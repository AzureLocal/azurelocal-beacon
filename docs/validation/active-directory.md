# Active Directory deployment validation

Select **option 1** from the Beacon menu to validate readiness for an AD-joined Azure Local deployment.

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| Active Directory domain FQDN | `corp.contoso.com` | Yes |
| Domain controller IP(s) | `192.0.2.10, 192.0.2.11` | Yes |
| Target OU Distinguished Name | `OU=AzureLocal,DC=corp,DC=contoso,DC=com` | Optional |
| Deployment prefix (up to 8 chars) | `azl` | Optional (default `azl`) |

## Tests run

| Category | Tests |
|---|---|
| **1 - Network and time** | NIC status, IP assigned, gateway ping, **NTP/W32Time**: UDP/123 to the NTP source (the domain controllers unless `ntpServers` is set) with the clock offset; more than 5 minutes is a warning (Kerberos tolerance) |
| **2 - DNS** | DNS TCP/UDP 53, forward resolution of Azure endpoints and the AD domain, reverse lookups of the DC IPs |
| **3 - AD ports** | Per DC, TCP: 53, 88, 135, 389, 445, 464, 636, 3268, 3269, 9389. UDP 88, 389, 464 where testable. SRV `_ldap._tcp.dc._msdcs.<domain>`. RPC dynamic range documented as not scanned |
| **4 - Endpoint sweep** | Your region's Azure Local, Arc, ARB, AKS and optional OEM endpoints; public-IP and HTTPS-inspection checks |
| **5 - Environment Checker** | Connectivity and Network validators |
| **6 - Arc** | Optional, see [Arc readiness](arc-readiness.md) |

### The Active Directory firewall table

From the Learn *Active Directory* table (client ports 49152-65535 to the DC):

| Service | Port | What Beacon does |
|---|---|---|
| DNS | 53 TCP/UDP | TCP connect (UDP is tested in Category 2) |
| Kerberos | 88 TCP/UDP | TCP connect; UDP probe |
| RPC endpoint mapper | 135 TCP | TCP connect |
| LDAP / LDAP SSL | 389 TCP/UDP, 636 TCP | TCP connect; UDP 389 probe |
| Global catalog / SSL | 3268, 3269 TCP | TCP connect |
| SMB | 445 TCP | TCP connect |
| Kerberos password change | 464 TCP/UDP | TCP connect; UDP probe |
| AD Web Services | 9389 TCP | TCP connect |
| W32Time | 123 UDP | NTP query in Category 1 |
| RPC for LSA, SAM, NetLogon, FRS, DFSR | 49152-65535 TCP | **Not scanned**: 16,000 ports cannot be probed meaningfully. A `Skip` row reminds you to verify the firewall rule. |

UDP cannot prove that a port is open. A reply is `Pass`, an ICMP port-unreachable is `Fail`, and silence is `Skip`
("open or filtered") - Beacon does not call that a pass.

## Active Directory preparation

> [!WARNING]
> Beacon tests AD **connectivity** (ports, DNS SRV, time). It does not run `Invoke-AzStackHciExternalActiveDirectoryValidation`
> because that needs RSAT/GPO modules that are not available in WinPE. Run the Microsoft AD validator from a
> domain-joined workstation or staging server.

Minimum AD requirements (Microsoft): a dedicated OU, Group Policy inheritance blocked on it, a lifecycle (LCM) deployment user
with delegated rights, a 14+ character password, and a unique LCM user name per cluster.

```powershell
# Run from a domain-joined machine
Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery -Force
New-HciAdObjectsPreCreation -AzureStackLCMUserCredential (Get-Credential) -AsHciOUName 'OU=AzureLocal,DC=corp,DC=contoso,DC=com'
```
