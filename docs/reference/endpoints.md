# Endpoint list

Category 4 probes the outbound endpoints Microsoft documents for Azure Local, for **your region**.
Microsoft Learn ([Firewall requirements for Azure Local](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements))
links to one consolidated list per region (Azure Local, Arc-enabled servers, Arc resource bridge and AKS).
Beacon ships a snapshot of each list and compiles them into `src/config/endpoints.json` (schema 2.0).

## Regions and counts

| Region key | Display name | Entries | Critical | Warning | Informational | Source list (last updated) |
|---|---|---|---|---|---|---|
| `eastus` | East US | 83 | 49 | 29 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md) (Nov 27, 2025) |
| `westeurope` | West Europe | 80 | 48 | 27 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/WestEuropeendpoints/westeurope-hci-endpoints.md) (Nov 27, 2025) |
| `australiaeast` | Australia East | 79 | 47 | 27 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/AustraliaEastendpoints/AustraliaEast-hci-endpoints.md) (Nov 27, 2025) |
| `canadacentral` | Canada Central | 80 | 48 | 27 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/CanadaCentralEndpoints/canadacentral-hci-endpoints.md) (Nov 27, 2025) |
| `centralindia` | India Central | 79 | 47 | 27 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/IndiaCentralEndpoints/IndiaCentral-hci-endpoints.md) (Nov 27, 2025) |
| `southeastasia` | Southeast Asia | 80 | 48 | 27 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/SouthEastAsiaEndpoints/southeastasia-hci-endpoints.md) (Nov 27, 2025) |
| `japaneast` | Japan East | 80 | 47 | 28 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/JapanEastEndpoints/japaneast-hci-endpoints.md) (Nov 27, 2025) |
| `southcentralus` | South Central US | 80 | 47 | 28 | 5 | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/SouthCentralUSEndpoints/southcentralus-hci-endpoints.md) (Nov 27, 2025) |
| `usgovvirginia` | US Gov Virginia | 89 | 51 | 33 | 5 | [list](https://github.com/CristianEdwards/AzureStack-Tools/blob/master/HCI/usgovvirginia-hci-endpoints/usgovvirginia-hci-endpoints.md) (Aug 25, 2026) |
| OEM `dell` | Dell (optional) | 4 | | 4 | | [list](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/OEMEndpoints/Dell/DellAzureLocalEndpoints.md) (Mar 19, 2025) |

Counts are after splitting multi-host cells and merging duplicates. The US Gov Virginia list is the one Learn links to.
Select the region with `azureRegion` in the config, `-Region` on the engine, or menu option 9. An unknown or empty
region falls back to `eastus` and says so with a warning.

## Fields of an entry

`id`, `component`, `host`, `port`, `protocol` (`HTTPS`, `HTTP`, `UDP`), `path`, `wildcard`, `probeHost` and
`probeHostBasis` (`list` = another row of the same list matches the wildcard, `curated` = a documented stand-in),
`placeholder` (`arcGateway` or `keyVault`: substituted from config), `severity`, `phase` (`deployment`,
`post-deployment`, `both`), `requiredFor`, `arcGateway` (`yes` = carried by the Arc gateway, `registration` or `no` =
needed directly), `arcGatewayNote`, `probe`, `skipReason`, `notes`, `source`.

## How an endpoint is probed

| Case | Behaviour |
|---|---|
| Normal row | TCP connect; critical HTTPS rows also get an HTTPS request (any HTTP status counts). |
| Wildcard (`*.x`) | Probed through a representative host. With none, `Skip` (validate at the firewall). A `curated` stand-in can only produce a warning. |
| `yourarcgatewayendpointid...gw.arc.azure.com` | Replaced by `arcGatewayFqdn`; `Skip` when not configured. |
| `yourhcikeyvaultname...vault.azure.net` | Replaced by `keyVaultFqdn`; `Skip` when not configured. |
| Port 8084 | Never probed (`Skip`): Learn lists it for AKS Arc after deployment; it is a cluster-internal service port, not an outbound rule. |
| UDP 123 | Left to the dedicated NTP check in Category 1. |
| **Arc gateway mode** (`arcGatewayFqdn` set) | Rows whose gateway support is `yes` are skipped (the gateway carries them); the gateway FQDN and rows needed at registration or without gateway support are still probed. |
| **Proxy** (`proxyUrl` set) | HTTPS rows go through the proxy (`CONNECT`) unless the host matches `proxyBypass` (host, `*.domain`, `.domain`, `10.0.0.0/8`, `<local>`). The proxy itself is TCP-checked first. |

Severity: `critical` fails the check when unreachable, `warning` and `informational` only warn. Severity is
derived from the Learn columns (component, phase, port, notes) by rules in the converter, not copied from Learn.

## Two extra checks in Category 4

- **Public addresses.** Learn: Arc Private Link Scopes are not supported; `*.his.arc.azure.com`,
  `*.guestconfiguration.azure.com` and `*.dp.kubernetesconfiguration.azure.com` must resolve to public IPs. Beacon
  resolves every concrete host of those families in your region and fails any private, loopback, link-local, CGNAT or reserved address.
- **HTTPS inspection.** Learn: Azure Local does not support HTTPS inspection. For the hosts in `tlsInspectionHosts`
  (default `login.microsoftonline.com`, `management.azure.com`) Beacon completes a TLS 1.2 handshake with .NET
  (through the proxy if configured), reads the certificate chain without trusting it, and expects a Microsoft or
  DigiCert issuer somewhere on it. Any other leaf issuer is reported as *suspected inspection* (a warning with severity critical).
  This works without the WinPE certificate store because the chain is read, not validated. It cannot see inspection
  that re-signs with a Microsoft-looking name; the Environment Checker's own root CA test (Category 5) is the second opinion.

## Regenerating endpoints.json

```powershell
.\src\Convert-EndpointsToJson.ps1 -Force            # offline, from config/endpoints/learn/*.md
.\src\Convert-EndpointsToJson.ps1 -Refresh -Force   # download the lists again first (sources: config/endpoints/sources.json)
.\src\Convert-EndpointsToJson.ps1 -Refresh -Strict -Force   # additionally fail on any rejected row
```

The converter is strict: every row must yield a valid host name and a numeric port. Cells with several hosts
or ports become several entries; backticks and schemes are stripped; anything else (`Management network`, `SSH`,
`Kubernetes API server` ...) is **rejected and reported**, never turned into a guessed entry. Rejections are written
to the output (`rejected`) and printed as warnings. Tests parse every committed snapshot and a fixture of known bad rows offline.

## Microsoft documentation

- [Firewall requirements for Azure Local](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements)
- [Azure Arc-enabled servers network requirements](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
