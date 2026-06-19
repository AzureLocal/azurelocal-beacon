# Environment Checker Integration

AzL Beacon bundles and calls the Microsoft `AzStackHci.EnvironmentChecker` PowerShell module.

## Module

**Module:** `AzStackHci.EnvironmentChecker`  
**Source:** PowerShell Gallery  
**Bundled at:** `X:\Tools\Modules\AzStackHci.EnvironmentChecker` (in the WinPE image)

## Validators used

| Validator | Cmdlet | When called |
|---|---|---|
| Connectivity | `Invoke-AzStackHciConnectivityValidation` | Category 9, all paths |
| Network | `Invoke-AzStackHciNetworkValidation` | Category 9, Local Identity path |
| Hardware | `Invoke-AzStackHciHardwareValidation` | Category 12 (partial — CIM-based) |
| Arc integration | `Invoke-AzStackHciArcIntegrationValidation` | Optional — requires Azure sign-in |

## WinPE limitations

The following validators **cannot run in WinPE** and are deferred to post-OS (Stage 2):

| Validator | Reason | Workaround |
|---|---|---|
| Active Directory | Requires RSAT AD/GPO modules | Run `Invoke-AzStackHciExternalActiveDirectoryValidation` from a domain-joined staging server |

## SSL inspection behavior

The Environment Checker detects SSL deep-inspection before testing connectivity. If the TLS chain contains a private/unknown root CA, `Invoke-AzStackHciConnectivityValidation` raises an error and aborts. Beacon's Category 10 (SSL inspection detection) runs the same check independently so you know before invoking the module.

## Post-OS environment checker (Stage 2)

After the OS is installed on each node, run the full suite locally on each node:

```powershell title="Run on each Azure Local node (Stage 2)"
Import-Module AzStackHci.EnvironmentChecker
Invoke-AzStackHciConnectivityValidation
Invoke-AzStackHciHardwareValidation
Invoke-AzStackHciNetworkValidation
Invoke-AzStackHciExternalActiveDirectoryValidation  # AD-joined only
```
