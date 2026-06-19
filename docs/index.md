---
hide:
  - navigation
---

# AzL Beacon

![AzL Beacon Banner](assets/images/azurelocal-beacon-banner.svg)

**Pre-deployment endpoint, network, and hardware readiness validation for Azure Local.**

AzL Beacon boots directly from an iDRAC virtual media session or USB drive — no OS, no domain join, no licensing — and verifies that the environment meets every Microsoft requirement before you begin an Azure Local deployment.

---

## What it validates

=== "Active Directory"

    - AD port reachability: LDAP 389/636, Kerberos 88, RPC 135, DNS 53
    - DNS SRV record: `_ldap._tcp.dc._msdcs.<domain>`
    - NTP time-skew check (Azure Local requires &lt; 5 min skew)
    - Azure endpoint sweep (critical + informational)
    - SSL deep-inspection detection
    - IP pool squatter scan

=== "Local Identity (AD-less)"

    - DNS resolution of management endpoints
    - Azure Key Vault endpoint reachability (TCP 443)
    - Azure endpoint sweep: Arc, HCI, Key Vault service endpoints
    - Networking subnet / reserved-range check
    - SSL deep-inspection detection
    - IP pool squatter scan

=== "Networking & Firewall"

    - Gateway reachability and physical NIC status
    - Full 121-endpoint sweep: Azure Local, Arc, Dell OEM
    - Service Bus WebSocket probe (Arc resource bridge)
    - NTP UDP port 123 probe
    - SSL/TLS deep-inspection detection (FortiGate)
    - Infrastructure device reachability (firewall, switch, iDRAC, OpenGear)
    - Hardware self-checks: TPM 2.0, Secure Boot, storage, NIC, CPU, memory

---

## Hardware support — v1.0.0-pre

| Vendor | Adapter | Driver | Version |
|---|---|---|---|
| Broadcom | NetXtreme-E 57400/57500 (bnxt) | `bnxtnd` | 236.1.152.0 |
| Broadcom | NetXtreme 5720 (1GbE LOM) | `b57nd60a` | 221.0.8.0 |
| Intel | E810 800-series | `icea` | 1.17.73.0 |
| Intel | E823 800-series | `scea` | 1.16.58.0 |
| Mellanox/NVIDIA | ConnectX (mlx5/WinOF-2) | `mlx5` | 24.4.26429.0 |

Source: Dell AX 16G SBE bundle `5.0.2603.1641`.

---

## Quick start

```powershell title="Build the ISO (Windows ADK + WinPE add-on required)"
# Clone the repo
git clone https://github.com/AzureLocal/azurelocal-beacon
cd azurelocal-beacon

# Build — Dell AX NIC drivers included; Admin elevation required
.\src\Build-WinPEImage.ps1
```

Boot the resulting `src/output/azl-validate-<date>.iso` via iDRAC virtual media or USB.

!!! tip "Air-gapped build"
    Supply a pre-downloaded PS7 zip and skip the module download:
    ```powershell
    .\src\Build-WinPEImage.ps1 -PS7ZipPath C:\downloads\PowerShell-7.4.6-win-x64.zip -SkipModuleDownload
    ```

---

## Validation lifecycle

| Stage | When | Tool |
|---|---|---|
| **Stage 1 — Pre-OS** | Before OS install, booting from Beacon ISO | AzL Beacon (this tool) |
| Stage 2 — Post-OS | After OS install, before Arc registration | AzStackHci.EnvironmentChecker on each node |
| Stage 3 — Pre-deploy | After Arc registration | Azure portal environment checker |
| Stage 4 — Deployment | During portal wizard | Built-in deployment validation |
| Stage 5 — Post-deploy | After deployment completes | Operational health checks |

---

## Project

- **Organization:** [AzureLocal](https://github.com/AzureLocal)
- **Repository:** [azurelocal-beacon](https://github.com/AzureLocal/azurelocal-beacon)
- **Platform:** [HCS Platform Engineering](https://github.com/AzureLocal/platform)
- **Owner:** Kristopher Turner — kris@hybridsolutions.cloud
