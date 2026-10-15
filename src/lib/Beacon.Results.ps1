# AzL Beacon - results document, redaction, HTML report and export.
# Contract: docs/reference/results.schema.json. PowerShell 5.1 and 7 compatible.

function New-BeaconRunId {
    return ([guid]::NewGuid().ToString())
}

function Get-BeaconNodeIdentity {
    <# Hostname plus hardware identity from SMBIOS. Every field is best-effort; unknown = ''. #>
    $id = [ordered]@{ hostname = "$env:COMPUTERNAME"; serialNumber = ''; smbiosUuid = ''; manufacturer = ''; model = '' }
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $id.serialNumber = "$($bios.SerialNumber)".Trim()
    } catch { Write-Verbose "BIOS query failed: $($_.Exception.Message)" }
    try {
        $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        $id.smbiosUuid = "$($csp.UUID)".Trim()
        $id.model = "$($csp.Name)".Trim()
        $id.manufacturer = "$($csp.Vendor)".Trim()
    } catch { Write-Verbose "ComputerSystemProduct query failed: $($_.Exception.Message)" }
    return [pscustomobject]$id
}

function Get-ResultSummary {
    param([object[]]$Results = @())
    $r = @($Results)
    $fail = @($r | Where-Object { $_.Status -eq 'Fail' }).Count
    $verdict = 'PASS'
    if ($r.Count -eq 0) { $verdict = 'NO_CHECKS' } elseif ($fail -gt 0) { $verdict = 'FAIL' }
    return [pscustomobject][ordered]@{
        total   = $r.Count
        pass    = @($r | Where-Object { $_.Status -eq 'Pass' }).Count
        fail    = $fail
        warn    = @($r | Where-Object { $_.Status -eq 'Warn' }).Count
        skip    = @($r | Where-Object { $_.Status -eq 'Skip' }).Count
        verdict = $verdict
    }
}

function ConvertTo-UtcStamp {
    param([datetime]$Time)
    return $Time.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function New-BeaconResultsDocument {
    <#
    Builds the results document. Pure given its inputs.
    $Context keys: RunId, Started (DateTime), Finished (DateTime), Node, Region, RegionRequested, Oem,
    ArcGatewayMode (bool), ProxyConfigured (bool), Categories (int[]), EndpointSource.
    #>
    param([object[]]$Results = @(), [Parameter(Mandatory)] [hashtable]$Context)
    $items = @($Results | ForEach-Object {
            [pscustomobject][ordered]@{
                category    = "$($_.Category)"
                name        = "$($_.Name)"
                target      = "$($_.Target)"
                status      = "$($_.Status)"
                severity    = "$($_.Severity)"
                detail      = "$($_.Detail)"
                durationMs  = [long]$_.DurationMs
                remediation = "$($_.Remediation)"
                source      = "$($_.Source)"
            }
        })
    $dur = [math]::Round(($Context.Finished - $Context.Started).TotalSeconds, 1)
    return [pscustomobject][ordered]@{
        schemaVersion   = $script:BeaconSchemaVersion
        tool            = [pscustomobject][ordered]@{ name = 'AzL Beacon'; version = $script:BeaconVersion; releaseTrain = $script:BeaconReleaseTrain }
        runId           = "$($Context.RunId)"
        startedUtc      = ConvertTo-UtcStamp $Context.Started
        finishedUtc     = ConvertTo-UtcStamp $Context.Finished
        durationSeconds = $dur
        redacted        = $false
        node            = $Context.Node
        context         = [pscustomobject][ordered]@{
            region          = "$($Context.Region)"
            regionRequested = "$($Context.RegionRequested)"
            oem             = "$($Context.Oem)"
            arcGatewayMode  = [bool]$Context.ArcGatewayMode
            proxyConfigured = [bool]$Context.ProxyConfigured
            categories      = @($Context.Categories)
            endpointSource  = "$($Context.EndpointSource)"
        }
        summary         = Get-ResultSummary -Results $items
        results         = $items
    }
}

#region ---- redaction ----

function Get-RedactionMap {
    <#
    Values that identify the customer environment, taken from the config and node identity,
    each with a stable token. Longest values first so 'corp.contoso.com' wins over 'contoso.com'.
    #>
    param([object]$Config, [object]$Node)
    $pairs = New-Object System.Collections.Generic.List[object]
    $add = {
        param($value, $token)
        $v = "$value".Trim()
        if ($v.Length -ge 3 -and -not ($pairs | Where-Object { $_.Value -eq $v })) {
            $pairs.Add([pscustomobject]@{ Value = $v; Token = $token })
        }
    }
    if ($Config) {
        $get = { param($n) if ($Config.PSObject.Properties.Name -contains $n) { return $Config.$n } return $null }
        & $add (& $get 'adDomainFqdn') '<domain>'
        & $add (& $get 'adNetbios') '<netbios>'
        & $add (& $get 'clusterName') '<cluster>'
        & $add (& $get 'keyVaultFqdn') '<keyvault>'
        & $add (& $get 'keyVaultName') '<keyvault-name>'
        & $add (& $get 'arcGatewayFqdn') '<arc-gateway>'
        & $add (& $get 'proxyUrl') '<proxy>'
        $i = 0; foreach ($v in @(& $get 'dcFqdns')) { $i++; & $add $v "<dc-$i>" }
        $i = 0; foreach ($v in @(& $get 'nodeFqdns')) { $i++; & $add $v "<node-$i>" }
    }
    if ($Node) {
        & $add $Node.hostname '<host>'
        & $add $Node.serialNumber '<serial>'
        & $add $Node.smbiosUuid '<smbios-uuid>'
    }
    return @($pairs | Sort-Object { $_.Value.Length } -Descending)
}

function Invoke-BeaconRedaction {
    <#
    Redacts a results document: configured identifying values -> tokens, then any remaining GUID ->
    <guid>, any IPv4 -> <ip-n> (stable per address). Returns a NEW document with redacted = $true.
    #>
    param([Parameter(Mandatory)] [object]$Document, [object[]]$Map = @())
    $json = $Document | ConvertTo-Json -Depth 8
    foreach ($m in $Map) {
        $json = [regex]::Replace($json, [regex]::Escape($m.Value), $m.Token, 'IgnoreCase')
    }
    $json = [regex]::Replace($json, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<guid>')
    $ipMap = @{}
    $json = [regex]::Replace($json, '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b', {
            param($mt)
            if (-not $ipMap.ContainsKey($mt.Value)) { $ipMap[$mt.Value] = '<ip-{0}>' -f ($ipMap.Count + 1) }
            $ipMap[$mt.Value]
        })
    $red = $json | ConvertFrom-Json
    $red.redacted = $true
    return $red
}

#endregion

#region ---- HTML / text ----

function ConvertTo-BeaconHtml {
    <# Self-contained HTML summary (no scripts, no external assets). #>
    param([Parameter(Mandatory)] [object]$Document)
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $s = $Document.summary
    $vclass = 'ok'
    if ($s.verdict -eq 'FAIL') { $vclass = 'bad' } elseif ($s.verdict -eq 'NO_CHECKS') { $vclass = 'warn' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>AzL Beacon results</title>')
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:20px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}th{background:#eee}.Pass{color:#0a7a2f}.Fail{color:#b00020;font-weight:bold}.Warn{color:#a35f00}.Skip{color:#777}.ok{color:#0a7a2f}.bad{color:#b00020}.warn{color:#a35f00}.meta td{border:none;padding:1px 12px 1px 0}</style></head><body>')
    [void]$sb.AppendLine(('<h1>AzL Beacon {0} - readiness results</h1>' -f (& $enc $Document.tool.version)))
    [void]$sb.AppendLine(('<p>Verdict: <strong class="{0}">{1}</strong> &nbsp; Pass {2} / Fail {3} / Warn {4} / Skip {5} (total {6})</p>' -f $vclass, (& $enc $s.verdict), $s.pass, $s.fail, $s.warn, $s.skip, $s.total))
    [void]$sb.AppendLine('<table class="meta">')
    foreach ($row in @(
            @('Run id', $Document.runId), @('Started (UTC)', $Document.startedUtc), @('Finished (UTC)', $Document.finishedUtc),
            @('Node', $Document.node.hostname), @('Serial', $Document.node.serialNumber), @('Model', "$($Document.node.manufacturer) $($Document.node.model)"),
            @('Region', $Document.context.region), @('Release train', $Document.tool.releaseTrain), @('Redacted', $Document.redacted))) {
        [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td></tr>' -f (& $enc $row[0]), (& $enc $row[1])))
    }
    [void]$sb.AppendLine('</table><h2>Checks</h2><table><tr><th>Category</th><th>Check</th><th>Target</th><th>Status</th><th>Severity</th><th>Detail</th><th>Remediation</th></tr>')
    foreach ($r in @($Document.results)) {
        [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class="{3}">{3}</td><td>{4}</td><td>{5}</td><td>{6}</td></tr>' -f
                (& $enc $r.category), (& $enc $r.name), (& $enc $r.target), (& $enc $r.status), (& $enc $r.severity), (& $enc $r.detail), (& $enc $r.remediation)))
    }
    [void]$sb.AppendLine('</table></body></html>')
    return $sb.ToString()
}

function ConvertTo-BeaconLogLines {
    param([Parameter(Mandatory)] [object]$Document)
    $s = $Document.summary
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("AzL Beacon $($Document.tool.version) validation log")
    $lines.Add("Run id    : $($Document.runId)")
    $lines.Add("Started   : $($Document.startedUtc)")
    $lines.Add("Duration  : $($Document.durationSeconds)s")
    $lines.Add("Node      : $($Document.node.hostname)  serial=$($Document.node.serialNumber)")
    $lines.Add("Verdict   : $($s.verdict)  (Pass=$($s.pass)  Fail=$($s.fail)  Warn=$($s.warn)  Skip=$($s.skip))")
    $lines.Add('')
    $lines.Add(("{0,-20} {1,-6} {2,-50} {3}" -f 'Category', 'Status', 'Target', 'Detail'))
    foreach ($r in @($Document.results)) {
        $tgt = "$($r.target)"
        if ($tgt.Length -gt 50) { $tgt = $tgt.Substring(0, 47) + '...' }
        $lines.Add(("{0,-20} {1,-6} {2,-50} {3}" -f $r.category, $r.status, $tgt, $r.detail))
    }
    return $lines.ToArray()
}

#endregion

#region ---- save / export ----

function Save-BeaconResults {
    <# Writes validation-<stamp>.json/.log/.html. Returns @{ Json; Log; Html; Stamp }. #>
    param([Parameter(Mandatory)] [object]$Document, [Parameter(Mandatory)] [string]$Directory, [string]$Suffix = '')
    if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $base = Join-Path $Directory "validation-$stamp$Suffix"
    $Document | ConvertTo-Json -Depth 8 | Set-Content -Path "$base.json" -Encoding UTF8
    ConvertTo-BeaconLogLines -Document $Document | Set-Content -Path "$base.log" -Encoding UTF8
    ConvertTo-BeaconHtml -Document $Document | Set-Content -Path "$base.html" -Encoding UTF8
    return @{ Json = "$base.json"; Log = "$base.log"; Html = "$base.html"; Stamp = $stamp }
}

function Resolve-ExportTarget {
    <#
    Classifies an export destination.
      'E' | 'E:' | 'E:\'            -> Drive  (USB or any local volume)
      '\\server\share[\sub]'        -> Smb
      'https://...' | 'http://...'  -> Http   (http only with -AllowInsecureHttp)
    Returns @{ Kind; Value; Error }.
    #>
    param([string]$Target, [switch]$AllowInsecureHttp)
    $t = "$Target".Trim()
    if ($t -eq '') { return @{ Kind = 'None'; Value = ''; Error = 'empty target' } }
    if ($t -match '^[A-Za-z]:?\\?$') { return @{ Kind = 'Drive'; Value = ($t.Substring(0, 1).ToUpperInvariant() + ':\'); Error = '' } }
    if ($t -match '^\\\\[^\\]+\\[^\\]+') { return @{ Kind = 'Smb'; Value = $t.TrimEnd('\'); Error = '' } }
    if ($t -match '^https://') { return @{ Kind = 'Http'; Value = $t; Error = '' } }
    if ($t -match '^http://') {
        if ($AllowInsecureHttp) { return @{ Kind = 'Http'; Value = $t; Error = '' } }
        return @{ Kind = 'None'; Value = $t; Error = 'plain http refused; use https or pass -AllowInsecureHttp' }
    }
    if ($t -match '^[A-Za-z]:\\.+') { return @{ Kind = 'Drive'; Value = $t; Error = '' } }
    return @{ Kind = 'None'; Value = $t; Error = 'not a drive letter, UNC share or http(s) URL' }
}

function Export-BeaconResults {
    <#
    Copies the result files to a drive/UNC folder, or POSTs the JSON to an http(s) endpoint.
    SMB credentials (if given) are used for this call only and never stored.
    Returns @{ Ok; Kind; Detail }.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$Files,
        [Parameter(Mandatory)] [string]$Target,
        [pscredential]$Credential,
        [string]$BearerToken = '',
        [switch]$AllowInsecureHttp
    )
    $t = Resolve-ExportTarget -Target $Target -AllowInsecureHttp:$AllowInsecureHttp
    if ($t.Kind -eq 'None') { return @{ Ok = $false; Kind = 'None'; Detail = $t.Error } }
    try {
        switch ($t.Kind) {
            'Drive' {
                if (-not (Test-Path $t.Value)) { return @{ Ok = $false; Kind = 'Drive'; Detail = "path not found: $($t.Value)" } }
                $dest = Join-Path $t.Value 'beacon-results'
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                foreach ($f in @($Files.Json, $Files.Log, $Files.Html)) { if ($f -and (Test-Path $f)) { Copy-Item $f $dest -Force } }
                return @{ Ok = $true; Kind = 'Drive'; Detail = "copied to $dest" }
            }
            'Smb' {
                $driveName = 'BeaconExport'
                $p = @{ Name = $driveName; PSProvider = 'FileSystem'; Root = $t.Value; ErrorAction = 'Stop' }
                if ($Credential) { $p.Credential = $Credential }
                $null = New-PSDrive @p
                try {
                    foreach ($f in @($Files.Json, $Files.Log, $Files.Html)) { if ($f -and (Test-Path $f)) { Copy-Item $f "${driveName}:\" -Force } }
                } finally {
                    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
                }
                return @{ Ok = $true; Kind = 'Smb'; Detail = "copied to $($t.Value)" }
            }
            'Http' {
                Enable-BeaconTls12
                $headers = @{}
                if ($BearerToken) { $headers.Authorization = "Bearer $BearerToken" }
                $body = Get-Content -Path $Files.Json -Raw
                $null = Invoke-RestMethod -Method Post -Uri $t.Value -Body $body -ContentType 'application/json' -Headers $headers -TimeoutSec 60 -ErrorAction Stop
                return @{ Ok = $true; Kind = 'Http'; Detail = "posted to $($t.Value)" }
            }
        }
    } catch {
        return @{ Ok = $false; Kind = $t.Kind; Detail = $_.Exception.Message }
    }
    return @{ Ok = $false; Kind = $t.Kind; Detail = 'unhandled target' }
}

#endregion
