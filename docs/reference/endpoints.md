# Endpoint List

AzL Beacon tests connectivity to 121 endpoints generated from three source files.

## Source files

| File | Endpoints | Description |
|---|---|---|
| `config/endpoints/azurelocal-endpoints.md` | ~80 | Azure Local firewall requirements |
| `config/endpoints/arc-endpoints.md` | ~30 | Arc for Servers connectivity requirements |
| `config/endpoints/dell-endpoints.md` | ~11 | Dell AX OEM-specific endpoints |

The endpoint list is compiled to `src/config/endpoints.json` by `src/Convert-EndpointsToJson.ps1`.

## Regenerating endpoints.json

```powershell title="From repo root"
.\src\Convert-EndpointsToJson.ps1 -Force
```

## Microsoft firewall documentation

- [Firewall requirements for Azure Local](https://github.com/MicrosoftDocs/azure-stack-docs/blob/main/azure-local/concepts/firewall-requirements.md)
- [East US HCI endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md)
- [Dell AX OEM endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/OEMEndpoints/Dell/DellAzureLocalEndpoints.md)

## Endpoint severity

| Severity | Beacon behavior | Meaning |
|---|---|---|
| `critical` | `[FAIL]` if unreachable | Azure Local will not deploy without this endpoint |
| `warning` | `[WARN]` if unreachable | Functionality degraded but deployment may proceed |
| `informational` | `[WARN]` if unreachable | Optional / monitoring endpoints |
