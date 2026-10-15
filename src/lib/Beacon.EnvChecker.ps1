# AzL Beacon - Microsoft Environment Checker (AzStackHci.EnvironmentChecker) integration helpers.
# The module is built for Windows PowerShell 5.1 (net472 assemblies); Beacon runs it there.

function Resolve-EnvCheckerManifest {
    <#
    The module ships as <root>\<version>\AzStackHci.EnvironmentChecker.psd1. Importing the version-less
    folder is not reliable in WinPE (no PSModulePath indexing), so resolve the manifest explicitly:
    highest version folder that contains the manifest. Also accepts a root that IS a version folder.
    Returns the manifest path or $null.
    #>
    param([string[]]$Roots)
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path $root -PathType Container)) { continue }
        $direct = Join-Path $root 'AzStackHci.EnvironmentChecker.psd1'
        if (Test-Path $direct) { return $direct }
        $versions = @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object {
                (Test-Path (Join-Path $_.FullName 'AzStackHci.EnvironmentChecker.psd1'))
            } | Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending)
        if ($versions.Count -gt 0) { return (Join-Path $versions[0].FullName 'AzStackHci.EnvironmentChecker.psd1') }
    }
    return $null
}

function Get-EnvCheckerModuleRoots {
    param([string]$ScriptRoot)
    return @(
        [System.IO.Path]::Combine($ScriptRoot, '..\tools\modules\AzStackHci.EnvironmentChecker'),
        [System.IO.Path]::Combine($ScriptRoot, 'Modules\AzStackHci.EnvironmentChecker'),
        [System.IO.Path]::Combine($ScriptRoot, '..\Modules\AzStackHci.EnvironmentChecker'),
        'X:\Tools\Modules\AzStackHci.EnvironmentChecker'
    )
}

function ConvertFrom-EnvCheckerResult {
    <#
    Maps Environment Checker result objects (New-AzStackHciResultObject: Name, DisplayName, Title,
    Status, Severity, Description, Remediation, TargetResourceName/ID/Type, AdditionalData) to
    Add-ValidationResult parameter hashtables. Succeeded = Pass; Failed + CRITICAL = Fail;
    Failed + WARNING = Warn; Failed + INFORMATIONAL = Warn; everything else = Skip.
    #>
    param(
        [object[]]$Results,
        [string]$Category,
        [string]$Prefix = 'EnvChecker'
    )
    $items = New-Object System.Collections.Generic.List[hashtable]
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $get = {
            param($n)
            if ($r.PSObject.Properties.Name -contains $n -and $null -ne $r.$n) { return "$($r.$n)" }
            return ''
        }
        $status = & $get 'Status'
        $sevRaw = (& $get 'Severity').ToUpperInvariant()
        $mapped = 'Skip'
        switch -Regex ($status) {
            '^(Succeeded|Success|Pass(ed)?)$' { $mapped = 'Pass' }
            '^(Failed|Failure|Fail)$' { if ($sevRaw -eq 'CRITICAL') { $mapped = 'Fail' } else { $mapped = 'Warn' } }
            '^(Warning|Warn)$' { $mapped = 'Warn' }
        }
        $sev = ''
        switch ($sevRaw) {
            'CRITICAL' { $sev = 'critical' }
            'WARNING' { $sev = 'warning' }
            'INFORMATIONAL' { $sev = 'informational' }
        }
        $name = & $get 'Name'
        if (-not $name) { $name = & $get 'DisplayName' }
        $target = & $get 'TargetResourceName'
        if (-not $target) { $target = & $get 'TargetResourceID' }
        $detail = & $get 'Description'
        if (-not $detail) { $detail = & $get 'Title' }
        $items.Add(@{
                Category    = $Category
                Name        = "$Prefix-$name"
                Target      = $target
                Status      = $mapped
                Severity    = $sev
                Detail      = $detail
                Remediation = (& $get 'Remediation')
                Source      = 'AzStackHci.EnvironmentChecker'
            })
    }
    return $items.ToArray()
}

function Get-EnvCheckerConnectivityParameters {
    <# Parameters for Invoke-AzStackHciConnectivityValidation built from the Beacon config. Pure. #>
    param([object]$Config, [string]$RegionKey, [bool]$UseLocalDefinitions = $true, [string]$OutputPath = '')
    $p = @{ PassThru = $true }
    if ($RegionKey) { $p.RegionName = $RegionKey }
    if ($Config.proxyUrl) { $p.Proxy = $Config.proxyUrl }
    if ($Config.arcGatewayFqdn) { $p.ARCGateway = $true }
    if ($UseLocalDefinitions) { $p.UseLocalDefinitionsOnly = $true }
    if ($OutputPath) { $p.OutputPath = $OutputPath }
    return $p
}

function Get-EnvCheckerNetworkParameters {
    <#
    Parameters for Invoke-AzStackHciNetworkValidation (EceParameter set). Returns
    @{ CanRun; Reason; Parameters }. The validator needs: IpPools, ManagementSubnetValue, NodesInCluster,
    AtcHostIntents and PSSession(s) to the nodes. Missing inputs -> CanRun=$false with a reason.
    config fields: infraIpPools = [{ StartingAddress, EndingAddress }], managementSubnetCidr,
    nodeIps/nodeFqdns (count), hostNetworkIntents = [{ Name, TrafficType, Adapter, OverrideAdapterProperty... }]
    #>
    param([object]$Config)
    $missing = New-Object System.Collections.Generic.List[string]
    if (@($Config.infraIpPools).Count -eq 0) { $missing.Add('infraIpPools') }
    if (-not $Config.managementSubnetCidr) { $missing.Add('managementSubnetCidr') }
    if (@($Config.hostNetworkIntents).Count -eq 0) { $missing.Add('hostNetworkIntents') }
    $nodeCount = @($Config.nodeIps).Count
    if ($nodeCount -eq 0) { $nodeCount = @($Config.nodeFqdns).Count }
    if ($nodeCount -eq 0) { $missing.Add('nodeIps') }
    if ($missing.Count -gt 0) {
        return @{ CanRun = $false; Reason = "config is missing: $($missing -join ', ')"; Parameters = @{} }
    }
    $pools = New-Object System.Collections.ArrayList
    foreach ($ip in @($Config.infraIpPools)) {
        [void]$pools.Add([pscustomobject]@{ StartingAddress = $ip.StartingAddress; EndingAddress = $ip.EndingAddress })
    }
    $p = @{
        IpPools               = $pools
        ManagementSubnetValue = "$($Config.managementSubnetCidr)"
        NodesInCluster        = [int16]$nodeCount
        AtcHostIntents        = @($Config.hostNetworkIntents)
        PassThru              = $true
    }
    return @{ CanRun = $true; Reason = ''; Parameters = $p }
}
