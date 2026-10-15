#Requires -Version 5.1
<#
.SYNOPSIS
    Builds src/config/endpoints.json from the per-region Azure Local endpoint lists that
    Microsoft Learn (firewall-requirements) links to.

.DESCRIPTION
    Reads the snapshots in config/endpoints/learn/ (one markdown file per region plus OEM
    lists), parses them STRICTLY and writes src/config/endpoints.json (schema 2.0).

    Strict means every row must yield a valid host (DNS name, optional wildcard, no spaces,
    no backticks, no scheme) and a numeric port (1-65535). Rows that do not are never
    guessed at: they are listed in the output's "rejected" array and reported, and
    -Strict turns any rejection into an error. Cells that carry several hosts or ports are
    split into one entry each. Placeholder rows (your Arc gateway id, your key vault name)
    are kept and flagged so the validation engine can substitute them from configuration.

    Each entry carries: id, component, host, port, protocol, path, wildcard, probeHost,
    probeHostBasis, placeholder, severity, phase, requiredFor, arcGateway, arcGatewayNote,
    probe, notes, source (URL of the Learn-linked list).

    -Refresh re-downloads the snapshots from config/endpoints/sources.json first. Without
    it the conversion is fully offline and deterministic (apart from generatedUtc).

.PARAMETER EndpointsDir
    Folder that holds sources.json and the learn/ snapshots. Default: <repo>\config\endpoints.

.PARAMETER OutputPath
    Destination JSON. Default: <scriptroot>\config\endpoints.json.

.PARAMETER Refresh
    Download the snapshots again before converting.

.PARAMETER Strict
    Fail when any row is rejected.

.PARAMETER Force
    Overwrite an existing output file.

.EXAMPLE
    .\Convert-EndpointsToJson.ps1 -Force
    Regenerate endpoints.json from the committed snapshots.

.NOTES
    Build-time script. PowerShell 5.1 or 7. PSScriptAnalyzer clean.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$EndpointsDir = '',
    [string]$OutputPath = '',
    [switch]$Refresh,
    [switch]$Strict,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ConverterVersion = '2.0'

#region --- Value validation ---

function Test-EndpointHostName {
    <# True when the string is a plausible DNS name; a leading or embedded '*' is allowed. #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 253) { return $false }
    if ($Name -match '[\s`<>"'',;|\\/:]') { return $false }
    if ($Name -notmatch '^[a-z0-9*]([a-z0-9*-]*[a-z0-9*])?(\.[a-z0-9*]([a-z0-9*-]*[a-z0-9*])?)+$') { return $false }
    $tld = ($Name -split '\.')[-1]
    if ($tld -notmatch '^([a-z]{2,24}|xn--[a-z0-9-]+)$') { return $false }
    return $true
}

function Get-PlaceholderKind {
    param([string]$Name)
    if ($Name -like 'yourarcgatewayendpointid.*') { return 'arcGateway' }
    if ($Name -like 'yourhcikeyvaultname.*') { return 'keyVault' }
    return ''
}

function ConvertTo-CleanCell {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '`', '' -replace '<br\s*/?>', ' ' -replace '\*\*', ''
    $t = $t -replace '\[([^\]]*)\]\([^)]*\)', '$1'     # markdown links -> text
    return $t.Trim()
}

#endregion

#region --- Row parsing ---

function Split-EndpointCell {
    <# One URL cell -> zero or more @{ Host; Path; Port } candidates (Port = 0 when absent). #>
    param([string]$Cell)
    $clean = ConvertTo-CleanCell $Cell
    $parts = @($clean -split '(?:\s*[,;]\s*|\s+and\s+|\s+)' | Where-Object { $_ -ne '' })
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($p in $parts) {
        $x = $p.Trim().TrimEnd('.', ')', '(')
        $x = $x -replace '^[a-z][a-z0-9+.-]*://', ''
        $path = ''
        $slash = $x.IndexOf('/')
        if ($slash -ge 0) {
            $path = $x.Substring($slash)
            $x = $x.Substring(0, $slash)
        }
        $port = 0
        if ($x -match '^(.+):(\d{1,5})$') { $x = $Matches[1]; $port = [int]$Matches[2] }
        if ($path -eq '/*') { $path = '' }
        $result.Add(@{ Host = $x.ToLowerInvariant(); Path = $path; Port = $port })
    }
    return $result
}

function Split-PortCell {
    <# '443' | '80, 443' | '80/443' | '80 and 443' -> int[]; returns $null when not numeric. #>
    param([string]$Cell)
    $clean = ConvertTo-CleanCell $Cell
    if ($clean -eq '') { return $null }
    $tokens = @($clean -split '(?:\s*[,;/]\s*|\s+and\s+|\s+)' | Where-Object { $_ -ne '' })
    $ports = New-Object System.Collections.Generic.List[int]
    foreach ($t in $tokens) {
        if ($t -notmatch '^\d{1,5}$') { return $null }
        $n = [int]$t
        if ($n -lt 1 -or $n -gt 65535) { return $null }
        $ports.Add($n)
    }
    if ($ports.Count -eq 0) { return $null }
    return $ports.ToArray()
}

function ConvertFrom-ArcGatewayCell {
    param([string]$Cell)
    $c = ConvertTo-CleanCell $Cell
    $mode = 'no'
    if ($c -match '^Yes') { $mode = 'yes' }
    elseif ($c -match '^Not required') { $mode = 'notRequired' }
    elseif ($c -match '^No\.?\s+Arc registration') { $mode = 'registration' }
    return @{ Mode = $mode; Note = $c }
}

function Get-PhaseFromRequiredFor {
    param([string]$RequiredFor)
    $r = $RequiredFor.ToLowerInvariant()
    if ($r -match 'deployment' -and $r -match 'post') {
        if ($r -match '^post') { return 'post-deployment' }
        return 'both'
    }
    if ($r -match '^post') { return 'post-deployment' }
    if ($r -match 'deploy') { return 'deployment' }
    return 'both'
}

function Get-EndpointSeverity {
    <#
    critical      = deployment/registration cannot proceed without it (identity, ARM, Arc agent,
                    ARB, deployment bits, billing/diagnostics registration)
    warning       = needed, but a failure does not block the first deployment step
                    (revocation lists, monitoring, updates, OEM, time)
    informational = optional feature or post-deployment only
    #>
    param([string]$Component, [string]$Phase, [string]$HostName, [int]$Port, [string]$Notes)
    $c = $Component.ToLowerInvariant()
    if ($Phase -eq 'post-deployment') { return 'informational' }
    if ($c -match 'defender|wac|windows admin center') { return 'informational' }
    if ($Notes -match '(?i)only if using|required only|optional') { return 'informational' }
    if ($c -match 'crl|benefits|monitoring|update|oem|sbe|digicert') { return 'warning' }
    if ($Port -eq 80) { return 'warning' }
    if ($Port -eq 123) { return 'warning' }
    if ($c -match 'authentication|management|arc agent|arc gateway|arb infra|deployment|diag') { return 'critical' }
    if ($c -match 'aks infra') {
        if ($HostName -match 'mcr\.microsoft\.com|azurecr\.io|dp\.kubernetesconfiguration|sts\.windows\.net') { return 'critical' }
        return 'warning'
    }
    return 'warning'
}

function Get-WildcardProbeHost {
    <#
    Representative concrete host for a wildcard row. Basis 'list' = another row of the SAME
    list matches the wildcard (strongest). 'curated' = widely documented concrete name,
    NOT taken from the Learn list (a failure is only ever a warning).
    #>
    param([string]$Wildcard, [string[]]$ConcreteHosts, [string]$Region)
    $regex = '^' + (([regex]::Escape($Wildcard)) -replace '\\\*', '[a-z0-9-]+(\.[a-z0-9-]+)*') + '$'
    $match = @($ConcreteHosts | Where-Object { $_ -ne $Wildcard -and $_ -match $regex }) | Select-Object -First 1
    if ($match) { return @{ Host = $match; Basis = 'list' } }
    $curated = @{
        # Documented in the Defender for Endpoint network requirements; not part of the Learn list.
        '*.endpoint.security.microsoft.com' = 'unitedstates.endpoint.security.microsoft.com'
    }
    if ($curated.ContainsKey($Wildcard)) {
        return @{ Host = ($curated[$Wildcard] -replace '\{region\}', $Region); Basis = 'curated' }
    }
    return @{ Host = ''; Basis = '' }
}

function ConvertFrom-EndpointMarkdown {
    <#
    Strict parser for the Learn-linked endpoint tables.
    Returns @{ Entries = [hashtable[]]; Rejected = [hashtable[]] }.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]]$Lines,
        [Parameter(Mandatory)] [string]$SourceUrl,
        [string]$Region = '',
        [string]$DefaultComponent = 'Azure Local'
    )

    $entries = New-Object System.Collections.Generic.List[hashtable]
    $rejected = New-Object System.Collections.Generic.List[hashtable]
    $map = $null

    $lineNo = 0
    foreach ($line in $Lines) {
        $lineNo++
        $t = $line.Trim()
        if (-not $t.StartsWith('|')) { $map = $null; continue }
        $cells = @($t.Trim('|').Split('|') | ForEach-Object { $_.Trim() })

        if ($null -eq $map) {
            $hdr = @($cells | ForEach-Object { $_.ToLowerInvariant() })
            $urlIdx = [array]::IndexOf($hdr, 'endpoint url')
            $portIdx = [array]::IndexOf($hdr, 'port')
            if ($urlIdx -ge 0 -and $portIdx -ge 0) {
                $map = @{
                    Url = $urlIdx; Port = $portIdx
                    Component = -1; Notes = -1; Gateway = -1; Required = -1; Id = -1
                }
                for ($i = 0; $i -lt $hdr.Count; $i++) {
                    switch -Regex ($hdr[$i]) {
                        '^id$|^#$'                                  { $map.Id = $i }
                        'component|endpoint description'            { $map.Component = $i }
                        '^notes$'                                   { $map.Notes = $i }
                        'arc gateway'                               { $map.Gateway = $i }
                        'required for'                              { $map.Required = $i }
                    }
                }
            }
            continue
        }
        if ($t -match '^\|[\s:|-]+\|?$') { continue }   # separator row

        $get = {
            param([int]$i)
            if ($i -ge 0 -and $i -lt $cells.Count) { return (ConvertTo-CleanCell $cells[$i]) }
            return ''
        }
        $rowId = & $get $map.Id
        $component = & $get $map.Component
        if ($component -eq '') { $component = $DefaultComponent }
        $urlCell = & $get $map.Url
        $notes = & $get $map.Notes
        $requiredFor = & $get $map.Required
        $gw = ConvertFrom-ArcGatewayCell (& $get $map.Gateway)

        $reject = {
            param([string]$why)
            $rejected.Add(@{ line = $lineNo; id = $rowId; component = $component; value = $urlCell; reason = $why })
        }

        $ports = Split-PortCell (& $get $map.Port)
        $hostCandidates = @(Split-EndpointCell $urlCell)
        if ($hostCandidates.Count -eq 0) { & $reject 'empty endpoint cell'; continue }

        foreach ($cand in $hostCandidates) {
            $hostName = $cand.Host
            $placeholder = Get-PlaceholderKind $hostName
            if (-not (Test-EndpointHostName $hostName)) {
                & $reject "not a host name: '$hostName'"
                continue
            }
            $candPorts = $ports
            if ($cand.Port -gt 0) { $candPorts = @($cand.Port) }
            if ($null -eq $candPorts) { & $reject "port is not numeric for '$hostName'"; continue }

            foreach ($port in $candPorts) {
                $protocol = 'HTTPS'
                if ($port -eq 123) { $protocol = 'UDP' } elseif ($port -eq 80) { $protocol = 'HTTP' }
                $phase = Get-PhaseFromRequiredFor $requiredFor
                $probe = $true
                $skipReason = ''
                if ($port -eq 8084) {
                    # Per Beacon policy: 8084 is a node/cluster-internal service port, not an outbound
                    # firewall rule. Listed by Learn for AKS Arc post-deployment; never probed.
                    $probe = $false
                    $skipReason = 'Port 8084 is a cluster-internal service port, not an outbound probe target'
                }
                $severity = Get-EndpointSeverity -Component $component -Phase $phase -HostName $hostName -Port $port -Notes $notes
                if (-not $probe) { $severity = 'informational' }
                $entries.Add(@{
                    id             = $rowId
                    component      = $component
                    host           = $hostName
                    port           = $port
                    protocol       = $protocol
                    path           = $cand.Path
                    wildcard       = $hostName.Contains('*')
                    probeHost      = ''
                    probeHostBasis = ''
                    placeholder    = $placeholder
                    severity       = $severity
                    phase          = $phase
                    requiredFor    = $requiredFor
                    arcGateway     = $gw.Mode
                    arcGatewayNote = $gw.Note
                    probe          = $probe
                    skipReason     = $skipReason
                    notes          = $notes
                    source         = $SourceUrl
                })
            }
        }
    }

    # Representative probe hosts for wildcard rows (needs the full concrete host list)
    $concrete = @($entries | Where-Object { -not $_.wildcard -and $_.placeholder -eq '' } | ForEach-Object { $_.host })
    foreach ($e in $entries) {
        if ($e.wildcard) {
            $pr = Get-WildcardProbeHost -Wildcard $e.host -ConcreteHosts $concrete -Region $Region
            $e.probeHost = $pr.Host
            $e.probeHostBasis = $pr.Basis
        }
    }
    return @{ Entries = $entries.ToArray(); Rejected = $rejected.ToArray() }
}

function Merge-EndpointEntries {
    <# Collapse duplicates on host+port+path; keep the more severe, join differing notes. #>
    param([hashtable[]]$Entries)
    $rank = @{ critical = 0; warning = 1; informational = 2 }
    $seen = [ordered]@{}
    foreach ($e in $Entries) {
        $key = '{0}:{1}{2}' -f $e.host, $e.port, $e.path
        if (-not $seen.Contains($key)) { $seen[$key] = $e; continue }
        if ($rank[$e.severity] -lt $rank[$seen[$key].severity]) { $seen[$key] = $e }
    }
    return @($seen.Values | Sort-Object @{ Expression = { $rank[$_.severity] } }, component, host, port)
}

#endregion

#region --- Main ---

function Invoke-EndpointConversion {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$EndpointsDir,
        [string]$OutputPath,
        [switch]$Refresh,
        [switch]$Strict,
        [switch]$Force
    )
    $sources = Get-Content (Join-Path $EndpointsDir 'sources.json') -Raw | ConvertFrom-Json
    $learnDir = Join-Path $EndpointsDir 'learn'
    if (-not (Test-Path $learnDir)) { New-Item -ItemType Directory -Path $learnDir -Force | Out-Null }

    $all = @(
        foreach ($r in $sources.regions.PSObject.Properties) { @{ Kind = 'region'; Key = $r.Name; Def = $r.Value } }
        foreach ($o in $sources.oem.PSObject.Properties) { @{ Kind = 'oem'; Key = $o.Name; Def = $o.Value } }
    )

    $regions = [ordered]@{}
    $oems = [ordered]@{}
    $totalRejected = 0
    foreach ($item in $all) {
        $file = Join-Path $learnDir $item.Def.file
        if ($Refresh) {
            Write-Verbose "Downloading $($item.Def.url)"
            Invoke-WebRequest -Uri $item.Def.url -OutFile $file -UseBasicParsing -TimeoutSec 60
        }
        if (-not (Test-Path $file)) { throw "Snapshot missing: $file (run with -Refresh)" }
        $lines = Get-Content $file
        $lastUpdated = ''
        $lu = $lines | Where-Object { $_ -match '(?i)last updated on' } | Select-Object -First 1
        if ($lu -and $lu -match '(?i)last updated on\s+([^*]+?)\*') { $lastUpdated = $Matches[1].Trim() }

        $defaultComp = 'Azure Local'
        if ($item.Kind -eq 'oem') { $defaultComp = "OEM ($($item.Def.displayName))" }
        $regionKey = ''
        if ($item.Kind -eq 'region') { $regionKey = $item.Key }
        $parsed = ConvertFrom-EndpointMarkdown -Lines $lines -SourceUrl $item.Def.page -Region $regionKey -DefaultComponent $defaultComp
        if ($item.Kind -eq 'oem') {
            foreach ($e in $parsed.Entries) { $e.component = $defaultComp; $e.severity = 'warning'; $e.phase = 'both' }
        }
        $merged = Merge-EndpointEntries -Entries $parsed.Entries
        $totalRejected += $parsed.Rejected.Count
        foreach ($rj in $parsed.Rejected) {
            Write-Warning ("[{0}] line {1}: rejected '{2}' -- {3}" -f $item.Key, $rj.line, $rj.value, $rj.reason)
        }
        $block = [ordered]@{
            displayName = $item.Def.displayName
            sourceUrl   = $item.Def.page
            lastUpdated = $lastUpdated
            cloud       = 'AzureCloud'
            count       = $merged.Count
            endpoints   = @($merged | ForEach-Object {
                [pscustomobject][ordered]@{
                    id = $_.id; component = $_.component; host = $_.host; port = $_.port; protocol = $_.protocol
                    path = $_.path; wildcard = $_.wildcard; probeHost = $_.probeHost; probeHostBasis = $_.probeHostBasis
                    placeholder = $_.placeholder; severity = $_.severity; phase = $_.phase; requiredFor = $_.requiredFor
                    arcGateway = $_.arcGateway; arcGatewayNote = $_.arcGatewayNote; probe = $_.probe
                    skipReason = $_.skipReason; notes = $_.notes; source = $_.source
                }
            })
            rejected    = @($parsed.Rejected | ForEach-Object { [pscustomobject]$_ })
        }
        if ($item.Def.PSObject.Properties.Name -contains 'cloud') { $block.cloud = $item.Def.cloud }
        if ($item.Kind -eq 'region') { $regions[$item.Key] = $block } else { $oems[$item.Key] = $block }
        Write-Information ("  {0,-15} {1,3} endpoints, {2} rejected" -f $item.Key, $merged.Count, $parsed.Rejected.Count) -InformationAction Continue
    }

    if ($Strict -and $totalRejected -gt 0) { throw "$totalRejected row(s) rejected and -Strict is set." }

    $doc = [pscustomobject][ordered]@{
        schemaVersion = '2.0'
        releaseTrain  = $sources.releaseTrain
        learnUrl      = $sources.learnUrl
        generatedUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        converter     = "Convert-EndpointsToJson.ps1 $($script:ConverterVersion)"
        regions       = [pscustomobject]$regions
        oem           = [pscustomobject]$oems
    }
    if ((Test-Path $OutputPath) -and -not $Force) {
        Write-Warning "Output exists: $OutputPath. Use -Force to overwrite."
        return $doc
    }
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write endpoints.json')) {
        $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Information "Written: $OutputPath" -InformationAction Continue
    }
    return $doc
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

$scriptDir = $PSScriptRoot
if (-not $EndpointsDir) { $EndpointsDir = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\config\endpoints')) }
if (-not $OutputPath) { $OutputPath = Join-Path $scriptDir 'config\endpoints.json' }
$null = Invoke-EndpointConversion -EndpointsDir $EndpointsDir -OutputPath $OutputPath -Refresh:$Refresh -Strict:$Strict -Force:$Force

#endregion
