# Support New Kernels with Downloadable Kernel Module

## Introduction

This document contains instructions on how to download and install ASR Mobility Agent Kernel Module to a Linux machine where the kernel has been upgraded to a newer version that is not supported by the current Mobility Agent version.

ASR has enhanced the new kernel support by providing the ASR Mobility Agent kernel module required to support new kernel on Microsoft Download Center (DLC). It requires customer to follow few manual steps to install the ASR kernel module.

## Scenarios

1. A customer has a protected machine that needs to upgrade to new kernel. But the installed ASR Mobility Agent version doesn't support it.

If users upgrade their protected machines to the latest released kernels which are not supported by the installed Source Agent build, replication will turn critical with below error message:

*The kernel version of the running operating system kernel on the source machine is not supported on the version of the mobility service installed on the source machine.*

2. A customer wants to enable replication on a machine that has kernel that is not supported by the latest release ASR Mobility Agent version.

In this case Enable Replication (ER) fails with a message that the OS kernel is not supported.

## Download links

Each link is unique for a Linux distro and it is a tar.gz file.


- [Debian 11](https://aka.ms/DriversPackage_DEBIAN11)
- [Debian 12](https://aka.ms/DriversPackage_DEBIAN12)
- [RHEL 8](https://aka.ms/DriversPackage_RHEL8)
- [RHEL 9](https://aka.ms/DriversPackage_RHEL9)
- [SLES 15](https://aka.ms/DriversPackage_SLES15)
- [Ubuntu 18](https://aka.ms/DriversPackage_UBUNTU18)
- [Ubuntu 20](https://aka.ms/DriversPackage_UBUNTU20)
- [Ubuntu 22](https://aka.ms/DriversPackage_UBUNTU22)
- [Ubuntu 24](https://aka.ms/DriversPackage_UBUNTU24)

## Install instructions


Use the following steps to install the kernel module on the machine.

1. Login to the machine as root user.

2. Create a directory to download the driver package.

    `# mkdir /root/asr-drivers`

    `# cd /root/asr-drivers`

3. In case the machine does not have internet access, download the files on a different machine and copy them to the impacted machine.

    a. For example, to download the driver package for Ubuntu 20, run the below command.

   `# wget https://aka.ms/DriversPackage_UBUNTU20 -O DriversPackage_UBUNTU20.tar.gz`

    b. Download the below two scripts from the ASR GitHub repository.

    `# wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/hotfix_install.sh`

    `# wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/OS_details.sh`

    c. Copy the files to the impacted machine using scp or any other method.

    d. Make sure the script files have execute permissions for user root.

    `# chmod +x hotfix_install.sh OS_details.sh`

    e. Place the driver package in a directory on the impacted machine (e.g. /root/asr-drivers/).

    f. Extract the driver package on the impacted machine.
        `# tar -xzvf <driver-package-filename>.tar.gz -C /root/asr-drivers/`

4. If the machine has internet access, you can directly download the script files on the impacted machine. The script will download the driver package required for the OS distribution and version.

    a. Download the below two scripts from the ASR GitHub repository.
     
    `# wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/hotfix_install.sh`

    `# wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/OS_details.sh`

    b. Make sure the script files have execute permissions for user root.

    `# chmod +x hotfix_install.sh OS_details.sh`

5. Run hotfix_install.sh to install the required kernel module.

    Usage: ./hotfix_install.sh < path to dir where drivers package is downloaded >

    `# ./hotfix_install.sh /root/asr-drivers/`

6. Once the script completes successfully, the ASR kernel module is installed on the machine. You can now Enable Replication (ER) for new protections. For existing protections, the replication will automatically resume.