#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'

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
        throw 'Cannot determine the ASR installation date. No changes were made. Contact Microsoft Support.'
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
            throw "Cannot verify the Windows upgrade date in '$($entry.PSChildName)'. No changes were made. Contact Microsoft Support."
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
            throw "Cannot verify the previous Windows build in '$($entry.PSChildName)'. No changes were made. Contact Microsoft Support."
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

$service = Get-Service -Name 'svagents' -ErrorAction Stop
if ($service.Status -ne 'Running') {
    throw 'The svagents service must be running before this procedure. Contact Microsoft Support.'
}

$serviceConfiguration = Get-CimInstance -ClassName Win32_Service -Filter "Name='svagents'" -ErrorAction Stop
if ($null -eq $serviceConfiguration -or [string]::IsNullOrWhiteSpace($serviceConfiguration.PathName)) {
    throw 'Cannot determine the svagents executable path. No changes were made.'
}

$imagePath = [Environment]::ExpandEnvironmentVariables($serviceConfiguration.PathName)
if ($imagePath -match '^\s*"(?<Executable>[^"]+)"(?:\s|$)' -or
    $imagePath -match '^\s*(?<Executable>.+?\.exe)(?:\s|$)') {
    $serviceExecutable = $Matches.Executable
} else {
    throw 'Cannot parse the svagents executable path. No changes were made.'
}

if (-not [IO.Path]::IsPathRooted($serviceExecutable) -or
    [IO.Path]::GetFileName($serviceExecutable) -ine 'svagents.exe' -or
    -not (Test-Path -LiteralPath $serviceExecutable -PathType Leaf)) {
    throw 'The registered svagents executable path is invalid. No changes were made.'
}

$installDirectory = [IO.Path]::GetDirectoryName($serviceExecutable)
$drvutil = Join-Path -Path $installDirectory -ChildPath 'drvutil.exe'
if (-not (Test-Path -LiteralPath $drvutil -PathType Leaf)) {
    throw "drvutil.exe was not found in '$installDirectory'. No changes were made."
}

Write-Host "Agent installation directory: $installDirectory"
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$currentVersion = $null
if (-not [version]::TryParse($os.Version, [ref]$currentVersion) -or $currentVersion.Build -le 0) {
    throw 'Cannot determine the current Windows version. No changes were made. Contact Microsoft Support.'
}
if ($currentVersion.Major -ne 10 -or $currentVersion.Minor -ne 0) {
    Write-Warning 'This procedure does not apply to the current Windows version. No changes were made.'
    return
}
$asrInstallDate = Get-AsrInstallDate -InstallDirectory $installDirectory
$upgrade = Get-PostAsrWindowsUpgrade -AsrInstallDate $asrInstallDate -CurrentVersion $currentVersion
if ($null -eq $upgrade) {
    Write-Warning 'Retained Windows Setup history does not confirm a qualifying upgrade on or after ASR installation. No changes were made. If an upgrade is suspected, contact Microsoft Support.'
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

try {
    Stop-Service -Name 'svagents' -ErrorAction Stop
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))

    $output = & $drvutil --stopf -stopall 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    $outputText = $output -join [Environment]::NewLine
    if ($exitCode -ne 0 -or
        $outputText -notmatch 'Returned Success from stop All filtering' -or
        $outputText -match '\bFailed\b') {
        throw "drvutil did not confirm success (exit code $exitCode). Preserve the output and contact Microsoft Support."
    }
} finally {
    Start-Service -Name 'svagents' -ErrorAction Stop
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
}

Write-Host 'Command completed and svagents is running. Wait for synchronization and a new recovery point before validating recovery.'
