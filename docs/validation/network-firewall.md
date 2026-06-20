# Networking and Firewall Validation

Select **option 3** from the Beacon main menu to run a focused networking and firewall validation.

## What it covers

This path runs everything except the AD port tests (Category 3). It's ideal for:

- Verifying firewall policy before any identity configuration
- Checking endpoint reachability from the management VLAN
- Confirming DNS is reachable

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| Management gateway IP | `10.10.0.1` | Optional (uses DHCP-detected if blank) |
| DNS server IP(s) | `10.10.0.10` | Optional |

## Tests run

| Category | Tests |
|---|---|
| **1 — Network** | NIC status, IP assigned, gateway ping |
| **2 — DNS** | DNS TCP/UDP 53, forward resolution of key Azure endpoints |
| **4 — Endpoint sweep** | All Azure Local + Arc + Dell endpoints |
| **5 — EnvChecker** | `Invoke-AzStackHciConnectivityValidation` + `Invoke-AzStackHciNetworkValidation` |
| **6 — Arc** | Optional |

## Firewall requirements — Azure Local

The endpoint sweep tests all endpoints from these sources:

| Source | Endpoints | Severity |
|---|---|---|
| Azure Local (`firewall-requirements.md`) | ~80 endpoints | Critical / Informational |
| Arc for Servers (`arc-endpoints.md`) | ~30 endpoints | Critical / Warning |
| Dell AX OEM (`DellAzureLocalEndpoints.md`) | ~11 endpoints | Warning |

!!! tip "See the full list"
    See [Endpoint List](../reference/endpoints.md) for every endpoint tested.

## Microsoft documentation

- [Azure Local firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements)
- [Azure Arc network requirements](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
