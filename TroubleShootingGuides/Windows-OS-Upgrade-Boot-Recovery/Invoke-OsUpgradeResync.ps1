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

# SIG # Begin signature block
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCVC2qRWvkOa23U
# USKSKHz96v+RFJ4Ntlp3BcR/ikEmf6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIK82GAPJnL23DH0sIhU9on5uj5G5bp24t5sgVknbu8BmMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAKZdpquCyOj6BEVzS
# kMA5HXtEJDeejoxnWRRDWtPpBla/FMsro0yJa2LoKOeR7TIo7vnufXcQA2wDDWj5
# 7jSH4ffMwbEUzhW5x5OzO7PzGw3kRkHwmHuaK82sStg6vfPHPlfY8YCe5bbuwT1R
# IaPphMXgj+4WDoQBvH3/DCY14JZ24qH2eEoL5K3LxPIPkih1YOU61BwjRBS7yq6m
# v8g/6z4oDPW1O12BizQIfanDNg/fJkPSOJPCbkvJR3+3BRI3O/Pfhm+6pz61cVsL
# VY3a7/hxbjXy/daGvWghEmsJgmuGDxvfE/D0MsfApBBNTUBdMu61Q+NAYjI4St5s
# Ce3JxqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kw
# gheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCzx9Uc0fODZRVy
# B/ydNByOF9eagJcA1rVOvmOMZf+sPQIGargJGma8GBMyMDI2MTAyNDE0MDYzNS41
# NDlaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIF
# EKADAgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyM1oXDTI2MTEx
# MzE4NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNhRM+BzF2AYiq5dUpZpJFP
# RjCcipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU/W6fecujjILkPqn9pngt
# WRkfQgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY/Qk/jtjsHdFXVBe+tshl
# IkSJ3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQMJP7tO8/BJ7ITs4/AV3D2
# bv8eHk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf5x1lXxAwEw5a7dpS+CKT
# anhtv+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1S9e8h1TszXFzjLLvE9Em
# jnNfIewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J60fGOl7A1UoUyAkhpb2B
# ja+SwSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6FZlPO8iuNyk680Di8Vnb
# SNpIdJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asNt/Ng6o4m2dnooWOdM3yK
# sJaWjyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+XSvI2m1yN4iibqjm5HPa
# AO3OJ+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C/+n1KFBpDGdDMw9gmu8C
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5ZQqnF5x8S1bJQzAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg5I/5S+gx67aR6RiW8ZAw
# tE3mz8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyvh3e2q/BV8rjHE3ud9PyY
# yq32euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZsSypbXDBbQkWkNl6g82y
# Ty3AbBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dMSkSZweCNDXqd9r/9W2Vd
# RZsDJKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69/N5CP/Tq3YgI1ub4b9+3
# MJFKWhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2NFXJFQHef6AdRe1ERvYQ
# eqtyrBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67oNwR4pEEJyAIEREvkdhj
# jfWcgsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D59r7/qebNSyQPTfwI9++
# jEY0Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HEovbA69qGlZ3OpUE3H1RB
# GDVp/FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IEXO2SeD1aD3IqvAOdHFKH
# g1vpbPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7zw64aO5hmJ7eQwoMfTu0
# Vay6r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCC
# AkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO6GxYkwIhgPMjAyNjEw
# MjQwNTUwMDFaGA8yMDI2MTAyNTA1NTAwMVowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7obFiQIBADAKAgEAAgIbFQIB/zAHAgEAAgISbjAKAgUA7ogXCQIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQAmY0TmRqLoZT009oojLNboBI78CsCXw6kg
# UhCJC2fX2REX3MwjApgjd1YKO9TcTTgNmuWSGZPxWpO5m3zyZTX8ojNOBYnmyeJ+
# jBgTfQILnz1jdpxLzdbT8QnCAM1Y+mTcALHp2c02hV+AT7l9/P/MO95wt2n1Okg2
# aC56WTOWR+7xdIHvgGCKEs3rY1i0T/VXyXddzcmSLkEGHRtK97oL6lsnLhqKXcpv
# ZwAMXxBWZYY7hTIeZW27SQ0uYTQkiE3ZYqKYTVNvw4v/kOnut2Hh1jK1QXh1QGHU
# MTKnd+Avgz3jcBAA0IFQWBvE0s5bt8KP/bUkvXSOGUxWr+bxa0j2MYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIXcfsupa8B
# HeoAAQAAAhcwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgd3ijum/ArBCT1SSOVLaQVvqoIfR7mAK/
# FU+Yk+iRIz8wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDQ8lBgPl23yZ0S
# zUSt5phOIegHPywrkNwevxe2k+RaWzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACF3H7LqWvAR3qAAEAAAIXMCIEIIHGfPdIWOlAbfQ5
# 8YCfgA+txzMWVLCJjW/rcNjMPy+SMA0GCSqGSIb3DQEBCwUABIICAGFOuV5Mw3SW
# VBqtgEkaaeg1f8P32w/GSaR4wSgOq95NAj+xUP+g0x29f5BZY7STWiB8FqOwosX/
# qdzE0EkGf4PRlhJfgKSWD4pSDnOL9D5r5/A7gD31JUDTicQN1t8jHd/SIUYqvsY2
# DKgGU+JnxK8pRBfz6pZRp0tRVpNxchwuIMZMNtifr0jZHnyR8M18KahLVMYNBp5j
# Z22bc0utJicTDA9c8RF+DetKpEXxuobDkwcEh3vtF0Q/J/d9Mw8Oc9NdOFgV85Zq
# VWK70lcFcrTG0t4493aiQ6S1i1wmetwfB2Cjf7r9V/61UznTskiMsPEQQbAYBTrH
# lC0NQsAJOUfWsnjzYujcVGr7tS2j8fW3caSWo4VeebcoZNRs+pMINRtxpRhAVURN
# NEqEbzNZTcB4PQUxfZFByUPT0vaOq2ojPI4qcZUUNNEyT3WF5b/okdIzgFt0PwpL
# baTSxwOdAlkeWFV9iNcS7A74hFV7hpsuPXlaRtxSc9IEsRkqrcWS+UM/uLgtY7f/
# J02a0XIZ79HCo3D67NO+dKiyNVkL2pjIUpSH5MSU0BimWVg6Z320pp/m8zIRR3s3
# 47rrRsE9PosJkYBXJsFQn0pDt47RkX1JbiRLRhOU7oH4eOVB+QupQWXo2kNs+0qi
# IpI2KIWmLEBMwmyljTePNqfzWQPMsgKP
# SIG # End signature block
