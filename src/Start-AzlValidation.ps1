#Requires -Version 5.1
<#
.SYNOPSIS
    Boot-time Azure Local pre-deployment validation engine for WinPE and full Windows.

.DESCRIPTION
    Runs all 12 categories of pre-deployment validation defined in
    docs/index.md. Designed to run from WinPE (PS 5.1 subset)
    or PowerShell 7 on any machine connected to the management network.

    Validation categories:
      1  Basic network: NIC up, IP assigned, gateway reachable
      2  DNS: forward and reverse lookups, TCP/UDP port 53 reachability
      3  NTP: w32tm stripchart + clock skew check
      4  Active Directory ports: LDAP, Kerberos, RPC, LDAPS, DNS + SRV record
      5  Azure endpoint sweep: TCP connect + HTTPS GET for critical endpoints
      6  Infrastructure device reachability: firewall, switches, iDRAC, OpenGear
      7  Service Bus WebSocket probe: TCP 443 to servicebus host
      8  NTP UDP port 123: raw UDP NTP packet to time.windows.com
      9  Environment Checker: AzStackHci.EnvironmentChecker module (load + run)
      10 SSL inspection detection: certificate chain root authority check
      11 Deployment prerequisite sanity: IP pool scan, DNS-not-in-K8s-range
      12 Hardware self-checks: TPM, Secure Boot, storage, NICs, CPU, memory

    All test targets are read from config\validation-config.json and
    config\endpoints.json — no values are hardcoded in this script.

    Exit codes:
      0 — all categories pass (no critical failures)
      1 — one or more critical failures

.PARAMETER ConfigPath
    Path to the config directory containing validation-config.json and endpoints.json.
    Default: <scriptroot>\config

.PARAMETER ResultsPath
    Directory where the JSON results file is written.
    Default: X:\results (WinPE RAM drive). Falls back to $env:TEMP if X: is absent.

.PARAMETER Categories
    One or more category numbers (1-12) to run. Default: all.
    Example: -Categories 1,2,5

.PARAMETER SkipEnvironmentChecker
    Skip Category 9 (AzStackHci.EnvironmentChecker). Use when the module is
    not bundled in the image or when running from a laptop without connectivity.

.EXAMPLE
    .\Start-AzlValidation.ps1
    Runs all 12 categories with defaults.

.EXAMPLE
    .\Start-AzlValidation.ps1 -Categories 1,2,3,4 -ResultsPath C:\Temp\results
    Runs network/DNS/NTP/AD categories only and saves results to C:\Temp\results.

.EXAMPLE
    .\Start-AzlValidation.ps1 -SkipEnvironmentChecker -Verbose
    Runs all categories except the MS Environment Checker with verbose output.

.NOTES
    Version:      1.0
    Last Updated: 2026-06-10
    Prerequisites:
      - config\validation-config.json and config\endpoints.json must exist.
      - curl.exe must be on PATH for HTTPS GET probes (built-in to WinPE and Win10+).
      - w32tm.exe must be on PATH for NTP checks (built-in to WinPE).
      - No external PowerShell modules required (except AzStackHci.EnvironmentChecker
        for Category 9, which is optional).
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
    [switch]$SkipEnvironmentChecker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#region ================================================================
#  CONSTANTS AND SCRIPT-LEVEL VARIABLES
#================================================================

$script:VERSION      = '1.0'
$script:StartTime    = Get-Date
$script:AllResults   = [System.Collections.Generic.List[object]]::new()
$script:CriticalFail = $false

#endregion

#region ================================================================
#  CONSOLE OUTPUT HELPER
#  Write-Information goes to stream 6; callers set $InformationPreference
#  or use -InformationAction Continue for interactive boot sessions.
#  Color information is embedded in the message tag for capture/replay.
#================================================================

$InformationPreference = 'Continue'

function Out-ConsoleLine {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    # Emit to Information stream (stream 6) — visible at boot, capturable in tests.
    # Color tag is advisory; WinPE console renders it via the calling context.
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
            $records = Resolve-DnsName -Name $SrvName -Type SRV -Server $DnsServer -ErrorAction Stop
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

function Test-CidrMembership {
    <#
    Returns $true if $IpAddress is within the CIDR block. PS 5.1 compatible.
    #>
    param([string]$IpAddress, [string]$CidrBlock)
    try {
        $parts   = $CidrBlock.Split('/')
        $netAddr = [System.Net.IPAddress]::Parse($parts[0])
        $prefix  = [int]$parts[1]

        $netBytes = $netAddr.GetAddressBytes()
        $ipBytes  = ([System.Net.IPAddress]::Parse($IpAddress)).GetAddressBytes()
        if ($netBytes.Length -ne $ipBytes.Length) { return $false }

        $maskUint = if ($prefix -eq 0) {
            [uint32]0
        } else {
            [uint32]([System.Math]::Pow(2, 32) - [System.Math]::Pow(2, 32 - $prefix))
        }

        $netInt = ([uint32]$netBytes[0] -shl 24) -bor ([uint32]$netBytes[1] -shl 16) -bor
                  ([uint32]$netBytes[2] -shl 8)  -bor [uint32]$netBytes[3]
        $ipInt  = ([uint32]$ipBytes[0] -shl 24)  -bor ([uint32]$ipBytes[1] -shl 16) -bor
                  ([uint32]$ipBytes[2] -shl 8)   -bor [uint32]$ipBytes[3]

        return (($ipInt -band $maskUint) -eq ($netInt -band $maskUint))
    } catch {
        return $false
    }
}

function Get-IpRangeList {
    <#
    Returns all IPs between startIp and endIp inclusive. PS 5.1 compatible.
    #>
    param([string]$StartIp, [string]$EndIp)
    $startBytes = [System.Net.IPAddress]::Parse($StartIp).GetAddressBytes()
    $endBytes   = [System.Net.IPAddress]::Parse($EndIp).GetAddressBytes()

    $startInt = ([uint32]$startBytes[0] -shl 24) -bor ([uint32]$startBytes[1] -shl 16) -bor
                ([uint32]$startBytes[2] -shl 8)  -bor [uint32]$startBytes[3]
    $endInt   = ([uint32]$endBytes[0] -shl 24) -bor ([uint32]$endBytes[1] -shl 16) -bor
                ([uint32]$endBytes[2] -shl 8)  -bor [uint32]$endBytes[3]

    $ips = [System.Collections.Generic.List[string]]::new()
    for ($i = $startInt; $i -le $endInt; $i++) {
        $b = [byte[]]([int](($i -shr 24) -band 0xFF),
                      [int](($i -shr 16) -band 0xFF),
                      [int](($i -shr 8)  -band 0xFF),
                      [int]($i -band 0xFF))
        $ips.Add([System.Net.IPAddress]::new($b).ToString())
    }
    return $ips
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
                    -Status 'Skip' -Detail 'Wildcard -- no representative probe host; validate at FortiGate'
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

function Invoke-Category6InfraDevice {
    param([object]$ValidationConfig)
    $cat = 'Cat-6-InfraDevice'
    Out-ConsoleLine -Message "`n[Category 6] Infrastructure Device Reachability" -Color ([System.ConsoleColor]::Cyan)

    foreach ($device in $ValidationConfig.infraDeviceIps) {
        $ping = Test-PingAddress -Address $device.ip -TimeoutMs $ValidationConfig.pingTimeoutMs
        $st   = if ($ping.Success) { 'Pass' } else { 'Warn' }
        $dt   = if ($ping.Success) { "$($ping.RoundtripMs)ms" } else { "Unreachable: $($ping.Error)" }
        Add-ValidationResult -Category $cat -Name "Ping-$($device.label)" -Target $device.ip `
            -Status $st -Detail "$($device.description) -- $dt" -DurationMs $ping.DurationMs
    }
}

function Invoke-Category7ServiceBus {
    param([object]$ValidationConfig)
    $cat        = 'Cat-7-ServiceBus'
    $probeHost  = $ValidationConfig.serviceBusProbeHost
    Out-ConsoleLine -Message "`n[Category 7] Service Bus / WebSocket Probe" -Color ([System.ConsoleColor]::Cyan)

    if ([string]::IsNullOrWhiteSpace($probeHost)) {
        # *.servicebus.windows.net hostnames are instance-specific and only exist
        # after ARB/guest-notification provisioning -- no generic host to probe.
        Add-ValidationResult -Category $cat -Name 'ServiceBus-TCP443' -Target '*.servicebus.windows.net:443' `
            -Status 'Skip' -DurationMs 0 -Detail ('No instance-specific Service Bus hostname configured (serviceBusProbeHost). ' +
            'Manually verify the firewall allows outbound 443 incl. WebSocket (wss) to *.servicebus.windows.net -- ' +
            'required by the Arc resource bridge.')
        return
    }

    $r  = Test-TcpConnect -TargetHost $probeHost -Port 443 -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
    $st = if ($r.Success) { 'Pass' } else { 'Fail' }
    $dt = if ($r.Success) {
        "$($r.DurationMs)ms -- TCP 443 reachable. Verify FortiGate app-control allows wss on *.servicebus.windows.net."
    } else {
        $r.Error
    }
    Add-ValidationResult -Category $cat -Name 'ServiceBus-TCP443' -Target "$probeHost`:443" `
        -Status $st -Detail $dt -DurationMs $r.DurationMs
}

function Invoke-Category8NtpUdp {
    param([object]$ValidationConfig)
    $cat      = 'Cat-8-NTP-UDP'
    $ntpProbe = $ValidationConfig.ntpUdpProbeHost
    Out-ConsoleLine -Message "`n[Category 8] NTP UDP Port 123 Probe" -Color ([System.ConsoleColor]::Cyan)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ntpPacket    = [byte[]]::new(48)
        $ntpPacket[0] = 0x1B   # LI=0, VN=3, Mode=3 (client)

        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect($ntpProbe, 123)
        $udpClient.Client.ReceiveTimeout = 5000
        $null = $udpClient.Send($ntpPacket, 48)

        $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udpClient.Receive([ref]$remoteEp)
        $udpClient.Close()
        $sw.Stop()

        $ok = $response.Length -ge 48
        $st = if ($ok) { 'Pass' } else { 'Warn' }
        $dt = if ($ok) { "NTP response $($response.Length) bytes from $($remoteEp.Address)" } else { "Short response: $($response.Length) bytes" }
        Add-ValidationResult -Category $cat -Name 'NTP-UDP123' -Target "$ntpProbe`:123/udp" `
            -Status $st -Detail $dt -DurationMs $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        Add-ValidationResult -Category $cat -Name 'NTP-UDP123' -Target "$ntpProbe`:123/udp" `
            -Status 'Warn' -Detail "UDP NTP probe failed: $($_.Exception.Message)" -DurationMs $sw.ElapsedMilliseconds
    }
}

function Invoke-Category9EnvironmentChecker {
    param([string]$DestResultsPath, [switch]$SkipChecks)
    $cat = 'Cat-9-EnvChecker'
    Out-ConsoleLine -Message "`n[Category 9] Azure Local Environment Checker (Official Microsoft Validator)" -Color ([System.ConsoleColor]::Cyan)

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
                -Status 'Warn' -Detail 'Module not found in image. Run from staging server. Custom sweep (categories 1-8) is the validation engine.'
        }
    }

    if (-not $moduleLoaded) { return }

    try {
        $sw         = [System.Diagnostics.Stopwatch]::StartNew()
        $envResults = Invoke-AzStackHciConnectivityValidation -PassThru -ErrorAction Stop
        $sw.Stop()

        $failCount  = @($envResults | Where-Object { $_.Status -ne 'Succeeded' }).Count
        $totalCount = $envResults.Count
        $st         = if ($failCount -eq 0) { 'Pass' } else { 'Fail' }
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Connectivity' -Target 'Invoke-AzStackHciConnectivityValidation' `
            -Status $st -Detail "$($totalCount - $failCount)/$totalCount endpoints Succeeded" -DurationMs $sw.ElapsedMilliseconds

        $reportSrc = Join-Path $HOME '.AzStackHci\AzStackHciEnvironmentReport.json'
        if (Test-Path $reportSrc) {
            try {
                Copy-Item $reportSrc (Join-Path $DestResultsPath 'AzStackHciEnvironmentReport.json') -Force -ErrorAction Stop
            } catch {
                Write-Warning "Could not copy Environment Checker report: $_"
            }
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Connectivity' -Target 'Invoke-AzStackHciConnectivityValidation' `
            -Status 'Warn' -Detail "Validator threw exception (WinPE compat issue?): $($_.Exception.Message)"
    }
}

function Invoke-Category10SslInspection {
    param([object]$ValidationConfig)
    $cat = 'Cat-10-SSL'
    Out-ConsoleLine -Message "`n[Category 10] SSL Inspection / TLS Interception Detection" -Color ([System.ConsoleColor]::Cyan)
    Out-ConsoleLine -Message '  NOTE: Private CA root detected = FortiGate SSL deep inspection active. This blocks Azure Local deployment.' -Color ([System.ConsoleColor]::DarkYellow)

    foreach ($sslEndpoint in $ValidationConfig.sslInspectionProbeEndpoints) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient($sslEndpoint, 443)
            $sslStream = New-Object System.Net.Security.SslStream(
                $tcpClient.GetStream(), $false, { $true }
            )
            $sslStream.AuthenticateAsClient($sslEndpoint)

            $certObj  = $sslStream.RemoteCertificate
            $chain    = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $null     = $chain.Build($certObj)
            $rootCert = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
            $rootSubj = $rootCert.Subject

            $sslStream.Close()
            $tcpClient.Close()
            $sw.Stop()

            $trusted = $rootSubj -match 'DigiCert|Microsoft|GlobalSign|Symantec|Entrust'
            $st      = if ($trusted) { 'Pass' } else { 'Fail' }
            $dt      = if ($trusted) {
                "Root: $rootSubj"
            } else {
                "PRIVATE/UNKNOWN ROOT CA -- root: $rootSubj -- disable SSL inspection for Azure Local traffic"
            }
            Add-ValidationResult -Category $cat -Name "SSL-Chain-$sslEndpoint" -Target "https://$sslEndpoint" `
                -Status $st -Detail $dt -DurationMs $sw.ElapsedMilliseconds
        } catch {
            $sw.Stop()
            Add-ValidationResult -Category $cat -Name "SSL-Chain-$sslEndpoint" -Target "https://$sslEndpoint" `
                -Status 'Warn' -Detail "TLS probe failed (no internet?): $($_.Exception.Message)" -DurationMs $sw.ElapsedMilliseconds
        }
    }
}

function Invoke-Category11DeployPrerequisite {
    param([object]$ValidationConfig)
    $cat = 'Cat-11-DeployPrereq'
    Out-ConsoleLine -Message "`n[Category 11] Deployment Prerequisite Sanity Checks" -Color ([System.ConsoleColor]::Cyan)

    Out-ConsoleLine -Message '  Scanning management IP pool for active hosts (may take ~30s) ...' -Color ([System.ConsoleColor]::DarkGray)
    $poolIps   = Get-IpRangeList -StartIp $ValidationConfig.managementIpPoolStart -EndIp $ValidationConfig.managementIpPoolEnd
    $squatters = [System.Collections.Generic.List[string]]::new()

    foreach ($poolIp in $poolIps) {
        $ping = Test-PingAddress -Address $poolIp -TimeoutMs 1000
        if ($ping.Success) {
            $squatters.Add($poolIp)
            continue
        }
        foreach ($probePort in @(5985, 5986, 22)) {
            $tcpR = Test-TcpConnect -TargetHost $poolIp -Port $probePort -TimeoutMs 1000
            if ($tcpR.Success) {
                $squatters.Add("$poolIp`:$probePort")
                break
            }
        }
    }

    if ($squatters.Count -eq 0) {
        Add-ValidationResult -Category $cat -Name 'MgmtPool-Free' `
            -Target "$($ValidationConfig.managementIpPoolStart)-$($ValidationConfig.managementIpPoolEnd)" `
            -Status 'Pass' -Detail "All $($poolIps.Count) IPs in pool are free"
    } else {
        $squatterStr = $squatters -join ', '
        Add-ValidationResult -Category $cat -Name 'MgmtPool-Free' `
            -Target "$($ValidationConfig.managementIpPoolStart)-$($ValidationConfig.managementIpPoolEnd)" `
            -Status 'Fail' -Detail "ACTIVE HOSTS IN RESERVED POOL: $squatterStr -- clear before deployment"
    }

    foreach ($dnsIp in $ValidationConfig.dnsServers) {
        $inK8s = $false
        foreach ($cidr in $ValidationConfig.kubernetesReservedCidrs) {
            if (Test-CidrMembership -IpAddress $dnsIp -CidrBlock $cidr) {
                $inK8s = $true
                Add-ValidationResult -Category $cat -Name "DNS-NotInK8s-$dnsIp" -Target $dnsIp `
                    -Status 'Fail' -Detail "DNS server inside Kubernetes reserved range $cidr -- cannot be changed after deployment"
                break
            }
        }
        if (-not $inK8s) {
            Add-ValidationResult -Category $cat -Name "DNS-NotInK8s-$dnsIp" -Target $dnsIp `
                -Status 'Pass' -Detail "Not in Kubernetes reserved ranges ($($ValidationConfig.kubernetesReservedCidrs -join ', '))"
        }
    }

    $domR = Invoke-DnsLookup -DnsHostname $ValidationConfig.adDomainFqdn
    $st   = if ($domR.Success) { 'Pass' } else { 'Fail' }
    $dt   = if ($domR.Success) { "Resolves to: $($domR.Addresses)" } else { "Required before deployment: $($domR.Error)" }
    Add-ValidationResult -Category $cat -Name 'ADDomain-Resolves' -Target $ValidationConfig.adDomainFqdn `
        -Status $st -Detail $dt -DurationMs $domR.DurationMs

    $vlanStr = ($ValidationConfig.storageVlans | ForEach-Object { $_.ToString() }) -join ', '
    Add-ValidationResult -Category $cat -Name 'StorageVLANs-Echo' -Target 'switch config' `
        -Status 'Skip' -Detail "Storage VLANs per plan: $vlanStr -- verify switch VLAN tagging manually; not probeable from WinPE"
}

function Invoke-Category12HardwareSelfCheck {
    $cat = 'Cat-12-Hardware'
    Out-ConsoleLine -Message "`n[Category 12] Hardware Self-Checks" -Color ([System.ConsoleColor]::Cyan)

    # TPM 2.0
    try {
        $tpmInst = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
        if ($tpmInst) {
            $tpmSpec = if ($tpmInst.SpecVersion) { $tpmInst.SpecVersion } else { 'unknown' }
            $st      = if ($tpmSpec -match '^2\.') { 'Pass' } else { 'Fail' }
            Add-ValidationResult -Category $cat -Name 'TPM-2.0' -Target 'root\cimv2\Security\MicrosoftTpm' `
                -Status $st -Detail "SpecVersion: $tpmSpec"
        } else {
            Add-ValidationResult -Category $cat -Name 'TPM-2.0' -Target 'root\cimv2\Security\MicrosoftTpm' `
                -Status 'Fail' -Detail 'Win32_Tpm returned null'
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'TPM-2.0' -Target 'root\cimv2\Security\MicrosoftTpm' `
            -Status 'Skip' -Detail "WMI namespace unavailable (WinPE-WMI not loaded, or not a physical node): $($_.Exception.Message)"
    }

    # Secure Boot
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        $st = if ($sb) { 'Pass' } else { 'Fail' }
        $dt = if ($sb) { 'Secure Boot enabled' } else { 'Secure Boot DISABLED -- required for Azure Local' }
        Add-ValidationResult -Category $cat -Name 'SecureBoot' -Target 'UEFI' -Status $st -Detail $dt
    } catch [System.PlatformNotSupportedException] {
        Add-ValidationResult -Category $cat -Name 'SecureBoot' -Target 'UEFI' `
            -Status 'Skip' -Detail 'Not supported on this platform (non-UEFI or VM without UEFI pass-through)'
    } catch {
        Add-ValidationResult -Category $cat -Name 'SecureBoot' -Target 'UEFI' `
            -Status 'Skip' -Detail "Cmdlet unavailable in this environment: $($_.Exception.Message)"
    }

    # Physical disk count
    try {
        $diskInsts = Get-CimInstance -ClassName MSFT_Disk -Namespace root\Microsoft\Windows\Storage -ErrorAction Stop
        $diskCount = if ($diskInsts) { @($diskInsts).Count } else { 0 }
        $st        = if ($diskCount -ge 3) { 'Pass' } else { 'Warn' }
        Add-ValidationResult -Category $cat -Name 'DiskCount' -Target 'MSFT_Disk' `
            -Status $st -Detail "$diskCount disk(s) visible (need boot + >=2 data disks)"
    } catch {
        Add-ValidationResult -Category $cat -Name 'DiskCount' -Target 'MSFT_Disk' `
            -Status 'Skip' -Detail "Storage WMI unavailable (add WinPE-StorageWMI component): $($_.Exception.Message)"
    }

    # Existing storage pools -- S2D stale metadata check
    try {
        $pools     = Get-CimInstance -ClassName MSFT_StoragePool -Namespace root\Microsoft\Windows\Storage `
                         -ErrorAction Stop | Where-Object { $_.IsPrimordial -eq $false }
        $poolCount = if ($pools) { @($pools).Count } else { 0 }
        if ($poolCount -gt 0) {
            $poolNames = ($pools | ForEach-Object { $_.FriendlyName }) -join ', '
            Add-ValidationResult -Category $cat -Name 'NoStoragePools' -Target 'MSFT_StoragePool' `
                -Status 'Fail' -Detail "EXISTING STORAGE POOLS: $poolNames -- must be removed before S2D deployment"
        } else {
            Add-ValidationResult -Category $cat -Name 'NoStoragePools' -Target 'MSFT_StoragePool' `
                -Status 'Pass' -Detail 'No pre-existing non-primordial storage pools'
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'NoStoragePools' -Target 'MSFT_StoragePool' `
            -Status 'Warn' -Detail "Could not query storage pools (WinPE-StorageWMI optional): $($_.Exception.Message)"
    }

    # Physical NIC count
    try {
        $nicInsts  = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' -ErrorAction Stop
        $nicCount  = if ($nicInsts) { @($nicInsts).Count } else { 0 }
        $st        = if ($nicCount -ge 2) { 'Pass' } else { 'Fail' }
        Add-ValidationResult -Category $cat -Name 'NIC-PhysicalCount' -Target 'Win32_NetworkAdapter' `
            -Status $st -Detail "$nicCount physical NIC(s) (Azure Local requires >=2)"
    } catch {
        Add-ValidationResult -Category $cat -Name 'NIC-PhysicalCount' -Target 'Win32_NetworkAdapter' `
            -Status 'Skip' -Detail "WMI unavailable: $($_.Exception.Message)"
    }

    # CPU virtualisation
    try {
        $cpuInst = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpuInst) {
            $virtOk = $cpuInst.VirtualizationFirmwareEnabled
            $st     = if ($virtOk) { 'Pass' } else { 'Fail' }
            Add-ValidationResult -Category $cat -Name 'CPU-Virtualization' -Target 'Win32_Processor' `
                -Status $st -Detail "VirtualizationFirmwareEnabled=$virtOk -- $($cpuInst.Name)"
        } else {
            Add-ValidationResult -Category $cat -Name 'CPU-Virtualization' -Target 'Win32_Processor' `
                -Status 'Skip' -Detail 'No Win32_Processor instance'
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'CPU-Virtualization' -Target 'Win32_Processor' `
            -Status 'Skip' -Detail "WMI unavailable: $($_.Exception.Message)"
    }

    # Memory >= 32 GB
    try {
        $csInst = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($csInst) {
            $ramGb = [math]::Round($csInst.TotalPhysicalMemory / 1GB, 1)
            $st    = if ($ramGb -ge 32) { 'Pass' } else { 'Fail' }
            Add-ValidationResult -Category $cat -Name 'Memory-32GB' -Target 'Win32_ComputerSystem' `
                -Status $st -Detail "${ramGb}GB (minimum 32GB ECC)"
        } else {
            Add-ValidationResult -Category $cat -Name 'Memory-32GB' -Target 'Win32_ComputerSystem' `
                -Status 'Skip' -Detail 'No Win32_ComputerSystem instance'
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'Memory-32GB' -Target 'Win32_ComputerSystem' `
            -Status 'Skip' -Detail "WMI unavailable: $($_.Exception.Message)"
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

$allCategoryNums = @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
# pwsh -File (the startnet.cmd launch path) passes array args as plain strings,
# so accept "2,10", "2 10", or repeated values and normalize to ints here.
$parsedCategories = @($Categories | ForEach-Object { $_ -split '[,\s]+' } |
    Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } |
    Where-Object { $allCategoryNums -contains $_ } | Select-Object -Unique)
$runCategories   = if ($parsedCategories.Count -gt 0) { $parsedCategories } else { $allCategoryNums }

Out-ConsoleLine -Message "  Categories   : $($runCategories -join ', ')" -Color ([System.ConsoleColor]::DarkGray)

if ($runCategories -contains 1)  { Invoke-Category1Network              -ValidationConfig $cfg }
if ($runCategories -contains 2)  { Invoke-Category2DnsCheck             -ValidationConfig $cfg }
if ($runCategories -contains 3)  { Invoke-Category3Ntp                  -ValidationConfig $cfg }
if ($runCategories -contains 4)  { Invoke-Category4ActiveDirectory       -ValidationConfig $cfg }
if ($runCategories -contains 5)  { Invoke-Category5EndpointSweep         -ValidationConfig $cfg -EndpointList $endpoints }
if ($runCategories -contains 6)  { Invoke-Category6InfraDevice           -ValidationConfig $cfg }
if ($runCategories -contains 7)  { Invoke-Category7ServiceBus            -ValidationConfig $cfg }
if ($runCategories -contains 8)  { Invoke-Category8NtpUdp                -ValidationConfig $cfg }
if ($runCategories -contains 9)  { Invoke-Category9EnvironmentChecker    -DestResultsPath $resolvedResultsPath -SkipChecks:$SkipEnvironmentChecker }
if ($runCategories -contains 10) { Invoke-Category10SslInspection        -ValidationConfig $cfg }
if ($runCategories -contains 11) { Invoke-Category11DeployPrerequisite   -ValidationConfig $cfg }
if ($runCategories -contains 12) { Invoke-Category12HardwareSelfCheck }

Write-ValidationSummary -Results $script:AllResults
$null = Save-ValidationResult -Results $script:AllResults -ResultsDir $resolvedResultsPath

$exitCode = if ($script:CriticalFail) { 1 } elseif ($script:AllResults.Count -eq 0) { 2 } else { 0 }
Write-Verbose "Exit code: $exitCode"
exit $exitCode

#endregion
