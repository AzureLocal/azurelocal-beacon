#Requires -Version 7.0
<#
.SYNOPSIS
    Updates the offline module cache in tools/modules/ from PowerShell Gallery.

.DESCRIPTION
    Downloads the latest versions of modules required by the AzL Beacon WinPE image.
    Run this manually before a build when you want to refresh module versions.
    The tools/modules/ folder is committed to the repo so builds are air-gap safe.

.EXAMPLE
    .\Update-BeaconModules.ps1
    Updates all modules to latest versions.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ModulePath = Join-Path $RepoRoot 'tools\modules'
$Modules    = @('AzStackHci.EnvironmentChecker')

New-Item -ItemType Directory -Path $ModulePath -Force | Out-Null

foreach ($mod in $Modules) {
    Write-Host "Updating $mod..." -ForegroundColor Cyan
    $dest = Join-Path $ModulePath $mod
    if (Test-Path $dest) {
        Remove-Item $dest -Recurse -Force
    }
    Save-Module -Name $mod -Path $ModulePath -Force
    $version = (Get-ChildItem $dest -Directory | Select-Object -First 1).Name
    Write-Host "  -> $mod $version saved." -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Commit tools/modules/ to include updated modules in the next build." -ForegroundColor Yellow
