# Contributing

See also [CONTRIBUTING.md](https://github.com/AzureLocal/azurelocal-beacon/blob/main/CONTRIBUTING.md) in the repository root.

## Standards

This repo follows the [AzureLocal platform standards](https://github.com/AzureLocal/platform/tree/main/docs/standards).

- PowerShell 7.4+ for build and maintenance scripts; **Windows PowerShell 5.1 compatible, ASCII-only** syntax for everything that runs in the image (`src/Start-*.ps1`, `src/lib/*.ps1`)
- `Set-StrictMode -Version Latest`; external commands and WinPE-dependent calls go through small wrappers so tests can mock them
- Commit format: `type(scope): short description` (feat, fix, docs, chore, refactor, test) and `AB#<id>` when a work item exists
- No secrets, tenant or subscription ids, and no customer or lab names in any committed file; example values only (`contoso.com`, `192.0.2.0/24`)

## Branches

Branch from `main` (`feature/`, `fix/`, `docs/`, `chore/`); open a PR; no direct commits to `main`.

## Checks to run before a PR

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-Pester -Path .\tests
Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
cd docs; npm install; npm run docs:build     # dead links fail the build
```

CI runs the same (`.github/workflows/ci.yml`), plus a Markdown link check.

## Updating the endpoint list

```powershell
.\src\Convert-EndpointsToJson.ps1 -Refresh -Strict -Force
```

Review the diff of `config/endpoints/learn/*.md` and `src/config/endpoints.json`. If a row is rejected the converter says why; fix the
parser or the source, do not hand-edit `endpoints.json`. Update the counts in `docs/reference/endpoints.md`.

## Updating the Environment Checker module

`scripts/Update-BeaconModules.ps1 -Version <new> -Refresh -UpdateLock`, then run the tests (they check the parameter names the
engine passes against the module's own function definitions) and review `tools/modules/modules.lock.json`.

## Updating NIC drivers

See [Dell AX NIC drivers](drivers/dell-ax.md): replace the files, update the table, run `scripts/New-DriverManifest.ps1`.

## Docs

The site is VitePress (`docs/`). Preview with `cd docs; npm run docs:dev`.

## Contact

Kristopher Turner - kris@hybridsolutions.cloud
