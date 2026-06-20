##------------------------------------------------------------------
##  <copyright file="Install-StandaloneObservability.ps1" company="Microsoft">
##    Copyright (C) Microsoft. All rights reserved.
##  </copyright>
##------------------------------------------------------------------

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium", PositionalBinding = $false, DefaultParameterSetName = "DefaultSet")]
param(
    [Parameter(Mandatory = $true)]
    [System.String] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [System.String] $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [System.String] $TenantId,

    [Parameter(Mandatory=$false)]
    [System.String] $RegistrationRegion = "eastus",

    [Parameter(Mandatory = $true, ParameterSetName = "DefaultSet")]
    [PSCredential] $RegistrationCredential,

    [Parameter(Mandatory = $true, ParameterSetName = "Interactive")]
    [Switch] $Interactive,

    [Parameter(Mandatory = $true, ParameterSetName = "PassThrough")]
    [Switch] $PassThrough,

    [Parameter(Mandatory = $true, ParameterSetName = "AccessToken")]
    [System.String] $AccessToken,

    [Parameter(Mandatory = $true, ParameterSetName = "ServicePrincipal")]
    [PSCredential] $RegistrationSPCredential,

    [Parameter(Mandatory=$true)]
    [System.String] $FactoryLogShare,

    [Parameter(Mandatory=$false)]
    [System.String] $ClusterName,

    [Parameter(Mandatory=$false)]
    [System.String] $ObsRootFolderPath = "C:\StandaloneObservability",

    [Parameter(Mandatory=$false)]
    [Switch] $ParseOnce,

    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [System.String] $InstanceGuid,

    [Parameter(Mandatory=$false)]
    [System.String] $Cloud = "AzureCloud",

    [Parameter(Mandatory=$false)]
    [System.String] $GcsRegion = "eastus",

    [Parameter(Mandatory=$false)]
    [System.Boolean] $SkipArcForServer = $false,

    [Parameter(Mandatory=$false)]
    [System.String] $TenantJsonOverridePath,

    [Parameter(Mandatory=$false)]
    [Int] $CacheFlushWaitTimeInSec = 600,

    [Parameter(Mandatory=$false)]
    [Switch] $Cleanup,

    [Parameter(Mandatory=$false)]
    [Nullable[Int]] $LogParsingEngineTimeoutInMinutes
)

    Import-Module "$PSScriptRoot\GMATenantJsonHelper.psm1" -Force
    Import-Module "$PSScriptRoot\ExtensionHelper.psm1" -Force
    Import-Module "$PSScriptRoot\SetupHelper.psm1" -Force
    Import-Module "$PSScriptRoot\StandaloneObservabilityHelper.psm1" -Force
    Import-Module "$PSScriptRoot\StandaloneObservabilityConstants.psm1" -Force

try {
    $ErrorActionPreference = "Stop"
    $functionName = $MyInvocation.MyCommand.Name

    # Track paths with pre-existing content before installation (for cleanup warnings)
    $cleanupPathsWithPriorContent = @()
    if ($Cleanup) {
        $cleanupPaths = Get-StandalonePipelineCleanupPaths
        $cleanupPathsWithPriorContent = @($cleanupPaths | Where-Object { Test-Path -Path $_ })
        
        # Release file locks on Obs_XXXX paths before installation (contains nuget packages with locked files)
        foreach ($standaloneNugetPath in $cleanupPathsWithPriorContent | Where-Object { $_ -like "*\Obs_*" })
        {
            Write-Host "[$functionName] Running Close-ProcessHandles.ps1 script on $standaloneNugetPath. This will take a few minutes."
            & "$PSScriptRoot\Close-ProcessHandles.ps1" -FolderPathToClean $standaloneNugetPath | Out-Null
        }
    }

    if ([string]::IsNullOrEmpty($ClusterName)) {
        Write-Host "[$functionName] ClusterName is empty. Setting it to computer name $($env:COMPUTERNAME)"
        $ClusterName = $env:COMPUTERNAME
    }

    if(-not (Test-Path -Path $ObsRootFolderPath -PathType Container))
    {
        Write-Host "[$functionName] ObsRootFolderPath '$ObsRootFolderPath' is not present. Creating it."
        New-Item -Path $ObsRootFolderPath -ItemType Directory -Force
    }

    Add-Type -Path "$PSScriptRoot\Microsoft.AzureStack.Observability.ObservabilityCommon.dll"

    ## Create pre-requisites for Extension
    New-GmaStateFolders -ObsRootFolderPath $ObsRootFolderPath
    Set-HandlerEnvInfo -ObsRootFolderPath $ObsRootFolderPath -CloudName $Cloud -RegionName $RegistrationRegion

    ## Determine GCS environment based on device type and cloud
    $isSddcTestDevice = Test-RegKeyExists -Path $MiscConstants.SddcRegKey.Path -Name $MiscConstants.SddcRegKey.Name -LogFile $LogFile -GetValueIfExists
    $isCIEnv = Test-RegKeyExists -Path "HKLM:\Software\Microsoft\SQMClient\" -Name "IsCIEnv"
    $isArcA = Confirm-IsArcAEnvironment

    if ($isArcA) {
        if ($isCIEnv) {
            $gcsEnvironment = "ArcAPpe"
        }
        elseif ($Cloud.ToLower() -eq "azurecloud") {
            $gcsEnvironment = "ArcAProd"
        }
        elseif ($Cloud.ToLower() -eq "azureusgovernment") {
            $gcsEnvironment = "ArcAFairfax"
        }
        else {
            $message = "Unknown Arc-A cloud: $Cloud. Please check the value of Cloud parameter."
            Write-Host "[$functionName] Error: $message"
            throw $message
        }
    }
    else {
        if ($isCIEnv) {
            $gcsEnvironment = "Ppe"
        }
        elseif ($null -ne $isSddcTestDevice -and $isSddcTestDevice -ne 0) {
            $gcsEnvironment = "Ppe"
        }
        else {
            $gcsEnvironment = "Prod"
        }
    }

    Write-Host "[$functionName] Using gcsEnvironment value $gcsEnvironment."

    $envInfoFilePath = "$PSScriptRoot\EnvironmentInfo.json"
    $tenantInfoContent = Get-Content $envInfoFilePath -Raw | ConvertFrom-Json
    $envInfo = $tenantInfoContent.$gcsEnvironment

    # Settings from EnvironmentInfo.json
    $gcsEndpoint = $envInfo.EndPoint
    $gcsAccount = $envInfo.Account
    $genevaConfigVersion = $envInfo.ConfigVersion

    ## Install Azure Connected Machine agent
    $StampId = Set-StampGuid
    $resourceName = "$(hostname)-$StampId"

    if ($skipArcForServer -eq $false) {
        Write-Host "[$functionName] Azure identity is not enabled. Going to install Arc for server agent."

        if(-not (Get-Module -Name Az.Accounts -ListAvailable)) {
            Install-Module -Name Az.Accounts -AllowClobber -Force
        }

        if ($PSCmdlet.ParameterSetName -eq "ServicePrincipal") {
            Connect-AzAccount -Credential $RegistrationSPCredential -ServicePrincipal -Environment $Cloud -Tenant $TenantId -Subscription $SubscriptionId
            Install-AzureConnectedMachineAgent -ResourceName $resourceName -ResourceGroupName $ResourceGroupName -TenantId $TenantId `
                                                -RegionName $RegistrationRegion -SubscriptionId $SubscriptionId -Cloud $Cloud `
                                                -StampId $StampId -RegistrationSPCredential $RegistrationSPCredential
        }
        elseif ($PSCmdlet.ParameterSetName -eq "Interactive") {
            Connect-AzAccount -UseDeviceAuthentication -Environment $Cloud -Tenant $TenantId -Subscription $SubscriptionId
            $token = Get-AzAccessTokenAsPlainText
            Install-AzureConnectedMachineAgent -ResourceName $resourceName -ResourceGroupName $ResourceGroupName -TenantId $TenantId `
                                                -RegionName $RegistrationRegion -SubscriptionId $SubscriptionId -Cloud $Cloud `
                                                -StampId $StampId -AccessToken $token
        }
        elseif ($PSCmdlet.ParameterSetName -eq "PassThrough") {
            $token = Get-AzAccessTokenAsPlainText
            Install-AzureConnectedMachineAgent -ResourceName $resourceName -ResourceGroupName $ResourceGroupName -TenantId $TenantId `
                                                -RegionName $RegistrationRegion -SubscriptionId $SubscriptionId -Cloud $Cloud `
                                                -StampId $StampId -AccessToken $token
        }
        elseif ($PSCmdlet.ParameterSetName -eq "AccessToken") {
            Install-AzureConnectedMachineAgent -ResourceName $resourceName -ResourceGroupName $ResourceGroupName -TenantId $TenantId `
                                                -RegionName $RegistrationRegion -SubscriptionId $SubscriptionId -Cloud $Cloud `
                                                -StampId $StampId -AccessToken $AccessToken
        }
        else {
            Connect-AzAccount -Credential $RegistrationCredential -Environment $Cloud -Tenant $TenantId -Subscription $SubscriptionId
            $token = Get-AzAccessTokenAsPlainText
            Install-AzureConnectedMachineAgent -ResourceName $resourceName -ResourceGroupName $ResourceGroupName -TenantId $TenantId `
                                                -RegionName $RegistrationRegion -SubscriptionId $SubscriptionId -Cloud $Cloud `
                                                -StampId $StampId -AccessToken $token
        }
    }

    ## Start Pipeline installation using Extension Install interface
    $deviceArmResourceUri = $PipelineConstants.DeviceArmUriFormat -f $SubscriptionId, $ResourceGroupName, $resourceName
    ## TODO: Add arcResourceUri
    # $arcResourceUri = $PipelineConstants.ArcResourceUriFormat -f $SubscriptionId, $ResourceGroupName, $resourceName
    $osBuild = Get-OsBuildVersion
    $extensionVersion = Get-ExtensionVersion
    $logFile = Get-HandlerLogFile
    Set-StandaloneScenarioRegistry -ErrorAction Stop
    $configTypes = @([Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Telemetry, [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.Contract.TenantConfigType]::Diagnostics)
    foreach($configType in $configTypes)
    {
        $gcsNameSpace = $envInfo.Namespaces.$configType
        [Microsoft.AzureStack.Observability.ObservabilityCommon.TenantConfigGenerator.TenantConfigRegistrySetter]::Current.SetTenantConfigRegistryKeys(
        $configType,
        "1.0",
        "AuthMSIToken",
        $gcsEndpoint,
        $gcsAccount,
        $gcsNameSpace,
        $GcsRegion,
        $genevaConfigVersion,
        $LocalPath,
        "true",
        "true",
        $GcsRegion,
        $deviceArmResourceUri,
        $StampId,
        $ClusterName,
        $osBuild,
        "1.0",
        $resourceName,
        $deviceArmResourceUri,
        # $arcResourceUri,
        $ClusterName,
        [string]::Empty,
        $extensionVersion)
    }

    $versionVariableName = $PipelineConstants.ExtVerEnvironment.VariableName
    $versionVariableValue = $PipelineConstants.ExtVerEnvironment.VariableValue
    Write-Host "[$functionName] Setting environment variable $versionVariableName to $versionVariableValue for extension script."
    [System.Environment]::SetEnvironmentVariable(
        $versionVariableName,
        $versionVariableValue,
        [System.EnvironmentVariableTarget]::Process)

    Write-Host "[$functionName] Starting Install-Extension script with DeviceArmResourceUri: $deviceArmResourceUri StampId: $StampId ClusterName: $ClusterName CloudName: $Cloud RegistrationRegion: $RegistrationRegion"

    # Start-Job to avoid persisting Add-Type of ObservabilityDeployment.dll during extension installation
    $argumentList = @($PSScriptRoot, $versionVariableName, $versionVariableValue)
    $obsAgentPackagePath = ""
    try
    {
        $job = Start-Job -ArgumentList $argumentList -ScriptBlock {
            param(
                [Parameter(Mandatory=$true)]
                [System.String] $ScriptRoot,

                [Parameter(Mandatory=$true)]
                [System.String] $VersionVariableName,

                [Parameter(Mandatory=$true)]
                [System.String] $VersionVariableValue
            )
            [System.Environment]::SetEnvironmentVariable(
                $VersionVariableName,
                $VersionVariableValue,
                [System.EnvironmentVariableTarget]::Process)

            # Import ExtensionHelper to access Get-StatusFilePath function
            Import-Module "$ScriptRoot\ExtensionHelper.psm1" -Force -DisableNameChecking

            # Run Install-Extension.ps1
            (& "$ScriptRoot\Install-Extension.ps1" -ErrorAction Stop) | Out-Null
            
            # Check status after Install-Extension.ps1
            $statusFilePath = Get-StatusFilePath
            if (Test-Path $statusFilePath) {
                $statusContent = Get-Content $statusFilePath -Raw | ConvertFrom-Json
                $latestStatus = $statusContent | Sort-Object { [DateTime]$_.timestampUTC } | Select-Object -Last 1
                
                if ($latestStatus.status.code -ne 0) {
                    $errorMessage = "Install-Extension.ps1 failed. Operation: $($latestStatus.status.operation), Message: $($latestStatus.status.formattedMessage.message)"
                    Write-Error $errorMessage
                    throw $errorMessage
                }
                else {
                    Write-Host "Install-Extension.ps1 completed successfully. Operation: $($latestStatus.status.operation)"
                }
            }
            else {
                Write-Warning "Status file not found at $statusFilePath after Install-Extension.ps1 execution"
            }

            # Run Enable-Extension.ps1  
            (& "$ScriptRoot\Enable-Extension.ps1" -ErrorAction Stop) | Out-Null
            
            # Check status after Enable-Extension.ps1
            if (Test-Path $statusFilePath) {
                $statusContent = Get-Content $statusFilePath -Raw | ConvertFrom-Json
                $latestStatus = $statusContent | Sort-Object { [DateTime]$_.timestampUTC } | Select-Object -Last 1
                
                if ($latestStatus.status.code -ne 0) {
                    $errorMessage = "Enable-Extension.ps1 failed. Operation: $($latestStatus.status.operation), Message: $($latestStatus.status.formattedMessage.message)"
                    Write-Error $errorMessage
                    throw $errorMessage
                }
                else {
                    Write-Host "Enable-Extension.ps1 completed successfully. Operation: $($latestStatus.status.operation)"
                }
            }
            else {
                Write-Warning "Status file not found at $statusFilePath after Enable-Extension.ps1 execution"
            }

            return Get-ObsAgentPackageContentPath
        } | Wait-Job -Timeout 900
        $obsAgentPackagePath = $job | Receive-Job
    }
    finally
    {
        $job | Remove-Job -Force
    }

    if ($TenantJsonOverridePath)
    {
        $destinationPath = "C:\GMACache\JsonDropLocation\AEODiagnostics.json"
        Write-Host "[$functionName] Diagnostics Json Path has been provided: $TenantJsonOverridePath. Copying it to $destinationPath"
        Copy-Item -Path $TenantJsonOverridePath -Destination $destinationPath -Force
    }
    # Sleep for sometime and check for GCS Config
    Wait-ForGcsConfigSync -TimeInSeconds 180 -LogFile $logFile

    ## Emit the instance guid telemetry event.
    if ($InstanceGuid) {
        Write-InstanceGuidEvent -InstanceGuidValue $InstanceGuid
    }
    else {
        Write-Host "[$functionName] InstanceGuid value is empty, not emitting its telemetry event."
    }

    $transcriptFolderPath = Join-Path -Path $(Get-LogFolderPath) -ChildPath $PipelineConstants.TranscriptsFolderName

    # Install ETW Manifests on Arc-A stamps only
    if (Confirm-IsArcAEnvironment) {
        Write-Host "[$functionName] Installing ETW Manifests on Arc-A host."
        $installManifestsScript = Join-Path -Path $PSScriptRoot -ChildPath "Install-EtwManifests.ps1"
        & $installManifestsScript
    }

    # Unzip .zip and .tar.gz files at $FactoryLogShare
    Get-ChildItem -Path $FactoryLogShare -Recurse -Filter "*.zip" | Where-Object { $_.Name -notmatch "etl.zip|dtr.zip" } | ForEach-Object {
        $destination = "$($_.DirectoryName)\$($_.BaseName)"
        $zipFile = $_.FullName
        try
        {
            Write-Host "[$functionName] Extracting $zipFile to $destination"
            Expand-Archive -Path $zipFile -DestinationPath $destination -Force
        }
        catch
        {
            Write-Host "[$functionName] Error encountered extracting $zipFile to $($destination): $_"
        }
    }
    if (Get-Command tar -ErrorAction SilentlyContinue)
    {
        Get-ChildItem -Path $FactoryLogShare -Recurse -Filter "*.tar.gz" | ForEach-Object {
            $destination = "$($_.DirectoryName)\$($_.BaseName)"
            $zipFile = $_.FullName
            try
            {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Write-Host "[$functionName] Extracting $zipFile to $destination"
                tar -xzf $zipFile -C $destination
            }
            catch
            {
                Write-Host "[$functionName] Error encountered extracting $zipFile to $($destination): $_"
            }
        }
        Get-ChildItem -Path $FactoryLogShare -Recurse -Filter "*.tar" | ForEach-Object {
            $zipFile = $_.FullName
            $destination = "$($_.DirectoryName)\$($_.BaseName)"
            try
            {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Write-Host "[$functionName] Extracting $zipFile to $destination"
                tar -xf $zipFile -C $destination
            }
            catch
            {
                Write-Host "[$functionName] Error encountered extracting $zipFile to $($destination): $_"
            }
        }
    }
    else
    {
        Write-Host "[$functionName] tar command not found. Skipping extraction of .tar.gz files."
    }

    $parsingEnginePath = Join-Path -Path $obsAgentPackagePath -ChildPath "LogParsingEngine"
    $parsingEngineScript = Join-Path -Path $PSScriptRoot -ChildPath "Invoke-ParsingEngine.ps1"

    if($ParseOnce)
    {
        ## Run ParsingEngine with given log location
        Write-Host "[$functionName] Starting Parser script: $parsingEngineScript -FactorySharePath $FactoryLogShare -ParsingEnginePackagePath $parsingEnginePath -TranscriptFolderPath $transcriptFolderPath -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes -ParseOnce"

        & $parsingEngineScript -FactorySharePath $FactoryLogShare `
                                -ParsingEnginePackagePath $parsingEnginePath `
                                -TranscriptFolderPath $transcriptFolderPath `
                                -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes `
                                -ParseOnce `
                                -ErrorAction Stop
    }
    else
    {
        ## Create ParsingEngine scheduled tasks
        $scriptArguments = "-TaskName $($PipelineConstants.ParserScheduledTaskName) -FactorySharePath $FactoryLogShare -ParsingEnginePackagePath $parsingEnginePath -TranscriptFolderPath $transcriptFolderPath -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes"
        Write-Host "[$functionName] Creating Parser scheduled task with arguments: $scriptArguments"

        New-ScheduledTaskForObservability -TaskName $PipelineConstants.ParserScheduledTaskName `
                                    -TaskPath $PipelineConstants.ParserScheduledTaskPath `
                                    -Description $PipelineConstants.ParserScheduledTaskDescription `
                                    -ScriptPath $parsingEngineScript `
                                    -ScriptArguments $scriptArguments `
                                    -DisableOnRegistration `
                                    -ErrorAction Stop

        ScheduledTasks\Enable-ScheduledTask -TaskPath $PipelineConstants.ParserScheduledTaskPath `
        -TaskName $PipelineConstants.ParserScheduledTaskName `
        -ErrorAction Stop
    }

    Set-Status -Name $functionName `
                -Operation "Log parsing succeeded" `
                -Message "[$functionName] Successfully completed log parsing using Standalone Observability pipeline components." `
                -Status "success" `
                -Code 0

    Write-Host "[$functionName] Log Parsing complete using Standalone Observability pipeline."

    Wait-ForLogUploadCompletion -Timeout (New-TimeSpan -Seconds $CacheFlushWaitTimeInSec)
}
catch {
    if ((Get-Command GMATenantJsonHelper\Get-ExceptionDetails -ErrorAction Ignore) -and (Get-Command ExtensionHelper\Set-Status -ErrorAction Ignore)) {
        $exceptionDetails = Get-ExceptionDetails -ErrorObject $_

        $errorMessage = "[$functionName] Failed to install and enable Standalone Observability pipeline components. Exception: $exceptionDetails"

        Set-Status -Name $functionName `
                -Operation "Install and Enable failed" `
                -Message $errorMessage `
                -Status "error" `
                -Code 1

        Write-Error $errorMessage
    }
    else {
        Write-Error $_
    }
}

# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBD898DIGX2KAUT
# dVYJZ417wuHgjhn/KBkZY2Ib6Qe2XqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIA8AOwmoiE+z63y88ZFNh3x3TUwi790kraH73AKL2DW6MEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAWvBYArqN9eK+fjNERalp
# Ih5ZeguSdKGtQ/sew+9kRAFRhXQbkXxYUiFSuhJyVFu3k/46ydeBa9zb4UMEN5OG
# SKXzdzngq2GX8dXNfPp/Hz0cXh5ORQObGVYhx9X0/1ms8cTqOH77ecG1IXYcu3Vw
# wnGGPxUmImL5u9GTPJIEISJ+CvW87moLbGt3q+GSp41eHgzEvBd9pcgJqhm5C9kp
# NmutTGZZ2OLbeH4uqhAaey3x5TjMoOAaUNnHs5Ot3aTpRHu7mmIttel43rLfISTb
# 54pJeK21CugVbgOJXPU/+ti2d/RIWuoGiwWyW0OtQwNCDjjDaSEV210U5YFUAc6Z
# o6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBGYY6q/+I3OvdFgRAl
# QKBgrJV1+x9SaCUpskNWC6y/3AIGaeuJ1G54GBMyMDI2MDUwMzE0MzEzMC44OTla
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACEtEIBjzKGE+qAAEAAAISMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxNVoXDTI2MTExMzE4
# NDgxNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAr0zToDkpWQtsZekS0cV0quDdKSTGkovvBaZH0OAIEi0O3CcO
# 77JiX8c4Epq9uibHVZZ1W/LoufE172vkRXO+QYNtWWorECJ2AcZQ10bpAltkhZNi
# XlVJ8L3QzhKgrXrmMkm2J+/g81U23JPcO4wXHEftonT3wpd//936rjmwxMm7Nkbs
# ygbJf+4AVBMNr4aMPQhBd76od0KMB6WrvyEGOOU0893OFufS5EDey4n44WgaxJE0
# Vnv3/OOvuOw5Kp1KPqjjYJ+L9ywLuBMtcDfLpNQO/h1eFEoMrbiEM67TOfNlXfxb
# Dz4MlsYvLioxgd2Xzey1QxrV1+i+JyVDJMiSe9gKOuzpiQQFE19DUPgsidyjLTzX
# EhSVLBlRor0eCVf7gC6Rfk8NY3rO2sggOL79vU5FuDKTh/sIOtcUHeHC42jBGB+t
# fdKC1KOBR+UlN9aOzg8mpUNI2FgqQvirVP9ppbeMUfvp2wA9voyTiRWvDgzCxo8x
# lJ1nscYTHIQrmkF9j/Ca0IDmt8fvOn64nnlJOGUYZYHMC1l0xtgkYTE1ESUqqkaw
# Kk7iqbxdnLyycS+dR+zaxPudMDLrQFz8lgfy9obk0D8HC2dzhWpYNn5hdkoPEzgC
# qQUOp8v3Qj/sd4anyupe5KoCkjABOP3yhSQ4W9Z+DrJnhM/rbsXC7oTv26cCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBRSBblSxb5cYKYOwvd/VfoXOfu33jAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAXnSAkmX79Rc7lxS1wOozXJ7V0ou5DntVcOJplIkD
# jvEN8BIQph4U+gSOLZuVReP/z9YdUiUkcPwL1PM245/kEX1EegpxNc8HDA6hKCHg
# 0ALNEcuxnGOlgKLokXfUer1D5hiW8PABM9R+neiteTgPaaRlJFvGTYvotc0uqGiE
# S5hMQhL8RNFhpS9RcIWHtnQGEnrdOUvCAhs4FeViawcmLTKv+1870c/MeTHi0QDd
# eR+7/Wg4qhkJ2k1iEHJdmYf8rIV0NRBZcdRTTdHee35SXP5neNCfAkjDIuZycRud
# 6jzPLCNLiNYzGXBswzJygj4EeSORT7wMvaFuKeRAXoXC3wwYvgIsI1zn3DGY625Y
# +yZSi8UNSNHuri36Zv9a+Q4vJwDpYK36S0TB2pf7xLiiH32nk7YK73Rg98W6fZ2I
# NuzYzZ7Ghgvfffkj4EUXg1E0EffY1pEqkbpDTP7h/DBqtzoPXsyw2MUh+7yvWcq2
# BGZSuca6CY6X4ioMuc5PWpsmvOOli7ARNA7Ab8kKdCc2gNDLacglsweZEc9/VQB6
# hls/b6Kk32nkwuHExKlaeoSVrKB5U9xlp1+c8J/7GJj4Rw7AiQ8tcp+WmfyD8KxX
# 2QlKbDi4SUjnglv4617R8+a/cDWJyaMt8279Wn7f2yMedN7kfGIQ5SZj66RdhdlZ
# Oq8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUA5VHBr4h00EN7jUdQ33SE+qbk/8CggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hPHgwIhgPMjAyNjA1MDMw
# MzE2MDhaGA8yMDI2MDUwNDAzMTYwOFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aE8eAIBADAKAgEAAgIqUwIB/zAHAgEAAgITfTAKAgUA7aKN+AIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAob1ciAs9EnklvfxsjRuxn1EXgx4NOdLcKwO7r
# /m10QuGw3cDnK5jwhUNWdMeurIe4d2zoVwlJgrsFVTWv+nvZyWMlnmDEU98vaSfz
# 3JV2V0NV5kkFXpPHpgAfHt+9sECdSs0S5NBD1s6J01gk2n5kuYpvZxwhdnWuPgd2
# EU+7p6GemsEK6nFR0BnCQZuMemNqEoeAA9i+Vq9eMf7zaz7JPTPSDm+IhzYSvVNN
# KSqZoNx6r90e81uqbjDqpfPH8XKaD9ETB1R/lHk9ba4h9LiMKlS0pcn/hCfSXvlM
# DTtRk7xFgU16wGTho3HULYVtQGFdC6H06IGmCtpThd1CtjCeMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIS0QgGPMoYT6oA
# AQAAAhIwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgRmpUtsct0Jd61379v/Acs9MzfP0Q9CbEPLWr
# TF8UILQwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBz+X5GvO7WngknH4BZ
# eYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIEIH62C3OysJpL+INwkKSZ
# fhuOdJ2Sj9gOYyp366y/mz5vMA0GCSqGSIb3DQEBCwUABIICAGtAmWfph3s5baNq
# hwuuT7d5G1P/vyaJaQGh0ne/mFWqpQPmBwbFdnSpL6NOO80dDObCn6EUsooakCQs
# Q3SQWABcjOjHMa+yPeZ3GAufKXhy0jRrIhguqNt6bbEU/EoSVZCsROG16pgHe0Dl
# QHMtNnuYKHc7vqUWncxf8YvwvHtPsmFsauBqM+ebIrWaftXfcJFtqKO6fjjLCDYc
# yz9KPbCP1BKuyHXBufMGPeg9WRlP9t3pFjwVFZEtyiR0133OXH3MZqFwdVP37LGJ
# x0GwEIxq4jTdYficKujX0UhdNkGLMGj1U5boS2iIddxXn+VpeYShamt4DPDbu4LD
# LMdebmKiI0TVlH7GfbR4UkooRiPI4y/6KWPoQYg87ewP+MtyjtyHrmvj14RpVGrx
# 1Dqf7fpInaiuGnwBktJgCfrWspjyZKYRZ0H2csyF+u4NIrkawnXss7HAG7uQpnwc
# V0vLjgE93SFb/W9E3btYptx72FWbcTKJF2FrKZIrU1Vd2R87Q141OWpAnNfF6sVr
# Fm7JjQESbTE1GPPL7eoKs5tVZjL+t8vL3fSq+j9gKvjk4eIaeCSd3Wn89HGyXIVm
# AvkDiboGA0aL4Fpjzq5cKxR1KMAj3ZSFOh0PsL4Dj+IhYDESpdi8U6bnpi4vPhtv
# MnTKHFeDYM5+QtvUQM2HlKKilnFn
# SIG # End signature block
