# Validation overview

AzL Beacon presents a **menu** at boot. Choose the path that matches your planned deployment type.

## Paths at a glance

| Path | Use when | Category 3 (AD ports) | Key Vault check |
|---|---|---|---|
| **Active Directory** (1) | Deploying into an AD-joined environment | included | - |
| **Local Identity (AD-less)** (2) | Deploying without Active Directory | skipped | uses `keyVaultFqdn` in the endpoint sweep |
| **Networking and Firewall** (3) | Network-focused check (any identity type) | skipped | - |
| **Full sweep** (4) | Everything; choose the AD or Local Identity sub-path | AD sub-path only | - |
| **Arc readiness** (5) | Azure side ready to register the nodes | - | - |

## Menu

```text
  +-----------------------------------------------------+
  |  Validation Menu                                    |
  +-----------------------------------------------------+
  |  1)  Active Directory deployment                    |
  |  2)  Local Identity (AD-less) deployment            |
  |  3)  Networking and Firewall                        |
  |  4)  Full readiness sweep (all 6 categories)        |
  |  5)  Arc readiness (Azure sign-in)                  |
  +-----------------------------------------------------+
  |  6)  Network settings (re-run bootstrap)            |
  |  7)  Open PowerShell console                        |
  |  8)  Export results (USB / SMB / HTTPS)             |
  |  9)  Region, proxy and Arc gateway settings         |
  |  0)  Exit to command prompt                         |
  +-----------------------------------------------------+
```

## The 6 validation categories

| Category | Name | Paths |
|---|---|---|
| 1 | Basic network and time (NIC, IP, gateway, NTP and clock skew) | All |
| 2 | DNS (forward, reverse, TCP and UDP 53) | All |
| 3 | Active Directory ports (TCP and UDP, SRV record) | AD, full sweep AD sub-path |
| 4 | Azure endpoint sweep for your region, public-IP and HTTPS-inspection checks | All |
| 5 | Microsoft Environment Checker (Connectivity and Network validators) | All |
| 6 | Arc readiness (device-code sign-in, Azure REST checks) | Optional on every path, option 5 |

There is deliberately **no drive or disk check**: Beacon validates the network, identity and Azure side, not the node's storage.

## Sources

Every target traces to Microsoft Learn:

- [Firewall requirements for Azure Local](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements) (outbound endpoints per region, Active Directory ports, NTP)
- [Assign required permissions for Azure Local deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions) (resource providers, Arc roles)
- The per-region endpoint lists and the Dell OEM list Learn links to (see [Endpoint list](../reference/endpoints.md))
