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
      7. Stage the pinned AzStackHci.EnvironmentChecker module (tools/modules, see
         modules.lock.json) into \Tools\Modules. The build fails EARLY if it is missing.
      8. Copy the in-image scripts, lib/ and the config folder into \Tools.
      9. Write startnet.cmd into \Windows\System32\startnet.cmd (version/brand tokens replaced) and
         build-manifest.json into \Tools (ADK/PS7/module versions and hashes, drivers, scripts).
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
    If omitted, the script downloads the release zip from GitHub (the latest stable release, or
    -PS7Version if given). The zip is ALWAYS verified against a SHA256: the hashes.sha256 asset
    published with the PowerShell release (download) or -PS7ZipSha256 (supplied file).

.PARAMETER PS7ZipSha256
    Expected SHA256 of -PS7ZipPath (from the hashes.sha256 asset of that PowerShell release).
    If a supplied zip has no expected hash the build fails unless -AllowUnverifiedPS7 is set.

.PARAMETER PS7Version
    Exact PowerShell release to download, e.g. 7.6.6. Default: latest stable release.

.PARAMETER AllowUnverifiedPS7
    Accept a supplied -PS7ZipPath that has no expected hash (the computed hash is still recorded in
    the build manifest). Not recommended.

.PARAMETER Brand
    Optional single line shown under the banner (for example your organisation name). ASCII only.
    Nothing vendor-specific is hard-coded in the image.

.PARAMETER ConfigPath
    Path to the folder containing per-POC config files that will be copied into
    \Tools\config inside the image. Defaults to src/winpe/config relative to the repo root.

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
    Version:       see src/lib/Beacon.Version.ps1
    Last Updated:  2026-10-15
    Prerequisites:
      - Windows ADK (winget install Microsoft.WindowsADK)
      - WinPE Add-on  (winget install Microsoft.ADKPEAddon)
      - Must run as Administrator (DISM mount requires elevation)
      - Internet access is only needed to download PowerShell 7 (supply -PS7ZipPath and -PS7ZipSha256 to build offline)
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
    [string]$PS7ZipSha256 = '',

    [Parameter(Mandatory = $false)]
    [string]$PS7Version = '',

    [Parameter(Mandatory = $false)]
    [switch]$AllowUnverifiedPS7,

    [Parameter(Mandatory = $false)]
    [string]$Brand = '',

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '',

    [Parameter(Mandatory = $false)]
    [string]$ModulesPath = (Join-Path $PSScriptRoot '..\tools\modules'),

    [Parameter(Mandatory = $false)]
    [switch]$BuildUSB,

    [Parameter(Mandatory = $false)]
    [string]$UsbDriveLetter = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Beacon.Version.ps1')

# ============================================================
# Constants - derived from parameters at runtime
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
# Cleanup helper - dismounts any lingering mount
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
# PS7 zip acquisition and verification
# ============================================================
function Get-ExpectedZipHash {
    <# Finds the SHA256 for a file name in a hashes.sha256 text ('<hash> *<name>' or '<hash>  <name>'). Pure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$HashFileText,
        [Parameter(Mandatory)] [string]$FileName
    )
    foreach ($line in ($HashFileText -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $FileName) {
            return $Matches[1].ToLowerInvariant()
        }
    }
    return $null
}

function Test-FileSha256 {
    <# True when the file's SHA256 equals Expected (case-insensitive). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Expected
    )
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($actual -eq $Expected.Trim().ToLowerInvariant())
}

function Get-ResolvedPS7Zip {
    <#
    Returns @{ Path; Sha256; Version; Verified; Source }. Throws when the hash does not match, or when
    no expected hash can be established (unless -AllowUnverified).
    #>
    [CmdletBinding()]
    param(
        [string]$ProvidedPath,
        [string]$ExpectedSha256 = '',
        [string]$Version = '',
        [switch]$AllowUnverified
    )

    if ($ProvidedPath -and (Test-Path $ProvidedPath)) {
        Write-Step "Using provided PS7 zip: $ProvidedPath"
        $actual = (Get-FileHash -Path $ProvidedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $ver = ''
        if ((Split-Path $ProvidedPath -Leaf) -match 'PowerShell-(\d+\.\d+\.\d+[^-]*)-win-x64') { $ver = $Matches[1] }
        if ($ExpectedSha256) {
            if ($actual -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
                throw "PS7 zip SHA256 mismatch. Expected $ExpectedSha256 but the file is $actual."
            }
            Write-Step 'PS7 zip SHA256 verified against -PS7ZipSha256.' -Level Success
            return @{ Path = $ProvidedPath; Sha256 = $actual; Version = $ver; Verified = $true; Source = 'provided' }
        }
        if (-not $AllowUnverified) {
            throw "PS7 zip '$ProvidedPath' has no expected hash. Pass -PS7ZipSha256 (from the release's hashes.sha256) or -AllowUnverifiedPS7. Computed: $actual"
        }
        Write-Warning "PS7 zip accepted UNVERIFIED (-AllowUnverifiedPS7). SHA256 $actual"
        return @{ Path = $ProvidedPath; Sha256 = $actual; Version = $ver; Verified = $false; Source = 'provided' }
    }

    if ($ProvidedPath -and -not (Test-Path $ProvidedPath)) {
        Write-Warning "PS7ZipPath '$ProvidedPath' not found. Downloading from GitHub."
    }

    Write-Step 'Querying GitHub for the PowerShell 7 release...'
    try {
        $headers = @{ 'User-Agent' = 'AzlBeaconBuilder/1.1' }
        if ($Version) {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v$Version" -Headers $headers -TimeoutSec 30
        } else {
            $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases' -Headers $headers -TimeoutSec 30
            $release = $releases | Where-Object {
                (-not $_.prerelease) -and ($_.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.zip' })
            } | Select-Object -First 1
        }
        if ($null -eq $release) { throw 'No suitable PowerShell release found on GitHub.' }

        $asset = $release.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.zip' } | Select-Object -First 1
        $hashAsset = $release.assets | Where-Object { $_.name -eq 'hashes.sha256' } | Select-Object -First 1
        if ($null -eq $asset) { throw "Release $($release.tag_name) has no win-x64 zip." }
        $expected = $null
        if ($hashAsset) {
            $hashText = (Invoke-WebRequest -Uri $hashAsset.browser_download_url -UseBasicParsing -Headers $headers -TimeoutSec 30).Content
            if ($hashText -is [byte[]]) { $hashText = [System.Text.Encoding]::UTF8.GetString($hashText) }
            $expected = Get-ExpectedZipHash -HashFileText $hashText -FileName $asset.name
        }
        if (-not $expected -and $ExpectedSha256) { $expected = $ExpectedSha256.Trim().ToLowerInvariant() }
        if (-not $expected) { throw "No SHA256 published for $($asset.name) (hashes.sha256 asset missing or without an entry); refusing to use an unverified download." }

        $dest = Join-Path ([IO.Path]::GetTempPath()) $asset.name
        Write-Step "Downloading $($asset.name) from GitHub..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing
        if (-not (Test-FileSha256 -Path $dest -Expected $expected)) {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            throw "SHA256 mismatch for downloaded $($asset.name) (expected $expected)."
        }
        Write-Step "Downloaded and SHA256-verified: $dest" -Level Success
        return @{ Path = $dest; Sha256 = $expected; Version = ($release.tag_name -replace '^v', ''); Verified = $true; Source = 'github' }
    }
    catch {
        throw "Failed to obtain PowerShell 7: $_`nProvide -PS7ZipPath with -PS7ZipSha256 to use a cached file."
    }
}

# ============================================================
# ADK / WinPE add-on version detection and build manifest
# ============================================================
function Get-AdkVersionInfo {
    <# ADK and WinPE add-on versions from the Uninstall registry keys (both views). Missing = ''. #>
    [CmdletBinding()]
    param()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $info = @{ AdkVersion = ''; WinPEAddonVersion = '' }
    foreach ($k in $keys) {
        foreach ($p in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            if (-not ($p.PSObject.Properties.Name -contains 'DisplayName')) { continue }
            $name = "$($p.DisplayName)"
            $ver = ''
            if ($p.PSObject.Properties.Name -contains 'DisplayVersion') { $ver = "$($p.DisplayVersion)" }
            if ($name -match 'Windows Assessment and Deployment Kit Windows Preinstallation Environment') { $info.WinPEAddonVersion = $ver }
            elseif ($name -match '^Windows Assessment and Deployment Kit$') { $info.AdkVersion = $ver }
        }
    }
    return $info
}

function Test-AdkVersionExpectation {
    <# Returns @{ Ok; Message }. Prefix like '10.1.26100' matches '10.1.26100.2454'. Pure. #>
    [CmdletBinding()]
    param([string]$Version, [Parameter(Mandatory)] [string]$ExpectedPrefix)
    if (-not $Version) { return @{ Ok = $false; Message = 'ADK version could not be read from the registry' } }
    if ($Version.StartsWith($ExpectedPrefix)) { return @{ Ok = $true; Message = "ADK $Version matches expected $ExpectedPrefix.*" } }
    return @{ Ok = $false; Message = "ADK $Version differs from the tested $ExpectedPrefix.*; the build continues but boot behaviour is untested" }
}

function Get-StartnetContent {
    <# Replaces the @@...@@ tokens in startnet.cmd. Brand is reduced to safe ASCII and cmd-escaped. Pure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Template, [Parameter(Mandatory)] [string]$Version, [string]$Brand = '')
    $line = ''
    $safe = ($Brand -replace '[^\x20-\x7E]', '').Trim()
    if ($safe) {
        $safe = $safe -replace '([&|<>^])', '^$1' -replace '%', '%%'
        $line = "echo   $safe"
    }
    $out = $Template -replace '@@BEACON_VERSION@@', "v$Version"
    if ($line) {
        $out = $out -replace '(?m)^@@BRAND_LINE@@', $line.Replace('$', '$$')
    } else {
        $out = $out -replace '(?m)^@@BRAND_LINE@@\r?\n', ''
    }
    return $out
}

function New-BuildManifest {
    <# Pure: assembles the build manifest object from collected facts. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Facts)
    return [pscustomobject][ordered]@{
        schemaVersion      = '1.0'
        tool               = [pscustomobject][ordered]@{ name = 'AzL Beacon'; version = $Facts.Version; releaseTrain = $Facts.ReleaseTrain }
        builtUtc           = $Facts.BuiltUtc
        gitCommit          = $Facts.GitCommit
        builder            = [pscustomobject][ordered]@{ powershell = $Facts.BuilderPowerShell; os = $Facts.BuilderOs }
        adk                = [pscustomobject][ordered]@{
            adkVersion        = $Facts.AdkVersion
            winpeAddonVersion = $Facts.WinPEAddonVersion
            expectedPrefix    = $Facts.AdkExpectedPrefix
            matchesExpected   = $Facts.AdkMatches
        }
        powershell7        = [pscustomobject][ordered]@{
            version = $Facts.PS7Version; sha256 = $Facts.PS7Sha256; verified = $Facts.PS7Verified; source = $Facts.PS7Source
        }
        environmentChecker = [pscustomobject][ordered]@{ version = $Facts.EnvCheckerVersion; manifestSha256 = $Facts.EnvCheckerManifestSha256 }
        endpoints          = [pscustomobject][ordered]@{ sha256 = $Facts.EndpointsSha256; generatedUtc = $Facts.EndpointsGeneratedUtc }
        scripts            = @($Facts.Scripts)
        drivers            = @($Facts.Drivers)
    }
}

function Get-FileHashEntries {
    <# @{ path (relative); sha256 } for every file under Root matching Include. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Root, [string[]]$Include = @('*'))
    if (-not (Test-Path $Root)) { return @() }
    $rootFull = (Resolve-Path $Root).Path.TrimEnd('\')
    return @(Get-ChildItem -Path $Root -Recurse -File -Include $Include -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
            [pscustomobject][ordered]@{
                path   = $_.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
                sha256 = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
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

# Dot-sourcing (Pester tests) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

# ============================================================
# Main build -- runs in script scope so parameters are visible
# ============================================================

Write-Step "=== AzL Beacon $script:BeaconVersion -- WinPE Image Build ===" -Level Info

# --- Pre-flight ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as Administrator (DISM mount requires elevation).'
}

Assert-AdkInstalled

if ($BuildUSB -and [string]::IsNullOrWhiteSpace($UsbDriveLetter)) {
    throw '-BuildUSB requires -UsbDriveLetter (e.g. -UsbDriveLetter F).'
}

# Fail early, before anything is mounted: the Environment Checker module must be staged in the repo.
$repoModuleCheck = Join-Path $ModulesPath $PS_GALLERY_MODULE
if (-not (Test-Path $repoModuleCheck)) {
    throw "Module '$PS_GALLERY_MODULE' not found at '$ModulesPath'. Run scripts/Update-BeaconModules.ps1 first."
}

$adkInfo = Get-AdkVersionInfo
$adkCheck = Test-AdkVersionExpectation -Version $adkInfo.AdkVersion -ExpectedPrefix $script:BeaconAdkExpectation.AdkVersionPrefix
$adkLevel = 'Success'
if (-not $adkCheck.Ok) { $adkLevel = 'Warning' }
Write-Step $adkCheck.Message -Level $adkLevel
if (-not $adkInfo.WinPEAddonVersion) { Write-Warning 'WinPE add-on version could not be read; recorded as empty in the build manifest.' }

$ps7 = Get-ResolvedPS7Zip -ProvidedPath $PS7ZipPath -ExpectedSha256 $PS7ZipSha256 -Version $PS7Version -AllowUnverified:$AllowUnverifiedPS7
$resolvedPS7Zip = $ps7.Path
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
                } catch { Write-Verbose "DriverVer not read from $($inf.Name)" }
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

    $repoModule = Join-Path $ModulesPath $PS_GALLERY_MODULE
    if (Test-Path $repoModule) {
        Write-Step "Copying $PS_GALLERY_MODULE from repo modules path..."
        Copy-Item -Path $repoModule -Destination $moduleDest -Recurse -Force
        Write-Step "$PS_GALLERY_MODULE staged." -Level Success
    }
    else {
        throw "Module '$PS_GALLERY_MODULE' not found at '$ModulesPath'. " +
              "Run Update-BeaconModules.ps1 to refresh the module cache in tools/modules/."
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
        if (-not (Test-Path $scriptSrc)) { throw "In-image script not found: $scriptSrc" }
        if ($PSCmdlet.ShouldProcess($toolsDest, "Copy $scriptName")) {
            Copy-Item -Path $scriptSrc -Destination $toolsDest -Force
            Write-Step "Copied $scriptName." -Level Success
        }
    }
    # Shared libraries dot-sourced by the scripts above
    $libSrc = Join-Path $PSScriptRoot 'lib'
    if (-not (Test-Path $libSrc)) { throw "Library folder not found: $libSrc" }
    if ($PSCmdlet.ShouldProcess((Join-Path $toolsDest 'lib'), 'Copy lib folder')) {
        Copy-Item -Path $libSrc -Destination $toolsDest -Recurse -Force
        Write-Step 'Copied lib/.' -Level Success
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
            if ($Brand -and (Test-Path $cfgJson)) {
                $cfgObj = Get-Content $cfgJson -Raw | ConvertFrom-Json
                $cfgObj | Add-Member -MemberType NoteProperty -Name brand -Value $Brand -Force
                $cfgObj | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgJson -Encoding UTF8
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
        $startnetText = Get-StartnetContent -Template (Get-Content $startnetSrc -Raw) -Version $script:BeaconVersion -Brand $Brand
        [System.IO.File]::WriteAllText($startnetDest, $startnetText, [System.Text.Encoding]::ASCII)
        Write-Step 'startnet.cmd installed.' -Level Success
    }

    # --- Step 9b: Build manifest (inside the image) ---
    Write-Step 'Step 9b: Writing build-manifest.json...'
    $envManifestPath = Get-ChildItem -Path $repoModuleCheck -Recurse -Filter 'AzStackHci.EnvironmentChecker.psd1' -Depth 2 | Select-Object -First 1
    $endpointsFile = Join-Path $resolvedConfig 'endpoints.json'
    $endpointsGenerated = ''
    if (Test-Path $endpointsFile) {
        $endpointsGenerated = "$((Get-Content $endpointsFile -Raw | ConvertFrom-Json).generatedUtc)"
    }
    $gitCommit = ''
    try { $gitCommit = "$(& git -C (Split-Path $PSScriptRoot -Parent) rev-parse HEAD 2>$null)".Trim() } catch { $gitCommit = '' }
    $facts = @{
        Version = $script:BeaconVersion; ReleaseTrain = $script:BeaconReleaseTrain
        BuiltUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); GitCommit = $gitCommit
        BuilderPowerShell = $PSVersionTable.PSVersion.ToString(); BuilderOs = [System.Environment]::OSVersion.VersionString
        AdkVersion = $adkInfo.AdkVersion; WinPEAddonVersion = $adkInfo.WinPEAddonVersion
        AdkExpectedPrefix = $script:BeaconAdkExpectation.AdkVersionPrefix; AdkMatches = [bool]$adkCheck.Ok
        PS7Version = $ps7.Version; PS7Sha256 = $ps7.Sha256; PS7Verified = [bool]$ps7.Verified; PS7Source = $ps7.Source
        EnvCheckerVersion = $(if ($envManifestPath) { Split-Path (Split-Path $envManifestPath.FullName -Parent) -Leaf } else { '' })
        EnvCheckerManifestSha256 = $(if ($envManifestPath) { (Get-FileHash $envManifestPath.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' })
        EndpointsSha256 = $(if (Test-Path $endpointsFile) { (Get-FileHash $endpointsFile -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' })
        EndpointsGeneratedUtc = $endpointsGenerated
        Scripts = @(Get-FileHashEntries -Root $PSScriptRoot -Include @('*.ps1', '*.cmd') | Where-Object { $_.path -notmatch '^(Build-|Convert-)' })
        Drivers = @(if ($resolvedDriverPath -and (Test-Path $resolvedDriverPath)) { Get-FileHashEntries -Root $resolvedDriverPath -Include @('*.inf', '*.sys', '*.cat', '*.dll') })
    }
    $buildManifest = New-BuildManifest -Facts $facts
    $buildManifestJson = $buildManifest | ConvertTo-Json -Depth 6
    if ($PSCmdlet.ShouldProcess((Join-Path $toolsDest 'build-manifest.json'), 'Write build manifest')) {
        Set-Content -Path (Join-Path $toolsDest 'build-manifest.json') -Value $buildManifestJson -Encoding UTF8
        Write-Step 'build-manifest.json written into the image.' -Level Success
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
$isoPath   = Join-Path $OutputPath "azl-beacon-$script:BeaconVersion-$datestamp.iso"
if ($PSCmdlet.ShouldProcess($isoPath, 'Build WinPE ISO')) {
    Invoke-MakeWinPEMedia -MediaType 'ISO' -Destination $isoPath
    # Sidecar manifest next to the ISO: same content plus the ISO's own hash (cannot be inside the ISO).
    if (Test-Path $isoPath) {
        $sidecar = $buildManifestJson | ConvertFrom-Json
        $sidecar | Add-Member -MemberType NoteProperty -Name iso -Value ([pscustomobject][ordered]@{
                fileName = (Split-Path $isoPath -Leaf)
                sizeBytes = (Get-Item $isoPath).Length
                sha256 = (Get-FileHash $isoPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }) -Force
        $sidecarPath = [IO.Path]::ChangeExtension($isoPath, 'build-manifest.json')
        $sidecar | ConvertTo-Json -Depth 6 | Set-Content -Path $sidecarPath -Encoding UTF8
        Write-Step "Build manifest: $sidecarPath" -Level Success
    }
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
