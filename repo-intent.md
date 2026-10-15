# Repo intent: azurelocal-beacon

**AzL Beacon: pre-deployment endpoint, network and Arc readiness validation for Azure Local (12.2609, latest). Bootable WinPE diagnostic image; no installed OS required.**

## What this repo is

Boots from BMC virtual media or USB: no installed OS, no domain join, no licensing required. Run it on bare metal before touching
the deployment wizard to confirm the environment is actually ready.

`Start-AzlBeacon.ps1` presents an interactive menu covering 6 validation categories, all grounded in Microsoft Learn: basic network and
time, DNS, Active Directory ports, the Azure endpoint sweep for the deployment region (Arc gateway and proxy aware), the Microsoft
Environment Checker (`Invoke-AzStackHciConnectivityValidation` / `Invoke-AzStackHciNetworkValidation`, failed checks itemised), and Arc
readiness (device-code sign-in plus Azure REST checks, no Az modules, nothing stored).

Beacon deliberately has **no drive or disk check**.

Results are machine readable (`docs/reference/results.schema.json`, with run id, node identity, tool version and UTC timestamps) and
can be redacted and exported to USB, SMB or HTTPS.

## How it relates to other repos

- `azurelocal-sonar` listens during deployment; Beacon checks the environment before it. They share no code or file format today; the
  results `schemaVersion` and `runId` are the hook if a link is wanted later.
- `azurelocal-trailwright` plans and documents the deployment; Beacon's results can be attached to its pre-deployment record.
- Complements `azurelocal-ranger` (post-deployment ground truth) and `azurelocal-s2d-cartographer` (post-deployment storage inventory):
  Beacon is the pre-deployment readiness check, before any OS is installed.

## Status

Active. 1.1.0 is code complete and unit tested; the ISO has to be built and boot-verified on a Windows host with the ADK
(`docs/getting-started/verify-build.md`).
