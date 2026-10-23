# Windows Server OS upgrade: test failover or failover boot failure

A VM upgraded from Windows Server 2016 or later to a higher Windows Server
release while protected by Azure Site Recovery may fail to boot during test
failover or failover, even though the source VM is running.

## Prerequisites

- Run on the **source Windows VM**, not the failed-over VM, using
  **Windows PowerShell 5.1 or later as Administrator**.

## Customer procedure

1. Download [Invoke-OsUpgradeResync.ps1](Invoke-OsUpgradeResync.ps1) to the source
   VM and review it.
2. Open PowerShell **as Administrator** in the folder containing the script.
3. Run the following command and confirm the operation when prompted:

   ```powershell
   .\Invoke-OsUpgradeResync.ps1
   ```

The script discovers the agent installation directory from the registered
`svagents` service executable, checks that `drvutil.exe` exists, and performs
the following sequence:

| Step | Action |
|---|---|
| 1 | Stop `svagents` and wait for it to stop. |
| 2 | Run `"<agent installation directory>\drvutil.exe" --stopf -stopall`. This stops filtering on all volumes. |
| 3 | Restart `svagents` in a `finally` block, including if the command fails, and wait for it to run. |

The expected command output is `Returned Success from stop All filtering`.
If the command or service restart fails, preserve the full output and contact
Microsoft Support.

## Verification

Confirm that replication resumes, corrective synchronization completes for the
protected disks including the OS disk, and a new recovery point is available.
