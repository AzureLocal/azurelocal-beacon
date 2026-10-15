# Build and first-boot verification

This is the procedure to build the Beacon ISO for the first time and prove that it boots and works.
Nothing in the repository can do this for you: the build needs the Windows ADK, an elevated DISM
session and a place to boot. Everything else (scripts, endpoint data, results format, menu logic) is
covered by the automated tests; this page covers what those tests cannot.

Expected time: about 45 minutes the first time (most of it ADK download and install).

## 0. What you need

| Item | Detail |
|---|---|
| Build host | Windows 11 or Windows Server 2022/2025, 64-bit, elevated PowerShell 7.4 or newer |
| Free disk | 15 GB on the drive that holds the workspace (`-WorkspacePath`, default `C:\WinPE_build`) plus the repository |
| Windows ADK | Windows ADK for Windows 11, version 10.1.26100.x (24H2/25H2 line) |
| WinPE add-on | The matching WinPE add-on for that ADK version |
| Internet | Only to download PowerShell 7 (or supply `-PS7ZipPath` and `-PS7ZipSha256`) |
| Test target 1 | Hyper-V on the build host or another host (a Generation 2 VM) |
| Test target 2 | One bare node with iDRAC or BMC virtual media, or a USB stick (its contents are erased) |

## 1. Install the ADK and the WinPE add-on

From an elevated prompt:

```powershell
winget install Microsoft.WindowsADK
winget install Microsoft.ADKPEAddon
```

Install **both**, and install the add-on **after** the ADK. In the ADK installer you only need
*Deployment Tools*; the add-on is a separate download that provides `copype.cmd` and the WinPE optional components.

Confirm what is installed (the build script reads the same values and records them in the build manifest):

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object DisplayName -like 'Windows Assessment and Deployment Kit*' |
  Select-Object DisplayName, DisplayVersion
```

Expected: two rows, both `10.1.26100.<build>`. Another version is allowed, the build prints a warning
and the manifest says `matchesExpected: false`. Record it in the checklist at the end.

## 2. Get the repository and run the pre-flight checks

```powershell
git clone https://github.com/AzureLocal/azurelocal-beacon
cd azurelocal-beacon

# The vendored Environment Checker module matches its pin and is signed by Microsoft
pwsh -File .\scripts\Update-BeaconModules.ps1
# Expected last lines:  Pinned: AzStackHci.EnvironmentChecker 10.2605.0.2006 ...   Signatures: 245 script files Valid ...

# Unit tests (no ADK needed)
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Minimal
# Expected: Tests Passed: <n>, Failed: 0
```

If the tests or the module check fail, stop. Do not build.

## 3. Build the ISO

Dry run first. It runs every pre-flight check (administrator, ADK, module, PowerShell 7 hash) without touching a workspace:

```powershell
.\src\Build-WinPEImage.ps1 -WhatIf
```

Then the real build:

```powershell
.\src\Build-WinPEImage.ps1 -OutputPath D:\beacon-out
```

Add `-Brand "Your organisation"` to print one extra line under the boot banner. Nothing vendor-specific is
built in. Offline build: `-PS7ZipPath <zip> -PS7ZipSha256 <hash from the release's hashes.sha256>`.

What you should see, in order:

1. `ADK 10.1.26100.x matches expected 10.1.26100.*` (or the warning described above).
2. `Downloaded and SHA256-verified: ...PowerShell-7.x.y-win-x64.zip`. A hash mismatch or a release without a published hash **stops the build**, which is intended.
3. Steps 1 to 11: workspace, `copype`, DISM mount, driver injection (5 INF files from `drivers\dell-ax`), six optional components, PowerShell 7, module, scripts, `lib`, config, `startnet.cmd`, `build-manifest.json`, scratch space, unmount and commit.
4. Step 12: `ISO created: D:\beacon-out\azl-beacon-1.1.0-<yyyyMMdd>.iso` and `Build manifest: ...build-manifest.json`.

Typical duration 5 to 15 minutes. If the build fails after the mount step the script discards the mount; if a
mount is left behind anyway run `dism /Cleanup-Mountpoints` and delete the workspace.

Check the artefacts:

```powershell
Get-Item D:\beacon-out\azl-beacon-*.iso | Select-Object Name, Length      # roughly 500 MB to 700 MB
$m = Get-Content D:\beacon-out\azl-beacon-*.build-manifest.json -Raw | ConvertFrom-Json
$m.tool.version                    # 1.1.0
$m.adk                             # versions of the ADK and add-on, matchesExpected
$m.powershell7                     # version, sha256, verified = True, source
$m.environmentChecker.version      # 10.2605.0.2006
$m.iso.sha256                      # hash of the ISO you are about to boot; keep it
```

The same manifest without the `iso` block is inside the image at `X:\Tools\build-manifest.json`.

## 4. Boot test A: Hyper-V Generation 2 VM

This proves the image boots (UEFI), the scripts load, the menu works and a network path to Azure works.

```powershell
$iso  = (Get-Item D:\beacon-out\azl-beacon-*.iso).FullName
$name = 'beacon-test'
New-VM -Name $name -Generation 2 -MemoryStartupBytes 4GB -NoVHD -SwitchName 'Default Switch'
Set-VMProcessor -VMName $name -Count 2
Add-VMDvdDrive -VMName $name -Path $iso
Set-VMFirmware -VMName $name -FirstBootDevice (Get-VMDvdDrive -VMName $name) -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Start-VM $name; vmconnect.exe localhost $name
```

Notes:

- **Legacy network adapter.** A Generation 2 VM has only the synthetic adapter; WinPE carries the in-box Hyper-V network driver, so the VM gets an address from the Default Switch. The *legacy* (emulated) adapter exists only on **Generation 1** VMs. If you also want the driver-less case, repeat with `-Generation 1`, `Add-VMNetworkAdapter -IsLegacy $true`, and BIOS boot from the DVD drive. Record both results.
- When the console shows *Press any key to boot from CD or DVD*, press a key within five seconds.
- 4 GB of memory is plenty; WinPE runs entirely from RAM.

### What you should see

| Time | Screen |
|---|---|
| 0:00 | Windows PE logo, then a black console. `wpeinit` runs (a few seconds). |
| 0:10 | `AzL Beacon v1.1.0`, `Azure Local Pre-Deployment Validation`, and your `-Brand` line if you set one. |
| 0:15 | `Launching AzL Beacon (interactive menu)...` If `X:\Tools\PowerShell7\pwsh.exe` fails you see `Falling back to Windows PowerShell 5.1...`: that is acceptable and must be recorded. |
| 0:20 | ASCII BEACON banner, `Initializing network bootstrap...`, a 15 second wait for DHCP, then `[OK] DHCP acquired: <address>` plus gateway and DNS lines. Verification lines for gateway, DNS and `login.microsoftonline.com:443` end with `[OK]`. |
| 0:40 | The **Validation Menu** with options 0 to 9 and `Network Status` showing IP, NIC, GW, DNS, HTTPS. |

### Run these checks in the VM

1. Menu **3** (Networking and Firewall), accept the bootstrap gateway and DNS. Expected: Category 1 NIC pass; Category 2 pass; Category 4 prints `Endpoint-Region` (`eastus` with a warning if you never set a region) and about 80 `EP-` lines, mostly `[PASS]` through the Default Switch NAT; `PublicIP-` and `TlsInspection-` lines pass; Category 5 loads the module and runs the Connectivity validator (several minutes; the first import is slow).
2. Menu **9**: set region `westeurope`, run menu **3** again, confirm the `EP-weu.his.arc.azure.com` row appears and `EP-eus...` does not.
3. Menu **5** (Arc readiness) with a throwaway test subscription: a URL and code are printed, sign in from another device, expect the `Arc-RP-...` lines. Skip this if you have no suitable subscription and say so in the checklist.
4. Open menu **7** (PowerShell console) and confirm the tools Beacon relies on exist:

   ```powershell
   Get-Command curl.exe, Resolve-DnsName, Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name
   $PSVersionTable.PSVersion
   [Net.ServicePointManager]::SecurityProtocol
   ```

   `curl.exe`, `Resolve-DnsName` and `Get-NetAdapter` are expected to be **absent** in WinPE. Beacon has fallbacks for all three (.NET HTTP probe, raw UDP DNS and `nslookup`, WMI adapter name). Write down which ones were present. Also run `fsutil volume diskfree X:` and record the free space on the RAM drive (512 MB scratch space; the module and PowerShell 7 are part of the image, results and temp files need room).
5. Menu **8** (Export results) to a second VHD or a USB-passthrough disk, or to an SMB share. Then on the host:

   ```powershell
   Test-Json -Json (Get-Content <exported>\validation-*.json -Raw) -SchemaFile .\docs\reference\results.schema.json
   ```

   Expected `True`.

Delete the VM afterwards: `Stop-VM $name -TurnOff; Remove-VM $name -Force`.

## 5. Boot test B: a bare node

1. Virtual media: mount `azl-beacon-1.1.0-<date>.iso` in the BMC (Dell iDRAC: *Virtual Console > Virtual Media > Connect > Map CD/DVD*). USB: `.\src\Build-WinPEImage.ps1 -BuildUSB -UsbDriveLetter F` (**the drive is erased**) or write the ISO with a UEFI-capable tool.
2. One-time boot to *Virtual CD/DVD* or the USB device (UEFI).
3. After boot, check the network status block in the menu. If no address was acquired the NIC driver for that model is probably missing: open menu **7** and run
   `ipconfig /all` and `pnputil /enum-devices /problem`. Capture the hardware IDs of the adapters without a driver; they go into the driver set (see [drivers](../drivers/dell-ax.md#other-oems)).
4. Menu **6** enters a static address if DHCP is not available (address, mask, gateway and DNS are validated before they are applied).
5. Run menu **1** or **2** with the real domain controller, DNS and Key Vault values, then menu **8** to copy the results off. The RAM drive is lost on reboot.

Pass criteria for the node: image boots, at least one NIC gets an address, the menu runs the chosen path to the end, results are exported and the JSON validates against the schema.

## 6. If something does not work

| Symptom | Likely cause and next step |
|---|---|
| Build stops at `copype`/`DandISetEnv.bat not found` | ADK or add-on missing or the add-on is a different version; reinstall both. |
| `Module 'AzStackHci.EnvironmentChecker' not found` at the very start | `tools/modules` is empty: `git lfs`/clone problem, or run `scripts/Update-BeaconModules.ps1 -Refresh`. |
| PowerShell 7 hash error | The release's `hashes.sha256` does not list the zip, or the file is corrupt. Download the zip yourself and pass `-PS7ZipPath` with `-PS7ZipSha256`. |
| VM does not boot the ISO | Gen 2: press a key at the prompt, keep Secure Boot template `MicrosoftWindows`. Gen 1: check boot order. |
| Menu shows but `pwsh.exe` message says a DLL is missing | Expected possibility: PowerShell 7 needs runtime files WinPE may lack. The 5.1 fallback must then work; record it. |
| Category 5 says `Import failed` | Note the exact message (the module targets Windows PowerShell 5.1 and needs .NET Framework from `WinPE-NetFX`). Capture a screenshot. |
| Every critical endpoint fails but the ping and DNS lines pass | A proxy or TLS inspection in the path. Use menu **9** for the proxy, and read the `TlsInspection-` lines. |

## 7. Record the result in the repository

Copy this block into a new file `docs/verification/first-boot-<yyyymmdd>.md` (create the folder), fill it in and commit it.

```markdown
# First boot verification <yyyy-mm-dd>

- Build host OS and PowerShell version:
- ADK version / WinPE add-on version (from the build manifest):
- PowerShell 7 version, sha256 verified (true/false):
- Environment Checker version:
- ISO file name, size, sha256:
- Beacon commit (from the manifest `gitCommit`):

## Hyper-V Generation 2 (synthetic adapter)
- [ ] ISO booted, menu reached          (seconds to menu: )
- [ ] pwsh 7 started / fell back to 5.1 (circle one)
- [ ] DHCP address acquired
- [ ] curl.exe present: y/n   Resolve-DnsName present: y/n   Get-NetAdapter present: y/n
- [ ] Menu 3: pass/warn/fail counts:
- [ ] Category 5 module import ok / error text:
- [ ] Category 5 Connectivity validator result:
- [ ] Menu 5 Arc readiness run (y/n), sign-in worked (y/n), provider lines correct (y/n)
- [ ] Export to USB/SMB/HTTPS worked; JSON validates against results.schema.json
## Hyper-V Generation 1 (legacy adapter), optional
- [ ] booted / address acquired / menu 3 summary:
## Bare node (model, firmware, boot mode)
- [ ] booted / NICs with driver / NICs without driver (hardware IDs):
- [ ] static address entry worked (if used)
- [ ] menu path run (1/2/3/4) and verdict:
- [ ] results exported and validated
## Problems found (and issue links)
```

Then update the CHANGELOG through the normal release process and remove the sentence "nothing in this release has booted yet" from the release notes only after this block is committed with ticks in the first two sections.
