#Requires -Version 5.1
<#
.SYNOPSIS
    Boot-time Azure Local pre-deployment validation engine for WinPE and full Windows.

.DESCRIPTION
    Runs 7 validation categories grounded in Microsoft and Dell documentation.
    Designed to run from WinPE (PS 5.1 subset) or PowerShell 7 on any machine
    connected to the management network.

    Validation categories:
      1  Basic network: NIC up, IP assigned, gateway reachable
      2  DNS: forward and reverse lookups, TCP/UDP port 53 reachability
      3  NTP: w32tm stripchart + clock skew check
      4  Active Directory ports: LDAP, Kerberos, RPC, LDAPS, DNS + SRV record (AD path only)
      5  Azure endpoint sweep: TCP connect + HTTPS GET — sourced from Azure Local firewall
         requirements, EastUS HCI endpoints, and Dell OEM endpoints
      6  Environment Checker: Invoke-AzStackHciConnectivityValidation +
         Invoke-AzStackHciNetworkValidation (AzStackHci.EnvironmentChecker module)
      7  Arc integration: Invoke-AzStackHciArcIntegrationValidation (optional; requires
         Connect-AzAccount login — skipped gracefully if not authenticated)

    All test targets are read from config\validation-config.json and
    config\endpoints.json — no values are hardcoded in this script.

    Exit codes:
      0 — all categories pass (no critical failures)
      1 — one or more critical failures
      2 — no checks ran

.PARAMETER ConfigPath
    Path to the config directory containing validation-config.json and endpoints.json.
    Default: <scriptroot>\config

.PARAMETER ResultsPath
    Directory where the JSON results file is written.
    Default: X:\results (WinPE RAM drive). Falls back to $env:TEMP if X: is absent.

.PARAMETER Categories
    One or more category numbers (1-7) to run. Default: all.
    Example: -Categories 1,2,5

.PARAMETER SkipEnvironmentChecker
    Skip Category 6 (AzStackHci.EnvironmentChecker connectivity + network validation).
    Use when the module is not bundled in the image or connectivity is unavailable.

.PARAMETER SkipArc
    Skip Category 7 (Arc integration validation).
    Use when not authenticated to Azure or Arc is not in scope.

.EXAMPLE
    .\Start-AzlValidation.ps1
    Runs all 7 categories with defaults.

.EXAMPLE
    .\Start-AzlValidation.ps1 -Categories 1,2,3,4 -ResultsPath C:\Temp\results
    Runs network/DNS/NTP/AD categories only and saves results to C:\Temp\results.

.EXAMPLE
    .\Start-AzlValidation.ps1 -SkipEnvironmentChecker -SkipArc
    Runs categories 1-5 only (network probes, no MS module required).

.NOTES
    Version:      2.0
    Last Updated: 2026-06-19
    Prerequisites:
      - config\validation-config.json and config\endpoints.json must exist.
      - curl.exe must be on PATH for HTTPS GET probes (built-in to WinPE and Win10+).
      - w32tm.exe must be on PATH for NTP checks (built-in to WinPE).
      - AzStackHci.EnvironmentChecker required for Cat-6/7 (bundled at ISO build time).
    PSScriptAnalyzer: passes at Warning/Error severity.
    Compatibility: PowerShell 5.1 (WinPE) and PowerShell 7. No PS7-only syntax used.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '',

    [Parameter(Mandatory = $false)]
    [string]$ResultsPath = '',

    [Parameter(Mandatory = $false)]
    [string[]]$Categories = @(),

    [Parameter(Mandatory = $false)]
    [switch]$SkipEnvironmentChecker,

    [Parameter(Mandatory = $false)]
    [switch]$SkipArc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#region ================================================================
#  CONSTANTS AND SCRIPT-LEVEL VARIABLES
#================================================================

$script:VERSION      = '2.0'
$script:StartTime    = Get-Date
$script:AllResults   = [System.Collections.Generic.List[object]]::new()
$script:CriticalFail = $false

#endregion

#region ================================================================
#  CONSOLE OUTPUT HELPER
#================================================================

$InformationPreference = 'Continue'

function Out-ConsoleLine {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    Write-Information -MessageData $Message -Tags @('AzlValidation', $Color.ToString()) -InformationAction Continue
}

#endregion

#region ================================================================
#  RESULT RECORDING
#================================================================

function Add-ValidationResult {
    [CmdletBinding()]
    param(
        [string]$Category,
        [string]$Name,
        [string]$Target,
        [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')]
        [string]$Status,
        [string]$Detail,
        [long]$DurationMs = 0
    )

    $result = [PSCustomObject][ordered]@{
        Category   = $Category
        Name       = $Name
        Target     = $Target
        Status     = $Status
        Detail     = $Detail
        DurationMs = $DurationMs
    }

    $script:AllResults.Add($result)

    $symbol = switch ($Status) {
        'Pass' { '[PASS]' }
        'Fail' { '[FAIL]' }
        'Warn' { '[WARN]' }
        'Skip' { '[SKIP]' }
        default { '[INFO]' }
    }
    $color = switch ($Status) {
        'Pass' { [System.ConsoleColor]::Green }
        'Fail' { [System.ConsoleColor]::Red }
        'Warn' { [System.ConsoleColor]::Yellow }
        'Skip' { [System.ConsoleColor]::DarkGray }
        default { [System.ConsoleColor]::White }
    }

    $msg = '  {0} {1,-48} {2}' -f $symbol, $Name, $Target
    if ($Detail) { $msg = $msg + ' -- ' + $Detail }
    Out-ConsoleLine -Message $msg -Color $color

    if ($Status -eq 'Fail') {
        $script:CriticalFail = $true
    }
}

#endregion

#region ================================================================
#  CONFIG LOADING
#================================================================

function Resolve-ScriptDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path $MyInvocation.ScriptName -Parent
}

function Get-ConfigDirectory {
    param([string]$Provided)
    if ($Provided -ne '' -and (Test-Path $Provided -PathType Container)) {
        return (Resolve-Path $Provided).Path
    }
    $root      = Resolve-ScriptDirectory
    $candidate = Join-Path $root 'config'
    if (Test-Path $candidate -PathType Container) { return $candidate }
    throw "Config directory not found. Pass -ConfigPath or place config/ next to this script."
}

function Get-ResultsDirectory {
    param([string]$Provided)
    if ($Provided -ne '') { return $Provided }
    if (Test-Path 'X:\') { return 'X:\results' }
    return $env:TEMP
}

function Import-JsonConfig {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) {
        throw "Required config file not found: $FilePath"
    }
    return Get-Content $FilePath -Raw | ConvertFrom-Json
}

#endregion

#region ================================================================
#  NETWORK HELPERS
#================================================================

function Test-TcpConnect {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 5000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar     = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $waited = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($waited) {
            $client.EndConnect($ar)
            $client.Close()
            $sw.Stop()
            return @{ Success = $true; DurationMs = $sw.ElapsedMilliseconds; Error = '' }
        } else {
            $client.Close()
            $sw.Stop()
            return @{ Success = $false; DurationMs = $sw.ElapsedMilliseconds; Error = 'Timeout' }
        }
    } catch {
        $sw.Stop()
        return @{ Success = $false; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

function Test-PingAddress {
    param([string]$Address, [int]$TimeoutMs = 2000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ping   = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($Address, $TimeoutMs)
        $sw.Stop()
        $ok = $result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
        return @{ Success = $ok; DurationMs = $sw.ElapsedMilliseconds; RoundtripMs = $result.RoundtripTime; Error = $result.Status.ToString() }
    } catch {
        $sw.Stop()
        return @{ Success = $false; DurationMs = $sw.ElapsedMilliseconds; RoundtripMs = 0; Error = $_.Exception.Message }
    }
}

function Invoke-DnsLookup {
    param([string]$DnsHostname)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($DnsHostname)
        $sw.Stop()
        $ips = ($addrs | ForEach-Object { $_.ToString() }) -join ', '
        return @{ Success = $true; Addresses = $ips; DurationMs = $sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return @{ Success = $false; Addresses = ''; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

function Invoke-ReverseDnsLookup {
    param([string]$IpAddress)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $entry = [System.Net.Dns]::GetHostEntry($IpAddress)
        $sw.Stop()
        return @{ Success = $true; DnsHostname = $entry.HostName; DurationMs = $sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return @{ Success = $false; DnsHostname = ''; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

function Invoke-DirectDnsQuery {
    <#
    Fallback DNS A-record query via raw UDP socket — for WinPE where Resolve-DnsName
    may not be available. Returns @{ Success; Addresses; DurationMs; Error }.
    #>
    param([string]$DnsServer, [string]$QueryName, [int]$TimeoutMs = 3000)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $txId   = [byte[]]@((Get-Random -Minimum 1 -Maximum 255), (Get-Random -Minimum 1 -Maximum 255))
        $flags  = [byte[]]@(0x01, 0x00)
        $counts = [byte[]]@(0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

        $qname = [System.Collections.Generic.List[byte]]::new()
        foreach ($label in $QueryName.Split('.')) {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($label)
            $qname.Add([byte]$bytes.Length)
            foreach ($b in $bytes) { $qname.Add($b) }
        }
        $qname.Add(0x00)

        $query = [byte[]]($txId + $flags + $counts + $qname.ToArray() + [byte[]]@(0x00, 0x01, 0x00, 0x01))

        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect($DnsServer, 53)
        $udpClient.Client.ReceiveTimeout = $TimeoutMs
        $null = $udpClient.Send($query, $query.Length)

        $remote   = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udpClient.Receive([ref]$remote)
        $udpClient.Close()
        $sw.Stop()

        $answerCount = ([int]$response[6] -shl 8) -bor [int]$response[7]
        return @{ Success = ($answerCount -gt 0); Addresses = "answers=$answerCount"; DurationMs = $sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return @{ Success = $false; Addresses = ''; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

function Test-DnsSrvRecord {
    param([string]$SrvName, [string]$DnsServer)
    $resolveDnsAvailable = $null -ne (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)
    if ($resolveDnsAvailable) {
        try {
            $records  = Resolve-DnsName -Name $SrvName -Type SRV -Server $DnsServer -ErrorAction Stop
            $srvCount = @($records | Where-Object { $_.QueryType -eq 'SRV' }).Count
            return @{ Success = ($srvCount -gt 0); Detail = "SRV records: $srvCount"; Error = '' }
        } catch {
            return @{ Success = $false; Detail = ''; Error = $_.Exception.Message }
        }
    } else {
        try {
            $output = & nslookup.exe -type=SRV $SrvName $DnsServer 2>&1
            $found  = $output -match 'svr hostname'
            return @{ Success = $found; Detail = 'via nslookup fallback'; Error = '' }
        } catch {
            return @{ Success = $false; Detail = ''; Error = $_.Exception.Message }
        }
    }
}

function Test-HttpsGet {
    <#
    Probes an HTTPS endpoint with curl.exe. Any HTTP response code = TLS succeeded.
    Returns @{ Success; HttpCode; DurationMs; Error }.
    #>
    param([string]$TargetHost, [int]$Port = 443, [int]$TimeoutSeconds = 10)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $curlCmd) {
            $sw.Stop()
            return @{ Success = $false; HttpCode = 0; DurationMs = $sw.ElapsedMilliseconds; Error = 'curl.exe not found on PATH' }
        }
        $url    = "https://$($TargetHost):$Port/"
        $output = & curl.exe --silent --max-time $TimeoutSeconds --output NUL `
                             --write-out '%{http_code}' --insecure $url 2>&1
        $sw.Stop()
        $exitCode = $LASTEXITCODE
        $httpCode = 0
        if ($output -match '^\d{3}$') { $httpCode = [int]([string]$output).Trim() }
        $success = ($exitCode -eq 0 -and $httpCode -gt 0)
        $errMsg  = if ($success) { '' } else { "curl exit=$exitCode http=$httpCode" }
        return @{ Success = $success; HttpCode = $httpCode; DurationMs = $sw.ElapsedMilliseconds; Error = $errMsg }
    } catch {
        $sw.Stop()
        return @{ Success = $false; HttpCode = 0; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

#endregion

#region ================================================================
#  CATEGORY IMPLEMENTATIONS
#================================================================

function Invoke-Category1Network {
    param([object]$ValidationConfig)
    $cat = 'Cat-1-Network'
    Out-ConsoleLine -Message "`n[Category 1] Basic Network Connectivity" -Color ([System.ConsoleColor]::Cyan)

    try {
        $nics      = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        $activeNic = $nics | Where-Object { $_.IPAddress -and $_.IPAddress.Count -gt 0 }
        if ($activeNic) {
            $nicList = ($activeNic | ForEach-Object { "$($_.Description) / $($_.IPAddress[0])" }) -join '; '
            Add-ValidationResult -Category $cat -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Pass' -Detail $nicList
        } else {
            Add-ValidationResult -Category $cat -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Fail' -Detail 'No IP-enabled adapters found'
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Fail' -Detail $_.Exception.Message
    }

    $gw     = $ValidationConfig.managementGateway
    $gwPing = Test-PingAddress -Address $gw -TimeoutMs $ValidationConfig.pingTimeoutMs
    $gwStat = if ($gwPing.Success) { 'Pass' } else { 'Fail' }
    $gwDet  = if ($gwPing.Success) { "$($gwPing.RoundtripMs)ms" } else { $gwPing.Error }
    Add-ValidationResult -Category $cat -Name 'Gateway-Ping' -Target $gw -Status $gwStat -Detail $gwDet -DurationMs $gwPing.DurationMs

    $nodeIp   = $ValidationConfig.nodeIps[0]
    $nodePing = Test-PingAddress -Address $nodeIp -TimeoutMs $ValidationConfig.pingTimeoutMs
    $nodeStat = if ($nodePing.Success) { 'Pass' } else { 'Warn' }
    $nodeDet  = if ($nodePing.Success) { "$($nodePing.RoundtripMs)ms" } else { "Not reachable (may be unpowered): $($nodePing.Error)" }
    Add-ValidationResult -Category $cat -Name 'MgmtSubnet-Node1-Ping' -Target $nodeIp -Status $nodeStat -Detail $nodeDet -DurationMs $nodePing.DurationMs
}

function Invoke-Category2DnsCheck {
    param([object]$ValidationConfig)
    $cat = 'Cat-2-DNS'
    Out-ConsoleLine -Message "`n[Category 2] DNS Resolution" -Color ([System.ConsoleColor]::Cyan)

    foreach ($dnsIp in $ValidationConfig.dnsServers) {
        $tcp = Test-TcpConnect -TargetHost $dnsIp -Port 53 -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
        $st  = if ($tcp.Success) { 'Pass' } else { 'Fail' }
        $det = if ($tcp.Success) { "$($tcp.DurationMs)ms" } else { $tcp.Error }
        Add-ValidationResult -Category $cat -Name "DNS-TCP53-$dnsIp" -Target "$dnsIp`:53" -Status $st -Detail $det -DurationMs $tcp.DurationMs
    }

    $primaryDns = $ValidationConfig.dnsServers[0]
    $udpResult  = Invoke-DirectDnsQuery -DnsServer $primaryDns -QueryName 'management.azure.com' -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
    $udpSt      = if ($udpResult.Success) { 'Pass' } else { 'Warn' }
    $udpDet     = if ($udpResult.Success) { "UDP answered -- $($udpResult.Addresses)" } else { $udpResult.Error }
    Add-ValidationResult -Category $cat -Name 'DNS-UDP53-Probe' -Target "$primaryDns`:53/udp" -Status $udpSt -Detail $udpDet -DurationMs $udpResult.DurationMs

    foreach ($fwdHost in @('login.microsoftonline.com', 'management.azure.com')) {
        $r  = Invoke-DnsLookup -DnsHostname $fwdHost
        $st = if ($r.Success) { 'Pass' } else { 'Fail' }
        $dt = if ($r.Success) { $r.Addresses } else { $r.Error }
        Add-ValidationResult -Category $cat -Name "DNS-Forward-$fwdHost" -Target $fwdHost -Status $st -Detail $dt -DurationMs $r.DurationMs
    }

    $domainR = Invoke-DnsLookup -DnsHostname $ValidationConfig.adDomainFqdn
    $domSt   = if ($domainR.Success) { 'Pass' } else { 'Fail' }
    $domDet  = if ($domainR.Success) { $domainR.Addresses } else { $domainR.Error }
    Add-ValidationResult -Category $cat -Name 'DNS-Forward-ADDomain' -Target $ValidationConfig.adDomainFqdn -Status $domSt -Detail $domDet -DurationMs $domainR.DurationMs

    foreach ($nodeFqdn in $ValidationConfig.nodeFqdns) {
        $r  = Invoke-DnsLookup -DnsHostname $nodeFqdn
        $st = if ($r.Success) { 'Pass' } else { 'Warn' }
        $dt = if ($r.Success) { $r.Addresses } else { "Expected before deployment: $($r.Error)" }
        Add-ValidationResult -Category $cat -Name "DNS-Forward-$nodeFqdn" -Target $nodeFqdn -Status $st -Detail $dt -DurationMs $r.DurationMs
    }

    foreach ($dcIp in $ValidationConfig.dcIps) {
        $r  = Invoke-ReverseDnsLookup -IpAddress $dcIp
        $st = if ($r.Success) { 'Pass' } else { 'Fail' }
        $dt = if ($r.Success) { $r.DnsHostname } else { $r.Error }
        Add-ValidationResult -Category $cat -Name "DNS-Reverse-$dcIp" -Target $dcIp -Status $st -Detail $dt -DurationMs $r.DurationMs
    }
}

function Invoke-Category3Ntp {
    param([object]$ValidationConfig)
    $cat = 'Cat-3-NTP'
    Out-ConsoleLine -Message "`n[Category 3] NTP Time Sync" -Color ([System.ConsoleColor]::Cyan)

    $ntpServerList = @($ValidationConfig.ntpServers.primary, $ValidationConfig.ntpServers.secondary)
    foreach ($ntpTarget in $ntpServerList) {
        try {
            $sw     = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & w32tm.exe /stripchart /computer:$ntpTarget /samples:1 /dataonly 2>&1
            $sw.Stop()

            if ($LASTEXITCODE -ne 0) {
                Add-ValidationResult -Category $cat -Name "NTP-$ntpTarget" -Target $ntpTarget -Status 'Fail' `
                    -Detail "w32tm exit $LASTEXITCODE" -DurationMs $sw.ElapsedMilliseconds
                continue
            }

            $offsetLine = $output | Where-Object { $_ -match '[+-]\d+\.\d+s' } | Select-Object -Last 1
            if ($offsetLine -and $offsetLine -match '([+-]\d+\.\d+)s') {
                $offsetSec = [double]$Matches[1]
                $absOffset = [System.Math]::Abs($offsetSec)
                $maxSkew   = $ValidationConfig.ntpMaxSkewSeconds
                if ($absOffset -le $maxSkew) {
                    Add-ValidationResult -Category $cat -Name "NTP-$ntpTarget" -Target $ntpTarget -Status 'Pass' `
                        -Detail "offset=${offsetSec}s (limit=${maxSkew}s)" -DurationMs $sw.ElapsedMilliseconds
                } else {
                    Add-ValidationResult -Category $cat -Name "NTP-$ntpTarget" -Target $ntpTarget -Status 'Fail' `
                        -Detail "offset=${offsetSec}s EXCEEDS ${maxSkew}s -- Azure Local deployment requires clock within 5 minutes of NTP" -DurationMs $sw.ElapsedMilliseconds
                }
            } else {
                Add-ValidationResult -Category $cat -Name "NTP-$ntpTarget" -Target $ntpTarget -Status 'Warn' `
                    -Detail "w32tm responded but offset not parseable" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            Add-ValidationResult -Category $cat -Name "NTP-$ntpTarget" -Target $ntpTarget -Status 'Fail' `
                -Detail $_.Exception.Message
        }
    }
}

function Invoke-Category4ActiveDirectory {
    param([object]$ValidationConfig)
    $cat = 'Cat-4-AD'
    Out-ConsoleLine -Message "`n[Category 4] Active Directory Ports" -Color ([System.ConsoleColor]::Cyan)

    $adPortSpec = @(
        @{ Port = 389; Label = 'LDAP' },
        @{ Port = 88;  Label = 'Kerberos' },
        @{ Port = 135; Label = 'RPC-Mapper' },
        @{ Port = 53;  Label = 'DNS' },
        @{ Port = 636; Label = 'LDAPS' }
    )

    foreach ($dcIp in $ValidationConfig.dcIps) {
        foreach ($ps in $adPortSpec) {
            $r  = Test-TcpConnect -TargetHost $dcIp -Port $ps.Port -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
            $st = if ($r.Success) { 'Pass' } else { 'Fail' }
            $dt = if ($r.Success) { "$($r.DurationMs)ms" } else { $r.Error }
            Add-ValidationResult -Category $cat -Name "AD-$($ps.Label)-$dcIp" `
                -Target "$dcIp`:$($ps.Port)" -Status $st -Detail $dt -DurationMs $r.DurationMs
        }
    }

    $srvName = "_ldap._tcp.dc._msdcs.$($ValidationConfig.adDomainFqdn)"
    $srv     = Test-DnsSrvRecord -SrvName $srvName -DnsServer $ValidationConfig.dnsServers[0]
    $st      = if ($srv.Success) { 'Pass' } else { 'Fail' }
    $dt      = if ($srv.Success) { $srv.Detail } else { $srv.Error }
    Add-ValidationResult -Category $cat -Name "AD-SRV-DCLocator" -Target $srvName -Status $st -Detail $dt
}

function Invoke-Category5EndpointSweep {
    param([object]$ValidationConfig, [object[]]$EndpointList)
    $cat = 'Cat-5-Endpoints'
    Out-ConsoleLine -Message "`n[Category 5] Azure Endpoint Sweep" -Color ([System.ConsoleColor]::Cyan)
    Out-ConsoleLine -Message "  Testing $($EndpointList.Count) endpoints ..." -Color ([System.ConsoleColor]::DarkGray)

    foreach ($ep in $EndpointList) {
        $probeTarget = $ep.host
        $isWild      = $ep.wildcard

        if ($isWild) {
            if ($ep.probeHost -and $ep.probeHost -ne '') {
                $probeTarget = $ep.probeHost
            } else {
                Add-ValidationResult -Category $cat -Name "EP-$($ep.host)" -Target "$($ep.host):$($ep.port)" `
                    -Status 'Skip' -Detail 'Wildcard -- no representative probe host; validate at firewall'
                continue
            }
        }

        $tcp = Test-TcpConnect -TargetHost $probeTarget -Port $ep.port -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs

        if ($tcp.Success) {
            $detail = "$($tcp.DurationMs)ms"
            if ($ep.severity -eq 'critical' -and $ep.protocol -eq 'HTTPS') {
                $https = Test-HttpsGet -TargetHost $probeTarget -Port $ep.port
                if (-not $https.Success) {
                    Add-ValidationResult -Category $cat -Name "EP-$($ep.host)" -Target "$($ep.host):$($ep.port)" `
                        -Status 'Warn' -Detail "TCP ok but HTTPS probe failed: $($https.Error)" `
                        -DurationMs ($tcp.DurationMs + $https.DurationMs)
                    continue
                }
                $detail = "TCP+HTTPS ok -- $($tcp.DurationMs)ms"
            }
            Add-ValidationResult -Category $cat -Name "EP-$($ep.host)" -Target "$($ep.host):$($ep.port)" `
                -Status 'Pass' -Detail $detail -DurationMs $tcp.DurationMs
        } else {
            $failSt = if ($ep.severity -eq 'critical') { 'Fail' } else { 'Warn' }
            Add-ValidationResult -Category $cat -Name "EP-$($ep.host)" -Target "$($ep.host):$($ep.port)" `
                -Status $failSt -Detail $tcp.Error -DurationMs $tcp.DurationMs
        }
    }
}

function Invoke-Category6EnvironmentChecker {
    param([string]$DestResultsPath, [switch]$SkipChecks)
    $cat = 'Cat-6-EnvChecker'
    Out-ConsoleLine -Message "`n[Category 6] Azure Local Environment Checker (Official Microsoft Validator)" -Color ([System.ConsoleColor]::Cyan)

    if ($SkipChecks) {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' `
            -Status 'Skip' -Detail '-SkipEnvironmentChecker switch set'
        return
    }

    $scriptDir   = Resolve-ScriptDirectory
    $modulePaths = @(
        (Join-Path $scriptDir '..\Modules\AzStackHci.EnvironmentChecker'),
        (Join-Path $scriptDir 'Modules\AzStackHci.EnvironmentChecker'),
        'X:\Tools\Modules\AzStackHci.EnvironmentChecker'
    )

    $moduleLoaded = $false
    foreach ($modPath in $modulePaths) {
        if (Test-Path $modPath -ErrorAction SilentlyContinue) {
            try {
                Import-Module $modPath -ErrorAction Stop -Force
                $moduleLoaded = $true
                Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' `
                    -Status 'Pass' -Detail "Loaded from $modPath"
                break
            } catch {
                Write-Verbose "Module load from $modPath failed: $_"
            }
        }
    }

    if (-not $moduleLoaded) {
        try {
            Import-Module AzStackHci.EnvironmentChecker -ErrorAction Stop
            $moduleLoaded = $true
            Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' `
                -Status 'Pass' -Detail 'Loaded from PSModulePath'
        } catch {
            Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' `
                -Status 'Warn' -Detail 'Module not found. Bundle via Build-WinPEImage.ps1 or run on staging server.'
        }
    }

    if (-not $moduleLoaded) { return }

    # Connectivity validation
    try {
        $sw         = [System.Diagnostics.Stopwatch]::StartNew()
        $envResults = Invoke-AzStackHciConnectivityValidation -PassThru -ErrorAction Stop
        $sw.Stop()
        $failCount  = @($envResults | Where-Object { $_.Status -ne 'Succeeded' }).Count
        $totalCount = $envResults.Count
        $st         = if ($failCount -eq 0) { 'Pass' } else { 'Fail' }
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Connectivity' -Target 'Invoke-AzStackHciConnectivityValidation' `
            -Status $st -Detail "$($totalCount - $failCount)/$totalCount endpoints Succeeded" -DurationMs $sw.ElapsedMilliseconds
    } catch {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Connectivity' -Target 'Invoke-AzStackHciConnectivityValidation' `
            -Status 'Warn' -Detail "Validator threw: $($_.Exception.Message)"
    }

    # Network validation
    try {
        $sw2        = [System.Diagnostics.Stopwatch]::StartNew()
        $netResults = Invoke-AzStackHciNetworkValidation -PassThru -ErrorAction Stop
        $sw2.Stop()
        $netFail    = @($netResults | Where-Object { $_.Status -ne 'Succeeded' }).Count
        $netTotal   = $netResults.Count
        $netSt      = if ($netFail -eq 0) { 'Pass' } else { 'Fail' }
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Network' -Target 'Invoke-AzStackHciNetworkValidation' `
            -Status $netSt -Detail "$($netTotal - $netFail)/$netTotal checks Succeeded" -DurationMs $sw2.ElapsedMilliseconds
    } catch {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Network' -Target 'Invoke-AzStackHciNetworkValidation' `
            -Status 'Warn' -Detail "Validator threw: $($_.Exception.Message)"
    }

    $reportSrc = Join-Path $HOME '.AzStackHci\AzStackHciEnvironmentReport.json'
    if (Test-Path $reportSrc) {
        try {
            Copy-Item $reportSrc (Join-Path $DestResultsPath 'AzStackHciEnvironmentReport.json') -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not copy Environment Checker report: $_"
        }
    }
}

function Invoke-Category7Arc {
    param([string]$DestResultsPath, [switch]$SkipChecks)
    $cat = 'Cat-7-Arc'
    Out-ConsoleLine -Message "`n[Category 7] Arc Integration (Optional)" -Color ([System.ConsoleColor]::Cyan)

    if ($SkipChecks) {
        Add-ValidationResult -Category $cat -Name 'Arc-Integration' -Target 'Invoke-AzStackHciArcIntegrationValidation' `
            -Status 'Skip' -Detail '-SkipArc switch set'
        return
    }

    $modLoaded = $null -ne (Get-Module -Name 'AzStackHci.EnvironmentChecker' -ErrorAction SilentlyContinue)
    if (-not $modLoaded) {
        Add-ValidationResult -Category $cat -Name 'Arc-Integration' -Target 'Invoke-AzStackHciArcIntegrationValidation' `
            -Status 'Skip' -Detail 'AzStackHci.EnvironmentChecker not loaded -- run Category 6 first'
        return
    }

    $azCtx = $null
    try { $azCtx = Get-AzContext -ErrorAction SilentlyContinue } catch { }
    if (-not $azCtx) {
        Add-ValidationResult -Category $cat -Name 'Arc-Integration' -Target 'Invoke-AzStackHciArcIntegrationValidation' `
            -Status 'Skip' -Detail 'No Azure context -- sign in with Connect-AzAccount -DeviceCode first'
        return
    }

    try {
        $sw         = [System.Diagnostics.Stopwatch]::StartNew()
        $arcResults = Invoke-AzStackHciArcIntegrationValidation -PassThru -ErrorAction Stop
        $sw.Stop()
        $failCount  = @($arcResults | Where-Object { $_.Status -ne 'Succeeded' }).Count
        $totalCount = $arcResults.Count
        $st         = if ($failCount -eq 0) { 'Pass' } else { 'Fail' }
        Add-ValidationResult -Category $cat -Name 'Arc-Integration' -Target 'Invoke-AzStackHciArcIntegrationValidation' `
            -Status $st -Detail "$($totalCount - $failCount)/$totalCount checks Succeeded" -DurationMs $sw.ElapsedMilliseconds
    } catch {
        Add-ValidationResult -Category $cat -Name 'Arc-Integration' -Target 'Invoke-AzStackHciArcIntegrationValidation' `
            -Status 'Warn' -Detail "Arc validator threw: $($_.Exception.Message)"
    }
}

#endregion

#region ================================================================
#  SUMMARY AND OUTPUT
#================================================================

function Write-ValidationSummary {
    param([System.Collections.Generic.List[object]]$Results)
    $pass  = @($Results | Where-Object { $_.Status -eq 'Pass' }).Count
    $fail  = @($Results | Where-Object { $_.Status -eq 'Fail' }).Count
    $warn  = @($Results | Where-Object { $_.Status -eq 'Warn' }).Count
    $skip  = @($Results | Where-Object { $_.Status -eq 'Skip' }).Count

    Out-ConsoleLine -Message '' -Color ([System.ConsoleColor]::White)
    Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::White)
    Out-ConsoleLine -Message '  Azure Local Pre-Deployment Validation -- Summary' -Color ([System.ConsoleColor]::White)
    Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::White)
    Out-ConsoleLine -Message ("  Total checks : {0}" -f $Results.Count) -Color ([System.ConsoleColor]::White)
    Out-ConsoleLine -Message ("  Pass         : {0}" -f $pass) -Color ([System.ConsoleColor]::Green)

    $failColor = if ($fail -gt 0) { [System.ConsoleColor]::Red } else { [System.ConsoleColor]::Green }
    $warnColor = if ($warn -gt 0) { [System.ConsoleColor]::Yellow } else { [System.ConsoleColor]::Green }
    Out-ConsoleLine -Message ("  Fail         : {0}" -f $fail) -Color $failColor
    Out-ConsoleLine -Message ("  Warning      : {0}" -f $warn) -Color $warnColor
    Out-ConsoleLine -Message ("  Skip         : {0}" -f $skip) -Color ([System.ConsoleColor]::DarkGray)
    Out-ConsoleLine -Message '' -Color ([System.ConsoleColor]::White)

    if ($fail -gt 0) {
        Out-ConsoleLine -Message '  BLOCKING FAILURES:' -Color ([System.ConsoleColor]::Red)
        $Results | Where-Object { $_.Status -eq 'Fail' } | ForEach-Object {
            Out-ConsoleLine -Message ("    [FAIL] [{0}] {1} -- {2}" -f $_.Category, $_.Name, $_.Detail) -Color ([System.ConsoleColor]::Red)
        }
        Out-ConsoleLine -Message '' -Color ([System.ConsoleColor]::White)
    }

    if ($warn -gt 0) {
        Out-ConsoleLine -Message '  WARNINGS (review before deployment):' -Color ([System.ConsoleColor]::Yellow)
        $Results | Where-Object { $_.Status -eq 'Warn' } | ForEach-Object {
            Out-ConsoleLine -Message ("    [WARN] [{0}] {1} -- {2}" -f $_.Category, $_.Name, $_.Detail) -Color ([System.ConsoleColor]::Yellow)
        }
        Out-ConsoleLine -Message '' -Color ([System.ConsoleColor]::White)
    }

    if ($Results.Count -eq 0) {
        Out-ConsoleLine -Message '  Verdict: NO CHECKS RAN -- check -Categories input and config' -Color ([System.ConsoleColor]::Red)
        Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::White)
        return
    }

    $verdict      = if ($fail -gt 0) { 'NOT READY -- Fix blocking failures before deployment' } else { 'READY -- No critical failures detected' }
    $verdictColor = if ($fail -gt 0) { [System.ConsoleColor]::Red } else { [System.ConsoleColor]::Green }
    Out-ConsoleLine -Message "  Verdict: $verdict" -Color $verdictColor
    Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::White)
}

function Save-ValidationResult {
    param([System.Collections.Generic.List[object]]$Results, [string]$ResultsDir)

    try {
        if (-not (Test-Path $ResultsDir)) {
            New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
        }

        $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputFile = Join-Path $ResultsDir "validation-$timestamp.json"

        $pass  = @($Results | Where-Object { $_.Status -eq 'Pass' }).Count
        $fail  = @($Results | Where-Object { $_.Status -eq 'Fail' }).Count
        $warn  = @($Results | Where-Object { $_.Status -eq 'Warn' }).Count
        $skip  = @($Results | Where-Object { $_.Status -eq 'Skip' }).Count

        $output = [PSCustomObject][ordered]@{
            validationTimestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            scriptVersion       = $script:VERSION
            durationSeconds     = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1)
            summary             = [PSCustomObject][ordered]@{
                total   = $Results.Count
                pass    = $pass
                fail    = $fail
                warn    = $warn
                skip    = $skip
                verdict = if ($fail -gt 0) { 'FAIL' } else { 'PASS' }
            }
            results = $Results
        }

        $output | ConvertTo-Json -Depth 5 | Set-Content -Path $outputFile -Encoding UTF8
        Out-ConsoleLine -Message "  Results written: $outputFile" -Color ([System.ConsoleColor]::DarkGray)
        return $outputFile
    } catch {
        Write-Warning "Could not save results JSON: $_"
        return ''
    }
}

#endregion

#region ================================================================
#  ENTRY POINT
#================================================================

Out-ConsoleLine -Message '' -Color ([System.ConsoleColor]::White)
Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::Cyan)
Out-ConsoleLine -Message "  Azure Local Pre-Deployment Validation v$($script:VERSION)" -Color ([System.ConsoleColor]::Cyan)
Out-ConsoleLine -Message "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color ([System.ConsoleColor]::Cyan)
Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::Cyan)

$resolvedConfigPath  = Get-ConfigDirectory -Provided $ConfigPath
$resolvedResultsPath = Get-ResultsDirectory -Provided $ResultsPath

Write-Verbose "Config path  : $resolvedConfigPath"
Write-Verbose "Results path : $resolvedResultsPath"

$cfg       = Import-JsonConfig -FilePath (Join-Path $resolvedConfigPath 'validation-config.json')
$epWrapper = Import-JsonConfig -FilePath (Join-Path $resolvedConfigPath 'endpoints.json')
$endpoints = $epWrapper.endpoints

Out-ConsoleLine -Message "  Config loaded: $($cfg.clusterName) / $($cfg.azureRegion)" -Color ([System.ConsoleColor]::DarkGray)
Out-ConsoleLine -Message "  Endpoints    : $($endpoints.Count) entries" -Color ([System.ConsoleColor]::DarkGray)

$allCategoryNums  = @(1, 2, 3, 4, 5, 6, 7)
$parsedCategories = @($Categories | ForEach-Object { $_ -split '[,\s]+' } |
    Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } |
    Where-Object { $allCategoryNums -contains $_ } | Select-Object -Unique)
$runCategories    = if ($parsedCategories.Count -gt 0) { $parsedCategories } else { $allCategoryNums }

Out-ConsoleLine -Message "  Categories   : $($runCategories -join ', ')" -Color ([System.ConsoleColor]::DarkGray)

if ($runCategories -contains 1) { Invoke-Category1Network            -ValidationConfig $cfg }
if ($runCategories -contains 2) { Invoke-Category2DnsCheck           -ValidationConfig $cfg }
if ($runCategories -contains 3) { Invoke-Category3Ntp                -ValidationConfig $cfg }
if ($runCategories -contains 4) { Invoke-Category4ActiveDirectory    -ValidationConfig $cfg }
if ($runCategories -contains 5) { Invoke-Category5EndpointSweep      -ValidationConfig $cfg -EndpointList $endpoints }
if ($runCategories -contains 6) { Invoke-Category6EnvironmentChecker -DestResultsPath $resolvedResultsPath -SkipChecks:$SkipEnvironmentChecker }
if ($runCategories -contains 7) { Invoke-Category7Arc                -DestResultsPath $resolvedResultsPath -SkipChecks:$SkipArc }

Write-ValidationSummary -Results $script:AllResults
$null = Save-ValidationResult -Results $script:AllResults -ResultsDir $resolvedResultsPath

$exitCode = if ($script:CriticalFail) { 1 } elseif ($script:AllResults.Count -eq 0) { 2 } else { 0 }
Write-Verbose "Exit code: $exitCode"
exit $exitCode

#endregion
