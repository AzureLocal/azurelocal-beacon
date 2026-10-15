# Overview

AzL Beacon is a WinPE bootable diagnostic image that validates Azure Local deployment readiness before any operating system is installed
on the target nodes. It targets Azure Local 12.2609 (latest).

## How it works

1. Boot the Beacon ISO on any machine on the management network, or on the target node itself via BMC virtual media or USB.
2. The image detects an address (DHCP) or prompts for one, and verifies gateway, DNS and outbound HTTPS.
3. A menu offers the validation paths: Active Directory, Local Identity, Networking and Firewall, full sweep, Arc readiness.
4. Checks run, results are saved to `X:\results\` as JSON, log and HTML, and a PASS/FAIL verdict is shown.
5. Export the results (USB, SMB share or HTTPS) before rebooting.

## Why use it

- **No OS required**: runs from WinPE; nodes do not need to be provisioned.
- **No domain join, no licensing.**
- **Region aware**: the endpoint sweep uses the per-region lists Microsoft Learn links to, with proxy and Arc gateway modes.
- **Both identity paths**: AD-joined and AD-less (Local Identity).
- **Azure side too**: resource providers and Arc roles are checked over REST with a device-code sign-in, nothing stored.
- **Bring your own drivers**: Dell AX 16G NIC drivers are bundled; other hardware via `-DriverPath`.

There is deliberately no drive or disk check.

## Output

`X:\results\validation-<timestamp>.json` (schema in [Results schema](../reference/results-schema.md)), a `.log` and an `.html` report, and
console lines with `[PASS]` / `[FAIL]` / `[WARN]` / `[SKIP]` per test.

> [!NOTE]
> **Results persist for the session only.** WinPE runs in RAM. Use menu option 8 (or `-ExportTo`) before rebooting.

## Next

- New to it? [Walkthrough](walkthrough.md) shows a complete run with sample output.
- First build? [Build and first-boot verification](verify-build.md).
