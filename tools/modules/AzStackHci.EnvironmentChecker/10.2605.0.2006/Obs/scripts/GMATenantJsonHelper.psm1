##------------------------------------------------------------------
##  <copyright file="GMATenantJsonHelper.psm1" company="Microsoft">
##    Copyright (C) Microsoft. All rights reserved.
##  </copyright>
##------------------------------------------------------------------

## Import ObservabilityGMAEventSource
Add-Type -Path "$PSScriptRoot\Microsoft.AzureStack.Observability.GenevaMonitoringAgent.dll" -Verbose
Add-Type -Path "$PSScriptRoot\Microsoft.AzureStack.Observability.ObservabilityCommon.dll" -Verbose
Add-Type -Path "$PSScriptRoot\Newtonsoft.Json.dll" -Verbose

#region Constants
$global:ErrorConstants = @{
    ManagementClusterNameNotFound = @{
        Code = 20
        Name = "ManagementClusterNameNotFound"
        Message = "ManagementClusterName not found in Cloud config."
    }
    CannotCopyUtcExporterDll = @{
        Code = 21
        Name = 'CannotCopyUtcExporterDll'
        Message = "Failed to copy UtcExporterDll file."
    }
    CannotStartService = @{
        Code = 22
        Name = 'CannotStartService'
        Message = "Observability related service cannot be started after multiple retries."
    }
    CannotStopService = @{
        Code = 23
        Name = 'CannotStopService'
        Message = "Observability related service cannot be stopped after multiple retries."
    }
    InsufficientDiskSpaceForGMACache = @{
        Code = 24
        Name = 'InsufficientDiskSpaceForGMACache'
        Message = "There is insufficient disk space available on the drive (Current size = {0} GB on {1} drive). To proceed with the extension installation, please delete some files to free up space."
    }
    GetAzureStackHCICmdletNotAvailable = @{
        Code = 25
        Name = 'GetAzureStackHCICmdletNotAvailable'
        Message = "If either the Get-AzureStackHCI or Get-ClusterNode cmdlet is not available to retrieve the necessary information, the tenant JSON configuration files will not be created."
    }
    InvalidScheduledTaskScriptPath = @{
        Code = 26
        Name = 'InvalidScheduledTaskScriptPath'
        Message = 'Invalid script path provided for scheduled task creation.'
    }
    TelemetryDisabled = @{
        Code = 27
        Name = 'TelemetryDisabled'
        Message = 'Telemetry is disabled.'
    }
    CannotRegisterService = @{
        Code = 28
        Name = 'CannotRegisterService'
        Message = 'Observability related service cannot be registered.'
    }
    MetricsRegionalNamespaceNotFound = @{
        Code = 29
        Name = 'RegionalMetricNamespaceNotFound'
        Message = 'Regional Metric Namespaces not found.'
    }
    VCRedistInstallFailed= @{
        Code = 30
        Name = 'VCRedistInstallFailed'
        Message = "Failed to install VC Redistributable VC_redist.x64.exe. Exit code is {0}"
    }
    GcsConfigFilesNotFound = @{
        Code = 31
        Name = 'GcsConfigFilesNotFound'
        Message = "GCSConfig files are not found. Please check the logs for further investigation."
    }
    SecurityJsonNotToBeCreatedInExt = @{
        Code = 32
        Name = 'SecurityJsonNotToBeCreatedInExt'
        Message = "Tenant json for Security config is not be created through extension. It will be generated on-demand by enabling/disabling of SysLogForwarder setting."
    }
    ArcAgentResourceInfoNotFound = @{
        Code = 33
        Name = 'ArcAgentResourceInfoNotFound'
        Message = "No return information recieved when calling arc agent."
    }
    PackagePathDoesNotExist = @{
        Code = 34
        Name = "PackagePathDoesNotExist"
        Message = "Package path ({0}) does not exist, cannot proceed."
    }
}

$global:RegistryConstants = @{
    DeviceTypeRegKey = @{
        Path = "HKLM:\SOFTWARE\Microsoft\AzureStack\"
        Name = "DeviceType"
        PropertyType = "String"
        Value = "AzureEdge"
    }
    TenantJsonCacheLocalPath = @{
        Path = "HKLM:\Software\Microsoft\AzureStack\Observability\TenantJson\{0}"
        Name = "LocalPath"
        PropertyType = "String"
    }
    TelemetryTenantGcsNamespace = @{
        Path = "HKLM:\SOFTWARE\Microsoft\AzureStack\Observability\TenantJson\Telemetry\"
        Name = "GcsNamespace"
    }
    ExtensionVersion = @{
        Path = "HKLM:\SOFTWARE\Microsoft\AzureStack\Observability\TenantJson\"
        Name = "MONITORING_AEO_EXTENSION_VERSION"
    }
    LongPathEnabled = @{
        Path = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem\"
        Name = "LongPathsEnabled"
        PropertyType = "DWord"
        Value = "1"
    }
}

$global:MiscConstants = @{
    CloudNames = @{
        <# 
            HCI RP Azure Environment (a.k.a Cloud) constants = 
            https://msazure.visualstudio.com/One/_git/AzSHCI-Usage?path=/src/common/ServiceCommon/Models/CommonConstants.cs&version=GBdevelopment&line=25&lineEnd=35&lineStartColumn=1&lineEndColumn=2&lineStyle=plain&_a=contents
        #>
        AzurePublicCloud = @("AzurePublicCloud", "AzureCloud")
        AzureUSGovernmentCloud = @("AzureUSGovernmentCloud", "AzureUSGovernment")
        AzureChinaCloud = @("AzureChinaCloud")
        AzureGermanCloud = @("AzureGermanCloud")
        USNat = @("USNat")
        USSec = @("USSec")
        AzureCanary = @("AzureCanary")
        AzurePPE = @("AzurePPE")
    }
    CIRegKey = @{
        Path = 'HKLM:\Software\Microsoft\SQMClient\'
        Name = 'IsCIEnv'
    }
    MetricsValidationRegKey = @{
        Path = 'HKLM:\Software\Microsoft\SQMClient\'
        Name = 'Enable3PMetricsValidation'
    }
    SddcRegKey = @{        
        Path = 'HKLM:\SOFTWARE\Microsoft\SQMClient'
        Name = 'IsTest'
    }
    ArcARegKey = @{
        Path = 'HKLM:\Software\Microsoft\ArcA\'
        Name = 'IsArcAEnv'
        PropertyType = 'DWORD'
        Value = 1
    }
    ConfigTypes = @{
        Telemetry = 'Telemetry'
        Diagnostics = 'Diagnostics'
        Health = 'Health'
        Security = 'Security'
        Metrics = 'Metrics'
    }
    DiagTrackRegKey = @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack'
        Name = 'AllowExporters'
        PropertyType = 'DWORD'
        Value = 1
    }
    HciDiagnosticLevel = @{
        Off = "off"
        Basic = "basic"
        Enhanced = "enhanced"
    }
    ErrorActionPreference = @{
        Ignore = "Ignore"
        Stop = "Stop"
        SilentlyContinue = "SilentlyContinue"
        Continue = "Continue"
    }
    GCSEnvironment = @{
        Test = "Test"
        Ppe = "Ppe"
        PpeFairfax = "PpeFairfax"
        PpeMooncake = "PpeMooncake"
        PpeUSNat = "PpeUSNat"
        PpeUSSec = "PpeUSSec"
        Prod = "Prod"
        ArcAPpe = "ArcAPpe"
        ArcAProd = "ArcAProd"
        Fairfax = "Fairfax"
        Mooncake = "Mooncake"
        USSec = "USSec"
        USNat = "USNat"
    }
    GCSRegionName = @{
        EastUS = 'eastus'
        WestEurope = 'westeurope'
    }
    GenevaExporterRegKey = @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\exporters\GenevaExporter'
        Name = 'DllPath'
        PropertyType = 'String'
    }
    GenevaNamespaceRegKey = @{
        Name = 'GenevaNamespace'
        PropertyType = 'String'
        Value = 'NAMESPACE_PLACEHOLDER'
    }
    EnvironmentVariableNames =  @{
        ClusterName = "CLUSTER_NAME"
        HciResourceUri = "HCI_RESOURCE_URI"
        AssemblyBuildVersion = "ASSEMBLY_BUILD_VERSION"
        SolutionBuildVersion = "SOLUTION_BUILD_VERSION"
        OsBuildVersion = "OS_BUILD_VERSION"
        MetricsArcResourceUri = "METRICS_ARC_RESOURCE_URI"
        MetricsShoeboxAccount = "METRICS_SHOEBOX_ACCOUNT"
    }
    HCITelemetryRegKey = @{
        Path = 'HKLM:\Software\Microsoft\AzureStack\Observability\MAWatchdogService\HCITelemetry'
        Name = 'AllowTelemetry'
        PropertyType = 'String'
        Value = 'True'
    }
    GMAScenarioRegKey = @{ # Registry is not set for ASZ scenario, "Bootstrap" for Bootstrap Scenario, "1P" for 1P scenario
        Path = 'HKLM:\Software\Microsoft\AzureStack\Observability'
        Name = 'GMAScenario'
        PropertyType = 'String'
        Bootstrap = 'Bootstrap'
        OneP = '1P'
    }
    Level = @{
        Debug = "DEBUG"
        Fatal = "FATAL"
        Error = "ERROR"
        Info = "INFO"
        Verbose = "VERBOSE"
        Warning = "WARNING"
    }
    LogCollectionConfigs = @{
        DiagLogRoleConfigJson = "DiagnosticLogRoleConfiguration.json"
    }
    ObsScheduledTaskDetails = @{
        TaskName = "Get-TelemetryStatusAndEditConfigsInJsonDropLocation"
        TaskPath = "\Microsoft\AzureStack\Observability\"
        TranscriptsFolderName = "ObsScheduledTaskTranscripts"
        Description = "Runs every hour to determine telemetry status and based on that either adds or removes Telemetry config from JsonDropLocation."
        ScriptFileName = "GetTelemetryStatusAndEditConfigs.ps1"
    }
    TestHooksRegKey = @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\TestHooks'
        Name = 'SkipSignatureMitigation'
        PropertyType = 'DWORD'
        Value = 1
    }
    ValidationFunctionNames = @{
        AssertNoObsGMAProcessIsRunning = "Assert-NoObsGMAProcessIsRunning"
        AssertSufficientDiskSpaceAvailableForGMACache = "Assert-SufficientDiskSpaceAvailableForGMACache"
    }
    ObsServiceDetails = @{
        DiagTrack = @{
            Name = 'Diagtrack'
        }
        WatchdogAgent = @{
            Name = 'WatchdogAgent'
            DisplayName = 'Arc Extension MA Watchdog'
            BinaryFileName = 'Microsoft.AzureStack.Solution.Diagnostics.MaWatchdog.exe'
        }
        ObsAgent = @{
            Name = "AzureStack Observability Agent"
            DisplayName = "AzureStack Arc Extension Observability Agent"
            BinaryFileName = "Microsoft.AzureStack.Common.Infrastructure.HostModel.WinSvcHost.exe"
        }
    }
    Logman = @{
        ComponentProviderGuids = @{
            Microsoft_AzureStack_SupportBridgeController_LogCollector = "8a460ad6-c898-51da-3b87-5195076be95c" # Obs Agent
            Microsoft_AzureStack_Observability_LogOrchestrator = "c1b24b80-e724-5f0c-da1f-6521a3f002eb"
            Microsoft_AzureStack_LogParsingEngineManager = "e9809dda-e2ab-5961-2368-958f996b4fd8"
            Microsoft_AzureStack_LogParsingEngine_LogParser = "e1950b60-b861-500c-81bf-0d29ac999695"
            Microsoft_AzureStack_LogParsingEngine_GenevaConnector = "9d526935-090c-5c06-2afa-7886238ae238"
            FDA = "80072b42-cf7a-51a7-ee38-195a10c39d6e"
            Microsoft_AzureStack_ExtensionLifecycleManager = "77ac5a9c-353c-5d13-accf-90b97a9385a9"
            Microsoft_AzureStack_Infrastructure_Health_ArcProxyPlugin = "c761de30-3369-5c68-96ca-960288c3b988"
        }
        MaxLogFileSizeInMB = 500
        OutputFilePath ="$($env:SystemDrive)\Observability\ObservabilityLogmanTraces\observabilityLogmanTraces.etl"
        TraceName = "observabilityLogmanTraces"
    }
    VCRedistRegKeys = @{
        Paths = (
            "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64",
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
        )
        Name = "Version"
    }
    IdentityParamsToFetchFromPublicSettings = @{
        DeviceArmResourceUri = "DeviceArmResourceUri"
        StampId = "StampId"
        ClusterName = "ClusterName"
        AssemblyVersion = "AssemblyVersion"
        SolutionVersion = "SolutionVersion"
        NodeId = "NodeId"
    }
    ProActiveLogCollectionStates = @{
        Enabled = "enabled"
        Disabled = "disabled"
    }
    TenantJsonPropertyNames = @{
        Version = "Version"
        GcsAuthIdType = "GcsAuthIdType"
        GcsEnvironment = "GcsEnvironment"
        GcsGenevaAccount = "GcsGenevaAccount"
        GcsNamespace = "GcsNamespace"
        GcsRegion = "GcsRegion"
        GenevaConfigVersion = "GenevaConfigVersion"
        LocalPath = "LocalPath"
        DisableUpdate = "DisableUpdate"
        DisableCustomImds = "DisableCustomImds"
        MONITORING_AEO_REGION = "MONITORING_AEO_REGION"
        MONITORING_AEO_DEVICE_ARM_RESOURCE_URI = "MONITORING_AEO_DEVICE_ARM_RESOURCE_URI"
        MONITORING_AEO_STAMPID = "MONITORING_AEO_STAMPID"
        MONITORING_AEO_CLUSTER_NAME = "MONITORING_AEO_CLUSTER_NAME"
        MONITORING_AEO_OSBUILD = "MONITORING_AEO_OSBUILD"
        MONITORING_AEO_ASSEMBLYBUILD = "MONITORING_AEO_ASSEMBLYBUILD"
        MONITORING_AEO_NODEID = "MONITORING_AEO_NODEID"
        MONITORING_AEO_NODE_ARC_RESOURCE_URI = "MONITORING_AEO_NODE_ARC_RESOURCE_URI"
        MONITORING_AEO_CLUSTER_NODE_NAME = "MONITORING_AEO_CLUSTER_NODE_NAME"
        MONITORING_AEO_NODE_ARC_VMID = "MONITORING_AEO_NODE_ARC_VMID"
        MONITORING_AEO_EXTENSION_VERSION = "MONITORING_AEO_EXTENSION_VERSION"
        MONITORING_AEO_SOLUTIONBUILD = "MONITORING_AEO_SOLUTIONBUILD"
    }
    TenantJsonPropertyStaticValues = @{
        Version = "1.0"
        GcsAuthIdType = "AuthMSIToken"
        DisableUpdate = "true"
        DisableCustomImds = "true"
        MONITORING_AEO_CLUSTER_NODE_NAME = "%COMPUTERNAME%"
    }
    WinServiceStartupTypes = @{
        Automatic = "Automatic"
        Manual = "Manual"
    }
    
    ## One liner constants

    ## Value will be updated during Get-ArcAgentResourceInfo function execution.
    ArcAgentResourceInfo = $null
    AvailableDiskSpaceLimitInGB = 20
    DefaultManagementClusterName = 'Test_Extension_ClusterName'
    DiagTrackExportersRegKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\exporters'
    FDAOutputDirectory = "C:\Observability\FleetDiagnosticsAgent\FDAOutput"
    GMAHostProcessNameRegex = "MonAgentHost*"
    GMAHostProcessFullPathRegex = "C:\\Packages\\Plugins\\Microsoft\.AzureStack\.Observability\..*TelemetryAndDiagnostics\\.+\\bin\\GMA\\Monitoring\\Agent\\MonAgentHost\.exe"
    MAWatchDogAppAppConfigName = 'Microsoft.AzureStack.Solution.Diagnostics.MaWatchdog.exe.config'
    MonAgentHostExeName = 'MonAgentHost.exe'
    GMAMultiTenantModeCmdParam = '-serviceMode'
    AMAModeCmdParam = '-mcsmode'
    Retries = 3
    SuccessCode = 0
    SystemDriveLetter = $env:SystemDrive.split(':')[0]
    UtcExporterDestinationDirectory = 'C:\Windows\System32\UtcExporters'
    UtcExporterDllName = 'UtcGenevaExporter.dll'
    VCRuntimeExeName = 'VC_redist.x64.exe'
    VCRedistInstallationLogFileName = "VCRedistInstallation.log"
    WatchdogTimerFrequencyInSeconds = '90'
    WatchdogStatusFileName = 'WatchdogStatus.json'
}
#endregion Constants

#region Functions
function Get-ExceptionDetails {
    [CmdLetBinding()]
    Param (
        [Parameter(Mandatory=$True, ValueFromPipeline)]
        [System.Management.Automation.ErrorRecord] $ErrorObject
    )

    return @{
        Errormsg = $ErrorObject.ToString()
        Exception = $ErrorObject.Exception.ToString()
        Stacktrace = $ErrorObject.ScriptStackTrace
        Failingline = $ErrorObject.InvocationInfo.Line
        Positionmsg = $ErrorObject.InvocationInfo.PositionMessage
        PScommandpath = $ErrorObject.InvocationInfo.PSCommandPath
        Failinglinenumber = $ErrorObject.InvocationInfo.ScriptLineNumber
        Scriptname = $ErrorObject.InvocationInfo.ScriptName
    } | ConvertTo-Json ## The ConvertTo-Json will return the entire hashtable as string.
}

function Get-AssemblyVersion {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param (
        [Parameter(Mandatory=$false)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $assemblyVersion = [System.String]::Empty
    try {
        Import-Module EceClient -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue
        $cloudDll = Join-Path -Path $env:SystemDrive -ChildPath "CloudDeployment\ECEngine\CloudEngine.Cmdlets.dll"

        if (Get-Command Create-ECEClusterServiceClient -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) {
            Write-Log "[$functionName] Getting current assembly build version." -LogFile $LogFile
            $ececlient = Create-ECEClusterServiceClient
            $assemblyVersion  = $eceClient.GetPackageVersions().Result.Services

            Set-GlobalEnvironmentVariable `
                -EnvVariableName $MiscConstants.EnvironmentVariableNames.AssemblyBuildVersion `
                -EnvVariableValue $assemblyVersion `
                -LogFile $LogFile
        }
        elseif (Test-Path $cloudDll) {
            Write-Log "[$functionName] EceClient is not yet available. CloudEngine cmdlets are available, so getting Assembly version from ECE Configuration." -LogFile $LogFile
            Import-Module $cloudDll -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue
            $eceConfig = Get-ECEConfiguration
            $eceConfigXml = [xml]$eceConfig.Xml
            $assemblyVersion = (
                (
                    $eceConfigXml.CustomerConfiguration.Role.Actions.Action `
                    | Where-object {
                        $_.Type -eq "CloudDeployment"
                    }
                ).Parameters.Category[0].Parameter `
                | Where-Object {
                    $_.Name -eq "ServicesVersion"
                }
            ).Value

            Set-GlobalEnvironmentVariable `
                -EnvVariableName $MiscConstants.EnvironmentVariableNames.AssemblyBuildVersion `
                -EnvVariableValue $assemblyVersion `
                -LogFile $LogFile
        }
        else {
            Write-Log "[$functionName] Cannot get Assembly version because EceClient and ECEConfiguration are not available." -LogFile $LogFile
        }
    }
    catch {
        $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
        Write-Log "[$functionName] AssemblyVersion value will be empty as exception occured, details are as follows: $exceptionDetails" -LogFile $LogFile
    }

    Write-Log "[$functionName] Exiting. Returning: {assemblyVersion = $assemblyVersion}" -LogFile $LogFile
    return $assemblyVersion
}

function Get-SolutionVersion {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param (
        [Parameter(Mandatory=$false)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $solutionVersion = [System.String]::Empty
    try {
        Import-Module EceClient -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue
        $cloudDll = Join-Path -Path $env:SystemDrive -ChildPath "CloudDeployment\ECEngine\CloudEngine.Cmdlets.dll"

        if (Get-Command Create-ECEClusterServiceClient -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) {
            Write-Log "[$functionName] Getting current solution build version." -LogFile $LogFile
            $ececlient = Create-ECEClusterServiceClient
            $solutionVersion = $ececlient.GetStampVersion().GetAwaiter().GetResult()

            Set-GlobalEnvironmentVariable `
                -EnvVariableName $MiscConstants.EnvironmentVariableNames.SolutionBuildVersion `
                -EnvVariableValue $solutionVersion `
                -LogFile $LogFile
        }
        elseif (Test-Path $cloudDll) {
            Write-Log "[$functionName] EceClient is not yet available. CloudEngine cmdlets are available, so getting Solution version from ECE Configuration." -LogFile $LogFile
            Import-Module $cloudDll -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue
            $eceConfig = Get-ECEConfiguration
            $eceConfigXml = [xml]$eceConfig.Xml
            $solutionVersion = $eceConfigXml.CustomerConfiguration.Role.PublicInfo.Version

            Set-GlobalEnvironmentVariable `
                -EnvVariableName $MiscConstants.EnvironmentVariableNames.SolutionBuildVersion `
                -EnvVariableValue $solutionVersion `
                -LogFile $LogFile
        }
        else {
            Write-Log "[$functionName] Cannot get Solution version because EceClient and ECEConfiguration are not available." -LogFile $LogFile
        }
    }
    catch {
        $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
        Write-Log "[$functionName] Solution value will be empty as exception occured, details are as follows: $exceptionDetails" -LogFile $LogFile
    }

    Write-Log "[$functionName] Exiting. Returning: {solutionVersion = $solutionVersion}" -LogFile $LogFile
    return $solutionVersion
}

function Get-OsBuildVersion {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param (
        [Parameter(Mandatory=$false)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $osVersion = (Get-CimInstance -ClassName Win32_OperatingSystem -Property Version).Version
    $ntoskrnl = (Get-Item -Path (Join-Path -Path ([System.Environment]::SystemDirectory) -ChildPath 'ntoskrnl.exe')).VersionInfo.ProductVersion

    $osBuildVersion = "$osVersion.$($ntoskrnl.Split('.')[-1])"

    Write-Log "[$functionName] Exiting. Returning: {osBuildVersion = $osBuildVersion}" -LogFile $LogFile
    return $osBuildVersion
}

function Get-ArcAgentResourceInfo {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param(
        [Parameter(Mandatory=$false)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    if ($null -eq $MiscConstants.ArcAgentResourceInfo) {
        try
        {
            # Fetch Arc ResourceID for metrics
            $arcAgentExePath = "$($env:ProgramW6432)\AzureConnectedMachineAgent\azcmagent.exe"
            $arcshow = & $arcAgentExePath show -j
            $MiscConstants.ArcAgentResourceInfo = $arcshow | ConvertFrom-Json

            if ($MiscConstants.ArcAgentResourceInfo)
            {
                Write-Log "[$functionName] Successfully retrieved arc agent information and saved it in MiscConstants.ArcAgentResourceInfo. Value is $($MiscConstants.ArcAgentResourceInfo)" -LogFile $LogFile
            }
            else {
                throw $MiscConstants.ArcAgentResourceInfoNotFound.Name
            }
        }
        catch {
            $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
            Write-Log "[$functionName] Unhandled exception occured while fetching arc resource information: Exception is as follows: $exceptionDetails" -LogFile $LogFile
        }
    }
    else {
        Write-Log "[$functionName] MiscConstants.ArcAgentResourceInfo object has value, returning it." -LogFile $LogFile
    }

    Write-Log "[$functionName] Exiting." -LogFile $LogFile    
    return $MiscConstants.ArcAgentResourceInfo
}


function Get-MetricsNamespaceRegionMapping {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param(
            [Parameter(Mandatory=$false)]
            [System.String] $LogFile,

            [Parameter(Mandatory=$true)]
            [System.Object] $MetricsNamespace,

            [Parameter(Mandatory=$false)]
            [System.String] $region
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: {MetricsNamespace = $MetricsNamespace | Region = $region}" -LogFile $LogFile

    if ($null -eq $MetricsNamespace)
    {
        throw $ErrorConstants.MetricsRegionalNamespaceNotFound.Name
    }

    $metricsRegionalNamespace = [System.String]::Empty

    if ([System.String]::IsNullOrEmpty($region))
    {
        Write-Log "[$functionName] As region is empty, defaulting prefix to eastus." -LogFile $LogFile
        $metricsRegionalNamespace = $MetricsNamespace.Prefix + "eastus"
    }
    else
    {
        if ($MetricsNamespace.Region -contains $region)
        {
            $metricsRegionalNamespace = $MetricsNamespace.Prefix + $region
            Write-Log "[$functionName] Found supported region = $metricsRegionalNamespace." -LogFile $LogFile
        }
        else {
            Write-Log "[$functionName] Region $region not fully supported. Falling back to default region" -LogFile $LogFile
            $metricsRegionalNamespace = $MetricsNamespace.Prefix + $MetricsNamespace.Default
        }
    }

    Write-Log "[$functionName] Exiting. Returning: {MetricsRegionalNamespace = $metricsRegionalNamespace}" -LogFile $LogFile
    return $metricsRegionalNamespace
}

function Get-ArcAgentResourceId {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Object] $ArcAgentInfo,

        [Parameter(Mandatory=$false)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: {ArcAgentInfo = $ArcAgentInfo}" -LogFile $LogFile

    $arcAgentResourceId = [System.String]::Empty

    if ($null -eq $arcAgentInfo)
    {
        Write-Log "[$functionName] ArcResourceInfo object null" -LogFile $LogFile
    }
    else
    {
        if ($arcAgentInfo.ResourceId)
        {
            $arcAgentResourceId = $arcAgentInfo.ResourceId
        }
        else
        {
            $arcAgentResourceId = "/Subscriptions/$($arcAgentInfo.SubscriptionID)/resourceGroups/$($arcAgentInfo.ResourceGroup)/providers/Microsoft.HybridCompute/Machines/$($arcAgentInfo.ResourceName)"
        }
    }

    Write-Log "[$functionName] Exiting. Returning: {ArcAgentResourceId = $arcAgentResourceId}" -LogFile $LogFile
    return $arcAgentResourceId
}

function Get-ArcAgentVmId {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Object] $ArcAgentInfo,

        [Parameter(Mandatory=$false)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: {ArcAgentInfo = $ArcAgentInfo}" -LogFile $LogFile

    $arcAgentVmId = [System.String]::Empty

    if ($null -eq $arcAgentInfo)
    {
        Write-Log "[$functionName] ArcResourceInfo object null" -LogFile $LogFile
    }
    else
    {
        if ($arcAgentInfo.vmId)
        {
            $arcAgentVmId = $arcAgentInfo.vmId
        }
    }

    Write-Log "[$functionName] Exiting. Returning: {ArcAgentVmId = $arcAgentVmId}" -LogFile $LogFile
    return $arcAgentVmId
}

function Set-GlobalEnvironmentVariable {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$False)]
        [System.string] $LogFile,

        [Parameter(Mandatory=$False)]
        [System.string] $EnvVariableName,

        [Parameter(Mandatory=$False)]
        [System.string] $EnvVariableValue
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: {EnvVariableName = $EnvVariableName | EnvVariableValue = $EnvVariableValue}" -LogFile $LogFile

    if (Confirm-IsStringNotEmpty $EnvVariableName) {
        if (Confirm-IsStringNotEmpty $EnvVariableValue) {
            # Set machine env variable for health agent to access
            setx /m $EnvVariableName $EnvVariableValue | Out-Null
            Write-Log "[$functionName] Set $EnvVariableName to $([Environment]::GetEnvironmentVariable($EnvVariableName, 'Machine'))." -LogFile $LogFile
        }
        else {
            Write-Log "[$functionName] Cannot set environment variable as EnvVariableValue param is either null or empty." -LogFile $LogFile
        }
    }
    else {
        Write-Log "[$functionName] Cannot set environment variable as EnvVariableName param is either null or empty." -LogFile $LogFile
    }

    Write-Log "[$functionName] Exiting." -LogFile $LogFile
}

function Set-EnvironmentVariablesForMetrics {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [System.string] $LogFile,

        [Parameter(Mandatory=$false)]
        [System.string] $EnvInfoFilePath,

        [Parameter(Mandatory=$false)]
        [System.string] $HciResourceUri,

        [Parameter(Mandatory=$false)]
        [System.string] $GcsEnvironment,

        [Parameter(Mandatory=$false)]
        [System.string] $AssemblyBuildVersion,

        [Parameter(Mandatory=$false)]
        [System.String] $ClusterName
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    # Set METRICS_ARC_RESOURCE_URI
    $ArcAgentInfo = Get-ArcAgentResourceInfo
    if($null -ne $ArcAgentInfo){
        $arcAgentResourceId = Get-ArcAgentResourceId -ArcAgentInfo $ArcAgentInfo   
        Set-GlobalEnvironmentVariable `
            -EnvVariableName $MiscConstants.EnvironmentVariableNames.MetricsArcResourceUri `
            -EnvVariableValue $arcAgentResourceId `
            -LogFile $LogFile
    }

    # Set CLUSTER_NAME
    $clusterNameValue = [System.String]::Empty
    if($null -ne $ClusterName){
        $clusterNameValue = $ClusterName
    }
    elseif (Confirm-GetAzureStackHciIsAvailable) {
        $clusterNameValue = (Get-Cluster).Name
    }
    Set-GlobalEnvironmentVariable `
        -EnvVariableName $MiscConstants.EnvironmentVariableNames.ClusterName `
        -EnvVariableValue $clusterNameValue `
        -LogFile $LogFile

    # Set HCI_RESOURCE_URI
    $deviceArmResourceUri = [System.String]::Empty
    if($null -ne $HciResourceUri) {
        $deviceArmResourceUri = $HciResourceUri
    }
    else {
        if(Confirm-GetAzureStackHciIsAvailable) {
            $azureStackHciDetails = Get-AzureStackHCI
            $deviceArmResourceUri = $azureStackHciDetails.AzureResourceUri
        }
    }
    Set-GlobalEnvironmentVariable `
        -EnvVariableName $MiscConstants.EnvironmentVariableNames.HciResourceUri `
        -EnvVariableValue $deviceArmResourceUri `
        -LogFile $LogFile
    
    # Set METRICS_SHOEBOX_ACCOUNT
    try {
        $tenantInfoContent = Get-Content $EnvInfoFilePath -Raw | ConvertFrom-Json
        $gcsEnvironmentName = $GcsEnvironment
        
        if (Test-RegKeyExists -Path $MiscConstants.MetricsValidationRegKey.Path -Name $MiscConstants.MetricsValidationRegKey.Name -LogFile $LogFile) {
            $gcsEnvironmentName = $MiscConstants.GCSEnvironment.Prod
        }

        $envInfo = $tenantInfoContent.$GcsEnvironmentName
        $shoeboxAccountName = Get-MetricsShoeboxAccountName `
            -ShoeboxAccountPrefix $envInfo.ShoeboxAccountPrefix `
            -MetricsNamespace $envInfo.Namespaces.Metrics `
            -Region $ArcAgentInfo.Location

        Set-GlobalEnvironmentVariable `
            -EnvVariableName $MiscConstants.EnvironmentVariableNames.MetricsShoeboxAccount `
            -EnvVariableValue $shoeboxAccountName `
            -LogFile $LogFile
    }
    catch
    {
        $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
        Write-Log "[$functionName] METRICS_SHOEBOX_ACCOUNT environment variable is not set due to exception: $exceptionDetails" -LogFile $LogFile
    }

    # Set Assembly Build Version
    Set-GlobalEnvironmentVariable `
        -EnvVariableName $MiscConstants.EnvironmentVariableNames.AssemblyBuildVersion `
        -EnvVariableValue $AssemblyBuildVersion `
        -LogFile $LogFile

    # Set OS Build Version
    $osBuildVersion = Get-OsBuildVersion
    Set-GlobalEnvironmentVariable `
        -EnvVariableName $MiscConstants.EnvironmentVariableNames.OsBuildVersion `
        -EnvVariableValue $osBuildVersion `
        -LogFile $LogFile
}

function Get-MetricsShoeboxAccountName {
    [CmdletBinding()]
    [OutputType([System.String])]
    Param(
        [Parameter(Mandatory=$false)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String] $ShoeboxAccountPrefix,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Object] $MetricsNamespace,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String] $Region
    )

    $functionName = $MyInvocation.MyCommand.Name
    $shoeboxAccountName = [System.String]::Empty

    Write-Log "[$functionName] Entering. Params: {ShoeboxAccountPrefix = $ShoeboxAccountPrefix | MetricsNamespace = $MetricsNamespace | Region = $Region}" -LogFile $LogFile

    # Shoebox account name and region mapping 
    if ($MetricsNamespace.Region -contains $Region)
    {
        Write-Log "[$functionName] Found supported region $Region." -LogFile $LogFile
        $shoeboxAccountName = $ShoeboxAccountPrefix + $Region
    }
    else
    {
        Write-Log "[$functionName] Region $Region not fully supported. Falling back to default region." -LogFile $LogFile
        $shoeboxAccountName = $ShoeboxAccountPrefix + $MetricsNamespace.Default
    }

    Write-Log "[$functionName] Exiting. Returning: {ShoeboxAccountName: $shoeboxAccountName}" -LogFile $LogFile
    return $shoeboxAccountName
}

function New-ScheduledTaskForObservability {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]
        [System.String] $TaskName,

        [Parameter(Mandatory=$false)]
        [System.String] $Description,

        [Parameter(Mandatory)]
        [System.String] $ScriptPath,

        [Parameter(Mandatory)]
        [System.String] $ScriptArguments,

        [Parameter(Mandatory=$false)]
        [System.String] $TaskPath = "\Microsoft\AzureStack\Observability\",

        [Parameter(Mandatory=$false)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.SwitchParameter] $DisableOnRegistration
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: {TaskName = $TaskName | Description = $Description | ScriptPath = $ScriptPath | ScriptArguments = $ScriptArguments | TaskPath = $TaskPath | DisableOnRegistration = $DisableOnRegistration}" -LogFile $LogFile

    if (([System.String]::IsNullOrEmpty($ScriptPath)) -or `
        (-not (Test-Path -Path $ScriptPath -ErrorAction $MiscConstants.ErrorActionPreference.Ignore)))
    {
        throw $ErrorConstants.InvalidScheduledTaskScriptPath.Name
    }

    # Enable scheduled task event log
    $logChannelStatus = Get-WinEvent -ListLog "Microsoft-Windows-TaskScheduler/Operational"
    if (!$logChannelStatus.IsEnabled)
    {
        Write-Log "[$functionName] Enabling TaskScheduler event logs" -LogFile $logFile
        $logName = 'Microsoft-Windows-TaskScheduler/Operational'
        $log = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration $logName
        $log.IsEnabled = $true
        $log.SaveChanges()
    }

    Write-Log "[$functionName] Setting up scheduled task ($TaskName) at path ($TaskPath)" -LogFile $logFile
    
    $action = ScheduledTasks\New-ScheduledTaskAction -Execute "powershell.exe" `
                                    -Argument "-windowstyle hidden -Command $ScriptPath $ScriptArguments"
    $principal = ScheduledTasks\New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount
    $trigger = ScheduledTasks\New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
    $trigger.Repetition.StopAtDurationEnd = $false
    
    $settings = ScheduledTasks\New-ScheduledTaskSettingsSet -ExecutionTimeLimit $(New-TimeSpan -Seconds 300) `
                                            -RestartCount 3 `
                                            -RestartInterval $(New-TimeSpan -Minutes 10)

    $object = ScheduledTasks\New-ScheduledTask -Action $action `
                                    -Principal $principal `
                                    -Trigger $trigger `
                                    -Settings $settings `
                                    -Description $Description

    # If the task is already registered, unregister it first or otherwise it does not get overwritten.
    if ($null -ne (ScheduledTasks\Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Verbose:$false -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue))
    {
        ScheduledTasks\Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -Verbose:$false -ErrorAction $MiscConstants.ErrorActionPreference.Stop | Out-Null
        Write-Log "[$functionName] Unregistered already created scheduled task ($TaskName) at path ($TaskPath)." -LogFile $logFile
    }

    ScheduledTasks\Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -InputObject $object -Verbose:$false -ErrorAction $MiscConstants.ErrorActionPreference.Stop | Out-Null
    Write-Log "[$functionName] Scheduled task creation ($TaskName) succeeded." -LogFile $logFile

    if ($DisableOnRegistration) {
        ScheduledTasks\Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Verbose:$false -ErrorAction $MiscConstants.ErrorActionPreference.Stop | Out-Null

        Write-Log "[$functionName] ScheduledTask named ($($MiscConstants.ObsScheduledTaskDetails.TaskName)) is disabled." -LogFile $logFile
    }
    
    Write-Log "[$functionName] Exiting." -LogFile $LogFile
}

function Test-RegKeyExists {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]
        [System.String] $Path,

        [Parameter(Mandatory)]
        [System.String] $Name,

        [Parameter(Mandatory = $False)]
        [System.String] $LogFile,

        [Parameter(Mandatory = $False)]
        [System.Management.Automation.SwitchParameter] $GetValueIfExists
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)" -LogFile $LogFile

    $regKey = $(Get-ItemProperty -Path $Path -Name $Name -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue)

    if ($null -ne $regKey) {

        if ($GetValueIfExists) {
            $value = $regKey.$Name
    
            Write-Log "[$functionName] Obtained registry value '$value' from path '$Path' and name '$Name'. Exiting." -LogFile $LogFile
    
            return $value
        }
    
        Write-Log "[$functionName] Registry key found at path '$Path' with name '$Name'. Exiting." -LogFile $LogFile

        return $regKey
    }
    else {
        Write-Log "[$functionName] Registry key at path '$Path' with name '$Name' does not exist. Exiting." -LogFile $LogFile

        return $null
    }
}

function Get-ConfigTypeEnum {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $ConfigType,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Getting configTypeEnum for configType ($ConfigType)." -LogFile $LogFile

    $configTypeEnum = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Invalid
    switch($ConfigType)
    {
        $MiscConstants.ConfigTypes.Telemetry
        {
            $configTypeEnum = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Telemetry
            break
        }
        $MiscConstants.ConfigTypes.Diagnostics
        {
            $configTypeEnum = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Diagnostics
            break
        }
        $MiscConstants.ConfigTypes.Health
        {
            $configTypeEnum = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Health
            break
        }
        $MiscConstants.ConfigTypes.Security
        {
            $configTypeEnum = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Security
            break
        }
        $MiscConstants.ConfigTypes.Metrics
        {
            $configTypeEnum = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Metrics
            break
        }
    }
    Write-Log "[$functionName] Exiting. Returning: {configTypeEnum = $configTypeEnum}" -LogFile $LogFile

    return $configTypeEnum
}

function Set-TenantConfigRegistryKeys
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [ValidateSet("Telemetry", "Health", "Diagnostics", "Security", "Metrics")]
        [System.String] $ConfigType,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $Version,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $GcsAuthIdType,
        
        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $GcsEnvironment,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $GcsGenevaAccount,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $GcsNamespace,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $GcsRegion,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $GenevaConfigVersion,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $LocalPath,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $DisableUpdate,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $DisableCustomImds,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $MONITORING_AEO_REGION,

        ## Some of the Identity parameters may be empty and so the AllowEmptyString() attribute is added.
        [Parameter(Mandatory=$True)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_DEVICE_ARM_RESOURCE_URI,

        [Parameter(Mandatory=$True)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_STAMPID,

        [Parameter(Mandatory=$True)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_CLUSTER_NAME,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $MONITORING_AEO_OSBUILD,

        [Parameter(Mandatory=$True)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_ASSEMBLYBUILD,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $MONITORING_AEO_NODEID,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $MONITORING_AEO_NODE_ARC_RESOURCE_URI,

        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [System.String] $MONITORING_AEO_CLUSTER_NODE_NAME,

        [Parameter(Mandatory=$True)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_NODE_ARC_VMID,

        [Parameter(Mandatory=$False)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_EXTENSION_VERSION,

        [Parameter(Mandatory=$False)]
        [AllowEmptyString()]
        [System.String] $MONITORING_AEO_SOLUTIONBUILD
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Setting Tenant config registry keys for $ConfigType. Params: $($PSBoundParameters | ConvertTo-Json -Compress)" -LogFile $LogFile
    if (-not $MONITORING_AEO_EXTENSION_VERSION)
    {
        $MONITORING_AEO_EXTENSION_VERSION = ""
    }
    if (-not $MONITORING_AEO_SOLUTIONBUILD)
    {
        $MONITORING_AEO_SOLUTIONBUILD = ""
    }

    $configTypeEnum = Get-ConfigTypeEnum -ConfigType $ConfigType -LogFile $LogFile

    if ($LogFile)
    {
        [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.TenantConfigRegistrySetter]::Current.SetTenantConfigRegistryKeys(
            $configTypeEnum,
            $LogFile,
            $Version,
            $GcsAuthIdType,
            $GcsEnvironment,
            $GcsGenevaAccount,
            $GcsNamespace,
            $GcsRegion,
            $GenevaConfigVersion,
            $LocalPath,
            $DisableUpdate,
            $DisableCustomImds,
            $MONITORING_AEO_REGION,
            $MONITORING_AEO_DEVICE_ARM_RESOURCE_URI,
            $MONITORING_AEO_STAMPID,
            $MONITORING_AEO_CLUSTER_NAME,
            $MONITORING_AEO_OSBUILD,
            $MONITORING_AEO_ASSEMBLYBUILD,
            $MONITORING_AEO_NODEID,
            $MONITORING_AEO_NODE_ARC_RESOURCE_URI,
            $MONITORING_AEO_CLUSTER_NODE_NAME,
            $MONITORING_AEO_NODE_ARC_VMID,
            $MONITORING_AEO_EXTENSION_VERSION,
            $MONITORING_AEO_SOLUTIONBUILD)
    }
    else
    {
        [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.TenantConfigRegistrySetter]::Current.SetTenantConfigRegistryKeys(
            $configTypeEnum,
            $Version,
            $GcsAuthIdType,
            $GcsEnvironment,
            $GcsGenevaAccount,
            $GcsNamespace,
            $GcsRegion,
            $GenevaConfigVersion,
            $LocalPath,
            $DisableUpdate,
            $DisableCustomImds,
            $MONITORING_AEO_REGION,
            $MONITORING_AEO_DEVICE_ARM_RESOURCE_URI,
            $MONITORING_AEO_STAMPID,
            $MONITORING_AEO_CLUSTER_NAME,
            $MONITORING_AEO_OSBUILD,
            $MONITORING_AEO_ASSEMBLYBUILD,
            $MONITORING_AEO_NODEID,
            $MONITORING_AEO_NODE_ARC_RESOURCE_URI,
            $MONITORING_AEO_CLUSTER_NODE_NAME,
            $MONITORING_AEO_NODE_ARC_VMID,
            $MONITORING_AEO_EXTENSION_VERSION,
            $MONITORING_AEO_SOLUTIONBUILD)
    }

    Write-Log "[$functionName] Successfully set tenant config registry keys for $ConfigType. Exiting." -LogFile $LogFile
}

function Set-TenantConfigJsonFile
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [ValidateSet("Telemetry", "Health", "Diagnostics", "Security", "Metrics")]
        [System.String] $ConfigType,

        [Parameter(Mandatory=$True)]
        [System.String] $FilePath,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Setting $ConfigType tenant config json file at $FilePath." -LogFile $LogFile

    $configTypeEnum = Get-ConfigTypeEnum -ConfigType $ConfigType -LogFile $LogFile
    
    if($ConfigType -eq "Metrics" -and -not(Test-MetricsSupportedForHCIBuild -LogFile $LogFile))
    {
        Write-Log "[$functionName] Azure Stack HCI standard metrics are not supported on Azure Stack HCI 22H2, skipping metrics tenant config generation."  -LogFile $LogFile
        return
    }

    if($LogFile)
    {
        [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.TenantConfigGenerator]::Current.GenerateConfig(
            $configTypeEnum,
            $LogFile,
            $FilePath)
    }
    else
    {
        [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.TenantConfigGenerator]::Current.GenerateConfig(
            $configTypeEnum,
            $FilePath)
    }

    Write-Log "[$functionName] Successfully created tenant config json file for $ConfigType. Exiting." -LogFile $LogFile    
}

function Test-MetricsSupportedForHCIBuild
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    $regConstants = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Constants]
    $commonRegPath =  $regConstants::CommonConfigRegistryPath -replace "HKEY_LOCAL_MACHINE", "HKLM:"
    $registryKeyName = $MiscConstants.TenantJsonPropertyNames.MONITORING_AEO_ASSEMBLYBUILD
    $MONITORING_AEO_ASSEMBLYBUILD = Test-RegKeyExists -Path $commonRegPath -Name $registryKeyName -GetValueIfExists -LogFile $LogFile
            
    if ($null -ne $MONITORING_AEO_ASSEMBLYBUILD) 
    {
        try
        {
            $currentVersion = [version]($MONITORING_AEO_ASSEMBLYBUILD)
            $minimumSupportedVersionForMetrics = [version]"10.2311.2.7"
            Write-Log "[$functionName] $registryKeyName is $currentVersion." -LogFile $LogFile
            if($currentVersion -lt $minimumSupportedVersionForMetrics)
            {
                Write-Log "[$functionName] Azure Stack HCI standard metrics are not supported on Azure Stack HCI 22H2, skipping metrics tenant config generation."  -LogFile $LogFile
                return $False
            }
            else 
            {
                return $True
            }
        }
        catch 
        {
            Write-Log "[$functionName] Error occurred while parsing the registry key value for $registryKeyName. Skipping metrics tenant config generation." -LogFile $LogFile
            return $False
        }
    }
    else 
    {
        Write-Log "[$functionName] $registryKeyName registry key not found at $commonRegPath. Skipping metrics tenant config generation." -LogFile $LogFile
        return $False
    }
}

function Sync-TenantRegKeysAndConfigFile
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [ValidateSet("Telemetry", "Health", "Diagnostics", "Security", "Metrics")]
        [System.String] $ConfigType,

        [Parameter(Mandatory=$True)]
        [System.String] $FilePath,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. ConfigType: $ConfigType FilePath: $FilePath" -LogFile $LogFile

    try
    {
        if (Test-Path $FilePath)
        {
            $rewriteJsonFile = $false
            $jsonContents = Get-ContentAsJson -Path $FilePath
            $jsonSections = @("ServiceArguments", "UserArguments", "ConstantVariables", "ExpandVariables")
            $jsonValues = @{}
            $regConstants = [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Constants]
            $commonKeys = $regConstants::CommonRegistryKeys
            $tenantKeys = $regConstants::TenantSpecificRegistryKeys
            foreach ($key in $commonKeys + $tenantKeys)
            {
                foreach ($section in $jsonSections)
                {
                    if (($jsonContents.$section.PSObject.Properties).Match($key).Count -gt 0)
                    {
                        $jsonValues[$key] = $jsonContents.$section.$key
                    }
                }
            }
            
            $commonRegPath =  $regConstants::CommonConfigRegistryPath -replace "HKEY_LOCAL_MACHINE", "HKLM:"
            $tenantRegPath = ($regConstants::"$($ConfigType)ConfigRegistryPath") -replace "HKEY_LOCAL_MACHINE", "HKLM:"

            :outerLoop foreach($regPath in $commonRegPath, $tenantRegPath)
            {
                foreach ($key in $jsonValues.Keys)
                {
                    $regValue = Test-RegKeyExists -Path $regPath -Name $key -GetValueIfExists -LogFile $LogFile
                    $fileValue = $jsonValues[$key]

                    if ($null -ne $regValue -and $regValue -ne $fileValue)
                    {
                        $rewriteJsonFile = $true
                        Write-Log "[$functionName] Found json file value to registry value discrepancy for $key." -LogFile $LogFile
                        Write-Log "[$functionName] $key Value at $regPath : $regValue" -LogFile $LogFile
                        Write-Log "[$functionName] $key Value at $FilePath : $fileValue" -LogFile $LogFile
                        break outerLoop
                    }
                }
            }

            if ($rewriteJsonFile)
            {
                Write-Log "[$functionName] Regenerating $FilePath based on registry values." -LogFile $LogFile
                Set-TenantConfigJsonFile -ConfigType $ConfigType -FilePath $FilePath -LogFile $LogFile
            }
            else
            {
                Write-Log "[$functionName] No discrepancies found between $filePath and $commonRegPath registry keys." -LogFile $LogFile
            }
        }
        else
        {
            Write-Log "[$functionName] File $FilePath is not present. Nothing to sync." -LogFile $LogFile
        }
    }
    catch
    {
        $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
        Write-Log "[$functionName] Unhandled exception occured: $exceptionDetails" -LogFile $LogFile
    }
}

function Write-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True, ValueFromPipeline)]
        [System.String] $Message,

        [Parameter(Mandatory=$False)]
        [ValidateSet("INFO","WARNING","ERROR","FATAL","DEBUG","VERBOSE")]
        [System.String] $Level = "INFO",

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.SwitchParameter] $WriteToConsole
    )

    if ($global:LogFile -and 
        ([System.String]::IsNullOrWhiteSpace($LogFile) -or [System.String]::IsNullOrEmpty($LogFile))) {
        $LogFile = $global:LogFile
    }

    $dateTimeStamp = [System.DateTime]::UtcNow.ToString("u")
    $formattedMessage = "$dateTimeStamp : $Level : $Message"

    if ($WriteToConsole -or (-not $LogFile)) {
        if (Get-Command Trace-Execution -ErrorAction Ignore) {
            Trace-Execution $formattedMessage
        }
        switch($Level.toUpper()) {
            "INFO" {
                Write-Host $formattedMessage
                break;
            }
            "DEBUG" {
                Write-Debug $formattedMessage
                break;
            }
            "VERBOSE" {
                Write-Verbose $formattedMessage
                break;
            }
            "WARNING" {
                Write-Warning $formattedMessage
                break;
            }
            "ERROR" {
                Write-Error $formattedMessage
                break;
            }
            "FATAL" {
                Write-Error $formattedMessage
                break;
            }
        }
    }

    if ($LogFile) {
        Out-File -FilePath $LogFile -InputObject $formattedMessage -Append -Encoding utf8 
    }
}

function Write-ObservabilityGMAEventSource {
    param(
        [Parameter(Mandatory=$true)]
        [System.String] $Message,

        [Parameter(Mandatory=$False)]
        [ValidateSet("INFO","ERROR")]
        [System.String] $Level = "INFO",

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    Write-Log -Message $Message -Level $Level -LogFile $LogFile

    switch($Level.toUpper()) {
         "INFO" {
                    [Microsoft.AzureStack.Observability.GenevaMonitoringAgent.ObservabilityGMAEventSource]::Log.InfoEvent($Message)
                    break;
                }
         "ERROR" {
                    [Microsoft.AzureStack.Observability.GenevaMonitoringAgent.ObservabilityGMAEventSource]::Log.ErrorEvent($Message)
                    break;
                }
    }
}

function Confirm-IsStringNotEmpty {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $s
    )
    return (-not (Confirm-IsStringEmpty $s))
}

function Confirm-IsStringEmpty {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $s
    )
    return ([System.String]::IsNullOrEmpty($s) -and [System.String]::IsNullOrWhiteSpace($s))
}

function Confirm-ClusterCmdletsAreAvailable {
    try
    {
        return (
        (Confirm-GetAzureStackHciIsAvailable) -and `
        (Confirm-GetClusterIsAvailable) -and `
        (Confirm-GetClusterNodeIsAvailable)
        )
    }
    catch
    {
        return $false
    }
}

function Confirm-GetAzureStackHciIsAvailable {
    return (
        (Get-Command Get-AzureStackHCI -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) -and `
        [System.Convert]::ToString((Get-AzureStackHCI).ClusterStatus).ToLower() -ne "notyet" -and `
        [System.Convert]::ToString((Get-AzureStackHCI).RegistrationStatus).ToLower() -ne "notyet"
    )
}

function Confirm-GetClusterIsAvailable {
    $clusterError = [System.Collections.ArrayList]::new()
    $clusterWarning = [System.Collections.ArrayList]::new()
    return (
        (Get-Command Get-Cluster `
            -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) -and `
        (Get-Cluster `
          -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue `
          -ErrorVariable clusterError `
          -WarningAction $MiscConstants.ErrorActionPreference.SilentlyContinue `
          -WarningVariable clusterWarning) -and `
        $null -eq $clusterError[0] -and `
        $null -eq $clusterWarning[0]
    )
}

function Confirm-GetClusterNodeIsAvailable {
    $clusterNodeError = [System.Collections.ArrayList]::new()
    $clusterNodeWarning = [System.Collections.ArrayList]::new()
    return (
        (Get-Command Get-ClusterNode `
            -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) -and `
        (Get-ClusterNode `
          -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue `
          -ErrorVariable clusterNodeError `
          -WarningAction $MiscConstants.ErrorActionPreference.SilentlyContinue `
          -WarningVariable clusterNodeWarning) -and `
        $null -eq $clusterNodeError[0] -and `
        $null -eq $clusterNodeWarning[0]
    )
}

function Set-ProactiveLogCollectionStatus {
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $DiagnosticLevel,
        
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    $functionName = $MyInvocation.MyCommand.Name
    Write-ObservabilityGMAEventSource "[$functionName] Entering. Params : {DiagnosticLevel = $DiagnosticLevel}" -LogFile $LogFile

    if (-not ((Get-Command Get-ProactiveLogCollectionState -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) -and `
        (Get-Command Enable-ProactiveLogCollection -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue) -and `
        (Get-Command Disable-ProactiveLogCollection -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue))) {
        
        ## Expectation is symlink is present for the path below.
        $diagnosticsInitializerPath = Join-Path -Path "$($env:SystemDrive)\Program Files\WindowsPowerShell\Modules\DiagnosticsInitializer" -ChildPath "DiagnosticsInitializer.psd1"
        Import-Module $diagnosticsInitializerPath | Out-Null
        Write-ObservabilityGMAEventSource "[$functionName] Enable or Disable-ProactiveLogCollection commands not found. Loading DiagnosticsInitializer from $diagnosticsInitializerPath." -LogFile $LogFile
    }
    
    if ($DiagnosticLevel -eq $MiscConstants.HciDiagnosticLevel.Enhanced) {
        if ((Get-ProactiveLogCollectionState -Verbose:$False) -eq $MiscConstants.ProActiveLogCollectionStates.Disabled) {
            Write-ObservabilityGMAEventSource "[$functionName] DiagnosticLevel = $DiagnosticLevel and ProActiveLogCollectionState is $($MiscConstants.ProActiveLogCollectionStates.Disabled). Enabling ProactiveLogCollection." -LogFile $LogFile
            Enable-ProactiveLogCollection | Out-Null
        }
    }
    else {
        if ((Get-ProactiveLogCollectionState -Verbose:$False) -eq $MiscConstants.ProActiveLogCollectionStates.Enabled) {
            Write-ObservabilityGMAEventSource "[$functionName] DiagnosticLevel = $DiagnosticLevel and ProActiveLogCollectionState is $($MiscConstants.ProActiveLogCollectionStates.Enabled). Disabing ProactiveLogCollection." -LogFile $LogFile
            Disable-ProactiveLogCollection | Out-Null
        }
    }

    Write-ObservabilityGMAEventSource "[$functionName] Exiting." -LogFile $LogFile
}

function Get-ContentAsJson {
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $Path
    )
    
    return Get-Content -Path $Path | ConvertFrom-Json
}

function Get-ClusterRegistrationValuesForIdParams {
    Param (
        [Parameter(Mandatory=$true)]
        [System.Object] $IdParamsToFetch
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: {IdParamsToFetch = $($IdParamsToFetch | ConvertTo-Json -Compress)}"

    $clusterRegistrationValues = @{}
    $azureStackHciDetails = Get-AzureStackHCI

    $clusterRegistrationValues[$IdParamsToFetch.DeviceArmResourceUri] = $azureStackHciDetails.AzureResourceUri
    $clusterRegistrationValues[$IdParamsToFetch.StampId] = $azureStackHciDetails.AzureResourceName
    $clusterRegistrationValues[$IdParamsToFetch.ClusterName] = (Get-Cluster).Name
    $clusterRegistrationValues[$IdParamsToFetch.NodeId] = $azureStackHciDetails.AzureResourceName + "-" + (Get-ClusterNode(hostname)).Id

    Write-Log "[$functionName] Exiting. Cluster registration values are as follows: $($clusterRegistrationValues | ConvertTo-Json -Compress)"

    return $clusterRegistrationValues
}
#endregion Functions

#region Exports

## Variable exports
Export-ModuleMember -Variable ErrorConstants
Export-ModuleMember -Variable MiscConstants
Export-ModuleMember -Variable RegistryConstants

## Function exports
Export-ModuleMember -Function Get-ArcAgentResourceId
Export-ModuleMember -Function Get-ArcAgentResourceInfo
Export-ModuleMember -Function Get-ArcAgentVmId
Export-ModuleMember -Function Get-AssemblyVersion
Export-ModuleMember -Function Get-SolutionVersion
Export-ModuleMember -Function Get-ExceptionDetails
Export-ModuleMember -Function Get-MetricsNamespaceRegionMapping
Export-ModuleMember -Function Get-OsBuildVersion
Export-ModuleMember -Function New-ScheduledTaskForObservability
Export-ModuleMember -Function Set-TenantConfigRegistryKeys
Export-ModuleMember -Function Set-TenantConfigJsonFile
Export-ModuleMember -Function Sync-TenantRegKeysAndConfigFile
Export-ModuleMember -Function Set-EnvironmentVariablesForMetrics
Export-ModuleMember -Function Test-RegKeyExists
Export-ModuleMember -Function Write-Log
Export-ModuleMember -Function Write-ObservabilityGMAEventSource
Export-ModuleMember -Function Get-MetricsShoeboxAccountName
Export-ModuleMember -Function Set-GlobalEnvironmentVariable
Export-ModuleMember -Function Confirm-IsStringNotEmpty
Export-ModuleMember -Function Confirm-IsStringEmpty
Export-ModuleMember -Function Confirm-ClusterCmdletsAreAvailable
Export-ModuleMember -Function Confirm-GetAzureStackHciIsAvailable
Export-ModuleMember -Function Confirm-GetClusterIsAvailable
Export-ModuleMember -Function Confirm-GetClusterNodeIsAvailable
Export-ModuleMember -Function Set-ProactiveLogCollectionStatus
Export-ModuleMember -Function Get-ContentAsJson
Export-ModuleMember -Function Get-ClusterRegistrationValuesForIdParams
Export-ModuleMember -Function Test-MetricsSupportedForHCIBuild
#endregion Exports
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCM7hp4ZqvuQ/2f
# m3/aVoqyrF85Pjn/9p4bFBI58URMuaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn+MIIZ+gIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIIvOHIFt0gB6o87fr8t6ZML9S01AaQT4TPs/SoentDbvMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAoF3QRQy6PJON48OZDBeh
# Iu5lRB6pK2ko/aHtgcYM4MFlnsitA2K/NFLLtT4l4bJUicuKm0WwGmzXAsDdRRox
# rI9/twF0KcjsXsTIP2z0PXzXNExUjwRjJb1fVzswSfM+7ALoVwElqbkUKAws1BNO
# zfGtXaU6OKjKqQaqu/O9BYz8gcTlYjLA0tzInONDyH5XQQIHfUTp1DDqiw8XG0Nw
# JNRCZhEe8jU+K5gYSeGmIuvEbabXbm8G06LX5nsYYU9LKwS5oMr4+yhFKcScziZS
# GnsA5hTj7Ts03oJgQ5L05L/0EhqX8Amg7HaThjw6ufDWdawW081gkLZvX0w0m5l9
# a6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBpaks/yZpGRxP4sGBw
# FV3lGh+yBJm3pEmkM4D7BM0d1QIGaetf7Mk3GBMyMDI2MDUwMzE0MzExMC45NzNa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACE7BDNWbPr5XoAAEAAAITMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxN1oXDTI2MTExMzE4
# NDgxN1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjM2MDUtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEA9Jl64LoZxDINSFgz+9KS5Ozv5m548ePVzc9RXWe4T4/Mplfg
# a4eq12RGdp5cVvnjde5vxfq2ax/jnu7vUW4rZN4mOUm5vh+kcYsQlYQ53FwgIB3n
# EjcQHomrG3mZe/ozjFSAr6JbglKtIeAySPzAcFzyAer5lLNUHBEvQMM8BOjMyapC
# vh0xsg4xKFcVEJQLKEfCGBffMZI/amutHFb3CUTZ7aVpG2KHEFUNlZ1vwMKvxXTP
# RDnbwPGzyyqJJznfsLNHQ4vXt2ttS1PeCoGI0hN1Peq8yGsIXM9oocwC06DGNSM/
# 4LAx2uKvwmUn6NwLc0+tmvny6w28rZLejskRfnVWofEv1mWY0jHUnHrwSGBS8gVP
# 9gcBs6P5g0OpJPMfxdUkHXRkcMPPW0hIP8NbW8W5Sup8HuwnSKbjpyAlGBUdM/V5
# rZb0sZmkn714r6ULGK+cLLAN6R3FhX6N0nj64F27LTK2BbS0pJZaXjo0eDNz1Qcx
# eIFLUgF+RBsLYDn8E8cCkexK8Nlt3Gi9zJf55w6UfTZ+kwTMxMqFxh7+Tfx7+aBO
# bZ+nx961AtiqAy7zVV69o/LWRdKPZdvZn9ESyGbTnPfjkBERv22prSlETlRwzP6b
# mEVOKWLWVwxuwh7bUWUuUb1cj93zvttQYGQat5E9ALLJNmlvLKCskB7raLsCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBQTnhBKx+FryphQWMRipH49sMFAOjAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAgmxaJrGqQ2D6UJhZ6Ql2SZFOaNuGbW3LzB+ES+l2
# BB1MJtBRSFdi/hVY33NpxsJQhQ5TLVp0DXYOkIoPQc17rH+IVhemO8jCt+U6I1TI
# w6cR7c+tEo/Jjp6EqEU1c4/mraMjgHhQ+raC/OUAm98A1r4bIPHtsBmLROGmeE5X
# LIFaBIZWHvh2COXITKObXVd5wGtJ1dZZdwaHACXF506jta+uoUdyzAeuNlTPLTrZ
# 8nyhxGwk9Vh6eiDQ7CQMWSSa8DJS9PUXjeoi9vTdS7ZMXqu+tv6Qz3xtoBF5+YFK
# 4uE+miGs90Fxm0VK2lWrmFhjkRl5zyoHOdwG7spNYkDomCPNWIudUQmQYKpt/Hss
# pfcb+xpnWIDQdMzgE8pj1vpwLgWEnH7LtT4dZCeoDo9PK40RxBD8kKJ769ngkEwf
# wCD2EX/MQk79eIvOhpnH12GuVByvaKZk5XZvqtPONNwr8q/qA3877IuWwWgnaeX+
# prpw0dZ/QLtbGGVrgP+TRQjt+2dcZA5P3X4LwANhiPsy0Ol4XCdj7OxBLFvOzsCP
# DPaVnkp+dfDFG+NOBir7aqTJ68622pymg1V+6gc/1RvxC/wgvYyG033ecJqv0On0
# ZRNYr+i/OkwgA3HP1aLD0aHrEpw6lt0263iRkCvrcdcOW8w3jC8TJuaGWyC2S9jE
# jzgwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
# CwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAe
# Fw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGm
# TOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/H
# ZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDc
# wUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62A
# W36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1w
# jjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCG
# MFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ
# 1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP
# 8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFz
# ymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHz
# NgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3
# xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsG
# AQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/
# LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8G
# A1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQw
# VgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9j
# cmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUF
# BwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQEL
# BQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfC
# cTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AF
# vonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l
# 9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn
# 8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5m
# O0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyx
# TkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4
# S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9
# y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM
# +Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhw
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCCAkEC
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAmBE8SCjxgjacmy8/VEdk7NxpR6aggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hu00wIhgPMjAyNjA1MDMx
# MjE3MTdaGA8yMDI2MDUwNDEyMTcxN1owdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aG7TQIBADAKAgEAAgIPKQIB/zAHAgEAAgISYDAKAgUA7aMMzQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQC0AYgtj+UpvwVb2CRr2AkSkCF1ougJpGP5LiZE
# JjCec1AmK86jjf+kkRiHxuyPZosa5p6+1Qaxal5Ga3qHYjOI+8LNRhj4lKblsLe1
# gr0v4B9GbdRwCvDVEj3pWO6BnT/rU0SwQ3TALtdHjCQzdXr/UFkWUiTOGETyhwxo
# /yd/8bcTU9HunRVdXcwPujXLzsQg8s1dFvUoGQtxUlaJg8/7lqaeuL1ljhKc03N0
# 4piwfhdAPEj8QZzq7AB8eiCq5cXfpKx1j1aH0dMeJUyL4/TSS521c/z0zz9qwK6n
# UQw1uD8e+zeD20zeMEjHrtiPTHc6TKdQsikJ0atRPDOfbCq3MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAITsEM1Zs+vlegA
# AQAAAhMwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgUVXRRRCKNeQt+PNjNwqMjL9idLxcqzXe4HJ4
# vCWiCQYwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDM4QltFIUz8J4DjAzP
# 4nVodZvQxYGleUIfp86Oa5xYaDCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACE7BDNWbPr5XoAAEAAAITMCIEIBrfrf4CbKQNVRrzdpPq
# jIdnysAs35FGOLEuYAcU0RZBMA0GCSqGSIb3DQEBCwUABIICALJT1saFACC+9FUK
# qqJ0/iS8wJ5U6SVN1Djy7pup6/FP94HdPx1zmKbnL09BBSKcdLxO5gFz8EHXszJQ
# QauHmAUMLdb4rWaTv9kSAF0Ls51hwguqngXaM7/4IL8ymkXkw7v/sBfa96CWKz6h
# Obfvt3R/Yt1SI6OMsX1QxNFxFUz/5rQEgwCLYZC5R978zPuevvwoQ0M9r/odUJ7R
# Pf5dsRn9fsbafx3iW6WLW5CBuXDuFYMUjal/LXy0FkJxDdVFMJK2BcmsUGreuY0u
# nrpnE8FNB3KmTMTPAUr861KCAMCwigCFpGnlVVIXiQx2fvfPmv7L1LOdklsWan2C
# PNZpsnmyt/VtotBboSoh1fXReQAwSCwoWh+P7M/A3nuzfF9fvHI8Xn8YHFQuN2CC
# xU+qUf3UpHPq105jUStfE90Ec3EnQBkcWGj8nHqtwsGlzOXKOyAxE9cPTgfJHQyg
# CT/+s4idsbDJKFNYlMwCv9f9iAlr1N6xHVcpL1nB/kZjaFTJupNZoiKXvWERjtXA
# uWzyYyRwfa/9aWWB0XQJioAUP0to2AovV/G7Y/xad5yluvGayH/Iv0uzoDOA9lXr
# UT0DGYfvCJW36Db/at8DuDS5+16ELlBH1A8WJqlPRSNozbnyonxPW9+HKJqYOMhu
# KXbjWfCropcwLVlb9UH2vgPW94FE
# SIG # End signature block
