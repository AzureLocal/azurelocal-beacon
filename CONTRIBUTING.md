# Contributing to AzL Beacon

## Commit message format

```text
type(scope): short description
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test` (add `AB#<id>` when a work item exists).

```text
feat(validation): add NTP clock-skew check
fix(startnet): fall back to Windows PowerShell 5.1 when pwsh fails
docs(readme): update iDRAC boot steps
chore(endpoints): regenerate endpoints.json from the Learn-linked lists
```

## Branches

Use `feature/`, `fix/`, or `docs/` prefixes. PRs target `main`.

## Scripts

- Everything that runs inside the image (`src/Start-*.ps1`, `src/lib/*.ps1`, `src/startnet.cmd`) must run on **Windows PowerShell 5.1** and be ASCII only.
  Build and maintenance scripts (`src/Build-WinPEImage.ps1`, `src/Convert-EndpointsToJson.ps1`, `scripts/`) need PowerShell 7.
- `Set-StrictMode -Version Latest`; `$ErrorActionPreference = 'Stop'` (or `'Continue'` where intentional and commented).
- Put external commands (`curl.exe`, `nslookup.exe`, network sockets) behind small functions so tests can mock them.
- New behaviour needs a Pester test in `tests/`.

Checks (CI runs the same):

```powershell
Invoke-Pester -Path .\tests
Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

## Config files

- `src/config/validation-config.json` is per-engagement and **gitignored**. Never commit it.
- `src/config/validation-config.example.json` is the template (example values only). Keep it current.
- `src/config/endpoints.json` is generated: run `src/Convert-EndpointsToJson.ps1 -Refresh -Strict -Force`; never edit it by hand.

## No secrets, no private names

Never commit passwords, PSKs, tokens, tenant or subscription ids, real domain names or customer/lab names.
Use example values (`contoso.com`, `192.0.2.0/24`, GUIDs of zeros). The test suite fails on known private names.

## Releases

Versions are managed by release-please from conventional commits (`.release-please-manifest.json`, `src/lib/Beacon.Version.ps1`).
The version shown in the banner, the results JSON, the ISO name and the CHANGELOG is that one version.
