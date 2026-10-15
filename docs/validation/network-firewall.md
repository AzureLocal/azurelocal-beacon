# Networking and Firewall validation

Select **option 3** from the Beacon menu for a focused network and firewall validation. Use **option 9** first to set the
region, a proxy or an Arc gateway.

## What it covers

Everything except the AD port tests (Category 3). Good for:

- verifying firewall policy before any identity configuration
- checking endpoint reachability from the management VLAN, through a proxy or an Arc gateway
- confirming DNS, NTP and the public-address and HTTPS-inspection conditions Learn calls out

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| Management gateway IP | `192.0.2.1` | Optional (taken from the network bootstrap when known) |
| DNS server IP(s) | `192.0.2.10` | Optional |

Settings (option 9): region, proxy URL and bypass list, Arc gateway FQDN, OEM list (`dell`), NTP servers.

## Tests run

| Category | Tests |
|---|---|
| **1 - Network and time** | NIC, IP, gateway ping, NTP and clock offset |
| **2 - DNS** | DNS TCP/UDP 53, forward resolution of key Azure endpoints |
| **4 - Endpoint sweep** | The region's Azure Local, Arc, ARB, AKS endpoints (plus OEM); `PublicIP-` and `TlsInspection-` checks |
| **5 - Environment Checker** | Connectivity validator (region, proxy and Arc gateway aware); Network validator when its inputs exist |
| **6 - Arc** | Optional |

## Proxy and Arc gateway

| Setting | Effect |
|---|---|
| `proxyUrl` | Endpoint rows are probed through the proxy with `CONNECT`; the proxy is TCP-checked; the TLS-inspection read goes through it too; passed to the Environment Checker |
| `proxyBypass` | Hosts that go direct: `host`, `*.domain`, `.domain`, `10.0.0.0/8`, `<local>` |
| `arcGatewayFqdn` | Arc gateway mode: rows with gateway support are skipped (the gateway carries them); the gateway endpoint is probed; passed as `-ARCGateway` to the Environment Checker |

## Firewall requirements

See [Endpoint list](../reference/endpoints.md) for the per-region counts and how each row is probed.

## Microsoft documentation

- [Azure Local firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements)
- [Azure Arc network requirements](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
