#Requires -Version 7.0
<#
.SYNOPSIS
    Writes Beacon's validation-config.json from the Azure Local infrastructure.yml.

.DESCRIPTION
    infrastructure.yml (the azurelocal-toolkit variables registry, schema 5) holds every engagement value
    Beacon tests: region, DNS, NTP, the domain and its controllers, the management network and the
    infrastructure pool, the machines, the cluster Key Vault, the proxy and the Network ATC intents.
    This script maps them to validation-config.json, the file Start-AzlValidation.ps1 and the WinPE menu
    read when there is no YAML parser (WinPE). Build-WinPEImage.ps1 -InfrastructureFile calls it.

    Beacon's own settings (oem, arcGatewayFqdn, tlsInspectionHosts, tcpConnectTimeoutMs, pingTimeoutMs, brand;
    tools.beacon in the registry) come from -SettingsPath when given, else the defaults. Any other key in that
    file is ignored: infrastructure.yml is the only source of the engagement values.
    The Azure subscription, tenant and resource group are left out of the written file unless
    -IncludeAzureTargets is set: Beacon never writes them to disk by default.

.PARAMETER InfrastructureFile
    The infrastructure.yml (or .json) to read. Reading YAML needs the powershell-yaml module.

.PARAMETER OutputPath
    The validation-config.json to write. Default: src\config\validation-config.json (gitignored).

.PARAMETER SettingsPath
    A JSON file with Beacon's own settings (for example an earlier validation-config.json). Optional.

.PARAMETER IncludeAzureTargets
    Also write arcSubscriptionId, arcTenantId and arcResourceGroup (for an image that runs the Arc checks
    without anyone typing them).

.PARAMETER ShowSources
    Print each field, its value and the infrastructure.yml key it came from.

.EXAMPLE
    ./src/ConvertTo-BeaconValidationConfig.ps1 -InfrastructureFile D:\azl\infrastructure.yml -ShowSources
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$InfrastructureFile,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'config\validation-config.json'),
    [string]$SettingsPath = '',
    [switch]$IncludeAzureTargets,
    [switch]$ShowSources
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Beacon.Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Beacon.Infrastructure.ps1')

function Get-BeaconWritableConfig {
    <# The generated config without the in-memory Azure targets (unless asked for) and with _sources kept for review. Pure. #>
    param([Parameter(Mandatory)] [object]$Config, [switch]$IncludeAzureTargets)
    $out = [ordered]@{}
    foreach ($p in $Config.PSObject.Properties) {
        if (-not $IncludeAzureTargets -and $p.Name -in @('arcSubscriptionId', 'arcTenantId', 'arcResourceGroup')) { continue }
        $out[$p.Name] = $p.Value
    }
    return [pscustomobject]$out
}

if ($MyInvocation.InvocationName -eq '.') { return }

$infra = Import-BeaconInfrastructureFile -Path $InfrastructureFile
$settings = $null
if ($SettingsPath) { $settings = Import-JsonConfig -FilePath $SettingsPath }
$cfg = ConvertTo-BeaconValidationConfig -Infrastructure $infra -SourceName ([System.IO.Path]::GetFileName($InfrastructureFile)) -Settings $settings
$writable = Get-BeaconWritableConfig -Config $cfg -IncludeAzureTargets:$IncludeAzureTargets

if ($ShowSources) {
    foreach ($p in $cfg.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $value = if ($p.Value -is [System.Array]) { ($p.Value | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress -Depth 4 } }) -join ', ' } else { "$($p.Value)" }
        if ($p.Name -in @('arcSubscriptionId', 'arcTenantId') -and $value) { $value = '(set)' }
        Write-Information -MessageData ('{0,-22} = {1}' -f $p.Name, $value) -InformationAction Continue
        Write-Information -MessageData ('{0,-22}   from {1}' -f '', $cfg._sources.($p.Name)) -InformationAction Continue
    }
}

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write validation-config.json')) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $writable | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    Write-Information -MessageData "Wrote $OutputPath from $InfrastructureFile" -InformationAction Continue
}
