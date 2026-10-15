# Walkthrough: boot the ISO, run the sweep, read the results

A short end to end run on a bare node. All names, addresses and values below are examples
(`contoso.com`, `192.0.2.0/24`). Sample output is abridged; a complete example results file is in
[`examples/sample-results.json`](https://github.com/AzureLocal/azurelocal-beacon/blob/main/examples/sample-results.json)
with its [HTML report](https://github.com/AzureLocal/azurelocal-beacon/blob/main/examples/sample-report.html).

## 1. Boot

Mount the ISO as virtual media (or boot the USB stick) and do a one-time boot from it. After about 20 seconds:

```text
============================================================
  AzL Beacon v1.1.0
  Azure Local Pre-Deployment Validation
============================================================

Launching AzL Beacon (interactive menu)...

  Initializing network bootstrap...
  Waiting 15s for NIC driver init and DHCP lease...
  [OK] DHCP acquired: 192.0.2.21
       Gateway : 192.0.2.1
       DNS     : 192.0.2.10

  Verifying connectivity...
  [OK]   Gateway ping: 192.0.2.1
  [OK]   DNS: management.azure.com
  [OK]   HTTPS: login.microsoftonline.com:443
```

No DHCP? Beacon asks for address, mask, gateway and DNS and checks each value before applying it.

## 2. Pick a path

```text
  Network Status:
    IP    : 192.0.2.21  (DHCP)
    NIC   : Ethernet
    GW    : 192.0.2.1  [OK]
    DNS   : 192.0.2.10  [OK]
    HTTPS : login.microsoftonline.com:443  [OK]

  +-----------------------------------------------------+
  |  Validation Menu                                    |
  +-----------------------------------------------------+
  |  1)  Active Directory deployment                    |
  |  2)  Local Identity (AD-less) deployment            |
  |  3)  Networking and Firewall                        |
  |  4)  Full readiness sweep (all 6 categories)        |
  |  5)  Arc readiness (Azure sign-in)                  |
  +-----------------------------------------------------+
  |  6)  Network settings (re-run bootstrap)            |
  |  7)  Open PowerShell console                        |
  |  8)  Export results (USB / SMB / HTTPS)             |
  |  9)  Region, proxy and Arc gateway settings         |
  |  0)  Exit to command prompt                         |
  +-----------------------------------------------------+
```

Before the first run choose **9** and set the Azure region of the deployment (it selects the endpoint list),
plus a proxy or an Arc gateway if you will use one. Then choose **1** for an Active Directory deployment:

```text
  Active Directory domain FQDN (e.g. corp.contoso.com): corp.contoso.com
  Domain controller IP(s) - comma-separated if multiple: 192.0.2.10, 192.0.2.11
  Target OU Distinguished Name (optional, Enter to skip):
  Deployment prefix (up to 8 chars) [azl]:
```

## 3. The sweep

```text
[Category 1] Basic Network and Time
  [PASS] NIC-Up-WithIP        adapter -- Example NIC 25GbE / 192.0.2.21
  [PASS] Gateway-Ping         192.0.2.1 -- 1ms
  [PASS] NTP-192.0.2.10       192.0.2.10:123/udp -- UDP/123 answered; clock offset 1.4s vs server

[Category 3] Active Directory Ports
  [PASS] AD-LDAP-192.0.2.10   192.0.2.10:389 -- 1ms
  [FAIL] AD-ADWS-192.0.2.10   192.0.2.10:9389 -- Timeout
  [SKIP] AD-Kerberos-UDP-192.0.2.10  192.0.2.10:88/udp -- UDP cannot prove open: no reply and no ICMP unreachable (open or filtered)
  [SKIP] AD-RPC-Dynamic-49152-65535  tcp 49152-65535 -- Not scanned: ...

[Category 4] Azure Endpoint Sweep
  [PASS] Endpoint-Region      eastus -- List updated November 27th, 2025; 83 entries
  [PASS] EP-management.azure.com   management.azure.com:443 -- TCP+HTTPS ok -- 21ms
  [WARN] EP-crl3.digicert.com      crl3.digicert.com:80 -- Timeout
  [PASS] PublicIP-gbl.his.arc.azure.com   gbl.his.arc.azure.com -- Public: 20.50.2.20
  [PASS] TlsInspection-login.microsoftonline.com   login.microsoftonline.com:443 -- Microsoft chain (...)
```

Status meanings: `PASS` ok, `FAIL` blocks deployment, `WARN` review, `SKIP` not applicable or not provable
(for example UDP silence, wildcard endpoints without a representative host, port 8084 which is a cluster-internal port).

## 4. The verdict

```text
================================================================
  Azure Local Pre-Deployment Validation -- Summary
================================================================
  Total checks : 25
  Pass         : 15
  Fail         : 1
  Warning      : 4
  Skip         : 5

  BLOCKING FAILURES:
    [FAIL] [Cat-3-AD] AD-ADWS-192.0.2.10 -- Timeout

  Verdict: NOT READY -- Fix blocking failures before deployment
================================================================
  Results  : X:\results\validation-20261015-140341.json
  Report   : X:\results\validation-20261015-140341.html
```

Every failure carries a `remediation` text ("Allow TCP/9389 from the nodes to the domain controller (ADWS).")
and a `source` (the Learn page or endpoint list the requirement comes from).

## 5. Get the results off the node

The files live on the RAM drive and vanish on reboot. Choose **8**:

```text
  Latest : validation-20261015-140341.json
  NOTE: results contain IP addresses, DC/host names, the domain and the node serial number.
  Redact identifying values before export? (y/N): y
  Target examples:  E   (USB drive letter)    \\server\share    https://example.com/beacon
  Export target: E
  Drive: copied to E:\beacon-results
```

With redaction, domain names, host names, serial numbers, GUIDs and every IPv4 address are replaced by stable
tokens (`<domain>`, `<host>`, `<ip-1>`); the same address always gets the same token so the file stays readable.
Command line equivalent inside the image: `Start-AzlValidation.ps1 -Redact -ExportTo E`.

## 6. Read the JSON

```powershell
$r = Get-Content .\validation-20261015-140341.json -Raw | ConvertFrom-Json
$r.summary                                              # counts and verdict
$r.results | Where-Object status -eq 'Fail' | Format-List name, target, detail, remediation, source
```

Fields are documented in the [results schema](../reference/results-schema.md); the file validates against
`docs/reference/results.schema.json`.
