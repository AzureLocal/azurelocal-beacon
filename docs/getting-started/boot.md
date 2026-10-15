# Boot and run

## Boot via BMC virtual media (Dell iDRAC example)

1. Open the BMC web console and go to **Virtual Console > Virtual Media**.
2. Map `azl-beacon-<version>-<date>.iso` as CD/DVD.
3. Set a one-time boot to **Virtual CD/DVD** (UEFI).
4. Power on or reboot the node.
5. The Beacon menu appears in about 30 to 60 seconds.

## Boot from USB

```powershell
.\src\Build-WinPEImage.ps1 -BuildUSB -UsbDriveLetter F     # erases F:
```

or write the ISO with a UEFI-capable tool, then one-time boot from the USB device.

## What happens at boot

```text
wpeinit                    <- WinPE network stack init
startnet.cmd               <- tries PowerShell 7 from X:\Tools, falls back to Windows PowerShell 5.1
  Start-AzlBeacon.ps1      <- menu
    Start-NetworkBootstrap <- DHCP detect, or a prompted static address (validated)
    Menu                   <- AD / Local Identity / Networking+Firewall / Full sweep / Arc / Export / Settings
```

## Network bootstrap

Beacon waits 15 seconds for a DHCP lease. If none arrives you are asked for:

| Prompt | Example |
|---|---|
| IP address | `192.0.2.50` |
| Subnet mask | `255.255.255.0` |
| Default gateway | `192.0.2.1` |
| Primary DNS | `192.0.2.10` |

Each value is validated (dotted quad, contiguous mask); invalid input applies nothing. The address is only for Beacon; it has nothing to do with
how the cluster nodes will be addressed later.

## Results

Saved to `X:\results\` for the WinPE session: `.json`, `.log`, `.html`.

> [!WARNING]
> **Results are lost on reboot.** Use menu option **8**: a USB drive letter, an SMB share (`\\server\share`) or an HTTPS URL, with an optional redaction.
> From a command prompt, `Start-AzlValidation.ps1 -ExportTo E -Redact` does the same.

Walkthrough with sample output: [Walkthrough](walkthrough.md).
