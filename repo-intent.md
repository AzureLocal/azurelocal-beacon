# Repo intent — azurelocal-beacon

**AzL Beacon — pre-deployment endpoint, network, and hardware readiness validation for Azure Local. Bootable WinPE diagnostic image; no installed OS required.**

## What this repo is

Boots from iDRAC Virtual Media or USB — no installed OS, no domain join, no
licensing required. Run it on bare metal before touching the deployment wizard
to confirm the environment is actually ready.

`Start-AzlBeacon.ps1` presents an interactive menu covering 6 validation
categories, all grounded in Microsoft/Dell source documents: basic network, DNS,
Active Directory ports, Azure endpoint sweep, Environment Checker (wraps
Microsoft's official `Invoke-AzStackHciConnectivityValidation` /
`Invoke-AzStackHciNetworkValidation`), and Arc integration
(`Invoke-AzStackHciArcIntegrationValidation`, optional).

## How it relates to other repos

- Complements `azurelocal-ranger` (post-deployment ground truth) and
  `azurelocal-s2d-cartographer` (post-deployment storage inventory) — Beacon is
  specifically the pre-deployment readiness check, before any OS is even
  installed

## Status

Active.
