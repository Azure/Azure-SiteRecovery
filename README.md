# Announcement

For customers running Virtual Machines on Red Hat Enterprise Linux 8 (RHEL 8) with the 8_4 kernel series, we want to bring an important update to your attention. Red Hat has recently released new kernels, starting from 4.18.0-305.148.1.el8_4. However, Azure Site Recovery (ASR) is currently incompatible with these new kernels. If you are planning to update your systems to this kernel version, please follow the steps below to avoid replication breakage and ensure uninterrupted ASR functionality:

# Execution Details

If you have already upgraded your Virtual Machines (VMs) with **Azure Site Recovery** (ASR) replication enabled to kernel version **4.18.0-305.148.1.el8_4** or any later **RHEL 8.4 kernel**, please follow the steps below to restore replication functionality and avoid disruptions:

**Note**: All these steps need to be run each time you reboot your source VM to ensure that the driver loads correctly after a VM reboot.

1. Download the driver package for RHEL8.4 Operating system version: [DriversPackage_RHEL8](https://aka.ms/DriversPackage_RHEL8)
2. Extract the downloaded driver package.
3. Stop the agent service using the command:
  ```sh
  /usr/local/ASR/Vx/bin/stop
  ```
4. Copy the required kernel driver file from the extracted package to the `/lib/modules/$(uname -r)/kernel/drivers/char` path.
  - Example: If the driver is required for 4.18.0-305.148.1.el8_4.x86_64, then copy the `involflt.ko.4.18.0-305.148.1.el8_4.x86_64` file from the extracted path and place it in the `/lib/modules/4.18.0-305.148.1.el8_4.x86_64/kernel/drivers/char` path and rename it as **involflt.ko**.
5. Give execute permission to the `involflt.ko` file:
  ```sh
  chmod 755 /lib/modules/$(uname -r)/kernel/drivers/char/involflt.ko
  ```
6. Execute the `depmod` command:
  - Example: `depmod 4.18.0-305.148.1.el8_4.x86_64`
7. Load the driver by executing the command:
  ```sh
  modprobe -vs involflt
  ```
8. Verify if the driver is loaded using the command:
  ```sh
  lsmod | grep involflt
  ```
   Example output:
  ```sh
  involflt              892928  11
  ```
9. Get the major number for the driver and create a device entry for it:
  ```sh
  INVOLFLT_MAJ_NUM=$(cat /proc/devices | grep involflt | awk '{print $1}')
  mknod /dev/involflt c $INVOLFLT_MAJ_NUM 0
  ```
10. Start the service using the command:
  ```sh
  /usr/local/ASR/Vx/bin/start
  ```

If you are planning to replicate a new Virtual Machine running **RHEL 8.4** with **kernel version 4.18.0-305.148.1.el8_4** or later," please followthe steps below to ensure successful replication with **Azure Site Recovery** (ASR):

**Note**: All these steps need to be run each time you reboot your source VM to ensure that the driver loads correctly after a VM reboot.

1. If you have uninstalled the mobility agent or has the error "Failed to enable replication", disable replication from the portal and follow the steps below.
2. Download the driver package for RHEL8.4 Operating system version from the given link: [DriversPackage_RHEL8](https://aka.ms/DriversPackage_RHEL8)
3. Extract the downloaded driver package.
4. Copy the required kernel driver file from the extracted package to the `/lib/modules/$(uname -r)/kernel/drivers/char` path.
  - Example: If the driver is required for 4.18.0-305.148.1.el8_4.x86_64, then copy the `involflt.ko.4.18.0-305.148.1.el8_4.x86_64` file from the extracted path and place it in the `/lib/modules/4.18.0-305.148.1.el8_4.x86_64/kernel/drivers/char` path and rename it as **involflt.ko**.
5. Add execution permission to `involflt.ko`:
  ```sh
  chmod 755 /lib/modules/$(uname -r)/kernel/drivers/char/involflt.ko
  ```
6. Execute the `depmod` command:
  - Example: `depmod 4.18.0-305.148.1.el8_4.x86_64`
7. Load the driver by executing the command:
  ```sh
  modprobe -vs involflt
  ```
8. Verify if the driver is loaded using the command:
  ```sh
  lsmod | grep involflt
  ```
   Example output:
  ```sh
  involflt              892928  11
  ```
9. Get the major number for the driver and create a device entry for it:
  ```sh
  INVOLFLT_MAJ_NUM=$(cat /proc/devices | grep involflt | awk '{print $1}')
  mknod /dev/involflt c $INVOLFLT_MAJ_NUM 0
  ```
10. Enable replication from the portal.
