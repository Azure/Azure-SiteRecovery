#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-OsUpgradeResync.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw ($parseErrors | Out-String)
}
if (-not $ast.ScriptRequirements.IsElevationRequired -or $ast.ScriptRequirements.RequiredPSVersion -lt [version]'5.1') {
    throw 'The script must retain its administrator and Windows PowerShell 5.1 requirements.'
}
$functions = $ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $_.Name -in @('Get-AsrInstallDate', 'Get-PostAsrWindowsUpgrade')
}
foreach ($definition in $functions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Load the actual main body without administrator requirements; all machine-changing commands are mocked.
$statements = $ast.EndBlock.Statements | Where-Object {
    $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
}
$attributes = ($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
$main = [scriptblock]::Create($attributes + "`n" + $ast.ParamBlock.Extent.Text + "`n" +
    (($statements | ForEach-Object { $_.Extent.Text }) -join "`n"))
$script:entries = @()
$script:records = @{}
$script:stopCount = 0
$script:startCount = 0
$script:installDateError = $false
$script:currentVersion = '10.0.26100'
$script:serviceStatus = 'Running'
$script:flowMode = $false
$script:msiDates = @()
$script:directoryDates = @{}
$script:dataLogDirectory = $null
$script:historyReadError = $false

function Get-ChildItem {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($LiteralPath -ne 'HKLM:\SYSTEM\Setup') {
        throw "Unexpected registry enumeration: $LiteralPath"
    }
    if ($script:historyReadError) {
        throw 'TEST: Windows Setup history access denied'
    }
    $script:entries
}

function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\InDskFlt\Parameters') {
        return [pscustomobject]@{ DataLogDirectory = $script:dataLogDirectory }
    }
    if (-not $script:records.ContainsKey($LiteralPath)) {
        throw "Unexpected registry read: $LiteralPath"
    }
    $script:records[$LiteralPath]
}

function Get-AsrMsiInstallDates {
    $script:msiDates
}

function Get-Item {
    [CmdletBinding()]
    param([string]$LiteralPath)
    [pscustomobject]@{ CreationTime = $script:directoryDates[$LiteralPath] }
}

function Get-Service {
    [CmdletBinding()]
    param([string]$Name)
    $service = [pscustomobject]@{ Status = $script:serviceStatus }
    $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($Status, $Timeout)
    }
    return $service
}

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    if ($ClassName -eq 'Win32_OperatingSystem') {
        return [pscustomobject]@{ Version = $script:currentVersion }
    }
    [pscustomobject]@{ PathName = '"C:\ASR\svagents.exe"' }
}

function Test-Path {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$PathType)
    if ($script:flowMode) { return $true }
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\InDskFlt\Parameters') {
        return $null -ne $script:dataLogDirectory
    }
    return $script:directoryDates.ContainsKey($LiteralPath)
}

function Stop-Service {
    [CmdletBinding()]
    param([string]$Name)
    $script:stopCount++
    throw 'TEST: recovery sequence reached'
}

function Start-Service {
    [CmdletBinding()]
    param([string]$Name)
    $script:startCount++
}

function Set-History {
    param([object[]]$Records)
    $script:entries = @()
    $script:records = @{}
    $index = 0
    foreach ($record in $Records) {
        $path = "Fixture:\$index"
        $index++
        $name = 'Source OS (Updated on 1/15/2024 0:01:00)'
        if ($record.ContainsKey('Name')) { $name = $record.Name }
        $script:entries += [pscustomobject]@{ PSChildName = $name; PSPath = $path }
        $values = @{}
        if ($record.ContainsKey('Build')) {
            $buildName = 'CurrentBuild'
            if ($record.ContainsKey('BuildName')) { $buildName = $record.BuildName }
            $values[$buildName] = $record.Build
        }
        if ($record.ContainsKey('Major')) { $values.CurrentMajorVersionNumber = $record.Major }
        if ($record.ContainsKey('Minor')) { $values.CurrentMinorVersionNumber = $record.Minor }
        $script:records[$path] = [pscustomobject]$values
    }
}

$cases = @(
    @{ Name = 'Same-day Server 2016 to 2019'; Current = '10.0.17763'; Records = @(@{ Build = '14393' }); Expected = $true }
    @{ Name = 'Server 2022 to 2025'; Current = '10.0.26100'; Records = @(@{ Build = '20348' }); Expected = $true }
    @{ Name = 'Windows 10 to 11'; Current = '10.0.22631'; Records = @(@{ Build = '19045'; Major = 10; Minor = 0 }); Expected = $true }
    @{ Name = 'Windows 10 1507 build fallback'; Current = '10.0.19045'; Records = @(@{ Build = '10240' }); Expected = $true }
    @{ Name = 'Upgrade before ASR installation'; Current = '10.0.26100'; Records = @(@{ Build = '20348'; Name = 'Source OS (Updated on 1/14/2024 23:59:59)' }); Expected = $false }
    @{ Name = 'Unreadable older build is not needed'; Current = '10.0.26100'; Records = @(@{ Name = 'Source OS (Updated on 1/14/2024 23:59:59)' }); Expected = $false }
    @{ Name = 'Same build'; Current = '10.0.20348'; Records = @(@{ Build = '20348' }); Expected = $false }
    @{ Name = 'Downgrade'; Current = '10.0.20348'; Records = @(@{ Build = '26100' }); Expected = $false }
    @{ Name = 'Pre-Windows 10 fallback'; Current = '10.0.17763'; Records = @(@{ Build = '9600' }); Expected = $false }
    @{ Name = 'Recorded different major version'; Current = '10.0.17763'; Records = @(@{ Build = '14393'; Major = 6; Minor = 3 }); Expected = $false }
    @{ Name = 'Alternate build value'; Current = '10.0.17763'; Records = @(@{ Build = '14393'; BuildName = 'CurrentBuildNumber' }); Expected = $true }
    @{ Name = 'Empty history'; Current = '10.0.26100'; Records = @(); Expected = $false }
    @{ Name = 'Unrelated setup key'; Current = '10.0.26100'; Records = @(@{ Name = 'Unrelated'; Build = '20348' }); Expected = $false }
    @{ Name = 'Missing build'; Current = '10.0.26100'; Records = @(@{}); Error = 'Cannot verify the previous Windows build*' }
    @{ Name = 'Wrong build registry type'; Current = '10.0.26100'; Records = @(@{ Build = 20348 }); Error = 'Cannot verify the previous Windows build*' }
    @{ Name = 'Build overflow'; Current = '10.0.26100'; Records = @(@{ Build = '4294967296' }); Error = 'Cannot verify the previous Windows build*' }
    @{ Name = 'Build includes revision'; Current = '10.0.26100'; Records = @(@{ Build = '20348.1' }); Error = 'Cannot verify the previous Windows build*' }
    @{ Name = 'Unknown history date'; Current = '10.0.26100'; Records = @(@{ Build = '20348'; Name = 'Source OS (unknown date)' }); Error = 'Cannot verify the Windows upgrade date*' }
    @{ Name = 'Invalid calendar date'; Current = '10.0.26100'; Records = @(@{ Build = '20348'; Name = 'Source OS (Updated on 2/30/2024 12:00:00)' }); Error = 'Cannot verify the Windows upgrade date*' }
    @{ Name = 'Future history date'; Current = '10.0.26100'; Records = @(@{ Build = '20348'; Name = 'Source OS (Updated on 1/15/9999 12:00:00)' }); Error = 'Cannot verify the Windows upgrade date*' }
    @{ Name = 'AM history format'; Current = '10.0.26100'; Records = @(@{ Build = '20348'; Name = 'Source OS (Updated on 1/16/2024 12:01:00 AM)' }); Expected = $true }
    @{ Name = 'PM history format'; Current = '10.0.26100'; Records = @(@{ Build = '20348'; Name = 'Source OS (Updated on 1/16/2024 1:01:00 PM)' }); Expected = $true }
    @{ Name = 'Multiple retained upgrades'; Current = '10.0.26100'; Records = @(@{ Build = '9600' }, @{ Build = '14393' }); Expected = $true }
)
$count = 0
$culture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]'de-DE'
    foreach ($case in $cases) {
        Set-History $case.Records
        $failure = $null
        $upgrade = $null
        try {
            $upgrade = Get-PostAsrWindowsUpgrade -AsrInstallDate ([datetime]'2024-01-15') -CurrentVersion ([version]$case.Current)
        } catch {
            $failure = $_.Exception.Message
        }
        if ($case.ContainsKey('Error')) {
            if ($null -eq $failure -or $failure -notlike $case.Error) {
                throw "FAIL $($case.Name): expected '$($case.Error)', received '$failure'."
            }
        } elseif ($null -ne $failure -or ($null -ne $upgrade) -ne $case.Expected) {
            throw "FAIL $($case.Name): expected eligibility $($case.Expected), received '$failure'."
        }
        $count++
    }
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $culture
}

$dateCases = @(
    @{ Name = 'MSI date only'; Msi = @([datetime]'2024-01-15'); Directories = @{}; Expected = [datetime]'2024-01-15' }
    @{ Name = 'Agent directory only'; Msi = @(); Directories = @{ 'C:\ASR' = [datetime]'2024-01-14' }; Expected = [datetime]'2024-01-14' }
    @{ Name = 'Directory predates MSI servicing'; Msi = @([datetime]'2024-02-01'); Directories = @{ 'C:\ASR' = [datetime]'2024-01-14' }; Expected = [datetime]'2024-01-14' }
    @{ Name = 'MSI predates recreated directory'; Msi = @([datetime]'2024-01-10'); Directories = @{ 'C:\ASR' = [datetime]'2024-02-01' }; Expected = [datetime]'2024-01-10' }
    @{ Name = 'Log directory preserves earlier installation'; Msi = @([datetime]'2024-02-01'); Directories = @{ 'C:\ASR' = [datetime]'2024-01-15'; 'C:\ASRLogs' = [datetime]'2024-01-10' }; Log = 'C:\ASRLogs'; Expected = [datetime]'2024-01-10' }
    @{ Name = 'Earliest of registry views'; Msi = @([datetime]'2024-02-01', [datetime]'2024-01-10'); Directories = @{}; Expected = [datetime]'2024-01-10' }
    @{ Name = 'Invalid directory date is ignored with evidence remaining'; Msi = @([datetime]'2024-01-15'); Directories = @{ 'C:\ASR' = [datetime]'9999-01-01' }; Expected = [datetime]'2024-01-15' }
    @{ Name = 'No usable installation evidence'; Msi = @(); Directories = @{}; Error = $true }
)
foreach ($case in $dateCases) {
    $script:msiDates = $case.Msi
    $script:directoryDates = $case.Directories
    $script:dataLogDirectory = $case.Log
    $failure = $null
    $date = $null
    try {
        $date = Get-AsrInstallDate -InstallDirectory 'C:\ASR'
    } catch {
        $failure = $_.Exception.Message
    }
    if ($case.Error -eq $true) {
        if ($failure -notlike 'Cannot determine the ASR installation date*') {
            throw "FAIL $($case.Name): expected an installation-date error, received '$failure'."
        }
    } elseif ($null -ne $failure -or $date -ne $case.Expected) {
        throw "FAIL $($case.Name): installation cutoff '$date', error '$failure'."
    }
    $count++
}

function Get-AsrInstallDate {
    param([string]$InstallDirectory)
    if ($script:installDateError) {
        throw 'Cannot determine the ASR installation date.'
    }
    [datetime]'2024-01-15'
}
$script:flowMode = $true
$flowCases = @(
    @{ Name = 'No history leaves services unchanged'; Records = @(); Stops = 0; Starts = 0 }
    @{ Name = 'Pre-install upgrade leaves services unchanged'; Records = @(@{ Build = '20348'; Name = 'Source OS (Updated on 1/14/2024 23:59:59)' }); Stops = 0; Starts = 0 }
    @{ Name = 'Malformed history leaves services unchanged'; Records = @(@{}); Stops = 0; Starts = 0; Error = 'Cannot verify the previous Windows build*' }
    @{ Name = 'Unreadable history leaves services unchanged'; Records = @(); HistoryError = $true; Stops = 0; Starts = 0; Error = 'TEST: Windows Setup history access denied' }
    @{ Name = 'Same build leaves services unchanged'; Records = @(@{ Build = '26100' }); Stops = 0; Starts = 0 }
    @{ Name = 'Downgrade leaves services unchanged'; Records = @(@{ Build = '26200' }); Stops = 0; Starts = 0 }
    @{ Name = 'Unknown ASR installation date leaves services unchanged'; Records = @(); DateError = $true; Stops = 0; Starts = 0; Error = 'Cannot determine the ASR installation date*' }
    @{ Name = 'Unparseable current OS leaves services unchanged'; Current = 'invalid'; Records = @(); Stops = 0; Starts = 0; Error = 'Cannot determine the current Windows version*' }
    @{ Name = 'Unsupported current OS leaves services unchanged'; Current = '6.3.9600'; Records = @(); Stops = 0; Starts = 0 }
    @{ Name = 'Initially stopped service remains untouched'; Service = 'Stopped'; Records = @(); Stops = 0; Starts = 0; Error = 'The svagents service must be running*' }
    @{ Name = 'Eligible upgrade reaches recovery and finally'; Records = @(@{ Build = '20348' }); Stops = 1; Starts = 1; Error = 'TEST: recovery sequence reached' }
    @{ Name = 'WhatIf never reaches recovery'; Records = @(@{ Build = '20348' }); WhatIf = $true; Stops = 0; Starts = 0 }
)
foreach ($case in $flowCases) {
    Set-History $case.Records
    $script:stopCount = 0
    $script:startCount = 0
    $script:installDateError = $case.DateError -eq $true
    $script:historyReadError = $case.HistoryError -eq $true
    $script:currentVersion = '10.0.26100'
    $script:serviceStatus = 'Running'
    if ($case.ContainsKey('Current')) { $script:currentVersion = $case.Current }
    if ($case.ContainsKey('Service')) { $script:serviceStatus = $case.Service }
    $failure = $null
    try {
        & $main -Confirm:$false -WhatIf:($case.WhatIf -eq $true)
    } catch {
        $failure = $_.Exception.Message
    }
    if (($case.ContainsKey('Error') -and ($null -eq $failure -or $failure -notlike $case.Error)) -or
        (-not $case.ContainsKey('Error') -and $null -ne $failure) -or
        $script:stopCount -ne $case.Stops -or $script:startCount -ne $case.Starts) {
        throw "FAIL $($case.Name): error '$failure', stopped $script:stopCount, started $script:startCount."
    }
    $count++
}
Write-Output "Passed $count OS upgrade history and service-guard checks."
