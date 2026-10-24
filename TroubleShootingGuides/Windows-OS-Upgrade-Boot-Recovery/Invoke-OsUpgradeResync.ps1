#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
param()

$ErrorActionPreference = 'Stop'

function Open-OsUpgradeAgentLog {
    param([string]$InstallDirectory)

    try {
        $logDirectories = @(
            foreach ($configPath in [IO.Directory]::GetFiles($InstallDirectory, 'drscout.conf', [IO.SearchOption]::AllDirectories)) {
                $section = ''
                foreach ($line in [IO.File]::ReadAllLines($configPath)) {
                    if ($line -match '^\s*\[(?<Section>[^\]]+)\]\s*$') {
                        $section = $Matches.Section
                    } elseif ($section -ieq 'vxagent' -and $line -match '^\s*LogPathname\s*=\s*(?<Directory>.+?)\s*$') {
                        [Environment]::ExpandEnvironmentVariables($Matches.Directory.Trim('"'))
                    }
                }
            }
        ) | Select-Object -Unique
        $logDirectories = @($logDirectories)
        if ($logDirectories.Count -ne 1 -or -not [IO.Path]::IsPathRooted($logDirectories[0])) {
            Write-Warning 'Cannot uniquely determine the configured agent log directory. Skipping execution logging.' -WarningAction Continue
            return $null
        }
        $currentLogs = @(
            foreach ($path in [IO.Directory]::GetFiles($logDirectories[0], 'svagents_curr_*.log')) {
                if ([IO.Path]::GetFileName($path) -match '^svagents_curr_(?<Sequence>[0-9]+)\.log$') {
                    [pscustomobject]@{ Path = $path; Sequence = [uint64]$Matches.Sequence }
                }
            }
        )
        $currentLog = $currentLogs | Sort-Object Sequence -Descending | Select-Object -First 1
        if ($null -eq $currentLog) {
            Write-Warning 'No current svagents log file was found. Continuing without execution telemetry.' -WarningAction Continue
            return $null
        }

        # Only called while svagents is stopped; deny other writers and rotation until closed.
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $stream = $null
            $writer = $null
            try {
                $stream = [IO.FileStream]::new($currentLog.Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                $null = $stream.Seek(0, [IO.SeekOrigin]::End)
                $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
                return $writer
            } catch [IO.IOException] {
                if (($_.Exception.HResult -band 0xffff) -ne 32 -or $attempt -eq 19) {
                    Write-Warning "Could not open the agent log: $($_.Exception.Message). Skipping execution logging." -WarningAction Continue
                    return $null
                }
                Start-Sleep -Milliseconds 250
            } finally {
                if ($null -ne $stream -and $null -eq $writer) {
                    try {
                        $stream.Dispose()
                    } catch {
                        Write-Warning "Could not close the agent log stream: $($_.Exception.Message)" -WarningAction Continue
                    }
                }
            }
        }
    } catch {
        Write-Warning "Execution logging is unavailable: $($_.Exception.Message)" -WarningAction Continue
        return $null
    }
}

function Write-OsUpgradeAgentLog {
    param($Run, [string]$Stage, [Nullable[int]]$ExitCode, [string]$Output)

    if ($null -eq $Run.Writer) {
        return
    }
    try {
        $now = [datetime]::UtcNow
        $record = [ordered]@{
            Operation = 'OsUpgradeResync'
            RunId = $Run.Id
            Script = 'Invoke-OsUpgradeResync.ps1'
            ScriptSha256 = $Run.ScriptHash
            StartedUtc = $Run.StartedUtc
            EventUtc = $now.ToString('o')
            Stage = $Stage
            PreviousVersion = $Run.PreviousVersion
            CurrentVersion = $Run.CurrentVersion
            DrvutilExitCode = $ExitCode
        }
        if (-not [string]::IsNullOrEmpty($Output)) {
            $record['DrvutilOutput'] = $Output
        }
        $Run.Sequence++
        $entry = '#~> ({0}):  ALWAYS  {1} 0 {2} {3}' -f
            $now.ToString('MM-dd-yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            $PID, $Run.Sequence, ($record | ConvertTo-Json -Compress)
        $Run.Writer.WriteLine($entry)
        $Run.Writer.Flush()
    } catch {
        Write-Warning "Could not write execution telemetry for run $($Run.Id): $($_.Exception.Message)" -WarningAction Continue
    }
}

function Get-AsrMsiInstallDates {
    $today = (Get-Date).Date
    $dates = @()
    $productKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{275197FC-14FD-4560-A5EB-38217F80CBD1}'
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        $registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $productKey = $registry.OpenSubKey($productKeyPath)
            if ($null -ne $productKey) {
                try {
                    $value = $productKey.GetValue('InstallDate')
                    $date = [datetime]::MinValue
                    if ($value -is [string] -and
                        [datetime]::TryParseExact($value, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::None, [ref]$date) -and
                        $date.Year -ge 1601 -and $date.Date -le $today) {
                        $dates += $date.Date
                        Write-Host "ASR MSI installation date ($view): $($date.ToString('yyyy-MM-dd'))"
                    } else {
                        Write-Warning "The ASR MSI installation date in $view is missing or invalid."
                    }
                } finally {
                    $productKey.Dispose()
                }
            }
        } finally {
            $registry.Dispose()
        }
    }

    return $dates
}

function Get-AsrInstallDate {
    param([string]$InstallDirectory)

    $today = (Get-Date).Date
    $dates = @(Get-AsrMsiInstallDates)
    $directories = @($InstallDirectory)
    $driverParametersPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\InDskFlt\Parameters'
    if (Test-Path -LiteralPath $driverParametersPath -ErrorAction Stop) {
        $driverParameters = Get-ItemProperty -LiteralPath $driverParametersPath -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($driverParameters.DataLogDirectory)) {
            $directories += [Environment]::ExpandEnvironmentVariables($driverParameters.DataLogDirectory)
        }
    }

    # MSI servicing can reset InstallDate; these directories can retain the earlier installation date.
    foreach ($directory in $directories | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container -ErrorAction Stop)) {
            Write-Warning "Cannot use the ASR directory creation date because '$directory' is missing."
            continue
        }
        $date = (Get-Item -LiteralPath $directory -ErrorAction Stop).CreationTime.Date
        if ($date.Year -lt 1601 -or $date -gt $today) {
            Write-Warning "The ASR directory creation date for '$directory' is invalid."
            continue
        }
        $dates += $date
        Write-Host "ASR directory creation date ('$directory'): $($date.ToString('yyyy-MM-dd'))"
    }

    if ($dates.Count -eq 0) {
        Write-Warning 'Cannot determine the ASR installation date. No changes were made. Contact Microsoft Support.' -WarningAction Continue
        return $null
    }
    return $dates | Sort-Object | Select-Object -First 1
}

function Get-PostAsrWindowsUpgrade {
    param([datetime]$AsrInstallDate, [version]$CurrentVersion)

    $formats = [string[]]@('M/d/yyyy H:mm:ss', 'M/d/yyyy h:mm:ss tt')
    $history = @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop |
        Where-Object { $_.PSChildName -like 'Source OS*' })
    foreach ($entry in $history) {
        $upgradeDate = [datetime]::MinValue
        if ($entry.PSChildName -notmatch '^Source OS \(Updated on (?<Timestamp>.+)\)$' -or
            -not [datetime]::TryParseExact($Matches.Timestamp, $formats, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$upgradeDate) -or
            $upgradeDate.Year -lt 1601 -or $upgradeDate.Date -gt (Get-Date).Date) {
            Write-Warning "Cannot verify the Windows upgrade date in '$($entry.PSChildName)'. No changes were made. Contact Microsoft Support." -WarningAction Continue
            return $null
        }
        if ($upgradeDate.Date -lt $AsrInstallDate.Date) {
            continue
        }

        $previous = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop
        $buildText = $previous.CurrentBuild
        if ($null -eq $previous.PSObject.Properties['CurrentBuild']) {
            $buildText = $previous.CurrentBuildNumber
        }
        $previousBuild = [uint32]0
        if ($buildText -isnot [string] -or $buildText -notmatch '^[0-9]+$' -or
            -not [uint32]::TryParse($buildText, [ref]$previousBuild) -or $previousBuild -eq 0) {
            Write-Warning "Cannot verify the previous Windows build in '$($entry.PSChildName)'. No changes were made. Contact Microsoft Support." -WarningAction Continue
            return $null
        }

        $previousMajor = $previous.CurrentMajorVersionNumber
        $previousMinor = $previous.CurrentMinorVersionNumber
        if ($previousMajor -isnot [int] -or $previousMinor -isnot [int] -or
            $previousMajor -lt 0 -or $previousMinor -lt 0) {
            $previousMajor = 6
            if ($previousBuild -ge 10240) {
                $previousMajor = 10
            }
            $previousMinor = 0
        }
        if ($previousMajor -eq $CurrentVersion.Major -and $previousMinor -eq $CurrentVersion.Minor -and
            $previousBuild -lt $CurrentVersion.Build) {
            return [pscustomobject]@{
                Date = $upgradeDate
                PreviousVersion = "$previousMajor.$previousMinor.$previousBuild"
                CurrentVersion = $CurrentVersion.ToString()
            }
        }
    }
}

try {
    $service = Get-Service -Name 'svagents' -ErrorAction Stop

    $serviceConfiguration = Get-CimInstance -ClassName Win32_Service -Filter "Name='svagents'" -ErrorAction Stop
    if ($null -eq $serviceConfiguration -or [string]::IsNullOrWhiteSpace($serviceConfiguration.PathName)) {
        Write-Warning 'Cannot determine the svagents executable path. No changes were made.' -WarningAction Continue
        return
    }

    $imagePath = [Environment]::ExpandEnvironmentVariables($serviceConfiguration.PathName)
    if ($imagePath -match '^\s*"(?<Executable>[^"]+)"(?:\s|$)' -or
        $imagePath -match '^\s*(?<Executable>.+?\.exe)(?:\s|$)') {
        $serviceExecutable = $Matches.Executable
    } else {
        Write-Warning 'Cannot parse the svagents executable path. No changes were made.' -WarningAction Continue
        return
    }

    if (-not [IO.Path]::IsPathRooted($serviceExecutable) -or
        [IO.Path]::GetFileName($serviceExecutable) -ine 'svagents.exe' -or
        -not (Test-Path -LiteralPath $serviceExecutable -PathType Leaf)) {
        Write-Warning 'The registered svagents executable path is invalid. No changes were made.' -WarningAction Continue
        return
    }

    $installDirectory = [IO.Path]::GetDirectoryName($serviceExecutable)
    $drvutil = Join-Path -Path $installDirectory -ChildPath 'drvutil.exe'
    if (-not (Test-Path -LiteralPath $drvutil -PathType Leaf)) {
        Write-Warning "drvutil.exe was not found in '$installDirectory'. No changes were made." -WarningAction Continue
        return
    }

    Write-Host "Agent installation directory: $installDirectory"
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $currentVersion = $null
    if (-not [version]::TryParse($os.Version, [ref]$currentVersion) -or $currentVersion.Build -le 0) {
        Write-Warning 'Cannot determine the current Windows version. No changes were made. Contact Microsoft Support.' -WarningAction Continue
        return
    }
    if ($currentVersion.Major -ne 10 -or $currentVersion.Minor -ne 0) {
        Write-Warning 'This procedure does not apply to the current Windows version. No changes were made.' -WarningAction Continue
        return
    }
    $asrInstallDate = Get-AsrInstallDate -InstallDirectory $installDirectory
    if ($null -eq $asrInstallDate) {
        return
    }
    $upgrade = Get-PostAsrWindowsUpgrade -AsrInstallDate $asrInstallDate -CurrentVersion $currentVersion
    if ($null -eq $upgrade) {
        Write-Warning 'Retained Windows Setup history does not confirm a qualifying upgrade on or after ASR installation. No changes were made. If an upgrade is suspected, contact Microsoft Support.' -WarningAction Continue
        return
    }
    Write-Host "ASR installation date: $($asrInstallDate.ToString('yyyy-MM-dd'))"
    Write-Host "Windows upgrade detected: $($upgrade.PreviousVersion) -> $($upgrade.CurrentVersion) on $($upgrade.Date.ToString('yyyy-MM-dd'))."

    if (-not $PSCmdlet.ShouldProcess(
        $env:COMPUTERNAME,
        'Stop svagents, run drvutil --stopf -stopall on all volumes, and restart svagents'
    )) {
        return
    }
} catch {
    Write-Warning "Cannot verify whether this VM requires mitigation: $($_.Exception.Message). No changes were made." -WarningAction Continue
    return
}

$scriptHash = $null
try {
    $scriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
} catch {
    Write-Warning "Could not calculate the script hash: $($_.Exception.Message). Continuing with mitigation." -WarningAction Continue
}
$run = [pscustomobject]@{
    Id = [guid]::NewGuid().ToString('D')
    StartedUtc = [datetime]::UtcNow.ToString('o')
    ScriptHash = $scriptHash
    PreviousVersion = $upgrade.PreviousVersion
    CurrentVersion = $upgrade.CurrentVersion
    Sequence = 0
    Writer = $null
}
Write-Host "OS upgrade recovery run ID: $($run.Id)"
$exitCode = $null
$output = [Collections.Generic.List[string]]::new()
$commandSucceeded = $false
$serviceRestarted = $false

try {
    try {
        Stop-Service -Name 'svagents' -Confirm:$false -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    } catch {
        Write-Warning "Could not stop svagents: $($_.Exception.Message). Continuing with drvutil." -WarningAction Continue
    }

    $commandErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can treat native stderr as an error; buffer both streams.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $drvutil --stopf -stopall 2>&1 | ForEach-Object { $output.Add([string]$_) }
        $exitCode = $global:LASTEXITCODE
    } catch {
        $output.Add("Could not run drvutil: $($_.Exception.Message)")
    } finally {
        $ErrorActionPreference = $commandErrorPreference
    }
    $output | ForEach-Object { Write-Host $_ }
    $outputText = $output -join [Environment]::NewLine
    $commandSucceeded = ($null -ne $exitCode -and $exitCode -eq 0 -and
        $outputText -match 'Returned Success from stop All filtering' -and
        $outputText -notmatch '\bFailed\b')

    try {
        $service.Refresh()
        if ($service.Status -eq 'Stopped') {
            $run.Writer = Open-OsUpgradeAgentLog -InstallDirectory $installDirectory
            Write-OsUpgradeAgentLog -Run $run -Stage 'Started'
            $stage = 'RecoveryFailed'
            if ($commandSucceeded) {
                $stage = 'FilteringSucceeded'
            }
            Write-OsUpgradeAgentLog -Run $run -Stage $stage -ExitCode $exitCode -Output $outputText
        } else {
            Write-Warning 'svagents is not stopped, so the captured output cannot be safely appended to its active log. The output is shown above.' -WarningAction Continue
        }
    } catch {
        Write-Warning "Could not append the captured command output to the agent log: $($_.Exception.Message)" -WarningAction Continue
    }
} catch {
    $commandSucceeded = $false
    Write-Warning "Mitigation encountered an error: $($_.Exception.Message)" -WarningAction Continue
} finally {
    try {
        try {
            Write-OsUpgradeAgentLog -Run $run -Stage 'ServiceRestartRequested'
        } catch {
            Write-Warning "Could not record the service restart: $($_.Exception.Message)" -WarningAction Continue
        } finally {
            if ($null -ne $run.Writer) {
                try {
                    $run.Writer.Dispose()
                } catch {
                    Write-Warning "Could not close execution telemetry for run $($run.Id): $($_.Exception.Message)" -WarningAction Continue
                }
            }
        }
    } finally {
        try {
            Start-Service -Name 'svagents' -Confirm:$false -ErrorAction Stop
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
            $serviceRestarted = $true
        } catch {
            Write-Warning "Could not start svagents: $($_.Exception.Message). Contact Microsoft Support." -WarningAction Continue
        }
    }
}

if (-not $commandSucceeded) {
    $exitCodeText = 'unavailable'
    if ($null -ne $exitCode) {
        $exitCodeText = [string]$exitCode
    }
    Write-Warning "drvutil did not confirm success (exit code $exitCodeText). Review the output above and contact Microsoft Support." -WarningAction Continue
} elseif ($serviceRestarted) {
    Write-Host 'Command completed and svagents is running. Wait for synchronization and a new recovery point before validating recovery.'
}
