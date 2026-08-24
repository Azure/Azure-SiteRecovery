# Common Kernel Module Updates

Kernel module updates add support for newer Linux kernels without publishing a new A2A extension or V2A Mobility Agent release. The downloadable modules are common to both scenarios, with separate supported-kernel lists for A2A and V2A.

## Downloads and installation

- [Download and install a kernel module](../KernelModuleDownloadLinks.md)
- [`hotfix_install.sh`](../hotfix_install.sh)
- [`OS_details.sh`](../OS_details.sh)

Kernel module packages are compatible with the latest applicable Mobility Agent version. Follow the upgrade guidance in the installation document before installing a module.

## Supported kernels

- [A2A supported-kernel lists](../AzureToAzure/SupportedKernels)
- [V2A supported-kernel lists](../OnPremiseToAzure/SupportedKernels)

Each version directory under `SupportedKernels` represents a kernel module update and contains the manifests published with that update. A directory may contain only the distributions updated in that drop, so its contents can be intentionally sparse.

## Contributing

For every kernel module update, add its supported-kernel manifests to the applicable scenario-specific `SupportedKernels/<version>/` path. Do not publish a kernel-only update as an A2A extension release or V2A Mobility Agent release.
