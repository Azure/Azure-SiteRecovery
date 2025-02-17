# Announcement
For customers running Virtual Machines on Red Hat Enterprise Linux 8 (RHEL 8) with the 8_4 kernel series, we want to bring an important update to your attention.
Red Hat has recently released new kernels, starting from 4.18.0-305.148.1.el8_4. However, Azure Site Recovery (ASR) is currently incompatible with these new kernels. If you are planning to update your systems to this kernel version, please follow the steps below to avoid replication breakage and ensure uninterrupted ASR functionality:
# Execution Details
If you have already upgraded your Virtual Machines (VMs) with **Azure Site Recovery** (ASR) replication enabled to kernel version **4.18.0-305.148.1.el8_4** or any later **RHEL 8.4 kernel**, please follow the steps below to restore replication functionality and avoid disruptions:

**Note** - All these steps need to be run each time you reboot your source VM to ensure that the driver loads correctly after a VM reboot.
1. Download driver package for RHEL8.4 Operating system version
[DriversPackage_RHEL8](https://aka.ms/DriversPackage_RHEL8)
2. Extract the downloaded driver package.
3. Stop the agent service using below command:
    /usr/local/ASR/Vx/bin/stop
4. Copy the required kernel driver file from the extracted package to "/lib/modules/`uname -r`/kernel/drivers/char" path.
  Example: If the driver is required for 4.18.0-305.148.1.el8_4.x86_64, then copy the "involflt.ko.4.18.0-305.148.1.el8_4.x86_64" file from the extracted path and place it in the
           /lib/modules/4.18.0-305.148.1.el8_4.x86_64/kernel/drivers/char path and rename it as **involflt.ko**

  Also give execute permission to involflt.ko file
      chmod 755 involflt.ko
5. Execute depmod command
  Example: depmod 4.18.0-305.148.1.el8_4.x86_64
6. Load the driver by executing below command:
    modprobe -vs involflt
7. Verify if driver is loaded or not using below command:
  lsmod | grep involflt
8. Get the major number for driver and create a device entry for it.
  INVOLFLT_MAJ_NUM=`cat /proc/devices | grep involflt | awk '{print $1}'`
  mknod /dev/involflt c $INVOLFLT_MAJ_NUM 0
9. Start the service using below command:
  /usr/local/ASR/Vx/bin/start

If you are a new customer planning to replicate **Virtual Machines (VMs)** running **RHEL 8.4** with **kernel version 4.18.0-305.148.1.el8_4** or later, please follow the steps below to ensure successful replication with **Azure Site Recovery** (ASR):

**Note** - All these steps need to be run each time you reboot your source VM to ensure that the driver loads correctly after a VM reboot.

1. If cx has uninstalled the mobility agent or has the error "Failed to enable replication", do the disable replication from the portal and follow the below steps
2. Download driver package for RHEL8.4 Operating system version from the given link
  [DriversPackage_RHEL8](https://aka.ms/DriversPackage_RHEL8)
3. Extract the downloaded driver package.
4. Copy the required kernel driver file from the extracted package to "/lib/modules/`uname -r`/kernel/drivers/char" path.
    Example: If the driver is required for 4.18.0-305.148.1.el8_4.x86_64, then copy the "involflt.ko.4.18.0-305.148.1.el8_4.x86_64" file from the extracted path and place it in the /lib/modules/4.18.0-305.148.1.el8_4.x86_64/kernel/drivers/char path and rename it as **involflt.ko**
    Add execution permission to involflt.ko
    chmod 755 involflt.ko
5. Execute depmod command
   Example: depmod 4.18.0-305.148.1.el8_4.x86_64
6.Load the driver by executing below command:
    modprobe -vs involflt
7. Verify if driver is loaded or not using below command:
    lsmod | grep involflt
8. Get the major number for driver and create a device entry for it.
    INVOLFLT_MAJ_NUM=`cat /proc/devices | grep involflt | awk '{print $1}'`
    mknod /dev/involflt c $INVOLFLT_MAJ_NUM 0
9.Do the enable replication from the portal.

 
