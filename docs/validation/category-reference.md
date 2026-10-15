# Category reference

Detail for the 6 categories in `Start-AzlValidation.ps1`. Parameters: `-Categories 1,2,4`, `-Region`, `-ProxyUrl`, `-ProxyBypass`,
`-ArcGatewayFqdn`, `-SkipEnvironmentChecker`, `-SkipArc`, `-Redact`, `-ExportTo`, `-ArcSubscriptionId`, `-ArcTenantId`, `-ArcResourceGroup`, `-ArcNodeNames`.
Exit code: `0` no failure, `1` at least one `Fail`, `2` no checks ran.

| # | Category | Key checks | Failure means |
|---|---|---|---|
| 1 | **Basic network and time** | NIC IP-enabled, gateway ping, first node ping, NTP reachability (UDP/123) and clock offset | NIC and gateway: `Fail`. Node ping and NTP: `Warn`. Offset over 5 minutes: `Warn` |
| 2 | **DNS** | TCP/UDP 53 per DNS server, forward A records for Azure and the AD domain, reverse PTR for DC IPs | TCP 53, forward Azure/AD and DC reverse: `Fail`. Node FQDNs: `Warn` (expected before deployment) |
| 3 | **Active Directory** | TCP 53/88/135/389/445/464/636/3268/3269/9389 per DC, UDP 88/389/464 where testable, SRV record | TCP port or SRV: `Fail`. UDP: `Pass` on reply, `Fail` on ICMP unreachable, else `Skip` |
| 4 | **Endpoint sweep** | Region list TCP (+HTTPS for critical), proxy/gateway aware; public IPs for Arc endpoints; HTTPS-inspection read | Critical endpoint or private Arc address: `Fail`. Others: `Warn`. Suspected inspection: `Warn` with severity `critical` |
| 5 | **Environment Checker** | Connectivity and Network validators, itemised | `Fail` for critical failed checks; `Warn` for the rest; module problems `Warn` |
| 6 | **Arc readiness** | Sign-in, subscription, resource providers, resource group, roles, existing Arc machines | Unregistered provider, missing roles, sign-in failure: `Fail` |

## Which categories run per path

| Category | AD | Local Identity | Networking and Firewall | Full sweep |
|---|---|---|---|---|
| 1 Network and time | yes | yes | yes | yes |
| 2 DNS | yes | yes | yes | yes |
| 3 AD ports | yes | no | no | AD sub-path only |
| 4 Endpoint sweep | yes | yes | yes | yes |
| 5 Environment Checker | yes | yes | yes | yes |
| 6 Arc readiness | optional | optional | optional | optional |

## Config keys (`validation-config.json`)

Collected by the menu at boot; for a pre-baked image copy `validation-config.example.json` and fill it in
(the file is gitignored: it holds site data).

| Key | Used by | Example |
|---|---|---|
| `azureRegion` | Cat 4, Cat 5 | `eastus` |
| `oem` | Cat 4 | `dell` or empty |
| `managementGateway` | Cat 1 | `192.0.2.1` |
| `nodeIps` | Cat 1, Cat 5 | `["192.0.2.21"]` |
| `dnsServers` | Cat 2, Cat 3 | `["192.0.2.10"]` |
| `adDomainFqdn` | Cat 2, Cat 3 | `corp.contoso.com` |
| `dcIps` | Cat 1 (NTP), 2, 3 | `["192.0.2.10", "192.0.2.11"]` |
| `nodeFqdns` | Cat 2 | `["node-01.corp.contoso.com"]` |
| `ntpServers` | Cat 1 | `[]` (DCs, else time.windows.com) |
| `keyVaultFqdn` | Cat 4 | `kv-example-01.vault.azure.net` |
| `proxyUrl`, `proxyBypass` | Cat 4, Cat 5 | `http://proxy.example.com:8080`, `["*.corp.contoso.com"]` |
| `arcGatewayFqdn` | Cat 4, Cat 5 | `<id>.gw.arc.azure.com` |
| `tlsInspectionHosts` | Cat 4 | `["login.microsoftonline.com", "management.azure.com"]` |
| `infraIpPools`, `managementSubnetCidr`, `hostNetworkIntents` | Cat 5 Network validator | see example file |
| `tcpConnectTimeoutMs`, `pingTimeoutMs` | all | `5000`, `2000` |
| `brand` | menu banner | optional text |

Arc subscription, tenant and resource group are **not** config keys: they are asked for at run time and never stored.
