# Prerequisites

## Build machine

!!! note "Build once, boot on any Dell AX node"
    You build the ISO once on a Windows machine with ADK installed, then mount it via iDRAC virtual media on each Dell AX node.

| Requirement | Details |
|---|---|
| **OS** | Windows 10/11 or Windows Server 2019+ |
| **Windows ADK** | `winget install Microsoft.WindowsADK` |
| **WinPE Add-on** | `winget install Microsoft.ADKPEAddon` |
| **PowerShell** | 7.4+ (for the build script) |
| **Elevation** | Administrator — DISM requires it |
| **Internet** | Required for PS7 download and module pull (unless using `-PS7ZipPath -SkipModuleDownload`) |
| **Disk space** | ~2 GB for workspace + ISO |

## Dell AX NIC drivers

NIC drivers for Dell AX 16G nodes are **bundled in the repo** under `drivers/dell-ax/` (extracted from Dell SBE bundle `5.0.2603.1641`). No separate download required — the build script picks them up automatically.

| Driver | File | Version |
|---|---|---|
| Broadcom NetXtreme-E bnxt | `bnxtnd.inf` | 236.1.152.0 |
| Broadcom NetXtreme 5720 | `b57nd60a.inf` | 221.0.8.0 |
| Intel E810 (ice) | `icea.inf` | 1.17.73.0 |
| Intel E823 (scea) | `scea.inf` | 1.16.58.0 |
| Mellanox ConnectX mlx5 | `mlx5.inf` | 24.4.26429.0 |

## Network requirements

The Beacon image needs outbound access to Azure endpoints to run the endpoint sweep. Ensure the management VLAN where Beacon will boot has:

- Outbound HTTPS (443) to Azure endpoints (see [Endpoint List](../reference/endpoints.md))
- DNS resolution (UDP/TCP 53)

!!! tip "No pre-configuration required"
    All environment values (DC IPs, DNS servers, gateway, domain FQDN) are collected interactively by the Beacon menu at boot. Nothing needs to be filled in before building the ISO.
