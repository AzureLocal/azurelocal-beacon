# Overview

AzL Beacon is a WinPE bootable diagnostic image that validates Azure Local deployment readiness before any OS is installed on the target nodes.

## How it works

1. Boot the Beacon ISO on any machine on the management network (or on the target node itself via iDRAC virtual media)
2. The image detects or prompts for a management IP address
3. A split menu presents three validation paths — choose the one that matches your planned deployment type
4. Tests run, results are saved to `X:\results\`, and a PASS/FAIL verdict is shown

## Why use it

- **No OS required** — runs from WinPE; target nodes don't need to be provisioned
- **No domain join** — works before AD preparation is complete
- **No licensing** — WinPE is royalty-free for diagnostic use
- **Dell AX 16G NIC drivers included** — Broadcom, Mellanox, and Intel 800-series all recognized out of the box
- **Both identity paths covered** — validates AD-joined and AD-less (Local Identity) deployments

## Output

Results are saved to `X:\results\validation-<timestamp>.json` and displayed on the console with `[PASS]` / `[FAIL]` / `[WARN]` / `[SKIP]` indicators per test.

!!! info "Results persist for the session only"
    WinPE runs entirely in RAM. Results saved to `X:\results\` are lost on reboot.
    Copy the results JSON to a network share or USB before rebooting if you need to retain them.
