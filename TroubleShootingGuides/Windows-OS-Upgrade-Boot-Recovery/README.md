# Windows OS upgrade: test failover or failover boot failure

A VM upgraded from Windows Server 2016 or later to a higher Windows Server
release, or from Windows 10 to Windows 11, while protected by Azure Site Recovery
may fail to boot during test failover or failover, even though the source VM is
running.

## Prerequisites

- Run on the **source Windows VM**, not the failed-over VM, using
  **Windows PowerShell 5.1 or later as Administrator**.

## Customer procedure

1. Download [Invoke-OsUpgradeResync.ps1](Invoke-OsUpgradeResync.ps1) to the source
   VM and review it.
2. Open PowerShell **as Administrator** in the folder containing the script.
3. Run the following command:

   ```powershell
   .\Invoke-OsUpgradeResync.ps1
   ```

Running the script initiates mitigation for this OS-upgrade-related boot issue.
Allow corrective synchronization to complete and a new recovery point to become
available before validating recovery.

If the script reports that no changes were made or encounters an error, preserve
the full output and contact Microsoft Support.

For further assistance, contact Microsoft Support.
