# Results schema

Beacon writes three files per run next to each other:

| File | Purpose |
|---|---|
| `validation-<yyyyMMdd-HHmmss>.json` | Machine readable result, validated by [`results.schema.json`](https://github.com/AzureLocal/azurelocal-beacon/blob/main/docs/reference/results.schema.json) (JSON Schema 2020-12) |
| `validation-<yyyyMMdd-HHmmss>.log` | Plain text table of every check |
| `validation-<yyyyMMdd-HHmmss>.html` | Self-contained report (no scripts, no external assets) |

In WinPE the folder is `X:\results\`; elsewhere `$env:TEMP`. The timestamp in the file name is UTC.
With `-Redact` only the redacted document is written. A copy of the Environment Checker's own report
(`AzStackHciEnvironmentReport.json`) is added when it exists and `-Redact` is not used.

## Document

```json
{
  "schemaVersion": "1.1",
  "tool": { "name": "AzL Beacon", "version": "1.1.0", "releaseTrain": "12.2609 (latest)" },
  "runId": "00000000-0000-0000-0000-0000000000aa",
  "startedUtc": "2026-10-15T14:00:05Z",
  "finishedUtc": "2026-10-15T14:03:41Z",
  "durationSeconds": 216,
  "redacted": false,
  "node": {
    "hostname": "MININT-EXAMPLE", "serialNumber": "EXAMPLE0001", "smbiosUuid": "00000000-0000-0000-0000-000000000001",
    "manufacturer": "Example Vendor", "model": "Example AX Node"
  },
  "context": {
    "region": "eastus", "regionRequested": "East US", "oem": "dell",
    "arcGatewayMode": false, "proxyConfigured": false,
    "categories": [1, 2, 3, 4, 5, 6],
    "endpointSource": "https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md"
  },
  "summary": { "total": 25, "pass": 15, "fail": 1, "warn": 4, "skip": 5, "verdict": "FAIL" },
  "results": [
    {
      "category": "Cat-3-AD",
      "name": "AD-ADWS-192.0.2.10",
      "target": "192.0.2.10:9389",
      "status": "Fail",
      "severity": "critical",
      "detail": "Timeout",
      "durationMs": 5003,
      "remediation": "Allow TCP/9389 from the nodes to the domain controller (ADWS).",
      "source": "https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements#active-directory"
    }
  ]
}
```

## Fields

| Field | Meaning |
|---|---|
| `schemaVersion` | Contract version. The major part changes only on breaking changes. |
| `tool.version` | Beacon version (one semantic version everywhere: banner, JSON, changelog, release manifest). |
| `tool.releaseTrain` | Azure Local release the endpoint data and checks target. |
| `runId` | New GUID per run. |
| `startedUtc`, `finishedUtc` | UTC, `yyyy-MM-ddTHH:mm:ssZ`. (Earlier builds wrote local time with a `Z`.) |
| `node` | Hostname and SMBIOS identity. Empty strings when WMI is unavailable. |
| `context.region` | Region key actually used. If it differs from `regionRequested`, the requested region had no list and `eastus` was used (also reported as a `Warn`). |
| `summary.verdict` | `PASS` (no `Fail`), `FAIL`, or `NO_CHECKS`. |
| `results[].category` | `Cat-1-Network`, `Cat-2-DNS`, `Cat-3-AD`, `Cat-4-Endpoints`, `Cat-5-EnvChecker`, `Cat-6-Arc`. |
| `results[].status` | `Pass`, `Fail` (potential deployment blocker), `Warn` (review), `Skip` (not applicable or not provable). |
| `results[].severity` | `critical`, `warning`, `informational`, or empty. For endpoint rows it is the severity from the endpoint list. |
| `results[].remediation` | What to change. Empty for `Pass` and most `Skip`. |
| `results[].source` | Learn page, endpoint list or validator the requirement comes from. |

Environment Checker findings are itemised: one row per non-successful check with the validator's own name,
severity, remediation and target resource. A summary row (`EnvChecker-Connectivity`, `EnvChecker-Network`) carries the counts.

## What is in the file (read before sharing)

Results contain IP addresses, domain controller and node names, the Active Directory domain, the node
serial number and SMBIOS UUID. Arc results show a **masked** subscription id (`********-****-****-****-********abcd`);
tokens, tenant ids and full subscription ids are never written.

`-Redact` (or the redact question in menu option 8) replaces: configured domain, NetBIOS name, cluster, Key Vault,
Arc gateway, proxy, DC and node names; the node hostname, serial and SMBIOS UUID; every remaining GUID (`<guid>`);
and every IPv4 address (`<ip-1>`, `<ip-2>` ... stable within one document). Review a redacted file before
publishing it anyway: free-text details from third-party validators can contain other identifying text.

## Validate a file

```powershell
Test-Json -Json (Get-Content .\validation-20261015-140341.json -Raw) -SchemaFile .\docs\reference\results.schema.json
```

## Copying results off the node

Use menu option 8, or `Start-AzlValidation.ps1 -ExportTo`:

| Target | Example | Notes |
|---|---|---|
| Drive letter | `E` or `E:\folder` | Files go to `beacon-results` on that drive. |
| SMB share | `\\server\share` | Optional credential for this call only; mapped as a temporary drive. |
| HTTPS | `https://example.com/beacon` | JSON POST. Plain `http://` is refused. |
