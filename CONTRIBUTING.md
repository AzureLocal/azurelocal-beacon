# Contributing to AzL Beacon

## Commit message format

```
type(scope): short description
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`

Examples:
```
feat(validation): add category 13 BGP route validation
fix(startnet): handle static IP prompt on DHCP timeout
docs(readme): update iDRAC boot steps for 9th gen
chore(endpoints): regenerate endpoints.json from 2504 source docs
```

## Branches

Use `feature/`, `fix/`, or `docs/` prefixes. PRs target `main`.

## Scripts

All PowerShell scripts must pass PSScriptAnalyzer at Warning/Error severity:

```powershell
Invoke-ScriptAnalyzer -Path src/*.ps1 -Severity Warning,Error
```

Scripts must use:
- `#Requires -Version 5.1` (or 7.4 for build scripts that need PS7 features)
- `Set-StrictMode -Version Latest`
- `$ErrorActionPreference = 'Stop'` (or `'Continue'` where intentional)

## Config files

- `src/config/validation-config.json` is per-engagement and **gitignored**. Never commit it.
- `src/config/validation-config.example.json` is the template. Keep it current.
- `src/config/endpoints.json` is pre-built Azure endpoint data — regenerate with `Convert-EndpointsToJson.ps1` when endpoint source files update.

## No secrets

Never commit IP addresses used as credentials, passwords, PSKs, tokens, or subscription IDs. Use example/placeholder values in all committed files.
