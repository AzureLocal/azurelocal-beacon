#Requires -Version 5.1
<#
.SYNOPSIS
    Parses the three Azure Local endpoint markdown files into a structured JSON file for WinPE validation.

.DESCRIPTION
    Reads azurelocal-endpoints.md, arc-endpoints.md, and dell-endpoints.md from
    config/endpoints/ and produces src/config/endpoints.json.

    Each entry in the JSON includes:
      name, host, port, protocol, category, severity (critical|warning|informational),
      sourceFile, notes, wildcard (bool), probeHost (concrete host for wildcard entries).

    Severity assignment rules:
      - Authentication, ARM, Arc agent hybrid-identity = critical
      - Deployment-blocking container registries = critical
      - Monitoring, updates, CRLs = warning
      - Informational/post-deployment-only = informational

    Wildcard hosts: a representative probeHost is set where a concrete example is
    documented in the markdown; otherwise wildcard=true and probeHost is empty.

    Output is written to the path provided by -OutputPath (default: script-relative
    config\endpoints.json). File is stable-sorted by category then host so diffs are
    clean across regenerations.

.PARAMETER EndpointsDir
    Path to the directory containing the three endpoint markdown files.
    Default: auto-detected relative to this script (../config/endpoints).

.PARAMETER OutputPath
    Destination JSON file path.
    Default: <scriptroot>\config\endpoints.json

.PARAMETER Force
    Overwrite the output file without prompting if it already exists.

.EXAMPLE
    .\Convert-EndpointsToJson.ps1
    Parses all three endpoint files and writes config\endpoints.json.

.EXAMPLE
    .\Convert-EndpointsToJson.ps1 -EndpointsDir C:\repo\config\azure\endpoints -OutputPath C:\out\endpoints.json
    Explicit paths.

.NOTES
    Version:      1.0
    Last Updated: 2026-06-10
    Prerequisites: PowerShell 5.1 or later. No external modules required.
    PSScriptAnalyzer: passes at Warning/Error severity.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$EndpointsDir = '',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Path resolution ---

function Resolve-EndpointsDir {
    param([string]$Provided)
    if ($Provided -ne '' -and (Test-Path $Provided -PathType Container)) {
        return (Resolve-Path $Provided).Path
    }
    # Navigate from src/ up one level to repo root, then into config/endpoints
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent }
    $candidate = Join-Path $scriptDir '..\config\endpoints'
    $candidate = [System.IO.Path]::GetFullPath($candidate)
    if (Test-Path $candidate -PathType Container) { return $candidate }
    throw "Cannot locate endpoint markdown directory. Pass -EndpointsDir explicitly."
}

function Resolve-OutputPath {
    param([string]$Provided)
    if ($Provided -ne '') { return $Provided }
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent }
    return Join-Path $scriptDir 'config\endpoints.json'
}

#endregion

#region --- Severity + category maps ---

function Get-Severity {
    param([string]$Component, [string]$Notes)
    $combined = ($Component + ' ' + $Notes).ToLower()
    # Authentication and ARM are always critical
    if ($combined -match 'auth|entra|arm token|token fetch|management\.azure\.com|login\.|key vault') {
        return 'critical'
    }
    if ($combined -match 'arc agent|arc-enabled|arc server|arc resource bridge|arb') {
        return 'critical'
    }
    if ($combined -match 'deployment' -and $combined -notmatch 'post.deployment.only') {
        return 'critical'
    }
    if ($combined -match 'monitor|telemetry|metric|diagn|billing|licens') {
        return 'warning'
    }
    if ($combined -match 'update|patch|crl|revocation|ocsp|package|gallery|deliver') {
        return 'warning'
    }
    if ($combined -match 'defender|wac|windows admin center|post.dep') {
        return 'informational'
    }
    # Default
    return 'warning'
}

#endregion

#region --- Wildcard probe-host resolution ---

# For wildcard FQDNs, map to a documented concrete representative host.
# Only entries confirmed in the source markdown files are listed here.
$script:WildcardProbeHosts = @{
    '*.servicebus.windows.net'                         = 'azgn123456789.servicebus.windows.net'
    'azgn*.servicebus.windows.net'                     = 'azgn123456789.servicebus.windows.net'
    '*.his.arc.azure.com'                              = 'eus.his.arc.azure.com'
    '*.guestconfiguration.azure.com'                   = 'eastus-gas.guestconfiguration.azure.com'
    '*.guestnotificationservice.azure.com'             = 'guestnotificationservice.azure.com'
    '*.waconazure.com'                                 = 'portal.waconazure.com'
    '*.blob.core.windows.net'                          = 'sttotepocwit01.blob.core.windows.net'
    '*.data.mcr.microsoft.com'                         = 'eastus.data.mcr.microsoft.com'
    '*.mcr.microsoft.com'                              = 'mcr.microsoft.com'
    '*.dl.delivery.mp.microsoft.com'                   = 'tlu.dl.delivery.mp.microsoft.com'
    '*.do.dsp.mp.microsoft.com'                        = 'dl.delivery.mp.microsoft.com'
    '*.prod.do.dsp.mp.microsoft.com'                   = 'dl.delivery.mp.microsoft.com'
    '*.prod.hot.ingest.monitor.core.windows.net'       = 'dc.prod.hot.ingest.monitor.core.windows.net'
    '*.prod.warm.ingest.monitor.core.windows.net'      = 'qos.prod.warm.ingest.monitor.core.windows.net'
    '*.dp.kubernetesconfiguration.azure.com'           = 'eastus.dp.kubernetesconfiguration.azure.com'
    '*.web.core.windows.net'                           = 'arcplatformcliextprod.z13.web.core.windows.net'
    '*.arc.azure.net'                                  = 'eastus.arc.azure.net'
    '*.blob.storage.azure.net'                         = 'msdownload.blob.storage.azure.net'
    '*.endpoint.security.microsoft.com'                = 'unitedstates.endpoint.security.microsoft.com'
    '*.login.microsoft.com'                            = 'eastus.login.microsoft.com'
    '*.pypi.org'                                       = 'pypi.org'
    '*.pythonhosted.org'                               = 'pythonhosted.org'
    '*.ods.opinsights.azure.com'                       = 'law-tote-poc-azl-eus-01.ods.opinsights.azure.com'
    '*.oms.opinsights.azure.com'                       = 'law-tote-poc-azl-eus-01.oms.opinsights.azure.com'
    '*.monitoring.azure.com'                           = 'eastus.monitoring.azure.com'
    '*.ingest.monitor.azure.com'                       = 'eastus.ingest.monitor.azure.com'
    '*.metrics.ingest.monitor.azure.com'               = 'eastus.metrics.ingest.monitor.azure.com'
    '*.prod.microsoftmetrics.com'                      = 'global.prod.microsoftmetrics.com'
    'pypi.org'                                         = 'pypi.org'
    'pythonhosted.org'                                 = 'pythonhosted.org'
}

function Get-WildcardInfo {
    param([string]$Hostname)
    $isWildcard = $Hostname.StartsWith('*') -or $Hostname.Contains('*')
    $probeHost = ''
    if ($isWildcard -and $script:WildcardProbeHosts.ContainsKey($Hostname)) {
        $probeHost = $script:WildcardProbeHosts[$Hostname]
    }
    return @{ IsWildcard = $isWildcard; ProbeHost = $probeHost }
}

#endregion

#region --- Template-host normalisation ---

# Some rows in the markdown use placeholder text instead of real hostnames.
# These are skipped or substituted.
$script:SkipHosts = @(
    'yourarcgatewayendpointid.gw.arc.azure.com'  # unique per deployment; excluded from generic list
    'yourhcikeyvaultname.vault.azure.net'          # substituted by validation-config.json keyVaultFqdn
    '<log-analytics-workspace-id>.ods.opinsights.azure.com'
    '<data-collection-endpoint>.eastus.ingest.monitor.azure.com'
)

#endregion

#region --- Markdown table parsers ---

function ConvertFrom-AzureLocalEndpointsTable {
    <#
    Parses azurelocal-endpoints.md pipe table format:
    | Id | Azure Local Component | Endpoint URL | Port | Notes | Arc gateway support | Required for |
    #>
    param([string[]]$Lines, [string]$SourceFile)

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $inTable = $false

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('|') -and $trimmed -match '\|\s*\d+\s*\|') {
            $inTable = $true
        }
        if (-not $inTable) { continue }
        if (-not $trimmed.StartsWith('|')) { $inTable = $false; continue }
        # Skip header and separator rows
        if ($trimmed -match '^\|\s*Id\s*\|' -or $trimmed -match '^\|\s*-') { continue }

        $cols = $trimmed.Split('|') | ForEach-Object { $_.Trim() }
        # cols[0] = empty, cols[1]=Id, cols[2]=Component, cols[3]=URL, cols[4]=Port, cols[5]=Notes
        if ($cols.Count -lt 5) { continue }

        $rawHost = $cols[3].Trim()
        # Strip leading https:// if present in the URL column
        $rawHost = $rawHost -replace '^https?://', ''
        # Strip trailing path for hosts like crl.microsoft.com/pkiinfra
        # Keep the path for probing purposes — extract just the hostname
        $hostOnly = $rawHost -replace '/.*$', ''
        if ([string]::IsNullOrWhiteSpace($hostOnly)) { continue }
        if ($script:SkipHosts -contains $hostOnly) { continue }

        $portStr = $cols[4].Trim()
        $port = 443
        if ($portStr -match '^\d+$') { $port = [int]$portStr }

        $component = if ($cols[2]) { $cols[2].Trim() } else { 'Azure Local' }
        $notes = if ($cols[5]) { $cols[5].Trim() } else { '' }
        $requiredFor = if ($cols.Count -gt 6) { $cols[6].Trim() } else { '' }

        # Protocol: NTP rows use UDP 123; everything else is TCP/HTTPS
        $protocol = if ($port -eq 123) { 'UDP' } elseif ($port -eq 80) { 'HTTP' } else { 'HTTPS' }

        $severity = Get-Severity -Component $component -Notes $notes
        $wildcardInfo = Get-WildcardInfo -Hostname $hostOnly

        $entry = @{
            name        = "$component : $hostOnly"
            host        = $hostOnly
            port        = $port
            protocol    = $protocol
            category    = $component
            severity    = $severity
            sourceFile  = $SourceFile
            notes       = $notes
            requiredFor = $requiredFor
            wildcard    = $wildcardInfo.IsWildcard
            probeHost   = $wildcardInfo.ProbeHost
        }
        $entries.Add($entry)
    }
    return $entries
}

function ConvertFrom-ArcEndpointsTable {
    <#
    Parses arc-endpoints.md — multiple sections, each with a pipe table.
    Header format varies: | # | Endpoint | Port | Protocol | Purpose | When |
                      or: | # | Endpoint | Port | Purpose |
    #>
    param([string[]]$Lines, [string]$SourceFile)

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $currentSection = 'Arc'

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        # Track section headings to assign category
        if ($trimmed -match '^##\s+(.+)') {
            $currentSection = $Matches[1].Trim()
        }

        if (-not $trimmed.StartsWith('|')) { continue }
        # Skip header and separator rows
        if ($trimmed -match '^\|\s*#\s*\|' -or $trimmed -match '^\|\s*-') { continue }
        # Must start with a number row
        if ($trimmed -notmatch '^\|\s*\d+\s*\|') { continue }

        $cols = $trimmed.Split('|') | ForEach-Object { $_.Trim() }
        if ($cols.Count -lt 4) { continue }

        # Format A: | # | Endpoint | Port | Protocol | Purpose | When |
        # Format B: | # | Endpoint | Port | Purpose |
        $rawHost = $cols[2].Trim()
        $rawHost = $rawHost.Trim('`')

        $hostOnly = $rawHost -replace '^https?://', '' -replace '/.*$', ''
        if ([string]::IsNullOrWhiteSpace($hostOnly)) { continue }
        if ($script:SkipHosts -contains $hostOnly) { continue }

        $portStr = $cols[3].Trim()
        $port = 443
        if ($portStr -match '^\d+$') { $port = [int]$portStr }

        # Determine if format has explicit Protocol column
        $protocol = 'HTTPS'
        $notes = ''
        if ($cols.Count -ge 6 -and $cols[4] -match '^(HTTPS|HTTP|WSS|UDP|TCP)') {
            $protocol = $cols[4].Trim().ToUpper()
            $notes = if ($cols.Count -gt 5) { $cols[5].Trim() } else { '' }
        } elseif ($cols.Count -ge 5) {
            $notes = $cols[4].Trim()
        }

        if ($port -eq 123) { $protocol = 'UDP' }
        if ($port -eq 80 -and $protocol -eq 'HTTPS') { $protocol = 'HTTP' }

        $severity = Get-Severity -Component $currentSection -Notes $notes
        $wildcardInfo = Get-WildcardInfo -Hostname $hostOnly

        $entry = @{
            name        = "$currentSection : $hostOnly"
            host        = $hostOnly
            port        = $port
            protocol    = $protocol
            category    = $currentSection
            severity    = $severity
            sourceFile  = $SourceFile
            notes       = $notes
            requiredFor = ''
            wildcard    = $wildcardInfo.IsWildcard
            probeHost   = $wildcardInfo.ProbeHost
        }
        $entries.Add($entry)
    }
    return $entries
}

function ConvertFrom-DellEndpointsTable {
    <#
    Parses dell-endpoints.md pipe table.
    Header: | Id | Endpoint Description | Endpoint URL | Port | Notes | Arc gateway support | Required for |
    #>
    param([string[]]$Lines, [string]$SourceFile)

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $inTable = $false

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\|\s*\d+\s*\|') { $inTable = $true }
        if (-not $inTable) { continue }
        if (-not $trimmed.StartsWith('|')) { $inTable = $false; continue }
        if ($trimmed -match '^\|\s*Id\s*\|' -or $trimmed -match '^\|\s*-') { continue }

        $cols = $trimmed.Split('|') | ForEach-Object { $_.Trim() }
        if ($cols.Count -lt 4) { continue }

        $component = if ($cols[2]) { $cols[2].Trim() } else { 'Dell SBE' }
        $rawHost = $cols[3].Trim()
        $rawHost = $rawHost -replace '^https?://', ''
        $hostOnly = $rawHost -replace '/.*$', ''
        if ([string]::IsNullOrWhiteSpace($hostOnly)) { continue }

        $portStr = $cols[4].Trim()
        $port = 443
        if ($portStr -match '^\d+$') { $port = [int]$portStr }

        $notes = if ($cols.Count -gt 5) { $cols[5].Trim() } else { '' }
        $protocol = if ($port -eq 80) { 'HTTP' } else { 'HTTPS' }

        $severity = Get-Severity -Component $component -Notes $notes
        # SBE/Dell endpoints are always warning — not deployment blockers
        if ($severity -eq 'critical') { $severity = 'warning' }

        $wildcardInfo = Get-WildcardInfo -Hostname $hostOnly

        $entry = @{
            name        = "Dell SBE : $hostOnly"
            host        = $hostOnly
            port        = $port
            protocol    = $protocol
            category    = 'Dell SBE'
            severity    = $severity
            sourceFile  = $SourceFile
            notes       = $notes
            requiredFor = 'Deployment & Post deployment'
            wildcard    = $wildcardInfo.IsWildcard
            probeHost   = $wildcardInfo.ProbeHost
        }
        $entries.Add($entry)
    }
    return $entries
}

#endregion

#region --- Deduplication ---

function Merge-EndpointList {
    [CmdletBinding()]
    param([System.Collections.Generic.List[hashtable]]$Entries)

    # Deduplicate on host+port combination. When duplicates exist, prefer the
    # entry with higher severity (critical > warning > informational).
    $severityRank = @{ critical = 0; warning = 1; informational = 2 }
    $seen = @{}
    $result = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in $Entries) {
        $key = "$($entry.host.ToLower()):$($entry.port)"
        if ($seen.ContainsKey($key)) {
            # Keep higher-severity entry
            $existing = $seen[$key]
            if ($severityRank[$entry.severity] -lt $severityRank[$existing.severity]) {
                $seen[$key] = $entry
            }
        } else {
            $seen[$key] = $entry
        }
    }

    # Collect and sort: severity asc (critical first), then category, then host
    $sorted = $seen.Values | Sort-Object @{Expression = { $severityRank[$_.severity] }}, category, host
    foreach ($item in $sorted) {
        $result.Add($item)
    }
    return $result
}

#endregion

#region --- Main ---

$resolvedEndpointsDir = Resolve-EndpointsDir -Provided $EndpointsDir
$resolvedOutputPath = Resolve-OutputPath -Provided $OutputPath

Write-Verbose "Endpoints directory : $resolvedEndpointsDir"
Write-Verbose "Output path         : $resolvedOutputPath"

$azlFile   = Join-Path $resolvedEndpointsDir 'azurelocal-endpoints.md'
$arcFile   = Join-Path $resolvedEndpointsDir 'arc-endpoints.md'
$dellFile  = Join-Path $resolvedEndpointsDir 'dell-endpoints.md'

foreach ($f in @($azlFile, $arcFile, $dellFile)) {
    if (-not (Test-Path $f)) {
        throw "Required endpoint file not found: $f"
    }
}

$allEntries = [System.Collections.Generic.List[hashtable]]::new()

Write-Output "Parsing azurelocal-endpoints.md ..."
$azlLines = Get-Content $azlFile
$azlEntries = ConvertFrom-AzureLocalEndpointsTable -Lines $azlLines -SourceFile 'azurelocal-endpoints.md'
foreach ($e in $azlEntries) { $allEntries.Add($e) }
Write-Output "  -> $($azlEntries.Count) entries parsed"

Write-Output "Parsing arc-endpoints.md ..."
$arcLines = Get-Content $arcFile
$arcEntries = ConvertFrom-ArcEndpointsTable -Lines $arcLines -SourceFile 'arc-endpoints.md'
foreach ($e in $arcEntries) { $allEntries.Add($e) }
Write-Output "  -> $($arcEntries.Count) entries parsed"

Write-Output "Parsing dell-endpoints.md ..."
$dellLines = Get-Content $dellFile
$dellEntries = ConvertFrom-DellEndpointsTable -Lines $dellLines -SourceFile 'dell-endpoints.md'
foreach ($e in $dellEntries) { $allEntries.Add($e) }
Write-Output "  -> $($dellEntries.Count) entries parsed"

$deduped = Merge-EndpointList -Entries $allEntries
Write-Output "Deduplication: $($allEntries.Count) raw -> $($deduped.Count) unique host:port entries"

# Build ordered output objects for stable JSON serialisation
$outputList = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($entry in $deduped) {
    $obj = [PSCustomObject][ordered]@{
        name        = $entry.name
        host        = $entry.host
        port        = $entry.port
        protocol    = $entry.protocol
        category    = $entry.category
        severity    = $entry.severity
        sourceFile  = $entry.sourceFile
        notes       = $entry.notes
        requiredFor = $entry.requiredFor
        wildcard    = $entry.wildcard
        probeHost   = $entry.probeHost
    }
    $outputList.Add($obj)
}

# Ensure output directory exists
$outputDir = Split-Path $resolvedOutputPath -Parent
if (-not (Test-Path $outputDir)) {
    if ($PSCmdlet.ShouldProcess($outputDir, 'Create directory')) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
}

if ((Test-Path $resolvedOutputPath) -and -not $Force) {
    Write-Warning "Output file already exists: $resolvedOutputPath. Use -Force to overwrite."
} else {
    if ($PSCmdlet.ShouldProcess($resolvedOutputPath, 'Write endpoints JSON')) {
        $wrapper = [PSCustomObject][ordered]@{
            generatedUtc    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            sourceDirectory = $resolvedEndpointsDir
            totalEndpoints  = $outputList.Count
            endpoints       = $outputList
        }
        $wrapper | ConvertTo-Json -Depth 5 | Set-Content -Path $resolvedOutputPath -Encoding UTF8
        Write-Output "Written: $resolvedOutputPath ($($outputList.Count) endpoints)"
    }
}

#endregion
