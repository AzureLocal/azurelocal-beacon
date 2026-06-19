# Networking and Firewall Validation

Select **option 3** from the Beacon main menu to run a focused networking and firewall validation.

## What it covers

This path runs everything except the AD port tests (Category 4). It's ideal for:

- Verifying firewall policy before any identity configuration
- Checking endpoint reachability from the management VLAN
- Detecting SSL deep-inspection on the outbound path
- Hardware self-checks (TPM, Secure Boot, NICs)

## What you are prompted for

| Input | Example | Required |
|---|---|---|
| Management gateway IP | `10.10.0.1` | Optional (uses DHCP-detected if blank) |
| DNS server IP(s) | `10.10.0.10` | Optional |
| IP pool start | `10.10.1.100` | Optional (enables squatter scan) |
| IP pool end | `10.10.1.120` | Optional |

## Firewall requirements — Azure Local

The endpoint sweep tests all endpoints from these sources:

| Source | Endpoints | Severity |
|---|---|---|
| Azure Local (`firewall-requirements.md`) | ~80 endpoints | Critical / Informational |
| Arc for Servers (`arc-endpoints.md`) | ~30 endpoints | Critical / Warning |
| Dell AX OEM (`DellAzureLocalEndpoints.md`) | ~11 endpoints | Warning |

!!! tip "See the full list"
    See [Endpoint List](../reference/endpoints.md) for every endpoint tested.

## SSL deep-inspection detection

Category 10 detects **FortiGate SSL deep inspection** (or any transparent proxy that re-signs TLS). Azure Local **cannot deploy** through an SSL inspection device because the TLS certificate chain will not match Microsoft's expected root CAs.

If Category 10 fails:

1. Work with your network team to create a firewall bypass/exemption for Azure Local node IPs
2. Verify the exemption: Beacon re-runs Category 10 and should show the correct DigiCert/Microsoft root

## Kubernetes reserved subnets

Category 11 checks that your planned IP pool does not overlap with Kubernetes-reserved ranges:

- `10.96.0.0/12` — Kubernetes service CIDR
- `10.244.0.0/16` — Pod network CIDR

DNS server IPs must also not fall within these ranges.
