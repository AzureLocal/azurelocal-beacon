#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\lib\Beacon.Version.ps1')
    . (Join-Path $script:Root 'src\lib\Beacon.Common.ps1')
    . (Join-Path $script:Root 'src\lib\Beacon.Net.ps1')
}

Describe 'Test-PublicIPv4' {
    It '<Ip> public = <Expected>' -ForEach @(
        @{ Ip = '20.42.65.90'; Expected = $true }
        @{ Ip = '8.8.8.8'; Expected = $true }
        @{ Ip = '10.1.2.3'; Expected = $false }
        @{ Ip = '172.16.0.1'; Expected = $false }
        @{ Ip = '172.31.255.255'; Expected = $false }
        @{ Ip = '172.32.0.1'; Expected = $true }
        @{ Ip = '192.168.1.1'; Expected = $false }
        @{ Ip = '100.64.0.1'; Expected = $false }
        @{ Ip = '100.128.0.1'; Expected = $true }
        @{ Ip = '127.0.0.1'; Expected = $false }
        @{ Ip = '169.254.10.10'; Expected = $false }
        @{ Ip = '192.0.2.5'; Expected = $false }
        @{ Ip = '224.0.0.1'; Expected = $false }
        @{ Ip = '0.0.0.0'; Expected = $false }
    ) { Test-PublicIPv4 $Ip | Should -Be $Expected }
    It 'returns $null for non IPv4 input' -ForEach @('not-an-ip', '::1', '') {
        Test-PublicIPv4 $_ | Should -BeNullOrEmpty
    }
}

Describe 'Test-ProxyBypass' {
    It 'matches <Pattern> against <Target> = <Expected>' -ForEach @(
        @{ Pattern = 'localhost'; Target = 'localhost'; Expected = $true }
        @{ Pattern = '*.corp.example.com'; Target = 'a.corp.example.com'; Expected = $true }
        @{ Pattern = '*.corp.example.com'; Target = 'corp.example.com'; Expected = $true }
        @{ Pattern = '.corp.example.com'; Target = 'x.corp.example.com'; Expected = $true }
        @{ Pattern = 'corp.example.com'; Target = 'x.corp.example.com'; Expected = $true }
        @{ Pattern = 'corp.example.com'; Target = 'notcorp.example.com'; Expected = $false }
        @{ Pattern = '10.0.0.0/8'; Target = '10.20.30.40'; Expected = $true }
        @{ Pattern = '10.0.0.0/8'; Target = '11.0.0.1'; Expected = $false }
        @{ Pattern = '<local>'; Target = 'intranet'; Expected = $true }
        @{ Pattern = '<local>'; Target = 'a.example.com'; Expected = $false }
    ) {
        Test-ProxyBypass -TargetHost $Target -BypassList @($Pattern) | Should -Be $Expected
    }
    It 'is false for an empty list' {
        Test-ProxyBypass -TargetHost 'a.example.com' -BypassList @() | Should -BeFalse
    }
}

Describe 'Get-CurlArguments' {
    It 'builds a plain probe without proxy flags' {
        $a = Get-CurlArguments -Url 'https://x.example.com:443/' -TimeoutSeconds 7
        $a | Should -Contain '--max-time'
        $a[$a.IndexOf('--max-time') + 1] | Should -Be '7'
        $a | Should -Not -Contain '--proxy'
        $a[-1] | Should -Be 'https://x.example.com:443/'
    }
    It 'adds proxy, tunnel and noproxy list' {
        $a = Get-CurlArguments -Url 'https://x.example.com/' -ProxyUrl 'http://proxy.example.com:8080' -ProxyBypass @('*.corp.example.com', '<local>', '10.0.0.0/8')
        $a[$a.IndexOf('--proxy') + 1] | Should -Be 'http://proxy.example.com:8080'
        $a | Should -Contain '--proxytunnel'
        $a[$a.IndexOf('--noproxy') + 1] | Should -Be '.corp.example.com,10.0.0.0/8'
    }
}

Describe 'Test-HttpsGet' {
    It 'treats any HTTP status with curl exit 0 as success' {
        Mock Get-Command { [pscustomobject]@{ Name = 'curl.exe' } } -ParameterFilter { $Name -eq 'curl.exe' }
        Mock Invoke-Curl { @{ ExitCode = 0; Output = '404' } }
        $r = Test-HttpsGet -TargetHost 'x.example.com'
        $r.Success | Should -BeTrue
        $r.HttpCode | Should -Be 404
    }
    It 'fails on a curl error even with output' {
        Mock Get-Command { [pscustomobject]@{ Name = 'curl.exe' } } -ParameterFilter { $Name -eq 'curl.exe' }
        Mock Invoke-Curl { @{ ExitCode = 35; Output = '000' } }
        $r = Test-HttpsGet -TargetHost 'x.example.com'
        $r.Success | Should -BeFalse
        $r.Error | Should -Match 'exit=35'
    }
    It 'falls back to the .NET probe when curl.exe is missing (WinPE)' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'curl.exe' }
        Mock Invoke-DotNetHttpProbe { @{ Ok = $true; HttpCode = 403; Error = '' } }
        Mock Invoke-Curl { throw 'curl must not be called' }
        $r = Test-HttpsGet -TargetHost 'x.example.com' -ProxyUrl 'http://proxy.example.com:8080'
        $r.Success | Should -BeTrue
        $r.HttpCode | Should -Be 403
        Should -Invoke Invoke-DotNetHttpProbe -ParameterFilter { $Url -eq 'https://x.example.com:443/' -and $ProxyUrl -eq 'http://proxy.example.com:8080' }
    }
    It 'reports a failing .NET probe with its error' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'curl.exe' }
        Mock Invoke-DotNetHttpProbe { @{ Ok = $false; HttpCode = 0; Error = 'timed out' } }
        (Test-HttpsGet -TargetHost 'x.example.com').Error | Should -Match 'dotnet probe: timed out'
    }
    It 'passes proxy arguments through to curl' {
        Mock Get-Command { [pscustomobject]@{ Name = 'curl.exe' } } -ParameterFilter { $Name -eq 'curl.exe' }
        Mock Invoke-Curl { @{ ExitCode = 0; Output = '200' } }
        $null = Test-HttpsGet -TargetHost 'x.example.com' -ProxyUrl 'http://proxy.example.com:8080'
        Should -Invoke Invoke-Curl -ParameterFilter { $Arguments -contains '--proxy' -and $Arguments -contains 'http://proxy.example.com:8080' }
    }
}

Describe 'Invoke-DotNetHttpProbe (real loopback listener)' {
    BeforeAll {
        $script:port = Get-Random -Minimum 20000 -Maximum 40000
        $script:listener = New-Object System.Net.HttpListener
        $script:listener.Prefixes.Add("http://127.0.0.1:$($script:port)/")
        $script:listener.Start()
        $script:job = Start-ThreadJob -ScriptBlock {
            param($l)
            while ($l.IsListening) {
                try {
                    $ctx = $l.GetContext()
                    $ctx.Response.StatusCode = if ($ctx.Request.Url.AbsolutePath -eq '/missing') { 404 } else { 200 }
                    $ctx.Response.Close()
                } catch { break }
            }
        } -ArgumentList $script:listener
    }
    AfterAll {
        $script:listener.Stop()
        Remove-Job $script:job -Force -ErrorAction SilentlyContinue
    }
    It 'reports a 200 as success' {
        $r = Invoke-DotNetHttpProbe -Url "http://127.0.0.1:$($script:port)/" -TimeoutSeconds 5
        $r.Ok | Should -BeTrue
        $r.HttpCode | Should -Be 200
    }
    It 'treats a 404 as transport success (any HTTP answer counts)' {
        $r = Invoke-DotNetHttpProbe -Url "http://127.0.0.1:$($script:port)/missing" -TimeoutSeconds 5
        $r.Ok | Should -BeTrue
        $r.HttpCode | Should -Be 404
    }
    It 'fails for a closed port' {
        (Invoke-DotNetHttpProbe -Url 'http://127.0.0.1:1/' -TimeoutSeconds 2).Ok | Should -BeFalse
    }
    It 'restores the global certificate callback' {
        $before = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        $null = Invoke-DotNetHttpProbe -Url "http://127.0.0.1:$($script:port)/" -TimeoutSeconds 5
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback | Should -Be $before
    }
}

Describe 'Test-DnsSrvRecord' {
    It 'uses Resolve-DnsName when available' {
        Mock Get-Command { [pscustomobject]@{ Name = 'Resolve-DnsName' } } -ParameterFilter { $Name -eq 'Resolve-DnsName' }
        function Resolve-DnsName { param($Name, $Type, $Server, $ErrorAction) @([pscustomobject]@{ QueryType = 'SRV' }, [pscustomobject]@{ QueryType = 'SRV' }) }
        $r = Test-DnsSrvRecord -SrvName '_ldap._tcp.dc._msdcs.corp.example.com' -DnsServer '192.0.2.10'
        $r.Success | Should -BeTrue
        $r.Detail | Should -Match '2'
    }
    It 'falls back to nslookup when Resolve-DnsName is missing (WinPE)' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Resolve-DnsName' }
        Mock Invoke-Nslookup { @('_ldap._tcp.dc._msdcs.corp.example.com', 'svr hostname = dc01.corp.example.com') }
        (Test-DnsSrvRecord -SrvName 'x' -DnsServer '192.0.2.10').Success | Should -BeTrue
        Should -Invoke Invoke-Nslookup -Times 1
    }
    It 'fails on nslookup without an answer' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Resolve-DnsName' }
        Mock Invoke-Nslookup { @('*** Can''t find x: Non-existent domain') }
        (Test-DnsSrvRecord -SrvName 'x' -DnsServer '192.0.2.10').Success | Should -BeFalse
    }
}

Describe 'DNS packet helpers' {
    It 'builds a query with the right header, labels and type/class' {
        $p = New-DnsQueryPacket -QueryName 'management.azure.com' -TransactionId ([byte[]]@(0x12, 0x34))
        $p[0] | Should -Be 0x12
        $p[1] | Should -Be 0x34
        $p[2] | Should -Be 0x01   # RD
        $p[5] | Should -Be 0x01   # QDCOUNT = 1
        $p[12] | Should -Be 10    # length of 'management'
        $p[$p.Length - 1] | Should -Be 0x01
        $p[$p.Length - 3] | Should -Be 0x01
        $p[$p.Length - 5] | Should -Be 0x00
    }
    It 'reads the answer count' {
        $resp = New-Object byte[] 12
        $resp[7] = 3
        Get-DnsAnswerCount -Response $resp | Should -Be 3
        Get-DnsAnswerCount -Response ([byte[]]@(1, 2)) | Should -Be -1
    }
}

Describe 'NTP helpers' {
    It 'builds a 48 byte SNTP client request' {
        $r = New-NtpRequest
        $r.Length | Should -Be 48
        $r[0] | Should -Be 0x23
    }
    It 'decodes the transmit timestamp of a server reply' {
        $resp = New-Object byte[] 48
        $resp[0] = 0x24   # LI 0, VN 4, mode 4 (server)
        # 2026-01-01T00:00:00Z = 3,976,992,000 seconds since 1900-01-01 = 0xECC4_1B80? compute below
        $secs = [uint64]([DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) - [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
        $b = [BitConverter]::GetBytes([uint32]$secs)
        [Array]::Reverse($b)
        [Array]::Copy($b, 0, $resp, 40, 4)
        $t = ConvertFrom-NtpResponse -Response $resp
        $t.Year | Should -Be 2026
        $t.Month | Should -Be 1
        $t.Kind | Should -Be 'Utc'
    }
    It 'rejects short, wrong-mode and zero-timestamp replies' {
        ConvertFrom-NtpResponse -Response (New-Object byte[] 10) | Should -BeNullOrEmpty
        $bad = New-Object byte[] 48; $bad[0] = 0x23
        ConvertFrom-NtpResponse -Response $bad | Should -BeNullOrEmpty
        $zero = New-Object byte[] 48; $zero[0] = 0x24
        ConvertFrom-NtpResponse -Response $zero | Should -BeNullOrEmpty
    }
    It 'computes the offset against the local clock' {
        $server = [DateTime]::UtcNow.AddSeconds(600)
        $resp = New-Object byte[] 48
        $resp[0] = 0x24
        $secs = [uint32]($server - [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
        $b = [BitConverter]::GetBytes($secs); [Array]::Reverse($b); [Array]::Copy($b, 0, $resp, 40, 4)
        Mock Test-UdpPort { @{ State = 'Responded'; Bytes = 48; Response = $resp; Error = '' } }
        $q = Invoke-NtpQuery -Server '192.0.2.10'
        $q.Success | Should -BeTrue
        $q.OffsetSeconds | Should -BeGreaterThan 590
        $q.OffsetSeconds | Should -BeLessThan 610
    }
    It 'reports no reply' {
        Mock Test-UdpPort { @{ State = 'NoResponse'; Bytes = 0; Response = $null; Error = 'no reply' } }
        (Invoke-NtpQuery -Server '192.0.2.10').Success | Should -BeFalse
    }
    It 'Get-ClockSkewVerdict honours the 5 minute Kerberos tolerance' {
        Get-ClockSkewVerdict -OffsetSeconds 12 | Should -Be 'Pass'
        Get-ClockSkewVerdict -OffsetSeconds -299 | Should -Be 'Pass'
        Get-ClockSkewVerdict -OffsetSeconds 301 | Should -Be 'Warn'
        Get-ClockSkewVerdict -OffsetSeconds -3600 | Should -Be 'Warn'
    }
}

Describe 'Get-TlsInspectionVerdict' {
    It 'accepts a Microsoft chain' {
        $v = Get-TlsInspectionVerdict -Subjects @('CN=management.azure.com', 'CN=Microsoft Azure RSA TLS Issuing CA 03, O=Microsoft Corporation') -Issuers @('CN=Microsoft Azure RSA TLS Issuing CA 03, O=Microsoft Corporation', 'CN=DigiCert Global Root G2')
        $v.Verdict | Should -Be 'Expected'
    }
    It 'accepts a DigiCert chain' {
        (Get-TlsInspectionVerdict -Subjects @('CN=x') -Issuers @('CN=DigiCert Global Root G2, OU=www.digicert.com')).Verdict | Should -Be 'Expected'
    }
    It 'flags a re-signing proxy' {
        $v = Get-TlsInspectionVerdict -Subjects @('CN=login.microsoftonline.com', 'CN=Example Corp Inspection CA') -Issuers @('CN=Example Corp Inspection CA', 'CN=Example Corp Root')
        $v.Verdict | Should -Be 'Suspected'
        $v.Detail | Should -Match 'Example Corp Inspection CA'
    }
    It 'is Unknown without a chain' {
        (Get-TlsInspectionVerdict).Verdict | Should -Be 'Unknown'
    }
}

Describe 'Get-TlsCertificateChain (loopback handshake)' {
    BeforeAll {
        $script:cert = $null
        try {
            $script:cert = New-SelfSignedCertificate -DnsName 'localhost' -CertStoreLocation 'Cert:\CurrentUser\My' -Subject 'CN=Beacon Test Inspection CA' -ErrorAction Stop
        } catch { $script:cert = $null }
    }
    AfterAll {
        if ($script:cert) { Remove-Item "Cert:\CurrentUser\My\$($script:cert.Thumbprint)" -ErrorAction SilentlyContinue }
    }
    It 'reads the presented chain and flags a non-Microsoft issuer' -Skip:(-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
        if (-not $script:cert) { Set-ItResult -Skipped -Because 'cannot create a certificate here'; return }
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $c = $script:cert
        $job = Start-ThreadJob -ScriptBlock {
            param($listener, $cert)
            $client = $listener.AcceptTcpClient()
            $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
            $ssl.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            Start-Sleep -Milliseconds 200
            $ssl.Dispose(); $client.Close()
        } -ArgumentList $listener, $c
        try {
            $r = Get-TlsCertificateChain -TargetHost 'localhost' -Port $port -TimeoutMs 8000
            $r.Success | Should -BeTrue -Because $r.Error
            ($r.Subjects -join ';') | Should -Match 'Beacon Test Inspection CA'
            (Get-TlsInspectionVerdict -Subjects $r.Subjects -Issuers $r.Issuers).Verdict | Should -Be 'Suspected'
        } finally {
            $listener.Stop()
            $null = Wait-Job $job -Timeout 5
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    It 'reports a connection error cleanly' {
        $r = Get-TlsCertificateChain -TargetHost '127.0.0.1' -Port 1 -TimeoutMs 1500
        $r.Success | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-ProbePlan' {
    BeforeAll {
        function New-Ep { param($Name = 'a.example.com', $Port = 443, $Protocol = 'HTTPS', $Wildcard = $false, $ProbeHost = '', $Placeholder = '', $Probe = $true, $Gateway = 'no', $Skip = '')
            [pscustomobject]@{ host = $Name; port = $Port; protocol = $Protocol; wildcard = $Wildcard; probeHost = $ProbeHost; placeholder = $Placeholder; probe = $Probe; arcGateway = $Gateway; skipReason = $Skip } }
    }
    It 'probes a normal endpoint directly' {
        $p = Get-ProbePlan -Endpoint (New-Ep)
        $p.Action | Should -Be 'Probe'
        $p.UseProxy | Should -BeFalse
        $p.Host | Should -Be 'a.example.com'
    }
    It 'skips rows flagged probe=false with their reason' {
        $p = Get-ProbePlan -Endpoint (New-Ep -Probe $false -Skip 'port 8084 internal')
        $p.Action | Should -Be 'Skip'
        $p.Reason | Should -Be 'port 8084 internal'
    }
    It 'uses the representative host of a wildcard, or skips without one' {
        (Get-ProbePlan -Endpoint (New-Ep -Name '*.x.example.com' -Wildcard $true -ProbeHost 'r.x.example.com')).Host | Should -Be 'r.x.example.com'
        (Get-ProbePlan -Endpoint (New-Ep -Name '*.x.example.com' -Wildcard $true)).Action | Should -Be 'Skip'
    }
    It 'substitutes the Arc gateway and Key Vault placeholders, or skips when unset' {
        $gw = New-Ep -Name 'yourarcgatewayendpointid.gw.arc.azure.com' -Placeholder 'arcGateway'
        (Get-ProbePlan -Endpoint $gw -GatewayFqdn 'abc123.gw.arc.azure.com').Host | Should -Be 'abc123.gw.arc.azure.com'
        (Get-ProbePlan -Endpoint $gw).Action | Should -Be 'Skip'
        $kv = New-Ep -Name 'yourhcikeyvaultname.vault.azure.net' -Placeholder 'keyVault'
        (Get-ProbePlan -Endpoint $kv -KeyVaultFqdn 'kv-example.vault.azure.net').Host | Should -Be 'kv-example.vault.azure.net'
        (Get-ProbePlan -Endpoint $kv).Action | Should -Be 'Skip'
    }
    It 'in gateway mode skips endpoints the gateway carries but keeps registration-time endpoints' {
        (Get-ProbePlan -Endpoint (New-Ep -Gateway 'yes') -GatewayMode $true).Action | Should -Be 'Skip'
        (Get-ProbePlan -Endpoint (New-Ep -Gateway 'registration') -GatewayMode $true).Action | Should -Be 'Probe'
        (Get-ProbePlan -Endpoint (New-Ep -Gateway 'no') -GatewayMode $true).Action | Should -Be 'Probe'
        (Get-ProbePlan -Endpoint (New-Ep -Gateway 'yes') -GatewayMode $false).Action | Should -Be 'Probe'
    }
    It 'leaves UDP rows to the NTP check' {
        (Get-ProbePlan -Endpoint (New-Ep -Port 123 -Protocol 'UDP')).Action | Should -Be 'Skip'
    }
    It 'routes through the proxy unless bypassed' {
        (Get-ProbePlan -Endpoint (New-Ep) -ProxyUrl 'http://proxy.example.com:8080').UseProxy | Should -BeTrue
        (Get-ProbePlan -Endpoint (New-Ep -Name 'a.corp.example.com') -ProxyUrl 'http://proxy.example.com:8080' -ProxyBypass @('*.corp.example.com')).UseProxy | Should -BeFalse
    }
}
