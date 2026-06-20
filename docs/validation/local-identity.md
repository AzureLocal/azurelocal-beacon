# Local Identity (AD-less) Deployment Validation

Select **option 2** from the Beacon main menu to validate readiness for a Local Identity (AD-less) Azure Local deployment.

## What is Local Identity?

Local Identity deployment uses a local administrator account and Azure Key Vault instead of Active Directory. There is no domain join and no AD infrastructure required on-premises.

**Key differences from AD deployment:**

| Item | AD deployment | Local Identity deployment |
|---|---|---|
| Identity provider | Active Directory | Local admin + Azure Key Vault |
| Node IP | DHCP or static | **Static only — DHCP not supported** |
| DNS server | AD-integrated DNS | Any DNS (internal or external) |
| Cluster type | Domain-joined | Workgroup cluster (`ADAware = 2`) |
| Windows Admin Center | Supported | Not supported |
| BitLocker keys | AD-stored | Key Vault-stored |

!!! warning "Static IP required"
    Microsoft explicitly requires static IP addresses for all cluster nodes in a Local Identity deployment. Configure static IPs before or during validation (Beacon's network bootstrap prompts for this).

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| DNS server IP(s) | `10.10.0.10, 8.8.8.8` | Yes |
| Azure Key Vault FQDN | `kv-iic-beacon.vault.azure.net` | Optional (enables KV endpoint probe) |

## Tests run

| Category | Tests |
|---|---|
| **1 — Network** | NIC status, IP assigned, gateway ping |
| **2 — DNS** | DNS TCP/UDP 53, forward resolution of Azure management endpoints |
| **4 — Endpoint sweep** | Azure Local, Arc, and Key Vault service endpoints |
| **5 — EnvChecker** | `Invoke-AzStackHciConnectivityValidation` + `Invoke-AzStackHciNetworkValidation` |
| **6 — Arc** | Optional: `Invoke-AzStackHciArcIntegrationValidation` |

!!! note "Category 3 (AD ports) is skipped"
    AD port tests are not applicable and not run in the Local Identity path.

## Azure Key Vault requirements

The deployment provisions an Azure Key Vault during deployment to store:

- BitLocker recovery keys
- Node local admin password
- `RecoveryAdmin` password

Ensure outbound HTTPS (443) to `*.vault.azure.net` is allowed through your firewall.

## Arc integration (optional)

After the Local Identity validation, Beacon offers an optional Arc integration check with device-code sign-in.

## Microsoft documentation

- [Deploy Azure Local using local identity with Azure Key Vault](https://learn.microsoft.com/azure/azure-local/deploy/deployment-local-identity-with-key-vault)
- [Deployment prerequisites](https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites)
