#Requires -Version 5.1
<#
.SYNOPSIS
    WinPE network bootstrap: DHCP detection, static IP fallback, and connectivity verification.

.DESCRIPTION
    Run at boot before any validation. Attempts a DHCP lease (15-second wait), detects
    the first routable IPv4 address, and if none is found, interactively prompts the
    operator for IP / subnet mask / gateway / DNS and applies them via netsh.
    After network configuration, verifies gateway reachability, DNS resolution, and
    outbound HTTPS connectivity before returning.

    Returns a hashtable describing the current network state. Callers (Start-AzlBeacon.ps1)
    use this to confirm network readiness before presenting the validation menu.

    Compatible with PowerShell 5.1 (WinPE built-in) and PowerShell 7.

.PARAMETER DhcpWaitSeconds
    Number of seconds to wait for a DHCP lease before prompting for static IP.
    Default: 15.

.PARAMETER SkipVerification
    If set, skip the post-config gateway/DNS/HTTPS verification step. Useful for
    air-gapped test scenarios where the verification targets are not reachable.

.OUTPUTS
    Hashtable with keys:
      IpAddress      [string]  - configured IPv4 address, or empty string
      Configured     [bool]    - $true if any routable IP is assigned
      DhcpAcquired   [bool]    - $true if IP came from DHCP
      StaticApplied  [bool]    - $true if operator entered static config
      GatewayOk      [bool]    - ping result for the default gateway
      DnsOk          [bool]    - DNS resolution of management.azure.com
      HttpsOk        [bool]    - outbound HTTPS probe to login.microsoftonline.com:443
      GatewayIp      [string]  - gateway IP (blank if not determined)
      DnsServer      [string]  - primary DNS server in use (blank if not determined)
      AdapterName    [string]  - NIC name the IP was configured on

.NOTES
    Author:       Kristopher Turner
    Contact:      kris@hybridsolutions.cloud
    Version:      see src/lib/Beacon.Version.ps1
    LastUpdated:  2026-10-15
    TaskReference = "azurelocal-beacon/phase-3-network-bootstrap"
    DocumentationRef = "docs/validation/network-firewall.md"
    Compatibility: PowerShell 5.1 (WinPE) and PowerShell 7. No PS7-only syntax used.
    PSScriptAnalyzer: passes at Warning/Error severity.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 120)]
    [int]$DhcpWaitSeconds = 15,

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# Helpers
# ============================================================

function Write-BootLine {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-RoutableIPv4 {
    <#
    Returns the first routable IPv4 address found on any enabled NIC.
    Excludes loopback (127.x) and APIPA (169.254.x).
    Returns empty string if none found.
    #>
    try {
        $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        foreach ($nic in $nics) {
            if ($null -eq $nic.IPAddress) { continue }
            foreach ($ip in $nic.IPAddress) {
                if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and
                    $ip -notmatch '^127\.' -and
                    $ip -notmatch '^169\.254\.') {
                    return $ip
                }
            }
        }
    } catch {
        # CIM may fail in minimal WinPE - try ipconfig parse
        try {
            $ipcfg = & ipconfig 2>&1
            foreach ($line in $ipcfg) {
                if ($line -match 'IPv4.*?:\s*([\d\.]+)') {
                    $ip = $Matches[1]
                    if ($ip -notmatch '^127\.' -and $ip -notmatch '^169\.254\.') {
                        return $ip
                    }
                }
            }
        } catch { Write-Verbose "probe failed: $($_.Exception.Message)" }
    }
    return ''
}

function Get-AdapterName {
    <#
    Returns the name of the first UP network adapter, for use with netsh.
    #>
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        if ($adapters) { return ($adapters | Select-Object -First 1).Name }
    } catch { Write-Verbose "probe failed: $($_.Exception.Message)" }
    # WinPE has no NetAdapter module: ask WMI for the connected adapter's connection name
    try {
        $cim = Get-CimInstance Win32_NetworkAdapter -Filter 'NetConnectionStatus=2' -ErrorAction Stop | Where-Object { $_.NetConnectionID } | Select-Object -First 1
        if ($cim) { return $cim.NetConnectionID }
    } catch { Write-Verbose "WMI adapter lookup failed: $($_.Exception.Message)" }
    # Fallback: common WinPE name
    return 'Ethernet'
}

function Get-DefaultGateway {
    <#
    Returns the default gateway for the active connection, or empty string.
    #>
    try {
        $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        foreach ($nic in $nics) {
            if ($nic.DefaultIPGateway -and $nic.DefaultIPGateway.Count -gt 0) {
                return $nic.DefaultIPGateway[0]
            }
        }
    } catch { Write-Verbose "probe failed: $($_.Exception.Message)" }
    return ''
}

function Get-PrimaryDns {
    <#
    Returns the primary DNS server IP, or empty string.
    #>
    try {
        $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        foreach ($nic in $nics) {
            if ($nic.DNSServerSearchOrder -and $nic.DNSServerSearchOrder.Count -gt 0) {
                return $nic.DNSServerSearchOrder[0]
            }
        }
    } catch { Write-Verbose "probe failed: $($_.Exception.Message)" }
    return ''
}

function Test-PingAddress {
    param([string]$Address, [int]$TimeoutMs = 2000)
    try {
        $ping   = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($Address, $TimeoutMs)
        return ($result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch {
        return $false
    }
}

function Test-DnsResolution {
    param([string]$Hostname)
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Hostname)
        return ($null -ne $addrs -and $addrs.Count -gt 0)
    } catch {
        return $false
    }
}

function Test-TcpPort {
    param([string]$Hostname, [int]$Port, [int]$TimeoutMs = 5000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar     = $client.BeginConnect($Hostname, $Port, $null, $null)
        $ok     = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $client.EndConnect($ar) }
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Read-ValueWithDefault {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) {
        $response = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($response)) { return $Default }
        return $response.Trim()
    } else {
        $response = Read-Host $Prompt
        return $response.Trim()
    }
}

function Test-Ipv4Address {
    <# True for a dotted-quad IPv4 address (each octet 0-255). Pure. #>
    param([string]$Text)
    $ip = $null
    if ($Text -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    return [System.Net.IPAddress]::TryParse($Text, [ref]$ip)
}

function Test-SubnetMask {
    <# True for a contiguous IPv4 subnet mask (e.g. 255.255.255.0). Pure. #>
    param([string]$Text)
    if (-not (Test-Ipv4Address $Text)) { return $false }
    [uint64]$n = 0
    foreach ($o in $Text.Split('.')) { $n = ($n * 256) + [uint64]$o }
    if ($n -eq 0) { return $false }
    [uint64]$inv = 4294967295 - $n
    return (($inv -band ($inv + 1)) -eq 0)
}

# Dot-sourcing (Pester) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

# ============================================================
# Main execution
# ============================================================

$state = @{
    IpAddress     = ''
    Configured    = $false
    DhcpAcquired  = $false
    StaticApplied = $false
    GatewayOk     = $false
    DnsOk         = $false
    HttpsOk       = $false
    GatewayIp     = ''
    DnsServer     = ''
    AdapterName   = ''
}

Write-BootLine ''
Write-BootLine '------------------------------------------------------------' -Color Cyan
Write-BootLine '  Network Bootstrap - AzL Beacon' -Color Cyan
Write-BootLine '------------------------------------------------------------' -Color Cyan

# Step 1: Wait for DHCP
if ($DhcpWaitSeconds -gt 0) {
    Write-BootLine "  Waiting ${DhcpWaitSeconds}s for NIC driver init and DHCP lease..." -Color White
    & ping -n ($DhcpWaitSeconds + 1) 127.0.0.1 | Out-Null
}

# Step 2: Check for routable IP
$detectedIp = Get-RoutableIPv4
if ($detectedIp) {
    $state.IpAddress    = $detectedIp
    $state.Configured   = $true
    $state.DhcpAcquired = $true
    $state.GatewayIp    = Get-DefaultGateway
    $state.DnsServer    = Get-PrimaryDns
    $state.AdapterName  = Get-AdapterName
    Write-BootLine "  [OK] DHCP acquired: $detectedIp" -Color Green
    if ($state.GatewayIp) { Write-BootLine "       Gateway : $($state.GatewayIp)" -Color White }
    if ($state.DnsServer)  { Write-BootLine "       DNS     : $($state.DnsServer)" -Color White }
} else {
    # Step 3: No DHCP - prompt for static IP
    Write-BootLine ''
    Write-BootLine '  [WARN] No DHCP address detected.' -Color Yellow
    Write-BootLine '  Enter static network configuration, or press Enter to skip.' -Color Yellow
    Write-BootLine ''

    $adapterName = Get-AdapterName
    $state.AdapterName = $adapterName

    $ipInput   = Read-ValueWithDefault "  IP address"
    $maskInput = Read-ValueWithDefault "  Subnet mask" -Default '255.255.255.0'
    $gwInput   = Read-ValueWithDefault "  Default gateway"
    $dnsInput  = Read-ValueWithDefault "  Primary DNS server"

    $inputOk = ($ipInput -and $gwInput -and (Test-Ipv4Address $ipInput) -and (Test-Ipv4Address $gwInput) -and (Test-SubnetMask $maskInput) -and (-not $dnsInput -or (Test-Ipv4Address $dnsInput)))
    if ($ipInput -and -not $inputOk) {
        Write-BootLine '  [WARN] Invalid address, mask, gateway or DNS entry; nothing applied.' -Color Yellow
    }
    if ($inputOk) {
        Write-BootLine "  Applying static IP to adapter '$adapterName'..." -Color Cyan
        try {
            & netsh interface ip set address name=`"$adapterName`" static $ipInput $maskInput $gwInput | Out-Null
            if ($dnsInput) {
                & netsh interface ip set dns name=`"$adapterName`" static $dnsInput | Out-Null
            }
            # Brief settle time
            & ping -n 3 127.0.0.1 | Out-Null

            $detectedIp = Get-RoutableIPv4
            if ($detectedIp) {
                $state.IpAddress     = $detectedIp
                $state.Configured    = $true
                $state.StaticApplied = $true
                $state.GatewayIp     = $gwInput
                $state.DnsServer     = $dnsInput
                Write-BootLine "  [OK] Static IP applied: $detectedIp" -Color Green
            } else {
                Write-BootLine "  [WARN] IP may not have applied. Network tests will likely fail." -Color Yellow
            }
        } catch {
            Write-BootLine "  [FAIL] netsh error: $($_.Exception.Message)" -Color Red
        }
    } else {
        Write-BootLine "  Skipping static IP - no valid input. Network tests will fail." -Color Yellow
    }
}

# Step 4: Verify connectivity
if (-not $SkipVerification -and $state.Configured) {
    Write-BootLine ''
    Write-BootLine '  Verifying connectivity...' -Color Cyan

    # Gateway ping
    if ($state.GatewayIp) {
        $gwOk = Test-PingAddress -Address $state.GatewayIp
        $state.GatewayOk = $gwOk
        $gwLabel = if ($gwOk) { '[OK]  ' } else { '[WARN]' }
        $gwColor = if ($gwOk) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Yellow }
        Write-BootLine "  $gwLabel Gateway ping: $($state.GatewayIp)" -Color $gwColor
    }

    # DNS resolution
    $dnsOk = Test-DnsResolution -Hostname 'management.azure.com'
    $state.DnsOk = $dnsOk
    $dnsLabel = if ($dnsOk) { '[OK]  ' } else { '[WARN]' }
    $dnsColor = if ($dnsOk) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Yellow }
    Write-BootLine "  $dnsLabel DNS: management.azure.com" -Color $dnsColor

    # Outbound HTTPS
    $httpsOk = Test-TcpPort -Hostname 'login.microsoftonline.com' -Port 443
    $state.HttpsOk = $httpsOk
    $httpsLabel = if ($httpsOk) { '[OK]  ' } else { '[WARN]' }
    $httpsColor = if ($httpsOk) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Yellow }
    Write-BootLine "  $httpsLabel HTTPS: login.microsoftonline.com:443" -Color $httpsColor
}

Write-BootLine ''

return $state
