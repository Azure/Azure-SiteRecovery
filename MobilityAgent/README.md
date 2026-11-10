# Azure Site Recovery Mobility Agent

Choose the release type that matches your replication scenario and task:

| Release type | Use this for | Content |
| --- | --- | --- |
| [A2A Extension Releases](AzureToAzure/README.md) | Azure-to-Azure (A2A) replication | Information about Mobility Service extension releases delivered through Azure. |
| [V2A Mobility Agent Releases](OnPremiseToAzure/README.md) | On-premises-to-Azure (V2A) replication | Full Mobility Agent installer download links. |
| [Common Kernel Module Updates](KernelModuleUpdates/README.md) | A2A and V2A Linux machines | Kernel module downloads, installation instructions, and scenario-specific supported-kernel lists. |

Kernel module updates are published more frequently than A2A or V2A agent releases. A version under a `SupportedKernels` folder identifies a kernel module update and does not necessarily indicate a new extension or full Mobility Agent release.

## Search Linux kernels

The [browser kernel search](../site/kernel-search/README.md) provides exact or
partial lookup across the A2A and V2A manifests, with scenario, distro/release,
and kernel module update version filters. The setup guide explains how to open
the deployed page once GitHub Pages is enabled, or preview it locally.

Results report explicit manifest entries, not inferred compatibility with an
installed agent. A missing entry is not proof that a kernel is unsupported.
