<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

Import-LocalizedData -BindingVariable lnTxt -FileName AzureLocal.NetworkStorageConnection.Strings.psd1
Import-Module $PSScriptRoot\..\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -DisableNameChecking -Global | Out-Null

#################################################################################################
# NetworkInfraConnection Validators
#   - Test-NwkStorageConnectionValidator_StorageAdapterConnection
#
#################################################################################################
function Test-NwkStorageConnectionValidator_StorageAdapterConnection
{
    <#
    .SYNOPSIS
        Test stamp storage connection for deployment

    .DESCRIPTION
        This validator tests the storage connection for the deployment using Test-Cluster or ping MESH.
        It will only be run if the end user provides one storage intent:
            If the storage intent is not converged intent, we check pNIC connection only.
            If the storage intent is converged intent (a.k.a., with management or compute intent combined), we create VMSwitch and storage vNIC for connection testing.

        The validation run ping mesh on each host for storage adapters using a valid IP address.
            We only run “ping” test and check if the results have “Reply from <TARGET_IP>: bytes=” string in it.
            With this test, there will be 1 validation result generated for each of the server in the stamp.

        After the validation is finished, we clean the test artifacts created during the validation (like the VLANID configuration on pNIC, VMSwitch itself, etc.)

    .PARAMETER PSSession
        The remote session array to the nodes to be validated

    .PARAMETER HostNetworkInfo
        The ATC host network info object, which contains the all the necessary host network configuration information for the nodes, like intent, storage network, etc.
        Easiest way to get this is to convert from the "HostNetwork" object in the unattended JSON file.

    .EXAMPLE
        Test-NwkValidator_StorageConnection -PSSession $PSSession -HostNetworkInfo $HostNetworkInfo
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        [PSObject] $HostNetworkInfo,
        [System.String] $StorageType = "S2D"
    )

    if ($PSSession.Count -le 1) {
        Log-Info "Only one or zero PSSession provided. Skip storage connection validation."
        return
    }

    try {
        Log-Info "[$($MyInvocation.MyCommand)] Starting function call... StorageType: $StorageType"
        $switchlessDeploy = $HostNetworkInfo.storageConnectivitySwitchless -eq $true

        Import-Module -Name Hyper-V     -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
        Import-Module -Name NetAdapter  -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
        Import-Module -Name NetTCPIP    -Verbose:$false -ErrorAction SilentlyContinue | Out-Null

        # validation results to be returned
        $storageAdapterConnectionResults = @()

        if (-not $HostNetworkInfo) {
            throw "HostNetworkInfo is required for the storage connection validation. Check your answer file / ARM template to make sure it contains section of [ ScaleUnits | DeploymentData | HostNetwork ]."
        }

        [PSObject[]] $AtcHostIntents = $HostNetworkInfo.intents

        # Storage VLAN defined
        [System.Collections.Hashtable] $storageAdapterVLANIDInfo = @{}
        # In non-SAN scenario If customer provided customized storage IP, we will save the info here
        [System.Collections.Hashtable] $storageAdapterIpInfo = @{}
        # For SAN: subnet info per adapter from sanNetworks.clusterNetworkConfig.adapterIPConfig
        [System.Collections.Hashtable] $sanAdapterSubnetInfo = @{}

        [System.Management.Automation.Runspaces.PSSession[]] $newTestSessionsBeforeChecking = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        #region Define variables used during the validation
        # We might have converged storage intent, so use a different variable to make sure we can use either physical adapters or vNIC created for converged intent.
        [PSObject[]] $allStorageAdaptersToCheck = @()
        [System.Collections.Hashtable] $storageAdapterVlanIdToConfig = @{}
        [System.Collections.Hashtable] $storageVirtualNicPhysicalNicTeamMapping = @{}
        [System.Boolean] $needStorageVMSwitch = $false
        [System.Boolean] $convergedMgmtStorageIntent = $false
        [System.String] $storageVMSwitchName= ""
        #endregion

        #region Prepare variables
        [PSObject[]] $storageNetworkDefinition = $null
        [System.String[]] $storageClusterNetworkAllPhysicalAdapters = @()

        if ($StorageType -ieq 'SAN') {
            # SAN: read adapter VLAN and subnet info from sanNetworks.clusterNetworkConfig.adapterIPConfig
            Log-Info "StorageType is SAN. Reading adapter configuration from sanNetworks.clusterNetworkConfig.adapterIPConfig."
            $sanClusterNetworkConfig = $HostNetworkInfo.sanNetworks.clusterNetworkConfig
            if (-not $sanClusterNetworkConfig -or -not $sanClusterNetworkConfig.adapterIPConfig) {
                throw "StorageType is SAN but sanNetworks.clusterNetworkConfig.adapterIPConfig is missing. Check your answer file / ARM template."
            }

            [PSObject[]] $adapterIPConfigEntries = $sanClusterNetworkConfig.adapterIPConfig
            foreach ($adapterIPEntry in $adapterIPConfigEntries) {
                $adapterName = $adapterIPEntry.networkAdapterName
                $vlanId = if ($null -ne $adapterIPEntry.vlanId) { $adapterIPEntry.vlanId } else { 0 }
                $storageAdapterVLANIDInfo.Add($adapterName, $vlanId)

                # Pre-compute normalized network address and subnet mask from addressPrefix
                if ($adapterIPEntry.addressPrefix) {
                    $cidrInfo = EnvValidatorNwkLibConvertPrefixLengthToSubnetMask -CidrNotation $adapterIPEntry.addressPrefix
                    $sanAdapterSubnetInfo.Add($adapterName, $cidrInfo)
                    Log-Info "SAN adapter $adapterName : addressPrefix=$($adapterIPEntry.addressPrefix) -> network=$($cidrInfo.NetworkAddress)/$($cidrInfo.PrefixLength), mask=$($cidrInfo.SubnetMask)"
                }
            }

            # Build a storageNetworkDefinition-compatible object for downstream link connection logic
            $storageNetworkDefinition = $adapterIPConfigEntries
            $storageClusterNetworkAllPhysicalAdapters = $adapterIPConfigEntries | Select-Object -ExpandProperty networkAdapterName
            $needStorageVMSwitch = $false
            $allStorageAdaptersToCheck = $storageClusterNetworkAllPhysicalAdapters
            $storageAdapterVlanIdToConfig = $StorageAdapterVLANIDInfo
        } else {
            # S2D (default): read from storageNetworks as before

            # Only need to worry about storage intent
            [PSObject[]] $tmpStorageIntents = $AtcHostIntents | Where-Object { $_.TrafficType.Contains("Storage") }

            # Prepare $allStorageAdaptersToCheck, $needStorageVMSwitch, $storageVMSwitchName, $storageAdapterVlanIdToConfig, $storageVirtualNicPhysicalNicTeamMapping
            if ($tmpStorageIntents.Count -eq 1) {
                # Valid storage intent provided
                Log-Info "Found storage intent [ $($tmpStorageIntents[0].Name) ]. Need to run storage adapter connection validation."

                $storageNetworkDefinition = $HostNetworkInfo.storageNetworks
                foreach ($storageNetworkInfo in $storageNetworkDefinition) {
                    $storageAdapterVLANIDInfo.Add($storagenetworkInfo.networkAdapterName, $storageNetworkInfo.VlanId)

                    # if end user provided storage adapter IP info, we will use it to validate the storage connection
                    if ($storageNetworkInfo.StorageAdapterIPInfo) {
                        $storageAdapterIpInfo.Add($storagenetworkInfo.networkAdapterName, $storageNetworkInfo.StorageAdapterIPInfo)
                    }
                }

                $storageClusterNetworkAllPhysicalAdapters = $tmpStorageIntents[0].Adapter

                if ($storageClusterNetworkAllPhysicalAdapters.Count -eq 0) {
                    # Ideally should not come to here but keep it here as a safe guard
                    Log-Info "No physical adapter found in the storage intent. Fail the storage adapter connection validation."
                    throw "No physical adapter found in the storage intent. Fail the storage adapter connection validation. Make sure the [ Adapter ] section is defined in the storage intent."
                }

                Log-Info "Found physical adapter list [ $($storageClusterNetworkAllPhysicalAdapters -join ",") ] in the storage intent."

                # If it is a converged intent, we will need to create VMSwitch/vNIC for validation
                # if it is storage only intent, we just check the physical storage adapter
                if ($tmpStorageIntents[0].TrafficType.Contains("Management") -or $tmpStorageIntents[0].TrafficType.Contains("Compute")) {
                    # Converged intent with storage, will need to create vNIC for storage
                    Log-Info "Converged intent. Will need to use VMSwitch/vNIC for storage connection validation."

                    if ($tmpStorageIntents[0].TrafficType.Contains("Management")) {
                        Log-Info "Management intent found in the converged storage intent."
                        $convergedMgmtStorageIntent = $true
                    }

                    foreach ($tempName in $storageClusterNetworkAllPhysicalAdapters) {
                        # Pre-define the storage vNIC to be checked, this name will be used later in the script block $setAndCheckHostIPv4AddressScript
                        [System.String] $tmpVirtualNicName = "vStorageTestNic($($tempName))"
                        $allStorageAdaptersToCheck += $tmpVirtualNicName
                        $storageAdapterVlanIdToConfig.Add($tmpVirtualNicName, $StorageAdapterVLANIDInfo[$tempName])
                        $storageVirtualNicPhysicalNicTeamMapping.Add($tmpVirtualNicName, $tempName)
                    }

                    $needStorageVMSwitch = $true
                    $tmpGuid = [System.Guid]::NewGuid()
                    $storageVMSwitchName = "StorageTestVMSwitch$($tmpGuid)"

                    Log-Info "If need to create new VMSwitch, will use name $($storageVMSwitchName)."
                } else {
                    Log-Info "Storage only intent. Will need to run storage connection validation on pNIC only."
                    $allStorageAdaptersToCheck = $storageClusterNetworkAllPhysicalAdapters
                    $storageAdapterVlanIdToConfig = $StorageAdapterVLANIDInfo
                }

                Log-Info "$($storageVirtualNicPhysicalNicTeamMapping | ConvertTo-Json -Depth 3)"
            } elseif ($tmpStorageIntents.Count -gt 1) {
                # Should not get into here as ATC does not support multiple storage intent, so the input $AtcHostIntents
                # object should not have multiple storage intent in it, but keep it here as a safe guard
                Log-Info "More than one storage intent found in the AtcHostIntents object array. Fail the storage adapter connection validation."
                throw "More than one storage intent found in the Intents definition. Fail the storage adapter connection validation. Make sure only one intent with [ TrafficType ] contains [ Storage ] in it."
            } else {
                Log-Info "No storage intent found in the AtcHostIntents object array. Skip the storage adapter connection validation."
                return
            }
        }

        Log-Info "Storage adapter NAME list used for the validation:"
        Log-Info "$($allStorageAdaptersToCheck -join ",")"
        Log-Info "Storage adapter VLANID list used for the validation:"
        Log-Info "$($storageAdapterVlanIdToConfig | Out-String)"

        #region Validate storage adapter IP info if provided, this will only happen if NOT in SAN scenario
        # For SAN scenario, $storageAdapterIpInfo is not assigned with any value, so the below check will be skipped
        if ($storageAdapterIpInfo.Count -gt 0) {
            # Below checking should not needed as we assume the input data is in good shape, but keep it here as a safe guard
            if ($HostNetworkInfo.EnableStorageAutoIP) {
                Log-Info "Customized storage IP provided with StorageAdapterIpInfo, but EnableStorageAutoIP is not configured to false." -Type 'WARNING'
                throw "Customized storage IP provided. Please check your unattended JSON file or ARM template to make sure EnableStorageAutoIP is set to false if you want to use customized storage IP configuration."
            }

            # If the storage adapter IP info is provided
            # 1. Make sure the storage adapter IP info is consistent with the storage adapter VLANID info.
            if ($storageAdapterIpInfo.Count -ne $storageAdapterVLANIDInfo.Count) {
                Log-Info "Storage adapter VLANID info and Storage adapter IP info are not consistent. Fail the storage connection validation." -Type 'WARNING'
                throw "Storage adapter VLANID info and Storage adapter IP info are not consistent: Adapter count with IP configuration [ $($storageAdapterIpInfo.Count) ]; Adapter count with VLANID configuration: [ $($storageAdapterVLANIDInfo.Count) ]"
            }

            # 2. Make sure the storage adapter IP info is consistent across all hosts.
            [System.Int16] $hostNumber = -1
            foreach ($adapterName in $storageAdapterIpInfo.Keys) {
                if ($hostNumber -eq -1) {
                    $hostNumber = $storageAdapterIpInfo[$adapterName].Count
                }

                if ($storageAdapterIpInfo[$adapterName].Count -ne $hostNumber) {
                    Log-Info "Storage adapter IP info for adapter $adapterName is not consistent across hosts. Fail the storage connection validation." -Type 'WARNING'
                    throw "Storage adapter IP info for adapter $adapterName is not consistent across hosts. Fail the storage connection validation. Expected $hostNumber IP addresses, but found $($storageAdapterIpInfo[$adapterName].Count) IP addresses."
                }
            }

            # 3. Make sure the storage adapter IP info is consistent with the storage adapter definition in the storage intent.
            if ($storageAdapterIpInfo.Count -ne $allStorageAdaptersToCheck.Count) {
                Log-Info "Customized IP info definition in StorageNetworks is not align with storage adapter definition in storage intent" -Type 'WARNING'
                throw "Customized IP info definition in StorageNetworks is not align with storage adapter definition in storage intent. Expected $($allStorageAdaptersToCheck.Count) storage adapters, but found $($storageAdapterIpInfo.Count) storage adapters with IP configuration."
            }
        }
        #endregion
        #endregion

        [System.Boolean] $needCleanUpStorageVMSwitch = $false

        if ($needStorageVMSwitch) {
            # First make sure all the nodes have same configuration
            Log-Info "Need to use storage VMSwitch for the validation. Make sure same configuration on all host(s)."

            [System.Boolean] $allNodeSameConfig = $true
            [System.String] $allNodeVMSwitchStatus = $null
            [System.String] $existingVMSwitchOnMachine = $null

            Log-Info "Checking VMSwitch configuration on all nodes in parallel..."
            $vmSwitchConfigurations = @(Invoke-Command -Session $newTestSessionsBeforeChecking -ScriptBlock {
                param ([System.String[]] $AdapterForStorageVMSwitch)

                $retVal = New-Object PSObject -Property @{
                    retValVMSwitchStatus = ""
                    existingVMSwitchName = ""
                    ComputerName = ""
                    AdapterName = $AdapterForStorageVMSwitch -join ", "
                }

                [System.String] $retValVMSwitchStatus = "NEED_CREATE_VMSWITCH"
                [System.String] $existingVMSwitchName = ""
                [System.String[]] $storageAdapterGuidOnCurrentNode = (Get-NetAdapter -Physical -Name $AdapterForStorageVMSwitch -ErrorAction SilentlyContinue).InterfaceGuid.Trim('{').Trim('}')

                try {
                    [PSObject[]] $allVMSwitchInSystem = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue

                    foreach ($tmpVMSwitch in $allVMSwitchInSystem) {
                        [PSObject[]] $currentVmSwitchTeam = @()
                        $currentVmSwitchTeam = Get-VMSwitchTeam -Name $tmpVMSwitch.Name -ErrorAction SilentlyContinue

                        if ($currentVmSwitchTeam.Count -gt 0) {
                            if (Compare-Object -ReferenceObject $currentVmSwitchTeam.NetAdapterInterfaceGuid.Guid -DifferenceObject $storageAdapterGuidOnCurrentNode) {
                                # Found difference between two objects, means some (if not all) adapters are used in pre-defined VMSwitch and the intent are different.
                            } else {
                                # if the system already have a VMSwitch with the same mgmt adapters in its teaming
                                $retValVMSwitchStatus = "EXIST_VMSWITCH"
                                $existingVMSwitchName = $tmpVMSwitch.Name
                                break
                            }
                        }
                    }
                } catch {
                    # In case the Hyper-V PowerShell module is not ready, we cannot do anything here
                    # This current validator will fail. Considering current it is only WARNING, so should be fine here.
                    $retValVMSwitchStatus = "HYPER_V_POWERSHELL_NOT_READY"
                }

                $retVal.ComputerName = $env:COMPUTERNAME
                $retVal.retValVMSwitchStatus = $retValVMSwitchStatus
                $retVal.existingVMSwitchName = $existingVMSwitchName

                return $retVal
            } -ArgumentList @(, $storageClusterNetworkAllPhysicalAdapters))

            foreach ($currentNodeConfig in $vmSwitchConfigurations) {
                Log-Info "Node $($currentNodeConfig.ComputerName) with VMSwitch status $($currentNodeConfig.retValVMSwitchStatus)"

                if (-not $allNodeVMSwitchStatus) {
                    $allNodeVMSwitchStatus = $currentNodeConfig.retValVMSwitchStatus
                    $existingVMSwitchOnMachine = $currentNodeConfig.existingVMSwitchName
                } else {
                    if ($allNodeVMSwitchStatus -ne $currentNodeConfig.retValVMSwitchStatus) {
                        Log-Info "VMSwitch status is different with other nodes. Will fail the validation."
                        $allNodeSameConfig = $false
                    }
                }
            }

            # Check that all VM Switches have the same name
            $previousVMSwitchName = $null
            foreach ($vmSwitchConfig in $vmSwitchConfigurations) {
                if (-not [string]::IsNullOrEmpty($vmSwitchConfig.existingVMSwitchName)) {
                    if (-not $previousVMSwitchName) {
                        $previousVMSwitchName = $vmSwitchConfig.existingVMSwitchName
                    } elseif ($previousVMSwitchName -ne $vmSwitchConfig.existingVMSwitchName) {
                        Log-Info "VMSwitch name is different with other nodes. Will fail the validation."
                        $allNodeSameConfig = $false
                    }
                }
            }

            if ((-not $allNodeSameConfig) -or ($allNodeVMSwitchStatus -notin @("EXIST_VMSWITCH", "NEED_CREATE_VMSWITCH"))) {
                # In case the node VMSwitch configuration is different between each other, we cannot do anything here
                # Should not be here, but will fail the validation just in case end user did not configure the system correctly

                # Construct the additional data detail message
                $targetResourceId = ""
                $additionalDataDetail = "Storage Adapter VMSwitch configurations differ between nodes: "
                foreach ($vmSwitchConfig in $vmSwitchConfigurations) {
                    if ($targetResourceId -ne "") {
                        $targetResourceId += ", "
                    }

                    $targetResourceId += "$($vmSwitchConfig.ComputerName) ($($vmSwitchConfig.AdapterName))"

                    if ([string]::IsNullOrEmpty($vmSwitchConfig.existingVMSwitchName)) {
                        $additionalDataDetail += "$($vmSwitchConfig.ComputerName) ($($vmSwitchConfig.AdapterName)) has no VMSwitch assigned., "
                    } else {
                        $additionalDataDetail += "$($vmSwitchConfig.ComputerName) ($($vmSwitchConfig.AdapterName)) has VMSwitch [$($vmSwitchConfig.existingVMSwitchName)], "
                    }
                }

                $additionalDataDetail = $additionalDataDetail.TrimEnd(', ')
                Log-Info $additionalDataDetail -Type 'WARNING'

                $storageAdapterConnectionRstObject = @{
                    Name               = 'AzureLocal_Network_Test_StorageConnections_VMSwitch_Configuration'
                    Title              = 'Validate that Storage Adapters have consistent VMSwitch configuration across all nodes.'
                    DisplayName        = 'Validate that Storage Adapters have consistent VMSwitch configuration across all nodes.'
                    Severity           = 'CRITICAL'
                    Description        = 'All Storage Adapters must have the same VMSwitch configuration across nodes. This check only applies if the VMSwitch was created before deployment, which is optional.'
                    Tags               = @{}
                    Remediation        = 'https://aka.ms/azurelocal/envvalidator/storageconnections'
                    TargetResourceID   = $targetResourceId
                    TargetResourceName = $targetResourceId
                    TargetResourceType = 'StorageAdapter'
                    Timestamp          = [datetime]::UtcNow
                    Status             = 'FAILURE'
                    AdditionalData     = @{
                        Source    = $targetResourceId
                        Resource  = 'StorageAdapter'
                        Detail    = $additionalDataDetail
                        Status    = 'FAILURE'
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                $storageAdapterConnectionResults += New-AzStackHciResultObject @storageAdapterConnectionRstObject

                return $storageAdapterConnectionResults
            }

            if ($allNodeVMSwitchStatus -eq "EXIST_VMSWITCH") {
                $needCleanUpStorageVMSwitch = $false

                # Just need to create new storage vNIC to test the storage connection on all nodes in parallel
                Invoke-Command -Session $newTestSessionsBeforeChecking -ScriptBlock {
                    param(
                        $ExistingVMSwitchOnMachine,
                        $AllStorageAdaptersToCheck,
                        $StorageAdapterVlanIdToConfig,
                        $StorageVirtualAdapterPhysicalNicMapping,
                        $CreateStorageVNICFunction
                    )

                    New-Item -Path "Function:\CreateStorageVNIC" -Value $CreateStorageVNICFunction -Force | Out-Null

                    CreateStorageVNIC -StorageVMSwitchName $ExistingVMSwitchOnMachine `
                                    -StorageVNICNames $AllStorageAdaptersToCheck `
                                    -StorageAdapterVLANIDInfo $StorageAdapterVlanIdToConfig `
                                    -StorageVirtualNicPhysicalNicTeamMapping $StorageVirtualAdapterPhysicalNicMapping
                } -ArgumentList $existingVMSwitchOnMachine, $allStorageAdaptersToCheck, $storageAdapterVlanIdToConfig, $storageVirtualNicPhysicalNicTeamMapping, $function:CreateStorageVNIC
            } elseif ($allNodeVMSwitchStatus -eq "NEED_CREATE_VMSWITCH") {
                $needCleanUpStorageVMSwitch = $true
                # Need to create VMSwitch on each node for storage connection validation
                Log-Info "Prepare VMSwitch for storage connection validation on all nodes"
                Log-Info "    New VMSwitch name: $($storageVMSwitchName)"
                Log-Info "    Physical adapter to be teamed: $($storageClusterNetworkAllPhysicalAdapters -join ", ")"
                Log-Info "    Storage vNIC will be created: $($allStorageAdaptersToCheck)"
                Log-Info "    Storage VLANID will be used: $($storageAdapterVlanIdToConfig | Out-String)"

                $vmSwitchCreationScript = {
                    param(
                        $StorageVMSwitchAdapter,
                        $StorageVMSwitchName,
                        $StorageVNICNames,
                        $StorageAdapterVLANIDInfo,
                        $StorageVirtualAdapterPhysicalNicMapping,
                        $EnvValidatorNwkLibConfigureVMSwitchForTestingFunction,
                        $CreateStorageVNICFunction
                    )

                    # Create the functions in the remote session
                    New-Item -Path "Function:\EnvValidatorNwkLibConfigureVMSwitchForTesting" -Value $EnvValidatorNwkLibConfigureVMSwitchForTestingFunction -Force | Out-Null
                    New-Item -Path "Function:\CreateStorageVNIC" -Value $CreateStorageVNICFunction -Force | Out-Null

                    # Now call the functions
                    $tmpRst = EnvValidatorNwkLibConfigureVMSwitchForTesting -SwitchAdapterNames $StorageVMSwitchAdapter -ExpectedVMSwitchName $StorageVMSwitchName

                    CreateStorageVNIC -StorageVMSwitchName $tmpRst.VMSwitchInfo.Name `
                                    -StorageVNICNames $StorageVNICNames `
                                    -StorageAdapterVLANIDInfo $StorageAdapterVLANIDInfo `
                                    -StorageVirtualNicPhysicalNicTeamMapping $StorageVirtualAdapterPhysicalNicMapping

                    return $tmpRst
                }

                # Separate remote sessions from local machine session
                $localIPs = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq "Preferred" } | Select-Object -ExpandProperty IPAddress
                [System.Management.Automation.Runspaces.PSSession[]] $remoteSessions = @($newTestSessionsBeforeChecking | Where-Object {
                    $_.ComputerName -ne $env:COMPUTERNAME -and
                    $_.ComputerName -ne "localhost" -and
                    $_.ComputerName -ne "127.0.0.1" -and
                    $localIPs -notcontains $_.ComputerName
                })

                # Run VMSwitch creation on all remote nodes in parallel
                if ($remoteSessions.Count -gt 0) {
                    Log-Info "Trying to prepare storage connection validation VMSwitch/vNIC on remote machines $($remoteSessions.ComputerName -join ', ') in parallel..."
                    Log-Info "    Might lost computer connection momentarily..."
                    Log-Info "    Creating VMSwitch with name $($storageVMSwitchName). StorageAdapters: $($allStorageAdaptersToCheck -join ", "), VLANID: $($storageAdapterVlanIdToConfig | Out-String)"
                    $null = Invoke-Command -Session $remoteSessions -ScriptBlock $vmSwitchCreationScript `
                                -ArgumentList @($storageClusterNetworkAllPhysicalAdapters, $storageVMSwitchName, $allStorageAdaptersToCheck, $storageAdapterVlanIdToConfig, $storageVirtualNicPhysicalNicTeamMapping, $function:EnvValidatorNwkLibConfigureVMSwitchForTesting, $function:CreateStorageVNIC)
                    Log-Info "    Done with configure VMSwitch/vNIC on remote machines $($remoteSessions.ComputerName -join ', ')!"
                }

                # Finally run the execution on local machine to make sure the VMSwitch is prepared on local machine as well
                Log-Info "Trying to prepare storage connection validation VMSwitch/vNIC on local machine $($env:COMPUTERNAME)"
                Log-Info "    Creating VMSwitch with name $($storageVMSwitchName) on the machine. StorageAdapters: $($allStorageAdaptersToCheck -join ", "), VLANID: $($storageAdapterVlanIdToConfig | Out-String)"
                $vmSwitchCreationInfo = Invoke-command -ScriptBlock $vmSwitchCreationScript `
                            -ArgumentList @($storageClusterNetworkAllPhysicalAdapters, $storageVMSwitchName, $allStorageAdaptersToCheck, $storageAdapterVlanIdToConfig, $storageVirtualNicPhysicalNicTeamMapping, $function:EnvValidatorNwkLibConfigureVMSwitchForTesting, $function:CreateStorageVNIC)
                Log-Info "    Done with configure VMSwitch/vNIC on local machine $($env:COMPUTERNAME)!"
            }
        } else {
            Log-Info "No need to create VMSwitch for storage connection validation. Will need to set the VLANID on pNIC on all nodes for the validation."

            if ($storageAdapterVlanIdToConfig.Count -gt 0) {
                # In case we have VLANID configured in the JSON (either S2D, or SAN), we will need to configure adapter VLANID
                Log-Info "Trying to set storage adapter VLANID on $($newTestSessionsBeforeChecking.ComputerName)"

                Invoke-Command -Session $newTestSessionsBeforeChecking -ArgumentList $storageAdapterVlanIdToConfig -ScriptBlock {
                    param ([System.Collections.Hashtable] $StorageAdapterVLANIDInfo)
                    foreach ($adapterName in $StorageAdapterVLANIDInfo.Keys) {
                        $vlanId = $StorageAdapterVLANIDInfo[$adapterName]
                        if ($vlanId -ne 0) {
                            $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
                            if ($adapter) {
                                Set-NetAdapterAdvancedProperty -Name $adapterName -RegistryKeyword "VLANID" -RegistryValue $vlanId
                            }
                        }
                    }
                }

                Log-Info "Done with $($newTestSessionsBeforeChecking.ComputerName)!"
            }
        }

        # Need to make sure we have the pre-req that needed for the storage connection validation
        #   Storage adapter has IPv4 address
        #   If converged intent with storage, then hyper-v feature should be there in the system.

        $usePingMeshOnIPv4 = $true
        [System.Collections.Hashtable] $hostIPv4AddressTable = @{}
        $hostIPv4AddressList = @() # Used to summarize the results at the end

        $setAndCheckHostIPv4AddressScript = {
            [CmdletBinding()]
            param (
                [String[]] $StorageAdaptersToCheck,
                [System.Collections.Hashtable] $StorageAdapterIpInfo = @{},
                [System.Collections.Hashtable] $SanAdapterSubnetInfo = @{},
                $EnvValidatorNwkLibConvertToPrefixLengthFunction,
                $FindExpectedIPFunction,
                $EnvValidatorNwkLibGenerateRandomIPInSubnetFunction,
                $EnvValidatorNwkLibNormalizeIPv4SubnetFunction,
                $EnvValidatorNwkLibGetNetworkAddressFunction,
                $EnvValidatorNwkLibConvertIPAddressToIntFunction,
                $EnvValidatorNwkLibConvertIntToIPAddressStringFunction
            )

            Import-Module -Name NetTCPIP -Verbose:$false -ErrorAction SilentlyContinue | Out-Null

            # Make sure the utility function EnvValidatorNwkLibConvertToPrefixLength is available in the remote session
            New-Item -Path "Function:\EnvValidatorNwkLibConvertToPrefixLength" -Value $EnvValidatorNwkLibConvertToPrefixLengthFunction -Force | Out-Null
            New-Item -Path "Function:\FindExpectedIP" -Value $FindExpectedIPFunction -Force | Out-Null

            # Inject functions needed for SAN random IP generation
            if ($null -ne $EnvValidatorNwkLibGenerateRandomIPInSubnetFunction) {
                New-Item -Path "Function:\EnvValidatorNwkLibGenerateRandomIPInSubnet" -Value $EnvValidatorNwkLibGenerateRandomIPInSubnetFunction -Force | Out-Null
                New-Item -Path "Function:\EnvValidatorNwkLibNormalizeIPv4Subnet" -Value $EnvValidatorNwkLibNormalizeIPv4SubnetFunction -Force | Out-Null
                New-Item -Path "Function:\EnvValidatorNwkLibGetNetworkAddress" -Value $EnvValidatorNwkLibGetNetworkAddressFunction -Force | Out-Null
                New-Item -Path "Function:\EnvValidatorNwkLibConvertIPAddressToInt" -Value $EnvValidatorNwkLibConvertIPAddressToIntFunction -Force | Out-Null
                New-Item -Path "Function:\EnvValidatorNwkLibConvertIntToIPAddressString" -Value $EnvValidatorNwkLibConvertIntToIPAddressStringFunction -Force | Out-Null
            }

            $retVal = New-Object PSObject -Property @{
                Pass = $true
                ComputerName = $env:COMPUTERNAME
                AdapterIPv4Mapping = @{}
                DetailLog = ""
            }

            for ($i=1; $i -le $StorageAdaptersToCheck.Count; $i++) {
                $storageAdapter = $StorageAdaptersToCheck[$i - 1]
                $retVal.DetailLog += "`r`nConfigure storage adapter: $($storageAdapter)"

                [System.Boolean] $currentAdapterIPReady = $false

                $retrySetIPCount = 0
                $maxSetIPRetries = 5

                # Try 5 times so we could possible get a valid IP allocated for the storage adapter, esp when we need to allocate 10.71.n.0/24 IP in AutoIP scenario
                while ($retrySetIPCount -lt $maxSetIPRetries) {
                    $retrySetIPCount++
                    $retVal.DetailLog += "`r`n    Attempt $($retrySetIPCount) to set IP on the adapter $($storageAdapter)"

                    # Need to configure the adapter IPv4 address from the default storage subnet, as end user might use AutoIP configuration
                    # Randomize the last octet to avoid conflicts: should not use 0 or 255, which are the network address and broadcast address
                    # Note that this subnet might need to be changed in the future when NetworkATC support AutoIP with customized subnet

                    [System.String] $tmpPhysicalAdapterName = $storageAdapter

                    # In case converged storage adapter, the test adapter is created with the name of the format of "vStorageTestNic(<PhysicalAdapterName>)".
                    if ($storageAdapter -match 'vStorageTestNic\(([^)]+)\)') {
                        $tmpPhysicalAdapterName = $matches[1]
                    }

                    # Determine IP subnet: use SAN pre-computed subnet info if available, otherwise default 10.71.{i}/24
                    [System.String] $tmpIpAddressToUse = ""

                    if ($SanAdapterSubnetInfo.Count -gt 0 -and $SanAdapterSubnetInfo.ContainsKey($tmpPhysicalAdapterName)) {
                        # SAN: generate a random IP within the adapter's subnet using the CIDR info
                        $sanInfo = $SanAdapterSubnetInfo[$tmpPhysicalAdapterName]
                        $subnetMask = $sanInfo.SubnetMask
                        $tmpIpAddressToUse = EnvValidatorNwkLibGenerateRandomIPInSubnet -CidrNotation "$($sanInfo.NetworkAddress)/$($sanInfo.PrefixLength)"

                        $retVal.DetailLog += "`r`n    SAN mode: using network $($sanInfo.NetworkAddress)/$($sanInfo.PrefixLength) for adapter $tmpPhysicalAdapterName, randomIP=$tmpIpAddressToUse"
                    } else {
                        $ip1stThreeOctet = "10.71.$($i)"
                        $ipLastOctet = [System.Random]::new().Next(1, 254)
                        $subnetMask = "255.255.255.0"
                        $tmpIpAddressToUse = "$($ip1stThreeOctet).$($ipLastOctet)"
                    }

                    $ipInfoToConfig = @{
                        "PhysicalNode" = $env:COMPUTERNAME
                        "IPV4Address" = $tmpIpAddressToUse
                        "SubnetMask" = $subnetMask
                    }

                    if ($StorageAdapterIpInfo.Count -gt 0) {
                        # $StorageAdapterIpInfo is provided, so user is using customized storage adapter IP (not using AutoIP)
                        # Need to use the IP info from the $StorageAdapterIpInfo hashtable
                        if ($StorageAdapterIpInfo.ContainsKey($tmpPhysicalAdapterName)) {
                            $ipInfoToConfig = $StorageAdapterIpInfo[$tmpPhysicalAdapterName] | Where-Object { $_.PhysicalNode -eq $env:COMPUTERNAME }
                        } else {
                            # If cannot find the storage adapter IP info for the current adapter, then the value is not passed in correctly.
                            # Should not come here as the input should already been validated before calling into this script block
                            # But just keep it here as a safe guard
                            throw "Cannot find storage adapter IP info for the adapter: $($tmpPhysicalAdapterName). Please check the input data."
                        }
                    }

                    $retVal.DetailLog += "`r`n    IP to be configured: $($ipInfoToConfig.IPV4Address)"

                    # Try to set the IP on the adapter
                    if ($StorageAdapterIpInfo.Count -eq 0) {
                        # if not using customized IP, will try to remove the IP from the adapter first, in case this is a retry attempt
                        $retVal.DetailLog += "`r`n    Clean existing IP address from the adapter"
                        Remove-NetIPAddress -InterfaceAlias $storageAdapter -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    }

                    $retVal.DetailLog += "`r`n    Setting IP address and clean default gateway from the adapter"
                    New-NetIPAddress -InterfaceAlias $storageAdapter -IPAddress $ipInfoToConfig.IPV4Address -AddressFamily IPv4 `
                                    -PrefixLength (EnvValidatorNwkLibConvertToPrefixLength -SubnetMask $ipInfoToConfig.SubnetMask) -ErrorAction SilentlyContinue | Out-Null

                    if($NetRoutes = Get-NetRoute -InterfaceAlias $storageAdapter -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue) {
                        foreach($NetRoute in $NetRoutes) {
                            Remove-NetRoute -InterfaceAlias $storageAdapter -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 -NextHop $NetRoute.NextHop
                        }
                    }

                    #region Wait for storage adapter to get IPv4 address configured correctly
                    $retVal.DetailLog += "`r`n    Wait up to 60 seconds till AddressState is Preferred and PrefixOrigin is Manual..."
                    $maxRetries = 12 # Maximum retries (60 seconds / 5 seconds per retry)
                    $retryCount = 0
                    while (-not $currentAdapterIPReady -and ($retryCount -lt $maxRetries)) {
                        # After New-NetIPAddress call, wait for 5 seconds and try to check the IP address state
                        Start-Sleep -Seconds 5
                        $tmpRst = FindExpectedIP -StorageAdapterName $storageAdapter -ExpectedIP $ipInfoToConfig.IPv4Address

                        if ($tmpRst.validIPv4Address.Count -eq 1) {
                            $currentAdapterIPReady = $true
                            break
                        } else {
                            $retryCount++
                        }
                    }
                    #endregion

                    if ($currentAdapterIPReady) {
                        $adapterIpv4AddressString = $tmpRst.validIPv4Address.IPAddress -join ", "
                    } else {
                        $adapterIpv4AddressString = $tmpRst.adapterIpv4Addresses.IPAddress -join ", "
                    }

                    # We might retry, so it is possible that the hashtable already has the entry for the adapter
                    if ($retVal.AdapterIPv4Mapping.containsKey($storageAdapter)) {
                        $retVal.DetailLog += "`r`n    Update existing adapter entry: $($storageAdapter) with IPv4 address: $($adapterIpv4AddressString), Valid: $($currentAdapterIPReady)"
                        $retVal.AdapterIPv4Mapping[$storageAdapter].IPv4Address = $adapterIpv4AddressString
                        $retVal.AdapterIPv4Mapping[$storageAdapter].Valid = $currentAdapterIPReady
                    } else {
                        $retVal.DetailLog += "`r`n    Add adapter entry: $($storageAdapter) with IPv4 address: $($adapterIpv4AddressString), Valid: $($currentAdapterIPReady)"
                        $retVal.AdapterIPv4Mapping.Add($storageAdapter, @{
                            IPv4Address = $adapterIpv4AddressString
                            Valid = $currentAdapterIPReady
                        })
                    }

                    if ($currentAdapterIPReady) {
                        $retVal.DetailLog += "`r`n    Found valid IPv4 address on the storage adapter $($storageAdapter)."
                        break
                    } else {
                        $retVal.DetailLog += "`r`n    Cannot find valid IPv4 address info on storage adapter $($storageAdapter)."
                        $retVal.DetailLog += "`r`n        Current IPAddress:    [ $($tmpRst.adapterIpv4Addresses.IPAddress -join ', ') ]"
                        $retVal.DetailLog += "`r`n        AddressState:         [ $($tmpRst.adapterIpv4Addresses.AddressState -join ', ') ]"
                        $retVal.DetailLog += "`r`n        PrefixOrigin:         [ $($tmpRst.adapterIpv4Addresses.PrefixOrigin -join ', ') ]"

                        # Try to remove the IP and try again
                        Remove-NetIPAddress -InterfaceAlias $storageAdapter -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

                        # We will wait for a random time between 5 to 10 seconds before next retry, so in case we have multiple deployment happened
                        # at the same time with same network, we can reduce the possible IP conflict.
                        $tmpSleepSecondsBetweenRetry = [System.Random]::new().Next(5, 10)
                        Start-Sleep -Seconds $tmpSleepSecondsBetweenRetry
                    }
                }

                # Adapter is considered not ready if it does not have an valid address or has more than one valid address after $maxSetIPRetries retries
                if (-not $currentAdapterIPReady) {
                    $retVal.Pass = $false
                }
            }

            return $retVal
        }

        # In case of VMSwitch creation scenario, the old PSSession might be in state of "Broken", so trying to re-open the session
        [System.Management.Automation.Runspaces.PSSession[]] $newTestSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $newTestSessionsBeforeChecking

        Log-Info "Configure and check IPv4 addresses on storage adapters across all nodes in parallel..."
        $allNodeIPv4Results = @(Invoke-Command -Session $newTestSessions -ScriptBlock $setAndCheckHostIPv4AddressScript `
                            -ArgumentList $allStorageAdaptersToCheck, $storageAdapterIpInfo, $sanAdapterSubnetInfo, `
                            $function:EnvValidatorNwkLibConvertToPrefixLength, $function:FindExpectedIP, `
                            $function:EnvValidatorNwkLibGenerateRandomIPInSubnet, $function:EnvValidatorNwkLibNormalizeIPv4Subnet, `
                            $function:EnvValidatorNwkLibGetNetworkAddress, $function:EnvValidatorNwkLibConvertIPAddressToInt, `
                            $function:EnvValidatorNwkLibConvertIntToIPAddressString)

        foreach ($storageAdapterIPv4ForCurrentNode in $allNodeIPv4Results) {
            Log-Info "$($storageAdapterIPv4ForCurrentNode.DetailLog)"

            $hostIPv4AddressTable.Add($storageAdapterIPv4ForCurrentNode.ComputerName, $storageAdapterIPv4ForCurrentNode.AdapterIPv4Mapping)
            $hostIPv4AddressList += $storageAdapterIPv4ForCurrentNode

            if (-not $storageAdapterIPv4ForCurrentNode.Pass) {
                Log-Info "Cannot find IPv4 address on storage adapter on $($storageAdapterIPv4ForCurrentNode.ComputerName). Will not run the validation."
                $usePingMeshOnIPv4 = $false
            } else {
                Log-Info "IPv4 address found on storage adapter on $($storageAdapterIPv4ForCurrentNode.ComputerName)."
            }
        }

        # Below checking should not needed as we assume the input data is in good shape, but keep it here
        # just in case there are something changed after the IP configured
        if ($storageAdapterIpInfo.Count -gt 0) {
            # If storage adapter IP info is provided, we will not make sure the IP we configured on the machine is the same as what we provided in the JSON
            # Need to compare $storageAdapterIpInfo with $hostIPv4AddressTable
            Log-Info "Storage adapter IP info is provided. Need to confirm the IP configured on machine is same as IP provided in answer file."

            # IP of each adapter defined in $storageAdapterIpInfo should have the same IP returned from $hostIpv4AddressTable
            foreach ($tmpAdapterName in $storageAdapterIpInfo.Keys) {
                foreach ($tmpIpInfoOnHost in $storageAdapterIpInfo[$tmpAdapterName]) {
                    $ipExpected = $tmpIpInfoOnHost.IPv4Address

                    [System.String] $ipConfiguredAdapterName = $tmpAdapterName

                    if ($needStorageVMSwitch) {
                        $ipConfiguredAdapterName = "vStorageTestNic($($tmpAdapterName))"
                    }

                    $ipConfigured = $hostIPv4AddressTable[$tmpIpInfoOnHost.PhysicalNode][$ipConfiguredAdapterName].IPv4Address

                    if ($ipExpected -ne $ipConfigured) {
                        Log-Info "Storage adapter IP info mismatch for adapter $tmpAdapterName on host $($tmpIpInfoOnHost.PhysicalNode). Expected: $ipExpected, Configured: $ipConfigured" -Type 'WARNING'
                        $usePingMeshOnIPv4 = $false
                        $hostIPv4AddressList += @{
                            ComputerName = $tmpIpInfoOnHost.PhysicalNode
                            Pass = $false
                            AdapterIPv4Mapping = @{$tmpAdapterName = @{IPv4Address = $ipConfigured; Valid = $false}}
                        }
                    }
                }
            }
        }

        if ($usePingMeshOnIPv4) {
            [System.Collections.Hashtable] $allHostStorageAdapterLinkConnections = @{}

            # Calculate link connections for switchless configuration only: for switched configuration, we always expect the storage
            # adapter with same name are in the same subnet, so don't need to generate the link connections.
            if (($storageNetworkDefinition.StorageAdapterIPInfo.Count -gt 0) -and $switchlessDeploy) {
                foreach ($adapterInfo in $storageNetworkDefinition) {
                    $adapterName = $adapterInfo.NetworkAdapterName

                    foreach ($storageAdapterIPInfoEntry in $adapterInfo.StorageAdapterIPInfo) {
                        $currentNode = $storageAdapterIPInfoEntry.PhysicalNode
                        $currentEntryPrefixLength = EnvValidatorNwkLibConvertToPrefixLength -SubnetMask $storageAdapterIPInfoEntry.SubnetMask
                        $currentSubnet = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$($storageAdapterIPInfoEntry.IPv4Address)/$($currentEntryPrefixLength)"

                        if (-not $allHostStorageAdapterLinkConnections.ContainsKey($currentNode)) {
                            $allHostStorageAdapterLinkConnections[$currentNode] = @()
                        }

                        $link = @{
                            SrcAdapter  = $adapterName
                            DestinationInfo = @()
                        }

                        foreach ($otherAdapter in $storageNetworkDefinition) {
                            foreach ($otherEntry in $otherAdapter.StorageAdapterIPInfo) {
                                $otherNode = $otherEntry.PhysicalNode
                                $otherEntryPrefixLength = EnvValidatorNwkLibConvertToPrefixLength -SubnetMask $otherEntry.SubnetMask
                                $otherSubnet = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$($otherEntry.IPv4Address)/$($otherEntryPrefixLength)"

                                if ($otherSubnet -eq $currentSubnet -and $otherNode -ne $currentNode)
                                {
                                    $link.DestinationInfo += @{
                                        DestNode    = $otherEntry.PhysicalNode
                                        DestAdapter = $otherAdapter.NetworkAdapterName
                                    }
                                }
                            }
                        }

                        $allHostStorageAdapterLinkConnections[$currentNode] += $link
                    }
                }
            } else {
                Log-Info "Switchless env: [ $switchlessDeploy ] - No need to calculate link connections."
            }

            $resolvedMaxParallelJobs = EnvValidatorNwkLibGetMaxParallelJobs -DefaultMaxParallelJobs 20

            $validationFunctionParams = @{
                allNodeSessions = $newTestSessions
                HostIPv4Table = $hostIPv4AddressTable
                HostStorageAdapterLinkConnections = $allHostStorageAdapterLinkConnections
                MaxParallelJobs = $resolvedMaxParallelJobs
            }

            $storageAdapterConnectionResults = ValidateStorageConnections @validationFunctionParams
        } else {
            Log-Info "No valid method available to test storage connection. Fail the validation." -Type 'WARNING'
            [PSObject[]] $failedResults = $hostIPv4AddressList | Where-Object { -not $_.Pass }
            foreach ($result in $failedResults) { # host
                foreach ($adapterName in $result.AdapterIPv4Mapping.Keys) { # storage adapter
                    if ($result.AdapterIPv4Mapping[$adapterName].Valid) {
                        # If the adapter has a valid IPv4 address, we will not report it as failure
                        continue
                    }

                    # Construct failure message
                    $targetResource = "$($result.ComputerName), $($adapterName)"
                    $tmpRemediationMsg = ""
                    $ips = $result.AdapterIPv4Mapping[$adapterName].IPv4Address
                    if ([string]::IsNullOrEmpty($ips)) {
                        $tmpRemediationMsg = "$targetResource does not have any IP addresses configured. The Storage adapter should be up, have up to one valid IPv4 address used for storage, and no other IP addresses."
                    } else {
                        $tmpRemediationMsg = "$targetResource has the following IP address(es) configured: [ $ips ]. DHCP should be disabled on the Storage adapter. It must have at most one single IPv4 address."
                    }

                    $storageAdapterConnectionRstObject = @{
                        Name               = "AzureLocal_Network_Test_StorageConnections_NoValidationMethod"
                        Title              = 'Validate that each Storage Adapter has a single IPv4 address for connectivity testing.'
                        DisplayName        = 'Validate that each Storage Adapter has a single IPv4 address for connectivity testing.'
                        Severity           = 'CRITICAL'
                        Description        = 'Each Storage Adapter must have exactly one IPv4 address and no other assigned IP addresses. The address is used to validate storage connectivity between nodes. The presence of DHCP IP addresses may interfere with connectivity tests.'
                        Tags               = @{}
                        Remediation        = "https://aka.ms/azurelocal/envvalidator/storageconnections"
                        TargetResourceID   = $targetResource
                        TargetResourceName = $targetResource
                        TargetResourceType = 'StorageAdapter'
                        Timestamp          = [datetime]::UtcNow
                        Status             = 'FAILURE'
                        AdditionalData     = @{
                            Source    = $targetResource
                            Resource  = 'StorageAdapter'
                            Detail    = $tmpRemediationMsg
                            Status    = 'FAILURE'
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }

                    $storageAdapterConnectionResults += New-AzStackHciResultObject @storageAdapterConnectionRstObject
                }
            }
        }

        return $storageAdapterConnectionResults
    } catch {
        $storageAdapterConnectionExceptionRstObject = @{
            Name               = "AzureLocal_Network_Test_StorageConnections_ExceptionFound"
            Title              = 'Exception found during storage connection validation.'
            DisplayName        = 'Exception found during storage connection validation.'
            Severity           = 'CRITICAL'
            Description        = 'Experienced exception during storage connection validation. Please check information in AdditionalData.Detail.'
            Tags               = @{}
            Remediation        = "https://aka.ms/azurelocal/envvalidator/storageconnections"
            TargetResourceID   = "StorageConnectionValidationException"
            TargetResourceName = "StorageConnectionValidationException"
            TargetResourceType = 'StorageAdapter'
            Timestamp          = [datetime]::UtcNow
            Status             = 'FAILURE'
            AdditionalData     = @{
                Source    = "StorageConnectionValidationException"
                Resource  = 'StorageConnectionValidationException'
                Detail    = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
                Status    = 'FAILURE'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $storageAdapterConnectionResults += New-AzStackHciResultObject @storageAdapterConnectionExceptionRstObject

        return $storageAdapterConnectionResults
    } finally {
        # Need to clean the storage vNIC
        Log-Info "Done with validation run. Now clean up test artifacts created during validation."

        # Exception might happen at a moment the original session is broken, so need to make sure the session is open before doing the clean up
        Log-Info "Make sure PSSession is ready for the clean up work..."
        [System.Management.Automation.Runspaces.PSSession[]] $newCleanupSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $newTestSessionsBeforeChecking

        Log-Info "Try to clean up storage vNIC and/or storage pNIC VLANID on [ $($newCleanupSessions.Count) ] nodes..."

        [System.Boolean] $needRemoveAutoIP = $false
        if ($StorageAdapterIpInfo.Count -eq 0) {
            $needRemoveAutoIP = $true
        }

        Log-Info "Working to remove storage vNIC and/or storage pNIC VLANID on all machines $($newCleanupSessions.ComputerName)"
        Invoke-Command -Session $newCleanupSessions -ScriptBlock {
            param(
                $allStorageAdaptersToCheck,
                $needStorageVMSwitch,
                $needRemoveAutoIP
            )

            foreach ($adapterName in $allStorageAdaptersToCheck) {
                if ($needRemoveAutoIP) {
                    # if not using customized IP, will try to remove the IP from the adapter first, in case this is a retry attempt
                    Remove-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                }

                Remove-VMNetworkAdapter -ManagementOS -Name $adapterName -ErrorAction SilentlyContinue
            }

            if (-not $needStorageVMSwitch) {
                foreach ($adapterName in $allStorageAdaptersToCheck) {
                    Set-NetAdapterAdvancedProperty -Name $adapterName -RegistryKeyword "VLANID" -RegistryValue 0 -ErrorAction SilentlyContinue
                }
            }

            # Device Management Service might need to be restarted to refresh the nic details
            # It also might not be there
            if (Get-Service -Name DeviceManagementService -ErrorAction SilentlyContinue) {
                Restart-Service -Name DeviceManagementService -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 20
            }
        } -ArgumentList @($allStorageAdaptersToCheck, $needStorageVMSwitch, $needRemoveAutoIP)

        Log-Info "    Done with clean up of vNIC on all machines $($newCleanupSessions.ComputerName)!"

        if ($needCleanUpStorageVMSwitch) {
            Log-Info "Need to clean up VMSwitch created during the validation"
            $cleanUpScript = {
                param (
                    [System.Boolean] $IsMgmtStorageConverged,
                    [System.String] $storageVMSwitchName,
                    [System.String[]] $adapterForStorageVMSwitch,
                    $mgmtVlanIdToRestore
                )

                Remove-VMSwitch -Name $storageVMSwitchName -Force

                if ($IsMgmtStorageConverged) {
                    # Only need to run below if converged intent contains mgmt intent
                    # Need to restore the mgmt VLANID on the mgmt adapter
                    if ($mgmtVlanIdToRestore -ne 0) {
                        Set-NetAdapterAdvancedProperty -Name $adapterForStorageVMSwitch -RegistryKeyword "VlanID" -RegistryValue $mgmtVlanIdToRestore
                    }

                    #region Wait for the NIC to get the IP address back
                    # In case of DHCP scenario, after VMSwitch removed, the pNIC might not get the IP address immediately
                    # Wait for some time (60 seconds) to make sure the new IP is settled correctly.
                    [System.Boolean] $currentIPReady = $false
                    $maxRetries = 20 # Maximum retries (60 seconds / 3 seconds per retry)
                    $retryCount = 0

                    while (-not $currentIPReady -and ($retryCount -lt $maxRetries)) {
                        # If the pNIC has Manual or Dhcp IPv4 address with "Preferred" state, we consider it as "ready"
                        [PSObject[]] $ipConfig = Get-NetIPAddress -InterfaceAlias $adapterForStorageVMSwitch -ErrorAction SilentlyContinue | Where-Object { ($_.PrefixOrigin -eq "Manual" -or $_.PrefixOrigin -eq "Dhcp") -and $_.AddressFamily -eq "IPv4" -and $_.AddressState -eq "Preferred" }

                        # $adapterForStorageVMSwitch contains all the pNIC that used in the VMSwitch, but we might only have one pNIC that
                        if ($ipConfig.Count -ge 1) {
                            $currentIPReady = $true
                            break
                        } else {
                            Start-Sleep -Seconds 3
                            $retryCount++
                        }
                    }
                    #endregion

                    if (-not $currentIPReady) {
                        # should not get into here, but keep it here for safety
                        $ipInfoAll = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table IPAddress, InterfaceAlias, PrefixLength, PrefixOrigin, AddressState -AutoSize
                        Write-Host "$($ipInfoAll | Out-String)"
                        Write-Host "Cannot get the IP address back to the pNIC after VMSwitch removed. Please check the system manually."
                        throw "Cannot get the IP address back to the pNIC after VMSwitch removed. Please check the system manually. IP info: $($ipInfoAll | Out-String)"
                    } else {
                        Write-Host "IP address back to the pNIC after VMSwitch removed. System is ready for connection."
                    }
                }

                # Same need to restart Device Management Service to refresh the nic details here
                if (Get-Service -Name DeviceManagementService -ErrorAction SilentlyContinue) {
                    Restart-Service -Name DeviceManagementService -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 20
                }
            }

            $mgmtVlanIdToRestore = 0

            if ($vmSwitchCreationInfo.MgmtVlanId) {
                Log-Info "Got valid MgmtVlanId from VMSwitch creation info. Will set mgmtVlanIdToRestore to: $($vmSwitchCreationInfo.MgmtVlanId)"
                $mgmtVlanIdToRestore = $vmSwitchCreationInfo.MgmtVlanId
            } else {
                Log-Info "Did not get a valid MgmtVlanId from VMSwitch creation info. Will not try to restore the mgmt VLANID on the pNIC."
            }

            if ($mgmtVlanIdToRestore -ne 0) {
                Log-Info "Need to restore management VLANID to: $mgmtVlanIdToRestore"
            }

            # Since we are changing the network configuration here (VMSwitch got removed), the PSSession might get disconnected.
            # So we will try to run the cleanup script on remote machine(s) first in parallel, and run the script directly on local machine.
            $localIPs = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq "Preferred" } | Select-Object -ExpandProperty IPAddress
            [System.Management.Automation.Runspaces.PSSession[]] $remoteCleanupSessions = @($newCleanupSessions | Where-Object {
                $_.ComputerName -ne $env:COMPUTERNAME -and
                $_.ComputerName -ne "localhost" -and
                $_.ComputerName -ne "127.0.0.1" -and
                $localIPs -notcontains $_.ComputerName
            })

            # Run VMSwitch cleanup on all remote nodes in parallel
            if ($remoteCleanupSessions.Count -gt 0) {
                Log-Info "Working to remove VMSwitch on remote machines $($remoteCleanupSessions.ComputerName -join ', ') in parallel..."
                Log-Info "    Might lost computer connection momentarily..."
                Invoke-Command -Session $remoteCleanupSessions -ScriptBlock $cleanUpScript -ArgumentList @($convergedMgmtStorageIntent, $storageVMSwitchName, $storageClusterNetworkAllPhysicalAdapters, $mgmtVlanIdToRestore)
                Log-Info "    Done with cleanup of VMSwitch on remote machines $($remoteCleanupSessions.ComputerName -join ', ')!"
            }

            # Finally run the execution on local machine to make sure the VMSwitch is removed
            Log-Info "Working to remove VMSwitch on local machine $($env:COMPUTERNAME)..."
            Invoke-command -ScriptBlock $cleanUpScript -ArgumentList @($convergedMgmtStorageIntent, $storageVMSwitchName, $storageClusterNetworkAllPhysicalAdapters, $mgmtVlanIdToRestore) -ErrorAction SilentlyContinue
            Log-Info "    Done with cleanup of VMSwitch on local machine $($env:COMPUTERNAME)!"
        } else {
            Log-Info "No VMSwitch created during the storage connection validation. Skip clean up."
        }

        Log-Info "[$($MyInvocation.MyCommand)] End function call."
    }
}

function CreateStorageVNIC {
    [CmdletBinding()]
    param (
        [System.String] $StorageVMSwitchName,
        [System.String[]] $StorageVNICNames,
        [System.Collections.Hashtable] $StorageAdapterVLANIDInfo,
        [System.Collections.Hashtable] $StorageVirtualNicPhysicalNicTeamMapping = @{}
    )

    Import-Module -Name DnsClient   -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
    Import-Module -Name Hyper-V     -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
    Import-Module -Name NetAdapter  -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
    Import-Module -Name NetTCPIP    -Verbose:$false -ErrorAction SilentlyContinue | Out-Null

    foreach ($tmpStorageVNIC in $StorageVNICNames) {
        Add-VMNetworkAdapter -ManagementOS -SwitchName $StorageVMSwitchName -Name $tmpStorageVNIC
        Get-NetAdapter -name "vEthernet ($($tmpStorageVNIC))" -ErrorAction SilentlyContinue | Rename-NetAdapter -NewName $tmpStorageVNIC
        Set-NetIPInterface -InterfaceAlias $tmpStorageVNIC -Dhcp Disabled
        Set-DnsClient -InterfaceAlias $tmpStorageVNIC -RegisterThisConnectionsAddress $false
        Set-VMNetworkAdapterIsolation -ManagementOS `
                                    -VMNetworkAdapterName $tmpStorageVNIC `
                                    -IsolationMode Vlan `
                                    -AllowUntaggedTraffic $true `
                                    -DefaultIsolationID $StorageAdapterVLANIDInfo[$tmpStorageVNIC]
        if ($StorageVirtualNicPhysicalNicTeamMapping.ContainsKey($tmpStorageVNIC)) {
            # Need to wait for some time to make sure the vNIC/WMI class is ready before setting the team mapping after isolation configured
            # Otherwise, we might get error like "No network adapter was found with the given criteria."
            Start-Sleep -Seconds 5
            Set-VMNetworkAdapterTeamMapping -ManagementOS `
                                        -VMNetworkAdapterName $tmpStorageVNIC `
                                        -PhysicalNetAdapterName $StorageVirtualNicPhysicalNicTeamMapping[$tmpStorageVNIC] `
                                        -ErrorAction SilentlyContinue
        }
    }
}

function FindExpectedIP {
    param(
        [System.String] $StorageAdapterName,
        [System.String] $ExpectedIP
    )

    Import-Module -Name NetTCPIP    -Verbose:$false -ErrorAction SilentlyContinue | Out-Null

    [PSObject[]] $adapterIpv4Addresses = $null

    # Using Get-NetIPConfiguration here as Get-NetIPAddress seems has issue while executed for local machine in Invoke-Command
    [PSObject[]] $adapterIpv4Addresses = (Get-NetIPConfiguration -InterfaceAlias $StorageAdapterName -ErrorAction SilentlyContinue).IPV4Address

    # Check if the adapter has ONLY a single valid address
    [PSObject[]] $validIPv4Address = $adapterIpv4Addresses | Where-Object { $_.AddressState -eq "Preferred" -and $_.PrefixOrigin -eq "Manual" -and $_.IPAddress -eq $ExpectedIP }

    return @{
        adapterIpv4Addresses = $adapterIpv4Addresses
        validIPv4Address = $validIPv4Address
    }
}

function ValidateStorageConnections
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Specify PSSession array of all validation session needed for ping mesh testing.")]
        [System.Management.Automation.Runspaces.PSSession[]] $AllNodeSessions,

        [Parameter(Mandatory = $true, HelpMessage = "Specify host IPV4 table of all nodes.")]
        [System.Collections.Hashtable] $HostIPv4Table,

        [Parameter(Mandatory = $false, HelpMessage = "Specify host IPV4 table of all nodes.")]
        [System.Collections.Hashtable] $HostStorageAdapterLinkConnections = @{},

        [Parameter(Mandatory = $false, HelpMessage = "Maximum number of parallel ping jobs per node.")]
        [System.UInt16] $MaxParallelJobs = 20
    )

    $retVal = @()

    Log-Info "Use ping mesh to check storage adapter connections."

    Log-Info "Run ping mesh on all nodes in parallel..."
    $allNodePingResults = @(Invoke-Command -Session $AllNodeSessions -ScriptBlock {
        param (
            $HostAdapterIPv4Table,
            $HostStorageAdapterLinkConnections,
            $EnvValidatorNwkLibInvokePingFunction,
            $EnvValidatorNwkLibInvokePingWithRetriesFunction,
            $MaxParallelJobs)

        # Make sure EnvValidatorNwkLibInvokePing function is available in the session
        New-Item -Path "Function:\EnvValidatorNwkLibInvokePing" -Value $EnvValidatorNwkLibInvokePingFunction -Force | Out-Null
        New-Item -Path "Function:\EnvValidatorNwkLibInvokePingWithRetries" -Value $EnvValidatorNwkLibInvokePingWithRetriesFunction -Force | Out-Null

        $sourceAdapterIPv4 = $HostAdapterIPv4Table[$ENV:COMPUTERNAME]

        $pingResults = @{
            SourceNode = $ENV:COMPUTERNAME
            AllSuccess = $true
            Results = @()
        }

        #region Phase 1: Collect all ping pairs into descriptors
        $pingPairs = @()

        if ($HostStorageAdapterLinkConnections.Count -eq 0) {
            # No storage adapter link connection defined, need to run a full ping mesh on storage adapters
            foreach ($destHost in $HostAdapterIPv4Table.Keys) {
                if ($destHost -ne $env:COMPUTERNAME) {
                    $destAdapterIPv4 = $HostAdapterIPv4Table[$destHost]

                    foreach ($adapter in $sourceAdapterIPv4.Keys) {
                        $pingPairs += @{
                            DestinationNode = $destHost
                            SourceAdapter = $adapter
                            DestinationAdapter = $adapter
                            SourceIPAddress = $sourceAdapterIPv4[$adapter].IPv4Address
                            DestinationIPAddress = $destAdapterIPv4[$adapter].IPv4Address
                        }
                    }
                }
            }
        } else {
            # Storage adapter link connections defined, need to use that data for ping test
            $storageConnectionInfoForCurrentNode = $HostStorageAdapterLinkConnections[$ENV:COMPUTERNAME]

            foreach ($adapterLinkInfo in $storageConnectionInfoForCurrentNode) {
                $sourceIp = $sourceAdapterIPv4[$adapterLinkInfo.SrcAdapter].IPv4Address
                $allDestinationForCurrentAdapter = $adapterLinkInfo.DestinationInfo

                foreach ($destinationInfo in $allDestinationForCurrentAdapter) {
                    $allAdapterIPv4OnDestHost = $HostAdapterIPv4Table[$destinationInfo.DestNode]
                    $destIp = $allAdapterIPv4OnDestHost[$destinationInfo.DestAdapter].IPv4Address

                    $pingPairs += @{
                        DestinationNode = $destinationInfo.DestNode
                        SourceAdapter = $adapterLinkInfo.SrcAdapter
                        DestinationAdapter = $destinationInfo.DestAdapter
                        SourceIPAddress = $sourceIp
                        DestinationIPAddress = $destIp
                    }
                }
            }
        }
        #endregion

        #region Phase 2: Execute all pings in parallel using Start-Job
        # Convert function script blocks to strings for safe serialization across job boundaries
        $pingFuncStr = $EnvValidatorNwkLibInvokePingFunction.ToString()
        $pingWithRetriesFuncStr = $EnvValidatorNwkLibInvokePingWithRetriesFunction.ToString()

        $pingJobScriptBlock = {
            param($DestIP, $SourceIP, $PingFuncStr, $PingWithRetriesFuncStr)

            $pingFunc = [scriptblock]::Create($PingFuncStr)
            $pingWithRetriesFunc = [scriptblock]::Create($PingWithRetriesFuncStr)

            New-Item -Path "Function:\EnvValidatorNwkLibInvokePing" -Value $pingFunc -Force | Out-Null
            New-Item -Path "Function:\EnvValidatorNwkLibInvokePingWithRetries" -Value $pingWithRetriesFunc -Force | Out-Null

            return (EnvValidatorNwkLibInvokePingWithRetries -Destination $DestIP -Source $SourceIP -RetryCount 15 -SleepSeconds 1)
        }

        $pingJobInfos = @()
        $inProgressJobList = @()
        $totalJobIdList = @()
        foreach ($pair in $pingPairs) {
            $job = Start-Job -ScriptBlock $pingJobScriptBlock -ArgumentList $pair.DestinationIPAddress, $pair.SourceIPAddress, $pingFuncStr, $pingWithRetriesFuncStr
            $pingJobInfos += @{ Job = $job; Pair = $pair }
            $inProgressJobList += $job
            $totalJobIdList += $job.Id

            if ($inProgressJobList.Count -ge $MaxParallelJobs) {
                # Throttle: wait for any one job to finish before starting the next
                $null = Wait-Job -Id @($inProgressJobList | ForEach-Object { $_.Id }) -Any
                # Remove all completed jobs from the in-progress list, not just the one
                # returned by Wait-Job, since multiple jobs may have finished between iterations
                $completedIds = @(Get-Job -Id @($inProgressJobList | ForEach-Object { $_.Id }) | Where-Object { $_.State -ne 'Running' } | ForEach-Object { $_.Id })
                if ($completedIds.Count -gt 0) {
                    $inProgressJobList = @($inProgressJobList | Where-Object { $_.Id -notin $completedIds })
                }
            }
        }

        # Wait for all remaining ping jobs to complete
        if ($totalJobIdList.Count -gt 0) {
            Wait-Job -Id $totalJobIdList | Out-Null
        }

        # Collect results from completed jobs
        foreach ($jobInfo in $pingJobInfos) {
            $pingSuccess = Receive-Job -Id $jobInfo.Job.Id
            $pair = $jobInfo.Pair

            $pingResult = [PSObject]@{
                Success = [bool]$pingSuccess
                DestinationNode = $pair.DestinationNode
                SourceAdapter = $pair.SourceAdapter
                DestinationAdapter = $pair.DestinationAdapter
                SourceIPAddress = $pair.SourceIPAddress
                DestinationIPAddress = $pair.DestinationIPAddress
            }

            if (-not $pingSuccess) {
                $pingResults.AllSuccess = $false
            }

            $pingResults.Results += $pingResult
        }

        # Clean up jobs
        if ($totalJobIdList.Count -gt 0) {
            Remove-Job -Id $totalJobIdList -Force -ErrorAction SilentlyContinue
        }
        #endregion

        return $pingResults
    } -ArgumentList $HostIPv4Table, $HostStorageAdapterLinkConnections, $function:EnvValidatorNwkLibInvokePing, $function:EnvValidatorNwkLibInvokePingWithRetries, $MaxParallelJobs)

    foreach ($nodePingRst in $allNodePingResults) {
        $validationRst = New-Object PSObject -Property @{
            Pass = $true
            Message = ""
        }

        if (-not $nodePingRst.AllSuccess) {
            $validationRst.Pass = $false
        }

        $totalCount = $nodePingRst.Results.Count
        $successCount = @($nodePingRst.Results | Where-Object { $_.Success -eq $true }).Count

        $detailMessage = "$($nodePingRst.SourceNode) ($successCount/$totalCount checks passed): "
        foreach ($result in $nodePingRst.Results) {
            if (-not $result.Success) {
                $validationRst.Pass = $false
                $detailMessage += "$($result.SourceAdapter)[$($result.SourceIPAddress)] to $($result.DestinationNode)/$($result.DestinationAdapter)[$($result.DestinationIPAddress)] = FAIL, "
            }
        }

        $validationRst.Message = $detailMessage.TrimEnd(', ').TrimEnd(': ')
        $validationRstStatus = if ($validationRst.Pass) { 'SUCCESS' } else { 'FAILURE' }
        $targetResourceId = "$($nodePingRst.SourceNode)"

        $storageAdapterConnectionRstObject = @{
            Name               = "AzureLocal_Network_Test_StorageConnections_ConnectivityCheck"
            Title              = "Validate that the Storage Adapters on each node can reach their connected adapters on other nodes."
            DisplayName        = "Validate that the Storage Adapters on each node can reach their connected adapters on other nodes."
            Severity           = 'CRITICAL'
            Description        = "The Storage Adapters on each node must be able to reach their connected adapters on other nodes, based on the expected network topology. This topology is determined by the Intent and Switch/Switchless configuration. Connectivity is tested using ICMP (ping) between the IP addresses of the Storage Adapters."
            Tags               = @{}
            Remediation        = "https://aka.ms/azurelocal/envvalidator/storageconnections"
            TargetResourceID   = $targetResourceId
            TargetResourceName = $targetResourceId
            TargetResourceType = 'StorageAdapterConnection'
            Timestamp          = [datetime]::UtcNow
            Status             = $validationRstStatus
            AdditionalData     = @{
                Source    = $targetResourceId
                Resource  = 'StorageAdapterConnection'
                Detail    = $validationRst.Message
                Status    = $validationRstStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $retVal += New-AzStackHciResultObject @storageAdapterConnectionRstObject

        Log-Info "    Finished processing ping results for $($nodePingRst.SourceNode)."
    }

    return $retVal
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDjzJvvlBli7+0h
# U4oyQ+ryBEuliaGgqA67FlOyUKZS56CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIOU4meRH
# /0IxrexLnwqKhYqQkDXpYZDavHFMUzIqHvrGMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAnbR00NGEr4MEm6rVFYW4D3jdKCDwEtuMHY6CuL4N
# jbg4Inu9O6/8yFka19XG5Bp1HdaiMCs7pTcKeTRq+mRkPs1XuTvPPux0rJ/81vQx
# 2Y4M5Tp2UWiEdT5hnP3KaaUjRYjUZ/NRJnKPeGShlQVJ9bGc6PMJ04ryOA6MVml8
# UrErSRvJvEJ5ofVbgSoR+cPdfwdLIDeogxChsY52UWfT1+csSFlSlwcUEajTcMrU
# 47Bozg5oGQA8VCUfOSEI5q1qCMdWoo9TSPdlCAsHqHkYIChQNiv4fH86Gw6+sEFE
# Nun5TfzpCzElr52ny3prRMhO4rMuJFGf6IgFu5YoY437kqGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAgkB14r4VRrDzBFuHa0ZehMWFSbHyU8fdvfBtU
# bHP46gIGaed8mPPrGBMyMDI2MDUwMzE0MzEwOS42MzdaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiWAxzfGzap3SQABAAAC
# JTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMDFaFw0yNzA1MTcxOTQwMDFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCm8RIP0eLA46VcCPovvmqsIlN6
# qkmz5IsHWmUU0neUqp8uGxadeo+SwWBCwQ5alZI/DNdpXfyiZLZR6XYgpRPFzepI
# l7OCDb4NtEskJCIZDkQMNwrH9YwUyu71GGigsLIxeleHtA3utoVTeHjS1b8UnwOR
# RtknKkyrUArT6ZpB2rodIcmcLcv3x3wwgYlOs0FEg5EsVrZb7LNc/nd0bXDp+HTO
# WWui8eoTVwJeLxcVP869oF8li5SU81aa2tGJ6/Jsejiz9JMW8SJXKBT2DCXMOUkC
# sGjonPZRqfvoMSIQZgtaOTyAJlrvsy0TZ78XrGqoygtQimQnbOAL4KNLSCuW5TZE
# QGTHLOQJGgggb3j5gKC778+RIPJA+n/hmHJ/x4qT/HTTPoVeMCcuBKWrQXR1+/pY
# au3Fwe0tWIyG+LWzkRr/ZNPPupcA2Yci3qn8HR9RwvQopqSNJwn2Ri6am8AQyfVV
# y/BBw0t6jpoRPjwKvuUjfCzpae6duOxQtQ1XDN9PA2yl9sDko/+AXV/SOe8ea8Qo
# Qcv3s3ErkG+Lp6hnvw6OMPian4ggNkRtgtB7ro1OiopOUXJn9Y5EO3JUAXNcuM9m
# +5My1VEuvGytgAH3uxmslTnW3YbrfazaySCSSnWkhaOZ33hgbuUQfH7n2NFEAUc/
# cFzfmCQUikWisnJYywIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFLE40qoXTuMHX3Af
# ZUu1n8nx2h93MB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQAHnfc2yUyoHZbvvyVK
# FuXh5HxxHIvIaR9JWpIfITJlc/Ki03juR+vckzq3tp5fFH5LL7eIFXRIuoewMsvW
# eFrWufrrW4HhmhCwkqArfA1C0xk+HaYs2O48YSxMX9lgS1kTTIb3YsfoFdFpKurP
# f2nc2Yd4wLg+FgwmkxkeyE3MUKVna8SZeVpEjnS5ucFck4srPwK2ORAf70I23GGy
# PhqgIKZphNXhSscTAQsyIqB5GwDMdRV5LK37NfU4YmxvCYh3TFYE/Gh01Q6yJvf9
# HxiEZpwW+oUk0gruHobg3sgIR5rfgUo8l30vUnaDYMcPAClaFMC/QbHZSaUhWXZG
# 1OOcMp0g9vYQNLDEqFX2jlquvzVSSwtHtm1KTldCjRED+kdCybcPxbPalwJigXc1
# BsI9CitnTf0ljwb9NkZ/JVI8/D62rXXzhz4F3u0iVGzwncGaxRxHG/Xv4nTrpkOe
# epoYbNBbMWS2G1qP3Xj7pVf0+4qRyAqJ0stjQjoVOJImVPWRjz5PR3Dn6adQVMBJ
# DM6gDrj1rZTFVgCtTijqGZSGzvXpGkF3vYsyE6ZDma/kGdiUe5saeI6lH66PiWWX
# gqxt7sy2Ezv0yIjSVv+eMOT2QMUiZ6WCc7gVtAmXpfeIus+NmgFvM+Ic1X58e4I9
# EL4ZSAidSpWW0GZTLNC02mryLjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg2MDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQBTb+bKOPAjCBflhzw5EXBuSWxeDqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aHLODAiGA8y
# MDI2MDUwMzEzMjUxMloYDzIwMjYwNTA0MTMyNTEyWjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtocs4AgEAMAoCAQACAgkSAgH/MAcCAQACAhPHMAoCBQDtoxy4AgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAJV8kMndt1RaS2RHUeu9bTv3Ooq4
# sbCHczveImmDaZD+9+5yDMK1aidKHx38eLL6OhoR6wOP5qVwJPtP+1vjgrzudRM2
# cYOfXx/mK6i0OAJhoHSi+zl3+ZvDfaFjkILB2GVwxapBD5pwSYhmZq2OBuNNCc84
# HylnTF24l0zhrn3np+buejMVsjljsyKbS2rT+WwxwzwwMVDkwyFzsV6zDjj5d156
# mVbKefzLvVlVu/gE034l9o+piJbyDU8g819ygwR+W4CkYPqR7HRz+Unboa4CFhQ4
# F8fABmMet/ssAoLdTx4QBcHmemqrmgsujRbR82BUVKpJSFPK+w2LhDbea7cxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiWA
# xzfGzap3SQABAAACJTANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCWsQQ9NDQs/FcH8p09F3kp6PPF
# TpdBa91ZdD+/u0DPIDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFYN7oh6
# ON3y92CmAl/lF0CYwrjWWQP6dCUxajPSHKEQMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIlgMc3xs2qd0kAAQAAAiUwIgQgOrqQiD8p
# rJMLOtfvraiqGafeCm8jnD39Hjc3g6/seDMwDQYJKoZIhvcNAQELBQAEggIAkukj
# ySDMf/iAoEuc2Td2wNXfpbpLLVthVizBLLwpAPsTafuuS3CxW2e+YMaGf8CSJLaF
# uGYA40mbOuNzWXNOiyAaXCi0IPzYUCCSiIafVVkYaBptbjyfvO/f7+aePmIT0R/L
# /JthYz6tttzmkBykE0XysA/FSljEwouftA4wOEgcZTWjle0j9a1Sj7wPhY1PGKBR
# cYxlt0r4o7aG7GrM3a7NSfA/IjweNYtGVfHRNSHwU63JMWW9z+ulQA+uI7Pvc2fl
# 9v/n08iqEa1i2+EqJmOr4YSLlvyOyVFh/oEifz3n7q1ixpllALeccDhllojaG11l
# /8HlzjOtpBqpS79iLUw0KH318inLUTmKWdt6iOcL/rmebI58jL4QVQkpJnEHNktk
# ID6JhnkE2l572KqLclaK63iWEgo+y889pZcQ7ydYxJKxH1hIO6pIKQlTs/4OLmsB
# leEHApnOQZbMgrXloIKp6Rhkg4d+/FxVOkSvv1ztnK7nJj9HfwwBpRc3S5K/yfGW
# ktfl87JXUp8FEoS+eT09wdQzN0s7s36WRqJAUmcRS/XZPONhdkD8dalCsWj8WGHk
# qtqhBgZtV1ZcVcpffzlbQYQuqlSp+5WTb0omo0aNjIPDTDnNgIV9gcm8P74EbAio
# j0UKtl1Uaxz529mKrSq1pH9PBkCFMhGgO3mAQV0=
# SIG # End signature block
