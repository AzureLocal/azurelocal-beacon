##------------------------------------------------------------------
##  <copyright file="SetupHelper.psm1" company="Microsoft">
##    Copyright (C) Microsoft. All rights reserved.
##  </copyright>
##------------------------------------------------------------------

#region Constants
$global:ObsArtifactsPaths = @{
    ## PackageContentPath value will be set by Set-ObsPackageContentPath function.
    ObsExtSetupScripts = @{
        PackageName = "Microsoft.AzureStack.Observability.ObsExtSetupScripts"
        ChildPath = "content"
        PackageContentPath = $null
    }
    GMA = @{
        PackageName = "Microsoft.AzureStack.Observability.GenevaMonitoringAgent"
        ChildPath = "content"
        PackageContentPath = $null
    }
    TestObservability = @{
        PackageName = "Microsoft.AzureStack.Observability.TestObservability"
        ChildPath = "content"
        PackageContentPath = $null
    }
    ObservabilityDeployment = @{
        PackageName = "Microsoft.AzureStack.Observability.ObservabilityDeployment"
        ChildPath = $null ## Explicitly set to null as the package has files in content as well as lib folder.
        PackageContentPath = $null
    }
    FDA = @{
        PackageName = "Microsoft.AzureStack.Observability.FDA.FleetDiagnosticsAgent"
        ChildPath = "content\FleetDiagnosticsAgent"
        PackageContentPath = $null
    }
    MAWatchDog = @{
        PackageName = "Microsoft.AzureStack.Solution.Diagnostics.HCIWatchdog"
        ChildPath = "MAWatchdog"
        PackageContentPath = $null
    }
    SBCClient = @{
        PackageName = "Microsoft.AzureStack.Services.SupportBridgeController.Client"
        ChildPath = $null
        PackageContentPath = $null
    }
    ObservabilityAgent = @{
        PackageName = "Microsoft.AzureStack.SupportBridge.LogCollector.WinService"
        ChildPath = "lib"
        PackageContentPath = $null
    }
    UtcExporter = @{
        PackageName = "Microsoft.Windows.Utc.Exporters.GenevaExporter"
        ChildPath = "runtimes\win10-x64\native"
        PackageContentPath = $null
    }
    NetworkObservability = @{
        PackageName = "Microsoft.AS.Network.Observability.Extension"
        ChildPath = "content"
        PackageContentPath = $null
    }
    WatsonAgent = @{
        PackageName = "AzureEdgeWatsonAgent-retail-amd64"
        ChildPath = "lib\native"
        PackageContentPath = $null
    }
}
#endregion Constants

#region Functions

#region Pre-installation validation functions

function Assert-NoObsGMAProcessIsRunning {
    param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    ## Step 1: Check if MAWatchdog is running? If yes, then stop and unregister the service.
    if (Get-Service $MiscConstants.ObsServiceDetails.WatchdogAgent.Name -ErrorAction SilentlyContinue) {
        ## Unregister watchdog agent service
        Write-Log "[$functionName] Found already running watchdog service. Trying to stop and unregister the service." -LogFile $LogFile

        Stop-ServiceForObservability `
            -ServiceName $MiscConstants.ObsServiceDetails.WatchdogAgent.Name `
            -LogFile $LogFile

        $sleepSeconds = 30
        Write-Log "[$functionName] Letting the process sleep for $sleepSeconds second(s), so that any child processes of the service can shutdown gracefully." -LogFile $logFile
    
        Start-Sleep -Seconds $sleepSeconds

        Unregister-ServiceForObservability `
            -ServiceName $MiscConstants.ObsServiceDetails.WatchdogAgent.Name `
            -LogFile $LogFile
    }
    else {
        Write-Log "[$functionName] No registered watchdog service found." -LogFile $LogFile
    }

    ## Step 2: Now check if MA host processes from a TelemetryAndDiagnostics extension are still running or not.
    $stoppedProcesses = $false
    $runningMAHostProcesses = @()
    $runningMAHostProcesses += Get-Process `
        -Name $MiscConstants.GMAHostProcessNameRegex `
        -ErrorAction SilentlyContinue `
        | Where-Object {
            $_.Path -match $MiscConstants.GMAHostProcessFullPathRegex -and (-not $_.HasExited)
        }

    
    Write-Log "[$functionName] Count of already running MonAgentHost process = $($runningMAHostProcesses.Count)." -LogFile $LogFile

    foreach ($hostProcess in $runningMAHostProcesses) {
        ## Step 3: If yes, stop them
        $procId = $hostProcess.Id
        $procName = $hostProcess.Name
        $procPath = $hostProcess.Path
        Write-Log "[$functionName] $($hostProcess | Stop-Process -Force -PassThru | Out-String)"
        Write-Log "[$functionName] Stopped the process $procName with id: $procId and path: $procPath."
        $stoppedProcesses = $true
    }

    if ($stoppedProcesses)
    {
        $sleepSeconds = 60
        Write-Log "[$functionName] Sleeping for $sleepSeconds second(s), so that child GMA processes can shutdown gracefully." -LogFile $logFile
        Start-Sleep -Seconds $sleepSeconds
    }

    Write-Log "[$functionName] Exiting." -LogFile $LogFile
    return $true
}

function Assert-SufficientDiskSpaceAvailableForGMACache {
    param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $ObsFolderName = $(Get-CacheDirectories).ObservabilityVolume
    if (-not (Test-Path $ObsFolderName -PathType Container)) {
        Write-Log "[$functionName] Checking diskspace as $ObsFolderName folder does not exist." -LogFile $LogFile
        $availableDiskspaceOnSysDrive = ((Get-Volume -DriveLetter $MiscConstants.systemDriveLetter).SizeRemaining) / 1GB
        
        Write-Log "[$functionName] Available diskspace on $($MiscConstants.systemDriveLetter) is $availableDiskspaceOnSysDrive GB." -LogFile $LogFile

        if ($availableDiskspaceOnSysDrive -lt $MiscConstants.AvailableDiskSpaceLimitInGB) {
            ## Update error message with disk space size so we know in the status and Portal.
            $ErrorConstants.InsufficientDiskSpaceForGMACache.Message = $ErrorConstants.InsufficientDiskSpaceForGMACache.Message -f $availableDiskspaceOnSysDrive, $MiscConstants.systemDriveLetter
            return $ErrorConstants.InsufficientDiskSpaceForGMACache.Name
        }
    }
    else {
        Write-Log "[$functionName] As $ObsFolderName folder exists already, skip the diskspace check." -LogFile $LogFile
    }
    
    Write-Log "[$functionName] Exiting." -LogFile $LogFile
    return $true
}

function Invoke-PreInstallationValidation {
    param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    
    $validationFunctionNames = (
        $MiscConstants.ValidationFunctionNames.AssertNoObsGMAProcessIsRunning,
        $MiscConstants.ValidationFunctionNames.AssertSufficientDiskSpaceAvailableForGMACache
    )
    
    Write-Log "[$functionName] Performing pre-installation validation." -LogFile $logFile
    
    foreach($validationFunction in $validationFunctionNames) {
        $validationResult = (Invoke-Expression "$validationFunction -LogFile `'$logFile`'")
        if ($validationResult -ne $true) {
            Write-Log "[$functionName] $validationFunction - $($ErrorConstants.$validationResult.Message)" `
                -LogFile $LogFile -Level $MiscConstants.Level.Error
                
            throw $validationResult
        }

        Write-Log "[$functionName] $validationFunction - $validationResult" -LogFile $LogFile
    }
    
    Write-Log "[$functionName] Pre-installation validation completed successfully." -LogFile $logFile
}
#endregion Pre-installation validation functions

#region GCS functions
function Get-CloudName {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile
    ## Default Cloud.
    $gcsCloudName = $MiscConstants.CloudNames.AzurePublicCloud[1]

    $arcAgentResourceInfo = Get-ArcAgentResourceInfo -LogFile $logFile
    if ($null -ne $arcAgentResourceInfo -and (Confirm-IsStringNotEmpty $arcAgentResourceInfo.cloud)) {
        $gcsCloudName = $arcAgentResourceInfo.cloud
        Write-Log "[$functionName] CloudName from arc agent show = $gcsCloudName." -LogFile $LogFile
    }
    else {
        ## Check if any cloud value is passed through Config settings.
        $publicSettings = Get-HandlerConfigSettings

        if (Confirm-IsStringNotEmpty $publicSettings.cloudName) {
            $gcsCloudName = $publicSettings.cloudName
            Write-Log "[$functionName] CloudName from publicSetting = $($publicSettings.cloudName)." -LogFile $LogFile
        }
    }

    Write-Log "[$functionName] Exiting. GcsCloudName: $gcsCloudName." -LogFile $LogFile
    return $gcsCloudName
}

function Confirm-IsPpeEnvironment
{
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $CloudName,
        
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)" -LogFile $LogFile
    $isPpeEnvironment = $false
    
    ## Check if the environment is PPE.
    $isSddcTestDevice = Test-RegKeyExists -Path $MiscConstants.SddcRegKey.Path -Name $MiscConstants.SddcRegKey.Name -LogFile $LogFile -GetValueIfExists
    if($null -ne $isSddcTestDevice -and $isSddcTestDevice -ne 0) {
        $isPpeEnvironment = $true
        Write-Log "[$functionName] SddcTestDevice reg key is present, setting isPpeEnvironment to true." -LogFile $LogFile
    }
    elseif (Test-RegKeyExists -Path $MiscConstants.CIRegKey.Path -Name $MiscConstants.CIRegKey.Name -LogFile $LogFile) {
        $isPpeEnvironment = $true
        Write-Log "[$functionName] CI reg key is present, setting isPpeEnvironment to true." -LogFile $LogFile
    }
    elseif ($CloudName -in $MiscConstants.CloudNames.AzureCanary -or $CloudName -in $MiscConstants.CloudNames.AzurePPE) {
        $isPpeEnvironment = $true
        Write-Log "[$functionName] CloudName ($CloudName) is in PPE/Canary, setting isPpeEnvironment to true." -LogFile $LogFile
    }
    Write-Log "[$functionName] Exiting. IsPpeEnvironment: $isPpeEnvironment" -LogFile $LogFile
    return $isPpeEnvironment
}

function Get-GcsEnvironmentName {
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $CloudName,
        
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)" -LogFile $LogFile

    ## Default environment value.
    $gcsEnvironmentName = $MiscConstants.GCSEnvironment.Prod

    ## Check if environment is PPE(SDDC, CI).
    $isEnvPpe = Confirm-IsPpeEnvironment -CloudName $CloudName -LogFile $LogFile
    
    ## Check for ARCA
    if (Get-IsArcAEnvironment) {
        $gcsEnvironmentName = $MiscConstants.GCSEnvironment.ArcAProd
        Write-Log "[$functionName] ArcA environment detected, setting gcsEnvironmentName to ArcAProd." -LogFile $LogFile
    }
    ## Check for CloudName and set environment accordingly.
    elseif ($CloudName -in $MiscConstants.CloudNames.AzureUSGovernmentCloud) {
        $gcsEnvironmentName = if ($isEnvPpe) { $MiscConstants.GCSEnvironment.PpeFairfax } else { $MiscConstants.GCSEnvironment.Fairfax }
        Write-Log "[$functionName] CloudName is USGovernmentCloud, PPE: $isEnvPpe, setting gcsEnvironmentName to $gcsEnvironmentName." -LogFile $LogFile
    }
    elseif ($CloudName -in $MiscConstants.CloudNames.AzureChinaCloud) {
        $gcsEnvironmentName = if ($isEnvPpe) { $MiscConstants.GCSEnvironment.PpeMooncake } else { $MiscConstants.GCSEnvironment.Mooncake }
        Write-Log "[$functionName] CloudName is AzureChinaCloud, PPE: $isEnvPpe, setting gcsEnvironmentName to $gcsEnvironmentName." -LogFile $LogFile
    }
    elseif ($CloudName -in $MiscConstants.CloudNames.USNat) {
        $gcsEnvironmentName = if ($isEnvPpe) { $MiscConstants.GCSEnvironment.PpeUSNat } else { $MiscConstants.GCSEnvironment.USNat }
        Write-Log "[$functionName] CloudName is USNat, PPE: $isEnvPpe, setting gcsEnvironmentName to $gcsEnvironmentName." -LogFile $LogFile
    }
    elseif ($CloudName -in $MiscConstants.CloudNames.USSec) {
        $gcsEnvironmentName = if ($isEnvPpe) { $MiscConstants.GCSEnvironment.PpeUSSec } else { $MiscConstants.GCSEnvironment.USSec }
        Write-Log "[$functionName] CloudName is USSec, PPE: $isEnvPpe, setting gcsEnvironmentName to $gcsEnvironmentName." -LogFile $LogFile
    }
    elseif ($isEnvPpe) {
        $gcsEnvironmentName = $MiscConstants.GCSEnvironment.Ppe
        Write-Log "[$functionName] PPE environment detected for CloudName ($CloudName), setting gcsEnvironmentName to Ppe." -LogFile $LogFile
    }
    else {
        Write-Log "[$functionName] Defaulting gcsEnvironmentName to Prod." -LogFile $LogFile
    }

    Write-Log "[$functionName] Exiting. GcsEnvironmentName = $gcsEnvironmentName" -LogFile $LogFile
    return $gcsEnvironmentName
}

function Get-GcsRegionName {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile
    ## Defaulted to eastus region.
    $gcsRegionName = "eastus"

    $arcAgentResourceInfo = Get-ArcAgentResourceInfo -LogFile $logFile
    if ($null -ne $arcAgentResourceInfo -and (Confirm-IsStringNotEmpty $arcAgentResourceInfo.location)) {
        $gcsRegionName = $arcAgentResourceInfo.location
        Write-Log "[$functionName] RegionName from arc agent show = $gcsRegionName." -LogFile $LogFile
    }
    else {
        ## Check if any region value is passed through Config settings, if yes than use that
        $publicSettings = Get-HandlerConfigSettings

        if (Confirm-IsStringNotEmpty $publicSettings.region) {
            $gcsRegionName = $publicSettings.region
            Write-Log "[$functionName] RegionName from publicSetting = $gcsRegionName." -LogFile $LogFile
        }
    }

    Write-Log "[$functionName] Exiting. GCSRegionName: $gcsRegionName." -LogFile $LogFile
    return $gcsRegionName
}
#endregion GCS functions

#region Misc functions
function Get-CacheDirectories {
    Param ()

    $gmaCacheLocation = Join-Path -Path $env:SystemDrive -ChildPath "GMACache"

    return [ordered] @{
        GMACache =              $gmaCacheLocation
        DiagnosticsCache =      Join-Path -Path $gmaCacheLocation -ChildPath "DiagnosticsCache"
        HealthCache =           Join-Path -Path $gmaCacheLocation -ChildPath "HealthCache"
        JsonDropLocation =      Join-Path -Path $gmaCacheLocation -ChildPath "JsonDropLocation"
        MonAgentHostCache =     Join-Path -Path $gmaCacheLocation -ChildPath "MonAgentHostCache"
        MetricsCache =          Join-Path -Path $gmaCacheLocation -ChildPath "MetricsCache"
        TelemetryCache =        Join-Path -Path $gmaCacheLocation -ChildPath "TelemetryCache"

        ObservabilityVolume =   Join-Path -Path $env:SystemDrive -ChildPath "Observability"
    }
}

function New-CacheDirectories {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log "[$functionName] Creating cache directories." -LogFile $LogFile

    $cacheDirectories = Get-CacheDirectories

    foreach ($directory in $cacheDirectories.Values) {
        New-Directory `
            -Path $directory `
            -LogFile $logFile
    }

    Write-Log "[$functionName] Created cache directories." -LogFile $LogFile

    return $cacheDirectories
}

function New-Directory {
    param (
        [Parameter(Mandatory=$True)]
        [System.String] $Path,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log "[$functionName] Directory to create is '$Path'." -LogFile $LogFile
    
    if (Test-Path $Path -PathType Container) {
        Write-Log "[$functionName] Directory '$Path' exists already." -LogFile $LogFile
    }
    else {
        New-Item `
            -Path $Path `
            -ItemType "Directory" `
            -Force `
            -Verbose:$False `
            | Out-Null

        Write-Log "[$functionName] Directory '$Path' created." -LogFile $LogFile
    }
}

function Get-WatchdogStatusFile
{
    param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    $watchdogStatusDirectory = Join-Path -Path $(Get-LogFolderPath) -ChildPath "WatchdogStatus"
    New-Directory -Path $watchdogStatusDirectory -LogFile $LogFile
    return Join-Path -Path $watchdogStatusDirectory -ChildPath $MiscConstants.WatchdogStatusFileName
}

function Get-IsArcAEnvironment {
   return (Test-RegKeyExists -Path $MiscConstants.ArcARegKey.Path -Name $MiscConstants.ArcARegKey.Name -GetValueIfExists -LogFile $LogFile) -eq $true
}

function Get-Sha256Hash {
    Param (
        [Parameter(Mandatory=$true)]
        [System.String] $ClearString
    )

    $hasher = [System.Security.Cryptography.HashAlgorithm]::Create('sha256')
    $hash = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ClearString))
    $hashString = [System.BitConverter]::ToString($hash)
    $hashString = $hashString.Replace('-', '')
    return $hashString
}
#endregion Misc functions

#region UTC setup functions
Function Initialize-UTCSetup {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    try {
        Write-Log `
            -Message "[$functionName] Initializing UTC setup." `
            -LogFile $logFile

        #region Stop diagtrack service
        Stop-ServiceForObservability `
            -ServiceName $MiscConstants.ObsServiceDetails.DiagTrack.Name `
            -LogFile $logFile
        #endregion Stop diagtrack service
    
        ## Create the UTC exporter destination folder (if not present) and copy the UtcGenevaExporter dll in it.
        Write-Log `
            -Message "[$functionName] Create folder for UTCExporterdll and place the respective binary in it." `
            -LogFile $logFile

        $utcExporterDllName = $MiscConstants.UtcExporterDllName
        $utcExporterSourcePath = Join-Path -Path (Get-UtcExporterPackageContentPath) -ChildPath $utcExporterDllName
    
        $utcExporterDestinationDirectory = $MiscConstants.UtcExporterDestinationDirectory
    
        New-Directory `
            -Path $utcExporterDestinationDirectory `
            -LogFile $logFile
    
        Copy-Item `
            -Path $utcExporterSourcePath `
            -Destination $utcExporterDestinationDirectory `
            -Force `
            | Out-Null
    
        $utcExporterDestinationPath = Join-Path -Path $utcExporterDestinationDirectory -ChildPath $utcExporterDllName
    
        if (Test-Path $utcExporterDestinationPath) {
            Write-Log `
                -Message "[$functionName] Successfully copied '$utcExporterDllName' to '$utcExporterDestinationPath'." `
                -LogFile $logFile
        }
        else {
            Write-Log `
                -Message "[$functionName] Failed to copy '$utcExporterDllName' to '$utcExporterDestinationPath'." `
                -LogFile $logFile `
                -Level $MiscConstants.Level.Error
    
            throw $ErrorConstants.CannotCopyUtcExporterDll.Name
        }
    
        #region Create reg keys
        New-RegKey `
            -Path $MiscConstants.DiagTrackExportersRegKeyPath `
            -LogFile $logFile `
            -CreatePathOnly
    
        New-RegKey `
            -Path $MiscConstants.GenevaExporterRegKey.Path `
            -LogFile $logFile `
            -CreatePathOnly
    
        New-RegKey `
            -Path $MiscConstants.DiagTrackRegKey.Path `
            -Name $MiscConstants.DiagTrackRegKey.Name `
            -PropertyType $MiscConstants.DiagTrackRegKey.PropertyType `
            -Value $MiscConstants.DiagTrackRegKey.Value `
            -LogFile $logFile
    
        New-RegKey `
            -Path $MiscConstants.GenevaExporterRegKey.Path `
            -Name $MiscConstants.GenevaExporterRegKey.Name `
            -PropertyType $MiscConstants.GenevaExporterRegKey.PropertyType `
            -Value $utcExporterDestinationPath `
            -LogFile $logFile
    
        New-RegKey `
            -Path $MiscConstants.TestHooksRegKey.Path `
            -Name $MiscConstants.TestHooksRegKey.Name `
            -PropertyType $MiscConstants.TestHooksRegKey.PropertyType `
            -Value $MiscConstants.TestHooksRegKey.Value `
            -LogFile $logFile
    
        New-RegKey `
            -Path $MiscConstants.GenevaExporterRegKey.Path `
            -Name $MiscConstants.GenevaNamespaceRegKey.Name `
            -PropertyType $MiscConstants.GenevaNamespaceRegKey.PropertyType `
            -Value $MiscConstants.GenevaNamespaceRegKey.Value `
            -LogFile $logFile
        #endregion Create reg keys
    
        #region Start diagtrack service
        Start-ServiceForObservability `
            -ServiceName $MiscConstants.ObsServiceDetails.DiagTrack.Name `
            -LogFile $logFile
        #endregion Start diagtrack service
    
        Write-Log `
            -Message "[$functionName] Successfully initialized UTC setup." `
            -LogFile $logFile

    }
    finally {
        if ((Get-Service $MiscConstants.ObsServiceDetails.DiagTrack.Name).Status -eq "Stopped") {
            Write-Log `
                -Message "[$functionName] Starting $($MiscConstants.ObsServiceDetails.DiagTrack.Name) service after it was stopped." `
                -LogFile $LogFile
            
            Start-Service `
                -Name $MiscConstants.ObsServiceDetails.DiagTrack.Name `
                -ErrorAction SilentlyContinue `
                -Verbose:$false `
                | Out-Null
        }
    }
}

Function Clear-UTCSetup {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    try {
        Write-Log `
            -Message "[$functionName] Cleaning up UTC related artifacts." `
            -LogFile $logFile

        #region Stop diagtrack service
        Stop-ServiceForObservability `
            -ServiceName $MiscConstants.ObsServiceDetails.DiagTrack.Name `
            -LogFile $LogFile
        #endregion Stop diagtrack service

        #region Remove UtcExporter dll
        Write-Log `
            -Message "[$functionName] Removing UTCExporterdll file and its folder." `
            -LogFile $LogFile
        
        $utcExporterDestinationPath = Join-Path -Path $MiscConstants.UtcExporterDestinationDirectory -ChildPath $MiscConstants.UtcExporterDllName

        if (Test-Path -Path $utcExporterDestinationPath) {

            Remove-Item `
                -Path $utcExporterDestinationPath `
                -Force `
                -Verbose:$false `
                | Out-Null

            Write-Log `
                -Message "[$functionName] Removed file '$utcExporterDestinationPath'." `
                -LogFile $LogFile


            if ((Get-ChildItem -Path $MiscConstants.UtcExporterDestinationDirectory | Measure-Object).Count -eq 0) {
                Remove-Item `
                    -Path $MiscConstants.UtcExporterDestinationDirectory `
                    -Force `
                    -Verbose:$false `
                    | Out-Null

                Write-Log `
                    -Message "[$functionName] Removed directory '$($MiscConstants.UtcExporterDestinationDirectory)'." `
                    -LogFile $LogFile
            }

            Write-Log `
                -Message "[$functionName] Removed UTCExporterdll file '$utcExporterDestinationPath' and its folder path '$($MiscConstants.UtcExporterDestinationDirectory)'." `
                -LogFile $logFile
        }
        else {
            Write-Log `
                -Message "[$functionName] UTCExporter dll does not exists at path '$utcExporterDestinationPath'. Nothing to remove." `
                -LogFile $logFile
        }
        #endregion Remove UtcExporter dll

        #region Remove reg keys
        Remove-RegKey `
            -Path $MiscConstants.DiagTrackRegKey.Path `
            -Name $MiscConstants.DiagTrackRegKey.Name `
            -LogFile $logFile

        Remove-RegKey `
            -Path $MiscConstants.TestHooksRegKey.Path `
            -Name $MiscConstants.TestHooksRegKey.Name `
            -LogFile $logFile

        Remove-RegKey `
            -Path $MiscConstants.GenevaExporterRegKey.Path `
            -Name $MiscConstants.GenevaExporterRegKey.Name `
            -LogFile $logFile

        Remove-RegKey `
            -Path $MiscConstants.GenevaExporterRegKey.Path `
            -Name $MiscConstants.GenevaNamespaceRegKey.Name `
            -LogFile $logFile

        Remove-RegKey `
            -Path $MiscConstants.GenevaExporterRegKey.Path `
            -LogFile $logFile `
            -RemovePathOnly
        #endregion Remove reg keys

        #region Start diagtrack service
        Start-ServiceForObservability `
            -ServiceName $MiscConstants.ObsServiceDetails.DiagTrack.Name `
            -LogFile $LogFile
        #endregion Start diagtrack service

        Write-Log `
            -Message "[$functionName] Cleaned up artifacts related to UTC setup." `
            -Logfile $logFile
    }
    finally {
        if ((Get-Service $MiscConstants.ObsServiceDetails.DiagTrack.Name).Status -eq "Stopped") {
            Write-Log `
                -Message "[$functionName] Starting $($MiscConstants.ObsServiceDetails.DiagTrack.Name) service after it was stopped." `
                -LogFile $LogFile
            
            Start-Service `
                -Name $MiscConstants.ObsServiceDetails.DiagTrack.Name `
                -ErrorAction SilentlyContinue `
                -Verbose:$false `
                | Out-Null
        }
    }
}
#endregion UTC setup functions

#region VCRuntime setup function
function Install-VCRuntime
{
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $Logfile

    <#
        Validate if there is an already installed version of VCRedist package and if yes, whether it is higher than the one we are installing.
        If higher, then skip installation.
    #>
    foreach ($regKeyPath in $MiscConstants.VCRedistRegKeys.Paths) {
        $installedVCRedistVersion = Test-RegKeyExists -Path $regKeyPath -Name $MiscConstants.VCRedistRegKeys.Name -GetValueIfExists -LogFile $Logfile
        if ($null -ne $installedVCRedistVersion) {
            $installedVCRedistVersion = $installedVCRedistVersion.Replace('v', '') # For e.g. If the version value comes to be "v14.32.31332.00" and to compare it with the file version we need to remove the character 'v'.
            Write-Log "[$functionName] VCRedist is already installed with version: $installedVCRedistVersion." -LogFile $Logfile
            break
        }
    }

    $vcRedistFilePath = Join-Path -Path (Get-VCRuntimePackageContentPath) -ChildPath $MiscConstants.VCRuntimeExeName
    $currentVCRedistFileVersion = (Get-Item $vcRedistFilePath).VersionInfo.FileVersion
    Write-Log "[$functionName] Current VCRedist file ($vcRedistFilePath) version is $currentVCRedistFileVersion." -LogFile $Logfile

    if ($null -eq $installedVCRedistVersion -or $installedVCRedistVersion -lt $currentVCRedistFileVersion) {
        $vcRedistInstallationLogFile = Join-Path $(Get-LogFolderPath) -ChildPath $MiscConstants.VCRedistInstallationLogFileName
        Write-Log "[$functionName] Either the VCRedist is not installed or the installed version is less than current version. Thus, installing VCRedist using following command - $vcRedistFilePath /install /quiet /norestart /log $vcRedistInstallationLogFile" -LogFile $LogFile
        $vcInstall = Start-Process -File $vcRedistFilePath -ArgumentList "/install /quiet /norestart /log $vcRedistInstallationLogFile" -Wait -NoNewWindow -PassThru
        <# Exit codes descriptions (https://learn.microsoft.com/en-us/windows/win32/msi/error-codes):
            0 = Install succeeded.
            3010 = A restart is required to complete the install (Machine reboot is pending).
        #>

        ## Update the error message with Exit code so that it can be visible on the Portal.
        $ErrorConstants.VCRedistInstallFailed.Message = $ErrorConstants.VCRedistInstallFailed.Message -f $vcInstall.ExitCode
        if ($vcInstall.ExitCode -ne 0 -and $vcInstall.ExitCode -ne 3010)
        {
            Write-Log `
                -Message "[$functionName] $($ErrorConstants.VCRedistInstallFailed.Message)" `
                -LogFile $LogFile `
                -Level $MiscConstants.Level.Error
            throw $ErrorConstants.VCRedistInstallFailed.Name
        }
        Write-Log "[$functionName] VC Runtime $vcRedistFilePath successfully installed." -LogFile $LogFile
    }
    else {
        Write-Log "[$functionName] VCRedist is already installed with version $installedVCRedistVersion which is either equal or higher than current vcredist file version of $currentVCRedistFileVersion. Thus, skipping the installation." -LogFile $Logfile
    }

    Write-Log "[$functionName] Exiting." -LogFile $Logfile
}
#endregion VCRuntime setup function

#region Registry functions
function New-RegKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True)]
        [System.String] $Path,

        [Parameter(Mandatory=$False)]
        [System.String] $Name,
        
        [Parameter(Mandatory=$False)]
        [System.String] $PropertyType,
        
        [Parameter(Mandatory=$False)]
        [System.String] $Value,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$False)]
        [System.Management.Automation.SwitchParameter] $CreatePathOnly
    )

    $functionName = $MyInvocation.MyCommand.Name

    if ($CreatePathOnly) {
        if (-not (Test-Path -Path $Path)) {
            New-Item `
                -Path $Path `
                -Force `
                -Verbose:$false `
                | Out-Null
            
            Write-Log `
                -Message "[$functionName] Created RegKey path ($Path)." `
                -LogFile $LogFile
        }
        else {
            Write-Log `
                -Message "[$functionName] RegKey path ($Path) exists already." `
                -LogFile $LogFile
        }
    }
    else {
        $currentValue = Test-RegKeyExists -Path $Path -Name $Name -GetValueIfExists
        if ($currentValue -ne $Value) {
            $out = New-ItemProperty `
                -Path $Path `
                -Name $Name `
                -PropertyType $PropertyType `
                -Value $Value `
                -Force
            if ([System.String]::IsNullOrEmpty($currentValue)) {
                Write-Log `
                    -Message "[$functionName] Created registry key with path ($Path), name ($Name) and value ($Value). Output: $out" `
                    -LogFile $LogFile
            }
            else {
                Write-Log `
                    -Message "[$functionName] Updated registry key with path ($Path), name ($Name) and value ($Value). (Previous value was '$currentValue'.)" `
                    -LogFile $LogFile
            }
        }
        else {
            Write-Log `
                -Message "[$functionName] RegKey path ($Path) and name ($Name) and value ($Value) exists already." `
                -LogFile $LogFile
        }
    }
}

Function Remove-RegKey {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $Path,

        [Parameter(Mandatory=$False)]
        [System.String] $Name,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$False)]
        [System.Management.Automation.SwitchParameter] $RemovePathOnly
    )

    $functionName = $MyInvocation.MyCommand.Name

    if ($RemovePathOnly) {
        if (Test-Path -Path $Path) {
            Remove-Item `
                -Path $Path `
                -Force `
                -Verbose:$false `
                | Out-Null

            Write-Log `
                -Message "[$functionName] Path ($Path) removed successfully." `
                -LogFile $LogFile
        }
        else {
            Write-Log `
                -Message "[$functionName] Path ($Path) does not exists. Nothing to remove" `
                -LogFile $LogFile
        }
    }
    else {
        if (Test-RegKeyExists -Path $Path -Name $Name -LogFile $LogFile) {
            Remove-ItemProperty `
                -Path $Path `
                -Name $Name `
                -Force `
                -Verbose:$false `
                | Out-Null
            
            Write-Log `
                -Message "[$functionName] RegKey path ($Path) and name ($Name) removed successfully." `
                -LogFile $LogFile
        }
        else {
            Write-Log `
                -Message "[$functionName] RegKey path ($Path) and name ($Name) does not exists. Nothing to remove" `
                -LogFile $LogFile
        }
    }
}
#endregion Registry functions

#region Scheduled task functions
function Enable-ObsScheduledTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log `
        -Message "[$functionName] Enabling ObsScheduledTask ($($MiscConstants.ObsScheduledTaskDetails.TaskName))." `
        -LogFile $LogFile

    $taskObject = ScheduledTasks\Get-ScheduledTask `
                    -TaskPath $MiscConstants.ObsScheduledTaskDetails.TaskPath `
                    -TaskName $MiscConstants.ObsScheduledTaskDetails.TaskName `
                    -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue

    if ($null -eq $taskObject) {
        Write-Log `
            -Message "[$functionName] No scheduled task with name ($($MiscConstants.ObsScheduledTaskDetails.TaskName)) was found to enable." `
            -LogFile $LogFile
    }
    else {
        ScheduledTasks\Enable-ScheduledTask `
            -InputObject $taskObject `
            -ErrorAction $MiscConstants.ErrorActionPreference.Stop `
            -Verbose:$false `
            | Out-Null

        Write-Log `
            -Message "[$functionName] Successfully enabled obs scheduled task with name $($taskObject.TaskName) at path $($taskObject.TaskPath)." `
            -LogFile $LogFile
    }
}

function Disable-ObsScheduledTask {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    
    Write-Log "[$functionName] Disabling ObsScheduledTask ($($MiscConstants.ObsScheduledTaskDetails.TaskName))." -LogFile $LogFile

    $taskObject = ScheduledTasks\Get-ScheduledTask `
                    -TaskPath $MiscConstants.ObsScheduledTaskDetails.TaskPath `
                    -TaskName $MiscConstants.ObsScheduledTaskDetails.TaskName `
                    -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue

    if ($null -eq $taskObject) {
        Write-Log "[$functionName] No scheduled task with name $($MiscConstants.ObsScheduledTaskDetails.TaskName) was found to disable." -LogFile $LogFile
    }
    else {
        ScheduledTasks\Disable-ScheduledTask `
            -InputObject $taskObject `
            -ErrorAction $MiscConstants.ErrorActionPreference.Stop `
            -Verbose:$false `
            | Out-Null

        Write-Log "[$functionName] Successfully disabled obs scheduled task with name $($taskObject.TaskName) at path $($taskObject.TaskPath)." -LogFile $LogFile
    }
}

function Remove-ObsScheduledTask {
    param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    $trimmedTaskPath = $MiscConstants.ObsScheduledTaskDetails.TaskPath.TrimEnd('\')
    $tasks = ScheduledTasks\Get-ScheduledTask -TaskPath "$trimmedTaskPath\*" -ErrorAction $MiscConstants.ErrorActionPreference.SilentlyContinue
    if ($tasks)
    {
        foreach($task in $tasks) {
            if($task.TaskName -eq $MiscConstants.ObsScheduledTaskDetails.TaskName) {
                ScheduledTasks\Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false | Out-Null

                Write-Log "[$functionName] Successfully removed scheduled task $($task.TaskName) from path $($task.TaskPath)." -LogFile $LogFile
            }
        }
    }
    else
    {
        Write-Log "[$functionName] Either the path '$trimmedTaskPath' doesn`'t exists or no scheduled tasks found to delete." -LogFile $LogFile
    }
}
#endregion Scheduled task functions

#region Windows service functions
function Register-ServiceForObservability {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True)]
        [System.String] $ServiceName,

        [Parameter(Mandatory=$True)]
        [System.String] $ServiceDisplayName,

        [Parameter(Mandatory=$True)]
        [System.String] $ServiceBinaryFilePath,

        [Parameter(Mandatory=$False)]
        [System.String] $ServiceStartupType = $MiscConstants.WinServiceStartupTypes.Manual,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    try {
        Write-Log "[$functionName] Starting registration of service '$ServiceName'." -LogFile $logFile
        
        Write-Log "[$functionName] Configuring service '$ServiceName' from path '$ServiceBinaryFilePath'" -LogFile $LogFile
        
        if (Get-Service $ServiceName -ErrorAction SilentlyContinue)
        {
            Write-Log "[$functionName] Service '$ServiceName' already registered." -LogFile $LogFile
        }
        else
        {
            New-Service `
                -Name $ServiceName `
                -BinaryPathName $ServiceBinaryFilePath `
                -DisplayName $ServiceDisplayName `
                -StartupType $ServiceStartupType `
                -ErrorAction Stop `
                -Verbose:$false `
                | Out-Null
        }
    
        Write-Log "[$functionName] Registration of service '$ServiceName' with display name '$ServiceDisplayName' completed." -LogFile $logFile
    }
    catch {
        Write-Log "[$functionName] $($ErrorConstants.CannotRegisterService.Message) Service Name: '$ServiceName'. Exception: $_" `
            -LogFile $LogFile -Level $MiscConstants.Level.Error
    
        throw $ErrorConstants.CannotRegisterService.Name
    }
}

function Start-ServiceForObservability {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True)]
        [System.String] $ServiceName,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$False)]
        [int] $Retries = $MiscConstants.Retries
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log "[$functionName] Starting service '$ServiceName'." -LogFile $logFile

    # Start MA Watchdog Agent Service
    $retryCount = $Retries
    $serviceStatus = (Get-Service $ServiceName).Status

    if ($serviceStatus -eq "Running") {
        Write-Log "[$functionName] Service '$ServiceName' running already." -LogFile $LogFile
        
        return
    }

    while(($serviceStatus -ne "Running") -and ($retryCount -gt 0)) {     
        Start-Service $ServiceName `
            -WarningAction SilentlyContinue `
            -WarningVariable $startSvcWarn
        
        if ($null -ne $startSvcWarn) {
            Write-Log "[$functionName] $startSvcWarn" `
                -Level $MiscConstants.Level.Warning -LogFile $LogFile
        }

        Write-Log "[$functionName] Waiting for service '$ServiceName' to start..." -LogFile $LogFile

        Start-Sleep -Seconds 5

        $serviceStatus = (Get-Service $ServiceName).Status
        $retryCount--
    }

    if ($serviceStatus -ne "Running") {
        Write-Log "[$functionName] $($ErrorConstants.CannotStartService.Message) Service Name: '$ServiceName'" `
            -LogFile $LogFile -Level $MiscConstants.Level.Error

        throw $ErrorConstants.CannotStartService.Name
    }

    Write-Log "[$functionName] Successfully started service '$ServiceName'." -LogFile $LogFile
}

Function Switch-ObsServiceStartupType {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True)]
        [System.String] $ServiceName,

        [Parameter(Mandatory=$True)]
        [System.String] $StartupType,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)" -LogFile $LogFile

    $service = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Log "[$functionName] Service '$ServiceName' not found." -LogFile $LogFile
        return
    }

    $out = Set-Service -Name $ServiceName -StartupType $StartupType -PassThru
    Write-Log "[$functionName] Start type for service ($($out.ServiceName))= $($out.StartType)." -LogFile $LogFile

    Write-Log "[$functionName] Exiting." -LogFile $LogFile
}

function Stop-ServiceForObservability {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True)]
        [System.String] $ServiceName,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$False)]
        [int] $Retries = $MiscConstants.Retries
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log "[$functionName] Stopping service '$ServiceName'." -LogFile $logFile

    # Stop MA Watchdog Agent Service
    $retryCount = $Retries

    $service = Get-Service $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Log "[$functionName] Service '$ServiceName' not found." -LogFile $LogFile
        return
    }
    $serviceStatus = $service.Status

    if ($serviceStatus -eq "Stopped") {
        Write-Log "[$functionName] Service '$ServiceName' stopped already." -LogFile $LogFile
        return
    }

    while (($serviceStatus -ne "Stopped") -and ($retryCount -gt 0)) {
        Stop-Service $ServiceName `
            -WarningAction SilentlyContinue `
            -WarningVariable $stopSvcWarn
        
        if ($null -ne $stopSvcWarn) {
            Write-Log "[$functionName] $stopSvcWarn" `
                -Level $MiscConstants.Level.Warning -LogFile $LogFile
        }

        Write-Log "[$functionName] Waiting for service '$ServiceName' to stop..." -LogFile $LogFile

        Start-Sleep -Seconds 5

        $serviceStatus = (Get-Service $ServiceName).Status
        $retryCount--
    }

    if ($serviceStatus -ne "Stopped") {
        Write-Log "[$functionName] $($ErrorConstants.CannotStopService.Message) Service Name: '$ServiceName'" `
            -LogFile $LogFile -Level $MiscConstants.Level.Error

        throw $ErrorConstants.CannotStopService.Name
    }

    Write-Log "[$functionName] Successfully stopped service '$ServiceName'." -LogFile $LogFile
}

Function Unregister-ServiceForObservability {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $ServiceName,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log "[$functionName] Unregistering service '$ServiceName'." -LogFile $LogFile
    
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Stop-ServiceForObservability -ServiceName $ServiceName -LogFile $LogFile
    }

    Write-Log "[$functionName] $(sc.exe delete $ServiceName -Verbose)" -LogFile $LogFile

    Write-Log "[$functionName] Successfully unregistered service '$ServiceName'." -LogFile $LogFile
}
#endregion

#region logman
Function Initialize-LogmanTraceSession {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log `
        -Message "[$functionName] Entering." `
        -LogFile $LogFile

    $logmanCreateResult = $null    
    if (Get-Command logman -ErrorAction SilentlyContinue) {
        $sessionsExistsResult = logman query $MiscConstants.Logman.TraceName
        if ($sessionsExistsResult[1] -eq "Error:" -and $sessionsExistsResult[2] -eq "Data Collector Set was not found.") {
            <# 
            Reference: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logman-create-trace
            
            --v: This flag removes the versioning added by default in the etl files. The version is removed because we need only one file to be present.

            -ow: This flag overwrites the existing file, when the current session is stopped and a new one is started.There is another -a (i.e. append) flag but after adding that, it fails to start the session and so for time being we are using this flag. As we don't expect the customers to be disabling the mandatory extensions oftenly.
            #>
            $logmanCreateResult += logman create trace $MiscConstants.Logman.TraceName -f bincirc -o $MiscConstants.Logman.OutputFilePath -max $MiscConstants.Logman.MaxLogFileSizeInMB --v -ow
            foreach ($guid in $MiscConstants.Logman.ComponentProviderGuids.Values) {
                $logmanCreateResult += logman update trace $MiscConstants.Logman.TraceName -p "{$guid}"
            }

            Write-Log `
                -Message "[$functionName] Successfully created logman trace session for Obs components with Output file path of $($MiscConstants.Logman.OutputFilePath) and max log file size of $($MiscConstants.Logman.MaxLogFileSizeInMB) MB. Results = $($logmanCreateResult | Out-String)" `
                -LogFile $LogFile
        }
        else {
            Write-Log `
                -Message "[$functionName] Logman trace session for Obs components exists already. Result = $($sessionsExistsResult | Out-String)" `
                -LogFile $LogFile
        }
    }
    else {
        Write-Log `
            -Message "[$functionName] Logman command is not available in the OS." `
            -LogFile $LogFile
    }

    Write-Log `
        -Message "[$functionName] Exiting." `
        -LogFile $LogFile
}

Function Start-LogmanTraceSession {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log `
        -Message "[$functionName] Entering." `
        -LogFile $LogFile

    if (Get-Command logman -ErrorAction SilentlyContinue) {
        $logmanStartResult = logman start $MiscConstants.Logman.TraceName

        Write-Log `
            -Message "[$functionName] Started logman trace session for Obs components. Result = $($logmanStartResult | Out-String)" `
            -LogFile $LogFile

        $logmanQueryResult = logman query $MiscConstants.Logman.TraceName
        Write-Log `
            -Message "[$functionName] Logman query result = $($logmanQueryResult | Out-String)" `
            -LogFile $LogFile
    }
    else {
        Write-Log `
            -Message "[$functionName] Logman command is not available in the OS." `
            -LogFile $LogFile
    }


    Write-Log `
        -Message "[$functionName] Exiting." `
        -LogFile $LogFile
}

Function Stop-LogmanTraceSession {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log `
        -Message "[$functionName] Entering." `
        -LogFile $LogFile
    
    if (Get-Command logman -ErrorAction SilentlyContinue) {
        $logmanStopResult = logman stop $MiscConstants.Logman.TraceName

        Write-Log `
            -Message "[$functionName] Logman trace session for Obs components stopped successfully. Result = $($logmanStopResult | Out-String)" `
            -LogFile $LogFile

        $logmanQueryResult = logman query $MiscConstants.Logman.TraceName
        Write-Log `
            -Message "[$functionName] Logman query result = $($logmanQueryResult | Out-String)" `
            -LogFile $LogFile
    }
    else {
        Write-Log `
            -Message "[$functionName] Logman command is not available in the OS." `
            -LogFile $LogFile
    }

    Write-Log `
        -Message "[$functionName] Exiting." `
        -LogFile $LogFile
}

Function Remove-LogmanTraceSession {
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    Write-Log `
        -Message "[$functionName] Entering." `
        -LogFile $LogFile
    
    if (Get-Command logman -ErrorAction SilentlyContinue) {
        $sessionsExistsResult = logman query $MiscConstants.Logman.TraceName
        <#
        Checking the length because if the session exists, it will give an output in array format (as shown below), so we just save it in a variable and count the length of the result. If the session is present it will have this below output.

            ```
            PS C:\sapanc00\FDA\Microsoft.FleetDiagnosticsAgent.Core.2.4.20230613.720> logman query sapancTest

            Name:                 sapancTest
            Status:               Stopped
            Root Path:            C:\
            Segment:              Off
            Schedules:            On
            Segment Max Size:     100 MB
            Run as:               SYSTEM

            Name:                 sapancTest\sapancTest
            Type:                 Trace
            Append:               Off
            Circular:             On
            Overwrite:            On
            Buffer Size:          8
            Buffers Lost:         0
            Buffers Written:      0
            Buffer Flush Timer:   0
            Clock Type:           Performance
            File Mode:            File

            The command completed successfully.
            ```

        But if the session is not present, then output should be as below, where the length of array is just 3.
            
            ```
            PS C:\sapanc00\FDA\Microsoft.FleetDiagnosticsAgent.Core.2.4.20230613.720> logman query sapancTest

            Error:
            Data Collector Set was not found.
            ```
        #>
        if ($sessionsExistsResult.Length -gt 10) {
            $logmanDeleteResult = logman delete $MiscConstants.Logman.TraceName
    
            Write-Log `
                -Message "[$functionName] Successfully deleted logman trace session for Obs components. Result = $($logmanDeleteResult | Out-String)" `
                -LogFile $LogFile

        }
        else {
            Write-Log `
            -Message "[$functionName] Logman trace session for Obs components does not exist. SessionExistsResult = $($sessionsExistsResult | Out-String)" `
            -LogFile $LogFile
        }
    }
    else {
        Write-Log `
            -Message "[$functionName] Logman command is not available in the OS." `
            -LogFile $LogFile
    }

    Write-Log `
        -Message "[$functionName] Exiting." `
        -LogFile $LogFile
}
#endregion logman

#region Observability Symlinks
function Get-SymlinkPaths {

    $symLinkPaths = @{
        DiagnosticsInitializer = @{
            SymLink = "C:\Program Files\WindowsPowerShell\Modules\DiagnosticsInitializer"
            Destination = Join-Path $(Get-ObsAgentPackageContentPath) -ChildPath "DiagnosticsInitializer"
        }
        SBRPClient = @{
            SymLink = "C:\Program Files\SBRPClient"
            Destination = Get-SBCClientPackageContentPath
        }
        ObservabilityAgent = @{
            SymLink = "C:\Program Files\ObsAgent"
            Destination = Get-ObsAgentPackageContentPath
        }
        TestObservability = @{
            SymLink = "C:\Program Files\WindowsPowerShell\Modules\TestObservability"
            Destination = Get-TestObservabilityPackagePath
        }
    }

    return $symLinkPaths
}
function Add-ObservabilitySymLinks
{
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile,

        [Parameter(Mandatory=$False)]
        [System.Management.Automation.SwitchParameter] $TestObsOnly
    )
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $allSymLinkPaths = Get-SymlinkPaths

    if ($TestObsOnly)
    {
        $symLinks = $allSymLinkPaths.GetEnumerator() | Where-Object {$_.Name -ieq "TestObservability"}
    }
    else
    {
        $symLinks = $allSymLinkPaths.GetEnumerator()
    }

    $symLinks | ForEach-Object {
        $symLinkPath = $_.Value.SymLink
        $destination = $_.Value.Destination

        if (-not (Test-Path $symLinkPath)) {
            if (-not (Test-PathIsSymLink -Path $symLinkPath -LogFile $LogFile)) {
                Write-Log "[$functionName] Adding symlink $symLinkPath to path $destination." -LogFile $LogFile
                Write-Log "[$functionName] $(cmd /c mklink /d "$symLinkPath" "$destination")" -LogFile $LogFile
            }
            else {
                Write-Log "[$functionName] Symlink $symLinkPath to path $destination already exists." -LogFile $LogFile
            }
        }
        else {
            Write-Log "[$functionName] Actual folder path to the symlinkPath ($symLinkPath) already exists." -LogFile $LogFile
        }
    }

    Write-Log "[$functionName] Exiting." -LogFile $LogFile
}

function Remove-ObservabilitySymLinks
{
    Param (
        [Parameter(Mandatory=$False)]
        [int] $Retries = $MiscConstants.Retries, 

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $retryCount = $Retries
    $success = $false
    $sleepSeconds = 10
    $allSymLinkPaths = Get-SymlinkPaths

    while ($retryCount -gt 0 -and -not $success)
    {
        try
        {
            $allSymLinkPaths.GetEnumerator() | ForEach-Object {
                $symLinkPath = $_.Value.SymLink
                $destination = $_.Value.Destination
                if (Test-PathIsSymLink -Path $symLinkPath -LogFile $logFile)
                {
                    Write-Log "[$functionName] Removing symlink $symLinkPath to path $destination." -LogFile $LogFile
                    Write-Log "[$functionName] $(cmd /c rmdir "$symLinkPath")" -LogFile $LogFile
                }
            }
            $success = $true

            ## Check if the symlinks are removed successfully
            foreach ($component in $allSymLinkPaths.GetEnumerator())
            {
                $symLinkPath = $component.Value.SymLink
                $destination = $component.Value.Destination
                if (Test-PathIsSymLink -Path $symLinkPath -LogFile $logFile)
                {
                    Write-Log `
                        -Message "[$functionName] Failed to remove symlink $symLinkPath." `
                        -LogFile $LogFile `
                        -Level $MiscConstants.Level.Error
                    $success = $false
                }
            }

            if (-not $success)
            {
                Write-Log `
                    -Message "[$functionName] Retrying after $sleepSeconds seconds." `
                    -LogFile $LogFile `
                    -Level $MiscConstants.Level.Error
                Start-Sleep -Seconds $sleepSeconds
            }
        }
        catch
        {
            Write-Log `
                -Message "[$functionName] Removing symlinks failed with error $_. Retrying after $sleepSeconds seconds." `
                -LogFile $LogFile `
                -Level $MiscConstants.Level.Error
            Start-Sleep -Seconds 10
        }
        $retryCount--
    }

    if ($retryCount -eq 0 -and -not $success)
    {
        $errMsg = "[$functionName] Failed to remove symlinks."
        Write-Log `
            -Message $errMsg `
            -LogFile $LogFile `
            -Level $MiscConstants.Level.Error
    }

    Write-Log "[$functionName] Exiting." -LogFile $LogFile
}

function Test-PathIsSymLink {
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $Path,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    if (Test-Path $Path)
    {
        if ((Get-Item $Path -ErrorAction SilentlyContinue).LinkType -eq "SymbolicLink")
        {
            Write-Log `
                -Message "[$functionName] Path $Path is a SymLink." `
                -LogFile $LogFile
            return $True
        }
    }
    Write-Log `
        -Message "[$functionName] Path $Path is not a SymLink." `
        -LogFile $LogFile
    return $False
}
#endregion Observability Symlinks

#region Identity Parameters from runtime settings
function Get-IdenityParametersFromPublicSettings {
    Param (
        [Parameter(Mandatory=$False)]
        [System.Object] $IdentityParamsToFetch,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering." -LogFile $LogFile

    $retrievedIdParams = @{}
    ## Check if any cloud value is passed through Config settings, if yes than use that
    $publicSettings = Get-HandlerConfigSettings

    foreach ($idParam in $IdentityParamsToFetch.Values) {
        ## Check if any identity value is passed through Config settings, if yes than use that
        if (Confirm-IsStringNotEmpty $publicSettings.$idParam) {
            Write-Log "[$functionName] $idParam value from publicSetting = $($publicSettings.$idParam)." -LogFile $LogFile
            $retrievedIdParams[$idParam] = $publicSettings.$idParam
        }
        else {
            Write-Log "[$functionName] $idParam not found in public settings." -LogFile $LogFile
            $retrievedIdParams[$idParam] = [System.String]::Empty
        }
    }

    Write-Log "[$functionName] Exiting. $($retrievedIdParams | ConvertTo-Json -Compress)." -LogFile $LogFile

    return $retrievedIdParams
}
#endregion Identity Parameters from runtime settings

#region Package Content Path functions

function Get-ObsNugetStorePath {
    [CmdletBinding()]
    Param ()
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."

    if (-not $global:ObsNugetStorePath) {
        Write-Log "[$functionName] global:ObsNugetStorePath is not set. Setting it."
        if (Get-Command Set-ObsNugetStorePath -ErrorAction Ignore) {
            Write-Log "[$functionName] Set-ObsNugetStorePath function is available. Invoking it."
            $obsStoreRootPath = Set-ObsStoreRootFolderPath
            Set-ObsNugetStorePath -ObsStoreRootPath $obsStoreRootPath
        }
        else {
            Write-Log "[$functionName] Set-ObsNugetStorePath function is not available. Setting ObsNugetStorePath manually (i.e. relative to the script path)."
            <#
                Split-Path levels w.r.t. ObsExtSetupScripts package's folder structure:
                L0 - $PSScriptRoot = Helpers folder
                L1 - Split-Path = content
                L2 - Split-Path = Package's name (i.e. Microsoft.AzureStack.Observability.ObsExtSetupScripts.*)
                L3 - Split-Path = ExtVersion folder (i.e. X.X.X.X)
            #>
            $global:ObsNugetStorePath = $PSScriptRoot `
                                        | Split-Path `
                                        | Split-Path `
                                        | Split-Path

            Write-Log "[$functionName] ObsNugetStorePath is set to= $($global:ObsNugetStorePath)"
        }
    }

    Write-Log "[$functionName] Exiting. ObsNugetStorePath = $($global:ObsNugetStorePath)"
    return $global:ObsNugetStorePath
}

function Set-ObsPackageContentPath {
    [CmdletBinding()]
    Param ()
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."

    $nugetStorePath = Get-ObsNugetStorePath

    foreach($nuget in $global:ObsArtifactsPaths.GetEnumerator()) {
        $nugetInfo = $nuget.Value
        
        Write-Log "[$functionName] Setting content path for package ($($nugetInfo.PackageName))."
        $packageArtifact = Get-Package `
                        -Name $nugetInfo.PackageName `
                        -Destination $nugetStorePath

        $nugetInfo.PackageContentPath = Join-Path -Path ([System.IO.Path]::GetDirectoryName($packageArtifact.Source)) -ChildPath $nugetInfo.ChildPath
        Write-Log "[$functionName] Content path of package ($($nugetInfo.PackageName)) = $($nugetInfo.PackageContentPath)"
    }

    Write-Log "[$functionName] Exiting. Successfully set the package content paths."
}

function Get-ExtensionVersion {
    [CmdletBinding()]
    Param ()
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."
    $extensionVersion = ""
    try
    {
        if ($global:extensionRootLocation)
        {
            $extensionVersion = ($global:extensionRootLocation).Split("\")[-1]
            if ($extensionVersion -eq "content")
            {
                # If extensionVersion is content, then Standalone observability pipeline is being used. Set extension version to Standalone<standalone nuget version>.
                $standaloneFolderName = ($global:extensionRootLocation).Split("\")[-2]
                $standalonePattern = "Standalone.*"
                $match = [System.Text.RegularExpressions.Regex]::Match($standaloneFolderName, $standalonePattern)
                if ($match.Success)
                {
                    $extensionVersion = $match.Value
                }
            }
        }
        else
        {
            Write-Log "[$functionName] Extension root location is not set. Getting extension version from ObsNugetStore version path."
            $extensionVersion = (Get-ObsNugetStorePath).Split("\")[-1]
        }
    }
    catch
    {
        Write-Log `
            -Message "[$functionName] Getting extension version failed with error $_" `
            -Level $MiscConstants.Level.Error
    }
    Write-Log "[$functionName] Exiting. ExtensionVersion = $extensionVersion"
    return $extensionVersion
}

function Stop-ExternalMonitoringAgentProcesses
{
    [CmdletBinding()]
    Param ()

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."
    $externalMonitoringProcesses = Get-Process "Mon*" -ErrorAction SilentlyContinue | Where-Object `
    {
        $_.Path -like "*Microsoft.Azure.Geneva.GenevaMonitoring*"
    }
    if ($externalMonitoringProcesses)
    {
        foreach ($process in $externalMonitoringProcesses)
        {
            try
            {
                Write-Log -Message "Found external monitoring agent process: $($process.Name) at $($process.Path) with Id: $($process.Id). Stopping process."
                Stop-Process -Id $process.Id -Force -Confirm:$false
            }
            catch
            {
                Write-Log -Message "Stopping external monitoring agent process: $($process.Name) at $($process.Path) with Id: $($process.Id) failed with error $_" -Level $MiscConstants.Level.Error
            }
        }
    }
}

function Get-FDAPackageContentPath { $global:ObsArtifactsPaths.FDA.PackageContentPath }

Function Get-GmaPackageContentPath { $global:ObsArtifactsPaths.GMA.PackageContentPath }

Function Get-ObsAgentPackageContentPath { $global:ObsArtifactsPaths.ObservabilityAgent.PackageContentPath }

function Get-ObservabilityDeploymentPackagePath { $global:ObsArtifactsPaths.ObservabilityDeployment.PackageContentPath }

function Get-VCRuntimePackageContentPath { "$($global:ObsArtifactsPaths.ObservabilityDeployment.PackageContentPath)\content\VS17" }

function Get-SBCClientPackageContentPath { $global:ObsArtifactsPaths.SBCClient.PackageContentPath }

function Get-TestObservabilityPackagePath  { $global:ObsArtifactsPaths.TestObservability.PackageContentPath }

function Get-UtcExporterPackageContentPath { $global:ObsArtifactsPaths.UtcExporter.PackageContentPath }

function Get-WatchdogPackageContentPath { $global:ObsArtifactsPaths.MAWatchdog.PackageContentPath }

function Get-ObsExtSetupScriptsPackageContentPath { $global:ObsArtifactsPaths.ObsExtSetupScripts.PackageContentPath }

function Get-NetworkObservabilityPackagePath { $global:ObsArtifactsPaths.NetworkObservability.PackageContentPath }

function Get-WatsonAgentPackagePath { $global:ObsArtifactsPaths.WatsonAgent.PackageContentPath }

#endregion Package Content Path functions

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

#endregion Functions

#region Exports

# Pre-installation validation functions
Export-ModuleMember -Function Invoke-PreInstallationValidation

## GCS functions
Export-ModuleMember -Function Get-CloudName
Export-ModuleMember -Function Confirm-IsPpeEnvironment
Export-ModuleMember -Function Get-GcsEnvironmentName
Export-ModuleMember -Function Get-GcsRegionName

## Misc functions
Export-ModuleMember -Function Get-CacheDirectories
Export-ModuleMember -Function New-CacheDirectories
Export-ModuleMember -Function New-Directory
Export-ModuleMember -Function Get-WatchdogStatusFile
Export-ModuleMember -Function Get-IsArcAEnvironment
Export-ModuleMember -Function Get-Sha256Hash
Export-ModuleMember -Function Stop-ExternalMonitoringAgentProcesses

## UTC setup functions
Export-ModuleMember -Function Initialize-UTCSetup
Export-ModuleMember -Function Clear-UTCSetup

## Registry functions
Export-ModuleMember -Function New-RegKey
Export-ModuleMember -Function Remove-RegKey

# VCRuntime setup function
Export-ModuleMember -Function Install-VCRuntime

## Scheduled task functions
Export-ModuleMember -Function Enable-ObsScheduledTask
Export-ModuleMember -Function Disable-ObsScheduledTask
Export-ModuleMember -Function Remove-ObsScheduledTask

## Windows service functions
Export-ModuleMember -Function Register-ServiceForObservability
Export-ModuleMember -Function Start-ServiceForObservability
Export-ModuleMember -Function Switch-ObsServiceStartupType
Export-ModuleMember -Function Stop-ServiceForObservability
Export-ModuleMember -Function Unregister-ServiceForObservability

## logman functions
Export-ModuleMember -Function Initialize-LogmanTraceSession
Export-ModuleMember -Function Start-LogmanTraceSession
Export-ModuleMember -Function Stop-LogmanTraceSession
Export-ModuleMember -Function Remove-LogmanTraceSession

# DiagnosticsInitializer Symlink functions
Export-ModuleMember -Function Get-SymlinkPaths
Export-ModuleMember -Function Add-ObservabilitySymLinks
Export-ModuleMember -Function Remove-ObservabilitySymLinks
Export-ModuleMEmber -Function Test-PathIsSymLink

## Identity Parameters from runtime settings
Export-ModuleMember -Function Get-IdenityParametersFromPublicSettings

## Package Content Path functions
Export-ModuleMember -Function Get-ObsNugetStorePath
Export-ModuleMember -Function Set-ObsPackageContentPath
Export-ModuleMember -Function Get-FDAPackageContentPath
Export-ModuleMember -Function Get-GmaPackageContentPath
Export-ModuleMember -Function Get-ObsAgentPackageContentPath
Export-ModuleMember -Function Get-ObservabilityDeploymentPackagePath
Export-ModuleMember -Function Get-VCRuntimePackageContentPath
Export-ModuleMember -Function Get-SBCClientPackageContentPath
Export-ModuleMember -Function Get-TestObservabilityPackagePath
Export-ModuleMember -Function Get-UtcExporterPackageContentPath
Export-ModuleMember -Function Get-WatchdogPackageContentPath
Export-ModuleMember -Function Get-ObsExtSetupScriptsPackageContentPath
Export-ModuleMember -Function Get-NetworkObservabilityPackagePath
Export-ModuleMember -Function Get-ExtensionVersion
Export-ModuleMember -Function Get-WatsonAgentPackagePath

#endregion Exports

# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDvMcEkW00tdJ/9
# 5UcvRjulYHkl2McWkyGBOE8EgVJfm6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIG+A1ITGynsygCPvulwhHom/OPBNgWVgltYjVnmn45I6MEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAUnhCxdockR7gLqEK1Ukw
# ZdntDbJwc3oHCNAVjzVQRlfbEbnxsVCI0SV+l9gKCLB+RwhCU46TWq6IrEeZlcIG
# w6KNGzJ9BvplxqGMPFr24EEVNbiVoUT5EQplGYxMJ+ehVfdyGTxS5H/xUYrA0Zxv
# 6FhpLzvg/Gz3t8WUCnwf5FOx0xPRnMBHjg4u2OeTDDhdv+6tfhTexxiRK4hQay7y
# YVKUhrw0G+44ozi5LZH9mtcxc1zwunPOcJdlPMN7A3rEr0WzX3fLa8tHeFGpv9s9
# xW894oyORANIJxttk7KU0CXNR9RsbZmvTYmcaT1JwkmqGXiaiquQFM/hWPverqfG
# YqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDtAZADLqxdR02+X/Rd
# gPYAekSNLfQ4nWSxY4NuI1rPhAIGaeugEigDGBMyMDI2MDUwMzE0MzEwOS45ODda
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyQTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACEKvN5BYY7zmwAAEAAAIQMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxMloXDTI2MTExMzE4
# NDgxMlowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjJBMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAjcc4q057ZwIgpKu4pTXWLejvYEduRf+1mIpbiJEMFWWmU2xp
# ip+zK7xFxKGB1CclUXBU0/ZQZ6LG8H0gI7yvosrsPEI1DPB/XccGCvswKbAKckng
# OuGTEPGk7K/vEZa9h0Xt02b7m2n9MdIjkLrFl0pDriKyz0QHGpdh93X6+NApfE1T
# L24Vo0xkeoFGpL3rX9gXhIOF59EMnTd2o45FW/oxMgY9q0y0jGO0HrCLTCZr50e7
# TZRSNYAy2lyKbvKI2MKlN1wLzJvZbbc//L3s1q3J6KhS0KC2VNEImYdFgVkJej4z
# ZqHfScTbx9hjFgFpVkJl4xH5VJ8tyJdXE9+vU0k9AaT2QP1Zm3WQmXedSoLjjI7L
# WznuHwnoGIXLiJMQzPqKqRIFL3wzcrDrZeWgtAdBPbipglZ5CQns6Baj5Mb6a/EZ
# C9G3faJYK5QVHeE6eLoSEwp1dz5WurLXNPsp0VWplpl/FJb8jrRT/jOoHu85qRcd
# YpgByU9W7IWPdrthmyfqeAw0omVWN5JxcogYbLo2pANJHlsMdWnxIpN5YwHbGEPC
# uosBHPk2Xd9+E/pZPQUR6v+D85eEN5A/ZM/xiPpxa8dJZ87BpTvui7/2uflUMJf2
# Yc9ZLPgEdhQQo0LwMDSTDT48y3sV7Pdo+g5q+MqnJztN/6qt1cgUTe9u+ykCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBSe42+FrpdF2avbUhlk86BLSH5kejAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAvs4rO3oo8czOrxPqnnSEkUVq718QzlrIiy7/EW7J
# mQXsJoFxHWUF0Ux0PDyKFDRXPJVv29F7kpJkBJJmcQg5HQV7blUXIMWQ1qX0KdtF
# QXI/MRL77Z+pK5x1jX+tbRkA7a5Ft7vWuRoAEi02HpFH5m/Akh/dfsbx8wOpecJb
# YvuHuy4aG0/tGzOWFCxMMNhGAIJ4qdV87JnY/uMBmiodlm+Gz357XWW5tg3HrtNZ
# XuQ0tWUv26ud4nGKJo/oLZHP75p4Rpt7dMdYKUF9AuVFBwxYZYpvgk12tfK+/yOw
# q84/fjXVCdM83Qnawtbenbk/lnbc9KsZom+GnvA4itAMUpSXFWrcRkqdUQLN+JrG
# 6fPBoV8+D8U2Q2F4XkiCR6EU9JzYKwTuvL6t3nFuxnkLdNjbTg2/yv2j3WaDuCK5
# lSPgsndIiH6Bku2Ui3A0aUo6D9z9v+XEuBs9ioVJaOjf/z+Urqg7ESnxG0/T1dKc
# i7vLQ2XNgWFYO+/OlDjtGoma1ijX4m14N9qgrXTuWEGwgC7hhBgp3id/LAOf9BST
# WA5lBrilsEoexXBrOn/1wM3rjG0hIsxvF5/YOK78mVRGY6Y7zYJ+uXt4OTOFBwad
# Pv8MklreQZLPnQPtiwop4rlLUYaPCiD4YUqRNbLp8Sgyo9g0iAcZYznTuc+8Q8ZI
# rgwwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyQTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAOsyf2b6riPKnnXlIgIL2f53PUsKggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hUrgwIhgPMjAyNjA1MDMw
# NDUxMDRaGA8yMDI2MDUwNDA0NTEwNFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aFSuAIBADAKAgEAAgIP2wIB/zAHAgEAAgITyzAKAgUA7aKkOAIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQC8BD/jbO+hYI1cLwigLLq4vh+KzNiSSPNrYpjK
# 81EmkYyZs5aX5AMRAnKzZrP4zsNFkviAjAjcDcR62MFounzMKMdJW5L/Ak/LXwXt
# M34DfDJQcdZIA42apu7Gxus4gBy4l6dU2LN+j4ltCPCRJhdMPexSSf+OQbx8kO01
# Je3+DWhdgn9pdujhIj8ifSldthlXtNLStB9fWFll8TzvJx6wr8KKMuvcau4DRbnp
# b8VFIDpJYNDEwTAhl9aTGcKSTtPlNK0OXC56AgmwyMbDcy10gMlKbnqlX+/gE2Na
# W74yfYadFJ7YPleyZRz57qTs137kpL9OZd3T9tyb2gqNzRj0MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIQq83kFhjvObAA
# AQAAAhAwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQg4pcVTfv15MwGwVg4G+qd4vzLRxFCWlogK7AQ
# 4h1VQvowgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDD1SHufsjzY59S1iHU
# QY9hnsKSrJPg5a9Mc4YnGmPHxjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEKvN5BYY7zmwAAEAAAIQMCIEIIT70NF/aOTBRnL/Ym5d
# CJI5L5fhiGpS2xzTAo0XyaBPMA0GCSqGSIb3DQEBCwUABIICACFsrwqwmSoW1lgM
# MjIynjOyoGiAeBP6B0rFHrpvhlwAL5yr2xqIypxAj79/XqFT9ufmCQh5sQjgx7sK
# yCplZJIxhfgeUn0uQvK2jHCGZW6AznVJeXLB2K1UtOFVyHprt8eZ6g0ox9x11jRC
# wEbMB850VH1mvLTEQBi0ro+2jb7OMx8x9ytQ1WCgCHD9cYGFkXNtvZ+o/rdDnau/
# 1PdFdqCXrUXwrF7KckugXLDvf+6k79Qw8jic+mbBzybUFQqzmISGAB1VHgdlH8Dw
# KJ4Y8AoYeRoy5H/un5vcGsFAE3UBNcsiSoJw5FUB43ddMET6HQCfc9x1tLN/MiSP
# qgv49+CyI7yhh0Haw1zoksSeLiGaJn3KQFM3dfAiXOwzOpMtGjCwXOTAlqS+0ATt
# 14GwTnZPvRC46LZbBsgCCKeNQa6Let46VCdHU65HaIhibHctznR8bZxL2rBZ2juN
# z3nMiPKn+qR6Nu/eblneZn1F07bRxdUco1gBUZQcAm50vLMENieF/8O+rIpZy4Zt
# QM1LWoOXA94HB/kE7RaNOCreL3fbztBw2HmkPEAy78IoqWK+GcYI0O1V7Qge0uG0
# BKUvFJxvh71k25X8vxOf7kjCC5ca92hFYHLxsyTK9xdEjwKVwokahovC7rWZGALZ
# r39C2hSSlV2QP23jGs2/4f9YUq0y
# SIG # End signature block
