Import-LocalizedData -BindingVariable lanTxt -FileName AzStackHci.ArcIntegration.Strings.psd1

function Test-ExistingArcResources {
    [CmdletBinding()]
    param (
        [string]
        $SubscriptionId,
        [string]
        $ArcResourceGroupName,
        [string[]]
        $NodeNames
    )
    try
    {
        $severity = 'CRITICAL'
        #TODO:check if the cmdlet is there, if it is not there, it means it is a different machine, we will fail the test
        $hciRegCmdlet =  Get-Command Get-AzureStackHCI -Type Cmdlet -ErrorAction Ignore
        if($null -eq $hciRegCmdlet)
        {
            # If Get-AzureStackHCI, is not found, fail validation, indicating, validation can only run on HCI OS
            $detail = $lanTxt.ArcValidationNotSupported
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        elseif ($(Get-AzureStackHCI).RegistrationStatus -ne "NotYet")
        {
            # Validation can only be done on un-registred cluster, when run on any other registration state, we will skip the validation
            $detail = $lanTxt.ClusterAlreadyRegistered
            $status = 'SUCCESS'
            Log-Info $detail
        }
        elseif (!$(Get-AzContext))
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        else
        {
            $HCApiVersion = "2022-03-10"
            $sameNodeNames = [System.Collections.ArrayList]::new()
	        $msg = "Verifying subscription ID : {0}, Resource Group: {1}, Node Names {2}" -f $SubscriptionId, $ArcResourceGroupName, ($NodeNames -join ',')
            Log-Info  $msg
            forEach ($clusNode in $NodeNames)
            {
                $machineResourceId = "/Subscriptions/" + $SubscriptionId + "/resourceGroups/" + $ArcResourceGroupName + "/providers/Microsoft.HybridCompute/machines/" + $clusNode
                $arcMachineResource = Get-AzResource -ResourceId $machineResourceId -ApiVersion $HCApiVersion -ErrorAction Ignore
                if ($Null -ne $arcMachineResource)
                {
                    $sameNodeNames.Add($clusNode) | Out-Null
                }
            }
            if ($sameNodeNames.Count -gt 0)
            {
                $sameNodeNamesAsList = $sameNodeNames -join ","
                $detail = $lanTxt.ArcMachineAlreadyExistsInResourceGroupError -f $sameNodeNamesAsList, $ArcResourceGroupName
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }
            else
            {
                $detail = $lanTxt.ArcMachineNotFound -f $ArcResourceGroupName
                $status = 'SUCCESS'
                Log-Info $detail
            }
        }
        $params = @{
            Name               = 'AzStackHci_ArcIntegration_ResourceGroup_Check'
            Title              = 'Test ARC ResourceGroup'
            DisplayName        = "Test ARC ResourceGroup $ArcResourceGroupName"
            Severity           = $severity
            Description        = 'Checking ARC ResourceGroup clean'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "$SubscriptionId/$ArcResourceGroupName/$($NodeNames -join ',')"
            TargetResourceName = $ArcResourceGroupName
            TargetResourceType = 'ResourceGroup'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = $ENV:COMPUTERNAME
                Resource  = 'ARC ResourceGroup'
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    catch
    {
        throw ("Error validating ARC Resource Group : {0}" -f $_.Exception)
    }
}

function Test-ArcAgentNotConnectedToDifferentResource
{
    param
    (
        [string]
        $SubscriptionId,
        [string]
        $ArcResourceGroupName,
        [string[]]
        $NodeNames,
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession
    )
    try
    {
        $severity = 'CRITICAL'
        #TODO:check if the cmdlet is there, if it is not there, it means it is a different machine, we will fail the test
        $hciRegCmdlet =  Get-Command Get-AzureStackHCI -Type Cmdlet -ErrorAction Ignore
        if($null -eq $hciRegCmdlet)
        {
            # If Get-AzureStackHCI, is not found, fail validation, indicating, validation can only run on HCI OS
            $detail = $lanTxt.ArcValidationNotSupported
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        elseif ($(Get-AzureStackHCI).RegistrationStatus -ne "NotYet")
        {
            # Validation can only be done on un-registred cluster, when run on any other registration state, we will skip the validation
            $detail = $lanTxt.ClusterAlreadyRegistered
            $status = 'SUCCESS'
            Log-Info $detail
        }
        elseif ($null -eq $PSSession)
        {
            $detail = $lanTxt.SessionNotProvided
            $status = 'SUCCESS'
            Log-Info $detail
        }
        else
        {
            $NodesAlreadyArcEnabledDifferentResource = [System.Collections.ArrayList]::new()
            foreach ($nodeSession in $PSSession)
            {
                try
                {
                    Microsoft.PowerShell.Core\Invoke-Command -Session $nodeSession -ErrorAction Stop -ArgumentList $lanTxt.ArcAgentExePath -ScriptBlock {
                        if(Test-Path -Path $args[0])
                        {
                            $arcAgentStatus = Invoke-Expression -Command "& 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' show -j"

                            # Parsing the status received from Arc agent
                            $arcAgentStatusParsed = $arcAgentStatus | ConvertFrom-Json

                            # Throw an error if the node is Arc enabled to a different resource group or subscription id
                            # Agent can be is "Connected"  or disconnected state. If the resource name property on the agent is empty, that means, it is cleanly disconnected , and just the exe exists
                            # If the resourceName exists and agent is in "Disconnected" state, indicates agent has temporary connectivity issues to the cloud
                            if(-not ([string]::IsNullOrEmpty($arcAgentStatusParsed.resourceName)) -And (($arcAgentStatusParsed.subscriptionId -ne $Using:SubscriptionId) -or ($arcAgentStatusParsed.resourceGroup -ne $Using:ArcResourceGroupName)))
                            {
                                $differentResourceExceptionMessage = ("{0}:  Subscription Id: {1}, Resource Group: {2} are the current parameters to which the arc agent is connected. Expected Subscription : {3} and Expected Resource Group : {4}" -f $Using:nodeSession.ComputerName, $arcAgentStatusParsed.subscriptionId, $arcAgentStatusParsed.resourceGroup, $SubscriptionId, $ArcResourceGroupName)
                                throw $differentResourceExceptionMessage
                            }
                        }
                    }
                }
                catch
                {
                    if(($null -ne $_.Exception.Message) -and $_.Exception.Message.Contains($nodeSession.ComputerName) -and $_.Exception.Message.Contains("Subscription Id") -and $_.Exception.Message.Contains("Resource Group"))
                    {
                        $NodesAlreadyArcEnabledDifferentResource.Add($_.Exception.Message) | Out-Null
                    }
                    else
                    {
                        throw ("Error verifying Arc registration state for node: {0} with exception: {1}" -f $nodeSession.ComputerName, $_.Exception.Message)
                    }
                }
            }

            if($NodesAlreadyArcEnabledDifferentResource.Length -gt 0)
            {
                $NodesAlreadyArcEnabledDifferentResource = $NodesAlreadyArcEnabledDifferentResource -join "`n"
                $detail = $lanTxt.ArcAlreadyEnabledInADifferentResourceError -f $NodesAlreadyArcEnabledDifferentResource
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }
            else
            {
                $detail = $lanTxt.ArcNotEnabledInADifferentResource
                $status = 'SUCCESS'
                Log-Info $detail
            }
        }
        $params = @{
            Name               = 'AzStackHci_ArcIntegration_ArcMachinesState_Check'
            Title              = 'Test Arc for servers machines state'
            DisplayName        = "Test Arc for servers machines state $($NodeNames -join ',')"
            Severity           = $severity
            Description        = 'Check if Arc for servers machines are already connected to a different subscription id or resource group'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "$SubscriptionId/$ArcResourceGroupName/$($NodeNames -join ',')"
            TargetResourceName = $($NodeNames -join ',')
            TargetResourceType = 'Arc for Servers'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = $ENV:COMPUTERNAME
                Resource  = 'Arc for Servers'
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    catch
    {
        throw ("Exception while checking Nodes Arc connection state: {0}" -f $_.Exception.Message)
    }
}

function Test-IsRegionValid
{
    [CmdletBinding()]
    param (
        [string]
        $Region
    )
    try
    {
        $severity = 'CRITICAL'
        Import-Module -Name Az.Resources -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
        if(!$(Get-AzContext))
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        elseif ([string]::IsNullOrEmpty($Region))
        {
            $detail = $lanTxt.RegionRequired
            $status = 'SUCCESS'
            Log-Info $detail
        }
        else
        {
            $Region = Normalize-RegionName -Region $Region
            $locations = Retry-Command -ScriptBlock { (Get-AzResourceProvider -ProviderNamespace Microsoft.AzureStackHCI).Where{($_.ResourceTypes.ResourceTypeName -eq 'clusters' -and $_.RegistrationState -eq 'Registered')}.Locations } -RetryIfNullOutput $true
            Log-Info ("RP supported regions : $locations")
            $locations | foreach {
                $regionName = Normalize-RegionName -Region $_
                if ($regionName -eq $Region)
                {
                    # Supported region
                    $detail = $lanTxt.RegionVerified
                    $status = 'SUCCESS'
                    Log-Info $detail
                }
            }

            if($status -ne 'SUCCESS')
            {
                $detail = $lanTxt.RegionNotVerified -f $Region
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }

            $params = @{
                Name               = 'AzStackHci_ArcIntegration_Region_Check'
                Title              = 'Verify Azure Region'
                DisplayName        = "Test Arc for servers machines state $($NodeNames -join ',')"
                Severity           = $severity
                Description        = 'Checking Azure Region'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = $Region
                TargetResourceName = $Region
                TargetResourceType = 'Azure Region'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $ENV:COMPUTERNAME
                    Resource  = 'Azure Region'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch
    {
        throw ("Exception while validating Region : {0}" -f $_.Exception)
    }
}

function Test-ResourceGroupLimit
{
    [CmdletBinding()]
    param (
        [string]
        $SubscriptionId,
        [string]
        $ArcResourceGroupName,
        [string]
        $RegistrationResourceGroupName
    )
    try
    {
        $severity = 'CRITICAL'
        $azureContext = Get-AzContext
        if(!$azureContext)
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        else
        {
            $newRGCount = 0
            $hciRG = Get-AzResourceGroup -Name $RegistrationResourceGroupName -ErrorAction SilentlyContinue
            if([string]::IsNullOrEmpty($hciRG))
            {
                $newRGCount++
            }

            if($ArcResourceGroupName -ne $RegistrationResourceGroupName)
            {
                $arcRG = Get-AzResourceGroup -Name $ArcResourceGroupName -ErrorAction SilentlyContinue
                if([string]::IsNullOrEmpty($arcRG))
                {
                    $newRGCount++
                }
            }

            $totalRGCount = (Get-AzResourceGroup -ErrorAction SilentlyContinue).Count
            if(($totalRGCount + $newRGCount) -gt 980)
            {
                $detail = $lanTxt.ResourceGroupLimitReached -f $SubscriptionId, ($totalRGCount + $newRGCount - 980)
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }
            else
            {
                $detail = $lanTxt.ResourceGroupLimitCheckSucceeded -f $SubscriptionId
                $status = 'SUCCESS'
                Log-Info $detail
            }

            $params = @{
                Name               = 'AzStackHci_ArcIntegration_ResourceGroupLimit_Check'
                Title              = 'Verify Resource group limit'
                DisplayName        = 'Verify Resource group limit'
                Severity           = $severity
                Description        = 'Checking Azure Resource group limit'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = "$SubscriptionId/$ArcResourceGroupName"
                TargetResourceName = $ArcResourceGroupName
                TargetResourceType = 'ResourceGroup'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $SubscriptionId
                    Resource  = ($totalRGCount + $newRGCount)
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch
    {
        throw ("Exception while verifying resource group limit : {0}" -f $_.Exception)
    }
}

function Test-ResourceCountLimit
{
    [CmdletBinding()]
    param (
        [string]
        $SubscriptionId,
        [string]
        $RegistrationResourceGroupName
    )
    try
    {
        $severity = 'CRITICAL'
        $azureContext = Get-AzContext
        if(!$azureContext)
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        else
        {
            try
            {
                $resourcesInHCIRg = Get-AzResource -ResourceGroupName $RegistrationResourceGroupName -ResourceType "Microsoft.AzureStackHCI/clusters" -ErrorAction Stop
                if($resourcesInHCIRg.Count -ge 800)
                {
                    $detail = $lanTxt.ResourceLimitReached -f $RegistrationResourceGroupName, $SubscriptionId
                    $status = 'FAILURE'
                    Log-Info $detail -Type $severity
                }
                else
                {
                    $detail = $lanTxt.ResourceLimitCheckSucceeded -f $RegistrationResourceGroupName
                    $status = 'SUCCESS'
                    Log-Info $detail
                }
            }
            catch
            {
                $detail = $lanTxt.MissingPermissions -f "Verify Resource count limit in Registration resource group"
                $status = 'SUCCESS'
                Log-Info $detail
            }

            $params = @{
                Name               = 'AzStackHci_ArcIntegration_ResourceLimit_Check'
                Title              = 'Verify Resource limit'
                DisplayName        = "Verify Resource limit in $RegistrationResourceGroupName"
                Severity           = $severity
                Description        = 'Checking Azure Stack HCI Cluster Resource limit in Registration resource group'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = "$SubscriptionId/$RegistrationResourceGroupName"
                TargetResourceName = $RegistrationResourceGroupName
                TargetResourceType = 'Cluster'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $RegistrationResourceGroupName
                    Resource  = $resourcesInHCIRg.Count
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch
    {
        throw ("Exception while verifying azure stack hci resource count limit : {0}" -f $_.Exception)
    }
}

function Test-RoleAssignmentCountLimit
{
    [CmdletBinding()]
    param (
        [string]
        $SubscriptionId
    )
    try
    {
        $severity = 'CRITICAL'
        $azureContext = Get-AzContext
        if(!$azureContext)
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        else
        {
            try
            {
                $roleAssignments = Get-AzRoleAssignment -Scope "/subscriptions/$SubscriptionId" -ErrorAction Stop
                if($roleAssignments.Count -ge 4000)
                {
                    $detail = $lanTxt.RoleAssignmentLimitReached -f $SubscriptionId
                    $status = 'FAILURE'
                    Log-Info $detail -Type $severity
                }
                else
                {
                    $detail = $lanTxt.RoleAssignmentLimitSuccessfullyVerified -f $SubscriptionId
                    $status = 'SUCCESS'
                    Log-Info $detail
                }
            }
            catch
            {
                $detail = $lanTxt.MissingPermissions -f "Verify Role Assignment count"
                $status = 'SUCCESS'
                Log-Info $detail
            }

            $params = @{
                Name               = 'AzStackHci_ArcIntegration_RoleAssignmentLimit_Check'
                Title              = 'Verify Role Assignment Limit'
                DisplayName        = "Verify Role Assignment Limit in $SubscriptionId"
                Severity           = $severity
                Description        = 'Checking Role Assignment limit in Subscription'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = $azureContext.Subscription.Id
                TargetResourceName = $azureContext.Subscription.Name
                TargetResourceType = 'Azure Subscription'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $azureContext.Subscription.Name
                    Resource  = $roleAssignments.Count
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch
    {
        throw ("Exception while verifying azure stack hci role assignment count limit : {0}" -f $_.Exception)
    }
}

function Test-ExistingHCIResource {
    [CmdletBinding()]
    param (
        [string]
        $SubscriptionId,
        [string]
        $RegistrationResourceGroupName,
        [string]
        $RegistrationResourceName
    )
    try
    {
        $severity = 'CRITICAL'
        #TODO:check if the cmdlet is there, if it is not there, it means it is a different machine, we will fail the test
        $hciRegCmdlet =  Get-Command Get-AzureStackHCI -Type Cmdlet -ErrorAction Ignore
        if($null -eq $hciRegCmdlet)
        {
            # If Get-AzureStackHCI, is not found, fail validation, indicating, validation can only run on HCI OS
            $detail = $lanTxt.ArcValidationNotSupported
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        elseif ($(Get-AzureStackHCI).RegistrationStatus -ne "NotYet")
        {
            # Validation can only be done on un-registred cluster, when run on any other registration state, we will skip the validation
            $detail = $lanTxt.ClusterAlreadyRegistered
            $status = 'SUCCESS'
            Log-Info $detail
        }
        elseif (!$(Get-AzContext))
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        elseif ([string]::IsNullOrEmpty($RegistrationResourceName))
        {
            $detail = $lanTxt.ResourceNameEmpty
            $status = 'SUCCESS'
            Log-Info $detail
        }
        else
        {
            $RPAPIVersion = "2022-12-01"
            Log-Info ($lanTxt.VerifyingIfHCIResourceExistsInHCIRG -f $RegistrationResourceName, $SubscriptionId, $RegistrationResourceGroupName)
            $hciClusterResourceId = "/Subscriptions/" + $SubscriptionId + "/resourceGroups/" + $RegistrationResourceGroupName + "/providers/Microsoft.AzureStackHCI/clusters/" + $RegistrationResourceName
            $hciClusterResource = Get-AzResource -ResourceId $hciClusterResourceId -ApiVersion $RPAPIVersion -ErrorAction Ignore

            if ($null -ne $hciClusterResource)
            {
                $detail = $lanTxt.HCIClusterResourceAlreadyExistsError -f $RegistrationResourceName, $RegistrationResourceGroupName
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }
            else
            {
                $detail = $lanTxt.HCIClusterNotFound -f $RegistrationResourceName, $RegistrationResourceGroupName
                $status = 'SUCCESS'
                Log-Info $detail
            }
        }

        $params = @{
            Name               = 'AzStackHci_HCI_ResourceGroup_Check'
            Title              = 'Test HCI Resource Group'
            DisplayName        = 'Test HCI Resource Group'
            Severity           = $severity
            Description        = 'Checking HCI Resource Group clean'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "$SubscriptionId/$RegistrationResourceGroupName"
            TargetResourceName = $RegistrationResourceGroupName
            TargetResourceType = 'ResourceGroup'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = $SubscriptionId
                Resource  = $RegistrationResourceGroupName
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    catch
    {
        throw ("Error validating HCI Resource Group : {0}" -f $_.Exception)
    }
}

function Normalize-RegionName{
    param(
        [string] $Region
        )
        $regionName = $Region -replace '\s',''
        $regionName = $regionName.ToLower()
        return $regionName
}

function Retry-Command {
    param (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [scriptblock] $ScriptBlock,
        [int]  $Attempts                   = 8,
        [int]  $MinWaitTimeInSeconds       = 5,
        [int]  $MaxWaitTimeInSeconds       = 60,
        [int]  $BaseBackoffTimeInSeconds   = 2,
        [bool] $RetryIfNullOutput          = $true
        )

    $attempt = 0
    $completed = $false
    $result = $null

    if($MaxWaitTimeInSeconds -lt $MinWaitTimeInSeconds)
    {
        throw "MaxWaitTimeInSeconds($MaxWaitTimeInSeconds) is less than MinWaitTimeInSeconds($MinWaitTimeInSeconds)"
    }

    while (-not $completed) {
        try
        {
            $attempt = $attempt + 1
            $result = Invoke-Command -ScriptBlock $ScriptBlock

            if($RetryIfNullOutput)
            {
                if($result -ne $null)
                {
                    $completed = $true
                }
                else
                {
                    throw "Null result received."
                }
            }
            else
            {
                $completed = $true
            }
        }
        catch
        {
            $exception = $_.Exception

            if([int]$exception.ErrorCode -eq [int][system.net.httpstatuscode]::Forbidden)
            {
                throw
            }
            else
            {
                if ($attempt -ge $Attempts)
                {
                    throw
                }
                else
                {
                    $secondsDelay = $MinWaitTimeInSeconds + [int]([Math]::Pow($BaseBackoffTimeInSeconds,($attempt-1)))

                    if($secondsDelay -gt $MaxWaitTimeInSeconds)
                    {
                        $secondsDelay = $MaxWaitTimeInSeconds
                    }

                    Start-Sleep $secondsDelay
                }
            }
        }
    }

    return $result
}

function Test-MandatoryRPRegistration
{
    [CmdletBinding()]
    param (
        [string]
        $SubscriptionId
    )
    try
    {
        $severity = 'CRITICAL'
        Import-Module -Name Az.Resources -Verbose:$false -ErrorAction SilentlyContinue | Out-Null
        $azureContext = Get-AzContext
        if(!$azureContext)
        {
            $detail = $lanTxt.AzureContextRequired
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }
        else
        {
            # Check Mandatory Resource Providers registration (Azure and Winfield)
            $listOfMandatoryRPsNeeded = @("Microsoft.GuestConfiguration", "Microsoft.HybridCompute", "Microsoft.HybridConnectivity", "Microsoft.ResourceConnector", "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation", "Microsoft.HybridContainerService", "Microsoft.AzureStackHCI")
            # Check Mandatory Resource Providers registration (Azure only)
            if (-not($azureContext.Environment.Name -eq "Azure.local")) {
                $listOfMandatoryRPsNeeded += "Microsoft.Attestation"
            }
            $registeredProviders = @()
            $unregisteredProviders = @()
            $registeredProviders = Get-AzResourceProvider | Where-Object { $_.RegistrationState -eq "Registered" } | Select ProviderNamespace
            foreach ($providerNameSpace in $listOfMandatoryRPsNeeded)
            {
                $isRPRegistered = $registeredProviders | Where-Object { $_.ProviderNamespace -eq $providerNameSpace } | ForEach-Object { $true } | Select-Object -First 1
                if (-not $isRPRegistered)
                {
                    $unregisteredProviders += $providerNameSpace
                }
            }
            if ($unregisteredProviders.Count -eq 0)
            {
                $detail = $lanTxt.ResourceProvidersAlreadyRegistered -f $SubscriptionId
                $status = 'SUCCESS'
                Log-Info $detail
            }
            else
            {
                $detail = $lanTxt.MandatoryRPRegistrationsNotPresent -f ($unregisteredProviders -join ','), $SubscriptionId
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }
            $params = @{
                Name               = 'AzStackHci_ArcIntegration_MandatoryRPRegistration_Check'
                Title              = 'Test RP registrations are present in the subscription'
                DisplayName        = "Test RP registrations are present in the subscription"
                Severity           = $severity
                Description        = 'Check if all Resource Providers are registered in the subscription'
                Tags               = @{}
                Remediation        = 'https://aka.ms/hci-envch'
                TargetResourceID   = $azureContext.Subscription.Id
                TargetResourceName = $azureContext.Subscription.Name
                TargetResourceType = 'Azure Subscription'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $azureContext.Subscription.Id
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch
    {
        throw ("Exception while checking mandatory RP registration: {0}" -f $_.Exception.Message)
    }
}

function Test-AzureStackHCISubscriptionState
{
    <#
    .SYNOPSIS
        Test Azure Stack HCI Subscription State
    .DESCRIPTION
        Test Azure Stack HCI Subscription State is Active
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try
    {
        Log-Info "Starting Test-AzureStackHCISubscriptionState Execution"
        $remoteOutput = @()

        $sb = {
            # Check if the required cmdlet exists before attempting to use it
            $cmdletExists = Get-Command Get-AzureStackHCISubscriptionStatus -ErrorAction SilentlyContinue
            if (-not $cmdletExists) {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    SubscriptionFound = $false
                    Error = "Get-AzureStackHCISubscriptionStatus cmdlet not found on $ENV:COMPUTERNAME"
                    AllSubscriptions = $null
                }
            }

            try {
                $subscriptions = @()
                $subscriptions = Get-AzureStackHCISubscriptionStatus -ErrorAction Stop

                $azureStackHCISubscription = $subscriptions | Where-Object SubscriptionName -like "Azure Stack HCI*"

                if ($null -eq $azureStackHCISubscription -or @($azureStackHCISubscription).Count -eq 0)
                {
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        SubscriptionFound = $false
                        AllSubscriptions = $subscriptions
                    }
                }
                else
                {
                    return New-Object PSObject -Property @{
                        ComputerName = $ENV:COMPUTERNAME
                        SubscriptionFound = $true
                        SubscriptionStatus = $azureStackHCISubscription.Status.ToString()
                        AllSubscriptions = $subscriptions
                    }
                }
            }
            catch {
                return New-Object PSObject -Property @{
                    ComputerName = $ENV:COMPUTERNAME
                    SubscriptionFound = $false
                    Error = "Error executing Get-AzureStackHCISubscriptionStatus: $($_.Exception.Message)"
                    AllSubscriptions = $null
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
            # Log the full subscription data returned from Get-AzureStackHCISubscriptionStatus
            if ($output.AllSubscriptions) {
                Log-Info "Full subscription data from Get-AzureStackHCISubscriptionStatus on $($output.ComputerName):"
                if ($output.AllSubscriptions -is [array] -and $output.AllSubscriptions.Count -gt 0) {
                    foreach ($sub in $output.AllSubscriptions) {
                        Log-Info "  - SubscriptionName: '$($sub.SubscriptionName)', Status: '$($sub.Status)'"
                    }
                } elseif ($output.AllSubscriptions) {
                    Log-Info "  - SubscriptionName: '$($output.AllSubscriptions.SubscriptionName)', Status: '$($output.AllSubscriptions.Status)'"
                } else {
                    Log-Info "  - No subscription data found"
                }
            } else {
                Log-Info "No AllSubscriptions data returned from $($output.ComputerName)"
            }

            # Handle cases where cmdlet doesn't exist or failed with error
            if ($output.Error) {
                $status = 'FAILURE'
                $detail = "Error checking subscription status on {0}: {1}" -f $output.ComputerName, $output.Error
                Log-Info $detail -Type CRITICAL
            }
            elseif ($output.SubscriptionFound -eq $false)
            {
                $status = 'FAILURE'
                $detail = $luTxt.AzureStackHCISubscriptionNotFound -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            elseif ($output.SubscriptionStatus -ne 'Active')
            {
                $status = 'FAILURE'
                $detail = $luTxt.AzureStackHCISubscriptionNotActive -f $output.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            else
            {
                $status = 'SUCCESS'
                $detail = $luTxt.AzureStackHCISubscriptionActive -f $output.ComputerName
                Log-Info $detail
            }

            $params = @{
                Name               = 'AzStackHci_Subscription_State'
                Title              = 'Test Azure Stack HCI Subscription State'
                DisplayName        = 'Test Azure Stack HCI Subscription State'
                Severity           = 'CRITICAL'
                Description        = 'Checking Azure Stack HCI Subscription is Active'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = 'AzureStackHCISubscription'
                TargetResourceName = 'AzureStackHCISubscription'
                TargetResourceType = 'Subscription'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $ENV:COMPUTERNAME
                    Resource  = 'Azure Stack HCI Subscription'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        Log-Info "Test-AzureStackHCISubscriptionState function completed successfully"
        return $instanceResults
    }
    catch
    {
        $errorMessage = "Test-AzureStackHCISubscriptionState function failed with error: $($_.Exception.Message)"
        Log-Info $errorMessage -Type CRITICAL
        throw $_
    }
}

Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBdklIakkQr7Ikc
# h3hgWKWQF8rLuhDf8yeuAjr+CHY2iqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIC9bY4Ib
# pPc67sejBGOEutzajuAXzced5kk5kLRzqx0zMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAhfC5PR9eic8kGvW6kk3Sh5BZtv+6WWHyi3S4vNJ0
# j9UwcJEnOu+11JyQT+ClYi6tQTsda9+YTzlUWKhqDcA8wTRGqs65Jsj1bZnfvvFQ
# PaCndqg4cu4u5br3f0MF4AzsL7y+ZzNQVGOMcXEsjl7doOyc8Hm3JfbploJuzNlJ
# YCG2n/u1J1VW+aVQ2on9jS8CEiVTvHZZQ18LF8/F0Mz46SR+gKOjWnlk+TZ+RYF/
# dmOW13Td31EtHc/7CohROz8nunK6JqiaDYIql4r276/xnVnutnWvLoVfuIcO1V71
# H3qzr/B+tuw0c3fgBk6eLMmOQ7xX2bnpPNWcrF0MuC6DzaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBz5Bv/fdvItADwvCmcS0JIZZRLexbLPCBd1UvK
# aH5MvAIGaedcMrcyGBMyMDI2MDUwMzE0MzEwOS43NjNaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBubOZGn1QzeqJci62mA4brNPST
# YIM3eyO2MP65x+zjYzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHIOI/Q/
# kFftYA+M2OY+1Bx3ajBD6/WDAtPT2vFkv25SMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIruwBQ/007mqEAAQAAAiswIgQg4bigwWvF
# x04J9mIfST2NDYTqeHpS2VK/0b1JF/5aWO0wDQYJKoZIhvcNAQELBQAEggIAQ4aN
# hXDVAMfWQa5XW1C47EHd8Bo+QP/15htPhDYt+Z8r4l1DsuWLGAOs2oZ4+T/v1YTP
# p/p0BSuDhJOVcj5coK36WKRm8Zsma+sFpA0Hd6F2oO45tebJ8LUCmqPMmREqGD9Q
# US9bKGesCWPYM9STXxRRmryH43YRM9fWa14ZCg8QTd7NR51Cq0NPsLETnvyGQ0D2
# uCXtHSRRPXl3QodWo4nPuavFfQ7M8ztrQHiXF+uJ94xlR1qxnPtlOqRJW1eWnxVl
# fUBFUM1Y+SEg3+CzMWtKnjB8uIa7V2BFHVmP5aUwhpntBhkg383OLNqsJS6Zk8/P
# NQAq4kC9O3r32+qYD09iQDctDtksRcw2DHVyGenbuZZYz+RCZkCWA7TveujAGYOa
# gWSg32x6VYxto6cDvfx8e9qzy9b1jR8MEyYJ2NdkiZ95i/gYMYQHNZlTG4toJZdz
# PlMeXdCGIOcJhT+UGWFHec9fBc4w4EAY7Hhejdw8mNnb0LQe9td2In/1o0cwXFtm
# pJ9wKnZ29kQXvK1jYMKYehHkeU+kYMYRHS/E7DucpksPwHXKTvgndtR0TTBtMUqW
# 7tJoUE01gUdpAEWhAODgyZQY3bIav3+ToafmMblZ5Vz+y3KoS9KtQtOrR8yQOMKw
# VlctMhE8ZIVtxT3YjRQS8jkFypW+zixAUVuNyFc=
# SIG # End signature block
