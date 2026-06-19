# Category Reference

Detailed reference for all 12 validation categories in `Start-AzlValidation.ps1`.

| # | Category | Key checks | Critical failure? |
|---|---|---|---|
| 1 | **Basic Network** | NIC IP-enabled, gateway ping, first node ping | Yes — no network = no deployment |
| 2 | **DNS** | TCP/UDP 53 per DC, forward A-record for Azure + AD domain, reverse PTR for DC IPs | Yes |
| 3 | **NTP** | `w32tm /stripchart` skew — must be < `ntpMaxSkewSeconds` (default 300s = 5 min) | Yes |
| 4 | **Active Directory** | TCP: LDAP 389/636, Kerberos 88, RPC 135, DNS 53 per DC; DNS SRV `_ldap._tcp.dc._msdcs.<domain>` | Yes |
| 5 | **Endpoint Sweep** | TCP connect + HTTPS GET (for critical/HTTPS) to all 121 endpoints | Critical = Fail; Warning = Warn |
| 6 | **Infra Devices** | ICMP ping to firewall, switch, iDRAC, OpenGear device IPs | Warn (devices may be powered down) |
| 7 | **Service Bus** | TCP 443 to `*.servicebus.windows.net` host (if configured) | Skip if not configured |
| 8 | **NTP UDP 123** | Raw UDP NTP packet to `time.windows.com`, 48-byte response | Warn (not always firewalled) |
| 9 | **EnvChecker** | `Invoke-AzStackHciConnectivityValidation -PassThru` | Warn if module absent |
| 10 | **SSL Inspection** | TLS handshake root-CA chain: private/unknown root = deep inspection detected | Yes — blocks deployment |
| 11 | **Prereq Sanity** | IP pool squatter (ICMP + TCP 5985/5986/22), DNS-not-in-K8s-CIDR (`10.96.0.0/12`, `10.244.0.0/16`) | Yes for K8s overlap |
| 12 | **Hardware** | TPM 2.0 presence, Secure Boot enabled, storage pool absence, NIC consistency, CPU virtualization | Yes for TPM/Secure Boot |

## Config keys (validation-config.json)

| Key | Used by | Example |
|---|---|---|
| `managementGateway` | Cat-1 | `"10.10.0.1"` |
| `dnsServers` | Cat-2 | `["10.10.0.10"]` |
| `adDomainFqdn` | Cat-2, Cat-4 | `"corp.improbability.cloud"` |
| `dcIps` | Cat-2, Cat-4 | `["10.10.0.10", "10.10.0.11"]` |
| `nodeFqdns` | Cat-2 | `["azl-node1.corp.improbability.cloud"]` |
| `nodeIps` | Cat-1, Cat-11 | `["10.10.1.10"]` |
| `ntpServers.primary` | Cat-3 | `"time.windows.com"` |
| `ntpMaxSkewSeconds` | Cat-3 | `300` |
| `pingTimeoutMs` | Cat-1, Cat-6 | `2000` |
| `tcpConnectTimeoutMs` | Cat-2 – Cat-5 | `5000` |
| `infraDeviceIps` | Cat-6 | `[{"label":"FW","ip":"10.10.0.254","description":"FortiGate"}]` |
| `serviceBusProbeHost` | Cat-7 | `"mynamespace.servicebus.windows.net"` |
| `ntpUdpProbeHost` | Cat-8 | `"time.windows.com"` |
| `ipPoolStart` / `ipPoolEnd` | Cat-11 | `"10.10.1.100"` / `"10.10.1.120"` |
