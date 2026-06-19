# Standards

This repository follows the **Hybrid Cloud Solutions platform standards**.

| Standard | Reference |
|---|---|
| Governance | [docs/standards/governance.md](https://github.com/AzureLocal/platform/blob/main/docs/standards/governance.md) |
| Scripting (PowerShell) | [docs/standards/scripting.md](https://github.com/AzureLocal/platform/blob/main/docs/standards/scripting.md) |
| Documentation | [docs/standards/documentation.md](https://github.com/AzureLocal/platform/blob/main/docs/standards/documentation.md) |
| Variables and naming | [docs/standards/variables.md](https://github.com/AzureLocal/platform/blob/main/docs/standards/variables.md) |
| Claude Code | [docs/standards/claude-code.md](https://github.com/AzureLocal/platform/blob/main/docs/standards/claude-code.md) |

## Local conventions

- Build scripts (`src/Build-WinPEImage.ps1`, `src/Convert-EndpointsToJson.ps1`): PowerShell 7.4+
- In-image scripts (`src/Start-*.ps1`, `src/startnet.cmd`): PS 5.1-compatible (WinPE includes PS 5.1; PS 7 is bundled but PS 5.1 is the fallback)
- Commit format: `type(scope): description`
- ADO work items referenced with `AB#<id>` in commits and PR descriptions
