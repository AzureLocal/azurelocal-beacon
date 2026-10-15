# AzL Beacon

**Pre-deployment endpoint, network and Arc readiness validation for Azure Local 12.2609 (latest).**

Boots from BMC virtual media or USB: no installed OS, no domain join, no licensing required.
Boot it on bare metal before you touch the deployment wizard. Know your environment is ready.
Beacon deliberately has **no drive check**: it validates the network, identity and Azure side only.

Documentation: <https://azurelocal.cloud/azurelocal-beacon/>

---

## What it does

On boot, `Start-AzlBeacon.ps1` presents a menu. Choose your deployment path; it calls `Start-AzlValidation.ps1` for the applicable
categories of these 6, grounded in Microsoft Learn:

| # | Category | What it checks |
|---|---|---|
| 1 | Basic network and time | NIC up, IP assigned, gateway, node ping, NTP/W32Time reachability and clock skew |
| 2 | DNS | Forward and reverse lookups, TCP/UDP 53, AD domain resolution |
| 3 | Active Directory | TCP 53/88/135/389/445/464/636/3268/3269/9389, UDP 88/389/464 where testable, DC SRV record (AD path only) |
| 4 | Azure endpoint sweep | The per-region endpoint list Learn links to (9 regions + optional Dell OEM), Arc gateway and proxy aware; Arc endpoints must resolve publicly; HTTPS-inspection detection |
| 5 | Environment Checker | `Invoke-AzStackHciConnectivityValidation` and `Invoke-AzStackHciNetworkValidation` (Microsoft's validators), failed checks itemised |
| 6 | Arc readiness | Device-code sign-in and Azure REST checks: resource providers, resource group, Arc roles, existing Arc machines. No Az modules, nothing stored |

Results land in `X:\results\` on the WinPE RAM drive as JSON (schema: `docs/reference/results.schema.json`), a log and an HTML report.
Export them from the menu (USB drive, SMB share or HTTPS) before reboot, optionally redacted.

See a full run with sample output: [walkthrough](docs/getting-started/walkthrough.md) and [examples/](examples/).

---

## Prerequisites

### Build machine

| Requirement | Install |
|---|---|
| Windows ADK | `winget install Microsoft.WindowsADK` |
| WinPE Add-on | `winget install Microsoft.ADKPEAddon` |
| PowerShell 7.4+ | `winget install Microsoft.PowerShell` |
| Administrator rights | DISM mount requires elevation |
| Internet access | Only to download PowerShell 7 (verified by SHA256); not needed with `-PS7ZipPath` and `-PS7ZipSha256` |

### NIC drivers

Dell AX 16G NIC drivers are bundled in `drivers/dell-ax/` (Dell SBE `5.0.2603.1641`; hashes in `drivers/driver-manifest.json`) and injected by
default. For other hardware supply your own: `-DriverPath C:\my-drivers` (see [drivers](docs/drivers/dell-ax.md#other-oems)).

---

## Quick start

> **First build?** Follow [docs/getting-started/verify-build.md](docs/getting-started/verify-build.md): install steps, expected output, a Hyper-V test and a bare-node
> test, and a checklist to record the first boot in the repository. The ISO has to be built and boot-verified on a Windows host with the ADK;
> it cannot be built in CI.

### 1. Check the repository

```powershell
pwsh -File .\scripts\Update-BeaconModules.ps1     # pinned, signed Environment Checker module
Invoke-Pester -Path .\tests                       # unit tests, no ADK needed
```

### 2. Build

```powershell
# Default: bundled drivers, PowerShell 7 downloaded and SHA256-verified
.\src\Build-WinPEImage.ps1

# Offline: verified local PowerShell 7 zip
.\src\Build-WinPEImage.ps1 -PS7ZipPath C:\downloads\PowerShell-7.6.6-win-x64.zip -PS7ZipSha256 <hash from hashes.sha256>

# ISO + USB stick (erases the stick)
.\src\Build-WinPEImage.ps1 -BuildUSB -UsbDriveLetter F

# Pre-flight only
.\src\Build-WinPEImage.ps1 -WhatIf
```

Output: `src/output/azl-beacon-<version>-<yyyyMMdd>.iso` plus `.build-manifest.json` (ADK, PowerShell 7, module, driver and script versions and hashes, ISO hash).

### 3. Boot

1. Mount the ISO as virtual media (Dell iDRAC: **Virtual Console > Virtual Media > Map CD/DVD**) or boot the USB stick.
2. One-time boot to the virtual CD/DVD or USB device (UEFI).
3. WinPE loads, `startnet.cmd` runs, the Beacon menu appears. Set region, proxy or Arc gateway with option 9 if needed.

### 4. Copy the results off

Menu option 8 copies the results to a USB drive, an SMB share or posts them over HTTPS, optionally redacted. Results contain
IP addresses, DC and host names, the domain and the node serial number, so redact before sharing.

---

## Repo layout

```text
azurelocal-beacon/
├── src/
│   ├── Build-WinPEImage.ps1          # Build script: creates the bootable ISO and its build manifest
│   ├── Start-AzlBeacon.ps1           # Menu
│   ├── Start-AzlValidation.ps1       # Validation engine
│   ├── Start-NetworkBootstrap.ps1    # DHCP / static address at boot
│   ├── Convert-EndpointsToJson.ps1   # Strict converter: Learn-linked lists -> endpoints.json
│   ├── startnet.cmd                  # WinPE boot entry point (template)
│   ├── lib/                          # Shared functions (version, net probes, Arc REST, results, ...)
│   └── config/                       # validation-config.example.json, endpoints.json (generated)
├── config/endpoints/                 # sources.json + learn/ snapshots of the per-region lists
├── scripts/                          # Update-BeaconModules.ps1, New-DriverManifest.ps1
├── tools/modules/                    # Vendored AzStackHci.EnvironmentChecker (pinned: modules.lock.json)
├── drivers/                          # NIC drivers + driver-manifest.json
├── tests/                            # Pester 5 tests
├── examples/                         # Sample results JSON and HTML report
└── docs/                             # VitePress site
```

---

## Validation lifecycle

AzL Beacon is **stage 1 of 5**:

| Stage | When | Tooling |
|---|---|---|
| **1 - Beacon (this tool)** | Before OS install, bare hardware | Custom sweep + Connectivity/Network validators + Arc REST checks |
| 2 - Post-OS, pre-registration | After the Azure Local OS is on the nodes | `Invoke-AzStackHciHardwareValidation`, `Invoke-AzStackHciSoftwareValidation`, `azcmagent check` |
| 3 - Pre-deployment | After AD prep | `Invoke-AzStackHciExternalActiveDirectoryValidation`, `Invoke-AzStackHciArcIntegrationValidation` |
| 4 - Portal wizard | Nodes with answer file | `Invoke-AzStackHciNetworkValidation -DeployAnswerFile` |
| 5 - Deployment | Cloud deployment | All validators re-run automatically |

---

## Rebuild triggers

Rebuild the ISO when `src/` scripts change, `src/config/endpoints.json` is regenerated, the module pin or drivers change, or you want a newer PowerShell 7.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
