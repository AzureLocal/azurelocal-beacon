# Module-level variables for cache paths
$script:CacheDirectory = Join-Path $env:ProgramData "AzStackHci\EnvironmentChecker\ManifestCache"
$script:NuGetStoreDirectory = "C:\NugetStore"
$script:ManifestNuGetName = "AzStackHci.EnvironmentChecker.Manifest"
$script:CachedManifestPath = Join-Path $script:NuGetStoreDirectory "$script:ManifestNuGetName\AzStackHci.EnvironmentChecker.Manifest.xml"
$script:CachedManifestMetadataPath = Join-Path $script:CacheDirectory "manifest.metadata.json"
$script:SideloadedManifestPath = Join-Path $script:CacheDirectory "manifest.sideloaded.xml"
$script:SideloadedManifestMetadataPath = Join-Path $script:CacheDirectory "manifest.sideloaded.metadata.json"
$script:CacheTTLHours = 24

function Get-AzureEnvironment {
    <#
    .SYNOPSIS
        Gets the Azure environment from the Azure Connected Machine Agent.
    #>
    [CmdletBinding()]
    param()

    try {
        $azcmagentPath = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
        if (Test-Path $azcmagentPath) {
            $json = & $azcmagentPath show -j 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($json -and $json.Cloud) {
                Write-Verbose "Azure Environment detected: $($json.Cloud)"
                return $json.Cloud
            }
        }
        Write-Verbose "Could not detect Azure environment, defaulting to AzureCloud"
        return "AzureCloud"
    }
    catch {
        Write-Verbose "Error detecting Azure environment: $_"
        return "AzureCloud"
    }
}

function Get-ModuleYYMMVersion {
    <#
    .SYNOPSIS
        Gets the YYMM version from the module's System.Version.
    #>
    [CmdletBinding()]
    param()

    try {
        $module = Get-Module -Name AzStackHci.EnvironmentChecker -ErrorAction SilentlyContinue
        if (-not $module) {
            # Try to get from manifest
            $manifestPath = Join-Path $PSScriptRoot "AzStackHci.EnvironmentChecker.psd1"
            if (Test-Path $manifestPath) {
                $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
                if ($manifest.ModuleVersion) {
                    $version = [System.Version]$manifest.ModuleVersion
                    $yymmVersion = $version.Minor.ToString("D4")
                    Write-Verbose "Module YYMM version from manifest: $yymmVersion"
                    return $yymmVersion
                }
            }
        }
        else {
            $version = $module.Version
            $yymmVersion = $version.Minor.ToString("D4")
            Write-Verbose "Module YYMM version: $yymmVersion"
            return $yymmVersion
        }

        Write-Verbose "Could not determine module version, defaulting to 2601"
        return "2601"
    }
    catch {
        Write-Verbose "Error getting module version: $_"
        return "2601"
    }
}

function Initialize-ManifestCacheDirectory {
    <#
    .SYNOPSIS
        Ensures the manifest cache directory exists.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:CacheDirectory)) {
        try {
            New-Item -Path $script:CacheDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created manifest cache directory: $script:CacheDirectory"
        }
        catch {
            Write-Warning "Failed to create cache directory: $_"
        }
    }
}

function Test-ManifestCacheValidity {
    <#
    .SYNOPSIS
        Checks if cached manifest is valid and within TTL.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:CachedManifestPath) -or -not (Test-Path $script:CachedManifestMetadataPath)) {
        Write-Verbose "Cached manifest or metadata not found"
        return $false
    }

    try {
        $metadata = Get-Content -Path $script:CachedManifestMetadataPath -Raw | ConvertFrom-Json
        $timestampDate = [DateTime]::Parse($metadata.Timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $cacheAge = (Get-Date) - $timestampDate

        if ($cacheAge.TotalHours -gt $script:CacheTTLHours) {
            Write-Verbose "Cached manifest expired (age: $($cacheAge.TotalHours) hours, TTL: $script:CacheTTLHours hours)"

            # Clean up expired cache files (leave sideloaded manifest alone)
            try {
                if (Test-Path $script:CachedManifestPath) {
                    Remove-Item -Path $script:CachedManifestPath -Force -ErrorAction Stop
                    Write-Verbose "Removed expired cached manifest: $script:CachedManifestPath"
                }
                if (Test-Path $script:CachedManifestMetadataPath) {
                    Remove-Item -Path $script:CachedManifestMetadataPath -Force -ErrorAction Stop
                    Write-Verbose "Removed expired cached manifest metadata: $script:CachedManifestMetadataPath"
                }
            }
            catch {
                Write-Warning "Failed to clean up expired cache: $_"
            }

            return $false
        }

        Write-Verbose "Cached manifest is valid (age: $($cacheAge.TotalHours) hours)"
        return $true
    }
    catch {
        Write-Verbose "Error validating cache: $_"
        return $false
    }
}

function Save-ManifestToCache {
    <#
    .SYNOPSIS
        Saves manifest and metadata to cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$XmlContent,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $false)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [bool]$SignatureValid
    )

    Initialize-ManifestCacheDirectory

    try {
        # Save manifest content
        Set-Content -Path $script:CachedManifestPath -Value $XmlContent -Force -ErrorAction Stop

        # Save metadata
        $metadata = @{
            Timestamp = (Get-Date).ToString("o")
            Source = $Source
            Url = $Url
            SignatureValid = $SignatureValid
            TTLHours = $script:CacheTTLHours
        }
        $metadata | ConvertTo-Json | Set-Content -Path $script:CachedManifestMetadataPath -Force -ErrorAction Stop

        Write-Verbose "Manifest cached successfully to: $script:CachedManifestPath"

        # Log telemetry
        $telemetryData = @{
            Event = "ManifestCached"
            Source = $Source
            Url = $Url
            SignatureValid = $SignatureValid
            Timestamp = $metadata.Timestamp
        }
        Write-Verbose "Telemetry: $($telemetryData | ConvertTo-Json -Compress)"
    }
    catch {
        Write-Warning "Failed to cache manifest: $_"
    }
}

function Get-CachedManifest {
    <#
    .SYNOPSIS
        Retrieves manifest from cache if valid.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-ManifestCacheValidity)) {
        return $null
    }

    try {
        $xmlContent = Get-Content -Path $script:CachedManifestPath -Raw -ErrorAction Stop
        $metadata = Get-Content -Path $script:CachedManifestMetadataPath -Raw | ConvertFrom-Json

        Write-Verbose "Using cached manifest from: $script:CachedManifestPath"

        # Log telemetry
        $timestampDate = [DateTime]::Parse($metadata.Timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $cacheAge = (Get-Date) - $timestampDate
        $telemetryData = @{
            Event = "ManifestLoadedFromCache"
            Source = $metadata.Source
            OriginalUrl = $metadata.Url
            CacheAge = $cacheAge.TotalHours
            SignatureValid = $metadata.SignatureValid
            Timestamp = (Get-Date).ToString("o")
        }
        Write-Verbose "Telemetry: $($telemetryData | ConvertTo-Json -Compress)"

        return @{
            Content = $xmlContent
            Source = "Cache"
            OriginalSource = $metadata.Source
            SignatureValid = $metadata.SignatureValid
            CacheAge = $cacheAge.TotalHours
        }
    }
    catch {
        Write-Verbose "Failed to read cached manifest: $_"
        return $null
    }
}

function Set-ValidationManifest {
    <#
    .SYNOPSIS
        Sideloads a validation manifest that takes precedence over downloaded manifests.

    .DESCRIPTION
        Allows administrators to sideload a custom validation manifest. The sideloaded manifest
        takes precedence over downloaded/cached manifests and persists across invocations.
        By default, the manifest signature is validated.

        When PsSession is provided, the manifest is sideloaded to all specified remote nodes,
        enabling cluster-wide manifest override deployment.

    .PARAMETER ManifestPath
        Path to the XML manifest file to sideload.

    .PARAMETER EnforceSignature
        If true, requires the manifest to be digitally signed by Microsoft. Default is true.

    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If provided, the manifest will be sideloaded
        to all remote nodes in addition to the local node.

    .PARAMETER Force
        Bypasses confirmation prompts.

    .EXAMPLE
        Set-ValidationManifest -ManifestPath "C:\custom\manifest.xml"
        Sideloads a manifest with signature validation on the local node only.

    .EXAMPLE
        Set-ValidationManifest -ManifestPath "C:\custom\manifest.xml" -EnforceSignature $false
        Sideloads a manifest without signature validation on the local node only.

    .EXAMPLE
        $sessions = Get-ClusterNode | ForEach-Object { New-PSSession -ComputerName $_.Name }
        Set-ValidationManifest -ManifestPath "C:\custom\manifest.xml" -PsSession $sessions
        Sideloads a manifest to all cluster nodes via PSSessions.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$ManifestPath,

        [Parameter(Mandatory = $false)]
        [bool]$EnforceSignature = $true,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]$PsSession,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Initialize telemetry decision object
    $telemetryDecision = @{
        ProcessingStatus = "Unknown"
        ProcessingMessage = ""
        ManifestSource = "Sideload"
        ManifestPath = $ManifestPath
        SignatureValid = $null
        EnforceSignature = $EnforceSignature
        SideloadedBy = $env:USERNAME
        SideloadedFrom = $env:COMPUTERNAME
        Timestamp = (Get-Date).ToString("o")
        DeploymentScope = if ($PsSession -and $PsSession.Count -gt 0) { "Cluster" } else { "Local" }
        TotalNodes = 0
        SuccessfulNodes = 0
        FailedNodes = 0
        ErrorDetails = $null
    }

    try {
        Initialize-ManifestCacheDirectory

    # Check if a sideloaded manifest already exists
    if (Test-Path $script:SideloadedManifestPath) {
        Write-Host "`n=== EXISTING SIDELOADED MANIFEST DETECTED ===" -ForegroundColor Yellow

        # Try to read existing metadata
        $existingMetadata = $null
        if (Test-Path $script:SideloadedManifestMetadataPath) {
            try {
                $existingMetadata = Get-Content -Path $script:SideloadedManifestMetadataPath -Raw | ConvertFrom-Json
                Write-Host "`nExisting Manifest Details:" -ForegroundColor Cyan
                Write-Host "  Sideloaded by: $($existingMetadata.SideloadedBy)" -ForegroundColor Gray
                Write-Host "  Sideloaded from: $($existingMetadata.SideloadedFrom)" -ForegroundColor Gray
                Write-Host "  Timestamp: $($existingMetadata.Timestamp)" -ForegroundColor Gray
                Write-Host "  Source path: $($existingMetadata.SourcePath)" -ForegroundColor Gray
                Write-Host "  Signature validated: $($existingMetadata.SignatureValid)" -ForegroundColor Gray
            }
            catch {
                Write-Host "  (Unable to read existing manifest metadata)" -ForegroundColor Gray
            }
        }

        # Parse existing and new manifests to check for conflicts
        $existingXml = $null
        $newXml = $null
        $hasApplicableValidators = $false
        $conflicts = @()

        try {
            $existingContent = Get-Content -Path $script:SideloadedManifestPath -Raw
            [xml]$existingXml = $existingContent

            # Read and parse new manifest
            $newContent = Get-Content -Path $ManifestPath -Raw -ErrorAction Stop
            [xml]$newXml = $newContent

            # Validate new manifest against XSD
            Write-Verbose "Validating new manifest against XSD schema..."
            $xsdValidation = Test-ManifestXsdValidation -ManifestXml $newXml
            if (-not $xsdValidation.IsValid -and $xsdValidation.SchemaValidated) {
                $xsdErrorMessage = "Manifest XSD validation failed. The manifest does not conform to the required schema and cannot be sideloaded. $($xsdValidation.ErrorMessage)"
                Write-Error $xsdErrorMessage

                # Update telemetry decision object
                $telemetryDecision.ProcessingStatus = "XsdValidationFailed"
                $telemetryDecision.ProcessingMessage = $xsdErrorMessage
                $telemetryDecision.ErrorDetails = @{
                    ValidationErrors = $xsdValidation.Errors
                    ErrorCount = $xsdValidation.Errors.Count
                }

                throw $xsdErrorMessage
            }
            Write-Verbose "New manifest passed XSD validation"

            # Validate existing manifest against XSD
            Write-Verbose "Validating existing manifest against XSD schema..."
            $existingXsdValidation = Test-ManifestXsdValidation -ManifestXml $existingXml
            if (-not $existingXsdValidation.IsValid -and $existingXsdValidation.SchemaValidated) {
                $existingXsdError = "Existing sideloaded manifest failed XSD validation and cannot be processed. $($existingXsdValidation.ErrorMessage)"
                Write-Warning $existingXsdError
                Write-Host "  (Unable to parse manifest content for conflict detection: Manifest XSD validation failed. Please fix the manifest structure before sideloading.)" -ForegroundColor Gray

                # Log existing manifest XSD failure but don't block new manifest
                # Create separate telemetry event for existing manifest validation failure
                try {
                    Import-Module "$PSScriptRoot\AzStackHci.EnvironmentChecker.Reporting.psm1" -Force -ErrorAction SilentlyContinue
                    $existingManifestTelemetry = @{
                        ProcessingStatus = "ExistingManifestXsdValidationFailed"
                        ProcessingMessage = $existingXsdError
                        ManifestSource = "ExistingSideload"
                        ErrorDetails = @{
                            ValidationErrors = $existingXsdValidation.Errors
                            ErrorCount = $existingXsdValidation.Errors.Count
                        }
                        Timestamp = (Get-Date).ToString("o")
                    }
                    Write-ManifestTelemetry -ManifestDecision $existingManifestTelemetry
                }
                catch {
                    Write-Verbose "Failed to write existing manifest XSD validation telemetry: $_"
                }
            }

            # Get current module version for version range checks
            $currentVersion = Get-ModuleYYMMVersion

            # Check if existing manifest has validators that are currently applicable
            if ($existingXml.ValidationManifest.Validators.Validator) {
                $existingValidators = @($existingXml.ValidationManifest.Validators.Validator)
                Write-Host "`nExisting Manifest Content:" -ForegroundColor Cyan
                Write-Host "  Manifest version: $($existingXml.ValidationManifest.Version)" -ForegroundColor Gray
                Write-Host "  Validators: $($existingValidators.Count)" -ForegroundColor Gray

                foreach ($validator in $existingValidators) {
                    $minVersion = if ($validator.MinVersion) { $validator.MinVersion } else { $null }
                    $maxVersion = if ($validator.MaxVersion) { $validator.MaxVersion } else { $null }

                    $isApplicable = Test-VersionInRange -CurrentVersion $currentVersion -MinVersion $minVersion -MaxVersion $maxVersion

                    if ($isApplicable) {
                        $hasApplicableValidators = $true
                        Write-Host "    - $($validator.Id): Currently applicable (version range: [$minVersion, $maxVersion])" -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "    - $($validator.Id): Not applicable for current version $currentVersion" -ForegroundColor Gray
                    }
                }
            }

            # Check for conflicts between old and new manifests
            if ($newXml.ValidationManifest.Validators.Validator) {
                $newValidators = @($newXml.ValidationManifest.Validators.Validator)

                foreach ($newValidator in $newValidators) {
                    $existingValidator = $existingValidators | Where-Object { $_.Id -eq $newValidator.Id }

                    if ($existingValidator) {
                        # Found matching validator - check for conflicts
                        $conflict = @{
                            ValidatorId = $newValidator.Id
                            Differences = @()
                        }

                        # Compare Enabled state
                        if ($existingValidator.Enabled -ne $newValidator.Enabled) {
                            $conflict.Differences += "Enabled: Existing=$($existingValidator.Enabled), New=$($newValidator.Enabled)"
                        }

                        # Compare version ranges
                        $existingMin = if ($existingValidator.MinVersion) { $existingValidator.MinVersion } else { "none" }
                        $existingMax = if ($existingValidator.MaxVersion) { $existingValidator.MaxVersion } else { "none" }
                        $newMin = if ($newValidator.MinVersion) { $newValidator.MinVersion } else { "none" }
                        $newMax = if ($newValidator.MaxVersion) { $newValidator.MaxVersion } else { "none" }

                        if ($existingMin -ne $newMin -or $existingMax -ne $newMax) {
                            $conflict.Differences += "Version Range: Existing=[$existingMin, $existingMax], New=[$newMin, $newMax]"
                        }

                        if ($conflict.Differences.Count -gt 0) {
                            $conflicts += $conflict
                        }
                    }
                }
            }
        }
        catch {
            Write-Host "  (Unable to parse manifest content for conflict detection: $_)" -ForegroundColor Gray
        }

        # If existing manifest has applicable validators, block the operation
        if ($hasApplicableValidators) {
            Write-Host "`n=== OPERATION BLOCKED ===" -ForegroundColor Red
            Write-Host "The existing sideloaded manifest contains validators that are currently applicable" -ForegroundColor Red
            Write-Host "to your environment version ($currentVersion). Overwriting could cause unexpected" -ForegroundColor Red
            Write-Host "validation behavior." -ForegroundColor Red

            # Show what the merged result would look like
            if ($existingXml -and $newXml) {
                Write-Host "`n--- MERGED RESULT PREVIEW ---" -ForegroundColor Cyan
                Write-Host "If you were to merge both manifests, the result would include:" -ForegroundColor Gray

                try {
                    $mergedManifest = Merge-ValidationManifests -BaseManifest $existingXml -SideloadedManifest $newXml

                    # Validate merged manifest against XSD before showing it to user
                    Write-Verbose "Validating merged manifest against XSD schema..."
                    $mergedXsdValidation = Test-ManifestXsdValidation -ManifestXml $mergedManifest
                    if (-not $mergedXsdValidation.IsValid -and $mergedXsdValidation.SchemaValidated) {
                        Write-Host "  (Merged manifest preview unavailable: XSD validation failed)" -ForegroundColor Red
                        Write-Host "  Error: $($mergedXsdValidation.ErrorMessage)" -ForegroundColor Red
                        Write-Verbose "Merged manifest XSD validation errors: $($mergedXsdValidation.Errors -join '; ')"
                        throw "Merged manifest failed XSD validation"
                    }
                    Write-Verbose "Merged manifest passed XSD validation"

                    $mergedValidators = @($mergedManifest.ValidationManifest.Validators.Validator)

                    Write-Host "`nMerged Validators:" -ForegroundColor Cyan
                    foreach ($validator in $mergedValidators) {
                        $source = if ($newValidators.Id -contains $validator.Id) {
                            if ($existingValidators.Id -contains $validator.Id) { "CONFLICT - New overrides Existing" }
                            else { "From New Manifest" }
                        } else { "From Existing Manifest" }
                        Write-Host "  - $($validator.Id) ($source)" -ForegroundColor Gray
                    }

                    # Show the actual merged XML
                    Write-Host "`nExample Merged Manifest XML:" -ForegroundColor Cyan
                    Write-Host "(XSD Validated)" -ForegroundColor Green

                    # Format the XML for display with proper declaration
                    $stringWriter = New-Object System.IO.StringWriter
                    $xmlSettings = New-Object System.Xml.XmlWriterSettings
                    $xmlSettings.Indent = $true
                    $xmlSettings.IndentChars = "  "
                    $xmlSettings.OmitXmlDeclaration = $false
                    $xmlWriter = [System.Xml.XmlWriter]::Create($stringWriter, $xmlSettings)
                    $mergedManifest.WriteTo($xmlWriter)
                    $xmlWriter.Flush()
                    $stringWriter.Flush()
                    $fullXml = $stringWriter.ToString()

                    # Save to temporary file
                    $tempMergedPath = Join-Path ([System.IO.Path]::GetTempPath()) "MergedManifest_$(Get-Date -Format 'yyyyMMddHHmmss').xml"
                    Set-Content -Path $tempMergedPath -Value $fullXml -Force

                    # Display the full XML without truncation
                    Write-Host ""
                    Write-Host $fullXml -ForegroundColor Gray
                    Write-Host ""
                    Write-Host "Merged manifest saved to: $tempMergedPath" -ForegroundColor Cyan
                }
                catch {
                    Write-Host "  (Unable to generate merge preview: $_)" -ForegroundColor Gray
                }
            }

            # Show conflicts if any
            if ($conflicts.Count -gt 0) {
                Write-Host "`n--- CONFLICTS DETECTED ---" -ForegroundColor Red
                foreach ($conflict in $conflicts) {
                    Write-Host "`nValidator: $($conflict.ValidatorId)" -ForegroundColor Yellow
                    foreach ($diff in $conflict.Differences) {
                        Write-Host "  ! $diff" -ForegroundColor Red
                    }
                }
            }

            Write-Host "`n=== REQUIRED ACTION ===" -ForegroundColor Yellow
            Write-Host "1. Review the merged manifest preview above to understand the combined result." -ForegroundColor Yellow
            Write-Host "2. Decide if you want to use the merged manifest or the new manifest only." -ForegroundColor Yellow
            Write-Host "3. Remove the existing sideloaded manifest:" -ForegroundColor Yellow
            Write-Host "     Clear-ValidationManifest" -ForegroundColor Cyan
            Write-Host "4. If you want the merged version, sideload the merged manifest file shown above." -ForegroundColor Yellow
            Write-Host "   If you want the new manifest only, retry this operation to sideload it." -ForegroundColor Yellow
            Write-Host "========================================`n" -ForegroundColor Yellow

            throw "Cannot overwrite existing sideloaded manifest with applicable validators. Please review the merged manifest preview, run 'Clear-ValidationManifest', and retry with your chosen manifest."
        }

        # If no applicable validators but conflicts exist, warn user
        if ($conflicts.Count -gt 0 -and -not $hasApplicableValidators) {
            Write-Host "`n--- CONFLICTS DETECTED ---" -ForegroundColor Yellow
            Write-Host "The new manifest conflicts with the existing manifest:" -ForegroundColor Yellow
            foreach ($conflict in $conflicts) {
                Write-Host "`nValidator: $($conflict.ValidatorId)" -ForegroundColor Cyan
                foreach ($diff in $conflict.Differences) {
                    Write-Host "  ! $diff" -ForegroundColor Yellow
                }
            }
            Write-Host "`nThese conflicts will be resolved by the new manifest taking precedence." -ForegroundColor Gray
        }

        Write-Host ""

        # Prompt for confirmation to overwrite (only if no applicable validators)
        if (-not $PSCmdlet.ShouldProcess($script:SideloadedManifestPath, "Overwrite existing sideloaded manifest")) {
            Write-Host "Operation cancelled by user. Existing sideloaded manifest will not be overwritten." -ForegroundColor Yellow
            return
        }
    }

        # Warn if no PSSession provided (local only)
        if (-not $PsSession -or $PsSession.Count -eq 0) {
            Write-Warning "No PsSession provided. Manifest will only be sideloaded on the local node ($env:COMPUTERNAME). This will only apply when orchestration is run from this node. To sideload to all cluster nodes, provide PsSession parameter with sessions to all nodes."
        }

        # Check if Copy-RemoteItem is available for remote deployments
        $useCopyRemoteItem = $false
        if ($PsSession -and $PsSession.Count -gt 0) {
            if (Get-Command -Name Copy-RemoteItem -ErrorAction SilentlyContinue) {
                $useCopyRemoteItem = $true
                Write-Verbose "Copy-RemoteItem utility found - will use for remote deployments"
            }
            else {
                Write-Warning "Copy-RemoteItem utility not found - falling back to Invoke-Command"
            }
        }

        # Validate it's XML
        $xmlContent = Get-Content -Path $ManifestPath -Raw -ErrorAction Stop
        try {
            [xml]$testXml = $xmlContent
            Write-Verbose "Manifest is valid XML"
        }
        catch {
            throw "Invalid XML format: $_"
        }

        # Validate against XSD schema
        Write-Verbose "Validating manifest against XSD schema..."
        $xsdValidation = Test-ManifestXsdValidation -ManifestXml $testXml
        if (-not $xsdValidation.IsValid -and $xsdValidation.SchemaValidated) {
            $xsdErrorMessage = "Manifest XSD validation failed. The manifest does not conform to the required schema and cannot be sideloaded. $($xsdValidation.ErrorMessage)"
            Write-Error $xsdErrorMessage

            # Update telemetry decision object
            $telemetryDecision.ProcessingStatus = "XsdValidationFailed"
            $telemetryDecision.ProcessingMessage = $xsdErrorMessage
            $telemetryDecision.ErrorDetails = @{
                ValidationErrors = $xsdValidation.Errors
                ErrorCount = $xsdValidation.Errors.Count
            }

            throw $xsdErrorMessage
        }
        Write-Verbose "Manifest passed XSD validation"

        # Validate signature
        $signatureValid = $false
        if ($EnforceSignature) {
            $signatureValid = Test-ManifestXmlSignature -XmlPath $ManifestPath -EnforceSignature $true
            if (-not $signatureValid) {
                $telemetryDecision.ProcessingStatus = "SignatureValidationFailed"
                $telemetryDecision.ProcessingMessage = "Manifest signature validation failed"
                $telemetryDecision.SignatureValid = $false
                throw "Manifest signature validation failed"
            }
        }
        else {
            Write-Warning "Signature validation skipped for sideloaded manifest"
            $signatureValid = $null
        }

        $telemetryDecision.SignatureValid = $signatureValid

        # Prepare metadata for all nodes
        $metadata = @{
            Timestamp = (Get-Date).ToString("o")
            SourcePath = $ManifestPath
            SignatureValid = $signatureValid
            EnforceSignature = $EnforceSignature
            SideloadedBy = $env:USERNAME
            SideloadedFrom = $env:COMPUTERNAME
        }
        $metadataJson = $metadata | ConvertTo-Json

        # Collect all deployment results
        $deploymentResults = @()

        # Deploy to local node
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Sideload validation manifest to local node")) {
            try {
                # Ensure cache directory exists
                if (-not (Test-Path $script:CacheDirectory)) {
                    New-Item -Path $script:CacheDirectory -ItemType Directory -Force | Out-Null
                }

                # Stage manifest
                Set-Content -Path $script:SideloadedManifestPath -Value $xmlContent -Force -ErrorAction Stop

                # Stage metadata
                Set-Content -Path $script:SideloadedManifestMetadataPath -Value $metadataJson -Force -ErrorAction Stop

                $deploymentResults += [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    Success = $true
                    Error = $null
                }
                Write-Host "[+] Local node ($env:COMPUTERNAME): Sideloaded successfully" -ForegroundColor Green
            }
            catch {
                $deploymentResults += [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    Success = $false
                    Error = $_.Exception.Message
                }
                Write-Error "Failed to sideload manifest on local node: $_"
                throw "Local node sideload failed: $_"
            }
        }

        # Deploy to remote nodes via PSSession
        if ($PsSession -and $PsSession.Count -gt 0) {
            Write-Host "`nSideloading manifest to $($PsSession.Count) remote node(s)..." -ForegroundColor Cyan

            if ($useCopyRemoteItem) {
                # Use Copy-RemoteItem utility for robust file transfer
                # First, create temporary staging files with the final destination names
                $tempDir = Join-Path $env:TEMP "ManifestSideload_$(Get-Date -Format 'yyyyMMddHHmmss')"
                if (-not (Test-Path $tempDir)) {
                    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
                }

                try {
                    # Create staging files with content
                    $stagingManifestPath = Join-Path $tempDir (Split-Path $script:SideloadedManifestPath -Leaf)
                    $stagingMetadataPath = Join-Path $tempDir (Split-Path $script:SideloadedManifestMetadataPath -Leaf)

                    Set-Content -Path $stagingManifestPath -Value $xmlContent -Force
                    Set-Content -Path $stagingMetadataPath -Value $metadataJson -Force

                    # Create remote cache directory first (Copy-RemoteItem may not create it)
                    foreach ($session in $PsSession) {
                        Invoke-Command -Session $session -ScriptBlock {
                            param($cacheDir)
                            if (-not (Test-Path $cacheDir)) {
                                New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
                            }
                        } -ArgumentList $script:CacheDirectory -ErrorAction SilentlyContinue
                    }

                    # Copy manifest file
                    Write-Verbose "Copying manifest to remote nodes using Copy-RemoteItem"
                    try {
                        Copy-RemoteItem -SourcePath $stagingManifestPath -DestinationPath $script:CacheDirectory -PsSession $PsSession -ErrorAction Stop
                        Write-Verbose "Manifest copied successfully"
                    }
                    catch {
                        Write-Warning "Copy-RemoteItem failed for manifest: $_"
                        throw
                    }

                    # Copy metadata file
                    Write-Verbose "Copying metadata to remote nodes using Copy-RemoteItem"
                    try {
                        Copy-RemoteItem -SourcePath $stagingMetadataPath -DestinationPath $script:CacheDirectory -PsSession $PsSession -ErrorAction Stop
                        Write-Verbose "Metadata copied successfully"
                    }
                    catch {
                        Write-Warning "Copy-RemoteItem failed for metadata: $_"
                        throw
                    }

                    # Verify on each node and collect results
                    foreach ($session in $PsSession) {
                        if ($PSCmdlet.ShouldProcess($session.ComputerName, "Verify sideload on remote node")) {
                            try {
                                $verifyResult = Invoke-Command -Session $session -ScriptBlock {
                                    param($manifestPath, $metadataPath)
                                    $manifestExists = Test-Path $manifestPath
                                    $metadataExists = Test-Path $metadataPath

                                    if ($manifestExists -and $metadataExists) {
                                        return [PSCustomObject]@{
                                            ComputerName = $env:COMPUTERNAME
                                            Success = $true
                                            Error = $null
                                        }
                                    }
                                    else {
                                        return [PSCustomObject]@{
                                            ComputerName = $env:COMPUTERNAME
                                            Success = $false
                                            Error = "File verification failed. Manifest: $manifestExists, Metadata: $metadataExists"
                                        }
                                    }
                                } -ArgumentList $script:SideloadedManifestPath, $script:SideloadedManifestMetadataPath -ErrorAction Stop

                                $deploymentResults += $verifyResult

                                if ($verifyResult.Success) {
                                    Write-Host "[+] Remote node ($($verifyResult.ComputerName)): Sideloaded successfully" -ForegroundColor Green
                                }
                                else {
                                    Write-Warning "Failed to verify sideload on remote node $($verifyResult.ComputerName): $($verifyResult.Error)"
                                }
                            }
                            catch {
                                $failedResult = [PSCustomObject]@{
                                    ComputerName = $session.ComputerName
                                    Success = $false
                                    Error = $_.Exception.Message
                                }
                                $deploymentResults += $failedResult
                                Write-Warning "Failed to verify sideload on remote node $($session.ComputerName): $_"
                            }
                        }
                    }
                }
                finally {
                    # Clean up temporary staging directory
                    if (Test-Path $tempDir) {
                        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                # Fallback: Use Invoke-Command directly
                $sideloadScriptBlock = {
                    param(
                        $CacheDirectory,
                        $SideloadedManifestPath,
                        $SideloadedManifestMetadataPath,
                        $XmlContent,
                        $MetadataJson
                    )

                    try {
                        # Ensure cache directory exists
                        if (-not (Test-Path $CacheDirectory)) {
                            New-Item -Path $CacheDirectory -ItemType Directory -Force | Out-Null
                        }

                        # Stage manifest
                        Set-Content -Path $SideloadedManifestPath -Value $XmlContent -Force -ErrorAction Stop

                        # Stage metadata
                        Set-Content -Path $SideloadedManifestMetadataPath -Value $MetadataJson -Force -ErrorAction Stop

                        # Return success
                        return [PSCustomObject]@{
                            ComputerName = $env:COMPUTERNAME
                            Success = $true
                            Error = $null
                        }
                    }
                    catch {
                        # Return failure
                        return [PSCustomObject]@{
                            ComputerName = $env:COMPUTERNAME
                            Success = $false
                            Error = $_.Exception.Message
                        }
                    }
                }

                foreach ($session in $PsSession) {
                    if ($PSCmdlet.ShouldProcess($session.ComputerName, "Sideload validation manifest to remote node")) {
                        try {
                            $remoteResult = Invoke-Command -Session $session -ScriptBlock $sideloadScriptBlock -ArgumentList $script:CacheDirectory, $script:SideloadedManifestPath, $script:SideloadedManifestMetadataPath, $xmlContent, $metadataJson -ErrorAction Stop
                            $deploymentResults += $remoteResult

                            if ($remoteResult.Success) {
                                Write-Host "[+] Remote node ($($remoteResult.ComputerName)): Sideloaded successfully" -ForegroundColor Green
                            }
                            else {
                                Write-Warning "Failed to sideload manifest on remote node $($remoteResult.ComputerName): $($remoteResult.Error)"
                            }
                        }
                        catch {
                            $failedResult = [PSCustomObject]@{
                                ComputerName = $session.ComputerName
                                Success = $false
                                Error = $_.Exception.Message
                            }
                            $deploymentResults += $failedResult
                            Write-Warning "Failed to sideload manifest on remote node $($session.ComputerName): $_"
                        }
                    }
                }
            }
        }

        # Summary output
        $successCount = ($deploymentResults | Where-Object Success | Measure-Object).Count
        $totalCount = $deploymentResults.Count

        Write-Host "`n Validation manifest sideload summary" -ForegroundColor Green
        Write-Host " Successful: $successCount of $totalCount node(s)" -ForegroundColor Gray
        Write-Host " Location: $script:SideloadedManifestPath" -ForegroundColor Gray
        Write-Host " Signature validated: $($signatureValid -ne $null -and $signatureValid)" -ForegroundColor Gray

        # Update telemetry decision object with deployment results
        $telemetryDecision.ProcessingStatus = "Success"
        $telemetryDecision.ProcessingMessage = "Manifest sideloaded successfully to $successCount of $totalCount node(s)"
        $telemetryDecision.TotalNodes = $totalCount
        $telemetryDecision.SuccessfulNodes = $successCount
        $telemetryDecision.FailedNodes = $totalCount - $successCount
        $telemetryDecision.NodeResults = $deploymentResults
        $telemetryDecision.NodeList = $deploymentResults | ForEach-Object { $_.ComputerName }

        # Throw if any nodes failed
        if ($successCount -lt $totalCount) {
            $failedNodes = $deploymentResults | Where-Object { -not $_.Success } | ForEach-Object { $_.ComputerName }
            $telemetryDecision.ProcessingStatus = "PartialFailure"
            $telemetryDecision.ProcessingMessage = "Manifest sideload failed on $($failedNodes.Count) node(s): $($failedNodes -join ', ')"
            throw "Manifest sideload failed on $($failedNodes.Count) node(s): $($failedNodes -join ', ')"
        }
    }
    catch {
        # Capture error details if not already set
        if ($telemetryDecision.ProcessingStatus -eq "Unknown") {
            $telemetryDecision.ProcessingStatus = "Error"
            $telemetryDecision.ProcessingMessage = "Failed to sideload manifest: $_"
            $telemetryDecision.ErrorDetails = @{
                Exception = $_.Exception.Message
                ErrorType = $_.Exception.GetType().FullName
                ScriptStackTrace = $_.ScriptStackTrace
                TargetObject = $_.TargetObject
            }
        }

        Write-Error "Failed to sideload manifest: $_"
        throw
    }
    finally {
        # Always log telemetry regardless of success or failure
        try {
            Import-Module "$PSScriptRoot\AzStackHci.EnvironmentChecker.Reporting.psm1" -Force -ErrorAction SilentlyContinue
            Write-ManifestTelemetry -ManifestDecision $telemetryDecision
        }
        catch {
            Write-Verbose "Failed to write telemetry: $_"
        }
    }
}

function Clear-ValidationManifest {
    <#
    .SYNOPSIS
        Removes sideloaded validation manifest.

    .DESCRIPTION
        Removes any sideloaded validation manifest, returning to using downloaded/cached manifests only.

    .PARAMETER IncludeCache
        If specified, also clears the downloaded manifest cache.

    .EXAMPLE
        Clear-ValidationManifest
        Removes sideloaded manifest only.

    .EXAMPLE
        Clear-ValidationManifest -IncludeCache
        Removes both sideloaded and cached manifests.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$IncludeCache
    )

    $removedItems = @()

    try {
        # Remove sideloaded manifest
        if (Test-Path $script:SideloadedManifestPath) {
            if ($PSCmdlet.ShouldProcess($script:SideloadedManifestPath, "Remove sideloaded manifest")) {
                Remove-Item -Path $script:SideloadedManifestPath -Force -ErrorAction Stop
                $removedItems += "Sideloaded manifest"
                Write-Verbose "Removed sideloaded manifest: $script:SideloadedManifestPath"
            }
        }

        if (Test-Path $script:SideloadedManifestMetadataPath) {
            if ($PSCmdlet.ShouldProcess($script:SideloadedManifestMetadataPath, "Remove sideloaded manifest metadata")) {
                Remove-Item -Path $script:SideloadedManifestMetadataPath -Force -ErrorAction Stop
                Write-Verbose "Removed sideloaded manifest metadata: $script:SideloadedManifestMetadataPath"
            }
        }

        # Remove cache if requested
        if ($IncludeCache) {
            if (Test-Path $script:CachedManifestPath) {
                if ($PSCmdlet.ShouldProcess($script:CachedManifestPath, "Remove cached manifest")) {
                    Remove-Item -Path $script:CachedManifestPath -Force -ErrorAction Stop
                    $removedItems += "Cached manifest"
                    Write-Verbose "Removed cached manifest: $script:CachedManifestPath"
                }
            }

            if (Test-Path $script:CachedManifestMetadataPath) {
                if ($PSCmdlet.ShouldProcess($script:CachedManifestMetadataPath, "Remove cached manifest metadata")) {
                    Remove-Item -Path $script:CachedManifestMetadataPath -Force -ErrorAction Stop
                    Write-Verbose "Removed cached manifest metadata: $script:CachedManifestMetadataPath"
                }
            }
        }

        if ($removedItems.Count -gt 0) {
            Write-Host " Removed: $($removedItems -join ', ')" -ForegroundColor Green

            # Log telemetry
            $telemetryData = @{
                Event = "ManifestCleared"
                RemovedItems = $removedItems
                IncludeCache = $IncludeCache.IsPresent
                ClearedBy = $env:USERNAME
                ComputerName = $env:COMPUTERNAME
                Timestamp = (Get-Date).ToString("o")
            }
            Write-Verbose "Telemetry: $($telemetryData | ConvertTo-Json -Compress)"
        }
        else {
            Write-Host "No manifests to remove" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Error "Failed to clear manifest: $_"
        throw
    }
}

function Get-SideloadedManifest {
    <#
    .SYNOPSIS
        Retrieves sideloaded manifest if present.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:SideloadedManifestPath)) {
        Write-Verbose "No sideloaded manifest found"
        return $null
    }

    try {
        $xmlContent = Get-Content -Path $script:SideloadedManifestPath -Raw -ErrorAction Stop
        $metadata = if (Test-Path $script:SideloadedManifestMetadataPath) {
            Get-Content -Path $script:SideloadedManifestMetadataPath -Raw | ConvertFrom-Json
        } else {
            @{}
        }

        Write-Verbose "Using sideloaded manifest from: $script:SideloadedManifestPath"

        # Log telemetry
        $telemetryData = @{
            Event = "ManifestLoadedFromSideload"
            SourcePath = $metadata.SourcePath
            SignatureValid = $metadata.SignatureValid
            SideloadedBy = $metadata.SideloadedBy
            SideloadedOn = $metadata.Timestamp
            Timestamp = (Get-Date).ToString("o")
        }
        Write-Verbose "Telemetry: $($telemetryData | ConvertTo-Json -Compress)"

        return @{
            Content = $xmlContent
            Source = "Sideloaded"
            SourcePath = $metadata.SourcePath
            SignatureValid = $metadata.SignatureValid
            SideloadedBy = $metadata.SideloadedBy
            SideloadedOn = $metadata.Timestamp
        }
    }
    catch {
        Write-Verbose "Failed to read sideloaded manifest: $_"
        return $null
    }
}

function Merge-ValidationManifests {
    <#
    .SYNOPSIS
        Merges sideloaded manifest with base manifest (sideloaded takes precedence).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$BaseManifest,

        [Parameter(Mandatory = $true)]
        [xml]$SideloadedManifest
    )

    try {
        # Clone base manifest
        $mergedManifest = $BaseManifest.Clone()

        # Iterate through sideloaded validators
        foreach ($sideloadedValidator in $SideloadedManifest.ValidationManifest.Validators.Validator) {
            $validatorId = $sideloadedValidator.Id
            $baseValidator = $mergedManifest.ValidationManifest.Validators.Validator | Where-Object { $_.Id -eq $validatorId }

            if ($baseValidator) {
                # Replace existing validator
                Write-Verbose "Merging validator: $validatorId (sideloaded takes precedence)"
                $importedNode = $mergedManifest.ImportNode($sideloadedValidator, $true)
                $mergedManifest.ValidationManifest.Validators.ReplaceChild($importedNode, $baseValidator) | Out-Null
            }
            else {
                # Add new validator
                Write-Verbose "Adding new validator from sideload: $validatorId"
                $importedNode = $mergedManifest.ImportNode($sideloadedValidator, $true)
                $mergedManifest.ValidationManifest.Validators.AppendChild($importedNode) | Out-Null
            }
        }

        Write-Verbose "Manifests merged successfully"
        return $mergedManifest
    }
    catch {
        Write-Warning "Failed to merge manifests: $_. Using base manifest only."
        return $BaseManifest
    }
}

function Test-VersionInRange {
    <#
    .SYNOPSIS
        Tests if the current version falls within the specified range.

    .PARAMETER CurrentVersion
        The current YYMM version (e.g., 2601).

    .PARAMETER MinVersion
        The minimum YYMM version (optional). If not specified, no lower bound is applied.

    .PARAMETER MaxVersion
        The maximum YYMM version (optional). If not specified, no upper bound is applied.

    .OUTPUTS
        System.Boolean - Returns $true if the version is within range, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,

        [Parameter(Mandatory = $false)]
        [string]$MinVersion,

        [Parameter(Mandatory = $false)]
        [string]$MaxVersion
    )

    # If no version constraints specified, always return true (backward compatibility)
    if ([string]::IsNullOrWhiteSpace($MinVersion) -and [string]::IsNullOrWhiteSpace($MaxVersion)) {
        Write-Verbose "No version constraints specified, override applies to all versions"
        return $true
    }

    try {
        $current = [int]$CurrentVersion

        # Check minimum version
        if (-not [string]::IsNullOrWhiteSpace($MinVersion)) {
            $min = [int]$MinVersion
            if ($current -lt $min) {
                Write-Verbose "Current version $CurrentVersion is below minimum $MinVersion"
                return $false
            }
        }

        # Check maximum version
        if (-not [string]::IsNullOrWhiteSpace($MaxVersion)) {
            $max = [int]$MaxVersion
            if ($current -gt $max) {
                Write-Verbose "Current version $CurrentVersion is above maximum $MaxVersion"
                return $false
            }
        }

        Write-Verbose "Current version $CurrentVersion is within range [$MinVersion, $MaxVersion]"
        return $true
    }
    catch {
        Write-Warning "Error comparing versions: $_. Override will not be applied."
        return $false
    }
}

function Test-ManifestXmlSignature {
    <#
    .SYNOPSIS
        Validates XML signature using the Test-XmlSignature.ps1 script.

    .PARAMETER XmlPath
        Path to the XML file to validate.

    .PARAMETER EnforceSignature
        If true, throws an error if signature validation fails. If false, only logs a warning.

    .OUTPUTS
        System.Boolean - Returns $true if signature is valid, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$XmlPath,

        [Parameter(Mandatory = $false)]
        [bool]$EnforceSignature = $false
    )

    $testScriptPath = Join-Path $PSScriptRoot "..\Test-XmlSignature.ps1"

    if (-not (Test-Path $testScriptPath)) {
        Write-Warning "Test-XmlSignature.ps1 not found at: $testScriptPath. Skipping signature validation."
        return $false
    }

    try {
        Write-Verbose "Validating XML signature for: $XmlPath"
        $result = & $testScriptPath -XmlPath $XmlPath -ErrorAction Stop

        if ($result) {
            Write-Verbose "XML signature validation passed."
            return $true
        }
        else {
            $message = "XML signature validation failed for: $XmlPath"
            if ($EnforceSignature) {
                throw $message
            }
            else {
                Write-Warning $message
                return $false
            }
        }
    }
    catch {
        $message = "Error validating XML signature: $_"
        if ($EnforceSignature) {
            throw $message
        }
        else {
            Write-Warning $message
            return $false
        }
    }
}

function Get-ManifestFromFileOrUrl {
    <#
    .SYNOPSIS
        Attempts to retrieve manifest with NuGet package support and sideload capability.

    .DESCRIPTION
        Retrieves manifest in the following priority order:
        1. Sideloaded manifest (if present)
        2. Local NuGet store (C:\NugetStore)
        3. Download NuGet package from VSR if newer version available
        4. Read manifest XML from NuGet package location

        If sideloaded manifest exists, it is merged with the base manifest.
        If Get-ValidatedSolutionRecipe commandlet is not available, uses local NuGet store only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$EnforceSignature = $false
    )

    $xmlContent = $null
    $source = "None"
    $manifestPath = $null
    $signatureValid = $null
    $retrievalAttempts = @()  # Track all retrieval attempts and their results
    $nugetVersion = $null

    # Check for sideloaded manifest first
    $sideloadedData = Get-SideloadedManifest
    $hasSideloaded = $null -ne $sideloadedData

    # Check local NuGet store second
    Write-Verbose "Checking local NuGet store at: $script:NuGetStoreDirectory"
    try {
        $localNuGet = Get-LatestLocalNuGetPackage
        if ($localNuGet) {
            $localVersion = $localNuGet.VersionObject
            $nugetVersion = $localNuGet.Version
            Write-Verbose "Found local NuGet package version: $nugetVersion"
            $retrievalAttempts += "Local NuGet: Found version $nugetVersion"

            # Construct versioned path to manifest
            $packageNameWithVersion = "$script:ManifestNuGetName.$nugetVersion"
            $versionedManifestPath = Join-Path $script:NuGetStoreDirectory "$packageNameWithVersion\AzStackHci.EnvironmentChecker.Manifest.xml"

            # Try to read manifest from local NuGet store
            if (Test-Path $versionedManifestPath) {
                try {
                    Write-Verbose "Reading manifest from local NuGet store: $versionedManifestPath"
                    $xmlContent = Get-Content -Path $versionedManifestPath -Raw -ErrorAction Stop
                    $source = "NuGetLocal"
                    $manifestPath = $versionedManifestPath
                    Write-Verbose "Successfully read manifest from local NuGet store"
                }
                catch {
                    Write-Verbose "Failed to read manifest from local NuGet store: $_"
                    $retrievalAttempts += "Local NuGet manifest read: Failed - $_"
                    $xmlContent = $null
                }
            }
            else {
                Write-Verbose "Manifest XML not found in local NuGet store at: $versionedManifestPath"
                $retrievalAttempts += "Local NuGet manifest: Not found at expected location"
            }
        }
        else {
            Write-Verbose "No local NuGet package found in: $script:NuGetStoreDirectory"
            $retrievalAttempts += "Local NuGet: Not found"
        }
    }
    catch {
        Write-Verbose "Error checking local NuGet store: $_"
        $retrievalAttempts += "Local NuGet: Error - $_"
    }

    # Check VSR for newer NuGet package third
    $shouldDownload = $false
    $vsrNuGet = $null

    try {
        # Check if Get-ValidatedSolutionRecipe commandlet exists
        if (-not (Get-Command -Name Get-ValidatedSolutionRecipe -ErrorAction SilentlyContinue)) {
            Write-Verbose "Get-ValidatedSolutionRecipe commandlet not found. Using local NuGet store only."
            $retrievalAttempts += "VSR NuGet: Get-ValidatedSolutionRecipe commandlet not available"
        }
        else {
            Write-Verbose "Getting manifest NuGet info from Validated Solution Recipe"
            $vsrNuGet = Get-ManifestNuGetFromRecipe

            if ($vsrNuGet -and $vsrNuGet.Version) {
                $vsrVersion = $vsrNuGet.VersionObject
                Write-Verbose "VSR provides NuGet version: $($vsrNuGet.Version)"
                $retrievalAttempts += "VSR NuGet: Found version $($vsrNuGet.Version) at $($vsrNuGet.Url)"

                # Compare versions if we have local
                if ($localNuGet) {
                    if ($vsrVersion -gt $localVersion) {
                        Write-Verbose "VSR version ($($vsrNuGet.Version)) is newer than local version ($nugetVersion)"
                        $shouldDownload = $true
                    }
                    else {
                        Write-Verbose "Local version ($nugetVersion) is up to date with VSR version ($($vsrNuGet.Version))"
                        $retrievalAttempts += "VSR NuGet: Local version is current or newer"
                    }
                }
                else {
                    Write-Verbose "No local NuGet found, will download from VSR"
                    $shouldDownload = $true
                }
            }
            else {
                Write-Verbose "Could not get NuGet info from VSR"
                $retrievalAttempts += "VSR NuGet: Not found in recipe"
            }
        }
    }
    catch {
        Write-Verbose "Error checking VSR for NuGet package: $_"
        $retrievalAttempts += "VSR NuGet: Error - $_"
    }

    # Download and expand NuGet if needed
    if ($shouldDownload -and $vsrNuGet) {
        Write-Verbose "Downloading and expanding NuGet package from: $($vsrNuGet.Url)"
        try {
            $expandSuccess = Expand-ManifestNuGetPackage -Url $vsrNuGet.Url -FileName $vsrNuGet.FileName

            if ($expandSuccess) {
                Write-Verbose "Successfully downloaded and expanded NuGet package"
                $retrievalAttempts += "NuGet Download: Success from $($vsrNuGet.Url)"
                $nugetVersion = $vsrNuGet.Version

                # Construct versioned path to manifest
                $packageNameWithVersion = "$script:ManifestNuGetName.$($vsrNuGet.Version)"
                $versionedManifestPath = Join-Path $script:NuGetStoreDirectory "$packageNameWithVersion\AzStackHci.EnvironmentChecker.Manifest.xml"

                # Read manifest from newly downloaded package
                if (Test-Path $versionedManifestPath) {
                    try {
                        Write-Verbose "Reading manifest from downloaded NuGet: $versionedManifestPath"
                        $xmlContent = Get-Content -Path $versionedManifestPath -Raw -ErrorAction Stop
                        $source = "NuGetDownloaded"
                        $manifestPath = $versionedManifestPath
                        Write-Verbose "Successfully read manifest from downloaded NuGet"
                    }
                    catch {
                        Write-Verbose "Failed to read manifest after download: $_"
                        $retrievalAttempts += "Downloaded NuGet manifest read: Failed - $_"
                    }
                }
                else {
                    Write-Verbose "Manifest not found after NuGet expansion at: $versionedManifestPath"
                    $retrievalAttempts += "Downloaded NuGet manifest: Not found at expected location"
                }
            }
            else {
                Write-Verbose "Failed to expand NuGet package"
                $retrievalAttempts += "NuGet Download: Expansion failed"
            }
        }
        catch {
            Write-Verbose "Error downloading/expanding NuGet package: $_"
            $retrievalAttempts += "NuGet Download: Error - $_"
        }
    }

    # Log telemetry event if no manifest found
    if ([string]::IsNullOrEmpty($xmlContent)) {
        $telemetryData = @{
            Event = "ManifestNotFound"
            NuGetStore = $script:NuGetStoreDirectory
            HasSideloaded = $hasSideloaded
            RetrievalAttempts = $retrievalAttempts
            Timestamp = (Get-Date).ToString("o")
        }
        Write-Verbose "Manifest not found from any source. Telemetry: $($telemetryData | ConvertTo-Json -Compress)"

        # If we have sideloaded but no base, return sideloaded only
        if ($hasSideloaded) {
            Write-Verbose "No base manifest found, using sideloaded manifest only"
            return @{
                Content = $sideloadedData.Content
                Source = "Sideloaded"
                SignatureValid = $sideloadedData.SignatureValid
                IsMerged = $false
                HasSideloaded = $true
                NuGetVersion = $null
                RetrievalAttempts = $retrievalAttempts
            }
        }

        return @{
            RetrievalAttempts = $retrievalAttempts
        }
    }

    # Validate signature if manifest path is available
    if ($manifestPath -and (Test-Path $manifestPath)) {
        $signatureValid = Test-ManifestXmlSignature -XmlPath $manifestPath -EnforceSignature $EnforceSignature

        if (-not $signatureValid -and $EnforceSignature) {
            return $null
        }
    }

    # Merge with sideloaded manifest if present
    $finalContent = $xmlContent
    $isMerged = $false
    $sideloadedSourcePath = $null
    $sideloadedBy = $null
    $sideloadedOn = $null

    # Validate base manifest against XSD
    try {
        [xml]$baseXmlForValidation = $xmlContent
        Write-Verbose "Validating base manifest against XSD schema..."
        $xsdValidation = Test-ManifestXsdValidation -ManifestXml $baseXmlForValidation
        if (-not $xsdValidation.IsValid -and $xsdValidation.SchemaValidated) {
            Write-Error "Base manifest failed XSD validation and cannot be processed:"
            Write-Error $xsdValidation.ErrorMessage
            throw "Manifest XSD validation has failed. The manifest does not conform to the required schema and will not be processed."
        }
        elseif (-not $xsdValidation.IsValid) {
            Write-Verbose "XSD validation could not be performed (schema file may be missing)"
        }
        else {
            Write-Verbose "Base manifest passed XSD validation"
        }
    }
    catch {
        if ($_.Exception.Message -like "*XSD validation failed*") {
            throw
        }
        Write-Verbose "Could not validate base manifest against XSD: $_"
    }

    if ($hasSideloaded) {
        # Preserve sideloaded metadata
        $sideloadedSourcePath = $sideloadedData.SourcePath
        $sideloadedBy = $sideloadedData.SideloadedBy
        $sideloadedOn = $sideloadedData.SideloadedOn

        try {
            [xml]$baseManifest = $xmlContent
            [xml]$sideloadManifest = $sideloadedData.Content

            $mergedManifest = Merge-ValidationManifests -BaseManifest $baseManifest -SideloadedManifest $sideloadManifest
            $finalContent = $mergedManifest.OuterXml
            $isMerged = $true
            $source = "$source+Sideloaded"

            Write-Verbose "Merged sideloaded manifest with base manifest"

            # Log telemetry
            $telemetryData = @{
                Event = "ManifestMerged"
                BaseSource = $source.Replace("+Sideloaded", "")
                SideloadedSource = $sideloadedData.SourcePath
                Timestamp = (Get-Date).ToString("o")
            }
            Write-Verbose "Telemetry: $($telemetryData | ConvertTo-Json -Compress)"
        }
        catch {
            Write-Warning "Failed to merge manifests: $_. Using base manifest only."
            $finalContent = $xmlContent
        }
    }

    return @{
        Content = $finalContent
        Source = $source
        SignatureValid = $signatureValid
        IsMerged = $isMerged
        HasSideloaded = $hasSideloaded
        NuGetVersion = $nugetVersion
        SideloadedSourcePath = $sideloadedSourcePath
        SideloadedBy = $sideloadedBy
        SideloadedOn = $sideloadedOn
        RetrievalAttempts = $retrievalAttempts
    }
}

function Test-ManifestXsdValidation {
    <#
    .SYNOPSIS
        Validates a manifest XML against the ValidationManifest XSD schema.

    .DESCRIPTION
        Validates XML structure and content against the ValidationManifest.xsd schema.
        Returns validation result with detailed error information if validation fails.

    .PARAMETER ManifestXml
        The XML document to validate.

    .PARAMETER XsdPath
        Optional path to the XSD schema file. If not provided, uses the default schema
        located in the module directory.

    .EXAMPLE
        $xml = [xml](Get-Content manifest.xml)
        Test-ManifestXsdValidation -ManifestXml $xml

    .OUTPUTS
        PSCustomObject with IsValid (bool), Errors (array), and ErrorMessage (string) properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlDocument]$ManifestXml,

        [Parameter(Mandatory = $false)]
        [string]$XsdPath
    )

    $validationErrors = @()
    $isValid = $true

    try {
        # Get XSD path if not provided
        if (-not $XsdPath) {
            $XsdPath = Join-Path $PSScriptRoot "ValidationManifest.xsd"
        }

        if (-not (Test-Path $XsdPath)) {
            Write-Warning "XSD schema not found at: $XsdPath. Skipping schema validation."
            return [PSCustomObject]@{
                IsValid = $true
                Errors = @()
                ErrorMessage = "Schema file not found - validation skipped"
                SchemaValidated = $false
            }
        }

        # Create XmlReaderSettings with XSD
        $readerSettings = New-Object System.Xml.XmlReaderSettings
        $readerSettings.ValidationType = [System.Xml.ValidationType]::Schema
        $readerSettings.ValidationFlags = [System.Xml.Schema.XmlSchemaValidationFlags]::ProcessInlineSchema -bor `
                                          [System.Xml.Schema.XmlSchemaValidationFlags]::ProcessSchemaLocation -bor `
                                          [System.Xml.Schema.XmlSchemaValidationFlags]::ReportValidationWarnings

        # Load XSD schema
        $null = $readerSettings.Schemas.Add($null, $XsdPath)

        # Add validation event handler using a shared object to track state
        $validationState = New-Object PSObject -Property @{
            IsValid = $true
            Errors = @()
        }

        $validationEventHandler = [System.Xml.Schema.ValidationEventHandler] {
            param($sender, $e)
            $validationState.IsValid = $false
            $validationState.Errors += [PSCustomObject]@{
                Severity = $e.Severity.ToString()
                Message = $e.Message
                LineNumber = $e.Exception.LineNumber
                LinePosition = $e.Exception.LinePosition
            }
        }
        $readerSettings.add_ValidationEventHandler($validationEventHandler)

        # Clone the XML and remove Signature elements before XSD validation
        # (Signature validation is handled separately by Test-ManifestXmlSignature)
        $xmlToValidate = $ManifestXml.Clone()
        $signatureNodes = $xmlToValidate.GetElementsByTagName("Signature", "http://www.w3.org/2000/09/xmldsig#")
        if ($signatureNodes.Count -gt 0) {
            Write-Verbose "Removing $($signatureNodes.Count) XML digital signature element(s) before XSD validation"
            foreach ($sig in @($signatureNodes)) {
                $sig.ParentNode.RemoveChild($sig) | Out-Null
            }
        }

        # Validate XML
        $stringReader = New-Object System.IO.StringReader($xmlToValidate.OuterXml)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)

        try {
            while ($xmlReader.Read()) { }
        }
        finally {
            $xmlReader.Close()
            $stringReader.Close()
        }

        # Build error message
        $errorMessage = ""
        if ($validationState.Errors.Count -gt 0) {
            $errorMessage = "XSD Validation failed with $($validationState.Errors.Count) error(s):`n"
            foreach ($err in $validationState.Errors) {
                $errorMessage += "  - Line $($err.LineNumber), Position $($err.LinePosition): $($err.Message)`n"
            }
        }

        return [PSCustomObject]@{
            IsValid = $validationState.IsValid
            Errors = $validationState.Errors
            ErrorMessage = $errorMessage
            SchemaValidated = $true
        }
    }
    catch {
        Write-Warning "Error during XSD validation: $_"
        return [PSCustomObject]@{
            IsValid = $false
            Errors = @([PSCustomObject]@{
                Severity = "Error"
                Message = $_.Exception.Message
                LineNumber = 0
                LinePosition = 0
            })
            ErrorMessage = "XSD validation error: $($_.Exception.Message)"
            SchemaValidated = $false
        }
    }
}

function Get-ValidationOverride {
    <#
    .SYNOPSIS
        Determines validation overrides based on lifecycle operation and validator configuration.

    .DESCRIPTION
        Reads an XML manifest and determines what overrides apply for a specific lifecycle operation
        and validator combination. Sets environment variables for test exclusions and severity overrides:
        - $ENV:envchkroverridetest - Comma-separated list of excluded tests
        - $env:envchkroverrideseverity - JSON lookup table of result severity overrides

        The manifest is retrieved via Get-ValidatedSolutionRecipe from the EnvironmentValidator component.
        If the commandlet is not available or no manifest URL is found, validation continues without overrides.

    .PARAMETER LifecycleOperation
        The lifecycle operation to evaluate (e.g., 'deployment', 'update', 'addnode', 'repairnode', 'upgrade')

    .PARAMETER ValidatorName
        The validator ID to evaluate (e.g., 'AzStackHCISoftware', 'DNS', 'Hardware')

    .PARAMETER EnforceSignature
        If true, requires the manifest XML to be digitally signed by Microsoft. Default is false.

    .EXAMPLE
        Get-ValidationOverride -LifecycleOperation "deployment" -ValidatorName "AzStackHCISoftware" -Verbose

    .EXAMPLE
        Get-ValidationOverride -LifecycleOperation "deployment" -ValidatorName "AzStackHCISoftware" -EnforceSignature $true
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LifecycleOperation,

        [Parameter(Mandatory = $true)]
        [string]$ValidatorName,

        [Parameter(Mandatory = $false)]
        [bool]$EnforceSignature = $false
    )

    begin {
        # Clear environment variables at start
        Write-Verbose "Clearing environment variables"
        $ENV:envchkroverridetest = $null
        $env:envchkroverrideseverity = $null
    }

    process {
        Invoke-ValidationOverrideProcessing -LifecycleOperation $LifecycleOperation -ValidatorName $ValidatorName -EnforceSignature $EnforceSignature
    }
}

function Get-ValidatorOverrideInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Validator,

        [Parameter(Mandatory)]
        [string]$LifecycleOperation
    )

    $enabled = [System.Convert]::ToBoolean($Validator.Enabled)
    $result = @{
        ValidatorEnabled = $enabled
        Reason = $null
        AppliedOverride = $false
    }

    # Get current module version
    $currentVersion = Get-ModuleYYMMVersion

    # Check global validator overrides
    if ($Validator.Overrides -and $Validator.Overrides.Override) {
        foreach ($override in $Validator.Overrides.Override) {
            $operations = @($override.LifecycleOperations.Operation)
            # Check if wildcard (*) is used or specific operation matches (case-insensitive)
            # Convert XML elements to strings first
            $operationsLower = $operations | ForEach-Object { [string]$_ | ForEach-Object { $_.ToLower() } }
            if (($operationsLower -contains '*') -or ($operationsLower -contains $LifecycleOperation.ToLower())) {
                # Check version range
                $minVersion = if ($override.MinVersion) { $override.MinVersion } else { $null }
                $maxVersion = if ($override.MaxVersion) { $override.MaxVersion } else { $null }

                if (Test-VersionInRange -CurrentVersion $currentVersion -MinVersion $minVersion -MaxVersion $maxVersion) {
                    $result.ValidatorEnabled = [System.Convert]::ToBoolean($override.Enabled)
                    $result.Reason = $override.Reason
                    $result.AppliedOverride = $true
                    Write-Verbose "Applied validator override for operation '$LifecycleOperation' (version $currentVersion in range [$minVersion, $maxVersion])"
                    break
                }
                else {
                    Write-Verbose "Skipping validator override for operation '$LifecycleOperation' (version $currentVersion outside range [$minVersion, $maxVersion])"
                }
            }
        }
    }

    return $result
}

function Get-TestOverrideInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Test,

        [Parameter(Mandatory)]
        [string]$LifecycleOperation
    )

    $enabled = [System.Convert]::ToBoolean($Test.Enabled)
    $result = @{
        TestName = $Test.Name
        TestEnabled = $enabled
        Reason = $null
        AppliedOverride = $false
    }

    # Get current module version
    $currentVersion = Get-ModuleYYMMVersion

    # Check test-specific overrides
    if ($Test.Overrides -and $Test.Overrides.Override) {
        foreach ($override in $Test.Overrides.Override) {
            $operations = @($override.LifecycleOperations.Operation)
            # Check if wildcard (*) is used or specific operation matches (case-insensitive)
            # Convert XML elements to strings first
            $operationsLower = $operations | ForEach-Object { [string]$_ | ForEach-Object { $_.ToLower() } }
            if (($operationsLower -contains '*') -or ($operationsLower -contains $LifecycleOperation.ToLower())) {
                # Check version range
                $minVersion = if ($override.MinVersion) { $override.MinVersion } else { $null }
                $maxVersion = if ($override.MaxVersion) { $override.MaxVersion } else { $null }

                if (Test-VersionInRange -CurrentVersion $currentVersion -MinVersion $minVersion -MaxVersion $maxVersion) {
                    $result.TestEnabled = [System.Convert]::ToBoolean($override.Enabled)
                    $result.Reason = $override.Reason
                    $result.AppliedOverride = $true
                    Write-Verbose "Applied test override for '$($Test.Name)' operation '$LifecycleOperation' (version $currentVersion in range [$minVersion, $maxVersion])"
                    break
                }
                else {
                    Write-Verbose "Skipping test override for '$($Test.Name)' operation '$LifecycleOperation' (version $currentVersion outside range [$minVersion, $maxVersion])"
                }
            }
        }
    }

    return $result
}

function Get-ResultSeverityOverrideInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Result,

        [Parameter(Mandatory)]
        [string]$LifecycleOperation
    )

    $resultObj = @{
        ResultName = $Result.ResultName
        FriendlyName = $Result.FriendlyName
        OverrideSeverity = $null
        Reason = $null
        AppliedOverride = $false
    }

    # Get current module version
    $currentVersion = Get-ModuleYYMMVersion

    # Check result-specific severity overrides
    if ($Result.Overrides -and $Result.Overrides.Override) {
        foreach ($override in $Result.Overrides.Override) {
            $operations = @($override.LifecycleOperations.Operation)
            # Check if wildcard (*) is used or specific operation matches (case-insensitive)
            # Convert XML elements to strings first
            $operationsLower = $operations | ForEach-Object { [string]$_ | ForEach-Object { $_.ToLower() } }
            if (($operationsLower -contains '*') -or ($operationsLower -contains $LifecycleOperation.ToLower())) {
                # Check version range
                $minVersion = if ($override.MinVersion) { $override.MinVersion } else { $null }
                $maxVersion = if ($override.MaxVersion) { $override.MaxVersion } else { $null }

                if (Test-VersionInRange -CurrentVersion $currentVersion -MinVersion $minVersion -MaxVersion $maxVersion) {
                    $resultObj.OverrideSeverity = $override.Severity
                    $resultObj.Reason = $override.Reason
                    $resultObj.AppliedOverride = $true
                    Write-Verbose "Applied result severity override for '$($Result.ResultName)' operation '$LifecycleOperation' (version $currentVersion in range [$minVersion, $maxVersion])"
                    break
                }
                else {
                    Write-Verbose "Skipping result severity override for '$($Result.ResultName)' operation '$LifecycleOperation' (version $currentVersion outside range [$minVersion, $maxVersion])"
                }
            }
        }
    }

    return $resultObj
}

function Invoke-ValidationOverrideProcessing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LifecycleOperation,

        [Parameter(Mandatory = $true)]
        [string]$ValidatorName,

        [Parameter(Mandatory = $false)]
        [bool]$EnforceSignature = $false
    )

    # Initialize minimal decision object for telemetry
    $decision = [PSCustomObject]@{
        LifecycleOperation = $LifecycleOperation
        ValidatorId = $ValidatorName
        ValidatorName = $null
        ManifestVersion = $null
        ProcessingStatus = "Started"
        ProcessingMessage = $null
        ErrorDetails = $null
        ManifestMetadata = @{
            Source = $null
            SignatureValid = $null
            IsMerged = $false
            HasSideloaded = $false
            OriginalSource = $null
            CacheAge = $null
            SideloadedSourcePath = $null
            SideloadedBy = $null
            SideloadedOn = $null
            LoadPrecedence = @(
                "1. Sideloaded manifest (highest priority)"
                "2. Cached manifest (if valid and within TTL)"
                "3. Local file from expected location"
                "4. Downloaded from URL (via Get-ValidatedSolutionRecipe)"
            )
        }
        Decisions = @{
            Validator = $null
            Tests = @()
            Results = @()
        }
    }

    try {
        # Attempt to get manifest from file or URL
        $manifestData = Get-ManifestFromFileOrUrl -EnforceSignature $EnforceSignature

        if (-not $manifestData -or -not $manifestData.Content) {
            $decision.ProcessingStatus = "NoManifestAvailable"

            # Build detailed message with retrieval attempts
            $attemptsDetail = ""
            if ($manifestData -and $manifestData.RetrievalAttempts) {
                $attemptsDetail = " Attempts: " + ($manifestData.RetrievalAttempts -join "; ")
            }

            $decision.ProcessingMessage = "No manifest available from any source. Continuing validation without overrides.$attemptsDetail"
            $decision.ValidatorName = $ValidatorName
            Write-Verbose $decision.ProcessingMessage
            return $null
        }

        Write-Verbose "Processing manifest from: $($manifestData.Source)"
        $xmlContent = $manifestData.Content

        # Update manifest metadata in decision
        $decision.ManifestMetadata.Source = $manifestData.Source
        $decision.ManifestMetadata.SignatureValid = $manifestData.SignatureValid
        $decision.ManifestMetadata.IsMerged = if ($manifestData.IsMerged) { $manifestData.IsMerged } else { $false }
        $decision.ManifestMetadata.HasSideloaded = if ($manifestData.HasSideloaded) { $manifestData.HasSideloaded } else { $false }
        $decision.ManifestMetadata.OriginalSource = if ($manifestData.OriginalSource) { $manifestData.OriginalSource } else { $null }
        $decision.ManifestMetadata.CacheAge = if ($manifestData.CacheAge) {
            if ($manifestData.CacheAge -lt 1) {
                "$([math]::Round($manifestData.CacheAge * 60, 1)) minutes"
            } else {
                "$([math]::Round($manifestData.CacheAge, 2)) hours"
            }
        } else { $null }
        $decision.ManifestMetadata.SideloadedSourcePath = if ($manifestData.SideloadedSourcePath) { $manifestData.SideloadedSourcePath } else { $null }
        $decision.ManifestMetadata.SideloadedBy = if ($manifestData.SideloadedBy) { $manifestData.SideloadedBy } else { $null }
        $decision.ManifestMetadata.SideloadedOn = if ($manifestData.SideloadedOn) { $manifestData.SideloadedOn } else { $null }

        # Parse XML manifest
        $manifest = $null
        try {
            [xml]$manifest = $xmlContent
            Write-Verbose "Successfully parsed XML manifest"
            $decision.ManifestVersion = $manifest.ValidationManifest.Version
        }
        catch {
            $decision.ProcessingStatus = "InvalidXml"
            $decision.ProcessingMessage = "Invalid XML format in manifest: $_. Continuing validation without overrides."
            $decision.ValidatorName = $ValidatorName
            Write-Verbose "Failed to parse XML content: $_"
            Write-Verbose "XML content preview: $($xmlContent.Substring(0, [Math]::Min(200, $xmlContent.Length)))"
            Write-Warning $decision.ProcessingMessage
            return $null
        }

        # Find the specified validator
        $validator = $manifest.ValidationManifest.Validators.Validator | Where-Object { $_.Id -eq $ValidatorName }

        if (-not $validator) {
            $decision.ProcessingStatus = "ValidatorNotFound"
            $decision.ProcessingMessage = "Validator '$ValidatorName' not found in manifest. Continuing validation without overrides."
            $decision.ValidatorName = $ValidatorName
            Write-Verbose $decision.ProcessingMessage
            return $null
        }

        $decision.ValidatorName = $validator.Name

        # Check if validator is applicable for current version
        $currentVersion = Get-ModuleYYMMVersion
        $minVersion = if ($validator.MinVersion) { $validator.MinVersion } else { $null }
        $maxVersion = if ($validator.MaxVersion) { $validator.MaxVersion } else { $null }

        if (-not (Test-VersionInRange -CurrentVersion $currentVersion -MinVersion $minVersion -MaxVersion $maxVersion)) {
            $decision.ProcessingStatus = "ValidatorVersionMismatch"
            $decision.ProcessingMessage = "Validator '$ValidatorName' not applicable for current version $currentVersion (valid range: [$minVersion, $maxVersion]). Continuing validation without this validator."
            $decision.ValidatorName = $validator.Name
            Write-Verbose $decision.ProcessingMessage
            return $null
        }

        # 1. Check Validator-level overrides
        $validatorOverride = Get-ValidatorOverrideInternal -Validator $validator -LifecycleOperation $LifecycleOperation
        $decision.Decisions.Validator = $validatorOverride

        # 2. Check Test-level overrides
        $excludedTests = @()
        if ($validator.Tests -and $validator.Tests.Test) {
            foreach ($test in $validator.Tests.Test) {
                $testOverride = Get-TestOverrideInternal -Test $test -LifecycleOperation $LifecycleOperation
                $decision.Decisions.Tests += $testOverride

                # Collect excluded tests
                if (-not $testOverride.TestEnabled) {
                    $excludedTests += $testOverride.TestName
                }
            }
        }

        # Set environment variable for excluded tests
        if ($excludedTests.Count -gt 0) {
            $ENV:envchkroverridetest = $excludedTests -join ','
        }

        # 3. Check Result-level severity overrides
        $severityLookup = @{}
        if ($validator.Results -and $validator.Results.Result) {
            foreach ($result in $validator.Results.Result) {
                $resultOverride = Get-ResultSeverityOverrideInternal -Result $result -LifecycleOperation $LifecycleOperation
                $decision.Decisions.Results += $resultOverride

                # Add to lookup table only if override was applied
                if ($resultOverride.AppliedOverride -and $resultOverride.OverrideSeverity) {
                    $severityLookup[$resultOverride.ResultName] = $resultOverride.OverrideSeverity
                }
            }
        }

        # Set environment variable for severity overrides as JSON
        if ($severityLookup.Count -gt 0) {
            $env:envchkroverrideseverity = $severityLookup | ConvertTo-Json -Compress
        }

        # Mark as successfully processed and build descriptive message
        $decision.ProcessingStatus = "Success"

        # Build specific message based on what was overridden
        $overrideDetails = @()
        if ($validatorOverride.AppliedOverride -and -not $validatorOverride.ValidatorEnabled) {
            $overrideDetails += "Validator disabled"
        }
        if ($excludedTests.Count -gt 0) {
            $overrideDetails += "$($excludedTests.Count) test(s) excluded"
        }
        if ($severityLookup.Count -gt 0) {
            $overrideDetails += "$($severityLookup.Count) result severity override(s)"
        }

        if ($overrideDetails.Count -gt 0) {
            $decision.ProcessingMessage = "Manifest processed successfully. Overrides applied: $($overrideDetails -join ', ')."
        } else {
            $decision.ProcessingMessage = "Manifest processed successfully. No overrides applicable for this operation."
        }

        # Return the decision object for programmatic use
        return $decision
    }
    catch {
        # Log error and continue without overrides
        $decision.ProcessingStatus = "Error"
        $decision.ProcessingMessage = "Error processing manifest: $_. Continuing validation without overrides."
        $decision.ErrorDetails = @{
            Exception = $_.Exception.Message
            ErrorType = $_.Exception.GetType().FullName
            ScriptStackTrace = $_.ScriptStackTrace
            TargetObject = if ($_.TargetObject) { $_.TargetObject.ToString() } else { $null }
        }
        Write-Warning $decision.ProcessingMessage
        Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
        return $null
    }
    finally {
        # Always write verbose decision summary if decisions were made
        if ($decision.Decisions.Validator) {
            Write-Verbose ""
            Write-Verbose "=========================================="
            Write-Verbose "Validation Override Decision Summary"
            Write-Verbose "=========================================="
            Write-Verbose "Lifecycle Operation: $($decision.LifecycleOperation)"
            Write-Verbose "Validator: $($decision.ValidatorName) ($($decision.ValidatorId))"
            Write-Verbose "Manifest Version: $($decision.ManifestVersion)"
            Write-Verbose "Processing Status: $($decision.ProcessingStatus)"

            # Validator-level decision
            Write-Verbose ""
            Write-Verbose "--- VALIDATOR LEVEL ---"
            if ($decision.Decisions.Validator.AppliedOverride) {
                Write-Verbose "  Status: OVERRIDDEN"
                Write-Verbose "  Enabled: $($decision.Decisions.Validator.ValidatorEnabled)"
                Write-Verbose "  Reason: $($decision.Decisions.Validator.Reason)"
            }
            else {
                Write-Verbose "  Status: DEFAULT"
                Write-Verbose "  Enabled: $($decision.Decisions.Validator.ValidatorEnabled)"
            }

            # Test-level decisions
            if ($decision.Decisions.Tests.Count -gt 0) {
                Write-Verbose ""
                Write-Verbose "--- TEST LEVEL ---"
                foreach ($test in $decision.Decisions.Tests) {
                    Write-Verbose "  Test: $($test.TestName)"
                    if ($test.AppliedOverride) {
                        Write-Verbose "    Status: OVERRIDDEN"
                        Write-Verbose "    Enabled: $($test.TestEnabled)"
                        Write-Verbose "    Reason: $($test.Reason)"
                    }
                    else {
                        Write-Verbose "    Status: DEFAULT"
                        Write-Verbose "    Enabled: $($test.TestEnabled)"
                    }
                }
            }

            # Result-level decisions
            if ($decision.Decisions.Results.Count -gt 0) {
                Write-Verbose ""
                Write-Verbose "--- RESULT SEVERITY LEVEL ---"
                foreach ($result in $decision.Decisions.Results) {
                    Write-Verbose "  Result: $($result.ResultName)"
                    if ($result.FriendlyName) {
                        Write-Verbose "    Friendly Name: $($result.FriendlyName)"
                    }
                    if ($result.AppliedOverride) {
                        Write-Verbose "    Status: OVERRIDDEN"
                        Write-Verbose "    Override Severity: $($result.OverrideSeverity)"
                        Write-Verbose "    Reason: $($result.Reason)"
                    }
                    else {
                        Write-Verbose "    Status: NO OVERRIDE"
                    }
                }
            }

            Write-Verbose ""
            Write-Verbose "Processing Message: $($decision.ProcessingMessage)"
            Write-Verbose "=========================================="
            Write-Verbose ""
        }

        # Always write telemetry regardless of success/failure
        try {
            Import-Module "$PSScriptRoot\AzStackHci.EnvironmentChecker.Reporting.psm1" -Force -ErrorAction SilentlyContinue
            Write-ManifestTelemetry -ManifestDecision $decision
        }
        catch {
            Write-Verbose "Failed to write manifest telemetry: $_"
        }
    }
}

function Get-ManifestSeverityOverride {
    <#
    .SYNOPSIS
        Applies manifest-based severity override to a result.

    .DESCRIPTION
        Checks the $env:envchkroverrideseverity environment variable for severity overrides
        and applies them to the result. Returns updated severity and detail message.

    .PARAMETER Name
        The result name to check for overrides

    .PARAMETER Severity
        The original severity value

    .EXAMPLE
        $override = Get-ManifestSeverityOverride -Name "AzStackHci_Software_NTP_Server_Consistency" -Severity "Critical"
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Severity
    )

    $result = @{
        Severity = $Severity
        OverrideApplied = $false
        Detail = $null
        AdditionalData = @{}
    }

    # Check for severity overrides from manifest
    if (-not [string]::IsNullOrEmpty($env:envchkroverrideseverity) -and -not [string]::IsNullOrEmpty($Name))
    {
        try
        {
            $severityOverrides = $env:envchkroverrideseverity | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($severityOverrides -and $severityOverrides.PSObject.Properties[$Name])
            {
                $overriddenSeverity = $severityOverrides.$Name
                if (-not [string]::IsNullOrEmpty($overriddenSeverity))
                {
                    $originalSeverity = $Severity
                    $result.Severity = $overriddenSeverity.ToUpper()
                    $result.OverrideApplied = $true
                    $result.AdditionalData.Override = @{
                        ResultName = $Name
                        OriginalSeverity = $originalSeverity
                        OverriddenSeverity = $result.Severity
                        Message = "Severity override applied for {0}: {1} to {2}" -f $Name, $originalSeverity, $result.Severity
                    }
                }
            }
        }
        catch
        {
            Write-Warning ("Failed to apply severity override for {0}. Error: {1}" -f $Name, $_.Exception.Message)
        }
    }

    return $result
}

function Get-NuPkgVersionFromFilename {
    <#
    .SYNOPSIS
        Extracts the version from a NuGet package filename.

    .DESCRIPTION
        Parses the version string from a NuGet package filename following the standard
        naming convention: PackageName.Version.nupkg

    .PARAMETER FileName
        The NuGet package filename (e.g., "AzStackHci.EnvironmentChecker.Manifest.10.2508.0.2048.nupkg")

    .PARAMETER PackageName
        Optional package name to validate against. If provided, ensures the filename matches this package.

    .EXAMPLE
        Get-NuPkgVersionFromFilename -FileName "AzStackHci.EnvironmentChecker.Manifest.10.2508.0.2048.nupkg"
        Returns "10.2508.0.2048"

    .OUTPUTS
        System.String - The version string extracted from the filename, or $null if parsing fails.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $false)]
        [string]$PackageName
    )

    try {
        # Remove .nupkg extension
        $nameWithoutExtension = $FileName -replace '\.nupkg$', ''

        # If package name provided, remove it from the start
        if ($PackageName) {
            if ($nameWithoutExtension -like "$PackageName.*") {
                $version = $nameWithoutExtension.Substring($PackageName.Length + 1)
                Write-Verbose "Extracted version '$version' from filename '$FileName' for package '$PackageName'"
                return $version
            }
            else {
                Write-Warning "Filename '$FileName' does not match expected package name '$PackageName'"
                return $null
            }
        }
        else {
            # Try to extract version assuming last segments are version numbers
            # Pattern: Name.Major.Minor.Build.Revision.nupkg
            if ($nameWithoutExtension -match '\.(\d+\.\d+\.\d+\.\d+)$') {
                $version = $Matches[1]
                Write-Verbose "Extracted version '$version' from filename '$FileName'"
                return $version
            }
            elseif ($nameWithoutExtension -match '\.(\d+\.\d+\.\d+)$') {
                $version = $Matches[1]
                Write-Verbose "Extracted version '$version' from filename '$FileName'"
                return $version
            }
            else {
                Write-Warning "Could not extract version from filename '$FileName'"
                return $null
            }
        }
    }
    catch {
        Write-Error "Failed to parse version from filename '$FileName': $_"
        return $null
    }
}

function Get-LatestLocalNuGetPackage {
    <#
    .SYNOPSIS
        Gets the latest version of a NuGet package from the local NuGet store.

    .DESCRIPTION
        Searches C:\NugetStore for the specified package and returns information about
        the latest version available locally. Uses Get-ASArtifactPath if available,
        otherwise falls back to directory search. Packages in the store are expanded
        into directories, not stored as .nupkg files.

    .PARAMETER PackageName
        The name of the NuGet package to search for. Defaults to the manifest package name.

    .EXAMPLE
        Get-LatestLocalNuGetPackage

    .EXAMPLE
        Get-LatestLocalNuGetPackage -PackageName "AzStackHci.EnvironmentChecker.Manifest"

    .OUTPUTS
        PSCustomObject with Path, Version, and DirectoryName properties, or $null if not found.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$PackageName = $script:ManifestNuGetName
    )

    try {
        # Try Get-ASArtifactPath first if available (preferred method)
        if (Get-Command -Name Get-ASArtifactPath -ErrorAction SilentlyContinue) {
            Write-Verbose "Using Get-ASArtifactPath to locate package '$PackageName'"
            try {
                $artifactPath = Get-ASArtifactPath -NugetName $PackageName -ErrorAction SilentlyContinue

                if ($artifactPath -and (Test-Path $artifactPath)) {
                    # Extract version from directory name
                    $dirName = Split-Path -Path $artifactPath -Leaf
                    $version = Get-NuPkgVersionFromFilename -FileName $dirName -PackageName $PackageName

                    if ($version) {
                        Write-Verbose "Found package via Get-ASArtifactPath: $dirName (Version: $version)"
                        return [PSCustomObject]@{
                            Path = $artifactPath
                            DirectoryName = $dirName
                            Version = $version
                            VersionObject = [version]$version
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Get-ASArtifactPath failed: $_. Falling back to directory search."
            }
        }

        # Fall back to searching NuGet store directories
        if (-not (Test-Path $script:NuGetStoreDirectory)) {
            Write-Verbose "NuGet store directory does not exist: $script:NuGetStoreDirectory"
            return $null
        }

        # Search for expanded package directories matching pattern
        $searchPattern = "$PackageName.*"
        $packageDirs = Get-ChildItem -Path $script:NuGetStoreDirectory -Filter $searchPattern -Directory -ErrorAction SilentlyContinue

        if (-not $packageDirs -or $packageDirs.Count -eq 0) {
            Write-Verbose "No local packages found for '$PackageName' in $script:NuGetStoreDirectory"
            return $null
        }

        # Parse versions from directory names and find latest
        $packagesWithVersions = $packageDirs | ForEach-Object {
            $version = Get-NuPkgVersionFromFilename -FileName $_.Name -PackageName $PackageName
            if ($version) {
                try {
                    [PSCustomObject]@{
                        Path = $_.FullName
                        DirectoryName = $_.Name
                        Version = $version
                        VersionObject = [version]$version
                    }
                }
                catch {
                    Write-Verbose "Skipping directory '$($_.Name)' - invalid version format: $_"
                    $null
                }
            }
        } | Where-Object { $_ -ne $null }

        if ($packagesWithVersions) {
            $latest = $packagesWithVersions | Sort-Object -Property VersionObject -Descending | Select-Object -First 1
            Write-Verbose "Found latest local package: $($latest.DirectoryName) (Version: $($latest.Version))"
            return $latest
        }
        else {
            Write-Verbose "Could not parse versions from any package directories"
            return $null
        }
    }
    catch {
        Write-Error "Failed to get latest local NuGet package: $_"
        return $null
    }
}

function Get-ManifestNuGetFromRecipe {
    <#
    .SYNOPSIS
        Gets the manifest NuGet package URL and version from Validated Solution Recipe.

    .DESCRIPTION
        Queries Get-ValidatedSolutionRecipe to find the manifest NuGet package URL.
        Extracts the version from the URL filename without downloading.

    .EXAMPLE
        Get-ManifestNuGetFromRecipe

    .OUTPUTS
        PSCustomObject with Url, Version, and FileName properties, or $null if not found.
    #>
    [CmdletBinding()]
    param()

    try {
        # Check if Get-ValidatedSolutionRecipe commandlet exists
        if (-not (Get-Command -Name Get-ValidatedSolutionRecipe -ErrorAction SilentlyContinue)) {
            Write-Verbose "Get-ValidatedSolutionRecipe commandlet not found"
            return $null
        }

        Write-Verbose "Getting manifest NuGet URL from Validated Solution Recipe"
        $recipe = Get-ValidatedSolutionRecipe
        $environmentValidatorComponent = $recipe.Components | Where-Object Name -eq "EnvironmentValidator"

        if (-not $environmentValidatorComponent) {
            Write-Verbose "EnvironmentValidator component not found in recipe"
            return $null
        }

        $payloads = $environmentValidatorComponent.Payloads
        $manifestPayload = $payloads | Where-Object { $_.Identifier -like '*EnvironmentValidator_Manifest*' } | Select-Object -First 1

        if (-not $manifestPayload) {
            Write-Verbose "No manifest payload found in EnvironmentValidator component"
            return $null
        }

        $url = $manifestPayload.Url
        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Verbose "Manifest payload URL is empty"
            return $null
        }

        # Extract filename from URL
        $fileName = Split-Path -Path $url -Leaf

        # Use PayloadVersion from recipe if available, otherwise parse from filename
        $version = $null
        if ($manifestPayload.PayloadVersion) {
            $version = $manifestPayload.PayloadVersion
            Write-Verbose "Using PayloadVersion from recipe: $version"
        }
        else {
            # Fallback to parsing from filename for backward compatibility
            Write-Verbose "PayloadVersion not found in recipe, parsing from filename"
            $version = Get-NuPkgVersionFromFilename -FileName $fileName -PackageName $script:ManifestNuGetName
        }

        if (-not $version) {
            Write-Warning "Could not determine version from manifest NuGet (Payload: $($manifestPayload.Identifier), FileName: $fileName)"
            return $null
        }

        Write-Verbose "Found manifest NuGet from recipe: $fileName (Version: $version)"

        return [PSCustomObject]@{
            Url = $url
            FileName = $fileName
            Version = $version
            VersionObject = [version]$version
        }
    }
    catch {
        Write-Verbose "Failed to get manifest NuGet from recipe: $_"
        return $null
    }
}

function Expand-ManifestNuGetPackage {
    <#
    .SYNOPSIS
        Downloads and expands a manifest NuGet package to the local store.

    .DESCRIPTION
        Downloads a manifest NuGet package from URL and expands its contents to
        C:\NugetStore using the CloudCommon module's Expand-NugetContent function.

    .PARAMETER Url
        URL to download the NuGet package from.

    .PARAMETER FileName
        Name of the NuGet package file.

    .EXAMPLE
        Expand-ManifestNuGetPackage -Url "https://example.com/package.nupkg" -FileName "package.nupkg"

    .OUTPUTS
        System.Boolean - Returns $true if successful, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    try {
        # Ensure NuGet store directory exists
        if (-not (Test-Path $script:NuGetStoreDirectory)) {
            New-Item -Path $script:NuGetStoreDirectory -ItemType Directory -Force | Out-Null
            Write-Verbose "Created NuGet store directory: $script:NuGetStoreDirectory"
        }

        # Download NuGet package to store
        $nupkgPath = Join-Path $script:NuGetStoreDirectory $FileName
        Write-Verbose "Downloading manifest NuGet package from: $Url"

        $maxRetries = 3
        $retryDelaySeconds = 2
        $downloaded = $false

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                if ($attempt -gt 1) {
                    Write-Verbose "Retry attempt $attempt of $maxRetries"
                    Start-Sleep -Seconds $retryDelaySeconds
                }

                Invoke-WebRequest -Uri $Url -OutFile $nupkgPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                Write-Verbose "Successfully downloaded NuGet package on attempt $attempt"
                $downloaded = $true
                break
            }
            catch {
                Write-Verbose "Download attempt $attempt failed: $_"
                if ($attempt -eq $maxRetries) {
                    throw
                }
            }
        }

        if (-not $downloaded) {
            throw "Failed to download NuGet package after $maxRetries attempts"
        }

        # Check if CloudCommon module is available
        $cloudCommonModule = Get-Module -Name CloudCommon -ListAvailable -ErrorAction SilentlyContinue
        if (-not $cloudCommonModule) {
            Write-Warning "CloudCommon module not found. Attempting to import from known locations..."
            # Try common module paths
            $possiblePaths = @(
                "C:\Program Files\WindowsPowerShell\Modules\CloudCommon",
                "C:\Windows\System32\WindowsPowerShell\v1.0\Modules\CloudCommon"
            )
            foreach ($path in $possiblePaths) {
                if (Test-Path $path) {
                    Import-Module $path -ErrorAction SilentlyContinue
                    break
                }
            }
        }
        else {
            Import-Module CloudCommon -ErrorAction Stop
        }

        # Verify Expand-NugetContent is available
        if (-not (Get-Command -Name Expand-NugetContent -ErrorAction SilentlyContinue)) {
            throw "Expand-NugetContent command not found. CloudCommon module may not be properly installed."
        }

        # Expand NuGet package content to store
        $packageNameWithoutExt = $FileName -replace '\.nupkg$', ''
        $destinationPath = Join-Path $script:NuGetStoreDirectory $packageNameWithoutExt

        Write-Verbose "Expanding NuGet package to: $destinationPath"
        Expand-NugetContent -NuGetName $packageNameWithoutExt -SourcePath "content" -DestinationPath $destinationPath -ErrorAction Stop

        Write-Verbose "Successfully expanded manifest NuGet package"
        return $true
    }
    catch {
        Write-Error "Failed to expand manifest NuGet package: $_"
        # Clean up downloaded file if expansion failed
        if (Test-Path $nupkgPath) {
            Remove-Item -Path $nupkgPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Get-NuPkgFileVersion {
    <#
    .SYNOPSIS
        Extracts the version string from a NuGet package (.nupkg) file.

    .DESCRIPTION
        Opens a NuGet package file and reads the version from the embedded .nuspec file.
        NuGet packages are ZIP archives containing a .nuspec manifest file.

    .PARAMETER Path
        Path to the .nupkg file to extract the version from.

    .EXAMPLE
        Get-NuPkgFileVersion -Path "C:\packages\MyPackage.1.0.0.nupkg"
        Returns "1.0.0"

    .OUTPUTS
        System.String - The version string from the package.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [string]$Path
    )

    try {
        $nupkg = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $nuspecEntry = $nupkg.Entries | Where-Object { $_.FullName -like "*.nuspec" }
            if ($null -eq $nuspecEntry) {
                throw "No .nuspec file found in the nupkg."
            }

            $nuspecStream = $nuspecEntry.Open()
            try {
                $reader = [System.IO.StreamReader]::new($nuspecStream)
                $nuspecContent = $reader.ReadToEnd()
                $reader.Close()

                $nuspecXml = [xml]$nuspecContent
                $version = $nuspecXml.package.metadata.version

                if ([string]::IsNullOrWhiteSpace($version)) {
                    throw "Version element not found in .nuspec file."
                }

                return $version
            }
            finally {
                if ($nuspecStream) { $nuspecStream.Close() }
            }
        }
        finally {
            if ($nupkg) { $nupkg.Dispose() }
        }
    }
    catch {
        Write-Error "Failed to extract version from NuGet package '$Path': $_"
        throw
    }
}

# Export the main functions
Export-ModuleMember -Function Get-ValidationOverride, `
                              Get-ManifestSeverityOverride, `
                              Test-ManifestXmlSignature, `
                              Test-ManifestXsdValidation, `
                              Set-ValidationManifest, `
                              Clear-ValidationManifest, `
                              Get-NuPkgFileVersion, `
                              Get-NuPkgVersionFromFilename, `
                              Get-LatestLocalNuGetPackage, `
                              Get-ManifestNuGetFromRecipe, `
                              Expand-ManifestNuGetPackage, `
                              Get-ManifestFromFileOrUrl

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCANpwJjpvT0HWHA
# C2sd5S8AhqZQavJW0xiAo66QRrXiI6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIO9zypnB
# +NVNWE3amSJtBZXahtBNLbGuT6AaLk9gpIeAMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAmL+vXlVi8shOdQUCqVkt/kNnNnFReyN0EbnRmUCj
# WqQ3liHs2ilmEpIYPUnSbUxRQIgYBhrdgneTK3qYtHRtJW2cN+EzNX87c3weq0DC
# BrlVt0Y+/gyuG9hBRmIMe25jV3pnOmEqoPe5aRP9sA5nxSTmwpjDpbEQ9PIacjfX
# ETME+mJtZ2te6sdGMrSrdYJLPAe7dBc7AsElWf50jUjfMLc4eQyoo2gBXxT2EH3I
# gVtJWquRyUm6gBpxGHSOEXwzLRcD/DlH7wiF0Wwyf0uHfxO0ndykduUR3AgiEkjs
# p2HLxekR+Iso/PBr7wXIAc6+MfEpp8K5kAvcH75cLCaVwaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCD4qwNF5HJEel7D6prBU2q212H4gfIX+AAC0T54
# farBNwIGadfEjs1HGBMyMDI2MDUwMzE0MzExMC4zODhaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiNP2WAkU8/+KwABAAAC
# IzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTdaFw0yNzA1MTcxOTM5NTdaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCK6Q2nk5WUdKzSCSafp+UjUARs
# WxHKS63rJhFC/zSabFumTBuaJ0QNrmqevub5Db7fSj5qtwwKnjIO92+HXF67192f
# ujL7DFot5WEj/AtEZ/XrzFHimKlN1h6gEQwP5I67wizaPW5ZzSBNpaLBg5oHvASP
# OZtwdNUoZ+DQKF3hJl1KZuoIlVK+qi7cLjgak6s5oOZcRCMrKnuC3aoVa6wRDbYv
# KUuj7rkFx9KO0PsHJ/k+LnZMggRheh4AVdawyh+oOzKPjlQGUNfSeWUgym2U9CLa
# 8tt0mQX4DxDz6+ram50gj1oAfyQ6TQ7r96PADFOKBgaU7+cpHnaZG89dTegQ6ydB
# RGIycOw1dRX2eKDRRzziK3cn0WaIm/7OeGsyQKjIzEQuUTDv0Jj/9zQ7truLOOpJ
# D98BJVOK7je84Sz2hb3HvUST7j1j2N8peD6olkpFHR/1Z8Jz4F+mkrUF7MmPAirY
# HRzunbIg3HrDMNwFYN7yBkDA4/VMo9CY0y9oGUoq2yjbCwTibz9VYl93nB3QQiTC
# T9nW3M+TOWB+PMrZpExq1BSHmKPzIqehKqrUDoM33PK+dEKwpYLET6uXq4HuQRMX
# WT//sPubUnQAaaUMfQhAZSy23HtxwtN3eK9+T4wCav2wQFt57eUOwUW5/DCzMF9t
# ua5He1hNvgcAXaiG1wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNbAh89v29nPY9bw
# Qb1QYCzxVgeXMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCHQwe7z5tp4NZwAf1c
# B+4c9J4svw3P6WqGBMxtqznS6DdzUzStXHCaPZhM41g1iKHNnmcnLjwLujOEaNjh
# SnUDiAZqQjW5ZapOBxgc7Egghh9k+r78qWAe3rJ4QohBbhSGdZtKivTRaeRqmnhy
# 8+ThrKhzCeEwaarXJimZwSpdQQUDbheWHeyAxASqultd5KO0m/UFvO03tfepqGXA
# 4tCg/WGECwKqOjJzpRAfPIB6y1HyVrk+vmL5rpEbTwwLOtX7WxFGG8+cYLk9HjaD
# kxraA/HYlKQRx1sdza+w/gulLwgOnByRJKF2rr8M7FNIlwoi6ywFpaNc8A7HewaG
# jgw/tfcE260I1XekGluANI9HnONOYWlI7BKBQbWE2teo6vsQ1Vg8B8rTZSePVdmX
# L1PPqqs3KVdFKM5kYocPCDM+6VL32IV96sESf2T7DjxanpCg2D2UYj4Z1i7cy8U1
# LLDGg55KWs4af2RRBjH2MulHgAmW5obKxiZCDQjRaroJ2XElXUhigE9BzvhCFbT/
# HDY2vpVpl5HnSpcCSxmL5i5lIT/xbAQMI7Luh75Xrm+IslfFWOGOGMlCp+24qEJE
# glXEP7xwsolNdBNndXihhyIefVGlI1DR7xGELiJrk8ifVWYo9XEbEXv/lbvp6F2R
# 2UsnweWckvq0y1HWnLHDqH6dPjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQA4RWFs+kTiZnoZiAj1BtYj8zCNaqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aE6szAiGA8y
# MDI2MDUwMzAzMDgzNVoYDzIwMjYwNTA0MDMwODM1WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoTqzAgEAMAoCAQACAgL2AgH/MAcCAQACAhJCMAoCBQDtoowzAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAK62FgK5K5XFuLoLHYR6IUW+ogJf
# KCdyOFrPfdTzuENPYK4pNJRhdSYBwZLnmbGbVkZDDTDbfoHKrru9aeR7Yz01YO+s
# KuJlnqXWr1KaCtN+3JD3UPXJVScMbMTniu6dkoWFw2h3TD8IvlxYAub419x2i42f
# Xee7sCLaYJYCyEYPuadY7XVpoveMOQeaaUy4CnFaXuxFE6H7kDC6MrIWN1G2mmkJ
# WNRsoKoA9Srs2ZfnRZuyX2F0j13KNLZ8Fy+lTnUATgAhEDJHsaKT+A2NJQumzsqy
# zINUNUVOO6KLYVQbO6Akb5xWoRsBzRw9dTPYNpAhbhqQtaoC3KGR899zWNsxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiNP
# 2WAkU8/+KwABAAACIzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCD1hRV4Gj4FB8kH7FKBZXjHrNOD
# 5fsb7j/OPZyAaORAVjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIJbwMywR
# bvcGiynjnwjAqcaD47yYvebKZRAvtEAR5u6zMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIjT9lgJFPP/isAAQAAAiMwIgQgit078tPa
# fcQnnQptmE1wsN7QTb6Exag5U1V1RqiSX9owDQYJKoZIhvcNAQELBQAEggIAUWg3
# BG9G1mJIxxqMehIjdNV37zFymzzTH9g084bgFAA5JTMI7fkUT0FcaHE1zn2yqpSX
# wfg18Yf29iSGjMtkAuEeozOpQ/9GOIrLQZwSwwDDzDHFtPs/1z94b812FNwYDZrw
# cXKhvDhsbdL1b7tOK+bB7ShXmOW+bcn/zKIfTyBYTws/T6ytjTex/vA9yWpIrQgm
# BTvhXS2jTE7ZcS9crRcTQpzNNQoXJehEsNKIibgcHZt1pWJyMMxnZjNJ6eloYLAP
# +XKotXgSSx13U6ssUjX5Ce4y1oiB+5Wjthh/EI1QX+EPGgwgUXqg1d/sW/Rpmqiu
# Onprl6oE469gwjicWKel/DGAZ4J3BAHuyKp458ZEGXr8rfuZ+Bx+5eFykQzo2l7r
# aAkojKs9hdc6QkiqIxXjh0gZCAqrz8EbEkBm6oavQ6ikeIXQoCFy4fu7pkgrDqby
# /laOOT2pAZM53ghCduWHduIi/ljBAMunYqSvBkglwvSSoa7a4kqMly0F9Nu8q6Pw
# 29RhUWTHueGfQsfPgs+Y8OnDGBl7SvR4Q00CnM5ewlqK3StB+9mahuJhdHu0ekdO
# fcDGGkzR+V9FSCWnoPj66qqDr8bxEOtA5E/zXfhqComKANsPpGefqQadgrD9ubyG
# uKV1F+LwDlFabqw0hegHh3N22uh++8F2f1NAgZE=
# SIG # End signature block
