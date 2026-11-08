# Prerequisites

## Build machine

You build the ISO once on a Windows machine with the ADK, then boot it on each node.

| Requirement | Details |
|---|---|
| **OS** | Windows 11 or Windows Server 2022/2025 |
| **Windows ADK** | `winget install Microsoft.WindowsADK` (tested line: 10.1.26100.x) |
| **WinPE Add-on** | `winget install Microsoft.ADKPEAddon` (same version as the ADK) |
| **PowerShell** | 7.4+ for the build script |
| **Elevation** | Administrator (DISM requires it) |
| **Internet** | To download PowerShell 7; not needed with `-PS7ZipPath` and `-PS7ZipSha256` |
| **Disk space** | About 15 GB free for workspace, ISO and ADK files |

The vendored Microsoft Environment Checker module (`tools/modules`, about 135 MB) is part of the repository; the build
does not download it. Verify it with `scripts/Update-BeaconModules.ps1`.

## NIC drivers

NIC drivers for Dell AX 16G nodes are bundled under `drivers/dell-ax/` (Dell Solution Builder Extension 5.0.2603.1641) and injected by default.
`drivers/driver-manifest.json` lists every file with its SHA256 and the INF versions. For other hardware see
[Dell AX NIC drivers](../drivers/dell-ax.md#other-oems).

| Driver | File | Version |
|---|---|---|
| Broadcom NetXtreme-E bnxt | `bnxtnd.inf` | 236.1.152.0 |
| Broadcom NetXtreme 5720 | `b57nd60a.inf` | 221.0.8.0 |
| Intel E810 | `icea.inf` | 1.17.73.0 |
| Intel E823 | `scea.inf` | 1.16.58.0 |
| Mellanox ConnectX mlx5 | `mlx5.inf` | 24.4.26429.0 |

## On the node (runtime)

| Requirement | Details |
|---|---|
| **Boot** | UEFI boot of the ISO from virtual media or USB; the image is WinPE amd64 (x64 hardware only) |
| **PowerShell** | PowerShell 7 is bundled in the image (downloaded and SHA256-verified at build time), so nothing is installed on the node |
| **Environment Checker** | `AzStackHci.EnvironmentChecker` is vendored and pinned in `tools/modules/modules.lock.json` (currently 10.2605.0.2006); no Az modules are used at runtime |
| **Credentials** | Nothing is stored in the image or the repository. The Arc readiness category uses an OAuth2 device-code sign-in from the menu; the token lives in memory only |
| **Ports from the node** | HTTPS 443 to the regional Azure endpoints and the sign-in/ARM endpoints (`login.microsoftonline.com`, `management.azure.com`; the `.us` equivalents for Azure Government); DNS 53 UDP/TCP; NTP 123 UDP; for the Active Directory category TCP 53/88/135/389/445/464/636/3268/3269/9389 and UDP 88/389/464 to a domain controller |

## Azure roles for the Arc readiness category

The signed-in account is checked against the resource group, and Beacon reports Pass, Warn or Fail:

- **Owner** on the resource group, or
- **Azure Connected Machine Onboarding** plus **Azure Connected Machine Resource Administrator** to register the Arc machines, and for the Azure Local deployment itself **Contributor** plus **User Access Administrator** (or **Role Based Access Control Administrator**).

The resource providers it checks as required: Microsoft.HybridCompute, Microsoft.GuestConfiguration, Microsoft.HybridConnectivity, Microsoft.AzureStackHCI, Microsoft.Kubernetes, Microsoft.KubernetesConfiguration, Microsoft.ExtendedLocation, Microsoft.ResourceConnector, Microsoft.Insights, Microsoft.Authorization (Microsoft.HybridContainerService only when AKS Arc is planned). Registering them needs permission to register providers on the subscription.

## Running the tests

`Invoke-Pester -Path .\tests` needs Pester 5.5 or later (the CI workflow installs `Pester` with `-MinimumVersion 5.5.0` and `PSScriptAnalyzer` 1.22.0 or later). No ADK is needed for the tests.
## Network requirements

The management VLAN where Beacon boots needs outbound HTTPS (443) to the Azure endpoints of your region
(see [Endpoint list](../reference/endpoints.md)), DNS (UDP/TCP 53), and NTP (UDP 123) to your time source.
HTTPS inspection must be off for these names (Learn: unsupported).

> [!TIP]
> **No pre-configuration required.** Domain, DC addresses, DNS, gateway, region, proxy and Arc inputs are collected by the menu at boot.
