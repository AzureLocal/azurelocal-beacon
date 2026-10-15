#Requires -Version 7.0
<#
.SYNOPSIS
    Writes drivers/driver-manifest.json: every bundled driver file with its SHA256, plus the INF
    metadata (provider, class, DriverVer) and where the set came from.

.DESCRIPTION
    Run it after adding or replacing a driver set under drivers/<set>/. Tests compare the manifest
    with the files on disk, so a silently changed driver fails CI.

    A set is one folder directly under drivers/. Describe its origin in -SetSource (set name -> text).
    Other OEMs: put their exported INF packages under drivers/<oem-set>/ (or keep them outside the repo
    and pass -DriverPath to Build-WinPEImage.ps1) and add an entry to -SetSource.

.PARAMETER DriversRoot
    Default: <repo>\drivers.

.PARAMETER SetSource
    Hashtable: set folder name -> source description.

.EXAMPLE
    .\New-DriverManifest.ps1
#>
[CmdletBinding()]
param(
    [string]$DriversRoot = '',
    [hashtable]$SetSource = @{
        'dell-ax' = 'Dell Solution Builder Extension SBE_Dell_AX-16G-45n0c_5.0.2603.1641 (Bundle_SBE_Dell_AX-16G-45n0c_5.0.2603.1641.zip, DriversGE\Network)'
    }
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-InfMetadata {
    <# DriverVer, Provider and Class from an INF (best effort; values with %tokens% are returned as written). #>
    param([Parameter(Mandatory)] [string]$Path)
    $text = Get-Content -Path $Path -ErrorAction Stop
    $get = {
        param($key)
        $line = $text | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
        if ($line -and $line -match '=\s*(.+?)\s*(;.*)?$') { return $Matches[1].Trim() }
        return ''
    }
    return [pscustomobject][ordered]@{
        provider  = (& $get 'Provider')
        class     = (& $get 'Class')
        driverVer = (& $get 'DriverVer')
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $DriversRoot) { $DriversRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'drivers' }
$root = (Resolve-Path $DriversRoot).Path.TrimEnd('\')

$sets = foreach ($d in Get-ChildItem -Path $root -Directory | Sort-Object Name) {
    $infs = Get-ChildItem -Path $d.FullName -Recurse -Filter '*.inf' | Sort-Object FullName
    [pscustomobject][ordered]@{
        name   = $d.Name
        source = $(if ($SetSource.ContainsKey($d.Name)) { $SetSource[$d.Name] } else { 'unspecified' })
        infs   = @($infs | ForEach-Object {
                $m = Get-InfMetadata -Path $_.FullName
                [pscustomobject][ordered]@{
                    path = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
                    provider = $m.provider; class = $m.class; driverVer = $m.driverVer
                }
            })
    }
}

$files = Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Name -ne 'driver-manifest.json' } | Sort-Object FullName | ForEach-Object {
    [pscustomobject][ordered]@{
        path   = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        size   = $_.Length
        sha256 = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

[pscustomobject][ordered]@{
    schemaVersion = '1.0'
    generatedUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    sets          = @($sets)
    files         = @($files)
} | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $root 'driver-manifest.json') -Encoding UTF8

Write-Host "driver-manifest.json written: $(@($files).Count) files in $(@($sets).Count) set(s)." -ForegroundColor Green
