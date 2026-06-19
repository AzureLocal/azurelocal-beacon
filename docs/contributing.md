# Contributing

## Standards

This repo follows the [AzureLocal platform standards](https://github.com/AzureLocal/platform/tree/main/docs/standards).

Key rules:

- PowerShell 7.4+ for build scripts; PS 5.1-compatible syntax for in-image scripts
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in all scripts
- `Write-Host` with color convention (Cyan=progress, Green=pass, Yellow=warn, Red=fail) for console output
- Commit format: `type(scope): short description` (feat, fix, docs, chore, refactor, test)
- All ADO work items referenced in commits with `AB#<id>`

## Branches

- Branch from `main`: `feature/`, `fix/`, `docs/`, `chore/`
- Open a PR — no direct commits to `main`
- Include `AB#<id>` in the PR title or description

## Updating the endpoint list

The endpoint list (`src/config/endpoints.json`) is generated from the markdown source files in `config/endpoints/`. Edit the markdown files and regenerate:

```powershell
.\src\Convert-EndpointsToJson.ps1 -Force
```

## Updating NIC drivers

Replace the files in `drivers/dell-ax/<family>/` with the new driver set from the SBE bundle (see [Dell AX NIC Drivers](drivers/dell-ax.md)) and update the version table in that doc.

## Building docs locally

```powershell
pip install -r requirements-docs.txt
mkdocs serve
```

Open `http://127.0.0.1:8000` to preview.

## Contact

Kristopher Turner — kris@hybridsolutions.cloud
