Import-LocalizedData -BindingVariable lswTxt -FileName AzStackHci.OSImageRecipe.Strings.psd1

$global:recipeFilePath = "$env:windir/System32/AzureLocalImage/OSImageRecipe.xml"

$renderXMLvarScriptBloc = {
    <#
    .SYNOPSIS
        A script block that can be passed to another script block that happens
        to be running remotely.  This is a cascaded script blocks concept.

    .DESCRIPTION
        The point of this script block is to validate that the Azure Local
        version is one that should have a local OS image recipe
        file on it.  If it is and that file exists return a data structure
        that represents that XML file.
    #>
    Param($recipeFilePath)

    function isOfficialBuild {
        <#
        Return $true if the registry tells us this is an official build.
        Return $false if the registry tells us this is NOT an official build.
        Return $null if the we fail to find OFFICIAL_BUILD in the ComposedBuildInfo
        registry location.
        The shouldHaveRecipeFile() function should be called before isOfficialBuild().
        This is assure that we at least expect the hosts is from a composed build
        and that we should expect the registry to contain this information.
        #>
        try {
            $rawIsOfficial = (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters -ErrorAction SilentlyContinue).OFFICIAL_BUILD
        }
        catch {
            $rawIsOfficial = $null
        }
        if ($null -eq $rawIsOfficial) {
            return $null
        } elseif ([int]$rawIsOfficial) {
            return $true
        } else {
            return $false
        }
    }

    function validateRecipeFileExistsAndIsNotCorrupt {
        <#
        Return the XML data structure if it renders correctly from the file.
        Return $false if the file simply does not exists OR
        if the file does not render a valid data structure and
        therefore considered corrupt.
        #>
        if (Test-Path -Path $recipeFilePath) {
            try {
                [xml]$recipeObj = Get-Content $recipeFilePath
                return $recipeObj
            }
            catch {
                # return False because although the XML file existed it appears to be corrupt
                return $false
            }
        } else {
            # return False because the xml should exist on this host, but it does not
            return $false
        }
    }

    function validateRecipeIsSigned {
        <#
        Validate that the signature in the recipe matches that particular file
        and that the file contents have not been manually manipulated.
        Return $true if the onbox xml recipe file is correctly signed.
        Return $false if the onbox xml recipe file is NOT correctly signed.
        isOfficialBuild() should be run before this function because
        only official builds contain signed recipe files and checking
        to see if it is an official build first guards the logic found
        in this func.
        #>
        Param($recipeFilePath)
        $recipeFilePath = $recipeFilePath -replace '\\|/', '='
        [string]$recipeFilePath = [string]$recipeFilePath -replace '=', '\\'
        $contentPath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\EdgeArcBootstrapSetup\' -ErrorAction SilentlyContinue).ContentBinariesPath
        if (([System.String]::IsNullOrEmpty($contentPath)) -or (!(Test-Path $contentPath)))
        {
            $bootstrapDirectory = Get-ChildItem -Path "C:/windows/system32/Bootstrap" | Where-Object { $_.Name -like "*content*" } | Sort-Object -Property Name -Descending
            if ($null -ne $bootstrapDirectory)
            {
                $contentPath = $bootstrapDirectory[0].FullName
            }
        }
        if ([System.String]::IsNullOrEmpty($contentPath))
        {
            return $false
        }
        $validatorDll = "$contentPath/Microsoft.AzureStack.UpdateService.BootstrapValidation"
        $validatorDll += "/lib/net472/Microsoft.AzureStack.Services.Update.ResourceProvider.UpdateService.Security.dll"
        Import-Module $validatorDll
        $validatorInstance = [Microsoft.AzureStack.Services.Update.ResourceProvider.UpdateService.Security.SignedXmlValidator]::new()
        if (Test-Path -Path $recipeFilePath) {
            $isSigned = $validatorInstance.ValidateAsync("$recipeFilePath").GetAwaiter().GetResult()
            if ($isSigned) {
                return $true
            }
            return $false
        }
        return $false
    }

    function getOSBuildVersion {
        <#
        .SYNOPSIS
            Return a version object that represents the live installed version.
            (HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters).COMPOSED_BUILD_ID
            NOTE: this func is scoped within a scriptBlock called by a scriptBlock
        .DESCRIPTION
            Discover the 'COMPOSED_BUILD_ID' version string.
            Convert the string into a [version] module object.
            For example if the string is '10.2502.0.6250' the object looks like this:
            Major  Minor  Build  Revision
            -----  -----  -----  --------
            10     2502   0      6205
        #>
    $installedVersionString = $null
    try {
        $installedVersionString = (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters -ErrorAction SilentlyContinue).COMPOSED_BUILD_ID
        if (-not $installedVersionString) {
            throw 'COMPOSED_BUILD_ID is not set'
        }
        $installedVersionString = $installedVersionString.split('.')[0..3] -join'.' # make sure no more than 4 chunks separated by periods because [Version]::Parse() does not like it
        $installedVersionString = [regex]::Replace($installedVersionString, '-\d*', '') # remove any hyphenated subversion string because [Version]::Parse() does not like it
        #assume subversion are backward and forward compatible with versions of similar major version
    }
    catch {
        # if the registry entry does not exist then this HCI instance can be considered a
        # nonComposed one and thus just set the version to 0
        # this will cause the downstream logic to skip the tests instead of fail them and
        # thus maintaining the integrity of the EnvironmentChecker for composed HCI
        # and the older nonComposed HCI.
        $installedVersionString = '0.0.0.0'
    }
    try {
        $installedVersionObj = [Version]::Parse($installedVersionString)
    }
    catch {
        $installedVersionString = '0.0.0.0'
        $installedVersionObj = [Version]::Parse($installedVersionString)
    }
        return $installedVersionObj
    }

    function shouldHaveRecipeFile {
        <#
        .SYNOPSIS
            Return True if the image running on the local host is an HCI image
            from an era that contained an embedded recipe XML file.
            NOTE: this func is scoped within a scriptBlock called by a scriptBlock
        .DESCRIPTION
            Check that the 'COMPOSED_BUILD_ID'
            version running on the local live host is >= 10.2502.0.3017.
            This minimum version is just a line in the sand when composed images
            started to contain the recipe xml file.
            Return True if the installed version is >= the minimum version.
            If True is returned the live host *should* have a valid recipe file.
            If False is returned then this live host should *not* have a recipe file.
        #>
        $minVersionString = '10.2502.0.0'
        $minVersionObj = [Version]::Parse($minVersionString)
        $installedVersionObj = getOSBuildVersion
        if ($installedVersionObj -ge $minVersionObj) {
            return $true
        }
        return $false
    }

    # The renderXMLvarScriptBloc can return 3 explicit things.
    # Each of these indicate a different outcome.
    # $recipeObj  == This image should contain a recipe file
    #                and the returned value is a data structure
    #                representing the XML content in the recipe file.
    # $False      == This image should contain a recipe file, but does NOT!
    # $Null       == This image should NOT contain a recipe file, thus it
    #                is OK to skip testing against it.
    # This Obj vs False vs Null response takes into account if the recipe file is signed
    # or not, but only if this live hosts was born from the official composed
    # image pipeline.  If it came from the buddy pipeline do not take
    # into account if the recipe is signed or not.
    # Return False if this is an Official build and it is NOT signed.
    # This False response will correctly induce recipe validation test failures.
    if ($(shouldHaveRecipeFile)) {
        $isOfficial = $(isOfficialBuild)
        if ($isOfficial -or ($null -eq $isOfficial)) {
            if (-not $(validateRecipeIsSigned $recipeFilePath)) {
                # return False because this is an official build and the recipe file is not signed
                return $false
            }
        }
        return $(validateRecipeFileExistsAndIsNotCorrupt)
    } else {
        return $null
    }
} # end renderXMLvarScriptBloc

function TestResult {
    <#
    .SYNOPSIS
        Build up a params data structure to pass the
        New-AzStackHciResultObject function.
    .DESCRIPTION
        The New-AzStackHciResultObject function get information about the
        result of a test into the correct result files (log, json, etc.)
    #>
    Param([Parameter(Mandatory=$true,Position=0)] [array]$responses,
          [Parameter(Mandatory=$true,Position=1)] [string]$Name,
          [Parameter(Mandatory=$true,Position=2)] [string]$Title,
          [Parameter(Mandatory=$true,Position=3)] [string]$DisplayName,
          [Parameter(Mandatory=$true,Position=4)] [string]$Severity,
          [Parameter(Mandatory=$true,Position=5)] [string]$Description,
          [Parameter(Mandatory=$false,Position=6)] [string]$Remediation = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-install-os',
          [Parameter(Mandatory=$false,Position=7)] [string]$TargetResourceType = 'OSImageRecipe',
          [Parameter(Mandatory=$false,Position=8)] [string]$Resource = 'OS Image Recipe')
    $instanceResults = @()
    foreach ($response in $responses) {
        $detailString = $($response.details) -join ';  '
        foreach ($msg in $($response.logLines)) {
            $msgArray = $msg.split('|')
            Log-Info $msgArray[0] -Type $msgArray[1]
        }
        try {
            $Status = 'SUCCESS'
            if ($($response.rc)) {
                $Status = 'FAILURE'
            }
            $params = @{
                Name               = $Name
                Title              = $Title
                DisplayName        = $DisplayName
                Severity           = $Severity
                Description        = $Description
                Tags               = @{}
                Remediation        = $Remediation
                TargetResourceID   = $($response.computername)
                TargetResourceName = $($response.computername)
                TargetResourceType = $TargetResourceType
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                HealthCheckSource  = $ENV:EnvChkrId
                AdditionalData     = @{Source    = $($response.computername)
                                       Resource  = $Resource
                                       Detail    = $detailString
                                       Status    = $status
                                       TimeStamp = [datetime]::UtcNow}}
            $instanceResults += New-AzStackHciResultObject @params
        }
        catch {
            throw $_
        }
    }
    return $instanceResults
}

function Test-InstalledPackages {
    <#
    .SYNOPSIS
        Validate that all the packages installed, including the bootStrap package,
        have the same version the OS image recipe requires.
    .DESCRIPTION
        Loop around the package defined in OSImageRecipe.xml
        and validate using 'Get-InstalledModule' that the version installed matches the version
        defined in the recipe XML file.
        This function used to use Get-Package to check to see if 'packages' as defined in
        the recipe were installed on a system with the correct version.  Get-Package
        was used because it is a more generic cmdline tool than Get-InstalledModule.
        Get-Package would allow the user to see PowerShell modules install and other
        types of packages.  As of 01/09/2025 the recipe does not contain any non-PowerShell
        packages other than The bootStrap one.  BootStrap is already special cased in this
        test.  Once there are non-PowerShell packages in the recipe we need to define what
        kind of package.
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession)
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $packageObj = New-Object System.Collections.Generic.List[System.Object]
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            if ($($XMLstructure.SelectNodes('/BuildInfo/Packages/Package'))) {
                $packageObj = $XMLstructure.BuildInfo.Packages.Package
            }
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = $resultSeverity
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        # the only thing we skip for now is the EC itself since how could we be running this code
        # unless EC is installed.  We will run the ver validation that it is the right EC ver
        # during build time, but in the field just skip validating that EC is installed for now
        # this was mainly done because otherwise the CI runs that use ALLNUGETSHARES as a way to
        # install a specific EC version will fail every time
        $packagesToSkip = @('AzStackHci.EnvironmentChecker', 'Microsoft.AzureStack.AzureConnectedMachineAgent')
        $packageTypesToValidate = @('BootstrapService', 'PowerShellModule')

        foreach ($pkg in $packageObj) {
            $name = $pkg.Name
            $ver = $pkg.Version
            # Only validate packages with PackageType 'BootstrapService' or 'PowerShellModule'
            if ($null -ne $pkg.PackageType) # Do not fail if this property is not found
            {
                if (-not ($packageTypesToValidate -contains $pkg.PackageType))
                {
                    continue
                }
            }
            try {
                $ver = $ver.split('.')[0..3] -join'.' # make sure no more than 4 chunks separated by periods because [Version]::Parse() does not like it
                $ver = [regex]::Replace($ver, '-\d*', '') # remove any hyphenated subversion string because [Version]::Parse() does not like it
                #assume subversion are backward and forward compatible with versions of similar major version
            }
            catch {
                $ver = 'N/A'
            }
            if ($packagesToSkip -contains $name) {
                continue
            }
            if ($name -notlike '*Bootstrap.Setup*') {
                try {
                    $liveHostVer = ([string]((Get-InstalledModule -Name ${name} -ErrorAction SilentlyContinue).Version)).trim()
                    $liveHostVer = $liveHostver.split('.')[0..3] -join'.' # make sure no more than 4 chunks separated by periods because [Version]::Parse() does not like it
                    $liveHostver = [regex]::Replace($liveHostver, '-\d*', '') # remove any hyphenated subversion string because [Version]::Parse() does not like it
                }
                catch {
                    $liveHostVer = 'N/A'
                }
                if (-not $liveHostVer) {
                    $liveHostVer = 'N/A'
                }
                try {
                    $liveHostVerObj = [Version]::Parse($liveHostVer)
                }
                catch {
                    $liveHostVerObj = $null
                }
                try {
                    $verObj = [Version]::Parse($ver)
                }
                catch {
                    $verObj = $null
                }
                if ($liveHostVer -eq 'N/A') {
                    $rc += 1
                    $msg = $lswTxt.InstalledPackagesNotInstalled -f $name, $localHost
                    $logLines.Add("${msg}|${resultSeverity}")
                } elseif (-not $liveHostVerObj) {
                    $rc += 1
                    $msg = $lswTxt.InstalledPackagesLiveHostVerConversionFail -f $name, $localHost
                    $logLines.Add("${msg}|${resultSeverity}")
                } elseif (-not $verObj) {
                    $rc += 1
                    $msg = $lswTxt.InstalledPackagesRecipeVerConversionFail -f $name, $localHost
                    $logLines.Add("${msg}|${resultSeverity}")
                } elseif ($liveHostVerObj -lt $verObj) {
                    $rc += 1
                    $msg = $lswTxt.InstalledPackagesFail -f $name, $localHost, $liveHostVer, $ver
                    $logLines.Add("${msg}|${resultSeverity}")
                } else { # this assumes that ($liveHostVerObj -ge $verObj)
                    $msg = $lswTxt.InstalledPackagesPass -f $name, $localHost, $liveHostVer, $ver
                    $logLines.Add("${msg}|SUCCESS")
                }
                $detailList.Add($msg)
            } else {
                # checking both if the 'InstallCompleted' AND the version string exist
                # this is done because in the past I have seen bugs that prevented the bootstrap package from
                # successfully installing, but the version string was there.
                # It is best to validate that both bits of information exists and not just the version string!
                $outString = Get-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\EdgeArcBootstrapSetup\' -ErrorAction SilentlyContinue |Out-String
                if (-not [regex]::match($outString, 'InstallCompleted\s+:\s+1').Success) {
                    $rc += 1
                    $msg = $lswTxt.InstalledPackagesBootstrapInstalledFail -f $name, $localHost
                    $logLines.Add("${msg}|${resultSeverity}")
                } else {
                    $msg = $lswTxt.InstalledPackagesBootstrapInstalledPass -f $name, $localHost
                    $logLines.Add("${msg}|SUCCESS")
                }
                $detailList.Add($msg)
                if (-not [regex]::match($outString, $ver).Success) {
                    $rc += 1
                    $msg = $lswTxt.InstalledPackagesBootstrapVersionFail -f $name, $localHost, $ver
                    $logLines.Add("${msg}|${resultSeverity}")
                } else {
                    $msg = $lswTxt.InstalledPackagesBootstrapVersionPass -f $name, $localHost, $ver
                    $logLines.Add("${msg}|SUCCESS")
                }
                $detailList.Add($msg)
            }
        }
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_Package_Version"
               Title       = "Installed Packages match recipe."
               DisplayName = "Installed Packages match recipe."
               Severity    = $resultSeverity
               Description = "Validating that the packages installed on the host are the same versions defined in the OS image recipe."}
    return (TestResult @splat)
}

function Test-InstalledAdditionalFiles {
    <#
    .SYNOPSIS
        Validate that all the 'additional files' defined in the OS image recipe
        match those installed on the system.
    .DESCRIPTION
        Loop around the additionFiles defined in OSImageRecipe.xml
        and validate they exit on the system using '[System.IO.File]::Exists()'.
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $fileList = New-Object System.Collections.Generic.List[System.Object]
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            if ($($XMLstructure.SelectNodes('/BuildInfo/AdditionalFiles/File/DestinationPath'))) {
                $fileList = $XMLstructure.BuildInfo.AdditionalFiles.File.DestinationPath
            }
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = ${resultSeverity}
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        $fileList |foreach-object {
            $localFilePath = $_
            $filePath = "${localFilePath}"
            #$logLines.Add("Validate that additional file [${filePath}] is installed on host.|INFO")
            if (-not [System.IO.File]::Exists(${filePath})) {
                $rc += 1
                $msg = $lswTxt.InstalledFilesFail -f $filePath, $localHost
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.InstalledFilesPass -f $filePath, $localHost
                $msg += ' :: '
                $msg += ([System.IO.File]::GetCreationTime(${localFilePath}) |Out-string).trim()
                $msg += ' :: '
                $msg += ((([System.IO.File]::GetAccessControl(${localFilePath})).Access)[0]).FileSystemRights
                $logLines.Add("${msg}|SUCCESS")
            }
            $detailList.Add($msg)
        }
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_Additional_Installed_Files"
               Title       = "Installed Files match recipe."
               DisplayName = "Installed Files match recipe."
               Severity    = $resultSeverity
               Description = "Validating all additional files exist on the live host that are defined in the OS image recipe."}
    return (TestResult @splat)
}

function Test-BaseOSimage {
    <#
    .SYNOPSIS
        Validate that the system has a supported base OS version installed as defined in the OS image recipe file.
    .DESCRIPTION
        Validate that the Edition string and the Version string installed match what is in the OS image recipe.
        Use the following PS commands to perform this validation:
          Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object -Property LCUVer).LCUVer
          (Get-ComputerInfo | Select-Object WindowsEditionId).WindowsEditionId
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $recipeBaseOSverString = $null
        $recipeEditionString = $null
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            $recipeBaseOSverString = $XMLstructure.BuildInfo.SupportedVersions.Version.Build
            # validate only the first 3 chunks of the version string as the last chunk represents
            # the LCU (HotFixes) and those differ post composed image creation
            $recipeBaseOSverString = ($recipeBaseOSverString.Split('.')[0..2]) -join('.')
            $recipeEditionString = $XMLstructure.BuildInfo.SupportedVersions.Version.Edition
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = $resultSeverity
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        if ($recipeBaseOSverString -and $recipeEditionString) {
            try {
                $installedBaseOSverString = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object -Property LCUVer).LCUVer
            }
            catch {
                $installedBaseOSverString = 'N.A.0.0'
            }
            # validate only the first 3 chunks of the version string as the last chunk represents the LCU (HotFixes) and those differ post composed image creation
            $installedBaseOSverString = ($installedBaseOSverString.Split('.')[0..2]) -join('.')
            try {
                $installedEditionString = (Get-ComputerInfo | Select-Object WindowsEditionId).WindowsEditionId
            }
            catch {
                $installedEditionString = 'N/A'
            }
            #$logLines.Add("Validate that the base OS installed on host [${installedBaseOSverString}] matches recipe version [${recipeBaseOSverString}].|INFO")
            if ($recipeBaseOSverString -ne $installedBaseOSverString) {
                $rc += 1
                $msg = $lswTxt.BaseOSimageVersionFail -f $localHost, $recipeBaseOSverString, $installedBaseOSverString
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.BaseOSimageVersionPass -f $localHost, $recipeBaseOSverString, $installedBaseOSverString
                $logLines.Add("${msg}|SUCCESS")
            }
            $detailList.Add($msg)
            if ($recipeEditionString -ne $installedEditionString) {
                $rc += 1
                $msg = $lswTxt.BaseOSimageEditionStringFail -f $localHost, $recipeEditionString, $installedEditionString
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.BaseOSimageEditionStringPass -f $localHost, $recipeEditionString, $installedEditionString
                $logLines.Add("${msg}|SUCCESS")
            }
        }
        $detailList.Add($msg)
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_Base_OS"
               Title       = "BaseOS matches recipe."
               DisplayName = "BaseOS matches recipe."
               Severity    = $resultSeverity
               Description = "Validating that the base OS version string and edition string installed on the host match the OS image recipe."}
    return (TestResult @splat)
}

function Test-BuildId {
    <#
    .SYNOPSIS
        Validate that the system has a version that matches the one defined in the OS image recipe file.
    .DESCRIPTION
        Validate that the version burned into the registry matches what is in the OS image recipe.
        Use the following PS commands to perform this validation:
          (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters).COMPOSED_BUILD_ID
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $recipeBuildId = $null
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            $recipeBuildId = $XMLstructure.BuildInfo.BuildId
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = ${resultSeverity}
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        if ($recipeBuildId) {
            try {
                $installedBuildID = [string]((Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters -ErrorAction SilentlyContinue).COMPOSED_BUILD_ID).trim()
            }
            catch {
                $installedBuildID = 'N/A'
            }
            #$logLines.Add("Validate that OS image version [${recipeBuildId}] is installed on host.|INFO")
            if ($recipeBuildId -ne $installedBuildID) {
                $rc += 1
                $msg = $lswTxt.BuildIdFail -f $localHost, $recipeBuildId, $installedBuildID
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.BuildIdPass -f $localHost, $recipeBuildId, $installedBuildID
                $logLines.Add("${msg}|SUCCESS")
            }
            $detailList.Add($msg)
        }
        $detailList.Add($msg)
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_Version"
               Title       = "OS image version matches recipe."
               DisplayName = "OS image version matches recipe."
               Severity    = $resultSeverity
               Description = "Validating that the OS image version installed on the host matches the OS image recipe."}
    return (TestResult @splat)
}

function Test-ComposedBuildVersion {
    <#
    .SYNOPSIS
        Validate that the version running on the existing Azure Local node
        matches the version running on a node this is about to be added.
        The passed in PSsession is the session to the node that is about to be added.
    .DESCRIPTION
        Validate that the version burned into the registry on the existing
        node matches what is burned into the registry on the node that is about to be added.
        Use the following PS commands to perform this validation:
          (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters).COMPOSED_BUILD_ID
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($existingNodeInstalledBuildID, $existingNodeName, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        if ($existingNodeName -eq $localHost) {
            # if by chance you happen to have remote PS session to the localhost then skip this test
            $msg = $lswTxt.SkipTestNotNodeAdd
            $res = 'SUCCESS'
            $logLines.Add("${msg}|${res}")
        } else {
            try {
                $newNodeInstalledBuildID = [string]((Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters -ErrorAction SilentlyContinue).COMPOSED_BUILD_ID).trim()
            }
            catch {
                $newNodeInstalledBuildID = 'N/A'
            }
            #$logLines.Add("Validate that OS image version [${existingNodeInstalledBuildID}] is installed on the node you want to add to the cluster.|INFO")
            if (($newNodeInstalledBuildID -eq 'N/A') -or ($existingNodeInstalledBuildID -eq 'N/A')) {
                $msg = $lswTxt.SkipTestMissingRecipe
                $res = 'SUCCESS'
                $logLines.Add("${msg}|${res}")
            } elseif ($newNodeInstalledBuildID -ne $existingNodeInstalledBuildID) {
                $rc += 1
                $msg = $lswTxt.NodeAddBuildIdFail -f $existingNodeName, $localHost, $existingNodeInstalledBuildID, $newNodeInstalledBuildID
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.NodeAddBuildIdPass -f $existingNodeName, $localHost, $existingNodeInstalledBuildID, $newNodeInstalledBuildID
                $logLines.Add("${msg}|SUCCESS")
            }
        }
        $detailList.Add($msg)
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    # this is where we get the buildID on the existing cluster, the buildID of the node you want to add is done in the scriptBlock Invoke-Command call below
    try {
        $existingNodeInstalledBuildID = [string]((Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ComposedBuildInfo\Parameters -ErrorAction SilentlyContinue).COMPOSED_BUILD_ID).trim()
    } catch {
        # Brownfield does not have composed build info
        $existingNodeInstalledBuildID = 'N/A'
    }
    $responses = "" | Select-Object -Property rc, details, computername, logLines
    $existingNodeName = $ENV:ComputerName
    if ($PsSession) {
        $responses = Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$existingNodeInstalledBuildID, $existingNodeName, $lswTxt, $resultSeverity)
    } else {
        # if a remote PS session is not passed in then this is NOT a nodeAdd test, so skip
        $rc = 0
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $msg = $lswTxt.SkipTestNotNodeAdd
        $res = 'SUCCESS'
        $detailList.Add($msg)
        $logLines.Add("${msg}|${res}")
        $responses = "" | Select-Object -Property rc, details, computername, logLines
        $responses.rc = $rc
        $responses.details = $detailList
        $responses.computername = $existingNodeName
        $responses.logLines = $logLines
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_NodeAdd_Version"
               Title       = "Cluster OS image version matches the version on the node to add."
               DisplayName = "Cluster OS image version matches the version on the node to add."
               Severity    = $resultSeverity
               Description = "Validating that the OS image version installed on the cluster matches the version on the host to add to the cluster."}
    return (TestResult @splat)
}

function Test-SolutionVersion {
    <#
    .SYNOPSIS
        Validate that the system has a solution version that matches the one defined in the OS image recipe file.
    .DESCRIPTION
        Validate that the solution version burned into the registry matches what is in the OS image recipe.
        Use the following PS commands to perform this validation:
          (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\EdgeArcBootstrapSetup').VSRInfo
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $recipeSolutionVersion = $null
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            $recipeSolutionVersion = $XMLstructure.BuildInfo.VSRVersion
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = ${resultSeverity}
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        if ($recipeSolutionVersion) {
            #$logLines.Add("Validate that solution version [${recipeSolutionVersion}] is installed on host.|INFO")
            try {
                $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\VSR'
                if (-not (Test-Path $regPath))
                {
                    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\EdgeArcBootstrapSetup'
                }
                $vsrInfoJson = [string](Get-ItemProperty -Path $regPath).VSRInfo
                $installedSolutionVersion = (($vsrInfoJson | ConvertFrom-Json | Select-Object -Property SolutionVersion).SolutionVersion).trim()
            }
            catch {
                $installedSolutionVersion = 'N/A'
            }
            if (($recipeSolutionVersion -ne $installedSolutionVersion) -or ($installedSolutionVersion -eq 'N/A')) {
                $rc += 1
                $msg = $lswTxt.SolutionVersionFail -f $localHost, $recipeSolutionVersion, $installedSolutionVersion
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.SolutionVersionPass -f $localHost, $recipeSolutionVersion, $installedSolutionVersion
                $logLines.Add("${msg}|SUCCESS")
            }
            $detailList.Add($msg)
        } else {
            $msg = $lswTxt.SkipTestMissingVSRVersion -f $localHost, $recipeSolutionVersion, $installedSolutionVersion
            $logLines.Add("${msg}|SUCCESS")
            $detailList.Add($msg)
        }
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_Solution_Version"
               Title       = "Solution version matches recipe."
               DisplayName = "Solution version matches recipe."
               Severity    = $resultSeverity
               Description = "Validating that the solution version installed on the host matches the OS image recipe."}
    return (TestResult @splat)
}

function Test-FeaturesOnDemand {
    <#
    .SYNOPSIS
        Validate that the system has the correct FOD enabled as defined in the OS image recipe file.
    .DESCRIPTION
        Validate that the correct version of the FODs are installed.
        Use the following PS command to perform this validation:
          ((Get-WindowsCapability -Online -Name '${name}*').Name.split('~')[-1]).TrimEnd()
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $recipeFODlist = New-Object System.Collections.Generic.List[System.Object]
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            if ($($XMLstructure.SelectNodes('/BuildInfo/FeatureOnDemands/Feature'))) {
                $recipeFODlist = $XMLstructure.BuildInfo.FeatureOnDemands.Feature
            }
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = ${resultSeverity}
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        $recipeFODlist |foreach-object {
            $fullNameString = $_.Name
            $name = ($fullNameString.split('~')[0]).TrimEnd()
            $ver = ($fullNameString.split('~')[-1]).TrimEnd()
            #$logLines.Add("Validate that FOD [${name}] is installed as version [${ver}] on host.|INFO")
            try {
                $liveHostVer = $(((Get-WindowsCapability -Online -Name "${name}*").Name.split('~')[-1]).TrimEnd())
            }
            catch {
                $liveHostVer = 'N/A'
            }
            if ($liveHostVer -ne $ver) {
                $rc += 1
                $msg = $lswTxt.FeaturesOnDemandFail -f $name, $localHost, $ver, $liveHostVer
                $logLines.Add("${msg}|${resultSeverity}")
            } else {
                $msg = $lswTxt.FeaturesOnDemandPass -f $name, $localHost, $ver, $liveHostVer
                $logLines.Add("${msg}|SUCCESS")
            }
            $detailList.Add($msg)
        }
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_FOD"
               Title       = "Features on Demand match recipe."
               DisplayName = "Features on Demand match recipe."
               Severity    = $resultSeverity
               Description = "Validating that the FODs installed on the host match the FODs defined in the OS image recipe."}
    return (TestResult @splat)
}

function Test-LatestCumulativeUpdate {
    <#
    .SYNOPSIS
        Validate that the system has the correct LCU as defined in the OS image recipe file.
    .DESCRIPTION
        Validate that the correct LCU version is installed.
        Use the following PS command to perform this validation:
          ((Get-HotFix -Id ${ver}).HotFixID).TrimEnd()
    #>
    [CmdletBinding()]
    Param([Parameter()]
          [System.Management.Automation.Runspaces.PSSession[]]
          $PsSession )
    $sb = {
        Param($recipeFilePath, $renderXML, $lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $recipeLCUlist = New-Object System.Collections.Generic.List[System.Object]
        $innerSB = [ScriptBlock]::Create($renderXML)
        $XMLstructure = & $innerSB $recipeFilePath
        if ($XMLstructure) {
            if ($($XMLstructure.SelectNodes('/BuildInfo/LCUs/LCU'))) {
                $recipeLCUlist = $XMLstructure.BuildInfo.LCUs.LCU
            }
        } else {
            if ($false -eq $XMLstructure) {
                $rc += 1
                $msg = $lswTxt.failTestMissingRecipe
                $res = ${resultSeverity}
            } else {
                $msg = $lswTxt.skipTestMissingRecipe
                $res = 'SUCCESS'
            }
            $detailList.Add($msg)
            $logLines.Add("${msg}|${res}")
        }
        # for example: 9B is overridden by 12B
        $overriddenKBs = @('KB5043080')
        $recipeLCUlist |foreach-object {
            $name = $_.Name
            $_.Msu | foreach-Object {
                [string]$recipeHotFixID = ($_).split('-')[1]
                if (-not ($overriddenKBs -contains $recipeHotFixID)) {
                    #$logLines.Add("Validate that LCU [${name}] as version [${recipeHotFixID}] is installed on host.|INFO.|INFO")
                    $liveHotFixID = $null
                    $liveHotFixID = (Get-HotFix -Id ${recipeHotFixID} -ErrorAction SilentlyContinue).HotFixID
                    if (-not $liveHotFixID -or $liveHotFixID.TrimEnd() -ne $recipeHotFixID) {
                        $rc += 1
                        $msg = $lswTxt.LatestCumulativeUpdateFail -f $name, $localHost, $recipeHotFixID, $liveHotFixID
                        if (-not $liveHotFixID) {
                            $msg += "  Installed Hot Fixes: ["
                            $msg += [string]((get-hotfix | Select-Object -Property HotFixID).HotFixID) -join(',')
                            $msg += "]."
                        }
                        $logLines.Add("${msg}|${resultSeverity}")
                    } else {
                        $msg = $lswTxt.LatestCumulativeUpdatePass -f $name, $localHost, $recipeHotFixID, $liveHotFixID
                        $logLines.Add("${msg}|SUCCESS")
                    }
                } else {
                    $msg = $lswTxt.LatestCumulativeUpdateSkip -f $name, $recipeHotFixID, $localHost
                    $logLines.Add("${msg}|INFO")
                }
                $detailList.Add($msg)
            }
        }
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$global:recipeFilePath, $renderXMLvarScriptBloc, $lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
               Name        = "AzStackHci_OSImageRecipeValidation_LCU"
               Title       = "Latest Cumulative Update matches recipe."
               DisplayName = "Latest Cumulative Update matches recipe."
               Severity    = $resultSeverity
               Description = "Validating that the LCUs installed on the host match the LCUs defined in the OS image recipe."}
    return (TestResult @splat)
}

Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDh5Ix9KML8wvX2
# FPOw0PoHzvFfdFYMRL5SszFnSW0F7qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHVXMml0
# 7+nzUU6AJEqRoVlojqdMjSUNGCmHzPBm7pq0MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEANx4nY1o7ga5bImRcAHRCE4SWHid5UMoROsxE6ioT
# t05SE1V6oWRsr3BhcIpgI08NDt9CMTXvjqi86B0Kh0PXTRcvhN6oTbe4JY3rWd81
# ymwuC1yaqYZl7jJJ+h5UXswKeXS0RSYfUOWTS+B8XREviSZPriUsa+9R8XJClrWe
# W1RRDjcQW+XSWfbuC0/DQSbkyzGNWObDZWiQGYYoSeQgxBaRNShaXlIo3qIrctSA
# ozkC066jNnC1FJqJ8bycJ935OmDa+CP/+Hr/yteAgtdhbNG2KOFp+UWtr5Y+sGVw
# VcHxv3Qf9xb7t2xMF3E0C5/dDLrmjPk4PDQSzJ7D8djGe6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBJx4OVdUnTtRAKkpcapYZx4Ucj1nWl265E1j3A
# dtgcxQIGaedcMrczGBMyMDI2MDUwMzE0MzEwOS45NzNaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCA4FDXVpMr77T8Yy4ZmZk2jRoXH
# y3FczCP1IMNX6EeykjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHIOI/Q/
# kFftYA+M2OY+1Bx3ajBD6/WDAtPT2vFkv25SMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIruwBQ/007mqEAAQAAAiswIgQg4bigwWvF
# x04J9mIfST2NDYTqeHpS2VK/0b1JF/5aWO0wDQYJKoZIhvcNAQELBQAEggIARX+g
# x6eXEGpPaZ6YlTzym+g00W3nkfU52N69dRWjreU8ttrmEZAAmZsTArqFiEMtT+7r
# Yoo4fLR8PhYkMMuLUpbC7HaNYSHph70vKVdZS5nH6+JOuOKRcv7MpE1eJj96WKg3
# n+rC61djJINojYdo7k3RLVI0PbM0PZWFmVeao6MpOIxUojfm2CY4k/fGUegDi3PU
# PxyfHil6Sd4Vxms1J0uQvt2wl8bHdaHivaok7aO3ORl3V1RLdDr71mlHmXXpY8jW
# O+HiTTuhLBNOqxnsU8HlaaBJWyMAcvKZqxcMLiTescGnob7hq2Vv46jfjQfl6tqZ
# 18ERkcq+vXvKUopVF+R5KJlWGo/OGt0WXbYtdk8S6Fw/ZfZ/2ftyr7Ho5LGtWmYd
# r16GiVt9qyUUGN0cbFAozXpdND5bcUxOC7TtVSZbk2wB0n9ECXTPpts3pzt5FD6Q
# IWMyfNBNTySBMs6v9Nn9knum7M8/RmPdzZ6pAnOmRuggScNGDOb2/S0W/cXOvwjs
# /Zp3Xiv1tsgZXT8llV+5WIzRgGK1C8rTSrDdrZx1s0dlC3LYPIxpeaMIHBrE/UrU
# WbkdTIA94YgKHvWMepsNWj55YOu8ap3qAnQuhPLcPCD4LPd49obZdza4OAryDKuh
# Pk+GuwxKGFWrabu3giEAXMXlFIbrnpqX7hp/ZfE=
# SIG # End signature block
