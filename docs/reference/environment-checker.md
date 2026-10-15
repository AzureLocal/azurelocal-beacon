# Environment Checker integration

Beacon bundles Microsoft's `AzStackHci.EnvironmentChecker` module and runs two of its validators in Category 5.

## Module

| Item | Value |
|---|---|
| Module | `AzStackHci.EnvironmentChecker` (PowerShell Gallery, signed by Microsoft Corporation) |
| Pinned version | `10.2605.0.2006`, recorded in `tools/modules/modules.lock.json` with the SHA256 of the manifest |
| In the image | `X:\Tools\Modules\AzStackHci.EnvironmentChecker\10.2605.0.2006\AzStackHci.EnvironmentChecker.psd1` |
| Verify / refresh | `scripts/Update-BeaconModules.ps1` verifies the pin and checks that all 245 script files are validly signed; `-Refresh` re-downloads the pinned version; `-Version x -Refresh -UpdateLock` moves the pin after the signature check |

The module is imported by **explicit manifest path**. The folder layout is `<root>\<version>\<name>.psd1`, and WinPE has no module
path indexing, so importing the version-less folder is not reliable. Beacon resolves the highest version folder that holds a manifest.

The module is built for Windows PowerShell 5.1 (it ships a net472 assembly). When the engine itself runs under PowerShell 7
(the image prefers it), Category 5 is delegated to `powershell.exe` (5.1) and the results are merged. Set
`BEACON_ENVCHECKER_INPROCESS=1` to run it in the current host instead.

## Validators used

| Validator | Inputs Beacon passes | Result in Beacon |
|---|---|---|
| `Invoke-AzStackHciConnectivityValidation` | `-RegionName` (the region key), `-Proxy` (config `proxyUrl`), `-ARCGateway` (when `arcGatewayFqdn` is set), `-UseLocalDefinitionsOnly` (the definitions that ship in the pinned module, no download), `-PassThru` | `EnvChecker-Connectivity` summary plus one row per non-successful check |
| `Invoke-AzStackHciNetworkValidation` | `-IpPools`, `-ManagementSubnetValue`, `-NodesInCluster`, `-AtcHostIntents` from the config and `-PSSession` to this node | `EnvChecker-Network` summary plus itemised rows; **Skip with the reason** when an input or the session is missing |

Why the Network validator is often skipped in WinPE: its parameters are mandatory (IP pools, management subnet, node count, host network intents)
and it works through a PowerShell remoting session to each node. WinPE normally has no WinRM listener, so the session cannot be created. When a
session can be opened and the config carries `infraIpPools`, `managementSubnetCidr`, `hostNetworkIntents` and node addresses, it runs. Otherwise run it from a staging server.

The module reports `SUCCESS` and `FAILURE` (not `Succeeded`). Mapping used:

| Module result | Beacon status |
|---|---|
| `SUCCESS` | `Pass` (not listed individually) |
| `FAILURE` with severity `CRITICAL` | `Fail` (severity `critical`) |
| `FAILURE` with severity `WARNING` or `INFORMATIONAL` | `Warn` |
| anything else | `Skip` |

Each itemised row carries `name`, `target` (the resource the validator tested), `severity`, `remediation` (the validator's own link or text) and `source`.

## Not run in WinPE

| Validator | Reason | Where to run it |
|---|---|---|
| `Invoke-AzStackHciExternalActiveDirectoryValidation` | Needs RSAT AD/GPO modules | A domain-joined staging server (Stage 2/3) |
| `Invoke-AzStackHciArcIntegrationValidation` | Needs `Az.Accounts`, `Az.Resources`, an Az context and `Get-AzureStackHCI` | Replaced in WinPE by the REST checks in [Arc readiness](../validation/arc-readiness.md) |
| Hardware, software, storage validators | Need the installed Azure Local OS | Stage 2, on each node |

> [!WARNING]
> **TLS inspection.** The Connectivity validator contains its own root-CA test and reports private root CAs in the TLS chain.
> Beacon's Category 4 `TlsInspection-` rows are an independent read of the same condition. Learn: Azure Local does not support HTTPS inspection.

## After the OS is installed (Stage 2)

```powershell
Import-Module AzStackHci.EnvironmentChecker
Invoke-AzStackHciConnectivityValidation
Invoke-AzStackHciHardwareValidation
Invoke-AzStackHciNetworkValidation
Invoke-AzStackHciExternalActiveDirectoryValidation   # AD-joined only
```
