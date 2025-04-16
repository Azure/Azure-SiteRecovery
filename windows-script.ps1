

$filePath = "C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\Application Data\etc\RcmProtectionState.json"

if ( -not (Test-Path $filePath) )

{

    Write-Host "file $filePath not found."
    exit
}





    Write-Host "file $filePath not found."

}





Stop-Service svagents

cd "C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\Application Data\etc"

del RcmProtectionState.json

Start-Service svagents