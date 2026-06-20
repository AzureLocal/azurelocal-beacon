##------------------------------------------------------------------
##  <copyright file="ExtensionHelper.psm1" company="Microsoft">
##    Copyright (C) Microsoft. All rights reserved.
##  </copyright>
##------------------------------------------------------------------

#region Imports
Import-Module PackageManagement -Global -DisableNameChecking -Verbose:$false
#endregion Imports

#region Constants
$global:extensionRootLocation = Split-Path -Parent $PSScriptRoot
$global:packageBinPath = Join-Path -Path $global:extensionRootLocation -ChildPath "bin"
## Value will be updated during Set-HandlerLogFile function execution.
$global:LogFile = $null
## Value will be updated by Set-ObsNugetStorePath function execution.
$global:ObsNugetStorePath = $null

$WrapperConstants = @{
    Exception = @{
        ## We throw the error using Name property of the error constant and than catch it in the caller function, where using the name property (same as Key) we retrieve the error message and error code.
        UnhandledException = @{
            Code = 1
            Name = "UnhandledException"
            Message = "An unhandled exception occurred."
        }
        HandlerEnvJsonDoesNotExist = @{
            Code = 2
            Name = "HandlerEnvJsonDoesNotExist"
            Message = "HandlerEnvironment.json file doesn't exist, cannot proceed."
        }
        LogFolderDoesNotExist = @{
            Code = 3
            Name = "LogFolderDoesNotExist"
            Message = "Log folder doesn't exist, cannot proceed."
        }
        StatusFolderDoesNotExist = @{
            Code = 4
            Name = "StatusFolderDoesNotExist"
            Message = "Status folder doesn't exist, cannot proceed."
        }
        ConfigFolderDoesNotExist = @{
            Code = 5
            Name = "ConfigFolderDoesNotExists"
            Message = "Config folder doesn't exist, cannot proceed."
        }
        PackageNotInstalled = @{
            Code = 6
            Name = "PackageNotInstalled"
            Message = "Package ({0}) is not installed at {1}."
        }
        GetPackageCommandNotFound = @{
            Code = 7
            Name = "GetPackageCommandNotFound"
            Message = "Get-Package command not found, cannot proceed."
        }
        HeartBeatFileValueDoesNotExist = @{
            Code = 8
            Name = "HeartBeatFileValueDoesNotExist"
            Message = "Heartbeat file value does not exist in the HandlerEnvironment.json file, cannot proceed."
        }
        NupkgVersionNotFound = @{
            Code = 9
            Name = "NupkgVersionNotFound"
            Message = "Unable to find package version for nupkg ({0}) in path ({1})."
        }
        NupkgFileNotFound = @{
            Code = 10
            Name = "NupkgFileNotFound"
            Message = "Nupkg file not found for {0} in path: {1}"
        }
        NugetStorePathDirectoryNotFound = @{
            Code = 11
            Name = "NugetStorePathDirectoryNotFound"
            Message = "NugetStorePath directory ({0}) was supposed to exist, cannot proceed."
        }
        SetupScriptPathNotFound = @{
            Code = 12
            Name = "SetupScriptPathNotFound"
            Message = "Setup script path ({0}) not found, cannot proceed."
        }
    }

    RequiredObsPackageNames = @{
        ObsExtSetupScripts = "Microsoft.AzureStack.Observability.ObsExtSetupScripts"
        GMA = "Microsoft.AzureStack.Observability.GenevaMonitoringAgent"
        TestObservability = "Microsoft.AzureStack.Observability.TestObservability"
        ObsDeployment = "Microsoft.AzureStack.Observability.ObservabilityDeployment"
        FDA = "Microsoft.AzureStack.Observability.FDA.FleetDiagnosticsAgent"
        MAWatchDog = "Microsoft.AzureStack.Solution.Diagnostics.HCIWatchdog"
        SBCClient = "Microsoft.AzureStack.Services.SupportBridgeController.Client"
        ObsAgent = "Microsoft.AzureStack.SupportBridge.LogCollector.WinService"
        UtcExporter = "Microsoft.Windows.Utc.Exporters.GenevaExporter"
        NetObs = "Microsoft.AS.Network.Observability.Extension"
        WatsonAgent = "AzureEdgeWatsonAgent-retail-amd64"
    }

    NugetDetails = @{
        ProviderName = "Nuget"
    }

    ## One liner constants
    HandlerLogFileName = "ObservabilityExtension.log"
    HandlerEnvFileName = "HandlerEnvironment.json"
}
#endregion Constants

#region Functions

#region Handler Functions
function Get-ConfigSequenceNumber {
    [CmdletBinding()]
    Param()

    if ($null -eq $env:ConfigSequenceNumber) { 0 } else { $env:ConfigSequenceNumber } 
}

function Get-HandlerEnvInfo {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
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

    $envFile = Join-path -Path $global:extensionRootLocation -ChildPath $WrapperConstants.HandlerEnvFileName
    if (-not (Test-Path $envFile -PathType Leaf)) {
        throw $WrapperConstants.Exception.HandlerEnvJsonDoesNotExist.Name
    }

    ## Read handler config
    $envJson = Get-Content -Path $envFile -Raw | ConvertFrom-Json
    if ($envJson -is [System.Array]) {
        $envJson = $envJson[0]
    }
    return $envJson.handlerEnvironment
}

function Get-HandlerHeartBeatFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $handlerEnvInfo = Get-HandlerEnvInfo

    if ($null -eq $handlerEnvInfo.heartbeatFile) {
        throw $WrapperConstants.Exception.HeartBeatFileValueDoesNotExist.Name
    }

    return $handlerEnvInfo.heartbeatFile
}

function Get-HandlerConfigSettings {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    <#
        Sample config json file:
        ------------------------------------------------------------
        {
            "runtimeSettings":
            [
                {
                    "handlerSettings":
                    {
                        "publicSettings":
                        {
                            "region": "eastus",
                            "cloudName": "AzureCanary"
                        }
                    }
                }
            ]
        }
        -----------------------------------------------------------

        Or If you don't want to pass any values, it can be empty as follows:

        { "runtimeSettings": [ { "handlerSettings":{ "publicSettings":{} } } ] }        
    #>

    $functionName = $MyInvocation.MyCommand.Name

    $handlerEnvInfo = Get-HandlerEnvInfo

    if (-not (Test-Path $handlerEnvInfo.configFolder -PathType Container)) {
        Write-Log "[$functionName] $($WrapperConstants.Exception.ConfigFolderDoesNotExist.Message)" `
            -Level "ERROR"

        throw $WrapperConstants.Exception.ConfigFolderDoesNotExist.Name
    }

    $configFile = Get-ChildItem -Path $handlerEnvInfo.configFolder | Sort-Object CreationTime -Descending | Select-Object -First 1
    ## Parse config file to read parameters
    $configJson = Get-Content -Path $configFile.FullName -Raw | ConvertFrom-Json
        
    return $configJson.runtimeSettings[0].handlerSettings.publicSettings
}

function Get-LogFolderPath {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $handlerEnvInfo = Get-HandlerEnvInfo

    if (-not (Test-Path $handlerEnvInfo.logFolder -PathType Container)) {
        throw $WrapperConstants.Exception.LogFolderDoesNotExist.Name
    }

    return $handlerEnvInfo.logFolder
}

function Get-StatusFolderPath {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $handlerEnvInfo = Get-HandlerEnvInfo

    if (-not (Test-Path $handlerEnvInfo.statusFolder -PathType Container)) {
        throw $WrapperConstants.Exception.StatusFolderDoesNotExist.Name
    }

    return $handlerEnvInfo.statusFolder
}

function Get-StatusFilePath {
    [CmdletBinding()]
    Param()

    $configSeqNum = Get-ConfigSequenceNumber
    $statusFolder = Get-StatusFolderPath
    return "$statusFolder\$configSeqNum.status"
}

function Set-HandlerLogFile {
    [CmdletBinding()]
    Param()

    $functionName = $MyInvocation.MyCommand.Name

    if ($null -eq $global:LogFile) {
        $global:LogFile = Join-Path $(Get-LogFolderPath) -ChildPath $WrapperConstants.HandlerLogFileName
        Write-Log "[$functionName] Setting the global:LogFile with the log file path of $($global:LogFile)."
    }
}

function Get-HandlerLogFile {
    [CmdletBinding()]
    Param()

    Set-HandlerLogFile
    return $global:LogFile
}

function Set-Status {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $Name,

        [Parameter(Mandatory=$True)]
        [System.String] $Operation,

        [Parameter(Mandatory=$True)]
        [System.String] $Message,

        [Parameter(Mandatory=$True)]
        [System.String] $Status,

        [Parameter(Mandatory=$True)]
        [System.Int16] $Code
    )
    
    & "$PSScriptRoot\ReportStatus.ps1" `
        -Name $Name `
        -Operation $Operation `
        -Message $Message `
        -Status $Status `
        -Code $Code
}
#endregion Handler Functions

#region Observability Functions
function Set-NugetPackageProvider {
    [CmdletBinding()]
    Param()
    
    $functionName = $MyInvocation.MyCommand.Name

    $providerName = $WrapperConstants.NugetDetails.ProviderName
    $nugetProvider = Get-PackageProvider | Where-Object { $_.Name -eq $providerName }

    if ($null -eq $nugetProvider) {
        Write-Log "[$functionName] Attempting to install $providerName package provider."
        Install-PackageProvider $providerName -Force -ForceBootstrap
    }
    else {
        Write-Log "[$functionName] Package provider $providerName already installed."
    }
}

function Set-AclsForGivenPath {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [System.String] $PathToSetAcls
    )
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)"

    $requiredACLs = @{
        "BUILTIN\Administrators" = "FullControl"
        "Everyone" = "ReadAndExecute"
        # "NT AUTHORITY\SYSTEM" = "FullControl"
    }

    ## Query existing Acls
    $aclObj = Get-Acl $PathToSetAcls

    # Check if required ACLs are missing
    $missingACLs = $requiredACLs.Keys | Where-Object { $_ -notin $aclObj.Access.IdentityReference }

    if ($missingACLs.Count -gt 0) {
        Write-Log "[$functionName] Re-configuring ACLs as some are missing. Missing ACLs = $($missingACLs -join ',')"

        ## Disable inheritance for PathToSetAcls and remove inherited acls
        ## https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection?view=net-8.0
        $aclObj.SetAccessRuleProtection($True, $False)

        ## Remove all existing access rules
        $aclObj.Access | ForEach-Object { $aclObj.RemoveAccessRule($_) } | Out-Null

        ## Re-configure acls
        foreach ($acl in $requiredACLs.GetEnumerator())
        {
            $account = $acl.Name
            $access = $acl.Value

            Write-Log "[$functionName] Give '$access' access to '$account'."

            # 3,0 allows child items of Path to inhertit the acls
            $newAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, $access, 3, 0, "Allow")

            $aclObj.SetAccessRule($newAccessRule)
        }

        ## Finally commit the acls
        Set-Acl -Path $PathToSetAcls -AclObject $aclObj
        Write-Log "[$functionName] ACLs committed for '$PathToSetAcls'."
    }
    else {
        Write-Log "[$functionName] All required ACLs are already present."
    }

    Write-Log "[$functionName] Exiting."
}

function Set-ObsStoreRootFolderPath {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False)]
        [System.Management.Automation.SwitchParameter] $SetAcls
    )
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)"
    
    $obsRootFolderRegKeyPath = "HKLM:\SOFTWARE\Microsoft\AzureStack\Observability"
    $obsRootFolderRegKeyName = "ObsRootFolderPath"
    
    $obsRootFolderPath = $null

    ## Check if ObsStorePath is present in registry
    if (Get-ItemProperty -Path $obsRootFolderRegKeyPath -Name $obsRootFolderRegKeyName -ErrorAction Ignore) {
        $pathFromRegKey = Get-ItemPropertyValue -Path $obsRootFolderRegKeyPath -Name $obsRootFolderRegKeyName -ErrorAction Ignore
        Write-Log "[$functionName] ObsRootFolderPath key found in registry - $pathFromRegKey"

        ## If key is present then check if the directory exists, if not, create a new directory and overwrite the new path in registry.
        if (Test-Path -Path $pathFromRegKey -PathType Container -ErrorAction Ignore) {
            $obsRootFolderPath = $pathFromRegKey
        }
        else {
            Write-Log "[$functionName] Directory not found for path - $pathFromRegKey."
        }
    }
    
    if (-not $obsRootFolderPath) {
        Write-Log "[$functionName] Either ObsRootFolderPath key not found in registry or the path doesn't exists. Create new path and store in registry - $obsRootFolderRegKeyPath."
        
        ## Create the registry key path if it does not exist.
        if (-not (Test-Path -Path $obsRootFolderRegKeyPath -ErrorAction Ignore)) {
            Write-Log "[$functionName] Registry key path not found. Creating registry key path - $obsRootFolderRegKeyPath"
            $out = New-Item -Path $obsRootFolderRegKeyPath -Force
            Write-Log "[$functionName] Registry key path created - $out"
        }

        ## Generate a unique ObsStorePath using last 4 characters of GUID.
        $guidStr = [System.Guid]::NewGuid().ToString()
        $last_4_chars = $guidStr.Substring($guidStr.Length - 4)
        $obsRootFolderPath = "$($env:SystemDrive)\Obs_$last_4_chars"

        ## Create the directory for the path.
        $out = New-Item -Path $obsRootFolderPath -ItemType Directory -Force
        Write-Log "[$functionName] Created directory for path - $out"

        ## Store the path in registry.
        $out = Set-ItemProperty -Path $obsRootFolderRegKeyPath -Name $obsRootFolderRegKeyName -Value $obsRootFolderPath
        Write-Log "[$functionName] Created registry key ($obsRootFolderRegKeyPath\$obsRootFolderRegKeyName) and stored ObsRootFolderPath value ($obsRootFolderPath) - $out."
    }

    if ($SetAcls) {
        ## Set ACLs for the Obs Store Path if it doesn't have the required permissions.
        Set-AclsForGivenPath -PathToSetAcls $obsRootFolderPath
    }

    Write-Log "[$functionName] Exiting. Returning { ObsRootFolderPath = $obsRootFolderPath }"
    return $obsRootFolderPath
}

function Get-ExtVersion {
    [CmdletBinding()]
    Param()
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."
    
    ## Figure out the extension version from env variable.
    $ExtVersion = [System.Environment]::GetEnvironmentVariable("AZURE_GUEST_AGENT_EXTENSION_VERSION")
    if (-not $ExtVersion) {
        ## As a fallback, get the extension version from the extension folder path.
        Write-Log "[$functionName] AZURE_GUEST_AGENT_EXTENSION_VERSION environment variable not found. Setting it from extension folder path."
        $ExtVersion = Split-Path -Leaf $global:extensionRootLocation
        Write-Log "[$functionName] Extension version from extension folder path = $ExtVersion."
    }

    Write-Log "[$functionName] Exiting. Returning { ExtVersion = $ExtVersion }"
    return $ExtVersion
}

function Set-ObsNugetStorePath {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $ObsStoreRootPath,

        [Parameter(Mandatory=$False)]
        [System.String] $ExtVersion,

        [Parameter(Mandatory=$False)]
        [System.String] $WorkloadName,

        [Parameter(Mandatory=$False)]
        [System.Management.Automation.SwitchParameter] $CreatePathIfNotExists
    )
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)"

    if (($null -ne $ExtVersion -and $ExtVersion -in $global:ObsNugetStorePath) -or
        ($null -ne $global:ObsNugetStorePath)) {
        Write-Log "[$functionName] ObsNugetStorePath already set. Exiting."
        return
    }

    $partialNugetStorePath = Join-Path -Path $ObsStoreRootPath -Child "Nugets"

    ## If ExtVersion is not passed, then figure out the extension version that is getting used.
    if (-not $ExtVersion) {
        $ExtVersion = Get-ExtVersion
    }

    ## Set the ObsNugetStorePath with the ext version specific nuget store.
    $global:ObsNugetStorePath = Join-Path -Path $partialNugetStorePath -ChildPath $ExtVersion
    Write-Log "[$functionName] Setting ObsNugetStorePath = $($global:ObsNugetStorePath)."
    
    ## Create the obsNugetStorePath directory if it does not exist.
    if ($CreatePathIfNotExists) {    
        if (-not (Test-Path -Path $global:ObsNugetStorePath -PathType Container)) {
            $out = New-Item -Path $global:ObsNugetStorePath -ItemType Directory -Force
            Write-Log "[$functionName] Created directory for path - $out"
        }
        else {
            Write-Log "[$functionName] Directory already exists for path - $($global:ObsNugetStorePath)."
        }
    }
    else {
        ## Directory must exist for the path.
        Write-Log "[$functionName] Let's confirm whether directory for path exists or not. Path = $($global:ObsNugetStorePath)."
        if (Test-Path -Path $global:ObsNugetStorePath -PathType Container) {
            Write-Log "[$functionName] Confirmed directory exists - $($global:ObsNugetStorePath)."
        }
        elseif ($WorkloadName -eq "Update") {
            ## For Update script, if nuget store based path is not found, then we can fallback to the extension folder path. So for this case, we don't throw an error if NugetStorePath directory is not found.
            Write-Log "[$functionName] Expected directory for workload ($WorkloadName) not found for path - $($global:ObsNugetStorePath)."
        }
        else {
            ## Error message is updated with the path where the directory was supposed to be present.
            $WrapperConstants.Exception.NugetStorePathDirectoryNotFound.Message = $WrapperConstants.Exception.NugetStorePathDirectoryNotFound.Message -f $global:ObsNugetStorePath
            Write-Log "[$functionName] $($WrapperConstants.Exception.NugetStorePathDirectoryNotFound.Message)."
            throw $WrapperConstants.Exception.NugetStorePathDirectoryNotFound.Name
        }
    }
    
    Write-Log "[$functionName] Exiting."
}

function Confirm-PackageExists {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $PackageName,

        [Parameter(Mandatory=$True)]
        [System.String] $SourcePath,

        [Parameter(Mandatory=$False)]
        [System.String] $ProviderName = $WrapperConstants.NugetDetails.ProviderName,

        [Parameter(Mandatory=$False)]
        [System.Management.Automation.SwitchParameter] $ThrowIfNotExists
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)"
    
    $packageExists = Find-Package -Name $PackageName -ProviderName $ProviderName -Source $SourcePath -ErrorAction Ignore

    if (-not $packageExists) {
        if ($ThrowIfNotExists) {
            ## Error message is updated with the package name and path where the nupkg file supposed to be present.
            $WrapperConstants.Exception.NupkgFileNotFound.Message = $WrapperConstants.Exception.NupkgFileNotFound.Message -f $PackageName, $SourcePath
            Write-Log "[$functionName] $($WrapperConstants.Exception.NupkgFileNotFound.Message)" -Level "ERROR"
            throw $WrapperConstants.Exception.NupkgFileNotFound.Name
        }
        else {
            Write-Log "[$functionName] Nupkg file for ($PackageName) not found in source ($SourcePath)."
            return $false
        }
    }

    Write-Log "[$functionName] Exiting. Nupkg file with version $($packageExists.PackageFilename) found at path $($packageExists.Source)."
    return $true
}

function Extract-Package {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.String] $PackageName,

        [Parameter(Mandatory=$True)]
        [System.String] $SourcePath,

        [Parameter(Mandatory=$True)]
        [System.String] $DestinationPath,

        [Parameter(Mandatory=$False)]
        [System.String] $ProviderName = $WrapperConstants.NugetDetails.ProviderName
    )
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)"

    $output = Install-Package `
        -Name $PackageName `
        -Source $SourcePath `
        -Destination $DestinationPath `
        -ProviderName $ProviderName `
        -Force

    Write-Log "[$functionName] Exiting. Successfully installed package. Result = $($output | Select-Object Name, Status, Source, FullPath)."
}

function Install-ObsPackages {
    [CmdletBinding()]
    Param()
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."

    Set-NugetPackageProvider

    ## Check if ZDP package path exists or not.
    $obsZDPPackagePath = "$env:SystemDrive\ObsZDP"
    $zdpPathExists = Test-Path $obsZDPPackagePath -PathType Container -ErrorAction Ignore

    ## Install the nuget packages
    foreach($packageName in $WrapperConstants.RequiredObsPackageNames.Values) {
        Write-Log "[$functionName] Installing package: $packageName from source: $global:packageBinPath."

        if (Confirm-PackageExists -PackageName $packageName -SourcePath $global:packageBinPath -ThrowIfNotExists) {
            Extract-Package `
                -PackageName $packageName `
                -SourcePath $global:packageBinPath `
                -DestinationPath $global:ObsNugetStorePath
        }

        if ($zdpPathExists) {
            Write-Log "[$functionName] Installing package: $packageName from source: $obsZDPPackagePath."
            ## Extract the ZDPd nugets to ObsNugetStorePath.
            ## Note: SourcePath value is different for ZDPd nugets.
            if (Confirm-PackageExists -PackageName $packageName -SourcePath $obsZDPPackagePath) {
                Extract-Package `
                    -PackageName $packageName `
                    -SourcePath $obsZDPPackagePath `
                    -DestinationPath $global:ObsNugetStorePath
            }
        }
    }
    
    Write-Log "[$functionName] Exiting. Successfully installed observability nuget packages."
}

function Uninstall-ObsPackages {
    [CmdletBinding()]
    Param()
    
    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering."

    ## Navigate to the parent directory of ObsNugetStorePath
    $nugetStorePathParent = Split-Path -Parent $global:ObsNugetStorePath

    ## Get all ext versions specific nuget store paths. Sort them in descending order.
    ## For e.g. List all the version folders in the ObsNugetStorePathParent directory (i.e. C:\Obs_XXXX\Nugets\), like 1.0.6.0, 1.0.6.1, 1.0.7.0, etc.
    $allVersionsOfNugetStorePaths = Get-ChildItem -Path $nugetStorePathParent -Directory -Name `
        | ForEach-Object {
            try
            {
                [System.Version] $_
            }
            catch
            {
                Write-Log "[$functionName] invalid version $_ found. Returning 0.0.0.0"
                [System.Version]::new('0.0.0.0')
            }
        } `
        | Sort-Object -Descending
    Write-Log "[$functionName] AllVersionsOfNugetStorePaths = `n$($allVersionsOfNugetStorePaths | Out-String) ."

    ## Keep the latest two versions of the nuget store paths.
    $latestTwoVersions = $allVersionsOfNugetStorePaths | Select-Object -First 2
    Write-Log "[$functionName] LatestTwoVersions = `n$($latestTwoVersions | Out-String) ."
    
    ## Delete N-2 and older versions of the nuget store paths.
    foreach ($version in $allVersionsOfNugetStorePaths) {
        if ($version -notin $latestTwoVersions) {
            $pathToDelete = Join-Path -Path $nugetStorePathParent -ChildPath $version.ToString()
            Write-Log "[$functionName] Deleting directory: $pathToDelete"
            try {
                ## Only when ErrorAction is set to SilentlyContinue, the error is saved in the ErrorVariable. For ErrorAction Ignore, the error is not saved in the ErrorVariable.
                Remove-Item -Path $pathToDelete -Recurse -Force `
                    -ErrorAction SilentlyContinue -ErrorVariable removeItemError
                if ($removeItemError) {
                    ## Just log the error and continue with the next directory deletion.
                    Write-Log "[$functionName] Error occured while deleting directory ($pathToDelete). ErrorDetails: $removeItemError"
                }
                else {
                    Write-Log "[$functionName] Successfully deleted directory: $pathToDelete"
                }
            }
            catch {
                $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
                Write-Log "[$functionName] Failed to delete directory: $pathToDelete. Error: $exceptionDetails" -Level "ERROR"
            }
        }
        else {
            Write-Log "[$functionName] Skipping version ($version) as it is one of the latest two versions."
        }
    }
    
    Write-Log "[$functionName] Exiting. Successfully uninstalled observability nuget packages."
}

function Get-SetupScriptPath {
    [CmdletBinding()]
    Param()

    $functionName = $MyInvocation.MyCommand.Name

    if (-not (Get-Command Get-Package -ErrorAction Ignore)) {
        Write-Log "[$functionName] $($WrapperConstants.Exception.GetPackageCommandNotFound.Message)" -Level "ERROR"
        throw $WrapperConstants.Exception.GetPackageCommandNotFound.Name
    }

    $setupScriptsPackageObj = Get-Package `
                            -Name $WrapperConstants.RequiredObsPackageNames.ObsExtSetupScripts `
                            -Destination $global:ObsNugetStorePath `
                            -ProviderName $WrapperConstants.NugetDetails.ProviderName

    Write-Log "[$functionName] SetupScriptsPackageObj = $($setupScriptsPackageObj)"
    $setupScriptsPackageContentPath = Join-Path -Path ([System.IO.Path]::GetDirectoryName($setupScriptsPackageObj.Source)) -ChildPath "content"
    Write-Log "[$functionName] SetupScriptsPackageContentPath = $($setupScriptsPackageContentPath)"
    $scriptPath = Join-Path -Path $setupScriptsPackageContentPath -ChildPath "Setup-Extension.ps1"
    
    if (-not (Test-Path $scriptPath)) {
        $WrapperConstants.Exception.SetupScriptPathNotFound.Message = $WrapperConstants.Exception.SetupScriptPathNotFound.Message -f $scriptPath
        Write-Log "[$functionName] $($WrapperConstants.Exception.SetupScriptPathNotFound.Message)" -Level "ERROR"
        throw $WrapperConstants.Exception.SetupScriptPathNotFound.Name
    }

    Write-Log "[$functionName] Returning. Successfully found setup scripts path at = $scriptPath"
    return $scriptPath
}

function Get-FileLockProcess {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [System.String] $FilePath,

        [Parameter(Mandatory=$False)]
        [System.String] $LogFile
    )

    $functionName = $MyInvocation.MyCommand.Name

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    if (! $(Test-Path $FilePath)) {
        Write-Log "[$functionName] The path $FilePath was not found! Halting!" -Level "WARNING"
        return
    }

    ##### END Variable/Parameter Transforms and PreRun Prep #####


    ##### BEGIN Main Body #####

    if ($PSVersionTable.PSEdition -eq "Desktop" -or $PSVersionTable.Platform -eq "Win32NT" -or 
    $($PSVersionTable.PSVersion.Major -le 5 -and $PSVersionTable.PSVersion.Major -ge 3)) {
        $CurrentlyLoadedAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies()
    
        $AssembliesFullInfo = $CurrentlyLoadedAssemblies | Where-Object {
            $_.GetName().Name -eq "Microsoft.CSharp" -or
            $_.GetName().Name -eq "mscorlib" -or
            $_.GetName().Name -eq "System" -or
            $_.GetName().Name -eq "System.Collections" -or
            $_.GetName().Name -eq "System.Core" -or
            $_.GetName().Name -eq "System.IO" -or
            $_.GetName().Name -eq "System.Linq" -or
            $_.GetName().Name -eq "System.Runtime" -or
            $_.GetName().Name -eq "System.Runtime.Extensions" -or
            $_.GetName().Name -eq "System.Runtime.InteropServices"
        }
        $AssembliesFullInfo = $AssembliesFullInfo | Where-Object {$_.IsDynamic -eq $False}
  
        $ReferencedAssemblies = $AssembliesFullInfo.FullName | Sort-Object | Get-Unique

        $usingStatementsAsString = @"
        using Microsoft.CSharp;
        using System.Collections.Generic;
        using System.Collections;
        using System.IO;
        using System.Linq;
        using System.Runtime.InteropServices;
        using System.Runtime;
        using System;
        using System.Diagnostics;
"@
        
        $TypeDefinition = @"
        $usingStatementsAsString
        
        namespace MyCore.Utils
        {
            static public class FileLockUtil
            {
                [StructLayout(LayoutKind.Sequential)]
                struct RM_UNIQUE_PROCESS
                {
                    public int dwProcessId;
                    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
                }
        
                const int RmRebootReasonNone = 0;
                const int CCH_RM_MAX_APP_NAME = 255;
                const int CCH_RM_MAX_SVC_NAME = 63;
        
                enum RM_APP_TYPE
                {
                    RmUnknownApp = 0,
                    RmMainWindow = 1,
                    RmOtherWindow = 2,
                    RmService = 3,
                    RmExplorer = 4,
                    RmConsole = 5,
                    RmCritical = 1000
                }
        
                [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
                struct RM_PROCESS_INFO
                {
                    public RM_UNIQUE_PROCESS Process;
        
                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
                    public string strAppName;
        
                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
                    public string strServiceShortName;
        
                    public RM_APP_TYPE ApplicationType;
                    public uint AppStatus;
                    public uint TSSessionId;
                    [MarshalAs(UnmanagedType.Bool)]
                    public bool bRestartable;
                }
        
                [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
                static extern int RmRegisterResources(uint pSessionHandle,
                                                    UInt32 nFiles,
                                                    string[] rgsFilenames,
                                                    UInt32 nApplications,
                                                    [In] RM_UNIQUE_PROCESS[] rgApplications,
                                                    UInt32 nServices,
                                                    string[] rgsServiceNames);
        
                [DllImport("rstrtmgr.dll", CharSet = CharSet.Auto)]
                static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
        
                [DllImport("rstrtmgr.dll")]
                static extern int RmEndSession(uint pSessionHandle);
        
                [DllImport("rstrtmgr.dll")]
                static extern int RmGetList(uint dwSessionHandle,
                                            out uint pnProcInfoNeeded,
                                            ref uint pnProcInfo,
                                            [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
                                            ref uint lpdwRebootReasons);
        
                /// <summary>
                /// Find out what process(es) have a lock on the specified file.
                /// </summary>
                /// <param name="path">Path of the file.</param>
                /// <returns>Processes locking the file</returns>
                /// <remarks>See also:
                /// http://msdn.microsoft.com/en-us/library/windows/desktop/aa373661(v=vs.85).aspx
                /// http://wyupdate.googlecode.com/svn-history/r401/trunk/frmFilesInUse.cs (no copyright in code at time of viewing)
                /// 
                /// </remarks>
                static public List<Int32> WhoIsLocking(string path)
                {
                    // Console.WriteLine("Looking for process handles for file {0}.", path);
                    uint handle;
                    string key = Guid.NewGuid().ToString();
                    var processes = new List<Int32>();
        
                    int res = RmStartSession(out handle, 0, key);
                    if (res != 0) throw new Exception("Could not begin restart session.  Unable to determine file locker.");
        
                    try
                    {
                        const int ERROR_MORE_DATA = 234;
                        uint pnProcInfoNeeded = 0,
                            pnProcInfo = 0,
                            lpdwRebootReasons = RmRebootReasonNone;
        
                        string[] resources = new string[] { path }; // Just checking on one resource.
        
                        res = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);
        
                        if (res != 0) throw new Exception("Could not register resource.");                                    
        
                        //Note: there's a race condition here -- the first call to RmGetList() returns
                        //      the total number of process. However, when we call RmGetList() again to get
                        //      the actual processes this number may have increased.
                        res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);
        
                        if (res == ERROR_MORE_DATA)
                        {
                            // Create an array to store the process results
                            RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
                            pnProcInfo = pnProcInfoNeeded;
        
                            // Get the list
                            res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons);
                            if (res == 0)
                            {
                                processes = new List<Int32>((int)pnProcInfo);
        
                                // Enumerate all of the results and add them to the 
                                // list to be returned
                                for (int i = 0; i < pnProcInfo; i++)
                                {
                                    try
                                    {
                                        processes.Add(processInfo[i].Process.dwProcessId);
                                    }
                                    // catch the error -- in case the process is no longer running
                                    catch (ArgumentException) { }
                                }
                            }
                            else {
                                var exceptionMessage = String.Format("Could not list processes locking file ({0}).", path);
                                throw new Exception(exceptionMessage);
                            }
                        }
                        else if (res != 0) {
                            var exceptionMessage = String.Format("Could not list processes locking file ({0}). Failed to get size of result.", path); 
                            throw new Exception(exceptionMessage);
                        }
                    }
                    finally
                    {
                        RmEndSession(handle);
                    }
        
                    return processes;
                }
            }
        }
"@

            $CheckMyCoreUtilsFileLockUtilLoaded = $CurrentlyLoadedAssemblies | Where-Object {$_.ExportedTypes -like "MyCore.Utils.FileLockUtil*"}
            if ($null -eq $CheckMyCoreUtilsFileLockUtilLoaded) {
                Add-Type -ReferencedAssemblies $ReferencedAssemblies -TypeDefinition $TypeDefinition
            }

            $Result = [MyCore.Utils.FileLockUtil]::WhoIsLocking($FilePath)
        }
        if ($null -ne $PSVersionTable.Platform -and $PSVersionTable.Platform -ne "Win32NT") {
            $lsofOutput = lsof $FilePath

            function Parse-lsofStrings ($lsofOutput, $Index) {
                $($lsofOutput[$Index] -split " " | foreach {
                    if (![String]::IsNullOrWhiteSpace($_)) {
                        $_
                    }
                }).Trim()
            }

            $lsofOutputHeaders = Parse-lsofStrings -lsofOutput $lsofOutput -Index 0
            $lsofOutputValues = Parse-lsofStrings -lsofOutput $lsofOutput -Index 1

            $Result = [pscustomobject]@{}
            for ($i=0; $i -lt $lsofOutputHeaders.Count; $i++) {
                $Result | Add-Member -MemberType NoteProperty -Name $lsofOutputHeaders[$i] -Value $lsofOutputValues[$i]
            }
        }

        return $Result
    
    ##### END Main Body #####

}

Function Close-ProcessHandles {
    [CmdletBinding()]
    Param (        
        [Parameter(Mandatory=$True)]
        [System.String] $FolderPathToClean
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Log "[$functionName] Entering. Params: $($PSBoundParameters | ConvertTo-Json -Compress)"

    ## Get the process handles that are locking files of lower extension version and save the fileName and corresponding ProcessIDs.
    $filesLockedByProcessesDict = @{}
    foreach ($directory in (Get-ChildItem $FolderPathToClean)) {
        Write-Log "[$functionName] Checking process handles inside directory: $($directory.FullName)"
        Get-ChildItem -Path $directory.FullName -Recurse | Where-Object { ! $_.PSIsContainer } | ForEach-Object {
            $filePath = $_.FullName
            try {
                $processHandles = Get-FileLockProcess -FilePath $filePath
                if ($null -ne $processHandles -and $processHandles.Count -gt 0) {
                    $filesLockedByProcessesDict[$filePath] = $processHandles
                }
            }
            catch {
                $exceptionDetails = Get-ExceptionDetails -ErrorObject $_
                Write-Log "[$functionName] Exception occurred for file ($filePath). Exception is as follows: $exceptionDetails"
            }
        }
    }

    if ($filesLockedByProcessesDict.Keys.Count -eq 0) {
        Write-Log "[$functionName] No files found with locked process handles."
    }
    else {
        Write-Log "[$functionName] Files locked by Processes are as follows = $($filesLockedByProcessesDict | ConvertTo-Json -Compress)."

        $currentPID = [System.Diagnostics.Process]::GetCurrentProcess().Id
        Write-Log "[$functionName] Current PID is $currentPID"

        $returnStatusMessage = [System.String]::Empty

        ## Loop through the ProcessIDs and force stop them accordingly (if needed).
        Write-Log "[$functionName] Looping through locked file processes and force stop them accordingly (if needed)."
        ## Maintain a set of stopped processes so we don't stop the same one again
        $stoppedPID = [System.Collections.Generic.HashSet[string]]@()
        foreach ($currentFile in $filesLockedByProcessesDict.Keys) {
            foreach ($procId in $filesLockedByProcessesDict[$currentFile]) {
                if ($procId -eq $currentPID) {
                    ## We do not want to stop the current process, so if the file is locked by the current process, we hope that the process will finish successfully and release the handle.
                    Write-Log "[$functionName] Ignoring file $currentFile as it is used by PID ($procId) which is running the current script."
                } 
                elseif ($stoppedPID.Contains($procId)) {
                    ## We do not want to stop the same process again (and get "PID not found" error)
                    Write-Log "[$functionName] Ignoring PID ($procId) as it was already stopped"
                }
                else {
                    $procDetails = gwmi win32_process | Where-Object {$_.ProcessId -eq $procId} | Select-Object ProcessName, ExecutablePath, CommandLine
                    $fileLockingProcDetails = @{
                        FilePath = $currentFile
                        ProcId = $procId
                        ProcessName = $procDetails.ProcessName
                        ExecutablePath = $procDetails.ExecutablePath
                        CommandLine = $procDetails.CommandLine
                    }
                    Write-Log "[$functionName] Details of file and its locking process = $($fileLockingProcDetails | ConvertTo-Json -Compress)"
                    try {
                        Write-Log "[$functionName] Stopping process $procId = $(Stop-Process -Id $procId -Force -PassThru | Out-String)"
                        $stoppedPID.Add($procId) | Out-Null
                    }
                    catch{
                        $returnStatusMessage += "[$functionName] Cannot stop process $procId due to error $_"
                    }
                }
            }
        }
    }

    Write-Log "[$functionName] Exiting. Return status message = $returnStatusMessage"
    return $returnStatusMessage
}
#endregion Observability Functions

#region Misc Functions
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

function Save-Exception {
    [CmdLetBinding()]
    Param (
        [Parameter(Mandatory=$True)]
        [System.Management.Automation.ErrorRecord] $ErrorObject,
        
        [Parameter(Mandatory=$False)]
        [System.String] $CustomErrorMessage
    )
    
    $functionName = $MyInvocation.MyCommand.Name

    $errorKey = $ErrorObject.ToString()
    $exceptionConstant = $null
    
    if ($global:ErrorConstants -and $global:ErrorConstants.Keys -contains $errorKey) {
        $exceptionConstant = $global:ErrorConstants[$errorKey]
    }
    elseif ($WrapperConstants.Exception.Keys -contains $errorKey) {
        $exceptionConstant = $WrapperConstants.Exception[$errorKey]
    }

    if ($exceptionConstant) {
        $customErrorMessage += $exceptionConstant.Message
        $errorCode = $exceptionConstant.Code
    }
    else {
        $customErrorMessage += "$($WrapperConstants.Exception.UnhandledException.Message) $errorKey"
        $errorCode = $WrapperConstants.Exception.UnhandledException.Code
    }

    $exceptionDetailsAsString = Get-ExceptionDetails -ErrorObject $ErrorObject
    ## Exception details are for logging only.
    Write-Log "[$functionName] $customErrorMessage : $exceptionDetailsAsString" -Level "ERROR"

    return $errorCode, $customErrorMessage
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
#endregion Misc Functions

#region Legacy functions
# Legacy functions are needed for compatability with Action plans that still call these functions

function Get-GmaPackageContentPath { "$PSScriptRoot\Legacy" }

## This import is needed only for legacy support.
Import-Module (Join-Path -Path (Get-GmaPackageContentPath) -ChildPath 'GMATenantJsonHelper.psm1') `
    -DisableNameChecking `
    -Verbose:$false `
    -Global

#endregion Legacy functions

#endregion Functions

#region Exports
## Handler functions
Export-ModuleMember -Function Get-ConfigSequenceNumber
Export-ModuleMember -Function Get-HandlerEnvInfo
Export-ModuleMember -Function Get-HandlerHeartBeatFile
Export-ModuleMember -Function Get-HandlerConfigSettings
Export-ModuleMember -Function Get-LogFolderPath
Export-ModuleMember -Function Get-StatusFolderPath
Export-ModuleMember -Function Get-StatusFilePath
Export-ModuleMember -Function Set-HandlerLogFile
Export-ModuleMember -Function Get-HandlerLogFile
Export-ModuleMember -Function Set-Status

## Observability functions
Export-ModuleMember -Function Set-NugetPackageProvider
Export-ModuleMember -Function Set-AclsForGivenPath
Export-ModuleMember -Function Set-ObsStoreRootFolderPath
Export-ModuleMember -Function Get-ExtVersion
Export-ModuleMember -Function Set-ObsNugetStorePath
Export-ModuleMember -Function Confirm-PackageExists
Export-ModuleMember -Function Extract-Package
Export-ModuleMember -Function Install-ObsPackages
Export-ModuleMember -Function Uninstall-ObsPackages
Export-ModuleMember -Function Get-SetupScriptPath
Export-ModuleMember -Function Get-FileLockProcess
Export-ModuleMember -Function Close-ProcessHandles

## Misc functions
Export-ModuleMember -Function Get-ExceptionDetails
Export-ModuleMember -Function Save-Exception
Export-ModuleMember -Function Write-Log

## Legacy functions
Export-ModuleMember -Function Get-GmaPackageContentPath

#endregion Exports
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDWpkr//r+LSM5J
# 0TTFs5UU+Za40Vj5XdDsZadcpEcvHKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIORnIot
# Tg2I5/N11mUvPYdbGICIZLnbxq0U/PMl1MXmMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEArLHhDUtpnrgfWtCYPVuhUzkPB6aiGiMaKBGOW7op
# 0TNvmQJt0GTwCyYEwIbyR4YdOOCfXS+LYizYB1TLuziwJ7AsmjBYMYS0ayN9FTC1
# 1168DU/MyykSe9qb4tUAccuq1yNl1fl/Wq2RC3s73jPSusjLkuk72FOd8H0vFJR6
# B8L3S6WrTK3wOR+AmX9x4fo9X1sxspO38C68kh6+yoJjqk3ZWi0wfJJlqjRI+e45
# AH6Liu5QPqVbbepgA52DS3wXOGmI9iczD20N42iAnYLTjcdG15x27xPPkAz17BaL
# 3N92x2X97oysCvH/bp2rq0sDWRPhK+zGfWzxeP9pkeXaUaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBonasRlRNaiDodwO9Ob1wplNldqP0ln+PJNChA
# GT/93wIGaegM03V4GBMyMDI2MDUwMzE0MzEwOS45NTZaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiEzwDX70g8hpAABAAAC
# ITANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTRaFw0yNzA1MTcxOTM5NTRaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDbcTACqU1YvRocyWL2PL9fyf/+
# ULs2qK7U1aZsRnDZSnlCr7K7jgA3eFCEJL5BZ7dUTC0DeZepf+ZC+7HEbB4IdzmJ
# fQAUDFFerqY5VTHmQvP2XA3lWSFj740idcGUHglP5H/PbCJU7GAHWP2HdcCjdx1l
# YAo0A+zLI7xwnTQeMyOXX212Eg4UmDPPJgxdTMw6WFVWsBPWRBi5gDixy2s+7R8A
# Dk5lbBBFDB5h0CjrNWIN7uCAzF5g7trrL8nXIKp10mj9RxhcGQ+tlht6VIvdygRV
# TUGdzFB2/nBvJqQ9kxxFltQST70fEdx4TyaKow/f5+BSh4z4/9f7NXIVVTLn/8kc
# JAfRqFmRrrFt3IKby7VrzmYuoQWD0lmNFtGQ57BrJkPrPFAPek1ALtcbb7FH3nQp
# vi8ngz/MFX/+cnmNFWFU29VVLmzB9XvLZxbYvkeett0mh5lfteeN2rEwUyrdrKuf
# z9h2S6pbate+C2h02CrXwSka0x6ezpTmGkIJLFt25ub/UYXNLdHdsxGD6EfckOIo
# JYsm4MS9F/vSqLNHK89I0vTLBngQEp6LIFkINanRT3PtNx3pNKRKJRALc6L6mhW4
# hL4aHL749qPfQ72t5qAMm5xiKYMgJ2WanidRLNuI251JIN7raaeA/2vb0XFkZcIb
# TR1pfQGsco4U0g5tjwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFOYjIs5qa6pfuquP
# yyK1FTr5QDCnMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQA4I/3bkdnTxD2rFum3
# MF8xVKdEkohAObbePrQ+0fr5bRimjz9sVkKT/7gcj4OMcClSYG+IdX6Mp3EYsLHW
# fjvwfzFoeZE+yTbdBj/1VHZQRuCmw6QqeVCTbw2nnS7nBxnWd9oZXbPUpqEawH5D
# qXQaWFgR9A4KWVK/IvXVDMj1PlPCES1P3JonNbdhkkkz49rJuKOm5b7e/BH8loqA
# mXOXRc22yxWVTMWrEp4pslmv8eT7VoY8X/jdKYTPVEXsfmLbVFcqzMuB8vFGfUyW
# sWROS8wgq7lQYfWcYqh7NymoATX+wWYK3zWG7aRciPGUAzznXdf+aHtIWnQLNa5H
# FmSXkiak3fSuprWYZiHhuYjE16hroApcBHpm+8S/kNqhm9WjQX+2BxnYv+Jejy6l
# qTi8fLBLS069WXVw/ptf5IV+FtYl34GvVoeg31UoUmVVZe1SDUJkm9dDXc8l/qBD
# YiAIT2CCsPTyt9XA9JVuHxdP63n7ChvWAO/47QRuCDsUlFJoWwyBwl7jeYpaRVMt
# Qt0iuJMGGjgEaJX1Q/2j8sXURvTceLHDD9ipWt092ZDWMQciDRmhHNFOX1dnjBvk
# /k1UMcg997j5oYznAnSpJvlg/4BP3aVE0h/YH2KgsKbU4NXZHAjJXj2Slqo1C115
# CG6qBZaFkM8W6vPZCm5qnSezOjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjMzMDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQALbEgZZnyYHXJ1DGb5fGjplXptuaCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aGyxzAiGA8y
# MDI2MDUwMzExNDA1NVoYDzIwMjYwNTA0MTE0MDU1WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtobLHAgEAMAoCAQACAglXAgH/MAcCAQACAhOvMAoCBQDtowRHAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBADrGuHPpc7CeLu8TiUQIOPBAH+XX
# ntp7jRQ6kuvBm7pyizTdh3iRKmccniCk7tIGNSi4ChdtPPmfxxgZQ33ThrSIdUad
# M0/EgrFbxfrrV3XZEUwBduweHL62/Kq1K/6banl6KVW/JT/jMbxb+qiIbuU0LY8i
# jJDxYSWfNS+0Cb2zPBgdS1dowQ58xv4jzNOYIjCbZP+r9YXSa/skn8Nc4+qGAw5d
# 1njWKiZq9/VPPWP80hdObwETV+p5vG0UTAH9qxaLhIVCIHcQedEu5juE3dvIBD0K
# 0wU2s2B2ByKk+2+E4AvR8tXGBI+TsWXqR9DvLrzNq7VOjdOOpNDDkntO1UcxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiEz
# wDX70g8hpAABAAACITANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCD/f1zpJgtcGMWbb98cXlhCAU0L
# 7wdiXpqw/WTtC6sy/DCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIADvIQef
# FVUa4BJy8IZywMAvmGSKdUVqEmy9A++PCj1EMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIhM8A1+9IPIaQAAQAAAiEwIgQgIw9s0ghY
# /2NfQQlEyV4KLOoV/KIa0Z1/P1GDErJ2ajIwDQYJKoZIhvcNAQELBQAEggIAYMsx
# dzoRnriPL04LdV7YgMea5+lOWQMiwtRes5zYWg69RJ+x1GwuBlbPvPYf4B8ney0i
# Y7HD7233SoH9OII4MfoRClngs4S5wGe9lsrPuHDIVI5/BzjagFwf6RcDTF+QYNOf
# /sDMx5C2pT2aBpL5TJuxIGYAvvyVZ9RMUoRBdzbRZCS58deuajpWggCuGLhwdsEe
# iPpm530UfAXV2P5iRWJqDf3zeG5LHT5rOyLtzGAoydLJ7CbKHlaZtWZ4crh0fhm1
# ogcYhoKSoGROnFsImH5PPqeL5bZwW0f30Sq0fEJd1KZ3CpXgRFlYiLQX6f1mP2kr
# veCO7i46zXavfQPHvkNDBBYbsRbMypNw13HpspLPpOMmdQlSCdsAqgNHN+EaLVYK
# q8i8jE+3EocK+DSlZxhTAgq2CqHb3R0T5ubG+WULdrlFLmy/u/5n0GNPaLNi8itp
# fUUW0xnnxI1IfcSXBfUWeuzYZ9eNGMeQAvRXNfydlnO/XYkcVj+9qfg+mSvO2RB9
# 39UHsJWM3ct80mf6jJ4yIpiN5V6c2q6aKHeMsiFWdasAWBIddIBK1h9w8iiOsWif
# Vd3N+i/5sDK5GF62T8pJHyZFJWWyy40/czUmHCsyJwLPrX3L+8UFClEKUHLvzn1w
# T325cIm/R+aCsvA3OAN/0RVV/4hSUuicTU7T5EU=
# SIG # End signature block
