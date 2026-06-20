#Requires -Version 7.4
<#
.SYNOPSIS
    Builds a bootable WinPE validation image for Azure Local pre-deployment readiness checks.

.DESCRIPTION
    Assembles a WinPE (Windows Preinstallation Environment) ISO and optional USB image that
    runs the AzL Beacon pre-deployment validation suite without requiring an installed OS.

    Build steps performed:
      1. Verify Windows ADK and WinPE add-on are installed; fail with install instructions if not.
      2. Run copype to create a fresh WinPE workspace.
      3. Mount boot.wim with DISM.
      4. Inject NIC drivers recursively if -DriverPath is supplied.
      5. Add WinPE optional components (WMI, NetFX, Scripting, PowerShell, StorageWMI, DismCmdlets)
         with matching en-us language packs.
      6. Extract PowerShell 7 into \Tools\PowerShell7 inside the mounted image.
      7. Stage AzStackHci.EnvironmentChecker module into \Tools\Modules. Copies from local
         -ModuleCachePath (default C:\build\modules) if present; otherwise downloads from
         PSGallery with a 5-minute timeout and caches locally. FAILS the build if unavailable.
      8. Copy Start-AzlValidation.ps1 and the config folder into \Tools.
      9. Write startnet.cmd into \Windows\System32\startnet.cmd.
     10. Set scratch space to 512 MB.
     11. Unmount and commit the image.
     12. Build ISO via MakeWinPEMedia.
     13. Optionally write to USB via MakeWinPEMedia /UFD if -BuildUSB and -UsbDriveLetter are set.

    The image is stage 1 of the 5-stage Azure Local validation lifecycle. See
    docs/index.md for the full coverage matrix.

    All environment values (DNS, domain, node IPs) are supplied via the config folder
    copied into the image -- no values are hardcoded in this script.

.PARAMETER WorkspacePath
    Directory where copype will create the WinPE workspace.
    Deleted and recreated on each run to ensure a clean build.
    Default: C:\WinPE_build

.PARAMETER OutputPath
    Directory where the final ISO (and USB media if -BuildUSB) will be written.
    Created if it does not exist.
    Default: .\output (relative to script location)

.PARAMETER DriverPath
    Optional folder containing exported NIC drivers (.inf files, searched recursively).
    Export from a provisioned node with: Export-WindowsDriver -Destination C:\drivers
    If absent or not found, a warning is emitted and the build continues without driver injection.

.PARAMETER PS7ZipPath
    Path to a PowerShell-7.x-win-x64.zip file to extract into the image.
    If omitted, the script downloads the latest PS 7 LTS release zip from GitHub.

.PARAMETER ConfigPath
    Path to the folder containing per-POC config files that will be copied into
    \Tools\config inside the image. Defaults to src/winpe/config relative to the repo root.

.PARAMETER SkipModuleDownload
    Skip the Save-Module step for AzStackHci.EnvironmentChecker.
    Use on air-gapped build machines. The module can be pre-staged manually at
    <WorkspacePath>\mount\Tools\Modules before the unmount step.

.PARAMETER BuildUSB
    If set, also writes the image to a USB drive after ISO creation.
    Requires -UsbDriveLetter.

.PARAMETER UsbDriveLetter
    Drive letter of the target USB drive (e.g. E). Used only with -BuildUSB.
    WARNING: the target drive will be reformatted. Verify the letter before running.

.EXAMPLE
    .\Build-WinPEImage.ps1
    Minimal build using defaults. Downloads PS7 LTS from GitHub, skips driver injection.

.EXAMPLE
    .\Build-WinPEImage.ps1 -DriverPath C:\drivers -PS7ZipPath C:\downloads\PowerShell-7.4.6-win-x64.zip
    Full build with pre-exported drivers and a cached PS7 zip (air-gap friendly).

.EXAMPLE
    .\Build-WinPEImage.ps1 -DriverPath C:\drivers -BuildUSB -UsbDriveLetter F -OutputPath D:\iso-output
    Build ISO and also write to USB drive F:.

.EXAMPLE
    .\Build-WinPEImage.ps1 -SkipModuleDownload -OutputPath D:\iso
    Build without attempting to download from PowerShell Gallery.

.NOTES
    Version:       1.0
    Last Updated:  2026-06-10
    Prerequisites:
      - Windows ADK (winget install Microsoft.WindowsADK)
      - WinPE Add-on  (winget install Microsoft.ADKPEAddon)
      - Must run as Administrator (DISM mount requires elevation)
      - Internet access required unless -SkipModuleDownload and -PS7ZipPath are both supplied
    Related:
      - docs/index.md                      -- full validation lifecycle and coverage matrix
      - src/Start-AzlValidation.ps1        -- validation script bundled in the image
      - src/config/                        -- per-engagement config files bundled in the image
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspacePath = 'C:\WinPE_build',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter(Mandatory = $false)]
    [string]$DriverPath = (Join-Path $PSScriptRoot '..\drivers\dell-ax'),

    [Parameter(Mandatory = $false)]
    [string]$PS7ZipPath = '',

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '',

    [Parameter(Mandatory = $false)]
    [string]$ModuleCachePath = 'C:\build\modules',

    [Parameter(Mandatory = $false)]
    [switch]$SkipModuleDownload,

    [Parameter(Mandatory = $false)]
    [switch]$BuildUSB,

    [Parameter(Mandatory = $false)]
    [string]$UsbDriveLetter = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Constants — derived from parameters at runtime
# ============================================================
$ADK_ROOT       = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
$WINPE_ADK_ROOT = Join-Path $ADK_ROOT 'Windows Preinstallation Environment'
$COPYPE_PATH    = Join-Path $WINPE_ADK_ROOT 'copype.cmd'
$DANDI_ENV      = Join-Path $ADK_ROOT 'Deployment Tools\DandISetEnv.bat'
$OC_BASE        = Join-Path $WINPE_ADK_ROOT 'amd64\WinPE_OCs'
$MOUNT_PATH     = Join-Path $WorkspacePath 'mount'
$MEDIA_PATH     = Join-Path $WorkspacePath 'media'
$BOOT_WIM       = Join-Path $MEDIA_PATH 'sources\boot.wim'
$TOOLS_DIR      = 'Tools'   # relative to mount root

# WinPE optional components -- order matters (WMI before PowerShell, etc.)
$OPTIONAL_COMPONENTS = @(
    'WinPE-WMI',
    'WinPE-NetFX',
    'WinPE-Scripting',
    'WinPE-PowerShell',
    'WinPE-StorageWMI',
    'WinPE-DismCmdlets'
)

$PS_GALLERY_MODULE = 'AzStackHci.EnvironmentChecker'

# ============================================================
# Logging helpers
# ============================================================
function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $stamp  = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'Success' { '[OK]   ' }
        'Warning' { '[WARN] ' }
        'Error'   { '[ERR]  ' }
        default   { '[.....] ' }
    }
    # Information stream, NOT Write-Output: helper functions return values via
    # the pipeline, and stdout logging would corrupt those return values.
    Write-Information -MessageData "$stamp $prefix $Message" -InformationAction Continue
}

# ============================================================
# Cleanup helper — dismounts any lingering mount
# ============================================================
function Invoke-MountCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Discard
    )
    Write-Step 'Checking for mounted WIM to clean up...' -Level Warning
    $mountInfo = & dism /Get-MountedImageInfo 2>&1
    if ($mountInfo -match [regex]::Escape($MOUNT_PATH)) {
        $action = if ($Discard) { '/Discard' } else { '/Commit' }
        Write-Step "Dismounting image at $MOUNT_PATH ($action)..." -Level Warning
        & dism /Unmount-Image /MountDir:$MOUNT_PATH $action | Out-Null
    }
}

# ============================================================
# ADK verification
# ============================================================
function Assert-AdkInstalled {
    [CmdletBinding()]
    param()

    $missing = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $COPYPE_PATH))   { $missing.Add("WinPE copype.cmd not found: $COPYPE_PATH") }
    if (-not (Test-Path $DANDI_ENV))     { $missing.Add("ADK DandISetEnv.bat not found: $DANDI_ENV") }
    if (-not (Test-Path $OC_BASE))       { $missing.Add("WinPE OCs folder not found: $OC_BASE") }

    if ($missing.Count -gt 0) {
        $installGuide = @(
            'Windows ADK and/or WinPE Add-on are missing. Install via winget (elevated terminal):'
            '  winget install Microsoft.WindowsADK'
            '  winget install Microsoft.ADKPEAddon'
            ''
            'Missing:'
        ) + $missing
        throw ($installGuide -join "`n")
    }
    Write-Step 'ADK and WinPE add-on verified.' -Level Success
}

# ============================================================
# PS7 zip acquisition
# ============================================================
function Get-ResolvedPS7Zip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProvidedPath
    )

    if ($ProvidedPath -and (Test-Path $ProvidedPath)) {
        Write-Step "Using provided PS7 zip: $ProvidedPath"
        return $ProvidedPath
    }

    if ($ProvidedPath -and -not (Test-Path $ProvidedPath)) {
        Write-Warning "PS7ZipPath '$ProvidedPath' not found. Downloading from GitHub."
    }

    Write-Step 'Querying GitHub for latest PowerShell 7 LTS release...'
    try {
        $headers   = @{ 'User-Agent' = 'AzlPocWinPEBuilder/1.0' }
        $releases  = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases' `
                         -Headers $headers -TimeoutSec 30
        $release   = $releases | Where-Object {
            (-not $_.prerelease) -and ($_.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.zip' })
        } | Select-Object -First 1

        if ($null -eq $release) { throw 'No suitable PowerShell release found on GitHub.' }

        $asset = $release.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.zip' } |
                 Select-Object -First 1
        $dest  = Join-Path $env:TEMP $asset.name

        Write-Step "Downloading $($asset.name) from GitHub..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing
        Write-Step "Downloaded to $dest" -Level Success
        return $dest
    }
    catch {
        throw "Failed to download PowerShell 7 LTS: $_`nProvide -PS7ZipPath to use a cached file."
    }
}

# ============================================================
# Config path resolution (repo-relative fallback)
# ============================================================
function Get-ResolvedConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProvidedPath
    )

    if ($ProvidedPath -and (Test-Path $ProvidedPath)) {
        return $ProvidedPath
    }

    # Walk up from script location seeking repo root (src\config)
    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 8; $i++) {
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
        if (Test-Path (Join-Path $dir 'src\config')) {
            $resolved = Join-Path $dir 'src\config'
            Write-Step "Config path resolved to: $resolved"
            return $resolved
        }
    }

    if ($ProvidedPath) {
        throw "ConfigPath '$ProvidedPath' not found and repo root could not be located."
    }

    # Return a path that may not exist -- the copy step will warn and continue
    return (Join-Path $PSScriptRoot 'config')
}

# ============================================================
# DISM wrapper
# ============================================================
function Invoke-DismCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$Description
    )

    $desc = if ($Description) { $Description } else { "dism $($Arguments -join ' ')" }
    Write-Step $desc

    if ($WhatIfPreference) {
        Write-Step "WhatIf: dism $($Arguments -join ' ')"
        return
    }

    & dism @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "DISM failed (exit $LASTEXITCODE): $desc"
    }
}

# ============================================================
# MakeWinPEMedia wrapper
# ============================================================
function Invoke-MakeWinPEMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ISO', 'UFD')]
        [string]$MediaType,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $makeMediaCmd = Join-Path $WINPE_ADK_ROOT 'MakeWinPEMedia.cmd'
    if (-not (Test-Path $makeMediaCmd)) {
        throw "MakeWinPEMedia.cmd not found at: $makeMediaCmd"
    }

    $flag = if ($MediaType -eq 'ISO') { '/ISO' } else { '/UFD' }
    Write-Step "Building $MediaType to: $Destination"

    if ($WhatIfPreference) {
        Write-Step "WhatIf: MakeWinPEMedia $flag $WorkspacePath $Destination"
        return
    }

    # DandISetEnv.bat must be sourced first -- MakeWinPEMedia shells out to
    # oscdimg.exe, which is only on PATH inside the ADK deployment environment.
    & cmd.exe /c "`"$DANDI_ENV`" && `"$makeMediaCmd`" $flag `"$WorkspacePath`" `"$Destination`""
    if ($LASTEXITCODE -ne 0) {
        throw "MakeWinPEMedia failed (exit $LASTEXITCODE): $MediaType to $Destination"
    }
    Write-Step "$MediaType created: $Destination" -Level Success
}

# ============================================================
# Main build -- runs in script scope so parameters are visible
# ============================================================

Write-Step '=== AzL Beacon -- WinPE Image Build ===' -Level Info

# --- Pre-flight ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as Administrator (DISM mount requires elevation).'
}

Assert-AdkInstalled

if ($BuildUSB -and [string]::IsNullOrWhiteSpace($UsbDriveLetter)) {
    throw '-BuildUSB requires -UsbDriveLetter (e.g. -UsbDriveLetter F).'
}

$resolvedPS7Zip = Get-ResolvedPS7Zip -ProvidedPath $PS7ZipPath
$resolvedConfig = Get-ResolvedConfigPath -ProvidedPath $ConfigPath

# Resolve all paths to absolute so MakeWinPEMedia and DISM work
# regardless of the working directory when the script is invoked.
$OutputPath      = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$WorkspacePath   = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkspacePath)
if ($DriverPath) {
    $DriverPath  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DriverPath)
}

# --- Step 1: Prepare workspace ---
Write-Step 'Step 1: Preparing workspace...'
if ($PSCmdlet.ShouldProcess($WorkspacePath, 'Remove and recreate WinPE workspace')) {
    if (Test-Path $WorkspacePath) {
        Invoke-MountCleanup -Discard
        Remove-Item -Path $WorkspacePath -Recurse -Force
    }
    # Do NOT pre-create the workspace -- copype refuses to run if the
    # destination directory already exists (it creates media/mount/fwfiles).
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Step "Output directory created: $OutputPath"
}

# --- Step 2: copype ---
Write-Step 'Step 2: Running copype amd64...'
if ($PSCmdlet.ShouldProcess($WorkspacePath, 'Run copype amd64')) {
    $copypeOutput = & cmd.exe /c "`"$DANDI_ENV`" && `"$COPYPE_PATH`" amd64 `"$WorkspacePath`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "copype failed (exit $LASTEXITCODE):`n$copypeOutput"
    }
    Write-Step 'copype complete.' -Level Success
}

# --- Step 3: Mount boot.wim ---
Write-Step 'Step 3: Mounting boot.wim...'
try {
    Invoke-DismCommand -Arguments @('/Mount-Image', "/ImageFile:$BOOT_WIM", '/Index:1', "/MountDir:$MOUNT_PATH") `
                       -Description "Mount boot.wim index 1 at $MOUNT_PATH"
}
catch {
    throw "Failed to mount boot.wim: $_"
}

# All steps after mount run inside try/finally to ensure dismount on error
try {

    # --- Step 4: Inject drivers ---
    Write-Step 'Step 4: Driver injection...'
    $resolvedDriverPath = if ($DriverPath) { $DriverPath } else { '' }
    if ($resolvedDriverPath -and (Test-Path $resolvedDriverPath)) {
        # Enumerate the INF files so we can log what is being injected
        $infFiles = Get-ChildItem -Path $resolvedDriverPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue
        if ($infFiles) {
            Write-Step "  Found $($infFiles.Count) INF file(s) to inject:"
            foreach ($inf in $infFiles) {
                # Read DriverVer from the INF for a build-log summary
                $driverVer = ''
                try {
                    $infContent = Get-Content $inf.FullName -ErrorAction SilentlyContinue
                    $verLine = $infContent | Where-Object { $_ -match '^\s*DriverVer\s*=' } | Select-Object -First 1
                    if ($verLine -and $verLine -match '=\s*(.+)$') { $driverVer = $Matches[1].Trim() }
                } catch { }
                $logLine = "    $($inf.Name)"
                if ($driverVer) { $logLine += "  [DriverVer=$driverVer]" }
                Write-Step $logLine
            }
        }
        Invoke-DismCommand -Arguments @("/Image:$MOUNT_PATH", '/Add-Driver', "/Driver:$resolvedDriverPath", '/Recurse') `
                           -Description "Inject drivers from $resolvedDriverPath"
        Write-Step "Driver injection complete ($($infFiles.Count) INF(s))." -Level Success
    }
    elseif ($resolvedDriverPath -and -not (Test-Path $resolvedDriverPath)) {
        Write-Warning "DriverPath '$resolvedDriverPath' not found. Skipping driver injection."
        Write-Warning 'Run the build from the repo root so drivers/dell-ax/ is discoverable, or supply -DriverPath.'
        Write-Step 'Driver injection skipped.' -Level Warning
    }
    else {
        Write-Warning 'No DriverPath resolved. Image will use WinPE default NIC driver set only.'
        Write-Step 'Driver injection skipped.' -Level Warning
    }

    # --- Step 5: WinPE optional components ---
    Write-Step 'Step 5: Adding WinPE optional components...'
    foreach ($component in $OPTIONAL_COMPONENTS) {
        $cab     = Join-Path $OC_BASE "$component.cab"
        $langCab = Join-Path $OC_BASE "en-us\${component}_en-us.cab"

        if (-not (Test-Path $cab)) {
            throw "Optional component cab not found: $cab"
        }

        Invoke-DismCommand -Arguments @("/Image:$MOUNT_PATH", '/Add-Package', "/PackagePath:$cab") `
                           -Description "Add $component"

        if (Test-Path $langCab) {
            Invoke-DismCommand -Arguments @("/Image:$MOUNT_PATH", '/Add-Package', "/PackagePath:$langCab") `
                               -Description "Add $component en-us language pack"
        }
        else {
            Write-Warning "Language pack not found (non-fatal): $langCab"
        }
    }
    Write-Step 'Optional components added.' -Level Success

    # --- Step 6: Extract PowerShell 7 ---
    Write-Step 'Step 6: Extracting PowerShell 7...'
    $ps7Dest = Join-Path $MOUNT_PATH "$TOOLS_DIR\PowerShell7"
    if ($PSCmdlet.ShouldProcess($ps7Dest, 'Extract PowerShell 7 zip')) {
        New-Item -ItemType Directory -Path $ps7Dest -Force | Out-Null
        Expand-Archive -Path $resolvedPS7Zip -DestinationPath $ps7Dest -Force
        Write-Step "PowerShell 7 extracted to $ps7Dest" -Level Success
    }

    # --- Step 7: Stage AzStackHci.EnvironmentChecker module ---
    Write-Step 'Step 7: Staging AzStackHci.EnvironmentChecker module (mandatory)...'
    $moduleDest = Join-Path $MOUNT_PATH "$TOOLS_DIR\Modules"
    New-Item -ItemType Directory -Path $moduleDest -Force | Out-Null

    $cacheModule = Join-Path $ModuleCachePath $PS_GALLERY_MODULE
    if (Test-Path $cacheModule) {
        Write-Step "Module found in local cache ($ModuleCachePath) — copying into image..."
        Copy-Item -Path $cacheModule -Destination $moduleDest -Recurse -Force
        Write-Step "$PS_GALLERY_MODULE staged from cache." -Level Success
    }
    elseif ($SkipModuleDownload) {
        throw "Module '$PS_GALLERY_MODULE' not found in cache '$ModuleCachePath' and -SkipModuleDownload is set. " +
              "Pre-stage the module by running: Save-Module -Name $PS_GALLERY_MODULE -Path '$ModuleCachePath' -Force"
    }
    else {
        Write-Step "Cache miss — downloading from PSGallery (5-min timeout)..."
        $job = Start-Job {
            Save-Module -Name $using:PS_GALLERY_MODULE -Path $using:ModuleCachePath -Force -ErrorAction Stop
        }
        $completed = $job | Wait-Job -Timeout 300
        if ($completed -and $job.State -eq 'Completed') {
            $job | Remove-Job -Force
            Copy-Item -Path $cacheModule -Destination $moduleDest -Recurse -Force
            Write-Step "$PS_GALLERY_MODULE downloaded and staged." -Level Success
        }
        else {
            $job | Stop-Job -PassThru | Remove-Job -Force
            throw "Save-Module timed out after 300s — PSGallery unreachable. " +
                  "Pre-stage the module: Save-Module -Name $PS_GALLERY_MODULE -Path '$ModuleCachePath' -Force"
        }
    }

    # --- Step 8: Copy validation artifacts ---
    Write-Step 'Step 8: Copying validation artifacts...'
    $toolsDest = Join-Path $MOUNT_PATH $TOOLS_DIR
    New-Item -ItemType Directory -Path $toolsDest -Force | Out-Null

    # Copy all PowerShell scripts that run inside the image
    $inImageScripts = @(
        'Start-AzlValidation.ps1',
        'Start-AzlBeacon.ps1',
        'Start-NetworkBootstrap.ps1'
    )
    foreach ($scriptName in $inImageScripts) {
        $scriptSrc = Join-Path $PSScriptRoot $scriptName
        if (Test-Path $scriptSrc) {
            if ($PSCmdlet.ShouldProcess($toolsDest, "Copy $scriptName")) {
                Copy-Item -Path $scriptSrc -Destination $toolsDest -Force
                Write-Step "Copied $scriptName." -Level Success
            }
        } else {
            $warnMsg = "$scriptName not found at $scriptSrc."
            if ($scriptName -eq 'Start-AzlValidation.ps1') {
                Write-Warning "$warnMsg Rebuild will not boot correctly without this file."
            } else {
                Write-Warning "$warnMsg The interactive menu may not function."
            }
        }
    }

    $configDest = Join-Path $toolsDest 'config'
    if (Test-Path $resolvedConfig) {
        if ($PSCmdlet.ShouldProcess($configDest, 'Copy config folder')) {
            Copy-Item -Path $resolvedConfig -Destination $configDest -Recurse -Force
            Write-Step "Config copied from $resolvedConfig." -Level Success

            # Seed a blank validation-config.json from the example if no real one was copied.
            # The menu collects actual values at runtime via Write-ValidationConfigOverrides.
            $cfgJson  = Join-Path $configDest 'validation-config.json'
            $cfgExamp = Join-Path $configDest 'validation-config.example.json'
            if (-not (Test-Path $cfgJson) -and (Test-Path $cfgExamp)) {
                Copy-Item -Path $cfgExamp -Destination $cfgJson -Force
                Write-Step 'Seeded validation-config.json from example (no engagement config provided).' -Level Warning
            }
        }
    }
    else {
        Write-Warning "Config path '$resolvedConfig' not found."
        Write-Warning 'Populate src/config/ and rebuild before use.'
    }

    # --- Step 9: Install startnet.cmd ---
    Write-Step 'Step 9: Installing startnet.cmd...'
    $startnetSrc  = Join-Path $PSScriptRoot 'startnet.cmd'
    $startnetDest = Join-Path $MOUNT_PATH 'Windows\System32\startnet.cmd'
    if (-not (Test-Path $startnetSrc)) {
        throw "startnet.cmd not found at $startnetSrc. It must exist in src/winpe/."
    }
    if ($PSCmdlet.ShouldProcess($startnetDest, 'Install startnet.cmd')) {
        Copy-Item -Path $startnetSrc -Destination $startnetDest -Force
        Write-Step 'startnet.cmd installed.' -Level Success
    }

    # --- Step 10: Scratch space ---
    Write-Step 'Step 10: Setting scratch space to 512 MB...'
    Invoke-DismCommand -Arguments @("/Image:$MOUNT_PATH", '/Set-ScratchSpace:512') `
                       -Description 'Set DISM scratch space 512 MB'

    # --- Step 11: Unmount and commit ---
    Write-Step 'Step 11: Unmounting and committing image...'
    if ($PSCmdlet.ShouldProcess($MOUNT_PATH, 'DISM unmount and commit')) {
        Invoke-DismCommand -Arguments @('/Unmount-Image', "/MountDir:$MOUNT_PATH", '/Commit') `
                           -Description 'Unmount and commit boot.wim'
        Write-Step 'Image committed.' -Level Success
    }

}
catch {
    Write-Step "Build failed: $_" -Level Error
    Invoke-MountCleanup -Discard
    throw
}

# --- Step 12: Build ISO ---
Write-Step 'Step 12: Building ISO...'
$datestamp = Get-Date -Format 'yyyyMMdd'
$isoPath   = Join-Path $OutputPath "azl-validate-$datestamp.iso"
if ($PSCmdlet.ShouldProcess($isoPath, 'Build WinPE ISO')) {
    Invoke-MakeWinPEMedia -MediaType 'ISO' -Destination $isoPath
}

# --- Step 13: Optional USB ---
if ($BuildUSB) {
    $usbTarget = "$($UsbDriveLetter.TrimEnd(':')):"
    Write-Step "Step 13: Writing to USB drive $usbTarget..."
    if ($PSCmdlet.ShouldProcess("Drive $usbTarget", 'Write WinPE USB (DRIVE WILL BE REFORMATTED)')) {
        Invoke-MakeWinPEMedia -MediaType 'UFD' -Destination $usbTarget
    }
}

# --- Summary ---
Write-Step '' -Level Info
Write-Step '=== Build Complete ===' -Level Success
Write-Step "ISO output : $isoPath" -Level Success
if ($BuildUSB) {
    Write-Step "USB drive  : $UsbDriveLetter`:" -Level Success
}
Write-Step '' -Level Info
Write-Step 'Next steps:' -Level Info
Write-Step '  1. Mount the ISO via iDRAC Virtual Media on the target POC node.' -Level Info
Write-Step '  2. Boot the node to the virtual CD/DVD (one-time boot menu).' -Level Info
Write-Step '  3. Validation script runs automatically on boot.' -Level Info
Write-Step '  4. Results land at X:\results\ on the WinPE RAM drive.' -Level Info
Write-Step '  5. Copy X:\results\ before reboot (network share or iDRAC virtual file copy).' -Level Info
Write-Step '  See docs/index.md for the full validation lifecycle.' -Level Info
