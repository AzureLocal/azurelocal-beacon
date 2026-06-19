# AzL Beacon — Validation Lifecycle and Coverage Matrix

## Validation stages

AzL Beacon is stage 1 of 5 in the Azure Local pre-deployment validation lifecycle.

| Stage | Environment | When | Tooling |
|---|---|---|---|
| **1 — Beacon** | WinPE (iDRAC or USB) | Before OS install | Custom sweep + `Invoke-AzStackHciConnectivityValidation` |
| 2 — Post-OS | Azure Stack HCI OS on nodes | After OS install, before Arc | `Invoke-AzStackHciHardwareValidation`, `Invoke-AzStackHciSoftwareValidation`, `azcmagent check` |
| 3 — Pre-deployment | Workstation / mgmt VM | After AD prep | `Invoke-AzStackHciExternalActiveDirectoryValidation`, `Invoke-AzStackHciArcIntegrationValidation` |
| 4 — Portal wizard | Nodes with answer file | During portal deployment wizard | `Invoke-AzStackHciNetworkValidation -DeployAnswerFile` |
| 5 — Deployment | Cloud (integrated) | During cloud deployment | All validators re-run automatically |

## Stage 1 coverage matrix

### Category 1 — Basic network
- NIC up with IP assigned
- Default gateway ping
- Management subnet node ping (warn-only — nodes may be unpowered)

### Category 2 — DNS
- TCP port 53 reachability to all DNS servers
- UDP port 53 probe
- Forward lookup: `login.microsoftonline.com`, `management.azure.com`
- Forward lookup: AD domain FQDN
- Forward lookup: node FQDNs (warn-only — pre-domain-join)
- Reverse lookup: DC IPs

### Category 3 — NTP
- `w32tm /stripchart` to primary and secondary NTP servers
- Clock skew check (< 300 seconds; hard limit for Azure Local deployment)

### Category 4 — Active Directory ports
- LDAP (TCP 389), LDAPS (TCP 636), Kerberos (TCP 88), RPC mapper (TCP 135), DNS (TCP 53) to each DC
- SRV record: `_ldap._tcp.dc._msdcs.<domain>`

### Category 5 — Azure endpoint sweep
- TCP connect + HTTPS probe to 120+ endpoints across: Arc, AKS, ARB, auth, monitoring, CRLs, updates, Dell SBE
- Severity-based: critical endpoints fail-hard; warning endpoints warn
- Wildcard entries use documented representative probe hosts

### Category 6 — Infrastructure device reachability
- ICMP ping to: firewalls, switches, iDRAC consoles, OpenGear OOB console

### Category 7 — Service Bus WebSocket
- TCP 443 to configured `serviceBusProbeHost`
- Skip with guidance note if not configured (host is instance-specific, created at deploy time)

### Category 8 — NTP UDP 123
- Raw UDP NTP packet probe to `time.windows.com`

### Category 9 — Microsoft Environment Checker
- `Import-Module AzStackHci.EnvironmentChecker` (bundled offline in image)
- `Invoke-AzStackHciConnectivityValidation -PassThru`
- Report harvested to `X:\results\AzStackHciEnvironmentReport.json`
- Graceful degradation if module incompatible with WinPE PS subset

### Category 10 — SSL inspection detection
- TLS handshake + cert chain root authority check
- Private/unknown root CA = FortiGate (or other MITM proxy) active = deployment blocker

### Category 11 — Deployment prerequisites
- Management IP pool scan: ICMP + TCP 5985/5986/22 for squatters in reserved node range
- DNS server not inside Kubernetes reserved CIDRs (10.96.0.0/12, 10.244.0.0/16)
- AD domain FQDN resolves
- Storage VLAN echo (informational — cannot probe from WinPE)

### Category 12 — Hardware self-checks
- TPM 2.0 (via `Win32_Tpm`)
- Secure Boot (via `Confirm-SecureBootUEFI`)
- Physical disk count (≥ 3: boot + 2 data)
- Existing storage pools (must be zero before S2D)
- Physical NIC count (≥ 2)
- CPU virtualisation enabled
- Memory ≥ 32 GB

## Mapping to Microsoft official validators

| Beacon category | Equivalent official validator |
|---|---|
| Cat 5 endpoint sweep | `Invoke-AzStackHciConnectivityValidation` (also bundled as Cat 9) |
| Cat 4 AD ports + SRV | `Invoke-AzStackHciExternalActiveDirectoryValidation` (stage 3) |
| Cat 12 hardware | `Invoke-AzStackHciHardwareValidation` (stage 2) |
| Cat 11 IP pool scan | `Invoke-AzStackHciNetworkValidation` (stage 4) |
| Cat 2 DNS | DNS health diagnostics inside `Invoke-AzStackHciConnectivityValidation` |
