#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function New-OsUpgradeLogRun {
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('D')
        StartedUtc = [datetime]::UtcNow.ToString('o')
        ScriptHash = $null
        PreviousVersion = $null
        CurrentVersion = $null
        Sequence = 0
        Writer = $null
        ScriptHashError = $null
        ServiceStopError = $null
        LoggingError = $null
        FallbackLogPath = $null
        Records = [Collections.Generic.List[string]]::new()
        NativeRecordsWritten = 0
    }
}

function Write-OsUpgradeMessage {
    param([string]$Message, [string]$Level = 'Warning', [switch]$Console,
        $Run = $script:osUpgradeRun)

    Write-OsUpgradeAgentLog -Run $Run -Stage 'Message' -Message $Message -Level $Level
    if ($Console) {
        Write-Host $Message
    }
}

function Get-OsUpgradeInstallDirectory {
    try {
        $configuration = Get-CimInstance -ClassName Win32_Service -Filter "Name='svagents'" -ErrorAction Stop
        if ($null -ne $configuration -and -not [string]::IsNullOrWhiteSpace($configuration.PathName)) {
            $imagePath = [Environment]::ExpandEnvironmentVariables($configuration.PathName)
            if ($imagePath -match '^\s*"(?<Executable>[^"]+)"(?:\s|$)' -or
                $imagePath -match '^\s*(?<Executable>.+?\.exe)(?:\s|$)') {
                $executable = $Matches.Executable
                if ([IO.Path]::IsPathRooted($executable) -and
                    [IO.Path]::GetFileName($executable) -ieq 'svagents.exe' -and
                    (Test-Path -LiteralPath $executable -PathType Leaf)) {
                    return [IO.Path]::GetDirectoryName($executable)
                }
            }
        }
        Write-OsUpgradeMessage -Message 'Cannot determine the svagents installation directory.'
    } catch {
        Write-OsUpgradeMessage -Message "Cannot determine the svagents installation directory: $($_.Exception.Message)"
    }
    return $null
}

function Complete-OsUpgradeAssessment {
    param([string]$Message, [string]$InstallDirectory)

    Write-OsUpgradeMessage -Message $Message -Level 'Information' -Console
    if (-not $WhatIfPreference) {
        if ([string]::IsNullOrEmpty($InstallDirectory)) {
            $InstallDirectory = Get-OsUpgradeInstallDirectory
        }
        if (-not [string]::IsNullOrEmpty($InstallDirectory)) {
            Write-OsUpgradeFallbackLog -Run $script:osUpgradeRun -InstallDirectory $InstallDirectory
        }
    }
}

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
            Write-OsUpgradeMessage -Message 'Cannot uniquely determine the configured agent log directory. Retaining diagnostics in the ASR installation folder.'
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
            Write-OsUpgradeMessage -Message 'No current svagents log file was found. Retaining diagnostics in the ASR installation folder.'
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
                    Write-OsUpgradeMessage -Message "Could not open the agent log: $($_.Exception.Message). Retaining diagnostics in the ASR installation folder."
                    return $null
                }
                Start-Sleep -Milliseconds 250
            } finally {
                if ($null -ne $stream -and $null -eq $writer) {
                    try {
                        $stream.Dispose()
                    } catch {
                        Write-OsUpgradeMessage -Message "Could not close the agent log stream: $($_.Exception.Message)"
                    }
                }
            }
        }
    } catch {
        Write-OsUpgradeMessage -Message "Native execution logging is unavailable: $($_.Exception.Message)"
        return $null
    }
}

function Write-OsUpgradeAgentLog {
    param($Run, [string]$Stage, [Nullable[int]]$ExitCode, [string]$Output, [string]$Command,
        [string]$Message, [string]$Level)
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
        if (-not [string]::IsNullOrEmpty($Command)) {
            $record['DrvutilCommand'] = $Command
        }
        if (-not [string]::IsNullOrEmpty($Message)) {
            $record['Message'] = $Message
            $record['Level'] = $Level
        }
        foreach ($name in @('ScriptHashError', 'ServiceStopError', 'LoggingError')) {
            $property = $Run.PSObject.Properties[$name]
            if ($null -ne $property -and -not [string]::IsNullOrEmpty($property.Value)) {
                $record[$name] = $property.Value
            }
        }
        $Run.Sequence++
        $entry = '#~> ({0}):  ALWAYS  {1} 0 {2} {3}' -f
            $now.ToString('MM-dd-yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            $PID, $Run.Sequence, ($record | ConvertTo-Json -Compress)
        $Run.Records.Add($entry)
        if ($null -ne $Run.Writer) {
            while ($Run.NativeRecordsWritten -lt $Run.Records.Count) {
                $Run.Writer.WriteLine($Run.Records[$Run.NativeRecordsWritten])
                $Run.Writer.Flush()
                $Run.NativeRecordsWritten++
            }
        }
    } catch {
        $Run.LoggingError = "Could not write native execution telemetry: $($_.Exception.Message)"
        $writer = $Run.Writer
        $Run.Writer = $null
        try {
            if ($null -ne $writer) { $writer.Dispose() }
        } catch {
            $Run.LoggingError += " Could not close the native log: $($_.Exception.Message)"
        }
        Write-OsUpgradeMessage -Run $Run -Message $Run.LoggingError
    }
}

function Write-OsUpgradeFallbackLog {
    param($Run, [string]$InstallDirectory)

    $stream = $null
    $writer = $null
    try {
        $path = Join-Path -Path $InstallDirectory -ChildPath "OsUpgradeResync_$($Run.Id).log"
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        foreach ($record in $Run.Records) {
            $writer.WriteLine($record)
        }
        $writer.Dispose()
        $writer = $null
        $stream = $null
        $Run.FallbackLogPath = $path
    } catch {
        Write-OsUpgradeMessage -Run $Run -Message "Could not write the fallback log in the ASR installation folder: $($_.Exception.Message)"
    } finally {
        try {
            if ($null -ne $writer) {
                $writer.Dispose()
            } elseif ($null -ne $stream) {
                $stream.Dispose()
            }
        } catch {
            Write-OsUpgradeMessage -Run $Run -Message "Could not close the fallback log: $($_.Exception.Message)"
        }
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
                    } else {
                        Write-OsUpgradeMessage -Message "The ASR MSI installation date in $view is missing or invalid."
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
            Write-OsUpgradeMessage -Message "Cannot use the ASR directory creation date because '$directory' is missing."
            continue
        }
        $date = (Get-Item -LiteralPath $directory -ErrorAction Stop).CreationTime.Date
        if ($date.Year -lt 1601 -or $date -gt $today) {
            Write-OsUpgradeMessage -Message "The ASR directory creation date for '$directory' is invalid."
            continue
        }
        $dates += $date
    }

    if ($dates.Count -eq 0) {
        Write-OsUpgradeMessage -Message 'Cannot determine the ASR installation date. No changes were made. Contact Microsoft Support.'
        return $null
    }
    return $dates | Sort-Object | Select-Object -First 1
}

function Get-WindowsUpgrade {
    param([version]$CurrentVersion)

    $assessment = [pscustomobject]@{
        Status = 'Undetermined'
        Date = $null
        PreviousVersion = $null
        CurrentVersion = $CurrentVersion.ToString()
        Diagnostic = $null
    }
    try {
        $formats = [string[]]@('M/d/yyyy H:mm:ss', 'M/d/yyyy h:mm:ss tt')
        $history = @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop |
            Where-Object { $_.PSChildName -like 'Source OS*' })
        $upgrades = [Collections.Generic.List[object]]::new()
        foreach ($entry in $history) {
            $upgradeDate = [datetime]::MinValue
            if ($entry.PSChildName -notmatch '^Source OS \(Updated on (?<Timestamp>.+)\)$' -or
                -not [datetime]::TryParseExact($Matches.Timestamp, $formats, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$upgradeDate) -or
                $upgradeDate.Year -lt 1601 -or $upgradeDate.Date -gt (Get-Date).Date) {
                $assessment.Diagnostic = 'Cannot verify the Windows upgrade date.'
                return $assessment
            }

            $previous = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop
            $buildText = $previous.CurrentBuild
            if ($null -eq $previous.PSObject.Properties['CurrentBuild']) {
                $buildText = $previous.CurrentBuildNumber
            }
            $previousBuild = [uint32]0
            if ($buildText -isnot [string] -or $buildText -notmatch '^[0-9]+$' -or
                -not [uint32]::TryParse($buildText, [ref]$previousBuild) -or $previousBuild -eq 0) {
                $assessment.Diagnostic = 'Cannot verify the previous Windows build.'
                return $assessment
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
                $upgrades.Add([pscustomobject]@{
                    Date = $upgradeDate
                    PreviousVersion = "$previousMajor.$previousMinor.$previousBuild"
                })
            }
        }

        $latest = $upgrades | Sort-Object Date -Descending | Select-Object -First 1
        $assessment.Status = 'NotUpgraded'
        if ($null -ne $latest) {
            $assessment.Status = 'Upgraded'
            $assessment.Date = $latest.Date
            $assessment.PreviousVersion = $latest.PreviousVersion
        }
    } catch {
        $assessment.Diagnostic = $_.Exception.Message
    }
    return $assessment
}

function Invoke-OsUpgradeDrvutil {
    param([string]$Path, [string[]]$Arguments)

    $output = [Collections.Generic.List[string]]::new()
    $exitCode = $null
    $commandErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can treat native stderr as an error; buffer both streams.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $Path @Arguments 2>&1 | ForEach-Object { $output.Add([string]$_) }
        $exitCode = $global:LASTEXITCODE
    } catch {
        $output.Add($_.Exception.Message)
    } finally {
        $ErrorActionPreference = $commandErrorPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output -join [Environment]::NewLine
    }
}

$noImpactMessage = 'There is no impact on this virtual machine.'
$undeterminedMessage = 'If you have upgraded OS from 2016 or above to higher version after installing ASR please contact https://aka.ms/azuresupport.'
$impactedMessage = 'Your Virtual machine is impacted, please contact https://aka.ms/azuresupport.'
$completedMessage = 'Script executed, Wait for new recovery point to be available before performing test failover or failover.'

$run = New-OsUpgradeLogRun
$script:osUpgradeRun = $run
$installDirectory = $null
if (-not $WhatIfPreference) {
    try {
        $run.ScriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        $run.ScriptHashError = $_.Exception.Message
        Write-OsUpgradeMessage -Message "Could not calculate the script hash: $($run.ScriptHashError)"
    }
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $currentVersion = $null
    if (-not [version]::TryParse($os.Version, [ref]$currentVersion) -or $currentVersion.Build -le 0) {
        Complete-OsUpgradeAssessment -Message $undeterminedMessage
        return
    }
    if ($currentVersion.Major -ne 10 -or $currentVersion.Minor -ne 0) {
        Complete-OsUpgradeAssessment -Message $noImpactMessage
        return
    }
    $upgrade = Get-WindowsUpgrade -CurrentVersion $currentVersion
    $run.CurrentVersion = $upgrade.CurrentVersion
    $run.PreviousVersion = $upgrade.PreviousVersion
    if ($upgrade.Status -eq 'NotUpgraded') {
        Complete-OsUpgradeAssessment -Message $noImpactMessage
        return
    }
    if ($upgrade.Status -ne 'Upgraded') {
        if (-not [string]::IsNullOrEmpty($upgrade.Diagnostic)) {
            Write-OsUpgradeMessage -Message $upgrade.Diagnostic
        }
        Complete-OsUpgradeAssessment -Message $undeterminedMessage
        return
    }

    $service = Get-Service -Name 'svagents' -ErrorAction Stop
    $installDirectory = Get-OsUpgradeInstallDirectory
    if ([string]::IsNullOrEmpty($installDirectory)) {
        Complete-OsUpgradeAssessment -Message $undeterminedMessage
        return
    }

    $asrInstallDate = Get-AsrInstallDate -InstallDirectory $installDirectory
    if ($null -eq $asrInstallDate) {
        Complete-OsUpgradeAssessment -Message $undeterminedMessage -InstallDirectory $installDirectory
        return
    }
    if ($asrInstallDate.Date -gt $upgrade.Date.Date) {
        Complete-OsUpgradeAssessment -Message $noImpactMessage -InstallDirectory $installDirectory
        return
    }
    $drvutil = Join-Path -Path $installDirectory -ChildPath 'drvutil.exe'

    if (-not $PSCmdlet.ShouldProcess(
        $env:COMPUTERNAME,
        'Stop svagents, run drvutil --stopf -stopall and drvutil --ps --dm, and start svagents'
    )) {
        return
    }
} catch {
    Write-OsUpgradeMessage -Message $_.Exception.Message
    Complete-OsUpgradeAssessment -Message $undeterminedMessage -InstallDirectory $installDirectory
    return
}

$exitCode = $null
$commandSucceeded = $false
$needsSupport = $false
$supportShown = $false
$supportLogged = $false

try {
    $serviceWarnings = @()
    try {
        Stop-Service -Name 'svagents' -Confirm:$false -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable serviceWarnings
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    } catch {
        $run.ServiceStopError = $_.Exception.Message
        Write-OsUpgradeMessage -Message "Could not stop svagents: $($run.ServiceStopError)"
    } finally {
        foreach ($warning in $serviceWarnings) {
            Write-OsUpgradeMessage -Message ([string]$warning)
        }
    }

    $result = Invoke-OsUpgradeDrvutil -Path $drvutil -Arguments @('--stopf', '-stopall')
    $exitCode = $result.ExitCode
    $outputText = $result.Output
    $commandSucceeded = ($null -ne $exitCode -and $exitCode -eq 0 -and
        $outputText -match 'Returned Success from stop All filtering' -and
        $outputText -notmatch '\bFailed\b')
    if (-not $commandSucceeded) {
        $needsSupport = $true
        Write-OsUpgradeMessage -Message $impactedMessage -Level 'Information' -Console
        $supportShown = $true
        $supportLogged = $true
    }

    $status = Invoke-OsUpgradeDrvutil -Path $drvutil -Arguments @('--ps', '--dm')
    if ($null -eq $status.ExitCode -or $status.ExitCode -ne 0) {
        $needsSupport = $true
    }

    try {
        $service.Refresh()
        if ($service.Status -eq 'Stopped') {
            $run.Writer = Open-OsUpgradeAgentLog -InstallDirectory $installDirectory
        } else {
            $run.LoggingError = 'svagents is not stopped; the active log cannot be safely updated.'
            Write-OsUpgradeMessage -Message $run.LoggingError
        }
    } catch {
        $run.LoggingError = $_.Exception.Message
        Write-OsUpgradeMessage -Message $run.LoggingError
    }
    Write-OsUpgradeAgentLog -Run $run -Stage 'Started'
    $stage = 'RecoveryFailed'
    if ($commandSucceeded) {
        $stage = 'FilteringSucceeded'
    }
    Write-OsUpgradeAgentLog -Run $run -Stage $stage -ExitCode $exitCode -Output $outputText -Command 'drvutil --stopf -stopall'
    Write-OsUpgradeAgentLog -Run $run -Stage 'DriverStatistics' -ExitCode $status.ExitCode -Output $status.Output -Command 'drvutil --ps --dm'
} catch {
    $needsSupport = $true
    Write-OsUpgradeMessage -Message $_.Exception.Message
    if (-not $supportShown) {
        Write-OsUpgradeMessage -Message $impactedMessage -Level 'Information' -Console
        $supportShown = $true
        $supportLogged = $true
    }
} finally {
    try {
        try {
            if ($needsSupport -and -not $supportLogged) {
                Write-OsUpgradeMessage -Message $impactedMessage -Level 'Information'
                $supportLogged = $true
            }
            Write-OsUpgradeMessage -Message $completedMessage -Level 'Information'
            Write-OsUpgradeAgentLog -Run $run -Stage 'ServiceRestartRequested'
        } catch {
            $run.LoggingError = $_.Exception.Message
            Write-OsUpgradeMessage -Message $run.LoggingError
        } finally {
            if ($null -ne $run.Writer) {
                $writer = $run.Writer
                $run.Writer = $null
                try {
                    $writer.Dispose()
                } catch {
                    $run.LoggingError = $_.Exception.Message
                    Write-OsUpgradeMessage -Message $run.LoggingError
                }
            }
        }
    } finally {
        Write-Host $completedMessage
        $serviceWarnings = @()
        try {
            Start-Service -Name 'svagents' -Confirm:$false -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable serviceWarnings
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
        } catch {
            $needsSupport = $true
            Write-OsUpgradeMessage -Message "Could not start svagents: $($_.Exception.Message)"
        } finally {
            foreach ($warning in $serviceWarnings) {
                Write-OsUpgradeMessage -Message ([string]$warning)
            }
        }
    }
}

if ($needsSupport -and -not $supportShown) {
    if (-not $supportLogged) {
        Write-OsUpgradeMessage -Message $impactedMessage -Level 'Information'
    }
    Write-Host $impactedMessage
}

if ($run.NativeRecordsWritten -lt $run.Records.Count) {
    Write-OsUpgradeFallbackLog -Run $run -InstallDirectory $installDirectory
}
