# Dell AX 16G NIC Drivers

AzL Beacon bundles the network drivers for Dell AX 16G nodes extracted from the Dell Solution Builder Extension (SBE) package.

## Driver inventory

| Vendor | Adapter family | INF | Version | Date |
|---|---|---|---|---|
| Broadcom | NetXtreme-E 57400/57500 (bnxt) | `bnxtnd.inf` | 236.1.152.0 | 2025-12-17 |
| Broadcom | NetXtreme 5720 (1GbE LOM) | `b57nd60a.inf` | 221.0.8.0 | 2025-07-03 |
| Intel | E810 800-series (`ice` driver) | `icea.inf` | 1.17.73.0 | 2025-04-11 |
| Intel | E823 800-series (`scea` driver) | `scea.inf` | 1.16.58.0 | 2025-04-11 |
| Mellanox/NVIDIA | ConnectX mlx5/WinOF-2 | `mlx5.inf` | 24.4.26429.0 | 2024-04-16 |

## Source

All drivers were extracted from:

```
Bundle_SBE_Dell_AX-16G-45n0c_5.0.2603.1641.zip
└── DriversGE\Network\
    ├── Broadcom\5720\WYPPJ\        → drivers/dell-ax/broadcom-5720/
    ├── Broadcom\57400-57500\78X9T\ → drivers/dell-ax/broadcom-bnxt/
    ├── Intel\E810\J4YG9\           → drivers/dell-ax/intel-e810/
    ├── Intel\E823\J4YG9\           → drivers/dell-ax/intel-e823/
    └── Mellanox\CX\G6M58\          → drivers/dell-ax/mellanox-cx/
```

**SBE package:** `SBE_Dell_AX-16G-45n0c_5.0.2603.1641`  
**SBE build version:** `10.2601.1002.2028`  
**CreationDate:** 2026-03-19

## DISM injection

The build script injects all drivers recursively via DISM:

```powershell title="From Build-WinPEImage.ps1 (simplified)"
dism /Image:<mount> /Add-Driver /Driver:drivers\dell-ax /Recurse
```

All drivers are signed (`.cat` catalog included), so no `/ForceUnsigned` flag is needed.

## Supported models

| Dell model | Notes |
|---|---|
| AX660 | Supported |
| AX760 | Supported |
| AX4510c | Supported |
| AX4520c | Supported |
| APEXMC variants | Supported |

## Updating drivers

To update to a newer SBE bundle:

1. Download the new SBE zip from Dell/Azure Local update channel
2. Extract `DriversGE\Network\` into the five `drivers/dell-ax/` subdirectories, replacing existing files
3. Update the version table in this document
4. Rebuild the ISO

!!! tip "Dell firmware (not included)"
    The SBE bundle also contains network firmware DUPs (Broadcom FW 36.11.56.00, Mellanox ConnectX FW 26.41.10.00, Intel E810 FW 23.61.3). These are not injected into the Beacon image — firmware updates are applied through Dell SBE / Cluster-Aware Updating during the cluster update lifecycle.
