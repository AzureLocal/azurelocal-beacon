<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-Module $PSScriptRoot\AzStackHci.SBEHealth.Helpers.psm1 -DisableNameChecking -Global
 $MetaData = @{
    "OperationType" =  @("PreUpdate", "PreUpdateJIT") # PreUpdateJIT should be removed after 2508
    "UIName" = 'Azure Stack HCI SBE Health'
    "UIDescription" = 'Check SBE Health requirements'
}

function Test-AzStackHciSBEHealth
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $OperationType,

        [parameter(Mandatory = $false)]
        [ValidateSet('Small','Medium','Large')]
        [String]
        $HardwareClass = "Medium",

        [parameter(Mandatory = $false)]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String]
        $ClusterPattern = "Standard",

        [parameter(Mandatory = $false)]
        [switch]
        $FailFast
    )
    try
    {
        $backupPSModuleAutoLoadingPreference = $PSModuleAutoLoadingPreference
        # Disable module auto-loading and explicitly import modules needed.
        $PSModuleAutoLoadingPreference = [System.Management.Automation.PSModuleAutoLoadingPreference]::None
        Import-Module Microsoft.PowerShell.Utility -Verbose:$false
        Import-Module Microsoft.PowerShell.Management -Verbose:$false
        Import-Module NetTCPIP -Verbose:$false
        Import-Module DnsClient -Verbose:$false
        Import-Module PackageManagement -Verbose:$false

        # Import Module via Helper in case this is update
        [EnvironmentValidator]::EnvironmentValidatorImport($Parameters)
        $ENV:EnvChkrOp = $OperationType
        Trace-Execution "Starting SBE Health validation for $OperationType"
        $allResult = @()
        $exitEarly = $false
        # Start with default of running SBE from local SBE Cache paths (needed for Deployment and AddNode since CSV doesn't exist or isn't accessible yet)
        $runFrom = "LOCAL"

        $runtimeParameters = $Parameters.RunInformation['RuntimeParameter']
        $extendedTests = $runtimeParameters["ExtendedTests"]
        if ($null -ne $extendedTests)
        {
            [bool]$hasExtendedTests = [System.Boolean]::Parse($extendedTests)
        }
        else
        {
            [bool]$hasExtendedTests = $false
        }

        # For deployments, use the C:\SBE directory to signal to skip SBE checks for "just" this deployment
        $deploymentExcludeAllFileDirectory = "C:\SBE"

        # If there is an SBE installed, used the installed CSV path to skip all future system and pre-update checks
        $updateExcludeAllFileDirectory = [System.Environment]::GetEnvironmentVariable("SBEInstalledMetadata", "Machine")
        if ([System.String]::IsNullOrWhiteSpace($updateExcludeAllFileDirectory))
        {
            # if there is no SBE installed yet, fall back to the deployment exclude path
            $updateExcludeAllFileDirectory = $deploymentExcludeAllFileDirectory
        }
        $sbeExcludeAllFilePath = Join-Path -Path $updateExcludeAllFileDirectory -ChildPath "ExcludeAllSBEHealthChecks.txt"

        Trace-Execution "Confirming we intend to run SBE Health checks during Deployment"
        if (Test-Path -Path $sbeExcludeAllFilePath)
        {
            Trace-Execution "Exclusion file found at $sbeExcludeAllFilePath. Skipping SBE Health checks."
            $allResult += (New-Object -TypeName PsObject -Property @{Result = 'INFORMATIONAL'; FailedResult = $null; ExecutionDetail = "SBE Health validation has been skipped as exclusion file was found at $sbeExcludeAllFilePath."})
            $exitEarly = $true
        }
        elseif ($OperationType -eq 'Deployment')
        {
            Trace-Execution "Checking SBE Configuration"
            $sbeConfigNuget = Get-ASArtifactPath -NugetName "Microsoft.AzureStack.SBEConfiguration"
            # Only run tests if the SBE Package is 4.1.x.x or later
            if ($sbeConfigNuget -match "SBEConfiguration.([\d\.]+)")
            {
                $sbeVersion = $Matches[1]
                $sbeVersionFormatted = "1.0"
                if ([System.Version]::TryParse($sbeVersion,[ref]$sbeVersionFormatted))
                {
                    if($sbeVersionFormatted -lt [System.Version]"4.1")
                    {
                        Trace-Execution "SBE Configuration nuget '$($sbeConfigNuget)' must be version 4.1.x.x or later to support SBE health checks."
                        
                        #try one more time the older way
                        $sbeVerMatch = "SBEConfiguration.(4\.[1-9])|([5-9])\."
                        if ($sbeConfigNuget -notmatch $sbeVerMatch)
                        {
                            $detailedMessage = "SBE Configuration nuget '$($sbeConfigNuget)' does not support this test. Must be version 4.1.x.x or later."
                            Trace-Execution $detailedMessage
                            $allResult += (New-Object -TypeName PsObject -Property @{Result = 'INFORMATIONAL'; FailedResult = $null; ExecutionDetail = $detailedMessage})
                            $exitEarly = $true
                        }
                        else
                        {
                            Trace-Execution "Matched old way. SBE version of '$sbeVersion' is new enough to that we should check to see if HealthChecks are implemented."
                        }
                    }
                    else
                    {
                        Trace-Execution "SBE version of '$sbeVersion' is new enough to that we should check to see if HealthChecks are implemented."
                    }
                }
                else
                {
                    $detailedMessage = "SBE Configuration nuget '$($sbeConfigNuget)' version of '$sbeVersion' is malformed. Must be version 4.1.x.x or later."
                    Trace-Execution $detailedMessage
                    $allResult += (New-Object -TypeName PsObject -Property @{Result = 'INFORMATIONAL'; FailedResult = $null; ExecutionDetail = $detailedMessage})
                    $exitEarly = $true
                }
            }
            $sbeMetadataPath = Join-Path -Path $sbeConfigNuget -ChildPath "content"
            $oemMetadataXmlPath = Join-Path -Path $sbeMetadataPath -ChildPath "oemMetadata.xml"
            if ($false -eq (Test-Path -Path $oemMetadataXmlPath))
            {
                throw "Unable to locate oemMetadata.xml file at $oemMetadataXmlPath"
            }
            [xml]$oemMetadata = Get-Content -Path $oemMetadataXmlPath
            $sbeVersion = $oemMetadata.UpdatePackageManifest.UpdateInfo.Version

            Trace-Execution "Getting SBE Package source local path"
            $sbeSourcePath = $Parameters.Roles["SBE"].PublicConfiguration.PublicInfo.SBEContentPaths.SBESeedNodePath
            if ($null -eq $sbeSourcePath)
            {
                $detailedMessage = "SBE Seed Node Path property did not get populated. Please retry the deployment."
                Trace-Execution $detailedMessage
                throw $detailedMessage
            }
        }
        elseif ($OperationType -eq 'PreUpdate')
        {
            $aldoSupport = [System.Environment]::GetEnvironmentVariable("DISCONNECTED_OPS_SUPPORT", "Machine")
            # note: order matters here - $true -eq $aldoSupport won't work because $aldoSupport is a string
            if ($null -ne $aldoSupport -and $aldoSupport -eq "True")
            {
                Trace-Execution "ALDO Disconnected Operations support detected. Skipping SBE endpoint check."
            }
            else
            {
                $manifestFilePath = (New-TemporaryFile).FullName
                if (Test-Path -Path $manifestFilePath)
                {
                    Remove-Item -Path $manifestFilePath -Force -ErrorAction SilentlyContinue
                }

                Trace-Execution "Validating SBE manifest endpoint connectivity"
                # First, make sure firewall rules are not blocking access to the manifest endpoint
                try
                {
                    Import-Module Microsoft.AzureStack.Lcm.PowerShell -Verbose:$false
                    $diagnosticInfo = Get-SolutionDiscoveryDiagnosticInfo 3>$null 4>$null
                    $sbeEndpoint = $diagnosticInfo.Configuration.ComponentUris["SBE"]
                    Trace-Execution "SBE manifest endpoint: $sbeEndpoint"
                }
                catch
                {
                    Trace-Execution "Failed to get SBE manifest endpoint from Get-SolutionDiscoveryDiagnosticInfo. Error: $($PSItem.Exception.Message)"
                }

                $endpointAccessResult = New-SBEHealthResultObject -TestName 'Test-Endpoint-Connectivity' -TargetName $env:ComputerName -Severity 'INFORMATIONAL' -Status 'SUCCESS' -Description "Validate SBE manifest reachable: $sbeEndpoint"
                $endpointAccessResult.TargetResourceID = $sbeEndpoint
                $endpointAccessResult.TargetResourceName = 'Hardware vendor Solution Builder Extension manifest'

                # Test connectivity to SBE manifest endpoint
                $endpointAccessResult = Test-SBEEndpointConnectivity -SbeEndpointUri $sbeEndpoint -EndpointAccessResult $endpointAccessResult -ManifestFilePath $manifestFilePath

                # continue with other tests - having bad firewall rules doesn't mean we can skip the rest of the tests
                $allResult += $endpointAccessResult

                if (Test-Path -Path $manifestFilePath)
                {
                    $endpointContentsResult  = New-SBEHealthResultObject -TestName 'Test-Endpoint-Matches-ModelSKU' -TargetName $env:ComputerName -Severity 'INFORMATIONAL' -Status 'SUCCESS' -Description "Validate SBE manifest matches hardware model:$modelValue, sku:$skuValue"
                    try
                    {
                        Trace-Execution "Attempting to get the path to the UpdateService.Validation module."
                        $validationModuleConsolidatedPath = Join-Path -Path (Get-ASArtifactPath -NugetName "Microsoft.AzureStack.UpdateService.Validation") -ChildPath "lib\net472\UpdateService.Validation.dll"
                        Trace-Execution "Will use: $validationModuleConsolidatedPath"
                    }
                    catch
                    {
                        Trace-Execution "Get-ASArtifactPath failed to locate Microsoft.AzureStack.UpdateService.Validation nuget."
                    }
                    if ($null -eq $validationModuleConsolidatedPath -or (Test-Path -Path $validationModuleConsolidatedPath) -eq $false)
                    {
                        $msg = "Unable to locate UpdateService.Validation module at expected path: $validationModuleConsolidatedPath"
                        Trace-Execution $msg
                        $endpointContentsResult.Description = $msg
                        $endpointContentsResult.Remediation = "Ensure the LCM Extension is properly installed and that C:\NugetStore\Microsoft.AzureStack.UpdateService.Validation nuget is available."
                    }
                    else
                    {
                        Trace-Execution "Loading UpdateService.Validation module from: $validationModuleConsolidatedPath"
                        $job = Start-Job -ScriptBlock {
                            try {
                                # Load DLL for running SBE validation
                                Import-Module "$($using:validationModuleConsolidatedPath)" -Force
                            }
                            catch {
                                return [PSCustomObject]@{
                                    Code = "ErrorUnableToLoadDll"
                                    Message = "Error loading $($using:validationModuleConsolidatedPath): $($_.Exception.Message)"
                                }
                            }
                            try {
                                $validator = [UpdateService.Validation.DeploymentSbeValidator]::new()
                                $defaultEndpoint = $validator.GetSbeDiscoveryUri()
                                return [PSCustomObject]@{
                                    Code = "Ok"
                                    Message = $defaultEndpoint
                                }
                            }
                            catch {

                                return [PSCustomObject]@{
                                    Code = "ErrorUnableToGetEndpoint"
                                    Message = "Error running SBE validation: $($_.Exception.Message)"
                                }
                            }
                        }
                        $result = $job | Receive-Job -Wait -AutoRemoveJob

                        if ($result.Code -ne "Ok")
                        {
                            $msg = $result.Message
                            Trace-Execution $msg
                            $endpointContentsResult.Status = 'FAILURE'
                            $endpointContentsResult.Description = $msg
                            $endpointContentsResult.Remediation = "Ensure the LCM Extension is properly installed and that C:\NugetStore\Microsoft.AzureStack.UpdateService.Validation nuget is available."
                        }
                        elseif($result.Message -eq $sbeEndpoint)
                        {
                            Trace-Execution "SBE manifest endpoint $sbeEndpoint matches the default endpoint will skip model/SKU check as we don't intend to advise users to change from default."
                            $endpointContentsResult.Description = "SBE manifest endpoint $sbeEndpoint matches the default endpoint. No model/SKU check needed."
                        }
                        else {
                            Trace-Execution "SBE manifest endpoint $sbeEndpoint does not match the default endpoint."

                            Trace-Execution "Proceeding with model/SKU check against manifest at $manifestFilePath to see if the override endpoint is valid for this hardware."
                            $endpointContentsResult = Get-ManifestMatchesModelandSKUResult -SBEManifestFilePath $manifestFilePath -EndpointContentsResult $endpointContentsResult
                        }

                    }
                    $allResult += $endpointContentsResult
                }
            }

            # Next, get the installed SBE info - we might need to fall back to this SBE
            $sbeVersion = '1.0'
            $sbeSourcePath = [System.Environment]::GetEnvironmentVariable("SBEInstalledContent", "Machine")
            $sbeMetadataPath = [System.Environment]::GetEnvironmentVariable("SBEInstalledMetadata", "Machine")
            if ($null -ne $sbeMetadataPath)
            {
                $oemMetadataXmlPath = Join-Path -Path $sbeMetadataPath -ChildPath "oemMetadata.xml"
                if ($true -eq (Test-Path -Path $oemMetadataXmlPath))
                {
                    [xml]$oemMetadata = Get-Content -Path $oemMetadataXmlPath
                    $sbeVersion = $oemMetadata.UpdatePackageManifest.UpdateInfo.Version
                }
            }
            $sbeInstalled = $false

            $installSBEResult = New-SBEHealthResultObject -TestName 'Test-Installed-SBE-Env-Vars' -TargetName $env:ComputerName -Status 'SUCCESS' -Description "Validate Installed SBE Env Vars"

            if (($null -ne $sbeSourcePath) -and ($null -ne $sbeMetadataPath) -and ($null -ne $sbeVersion))
            {
                $detailedMessage = "Detected SBE $sbeVersion is installed. TBD if we will use this or a newer version for checks."
                $sbeInstalled = $true
            }
            elseif ((($null -eq $sbeSourcePath) -and ($null -eq $sbeMetadataPath) -and ($null -eq $sbeVersion)) -or ($sbeVersion -eq '1.0'))
            {
                Trace-Execution "SBE ENV vars - content: [$sbeSourcePath], metadata: [$sbeMetadataPath], sbeVersion [$sbeVersion]"
                $detailedMessage = "No SBE installed. May be skipping checks if this isn't an update including an SBE."
            }
            else
            {
                $detailedMessage = "Inconsistent SBE ENV vars!! content: [$sbeSourcePath], metadata: [$sbeMetadataPath], sbeVersion [$sbeVersion]"
                $installSBEResult.Severity = 'WARNING'
                $installSBEResult.Remediation = "Update to latest available Solution Builder Extension to restore consistent SBE state."
            }
            Trace-Execution $detailedMessage
            $installSBEResult.AdditionalData.Detail = $detailedMessage
            $allResult += $installSBEResult

            # Figure out if this is a period "system" healthcheck or "preUpdate" HealthCheck
            if ($null -eq $runtimeParameters)
            {
                $runtimeParameters = $Parameters.RunInformation['RuntimeParameter']
            }
            $packagePath = $runtimeParameters["UpdatePackagePath"]
            $updateVersion = $runtimeParameters["UpdateVersion"]
            if ($null -eq $packagePath)
            {
                Trace-Execution "System HealthCheck detected."
                if ($sbeInstalled)
                {
                    Trace-Execution -Message "System check scenario - Using installed SBE - content: [$sbeSourcePath], metadata: [$sbeMetadataPath], sbeVersion [$sbeVersion]"
                    # For the "installed" system check scenario we want to just run from the installed CSV dir as it is already properly organzied (with split content and metadata)
                    #   Note: We can't run from the update CSV as it is messy - has combined content and metadata as well as the zip files
                    $runFrom = "CSV"
                }
                else
                {
                    # Early exit, there is no SBE to test with
                    $exitEarly = $true
                }
            }
            else
            {
                Trace-Execution "Update package @: [$packagePath]"
                Trace-Execution "Update version @: [$updateVersion]"
                $updateEnvVarsForSBE = $false

                # The package path is expected to be a full path to an update package file (e.g. a self-
                # extracting .exe, metadata.xml, or oemMetadata.xml file). The content is in the same dir.

                # Also paths from runtime params often have extra \\ in them like: C:\\ClusterStorage\\Infrastructure_1\\Shares\\SU1_Infrastructure_1\\Updates\\Packages\Solution99.9999.9.11\metadata.xml
                $updatePackageBaseDir = (Split-Path $packagePath -Parent).Replace( '\\', '\')
                if ($updateVersion -match '^\d{2}\.\d{4}\..*')
                {
                    # Version is something like 10.2405.1.13 and indicates this is a solution update
                    $potentialSBEPath = "$updatePackageBaseDir\SBE"
                    if (Test-Path -Path $potentialSBEPath)
                    {
                        $sbeSourcePath = $potentialSBEPath
                        $sbeMetadataPath = $potentialSBEPath
                        $oemMetadataXmlPath = Join-Path -Path $sbeMetadataPath -ChildPath "oemMetadata.xml"
                        if ($false -eq (Test-Path -Path $oemMetadataXmlPath))
                        {
                            throw "Unable to locate oemMetadata.xml file at $oemMetadataXmlPath"
                        }
                        [xml]$oemMetadata = Get-Content -Path $oemMetadataXmlPath
                        $sbeVersion = $oemMetadata.UpdatePackageManifest.UpdateInfo.Version
                        Trace-Execution "Using SBE from Solution Update - content: [$sbeSourcePath], metadata: [$sbeMetadataPath], sbeVersion [$sbeVersion]"
                        $updateEnvVarsForSBE = $true
                    }
                    elseif ($sbeInstalled)
                    {
                        Trace-Execution -Message "Non-SBE Solution update scenario - Using installed SBE - content: [$sbeSourcePath], metadata: [$sbeMetadataPath], sbeVersion [$sbeVersion]"
                        # run from the installed CSV dir as it is already properly organzied (with split content and metadata)
                        $runFrom = "CSV"
                    }
                    else
                    {
                        # Early exit, this is a Solution update w/o an SBE and there is no SBE installed
                        Trace-Execution "Skipping tests as no SBE is installed and there is no SBE from this Solution Update"
                        $exitEarly = $true
                    }
                }
                elseif ($updateVersion -match '\d\.\d\.\d{4}\..*')
                {
                    $sbeSourcePath = $updatePackageBaseDir
                    $sbeMetadataPath = $updatePackageBaseDir
                    $sbeVersion = $updateVersion
                    $updateEnvVarsForSBE = $true
                    Trace-Execution "Using SBE from SBE-only Update - content: [$sbeSourcePath], metadata: [$sbeMetadataPath], sbeVersion [$sbeVersion]"
                }
            }
            $sbeVersionFormatted = "1.0"
            if ([System.Version]::TryParse($sbeVersion,[ref]$sbeVersionFormatted))
            {
                if($sbeVersionFormatted -lt [System.Version]"4.1")
                {
                    $versionResult = New-SBEHealthResultObject -TestName 'Test-Version-Supports-$OperationType-Tests' -TargetName $env:ComputerName -Status 'SUCCESS' -Description "Validate SBE Version supports $OperationType type tests."
                    $detailedMessage = "Skipping tests. SBE '$OperationType' type Health Checks are only supported with version 4.1.x.x or later (SBE version was $sbeVersion)."
                    Trace-Execution $detailedMessage
                    $versionResult.AdditionalData.Detail = $detailedMessage
                    $allResult += $versionResult
                    $exitEarly = $true
                }
            }
        }
        elseif ($OperationType -eq 'PreAddNode')
        {
            # TODO : Future placeholder for when AddNode tests are implemented
            Trace-Execution "SBE Health validation for $OperationType has not been implemented yet"
            $allResult += (New-Object -TypeName PsObject -Property @{Result = 'INFORMATIONAL'; FailedResult = $null; ExecutionDetail = 'SBE Health validation has been skipped as this OperationType is not yet supported.'})
            $exitEarly = $true
        }
        else
        {
            Trace-Execution "OperationType $OperationType is not implemented"
            $allResult += (New-Object -TypeName PsObject -Property @{Result = 'INFORMATIONAL'; FailedResult = $null; ExecutionDetail = 'SBE Health validation has been skipped as this OperationType is not yet supported.'})
            $exitEarly = $true
        }

        # Done with built-in checks - send result to telemetry channel
        foreach ($res in $allResult)
        {
            Write-ETWResult -Result $res
        }

        if ($exitEarly)
        {
            Trace-Execution "Either decided to skip SBE checks (on request or due to lack of SBE support for health check) or identified a setup issue. Exit early before partner tests."
            # Check if the ParseResult method supports the Parameters
            if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
            {
                Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
                return [EnvironmentValidator]::ParseResult($allResult, 'SBEHealth', $FailFast, $Parameters)
            }
            else
            {
                Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
                return [EnvironmentValidator]::ParseResult($allResult, 'SBEHealth', $FailFast)
            }
        }

        $priorStageVersion = $null
        $priorStageRootPath = $null
        $priorSBEMeatadataPath = $null
        if ($true -eq $updateEnvVarsForSBE)
        {
            # While we haven't technically staged the SBE yet, set the env vars so some of the helper functions know where to find the metadata files or SBE content
            # IMPORTANT: We MUST put these values back to their prior values when we are done (success or fail).  If we don't we will get new + old mismatches:
            #  - scenario 1: system checks will fail (old install dir + new metadata path)
            #  - scenario 2: after scenario 1 fails we have pre-update checks will fail due to both new and old files being at the cache path (since we do pssession copy-item copy first instead of a robocopy /MIR type copy)
            $priorStageVersion = [System.Environment]::GetEnvironmentVariable("SBEStageVersion", "Machine")
            Trace-Execution "Temporarily changing SBEStageVersion from '$priorStageVersion' to '$sbeVersion'"
            [System.Environment]::SetEnvironmentVariable("SBEStageVersion", $sbeVersion, "Machine")
            $priorStageRootPath = [System.Environment]::GetEnvironmentVariable("SBEStageRootPath", "Machine")
            Trace-Execution "Temporarily changing SBEStageRootPath from '$priorStageRootPath' to '$sbeSourcePath'"
            [System.Environment]::SetEnvironmentVariable("SBEStageRootPath", $sbeSourcePath, "Machine")
            $priorSBEMeatadataPath = [System.Environment]::GetEnvironmentVariable("SBEStagedMetadata", "Machine")
            Trace-Execution "Temporarily changing SBEStagedMetadata from '$priorSBEMeatadataPath' to '$sbeMetadataPath'"
            [System.Environment]::SetEnvironmentVariable("SBEStagedMetadata", $sbeMetadataPath, "Machine")
        }

        Trace-Execution "Getting PSSessions for all hosts"

        # No prep for the partner validators
        $psSession = [EnvironmentValidator]::NewPsSessionAllHosts($Parameters)

        # Update mapping as needed each time envChecker adds a new OperationType that we want to translate to an SBE healthCheck "tag"
        $envCheckerToSBEPrecheckTagMap = @{
            PreUpdate = "Update"
            PostUpdate = "Update"
            PreAddNode = "AddNode"
        }
        $tag = $OperationType
        if ($null -ne $envCheckerToSBEPrecheckTagMap.$OperationType)
        {
            # EnvChecker has invented some new test types that SBE doesn't support - use mapping table to translate to SBE equivalent
            $tag = $envCheckerToSBEPrecheckTagMap.$OperationType
        }
        $params = @{
            PsSession = $psSession
            PassThru = $true
            OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
            HardwareClass = $HardwareClass
            ClusterPattern = $ClusterPattern
            Tag = $tag
            SBESourcePath = $sbeSourcePath
            SBEMetadataPath = $sbeMetadataPath
            SBEVersion = $sbeVersion
            ECEParameters = $Parameters
            RunFrom = $runFrom
        }
        if ($true -eq $hasExtendedTests)
        {
            $params += @{ExtendedTests = [switch]::Present}
        }

        # Run Partner SBE Health Checks
        [array]$partnerResults = AzStackHci.EnvironmentChecker\Invoke-AzStackHciSBEHealthValidation @params
        if ($null -ne $partnerResults -and $partnerResults.Count -gt 0)
        {
            $allResult += $partnerResults
        }
        # Check if the ParseResult method supports the Parameters
        if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
        {
            Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
            return [EnvironmentValidator]::ParseResult($allResult, 'SBEHealth', $FailFast, $Parameters)
        }
        else
        {
            Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
            return [EnvironmentValidator]::ParseResult($allResult, 'SBEHealth', $FailFast)
        }
    }
    catch
    {
        Trace-Execution "Validator failed. $PSItem"
        Trace-Execution "$($PSItem.ScriptStackTrace)"
        throw $PSItem
    }
    finally
    {
        #return the EnvVars to default values
        if ($OperationType -eq 'PreUpdate')
        {
            try {
                Trace-Execution "Reverting SBE env vars to default values"
                $templatedSBEPath = $Parameters.Roles["SBE"].PublicConfiguration.PublicInfo.SBEContentPaths.SBESharePath
                $sbeCSVDir = $templatedSBEPath.Replace('{DefaultClusterShare}', $env:InfraCSVRootFolderPath)
                if ($false -eq (Test-Path -Path $sbeCSVDir))
                {
                    Trace-Execution "Unable to locate SBE CSV path at $sbeCSVDir"
                }
                else
                {
                    Trace-Execution "Resolved SBE CSV path to '$sbeCSVDir'"
                    $defaultStagedMetadata  = Join-Path -Path $sbeCSVDir -ChildPath $Parameters.Roles["SBE"].PublicConfiguration.PublicInfo.SBEContentPaths.RelativePaths.CSVStagedMetadataPath
                    $defaultStagedRoot = Join-Path -Path $sbeCSVDir -ChildPath $Parameters.Roles["SBE"].PublicConfiguration.PublicInfo.SBEContentPaths.RelativePaths.CSVStagedContentPath
                    if ($false -eq [System.String]::IsNullOrWhiteSpace($defaultStagedMetadata) -and (Test-Path -Path $defaultStagedMetadata))
                    {
                        $newSBEMeatadataPath = [System.Environment]::GetEnvironmentVariable("SBEStagedMetadata", "Machine")
                        Trace-Execution "Reverting changing SBEStagedMetadata from '$newSBEMeatadataPath' to default '$defaultStagedMetadata'"
                        [System.Environment]::SetEnvironmentVariable("SBEStagedMetadata", $defaultStagedMetadata, "Machine")
                    }
                    if ($false -eq [System.String]::IsNullOrWhiteSpace($defaultStagedRoot) -and (Test-Path -Path $defaultStagedRoot))
                    {
                        $newStageRootPath = [System.Environment]::GetEnvironmentVariable("SBEStageRootPath", "Machine")
                        Trace-Execution "Reverting changing SBEStageRootPath from '$newStageRootPath' to default '$defaultStagedRoot'"
                        [System.Environment]::SetEnvironmentVariable("SBEStageRootPath", $defaultStagedRoot, "Machine")
                    }
                    if ($true -eq $updateEnvVarsForSBE)
                    {
                        # While it is always safe to return the "staged" paths to their defaults, we should only go back to the installed version in the case of a true pre-update check.
                        # Avoid doing this in the daily health check case because it will change from the staged version to the installed version
                        $installedSBEVersion = [System.Environment]::GetEnvironmentVariable("SBEInstallVersion", "Machine")
                        if ([System.String]::IsNullOrWhiteSpace($installedSBEVersion) -or $false -eq $installedSBEVersion.StartsWith("4"))
                        {
                            $installedSBEVersion = "2.1.0.0"
                            Trace-Execution "No SBEis installed, will revert staged SBE back to '$installedSBEVersion'"
                        }
                        $sbeVersion = [System.Environment]::GetEnvironmentVariable("SBEStageVersion", "Machine")
                        Trace-Execution "Reverting changing SBEStageVersion from '$sbeVersion' to the actual installed value '$installedSBEVersion'"
                        [System.Environment]::SetEnvironmentVariable("SBEStageVersion", $installedSBEVersion, "Machine")
                    }
                }
            }
            catch
            {
                Trace-Execution "Failed to revert SBE env vars. $($PSItem.Exception.Message)"
                Trace-Execution "$($PSItem.ScriptStackTrace)"
            }
        }
        if ($psSession)
        {
            if ($backupPSModuleAutoLoadingPreference)
            {
                $PSModuleAutoLoadingPreference = $backupPSModuleAutoLoadingPreference
            }
            $psSession | Microsoft.PowerShell.Core\Remove-PSSession
        }
    }
}

Export-ModuleMember -Function Test-AzStackHciSBEHealth -Variable MetaData

# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA3kJDqXMQFnbGy
# 1MzPbWO8LkkkrPb5sOwFKsJjMUgnVKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn7MIIZ9wIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIAjohyO4y0aScXtYUARvHFLnT3yaQwCk0SPlxyDkJDCJMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAq15+U6LGYXbcq8lbCrHv
# j2TEow32eZYKPlGH9DmcSikIN1znuzjvMDgRLcWV5LW8aZkWL7659y7y19h03Z4E
# O/q2CJRDHQ4sTee2x6BbcmOXp+c92ak4wOu4GA/xrbQjuFe4PR8tqxPT11NiLC1u
# byBuAtLiiHI1wTxx2snGeJd5/4EEt2NBSsdtwn2JiUFt7yQvn2kDo4cyGi39Vz7d
# 1u8liyn/LiwlhYyLVZsaFZYzlk//tV6sDk1xMSp9uk1K0lXmZPwFQyGX6PWvOWEd
# EmSQ+nIF844DdcdW0EzRxoFB8m5PU853b29h2Am+7mzP9j4nRxGEMQax3LrLwN9J
# zKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDhcCzuajjpJqGJUc2q
# D6GmBlj9tqfU+4CSHZ4cq+9OEAIGaewquMvBGBMyMDI2MDUwMzE0MzExMS4xMzRa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1OTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACFI3NI0TuBt9yAAEAAAIUMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxOFoXDTI2MTExMzE4
# NDgxOFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjU5MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAyU+nWgCUyvfyGP1zTFkLkdgOutXcVteP/0CeXfrF/66chKl4
# /MZDCQ6E8Ur4kqgCxQvef7Lg1gfso1EWWKG6vix1VxtvO1kPGK4PZKmOeoeL68F6
# +Mw2ERPy4BL2vJKf6Lo5Z7X0xkRjtcvfM9T0HDgfHUW6z1CbgQiqrExs2NH27rWp
# UkyTYrMG6TXy39+GdMOTgXyUDiRGVHAy3EqYNw3zSWusn0zedl6a/1DbnXIcvn9F
# aHzd/96EPNBOCd2vOpS0Ck7kgkjVxwOptsWa8I+m+DA43cwlErPaId84GbdGzo3V
# oO7YhCmQIoRab0d8or5Pmyg+VMl8jeoN9SeUxVZpBI/cQ4TXXKlLDkfbzzSQriVi
# QGJGJLtKS3DTVNuBqpjXLdu2p2Yq9ODPqZCoiNBh4CB6X2iLYUSO8tmbUVLMMEeg
# bvHSLXQR88QNICjFoBBDCDydoTo9/TNkq80mO77wDM04tPdvbMmxT01GTod60JJx
# UGmMTgseghdBGjkN+D6GsUpY7ta7hP9PzLrs+Alxu46XT217bBn6EwJsAYAc9C28
# mKRUcoIZWQRb+McoZaSu2EcSzuIlAaNIQNtGlz2PF3foSeGmc/V7gCGs8AHkiKwX
# zJSPftnsH8O/R3pJw2D/2hHE3JzxH2SrLX1FdI7Drw145PkL0hbFL6MVCCkCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBTbX/bs1cSpyTYnYuf/Mt9CPNhwGzAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAP3xp9D4Gu0SH9B+1JH0hswFquINaTT+RjpfEr8Um
# UOeDl4U5uV+i28/eSYXMxgem3yBZywYDyvf4qMXUvbDcllNqRyL2Rv8jSu8wclt/
# VS1+c5cVCJfM+WHvkUr+dCfUlOy9n4exCPX1L6uWwFH5eoFfqPEp3Fw30irMN2So
# nHBK3mB8vDj3D80oJKqe2tatO38yMTiREdC2HD7eVIUWL7d54UtoYxzwkJN1t7gE
# EGosgBpdmwKVYYDO1USWSNmZELglYA4LoVoGDuWbN7mD8VozYBsfkZarOyrJYlF/
# UCDZLB8XaLfrMfMyZTMCOuEuPD4zj8jy/Jt40clrIW04cvLhkhkydBzcrmC2HxeE
# 36gJsh+jzmivS9YvyiPhLkom1FP0DIFr4VlqyXHKagrtnqSF8QyEpqtQS7wS7ZzZ
# F0eZe0fsYD0J1RarbVuDxmWsq45n1vjRdontuGUdmrG2OGeKd8AtiNghfnabVBbg
# pYgcx/eLyW/n40eTbKIlsm0cseyuWvYFyOqQXjoWtL4/sUHxlWIsrjnNarNr+POk
# L8C1jGBCJuvm0UYgjhIaL+XBXavrbOtX9mrZ3y8GQDxWXn3mhqM21ZcGk83xSRqB
# 9ecfGYNRG6g65v635gSzUmBKZWWcDNzwAoxsgEjTFXz6ahfyrBLqshrjJXPKfO+9
# Ar8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCCAj4C
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1OTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUA2RysX196RXLTwA/P8RFWdUTpUsaggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hNKgwIhgPMjAyNjA1MDMw
# MjQyNDhaGA8yMDI2MDUwNDAyNDI0OFowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7aE0qAIBADAHAgEAAgIA/DAHAgEAAgISUTAKAgUA7aKGKAIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQAc2Yzc77kwZuH46ShXvStPqvvycwk+yq9klOHFkRvR
# PgLHSofJciKLjwGzsi0wfb5jadJcoJxDENCEmkR/WpPliL61hemoHY/2cMGp7s5i
# 5jdqptQRrhwNBAZuRVAqB/EaG1AC6FNJhSM2xyaLEaRI6HWU6gDfuj1L0aCm3++b
# yPA6EH8tn5NVw4H4WdeLe99pW6k6PAMqgO+gj2QNX+TGgrABvYmUDbHunEyabbrZ
# rhZjJ2n0QwoDUeST9eIvD+nKNs6FxbnjCZ08rL61Z2AZM+k3BFBREhhVtdN/7Xvk
# k6ipnYxlAiF9uqOd3Cyjwb7P34igT8weR0PntEH6Rx+DMYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIUjc0jRO4G33IAAQAA
# AhQwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgv2Wzz0fXQmDXE0s/vgz3gSStXHKF/ccmHytY0M2R
# LdowgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCA2eKvvWx5bcoi43bRO3+Et
# tQUCvyeD2dbXy/6+0xK+xzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACFI3NI0TuBt9yAAEAAAIUMCIEIIuYD1reuH7VxpqskBn7uksa
# ptLeODyj6FjPBUD6JIKNMA0GCSqGSIb3DQEBCwUABIICACWTnvjnjs8Oq/Mg3QcV
# QBlABH9ZBiRPv9NyfEI7UrwW5NzEu3Rw2b0vUc3FYbqs3eWt9Km7QROTfCpCgg+c
# U8XpObiT06OklZJbMYfPE35M1t2ODFXf9vK8bnl+jwNSw+X/iCNSK+udU2mhfvg2
# MbvVyoLPwXjW77ydI+YYKcXl+0KxBU/ejSXUzO7g+omBw988wv74G03iXQ/slY68
# jm0yWIMjdWHb+kD+uMte9Wv7PWTPGR7Dm6lxf2ElBkED0RSrO6QZVvbgVBRJT92k
# ERvIFe6gLkdaxgq6TgEHLD+HuyffhqMWv5DF3I7q8ffnOhVJvq7IDxW9HmscfM3e
# GzyzyDlhnPEaFgc1Kk+OaZcYe5pXRK3tsg7z/2YDMsOglfl727asZHgnxxPe8cAD
# /bG5YbdXVq5X0xPOoQOtUQKNrj1qQ3pvSqOYEPv3gkKEsuOtPYf6vIZFU75QnRsk
# LIAVZFQT6Jm6MkURDtg7jCJZysHfV6fq+dBUcoH/lR65XPZHyMrvG992KCxAfkgq
# sHxn4bJmFG30uwUAiRtTMSfvVdzvgZ3uINrWBw5lUlMqV7sJxt62//qBLSEjYpvC
# TALYfojHwj3crOZR7HdJY4FN+CZUQaItdyXAym5wYKUp+KPuBa0B8XZwVrB1Ce9C
# x/mBwS6v+1lEGsqkrBmpHbEr
# SIG # End signature block
