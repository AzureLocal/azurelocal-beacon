# Category Reference

Detailed reference for all 7 validation categories in `Start-AzlValidation.ps1`.

| # | Category | Key checks | Critical failure? |
|---|---|---|---|
| 1 | **Basic Network** | NIC IP-enabled, gateway ping, first node ping | Yes |
| 2 | **DNS** | TCP/UDP 53 per DNS server, forward A-record for Azure + AD domain, reverse PTR for DC IPs | Yes |
| 3 | **NTP** | `w32tm /stripchart` skew — must be < `ntpMaxSkewSeconds` (default 300s = 5 min) | Yes |
| 4 | **Active Directory** | TCP: LDAP 389/636, Kerberos 88, RPC 135, DNS 53 per DC; DNS SRV `_ldap._tcp.dc._msdcs.<domain>` | Yes (AD path only) |
| 5 | **Endpoint Sweep** | TCP connect + HTTPS GET to all endpoints from the 3 source links | Critical = Fail; Warning = Warn |
| 6 | **Environment Checker** | `Invoke-AzStackHciConnectivityValidation` + `Invoke-AzStackHciNetworkValidation` | Warn if module absent |
| 7 | **Arc Integration** | `Invoke-AzStackHciArcIntegrationValidation` (optional — requires Az login) | Skip if not authenticated |

## Endpoint sources (Category 5)

All endpoints in `config/endpoints.json` trace to one of three Microsoft/Dell sources:

| Source | Coverage |
|---|---|
| [Azure Local firewall requirements](https://github.com/MicrosoftDocs/azure-stack-docs/blob/main/azure-local/concepts/firewall-requirements.md) | Core Azure Local service endpoints |
| [EastUS HCI endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md) | Azure HCI endpoints for East US region |
| [Dell OEM endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/OEMEndpoints/Dell/DellAzureLocalEndpoints.md) | Dell-specific OEM endpoints |

## Which categories run per path

| Category | AD | Local Identity | Networking & Firewall | Full sweep |
|---|---|---|---|---|
| 1 Network | ✅ | ✅ | ✅ | ✅ |
| 2 DNS | ✅ | ✅ | ✅ | ✅ |
| 3 NTP | ✅ | ✅ | ✅ | ✅ |
| 4 AD ports | ✅ | ❌ | ❌ | AD sub-path only |
| 5 Endpoint sweep | ✅ | ✅ | ✅ | ✅ |
| 6 EnvChecker | ✅ | ✅ | ✅ | ✅ |
| 7 Arc | ⚠️ optional | ⚠️ optional | ⚠️ optional | ⚠️ optional |

## Config keys (validation-config.json)

| Key | Used by | Example |
|---|---|---|
| `managementGateway` | Cat-1 | `"10.10.0.1"` |
| `nodeIps` | Cat-1 | `["10.10.1.10"]` |
| `dnsServers` | Cat-2 | `["10.10.0.10"]` |
| `adDomainFqdn` | Cat-2, Cat-4 | `"corp.improbability.cloud"` |
| `dcIps` | Cat-2, Cat-4 | `["10.10.0.10", "10.10.0.11"]` |
| `nodeFqdns` | Cat-2 | `["azl-node1.corp.improbability.cloud"]` |
| `ntpServers.primary` | Cat-3 | `"time.windows.com"` |
| `ntpMaxSkewSeconds` | Cat-3 | `300` |
| `pingTimeoutMs` | Cat-1 | `2000` |
| `tcpConnectTimeoutMs` | Cat-2–5 | `5000` |
| `keyVaultFqdn` | Cat-5 (endpoint sweep) | `"kv-vault.vault.azure.net"` |
| `azureRegion` | Cat-6 (EnvChecker) | `"eastus"` |
