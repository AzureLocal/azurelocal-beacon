Import-LocalizedData -BindingVariable locSbeTxt -FileName AzStackHci.SBEHealth.Strings.psd1

function Get-ASArtifactPathLite
{
    <#
    .SYNOPSIS
    Returns the nuget content path.  Same as normal Get-ArtifactPath except it doesn't use Trace-Execution or try to locate on ProductVHD.

    .DESCRIPTION
    Calculates and returns the path to the nuget content folder for the specified nuget on the current infrastructure vm environment. All product artifacts are
    exposed to the infrastructure vms, however the location is not fixed, this method is used to find the desired content.

    .EXAMPLE
    $Path = Get-ASArtifactPathLite -NugetName "Microsoft.Diagnostics.Tracing.EventSource.Redist"

    .PARAMETER NugetName
    The full name of the nuget without version information.

    .PARAMETER Version
    The optional version number of the package.

    #>
    [CmdletBinding()]
    PARAM
    (
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $NugetName,

        [Parameter(Mandatory=$false)]
        [System.String]
        $Version = $null
    )
    PROCESS
    {
        $VerbosePreference = [System.Management.Automation.ActionPreference]::Continue
        Import-Module PackageManagement -DisableNameChecking -Verbose:$false | Out-Null

        $nugetProvider = Get-PackageProvider | Where-Object { $_.Name -eq "Nuget" }

        if ($nugetProvider -eq $null)
        {
            Log-Info -Message "Attempting to install nuget package provider."
            Install-PackageProvider nuget -Force -ForceBootstrap
        }

        $drivePath = "$env:SystemDrive\NugetStore"

        if (Test-Path -Path $drivePath)
        {
            if ($Version)
            {
                $package = Get-Package -Name $NugetName -Destination $drivePath -ErrorAction Stop -RequiredVersion $Version -ProviderName Nuget
            }
            else
            {
                $package = Get-Package -Name $NugetName -Destination $drivePath -ErrorAction Stop -ProviderName Nuget
            }

            Log-Info -Message "Get-Package returned with Success:$($?)"
        }

        if ($package -eq $null)
        {
            throw "Could not find package $NugetName on source $drivePath."
        }

        Log-Info -Message  "Found package $($package.Name) with version $($package.Version) at $($package.Source)."

        return [System.IO.Path]::GetDirectoryName($package.Source);
    }
}

function Copy-SBEContentLocalToNode
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackagePath,

        [Parameter(Mandatory=$true)]
        [string]$TargetNodeName,

        [Parameter(Mandatory=$true)]
        [string]$DestPath,

        [Parameter(Mandatory=$false)]
        [string[]]$ExcludeDirs,

        [Parameter(Mandatory=$false)]
        [string[]]$ExcludeFiles,

        [Parameter(Mandatory=$false)]
        [switch]$SkipNugetCopy,

        [PSCredential]$Credential
    )

    $copyItems = @()

    # Note - this function only works on the seed node as only it will have NugetStore bootstrapped.
    $sbeConfig = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.SBEConfiguration"
    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
    if ($Credential)
    {
        Log-Info ("$($MyInvocation.MyCommand.Name) - Username is '{0}'" -f $Credential.UserName)
    }
    else
    {
        # Credential is not needed if the target is the seed node (in this case it is copying to itself)
        Log-Info "$($MyInvocation.MyCommand.Name) - Credential was not provided"
    }

    # Check if the copy destination is the current node
    $targetIsCurrentNode = $false
    if ($env:ComputerName -eq $TargetNodeName)
    {
        Log-Info "$($MyInvocation.MyCommand.Name) - Current node ComputerName matched TargetNodeName"
        $targetIsCurrentNode = $true
    }
    else
    {
        $thisComputerName = $null
        $foundDnsModule = Get-Command -Module DnsClient -Name Register-DnsClient -ErrorAction SilentlyContinue
        if ($null -eq $foundDnsModule)
        {
            Import-Module -Name DnsClient -ErrorAction SilentlyContinue -Force | Out-Null
        }
        $dnsName = ((Resolve-DnsName -Name $TargetNodeName -ErrorAction SilentlyContinue) | Select-Object -First 1)
        if ($dnsName.NameHost)
        {
            # Case when IP is resolved
            $thisComputerName = ($dnsName.NameHost).Split('.')[0]
            if ($env:ComputerName -eq $thisComputerName)
            {
                Log-Info "$($MyInvocation.MyCommand.Name) - Current node ComputerName matched Resolve-DnsName by IP address"
                $targetIsCurrentNode = $true
            }
        }
        elseif ($dnsName.Name)
        {
            # Case when hostname is resolved
            $thisComputerName = ($dnsName.Name).Split('.')[0]
            if ($env:ComputerName -eq $thisComputerName)
            {
                Log-Info "$($MyInvocation.MyCommand.Name) - Current node ComputerName matched Resolve-DnsName by hostname"
                $targetIsCurrentNode = $true
            }
        }
        else
        {
            # No DNS match so try IP address instead
            [array]$myIP = (Get-NetIPAddress).IPAddress
            if ($TargetNodeName -in $myIP)
            {
                Log-Info "$($MyInvocation.MyCommand.Name) - TargetNodeName was matched in the current node myIP list"
                $targetIsCurrentNode = $true
            }
        }
    }
    if ($true -eq $targetIsCurrentNode)
    {
        $finalDestPath = $DestPath
        Log-Info "$($MyInvocation.MyCommand.Name) - Target node is the current node, so use local path as destination: $finalDestPath"
    }
    else
    {
        Log-Info "$($MyInvocation.MyCommand.Name) - Target node is a remote node, so need to map PSDrive(s)"
        Get-PSDrive -Name SBE -ErrorAction SilentlyContinue | Remove-PSDrive -Force
        if ($DestPath -match '^(\w):')
        {
            $destRoot = '\\' + $TargetNodeName + '\' + $Matches[1] + '$'
        }
        else
        {
            throw "Unable to determine proper path to copy SBE. Dest structure is unexpected '$DestPath'."
        }
        $systemDriveRoot = '\\' + $TargetNodeName + '\' + ($env:SystemDrive ).Replace(':','$')

        $retry = $true
        $maxRetry = 4
        $attempt = 0
        while ($true -eq $retry)
        {
            $attempt++
            Log-Info "$($MyInvocation.MyCommand.Name) - Map New-PSDrive to '$($destRoot)', attempt '$($attempt)/$($maxRetry)'"
            try
            {
                $destDrv = New-PSDrive -Credential $Credential -Name SBECACHE -PSProvider FileSystem -Root $destRoot -ErrorAction SilentlyContinue
            }
            catch
            {
                $errMessage = $PSItem.Exception.Message
                Log-Info "$($MyInvocation.MyCommand.Name) - New-PSDrive failed with exception: $($errMessage)"
            }
            $found = Get-PSDrive -Name SBECACHE
            if ($found -and $found.Root -eq $destRoot)
            {
                $errMessage = ''
                $retry = $false
            }
            else
            {
                if ($attempt -ge $maxRetry)
                {
                    throw "Failed to map New-PSDrive after '$($attempt)' attempts. Exception: '$($errMessage)'"
                    $retry = $false
                }
                Start-Sleep -Seconds 15
            }
        }
        # Change the destination path to use the mounted drive letter...
        $finalDestPath = $DestPath -replace '^\w:', $destDrv.Root
        Log-Info "$($MyInvocation.MyCommand.Name) - Changing DestPath from $DestPath to $finalDestPath."

        if ($destRoot -ne $systemDriveRoot -and $false -eq $SkipNugetCopy.IsPresent)
        {
            $retry = $true
            $maxRetry = 4
            $attempt = 0
            while ($true -eq $retry)
            {
                $attempt++
                Log-Info "$($MyInvocation.MyCommand.Name) - Map New-PSDrive to '$($systemDriveRoot)', attempt '$($attempt)/$($maxRetry)'"
                try
                {
                    $sysDrv = New-PSDrive -Credential $Credential -Name SBESYSROOT -PSProvider FileSystem -Root $systemDriveRoot -ErrorAction SilentlyContinue
                }
                catch
                {
                    $errMessage = $PSItem.Exception.Message
                    Log-Info "$($MyInvocation.MyCommand.Name) - New-PSDrive failed with exception: $($errMessage)"
                }
                $found = Get-PSDrive -Name SBESYSROOT
                if ($found -and $found.Root -eq $systemDriveRoot)
                {
                    $errMessage = ''
                    $retry = $false
                }
                else
                {
                    if ($attempt -ge $maxRetry)
                    {
                        throw "Failed to map New-PSDrive after '$($attempt)' attempts. Exception: '$($errMessage)'"
                        $retry = $false
                    }
                    Start-Sleep -Seconds 15
                }
            }
            $sbeConfigDest = $sbeConfig.Replace($env:SystemDrive,$sysDrv.Root)
            $sbeRoleDest = $sbeRoleNuget.Replace($env:SystemDrive,$sysDrv.Root)
        }
        elseif ($false -eq $SkipNugetCopy.IsPresent)
        {
            Log-Info "$($MyInvocation.MyCommand.Name) - Using the destDrv mount to copy Config and Role Nugets."
            $sbeConfigDest = $sbeConfig.Replace($env:SystemDrive,$destDrv.Root)
            $sbeRoleDest = $sbeRoleNuget.Replace($env:SystemDrive,$destDrv.Root)
        }
        else
        {
            Log-Info "$($MyInvocation.MyCommand.Name) - Skipping sysDrv mount - we don't need to copy Config or Role Nugets."
            # This is typical of post-deploy OperationType like "Update" where the SBE.Role nuget is already available on all nodes and the SBEConfiguration nuget is not needed.
        }
    }
    $msg = "$($MyInvocation.MyCommand.Name) - " + ($locSbeTxt.WillCopyToPSDrive -f 'SBE package contents',$finalDestPath,$TargetNodeName)
    Log-Info -Message $msg
    $copyItems += @{Source=$PackagePath;Destination=$finalDestPath}
    if (-not([string]::IsNullOrWhitespace($sbeConfigDest)))
    {
        $msg = "$($MyInvocation.MyCommand.Name) - " + ($locSbeTxt.WillCopyToPSDrive -f 'SBEConfiguration',$sbeConfigDest,$TargetNodeName)
        Log-Info -Message $msg
        $copyItems += @{Source=$sbeConfig;Destination=$sbeConfigDest}
    }
    if (-not([string]::IsNullOrWhitespace($sbeRoleDest)))
    {
        $msg = "$($MyInvocation.MyCommand.Name) - " + ($locSbeTxt.WillCopyToPSDrive -f 'SBE.Role nuget',$sbeRoleDest,$TargetNodeName)
        Log-Info -Message $msg
        $copyItems += @{Source=$sbeRoleNuget;Destination=$sbeRoleDest}
    }

    [string]$exclude = ""
    if ($ExcludeFiles.Count -ne 0)
    {
        $exclude += " /XF $ExcludeFiles"
    }
    if ($ExcludeDirs.Count -ne 0)
    {
        $exclude += " /XD $ExcludeDirs"
    }

    foreach ($item in $copyItems)
    {
        try
        {
            $msg = "$($MyInvocation.MyCommand.Name) - " + ($locSbeTxt.CopySBEToNode -f $item.Source,$TargetNodeName,$item.Destination)
            Log-Info -Message $msg -Type Info
            $copyCmd = "robocopy.exe $($item.Source) $($item.Destination) *.* /MIR /NP /R:2 /W:10$exclude"
            $output = Invoke-Command -ScriptBlock { cmd.exe /c $copyCmd }
            # Check for exit code. If exit code is greater than 7, an error occurred while peforming the copy operation.
            if ($LASTEXITCODE -ge 8)
            {
                $msg = "$($MyInvocation.MyCommand.Name) - " + ($locSbeTxt.RobocopyFailed -f $LASTEXITCODE)
                Log-Info -Message $msg -ConsoleOut -Type Error
                $msg = "$($MyInvocation.MyCommand.Name) - " + ($output | Out-String).Trim()
                Log-Info -Message $msg -ConsoleOut -Type Info
                if ($destDrv) { $destDrv | Remove-PSDrive -ErrorAction SilentlyContinue }
                if ($sysDrv) { $sysDrv | Remove-PSDrive -ErrorAction SilentlyContinue }
                return $false
            }
            else
            {
                try
                {
                    if ($true -eq (Test-Path -Path $item.Destination -PathType Container))
                    {
                        Log-Info -Message "$($MyInvocation.MyCommand.Name) - Unblock-File for destination '$($item.Destination)'" -Type Info
                        Get-ChildItem -Path $item.Destination -Recurse | ForEach-Object { Unblock-File -Path $PSItem.FullName -ErrorAction SilentlyContinue }
                    }
                    else
                    {
                        # Expected destination to exist as a folder
                        Log-Info -Message "$($MyInvocation.MyCommand.Name) - Expected a folder for Unblock-File: $($item.Destination)" -Type Warning
                    }
                }
                catch
                {
                    # Ignore errors here
                    Log-Info -Message "$($MyInvocation.MyCommand.Name) - Error occurred during Unblock-File: $($PSItem.Exception.Message)" -Type Warning
                }
            }
        }
        catch
        {
            Log-Info -Message ("$($MyInvocation.MyCommand.Name) - Copy operation failed with error: " + $PSItem.Exception.Message) -Type Error
            throw "Copy operation '$($copyCmd)' failed with error: $($PSItem.Exception.Message)"
        }
        finally
        {
            # Remove any mapped PSDrives
            if (Get-PSDrive -Name SBESYSROOT -ErrorAction SilentlyContinue)
            {
                Get-PSDrive -Name SBESYSROOT -ErrorAction SilentlyContinue | Remove-PSDrive -Force | Out-Null
            }
            if (Get-PSDrive -Name SBECACHE -ErrorAction SilentlyContinue)
            {
                Get-PSDrive -Name SBECACHE -ErrorAction SilentlyContinue | Remove-PSDrive -Force | Out-Null
            }
        }
    }
    if ($destDrv) { $destDrv | Remove-PSDrive -ErrorAction SilentlyContinue }
    if ($sysDrv) { $sysDrv | Remove-PSDrive -ErrorAction SilentlyContinue }
    return $true
}

function Get-SBEHealthCheckParams
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [CloudEngine.Configurations.EceInterfaceParameters]
        $ECEParameters,

        [String]
        $Tag,

        [Parameter(Mandatory=$true)]
        [string] $SBEMetadataPath
    )

    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
    Import-Module "$($sbeRoleNuget)\content\Helpers\SBESolutionExtensionHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
    $sbePartnerProps = $null
    if ((Get-Command Get-SBEPartnerProperties).Parameters.Keys -contains "SBEMetadataPath")
    {
        $sbePartnerProps = Get-SBEPartnerProperties -SBERoleConfig $ECEParameters.Roles["SBE"].PublicConfiguration -SBEMetadataPath $SBEMetadataPath
    }
    else
    {
        Log-Info -Message "Get-SBEPartnerProperties does not support SBEMetadataPath parameter, so calling without it." -Type Info
        $sbePartnerProps = Get-SBEPartnerProperties -SBERoleConfig $ECEParameters.Roles["SBE"].PublicConfiguration

    }
    $sbeCredList = $null
    if ((Get-Command Get-SBECredentialList).Parameters.Keys -contains "SBEMetadataPath")
    {
        $sbeCredList = Get-SBECredentialList -Parameters $ECEParameters -SBEMetadataPath $SBEMetadataPath
    }
    else
    {
        Log-Info -Message "Get-SBECredentialList does not support SBEMetadataPath parameter, so calling without it." -Type Info
        $sbeCredList = Get-SBECredentialList -Parameters $ECEParameters
    }
    $sbeHostData = Get-AllNodesData -BareMetalConfig $ECEParameters.Roles["BareMetal"].PublicConfiguration

    $params = @{
        CredentialList = $sbeCredList
        HostData = $sbeHostData
        PartnerProperties = $sbePartnerProps
        Tag = $Tag
    }
    return $params
}

function Get-ManifestMatchesModelandSKUResult
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [String]
        $SBEManifestFilePath,

        [Parameter(Mandatory=$true)]
        [Object]
        $EndpointContentsResult,

        [Parameter(Mandatory = $false)]
        [System.String]
        $ModelOverride = "",

        [Parameter(Mandatory = $false)]
        [System.String]
        $SKUOverride
    )

    $modelValue = $ModelOverride
    if ([System.String]::IsNullOrEmpty($ModelOverride)) {
        try {
            $modelValue = (Get-ItemPropertyValue -Path "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" -Name "SystemProductName").ToString()
        }
        catch {
            try {
                # Typically on need to do this on containerized build agents
                Trace-Execution  "Unable to determine model from registry - falling back to Win32_ComputerSystem"
                $modelValue = (Get-WmiObject -ComputerName localhost -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object Model).Model
            }
            catch {
                Trace-Execution  "Unable to determine model from Win32_ComputerSystem"
                $modelValue = "Unknown"
            }
        }
    }

    $skuValue = $SKUOverride
    if ($null -eq $SKUOverride) {
        try {
            $skuValue = (Get-ItemPropertyValue -Path "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" -Name "SystemSKU").ToString()
        }
        catch {
            try {
                Trace-Execution  "Unable to determine SKU from registry - falling back to Win32_ComputerSystem"
                $skuValue = (Get-WmiObject -ComputerName localhost -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object SystemSKUNumber).SystemSKUNumber
            }
            catch {
                Trace-Execution  "Unable to determine SKU from Win32_ComputerSystem"
            }
        }
    }

    try {
        $manifestXML = New-Object -TypeName System.Xml.XmlDocument
        $manifestXML.PreserveWhitespace = $false
        $xmlTextReader = New-Object -TypeName System.Xml.XmlTextReader -ArgumentList $SBEManifestFilePath
        $manifestXML.Load($xmlTextReader)
        $xmlTextReader.Dispose()

        # Get all of the supported models entries in the manifest
        $suppportedModelsElements = $manifestXML.SelectNodes("//ApplicableUpdate/UpdateInfo/SupportedModels")
        if ([System.String]::IsNullOrEmpty($suppportedModelsElements)) {
            throw "Unable to locate any SupportedModels elements in manifest at $SBEManifestFilePath"
        }

        # test that the model is supported
        $modelSupported = $false
        $skuSupported = $false
        $supportedModels = $applicableUpdate.UpdateInfo.SupportedModels
        $noSpacesModel = $modelValue -replace '[\W]', ''
        $supportedModelTextList = @()
        $totalSupportedModels = @{}
        foreach ($supportedModels in $suppportedModelsElements)
        {
            foreach ($supportedModel in $supportedModels.SupportedModel)
            {
                $supportedModelValue = $supportedModel.InnerText
                if ([System.String]::IsNullOrEmpty($supportedModelValue))
                {
                    $supportedModelValue = $supportedModel
                }
                $totalSupportedModels[$supportedModelValue] = $true
            }
        }
        $supportedModelTextList = $totalSupportedModels.Keys
        $supportedModelListAsString = $supportedModelTextList -join ", "
        foreach ($supportedModels in $suppportedModelsElements)
        {
            foreach ($supportedModel in $supportedModels.SupportedModel)
            {
                $supportedModelValue = $supportedModel.InnerText
                if ([System.String]::IsNullOrEmpty($supportedModelValue))
                {
                    $supportedModelValue = $supportedModel
                }
                if ($noSpacesModel -like "$supportedModelValue*")
                {
                    Trace-Execution "Model '$modelValue' is supported by SBE."
                    $modelSupported = $true
                    $supportedSKUs = $supportedModel.SupportedSKUs
                    $notSupportedSKUS = $supportedModel.NotSupportedSKUs
                    if ($null -eq $notSupportedSKUS -and $null -eq $supportedSKUs)
                    {
                        # no SKU restrictions
                        $skuSupported = $true
                    }
                    else
                    {
                        $supportedSKUList = $supportedSKUs -split ";"
                        $notSupportedSKUList = $notSupportedSKUS -split ";"
                        $noSpaceSKU = $skuValue -replace '[\W]', ''
                        foreach ($supportedSKU in $supportedSKUList)
                        {
                            if ([System.String]::IsNullOrWhiteSpace(($supportedSKU)))
                            {
                                continue
                            }
                            if ($noSpaceSKU -like "$supportedSKU*")
                            {
                                Trace-Execution "SKU '$skuValue' is supported by SBE."
                                $skuSupported = $true
                                break
                            }
                        }
                        foreach ($notSupportedSKU in $notSupportedSKUList)
                        {
                            if ([System.String]::IsNullOrWhiteSpace(($notSupportedSKU)))
                            {
                                continue
                            }
                            if ($noSpaceSKU -like "$notSupportedSKU*")
                            {
                                Trace-Execution "SKU '$skuValue' is not supported by SBE."
                                $skuSupported = $false
                                break
                            }
                        }
                    }
                }
                if ($modelSupported -and $skuSupported) {
                    break
                }
            }
        }
        if ($modelSupported -and $skuSupported)
        {
            Trace-Execution "Model '$modelValue' and SKU '$skuValue' are supported by SBE."
            $EndpointContentsResult.Status = 'SUCCESS'
            $EndpointContentsResult.Description = "The current SBE discovery manifest endpoint at $sbeEndpoint has matching entries for the server model '$modelValue' and SKU '$skuValue'."
        }
        else
        {
            $msg = "System model '$modelValue' is not supported by SBE. Supported models: $supportedModelListAsString"
            Trace-Execution $msg
            $EndpointContentsResult.Status = 'FAILURE'
            $EndpointContentsResult.Description = $msg
            $EndpointContentsResult.Remediation = "The current SBE discovery manifest endpoint at $sbeEndpoint does not currently have any matching entries for the server model '$modelValue' and SKU '$skuValue'.`nTo assure your Azure Local instance can receive updates, review your hardware vendor documentation to confirm the endpoint override $sbeEndpoint is appropriate for your model server.`nTo reset the endpoint to the default value please use: Set-OverrideUpdateConfiguration -ResetDefaultOemUpdateUri"
        }
    }
    catch {
        $msg = "Failed to parse SBE manifest XML at $SBEManifestFilePath. Error: $($PSItem.Exception.Message)"
        Trace-Execution $msg
        $EndpointContentsResult.Status = 'FAILURE'
        $EndpointContentsResult.Description = $msg
    }
    return $EndpointContentsResult
}

function Test-SBEPropertiesValid
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [CloudEngine.Configurations.EceInterfaceParameters]
        $ECEParameters,

        [Parameter(Mandatory=$false)]
        [System.String] $SBEMetadataPath
    )

    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
    Import-Module "$($sbeRoleNuget)\content\Helpers\SBESolutionExtensionHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
    if ((Get-Command Get-SBEPartnerProperties).Parameters.Keys -contains "SBEMetadataPath")
    {
        $sbePartnerProps = Get-SBEPartnerProperties -SBERoleConfig $ECEParameters.Roles["SBE"].PublicConfiguration -SBEMetadataPath $SBEMetadataPath
    }
    else
    {
        Log-Info -Message "Get-SBEPartnerProperties does not support SBEMetadataPath parameter, so calling without it." -Type Info
        $sbePartnerProps = Get-SBEPartnerProperties -SBERoleConfig $ECEParameters.Roles["SBE"].PublicConfiguration
    }

    Log-Info -Message "Found '$($sbePartnerProps.Count)' PartnerProperties." -Type Info
}

function Test-SBECredentialsValid
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [CloudEngine.Configurations.EceInterfaceParameters]
        $ECEParameters,

        [Parameter(Mandatory=$false)]
        [System.String] $SBEMetadataPath
    )

    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
    Import-Module "$($sbeRoleNuget)\content\Helpers\SBESolutionExtensionHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
    if ((Get-Command Get-SBECredentialList).Parameters.Keys -contains "SBEMetadataPath")
    {
        $sbeCredList = Get-SBECredentialList -Parameters $ECEParameters -SBEMetadataPath $SBEMetadataPath
    }
    else
    {
        Log-Info -Message "Get-SBECredentialList does not support SBEMetadataPath parameter, so calling without it." -Type Info
        $sbeCredList = Get-SBECredentialList -Parameters $ECEParameters
    }
}

function Test-SolutionExtensionModule
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $PackagePath,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    $solExtModule = $null
    Log-Info -Message ($locSbeTxt.SBEPackagePath -f $PackagePath) -Type Info

    if ($PSSession)
    {
        $computername = $PsSession.ComputerName
    }
    else
    {
        $computername = $env:ComputerName
    }

    # Validate the SolutionExtension module using a function from the SBE Role Helper module
    $sbValidate = {
        param(
                [String]
                [parameter(Mandatory=$true)]
                $PackagePath,

                [String]
                [parameter(Mandatory=$true)]
                $SbeRoleNuget
            )
        try
        {
            Import-Module "$SbeRoleNuget\content\Helpers\SBESolutionExtensionHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
            $solExtModulePath = Join-Path -Path $PackagePath -ChildPath "Configuration\SolutionExtension"
            $solExtModule = Initialize-SolutionExtensionModule -SolExtFilePath $solExtModulePath -RequireTag "HealthServiceIntegration" -AssertCertificate
            return $solExtModule
        }
        catch
        {
            Write-Output "An exception occurred while validating the SolutionExtension module: " + ($PSItem | Format-List * | Out-String).Trim()
        }
    }
    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
    $solExtModule = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sbValidate -ArgumentList @($PackagePath, $sbeRoleNuget)
    }
    else
    {
        Invoke-Command -ScriptBlock $sbValidate -ArgumentList @($PackagePath, $sbeRoleNuget)
    }

    if ($null -eq $solExtModule)
    {
        Log-Info -Message ($locSbeTxt.NoHeatlhChecks) -Type Info
        return $false
    }
    elseif ($solExtModule -match "An exception occurred")
    {
        throw $solExtModule
    }

    return $true
}

function Invoke-TestSBEContentIntegrity
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $SBEMetadataPath,

        [Parameter(Mandatory=$true)]
        [string]
        $SBEContentPath,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession
    )

    $sbIntegrity = {
        param(
            [String]
            [parameter(Mandatory=$true)]
            $SBEMetadataPath,

            [String]
            [parameter(Mandatory=$true)]
            $SBEContentPath,

            [String]
            [parameter(Mandatory=$true)]
            $SbeRoleNuget
        )

        try
        {
            if (-not(Get-Command -Name Test-SBEContentIntegrity -ErrorAction SilentlyContinue))
            {
                if (Test-Path -Path "$($SbeRoleNuget)\content\Helpers\SBEMetadataHelper.psm1" -PathType Leaf)
                {
                    Write-Verbose "Importing SBEMetadataHelper module from $SbeRoleNuget for content integrity test."
                    Import-Module "$($SbeRoleNuget)\content\Helpers\SBEMetadataHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
                }
                else
                {
                    Write-Verbose "Fallback to importing SBESolutionExtensionHelper module from $SbeRoleNuget for content integrity test."
                    Import-Module "$($SbeRoleNuget)\content\Helpers\SBESolutionExtensionHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
                }
            }
            $skipDir = @("IntegratedContent")
            Test-SBEContentIntegrity -SBEMetadataDirPath $SBEMetadataPath -SBEContentPath $SBEContentPath -IgnoreTopLevelFolder $skipDir
        }
        catch
        {
            throw $PSItem
        }
    }
    $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
    $result = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sbIntegrity -ArgumentList @($SBEMetadataPath, $SBEContentPath, $sbeRoleNuget)
    }
    else
    {
        Invoke-Command -ScriptBlock $sbIntegrity -ArgumentList @($SBEMetadataPath, $SBEContentPath, $sbeRoleNuget)
    }

    return $result
}

function Import-SolutionExtensionModule
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $PackagePath,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    # Import the SolutionExtension module
    $solExtModule = (Join-Path -Path $PackagePath -ChildPath "Configuration\SolutionExtension\SolutionExtension.psd1")
    Log-Info -Message ($locSbeTxt.ModuleToImport -f $solExtModule) -Type Info
    $sbImport = {
        param(
            [String]
            [parameter(Mandatory=$true)]
            $SolExtModule
        )
        try
        {
            Import-Module $SolExtModule -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
        }
        catch
        {
            Write-Output "An error occurred while importing the SolutionExtension module: " + ($PSItem | Format-List * | Out-String).Trim()
        }
    }
    $result = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sbImport -ArgumentList @($solExtModule)
    }
    else
    {
        Invoke-Command -ScriptBlock $sbImport -ArgumentList @($solExtModule)
    }

    if ($result -match "An exception occurred")
    {
        throw $solExtModule
    }

    return $true
}

function New-SBEHealthResultObject
{
    param (
        [Parameter(Mandatory=$true)]
        [string]$TargetName,

        [Parameter()]
        [string]$TestName,

        [Parameter()]
        [ValidateSet('CRITICAL','WARNING','INFORMATIONAL')]
        [string]$Severity = 'INFORMATIONAL',

        [Parameter()]
        [ValidateSet('SUCCESS', 'FAILURE', 'ERROR')]
        [string]$Status,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [string]$Detail,

        [Parameter()]
        [bool]$PopulateAdditionalData = $true
    )

    $name = 'AzStackHci_SBEHealth'
    $title = 'SBE'
    if (-not([string]::IsNullOrWhiteSpace($TestName)))
    {
        $name += "_$TestName"
        $title += (" " + $TestName.Replace("-", " "))
    }
    $name += "_$TargetName"
    if (-not($title.EndsWith(" Health Check")))
    {
        $title += " Health Check"
    }

    $params = @{
        Name               = $name
        Title              = $title
        DisplayName        = $title
        Severity           = $Severity
        Description        = $Description
        Tags               = @{}
        Remediation        = ''
        TargetResourceID   = $TargetName
        TargetResourceName = $TargetName
        TargetResourceType = 'SBEHealth'
        Timestamp          = "$([datetime]::UtcNow)"
        Status             = $Status
        AdditionalData     = @{
            Source    = $TargetName
            Resource  = 'SBEHealth'
            Detail    = $Detail
            Status    = $Status
            Timestamp = "$([datetime]::UtcNow)"
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    $resultObj = New-AzStackHciResultObject @params
    return $resultObj
}

function Get-ResultObject
{
    $resultObject = @{
        "Name" = ""
        "DisplayName" = ""
        "Title"= ""
        "Description" = ""
        "Status" = ""
        "Severity" = ""
        "Timestamp" = ""
        "TargetResourceID" = ""
        "TargetResourceName" = ""
        "TargetResourceType" = ""
        "Tags" = @{}
        "AdditionalData" = @{}
        "HealthCheckSource" = ""
        "Remediation" = ""
    }
    return $resultObject
}

function Assert-ResponseSchemaValid
{
    [CmdletBinding()]
    param (
        [PSObject[]]$ResultObject
    )

    $expectedSchema = Get-ResultObject
    foreach ($item in $ResultObject)
    {
        # Assert Name or Title must contain information
        if ([string]::IsNullOrWhiteSpace($item.Name) -and [string]::IsNullOrWhiteSpace($item.Title))
        {
            $msg = "Both Name and Title properties of this result object are empty"
            Log-Info -Message $msg -Type Error
            $item.AdditionalData.NameTitleEmpty = $msg
            $item.Severity = 'CRITICAL'
            $item.Status = "Error"
        }
        elseif ([string]::IsNullOrWhiteSpace($item.Name))
        {
            $item.Name = $item.Title
        }
        elseif ([string]::IsNullOrWhiteSpace($item.Title))
        {
            $item.Title = $item.Name
        }

        # Assert response contains expected schema properties
        foreach ($expectedKey in $expectedSchema.Keys)
        {
            if (-not($item.ContainsKey($expectedKey)))
            {
                # TODO : Temporary special case to add DisplayName if missing due to this being added after partner communication
                if ($key -eq "DisplayName")
                {
                    $item.DisplayName = $item.Title
                }
                else
                {
                    Log-Info -Message "Expected result property '$($expectedKey)' was not found" -Type Warning
                    $item.$expectedKey = ""
                    # TODO : In the future, we should decide how to better handle these cases of missing properties
                }
            }
        }

        # Assert Status values
        if ($item.Status -notin @("Success", "Failure", "Error"))
        {
            $msg = "Unexpected Status: '$($item.Status)'"
            Log-Info -Message $msg
            $item.AdditionalData.StatusDiscrepancy = $msg
            $item.Status = "Error"
        }

        # Assert Severity values
        if ($item.Severity -notin @('CRITICAL', 'WARNING', 'INFORMATIONAL'))
        {
            $msg = "Unexpected Severity: '$($item.Severity)'"
            $item.AdditionalData.SeverityDiscrepancy = $msg
            if ($item.Status -eq "Success")
            {
                $item.Severity = 'WARNING'
                Log-Info -Message $msg -Type Warning
            }
            else
            {
                $item.Severity = 'CRITICAL'
                Log-Info -Message $msg -Type Error
            }
        }

        # Assert Timestamp is valid
        if (-not [string]::IsNullOrWhiteSpace($item.Timestamp))
        {
            try
            {
                $null = [DateTime]$item.Timestamp
            }
            catch
            {
                Log-Info -Message "Invalid Timestamp: '$($item.Timestamp)'" -Type Warning
                if (-not [string]::IsNullOrWhiteSpace($item.AdditionalData.Timestamp))
                {
                    try
                    {
                        $null = [DateTime]$item.AdditionalData.Timestamp
                        # AdditionalData.Timestamp is valid, so use it
                        $item.Timestamp = $item.AdditionalData.Timestamp
                    }
                    catch
                    {
                        # Use current time
                        $item.Timestamp = "$([datetime]::UtcNow)"
                    }
                }
                else
                {
                    # Use current time
                    $item.Timestamp = "$([datetime]::UtcNow)"
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($item.AdditionalData.Timestamp))
        {
            try
            {
                $null = [DateTime]$item.AdditionalData.Timestamp
            }
            catch
            {
                Log-Info -Message "Invalid Timestamp: '$($item.AdditionalData.Timestamp)'" -Type Warning
                # Timestamp must be valid now, so use it
                $item.AdditionalData.Timestamp = $item.Timestamp
            }
        }
    }

    return $ResultObject
}

function Test-SBEEndpointConnectivity
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $SbeEndpointUri,

        [Parameter(Mandatory=$true)]
        [PSCustomObject]
        $EndpointAccessResult,

        [Parameter(Mandatory=$true)]
        [string]
        $ManifestFilePath
    )

    if ([System.String]::IsNullOrWhiteSpace($SbeEndpointUri))
    {
        Trace-Execution "SBE manifest endpoint not reported by Get-SolutionDiscoveryDiagnosticInfo."
        $EndpointAccessResult.Status = 'FAILURE'
        # don't want to block updates if there is a bug with Get-SolutionDiscoveryDiagnosticInfo reporting the endpoint
        $EndpointAccessResult.Severity = 'INFORMATIONAL'
        $EndpointAccessResult.Description = "SBE manifest endpoint not reported by Get-SolutionDiscoveryDiagnosticInfo."
        $EndpointAccessResult.Remediation = "Check the Get-SolutionDiscoveryDiagnosticInfo output for the SBE manifest endpoint. If it is missing, check the Solution Discovery service configuration."
    }
    else
    {
        $caughtThrow = $false
        try
        {
            Trace-Execution "Checking connectivity to SBE manifest endpoint: $SbeEndpointUri"
            Trace-Execution "Downloading SBE manifest to temporary file: $ManifestFilePath"
            # Need to use try/catch.  Apparently Invoke-WebRequest doesn't really support SilentlyContinue
            $manifestResponse = Invoke-WebRequest -Uri $SbeEndpointUri -UseBasicParsing -ErrorAction SilentlyContinue -OutFile $ManifestFilePath -TimeoutSec 15 -PassThru
            Trace-Execution "SBE manifest response: $($manifestResponse.StatusCode)"
        }
        catch
        {
            $msg = "Failed to reach SBE manifest endpoint: $SbeEndpointUri. Error: $($PSItem.Exception.Message)"
            Trace-Execution $msg
            $EndpointAccessResult.Status = 'FAILURE'
            $EndpointAccessResult.Description = $msg
            $caughtThrow = $true
        }
        if ($null -eq $manifestResponse -and $false -eq $caughtThrow)
        {
            # no response object - should never get here as only way to have null is for an exception to be thrown now that we use -PassThru
            $msg = "Failed to reach SBE manifest endpoint: $SbeEndpointUri. No response received."
            Trace-Execution $msg
            $EndpointAccessResult.Status = 'FAILURE'
            $EndpointAccessResult.Description = $msg
        }
        elseif ($manifestResponse.StatusCode -ne 200)
        {
            $msg = "Failed to reach SBE manifest endpoint: $SbeEndpointUri. Response code: $($manifestResponse.StatusCode)"
            Trace-Execution $msg
            $EndpointAccessResult.Status = 'FAILURE'
            $EndpointAccessResult.Description = $msg
        }

        if ($EndpointAccessResult.Status -eq 'FAILURE')
        {
            $EndpointAccessResult.Remediation = "Check firewall rules to ensure the SBE manifest endpoint $SbeEndpointUri is reachable."
            if ($SbeEndpointUri -like "*aka.ms*")
            {
                $EndpointAccessResult.Remediation += " NOTE: Because aka.ms redirects, you will need to allow HTTPS(443) to aka.ms and to the target of $SbeEndpointUri. To determine the redirection target, browse to $SbeEndpointUri and note the URL that it redirects to in your browser address bar."
            }
        }
    }

    return $EndpointAccessResult
}
function Invoke-SBEHealthCheckWithPrerequisites {
    <#
    .SYNOPSIS
    Executes SBE health check with required prerequisite steps (integrity check and module import).

    .DESCRIPTION
    This function performs the following steps in sequence:
    1. Verifies SBE content integrity (if enabled)
    2. Imports the SolutionExtension module
    3. Executes the specified health check function

    This function is designed to run within a remote PowerShell job for parallel execution.

    .EXAMPLE
    Invoke-SBEHealthCheckWithPrerequisites -FunctionName 'Get-SBEHealthCheckResultOnNode' -FunctionParams @{Tag='Deployment'} -SBEWorkingDir 'C:\CloudContent\...' -SBEMetadataPath 'C:\CloudContent\...' -RunFrom 'Local' -SkipIntegrityTest $false

    .PARAMETER FunctionName
    The name of the SBE health check function to execute.

    .PARAMETER FunctionParams
    Hashtable of parameters to pass to the health check function.

    .PARAMETER SBEWorkingDir
    Path to the SBE working directory containing the SolutionExtension module.

    .PARAMETER SBEMetadataPath
    Path to the SBE metadata directory used for integrity verification.

    .PARAMETER RunFrom
    Specifies where the check is running from ('Local' or 'CSV').

    .PARAMETER SkipIntegrityTest
    If true, skips the SBE content integrity verification.

    .PARAMETER SbeRoleHelpersPath
    Optional pre-resolved path to the $sbeRoleNuget\content\Helpers directory. When provided, avoids
    calling Get-ASArtifactPathLite on each node, which eliminates the NuGet provider bootstrap cost.
    If not provided, falls back to resolving the path via Get-ASArtifactPathLite.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$FunctionName,

        [Parameter(Mandatory=$true)]
        [hashtable]$FunctionParams,

        [Parameter(Mandatory=$true)]
        [string]$SBEWorkingDir,

        [Parameter(Mandatory=$true)]
        [string]$SBEMetadataPath,

        [Parameter(Mandatory=$true)]
        [string]$RunFrom,

        [Parameter(Mandatory=$false)]
        [bool]$SkipIntegrityTest = $false,

        [Parameter(Mandatory=$false)]
        [string]$SbeRoleHelpersPath = $null
    )

    try
    {
        # Verify SBE content integrity (if enabled)
        if ("Local" -eq $RunFrom -and -not $SkipIntegrityTest)
        {
            # Use pre-resolved helpers path if provided to avoid per-node NuGet provider bootstrap cost.
            # Fall back to Get-ASArtifactPathLite if no path was supplied.
            if (-not [string]::IsNullOrEmpty($SbeRoleHelpersPath))
            {
                $sbeHelpersDir = $SbeRoleHelpersPath
            }
            else
            {
                $sbeRoleNuget = Get-ASArtifactPathLite -NugetName "Microsoft.AzureStack.Role.SBE"
                $sbeHelpersDir = "$sbeRoleNuget\content\Helpers"
            }

            Import-Module "$sbeHelpersDir\SBESolutionExtensionHelper.psm1" -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null
            $skipDir = @("IntegratedContent")
            $integrityResult = Test-SBEContentIntegrity -SBEMetadataDirPath $SBEMetadataPath -SBEContentPath $SBEWorkingDir -IgnoreTopLevelFolder $skipDir

            if ($false -eq $integrityResult)
            {
                throw "SBE content integrity check found irregularities in the files at '$SBEWorkingDir' on '$env:COMPUTERNAME'"
            }
        }

        # Import the SolutionExtension module
        $solExtModule = Join-Path -Path $SBEWorkingDir -ChildPath "Configuration\SolutionExtension\SolutionExtension.psd1"
        Import-Module $solExtModule -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking -Global | Out-Null

        # Execute the health check function
        & $FunctionName @FunctionParams
    }
    catch
    {
        # Return error information that can be captured by the parent
        throw $PSItem
    }
}

function Wait-SBECopyNodeBatch
{
    <#
    .SYNOPSIS
    Processes results from a batch of parallel SBE content copy jobs.

    .DESCRIPTION
    Waits for a batch of PowerShell jobs that copy SBE content to nodes, processes their results,
    and returns a structured output object. On first failure, all remaining jobs are cleaned up
    (by design) to fail fast - their completed status is not captured.

    .PARAMETER Jobs
    Array of PowerShell jobs started by Start-Job for copying SBE content to nodes.

    .PARAMETER FunctionName
    The test name used when creating result objects for failures.

    .OUTPUTS
    Hashtable with keys:
    - Results              : Array of result objects (populated on failure)
    - FirewallRulesChanged : Hashtable of node name to firewall rules changed by successful jobs
    - HasError             : Boolean, true if any job failed
    - ErrorMessage         : The error message from the first failure, if HasError is true
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]
        $Jobs,

        [Parameter(Mandatory = $true)]
        [string]
        $FunctionName
    )

    $output = @{
        Results              = @()
        FirewallRulesChanged = @{}
        HasError             = $false
        ErrorMessage         = ''
    }

    $Jobs | Wait-Job | Out-Null

    foreach ($job in $Jobs)
    {
        $jobResult = Receive-Job -Job $job -ErrorAction SilentlyContinue
        $nodePrefix = if ($jobResult.ComputerName) { "[$($jobResult.ComputerName)]" } else { "[$($job.Location)]" }

        if ($null -ne $jobResult)
        {
            foreach ($msg in $jobResult.Messages)
            {
                Log-Info "$nodePrefix $msg"
            }

            if ($jobResult.Success)
            {
                Log-Info "  Successfully copied SBE content to '$($jobResult.ComputerName)'"

                if ($jobResult.FirewallRulesChanged.Count -gt 0)
                {
                    foreach ($node in $jobResult.FirewallRulesChanged.Keys)
                    {
                        $output.FirewallRulesChanged[$node] = $jobResult.FirewallRulesChanged[$node]
                    }
                }
            }
            else
            {
                $errorMsg = $jobResult.Error
                if ([string]::IsNullOrEmpty($errorMsg))
                {
                    $errorMsg = "Unknown error during copy operation"
                }

                Log-Info -Message "  An unhandled error occurred during 'Copy-SBEContentLocalToNode' to '$($jobResult.ComputerName)'" -Type Error -ConsoleOut
                Log-Info -Message ("  The exception message was: $errorMsg") -Type Error -ConsoleOut

                $exceptionResult = New-SBEHealthResultObject -TestName $FunctionName -TargetName $jobResult.ComputerName -Status 'FAILURE' -Severity 'CRITICAL' -Description "Copy-SBEContentLocalToNode to '$($jobResult.ComputerName)'"
                $exceptionResult.AdditionalData.Detail = $errorMsg
                $output.Results += $exceptionResult

                # By design: on first failure, remove ALL jobs (including completed but unprocessed)
                # and return immediately. Remaining completed jobs' results are intentionally discarded.
                $Jobs | Remove-Job -Force -ErrorAction SilentlyContinue

                $output.HasError = $true
                $output.ErrorMessage = $errorMsg
                return $output
            }
        }
        else
        {
            Log-Info -Message "  $nodePrefix No result received from job for node (job may have failed to start or return data)" -Type Warning -ConsoleOut
        }
    }

    $Jobs | Remove-Job -Force -ErrorAction SilentlyContinue

    return $output
}

Export-ModuleMember -Function Test-*
Export-ModuleMember -Function New-SBEHealthResultObject
Export-ModuleMember -Function Get-ASArtifactPathLite
Export-ModuleMember -Function Get-ManifestMatchesModelandSKUResult
Export-ModuleMember -Function Get-SBEHealthCheckParams
Export-ModuleMember -Function Copy-SBEContentLocalToNode
Export-ModuleMember -Function Import-SolutionExtensionModule
Export-ModuleMember -Function Assert-ResponseSchemaValid
Export-ModuleMember -Function Invoke-TestSBEContentIntegrity
Export-ModuleMember -Function Invoke-SBEHealthCheckWithPrerequisites
Export-ModuleMember -Function Wait-SBECopyNodeBatch
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDsiLZysG79OVht
# uZqmZA02OpNB2meRQpsM3BLAvNH2rqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIKUwRhFY73z4D/LcwTOi0ecFGZN81TZHAIrzRcj1IsyWMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAYP5flA7Q55hMGW4PtFRA
# qxeS5AcV3vsqAfGJovGQ/8aG6fCOuYRLBdM/FlTzy2DiC7+aH/y4R0dEsNIaeiJw
# rbBTE9y0W7jj2GA68ZLW/lOKE/sMVi5gxyEsqB3Jm8apWfDRdsz7muQd9aI4wXjC
# 9OO4RXUCzAHc1YooZD9u1CqHGlX51889J3bSvaA4B5B+YntvV1MqMtdVLSm9ws7x
# NVpPlzjE6qrzH6/w4uj7E4ojxcuBViciGeSCa5VR+Na1wvo3f3lcAAbS465X8jIK
# XvkMbWIY3/IZPch7HbXdlfoiXn+NUkS0zMxcgIXFlLqJ7hdU7dZ9fXcMwCEFhx79
# EqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDu9huqwAk747X53RtV
# +9qUo72kPenNl1H9C2ZORcyLIQIGaeugEigEGBMyMDI2MDUwMzE0MzExMC4xODVa
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
# CRABBDAvBgkqhkiG9w0BCQQxIgQgx3nN7dbkLCUV3AAG6KRPHxc54ClIOOjR+Hk6
# CCBEoj0wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDD1SHufsjzY59S1iHU
# QY9hnsKSrJPg5a9Mc4YnGmPHxjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEKvN5BYY7zmwAAEAAAIQMCIEIIT70NF/aOTBRnL/Ym5d
# CJI5L5fhiGpS2xzTAo0XyaBPMA0GCSqGSIb3DQEBCwUABIICADveX8AcCUYV2tya
# QTQLFG0UZxCft4NKBBik07su+TTiegTTeNgkIJWQ63eOgttruUO75jmZfhsoN1LE
# Dly6oGBtqgTovoetGj60VsL0gKuSMK7IPqlYiM8Hz2nX5hpXotp8xJBKZ0Y+XZxc
# 5A/tnFeM3l1iaUNUY5iYLuu0p5UQLReer1NcrpvRtOj1ntANG0G44Yxz9Q4I/rsU
# CpZL92DFS5aiQZdcZT8PPdP++/p8fj/LHctE5SncbQZWcfSY5DQ38+k7bwol/ZfN
# KAEMLmQCWrnOtB06BwKyIK2eQo74KzxC1yKSEvm16M1v59M8oOr5VYi1cbb8PNpf
# ziOQNIlVXbmYxfN6IZUJOK9XtNCaabkIA1HMY7z3sP+Ql/Mwo1Uh9KdASq6FGA//
# kdSkCN35+doKAvRputekOa8cv/RCib+mfpz7MbkivGSQs78+tc33ZPcwsmElH8M0
# +I7MHRYswq2X/YvoacpIgmJG6dALGLpajhYnPxcSPuJ41zOeCICPK7Ugmp7CtpM8
# B9QvlmbvcQeBx9MshZ5IvGa+iMw+rw8ezaiqlGTmp53JrA2cLdVnE2FqLuJouJf9
# Dfrx+LYhIsdfLU2N2DWozyhMi8eOuHaF2T7OLM4NRaB9MMIAJyhqWQ7DlhJWYPYT
# DRE3L1rBcKJMhjSxf+Dsc0BtPQTD
# SIG # End signature block
