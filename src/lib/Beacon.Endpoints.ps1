# AzL Beacon - endpoint data access (region / OEM selection). Pure; unit tested.

$script:RegionAliases = @{
    'eastus' = 'eastus'; 'east us' = 'eastus'
    'westeurope' = 'westeurope'; 'west europe' = 'westeurope'
    'australiaeast' = 'australiaeast'; 'australia east' = 'australiaeast'
    'canadacentral' = 'canadacentral'; 'canada central' = 'canadacentral'
    'centralindia' = 'centralindia'; 'india central' = 'centralindia'; 'central india' = 'centralindia'
    'southeastasia' = 'southeastasia'; 'southeast asia' = 'southeastasia'; 'south east asia' = 'southeastasia'
    'japaneast' = 'japaneast'; 'japan east' = 'japaneast'
    'southcentralus' = 'southcentralus'; 'south central us' = 'southcentralus'
    'usgovvirginia' = 'usgovvirginia'; 'us gov virginia' = 'usgovvirginia'; 'usgov virginia' = 'usgovvirginia'
}

function ConvertTo-BeaconRegionKey {
    <# 'East US' | 'eastus' | 'EASTUS ' -> 'eastus'; '' when unknown. #>
    param([string]$Region)
    if ([string]::IsNullOrWhiteSpace($Region)) { return '' }
    $k = $Region.Trim().ToLowerInvariant()
    if ($script:RegionAliases.ContainsKey($k)) { return $script:RegionAliases[$k] }
    $compact = $k -replace '[\s_-]', ''
    if ($script:RegionAliases.ContainsKey($compact)) { return $script:RegionAliases[$compact] }
    return ''
}

function Get-BeaconRegionKeys {
    param([object]$Data)
    return @($Data.regions.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-BeaconEndpointSet {
    <#
    Returns @{ Region; RegionRequested; FellBack; Cloud; SourceUrl; LastUpdated; Endpoints }.
    Unknown/empty region falls back to eastus (FellBack = $true) so the sweep still runs.
    OEM rows (e.g. 'dell') are appended when requested and present in the data file.
    #>
    param(
        [Parameter(Mandatory)] [object]$Data,
        [string]$Region = '',
        [string]$Oem = ''
    )
    $key = ConvertTo-BeaconRegionKey $Region
    $fell = $false
    if (-not $key -or -not ($Data.regions.PSObject.Properties.Name -contains $key)) {
        $key = 'eastus'
        $fell = $true
    }
    $block = $Data.regions.$key
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in $block.endpoints) { $list.Add($e) }
    $oemKey = "$Oem".Trim().ToLowerInvariant()
    if ($oemKey -and ($Data.oem.PSObject.Properties.Name -contains $oemKey)) {
        foreach ($e in $Data.oem.$oemKey.endpoints) { $list.Add($e) }
    }
    return @{
        Region          = $key
        RegionRequested = $Region
        FellBack        = $fell
        Cloud           = $block.cloud
        SourceUrl       = $block.sourceUrl
        LastUpdated     = $block.lastUpdated
        Endpoints       = $list.ToArray()
    }
}

function Get-PublicIpCheckTargets {
    <#
    Endpoints Learn says must resolve to PUBLIC IPs (Arc Private Link Scopes are not supported for
    Azure Local): *.his.arc.azure.com, *.guestconfiguration.azure.com, *.dp.kubernetesconfiguration.azure.com.
    Returns the concrete (non-wildcard) hosts from the set that match.
    #>
    param([object[]]$Endpoints)
    $patterns = @('\.his\.arc\.azure\.com$', '\.guestconfiguration\.azure\.com$', '\.dp\.kubernetesconfiguration\.azure\.com$')
    $hosts = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Endpoints) {
        if ($e.wildcard -or $e.placeholder) { continue }
        foreach ($p in $patterns) {
            if ($e.host -match $p -and -not $hosts.Contains($e.host)) { $hosts.Add($e.host) }
        }
    }
    return $hosts.ToArray()
}
