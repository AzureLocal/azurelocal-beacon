<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>



<#
Import-Module $PSScriptRoot\AzStackHci.NetworkSLB.Helpers.psm1 -DisableNameChecking -Global
.SYNOPSIS
    Validates the Software Load Balancer (SLB) network configuration for Azure Stack HCI environments.

.DESCRIPTION
    The Invoke-AzStackHciNetworkSLBValidation function runs a set of validation tests on the SLB network configuration using provided parameters. It supports multiple operation types (DeploySLB, ScaleOutSLB, ScaleInSLB, PostSLB, PreUpdate, PostUpdate, AddNode) and generates logs and reports for the validation process.

.PARAMETER Parameters
    The environment configuration parameters required for validation.

.PARAMETER OperationType
    Indicates the operation type. Valid values are 'DeploySLB', 'ScaleOutSLB', 'ScaleInSLB', 'PostSLB', 'PreUpdate', 'PostUpdate', 'AddNode'.

.PARAMETER PSSession
    PowerShell session(s) used to perform the validation.

.PARAMETER PassThru
    If specified, returns the PSObject result instead of writing output to the console.

.PARAMETER Include
    Specifies which tests to include in the validation.

.PARAMETER Exclude
    Specifies which tests to exclude from the validation.

.PARAMETER HardwareClass
    Specifies the hardware class for the environment. Valid values are 'Small', 'Medium', or 'Large'. Default is 'Medium'.

.PARAMETER ClusterPattern
    Specifies the cluster pattern for the environment. Valid values are 'Standard', 'Stretch', or 'RackAware'. Default is 'Standard'.

.PARAMETER OutputPath
    Directory path for log and report output.

.PARAMETER CleanReport
    If specified, removes all previous progress and creates a clean report.

.PARAMETER ShowFailedOnly
    If specified, only failed results are shown on the screen.

.EXAMPLE
    Invoke-AzStackHciNetworkSLBValidation -Parameters $params -OperationType DeploySLB -PSSession $session -OutputPath "C:\Logs"

.NOTES
    - This function is intended for use in Azure Stack HCI deployment and update validation scenarios.
    - The list of validators to run is explicitly maintained in the script for clarity and maintainability.
    - Requires supporting modules and helper functions to be available in the module path.
#>
function Invoke-AzStackHciNetworkSLBValidation
{
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters,

        [Parameter(Mandatory = $true, HelpMessage = "Indicating Operation Type")]
        [ValidateSet('DeploySLB', 'ScaleOutSLB', 'ScaleInSLB', 'PostSLB', 'DnsSLB','PreUpdate', 'PostUpdate', 'AddNode')]
        [String]$OperationType,

        [Parameter(Mandatory = $true,HelpMessage = "Specify the PsSession(s) used to validation from.")]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.NetworkSLB.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.NetworkSLB.Helpers) })]
        [string[]]
        $Include,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.NetworkSLB.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.NetworkSLB.Helpers) })]
        [string[]]
        $Exclude,

        [Parameter(Mandatory = $false, HelpMessage = "Hardware class: Small, Medium, or Large")]
        [ValidateSet('Small','Medium','Large')]
        [String] $HardwareClass = "Medium",

        [Parameter(Mandatory = $false, HelpMessage = "Cluster Pattern: Standard, Stretch, or RackAware")]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String]
        $ClusterPattern = "Standard",

        [Parameter(Mandatory = $true, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false,

        [Parameter(Mandatory = $false, HelpMessage = "Show only failed results on screen.")]
        [switch]$ShowFailedOnly
    )

    try {
        # Set error action preference to stop on errors for strict validation
        $script:ErrorActionPreference = 'Stop'

        # Initialize the output path for logs and reports
        Set-AzStackHciOutputPath -Path $OutputPath

        # Initialize the parameter hashtable that will be passed to validation tests
        $callingTestParam = @{}

        # Extract the region name from the parameters (e.g., 'AzureLocal' for Azure.local)
        $regionName = Get-RegionNameFromParameters -Parameters $Parameters

        # If a region name is specified, add it to the calling test parameters
        if ($regionName -ne '') {
            $params = @{
                RegionName = $regionName
            }
            $callingTestParam += $params
        }

        switch ($OperationType)
        {
            # DeploySLB: Initial deployment of Software Load Balancer
            # Extracts SLB configuration from runtime parameters and prepares validation parameters
            # DnsSLB: Also used for DNS SLB validation
            { $_ -in @("DeploySLB", "DnsSLB") }
            {
                $runtimeParameters = $null
                if ($null -ne $Parameters.RunInformation -and $Parameters.RunInformation.ContainsKey('RuntimeParameter'))
                {
                    # Runtime parameter is available to all the interfaces to the action plan; it is a property bag of the customer provided data.
                    # During remediation the failed summary xml is also added to the runtime parameters.
                    # Failed summary xml will provide us the information on failed step's role, interface and execution-context details.
                    Log-Info -Message "Runtime Parameter is found."
                    $runtimeParameters = $Parameters.RunInformation['RuntimeParameter']
                }
                else
                {
                    # Fail because no runtime parameters found
                    throw "No runtime parameters with SLB Configuration Path Found"
                }

                # Extract SLB configuration JSON from runtime parameters
                $slbConfiguration = $runtimeParameters["InputJsonString"]
                Log-Info -Message "SLB user configuration: $slbConfiguration"

                # Parse the SLB configuration JSON and extract relevant sections
                $slbConfigurationObject = $slbConfiguration | ConvertFrom-Json
                $softwareLoadbalancerConfiguration = $slbConfigurationObject.SdnIntegration.SoftwareLoadBalancer
                $networksConfiguration = $slbConfigurationObject.SdnIntegration.Networks

                $eceClient = Create-ECEClusterServiceClient
                $eceXml = [XML]($eceClient.GetCloudParameters().getAwaiter().GetResult().CloudDefinitionAsXmlString)
                $sdnInt = $eceXml.Parameters.Category | Where-Object { $_.Name -eq "SDNIntegration" }
                $sdnPrefix = ($sdnInt.Parameter | Where-Object { $_.Name -eq "SDNPrefix" }).Value
                Log-Info -Message "SDN Prefix: $sdnPrefix"

                # Build parameter hashtable for deployment validation tests
                Log-Info -Message "Performing SLB Validation using Deploy parameters"
                $callingTestParam = @{
                    SoftwareLoadbalancerConfiguration = $softwareLoadbalancerConfiguration
                    NetworksConfiguration = $networksConfiguration
                    PSSession = $PSSession
                    ClusterPattern = $ClusterPattern
                    HardwareClass = $HardwareClass
                    IsDeployment = $true
                    SDNPrefix = $sdnPrefix.Trim().ToLower()
                }
            }
            # PreUpdate/PostUpdate/PostSLB: Validation during update operations or after SLB deployment
            # Checks server, SLB Mux, and load balancer manager configuration and provisioning state
            { $_ -in @("PreUpdate", "PostUpdate", "PostSLB") }
            {
                Log-Info -Message "$($_) scenario, will check all server, SLB Mux and load balancer manager configuration and provisioning state"

                # Build parameter hashtable for update/post-deployment validation tests
                $callingTestParam = @{
                    Parameters = $Parameters
                    PSSession = $PSSession
                    ClusterPattern = $ClusterPattern
                    HardwareClass = $HardwareClass
                }
            }
            # AddNode: Validation when adding new nodes to the cluster
            # Extracts node information and validates HNVPA IP pool allocation
            "AddNode"
            {
                $runtimeParameters = $null
                if ($null -ne $Parameters.RunInformation -and $Parameters.RunInformation.ContainsKey('RuntimeParameter'))
                {
                    Log-Info -Message "Runtime Parameter is found."
                    $runtimeParameters = $Parameters.RunInformation['RuntimeParameter']
                }
                else
                {
                    # Fail because no runtime parameters found
                    throw "No runtime parameters found"
                }

                # Parse the list of new node names being added to the cluster
                [System.String[]] $nodeNames = $runtimeParameters["NodeName"].Split()
                Log-Info -Message "AddNode scenario, new hosts to be added: $($nodeNames -join ',')"

                # Count the number of new hosts for validation purposes
                $numberOfNewHosts = @($nodeNames).Count
                Log-Info -Message "AddNode scenario, number of new hosts to be added: $numberOfNewHosts"

                # Build parameter hashtable for add node validation tests
                $callingTestParam = @{
                    NumberOfNewHosts = $numberOfNewHosts
                    Parameters = $Parameters
                    PSSession = $PSSession
                    ClusterPattern = $ClusterPattern
                    HardwareClass = $HardwareClass
                }
            }
            # ScaleOutSLB: Validation when scaling SLB Mux instances out
            # Validates that the SLB infrastructure is correctly scaled to the target count
            "ScaleOutSLB"
            {
                # Determine the current number of SLB nodes from the parameters
                $numOfSLBs = @($Parameters.Roles['VirtualMachines'].PublicConfiguration.Nodes.Node | Where-Object {$_.Role -eq 'SLB' -and $_.ProvisioningStatus -ne 'Removed'}).Count
                Log-Info -Message "The number of SLB nodes: $numOfSLBs"

                # Build parameter hashtable for scale validation tests
                Log-Info -Message "In SLB scale out scenario, the validator will check all SLB mux and manager configuration and provisioning status and ensure they are correctly scaled."
                $callingTestParam = @{
                    SoftwareLoadbalancerConfiguration = $null
                    NumberOfMuxes = ++$numOfSLBs
                    Parameters = $Parameters
                    PSSession = $PSSession
                    ClusterPattern = $ClusterPattern
                    HardwareClass = $HardwareClass
                }
            }
            # ScaleInSLB: Validation when scaling SLB Mux instances in
            "ScaleInSLB"
            {
                # Determine the current number of SLB nodes from the parameters
                $numOfSLBs = @($Parameters.Roles['VirtualMachines'].PublicConfiguration.Nodes.Node | Where-Object {$_.Role -eq 'SLB' -and $_.ProvisioningStatus -ne 'Removed'}).Count
                Log-Info -Message "The number of SLB nodes: $numOfSLBs"

                # Build parameter hashtable for scale validation tests
                Log-Info -Message "In SLB scale in scenario, the validator will check all SLB mux and manager configuration and provisioning status and ensure they are correctly scaled."
                $callingTestParam = @{
                    SoftwareLoadbalancerConfiguration = $null
                    NumberOfMuxes = --$numOfSLBs
                    Parameters = $Parameters
                    PSSession = $PSSession
                    ClusterPattern = $ClusterPattern
                    HardwareClass = $HardwareClass
                }
            }
            # Default case: Unknown operation type
            default
            {
                throw "Unknown OperationType [$OperationType]"
            }
        }

        # Write header information for the validation run
        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru

        # Initialize or retrieve the environment checker report
        # If CleanReport is specified, previous progress is removed and a fresh report is created
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        # Import the SLB network validation helper module containing test functions
        Import-Module $PSScriptRoot\AzStackHci.NetworkSLB.Helpers.psm1 -DisableNameChecking -Global

        #region Get test list
        # Display progress indicator for the validation process
        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependencies" -Status "SLB Network Configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        # Define the list of SLB network validation tests to run based on the operation type
        # Each operation type has a specific set of tests tailored to its validation requirements
        $script:envchktestList = @()
        switch ($OperationType)
        {
            # DeploySLB: Validates all SLB network configuration during initial deployment
            # Tests include FC/NC installation, node count, network configurations, IP pools, and BGP peers
            "DeploySLB"
            {
                Log-Info -Message "DeploySLB scenario, will check all SLB networks configuration."
                $script:envchktestList = @(
                                "Test-SLB_ValidateFCNCInstalled",              # Verify Failover Clustering and Network Controller are installed
                                "Test-SLB_ValidateNumberOfSLBNodes",           # Validate the number of SLB nodes matches requirements
                                "Test-SLB_ValidateSoftwareLoadBalancer",       # Verify SLB configuration is valid
                                "Test-SLB_ValidateHNVPANetwork",               # Validate HNV Provider Address (HNVPA) network configuration
                                "Test-SLB_ValidatePublicPrivateVIPNetworks",   # Validate public and private VIP network configurations
                                "Test-SLB_ValidateOverlappingIPPools",         # Check for overlapping IP address pools
                                "Test-SLB_ValidateBGPPeersReachable",          # Verify BGP peers are reachable
                                "Test-SLB_ValidateInfraIPPools")               # Validate infrastructure IP pool configuration
            }
            # DnsSLB: Validates DNS name resolution for SLB VMs during deployment
            # Tests include DNS configuration validation
            "DnsSLB"
            {
                Log-Info -Message "DeploySLB scenario, will check all SLB networks configuration."
                $script:envchktestList = @("Test-SLB_ValidateDNSName")          # Validate DNS configuration
            }
            # PreUpdate/PostUpdate/PostSLB: Validates SLB components and their provisioning status
            # Tests focus on Network Controller resources: Load Balancer Manager, Mux, and Servers
            { $_ -in @("PreUpdate", "PostUpdate", "PostSLB") }
            {
                Log-Info -Message "PreUpdate, PostUpdate and PostSLB scenario, will check all NC SLB mux, LB manager and servers configuration and provisioning status"
                $script:envchktestList = @(
                                "Test-SLB_ValidateNCLoadBalancerManager",      # Validate Network Controller Load Balancer Manager configuration
                                "Test-SLB_ValidateNCLoadBalancerMux",          # Validate Network Controller SLB Mux configuration
                                "Test-SLB_ValidateNCServers")                  # Validate Network Controller server configuration
            }
            # AddNode: Validates SLB configuration when adding new nodes to the cluster
            # Includes standard NC validation plus HNVPA IP pool validation for new hosts
            "AddNode"
            {
                Log-Info -Message "AddNode scenario, will check all NC SLB mux, LB manager and servers configuration and provisioning status. In addition, it will validate HNVPA IP pools."
                $script:envchktestList = @(
                                "Test-SLB_ValidateNCLoadBalancerMux",          # Validate Network Controller SLB Mux configuration
                                "Test-SLB_ValidateNCLoadBalancerManager",      # Validate Network Controller Load Balancer Manager configuration
                                "Test-SLB_ValidateNCServers",                  # Validate Network Controller server configuration
                                "Test-SLB_ValidateNCHNVPAIPPools")             # Validate HNVPA IP pools have sufficient capacity for new nodes
            }
            # Scale In/Out SLB: Validates SLB configuration when scaling SLB Mux instances
            # Includes node count validation, NC component validation, and infrastructure IP pool validation
            { $_ -in @("ScaleOutSLB", "ScaleInSLB") }
            {
                Log-Info -Message "Scale In/Out SLB scenario, will check all NC SLB mux, LB manager and servers configuration and provisioning status. In addition, it will validate Infrastructure IP pools and MUX count."
                $script:envchktestList = @(
                                "Test-SLB_ValidateNumberOfSLBNodes",           # Validate the number of SLB nodes matches the target scale
                                "Test-SLB_ValidateNCLoadBalancerMux",          # Validate Network Controller SLB Mux configuration
                                "Test-SLB_ValidateNCLoadBalancerManager",      # Validate Network Controller Load Balancer Manager configuration
                                "Test-SLB_ValidateNCServers",                  # Validate Network Controller server configuration
                                "Test-SLB_ValidateInfraIPPools")               # Validate infrastructure IP pools for scaled environment
            }
        }
        #endregion

        # Apply Include/Exclude parameters and all exclusion mechanisms (manifest, file-based)
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $script:envchktestList

        # Calculate the total number of tests to run for progress tracking
        $TotalTestCount = ($script:envchktestList).Count

        # Run validation
        $i = 0
        $Result = @()
        $ProgressActivity = "Checking AzStackHci SLB network compatibility"
        $i = 0
        $ProgressStatus = "Testing $ENV:ComputerName"

        # Configure progress bar parameters
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }
        Write-Progress @progressParams

        # Execute each validation test in sequence
        :noTestsBreak foreach ($test in $script:envchktestList)
        {
            # Log and display the current test being executed
            $OpMsg = "Run SLB network validator [{0}] on {1}" -f $test, $ENV:ComputerName
            Log-Info -Message $OpMsg
            Write-Progress @progressParams -CurrentOperation $OpMsg -PercentComplete (($i++ / $TotalTestCount) * 100)

            # Build the parameter hashtable for the current test by matching available parameters
            # Only pass parameters that the test function accepts
            $invokeParameters = @{}
            Get-Command $test | Select-Object -ExpandProperty Parameters | Select-Object -ExpandProperty Keys | ForEach-Object {
                if ($callingTestParam[$PSITEM]) {
                    $invokeParameters += @{
                        $PSITEM = $callingTestParam[$PSITEM]
                    }
                }
            }

            # Log the parameters being passed to the validator for debugging purposes
            Log-Info "Validator parameters:"
            Log-Info -Message ($invokeParameters | Out-String)

            # Execute the test function with the prepared parameters and collect results
            $Result += Invoke-Expression "$test @invokeParameters"

            # Log completion of the current test
            $OpMsg = "End of SLB network validator [{0}] run on {1}`n" -f $test, $ENV:ComputerName
            Log-Info -Message $OpMsg
        }

        # Feedback results - user scenario
        Log-Info "SLB validation finished!" -ConsoleOut:(-not $PassThru)

        # If PassThru is not specified, format and display results to the console
        if (-not $PassThru)
        {
            # Show progress while formatting results
            $progressParams = @{
                Id              = 3
                Activity        = "Formating Results"
                Status          = "Writing Results for $($ENV:ComputerName)"
                PercentComplete = 1
                ErrorAction     = 'SilentlyContinue'
            }
            Write-Progress @progressParams

            # Write formatted results to console, optionally showing only failed tests
            Write-AzStackHciResult -Title "$($ENV:COMPUTERNAME):" -Result $Result -ShowFailedOnly:$ShowFailedOnly -Seperator ': '
            Write-Summary -Result $Result -Property1 Detail
        }
        else
        {
            # If PassThru is specified, log and return the raw result object
            Log-Info "SLB validation result: $($Result | Out-String)"
            return $result
        }
    }
    catch
    {
        Log-Info -Message "" -ConsoleOut
        Log-Info -Message "$($_.Exception.Message)" -ConsoleOut -Type Error
        Log-Info -Message "$($_.ScriptStackTrace)" -ConsoleOut -Type Error
        $cmdletException = $_
        throw $_
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        # Write result to telemetry channel
        foreach ($r in $result)
        {
            Write-ETWResult -Result $r
        }

        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'NetworkSLB' -Value $Result -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

<#
.SYNOPSIS
    Contains helper functions for AzStackHci Network SLB validation.

.DESCRIPTION
    Provides utility functions used by AzStackHci Network SLB validation, including region name extraction from environment parameters.

.FUNCTIONALITY
    - Get-RegionNameFromParameters: Extracts the region name based on RegistrationCloudName in the provided parameters.
    - Additional helper functions can be added here to support SLB validation scenarios.
.NOTES
    This file is intended to be imported by AzStackHci.NetworkSLB.psm1 and related modules.
#>
function Get-RegionNameFromParameters
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters
    )

    # Specify the region name to target for connectivity validation
    $RegionName = ''

    # Retrieve the RegistrationCloudName from the parameters to determine the cloud environment.
    $RegistrationCloudName = $Parameters.Roles["Cloud"].PublicConfiguration.PublicInfo.RegistrationCloudName

    # If the RegistrationCloudName is 'Azure.local' (case-insensitive), set the RegionName parameter to 'AzureLocal'.
    if ($RegistrationCloudName -ieq 'Azure.local')
    {
        $RegionName = 'AzureLocal'
    }

    return $RegionName
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDivaE6L1lDxKYF
# bdeCB6IehOS9bDMllC83I6kUeWVD5aCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGH3d35/
# L13N02+EgxdWOAttUk1HnKBwFA//bVKOozgBMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAL4dzqoSgNafsPLucaB1h6b2jdBkEcROgnDbWCM56
# 3GICnuuzTAV8s+VR2yXH8aPkd7eauVT+lmKsoTg1MY+xR+iOEYIjA8ceWRfrThhz
# j8fkQei3s3Kxj4axLmTdlwinyNCmasb4IFoAeQryusG+7MCW1jlaOM10IdPVJPy1
# yGSFscI6xpOZ3o1OynuwxTtg4Qaeeo8q63Ie+l0PUxMWy1k3MD+YKZWYLN/xD80C
# tVglAxVqig3DEb+ahp4UZDg53OdKYpOaSS7Z0XLjkqCJjhQ1yAbAnmYf3qplUzZr
# t0Cp1mKdIsKMpCJn2yPTFqm0w8LKF+7KxNmmeJpC/r6NZ6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCCkOF3tV5fpSUffzGv9wHa/BXG60GPAdioxOP1l
# y9FP1QIGaefB+1SZGBMyMDI2MDUwMzE0MzExMS40NzhaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCgWnSyoJx4ilxUoHJekO2NqHbb
# Cl/iyHMdmwTsL+IzlDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILAkCt9W
# kCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wIgQgXDVXUUgM
# F2UJ5kLBUeKOgKL/uQDhW3pavs3L2zobM+AwDQYJKoZIhvcNAQELBQAEggIAg9hz
# 9o5KZdxualZ+6IGjWqHcV69xYmIGDAcHPfV8495DH7I/zkm3/bjy6xFMlv2aa4/8
# FOlmoh1BUWDxXLkzkYeTS9dLujb+ERxfBxdbc83nqm0DMUFAjEWa0mHgVVyaVcYz
# GPMAlW8WLnDHWPcbQ2uxZfpQXZQT754DGkkeuIY8OAcAYBF3Y/rD+DGheP8VVBsV
# lSzgHtrOUKSKO8joLnFIuyaHjIxWhSFxn17WreIXJRq71eEhJFdymDWvHaINB+RH
# 5EESm2nH1avfmqbzJsaDyVq73BlktMQIXiIpkAdXqb+9LqRwib/6ZJosmbTObIJe
# HirUdHYth2s2HHBG9Qa+yHhv4DNSSYHsCzcH10t2ez0M97ybur/O+3SYVvODYIVq
# mA+JiIJS3WeskhdhbO92E7plP/BqQqereBygWU80KjNInErPdTkwBI4E8m0lExGb
# M+erWtDHeBQ5Vlhd86xCW2ZCRKpPwRyvK2Xv7ylBgtQiarznpmWxgGPGte2Y367f
# hN9AKVbvZeE6AiAiXnYel/1gjsrDU0gF8HSeRm/noN9Uv67OPrDt3ZuyxcnuYffi
# pvesKNpH4UaK1gd7Rayb+/kqLBsCJM6ChfmrcO5vJY+T7FcCv/jktiZoT9+iYYm3
# XdUyGMp4YiXey24YxgcsyC5t5/shjL0iEXXc/Yg=
# SIG # End signature block
