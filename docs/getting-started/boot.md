# Boot and Run

## Boot via iDRAC Virtual Media

1. Open iDRAC and navigate to **Configuration → Virtual Media**
2. Map the `azl-validate-<date>.iso` from your management machine
3. Set boot order to **Virtual CD/DVD** (one-time boot)
4. Power on or reboot the node
5. The Beacon menu appears automatically within ~60 seconds

## Boot from USB

Flash the ISO to a USB drive (or build directly with `-BuildUSB`):

```powershell title="Flash to USB with Rufus or the build script"
# Option A: build script writes USB directly
.\src\Build-WinPEImage.ps1 -BuildUSB -UsbDriveLetter F

# Option B: write a pre-built ISO with Rufus (DD mode recommended)
```

Set the node's one-time boot order to the USB device.

## What happens at boot

```
wpeinit                   ← WinPE network stack init
Start-AzlBeacon.ps1       ← Menu orchestrator
  Start-NetworkBootstrap  ← DHCP detect / static IP prompt
  Main menu               ← Choose: AD / Local Identity / Network+Firewall / Full sweep
```

## Network bootstrap

On boot, Beacon waits **15 seconds** for a DHCP lease. If none is detected, you are prompted for:

| Prompt | Example |
|---|---|
| IP address | `10.10.0.50` |
| Subnet mask | `255.255.255.0` |
| Default gateway | `10.10.0.1` |
| Primary DNS | `10.10.0.10` |

!!! note "Local Identity deployments require static IPs"
    Microsoft requires static IP addresses for all cluster nodes in a Local Identity (AD-less) deployment.
    DHCP is not supported for node NICs in this mode.

## Results

Results are saved to `X:\results\validation-<timestamp>.json` for the duration of the WinPE session.

!!! warning "Results lost on reboot"
    WinPE runs in RAM. Copy results before rebooting:
    ```cmd
    net use Z: \\management-server\share password /user:domain\user
    copy X:\results\*.json Z:\beacon-results\
    ```
