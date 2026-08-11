# Recover an Oracle Linux 8 VM after a UEK kernel update

> [!IMPORTANT]
> This procedure applies to **Oracle Linux 8 VMs using UEK Release 7** and was validated on Oracle Linux 8.10. Follow it **only when the VM boot issue started after a UEK kernel upgrade** and the serial-console symptoms match those documented below. Do not use these steps for another Oracle Linux release or for an unrelated emergency-mode, disk, filesystem, or generic Linux boot failure.

Use this procedure only when all of the following conditions apply:

1. The VM runs Oracle Linux 8 with UEK Release 7 and is protected by Azure Site Recovery.
2. The VM was upgraded to a newer UEK kernel immediately before the boot issue appeared.
3. The serial console shows either:
   - an `involflt.ko` panic that references `apply_alternatives()`, `module_finalize()`, and `load_module()`; or
   - a kernel-module loading failure followed by failures to mount `/boot/efi` or other configured disks.
4. Booting a previously working older kernel with `inmage=0` avoids the `involflt.ko` panic.

If the VM was not recently upgraded to a new kernel or the serial-console symptoms do not match either documented path, stop and investigate the actual boot error instead of applying this procedure.

This procedure restores operating-system access. It does not make the affected UEK kernel compatible with the Azure Site Recovery filter driver.

## Symptoms

### Kernel panic while loading the Azure Site Recovery driver

The serial console can contain a stack similar to the following:

```text
involflt: loading out-of-tree module taints kernel.
involflt: module verification failed: signature and/or required key missing - tainting kernel
------------[ cut here ]------------
kernel BUG at arch/x86/kernel/alternative.c:392!
invalid opcode: 0000 [#1] SMP PTI
...
Call Trace:
 apply_alternatives
 module_finalize
 load_module
 init_module_from_file
 idempotent_init_module
 __x64_sys_finit_module
```

The signature message only records kernel taint. The panic occurs while the kernel finalizes and patches the loaded module.

### Kernel-module loading and filesystem mount failures

Some affected boots might show a module-loading failure instead of, or before, the panic:

```text
[FAILED] Failed to start Load Kernel Modules.
See 'systemctl status systemd-modules-load.service' for details.
```

When kernel-module indexes are empty or unusable, the detailed service status can contain:

```text
systemd-modules-load: Failed to lookup alias 'msr': Function not implemented
systemd-modules-load.service: Failed with result 'exit-code'.
```

This can be followed by failures to load filesystem support and mount EFI or data-disk filesystems:

```text
Mounting /datadisks/disk1...
Mounting /datadisks/disk0...
Mounting /boot/efi...
[FAILED] Failed to mount /datadisks/disk1.
[FAILED] Failed to mount /datadisks/disk0.
[FAILED] Failed to mount /boot/efi.
[DEPEND] Dependency failed for Local File Systems.
```

### Older kernel enters emergency mode

After selecting an older kernel and adding `inmage=0`, the driver panic no longer occurs. However, mandatory `/etc/fstab` mounts can stop the boot:

```text
Mounting /datadisks/disk1...
Mounting /datadisks/disk0...
Mounting /boot/efi...
[FAILED] Failed to mount /datadisks/disk1.
[FAILED] Failed to mount /datadisks/disk0.
[FAILED] Failed to mount /boot/efi.
[DEPEND] Dependency failed for Local File Systems.
```

Cloud images commonly have a locked root password. Normal emergency mode then displays:

```text
Cannot open access to console, the root account is locked.
See sulogin(8) man page for more details.
```

Use `rd.break` as described below instead of trying to unlock the root account.

## Before starting

1. Confirm that the issue began after a UEK kernel upgrade and that the serial-console logs match the preceding symptoms.
2. Take a snapshot of the OS disk.
3. Ensure Azure Serial Console or equivalent boot-console access is available.
4. Identify an older kernel that booted successfully before the update.
5. Record every `/etc/fstab` entry that will be changed. Do not comment out the root filesystem entry.

## Recovery procedure

### 1. First try the older kernel with only `inmage=0`

1. Restart the VM and open the GRUB menu.
2. Select an older known-good kernel.
3. Press `e` to edit the selected entry.
4. Locate the line beginning with `linux`, `linux16`, or `linuxefi`.
5. Append this parameter to that line:

   ```text
   inmage=0
   ```

   `inmage=0` prevents the Azure Site Recovery boot logic from loading
   `involflt.ko`.

6. Press `Ctrl+X` to boot the edited entry.

The early boot log should show the older kernel and the parameter:

```text
Command line: ... vmlinuz-<older-kernel> ... inmage=0
```

If the VM reaches the normal login prompt, do not use `rd.break` and do not
modify `/etc/fstab`. Continue directly to
[Upgrade to the fixed kernel and restore normal boot](#upgrade-to-the-fixed-kernel-and-restore-normal-boot).

Proceed with the remaining `rd.break` and `/etc/fstab` recovery steps only if
the older-kernel boot displays the documented `/boot/efi` or data-disk mount
failures and enters emergency mode.

### 2. Only for mount failures: boot with `rd.break`

1. Restart the VM and select the same older known-good kernel in GRUB.
2. Press `e` and append both parameters to the kernel line:

   ```text
   rd.break inmage=0
   ```

   `rd.break` opens an initramfs shell before systemd requires
   emergency-mode root authentication.

3. Press `Ctrl+X` to boot the edited entry.

Confirm that the command line contains both parameters:

```text
Command line: ... vmlinuz-<older-kernel> ... rd.break inmage=0
```

Wait for this prompt:

```text
switch_root:/#
```

### 3. Make the installed root filesystem writable

The `/` filesystem at `switch_root:/#` is the temporary initramfs. The installed operating system is mounted at `/sysroot`.

```sh
mount -o remount,rw /sysroot
```

Confirm it is writable:

```sh
mount | grep ' /sysroot '
```

Expected output contains `(rw,`:

```text
/dev/mapper/<root-volume> on /sysroot type xfs (rw,...)
```

### 4. Back up and inspect `/etc/fstab`

Create a timestamped backup before editing:

```sh
cp -a /sysroot/etc/fstab "/sysroot/etc/fstab.pre-recovery.$(date +%Y%m%d%H%M%S)"
cat /sysroot/etc/fstab
```

If available, inspect detected devices and UUIDs:

```sh
lsblk -f
blkid
```

Identify only the entries that correspond to the mount failures printed during boot. Typical examples are:

```text
UUID=<efi-uuid>   /boot/efi         vfat  defaults,...  0 2
UUID=<disk0-uuid> /datadisks/disk0  ext4  defaults,...  1 2
UUID=<disk1-uuid> /datadisks/disk1  ext4  defaults,...  1 2
```

### 5. Temporarily disable the failing non-root mounts

Edit the installed system's file, not `/etc/fstab` in the temporary initramfs:

```sh
vi /sysroot/etc/fstab
```

Prefix only the failing non-root entries with `#`:

```text
#UUID=<efi-uuid>   /boot/efi         vfat  defaults,...  0 2
#UUID=<disk0-uuid> /datadisks/disk0  ext4  defaults,...  1 2
#UUID=<disk1-uuid> /datadisks/disk1  ext4  defaults,...  1 2
```

Do not comment out:

- `/`
- The root LVM logical volume
- `/boot`, unless its own mount was explicitly reported as failed and a separate recovery plan exists

Review the resulting file:

```sh
cat /sysroot/etc/fstab
```

### 6. Continue booting

Flush the change and leave the initramfs shell:

```sh
sync
exit
```

The boot should proceed through `Switch Root` and eventually reach the multi-user target:

```text
Reached target Switch Root.
Starting Switch Root...
...
Started Serial Getty on ttyS0.
Reached target Multi-User System.
```

## Optional: repair empty kernel-module indexes

Use this section if boot logs contain messages such as:

```text
Failed to lookup alias 'msr': Function not implemented
```

Check the running kernel's module indexes after the VM boots:

```sh
K=$(uname -r)
ls -l /lib/modules/$K/modules.{alias,alias.bin,dep,dep.bin}
```

If these files are zero bytes, rebuild them:

```sh
depmod -a "$K"
ls -lh /lib/modules/$K/modules.{alias,alias.bin,dep,dep.bin}
```

When repairing from `switch_root:/#` without entering a chroot, explicitly target the installed system:

```sh
K=$(uname -r)
depmod -b /sysroot -a "$K"
ls -lh /sysroot/lib/modules/$K/modules.{alias,alias.bin,dep,dep.bin}
```

Do not run a plain `depmod -a` from `switch_root:/#`; it can target the temporary initramfs instead of the installed operating system.

## Upgrade to the fixed kernel and restore normal boot

After the VM boots successfully on the older kernel, install the fixed Oracle UEK kernel:

```sh
sudo dnf clean metadata
sudo dnf makecache --refresh
sudo dnf repolist --enabled
sudo dnf list --showduplicates kernel-uek
sudo dnf install kernel-uek-5.15.0-322.203.3.5.el8uek.x86_64
```

Confirm that the enabled repositories include `ol8_UEKR7` and that
`5.15.0-322.203.3.5.el8uek` appears in the available package list before
running the installation.

If DNF initially reports that the package is unavailable, retry the metadata
refresh:

```sh
sudo dnf clean metadata
sudo dnf makecache --refresh
sudo dnf repoquery kernel-uek-5.15.0-322.203.3.5.el8uek.x86_64
```

If `repoquery` returns the package but installation still fails, check for
another active DNF or RPM transaction and retry after it completes:

```sh
ps -ef | grep -E '[d]nf|[r]pm'
```

Confirm that the kernel and its module directory are installed:

```sh
rpm -q kernel-uek-5.15.0-322.203.3.5.el8uek.x86_64
ls -ld /lib/modules/5.15.0-322.203.3.5.el8uek.x86_64
```

Rebuild and verify the module indexes:

```sh
FIXED_KERNEL=5.15.0-322.203.3.5.el8uek.x86_64
sudo depmod -a "$FIXED_KERNEL"
ls -lh /lib/modules/$FIXED_KERNEL/modules.{alias,alias.bin,dep,dep.bin}
```

The index files must be non-empty before rebooting.

### Restore any disabled mounts

If the mount-failure recovery path required changes to `/etc/fstab`, restore
those entries before booting the fixed kernel. If the VM booted successfully
with only `inmage=0`, skip this subsection because `/etc/fstab` was not
modified.

1. Compare the current devices with the saved `/etc/fstab` entries:

   ```sh
   lsblk -f
   blkid
   cat /etc/fstab
   ```

2. Determine why each mount failed. Common causes include a missing disk, changed UUID, delayed device discovery, an unavailable filesystem module, or a stale `/boot/efi` entry.
3. Restore one entry at a time and test it:

   ```sh
   cp -a /etc/fstab /etc/fstab.before-mount-restore
   vi /etc/fstab
   mount -av
   ```

4. For optional data disks, consider `nofail` and an appropriate device timeout so a missing data disk does not block operating-system boot:

   ```text
   defaults,nofail,x-systemd.device-timeout=30
   ```

5. Do not permanently suppress a required filesystem failure. Correct its device, UUID, filesystem, or mount configuration.

After `mount -av` succeeds, select the fixed kernel and reboot:

```sh
sudo grubby --set-default /boot/vmlinuz-5.15.0-322.203.3.5.el8uek.x86_64
sudo grubby --default-kernel
sudo reboot
```

The `rd.break` and `inmage=0` parameters added interactively in GRUB are temporary and should not be added to the persistent kernel command line.

After reboot, confirm the fixed kernel and restored mounts:

```sh
uname -r
findmnt /boot/efi
findmnt /datadisks/disk0
findmnt /datadisks/disk1
systemctl --failed
```

Expected kernel:

```text
5.15.0-322.203.3.5.el8uek.x86_64
```

## Important follow-up actions

- Keep the VM on the known-good older kernel until `kernel-uek-5.15.0-322.203.3.5.el8uek.x86_64` is installed and the restored mounts pass `mount -av`.
- Use `inmage=0` only for recovery or diagnostic boots where the driver must not load.
- Do not manually load `involflt.ko` on the affected older kernel package that produced the panic.
- Treat Azure Site Recovery replication as interrupted. Validate protection health and perform resynchronization if required after the operating system is stable.
- Preserve the original boot diagnostics and `/etc/fstab` backup for root-cause analysis.

## If `rd.break` is unavailable

Use an Azure repair VM:

1. Stop the affected VM and snapshot its OS disk.
2. Attach a copy of the OS disk to a healthy Linux VM.
3. Activate its LVM volumes if required and mount the root filesystem.
4. Back up and edit `<mount-path>/etc/fstab` using the same rules above.
5. Reattach the repaired disk and boot the affected VM using the older kernel with `inmage=0`.
