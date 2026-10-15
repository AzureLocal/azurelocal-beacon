#Requires -Version 5.1
<#
.SYNOPSIS
    AzL Beacon: interactive boot menu for Azure Local pre-deployment readiness validation.

.DESCRIPTION
    Entry point started by startnet.cmd at WinPE boot. Runs the network bootstrap, then shows a
    menu so the operator chooses which deployment path to validate:

      1) Active Directory deployment
      2) Local Identity (AD-less) deployment
      3) Networking and Firewall
      4) Full readiness sweep (all 6 categories)
      5) Arc readiness (sign-in + Azure REST checks)
      6) Network settings (re-run bootstrap)
      7) Open PowerShell console
      8) Export results (USB drive, SMB share or HTTPS)
      9) Region, proxy and Arc gateway settings
      0) Exit to command prompt

    Each path collects the inputs it needs and calls the validation engine
    (Start-AzlValidation.ps1) with the right -Categories. Arc subscription/tenant ids are passed to
    the engine through process environment variables only, never written to disk.

    Compatible with PowerShell 5.1 (WinPE) and PowerShell 7. ASCII only (WinPE consoles and
    PowerShell 5.1 mis-read UTF-8 without BOM).

.PARAMETER SkipNetworkBootstrap
    Skip the DHCP/static address bootstrap.

.NOTES
    Version: see src/lib/Beacon.Version.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$SkipNetworkBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:ScriptRoot = $PSScriptRoot
. (Join-Path $script:ScriptRoot 'lib\Beacon.Version.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Common.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Results.ps1')

$script:BootstrapScript = Join-Path $script:ScriptRoot 'Start-NetworkBootstrap.ps1'
$script:ValidationScript = Join-Path $script:ScriptRoot 'Start-AzlValidation.ps1'
$script:Pwsh7Path = 'X:\Tools\PowerShell7\pwsh.exe'
$script:ConfigFile = Join-Path $script:ScriptRoot 'config\validation-config.json'
$script:ResultsDir = 'X:\results'

#region ---- pure helpers (unit tested) ----

function Test-YesAnswer {
    param([string]$Answer)
    return ("$Answer".Trim() -match '^(y|yes)$')
}

function Split-InputList {
    <# 'a, b,,c' -> @('a','b','c') #>
    param([string]$Text)
    return @("$Text" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-BannerLines {
    param([string]$Version = $script:BeaconVersion, [string]$Brand = '')
    $lines = @(
        '',
        '   ____  _____    _    ____ ___  _   _ ',
        '  | __ )| ____|  / \  / ___/ _ \| \ | |',
        '  |  _ \|  _|   / _ \| |  | | | |  \| |',
        '  | |_) | |___ / ___ \ |__| |_| | |\  |',
        '  |____/|_____/_/   \_\____\___/|_| \_|',
        '',
        '    Azure Local Pre-Deployment Validation',
        "    v$Version  |  Azure Local $script:BeaconReleaseTrain"
    )
    if ($Brand) { $lines += "    $Brand" }
    $lines += @('', '    Pre-deployment endpoint, network and Arc readiness', '    validation for Azure Local.', '')
    return $lines
}

function Get-MainMenuLines {
    return @(
        '  +-----------------------------------------------------+',
        '  |  Validation Menu                                    |',
        '  +-----------------------------------------------------+',
        '  |  1)  Active Directory deployment                    |',
        '  |  2)  Local Identity (AD-less) deployment            |',
        '  |  3)  Networking and Firewall                        |',
        '  |  4)  Full readiness sweep (all 6 categories)        |',
        '  |  5)  Arc readiness (Azure sign-in)                  |',
        '  +-----------------------------------------------------+',
        '  |  6)  Network settings (re-run bootstrap)            |',
        '  |  7)  Open PowerShell console                        |',
        '  |  8)  Export results (USB / SMB / HTTPS)             |',
        '  |  9)  Region, proxy and Arc gateway settings         |',
        '  |  0)  Exit to command prompt                         |',
        '  +-----------------------------------------------------+'
    )
}

function Get-EngineArguments {
    <# Argument list for the validation engine. Pure. #>
    param([string]$ScriptPath, [string[]]$Categories = @(), [switch]$SkipEnvironmentChecker, [switch]$Redact)
    $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    if ($Categories -and $Categories.Count -gt 0) { $a += @('-Categories', ($Categories -join ',')) }
    if ($SkipEnvironmentChecker) { $a += '-SkipEnvironmentChecker' }
    if ($Redact) { $a += '-Redact' }
    return $a
}

function Get-SweepCategories {
    <# Full sweep: A = Active Directory (1-6), L = Local Identity (1,2,4,5,6; no AD ports). #>
    param([string]$PathChoice)
    if ("$PathChoice".Trim() -match '^(l|L)$') { return @('1', '2', '4', '5', '6') }
    return @('1', '2', '3', '4', '5', '6')
}

function Resolve-MenuChoice {
    <# Returns the menu key for the entered text, or '' when invalid. #>
    param([string]$Choice)
    $c = "$Choice".Trim()
    if ($c -match '^[0-9]$') { return $c }
    return ''
}

function Set-ArcEnvironment {
    <# Process-scope environment only. Returns the names set, for Clear-ArcEnvironment. #>
    param([string]$Subscription, [string]$Tenant, [string]$ResourceGroup, [string[]]$Nodes)
    $env:BEACON_ARC_SUBSCRIPTION = $Subscription
    $env:BEACON_ARC_TENANT = $Tenant
    $env:BEACON_ARC_RG = $ResourceGroup
    $env:BEACON_ARC_NODES = ($Nodes -join ',')
}

function Clear-ArcEnvironment {
    foreach ($n in @('BEACON_ARC_SUBSCRIPTION', 'BEACON_ARC_TENANT', 'BEACON_ARC_RG', 'BEACON_ARC_NODES')) {
        Remove-Item "Env:$n" -ErrorAction SilentlyContinue
    }
}

#endregion

#region ---- console helpers ----

function Write-BeaconLine {
    param([string]$Message = '', [System.ConsoleColor]$Color = [System.ConsoleColor]::White)
    Write-Host $Message -ForegroundColor $Color
}

function Write-BeaconHeader {
    param([string]$Title)
    Write-BeaconLine ''
    Write-BeaconLine ('=' * 62) -Color Cyan
    Write-BeaconLine "  $Title" -Color Cyan
    Write-BeaconLine ('=' * 62) -Color Cyan
    Write-BeaconLine ''
}

function Read-MenuInput {
    param([string]$Prompt = 'Select')
    $response = Read-Host "  $Prompt"
    return "$response".Trim()
}

function Read-RequiredInput {
    param([string]$Label, [string]$Default = '')
    do {
        if ($Default) {
            $v = Read-Host "  $Label [$Default]"
            if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        } else {
            $v = Read-Host "  $Label"
        }
        $v = "$v".Trim()
    } while ([string]::IsNullOrWhiteSpace($v))
    return $v
}

function Read-OptionalInput {
    param([string]$Label, [string]$Default = '')
    if ($Default) {
        $v = Read-Host "  $Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
    } else {
        $v = Read-Host "  $Label (optional, Enter to skip)"
    }
    return "$v".Trim()
}

function Show-Banner {
    Clear-Host
    $brand = ''
    if (Test-Path $script:ConfigFile) {
        try {
            $c = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
            if ($c.PSObject.Properties.Name -contains 'brand') { $brand = "$($c.brand)" }
        } catch { Write-Verbose 'brand not read' }
    }
    $lines = Get-BannerLines -Brand $brand
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $col = [System.ConsoleColor]::DarkGray
        if ($i -ge 1 -and $i -le 5) { $col = [System.ConsoleColor]::Cyan }
        elseif ($i -eq 7) { $col = [System.ConsoleColor]::White }
        Write-BeaconLine $lines[$i] -Color $col
    }
}

#endregion

#region ---- engine and config ----

function Invoke-ValidationEngine {
    param([string[]]$Categories, [switch]$SkipEnvironmentChecker)
    $engineArgs = Get-EngineArguments -ScriptPath $script:ValidationScript -Categories $Categories -SkipEnvironmentChecker:$SkipEnvironmentChecker
    # Prefer PowerShell 7 bundled in the image; fall back to the built-in 5.1.
    if (Test-Path $script:Pwsh7Path) {
        & $script:Pwsh7Path @engineArgs
    } else {
        & powershell.exe @engineArgs
    }
}

function Write-ValidationConfigOverrides {
    param([hashtable]$Overrides)
    if (-not (Test-Path $script:ConfigFile)) {
        Write-BeaconLine "  [WARN] Config file not found: $($script:ConfigFile) - your inputs will NOT be applied." -Color Yellow
        return
    }
    try {
        $cfg = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
        foreach ($key in $Overrides.Keys) {
            $cfg | Add-Member -MemberType NoteProperty -Name $key -Value $Overrides[$key] -Force
        }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $script:ConfigFile -Encoding UTF8
    } catch {
        Write-BeaconLine "  [WARN] Could not update config: $($_.Exception.Message)" -Color Yellow
    }
}

function Invoke-PostRunPrompt {
    Write-BeaconLine ''
    Write-BeaconLine '  Press Enter to return to the main menu...' -Color DarkGray
    $null = Read-Host
}

function Invoke-OptionalArcCheck {
    $runArc = Read-MenuInput 'Run optional Arc readiness check? Requires Azure sign-in. (y/N)'
    if (Test-YesAnswer $runArc) { Invoke-ArcValidation }
}

#endregion

#region ---- menu paths ----

function Invoke-ADMenu {
    Write-BeaconHeader 'Active Directory Deployment Validation'
    Write-BeaconLine '  This path validates readiness for an AD-joined Azure Local deployment.' -Color White
    Write-BeaconLine '  You will be prompted for domain and DC details.' -Color DarkGray
    Write-BeaconLine ''

    $domainFqdn = Read-RequiredInput 'Active Directory domain FQDN (e.g. corp.contoso.com)'
    $dcIps = Split-InputList (Read-RequiredInput 'Domain controller IP(s) - comma-separated if multiple')
    $ouDn = Read-OptionalInput 'Target OU Distinguished Name (e.g. OU=AzureLocal,DC=corp,DC=contoso,DC=com)'
    $deployPrefix = Read-OptionalInput 'Deployment prefix (up to 8 chars)' -Default 'azl'
    Write-BeaconLine ''
    Write-BeaconLine '  Configuration collected. Updating validation config...' -Color Cyan

    $overrides = @{ adDomainFqdn = $domainFqdn; dcIps = $dcIps; deploymentPrefix = $deployPrefix }
    if ($ouDn) { $overrides['adOuDn'] = $ouDn }
    Write-ValidationConfigOverrides -Overrides $overrides

    Write-BeaconLine '  Running Active Directory validation (Categories 1-5)...' -Color Cyan
    Write-BeaconLine ''
    # 1=Network+time, 2=DNS, 3=AD ports, 4=Endpoint sweep, 5=Environment Checker, 6=Arc (optional, asked below)
    Invoke-ValidationEngine -Categories @('1', '2', '3', '4', '5')

    Write-BeaconLine ''
    Write-BeaconLine "  AD validation complete. Results in $script:ResultsDir\" -Color Green
    Invoke-OptionalArcCheck
    Invoke-PostRunPrompt
}

function Invoke-LocalIdentityMenu {
    Write-BeaconHeader 'Local Identity (AD-less) Deployment Validation'
    Write-BeaconLine '  This path validates readiness for an AD-less Azure Local deployment.' -Color White
    Write-BeaconLine '  Nodes use local admin + Azure Key Vault (no Active Directory required).' -Color DarkGray
    Write-BeaconLine ''
    Write-BeaconLine '  NOTE: Local Identity deployments require STATIC IP addresses.' -Color Yellow
    Write-BeaconLine '        DHCP is not supported for cluster nodes in this mode.' -Color Yellow
    Write-BeaconLine ''

    $dnsServers = Split-InputList (Read-RequiredInput 'DNS server IP(s) - comma-separated')
    $kvFqdn = Read-OptionalInput 'Azure Key Vault FQDN (e.g. kv-example-01.vault.azure.net)'
    Write-BeaconLine ''
    Write-BeaconLine '  Running Local Identity validation (Categories 1, 2, 4, 5)...' -Color Cyan
    Write-BeaconLine '  Skipping AD port tests (Category 3) - not needed for Local Identity.' -Color DarkGray
    Write-BeaconLine ''

    # adDomainFqdn blank suppresses the AD domain lookup in Category 2; the Key Vault name feeds the sweep.
    Write-ValidationConfigOverrides -Overrides @{ dnsServers = $dnsServers; adDomainFqdn = ''; keyVaultFqdn = $kvFqdn }
    Invoke-ValidationEngine -Categories @('1', '2', '4', '5')

    Write-BeaconLine ''
    Write-BeaconLine "  Local Identity validation complete. Results in $script:ResultsDir\" -Color Green
    Invoke-OptionalArcCheck
    Invoke-PostRunPrompt
}

function Invoke-NetworkFirewallMenu {
    param([hashtable]$NetworkState = @{})
    Write-BeaconHeader 'Networking and Firewall Validation'
    Write-BeaconLine '  Validates the physical network, endpoint reachability for your region' -Color White
    Write-BeaconLine '  (Azure Local + Arc + OEM), DNS, NTP and the Microsoft Environment Checker.' -Color White
    Write-BeaconLine ''

    $gwIp = ''
    if ($NetworkState.ContainsKey('GatewayIp') -and $NetworkState.GatewayIp) { $gwIp = $NetworkState.GatewayIp }
    $dnsIp = ''
    if ($NetworkState.ContainsKey('DnsServer') -and $NetworkState.DnsServer) { $dnsIp = $NetworkState.DnsServer }

    if ($gwIp) { Write-BeaconLine "  Gateway : $gwIp  (from bootstrap)" -Color DarkGray }
    else { $gwIp = Read-OptionalInput 'Management gateway IP (leave blank to skip)' }

    $dnsServers = @()
    if ($dnsIp) {
        Write-BeaconLine "  DNS     : $dnsIp  (from bootstrap)" -Color DarkGray
        $dnsServers = @($dnsIp)
    } else {
        $dnsServers = Split-InputList (Read-OptionalInput 'DNS server IP(s) - comma-separated (leave blank to skip)')
    }
    Write-BeaconLine ''

    $overrides = @{}
    if ($gwIp) { $overrides['managementGateway'] = $gwIp }
    if ($dnsServers.Count -gt 0) { $overrides['dnsServers'] = $dnsServers }
    if ($overrides.Count -gt 0) { Write-ValidationConfigOverrides -Overrides $overrides }

    Write-BeaconLine '  Running Networking/Firewall validation (Categories 1, 2, 4, 5)...' -Color Cyan
    Write-BeaconLine '  (Category 3 AD ports is not part of a network-focused run.)' -Color DarkGray
    Write-BeaconLine ''
    Invoke-ValidationEngine -Categories @('1', '2', '4', '5')

    Write-BeaconLine ''
    Write-BeaconLine "  Networking and Firewall validation complete. Results in $script:ResultsDir\" -Color Green
    Invoke-OptionalArcCheck
    Invoke-PostRunPrompt
}

function Invoke-ArcValidation {
    Write-BeaconLine ''
    Write-BeaconLine '  -- Arc Readiness Check --' -Color Cyan
    Write-BeaconLine '  Requires: Azure subscription ID, resource group, node host names.' -Color DarkGray
    Write-BeaconLine '  A device-code URL and code appear; sign in on any other device.' -Color DarkGray
    Write-BeaconLine '  Nothing you enter here, and no token, is written to disk.' -Color DarkGray
    Write-BeaconLine ''

    $subId = Read-RequiredInput 'Azure Subscription ID'
    $tenant = Read-OptionalInput 'Tenant ID or domain (Enter = organizations)'
    $rgName = Read-RequiredInput 'Arc resource group name'
    $nodes = Split-InputList (Read-RequiredInput 'Node hostnames - comma-separated')

    try {
        Set-ArcEnvironment -Subscription $subId -Tenant $tenant -ResourceGroup $rgName -Nodes $nodes
        Invoke-ValidationEngine -Categories @('6')
    } finally {
        Clear-ArcEnvironment
    }
}

function Invoke-FullSweep {
    Write-BeaconHeader 'Full Readiness Sweep - All 6 Categories'
    Write-BeaconLine '  Runs all 6 validation categories including the Microsoft Environment Checker.' -Color White
    Write-BeaconLine '  Choose the deployment path to include the correct identity tests:' -Color DarkGray
    Write-BeaconLine ''
    Write-BeaconLine '    A) Active Directory (includes Category 3 AD port tests)' -Color White
    Write-BeaconLine '    L) Local Identity - AD-less (skips Category 3)' -Color White
    Write-BeaconLine ''

    $pathChoice = Read-MenuInput 'Path (A/L)'
    $sweepCategories = Get-SweepCategories -PathChoice $pathChoice
    Write-BeaconLine ''
    if ($sweepCategories -contains '3') {
        Write-BeaconLine '  Running full sweep - Active Directory path (all categories)...' -Color Cyan
    } else {
        Write-BeaconLine '  Running full sweep - Local Identity path (skipping AD port tests)...' -Color Cyan
    }
    Write-BeaconLine '  Category 6 asks for a subscription; with none it is skipped.' -Color DarkGray

    $runArc = Read-MenuInput 'Include Arc readiness (needs Azure sign-in)? (y/N)'
    if (Test-YesAnswer $runArc) {
        $sweepCategories = @($sweepCategories | Where-Object { $_ -ne '6' })
        Invoke-ValidationEngine -Categories $sweepCategories
        Invoke-ArcValidation
    } else {
        Invoke-ValidationEngine -Categories @($sweepCategories | Where-Object { $_ -ne '6' })
    }

    Write-BeaconLine ''
    Write-BeaconLine "  Full sweep complete. Results in $script:ResultsDir\" -Color Green
    Invoke-PostRunPrompt
}

function Invoke-SettingsMenu {
    Write-BeaconHeader 'Region, Proxy and Arc Gateway'
    Write-BeaconLine '  Regions: eastus, westeurope, australiaeast, canadacentral, centralindia,' -Color DarkGray
    Write-BeaconLine '           southeastasia, japaneast, southcentralus, usgovvirginia' -Color DarkGray
    Write-BeaconLine ''
    $region = Read-OptionalInput 'Azure region'
    $proxy = Read-OptionalInput 'Proxy URL (e.g. http://proxy.example.com:8080)'
    $bypass = ''
    if ($proxy) { $bypass = Read-OptionalInput 'Proxy bypass list, comma-separated (e.g. localhost,*.corp.example.com,10.0.0.0/8)' }
    $gateway = Read-OptionalInput 'Arc gateway FQDN (<id>.gw.arc.azure.com)'
    $oem = Read-OptionalInput 'OEM endpoint list (dell, or blank for none)'
    $ntp = Read-OptionalInput 'NTP server(s), comma-separated (blank = domain controllers, else time.windows.com)'

    $o = @{}
    if ($region) { $o['azureRegion'] = $region }
    $o['proxyUrl'] = $proxy
    $o['proxyBypass'] = Split-InputList $bypass
    $o['arcGatewayFqdn'] = $gateway
    $o['oem'] = $oem
    $o['ntpServers'] = Split-InputList $ntp
    Write-ValidationConfigOverrides -Overrides $o
    Write-BeaconLine '  Saved for this session (RAM drive only).' -Color Green
    Invoke-PostRunPrompt
}

function Get-LatestResultFile {
    param([string]$Directory = $script:ResultsDir)
    if (-not (Test-Path $Directory)) { return $null }
    return (Get-ChildItem -Path $Directory -Filter 'validation-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '-redacted\.json$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Invoke-ExportMenu {
    Write-BeaconHeader 'Export Results'
    $latest = Get-LatestResultFile
    if (-not $latest) {
        Write-BeaconLine "  No results found in $script:ResultsDir. Run a validation first." -Color Yellow
        Invoke-PostRunPrompt
        return
    }
    Write-BeaconLine "  Latest : $($latest.Name)" -Color White
    Write-BeaconLine '  NOTE: results contain IP addresses, DC/host names, the domain and the node serial number.' -Color Yellow
    Write-BeaconLine ''
    $redact = Test-YesAnswer (Read-MenuInput 'Redact identifying values before export? (y/N)')
    Write-BeaconLine '  Target examples:  E   (USB drive letter)    \\server\share    https://example.com/beacon' -Color DarkGray
    $target = Read-RequiredInput 'Export target'

    $files = @{ Json = $latest.FullName; Log = [IO.Path]::ChangeExtension($latest.FullName, '.log'); Html = [IO.Path]::ChangeExtension($latest.FullName, '.html') }
    if ($redact) {
        $doc = Get-Content $latest.FullName -Raw | ConvertFrom-Json
        $cfg = $null
        if (Test-Path $script:ConfigFile) { $cfg = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json }
        $red = Invoke-BeaconRedaction -Document $doc -Map (Get-RedactionMap -Config $cfg -Node $doc.node)
        $files = Save-BeaconResults -Document $red -Directory $script:ResultsDir -Suffix '-redacted'
    }
    $cred = $null
    if ((Resolve-ExportTarget -Target $target).Kind -eq 'Smb') {
        if (Test-YesAnswer (Read-MenuInput 'Does the share need credentials? (y/N)')) { $cred = Get-Credential }
    }
    $r = Export-BeaconResults -Files $files -Target $target -Credential $cred
    $color = [System.ConsoleColor]::Red
    if ($r.Ok) { $color = [System.ConsoleColor]::Green }
    Write-BeaconLine "  $($r.Kind): $($r.Detail)" -Color $color
    Invoke-PostRunPrompt
}

#endregion

#region ---- main menu ----

function Get-EmptyNetworkState {
    return @{ IpAddress = ''; Configured = $false; DhcpAcquired = $false; StaticApplied = $false; GatewayOk = $false; DnsOk = $false; HttpsOk = $false; GatewayIp = ''; DnsServer = ''; AdapterName = '' }
}

function Invoke-NetworkBootstrap {
    $state = & $script:BootstrapScript
    if ($null -eq $state -or $state -isnot [hashtable]) { return (Get-EmptyNetworkState) }
    return $state
}

function Show-MainMenu {
    param([hashtable]$NetworkState)
    Show-Banner
    if ($NetworkState.Configured) {
        $dhcpTag = ''
        if ($NetworkState.DhcpAcquired) { $dhcpTag = '  (DHCP)' } elseif ($NetworkState.StaticApplied) { $dhcpTag = '  (Static)' }
        Write-BeaconLine '  Network Status:' -Color Cyan
        Write-BeaconLine "    IP    : $($NetworkState.IpAddress)$dhcpTag" -Color Green
        if ($NetworkState.AdapterName) { Write-BeaconLine "    NIC   : $($NetworkState.AdapterName)" -Color White }
        foreach ($row in @(@('GW   ', 'GatewayIp', 'GatewayOk'), @('DNS  ', 'DnsServer', 'DnsOk'))) {
            if ($NetworkState[$row[1]]) {
                $ok = [bool]$NetworkState[$row[2]]
                $tag = '[WARN]'; $col = [System.ConsoleColor]::Yellow
                if ($ok) { $tag = '[OK]  '; $col = [System.ConsoleColor]::Green }
                Write-BeaconLine "    $($row[0]) : $($NetworkState[$row[1]])  $tag" -Color $col
            }
        }
        $httpsTag = '[WARN]'; $httpsCol = [System.ConsoleColor]::Yellow
        if ($NetworkState.HttpsOk) { $httpsTag = '[OK]  '; $httpsCol = [System.ConsoleColor]::Green }
        Write-BeaconLine "    HTTPS : login.microsoftonline.com:443  $httpsTag" -Color $httpsCol
    } else {
        Write-BeaconLine '  Network Status:  NOT CONFIGURED' -Color Red
        Write-BeaconLine '  Use option 6 to configure network settings.' -Color Yellow
    }
    Write-BeaconLine ''
    $menu = Get-MainMenuLines
    for ($i = 0; $i -lt $menu.Count; $i++) {
        $col = [System.ConsoleColor]::White
        if ($menu[$i] -match '^\s+\+--') { $col = [System.ConsoleColor]::Cyan }
        elseif ($menu[$i] -match '\|\s+(6|7|8|9|0)\)') { $col = [System.ConsoleColor]::DarkGray }
        Write-BeaconLine $menu[$i] -Color $col
    }
    Write-BeaconLine ''
}

function Start-BeaconMenuLoop {
    param([hashtable]$NetworkState)
    $running = $true
    while ($running) {
        Show-MainMenu -NetworkState $NetworkState
        $choice = Resolve-MenuChoice (Read-MenuInput 'Enter choice')
        switch ($choice) {
            '1' { Invoke-ADMenu }
            '2' { Invoke-LocalIdentityMenu }
            '3' { Invoke-NetworkFirewallMenu -NetworkState $NetworkState }
            '4' { Invoke-FullSweep }
            '5' { Invoke-ArcValidation; Invoke-PostRunPrompt }
            '6' {
                if (Test-Path $script:BootstrapScript) {
                    Write-BeaconLine '  Re-running network bootstrap...' -Color Cyan
                    $NetworkState = Invoke-NetworkBootstrap
                } else {
                    Write-BeaconLine "  Bootstrap script not found: $($script:BootstrapScript)" -Color Red
                    Invoke-PostRunPrompt
                }
            }
            '7' { Start-Process -FilePath 'powershell.exe' }
            '8' { Invoke-ExportMenu }
            '9' { Invoke-SettingsMenu }
            '0' {
                Write-BeaconLine ''
                Write-BeaconLine "  Exiting to command prompt. Results are in $script:ResultsDir\" -Color White
                Write-BeaconLine '  DO NOT reboot unless you intend to exit this session.' -Color Yellow
                Write-BeaconLine ''
                $running = $false
            }
            default {
                Write-BeaconLine '  Invalid choice. Enter 0-9.' -Color Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

#endregion

# Dot-sourcing (Pester) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

Show-Banner
$networkState = Get-EmptyNetworkState
if (-not $SkipNetworkBootstrap -and (Test-Path $script:BootstrapScript)) {
    Write-BeaconLine '  Initializing network bootstrap...' -Color Cyan
    $networkState = Invoke-NetworkBootstrap
} elseif (-not $SkipNetworkBootstrap) {
    Write-BeaconLine "  [WARN] Bootstrap script not found: $($script:BootstrapScript)" -Color Yellow
    Write-BeaconLine '  Continuing without network initialization.' -Color Yellow
}
Start-BeaconMenuLoop -NetworkState $networkState
