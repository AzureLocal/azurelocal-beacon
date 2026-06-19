# AzL Beacon

**Pre-deployment endpoint, network, and hardware readiness validation for Azure Local.**

Boots from iDRAC Virtual Media or USB — no installed OS, no domain join, no licensing required.
Boot it on bare metal before you touch the deployment wizard. Know your environment is ready.

---

## What it does

On boot, `Start-AzlValidation.ps1` runs automatically and sweeps 12 validation categories:

| # | Category | What it checks |
|---|---|---|
| 1 | Basic network | NIC up, IP assigned, gateway reachable |
| 2 | DNS | Forward/reverse lookups, TCP/UDP port 53, AD domain resolution |
| 3 | NTP | w32tm stripchart + clock skew check (5-minute limit) |
| 4 | Active Directory ports | LDAP 389, LDAPS 636, Kerberos 88, RPC 135, DNS 53, SRV records |
| 5 | Azure endpoint sweep | TCP + HTTPS probe for 120+ Arc, AKS, auth, monitoring, CRL endpoints |
| 6 | Infrastructure devices | Firewall, switches, iDRAC, OpenGear reachability |
| 7 | Service Bus WebSocket | TCP 443 to `*.servicebus.windows.net` (Arc resource bridge) |
| 8 | NTP UDP 123 | Raw UDP NTP packet probe |
| 9 | Environment Checker | Microsoft's `Invoke-AzStackHciConnectivityValidation` (official validator) |
| 10 | SSL inspection | Cert chain root authority — detects FortiGate deep inspection (deployment blocker) |
| 11 | Deployment prerequisites | IP pool squatter scan, DNS-not-in-K8s-range sanity check |
| 12 | Hardware self-checks | TPM 2.0, Secure Boot, disk count, storage pools, NIC count, CPU virt, memory |

Results land at `X:\results\` on the WinPE RAM drive in JSON format. Copy off before reboot.

---

## Prerequisites

### Build machine

| Requirement | Install |
|---|---|
| Windows ADK | `winget install Microsoft.WindowsADK` |
| WinPE Add-on | `winget install Microsoft.ADKPEAddon` |
| PowerShell 7.4+ | `winget install Microsoft.PowerShell` |
| Administrator rights | DISM mount requires elevation |
| Internet access | For PS7 download + `Save-Module` (skippable — see air-gap build) |

### NIC drivers (recommended)

Inject 25 GbE NIC drivers so ports come up on first boot. Export from a provisioned node:

```powershell
Export-WindowsDriver -Online -Destination C:\drivers
```

Or download the full driver pack for your hardware and point `-DriverPath` at the extracted folder.

---

## Quick start

### 1. Populate config

Copy `src/config/validation-config.example.json` to `src/config/validation-config.json` and fill in your deployment values (DNS, NTP, AD domain, node IPs, gateway, IP pool range).

Regenerate the Azure endpoint list if needed:

```powershell
.\src\Convert-EndpointsToJson.ps1
```

### 2. Build

```powershell
# Minimal — downloads PS7, no drivers
.\src\Build-WinPEImage.ps1

# Recommended — pre-exported drivers, cached PS7 zip
.\src\Build-WinPEImage.ps1 -DriverPath C:\drivers -PS7ZipPath C:\downloads\PowerShell-7.4.6-win-x64.zip

# Build ISO + write USB simultaneously
.\src\Build-WinPEImage.ps1 -DriverPath C:\drivers -BuildUSB -UsbDriveLetter F

# Air-gapped (no internet)
Save-Module -Name AzStackHci.EnvironmentChecker -Path C:\staging\Modules   # on internet-connected machine
.\src\Build-WinPEImage.ps1 -SkipModuleDownload -PS7ZipPath C:\downloads\PowerShell-7.4.6-win-x64.zip

# Dry run
.\src\Build-WinPEImage.ps1 -WhatIf
```

Output: `src/output/azl-validate-<yyyyMMdd>.iso`

### 3. Boot via iDRAC Virtual Media

1. Log in to the iDRAC web console.
2. Open **Virtual Console → Virtual Media → Connect Virtual Media**.
3. Under **Map CD/DVD**, select the ISO and click **Map Device**.
4. Reboot: power menu → one-time boot (F11) → **Virtual CD/DVD**.
5. WinPE loads, `startnet.cmd` runs, validation starts automatically.

To preserve results before reboot:

```cmd
:: Map a network share inside WinPE
net use Z: \\<server>\<share>
xcopy X:\results Z:\beacon-results /E /Y
```

---

## Repo layout

```
azurelocal-beacon/
├── src/
│   ├── Build-WinPEImage.ps1          # Build script — creates the bootable ISO
│   ├── Start-AzlValidation.ps1       # Validation engine — runs on boot
│   ├── Convert-EndpointsToJson.ps1   # Regenerates endpoints.json from markdown sources
│   ├── startnet.cmd                  # WinPE boot entry point
│   └── config/
│       ├── validation-config.example.json   # Template — copy and populate per engagement
│       └── endpoints.json                   # Azure endpoint list (pre-built, regenerate with Convert-*)
├── config/
│   └── endpoints/
│       ├── azurelocal-endpoints.md   # Azure Local service endpoints (source for Convert-*)
│       ├── arc-endpoints.md          # Arc agent + ARB endpoints
│       └── dell-endpoints.md         # Dell SBE endpoints
├── docs/
│   └── index.md                      # Validation lifecycle and coverage matrix
└── ...
```

---

## Validation lifecycle

AzL Beacon is **stage 1 of 5** in the Azure Local validation lifecycle:

| Stage | When | Tooling |
|---|---|---|
| **1 — Beacon (this tool)** | Before OS install, bare hardware | Custom sweep + `Invoke-AzStackHciConnectivityValidation` |
| 2 — Post-OS, pre-registration | After Azure Stack HCI OS on nodes | `Invoke-AzStackHciHardwareValidation`, `Invoke-AzStackHciSoftwareValidation`, `azcmagent check` |
| 3 — Pre-deployment | After AD prep | `Invoke-AzStackHciExternalActiveDirectoryValidation`, `Invoke-AzStackHciArcIntegrationValidation` |
| 4 — Portal wizard | Nodes with answer file | `Invoke-AzStackHciNetworkValidation -DeployAnswerFile` |
| 5 — Deployment | Cloud deployment (integrated) | All validators re-run automatically |

---

## Rebuild triggers

Rebuild the ISO when:
- `src/Start-AzlValidation.ps1` changes
- `src/config/validation-config.json` changes (engagement-specific values)
- `src/config/endpoints.json` changes (regenerate with `Convert-EndpointsToJson.ps1` after endpoint list updates)
- Driver versions change (re-export from node after firmware/driver updates)
- PowerShell 7 minor version bumps

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

MIT — see [LICENSE](LICENSE).
