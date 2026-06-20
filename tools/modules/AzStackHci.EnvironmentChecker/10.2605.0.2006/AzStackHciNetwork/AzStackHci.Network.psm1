<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.Network.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.Network.Helpers.psm1 -DisableNameChecking -Global
function Invoke-AzStackHciNetworkValidation
{
    <#
    .SYNOPSIS
        Perform AzStackHci Network Validation
    .DESCRIPTION
        Perform AzStackHci Network Validation by attempting below tests:
        - Validate management IP range (for deployment)
        - Validate IP range against K8s reserved networks
        - Validate host network configuration readiness
        - Validate adapter readiness
        - Validate DHCP status for host (for DHCP deployment)
        - Validate new node readiness and network intent status (during add server)
        - Validate host network intents requirement and storage connectivity type (for deployment)
    .EXAMPLE
        # Using a deployment answer file to validate network configurations

        $allServers = @("Server 1 IP", "Server 2 IP") # you need to use IP for the connection
        $userName = "<LOCAL_ADMIN>"
        $secPassWord = ConvertTo-SecureString "<LOCAL_ADMIN_PASSWORD>" -AsPlainText -Force
        $hostCred = New-Object System.Management.Automation.PSCredential($username, $secPassWord)
        [System.Management.Automation.Runspaces.PSSession[]] $allServerSessions = @();
        foreach ($currentServer in $allServers) {
            $currentSession = Microsoft.PowerShell.Core\New-PSSession -ComputerName $currentServer -Credential $hostCred -ErrorAction Stop
            $allServerSessions += $currentSession
        }
        $answerFilePath = "<ANSWER_FILE_LOCATION>" # Like C:\MASLogs\Unattended-2024-07-18-20-44-48.json
        Invoke-AzStackHciNetworkValidation -DeployAnswerFile $answerFilePath -PSSession $allServerSessions -ProxyEnabled $false
    .EXAMPLE
        # Using individual parameter to validate network configurations

        $answerFilePath = "<ANSWER_FILE_LOCATION>"
        $managementSubnetCIDR = "<CIDR string for management subnet>"
        $logOutputPath = "<LOG_FILE_LOCATION>"
        $userName = "<LOCAL_ADMIN>"
        $secPassWord = ConvertTo-SecureString "<LOCAL_ADMIN_PASSWORD>" -AsPlainText -Force
        $hostCred = New-Object System.Management.Automation.PSCredential($username, $secPassWord)
        $answerFileContent = Get-Content $answerFilePath -Raw | ConvertFrom-Json
        $ipPools = New-Object System.Collections.ArrayList
        [System.Management.Automation.Runspaces.PSSession[]] $allServerSessions = @();
        foreach ($ipPool in $answerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].ipPools) {
            $currentPoolObject = [PSCustomObject] @{
                StartingAddress =  $ipPool.StartingAddress
                EndingAddress= $ipPool.EndingAddress
            }
            $ipPools.Add($currentPoolObject)
        }
        [PSObject] $atcHostNetworkInfo = $answerFileContent.scaleUnits[0].deploymentData.hostNetwork
        [System.String[]]$allServers = $answerFileContent.scaleUnits[0].deploymentData.physicalNodes.Name
        [System.Management.Automation.Runspaces.PSSession[]] $allServerSessions = @();
        foreach ($currentServer in $allServers) {
            $currentSession = Microsoft.PowerShell.Core\New-PSSession -ComputerName $currentServer -Credential $hostCred -ErrorAction Stop
            $allServerSessions += $currentSession
        }
        Invoke-AzStackHciNetworkValidation -IpPools $ipPools -ManagementSubnetValue $managementSubnetCIDR -PSSession $allServerSessions -OutputPath $logOutputPath -HostNetworkInfo $atcHostNetworkInfo
    .PARAMETER PassThru
        Return PSObject result.
    .PARAMETER HardwareClass
        Hardware class: Small, Medium, or Large.
    .PARAMETER ClusterPattern
        Hardware class: Standard, Stretch, or RackAware.
    .PARAMETER OutputPath
        Directory path for log and report output.
    .PARAMETER CleanReport
        Remove all previous progress and create a clean report.
    .INPUTS
        Inputs (if any)
    .OUTPUTS
        Output (if any)
    .LINK
        https://docs.microsoft.com/en-us/azure-stack/hci/manage/use-environment-checker?tabs=network
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile', HelpMessage = "Specify the answer file used for deployment validation.")]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [System.String]
        $DeployAnswerFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "Specify end infra IP Range pools")]
        [System.Collections.ArrayList]
        $IpPools,

        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "Specify string of management subnet value in CIDR format")]
        [string] $ManagementSubnetValue,

        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile', HelpMessage = "Specify the PSSession(s) used to validation from")]
        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "Specify the PSSession(s) used to validation from")]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "Specify Host and Mgmt IP Mapping for Nodes")]
        [Hashtable]
        $NodeToManagementIPMap = $null,

        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "Run tests specific to DHCP case")]
        [switch]
        $dhcpEnabled,

        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "How many nodes in the cluster")]
        [System.Int16] $NodesInCluster,

        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "Specify PSObject of HostNetwork info")]
        [PSObject] $HostNetworkInfo = $null,

        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "Specify PSObject array of ATC Host Intents.")]
        [PSObject[]] $AtcHostIntents,

        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "Specify the installation method of the system")]
        [ValidateSet('Deployment','Upgrade')]
        [string] $InstallationMethod = "Deployment",

        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile', HelpMessage = "System proxy information")]
        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "System proxy information")]
        [System.Boolean] $ProxyEnabled = $false,

        [Parameter(Mandatory = $false, ParameterSetName = 'AnswerFile', HelpMessage = "Domain admin credential for current deployment. Must be provided if ConnectionLocalAdminCredential is not provided.")]
        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "Domain admin credential for current deployment. Must be provided if ConnectionLocalAdminCredential is not provided.")]
        [PSCredential] $ConnectionDomainAdminCredential = $null,

        [Parameter(Mandatory = $false, ParameterSetName = 'AnswerFile', HelpMessage = "Local admin credential for current deployment. Must be provided if ConnectionDomainAdminCredential is not provided.")]
        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "Local admin credential for current deployment. Must be provided if ConnectionDomainAdminCredential is not provided.")]
        [PSCredential] $ConnectionLocalAdminCredential = $null,

        [Parameter(Mandatory = $false, ParameterSetName = 'AnswerFile', HelpMessage = "If current deployment is using local identity")]
        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "If current deployment is using local identity")]
        [System.String] $DeployADLess = "false",

        [Parameter(Mandatory = $false, HelpMessage = "Specify the region name to target for connectivity validation.")]
        [string]
        $RegionName,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.Network.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.Network.Helpers) })]
        [System.String[]] $Include,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.Network.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.Network.Helpers) })]
        [System.String[]] $Exclude = @(),

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Hardware class: Small, Medium, or Large")]
        [ValidateSet('Small','Medium','Large')]
        [String] $HardwareClass = "Medium",

        [Parameter(Mandatory = $false, HelpMessage = "Cluster Pattern: Standard, Stretch, or RackAware")]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String]
        $ClusterPattern = "Standard",

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false,

        [Parameter(Mandatory = $false, HelpMessage = "Show only failed results on screen.")]
        [switch]$ShowFailedOnly,

        [Parameter(Mandatory = $false, HelpMessage = "Indicating Operation Type")]
        [ValidateSet('AddNode','Deployment','Upgrade', 'PreUpdate')]
        [String]$OperationType = "Deployment",

        [Parameter(Mandatory = $false, HelpMessage = "Storage type: S2D or SAN")]
        [String]$StorageType = "S2D"
    )

    $callingTestParam = @{}

    Import-Module $PSScriptRoot\AzStackHci.Network.Helpers.psm1 -DisableNameChecking -Global

    # Prepare validator call parameters
    switch ($PSCmdlet.ParameterSetName)
    {
        "AnswerFile"
        {
            # If the function is called with the AnswerFile parameter set, we need to set the other parameters
            Log-Info -Message "Performing Network Validation using AnswerFile"
            $deployAnswerFileContent = Get-Content $DeployAnswerFile -Raw | ConvertFrom-Json

            Log-Info -Message "Get IpPools info from answer file `"infrastructureNetwork | ipPools`" section"
            $allIpPools = New-Object System.Collections.ArrayList
            foreach ($ipPool in $deployAnswerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].ipPools)
            {
                $currentPoolObject = [PSCustomObject] @{
                    StartingAddress =  $ipPool.StartingAddress
                    EndingAddress= $ipPool.EndingAddress
                }

                $allIpPools.Add($currentPoolObject)
            }

            # calculate the infra network CIDR string
            Log-Info -Message "Calculate ManagementSubnetValue (infra network CIDR string) from answer file `"infrastructureNetwork | subnetMask`" and StartingAddress of 1st element of `"infrastructureNetwork | ipPools`""
            $infraSubnetMask = $deployAnswerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask
            $infraSubnetMaskBytes = $infraSubnetMask -split '\.' | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }
            $infraBinarySubnetMask = $infraSubnetMaskBytes -join ''
            $prefixLength = ($infraBinarySubnetMask -split '1').Count - 1
            $testIP = $deployAnswerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].ipPools[0].StartingAddress
            # Note that all IP pools must be in same subnet so we can use the first IP pool to calculate the subnet CIDR
            $managementSubnetCIDR = (EnvValidatorNwkLibNormalizeIPv4Subnet -cidrSubnet "$testIP/$prefixLength").ToString()
            Log-Info -Message "Got management subnet CIDR: $managementSubnetCIDR"

            [PSObject] $hostNetworkInfoFromAnswerFile = $deployAnswerFileContent.scaleUnits[0].deploymentData.hostNetwork
            [PSObject[]] $atcHostIntentsInfo = $hostNetworkInfoFromAnswerFile.intents

            # Calculate switchless flag from answer file
            # using "-eq $true" here just in case some deployment does not have this "StorageConnectivitySwitchless" in the JSON
            $switchlessFlag = $hostNetworkInfoFromAnswerFile.storageConnectivitySwitchless -eq $true

            $callingTestParam = @{
                IpPools = $allIpPools
                ManagementSubnetValue = $managementSubnetCIDR
                PSSession = $PSSession
                dhcpEnabled = $deployAnswerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].useDhcp
                AtcHostIntents = $atcHostIntentsInfo
                HostNetworkInfo = $hostNetworkInfoFromAnswerFile
                ProxyEnabled = $ProxyEnabled
                HardwareClass = $HardwareClass
                ClusterPattern = $ClusterPattern
                SwitchlessDeploy = $switchlessFlag
                NodeCount = $deployAnswerFileContent.scaleUnits[0].deploymentData.physicalNodes.Count
                OperationType = $OperationType
                ConnectionDomainAdminCredential = $ConnectionDomainAdminCredential
                ConnectionLocalAdminCredential = $ConnectionLocalAdminCredential
                DeployADLess = $DeployADLess
                StorageType = if ($deployAnswerFileContent.scaleUnits[0].deploymentData.storage.storageType) { $deployAnswerFileContent.scaleUnits[0].deploymentData.storage.storageType } else { "S2D" }
            }
        }
        "EceParameter"
        {
            Log-Info -Message "Performing Network Validation using Deploy parameters"

            # If current deployment is switchless, using "-eq $true" here just in case some deployment does not have this "StorageConnectivitySwitchless" in the JSON
            $switchlessFlag = $HostNetworkInfo.StorageConnectivitySwitchless -eq $true

            [PSObject[]] $atcHostIntentsInfo = $null

            if ($HostNetworkInfo -and ($OperationType -eq "Deployment")) {
                Log-Info -Message "Getting ATC Host Intents from HostNetworkInfo for Deployment scenario."
                $atcHostIntentsInfo = $HostNetworkInfo.intents
            } else {
                Log-Info -Message "HostNetworkInfo parameter is null. AddNode, Upgrade or PreUpdate scenario. Getting ATC Host Intents from passed in parameter."
                $atcHostIntentsInfo = $AtcHostIntents
            }

            if ($null -eq $atcHostIntentsInfo)
            {
                throw "No ATC Host Intents found. Please provide ATC Host Intents info. For deployment: provide in unattended JSON; for upgrade: make sure system has intent configured."
            }

            $callingTestParam = @{
                IpPools = $IpPools
                ManagementSubnetValue = $ManagementSubnetValue
                PSSession = $PSSession
                dhcpEnabled = $dhcpEnabled
                AtcHostIntents = $atcHostIntentsInfo
                HostNetworkInfo = $HostNetworkInfo
                ProxyEnabled = $ProxyEnabled
                HardwareClass = $HardwareClass
                ClusterPattern = $ClusterPattern
                SwitchlessDeploy = $switchlessFlag
                NodeToManagementIPMap = $NodeToManagementIPMap
                NodeCount = $NodesInCluster
                OperationType = $OperationType
                ConnectionDomainAdminCredential = $ConnectionDomainAdminCredential
                ConnectionLocalAdminCredential = $ConnectionLocalAdminCredential
                DeployADLess = $DeployADLess
                StorageType = $StorageType
            }
        }
    }

    try
    {
        $script:ErrorActionPreference = 'Stop'
        Set-AzStackHciOutputPath -Path $OutputPath

        if ($RegionName -eq 'AzureLocal') {
            $params = @{
                RegionName = 'AzureLocal'
            }
            $callingTestParam += $params
        }

        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru

        # Call/Initialize reporting
        $envCheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envCheckerReport = Add-AzStackHciEnvJob -report $envCheckerReport

        #region Get test list
        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependencies" -Status "Network Configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        # We could use function "Get-TestListByFunction" to get the list of tests to run.
        # However, that function will return all tests in the module that matching to a specific function name.
        # The inexplicit selection of the validator might make the maintenance of the validator list
        # harder: if a new validator is added, the function will automatically include it to be run for
        # a specific scenario. It will be easy to forget that implication. It might be easier to maintain
        # the list of tests to run in the script explicitly. With the explicit list, the user can clearly
        # see what tests are run for a specific scenario and can easily add or remove tests from the list.
        Log-Info -Message "[NetworkValidator] [$($OperationType)] scenario"
        switch ($OperationType)
        {
            "Deployment"
            {
                Log-Info -Message "Will check all network configuration needed for a successful deployment"
                $script:envchktestList = @( "Test-NwkValidator_StorageAdapterReadiness",
                                            "Test-NwkValidator_InfraIpPoolReadiness",
                                            "Test-NwkValidator_AKS_CidrOverlaps",
                                            "Test-NwkValidator_HostNetworkConfigurationReadiness",
                                            "Test-NwkValidator_AdapterDriverMgmtAdapterReadiness",
                                            "Test-NwkValidator_MgmtIpIpPoolRequirement",
                                            "Test-NwkValidator_NetworkIntentRequirement",
                                            "Test-NwkValidator_StorageConnectivityType",
                                            "Test-NwkValidator_StorageVlanFor2NodeSwitchLessDeployment",
                                            "Test-NwkValidator_NetworkGatewayRequirement")

                if (-not $dhcpEnabled) {
                    # For static IP deployment, need to validate management IP should not change after initial deployment
                    $script:envchktestList += "Test-NwkValidator_MgmtIpConfigurationForStaticDeployment"
                }

                Log-Info -Message "Network validator to run: [ $($script:envchktestList -join ', ') ]"
            }
            "AddNode"
            {
                if ($null -eq $callingTestParam.NodeToManagementIPMap)
                {
                    throw "NodeToManagementIPMap parameter is required for AddNode scenario."
                }

                Log-Info -Message "Will check network configuration needed for adding new node(s) into existing cluster"
                $script:envchktestList = @( "Test-NwkValidator_StorageAdapterReadiness",
                                            "Test-NwkValidator_HostNetworkConfigurationReadiness",
                                            "Test-NwkValidator_AdapterDriverMgmtAdapterReadiness",
                                            "Test-NwkValidator_MgmtIpIpPoolRequirement",
                                            "Test-NwkValidator_ClusterNetworkIntentStatus",
                                            "Test-NwkValidator_StorageIntentExistence",
                                            "Test-NwkValidator_NetworkATCFeatureStatusOnNewNode",
                                            "Test-NwkValidator_NetworkGatewayRequirement")

                # Check if DHCP enabled or Brownfield upgrade. envType will be "Upgrade" for brownfield, "Deployment" for greenfield
                $envType = $null

                if ($null -ne $InstallationMethod)
                {
                    $envType = $InstallationMethod
                }

                if ($dhcpEnabled -or ($envType -eq "Upgrade"))
                {
                    Log-Info -Message "No need to run TestMgmtIPForNewNode for Add Node scenario when DHCP enabled or Brownfield upgrade"
                }
                else
                {
                    Log-Info -Message "Need to run TestMgmtIPForNewNode for Add Node scenario if not DHCP enabled and not Brownfield upgrade"
                    $script:envchktestList += "Test-NwkValidator_MgmtIPForNewNode"
                }
            }
            "Upgrade"
            {
                Log-Info -Message "[NetworkValidator][Upgrade] scenario. Only need to run Test-NwkValidator_InfraIpPoolReadiness for non ArcGateway connection type"
                $script:envchktestList = @( "Test-NwkValidator_InfraIpPoolReadiness",
                                            "Test-NwkValidator_IntentVirtualAdapterExistence")
            }
            "PreUpdate"
            {
                Log-Info -Message "Will check network configuration needed for running a success patch and update operation"
                $script:envchktestList = @( "Test-NwkValidator_HostNetworkConfigurationReadiness",
                                            "Test-NwkValidator_AdapterDriverMgmtAdapterReadiness",
                                            "Test-NwkValidator_ClusterNetworkIntentStatus",
                                            "Test-NwkValidator_IntentVirtualAdapterExistence",
                                            "Test-NwkValidator_StorageAdapterIPConfigurationPreUpdate")

                if (-not $dhcpEnabled) {
                    # For static IP deployment, need to validate management IP should not change after initial deployment
                    $script:envchktestList += "Test-NwkValidator_MgmtIpConfigurationForStaticDeployment"
                }
            }
        }

        # SAN deployments do not use NetworkATC storage intents; skip storage intent existence check
        # but add SAN cluster network adapter readiness check instead
        if ($callingTestParam.StorageType -ieq 'SAN') {
            Log-Info -Message "SAN scenario detected. Removing Test-NwkValidator_StorageIntentExistence from the test list."
            $script:envchktestList = $script:envchktestList | Where-Object { $_ -ne "Test-NwkValidator_StorageIntentExistence" }

            # Only add SAN cluster network adapter readiness test for Deployment and AddNode operations
            if ($OperationType -in @('Deployment', 'AddNode')) {
                Log-Info -Message "SAN scenario detected for $OperationType. Adding Test-NwkValidator_SanClusterNetworkAdapterReadiness to the test list."
                $script:envchktestList += "Test-NwkValidator_SanClusterNetworkAdapterReadiness"
            } else {
                Log-Info -Message "SAN scenario detected for $OperationType. Test-NwkValidator_SanClusterNetworkAdapterReadiness is not required for this operation type."
            }
        }

        # Apply Include/Exclude filtering
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $script:envchktestList
        #endregion

        Log-Info -Message "Network validator to run during [ $($OperationType) ]: [ $($script:envchktestList -join ', ') ]"
        $Result = @()

        $TotalTestCount = ($script:envchktestList).Count

        if($TotalTestCount -eq 0)
        {
            Log-Info "No test cases need to be run."
            return $result
        }

        # Run validation
        $i = 0
        $ProgressActivity = "Checking AzStackHci Network Compatibility"
        $i = 0
        $ProgressStatus = "Testing $ENV:ComputerName"
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }
        Write-Progress @progressParams

        :noTestsBreak foreach ($test in $script:envchktestList)
        {
            $OpMsg = "Run network validator [{0}] on {1}" -f $test, $ENV:ComputerName
            Log-Info -Message $OpMsg
            Write-Progress @progressParams -CurrentOperation $OpMsg -PercentComplete (($i++ / $TotalTestCount) * 100)

            $invokeParameters = @{}
            Get-Command $test | Select-Object -ExpandProperty Parameters | Select-Object -ExpandProperty Keys | ForEach-Object {
                if ($callingTestParam.ContainsKey($PSITEM)) {
                    $invokeParameters += @{
                        $PSITEM = $callingTestParam[$PSITEM]
                    }
                }
            }

            Log-Info "Parameters used for current validator: [ $test ]"
            foreach ($param in $invokeParameters.GetEnumerator())
            {
                if ($param.Key -ne 'PSSession')
                {
                    Log-Info -Message "Parameter: $($param.Key) = $($param.Value | ConvertTo-Json -Depth 5)"
                }
            }
            $Result += Invoke-Expression "$test @invokeParameters"

            $OpMsg = "End of network validator [{0}] run on {1}`n" -f $test, $ENV:ComputerName
            Log-Info -Message $OpMsg
        }

        # Feedback results - user scenario
        Log-Info "Network validation finished!" -ConsoleOut:(-not $PassThru)

        if (-not $PassThru)
        {
            $progressParams = @{
                Id              = 3
                Activity        = "Formating Results"
                Status          = "Writing Results for $($ENV:ComputerName)"
                PercentComplete = 1
                ErrorAction     = 'SilentlyContinue'
            }
            Write-Progress @progressParams
            Write-AzStackHciResult -Title "$($ENV:COMPUTERNAME):" -Result $result -ShowFailedOnly:$ShowFailedOnly -Seperator ': '
            Write-Summary -Result $Result -Property1 Detail
        }
        else
        {
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
        $envCheckerReport | Add-Member -MemberType NoteProperty -Name 'Network' -Value $Result -Force
        $envCheckerReport = Close-AzStackHciEnvJob -report $envCheckerReport
        Write-AzStackHciEnvReport -report $envCheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

# SIG # Begin signature block
# MIInRgYJKoZIhvcNAQcCoIInNzCCJzMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBGOmitah7g5uAE
# knnqmJ05+O3p4VNrAdK95UJDzisKdKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIILFx12c
# 4mohX5+Gd8vQdF6OEcwKrWIkqpDEgUpW2z5NMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAIEW+lQEHTn5YMPC5TMMJOCRi6ttxxFWyaWPWSUCc
# 1nCyN8mdVqm+R7GxlCAlUBi5hN7KGib5ntCyMNu0f67RF1nejqhsjasrUCbIF+uC
# z660RAv4YPs69hadjHpJMpjiS3srlMnVsPwNUfRpB6o1sAtN9ScO84aNU4kzigcC
# 31DxuEf9niWytBIhzyUWv3hch68HDpQJx7wuoKz6jZ08RSO5l3zpjFa0PjXzLGsr
# IwB4EVePXsfmBLj0xIJ0xJBgwf+XnLZPxu+c1KRRiK52cFrCvnTyr8yVq5I+3l42
# CaQ+lPa79wqvai+oBIaQ7WzLqRuOnYvOsHr73UMeIetUR6GCF5QwgheQBgorBgEE
# AYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAVguNWy72UDkvnI/lDigPVnuDv0jaYeH3q5ONO
# co4WZgIGaedeW7IfGBMyMDI2MDUwMzE0MzExMC45MjdaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgITMwAAAijwpYfX88geQAABAAAC
# KDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMDZaFw0yNzA1MTcxOTQwMDZaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCujvbk/sqcCSReZaJfCuf1NwRc
# c7XknhE6wkLofkNj1mxEAg35qy2xcFjgjartVvA09W8QHcpyMqVSXOTxNHJsmk0q
# P2CDLvUAulWg7aS5oBORpEX1oz3n0R2nPqeH0IHK1zJxjxaHW21AbuZ0Z+wM3WYN
# zkBlcHmVe03ZG7rlk28h72r5P5ME8FGpFmYW5Hl7psKbgLEfrYAitpttsb+sZsBU
# I+hMKl4uLJYotKyZv1ewOIinBfRU8QosivjofaBezUf9NdV+iGrWh321WnSsK3A/
# Jl6GLtbSWXcJWULgbxuqnobPK+YlB3174TMWTgX4YWjG7o0Otz/pjHNCKBbB788d
# ynhLdGY6B08E9+4SGrRpsty4iJHOydHCA5M4i5yYRwsdut+gmvxIpT8yNXJcjJCg
# 0vO8mv/nFY9Wytv2qmCtCFFivGUWqU20/sUeRooQZGiQOJQn095Cj3isIsvRP8KU
# 7hN/EDI8HVsb/NPzMFLvRznrRnj0TOnDiOTUcnYwmk+XfoS1owskcCCCwHnbC00D
# 58z83y7K5ZJB745hcn4CE2nR3e6RGsr42y5qtt6Mdz/s7MTnDS2UmVHWX1X/HZe3
# UlX8gj/t63L50xIPqkRCBEdM1ADNUaSfo9OQiKb/bj1diZCGTfEDUBBLop1mhkwI
# F82faplV2busZ+U4kQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFKrJpYz48tzouvVk
# BVthASFpQ93DMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCQ6NfLmrRahgVtgWg3
# 83GaS07fHyod6bhcUONt2tet+6BaNuH0r7ABkVHheOpxBdrUrOEYVEaIii9dK3cu
# ZLNmp1iUAx/VbmOZYl7xz+tNrjCWqrg1jQmq0oRB8iE4QJpwNhGP67oY5huYIU0D
# 4lhDoahqfgKJn/0Bk+9UKDPw5XlUYmreFmJlj9YQzcPPep8MxBXxh/Y5I7vQeRaW
# 5SjtiLQOLRk3ggvraDs5Sf49MJV6/BwxXC2rvUfEFX6SUDooqKIE9NgVIRq0RZu7
# Ot0i0Is+HvPP0hB6KwOxMg1SWKOfTtFpWpdo8MJvgKCHkPpXEzgprP+pyIHuO7gV
# RlSTsbYBFLh2yId/itM4uYL0R+2SSBBTpSSRthrGuEmElI5BCHMxzMg/oqHSPwZA
# IAkM2C4xxi0St7qMuA+m+ZzFYkfoF41QoSJn+HjqhqWYQ0m/SO9/KnJRJJUwMd5T
# iMnjZ+E/DJiUry5udiWyQpvfj2hQFI0djhahoAXDazeEciLF2uEnTur9UfjcwOun
# /oMY+ULftnOi2jKLMrreV097akzz/JxpnDgYJU/tgU7fQflg7IqiL9+0276+joQH
# o21mVeY5YD8Kh/kUaY6Jm/OTM88G7evTz/qnRumxovTjMStvpbAHNRhmSTdIPTV3
# 2CyuxDKS/V5a5iwA+f9ViBo+wjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE0MDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQB1rbmFkzS7qAK1Oav08AUnhbNIUqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aGs9jAiGA8y
# MDI2MDUwMzExMTYwNloYDzIwMjYwNTA0MTExNjA2WjB0MDoGCisGAQQBhFkKBAEx
# LDAqMAoCBQDtoaz2AgEAMAcCAQACAh38MAcCAQACAhOMMAoCBQDtov52AgEAMDYG
# CisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEA
# AgMBhqAwDQYJKoZIhvcNAQELBQADggEBALwsL2mQmgXhEHIN+3Qcb8doncIqs9Mr
# R5LeJc+wkC1vv77d0Ywdyl2XNDNCJrzlAaWl+dv/BFHTIdZj/rA4+mYKN96UcizV
# KCYsbRZpAX3h7NwDHIk3V2VNYUN4ENO53iI7x+cH5CKCY1x6xuJaGvigL9+2Y+cX
# EBcyriNYfcJL++ASqegjjUedxQGwr2bahgUMQrBHMftlij4Ejod7zDvctpBSCx+O
# oG7yEOj97UDjR9jGGhsq1I3qWiiqanx87FJ10LBaqw5vk5RxNWWAHrEUOL7/+Ita
# qqCscHFzPoMv58mm+csyWjNPB8kVVq98fg3BFEnunuotlQRQFZnl1HExggQNMIIE
# CQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYw
# JAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAijwpYfX
# 88geQAABAAACKDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCrqRuLcgeOUMHyQrxyTixK6eGzP66c
# +RXzsyj/N+D6ITCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFWxikZRYGNf
# 4oEVZK1eT45H+3GQ3/qxV75VwuBt+iLXMIGYMIGApH4wfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTACEzMAAAIo8KWH1/PIHkAAAQAAAigwIgQgp4Cb2F6guOZy
# DcPwUXJi0s7Mn7qi2o2Z1BZ5LZlH28swDQYJKoZIhvcNAQELBQAEggIArNPNylxO
# jIdDMEp9a/krmDbyQkTa+7cDg8vGGzJsO5eXKWiOgUrLEaODuSFRN8XMpDPyhk+I
# t43JMDZaVx4IDPVv+xvw0Gpf0YWVlwgWw4iHs//tevPC1MOrUYe/1ACb+v0zBFng
# +VcuxMV9c5HpxzvDAkPgqCw0QCVTCU/bX++/BDp36EA+gCBYF9WBqwAPvUy9nEai
# M/MESA8IJicFTfEOxHwsrztEyZ4PgEMJHvUWdgSOyWzsrUkdsEZ6zAY2utDj1QDt
# +A2fiYkV7tZSEOk0SUYaeAiGEVJIAMrQPp5KeytpyFXnaMM33AGrNLIs0PAyKCba
# 9uqv3cdYfx28GydZ09/J80HnJV6h9wxNAYS85/mmoyLwDWm2fx+K6akNK6lFGk/e
# o/E71kIUWKytuQz/uAENSoVDW/p2wUSwaG/HW5XiRQGXFbWQ9IFQePmsDhD2U47q
# 4s7tZe3z9bZRhBDtiSzV35Bjeb809cCWnHxfV1MrO/tjxTOpXEWswsdMq60Jr1q5
# JSSTwnu7Lq/i75krn4z9mu3SVb6RI9nXvsyLDpTeBtQ5uqD20ZAsFnnHAS7iJK9T
# nPPaW+Gyn5jVwtBagLzpKcwknFbOI/MeBlUAVCGF6oUH1LVU54AfGNTk6vIlGcoV
# e7WOQKsUnYkyur5JaFL6e2mydxJ8ut0n0TA=
# SIG # End signature block
