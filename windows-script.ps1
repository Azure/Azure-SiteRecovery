Stop-Service svagents

cd "C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\Application Data\etc"

del RcmProtectionState.json

Start-Service svagents