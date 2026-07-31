# Reconfigure Azure Site Recovery after an incorrect staging extension installation

Follow these steps only if the Azure Site Recovery extension installed on the protected Azure virtual machine (VM) uses the `Microsoft.Azure.SiteRecovery.Stage` publisher.

1. In the Azure portal, open the VM and select **Extensions + applications**.
2. Select each Site Recovery extension and verify that its **Type** contains `Microsoft.Azure.SiteRecovery.Stage`. If it does not, stop and do not perform the remaining steps.
3. Uninstall the Site Recovery extensions:
   - **Windows:** Select `SiteRecovery-Windows`, and then select **Uninstall**.
   - **Linux:** Select and uninstall both `SiteRecovery-Linux` and `SiteRecovery-Linux<Distro>`, where `<Distro>` identifies the Linux distribution.
4. Disable Azure Site Recovery replication for the VM from the Recovery Services vault.
5. Uninstall the Azure Site Recovery Mobility Service from the guest operating system:
   - **Windows:** In **Control Panel**, select **Programs**, select **Microsoft Azure Site Recovery Mobility Service/Master Target Server**, and then select **Uninstall**.
     After the uninstall completes, reboot the server.
   - **Linux:** Run:

     ```sh
     sudo /usr/local/ASR/uninstall.sh -Y
     ```

6. Enable replication for the VM again.
7. Confirm that replication becomes healthy and that the extension **Type** uses one of the following supported publishers:
   - `Microsoft.Azure.RecoveryServices.SiteRecovery`
   - `Microsoft.Azure.RecoveryServices.SiteRecovery2`
