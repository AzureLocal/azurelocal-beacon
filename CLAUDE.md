# azurelocal-beacon — Claude Code Context

## What this repo is

AzL Beacon — pre-deployment endpoint, network, and hardware readiness validation for Azure Local.
Bootable WinPE diagnostic image. No installed OS required.

Part of the [AzureLocal](https://github.com/AzureLocal) GitHub organization.

---

## Standards

Follows AzureLocal org standards defined in [platform](https://github.com/AzureLocal/platform).

Key rules:
- PowerShell 7+ for build scripts; PS 5.1-compatible for in-image scripts (WinPE constraint)
- `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`
- Commit format: `type(scope): description`
- No secrets, tokens, or credentials committed

---

## Key facts

| Fact | Value |
|---|---|
| Primary language | PowerShell + JSON |
| GitHub org | AzureLocal |
| ADO org | https://dev.azure.com/hybridcloudsolutions |
| ADO project | Azure Local Beacon |
| ADO area path | Azure Local Beacon |
| In-image scripts | Must be PS 5.1 compatible (WinPE runs PS 5.1 subset) |
| Build scripts | PS 7.4+ (runs on the build machine, not in WinPE) |

---

## Repo structure

```
src/
  Build-WinPEImage.ps1         # Builds the ISO (PS 7.4+, run on build machine as Administrator)
  Start-AzlBeacon.ps1          # Boot orchestrator — split menu (PS 5.1 compatible)
  Start-NetworkBootstrap.ps1   # DHCP detect / static IP prompt + connectivity verify (PS 5.1)
  Start-AzlValidation.ps1      # Validation engine bundled in the image (PS 5.1 compatible)
  Convert-EndpointsToJson.ps1  # Regenerates endpoints.json from markdown source files
  startnet.cmd                 # WinPE boot entry point → launches Start-AzlBeacon.ps1
  config/
    validation-config.example.json   # Template — copy to validation-config.json and populate
    endpoints.json                   # Pre-built Azure endpoint list
drivers/
  dell-ax/                     # Signed NIC drivers for Dell AX 16G nodes (from SBE 5.0.2603.1641)
    broadcom-5720/             # b57nd60a.inf — 1GbE LOM, 221.0.8.0
    broadcom-bnxt/             # bnxtnd.inf — 10/25/100GbE, 236.1.152.0
    intel-e810/                # icea.inf — 100GbE, 1.17.73.0
    intel-e823/                # scea.inf — 1.16.58.0
    mellanox-cx/               # mlx5.inf — ConnectX, 24.4.26429.0
config/
  endpoints/                   # Endpoint markdown source files (inputs to Convert-*)
    azurelocal-endpoints.md
    arc-endpoints.md
    dell-endpoints.md
docs/                          # MkDocs Material docs site
  index.md
  getting-started/
  validation/
  drivers/
  reference/
```

---

## Claude Code actions

**Run autonomously:**
- Read, search, and grep any file in this repo
- Write and edit PowerShell scripts, JSON config, and Markdown docs
- Run `Invoke-ScriptAnalyzer` on PS1 files
- `git add`, `git commit`, `git push`
- `gh` CLI for issues, PRs, releases

**Always confirm before:**
- Committing `src/config/validation-config.json` (gitignored — contains site-specific values)
- Any destructive git operations

---

## Build/test commands

```powershell
# Lint all scripts
Invoke-ScriptAnalyzer -Path src/*.ps1 -Severity Warning,Error

# Dry-run build (no changes)
.\src\Build-WinPEImage.ps1 -WhatIf

# Regenerate endpoint JSON
.\src\Convert-EndpointsToJson.ps1 -Force
```

---

## Owner

Kristopher Turner — kris@hybridsolutions.cloud
