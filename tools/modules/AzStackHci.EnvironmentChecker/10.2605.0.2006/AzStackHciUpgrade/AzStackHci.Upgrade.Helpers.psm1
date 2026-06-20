Import-LocalizedData -BindingVariable luTxt -FileName AzStackHci.Upgrade.Strings.psd1
Import-Module $PSScriptRoot\..\AzStackHciHardware\AzStackHci.Hardware.Helpers.psm1 -DisableNameChecking -Global

function Get-OSBuildFailureResultObject
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('SUCCESS', 'FAILURE')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Detail
    )

    $params = @{
        Name               = 'AzStackHci_Upgrade_Test_Unsupported_OS_Build'
        Title              = 'Test if supported OS Build is installed'
        DisplayName        = 'Test if supported OS Build is installed'
        Severity           = 'CRITICAL'
        Description        = 'Test if supported OS Build is installed'
        Tags               = @{}
        Remediation        = 'https://aka.ms/UpgradeRequirements'
        TargetResourceID   = $ENV:COMPUTERNAME
        TargetResourceName = $ENV:COMPUTERNAME
        TargetResourceType = 'OperatingSystem'
        Timestamp          = [datetime]::UtcNow
        Status             = $Status
        AdditionalData     = @{
            Source    = $ENV:COMPUTERNAME
            Resource  = 'OS Build'
            Detail    = $Detail
            Status    = $Status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    return New-AzStackHciResultObject @params
}

function Test-RequiredWindowsVersionForUpgrade
{
    <#
    .SYNOPSIS
        Test Windows OS is Supported
    .DESCRIPTION
        Test Windows OS is Supported
    .EXAMPLE
        PS C:\> Test-RequiredWindowsVersionForUpgrade
        Test Windows OS is supported on localhost.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    # Min LCU versions per OS (such as 23H2 or 24H2) that are required for upgrade.
    $minimumLCUVersionsPerOS = @()
    $minimumLCUVersionsPerOS += New-Object PSObject -Property @{MinOS = '23H2';MinLCU = [System.Version]'10.0.25398.1904'} # Will enforce any 10B+ LCU
    $minimumLCUVersionsPerOS += New-Object PSObject -Property @{MinOS = '24H2';MinLCU = [System.Version]'10.0.26100.32814'} # Will enforce any 5B+ LCU
    Log-Info $($luTxt.OSCheckScanning -f $(($minimumLCUVersionsPerOS | ForEach-Object { "$($_.MinOS)($($_.MinLCU))"}) -join ','))

    try
    {
        Import-Module "$PsScriptRoot\..\AzStackHciSoftware\AzStackHci.Software.Helpers.psm1" -Force

        # Get OS Build from any host node to determine what OS family to go after.
        # If PsSession hasn't been passed, it means we are running locally on host node and should get the OS version from local machine.
        # If PsSession has been passed, it means we are running remotely and should identify OS version from one of the sessions.
        if ($PsSession.Count -eq 0)
        {
            $anyNodeOSVersion = GetOSVersion
            $anyNodeOSBuild = $anyNodeOSVersion.OSVersion.Build
            Log-Info $($luTxt.OSCheckQueryingLocal -f $anyNodeOSBuild, $anyNodeOSVersion.ComputerName)
        }
        else
        {
            $psSessionOSVersion = (GetOSVersion -PsSession $PsSession)[0]
            $anyNodeOSBuild = $psSessionOSVersion.OSVersion.Build
            Log-Info $($luTxt.OSCheckQueryingSession -f $anyNodeOSBuild, $psSessionOSVersion.ComputerName)
        }

        if (-not $anyNodeOSBuild)
        {
            $detail = $luTxt.OSCheckCannotQueryNodeBuild
            Log-Info $detail -Type CRITICAL
            return (Get-OSBuildFailureResultObject 'FAILURE' $detail)
        }

        # Local node's OS build must match at-least one from the min LCU versions per OS. We only need to check
        # one node to determine the OS family, since all nodes in the cluster should be on the same OS version.
        # This will be enforced later via Test-OSVersion.
        $supportedVersion = $minimumLCUVersionsPerOS | Where-Object {$_.MinLCU.Build -eq $anyNodeOSBuild}
        if (-not $supportedVersion)
        {
            $expectedBuilds = ($minimumLCUVersionsPerOS | ForEach-Object { "$($_.MinOS)($($_.MinLCU.Build))"}) -join ' or '
            $detail = $luTxt.OSCheckUnsupportedBuild -f $ENV:COMPUTERNAME, $anyNodeOSBuild, $expectedBuilds
            Log-Info $detail -Type CRITICAL
            return (Get-OSBuildFailureResultObject 'FAILURE' $detail)
        }
        else
        {
            Log-Info $($luTxt.OSCheckMinVerToCheck -f $($supportedVersion.MinLCU))
        }

        # Will internally ensure that local node's LCU matches min requirement and then ensures that LCU of
        # other nodes exactly matches that of local node.
        $instanceResults = Test-OSVersion -PsSession $PsSession -MinimumVersion "$($supportedVersion.MinLCU)"
        foreach ($instanceResult in $instanceResults)
        {
            $instanceResult.Name = 'AzStackHci_Upgrade_Windows_OS_Version'
            $instanceResult.Title = 'Test Windows OS is Supported'
            $instanceResult.DisplayName = 'Test Windows OS is Supported'
            $instanceResult.Description = 'Checking Windows OS is Supported'
            $instanceResult.Tags = @{}
            $instanceResult.Severity = 'CRITICAL'
            $instanceResult.Remediation = 'https://aka.ms/UpgradeRequirements'
            $instanceResult.TargetResourceID = $instanceResult.TargetResourceName
            $instanceResult.TargetResourceType = 'OS'
            $instanceResult.HealthCheckSource = $ENV:EnvChkrId
        }
        return @(New-AggregatedTestResult -TestName 'Test-RequiredWindowsVersionForUpgrade' `
                -DisplayName 'Required Windows Version' `
                -Description 'Checking Windows version meets upgrade requirements' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}

function Test-RequiredWindowsFeature
{
    <#
    .SYNOPSIS
        Test if the required Windows feature is installed
    .DESCRIPTION
        Test if the required Windows feature is installed
    .EXAMPLE
        PS C:\> Test-RequiredWindowsFeature
        Test if the required Windows feature is installed on localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            # Can be dedup with windowsOptionalFeatureToCheck
            $windowsFeatureTocheck =  @(
                "Failover-Clustering",
                "NetworkATC",
                "RSAT-AD-Powershell",
                "RSAT-Hyper-V-Tools",
                "Data-Center-Bridging",
                "NetworkVirtualization",
                "RSAT-AD-AdminCenter"
            )
            $windowsOptionalFeatureToCheck = @(
                "Server-Core",
                "ServerManager-Core-RSAT",
                "ServerManager-Core-RSAT-Role-Tools",
                "ServerManager-Core-RSAT-Feature-Tools",
                "DataCenterBridging-LLDP-Tools",
                "Microsoft-Hyper-V",
                "Microsoft-Hyper-V-Offline",
                "Microsoft-Hyper-V-Online",
                "RSAT-Hyper-V-Tools-Feature",
                "Microsoft-Hyper-V-Management-PowerShell",
                "NetworkVirtualization",
                "RSAT-AD-Tools-Feature",
                "RSAT-ADDS-Tools-Feature",
                "DirectoryServices-DomainController-Tools",
                "ActiveDirectory-PowerShell",
                "DirectoryServices-AdministrativeCenter",
                "DNS-Server-Tools",
                "EnhancedStorage",
                "WCF-Services45",
                "WCF-TCP-PortSharing45",
                "NetworkController",
                "NetFx4ServerFeatures",
                "NetFx4",
                "MicrosoftWindowsPowerShellRoot",
                "MicrosoftWindowsPowerShell",
                "Server-Psh-Cmdlets",
                "KeyDistributionService-PSH-Cmdlets",
                "TlsSessionTicketKey-PSH-Cmdlets",
                "Tpm-PSH-Cmdlets",
                "FSRM-Infrastructure",
                "ServerCore-WOW64",
                "SmbDirect",
                "FailoverCluster-AdminPak",
                "Windows-Defender",
                "SMBBW",
                "FailoverCluster-FullServer",
                "FailoverCluster-PowerShell",
                "Microsoft-Windows-GroupPolicy-ServerAdminTools-Update",
                "DataCenterBridging",
                "BitLocker",
                "FileServerVSSAgent",
                "FileAndStorage-Services",
                "Storage-Services",
                "File-Services",
                "CoreFileServer",
                "SystemDataArchiver",
                "ServerCoreFonts-NonCritical-Fonts-MinConsoleFonts",
                "ServerCoreFonts-NonCritical-Fonts-BitmapFonts",
                "ServerCoreFonts-NonCritical-Fonts-TrueType",
                "ServerCoreFonts-NonCritical-Fonts-UAPFonts",
                "ServerCoreFonts-NonCritical-Fonts-Support",
                "ServerCore-Drivers-General",
                "ServerCore-Drivers-General-WOW64",
                "NetworkATC"
            )
            $windowsFeatureNotInstalled = @()
            foreach ($featureName in $windowsFeatureToCheck)
            {
                if (-not (Get-WindowsFeature -Name $featureName | Where-Object InstallState -eq Installed))
                {
                    $windowsFeatureNotInstalled += $featureName
                }
            }
            $windowsOptionalFeatureNotEnabled = @()
            foreach ($featureName in $windowsOptionalFeatureToCheck)
            {
                if (-not (Get-WindowsOptionalFeature -Online -FeatureName $featureName | Where-Object State -eq Enabled))
                {
                    $windowsOptionalFeatureNotEnabled += $featureName
                }
            }
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                list = $windowsFeatureNotInstalled + $windowsOptionalFeatureNotEnabled
                result = ($windowsFeatureNotInstalled.Count -eq 0) -and ($windowsOptionalFeatureNotEnabled.Count -eq 0)
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.RequiredWindowsFeatureEnabled -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $featureList = ($output.list) -join ', '
                $detail = $luTxt.RequiredWindowsFeatureNotEnabled -f $featureList, $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Required_Windows_Features'
                Title              = 'Test Required Windows features'
                DisplayName        = 'Test Required Windows features'
                Severity           = 'Critical'
                Description        = 'Checks that all nodes have the required Windows features installed'
                Tags               = @{}
                Remediation        = "https://aka.ms/UpgradeRequirements"
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Feature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Required Windows features '
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-RequiredWindowsFeature' `
                -DisplayName 'Required Windows Features' `
                -Description 'Checking required Windows features are installed' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }

}

function Test-NetworkAtcIntents
{
    <#
    .SYNOPSIS
        Test the required Network ATC intents are present and in heathy state
    .DESCRIPTION
        Test the required Network ATC intents are present and in heathy state
    .EXAMPLE
        PS C:\> Test-NetworkAtcIntents
        Test the required Network ATC intents are present and in heathy state.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            $networkATC = [bool](Get-WindowsFeature -Name NetworkATC | Where-Object InstallState -eq 'Installed')
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $networkATC
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $hasError = $false
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.NetworkAtcEnabled -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $hasError = $true
                $detail = $luTxt.NetworkAtcNotEnabled -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_Test_NetworkATCFeature_Installed'
                Title              = 'Test Network ATC feature is installed on the node'
                DisplayName        = 'Test Network ATC feature is installed on the node'
                Severity           = 'CRITICAL'
                Description        = 'Checking Network ATC feature is enabled on the node'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeNetworkATC'
                TargetResourceID   = 'NetworkAtcFeature'
                TargetResourceName = 'NetworkAtcFeature'
                TargetResourceType = 'NetworkAtcFeature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Network ATC'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        # If there is a node that doesn't have Network ATC enabled, then the cluster won't have proper network ATC intents configured. So no need to check further.
        if ($hasError)
        {
            return @(New-AggregatedTestResult -TestName 'Test-NetworkAtcIntents' `
                    -DisplayName 'Network ATC Intents' `
                    -Description 'Checking Network ATC intent configuration' `
                    -DetailResults $instanceResults `
                    -ValidatorName 'Upgrade' `
                    -ResourceType 'OperatingSystem' `
                    -Remediation 'https://aka.ms/UpgradeNetworkATC')
        }

        # Check if the Network ATC service is running on the nodes
        $remoteOutput = @()
        $sb = {
            $atcService = Get-Service NetworkATC -ErrorAction SilentlyContinue
            $atcServiceRunning = $atcService -and $atcService.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $atcServiceRunning
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.NetworkAtcServiceRunning -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.NetworkAtcServiceNotRunning -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_Test_NetworkATCService_Running'
                Title              = 'Test NetworkATC service is running on the node'
                DisplayName        = 'Test NetworkATC service is running on the node'
                Severity           = 'CRITICAL'
                Description        = 'Checking NetworkATC service is running on the node'
                Tags               = @{}
                Remediation        = 'Make sure NetworkAtc service is running on the node. If not, start the service.'
                TargetResourceID   = 'NetworkAtcService'
                TargetResourceName = 'NetworkAtcService'
                TargetResourceType = 'NetworkAtcService'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Network ATC'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        # Check if the required Network ATC intents are present
        $remoteOutput = @()
        $sb = {
            $intents = Get-NetIntent -ErrorAction SilentlyContinue
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $intents
            }
        }
        if ($PsSession)
        {
            $clusterNodesCount = Invoke-Command -Session $PsSession[0] { (Get-ClusterNode).Count }
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $clusterNodesCount = (Get-ClusterNode).Count
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        foreach ($output in $remoteOutput)
        {
            if ($null -eq $output.result)
            {
                $status = 'FAILURE'
                $detail = $luTxt.NetworkAtcIntentsNotPresent -f $output.ComputerName
                Log-Info $detail -Type CRITICAL

                $params = @{
                    Name               = 'AzStackHci_Upgrade_Test_NetworkATCIntents_Present'
                    Title              = 'Test NetworkATC intents are present on the node'
                    DisplayName        = 'Test NetworkATC intents are present on the node'
                    Severity           = 'CRITICAL'
                    Description        = 'Checking NetworkATC intents are present on the node'
                    Tags               = @{}
                    Remediation        = 'Make sure NetworkATC intents are properly configured on the node.'
                    TargetResourceID   = 'NetworkAtcIntents'
                    TargetResourceName = 'NetworkAtcIntents'
                    TargetResourceType = 'NetworkAtcIntents'
                    Timestamp          = [datetime]::UtcNow
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $output.ComputerName
                        Resource  = 'Network ATC'
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $instanceResults += New-AzStackHciResultObject @params
            }
            else
            {
                $outputResultString = $output.result | Out-String
                log-info "Get-NetIntent returned from node $($output.ComputerName) : $outputResultString"

                $isManagementIntentPresent = $output.result | Where-Object { $_.IsManagementIntentSet -eq $true }
                $isStorageIntentPresent = $output.result | Where-Object { $_.IsStorageIntentSet -eq $true }

                if (-not $isManagementIntentPresent)
                {
                    $status = 'FAILURE'
                    $detail = $luTxt.NetworkAtcManagementIntentNotPresent -f $output.ComputerName
                    Log-Info $detail -Type CRITICAL

                    $params = @{
                        Name               = 'AzStackHci_Upgrade_Test_NetworkATCManagementIntent_Present'
                        Title              = 'Test NetworkATC management intent is present on the node'
                        DisplayName        = 'Test NetworkATC management intent is present on the node'
                        Severity           = 'CRITICAL'
                        Description        = 'Checking NetworkATC management intent is present on the node'
                        Tags               = @{}
                        Remediation        = 'Make sure NetworkATC management intent is properly configured on the node.'
                        TargetResourceID   = 'NetworkAtcManagementIntent'
                        TargetResourceName = 'NetworkAtcManagementIntent'
                        TargetResourceType = 'NetworkAtcManagementIntent'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $status
                        AdditionalData     = @{
                            Source    = $output.ComputerName
                            Resource  = 'Network ATC'
                            Detail    = $detail
                            Status    = $status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                }
                elseif (-not $isStorageIntentPresent -and $clusterNodesCount -gt 1) {
                    $status = 'FAILURE'
                    $detail = $luTxt.NetworkAtcStorageIntentNotPresent -f $output.ComputerName
                    Log-Info $detail -Type CRITICAL

                    $params = @{
                        Name               = 'AzStackHci_Upgrade_Test_NetworkATCStorageIntent_Present'
                        Title              = 'Test NetworkATC storage intent is present on the node'
                        DisplayName        = 'Test NetworkATC storage intent is present on the node'
                        Severity           = 'CRITICAL'
                        Description        = 'Checking NetworkATC storage intent is present on the node'
                        Tags               = @{}
                        Remediation        = 'Make sure NetworkATC storage intent is properly configured on the node if it is multi-node HCI system.'
                        TargetResourceID   = 'NetworkAtcStorageIntent'
                        TargetResourceName = 'NetworkAtcStorageIntent'
                        TargetResourceType = 'NetworkAtcStorageIntent'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $status
                        AdditionalData     = @{
                            Source    = $output.ComputerName
                            Resource  = 'Network ATC'
                            Detail    = $detail
                            Status    = $status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                }
                else
                {
                    $status = 'SUCCESS'
                    $detail = $luTxt.NetworkAtcRequiredIntentsArePresent -f $output.ComputerName
                    Log-Info $detail

                    $params = @{
                        Name               = 'AzStackHci_Upgrade_Test_NetworkATCRequiredIntents_Present'
                        Title              = 'Test NetworkATC required intents are present on the node'
                        DisplayName        = 'Test NetworkATC required intents are present on the node'
                        Severity           = 'CRITICAL'
                        Description        = 'Checking NetworkATC required intents are present on the node'
                        Tags               = @{}
                        Remediation        = 'https://aka.ms/UpgradeNetworkATC'
                        TargetResourceID   = 'NetworkAtcIntents'
                        TargetResourceName = 'NetworkAtcIntents'
                        TargetResourceType = 'NetworkAtcIntents'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $status
                        AdditionalData     = @{
                            Source    = $output.ComputerName
                            Resource  = 'Network ATC'
                            Detail    = $detail
                            Status    = $status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                }
            }
        }

        # check if the intents on the nodes are in healthy state
        $remoteOutput = @()
        $sb = {
            $stopWatch = [diagnostics.stopwatch]::StartNew()
            $intentStatus = $null

            # NetworkATC might doing drift detection (every 15 min), and intent status might be at "Validating" state for a while.
            # So we will wait for some time to make sure we can get expected Success/Completed status.
            while ($stopWatch.Elapsed.TotalSeconds -lt 1080)
            {
                [PSObject[]] $intentStatus = Get-NetIntentStatus  -ErrorAction SilentlyContinue
                [PSObject[]] $notCompletedOrNotSuccessIntents = $intentStatus | Where-Object { $_.ConfigurationStatus -ne 'Success' -or $_.ProvisioningStatus -ne 'Completed' }
                [PSObject[]] $failedIntents = $intentStatus | Where-Object { $_.ConfigurationStatus -eq 'Failed' }

                if (($notCompletedOrNotSuccessIntents.Count -eq 0) -or ($failedIntents.Count -gt 0))
                {
                    break
                }

                Start-Sleep -seconds 5
            }

            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $intentStatus
            }
        }

        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        foreach ($output in $remoteOutput)
        {
            $resultString = $output.result | Out-String
            log-info "Get-NetIntentStatus returned from node $($output.ComputerName) : $resultString"

            $failedIntents = $output.result | Where-Object { $_.ConfigurationStatus -ne 'Success' -or $_.ProvisioningStatus -ne 'Completed' }

            if ($null -ne $failedIntents)
            {
                $status = 'FAILURE'
                $detail = $luTxt.NetworkAtcIntentsStatusNotHealthy -f $output.ComputerName
                Log-Info $detail -Type CRITICAL

                $params = @{
                    Name               = "AzStackHci_Upgrade_Test_NetworkATCIntent_HealthyState"
                    Title              = "Test NetworkAtc intent configuration and provisioning status"
                    DisplayName        = "Test NetworkAtc intent configuration and provisioning status"
                    Severity           = 'CRITICAL'
                    Description        = "Checking Test NetworkAtc intent configuration and provisioning status"
                    Tags               = @{}
                    Remediation        = "Use Get-NetIntentStatus cmdlet to check the status of the intent and take necessary action to fix the issue."
                    TargetResourceID   = "NetworkAtcIntents"
                    TargetResourceName = "NetworkAtcIntents"
                    TargetResourceType = "NetworkAtcIntents"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $output.ComputerName
                        Resource  = "NetworkAtcIntents"
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $instanceResults += New-AzStackHciResultObject @params
            }
            elseif ($null -eq $output.result)
            {
                $status = 'FAILURE'
                $detail = $luTxt.NetworkAtcIntentsStatusNull -f $output.ComputerName
                Log-Info $detail -Type CRITICAL

                $params = @{
                    Name               = "AzStackHci_Upgrade_Test_NetworkATCIntent_StatusNull"
                    Title              = "Test NetworkAtc intent configuration and provisioning status"
                    DisplayName        = "Test NetworkAtc intent configuration and provisioning status"
                    Severity           = 'CRITICAL'
                    Description        = "Checking Test NetworkAtc intent configuration and provisioning status"
                    Tags               = @{}
                    Remediation        = "Use Get-NetIntentStatus cmdlet to check the status of the intents and take necessary action to fix the issue."
                    TargetResourceID   = "NetworkAtcIntents"
                    TargetResourceName = "NetworkAtcIntents"
                    TargetResourceType = "NetworkAtcIntents"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $output.ComputerName
                        Resource  = "NetworkAtcIntents"
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $instanceResults += New-AzStackHciResultObject @params
            }
            else
            {
                $status = 'SUCCESS'
                $detail = $luTxt.NetworkAtcIntentsHealthy -f $output.ComputerName
                Log-Info $detail

                $params = @{
                    Name               = "AzStackHci_Upgrade_Test_NetworkATCIntent_HealthyState"
                    Title              = "Test NetworkAtc intent configuration and provisioning status"
                    DisplayName        = "Test NetworkAtc intent configuration and provisioning status"
                    Severity           = 'CRITICAL'
                    Description        = "Checking Test NetworkAtc intent configuration and provisioning status"
                    Tags               = @{}
                    Remediation        = 'https://aka.ms/UpgradeNetworkATC'
                    TargetResourceID   = "NetworkAtcIntents"
                    TargetResourceName = "NetworkAtcIntents"
                    TargetResourceType = "NetworkAtcIntents"
                    Timestamp          = [datetime]::UtcNow
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $output.ComputerName
                        Resource  = "NetworkAtcIntents"
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $instanceResults += New-AzStackHciResultObject @params
            }
        }

        return @(New-AggregatedTestResult -TestName 'Test-NetworkAtcIntents' `
                -DisplayName 'Network ATC Intents' `
                -Description 'Checking Network ATC intent configuration' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeNetworkATC')
    }
    catch
    {
        throw $_
    }

}

function Test-TPMHealth
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try {
        $results = @()
        $results += Test-TpmVersion -PsSession $PsSession
        $results += Test-TpmProperties -PsSession $PsSession
        $results += Test-TpmCertificates -PsSession $PsSession
        $results | % {
            $_.Name = $_.Name -replace 'Hardware','Upgrade'
            $_.Severity = 'WARNING'
        }
        return @(New-AggregatedTestResult -TestName 'Test-TPMHealth' `
                -DisplayName 'TPM Health' `
                -Description 'Checking TPM health status' `
                -DetailResults $results `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem')
    }
    catch {
        throw $_
    }
}

function Test-BitlockerSuspension
{
    <#
    .SYNOPSIS
        Test if bitlocker is enabled but not in suspended state.
    .DESCRIPTION
        Test if bitlocker is enabled but not in suspended state.
    .EXAMPLE
        PS C:\> function Test-BitlockerSuspension
        Test if bitlocker is enabled but not in suspended state for all volumes.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    $remoteOutput = @()
    try {

        $sb = {

            try {
                $volumes = $null

                try {
                    $volumes = Get-BitLockerVolume
                }
                catch {
                    # Return test result as True/Pass because we dont want to fail test if bitlocker feature is not available.
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        Details = "Could not fetch bitlocker volumes. Error: " + $_.Exception.Message
                        error = $_.Exception.Message
                        result = $true
                        isBitlockerFeatureInstalled = $false
                    }
                }

                $volumeDetails = ""
                $overallStatus = $true

                if($volumes)
                {
                    $criticalVolumes = $volumes |? {$_.KeyProtector.KeyProtectorType -contains "Tpm"}
                    foreach ($volume in $criticalVolumes) {
                        # Get volume information
                        $volumeInfo = Get-BitLockerVolume -MountPoint $volume.MountPoint
                        $volumeMountPoint = $volumeInfo.MountPoint
                        $volumeProtectionStatus = $volumeInfo.ProtectionStatus
                        $volumeType = $volumeInfo.VolumeType

                        # Check if BitLocker protection is enabled
                        if($volumeInfo.ProtectionStatus -eq "On")
                        {
                            $overallStatus = $false
                        }

                        $volumeDetails += "Volume with mount point: $volumeMountPoint and type : $volumeType has a protection status of $volumeProtectionStatus. `n"
                    }
                }
                else {
                    $volumeDetails = "No bitlocker volumes found."
                }
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    Details = $volumeDetails
                    result = $overallStatus
                }
            }
            catch {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    Details = $volumeDetails + $_.Exception.Message
                    error = $_.Exception.Message
                    result = $false
                }
            }
        }

        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            Log-Info $output.Details

            if ($output.result -eq $true)
            {
                if(($output.isBitlockerFeatureInstalled -ne $null) -and ($output.isBitlockerFeatureInstalled -eq $false))
                {
                    $status = 'SUCCESS'
                    $detail = $luTxt.BitlockerFeatureNotInstalled -f $output.ComputerName
                    Log-Info $detail -Type CRITICAL
                }
                else
                {
                    $status = 'SUCCESS'
                    $detail = $luTxt.BitlockerEncryptedVolumesSuspended -f $output.ComputerName
                    Log-Info $detail
                }
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.BitlockerEncryptedVolumesNotSuspended -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_BitlockerSuspension'
                Title              = 'Test Bitlocker Suspension'
                DisplayName        = 'Test Bitlocker Suspension'
                Severity           = 'CRITICAL'
                Description        = 'Checking if any volumes have bitlocker suspended.'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Security'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Bitlocker Suspension'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-BitlockerSuspension' `
                -DisplayName 'BitLocker Suspension' `
                -Description 'Checking BitLocker suspension status' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch {
        throw $_
    }
}

function Test-WdacEnablement
{
    <#
    .SYNOPSIS
        Test if WDAC is enabled
    .DESCRIPTION
        Test if WDAC is enabled
    .EXAMPLE
        PS C:\> function Test-WdacEnablement
        Test if WDAC is enabled on localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            # Bug 32694371: filter out policy files that cannot be applied
            $cipFiles = Get-ChildItem -Path "$env:SystemRoot\System32\CodeIntegrity\CiPolicies\Active" -Filter *.cip | Where-Object { $_.Name -imatch "^\{[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}\}\.cip$" }
            if ($cipFiles.Count -gt 0)
            {
                # Refresh the current policy and check if audit mode is enabled from the lastest event
                Invoke-CimMethod -Namespace 'root\Microsoft\Windows\CI' -ClassName 'PS_UpdateAndCompareCIPolicy' -MethodName 'Update' -Arguments @{FilePath = $cipFiles[0].FullName} | Out-Null
                $events = Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -ErrorAction SilentlyContinue
                $targetEvent = $events | Where-Object { ($_.Id -in @('3099','3096')) -and ($_.Message -imatch $cipFiles[0].BaseName) } | Sort-Object TimeCreated -Descending | Select-Object -First 1
                $eventXml = [XML]$targetEvent.ToXml()
                $eventData = $eventXml.Event.EventData.Data
                $policyOptions = [System.Convert]::ToInt64($eventData[6].'#text', 16)
                # SYSTEM_INTEGRITY_POLICY_ENABLE_AUDIT_MODE 1 << 16 => 65536
                $policyResult = (($policyOptions -band 65536) -eq 0)
            }
            else
            {
                # No WDAC policy file found
                $policyResult = $false
            }
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $policyResult
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'FAILURE'
                $detail = $luTxt.WdacEnabled -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            else
            {
                $status = 'SUCCESS'
                $detail = $luTxt.WdacNotEnabled -f $output.ComputerName
                Log-Info $detail
            }
            $params = @{
                Name               = 'AzStackHci_Upgrade_WDACEnablement'
                Title              = 'Test WDAC Enablement'
                DisplayName        = 'Test WDAC Enablement'
                Severity           = 'CRITICAL'
                Description        = 'Checking if WDAC is enabled'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Security'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'WDAC Enablement'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-WdacEnablement' `
                -DisplayName 'WDAC Enablement' `
                -Description 'Checking WDAC enablement status' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}

function Test-AzureSupportedCloudType
{
     <#
    .SYNOPSIS
        Test if cluster is connected to Azure Public Cloud or Azure US Government Cloud.
    .DESCRIPTION
        Upgrade is only supported for clusters connected to Azure Public Cloud or Azure US Government Cloud.
    .EXAMPLE
        PS C:\> function Test-AzureSupportedCloudType
    .EXAMPLE

    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )


    $sb= {
            try
                {
                    if(Test-Path -Path "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe")
                    {
                        $overallStatus = $true
                        $testDetails = ""
                        $arcAgentStatus = Invoke-Expression -Command "& 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' show -j"
                        # Parsing the status received from Arc agent
                        $arcAgentStatusParsed = $arcAgentStatus | ConvertFrom-Json

                        # Throw an error if the node is Arc enabled to any other cloud apart from Azure Public cloud or Azure US Government Cloud.
                        # Other supported values which are not supported for Upgrade : AzureChinaCloud
                        if ([string]::IsNullOrEmpty($arcAgentStatusParsed.cloud))
                        {
                            $overallStatus = $false
                            $testDetails = "Unable to determine Azure cloud type. ARC Agent status read:  [{0}]" -f $arcAgentStatus
                        }
                        elseif (($arcAgentStatusParsed.cloud -ne "AzureCloud") -and ($arcAgentStatusParsed.cloud -ne "AzureUSGovernment"))
                        {
                            $overallStatus = $false
                            $testDetails = "{0}: Arc Agent is connected to {1}: cloud, which is not supported for upgrade." -f  $ENV:COMPUTERNAME,$arcAgentStatusParsed.cloud
                        }
                    }
                    else
                    {
                        $overallStatus = $false
                        $testDetails ="ARC agent installation cannot be found at : C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe"
                    }
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        Details = $testDetails
                        result = $overallStatus
                        }
                }
                catch
                {
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        Details = $_.Exception.Message
                        result = $false
                    }
                }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            Log-Info $output.Details
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.CloudSupported -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.CloudNotSupported -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_SupportedCloud'
                Title              = 'Test Supported Cloud Type'
                DisplayName        = 'Test Supported Cloud Type'
                Severity           = 'CRITICAL'
                Description        = 'Checking if any node is connected to an unsupported cloud'
                Tags               = @{}
                Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/concepts/system-requirements-23h2'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Feature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Azure Cloud'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-AzureSupportedCloudType' `
                -DisplayName 'Azure Supported Cloud Type' `
                -Description 'Checking Azure cloud type is supported' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://learn.microsoft.com/en-us/azure-stack/hci/concepts/system-requirements-23h2')


}

function Test-AzureStackHCIRegistrationState
{
     <#
    .SYNOPSIS
        Test if cluster registration state is connected.
    .DESCRIPTION
        Upgrade is only supported for clusters which are succesfully registered to azure.
    .EXAMPLE
        PS C:\> function Test-AzureStackHCIRegistrationState
    .EXAMPLE

    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )


    $sb= {
            $severity = 'CRITICAL'
            try
                {

                    $hciRegCmdlet =  Get-Command Get-AzureStackHCI -Type Cmdlet -ErrorAction Ignore
                    if($null -ne $hciRegCmdlet)
                    {
                        $overallStatus = $true
                        $testDetails = ""

                        $clusterRegistrationStatus = $(Get-AzureStackHCI)


                        if ($null -eq $clusterRegistrationStatus)
                        {
                            $overallStatus = $false
                            $testDetails = "Unable to determine Cluster registration status:  [{0}]" -f $clusterRegistrationStatus

                        }
                        elseif ($clusterRegistrationStatus.RegistrationStatus -ne "Registered")
                        {
                            $overallStatus = $false
                            $testDetails = "{0}: Cluster Registration status is:  {1} , expected status: 'Registered'" -f  $ENV:COMPUTERNAME,$clusterRegistrationStatus.RegistrationStatus
                        }
                    }
                    else
                    {
                        $overallStatus = $false
                        $testDetails ="Unable to find 'get-azurestackhci' cmdlet. Azure Stack HCI cluster registration status can only be checked on an Azure Stack HCI node."
                    }
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        Details = $testDetails
                        result = $overallStatus
                        }
                }
                catch
                {
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        Details = $_.Exception.Message
                        result = $false
                    }
                }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            Log-Info $output.Details
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.CloudSupported -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.CloudNotSupported -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_ClusterRegistrationState'
                Title              = 'Test Cluster Registration state'
                DisplayName        = 'Test Cluster Registration state'
                Severity           = 'CRITICAL'
                Description        = 'Checking if the cluster is successfully registered to azure cloud'
                Tags               = @{}
                Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/concepts/system-requirements-23h2'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Feature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Azure Cloud'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-AzureStackHCIRegistrationState' `
                -DisplayName 'HCI Registration State' `
                -Description 'Checking Azure Stack HCI registration state' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://learn.microsoft.com/en-us/azure-stack/hci/concepts/system-requirements-23h2')


}

function Test-AksHciInstallState
{
    <#
    .SYNOPSIS
        Test Windows Deduplication is enabled
    .DESCRIPTION
        Test Windows Deduplication is enabled
    .EXAMPLE
        PS C:\> Test-WindowsDeduplication
        Test if Windows Deduplication is enabled on localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            Import-Module AksHci -ErrorAction SilentlyContinue
            $result = [bool](Get-Module AksHci)
            if($result)
            {
                try
                {
                    $installState = (Get-AksHciConfig).AksHci.installState -ne "NotInstalled"
                    if($installState) {
                        return New-Object PSObject -Property @{
                            ComputerName = $ENV:COMPUTERNAME
                            result = $false
                            error = "AksHci is installed"
                        }
                    }
                }
                catch
                {
                    #NOOP
                }
            }
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $true
                error = ""
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.AksHciNotInstalled -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.AksHciInstalled -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            $params = @{
                Name               = 'AzStackHci_Upgrade_AksHci'
                Title              = 'Test AKS HCI install state'
                DisplayName        = "Test AKS HCI install state on $($output.ComputerName)"
                Severity           = 'CRITICAL'
                Description        = 'Checking if AKS HCI is installed'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Feature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'AKS HCI'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-AksHciInstallState' `
                -DisplayName 'AKS HCI Install State' `
                -Description 'Checking AKS HCI installation state' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}

function Test-MocInstallState
{
    <#
    .SYNOPSIS
        Test Windows Deduplication is enabled
    .DESCRIPTION
        Test Windows Deduplication is enabled
    .EXAMPLE
        PS C:\> Test-WindowsDeduplication
        Test if Windows Deduplication is enabled on localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            Import-Module Moc -ErrorAction SilentlyContinue
            $result = [bool](Get-Module Moc)
            if($result)
            {
                try
                {
                    $installState = (Get-MocConfig).installState -ne "NotInstalled"
                    if($installState) {
                        return New-Object PSObject -Property @{
                            ComputerName = $ENV:COMPUTERNAME
                            result = $false
                            error = "Moc is installed"
                        }
                    }
                }
                catch
                {
                    #NOOP
                }
            }
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $true
                error = ""
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.MocNotInstalled -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.MocInstalled -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            $params = @{
                Name               = 'AzStackHci_Upgrade_Moc'
                Title              = 'Test MOC install state'
                DisplayName        = "Test MOC install state on $($output.ComputerName)"
                Severity           = 'CRITICAL'
                Description        = 'Checking if MOC is installed'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Feature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'MOC'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-MocInstallState' `
                -DisplayName 'MOC Install State' `
                -Description 'Checking MOC installation state' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}

function Test-MocServicesInstallState
{
    <#
    .SYNOPSIS
        Test Windows Deduplication is enabled
    .DESCRIPTION
        Test Windows Deduplication is enabled
    .EXAMPLE
        PS C:\> Test-WindowsDeduplication
        Test if Windows Deduplication is enabled on localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            $service = Get-Service -Name wssdcloudagent -ErrorAction SilentlyContinue
            if($null -ne $service)
            {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    result = $false
                    error = "wssdcloudagent service is running"
                }
            }
            $service = Get-Service -Name wssdagent -ErrorAction SilentlyContinue
            if($null -ne $service)
            {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    result = $false
                    error = "wssdagent service is running"
                }
            }
            $service = Get-Service -Name MocHostAgent -ErrorAction SilentlyContinue
            if($null -ne $service)
            {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    result = $false
                    error = "MocHostAgent service is running"
                }
            }
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                result = $true
                error = ""
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.result)
            {
                $status = 'SUCCESS'
                $detail = $luTxt.MocServicesNotInstalled -f $output.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.MocServicesInstalled -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            $params = @{
                Name               = 'AzStackHci_Upgrade_MocServices'
                Title              = 'Test MOC services running'
                DisplayName        = "Test MOC services running on $($output.ComputerName)"
                Severity           = 'CRITICAL'
                Description        = 'Checking MOC services running state'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Feature'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'MOC services'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-MocServicesInstallState' `
                -DisplayName 'MOC Services Install State' `
                -Description 'Checking MOC services installation state' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}

function Test-Language
{
    <#
    .SYNOPSIS
        Test if the language is English-US
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            $lang = Get-WinUserLanguageList
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                Language = $lang
                User = $ENV:USERNAME
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            Log-Info "Langauges on $($output.ComputerName) :"
            Log-Info  ($output.Language | Out-String)
            if ($output.Language.LanguageTag -like 'en-*')
            {
                $status = 'SUCCESS'
                $detail = $luTxt.LanguageEnglishUS -f $output.ComputerName, $output.User
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $luTxt.LanguageNotEnglishUS -f $output.ComputerName, $output.Language.LanguageTag, $output.User
                Log-Info $detail -Type CRITICAL
            }
            $params = @{
                Name               = 'AzStackHci_Upgrade_Language'
                Title              = 'Test Language is English'
                DisplayName        = 'Test Language is English'
                Severity           = 'CRITICAL'
                Description        = 'Checking if the language is English for deployment user'
                Tags               = @{}
                Remediation        = "https://aka.ms/UpgradeRequirements"
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Language'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = "Language: $($output.Language.LanguageTag)"
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-Language' `
                -DisplayName 'Language Settings' `
                -Description 'Checking language configuration' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}

function Test-Storage
{
    [CmdletBinding()]
    param ()
    try {
        $results = @()
        $poolConfigXml = [xml]'<StoragePool><Volumes><Volume Name="Infrastructure_1" Size="256GB" MinNodeCount="1" ></Volume></Volumes></StoragePool>'
        $results += Invoke-AzStackHciStorageValidation -PoolConfigXml $poolConfigXml -PassThru -Exclude Test-StoragePoolCapacity
        $results | % {
            $_.Name = $_.Name -replace 'AzStackHci_Storage','AzStackHci_Upgrade'
        }
        return @(New-AggregatedTestResult -TestName 'Test-Storage' `
                -DisplayName 'Storage' `
                -Description 'Checking storage configuration' `
                -DetailResults $results `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem')
    }
    catch {
        throw $_
    }
}

function Test-LCMVersion
{
    <#
    .SYNOPSIS
        Test if the LCM version meets the minimum requirement
    .DESCRIPTION
        Test if the LCM version meets the minimum requirement
    .EXAMPLE
        PS C:\> function Test-LCMVersion
        Test if the LCM version meets the minimum requirement
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            $lcmControllerService = Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -eq 'LcmController' }
            if ($lcmControllerService.State -eq "Running")
            {
                $lcmPathParts = $lcmControllerService.PathName -split '\\'
                $lcmNugetName = $lcmPathParts | Where-Object {$_ -like "Microsoft.AzureStack.Solution.LCMControllerWinService*"}

                if ($lcmNugetName -match '\.(\d+\.\d+\.\d+\.\d+)$') {
                    $lcmVersion = $matches[1]
                }
                else
                {
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        Details = "Fail to extract  Controller service version."
                        hasVersion = $false
                    }
                }

                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    lcmVersion = $lcmVersion
                    hasVersion = $true
                }
            }
            else
            {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    Details = "LCM Controller service is not in running state."
                    hasVersion = $false
                }
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            if ($output.hasVersion -eq $false) {
                $status = 'FAILURE'
                $detail = $luTxt.LCMVersionNotAvailable -f $output.ComputerName, $output.Details
                Log-Info $detail -Type CRITICAL
            }
            else
            {
                $minLcmVersion = "10.2408.0.537"
                Log-Info "LCM controllver minimum version requirement is $minLcmVersion"
                $lcmVersion = $output.lcmVersion
                Log-Info "LCM controllver version on $($output.ComputerName) : $lcmVersion"
                $minVersion = [System.Version]$minLcmVersion
                $version = [System.Version]$lcmVersion
                # Compare versions
                if ($version -ge $minVersion) {
                    $status = 'SUCCESS'
                    $detail = $luTxt.LCMVersionMeetMinRequirement -f $output.ComputerName, $lcmVersion, $minLcmVersion
                    Log-Info $detail
                }
                else
                {
                    $status = 'FAILURE'
                    $detail = $luTxt.LCMVersionNotMeetMinRequirement -f $output.ComputerName, $lcmVersion, $minLcmVersion
                    Log-Info $detail -Type CRITICAL
                }
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_Minimum_LCM_Version'
                Title              = 'Test LCM Version meets minimum requirement'
                DisplayName        = 'Test LCM Version meets minimum requirement'
                Severity           = 'Critical'
                Description        = 'Checks that all nodes have the minimum LCM version'
                Tags               = @{}
                Remediation        = "https://aka.ms/UpgradeRequirements"
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'LCMService'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'LCM Version'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-LCMVersion' `
                -DisplayName 'LCM Version' `
                -Description 'Checking LCM version compatibility' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }

}

function Get-SupportOsVersion
{
    try {
        Log-Info "Getting the supported OS version"
        $nugetPath = Get-ASArtifactPath -NugetName Microsoft.AzureStack.Solution.Deploy.ProductNugets
        $xmlPath = Join-Path -Path $nugetPath -ChildPath ProductNugets.xml
        Log-Info "Reading the xml file from $xmlPath"
        [xml]$xml = Get-Content -Path $xmlPath
        Log-info "Getting the OS version from the xml file $xmlPath"
        $osVersion = $xml| Select-Xml -XPath "//NuGetPackage[@Name='Microsoft.AzureStack.OSUpdates']" | Select-Object -ExpandProperty Node | Select-Object -ExpandProperty RequiredVersion
        Log-info "Found supported OS version: $osVersion"
        return $osVersion
    }
    catch {
        Log-Info "Failed to get the supported OS version. Error: $_" -Type WARNING
    }
}

function Test-FreeMemory
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $RequiredMemoryGB = 8 # Required for ARB VM
        $severity = 'CRITICAL'
        $remoteOutput = @()
        $sb = {
            $AvailableMemoryGB = [System.Math]::Round((Get-WmiObject -Class Win32_OperatingSystem).FreePhysicalMemory * 1KB / 1GB,2)
            return (New-Object psobject -Property @{
                    AvailableMemoryGB = $AvailableMemoryGB
                    ComputerName = $ENV:COMPUTERNAME
                }
            )
        }

        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        foreach ($output in $remoteOutput)
        {
            $dtl = $luTxt.AvailableMemory -f $output.ComputerName, [System.Math]::Round($output.AvailableMemoryGB,2), ($RequiredMemoryGB)
            if ($output.AvailableMemoryGB -gt $RequiredMemoryGB)
            {
                $status = 'SUCCESS'
                Log-Info $dtl
            }
            else
            {
                $status = 'FAILURE'
                Log-Info $dtl -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_FreeMemory'
                Title              = 'Test Free Memory'
                DisplayName        = 'Test Free Memory'
                Severity           = $severity
                Description        = 'Checking if there is enough free memory'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Memory'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Memory'
                    Detail    = $dtl
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return @(New-AggregatedTestResult -TestName 'Test-FreeMemory' `
                -DisplayName 'Free Memory' `
                -Description 'Checking available free memory' `
                -DetailResults $instanceResults `
                -ValidatorName 'Upgrade' `
                -ResourceType 'OperatingSystem' `
                -Remediation 'https://aka.ms/UpgradeRequirements')
    }
    catch
    {
        throw $_
    }
}


function Test-AlreadyDeployed
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    $severity = 'INFORMATIONAL'
    $remoteOutput = @()
    $sb = {
        try {
            $eceWindowsService = Get-Service | Where-Object Name -eq "Azure Stack HCI Orchestrator Service"
            $HasECEService = ($null -ne $eceWindowsService)
            $overrideRegistryKey = Get-ItemProperty -Path "HKLM:\Software\Microsoft\LCMAzureStackStampInformation" -Name "ValidateAlreadyDeployedForUpgrade" -ErrorAction Ignore
            $HasOverrideRegistry = ($overrideRegistryKey -and $overrideRegistryKey.ValidateAlreadyDeployedForUpgrade -eq "Bypass")
        }
        catch {
            # Wrapped in try catch, by default this test will pass if something goes wrong.
            $HasECEService = $null
            $HasOverrideRegistry = $null
        }

        return (New-Object psobject -Property @{
                HasECEService = $HasECEService
                HasOverrideRegistry = $HasOverrideRegistry
                ComputerName = $ENV:COMPUTERNAME
            }
        )
    }

    if ($PsSession)
    {
        $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
    }
    else
    {
        $remoteOutput += Invoke-Command -ScriptBlock $sb
    }

    $instanceResults = @()
    foreach ($output in $remoteOutput)
    {
        $dtl = $luTxt.DeployedPresence -f $output.ComputerName, $output.HasECEService
        if ($true -eq $output.HasOverrideRegistry)
        {
            # Override registry is set to bypass the ECE service check.
            $status = 'SUCCESS'
            Log-Info $dtl
        }
        elseif ($true -eq $output.HasECEService)
        {
            # Cannot start upgrade if ECE is already installed. This is a wrong scenario.
            $status = 'FAILURE'
            Log-Info $dtl -Type Warning
        }
        else
        {
            # This case ensure the NULL HasECEService is treated as not installed.
            $status = 'SUCCESS'
            Log-Info $dtl
        }

        $params = @{
            Name               = 'AzStackHci_Upgrade_AlreadyDeployedEnvironment'
            Title              = 'Test Environment is already deployed'
            DisplayName        = 'Test Environment is already deployed'
            Severity           = $severity
            Description        = 'Checking if the environment is already deployed'
            Tags               = @{}
            Remediation        = 'Cluster Upgrade is not allowed on a previously deployed Azure Local cluster. Please refer to aka.ms/KnownIssueUpgradeOfferedOnDeployedCluster.'
            TargetResourceID   = $output.ComputerName
            TargetResourceName = $output.ComputerName
            TargetResourceType = 'Service'
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = $output.ComputerName
                Resource  = 'Service'
                Detail    = $dtl
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @params
    }
    return @(New-AggregatedTestResult -TestName 'Test-AlreadyDeployed' `
            -DisplayName 'Already Deployed' `
            -Description 'Checking deployment state' `
            -DetailResults $instanceResults `
            -ValidatorName 'Upgrade' `
            -ResourceType 'OperatingSystem' `
            -Remediation 'Cluster Upgrade is not allowed on a previously deployed Azure Local cluster. Please refer to aka.ms/KnownIssueUpgradeOfferedOnDeployedCluster.')
}


Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIIncAYJKoZIhvcNAQcCoIInYTCCJ10CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAjNyVWQOY+N8i8
# On/wD1TF1p42A4FOm40MKIyo7CsU0aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn9MIIZ+QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIKBPUPm9RmtSjzewIOh1z8c82lnQFTv+5hAt3zY+S4djMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAl7NjJCpIz4YGapxtJeMh
# L8QFfjOteETLUbsn/tNuYwUzjJHXnvFEnaIDzy0GXYsgwhrRgMWvTmNiwQeW46xx
# 6CyS8z1/gtk7n8wX2XWS7b/KPNV0TEOsNexG1oBpf7BbwDkEeyumDwsqpQ3lPLhn
# Kdh2o0QGVpVAS8nllGm2fnxi9Nxb0VTNl+NEhc0wIni7QZ6CqGC6/uRoctfTmRKZ
# j9Re5P/unhZmtBJ2rJPDw3+hHBlbxS1mt37h7gf9umQeyJkUR92L7K832fGeanbj
# 9eeqMpAveKSAUqdfM6a+skwHB2l4EdjTG0p8Hy7BLGOht4jKUq8NHl+VvSB6RCoj
# yKGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cGCSqGSIb3DQEHAqCCF4gwgheE
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0BCRABBKCCAUgEggFEMIIB
# QAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCA/db3fkOVioVIRuh6C
# cPlwQ8ga8WVd3s1rUkvHTvu3aQIGaexb5ppPGBIyMDI2MDUwMzE0MzExMC4xNlow
# BIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR/jCCBygwggUQoAMC
# AQICEzMAAAIb0LK4Amf3cs8AAQAAAhswDQYJKoZIhvcNAQELBQAwfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0MTg0ODMwWhcNMjYxMTEzMTg0
# ODMwWjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsG
# A1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046NTUxQS0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCOxZ3nZlmTMHld7mD+XYaw6MDPfSyDqNXF8UlX7DjEgNXJojcs
# 7xsimbNi6XcBkeDnRQhDw+tJFkalCoWRE276jdgoniDa4ZgFGSwecdhHS5VIJCDn
# xOGRjJ6mUZfegC8ZFW48ilC0CJOxHvoD+B2hTscPARtvvdsnBPKtsoeFH5ZozL0N
# AcjiTlCjj5tkOzSSPvpu+Em90ZT5LzPFAGntQCGMmcWorEi6xIhMTvMIJHjbYQuG
# SFVU4WorbDqHUwC8gt7vqHFEhw+PRIEvavw723HmeNTj62DasB1TXnembKGprN2l
# RxxgET3ANEVR3970KhbHtN2dSJwH4xqLtFPqqx7t7loapfUHtueP9ke+ut8X4EkQ
# iVL2INcBSB6S9dn4VmaO8vA/5037T9yuH76vh7wWScXsRfogl+eY14M3/rxnn2Rt
# onV/4/macph/J0J5mbGsalLS1paQOTfoPeM9Vl+W/Gtz7WuEIiUzm/1qAsQUjXZC
# IFN+k4E4GvcAYI+T54fT6Vq2NBqO6D7b8EPXapvzbnTQtDK1RZPai1r8didGBK/W
# O9nT92aXUWzFZjM6cKuN90H/s3qk3JK3i+f48Y3p0UuKbuTGiz4H1Z9A97MmLd+4
# rLIMAH3NIc+PVm7ydl95xkn26bjOPsMWC8ldMNOcbmqUbhl1sVFr+ut/OQIDAQAB
# o4IBSTCCAUUwHQYDVR0OBBYEFLa+n3f+XEumk0rw6Rq4nYC82YhQMB8GA1UdIwQY
# MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYB
# BQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB
# /wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQBmRTVfFAPg5MzcZOG3fZNdKEh88Ggx9KwWwFCoU5mo
# sk7HIk6WUgEWmam860Y0+QLlnyV0bxoKm+AU2j+MNZ5PkWJbnd0CP0qdnGmxDc9/
# l9HNIYdFzEQw51chXMMnBxlRfRyN/GdrvJ02/x5cH9eTobpLKtHY4fpLUscxbXWb
# dS8oX54uMg+XjmvGKa4MKgR35p3SU4BcDn+9k4o3mf949h4/QtFyFlfRDofyf9mZ
# I8yVuWLcw7znVDT1GZP9kYdr78V3L5YsOvBxjKRX2ZTL/hNvArDoW11Hpk8fEx0i
# LWmTxjaYL8bMKrQsKwfS5MV5DpDs1zcxGYRH/eYtZSFtpYeBfUVthyG9HbZv4G6n
# 5g9HlD/QGFpoA3oAgF9waz67+cmggHLJkoDxxPIKadQj/i9boPi/LCDdcEV/h/YP
# AUfL96+wL7nwoyX6TbBrTlfaQrRP9sI8uFqi/1lfKhtrB804tgaJq4pPYVa9vBnM
# cgUJPGMHDDo+3m5G8IT+OdRx//GGU4YyfqIo71e3j29lMTZJ8gGT/fiItNEEnoft
# oY9NNCfNrc59a7X91HJwLpaXmiezc+OcZdNIpLFeWUk+aDpH+6Uaic/9QJignqY3
# 4ReN/IMs9cuqyv3X5VMbWtjNEKM/AEUAe/gQjBoTRqMKt/vl5QYjf6hdTRQ/quWh
# nzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM
# 57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm
# 95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzB
# RMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBb
# fowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCO
# Mcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYw
# XE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW
# /aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/w
# EPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
# Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2
# BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfH
# CBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYB
# BAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8v
# BO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEF
# BQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBW
# BgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
# AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# L2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518Jx
# Nj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+
# iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2
# pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefw
# C2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7
# T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFO
# Ry3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhL
# mm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3L
# wUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
# m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNZMIICQQIB
# ATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoD
# FQCGhXqvj0zgYF3jUrVFgHVnR/jO4KCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFl1jAiGA8yMDI2MDUwMzA2
# MTIzOFoYDzIwMjYwNTA0MDYxMjM4WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDt
# oWXWAgEAMAoCAQACAgL1AgH/MAcCAQACAhNwMAoCBQDtordWAgEAMDYGCisGAQQB
# hFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAw
# DQYJKoZIhvcNAQELBQADggEBAGkYMsbBisB82G8v30UIVBpEKYpoSYpkMoKTgkGk
# JD+k1VMgIJ0vjnhBkxaQyYtJrySpEZi5HXBTfiDE31XA3qW3L3snLCrrio9W3KUM
# RK3NenDyb6El18J3by2V1nmnZ/mZECDaAYKII/cNVOe3PPFdLrFOA5tFq5ih73E2
# MyizH32HZJjW2BgrgAX30jtQRrtqMRJ0aTxLkY03Ki8KIata5NFsjaEKvKsxbDFl
# RB3ssAEyAtL1/ShXKuELn90PotcVe7O+ujmSgj2hP5FGMSkTZE7RwglFLAoRe3II
# owGEbnVeXbpBTuU5+KvcHhWuWcOm+ZKLjwf7PwkB8grFsBsxggQNMIIECQIBATCB
# kzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAhvQsrgCZ/dyzwAB
# AAACGzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJ
# EAEEMC8GCSqGSIb3DQEJBDEiBCCnOcRww2no39IDdAN44IEOKlyeNVZRsjDEReJh
# qqfF/jCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIDAlFJW4PaOYxxAIVd0u
# 4kDAOlRU1nptzp18lTzdDYuAMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAIb0LK4Amf3cs8AAQAAAhswIgQgmkskmtMKKjrQ05LWi/d2
# 2M3KUn7kORMqL+vObqCwgxAwDQYJKoZIhvcNAQELBQAEggIAeTI0ftVDVBkCtLT6
# Yom2ZjsJSUHbE8mJyPwyUMiF6IxBHixlafhgftlp3q2Dvbg2aQiLnLaY68aq6ebP
# CdWM6ZP2JTjatvauUTSoV3Nc7z8MKkPPyXPvE7h7qa9IJMEcb9g1AasXrbxZkCl2
# BsoB/sEDShSJQ9LXHzyquxh6wnsSgNkpjrOf9Rh7+2YR4/z5arHYcflUJCLDWzeP
# n4fd/m9ebBn39YH0sES1QAhONKY9QHsqHkvFo4A0csvpLb7QLrysnRc/DABgaOpX
# QxvSL+5zVZ5gWJh3Zt+lzGsx4uAVVV1w1z3yxsfVmaNnOR2CwRIc+FDLYc9gM9Ff
# qDIE23voGOmXVj3Z54vMQUCoeSDNfD9OvmSi59BQQ/HtaP6ZtoKuyODdZkB/JyAY
# gZVCE2eV3KbFGmqas61LdUd0LRjA7QQQa3C1uFRvGhXfTfKygR26O8cMa1dsoVA2
# CpEQ4teSr8vu+YbSLlCI3+8aB9ib9DPWaJutR8RW0/wG4Yh4RmNyO8OAYvt0OfUG
# DP2t5L10CvhQPiCZ1SFXkVG+xnFjTznv5DuPx3/bzLtsdYOtXA12sMnQ816Jw5Wq
# rRd+Xh2SiJ2pVyBMgNRJc8R5mdgE3zr1U49PoNclk4oDgbO/XnCFBN2Ziz7u291B
# s6MUAPjSdn2Eo+2gwFVXENbMNIU=
# SIG # End signature block
