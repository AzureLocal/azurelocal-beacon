<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-LocalizedData -BindingVariable lhwTxt -FileName AzStackHci.SBEHealth.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.SBEHealth.Helpers.psm1 -DisableNameChecking -Global

function Invoke-AzStackHciSBEHealthValidation
{
    <#
        .SYNOPSIS
            Perform AzStackHci SBE Health validation
        .DESCRIPTION
            Perform AzStackHci SBE Health validation
        .EXAMPLE
            PS C:\> Invoke-AzStackHciSBEHealthValidation -SBESourcePath "C:\SBE"
            Perform SBE Health validations on localhost
        .EXAMPLE
            PS C:\> $Credential = Get-Credential -Message "Credential for RemoteSystem"
            PS C:\> $RemoteSystemSession = New-PSSession -Computer 10.0.0.4,10.0.0.5 -Credential $Credential
            PS C:\> Invoke-AzStackHciSBEHealthValidation -SBESourcePath "C:\SBE" -PsSession $RemoteSystemSession
            Perform SBE Health validations on the localhost and all specified remote PS sessions
        .PARAMETER PsSession
            Specify the PsSession(s) used to validation from
        .PARAMETER Tag
            Specify the Tag value to be passed to the SolutionExtension module when called
        .PARAMETER SBESourcePath
            Specify the full local path to the folder containing the extracted SBE Package
        .PARAMETER SBEMetadataPath
            Specify the full local path to the folder containing the SBE Metadata files
        .PARAMETER SBEVersion
            Specify the SBE Version to be used for validation interfaces
        .PARAMETER HardwareClass
            Hardware class: Small, Medium, or Large
        .PARAMETER ClusterPattern
            Cluster Pattern: Standard, Stretch, or RackAware
        .PARAMETER SkipIntegrityTest
            Skip the SBE file integrity test
        .PARAMETER ShowFailedOnly
            Show only failed results on screen
        .PARAMETER ECEParameters
            ECE Parameters
        .PARAMETER RunFrom
            Define where to run from. Local or CSV
        .PARAMETER OutputPath
            Directory path for log and report output
        .PARAMETER CleanReport
            Remove all previous progress and create a clean report
        .PARAMETER Exclude
            List of test names to exclude from execution
        .PARAMETER ExtendedTests
            Tests to run will include extended tests
        .INPUTS
            Inputs (if any)
        .OUTPUTS
            Output (if any)
    #>

    [CmdletBinding()]
    param (

        [Parameter(Mandatory = $false, HelpMessage = "Specify the PsSession(s) used to validation from. If null the local machine will be used.")]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false, HelpMessage = "Tag to pass to SolutionExtension module functions.")]
        [string]
        $Tag = "Deployment",

        [Parameter(Mandatory = $true, HelpMessage = "Local path to the folder containing the extracted SBE Package.")]
        [string]
        $SBESourcePath,

        [Parameter(Mandatory = $true, HelpMessage = "Local path to the folder containing the SBE metadata file.")]
        [string]
        $SBEMetadataPath,

        [Parameter(Mandatory = $true, HelpMessage = "Version of the SBE package to use for validation interfaces.")]
        [string]
        $SBEVersion,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Hardware class: Small, Medium, or Large")]
        [ValidateSet('Small','Medium','Large')]
        [string]
        $HardwareClass = "Medium",

        [Parameter(Mandatory = $false, HelpMessage = "Cluster Pattern: Standard, Stretch, or RackAware")]
        [ValidateSet('Standard','Stretch','RackAware')]
        [string]
        $ClusterPattern = "Standard",

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]
        $OutputPath,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]
        $CleanReport = $false,

        [Parameter(Mandatory = $false, HelpMessage = "Show only failed results on screen.")]
        [switch]
        $ShowFailedOnly,

        [Parameter(Mandatory = $false, HelpMessage = "Skip the SBE file integrity test.")]
        [switch]
        $SkipIntegrityTest,

        [Parameter(Mandatory = $true, HelpMessage = "ECE Params")]
        [CloudEngine.Configurations.EceInterfaceParameters]
        $ECEParameters,

        [Parameter(Mandatory = $false, HelpMessage = "Define where to run from.")]
        [ValidateSet('Local','CSV')]
        [string]
        $RunFrom = "Local",

        [Parameter(Mandatory = $false, HelpMessage = "List of test names to exclude.")]
        [string[]]
        $Exclude,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to run will include Extended Tests.")]
        [switch]
        $ExtendedTests
    )

    $firewallRulesChanged = @()
    try
    {
        $script:ErrorActionPreference = 'Stop'
        Set-AzStackHciOutputPath -Path $OutputPath
        $allResult = @()

        Write-AzStackHciHeader -Invocation $MyInvocation -Params $PSBoundParameters -PassThru:$PassThru

        [string[]]$excludeTests = $Exclude
        $excludeTests += Get-FileExclusion
        if ($excludeTests.Count -gt 0)
        {
            Log-Info -Message ("The following tests will be excluded from execution: " + ($excludeTests -Join ", " | Out-String)) -Type Info
        }

        # Use the SBE role defined local cache path
        $templatedLocalSBEPath = $ECEParameters.Roles["SBE"].PublicConfiguration.PublicInfo.SBEContentPaths.SBELocalPath
        $defaultLocalShare = $ECEParameters.Roles["Cloud"].PublicConfiguration.PublicInfo.DefaultInfraStorageLocations.DefaultLocalShare

        if ($null -eq $defaultLocalShare)
        {
            $defaultLocalShare = "D:"
            Trace-Execution "Older build - using hardcoded path '$defaultLocalShare' to defaultLocalShare"
        }
        $sbeLocalPath = $templatedLocalSBEPath.Replace('{DefaultLocalShare}', $defaultLocalShare.TrimEnd('\'))
        $cacheBase = Join-Path -Path $sbeLocalPath -ChildPath $ECEParameters.Roles["SBE"].PublicConfiguration.PublicInfo.SBEContentPaths.RelativePaths.LocalSBECachePath

        if ("Local" -eq $RunFrom)
        {
            # Use the local cache path for the SBE package
            $sbeWorkingDir = Join-Path -Path $cacheBase -ChildPath $SBEVersion
            Log-Info -Message "Using '$sbeWorkingDir' to cache SBE content locally."
        }
        elseif ("CSV" -eq $RunFrom)
        {
            $sbeWorkingDir = $SBESourcePath
            Log-Info -Message "Will run health checks in place from CSV '$sbeWorkingDir'."
        }

        $excludeFromContent = @()
        if ($SBESourcePath -eq $SBEMetadataPath)
        {
            # The update service combines the content and metadata together
            $sbeMetadataFiles = (Get-ChildItem -Path $SBESourcePath | Where-Object {$PSItem.Name -like "SBE*.xml" -or $PSItem.Name -eq "oemMetadata.xml"})
            $sbeZip = Get-ChildItem -Path $SBESourcePath -Filter "SBE*.zip"
            [array]$excludeFromContent = [array]$sbeMetadataFiles.Name + $sbeZip.Name
            Log-Info -Message ("Will exclude the following files from local SBE content cache: " + ($excludeFromContent -Join ", " | Out-String))
        }

        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -Clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -Report $envcheckerReport

        Log-Info -Message ("Allow SMB-In firewall rules for duration of the SBE Health Checks.") -Type Info
        $firewallRulesChanged += Enable-SmbAccess -PsSession $PsSession
        if ($firewallRulesChanged.Count -gt 0)
        {
            foreach ($node in $firewallRulesChanged.Keys)
            {
                Log-Info -Message "SMB firewall rules enabled on '$($node)': $($firewallRulesChanged.$node -join ',')" -Type Info
            }
        }

        Log-Info -Message ("Check partner properties values match SBE manifest") -Type Info
        try
        {
            $result = Test-SBEPropertiesValid -ECEParameters $ECEParameters -SBEMetadataPath $SBEMetadataPath
        }
        catch
        {
            Log-Info -Message "Error validating partner properties in unattended.json with SBE manifest" -Type Error -ConsoleOut
            Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
            $exceptionResult = New-SBEHealthResultObject -TestName 'Test-SBEPropertiesValid' -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Validate partner property setting values"
            $detailedMessage = "Found invalid partnerProperties values or inconsistent SBE metadata. $($PSItem.Exception.Message)"
            $exceptionResult.Remediation = "Fix PartnerProperty values in deployment settings (or if after deployment using Set-SolutionExtensionProperty) to be compliant with the JSON schema in the <PartnerProperties> element of the SBE manifest."
            $exceptionResult.AdditionalData.Detail = $detailedMessage
            $allResult += $exceptionResult
            throw $detailedMessage
        }

        Log-Info -Message ("Check SBE credentials in secret store match SBE manifest") -Type Info
        try
        {
            $result = Test-SBECredentialsValid -ECEParameters $ECEParameters -SBEMetadataPath $SBEMetadataPath
        }
        catch
        {
            Log-Info -Message "Error validating SBE credentials in secret store with SBE manifest" -Type Error -ConsoleOut
            Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
            $exceptionResult = New-SBEHealthResultObject -TestName 'Test-SBECredentialsValid' -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Validate SBE credentials in secret store"
            $detailedMessage = "Found invalid SBE Credentials in secret store. $($PSItem.Exception.Message)"
            $exceptionResult.Remediation = "Correct issues with the indicated secrets in the Key Vault associated with this cluster and restart your deployment."
            $exceptionResult.AdditionalData.Detail = $detailedMessage
            $allResult += $exceptionResult
            throw $detailedMessage
        }

        # Pre-validation checks and preparation
        Log-Info -Message ("Validate the SolutionExtension module is present and meets the requirements for health testing.") -Type Info
        try
        {
            $result = Test-SolutionExtensionModule -PackagePath $SBESourcePath
            if ($false -eq $result)
            {
                $detailedMessage = "Skipping as the provided SolutionExtension module has not implemented any tests or does not support the HealthServiceIntegration tag."
                Log-Info -Message $detailedMessage -Type Info
                $instanceResult = New-SBEHealthResultObject -TestName 'Test-SolutionExtensionModule' -TargetName $env:ComputerName -Status 'SUCCESS' -Description "Validate SolutionExtension module exists and supports health tests"
                $instanceResult.AdditionalData.Detail = $detailedMessage
                $allResult += $instanceResult
                return $allResult
            }
        }
        catch
        {
            Log-Info -Message "The SolutionExtension module could not be validated" -Type Error -ConsoleOut
            Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
            $exceptionResult = New-SBEHealthResultObject -TestName 'Test-SolutionExtensionModule' -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Validate SolutionExtension module exists and supports health tests"
            $detailedMessage = "The SolutionExtension module could not be validated. $($PSItem.Exception.Message)"
            $exceptionResult.Remediation = "https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-troubleshoot#rerun-deployment"
            $exceptionResult.AdditionalData.Detail = $detailedMessage
            $allResult += $exceptionResult
            throw $detailedMessage
        }

        # Copy SBE package to local working dir if needed
        if ("Local" -eq $RunFrom)
        {
            try
            {
                $result = Copy-SBEContentLocalToNode -PackagePath $SBESourcePath -SkipNugetCopy:($Tag -ne 'Deployment') -TargetNodeName $env:ComputerName -ExcludeDirs @("IntegratedContent") -ExcludeFiles $excludeFromContent -DestPath $sbeWorkingDir
                if ($false -eq $result)
                {
                    throw "An error occurred during the SBE package copy operation. See logs for details."
                }
            }
            catch
            {
                Log-Info -Message "An error occurred during the SBE package copy operation" -Type Error -ConsoleOut
                Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
                $detailedMessage = $PSItem.Exception.Message
                $exceptionResult = New-SBEHealthResultObject -TestName 'Copy-SBEContentLocalToNode' -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Copy the SBE Package to working folder on '$($env:ComputerName)'"
                $exceptionResult.Remediation = "https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-troubleshoot#rerun-deployment"
                $exceptionResult.AdditionalData.Detail = $detailedMessage
                $allResult += $exceptionResult
                throw $detailedMessage
            }
        }

        # Validate SBE content integrity of working dir
        try
        {
            if (-not $SkipIntegrityTest)
            {
                $result = Invoke-TestSBEContentIntegrity -SBEMetadataPath $SBEMetadataPath -SBEContentPath $sbeWorkingDir
                if ($false -eq $result)
                {
                    throw "SBE content integrity check found irregularities in the files at '$($sbeWorkingDir)'. Check the ECE logs for more information."
                }
            }
        }
        catch
        {
            $detailedMessage = "SBE content failed integrity check at '$($sbeWorkingDir)'"
            Log-Info -Message $detailedMessage -Type Error -ConsoleOut
            Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
            $exceptionResult = New-SBEHealthResultObject -TestName 'Test-SBEContentIntegrity' -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Validate SBE content integrity"
            $exceptionResult.Remediation = "https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-troubleshoot#rerun-deployment"
            $exceptionResult.AdditionalData.Detail = $detailedMessage
            $allResult += $exceptionResult
            throw $detailedMessage
        }

        # Import the SolutionExtension module
        try
        {
            $result = Import-SolutionExtensionModule -PackagePath $sbeWorkingDir
        }
        catch
        {
            $detailedMessage = "Import SolutionExtension module from '$($sbeWorkingDir)' failed. The exception was: $($PSItem.Exception.Message)"
            Log-Info -Message "Import SolutionExtension module from '$($sbeWorkingDir)' failed." -Type Error -ConsoleOut
            Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
            $exceptionResult = New-SBEHealthResultObject -TestName 'Import-SolutionExtensionModule' -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Import SolutionExtension module"
            $exceptionResult.Remediation = "https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-troubleshoot#rerun-deployment"
            $exceptionResult.AdditionalData.Detail = $detailedMessage
            $allResult += $exceptionResult
            throw $detailedMessage
        }

        # Run validation
        try
        {
            $commonParams = Get-SBEHealthCheckParams -ECEParameters $ECEParameters -Tag $Tag -SBEMetadataPath $SBEMetadataPath
            $functionName = 'Get-SBEHealthCheckResult'
            $exceptionResult = $null
            $instanceResult = @()
            $functionFound = Get-Command -Module SolutionExtension -Name $functionName -ErrorAction SilentlyContinue
            if ($null -eq $functionFound)
            {
                $detailedMessage = "A function named '$($functionName)' was not found in the SolutionExtension module."
                Log-Info -Message $detailedMessage -Type Error -ConsoleOut
                $thisResult = New-SBEHealthResultObject -TestName $functionName -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Invoke $functionName"
                $thisResult.AdditionalData.Detail = $detailedMessage
                $instanceResult += $thisResult
            }
            else
            {
                $params = $commonParams
                $solExtVersion = $functionFound.Version.ToString()
                Log-Info -Message "SolutionExtension version being used: $solExtVersion" -Type Info
                if (($excludeTests.Count -gt 0) -and ((Get-Command -Name $functionName).Parameters.Keys -contains "ExcludeTest"))
                {
                    $params += @{
                        ExcludeTest = $excludeTests
                    }
                }
                if ((Get-Command -Name $functionName).Parameters.Keys -contains "ExtendedTests")
                {
                    $params += @{
                        ExtendedTests = $ExtendedTests.IsPresent
                    }
                }
                Log-Info -Message "Invoke $functionName on $($env:ComputerName)" -Type Info
                [array]$thisResult = & $functionName @params
                if ($thisResult.Count -eq 0)
                {
                    Log-Info -Message "'$($functionName)' did not return any test results or no tests have been implemented." -Type Warning
                    $detailedMessage = "'$($functionName)' did not return any test results or no tests have been implemented."
                    $thisResult = New-SBEHealthResultObject -TestName $functionName -TargetName $env:ComputerName -Status 'SUCCESS' -Description "No health check results were returned by '$functionName'"
                    $thisResult.AdditionalData.Detail = $detailedMessage
                    $instanceResult += $thisResult
                }
                else
                {
                    [array]$assertResult = Assert-ResponseSchemaValid -ResultObject $thisResult
                    if ($assertResult.Count -gt 0) { $instanceResult += $assertResult }
                }
            }
        }
        catch
        {
            # Unexpected exception occurred during partner tests
            Log-Info -Message "An error occurred during '$($functionName)'" -Type Error -ConsoleOut
            Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
            $exceptionResult = New-SBEHealthResultObject -TestName $functionName -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "$functionName on $($env:ComputerName)"
            $exceptionResult.Remediation = "https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-troubleshoot#rerun-deployment"
            $exceptionResult.AdditionalData.Detail = "An unhandled error occurred: " + ($PSItem | Format-List * | Out-String).Trim()
            $instanceResult += $exceptionResult
            $allResult += $instanceResult
            throw $PSItem
        }
        finally
        {
            Log-Info -Message "Before adding $($functionName) instances... all count = $($allResult.Count) / instance count = $($instanceResult.Count))"
            if ($null -ne $instanceResult) { $allResult += $instanceResult }
        }

        try
        {
            $jobRun = @()
            $exceptionResult = $null
            $instanceResult = @()
            $functionName = 'Get-SBEHealthCheckResultOnNode'
            $functionFound = Get-Command -Module SolutionExtension -Name $functionName -ErrorAction SilentlyContinue
            if ($null -eq $functionFound)
            {
                # NOTE: The only way this could fail if the SBE was tampered with
                $detailedMessage = "A function named '$($functionName)' was not found in the SolutionExtension module."
                Log-Info -Message $detailedMessage -Type Error -ConsoleOut
                $exceptionResult = New-SBEHealthResultObject -TestName $functionName -TargetName $env:ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Invoke $functionName"
                $exceptionResult.Remediation = $detailedMessage + " Please contact product support."
                $exceptionResult.AdditionalData.Detail = $detailedMessage
                $allResult += $exceptionResult
                throw $detailedMessage
            }
            else
            {
                if ($null -eq $commonParams)
                {
                    $commonParams = Get-SBEHealthCheckParams -ECEParameters $ECEParameters -Tag $Tag -SBEMetadataPath $SBEMetadataPath
                }
                $params = $commonParams
                if (($excludeTests.Count -gt 0) -and ((Get-Command -Name $functionName).Parameters.Keys -contains "ExcludeTest"))
                {
                    $params += @{
                        ExcludeTest = $excludeTests
                    }
                }
                if ((Get-Command -Name $functionName).Parameters.Keys -contains "ExtendedTests")
                {
                    $params += @{
                        ExtendedTests = $ExtendedTests.IsPresent
                    }
                }
                if ("Local" -eq $RunFrom)
                {
                    # Define scriptblock for parallel copy operations
                    $copySBEScriptBlock = {
                        param(
                            [string]$ComputerName,
                            [PSCredential]$Credential,
                            [string]$SBESourcePath,
                            [string]$Tag,
                            [string]$sbeWorkingDir,
                            [string[]]$excludeFromContent,
                            [string]$HelperModulePath,
                            [string]$ReportingModulePath,
                            [string]$PortableUtilitiesModulePath
                        )

                        # Import required modules in job context
                        Import-Module $ReportingModulePath -DisableNameChecking -Global -Force
                        Import-Module $PortableUtilitiesModulePath -DisableNameChecking -Global -Force
                        Import-Module $HelperModulePath -DisableNameChecking -Global -Force

                        $jobResult = @{
                            ComputerName = $ComputerName
                            Success = $false
                            Error = $null
                            FirewallRulesChanged = @{}
                            Messages = [System.Collections.Generic.List[string]]::new()
                        }

                        try
                        {
                            # Check if we can reach the remote system on port 445 and enable firewall rule FPS-SMB-In-TCP if we can't
                            if (-not (Test-NetConnection -ComputerName $ComputerName -Port 445 -InformationLevel Quiet))
                            {
                                $jobResult.Messages.Add("Failed to reach $ComputerName on port 445")
                                $jobResult.Messages.Add("Attempting to enable SMB-In firewall rules.")

                                # Create a temporary session for enabling SMB access
                                $tempSession = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
                                $fwRulesChanged = Enable-SmbAccess -PsSession $tempSession
                                if ($fwRulesChanged.Count -gt 0)
                                {
                                    $jobResult.FirewallRulesChanged = $fwRulesChanged
                                    foreach ($node in $fwRulesChanged.Keys)
                                    {
                                        $jobResult.Messages.Add("SMB firewall rules enabled on '$node': $($fwRulesChanged.$node -join ',')")
                                    }
                                }
                                Remove-PSSession -Session $tempSession -ErrorAction SilentlyContinue

                                # Retry the connection to the remote system on port 445
                                if (-not (Test-NetConnection -ComputerName $ComputerName -Port 445 -InformationLevel Quiet))
                                {
                                    throw "Failed to reach $ComputerName on port 445 after enabling SMB-In firewall rules. Some other network policy, or a custom local firewall rule is blocking SMB access to '$ComputerName'."
                                }
                            }

                            $result = Copy-SBEContentLocalToNode -PackagePath $SBESourcePath -SkipNugetCopy:($Tag -ne 'Deployment') -TargetNodeName $ComputerName -ExcludeDirs @("IntegratedContent") -ExcludeFiles $excludeFromContent -Credential $Credential -DestPath $sbeWorkingDir
                            if ($false -eq $result)
                            {
                                throw "An error occurred during the SBE package copy operation to '$ComputerName'. See logs for details."
                            }
                            $jobResult.Success = $true
                        }
                        catch
                        {
                            $jobResult.Error = $_.Exception.Message
                        }

                        return $jobResult
                    }

                    # Process nodes in batches of 8
                    $batchSize = 8
                    $totalNodes = $PsSession.Count
                    Log-Info "Starting parallel copy of SBE content to $totalNodes nodes in batches of $batchSize"

                    for ($batchStart = 0; $batchStart -lt $totalNodes; $batchStart += $batchSize)
                    {
                        $batchEnd = [Math]::Min($batchStart + $batchSize - 1, $totalNodes - 1)
                        $currentBatchSize = $batchEnd - $batchStart + 1
                        $batchNumber = [Math]::Floor($batchStart / $batchSize) + 1
                        $totalBatches = [Math]::Ceiling($totalNodes / $batchSize)

                        Log-Info "Processing batch $batchNumber of $totalBatches ($currentBatchSize nodes)"

                        $jobs = @()
                        for ($i = $batchStart; $i -le $batchEnd; $i++)
                        {
                            $session = $PsSession[$i]
                            Log-Info "  Starting copy job for: '$($session.ComputerName)'"

                            $thisCred = $session.Runspace.ConnectionInfo.Credential
                            $helperModulePath = Join-Path $PSScriptRoot "AzStackHci.SBEHealth.Helpers.psm1"
                            $reportingModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "AzStackHci.EnvironmentChecker.Reporting.psm1"
                            $portableUtilitiesModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "AzStackHci.EnvironmentChecker.PortableUtilities.psm1"

                            $job = Start-Job -ScriptBlock $copySBEScriptBlock -ArgumentList `
                                $session.ComputerName, `
                                $thisCred, `
                                $SBESourcePath, `
                                $Tag, `
                                $sbeWorkingDir, `
                                $excludeFromContent, `
                                $helperModulePath, `
                                $reportingModulePath, `
                                $portableUtilitiesModulePath

                            $jobs += $job
                        }

                        # Process results from parallel copy jobs
                        Log-Info "Waiting for batch $batchNumber jobs to complete..."
                        $batchOutput = Wait-SBECopyNodeBatch -Jobs $jobs -FunctionName $functionName

                        foreach ($node in $batchOutput.FirewallRulesChanged.Keys)
                        {
                            $firewallRulesChanged[$node] = $batchOutput.FirewallRulesChanged[$node]
                        }
                        $allResult += $batchOutput.Results

                        if ($batchOutput.HasError)
                        {
                            throw $batchOutput.ErrorMessage
                        }

                        Log-Info "Batch $batchNumber completed successfully"
                    }

                    Log-Info "All parallel copy operations completed successfully"
                } # End of Local copy to remote nodes

                # Resolve the SBE Role helpers path once here (in the caller) so that each remote
                # node job receives it as a pre-computed value, avoiding a NuGet provider bootstrap
                # on every node.
                $sbeRoleHelpersPath = $null
                if (-not $SkipIntegrityTest)
                {
                    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
                    $sbeRoleHelpersPath = Join-Path $sbeRoleNuget "content\Helpers"
                    Log-Info -Message "Resolved SBE Role helpers path: '$sbeRoleHelpersPath'"
                }

                # Process sessions in batches to avoid overloading the system
                $batchSize = 8
                $sessionBatches = @()
                for ($i = 0; $i -lt $PsSession.Count; $i += $batchSize)
                {
                    $endIndex = [Math]::Min($i + $batchSize - 1, $PsSession.Count - 1)
                    $sessionBatches += ,@($PsSession[$i..$endIndex])
                }

                $batchNumber = 0
                foreach ($sessionBatch in $sessionBatches)
                {
                    $batchNumber++
                    Log-Info -Message "Processing batch $batchNumber of $($sessionBatches.Count) (batch size: $($sessionBatch.Count))"

                    $jobRun = @()
                    try
                    {
                        foreach ($session in $sessionBatch)
                        {
                            Log-Info -Message "Invoke $functionName on '$($session.ComputerName)'"

                            $argList = @($functionName, $params, $sbeWorkingDir, $SBEMetadataPath, $RunFrom, $SkipIntegrityTest, $sbeRoleHelpersPath)
                            $jobRun += Invoke-Command -Session $session -ScriptBlock ${function:Invoke-SBEHealthCheckWithPrerequisites} -AsJob -ArgumentList $argList
                        }
                    }
                    catch
                    {
                        Log-Info -Message "An unhandled error occurred on '$($session.ComputerName)' during '$($functionName)'" -Type Error -ConsoleOut
                        Log-Info -Message ("The exception message was: $($PSItem.Exception.Message)") -Type Error -ConsoleOut
                        $detailedMessage = $PSItem.Exception.Message
                        $exceptionResult = New-SBEHealthResultObject -TestName $functionName -TargetName $session.ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Invoke '$($functionName)' on '$($session.ComputerName)'"
                        $exceptionResult.AdditionalData.Detail = $detailedMessage
                        $allResult += $exceptionResult

                        # Stop any jobs already started in this batch
                        foreach ($job in $jobRun)
                        {
                            if ($job.State -eq 'Running')
                            {
                                Log-Info -Message "Stopping job on '$($job.Location)' due to exception."
                                $job | Stop-Job
                            }
                        }

                        throw $detailedMessage
                    }

                    # Wait for batch jobs to complete with a timeout after 30 minutes
                    Log-Info -Message "Waiting for batch $batchNumber '$($functionName)' jobs to complete"
                    $waitJob = $true
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $timeoutMinutes = 30
                    while ($true -eq $waitJob)
                    {
                        if ($stopwatch.Elapsed.TotalMinutes -ge $timeoutMinutes)
                        {
                            Log-Info -Message "Batch $batchNumber jobs have not completed in the specifiedtimeout period." -Type Error
                            $stopwatch.Stop()
                            $waitJob = $false
                        }
                        else
                        {
                            $keepWaiting = $false
                            foreach ($job in $jobRun.ChildJobs)
                            {
                                if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted' -or $job.State -eq 'Suspended')
                                {
                                    $keepWaiting = $true
                                }
                            }
                            if ($false -eq $keepWaiting)
                            {
                                $stopwatch.Stop()
                                $waitJob = $false
                            }
                            else
                            {
                                Start-Sleep -Seconds 30
                            }
                        }
                    }

                    foreach ($job in $jobRun.ChildJobs)
                    {
                        $thisComputerName = $job.Location
                        if ($job.State -eq 'Failed')
                        {
                            [string]$detailedMessage = "Error while running '$($functionName)' on '$($thisComputerName)'.  Exception message: " + $job.JobStateInfo.Reason.Message
                            Log-Info -Message $detailedMessage -Type Error -ConsoleOut
                            $exceptionResult = New-SBEHealthResultObject -TestName $functionName -TargetName $job.Location -Status 'FAILURE' -Severity 'CRITICAL' -Description "An exception occurred during $functionName"
                            $exceptionResult.AdditionalData.Detail = $detailedMessage
                            $allResult += $exceptionResult
                        }
                        elseif ($job.State -eq 'Running')
                        {
                            Log-Info -Message "'$($functionName)' was still running on '$($thisComputerName)' when the timeout period was hit." -Type Warning
                            $job | Stop-Job
                        }
                        else
                        {
                            Log-Info -Message "Log results for '$($thisComputerName)'" -Type Info
                            [array]$thisOutput = $job.Output
                            if ($thisOutput.Count -gt 0)
                            {
                                $instanceResult += $thisOutput
                            }
                        }
                    }
                }

                if ($instanceResult.Count -gt 0)
                {
                    [array]$assertResult = Assert-ResponseSchemaValid -ResultObject $instanceResult
                    if ($assertResult.Count -gt 0) { $instanceResult += $assertResult }
                }
                else
                {
                    Log-Info -Message "'$($functionName)' did not return any test results or no tests have been implemented." -Type Warning
                    $detailedMessage = "'$($functionName)' did not return any test results or no tests have been implemented."
                    $thisResult = New-SBEHealthResultObject -TestName $functionName -TargetName $env:ComputerName -Status 'FAILURE' -Description "Received health check results from $functionName"
                    $thisResult.AdditionalData.Detail = $detailedMessage
                    $instanceResult += $thisResult
                }
            }
        }
        catch
        {
            if ($null -ne $exceptionResult)
            {
                Log-Info -Message "'$($functionName)' hit exception - adding result details: $($exceptionResult.AdditionalData.Detail)" -Type Warning
                $instanceResult += $exceptionResult
                $allResult += $instanceResult
            }
            foreach ($job in $jobRun.ChildJobs)
            {
                if ($job.State -eq 'Running')
                {
                    Log-Info -Message "'$($functionName)' was still running on '$($thisComputerName)' when an exception occurred." -Type Warning
                    $job | Stop-Job
                }
            }
            throw $PSItem
        }
        finally
        {
            Log-Info -Message "Before adding $($functionName) instances... all count = $($allResult.Count) / instance count = $($instanceResult.Count) )"
            if ($null -ne $instanceResult) { $allResult += $instanceResult }
        }

        Log-Info -Message "Returning with all count = $($allResult.Count)"
        return $allResult
    }
    catch
    {
        Log-Info -Message "" -ConsoleOut
        Log-Info -Message "$($PSItem.Exception.Message)" -ConsoleOut -Type Error
        Log-Info -Message "$($PSItem.ScriptStackTrace)" -ConsoleOut -Type Error
        $cmdletException = $PSItem
        if ($allResult.Count -eq 0)
        {
            throw $PSItem
        }
        else
        {
            Log-Info -Message "Returning with all count = $($allResult.Count)"
            return $allResult
        }
    }
    finally
    {
        Log-Info -Message "Performing clean up"
        $cleanupScriptBlock = {
            Get-Module -Name SolutionExtension -ErrorAction SilentlyContinue | Remove-Module -Force -Verbose:$false
            <#
            We now depend on deploy and action plans to clean up the cache dirs we leave behind for them
            if ($null -eq $sbeWorkingDir)
            {
                $sbeWorkingDir = $using:sbeWorkingDir
            }
            if (Test-Path -Path $sbeWorkingDir)
            {
                Write-Output "Remove SBE temporary working folder '$($sbeWorkingDir)' on '$($env:ComputerName)'"
                Remove-Item -Path $sbeWorkingDir -Recurse -Force
            }
            #>
        }
        if ($PsSession.Count -gt 0)
        {
            $jobClean = Invoke-Command -Session $PsSession -ScriptBlock $cleanupScriptBlock -AsJob
            $jobClean | Wait-Job | Out-Null
            foreach ($job in $jobClean.ChildJobs)
            {
                if ($job.State -eq 'Failed')
                {
                    [string]$detailedMessage = "An exception occurred during clean-up on '$($job.Location)'.  Exception message: " + $job.JobStateInfo.Reason.Message
                    Log-Info -Message $detailedMessage -Type Warning
                }
                else
                {
                    [string]$output = $job.Output
                    Log-Info -Message $output -Type Info
                }
            }
            # If we enabled any SMB-In rules, disable them now
            if ($firewallRulesChanged.Count -gt 0)
            {
                foreach ($session in $PsSession)
                {
                    Log-Info "Returning SMB firewall rules to original state on '$($session.ComputerName)'."
                    Disable-SmbAccess -PsSession $session -Rules $firewallRulesChanged.($session.ComputerName)
                }
                Log-Info -Message ""
            }
        }
        else
        {
            Invoke-Command -ScriptBlock $cleanupScriptBlock
        }

        $script:ErrorActionPreference = 'SilentlyContinue'
        # Write result to telemetry channel
        foreach ($res in $allResult)
        {
            Write-ETWResult -Result $res
        }
        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'SBEHealth' -Value $allResult -Force
        $envcheckerReport = Close-AzStackHciEnvJob -Report $envcheckerReport
        Write-AzStackHciEnvReport -Report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

# SIG # Begin signature block
# MIInRgYJKoZIhvcNAQcCoIInNzCCJzMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAbEWh9y7lq9SCO
# eWaACoi97DbFlfG8P5rCxM3MVpfUjqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGtjNI7g
# UmyqAvxcF2lZV3ItEDpzc75WxKM3zZHdqCD2MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAeFzfGtZqDJGSQx7fTTJrq8ajOQ+HXIK4EFfIfw1A
# Dy6ONdUD3O83PzE3Jpt6xglXensx23hZ2nkCRnNBtkGIz/v+YWoMQTpEEs80NSdL
# V4lc8UwWtaX2eJP1NcK9FiTIyW6qkle2um9jEr7kzUljTpm/suhhEYhBHf39WV1c
# 9B31MjP7iv7ati29U9Q73KvEl5JzNrA5FylVp5jgxtrRAmXQd/M1m2DinKRlrsIW
# MNoSqv33NlHz2lOSrTdPCgS7EbudPpl5ypwdrx3K3bsdZQ/Gy8vehp6Sv/m3NE/O
# RIcRW/a+HCjGAI+30C3zGh4NDow9F6VPEO1bzauw0OX1PqGCF5QwgheQBgorBgEE
# AYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCCy/fleYllP1fnz9fTronG1ufYMbG/GwGmgFHeZ
# +cQ1SwIGaeeNG/EUGBMyMDI2MDUwMzE0MzExMC40NDdaMASAAgH0oIHRpIHOMIHL
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
# SIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBNxCu7yffebQxHtj5XRhfzITxHnRTl
# OzidFFKaOXJEhzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEghPTdqm/dR
# yZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGYMIGApH4wfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCysZCIAAQAAAiQwIgQgA//oxm2fo5LO
# mmtYNHLZwfdHBrA0Jfu1dxOXSFqdBYowDQYJKoZIhvcNAQELBQAEggIAGif/fvRl
# 9Z5DZsazY/LkQLmsfSAoMl3ivje1DgBrcEniY+L8lCRMIFLkOwiWAaRp7fCzlI3T
# mf0b9SBtOihIL4a+Kyap6mHv1zaeq+VcAh3fhswSDbzmnC2StFjsUrnTCozo3P7W
# JBbV/QbBhFVOtzUDY0atOkVXNC7x3EEEbPWGmYeDqeVPTpqgwf1aCS/4d+pcHX2t
# jVn+vEuV+YmWiko0EYrxKGDIpGVAK5KNa52cBYJUTfshhRybQiOjP6SOiOhfWpek
# f7tcEGmJ2t8xqzcVgHTXXwTkoI2ZsfDItnNd4dONl2QEuKRvFo6ihiO/0oFnJO+F
# X/6VTL7Y2MoC9Rjtk8sz5v/aPyRjQtMeyhlSshINFWnH9I6dcNlj5kqIldeyBADd
# KRu11JkI7iQFCQ16HjUfGTd88uC502di5xoL5rNllGgsJUzjihw2DeUBDHVOyXtc
# x3YjH1DjZSZ40WNdNPZ98WxxiH03STBvvwqW3P30F4Os5P8I1mBA8Qa/nrfN++kC
# AGYraBhxtXiW1fFIw2P7r8xn2t1gcLN0LE+oQbnMdPyeZTP0rXLflfR3mdAYE+PT
# O4Fxg7uN0HyNmvD9hIST7UMx8LG/l7y3ANYsmdpjJfrtcECDfCGq8gz9VNimMhoI
# T5hJMsBRTI1CdHg9wVw/UIrgXFgWMluk/bY=
# SIG # End signature block
