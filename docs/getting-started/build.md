# Build the ISO

Run from an elevated PowerShell 7 prompt at the repository root. The first build should follow
[Build and first-boot verification](verify-build.md).

## Standard build

```powershell
.\src\Build-WinPEImage.ps1
```

The ISO is written to `src/output/azl-beacon-<version>-<yyyyMMdd>.iso`, next to a `.build-manifest.json`
(versions, hashes, date, ISO hash). The same manifest without the ISO block is inside the image at `X:\Tools\build-manifest.json`.

## PowerShell 7 and its hash

PowerShell 7 is extracted into the image (best effort; Windows PowerShell 5.1 is the fallback at boot). The zip is **always verified**:

| Situation | What happens |
|---|---|
| Download (default) | Latest stable release, or `-PS7Version 7.6.6`. The SHA256 comes from the release's `hashes.sha256`; no hash or a mismatch stops the build |
| `-PS7ZipPath <zip> -PS7ZipSha256 <hash>` | Hash compared; mismatch stops the build |
| `-PS7ZipPath <zip>` only | Stops: no expected hash. `-AllowUnverifiedPS7` accepts it and records `verified: false` |

```powershell
.\src\Build-WinPEImage.ps1 -PS7ZipPath C:\cache\PowerShell-7.6.6-win-x64.zip -PS7ZipSha256 <hash from hashes.sha256>
```

## Other options

```powershell
.\src\Build-WinPEImage.ps1 -BuildUSB -UsbDriveLetter F      # also write a USB stick (erases it)
.\src\Build-WinPEImage.ps1 -DriverPath C:\my-drivers        # other hardware, see the drivers page
.\src\Build-WinPEImage.ps1 -Brand "Contoso Labs"            # optional line under the boot banner
.\src\Build-WinPEImage.ps1 -WhatIf                          # pre-flight only
```

> [!CAUTION]
> **The USB drive is reformatted.** Verify the drive letter first.

> [!WARNING]
> **Engagement config is copied into the image.** If `src/config/validation-config.json` exists it is baked in (it is gitignored).
> Without it an example config is seeded and the menu collects real values at boot. Do not publish an ISO built with real site data.

## What the build does

| Step | Action |
|---|---|
| pre | Administrator, ADK and add-on present and versions recorded, Environment Checker module present, PowerShell 7 zip obtained and verified |
| 1-2 | Clean workspace, `copype amd64` |
| 3 | DISM mount `boot.wim` |
| 4 | Inject NIC drivers (recursive) |
| 5 | WinPE optional components: WMI, NetFX, Scripting, PowerShell, StorageWMI, DismCmdlets (+ en-us packs) |
| 6 | Extract PowerShell 7 to `\Tools\PowerShell7` |
| 7 | Stage the pinned `AzStackHci.EnvironmentChecker` to `\Tools\Modules` |
| 8 | Copy scripts, `lib\` and `config\` to `\Tools` |
| 9 | Install `startnet.cmd` (version and brand filled in) and write `build-manifest.json` |
| 10 | DISM scratch space 512 MB |
| 11 | Unmount and commit |
| 12 | MakeWinPEMedia to ISO, write the sidecar manifest |
| 13 | Optional USB |

The ADK build cannot run on a hosted CI runner. The [manual workflow](https://github.com/AzureLocal/azurelocal-beacon/blob/main/.github/workflows/build-iso-manual.yml)
only prints this procedure.
