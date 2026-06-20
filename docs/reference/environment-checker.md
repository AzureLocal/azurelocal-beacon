# Environment Checker Integration

AzL Beacon bundles and calls the Microsoft `AzStackHci.EnvironmentChecker` PowerShell module.

## Module

**Module:** `AzStackHci.EnvironmentChecker`  
**Source:** PowerShell Gallery  
**Bundled at:** `X:\Tools\Modules\AzStackHci.EnvironmentChecker` (in the WinPE image)

## Validators used

| Validator | Cmdlet | When called |
|---|---|---|
| Connectivity | `Invoke-AzStackHciConnectivityValidation` | Category 5, all paths |
| Network | `Invoke-AzStackHciNetworkValidation` | Category 5, all paths |
| Arc integration | `Invoke-AzStackHciArcIntegrationValidation` | Category 6 — optional, requires Azure sign-in |

## WinPE limitations

The following validators **cannot run in WinPE** and are deferred to post-OS (Stage 2):

| Validator | Reason | Workaround |
|---|---|---|
| Active Directory | Requires RSAT AD/GPO modules | Run `Invoke-AzStackHciExternalActiveDirectoryValidation` from a domain-joined staging server |

!!! warning "SSL inspection — note"
    `Invoke-AzStackHciConnectivityValidation` raises an error if it detects SSL deep-inspection (private root CA in the TLS chain). If you see this failure, work with your network team to exempt Azure Local node IPs from SSL inspection before re-running.

## Post-OS environment checker (Stage 2)

After the OS is installed on each node, run the full suite locally on each node:

```powershell title="Run on each Azure Local node (Stage 2)"
Import-Module AzStackHci.EnvironmentChecker
Invoke-AzStackHciConnectivityValidation
Invoke-AzStackHciHardwareValidation
Invoke-AzStackHciNetworkValidation
Invoke-AzStackHciExternalActiveDirectoryValidation  # AD-joined only
```
