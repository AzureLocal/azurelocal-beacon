# Local Identity (AD-less) deployment validation

Select **option 2** from the Beacon menu to validate readiness for a Local Identity (AD-less) Azure Local deployment.

## What is Local Identity?

Local Identity uses a local administrator account and Azure Key Vault instead of Active Directory. There is no domain join and no AD
infrastructure on premises.

| Item | AD deployment | Local Identity deployment |
|---|---|---|
| Identity provider | Active Directory | Local admin + Azure Key Vault |
| Node IP | DHCP or static | **Static only** |
| DNS server | AD-integrated DNS | Any DNS (internal or external) |
| Cluster type | Domain-joined | Workgroup cluster |
| Windows Admin Center | Supported | Not supported |
| BitLocker keys | AD-stored | Key Vault-stored |

> [!WARNING]
> **Static IP required.** Microsoft requires static IP addresses for all cluster nodes in a Local Identity deployment. Beacon's network
> bootstrap prompts for a static address when DHCP is not available.

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| DNS server IP(s) | `192.0.2.10, 192.0.2.12` | Yes |
| Azure Key Vault FQDN | `kv-example-01.vault.azure.net` | Optional; replaces the Key Vault placeholder row of the endpoint sweep |

## Tests run

| Category | Tests |
|---|---|
| **1 - Network and time** | NIC, IP, gateway, NTP reachability and clock offset |
| **2 - DNS** | DNS TCP/UDP 53, forward resolution of Azure management endpoints |
| **4 - Endpoint sweep** | Region endpoint list including the Key Vault endpoint, public-IP and HTTPS-inspection checks |
| **5 - Environment Checker** | Connectivity and Network validators |
| **6 - Arc** | Optional, see [Arc readiness](arc-readiness.md) |

> [!NOTE]
> **Category 3 (AD ports) is skipped.** AD port tests are not applicable to this path.

## Azure Key Vault requirements

The deployment creates a Key Vault for BitLocker recovery keys, the node local administrator password and the recovery admin password.
Allow outbound HTTPS (443) to your vault name (`*.vault.azure.net`).

## Microsoft documentation

- [Deploy Azure Local using local identity with Azure Key Vault](https://learn.microsoft.com/azure/azure-local/deploy/deployment-local-identity-with-key-vault)
- [Deployment prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites)
