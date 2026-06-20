##------------------------------------------------------------------
##  <copyright file="StandaloneObservabilityHelper.psm1" company="Microsoft">
##    Copyright (C) Microsoft. All rights reserved.
##  </copyright>
##------------------------------------------------------------------

Import-Module "$PSScriptRoot\GMATenantJsonHelper.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\StandaloneObservabilityConstants.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\ExtensionHelper.psm1" -Force -DisableNameChecking

function Install-AzureConnectedMachineAgent
{
    param (
        [Parameter(Mandatory)]
        [System.String] $ResourceName,

        [Parameter(Mandatory)]
        [System.String] $ResourceGroupName,

        [Parameter(Mandatory)]
        [System.String] $TenantId,

        [Parameter(Mandatory)]
        [System.String] $RegionName,

        [Parameter(Mandatory)]
        [System.String] $SubscriptionId,

        [Parameter(Mandatory)]
        [System.String] $Cloud,

        [Parameter(Mandatory)]
        [System.String] $StampId,

        [Parameter(Mandatory = $true, ParameterSetName = "ServicePrincipal")]
        [PSCredential] $RegistrationSPCredential,

        [Parameter(Mandatory = $true, ParameterSetName = "DefaultSet")]
        [System.String] $AccessToken
    )

    ## Run connect command
	$timestamp = [DateTime]::Now.ToString("yyyyMMdd-HHmmss")
    $logPath = Get-LogFolderPath
    $logFile = Join-Path -Path $logPath -ChildPath "ArcForServerInstall_${timestamp}.txt"

    $AgentWebLink = $PipelineConstants.ArcForServerAgentWebLink
    $AgentMsiPath = Join-Path -Path $logPath -ChildPath $PipelineConstants.ArcForServerMsiFileName
    $AgentExePath = $PipelineConstants.ArcForServerExePath

    Write-Host "Starting Arc-for-server agent install AgentWebLink: $AgentWebLink  AgentMsiPath: $AgentMsiPath  AgentExePath: $AgentExePath  logs: $logFile"
    if ($PSCmdlet.ParameterSetName -eq "ServicePrincipal") {
        $regSpNetworkCreds = $RegistrationSPCredential.GetNetworkCredential()
        Write-Host "Creating ArcContext for SPN: $($regSpNetworkCreds.UserName)"
        $arcContext = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcContextSpn
        $arcContext.SubscriptionId = $SubscriptionId
        $arcContext.ResourceGroup = $ResourceGroupName
        $arcContext.Location = $RegionName
        $arcContext.Cloud = $Cloud
        $arcContext.ResourceName = $ResourceName
        $arcContext.TenantId = $TenantId
        $arcContext.ServicePrincipalId = $regSpNetworkCreds.UserName
        $arcContext.ServicePrincipalSecret = $regSpNetworkCreds.Password
    }
    else {
        Write-Host "Creating ArcContext with AccessToken Length: $($AccessToken.Length)"
        $arcContext = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcContext
        $arcContext.SubscriptionId = $SubscriptionId
        $arcContext.ResourceGroup = $ResourceGroupName
        $arcContext.Location = $RegionName
        $arcContext.Cloud = $Cloud
        $arcContext.ResourceName = $ResourceName
        $arcContext.TenantId = $TenantId
        $arcContext.AccessToken = $AccessToken
    }

    $arcAgent = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcAgent
    $res = $arcAgent.Onboard($arcContext, $AgentWebLink, $AgentMsiPath, $logFile, $AgentExePath)

    Write-Host "Arc-for-server agent install $env:COMPUTERNAME. Status $res"

    if($res -eq $true) {
        Write-Host -ForegroundColor yellow "To view your onboarded server(s), navigate to https://ms.portal.azure.com/#blade/Microsoft_Azure_HybridCompute/AzureArcCenterBlade/servers"
    }
    else {
        throw "Hybrid agent connection failed. LogPath: $logFile"
    }
}

function Remove-AzureConnectedMachineAgent
{
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "ServicePrincipal")]
        [PSCredential] $RegistrationSPCredential,

        [Parameter(Mandatory = $true, ParameterSetName = "DefaultSet")]
        [System.String] $AccessToken
    )

    $timestamp = [DateTime]::Now.ToString("yyyyMMdd-HHmmss")
    $logPath = Get-LogFolderPath
    $logFile = Join-Path -Path $logPath -ChildPath "ArcForServerUninstall_${timestamp}.txt"

    $AgentExePath = $PipelineConstants.ArcForServerExePath
    $AgentMsiPath = Join-Path -Path $logPath -ChildPath $PipelineConstants.ArcForServerMsiFileName

    if ($PSCmdlet.ParameterSetName -eq "ServicePrincipal") {
        $regSpNetworkCreds = $RegistrationSPCredential.GetNetworkCredential()
        Write-Host "Creating ArcContext for SPN: $($regSpNetworkCreds.UserName)"
        $arcContext = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcContextSpn
        $arcContext = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcContextSpn
        $arcContext.ServicePrincipalId = $regSpNetworkCreds.UserName
        $arcContext.ServicePrincipalSecret = $regSpNetworkCreds.Password
    }
    else {
        Write-Host "Creating ArcContext with AccessToken Length: $($AccessToken.Length)"
        $arcContext = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcContext
        $arcContext.AccessToken = $AccessToken
    }

    $arcAgent = New-Object Microsoft.AzureStack.Observability.ObservabilityCommon.ArcForServer.ArcAgent
    $res = $arcAgent.Offboard($arcContext, $logFile, $AgentExePath, $AgentMsiPath)
    if($res -eq $true) {
        Write-Host -ForegroundColor yellow "ArcAgent uninstall succeeded"
    }
    else {
        throw "ArcAgent uninstall failed. LogPath: $logFile"
    }
}

function Get-GmaStateFolders {
    param (
        [Parameter(Mandatory)]
        [System.String] $ObsRootFolderPath
    )
    
    $gmaCacheDirectories = [ordered] @{
        RuntimeSettings = "$ObsRootFolderPath\RuntimeSettings"
    }

    return $gmaCacheDirectories

}

function New-GmaStateFolders {
    param (
        [Parameter(Mandatory)]
        [System.String] $ObsRootFolderPath
    )
    
    $gmaCacheDirectories = Get-GmaStateFolders -ObsRootFolderPath $ObsRootFolderPath

    foreach ($directory in $gmaCacheDirectories.Values) {
        if (-not (Test-Path $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force -Verbose *>> $temp
        }
    }
}

function Test-IsArcAgentConnected() {
    [CmdletBinding()]
    param (
    )

    Write-Host "Checking if Arc connection already exists..."
    try {
        $arcAgentInfo = @{}
        $arcAgentExePath = $PipelineConstants.ArcForServerExePath
        $arcshow = & $arcAgentExePath show
        $arcshow | ForEach-Object {
            $arcProperty = $_.split(':')
            $arcAgentInfo[$arcProperty[0].trim()] =  if ($arcProperty.Count -eq 2) { $arcProperty[1].trim() } else {""}
        }

        Write-Host "Checking Agent connection status: $($arcAgentInfo.'Agent Status')"
        return ($arcAgentInfo.'Agent Status' -eq "Connected")
    }
    catch {
        Write-Host "Error $_ checking if Arc Agent is connected"
        return $false
    }
}

function Test-IsAzure() {
    [CmdletBinding()]
    param (
    )

    Write-Host "Checking if this is an Azure virtual machine"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://169.254.169.254/metadata/instance/compute?api-version=2019-06-01" -Headers @{Metadata = "true"} -TimeoutSec 1 -ErrorAction SilentlyContinue
    }
    catch {
        Write-Verbose "Error $_ checking if we are in Azure"
        return $false
    }
    if ($null -ne $response -and $response.StatusCode -eq 200) {
        Write-Verbose "Azure check indicates that we are in Azure"
        return $true
    }
    return $false
}

function Set-StampGuid() {
    [CmdletBinding()]
    param (
    )

    $StampGuid = $env:STAMP_GUID
    Write-Host "Checking if STAMP_GUID environment is empty: $StampGuid"
    if ($null -eq $env:STAMP_GUID) {
        $StampGuid = (Get-CimInstance -Class Win32_ComputerSystemProduct).UUID
        Write-Host "$functionName Setting the STAMP_GUID variable to $StampGuid"
        $env:STAMP_GUID = $StampGuid
    }

    return $StampGuid
}

function Set-HandlerEnvInfo {
    param (
        [Parameter(Mandatory)]
        [System.String] $ObsRootFolderPath,

        [Parameter(Mandatory)]
        [System.String] $CloudName,

        [Parameter(Mandatory)]
        [System.String] $RegionName
    )

    <#
    Sample HandlerEnvironment.json content:
    [
        {
            "handlerEnvironment": {
                "configFolder": "C:\\Packages\\Plugins\\Microsoft.AzureStack.Observability.Observability\\0.0.0.4\\RuntimeSettings",
                "deploymentid": "",
                "heartbeatFile": "C:\\Packages\\Plugins\\Microsoft.AzureStack.Observability.Observability\\0.0.0.4\\status\\HeartBeat.Json",
                "hostResolverAddress": "",
                "instance": "",
                "logFolder": "C:\\ProgramData\\GuestConfig\\extension_logs\\Microsoft.AzureStack.Observability.Observability",
                "rolename": "",
                "statusFolder": "C:\\Packages\\Plugins\\Microsoft.AzureStack.Observability.Observability\\0.0.0.4\\status"
            },
            "name": "Microsoft.RecoveryServices.Test.AzureSiteRecovery",
            "version": "1"
        }
    ]
    #>

    $handlerEnvironment = @{}
    $handlerEnvironment.configFolder = "$ObsRootFolderPath\RuntimeSettings"
    $handlerEnvironment.deploymentid = ""
    $handlerEnvironment.heartbeatFile = "$ObsRootFolderPath\HeartBeat.Json"
    $handlerEnvironment.hostResolverAddress = ""
    $handlerEnvironment.instance = ""
    $handlerEnvironment.logFolder = "$ObsRootFolderPath"
    $handlerEnvironment.rolename = ""
    $handlerEnvironment.statusFolder = "$ObsRootFolderPath"

    $jsonArray = @{}
    $jsonArray.Add("handlerEnvironment",$handlerEnvironment)
    $jsonArray.Add("name","Microsoft.AzureStack.Observability.Standalone")
    $jsonArray.Add("version","1")

    $jsonContent = ConvertTo-Json -InputObject $jsonArray

    $envFile = "$global:extensionRootLocation\HandlerEnvironment.json"
    $functionName = $MyInvocation.MyCommand.Name

    Write-Host "$functionName : HandlerEnvironment.json doesn't exist at path $envFile. So creating new file"
    Set-Content -Path $envFile -Value $jsonContent

    # Set the runtime settings
    $runtimeSettingsFile = "$ObsRootFolderPath\RuntimeSettings\0.settings"

    $publicSettings = @{}
    $publicSettings.cloudName = $CloudName
    $publicSettings.deviceType = "EnvValidatorStandAlone"
    $publicSettings.region = $RegionName

    $handlerSettings = @{}
    $handlerSettings.publicSettings = $publicSettings

    $jsonArray = @{}
    $jsonArray.Add("handlerSettings",$handlerSettings)

    $runtimeSettings = @{}
    $runtimeSettings.runtimeSettings = @($jsonArray)
    $jsonContent = ConvertTo-Json -InputObject $runtimeSettings -Depth 10

    Set-Content -Path $runtimeSettingsFile -Value $jsonContent
}

function Set-StandaloneScenarioRegistry {
    [CmdletBinding()]
    Param ()

    $functionName = $MyInvocation.MyCommand.Name
    Write-Host "[$functionName] Entering."

    if (-not (Test-Path $MiscConstants.GMAScenarioRegKey.Path)) {
        Write-Host "[$functionName] Creating GMAScenario registry key at path $($MiscConstants.GMAScenarioRegKey.Path) as it does not exists."
        New-Item -Path $MiscConstants.GMAScenarioRegKey.Path -Force
    }

    if (-not ((Test-RegKeyExists -Path $MiscConstants.GMAScenarioRegKey.Path -Name $MiscConstants.GMAScenarioRegKey.Name -GetValueIfExists) -eq $MiscConstants.GMAScenarioRegKey.OneP)) {
        New-ItemProperty `
            -Path $MiscConstants.GMAScenarioRegKey.Path `
            -Name $MiscConstants.GMAScenarioRegKey.Name `
            -PropertyType $MiscConstants.GMAScenarioRegKey.PropertyType `
            -Value $MiscConstants.GMAScenarioRegKey.OneP
    }

    Write-Host "[$functionName] Exiting."
}

function Confirm-IsArcAEnvironment {
    return (Test-RegKeyExists -Path $MiscConstants.ArcARegKey.Path -Name $MiscConstants.ArcARegKey.Name -GetValueIfExists) -eq $true
 }

function Wait-ForGcsConfigSync {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$False)]
        [int] $TimeInSeconds = 60
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Host "[$functionName] Entering. TimeOut: $TimeInSeconds"

    Write-Host "[$functionName] Going to wait for GCSConfig sync $TimeInSeconds"
    Start-Sleep -Seconds $TimeInSeconds
    
    $cacheDir = Join-Path -Path $env:SystemDrive -ChildPath "GMACache\DiagnosticsCache"
    $gcsConfigFiles = Get-ChildItem -Path $cacheDir -Filter GcsConfig -Recurse
    
    if ($gcsConfigFiles.Count -eq 0)
    {
        Write-Error "[$functionName] GCSConfig files are not found. Please check the logs for further investigation."
    }

    Write-Host "[$functionName] Exiting. GCSCongfile count: $($gcsConfigFiles.Count)"
}

 function Get-TenantId
 {
     [CmdletBinding()]
     param (
         [Parameter(Mandatory=$false)]
         [ValidateSet("AzureCloud", "AzureChinaCloud", "AzureUSGovernment", "AzureStackCloud")]
         [string] $AzureEnvironment = "AzureCloud",

         [Parameter(Mandatory=$true)]
         [string] $SubscriptionId
     )

     $functionName = $MyInvocation.MyCommand.Name
     $endpoints = Get-AzureURIs -AzureEnvironment $AzureEnvironment

     $params = @{
         UseBasicParsing = $true
         ErrorAction     = 'Stop'
         Uri             = $endpoints.ARMUri.TrimEnd('/') + "/subscriptions/${SubscriptionId}?api-version=1.0"
     }
     $response = try { Invoke-WebRequest @params } catch { $_.Exception.Response }

     if ($response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
         throw "[$functionName] SubscriptionId $SubscriptionId not found"
     }

     $header   = $response.GetResponseHeader('WWW-Authenticate')
     Write-Verbose "[$functionName] $header"
     $guidPattern = "[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}"
     $tenantId = $header.Split(' ') | Where-Object { $_ -like '*authorization_uri*' } | Select-Object -First 1 | ForEach-Object { [Regex]::Matches($_, $guidPattern).Value }

     if ([string]::IsNullOrEmpty($tenantId)) {
         Write-Verbose "[$functionName] Response $($response | ConvertTo-Json -depth 5)"
         throw "[$functionName] Unable to get tenantId for SubscriptionId $SubscriptionId"
     }

     Write-Verbose "[$functionName] Retrieved tenantId $tenantId"
     return ,$tenantId

 }

 <#
 .Synopsis
    Builds graph and login endpoints for a given AzureEnvironment
 #>
 function Get-AzureURIs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateSet("AzureCloud", "AzureChinaCloud", "AzureUSGovernment", "AzureStackCloud")]
        [string]$AzureEnvironment = "AzureCloud"
    )

    $functionName = $MyInvocation.MyCommand.Name

    # Cloud-specific ARM base URI for the metadata endpoint
    # (Public vs sovereign clouds differ in management endpoint) [1](https://stackoverflow.com/questions/71772443/azure-python-sdk-connecting-to-usgov-with-cli-credentials-fails)[2](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-developer-guide)
    $armBaseByCloud = @{
        AzureCloud        = 'https://management.azure.com'
        AzureUSGovernment = 'https://management.usgovcloudapi.net'
        AzureChinaCloud   = 'https://management.chinacloudapi.cn'
        AzureStackCloud   = 'https://armmanagement.autonomous.aldo.private'
    }

    $armBase = $armBaseByCloud[$AzureEnvironment]
    $fullUri = "$armBase/metadata/endpoints?api-version=2023-01-01"

    try {
        Write-Verbose "[$functionName] GET $fullUri"
        $response = Invoke-RestMethod -Uri $fullUri -ErrorAction Stop -TimeoutSec 30
    }
    catch {
        throw "[$functionName] Failed calling $fullUri : $($_.Exception.Message)"
    }

    # Response can be either an array OR { value: [...] } (handle both)
    $items =
        if ($response -is [System.Collections.IEnumerable] -and -not ($response -is [string])) {
            $response
        }
        elseif ($response.PSObject.Properties.Name -contains 'value') {
            $response.value
        }
        else {
            @($response)
        }

    # Find the cloud entry
    $data = $items | Where-Object { $_.name -eq $AzureEnvironment } | Select-Object -First 1
    if (-not $data) {
        throw "[$functionName] Unknown environment '$AzureEnvironment' in response from $fullUri"
    }

    # Pick first audience as "management service uri" (often includes management.core.*)
    $mgmtSvc = $null
    if ($data.authentication.audiences) {
        $mgmtSvc = $data.authentication.audiences | Select-Object -First 1
    }

    $endpointProperties = @{
        GraphUri = $data.graph
        LoginUri = $data.authentication.loginEndpoint
        ManagementServiceUri = $mgmtSvc
        ARMUri = $data.resourceManager
        MsGraphUri = $data.microsoftGraphResourceId
    }

    Write-Verbose "[$functionName] $AzureEnvironment EndpointProperties: $( $endpointProperties | ConvertTo-Json -Depth 3 -Compress )"
    return $endpointProperties
}

function Test-UserIsElevated
{
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
}

function Test-ArcExtensionWatchdogIsPresent
{
    $functionName = $MyInvocation.MyCommand.Name
    Write-Host "[$functionName] Checking if TelemetryAndDiagnostics ARC extension WatchdogAgent is present."
    $watchdogPath = (Get-CimInstance Win32_Service -Filter "Name='WatchdogAgent'" -ErrorAction SilentlyContinue).PathName
    if ($watchdogPath)
    {
        if ($watchdogPath.Contains("\Nugets\0.0.0.1\"))
        {
            Write-Host "[$functionName] Standalone Observability WatchdogAgent detected at path $watchdogPath."
        }
        else
        {
            Write-Host "[$functionName] TelemetryAndDiagnostics ARC Extension WatchdogAgent detected at path $watchdogPath."
            return $true
        }
    }
    return $false
}

function Write-InstanceGuidEvent {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String] $InstanceGuidValue
    )

    $argumentList = @($PSScriptRoot, $InstanceGuidValue)
    try
    {
        $job = Start-Job -ArgumentList $argumentList -ScriptBlock {
            param($ScriptRoot, $InstanceGuidValue)
            Add-Type -Path "$ScriptRoot\Microsoft.AzureStack.Observability.Standalone.dll" -Verbose
            [Microsoft.AzureStack.Observability.Standalone.StandaloneTelEventSource]::Log.InstanceGuid($InstanceGuidValue)
            Write-Host "Successfully emitted InstanceGuid telemetry event."
        } | Wait-Job -Timeout 30 | Receive-Job | Out-Null
    }
    finally
    {
        $job | Remove-Job -Force
    }
}

function Get-AzAccessTokenAsPlainText
{
    [CmdletBinding()]
    Param (
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Verbose "[$functionName] Entering"
    $token = $null
    $BSTR = $null

    try
    {
        $azAccountsVersion = (Get-Module Az.Accounts).Version
        if ($azAccountsVersion -lt "2.17.0")
        {
            $token = (Get-AzAccessToken).Token
        }
        else
        {
            $secureAccessToken = (Get-AzAccessToken -AsSecureString).Token
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureAccessToken)
            $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        }
        Write-Host "[$functionName] Successfully obtained access token."
    }
    catch
    {
        Write-Error "[$functionName] Failed to get access token. Error: $_"
    }
    finally
    {
        if ($BSTR)
        {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }
    }
    return $token
}

function Wait-ForLogUploadCompletion {
    param (
        [Parameter(Mandatory=$true)]
        [TimeSpan] $Timeout
    )

    $functionName = $MyInvocation.MyCommand.Name

    if (-not (Get-Command Get-CacheDirectories -ErrorAction SilentlyContinue)) {
        Write-Host "[$functionName] Get-CacheDirectories command not found. Reimporting SetupHelper module."
        Import-Module "$PSScriptRoot\SetupHelper.psm1" -Force
    }

    $operationTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "[$functionName] Waiting $($TimeOut.ToString("hh\:mm\:ss")) for MA to upload the logs..."

    $gmaCacheUploadSummary = @()
    $filtersIncompletePrevious = @()
    $gmaCacheUploadSummaryInitialized = $false
    $diagnosticsCacheTablesPath = Join-Path -Path (Get-CacheDirectories).DiagnosticsCache -ChildPath "Tables"

    Start-Sleep -Seconds 60 # Wait at least a minute for files to propagate to GMACache
    while ($operationTimer.Elapsed -le $Timeout)
    {
        $timeElapsed = $operationTimer.Elapsed
        $timeRemaining = $Timeout - $operationTimer.Elapsed
        Write-Host "[$functionName] Log Upload Operation Time Elapsed: $($timeElapsed.ToString("hh\:mm\:ss")) | Time Remaining: $($timeRemaining.ToString("hh\:mm\:ss"))"

        $filtersIncomplete = @()
        $cacheUploadCompleted = $true
        foreach ($filter in @("TextLogs", "EvtxLogs", "EtlLogs", "ServiceFabricLogs", "ACSLogs"))
        {
            $tsfs = Get-ChildItem -Path $diagnosticsCacheTablesPath -Filter "$filter*.tsf" -ErrorAction SilentlyContinue
            if ($null -ne $tsfs -and $($tsfs.Count) -gt 4)
            {
                $measure = $tsfs | Measure-Object Length -Sum
                $sizeNotYetUploaded = $measure.Sum / 1MB
                Write-Host "[$functionName] $filter size not yet uploaded: $sizeNotYetUploaded"
                $filtersIncomplete += $filter
                $cacheUploadCompleted = $false

                # Initialize GMA cache summary or update with incomplete filter uploads
                if (-not $gmaCacheUploadSummaryInitialized)
                {
                    $gmaCacheUploadSummary += [PSCustomObject]@{
                        LogType = $filter
                        StartingMB = $sizeNotYetUploaded
                        RemainingMB = $sizeNotYetUploaded
                        CompletionTime = "Incomplete"
                    }
                }
                else
                {
                    $gmaCacheUploadSummary | Where-Object { $_.LogType -eq $filter } | ForEach-Object {
                        $_.RemainingMB = $sizeNotYetUploaded
                    }
                }
            }
        }

        # Update GMA cache summary with completed filter uploads
        $gmaCacheUploadSummaryInitialized = $true
        $filtersCompleted = $filtersIncompletePrevious | Where-Object { $_ -notin $filtersIncomplete }
        $filtersIncompletePrevious = $filtersIncomplete
        foreach ($filter in $filtersCompleted)
        {
            Write-Host "[$functionName] $filter upload completed."
            $gmaCacheUploadSummary | Where-Object { $_.LogType -eq $filter } | ForEach-Object {
                $_.RemainingMB = 0
                $_.CompletionTime = $timeElapsed.ToString("hh\:mm\:ss")
            }
        }

        if ($cacheUploadCompleted)
        {
            Write-Host "[$functionName] Log upload completed."
            break
        }

        Write-Host "[$functionName] Waiting 30 seconds for $($filtersIncomplete -join ", ") upload..."
        Start-Sleep -Seconds 30
    }

    if (!$cacheUploadCompleted)
    {
        $message = "[$functionName] $($filtersIncomplete -join ", ") upload failed to complete within $($Timeout.ToString("hh\:mm\:ss"))."
        Write-Host $message
    }

    Write-Host "[$functionName] Log Upload Summary:`r`n$($gmaCacheUploadSummary | Format-Table -AutoSize | Out-String)"
}

<#
.SYNOPSIS
    Gets the paths written to by the Standalone Observability pipeline that should be cleaned up.
.DESCRIPTION
    Dynamically builds the list of cleanup paths based on:
      - Get-CacheDirectories (GMACache)
      - Registry key for ObsRootFolderPath (e.g., C:\Obs_XXXX)
#>
function Get-StandalonePipelineCleanupPaths {
    # Get cache directories from SetupHelper (GMACache, ObservabilityVolume)
    if (-not (Get-Command Get-CacheDirectories -ErrorAction SilentlyContinue)) {
        Write-Host "[$functionName] Get-CacheDirectories command not found. Reimporting SetupHelper module."
        Import-Module "$PSScriptRoot\SetupHelper.psm1" -Force
    }
    $cacheDirectories = Get-CacheDirectories
    $cleanupPaths = @(
        $cacheDirectories.GMACache
    )

    # Get ObsRootFolderPath from registry (e.g., C:\Obs_XXXX)
    $obsRootFolderRegKeyPath = "HKLM:\SOFTWARE\Microsoft\AzureStack\Observability"
    $obsRootFolderRegKeyName = "ObsRootFolderPath"
    $obsRootFolderPath = Get-ItemPropertyValue -Path $obsRootFolderRegKeyPath -Name $obsRootFolderRegKeyName -ErrorAction SilentlyContinue
    
    if ($obsRootFolderPath) {
        $cleanupPaths += $obsRootFolderPath
    }

    return $cleanupPaths
}

<#
.SYNOPSIS
    Attempts to remove content generated by the Standalone Observability pipeline installation.
.DESCRIPTION
    Best-effort removal of temporary files and folders created by the observability pipeline.
    Paths are determined dynamically via Get-StandalonePipelineCleanupPaths.
    Prompts for confirmation only for paths that had pre-existing content before installation.
    If removal fails due to file locks, attempts to release handles via Close-ProcessHandles.ps1
    and retries.
.PARAMETER PreExistingPaths
    Paths that had content before installation. User will be prompted for confirmation on these.
.PARAMETER PromptForAll
    If specified, prompts for confirmation before removing each path (treats all as pre-existing).
#>
function Remove-StandalonePipelineGeneratedContent {
    param (
        [Parameter(Mandatory = $false)]
        [string[]] $PreExistingPaths = @(),

        [Parameter(Mandatory = $false)]
        [switch] $PromptForAll
    )

    # Get cleanup paths and filter to those that exist
    $cleanupPaths = Get-StandalonePipelineCleanupPaths
    $resolvedPaths = $cleanupPaths | Where-Object { Test-Path -Path $_ }

    if (-not $resolvedPaths) {
        Write-Host "No content found at pipeline output locations."
        return
    }

    # If PromptForAll is set, treat all resolved paths as pre-existing
    if ($PromptForAll) {
        $PreExistingPaths = $resolvedPaths
    }

    $pathList = $resolvedPaths -join "`n  - "
    Write-Host "Removing pipeline generated content at:`n  - $pathList"

    $removedCount = 0
    $skippedCount = 0
    $failedCount = 0

    foreach ($pathToRemove in $resolvedPaths) {
        # Prompt for confirmation only if this path had pre-existing content
        if ($PreExistingPaths -contains $pathToRemove) {
            if (-not $PromptForAll) {
                Write-Warning "Pre-existing content detected at '$pathToRemove'."
            }
            $confirm = Read-Host "Remove '$pathToRemove'? (y/n)"
            if ($confirm -ne 'y') {
                Write-Host "Skipped '$pathToRemove'."
                $skippedCount++
                continue
            }
        }

        $removed = $false
        $lastError = $null
        try {
            Remove-Item -Path $pathToRemove -Force -Recurse -ErrorAction Stop
            $removed = $true
        }
        catch {
            $lastError = $_.Exception.Message
            if ($lastError -match 'being used by another process|access.*denied|cannot remove') {
                Write-Host "File lock detected on '$pathToRemove'. Attempting to release handles..."
                & "$PSScriptRoot\Close-ProcessHandles.ps1" -FolderPathToClean $pathToRemove 2>&1 | Out-Null
                try {
                    Remove-Item -Path $pathToRemove -Force -Recurse -ErrorAction Stop
                    $removed = $true
                }
                catch {
                    $lastError = $_.Exception.Message
                }
            }
        }

        if ($removed) {
            $removedCount++
            Write-Host "Removed '$pathToRemove'."
        }
        else {
            $failedCount++
            Write-Warning "Failed to remove '$pathToRemove': $lastError"
        }
    }

    # Build summary message
    $totalCount = $resolvedPaths.Count
    $summary = "Cleanup complete. Removed $removedCount of $totalCount paths"
    if ($skippedCount -gt 0 -or $failedCount -gt 0) {
        $details = @()
        if ($skippedCount -gt 0) { $details += "$skippedCount skipped" }
        if ($failedCount -gt 0) { $details += "$failedCount failed" }
        $summary += " ($($details -join ', '))"
    }
    $summary += "."
    Write-Host $summary
}

# Export section
Export-ModuleMember -Function Remove-AzureConnectedMachineAgent
Export-ModuleMember -Function Install-AzureConnectedMachineAgent
Export-ModuleMember -Function New-GmaStateFolders
Export-ModuleMember -Function Set-HandlerEnvInfo
Export-ModuleMember -Function Test-IsAzure
Export-ModuleMember -Function Set-StampGuid
Export-ModuleMember -Function Test-IsArcAgentConnected
Export-ModuleMember -Function Test-UserIsElevated
Export-ModuleMember -Function Test-ArcExtensionWatchdogIsPresent

Export-ModuleMember -Function Get-AzAccessTokenAsPlainText
Export-ModuleMember -Function Get-TenantId
Export-ModuleMember -Function Get-AzureURIs
Export-ModuleMember -Function Get-GmaStateFolders
Export-ModuleMember -Function Set-StandaloneScenarioRegistry
Export-ModuleMember -Function Confirm-IsArcAEnvironment
Export-ModuleMember -Function Wait-ForGcsConfigSync
Export-ModuleMember -Function Wait-ForLogUploadCompletion
Export-ModuleMember -Function Write-InstanceGuidEvent
Export-ModuleMember -Function Get-StandalonePipelineCleanupPaths
Export-ModuleMember -Function Remove-StandalonePipelineGeneratedContent
# SIG # Begin signature block
# MIInRgYJKoZIhvcNAQcCoIInNzCCJzMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB4DWvj/bU9SSvc
# 2LGlalT4dR2JKwMs+RDR+ueWYgC9hqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIyjyTsw
# BlQBiNDOGiSvYBL14H2Uh6LBy6y6oWxtlRnoMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAZXuIy1/IFFBOyJqMcdF8SWN/UnuldbJHhQeMdCCL
# QlwnHKH8hdGWadswfESeqIsGR7o37sDUTedtjTEzZSTOhw/muFrrW1Zcyqz3OE0A
# l/uSBQDBL7E2Sr868HP9SSXX3BB9M/oQ6l7LA0lFnw+utyVmuVrAd+V2LMGB3J7f
# zGMsn2ouUulPLk+H4I1GUd+Y6Y2MBx6T+0/gS2UJN4gKZ0eFt7lrkjPeRgxGmD4b
# 2NOGEpbh456lwwaep4YEO1Dpw5MANXg7BYSSu0A4hiCV7lxYTFZcfGXL339Nmst+
# hsdNV5ziqqrciBfkCkbMxJY+YAP743k/RB6hj3z/t3kmz6GCF5QwgheQBgorBgEE
# AYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDmEODMLa9zALyUS5/kGtJbXbmx6Rj4cXjg3pf3
# JfhWBwIGaeeNG/EVGBMyMDI2MDUwMzE0MzExMC42NTRaMASAAgH0oIHRpIHOMIHL
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
# SIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCA1rPne9sYkCY92paqzWSdtpQa2JAY4
# gcpkpsslBBFCQjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEghPTdqm/dR
# yZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGYMIGApH4wfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCysZCIAAQAAAiQwIgQgA//oxm2fo5LO
# mmtYNHLZwfdHBrA0Jfu1dxOXSFqdBYowDQYJKoZIhvcNAQELBQAEggIANiGiWcg2
# xAgAkHbvmTAhy/i3aUyMxSxoFpcaBSnhVk6KJtQQhjAYazTNFn4pSSXPm23EVb3y
# CZQm+qeW9hM6FiX5pNQmQKDUnyJz9WNy211ni3YDtQsf9UjCI2SjrQ7sTlTx7qdO
# Ns8D2NsDSXW5zZ/yi417cap3fHNSpQcqR9JhgrmPeaGXQSx80iRE31iJAXEty3lf
# ZzO7j+q0HpP5+VLyoQyO6WgPoCvzP03fZfKe4NqfDPkSivFUl4U3ogd4BaEiTVzW
# QodlNFp+/PauKOXUWdiUc8xP0AXE/vSHkA9boZrlMPK5kTRficPm343YmIr69D+/
# +4vD3jQmrMl9n8PW01g5jk2P/KlxRRBq3+NkbpakMrI+Us6IcJvtgEyZqqoUDE9G
# D939MxZkuqvnUkMCMU8BCSAR7Ji33ySuU6zJG5tPLSG3RaaglkwQ10Pnln54ocx7
# H0ACQLR0qEzV0Upy7pQl5IWD194OK2GrO8NhCrpTfxvXZbsRiQ/k/ftUPy59m4Vq
# NNpWBYrMysNtBopUwtWwyGJ9wfr26bDY45kmYUIMAQrSh7FVH+IBrth/ZnZ0wdoj
# CmeQOOIvnqWRO/Vlknad39SYQwiTXxIP1PS2vRr3E2DlrXKqRECGztI1l7V2WJMC
# NXRZr4APRZfc04i048RdYmNPF5ggSZQdplw=
# SIG # End signature block
