# Prerequisites

## Build machine

!!! note "Build once, boot anywhere"
    You build the ISO once on a Windows machine, then boot it on any node (or on a separate machine on the management network).

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

NIC drivers for Dell AX 16G nodes are **bundled in the repo** under `drivers/dell-ax/` (extracted from Dell SBE bundle `5.0.2603.1641`). No separate download required.

| Driver | File | Version |
|---|---|---|
| Broadcom NetXtreme-E bnxt | `bnxtnd.inf` | 236.1.152.0 |
| Broadcom NetXtreme 5720 | `b57nd60a.inf` | 221.0.8.0 |
| Intel E810 (ice) | `icea.inf` | 1.17.73.0 |
| Intel E823 (scea) | `scea.inf` | 1.16.58.0 |
| Mellanox ConnectX mlx5 | `mlx5.inf` | 24.4.26429.0 |

## Network requirements

The Beacon image needs to reach Azure endpoints to run the full endpoint sweep. Ensure:

- Management VLAN access from the machine where Beacon boots
- Outbound HTTPS (443) to Azure endpoints (see [Endpoint List](../reference/endpoints.md))
- DNS resolution (UDP/TCP 53) — can be tested interactively if DNS is in question

## Validation config

Copy `src/config/validation-config.example.json` to `src/config/validation-config.json` before building and fill in your environment's values (DC IPs, gateway, DNS, node IPs, etc.).

```powershell title="Create your validation config"
Copy-Item src\config\validation-config.example.json src\config\validation-config.json
# Edit src\config\validation-config.json with your values
```

!!! warning
    `validation-config.json` is gitignored. Never commit it — it contains environment-specific IPs.
