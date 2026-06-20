<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

Import-LocalizedData -BindingVariable lnTxt -FileName AzureLocal.NetworkInfraConnection.Strings.psd1
Import-Module $PSScriptRoot\..\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -DisableNameChecking -Global | Out-Null

Import-Module -Name DnsClient -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name Hyper-V -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name NetAdapter -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name NetTCPIP -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null
Import-Module -Name ServerManager -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null

#################################################################################################
# NetworkInfraConnection Validators
#   - Test-NwkInfraConnectionValidator_InfraIpPoolConnection
#
#################################################################################################
function Test-NwkInfraConnectionValidator_InfraIpPoolConnection
{
    <#  .SYNOPSIS
        Validate the connectivity from infra IP pool to DNS server and public endpoints required by Azure Local cluster
        .DESCRIPTION
        Validate the connectivity from infra IP pool to DNS server and public endpoints required by Azure Local cluster
        .PARAMETER AtcHostIntents
        The ATC host intents configuration provided by customer in the deployment json
        .PARAMETER IpPools
        The IP pools configuration provided by customer in the deployment json
        .PARAMETER ProxyEnabled
        If proxy is enabled on the host
        .PARAMETER RegionName
        The region name of the Azure Local cluster
        .PARAMETER TimeoutWaitForIPInSeconds
        The timeout in seconds to wait for an IP to be ready on the test vNIC created. Default to 60 seconds
        .EXAMPLE
        PS C:\> Test-NwkInfraConnectionValidator_InfraIpPoolConnection -AtcHostIntents $atcHostIntents -IpPools $ipPools -ProxyEnabled $true -RegionName "AzureLocal"
        Validate the connectivity from infra IP pool to DNS server and public endpoints required by Azure Local cluster
        .NOTES
    #>
    [CmdletBinding()]
    param (
        [PSObject[]] $AtcHostIntents,
        [System.Collections.ArrayList] $IpPools,
        [System.Boolean] $ProxyEnabled = $false,
        [System.String] $RegionName = "",
        [System.Int16] $TimeoutWaitForIPInSeconds = 180
    )

    try {
        $instanceResults = @()

        #region check infra IP connection
        # A new vSwitch and management vNIC is created using Network ATC naming standards. The vSwitch is created using
        # the intents configuration provided by the customer in the deployment json. We will rotate the vNIC IP with the
        # infra IPs to be tested. Whatever is the Mgmt intent, we will create the vSwitch using the selected pNICs from
        # the customer. curl.exe tool seems to provide the solution to test from specific source IP and allows to check
        # TCP ports and also URLs. Only the first 9 IPs from the infra range will be tested.
        # DNS registration must be disabled on vNIC that is used to test the infra IPs

        Log-Info "Validator: Test-NwkInfraConnectionValidator_InfraIpPoolConnection"

        $infraIPRangeToValidate = EnvValidatorNwkLibGetMgmtIpRangeFromPools -IpPools $IpPools

        if ($ProxyEnabled) {
            Log-Info "Proxy is enabled on the host. Will check public endpoint connection via proxy."
        } else {
            Log-Info "Proxy is not enabled on the host. Will check public endpoint connection directly."
        }

        if ((Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) -and (Get-WindowsFeature -Name "Hyper-V" -ErrorAction SilentlyContinue).Installed) {
            [PSObject[]] $mgmtIntent = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Management") }
            [System.String] $mgmtIntentName = $mgmtIntent[0].Name
            Log-Info "Got management intent name: $($mgmtIntentName)"
            Log-Info "Make sure 1st mgmt intent adapter is the one with valid IP address on it"
            [System.String[]] $mgmtAdapters = EnvValidatorNwkLibGetSortedMgmtIntentAdapter -MgmtAdapterNames $mgmtIntent[0].Adapter
            Log-Info "Got sorted adapters list for management intent: $($mgmtAdapters -join ", ")"

            # The mgmt adapter name used for validation
            [System.String] $mgmtAdapterAlias = "vManagement($($MgmtIntentName))"

            [System.Guid[]] $intentAdapterGuids = (Get-NetAdapter -Name $mgmtAdapters -Physical -ErrorAction SilentlyContinue).InterfaceGuid
            Log-Info "Got adapter GUID list from system: $($intentAdapterGuids -join ", ")"

            try {
                $needCleanUpVMSwitch = $false
                $mgmtVlanIdToRestore = 0

                #region prepare VMSwitch for testing infra IP connection
                [PSObject[]] $allExistingVMSwitches = Get-VMSwitch -SwitchType External
                $externalVMSwitchesCount = $allExistingVMSwitches.Count

                [PSObject] $foundVMSwitchToUse = $null

                if ($externalVMSwitchesCount -eq 0) {
                    # if we found 0 VMSwitch, we will need to create one for this testing
                    # Note that this operation will have the host disconnected from network for a moment (due to VMSwitch/vNIC creation)
                    # Since the code is executed locally, this disconnection should not affect the execution
                    Log-Info "No VMSwitch exists in system. Will create VMSwitch for testing of infra IP connection."
                    $tmpVMSwitchConfigInfo = EnvValidatorNwkLibConfigureVMSwitchForTesting -SwitchAdapterNames $mgmtAdapters -MgmtIntentName $mgmtIntentName -ExpectedMgmtVNicName $mgmtAdapterAlias
                    $foundVMSwitchToUse = $tmpVMSwitchConfigInfo.VMSwitchInfo
                    $needCleanUpVMSwitch = $tmpVMSwitchConfigInfo.NeedCleanUp
                    $mgmtVlanIdToRestore = $tmpVMSwitchConfigInfo.MgmtVlanId

                    if (-not $tmpVMSwitchConfigInfo.IPReady) {
                        Log-Info "Cannot get a VMSwitch ready on $($env:COMPUTERNAME) with valid IP on the vNIC created. Fail the validation"
                        throw "Cannot get a VMSwitch ready on $($env:COMPUTERNAME) with valid IP on the vNIC created. Fail the validation"
                    } else {
                        Log-info "Test VMSwitch [ $($foundVMSwitchToUse.Name) ] ready on $($env:COMPUTERNAME) with valid IP on the vNIC created."
                    }

                } else {
                    # if we found at least 1 VMSwitch in the system, we then need to check
                    #       If there is one VMSwitch that has the same mgmt intent adapters
                    Log-info "Found $($externalVMSwitchesCount) VMSwitch in the system. Need to check if a valid one could be used for validation."

                    foreach ($externalVMSwitch in $allExistingVMSwitches) {
                        # Need to check the switch is good for deployment: using same adapter as the intent
                        [System.Guid[]] $switchAdapterGuids = $externalVMSwitch.NetAdapterInterfaceGuid

                        if (Compare-Object -ReferenceObject $switchAdapterGuids -DifferenceObject $intentAdapterGuids) {
                            # Adapters used in pre-defined VMSwitch and the intent are different. Ignore that VMSwitch
                            Log-Info "Found $($externalVMSwitch.Name) with different adapters than the mgmt intent. Skip it."
                        } else {
                            # if the system already have a VMSwitch with the same mgmt adapters in its teaming, we will just use that adapter
                            $foundVMSwitchToUse = $externalVMSwitch
                            break
                        }
                    }

                    if (-not $foundVMSwitchToUse) {
                        Log-info "No valid VMSwitch found! Check if we could create a new VMSwitch for validation."

                        # At this moment, we need further checking:
                        #       If all adapters in the mgmt intent is not used by any adapter, we will need to create a new VMSwitch
                        #       If any of the adapter in the mgmt intent is used by any adapter, we will need to error out as this is not a supported scenario
                        [System.Guid[]] $allSwitchAdapterGuids = $allExistingVMSwitches.NetAdapterInterfaceGuid

                        [System.Boolean] $intentAdapterAlreadyUsed = $false
                        foreach ($tmpAdapterGuid in $intentAdapterGuids) {
                            if ($allSwitchAdapterGuids.Contains($tmpAdapterGuid)) {
                                $intentAdapterAlreadyUsed = $true
                                break
                            }
                        }

                        if (-not $intentAdapterAlreadyUsed) {
                            # if none of the adapter in the mgmt intent is used by any adapter, we will create a new VMSwitch
                            Log-Info "VMSwitch found, but no VMSwitch mgmt adapters in the system. Will create VMSwitch for testing infra IP connection."
                            $tmpVMSwitchConfigInfo = EnvValidatorNwkLibConfigureVMSwitchForTesting -SwitchAdapterNames $mgmtAdapters -MgmtIntentName $mgmtIntentName
                            $foundVMSwitchToUse = $tmpVMSwitchConfigInfo.VMSwitchInfo
                            $needCleanUpVMSwitch = $tmpVMSwitchConfigInfo.NeedCleanUp
                            $mgmtVlanIdToRestore = $tmpVMSwitchConfigInfo.MgmtVlanId

                            if (-not $tmpVMSwitchConfigInfo.IPReady) {
                                Log-Info "Cannot get a VMSwitch ready on $($env:COMPUTERNAME) with valid IP on the vNIC created. Fail the validation"
                                throw "Cannot get a VMSwitch ready on $($env:COMPUTERNAME) with valid IP on the vNIC created. Fail the validation"
                            }
                        } else {
                            # This is an error situation: some of the mgmt intent adapters is already used by an existing VMSwitch, some other mgmt
                            # intent adapter is still "free" in the system. We don't know what to do with this, so need to error out
                            Log-Info "VMSwitch found, mgmt adapter list is not matching to any VMSwitch adapter list. Wrong configuration. Will to fail the validation"
                        }
                    }
                }
                #endregion

                # Initialize to empty array to prevent null parameter errors
                $allPublicEndpointServicesToCheck = @()

                if ($RegionName -eq "AzureLocal") {

                    $allPublicEndpointServicesToCheck = Get-AzStackHciConnectivityTarget -LocalOnly:$true -RegionName $RegionName | Where-Object { $_.Name -Like "Azure_Kubernetes_Service_*" -or $_.Name -Like "AzStackHci_MOCStack_*" -or $_.Name -Like "Vm_Management_HCI_*" }
                }
                elseif (Get-RegionIsUSSecOrUSNat -RegionName $RegionName) {
                    Log-Info "Do not check public endpoint services for USNet/USSec $RegionName region."
                }
                else {
                    $allPublicEndpointServicesToCheck = Get-AzStackHciConnectivityTarget -RegionName $RegionName | Where-Object { $_.Name -Like "Azure_Kubernetes_Service_*" -or $_.Name -Like "AzStackHci_MOCStack_*" -or $_.Name -Like "Vm_Management_HCI_*" }
                }

                if ($foundVMSwitchToUse) {
                    Log-Info "Use VMSwitch $($foundVMSwitchToUse.Name) to validate infra IP connection. Start the validation..."
                    Log-Info "Mgmt adapter $($mgmtAdapterAlias) should exist in the system"

                    [System.String[]] $physicalAdapterNamesInVMSwitch = @()
                    [System.Guid[]] $physicalAdapterGuidsInVMSwitch = $foundVMSwitchToUse.NetAdapterInterfaceGuid
                    foreach ($tmpGuid in $physicalAdapterGuidsInVMSwitch) {
                        Log-Info "    >> Adapter GUID in VMSwitch: $($tmpGuid)"
                        $physicalAdapterNamesInVMSwitch += (Get-NetAdapter | Where-Object { $_.InterfaceGuid -like "{$($tmpGuid)}" }).Name
                    }

                    [PSObject[]] $mgmtAdapterIP = Get-NetIPAddress -InterfaceAlias $mgmtAdapterAlias -ErrorAction SilentlyContinue | Where-Object { ($_.PrefixOrigin -eq "Manual" -or $_.PrefixOrigin -eq "Dhcp") -and $_.AddressFamily -eq "IPv4" -and $_.AddressState -eq "Preferred" }

                    if ($mgmtAdapterIP -and $mgmtAdapterIP.Count -gt 0) {
                        $prefixLength = $mgmtAdapterIP[0].PrefixLength[0]
                        $mgmtIPConfig = Get-NetIPConfiguration -InterfaceAlias $mgmtAdapterAlias
                        $defaultGateway = $mgmtIPconfig.IPv4DefaultGateway[0].NextHop

                        # Try to get DNS server IP from running system
                        [PSObject[]] $getDNSServers = Get-DnsClientServerAddress -InterfaceAlias $mgmtAdapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue

                        if ($getDNSServers -and ($getDNSServers.Count -gt 0) -and ($getDNSServers[0].ServerAddresses.Count -gt 0)) {
                            # Get up to 3 DNS servers to check
                            [System.String[]] $dnsServersIPToCheck = $getDNSServers[0].ServerAddresses[0..2]

                            try {
                                #region configure vNIC for testing infra IP connection
                                $tmpGuid = [System.Guid]::NewGuid()
                                $newVNICName = "TestVirtualNIC$($tmpGuid)"

                                Log-Info "Prepare vNIC $($newVNICName) on the VMSwitch for infra IP connection validation"

                                if (Get-VMNetworkAdapter -ManagementOS -Name $newVNICName -ErrorAction SilentlyContinue) {
                                    Remove-VMNetworkAdapter -ManagementOS -SwitchName $foundVMSwitchToUse.Name -Name $newVNICName -Confirm:$false
                                }

                                Add-VMNetworkAdapter -ManagementOS -SwitchName $foundVMSwitchToUse.Name -Name $newVNICName
                                [PSObject[]] $adapterToBeRenamed = Get-NetAdapter -name "vEthernet ($($newVNICName))" -ErrorAction SilentlyContinue
                                if ($adapterToBeRenamed.Count -eq 1) {
                                    Rename-NetAdapter -NewName $newVNICName -Name "vEthernet ($($newVNICName))" -ErrorAction SilentlyContinue
                                } else {
                                    Log-Info "Cannot find the vNIC created on VMSwitch $($foundVMSwitchToUse.Name). Fail the validation"
                                    throw "Cannot find the vNIC created on VMSwitch $($foundVMSwitchToUse.Name). Fail the validation"
                                }

                                Log-Info "Set -RegisterThisConnectionsAddress on test vNIC $($newVNICName) to false"
                                Set-DnsClient -InterfaceAlias $newVNICName -RegisterThisConnectionsAddress $false

                                #region Set DefaultIsolationID on the vNIC
                                $tempDefaultIsolationIdToSet = 0
                                # There is a possibility that the mgmt VMNetworkAdapter is not there
                                # (NOTE: we have the validation in Test-NwkValidator_AdapterDriverMgmtAdapterReadiness, however if the result failed there, the current test will still run.
                                # So there is a chance that below call will throw exception out if we do not specify -ErrorAction SilentlyContinue)
                                $tempVMNetworkAdapterIsolation = Get-VMNetworkAdapterIsolation -ManagementOS -VMNetworkAdapterName $mgmtAdapterAlias -ErrorAction SilentlyContinue
                                if ($tempVMNetworkAdapterIsolation -and $tempVMNetworkAdapterIsolation.DefaultIsolationID -ne 0) {
                                    $tempDefaultIsolationIdToSet = $tempVMNetworkAdapterIsolation.DefaultIsolationID
                                }

                                # In case adapter is pre-created and configured with VMNetworkAdapterVlan for the VLANID (likely in Upgrade scenario)
                                $tempVMNetworkAdapterVlanId = 0
                                $tempVMNetworkAdapterVlanConfiguration = Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $mgmtAdapterAlias -ErrorAction SilentlyContinue
                                if ($tempVMNetworkAdapterVlanConfiguration) {
                                    $tempVlanMode = $tempVMNetworkAdapterVlanConfiguration.OperationMode
                                    if ($tempVlanMode -eq "Untagged") {
                                        Log-Info "No VLANID configured with VMNetworkAdapterVlan - Untagged mode"
                                    } elseif ($tempVlanMode -eq "Trunk") {
                                        # In trunk mode, we will just use the first VLAN ID in the AllowedVlanIdList
                                        if ($tempVMNetworkAdapterVlanConfiguration.AllowedVlanIdList -and $tempVMNetworkAdapterVlanConfiguration.AllowedVlanIdList.Count -gt 0) {
                                            $tempVMNetworkAdapterVlanId = $tempVMNetworkAdapterVlanConfiguration.AllowedVlanIdList[0]
                                            Log-Info "VLANID configured with VMNetworkAdapterVlan - Trunk mode"
                                        } else {
                                            throw "VMNetworkAdapter $mgmtAdapterAlias configured with Trunk mode, but no AllowedVlanIdList found"
                                        }
                                    } elseif ($tempVlanMode -eq "Access") {
                                        # In native mode, we will just use the Native VLAN ID
                                        $tempVMNetworkAdapterVlanId = $tempVMNetworkAdapterVlanConfiguration.NativeVlanId
                                        Log-Info "VLANID configured with VMNetworkAdapterVlan - Access mode"
                                    }
                                }

                                if ((-not $tempDefaultIsolationIdToSet) -and $tempVMNetworkAdapterVlanId) {
                                    Log-Info "Will use VLANID configured with VMNetworkAdapterVlan on mgmt adapter $($mgmtAdapterAlias): $($tempVMNetworkAdapterVlanId)"
                                    $tempDefaultIsolationIdToSet = $tempVMNetworkAdapterVlanId
                                }

                                if ($tempDefaultIsolationIdToSet) {
                                    Log-Info "Set -DefaultIsolationID on test vNIC $($newVNICName) to $($tempDefaultIsolationIdToSet)"
                                    Set-VMNetworkAdapterIsolation -ManagementOS `
                                                            -VMNetworkAdapterName $newVNICName `
                                                            -IsolationMode Vlan `
                                                            -AllowUntaggedTraffic $true `
                                                            -DefaultIsolationID $tempDefaultIsolationIdToSet
                                }
                                #endregion

                                Log-Info "Disable DHCP on test vNIC $($newVNICName)"
                                Set-NetIPInterface -InterfaceAlias $newVNICName -Dhcp Disabled

                                # Need to wait until the DHCP is disabled on the adapter. Otherwise, following call might fail
                                [System.Boolean] $vNicReady = $false
                                $stopWatch = [System.diagnostics.stopwatch]::StartNew()
                                while (-not $vNicReady -and ($stopWatch.Elapsed.TotalSeconds -lt $TimeoutWaitForIPInSeconds)) {
                                    if ((Get-VMNetworkAdapter -ManagementOS -Name $newVNICName -ErrorAction SilentlyContinue) -and ((Get-NetIPInterface -InterfaceAlias $newVNICName -AddressFamily IPv4).Dhcp -eq "Disabled")) {
                                        $vNicReady = $true
                                        break
                                    } else {
                                        Start-Sleep -Seconds 3
                                    }
                                }
                                #endregion

                                if ($vNICReady) {
                                    Log-Info "VMNetworkAdapter [ $($newVNICName) ] ready and DHCP is disabled on the adapter."

                                    # We will need to test the connection from vNIC via different pNIC teamed to the VMSwitch
                                    foreach ($pNicInVMSwitch in $physicalAdapterNamesInVMSwitch) {
                                        Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $newVNICName `
                                                                        -PhysicalNetAdapterName $pNicInVMSwitch -ErrorAction SilentlyContinue

                                        Start-Sleep -Seconds 5

                                        Log-Info "Will check connection from the virtual adapter via physical adapter $pNicInVMSwitch."

                                        $retryTimes = 10
                                        Log-Info "Will check connection from Infra IP to DNS server(s) port 53 and public endpoints for max of $($retryTimes) times"
                                        Log-Info "DNS Server to check: $($dnsServersIPToCheck -join ", ")"

                                        ###################################
                                        # Start testing infra IP connection
                                        ###################################
                                        # Magic number: we will test only first 9 IPs from the infra range as:
                                        #       6 are the one we requested right now for services running in HCI cluster
                                        #       3 are the additional that might be used in the future (for example, SLB VM, etc.)
                                        # We don't want to test all the infra IP as it will requires a lot of time to finish the validation
                                        $ipNumberToCheck = 9

                                        if ($infraIPRangeToValidate.Count -lt $ipNumberToCheck) {
                                            $ipNumberToCheck = $infraIPRangeToValidate.Count
                                        }

                                        for ($i=0; $i -lt $ipNumberToCheck; $i++) {
                                            $ipToCheck = $infraIPRangeToValidate[$i]
                                            Log-Info "`n`rCheck IP $($i+1) / $($ipNumberToCheck): [ $($ipToCheck) ]"

                                            #region Set new IP on the adapter
                                            # Make sure no IP on the adapter
                                            $oldIpAddresses = Get-NetIPAddress -InterfaceAlias $newVNICName -ErrorAction SilentlyContinue

                                            foreach ($ip in $oldIpAddresses) {
                                                Remove-NetIPAddress -InterfaceAlias $newVNICName -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
                                            }

                                            Log-Info "Preparing IP $ipToCheck on vNIC $newVNICName."

                                            [System.Boolean] $currentIPReady = $false
                                            try {
                                                if (Get-NetRoute -InterfaceAlias $newVNICName -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue) {
                                                    New-NetIPAddress -InterfaceAlias $newVNICName -IPAddress $ipToCheck -PrefixLength $prefixLength -SkipAsSource $true | Out-Null
                                                } else {
                                                    New-NetIPAddress -InterfaceAlias $newVNICName -IPAddress $ipToCheck -PrefixLength $prefixLength -DefaultGateway $defaultGateway -SkipAsSource $true | Out-Null
                                                }

                                                #region Wait for the new IP to be ready, for up to $TimeoutWaitForIPInSeconds seconds
                                                $ipStopWatch = [System.diagnostics.stopwatch]::StartNew()
                                                while (-not $currentIPReady -and ($ipStopWatch.Elapsed.TotalSeconds -lt $TimeoutWaitForIPInSeconds)) {
                                                    $ipConfig = Get-NetIPAddress -InterfaceAlias $newVNICName -IPAddress $ipToCheck -PrefixOrigin "Manual" -AddressFamily "IPv4" -AddressState "Preferred" -ErrorAction SilentlyContinue

                                                    if ($ipConfig) {
                                                        # After IP configured on the adapter, will need to try ping from the IP to default gateway to make sure the IP is really ready to use
                                                        Log-Info "Validating ICMP connection from $ipToCheck to default gateway $defaultGateway..."

                                                        $tmpPingSuccess = EnvValidatorNwkLibInvokePingWithRetries -Destination $defaultGateway -Source $ipToCheck -RetryCount 15 -SleepSeconds 1
                                                        if ($tmpPingSuccess) {
                                                            Log-Info "ICMP connection from $ipToCheck to default gateway $defaultGateway is successful."
                                                            $currentIPReady = $true
                                                            break
                                                        }
                                                    }

                                                    Start-Sleep -Seconds 3
                                                }
                                                #endregion
                                            } catch {
                                                Log-Info "Got exception when trying to set IP $ipToCheck on vNIC $newVNICName."
                                                $currentIPReady = $false
                                            }
                                            #endregion

                                            if (-not $currentIPReady) {
                                                Log-Info "Cannot get the IP $ipToCheck ready on the vNIC $newVNICName after 60 seconds. Skip to next IP."

                                                $infraIpNotReadyRstParams = @{
                                                    Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_IPReadiness'
                                                    Title              = $lnTxt.InfraConnectionInfraPoolIPReadinessOnAdapter
                                                    DisplayName        = $lnTxt.InfraConnectionInfraPoolIPReadinessOnAdapter
                                                    Severity           = 'CRITICAL'
                                                    Description        = $lnTxt.InfraConnectionInfraPoolIPReadinessOnAdapter
                                                    Tags               = @{}
                                                    Remediation        = $lnTxt.InfraConnectionInfraPoolIPReadinessOnAdapterRemediation -f $ipToCheck, $defaultGateway
                                                    TargetResourceID   = "Infra_IP_Connection_InfraIP_Readiness_$($ipToCheck)"
                                                    TargetResourceName = "Infra_IP_Connection_InfraIP_Readiness_$($ipToCheck)"
                                                    TargetResourceType = "Infra_IP_Connection_InfraIP_Readiness_$($ipToCheck)"
                                                    Timestamp          = [datetime]::UtcNow
                                                    Status             = "FAILURE"
                                                    AdditionalData     = @{
                                                        Source    = $env:COMPUTERNAME
                                                        Resource  = $($ipToCheck)
                                                        Detail    = "[FAILED] Connection from $ipToCheck to gateway $defaultGateway failed. Cannot get the IP configured correctly on the test adapter."
                                                        Status    = "FAILURE"
                                                        TimeStamp = [datetime]::UtcNow
                                                    }
                                                    HealthCheckSource  = $ENV:EnvChkrId
                                                }

                                                $instanceResults += New-AzStackHciResultObject @infraIpNotReadyRstParams
                                                continue
                                            } else {
                                                Log-Info "IP $ipToCheck ready on the vNIC $newVNICName."
                                            }

                                            #region Check connection from infra IP to DNS server
                                            # Note that we cannot use Resolve-DnsName or nslookup here directly, as those call cannot specify the source IP
                                            foreach ($currentDNSServerToCheck in $dnsServersIPToCheck) {
                                                Log-Info "        >> Trying DNS connection to $($currentDNSServerToCheck) port 53."

                                                [System.Boolean] $isDnsConnected = $false
                                                $isDnsConnected = EnvValidatorNwkLibCheckTcpConnectionWithRetries -SourceIp $ipToCheck -DestinationIp $currentDNSServerToCheck -PortToCheck 53 -RetryTimes $retryTimes

                                                if ($isDnsConnected) {
                                                    Log-Info "            == Found valid DNS connection"
                                                    break
                                                }
                                            }
                                            #endregion

                                            $dnsConnectionRstParams = @{
                                                Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_DNS_Server_Port_53'
                                                Title              = $lnTxt.InfraConnectionInfraPoolIPToDNSServer
                                                DisplayName        = $lnTxt.InfraConnectionInfraPoolIPToDNSServer
                                                Severity           = 'CRITICAL'
                                                Description        = $lnTxt.InfraConnectionInfraPoolIPToDNSServer
                                                Tags               = @{}
                                                Remediation        = $lnTxt.InfraConnectionInfraPoolIPToDNSServerRemediation -f $ipToCheck
                                                TargetResourceID   = "Infra_IP_Connection_DNS_Connection_$($ipToCheck)"
                                                TargetResourceName = "Infra_IP_Connection_DNS_Connection_$($ipToCheck)"
                                                TargetResourceType = "Infra_IP_Connection_DNS_Connection_$($ipToCheck)"
                                                Timestamp          = [datetime]::UtcNow
                                                Status             = "FAILURE"
                                                AdditionalData     = @{
                                                    Source    = $env:COMPUTERNAME
                                                    Resource  = "$($ipToCheck)-$($pNicInVMSwitch)"
                                                    Detail    = "[FAILED] Connection from $ipToCheck (via physical adapter $($pNicInVMSwitch)) to DNS server port 53 failed after 3 attempts. DNS server used: $($dnsServersIPToCheck | Out-String)"
                                                    Status    = "FAILURE"
                                                    TimeStamp = [datetime]::UtcNow
                                                }
                                                HealthCheckSource  = $ENV:EnvChkrId
                                            }

                                            if ($ProxyEnabled) {
                                                # In case proxy is enabled, we will downgrade the severity to WARNING as the DNS resolution might happen on proxy server
                                                $dnsConnectionRstParams.Severity = 'WARNING'
                                            }

                                            if ($isDnsConnected) {
                                                $dnsConnectionRstParams.Status = "SUCCESS"
                                                $dnsConnectionRstParams.AdditionalData.Detail = "[PASSED] Connection from $ipToCheck (via physical adapter $($pNicInVMSwitch)) to DNS server port 53 passed. DNS server used: $($dnsServersIPToCheck | Out-String)"
                                                $dnsConnectionRstParams.AdditionalData.Status = "SUCCESS"

                                                #region Check connection from infra IP to well known endpoints
                                                # Since we rely on DNS naming resolution, we put the checking here in this if statement
                                                # Only check if there are endpoints to validate
                                                if ($allPublicEndpointServicesToCheck -and $allPublicEndpointServicesToCheck.Count -gt 0) {
                                                    $resolvedMaxParallelJobs = EnvValidatorNwkLibGetMaxParallelJobs -DefaultMaxParallelJobs 20
                                                    [System.Collections.Hashtable[]] $currentIpConnectionResults = @()
                                                    $currentIpConnectionResults = InfraIpCurlTestToEndpoint -SourceIp $ipToCheck `
                                                                                                        -PhysicalAdapterUsed $pNicInVMSwitch `
                                                                                                        -AllPublicEndpointServicesToCheck $allPublicEndpointServicesToCheck `
                                                                                                        -RegionName $RegionName `
                                                                                                        -LanguageText $lnTxt `
                                                                                                        -ProxyEnabled $ProxyEnabled `
                                                                                                        -TimeoutInSeconds 15 `
                                                                                                        -MaxParallelJobs $resolvedMaxParallelJobs `
                                                                                                        -RetryTimes $retryTimes

                                                    foreach ($rst in $currentIpConnectionResults) {
                                                        $instanceResults += New-AzStackHciResultObject @rst
                                                    }
                                                } else {
                                                    Log-Info "No public endpoints to check for this region. Skipping endpoint connectivity tests."
                                                }

                                                #endregion
                                            } else {
                                                Log-info "DNS connection failed for infra IP $ipToCheck."
                                            }

                                            # Add the DNS connection result here as it might at fail/warning state
                                            $instanceResults += New-AzStackHciResultObject @dnsConnectionRstParams
                                        }
                                    }
                                } else {
                                    # vNIC creation failure. Normally won't hit this path, but keep it here for safety
                                    Log-Info "Cannot get a vNIC ready on VMSwitch $($foundVMSwitchToUse.Name) in $($env:COMPUTERNAME) for validating infra IP connection. Fail the validation"

                                    $params = @{
                                        Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_vNIC_Readiness'
                                        Title              = 'Test virtual adapter readiness for all IP in infra IP pool'
                                        DisplayName        = "Test virtual adapter readiness for all IP in infra IP pool"
                                        Severity           = 'CRITICAL'
                                        Description        = 'Test virtual adapter readiness for all IP in infra IP pool'
                                        Tags               = @{}
                                        Remediation        = "Make sure Add/Get-VMNetworkAdapter on $($env:COMPUTERNAME) can run correctly."
                                        TargetResourceID   = "Infra_IP_Connection_VNICReadiness"
                                        TargetResourceName = "Infra_IP_Connection_VNICReadiness"
                                        TargetResourceType = "Infra_IP_Connection_VNICReadiness"
                                        Timestamp          = [datetime]::UtcNow
                                        Status             = "FAILURE"
                                        AdditionalData     = @{
                                            Source    = $env:COMPUTERNAME
                                            Resource  = 'VNICReadiness'
                                            Detail    = "[FAILED] Cannot test connection for infra IP. VM network adapter is not configured correctly on host $($env:COMPUTERNAME)."
                                            Status    = "FAILURE"
                                            TimeStamp = [datetime]::UtcNow
                                        }
                                        HealthCheckSource  = $ENV:EnvChkrId
                                    }

                                    $instanceResults += New-AzStackHciResultObject @params
                                }
                            } finally {
                                # Best effort to clean the IP used, as the last IP checked might not be cleaned in the previous checking
                                for ($i=0; $i -lt $ipNumberToCheck; $i++) {
                                    Remove-NetIPAddress -IPAddress $infraIPRangeToValidate[$i] -ErrorAction SilentlyContinue -Confirm:$false
                                }

                                # Clean up the vNIC
                                if (Get-VMNetworkAdapter -ManagementOS -Name $newVNICName -ErrorAction SilentlyContinue) {
                                    Remove-VMNetworkAdapter -ManagementOS -SwitchName $foundVMSwitchToUse.Name -Name $newVNICName -Confirm:$false
                                }
                            }
                        } else {
                            # No DNS client server address found on the adapter
                            Log-Info "Cannot get DNS client server address correctly on $($env:COMPUTERNAME) for validating infra IP connection. Fail the validation"

                            $params = @{
                                Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_DNSClientServerAddress_Readiness'
                                Title              = 'Test DNS client server addresses readiness for all IP in infra IP pool'
                                DisplayName        = "Test DNS client server addresses readiness for all IP in infra IP pool"
                                Severity           = 'CRITICAL'
                                Description        = 'Test DNS client server addresses readiness for all IP in infra IP pool'
                                Tags               = @{}
                                Remediation        = "Set DNS client server address correctly on management adapter [ $($mgmtAdapterAlias) ] on $($env:COMPUTERNAME). Check it using Get-DnsClientServerAddress"
                                TargetResourceID   = "Infra_IP_Connection_DNSClientReadiness"
                                TargetResourceName = "Infra_IP_Connection_DNSClientReadiness"
                                TargetResourceType = "Infra_IP_Connection_DNSClientReadiness"
                                Timestamp          = [datetime]::UtcNow
                                Status             = "FAILURE"
                                AdditionalData     = @{
                                    Source    = $env:COMPUTERNAME
                                    Resource  = 'DNSClientReadiness'
                                    Detail    = "[FAILED] Cannot find correctly DNS client server address on host $($env:COMPUTERNAME)."
                                    Status    = "FAILURE"
                                    TimeStamp = [datetime]::UtcNow
                                }
                                HealthCheckSource  = $ENV:EnvChkrId
                            }

                            $instanceResults += New-AzStackHciResultObject @params
                        }
                    } else {
                        Log-Info "Got VMSwitch, but cannot get a valid vNIC to use on $($env:COMPUTERNAME) for validating infra IP connection. Fail the validation"

                        $params = @{
                            Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_MANAGEMENT_VNIC_Readiness'
                            Title              = 'Test VMSwitch/Management VMNetworkAdapter readiness for all IP in infra IP pool'
                            DisplayName        = 'Test VMSwitch/Management VMNetworkAdapter readiness for all IP in infra IP pool'
                            Severity           = 'CRITICAL'
                            Description        = 'Test VMSwitch/Management VMNetworkAdapter readiness for all IP in infra IP pool'
                            Tags               = @{}
                            Remediation        = "Make sure at least one management VMNetworkAdapter with name $($mgmtAdapterAlias) configured correctly on the host $($env:COMPUTERNAME)."
                            TargetResourceID   = "Infra_IP_Connection_ManagementVMNetworkAdapterReadiness"
                            TargetResourceName = "Infra_IP_Connection_ManagementVMNetworkAdapterReadiness"
                            TargetResourceType = 'Infra_IP_Connection_ManagementVMNetworkAdapterReadiness'
                            Timestamp          = [datetime]::UtcNow
                            Status             = "FAILURE"
                            AdditionalData     = @{
                                Source    = $env:COMPUTERNAME
                                Resource  = 'ManagementVMNetworkAdapterReadiness'
                                Detail    = "[FAILED] Cannot test connection for infra IP with wrong management VMNetworkAdapter configured on host $($env:COMPUTERNAME). Expected adapter name: $($mgmtAdapterAlias)."
                                Status    = "FAILURE"
                                TimeStamp = [datetime]::UtcNow
                            }
                            HealthCheckSource  = $ENV:EnvChkrId
                        }

                        $instanceResults += New-AzStackHciResultObject @params
                    }
                } else {
                    Log-Info "Cannot get a VMSwitch to use on $($env:COMPUTERNAME) for validating infra IP connection. Fail the validation"

                    $params = @{
                        Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_VMSwitch_Readiness'
                        Title              = 'Test VMSwitch readiness for all IP in infra IP pool'
                        DisplayName        = "Test VMSwitch readiness for all IP in infra IP pool"
                        Severity           = 'CRITICAL'
                        Description        = 'Test VMSwitch readiness for all IP in infra IP pool'
                        Tags               = @{}
                        Remediation        = "Make sure at least one VMSwitch pre-configured on the host $($env:COMPUTERNAME) has the same set of adapters defined in management intent."
                        TargetResourceID   = "Infra_IP_Connection_VMSwitchReadiness"
                        TargetResourceName = "Infra_IP_Connection_VMSwitchReadiness"
                        TargetResourceType = 'Infra_IP_Connection_VMSwitchReadiness'
                        Timestamp          = [datetime]::UtcNow
                        Status             = "FAILURE"
                        AdditionalData     = @{
                            Source    = $env:COMPUTERNAME
                            Resource  = 'VMSwitchReadiness'
                            Detail    = "[FAILED] Cannot test connection for infra IP with wrong VMSwitch configured on host $($env:COMPUTERNAME)."
                            Status    = "FAILURE"
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }

                    $instanceResults += New-AzStackHciResultObject @params
                }
            } finally {
                if ($needCleanUpVMSwitch) {
                    # Clean up the VMSwitch created for testing
                    Log-Info "Clean up VMSwitch $($foundVMSwitchToUse.Name) created during validation..."
                    Remove-VMSwitch -Name $foundVMSwitchToUse.Name -Force -ErrorAction SilentlyContinue

                    if ($mgmtVlanIdToRestore -ne 0) {
                        foreach ($tmpAdapter in $mgmtAdapters) {
                            Log-Info "Restore VlanId for adapter $tmpAdapter to $mgmtVlanIdToRestore"
                            Set-NetAdapterAdvancedProperty -Name $tmpAdapter -RegistryKeyword "VlanID" -RegistryValue $mgmtVlanIdToRestore
                        }
                    }

                    #region Wait for the IP address back to the pNIC
                    # In case of DHCP scenario, after VMSwitch removed, the pNIC might not get the IP address immediately
                    # Wait for some time (60 seconds) to make sure the new IP is settled correctly.
                    Log-Info "Check if IP address is back to the pNIC after VMSwitch removed."

                    [System.Boolean] $currentIPReady = $false
                    $ipStopWatch = [System.diagnostics.stopwatch]::StartNew()
                    while (-not $currentIPReady -and ($ipStopWatch.Elapsed.TotalSeconds -lt $TimeoutWaitForIPInSeconds)) {
                        # If the pNIC has Manual or Dhcp IPv4 address with "Preferred" state, we consider it as "ready"
                        [PSObject[]] $ipConfig = Get-NetIPAddress -InterfaceAlias $mgmtAdapters[0] -AddressFamily "IPv4" -AddressState "Preferred" -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq "Manual" -or $_.PrefixOrigin -eq "Dhcp" }
                        if ($ipConfig.Count -ge 1) {
                            Log-Info "IP ready on the pNIC $($mgmtAdapters[0])!"
                            Log-Info "$($ipConfig | Out-String)"
                            $currentIPReady = $true
                            break
                        } else {
                            Log-Info "IP not ready yet on the pNIC $($mgmtAdapters[0]). Will check again in 3 seconds..."
                            Start-Sleep -Seconds 3
                        }
                    }
                    #endregion

                    if (-not $currentIPReady) {
                        # should not get into here, but keep it here for safety
                        $ipInfoAll = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table IPAddress, InterfaceAlias, PrefixLength, PrefixOrigin, AddressState -AutoSize
                        Log-Info "$($ipInfoAll | Out-String)"
                        Log-Info "Cannot get the IP address back to the pNIC after VMSwitch removed. Please check the system manually."
                        throw "Cannot get the IP address back to the pNIC after VMSwitch removed. Please check the system manually."
                    } else {
                        Log-Info "IP address back to the pNIC after VMSwitch removed. System is ready for next validation."
                    }
                } else {
                    Log-Info "VMSwitch $($foundVMSwitchToUse.Name) pre-exist in the system. No need to clean up."
                }
            }
        } else {
            Log-Info "Hyper-V is not working correctly on $($env:COMPUTERNAME). Fail testing infra IP connection."

            $params = @{
                Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_Hyper_V_Readiness'
                Title              = 'Test Hyper-V readiness for all IP in infra IP pool'
                DisplayName        = "Test Hyper-V readiness for all IP in infra IP pool"
                Severity           = 'CRITICAL'
                Description        = 'Test Hyper-V readiness for all IP in infra IP pool'
                Tags               = @{}
                Remediation        = "Make sure that Hyper-V is installed on host $($env:COMPUTERNAME) and rerun the validation."
                TargetResourceID   = "Infra_IP_Connection_HyperVReadiness"
                TargetResourceName = "Infra_IP_Connection_HyperVReadiness"
                TargetResourceType = 'Infra_IP_Connection_HyperVReadiness'
                Timestamp          = [datetime]::UtcNow
                Status             = "FAILURE"
                AdditionalData     = @{
                    Source    = $env:COMPUTERNAME
                    Resource  = 'HyperVReadiness'
                    Detail    = "[FAILED] Cannot test connection for infra IP without Hyper-V on host $($env:COMPUTERNAME)."
                    Status    = "FAILURE"
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $instanceResults += New-AzStackHciResultObject @params
        }
        #endregion

        return $instanceResults
    } catch {
        $params = @{
            Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_ExceptionFound'
            Title              = 'Exception found during infra IP pool connection validation.'
            DisplayName        = 'Exception found during infra IP pool connection validation.'
            Severity           = 'CRITICAL'
            Description        = 'Experienced exception during infra IP pool readiness validation. Please check information in AdditionalData.Detail section'
            Tags               = @{}
            Remediation        = "URI"
            TargetResourceID   = "Infra_IP_Connection_Exception"
            TargetResourceName = "Infra_IP_Connection_Exception"
            TargetResourceType = 'InfraIpPool'
            Timestamp          = [datetime]::UtcNow
            Status             = "FAILURE"
            AdditionalData     = @{
                Source    = 'Infra_IP_Connection_Exception'
                Resource  = 'Infra_IP_Connection_Exception'
                Detail    = "$($_.Exception.Message)`n`r$($_.ScriptStackTrace)"
                Status    = "FAILURE"
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $instanceResults += New-AzStackHciResultObject @params

        return $instanceResults
    } finally {
        # Device Management Service might need to be restarted to refresh the nic details
        # It also might not be there
        if (Get-Service -Name DeviceManagementService -ErrorAction SilentlyContinue) {
            Restart-Service -Name DeviceManagementService -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 20
            Log-Info "Restarted the Device Management Service successfully and waited 20 seconds which should refresh the nic details"
        }
    }
}

function InfraIpCurlTestToEndpoint {
    param (
        [Parameter(Mandatory = $true)]
        [System.String] $SourceIp,

        [Parameter(Mandatory = $true)]
        [System.String] $PhysicalAdapterUsed,

        [Parameter(Mandatory = $true)]
        [PSObject[]] $AllPublicEndpointServicesToCheck,

        [Parameter(Mandatory = $false)]
        [System.String] $RegionName,

        [Parameter(Mandatory = $true)]
        $LanguageText,

        [Parameter(Mandatory = $false)]
        [System.Boolean] $ProxyEnabled = $false,

        [System.UInt16] $TimeoutInSeconds = 15,
        [System.UInt16] $MaxParallelJobs = 10,
        [System.UInt16] $RetryTimes = 10
    )

    $curlJobScriptBlock = {
        param (
            [Parameter(Mandatory = $true)]
            [System.String] $SourceIP,
            [Parameter(Mandatory = $true)]
            [System.String] $Uri,
            [Parameter(Mandatory = $true)]
            [System.String] $RegionName,
            [Parameter(Mandatory = $true)]
            [PSObject] $Service,
            [Parameter(Mandatory = $true)]
            $EnvCheckerId,
            [Parameter(Mandatory = $true)]
            $LanguageText,
            [Parameter(Mandatory = $false)]
            [System.Boolean] $ProxyEnabled,
            [Parameter(Mandatory = $false)]
            [System.UInt16] $ConnectTimeout = 15,
            [Parameter(Mandatory = $false)]
            [System.UInt16] $RetryTimes = 10
        )

        [System.String] $jobProgressLog = "`n`rEndpoint connection check for [ $($Uri) ] from infra IP [ $SourceIP ]."

        #region Prepare command to call curl.exe
        # Note that curl.exe honor the system HTTP_PROXY/HTTPS_PROXY settings, so we don't need to specify "--proxy" parameter here
        # Also for "AzureLocal" region (local identity), need to use "--ssl-revoke-best-effort" parameter to avoid curl.exe failing due to cert validation issue
        $maxTimeout = $ConnectTimeout + 5
        $curlGetExpression = "curl.exe -sS --connect-timeout $($ConnectTimeout) --max-time $($maxTimeout) `"$($Uri)`" --interface $($SourceIP)"
        $curlHeaderExpression = "$($curlGetExpression) --show-headers"
        if ($RegionName -eq "AzureLocal") {
            $curlGetExpression = "$($curlGetExpression) --ssl-revoke-best-effort"
            $curlHeaderExpression = "$($curlHeaderExpression) --ssl-revoke-best-effort"
        }

        # So need to redirect stderr to stdout to capture all output
        $curlGetExpression = "$($curlGetExpression) 2>&1"
        $curlHeaderExpression = "$($curlHeaderExpression) 2>&1"

        #endregion

        [System.Boolean] $isPublicEndpointConnected = $false

        $retry = 1
        $stopWatch = [System.diagnostics.stopwatch]::StartNew()

        while ((-not $isPublicEndpointConnected) -and ($retry -le $RetryTimes)) {
            try {
                $curlGetContent = Invoke-Expression $curlGetExpression

                if ((-not [System.String]::IsNullOrWhiteSpace($curlGetContent)) -and ($LASTEXITCODE -eq 0)) {
                    $jobProgressLog += "`n`r    == Run $($curlGetExpression)"
                    $jobProgressLog += "`n`r    == Connection ESTABLISHED with GET on attempt $($retry)"
                    $isPublicEndpointConnected = $true
                    break
                } else {
                    $jobProgressLog += "`n`r    == Run $($curlHeaderExpression)"
                    $curlHeaderContent = Invoke-Expression $curlHeaderExpression

                    if ($LASTEXITCODE -ne 0) {
                        throw "curl failed (exit code $($LASTEXITCODE)): $($curlHeaderContent)"
                    }

                    # Need to analyze the output of $curlHeaderContent to see if the connection is established
                    # If proxy enabled, the response will need to contain something in addition to the "HTTP/1.1 200 Connection established"
                    if ($ProxyEnabled) {
                        $curlHeaderContent = $curlHeaderContent -replace "^HTTP\/\d\.\d 200 Connection established", ""
                    }

                    if (-not [System.String]::IsNullOrWhiteSpace($curlHeaderContent)) {
                        $jobProgressLog += "`n`r    == Connection ESTABLISHED with HEADER only on attempt $($retry)"
                        $isPublicEndpointConnected = $true
                        break
                    } else {
                        $jobProgressLog += "`n`r    ?? FAILED connection on attempt $($retry)"
                    }
                }
            } catch {
                $jobProgressLog += "`n`r    ?? FAILED! Got exception while checking [ $($Uri) ] on attempt ($($retry))!"
                $jobProgressLog += "`n`r    ?? $($_)!"
            }

            Start-Sleep -Seconds 3
            $retry++
        }

        $stopWatch.Stop()

        if ([System.String]::IsNullOrEmpty($Service.Severity) -or [System.String]::IsNullOrWhiteSpace($Service.Severity)) {
            $currentSeverity = "CRITICAL"
        } else {
            $currentSeverity = $Service.Severity
        }

        $publicEndpointRstParams = @{
            Name               = 'AzureLocal_NetworkInfraConnection_Test_Infra_IP_Connection_' + $Service.Name
            Title              = $LanguageText.InfraConnectionInfraPoolIPToOutboundEndpoint -f ""
            DisplayName        = $LanguageText.InfraConnectionInfraPoolIPToOutboundEndpoint -f $Service.Title
            Severity           = $currentSeverity
            Description        = $LanguageText.InfraConnectionInfraPoolIPToOutboundEndpoint -f $Service.Description
            Tags               = @{}
            Remediation        = $LanguageText.InfraConnectionInfraPoolIPToOutboundEndpointRemediation -f $SourceIP, $Uri
            TargetResourceID   = $Service.TargetResourceID
            TargetResourceName = $Service.TargetResourceName
            TargetResourceType = $Service.TargetResourceType
            Timestamp          = [datetime]::UtcNow
            Status             = "FAILURE"
            AdditionalData     = @{
                Source    = $env:COMPUTERNAME
                Resource  = "$($SourceIP)-$($PhysicalAdapterUsed)"
                Detail    = $LanguageText.InfraConnectionInfraPoolIPToOutboundEndpointFAILED -f $SourceIP, $PhysicalAdapterUsed, $Uri, $RetryTimes
                Status    = "FAILURE"
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $EnvCheckerId
        }

        $jobProgressLog += "`n`r    INFO: Total time taken for curl.exe validation: [ $($stopWatch.Elapsed.TotalSeconds) seconds ]"

        if ($isPublicEndpointConnected) {
            $publicEndpointRstParams.Status = "SUCCESS"
            $publicEndpointRstParams.AdditionalData.Detail = $LanguageText.InfraConnectionInfraPoolIPToOutboundEndpointPASSED -f $SourceIP, $PhysicalAdapterUsed, $Uri
            $publicEndpointRstParams.AdditionalData.Status = "SUCCESS"
            $jobProgressLog += "`n`r    [PASS] Public Endpoint connection for [ $($Uri) ] from infra IP [ $SourceIP ]."
        } else {
            $jobProgressLog += "`n`r    [FAIL] Public Endpoint connection for [ $($Uri) ] from infra IP [ $SourceIP ]."
        }

        return @{
            ValidatorLog    = $jobProgressLog
            ValidatorResult = $publicEndpointRstParams
        }
    }

    [System.Collections.Hashtable[]] $resultsForAllEndpoints = @()

    # Create an array of jobs for all uris
    $inProgressJobList = @()
    $totalJobIdList = @()

    Log-Info "Starting max of $($MaxParallelJobs) parallel curl.exe job(s) to check public endpoint connectivity from infra IP [ $SourceIp ]..."

    foreach ($service in $AllPublicEndpointServicesToCheck) {
        foreach ($endpointInService in $service.EndPoint) {
            if (($endpointInService -match "(:[\d]+)$") -and $ProxyEnabled) {
                Log-Info "        >> Skip checking connection to $($endpointInService) in a proxy enabled environment as proxy might not allow HTTP/HTTPS query to non-standard port via curl.exe."
                continue
            }

            $endpointToCheck = "$($service.Protocol[0])://$($endpointInService)"

            [System.String] $checkerId = ""

            if ([System.String]::IsNullOrEmpty($ENV:EnvChkrId) -or [System.String]::IsNullOrWhiteSpace($ENV:EnvChkrId)) {
                $checkerId = ([System.Guid]::NewGuid()) -split '-' | Select-Object -first 1
            } else {
                $checkerId = $ENV:EnvChkrId
            }

            $job = Start-Job -PSVersion 5.1 -ArgumentList $SourceIp, $endpointToCheck, $RegionName, $service, $checkerId, $LanguageText, $ProxyEnabled, $TimeoutInSeconds, $RetryTimes `
                            -ScriptBlock $curlJobScriptBlock
            $inProgressJobList += $job
            $totalJobIdList += $job.id

            if ($inProgressJobList.Count -ge $MaxParallelJobs) {
                # In case we have too many jobs in progress, wait for any one to finish before we go into next iteration to start a new job
                $finishedJob = @()
                $finishedJob = $inProgressJobList | Wait-Job -Any
                if ($finishedJob) {
                    $inProgressJobList = $inProgressJobList | Where-Object { $_ -ne $finishedJob }
                }
            }
        }
    }

    # Wait for all remaining jobs to finish
    Log-Info "Check result for $($totalJobIdList.Count) endpoints. Waiting for connection validation jobs to finish..."
    Wait-Job -Id $totalJobIdList | Out-Null

    Log-Info "All connection validation jobs finished. Collecting results..."
    $resultsForAllEndpoints += Receive-Job -Id $totalJobIdList

    $i = 1
    foreach ($logInfo in $resultsForAllEndpoints) {
        Log-Info "Connection test result log for endpoint $($i) / $($totalJobIdList.Count):"
        Log-Info "$($logInfo.ValidatorLog)"
        $i++
    }

    Log-Info "Cleaning up all connection validation jobs for current IP ..."
    Remove-Job -Id $totalJobIdList -ErrorAction SilentlyContinue
    Log-Info "Clean up finished.`n`r"

    [System.Collections.Hashtable[]] $endpointsValidatorResults = $resultsForAllEndpoints.ValidatorResult
    return $endpointsValidatorResults
}

# SIG # Begin signature block
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDXItNfLmGo75XL
# dHHxRJMvt+fzRPX4IX1N9Xc7hvAZg6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIICI7/4c
# m5SeTiPTbWCMBFFZOHjhNv6XUH82Hbw6zw/zMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAfxCwGWZW+3CDKKZccZ2JUeaZO4IkpHw/uSwliHTk
# Q1e9BkEOa15qIrgKkJB/qeyWaw5oZ6zyqdOqDZpefcL4+UhsFe4fx3kK7OOE+2Y3
# HyKwtUQqexpZmrurzTX/dPzBngHQ5v1h6TvmLzg+KwIZU+ZT7/PcXOMH6rThyM8P
# oTzcQIOoQTl7vhijEfpO/8arr6MFwAa9HjVSONPA3WcS8wbXsrNPLWve1JJMCdHw
# ESsV+sj/rDjhLMPLRFdpA8/3CtAtQFdnVAnTziZt7jsk5Vs2DwklXPbnGH75ooqt
# Z1ONAp5+EN8DeK9/oxWaH7ezWlgHlOWpCKLwt339AT6P2aGCF5IwgheOBgorBgEE
# AYI3AwMBMYIXfjCCF3oGCSqGSIb3DQEHAqCCF2swghdnAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFQBgsqhkiG9w0BCRABBKCCAT8EggE7MIIBNwIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBpV4OyDdKhVN+4KSGcAOmzQk+xQEHQ6A5hOjRF
# 8EcfdQIGaedeW7K8GBEyMDI2MDUwMzE0MzEzMC43WjAEgAIB9KCB0aSBzjCByzEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWlj
# cm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1Mg
# RVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNloIIR6jCCByAwggUIoAMCAQICEzMAAAIo8KWH1/PIHkAAAQAAAigw
# DQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcN
# MjYwMjE5MTk0MDA2WhcNMjcwNTE3MTk0MDA2WjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE0MDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAro725P7KnAkkXmWiXwrn9TcEXHO1
# 5J4ROsJC6H5DY9ZsRAIN+astsXBY4I2q7VbwNPVvEB3KcjKlUlzk8TRybJpNKj9g
# gy71ALpVoO2kuaATkaRF9aM959Edpz6nh9CBytcycY8Wh1ttQG7mdGfsDN1mDc5A
# ZXB5lXtN2Ru65ZNvIe9q+T+TBPBRqRZmFuR5e6bCm4CxH62AIrabbbG/rGbAVCPo
# TCpeLiyWKLSsmb9XsDiIpwX0VPEKLIr46H2gXs1H/TXVfohq1od9tVp0rCtwPyZe
# hi7W0ll3CVlC4G8bqp6GzyvmJQd9e+EzFk4F+GFoxu6NDrc/6YxzQigWwe/PHcp4
# S3RmOgdPBPfuEhq0abLcuIiRzsnRwgOTOIucmEcLHbrfoJr8SKU/MjVyXIyQoNLz
# vJr/5xWPVsrb9qpgrQhRYrxlFqlNtP7FHkaKEGRokDiUJ9PeQo94rCLL0T/ClO4T
# fxAyPB1bG/zT8zBS70c560Z49Ezpw4jk1HJ2MJpPl36EtaMLJHAggsB52wtNA+fM
# /N8uyuWSQe+OYXJ+AhNp0d3ukRrK+NsuarbejHc/7OzE5w0tlJlR1l9V/x2Xt1JV
# /II/7ety+dMSD6pEQgRHTNQAzVGkn6PTkIim/249XYmQhk3xA1AQS6KdZoZMCBfN
# n2qZVdm7rGflOJECAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSqyaWM+PLc6Lr1ZAVb
# YQEhaUPdwzAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8E
# WDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYB
# BQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEw
# KDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4G
# A1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAkOjXy5q0WoYFbYFoN/Nx
# mktO3x8qHem4XFDjbdrXrfugWjbh9K+wAZFR4XjqcQXa1KzhGFRGiIovXSt3LmSz
# ZqdYlAMf1W5jmWJe8c/rTa4wlqq4NY0JqtKEQfIhOECacDYRj+u6GOYbmCFNA+JY
# Q6Goan4CiZ/9AZPvVCgz8OV5VGJq3hZiZY/WEM3Dz3qfDMQV8Yf2OSO70HkWluUo
# 7Yi0Di0ZN4IL62g7OUn+PTCVevwcMVwtq71HxBV+klA6KKiiBPTYFSEatEWbuzrd
# ItCLPh7zz9IQeisDsTINUlijn07RaVqXaPDCb4Cgh5D6VxM4Kaz/qciB7ju4FUZU
# k7G2ARS4dsiHf4rTOLmC9EftkkgQU6UkkbYaxrhJhJSOQQhzMczIP6Kh0j8GQCAJ
# DNguMcYtEre6jLgPpvmcxWJH6BeNUKEiZ/h46oalmENJv0jvfypyUSSVMDHeU4jJ
# 42fhPwyYlK8ubnYlskKb349oUBSNHY4WoaAFw2s3hHIixdrhJ07q/VH43MDrp/6D
# GPlC37ZzotoyizK63ldPe2pM8/ycaZw4GCVP7YFO30H5YOyKoi/ftNu+vo6EB6Nt
# ZlXmOWA/Cof5FGmOiZvzkzPPBu3r08/6p0bpsaL04zErb6WwBzUYZkk3SD01d9gs
# rsQykv1eWuYsAPn/VYgaPsIwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAA
# AAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBB
# dXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YB
# f2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKD
# RLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus
# 9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTj
# kY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56
# KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39
# IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHo
# vwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJo
# LhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMh
# XV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREd
# cu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEA
# AaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqn
# Uv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnp
# cjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0w
# EwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# CwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/o
# olxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNy
# b3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYt
# MjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5j
# cnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+
# TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2Y
# urYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4
# U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJ
# w7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb
# 30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ
# /gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGO
# WhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFE
# fnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJ
# jXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rR
# nj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUz
# WLOhcGbyoYIDTTCCAjUCAQEwgfmhgdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9w
# ZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNDAwLTA1RTAtRDk0
# NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcG
# BSsOAwIaAxUAda25hZM0u6gCtTmr9PAFJ4WzSFKggYMwgYCkfjB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hrPYwIhgPMjAy
# NjA1MDMxMTE2MDZaGA8yMDI2MDUwNDExMTYwNlowdDA6BgorBgEEAYRZCgQBMSww
# KjAKAgUA7aGs9gIBADAHAgEAAgId/DAHAgEAAgITjDAKAgUA7aL+dgIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQC8LC9pkJoF4RByDft0HG/HaJ3CKrPTK0eS
# 3iXPsJAtb7++3dGMHcpdlzQzQia85QGlpfnb/wRR0yHWY/6wOPpmCjfelHIs1Sgm
# LG0WaQF94ezcAxyJN1dlTWFDeBDTud4iO8fnB+QigmNcesbiWhr4oC/ftmPnFxAX
# Mq4jWH3CS/vgEqnoI41HncUBsK9m2oYFDEKwRzH7ZYo+BI6He8w73LaQUgsfjqBu
# 8hDo/e1A40fYxhobKtSN6looqmp8fOxSddCwWqsOb5OUcTVlgB6xFDi+//iLWqqg
# rHBxcz6DL+fJpvnLMlozTwfJFVavfH4NwRRJ7p7qLZUEUBWZ5dRxMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIo8KWH1/PI
# HkAAAQAAAigwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgulz4acvAQUwy6ywkxHu4QZRsGJbkJaLP
# gB90Sv/Mq1MwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBVsYpGUWBjX+KB
# FWStXk+OR/txkN/6sVe+VcLgbfoi1zCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACKPClh9fzyB5AAAEAAAIoMCIEIKeAm9heoLjmcg3D
# 8FFyYtLOzJ+6otqNmdQWeS2ZR9vLMA0GCSqGSIb3DQEBCwUABIICADO5AEb9u+0o
# EV8sNQ04e/Cv/RmkdgoM8mJb8J+sgrS5+yhLqGJ9hBr+JT5t/gPaFHZn/isALzYg
# QITvowWR4qh2BY74FjYHnrVr9X11qHQamJ5NnUNLbwCDXQE5cp68RvK4O6gyWJce
# PBFAwI8iHxSLHqQh/XvW4jqiHr1Ze+BKiEnCy4gAzvfIN1+5s1Y7Z1SP6bdkXMk/
# QyD37XosYk+mioQ5AIGk1b4haj2TZM2mgxjn0Jxx8gHuAWR05yXKdVyGZP8gbMme
# GdY4HgCL+76uzg9/aNroC/Sj/ciMslO+SxPEurhWaihxOe8kBzcGdR6F3c9iyNzz
# fMoAPWYcQyebS04e61ZThIgcpOk5dtcf9yTFfHWdACxm3/Vw7I1X60TNoyqv5XJH
# b+9dOc20TvSp0SF+NWQlFSJXgL96XlKVkEWGGF8gCTCCyp2zE8pV6W/E5TXyOAHr
# mKYisPON6jezCrAIkb+sd5a+VnsgNh0hoX5Fy0Px4EqR7P4rK8vOAc3yCYG5laEG
# QeEqWpWMPoDYqLYR9DemnC6EylqCQ1W+0eomW0DRssl72sAIx26Z0qCw6BH+sVEZ
# Dt1MlnfckDIRW3ikzX0iCCvGAmwVvvM3+1wKC8+av1VIj6qcXlKCVG04Kqvr9K8j
# /0IkGuu6fvJ6/hvS4ATXX2NWtmy+wYC/
# SIG # End signature block
