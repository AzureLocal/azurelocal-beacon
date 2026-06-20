Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.Network.Strings.psd1
Import-Module $PSScriptRoot\..\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -DisableNameChecking -Global | Out-Null

Import-Module -Name NetworkATC -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name NetTCPIP -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name Hyper-V -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name NetAdapter -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name DnsClient -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null

#################################################################################################
# Network Validators
#   - Test-NwkValidator_StorageAdapterReadiness
#   - Test-NwkValidator_InfraIpPoolReadiness
#   - Test-NwkValidator_AKS_CidrOverlaps
#   - Test-NwkValidator_HostNetworkConfigurationReadiness
#   - Test-NwkValidator_AdapterDriverMgmtAdapterReadiness
#   - Test-NwkValidator_MgmtIpIpPoolRequirement
#   - Test-NwkValidator_MgmtIPForNewNode
#   - Test-NwkValidator_ClusterNetworkIntentStatus
#   - Test-NwkValidator_NetworkIntentRequirement
#   - Test-NwkValidator_StorageIntentExistence
#   - Test-NwkValidator_StorageConnectivityType
#   - Test-NwkValidator_NetworkATCFeatureStatusOnNewNode
#   - Test-NwkValidator_StorageAdapterIPConfigurationPreUpdate
#
# Note that the validator names are used in AzStackHci.Network.psm1 file to define which validators
# to be run in different scenarios. Please make sure to keep the validator names consistent between
# the files.
# Check the comments there for more information.
#################################################################################################
function Test-NwkValidator_StorageAdapterReadiness
{
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        [PSObject[]] $AtcHostIntents,
        [PSObject] $HostNetworkInfo = $null
    )

    try
    {
        # If customer provided customized storage IP, we will save the info here
        [System.Collections.Hashtable] $storageAdapterIpInfo = @{}

        # For the AtcHostIntents object array, we only need to check the storage only intents
        [PSObject[]] $storageIntents = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Storage") -and (-not $_.TrafficType.contains("Management")) -and (-not $_.TrafficType.contains("Compute")) }
        [String[]] $allPhysicalAdaptersToCheck = @()
        if ($storageIntents.Count -eq 1)
        {
            $allPhysicalAdaptersToCheck = $storageIntents[0].Adapter
            Log-Info "Will try to check storage adapters readiness for [ $($allPhysicalAdaptersToCheck -join ',') ]"

            if ($HostNetworkInfo) {
                [PSObject[]] $storageNetworkDefinition = $HostNetworkInfo.storageNetworks
                foreach ($storageNetworkInfo in $storageNetworkDefinition)
                {
                    # if end user provided storage adapter IP info, we will use it to validate the storage adapter configuration
                    if ($storageNetworkInfo.StorageAdapterIPInfo) {
                        $storageAdapterIpInfo.Add($storagenetworkInfo.networkAdapterName, $storageNetworkInfo.StorageAdapterIPInfo)
                    }
                }
            }
        }
        elseif ($storageIntents.Count -gt 1)
        {
            # Should not get into here as ATC does not support multiple storage intent, so the input $AtcHostIntents
            # object should not have multiple storage intent in it, but keep it here as a safe guard
            throw "More than one storage intent found in the AtcHostIntents object array. Fail the storage adapter configuration validation."
        }
        else
        {
            Log-Info "No storage only intent found in the AtcHostIntents object array. Skip the storage adapter configuration validation."
            return
        }

        $storageAdapterReadinessResults = @()

        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        #region Test storage adapter configuration
        # Now, check every adapter on all nodes in parallel
        foreach ($adapterName in $allPhysicalAdaptersToCheck) {
            [PSObject[]] $adapterIpInfoToCheck = @()
            if ($HostNetworkInfo) {
                $adapterIpInfoToCheck = $storageAdapterIpInfo[$adapterName]
            }

            Log-Info "Checking storage adapter [$adapterName] readiness on all nodes in parallel"
            $allAdapterResults = @(Invoke-Command -Session $allNodeSessions -ScriptBlock ${function:CheckStorageAdapterReadiness} -ArgumentList @($adapterName, $adapterIpInfoToCheck))

            foreach ($adapterReadinessResult in $allAdapterResults) {
                $nodeName = $adapterReadinessResult.PSComputerName
                Log-Info "Got storage adapter readiness validation results from $nodeName"
                $storageAdapterReadinessValidationStatus = if ($adapterReadinessResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
                $storageAdapterReadinessValidationDetailMessage = $adapterReadinessResult.Failures

                $storageAdapterReadinessRstObject = @{
                    Name               = 'AzureLocal_Network_Test_StorageAdapterReadiness'
                    Title              = 'Validate that the Storage Adapters are ready for deployment'
                    DisplayName        = 'Validate that the Storage Adapters are ready for deployment'
                    Severity           = 'CRITICAL'
                    Description        = 'Validates that the Storage adapters on the node do not have Manual/DHCP IP Addresses or VLANID or Default gateway configured. There should not be multiple Storage adapters with the same name on the same node.'
                    Tags               = @{}
                    Remediation        = "https://aka.ms/azurelocal/envvalidator/storageadapterreadiness"
                    TargetResourceID   = "$nodeName, $($adapterName)"
                    TargetResourceName = "$nodeName, $($adapterName)"
                    TargetResourceType = "StorageAdapter"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $storageAdapterReadinessValidationStatus
                    AdditionalData     = @{
                        Source    = "$nodeName, $($adapterName)"
                        Resource  = 'StorageAdapter'
                        Detail    = $storageAdapterReadinessValidationDetailMessage
                        Status    = $storageAdapterReadinessValidationStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $storageAdapterReadinessResults += New-AzStackHciResultObject @storageAdapterReadinessRstObject
            }
        }
        #endregion

        return $storageAdapterReadinessResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_SanClusterNetworkAdapterReadiness
{
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        [PSObject] $HostNetworkInfo = $null,
        [System.String] $StorageType = "S2D"
    )

    try
    {
        if ($StorageType -ine 'SAN') {
            Log-Info "StorageType is [ $StorageType ], not SAN. Skip SAN cluster network adapter readiness check."
            return @()
        }

        if ($null -eq $HostNetworkInfo -or $null -eq $HostNetworkInfo.sanNetworks) {
            Log-Info "No sanNetworks found in HostNetworkInfo. Skip SAN cluster network adapter readiness check."
            return @()
        }

        $sanClusterNetConfig = $HostNetworkInfo.sanNetworks.clusterNetworkConfig
        if ($null -eq $sanClusterNetConfig -or $null -eq $sanClusterNetConfig.adapterIPConfig) {
            Log-Info "No clusterNetworkConfig or adapterIPConfig found in sanNetworks. Skip SAN cluster network adapter readiness check."
            return @()
        }

        [PSObject[]] $adapterIPConfigs = $sanClusterNetConfig.adapterIPConfig
        [System.String[]] $allSanAdapterNames = $adapterIPConfigs | ForEach-Object { $_.networkAdapterName }
        Log-Info "Will check SAN cluster network adapter readiness for [ $($allSanAdapterNames -join ', ') ]"

        $sanAdapterReadinessResults = @()

        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        foreach ($adapterName in $allSanAdapterNames) {
            Log-Info "Checking SAN cluster network adapter [ $adapterName ] readiness on all nodes in parallel"
            $allAdapterResults = @(Invoke-Command -Session $allNodeSessions -ScriptBlock ${function:CheckStorageAdapterReadiness} -ArgumentList $adapterName, @())

            foreach ($adapterReadinessResult in $allAdapterResults) {
                $nodeName = $adapterReadinessResult.PSComputerName
                Log-Info "Got SAN adapter readiness validation results from $nodeName"
                $validationStatus = if ($adapterReadinessResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
                $validationDetailMessage = $adapterReadinessResult.Failures

                $rstObject = @{
                    Name               = 'AzureLocal_Network_Test_SanClusterNetworkAdapterReadiness'
                    Title              = 'Validate that the SAN Cluster Network Adapters are ready for deployment'
                    DisplayName        = 'Validate that the SAN Cluster Network Adapters are ready for deployment'
                    Severity           = 'CRITICAL'
                    Description        = 'Validates that the SAN cluster network adapters on the node do not have Manual/DHCP IP Addresses or VLANID or Default gateway configured. There should not be multiple adapters with the same name on the same node.'
                    Tags               = @{}
                    Remediation        = "https://aka.ms/azurelocal/envvalidator/storageadapterreadiness"
                    TargetResourceID   = "$nodeName, $($adapterName)"
                    TargetResourceName = "$nodeName, $($adapterName)"
                    TargetResourceType = "SanClusterNetworkAdapter"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $validationStatus
                    AdditionalData     = @{
                        Source    = "$nodeName, $($adapterName)"
                        Resource  = 'SanClusterNetworkAdapter'
                        Detail    = $validationDetailMessage
                        Status    = $validationStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $sanAdapterReadinessResults += New-AzStackHciResultObject @rstObject
            }
        }

        return $sanAdapterReadinessResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_InfraIpPoolReadiness
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [Parameter(Mandatory = $false, HelpMessage = "Specify Management Subnet")]
        [string] $ManagementSubnetValue,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the region name to target for connectivity validation.")]
        [string] $RegionName,

        [int[]]
        $port = @(5986, 5985, 22),

        [int]
        $Timeout = 1000,

        [int]
        $Minimum = 6,

        [int]
        $Maximum = 255,

        [PSObject[]] $AtcHostIntents,

        [System.Boolean] $ProxyEnabled = $false
    )
    try
    {
        $instanceResults = @()
        $MaxParallelJobs = EnvValidatorNwkLibGetMaxParallelJobs -DefaultMaxParallelJobs 20

        # Check no repeating ips in pool and all in management subnet
        Log-Info "Test no repeating ips in all IP pools"
        $testIpInSameSubnetNoRepeatIp = TestMgmtIpPools -IpPools $IpPools -ManagementSubnetValue $ManagementSubnetValue
        $Status = if ($testIpInSameSubnetNoRepeatIp) { 'SUCCESS' } else { 'FAILURE' }
        $params = @{
            Name               = "AzStackHci_Network_Test_IP_Pools_Subnet_No_Duplicates"
            Title              = 'Test IP Pools in Management Subnet and No duplicate IPs in IpPools'
            DisplayName        = "Test IP Pools $ManagementSubnetValue"
            Severity           = 'CRITICAL'
            Description        = 'Checking start and end address are on the same subnet'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "IpPool-$ManagementSubnetValue"
            TargetResourceName = "ManagementIPRange"
            TargetResourceType = 'Network Range'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = 'CustomerNetwork'
                Resource  = 'CustomerSubnet'
                Detail    = if ($testIpInSameSubnetNoRepeatIp) { $lnTxt.TestIpPoolPass -f $ManagementSubnetValue } else { $lnTxt.TestIpPoolFail -f $ManagementSubnetValue }
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        Log-Info "Test all IP in IP pools are in management subnet, and no IP in IP pools are in use"
        foreach ($ipPool in $IpPools)
        {
            $StartingAddress = $ipPool.StartingAddress
            $EndingAddress = $ipPool.EndingAddress

            # Check ip in management subnet
            $TestMgmtSubnet = (CheckIPInSubnet -IPAddress $StartingAddress -CIDR $ManagementSubnetValue) -and (CheckIPInSubnet -IPAddress $EndingAddress -CIDR $ManagementSubnetValue)
            $Status = if ($TestMgmtSubnet) { 'SUCCESS' } else { 'FAILURE' }
            $params = @{
                Name               = 'AzStackHci_Network_Test_Management_IP_Range_Subnet'
                Title              = 'Test Management IP Subnet'
                DisplayName        = "Test Management IP Subnet $StartingAddress - $EndingAddress"
                Severity           = 'CRITICAL'
                Description        = 'Checking start and end address are on the same subnet'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = "$StartingAddress-$EndingAddress"
                TargetResourceName = "ManagementIPRange"
                TargetResourceType = 'Network Range'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = 'CustomerNetwork'
                    Resource  = 'CustomerSubnet'
                    Detail    = if ($TestMgmtSubnet) { $lnTxt.TestMgmtSubnetPass -f $StartingAddress, $EndingAddress } else { $lnTxt.TestMgmtSubnetFail -f $StartingAddress, $EndingAddress }
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params

            # Test IP in Range are not in use
            $MgmtIpRange = EnvValidatorNwkLibGetIpRange -StartingAddress $StartingAddress -EndingAddress $EndingAddress

            # Magic number for IP range size to check: 6, min infra IP requirement
            if ($MgmtIpRange.Count -le 6)
            {
                #region Sequential path for small IP pools (job overhead not worthwhile)
                foreach ($Ip in $MgmtIpRange)
                {
                    $result = @{}
                    $result += @{
                        'Ping' = Test-NetConnection -ComputerName $Ip -InformationLevel Quiet -WarningAction SilentlyContinue
                    }
                    foreach ($p in $port)
                    {
                        $result += @{
                            $p = IsTcpPortInUse -Ip $ip -Port $p -Timeout $Timeout
                        }
                    }
                    $Status = if ($true -notin $result.Values) { 'SUCCESS' } else { 'FAILURE' }
                    $msg = $lnTxt.ActiveHostCheck -f $ip, (($result.Keys | ForEach-Object { "{0}:{1}" -f $psitem,$result[$psitem] }) -join ', ')
                    $Type = if ($result.Values -contains $true) { 'WARNING' } else { 'INFORMATIONAL' }
                    Log-Info $msg -Type $Type

                    $params = @{
                        Name               = 'AzStackHci_Network_Test_Management_IP_No_Active_Hosts'
                        Title              = 'Test Management IP Range for Active Hosts'
                        DisplayName        = "Test Management IP Range $Ip for Active Hosts"
                        Severity           = 'CRITICAL'
                        Description        = 'Checking no hosts respond on Management IP range'
                        Tags               = @{}
                        Remediation        = 'https://aka.ms/hci-envch'
                        TargetResourceID   = $Ip
                        TargetResourceName = "ManagementIPRange"
                        TargetResourceType = 'Network Range'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $Status
                        AdditionalData     = @{
                            Source    = $Ip
                            Resource  = 'ICMP/SSH/WINRM'
                            Detail    = ($result.Keys | ForEach-Object { "{0}:{1}" -f $psitem,$result[$psitem] }) -join ', '
                            Status    = $Status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                }
                #endregion
            }
            else
            {
                #region Parallel path for larger IP pools using Start-Job with throttling
                Log-Info "Checking $($MgmtIpRange.Count) IPs in parallel (max $MaxParallelJobs concurrent jobs)"

                # Serialize IsTcpPortInUse for cross-job boundary use
                $isTcpPortInUseFuncStr = ${function:IsTcpPortInUse}.ToString()

                $ipCheckJobScript = {
                    param($CheckIp, $Ports, $CheckTimeout, $IsTcpPortInUseFuncStr)

                    # Recreate IsTcpPortInUse in the job runspace
                    $isTcpFunc = [scriptblock]::Create($IsTcpPortInUseFuncStr)
                    New-Item -Path "Function:\IsTcpPortInUse" -Value $isTcpFunc -Force | Out-Null

                    $result = @{}
                    $result['Ping'] = Test-NetConnection -ComputerName $CheckIp -InformationLevel Quiet -WarningAction SilentlyContinue
                    foreach ($p in $Ports)
                    {
                        $result[$p] = IsTcpPortInUse -Ip $CheckIp -Port $p -Timeout $CheckTimeout
                    }
                    return [pscustomobject]@{
                        Ip     = $CheckIp
                        Result = $result
                    }
                }

                # Phase 1: Spawn jobs with throttling
                $jobInfos = @()
                $inProgressJobs = @()
                $allJobIds = @()

                foreach ($Ip in $MgmtIpRange)
                {
                    $job = Start-Job -ScriptBlock $ipCheckJobScript -ArgumentList $Ip, $port, $Timeout, $isTcpPortInUseFuncStr
                    $jobInfos += @{ Job = $job; Ip = $Ip }
                    $inProgressJobs += $job
                    $allJobIds += $job.Id

                    if ($inProgressJobs.Count -ge $MaxParallelJobs)
                    {
                        # Throttle: wait for any one job to finish before starting the next
                        $null = Wait-Job -Id @($inProgressJobs | ForEach-Object { $_.Id }) -Any
                        # Remove all completed jobs from the in-progress list
                        $completedIds = @(Get-Job -Id @($inProgressJobs | ForEach-Object { $_.Id }) | Where-Object { $_.State -ne 'Running' } | ForEach-Object { $_.Id })
                        if ($completedIds.Count -gt 0)
                        {
                            $inProgressJobs = @($inProgressJobs | Where-Object { $_.Id -notin $completedIds })
                        }
                    }
                }

                # Wait for all remaining jobs to complete
                if ($allJobIds.Count -gt 0)
                {
                    Wait-Job -Id $allJobIds | Out-Null
                }

                # Phase 2: Collect results and build result objects
                foreach ($jobInfo in $jobInfos)
                {
                    $output = Receive-Job -Id $jobInfo.Job.Id
                    $ip = $output.Ip
                    $result = $output.Result

                    $Status = if ($true -notin $result.Values) { 'SUCCESS' } else { 'FAILURE' }
                    $msg = $lnTxt.ActiveHostCheck -f $ip, (($result.Keys | ForEach-Object { "{0}:{1}" -f $psitem,$result[$psitem] }) -join ', ')
                    $Type = if ($result.Values -contains $true) { 'WARNING' } else { 'INFORMATIONAL' }
                    Log-Info $msg -Type $Type

                    $params = @{
                        Name               = 'AzStackHci_Network_Test_Management_IP_No_Active_Hosts'
                        Title              = 'Test Management IP Range for Active Hosts'
                        DisplayName        = "Test Management IP Range $Ip for Active Hosts"
                        Severity           = 'CRITICAL'
                        Description        = 'Checking no hosts respond on Management IP range'
                        Tags               = @{}
                        Remediation        = 'https://aka.ms/hci-envch'
                        TargetResourceID   = $Ip
                        TargetResourceName = "ManagementIPRange"
                        TargetResourceType = 'Network Range'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $Status
                        AdditionalData     = @{
                            Source    = $Ip
                            Resource  = 'ICMP/SSH/WINRM'
                            Detail    = ($result.Keys | ForEach-Object { "{0}:{1}" -f $psitem,$result[$psitem] }) -join ', '
                            Status    = $Status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                }

                # Cleanup jobs
                if ($allJobIds.Count -gt 0)
                {
                    Remove-Job -Id $allJobIds -Force -ErrorAction SilentlyContinue
                }
                #endregion
            }
        }

        # Check range size
        Log-Info "Test infra pool range size"
        $TestMgmtRangeSize = TestMgmtRangeSize -IpPools $IpPools -Minimum $Minimum -Maximum $Maximum
        $status = if ($TestMgmtRangeSize) { 'SUCCESS' } else { 'FAILURE' }
        $allIps = EnvValidatorNwkLibGetMgmtIpRangeFromPools -IpPools $IpPools
        $ipCount = $allIps.Count
        $params = @{
            Name               = 'AzStackHci_Network_Test_Management_IP_Range_Size'
            Title              = 'Test Management IP Range Size'
            DisplayName        = "Test Management IP Range Size of all the pools. $ipCount ips found."
            Severity           = 'CRITICAL'
            Description        = "Checking management IP range size is between $minimum-$maximum"
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "Size:$ipCount "
            TargetResourceName = "ManagementIPRange"
            TargetResourceType = 'Network Range'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = 'CustomerNetwork'
                Resource  = 'CustomerRange'
                Detail    = if ($TestMgmtRangeSize) { $lnTxt.TestMgmtRangeSizePass -f $Minimum, $Maximum } else { $lnTxt.TestMgmtRangeSizeFail -f $Minimum, $Maximum }
                Status    = if ($TestMgmtRangeSize) { 'SUCCESS' } else { 'FAILURE' }
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        # Check pool sizes
        Log-Info "Test infra pool size"
        $TestMgmtRangePoolCount = TestMgmtRangePoolCount -IpPools $IpPools -Minimum $Minimum
        $poolCount = $IpPools.Count
        $status = if ($TestMgmtRangePoolCount) { 'SUCCESS' } else { 'FAILURE' }
        $params = @{
            Name               = 'AzStackHci_Network_Test_Management_IP_Range_Pool_Count'
            Title              = 'Test Management IP Pool Count'
            DisplayName        = "Test Management IP Range Number of IP Pools."
            Severity           = 'CRITICAL'
            Description        = "Checking management IP pools has one or two pools. First pool must only have 1 ip if 2 pools"
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "Count:$poolCount "
            TargetResourceName = "ManagementIPRange"
            TargetResourceType = 'Network Range'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = 'CustomerNetwork'
                Resource  = 'CustomerRange'
                Detail    = if ($TestMgmtRangePoolCount) { $lnTxt.TestMgmtRangePoolCountPass -f $poolCount} else { $lnTxt.TestMgmtRangePoolCountFail -f $poolCount, ($Minimum - 1) }
                Status    = if ($TestMgmtRangePoolCount) { 'SUCCESS' } else { 'FAILURE' }
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        return $instanceResults
    }
    catch
    {
        throw $_
    }
    finally
    {
        # Device Management Service might need to be restarted to refresh the nic details
        # It also might not be there
        if (Get-Service -Name DeviceManagementService -ErrorAction SilentlyContinue)
        {
            Restart-Service -Name DeviceManagementService -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 20
            Log-Info "Restarted the Device Management Service successfully and waited 20 seconds which should refresh the nic details"
        }
    }
}

function Test-NwkValidator_AKS_CidrOverlaps
{
        <#
    .SYNOPSIS
        1. POD CIDR subnet shall not overlap with customer network
        2. Service CIDR subnet shall warn overlaps with customer network.
        #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [Parameter(Mandatory = $false, HelpMessage = "Specify POD CIDR if not default setting: 10.244.0.0/16")]
        [string] $PODCidr = "10.244.0.0/16",

        [PSObject[]] $AtcHostIntents
    )

    try
    {
        $instanceResults = @()
        $ServiceCidr = "10.96.0.0/12"

        Log-Info "Test for overlaps with POD CIDR range $PODCidr" -ConsoleOut
        foreach ($ipPool in $IpPools)
        {
            $StartingAddress = $ipPool.StartingAddress
            $EndingAddress = $ipPool.EndingAddress
            $Status = "FAILURE"

            # Check IPs in range are not in Kubernetes POD subnet range.
            $TestCidrSubnet = (CheckIPInSubnet -IPAddress $StartingAddress -CIDR $PODCidr) -or (CheckIPInSubnet -IPAddress $EndingAddress -CIDR $PODCidr)

            if ($TestCidrSubnet)
            {
                Log-Info "IP Range: $StartingAddress - $EndingAddress overlaps with K8s Default POD CIDR: $PODCidr. Please reconfigure the network to resolve this conflict." -Type 'Error' -ConsoleOut
            }
            else
            {
                $Status = 'SUCCESS'
            }

            $params = @{
                Name               = 'AzStackHci_Network_Test_AKS_Subnet_POD_CIDR_IP_Range_Overlap'
                Title              = "Test for overlaps with POD CIDR Subnet $PODCidr"
                DisplayName        = "Test for overlaps with POD CIDR Subnet $PODCidr"
                Severity           = 'INFORMATIONAL'
                Description        = "Checking start and end address are not within the POD CIDR Subnet $PODCidr"
                Tags               = @{}
                Remediation        = '"Verify IP pool(s) are not overlapping with AKS pre-defined POD subnet. Check https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-hci-ip-address-planning for more information.'
                TargetResourceID   = "IpPool-$StartingAddress-$EndingAddress"
                TargetResourceName = "ManagementIPRange"
                TargetResourceType = 'Network Range'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = 'CustomerNetwork'
                    Resource  = 'CustomerSubnet'
                    Detail    = if ($TestCidrSubnet) { $lnTxt.TestPodCidrSubnetFail -f $StartingAddress, $EndingAddress, $PODCidr } else { $lnTxt.TestPodCidrSubnetPass -f $StartingAddress, $EndingAddress, $PODCidr }
                    Status    = $Status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        Log-Info "Test for overlaps with Service CIDR range $ServiceCidr" -ConsoleOut
        foreach ($ipPool in $IpPools)
        {
            $StartingAddress = $ipPool.StartingAddress
            $EndingAddress = $ipPool.EndingAddress
            $Status = "FAILURE"

            # Check IPs in range are not in Kubernetes Service subnet range.
            $TestCidrSubnet = (CheckIPInSubnet -IPAddress $StartingAddress -CIDR $ServiceCidr) -or (CheckIPInSubnet -IPAddress $EndingAddress -CIDR $ServiceCidr)

            if ($TestCidrSubnet)
            {
                Log-Info "IP Range: $StartingAddress - $EndingAddress overlaps with K8s Default Service CIDR: $ServiceCidr. Be aware that this many result in suboptimal network conditions." -Type 'WARNING' -ConsoleOut
            }
            else
            {
                $Status = 'SUCCESS'
            }

            $params = @{
                Name               = 'AzStackHci_Network_Test_AKS_Subnet_Service_CIDR_IP_Range_Overlap'
                Title              = "Test for overlaps with Service CIDR IP Subnet $ServiceCidr"
                DisplayName        = "Test for overlaps with Service CIDR IP Subnet $ServiceCidr"
                Severity           = 'INFORMATIONAL'
                Description        = 'Checking start and end address are not within the Service CIDR Subnet'
                Tags               = @{}
                Remediation        = "Verify IP pool(s) are not overlapping with AKS pre-defined Service subnet. Check https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-hci-ip-address-planning for more information."
                TargetResourceID   = "IpPool-$StartingAddress-$EndingAddress"
                TargetResourceName = 'ManagementIPRange'
                TargetResourceType = 'Network Range'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = 'CustomerNetwork'
                    Resource  = 'CustomerSubnet'
                    Detail    = if ($TestCidrSubnet) { $lnTxt.TestServiceCidrSubnetFail -f $StartingAddress, $EndingAddress, $ServiceCidr } else { $lnTxt.TestServiceCidrSubnetPass -f $StartingAddress, $EndingAddress, $ServiceCidr }
                    Status    = $Status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        #region Check DNS Server overlaps with POD CIDR and Service CIDR
        Log-Info "Test for DNS server overlaps with POD CIDR range $PODCidr and $ServiceCidr"
        [PSObject[]] $mgmtIntent = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Management") }
        [System.String] $intentName = $mgmtIntent[0].Name
        [System.String] $mgmtPhysicalAdapterName = $mgmtIntent[0].Adapter[0]
        [System.String] $mgmtVirtualAdapterName = "vManagement($intentName)"

        [PSObject[]] $mgmtVirtualAdapterExists = @()
        try {
            Log-Info "Check if virtual adapter $mgmtVirtualAdapterName is defined in the system..."
            $mgmtVirtualAdapterExists = Get-VMNetworkAdapter -ManagementOS -Name $mgmtVirtualAdapterName -ErrorAction SilentlyContinue
        } catch {}

        [System.String] $adapterWithValidIp = ""
        if ($mgmtVirtualAdapterExists.Count -gt 0) {
            Log-Info "Found virtual adapter with name $mgmtVirtualAdapterName. Will try to get DNS server information from it."
            $adapterWithValidIp = $mgmtVirtualAdapterName
        } else {
            Log-Info "No virtual adapter $mgmtVirtualAdapterName found. Will use physical adapter $mgmtPhysicalAdapterName to get DNS server information from it."
            $adapterWithValidIp = $mgmtPhysicalAdapterName
        }

        [System.String] $dnsOverlapStatus = "FAILURE"
        [System.Boolean] $dnsOverLapWithPODCidr = $false
        [PSObject[]] $mgmtAdapterDNSClientServerAddresses = Get-DnsClientServerAddress -InterfaceAlias $adapterWithValidIp -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($mgmtAdapterDNSClientServerAddresses -and ($mgmtAdapterDNSClientServerAddresses.Count -gt 0) -and ($mgmtAdapterDNSClientServerAddresses[0].ServerAddresses.Count -gt 0)) {
            foreach ($tmpDnsServerInfo in $mgmtAdapterDNSClientServerAddresses[0].ServerAddresses) {
                $dnsOverLapWithPODCidr = $dnsOverLapWithPODCidr -or (CheckIPInSubnet -IPAddress $tmpDnsServerInfo -CIDR $PODCidr)
                $dnsOverLapWithPODCidr = $dnsOverLapWithPODCidr -or (CheckIPInSubnet -IPAddress $tmpDnsServerInfo -CIDR $ServiceCidr)
            }
            $resultResourceInfo = $mgmtAdapterDNSClientServerAddresses[0].ServerAddresses -join ', '
        } else {
            Log-Info "No DNS server address found from adapter $adapterWithValidIp. Skip the DNS server overlap check."
            $resultResourceInfo = "NOT_FOUND"
        }

        if ($dnsOverLapWithPODCidr) {
            Log-Info "DNS server address overlaps with K8s Default POD CIDR $PODCidr and/or Service CIDR: $ServiceCidr"
        } else {
            Log-Info "DNS server address NOT overlaps with K8s Default POD CIDR $PODCidr or Service CIDR: $ServiceCidr"
            $dnsOverlapStatus = 'SUCCESS'
        }

        $dnsServerOverlapParams = @{
            Name               = "AzureLocal_Network_Test_AKS_Subnet_POD_SERVICE_CIDR_DNSServer_Overlap"
            Title              = "Test for DNS server overlaps with POD CIDR Subnet $PODCidr and Service CIDR Subnet $ServiceCidr"
            DisplayName        = "Test for DNS server overlaps with POD CIDR Subnet $PODCidr and Service CIDR Subnet $ServiceCidr"
            Severity           = "INFORMATIONAL"
            Description        = "Checking DNS server address(es) not within the POD CIDR Subnet $PODCidr and Service CIDR Subnet $ServiceCidr"
            Tags               = @{}
            Remediation        = "Verify DNS servers configured are not overlapping with AKS pre-defined POD subnet and Service subnet. Check https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-hci-ip-address-planning for more information."
            TargetResourceID   = "DNSServer-$($resultResourceInfo)"
            TargetResourceName = "DNSServer-$($resultResourceInfo)"
            TargetResourceType = "DNSServer-$($resultResourceInfo)"
            Timestamp          = [datetime]::UtcNow
            Status             = $dnsOverlapStatus
            AdditionalData     = @{
                Source    = 'DNSServerPODServiceCIDR'
                Resource  = 'DNSServerPODServiceCIDR'
                Detail    = "DNS server address(es): $($resultResourceInfo). POD CIDR: $PODCidr; Service CIDR: $ServiceCidr"
                Status    = $dnsOverlapStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $instanceResults += New-AzStackHciResultObject @dnsServerOverlapParams
        #endregion

        #region Check Proxy Server overlaps with POD CIDR and Service CIDR
        Log-Info "Test for proxy server overlaps with POD CIDR range $PODCidr and $ServiceCidr"
        Log-Info "Trying to get system proxy configuration..."
        $proxyConfigs = @()
        $proxyConfigs += EnvValidatorNwkLibGetWinProxyConfiguration -ProxyType "WinHttp"
        $proxyConfigs += EnvValidatorNwkLibGetWinProxyConfiguration -ProxyType "WinInet"

        $envVariableHttpProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY","MACHINE")
        $envVariableHttpsProxy = [Environment]::GetEnvironmentVariable("HTTPS_PROXY","MACHINE")
        $proxyConfigs += @{
                HttpProxy       = $envVariableHttpProxy
                HttpsProxy      = $envVariableHttpsProxy
                ProxyIsEnabled  = -Not ([System.String]::IsNullOrEmpty($envVariableHttpProxy) -and [System.String]::IsNullOrEmpty($envVariableHttpsProxy))
        }

        Log-Info "Got proxy configuration: $($proxyConfigs | ConvertTo-Json)"

        # $proxyConfigs contains information like below:
        # HttpProxy  : http://proxyserver:8080
        # HttpsProxy : http://proxyserver:8080
        # ProxyIsEnabled : True
        # Need to retrieve the "proxyserver" part from the HttpProxy and HttpsProxy values
        [System.Boolean] $needProxyOverlapResult = $false
        [string[]]$proxyServerList = @()
        foreach ($config in $proxyConfigs) {
            Log-Info "Checking proxy config $($config | ConvertTo-Json)"

            if ($config.ProxyIsEnabled) {
                $needProxyOverlapResult = $true
                if (-not [string]::IsNullOrEmpty($config.HttpProxy)) {
                    try {
                        $uri = [System.Uri]$config.HttpProxy
                        $proxyServerList += $uri.Host
                    } catch {}
                }
                if (-not [string]::IsNullOrEmpty($config.HttpsProxy)) {
                    try {
                        $uri = [System.Uri]$config.HttpsProxy
                        $proxyServerList += $uri.Host
                    } catch {}
                }
            }
        }

        # Make sure no duplicate proxy server in the list
        $proxyServerList = $proxyServerList | Select-Object -Unique
        $proxyServerListString = $proxyServerList -join ', '
        Log-Info "Proxy server list to check: $($proxyServerListString)"

        if ($needProxyOverlapResult) {
            Log-Info "Proxy configuration enabled in the system. Will check proxy server(s) overlap with POD CIDR and Service CIDR."
            [System.Boolean] $proxyServerOverlap = $false
            foreach ($proxyServer in $proxyServerList) {
                # Resolve to IP if possible, or check if it is an IP
                try {
                    $ipAddresses = [System.Net.Dns]::GetHostAddresses($proxyServer)
                    Log-Info "Resolved proxy host $proxyServer to IP addresses: $($ipAddresses.IPAddressToString -join ', ')"
                    foreach ($ipAddress in $ipAddresses) {
                        $ipString = $ipAddress.IPAddressToString
                        Log-Info "Checking proxy server IP address: $ipString"
                        $proxyServerOverlap = $proxyServerOverlap -or (CheckIPInSubnet -IPAddress $ipString -CIDR $PODCidr)
                        $proxyServerOverlap = $proxyServerOverlap -or (CheckIPInSubnet -IPAddress $ipString -CIDR $ServiceCidr)
                    }
                } catch {
                    # DNS resolution failed or invalid IP, skip
                    Log-Info "Could not resolve proxy host: $proxyServer"
                }
            }

            $proxyOverlapStatus = "FAILURE"
            if ($proxyServerOverlap) {
                Log-Info "Proxy Server overlaps with K8s Default POD CIDR: $PODCidr or Service CIDR: $ServiceCidr. Be aware that this many result in suboptimal network conditions."
            } else {
                $proxyOverlapStatus = 'SUCCESS'
            }

            $proxyServerOverlapParams = @{
                Name               = "AzureLocal_Network_Test_AKS_Subnet_POD_CIDR_ProxyServer_Overlap"
                Title              = "Test for Proxy server overlaps with POD CIDR Subnet $PODCidr and Service CIDR Subnet $ServiceCidr"
                DisplayName        = "Test for Proxy server overlaps with POD CIDR Subnet $PODCidr and Service CIDR Subnet $ServiceCidr"
                Severity           = "INFORMATIONAL"
                Description        = "Checking Proxy server address(es) not within the POD CIDR Subnet $PODCidr and Service CIDR Subnet $ServiceCidr"
                Tags               = @{}
                Remediation        = "Verify IP of the proxy server(s) configured are not overlapping with AKS pre-defined POD subnet and Service subnet. Check https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-hci-ip-address-planning for more information."
                TargetResourceID   = "ProxyServer-$($proxyServerListString)"
                TargetResourceName = "ProxyServer-$($proxyServerListString)"
                TargetResourceType = "ProxyServer-$($proxyServerListString)"
                Timestamp          = [datetime]::UtcNow
                Status             = $proxyOverlapStatus
                AdditionalData     = @{
                    Source    = 'ProxyServerPODServiceCIDR'
                    Resource  = 'ProxyServerPODServiceCIDR'
                    Detail    = "Proxy server address(es): $($proxyServerListString). POD CIDR: $PODCidr; Service CIDR: $ServiceCidr"
                    Status    = $proxyOverlapStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $instanceResults += New-AzStackHciResultObject @proxyServerOverlapParams
        }
        #endregion

        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_HostNetworkConfigurationReadiness
{
    [CmdletBinding()]
    param
    (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,

        [PSObject[]] $AtcHostIntents,
        [System.String] $OperationType,
        [ValidateSet('Small','Medium','Large')]
        [System.String] $HardwareClass = "Medium"
    )

    try
    {
        Log-Info "Start running Test-NwkValidator_HostNetworkConfigurationReadiness"

        if (($PSSession.Count -eq 0) -or ($AtcHostIntents.Count -eq 0))
        {
            Log-Info "No PSSession or AtcHostIntents provided. Skip run of Test-NwkValidator_HostNetworkConfigurationReadiness"
            return
        }
        else
        {
            Log-Info "Will check host network adapter RDMA status, adapter symmetry and bandwidth, and other host network"
            Log-Info "configuration (include DNS client configuration, Hyper-V is running correctly, VMSwitch (if exists)"
            Log-Info "has mgmt intent adapters, VlanId for adapters, physical adapter used in JSON."
        }

        [System.Management.Automation.Runspaces.PSSession[]] $allPSSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        switch ($HardwareClass)
        {
            "Small"  { $expectedAdapterMinBandWidth = 1000000000 } # 1Gbps
            "Medium" { $expectedAdapterMinBandWidth = 10000000000 } # 10Gbps
            "Large"  { $expectedAdapterMinBandWidth = 10000000000 } # 10Gbps
            Default  { $expectedAdapterMinBandWidth = 10000000000 } # 10Gbps
        }

        # Check host network readiness status
        $hostNetworkReadinessTestResults = @()

        #region Check RDMA status
        if ($OperationType -eq "Deployment") {
            Log-Info "Checking NetAdapter RDMA status on all nodes in parallel"
            $allRdmaResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock ${function:CheckNetAdapterRDMAStatus} -ArgumentList @(, $AtcHostIntents))

            foreach ($rdmaResult in $allRdmaResults) {
                if ($null -ne $rdmaResult)
                {
                    $nodeName = $rdmaResult.PSComputerName
                    Log-Info "Got RDMA validation results from $nodeName"
                    $currentMachineRdmaStatus = if ($rdmaResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
                    $currentMachineRdmaTestDetailMessage = $rdmaResult.Message
                    Log-Info "    Result: $($currentMachineRdmaTestDetailMessage)"
                }
                else
                {
                    $nodeName = 'Unknown'
                    Log-Info "NO RDMA validation results found from $nodeName"
                    $currentMachineRdmaStatus = 'FAILURE'
                    $currentMachineRdmaTestDetailMessage = "NO RDMA validation results returned by function CheckNetAdapterRDMAStatus from server $nodeName"
                }

                $rdmaRstObject = @{
                    Name               = 'AzStackHci_Network_Test_NetAdapter_RDMA_Operational'
                    Title              = 'Test NetAdapter RDMA requirement'
                    DisplayName        = "Test if RDMA requirement meets for the deployment on all servers"
                    Severity           = 'CRITICAL'
                    Description        = 'Checking RDMA Operational Status on {0}' -f $nodeName
                    Tags               = @{}
                    Remediation        = 'Make sure adapter RDMA is operational. Use Get-NetAdapterRdma cmdlet to check the status of RDMA for the network adapter in the system.'
                    TargetResourceID   = $nodeName
                    TargetResourceName = "NetAdapter"
                    TargetResourceType = 'Network Adapter RDMA'
                    Timestamp          = [datetime]::UtcNow
                    Status             = $currentMachineRdmaStatus
                    AdditionalData     = @{
                        Source    = $nodeName
                        Resource  = 'Network Adapter RDMA Operational Status'
                        Detail    = $currentMachineRdmaTestDetailMessage
                        Status    = $currentMachineRdmaStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $hostNetworkReadinessTestResults += New-AzStackHciResultObject @rdmaRstObject
            }
        }
        #endregion

        #region Check adapter symmetry and bandwidth requirement
        Log-Info "Checking NetAdapter symmetry bandwidth requirement on all nodes in parallel"
        $allSymmetryResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock ${function:CheckAdapterSymmetryAndBandwidth} -ArgumentList $AtcHostIntents, $expectedAdapterMinBandWidth)

        foreach ($adapterSymmetryAndBandwidthResult in $allSymmetryResults) {
            $nodeName = $adapterSymmetryAndBandwidthResult.PSComputerName
            if ($null -ne $adapterSymmetryAndBandwidthResult)
            {
                Log-Info "Got adapter symmetry and bandwidth validation results from $nodeName"
                $currentMachineAdapterSymmetryBandwidthStatus = if ($adapterSymmetryAndBandwidthResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
                $currentMachineAdapterSymmetryBandwidthTestDetailMessage = $adapterSymmetryAndBandwidthResult.Message
            }
            else
            {
                Log-Info "NO adapter symmetry and bandwidth validation results found from $nodeName"
                $currentMachineAdapterSymmetryBandwidthStatus = 'FAILURE'
                $currentMachineAdapterSymmetryBandwidthTestDetailMessage = "NO adapter symmetry and bandwidth validation results returned by function CheckAdapterSymmetryAndBandwidth from server $nodeName"
            }

            $adapterSymmetryRstObject = @{
                Name               = 'AzStackHci_Network_Test_NetAdapter_Symmetry_Bandwidth'
                Title              = 'Test NetAdapter symmetry and bandwidth requirement'
                DisplayName        = "Test if network adapters used in one intent is symmetry and if bandwidth meets minimum requirement"
                Severity           = 'CRITICAL'
                Description        = 'Checking network adapters and bandwidth Status on {0}' -f $nodeName
                Tags               = @{}
                Remediation        = 'Make sure adapters used in intent are symmetry and minimum bandwidth to use for RDMA is 10G. Use Get-NetAdapter cmdlet on the system to check the adapter information.'
                TargetResourceID   = $nodeName
                TargetResourceName = "NetAdapter"
                TargetResourceType = 'Network Adapter Symmetry and Bandwidth'
                Timestamp          = [datetime]::UtcNow
                Status             = $currentMachineAdapterSymmetryBandwidthStatus
                AdditionalData     = @{
                    Source    = $nodeName
                    Resource  = 'Network Adapter Symmetry and Bandwidth'
                    Detail    = $currentMachineAdapterSymmetryBandwidthTestDetailMessage
                    Status    = $currentMachineAdapterSymmetryBandwidthStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $hostNetworkReadinessTestResults += New-AzStackHciResultObject @adapterSymmetryRstObject
        }
        #endregion

        #region Check cross-node adapter link speed consistency per intent
        Log-Info "Checking NetAdapter cross-node link speed consistency for each intent"

        # Scriptblock to gather adapter speed info on each node; parameterized by $AdapterNames
        $getIntentAdapterSpeedInfo = {
            [CmdletBinding()]
            param (
                [String[]] $AdapterNames
            )

            $adaptersInfo = [PSCustomObject]@{
                Node = $env:COMPUTERNAME
                Adapters = @()
            }

            foreach ($adapterName in $AdapterNames)
            {
                $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue

                if ($null -eq $adapter) {
                    $adapterObj = @{
                        Name          = $adapterName
                        LinkSpeed     = "Adapter Not Found"
                        Speed         = -1
                        FormattedName = "$($env:COMPUTERNAME)/$adapterName"
                    }
                } else {
                    $adapterObj = @{
                        Name          = $adapter.Name
                        LinkSpeed     = $adapter.LinkSpeed
                        Speed         = $adapter.Speed
                        FormattedName = "$($env:COMPUTERNAME)/$($adapter.Name)"
                    }
                }

                $adaptersInfo.Adapters += $adapterObj
            }

            return $adaptersInfo
        }

        foreach ($intentToCheck in $AtcHostIntents)
        {
            [System.String] $intentName = $intentToCheck.Name
            [System.String[]] $intentAdapterNames = $intentToCheck.Adapter

            Log-Info "Getting adapter speed information for intent [$intentName] from all nodes in parallel"
            $intentAdapterSpeedInfo = @(Invoke-Command -Session $allPSSessions -ScriptBlock $getIntentAdapterSpeedInfo -ArgumentList @(, $intentAdapterNames))
            foreach ($hostAdapterSpeedInfo in $intentAdapterSpeedInfo) {
                Log-Info "Adapter speed information from $($hostAdapterSpeedInfo.Node): $($hostAdapterSpeedInfo | ConvertTo-Json -Depth 5)"
            }

            $crossNodeSpeedMessage = "[FAIL] Unable to retrieve adapter speed configuration."
            $crossNodeSpeedStatus = "FAILURE"
            $allSpeedAdapters = $intentAdapterSpeedInfo | Select-Object -ExpandProperty Adapters
            Log-Info "All Adapter speeds for [$intentName]: $($allSpeedAdapters | ConvertTo-Json -Depth 5)"

            # Separate missing adapters from found adapters before consistency comparison
            $missingAdapters = @($allSpeedAdapters | Where-Object { $_.Speed -eq -1 })
            $foundAdapters = @($allSpeedAdapters | Where-Object { $_.Speed -ne -1 })

            if ($missingAdapters.Count -gt 0) {
                $missingList = ($missingAdapters | ForEach-Object { $_.FormattedName }) -join ', '
                Log-Info "Adapters not found for intent [$intentName]: $missingList"
                $crossNodeSpeedMessage = "[FAIL] " + ($lnTxt.CrossNodeLinkSpeedAdapterNotFound -f $intentName, $missingList)
                $crossNodeSpeedStatus = "FAILURE"
            }
            elseif ($foundAdapters.Count -eq 0) {
                $crossNodeSpeedMessage = "[FAIL] " + ($lnTxt.CrossNodeLinkSpeedNoData -f $intentName)
                $crossNodeSpeedStatus = "FAILURE"
            }
            else {
                # Group found adapters by their link speed
                $speedGroups = @{}
                foreach ($adapter in $foundAdapters) {
                    $linkSpeed = $adapter.LinkSpeed
                    if (-not $speedGroups.ContainsKey($linkSpeed)) {
                        $speedGroups[$linkSpeed] = @{
                            LinkSpeed    = $linkSpeed
                            AdapterNames = [System.Collections.ArrayList]::new()
                        }
                    }

                    [void]$speedGroups[$linkSpeed]['AdapterNames'].Add($adapter.FormattedName)
                }

                Log-Info "Adapter speed grouping for intent [$intentName]: $($speedGroups | ConvertTo-Json -Depth 5)"
                if ($speedGroups.Count -eq 1) {
                    $linkSpeed = $speedGroups.Values[0].LinkSpeed
                    $adapterList = $speedGroups[$linkSpeed].AdapterNames -join ', '
                    $crossNodeSpeedMessage = "[PASS] " + ($lnTxt.CrossNodeLinkSpeedPass -f $intentName, $linkSpeed, $adapterList)
                    $crossNodeSpeedStatus = "SUCCESS"
                }
                elseif ($speedGroups.Count -gt 1) {
                    $failParts = foreach ($speedGroup in ($speedGroups.Values | Sort-Object LinkSpeed)) {
                        $adapterList = $speedGroup.AdapterNames -join ', '
                        "[$($speedGroup.LinkSpeed)] ($adapterList)"
                    }
                    $crossNodeSpeedMessage = "[FAIL] " + ($lnTxt.CrossNodeLinkSpeedFail -f $intentName, ($failParts -join ', '))
                }
            }

            $nodeNames = ($intentAdapterSpeedInfo | ForEach-Object { $_.Node }) -join ', '
            $crossNodeSpeedRstObject = @{
                Name               = 'AzStackHci_Network_Test_NetAdapter_CrossNode_LinkSpeed_Consistency'
                Title              = 'Test NetAdapter cross-node link speed consistency'
                DisplayName        = "Test if network adapters in the same intent have consistent link speeds across all nodes"
                Severity           = 'INFORMATIONAL'
                Description        = 'Checking that adapters in intent {0} have the same link speed on all nodes' -f $intentName
                Tags               = @{}
                Remediation        = 'Ensure all nodes use network adapters with the same link speed for each intent. Use Get-NetAdapter on each node to verify adapter speeds.'
                TargetResourceID   = "$intentName Intent"
                TargetResourceName = "$intentName Intent"
                TargetResourceType = 'Network Adapter Cross-Node Link Speed'
                Timestamp          = [datetime]::UtcNow
                Status             = $crossNodeSpeedStatus
                AdditionalData     = @{
                    Source    = $nodeNames
                    Resource  = "$intentName Intent"
                    Detail    = $crossNodeSpeedMessage
                    Status    = $crossNodeSpeedStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $hostNetworkReadinessTestResults += New-AzStackHciResultObject @crossNodeSpeedRstObject
        }
        #endregion

        #region Host network configuration readiness
        Log-Info "Checking host network readiness configuration on all nodes in parallel"
        $allNetworkReadinessResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock ${function:CheckHostNetworkConfigurationReadiness} -ArgumentList @(, $AtcHostIntents))

        foreach ($networkReadinessResult in $allNetworkReadinessResults) {
            $nodeName = $networkReadinessResult.PSComputerName
            if ($null -ne $networkReadinessResult)
            {
                Log-Info "Network readiness check results from $nodeName"
                $currentMachineNetworkReadinessStatus = if ($networkReadinessResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
                $currentMachineNetworkReadinessTestDetailMessage = $networkReadinessResult.Message
            }
            else
            {
                Log-Info "NO host network configuration readiness validation results found from $nodeName"
                $currentMachineNetworkReadinessStatus = 'FAILURE'
                $currentMachineNetworkReadinessTestDetailMessage = "NO host network configuration readiness validation results returned by function CheckHostNetworkConfigurationReadiness from $nodeName"
            }

            $networkReadinessRstObject = @{
                Name               = 'AzStackHci_Network_Test_HostNetworkConfigurationReadiness'
                Title              = 'Test host network configuration readiness'
                DisplayName        = "Test if host network requirement meets for the deployment on all servers"
                Severity           = 'CRITICAL'
                Description        = 'Checking host network configuration readiness status on {0}' -f $nodeName
                Tags               = @{}
                Remediation        = 'Make sure host network configuration readiness is correct. Review detail message to find out the issue.'
                TargetResourceID   = $nodeName
                TargetResourceName = "HostNetworkReadiness"
                TargetResourceType = 'HostNetworkReadiness'
                Timestamp          = [datetime]::UtcNow
                Status             = $currentMachineNetworkReadinessStatus
                AdditionalData     = @{
                    Source    = $nodeName
                    Resource  = 'HostNetworkReadiness configuration status'
                    Detail    = $currentMachineNetworkReadinessTestDetailMessage
                    Status    = $currentMachineNetworkReadinessStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $hostNetworkReadinessTestResults += New-AzStackHciResultObject @networkReadinessRstObject
        }
        #endregion

        #region Host intent configuration readiness
        Log-Info "Checking if intent configuration is able to be applied on all nodes in parallel"
        $allIntentConfigResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock ${function:CheckIntentConfigurationReadiness} -ArgumentList @($AtcHostIntents, $OperationType))

        $intentConfigurationRemediationMsg = "Please double check your adapters advanced property."
        $intentConfigurationRemediationMsg += "`n    Get adapter name: Get-NetAdapter | ft Name"
        $intentConfigurationRemediationMsg += "`n    Get-NetAdapterAdvancedProperty -Name <ADAPTER_NAME> -RegistryKeyword <Property To Check>"
        $intentConfigurationRemediationMsg += "`n               <Adapter Name>: Name of the adapter, got from the above Get-NetAdapter call"
        $intentConfigurationRemediationMsg += "`n               <Property To Check>: what property to check. We are validating below properties:"
        $intentConfigurationRemediationMsg += "`n                               *NetworkDirectTechnology: check `"ValidDisplayValues`" in it to see if a specific NetworkDirect technology is supported by the adapter"
        $intentConfigurationRemediationMsg += "`n                                                         Valid value should be the combination of the following: iWARP, RoCE, RoCEv2"
        $intentConfigurationRemediationMsg += "`n    Sample: Check what NetworkDirect technology is supported by adapter `"Ethernet`""
        $intentConfigurationRemediationMsg += "`n           (Get-NetAdapterAdvancedProperty -Name `"Ethernet`" -RegistryKeyword `"*NetworkDirectTechnology`").ValidDisplayValues"

        foreach ($intentConfigurationReadinessResult in $allIntentConfigResults) {
            $nodeName = $intentConfigurationReadinessResult.PSComputerName
            if ($null -ne $intentConfigurationReadinessResult)
            {
                Log-Info "Got intent configuration readiness validation results from $nodeName"
                $intentConfigurationReadinessValidationStatus = if ($intentConfigurationReadinessResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
                $intentConfigurationReadinessValidationDetailMessage = $intentConfigurationReadinessResult.Message
                Log-Info "    Result: $($intentConfigurationReadinessValidationDetailMessage)"
            }
            else
            {
                Log-Info "NO intent configuration readiness validation results found from $nodeName"
                $intentConfigurationReadinessValidationStatus = 'FAILURE'
                $intentConfigurationReadinessValidationDetailMessage = "NO intent configuration readiness validation results returned by function CheckIntentConfigurationReadiness from server $nodeName"
            }

            $intentConfigurationReadinessRstObject = @{
                Name               = 'AzStackHci_Network_Test_HostIntentConfigurationReadiness'
                Title              = 'Test host intent configuration readiness'
                DisplayName        = 'Test if intent configuration is ready to be configured on all servers'
                Severity           = 'CRITICAL'
                Description        = 'Test network intent configuration could be possible applied on host {0}' -f $nodeName
                Tags               = @{}
                Remediation        = $intentConfigurationRemediationMsg
                TargetResourceID   = $nodeName
                TargetResourceName = "IntentConfigurationReadiness"
                TargetResourceType = "IntentConfigurationReadiness"
                Timestamp          = [datetime]::UtcNow
                Status             = $intentConfigurationReadinessValidationStatus
                AdditionalData     = @{
                    Source    = $nodeName
                    Resource  = 'IntentConfigurationReadiness'
                    Detail    = $intentConfigurationReadinessValidationDetailMessage
                    Status    = $intentConfigurationReadinessValidationStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $hostNetworkReadinessTestResults += New-AzStackHciResultObject @intentConfigurationReadinessRstObject
        }
        #endregion

        return $hostNetworkReadinessTestResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_AdapterDriverMgmtAdapterReadiness
{
    [CmdletBinding()]
    param
    (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        [PSObject[]] $AtcHostIntents,
        [System.Boolean] $DhcpEnabled,
        [System.String] $OperationType
    )

    try
    {
        [System.Management.Automation.Runspaces.PSSession[]] $allPSSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $ErrorActionPreference = "Stop"

        $inboxDriverMgmtIPTestResults = @()

        $checkInboxDriverScript = {
            [CmdletBinding()]
            param (
                [String[]] $AdapterNames
            )

            $retVal = New-Object PSObject -Property @{
                Pass = $true
                Adapters = @()
            }
            $hardwareType = (Get-WmiObject -Class Win32_ComputerSystem).Model

            foreach ($adapterName in $AdapterNames) {
                $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
                $adapterResult = @{
                    Name = $adapterName
                    DriverProvider = "Not Found"
                    Pass = $false
                }

                if ($null -eq $adapter) {
                    $retVal.Pass = $false
                } else {
                    $adapterResult.DriverProvider = $adapter.DriverProvider
                    if ($adapter.DriverProvider -match "Microsoft" -or $adapter.DriverProvider -match "Windows") {
                        if ($hardwareType -ne "Virtual Machine") {
                            $retVal.Pass = $false
                            $adapterResult.Pass = $false
                        } else {
                            $adapterResult.Pass = $true
                        }
                    } else {
                        $adapterResult.Pass = $true
                    }
                }

                $retVal.Adapters += $adapterResult
            }

            return $retVal
        }

        $checkMgmtAdapterScript = {
            [CmdletBinding()]
            param (
                [String[]] $MgmtAdapterNames,
                [String] $MgmtIntentName,
                [System.Boolean] $DhcpEnabled,
                [System.String] $OperationType

            )

            $ErrorActionPreference = "Stop"

            $infoNumber = 1
            $retVal = New-Object PSObject -Property @{
                Pass = $true
                Message = ""
                FirstManagementAdapter = $null
            }

            $mgmtVNicName = "vManagement($($MgmtIntentName))"

            [PSObject[]] $allExistingVMSwitches = @()
            try
            {
                $allExistingVMSwitches = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue
            }
            catch
            {
            }

            [System.Boolean] $expectedVMSwitchReadyInSystem = $false

            if ($allExistingVMSwitches.Count -gt 0)
            {
                $vmSwitchMessage = ""
                # VMSwitch should contains 0 or all of the mgmt adapters
                # if VMSwitch contains all mgmt adapters, then there should be 1 vNIC named as "vManagement(ManagementIntentName)""
                foreach ($externalVMSwitch in $allExistingVMSwitches)
                {
                    # Need to check the switch is good for deployment: using same adapter as the intent
                    [System.Guid[]] $switchAdapterGuids = $externalVMSwitch.NetAdapterInterfaceGuid
                    [System.Guid[]] $intentAdapterGuids = (Get-NetAdapter -Name $MgmtAdapterNames -Physical -ErrorAction SilentlyContinue).InterfaceGuid

                    if ($intentAdapterGuids.Count -eq 0) {
                        $intentAdapterGuids = @()
                    }

                    if (Compare-Object -ReferenceObject $switchAdapterGuids -DifferenceObject $intentAdapterGuids)
                    {
                        # Adapters used in pre-defined VMSwitch and the intent are different. Need to make sure 0 mgmt adapter used by VMSwitch
                        foreach ($mgmtAdapter in $intentAdapterGuids)
                        {
                            if ($switchAdapterGuids -contains $mgmtAdapter)
                            {
                                $retVal.Pass = $false
                                $vmSwitchMessage += "VMSwitch [$($externalVMSwitch.Name)] uses physical adapter [$mgmtAdapter] defined in the management intent, but it does not use all physical adapters defined in the management intent."
                            }
                        }

                        if ($retVal.Pass -eq $true)
                        {
                            $vmSwitchMessage += "VMSwitch [$($externalVMSwitch.Name)] does not use any physical adapters defined in the management intent, "
                        }
                    }
                    else
                    {
                        $vmSwitchMessage += "Found VMSwitch [$($externalVMSwitch.Name)] that uses all physical adapters defined in the management intent."

                        $expectedVMSwitchReadyInSystem = $true

                        # VMSwitch uses same set of adapters defined in mgmt intent, will need to check there is a vNIC named as "vManagement(ManagementIntentName)"
                        [PSObject[]] $expectedVMNetworkAdapterMgmtNIC = Get-VMNetworkAdapter -ManagementOS -Name $mgmtVNicName -ErrorAction SilentlyContinue
                        if ($expectedVMNetworkAdapterMgmtNIC.Count -ne 1)
                        {
                            $retVal.Pass = $false
                            $vmSwitchMessage += " Expected 1 VMNetworkAdapter [$($mgmtVNicName)] but found $($expectedVMNetworkAdapterMgmtNIC.Count)."
                        }
                        else
                        {
                            $vmSwitchMessage += " Found 1 VMNetworkAdapter [$($mgmtVNicName)] configured."
                        }

                        [PSObject[]] $expectedNetAdapterMgmtNIC = Get-NetAdapter -Name $mgmtVNicName -ErrorAction SilentlyContinue
                        if ($expectedNetAdapterMgmtNIC.Count -ne 1)
                        {
                            $retVal.Pass = $false
                            $vmSwitchMessage += " Expected 1 NetAdapter [$($mgmtVNicName)] but found $($expectedNetAdapterMgmtNIC.Count)."
                        }
                        else
                        {
                            $vmSwitchMessage += " Found 1 NetAdapter [$($mgmtVNicName)] configured."
                        }
                    }
                }

                if ($retVal.Pass -eq $true) {
                    $vmSwitchMessage = "$infoNumber) [PASS] " + $vmSwitchMessage
                } else {
                    $vmSwitchMessage = "$infoNumber) [FAIL] " + $vmSwitchMessage
                }
                $infoNumber++
                $retVal.Message = $vmSwitchMessage.Trim() -replace ",$", "."
            }

            [String[]] $adaptersToCheck = @()
            $adapterIpMessage = ""

            if ($expectedVMSwitchReadyInSystem)
            {
                $adaptersToCheck = @($mgmtVNicName)
            }
            else
            {
                $adaptersToCheck = $MgmtAdapterNames
            }

            # Following checks only be performed on the 1st adapter in the list as other adapters might not have
            # valid IP address configured on it during the test:
            #       Deployment or Add-Server: Might only configured on the 1st adapter
            #       PreUpdate: Only need to check vManagement(<IntentName>)
            $firstMgmtAdapter = $adaptersToCheck[0]
            $retVal.FirstManagementAdapter = $firstMgmtAdapter

            # Adapter IP checking
            if ($DhcpEnabled)
            {
                $prefixOriginExpected = "Dhcp"
                $prefixOriginNotExpected = "Manual"
            }
            else
            {
                $prefixOriginExpected = "Manual"
                $prefixOriginNotExpected = "Dhcp"
            }

            # For all mgmt adapter, in deployment time
            #   if DHCP enabled, we should not have static IP address configured on it, otherwise, cluster creation will have problem
            #   Similar, if static IP scenario, we should not have DHCP IP address configured on it.
            # Note that we don't check this in other scenarios, like PreUpdate, because it is possible that the adapter have
            # different IP type on it.
            if ($OperationType -eq "Deployment") {
                $adapterValidIPs = $true
                foreach ($mgmtAdapter in $adaptersToCheck)
                {
                    $adapterIPs = Get-NetIPAddress -InterfaceAlias $mgmtAdapter -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                                 Where-Object { $_.AddressState -eq "Preferred" }

                    $invalidIPs = $adapterIPs | Where-Object { $_.PrefixOrigin -eq $prefixOriginNotExpected }
                    $validIPs = $adapterIPs | Where-Object { $_.PrefixOrigin -eq $prefixOriginExpected }

                    if ($invalidIPs) {
                        $adapterValidIPs = $false
                        $adapterIpMessage += " Adapter [$mgmtAdapter] has invalid IP(s): [$(($invalidIPs.IPAddress -join ', ').Trim())] with PrefixOrigin [$prefixOriginNotExpected],"
                    } elseif ($validIPs) {
                        $adapterIpMessage += " Adapter [$mgmtAdapter] has valid IP(s): [$(($validIPs.IPAddress -join ', ').Trim())] with PrefixOrigin [$prefixOriginExpected],"
                    } else {
                        $adapterIpMessage += " Adapter [$mgmtAdapter] does not have any IPs configured with expected PrefixOrigin [$prefixOriginExpected] or unexpected PrefixOrigin [$prefixOriginNotExpected],"
                    }
                }

                if ($adapterValidIPs -eq $false) {
                    $retVal.Message += " $infoNumber) [FAIL] " + $adapterIpMessage.Trim() -replace ",$", "."
                    $retVal.Pass = $false
                } else {
                    $retVal.Message += " $infoNumber) [PASS] " + $adapterIpMessage.Trim() -replace ",$", "."
                }
            } else {
                $retVal.Message += " $infoNumber) [SKIP] IP Prefix Origin is only checked during Deployment, this is $($OperationType)."
            }
            $infoNumber++

            # Adapter default gateway checking
            [PSObject[]] $currentAdapterNetIPConfiguration = @()

            try {
                $currentAdapterNetIPConfiguration = Get-NetIPConfiguration -InterfaceAlias $firstMgmtAdapter -ErrorAction SilentlyContinue
            } catch {
                # using a try/catch here to avoid exception when Get-NetIPConfiguration fails: even we use -ErrorAction SilentlyContinue, it
                # still throws error when the adapter is not found.
                $retVal.Pass = $false
            }

            if ($currentAdapterNetIPConfiguration.Count -gt 0)
            {
                [PSObject[]] $allDefaultGateway = $currentAdapterNetIPConfiguration[0].IPv4DefaultGateway

                if ($allDefaultGateway.Count -ne 1)
                {
                    $retVal.Pass = $false
                    $retVal.Message += " $infoNumber) [FAIL] First management adapter [$firstMgmtAdapter] has [$($allDefaultGateway.Count)] default gateway(s) configured, but expected [1]."
                }
                else
                {
                    $retVal.Message += " $infoNumber) [PASS] First management adapter [$firstMgmtAdapter] has [$($allDefaultGateway.Count)] default gateway configured."
                }
            }
            else
            {
                $retVal.Pass = $false
                $retVal.Message += " $infoNumber) [FAIL] First management adapter [$firstMgmtAdapter] does not have an IP Configuration, at least one IP Configuration is expected."
            }
            $infoNumber++

            # Adapter DNS server checking.
            [PSObject[]] $mgmtAdapterDNSClientServerAddresses = Get-DnsClientServerAddress -InterfaceAlias $firstMgmtAdapter -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($mgmtAdapterDNSClientServerAddresses -and ($mgmtAdapterDNSClientServerAddresses.Count -gt 0) -and ($mgmtAdapterDNSClientServerAddresses[0].ServerAddresses.Count -gt 0))
            {
                $retVal.Message += " $infoNumber) [PASS] First management adapter [$firstMgmtAdapter] has [1] DNS Client Server with IP Address [$($mgmtAdapterDNSClientServerAddresses.ServerAddresses -join ',')] configured."
            }
            else
            {
                $retVal.Pass = $false
                $retVal.Message += " $infoNumber) [FAIL] First management adapter [$firstMgmtAdapter] has [0] DNS Client Servers configured, but expected [1+]."
            }
            $infoNumber++

            [PSObject[]] $currentAdapterAddresses = Get-NetIPAddress -InterfaceAlias $firstMgmtAdapter -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue `
                                                        | Where-Object { ($_.PrefixOrigin -eq $prefixOriginExpected) -and ($_.AddressState -eq "Preferred") }

            if ($currentAdapterAddresses.Count -ge 2)
            {
                try
                {
                    $tmpClusterIp = (Get-ClusterResource -Name "Cluster IP Address" -ErrorAction Stop | Get-ClusterParameter -Name Address -ErrorAction Stop).Value
                }
                catch
                {
                    $tmpClusterIp = "Unknown"
                }

                $currentIPString = ($currentAdapterAddresses.IPAddress -join ", ").Trim()
                $retVal.Message += " $infoNumber) [WARN] First management adapter [$firstMgmtAdapter] has multiple IP addresses configured: [$currentIPString]. One IP should be the nodes primary IP address, the other IPs may be the Cluster IP Address ($tmpClusterIp) or may be used by another service."
                $infoNumber++
            }

            $retVal.Message = $retVal.Message.Trim()
            return $retVal
        }

        Log-Info "DHCP enabled environment? [ $($DhcpEnabled) ]"

        #region TEST1: Check inbox driver for all intent adapters in the host
        [System.String[]] $allIntentAdapters = $AtcHostIntents | Select-Object -ExpandProperty Adapter

        if ($allIntentAdapters.Count -gt 0)
        {
            Log-Info "Check intent adapter(s) inbox driver on all nodes in parallel"
            $allInboxDriverResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock $checkInboxDriverScript -ArgumentList @(, $allIntentAdapters))

            foreach ($tmpInboxDriverCheckRst in $allInboxDriverResults) {
                $nodeName = $tmpInboxDriverCheckRst.PSComputerName
                $detailMessage = ""
                $testStatus = "FAILURE"
                if ($null -ne $tmpInboxDriverCheckRst)
                {
                    Log-Info "Got inbox driver validation results from $nodeName"
                    Log-Info ($tmpInboxDriverCheckRst | ConvertTo-Json -Depth 5)
                    $testStatus = if ($tmpInboxDriverCheckRst.Pass) { 'SUCCESS' } else { 'FAILURE' }
                    $totalAdapters = $tmpInboxDriverCheckRst.Adapters.Count
                    $successAdapters = @($tmpInboxDriverCheckRst.Adapters | Where-Object { $_.Pass -eq $true }).Count
                    $detailMessage = "$nodeName ($successAdapters/$totalAdapters adapters passed): "
                    foreach ($adapter in $tmpInboxDriverCheckRst.Adapters) {
                        $detailMessage += "$($adapter.Name) [$($adapter.DriverProvider)], "
                    }
                    $detailMessage = $detailMessage.TrimEnd(", ")
                    $detailMessage += ". No adapters should use inbox (Microsoft or Windows) drivers."
                }
                else
                {
                    # Should not come here, just a safe guard
                    Log-Info "NO inbox driver validation results found from $nodeName"
                    $testStatus = 'FAILURE'
                    $detailMessage = "No Inbox Driver results were returned from $nodeName. This is unexpected."
                }

                # Build the detail message showing adapter driver status
                $inboxDriverCheckRstObject = @{
                    Name               = "AzureLocal_Network_Test_NetworkAdapter_InboxDriver"
                    Title              = "Validate that the Network Adapters are not using inbox drivers"
                    DisplayName        = "Validate that the Network Adapters are not using inbox drivers"
                    Severity           = "CRITICAL"
                    Description        = "The Network Adapters used by a Network Intent must not use inbox drivers, unless it is a virtual deployment. Inbox drivers will have the DriverProvider equal to Microsoft or Windows. Work with your hardware vendor to obtain the appropriate drivers."
                    Tags               = @{}
                    Remediation        = "https://aka.ms/azurelocal/envvalidator/InboxDrivers"
                    TargetResourceID   = "$nodeName, Network Adapters"
                    TargetResourceName = "$nodeName, Network Adapters"
                    TargetResourceType = "NetworkAdapter"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $testStatus
                    AdditionalData     = @{
                        Source    = "$nodeName, Network Adapters"
                        Resource  = "NetworkAdapter"
                        Detail    = $detailMessage
                        Status    = $testStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $inboxDriverMgmtIPTestResults += New-AzStackHciResultObject @inboxDriverCheckRstObject
            }
        }
        else
        {
            # Should not got here. But just keep it here for safe guard
            Log-Info "No adapter found in intent definition. Skip inbox driver check for intent adapter."
        }
        #endregion

        #region TEST2: Check no more than 1 IP address and DNS client server address on mgmt adapter, IP type is correct
        [PSObject[]] $mgmtIntent = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Management") }
        [System.String] $mgmtIntentName = $mgmtIntent[0].Name
        [System.String[]] $mgmtAdapters = GetSortedMgmtIntentAdapter -MgmtAdapterNames $mgmtIntent[0].Adapter

        Log-Info "Check on mgmt adapter readiness on all nodes in parallel"
        $allMgmtAdapterResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock $checkMgmtAdapterScript -ArgumentList @($mgmtAdapters, $mgmtIntentName, $DhcpEnabled, $OperationType))

        foreach ($tmpMgmtAdapterIPCheckRst in $allMgmtAdapterResults) {
            $nodeName = $tmpMgmtAdapterIPCheckRst.PSComputerName
            if ($null -ne $tmpMgmtAdapterIPCheckRst)
            {
                Log-Info "Got mgmt adapter IP validation results from $nodeName"
                $currentMachineMgmtIPTestStatus = if ($tmpMgmtAdapterIPCheckRst.Pass) { 'SUCCESS' } else { 'FAILURE' }
                $currentMachineMgmtIPTestDetailMessage = $tmpMgmtAdapterIPCheckRst.Message
                $target = "$nodeName"
            }
            else
            {
                # Should not come here, just a safe guard
                Log-Info "NO mgmt adapter IP validation results found from $nodeName"
                $currentMachineMgmtIPTestStatus = 'FAILURE'
                $currentMachineMgmtIPTestDetailMessage = "NO mgmt adapter IP validation results returned from server $nodeName"
                $target = "$nodeName"
            }

            $mgmtAdapterCheckRstObject = @{
                Name               = "AzureLocal_Network_Test_ManagementAdapterReadiness"
                Title              = "Validate that at least one Management Adapter has a valid IP Configuration, DNS Server, and Gateway"
                DisplayName        = "Validate that at least one Management Adapter has a valid IP Configuration, DNS Server, and Gateway"
                Severity           = "CRITICAL"
                Description        = "Each node must have a management adapter with a valid IP Configuration, DNS Server, and Gateway. If this is a DHCP deployment, the management adapter must have a DHCP address. If the adapter is teamed with a VMSwitch, that VMSwitch must have all adapters defined in the management intent and no others."
                Tags               = @{}
                Remediation        = "https://aka.ms/azurelocal/envvalidator/ManagementAdapterReadiness"
                TargetResourceName = $target
                TargetResourceID   = $target
                TargetResourceType = "ManagementAdapter"
                Timestamp          = [datetime]::UtcNow
                Status             = $currentMachineMgmtIPTestStatus
                AdditionalData     = @{
                    Source    = $target
                    Resource  = "ManagementAdapter"
                    Detail    = $currentMachineMgmtIPTestDetailMessage
                    Status    = $currentMachineMgmtIPTestStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $inboxDriverMgmtIPTestResults += New-AzStackHciResultObject @mgmtAdapterCheckRstObject
        }
        #endregion

        #region TEST3
        # Check all adapters used in same intent across all nodes are using same driver version
        foreach ($intentToCheck in $ATCHostIntents)
        {
            [System.String] $intentName = $intentToCheck.Name
            [System.String[]] $intentAdapterNames = $intentToCheck.Adapter

            # Get Adapter Information from all host nodes in parallel
            $getIntentAdapterInfo = {
                [CmdletBinding()]
                param (
                    [String[]] $AdapterNames
                )

                $adaptersInfo = [PSCustomObject]@{
                    Node = $env:COMPUTERNAME
                    Adapters = @()
                }

                foreach ($adapterName in $AdapterNames)
                {
                    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue

                    if ($null -eq $adapter) {
                        $adapterObj = @{
                            Name                 = $adapterName
                            DriverVersion        = "Adapter Not Found"
                            DriverProvider       = "Adapter Not Found"
                            DriverInformation    = "Adapter Not Found"
                            InterfaceDescription = "Adapter Not Found"
                            FormattedName        = "$($env:COMPUTERNAME)/$adapterName"
                            FormattedInfo        = "Adapter Not Found"
                        }
                    } else {
                        $adapterObj = @{
                            Name                 = $adapter.Name
                            DriverVersion        = $adapter.DriverVersion
                            DriverProvider       = $adapter.DriverProvider
                            DriverInformation    = $adapter.DriverInformation
                            InterfaceDescription = $adapter.InterfaceDescription
                            FormattedName        = "$($env:COMPUTERNAME)/$($adapter.Name)"
                            FormattedInfo        = "$($adapter.DriverProvider) | $($adapter.DriverInformation)"
                        }
                    }

                    $adaptersInfo.Adapters += $adapterObj
                }

                return $adaptersInfo
            }

            Log-Info "Getting adapter information for intent [$intentName] from all nodes in parallel"
            $intentAdaptersDriverInfo = @(Invoke-Command -Session $allPSSessions -ScriptBlock $getIntentAdapterInfo -ArgumentList @(, $intentAdapterNames))
            foreach ($hostAdapterInfo in $intentAdaptersDriverInfo) {
                Log-Info "Adapter information from $($hostAdapterInfo.Node): $($hostAdapterInfo | ConvertTo-Json -Depth 5)"
            }

            $message = "[FAIL] Unable to retrieve adapter driver configuration."
            $status = "FAILURE"
            $allAdapters = $intentAdaptersDriverInfo | Select-Object -ExpandProperty Adapters
            Log-Info "All Adapters for [$intentName]: $($allAdapters | ConvertTo-Json -Depth 5)"

            # Organize adapters by their driver information
            $driverGroups = @{}
            foreach ($adapter in $allAdapters) {
                $driverInfo = $adapter.DriverInformation
                if (-not $driverGroups.ContainsKey($driverInfo)) {
                    $driverGroups[$driverInfo] = @{
                        Driver = $driverInfo
                        AdapterNames = @()
                    }
                }

                $driverGroups[$driverInfo].AdapterNames += $adapter.FormattedName
            }

            Log-Info "Adapter driver grouping for intent [$intentName]: $($driverGroups | ConvertTo-Json -Depth 5)"
            if ($driverGroups.Count -eq 1) {
                $driver = $driverGroups.Values[0].Driver
                $adapterList = $driverGroups[$driver].AdapterNames -join ', '
                $message = "[PASS] $intentName Intent uses [$driver] on all adapters ($adapterList)."
                $status = "SUCCESS"
            }
            elseif ($driverGroups.Count -gt 1) {
                $failParts = foreach ($driverGroup in ($driverGroups.Values | Sort-Object Driver)) {
                    $adapterList = $driverGroup.AdapterNames -join ', '
                    "[$($driverGroup.Driver)] ($adapterList)"
                }
                $message = "[FAIL] $intentName Intent uses multiple driver versions: " + ($failParts -join ', ') + "."
            }

            $nodeNames = ($intentAdaptersDriverInfo | ForEach-Object { $_.Node }) -join ', '
            $adapterDriverVersionCheckRstObject = @{
                Name               = "AzureLocal_Network_Test_NetworkAdapter_DriverConsistency"
                Title              = "Validate that Network Intent Adapters use consistent driver versions across all nodes"
                DisplayName        = "Validate that Network Intent Adapters use consistent driver versions across all nodes"
                Severity           = "CRITICAL"
                Description        = "All Network Adapters assigned to a Network Intent must use consistent driver versions across all nodes. Adapters from the same manufacturer should have identical driver versions. All nodes in the cluster must maintain this consistency to ensure predictable networking behavior."
                Tags               = @{}
                Remediation        = "https://aka.ms/azurelocal/envvalidator/IntentAdapterDrivers"
                TargetResourceID   = "$intentName Intent"
                TargetResourceName = "$intentName Intent"
                TargetResourceType = 'Network Intent Adapters'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $nodeNames
                    Resource  = "$intentName Intent"
                    Detail    = $message
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $inboxDriverMgmtIPTestResults += New-AzStackHciResultObject @adapterDriverVersionCheckRstObject
        }

        #endregion
        return $inboxDriverMgmtIPTestResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_MgmtIpIpPoolRequirement
{
    <#
    .SYNOPSIS
        Run during both Deployment and AddNode
        1. Mgmt NIC IP should not be overlapping with IP Pool
        2. Ensure Mgmt NIC IPs and IP Pool are in the same subnet
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [Parameter(Mandatory = $false, HelpMessage = "Specify Management Subnet")]
        [string] $ManagementSubnetValue,

        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession
    )

    try
    {
        [System.Management.Automation.Runspaces.PSSession[]] $allPSSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession
        $ManagementSubnetValue = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet $ManagementSubnetValue

        $instanceResults = @()
        foreach ($ipPool in $IpPools)
        {
            $StartingAddress = $ipPool.StartingAddress
            $EndingAddress = $ipPool.EndingAddress

            $sb = {
                [System.Collections.Hashtable] $nodeIpPrefixLength = @{}

                [System.String[]] $validIPAddresses = (Get-NetIPConfiguration | Where-Object { (-Not [System.String]::IsNullOrEmpty($_.IPv4DefaultGateway)) -and $_.NetAdapter.Status -eq "Up" }).IPv4Address.IPAddress
                $validIPAddresses = $validIPAddresses | Select-Object -Unique
                foreach ($tmpIp in $validIPAddresses) {
                    [System.Byte] $tmpIpPrefixLength = (Get-NetIPAddress -IPAddress $tmpIp).PrefixLength
                    $nodeIpPrefixLength[$tmpIp] = $tmpIpPrefixLength
                }

                return [PSCustomObject]@{
                    NodeName       = $env:COMPUTERNAME
                    IpPrefixLength = $nodeIpPrefixLength
                }
            }

            # Invoke on all nodes in parallel for this IP pool
            Log-Info "Gathering management IP info from all nodes in parallel for IP pool $StartingAddress - $EndingAddress"
            $allNodeData = @(Invoke-Command -Session $allPSSessions -ScriptBlock $sb)

            foreach ($nodeData in $allNodeData) {
                $NodeName = $nodeData.NodeName
                # Check for all of the IPs found on the Host
                foreach ($tmpKey in $nodeData.IpPrefixLength.Keys) {
                    Log-Info "Node [$NodeName] has IP Address: $tmpKey with Prefix Length: $($nodeData.IpPrefixLength[$tmpKey])"
                    $nodeManagementIPAddress = $tmpKey
                    $nodeManagementIPPrefixLength = $nodeData.IpPrefixLength[$tmpKey]

                    Log-Info "Node Name retrieved from session: $NodeName"
                    Log-Info "Node Management IP Address retrieved from session: $nodeManagementIPAddress"

                    #region Check node management IP is not in infra pool range
                    [System.String] $mgmtIpOverlapStatus = ""

                    Log-Info "Start testing Mgmt IP on $NodeName is not in Infra IP Pool..."

                    $ip = [system.net.ipaddress]::Parse($nodeManagementIPAddress).GetAddressBytes()
                    [array]::Reverse($ip)
                    $ip = [system.BitConverter]::ToUInt32($ip, 0)

                    $from = [system.net.ipaddress]::Parse($StartingAddress).GetAddressBytes()
                    [array]::Reverse($from)
                    $from = [system.BitConverter]::ToUInt32($from, 0)

                    $to = [system.net.ipaddress]::Parse($EndingAddress).GetAddressBytes()
                    [array]::Reverse($to)
                    $to = [system.BitConverter]::ToUInt32($to, 0)

                    $mgmtIPOutsideRange = ($ip -le $from) -or ($ip -ge $to)
                    if ($mgmtIPOutsideRange) {
                        $TestMgmtIPInfraRangeDetail = $lnTxt.TestMgmtIPInfraRangePass -f $nodeManagementIPAddress, $StartingAddress, $EndingAddress
                    }
                    else {
                        $TestMgmtIPInfraRangeDetail = $lnTxt.TestMgmtIPInfraRangeFail -f $nodeManagementIPAddress, $StartingAddress, $EndingAddress
                        Log-Info $TestMgmtIPInfraRangeDetail -Type Warning
                    }
                    $mgmtIpOverlapStatus = if ($mgmtIPOutsideRange) { 'SUCCESS' } else { 'FAILURE' }

                    $params = @{
                        Name               = 'AzStackHci_Network_Test_Validity_MgmtIp_NotIn_Infra_Pool'
                        Title              = 'Test Validity Management IP not in Infra Pool'
                        DisplayName        = "Test Validity Management IP not in Infra Pool"
                        Severity           = 'CRITICAL'
                        Description        = 'Checking management IPs are not in infra IP pool'
                        Tags               = @{}
                        Remediation        = 'https://aka.ms/hci-envch'
                        TargetResourceID   = "$StartingAddress-$EndingAddress"
                        TargetResourceName = "ManagementIpIpPoolConfiguration"
                        TargetResourceType = 'ManagementIpIpPoolConfiguration'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $mgmtIpOverlapStatus
                        AdditionalData     = @{
                            Source    = $NodeName
                            Resource  = 'NodeManagementIP'
                            Detail    = $TestMgmtIPInfraRangeDetail
                            Status    = $mgmtIpOverlapStatus
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                    #endregion

                    #region Check node management IP is within the same subnet as the IP pools
                    [System.String] $mgmtSubnetOverlapStatus = ""

                    Log-Info "Start testing Mgmt IP on $NodeName is within the same subnet as that of Infra IP Pool..."
                    $mgmtIpCIDR = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$($nodeManagementIPAddress)/$($nodeManagementIPPrefixLength)"
                    $TestMgmtSubnet = $mgmtIpCIDR -ieq $ManagementSubnetValue
                    $mgmtSubnetOverlapStatus = if ($TestMgmtSubnet) { 'SUCCESS' } else { 'FAILURE' }

                    $params = @{
                        Name               = 'AzStackHci_Network_Test_Validity_MgmtIp_In_Infra_Subnet'
                        Title              = 'Test Validity Management IP in same infra subnet as IP pools'
                        DisplayName        = "Test Validity Management IP in same infra subnet as IP pools"
                        Severity           = 'CRITICAL'
                        Description        = 'Checking management IPs are in same subnet as infra IP pool'
                        Tags               = @{}
                        Remediation        = 'https://aka.ms/hci-envch'
                        TargetResourceID   = "$($mgmtIpCIDR)-$($ManagementSubnetValue)"
                        TargetResourceName = "ManagementIpIpPoolCIDR"
                        TargetResourceType = 'ManagementIpIpPoolCIDR'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $mgmtSubnetOverlapStatus
                        AdditionalData     = @{
                            Source    = $NodeName
                            Resource  = 'ManagementIpIpPoolCIDR'
                            Detail    = if ($TestMgmtSubnet) { $lnTxt.TestMgmtSubnetPass -f $nodeManagementIPAddress, $EndingAddress } else { $lnTxt.TestMgmtSubnetFail -f $nodeManagementIPAddress, $EndingAddress }
                            Status    = $mgmtSubnetOverlapStatus
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                    #endregion
                }
            }
        }
        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

# Initial tests to determine if Mgmt IP of new Node is OK
# Below Tests are for Static IP Allocation (Non-DHCP)
function Test-NwkValidator_MgmtIPForNewNode
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [Hashtable]
        $NodeToManagementIPMap,

        [PSObject[]] $AtcHostIntents
    )
    try
    {
        [System.Management.Automation.Runspaces.PSSession[]] $allPSSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $instanceResults = @()

        $newNodeSession = $allPSSessions[0]

        [PSObject[]] $mgmtIntent = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Management") }
        $intentName = $mgmtIntent[0].Name
        $firstAdapterName = $mgmtIntent[0].Adapter[0]

        $sb = {
            $env:COMPUTERNAME
            (
                Get-NetIPConfiguration |
                Where-Object {
                    $null -ne $_.IPv4DefaultGateway -and
                    $_.NetAdapter.Status -eq "Up"
                }
            ).IPv4Address.IPAddress
        }
        $NewNodeData = Invoke-Command $newNodeSession -ScriptBlock $sb
        $NodeName = $NewNodeData[0]
        $NodeManagementIPAddress = $NewNodeData[1]

        Log-Info "Node Name retrieved from PSSession: $NodeName"
        Log-Info "Node Management IP Address retrieved from PSSession: $NodeManagementIPAddress"

        foreach ($ipPool in $IpPools)
        {
            $StartingAddress = $ipPool.StartingAddress
            $EndingAddress = $ipPool.EndingAddress


            # Check node management IP is not in infra pool range
            Log-Info "Starting Test Mgmt IP is not in Infra IP Pool for $($newNodeSession.ComputerName)"
            $ip = [system.net.ipaddress]::Parse($NodeManagementIPAddress).GetAddressBytes()
            [array]::Reverse($ip)
            $ip = [system.BitConverter]::ToUInt32($ip, 0)

            $from = [system.net.ipaddress]::Parse($StartingAddress).GetAddressBytes()
            [array]::Reverse($from)
            $from = [system.BitConverter]::ToUInt32($from, 0)

            $to = [system.net.ipaddress]::Parse($EndingAddress).GetAddressBytes()
            [array]::Reverse($to)
            $to = [system.BitConverter]::ToUInt32($to, 0)


            $mgmtIPOutsideRange = ($ip -le $from) -or ($ip -ge $to)
            if ($mgmtIPOutsideRange) {
                $TestMgmtIPInfraRangeDetail = $lnTxt.TestMgmtIPInfraRangePass -f $NodeManagementIPAddress, $StartingAddress, $EndingAddress
                $status = 'SUCCESS'
            }
            else {
                $TestMgmtIPInfraRangeDetail = $lnTxt.TestMgmtIPInfraRangeFail -f $NodeManagementIPAddress, $StartingAddress, $EndingAddress
                Log-Info $TestMgmtIPInfraRangeDetail -Type Warning
                $status = 'FAILURE'
            }
            $params = @{
                Name               = 'AzStackHci_Network_Test_New_Node_Validity_Outside_Mgmt_Range'
                Title              = 'Test New Node Configuration Outside Management Range'
                DisplayName        = "Test New Node Configuration Outside Management Range"
                Severity           = 'CRITICAL'
                Description        = 'Checking New Node IP'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = $NodeManagementIPAddress
                TargetResourceName = "IPAddress"
                TargetResourceType = 'IPAddress'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $NodeName
                    Resource  = 'NewNodeManagementIP'
                    Detail    = $TestMgmtIPInfraRangeDetail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        # Check that no management IPs are the same (Mgmt IP shouldn't conflict with existing node)
        Log-Info "Starting Test for No Mgmt IPs are the same for any Nodes"
        $duplicateIPs = $false
        $numDuplicates = $NodeToManagementIPMap.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }
        if ($null -ne $numDuplicates) {
            $duplicateIPs = $true
            Log-Info 'Duplicate IPs found for Node Management IPs' -Type Warning
        }

        if ($duplicateIPs) {
            $dtl = 'Duplicate IPs found for Node Management IPs'
            $status = 'FAILURE'
        }
        else {
            $dtl = 'No Duplicate IPs found for Node Management IPs'
            $status = 'SUCCESS'
        }

        $params = @{
            Name               = 'AzStackHci_Network_Test_New_Node_Validity_Duplicate_IP'
            Title              = 'Test New Node Configuration Duplicate IP'
            DisplayName        = "Test New Node Configuration Duplicate IP"
            Severity           = 'CRITICAL'
            Description        = 'Checking New Node IP is not a duplicate'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = $NodeManagementIPAddress
            TargetResourceName = "IPAddress"
            TargetResourceType = 'IPAddress'
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = 'NodeAndManagementIPMapping'
                Resource  = 'NodeManagementIPs'
                Detail    = $dtl
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        # Check that host name exists, and the name and mgmt IP both match current node
        Log-Info "Starting Test to check if Mgmt IP is on a different node as $NodeName"
        Log-Info "Starting simultaneous Test to check if HostName and Mgmt IP Match for $NodeName"
        $ipOnAnotherNode = $false
        $NodeNameAndIPMatches = $false
        $nodeNameForIP = $null
        foreach ($NodeIP in $NodeToManagementIPMap.GetEnumerator()) {
            Write-Host "$($NodeIP.Name): $($NodeIP.Value)"
            if ($NodeIP.Name -eq $NodeName) {
                if ($NodeIP.Value -eq $NodeManagementIPAddress) {
                    $NodeNameAndIPMatches = $true
                    $nodeNameForIP = $NodeIP.Name
                }
            } else {
                if ($NodeIP.Value -eq $NodeManagementIPAddress) {
                    $ipOnAnotherNode = $true
                    $nodeNameForIP = $NodeIP.Name
                }
            }
        }

        if ($ipOnAnotherNode) {
            $CheckMgmtIPNotOnOtherNodeDetail = $lnTxt.CheckMgmtIPNotOnOtherNodeFail -f $NodeManagementIPAddress, $nodeNameForIP
            Log-Info $CheckMgmtIPNotOnOtherNodeDetail -Type Warning
        }
        else {
            $CheckMgmtIPNotOnOtherNodeDetail = $lnTxt.CheckMgmtIPNotOnOtherNodePass -f $NodeManagementIPAddress, $nodeNameForIP
        }
        $status = if ($ipOnAnotherNode) { 'FAILURE' } else { 'SUCCESS' }
        $params = @{
            Name               = 'AzStackHci_Network_Test_New_Node_Validity_IP_Conflict'
            Title              = 'Test New Node Configuration Conflicting IP'
            DisplayName        = "Test New Node Configuration Conflicting IP"
            Severity           = 'CRITICAL'
            Description        = 'Checking New Node IP is not on another node'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = $NodeManagementIPAddress
            TargetResourceName = "IPAddress"
            TargetResourceType = 'IPAddress'
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = 'NodeAndManagementIPMapping'
                Resource  = 'NodeNameAndManagementIP'
                Detail    = $CheckMgmtIPNotOnOtherNodeDetail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        if ($NodeNameAndIPMatches) {
            $CheckMgmtIPOnNewNodeDetail = $lnTxt.CheckMgmtIPOnNewNodePass -f $NodeManagementIPAddress, $nodeNameForIP
            $status = 'SUCCESS'
        }
        else {
            $CheckMgmtIPOnNewNodeDetail = $lnTxt.CheckMgmtIPOnNewNodeFail -f $NodeManagementIPAddress, $nodeNameForIP
            Log-Info $CheckMgmtIPOnNewNodeDetail -Type Warning
            $status = 'FAILURE'
        }

        $params = @{
            Name               = 'AzStackHci_Network_Test_New_Node_And_IP_Match'
            Title              = 'Test New Node Configuration Name and IP Match'
            DisplayName        = "Test New Node Configuration Name and IP Match"
            Severity           = 'CRITICAL'
            Description        = 'Checking New Node Name and IP match'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = $NodeManagementIPAddress
            TargetResourceName = "IPAddress"
            TargetResourceType = 'IPAddress'
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = 'NodeAndManagementIPMapping'
                Resource  = 'NewNodeNameAndManagementIP'
                Detail    = $CheckMgmtIPOnNewNodeDetail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        # Check that New Node has the first physical adapter and the physical adapter has the mgmt IP
        Log-Info "Starting Test to see if $firstAdapterName on $NodeName has the correct Mgmt IP"
        $adapterSB = {
            param($adapterName)
            $returnDict = @{}
            $returnDict["GetNetIPAddressOutput"] = Get-NetIPAddress -ErrorAction SilentlyContinue
            $returnDict["GetNetAdapterOutput"] = Get-NetAdapter
            $AdapterIPObject = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($null -eq $AdapterIPObject) {
                $returnDict["Result"] = $false
                $returnDict["AdapterName"] = $adapterName
                return $returnDict
            }
            $returnDict["Result"] = $true
            $returnDict["AdapterName"] = $adapterName
            $returnDict["AdapterIP"] = $AdapterIPObject.IPAddress
            return $returnDict
        }

        $AdapterContainsMgmtIP = $false
        $physicalAdapterExists = $false
        $VirtualNICName = "vManagement($intentName)"
        try {
            $NewNodeAdapterData = Invoke-Command $newNodeSession -ScriptBlock $adapterSB -ArgumentList $firstAdapterName
            Log-Info "Data found for New Node Adapter ($firstAdapterName): $($NewNodeAdapterData | Out-String)"
            if ($NewNodeAdapterData['Result'] -eq $false) {
                Log-Info "Physical Adapter Not Found"
                Log-Info "Get-NetIPAddress output: $($NewNodeAdapterData['GetNetIPAddressOutput'] | Out-String)"
                Log-Info "Get-NetAdapter output: $($NewNodeAdapterData['GetNetAdapterOutput'] | Out-String)"
            }
            elseif ($NewNodeAdapterData['Result'] -eq $true -and $NewNodeAdapterData['AdapterIP'] -eq $NodeManagementIPAddress) {
                Log-Info "Physical Adapter found with Correct IP: $($NewNodeAdapterData['AdapterIP'] | Out-String)"
                $physicalAdapterExists = $true
                $AdapterContainsMgmtIP = $true
                $CheckAdapterContainsIPDetail = $lnTxt.CheckAdapterContainsIPPass -f $firstAdapterName, $NodeManagementIPAddress
            }
            else {
                Log-Info "Physical Adapter found but with incorrect IP"
                Log-Info "Get-NetIPAddress output: $($NewNodeAdapterData['GetNetIPAddressOutput'] | Out-String)"
                Log-Info "Get-NetAdapter output: $($NewNodeAdapterData['GetNetAdapterOutput'] | Out-String)"
            }

            # In certain cases, new node will be set up with the vNIC instead and need to check that for mgmt IP
            if (!$physicalAdapterExists) {
                Log-Info "Physical Adapter does not exist or mgmt IP is wrong. Checking Virtual Adapter" -Type Warning
                $NewNodeVirtualAdapterData = Invoke-Command $newNodeSession -ScriptBlock $adapterSB -ArgumentList $VirtualNICName
                Log-Info "Data found for New Node Virtual Adapter ($VirtualNICName): $($NewNodeVirtualAdapterData | Out-String)"
                if ($NewNodeVirtualAdapterData['Result'] -eq $false) {
                    Log-Info "Virtual Adapter Not Found"
                    Log-Info "Get-NetIPAddress output: $($NewNodeVirtualAdapterData['GetNetIPAddressOutput'] | Out-String)"
                    Log-Info "Get-NetAdapter output: $($NewNodeVirtualAdapterData['GetNetAdapterOutput'] | Out-String)"
                }
                elseif ($NewNodeVirtualAdapterData['Result'] -eq $true -and $NewNodeVirtualAdapterData['AdapterIP'] -eq $NodeManagementIPAddress) {
                    Log-Info "Virtual Adapter found with Correct IP: $($NewNodeVirtualAdapterData['AdapterIP'] | Out-String)"
                    $AdapterContainsMgmtIP = $true
                    $CheckAdapterContainsIPDetail = $lnTxt.CheckAdapterContainsIPPass -f $VirtualNICName, $NodeManagementIPAddress
                }
                else {
                    Log-Info "Virtual Adapter found but with incorrect IP"
                    Log-Info "Get-NetIPAddress output: $($NewNodeVirtualAdapterData['GetNetIPAddressOutput'] | Out-String)"
                    Log-Info "Get-NetAdapter output: $($NewNodeVirtualAdapterData['GetNetAdapterOutput'] | Out-String)"
                }
            }
        }
        catch {
            Log-Info "Exception thrown when checking New Node Adapter: $_" -Type Warning
        }

        if (!$AdapterContainsMgmtIP) {
            $CheckAdapterContainsIPDetail = $lnTxt.CheckAdapterContainsIPFail -f $firstAdapterName, $VirtualNICName, $NodeManagementIPAddress
            Log-Info $CheckAdapterContainsIPDetail -Type Warning
            $status = 'FAILURE'
        }
        else
        {
            $status = 'SUCCESS'
        }

        $params = @{
            Name               = 'AzStackHci_Network_Test_New_Node_First_Adapter_Validity'
            Title              = 'Test New Node Configuration First Network Adapter has Management IP'
            DisplayName        = "Test New Node Configuration First Network Adapter has Management IP"
            Severity           = 'CRITICAL'
            Description        = 'Checking New Node first adapter has management IP'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-checklist'
            TargetResourceID   = $NodeManagementIPAddress
            TargetResourceName = $firstAdapterName
            TargetResourceType = 'Network Adapter'
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = 'NewNodeAdapter'
                Resource  = 'NewNodeAdapterIP'
                Detail    = $CheckAdapterContainsIPDetail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params
        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_ClusterNetworkIntentStatus
{
    <#
    .SYNOPSIS
        This test is run in the AddNode/PreUpdate context only.
        This test validates if the intents configured on the existing cluster are in good state.

    .DESCRIPTION
        This test performs the following Validations:
        1) Check the ATC Intent status on existing nodes are successfully allocated
    #>

    try
    {
        $instanceResults = @()

        #region Test there is only 1 management intent on the cluster
        [System.String] $mgmtIntentRstStatus = ""
        [PSObject[]] $mgmtIntent = @()
        [PSObject[]] $mgmtIntent = Get-NetIntent | Where-Object { $_.IsManagementIntentSet -eq $true }
        if ($mgmtIntent.Count -eq 1)
        {
            $mgmtIntentRstStatus = "SUCCESS"
            $mgmtIntentRstDetail = "Found one management intent $($mgmtIntent.IntentName) on the cluster."
        }
        else
        {
            $mgmtIntentRstStatus = "FAILURE"
            $mgmtIntentRstDetail = "There are [ $($mgmtIntent.Count) ] management intent(s) on the cluster. Expecting [ 1 ]. Please check the cluster network intent configuration."
        }

        $tmpMgmtIntentRemediationMsg = "To check cluster network intent information, run below cmdlet on your cluster:"
        $tmpMgmtIntentRemediationMsg += "`n    Get-NetIntent"
        $tmpMgmtIntentRemediationMsg += "`n Make sure one and only one intent is management intent: IsManagementIntentSet == `"True`""

        $mgmtIntentExists = @{
            Name               = 'AzStackHci_Network_Test_Network_Cluster_MgmtIntent_Exists'
            Title              = 'Test one management intent exists on cluster'
            DisplayName        = 'Test one management intent exists on cluster'
            Severity           = 'CRITICAL'
            Description        = 'Checking if there is one and only one management intent on existing cluster'
            Tags               = @{}
            Remediation        = $tmpMgmtIntentRemediationMsg
            TargetResourceID   = 'NetworkIntent'
            TargetResourceName = 'NetworkIntent'
            TargetResourceType = 'NetworkIntent'
            Timestamp          = [datetime]::UtcNow
            Status             = $mgmtIntentRstStatus
            AdditionalData     = @{
                Source    = 'ClusterMgmtIntent'
                Resource  = 'ClusterMgmtIntent'
                Detail    = $mgmtIntentRstDetail
                Status    = $mgmtIntentRstStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $instanceResults += New-AzStackHciResultObject @mgmtIntentExists
        #endregion

        #region Test intent status on the system
        # Get the names of all nodes with an Up Status
        $activeNodes = (Get-ClusterNode | Where-Object {$_.State -eq "Up"}).Name
        Log-Info "Checking ATC Intent status on existing all active nodes: $($activeNodes -join ', ')"

        # Get all intents on the active nodes and try to check the status
        # Note that if we find any intent is in "Validating" state, it might due to ATC is doing drift detection and we will need to wait for it to complete.
        # As drift detection interval is 15 minutes, we wait for up to 14 minutes (840 seconds) for the intent(s) to get out of "Validating" state.
        [PSObject[]] $intentsStatus = Get-NetIntentStatus | Where-Object {$activeNodes -contains $_.Host}
        $intentValidatingStopWatch = [System.diagnostics.stopwatch]::StartNew()
        while (($intentsStatus.ConfigurationStatus -match "Provisioning|ProvisioningUpdate|Retrying|Validating|Pending") -and ($intentValidatingStopWatch.Elapsed.TotalSeconds -lt 840)) {
            # We found at least one intent is not in "Success" or "Failed" state, we will wait for 10 seconds and re-check the intent status again.
            Log-Info "Found intent(s) NOT in Success/Failed state:"
            foreach ($tmpIntentStatus in $intentsStatus) {
                Log-Info "    Intent: $($tmpIntentStatus.IntentName) on host $($tmpIntentStatus.Host): ConfigurationStatus: $($tmpIntentStatus.ConfigurationStatus), ProvisioningStatus: $($tmpIntentStatus.ProvisioningStatus) "
            }

            Log-Info "Will wait for 10 seconds and re-check the intent status again."
            Start-Sleep -Seconds 10

            $intentsStatus = Get-NetIntentStatus | Where-Object {$activeNodes -contains $_.Host}
        }

        Log-Info "Found intent(s) with ConfigurationStatus Success/Failed:"
        foreach ($tmpIntentStatus in $intentsStatus) {
            Log-Info "    Intent: $($tmpIntentStatus.IntentName) on host $($tmpIntentStatus.Host): ConfigurationStatus: $($tmpIntentStatus.ConfigurationStatus), ProvisioningStatus: $($tmpIntentStatus.ProvisioningStatus) "
        }

        $tmpRemediationMsg = "To check cluster network intent status, run below cmdlet on your cluster:"
        $tmpRemediationMsg += "`n    Get-NetIntentStatus"
        $tmpRemediationMsg += "`n  ConfigurationStatus should be `"Success`""
        $tmpRemediationMsg += "`n  ProvisioningStatus  should be `"Completed`":"

        # Checks the intent status on the existing nodes.
        foreach ($intent in $intentsStatus)
        {
            $intentHealthy = $true
            if ($intent.ConfigurationStatus -ne "Success" -or $intent.ProvisioningStatus -ne "Completed")
            {
                $intentHealthy = $false
                $TestNetworkIntentStatusDetail = $lnTxt.TestNetworkIntentStatusFail -f $intent.IntentName, $intent.Host, $intent.ConfigurationStatus, $intent.ProvisioningStatus
                Log-Info $TestNetworkIntentStatusDetail -Type Warning
            }
            else
            {
                $intentHealthy = $true
                $TestNetworkIntentStatusDetail = $lnTxt.TestNetworkIntentStatusPass -f $intent.IntentName, $intent.Host, $intent.ConfigurationStatus, $intent.ProvisioningStatus
                Log-Info $TestNetworkIntentStatusDetail -Type Success
            }

            $params = @{
                Name               = 'AzStackHci_Network_Test_Network_Cluster_Intent_Status'
                Title              = 'Test Network intent on existing cluster nodes'
                DisplayName        = 'Test Network intent on existing cluster nodes'
                Severity           = 'CRITICAL'
                Description        = 'Checking if network intent is healthy on existing nodes'
                Tags               = @{}
                Remediation        = $tmpRemediationMsg
                TargetResourceID   = 'NetworkIntent'
                TargetResourceName = 'NetworkIntent'
                TargetResourceType = 'NetworkIntent'
                Timestamp          = [datetime]::UtcNow
                Status             = if ($intentHealthy) { 'SUCCESS' } else { 'FAILURE' }
                AdditionalData     = @{
                    Source    = $intent.Host
                    Resource  = $intent.IntentName
                    Detail    = $TestNetworkIntentStatusDetail
                    Status    = if ($intentHealthy) { 'SUCCESS' } else { 'FAILURE' }
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        #endregion

        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_StorageIntentExistence
{
    <#
    .SYNOPSIS
        This test is run in the AddNode context only.
        This test validates if there is a storage intent configured on the cluster

    .DESCRIPTION
        This test performs the following Validation:
        1) Check if the existing cluster have storage intent configured in them. If not, fail the test.
        We require the storage intent for 2+ node cluster, thus user must make sure storage intent is there
    #>

    try
    {
        $instanceResults = @()

        # Get the names of all nodes with an Up Status
        $activeNodes = (Get-ClusterNode | Where-Object {$_.State -eq "Up"}).Name
        Log-Info "Active nodes: $($activeNodes | Out-String)"

        # Get all intents on the active nodes
        $intents = Get-NetIntentStatus | Where-Object {$activeNodes -contains $_.Host}
        Log-Info "Checking if the storage intent is configured on the existing cluster before add node."

        $tmpRemediationMsg = "Storage intent is required for 2+ nodes Azure Local cluster."
        $tmpRemediationMsg += "`nPlease run below PowerShell cmdlet to add storage intent into the cluster:"
        $tmpRemediationMsg += "`n    Add-NetIntent"
        $tmpRemediationMsg += "`nCheck https://learn.microsoft.com/en-us/azure/azure-local/ for more information!"

        $storageIntent = $intents | Where-Object {$_.IsStorageIntentSet -eq $true}

        try {
            $source = Get-Cluster
        }
        catch {
            $source = $Env:COMPUTERNAME
            Log-Info "Error getting the cluster, we could be running this test in standalone mode on $($source)"
        }

        if ($null -eq $storageIntent)
        {
            $TestNetworkIntentStatusDetail = $lnTxt.TestStorageIntentNotConfigured -f $source
            Log-Info $TestNetworkIntentStatusDetail -Type Warning
        }
        else
        {
            $TestNetworkIntentStatusDetail = $lnTxt.TestStorageIntentConfigured -f $source
            Log-Info $TestNetworkIntentStatusDetail -Type Success
        }

        $params = @{
            Name               = 'AzStackHci_Network_Test_Network_Cluster_StorageIntentExistence'
            Title              = 'Test Storage intent existence'
            DisplayName        = 'Test Storage intent should exists on current cluster'
            Severity           = 'CRITICAL'
            Description        = 'Check if the storage intent is configured on the existing cluster'
            Tags               = @{}
            Remediation        = $tmpRemediationMsg
            TargetResourceID   = 'StorageIntent'
            TargetResourceName = 'StorageIntent'
            TargetResourceType = 'StorageIntent'
            Timestamp          = [datetime]::UtcNow
            Status             = if ($null -eq $storageIntent) { 'FAILURE' } else { 'SUCCESS' }
            AdditionalData     = @{
                Source    = $source
                Resource  = 'AddNodeStorageIntentCheck'
                Detail    = $TestNetworkIntentStatusDetail
                Status    = if ($null -eq $storageIntent) { 'FAILURE' } else { 'SUCCESS' }
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params

        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_NetworkATCFeatureStatusOnNewNode
{
    <#
    .SYNOPSIS
        This test is run in the AddNode context only.
        This test validates if the NetworkATC services in good state on the new nodes to be added.

    .DESCRIPTION
        This test performs the following Validations:
        1) Check if NetworkATC service is running on the new node

    .PARAMETERS
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession
    )

    try
    {
        [System.Management.Automation.Runspaces.PSSession[]] $allPSSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $sessionToCheck = $allPSSessions[0]
        Log-Info "Checking NetworkATC feature/service status on the new nodes."
        $instanceResults = @()

        # Check if NetworkATC service is running on the new node
        $sb = {
            $retVal = New-Object PSObject -Property @{
                Pass = $true
                Status = [string]::Empty
            }

            $atcFeature = Get-WindowsFeature -Name NetworkATC

            if ($atcFeature.InstallState -eq "Installed")
            {
                $atcService = Get-Service NetworkATC -ErrorAction SilentlyContinue
                $retVal.Status = "Feature Installed Service $($atcService.Status)"
            }
            elseif ($atcFeature.InstallState -eq "Available")
            {
                $retVal.Status = "Feature Available"
            }
            else
            {
                $retVal.Pass = $false
            }

            return $retVal
        }

        $NetworkATCStatus = Invoke-Command $sessionToCheck -ScriptBlock $sb
        $ATCStatusHealthy = $true
        if (!$NetworkATCStatus.Pass)
        {
            # NetworkATC feature not Installed, not Available on the system
            $ATCStatusHealthy = $false
            $TestNetworkATCServiceDetail = $lnTxt.TestNetworkATCFeatureNotInSystem -f $sessionToCheck.ComputerName
            Log-Info $TestNetworkATCServiceDetail -Type Warning
        }
        elseif (-not (($NetworkATCStatus.Status -eq 'Feature Installed Service Running') -or ($NetworkATCStatus.Status -eq 'Feature Available')))
        {
            # NetworkATC feature installed but service not 'Running', or feature not available
            $ATCStatusHealthy = $false
            $TestNetworkATCServiceDetail = $lnTxt.TestNetworkATCFeatureServiceStatus -f $NetworkATCStatus.Status, $sessionToCheck.ComputerName
            Log-Info $TestNetworkATCServiceDetail -Type Warning
        }
        else
        {
            $ATCStatusHealthy = $true
            $TestNetworkATCServiceDetail = $lnTxt.TestNetworkATCFeatureServiceStatus -f $NetworkATCStatus.Status, $sessionToCheck.ComputerName
            Log-Info $TestNetworkATCServiceDetail -Type Success
        }

        $params = @{
            Name               = 'AzStackHci_Network_Test_Network_AddNode_NetworkATC_Service'
            Title              = 'Test NetworkATC service is running on new node'
            DisplayName        = 'Test NetworkATC service is running on new node'
            Severity           = 'CRITICAL'
            Description        = 'Check NetworkATC service is running on new node'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-checklist'
            TargetResourceID   = 'NetworkATCService'
            TargetResourceName = 'NetworkATCService'
            TargetResourceType = 'NetworkATCService'
            Timestamp          = [datetime]::UtcNow
            Status             = if ($ATCStatusHealthy) { 'SUCCESS' } else { 'FAILURE' }
            AdditionalData     = @{
                Source    = $sessionToCheck.ComputerName
                Resource  = 'AddNodeNewNodeNetworkATCServiceCheck'
                Detail    = $TestNetworkATCServiceDetail
                Status    = if ($ATCStatusHealthy) { 'SUCCESS' } else { 'FAILURE' }
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params
        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_NetworkIntentRequirement
{
    <#
    .SYNOPSIS
        This test is run in the Deployment context only.
        This test validates that at least one storage-only intent must be defined for Rack Aware Cluster.

    .DESCRIPTION
        This test performs the following Validations:
        1) For a Rack Aware cluster, at least one storage-only intent is present.

    .PARAMETER ClusterPattern
        The pattern of the cluster. It can be 'Standard', 'Stretch', or 'RackAware'.

    .PARAMETER AtcHostIntents
        The ATC host intents to be applied during deployment.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String] $ClusterPattern,
        [Parameter(Mandatory = $true)]
        [PSObject[]] $AtcHostIntents
    )

    try
    {
        $networkIntentRequirementResults = @()
        # For the AtcHostIntents object array, we only need to check the storage only intents
        [PSObject[]] $storageIntents = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Storage") -and (-not $_.TrafficType.contains("Management")) -and (-not $_.TrafficType.contains("Compute")) }

        $networkIntentRequirementRstObject = @{
            Name               = 'AzStackHci_Network_Test_NetworkIntentRequirement'
            Title              = 'Test host network intent requirements for Rack Aware cluster'
            DisplayName        = 'Test host network intent requirements for Rack Aware cluster'
            Severity           = 'CRITICAL'
            Description        = 'Test that only one storage-only intent is present for Rack Aware cluster'
            Tags               = @{}
            Remediation        = ""
            TargetResourceID   = "NetworkIntentRequirement"
            TargetResourceName = "NetworkIntentRequirement"
            TargetResourceType = "NetworkIntentRequirement"
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source    = $Env:COMPUTERNAME
                Resource  = 'NetworkIntentRequirement'
                Detail    = 'Only one storage-only intent is present for Rack Aware cluster as expected.'
                Status    = 'SUCCESS'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        if ('RackAware' -eq $ClusterPattern)
        {
            if (($null -eq $storageIntents) -or ($storageIntents.Count -eq 0))
            {
                Log-Info 'No storage-only intent is present for Rack Aware cluster. Test is failed.' -Type Warning
                $networkIntentRequirementRstObject.Status = 'FAILURE'
                $networkIntentRequirementRstObject.AdditionalData.Detail = 'No storage-only intent is present for Rack Aware cluster.'
                $networkIntentRequirementRstObject.AdditionalData.Status = 'FAILURE'
            }
            elseif ($storageIntents.Count -gt 1) {
                Log-Info 'More than 1 storage-only intents are present for Rack Aware cluster. Test is failed.' -Type Warning
                $networkIntentRequirementRstObject.Status = 'FAILURE'
                $networkIntentRequirementRstObject.AdditionalData.Detail = 'More than 1 storage-only intents are present for Rack Aware cluster.'
                $networkIntentRequirementRstObject.AdditionalData.Status = 'FAILURE'
            }
            else
            {
                Log-Info "Only one storage-only intent is present for Rack Aware cluster as expected. Test is passed."
            }
        }
        else
        {
            Log-Info "Cluster pattern is not RackAware, so skip the storage intent requirement check."
            $networkIntentRequirementRstObject = @{
                Name               = 'AzStackHci_Network_Test_NetworkIntentRequirement'
                Title              = 'Test host network intent requirements for Rack Aware cluster'
                DisplayName        = 'Test host network intent requirements for Rack Aware cluster'
                Severity           = 'INFORMATIONAL'
                Description        = 'Test that only one storage-only intent is present for Rack Aware cluster'
                Tags               = @{}
                Remediation        = ""
                TargetResourceID   = "NetworkIntentRequirement"
                TargetResourceName = "NetworkIntentRequirement"
                TargetResourceType = "NetworkIntentRequirement"
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = $Env:COMPUTERNAME
                    Resource  = 'NetworkIntentRequirement'
                    Detail    = 'This is not a RackAware cluster, so skip the storage intent requirement check.'
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
        }

        $networkIntentRequirementResults += New-AzStackHciResultObject @networkIntentRequirementRstObject

        return $networkIntentRequirementResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_StorageConnectivityType
{
    <#
    .SYNOPSIS
        This test is run in the Deployment context only.
        This test validates that switched storage connectivity is used for Rack Aware Cluster.

    .DESCRIPTION
        This test performs the following Validations:
        1) For a Rack Aware cluster, the storage must be switched instead of switchless .

    .PARAMETER ClusterPattern
        The pattern of the cluster. It can be 'Standard', 'Stretch', or 'RackAware'.

    .PARAMETER SwitchlessDeploy
        Whether switchless configuration is used for storage connectivity .
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String] $ClusterPattern,
        [Parameter(Mandatory = $false)]
        [System.Boolean] $SwitchlessDeploy = $false
    )

        $storageConnectivityTypeResults = @()

        $storageConnectivityTypeRstObject = @{
            Name               = 'AzStackHci_Network_Test_StorageConnectivityType'
            Title              = 'Test storage connectivity type for Rack Aware cluster'
            DisplayName        = 'Test storage connectivity type for Rack Aware cluster'
            Severity           = 'CRITICAL'
            Description        = 'Test that switchless storage connectivity is NOT used for Rack Aware cluster.'
            Tags               = @{}
            Remediation        = ""
            TargetResourceID   = "StorageConnectivityType"
            TargetResourceName = "StorageConnectivityType"
            TargetResourceType = "StorageConnectivityType"
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source    = $Env:COMPUTERNAME
                Resource  = 'StorageConnectivityType'
                Detail    = 'Switchless storage connectivity is NOT used for Rack Aware cluster.'
                Status    = 'SUCCESS'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        if ('RackAware' -eq $ClusterPattern)
        {
            if ($SwitchlessDeploy)
            {
                Log-Info 'Switchless storage connectivity is used for Rack Aware cluster. Test is failed.' -Type Warning
                $storageConnectivityTypeRstObject.Status = 'FAILURE'
                $storageConnectivityTypeRstObject.AdditionalData.Detail = 'Switchless storage connectivity is used for Rack Aware cluster.'
                $storageConnectivityTypeRstObject.AdditionalData.Status = 'FAILURE'
            }
            else
            {
                Log-Info "Switchless storage connectivity is NOT used for Rack Aware cluster as expected. Test is passed."
            }
        }
        else
        {
            Log-Info "Cluster pattern is not RackAware, so skip the storage connectivity type check."
            $storageConnectivityTypeRstObject = @{
                Name               = 'AzStackHci_Network_Test_StorageConnectivityType'
                Title              = 'Test storage connectivity type for Rack Aware cluster'
                DisplayName        = 'Test storage connectivity type for Rack Aware cluster'
                Severity           = 'INFORMATIONAL'
                Description        = 'Test that switchless storage connectivity is NOT used for Rack Aware cluster.'
                Tags               = @{}
                Remediation        = ""
                TargetResourceID   = "StorageConnectivityType"
                TargetResourceName = "StorageConnectivityType"
                TargetResourceType = "StorageConnectivityType"
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = $Env:COMPUTERNAME
                    Resource  = 'StorageConnectivityType'
                    Detail    = 'This is not a RackAware cluster, so skip the storage connectivity type check.'
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
        }

        $storageConnectivityTypeResults += New-AzStackHciResultObject @storageConnectivityTypeRstObject

        return $storageConnectivityTypeResults
}

function Test-NwkValidator_StorageAdapterIPConfigurationPreUpdate
{
    <#
    .SYNOPSIS
        This test is run in the Patch and Update context only to check the storage adapter IP configuration
        This test validates storage adapters should have only 1 IP address configured.
        Or if it has multiple IP addresses, they should be in the same subnet.

    .DESCRIPTION
        During patch and update, we will check the IP configuration on the storage adapters.
        All storage adapters should have only 1 IP address configured on each of them.
        Or if an adapter has multiple IP addresses, they should be in the same subnet.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession
    )

    try
    {
        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $storageAdapterIpConfigResults = @()

        # Get storage adapter names from the storage intent
        [PSObject[]] $storageIntent = Get-NetIntent | Where-Object { $true -eq $_.IsStorageIntentSet }

        if ($storageIntent.Count -eq 0)
        {
            Log-Info "No storage intent found in the system. Skip the storage adapter IP configuration check."
            return $storageAdapterIpConfigResults
        }

        # Only 1 Storage intent allowed. So use index [0] here
        $storageIntentName = $storageIntent[0].IntentName
        [System.String[]] $storagePhysicalAdapters = $storageIntent[0].NetAdapterNamesAsList

        [System.String[]] $storageAdaptersToCheck = @()
        if (($true -eq $storageIntent.IsManagementIntentSet) -or ($true -eq $storageIntent.IsComputeIntentSet))
        {
            foreach ($pStorageNic in $storagePhysicalAdapters)
            {
                $storageAdaptersToCheck += "vSMB($($storageIntentName)#$($pStorageNic))"
            }
        }
        else
        {
            $storageAdaptersToCheck = $storagePhysicalAdapters
        }

        Log-Info "Active storage intent: $($storageIntentName)"
        $storageAdapterInfoMsg = "Storage intent adapter(s) in the system: [ $($storageAdaptersToCheck -join `",`") ]"
        Log-Info "$($storageAdapterInfoMsg)"

        $tmpRemediationMsg = "Storage intent adapter(s) should have only 1 IPv4 address configured on each or all IPs on the same adapter should be in the same subnet."
        $tmpRemediationMsg += "`nYou have $($storageAdapterInfoMsg):"
        $tmpRemediationMsg += "`nPlease run below PowerShell cmdlet to check the IP configuration on all the adapter(s):"
        $tmpRemediationMsg += "`n    Get-NetIPaddress -InterfaceAlias <INTERFACE_ALIAS> -AddressFamily IPv4 -PrefixOrigin Manual"
        $tmpRemediationMsg += "`nIf you find multiple IPs on the storage adapter(s), please remove the extra IPs that you do not need."
        $tmpRemediationMsg += "`n    Remove-NetIPAddress -InterfaceAlias <INTERFACE_ALIAS> -IPAddress <IPADDRESS> -Confirm:$false"

        # Invoke on all nodes in parallel
        Log-Info "Checking correct storage IP configured on storage adapter(s) on all nodes in parallel"
        $allStorageIpConfigResults = @(Invoke-Command -Session $allNodeSessions -ScriptBlock ${function:CheckStorageAdapterIPConfig} `
                            -ArgumentList @($storageAdaptersToCheck, $function:EnvValidatorNwkLibConvertIPAddressToInt, $function:EnvValidatorNwkLibConvertIntToIPAddressString, $function:EnvValidatorNwkLibGetNetworkAddress, $function:EnvValidatorNwkLibNormalizeIPv4Subnet))

        foreach ($storageAdapterIpConfigResult in $allStorageIpConfigResults)
        {
            $nodeName = $storageAdapterIpConfigResult.PSComputerName
            Log-Info "Got storage adapter readiness validation results from $nodeName"

            $storageAdapterIpConfigValidationStatus = if ($storageAdapterIpConfigResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
            $storageAdapterIpConfigValidationDetailMessage = $storageAdapterIpConfigResult.Message

            $storageAdapterIpConfigRstObject = @{
                Name               = 'AzStackHci_Network_Test_StorageAdapterIpConfiguration'
                Title              = 'Test storage adapter IP configuration on node'
                DisplayName        = 'Test storage adapter IP configuration on node'
                Severity           = 'CRITICAL'
                Description        = 'Test storage adapter IP configuration on node: should have only 1 IPv4 address configured or all IPs should be in the same subnet.'
                Tags               = @{}
                Remediation        = $tmpRemediationMsg
                TargetResourceID   = "StorageAdapterIpConfiguration"
                TargetResourceName = "StorageAdapterIpConfiguration"
                TargetResourceType = "StorageAdapterIpConfiguration"
                Timestamp          = [datetime]::UtcNow
                Status             = $storageAdapterIpConfigValidationStatus
                AdditionalData     = @{
                    Source    = $nodeName
                    Resource  = $storageAdaptersToCheck -join ","
                    Detail    = $storageAdapterIpConfigValidationDetailMessage
                    Status    = $storageAdapterIpConfigValidationStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $storageAdapterIpConfigResults += New-AzStackHciResultObject @storageAdapterIpConfigRstObject
        }

        return $storageAdapterIpConfigResults
    }
    catch
    {
        throw $_
    }
}

function Test-NwkValidator_StorageVlanFor2NodeSwitchLessDeployment {
    [CmdletBinding()]
    param (
        [PSObject] $HostNetworkInfo,
        [System.Int16] $NodeCount,
        [System.Boolean] $SwitchlessDeploy = $false
    )

    $instanceResults = @()

    if ($SwitchlessDeploy -and $NodeCount -eq 2) {
        Log-info "2-Node switchless deployment detected. Will check VLANID for 2-node switchless deployment."
    } else {
        Log-info "Node Count: [ $($NodeCount) ]"
        Log-info "Switchless Deployment? [ $($SwitchlessDeploy) ]"
        Log-info "Not a 2-node switchless deployment. Skip the VLANID check."
        return $instanceResults
    }

    try {
        [System.String[]] $storageVlanIdList = @()

        [System.String] $validationRst = ""
        [System.String] $validationDetailInfo = ""
        [System.String] $validationRemediation = ""

        if ($HostNetworkInfo.storageNetworks -and ($HostNetworkInfo.storageNetworks.Count -gt 0)) {
            $storageVlanIdList = $HostNetworkInfo.storageNetworks.vlanId | Select-Object -Unique

            [System.Int16] $storageVlanidProvided = $storageVlanIdList.Count
            $validationDetailInfo = "Found [ $($storageVlanidProvided) ] storage VLANID in the configuration: $($storageVlanIdList -join ',')"

            [PSObject[]] $atcHostIntents = $HostNetworkInfo.intents
            [PSObject[]] $storageIntent = $atcHostIntents | Where-Object { $_.TrafficType.Contains("Storage") }
            [System.String[]] $storageAdapters = $storageIntent.Adapter

            if ($storageVlanidProvided -eq $storageAdapters.Count) { $validationRst = 'SUCCESS' } else { $validationRst = 'FAILURE' }

            $validationRemediation = "Found [ $($storageVlanidProvided) ] storage VLANID. Make sure you provide one storage VLANID for each storage adapter provided on 2-node switchless deployment."
        } else {
            $validationRst = 'FAILURE'
            $validationDetailInfo = "No storageNetworks section or valid storage VLANID info provided in the configuration."
            $validationRemediation = "Please provide valid storageNetworks and storage VLANID information in your deployment configuration file: Make sure you provide one storage VLANID for each storage adapter provided on 2-node switchless deployment."
        }

        Log-Info $validationDetailInfo

        $params = @{
            Name               = 'AzStackHci_Network_Test_Network_StorageVlanFor2NodeSwitchLess'
            Title              = 'Test storage VLANID requirement for 2-node switchless deployment'
            DisplayName        = 'Test storage VLANID requirement for 2-node switchless deployment'
            Severity           = 'CRITICAL'
            Description        = 'Check user provides one storage VLANID for each storage adapter provided on 2-node switchless deployment'
            Tags               = @{}
            Remediation        = $validationRemediation
            TargetResourceID   = 'StorageVlanIdFor2NodeSwitchLess'
            TargetResourceName = 'StorageVlanIdFor2NodeSwitchLess'
            TargetResourceType = 'StorageVlanIdFor2NodeSwitchLess'
            Timestamp          = [datetime]::UtcNow
            Status             = $validationRst
            AdditionalData     = @{
                Source    = $env:COMPUTERNAME
                Resource  = 'StorageVlanIdFor2NodeSwitchLess'
                Detail    = $validationDetailInfo
                Status    = $validationRst
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $instanceResults += New-AzStackHciResultObject @params

        return $instanceResults
    } catch {
        throw $_
    }
}

function Test-NwkValidator_NetworkGatewayRequirement {
    <#
    .SYNOPSIS
        Verify that only one default gateway is defined in the system for the nodes.

    .DESCRIPTION
        This test is run in the deployment and add node scenario to make sure that there is
        only one default gateway defined in the system for the nodes
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession
    )

    try {
        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $defaultGatewayRequirementResults = @()

        $tmpRemediationMsg = "There should be only one default gateway defined on the server."
        $tmpRemediationMsg += "`n Please run below PowerShell cmdlet to verify the default gateway configuration on the machine:"
        $tmpRemediationMsg += "`n     Get-NetRoute -DestinationPrefix `"0.0.0.0/0`" -AddressFamily IPv4"
        $tmpRemediationMsg += "`n If you find multiple different gateway defined for the `"NextHop`" property from the above cmdlet"
        $tmpRemediationMsg += "`n call, please remove the one that you do not need from the system."
        $tmpRemediationMsg += "`n     Remove-NetRoute -DestinationPrefix `"0.0.0.0/0`" -NextHop <GATEWAY_IP_YOU_DO_NOT_NEED> -Confirm:$false"

        $validationScript = {
            $result = New-Object PSObject -Property @{
                Pass    = $true
                Message = ''
            }

            [PSObject[]] $defaultGateways = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue
            [System.String[]] $nextHops = $defaultGateways | Select-Object -ExpandProperty NextHop -Unique

            if ($nextHops.Count -gt 1) {
                $result.Pass = $false
                $result.Message = "Multiple default gateways found on $($ENV:COMPUTERNAME): $($nextHops -join ', ')."
            } elseif ($nextHops.Count -eq 0) {
                $result.Pass = $false
                $result.Message = "No default gateway defined on any adapter(s) on $($ENV:COMPUTERNAME)."
            } else {
                $result.Message = "Single default gateway found on $($ENV:COMPUTERNAME): $($nextHops[0])"
            }

            return $result
        }

        # Invoke on all nodes in parallel
        Log-Info "Checking default gateway configuration on all nodes in parallel"
        $allDefaultGatewayResults = @(Invoke-Command -Session $allNodeSessions -ScriptBlock $validationScript)

        foreach ($defaultGatewayConfigResult in $allDefaultGatewayResults) {
            $nodeName = $defaultGatewayConfigResult.PSComputerName
            Log-Info "Got default gateway validation results from $nodeName"

            $defaultGatewayConfigValidationStatus = if ($defaultGatewayConfigResult.Pass) { 'SUCCESS' } else { 'FAILURE' }

            if ($defaultGatewayConfigResult.Pass) {
                $defaultGatewayConfigValidationDetailMessage = $defaultGatewayConfigResult.Message
            } else {
                $defaultGatewayConfigValidationDetailMessage = $defaultGatewayConfigResult.Message + "`n`n" + $tmpRemediationMsg
            }

            $defaultGatewayValidationRstObject = @{
                Name               = 'AzureLocal_Network_Test_NetworkDefaultGatewayRequirement'
                Title              = 'Validate that only one default gateway is defined on the server'
                DisplayName        = 'Validate that only one default gateway is defined on the server'
                Severity           = 'CRITICAL'
                Description        = 'Each node must have a single default gateway configured.'
                Tags               = @{}
                Remediation        = "https://aka.ms/azurelocal/envvalidator/networkgatewayrequirement"
                TargetResourceID   = "$nodeName, NetworkDefaultGateway"
                TargetResourceName = "$nodeName, NetworkDefaultGateway"
                TargetResourceType = "NetworkDefaultGateway"
                Timestamp          = [datetime]::UtcNow
                Status             = $defaultGatewayConfigValidationStatus
                AdditionalData     = @{
                    Source    = $nodeName
                    Resource  = "NetworkDefaultGateway"
                    Detail    = $defaultGatewayConfigValidationDetailMessage
                    Status    = $defaultGatewayConfigValidationStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $defaultGatewayRequirementResults += New-AzStackHciResultObject @defaultGatewayValidationRstObject
        }

        return $defaultGatewayRequirementResults
    } catch {
        throw $_
    }
}

function Test-NwkValidator_MgmtIpConfigurationForStaticDeployment {
    [CmdletBinding()]
    param (
        [System.Collections.Hashtable] $NodeToManagementIPMap,
        [PSCredential] $ConnectionDomainAdminCredential = $null,
        [PSCredential] $ConnectionLocalAdminCredential = $null,
        [System.String] $DeployADLess = "false",
        [PSObject] $HostNetworkInfo
    )

    try {
        $nodeMgmtIpRequirementResults = @()

        if (-not $ConnectionDomainAdminCredential -and -not $ConnectionLocalAdminCredential) {
            throw "Must provide one credential to run Test-NwkValidator_MgmtIpConfigurationForStaticDeployment: DomainAdminCredential or LocalAdminCredential."
        }

        if (-not $HostNetworkInfo)
        {
            throw "HostNetworkInfo is required for the storage connection validation. Check your answer file / ARM template to make sure it contains section of [ ScaleUnits | DeploymentData | HostNetwork ]."
        }

        [PSObject[]] $AtcHostIntents = $HostNetworkInfo.intents
        [PSObject[]] $mgmtIntent = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Management") }
        [System.String] $firstAdapterName = $mgmtIntent[0].Adapter[0]

        # For each node defined in hashtable $NodeToManagementIPMap (which is node name to management IP mapping), we will try the following:
        # Try to create a PSSession to the node using the management IP defined in the hashtable.
        # if we can create the session successfully, then connect to that session and check if the machine name is the same as the node name defined in the hashtable.
        # if we cannot create the session successfully, it means the IP cannot be connected via remote session.
        foreach ($nodeName in $NodeToManagementIPMap.Keys) {
            $tmpNodeIP = $NodeToManagementIPMap[$nodeName]

            Log-Info "Checking management IP on server $($nodeName) is correct as expected to be [ $($tmpNodeIP) ]."

            $currentNodeMgmtIPConfigValidationStatus = "FAILURE"
            $currentNodeMgmtIPConfigValidationDetailMessage = "Management IP on server $($nodeName) is correct as expected: [ $($tmpNodeIP) ]."

            try {
                $tmpTestSession = EnvValidatorNwkLibTryCreateNewPsSessionOnNode -NodeName $nodeName `
                    -NodeIP $tmpNodeIP `
                    -ConnectionDomainAdminCredential $ConnectionDomainAdminCredential `
                    -ConnectionLocalAdminCredential $ConnectionLocalAdminCredential `
                    -DeployADLess $DeployADLess

                #region Test computername from the created session
                [System.String] $computerNameFromSession = ""
                $computerNameFromSession = InvokeRemoteCommandWithSessionId -TestSessionID $tmpTestSession.Id -ScriptToExecute { return $env:COMPUTERNAME }

                Log-Info "Machine name got from remote session is [ $($computerNameFromSession) ]"

                if ($computerNameFromSession -ieq $nodeName) {
                    $currentNodeMgmtIPConfigValidationStatus = "SUCCESS"
                } else {
                    $currentNodeMgmtIPConfigValidationDetailMessage = "Management IP on server $($nodeName) is NOT correct. Expected node name: $($nodeName), actual node name from IP: $($computerNameFromSession)."
                }

                Log-Info $currentNodeMgmtIPConfigValidationDetailMessage

                $nodeMgmtIPConnectionValidationRstObject = @{
                    Name               = 'AzureLocal_Network_Test_NodeManagementIPConnection'
                    Title              = 'Validate that management IP of host machine is able to be connected'
                    DisplayName        = 'Validate that management IP of host machine is able to be connected'
                    Severity           = 'INFORMATIONAL'
                    Description        = 'Management IP of each host machine defined in ECE config should be able to be connected correctly.'
                    Tags               = @{}
                    Remediation        = "https://aka.ms/azurelocal/envvalidator/networkmgmtipconfiguration"
                    TargetResourceID   = "$($nodeName), NetworkHostManagementIP"
                    TargetResourceName = "$($nodeName), NetworkHostManagementIP"
                    TargetResourceType = "NetworkHostManagementIP"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $currentNodeMgmtIPConfigValidationStatus
                    AdditionalData     = @{
                        Source    = $testSession.ComputerName
                        Resource  = "NetworkHostManagementIP"
                        Detail    = $currentNodeMgmtIPConfigValidationDetailMessage
                        Status    = $currentNodeMgmtIPConfigValidationStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $nodeMgmtIpRequirementResults += New-AzStackHciResultObject @nodeMgmtIPConnectionValidationRstObject
                #endregion

                #region Check that node to be checked has the first physical adapter and the physical adapter has the mgmt IP
                $nodeInfoScriptBlock = {
                    param (
                        [PSObject] $MgmtIntent
                    )

                    $ErrorActionPreference = 'Stop'

                    [System.String] $mgmtIntentName = $MgmtIntent.Name
                    [System.String[]] $expectedMgmtIntentAdapters = $MgmtIntent.Adapter
                    [System.String] $firstMgmtAdapterNameExpected = $expectedMgmtIntentAdapters[0]

                    # Default return values
                    [System.Boolean] $firstMgmtAdapterExists = $false
                    [PSObject[]] $mgmtIPOn1stAdapter = @()

                    [PSObject[]] $pNicObj = Get-NetAdapter -Physical -Name $firstMgmtAdapterNameExpected -ErrorAction SilentlyContinue
                    $firstMgmtAdapterExists = $pNicObj.Count -eq 1

                    if ($firstMgmtAdapterExists) {
                        [PSObject[]] $adapterIpInfo = $null
                        try {
                            # Try to get pNIC IP. using try/catch here as "SilentlyContinue" still throws error if Get-NetIPConfiguration fails
                            $adapterIpInfo = Get-NetIPConfiguration -InterfaceAlias $FirstMgmtAdapterNameExpected  -ErrorAction Stop
                        } catch {
                            # In case cannot get IP from pNIC, it could be the user already created SET VMSwitch in the system
                            # So try to get IP from the expected vNIC name
                            try {
                                [System.String] $vNicNameToCheck = "vManagement($($mgmtIntentName))"
                                $adapterIpInfo = Get-NetIPConfiguration -InterfaceAlias $vNicNameToCheck  -ErrorAction Stop
                            } catch {
                                # Do not want to throw exception here
                            }
                        }

                        # if we got IP info, means we got IP on the 1st pNIC, or on the expected vNIC
                        if ($adapterIpInfo) {
                            $mgmtIPOn1stAdapter = $adapterIpInfo[0].IPv4Address
                        }
                    }

                    $retVal = @{
                        MachineName = $env:COMPUTERNAME
                        FirstAdapterExists = $firstMgmtAdapterExists
                        ManagementIPv4AddressOn1stPhysicalAdapter = $mgmtIPOn1stAdapter
                    }

                    return $retVal
                }

                $testNodeMgmtAdapterInfoRst = InvokeRemoteCommandWithSessionId -TestSessionId $tmpTestSession.Id -ScriptToExecute $nodeInfoScriptBlock -Arguments $mgmtIntent[0]
                [System.String[]] $nodeManagementIPAddresses = $testNodeMgmtAdapterInfoRst.ManagementIPv4AddressOn1stPhysicalAdapter.IPAddress

                [System.String] $mgmtIPConfigStatus = "FAILURE"
                [System.String] $CheckAdapterContainsIPDetail = $lnTxt.CheckAdapterContainsIPPass -f $firstAdapterName, $tmpTestSession.ComputerName

                if ($nodeManagementIPAddresses -contains $tmpNodeIP) {
                    # Check if the node name from remote exists in the NodeToManagementIPMap and the IP matches
                    $mgmtIPConfigStatus = 'SUCCESS'
                } else {
                    # In Static deployment scenario, we are using IP for the remote session connection
                    # So if the IP is not found on the expected adapter, then it is a failure
                    $CheckAdapterContainsIPDetail = $lnTxt.CheckAdapterContainsIPFail -f $firstAdapterName, "vManagement($($mgmtIntent.Name))", $tmpTestSession.ComputerName
                }

                Log-Info $CheckAdapterContainsIPDetail

                $params = @{
                    Name               = 'AzureLocal_Network_Test_Node_ManagementIP_On_Correct_Adapter'
                    Title              = 'Test machine management IP is configured on correct adapter'
                    DisplayName        = 'Test machine management IP is configured on correct adapter'
                    Severity           = 'INFORMATIONAL'
                    Description        = 'Test machine management IP is configured on correct adapter'
                    Tags               = @{}
                    Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-checklist'
                    TargetResourceID   = "$($tmpTestSession.ComputerName), MgmtIPOnCorrectAdapter"
                    TargetResourceName = "$($tmpTestSession.ComputerName), MgmtIPOnCorrectAdapter"
                    TargetResourceType = "MgmtIPOnCorrectAdapter"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $mgmtIPConfigStatus
                    AdditionalData     = @{
                        Source    = "$($tmpTestSession.ComputerName), MgmtIPOnCorrectAdapter"
                        Resource  = "$($tmpTestSession.ComputerName), MgmtIPOnCorrectAdapter"
                        Detail    = $CheckAdapterContainsIPDetail
                        Status    = $mgmtIPConfigStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $nodeMgmtIpRequirementResults += New-AzStackHciResultObject @params
                #endregion

                #region Check that node management IP is not in subnet of storage network
                if ($mgmtIPConfigStatus -ieq "SUCCESS") {

                    [System.String] $mgmtIpAddress = $testNodeMgmtAdapterInfoRst.ManagementIPv4AddressOn1stPhysicalAdapter[0].IPAddress
                    [System.String] $mgmtIpGateway = $testNodeMgmtAdapterInfoRst.ManagementIPv4AddressOn1stPhysicalAdapter[0].PrefixLength
                    [System.String] $mgmtIpSubnetCIDR = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$($mgmtIpAddress)/$($mgmtIpGateway)"

                    [System.String[]] $storageSubnetInfo = @()
                    if ($HostNetworkInfo.EnableStorageAutoIP) {
                        # Mgmt IP should not overlap with storage subnet like 10.71.1.0/24, 10.71.2.0/24, etc.
                        [PSObject[]] $storageIntent = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Storage") }
                        [PSObject[]] $storageVLANID = $HostNetworkInfo.StorageNetworks.VlanId | Select-Object -Unique
                        [System.String[]] $storageAdapters = $storageIntent.Adapter

                        # Subnet count should be the smaller number of $storageVLANID.Count and $storageAdapters.Count
                        [System.UInt16] $subnetCount = if ($storageVLANID.Count -lt $storageAdapters.Count) { $storageVLANID.Count } else { $storageAdapters.Count }
                        for ($i = 1; $i -le $subnetCount; $i++) {
                            $storageSubnetInfo += "10.71.$($i).0/24"
                        }
                    } else {
                        # Mgmt IP should not overlap with storage subnet defined in the answer file section storageNetworks section
                        [PSObject[]] $storageAdapterIpInfo = $HostNetworkInfo.StorageNetworks.StorageAdapterIPInfo
                        foreach ($tmpAdapterIpInfo in $storageAdapterIpInfo) {
                            # $tmpAdapterIpInfo.IPv4Address has the address of the adapter, $tmpAdapterIpInfo.SubnetMask has the subnet mask for that IP
                            # we could calculate the CIDR from subnet mask and the IP
                            $currentEntryPrefixLength = EnvValidatorNwkLibConvertToPrefixLength -SubnetMask $tmpAdapterIpInfo.SubnetMask
                            $currentSubnet = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$($tmpAdapterIpInfo.IPv4Address)/$($currentEntryPrefixLength)"
                            if (-not $storageSubnetInfo.Contains($currentSubnet)) {
                                $storageSubnetInfo += $currentSubnet
                            }
                        }
                    }

                    [System.String] $mgmtIPOverlapWithStorageStatus = "FAILURE"

                    if ($storageSubnetInfo.Contains($mgmtIpSubnetCIDR)) {
                        $mgmtIPOverlapWithStorageStatus = "FAILURE"
                        $mgmtIPOverlapWithStorageDetailInfo = "Management IP $mgmtIpAddress on subnet $mgmtIpSubnetCIDR overlaps with storage subnet(s): $($storageSubnetInfo -join ', ')."
                    } else {
                        $mgmtIPOverlapWithStorageStatus = "SUCCESS"
                        $mgmtIPOverlapWithStorageDetailInfo = "Management IP $mgmtIpAddress on subnet $mgmtIpSubnetCIDR does not overlap with any storage subnet(s): $($storageSubnetInfo -join ', ')."
                    }

                    Log-Info $mgmtIPOverlapWithStorageDetailInfo

                    $params = @{
                        Name               = 'AzureLocal_Network_Test_Node_ManagementIP_Not_Overlap_With_Storage_Subnet'
                        Title              = 'Test machine management IP is not in the same subnet as any storage network'
                        DisplayName        = 'Test machine management IP is not in the same subnet as any storage network'
                        Severity           = 'INFORMATIONAL'
                        Description        = 'Test machine management IP is not in the same subnet as any storage network'
                        Tags               = @{}
                        Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-checklist'
                        TargetResourceID   = "$($tmpTestSession.ComputerName), MgmtIPNotOverlapStorageSubnet"
                        TargetResourceName = "$($tmpTestSession.ComputerName), MgmtIPNotOverlapStorageSubnet"
                        TargetResourceType = "MgmtIPNotOverlapStorageSubnet"
                        Timestamp          = [datetime]::UtcNow
                        Status             = $mgmtIPOverlapWithStorageStatus
                        AdditionalData     = @{
                            Source    = "$($tmpTestSession.ComputerName), MgmtIPNotOverlapStorageSubnet"
                            Resource  = "$($tmpTestSession.ComputerName), MgmtIPNotOverlapStorageSubnet"
                            Detail    = $mgmtIPOverlapWithStorageDetailInfo
                            Status    = $mgmtIPOverlapWithStorageStatus
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }

                    $nodeMgmtIpRequirementResults += New-AzStackHciResultObject @params
                }
                #endregion
            } finally {
                if ($null -ne $tmpTestSession) {
                    Log-Info "Need to remove temporary test session to server $($nodeName): Session Id $($tmpTestSession.Id)"
                    Microsoft.PowerShell.Core\Remove-PSSession -Id $tmpTestSession.Id -ErrorAction SilentlyContinue
                }
            }
        }

        return $nodeMgmtIpRequirementResults
    } catch {
        $nodeMgmtIPConnectionValidationRstObject = @{
            Name               = "AzureLocal_Network_Test_NodeManagementIPConnection_ExceptionFound"
            Title              = 'Exception found during management IP configuration validation.'
            DisplayName        = 'Exception found during management IP configuration validation.'
            Severity           = 'INFORMATIONAL'
            Description        = 'Experienced exception during management IP configuration validation. Please check information in AdditionalData.Detail.'
            Tags               = @{}
            Remediation        = "https://aka.ms/azurelocal/envvalidator/networkmgmtipconfiguration"
            TargetResourceID   = "NetworkHostManagementIP"
            TargetResourceName = "NetworkHostManagementIP"
            TargetResourceType = 'NetworkHostManagementIP'
            Timestamp          = [datetime]::UtcNow
            Status             = 'FAILURE'
            AdditionalData     = @{
                Source    = "NetworkHostManagementIPValidationException"
                Resource  = "NetworkHostManagementIP"
                Detail    = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
                Status    = 'FAILURE'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $nodeMgmtIpRequirementResults += New-AzStackHciResultObject @nodeMgmtIPConnectionValidationRstObject

        return $nodeMgmtIpRequirementResults
    }
}

function Test-NwkValidator_IntentVirtualAdapterExistence {
    [CmdletBinding()]
    param
    (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        [PSObject[]] $AtcHostIntents
    )

    try {
        Log-Info "Start running Test-NwkValidator_IntentVirtualAdapterExistence"

        if (($PSSession.Count -eq 0) -or ($AtcHostIntents.Count -eq 0))
        {
            Log-Info "No PSSession or AtcHostIntents provided. Skip run of Test-NwkValidator_IntentVirtualAdapterExistence"
            return
        }
        else
        {
            Log-Info "Will check intent virtual adapter readiness on all nodes defined in PSSession."
        }

        #region Prepare checking configuration/script
        [System.Management.Automation.Runspaces.PSSession[]] $allPSSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession
        [System.String[]] $intentVirtualAdapterNames = @()
        foreach ($intent in $AtcHostIntents) {
            if ($intent.TrafficType.contains("Management")) {
                $intentVirtualAdapterNames += "vManagement($($intent.Name))"
            }

            if ($intent.TrafficType.contains("Storage") -and ($intent.TrafficType.contains("Management") -or $intent.TrafficType.contains("Compute"))) {
                # Converged storage
                foreach ($storageAdapter in $intent.Adapter) {
                    $intentVirtualAdapterNames += "vSMB($($intent.Name)#$($storageAdapter))"
                }
            }
        }

        $intentVirtualAdapterNames = $intentVirtualAdapterNames | Select-Object -Unique

        $checkVirtualAdapterScript = {
            [CmdletBinding()]
            param (
                [System.String[]] $ExpectedAdapters
            )

            $retVal = New-Object PSObject -Property @{
                Pass = $true
                Message = "Virtual adapter status on $($ENV:COMPUTERNAME)"
            }

            foreach ($adapterToCheck in $ExpectedAdapters) {
                [PSObject[]] $getVMNetworkAdapterRst = Get-VMNetworkAdapter -ManagementOS -Name $adapterToCheck -ErrorAction SilentlyContinue

                if ($getVMNetworkAdapterRst.Count -eq 1) {
                    $retVal.Message += "`n    Pass:  VMNetworkAdapter $adapterToCheck exists."
                } else {
                    $retVal.Pass = $false
                    $retVal.Message += "`n    ERROR: VMNetworkAdapter $adapterToCheck does NOT exist."
                }

                [PSObject[]] $getNetAdapterRst = Get-NetAdapter -Name $adapterToCheck -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

                if ($getNetAdapterRst.Count -eq 1) {
                    $retVal.Message += "`n    Pass:  NetAdapter $adapterToCheck exists and is Up."
                } else {
                    $retVal.Pass = $false
                    $retVal.Message += "`n    ERROR: NetAdapter $adapterToCheck does NOT exist or is not Up."
                }
            }

            return $retVal
        }
        #endregion

        [PSObject[]] $intentVirtualAdapterExistenceTestResults = @()

        # Invoke on all nodes in parallel
        Log-Info "Checking intent virtual adapter readiness on all nodes in parallel"
        $allIntentVAdapterResults = @(Invoke-Command -Session $allPSSessions -ScriptBlock $checkVirtualAdapterScript -ArgumentList @(, $intentVirtualAdapterNames))

        foreach ($IntentVirtualAdapterExistenceResult in $allIntentVAdapterResults)
        {
            $nodeName = $IntentVirtualAdapterExistenceResult.PSComputerName
            Log-Info "Got intent virtual adapter readiness validation results from $nodeName"

            $IntentVirtualAdapterExistenceValidationStatus = if ($IntentVirtualAdapterExistenceResult.Pass) { 'SUCCESS' } else { 'FAILURE' }
            $IntentVirtualAdapterExistenceValidationDetailMessage = $IntentVirtualAdapterExistenceResult.Message

            $IntentVirtualAdapterExistenceRstObject = @{
                Name               = 'AzureLocal_Network_Test_IntentVirtualAdapterExistence'
                Title              = 'Test intent virtual adapter readiness'
                DisplayName        = 'Test intent virtual adapter readiness on server'
                Severity           = 'INFORMATIONAL'
                Description        = 'Check intent virtual adapter readiness on {0}' -f $nodeName
                Tags               = @{}
                Remediation        = "https://aka.ms/azurelocal/envvalidator/IntentVirtualAdapterExistence"
                TargetResourceID   = "IntentVirtualAdapterExistence"
                TargetResourceName = "IntentVirtualAdapterExistence"
                TargetResourceType = "IntentVirtualAdapterExistence"
                Timestamp          = [datetime]::UtcNow
                Status             = $IntentVirtualAdapterExistenceValidationStatus
                AdditionalData     = @{
                    Source    = $nodeName
                    Resource  = "IntentVirtualAdapterExistence"
                    Detail    = $IntentVirtualAdapterExistenceValidationDetailMessage
                    Status    = $IntentVirtualAdapterExistenceValidationStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $intentVirtualAdapterExistenceTestResults += New-AzStackHciResultObject @IntentVirtualAdapterExistenceRstObject
        }

        return $intentVirtualAdapterExistenceTestResults

    } catch {
        $intentVirtualAdapterExistenceRstObject = @{
            Name               = "AzureLocal_Network_Test_IntentVirtualAdapterExistence_ExceptionFound"
            Title              = 'Exception found during intent virtual adapter readiness validation.'
            DisplayName        = 'Exception found during intent virtual adapter readiness validation.'
            Severity           = 'INFORMATIONAL'
            Description        = 'Exception found during intent virtual adapter readiness validation. Please check information in AdditionalData.Detail.'
            Tags               = @{}
            Remediation        = "https://aka.ms/azurelocal/envvalidator/IntentVirtualAdapterExistence"
            TargetResourceID   = "IntentVirtualAdapterExistence"
            TargetResourceName = "IntentVirtualAdapterExistence"
            TargetResourceType = 'IntentVirtualAdapterExistence'
            Timestamp          = [datetime]::UtcNow
            Status             = 'FAILURE'
            AdditionalData     = @{
                Source    = "IntentVirtualAdapterExistenceValidationException"
                Resource  = "IntentVirtualAdapterExistence"
                Detail    = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
                Status    = 'FAILURE'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $intentVirtualAdapterExistenceTestResults += New-AzStackHciResultObject @intentVirtualAdapterExistenceRstObject

        return $intentVirtualAdapterExistenceTestResults
    }
}

#################################################################################################
# Helper Functions
#################################################################################################
function TestMgmtIpPools
{
    <#
    .SYNOPSIS
        Ensure all ip are in management subnet.
    #>

    param (
        [Parameter(Mandatory = $true, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [Parameter(Mandatory = $false, HelpMessage = "Specify Management Subnet")]
        [string] $ManagementSubnetValue
    )

    try
    {
        $allIps = EnvValidatorNwkLibGetMgmtIpRangeFromPools -IpPools $IpPools

        $uniqueIPs = @{}
        foreach ($ip in $allIps)
        {
            $ipString = $ip.ToString()
            if ($uniqueIPs.ContainsKey($ipString))
            {
                return $false
            }
            else
            {
                $uniqueIPs[$ipString] = $true
            }
        }

        # More reliable test to make sure all ips in the management pool
        if (-not ([string]::IsNullOrEmpty($ManagementSubnetValue)))
        {
            foreach ($ipPool in $IpPools)
            {
                $StartingAddress = $ipPool.StartingAddress
                $EndingAddress = $ipPool.EndingAddress

                if (!(CheckIPInSubnet -IPAddress $StartingAddress -CIDR $ManagementSubnetValue))
                {
                    return $false
                }

                if (!(CheckIPInSubnet -IPAddress $EndingAddress -CIDR $ManagementSubnetValue))
                {
                    return $false
                }
            }
        } else {
            # Should not get here, but just in case
            Log-Info "Management subnet value is not provided. Skipping management subnet check."
        }


        return $true
    }
    catch
    {
        throw "Failed to check ip pools. Error: $_"
    }
}

function CheckIPInSubnet {
    param(
        [Parameter(Mandatory=$true)]
        [System.String] $IPAddress,

        # Range in which to search using CIDR notation. (IpAddress/PrefixLength)
        [Parameter(Mandatory=$true)]
        [System.String] $CIDR
    )
    # $CIDR should already be normalized CIDR format
    # Call this function here just to ensure the format in case it is not normalized
    $CIDR = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet $CIDR

    # Split range into the address and the CIDR notation prefix
    [System.String[]] $cidrParts = $CIDR.Split('/')
    [String] $CIDRAddress = $cidrParts[0]
    [int] $prefixLength   = $cidrParts[1]

    # Convert network and IP address to unsigned integers
    $network = [System.Net.IPAddress]::Parse($CIDRAddress)
    $networkInt = EnvValidatorNwkLibConvertIPAddressToInt -IPAddress $network

    $ip = [System.Net.IPAddress]::Parse($IPAddress)
    $ipInt = EnvValidatorNwkLibConvertIPAddressToInt -IPAddress $ip

    # Create subnet mask
    $mask = [uint32]([math]::Pow(2,32) - [math]::Pow(2, (32 - $prefixLength)))

    # Test if IP belongs to subnet
    return (($ipInt -band $mask) -eq ($networkInt -band $mask))
}

function TestMgmtRangeSize
{
    <#
    .SYNOPSIS
        Ensure IP range is within boundaries.
    #>
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [int]
        $Minimum = 6,

        [int]
        $Maximum = 16
    )

    try
    {
        $totalCount = 0
        foreach ($ipPool in $IpPools)
        {
            $StartingAddress = $ipPool.StartingAddress
            $EndingAddress = $ipPool.EndingAddress
            [System.String[]] $allIpInCurrentPool = EnvValidatorNwkLibGetIpRange -StartingAddress $StartingAddress -EndingAddress $EndingAddress
            Log-info "Start: $StartingAddress and end: $EndingAddress gives host count: $($allIpInCurrentPool.Count)"
            $totalCount += $allIpInCurrentPool.Count
        }

        if ($totalCount -gt $Maximum -or $totalCount -lt $Minimum)
        {
            return $false
        }
        else
        {
            return $true
        }
    }
    catch
    {
        throw "Failed to check range size. Error: $_"
    }
}

function TestMgmtRangePoolCount
{
    <#
    .SYNOPSIS
        #1, either one single pool that is big enough (>= Minimum IPs) (for both DHCP and static scenario) <== for general customers , or
        #2, 2 pools with 1 pool having 1 IP and 2 pool have at least (Minimum - 1 IPs) (for non-DHCP scenario only) <== for specific customers?
    #>
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList]
        $IpPools,

        [int]
        $Minimum = 5
    )

    try
    {
        $poolCount = $IpPools.Count

        if ($poolCount -gt 2)
        {
            Log-info "Found more than 2 IP pools. Test Failed"
            return $false
        }
        elseif ($poolCount -eq 1)
        {
            Log-info "Found only 1 IP Pool. Test Passed"
            return $true
        }
        else # 2 pools
        {
            $StartingAddress = $IpPools[0].StartingAddress
            $EndingAddress = $IpPools[0].EndingAddress
            [System.String[]] $allIpInFirstPool = EnvValidatorNwkLibGetIpRange -StartingAddress $StartingAddress -EndingAddress $EndingAddress
            $ipCount = $allIpInFirstPool.Count

            if ($ipCount -ne 1)
            {
                Log-info "Found more than 1 ip in first IP pool. Test Failed"
                return $false
            }

            $StartingAddress = $IpPools[1].StartingAddress
            $EndingAddress = $IpPools[1].EndingAddress
            [System.String[]] $allIpInSecondPool = EnvValidatorNwkLibGetIpRange -StartingAddress $StartingAddress -EndingAddress $EndingAddress
            $ipCount = $allIpInSecondPool.Count

            if ($ipCount -lt ($Minimum - 1))
            {
                Log-info "Found less then enough IPs in second IP pool. Test Failed"
                return $false
            }

            Log-info "Test Passed"
            return $true
        }
    }
    catch
    {
        throw "Failed to check IP Pool Count. Error: $_"
    }
}

function IsTcpPortInUse
{
    param(
        [System.Net.IPAddress]
        $Ip,

        [int]
        $Port = 5986,

        [int]
        $Timeout = 500
    )

    try
    {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $portOpened = $tcpClient.ConnectAsync($ip, $Port).Wait($timeout)
        $tcpClient.Dispose()
        return ($portOpened -contains $true)
    }
    catch
    {
        return $true
    } finally {
        if ($tcpClient) {
            $tcpClient.Dispose()
        }
    }
}

function CheckNetAdapterRDMAStatus
{
    param (
        [PSObject[]] $IntentsInfoFromJson
    )

    $retVal = New-Object PSObject -Property @{
        Pass = $true
        Message = "on $($ENV:COMPUTERNAME)"
    }

    enum NetworkDirectEnabledState { Disabled = 0; Enabled = 1 }

    # Read RDMA state info for all adapters
    [PSObject[]] $allAdapterRdmaInfo = Get-NetAdapterRdma

    [System.Boolean] $validSystemRdmaConfig = $true

    # need to check each adapter for all intents
    foreach ($currentIntent in $IntentsInfoFromJson)
    {
        [System.String[]] $adaptersToCheck = $currentIntent.Adapter
        [PSObject[]] $rdmaInfoForAdaptersToCheck = $allAdapterRdmaInfo | Where-Object { $_.Name -in $adaptersToCheck }

        [Boolean] $currentIntentAdapterOverride = $currentIntent.OverrideAdapterProperty
        [System.Int32] $currentIntentNetworkDirectOverride = 0
        if (-Not [System.String]::IsNullOrEmpty($currentIntent.AdapterPropertyOverrides.NetworkDirect))
        {
            $currentIntentNetworkDirectOverride = [System.Int32] [NetworkDirectEnabledState] $currentIntent.AdapterPropertyOverrides.NetworkDirect
        }
        $retVal.Message += "`n  Intent $($currentIntent.Name) Adapter Override - [ $currentIntentAdapterOverride ]; NetworkDirect - [ $currentIntentNetworkDirectOverride ]"

        if ($rdmaInfoForAdaptersToCheck.Count -ne $adaptersToCheck.Count)
        {
            # End user provided adapter(s) that don't have RDMA support (a.k.a, Get-NetAdapterRdma returns nothing for the adapter)
            # So the intent adapter override should have NetworkDirect Disabled. Otherwise the configuration will fail the ATC configuration
            # Note that if Get-NetAdapterRdma returns nothing, it means that the adapter does not support RDMA. Ideally customer should not
            # need to override, but we still need to check this condition due to a bug in OS ATC code. So remove the $rdmaInfoForAdaptersToCheck.Count -eq 0 check
            if ($currentIntentAdapterOverride -and $currentIntentNetworkDirectOverride -eq 0) {
                $retVal.Message += "`n    Correct configuration for adapters  [ $($adaptersToCheck -join ", ") ]: RDMA not supported on some adapters, and intent is configured with adapter override to disable NetworkDirect"
            } else {
                $retVal.Message += "`n    Wrong configuration for adapters  [ $($adaptersToCheck -join ", ") ]: RDMA not supported some adapters, but intent is NOT configured with adapter override to disable NetworkDirect"
                $retVal.Message += "`n        Run `"Get-NetAdapterRdma`" to check if RDMA is supported on storage adapter(s)."
                $retVal.Message += "`n        Make sure use OverrideAdapterProperty to disable NetworkDirect for storage intent if RDMA is not supported on the adapter(s)"
                $validSystemRdmaConfig = $false
            }
        }
        else
        {
            foreach ($currentRdmaInfo in $rdmaInfoForAdaptersToCheck)
            {

                # The following conditions are valid for RDMA configuration:
                # RDMA Enabled | RDMA OperationalStatus | Override | OverrideValue
                # True         | True                   |  -       |  -
                # -            | False                  | True     |  0
                # False        | False                  | False    |  -
                $rdmaEnabled = $currentRdmaInfo.Enabled
                $rdmaOperationalState = $currentRdmaInfo.OperationalState

                $validRdmaForCurrentAdapter = ($rdmaEnabled -and $rdmaOperationalState) -or
                                            ((-not $rdmaOperationalState) -and $currentIntentAdapterOverride -and $currentIntentNetworkDirectOverride -eq 0) -or
                                            ((-not $rdmaEnabled) -and (-not $rdmaOperationalState) -and (-not $currentIntentAdapterOverride))

                if (-not $validRdmaForCurrentAdapter) {
                    $retVal.Message += "`n    Wrong configuration for adapter $($currentRdmaInfo.Name):"
                    $retVal.Message += "`n        RDMA Enabled - [ $rdmaEnabled ]; RDMA OperationalState - [ $rdmaOperationalState ]"
                    $retVal.Message += "`n        OverrideAdapterProperty - [ $currentIntentAdapterOverride ]; NetworkDirect - [ $currentIntentNetworkDirectOverride ]"
                    $retVal.Message += "`n    If you want to use RDMA, make sure RDMA is enabled on the adapter and OperationalState is True."

                    if (-not $rdmaOperationalState) {
                        $retVal.Message += "`n    RDMA OperationalState is False. Please check BIOS setting of the machine to make sure RDMA is enabled in BIOS. Contact your hardware vendor for more information."
                    }
                } else {
                    $retVal.Message += "`n    Correct configuration for adapter $($currentRdmaInfo.Name): RDMA Enabled - [ $rdmaEnabled ], RDMA OperationalState - [ $rdmaOperationalState ]"
                }

                $validSystemRdmaConfig = $validSystemRdmaConfig -and $validRdmaForCurrentAdapter
            }
        }
    }

    if (-not $validSystemRdmaConfig)
    {
        $retVal.Pass = $false
        $retVal.Message = "`nERROR: RDMA setting on adapters are invalid " + $retVal.Message
    }
    else
    {
        $retVal.Pass = $true
        $retVal.Message = "`nPASS: RDMA setting on adapters are valid " + $retVal.Message
    }

    return $retVal
}

function CheckAdapterSymmetryAndBandwidth
{
    param (
        [PSObject[]] $IntentsInfoFromJson,
        [System.Int64] $ExpectedBandWidth = 10000000000
    )

    function ParseComponentID {
        [CmdletBinding()]
        param (
            [Parameter()]
            [System.String] $ComponentID
        )
        # https://learn.microsoft.com/en-us/windows-hardware/drivers/install/identifiers-for-pci-devices
        # ComponentID sample: "pci\ven_8086&dev_1593&subsys_000a8086"
        [System.Collections.Hashtable] $componentIDParts = @{}

        # Get the enumerator part and the rest of the component ID
        [System.String[]] $enumeratorParts = $ComponentID.Split("\", [System.StringSplitOptions]::RemoveEmptyEntries)
        [System.String[]] $idAfterEnumerator = $null;

        if ($enumeratorParts.Count -gt 1) {
            $componentIDParts.Add("Enumerator", $enumeratorParts[0])
            $idAfterEnumerator = $enumeratorParts[1]
        }

        if ($null -ne $idAfterEnumerator) {
            # Split the rest of the component ID by '&' and parse each part
            [System.String[]] $parts = $idAfterEnumerator.Split("&", [System.StringSplitOptions]::RemoveEmptyEntries)

            foreach ($part in $parts) {
                if ($part -like "VEN_*") {
                    [System.String] $vendorVal = $part.Substring("VEN_".Length)
                    $componentIDParts.Add("Vendor", $vendorVal)
                } elseif ($part -like "DEV_*") {
                    [System.String] $deviceVal = $part.Substring("DEV_".Length);
                    $componentIDParts.Add("Device", $deviceVal);
                } elseif ($part -like "SUBSYS_*") {
                    [System.String] $subSysVal = $part.Substring("SUBSYS_".Length);
                    $componentIDParts.Add("SubSys", $subSysVal);
                } elseif ($part -like "REV_*") {
                    [System.String] $revisionVal = $part.Substring("REV_".Length);
                    $componentIDParts.Add("Revision", $revisionVal);
                } elseif ($part -like "CC_*") {
                    [System.String] $classCodeVal = $part.Substring("CC_".Length);
                    $componentIDParts.Add("ClassCode", $classCodeVal);
                }
            }
        }

        return $componentIDParts;
    }

    function CompareComponentIDFields {
        param (
            [System.Collections.Hashtable] $componentIDParts1,
            [System.Collections.Hashtable] $componentIDParts2,
            [System.String[]] $fieldsToCompare = @("Vendor", "Device")
        )

        # Ignore other fields for now, since driver updates may the component ID to change (ex. append &Subsys_<ssss> value)

        foreach ($field in $fieldsToCompare) {
            if ($componentIDParts1.ContainsKey($field) -and $componentIDParts2.ContainsKey($field)) {
                if ($componentIDParts1[$field] -ne $componentIDParts2[$field] ) {
                    return $false
                }
            }
        }

        return $true
    }

    enum NetworkDirectEnabledState { Disabled = 0; Enabled = 1 }

    $nodeName = $env:COMPUTERNAME
    $retVal = New-Object PSObject -Property @{
        Pass = $true
        Message = "on $($nodeName)`n"
    }

    [PSObject[]] $allAdapterInfo = Get-NetAdapter

    foreach ($currentIntent in $IntentsInfoFromJson)
    {
        [System.String[]] $adaptersToCheck = $currentIntent.Adapter

        $intentAdapterInfoToCheck = $allAdapterInfo | Where-Object { $_.Name -in $adaptersToCheck }

        # Check adapter symmetry
        $retVal.Message += "`n--- Adapter Symmetry Check: Link speed and Vendor/Device part in ComponentID should be same for all adapters in the intent"

        $compIDFail = $false
        $linkSpeedFail = $false
        $expectedSpeed = $null
        $expectedComponentID = $null

        foreach ($nicInfo in $intentAdapterInfoToCheck)
        {
            if ($null -eq $expectedSpeed)
            {
                $expectedSpeed = $nicInfo.Speed
            }

            if ($null -eq $expectedComponentID)
            {
                $expectedComponentID = $nicInfo.ComponentID
            }

            if ($expectedSpeed -ne $nicInfo.Speed)
            {
                $linkSpeedFail = $true
            }

            # ComponentID is a string that contains the Component ID of the adapter.
            # It is of format like "pci\ven_8086&dev_1593&subsys_000a8086"
            # https://learn.microsoft.com/en-us/windows-hardware/drivers/install/identifiers-for-pci-devices
            # ATC now check for Vendor and Device only, so we will need to use the same logic here
            [System.Boolean] $currentComponentIdCompareRst = $false
            $currentComponentIdCompareRst = CompareComponentIDFields (ParseComponentID -ComponentID $expectedComponentID) (ParseComponentID -ComponentID $nicInfo.ComponentID)

            if (-not $currentComponentIdCompareRst)
            {
                $compIDFail = $true
            }

            if ($linkSpeedFail -Or $compIDFail)
            {
                $retVal.Pass = $false
            }

            $retVal.Message += "`n -- $nodeName ($($nicInfo.Name),`t$($nicInfo.LinkSpeed),`t$($nicInfo.ComponentID))"
        }

        # Check adapter bandwidth
        # This is needed if current intent is for storage traffic and adapter property is not overridden with NetworkDirect Disabled
        [Boolean] $currentIntentAdapterOverride = $currentIntent.OverrideAdapterProperty
        [System.Int32] $currentIntentNetworkDirectOverride = 0
        if (-Not [System.String]::IsNullOrEmpty($currentIntent.AdapterPropertyOverrides.NetworkDirect))
        {
            $currentIntentNetworkDirectOverride = [System.Int32] [NetworkDirectEnabledState] $currentIntent.AdapterPropertyOverrides.NetworkDirect
        }

        $needCheckBandwidth = $currentIntent.TrafficType.Contains("Storage") -and (-not $currentIntentAdapterOverride -or $currentIntentNetworkDirectOverride -ne 0)
        if ($needCheckBandwidth)
        {
            $retVal.Message += "`n--- Adapter Bandwidth Check for storage adapters when RDMA enabled: Need to be 10Gbps or higher"

            foreach ($nicInfo in $intentAdapterInfoToCheck)
            {
                if ($nicInfo.Speed)
                {
                    if ([System.Int64] $nicInfo.Speed -lt $ExpectedBandWidth)
                    {
                        $retVal.Pass = $false
                    }

                    $retVal.Message += "`n -- $nodeName ($($nicInfo.Name),`t$($nicInfo.LinkSpeed))"
                }
                else
                {
                    $retVal.Pass = $false
                    $retVal.Message += "`n -- $nodeName ($($nicInfo.Name), Speed not available)"
                }
            }
        }
    }

    if ($retVal.Pass)
    {
        $retVal.Message = "`nPASS: Network adapter(s) are symmetric and meet bandwidth requirement " + $retVal.Message
    }
    else
    {
        $retVal.Message = "`nERROR: Network adapter(s) are not symmetric or do not meet bandwidth requirement " + $retVal.Message
    }

    return $retVal
}

function CheckHostNetworkConfigurationReadiness
{
    param
    (
        [PSObject[]] $IntentsInfoFromJson
    )

    $retVal = New-Object PSObject -Property @{
        Pass = $true
        Message = "On $($ENV:COMPUTERNAME):"
    }

    [System.String[]] $intentAdapters = $IntentsInfoFromJson | ForEach-Object { $_.Adapter } | Select-Object -Unique

    [PSObject[]] $extSwitchInfo = @()

    if ((Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) -and (Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue).Installed)
    {
        $extSwitchInfo = Get-VMSwitch -SwitchType External
    }

    [System.String] $interimPassMessage = ""

    #region Check DNS client configuration
    [PSObject[]] $adapterDnsClientInfo = Get-DNSClient
    [System.String[]] $adapterWithDNSClientInfo = $adapterDnsClientInfo.InterfaceAlias | Select-Object -Unique

    if ($adapterWithDNSClientInfo.Count -eq 0) {
        # Should not be here, but just in case for some weird system configuration
        $retVal.Pass = $false
        $retVal.Message += "`nERROR: No network adapter has DNS Client configuration"
        return $retVal
    }

    [System.String[]] $adaptersToCheck = @()

    if ($extSwitchInfo.Count -eq 0)
    {
        # In case there is no VMSwitch in the system, we will need to make sure all adapters used in intents are in the result of Get-DNSClient
        $adaptersToCheck = $intentAdapters
    }
    else
    {
        # if there is a VMSwitch, we will need to make sure that those adapters not in VMSwitch but in intent are in the result of Get-DNSClient
        [System.Guid[]] $switchAdapterGuids = $extSwitchInfo | ForEach-Object { $_.NetAdapterInterfaceGuid }
        [System.String[]] $adaptersNotInVMSwitchNames = Get-NetAdapter -Physical | Where-Object { $_.InterfaceGuid -notin $switchAdapterGuids } | ForEach-Object { $_.Name }
        $adaptersToCheck = $intentAdapters | Where-Object { $_ -in $adaptersNotInVMSwitchNames }
    }

    if ($adaptersToCheck.Count -eq 0)
    {
        #This means all the adapters defined in intent are used in VMSwitch
        $intentAdapterMissingDnsClient = $null
    }
    else
    {
        $intentAdapterMissingDnsClient = Compare-Object $adaptersToCheck $adapterWithDNSClientInfo | Where-Object { $_.SideIndicator -eq "<=" } | ForEach-Object { $_.InputObject }
    }

    if ($intentAdapterMissingDnsClient.Count -gt 0)
    {
        $retVal.Pass = $false
        $retVal.Message += "`nERROR: DNS Client configuration is missing for the following adapter(s): $($intentAdapterMissingDnsClient -join ', ')"
    }
    else
    {
        $interimPassMessage += "`nPASS: DNS Client configuration has valid data for all adapters defined in intent"
    }
    #endregion

    #region Check Hyper-V running status by calling Get-VMHost
    if ((Get-Command Get-VMHost -ErrorAction SilentlyContinue) -and (Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue).Installed)
    {
        [PSObject[]] $vmHostInfo = Get-VMHost -ErrorAction SilentlyContinue
        if ($vmHostInfo.Count -eq 0)
        {
            $retVal.Pass = $false
            $retVal.Message += "`nERROR: Hyper-V is not running correctly on the system"
        }
        else
        {
            $interimPassMessage += "`nPASS: Hyper-V is running correctly on the system"
        }
    }
    else
    {
        $interimPassMessage += "`nWARNING: Hyper-V-PowerShell might not installed correctly on the system. Will skip VM host check."
    }
    #endregion

    #region Check VMSwitch readiness
    if ($extSwitchInfo.Count -ge 1)
    {
        # At leas 1 VMSwitch is having the network adapter defined in the management intent
        # Or management intent adapters are not included in any VMSwitch
        [System.String[]] $mgmtIntentAdapterNames = $IntentsInfoFromJson | Where-Object { $_.TrafficType.Contains("Management") } | ForEach-Object { $_.Adapter } | Select-Object -Unique

        [System.Boolean] $foundMgmtVMSwitch = $false
        foreach ($currentSwitchInfo in $extSwitchInfo)
        {
            [System.Guid[]] $currentSwitchAdapterGuids = $currentSwitchInfo | ForEach-Object { $_.NetAdapterInterfaceGuid }
            [System.String[]] $currentSwitchAdapterNames = Get-NetAdapter -Physical | Where-Object { $_.InterfaceGuid -in $currentSwitchAdapterGuids } | ForEach-Object { $_.Name }

            $tempRst = Compare-Object $mgmtIntentAdapterNames $currentSwitchAdapterNames | Where-Object { $_.SideIndicator -eq "<=" } | ForEach-Object { $_.InputObject }
            if ($tempRst.Count -eq 0)
            {
                $foundMgmtVMSwitch = $true
                break
            }
        }

        if ($foundMgmtVMSwitch)
        {
            $interimPassMessage += "`nPASS: At least 1 VMSwitch is having the network adapter defined in the management intent"
        }
        else
        {
            $retVal.Pass = $false
            $retVal.Message += "`nERROR: No VMSwitch is having the network adapter defined in the management intent"
        }
    }
    #endregion

    #Region Check advanced property VlanId on adapters
    foreach ($pNIC in $intentAdapters)
    {
        $currentAdapterAdvancedPropertyVlanId = Get-NetAdapterAdvancedProperty -Name $pNIC -RegistryKeyword VlanId -ErrorAction SilentlyContinue

        if (($null -eq $currentAdapterAdvancedPropertyVlanId) -or ($null -eq $currentAdapterAdvancedPropertyVlanId.RegistryValue))
        {
            $retVal.Pass = $false
            $retVal.Message += "`nERROR: Cannot find valid advanced property VlanId for adapter $pNIC. Use Get-NetAdapterAdvancedProperty/Set-NetAdapterAdvancedProperty with parameter RegistryKeyword set to VlanId to verify and configure it."
        }
    }

    if ($retVal.Pass)
    {
        $interimPassMessage += "`nPASS: Advanced property VlanId exist for all adapters defined in intent"
    }
    #endregion

    #region Check RSS property on adapters
    foreach ($pNIC in $intentAdapters)
    {
        [PSObject[]] $currentAdapterRSSSetting = Get-NetAdapterRss -Name $pNIC -ErrorAction SilentlyContinue

        # Adapter should have RSS property returned
        if (($null -eq $currentAdapterRSSSetting) -or ($currentAdapterRSSSetting.Count -eq 0))
        {
            $retVal.Pass = $false
            $retVal.Message += "`nERROR: Cannot find valid RSS property for adapter $pNIC. Adapter need support RSS. Use Get-NetAdapterRss to verify it."
        } else {
            # Adapter should have RSS enabled field set to some value
            if ([System.String]::IsNullOrEmpty("$($currentAdapterRSSSetting.Enabled)")) {
                $retVal.Pass = $false
                $retVal.Message += "`nERROR: RSS property [Enabled] does not have any value for adapter $pNIC. Please use an adapter that have the property configured as True or False."
            }
        }
    }

    if ($retVal.Pass)
    {
        $interimPassMessage += "`nPASS: RSS property exists for all adapters defined in intent and have valid Enabled property value."
    }
    #endregion

    #region Check pNIC are in the intent adapters
    [System.String[]] $allPhysicalNicUpInSystem = Get-NetAdapter -Physical -Name $intentAdapters -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | ForEach-Object { $_.Name }

    if ($allPhysicalNicUpInSystem.Count -eq 0) {
            $retVal.Pass = $false
            $retVal.Message += "`nERROR: The following adapter(s) are not physical adapter or not Up in the system: $($intentAdapters -join ', '). Intent adapters should be physical adapters and Up in the system."
    } else {
        $adapterCompareResult = Compare-Object $intentAdapters $allPhysicalNicUpInSystem | Where-Object { $_.SideIndicator -eq "<=" } | ForEach-Object { $_.InputObject }
        if ($adapterCompareResult.Count -gt 0)
        {
            $retVal.Pass = $false
            $retVal.Message += "`nERROR: The following adapter(s) are not physical adapter or not Up in the system: $($adapterCompareResult -join ', '). Intent adapters should be physical adapters and Up in the system."
        }
        else
        {
            $interimPassMessage += "`nPASS: All adapters defined in intent are physical NICs and Up in the system"
        }
    }
    #endregion

    #region Check intent adapter should not be used by other intent in the system
    [PSObject[]] $allIntentsOnCurrentMachine = @()
    try
    {
        $allIntentsOnCurrentMachine = Get-NetIntent
    }
    catch
    {
        # Catch here in case NetworkATC service is not installed in the system, in which case should be OK for initial deployment scenario
    }

    if ($allIntentsOnCurrentMachine.Count -gt 0)
    {
        # For each intent to be checked:
        # If intent with same name already defined in the system, we need to make sure that the adapters used are the same
        # If intent with same name not defined in the system, we need to make sure that the adapters used are not used by any other intent in the system

        [System.String[]] $existingIntentAdapterNames = $allIntentsOnCurrentMachine | ForEach-Object { $_.NetAdapterNamesAsList } | Select-Object -Unique

        foreach ($intentToCheck in $IntentsInfoFromJson)
        {
            [PSObject[]] $existingIntentWithSameName = @()

            # Try to get intent with same name
            $existingIntentWithSameName = $allIntentsOnCurrentMachine | Where-Object { $_.IntentName -eq $intentToCheck.Name }

            if ($existingIntentWithSameName.Count -gt 0)
            {
                # if we have intent with same name, then the adapters we used should have same information
                if (Compare-Object -ReferenceObject $intentToCheck.Adapter -DifferenceObject $existingIntentWithSameName.NetAdapterNamesAsList -ErrorAction SilentlyContinue)
                {
                    # The compare returns something, means the adapters are different between the intent passed in and the existing intent on the system: same name, but different adapters.
                    $retVal.Pass = $false
                    $retVal.Message += "`nERROR: Intent $($intentToCheck.Name) is already defined in the system with different adapter(s)."
                    $retVal.Message += "`n       Please use different intent name or remove the existing intent first."
                }
                else
                {
                    $interimPassMessage += "`nPASS: Intent $($intentToCheck.Name) is already defined in the system with same adapter(s)"
                }
            }
            else
            {
                # if we don't have intent with same name, then the adapters for current $intentToCheck should not be used by any existing intent
                $adapterCompareResult = Compare-Object -ReferenceObject $intentToCheck.Adapter -DifferenceObject $existingIntentAdapterNames -IncludeEqual | Where-Object { $_.SideIndicator -eq "==" }

                if ($adapterCompareResult.Count -gt 0)
                {
                    $retVal.Pass = $false
                    $retVal.Message += "`nERROR: The following adapter(s) are already used by other intent in the system: $($adapterCompareResult.InputObject -join ', ')."
                    $retVal.Message += "`n       Intent adapters should not be used by other intent in the system."
                }
                else
                {
                    $interimPassMessage += "`nPASS: Intent $($intentToCheck.Name) adapter(s) are not used by any other intent in the system"
                }
            }
        }
    }
    else
    {
        $interimPassMessage += "`n--- No intent found in the system. Skip intent adapter check."
    }
    #endregion

    $retVal.Message += $interimPassMessage
    return $retVal
}

function GetSortedMgmtIntentAdapter
{
    param
    (
        [System.String[]] $MgmtAdapterNames
    )

    Log-Info "Make sure 1st mgmt intent adapter is the one with valid IP address in it"
    Log-Info "$($MgmtAdapterNames -join ",")"

    # Re-arrange the order in $MgmtAdapterNames to make sure the nic having a valid IPv4 address appears before the other NIC in the array
    $mgmtNicNamesTemp = [System.Collections.ArrayList] $MgmtAdapterNames

    foreach($name in $MgmtAdapterNames)
    {
        $a = Get-NetIPAddress -InterfaceAlias $name -AddressFamily ipv4 -Type Unicast -AddressState Preferred -PrefixOrigin Dhcp -ErrorAction SilentlyContinue
        $b = Get-NetIPAddress -InterfaceAlias $name -AddressFamily ipv4 -Type Unicast -AddressState Preferred -PrefixOrigin Manual -ErrorAction SilentlyContinue
        if (($null -ne $a) -or ($null -ne $b))
        {
            # move the NIC name to the top
            $mgmtNicNamesTemp.Remove($name)
            $mgmtNicNamesTemp.Insert(0, $name)
            break
        }
    }

    [System.String[]] $retVal = [System.String[]] $mgmtNicNamesTemp

    Log-Info "Got sorted adapters list:"
    Log-Info "$($retVal -join ",")"

    return $retVal
}

function CheckStorageAdapterReadiness
{
    param (
        [System.String] $AdapterName,
        [PSObject[]] $AdapterIPAddressOnAllHosts = @()
    )

    Import-Module -Name NetAdapter -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
    Import-Module -Name NetTCPIP -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null

    $retVal = New-Object PSObject -Property @{
        Pass = $true
        AdapterName = $AdapterName
        Failures = ""
    }

    $failureCount = 1
    [PSObject[]] $currentAdapterInfo = Get-NetAdapter -Physical -Name $AdapterName -ErrorAction SilentlyContinue
    if ($currentAdapterInfo.Count -ne 1)
    {
        $retVal.Pass = $false
        $retVal.Failures += " $failureCount) Expected [ 1 ] adapter with name [ $AdapterName ]. But found [ $($currentAdapterInfo.Count) ]."
        $failureCount++
    }
    else
    {
        [PSObject[]] $currentAdapterIPAddressInfo = @()
        if ($AdapterIPAddressOnAllHosts.Count -gt 0) {
            $tmpAdapterIP = $AdapterIPAddressOnAllHosts | Where-Object { $_.PhysicalNode -eq $env:COMPUTERNAME }
            $currentAdapterIPAddressInfo = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $currentAdapterInfo.InterfaceIndex -IPAddress $tmpAdapterIP -PrefixOrigin "Manual"  -ErrorAction SilentlyContinue
        } else {
            $currentAdapterIPAddressInfo = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $currentAdapterInfo.InterfaceIndex -PrefixOrigin @("Dhcp", "Manual") -ErrorAction SilentlyContinue
        }

        [System.Boolean] $validIPConfiguration = $false

        switch ($currentAdapterIPAddressInfo.Count) {
            0 {
                # Should be fine if customer did not configure any IP address on the physical adapter
                $validIPConfiguration = $true
            }
            1 {
                # Should be fine only if 1 IP address on the physical adapter, and customer provided the same customized IP address
                if ($AdapterIPAddressOnAllHosts.Count -gt 0) {
                    if ($currentAdapterIPAddressInfo[0].IPAddress -ne $tmpAdapterIP) {
                        $validIPConfiguration = $false
                    } else {
                        $validIPConfiguration = $true
                    }
                } else {
                    # Customer not using customized IP address, so we will consider it as invalid configuration
                    $validIPConfiguration = $false
                }
            }
            Default {
                $validIPConfiguration = $false
            }
        }

        if (-not $validIPConfiguration) {
            $retVal.Pass = $false
            $ipList = $currentAdapterIPAddressInfo | ForEach-Object { $_.IPAddress } | Where-Object { $_ } | Sort-Object | Select-Object -Unique
            $ipListString = $ipList -join ", "
            $retVal.Failures += " $failureCount) Adapter has the following IP address(es) configured: [ $ipListString ]. The Storage adapter should not have any Manual/DHCP IP addresses configured and DHCP should be disabled."
            $failureCount++
        }

        [String[]] $currentAdapterVlanInfo = (Get-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword VLANID -ErrorAction SilentlyContinue).RegistryValue

        if (-not $currentAdapterVlanInfo)
        {
            $retVal.Pass = $false
            $retVal.Failures += " $failureCount) Adapter does not support VLANID. The Storage adapter should support VLANID."
            $failureCount++
        }
        else
        {
            if (($currentAdapterVlanInfo.Count -gt 1) -or ($currentAdapterVlanInfo[0] -ne "0"))
            {
                $retVal.Pass = $false
                $retVal.Failures += " $failureCount) Adapter has the following VLANID configured: [ $($currentAdapterVlanInfo) ]. The Storage adapter should support VLANID, but not have a value configured."
                $failureCount++
            }
        }

        [PSObject[]] $tmpRouteInfo = Get-NetRoute -InterfaceIndex $currentAdapterInfo.InterfaceIndex -DestinationPrefix 0.0.0.0/0 -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($tmpRouteInfo) {
            # If we have a default route configured on the adapter, it is not a valid storage adapter configuration
            $retVal.Pass = $false
            $retVal.Failures += " $failureCount) Storage adapter has default route configured: [ $($tmpRouteInfo.NextHop -join ", ") ]. The storage adapter should not have a default route configured."
            $failureCount++
        }
    }

    $retval.Failures = $retVal.Failures.TrimStart()
    return $retVal
}

function CheckStorageAdapterIPConfig {
    param (
        [String[]] $StorageAdaptersToCheck,
        $EnvValidatorNwkLibConvertIPAddressToIntFunction,
        $EnvValidatorNwkLibConvertIntToIPAddressStringFunction,
        $EnvValidatorNwkLibGetNetworkAddressFunction,
        $EnvValidatorNwkLibNormalizeIPv4SubnetFunction
    )

    Import-Module -Name NetTCPIP -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path "Function:\EnvValidatorNwkLibConvertIPAddressToInt" -Value $EnvValidatorNwkLibConvertIPAddressToIntFunction -Force | Out-Null
    New-Item -Path "Function:\EnvValidatorNwkLibConvertIntToIPAddressString" -Value $EnvValidatorNwkLibConvertIntToIPAddressStringFunction -Force | Out-Null
    New-Item -Path "Function:\EnvValidatorNwkLibGetNetworkAddress" -Value $EnvValidatorNwkLibGetNetworkAddressFunction -Force | Out-Null
    New-Item -Path "Function:\EnvValidatorNwkLibNormalizeIPv4Subnet" -Value $EnvValidatorNwkLibNormalizeIPv4SubnetFunction -Force | Out-Null

    $retVal = New-Object PSObject -Property @{
        Pass = $true
        Message = "Storage adapter IP configuration check on $($ENV:COMPUTERNAME)"
    }

    foreach ($expectedAdapter in $StorageAdaptersToCheck) {
        [PSObject[]] $currentAdapterIPAddressInfo = Get-NetIPaddress -InterfaceAlias $expectedAdapter -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue

        if ($currentAdapterIPAddressInfo.Count -eq 1) {
            $retVal.Message += "`n    Passed: Storage adapter [ $expectedAdapter ] have one and only one valid IPv4 defined on it."
        } elseif ($currentAdapterIPAddressInfo.Count -eq 0) {
            $retVal.Pass = $false
            $retVal.Message += "`n    !! Expect one valid IPv4 address configured on storage adapter [ $($expectedAdapter) ]."
            $retVal.Message += "`n    !! Please run below command to confirm:"
            $retVal.Message += "`n    !!     Get-NetIPaddress -InterfaceAlias $($expectedAdapter) -AddressFamily IPv4 -PrefixOrigin Manual"
        } else {
            # Multiple IP address found on the adapter, we need to make sure that all the IP are in same subnet
            [System.String] $expectedIpSubnet = ""

            foreach ($currentIp in $currentAdapterIPAddressInfo) {
                [System.String] $currentCidr = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$($currentIp.IPAddress)/$($currentIp.PrefixLength)"

                if ([System.String]::IsNullOrEmpty($expectedIpSubnet)) {
                    $expectedIpSubnet = $currentCidr
                } else {
                    if ($expectedIpSubnet -ne $currentCidr) {
                        $retVal.Pass = $false
                        $retVal.Message += "`n    !! Expect all IP address on storage adapter [ $($expectedAdapter) ] to be in same subnet."
                        $retVal.Message += "`n    !! But found [ $($currentCidr) ] and [ $expectedIpSubnet ]."
                        $retVal.Message += "`n    !!   Get-NetIPaddress -InterfaceAlias $($expectedAdapter) -AddressFamily IPv4 -PrefixOrigin Manual"
                    } else {
                        $retVal.Message += "`n    Passed: Storage adapter [ $expectedAdapter ] have multiple valid IPv4 address(es) [ $($currentIp.IPAddress) ] configured on it. All in same subnet [ $($currentCidr) ]."
                    }
                }
            }
        }
    }

    return $retVal
}

function CheckIntentConfigurationReadiness
{
    param (
        [PSObject[]] $IntentsInfoFromJson,
        [System.String] $OperationType
    )

    enum NetworkDirectEnabledState { Disabled = 0; Enabled = 1 }
    enum NetworkDirectTechnologyState { iWARP = 1; RoCE = 3; RoCEv2 = 4 }

    $nodeName = $env:COMPUTERNAME
    $retVal = New-Object PSObject -Property @{
        Pass = $true
        Message = "on $($nodeName)"
    }

    [PSObject[]] $allAdapterAdvancedPropertyInfo = Get-NetAdapterAdvancedProperty

    [System.Boolean] $currentIntentPass = $true
    foreach ($currentIntent in $IntentsInfoFromJson)
    {
        $currentIntentPass = $true

        $retVal.Message += "`n--- Check intent $($currentIntent.Name):"

        # Check network direct technology is supported by the adapter if user choose to override
        if ($currentIntent.overrideAdapterProperty -eq $true)
        {
            [NetworkDirectEnabledState] $currentIntentNetworkDirectOverride = [NetworkDirectEnabledState]::Disabled

            [System.Boolean] $networkDirectConfigured = -not ([System.String]::IsNullOrEmpty($currentIntent.AdapterPropertyOverrides.NetworkDirect))

            if ($networkDirectConfigured)
            {
                # Only check below if the NetworkDirect property is set.
                # If it is not set by end user then the value read from the input JSON could be either "" or $null
                try
                {
                    $currentIntentNetworkDirectOverride = [NetworkDirectEnabledState] $currentIntent.AdapterPropertyOverrides.NetworkDirect
                }
                catch
                {
                    $retVal.Pass = $false
                    $currentIntentPass = $false
                    $retVal.Message += "`n---    !!! Invalid NetworkDirect string $($currentIntent.AdapterPropertyOverrides.NetworkDirect) defined: use `"Enabled`" or `"Disabled`""
                }
            }
            else
            {
                $retVal.Message += "`n---    NetworkDirect not configured"
            }

            if ($currentIntentPass)
            {
                if ($networkDirectConfigured -and ($currentIntentNetworkDirectOverride -eq [NetworkDirectEnabledState]::Enabled))
                {
                    $retVal.Message += "`n---    NetworkDirect: Enabled"

                    # In Add-Server/Repair-Server, or PnU scenarios, it is possible that NetworkATC put the NetworkDirectTechnology field
                    # in intent to null/empty - so it will use default value that adapter supports - we don't need to check it if that is
                    # the case.
                    # So we only check technology string if:
                    # - Deployment scenario, or
                    # - Non-Deployment scenario, and the "NetworkDirectTechnology" read from system intent is not null or empty
                    [System.Boolean] $shouldCheckTechnology = ($OperationType -eq "Deployment") -or (-not [System.String]::IsNullOrEmpty($currentIntent.adapterPropertyOverrides.NetworkDirectTechnology))

                    if ($shouldCheckTechnology) {
                        try
                        {
                            [System.String] $intentNetworkDirectTechnology = [System.String] [NetworkDirectTechnologyState] $currentIntent.adapterPropertyOverrides.NetworkDirectTechnology
                        }
                        catch
                        {
                            $retVal.Pass = $false
                            $currentIntentPass = $false
                            $retVal.Message += "`n---    !!! Invalid NetworkDirectTechnology string $($currentIntent.adapterPropertyOverrides.NetworkDirectTechnology) defined while NetworkDirect enabled: use `"iWARP`", `"RoCE`" or `"RoCEv2`""
                        }
                    }

                    if ($currentIntentPass)
                    {
                        [System.String[]] $adaptersToCheck = $currentIntent.Adapter

                        foreach ($currentAdapter in $adaptersToCheck)
                        {
                            [PSObject] $adapterNetworkDirectTechnologyInfo = $allAdapterAdvancedPropertyInfo | Where-Object { $_.Name -eq $currentAdapter -and $_.RegistryKeyword -eq "*NetworkDirectTechnology" }

                            [System.String[]] $adapterSupportedNetworkDirectTechnology = $adapterNetworkDirectTechnologyInfo.ValidDisplayValues
                            if ($intentNetworkDirectTechnology -in $adapterSupportedNetworkDirectTechnology)
                            {
                                $retVal.Message += "`n---    NetworkDirect technology $($intentNetworkDirectTechnology) supported by adapter $($currentAdapter)"
                            }
                            else
                            {
                                $retVal.Pass = $false
                                $retVal.Message += "`n---    !!! NetworkDirect technology $($intentNetworkDirectTechnology) NOT supported by adapter $($currentAdapter)"
                            }
                        }
                    }
                }
                else
                {
                    # Intent NetworkDirect disabled
                    $retVal.Message += "`n---    NetworkDirect not configured or Disabled. Skip NetworkDirectTechnology checking."
                }
            }
        }
        else
        {
            # In case of no override, we just skip the checking for this intent
            $retVal.Message += "`n--- Adapter property override for intent $($currentIntent.Name) not configured. Skip adapter override property checking."
        }
    }

    if ($retVal.Pass)
    {
        $retVal.Message = "`nPASS: Network intent configuration checking " + $retVal.Message
    }
    else
    {
        $retVal.Message = "`nERROR: Network intent configuration checking " + $retVal.Message
    }

    return $retVal
}

function InvokeRemoteCommandWithSessionId {
    param (
        [Parameter(Mandatory=$true)]
        [System.Int64] $TestSessionId,
        [ScriptBlock] $ScriptToExecute,
        [PSObject[]] $Arguments
    )
    $testSession = Get-PSSession -Id $TestSessionId
    if ($PSBoundParameters.ContainsKey("Arguments")) {
        return Microsoft.PowerShell.Core\Invoke-Command -Session $testSession -ScriptBlock $ScriptToExecute -ArgumentList $Arguments -ErrorAction Stop
    } else {
        return Microsoft.PowerShell.Core\Invoke-Command -Session $testSession -ScriptBlock $ScriptToExecute -ErrorAction Stop
    }
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCi0G0oEQdS2Pha
# aTX4b49krT3VB+mokoUiMmSFE5Rnj6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEINzEfRZN
# iEySAdQpMTqJXvBxjx3Dhv3DDQd9BJErz8VYMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAbNwheeS0Uk6FaKXyL5ICBrfL0QPFu/dYZ1p9M+u6
# 57eKRReeV+GNA8hR2FqS+RGq3j/GtbezgtjQ3lAxLw3QkMDNwjT1fdMokNbrRMMD
# 6D7oKLCycZef0iG4VfdCgBhLsZZsI2IkHCD+z23TEY899jlogK5hBIQoxxxCTkV7
# PlKISDtBo32qMmKhHIj+7xgLeZfISVMERyfT2KcyQSErPRAlSwL1n3Ulu982UMa5
# t+6eVpRz9es74LhLWGiTa+y7JpLwr/jftliRQZhJVD0clmjxDbqhHInEOaZLv585
# HqGcOEauzg69xrMs8m4RGJzhHp8lWu2XB6v4nnPMKcDtNqGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCA+NxIMtsio41m5E2pbIdenH0s/yBObMUJK4v8J
# lNpgLAIGaeegqJ36GBMyMDI2MDUwMzE0MzEwOS45NjFaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046N0YwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAh6jrKRuOW98SQABAAAC
# HjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NDlaFw0yNzA1MTcxOTM5NDlaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0YwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCl0TjtbDwsR7Fe8ac6ol5s1zht
# Tqd2AWpchQhLp9G5mmSM23N5fyQGCQ1D06rOA3PgXKF+76vXvOCs2VsLv1owj4mH
# EyEqiq8GJ5yC+/QNYRpZPA8e7OgekzDO6S/4vy/jTMYbp3rhuFiKKCzTWOQtdFcF
# +D0k369I7pm/E07SyNMGkuNd5lj5SJ91UqFuZfjMB6cQ2wh77mtiRUVdj53yjdNq
# j+GQl+Yaz29Bjrzn7U1ln+JpLlnb0xdGmZoIPKZbwBVcWtyL4uyhML7SSTmiOfWX
# U+g+yNl0CdoLGL8LtWHEi8FsuTPeSdSqmeMrvLaEmibTVTS4vQQY8NPnb6uI5y6i
# NV9vBFcm8LU/lDTjGTqPa7UBT4gdf5Jm3wYrfCFZ4P/j5MoqT0JONca50jt4TGI9
# 0SihXaDEYqk23S0IJZ3UkUpukDRTjK713BIykffxyBqMeQqfO0zvWfUx7BrmUpug
# Qcw99+DxLl2gf+uQEpRmnlbrVJ9dvW9ds4fqEPN2jG0QwF1PBSglNcV1SpqZKitQ
# gBGSwu/82AKztoCHwYRHRNwzwTVe/1KNTvmqAd4Uges4ywOH02haagT8wYY8OdWd
# jKn3k052w+kmc0UC0F+iVXTGZIMxvo9iBZQoXehzRtWJ/VOtKvCyS3csKzN7rStW
# JwjSWz6dtOf0l+ytLQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFOYKFprqBB0JZmJc
# FC4cPPmeF4JkMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCkoZB5NnJVFb5wKejR
# onk518a2TBNYpKcBMtfL6BS0ARaABOMGYLlPNuhI1HwmelP9hX3oq3TaEm/cDkkz
# NQAzDedPgoRI2R7+8poNSWvHXEAs7SZODm9x7KqlBkNZM9ex4XY1yNmVOAmWDjRr
# 7jKjaiQbntf7EC4GNikxGGaVWOjfYt3Q9X0r/Ks8KBlbzDR9zjA/TCctR4co1WpU
# 1ZRLFrB9bl8dRxsbnyT2qQ41E7dT12R30eIGUziEs5GN+26V/ovXOi20dJiM13hY
# Wvy1NNJAhkKOlLB1ONund6ffhPdUcHWsu8V+lR0aakMV64HqDbLumZrCNwUofVx3
# xMk8F4tCYJtQxLTywc30sZAD1S2sC1959x6KixA+p41FLUl8g64oHy3bfYnH5xd4
# JOBgQoaqndGjcctxr+8EknjhKyrgAzrTcKLJbUezgoye8brCLJ+y6PAoEjpXRkSY
# AU8wfQ3YWRck6ALwoV7Uin8+rpGQSbXhF6c1dTFakXmChClud4IADY/t6JRkJ+06
# FzL+jDd8KLV8Qj77JfiuTiPIG5G/xlnGoZFcX+yyBtDvzZE48d+Y+HYUd/cvhH1F
# Kl7AH+5AyotqJSFmvM/BuYRx2B20asVXilV2k2JbNO3LGCz3Q+dpElzwsfJrka1N
# /getma7fWpowsNvoIaEQvjad8TCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdGMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCD/QNkKDIW4VIF7j3oi2qbrR0a/6CBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFGjDAiGA8y
# MDI2MDUwMzAzNTkwOFoYDzIwMjYwNTA0MDM1OTA4WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoUaMAgEAMAoCAQACAhMyAgH/MAcCAQACAhMQMAoCBQDtopgMAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAAVi9xvlOh955n1ik5D1kDjxW5FS
# jTmAe2i5ti6Xo0Q8nen2zRj2DZiWYlmUxCXO+wcwd01IsjU0N1lo3LHT7+My0gjS
# WKdhsyj0t49HrZf479uUNdo4iK5OxxmLXEiDNc+nmrmp5PVME6eXxoA3kyhqace3
# ctTktUSzrD3GU+S3M2Lr/8B3g8ckRgnMEw55oPr9c5PIZYs6DpLjUbEmqrICkkf2
# Xf+kHVJF1isU6mmlcnvll7lhPAW6QCILPaKSb5ZEnLE3kTvhpZFTfVFxEyy1cNof
# 6rCDf8+5OC+BADB16rc7SWr1xf4t8qU9jcpWemVXnDqLBSo/CThYlr++Y2UxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh6j
# rKRuOW98SQABAAACHjANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCMepw/Vh0pMWVvCuBDGxHVZwCD
# 1txvwRDgV1l5RaTHSjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIC+BXWrz
# 9geMgM8Bvn8bqxHjhHXJ29EBizITIw0B9vOCMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIeo6ykbjlvfEkAAQAAAh4wIgQgJ1jdQD+0
# szm+d0/kpKtiIuKHE8oW2d9Vtqy9flj8PCswDQYJKoZIhvcNAQELBQAEggIAhENb
# 0D0YLr2Y85ATqz6fcbwVWfG6I+oEiV2uK7Y9rKCdv81BGgwEMDZTsLNo57fVPcel
# xf0lVdpEPMDaJWn2MuL0R36ABrRfl3iKNdbL+Qx6ShtKLiG6WBG7Zhm47AFYNuxV
# Wx2dGihMcbcYuUsE+kEXD3zGApRw0ze1bG3nGwM4aN+EwBkzdxl0fAOBCj8TLk3P
# sffXzSs7veTylEVh3YR+Ra04vKfR6G4qJC208etk7pXo6FPuHPay3rITRYhromYU
# N/aVWetcNb8afTyiV+TUpUJk3FlejjCpAK0KICNdQCYC2wS86F+MoV/f23E130c4
# XWFZllIg8d8tDXjx8Qm7x5AUNR9GenWx10vAGN9Qh5XTupaYf/HtPSZevAK34pfX
# DbO6uSDNcwYIrA12tup58WKsBt9TUSnEmMo/XPdOyy3yRN7NJ9Bkboj6QI/D9/iq
# hnYJB4Pf6zRgbBtEajbWR1AYBMGVd0P3A2xLh6mO/lEc6+BbgDbWrgGuoCTkYW+b
# tvtbEwJWVjMcCHGwWJREBmZeglkSuC0Cwi2Y3hg2fJ0vQqkGwoNm03i/LwGjPXAL
# B1+Wd1v/rDuz1DASK4fi4cIGfsABcMiCEenyQK+BGoM+iCIw25cmZdSr7sD5AMH3
# Mcbhxum3CNSpnQZkOuGr9Up8p+UGKQd2TSIL94I=
# SIG # End signature block
