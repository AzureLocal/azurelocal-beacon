# AzL Beacon - reads the Azure Local infrastructure.yml (the azurelocal-toolkit variables registry, schema 5)
# and builds Beacon's validation config from it. infrastructure.yml is the source of every engagement value;
# validation-config.json is only Beacon's run-time copy (generated, or hand-filled when there is no file).
# Dot-sourced by Start-AzlValidation.ps1 and ConvertTo-BeaconValidationConfig.ps1. PowerShell 5.1 compatible.

function Get-BeaconInfraValue {
    <# Null-safe lookup of a dotted path in a parsed infrastructure file (hashtables from YAML, objects from JSON). Pure. #>
    param($Object, [string]$Path)
    $cur = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($part)) { $cur = $cur[$part] } else { return $null }
        } elseif ($cur.PSObject.Properties.Name -contains $part) {
            $cur = $cur.$part
        } else {
            return $null
        }
    }
    return $cur
}

function Import-BeaconInfrastructureFile {
    <#
    Reads infrastructure.yml (needs the powershell-yaml module: ConvertFrom-Yaml) or an infrastructure.json.
    WinPE has no YAML parser: there the image carries the validation-config.json that
    ConvertTo-BeaconValidationConfig.ps1 (or Build-WinPEImage.ps1 -InfrastructureFile) generated at build time.
    #>
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Infrastructure file not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($Path -match '\.json$') { return ($raw | ConvertFrom-Json) }
    if (-not (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "Reading $Path needs the powershell-yaml module (Install-Module powershell-yaml -Scope CurrentUser). In WinPE, build the image with Build-WinPEImage.ps1 -InfrastructureFile so it carries the generated validation-config.json."
    }
    return (ConvertFrom-Yaml -Yaml $raw)
}

function Test-BeaconIPv4 {
    param([string]$Value)
    return ($Value -match '^\d{1,3}(\.\d{1,3}){3}$')
}

function Get-BeaconNodeManagementIp {
    <# nodes[].management.ip_address (schema 5.0/5.1), else the network_adapters[] port with role management (5.2+). Pure. #>
    param($Node)
    $ip = Get-BeaconInfraValue $Node 'management.ip_address'
    if ($ip) { return "$ip" }
    foreach ($a in @(Get-BeaconInfraValue $Node 'network_adapters')) {
        if ($null -eq $a) { continue }
        $roles = @(Get-BeaconInfraValue $a 'roles' | ForEach-Object { "$_".ToLowerInvariant() })
        $aip = Get-BeaconInfraValue $a 'ip_address'
        if ($roles -contains 'management' -and $aip) { return "$aip" }
    }
    return ''
}

function ConvertTo-BeaconTrafficType {
    <# networking.intents[].traffic (management, compute, storage) -> the Network ATC names the Environment Checker takes. Pure. #>
    param([string]$Traffic)
    switch ($Traffic.ToLowerInvariant()) {
        'management' { return 'Management' }
        'compute' { return 'Compute' }
        'storage' { return 'Storage' }
        default { return $Traffic }
    }
}

function Get-BeaconOsAdapterName {
    <# The OS name of a port the intents name: network_adapters[].os_name_override on the first node, else the name. Pure. #>
    param($Infrastructure, [string]$Name)
    $first = @(Get-BeaconInfraValue $Infrastructure 'nodes') | Select-Object -First 1
    foreach ($a in @(Get-BeaconInfraValue $first 'network_adapters')) {
        if ($null -eq $a) { continue }
        if ("$(Get-BeaconInfraValue $a 'name')" -eq $Name) {
            $o = Get-BeaconInfraValue $a 'os_name_override'
            if ($o) { return "$o" }
        }
    }
    return $Name
}

function Get-BeaconProxyFromInfrastructure {
    <# scenario.outbound_path -> @{ Url; Bypass; Source }. proxy / proxy_arc_gateway: networking.outbound.proxy; private_path: the Azure Firewall explicit proxy. Pure. #>
    param($Infrastructure)
    $path = "$(Get-BeaconInfraValue $Infrastructure 'scenario.outbound_path')".ToLowerInvariant()
    if ($path -eq 'proxy' -or $path -eq 'proxy_arc_gateway') {
        return @{
            Url    = "$(Get-BeaconInfraValue $Infrastructure 'networking.outbound.proxy.url')"
            Bypass = @(ConvertTo-StringList (Get-BeaconInfraValue $Infrastructure 'networking.outbound.proxy.bypass'))
            Source = 'networking.outbound.proxy.url, networking.outbound.proxy.bypass'
        }
    }
    if ($path -eq 'private_path') {
        $fw = Get-BeaconInfraValue $Infrastructure 'networking.outbound.private_path.firewall_private_ip'
        $port = Get-BeaconInfraValue $Infrastructure 'networking.outbound.private_path.firewall_port'
        $url = ''
        if ($fw -and $port) { $url = "http://${fw}:$port" }
        return @{
            Url    = $url
            Bypass = @(ConvertTo-StringList (Get-BeaconInfraValue $Infrastructure 'networking.outbound.private_path.proxy_bypass'))
            Source = 'networking.outbound.private_path.firewall_private_ip, firewall_port, proxy_bypass'
        }
    }
    return @{ Url = ''; Bypass = @(); Source = "scenario.outbound_path ($path): no proxy" }
}

# Beacon's own settings: the only keys Beacon keeps in its own config (registered in the azurelocal-toolkit
# registry as tools.beacon). Every other value of a run comes from infrastructure.yml.
$script:BeaconOwnSettings = @('oem', 'arcGatewayFqdn', 'tlsInspectionHosts', 'tcpConnectTimeoutMs', 'pingTimeoutMs', 'brand')

function Get-BeaconOwnSetting {
    <# One Beacon setting from the settings object (validation-config.json), else $null. Pure. #>
    param($Settings, [string]$Name)
    if ($null -eq $Settings) { return $null }
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains($Name)) { return $Settings[$Name] }
        return $null
    }
    if ($Settings.PSObject.Properties.Name -contains $Name) { return $Settings.$Name }
    return $null
}

function ConvertTo-BeaconValidationConfig {
    <#
    Builds Beacon's validation config (the validation-config.json shape) from a parsed infrastructure.yml.
    Every engagement value comes from a registry key. Beacon's own settings ($script:BeaconOwnSettings: the OEM
    list, the Arc gateway endpoint, TLS inspection hosts, timeouts, brand) come from -Settings (Beacon's
    validation-config.json; any other key in it is ignored), else the defaults.
    The result carries _sources: field -> the infrastructure.yml key (or Beacon setting) it came from. Pure.
    #>
    param([Parameter(Mandatory)] $Infrastructure, [string]$SourceName = 'infrastructure.yml', $Settings = $null)

    $src = [ordered]@{}
    $cfg = [ordered]@{}
    $set = {
        param([string]$Field, $Value, [string]$Source)
        $cfg[$Field] = $Value
        $src[$Field] = $Source
    }

    $clusterName = "$(Get-BeaconInfraValue $Infrastructure 'cluster.name')"
    & $set '_comment' "Generated by AzL Beacon from $SourceName (the azurelocal-toolkit registry). Edit infrastructure.yml and regenerate; do not edit this file." ''
    & $set '_engagement' $clusterName 'cluster.name'

    & $set 'azureRegion' "$(Get-BeaconInfraValue $Infrastructure 'azure.location')" 'azure.location'
    & $set 'dnsServers' @(ConvertTo-StringList (Get-BeaconInfraValue $Infrastructure 'networking.management.dns_servers')) 'networking.management.dns_servers'
    & $set 'ntpServers' @(ConvertTo-StringList (Get-BeaconInfraValue $Infrastructure 'networking.ntp_servers')) 'networking.ntp_servers'

    # Identity: only the Active Directory path has a domain to test (category 3).
    $identity = "$(Get-BeaconInfraValue $Infrastructure 'scenario.identity')".ToLowerInvariant()
    $domain = ''
    $netbios = ''
    $dcIps = @()
    $dcFqdns = @()
    if ($identity -ne 'local_identity') {
        $domain = "$(Get-BeaconInfraValue $Infrastructure 'identity.active_directory.domain_fqdn')"
        $netbios = "$(Get-BeaconInfraValue $Infrastructure 'identity.active_directory.netbios_name')"
        foreach ($dc in @(ConvertTo-StringList (Get-BeaconInfraValue $Infrastructure 'identity.active_directory.domain_controllers'))) {
            if (Test-BeaconIPv4 $dc) { $dcIps += $dc } else { $dcFqdns += $dc }
        }
    }
    & $set 'adDomainFqdn' $domain 'identity.active_directory.domain_fqdn (scenario.identity active_directory)'
    & $set 'adNetbios' $netbios 'identity.active_directory.netbios_name'
    & $set 'dcIps' @($dcIps) 'identity.active_directory.domain_controllers (addresses)'
    & $set 'dcFqdns' @($dcFqdns) 'identity.active_directory.domain_controllers (names)'

    & $set 'managementGateway' "$(Get-BeaconInfraValue $Infrastructure 'networking.management.gateway')" 'networking.management.gateway'
    & $set 'managementSubnetCidr' "$(Get-BeaconInfraValue $Infrastructure 'networking.management.subnet')" 'networking.management.subnet'
    $vlan = Get-BeaconInfraValue $Infrastructure 'networking.management.vlan_id'
    if ($null -eq $vlan -or "$vlan" -eq '') { $vlan = 0 }
    & $set 'managementVlan' ([int]$vlan) 'networking.management.vlan_id'

    $nodeIps = @()
    $nodeFqdns = @()
    $nodeNames = @()
    foreach ($n in @(Get-BeaconInfraValue $Infrastructure 'nodes')) {
        if ($null -eq $n) { continue }
        $name = "$(Get-BeaconInfraValue $n 'name')"
        $ip = Get-BeaconNodeManagementIp -Node $n
        if ($ip) { $nodeIps += $ip }
        if ($name -and $domain) { $nodeFqdns += "$name.$domain" }
        $arcName = "$(Get-BeaconInfraValue $n 'arc_machine_name')"
        if (-not $arcName) { $arcName = $name }
        if ($arcName) { $nodeNames += $arcName }
    }
    & $set 'nodeIps' @($nodeIps) 'nodes[].management.ip_address (or the network_adapters[] port with role management)'
    & $set 'nodeFqdns' @($nodeFqdns) 'nodes[].name + identity.active_directory.domain_fqdn'

    $kvName = "$(Get-BeaconInfraValue $Infrastructure 'cluster.key_vault.name')"
    $kvSuffix = 'vault.azure.net'
    if ("$(Get-BeaconInfraValue $Infrastructure 'scenario.cloud')".ToLowerInvariant() -eq 'government') { $kvSuffix = 'vault.usgovcloudapi.net' }
    $kvFqdn = ''
    if ($kvName) { $kvFqdn = "$kvName.$kvSuffix" }
    & $set 'keyVaultName' $kvName 'cluster.key_vault.name'
    & $set 'keyVaultFqdn' $kvFqdn 'cluster.key_vault.name + scenario.cloud'
    & $set 'clusterName' $clusterName 'cluster.name'

    $proxy = Get-BeaconProxyFromInfrastructure -Infrastructure $Infrastructure
    & $set 'proxyUrl' $proxy.Url $proxy.Source
    & $set 'proxyBypass' @($proxy.Bypass) $proxy.Source

    $pools = @()
    $poolStart = Get-BeaconInfraValue $Infrastructure 'networking.management.infrastructure_pool.start'
    $poolEnd = Get-BeaconInfraValue $Infrastructure 'networking.management.infrastructure_pool.end'
    if ($poolStart -and $poolEnd) { $pools += [pscustomobject][ordered]@{ StartingAddress = "$poolStart"; EndingAddress = "$poolEnd" } }
    & $set 'infraIpPools' @($pools) 'networking.management.infrastructure_pool'

    $intents = @()
    foreach ($i in @(Get-BeaconInfraValue $Infrastructure 'networking.intents')) {
        if ($null -eq $i) { continue }
        $intents += [pscustomobject][ordered]@{
            Name        = "$(Get-BeaconInfraValue $i 'name')"
            TrafficType = @(@(Get-BeaconInfraValue $i 'traffic') | Where-Object { $_ } | ForEach-Object { ConvertTo-BeaconTrafficType "$_" })
            Adapter     = @(@(Get-BeaconInfraValue $i 'adapters') | Where-Object { $_ } | ForEach-Object { Get-BeaconOsAdapterName -Infrastructure $Infrastructure -Name "$_" })
        }
    }
    & $set 'hostNetworkIntents' @($intents) 'networking.intents (adapter names through nodes[0].network_adapters[].os_name_override)'

    # Arc readiness (category 6): targets only; the sign-in stays interactive and nothing is written to disk by the run.
    & $set 'arcSubscriptionId' "$(Get-BeaconInfraValue $Infrastructure 'azure.subscription_id')" 'azure.subscription_id'
    & $set 'arcTenantId' "$(Get-BeaconInfraValue $Infrastructure 'azure.tenant_id')" 'azure.tenant_id'
    & $set 'arcResourceGroup' "$(Get-BeaconInfraValue $Infrastructure 'azure.resource_group')" 'azure.resource_group'
    & $set 'arcNodeNames' @($nodeNames) 'nodes[].arc_machine_name (default nodes[].name)'

    # Beacon's own settings (validation-config.json; tools.beacon in the registry); defaults when not set.
    $own = 'Beacon setting {0} (validation-config.json)'
    $vendor = "$(Get-BeaconInfraValue $Infrastructure 'hardware.vendor')".ToLowerInvariant()
    $oem = "$(Get-BeaconOwnSetting $Settings 'oem')"
    $oemSource = $own -f 'oem'
    if (-not $oem -and $vendor -eq 'dell') { $oem = 'dell'; $oemSource = 'hardware.vendor (Dell has an OEM endpoint list)' }
    & $set 'oem' $oem $oemSource

    $gwSource = ($own -f 'arcGatewayFqdn') + '; the registry names the Arc gateway resource (networking.outbound.arc_gateway.name), not its endpoint'
    & $set 'arcGatewayFqdn' "$(Get-BeaconOwnSetting $Settings 'arcGatewayFqdn')" $gwSource

    $tls = @(ConvertTo-StringList (Get-BeaconOwnSetting $Settings 'tlsInspectionHosts'))
    $tlsSource = $own -f 'tlsInspectionHosts'
    if ($tls.Count -eq 0) { $tls = @('login.microsoftonline.com', 'management.azure.com'); $tlsSource = 'Beacon default' }
    & $set 'tlsInspectionHosts' @($tls) $tlsSource

    $tcp = Get-BeaconOwnSetting $Settings 'tcpConnectTimeoutMs'
    $tcpSource = $own -f 'tcpConnectTimeoutMs'
    if (-not $tcp) { $tcp = 5000; $tcpSource = 'Beacon default' }
    & $set 'tcpConnectTimeoutMs' ([int]$tcp) $tcpSource
    $ping = Get-BeaconOwnSetting $Settings 'pingTimeoutMs'
    $pingSource = $own -f 'pingTimeoutMs'
    if (-not $ping) { $ping = 2000; $pingSource = 'Beacon default' }
    & $set 'pingTimeoutMs' ([int]$ping) $pingSource
    & $set 'brand' "$(Get-BeaconOwnSetting $Settings 'brand')" ($own -f 'brand')

    $result = [pscustomobject]$cfg
    $result | Add-Member -MemberType NoteProperty -Name '_sources' -Value ([pscustomobject]$src) -Force
    return $result
}

function Get-BeaconInfrastructureContext {
    <# What the results document records about the file it ran from: name, SHA-256, schema version, cluster. #>
    param([Parameter(Mandatory)] [string]$Path, $Infrastructure)
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { $hash = '' }
    return [pscustomobject][ordered]@{
        fileName      = [System.IO.Path]::GetFileName($Path)
        sha256        = $hash
        schemaVersion = "$(Get-BeaconInfraValue $Infrastructure '_metadata.schema_version')"
        clusterName   = "$(Get-BeaconInfraValue $Infrastructure 'cluster.name')"
    }
}

function Get-BeaconInfrastructureScopeNote {
    <#
    A file cut for another tool (_metadata.scope other than full or beacon, for example ztp) lacks sections Beacon
    tests (identity, cluster, intents). Returns the warning to show, or '' for a full file or the beacon cut. Pure.
    #>
    param([Parameter(Mandatory)] $Infrastructure)
    $scope = "$(Get-BeaconInfraValue $Infrastructure '_metadata.scope')".ToLowerInvariant()
    if (-not $scope -or $scope -eq 'full' -or $scope -eq 'beacon') { return '' }
    return "The file has _metadata.scope '$scope': it is cut for another tool and may lack what Beacon tests (identity, cluster, intents). Use the full infrastructure.yml or the beacon cut (New-InfrastructureArtifacts.ps1 -Cut beacon)."
}

function Get-BeaconEvidenceDirectory {
    <#
    Where Beacon writes its results when it runs from infrastructure.yml: <discovery folder>\beacon.
    The discovery folder is the one Sonar's Discovery view reads: hardware.discovery.output_directory when the
    file has it, else <provisioning.simplified.evidence_path>\discovery, else ZTP's default
    %ProgramData%\AzureLocalZtp\<site_name>\evidence\discovery. Empty when the file names none of them. Pure.
    #>
    param([Parameter(Mandatory)] $Infrastructure)
    $discovery = "$(Get-BeaconInfraValue $Infrastructure 'hardware.discovery.output_directory')"
    if (-not $discovery) {
        $evidence = "$(Get-BeaconInfraValue $Infrastructure 'provisioning.simplified.evidence_path')"
        if (-not $evidence) {
            $site = "$(Get-BeaconInfraValue $Infrastructure 'provisioning.simplified.site_name')"
            if ($site) { $evidence = "%ProgramData%\AzureLocalZtp\$site\evidence" }
        }
        if ($evidence) { $discovery = $evidence.TrimEnd('\', '/') + '\discovery' }
    }
    if (-not $discovery) { return '' }
    return ([Environment]::ExpandEnvironmentVariables($discovery.TrimEnd('\', '/')) + '\beacon')
}
