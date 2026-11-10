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

### Search by kernel release

Use the [browser kernel search](../../site/kernel-search/README.md) to look up
the output of `uname -r` across both scenarios. Exact matching is the default;
optional partial matching and scenario, distro/release, and update version
filters help narrow results. The guide includes local preview and GitHub Pages
activation instructions; the public page requires a successful deployment.

Matches link to the original manifests at the indexed commit. They do not imply
cumulative support across updates or compatibility with a specific installed
agent. No matching entry means only that the query and filters found no
published entry, not that the kernel is necessarily unsupported.

## Contributing

For every kernel module update, add its supported-kernel manifests to the applicable scenario-specific `SupportedKernels/<version>/` path. Do not publish a kernel-only update as an A2A extension release or V2A Mobility Agent release.
