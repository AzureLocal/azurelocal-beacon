#Requires -Version 5.1
<#
.SYNOPSIS
    AzL Beacon validation engine: Azure Local pre-deployment readiness checks for WinPE and full Windows.

.DESCRIPTION
    Runs 6 validation categories grounded in Microsoft Learn:
      1  Basic network and time: NIC up, gateway reachable, node IPs, NTP/W32Time reachability and clock skew
      2  DNS: forward and reverse lookups, TCP/UDP port 53
      3  Active Directory: LDAP, LDAPS, GC, Kerberos, kpasswd, SMB, RPC mapper, ADWS (TCP) + UDP 88/389/464
         where testable + DC locator SRV record (AD path only)
      4  Azure endpoint sweep for the selected region (Learn-linked per-region lists), Arc gateway and
         proxy aware, plus public-IP resolution of Arc endpoints and an HTTPS-inspection check
      5  Environment Checker: Invoke-AzStackHciConnectivityValidation / Invoke-AzStackHciNetworkValidation
         (vendored AzStackHci.EnvironmentChecker; failed checks are itemised)
      6  Arc readiness: device-code sign-in + ARM REST checks (no Az modules); memory only

    Test targets come from config\validation-config.json and config\endpoints.json.
    There is deliberately NO drive/disk check.

    Exit codes: 0 no critical failures, 1 one or more failures, 2 no checks ran.

.PARAMETER ConfigPath
    Folder with validation-config.json and endpoints.json. Default: <scriptroot>\config.

.PARAMETER ResultsPath
    Where results are written. Default X:\results in WinPE, otherwise $env:TEMP.

.PARAMETER Categories
    Category numbers 1-6 to run (default all). Example: -Categories 1,2,4

.PARAMETER SkipEnvironmentChecker
    Skip category 5.

.PARAMETER SkipArc
    Skip category 6.

.PARAMETER Region
    Azure region for the endpoint list (eastus, westeurope, australiaeast, canadacentral, centralindia,
    southeastasia, japaneast, southcentralus, usgovvirginia). Overrides config azureRegion.

.PARAMETER ProxyUrl
    Explicit proxy (http://proxy:port) used by HTTPS probes. Overrides config proxyUrl.

.PARAMETER ProxyBypass
    Hosts that skip the proxy (suffixes, *.domain, CIDR, <local>). Overrides config proxyBypass.

.PARAMETER ArcGatewayFqdn
    <id>.gw.arc.azure.com. Switches the sweep to Arc gateway mode. Overrides config arcGatewayFqdn.

.PARAMETER Redact
    Replace domain, host names, serials, GUIDs and IP addresses in the written results with tokens.

.PARAMETER ExportTo
    Also copy/post the results: a drive letter (E), a UNC folder (\\server\share) or an https URL.

.PARAMETER ArcSubscriptionId
    Subscription for the Arc checks (or env BEACON_ARC_SUBSCRIPTION). Never written to disk.

.PARAMETER ArcTenantId
    Entra tenant for the device-code sign-in (or env BEACON_ARC_TENANT). Default: organizations.

.PARAMETER ArcResourceGroup
    Resource group to check (or env BEACON_ARC_RG).

.PARAMETER ArcNodeNames
    Node host names to check for existing Arc machines (or env BEACON_ARC_NODES, comma separated).

.PARAMETER PartialResultsPath
    Internal: write only the raw result list to this file and exit (used when a PowerShell 7 host
    delegates category 5 to Windows PowerShell 5.1).

.EXAMPLE
    .\Start-AzlValidation.ps1 -Categories 1,2,4 -Region westeurope -ResultsPath C:\Temp\results

.EXAMPLE
    .\Start-AzlValidation.ps1 -SkipEnvironmentChecker -SkipArc -Redact -ExportTo E

.NOTES
    Compatibility: PowerShell 5.1 (WinPE) and 7. No PS7-only syntax.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$ResultsPath = '',
    [string[]]$Categories = @(),
    [switch]$SkipEnvironmentChecker,
    [switch]$SkipArc,
    [string]$Region = '',
    [string]$ProxyUrl = '',
    [string[]]$ProxyBypass = @(),
    [string]$ArcGatewayFqdn = '',
    [switch]$Redact,
    [string]$ExportTo = '',
    [string]$ArcSubscriptionId = '',
    [string]$ArcTenantId = '',
    [string]$ArcResourceGroup = '',
    [string[]]$ArcNodeNames = @(),
    [string]$PartialResultsPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$InformationPreference = 'Continue'

$script:ScriptRoot = $PSScriptRoot
. (Join-Path $script:ScriptRoot 'lib\Beacon.Version.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Common.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Net.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Endpoints.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.EnvChecker.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Arc.ps1')
. (Join-Path $script:ScriptRoot 'lib\Beacon.Results.ps1')

$script:StartTime = Get-Date
$script:StartTimeUtc = [DateTime]::UtcNow

# Category 3 specification: TCP ports from Learn "Active Directory" firewall table.
$script:AdTcpPorts = @(
    @{ Port = 53;   Label = 'DNS' },
    @{ Port = 88;   Label = 'Kerberos' },
    @{ Port = 135;  Label = 'RPC-Mapper' },
    @{ Port = 389;  Label = 'LDAP' },
    @{ Port = 445;  Label = 'SMB' },
    @{ Port = 464;  Label = 'Kpasswd' },
    @{ Port = 636;  Label = 'LDAPS' },
    @{ Port = 3268; Label = 'GC' },
    @{ Port = 3269; Label = 'GC-SSL' },
    @{ Port = 9389; Label = 'ADWS' }
)
$script:AdUdpPorts = @(
    @{ Port = 88;  Label = 'Kerberos-UDP' },
    @{ Port = 389; Label = 'LDAP-UDP' },
    @{ Port = 464; Label = 'Kpasswd-UDP' }
)
$script:LearnFirewallUrl = 'https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements'

#region ================================================================
#  CATEGORY IMPLEMENTATIONS
#================================================================

function Invoke-Category1Network {
    param([object]$ValidationConfig)
    $cat = 'Cat-1-Network'
    Out-ConsoleLine -Message "`n[Category 1] Basic Network and Time" -Color ([System.ConsoleColor]::Cyan)

    try {
        $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        $activeNic = @($nics | Where-Object { $_.IPAddress -and $_.IPAddress.Count -gt 0 })
        if ($activeNic.Count -gt 0) {
            $nicList = ($activeNic | ForEach-Object { "$($_.Description) / $($_.IPAddress[0])" }) -join '; '
            Add-ValidationResult -Category $cat -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Pass' -Detail $nicList
        } else {
            Add-ValidationResult -Category $cat -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Fail' -Severity 'critical' -Detail 'No IP-enabled adapters found' `
                -Remediation 'Load the NIC driver (-DriverPath at build time) or assign an address from the network settings menu.'
        }
    } catch {
        Add-ValidationResult -Category $cat -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Fail' -Severity 'critical' -Detail $_.Exception.Message
    }

    $gw = $ValidationConfig.managementGateway
    if ($gw) {
        $gwPing = Test-PingAddress -Address $gw -TimeoutMs $ValidationConfig.pingTimeoutMs
        $gwStat = if ($gwPing.Success) { 'Pass' } else { 'Fail' }
        $gwDet = if ($gwPing.Success) { "$($gwPing.RoundtripMs)ms" } else { $gwPing.Error }
        Add-ValidationResult -Category $cat -Name 'Gateway-Ping' -Target $gw -Status $gwStat -Detail $gwDet -DurationMs $gwPing.DurationMs `
            -Severity $(if ($gwPing.Success) { '' } else { 'critical' }) `
            -Remediation $(if ($gwPing.Success) { '' } else { 'Learn: allow ICMP from the infrastructure range to the default gateway.' }) -Source $script:LearnFirewallUrl
    } else {
        Add-ValidationResult -Category $cat -Name 'Gateway-Ping' -Target 'managementGateway' -Status 'Skip' -Detail 'managementGateway not configured'
    }

    if (@($ValidationConfig.nodeIps).Count -gt 0) {
        $nodeIp = @($ValidationConfig.nodeIps)[0]
        $nodePing = Test-PingAddress -Address $nodeIp -TimeoutMs $ValidationConfig.pingTimeoutMs
        $nodeStat = if ($nodePing.Success) { 'Pass' } else { 'Warn' }
        $nodeDet = if ($nodePing.Success) { "$($nodePing.RoundtripMs)ms" } else { "Not reachable (may be unpowered): $($nodePing.Error)" }
        Add-ValidationResult -Category $cat -Name 'MgmtSubnet-Node1-Ping' -Target $nodeIp -Status $nodeStat -Detail $nodeDet -DurationMs $nodePing.DurationMs
    } else {
        Add-ValidationResult -Category $cat -Name 'MgmtSubnet-Node1-Ping' -Target 'nodeIps' -Status 'Skip' -Detail 'No node IPs in config'
    }

    # NTP / W32Time: its own check (Learn: UDP/123 to the NTP server; Kerberos tolerates 5 min skew)
    $ntp = @(Get-NtpServerList -ValidationConfig $ValidationConfig)
    foreach ($server in $ntp) {
        $q = Invoke-NtpQuery -Server $server
        if ($q.Success) {
            $v = Get-ClockSkewVerdict -OffsetSeconds $q.OffsetSeconds
            $det = "UDP/123 answered; clock offset {0}s vs server" -f $q.OffsetSeconds
            $rem = ''
            if ($v -ne 'Pass') { $rem = 'Clock differs by more than 5 minutes: set the BIOS clock or fix time sync; Kerberos and Arc registration fail on large skew.' }
            Add-ValidationResult -Category $cat -Name "NTP-$server" -Target "${server}:123/udp" -Status $v -Detail $det -Remediation $rem -Source $script:LearnFirewallUrl
        } else {
            Add-ValidationResult -Category $cat -Name "NTP-$server" -Target "${server}:123/udp" -Status 'Warn' -Severity 'warning' -Detail $q.Error `
                -Remediation 'Allow UDP/123 from the nodes to the NTP source (a domain controller or NTP appliance).' -Source $script:LearnFirewallUrl
        }
    }
}

function Get-NtpServerList {
    <# Configured NTP servers; else the domain controllers (they are the AD time source); else time.windows.com. Pure. #>
    param([object]$ValidationConfig)
    $configured = @(ConvertTo-StringList $ValidationConfig.ntpServers)
    if ($configured.Count -gt 0) { return $configured }
    $dcs = @(ConvertTo-StringList $ValidationConfig.dcIps)
    if ($dcs.Count -gt 0) { return $dcs }
    return @('time.windows.com')
}

function Invoke-Category2DnsCheck {
    param([object]$ValidationConfig)
    $cat = 'Cat-2-DNS'
    Out-ConsoleLine -Message "`n[Category 2] DNS Resolution" -Color ([System.ConsoleColor]::Cyan)

    foreach ($dnsIp in @($ValidationConfig.dnsServers)) {
        $tcp = Test-TcpConnect -TargetHost $dnsIp -Port 53 -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
        $st = if ($tcp.Success) { 'Pass' } else { 'Fail' }
        $det = if ($tcp.Success) { "$($tcp.DurationMs)ms" } else { $tcp.Error }
        Add-ValidationResult -Category $cat -Name "DNS-TCP53-$dnsIp" -Target "${dnsIp}:53" -Status $st -Detail $det -DurationMs $tcp.DurationMs
    }

    if (@($ValidationConfig.dnsServers).Count -gt 0) {
        $primaryDns = @($ValidationConfig.dnsServers)[0]
        $udpResult = Invoke-DirectDnsQuery -DnsServer $primaryDns -QueryName 'management.azure.com' -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
        $udpSt = if ($udpResult.Success) { 'Pass' } else { 'Warn' }
        $udpDet = if ($udpResult.Success) { "UDP answered -- $($udpResult.Addresses)" } else { $udpResult.Error }
        Add-ValidationResult -Category $cat -Name 'DNS-UDP53-Probe' -Target "${primaryDns}:53/udp" -Status $udpSt -Detail $udpDet -DurationMs $udpResult.DurationMs
    } else {
        Add-ValidationResult -Category $cat -Name 'DNS-UDP53-Probe' -Target '53/udp' -Status 'Skip' -Detail 'No DNS servers configured'
    }

    foreach ($fwdHost in @('login.microsoftonline.com', 'management.azure.com')) {
        $r = Invoke-DnsLookup -DnsHostname $fwdHost
        $st = if ($r.Success) { 'Pass' } else { 'Fail' }
        $dt = if ($r.Success) { $r.Addresses } else { $r.Error }
        Add-ValidationResult -Category $cat -Name "DNS-Forward-$fwdHost" -Target $fwdHost -Status $st -Detail $dt -DurationMs $r.DurationMs
    }

    if ($ValidationConfig.adDomainFqdn) {
        $domainR = Invoke-DnsLookup -DnsHostname $ValidationConfig.adDomainFqdn
        $domSt = if ($domainR.Success) { 'Pass' } else { 'Fail' }
        $domDet = if ($domainR.Success) { $domainR.Addresses } else { $domainR.Error }
        Add-ValidationResult -Category $cat -Name 'DNS-Forward-ADDomain' -Target $ValidationConfig.adDomainFqdn -Status $domSt -Detail $domDet -DurationMs $domainR.DurationMs
    } else {
        Add-ValidationResult -Category $cat -Name 'DNS-Forward-ADDomain' -Target 'adDomainFqdn' -Status 'Skip' -Detail 'AD domain not configured (Local Identity path)'
    }

    foreach ($nodeFqdn in @($ValidationConfig.nodeFqdns)) {
        $r = Invoke-DnsLookup -DnsHostname $nodeFqdn
        $st = if ($r.Success) { 'Pass' } else { 'Warn' }
        $dt = if ($r.Success) { $r.Addresses } else { "Expected before deployment: $($r.Error)" }
        Add-ValidationResult -Category $cat -Name "DNS-Forward-$nodeFqdn" -Target $nodeFqdn -Status $st -Detail $dt -DurationMs $r.DurationMs
    }

    foreach ($dcIp in @($ValidationConfig.dcIps)) {
        $r = Invoke-ReverseDnsLookup -IpAddress $dcIp
        $st = if ($r.Success) { 'Pass' } else { 'Fail' }
        $dt = if ($r.Success) { $r.DnsHostname } else { $r.Error }
        Add-ValidationResult -Category $cat -Name "DNS-Reverse-$dcIp" -Target $dcIp -Status $st -Detail $dt -DurationMs $r.DurationMs
    }
}

function Invoke-Category3ActiveDirectory {
    param([object]$ValidationConfig)
    $cat = 'Cat-3-AD'
    $learnAd = "$script:LearnFirewallUrl#active-directory"
    Out-ConsoleLine -Message "`n[Category 3] Active Directory Ports" -Color ([System.ConsoleColor]::Cyan)

    foreach ($dcIp in @($ValidationConfig.dcIps)) {
        foreach ($ps in $script:AdTcpPorts) {
            $r = Test-TcpConnect -TargetHost $dcIp -Port $ps.Port -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
            $st = if ($r.Success) { 'Pass' } else { 'Fail' }
            $dt = if ($r.Success) { "$($r.DurationMs)ms" } else { $r.Error }
            Add-ValidationResult -Category $cat -Name "AD-$($ps.Label)-$dcIp" -Target "${dcIp}:$($ps.Port)" -Status $st -Detail $dt -DurationMs $r.DurationMs `
                -Severity $(if ($r.Success) { '' } else { 'critical' }) `
                -Remediation $(if ($r.Success) { '' } else { "Allow TCP/$($ps.Port) from the nodes to the domain controller ($($ps.Label))." }) -Source $learnAd
        }
        foreach ($ps in $script:AdUdpPorts) {
            $u = Test-UdpPort -TargetHost $dcIp -Port $ps.Port -Payload ([byte[]]@(0)) -TimeoutMs 1500
            $target = "${dcIp}:$($ps.Port)/udp"
            switch ($u.State) {
                'Responded' { Add-ValidationResult -Category $cat -Name "AD-$($ps.Label)-$dcIp" -Target $target -Status 'Pass' -Detail "reply, $($u.Bytes) bytes" -Source $learnAd }
                'Refused' { Add-ValidationResult -Category $cat -Name "AD-$($ps.Label)-$dcIp" -Target $target -Status 'Fail' -Severity 'critical' -Detail 'ICMP port unreachable' -Remediation "Allow UDP/$($ps.Port) to the domain controller." -Source $learnAd }
                default { Add-ValidationResult -Category $cat -Name "AD-$($ps.Label)-$dcIp" -Target $target -Status 'Skip' -Detail 'UDP cannot prove open: no reply and no ICMP unreachable (open or filtered)' -Source $learnAd }
            }
        }
    }
    if (@($ValidationConfig.dcIps).Count -gt 0) {
        Add-ValidationResult -Category $cat -Name 'AD-RPC-Dynamic-49152-65535' -Target 'tcp 49152-65535' -Status 'Skip' `
            -Detail 'Not scanned: the RPC dynamic range (LSA, SAM, NetLogon, FRS, DFSR) is too large to probe; verify the firewall rule 49152-65535/TCP from the nodes to the DCs (RPC mapper TCP/135 is tested above).' -Source $learnAd
    }

    if ($ValidationConfig.adDomainFqdn -and @($ValidationConfig.dnsServers).Count -gt 0) {
        $srvName = "_ldap._tcp.dc._msdcs.$($ValidationConfig.adDomainFqdn)"
        $srv = Test-DnsSrvRecord -SrvName $srvName -DnsServer @($ValidationConfig.dnsServers)[0]
        $st = if ($srv.Success) { 'Pass' } else { 'Fail' }
        $dt = if ($srv.Success) { $srv.Detail } else { $srv.Error }
        Add-ValidationResult -Category $cat -Name 'AD-SRV-DCLocator' -Target $srvName -Status $st -Detail $dt
    } else {
        Add-ValidationResult -Category $cat -Name 'AD-SRV-DCLocator' -Target 'SRV' -Status 'Skip' -Detail 'AD domain or DNS servers not configured'
    }
}

function Get-EndpointFailureStatus {
    <# Severity -> status when a probe fails. Wildcard rows probed through a curated stand-in never exceed Warn. Pure. #>
    param([string]$Severity, [string]$ProbeHostBasis = '')
    if ($Severity -eq 'critical' -and $ProbeHostBasis -ne 'curated') { return 'Fail' }
    return 'Warn'
}

function Invoke-EndpointProbe {
    <# Probes one endpoint per its plan. Returns @{ Success; Detail; DurationMs }. #>
    param([object]$Endpoint, [hashtable]$Plan, [object]$ValidationConfig, [string]$ProxyUrl, [string[]]$ProxyBypass)
    $timeoutSec = [math]::Max(3, [int]($ValidationConfig.tcpConnectTimeoutMs / 1000))
    $path = ''
    if ($Endpoint.path) { $path = $Endpoint.path }
    if ($Plan.UseProxy) {
        $scheme = 'https'
        if ($Plan.Port -eq 80) { $scheme = 'http' }
        $h = Test-HttpsGet -TargetHost $Plan.Host -Port $Plan.Port -Path $path -Scheme $scheme -TimeoutSeconds $timeoutSec -ProxyUrl $ProxyUrl -ProxyBypass $ProxyBypass
        if ($h.Success) { return @{ Success = $true; Detail = "via proxy, HTTP $($h.HttpCode), $($h.DurationMs)ms"; DurationMs = $h.DurationMs } }
        return @{ Success = $false; Detail = "via proxy: $($h.Error)"; DurationMs = $h.DurationMs }
    }
    $tcp = Test-TcpConnect -TargetHost $Plan.Host -Port $Plan.Port -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
    if (-not $tcp.Success) { return @{ Success = $false; Detail = $tcp.Error; DurationMs = $tcp.DurationMs } }
    $detail = "$($tcp.DurationMs)ms"
    if ($Endpoint.severity -eq 'critical' -and $Endpoint.protocol -eq 'HTTPS') {
        $https = Test-HttpsGet -TargetHost $Plan.Host -Port $Plan.Port -Path $path -TimeoutSeconds $timeoutSec
        if (-not $https.Success) {
            return @{ Success = $false; Detail = "TCP ok but HTTPS probe failed: $($https.Error)"; DurationMs = ($tcp.DurationMs + $https.DurationMs) }
        }
        $detail = "TCP+HTTPS ok -- $($tcp.DurationMs)ms"
    }
    return @{ Success = $true; Detail = $detail; DurationMs = $tcp.DurationMs }
}

function Invoke-Category4EndpointSweep {
    param([object]$ValidationConfig, [object]$EndpointData, [string]$RegionName, [string]$ProxyUrl, [string[]]$ProxyBypass, [string]$GatewayFqdn)
    $cat = 'Cat-4-Endpoints'
    Out-ConsoleLine -Message "`n[Category 4] Azure Endpoint Sweep" -Color ([System.ConsoleColor]::Cyan)

    $set = Get-BeaconEndpointSet -Data $EndpointData -Region $RegionName -Oem $ValidationConfig.oem
    if ($set.FellBack) {
        $why = if ($RegionName) { "Region '$RegionName' has no published list" } else { 'No region configured' }
        Add-ValidationResult -Category $cat -Name 'Endpoint-Region' -Target $set.Region -Status 'Warn' -Severity 'warning' `
            -Detail "$why; using eastus. Set azureRegion or -Region to one of: $((Get-BeaconRegionKeys $EndpointData) -join ', ')" -Source $script:LearnFirewallUrl
    } else {
        Add-ValidationResult -Category $cat -Name 'Endpoint-Region' -Target $set.Region -Status 'Pass' -Detail "List updated $($set.LastUpdated); $($set.Endpoints.Count) entries" -Source $set.SourceUrl
    }
    $gatewayMode = [bool]$GatewayFqdn
    if ($gatewayMode) {
        Out-ConsoleLine -Message "  Arc gateway mode: endpoints the gateway carries are not probed directly." -Color ([System.ConsoleColor]::DarkGray)
    }
    if ($ProxyUrl) {
        $px = Test-TcpConnect -TargetHost ([System.Uri]$ProxyUrl).Host -Port ([System.Uri]$ProxyUrl).Port -TimeoutMs $ValidationConfig.tcpConnectTimeoutMs
        $pst = if ($px.Success) { 'Pass' } else { 'Fail' }
        Add-ValidationResult -Category $cat -Name 'Proxy-Reachable' -Target ([System.Uri]$ProxyUrl).Authority -Status $pst -Detail $(if ($px.Success) { "$($px.DurationMs)ms" } else { $px.Error }) `
            -Severity $(if ($px.Success) { '' } else { 'critical' })
    }
    Out-ConsoleLine -Message "  Testing $($set.Endpoints.Count) endpoints ($($set.Region)) ..." -Color ([System.ConsoleColor]::DarkGray)

    foreach ($ep in $set.Endpoints) {
        $plan = Get-ProbePlan -Endpoint $ep -ProxyUrl $ProxyUrl -ProxyBypass $ProxyBypass -GatewayMode $gatewayMode -GatewayFqdn $GatewayFqdn -KeyVaultFqdn $ValidationConfig.keyVaultFqdn
        $label = "EP-$($ep.host)"
        $target = "$($ep.host):$($ep.port)"
        if ($plan.Action -eq 'Skip') {
            Add-ValidationResult -Category $cat -Name $label -Target $target -Status 'Skip' -Detail $plan.Reason -Severity $ep.severity -Source $ep.source
            continue
        }
        $res = Invoke-EndpointProbe -Endpoint $ep -Plan $plan -ValidationConfig $ValidationConfig -ProxyUrl $ProxyUrl -ProxyBypass $ProxyBypass
        $detail = $res.Detail
        if ($ep.wildcard -and $plan.Host -ne $ep.host) { $detail = "$detail (representative host $($plan.Host))" }
        if ($res.Success) {
            Add-ValidationResult -Category $cat -Name $label -Target $target -Status 'Pass' -Detail $detail -DurationMs $res.DurationMs -Severity $ep.severity -Source $ep.source
        } else {
            $st = Get-EndpointFailureStatus -Severity $ep.severity -ProbeHostBasis $ep.probeHostBasis
            $rem = "Allow outbound $($ep.protocol) $($ep.port) to $($ep.host) ($($ep.component)); HTTPS inspection must be off for these names."
            Add-ValidationResult -Category $cat -Name $label -Target $target -Status $st -Detail $detail -DurationMs $res.DurationMs -Severity $ep.severity -Remediation $rem -Source $ep.source
        }
    }

    Invoke-PublicIpCheck -Endpoints $set.Endpoints
    Invoke-TlsInspectionCheck -ValidationConfig $ValidationConfig -ProxyUrl $ProxyUrl
}

function Invoke-PublicIpCheck {
    <# Learn: Arc Private Link Scopes are not supported; his/guestconfiguration/dp.kubernetesconfiguration must resolve to PUBLIC IPs. #>
    param([object[]]$Endpoints)
    $cat = 'Cat-4-Endpoints'
    $learn = $script:LearnFirewallUrl
    foreach ($h in (Get-PublicIpCheckTargets -Endpoints $Endpoints)) {
        $r = Invoke-DnsLookup -DnsHostname $h
        if (-not $r.Success) {
            Add-ValidationResult -Category $cat -Name "PublicIP-$h" -Target $h -Status 'Warn' -Detail "Does not resolve: $($r.Error)" -Source $learn
            continue
        }
        $private = @($r.AddressList | Where-Object { (Test-PublicIPv4 $_) -eq $false })
        if ($private.Count -gt 0) {
            Add-ValidationResult -Category $cat -Name "PublicIP-$h" -Target $h -Status 'Fail' -Severity 'critical' `
                -Detail "Resolves to a non-public address: $($private -join ', ')" `
                -Remediation 'Azure Local does not support Arc Private Link Scopes. Remove the private DNS zone / conditional forwarder for this name so it resolves to its public IP.' -Source $learn
        } else {
            Add-ValidationResult -Category $cat -Name "PublicIP-$h" -Target $h -Status 'Pass' -Detail "Public: $($r.Addresses)" -Source $learn
        }
    }
}

function Invoke-TlsInspectionCheck {
    <# Learn: Azure Local does not support HTTPS inspection. Compare the presented chain with the expected Microsoft/DigiCert issuers. #>
    param([object]$ValidationConfig, [string]$ProxyUrl)
    $cat = 'Cat-4-Endpoints'
    $learn = $script:LearnFirewallUrl
    foreach ($h in @(ConvertTo-StringList $ValidationConfig.tlsInspectionHosts)) {
        $c = Get-TlsCertificateChain -TargetHost $h -Port 443 -ProxyUrl $ProxyUrl
        if (-not $c.Success) {
            Add-ValidationResult -Category $cat -Name "TlsInspection-$h" -Target "${h}:443" -Status 'Warn' -Detail "Could not read the certificate chain: $($c.Error)" -Source $learn
            continue
        }
        $v = Get-TlsInspectionVerdict -Subjects $c.Subjects -Issuers $c.Issuers
        switch ($v.Verdict) {
            'Expected' { Add-ValidationResult -Category $cat -Name "TlsInspection-$h" -Target "${h}:443" -Status 'Pass' -Detail "Microsoft chain ($($v.Detail))" -Source $learn }
            'Suspected' {
                Add-ValidationResult -Category $cat -Name "TlsInspection-$h" -Target "${h}:443" -Status 'Warn' -Severity 'critical' -Detail "HTTPS inspection suspected: $($v.Detail)" `
                    -Remediation 'Azure Local does not support HTTPS inspection. Exempt the required endpoints from TLS inspection on the firewall/proxy.' -Source $learn
            }
            default { Add-ValidationResult -Category $cat -Name "TlsInspection-$h" -Target "${h}:443" -Status 'Warn' -Detail $v.Detail -Source $learn }
        }
    }
}

function New-NodeSession {
    <# Loopback PowerShell remoting session to this node (thin wrapper so tests can replace it). #>
    return (New-PSSession -ComputerName $env:COMPUTERNAME -ErrorAction Stop)
}

function Remove-NodeSession {
    param($Session)
    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
}

function Add-EnvCheckerResults {
    param([object[]]$Raw, [string]$Category, [string]$Prefix, [string]$SummaryName, [string]$SummaryTarget, [long]$DurationMs)
    $items = @(ConvertFrom-EnvCheckerResult -Results $Raw -Category $Category -Prefix $Prefix)
    $failed = @($items | Where-Object { $_.Status -ne 'Pass' -and $_.Status -ne 'Skip' })
    $st = 'Pass'
    if (@($items | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { $st = 'Fail' } elseif ($failed.Count -gt 0) { $st = 'Warn' }
    Add-ValidationResult -Category $Category -Name $SummaryName -Target $SummaryTarget -Status $st `
        -Detail ("{0}/{1} checks succeeded; {2} itemised below" -f (@($items | Where-Object { $_.Status -eq 'Pass' }).Count), $items.Count, $failed.Count) -DurationMs $DurationMs
    foreach ($i in $failed) { Add-ValidationResult @i }
}

function Invoke-EnvCheckerDelegated {
    <# From PowerShell 7, run category 5 in Windows PowerShell 5.1 (the module is net472) and merge the results. #>
    param([string]$ConfigDir, [string]$ResultsDir, [string]$RegionName)
    $cat = 'Cat-5-EnvChecker'
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps51)) { return $false }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("beacon-partial-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:ScriptRoot 'Start-AzlValidation.ps1'),
            '-Categories', '5', '-ConfigPath', $ConfigDir, '-ResultsPath', $ResultsDir, '-PartialResultsPath', $tmp, '-Region', $RegionName)
        if ($ProxyUrl) { $a += @('-ProxyUrl', $ProxyUrl) }
        & $ps51 @a
        if (Test-Path $tmp) {
            $rows = @(Get-Content $tmp -Raw | ConvertFrom-Json)
            foreach ($row in $rows) { $script:AllResults.Add($row); if ($row.Status -eq 'Fail') { $script:CriticalFail = $true } }
            return $true
        }
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Delegate' -Target 'powershell.exe' -Status 'Warn' -Detail 'Windows PowerShell 5.1 child produced no results'
        return $true
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Category5EnvironmentChecker {
    param([object]$ValidationConfig, [string]$ConfigDir, [string]$ResultsDir, [string]$RegionKey, [switch]$SkipChecks, [bool]$KeepReport = $true)
    $cat = 'Cat-5-EnvChecker'
    Out-ConsoleLine -Message "`n[Category 5] Azure Local Environment Checker (Microsoft validator)" -Color ([System.ConsoleColor]::Cyan)

    if ($SkipChecks) {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' -Status 'Skip' -Detail '-SkipEnvironmentChecker switch set'
        return
    }
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $PartialResultsPath -and -not $env:BEACON_ENVCHECKER_INPROCESS) {
        if (Invoke-EnvCheckerDelegated -ConfigDir $ConfigDir -ResultsDir $ResultsDir -RegionName $RegionKey) { return }
    }

    $manifest = Resolve-EnvCheckerManifest -Roots (Get-EnvCheckerModuleRoots -ScriptRoot $script:ScriptRoot)
    $moduleLoaded = $false
    if ($manifest) {
        try {
            Import-Module -Name $manifest -ErrorAction Stop -Force
            $moduleLoaded = $true
            Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' -Status 'Pass' -Detail "Loaded $(Split-Path (Split-Path $manifest -Parent) -Leaf) from $manifest"
        } catch {
            Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' -Status 'Warn' -Detail "Import failed: $($_.Exception.Message)"
        }
    } else {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Module' -Target 'AzStackHci.EnvironmentChecker' -Status 'Warn' `
            -Detail 'Module not found. Run scripts/Update-BeaconModules.ps1 and rebuild the image.'
    }
    if (-not $moduleLoaded) { return }

    # Connectivity (region, proxy and Arc gateway aware)
    try {
        $p = Get-EnvCheckerConnectivityParameters -Config $ValidationConfig -RegionKey $RegionKey
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Invoke-AzStackHciConnectivityValidation @p -ErrorAction Stop
        $sw.Stop()
        Add-EnvCheckerResults -Raw $raw -Category $cat -Prefix 'Connectivity' -SummaryName 'EnvChecker-Connectivity' -SummaryTarget 'Invoke-AzStackHciConnectivityValidation' -DurationMs $sw.ElapsedMilliseconds
    } catch {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Connectivity' -Target 'Invoke-AzStackHciConnectivityValidation' -Status 'Warn' -Detail "Validator threw: $($_.Exception.Message)"
    }

    # Network (needs real inputs and PSSessions to the nodes)
    $np = Get-EnvCheckerNetworkParameters -Config $ValidationConfig
    if (-not $np.CanRun) {
        Add-ValidationResult -Category $cat -Name 'EnvChecker-Network' -Target 'Invoke-AzStackHciNetworkValidation' -Status 'Skip' `
            -Detail "Skipped: $($np.Reason). The validator needs the intent, IP pool and management subnet plus a session to each node."
    } else {
        $session = $null
        try {
            $session = New-NodeSession
        } catch {
            Add-ValidationResult -Category $cat -Name 'EnvChecker-Network' -Target 'Invoke-AzStackHciNetworkValidation' -Status 'Skip' `
                -Detail "Skipped: no PowerShell remoting session to this node ($($_.Exception.Message)). Typical in WinPE; run the validator from a staging server instead."
        }
        if ($session) {
            try {
                $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
                $args2 = $np.Parameters
                $raw2 = Invoke-AzStackHciNetworkValidation @args2 -PSSession $session -ErrorAction Stop
                $sw2.Stop()
                Add-EnvCheckerResults -Raw $raw2 -Category $cat -Prefix 'Network' -SummaryName 'EnvChecker-Network' -SummaryTarget 'Invoke-AzStackHciNetworkValidation' -DurationMs $sw2.ElapsedMilliseconds
            } catch {
                Add-ValidationResult -Category $cat -Name 'EnvChecker-Network' -Target 'Invoke-AzStackHciNetworkValidation' -Status 'Warn' -Detail "Validator threw: $($_.Exception.Message)"
            } finally {
                Remove-NodeSession -Session $session
            }
        }
    }

    $reportSrc = Join-Path $HOME '.AzStackHci\AzStackHciEnvironmentReport.json'
    if ($KeepReport -and (Test-Path $reportSrc)) {
        try { Copy-Item $reportSrc (Join-Path $ResultsDir 'AzStackHciEnvironmentReport.json') -Force -ErrorAction Stop }
        catch { Write-Warning "Could not copy Environment Checker report: $_" }
    }
}

function Get-ArcInputs {
    <# Arc inputs from parameters, else process environment (set by the menu; never from disk). #>
    param([string]$Subscription, [string]$Tenant, [string]$ResourceGroup, [string[]]$Nodes, [string]$Cloud, [string]$ProxyUrl)
    if (-not $Subscription) { $Subscription = "$env:BEACON_ARC_SUBSCRIPTION" }
    if (-not $Tenant) { $Tenant = "$env:BEACON_ARC_TENANT" }
    if (-not $ResourceGroup) { $ResourceGroup = "$env:BEACON_ARC_RG" }
    if (@($Nodes).Count -eq 0) { $Nodes = @(ConvertTo-StringList $env:BEACON_ARC_NODES) }
    return @{ SubscriptionId = $Subscription; TenantId = $Tenant; ResourceGroup = $ResourceGroup; NodeNames = @($Nodes); Cloud = $Cloud; ProxyUrl = $ProxyUrl; ClientId = "$env:BEACON_ARC_CLIENT_ID" }
}

function Invoke-Category6Arc {
    param([hashtable]$ArcInputs, [switch]$SkipChecks)
    $cat = 'Cat-6-Arc'
    Out-ConsoleLine -Message "`n[Category 6] Arc Readiness (optional)" -Color ([System.ConsoleColor]::Cyan)
    if ($SkipChecks) {
        Add-ValidationResult -Category $cat -Name 'Arc-Readiness' -Target 'arc' -Status 'Skip' -Detail '-SkipArc switch set'
        return
    }
    if (-not $ArcInputs.SubscriptionId) {
        Add-ValidationResult -Category $cat -Name 'Arc-Readiness' -Target 'arc' -Status 'Skip' -Detail 'No subscription given (-ArcSubscriptionId or the menu prompt); Arc checks need Azure sign-in'
        return
    }
    Invoke-ArcReadinessChecks -ArcInputs $ArcInputs
}

#endregion

#region ================================================================
#  SUMMARY
#================================================================

function Write-ValidationSummary {
    param([object[]]$Results)
    $s = Get-ResultSummary -Results $Results
    $w = [System.ConsoleColor]::White
    Out-ConsoleLine -Message '' -Color $w
    Out-ConsoleLine -Message '================================================================' -Color $w
    Out-ConsoleLine -Message '  Azure Local Pre-Deployment Validation -- Summary' -Color $w
    Out-ConsoleLine -Message '================================================================' -Color $w
    Out-ConsoleLine -Message ("  Total checks : {0}" -f $s.total) -Color $w
    Out-ConsoleLine -Message ("  Pass         : {0}" -f $s.pass) -Color ([System.ConsoleColor]::Green)
    Out-ConsoleLine -Message ("  Fail         : {0}" -f $s.fail) -Color $(if ($s.fail -gt 0) { [System.ConsoleColor]::Red } else { [System.ConsoleColor]::Green })
    Out-ConsoleLine -Message ("  Warning      : {0}" -f $s.warn) -Color $(if ($s.warn -gt 0) { [System.ConsoleColor]::Yellow } else { [System.ConsoleColor]::Green })
    Out-ConsoleLine -Message ("  Skip         : {0}" -f $s.skip) -Color ([System.ConsoleColor]::DarkGray)
    Out-ConsoleLine -Message '' -Color $w
    if ($s.fail -gt 0) {
        Out-ConsoleLine -Message '  BLOCKING FAILURES:' -Color ([System.ConsoleColor]::Red)
        @($Results | Where-Object { $_.Status -eq 'Fail' }) | ForEach-Object {
            Out-ConsoleLine -Message ("    [FAIL] [{0}] {1} -- {2}" -f $_.Category, $_.Name, $_.Detail) -Color ([System.ConsoleColor]::Red)
        }
        Out-ConsoleLine -Message '' -Color $w
    }
    if ($s.warn -gt 0) {
        Out-ConsoleLine -Message '  WARNINGS (review before deployment):' -Color ([System.ConsoleColor]::Yellow)
        @($Results | Where-Object { $_.Status -eq 'Warn' }) | ForEach-Object {
            Out-ConsoleLine -Message ("    [WARN] [{0}] {1} -- {2}" -f $_.Category, $_.Name, $_.Detail) -Color ([System.ConsoleColor]::Yellow)
        }
        Out-ConsoleLine -Message '' -Color $w
    }
    if ($s.total -eq 0) {
        Out-ConsoleLine -Message '  Verdict: NO CHECKS RAN -- check -Categories input and config' -Color ([System.ConsoleColor]::Red)
    } elseif ($s.fail -gt 0) {
        Out-ConsoleLine -Message '  Verdict: NOT READY -- Fix blocking failures before deployment' -Color ([System.ConsoleColor]::Red)
    } else {
        Out-ConsoleLine -Message '  Verdict: READY -- No critical failures detected' -Color ([System.ConsoleColor]::Green)
    }
    Out-ConsoleLine -Message '================================================================' -Color $w
}

function Get-ExitCode {
    param([object[]]$Results)
    $r = @($Results)
    if (@($r | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { return 1 }
    if ($r.Count -eq 0) { return 2 }
    return 0
}

#endregion

#region ================================================================
#  ENTRY POINT  (skipped when the file is dot-sourced, e.g. by the Pester tests)
#================================================================

if ($MyInvocation.InvocationName -eq '.') { return }

$banner = "  Azure Local Pre-Deployment Validation v$($script:BeaconVersion)"
Out-ConsoleLine -Message '' -Color ([System.ConsoleColor]::White)
Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::Cyan)
Out-ConsoleLine -Message $banner -Color ([System.ConsoleColor]::Cyan)
Out-ConsoleLine -Message "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  (Azure Local $script:BeaconReleaseTrain)" -Color ([System.ConsoleColor]::Cyan)
Out-ConsoleLine -Message '================================================================' -Color ([System.ConsoleColor]::Cyan)

$resolvedConfigPath = Get-ConfigDirectory -Provided $ConfigPath -ScriptRoot $script:ScriptRoot
$resolvedResultsPath = Get-ResultsDirectory -Provided $ResultsPath

$cfg = Resolve-ConfigDefaults -Config (Import-JsonConfig -FilePath (Join-Path $resolvedConfigPath 'validation-config.json'))
$epData = Import-JsonConfig -FilePath (Join-Path $resolvedConfigPath 'endpoints.json')

$effRegion = if ($Region) { $Region } else { "$($cfg.azureRegion)" }
$effProxy = if ($ProxyUrl) { $ProxyUrl } else { "$($cfg.proxyUrl)" }
$effBypass = if (@($ProxyBypass).Count -gt 0) { @($ProxyBypass) } else { @(ConvertTo-StringList $cfg.proxyBypass) }
$effGateway = if ($ArcGatewayFqdn) { $ArcGatewayFqdn } else { "$($cfg.arcGatewayFqdn)" }
$cfg.proxyUrl = $effProxy
$cfg.arcGatewayFqdn = $effGateway
$regionKey = ConvertTo-BeaconRegionKey $effRegion
$epSet = Get-BeaconEndpointSet -Data $epData -Region $effRegion -Oem $cfg.oem

Out-ConsoleLine -Message "  Config       : $($cfg.clusterName) / $($epSet.Region)$(if ($effProxy) { ' / proxy' })$(if ($effGateway) { ' / Arc gateway' })" -Color ([System.ConsoleColor]::DarkGray)
if ($cfg.brand) { Out-ConsoleLine -Message "  $($cfg.brand)" -Color ([System.ConsoleColor]::DarkGray) }

$runCategories = ConvertTo-CategoryList -Categories $Categories
Out-ConsoleLine -Message "  Categories   : $($runCategories -join ', ')" -Color ([System.ConsoleColor]::DarkGray)

if ($runCategories -contains 1) { Invoke-Category1Network -ValidationConfig $cfg }
if ($runCategories -contains 2) { Invoke-Category2DnsCheck -ValidationConfig $cfg }
if ($runCategories -contains 3) { Invoke-Category3ActiveDirectory -ValidationConfig $cfg }
if ($runCategories -contains 4) {
    Invoke-Category4EndpointSweep -ValidationConfig $cfg -EndpointData $epData -RegionName $effRegion -ProxyUrl $effProxy -ProxyBypass $effBypass -GatewayFqdn $effGateway
}
if ($runCategories -contains 5) {
    Invoke-Category5EnvironmentChecker -ValidationConfig $cfg -ConfigDir $resolvedConfigPath -ResultsDir $resolvedResultsPath -RegionKey $epSet.Region -SkipChecks:$SkipEnvironmentChecker -KeepReport (-not $Redact)
}
if ($runCategories -contains 6) {
    $arcCloud = 'AzureCloud'
    if ($epSet.Cloud) { $arcCloud = $epSet.Cloud }
    $arcIn = Get-ArcInputs -Subscription $ArcSubscriptionId -Tenant $ArcTenantId -ResourceGroup $ArcResourceGroup -Nodes $ArcNodeNames -Cloud $arcCloud -ProxyUrl $effProxy
    Invoke-Category6Arc -ArcInputs $arcIn -SkipChecks:$SkipArc
}

if ($PartialResultsPath) {
    ConvertTo-Json -InputObject @($script:AllResults) -Depth 5 | Set-Content -Path $PartialResultsPath -Encoding UTF8
    exit 0
}

Write-ValidationSummary -Results $script:AllResults

$node = Get-BeaconNodeIdentity
$doc = New-BeaconResultsDocument -Results $script:AllResults -Context @{
    RunId = (New-BeaconRunId); Started = $script:StartTimeUtc; Finished = [DateTime]::UtcNow; Node = $node
    Region = $epSet.Region; RegionRequested = $effRegion; Oem = $cfg.oem
    ArcGatewayMode = [bool]$effGateway; ProxyConfigured = [bool]$effProxy
    Categories = $runCategories; EndpointSource = $epSet.SourceUrl
}
if ($Redact) { $doc = Invoke-BeaconRedaction -Document $doc -Map (Get-RedactionMap -Config $cfg -Node $node) }

$files = $null
try {
    $files = Save-BeaconResults -Document $doc -Directory $resolvedResultsPath
    Out-ConsoleLine -Message "  Results  : $($files.Json)" -Color ([System.ConsoleColor]::DarkGray)
    Out-ConsoleLine -Message "  Report   : $($files.Html)" -Color ([System.ConsoleColor]::DarkGray)
    if (-not $Redact) {
        Out-ConsoleLine -Message '  NOTE: results contain IP addresses, DC/host names, the domain and serial numbers. Use -Redact before sharing.' -Color ([System.ConsoleColor]::Yellow)
    }
} catch {
    Write-Warning "Could not save results: $_"
}
if ($ExportTo -and $files) {
    $ex = Export-BeaconResults -Files $files -Target $ExportTo
    $exColor = if ($ex.Ok) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Red }
    Out-ConsoleLine -Message "  Export   : $($ex.Kind) -- $($ex.Detail)" -Color $exColor
}

exit (Get-ExitCode -Results $script:AllResults)

#endregion
