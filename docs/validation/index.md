# Validation Overview

AzL Beacon presents a **split menu** at boot. Choose the path that matches your planned deployment type.

## Paths at a glance

| Path | Use when | AD Category 4 | Key Vault check |
|---|---|---|---|
| **Active Directory** | Deploying to an AD-joined environment | ✅ included | — |
| **Local Identity (AD-less)** | Deploying without Active Directory | ❌ skipped | ✅ included |
| **Networking & Firewall** | Network-focused check (any identity type) | ❌ skipped | — |
| **Full sweep** | Comprehensive run (choose AD or Local Identity sub-path) | Configurable | — |

## Menu options

```
  ┌─────────────────────────────────────────────────────┐
  │  Validation Menu                                    │
  ├─────────────────────────────────────────────────────┤
  │  1)  Active Directory deployment                    │
  │  2)  Local Identity (AD-less) deployment            │
  │  3)  Networking and Firewall                        │
  │  4)  Full readiness sweep                           │
  ├─────────────────────────────────────────────────────┤
  │  5)  Network settings (re-run bootstrap)            │
  │  0)  Exit to command prompt                         │
  └─────────────────────────────────────────────────────┘
```

## All 12 validation categories

| Category | Name | Paths |
|---|---|---|
| 1 | Basic network connectivity (NIC, IP, gateway) | All |
| 2 | DNS (forward/reverse/UDP) | All |
| 3 | NTP time-skew | All |
| 4 | Active Directory ports (LDAP/Kerberos/RPC/DNS/LDAPS + SRV) | AD, Full-AD |
| 5 | Azure endpoint sweep (121 endpoints) | All |
| 6 | Infrastructure device reachability | Networking, Full |
| 7 | Service Bus WebSocket probe | Networking, Full |
| 8 | NTP UDP port 123 | Networking, Full |
| 9 | AzStackHci.EnvironmentChecker (connectivity + network validators) | All |
| 10 | SSL deep-inspection detection | All |
| 11 | Deployment prerequisite sanity (IP pool, Kubernetes subnet) | Local Identity, Full |
| 12 | Hardware self-checks (TPM, Secure Boot, NIC, CPU, storage) | Networking, Full |
