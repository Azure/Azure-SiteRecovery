# Support New Kernels with Downloadable Kernel Module

## Introduction

This document provides instructions to download and install the ASR Mobility Agent Kernel Module on a Linux machine where the kernel has been upgraded to a version not supported by the latest Mobility Agent.

ASR now supports new kernels by providing the required kernel module via the Microsoft Download Center (DLC). Customers must follow a few manual steps to install the ASR kernel module.

## Scenarios

1. **Upgrading a protected machine to a new kernel:**  
   If you upgrade a protected machine to a kernel not supported by the installed ASR Mobility Agent, replication will become critical and show the following error:

   > *The kernel version of the running operating system kernel on the source machine is not supported on the version of the mobility service installed on the source machine.*

2. **Enabling replication on a machine with an unsupported kernel:**  
   Enable Replication (ER) will fail with a message indicating the OS kernel is not supported.

   > *9.xx version of mobility service doesn't support the operating system kernel version < Y > running on the source machine. Please refer the list of operating systems supported by Azure Site Recovery : https://aka.ms/a2a_supported_linux_os_versions*

## Supported kernel versions

The supported kernel versions are listed below as per the replication scenario and the kernel module release version.

- [Azure To Azure](https://github.com/Azure/Azure-SiteRecovery/tree/main/MobilityAgent/AzureToAzure/SupportedKernels)

- [Onprem to Azure](https://github.com/Azure/Azure-SiteRecovery/tree/main/MobilityAgent/OnPremiseToAzure/SupportedKernels)

Please note that the supported kernel modules versions are compatible with the latest Mobility Agent version only. In case the Mobility Agent version is lower than the latest kernel module version, please upgrade the Mobility Agent to the latest version before installing the kernel module.

For example, if the latest kernel module version is 9.65 and the installed Mobility Agent version is 9.64, please upgrade the Mobility Agent to version 9.65 before installing the kernel modules of versions on 9.65.



## Download Links

Each link is unique for a Linux distribution and points to a `.tar.gz` file. These links point to packages containing latest kernel modules and are compatible with the latest Mobility Agent version.


- [Debian 11](https://aka.ms/DriversPackage_DEBIAN11)
- [Debian 12](https://aka.ms/DriversPackage_DEBIAN12)
- [RHEL 8](https://aka.ms/DriversPackage_RHEL8)
- [RHEL 9](https://aka.ms/DriversPackage_RHEL9)
- [SLES 15](https://aka.ms/DriversPackage_SLES15)
- [Ubuntu 18](https://aka.ms/DriversPackage_UBUNTU18)
- [Ubuntu 20](https://aka.ms/DriversPackage_UBUNTU20)
- [Ubuntu 22](https://aka.ms/DriversPackage_UBUNTU22)
- [Ubuntu 24](https://aka.ms/DriversPackage_UBUNTU24)

## Installation Instructions

Follow these steps to install the kernel module:

### 1. Prepare the Machine

- Log in as the root user.
- Create a directory for the driver package.

    ```bash
    # mkdir /root/asr-drivers
    # cd /root/asr-drivers
    ```

### 2. Download the Driver Package

#### If the machine has internet access, skip this step and proceed to Step 3.

#### If the machine does not have internet access:

- Download the driver package on a different machine and transfer it to the impacted machine.
- For example, download the package for Ubuntu 20 and copy it to the impacted machine:

    ```bash
    # wget https://aka.ms/DriversPackage_UBUNTU20 -O DriversPackage_UBUNTU20.tar.gz
    # scp DriversPackage_UBUNTU20.tar.gz user@impacted_machine:/root/asr-drivers/
    ```

### 3. Download the Installation Scripts

- Download the following scripts from the ASR GitHub repository:

    ```bash
    # wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/hotfix_install.sh?raw=true
    # wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/OS_details.sh?raw=true
    ```

- If the machine does not have internet access, download these scripts on a different machine and transfer them to the impacted machine.

### 4. Set Permissions

- Ensure the script files have execute permissions for the root user:

    ```bash
    # chmod +x hotfix_install.sh OS_details.sh
    ```

### 5. Extract the Driver Package for machines without internet access

- Extract the downloaded driver package:

    ```bash
    # tar -xzvf <driver-package-filename>.tar.gz -C /root/asr-drivers/
    ```

### 6. Install the Kernel Module

- Run the installation script to install the required kernel module. On machines with internet access, the script will automatically download the required driver package and installs it:

    ```bash
    # ./hotfix_install.sh /root/asr-drivers/
    ```

### 7. Post-Installation

- After successful completion, the ASR kernel module is installed.
- You can now enable replication for new protections.
- For existing protections, replication will automatically resume.

---

