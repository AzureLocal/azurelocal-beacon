# Active Directory Deployment Validation

Select **option 1** from the Beacon main menu to validate readiness for an AD-joined Azure Local deployment.

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| Active Directory domain FQDN | `corp.improbability.cloud` | Yes |
| Domain controller IP(s) | `10.10.0.10, 10.10.0.11` | Yes |
| Target OU Distinguished Name | `OU=AzureLocal,DC=corp,DC=improbability,DC=cloud` | Optional |
| Deployment prefix (≤ 8 chars) | `azl` | Optional (default: `azl`) |
| Primary NTP/time source | `10.10.0.1` | Optional (default: `time.windows.com`) |

## Tests run

| Category | Tests |
|---|---|
| **1 — Network** | NIC status, IP assigned, gateway ping |
| **2 — DNS** | DNS TCP/UDP 53 reachability, forward resolution of Azure endpoints and AD domain FQDN, reverse lookups of DC IPs |
| **3 — NTP** | Clock skew check (must be < 5 minutes) |
| **4 — AD ports** | TCP probe per DC: LDAP 389, Kerberos 88, RPC 135, DNS 53, LDAPS 636; DNS SRV `_ldap._tcp.dc._msdcs.<domain>` |
| **5 — Endpoint sweep** | All 121 Azure Local + Arc + Dell endpoints (TCP + HTTPS for critical) |
| **9 — EnvChecker** | `Invoke-AzStackHciConnectivityValidation` (Microsoft's connectivity validator) |

## Active Directory preparation requirements

!!! warning "AD prep must be run before deployment — not before Beacon"
    Beacon tests AD **connectivity** (port probes + DNS SRV). It does not run `Invoke-AzStackHciExternalActiveDirectoryValidation` (the MS AD validator) because that requires RSAT/GPO modules not available in WinPE.

    Run the Microsoft AD validator from a domain-joined workstation or staging server post-OS as part of Stage 2-3 validation.

### Minimum AD requirements (from Microsoft)

- Dedicated OU for the Azure Local deployment
- Group Policy inheritance blocked at the OU
- LCM deployment user with delegated rights to the OU
- LCM user password: minimum 14 chars, uppercase + lowercase + numeral + special char
- LCM username must be unique per cluster (1-20 chars, no domain prefix)

```powershell title="Run from a domain-joined machine (Stage 2)"
Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery -Force
New-HciAdObjectsPreCreation `
    -AzureStackLCMUserCredential (Get-Credential) `
    -AsHciOUName 'OU=AzL-IIC-01,DC=corp,DC=improbability,DC=cloud'
```

## Arc integration (optional)

After AD validation completes, Beacon offers an optional Arc integration check. This requires an Azure device-code sign-in — a URL is printed and you enter the code on any browser.
