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

## Config keys (`validation-config.json`) and where they come from

The source of every engagement value is the Azure Local `infrastructure.yml` (azurelocal-toolkit variables registry, schema 5).
`Start-AzlValidation.ps1 -InfrastructureFile` reads it directly; for WinPE, `Build-WinPEImage.ps1 -InfrastructureFile`
(or `ConvertTo-BeaconValidationConfig.ps1`) writes `validation-config.json` from it. `-Plan` prints each value with its key.
Without an infrastructure file the menu collects the values at boot, or you copy `validation-config.example.json` and fill it in
(the file is gitignored: it holds site data).

| Key | Used by | infrastructure.yml key |
|---|---|---|
| `azureRegion` | Cat 4, Cat 5 | `azure.location` |
| `managementGateway` | Cat 1 | `networking.management.gateway` |
| `managementSubnetCidr` | Cat 5 Network validator | `networking.management.subnet` |
| `managementVlan` | menu | `networking.management.vlan_id` |
| `nodeIps` | Cat 1, Cat 5 | `nodes[].management.ip_address`, or the `nodes[].network_adapters[]` port with role `management` |
| `nodeFqdns` | Cat 2 | `nodes[].name` + `identity.active_directory.domain_fqdn` |
| `dnsServers` | Cat 2, Cat 3 | `networking.management.dns_servers` |
| `ntpServers` | Cat 1 | `networking.ntp_servers` (empty: the DCs, else time.windows.com) |
| `adDomainFqdn`, `adNetbios` | Cat 2, Cat 3 | `identity.active_directory.domain_fqdn`, `netbios_name` (empty when `scenario.identity` is `local_identity`) |
| `dcIps`, `dcFqdns` | Cat 1 (NTP), 2, 3 | `identity.active_directory.domain_controllers` (addresses and names) |
| `keyVaultName`, `keyVaultFqdn` | Cat 4 | `cluster.key_vault.name` (+ `vault.azure.net`, or `vault.usgovcloudapi.net` for `scenario.cloud: government`) |
| `clusterName` | banner, redaction | `cluster.name` |
| `proxyUrl`, `proxyBypass` | Cat 4, Cat 5 | `networking.outbound.proxy.url`, `bypass` (`scenario.outbound_path` proxy or proxy_arc_gateway); the Azure Firewall explicit proxy for `private_path` |
| `infraIpPools` | Cat 5 Network validator | `networking.management.infrastructure_pool` |
| `hostNetworkIntents` | Cat 5 Network validator | `networking.intents` (adapter names through `network_adapters[].os_name_override`) |
| `oem` | Cat 4 | Beacon setting; `dell` when `hardware.vendor` is Dell |
| `arcGatewayFqdn` | Cat 4, Cat 5 | Beacon setting: the registry names the Arc gateway resource (`networking.outbound.arc_gateway.name`), not its `<id>.gw.arc.azure.com` endpoint |
| `tlsInspectionHosts` | Cat 4 | Beacon setting, default `["login.microsoftonline.com", "management.azure.com"]` |
| `tcpConnectTimeoutMs`, `pingTimeoutMs` | all | Beacon settings, default `5000`, `2000` |
| `brand` | menu banner | Beacon setting, optional text |

The Beacon settings are the only keys Beacon keeps in its own config when it runs from `infrastructure.yml`; any other key there is ignored.

The Arc subscription, tenant and resource group are **not** written to a config file. With `-InfrastructureFile` the run uses
`azure.subscription_id`, `tenant_id`, `resource_group` and the node names (`nodes[].arc_machine_name`, else `name`) in memory;
otherwise they are asked for at run time. `ConvertTo-BeaconValidationConfig.ps1` writes them only with `-IncludeAzureTargets`.
