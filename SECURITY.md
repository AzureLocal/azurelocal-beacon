# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| v1.0.x | ✅ |
| pre-release | ⚠️ Best effort |

## Reporting a vulnerability

Report security vulnerabilities to **kris@hybridsolutions.cloud**.

Do **not** open a public GitHub issue for security vulnerabilities.

We aim to acknowledge reports within **2 business days** and provide a resolution or mitigation within **14 days**.

## Scope

- WinPE image build scripts
- Endpoint sweep logic and endpoints.json
- NIC driver injection
- Validation configuration handling

## Out of scope

- Third-party Microsoft modules (`AzStackHci.EnvironmentChecker`, `Az.Accounts`)
- Dell driver binaries — report driver vulnerabilities to Dell via [Dell Security Advisories](https://www.dell.com/support/kbdoc/en-us/000124654/dell-security-advisories-and-notices)
