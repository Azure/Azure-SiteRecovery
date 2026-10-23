#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'

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
