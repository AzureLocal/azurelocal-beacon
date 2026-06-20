#Requires -Version 5.1
<#
.SYNOPSIS
    AzL Beacon — interactive boot orchestrator for Azure Local pre-deployment validation.

.DESCRIPTION
    Entry point invoked by startnet.cmd at WinPE boot. Runs the network bootstrap,
    then presents a split menu allowing the operator to choose which deployment path
    to validate:

      1) Active Directory deployment
      2) Local Identity (AD-less) deployment
      3) Networking and Firewall
      4) Full readiness sweep (all categories)
      5) Network settings (re-run bootstrap)
      0) Exit to command prompt

    Each menu path collects the inputs it needs, then calls the validation engine
    (Start-AzlValidation.ps1) with appropriate -Categories parameters.

    Compatible with PowerShell 5.1 (WinPE) and PowerShell 7. No PS7-only syntax used.

.NOTES
    Author:       Kristopher Turner
    Contact:      kris@hybridsolutions.cloud
    Version:      1.0.0
    LastUpdated:  2026-06-19
    ScriptVersion = "1.0.0"
    TaskReference = "azurelocal-beacon/phase-4-interactive-menu"
    DocumentationRef = "docs/validation/index.md"
    ChangeLog     = @(
        "1.0.0 - 2026-06-19 - Initial implementation with split menu and three validation paths"
    )
    Compatibility: PowerShell 5.1 (WinPE) and PowerShell 7. No PS7-only syntax.
    PSScriptAnalyzer: passes at Warning/Error severity.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$SkipNetworkBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# Script locations — resolve relative to this script
# ============================================================
$scriptDir      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.ScriptName -Parent }
$bootstrapScript = Join-Path $scriptDir 'Start-NetworkBootstrap.ps1'
$validationScript = Join-Path $scriptDir 'Start-AzlValidation.ps1'

# WinPE image paths (fallback when script is running from X:\Tools)
if (-not (Test-Path $bootstrapScript)) {
    $bootstrapScript = 'X:\Tools\Start-NetworkBootstrap.ps1'
}
if (-not (Test-Path $validationScript)) {
    $validationScript = 'X:\Tools\Start-AzlValidation.ps1'
}

# ============================================================
# Console helper
# ============================================================
function Write-BeaconLine {
    param(
        [string]$Message = '',
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    $old = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $Color
    Write-Output $Message
    $Host.UI.RawUI.ForegroundColor = $old
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
    return $response.Trim()
}

function Prompt-Required {
    param([string]$Label, [string]$Default = '')
    do {
        if ($Default) {
            $v = Read-Host "  $Label [$Default]"
            if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        } else {
            $v = Read-Host "  $Label"
        }
        $v = $v.Trim()
    } while ([string]::IsNullOrWhiteSpace($v))
    return $v
}

function Prompt-Optional {
    param([string]$Label, [string]$Default = '')
    if ($Default) {
        $v = Read-Host "  $Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
    } else {
        $v = Read-Host "  $Label (optional, Enter to skip)"
    }
    return $v.Trim()
}

# ============================================================
# Banner
# ============================================================
function Show-Banner {
    Clear-Host
    Write-BeaconLine ''
    Write-BeaconLine '  ██████╗ ███████╗ █████╗  ██████╗ ██████╗ ███╗   ██╗' -Color Cyan
    Write-BeaconLine '  ██╔══██╗██╔════╝██╔══██╗██╔════╝██╔═══██╗████╗  ██║' -Color Cyan
    Write-BeaconLine '  ██████╔╝█████╗  ███████║██║     ██║   ██║██╔██╗ ██║' -Color Cyan
    Write-BeaconLine '  ██╔══██╗██╔══╝  ██╔══██║██║     ██║   ██║██║╚██╗██║' -Color Cyan
    Write-BeaconLine '  ██████╔╝███████╗██║  ██║╚██████╗╚██████╔╝██║ ╚████║' -Color Cyan
    Write-BeaconLine '  ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝' -Color Cyan
    Write-BeaconLine ''
    Write-BeaconLine '    Azure Local Pre-Deployment Validation' -Color White
    Write-BeaconLine '    v1.0.0-pre  |  Dell AX 16G  |  HCS Platform' -Color DarkGray
    Write-BeaconLine ''
    Write-BeaconLine '    Pre-deployment endpoint and network' -Color DarkGray
    Write-BeaconLine '    readiness validation for Azure Local.' -Color DarkGray
    Write-BeaconLine ''
}

# ============================================================
# Invoke the validation engine
# ============================================================
function Invoke-ValidationEngine {
    param(
        [string[]]$Categories,
        [switch]$SkipEnvironmentChecker
    )

    $args = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
              '-File', $validationScript)
    if ($Categories -and $Categories.Count -gt 0) {
        $args += @('-Categories', ($Categories -join ','))
    }
    if ($SkipEnvironmentChecker) {
        $args += '-SkipEnvironmentChecker'
    }

    # Try PS7 bundled in the image, fall back to built-in PS5.1
    $ps7 = 'X:\Tools\PowerShell7\pwsh.exe'
    if (Test-Path $ps7) {
        & $ps7 @args
    } else {
        & powershell.exe @args
    }
}

# ============================================================
# Inject runtime config overrides into the config file
# used by the validation engine
# ============================================================
function Write-ValidationConfigOverrides {
    param([hashtable]$Overrides)
    $configDir = 'X:\Tools\config'
    $configFile = Join-Path $configDir 'validation-config.json'
    if (-not (Test-Path $configFile)) { return }
    try {
        $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
        foreach ($key in $Overrides.Keys) {
            $cfg | Add-Member -MemberType NoteProperty -Name $key -Value $Overrides[$key] -Force
        }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $configFile -Encoding UTF8
    } catch {
        Write-BeaconLine "  [WARN] Could not update config: $($_.Exception.Message)" -Color Yellow
    }
}

# ============================================================
# MENU PATHS
# ============================================================

#region  ── Active Directory Path ──

function Invoke-ADMenu {
    Write-BeaconHeader 'Active Directory Deployment Validation'
    Write-BeaconLine '  This path validates readiness for an AD-joined Azure Local deployment.' -Color White
    Write-BeaconLine '  You will be prompted for domain and DC details.' -Color DarkGray
    Write-BeaconLine ''

    $domainFqdn    = Prompt-Required 'Active Directory domain FQDN (e.g. corp.contoso.com)'
    Write-BeaconLine ''
    $dcIpRaw       = Prompt-Required 'Domain controller IP(s) — comma-separated if multiple'
    $dcIps         = @($dcIpRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    Write-BeaconLine ''
    $ouDn          = Prompt-Optional 'Target OU Distinguished Name (e.g. OU=AzureLocal,DC=corp,DC=contoso,DC=com)'
    $deployPrefix  = Prompt-Optional 'Deployment prefix (up to 8 chars)' -Default 'azl'
    Write-BeaconLine ''
    $ntpPrimary    = Prompt-Optional 'Primary NTP/time source IP or FQDN' -Default 'time.windows.com'

    Write-BeaconLine ''
    Write-BeaconLine '  Configuration collected. Updating validation config...' -Color Cyan

    $overrides = @{
        adDomainFqdn          = $domainFqdn
        dcIps                 = $dcIps
        deploymentPrefix      = $deployPrefix
    }
    if ($ouDn)      { $overrides['adOuDn']   = $ouDn }
    if ($ntpPrimary) {
        $overrides['ntpServers'] = @{ primary = $ntpPrimary; secondary = 'time.windows.com' }
    }
    Write-ValidationConfigOverrides -Overrides $overrides

    Write-BeaconLine ''
    Write-BeaconLine '  Running Active Directory validation (Categories 1-4 + Connectivity)...' -Color Cyan
    Write-BeaconLine ''

    # Categories: 1=Network, 2=DNS, 3=AD ports, 4=Endpoint sweep, 5=EnvChecker, 6=Arc(optional)
    Invoke-ValidationEngine -Categories @('1', '2', '3', '4', '5')

    Write-BeaconLine ''
    Write-BeaconLine '  AD validation complete. Results in X:\results\' -Color Green
    Invoke-PostRunPrompt
}

#endregion

#region  ── Local Identity (AD-less) Path ──

function Invoke-LocalIdentityMenu {
    Write-BeaconHeader 'Local Identity (AD-less) Deployment Validation'
    Write-BeaconLine '  This path validates readiness for an AD-less Azure Local deployment.' -Color White
    Write-BeaconLine '  Nodes use local admin + Azure Key Vault (no Active Directory required).' -Color DarkGray
    Write-BeaconLine ''
    Write-BeaconLine '  NOTE: Azure Local Local Identity deployments require STATIC IP addresses.' -Color Yellow
    Write-BeaconLine '        DHCP is not supported for cluster nodes in this mode.' -Color Yellow
    Write-BeaconLine ''

    $dnsRaw     = Prompt-Required 'DNS server IP(s) — comma-separated'
    $dnsServers = @($dnsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    Write-BeaconLine ''
    $kvFqdn     = Prompt-Optional 'Azure Key Vault FQDN (e.g. kv-beacon-01.vault.azure.net)' -Default ''
    Write-BeaconLine ''

    Write-BeaconLine '  Running Local Identity validation (Categories 1, 2, 4, 5)...' -Color Cyan
    Write-BeaconLine '  Skipping AD port tests (Category 3) — not needed for Local Identity.' -Color DarkGray
    Write-BeaconLine ''

    $overrides = @{
        dnsServers    = $dnsServers
        adDomainFqdn  = ''   # Not needed — suppresses DNS domain lookup in Cat-2
    }
    Write-ValidationConfigOverrides -Overrides $overrides

    # Categories: 1=Network, 2=DNS, 4=Endpoint sweep, 5=EnvChecker(connectivity+network), 6=Arc(optional)
    Invoke-ValidationEngine -Categories @('1', '2', '4', '5')

    # Key Vault endpoint check — manual TCP probe if FQDN provided
    if ($kvFqdn) {
        Write-BeaconLine ''
        Write-BeaconLine "  Probing Key Vault endpoint: $kvFqdn`:443" -Color Cyan
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $ar     = $client.BeginConnect($kvFqdn, 443, $null, $null)
            $ok     = $ar.AsyncWaitHandle.WaitOne(8000, $false)
            if ($ok) { $client.EndConnect($ar) }
            $client.Close()
            $color  = if ($ok) { [System.ConsoleColor]::Green  } else { [System.ConsoleColor]::Red }
            $label  = if ($ok) { '[PASS] Key Vault TCP 443 reachable' } else { '[FAIL] Key Vault TCP 443 blocked — deployment will fail' }
            Write-BeaconLine "  $label" -Color $color
        } catch {
            Write-BeaconLine "  [FAIL] Key Vault probe error: $($_.Exception.Message)" -Color Red
        }
    }

    # Arc validation (optional)
    Write-BeaconLine ''
    $runArc = Read-MenuInput 'Run optional Arc integration readiness check? Requires Azure sign-in. (y/N)'
    if ($runArc -eq 'y' -or $runArc -eq 'Y') {
        Invoke-ArcValidation
    }

    Write-BeaconLine ''
    Write-BeaconLine '  Local Identity validation complete. Results in X:\results\' -Color Green
    Invoke-PostRunPrompt
}

#endregion

#region  ── Networking & Firewall Path ──

function Invoke-NetworkFirewallMenu {
    Write-BeaconHeader 'Networking and Firewall Validation'
    Write-BeaconLine '  Validates physical network, endpoint reachability (Azure Local + Arc + Dell),' -Color White
    Write-BeaconLine '  DNS, NTP, and the Microsoft Environment Checker.' -Color White
    Write-BeaconLine ''

    $gwIp       = Prompt-Optional 'Management gateway IP (leave blank to use DHCP-detected)'
    $dnsRaw     = Prompt-Optional 'DNS server IP(s) — comma-separated (leave blank to use current)'
    $dnsServers = if ($dnsRaw) { @($dnsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) } else { @() }
    Write-BeaconLine ''

    $overrides = @{}
    if ($gwIp)                    { $overrides['managementGateway'] = $gwIp }
    if ($dnsServers.Count -gt 0)  { $overrides['dnsServers']        = $dnsServers }
    if ($overrides.Count -gt 0) { Write-ValidationConfigOverrides -Overrides $overrides }

    Write-BeaconLine '  Running Networking/Firewall validation (Categories 1, 2, 4, 5)...' -Color Cyan
    Write-BeaconLine ''

    # All categories except Cat-3 (AD ports — not relevant for a network-focused run)
    Invoke-ValidationEngine -Categories @('1', '2', '4', '5')

    Write-BeaconLine ''
    Write-BeaconLine '  Networking and Firewall validation complete. Results in X:\results\' -Color Green
    Invoke-PostRunPrompt
}

#endregion

#region  ── Arc Validation (optional, called from AD and Local Identity paths) ──

function Invoke-ArcValidation {
    Write-BeaconLine ''
    Write-BeaconLine '  ── Arc Integration Check ──' -Color Cyan
    Write-BeaconLine '  Requires: Azure subscription ID, resource group, node names.' -Color DarkGray
    Write-BeaconLine '  A device-code sign-in URL will appear — enter the code on any browser.' -Color DarkGray
    Write-BeaconLine ''

    $subId    = Prompt-Required 'Azure Subscription ID'
    $rgName   = Prompt-Required 'Arc resource group name'
    $nodesRaw = Prompt-Required 'Node hostnames — comma-separated'
    $nodes    = @($nodesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

    $ps7 = 'X:\Tools\PowerShell7\pwsh.exe'
    $psExe = if (Test-Path $ps7) { $ps7 } else { 'powershell.exe' }

    $arcScript = @"
Import-Module AzStackHci.EnvironmentChecker -ErrorAction SilentlyContinue
Connect-AzAccount -Tenant (Read-Host 'Tenant ID (or press Enter to skip)') -Subscription '$subId' -DeviceCode -ErrorAction SilentlyContinue
Invoke-AzStackHciArcIntegrationValidation ``
    -SubscriptionID '$subId' ``
    -RegistrationResourceGroupName '$rgName' ``
    -ArcResourceGroupName '$rgName' ``
    -NodeNames @($( ($nodes | ForEach-Object { "'$_'" }) -join ',' ))
"@

    $tmpScript = Join-Path $env:TEMP 'arc-validate.ps1'
    $arcScript | Set-Content $tmpScript -Encoding UTF8
    & $psExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmpScript
    Remove-Item $tmpScript -ErrorAction SilentlyContinue
}

#endregion

#region  ── Full Sweep ──

function Invoke-FullSweep {
    Write-BeaconHeader 'Full Readiness Sweep — All 6 Categories'
    Write-BeaconLine '  Runs all 6 validation categories including the Microsoft Environment Checker.' -Color White
    Write-BeaconLine '  Choose deployment path to include the correct identity tests:' -Color DarkGray
    Write-BeaconLine ''
    Write-BeaconLine '    A) Active Directory (includes Category 4 AD port tests)' -Color White
    Write-BeaconLine '    L) Local Identity — AD-less (skips Category 4)' -Color White
    Write-BeaconLine ''

    $pathChoice = Read-MenuInput 'Path (A/L)'
    Write-BeaconLine ''

    $sweepCategories = if ($pathChoice -eq 'L' -or $pathChoice -eq 'l') {
        Write-BeaconLine '  Running full sweep — Local Identity path (skipping AD port tests)...' -Color Cyan
        @('1', '2', '4', '5', '6')
    } else {
        Write-BeaconLine '  Running full sweep — Active Directory path (all categories)...' -Color Cyan
        @('1', '2', '3', '4', '5', '6')
    }

    Write-BeaconLine ''
    Invoke-ValidationEngine -Categories $sweepCategories

    Write-BeaconLine ''
    Write-BeaconLine '  Full sweep complete. Results in X:\results\' -Color Green
    Invoke-PostRunPrompt
}

#endregion

# ============================================================
# Post-run prompt
# ============================================================
function Invoke-PostRunPrompt {
    Write-BeaconLine ''
    Write-BeaconLine '  Press Enter to return to the main menu...' -Color DarkGray
    $null = Read-Host
}

# ============================================================
# Main menu
# ============================================================
function Show-MainMenu {
    param([hashtable]$NetworkState)

    $networkLabel = if ($networkState.Configured) {
        "$($networkState.IpAddress)"
    } else {
        'NOT CONFIGURED'
    }
    $networkColor = if ($networkState.Configured) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Red }

    Show-Banner
    Write-BeaconLine "  Network : " -Color White
    Write-BeaconLine "  $networkLabel" -Color $networkColor
    Write-BeaconLine ''
    Write-BeaconLine '  ┌─────────────────────────────────────────────────────┐' -Color Cyan
    Write-BeaconLine '  │  Validation Menu                                    │' -Color Cyan
    Write-BeaconLine '  ├─────────────────────────────────────────────────────┤' -Color Cyan
    Write-BeaconLine '  │  1)  Active Directory deployment                    │' -Color White
    Write-BeaconLine '  │  2)  Local Identity (AD-less) deployment            │' -Color White
    Write-BeaconLine '  │  3)  Networking and Firewall                        │' -Color White
    Write-BeaconLine '  │  4)  Full readiness sweep                           │' -Color White
    Write-BeaconLine '  ├─────────────────────────────────────────────────────┤' -Color Cyan
    Write-BeaconLine '  │  5)  Network settings (re-run bootstrap)            │' -Color DarkGray
    Write-BeaconLine '  │  0)  Exit to command prompt                         │' -Color DarkGray
    Write-BeaconLine '  └─────────────────────────────────────────────────────┘' -Color Cyan
    Write-BeaconLine ''
}

# ============================================================
# Main execution loop
# ============================================================

Show-Banner

# Network bootstrap
$networkState = @{
    IpAddress    = ''
    Configured   = $false
    DhcpAcquired = $false
}

if (-not $SkipNetworkBootstrap -and (Test-Path $bootstrapScript)) {
    Write-BeaconLine '  Initializing network bootstrap...' -Color Cyan
    $networkState = & $bootstrapScript
    if ($null -eq $networkState) {
        $networkState = @{ IpAddress = ''; Configured = $false; DhcpAcquired = $false }
    }
} elseif (-not $SkipNetworkBootstrap) {
    Write-BeaconLine "  [WARN] Bootstrap script not found: $bootstrapScript" -Color Yellow
    Write-BeaconLine '  Continuing without network initialization.' -Color Yellow
}

$running = $true
while ($running) {
    Show-MainMenu -NetworkState $networkState

    $choice = Read-MenuInput 'Enter choice'

    switch ($choice) {
        '1' { Invoke-ADMenu }
        '2' { Invoke-LocalIdentityMenu }
        '3' { Invoke-NetworkFirewallMenu }
        '4' { Invoke-FullSweep }
        '5' {
            if (Test-Path $bootstrapScript) {
                Write-BeaconLine '  Re-running network bootstrap...' -Color Cyan
                $networkState = & $bootstrapScript
                if ($null -eq $networkState) {
                    $networkState = @{ IpAddress = ''; Configured = $false; DhcpAcquired = $false }
                }
            } else {
                Write-BeaconLine "  Bootstrap script not found: $bootstrapScript" -Color Red
                Invoke-PostRunPrompt
            }
        }
        '0' {
            Write-BeaconLine ''
            Write-BeaconLine '  Exiting to command prompt. Results are in X:\results\' -Color White
            Write-BeaconLine '  DO NOT reboot unless you intend to exit this session.' -Color Yellow
            Write-BeaconLine ''
            $running = $false
        }
        default {
            Write-BeaconLine "  Invalid choice: '$choice'. Enter 0-5." -Color Yellow
            & ping -n 2 127.0.0.1 | Out-Null
        }
    }
}
