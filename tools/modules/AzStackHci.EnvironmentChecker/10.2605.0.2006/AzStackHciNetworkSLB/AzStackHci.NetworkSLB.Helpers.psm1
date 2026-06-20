Import-LocalizedData -BindingVariable slbTxt -FileName AzStackHci.NetworkSLB.Strings.psd1
Import-Module $PSScriptRoot\..\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -DisableNameChecking -Global | Out-Null

Set-Variable -Name StatusSuccess -Value "SUCCESS" -Option ReadOnly
Set-Variable -Name StatusFailure -Value "FAILURE" -Option ReadOnly

Set-Variable -Name TypeSDN -Value "SDNIntegration" -Option ReadOnly
Set-Variable -Name TypeSLB -Value "SoftwareLoadBalancer" -Option ReadOnly
Set-Variable -Name TypeNetworks -Value "Networks" -Option ReadOnly

Set-Variable -Name TypeHNVPA -Value "HNVPA" -Option ReadOnly
Set-Variable -Name TypePublicVIP -Value "PublicVIP" -Option ReadOnly
Set-Variable -Name TypePrivateVIP -Value "PrivateVIP" -Option ReadOnly

Set-Variable -Name PropertyName -Value "Name" -Option ReadOnly
Set-Variable -Name PropertySubnets -Value "Subnets" -Option ReadOnly
Set-Variable -Name PropertyAddressPrefix -Value "AddressPrefix" -Option ReadOnly
Set-Variable -Name PropertyVlanId -Value "VlanId" -Option ReadOnly
Set-Variable -Name PropertyDefaultGateways -Value "DefaultGateways" -Option ReadOnly
Set-Variable -Name PropertyIPPools -Value "IPPools" -Option ReadOnly
Set-Variable -Name PropertyNumberOfMuxes -Value "NumberOfMuxes" -Option ReadOnly
Set-Variable -Name PropertyBGPInfo -Value "BGPInfo" -Option ReadOnly
Set-Variable -Name PropertyLocalASN -Value "LocalASN" -Option ReadOnly
Set-Variable -Name PropertyPeerRouterConfigurations -Value "PeerRouterConfigurations" -Option ReadOnly
Set-Variable -Name PropertyPeerASN -Value "PeerASN" -Option ReadOnly
Set-Variable -Name PropertyRouterIPAddress -Value "RouterIPAddress" -Option ReadOnly
Set-Variable -Name PropertyStartIPAddress -Value "StartIPAddress" -Option ReadOnly
Set-Variable -Name PropertyEndIPAddress -Value "EndIPAddress" -Option ReadOnly

#################################################################################################
# SLB Validators
#   - Test-SLB_ValidateNumberOfSLBNodes
#   - Test-SLB_ValidateFCNCInstalled
#   - Test-SLB_ValidateBGPPeersReachable
#   - Test-SLB_ValidateHNVPANetwork
#   - Test-SLB_ValidatePublicPrivateVIPNetworks
#   - Test-SLB_ValidateSoftwareLoadBalancer
#   - Test-SLB_ValidateOverlappingIPPools
#   - Test-SLB_ValidateNCLoadBalancerMux
#   - Test-SLB_ValidateNCLoadBalancerManager
#   - Test-SLB_ValidateNCServers
#   - Test-SLB_ValidateNCHNVPAIPPools
#   - Test-SLB_ValidateInfraIPPools
#   - Test-SLB_ValidateDNSName
#
# Note that the validator names are used in AzStackHci.Network.psm1 file to define which validators
# to be run in different scenarios. Please make sure to keep the validator names consistent between
# the files.
# Check the comments there for more information.
#################################################################################################

<#
.SYNOPSIS
    Validates whether the FCNC (Failover Cluster Network Controller) component is installed on all target nodes.

.DESCRIPTION
    The Test-SLB_ValidateFCNCInstalled function checks if the Failover Cluster Network Controller (FCNC) is present and installed on each node in the provided PSSession array.
    It validates that the ApiService cluster resource exists and is available, which is a informational prerequisite for SLB (Software Load Balancer) deployment in Azure Stack HCI environments.
    The function returns detailed validation results for each node, including success/failure status and appropriate remediation guidance.

.PARAMETER PSSession
    An array of PowerShell PSSession objects representing the target nodes for validation. Each session must be established and accessible for the validation to proceed.

.OUTPUTS
    Returns an array of New-AzStackHciResultObject instances containing validation results for each node, including status, detailed messages, and remediation guidance.

.EXAMPLE
    Test-SLB_ValidateFCNCInstalled -PSSession $sessions

    Returns result objects indicating whether FCNC is installed on all nodes in the cluster.

.NOTES
    File: AzStackHci.NetworkSLB.Helpers.psm1
    Module: AzStackHci.EnvironmentChecker

    - This function is informational for SLB deployment validation.
    - FCNC must be installed on all nodes before SLB can be deployed.
    - The function checks for the ApiService cluster resource on each node.
    - Results are returned per node for granular validation reporting.
#>
function Test-SLB_ValidateFCNCInstalled {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession
    )

    $FCNCInstalledResults = @()

    try {
        # Ensure all node sessions are open and accessible for validation
        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $FCNCValidationStatus = ""
        $FCNCValidationDetail = ""

        # Check if FCNC is installed script block
        $scriptBlock = {
            $apiService = Get-ClusterResource ApiService -ErrorAction SilentlyContinue
            return $null -ne $apiService
        }

        # Check every session and make sure that FCNC is installed
        foreach ($testSession in $allNodeSessions) {
            Log-Info -Message ("Checking FCNC is installed on {0}" -f $testSession.ComputerName)
            $FCNCInstalled = Invoke-Command -Session $testSession -ScriptBlock $scriptBlock

            # Set validation status based on whether FCNC is installed
            $FCNCValidationStatus = if ($FCNCInstalled) { $StatusSuccess } else { $StatusFailure }

            # Log and set detailed message based on installation status
            if ($FCNCInstalled) {
                Log-Info -Message ("FCNC is installed on {0}" -f $testSession.ComputerName)
                $FCNCValidationDetail = $slbTxt.TestFCNCInstalledPass -f $testSession.ComputerName
            }
            else {
                Log-Info -Message ("FCNC is not installed on {0}" -f $testSession.ComputerName)
                $FCNCValidationDetail = $slbTxt.TestFCNCInstalledFail -f $testSession.ComputerName
            }

            $FCNCInstalledResult = @{
                Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateFCNCInstalled'
                Title              = 'FCNC (Failover Cluster Network Controller) component is installed on all cluster nodes'
                DisplayName        = 'FCNC is installed on all cluster nodes'
                Severity           = 'INFORMATIONAL'
                Description        = 'Verifies that the FCNC is properly installed and configured on each node in the cluster'
                Tags               = @{}
                Remediation        = 'https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateFCNCInstalled.md'
                TargetResourceID   = "Node: $($testSession.ComputerName), service: NC API service"
                TargetResourceName = 'FCNC API Service'
                TargetResourceType = 'FCNC installation'
                Timestamp          = [datetime]::UtcNow
                Status             = $FCNCValidationStatus
                AdditionalData     = @{
                    Source    = $testSession.ComputerName
                    Resource  = 'FCNC installation'
                    Detail    = $FCNCValidationDetail
                    Status    = $FCNCValidationStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            # The number of results is equal to the number of nodes
            $FCNCInstalledResults += New-AzStackHciResultObject @FCNCInstalledResult
        }

        return $FCNCInstalledResults
    }
    catch {
        throw ("Exception testing FCNC installation: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
    Validates that the number of Software Load Balancer (SLB) nodes is appropriate for the number of hosts in the deployment.

.DESCRIPTION
    The Test-SLB_ValidateNumberOfSLBNodes function checks whether the number of SLB nodes (MUXes) configured in the deployment is valid based on the number of hosts.
    It enforces the following rules:
      - For a single host, only one SLB node is allowed.
      - For multiple hosts, the number of SLB nodes must be at least 2 and no more than 3, and cannot exceed the number of hosts.
    The function logs detailed validation messages and returns a result object indicating success or failure.

.PARAMETER PSSession
    An array of PowerShell PSSession objects representing the hosts in the deployment.

.PARAMETER SoftwareLoadbalancerConfiguration
    An object containing the Software Load Balancer configuration, including the NumberOfMuxes property.

.OUTPUTS
    Returns a custom result object indicating the validation status, detailed message, and additional metadata.

.EXAMPLE
    PS> Test-SLB_ValidateNumberOfSLBNodes -PSSession $sessions -SoftwareLoadbalancerConfiguration $slbConfig

.NOTES
    This function is intended for use in AzStackHci environment validation scenarios.
#>
function Test-SLB_ValidateNumberOfSLBNodes {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [parameter(Mandatory = $false)]
        [PSCustomObject]
        $SoftwareLoadbalancerConfiguration,

        [parameter(Mandatory = $false)]
        [UInt16]
        $NumberOfMuxes
    )

    try {
        # Ensure all node sessions are open and accessible for validation
        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        $numberOfHosts = $allNodeSessions.Count
        $SLBNodesValidationStatus = $StatusSuccess
        $SLBNodesValidationDetail = $slbTxt.TestMuxValidPass
        $SLBNodesValidationSeverity = "INFORMATIONAL"

        if ($SoftwareLoadbalancerConfiguration) {
            if(IsNullOrEmpty -Resource $SoftwareLoadbalancerConfiguration.NumberOfMuxes -TreatWhiteSpaceAsNull) {
                # Set default based on number of hosts
                if ($numberOfHosts -eq 1) {
                    $NumberOfMuxes = 1
                }
                else {   #Multinode
                    $NumberOfMuxes = 2
                }
            }
            else {
                $NumberOfMuxes = $SoftwareLoadbalancerConfiguration.NumberOfMuxes
            }
        }

        # Log the current configuration for diagnostics
        Log-Info -Message "Found $numberOfHosts hosts and $NumberOfMuxes MUXes in the deployment."

        # Validate that at least one host exists in the deployment
        if ($numberOfHosts -eq 0) {
            $SLBNodesValidationStatus = $StatusFailure
            $SLBNodesValidationDetail = $slbTxt.TestNoHostsFoundFail
        }
        # Single-node deployment validation
        elseif ($numberOfHosts -eq 1) {
            # For single-node deployments, only 1 MUX is allowed
            if ($NumberOfMuxes -eq 1) {
            $SLBNodesValidationDetail = $slbTxt.TestSingleHostSingleMuxPass
            }
            else {
            # Single-node deployments cannot have multiple MUXes
            $SLBNodesValidationStatus = $StatusFailure
            $SLBNodesValidationDetail = $slbTxt.TestSingleHostMultipleMuxFail
            }
        }
        # Multi-node deployment validation
        else {
            switch ($true) {
                # Check if number of MUXes exceeds the maximum allowed (3)
                ($NumberOfMuxes -gt 3) {
                    $SLBNodesValidationStatus = $StatusFailure
                    $SLBNodesValidationDetail = $slbTxt.TestMaxMuxExceededFail
                }
                # Check if number of MUXes is less than the minimum allowed (1)
                ($NumberOfMuxes -lt 1) {
                    $SLBNodesValidationStatus = $StatusFailure
                    $SLBNodesValidationDetail = $slbTxt.TestSLBPropertyFail -f $PropertyNumberOfMuxes, $NumberOfMuxes
                }
                # Warn if only 1 MUX is configured in multi-node deployment
                # This is not recommended but allowed for scale-in scenarios
                ($NumberOfMuxes -eq 1) {
                    $SLBNodesValidationStatus = $StatusFailure
                    $SLBNodesValidationDetail = $slbTxt.TestMinMuxNotMetWarn
                    $SLBNodesValidationSeverity = "INFORMATIONAL"
                }
                # Check if number of MUXes exceeds the number of available hosts
                ($NumberOfMuxes -gt $numberOfHosts) {
                    $SLBNodesValidationStatus = $StatusFailure
                    $SLBNodesValidationDetail = $slbTxt.TestMuxExceedsHostsFail -f $NumberOfMuxes, $numberOfHosts
                }
                # All validations passed for multi-node deployment
                default {
                    $SLBNodesValidationDetail = $slbTxt.TestMuxValidPass
                }
            }
        }

        Log-Info -Message $SLBNodesValidationDetail
        $SLBNodesResult = @{
            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateNumberOfSLBNodes'
            Title              = 'The number of Software Load Balancer (SLB) Multiplexer (MUX) is appropriate for the number of available hosts in an Azure Local deployment.'
            DisplayName        = 'The number of Software Load Balancer (SLB) Multiplexer (MUX) is appropriate for the number of available hosts in an Azure Local deployment.'
            Severity           = $SLBNodesValidationSeverity
            Description        = 'Execute informational validation of the SLB node count configuration to ensure proper load balancer deployment in Azure Local environments.'
            Tags               = @{}
            Remediation        = 'https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateNumberOfSLBNodes.md'
            TargetResourceID   = "$TypeSLB - Mux:$NumberOfMuxes, Hosts:$numberOfHosts"
            TargetResourceName = $PropertyNumberOfMuxes
            TargetResourceType = $TypeSLB
            Timestamp          = [datetime]::UtcNow
            Status             = $SLBNodesValidationStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $TypeSDN
                Detail    = $SLBNodesValidationDetail
                Status    = $SLBNodesValidationStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        # There is only one result for this test
        return New-AzStackHciResultObject @SLBNodesResult
    }
    catch {
        throw ("Exception testing the number of SLB nodes and MUXes: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
    Validates the Software Load Balancer (SLB) configuration present in the SDNIntegration data.

.DESCRIPTION
    Test-SLB_ValidateSoftwareLoadBalancer ensures that a SoftwareLoadBalancer object exists
    in the provided configuration and that its properties comply with SLB validation rules via ValidateSLBProperties.
    The function returns a standardized New-AzStackHciResultObject describing validation status,
    details, and remediation guidance suitable for telemetry.

.PARAMETER SoftwareLoadbalancerConfiguration
    A PSCustomObject containing the SoftwareLoadBalancer configuration to validate, including
    properties such as NumberOfMuxes and BGPInfo.

.OUTPUTS
    New-AzStackHciResultObject PSCustomObject describing result status, message, and metadata.

.EXAMPLE
    Test-SLB_ValidateSoftwareLoadBalancer -SoftwareLoadbalancerConfiguration $slbConfig

.NOTES
    Relies on ValidateSLBProperties, New-AzStackHciResultObject, and $slbTxt.
#>
function Test-SLB_ValidateSoftwareLoadBalancer {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $SoftwareLoadbalancerConfiguration
    )

    try {
        # Initialize validation result variables with default success state
        $SLBValidationStatus = $StatusSuccess
        $SLBValidationDetail = $slbTxt.TestSLBPass
        $SLBValidationResourceName = ""
        $SLBValidationResourceID = ""

        # Check if SoftwareLoadbalancerConfiguration is null or empty
        if (IsNullOrEmpty -Resource $SoftwareLoadbalancerConfiguration -TreatWhiteSpaceAsNull) {
            # Configuration is missing - set failure status with appropriate message
            $SLBValidationStatus = $StatusFailure
            $SLBValidationDetail = $slbTxt.TestNotFoundSLBFail
            $SLBValidationResourceName = "<NULL>"
            $SLBValidationResourceID = "<NULL>"
        } else {
            # Configuration exists - validate its properties using ValidateSLBProperties helper
            $slbResult = ValidateSLBProperties -SLB $SoftwareLoadbalancerConfiguration

            # Check if validation failed (result is null or Valid property is false)
            if ($null -eq $slbResult -or -not $slbResult['Valid']) {
                # Validation failed - extract error details from result object
                $SLBValidationStatus = $StatusFailure
                # Use message from result if available, otherwise use generic failure message
                $SLBValidationDetail = if ($null -ne $slbResult -and $slbResult.ContainsKey('Message')) { $slbResult['Message'] } else { $slbTxt.TestNullResultSLBFail }
                # Extract the name of the property that failed validation
                $SLBValidationResourceName = if ($null -ne $slbResult -and $slbResult.ContainsKey('Name')) { $slbResult['Name'] } else { "<NULL>" }
                # Format resource ID with property name and value for telemetry
                $SLBValidationResourceID = if ($null -ne $slbResult -and $slbResult.ContainsKey('Name') -and $slbResult.ContainsKey('Value')) { SetPropertyFormat -Name $slbResult['Name'] -Value $slbResult['Value'] } else { "<NULL>" }
            }
        }

        Log-Info -Message $SLBValidationDetail
        $SLBResultObject = @{

            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateSoftwareLoadBalancer'
            Title              = 'Check Software Load Balancer (SLB) configuration is present and valid'
            DisplayName        = 'Check Software Load Balancer (SLB) configuration is present and valid'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if we have valid SoftwareLoadBalancer configuration'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateSoftwareLoadBalancer.md"
            TargetResourceID   = $SLBValidationResourceID
            TargetResourceName = $SLBValidationResourceName
            TargetResourceType = $TypeSLB
            Timestamp          = [datetime]::UtcNow
            Status             = $SLBValidationStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $TypeSDN
                Detail    = $SLBValidationDetail
                Status    = $SLBValidationStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        return New-AzStackHciResultObject @SLBResultObject
    }
    catch {
        throw ("Exception testing Software Load Balancer configuration: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates the HNVPA (Hyper-V Network Virtualization Provider Address) network configuration for the Software Load Balancer (SLB) in an Azure Stack HCI environment.

.DESCRIPTION
The Test-SLB_ValidateHNVPANetwork function checks the HNVPA network configuration to ensure it is suitable for SLB deployment. It verifies that exactly one HNVPA network exists, that it is enabled for network virtualization, and that its IP pools contain at least (2 * number of hosts) + number of muxes IP addresses. The function also ensures that the subnets and IP pools are properly configured and do not overlap with other networks. The function returns a result object indicating the validation status and details.

.PARAMETER PSSession
An array of PowerShell PSSession objects representing the target nodes for validation.

.PARAMETER NetworksConfiguration
An array of network configuration objects, each describing a network and its properties, including type, subnets, and IP pools.

.OUTPUTS
Returns a custom result object indicating the outcome of the HNVPA network validation, including status, details, and remediation steps if necessary.

.EXAMPLE
PS C:\> Test-SLB_ValidateHNVPANetwork -PSSession $sessions -NetworksConfiguration $networks

.NOTES
- The function assumes that the network configuration objects contain properties such as NetworkType, NetworkVirtualizationEnabled, and subnets with IpPools.
- The function logs the validation result and provides remediation guidance if the validation fails.
- This function is intended for use in Azure Stack HCI environment validation scenarios.
- Ensure that the provided NetworksConfiguration is accurate and up-to-date before running the validation.
#>
function Test-SLB_ValidateHNVPANetwork {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $NetworksConfiguration
    )

    # Validate HNVPA network IP pool contains minimum double #hosts + #number of MUXes in IP addresses
    # Validate IP pools valid
    try {
        # Ensure all node sessions are open and accessible for validation
        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        # Initialize validation variables for HNVPA network
        $numberOfHosts = $allNodeSessions.Count
        $numberOfMuxes = 1
        $totalAvailableIPs = 0

        # For multi-node deployments, set minimum number of MUXes to 2
        if ($numberOfHosts -gt 1) {
            #Multinode
            $numberOfMuxes = 2
        }

        # Set default validation status and messages
        $HNVPAStatus = $StatusSuccess
        $HNVPADetail = $slbTxt.TestNetworksPass -f $TypeHNVPA
        $HNVPAResourceName = ""
        $HNVPAResourceID = ""

        # Validate HNVPA network exists in configuration
        if (IsNullOrEmpty -Resource @($NetworksConfiguration.HNVPA) -TreatWhiteSpaceAsNull) {
            # No HNVPA network found - this is a informational failure
            $HNVPAStatus = $StatusFailure
            $HNVPADetail = $slbTxt.TestNotFoundHNVPAFail
            $HNVPAResourceName = $TypeHNVPA
            $HNVPAResourceID = SetPropertyFormat -Name $TypeHNVPA -Value "<NULL>"
        }
        elseif (@($NetworksConfiguration.HNVPA).Count -gt 1) {
            # Multiple HNVPA networks found - only one is allowed
            $HNVPAStatus = $StatusFailure
            $HNVPADetail = $slbTxt.TestMultipleHNVPAFail
            $HNVPAResourceName = $TypeHNVPA
            $HNVPAResourceID = SetPropertyFormat -Name $TypeHNVPA -Value "Multiple HNVPAs"
        }
        else {
            # Single HNVPA network found - proceed with detailed validation
            $hnvpa = @($NetworksConfiguration.HNVPA)

            # Validate that at least one subnet exists
            if (@($hnvpa.Subnets).Count -ge 1) {
            # Track address prefixes to detect overlaps across subnets
            $addressPrefixes = @()

            # Iterate through each subnet and perform comprehensive validation
            foreach ($subnet in @($hnvpa.Subnets)) {

                # Validate basic subnet properties (AddressPrefix, VlanId, IpPools)
                $subnetResult = ValidateSubnetProperties -Subnet $subnet -NetworkType $TypeHNVPA
                if (-not $subnetResult -or -not $subnetResult.Valid) {
                    $HNVPAStatus = $StatusFailure
                    $HNVPADetail = if ($subnetResult -and $subnetResult.Message) { $subnetResult.Message } else { ($slbTxt.TestNullResultFail -f $PropertySubnets, $TypeHNVPA) }
                    $HNVPAResourceName = if ($subnetResult -and $subnetResult.Name) { $subnetResult.Name } else { $PropertySubnets }
                    $HNVPAResourceID = if ($subnetResult -and $subnetResult.Name -and $subnetResult.Value) { SetPropertyFormat -Name $subnetResult.Name -Value $subnetResult.Value } else { "<NULL>" }
                    break
                }

                # Validate DefaultGateways are present and within subnet range
                $gatewayResult = ValidateDefaultGateways -Subnet $subnet -NetworkType $TypeHNVPA
                if (-not $gatewayResult -or -not $gatewayResult.Valid) {
                    $HNVPAStatus = $StatusFailure
                    $HNVPADetail = if ($gatewayResult -and $gatewayResult.Message) { $gatewayResult.Message } else { ($slbTxt.TestNullResultFail -f $PropertyDefaultGateways, $TypeHNVPA) }
                    $HNVPAResourceName = if ($gatewayResult -and $gatewayResult.Name) { $gatewayResult.Name } else { $PropertyDefaultGateways }
                    $HNVPAResourceID = if ($gatewayResult -and $gatewayResult.Name -and $gatewayResult.Value) { SetPropertyFormat -Name $gatewayResult.Name -Value $gatewayResult.Value } else { "<NULL>" }
                    break
                }

                # Validate IP Pools configuration and accumulate total available IPs
                $ipPoolsResult = ValidateIPPools -Subnet $subnet -NetworkType $TypeHNVPA
                if (-not $ipPoolsResult -or -not $ipPoolsResult.Valid) {
                    $HNVPAStatus = $StatusFailure
                    $HNVPADetail = if ($ipPoolsResult -and $ipPoolsResult.Message) { $ipPoolsResult.Message } else { ($slbTxt.TestNullResultFail -f $PropertyIPPools, $TypeHNVPA) }
                    $HNVPAResourceName = if ($ipPoolsResult -and $ipPoolsResult.Name) { $ipPoolsResult.Name } else { $PropertyIPPools }
                    $HNVPAResourceID = if ($ipPoolsResult -and $ipPoolsResult.Name -and $ipPoolsResult.Value) { SetPropertyFormat -Name $ipPoolsResult.Name -Value $ipPoolsResult.Value } else { "<NULL>" }
                    break
                } else {
                    # Add available IPs from this subnet to the total
                    $totalAvailableIPs += $ipPoolsResult.AvailableIPs
                }

                # Validate address prefixes don't overlap with previously checked subnets
                $addressPrefixesResult = ValidateAddressPrefixes -Subnet $subnet -AddressPrefixes $addressPrefixes
                if (-not $addressPrefixesResult -or -not $addressPrefixesResult.Valid) {
                    $HNVPAStatus = $StatusFailure
                    $HNVPADetail = if ($addressPrefixesResult -and $addressPrefixesResult.Message) { $addressPrefixesResult.Message } else { ($slbTxt.TestNullResultFail -f $PropertyAddressPrefix, $TypeHNVPA) }
                    $HNVPAResourceName = if ($addressPrefixesResult -and $addressPrefixesResult.Name) { $addressPrefixesResult.Name } else { $PropertyAddressPrefix }
                    $HNVPAResourceID = if ($addressPrefixesResult -and $addressPrefixesResult.Name -and $addressPrefixesResult.Value) { SetPropertyFormat -Name $addressPrefixesResult.Name -Value $addressPrefixesResult.Value } else { "<NULL>" }
                    break
                }
            }

            # If all subnet validations passed, verify total IP pool size meets requirements
            if ($HNVPAStatus -eq $StatusSuccess) {
                # Calculate required IPs: (2 * number of hosts) + number of MUXes
                $requiredIPs = (2 * $numberOfHosts) + $numberOfMuxes

                # Check if available IPs meet the minimum requirement
                if ($totalAvailableIPs -lt $requiredIPs) {
                    $HNVPAStatus = $StatusFailure
                    $HNVPADetail = $slbTxt.TestNotEnoughIPHNVPAFail -f $totalAvailableIPs, $requiredIPs, $numberOfHosts, $numberOfMuxes
                    $HNVPAResourceName = $PropertyIPPools
                    $HNVPAResourceID = SetPropertyFormat -Name $PropertyIPPools -Value "Required: $requiredIPs, Available: $totalAvailableIPs"
                }
            }
            } else {
                # No subnets found in HNVPA network - this is a informational failure
                $HNVPAStatus = $StatusFailure
                $HNVPADetail = $slbTxt.TestNetworkPropertyFail -f $TypeHNVPA, $PropertySubnets
                $HNVPAResourceName = $PropertySubnets
                $HNVPAResourceID = SetPropertyFormat -Name $PropertySubnets -Value "<NULL>"
            }
        }

        # Log the validation result
        Log-Info -Message $HNVPADetail
        $HNVPAResult = @{

            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateHNVPANetwork'
            Title              = 'Validate the Hyper-V Network Virtualization Provider Address (HNVPA) network configuration for the Software Load Balancer (SLB)'
            DisplayName        = 'Validate the Hyper-V Network Virtualization Provider Address (HNVPA) network configuration for the Software Load Balancer (SLB)'
            Severity           = 'INFORMATIONAL'
            Description        = 'Execute comprehensive validation of HNVPA network configuration to ensure it meets the requirements for proper SLB deployment in Azure Local environments. This function is informational for validating the network infrastructure before deploying SLB components.'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateHNVPANetwork.md"
            TargetResourceID   = $HNVPAResourceID
            TargetResourceName = $HNVPAResourceName
            TargetResourceType = $TypeHNVPA
            Timestamp          = [datetime]::UtcNow
            Status             = $HNVPAStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $TypeNetworks
                Detail    = $HNVPADetail
                Status    = $HNVPAStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        return New-AzStackHciResultObject @HNVPAResult
    }
    catch {
        throw ("Exception testing HNVPA configuration: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates the configuration of public and private VIP networks for the SLB (Software Load Balancer) in an Azure Stack HCI environment.

.DESCRIPTION
The Test-SLB_ValidatePublicPrivateVIPNetworks function checks the setup of public and private Virtual IP (VIP) networks to ensure they meet the requirements for proper SLB operation within an Azure Stack HCI deployment.
This validation ensures that the networks are correctly configured, including proper subnet and IP pool settings, and helps prevent misconfigurations that could impact network traffic distribution and load balancing.

.PARAMETER PSSession
An array of PowerShell PSSession objects representing the target nodes for validation.

.PARAMETER NetworksConfiguration
An array of network configuration objects, each describing a network and its properties, including type, subnets, and IP pools.

.PARAMETER ValidationMode
Specifies the mode of validation to perform. Possible values are 'Strict' or 'Relaxed'. Default is 'Strict'.

.EXAMPLE
PS C:\> Test-SLB_ValidatePublicPrivateVIPNetworks -PSSession $sessions -NetworksConfiguration $networks -ValidationMode 'Strict'

# Runs the validation for public and private VIP networks in strict mode and outputs the results.

.NOTES
File: AzStackHci.NetworkSLB.Helpers.psm1
Module: AzStackHci.EnvironmentChecker
#>
function Test-SLB_ValidatePublicPrivateVIPNetworks {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $NetworksConfiguration
    )

    $VIPResults = @()
    try {
        # Get VIP networks from ECE configuration
        # PublicVIP and PrivateVIP are used to provide load balancer endpoints for tenant workloads
        $publicVIPs = @($NetworksConfiguration.PublicVIP)
        $privateVIPs = @($NetworksConfiguration.PrivateVIP)

        # Validate Public VIP networks (mandatory)
        # At least one Public VIP network must be configured for SLB deployment
        if ((IsNullOrEmpty -Resource $publicVIPs -TreatWhiteSpaceAsNull)) {
            # No Public VIPs found - this is a informational failure as Public VIP is mandatory
            $VIPResults += ValidatePublicPrivateVIPNetworksResult -Result @{Status= $StatusFailure; Message= $slbTxt.TestVIPNotFoundFail; Name="<NULL>"; ID="<NULL>"; Type=$TypePublicVIP}
        } else {
            # Public VIP found - perform detailed validation of network properties
            $VIPResults += ValidatePublicPrivateVIPNetworksCheck -VIPs $publicVIPs -NetworkType $TypePublicVIP
        }

        # Validate Private VIP networks (optional)
        # Private VIP networks are optional and used for internal load balancing scenarios
        if ((IsNullOrEmpty -Resource $privateVIPs -TreatWhiteSpaceAsNull)) {
            # No Private VIPs found - this is acceptable as Private VIP is optional
            Log-Info -Message "No Private VIP networks found in configuration. Skipping Private VIP validation."
        } else {
            # Private VIP found - perform detailed validation of network properties
            $VIPResults += ValidatePublicPrivateVIPNetworksCheck -VIPs $privateVIPs -NetworkType $TypePrivateVIP
        }
    }
    catch {
        throw ("Exception testing Public/Private VIP configuration: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }

    return $VIPResults
}

<#
.SYNOPSIS
    Validates that configured BGP peer router IPs are reachable from a host in the cluster.

.DESCRIPTION
    Test-SLB_ValidateBGPPeersReachable iterates the PeerRouterConfigurations listed
    under the SoftwareLoadBalancer configuration's BGPInfo and attempts a simple network
    connectivity test (Test-NetConnection) to each RouterIPAddress. For each peer, it
    produces a standardized result object suitable for telemetry, indicating whether the
    peer is reachable and providing remediation guidance when it is not.

    The function runs the network tests from nodes represented by the supplied PSSession(s).
    It returns an array of New-AzStackHciResultObject items — one per BGP peer — containing
    Status = $StatusSuccess when the peer is reachable and $StatusFailure when it is not.

.PARAMETER PSSession
    An array of PowerShell PSSession objects representing the target nodes used to run
    the connectivity checks (the first returned session is used as the test source).

.PARAMETER SoftwareLoadbalancerConfiguration
    A PSCustomObject containing the SoftwareLoadBalancer configuration. Expected to contain
    BGPInfo.PeerRouterConfigurations with RouterIPAddress entries.

.OUTPUTS
    An array of New-AzStackHciResultObject PSCustomObjects describing per-peer validation
    status, detail messages, and remediation guidance.

.EXAMPLE
    $results = Test-SLB_ValidateBGPPeersReachable -PSSession $sessions -SoftwareLoadbalancerConfiguration $slbConfig
    $results | Format-Table -AutoSize

.NOTES
    - Relies on Test-NetConnection being available on the target node(s).
    - Uses localized strings from $slbTxt for messages.
    - Designed to produce one result object per configured BGP peer for telemetry ingestion.
#>
function Test-SLB_ValidateBGPPeersReachable {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $SoftwareLoadbalancerConfiguration
    )

    $BGPPeerResults = @()
    try {
        # Ensure all node sessions are open and accessible for validation
        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnvValidatorNwkLibEnsureTestSessionOpen -PSSessions $PSSession

        # Define script block to test BGP peer reachability
        # Tests TCP connectivity to BGP port 179 on the target IP address
        $scriptBlock = {
            param ($ip)
            # Perform a simple TCP connection test to the BGP port (179)
            $result = Test-NetConnection -ComputerName $ip -port 179 -InformationLevel Quiet -WarningAction SilentlyContinue
            return $result
        }

        # Extract BGP peer router configurations from the SLB configuration
        $bgpPeers = $SoftwareLoadbalancerConfiguration.BGPInfo.PeerRouterConfigurations
        $BGPPeerReachableStatus = ""
        $BGPPeerReachableDetail = ""

        # Iterate through each node session to test BGP peer connectivity
        foreach ($testSession in $allNodeSessions) {
            Log-Info -Message "Checking BGP Peers reachable from $($testSession.ComputerName)"

            # Test connectivity to each configured BGP peer
            foreach ($bgpPeer in $bgpPeers) {
                $ip = $bgpPeer.RouterIPAddress
                Log-Info -Message "Checking BGP Peer $ip"

                # Invoke the connectivity test on the target node
                $result = Invoke-Command -Session $testSession -ScriptBlock $scriptBlock -ArgumentList $ip

                # Set validation status based on connectivity test result
                $BGPPeerReachableStatus = if ($result) { $StatusSuccess } else { $StatusFailure }

                # Set detailed message based on connectivity test result
                $BGPPeerReachableDetail = if ($result) {
                    $slbTxt.TestBGPPeerReachablePass -f $ip
                } else {
                    $slbTxt.TestBGPPeerReachableFail -f $ip
                }

                # Log the validation result for this BGP peer
                Log-Info -Message $BGPPeerReachableDetail

                # Construct result object with validation details for telemetry
                $BGPPeerResult = @{
                    Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateBGPPeersReachable'
                    Title              = 'Border Gateway Protocol (BGP) Peers Reachable'
                    DisplayName        = 'Border Gateway Protocol (BGP) Peers Reachable'
                    Severity           = 'INFORMATIONAL'
                    Description        = 'Test if BGP Peers are reachable'
                    Tags               = @{}
                    Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateBGPPeersReachable.md"
                    TargetResourceID   = SetPropertyFormat -Name $PropertyRouterIPAddress -Value $ip
                    TargetResourceName = $PropertyPeerRouterConfigurations
                    TargetResourceType = $PropertyBGPInfo
                    Timestamp          = [datetime]::UtcNow
                    Status             = $BGPPeerReachableStatus
                    AdditionalData     = @{
                        Source    = $testSession.ComputerName
                        Resource  = $PropertyBGPInfo
                        Detail    = $BGPPeerReachableDetail
                        Status    = $BGPPeerReachableStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }

                # Add the result object to the collection for return
                $BGPPeerResults += New-AzStackHciResultObject @BGPPeerResult
            }
        }

        return $BGPPeerResults
    }
    catch {
        throw ("Exception testing BGP peers reachable: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates the configuration and provisioning status of the SLB (Software Load Balancer) MUX (Multiplexer) in an Azure Stack HCI environment.

.DESCRIPTION
The Test-SLB_ValidateNCLoadBalancerMux function checks the configuration and provisioning status of the SLB MUX on the target nodes. It ensures that the SLB MUX is healthy and ready for deployment. The function uses the provided parameters and PowerShell sessions to perform the validation.

.PARAMETER Parameters
A set of parameters required for validating the SLB MUX configuration and provisioning status.

.PARAMETER PSSession
An array of PowerShell PSSession objects representing the target nodes for validation.

.OUTPUTS
Returns a result object indicating the outcome of the SLB MUX validation, including status, details, and remediation steps if necessary.

.EXAMPLE
PS C:\> Test-SLB_ValidateNCLoadBalancerMux -Parameters $params -PSSession $sessions

Validates the SLB MUX configuration and provisioning status on the target nodes.

.NOTES
- This function assumes that the required modules for SLB MUX validation are available and can be imported.
- The function logs the validation result and provides remediation guidance if the validation fails.
- Ensure that the provided parameters and sessions are accurate and up-to-date before running the validation.
#>
function Test-SLB_ValidateNCLoadBalancerMux {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        [ValidateNotNullOrEmpty()]
        $PSSession,

        [parameter(Mandatory = $false)]
        $Parameters
    )

    try {
        # Get names of SLB nodes that are in 'Complete' provisioning status
        $slbNames = $Parameters.Roles['VirtualMachines'].PublicConfiguration.Nodes.Node | Where-Object {$_.Role -eq 'SLB' -and $_.ProvisioningStatus -ne 'Removed'} | Select-Object -ExpandProperty Name

        # Initialize result collection and default validation status
        $ncSlbMuxResults = @()
        $ncSlbMuxStatus = $StatusSuccess
        $ncSlbMuxDetail = $slbTxt.TestNCSLBMuxStatusPass

        $muxResults = $null
        try {
            # Set connection to Network Controller
            SetNCConnection

            # Retrieve all SLB MUX from Network Controller
            # Then remove nextLink property from results
            $slbMuxes = @(Get-NCLoadBalancerMux -ErrorAction Stop)
            $slbMuxes = @($slbMuxes | Where-Object { $_.PSObject.Properties.Name -ne 'nextLink' })
            if($slbMuxes.Count -gt 0 -and $slbMuxes.Count -eq $slbNames.Count) {
                # Verify all SLB MUX exist in provided node names
                $unmatchedMux = $slbMuxes | Where-Object { $slbNames -notcontains $_.resourceId } | Select-Object -First 1
                if ($unmatchedMux) {
                    # SLB MUX not found in provided node names - create failure result
                    $muxResults = @(@{
                    Valid           = $false
                    Id              = $unmatchedMux.resourceId
                    Provisioning    = ""
                    Configuration   = ""
                    DetailSource    = ""
                    DetailMessage   = "SLB MUX $($unmatchedMux.resourceId) not found in provided node names."
                    DetailCode      = ""
                    })
                }
            } else {
                # SLB mux count is 0 or mismatch - create failure result
                $muxResults = @(@{
                    Valid           = $false
                    Id              = ""
                    Provisioning    = ""
                    Configuration   = ""
                    DetailSource    = ""
                    DetailMessage   = "SLB mux count is 0 or mismatch. Expected: $($slbNames.Count), Found: $($slbMuxes.Count)."
                    DetailCode      = ""
                })
            }

            # If results not already set due to errors, validate each SLB MUX
            if($null -eq $muxResults) {
                # Retrieve NC role parameters from ECE configuration
                $ncParams = Get-EceLiteRoleParameters -RoleName NC

                # Execute validation of NC Load Balancer MUX configuration and provisioning state
                $muxResults = Validate-NCLoadBalancerMux -Parameters $ncParams -ErrorStop $false -ErrorAction Stop -Verbose
            }
        } catch {
            # Capture exception details for error reporting
            $exceptionMessage = "$($_.Exception.Message)`n$($_.Exception.StackTrace)"
        } finally {
            # Ensure we always return a result object, even if validation threw an exception
            if(-not $muxResults) {
                $muxResults = @(@{
                    Exception = $exceptionMessage
                })
            }
        }

        # Process each SLB MUX result returned from the validation
        foreach ($result in $muxResults) {
            # Check if the result object is valid and not null
            if($result) {
                # Check if the result contains the 'Valid' key and if validation passed
                if ($result.containsKey('Valid') -and $result.Valid) {
                    # Validation succeeded - set success status and message
                    $ncSlbMuxStatus = $StatusSuccess
                    $ncSlbMuxDetail = $slbTxt.TestNCSLBMuxStatusPass
                } else {
                    # Validation failed - set failure status and extract error details
                    $ncSlbMuxStatus = $StatusFailure
                    if($result.containsKey('Exception')) {
                    # Use exception message if available
                    $ncSlbMuxDetail = "$($result.Exception)"
                    } else {
                    # Otherwise format detailed failure message with MUX state information
                    $ncSlbMuxDetail = $slbTxt.TestNCSLBMuxStatusFail -f $result.Id, $result.Provisioning, $result.Configuration, $result.DetailMessage
                    }
                }
            } else {
                # Result is null - set failure status and create placeholder result object
                $ncSlbMuxStatus = $StatusFailure
                $ncSlbMuxDetail = $slbTxt.TestNCReturnNullFail
                $result = @{Valid=$false; Id="<NULL>"; Provisioning="<NULL>"; Configuration="<NULL>"; DetailSource="<NULL>"; DetailMessage="<NULL>"; DetailCode="<NULL>"}
            }

            # Construct the result object with all validation details for telemetry
            $SlbMuxResult = @{
            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateNCLoadBalancerMux'
            Title              = 'All Software Load Balancer (SLB) Multiplexer (MUX) state on Network Controller (NC)'
            DisplayName        = 'All Software Load Balancer (SLB) Multiplexer (MUX) state on Network Controller (NC)'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if all SLB MUX configuration and provisioning state are healthy.'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateNCLoadBalancerMux.md"
            TargetResourceID   = "SLB MUX: " + $result.Id + ", " + $result.DetailMessage
            TargetResourceName = $result.DetailCode
            TargetResourceType = $result.DetailSource
            Timestamp          = [datetime]::UtcNow
            Status             = $ncSlbMuxStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $result.DetailSource
                Detail    = $ncSlbMuxDetail
                Status    = $ncSlbMuxStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
            }

            # Add the result object to the collection (one result per MUX)
            $ncSlbMuxResults += New-AzStackHciResultObject @SlbMuxResult
        }

        return $ncSlbMuxResults
    }
    catch {
        throw ("Exception testing NC load balancer MUX: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates the configuration and provisioning status of the SLB (Software Load Balancer) Manager in an Azure Stack HCI environment.

.DESCRIPTION
The Test-SLB_ValidateNCLoadBalancerManager function checks the configuration and provisioning status of the SLB Manager on the target nodes. It ensures that the SLB Manager is healthy and ready for deployment. The function uses the provided parameters and PowerShell sessions to perform the validation.

.PARAMETER Parameters
A set of parameters required for validating the SLB Manager configuration and provisioning status.

.PARAMETER PSSession
An array of PowerShell PSSession objects representing the target nodes for validation.

.OUTPUTS
Returns a result object indicating the outcome of the SLB Manager validation, including status, details, and remediation steps if necessary.

.EXAMPLE
PS C:\> Test-SLB_ValidateNCLoadBalancerManager -Parameters $params -PSSession $sessions

Validates the SLB Manager configuration and provisioning status on the target nodes.

.NOTES
- This function assumes that the required modules for SLB Manager validation are available and can be imported.
- The function logs the validation result and provides remediation guidance if the validation fails.
- Ensure that the provided parameters and sessions are accurate and up-to-date before running the validation.
#>
function Test-SLB_ValidateNCLoadBalancerManager {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        [ValidateNotNullOrEmpty()]
        $PSSession,

        [parameter(Mandatory = $false)]
        $Parameters
    )

    try {
        # Initialize result variables with default success state
        $lbManagerStatus = $StatusSuccess
        $lbManagerDetail = $slbTxt.TestNCLBManagerStatusPass

        # Set connection to Network Controller
        SetNCConnection

        $lbManagerResult = $null
        try {
            # Retrieve NC role parameters from ECE configuration
            $ncParams = Get-EceLiteRoleParameters -RoleName NC

            # Execute validation of NC Load Balancer Manager configuration and provisioning state
            $lbManagerResult = Validate-NCLoadBalancerManager -Parameters $ncParams -ErrorStop $false -ErrorAction Stop -Verbose
        } catch {
            # Capture exception details for error reporting
            $exceptionMessage = "$($_.Exception.Message)`n$($_.Exception.StackTrace)"
        } finally {
            # Ensure we always return a result object, even if validation threw an exception
            if(-not $lbManagerResult) {
                $lbManagerResult = @{
                    ExceptionDetail = $exceptionMessage
                }
            }
        }

        # Check if the result object is valid and not null
        if ($lbManagerResult) {
            # Check if the result contains the 'Valid' key and if validation passed
            if ($lbManagerResult.containsKey('Valid') -and $lbManagerResult.Valid) {
                # Validation succeeded - set success status and message
                $lbManagerStatus = $StatusSuccess
                $lbManagerDetail = $slbTxt.TestNCLBManagerStatusPass
            } else {
                # Validation failed - set failure status and extract error details
                $lbManagerStatus = $StatusFailure
                if ($lbManagerResult.containsKey('ExceptionDetail')) {
                    # Use exception detail message if available
                    $lbManagerDetail = $lbManagerResult.ExceptionDetail
                } else {
                    # Otherwise format detailed failure message with provisioning state information
                    $lbManagerDetail = $slbTxt.TestNCLBManagerStatusFail -f $lbManagerResult.Provisioning
                }
            }
        } else {
            # Result is null - set failure status with appropriate message
            $lbManagerStatus = $StatusFailure
            $lbManagerDetail = $slbTxt.TestNCReturnNullFail
        }

        $LBManagerResult = @{
            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateNCLoadBalancerManager'
            Title              = 'Network Controller (NC) load balancer manager state'
            DisplayName        = 'Network Controller (NC) load balancer manager state'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if all NC load balancer manager provisioning state are healthy.'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateNCLoadBalancerManager.md"
            TargetResourceID   = "NCLoadBalancerManager"
            TargetResourceName = "NCLoadBalancerManager"
            TargetResourceType = 'Network Controller load balancer manager'
            Timestamp          = [datetime]::UtcNow
            Status             = $lbManagerStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = 'Network Controller load balancer manager'
                Detail    = $lbManagerDetail
                Status    = $lbManagerStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        return New-AzStackHciResultObject @LBManagerResult
    }
    catch {
        throw ("Exception testing NC load balancer manager: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}


<#
.SYNOPSIS
Validates the available IP pools from the Hyper-V Network Virtualization Provider Address (HNVPA) network in Network Controller (NC).

.DESCRIPTION
Test-SLB_ValidateNCHNVPAIPPools checks if the HNVPA logical network in NC has enough available IP addresses for the deployment.
It calculates the required IPs as (2 * (number of hosts + number of new hosts)) + number of MUXes, and compares with the available IPs.
Returns a result object indicating pass/fail and details.

.PARAMETER PSSession
An array of PowerShell PSSession objects representing the target nodes for validation.

.PARAMETER NumberOfNewHosts
The number of new hosts to be added to the deployment.

.OUTPUTS
Returns a result object indicating the outcome of the HNVPA IP pool validation, including status, details, and remediation steps if necessary.

.EXAMPLE
PS C:\> Test-SLB_ValidateNCHNVPAIPPools -NumberOfNewHosts 2 -PSSession $sessions

.NOTES
- Requires NC PowerShell modules to be available on the target node.
- Only the first session is used for validation.
#>
function Test-SLB_ValidateNCHNVPAIPPools {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        [ValidateNotNullOrEmpty()]
        $PSSession,

        [parameter(Mandatory = $true)]
        $NumberOfNewHosts
    )

    try {
        # Initialize variables to track IP availability and requirements
        $totalAvailableIPs = 0
        $requiredIPs = 0

        # Set default validation status and message
        $ncHNVPAIPStatus = $StatusSuccess
        $ncHNVPAIPDetail = $slbTxt.TestNCHNVPAIPPoolPass

        # Query Network Controller for HNVPA IP pool availability
        $ncResult = $null
        $availableIP = 0
        try {
            # Set connection to Network Controller
            SetNCConnection

            # Query Network Controller for HNVPA logical network configuration
            $logicalNetworks = Get-NCLogicalNetwork -resourceID "HNVPA" -ErrorAction Stop
            if($logicalNetworks) {
                # Ensure $logicalNetworks is an array (Get-NCLogicalNetwork may return single object)
                $logicalNetworks = @($logicalNetworks)

                # Iterate through each HNVPA logical network
                foreach ($ln in $logicalNetworks) {
                    if ($ln.Properties -and $ln.Properties.Subnets) {
                        $subnets = @($ln.Properties.Subnets)

                        # Iterate through each subnet in the logical network
                        foreach ($subnet in $subnets) {
                            if ($subnet.Properties) {
                                # Count network interfaces attached to this subnet
                                $nicCount = 0
                                if($subnet.Properties.networkInterfaces) {
                                    $nicCount = @($subnet.Properties.networkInterfaces).Count
                                }

                                # Count reserved IP addresses in this subnet
                                $ipReservedCount = 0
                                if($subnet.Properties.ipReservations) {
                                    foreach ($ipReservation in @($subnet.Properties.ipReservations)) {
                                        if ($ipReservation.properties -and $null -ne $ipReservation.properties.numberOfAddresses) {
                                        $ipReservedCount += $ipReservation.properties.numberOfAddresses
                                        }
                                    }
                                }

                                # Calculate available IPs: Total - (NICs * 2) - Reserved - In-transition
                                # NICs consume 2 IPs each (CA and PA addresses in SDN)
                                if ($subnet.Properties.usage) {
                                    if ($null -ne $subnet.Properties.usage.numberOfIPAddresses -and $null -ne $subnet.Properties.usage.numberOfIPAddressesInTransition) {
                                        $availableIP += $subnet.Properties.usage.numberOfIPAddresses - (($nicCount * 2) + $ipReservedCount + $subnet.Properties.usage.numberOfIPAddressesInTransition)
                                    } else {
                                        throw "No usage detailed information found for HNVPA subnet"
                                    }
                                }
                            } else {
                                throw "No properties found for HNVPA subnet"
                            }
                        }
                    } else {
                        throw "No properties or subnets found for HNVPA"
                    }
                }
            } else {
                throw "No NC logical networks found for HNVPA"
            }

            # Return available IP count on success
            $ncResult = @{ AvailableIP = $availableIP }
        } catch {
            # Capture exception details for error reporting
            $exceptionMessage = "$($_.Exception.Message)`n$($_.Exception.StackTrace)"
        } finally {
            # Ensure we always return a result object, even if validation threw an exception
            if(-not $ncResult) {
                $ncResult = @{ Exception = $exceptionMessage }
            }
        }

        # Check if the result object is valid and not null
        if($ncResult) {
            # Check if the result contains available IP count
            if ($ncResult.containsKey('AvailableIP')) {
                $totalAvailableIPs = $ncResult.AvailableIP

                # Calculate required IPs: 2 * number of new hosts
                # Each new host requires 2 IP addresses (CA and PA addresses in SDN)
                $requiredIPs = (2 * $NumberOfNewHosts)

                # Check if total available IPs meet the requirement
                if ($requiredIPs -gt $totalAvailableIPs) {
                    # Insufficient IPs available - set failure status
                    $ncHNVPAIPStatus = $StatusFailure
                    $ncHNVPAIPDetail = $slbTxt.TestNCHNVPAIPPoolFail -f $totalAvailableIPs, $requiredIPs
                }
            } else {
                # Result doesn't contain AvailableIP key - set failure status
                $ncHNVPAIPStatus = $StatusFailure
                if($ncResult.containsKey('Exception')) {
                    # Use exception message if available
                    $ncHNVPAIPDetail = $ncResult.Exception
                } else {
                    # Otherwise use generic null result message
                    $ncHNVPAIPDetail = $slbTxt.TestNCReturnNullFail
                }
            }
        } else {
            # Result is null - set failure status with appropriate message
            $ncHNVPAIPStatus = $StatusFailure
            $ncHNVPAIPDetail = $slbTxt.TestNCReturnNullFail
        }

        # Construct the result object with validation details for telemetry
        $ncHNVPAIPResult = @{
            Name               = 'Test-SLB_ValidateNCHNVPAIPPools'
            Title              = 'Validate the available IP pools from Hyper-V Network Virtualization Provider Address (HNVPA) network'
            DisplayName        = 'Validate the available IP pools from Hyper-V Network Virtualization Provider Address (HNVPA) network'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if HNVPA IP pools have sufficient IP addresses.'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateHNVPANetwork.md"
            TargetResourceID   = "NC HNVPA Available IP Addresses: [$totalAvailableIPs], Required: [$requiredIPs]"
            TargetResourceName = $PropertyIPPools
            TargetResourceType = $TypeHNVPA
            Timestamp          = [datetime]::UtcNow
            Status             = $ncHNVPAIPStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $PropertyIPPools
                Detail    = $ncHNVPAIPDetail
                Status    = $ncHNVPAIPStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        # There is only one result for this test
        return New-AzStackHciResultObject @ncHNVPAIPResult
    }
    catch {
        throw ("Exception testing HNVPA IP pools: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates the configuration and provisioning status of the SLB (Software Load Balancer) NC servers in an Azure Stack HCI environment.

.DESCRIPTION
The Test-SLB_ValidateNCServers function checks the configuration and provisioning status of the Network Controller (NC) servers on the target nodes. It ensures that each NC server is healthy, properly configured, and ready for SLB-related operations. The function uses the provided parameters and PowerShell sessions to perform the validation and produces result objects suitable for telemetry.

.PARAMETER Parameters
A set of parameters required for validating the NC server configuration and provisioning status.

.PARAMETER PSSession
An array of PowerShell PSSession objects representing the target nodes for validation.

.OUTPUTS
Returns an array of result objects indicating the outcome of the NC server validation, including status, details, and remediation steps if necessary.

.EXAMPLE
PS C:\> Test-SLB_ValidateNCServers -Parameters $params -PSSession $sessions

Validates the NC server configuration and provisioning status on the target nodes.

.NOTES
- This function assumes that the required modules for NC server validation are available and can be imported.
- The function logs the validation result and provides remediation guidance if the validation fails.
- Ensure that the provided parameters and sessions are accurate and up-to-date before running the validation.
#>

function Test-SLB_ValidateNCServers {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        [ValidateNotNullOrEmpty()]
        $PSSession,

        [parameter(Mandatory = $false)]
        $Parameters
    )

    try {
        # Get names of nodes from BareMetal role configuration
        $nodeNames  = $Parameters.Roles["BareMetal"].PublicConfiguration.Nodes.Node.Name

        # Initialize result collection and default validation status
        $ncServerResults = @()
        $ncServerStatus = $StatusSuccess
        $ncServerDetail = $slbTxt.TestNCServerStatusPass

        $ncResults = $null
        try {
            # Set connection to Network Controller
            SetNCConnection

            # Retrieve all NC servers from Network Controller
            # Then remove nextLink property from results
            $ncServers = @(Get-NCServer -ErrorAction Stop)
            $ncServers = @($ncServers | Where-Object { $_.PSObject.Properties.Name -ne 'nextLink' })
            if($ncServers.Count -gt 0 -and $ncServers.Count -eq $nodeNames.Count) {
                # Verify all NC servers exist in provided node names
                $unmatchedServer = $ncServers | Where-Object { $nodeNames -notcontains $_.resourceId } | Select-Object -First 1
                if ($unmatchedServer) {
                    # NC server not found in provided node names - create failure result
                    $ncResults = @(@{
                        Valid           = $false
                        Id              = $unmatchedServer.resourceId
                        Provisioning    = ""
                        Configuration   = ""
                        DetailSource    = ""
                        DetailMessage   = "NC Server $($unmatchedServer.resourceId) not found in provided node names."
                        DetailCode      = ""
                    })
                }
            } else {
                # NC server count is 0 or mismatch - create failure result
                $ncResults = @(@{
                    Valid           = $false
                    Id              = ""
                    Provisioning    = ""
                    Configuration   = ""
                    DetailSource    = ""
                    DetailMessage   = "NC server count is 0 or mismatch. Expected: $($nodeNames.Count), Found: $($ncServers.Count)."
                    DetailCode      = ""
                })
            }

            # If results not already set due to errors, validate each NC server
            if($null -eq $ncResults) {
                # Retrieve NC role parameters from ECE configuration
                $ncParams = Get-EceLiteRoleParameters -RoleName NC

                # Execute validation of NC server configuration and provisioning state
                $ncResults = Validate-NCServer -Parameters $ncParams -ErrorStop $false -ErrorAction stop -Verbose
            }
        } catch {
            # Capture exception details for error reporting
            $exceptionMessage = "$($_.Exception.Message)`n$($_.Exception.StackTrace)"
        } finally {
            # Ensure we always return a result object, even if validation threw an exception
            if(-not $ncResults) {
                $ncResults = @(@{
                Exception       = $exceptionMessage
                })
            }
        }

        # Process each NC server result returned from the validation
        foreach ($result in $ncResults) {
            # Check if the result object is valid and not null
            if ($result) {
                # Check if the result contains the 'Valid' key and if validation passed
                if ($result.containsKey('Valid') -and $result.Valid) {
                    # Validation succeeded - set success status and message
                    $ncServerStatus = $StatusSuccess
                    $ncServerDetail = $slbTxt.TestNCServerStatusPass
                } else {
                    # Validation failed - set failure status and extract error details
                    $ncServerStatus = $StatusFailure
                    if ($result.containsKey('Exception')) {
                    # Use exception message if available
                    $ncServerDetail = "$($result.Exception)"
                    } else {
                    # Otherwise format detailed failure message with server state information
                    $ncServerDetail = $slbTxt.TestNCServerStatusFail -f $result.Id, $result.Provisioning, $result.Configuration, $result.DetailMessage
                    }
                }
            } else {
                # Result is null - set failure status and create placeholder result object
                $ncServerStatus = $StatusFailure
                $ncServerDetail = $slbTxt.TestNCReturnNullFail
                $result = @{
                    Valid           = $false
                    Id              = "<NULL>"
                    Provisioning    = "<NULL>"
                    Configuration   = "<NULL>"
                    DetailSource    = "<NULL>"
                    DetailMessage   = "<NULL>"
                    DetailCode      = "<NULL>"
                }
            }

            # Construct the result object with all validation details for telemetry
            $NCServerResult = @{
                Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateNCServers'
                Title              = 'All Network Controller (NC) server state'
                DisplayName        = 'All Network Controller (NC) server state'
                Severity           = 'INFORMATIONAL'
                Description        = 'Test if all NC servers configuration and provisioning state are healthy.'
                Tags               = @{}
                Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateNCServers.md"
                TargetResourceID   = "NC server: " + $result.Id + ", " + $result.DetailMessage
                TargetResourceName = $result.DetailCode
                TargetResourceType = $result.DetailSource
                Timestamp          = [datetime]::UtcNow
                Status             = $ncServerStatus
                AdditionalData     = @{
                    Source    = $(hostname)
                    Resource  = $result.DetailSource
                    Detail    = $ncServerDetail
                    Status    = $ncServerStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            # Add the result object to the collection (one result per NC server)
            $ncServerResults += New-AzStackHciResultObject @NCServerResult
        }

        return $ncServerResults
    }
    catch {
        throw ("Exception testing NC servers: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates that IP pools across HNVPA, PublicVIP, and PrivateVIP networks do not overlap.

.DESCRIPTION
Test-SLB_ValidateOverlappingIPPools checks the provided NetworksConfiguration for overlapping IP pool ranges across all relevant SDN networks (HNVPA, PublicVIP, PrivateVIP).
It delegates the detailed check to ValidateOverlappingIPPools and returns a standardized result object describing success or failure along with a human-readable message suitable for telemetry/remediation.

.PARAMETER NetworksConfiguration
An object describing SDN networks and their subnets/IP pools. Expected to contain SDNIntegration.Networks with HNVPA, PublicVIP, and PrivateVIP entries.

.OUTPUTS
A New-AzStackHciResultObject-style PSCustomObject containing validation status, detailed message, and metadata.

.EXAMPLE
PS> Test-SLB_ValidateOverlappingIPPools -NetworksConfiguration $networksConfig

.NOTES
This validator is intended to be used by the Azure Stack HCI environment checker to ensure IP pool ranges do not conflict prior to SLB deployment.
#>
function Test-SLB_ValidateOverlappingIPPools {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $NetworksConfiguration
    )

    try {
        # Initialize validation result variables with default success state
        $overlappingStatus = $StatusSuccess
        $overlappingDetail = $slbTxt.TestOverlapIPPoolsPass
        $overlappingName = ""
        $overlappingID = ""

        # Validate that IP pools across all networks (HNVPA, PublicVIP, PrivateVIP) do not overlap
        $ipPoolsResult = ValidateOverlappingIPPools -NetworksConfiguration $NetworksConfiguration -ErrorAction Stop -Verbose

        # Check if validation failed (result is null or Valid property is false)
        if ($null -eq $ipPoolsResult -or -not $ipPoolsResult.Valid) {
            # Validation failed - extract error details from result object
            $overlappingStatus = $StatusFailure
            # Use message from result if available, otherwise use generic failure message
            $overlappingDetail = if ($ipPoolsResult -and $ipPoolsResult.Message) { $ipPoolsResult.Message } else { ($slbTxt.TestPropertyNullResultFail -f $PropertyIPPools) }
            # Extract the name of the property that failed validation
            $overlappingName = if ($ipPoolsResult -and $ipPoolsResult.Name) { $ipPoolsResult.Name } else { $PropertyIPPools }
            # Format resource ID with property name and value for telemetry
            $overlappingID = if ($ipPoolsResult -and $ipPoolsResult.Name -and $ipPoolsResult.Value) { SetPropertyFormat -Name $ipPoolsResult.Name -Value $ipPoolsResult.Value } else { "<NULL>" }
        }

        # Construct the result object with validation details for telemetry
        $OverlappingResult = @{
            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateOverlappingIPPools'
            Title              = 'Validate overlapping IP Pools'
            DisplayName        = 'Validate overlapping IP Pools'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if all IP pools are not overlapping each other'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateOverlappingIPPools.md"
            TargetResourceID   = $overlappingID
            TargetResourceName = $overlappingName
            TargetResourceType = $PropertyIPPools
            Timestamp          = [datetime]::UtcNow
            Status             = $overlappingStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $TypeNetworks
                Detail    = $overlappingDetail
                Status    = $overlappingStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        # Return the result object for this validation test
        return New-AzStackHciResultObject @OverlappingResult
    }
    catch {
        throw ("Exception testing IP pools: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
    Validates that there are enough management IP addresses available for SLB deployment in Azure Stack HCI.

.DESCRIPTION
    The Test-SLB_ValidateInfraIPPools function checks the available management IP pool size against the required number of IPs for SLB deployment.
    It calculates the required IPs based on the number of hosts and MUXes, and for new deployments, reserves one additional IP for SLBM.
    The function queries the ECE store for management subnet information and verifies that the available IPs meet the deployment requirements.
    Returns a result object indicating pass/fail and details.

.PARAMETER PSSession
    An array of PowerShell PSSession objects representing the target nodes for validation.

.PARAMETER IsDeployment
    Boolean indicating if this is a new deployment (reserves one additional IP for SLBM).

.PARAMETER SoftwareLoadbalancerConfiguration
    Optional. A PSCustomObject containing the Software Load Balancer configuration, including NumberOfMuxes.

.PARAMETER NumberOfMuxes
    Optional. The number of MUXes to use for validation if not specified in configuration.

.OUTPUTS
    Returns a result object indicating the outcome of the management IP pool validation, including status, details, and remediation steps if necessary.

.EXAMPLE
    PS C:\> Test-SLB_ValidateInfraIPPools -PSSession $sessions -IsDeployment $true -SoftwareLoadbalancerConfiguration $slbConfig

.NOTES
    - This function assumes that the required modules for ECE client are available and can be imported.
    - The function logs the validation result and provides remediation guidance if the validation fails.
    - Ensure that the provided parameters and sessions are accurate and up-to-date before running the validation.
#>
function Test-SLB_ValidateInfraIPPools {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [parameter(Mandatory = $false)]
        [boolean]
        $IsDeployment = $false,

        [parameter(Mandatory = $false)]
        [UInt16]
        $NumberOfMuxes = 0,

        [parameter(Mandatory = $false)]
        [PSCustomObject]
        $SoftwareLoadbalancerConfiguration
    )

    try {
        # Initialize variables to track IP requirements and availability
        $requiredIps = 0
        $availablePoolsize = 0
        $EnoughIpsStatus = $StatusSuccess
        $EnoughIpsMessage = ""
        $numberOfHosts = $PSSession.Count

        # Determine the number of required IPs based on MUXes configuration
        if((IsNullOrEmpty -Resource $SoftwareLoadbalancerConfiguration -TreatWhiteSpaceAsNull) -or (IsNullOrEmpty -Resource $SoftwareLoadbalancerConfiguration.NumberOfMuxes -TreatWhiteSpaceAsNull)) {
            # No SLB configuration or NumberOfMuxes specified - use default based on NumberOfMuxes parameter
            if ($NumberOfMuxes -eq 0) {
                # NumberOfMuxes not provided - calculate default based on number of hosts
                if ($numberOfHosts -eq 1) {
                    # Single node deployment requires 1 MUX
                    $requiredIps = 1
                }
                else { # Multinode deployment requires at least 2 MUXes
                    $requiredIps = 2
                }
            } else {
                # Use the NumberOfMuxes parameter value
                $requiredIps = $NumberOfMuxes
            }
        } else {
            # Use NumberOfMuxes from SLB configuration
            $requiredIps = $SoftwareLoadbalancerConfiguration.NumberOfMuxes
        }

        # For new deployments, reserve 1 additional IP address for SLBM (Software Load Balancer Manager)
        if ($IsDeployment) {
            $requiredIps++
        }

        # Query ECE store for management subnet IP availability
        $mgmtResult = $null
        $exceptionMessage = ""
        try {
            $availableIps = 0
            Import-Module ECEClient -Force -DisableNameChecking 3>$null 4>$null

            # Create ECE client to query cloud parameters
            $eceClient = Create-ECEClusterServiceClient
            $eceXml = [XML]($eceClient.GetCloudParameters().GetAwaiter().GetResult().CloudDefinitionAsXmlString)

            # Extract subnet ranges from ECE configuration
            $subnetRanges = $eceXml.Parameters.Category | Where-Object { $_.Name -eq "Subnet Ranges" }
            $mgmtSubnets = @($subnetRanges.parameter | Where-Object { $_.name -eq "Management Subnet" })

            # Validate management subnet configuration
            if (IsNullOrEmpty -Resource $mgmtSubnets -TreatWhiteSpaceAsNull) {
                throw "No management subnets found"
            } else {
                # Ensure exactly one management subnet exists
                if (@($mgmtSubnets).Count -eq 1) {
                    # Extract allocatable IPs from management subnet
                    if (-not (IsNullOrEmpty -Resource $mgmtSubnets[0] -TreatWhiteSpaceAsNull) -and  -not (IsNullOrEmpty -Resource $mgmtSubnets[0].AllocatableIps -TreatWhiteSpaceAsNull)) {
                        $availableIps = [int] ($mgmtSubnets[0].AllocatableIps - $mgmtSubnets[0].Mapping.Count)
                    } else {
                        throw "No allocatable IPs found for management subnet"
                    }
                } else {
                    throw "Multiple management subnets found, unable to determine available IPs"
                }
            }
            $mgmtResult = @{ AvailableIPs = $availableIps }
        } catch {
            # Capture exception details for error reporting
            $exceptionMessage = "$($_.Exception.Message)`n$($_.Exception.StackTrace)"
        } finally {
            # Ensure we always return a result object, even if validation threw an exception
            if(-not $mgmtResult) {
                $mgmtResult = @{ Exception = $exceptionMessage }
            }
        }

        # Process the script result and validate IP availability
        if ($mgmtResult) {
            if ($mgmtResult.containsKey('AvailableIPs')) {
                # Extract available IP count from result
                $availablePoolsize = [int] $mgmtResult.AvailableIPs
                Log-Info -Message "Found $availablePoolsize available management IPs. $requiredIps needed."

                # Check if available IPs meet the requirement
                if ($availablePoolsize -ge $requiredIps){
                    $EnoughIpsStatus = $StatusSuccess
                    $EnoughIpsMessage = $slbTxt.TestManagementIPsPass -f $availablePoolsize
                } else {
                    $EnoughIpsStatus = $StatusFailure
                    $EnoughIpsMessage = $slbTxt.TestManagementNotEnoughIPsFail -f $availablePoolsize, $requiredIps
                }
            } else {
                # Result doesn't contain AvailableIPs key - set failure status
                $EnoughIpsStatus = $StatusFailure
                if ($mgmtResult.containsKey('Exception')) {
                    # Use exception message if available
                    $EnoughIpsMessage = $mgmtResult.Exception
                } else {
                    # Otherwise use generic null result message
                    $EnoughIpsMessage = $slbTxt.TestManagementReturnNullFail
                }
            }
        } else {
            # Script result is null - set failure status with appropriate message
            $EnoughIpsStatus = $StatusFailure
            $EnoughIpsMessage = $slbTxt.TestManagementReturnNullFail
        }

        # Construct the result object with validation details for telemetry
        $EnoughManagementIpsRstObject = @{
            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateInfraIPPools'
            Title              = 'Check management IP addresses'
            DisplayName        = 'Check management IP addresses'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if we have enough management IP addresses'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateInfraIPPools.md"
            TargetResourceID   = "ManagementIPAddresses"
            TargetResourceName = "ManagementIPAddresses"
            TargetResourceType = "ManagementIPAddresses"
            Timestamp          = [datetime]::UtcNow
            Status             = $EnoughIpsStatus
            AdditionalData     = @{
                Source    =  $(hostname)
                Resource  = 'ManagementIPAddresses'
                Detail    = $EnoughIpsMessage
                Status    = $EnoughIpsStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        # Return the result object for this validation test
        return New-AzStackHciResultObject @EnoughManagementIpsRstObject
    }
    catch {
        throw ("Exception testing management IP pools: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

function Test-SLB_ValidateDNSName {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $SoftwareLoadbalancerConfiguration,

        [parameter(Mandatory = $true)]
        [string]
        $SDNPrefix
    )

    try {
        # Initialize variables for DNS resolution validation
        $resolveDNSStatus = $StatusSuccess
        $resolveDNSMessage = $slbTxt.TestDNSResolutionPass
        $NumberOfMuxes = 0

        if ($SoftwareLoadbalancerConfiguration) {
            if(IsNullOrEmpty -Resource $SoftwareLoadbalancerConfiguration.NumberOfMuxes -TreatWhiteSpaceAsNull) {
                # Set default based on number of hosts
                if ($numberOfHosts -eq 1) {
                    $NumberOfMuxes = 1
                }
                else {   #Multinode
                    $NumberOfMuxes = 2
                }
            }
            else {
                $NumberOfMuxes = $SoftwareLoadbalancerConfiguration.NumberOfMuxes
            }
        }

        # Set connection to Network Controller
        SetNCConnection

        # Retrieve NC role parameters from ECE configuration
        $cloudParams = Get-EceLiteRoleParameters -RoleName Cloud
        $cloudRole = $cloudParams.Roles["Cloud"].PublicConfiguration
        $isADLess = $cloudRole.PublicInfo.DeployADLess
        $needToVerifyDNS = $true

        # If ADLess deployment with internal DNS configured, skip DNS verification
        # Otherwise, perform DNS name resolution verification
        if($isADLess -eq 'True'){
            $isInternalDns = $cloudRole.PublicInfo.NetworkConfiguration.ConfigureInternalDNS
            if ($isInternalDns -is [string]) {
                if ([string]::IsNullOrEmpty($isInternalDns)) {
                    $isInternalDns = $false
                } else {
                    $isInternalDns = [System.Convert]::ToBoolean($isInternalDns)
                }
            }

            if ($isInternalDns) {
                $needToVerifyDNS = $false
            }
        }

        # Perform DNS name resolution verification if required
        if($needToVerifyDNS){
            # Get management intent names to identify management NIC
            $intentNames = @(Get-NetIntent | Where-Object { $_.IsManagementIntentSet} | Select-Object IntentName)
            if($intentNames.Count -gt 0){
                $mgmtNicIndex = Get-NetAdapter -Name "vManagement($($intentNames[0].IntentName))" | Select-Object ifIndex
                $registered = Get-DnsClient -InterfaceIndex $($mgmtNicIndex.ifIndex) | Select-Object RegisterThisConnectionsAddress

                # Only verify DNS resolution if the management NIC is not set to register its address
                if($registered.RegisterThisConnectionsAddress -ne $true){
                    $domainParams = Get-EceLiteRoleParameters -RoleName Domain
                    $domainRole = $domainParams.Roles["Domain"].PublicConfiguration

                    [string]$fqdnName = "$($domainRole.PublicInfo.DomainConfiguration.FQDN)"
                    $result = IsResolveDNSName -MuxCount $NumberOfMuxes -SDNPrefix $SDNPrefix -FqdnName $fqdnName -ErrorAction Stop -Verbose
                    $resolveDNSStatus = $result.Status
                    $resolveDNSMessage = $result.Message
                }
            } else {
                $resolveDNSStatus = $StatusFailure
                $resolveDNSMessage = $slbTxt.TestDNSResolutionException -f "No management intent found"
            }
        }

        # Construct the result object with validation details for telemetry
        $ResolveDNSResult = @{
            Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidateDNSName'
            Title              = 'Resolve DNS Name for SLB VMs'
            DisplayName        = 'Resolve DNS Name for SLB VMs'
            Severity           = 'INFORMATIONAL'
            Description        = 'Test if the DNS names for SLB VMs can be resolved'
            Tags               = @{}
            Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidateDNSName.md"
            TargetResourceID   = 'DNS resolution for SLB VMs'
            TargetResourceName = $TypeSLB
            TargetResourceType = 'DNS resolution for SLB VMs'
            Timestamp          = [datetime]::UtcNow
            Status             = $resolveDNSStatus
            AdditionalData     = @{
                Source    = $(hostname)
                Resource  = $TypeSLB
                Detail    = $resolveDNSMessage
                Status    = $resolveDNSStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        # Return the result object for this validation test
        return New-AzStackHciResultObject @ResolveDNSResult
    }
    catch {
        throw ("Exception testing DNS resolution: {0}`nError Message: {1}`nStack Trace: {2}" -f $_.Exception, $_.Exception.Message, $_.ScriptStackTrace)
    }
}

<#
.SYNOPSIS
Validates the configuration of public or private VIP (Virtual IP) networks, ensuring correct subnet and IP pool settings.

.DESCRIPTION
The ValidatePublicPrivateVIPNetworksCheck function iterates through a collection of VIP network objects and validates their configuration based on whether they are expected to be public or private. It checks for the following:
- Network virtualization must not be enabled for public/private VIP networks.
- Each subnet must match the expected public/private status.
- IP pool start and end addresses must be valid and in the correct order.

If any validation fails, the function calls ValidatePublicPrivateVIPNetworksResult with a failure status and a detailed message.

.PARAMETER VIPs
An array of PSCustomObject instances representing the VIP networks to be validated. Each object should contain properties for NetworkVirtualizationEnabled, ResourceId, and Subnets.

.PARAMETER IsPublic
A boolean value indicating whether the VIP networks are expected to be public ($true) or private ($false). Default is $false.

.EXAMPLE
ValidatePublicPrivateVIPNetworksCheck -VIPs $vipNetworks -IsPublic $true

Validates that the provided VIP networks are configured as public networks.

.NOTES
- This function is intended for use in Azure Stack HCI network validation scenarios.
- The function assumes that each VIP object and its sub-properties are structured as expected.

#>
function ValidatePublicPrivateVIPNetworksCheck {
    [CmdletBinding()]
    param (
        [PSObject[]]
        $VIPs,

        [string]
        $NetworkType
    )

    # Initialize result parameters with default success state
    $resultParams = @{Status= $StatusSuccess; Message=$($slbTxt.TestVIPPass -f $NetworkType); Name=""; ID=""; Type=$NetworkType;}

    # Iterate through each VIP network to validate its configuration
    foreach ($vip in $VIPs) {
        # Iterate through each subnet within the VIP network
        foreach ($subnet in $vip.Subnets) {
            # Validate basic subnet properties (AddressPrefix, VlanId, IpPools)
            $subnetResult = ValidateSubnetProperties -Subnet $subnet -NetworkType $NetworkType
            if (-not $subnetResult -or -not $subnetResult.Valid) {
                # Subnet validation failed - set failure status and extract error details
                $resultParams.Status  = $StatusFailure
                $resultParams.Message = if ($subnetResult -and $subnetResult.Message) { $subnetResult.Message } else { $slbTxt.TestNullResultSLBFail }
                $resultParams.Name    = if ($subnetResult -and $subnetResult.Name) { $subnetResult.Name } else { "<NULL>" }
                $resultParams.ID      = if ($subnetResult -and $subnetResult.Name -and $subnetResult.Value) { SetPropertyFormat -Name $subnetResult.Name -Value $subnetResult.Value } else { "<NULL>" }
                break
            }

            # Validate IP pools configuration (start/end addresses, ranges, no gateway conflicts)
            $ipPoolsResult = ValidateIPPools -Subnet $subnet -NetworkType $NetworkType
            if (-not $ipPoolsResult -or -not $ipPoolsResult.Valid) {
                # IP pools validation failed - set failure status and extract error details
                $resultParams.Status  = $StatusFailure
                $resultParams.Message = if ($ipPoolsResult -and $ipPoolsResult.Message) { $ipPoolsResult.Message } else { $slbTxt.TestNullResultSLBFail }
                $resultParams.Name    = if ($ipPoolsResult -and $ipPoolsResult.Name) { $ipPoolsResult.Name } else { "<NULL>" }
                $resultParams.ID      = if ($ipPoolsResult -and $ipPoolsResult.Name -and $ipPoolsResult.Value) { SetPropertyFormat -Name $ipPoolsResult.Name -Value $ipPoolsResult.Value } else { "<NULL>" }
                break
            }
        }
        # If any subnet validation failed, exit the VIP loop early
        if ($resultParams.Status -eq $StatusFailure) { break }
    }

    return ValidatePublicPrivateVIPNetworksResult -Result $resultParams
}

# Helper function to log and return the result object for Public/Private VIP network validation
<#
.SYNOPSIS
    Validates the presence of public and private VIP networks and logs the result.

.DESCRIPTION
    This function logs the validation result for checking the existence of public and private IP addresses.
    It constructs a result object with detailed information about the validation and returns it as a standardized result object.

.PARAMETER Status
    The status of the validation (e.g., 'Success', 'Failure', etc.).

.PARAMETER DetailedMessage
    A detailed message describing the result of the validation.

.EXAMPLE
    ValidatePublicPrivateVIPNetworksResult -Status "Success" -DetailedMessage "Public and private IPs are configured correctly."

.NOTES
    The function uses the environment variable 'EnvChkrId' for the HealthCheckSource property.
#>
function ValidatePublicPrivateVIPNetworksResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Result
    )

    $PublicPrivateVIPsRstObject = @{
        Name               = 'AzStackHci_NetworkSLB_Test-SLB_ValidatePublicPrivateVIPNetworks'
        Title              = 'Check public and private Virtual IP (VIP) addresses'
        DisplayName        = 'Check public and private Virtual IP (VIP) addresses'
        Severity           = 'INFORMATIONAL'
        Description        = 'Test if we have valid public and/or private VIP addresses'
        Tags               = @{}
        Remediation        = "https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/EnvironmentValidator/SLB/Troubleshoot-Test-SLB_ValidatePublicPrivateVIPNetworks.md"
        TargetResourceID   = "$($Result.ID)"
        TargetResourceName = "$($Result.Name)"
        TargetResourceType = "$($Result.Type)"
        Timestamp          = [datetime]::UtcNow
        Status             = "$($Result.Status)"
        AdditionalData     = @{
            Source    = $(hostname)
            Resource  = "$($Result.Type)"
            Detail    = "$($Result.Message)"
            Status    = "$($Result.Status)"
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    Return New-AzStackHciResultObject @PublicPrivateVIPsRstObject
}

<#
.SYNOPSIS
    Imports the Network Controller (NC) PowerShell modules and establishes a connection to the Network Controller.

.DESCRIPTION
    The SetNCConnection function retrieves the NC deployment package path and imports all required
    NC PowerShell modules (NC.psd1, NC.psm1, Common.psm1, CommonNC.psm1, NetworkControllerFc.psm1).
    It then retrieves the Network Controller connection information from the registry, obtains the
    appropriate client certificate, and establishes a connection to the Network Controller.
    This helper function centralizes the module import and connection logic to avoid code duplication
    across multiple SLB validation functions.

.OUTPUTS
    None. The function imports modules into the current session and establishes an NC connection.

.EXAMPLE
    SetNCConnection

.NOTES
    This function is used internally by SLB validation functions that require NC module functionality
    and connectivity to the Network Controller.
#>
function SetNCConnection {

    # Import required NC modules
    #Import-Module ECEClient -DisableNameChecking 3>$null 4>$null
    $packagePath = Get-ASArtifactPath -NugetName "Microsoft.AS.Network.Deploy.NC" -Verbose:$false 3>$null 4>$null
    Import-Module "$packagePath\content\Powershell\Roles\NC\NC.psd1" -Force -DisableNameChecking 3>$null 4>$null
    Import-Module "$packagePath\content\Powershell\Roles\NC\NC.psm1" -Force -DisableNameChecking 3>$null 4>$null
    Import-Module "$packagePath\content\Powershell\Roles\NC\Common.psm1" -Force -DisableNameChecking 3>$null 4>$null
    Import-Module "$packagePath\content\Powershell\Roles\NC\CommonNC.psm1" -Force -DisableNameChecking 3>$null 4>$null
    Import-Module "$packagePath\content\Powershell\Roles\NC\NetworkControllerFc.psm1" -Force -DisableNameChecking 3>$null 4>$null

    # Retrieve Network Controller connection information from registry
    $NCRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters"
    $subjectCN = Get-ItemPropertyValue -Path $NCRegPath -Name "PeerCertificateCName"

    # Get client certificate for NC authentication
    $certs = Get-ChildItem "Cert:\localmachine\my"
    $clientCert = Get-CertificateByHostName -certs $certs -hostName $subjectCN -isServer $false

    # Establish connection to Network Controller
    Set-NCConnection -RestName $subjectCN -NCCertificate $clientCert
}

<#
.SYNOPSIS
    Validates core properties of a subnet used by HNVPA, PublicVIP, and PrivateVIP networks.

.DESCRIPTION
    ValidateSubnetProperties verifies that a given subnet object includes required and well-formed properties
    necessary for SLB validation. The function checks:
      - AddressPrefix is present and in CIDR format (for example "10.0.0.0/24").
      - VlanId is present and within the allowed range (0-4096).
      - IpPools are present and contain at least one entry.

    On failure the function returns a descriptive message suitable for telemetry/remediation. The returned object
    is a hashtable with keys:
      - Valid   : [bool] indicates whether the subnet passed validation.
      - Message : [string] contains a localized failure description when Valid is $false.

.PARAMETER Subnet
    A PSCustomObject describing the subnet to validate. Expected properties include AddressPrefix, VlanId, and IpPools.

.PARAMETER NetworkType
    Optional. A string used in error messages to identify the network type being validated (defaults to 'HNVPA').

.OUTPUTS
    Hashtable with properties Valid ([bool]) and Message ([string]).

.EXAMPLE
    $result = ValidateSubnetProperties -Subnet $subnet -NetworkType 'Public'
    if (-not $result.Valid) { Write-Error $result.Message }

.NOTES
    This helper is intended for internal use by SLB validators to centralize basic subnet validation logic
    and to produce consistent localized messages via the $slbTxt localization resource.
#>
function ValidateSubnetProperties {
    [CmdletBinding()]
    param (
        [PSCustomObject]
        $Subnet,

        [string]
        $NetworkType
    )

    # Check for null or empty subnet object
    if(IsNullOrEmpty -Resource $Subnet -TreatWhiteSpaceAsNull) {
        return @{Valid=$false; Message=$($slbTxt.TestNetworkPropertyFail -f $NetworkType, $PropertySubnets); Name=$PropertySubnets; Value="<NULL>"}
    }

    # Validate AddressPrefix is present and in correct CIDR format (e.g., "10.0.0.0/24")
    if ($null -eq $Subnet.AddressPrefix -or $Subnet.AddressPrefix -eq '') {
        # AddressPrefix is missing - return failure with appropriate message
        return @{Valid=$false; Message=$($slbTxt.TestNetworkPropertyFail -f $NetworkType, $PropertyAddressPrefix); Name=$PropertyAddressPrefix; Value="<NULL>"}
    } else {
        # Validate AddressPrefix format using CIDR regex pattern
        # Pattern matches IPv4 address (0-255 for each octet) followed by /prefix (0-32)
        $cidrPattern = '^((25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\/([0-9]|[1-2][0-9]|3[0-2])$'
        if (-not ($Subnet.AddressPrefix -match $cidrPattern)) {
            # AddressPrefix format is invalid - return failure with current value
            return @{Valid=$false; Message=$($slbTxt.TestInvalidFormatFail -f $PropertyAddressPrefix, $NetworkType); Name=$PropertyAddressPrefix; Value=$Subnet.AddressPrefix}
        }
    }

    # Validate VlanId is present and within valid range (0-4095)
    if ($null -eq $Subnet.VlanId -or -not ($Subnet.VlanId -match '^\d+$') -or $Subnet.VlanId -lt 0 -or $Subnet.VlanId -gt 4095) {
        # VlanId is missing, not numeric, or out of valid range - return failure
        return @{Valid=$false; Message=$($slbTxt.TestNetworkPropertyFail -f $NetworkType, $PropertyVlanId); Name=$PropertyVlanId; Value=$Subnet.VlanId}
    }

    # Validate IP Pools are present and contain at least one entry
    if ($null -eq $Subnet.IpPools -or @($Subnet.IpPools).Count -eq 0) {
        # No IP pools found - return failure as at least one pool is required
        return @{Valid=$false; Message=$($slbTxt.TestNetworkPropertyFail -f $NetworkType, $PropertyIPPools); Name=$PropertyIPPools; Value="<NULL>"}
    }

    # All subnet property validations passed successfully
    return @{ Valid=$true; Message=""; Name=""; Value="" }
}

<#
.SYNOPSIS
    Validates DefaultGateway entries for a subnet.

.DESCRIPTION
    ValidateDefaultGateways verifies that a given subnet contains one or more DefaultGateway entries,
    that each gateway is a valid IPv4 address, and that each gateway resides within the subnet defined
    by AddressPrefix. On failure the function returns a hashtable with keys:
      - Valid   : [bool] indicates whether the subnet passed validation.
      - Message : [string] contains a localized failure description when Valid is $false.

PARAMETER Subnet
    A PSCustomObject describing the subnet to validate. Expected properties include AddressPrefix and DefaultGateways.

PARAMETER NetworkType
    Optional. A string used in error messages to identify the network type being validated (defaults to HNVPA).

.OUTPUTS
    Hashtable with properties Valid ([bool]) and Message ([string]).

.EXAMPLE
    $result = ValidateDefaultGateways -Subnet $subnet -NetworkType 'Public'
    if (-not $result.Valid) { Write-Error $result.Message }

.NOTES
    This helper is intended for internal use by SLB validators to centralize DefaultGateway validation logic
    and to produce consistent localized messages via the $slbTxt localization resource.
#>
function ValidateDefaultGateways {
    [CmdletBinding()]
    param (
        [PSCustomObject]
        $Subnet,

        [string]
        $NetworkType
    )

    # Initialize result object with default success state
    $resultObj = @{Valid=$true; Message=""; Name=""; Value=""}

    # Validate that at least one DefaultGateway exists in the subnet
    if ($null -eq $Subnet.DefaultGateways -or @($Subnet.DefaultGateways).Count -eq 0) {
        # No default gateways found - return failure with appropriate message
        return @{Valid=$false; Message=$($slbTxt.TestNetworkPropertyFail -f $NetworkType, $PropertyDefaultGateways); Name=$PropertyDefaultGateways; Value="<NULL>"}
    }

    # Get subnet range information to validate gateway membership
    # Extract mask and network address for subnet membership checks
    $prefixRange = GetAddressRange -addressPrefix $Subnet.AddressPrefix
    $mask = $prefixRange.Mask
    $prefixStart = $prefixRange.Start

    # Validate each default gateway is a valid IP and belongs to the subnet
    foreach ($gateway in $Subnet.DefaultGateways) {
        # Attempt to parse gateway as IPv4 address
        $gatewayIP = $gateway -as [System.Net.IPAddress]
        if ($null -ne $gatewayIP) {
            # Gateway is a valid IP - check if it belongs to the subnet's address space
            $gatewayInt = ConvertToUInt32([System.Net.IPAddress]::Parse($gatewayIP))
            if (($gatewayInt -band $mask) -ne ($prefixStart -band $mask)) {
                # Gateway is not in the subnet's address range - return failure
                $resultObj =  @{Valid=$false; Message=$($slbTxt.TestNotInSubnetHNVPAFail -f $PropertyDefaultGateways, $gatewayIP, $Subnet.AddressPrefix); Name=$PropertyDefaultGateways; Value=$gatewayIP}
                break
            }
        } else {
            # Gateway could not be parsed as a valid IP address - return failure
            $resultObj = @{Valid=$false; Message=$($slbTxt.TestInvalidFormatFail -f $PropertyDefaultGateways, $NetworkType); Name=$PropertyDefaultGateways; Value="<NULL>"}
            break
        }
    }

    return $resultObj
}

<#
.SYNOPSIS
    Validates IP pool entries for a subnet and ensures they meet SLB requirements.

.DESCRIPTION
    ValidateIPPools verifies that each IP pool in the provided subnet:
      - Contains valid StartIPAddress and EndIPAddress values.
      - Has Start < End.
      - Has addresses that belong to the subnet defined by AddressPrefix.
      - Does not include any DefaultGateways.
    It also computes the total available IPs across all pools and verifies the total meets the minimum
    requirement calculated as (2 * NumberOfHosts) + NumberOfMuxes.

PARAMETER Subnet
    A PSCustomObject describing the subnet to validate. Expected properties include AddressPrefix, IpPools and DefaultGateways.

PARAMETER NetworkType
    Optional. A string used in error messages to identify the network type being validated (defaults to HNVPA).

PARAMETER NumberOfHosts
    Number of hosts in the deployment used to compute IP requirements.

PARAMETER NumberOfMuxes
    Number of MUXes (SLB nodes) in the deployment used to compute IP requirements.

.OUTPUTS
    Hashtable with properties Valid ([bool]) and Message ([string]).

.EXAMPLE
    $result = ValidateIPPools -Subnet $subnet -NetworkType $networkType -NumberOfHosts 4 -NumberOfMuxes 2
    if (-not $result.Valid) { Write-Error $result.Message }

.NOTES
    This helper is intended for internal use by SLB validators to centralize IP pool validation logic
    and to produce consistent localized messages via the $slbTxt localization resource.
#>
function ValidateIPPools {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [PSCustomObject]
        $Subnet,

        [Parameter(Mandatory = $false)]
        [string]
        $NetworkType
    )

    # Initialize result object with default success state and zero available IPs
    $resultObj = @{Valid = $true; Message = ""; Name = ""; Value = ""; AvailableIPs = 0}

    # Track total available IPs across all pools in this subnet
    $availableIPs = 0

    # Get subnet range information (mask, start, end) for validation
    $prefixRange = GetAddressRange -addressPrefix $Subnet.AddressPrefix
    $mask = $prefixRange.Mask
    $prefixStart = $prefixRange.Start

    # Validate each IP pool in the subnet
    # Use labeled loop to allow breaking from nested gateway validation
    :outerloop foreach ($ipPool in @($Subnet.IpPools)) {

        # Validate StartIPAddress and EndIPAddress are valid IPv4 addresses
        $startIP = $ipPool.StartIPAddress -as [System.Net.IPAddress]
        $endIP = $ipPool.EndIPAddress -as [System.Net.IPAddress]
        if ($null -eq $startIP -or $null -eq $endIP) {
            # IP addresses are invalid or missing - return failure
            $resultObj = @{
                Valid       = $false
                Message     = $($slbTxt.TestNetworkPropertyFail -f $NetworkType, $PropertyIPPools)
                Name        = $PropertyIPPools
                Value       = "<NULL>"
                AvailableIPs = 0
            }
            break
        }

        # Convert IP addresses to UInt32 for numeric comparison
        # EndIP must be greater than StartIP
        $startInt = ConvertToUInt32([System.Net.IPAddress]::Parse($startIP))
        $endInt = ConvertToUInt32([System.Net.IPAddress]::Parse($endIP))
        if ($startInt -ge $endInt) {
            # Invalid range - StartIP must be less than EndIP
            $resultObj = @{
                Valid       = $false
                Message     = $($slbTxt.TestInvalidStartEndFail -f $PropertyIPPools, $NetworkType, $startIP, $endIP)
                Name        = $PropertyIPPools
                Value       = "$startIP >= $endIP"
                AvailableIPs = 0
            }
            break
        }

        # Validate StartIP belongs to the subnet's address space
        if (($startInt -band $mask) -ne ($prefixStart -band $mask)) {
            # StartIP is not in the subnet's address range - return failure
            $resultObj = @{
                Valid       = $false
                Message     = $($slbTxt.TestNotInSubnetHNVPAFail -f 'StartIPAddress', $startIP, $subnet.AddressPrefix)
                Name        = $PropertyIPPools
                Value       = "$startIP not in $subnet.AddressPrefix"
                AvailableIPs = 0
            }
            break
        }

        # Validate EndIP belongs to the subnet's address space
        if (($endInt -band $mask) -ne ($prefixStart -band $mask)) {
            # EndIP is not in the subnet's address range - return failure
            $resultObj = @{
                Valid       = $false
                Message     = $($slbTxt.TestNotInSubnetHNVPAFail -f 'EndIPAddress', $endIP, $subnet.AddressPrefix)
                Name        = $PropertyIPPools
                Value       = "$endIP not in $subnet.AddressPrefix"
                AvailableIPs = 0
            }
            break
        }

        # Validate that no DefaultGateways fall within this IP pool range
        # Gateways must be excluded from allocatable IP pools
        foreach ($gateway in $Subnet.DefaultGateways) {
            $gatewayIP = $gateway -as [System.Net.IPAddress]
            $gatewayInt = ConvertToUInt32([System.Net.IPAddress]::Parse($gatewayIP))
            # Check if gateway is within the IP pool range [startInt, endInt]
            if (($startInt -ge $gatewayInt) -ne ($gatewayInt -le $endInt)) {
                # Gateway is within the IP pool range - return failure
                $resultObj = @{
                    Valid       = $false
                    Message     = $($slbTxt.TestDefaultGatewayInPoolHNVPAFail -f $PropertyDefaultGateways, $gatewayIP, $startIP, $endIP)
                    Name        = $PropertyDefaultGateways
                    Value       = "$gatewayIP in [$startIP, $endIP]"
                    AvailableIPs = 0
                }
                # Break out of both loops since we found a validation failure
                break outerloop
            }
        }

        # Calculate total available IPs in this pool (inclusive of start and end)
        $availableIPs += $endInt - $startInt + 1
    }

    # If any validation failed, return the failure result object
    if (-not $resultObj.Valid) {
        return $resultObj
    }

    # All validations passed - return success with total available IPs
    return @{ Valid = $true; Message = ""; Name = ""; Value = ""; AvailableIPs = $availableIPs }
}

<#
.SYNOPSIS
    Validate that a subnet's AddressPrefix does not overlap with previously seen prefixes.

.DESCRIPTION
    Ensures the Subnet.AddressPrefix is in CIDR form and checks that it does not overlap with any prefixes
    already provided via the AddressPrefixes [ref] parameter. On success the prefix is appended to
    AddressPrefixes.Value. Returns a hashtable: @{ Valid = [bool]; Message = [string] } suitable for callers.

.PARAMETER Subnet
    PSCustomObject describing the subnet. Must contain an AddressPrefix property.

.PARAMETER AddressPrefixes
    [ref] to an array (or list) of address prefix strings already validated. This function appends the
    current subnet prefix on success.

.OUTPUTS
    Hashtable with 'Valid' and 'Message' keys.

.NOTES
    This helper is used by SLB validators to detect overlapping address prefixes across networks.
#>
function ValidateAddressPrefixes {
    [CmdletBinding()]
    param (
        [PSCustomObject]
        $Subnet,

        [PSObject[]]
        $AddressPrefixes
    )

    # Initialize result object with default success state
    $resultObj = @{Valid = $true; Message = ""; Name = ""; Value = ""}

    # Parse the current subnet's address prefix to get numeric range boundaries
    $prefixRange = GetAddressRange -addressPrefix $Subnet.AddressPrefix
    $prefixStart = $prefixRange.Start
    $prefixEnd = $prefixRange.End

    # Check if there are any previously validated address prefixes to compare against
    if ($AddressPrefixes.Count -gt 0) {
        # Check for overlapping address prefixes with previously validated subnets
        foreach ($existing in $AddressPrefixes) {
            # Parse the existing address prefix to get its numeric range
            $existingRange = GetAddressRange -addressPrefix $existing

            # Check if the current prefix overlaps with the existing prefix
            # Two ranges overlap if: (end1 >= start2) AND (end2 >= start1)
            if ($prefixEnd -ge $existingRange.Start -and $existingRange.End -ge $prefixStart) {
                # Overlap detected - set failure status with detailed message
                $resultObj = @{
                    Valid  = $false
                    Message = $($slbTxt.TestOverlapAddressPrefixFail -f $PropertyAddressPrefix, $Subnet.AddressPrefix, $existing)
                    Name   = $PropertyAddressPrefix
                    Value  = "$($Subnet.AddressPrefix) overlaps with $existing"
                }
                break
            }
        }

        # Add the current prefix to the list of validated prefixes
        $AddressPrefixes += $Subnet.AddressPrefix
    } else {
        # This is the first prefix being validated - initialize the array
        $AddressPrefixes = @($Subnet.AddressPrefix)
    }

    # Return the validation result
    return $resultObj
}

<#
.SYNOPSIS
    Validates that IP pools across HNVPA, PublicVIP and PrivateVIP networks do not overlap.

.DESCRIPTION
    ValidateOverlappingIPPools inspects the provided NetworksConfiguration for IP pool ranges
    defined under the SDNIntegration.Networks (HNVPA, PublicVIP and PrivateVIP). It ensures:
      - Each IP pool StartIPAddress and EndIPAddress are valid IPv4 addresses.
      - StartIPAddress is less than EndIPAddress for every pool.
      - No two IP pools (across all relevant networks/subnets) overlap.

    On success the function returns @{ Valid = $true; Message = '' }.
    On failure it returns @{ Valid = $false; Message = <localized failure text> } suitable for
    telemetry and remediation guidance.

.PARAMETER NetworksConfiguration
    PSCustomObject describing SDN networks and their subnets/ip pools. Expected layout:
    $NetworksConfiguration.{HNVPA,PublicVIP,PrivateVIP}[*].Subnets[*].IpPools[*]

.OUTPUTS
    Hashtable with keys:
      - Valid   : [bool] indicates overall validation success.
      - Message : [string] localized failure description when Valid is $false.

.EXAMPLE
    $result = ValidateOverlappingIPPools -NetworksConfiguration $networksConfig
    if (-not $result.Valid) { Write-Error $result.Message }

.NOTES
    This helper is intended for internal use by SLB validators and uses the $slbTxt
    localization resource for user-facing messages.
#>
function ValidateOverlappingIPPools {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [PSCustomObject]
        $NetworksConfiguration
    )

    # Initialize result object with default success state
    $resultObj = @{Valid = $true; Message = $slbTxt.TestOverlapIPPoolsPass; Name = ""; Value = ""}

    # Array to store all IP pool ranges as UInt32 values for fast numeric comparison
    $existingArray = @()  # Array of StartIPAddress and EndIPAddress as UInt32

    # Collect all networks that need to be checked for overlapping IP pools
    $networks = @()
    if (-Not (IsNullOrEmpty -Resource @($NetworksConfiguration.HNVPA))) {
        $networks += $NetworksConfiguration.HNVPA
    }

    if (-Not (IsNullOrEmpty -Resource @($NetworksConfiguration.PublicVIP))) {
        $networks += $NetworksConfiguration.PublicVIP
    }

    if (-Not (IsNullOrEmpty -Resource @($NetworksConfiguration.PrivateVIP))) {
        $networks += $NetworksConfiguration.PrivateVIP
    }

    # Use labeled loop to allow breaking from nested loops when overlap is detected
    :exitloop foreach ($net in $networks) {
        # Iterate through each subnet in the current network
        foreach ($subnet in $net.Subnets) {
            # Iterate through each IP pool in the current subnet
            foreach ($ipPool in $subnet.IpPools) {
                # Parse and convert IP pool boundaries to UInt32 for numeric comparison
                $startIP = $ipPool.StartIPAddress -as [System.Net.IPAddress]
                $endIP = $ipPool.EndIPAddress -as [System.Net.IPAddress]
                $startInt = ConvertToUInt32([System.Net.IPAddress]::Parse($startIP))
                $endInt = ConvertToUInt32([System.Net.IPAddress]::Parse($endIP))

                # Check for overlapping IP pools against all previously validated pools
                if ($existingArray.Count -gt 0) {
                    foreach ($customObject in $existingArray) {
                        # Two ranges overlap if: (end1 >= start2) AND (end2 >= start1)
                        if ($endInt -ge $customObject.IntStartIP -and $customObject.IntEndIP -ge $startInt) {
                            # Overlap detected - convert existing pool boundaries back to IP addresses for error message
                            $customStartIP = ConvertFromUInt32($customObject.IntStartIP)
                            $customEndIP = ConvertFromUInt32($customObject.IntEndIP)

                            # Set failure status with detailed overlap information
                            $resultObj.Valid = $false
                            $resultObj.Message = $slbTxt.TestOverlapIPPoolsFail -f $PropertyIPPools, $startIP, $endIP, $customStartIP, $customEndIP
                            $resultObj.Name = $PropertyIPPools
                            $resultObj.Value = "[$startIP, $endIP] overlaps with [$customStartIP, $customEndIP]"

                            # Exit all loops immediately since we found an overlap
                            break exitloop
                        }
                    }
                }

                # No overlap found - add current pool to the list of validated pools
                $existingArray += [PSCustomObject]@{ IntStartIP = $startInt; IntEndIP = $endInt }
            }
        }
    }

    # Return validation result (success if no overlaps found, failure otherwise)
    return $resultObj
}

<#
.SYNOPSIS
    Validates core properties of a subnet used by HNVPA, PublicVIP, and PrivateVIP networks.

.DESCRIPTION
    ValidateSubnetProperties verifies that a given subnet object includes required and well-formed properties
    necessary for SLB validation. The function checks:
      - AddressPrefix is present and in CIDR format (for example "10.0.0.0/24").
      - VlanId is present and within the allowed range (0-4096).
      - IpPools are present and contain at least one entry.

    On failure the function returns a descriptive message suitable for telemetry/remediation. The returned object
    is a hashtable with keys:
      - Valid   : [bool] indicates whether the subnet passed validation.
      - Message : [string] contains a localized failure description when Valid is $false.

.PARAMETER Subnet
    A PSCustomObject describing the subnet to validate. Expected properties include AddressPrefix, VlanId, and IpPools.

.PARAMETER NetworkType
    Optional. A string used in error messages to identify the network type being validated (defaults to 'HNVPA').

.OUTPUTS
    Hashtable with properties Valid ([bool]) and Message ([string]).

.EXAMPLE
    $result = ValidateSubnetProperties -Subnet $subnet -NetworkType 'Public'
    if (-not $result.Valid) { Write-Error $result.Message }

.NOTES
    This helper is intended for internal use by SLB validators to centralize basic subnet validation logic
    and to produce consistent localized messages via the $slbTxt localization resource.
#>
function ValidateSLBProperties {
    [CmdletBinding()]
    param (
        [PSCustomObject]
        $SLB
    )

    # If Valid is $true, Message, Name and Value are empty strings
    # If Valid is $false, Message, Name and Value contains the failure reason
    # Message is localized text suitable for telemetry/remediation
    # Name is the property name that failed validation
    # Value is the actual property value that failed validation
    $returnObj = @{Valid = $true; Message = ""; Name = ""; Value = ""}

    # Validate NumberOfMuxes property if present
    # MUX count must be between 1 and 3 (inclusive)
    if($null -ne $SLB.PSObject.Properties['NumberOfMuxes']) {
        if ((IsNullOrEmpty -Resource $SLB.NumberOfMuxes -TreatWhiteSpaceAsNull) -or $SLB.NumberOfMuxes -lt 1 -or $SLB.NumberOfMuxes -gt 3) {
            return @{Valid = $false; Message = $slbTxt.TestSLBPropertyFail -f $PropertyNumberOfMuxes, $SLB.NumberOfMuxes; Name = $PropertyNumberOfMuxes; Value = "$($SLB.NumberOfMuxes)"}
        }
    }

    # Validate BGPInfo is present
    # BGP configuration is required for SLB to advertise VIP routes
    if (IsNullOrEmpty -Resource $SLB.BGPInfo -TreatWhiteSpaceAsNull) {
        return @{Valid = $false; Message = $slbTxt.TestSLBPropertyFail -f $PropertyBGPInfo, $SLB.BGPInfo; Name = $PropertyBGPInfo; Value = "<NULL>"}
    }

    # Validate LocalASN (Autonomous System Number)
    # Must be a valid 32-bit ASN (0 to 4294967295)
    if ((IsNullOrEmpty -Resource $SLB.BGPInfo.LocalASN -TreatWhiteSpaceAsNull) -or $SLB.BGPInfo.LocalASN -lt 0 -or $SLB.BGPInfo.LocalASN -gt 4294967295) {
        return @{Valid = $false; Message = $slbTxt.TestSLBPropertyFail -f $PropertyLocalASN, $SLB.BGPInfo.LocalASN; Name = $PropertyLocalASN; Value = "$($SLB.BGPInfo.LocalASN)"}
    }

    # Validate PeerRouterConfigurations array is present and contains at least one peer
    # At least one BGP peer router is required for proper SLB operation
    if ((IsNullOrEmpty -Resource @($SLB.BGPInfo.PeerRouterConfigurations) -TreatWhiteSpaceAsNull) -or @($SLB.BGPInfo.PeerRouterConfigurations).Count -eq 0) {
        return @{Valid = $false; Message = $slbTxt.TestSLBPropertyFail -f $PropertyPeerRouterConfigurations, $SLB.BGPInfo.PeerRouterConfigurations; Name = $PropertyPeerRouterConfigurations; Value = "<NULL>"}
    }

    # Validate each BGP peer router configuration
    # Track peer IP addresses to detect duplicates
    $peerAddresses = @()
    foreach ($peer in @($SLB.BGPInfo.PeerRouterConfigurations)) {
        # Validate PeerASN (peer router's Autonomous System Number)
        # Must be a valid 32-bit ASN (0 to 4294967295)
        $peerASN = $peer.PeerASN
        if ((IsNullOrEmpty -Resource $peerASN -TreatWhiteSpaceAsNull) -or $peerASN -lt 0 -or $peerASN -gt 4294967295) {
            $returnObj = @{Valid = $false; Message = $slbTxt.TestSLBPropertyFail -f $PropertyPeerASN, $peer.PeerASN; Name = $PropertyPeerASN; Value = "$($peer.PeerASN)"}
        }

        # Validate RouterIPAddress is present and is a valid IPv4 address
        $peerIP = $peer.RouterIPAddress -as [System.Net.IPAddress]
        if ((IsNullOrEmpty -Resource $peerIP -TreatWhiteSpaceAsNull) -or $peerIP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $returnObj = @{Valid = $false; Message = $slbTxt.TestSLBPropertyFail -f $PropertyRouterIPAddress, $peer.RouterIPAddress; Name = $PropertyRouterIPAddress; Value = $peer.RouterIPAddress}
        } else {
            # Check for duplicate peer IP addresses
            # Each BGP peer must have a unique IP address
            foreach ($existing in $peerAddresses) {
                if ($existing -eq $peer.RouterIPAddress) {
                    $returnObj = @{Valid = $false; Message = $slbTxt.TestSLBDuplicateIPFail -f $PropertyRouterIPAddress, $peer.RouterIPAddress; Name = $PropertyRouterIPAddress; Value = $peer.RouterIPAddress}
                    break
                }
            }
            # Add validated peer IP to tracking array
            $peerAddresses += $peerIP
        }
    }

    return $returnObj
}

<#
.SYNOPSIS
    Determines whether a given value is null or empty.

.DESCRIPTION
    IsNullOrEmpty returns $true when the provided input is:
      - $null
      - An empty string (optionally treating whitespace-only strings as empty)
      - An empty collection/array/hashtable/enumerable (no elements)
    Otherwise returns $false.

.PARAMETER Network
    The object to evaluate.

.PARAMETER TreatWhiteSpaceAsNull
    If specified, strings that contain only whitespace are considered empty.

.EXAMPLE
    IsNullOrEmpty -Resource $null             # $true
    IsNullOrEmpty -Resource ""                # $true
    IsNullOrEmpty -Resource "  " -TreatWhiteSpaceAsNull  # $true
    IsNullOrEmpty -Resource @()               # $true
    IsNullOrEmpty -Resource @("a","b")        # $false
#>
function IsNullOrEmpty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [Object] $Resource,

        [switch] $TreatWhiteSpaceAsNull
    )

    # Null check - return true if the resource is null
    if ($null -eq $Resource) {
        return $true
    }

    # String handling - check if string is empty or whitespace
    if ($Resource.GetType() -eq [string]) {
        if ($TreatWhiteSpaceAsNull.IsPresent) {
            # Treat whitespace-only strings as null/empty
            return ([string]::IsNullOrWhiteSpace($Resource))
        } else {
            # Only treat empty strings as null/empty
            return ($Resource.Length -eq 0)
        }
    }

    # Integer handling - integers are never considered empty
    if ($Resource.GetType() -eq [int]) {
        return $false
    }

    # JSON handling (PSCustomObject or hashtable)
    if ($Resource.PSObject.TypeNames -contains 'System.Collections.Hashtable') {
        # For hashtable, check if there are any key-value pairs
        if ($Resource.Count -eq 0) {
            return $true
        }
        return $false
    } elseif ($Resource.PSObject.TypeNames -match 'PSCustomObject') {
        # For PSCustomObject, check if it has any NoteProperty members (i.e., properties with values)
        $noteProps = $Resource | Get-Member -MemberType NoteProperty
        if ($noteProps.Count -eq 0) {
            return $true
        }
        # Check if all NoteProperty values are $null or empty
        foreach ($prop in $noteProps) {
            $val = $Resource."$($prop.Name)"
            if (-not (IsNullOrEmpty -Resource $val -TreatWhiteSpaceAsNull)) {
                return $false
            }
        }
        return $true
    } elseif ($null -ne $Resource -and ($Resource.PSObject.TypeNames -contains 'System.Object[]' -or
        $Resource.PSObject.TypeNames -contains 'System.Collections.ArrayList' -or
        $Resource.PSObject.TypeNames -contains 'System.Collections.Generic.List')) {
        # For array-like structures, check if they are empty or contain only $null elements
        try {
            if ($Resource.Count -eq 0) {
                # Array has no elements
                return $true
            } else {
                # Check if all elements in the array are $null; returns true if array contains only $null
                return ($Resource | Where-Object { $_ -ne $null }).Count -eq 0
            }
        } catch {
            # If any error occurs during array evaluation, treat as empty
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Converts an IPv4 address to its UInt32 representation.

.DESCRIPTION
    ConvertToUInt32 accepts a System.Net.IPAddress (IPv4) and returns the 32-bit unsigned integer
    representation suitable for numeric comparisons and range checks. Throws on null or non-IPv4 input.

.PARAMETER ip
    The IPv4 address to convert.

.EXAMPLE
    ConvertToUInt32 -ip ([System.Net.IPAddress]::Parse("10.0.0.1"))
#>
function ConvertToUInt32 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$ip
    )

    # Validate that the IP address parameter is not null
    if ($null -eq $ip) {
        throw [System.ArgumentNullException]::new('ip')
    }

    # Ensure the IP address is IPv4 (not IPv6 or other address family)
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw [System.ArgumentException]::new('Only IPv4 addresses are supported.')
    }

    # Get the byte representation of the IP address
    $bytes = $ip.GetAddressBytes()

    # Reverse byte order from network byte order (big-endian) to host byte order (little-endian)
    [Array]::Reverse($bytes)

    # Convert the byte array to a 32-bit unsigned integer
    return [BitConverter]::ToUInt32($bytes, 0)
}

<#
.SYNOPSIS
    Converts a 32-bit unsigned integer to an IPv4 System.Net.IPAddress.

.DESCRIPTION
    ConvertFromUInt32 accepts a UInt32 (numeric) representation of an IPv4 address
    and returns a corresponding [System.Net.IPAddress] instance. This is the inverse
    operation of ConvertToUInt32.

.PARAMETER int
    The 32-bit unsigned integer representing an IPv4 address (network byte order).

.EXAMPLE
    ConvertFromUInt32 -int 167772161  # returns 10.0.0.1
#>
function ConvertFromUInt32 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [UInt32]$int
    )

    # Convert the UInt32 integer to a byte array (4 bytes for IPv4)
    $bytes = [BitConverter]::GetBytes($int)

    # Reverse byte order from host byte order (little-endian) to network byte order (big-endian)
    [Array]::Reverse($bytes)

    # Create and return a new IPv4 address from the byte array
    return [System.Net.IPAddress]::new($bytes)
}


<#
.SYNOPSIS
    Parses an IPv4 CIDR prefix (for example "10.0.0.0/24") and returns the numeric subnet mask,
    the numeric network (starting) address and the numeric broadcast (ending) address.

.DESCRIPTION
    GetAddressRange accepts a single CIDR-formatted IPv4 prefix string and computes:
      - Mask  : The subnet mask as a UInt32 suitable for bitwise operations.
      - Start : The network (lowest) address as a UInt32.
      - End   : The broadcast (highest) address as a UInt32.

    The numeric values are returned in a hashtable to allow fast numeric comparisons and
    membership checks without repeated parsing or conversions to System.Net.IPAddress.

.PARAMETER addressPrefix
    A CIDR-formatted IPv4 prefix string (e.g. "10.0.0.0/24").

.OUTPUTS
    Hashtable with keys:
      - Mask  : [UInt32] subnet mask in network byte order suitable for bitwise comparisons.
      - Start : [UInt32] numeric network address.
      - End   : [UInt32] numeric broadcast address.

.EXAMPLE
    $range = GetAddressRange -addressPrefix '10.0.0.0/24'
    # $range.Mask  -> UInt32 mask
    # $range.Start -> numeric network address
    # $range.End   -> numeric broadcast address

.NOTES
    This function is intended for internal use by other validators that perform numeric IP
    range and overlap checks.
#>
function GetAddressRange {
    param (
        [string]$addressPrefix
    )

    # Initialize return object with default values for mask, start, and end addresses
    $returnObj = @{ Mask = 0; Start = 0; End = 0 }
    try {
        # Parse the CIDR prefix into IP address and prefix length components
        # Example: "10.0.0.0/24" -> IP = "10.0.0.0", Length = 24
        $prefixIP, $prefixLength = $addressPrefix -split '/'
        $prefixIP = [System.Net.IPAddress]::Parse($prefixIP)
        $prefixLength = [int]$prefixLength

        # Convert the IP address to its UInt32 representation for bitwise operations
        $prefixInt = ConvertToUInt32([System.Net.IPAddress]::Parse($prefixIP))

        # Calculate the subnet mask based on prefix length
        # Formula: (2^32 - 1) - (2^(32 - prefixLength) - 1)
        # Example: /24 -> 0xFFFFFF00 (255.255.255.0)
        $mask = ([math]::Pow(2, 32) - 1) - ([math]::Pow(2, 32 - $prefixLength) - 1)
        $mask = [uint32]$mask

        # Calculate the network (starting) address by applying the mask to the IP
        # This gives us the lowest address in the subnet
        $network = $prefixInt -band $mask

        # Calculate the broadcast (ending) address
        # Add the number of host addresses (2^(32 - prefixLength) - 1) to the network address
        # This gives us the highest address in the subnet
        $broadcast = $network + (([uint32]1 -shl (32 - $prefixLength)) - 1)

        # Return the calculated values
        $returnObj = @{ Mask = $mask; Start = $network; End = $broadcast }
    } catch {
        # Throw a descriptive error if parsing or calculation fails
        throw "Failed to parse address prefix '$addressPrefix'. Ensure it is in CIDR format (e.g., '10.0.0.0/24'). Error: $($_.Exception.Message)"
    }

    return $returnObj
}

function SetPropertyFormat {
    param (
        [string]$Name,
        [string]$Value
    )

    # Check if both Name and Value parameters are provided (not null)
    if ($null -ne $Name -and $null -ne $Value) {
        # Return a formatted string combining the property name and value
        return "Property name: $Name, value: $Value"
    }

    return "<NULL>"
}

function IsResolveDNSName {
    param (
        [int]$MuxCount,
        [string]$SDNPrefix,
        [string]$FqdnName
    )

    # Initialize result object with default success state and zero available IPs
    try {
        $packagePath = Get-ASArtifactPath -NugetName "Microsoft.AS.Network.Deploy.HostNetwork" -Verbose:$false 3>$null 4>$null
        Import-Module "$packagePath\content\Powershell\Modules\HostNetworkHelpers\HostNetworkHelpers.psd1" -Force -DisableNameChecking

        for($i = 1; $i -le $MuxCount; $i++){
            $reservedIP = (Get-HostNetworkReservedIpAddress -NetworkId Management -ReservationId ("SlbVmNic1IpAddress0{0}" -f $i)).Split("/")[0]
            $slbName = "$SDNPrefix`-slb0{0:d1}" -f $i
            $slbFQDN = "$slbName.$FqdnName"
            foreach($name in @($slbName, $slbFQDN)){
                # Resolve the DNS name to get the associated IP address
                $ipAddress = @(Resolve-DnsName $name -ErrorAction SilentlyContinue).Where({$_.IPAddress}) | Select-Object -First 1
                if ((IsNullOrEmpty -Resource $ipAddress -TreatWhiteSpaceAsNull) -or (IsNullOrEmpty -Resource $ipAddress.IPAddress -TreatWhiteSpaceAsNull)) {
                    return @{ Status = $StatusFailure; Message = $slbTxt.TestDNSResolutionFail -f $name, $reservedIP, "<NULL>" }
                }

                # Verify that the resolved IP address matches the expected reserved IP
                if ($ipAddress.IPAddress -ne $reservedIP) {
                    return @{ Status = $StatusFailure; Message = $slbTxt.TestDNSResolutionFail -f $name, $reservedIP, $ipAddress.IPAddress }
                }
            }
        }
    }
    catch {
        # Handle exceptions that occur during DNS resolution
        return @{ Status = $StatusFailure; Message = $slbTxt.TestDNSResolutionException -f $_.Exception.Message}
    }

    return @{ Status = $StatusSuccess; Message = $slbTxt.TestDNSResolutionPass }
}

# for($i = 1; $i -le $MuxCount; $i++){
#     # Reserved IP format x.x.x.x/x
#     $reservedIP = Get-HostNetworkReservedIpAddress -NetworkId Management -ReservationId ("SlbVmNic1IpAddress0{0}" -f $i)
#     $reservedIP = $reservedIP.Split("/")[0]
#     $slbName = $DomainName + ("slb0{0}" -f $i)
#     $slbFQDN = $slbName + "." + $FqdnName
#     $slbDnsNames = @($slbName, $slbFQDN)
#     foreach($name in $slbDnsNames){
#         $ipAddressByDNS = @(Resolve-DnsName $name | Select-Object IPAddress -ErrorAction SilentlyContinue)
#         if(IsNullOrEmpty -Resource $ipAddressByDNS -TreatWhiteSpaceAsNull){
#             return $false
#         } else {
#             if(-not ( $ipAddressByDNS[0]) -or -not ( $ipAddressByDNS[0].IPAddress) -or  ($ipAddressByDNS[0].IPAddress -ne $reservedIP)){
#                 return $false
#             }
#         }
#     }
# }

# Export module members
Export-ModuleMember -Variable TypeHNVPA
Export-ModuleMember -Variable TypePublicVIP
Export-ModuleMember -Variable TypePrivateVIP
Export-ModuleMember -Variable PropertyName
Export-ModuleMember -Variable PropertySubnets
Export-ModuleMember -Variable PropertyAddressPrefix
Export-ModuleMember -Variable PropertyVlanId
Export-ModuleMember -Variable PropertyDefaultGateways
Export-ModuleMember -Variable PropertyIPPools
Export-ModuleMember -Variable PropertyNumberOfMuxes
Export-ModuleMember -Variable PropertyBGPInfo
Export-ModuleMember -Variable PropertyLocalASN
Export-ModuleMember -Variable PropertyPeerRouterConfigurations
Export-ModuleMember -Variable PropertyPeerASN
Export-ModuleMember -Variable PropertyRouterIPAddress
Export-ModuleMember -Variable PropertyStartIPAddress
Export-ModuleMember -Variable PropertyEndIPAddress

# Export module functions
Export-ModuleMember -Function Test-SLB_ValidateHNVPANetwork
Export-ModuleMember -Function Test-SLB_ValidatePublicPrivateVIPNetworks
Export-ModuleMember -Function Test-SLB_ValidateSoftwareLoadBalancer
Export-ModuleMember -Function Test-SLB_ValidateBGPPeersReachable
Export-ModuleMember -Function Test-SLB_ValidateFCNCInstalled
Export-ModuleMember -Function Test-SLB_ValidateNumberOfSLBNodes
Export-ModuleMember -Function Test-SLB_ValidateNCHNVPAIPPools
Export-ModuleMember -Function Test-SLB_ValidateNCLoadBalancerMux
Export-ModuleMember -Function Test-SLB_ValidateNCLoadBalancerManager
Export-ModuleMember -Function Test-SLB_ValidateNCServers
Export-ModuleMember -Function Test-SLB_ValidateOverlappingIPPools
Export-ModuleMember -Function Test-SLB_ValidateInfraIPPools
Export-ModuleMember -Function Test-SLB_ValidateDNSName
Export-ModuleMember -Function ValidatePublicPrivateVIPNetworksCheck
Export-ModuleMember -Function ValidatePublicPrivateVIPNetworksResult
Export-ModuleMember -Function ValidateSubnetProperties
Export-ModuleMember -Function ValidateDefaultGateways
Export-ModuleMember -Function ValidateIPPools
Export-ModuleMember -Function ValidateAddressPrefixes
Export-ModuleMember -Function ValidateOverlappingIPPools
Export-ModuleMember -Function ValidateSLBProperties
Export-ModuleMember -Function IsNullOrEmpty
Export-ModuleMember -Function ConvertToUInt32
Export-ModuleMember -Function ConvertFromUInt32
Export-ModuleMember -Function GetAddressRange
Export-ModuleMember -Function SetPropertyFormat
Export-ModuleMember -Function IsResolveDNSName

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBdY2i1XCVG+CAz
# DqFMhXvuUEkDxh63bXMu6InK3/uW0aCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIF+XKXlD
# gOjE3a3rRlh57uJuXPGmFc7TJQU+O77l3N2lMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAJRG8cP5INhsqE/TzLV2OFcq/k9YX90X2F2CUYIQL
# PaT6pvYsSWlEUgo0w7I2AOgY6r821dPu2q3B4eAtP2+GIoK2QHCzRQuQ20uOiGI/
# J482ufBwKVBTSgcphudYgSkP5NvgmYZYc3ER/49xL6e2nYCAjKiPIONvybHFLnKT
# 65kToTaufATDwhQW6WQ88YSTaLu3RdIVy0x60QOICJFjaASqmX4PXFn5rrWALb6c
# X4piZJz40ZxGmiHmrfb1VJ3Lz9Nk0vYkKOgDTJnu1VVhxDwapdKrPH9ZiwBfX+Eo
# XS/0Hvq2hGsTmFpApWl8EFibyCbSXSgew8tdJ4b67IOBmaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBC1ESj/UmDQ/ubOb5qT2xAxo8F+5HkGoQfhExD
# n+iUGgIGaedcMrc3GBMyMDI2MDUwMzE0MzExMC40MDZaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiu7AFD/TTuaoQABAAAC
# KzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMTFaFw0yNzA1MTcxOTQwMTFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCX3mi6OD3syUqQm4QqgkrKPbcs
# K/Qx3fYctL8+VM1uOY3booi5GxwauTgQf6JFHITToxS7gjqKlK8OFLzL6UTl0jxE
# K5t6DuOcgJXdvutimoTlOS0C3kyITXBAXoj/gp6hRR9z6WRip1Ktkilb3dJXCjQq
# T9P2Cuujr+Vz8r+Z+jDl09ji/ic/4G34r3mVwjs//Gnx9Pu31V8rXFicNiAzxpub
# awpbd8pqfzlWT2vnG3kF9l6MiREbvJ3XHLUwHQsh0t/TrSFx/s/yCqpJWYJ6oClG
# 70tvsFH0aRP8wB4cP/CFa2ILvk26i3OcJBl+pqKjHTSBy9mvwTPEDlnzco0Nt8R6
# pSPTXZgBsscHhoKfC0WQmOzY2keXbAmRTcZMyXz5v/AJbmoI0y07Bazvt5NkXddG
# 9TErQWwtsFyIKrElDgWfHeCoTu1wu2ciD3dK72z3ca2gzoEDxT2j9BXIUKaiTzTd
# QPRsAMaO3dU0zaGwMMlwtSJyDh14YEgZoUu5vS8MugMqdrNjphyL65yKhjpAWbhY
# kIHO/0uZju95tP8zZNqXIRh4tdfWHJPATn9r+cxkyuh2x0VLdfx1lmK9X3NjH0Nt
# gAs5JB/wOlkyuudxmFTfWVyRrL37ispOZ8aPAFgvyR6cNTkGpkFo35JRjciNmZiU
# 4qT9Uty+V5gudFk1jwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFD4WjuQTUJbtbd3j
# mvZku0FZ2eU2MB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQDO/CKsciEM8kr1fqH4
# TlfT66ENoTjxXw810pyEq0PdrgLwfgT3x+1gz7CQHtUdevqMQ5qHyDLhm6pT911C
# YkGN+6g+MU7fMYTr6d3SxieJwBIoWkfR4g7SitGzMKU465KEYejfddoUgovC/xcR
# paALO5p3/A248ByhJiMttBQNDtsT/HaCFwRFCURby/f8c1kky8F8xkCXFz+/MtZ5
# d1lWFjwOI2geZHWq9XihDOgee5nS2koo5V6n8XG220UTevVf+pgmpIH71XKDVIYT
# GGZJs6yPlfJ2aXqw1ME4NR6okNsY3P1M31H6DMYRfJGNBNep595kXGh3YzA3cCiy
# g+jmJ58h/fTvjngIpuUFfODpDjFx0ic1YoLANxhCF3RhS9qYM7K40NEhKshYuaAk
# IG2XBKYig3r/0/b0sjvjBws55AYonMm3A8qcX/6k9Vfc0mv9dtonHuWGfA2b+qE2
# qpCnhzGbdDHq7iOSZEw01nNupAMf1c41k9IoTQ2z3iw6w4ZZoLOyg4TKMbp1krpT
# 4trip/y30Cv5khyqCDNqaXQpBkOYON8LgtoQ3amVOX7ix5jdrnx/vUxTUSigXvrW
# dL7Uk8kpmS0zto2Toy7aT5oBzCTvfj9iJ/BN/E1vhFBkhJCvZ7PVvsMSnTTmkx2F
# al2lVkztuAI44fD/uyLJdaMQSzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkEwMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQAJrD90ykHpo/0AGb7lmwvsCtqROaCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aGqzTAiGA8y
# MDI2MDUwMzExMDY1M1oYDzIwMjYwNTA0MTEwNjUzWjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoarNAgEAMAoCAQACAgriAgH/MAcCAQACAhKRMAoCBQDtovxNAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAIl4g/kZCHOercYjfWGc3FY550/1
# yoGs3vrCpYCiNuNfqVIkgW9OD5T8579pxf21Xr0U1AcPlDXTJp0yDpUZSQC5piZ4
# GVlnWRd8cwYcudJMTRvohaKkB8RkIW/HdTHdBIBfKPSl0ebsY5sHpGDMZvnL5VY3
# hd5ZuFeSh7gV7YY2C5pt2CCK+97ZWsL6Ta38OU9D6850s8gLcTRyxUB0LH97fUTp
# i4IbVl9jVfkBnzUj1jIcGKgxMLwkI0OjgCqCX5kaZglamPJpmE56ddNb6tyRftU8
# uyBiJiHIbT+I0Fulg0PSenWSkVIO7qbbEJRaLt5aGv+5+hCzhUkHddnXKDExggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7
# AFD/TTuaoQABAAACKzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDN7DTtucEYWAxPV3lM4y2U16iH
# NL1Y6MAxmayT5vpeWjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHIOI/Q/
# kFftYA+M2OY+1Bx3ajBD6/WDAtPT2vFkv25SMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIruwBQ/007mqEAAQAAAiswIgQg4bigwWvF
# x04J9mIfST2NDYTqeHpS2VK/0b1JF/5aWO0wDQYJKoZIhvcNAQELBQAEggIAAEhf
# /3Wr9Kjev7Yc8ieB+po9FhIsdOvuqxONomJFNp3RCH6yw/Dq93lu0Zjv+i2ECjbr
# q0dJmUo01Fnr9c2O21ta/1RkS5l3FBKBy9b/nh4UQDUbj8BDe6ejLfdRnKJnnpn4
# R6Bf3AV8DBN6UNfqW3/q/fUE9DVYEefNXDz44vfxLnH6KbGDb5pDn5aPE4/iOnbq
# Bhw5VZabwoZ/wynQliid/Ktg4PuxzowMSl+u8RH9veguZJAf3bKaB4T3onBFg9qC
# c3ImHWLX5adcsnJiHs0jAXNJ73lMhgIa9mT0edfNJ6j/pNCnTnt9e/LMjYEn50xu
# D/Ggoscsa+4KEX1EwccQwnwykfRP0N21fREi85zSpKSY7AdFr0saxiJ3sS4KOe4R
# r0lj/cifphKafbHmYTTAVRtimUtuxu9EU4CqmFrScpIGkncOmTaTLwXGtZCbkbCd
# KzDTwgCFO3GWL+83Q3e8u/3PrNVBddQNnzGUx/WqsmHraYOBbP3WgXuf6HmISHEs
# e9jhXmD6RyQWJNMhC1UxAGUnGmyhbowlgM196b3kPZMZOEUmQuHFibOi0KOTHJuA
# 9S2mR4N9WUOAa1t757jJnXFLjYTWfSBfrIIh2b04BIb+wncutk8Ph7fYahBer3UH
# EV5Ub4tOsY+GeSoyiBnDzvI7AbvYTP3LQLQnW7w=
# SIG # End signature block
