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
| In-image scripts | Must be PS 5.1 compatible (WinPE runs PS 5.1 subset) |
| Build scripts | PS 7.4+ (runs on the build machine, not in WinPE) |

---

## Repo structure

```
src/
  Build-WinPEImage.ps1         # Builds the ISO (PS 7.4+, run on build machine as Administrator)
  Start-AzlValidation.ps1      # Validation engine bundled in the image (PS 5.1 compatible)
  Convert-EndpointsToJson.ps1  # Regenerates endpoints.json from markdown source files
  startnet.cmd                 # WinPE boot entry point
  config/
    validation-config.example.json   # Template — copy to validation-config.json and populate
    endpoints.json                   # Pre-built Azure endpoint list
config/
  endpoints/                   # Endpoint markdown source files (inputs to Convert-*)
    azurelocal-endpoints.md
    arc-endpoints.md
    dell-endpoints.md
docs/
  index.md                     # Validation lifecycle and coverage matrix
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
