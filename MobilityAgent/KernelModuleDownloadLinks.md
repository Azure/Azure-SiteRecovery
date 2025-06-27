# Support New Kernels with Downloadable Kernel Module

## Introduction

This document contains instructions on how to download and install ASR Mobility Agent Kernel Module to an already protected Linux machine where the kernel has been upgraded to a newer version that requires kernel module update. It does NOT apply to fresh protections or where Cx has already disabled replication of a previously protected machines.

## Scenario

If users upgrade their machines to the latest released kernels for which a new ASR Mobility Agent Kernel Module is required to continue the replication, the replication health will turn critical with below error message:

*The kernel version of the running operating system kernel on the source machine is not supported on the version of the Mobility Agent installed on the source machine.*

## Downd links

Each link is unique for a Linux distro and it is a tar.gz file.

## Download Links

Each link is unique for a Linux distro and it is a tar.gz file:

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
Please follow below steps to load the required kernel driver on the Source machine.

# Automated install

Use the following steps to install the kernel module on the replicating machine.

1. Login to the impacted replicating VM as root user.

2. Download driver package for respective Linux distro using the download links listed above.

    `# mkdir /root/asr-drivers`

    `# cd /root/asr-drivers`

    `# wget https://aka.ms/DriversPackage_UBUNTU24`

3. Download and copy the hotfix_install.sh file impacted replicating VM. Make sure the script file has execute permissions for user root.

    `# wget https://github.com/Azure/Azure-SiteRecovery/blob/main/MobilityAgent/hotfix_install.sh`
    
    `# chmod +x hotfix_install.sh`

4. run hotfix_install.sh

    Usage: ./hotfix_install.sh <path to dir where drivers package is downloaded>

    `# ./hotfix_install.sh /root/asr-drivers/`