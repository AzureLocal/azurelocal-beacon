# AzL Beacon - network probes and the pure helpers around them.
# PowerShell 5.1 (WinPE) and 7 compatible. External commands go through thin wrappers
# (Invoke-Curl, Invoke-Nslookup) so unit tests can mock them.

#region ---- external command wrappers ----

function Invoke-Curl {
    <# Runs curl.exe. Returns @{ ExitCode; Output }. #>
    param([string[]]$Arguments)
    $out = & curl.exe @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = "$out".Trim() }
}

function Invoke-Nslookup {
    param([string[]]$Arguments)
    return (& nslookup.exe @Arguments 2>&1)
}

#endregion

#region ---- TCP / ICMP / DNS ----

function Test-TcpConnect {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 5000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $waited = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($waited) {
            $client.EndConnect($ar)
            $sw.Stop()
            return @{ Success = $true; DurationMs = $sw.ElapsedMilliseconds; Error = '' }
        }
        $sw.Stop()
        return @{ Success = $false; DurationMs = $sw.ElapsedMilliseconds; Error = 'Timeout' }
    } catch {
        $sw.Stop()
        return @{ Success = $false; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    } finally {
        if ($client) { $client.Close() }
    }
}

function Test-PingAddress {
    param([string]$Address, [int]$TimeoutMs = 2000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
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
        return @{ Success = $true; Addresses = $ips; AddressList = @($addrs | ForEach-Object { $_.ToString() }); DurationMs = $sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return @{ Success = $false; Addresses = ''; AddressList = @(); DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
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

function New-DnsQueryPacket {
    <# Builds a standard recursive A-record query. Pure; unit tested. #>
    param([string]$QueryName, [byte[]]$TransactionId = $null)
    if (-not $TransactionId) {
        $TransactionId = [byte[]]@((Get-Random -Minimum 1 -Maximum 255), (Get-Random -Minimum 1 -Maximum 255))
    }
    $flags = [byte[]]@(0x01, 0x00)
    $counts = [byte[]]@(0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    $qname = New-Object System.Collections.Generic.List[byte]
    foreach ($label in $QueryName.Split('.')) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        $qname.Add([byte]$bytes.Length)
        foreach ($b in $bytes) { $qname.Add($b) }
    }
    $qname.Add(0x00)
    return [byte[]]($TransactionId + $flags + $counts + $qname.ToArray() + [byte[]]@(0x00, 0x01, 0x00, 0x01))
}

function Get-DnsAnswerCount {
    <# Answer count from a DNS response header, or -1 when the packet is too short. #>
    param([byte[]]$Response)
    if ($null -eq $Response -or $Response.Length -lt 8) { return -1 }
    return (([int]$Response[6] -shl 8) -bor [int]$Response[7])
}

function Invoke-DirectDnsQuery {
    # Raw UDP DNS A query: works in WinPE where Resolve-DnsName may be missing.
    param([string]$DnsServer, [string]$QueryName, [int]$TimeoutMs = 3000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $udpClient = $null
    try {
        $query = New-DnsQueryPacket -QueryName $QueryName
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect($DnsServer, 53)
        $udpClient.Client.ReceiveTimeout = $TimeoutMs
        $null = $udpClient.Send($query, $query.Length)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udpClient.Receive([ref]$remote)
        $sw.Stop()
        $answerCount = Get-DnsAnswerCount -Response $response
        if ($answerCount -lt 0) {
            return @{ Success = $false; Addresses = ''; DurationMs = $sw.ElapsedMilliseconds; Error = 'DNS response too short' }
        }
        return @{ Success = ($answerCount -gt 0); Addresses = "answers=$answerCount"; DurationMs = $sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return @{ Success = $false; Addresses = ''; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    } finally {
        if ($udpClient) { $udpClient.Close() }
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
    }
    try {
        $output = Invoke-Nslookup -Arguments @('-type=SRV', $SrvName, $DnsServer)
        $found = [bool]($output -match 'svr hostname')
        return @{ Success = $found; Detail = 'via nslookup fallback'; Error = '' }
    } catch {
        return @{ Success = $false; Detail = ''; Error = $_.Exception.Message }
    }
}

#endregion

#region ---- address classification ----

function ConvertTo-IPv4UInt32 {
    param([string]$Address)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $null }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $b = $ip.GetAddressBytes()
    return ([uint32]$b[0] * 16777216) + ([uint32]$b[1] * 65536) + ([uint32]$b[2] * 256) + [uint32]$b[3]
}

function Test-PublicIPv4 {
    <#
    True when the address is a routable public IPv4 address. False for RFC 1918, loopback,
    link-local, CGNAT (100.64/10), multicast/reserved, 0/8 and documentation ranges.
    $null for input that is not IPv4.
    #>
    param([string]$Address)
    $n = ConvertTo-IPv4UInt32 $Address
    if ($null -eq $n) { return $null }
    $ranges = @(
        @('0.0.0.0', 8), @('10.0.0.0', 8), @('100.64.0.0', 10), @('127.0.0.0', 8),
        @('169.254.0.0', 16), @('172.16.0.0', 12), @('192.0.0.0', 24), @('192.0.2.0', 24),
        @('192.168.0.0', 16), @('198.18.0.0', 15), @('198.51.100.0', 24), @('203.0.113.0', 24),
        @('224.0.0.0', 4), @('240.0.0.0', 4)
    )
    foreach ($r in $ranges) {
        $base = ConvertTo-IPv4UInt32 $r[0]
        $size = [math]::Pow(2, 32 - $r[1])
        if ($n -ge $base -and $n -lt ($base + $size)) { return $false }
    }
    return $true
}

#endregion

#region ---- proxy handling ----

function Test-ProxyBypass {
    <#
    Decides whether a host skips the proxy. Accepts the usual list forms:
    'localhost', '*.contoso.local', '.contoso.local', 'contoso.local', '10.0.0.0/8', '<local>'.
    #>
    param([string]$TargetHost, [string[]]$BypassList)
    $h = $TargetHost.ToLowerInvariant()
    foreach ($raw in @($BypassList)) {
        $p = "$raw".Trim().ToLowerInvariant()
        if ($p -eq '') { continue }
        if ($p -eq '<local>') { if ($h -notmatch '\.') { return $true }; continue }
        if ($p -match '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') {
            $hn = ConvertTo-IPv4UInt32 $h
            if ($null -ne $hn) {
                $base = ConvertTo-IPv4UInt32 $Matches[1]
                $size = [math]::Pow(2, 32 - [int]$Matches[3])
                if ($hn -ge $base -and $hn -lt ($base + $size)) { return $true }
            }
            continue
        }
        if ($p.StartsWith('*.')) { $suffix = $p.Substring(1) }       # '.contoso.local'
        elseif ($p.StartsWith('.')) { $suffix = $p }
        else { $suffix = $null }
        if ($null -ne $suffix) {
            if ($h.EndsWith($suffix) -or $h -eq $suffix.TrimStart('.')) { return $true }
            continue
        }
        if ($h -eq $p -or $h.EndsWith('.' + $p)) { return $true }
    }
    return $false
}

function Get-ProbePlan {
    <#
    Decides HOW one endpoint entry is probed. Returns @{ Action; Reason; Host; Port; UseProxy }
    Action: Probe | Skip. Pure function; the caller does the network work.
    $GatewayMode true = Arc gateway in use: rows that the gateway carries are not probed directly.
    #>
    param(
        [Parameter(Mandatory)] [object]$Endpoint,
        [string]$ProxyUrl = '',
        [string[]]$ProxyBypass = @(),
        [bool]$GatewayMode = $false,
        [string]$GatewayFqdn = '',
        [string]$KeyVaultFqdn = ''
    )
    $plan = @{ Action = 'Probe'; Reason = ''; Host = $Endpoint.host; Port = [int]$Endpoint.port; UseProxy = $false }

    if (-not $Endpoint.probe) {
        $plan.Action = 'Skip'
        $plan.Reason = $Endpoint.skipReason
        return $plan
    }
    if ($Endpoint.placeholder -eq 'arcGateway') {
        if ($GatewayFqdn) { $plan.Host = $GatewayFqdn }
        else { $plan.Action = 'Skip'; $plan.Reason = 'Arc gateway not configured (arcGatewayFqdn is empty)'; return $plan }
    } elseif ($Endpoint.placeholder -eq 'keyVault') {
        if ($KeyVaultFqdn) { $plan.Host = $KeyVaultFqdn }
        else { $plan.Action = 'Skip'; $plan.Reason = 'Key Vault name not configured (keyVaultFqdn is empty)'; return $plan }
    } elseif ($Endpoint.wildcard) {
        if ($Endpoint.probeHost) { $plan.Host = $Endpoint.probeHost }
        else { $plan.Action = 'Skip'; $plan.Reason = 'Wildcard with no representative host; validate at the firewall'; return $plan }
    }
    if ($GatewayMode -and $Endpoint.arcGateway -eq 'yes') {
        $plan.Action = 'Skip'
        $plan.Reason = 'Carried by the Arc gateway after registration; not required directly'
        return $plan
    }
    if ($Endpoint.protocol -eq 'UDP') {
        $plan.Action = 'Skip'
        $plan.Reason = 'UDP/123 is checked by the dedicated NTP check'
        return $plan
    }
    if ($ProxyUrl -and -not (Test-ProxyBypass -TargetHost $plan.Host -BypassList $ProxyBypass)) {
        $plan.UseProxy = $true
    }
    return $plan
}

#endregion

#region ---- HTTPS probe (curl.exe) ----

function Get-CurlArguments {
    <# Argument list for the HTTP(S) probe. Pure. Any HTTP status means the transport worked. #>
    param(
        [Parameter(Mandatory)] [string]$Url,
        [int]$TimeoutSeconds = 10,
        [string]$ProxyUrl = '',
        [string[]]$ProxyBypass = @()
    )
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('--silent', '--max-time', "$TimeoutSeconds", '--output', 'NUL', '--write-out', '%{http_code}', '--insecure')) { $a.Add($x) }
    if ($ProxyUrl) {
        $a.Add('--proxy'); $a.Add($ProxyUrl)
        $a.Add('--proxytunnel')
        $np = @($ProxyBypass | Where-Object { $_ -and $_ -ne '<local>' } | ForEach-Object { $_.TrimStart('*') })
        if ($np.Count -gt 0) { $a.Add('--noproxy'); $a.Add(($np -join ',')) }
    }
    $a.Add($Url)
    return $a.ToArray()
}

function Invoke-DotNetHttpProbe {
    <#
    HTTP(S) probe with System.Net.HttpWebRequest for images without curl.exe (WinPE does not ship it).
    Any HTTP status (including 4xx/5xx) means the transport worked. Certificates are not validated here
    (same as curl --insecure); TLS inspection is judged separately from the chain.
    Returns @{ Ok; HttpCode; Error }.
    #>
    param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSeconds = 10, [string]$ProxyUrl = '')
    $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        Enable-BeaconTls12
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSeconds * 1000
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'AzL-Beacon'
        if ($ProxyUrl) { $req.Proxy = New-Object System.Net.WebProxy($ProxyUrl, $false) } else { $req.Proxy = $null }
        $resp = $null
        try {
            $resp = $req.GetResponse()
            return @{ Ok = $true; HttpCode = [int]$resp.StatusCode; Error = '' }
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) { return @{ Ok = $true; HttpCode = [int]$r.StatusCode; Error = '' } }
            return @{ Ok = $false; HttpCode = 0; Error = $_.Exception.Message }
        } finally {
            if ($resp) { $resp.Close() }
        }
    } catch {
        return @{ Ok = $false; HttpCode = 0; Error = $_.Exception.Message }
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

function Test-HttpsGet {
    <# Probes https://host:port/path with curl.exe. Returns @{ Success; HttpCode; DurationMs; Error }. #>
    param(
        [string]$TargetHost,
        [int]$Port = 443,
        [string]$Path = '/',
        [string]$Scheme = 'https',
        [int]$TimeoutSeconds = 10,
        [string]$ProxyUrl = '',
        [string[]]$ProxyBypass = @()
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $Path) { $Path = '/' }
        $url = '{0}://{1}:{2}{3}' -f $Scheme, $TargetHost, $Port, $Path
        if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
            # WinPE has no curl.exe: use the .NET probe so critical endpoints are not failed for a missing tool.
            $d = Invoke-DotNetHttpProbe -Url $url -TimeoutSeconds $TimeoutSeconds -ProxyUrl $ProxyUrl
            $sw.Stop()
            $dErr = ''
            if (-not $d.Ok) { $dErr = "dotnet probe: $($d.Error)" }
            return @{ Success = $d.Ok; HttpCode = $d.HttpCode; DurationMs = $sw.ElapsedMilliseconds; Error = $dErr }
        }
        $curlArgs = Get-CurlArguments -Url $url -TimeoutSeconds $TimeoutSeconds -ProxyUrl $ProxyUrl -ProxyBypass $ProxyBypass
        $r = Invoke-Curl -Arguments $curlArgs
        $sw.Stop()
        $httpCode = 0
        if ($r.Output -match '(\d{3})$') { $httpCode = [int]$Matches[1] }
        $success = ($r.ExitCode -eq 0 -and $httpCode -gt 0)
        $errMsg = ''
        if (-not $success) { $errMsg = "curl exit=$($r.ExitCode) http=$httpCode" }
        return @{ Success = $success; HttpCode = $httpCode; DurationMs = $sw.ElapsedMilliseconds; Error = $errMsg }
    } catch {
        $sw.Stop()
        return @{ Success = $false; HttpCode = 0; DurationMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

#endregion

#region ---- UDP and NTP ----

function Test-UdpPort {
    <#
    Sends a datagram and reports what came back. UDP cannot prove 'open':
      Responded   - a reply arrived (open)
      Refused     - ICMP port unreachable (closed)
      NoResponse  - silence (open|filtered; cannot tell)
    #>
    param([string]$TargetHost, [int]$Port, [byte[]]$Payload = @(0), [int]$TimeoutMs = 2000)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($TargetHost, $Port)
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $null = $udp.Send($Payload, $Payload.Length)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remote)
        return @{ State = 'Responded'; Bytes = $resp.Length; Response = $resp; Error = '' }
    } catch [System.Net.Sockets.SocketException] {
        $code = $_.Exception.SocketErrorCode.ToString()
        if ($code -eq 'ConnectionReset') { return @{ State = 'Refused'; Bytes = 0; Response = $null; Error = 'ICMP port unreachable' } }
        if ($code -eq 'TimedOut') { return @{ State = 'NoResponse'; Bytes = 0; Response = $null; Error = 'no reply' } }
        return @{ State = 'Error'; Bytes = 0; Response = $null; Error = $_.Exception.Message }
    } catch {
        return @{ State = 'Error'; Bytes = 0; Response = $null; Error = $_.Exception.Message }
    } finally {
        if ($udp) { $udp.Close() }
    }
}

function New-NtpRequest {
    <# 48-byte SNTP client request (LI=0, VN=4, Mode=3). #>
    $p = New-Object byte[] 48
    $p[0] = 0x23
    return $p
}

function ConvertFrom-NtpResponse {
    <# Server transmit timestamp (bytes 40-47) -> UTC DateTime; $null when malformed. #>
    param([byte[]]$Response)
    if ($null -eq $Response -or $Response.Length -lt 48) { return $null }
    $mode = $Response[0] -band 0x07
    if ($mode -ne 4 -and $mode -ne 5) { return $null }
    $secs = ([uint64]$Response[40] * 16777216) + ([uint64]$Response[41] * 65536) + ([uint64]$Response[42] * 256) + [uint64]$Response[43]
    $frac = ([uint64]$Response[44] * 16777216) + ([uint64]$Response[45] * 65536) + ([uint64]$Response[46] * 256) + [uint64]$Response[47]
    if ($secs -eq 0) { return $null }
    $epoch = New-Object DateTime 1900, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return $epoch.AddSeconds([double]$secs).AddMilliseconds(([double]$frac / 4294967296.0) * 1000)
}

function Invoke-NtpQuery {
    <# Returns @{ Success; OffsetSeconds; ServerTimeUtc; Error }. OffsetSeconds = server - local clock. #>
    param([string]$Server, [int]$TimeoutMs = 2500)
    $r = Test-UdpPort -TargetHost $Server -Port 123 -Payload (New-NtpRequest) -TimeoutMs $TimeoutMs
    if ($r.State -ne 'Responded') {
        return @{ Success = $false; OffsetSeconds = 0; ServerTimeUtc = $null; Error = "$($r.State): $($r.Error)" }
    }
    $t = ConvertFrom-NtpResponse -Response $r.Response
    if ($null -eq $t) { return @{ Success = $false; OffsetSeconds = 0; ServerTimeUtc = $null; Error = 'malformed NTP reply' } }
    $offset = [math]::Round(($t - [DateTime]::UtcNow).TotalSeconds, 1)
    return @{ Success = $true; OffsetSeconds = $offset; ServerTimeUtc = $t; Error = '' }
}

#endregion

#region ---- TLS inspection ----

# Issuers/roots expected on the certificate chain of Microsoft endpoints. A chain that contains none
# of these is almost always a re-signing (HTTPS-inspecting) proxy or firewall.
$script:ExpectedMicrosoftChainPatterns = @(
    'Microsoft RSA Root Certificate Authority 2017',
    'Microsoft ECC Root Certificate Authority 2017',
    'Microsoft Root Certificate Authority 20(10|11)',
    'Microsoft Azure (RSA|ECC) TLS Issuing CA',
    'Microsoft Azure TLS Issuing CA',
    'Microsoft (RSA|ECC) TLS (CA|Issuing CA)',
    'Microsoft IT TLS CA',
    'DigiCert Global Root (G2|CA|G3)',
    'DigiCert (Global G2 )?TLS (RSA|ECC)',
    'Baltimore CyberTrust Root',
    'GlobalSign'
)

function Get-TlsInspectionVerdict {
    <#
    Pure. Input: subject and issuer names seen on the chain (leaf first).
    Returns @{ Verdict = 'Expected'|'Suspected'|'Unknown'; Detail }.
    #>
    param([string[]]$Subjects = @(), [string[]]$Issuers = @())
    $names = @($Subjects) + @($Issuers) | Where-Object { $_ }
    if (@($names).Count -eq 0) { return @{ Verdict = 'Unknown'; Detail = 'no certificate chain captured' } }
    foreach ($n in $names) {
        foreach ($pat in $script:ExpectedMicrosoftChainPatterns) {
            if ($n -match $pat) { return @{ Verdict = 'Expected'; Detail = "chain contains '$pat'" } }
        }
    }
    $leafIssuer = @($Issuers)[0]
    return @{ Verdict = 'Suspected'; Detail = "leaf issuer '$leafIssuer' is not a known Microsoft/DigiCert issuer" }
}

function Get-TlsCertificateChain {
    <#
    Opens TCP (optionally through an HTTP CONNECT proxy), does a TLS 1.2 handshake with SslStream,
    and records the certificate chain the server presented. Certificate trust is NOT enforced
    (the callback accepts everything) because the goal is to READ the chain, even when the WinPE
    root store lacks the Microsoft roots. Returns @{ Success; Subjects; Issuers; Error }.
    #>
    param([string]$TargetHost, [int]$Port = 443, [int]$TimeoutMs = 8000, [string]$ProxyUrl = '')
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connectHost = $TargetHost
        $connectPort = $Port
        if ($ProxyUrl) {
            $pu = [System.Uri]$ProxyUrl
            $connectHost = $pu.Host
            $connectPort = $pu.Port
        }
        $ar = $client.BeginConnect($connectHost, $connectPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { throw 'connect timeout' }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        if ($ProxyUrl) {
            $req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT ${TargetHost}:${Port} HTTP/1.1`r`nHost: ${TargetHost}:${Port}`r`n`r`n")
            $stream.Write($req, 0, $req.Length)
            $buf = New-Object byte[] 1024
            $n = $stream.Read($buf, 0, $buf.Length)
            $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            if ($head -notmatch '^HTTP/1\.[01] 200') { throw "proxy CONNECT refused: $(($head -split "`r`n")[0])" }
        }

        $seen = New-Object System.Collections.Generic.List[object]
        $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
            $cert = $args[1]; $chain = $args[2]
            if ($cert) { $seen.Add(@{ Subject = $cert.Subject; Issuer = $cert.Issuer }) }
            if ($chain) {
                foreach ($el in $chain.ChainElements) {
                    $seen.Add(@{ Subject = $el.Certificate.Subject; Issuer = $el.Certificate.Issuer })
                }
            }
            return $true
        }
        $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
        try {
            $ssl.AuthenticateAsClient($TargetHost, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        } finally {
            $ssl.Dispose()
        }
        return @{
            Success  = $true
            Subjects = @($seen | ForEach-Object { $_.Subject })
            Issuers  = @($seen | ForEach-Object { $_.Issuer })
            Error    = ''
        }
    } catch {
        return @{ Success = $false; Subjects = @(); Issuers = @(); Error = $_.Exception.Message }
    } finally {
        if ($client) { $client.Close() }
    }
}

#endregion
