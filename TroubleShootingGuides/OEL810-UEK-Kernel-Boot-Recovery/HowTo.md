# Recover an Oracle Linux VM that enters emergency mode after a UEK kernel update

Use this procedure when an Azure Site Recovery-protected Oracle Linux VM encounters both of the following conditions:

- Loading `involflt.ko` on a newly installed UEK kernel causes a kernel panic in `apply_alternatives()`.
- Booting an older kernel with `inmage=0` avoids the driver panic, but the VM enters emergency mode because one or more non-root filesystems cannot be mounted.

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

1. Take a snapshot of the OS disk.
2. Ensure Azure Serial Console or equivalent boot-console access is available.
3. Identify an older kernel that booted successfully before the update.
4. Record every `/etc/fstab` entry that will be changed. Do not comment out the root filesystem entry.

## Recovery procedure

### 1. Boot an older kernel and stop before `switch_root`

1. Restart the VM and open the GRUB menu.
2. Select an older known-good kernel.
3. Press `e` to edit the selected entry.
4. Locate the line beginning with `linux`, `linux16`, or `linuxefi`.
5. Append these parameters to that line:

   ```text
   rd.break inmage=0
   ```

   - `inmage=0` prevents the Azure Site Recovery boot logic from loading `involflt.ko`.
   - `rd.break` opens an initramfs shell before systemd requires emergency-mode root authentication.

6. Press `Ctrl+X` to boot the edited entry.

The early boot log should show the older kernel and both parameters:

```text
Command line: ... vmlinuz-<older-kernel> ... rd.break inmage=0
```

Wait for this prompt:

```text
switch_root:/#
```

### 2. Make the installed root filesystem writable

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

### 3. Back up and inspect `/etc/fstab`

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

### 4. Temporarily disable the failing non-root mounts

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

### 5. Continue booting

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

## Restore the disabled mounts

After access is restored:

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

## Important follow-up actions

- Keep the VM on the known-good older kernel until the affected UEK kernel and `involflt.ko` combination is supported.
- Continue using `inmage=0` while performing recovery or diagnostic boots where the driver must not load.
- Do not manually load `involflt.ko` on the affected kernel.
- Treat Azure Site Recovery replication as interrupted. Validate protection health and perform resynchronization if required after the operating system is stable.
- Preserve the original boot diagnostics and `/etc/fstab` backup for root-cause analysis.

## If `rd.break` is unavailable

Use an Azure repair VM:

1. Stop the affected VM and snapshot its OS disk.
2. Attach a copy of the OS disk to a healthy Linux VM.
3. Activate its LVM volumes if required and mount the root filesystem.
4. Back up and edit `<mount-path>/etc/fstab` using the same rules above.
5. Reattach the repaired disk and boot the affected VM using the older kernel with `inmage=0`.
