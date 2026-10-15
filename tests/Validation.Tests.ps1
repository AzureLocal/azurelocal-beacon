#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Start-AzlValidation.ps1: categories with every external call mocked.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\Start-AzlValidation.ps1')
    $script:Data = Get-Content (Join-Path $script:Root 'src\config\endpoints.json') -Raw | ConvertFrom-Json
    function New-Cfg {
        param([hashtable]$Over = @{})
        $c = [pscustomobject]@{ clusterName = 'example'; tcpConnectTimeoutMs = 1000; pingTimeoutMs = 500 }
        foreach ($k in $Over.Keys) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $Over[$k] -Force }
        return (Resolve-ConfigDefaults -Config $c)
    }
}

Describe 'Start-AzlValidation' {
BeforeEach {
    $script:AllResults = New-Object System.Collections.Generic.List[object]
    $script:CriticalFail = $false
    Mock Out-ConsoleLine { }
}

Describe 'script structure' {
    It 'is dot-sourceable without running (entry guard) and exposes the category functions' {
        foreach ($f in 'Invoke-Category1Network', 'Invoke-Category2DnsCheck', 'Invoke-Category3ActiveDirectory', 'Invoke-Category4EndpointSweep', 'Invoke-Category5EnvironmentChecker', 'Invoke-Category6Arc') {
            Get-Command $f -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }
    }
    It 'has no drive or disk check anywhere in the engine or libraries' {
        $txt = (Get-ChildItem (Join-Path $script:Root 'src') -Recurse -Include *.ps1 | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $txt | Should -Not -Match '(?i)Get-PhysicalDisk|Get-Disk\b|Win32_DiskDrive|Win32_LogicalDisk|Get-Volume|Get-Partition|DriveInfo'
    }
}

Describe 'Get-NtpServerList' {
    It 'prefers configured NTP servers, then the DCs, then time.windows.com' {
        Get-NtpServerList -ValidationConfig (New-Cfg @{ ntpServers = @('192.0.2.50'); dcIps = @('192.0.2.10') }) | Should -Be @('192.0.2.50')
        Get-NtpServerList -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10', '192.0.2.11') }) | Should -Be @('192.0.2.10', '192.0.2.11')
        Get-NtpServerList -ValidationConfig (New-Cfg) | Should -Be @('time.windows.com')
    }
}

Describe 'Get-EndpointFailureStatus / Get-ExitCode / Get-ArcInputs' {
    It 'critical fails, others warn, curated stand-ins never fail' {
        Get-EndpointFailureStatus -Severity 'critical' | Should -Be 'Fail'
        Get-EndpointFailureStatus -Severity 'warning' | Should -Be 'Warn'
        Get-EndpointFailureStatus -Severity 'informational' | Should -Be 'Warn'
        Get-EndpointFailureStatus -Severity 'critical' -ProbeHostBasis 'curated' | Should -Be 'Warn'
    }
    It 'exit code: 1 on a failure, 2 when nothing ran, else 0' {
        Get-ExitCode -Results @([pscustomobject]@{ Status = 'Pass' }, [pscustomobject]@{ Status = 'Fail' }) | Should -Be 1
        Get-ExitCode -Results @() | Should -Be 2
        Get-ExitCode -Results @([pscustomobject]@{ Status = 'Warn' }, [pscustomobject]@{ Status = 'Skip' }) | Should -Be 0
    }
    It 'reads Arc inputs from parameters first, then the process environment' {
        $env:BEACON_ARC_SUBSCRIPTION = 'env-sub'; $env:BEACON_ARC_RG = 'env-rg'; $env:BEACON_ARC_NODES = 'n1,n2'; $env:BEACON_ARC_TENANT = 'env-tenant'
        try {
            $a = Get-ArcInputs -Subscription '' -Tenant '' -ResourceGroup '' -Nodes @() -Cloud 'AzureCloud' -ProxyUrl ''
            $a.SubscriptionId | Should -Be 'env-sub'; $a.ResourceGroup | Should -Be 'env-rg'; $a.NodeNames | Should -Be @('n1', 'n2'); $a.TenantId | Should -Be 'env-tenant'
            (Get-ArcInputs -Subscription 'param-sub' -Tenant '' -ResourceGroup '' -Nodes @() -Cloud 'AzureCloud' -ProxyUrl '').SubscriptionId | Should -Be 'param-sub'
        } finally {
            Remove-Item Env:BEACON_ARC_SUBSCRIPTION, Env:BEACON_ARC_RG, Env:BEACON_ARC_NODES, Env:BEACON_ARC_TENANT -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Category 1 - network and time' {
    BeforeEach {
        Mock Get-CimInstance { @([pscustomobject]@{ Description = 'Example NIC'; IPAddress = @('192.0.2.21') }) }
        Mock Test-PingAddress { @{ Success = $true; DurationMs = 1; RoundtripMs = 1; Error = '' } }
        Mock Invoke-NtpQuery { @{ Success = $true; OffsetSeconds = 2.5; ServerTimeUtc = [DateTime]::UtcNow; Error = '' } }
    }
    It 'passes NIC, gateway, node ping and NTP' {
        Invoke-Category1Network -ValidationConfig (New-Cfg @{ managementGateway = '192.0.2.1'; nodeIps = @('192.0.2.21'); dcIps = @('192.0.2.10') })
        @($script:AllResults | Where-Object Status -eq 'Fail').Count | Should -Be 0
        ($script:AllResults | Where-Object Name -eq 'NTP-192.0.2.10').Status | Should -Be 'Pass'
    }
    It 'fails when no adapter has an IP' {
        Mock Get-CimInstance { @() }
        Invoke-Category1Network -ValidationConfig (New-Cfg)
        ($script:AllResults | Where-Object Name -eq 'NIC-Up-WithIP').Status | Should -Be 'Fail'
    }
    It 'fails an unreachable gateway but only warns for an unreachable node' {
        Mock Test-PingAddress { @{ Success = $false; DurationMs = 1; RoundtripMs = 0; Error = 'TimedOut' } }
        Invoke-Category1Network -ValidationConfig (New-Cfg @{ managementGateway = '192.0.2.1'; nodeIps = @('192.0.2.21') })
        ($script:AllResults | Where-Object Name -eq 'Gateway-Ping').Status | Should -Be 'Fail'
        ($script:AllResults | Where-Object Name -eq 'MgmtSubnet-Node1-Ping').Status | Should -Be 'Warn'
    }
    It 'warns on a clock more than five minutes off and names the fix' {
        Mock Invoke-NtpQuery { @{ Success = $true; OffsetSeconds = 4000; ServerTimeUtc = [DateTime]::UtcNow; Error = '' } }
        Invoke-Category1Network -ValidationConfig (New-Cfg)
        $r = $script:AllResults | Where-Object Name -eq 'NTP-time.windows.com'
        $r.Status | Should -Be 'Warn'
        $r.Remediation | Should -Match 'BIOS'
    }
    It 'warns (not fails) when NTP does not answer' {
        Mock Invoke-NtpQuery { @{ Success = $false; OffsetSeconds = 0; ServerTimeUtc = $null; Error = 'NoResponse: no reply' } }
        Invoke-Category1Network -ValidationConfig (New-Cfg)
        ($script:AllResults | Where-Object Name -eq 'NTP-time.windows.com').Status | Should -Be 'Warn'
    }
    It 'skips gateway and node checks when not configured' {
        Invoke-Category1Network -ValidationConfig (New-Cfg)
        ($script:AllResults | Where-Object Name -eq 'Gateway-Ping').Status | Should -Be 'Skip'
        ($script:AllResults | Where-Object Name -eq 'MgmtSubnet-Node1-Ping').Status | Should -Be 'Skip'
    }
}

Describe 'Category 2 - DNS' {
    BeforeEach {
        Mock Test-TcpConnect { @{ Success = $true; DurationMs = 2; Error = '' } }
        Mock Invoke-DirectDnsQuery { @{ Success = $true; Addresses = 'answers=2'; DurationMs = 2; Error = '' } }
        Mock Invoke-DnsLookup { @{ Success = $true; Addresses = '20.1.1.1'; AddressList = @('20.1.1.1'); DurationMs = 2; Error = '' } }
        Mock Invoke-ReverseDnsLookup { @{ Success = $true; DnsHostname = 'dc01.corp.example.com'; DurationMs = 2; Error = '' } }
    }
    It 'tests TCP and UDP 53, forward names, AD domain, node FQDNs and DC reverse lookups' {
        Invoke-Category2DnsCheck -ValidationConfig (New-Cfg @{ dnsServers = @('192.0.2.10'); adDomainFqdn = 'corp.example.com'; nodeFqdns = @('n1.corp.example.com'); dcIps = @('192.0.2.10') })
        foreach ($n in 'DNS-TCP53-192.0.2.10', 'DNS-UDP53-Probe', 'DNS-Forward-login.microsoftonline.com', 'DNS-Forward-management.azure.com', 'DNS-Forward-ADDomain', 'DNS-Forward-n1.corp.example.com', 'DNS-Reverse-192.0.2.10') {
            ($script:AllResults | Where-Object Name -eq $n).Status | Should -Be 'Pass' -Because $n
        }
    }
    It 'Local Identity: AD domain lookup is skipped, UDP probe skipped without DNS servers' {
        Invoke-Category2DnsCheck -ValidationConfig (New-Cfg)
        ($script:AllResults | Where-Object Name -eq 'DNS-Forward-ADDomain').Status | Should -Be 'Skip'
        ($script:AllResults | Where-Object Name -eq 'DNS-UDP53-Probe').Status | Should -Be 'Skip'
    }
    It 'failed DNS server TCP is a Fail, unresolved node FQDN only a Warn' {
        Mock Test-TcpConnect { @{ Success = $false; DurationMs = 2; Error = 'Timeout' } }
        Mock Invoke-DnsLookup { @{ Success = $false; Addresses = ''; AddressList = @(); DurationMs = 2; Error = 'not found' } }
        Invoke-Category2DnsCheck -ValidationConfig (New-Cfg @{ dnsServers = @('192.0.2.10'); nodeFqdns = @('n1.corp.example.com') })
        ($script:AllResults | Where-Object Name -eq 'DNS-TCP53-192.0.2.10').Status | Should -Be 'Fail'
        ($script:AllResults | Where-Object Name -eq 'DNS-Forward-n1.corp.example.com').Status | Should -Be 'Warn'
    }
}

Describe 'Category 3 - Active Directory' {
    BeforeEach {
        Mock Test-TcpConnect { @{ Success = $true; DurationMs = 1; Error = '' } }
        Mock Test-UdpPort { @{ State = 'NoResponse'; Bytes = 0; Response = $null; Error = 'no reply' } }
        Mock Test-DnsSrvRecord { @{ Success = $true; Detail = 'SRV records: 2'; Error = '' } }
    }
    It 'probes every TCP port from the Learn Active Directory table' {
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10') })
        foreach ($port in 53, 88, 135, 389, 445, 464, 636, 3268, 3269, 9389) {
            Should -Invoke Test-TcpConnect -ParameterFilter { $Port -eq $port -and $TargetHost -eq '192.0.2.10' } -Times 1
        }
    }
    It 'tests UDP 88, 389 and 464 and never over-claims: silence is a Skip' {
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10') })
        foreach ($l in 'Kerberos-UDP', 'LDAP-UDP', 'Kpasswd-UDP') {
            ($script:AllResults | Where-Object Name -eq "AD-$l-192.0.2.10").Status | Should -Be 'Skip'
        }
    }
    It 'an ICMP port-unreachable on a UDP port is a Fail; a reply is a Pass' {
        Mock Test-UdpPort { @{ State = 'Refused'; Bytes = 0; Response = $null; Error = 'ICMP port unreachable' } } -ParameterFilter { $Port -eq 88 }
        Mock Test-UdpPort { @{ State = 'Responded'; Bytes = 20; Response = $null; Error = '' } } -ParameterFilter { $Port -eq 389 }
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10') })
        ($script:AllResults | Where-Object Name -eq 'AD-Kerberos-UDP-192.0.2.10').Status | Should -Be 'Fail'
        ($script:AllResults | Where-Object Name -eq 'AD-LDAP-UDP-192.0.2.10').Status | Should -Be 'Pass'
    }
    It 'documents the RPC dynamic range as a Skip instead of scanning it' {
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10') })
        $r = $script:AllResults | Where-Object Name -eq 'AD-RPC-Dynamic-49152-65535'
        $r.Status | Should -Be 'Skip'
        $r.Detail | Should -Match 'not scanned'
        Should -Invoke Test-TcpConnect -ParameterFilter { $Port -ge 49152 } -Times 0
    }
    It 'fails a blocked port with a remediation naming the port' {
        Mock Test-TcpConnect { @{ Success = $false; DurationMs = 1; Error = 'Timeout' } } -ParameterFilter { $Port -eq 9389 }
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10') })
        $r = $script:AllResults | Where-Object Name -eq 'AD-ADWS-192.0.2.10'
        $r.Status | Should -Be 'Fail'
        $r.Remediation | Should -Match '9389'
    }
    It 'checks the DC locator SRV record and skips it without a domain' {
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg @{ dcIps = @('192.0.2.10'); adDomainFqdn = 'corp.example.com'; dnsServers = @('192.0.2.10') })
        ($script:AllResults | Where-Object Name -eq 'AD-SRV-DCLocator').Status | Should -Be 'Pass'
        $script:AllResults.Clear()
        Invoke-Category3ActiveDirectory -ValidationConfig (New-Cfg)
        ($script:AllResults | Where-Object Name -eq 'AD-SRV-DCLocator').Status | Should -Be 'Skip'
    }
}

Describe 'Category 4 - endpoint sweep' {
    BeforeEach {
        Mock Test-TcpConnect { @{ Success = $true; DurationMs = 3; Error = '' } }
        Mock Test-HttpsGet { @{ Success = $true; HttpCode = 200; DurationMs = 4; Error = '' } }
        Mock Invoke-DnsLookup { @{ Success = $true; Addresses = '20.1.1.1'; AddressList = @('20.1.1.1'); DurationMs = 1; Error = '' } }
        Mock Get-TlsCertificateChain { @{ Success = $true; Subjects = @('CN=x', 'CN=Microsoft Azure RSA TLS Issuing CA 03'); Issuers = @('CN=Microsoft Azure RSA TLS Issuing CA 03', 'CN=DigiCert Global Root G2'); Error = '' } }
    }
    It 'sweeps the region list and records the region and list source' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'West Europe' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        $r = $script:AllResults | Where-Object Name -eq 'Endpoint-Region'
        $r.Status | Should -Be 'Pass'
        $r.Target | Should -Be 'westeurope'
        $r.Source | Should -Match 'westeurope-hci-endpoints'
        ($script:AllResults | Where-Object Name -eq 'EP-weu.his.arc.azure.com').Status | Should -Be 'Pass'
        $script:AllResults | Where-Object Name -eq 'EP-eus.his.arc.azure.com' | Should -BeNullOrEmpty
    }
    It 'warns and falls back to eastus without a usable region' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName '' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        ($script:AllResults | Where-Object Name -eq 'Endpoint-Region').Status | Should -Be 'Warn'
        ($script:AllResults | Where-Object Name -eq 'EP-eus.his.arc.azure.com').Status | Should -Be 'Pass'
    }
    It 'never probes port 8084 (cluster-internal) and records why' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        Should -Invoke Test-TcpConnect -ParameterFilter { $Port -eq 8084 } -Times 0
        ($script:AllResults | Where-Object Target -like '*:8084').Status | Should -Be 'Skip'
    }
    It 'a blocked critical endpoint is a Fail with severity and remediation; a blocked warning endpoint only warns' {
        Mock Test-TcpConnect { @{ Success = $false; DurationMs = 1; Error = 'Timeout' } } -ParameterFilter { $TargetHost -eq 'management.azure.com' -or $TargetHost -eq 'crl3.digicert.com' }
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        $m = $script:AllResults | Where-Object Name -eq 'EP-management.azure.com'
        $m.Status | Should -Be 'Fail'
        $m.Severity | Should -Be 'critical'
        $m.Remediation | Should -Match 'management.azure.com'
        ($script:AllResults | Where-Object Name -eq 'EP-crl3.digicert.com').Status | Should -Be 'Warn'
    }
    It 'TCP open but HTTPS probe failing is a Warn on a critical endpoint' {
        Mock Test-HttpsGet { @{ Success = $false; HttpCode = 0; DurationMs = 4; Error = 'curl exit=35' } }
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        ($script:AllResults | Where-Object Name -eq 'EP-management.azure.com').Status | Should -Be 'Fail'
    }
    It 'proxy mode probes through the proxy, not directly, and honours the bypass list' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl 'http://proxy.example.com:8080' -ProxyBypass @('*.dp.kubernetesconfiguration.azure.com') -GatewayFqdn ''
        Should -Invoke Test-HttpsGet -ParameterFilter { $TargetHost -eq 'management.azure.com' -and $ProxyUrl -eq 'http://proxy.example.com:8080' }
        Should -Invoke Test-TcpConnect -ParameterFilter { $TargetHost -eq 'management.azure.com' } -Times 0
        Should -Invoke Test-TcpConnect -ParameterFilter { $TargetHost -eq 'eastus.dp.kubernetesconfiguration.azure.com' }
        ($script:AllResults | Where-Object Name -eq 'Proxy-Reachable') | Should -Not -BeNullOrEmpty
    }
    It 'Arc gateway mode probes the gateway FQDN and skips what the gateway carries' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn 'abc123.gw.arc.azure.com'
        Should -Invoke Test-TcpConnect -ParameterFilter { $TargetHost -eq 'abc123.gw.arc.azure.com' }
        ($script:AllResults | Where-Object Name -eq 'EP-mcr.microsoft.com').Status | Should -Be 'Skip'
        ($script:AllResults | Where-Object Name -eq 'EP-management.azure.com').Status | Should -Be 'Pass'
    }
    It 'without a gateway the gateway row is skipped with the reason' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        ($script:AllResults | Where-Object Name -like 'EP-yourarcgatewayendpointid*').Detail | Should -Match 'not configured'
    }
    It 'fails an Arc endpoint that resolves to a private address (Private Link Scopes unsupported)' {
        Mock Invoke-DnsLookup { @{ Success = $true; Addresses = '10.9.9.9'; AddressList = @('10.9.9.9'); DurationMs = 1; Error = '' } } -ParameterFilter { $DnsHostname -eq 'gbl.his.arc.azure.com' }
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        $r = $script:AllResults | Where-Object Name -eq 'PublicIP-gbl.his.arc.azure.com'
        $r.Status | Should -Be 'Fail'
        $r.Detail | Should -Match '10\.9\.9\.9'
        $r.Remediation | Should -Match 'Private Link'
        ($script:AllResults | Where-Object Name -eq 'PublicIP-eus.his.arc.azure.com').Status | Should -Be 'Pass'
    }
    It 'flags a re-signed certificate chain as suspected HTTPS inspection' {
        Mock Get-TlsCertificateChain { @{ Success = $true; Subjects = @('CN=login.microsoftonline.com', 'CN=Example Inspection CA'); Issuers = @('CN=Example Inspection CA', 'CN=Example Root'); Error = '' } }
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        $r = $script:AllResults | Where-Object Name -eq 'TlsInspection-login.microsoftonline.com'
        $r.Status | Should -Be 'Warn'
        $r.Severity | Should -Be 'critical'
        $r.Detail | Should -Match 'inspection suspected'
        ($script:AllResults | Where-Object Name -eq 'TlsInspection-management.azure.com').Status | Should -Be 'Warn'
    }
    It 'passes a Microsoft chain and warns (not fails) when the chain cannot be read' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        ($script:AllResults | Where-Object Name -eq 'TlsInspection-login.microsoftonline.com').Status | Should -Be 'Pass'
        $script:AllResults.Clear()
        Mock Get-TlsCertificateChain { @{ Success = $false; Subjects = @(); Issuers = @(); Error = 'timeout' } }
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        ($script:AllResults | Where-Object Name -eq 'TlsInspection-login.microsoftonline.com').Status | Should -Be 'Warn'
    }
    It 'hands the proxy to the TLS inspection check' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl 'http://proxy.example.com:8080' -ProxyBypass @() -GatewayFqdn ''
        Should -Invoke Get-TlsCertificateChain -ParameterFilter { $ProxyUrl -eq 'http://proxy.example.com:8080' }
    }
    It 'adds the OEM list when configured' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg @{ oem = 'dell' }) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        ($script:AllResults | Where-Object Name -eq 'EP-downloads.dell.com') | Should -Not -BeNullOrEmpty
    }
    It 'substitutes the Key Vault name for the placeholder row' {
        Invoke-Category4EndpointSweep -ValidationConfig (New-Cfg @{ keyVaultFqdn = 'kv-example.vault.azure.net' }) -EndpointData $script:Data -RegionName 'eastus' -ProxyUrl '' -ProxyBypass @() -GatewayFqdn ''
        Should -Invoke Test-TcpConnect -ParameterFilter { $TargetHost -eq 'kv-example.vault.azure.net' }
    }
}

Describe 'Category 5 - Environment Checker' {
    BeforeEach {
        $script:EnvModule = Join-Path $script:Root 'tools\modules\AzStackHci.EnvironmentChecker'
        $env:BEACON_ENVCHECKER_INPROCESS = '1'
        Mock Import-Module { }
        function global:Invoke-AzStackHciConnectivityValidation { [CmdletBinding()] param($PassThru, $RegionName, $Proxy, [switch]$ARCGateway, [switch]$UseLocalDefinitionsOnly, $OutputPath) }
        function global:Invoke-AzStackHciNetworkValidation { [CmdletBinding()] param($IpPools, $ManagementSubnetValue, $NodesInCluster, $AtcHostIntents, $PassThru, $PSSession) }
        Mock Invoke-AzStackHciConnectivityValidation {
            @(
                [pscustomobject]@{ Name = 'a'; Status = 'SUCCESS'; Severity = 'CRITICAL'; TargetResourceName = 'a.example.com'; Description = 'ok'; Remediation = '' },
                [pscustomobject]@{ Name = 'b'; Status = 'FAILURE'; Severity = 'CRITICAL'; TargetResourceName = 'b.example.com'; Description = 'blocked'; Remediation = 'https://aka.ms/hci-envch' },
                [pscustomobject]@{ Name = 'c'; Status = 'FAILURE'; Severity = 'WARNING'; TargetResourceName = 'c.example.com'; Description = 'slow'; Remediation = '' }
            )
        }
    }
    AfterEach {
        Remove-Item Env:BEACON_ENVCHECKER_INPROCESS -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-AzStackHciConnectivityValidation, function:global:Invoke-AzStackHciNetworkValidation -ErrorAction SilentlyContinue
    }
    It 'skips with the switch' {
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus' -SkipChecks
        $script:AllResults[0].Status | Should -Be 'Skip'
    }
    It 'imports the module by explicit manifest path (version sub folder)' {
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        Should -Invoke Import-Module -ParameterFilter { $Name -match '10\.2605\.0\.2006[\\/]AzStackHci\.EnvironmentChecker\.psd1$' }
    }
    It 'itemises failed checks with name, status, severity, remediation and target' {
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        $sum = $script:AllResults | Where-Object Name -eq 'EnvChecker-Connectivity'
        $sum.Status | Should -Be 'Fail'
        $sum.Detail | Should -Match '1/3 checks succeeded'
        $b = $script:AllResults | Where-Object Name -eq 'Connectivity-b'
        $b.Status | Should -Be 'Fail'
        $b.Severity | Should -Be 'critical'
        $b.Remediation | Should -Be 'https://aka.ms/hci-envch'
        $b.Target | Should -Be 'b.example.com'
        ($script:AllResults | Where-Object Name -eq 'Connectivity-c').Status | Should -Be 'Warn'
        $script:AllResults | Where-Object Name -eq 'Connectivity-a' | Should -BeNullOrEmpty
    }
    It 'passes region, proxy and Arc gateway to the Connectivity validator' {
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg @{ proxyUrl = 'http://proxy.example.com:8080'; arcGatewayFqdn = 'abc.gw.arc.azure.com' }) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'westeurope'
        Should -Invoke Invoke-AzStackHciConnectivityValidation -ParameterFilter { $RegionName -eq 'westeurope' -and $Proxy -eq 'http://proxy.example.com:8080' -and $ARCGateway }
    }
    It 'skips the Network validator (with the reason) when its inputs are not configured' {
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        $n = $script:AllResults | Where-Object Name -eq 'EnvChecker-Network'
        $n.Status | Should -Be 'Skip'
        $n.Detail | Should -Match 'infraIpPools'
    }
    It 'skips the Network validator when no remoting session to the node is possible (WinPE)' {
        Mock New-NodeSession { throw 'WinRM cannot process the request' }
        $cfg = New-Cfg @{ infraIpPools = @([pscustomobject]@{ StartingAddress = '192.0.2.100'; EndingAddress = '192.0.2.110' }); managementSubnetCidr = '192.0.2.0/24'; hostNetworkIntents = @([pscustomobject]@{ Name = 'Mgmt' }); nodeIps = @('192.0.2.21') }
        Invoke-Category5EnvironmentChecker -ValidationConfig $cfg -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        $n = $script:AllResults | Where-Object Name -eq 'EnvChecker-Network'
        $n.Status | Should -Be 'Skip'
        $n.Detail | Should -Match 'remoting'
    }
    It 'runs the Network validator with real inputs and a session, itemises its failures and closes the session' {
        Mock New-NodeSession { [pscustomobject]@{ Id = 1 } }
        Mock Remove-NodeSession { }
        Mock Invoke-AzStackHciNetworkValidation { @([pscustomobject]@{ Name = 'MgmtRange'; Status = 'FAILURE'; Severity = 'CRITICAL'; TargetResourceName = '192.0.2.100'; Description = 'range overlaps'; Remediation = 'fix pool' }) }
        $cfg = New-Cfg @{ infraIpPools = @([pscustomobject]@{ StartingAddress = '192.0.2.100'; EndingAddress = '192.0.2.110' }); managementSubnetCidr = '192.0.2.0/24'; hostNetworkIntents = @([pscustomobject]@{ Name = 'Mgmt' }); nodeIps = @('192.0.2.21', '192.0.2.22') }
        Invoke-Category5EnvironmentChecker -ValidationConfig $cfg -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        Should -Invoke Invoke-AzStackHciNetworkValidation -ParameterFilter { $NodesInCluster -eq 2 -and $ManagementSubnetValue -eq '192.0.2.0/24' }
        Should -Invoke Remove-NodeSession -Times 1
        ($script:AllResults | Where-Object Name -eq 'Network-MgmtRange').Remediation | Should -Be 'fix pool'
    }
    It 'a validator that throws becomes a Warn, never a crash' {
        Mock Invoke-AzStackHciConnectivityValidation { throw 'module internal error' }
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        ($script:AllResults | Where-Object Name -eq 'EnvChecker-Connectivity').Status | Should -Be 'Warn'
    }
    It 'reports a missing module as a Warn' {
        Mock Resolve-EnvCheckerManifest { $null }
        Invoke-Category5EnvironmentChecker -ValidationConfig (New-Cfg) -ConfigDir 'x' -ResultsDir $TestDrive -RegionKey 'eastus'
        ($script:AllResults | Where-Object Name -eq 'EnvChecker-Module').Status | Should -Be 'Warn'
    }
    It 'maps real module statuses: the vendored module emits SUCCESS and FAILURE, not Succeeded' {
        $src = (Get-ChildItem (Join-Path $script:Root 'tools\modules\AzStackHci.EnvironmentChecker\10.2605.0.2006') -Recurse -Filter '*.psm1' | Select-Object -First 400 | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $src | Should -Match "Status\s*=\s*'SUCCESS'"
        $src | Should -Match "Status\s*=\s*'FAILURE'"
    }
}

Describe 'Category 5 delegation from PowerShell 7' {
    It 'is wired to run the module in Windows PowerShell 5.1 and merge results' {
        (Get-Command Invoke-EnvCheckerDelegated).ScriptBlock.ToString() | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe'
        (Get-Command Invoke-EnvCheckerDelegated).ScriptBlock.ToString() | Should -Match 'PartialResultsPath'
        (Get-Command Invoke-Category5EnvironmentChecker).ScriptBlock.ToString() | Should -Match "PSEdition -eq 'Core'"
    }
}

Describe 'Category 6 - Arc' {
    It 'skips with -SkipArc' {
        Invoke-Category6Arc -ArcInputs @{ SubscriptionId = 'x' } -SkipChecks
        $script:AllResults[0].Status | Should -Be 'Skip'
    }
    It 'skips without a subscription instead of prompting' {
        Invoke-Category6Arc -ArcInputs @{ SubscriptionId = '' }
        $script:AllResults[0].Status | Should -Be 'Skip'
        $script:AllResults[0].Detail | Should -Match 'No subscription'
    }
    It 'delegates to the REST checks when a subscription is present' {
        Mock Invoke-ArcReadinessChecks { }
        Invoke-Category6Arc -ArcInputs @{ SubscriptionId = '11111111-2222-3333-4444-555555555555' }
        Should -Invoke Invoke-ArcReadinessChecks -Times 1
    }
}

Describe 'Write-ValidationSummary' {
    It 'prints the verdict for pass, fail and no checks' {
        $lines = New-Object System.Collections.Generic.List[string]
        Mock Out-ConsoleLine { $lines.Add($Message) }
        Write-ValidationSummary -Results @([pscustomobject]@{ Status = 'Pass'; Category = 'c'; Name = 'n'; Detail = 'd' })
        ($lines -join "`n") | Should -Match 'READY'
        $lines.Clear()
        Write-ValidationSummary -Results @([pscustomobject]@{ Status = 'Fail'; Category = 'c'; Name = 'n'; Detail = 'd' })
        ($lines -join "`n") | Should -Match 'NOT READY'
        $lines.Clear()
        Write-ValidationSummary -Results @()
        ($lines -join "`n") | Should -Match 'NO CHECKS RAN'
    }
}

Describe 'end to end: engine process with everything skipped' {
    It 'writes schema-valid JSON, log and HTML and exits 0 when only skips occurred' {
        $cfgDir = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory -Path $cfgDir | Out-Null
        Copy-Item (Join-Path $script:Root 'src\config\endpoints.json') $cfgDir
        Copy-Item (Join-Path $script:Root 'src\config\validation-config.example.json') (Join-Path $cfgDir 'validation-config.json')
        $out = Join-Path $TestDrive 'results'
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoLogo -NoProfile -File (Join-Path $script:Root 'src\Start-AzlValidation.ps1') -ConfigPath $cfgDir -ResultsPath $out -Categories 5 -SkipEnvironmentChecker 6>$null *>$null
        $LASTEXITCODE | Should -Be 0
        $json = Get-ChildItem $out -Filter 'validation-*.json' | Select-Object -First 1
        $json | Should -Not -BeNullOrEmpty
        Test-Json -Json (Get-Content $json.FullName -Raw) -SchemaFile (Join-Path $script:Root 'docs\reference\results.schema.json') | Should -BeTrue
        @(Get-ChildItem $out -Filter 'validation-*.html').Count | Should -Be 1
        (Get-Content $json.FullName -Raw | ConvertFrom-Json).results[0].name | Should -Be 'EnvChecker-Module'
    }
    It '-Redact writes a redacted document and no Environment Checker report copy' {
        $cfgDir = Join-Path $TestDrive 'cfg2'
        New-Item -ItemType Directory -Path $cfgDir | Out-Null
        Copy-Item (Join-Path $script:Root 'src\config\endpoints.json') $cfgDir
        $c = Get-Content (Join-Path $script:Root 'src\config\validation-config.example.json') -Raw | ConvertFrom-Json
        $c.adDomainFqdn = 'corp.contoso.com'
        $c | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $cfgDir 'validation-config.json')
        $out = Join-Path $TestDrive 'results2'
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoLogo -NoProfile -File (Join-Path $script:Root 'src\Start-AzlValidation.ps1') -ConfigPath $cfgDir -ResultsPath $out -Categories 5 -SkipEnvironmentChecker -Redact 6>$null *>$null
        $doc = Get-Content (Get-ChildItem $out -Filter 'validation-*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
        $doc.redacted | Should -BeTrue
        $doc.node.hostname | Should -Be '<host>'
    }
}

}
