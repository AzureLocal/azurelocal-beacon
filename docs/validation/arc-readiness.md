# Arc readiness (Category 6)

Menu option **5** (or the optional question at the end of the other paths) checks that the Azure side is ready
to register the nodes with Azure Arc. It needs no Azure PowerShell modules: the image has none. It signs in with the
OAuth2 device-code flow and reads Azure Resource Manager with plain REST calls.

## What you enter

| Input | Example |
|---|---|
| Azure subscription ID | `00000000-0000-0000-0000-000000000000` |
| Tenant ID or domain | blank (`organizations`), `contoso.onmicrosoft.com` or a tenant GUID |
| Arc resource group | `rg-azurelocal-example` |
| Node host names | `node-01, node-02` |

Then a URL and a code are printed. Open the URL on any other device, enter the code and sign in with the account
that will register the machines.

## What is checked

| Check | Result names | What it means |
|---|---|---|
| Sign-in | `Arc-SignIn` | Device-code flow reached the Microsoft identity platform and the account signed in. |
| Subscription | `Arc-Subscription` | The subscription is visible to you and `Enabled`. |
| Resource providers | `Arc-RP-<namespace>` | Registration state of `Microsoft.HybridCompute`, `GuestConfiguration`, `HybridConnectivity`, `AzureStackHCI`, `Kubernetes`, `KubernetesConfiguration`, `ExtendedLocation`, `ResourceConnector`, `Insights`, `Authorization` (each `Fail` when not registered, remediation `az provider register --namespace ...`) and `Microsoft.HybridContainerService` (AKS Arc; `Warn` only). |
| Resource group | `Arc-ResourceGroup` | Exists (`Pass`) or still has to be created (`Warn`). |
| Role assignments | `Arc-RoleAssignments` | Learn: to register Arc machines you must be Owner of the resource group, **or** hold *Azure Connected Machine Onboarding* and *Azure Connected Machine Resource Administrator* on it. `Contributor` + `User Access Administrator`/`Role Based Access Control Administrator` only warns because it lacks the two Arc roles. Assignments inherited from the subscription count. |
| Existing machines | `Arc-NodeName-<name>` | An Arc machine with the same name already in the resource group (a stale registration) is a warning. |
| Environment Checker Arc validator | `Arc-EnvChecker-IntegrationValidator` | `Invoke-AzStackHciArcIntegrationValidation` needs `Az.Accounts`, `Az.Resources`, an Az context **and** the Azure Local OS cmdlet `Get-AzureStackHCI`. None of these exist in WinPE, so it is reported as `Skip` with the reason. The REST checks above cover the same ground (resource providers, resource group, existing Arc resources, roles). |

## What is stored

Nothing on disk. The access token lives in a script variable and is cleared in a `finally` block (also when a
check throws). The menu hands the subscription, tenant, resource group and node names to the engine through
process environment variables and removes them afterwards in a `finally` block. Results show a masked subscription
id only (`********-****-****-****-********abcd`). The sign-in uses the public Azure CLI client id (a documented
constant, not tenant data); set the environment variable `BEACON_ARC_CLIENT_ID` to use another public client application if your tenant blocks it.

## Limits

- Role assignments are read with the signed-in user's own `assignedTo` filter. If the account may not read
  assignments the check reports a warning and tells you to verify the two roles in the portal.
- Conditional Access policies that block the device-code flow make `Arc-SignIn` fail; use another network or account.
- US Government regions use the sovereign login and management hosts automatically (`usgovvirginia`).

## Microsoft documentation

- [Assign required permissions for Azure Local deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions)
- [Connected Machine agent prerequisites (resource providers)](https://learn.microsoft.com/azure/azure-arc/servers/prerequisites#azure-resource-providers)
