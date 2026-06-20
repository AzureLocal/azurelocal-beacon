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

## 6 validation categories

| Category | Name | Paths |
|---|---|---|
| 1 | Basic network connectivity (NIC, IP, gateway) | All |
| 2 | DNS (forward/reverse/TCP/UDP) | All |
| 3 | Active Directory ports (LDAP/Kerberos/RPC/DNS/LDAPS + SRV) | AD, Full-AD |
| 4 | Azure endpoint sweep | All |
| 5 | AzStackHci.EnvironmentChecker (connectivity + network validators) | All |
| 6 | Arc integration (optional — requires Azure device-code login) | Optional on all paths |

All test targets derive from the three Microsoft/Dell source documents:

- [Azure Local firewall requirements](https://github.com/MicrosoftDocs/azure-stack-docs/blob/main/azure-local/concepts/firewall-requirements.md)
- [EastUS HCI endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md)
- [Dell OEM endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/OEMEndpoints/Dell/DellAzureLocalEndpoints.md)
