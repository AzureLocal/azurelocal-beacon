#Requires -Version 7.0
<#
.SYNOPSIS
    Pins, refreshes and verifies the vendored AzStackHci.EnvironmentChecker module in tools/modules/.

.DESCRIPTION
    The image bundles Microsoft's AzStackHci.EnvironmentChecker. The exact version is pinned in
    tools/modules/modules.lock.json (name, version, SHA256 of the module manifest).

    Default (-Verify): checks that the committed copy matches the lock (version folder present,
    manifest hash equal) and that every script file carries a VALID Authenticode signature issued
    to Microsoft Corporation. Exit code 0 = pinned and signed; non-zero = do not build.

    -Refresh: re-downloads the PINNED version from the PowerShell Gallery (Save-Module
    -RequiredVersion), replaces the committed copy and verifies it.

    -Version <x> -Refresh -UpdateLock: moves the pin to a new version after the verification passes.
    Review the diff of modules.lock.json in the pull request.

.PARAMETER Refresh
    Re-download the pinned (or -Version) module.

.PARAMETER Version
    Version to download with -Refresh. Default: the version in the lock file.

.PARAMETER UpdateLock
    Write the lock file for the downloaded version (only after verification passed).

.PARAMETER SkipSignatureCheck
    Skip the Authenticode scan (only the lock comparison runs). Use on hosts without internet access
    for certificate chain building; the signature scan should still be run once elsewhere.

.EXAMPLE
    .\Update-BeaconModules.ps1
    Verify the committed module against the pin and its signatures.

.EXAMPLE
    .\Update-BeaconModules.ps1 -Version 10.2609.0.1000 -Refresh -UpdateLock
    Move the pin to a newer release.
#>
[CmdletBinding()]
param(
    [switch]$Refresh,
    [string]$Version = '',
    [switch]$UpdateLock,
    [switch]$SkipSignatureCheck,
    [string]$ModuleRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleName = 'AzStackHci.EnvironmentChecker'
$script:ExpectedSigner = 'Microsoft Corporation'

function Get-ModuleLock {
    param([Parameter(Mandatory)] [string]$LockPath)
    if (-not (Test-Path $LockPath)) { throw "Lock file not found: $LockPath" }
    $lock = Get-Content $LockPath -Raw | ConvertFrom-Json
    $entry = @($lock.modules | Where-Object { $_.name -eq $script:ModuleName }) | Select-Object -First 1
    if (-not $entry) { throw "Lock file has no entry for $($script:ModuleName)." }
    return $entry
}

function Test-ModuleLockMatch {
    <# Compares the on-disk module with the lock entry. Returns @{ Ok; Problems }. #>
    param([Parameter(Mandatory)] [string]$Root, [Parameter(Mandatory)] [object]$Entry)
    $problems = New-Object System.Collections.Generic.List[string]
    $dir = Join-Path (Join-Path $Root $script:ModuleName) $Entry.version
    $psd1 = Join-Path $dir "$($script:ModuleName).psd1"
    if (-not (Test-Path $psd1)) {
        $problems.Add("pinned version folder missing: $dir")
    } else {
        $actual = (Get-FileHash $psd1 -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne "$($Entry.manifestSha256)".ToLowerInvariant()) { $problems.Add("manifest SHA256 $actual differs from lock $($Entry.manifestSha256)") }
    }
    $others = @(Get-ChildItem -Path (Join-Path $Root $script:ModuleName) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $Entry.version })
    if ($others.Count -gt 0) { $problems.Add("unpinned extra version folder(s): $(($others | ForEach-Object Name) -join ', ')") }
    return @{ Ok = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

function Test-ModuleSignature {
    <# Every .ps1/.psm1/.psd1 must be Authenticode Valid and signed by Microsoft Corporation. #>
    param([Parameter(Mandatory)] [string]$Path)
    $bad = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -Path $Path -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
    foreach ($f in $files) {
        $sig = Get-AuthenticodeSignature -FilePath $f.FullName
        $signer = ''
        if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        if ($sig.Status -ne 'Valid' -or $signer -notmatch "O=$($script:ExpectedSigner)") {
            $bad.Add("$($f.FullName.Substring($Path.Length)) : $($sig.Status) $signer")
        }
    }
    return @{ Ok = ($bad.Count -eq 0); Checked = $files.Count; Bad = $bad.ToArray() }
}

# Dot-sourcing (Pester) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $ModuleRoot) { $ModuleRoot = Join-Path $repoRoot 'tools\modules' }
$lockPath = Join-Path $ModuleRoot 'modules.lock.json'

if ($Refresh) {
    $entry = $null
    if (Test-Path $lockPath) { $entry = Get-ModuleLock -LockPath $lockPath }
    $want = $Version
    if (-not $want -and $entry) { $want = $entry.version }
    if (-not $want) { throw 'No lock file and no -Version given.' }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("beacon-mod-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Write-Host "Downloading $($script:ModuleName) $want ..." -ForegroundColor Cyan
        Save-Module -Name $script:ModuleName -RequiredVersion $want -Path $stage -Force
        $sig = Test-ModuleSignature -Path (Join-Path $stage $script:ModuleName)
        if (-not $sig.Ok) { throw "Signature check failed for the download:`n$($sig.Bad -join "`n")" }
        $dest = Join-Path $ModuleRoot $script:ModuleName
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $ModuleRoot -Force | Out-Null
        Move-Item (Join-Path $stage $script:ModuleName) $dest
        if ($UpdateLock -or -not (Test-Path $lockPath)) {
            $psd1 = Join-Path (Join-Path $dest $want) "$($script:ModuleName).psd1"
            $newLock = [pscustomobject][ordered]@{
                modules = @([pscustomobject][ordered]@{
                        name = $script:ModuleName; version = $want
                        manifestSha256 = (Get-FileHash $psd1 -Algorithm SHA256).Hash.ToLowerInvariant()
                        source = 'https://www.powershellgallery.com/packages/AzStackHci.EnvironmentChecker'
                        pinnedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    })
            }
            $newLock | ConvertTo-Json -Depth 4 | Set-Content -Path $lockPath -Encoding UTF8
            Write-Host "Lock written: $lockPath" -ForegroundColor Green
        }
    } finally {
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$lockEntry = Get-ModuleLock -LockPath $lockPath
$match = Test-ModuleLockMatch -Root $ModuleRoot -Entry $lockEntry
if (-not $match.Ok) {
    $match.Problems | ForEach-Object { Write-Host "  LOCK  $_" -ForegroundColor Red }
    throw 'Vendored module does not match modules.lock.json.'
}
Write-Host "Pinned: $($script:ModuleName) $($lockEntry.version) (manifest hash matches the lock)." -ForegroundColor Green

if (-not $SkipSignatureCheck) {
    $dir = Join-Path (Join-Path $ModuleRoot $script:ModuleName) $lockEntry.version
    $sig = Test-ModuleSignature -Path $dir
    if (-not $sig.Ok) {
        $sig.Bad | Select-Object -First 20 | ForEach-Object { Write-Host "  SIG   $_" -ForegroundColor Red }
        throw "$($sig.Bad.Count) of $($sig.Checked) script files are not validly signed by $($script:ExpectedSigner)."
    }
    Write-Host "Signatures: $($sig.Checked) script files Valid, signed by $($script:ExpectedSigner)." -ForegroundColor Green
}
Write-Host 'Done.' -ForegroundColor Yellow
