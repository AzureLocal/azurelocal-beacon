<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

################################################
####### Main functions below, exported #######
################################################
function EnvValidatorNwkLibCheckTcpConnectionWithRetries {
    <#
    Checks TCP connection to the given destination and port.
    #>
    param(
        [System.String] $SourceIp,
        [System.String] $DestinationIp,
        [System.Int16] $PortToCheck = 53,
        [System.Int16] $RetryTimes = 10,
        [System.Int16] $IntervalBetweenRetry = 3
    )

    [System.Boolean] $retVal = $false

    $retry = 1
    while ((-not $retVal) -and ($retry -le $RetryTimes)) {
        try {
            $src  = [System.Net.IPEndPoint]::new([ipaddress]::Parse($SourceIp),0)
            $tc   = [System.Net.Sockets.TcpClient]::new($src)
            $tc.Connect($DestinationIp, $PortToCheck)

            if ($tc.Connected) {
                Log-Info "            == TCP connection ESTABLISHED from $($SourceIp) to $($DestinationIp) port $($PortToCheck) on attempt $($retry)"
                $retVal = $true
                break
            } else {
                Log-Info "        ?? FAILED TCP connection from $($SourceIp) to $($DestinationIp) port $($PortToCheck) on attempt $($retry)"
            }
        } catch {
            Log-Info "        ?? FAILED! Got exception while checking TCP connection from $($SourceIp) to $($DestinationIp) port $($PortToCheck) on attempt ($($retry))!"
        } finally {
            if ($tc) {
                $tc.Dispose()
            }
        }

        Start-Sleep -Seconds $IntervalBetweenRetry
        $retry++
    }

    return $retVal
}

function EnvValidatorNwkLibConfigureVMSwitchForTesting {
    [CmdletBinding()]
    param
    (
        [System.String[]] $SwitchAdapterNames,
        [System.String] $MgmtIntentName = "",
        [System.String] $ExpectedVMSwitchName = "ConvergedSwitch($($MgmtIntentName))",
        [System.String] $ExpectedMgmtVNicName = "vManagement($($MgmtIntentName))"
    )

    Import-Module -Name Hyper-V     -Force -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
    Import-Module -Name NetAdapter  -Force -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
    Import-Module -Name NetTCPIP    -Force -Verbose:$false -ErrorAction SilentlyContinue | Out-Null

    [PSObject] $retVal = New-Object PSObject -Property @{
        VMSwitchInfo = $null
        MgmtVlanId = 0
        NeedCleanUp = $false
        IPReady = $false
    }

    # Make sure VMMS service is running
    [System.Boolean] $vmmsRunning = $false
    $vmmsStopWatch = [System.diagnostics.stopwatch]::StartNew()
    while (-not $vmmsRunning -and ($vmmsStopWatch.Elapsed.TotalSeconds -lt 60)) {
        [PSObject[]] $vmmsService = @()
        try {
            $vmmsService = Get-Service -Name "vmms" -ErrorAction SilentlyContinue
        } catch {
        }

        if ($vmmsService.Count -eq 1) {
            $vmmsRunning = $vmmsService[0].Status -eq "Running"
        }

        if ($vmmsRunning) {
            break
        } else {
            Restart-Service -Name vmms -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
    }

    $mgmtVlanId = 0
    $existingPhysicalNICVlanId = Get-NetAdapterAdvancedProperty -RegistryKeyword VlanID -Name $SwitchAdapterNames[0] -ErrorAction SilentlyContinue

    if ($existingPhysicalNICVlanId -and $existingPhysicalNICVlanId.RegistryValue) {
        $mgmtVlanId = $existingPhysicalNICVlanId.RegistryValue[0]
    }

    $tmpVMSwitch = New-VMSwitch -Name $ExpectedVMSwitchName -NetAdapterName $SwitchAdapterNames -EnableEmbeddedTeaming $true -AllowManagementOS $true

    if ($tmpVMSwitch) {
        $retVal.VMSwitchInfo = $tmpVMSwitch
        $retVal.MgmtVlanId = 0
        $retVal.NeedCleanUp = $true

        Get-VMNetworkAdapter -ManagementOS -Name $ExpectedVMSwitchName |  Rename-VMNetworkAdapter -NewName $ExpectedMgmtVNicName
        Get-NetAdapter -Name "vEthernet ($($ExpectedMgmtVNicName))" -ErrorAction SilentlyContinue | Rename-NetAdapter -NewName $ExpectedMgmtVNicName

        if ($mgmtVlanId -ne 0) {
            Set-VMNetworkAdapterIsolation -ManagementOS `
                                        -VMNetworkAdapterName $ExpectedMgmtVNicName `
                                        -IsolationMode Vlan `
                                        -AllowUntaggedTraffic $true `
                                        -DefaultIsolationID $mgmtVlanId

            # Save the VLAN ID info to return value
            $retVal.MgmtVlanId = $mgmtVlanId
        }

        # In case of DHCP scenario, the new adapter might not get the IP address immediately
        # Wait for some time (60 seconds) to make sure the new IP is settled correctly.
        [System.Boolean] $currentIPReady = $false
        $ipStopWatch = [System.diagnostics.stopwatch]::StartNew()
        while (-not $currentIPReady -and ($ipStopWatch.Elapsed.TotalSeconds -lt 60)) {
            # If the vNIC has Manual or Dhcp IPv4 address with "Preferred" state, we consider it as "ready"
            $ipConfig = Get-NetIPAddress -InterfaceAlias $ExpectedMgmtVNicName -ErrorAction SilentlyContinue | Where-Object { ($_.PrefixOrigin -eq "Manual" -or $_.PrefixOrigin -eq "Dhcp") -and $_.AddressFamily -eq "IPv4" -and $_.AddressState -eq "Preferred" }

            if ($ipConfig) {
                $currentIPReady = $true
                $retVal.IPReady = $true
                break
            } else {
                Start-Sleep -Seconds 3
            }
        }

        if (-not $currentIPReady) {
            # should not get into here, but keep it here for safety
            Write-Host "Cannot get the IP address bind to the vNIC after VMSwitch created. Please check the system manually."
        } else {
            Write-Host "[$($env:COMPUTERNAME)] VMSwitch created successfully. VMSwitch: $($ExpectedVMSwitchName), MgmtVNic: $($ExpectedMgmtVNicName)"
        }

        # We need to manually set the VLAN ID of the pNIC used in VMSwitch to 0 now, otherwise if the vNIC is using a different VLANID, the traffic will not go through
        # Ideally, pNIC should have correct VLAN ID configured and if that is the case, we don't need to set it to 0.
        # But we see some customers has the VLANID set incorrectly, causing the vNIC traffic not going through after we set the vNIC isolation ID.
        # So we want to set the VLAN ID of the pNIC to 0 after VMSwitch SET created.
        foreach ($tempPhysicalNIC in $SwitchAdapterNames) {
            Set-NetAdapterAdvancedProperty -Name $tempPhysicalNIC -RegistryKeyword "VLANID" -RegistryValue 0 -ErrorAction SilentlyContinue
        }
    }

    return $retVal
}

function EnvValidatorNwkLibConvertIPAddressToInt {
    param (
        [Parameter(Mandatory=$true)]
        [System.Net.IPAddress]
        $IPAddress
    )

    $bytes = $IPAddress.GetAddressBytes()
    [Array]::Reverse($bytes)

    return [BitConverter]::ToUInt32($bytes, 0)
}

function EnvValidatorNwkLibConvertToPrefixLength {
        param(
        [System.Net.IPAddress] $SubnetMask
    )

    $Bits = "$($SubnetMask.GetAddressBytes() | ForEach-Object {[Convert]::ToString($_, 2)})" -Replace '[\s0]'
    return $Bits.Length
}

function EnvValidatorNwkLibConvertPrefixLengthToSubnetMask {
    <#
    .SYNOPSIS
        Parses a CIDR string and returns the normalized network address and subnet mask.
    .DESCRIPTION
        Given a CIDR notation string (e.g. "10.10.30.5/24"), this function normalizes the
        network address (using EnvValidatorNwkLibNormalizeIPv4Subnet) and converts the prefix
        length to a subnet mask string. Returns a hashtable with NetworkAddress and SubnetMask.
    .PARAMETER CidrNotation
        IPv4 CIDR notation string, e.g. "10.10.30.0/24".
    .EXAMPLE
        $result = EnvValidatorNwkLibConvertPrefixLengthToSubnetMask -CidrNotation "10.10.30.5/24"
        # $result.NetworkAddress = "10.10.30.0"
        # $result.SubnetMask = "255.255.255.0"
        # $result.PrefixLength = 24
    #>
    param(
        [Parameter(Mandatory=$true)]
        [System.String] $CidrNotation
    )

    # Normalize the CIDR to get the correct network address
    $normalizedCidr = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet $CidrNotation
    $parts = $normalizedCidr -split '/'
    $networkAddress = $parts[0]
    $prefixLen = [int]$parts[1]

    # Convert prefix length to subnet mask
    $maskBits = [UInt32]::MaxValue -shl (32 - $prefixLen)
    $bytes = [System.BitConverter]::GetBytes($maskBits)
    [Array]::Reverse($bytes)
    $subnetMask = ([System.Net.IPAddress]$bytes).IPAddressToString

    return @{
        NetworkAddress = $networkAddress
        SubnetMask     = $subnetMask
        PrefixLength   = $prefixLen
    }
}

function EnvValidatorNwkLibGenerateRandomIPInSubnet {
    <#
    .SYNOPSIS
        Generates a random host IP address within the given CIDR subnet.
    .DESCRIPTION
        Accepts a CIDR notation string (which may not be normalized), validates and normalizes it,
        then returns a random usable host IP within that subnet. Network address and broadcast
        address are excluded.
    .PARAMETER CidrNotation
        IPv4 CIDR notation string, e.g. "10.10.30.5/24" or "192.168.1.0/28".
    .EXAMPLE
        $ip = EnvValidatorNwkLibGenerateRandomIPInSubnet -CidrNotation "10.10.30.5/24"
        # Returns a random IP like "10.10.30.142"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [System.String] $CidrNotation
    )

    # Normalize and parse the CIDR
    $normalizedCidr = EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet $CidrNotation
    $parts = $normalizedCidr -split '/'
    $networkAddress = $parts[0]
    $prefixLen = [int]$parts[1]

    if ($prefixLen -ge 31) {
        throw "Subnet /$prefixLen is too small to generate a random host IP. Minimum prefix length is /30."
    }

    $networkInt = EnvValidatorNwkLibConvertIPAddressToInt ([System.Net.IPAddress]::Parse($networkAddress))

    # Host range: network+1 to broadcast-1
    $hostCount = [Math]::Pow(2, (32 - $prefixLen)) - 2  # exclude network and broadcast
    $randomOffset = [System.Random]::new().Next(1, [int]$hostCount + 1)  # 1..hostCount inclusive

    $randomInt = $networkInt + [UInt32]$randomOffset
    return (EnvValidatorNwkLibConvertIntToIPAddressString $randomInt)
}

function EnvValidatorNwkLibCreateAtcHostIntentsInfoFromSystem {
    Import-Module -Name NetworkATC -Force -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null

    [PSObject[]] $atcHostIntents = Get-NetIntent
    [PSObject[]] $allIntentInfo = @()

    foreach ($intent in $atcHostIntents) {
        [PSObject] $currentIntentInfo = New-Object PSObject
        $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "Name" -Value $intent.IntentName

        [String[]] $currentIntentType = @()
        if ($intent.IsManagementIntentSet) { $currentIntentType += "Management" }
        if ($intent.IsStorageIntentSet) { $currentIntentType += "Storage" }
        if ($intent.IsComputeIntentSet) { $currentIntentType += "Compute" }
        $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "TrafficType" -Value $currentIntentType
        $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "Adapter" -Value $intent.NetAdapterNamesAsList

        # Check if the intent has any overrides, note that we only convert the overrides that we supported right now
        if (($null -ne $intent.AdapterAdvancedParametersOverride.NetworkDirect) -or ($null -ne $intent.AdapterAdvancedParametersOverride.JumboPacket)) {
            [PSObject] $tempAdapterOverride = New-Object PSObject

            if ($null -ne $intent.AdapterAdvancedParametersOverride.JumboPacket) {
                $tempAdapterOverride | Add-Member -MemberType NoteProperty -Name "JumboPacket" -Value $intent.AdapterAdvancedParametersOverride.JumboPacket
            } else {
                $tempAdapterOverride | Add-Member -MemberType NoteProperty -Name "JumboPacket" -Value $null
            }

            if ($null -ne $intent.AdapterAdvancedParametersOverride.NetworkDirect) {
                $tempAdapterOverride | Add-Member -MemberType NoteProperty -Name "NetworkDirect" -Value $intent.AdapterAdvancedParametersOverride.NetworkDirect
            } else {
                $tempAdapterOverride | Add-Member -MemberType NoteProperty -Name "NetworkDirect" -Value $null
            }

            if ($null -ne $intent.AdapterAdvancedParametersOverride.NetworkDirectTechnology) {
                $tempAdapterOverride | Add-Member -MemberType NoteProperty -Name "NetworkDirectTechnology" -Value $intent.AdapterAdvancedParametersOverride.NetworkDirectTechnology
            } else {
                $tempAdapterOverride | Add-Member -MemberType NoteProperty -Name "NetworkDirectTechnology" -Value $null
            }

            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "AdapterPropertyOverrides" -Value $tempAdapterOverride
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "OverrideAdapterProperty" -Value $true
        } else {
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "AdapterPropertyOverrides" -Value $null
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "OverrideAdapterProperty" -Value $false
        }

        if (($null -ne $intent.QosPolicyOverride.PriorityValue8021Action_SMB) -or ($null -ne $intent.QosPolicyOverride.PriorityValue8021Action_Cluster) -or ($null -ne $intent.QosPolicyOverride.BandwidthPercentage_SMB)) {
            [PSObject] $tempQosOverride = New-Object PSObject

            if ($null -ne $intent.QosPolicyOverride.PriorityValue8021Action_SMB) {
                $tempQosOverride | Add-Member -MemberType NoteProperty -Name "PriorityValue8021Action_SMB" -Value $intent.QosPolicyOverride.PriorityValue8021Action_SMB
            } else {
                $tempQosOverride | Add-Member -MemberType NoteProperty -Name "PriorityValue8021Action_SMB" -Value $null
            }

            if ($null -ne $intent.QosPolicyOverride.PriorityValue8021Action_Cluster) {
                $tempQosOverride | Add-Member -MemberType NoteProperty -Name "PriorityValue8021Action_Cluster" -Value $intent.QosPolicyOverride.PriorityValue8021Action_Cluster
            } else {
                $tempQosOverride | Add-Member -MemberType NoteProperty -Name "PriorityValue8021Action_Cluster" -Value $null
            }

            if ($null -ne $intent.QosPolicyOverride.BandwidthPercentage_SMB) {
                $tempQosOverride | Add-Member -MemberType NoteProperty -Name "BandwidthPercentage_SMB" -Value $intent.QosPolicyOverride.BandwidthPercentage_SMB
            } else {
                $tempQosOverride | Add-Member -MemberType NoteProperty -Name "BandwidthPercentage_SMB" -Value $null
            }

            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "QoSPolicyOverrides" -Value $tempQosOverride
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "OverrideQoSPolicy" -Value $true
        } else {
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "QoSPolicyOverrides" -Value $null
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "OverrideQoSPolicy" -Value $false
        }

        if (($null -ne $intent.SwitchConfigOverride.EnableIov) -or ($null -ne $intent.SwitchConfigOverride.LoadBalancingAlgorithm)) {
            [PSObject] $tempVMSwitchOverride = New-Object PSObject

            if ($null -ne $intent.SwitchConfigOverride.EnableIov) {
                $tempVMSwitchOverride | Add-Member -MemberType NoteProperty -Name "EnableIov" -Value $intent.SwitchConfigOverride.EnableIov
            } else {
                $tempVMSwitchOverride | Add-Member -MemberType NoteProperty -Name "EnableIov" -Value $null
            }

            if ($null -ne $intent.SwitchConfigOverride.LoadBalancingAlgorithm) {
                $tempVMSwitchOverride | Add-Member -MemberType NoteProperty -Name "LoadBalancingAlgorithm" -Value $intent.SwitchConfigOverride.LoadBalancingAlgorithm
            } else {
                $tempVMSwitchOverride | Add-Member -MemberType NoteProperty -Name "LoadBalancingAlgorithm" -Value $null
            }

            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "VirtualSwitchConfigurationOverrides" -Value $tempVMSwitchOverride
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "OverrideVirtualSwitchConfiguration" -Value $true
        } else {
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "VirtualSwitchConfigurationOverrides" -Value $null
            $currentIntentInfo | Add-Member -MemberType NoteProperty -Name "OverrideVirtualSwitchConfiguration" -Value $false
        }

        $allIntentInfo += $currentIntentInfo
    }

    return $allIntentInfo
}

function EnvValidatorNwkLibEnsureTestSessionOpen {
    <#
    .SYNOPSIS
    Make sure the test session is opened for the given PSSessions
    .DESCRIPTION
    Make sure the test session is opened for the given PSSessions. If the session is not opened, open a new session for it.
    .PARAMETER PSSessions
    The PSSessions to be checked
    .EXAMPLE
    EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSessions
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSessions
    )

    [System.Management.Automation.Runspaces.PSSession[]] $newTestSessionsAfterChecking = @()

    foreach ($testSession in $PSSessions) {
        [System.Management.Automation.Runspaces.PSSession] $sessionToReturn = $null
        Log-Info "[EnvValidatorNwkLibEnsureTestSessionOpen] Clean up PSSession on $($testSession.ComputerName) and create a new session"

        Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
        $sessionCredential = $testSession.Runspace.ConnectionInfo.Credential
        if ($sessionCredential) {
            $sessionToReturn = EnvValidatorNwkLibNewPsSessionWithRetries -Node $testSession.ComputerName -Credential $sessionCredential
        } else {
            $sessionToReturn = EnvValidatorNwkLibNewPsSessionWithRetries -Node $testSession.ComputerName
        }
        $newTestSessionsAfterChecking += $sessionToReturn
    }

    return $newTestSessionsAfterChecking
}

function EnvValidatorNwkLibGetIpRange {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Net.IPAddress] $StartingAddress,

        [Parameter(Mandatory = $false, HelpMessage = "Specify end Management IP Range")]
        [System.Net.IPAddress] $EndingAddress
    )

    try {
        # Convert to unsigned 32-bit integer
        $startInt = EnvValidatorNwkLibConvertIPAddressToInt -IPAddress $StartingAddress
        $endInt = EnvValidatorNwkLibConvertIPAddressToInt -IPAddress $EndingAddress

        # Build list of IPs
        [System.String[]] $range = @()

        for ($i = $startInt; $i -le $endInt; $i++) {
            [System.String] $currentIpString = EnvValidatorNwkLibConvertIntToIPAddressString -Value $i
            $range += $currentIpString
        }

        return $range
    } catch {
        throw "[EnvValidatorNwkLibGetIpRange] Failed to get management IP range for start IP $($StartingAddress) and end IP $($EndingAddress). Error: $_"
    }
}

function EnvValidatorNwkLibGetMgmtIpRangeFromPools {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify starting Management IP Range")]
        [System.Collections.ArrayList] $IpPools
    )

    $result = @()

    foreach ($ipPool in $IpPools) {
        $result += EnvValidatorNwkLibGetIpRange -StartingAddress $ipPool.StartingAddress -EndingAddress $ipPool.EndingAddress
    }

    return $result
}

function EnvValidatorNwkLibGetNetworkAddress {
    param (
        [Parameter(Mandatory=$true)]
        [System.Net.IPAddress]
        $IPAddress,

        [Parameter(Mandatory=$true)]
        [UInt32]
        $PrefixLength
    )

    $value = EnvValidatorNwkLibConvertIPAddressToInt $IPAddress

    $networkMask = [Convert]::ToUInt32(("1" * $PrefixLength).PadRight(32, "0"), 2)
    $transformedValue = $value -band $networkMask

    return (EnvValidatorNwkLibConvertIntToIPAddressString $transformedValue)
}

function EnvValidatorNwkLibGetSortedMgmtIntentAdapter {
    param (
        [System.String[]] $MgmtAdapterNames
    )
    # Re-arrange the order in $MgmtAdapterNames to make sure the nic having a valid IPv4 address appears before the other NIC in the array
    $mgmtNicNamesTemp = [System.Collections.ArrayList] $MgmtAdapterNames

    foreach($name in $MgmtAdapterNames) {
        $a = Get-NetIPAddress -InterfaceAlias $name -AddressFamily ipv4 -Type Unicast -AddressState Preferred -PrefixOrigin Dhcp -ErrorAction SilentlyContinue
        $b = Get-NetIPAddress -InterfaceAlias $name -AddressFamily ipv4 -Type Unicast -AddressState Preferred -PrefixOrigin Manual -ErrorAction SilentlyContinue
        if (($null -ne $a) -or ($null -ne $b)) {
            # move the NIC name to the top
            $mgmtNicNamesTemp.Remove($name)
            $mgmtNicNamesTemp.Insert(0, $name)
            break
        }
    }

    [System.String[]] $retVal = [System.String[]] $mgmtNicNamesTemp

    return $retVal
}

function EnvValidatorNwkLibInvokePing {
    <#
    Runs ping command with the given parameters and returns the result. This wrapper allows ping to be mocked.
    #>
    param(
        [string]$Destination,
        [string]$Source,
        [int]$Count = 2,
        [int]$TimeoutMs = 2000
    )
    return ping $Destination -S $Source -n $Count -w $TimeoutMs
}

function EnvValidatorNwkLibInvokePingWithRetries {
    <#
    Runs ping command with retries. This wrapper allows mocking without waiting for the timeout.
    #>
    param(
        [string]$Destination,
        [string]$Source,
        [int]$Count = 1,
        [int]$TimeoutMs = 2000,
        [int]$RetryCount = 10,
        [int]$SleepSeconds = 1
    )

    # By default ping timeout is 2000, with a sleep of 1 second, so each ping iteration will take 3 seconds
    # With a default of 10 retries, the total time for ping will be 30 seconds
    [System.Boolean] $pingSuccess = $false
    $retry = 0
    while (-not $pingSuccess -and ($retry -lt $RetryCount)) {
        $output = EnvValidatorNwkLibInvokePing -Destination $Destination -Source $Source -Count $Count -TimeoutMs $TimeoutMs
        try {
            $pingSuccess = $output | Select-String "Reply from $($Destination): bytes=" -Quiet
        } catch {
            $pingSuccess = $false
        }

        if ($pingSuccess) {
            break
        } else {
            $retry++
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    return $pingSuccess
}

function EnvValidatorNwkLibNormalizeIPv4Subnet {
    param (
        [Parameter(Mandatory=$true)][string]$cidrSubnet
    )

    # $cidrSubnet is IPv4 subnet in CIDR format, such as 192.168.10.0/24
    $subnet, $prefixLength = $cidrSubnet.Split('/')

    $addr = $null
    if (([System.Net.IPAddress]::TryParse($subnet, [ref]$addr) -ne $true) -or ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork)) {
        throw "$subnet is not a valid IPv4 address."
    }

    if ([System.Int16] $prefixLength -lt 0 -or [System.Int16] $prefixLength -gt 32) {
        throw "$prefixLength is not a valid IPv4 subnet prefix-length."
    }

    $networkAddress = EnvValidatorNwkLibGetNetworkAddress $subnet $prefixLength

    return $networkAddress.ToString() + '/' + $prefixLength
}

function EnvValidatorNwkLibTryCreateNewPsSessionOnNode {
    param (
        [System.String] $NodeName,
        [System.String] $NodeIP,
        [PSCredential] $ConnectionDomainAdminCredential = $null,
        [PSCredential] $ConnectionLocalAdminCredential = $null,
        [System.String] $DeployADLess = "false"
    )

    Import-Module -Name Microsoft.WSMan.Management -Force -Verbose:$false -ErrorAction SilentlyContinue | Out-Null

    # LocalAdmin ECE store container is wiped post deployment and scaleout. This is AD'less Update path. Use implicit credential.
    if ($DeployADLess -eq "true" -and $null -eq $ConnectionLocalAdminCredential) {
        return EnvValidatorNwkLibNewPsSessionWithRetries -Node $NodeIP
    }

    # Test-WSMan with domain credentials and capture any errors e.g. access denied, connectivity etc..
    # Testing WSMan to $NodeIP with domain credentials $($domainCredential.UserName)"
    try {
        Test-WSMan -ComputerName $NodeIP -Credential $ConnectionDomainAdminCredential -Authentication Default -ErrorAction Stop | Out-Null
        $credential = $ConnectionDomainAdminCredential
    } catch {
        # if local admin is null, the above should not error.
        # troubleshooting should be performed on secrets and PsSession creation.
        if ($null -eq $ConnectionLocalAdminCredential) {
            throw "Unable to create a valid session to $NodeIP with domain credentials. Ensure domain credential in ECE store is correct and can establish a PsSession to $NodeIP. Error: $($_.Exception.Message)"
        } else {
            $credential = $ConnectionLocalAdminCredential
        }
    }

    # Try to connect to IP first
    try {
        $PsSession = EnvValidatorNwkLibNewPsSessionWithRetries -Node $NodeIP -Credential $credential
        return $PsSession
    } catch {
        # As a last resort, try to connect with node name
        $PsSession = EnvValidatorNwkLibNewPsSessionWithRetries -Node $NodeName -Credential $credential
        return $PsSession
    }
}

function EnvValidatorNwkLibNewPsSessionWithRetries {
    [CmdletBinding()]
    Param (
        [System.String] $Node,
        [PSCredential] $Credential = $null,
        [System.Int16] $Retries = 60,
        [System.Int16] $WaitSeconds = 10
    )

    for ($i=1; $i -le $Retries; $i++) {
        try {
            if ($Credential) {
                #Log-Info "Creating PsSession ($i/$retries) to $Node as $($Credential.UserName)..."
                $psSessionCreated = Microsoft.PowerShell.Core\New-PSSession -ComputerName $Node -Credential $Credential -ErrorAction Stop
            } else {
                #Log-Info "Creating PsSession ($i/$retries) to $Node with implicit credential..."
                $psSessionCreated = Microsoft.PowerShell.Core\New-PSSession -ComputerName $Node -ErrorAction Stop
            }

            $computerNameFromSession = Microsoft.PowerShell.Core\Invoke-Command -Session $psSessionCreated -ScriptBlock { $ENV:COMPUTERNAME } -ErrorAction Stop
            $isAdminSession = Microsoft.PowerShell.Core\Invoke-Command -Session $psSessionCreated -ScriptBlock {
                ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
            } -ErrorAction Stop

            if (-not $isAdminSession) {
                throw ("PsSession was successful but user: {0} is not an administrator on computer {1} " -f $psSessionCreated.Runspace.ConnectionInfo.Credential.Username, $computerName)
            } else {
                #Log-Info "PsSession to $Node is an administrator session."
            }

            break
        } catch {
            #Log-Info "Creating PsSession ($i/$Retries) to $Node failed: $($_.exception.message)"
            $errMsg = $_.ToString()
            Start-Sleep -Seconds $WaitSeconds
        }
    }

    if ($psSessionCreated -and $computerNameFromSession -and $isAdminSession) {
        #Log-Info ("PsSession to {0} created after {1} retries. (Remote machine name: {2})" -f $Node, ("$i/$retries"), $computerNameFromSession)
        return $psSessionCreated
    } else {
        throw "Unable to create a valid session to $Node`: $errMsg"
    }
}

####################################################
####### Helper functions below, not exported #######
####################################################
function EnvValidatorNwkLibConvertIntToIPAddressString {
    param (
        [Parameter(Mandatory=$true)]
        [UInt32]
        $Value
    )

    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)

    # Construct new IPAddress object from byte array.
    # ', ' construct is used to wrap $bytes array into another array to prevent treating each byte as a separate argument.
    $ipAddress = New-Object System.Net.IPAddress -ArgumentList (, $bytes)

    return $ipAddress.IPAddressToString
}

function EnvValidatorNwkLibGetWinProxyConfiguration {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("WinHttp", "WinInet")]
        [System.String] $ProxyType
    )

    [System.Collections.Hashtable] $getParameter = @{}
    [System.String] $matchString = ""

    switch ($ProxyType) {
        "WinHttp" {
            $getParameter = @{ Default = $true }
            $matchString = "Proxy Server\(s\)\s*:\s*(.+)"
        }
        "WinInet" {
            $getParameter = @{ Advanced = $true }
            $matchString = "^Proxy\s*:\s*(.+)$"
        }
        Default {
            throw "Unsupported ProxyType: $ProxyType"
        }
    }

    Import-Module WinHttpProxy -Verbose:$false *>$null
    $proxySetting = Get-WinHttpProxy @getParameter
    $proxyHttp = ""
    $proxyHttps = ""

    foreach ($setting in $proxySetting) {
        if ($setting -match $matchString) {
            $rawProxies = $Matches[1].Trim()
            $proxyServers = $rawProxies -split ';'
            foreach ($server in $proxyServers){
                if($server -like "*http=*") {
                    $proxyHttp = $server -split "=", 2 | Select-Object -Last 1
                    $proxyHttp = $proxyHttp.Trim()
                } elseif($server -like "*https=*") {
                    $proxyHttps = $server -split "=", 2 | Select-Object -Last 1
                    $proxyHttps = $proxyHttps.Trim()
                } else {
                    # Single proxy applies to both
                    $proxyHttp = $server.Trim()
                    $proxyHttps = $proxyHttp
                }
            }
        }
    }

    # Construct the proxy settings object to return
    $proxySettings = @{
        HttpProxy       = $proxyHttp
        HttpsProxy      = $proxyHttps
        ProxyIsEnabled  = -not [string]::IsNullOrEmpty($proxyHttp)
    }

    return $proxySettings
}

function EnvValidatorNwkLibGetMaxParallelJobs
{
    <#
    .SYNOPSIS
    Reads a MaxParallelJobs override from a well-known file, falling back to a caller-supplied default.

    .DESCRIPTION
    Looks for 'networkmaxparallel.txt' in the AzStackHci.EnvironmentChecker root folder
    ($PSScriptRoot\..). If the file exists and contains a valid positive integer, that value
    is returned. Otherwise the DefaultMaxParallelJobs value is returned.

    .PARAMETER DefaultMaxParallelJobs
    The fallback value to use when the override file is missing or contains invalid content.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [int] $DefaultMaxParallelJobs
    )

    $overrideFileName = 'networkmaxparallel.txt'
    $overrideFilePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..') -ChildPath $overrideFileName

    if (Test-Path -Path $overrideFilePath -PathType Leaf)
    {
        try
        {
            $content = (Get-Content -Path $overrideFilePath -Raw).Trim()
            $parsedValue = 0
            if ([int]::TryParse($content, [ref]$parsedValue) -and $parsedValue -gt 0)
            {
                Log-Info "Using MaxParallelJobs override from '$overrideFilePath': $parsedValue"
                return $parsedValue
            }
            else
            {
                Log-Info "Invalid content in '$overrideFilePath': '$content'. Using default: $DefaultMaxParallelJobs" -Type 'WARNING'
            }
        }
        catch
        {
            Log-Info "Failed to read '$overrideFilePath': $_. Using default: $DefaultMaxParallelJobs" -Type 'WARNING'
        }
    }

    return $DefaultMaxParallelJobs
}

Export-ModuleMember -Function EnvValidatorNwkLibCheckTcpConnectionWithRetries
Export-ModuleMember -Function EnvValidatorNwkLibConfigureVMSwitchForTesting
Export-ModuleMember -Function EnvValidatorNwkLibConvertIntToIPAddressString
Export-ModuleMember -Function EnvValidatorNwkLibConvertIPAddressToInt
Export-ModuleMember -Function EnvValidatorNwkLibConvertToPrefixLength
Export-ModuleMember -Function EnvValidatorNwkLibConvertPrefixLengthToSubnetMask
Export-ModuleMember -Function EnvValidatorNwkLibCreateAtcHostIntentsInfoFromSystem
Export-ModuleMember -Function EnvValidatorNwkLibEnsureTestSessionOpen
Export-ModuleMember -Function EnvValidatorNwkLibGenerateRandomIPInSubnet
Export-ModuleMember -Function EnvValidatorNwkLibGetIpRange
Export-ModuleMember -Function EnvValidatorNwkLibGetMaxParallelJobs
Export-ModuleMember -Function EnvValidatorNwkLibGetMgmtIpRangeFromPools
Export-ModuleMember -Function EnvValidatorNwkLibGetNetworkAddress
Export-ModuleMember -Function EnvValidatorNwkLibGetSortedMgmtIntentAdapter
Export-ModuleMember -Function EnvValidatorNwkLibGetWinProxyConfiguration
Export-ModuleMember -Function EnvValidatorNwkLibInvokePing
Export-ModuleMember -Function EnvValidatorNwkLibInvokePingWithRetries
Export-ModuleMember -Function EnvValidatorNwkLibNewPsSessionWithRetries
Export-ModuleMember -Function EnvValidatorNwkLibNormalizeIPv4Subnet
Export-ModuleMember -Function EnvValidatorNwkLibTryCreateNewPsSessionOnNode

# SIG # Begin signature block
# MIInRgYJKoZIhvcNAQcCoIInNzCCJzMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBuYYSKK7Os0lV8
# MZS5yCo6sWYr+cLVLxtgje+e0WdboKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghniMIIZ3gIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIF1dLNG7
# tI+rxya4HDqgx07G5CRR0mfJlWXUK5i11GScMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAmgSfFLT+eVWUK+lbHQYvwpdQsn91SnqMc52CicpT
# 2aZPgyroZhzkO76cdFEgQ52sRQeWpdljyetaAmc2wm+LgthCFIAZCnwRDP3TMpFK
# uf7E6BvmhTFJaYdMcm5cF5Wkb+i6+I/79l7Q3DNm4VtCV0SX8WLKO9ivgvCis1HY
# qtMga8XITYNTEroG0Kpf1Q+FnptOndIWcMdvJ8bk+UwDEWKVfhCBn6/aAy5aBpFk
# Rd+1fkHioesbP/3UbFJW4GRiQ56JGGUV6sDTwR8qXJhWFncUUhD//JWimX9haicG
# UvZtBglR+uQDyIRaa3zBe396EEppii662t/wVptlXJcNmqGCF5QwgheQBgorBgEE
# AYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDD5xtMo81Ude2SIaEq/+L/Df91ckhlUU3OMgho
# rYBy8AIGaeeNG/HsGBMyMDI2MDUwMzE0MzEzMC4yOTlaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgITMwAAAiQ7hCGwLKxkIgABAAAC
# JDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTlaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj6W3UaQ2Zr4hNvSy7j7UMPFVy
# s7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrLQCOZcgLvz6FkqmghzQxzmkgK
# tLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcViBX4LcHk38RusZiF7wxSa5t/
# Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9pU9uriGdDxfJXn/lc49CxbXq
# A3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfdrA29sWTSNKig9CtBC5tzQj0f
# lbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjlyUP9ZO38839NwSuiHtvsFCNk
# TNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PDERyrAs0pvfUWOLapVQajHPoC
# nuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8WwBtk3Yxyhjj0GXw909i0EkTk
# Vyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1YGnYwCjIwa5/lMW0pFn/HpJdB
# 6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v3E9kwN9VBC+wJESBECC1gZMC
# S5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3SNt0a0Q5Nc2Ul+rMlQxXoP9i
# sXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFHMfkX1u/zJLCMe0
# gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQA+wHSbmhIpM8CRVZ4t
# k624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko6diEDHXPNWvAagxastCewPzm
# 5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/Fwps1sbNUEu7Bzg004qULIVJ
# 963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQTHZgwuNB6QhcEEsgogLVwNRj3
# 7VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi6jlcfqfo619uDH9r8k2qAOHC
# eEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilUSon07wjHu0e0ssBmtBafPb4G
# d+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oczxC/4JT3Hf45JEtszToXwNsk
# V3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGElPl5GRoPtJiDEvRIbv5MFKIw
# 2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOkX4ug0/0mN2CSarhuSi9NmHIO
# pUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1objAGKdWMPCrlSyNAs0jZYzkh
# a535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbUVqMU1OrQbHfdyzJpbhJC1PbA
# ZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# VTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+46CBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aEy/DAiGA8y
# MDI2MDUwMzAyMzU0MFoYDzIwMjYwNTA0MDIzNTQwWjB0MDoGCisGAQQBhFkKBAEx
# LDAqMAoCBQDtoTL8AgEAMAcCAQACAg/aMAcCAQACAhIOMAoCBQDtooR8AgEAMDYG
# CisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEA
# AgMBhqAwDQYJKoZIhvcNAQELBQADggEBAL9QPClikC5HBBjkEV8kQCdOYgladCEK
# OVxs6xbIHbuWlp0Zx98nC6OKdOCDGy6v72cKF73oTc+MJIyg+V9MC5amxJhbOexC
# 6UhDv2K0e2UO29hd6bLMwJNSOG2cikQtrCx2HwUFMfA0cL5/v5JkCrGVOMC9+dqO
# l3UGJV2kDyUveA8XZTcOfE0uxhBi9WqI3+2o35c0pirxSDZ+e4a0Y1kfCvmV8SKX
# 03/4OobFPRKBe3Zen5G3X4q6a0kwFdb20958JGDQIOztpc1e9ozHpvw6EaLGJQf1
# XBgPBcpQHUAPzG2cxa2bFdeczcOxTadb9fhz54UjiqP4PlAqI2nMi0gxggQNMIIE
# CQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYw
# JAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiQ7hCGw
# LKxkIgABAAACJDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDUMKbyEV7nzcnOt0Aex8VCkZnGs3Dt
# z09ZPKf/lg5lqDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEghPTdqm/dR
# yZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGYMIGApH4wfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCysZCIAAQAAAiQwIgQgA//oxm2fo5LO
# mmtYNHLZwfdHBrA0Jfu1dxOXSFqdBYowDQYJKoZIhvcNAQELBQAEggIATxgqnAZ/
# vcDJtizaA9geg06xKIkdx3/1/Z7WXpUHAfIkMp+J+wIBru4fkLXlrx6R2UjaiDHt
# XZaeeKdHWL8BrTZcf2V3yJyPHXGhxTl/Wk+2k9nm7/fzKIg+YMsQVaHnmRokLQ5z
# AiCyHPj37qETJh/FaH7D/W40zIlDf+LqojlLb5r4TfXuxdRjdIe493TdkLTu2752
# rlYGYhRwOpdjTyfgz8uoA6PF6BAXDg8NvRi+/vQQAaU/jAVknP9kx+YcPTLItlft
# npWxm3fe1FkZ1yt8wqeSzrpUDxV0Bf+6iOjk/AYsJ/bTQGX1x53xC4lPpTfQwA+H
# mcbfvzq2Ko6sfPXn2nYvr6ATRx9I2p4mOppwUP5xX0xdc0m7kmkQfB6s3r306Gud
# h9074eyLG+kWAUVlRBOyDrIXReVD0fw0L6aKOsZMPIUJ/YWqnijr/HZyzGS6DFQF
# UsC+ejH32z4LbfMi0VyEyHDFd6uJmO27db7yz7sjMwVa5ug5BbPi6v3KRU8R0Ij1
# 4b+APlkiZoE52+8Gq3ngzvRV4oaKP/97Ew+Jk9GcNwVzPvbx7akpiKlR6iBGs1Pz
# RYheL9BQ9d2QXdnP+pVtJY58Hb1QGQj/zcplw8dnTntlDJ81ntt4i65cj+kUzR2H
# FdqyjG5r6sHB6AjLcGGzSqdQEbgI32AAtuY=
# SIG # End signature block
