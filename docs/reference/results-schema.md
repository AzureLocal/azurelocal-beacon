# Results Schema

Beacon saves results to `X:\results\validation-<timestamp>.json`.

## Schema

```json
{
  "metadata": {
    "version": "1.0",
    "startTime": "2026-06-19T14:23:00",
    "durationSeconds": 142,
    "ready": false
  },
  "summary": {
    "pass": 87,
    "fail": 3,
    "warn": 12,
    "skip": 2
  },
  "results": [
    {
      "Category": "Cat-1-Network",
      "Name": "NIC-Up-WithIP",
      "Target": "adapter",
      "Status": "Pass",
      "Detail": "Broadcom NetXtreme-E NIC / 10.10.1.50",
      "DurationMs": 38
    },
    {
      "Category": "Cat-4-AD",
      "Name": "AD-LDAP-10.10.0.10",
      "Target": "10.10.0.10:389",
      "Status": "Fail",
      "Detail": "Timeout",
      "DurationMs": 5002
    }
  ]
}
```

## Status values

| Status | Meaning |
|---|---|
| `Pass` | Test succeeded |
| `Fail` | Test failed — potential deployment blocker |
| `Warn` | Test returned a non-fatal issue |
| `Skip` | Test was not applicable or explicitly skipped |

## Copying results off the WinPE session

```cmd title="Copy to network share (run in WinPE command prompt)"
net use Z: \\10.10.0.100\results /user:domain\user password
xcopy X:\results\*.json Z:\beacon\
net use Z: /delete
```
