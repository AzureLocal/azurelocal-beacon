# Build the ISO

## Standard build

```powershell title="Run from an elevated PowerShell 7 prompt"
# Navigate to the repo root
cd D:\git\azurelocal\azurelocal-beacon

# Minimal build — downloads PS7, uses bundled Dell drivers
.\src\Build-WinPEImage.ps1
```

The ISO is written to `src/output/azl-validate-<yyyyMMdd>.iso`.

## Build with cached PS7 zip

If your build machine has limited or no internet access, pre-download the PS7 LTS zip and supply it:

```powershell
.\src\Build-WinPEImage.ps1 -PS7ZipPath C:\cache\PowerShell-7.4.6-win-x64.zip
```

## Air-gapped build

```powershell
.\src\Build-WinPEImage.ps1 `
    -PS7ZipPath C:\cache\PowerShell-7.4.6-win-x64.zip `
    -SkipModuleDownload
```

!!! warning "Module not included in air-gapped builds"
    Without `AzStackHci.EnvironmentChecker`, Category 6 (environment checker) is skipped.
    Pre-stage the module at `<WorkspacePath>\mount\Tools\Modules` before the unmount step, or
    run the module-based tests from a staging server post-OS.

## Write to USB

```powershell
.\src\Build-WinPEImage.ps1 -BuildUSB -UsbDriveLetter F
```

!!! danger "The USB drive is reformatted"
    Verify the drive letter before running. All data on the drive is erased.

## Custom driver path

The build defaults to `drivers/dell-ax/` in the repo. To supply a different driver folder:

```powershell
.\src\Build-WinPEImage.ps1 -DriverPath C:\my-drivers
```

## What the build does

| Step | Action |
|---|---|
| 1 | Prepare clean workspace at `C:\WinPE_build` |
| 2 | `copype amd64` — creates WinPE media skeleton |
| 3 | DISM mount `boot.wim` |
| 4 | **Inject NIC drivers** (Dell AX: Broadcom/Mellanox/Intel — 5 INF files) |
| 5 | Add WinPE optional components: WMI, NetFX, Scripting, PowerShell, StorageWMI, DismCmdlets |
| 6 | Extract PowerShell 7 into `\Tools\PowerShell7` |
| 7 | Save `AzStackHci.EnvironmentChecker` module offline |
| 8 | Copy `Start-AzlBeacon.ps1`, `Start-NetworkBootstrap.ps1`, `Start-AzlValidation.ps1` + config into `\Tools` |
| 9 | Install `startnet.cmd` → `\Windows\System32\startnet.cmd` |
| 10 | Set DISM scratch space to 512 MB |
| 11 | DISM unmount + commit |
| 12 | MakeWinPEMedia → ISO |
| 13 | (Optional) MakeWinPEMedia → USB |
