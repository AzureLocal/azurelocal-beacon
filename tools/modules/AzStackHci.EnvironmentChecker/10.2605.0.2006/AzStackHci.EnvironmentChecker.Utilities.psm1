# Push shared infrastructure to global scope so all validator modules can use
# Log-Info, New-AzStackHciResultObject, Assert-ServiceState, Get-DeviceRequirementsUrl etc.
# -Global without -Force: fast (uses module cache), just makes functions available globally.
Import-Module $PSScriptRoot\AzStackHci.EnvironmentChecker.Reporting.psm1 -Global -DisableNameChecking
Import-Module $PSScriptRoot\AzStackHci.EnvironmentChecker.PortableUtilities.psm1 -Global -DisableNameChecking
Import-Module $PSScriptRoot\AzStackHci.EnvironmentChecker.Helpers.psm1 -Global -DisableNameChecking
Import-Module $PSScriptRoot\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -Global -DisableNameChecking
Import-LocalizedData -BindingVariable lTxt -FileName AzStackHci.EnvironmentChecker.Strings.psd1

function Test-ModuleUpdate
{
    <#
    .SYNOPSIS
        Checks PSGallery for updated module.
    .DESCRIPTION
        Checks PSGallery for updated module and gives user 10 seconds
        to cancel cmdlet and prints update instructions to screen
    #>
    param([switch]$PassThru)
    try
    {
        if (-not $PassThru)
        {
            $thisVersion = (Get-PSCallStack | Where-Object Command -like 'Invoke-AzstackHci*Validation').InvocationInfo.MyCommand.Version
            Log-Info ("Looking for module updates for AzStackHci.EnvironmentChecker greater than {0}" -f [system.string]$thisVersion)
            $ModuleOnline = Find-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery -ErrorAction SilentlyContinue
            if ($ModuleOnline -ne $null)
            {
                if ([system.version]$($ModuleOnline.Version -replace ('-preview', '')) -gt $thisVersion)
                {
                    Log-Info ($lTxt.UpdateToVersion -f $ModuleOnline.Version, $ModuleOnline.Name) -ConsoleOut
                    Start-Sleep -Seconds 10
                }
                else
                {
                    Log-Info ($lTxt.CurrentVersion -f 'AzStackHci.EnvironmentChecker', [system.string]$thisVersion)
                }
            }
            else
            {
                Log-Info $lTxt.EnvCheckerVersionNotFound -ConsoleOut -Type Warning
            }
        }
    }
    catch
    {
        Log-Info ($lTxt.Exception -f $MyInvocation.MyCommand.Name, $_.exception.message) -Type Error
    }
}

function Test-Count
{
    [CmdletBinding()]
    param (
        $CimData,

        [int]
        $minimum,

        [string]
        $ValidatorName,

        [validateset('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]
        $Severity
    )
    try
    {
        $className = $CimData.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
        $serverName = $CimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        $instanceId = "Machine: $serverName, Class: $ClassName"

        if ($CimData.Count -lt $minimum)
        {
            $status = 'FAILURE'
            $detail = $lTxt.MinCount -f $ClassName, $CimData.count, $minimum
            Log-Info $detail -Type $Severity
        }
        else
        {
            $detail = $lTxt.MinCount -f $ClassName, $CimData.count, $minimum
            $status = 'SUCCESS'
        }

        $resultParams = @{
            Name               = 'AzStackHci_{0}_Test_{1}_Minimum_Count' -f $ValidatorName, $className
            Status             = $status
            Severity           = $Severity
            TargetResourceName = $instanceId
            Source             = "$ClassName Minimum Count"
            Resource           = $CimData.count
            Detail             = $detail
        }
        New-LightweightResult @resultParams
    }
    catch
    {
        throw $_
    }
}

function Test-InstanceCountByGroup
{
    <#
    .SYNOPSIS
        Test if count matches across groups
    #>
    [CmdletBinding()]
    param (
        $CimData,

        [string[]]
        $GroupProperty,

        [string]
        $ValidatorName,

        [validateset('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]
        $Severity
    )
    try
    {
        $GroupValues = $cimData | Group-Object -Property $groupProperty | Select-Object -ExpandProperty Name
        $nodeCount = @($cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique).count
        foreach ($GroupValue in $GroupValues)
        {
            foreach ($group in $GroupProperty)
            {
                $gData = $CimData | Where-Object $Group -eq $GroupValue
                if ($gData.CimSystemProperties.SystemName.Count -eq 1)
                {
                    $serverName = $gData.CimSystemProperties.SystemName
                }
                else
                {
                    $serverName = 'AllServers'
                }
                $className = $gData.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
                $groupData = $gData | Group-Object { $_.CimSystemProperties.ServerName } | Select-Object *, @{label = 'InstanceCount'; e = { $_.count } }
                $groupDataCount = $groupData.InstanceCount | Sort-Object | Get-Unique
                # The count of InstanceCounts must equal the number of servers to ensure each server has at least 1 instance
                # e.g. SVR1 has 6 disks of type A, SVR has 6 disks of type A, but SVR3 could have 5 disks of type A.
                # There should be only 1 unique InstanceCount from all values to ensure each server has the same instance count
                # e.g. SVR1 has 6 disks of type A, SVR has 6 disks of type A, SVR3 has 6 disks of type A.
                $Status = if ($groupData.InstanceCount.Count -ne $nodeCount -or $groupDataCount.Count -gt 1 ) { 'FAILURE' } else { 'SUCCESS' }
                $groupDataString = ($groupData | Sort-Object InstanceCount | ForEach-Object { "{0}: {1} x {2}" -f $_.Name, $GroupValue, $_.InstanceCount }) -join "`r`n"
                $dtl = $lTxt.CountByGroup -f $className, $group, $groupDataString
                if ($status -eq 'SUCCESS') {
                    Log-Info $dtl
                }
                else
                {
                    Log-Info $dtl -Type Warning
                }
                $params = @{
                    Name               = 'AzStackHci_{0}_Test_{1}_Instance_Consistency_Count_ByGroup' -f $ValidatorName, $className
                    Title              = 'Test {0} Instance Consistency By Group' -f $className
                    DisplayName        = 'Test {0} Instance Consistency By Group {1}' -f $className, $ServerName
                    Severity           = $Severity
                    Description        = 'Checking all servers have same {0} instance count by group' -f $className
                    Tags               = @{}
                    Remediation        = Get-DeviceRequirementsUrl
                    TargetResourceID   = "Machine: $ServerName, Class: $ClassName, Group: $GroupValue"
                    TargetResourceName = "Machine: $ServerName, Class: $ClassName, Group: $GroupValue"
                    TargetResourceType = $className
                    Timestamp          = [datetime]::UtcNow
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $serverName
                        Resource  = $ClassName
                        Detail    = $dtl
                        Status    = $Status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                New-AzStackHciResultObject @params
            }
        }
    }
    catch
    {
        throw $_
    }
}

function Test-GroupProperty
{
    <#
    .SYNOPSIS
        Test if properties match across groups
    #>
    [CmdletBinding()]
    param (
        $CimData,

        [string[]]
        $GroupProperty,

        [string[]]
        $MatchProperty,

        [string]
        $ValidatorName,

        [validateset('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]
        $Severity
    )
    try
    {
        # Group by name and compare properties within each group
        $className = $CimData.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
        $ServerName = $CimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        $groupedData = @($CimData | Group-Object -Property $groupProperty)
        $returnResult = @()
        if ($serverName.Count -gt 1)
        {
            $serverName = 'AllServers'
        }
        $returnResult += foreach ($group in $groupedData)
        {
            $instanceId = "Machine: {0}, Class: {1} Group: {2}" -f $ServerName, $className, $group.Name
            $groupName = $group.Name
            $detail = $null
            if ($group.Count -gt 1)
            {
                foreach ($propertyName in $matchProperty)
                {
                    # Using Select-Object -Unique to get unique values because Get-Unique doesn't work with null and empty values
                    if (($group.Group.$propertyName | Select-Object -Unique).Count -gt 1)
                    {
                        $status = 'FAILURE'
                        # Summarize which servers/instances have which values
                        $valueGroups = $group.Group | Group-Object -Property $propertyName
                        $valueSummary = @($valueGroups | ForEach-Object {
                            $servers = @($_.Group.CimSystemProperties.ServerName | Sort-Object | Get-Unique)
                            $serverList = if ($servers.Count -le 4) { $servers -join ', ' } else { ($servers[0..2] -join ', ') + " +$($servers.Count - 3) more" }
                            "'$($_.Name)' on $($_.Count) instance(s) ($serverList)"
                        })
                        $detail = "$className property '$propertyName' has inconsistent values: $($valueSummary -join '; ')"
                        Log-Info -Message $detail -Type Warning
                    }
                    else
                    {
                        $detail = $lTxt.MatchProp -f $className, $propertyName, ($group.Group.$propertyName -join ', ')
                        $status = 'SUCCESS'
                    }
                    $params = @{
                        Name               = 'AzStackHci_{0}_Test_{1}_Group_Consistency' -f $ValidatorName, $className
                        Title              = 'Test {0} Grouped by {1} has consistent {2} property values' -f $className, $groupName, $propertyName
                        DisplayName        = 'Test {0} Grouped by {1} has consistent {2} property values {3}' -f $className, $groupName, $propertyName, $ServerName
                        Severity           = $Severity
                        Description        = 'Checking {0} Grouped by {1} for consistent {2} property' -f $className, $groupName, $propertyName
                        Tags               = @{}
                        Remediation        = Get-DeviceRequirementsUrl
                        TargetResourceID   = "Machine: $ServerName, Class: $ClassName, Group: $GroupValue, Property: $propertyName"
                        TargetResourceName = "Machine: $ServerName, Class: $ClassName, Group: $GroupValue, Property: $propertyName"
                        TargetResourceType = $className
                        Timestamp          = [datetime]::UtcNow
                        Status             = $status
                        AdditionalData     = @{
                            Source    = "$serverName, $ClassName, $groupName, $propertName"
                            Resource  = ($group.Group.$propertyName -join "', '")
                            Detail    = $detail
                            Status    = $Status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    New-AzStackHciResultObject @params
                }
            }
        }
        $returnResult
    }
    catch
    {
        throw $_
    }
}

function Test-InstanceCount
{
    <#
    .SYNOPSIS
        Test if instance count matches across instances
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        $CimData,

        [Parameter()]
        [string]
        $ValidatorName,

        [validateset('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]
        $Severity,

        [Parameter()]
        [string]
        $NamePostFix
    )
    if ($CimData.CimSystemProperties.SystemName.Count -eq 1)
    {
        $serverName = $CimData.CimSystemProperties.SystemName
    }
    else
    {
        $serverName = 'AllServers'
    }

    $className = $CimData.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
    $InstanceId = "Machine: $ServerName, Class: $ClassName"
    $groupData = $cimData | Group-Object { $_.CimSystemProperties.ServerName } | Select-Object *, @{label = 'InstanceCount'; e = { $_.count } }
    $groupDataCount = $groupData.InstanceCount | Sort-Object | Get-Unique
    $status = if ($groupDataCount.Count -gt 1) { 'FAILURE' } else { 'SUCCESS' }
    $groupDataString = ($groupData | Sort-Object InstanceCount | ForEach-Object { "{0} x {1}" -f $_.Name, $_.InstanceCount }) -join "`r`n"
    if ($NamePostFix)
    {
        $Name = 'AzStackHci_{0}_Test_{1}_{2}_Instance_Consistency_Count' -f $ValidatorName, $className, $NamePostFix
        $Title = 'Test {0} {1} Instance Count Consistency' -f $className, $NamePostFix
        $DisplayName = 'Test {0} {1} Instance Count Consistency {2}' -f $className, $NamePostFix, $serverName
        $Description = 'Checking all servers have same {0} {1} instance count' -f $className, $NamePostFix
        $dtl = $lTxt.InstanceCount -f $ClassName, "($NamePostFix) ", $groupDataString
    }
    else
    {
        $Name = 'AzStackHci_{0}_Test_{1}_Instance_Consistency_Count' -f $ValidatorName, $className
        $Title = 'Test {0} Instance Count Consistency' -f $className
        $DisplayName = 'Test {0} Instance Count Consistency {1}' -f $className, $serverName
        $Description = 'Checking all servers have same {0} instance count' -f $className
        $dtl = $lTxt.InstanceCount -f $ClassName, $NamePostFix, $groupDataString
    }

    if ($Status -eq 'SUCCESS') {
        Log-Info $dtl
    }
    else
    {
        Log-Info $dtl -Type Warning
    }
    $params = @{
        Name               = $Name
        Title              = $Title
        DisplayName        = $DisplayName
        Severity           = $Severity
        Description        = $Description
        Tags               = @{}
        Remediation        = Get-DeviceRequirementsUrl
        TargetResourceID   = $InstanceId
        TargetResourceName = $InstanceId
        TargetResourceType = $className
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source    = $serverName
            Resource  = $ClassName
            Detail    = $dtl
            Status    = $status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    New-AzStackHciResultObject @params
}

function Test-PropertySync
{
    <#
    .SYNOPSIS
        Test if properties match across instances
    #>

    [CmdletBinding()]
    param (
        [Parameter()]
        $CimData,

        [Parameter()]
        [string[]]
        $MatchProperty,

        [string]
        $ValidatorName,

        [validateset('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]
        $Severity
    )
    try
    {
        $returnResult = @()
        $className = $CimData.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
        $serverName = $CimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique

        if ($serverName.Count -gt 1)
        {
            $serverName = 'AllServers'
            $returnResult += Test-InstanceCount -CimData $CimData -Severity $Severity -ValidatorName $ValidatorName

        }
        $instanceId = "Machine: $ServerName, Class: $ClassName, Instance: All"
        $returnResult += if ($CimData.Count -gt 1)
        {
            foreach ($propertyName in $matchProperty)
            {
                # Using Select-Object -Unique to get unique values because Get-Unique doesn't work with null and empty values
                if (($CimData.$propertyName | Select-Object -Unique).Count -gt 1)
                {
                    $status = 'FAILURE'
                    $detail = $lTxt.MismatchProp -f $className, $propertyName, ("'{0}'" -f ($CimData.$propertyName -join "', '"))
                    Log-Info -Message $detail -Type Warning
                }
                else
                {
                    $detail = $lTxt.MatchProp -f $className, $propertyName, ($CimData.$propertyName -join ',')
                    $status = 'SUCCESS'
                }
                $resultParams = @{
                    Name               = 'AzStackHci_{0}_Test_{1}_Property_{2}_Consistency' -f $ValidatorName, $className, $propertyName
                    Status             = $status
                    Severity           = $Severity
                    TargetResourceName = $InstanceId
                    Source             = "$className`: $propertyName"
                    Resource           = ($CimData.$propertyName -join ',')
                    Detail             = $detail
                }
                New-LightweightResult @resultParams
            }
        }
        return $returnResult
    }
    catch
    {
        throw $_
    }
}

function Test-DesiredProperty
{
    <#
    .SYNOPSIS
        Test if properties have required value
    #>
    [cmdletbinding()]
    param (
        $cimData,

        [hashtable]
        $desiredPropertyValue,

        [string]
        $InstanceIdStr,

        [string]
        $ValidatorName,

        [validateset('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]
        $Severity
    )

    try
    {
        # Test properties
        $returnResult = @()
        $returnResult += foreach ($instance in $cimData)
        {
            $serverName = $instance.CimSystemProperties.ServerName | Sort-Object | Get-Unique
            $className = $instance.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
            $sb = ([scriptblock]::Create($InstanceIdStr))
            $instanceId = Invoke-Command -ScriptBlock $sb
            foreach ($propertyName in $desiredPropertyValue.Keys)
            {
                $detail = $null
                $passed = $false
                $hint = $null
                $diagProp = $null
                $desiredPropertyValueCheck = $null
                $desiredPropertyValueCheck = if ($desiredPropertyValue.$propertyName -is [hashtable])
                {
                    $desiredPropertyValue.$propertyName.Value
                }
                else
                {
                    $desiredPropertyValue.$propertyName
                }

                $instancePropertyValue = $instance.$propertyName | Select-Object -First 1
                if ($instancePropertyValue -notin $desiredPropertyValueCheck)
                {
                    # Try to add additional diagnostic property
                    if ($desiredPropertyValue.$propertyName.DiagnosticProperty)
                    {
                        $diagProp = ' ({0}: {1})' -f $desiredPropertyValue.$propertyName.DiagnosticProperty, ($instance.$($desiredPropertyValue.$propertyName.DiagnosticProperty) | Select-Object -First 1)
                    }
                    $status = 'FAILURE'
                    $hint = if ($desiredPropertyValue.$propertyName.hint) { ' ({0})' -f $desiredPropertyValue.$propertyName.hint }
                    $detail = $lTxt.UnexProp -f $className, $propertyName, $instancePropertyValue, ($desiredPropertyValueCheck -join ','), $hint, $diagProp
                    Log-Info -Message $detail -Type Warning
                }
                else
                {
                    $status = 'SUCCESS'
                    $detail = $lTxt.Prop -f $className, $propertyName, $instancePropertyValue, ($desiredPropertyValueCheck -join ','), $hint
                }

                $resultParams = @{
                    Name               = 'AzStackHci_{0}_Test_{1}_Instance_Property_{2}' -f $ValidatorName, $className, $propertyName
                    Status             = $status
                    Severity           = $Severity
                    TargetResourceName = $InstanceId
                    Source             = "$className`: $propertyName"
                    Resource           = $(if ($hint) { "$($instancePropertyValue)$hint" } else { $instancePropertyValue })
                    Detail             = $detail
                }
                New-LightweightResult @resultParams
            }
        }
        return $returnResult
    }
    catch
    {
        throw $_
    }
}

function Get-TestCount
{
    param (
        [Parameter()]
        [string]
        $ModuleName,

        [Parameter()]
        [string]
        $CommandPrefix
    )
    try
    {
        $command = Get-Command -Name $CommandPrefix* -Module $ModuleName
        if ($command)
        {
            return $command.Count
        }
        else
        {
            return 1
        }
    }
    catch
    {
        return 1
    }
}


function Test-CimData {
    param (
        $Data,
        $ClassName,
        $Detail,
        [string]$DiagnosticCommand
    )

    $systemNames = $Data.ComputerName | Sort-Object | Get-Unique
    $testResult = foreach ($systemName in $systemNames)
    {
        $sData = $Data.CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
        if ($sData.count -eq 0)
        {
            $diagHint = if ($DiagnosticCommand) {
                "`nTo diagnose, run on $systemName`:`n  $DiagnosticCommand"
            } else { '' }
            $failDetail = if ([string]::IsNullOrEmpty($detail))
            {
                "Unable to retrieve data for $ClassName on $systemName$diagHint"
            }
            else
            {
                "$Detail$diagHint"
            }
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_{0}' -f $className
                Title              = "Test $ClassName API"
                DisplayName        = "Test $ClassName API $systemName"
                Severity           = 'CRITICAL'
                Description        = "Checking $ClassName has CIM data"
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = "Machine: $systemName, Class: $ClassName"
                TargetResourceName = "Machine: $systemName, Class: $ClassName"
                TargetResourceType = $className
                Timestamp          = [datetime]::UtcNow
                Status             = 'FAILURE'
                AdditionalData     = @{
                    Source    = $systemName
                    Resource  = 'Null'
                    Detail    = $failDetail
                    Status    = 'FAILURE'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    return $testResult
}

function Get-DeploymentData
{
    [cmdletbinding()]
    param ($Path)

    try
    {
        $Json = Get-Content -Path $Path | ConvertFrom-Json
        $DeploymentData = $json.ScaleUnits[0].DeploymentData
        if ([string]::IsNullOrEmpty($DeploymentData))
        {
            Log-Info $lTxt.InvalidDeploymentData -Type Warning
            return $null
        }
        return $DeploymentData
    }
    catch
    {
        throw $_
    }
}

function Get-TestListByFunction
{
    <#
    .SYNOPSIS
        Retrieve list of tests for a given validator
    .DESCRIPTION
        Tests should be prefixed with Test- and reside in a "helpers" module
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $prefix = 'Test-*',

        [Parameter()]
        [string]
        $ModuleName
    )

    try
    {
        # First try to get exported functions (fast path)
        $script:envchktestList = @(Get-Command -Name $prefix -Module $ModuleName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

        # If no exported functions found, scan the module file directly (handles nested modules without exports)
        if ($script:envchktestList.Count -eq 0)
        {
            $modulePath = $null

            # Try to find the module, checking both loaded and available modules
            $module = Get-Module -Name $ModuleName -ErrorAction SilentlyContinue

            if ($module)
            {
                $modulePath = $module.Path
            }
            else
            {
                # Module not loaded, try to find it in available modules
                $moduleInfo = Get-Module -Name $ModuleName -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($moduleInfo)
                {
                    $modulePath = $moduleInfo.Path
                }
                else
                {
                    # Module not found through Get-Module, try to locate it by searching relative to this module
                    # This handles nested modules that aren't in $env:PSModulePath
                    # Expected pattern: AzStackHci.ValidatorName.Helpers

                    # Extract the validator folder name from the module name
                    # E.g., AzStackHci.Upgrade.Helpers -> AzStackHci.Upgrade -> AzStackHciUpgrade
                    $parts = $ModuleName -split '\.'
                    if ($parts.Count -gt 2)
                    {
                        $validatorName = $parts[0..($parts.Count-2)] -join '.'
                        $folderName = $validatorName -replace '\.', ''
                    }
                    else
                    {
                        $folderName = $ModuleName -replace '\.', ''
                    }

                    $possiblePaths = @(
                        (Join-Path $PSScriptRoot "$folderName\$ModuleName.psm1"),
                        (Join-Path $PSScriptRoot "$ModuleName\$ModuleName.psm1"),
                        (Join-Path $PSScriptRoot "$ModuleName.psm1")
                    )

                    foreach ($path in $possiblePaths)
                    {
                        if (Test-Path $path)
                        {
                            $modulePath = $path
                            Write-Debug -Message "Found module file at: $modulePath" -Verbose
                            break
                        }
                    }
                }
            }

            if ($modulePath -and (Test-Path $modulePath))
            {
                Write-Debug -Message "Scanning module file directly: $modulePath" -Verbose
                $content = Get-Content -Path $modulePath -Raw

                # Extract function names that match the prefix pattern (convert wildcard to regex)
                $prefixRegex = '^' + $prefix.Replace('*', '.*').Replace('?', '.') + '$'
                $functionPattern = 'function\s+(Test-[a-zA-Z0-9_-]+)'
                $matches = [regex]::Matches($content, $functionPattern)

                $script:envchktestList = @($matches | ForEach-Object {
                    $functionName = $_.Groups[1].Value
                    if ($functionName -match $prefixRegex)
                    {
                        $functionName
                    }
                } | Where-Object { $_ } | Sort-Object -Unique)
            }
        }

        Write-Debug -Message "Retrieving list of tests for $ModuleName`: $($script:envchktestList -join ',')" -Verbose
        return $script:envchktestList
    }
    catch
    {
        Write-Debug -Message "Failed to retrieve test list. Error $($_.exception)" -Verbose
    }
}

function Select-TestList
{
    <#
    .SYNOPSIS
        Filter Testlist by Include, Exclude and File based exclusions
    .DESCRIPTION
        Include replaces complete list, exclude is applied and file based exclusions are removed by regex.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $TestList,

        [Parameter()]
        [string[]]
        $Include,

        [Parameter()]
        [string[]]
        $Exclude,

        [Parameter()]
        [string]
        $FilePath  = "$PsScriptRoot\ExcludeTests.txt"
    )
    try
    {
        $returnList = @($TestList)
        if ($include)
        {
            $returnList = $Include
            Log-Info "Setting tests to $($include -join ',')"
        }
        if ($exclude)
        {
            Log-Info "Removing tests $($exclude -join ',')"
            $returnList = $returnList | Select-String -Pattern $exclude -NotMatch | ForEach-Object { $_.Line }
        }
        if (![string]::IsNullOrEmpty($ENV:envchkroverridetest))
        {
            $overrideTests = $ENV:envchkroverridetest -split ','
            Log-Info "Removing override tests (via manifest) from test list: $($overrideTests -join ',')"
            $returnList = $returnList | Select-String -Pattern $overrideTests -NotMatch | ForEach-Object { $_.Line }
        }
        $fileExclusion = @()
        $fileExclusion = Get-FileExclusion
        if ($fileExclusion -and $fileExclusion.Count -gt 0)
        {
            $returnList = $returnList | Select-String -Pattern $fileExclusion -NotMatch | ForEach-Object { $_.Line }
        }
        else
        {
            Log-Info "No file exclusions found or file is empty."
        }

        if ($returnList.Count -eq 0)
        {
            Log-Info -Message "No tests to run." -ConsoleOut -Type Warning
            break noTestsBreak
        }

        Log-Info "Test list: $($returnList -join ',')"

        return $returnList
    }
    catch
    {
        Log-Info "Failed to filter test list. Error: $($_.exception)" -Type Warning
    }
}

function Get-FileExclusion
{
    <#
    .SYNOPSIS
        Get file based exclusions from ExcludeTests.txt
    .DESCRIPTION
        Reads ExcludeTests.txt file and returns list of exclusions.
    #>
    [CmdletBinding()]
    param ()
    try
    {
        # Set potential paths for ExcludeTests.txt
        $path = @($PSScriptRoot)
        $moduleBase = Get-Module AzStackHci.EnvironmentChecker -ListAvailable | Select-Object -ExpandProperty ModuleBase
        if ($moduleBase) { $path += $moduleBase }
        Log-Info "Searching for ExcludeTests.txt in paths: $($path -join ', ')"
        # get the most recent ExcludeTests.txt file
        $filePath = Get-ChildItem -Path $path -Recurse -Filter 'ExcludeTests.txt' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        # if the file exists, read and return its content
        if ($null -ne $filePath)
        {
            Log-Info "Reading exclusion file $($FilePath.Fullname) LastWriteTime: $($FilePath.LastWriteTime)" -ConsoleOut
            $fileExclusion = @()
            $fileExclusion = Get-Content -Path $FilePath.Fullname
            Log-Info "Applying file exclusions: $($fileExclusion -join ',')" -ConsoleOut
            return $fileExclusion
        }
        else
        {
            return $null
        }
    }
    catch
    {
        Log-Info "Failed to read exclusions file $filePath. Error: $($_.exception)" -Type Warning
        return $null
    }
}

function Get-TestIsEnabled
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $TestName
    )
    if (Select-TestList -TestList $TestName)
    {
        Log-Info "Test $TestName is enabled."
        return $true
    }
    else
    {
        Log-Info "Test $TestName is not enabled. Skipping."
        return $false
    }
}

function Set-TrustedHosts
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $Nodes
    )
    $trustedHosts = (Get-Item -Path WSMan:\localhost\Client\TrustedHosts).Value
    foreach ($node in $nodes)
    {
        if ('*' -notin $TrustedHosts -and ($node -notin $TrustedHosts.Split(',')))
        {
            Log-Info "Adding $node to TrustedHosts"
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $node -Concatenate -Force
        }
        else
        {
            Log-Info "TrustedHosts already matches $node. Continuing."
        }
    }
}

function Get-IsProxyEnabled
{
    $line1, $line2, $line3, $JsonLines = netsh winhttp show advproxy
    $proxy = $JsonLines | ConvertFrom-Json -ErrorAction SilentlyContinue
    Log-Info "Proxy Enabled: $([bool]$proxy.Proxy)"
    Log-Info "Proxy Output:"
    Log-Info "$($proxy | Format-Table | Out-String)"
    [bool]$proxy.Proxy
}

function Get-RegionIsUSSecOrUSNat
{
    param (
        [string]
        $RegionName
    )
    if ($RegionName -in @('USSecEast', 'USSecWest', 'USSecWestCentral', 'USNatEast', 'USNatWest'))
    {
        Log-Info "Region $RegionName is USSec or USNat"
        return $true
    }
    Log-Info "Region $RegionName is not USSec or USNat"
    return $false
}

function Get-OptimalParallelJobCount
{
    <#
    .SYNOPSIS
        Calculates optimal parallel job count based on node count and system resources.
    .DESCRIPTION
        Returns a bounded parallel job count for scale-aware throttling.
        Used to prevent resource exhaustion on large clusters while maximizing throughput.
    .PARAMETER NodeCount
        Number of nodes in the cluster.
    .PARAMETER MaxJobs
        Maximum allowed parallel jobs (default: 64).
    .PARAMETER MinJobs
        Minimum parallel jobs to maintain (default: 4).
    .EXAMPLE
        $maxParallel = Get-OptimalParallelJobCount -NodeCount 64
        # Returns min(64, ProcessorCount * 2), clamped to 4-64 range
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [int]$NodeCount,

        [int]$MaxJobs = 64,

        [int]$MinJobs = 4
    )
    $processorCount = [Environment]::ProcessorCount
    $calculated = [Math]::Min($NodeCount, $processorCount * 2)
    return [Math]::Max([Math]::Min($calculated, $MaxJobs), $MinJobs)
}

function Invoke-ParallelPerNodeTest
{
    <#
    .SYNOPSIS
        Processes Test-DesiredProperty and Test-PropertySync calls in parallel per node.
    .DESCRIPTION
        Optimized replacement for sequential foreach loops in hardware validation.
        Collects per-node data first, then calls validation functions in parallel using runspaces.
        Falls back to sequential for 4 or fewer nodes.

        This function is designed for the specific pattern used in Hardware validators:
        - Test-DesiredProperty (critical and warning)
        - Test-PropertySync
        - Test-Count
    .PARAMETER SystemNames
        Array of system/node names to process.
    .PARAMETER CimData
        Full CIM data collection from all nodes.
    .PARAMETER DesiredPropertyValue
        Hashtable of desired property values for Test-DesiredProperty.
    .PARAMETER CriticalDesiredPropertyValue
        Hashtable of critical desired property values (optional).
    .PARAMETER MatchProperty
        Array of property names for Test-PropertySync.
    .PARAMETER InstanceIdStr
        String template for instance identification.
    .PARAMETER ValidatorName
        Name of the validator (e.g., 'Hardware').
    .PARAMETER Severity
        Severity level for Test-DesiredProperty.
    .PARAMETER Minimum
        Minimum count for Test-Count (optional).
    .PARAMETER NodeLogMessage
        Log message format string for per-node logging (optional). Use {0} for node name, {1} for count.
    .EXAMPLE
        $results = Invoke-ParallelPerNodeTest -SystemNames $systemNames -CimData $cimData `
            -DesiredPropertyValue $desiredPropertyValue -MatchProperty $matchProperty `
            -InstanceIdStr $instanceIdStr -ValidatorName 'Hardware' -Severity Critical
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]]$SystemNames,

        [Parameter(Mandatory)]
        [object[]]$CimData,

        [hashtable]$DesiredPropertyValue,

        [hashtable]$CriticalDesiredPropertyValue,

        [string[]]$MatchProperty,

        [string]$InstanceIdStr,

        [Parameter(Mandatory)]
        [string]$ValidatorName,

        [ValidateSet('CRITICAL','WARNING','INFORMATIONAL','Hidden')]
        [string]$Severity = 'WARNING',

        [int]$Minimum = 0,

        [string]$NodeLogMessage
    )

    # For small node counts (4 or fewer), use sequential processing
    # to avoid runspace overhead
    if ($SystemNames.Count -le 4)
    {
        $results = @()
        foreach ($systemName in $SystemNames)
        {
            $nodeData = @($CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName })

            if ($NodeLogMessage)
            {
                Log-Info -Message ($NodeLogMessage -f $systemName, $nodeData.Count)
            }

            if ($DesiredPropertyValue)
            {
                $results += Test-DesiredProperty -CimData $nodeData -desiredPropertyValue $DesiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName $ValidatorName -Severity $Severity
            }

            if ($CriticalDesiredPropertyValue)
            {
                $results += Test-DesiredProperty -CimData $nodeData -desiredPropertyValue $CriticalDesiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName $ValidatorName -Severity CRITICAL
            }

            if ($MatchProperty)
            {
                $results += Test-PropertySync -CimData $nodeData -MatchProperty $MatchProperty -ValidatorName $ValidatorName -Severity $Severity
            }

            if ($Minimum -gt 0)
            {
                $results += Test-Count -CimData $nodeData -minimum $Minimum -ValidatorName $ValidatorName -Severity $Severity
            }
        }
        return $results
    }

    # For larger node counts, process in parallel
    $throttleLimit = Get-OptimalParallelJobCount -NodeCount $SystemNames.Count
    Log-Info -Message ("Processing {0} nodes in parallel (ThrottleLimit: {1})" -f $SystemNames.Count, $throttleLimit)

    # Pre-filter data per node to avoid repeated filtering in runspaces
    $nodeDataMap = @{}
    foreach ($systemName in $SystemNames)
    {
        $nodeDataMap[$systemName] = @($CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName })
    }

    # Create runspace pool
    # Save EnvChkrId - runspaces share the process env and Log-Info in a fresh runspace
    # calls Set-AzStackHciOutputPath which nulls $ENV:EnvChkrId via Set-AzStackHciIdentifier
    $savedEnvChkrId = $ENV:EnvChkrId
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $throttleLimit)
    $runspacePool.Open()

    $jobs = [System.Collections.ArrayList]::new()
    $results = [System.Collections.ArrayList]::new()

    try
    {
        foreach ($systemName in $SystemNames)
        {
            $nodeData = $nodeDataMap[$systemName]

            # Log node info (sequential to maintain order)
            if ($NodeLogMessage)
            {
                Log-Info -Message ($NodeLogMessage -f $systemName, $nodeData.Count)
            }

            # Create PowerShell instance for this node's validation
            $ps = [powershell]::Create()
            $ps.RunspacePool = $runspacePool

            # Define the work to do per node
            $nodeScript = {
                param($NodeData, $DesiredPropertyValue, $CriticalDesiredPropertyValue, $MatchProperty,
                      $InstanceIdStr, $ValidatorName, $Severity, $Minimum, $UtilitiesModulePath, $EnvChkrId)

                # Propagate EnvChkrId into runspace so results have HealthCheckSource
                $ENV:EnvChkrId = $EnvChkrId

                # Import required module in runspace
                Import-Module $UtilitiesModulePath -Force -DisableNameChecking

                $nodeResults = @()

                if ($DesiredPropertyValue)
                {
                    $nodeResults += Test-DesiredProperty -CimData $NodeData -desiredPropertyValue $DesiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName $ValidatorName -Severity $Severity
                }

                if ($CriticalDesiredPropertyValue)
                {
                    $nodeResults += Test-DesiredProperty -CimData $NodeData -desiredPropertyValue $CriticalDesiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName $ValidatorName -Severity CRITICAL
                }

                if ($MatchProperty)
                {
                    $nodeResults += Test-PropertySync -CimData $NodeData -MatchProperty $MatchProperty -ValidatorName $ValidatorName -Severity $Severity
                }

                if ($Minimum -gt 0)
                {
                    $nodeResults += Test-Count -CimData $NodeData -minimum $Minimum -ValidatorName $ValidatorName -Severity $Severity
                }

                return $nodeResults
            }

            [void]$ps.AddScript($nodeScript)
            [void]$ps.AddParameter('NodeData', $nodeData)
            [void]$ps.AddParameter('DesiredPropertyValue', $DesiredPropertyValue)
            [void]$ps.AddParameter('CriticalDesiredPropertyValue', $CriticalDesiredPropertyValue)
            [void]$ps.AddParameter('MatchProperty', $MatchProperty)
            [void]$ps.AddParameter('InstanceIdStr', $InstanceIdStr)
            [void]$ps.AddParameter('ValidatorName', $ValidatorName)
            [void]$ps.AddParameter('Severity', $Severity)
            [void]$ps.AddParameter('Minimum', $Minimum)
            [void]$ps.AddParameter('UtilitiesModulePath', "$PSScriptRoot\AzStackHci.EnvironmentChecker.Utilities.psm1")
            [void]$ps.AddParameter('EnvChkrId', $ENV:EnvChkrId)

            # Start async
            $handle = $ps.BeginInvoke()

            [void]$jobs.Add(@{
                PowerShell = $ps
                Handle     = $handle
                NodeName   = $systemName
            })
        }

        # Collect results from all jobs
        foreach ($job in $jobs)
        {
            try
            {
                $output = $job.PowerShell.EndInvoke($job.Handle)
                if ($output)
                {
                    [void]$results.AddRange(@($output))
                }

                # Check for errors in the runspace
                if ($job.PowerShell.Streams.Error.Count -gt 0)
                {
                    foreach ($err in $job.PowerShell.Streams.Error)
                    {
                        Log-Info -Message ("Warning processing node {0}: {1}" -f $job.NodeName, $err.Exception.Message) -Type Warning
                    }
                }
            }
            catch
            {
                Log-Info -Message ("Error processing node {0}: {1}" -f $job.NodeName, $_.Exception.Message) -Type Warning
            }
            finally
            {
                $job.PowerShell.Dispose()
            }
        }
    }
    finally
    {
        $runspacePool.Close()
        $runspacePool.Dispose()
        # Restore EnvChkrId after runspaces are disposed
        $ENV:EnvChkrId = $savedEnvChkrId
    }

    return $results.ToArray()
}

function Start-ValidatorTest
{
    <#
    .SYNOPSIS
        Safely invokes a test function with timing instrumentation and error handling.
    .DESCRIPTION
        A defensive wrapper for invoking test functions with:
        - Per-test timing logged to verbose log and optionally telemetry
        - Consistent error result generation on failure
        - Optional timeout protection (requires explicit opt-in)

        Note: Timeout protection uses a separate runspace which may not have
        access to all modules. Use TimeoutSeconds only when necessary and ensure
        the test function is available in a fresh runspace.
    .PARAMETER TestName
        Name of the test function to invoke (e.g., 'Test-NetAdapter').
    .PARAMETER Parameters
        Hashtable of parameters to pass to the test function.
    .PARAMETER ValidatorName
        Name of the parent validator (e.g., 'Hardware') for logging context.
    .PARAMETER TimeoutSeconds
        Maximum time allowed for test execution. Default: 0 (no timeout).
        When > 0, uses a separate runspace with timeout protection.
    .PARAMETER EnableTelemetry
        If specified, timing data will be sent to telemetry channel.
    .PARAMETER ContinueOnError
        If specified, returns a proper aggregated error result (via New-AggregatedTestResult)
        instead of throwing on failure. This ensures the test failure appears in telemetry
        with correct shape rather than being silently swallowed.
    .EXAMPLE
        $result = Start-ValidatorTest -TestName 'Test-NetAdapter' -Parameters @{ PsSession = $sessions } -ValidatorName 'Hardware'
    .EXAMPLE
        # With strict timeout (ensure test is available in fresh runspace)
        $result = Start-ValidatorTest -TestName 'Test-PartnerSBECheck' -Parameters $params -ValidatorName 'SBEHealth' -TimeoutSeconds 60 -ContinueOnError
    .OUTPUTS
        Array of test results from the invoked test function, or error result on failure.
    .NOTES
        This function replaces direct Invoke-Expression calls in validators to provide:
        1. Consistent timing instrumentation for performance analysis
        2. Safe execution with graceful error handling
        3. Telemetry for production monitoring
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TestName,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [string]$ValidatorName = 'Unknown',

        [Parameter()]
        [int]$TimeoutSeconds = 0,

        [Parameter()]
        [switch]$EnableTelemetry,

        [Parameter()]
        [switch]$ContinueOnError
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $startTime = Get-Date
    $startTimeStr = $startTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $result = $null
    $status = 'Success'
    $errorMessage = $null

    try
    {
        $timeoutInfo = if ($TimeoutSeconds -gt 0) { " (Timeout: ${TimeoutSeconds}s)" } else { "" }
        Log-Info -Message ("[{0}] Starting test: {1}{2}" -f $ValidatorName, $TestName, $timeoutInfo)

        if ($TimeoutSeconds -gt 0)
        {
            # Create runspace with caller's session state so modules/functions are available
            $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

            # Import all modules currently loaded in the caller's session
            $loadedModules = Get-Module | Where-Object { $_.ModuleType -ne 'Manifest' }
            foreach ($mod in $loadedModules) {
                if ($mod.Path) {
                    $iss.ImportPSModule($mod.Path)
                }
            }

            # Also import any global functions (e.g. test functions defined in-session)
            $globalFunctions = Get-ChildItem Function:\ -ErrorAction SilentlyContinue
            foreach ($fn in $globalFunctions) {
                $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
                    $fn.Name, $fn.ScriptBlock
                )
                $iss.Commands.Add($entry)
            }

            $runspace = [runspacefactory]::CreateRunspace($iss)
            $runspace.Open()

            $ps = [powershell]::Create()
            $ps.Runspace = $runspace

            # Build the script to execute
            $scriptBlock = {
                param($TestName, $Params)
                Invoke-Expression "$TestName @Params"
            }

            [void]$ps.AddScript($scriptBlock)
            [void]$ps.AddParameter('TestName', $TestName)
            [void]$ps.AddParameter('Params', $Parameters)

            $handle = $ps.BeginInvoke()

            # Wait for completion or timeout
            $completed = $handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))

            if ($completed)
            {
                $result = $ps.EndInvoke($handle)

                # Check for errors in the runspace
                if ($ps.Streams.Error.Count -gt 0)
                {
                    $status = 'Error'
                    $errorMessage = ($ps.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '; '
                    Log-Info -Message ("[{0}] Test {1} completed with errors: {2}" -f $ValidatorName, $TestName, $errorMessage) -Type Warning

                    if (-not $ContinueOnError)
                    {
                        $streamException = $ps.Streams.Error[0].Exception
                        try
                        {
                            $ps.Dispose()
                        }
                        finally
                        {
                            try
                            {
                                $runspace.Close()
                            }
                            finally
                            {
                                $runspace.Dispose()
                            }
                        }
                        throw $streamException
                    }
                }
            }
            else
            {
                # Timeout - attempt to stop the runspace
                $ps.Stop()
                $status = 'Timeout'
                $errorMessage = "Test exceeded timeout of $TimeoutSeconds seconds"
                Log-Info -Message ("[{0}] TIMEOUT: Test {1} exceeded {2}s limit" -f $ValidatorName, $TestName, $TimeoutSeconds) -Type Error

                if (-not $ContinueOnError)
                {
                    throw [System.TimeoutException]::new($errorMessage)
                }
            }

            $ps.Dispose()
            $runspace.Close()
            $runspace.Dispose()
        }
        else
        {
            # No timeout - direct invocation (use for trusted internal code only)
            $result = Invoke-Expression "$TestName @Parameters"
        }

        $stopwatch.Stop()
    }
    catch
    {
        $stopwatch.Stop()
        $status = 'Error'
        $errorMessage = $_.Exception.Message

        Log-Info -Message ("[{0}] FAILED test: {1} | Duration: {2}s | Error: {3}" -f $ValidatorName, $TestName, [math]::Round($stopwatch.Elapsed.TotalSeconds, 2), $errorMessage) -Type Error

        if (-not $ContinueOnError)
        {
            throw
        }
    }
    finally
    {
        $durationMs = $stopwatch.Elapsed.TotalMilliseconds
        $durationSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        $resultCount = if ($result) { @($result).Count } else { 0 }

        # Always log completion with timing
        $logMessage = "[{0}] Completed test: {1} | Status: {2} | Duration: {3}s | Results: {4}" -f $ValidatorName, $TestName, $status, $durationSec, $resultCount
        if ($status -eq 'Success') {
            Log-Info -Message $logMessage
        }

        # Send telemetry if enabled
        if ($EnableTelemetry)
        {
            $telemetryData = @{
                Validator = $ValidatorName
                Test = $TestName
                Status = $status
                DurationMs = [math]::Round($durationMs, 0)
                DurationSec = $durationSec
                ResultCount = $resultCount
                TimeoutSeconds = $TimeoutSeconds
                StartTime = $startTimeStr
                EndTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
                EnvChkrId = $ENV:EnvChkrId
            }

            if ($errorMessage) {
                $telemetryData['Error'] = $errorMessage.Substring(0, [Math]::Min(500, $errorMessage.Length))
            }

            $telemetryMessage = $telemetryData | ConvertTo-Json -Compress

            try
            {
                Write-ETWLog -Source 'AzStackHciEnvironmentChecker/Telemetry' -Message $telemetryMessage -EventType Information -EventId 1001
            }
            catch
            {
                Log-Info -Message ("Failed to write test timing telemetry for {0}: {1}" -f $TestName, $_.Exception.Message) -Type Warning
            }
        }
    }

    # If we had an error and ContinueOnError is set, generate a proper error result
    # This ensures the test failure appears in telemetry rather than being silently swallowed.
    if ($status -ne 'Success' -and $ContinueOnError -and -not $result)
    {
        $errorDetail = if ($status -eq 'Timeout') {
            "Test '$TestName' timed out after $TimeoutSeconds seconds."
        } else {
            "Test '$TestName' threw an unhandled exception: $errorMessage"
        }

        $errorLightweight = @(New-LightweightResult `
            -Name "${TestName}_ExecutionError" `
            -Status 'FAILURE' `
            -Severity 'CRITICAL' `
            -TargetResourceName 'TestFramework' `
            -Source $ENV:COMPUTERNAME `
            -Resource $TestName `
            -Detail $errorDetail)

        $result = @(New-AggregatedTestResult `
            -TestName $TestName `
            -DisplayName "$TestName (Execution Error)" `
            -Description $errorDetail `
            -DetailResults $errorLightweight `
            -ValidatorName $ValidatorName `
            -ResourceType 'TestExecution')
    }

    return $result
}

function New-TestSummaryResult
{
    <#
    .SYNOPSIS
        Creates summary result objects for test results at node or cluster scope, separated by severity.
    .DESCRIPTION
        Aggregates multiple detailed test results into summary results grouped by status.
        Generates separate summaries for FAILURE, WARNING, and SUCCESS results.
        Supports two scopes:
        - Node: Creates summaries per node (default)
        - Cluster: Creates summaries for the entire test across all nodes

        This reduces result verbosity while preserving severity separation for prioritization.
    .PARAMETER Scope
        The scope of the summary: 'Node' (per-node) or 'Cluster' (per-test).
        Default: Node
    .PARAMETER NodeName
        The name of the node being summarized (required for Node scope).
    .PARAMETER TestName
        The name of the test (e.g., 'Test-TpmProperties').
    .PARAMETER DetailResults
        Array of detailed result objects from the test.
    .PARAMETER ValidatorName
        Name of the validator (e.g., 'Hardware').
    .PARAMETER Severity
        Default severity for successful results. Failures use CRITICAL, warnings use WARNING.
        Default: INFORMATIONAL.
    .EXAMPLE
        # Per-node summary - returns separate results for failures, warnings, and successes
        $summaries = New-TestSummaryResult -Scope Node -NodeName 'Node1' -TestName 'Test-TpmProperties' `
            -DetailResults $nodeResults -ValidatorName 'Hardware'
    .OUTPUTS
        Array of AzStackHciResultObject - Summary results per severity with IsSummary = $true
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Node', 'Cluster')]
        [string]$Scope = 'Node',

        [Parameter()]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [string]$TestName,

        [Parameter()]
        [array]$DetailResults = @(),

        [Parameter()]
        [string]$ValidatorName = 'Hardware',

        [Parameter()]
        [ValidateSet('CRITICAL', 'WARNING', 'INFORMATIONAL')]
        [string]$Severity = 'INFORMATIONAL'
    )

    $summaryResults = @()

    # Group results by status
    $failedResults = @($DetailResults | Where-Object { $_.Status -eq 'FAILURE' })
    $warningResults = @($DetailResults | Where-Object { $_.Status -eq 'WARNING' })
    $successResults = @($DetailResults | Where-Object { $_.Status -eq 'SUCCESS' })
    $totalCount = @($DetailResults).Count

    # Build scope-specific base identifiers
    if ($Scope -eq 'Node')
    {
        if ([string]::IsNullOrEmpty($NodeName))
        {
            throw "NodeName is required when Scope is 'Node'"
        }
        $resourceName = $NodeName
        $baseInstanceId = "Machine: $NodeName, Test: $TestName"
        $baseDisplayName = "$TestName $NodeName"
        $baseDescription = "$TestName checks on $NodeName"
    }
    else # Cluster
    {
        # Count unique nodes in results
        $nodeCount = @($DetailResults | ForEach-Object {
            if ($_.TargetResourceName -match 'Machine:\s*([^,]+)') { $Matches[1] }
        } | Sort-Object -Unique).Count

        $resourceName = "Cluster ($nodeCount nodes)"
        $baseInstanceId = "Cluster: $TestName"
        $baseDisplayName = "$TestName Cluster"
        $baseDescription = "$TestName checks across $nodeCount nodes"
    }

    # Helper to create a summary result for a specific status group
    $createSummary = {
        param($statusResults, $status, $severityLevel)

        $count = @($statusResults).Count
        if ($count -eq 0) { return $null }

        $statusLabel = switch ($status) {
            'FAILURE' { 'Failed' }
            'WARNING' { 'Warnings' }
            'SUCCESS' { 'Passed' }
        }

        $summaryMessage = "$count $statusLabel of $totalCount total checks"

        $params = @{
            Name               = "AzStackHci_${ValidatorName}_${TestName}_${Scope}_${status}_Summary"
            Title              = "$TestName $Scope $statusLabel"
            DisplayName        = "$baseDisplayName - $count $statusLabel"
            Severity           = $severityLevel
            Description        = "$baseDescription - $statusLabel"
            Tags               = @{ IsSummary = $true; Scope = $Scope; StatusGroup = $status }
            Remediation        = Get-DeviceRequirementsUrl
            TargetResourceID   = "$baseInstanceId, $status Summary"
            TargetResourceName = "$baseInstanceId, $status Summary"
            TargetResourceType = "${Scope}Summary"
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source       = $TestName
                Resource     = $resourceName
                Detail       = $summaryMessage
                Status       = $status
                TimeStamp    = [datetime]::UtcNow
                IsSummary    = $true
                Scope        = $Scope
                StatusGroup  = $status
                Count        = $count
                TotalCount   = $totalCount
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        try
        {
            return New-AzStackHciResultObject @params
        }
        catch
        {
            # Fallback to PSCustomObject if New-AzStackHciResultObject is not available (e.g., in tests)
            return [PSCustomObject]$params
        }
    }

    # Generate separate summaries by severity (FAILURE/CRITICAL first, then FAILURE/WARNING, then SUCCESS)
    $failureSummary = & $createSummary $failedResults 'FAILURE' 'CRITICAL'
    if ($failureSummary) { $summaryResults += $failureSummary }

    # Warnings are FAILURE status with WARNING severity
    $warningSummary = & $createSummary $warningResults 'FAILURE' 'WARNING'
    if ($warningSummary) { $summaryResults += $warningSummary }

    $successSummary = & $createSummary $successResults 'SUCCESS' $Severity
    if ($successSummary) { $summaryResults += $successSummary }

    return $summaryResults
}

function New-NodeSummaryResult
{
    <#
    .SYNOPSIS
        Creates a summary result object for a node's test results.
    .DESCRIPTION
        Aggregates multiple detailed test results into a single summary result per node.
        The summary indicates overall pass/fail status and counts of passed/failed checks.
        This reduces result verbosity while preserving detailed results for diagnostics.

        This is a convenience wrapper around New-TestSummaryResult with Scope='Node'.
    .PARAMETER NodeName
        The name of the node being summarized.
    .PARAMETER TestName
        The name of the test (e.g., 'Test-TpmProperties').
    .PARAMETER DetailResults
        Array of detailed result objects from the test.
    .PARAMETER ValidatorName
        Name of the validator (e.g., 'Hardware').
    .PARAMETER Severity
        Severity level for the summary result. Default: CRITICAL.
    .EXAMPLE
        $summary = New-NodeSummaryResult -NodeName 'Node1' -TestName 'Test-TpmProperties' `
            -DetailResults $nodeResults -ValidatorName 'Hardware'
    .OUTPUTS
        AzStackHciResultObject - A summary result object with IsSummary = $true
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [string]$TestName,

        [Parameter()]
        [array]$DetailResults = @(),

        [Parameter()]
        [string]$ValidatorName = 'Hardware',

        [Parameter()]
        [ValidateSet('CRITICAL', 'WARNING', 'INFORMATIONAL')]
        [string]$Severity = 'CRITICAL'
    )

    return New-TestSummaryResult -Scope Node -NodeName $NodeName -TestName $TestName `
        -DetailResults $DetailResults -ValidatorName $ValidatorName -Severity $Severity
}

function New-LightweightResult
{
    <#
    .SYNOPSIS
        Creates a lightweight hashtable result for aggregation.
    .DESCRIPTION
        Returns a plain hashtable with only the properties needed by New-AggregatedTestResult.
        Avoids the overhead of New-AzStackHciResultObject (DLL loading, manifest overrides,
        ConvertTo-Dictionary, etc.) when individual results will be aggregated and discarded.
        Estimated savings: ~200ms per call (vs New-AzStackHciResultObject).
    .PARAMETER Name
        Test result name (e.g., 'AzStackHci_Hardware_Test_Tpm_TpmPresent_Property').
    .PARAMETER Status
        Result status: SUCCESS, FAILURE, or WARNING.
    .PARAMETER Severity
        Result severity: CRITICAL, WARNING, or INFORMATIONAL.
    .PARAMETER TargetResourceName
        Resource identifier including node name (e.g., 'Machine: NodeName, Class: Tpm').
    .PARAMETER Source
        AdditionalData source field (e.g., property name being tested).
    .PARAMETER Resource
        AdditionalData resource field (e.g., actual property value).
    .PARAMETER Detail
        AdditionalData detail field (e.g., human-readable pass/fail message).
    #>
    [CmdletBinding()]
    param (
        [string]$Name,
        [string]$Status,
        [string]$Severity,
        [string]$TargetResourceName,
        [string]$Source,
        $Resource,
        [string]$Detail
    )

    return @{
        Name               = $Name
        Status             = $Status
        Severity           = $Severity
        TargetResourceName = $TargetResourceName
        TargetResourceID   = $TargetResourceName
        AdditionalData     = @{
            Source = $Source
            Resource = $Resource
            Detail = $Detail
            Status = $Status
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
}

function New-AggregatedTestResult
{
    <#
    .SYNOPSIS
        Creates aggregated results for a test across all nodes, separated by severity.
    .DESCRIPTION
        Aggregates detail results from a test into separate result objects per severity level.
        Returns up to 3 results:
        - CRITICAL result (if any failures exist) with failed nodes and failure details
        - WARNING result (if any warnings exist) with warning nodes and warning details
        - INFORMATIONAL result (if any passes exist) with passed node summary

        This produces 1-3 results per test instead of N results per node, dramatically reducing
        result count at scale while preserving severity separation for prioritization.
    .PARAMETER TestName
        The name of the test (e.g., 'Test-TpmProperties'). 'Test-' prefix will be removed for display.
    .PARAMETER DisplayName
        Human-readable display name (e.g., 'TPM Properties').
    .PARAMETER Description
        Description of what the test checks.
    .PARAMETER DetailResults
        Array of detailed result objects from the test.
    .PARAMETER ValidatorName
        Name of the validator (e.g., 'Hardware').
    .PARAMETER ResourceType
        Type of resource being tested (e.g., 'TPM', 'Memory', 'Processor').
    .PARAMETER Remediation
        Test-specific remediation text. If not provided, defaults to the generic
        device requirements URL from Get-DeviceRequirementsUrl.
    .EXAMPLE
        $results = New-AggregatedTestResult -TestName 'Test-TpmProperties' -DisplayName 'TPM Properties' `
            -Description 'Checking TPM Properties' -DetailResults $allResults -ResourceType 'TPM'
        # Returns 1-3 results depending on whether there are failures, warnings, and/or passes
    .OUTPUTS
        Array of AzStackHciResultObjects - one per severity level with issues.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TestName,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter()]
        [string]$Description = '',

        [Parameter()]
        [array]$DetailResults = @(),

        [Parameter()]
        [string]$ValidatorName = 'Hardware',

        [Parameter()]
        [string]$ResourceType = 'Hardware',

        [Parameter()]
        [string]$Remediation = ''
    )

    # Extract node name from result - handles various formats
    $getNodeName = {
        param($result)
        # Try TargetResourceName first: "Machine: NodeName, ..."
        if ($result.TargetResourceName -match 'Machine:\s*([^,]+)') {
            $name = $Matches[1].Trim()
            if ($name) { return $name }
        }
        # Try TargetResourceID: "Machine: NodeName, ..."
        if ($result.TargetResourceID -match 'Machine:\s*([^,]+)') {
            $name = $Matches[1].Trim()
            if ($name) { return $name }
        }
        # Fallback to ComputerName property if exists
        if ($result.ComputerName) {
            return $result.ComputerName
        }
        # Try CimSystemProperties.ServerName from nested data
        if ($result.CimSystemProperties -and $result.CimSystemProperties.ServerName) {
            return $result.CimSystemProperties.ServerName
        }
        # Try TargetResourceID composite format: "NodeName/Resource" (used by DNS, Software)
        if ($result.TargetResourceID -and $result.TargetResourceID -match '/') {
            $candidate = ($result.TargetResourceID -split '/')[0].Trim()
            if ($candidate -and $candidate -ne 'AllNodes') {
                return $candidate
            }
        }
        # Try bare TargetResourceName (take first path segment for formats like "NodeName/Resource")
        if ($result.TargetResourceName -and $result.TargetResourceName -ne 'AllNodes') {
            return ($result.TargetResourceName -split '/')[0].Trim()
        }
        # Try AdditionalData.Source (populated by Software, MOCStack, DNS, etc.)
        if ($result.AdditionalData -and $result.AdditionalData.Source) {
            $src = $result.AdditionalData.Source
            if ($src -and $src -ne 'AllNodes' -and $src -ne 'All Nodes') {
                return $src
            }
        }
        return 'Unknown'
    }

    # Group results by node, separating cluster-wide consistency checks (e.g. AllServers from Test-PropertySync)
    $clusterWideNames = @('AllServers', 'All Servers', 'AllNodes', 'All Nodes', 'Unknown')
    $nodeGroups = @{}
    $clusterWideResults = @()
    foreach ($result in $DetailResults) {
        $nodeName = & $getNodeName $result
        if ($nodeName -in $clusterWideNames) {
            $clusterWideResults += $result  # Track separately, don't count as a node
            continue
        }
        if (-not $nodeGroups.ContainsKey($nodeName)) {
            $nodeGroups[$nodeName] = @()
        }
        $nodeGroups[$nodeName] += $result
    }

    # If no per-node results found (e.g. Test-Model with only cross-node consistency checks),
    # fall back to including cluster-wide results as a single group
    if ($nodeGroups.Count -eq 0 -and $clusterWideResults.Count -gt 0) {
        $nodeGroups['AllNodes'] = $clusterWideResults
    }

    # Apply manifest severity overrides to per-node detail results before aggregation.
    # This ensures SBE overrides (keyed by per-node result Name) affect the aggregated
    # worst-severity calculation, even when New-LightweightResult skipped the override.
    # Guard with Get-Command: Get-ManifestSeverityOverride is in Manifest.Utilities module
    # which is only imported inside Reporting.psm1 scope (not globally visible in PS 5.1).
    $hasManifestOverride = $null -ne (Get-Command Get-ManifestSeverityOverride -ErrorAction SilentlyContinue)
    if ($hasManifestOverride) {
        foreach ($result in $DetailResults) {
            if ($result.Name -and $result.Severity) {
                try {
                    $override = Get-ManifestSeverityOverride -Name $result.Name -Severity $result.Severity
                    if ($override.OverrideApplied) {
                        $result.Severity = $override.Severity
                    }
                } catch { }
            }
        }
    }

    # Clean test name (remove Test- prefix)
    $cleanTestName = $TestName -replace '^Test-', ''
    # $totalNodes is the nodeCount parameter passed to $createResult per severity group
    $totalChecks = @($DetailResults).Count

    # Inherit HealthCheckSource from detail results if $ENV:EnvChkrId is not set (e.g. manual testing)
    $healthCheckSource = $ENV:EnvChkrId
    if ([string]::IsNullOrEmpty($healthCheckSource) -and $DetailResults.Count -gt 0) {
        $healthCheckSource = ($DetailResults | Where-Object { $_.HealthCheckSource } | Select-Object -First 1).HealthCheckSource
    }

    # Helper to create a result object
    $createResult = {
        param($status, $severity, $detailText, $nodeCount, $descriptionOverride)

        $resultDescription = if ($descriptionOverride) { $descriptionOverride } else { $Description }
        $params = @{
            Name               = "AzStackHci_${ValidatorName}_${cleanTestName}"
            Title              = $DisplayName
            DisplayName        = $DisplayName
            Severity           = $severity
            Description        = $resultDescription
            Tags               = @{ IsAggregated = $true; NodeCount = $nodeCount; StatusGroup = $status }
            Remediation        = if ($Remediation) { $Remediation } else { Get-DeviceRequirementsUrl }
            TargetResourceID   = "AllNodes"
            TargetResourceName = "AllNodes"
            TargetResourceType = "AllNodes:${ResourceType}"
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source       = 'AllNodes'
                Resource     = $ResourceType
                Status       = $status
                Detail       = $detailText
                TimeStamp    = [datetime]::UtcNow
                IsAggregated = $true
                StatusGroup  = $status
                NodeCount    = $nodeCount
                TotalNodes   = $nodeCount
                TotalChecks  = $totalChecks
            }
            HealthCheckSource  = $healthCheckSource
        }

        try {
            return New-AzStackHciResultObject @params
        } catch {
            return [PSCustomObject]$params
        }
    }

    # Group detail results by severity — never aggregate across severities.
    # Each severity level gets its own aggregated result.
    # Cast to [string] because DLL results use ResultSeverity enum, not string.
    # Hashtable.ContainsKey('CRITICAL') fails when the key is an enum value.
    $severityGroups = @{}
    foreach ($result in $DetailResults) {
        $sev = if ($result.Severity) { [string]$result.Severity } else { 'INFORMATIONAL' }
        if (-not $severityGroups.ContainsKey($sev)) {
            $severityGroups[$sev] = @()
        }
        $severityGroups[$sev] += $result
    }

    # If no results at all, return a single passing result at INFORMATIONAL
    if ($severityGroups.Count -eq 0) {
        return @(& $createResult 'SUCCESS' 'INFORMATIONAL' '' 0 $Description)
    }

    # Build one aggregated result per severity group (inline to avoid PS 5.1 scriptblock closure issues)
    $allResults = @()
    $sevOrder = @('CRITICAL', 'WARNING', 'INFORMATIONAL')
    # Include any unexpected severity values
    foreach ($k in $severityGroups.Keys) {
        if ($k -notin $sevOrder) { $sevOrder += $k }
    }

    foreach ($currentSev in $sevOrder) {
        if (-not $severityGroups.ContainsKey($currentSev)) { continue }
        $sevResults = $severityGroups[$currentSev]

        # Categorize nodes within this severity group
        $sevNodeGroups = @{}
        $sevClusterWide = @()
        foreach ($r in $sevResults) {
            $nodeName = & $getNodeName $r
            if ($nodeName -in $clusterWideNames) {
                $sevClusterWide += $r
                continue
            }
            if (-not $sevNodeGroups.ContainsKey($nodeName)) {
                $sevNodeGroups[$nodeName] = @()
            }
            $sevNodeGroups[$nodeName] += $r
        }
        if ($sevNodeGroups.Count -eq 0 -and $sevClusterWide.Count -gt 0) {
            $sevNodeGroups['AllNodes'] = $sevClusterWide
        }

        $sevIsClusterWide = ($sevNodeGroups.Count -eq 1 -and $sevNodeGroups.ContainsKey('AllNodes'))
        $sevFailedNodes = @{}
        $sevWarningNodes = @{}
        $sevPassedNodes = @{}

        foreach ($nodeName in $sevNodeGroups.Keys) {
            $nResults = $sevNodeGroups[$nodeName]
            $nFailures = @($nResults | Where-Object { $_.Status -eq 'FAILURE' })
            $nWarnings = @($nResults | Where-Object { $_.Status -eq 'WARNING' })
            $nPasses = @($nResults | Where-Object { $_.Status -eq 'SUCCESS' })

            if ($nFailures.Count -gt 0) {
                $sevFailedNodes[$nodeName] = @{
                    Failures = $nFailures
                    Warnings = $nWarnings
                    Passes = $nPasses
                    Total = $nResults.Count
                }
            }
            elseif ($nWarnings.Count -gt 0) {
                $sevWarningNodes[$nodeName] = @{
                    Warnings = $nWarnings
                    Passes = $nPasses
                    Total = $nResults.Count
                }
            }
            else {
                $sevPassedNodes[$nodeName] = @{
                    Passes = $nPasses
                    Total = $nResults.Count
                }
            }
        }

        $sevTotalNodes = $sevFailedNodes.Count + $sevWarningNodes.Count + $sevPassedNodes.Count
        $sevDetailLines = @()
        $sevDescParts = @()

        $sevStatus = 'SUCCESS'
        if ($sevFailedNodes.Count -gt 0) { $sevStatus = 'FAILURE' }
        elseif ($sevWarningNodes.Count -gt 0) { $sevStatus = 'FAILURE' }

        # FAILURE nodes
        if ($sevFailedNodes.Count -gt 0) {
            $descriptionSuffix = @()
            foreach ($fNodeName in ($sevFailedNodes.Keys | Sort-Object)) {
                $fNodeData = $sevFailedNodes[$fNodeName]
                $sevDetailLines += "- $fNodeName"
                $failDetailMap = [ordered]@{}
                $hasLongDetail = $false
                foreach ($failure in $fNodeData.Failures) {
                    $failDetail = if ($failure.AdditionalData.Detail) {
                        $rawDetail = [string]$failure.AdditionalData.Detail
                        if ($rawDetail.Length -gt 200) {
                            $hasLongDetail = $true
                        }
                        $rawDetail
                    } else {
                        "$($failure.Name): FAILURE"
                    }
                    if ($failDetailMap.Contains($failDetail)) {
                        $failDetailMap[$failDetail]++
                    } else {
                        $failDetailMap[$failDetail] = 1
                    }
                }
                $nodeReasons = @()
                foreach ($detail in $failDetailMap.Keys) {
                    # AdditionalData.Detail gets full text always
                    if ($failDetailMap[$detail] -gt 1) {
                        $sevDetailLines += "  - $detail ($($failDetailMap[$detail]) instances)"
                        $nodeReasons += "$detail ($($failDetailMap[$detail]) instances)"
                    } else {
                        $sevDetailLines += "  - $detail"
                        $nodeReasons += $detail
                    }
                }
                if ($hasLongDetail) {
                    $descriptionSuffix += "${fNodeName}: see AdditionalData.Detail for full error"
                } else {
                    $descriptionSuffix += "${fNodeName}: $($nodeReasons -join '; ')"
                }
            }
            if ($sevIsClusterWide) {
                $failedProps = @($sevFailedNodes.Values | ForEach-Object { $_.Failures } | Where-Object { $_.Title -match 'consistent\s+(\S+)\s+property' } | ForEach-Object { $Matches[1] } | Select-Object -Unique)
                if ($failedProps.Count -gt 0) {
                    $sevDescParts += "Failed - Inconsistent values for $($failedProps -join ', ')"
                } else {
                    $failReasons = @($descriptionSuffix | ForEach-Object { ($_ -replace '^AllNodes:\s*', '').Trim() } | Where-Object { $_ })
                    if ($failReasons.Count -gt 0) {
                        $sevDescParts += "Failed:`n$($failReasons -join "`n")"
                    } else {
                        $sevDescParts += "Failed"
                    }
                }
            } else {
                $sevDescParts += "Failed ($($sevFailedNodes.Count) of ${sevTotalNodes} nodes):`n$($descriptionSuffix -join "`n")"
            }
        }

        # WARNING nodes (status=WARNING, not severity)
        if ($sevWarningNodes.Count -gt 0) {
            $descriptionSuffix = @()
            foreach ($wNodeName in ($sevWarningNodes.Keys | Sort-Object)) {
                $wNodeData = $sevWarningNodes[$wNodeName]
                $sevDetailLines += "- $wNodeName"
                $warnDetailMap = [ordered]@{}
                foreach ($warning in $wNodeData.Warnings) {
                    $warnDetail = if ($warning.AdditionalData.Detail) {
                        $warning.AdditionalData.Detail
                    } else {
                        "$($warning.Name)"
                    }
                    if ($warnDetailMap.Contains($warnDetail)) {
                        $warnDetailMap[$warnDetail]++
                    } else {
                        $warnDetailMap[$warnDetail] = 1
                    }
                }
                $nodeReasons = @()
                foreach ($detail in $warnDetailMap.Keys) {
                    if ($warnDetailMap[$detail] -gt 1) {
                        $sevDetailLines += "  - $detail ($($warnDetailMap[$detail]) instances)"
                        $nodeReasons += "$detail ($($warnDetailMap[$detail]) instances)"
                    } else {
                        $sevDetailLines += "  - $detail"
                        $nodeReasons += $detail
                    }
                }
                $descriptionSuffix += "${wNodeName}: $($nodeReasons -join '; ')"
            }
            $sevDescParts += "Warning ($($sevWarningNodes.Count) of ${sevTotalNodes} nodes):`n$($descriptionSuffix -join "`n")"
        }

        # SUCCESS nodes
        if ($sevPassedNodes.Count -gt 0) {
            foreach ($sNodeName in ($sevPassedNodes.Keys | Sort-Object)) {
                $sNodeData = $sevPassedNodes[$sNodeName]
                $sevDetailLines += "- $sNodeName - $($sNodeData.Total) of $($sNodeData.Total) checks SUCCESS"
            }
            if ($sevIsClusterWide) {
                $checkedProps = @($sevResults | Where-Object { $_.Title -match 'consistent\s+(\S+)\s+property' } | ForEach-Object { $Matches[1] } | Select-Object -Unique)
                if ($checkedProps.Count -gt 0) {
                    $sevDescParts += "Passed - All instances are consistent for $($checkedProps -join ', ')"
                } else {
                    $sevDescParts += "Passed ($($sevResults.Count) of $($sevResults.Count) checks)"
                }
            } else {
                $sevDescParts += "Passed ($($sevPassedNodes.Count) of ${sevTotalNodes} nodes)"
            }
        }

        $sevDescription = "$Description`n$($sevDescParts -join "`n")"
        $sevDetail = $sevDetailLines -join "`n"

        $allResults += @(& $createResult $sevStatus $currentSev $sevDetail $sevTotalNodes $sevDescription)
    }

    return $allResults
}

Export-ModuleMember -Function Get-DeploymentData
Export-ModuleMember -Function Get-IsProxyEnabled
Export-ModuleMember -Function Get-TestCount
Export-ModuleMember -Function Get-TestListByFunction
Export-ModuleMember -Function Select-TestList
Export-ModuleMember -Function Set-TrustedHosts
Export-ModuleMember -Function Test-Count
Export-ModuleMember -Function Test-DesiredProperty
Export-ModuleMember -Function Test-GroupProperty
Export-ModuleMember -Function Test-InstanceCount
Export-ModuleMember -Function Test-InstanceCountByGroup
Export-ModuleMember -Function Test-ModuleUpdate
Export-ModuleMember -Function Test-PropertySync
Export-ModuleMember -Function Test-CimData
Export-ModuleMember -Function Get-FileExclusion
Export-ModuleMember -Function Get-RegionIsUSSecOrUSNat
Export-ModuleMember -Function Get-OptimalParallelJobCount
Export-ModuleMember -Function Invoke-ParallelPerNodeTest
Export-ModuleMember -Function Start-ValidatorTest
Export-ModuleMember -Function New-TestSummaryResult
Export-ModuleMember -Function New-NodeSummaryResult
Export-ModuleMember -Function New-AggregatedTestResult
Export-ModuleMember -Function New-LightweightResult

# Push Utilities functions to global scope for cross-module access.
# All 30+ validator modules call functions from Utilities (Test-ModuleUpdate,
# Select-TestList, Get-TestCount, etc.) but as NestedModules of the psd1
# they can't see sibling modules' functions without global scope.
# We set each function directly in global scope to avoid Import-Module
# recursion when the parent psd1 is loaded with -Force.
foreach ($exportedFunc in @(
    'Get-DeploymentData', 'Get-IsProxyEnabled', 'Get-TestCount',
    'Get-TestListByFunction', 'Select-TestList', 'Set-TrustedHosts',
    'Test-Count', 'Test-DesiredProperty', 'Test-GroupProperty',
    'Test-InstanceCount', 'Test-InstanceCountByGroup', 'Test-ModuleUpdate',
    'Test-PropertySync', 'Test-CimData', 'Get-FileExclusion',
    'Get-RegionIsUSSecOrUSNat', 'Get-OptimalParallelJobCount',
    'Invoke-ParallelPerNodeTest', 'Start-ValidatorTest',
    'New-TestSummaryResult', 'New-NodeSummaryResult', 'New-AggregatedTestResult',
    'New-LightweightResult'
)) {
    $fn = Get-Item "function:$exportedFunc" -ErrorAction SilentlyContinue
    if ($fn) { Set-Item "function:global:$exportedFunc" -Value $fn.ScriptBlock }
}
# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCQPJt3gF75oS0v
# o6uoo4/8DRjmLuPUy8UIDEy5Tzm1haCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIM5bFEMJ6BBsKhKAR5hp/jrDGMQ5BOaaHiOHYZFUFSfyMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAzvRt3S/4e//42NigI6RN
# 0UqB4GSpXDAHN/csciyklLmydvvW/MFaQGFbzuqIsfdSIz2yG+eKG6CIjEpSeXEH
# vNwr3Egb04ePGgMUZ+XDFg6x5jndD9BdjgBczxfJwNXlKd2/JMKZg1OHmEW6Suv6
# fRLi2V97cpdVsQxTce2Ea7MpPJN5o9OnGxp9IdQMZF9JjGJxhnr6qZIyimqt2hiV
# iOGbSt2SFx8Y6exsdq3SNpzkMYetm2Pwps+ApQMndFGSTBBakqmD2Nec7cF/C4sU
# IRkpIi1SJJnROyUD1fdO3B4Vx3GDKBMuOidpUbIjMLDBYBjilypsHiPul7i/jKFU
# wqGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBCyD/Y+kCwzgg7cVuh
# ak4hz8ziYB0GC9B3u9b7K3aP4wIGaev4hL/nGBMyMDI2MDUwMzE0MzExMC4yMjFa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0MzFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACHUvAkoc4hX45AAEAAAIdMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgzM1oXDTI2MTExMzE4
# NDgzM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjQzMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAorSgaAA8oOl4ph574zw29egUN8DDepRHLX8FM1zHNJmXG6Kr
# SqUKwzcKafopuYdPTETTCvb9aJfESuAU0iGNUFI/D6R0kvdfpe2oPX+E3sbTQvGi
# 4JPH5qdIYUaJ45V/4bqe8eNvbWzpC+ZKjH193DeiI1XAI918JoQmBhlEXo/Ton17
# 21luZJgincsf5LjMY3jX84WyXUSX3dsS7h/7xVI+w1yjg7pa+0y3o/me2Tsv6UJU
# dSTQap5ORGSfCnclnP1z3IiiWIWr3Vo7aIPWsgJzq3m5GxpxUHCQk8qzUhk50y/u
# B+LGE3WIK2C77iy9iFsSfSLUnyMEzGRDW9mXHT4PH7Ozz6CHqQEiNvwcHqlvlCh1
# pHQh1NXQSAqOoVBs5mi6easf6yxWTfe5DrR79503r8pU6VqC2Y9XMRU4wH9QbYXY
# sIUZ33Jmndy22W1LBDAbxBPQHCBlncGDU3BgdhVUVLe80mggFO98FdkWho67w4kP
# dCTRkvdvkY8PrQYE/nQjHXCa0g7LcMttZb6ejMHfQ+tUWXv6+nZ4Ynkr2OkaxclF
# Cw4RIYNMWD26AWbQj/WEdzga18fKtw66L5gzXPza6jFBfPJeKE3H8QAuwpirmH4m
# s+5nUjNNQOmNgqJn0U1+3Yn7ClswD79YN0r3fdbYBMDApBZJpNlK7q7HXRsCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBSEWfBxNEamZtXm8gl92Yq80jfxXTAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAkdweB4yxvLspLKq0D+miyD4Q0EcxVFpNZuJxiR54
# gWRkeTDDuymNeB03JhlsBpbwSYJ5uZSgDBCvwHED2VL8lJpFlOprJzxsXWC2NTfA
# +O+PO5Fk5jw6LHh6jeBADDEdQAx3Hqi7Zm0JwvQ93z5f6dtxkm29WqOcHYXRXfAQ
# wy1hSrLXyfeblqR66jpP/9n0fCkWU4ggsUjQpQ2Ngj1DV09J4Y3y7p9Nd81+Xs6q
# Yo++7RKm8qiB/5NDeigOLjlAeFgiEXIRUJW+mJyqpQw+OORlaqcFjR8Hu0G+/7bM
# dek68YX+kPpDBk7Ue+I/xgiYJ1xcDRBn/vczLtN72+RIlD4UgXYLuBSCk//pDEPX
# 5z39Cr+rkc6E4Y28FPk4BhloAyvp628P4xfElQY8TcxraUbZShypocE6ny95D1K1
# BkltZmrHVKCxmglnuOlM15NKIrXFlXCzdqpCtIwQ417wNAVF/QDPvzzbumPdTi6f
# b0tLbScYobV6zvbBsMsKEME4Tj1b9oIXC8dybJq4nbboEXYpRwi1QAbpSNrn+PxG
# W9uf1q63FnMJu4gm3Oh63njW/iVf723quzyHrSijWMgY0HiRiHQi0Jyu0h8MdhRU
# p7mxbmLQckPiOFwAlIaUN/k725y/aLWpkRU6fqmLlEOyH5WpyLd23AYy9r8v+Qob
# a6swggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0MzFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAuoO+BKbfXzqyfi9GLEdWHkCLeT+ggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hqzEwIhgPMjAyNjA1MDMx
# MTA4MzNaGA8yMDI2MDUwNDExMDgzM1owdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7aGrMQIBADAHAgEAAgJABzAHAgEAAgISQjAKAgUA7aL8sQIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQAB+igm6pMc0E4CRHZbcNNYYAL6QMEQa1pyhEMJzMkb
# y55JqRu1JwjrzJ+g3pdvfdcrJsBzpvIj//sInV/OxcTjSISmakjvvMf5wMYoRQns
# Ow0zn7XG+Owg3nTm78mv3JdeHylAtXxaGTaj3w++TjdbseyjNR1A80kT3lfAVVap
# F+4V0eFp1ac6obyDfMeIgbRBfRx42Z/vPqTNGZSvTsZT3fnmn43jBwQ5yAjrlmWk
# 09wAUX61nQkFXZudrcJjMQDXjfZb1Yw3axlamt+uNISXjmN1MYhi20iKfSxXuNu+
# mV2duf7jZqXw8qUtK8bwU3pRmMJjUwItVfnzZAOUbW0lMYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIdS8CShziFfjkAAQAA
# Ah0wDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgT2/RGanG9/On8Fh/IQNcviaE6ffJBHImikuI1KOf
# 95IwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCxtpXMXEiLJzrqM77ep4rT
# NwrMOj6gpWN9hZvpj5QFUTCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACHUvAkoc4hX45AAEAAAIdMCIEIGY/WMYNzSMiD7/PUVvpyWmX
# j4F1dbuZEiYSbsNkqQniMA0GCSqGSIb3DQEBCwUABIICAIl9iakSCpVo4J7UNCHw
# KyAPiThwsNbarj8COs5XMvrOKr7B+w/tu9GND7a+0oGWokAM175MD0UhjX0tbe0p
# o+Ma4obc6GVL34qxtACYf1IaM0WCjTAGbgkmtStbMxX9jbc6SKPzX/MpZbQyhb3J
# E7YJdlXPglPLqTwrjR2AQpSoUKyk/dpd6eiJupQhaRy8KTzz7zCZdbjMbz3n2C3A
# h5zPlvQqli44iZmmFGwmGmHkOgnRkXEwYRsGcH4cN/QCaM8CHqbL2YX4lSbTUoTw
# yTPJ1xNg2jIhZTElJO0thTOdSU4bGMgsHnpQ0O/NZK9i+AYhoY57p0tJHx9fLspA
# GOrCdRVDIKCPWBnCVz5Y1B8ruOyTDMiZ9hS9qS6kcUArgwDhSpfYRTmHKJF6nodn
# LULGt7Ym52kVX1Z+1D6lja8TP+8zi40j5fcYWQCIQIZS2C2YD/e2EEOMu46p3CoF
# KzfMmIL7rUxRey8SnUmTcHzu9CHUXNKiwBC2xx8nitLsMGJRHbHZews/eq8LN6M/
# +WPG0zQRUPJ1y4ZuscvGi9IKBvP4wvLuouv8DuhEKZUiCj1kwSFTGaSJHjG/f3mE
# QCsJ1GWKgKTJtPovFRq7ACQl8hbGs1IelX5ntOKt4eMZO88JyFi+yfAbPCSw3rju
# LnwKMby9MSFR8DpmfATl/eNd
# SIG # End signature block
