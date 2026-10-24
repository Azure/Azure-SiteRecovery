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

The script discovers the agent installation directory from the registered
`svagents` service executable and checks that `drvutil.exe` exists. Before
making changes, it checks retained Windows Setup history for an OS build upgrade
on or after the detected ASR installation date.

If a qualifying upgrade cannot be confirmed, the script makes no changes.
Contact Microsoft Support if an upgrade is suspected but cannot be verified.
Otherwise, the script automatically performs the following sequence without a
confirmation prompt:

| Step | Action |
|---|---|
| 1 | Stop `svagents` and wait for it to stop. |
| 2 | Run `"<agent installation directory>\drvutil.exe" --stopf -stopall`. This stops filtering on all volumes. |
| 3 | Restart `svagents` in a `finally` block, including if the command fails, and wait for it to run. |

The expected command output is `Returned Success from stop All filtering`.
If the command or service restart fails, preserve the full output and contact
Microsoft Support.

The script prints a unique recovery run ID and records its start, filtering
result, and service restart request in the existing `svagents` logs while the
service is stopped. These records use the agent's normal log upload path and
include the script hash and Windows versions. Upload depends on agent logging,
connectivity, and log processing; a local record does not guarantee delivery.
The restart-request record does not confirm that the service restarted or that
synchronization completed. Preserve any telemetry warnings with the run ID.

## Verification

Confirm that replication resumes, corrective synchronization completes for the
protected disks including the OS disk, and a new recovery point is available.

For further assistance, contact Microsoft Support.
