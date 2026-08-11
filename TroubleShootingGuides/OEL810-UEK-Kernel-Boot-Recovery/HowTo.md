# Recover an Oracle Linux 8 VM after a UEK kernel update

> [!IMPORTANT]
> Use this procedure only for an Azure Site Recovery-protected Oracle Linux 8 VM that stopped booting after a UEK kernel update.

The serial console might show an `involflt` panic:

```text
involflt: loading out-of-tree module taints kernel.
kernel BUG at arch/x86/kernel/alternative.c:392!
...
apply_alternatives
module_finalize
load_module
```

## Option 1: The VM can boot with an older kernel

1. In GRUB, select a previously working older kernel.
2. Press `e`, append `inmage=0` to the kernel command line, and press `Ctrl+X`.
3. If the VM reaches the login prompt, install the fixed kernel:

   ```sh
   sudo dnf clean metadata
   sudo dnf makecache --refresh
   sudo dnf install kernel-uek-5.15.0-322.203.3.5.el8uek.x86_64
   ```

4. Select the fixed kernel and reboot:

   ```sh
   sudo grubby --set-default /boot/vmlinuz-5.15.0-322.203.3.5.el8uek.x86_64
   sudo reboot
   ```

No `rd.break` or `/etc/fstab` change is required for this option.

## Option 2: The older kernel is blocked by mount failures

Use this option only if the older-kernel boot shows failures similar to:

```text
[FAILED] Failed to mount /boot/efi.
[FAILED] Failed to mount /datadisks/disk0.
[FAILED] Failed to mount /datadisks/disk1.
[DEPEND] Dependency failed for Local File Systems.
```

The normal emergency shell might also report that the root account is locked.

1. In GRUB, select the same older kernel.
2. Press `e`, append both parameters, and press `Ctrl+X`:

   ```text
   rd.break inmage=0
   ```

3. At the `switch_root:/#` prompt, make the installed root filesystem writable:

   ```sh
   mount -o remount,rw /sysroot
   ```

4. Back up `/etc/fstab`:

   ```sh
   cp -a /sysroot/etc/fstab /sysroot/etc/fstab.pre-uek-recovery
   ```

5. Edit the installed system's `/etc/fstab`:

   ```sh
   vi /sysroot/etc/fstab
   ```

   Temporarily comment only the entries that failed during boot, such as
   `/boot/efi` or the affected data disks. Do not comment out `/` or `/boot`.

6. Continue booting:

   ```sh
   sync
   exit
   ```

7. After the VM reaches the login prompt, install the fixed kernel:

   ```sh
   sudo dnf clean metadata
   sudo dnf makecache --refresh
   sudo dnf install kernel-uek-5.15.0-322.203.3.5.el8uek.x86_64
   ```

8. Restore `/etc/fstab` and verify the mounts:

   ```sh
   sudo cp -a /etc/fstab.pre-uek-recovery /etc/fstab
   sudo mount -av
   ```

9. Select the fixed kernel and reboot:

   ```sh
   sudo grubby --set-default /boot/vmlinuz-5.15.0-322.203.3.5.el8uek.x86_64
   sudo reboot
   ```

After reboot, confirm the expected kernel:

```sh
uname -r
```

Expected output:

```text
5.15.0-322.203.3.5.el8uek.x86_64
```
