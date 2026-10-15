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

## Network requirements

The management VLAN where Beacon boots needs outbound HTTPS (443) to the Azure endpoints of your region
(see [Endpoint list](../reference/endpoints.md)), DNS (UDP/TCP 53), and NTP (UDP 123) to your time source.
HTTPS inspection must be off for these names (Learn: unsupported).

> [!TIP]
> **No pre-configuration required.** Domain, DC addresses, DNS, gateway, region, proxy and Arc inputs are collected by the menu at boot.
