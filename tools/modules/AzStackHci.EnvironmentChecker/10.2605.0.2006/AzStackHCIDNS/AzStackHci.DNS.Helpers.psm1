Import-LocalizedData -BindingVariable ldTxt -FileName AzStackHci.DNS.Strings.psd1

# This file contains a list of discreet tests that can be run against the environment
# Each test named Test-* is exported and discovered to be run by the user-facing function.
# The user uses Include and Exclude parameters to run specific tests. (this provides a consistent experience across validators)
# If tests have dependencies on other tests, or they should be run in a specific order, the pattern describe above should be removed.
function Test-ExternalDnsResolution
{
    <#
    .SYNOPSIS
        Validates external hostname resolution from all cluster nodes.
    .DESCRIPTION
        Tests that each configured DNS server on every cluster node can resolve an external hostname
        (default: microsoft.com). Uses Resolve-DnsName -DnsOnly against each DNS server independently.
        Retries up to 3 times with 5-second delays. Enables the DNS Client operational event log on
        the final retry attempt for diagnostic capture.

        If a web proxy is enabled (via netsh winhttp show advproxy), the test is skipped because the
        proxy may handle DNS resolution.

        Asserts: All DNS servers on all nodes can resolve the external hostname.
        Severity: CRITICAL — failure indicates broken outbound DNS which blocks deployment.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    .PARAMETER ExternalName
        The external hostname to resolve. Defaults to 'microsoft.com' if not specified.
        Exactly one name must be provided.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [string[]]
        $ExternalName
    )

    $SkipDnsWithProxy = $ldTxt.SkipDnsWithProxy
    # Test if proxy is enabled and return because proxy maybe doing dns resolution
    function IsProxyEnabled
    {
        $line1, $line2, $line3, $JsonLines = netsh winhttp show advproxy
        $proxy = $JsonLines | ConvertFrom-Json -ErrorAction SilentlyContinue
        [bool]$proxy.Proxy
    }

    if (IsProxyEnabled)
    {
        $testDnsServer = @{
            Resource  = $SkipDnsWithProxy
            Status    = 'SUCCESS'
            TimeStamp = [datetime]::UtcNow
            Source    = $ENV:COMPUTERNAME
            Detail    = $SkipDnsWithProxy -f $ENV:COMPUTERNAME
        }
    }
    else
    {
        if ([string]::IsNullOrEmpty($PSBoundParameters['ExternalName']))
        {
            Log-Info "No DNS target found, using microsoft.com as fall back" -ConsoleOut -Type Warning
            $ExternalName = @('microsoft.com')
        }
        if ($ExternalName.count -ne 1)
        {
            throw "Expected 1 System_Check_DNS_External_Hostname_Resolution, found $($ExternalName.count)"
        }

        $TestDNSResolutionParams = @{}
        if ($PSBoundParameters['PsSession'])
        {
            $TestDNSResolutionParams.Add('PsSession', $PsSession)
        }

        if ($PSBoundParameters['ExternalName'])
        {
            $TestDNSResolutionParams.Add('TargetName', $ExternalName)
        }

        $testDnsServer = TestDNSResolution @TestDNSResolutionParams
    }

    # Write result to verbose log
    $testDnsServer | Foreach-Object {
        Log-Info $_.Detail -Type $(if ( $_.Status -eq 'FAILURE' ){ "Critical" } else { "INFO" } )
    }

    # Collect lightweight per-node results for aggregation
    $detailResults = @()
    $detailResults += $testDnsServer | Foreach-Object {
        New-LightweightResult `
            -Name 'AzStackHci_DNS_Test_External_Hostname_Resolution' `
            -Status $PsItem.Status `
            -Severity 'Critical' `
            -TargetResourceName "$($PsItem.Source)/$($PsItem.Resource)" `
            -Source $PsItem.Source `
            -Resource $PsItem.Resource `
            -Detail $PsItem.Detail
    }

    return @(New-AggregatedTestResult `
        -TestName 'Test-ExternalDnsResolution' `
        -DisplayName 'External DNS Resolution' `
        -Description 'Validates external hostname resolution from each cluster node. Uses Resolve-DnsName -DnsOnly against all configured DNS servers to verify that the target hostname (default: microsoft.com) can be resolved. Tests each DNS server independently with up to 3 retries and 5-second delays between attempts. Enables DNS Client operational log on final retry for diagnostics.' `
        -DetailResults $detailResults `
        -ValidatorName 'DNS' `
        -ResourceType 'DNS' `
        -Remediation $ldTxt.ExternalDnsRemediation)
}

function Test-ActiveDirectoryDomainName
{
    <#
    .SYNOPSIS
        Validates Active Directory domain FQDN resolution from all cluster nodes.
    .DESCRIPTION
        Tests that each configured DNS server on every cluster node can resolve the Active Directory
        domain FQDN. Uses Resolve-DnsName -DnsOnly against each DNS server independently with up to
        3 retries and 5-second delays between attempts. Enables the DNS Client operational event log
        on the final retry for diagnostics.

        A resolvable AD domain name is required for domain join and cluster lifecycle operations.

        Asserts: All DNS servers on all nodes return a valid response for the domain FQDN.
        Severity: CRITICAL — failure blocks domain join.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    .PARAMETER DomainFQDN
        The Active Directory domain FQDN to resolve (e.g., 'contoso.local').
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [string[]]
        $DomainFQDN
    )

    $TestDNSResolutionParams = @{}
    if ($PSBoundParameters['PsSession'])
    {
        $TestDNSResolutionParams.Add('PsSession', $PsSession)
    }

    if ($PSBoundParameters['DomainFQDN'])
    {
        $TestDNSResolutionParams.Add('TargetName', $DomainFQDN)
    }

    $testDnsServer = TestDNSResolution @TestDNSResolutionParams

    # Write result to verbose log
    $testDnsServer | Foreach-Object {
        Log-Info $_.Detail -Type $(if ( $_.Status -eq 'FAILURE' ){ "Critical" } else { "INFO" } )
    }

    # Collect lightweight per-node results for aggregation
    $detailResults = @()
    $detailResults += $testDnsServer | Foreach-Object {
        New-LightweightResult `
            -Name 'AzStackHci_DNS_Test_ActiveDirectory_DomainName_Resolution' `
            -Status $PsItem.Status `
            -Severity 'Critical' `
            -TargetResourceName "$($PsItem.Source)/$($PsItem.Resource)" `
            -Source $PsItem.Source `
            -Resource $PsItem.Resource `
            -Detail $PsItem.Detail
    }

    return @(New-AggregatedTestResult `
        -TestName 'Test-ActiveDirectoryDomainName' `
        -DisplayName 'Active Directory Domain Name Resolution' `
        -Description 'Validates that the Active Directory domain FQDN can be resolved from each cluster node. Queries all configured DNS servers using Resolve-DnsName -DnsOnly with up to 3 retries per server. A resolvable AD domain name is required for domain join and cluster operations.' `
        -DetailResults $detailResults `
        -ValidatorName 'DNS' `
        -ResourceType 'DNS' `
        -Remediation $ldTxt.DomainNameDnsRemediation)
}

function Test-IPMapForClusterNodes
{
    <#
    .SYNOPSIS
        Validates that DNS A records for cluster nodes resolve to their expected IP addresses.
    .DESCRIPTION
        For each node in the physicalNodesSettings, constructs the FQDN (nodeName.domainFQDN) and
        queries all configured DNS servers using Resolve-DnsName -DnsOnly with up to 3 retries and
        5-second delays. Compares the returned IP addresses against the expected management IP from
        the deployment answer file.

        Asserts: Each node FQDN resolves to its expected IP address on every DNS server.
        Severity: INFORMATIONAL — mismatches are reported but do not block deployment because
        DNS records may be created dynamically during domain join.
    .PARAMETER PhysicalMachineIpMap
        Hashtable mapping node hostnames to their expected management IP addresses.
    .PARAMETER DomainFQDN
        The Active Directory domain FQDN used to construct node FQDNs.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    #>
    [CmdletBinding()]
    param (
        [hashtable]
        $PhysicalMachineIpMap,

        [string]
        $DomainFQDN,

        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try {
        $TestDNSResolutionParams = @{}
        if ($PSBoundParameters['PsSession'])
        {
            $TestDNSResolutionParams.Add('PsSession', $PsSession)
        }

        $IpMap = @{}
        foreach ($key in $PhysicalMachineIpMap.Keys)
        {
            $fqdnKey = "$key.$DomainFQDN"
            $IpMap.Add($fqdnKey, $PhysicalMachineIpMap[$key])
        }
        $TestDNSResolutionParams.Add('IpMap', $IpMap)
        $result = TestDNSResolution @TestDNSResolutionParams

        $detailResults = @()
        foreach ($res in $result)
        {
            Log-Info $res.Detail -Type $(if ( $res.Status -eq 'FAILURE' ){ "Critical" } else { "INFO" } )
            $detailResults += New-LightweightResult `
                -Name 'AzStackHci_DNS_Test_IPMap_For_Cluster_Nodes' `
                -Status $res.Status `
                -Severity 'INFORMATIONAL' `
                -TargetResourceName "$($res.Source)/$($res.Resource)" `
                -Source $res.Source `
                -Resource $res.Resource `
                -Detail $res.Detail
        }

        return @(New-AggregatedTestResult `
            -TestName 'Test-IPMapForClusterNodes' `
            -DisplayName 'IP Map For Cluster Nodes' `
            -Description 'Validates that DNS A records for each node in physicalNodesSettings resolve to the expected IP addresses. For each node, constructs the FQDN (nodeName.domainFQDN) and queries all configured DNS servers using Resolve-DnsName -DnsOnly. Compares returned IP addresses against the expected IP from the deployment answer file. Retries up to 3 times with 5-second delays.' `
            -DetailResults $detailResults `
            -ValidatorName 'DNS' `
            -ResourceType 'DNS' `
            -Remediation $ldTxt.IPMapRemediation)
    }
    catch {
        Log-Info "Test-IPMapForClusterNodes failed with error: $_" -Type WARNING
    }
}

function Test-LocalClusterDNSResolution
{
    <#
    .SYNOPSIS
        Validates that all cluster node names and the cluster name are resolvable in DNS.
    .DESCRIPTION
        Constructs FQDNs for each node (nodeName.domainFqdn) and the cluster (clusterName.domainFqdn),
        then queries all configured DNS servers using Resolve-DnsName -DnsOnly with up to 3 retries
        and 5-second delays. All names must be resolvable for cluster formation and lifecycle operations.

        If resolution fails and the environment uses Active Directory (not LocalIdentity), a secondary
        test checks for AD-integrated DNS zones via LDAP (TestAdIntegratedDns). If AD-integrated DNS
        is present, the local resolution failure is downgraded to INFORMATIONAL because cluster names
        will be dynamically registered during domain join.

        Asserts: Every DNS server can resolve all node FQDNs and the cluster FQDN.
        Severity: CRITICAL (downgraded to INFORMATIONAL if AD-integrated DNS passes).
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    .PARAMETER PhysicalMachineNames
        Array of node hostnames (short names without domain suffix).
    .PARAMETER ClusterName
        The cluster name (short name without domain suffix).
    .PARAMETER DomainFqdn
        The Active Directory domain FQDN for constructing fully-qualified names.
    .PARAMETER DomainCredential
        Credential for AD-integrated DNS zone lookup (used in fallback test).
    .PARAMETER IsLocalIdentityEnvironment
        Switch indicating an AD-less (LocalIdentity) deployment. When set, the AD-integrated
        DNS fallback test is skipped and failures remain CRITICAL.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [string[]]
        $PhysicalMachineNames,

        [string]
        $ClusterName,

        # AD integration parameters
        [Parameter()]
        [System.String]
        $DomainFqdn,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $DomainCredential,

        [Parameter()]
        [switch]
        $IsLocalIdentityEnvironment
    )

    $TestDNSResolutionParams = @{}
    $severity = 'Critical'
    if ($PSBoundParameters['PsSession'])
    {
        $TestDNSResolutionParams.Add('PsSession', $PsSession)
    }

    # Add fully qualified cluster and node names to resolve.
    # Cluster name is already fully qualified, so just add it to the list.
    $targetNames = @()
    $targetNames += $PhysicalMachineNames | ForEach-Object { "$_.$DomainFqdn" }
    $targetNames += "$ClusterName.$DomainFqdn"
    $TestDNSResolutionParams.Add('TargetName', $targetNames)

    $testDnsServer = TestDNSResolution @TestDNSResolutionParams

    # Write result to verbose log
    $testDnsServer | Foreach-Object {
        Log-Info $_.Detail -Type $(if ( $_.Status -eq 'FAILURE' ){ $severity } else { "INFO" } )
    }

    # Collect lightweight per-node results for aggregation
    $detailResults = @()
    $detailResults += $testDnsServer | Foreach-Object {
        New-LightweightResult `
            -Name 'AzStackHci_DNS_Test_Local_Cluster_DNS_Resolution' `
            -Status $PsItem.Status `
            -Severity $severity `
            -TargetResourceName "$($PsItem.Source)/$($PsItem.Resource)" `
            -Source $PsItem.Source `
            -Resource $PsItem.Resource `
            -Detail $PsItem.Detail
    }

    $LocalClusterDNSResult = @(New-AggregatedTestResult `
        -TestName 'Test-LocalClusterDNSResolution' `
        -DisplayName 'Local Cluster DNS Resolution' `
        -Description 'Validates that each DNS server can resolve all cluster node names and the cluster name. Constructs FQDNs for each node (nodeName.domainFqdn) and the cluster (clusterName.domainFqdn), then queries all configured DNS servers using Resolve-DnsName -DnsOnly with up to 3 retries and 5-second delays. All names must be resolvable for cluster formation and lifecycle operations.' `
        -DetailResults $detailResults `
        -ValidatorName 'DNS' `
        -ResourceType 'DNS' `
        -Remediation $ldTxt.LocalClusterDnsRemediation)

    # Check if the test failed and if so, check if AD integration test parameters are set
    # If AD integration test parameters are set, run the AD integrated DNS test
    # If the AD integrated DNS test fails, return the result of the AD integrated DNS test (critical) and the local cluster DNS test (critical)
    # If the AD integrated DNS test passes, return the result of the non AD integrated DNS test
    if ('FAILURE' -in $LocalClusterDNSResult.Status)
    {
        Log-Info -Message "Local Cluster member DNS resolution test failed. Checking if AD integration test parameters are set." -Type $severity

        # AD deployment's have DomainCredential and DomainFqdn set, AD-less deployments do not have these parameters set.
        if (-not $PSBoundParameters['IsLocalIdentityEnvironment'])
        {
            Log-Info -Message "AD integration test parameters are set. Running AD integrated DNS test." -Type $severity
            $adIntDnsResult = TestAdIntegratedDns -DomainFqdn $DomainFqdn -DomainCredential $DomainCredential

            # both tests have failed return both results
            if ($adIntDnsResult.Status -eq 'FAILURE')
            {
                Log-Info -Message "AD integrated DNS test failed. Returning both local resolution and AD integrated together" -Type $severity
                return ($LocalClusterDNSResult + $adIntDnsResult)
            }
            else
            {
                # This is happy path AD deployment has AD integrated DNS.
                Log-Info -Message "AD integrated DNS test passed. We don't need to block the life cycle operation. Returning AD Integrated DNS test result and downgrading A record test to informational."
                $LocalClusterDNSResult | ForEach-Object {
                    $_.Severity = 'INFORMATIONAL'
                    if ($_.AdditionalData -and $_.AdditionalData.ContainsKey('Detail')) { $_.AdditionalData['Detail'] += "`n[Severity downgraded from CRITICAL to INFORMATIONAL: AD Integrated DNS passed, cluster names will be dynamically registered]" }
                }
                return ($LocalClusterDNSResult + $adIntDnsResult)
            }
        }
        else
        {
            Log-Info -Message "AD integration test parameters are not set. Local Cluster member DNS resolution test failed. This will block lifecycle operation." -Type $severity
            return $LocalClusterDNSResult
        }
    }
    else
    {
        Log-info -Message "Local Cluster member DNS resolution test passed. Returning."
        return $LocalClusterDNSResult
    }
}

function TestDNSResolution
{
    <#
    .SYNOPSIS
        Test DNS Resolution of a target name by testing each dns server configured on any remote machine.
    .DESCRIPTION
        This function will test the DNS resolution of a target name by testing each DNS server configured on the machine. It will return the status of each DNS server and the result of the DNS query.
        It will also enable the DNS client operational log to get the logs for last attempt during failures. It will then disable the log if it was not enabled in the first place.
        It's intended to be a reusable function to facilitate the testing of DNS resolution in a consistent manner across types of names internal/external/node/cluster etc.

    #>
    [CmdletBinding()]
    param (
        [string[]]
        $TargetName,

        [hashtable]
        $IpMap,

        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try {
        # scriptblock to test dns resolution for each dns server
        $testDnsSb = {
            $TargetName = $args[0] -split ' '
            $IpMap = $args[1]

            # Pass in localized strings
            $NoDnsConfigured = $args[2]
            $QueryDnsFail = $args[3]
            $QueryDnsPass = $args[4]
            $ExpectedDnsResultPass = $args[5]
            $ExpectedDnsResultFail = $args[6]

            $AdditionalData = @()

            # Get local DNS servers
            $dnsServers = @()
            $netAdapter = Get-NetAdapter | Where-Object Status -EQ Up
            $dnsServer = Get-DnsClientServerAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4
            $dnsServers += $dnsServer | ForEach-Object { $PSITEM.Address } | Sort-Object | Get-Unique

            # set target name to ipmap key if applicable
            $UseMap = ![string]::IsNullOrEmpty($IpMap)
            if ($UseMap)
            {
                $TargetName = $IpMap.Keys
            }

            if (-not $dnsServers)
            {
                return @{
                    Resource  = $NoDnsConfigured
                    Status    = 'FAILURE'
                    TimeStamp = [datetime]::UtcNow
                    Source    = $ENV:COMPUTERNAME
                    Detail    = $NoDnsConfigured
                }
            }
            else
            {
                foreach ($target in $TargetName)
                {
                    foreach ($dnsServer in $dnsServers)
                    {
                        $status = 'FAILURE'
                        $attempt = 0
                        $maxRetry = 3
                        $sleepInSeconds = 5
                        while ($attempt -lt $maxRetry -and $status -eq 'FAILURE')
                        {
                            try
                            {
                                $attempt++
                                $dnsFailure = $null
                                # if this is the last attempt, check if the DNS client operational log is enabled, enabled it and reads the log for debug information
                                if ($attempt -eq ($maxRetry - 1))
                                {
                                    $wevtutilglcmd = "& wevtutil gl Microsoft-Windows-DNS-Client/Operational"
                                    $dnsLogState = Invoke-Expression -command $wevtutilglcmd | select-string -pattern "enabled: (.*)"
                                    if ($dnsLogState -like '*false')
                                    {
                                        # enable the dns log for 5 minutes to get the logs and set the size to 10MB
                                        & wevtutil sl Microsoft-Windows-DNS-Client/Operational /e:true /ms:10485760
                                        $dnsLogNeedsToBeDisabled = $true
                                    }
                                    else
                                    {
                                        $dnsLogAlreadyEnabled = $true
                                    }
                                    $preDnsTimeStamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ" -AsUTC
                                }
                                $dnsResult = Resolve-DnsName -Name $target -Server $dnsServer -DnsOnly -ErrorAction SilentlyContinue -QuickTimeout -Type A
                            }
                            catch {
                                $dnsFailure = $_.Exception.Message
                            }

                            if ([int]($dnsResult.count) -eq 0)
                            {
                                $detail = $QueryDnsFail -f $dnsServer, $target, $ENV:COMPUTERNAME, "$attempt/$maxRetry", [int]($dnsResult.count), $dnsFailure
                            }
                            else
                            {
                                $detail = $QueryDnsPass -f $dnsServer, $target, $ENV:COMPUTERNAME, "$attempt/$maxRetry", [int]($dnsResult.count), ($dnsResult.IpAddress -join ',')
                            }

                            if ($dnsResult)
                            {
                                if ($dnsResult[0] -is [Microsoft.DnsClient.Commands.DnsRecord])
                                {
                                    # If there is no IpMap provided, consider any valid response as success
                                    if (!$UseMap)
                                    {
                                        $status = 'SUCCESS'
                                        break
                                    }
                                    else
                                    {
                                        # If there the IpMap is provided but we don't have an expected IP for this target, consider any valid response as success
                                        # When we do have an expected IP for this target, check if the returned IPs contain the expected IP
                                        if ( -not $IpMap.ContainsKey($target) )
                                        {
                                            $status = 'SUCCESS'
                                            break
                                        }
                                        else
                                        {
                                            # Check if the returned IPs contain the expected IP
                                            if ($dnsResult.IpAddress -contains $IpMap[$target])
                                            {
                                                $status = 'SUCCESS'
                                                $detail = "`r`n" + ($ExpectedDnsResultPass -f $target, $ENV:COMPUTERNAME, $IpMap[$target], ($dnsResult.IpAddress -join ','), $dnsServer, "$attempt/$maxRetry")
                                                break
                                            }
                                            else
                                            {
                                                $status = 'FAILURE'
                                                $detail = "`r`n" + ($ExpectedDnsResultFail -f $target, $ENV:COMPUTERNAME, $IpMap[$target], ($dnsResult.IpAddress -join ','), $dnsServer, "$attempt/$maxRetry")
                                            }
                                        }
                                    }
                                }
                                else
                                {
                                    $status = 'FAILURE'
                                }
                            }
                            else
                            {
                                $status = 'FAILURE'
                            }
                            Start-Sleep -Second $sleepInSeconds
                        }

                        # If the dns log is enabled get the dns logs for this domain
                        if ($dnsLogNeedsToBeDisabled -eq $true -or $dnsLogAlreadyEnabled)
                        {
                            $xPathFilter = "*[System[Provider[@Name='Microsoft-Windows-DNS-Client']]] and *[EventData[Data[@Name='QueryName']='$target']] and *[System[TimeCreated[@SystemTime > '$preDnsTimeStamp']]]"
                            $dnsEvents = Get-WinEvent -LogName "Microsoft-Windows-DNS-Client/Operational" -FilterXPath $xPathFilter -ErrorAction SilentlyContinue | sort-object TimeCreated | Foreach-Object { "[{0}] [{1}] - {2}" -f $_.TimeCreated, $_.LevelDisplayName, $_.Message}
                            if ($dnsEvents)
                            {
                                $detail += "`n`nDNS Client Operational Log:`n$($dnsEvents -join "`r`n" | Out-String)"
                            }
                            # Disable the DNS client operational log if it was enabled in the first place
                            if ($dnsLogNeedsToBeDisabled -eq $true)
                            {
                                $wevtutilslCmd = "& wevtutil sl Microsoft-Windows-DNS-Client/Operational /e:false"
                                Invoke-Expression -Command $wevtutilslCmd
                            }
                        }

                        $AdditionalData += @{
                            Resource  = $dnsServer
                            Status    = $status
                            TimeStamp = [datetime]::UtcNow
                            Source    = $ENV:COMPUTERNAME
                            Detail    = $detail
                        }
                    }
                }

            }
            $AdditionalData
        }

        # run scriptblock
        $dnsargs = @{
            ArgumentList = $TargetName, $IpMap, $ldTxt.NoDnsConfigured, $ldTxt.QueryDnsFail, $ldTxt.QueryDnsPass, $ldTxt.ExpectedDnsResultPass, $ldTxt.ExpectedDnsResultFail
        }
        $testDnsServer = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $testDnsSb @dnsArgs
        }
        else
        {
            Invoke-Command -ScriptBlock $testDnsSb @dnsArgs
        }
        return $testDnsServer
    }
    catch
    {
        throw "Failed to run TestDNSResolution: $($_.Exception.Message)"
    }
}

function Get-LdapDomain {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Domain
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    $ldapDomain = ($Domain.Split('.') | ForEach-Object {"DC=$_"}) -join ','

    return $ldapDomain
}

function TestAdIntegratedDns {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    Param (
        [Parameter(Mandatory = $true)]
        [System.String]
        $DomainFqdn,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $DomainCredential
    )

    try {
        $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
        $severity = 'Critical'
        Log-Info -Message 'Importing module ActiveDirectory.'
        Import-Module ActiveDirectory -Verbose:$false

        # Convert domain name to fully qualified LDAP name
        $ldapDomain = Get-LdapDomain -Domain $DomainFqdn
        Log-Info -Message "LdapDomain to search is '$ldapDomain'."

        # Get forest root domain so we can search for forest zones as well as domain zones
        $rootDomain = Get-LdapDomain -Domain (Get-ADForest -Credential $DomainCredential -Server $DomainFqdn).RootDomain
        Log-Info -Message "RootDomain to search is '$rootDomain'."

        # Build list of locations to search - including legacy Windows 2000 locations
        $searchBases = @(
            "DC=$DomainFqdn,CN=MicrosoftDNS,DC=DomainDnsZones,$ldapDomain"
            "DC=$DomainFqdn,CN=MicrosoftDNS,CN=System,$ldapDomain"
            "DC=$DomainFqdn,CN=MicrosoftDNS,DC=ForestDnsZones,$rootDomain"
            "DC=$DomainFqdn,CN=MicrosoftDNS,CN=System,$rootDomain"
        )

        $result = $false

        # Search each location until one is found
        foreach ($searchBase in $searchBases) {
            if (-not $result) {
                Log-Info -Message "Searching for DNS zone container '$searchBase'."
                try {
                    $dnsZone = Get-ADObject -SearchBase $searchBase -LDAPFilter '(objectClass=dnsZone)' -Properties @('dnsProperty') -Credential $DomainCredential -Server $DomainFqdn
                    Log-Info -Message "Found DNS zone container '$searchBase'."
                    $result = $true
                }
                catch {
                    Log-Info -Message "DNS zone container '$searchBase' does not exist."
                }
            }
        }

        # Write to log file and set status
        if ($result) {
            $dtl = $ldTxt.AdIntDnsPass -f $rootDomain, $dnsZone.DistinguishedName
            Log-Info -Message $dtl
            $Status = 'SUCCESS'
        }
        else {
            $dtl = $ldTxt.AdIntDnsFail -f $rootDomain
            Log-Info -Message $dtl -Type $severity
            $Status = 'FAILURE'
        }

        # Write result
        $now = [datetime]::UtcNow
        $params = @{
            Name               = 'AzStackHci_DNS_Test_ActiveDirectory_Integrated_DNS'
            Title              = 'Test Active Directory Integrated DNS'
            DisplayName        = 'Test Active Directory Integrated DNS'
            Severity           = $severity
            Description        = 'Test Active Directory Integrated DNS'
            Tags               = @{
                Service        = 'System'
            }
            Remediation        = $ldTxt.AdIntDnsRemediation
            TargetResourceID   = "$ENV:COMPUTERNAME/$rootDomain"
            TargetResourceName = $rootDomain
            TargetResourceType = 'DNS'
            Timestamp          = $now
            Status             = $Status
            AdditionalData     = @{
                Resource = $rootDomain
                Source   = $ENV:COMPUTERNAME
                Status   = $Status
                Detail  = $dtl
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return (New-AzStackHciResultObject @params)
    }
    catch {
        throw "Error checking Active Directory Integrated DNS: $_"
    }
}

Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBOQpk4c1Uv2Rp4
# x+nNezTeHrkv0m6Q0QT2Oi9ZtTYXUqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnlMIIZ4QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICM6fMDi
# tSSlgOy9cAEBEiwqdR/pArY+S+5py5GxD/QtMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAsTJKcojW4d1j6KpSVXVLgOfikl964bI1KdsYUvQd
# KRdwJRYVcvXwrh493nPqz6L4P/WKqbsH9lWu69vJHcpupijrXtB+KTeq49ICKYBV
# RhisLlABXVVMbBRz+wODun01DchgJ7135dN7rLjLRYOzuM7jZO2i0vdH4nHSlUyJ
# JofXe9mQDaRV3ikHVolx9UOTpDdP83bbUnP7p0jzQ9dusPu669IwgNzMA3qbF2kV
# gmCctGcrLGwW1+3lrm/rJ9rCk3RwlCjwS9gmuecudZk3Z5PCckeSOAmHic30v7Ui
# oyTV3yTwVKpdwWR5eeQDfYUI2p4wcVTivF59AUcLPZgRz6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBaU/zxr0ffa1hX5M+s+8Hz8ck8+D7OZzVAaxII
# 7DTfhQIGaefB+1SWGBMyMDI2MDUwMzE0MzExMC45NzlaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046MzcwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAh86cGnkojAulQABAAAC
# HzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTFaFw0yNzA1MTcxOTM5NTFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzcwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLO8XFOcfGqAqgiz0+AmQmFl3d
# Z0aTG4UFJkqqNdMHy28DaheCBs6ONufukye5x42CWkzgRIy9kE2VWwEntZ8Zkgyr
# ykC0bIqsID7+6FxguseTXf1Vwvm1D8104VmetoBJlJ4uGbuyJZUvXDx55nVh50yg
# LTzZ24WkQsnPpvRZv2kPc39f3bhLyHVtnHsa/W/86Vrftd+AfFveA+qN/EY+XGj5
# c/DPMXCYECb0arYb92dDJWtwzpyBrp4gfHlgY1UEpc4l4AGELrf2J4wrxTzTW+SM
# 8XhV1dOOPrYjD080IbZqL8B+IF0RCdn269YXrGK6QIHipznKZcCS8jN30YAHnTJV
# N5Zzs6t/2YsqBGDquvDad7934FFTwzvUcO3VoIyd93XWwvP8/SCFVJh21W8oGQTp
# tGHyly+Fl4henVMVZF1v6osOtirX8GFTiEhnf8nRdOg7yZYAJ0xy9CtDfbXaTn/c
# f3Lq3N/GCYKFjC+5mUCE+AJhmxMuMdvSUGmKiAFdiPAjUTqsWWBBZJm0eCwgeGJF
# mmQA+V7/98BKcE+gUL7O9eWRDQwKeAcvo6rxNv2Y4jKrHA6Z/wi3a/fKUhLCNZES
# 8qGdrpDAm7qh+6FjYxytAbkiKM6uTNy/ULPlwtlYZoAJDDQP7eYCywwVbNTbHXRB
# SS+NccC0sSB4W7U67wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNk72sGDlH0r5Dwv
# fGR5XwJI8B7bMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBlbu3IoynnPz0K1iPb
# eNnsej2b15l5sdl2FAFBBGT9lRdc2gNV8LAIusPYHHhUvRDcsx4lbMNhVKPGu4TD
# LaqNt/CI+SFtGuqdRLpVP1XE9cCLyKrKPpcJFJCqPpV+efoAtYBmIUQcxxwT7WIQ
# 7gag8+rkKvrMkCoRqKS0mKv8J1sKfi85+G2uhZ/1RteSVdYZOZOj+Sb4wzonTCTj
# 7EtgMN/BX35W5dTzd7wJdGepYkVi871dSrC2Tr1ZFzAR7S44drCWZpJ6phJabVNO
# sNxFJKgSykugOGWzQ318Rr3MTPg2s3Bns+pUPVgMijd4bUOH2BlEsLMMwOcolTTZ
# qg1HYrdY1jxpUAI9ipjBQRINL/O705Z+/f2LjNmJQooCVJVX24adpZ519SsfazGo
# qXGt91bmqKo0fI09Il4sUHh4ih6rpiQDBlyL7vmvCejwVxYevY4qVwTZ/o3gvl+R
# 0lFxYS9feIM4NeG0+WsDZ7jLci5MFeuNwosQY3z26Xg1oj0U9u+ncR9uTU+xBmJ8
# BtlCdhQ13RNMX5P+krRYPB3XCp9Jm6XaO1995q32AIZm1mzBGI6yHlviXaEC5TzG
# iO1LXuPtXZU2X93oQJbMoe3v8+5CPKrQalGWyYuh2a3V1pwbj+W0FEmEFPpu8TI+
# qYO1IIQWUSRvFjXth5Ob02hMMjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjM3MDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQBLIMg1P7sNuCXpmbH2IXT2tXeEEKCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFn5DAiGA8y
# MDI2MDUwMzA2MjEyNFoYDzIwMjYwNTA0MDYyMTI0WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoWfkAgEAMAoCAQACAhT3AgH/MAcCAQACAhNsMAoCBQDtorlkAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAHq7s9YMgMpIuyTAwWsMxFD0DDmR
# QoXeyij+UMPaYdsxa3ei47tU4WE0xqHP+0mYPcDDrbUyiue3JiyjGqyZhs63H39t
# kyIRrg787TNyIuzMJH04BSpAsjQL9jKHDPuDN03FtnZFcxLvnFz+i2e1OAQ5Odan
# ScUkOnVkC7TLm/DMelMwJm5tfFkMo6hKZS1tLtKyjJBB8ZMZlm+35LeUNJBgFRCA
# D0iG1bZFVD09Rf7diPhBQPHI70wqiFkIrPwgHUS8EKHQ1RrMajudvnX/GWgSZH2L
# As6VIoh8Xy8inHRClIVPQeQvEclLgJYcJ7qPQRmfh7UZHYThMVUooesH7aYxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh86
# cGnkojAulQABAAACHzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCC9i4i759s2Wnap1wdKbd9acy8n
# uu8AJEnGyRv4WMUKeTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILAkCt9W
# kCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wIgQgXDVXUUgM
# F2UJ5kLBUeKOgKL/uQDhW3pavs3L2zobM+AwDQYJKoZIhvcNAQELBQAEggIATLjw
# P5daKONsxque5sCnbVFWrZmR7j8OxfHZkiZY4mMqZpbumVt4aAiYVgm2XSlt+WQV
# 7c6v5qC6EgLvOTRaMVH2q+AmQSADupvns9IN0pFXaeb8r9S/osjiGlBM8pJB43Ty
# tK7GpnA0h13Q6CMFFnvHyfAa0lNEnUjN9w3Kqucos6P7uHPMzo3FT2ZDLpNtH9hi
# tPx8EoS7JBcUorfJsNSRBg7YdzK1WUTuzh+hrr57cXxZKBoLbvzZ+VH7V5y9ersg
# f1KY+FX0PbXq7yV2Kx6UUnZggLqMe/urK5JqU0dcc+09WbMzVLiES2+2En4lUy0K
# dzw9FKCNcubcbmiIOpbogCSmH+g1UxPrF6LsoB21HPtljA0W13NcaZJgU9S5s5mi
# 168Vv5BsAAtWKY02R7hNCwuWkGbDW+rdjY+LPXVLop4M46fxz8ty/arM9ypfgh0T
# R2xGIDOEQws71vlQ3LUIfgSqlr3CM/1Ek8AtSyO1uqFgd1HWkyEweRj8hoqdUkxc
# NvPhFRaUKU9PGgDTBhCshGijpq6v5+1PZZIF+qiNmxTjNwq3BDoN8q5gunWkAOhD
# 3rK/Va4VcwmPokIIdnv4uCzwOlbCcTONS0yIg8oCX52TKm6M33KaV8eB5fX3Jxxi
# HX36iI0hShmUrPHLYf/XIrS+Z9kIicybpKGy8MM=
# SIG # End signature block
