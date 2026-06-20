class AzStackHciConnectivityTarget
{
    # Attributes for Azure Monitor schema
    [string]$Name #Name of the individual test/rule/alert that was executed. Unique, not exposed to the customer.
    [string]$Title #User-facing name; one or more sentences indicating the direct issue.
    [string]$Severity #Severity of the result (Critical, Warning, Informational, Hidden) – this answers how important the result is. Critical is the only update-blocking severity.
    [string]$Description #Detailed overview of the issue and what impact the issue has on the stamp.
    [psobject]$Tags #Key-value pairs that allow grouping/filtering individual tests. For example, "Group": "ReadinessChecks", "UpdateType": "ClusterAware"
    [string]$Status #The status of the check running (i.e. Failed, Succeeded, In Progress) – this answers whether the check ran, and passed or failed.
    [string]$Remediation #Set of steps that can be taken to resolve the issue found.
    [string]$TargetResourceID #The unique identifier for the affected resource (such as a node or drive).
    [string]$TargetResourceName #The name of the affected resource.
    [string]$TargetResourceType #The type of resource being referred to (well-known set of nouns in infrastructure, aligning with Monitoring).
    [datetime]$Timestamp #The Time in which the HealthCheck was called.
    [psobject[]]$AdditionalData #Property bag of key value pairs for additional information.
    [string]$HealthCheckSource #The name of the services called for the HealthCheck (I.E. Test-AzureStack, Test-Cluster).

    # Attribute for performing check
    [string[]]$EndPoint
    [string[]]$Protocol

    # Additional Attributes for end user interaction
    [string[]]$Service # short cut property to Service from tags
    [string[]]$OperationType # short cut property to Operation Type from tags
    [string[]]$Group # short cut property to group from tags
    [bool]$Mandatory # short cut property to mandatory from tags
    [bool]$System # targets for system checks such as proxy traversal
    [string]$Region # Region of the target
    [bool]$ArcGateway # Support by Arc Gateway and hence does not need checking explicitly
}

class AzStackHciConnectivityManifest
{
    [string]$Title
    [System.Version]$Version
    [PsObject[]]$Targets
}

Import-LocalizedData -BindingVariable lcTxt -FileName AzStackHci.Connectivity.Strings.psd1

function Get-AzStackHciConnectivityServiceName
{
    <#
    .SYNOPSIS
        Retrieve Services from built target packs
    .DESCRIPTION
        Retrieve Services from built target packs
    .EXAMPLE
        PS C:\> Get-AzStackHciServices
        Explanation of what the example does
    .INPUTS
        Service
    .OUTPUTS
        PSObject
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Service,

        [Parameter(Mandatory = $false)]
        [switch]
        $IncludeSystem
    )
    try
    {
        Get-AzStackHciConnectivityTarget -IncludeSystem:$IncludeSystem | Select-Object -ExpandProperty Service | Sort-Object | Get-Unique
    }
    catch
    {
        throw "Failed to get services names. Error: $($_.Exception.Message)"
    }
}

function Get-AzStackHciConnectivityOperationName
{
    <#
    .SYNOPSIS
        Retrieve Operation Types from built target packs
    .DESCRIPTION
        Retrieve Operation Types from built target packs e.g. Deployment, Update, Secret Rotation.
    .EXAMPLE
        PS C:\> Get-AzStackHciConnectivityOperationName
        Explanation of what the example does
    .INPUTS
        Service
    .OUTPUTS
        PSObject
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $OperationType
    )
    try
    {
        Get-AzStackHciConnectivityTarget | Select-Object -ExpandProperty OperationType | Sort-Object | Get-Unique
    }
    catch
    {
        throw "Failed to get services names. Error: $($_.Exception.Message)"
    }
}

function Get-AzStackHciConnectivityTarget
{
    <#
        .SYNOPSIS
            Retrieve Endpoints from built target packs
        .DESCRIPTION
            Retrieve Endpoints from built target packs
        .EXAMPLE
            PS> Get-AzStackHciConnectivityTarget
            Get all connectivity targets
        .EXAMPLE
            Get-AzStackHciConnectivityTarget -Service ARC | ft Name, Title, Service, OperationType -AutoSize
            Get all ARC connectivity targets
        .EXAMPLE
            PS> Get-AzStackHciConnectivityTarget -Service ARC -OperationType Workload | ft Name, Title, Service, OperationType -AutoSize
            Get all ARC targets for workloads
        .EXAMPLE
            PS> Get-AzStackHciConnectivityTarget -OperationType Workload | ft Name, Title, Service, OperationType -AutoSize
            Get all targets for workloads
        .EXAMPLE
            PS> Get-AzStackHciConnectivityTarget -OperationType ARC -OperationType Update -Additive | ft Name, Title, Service, OperationType -AutoSize
            Get all ARC targets and all targets for Update
        .INPUTS
            Service - String array
            OperationType - String array
            Additive - Switch
        .OUTPUTS
            PSObject
        .NOTES
    #>
    [CmdletBinding()]
    param (

        [Parameter(Mandatory = $false)]
        [string[]]
        $Service,

        [Parameter(Mandatory = $false)]
        [string[]]
        $OperationType,

        [Parameter(Mandatory = $false)]
        [switch]
        $Additive,

        [Parameter(Mandatory = $false)]
        [switch]
        $IncludeSystem,

        [Parameter(Mandatory = $false)]
        [switch]
        $LocalOnly,

        [Parameter()]
        [system.uri]
        $Uri = 'https://aka.ms/hciconnectivitytargets',

        [Parameter()]
        [psobject[]]
        $RuntimeConnectivityTarget,

        [Parameter()]
        [string]
        $RegionName,

        [Parameter()]
        [switch]
        $ARCGateway

    )
    try
    {
        $executionTargets = @()
        if (Get-RegionIsUSSecOrUSNat -RegionName $RegionName)
        {
            Write-Verbose -Message "Region Is USSec or USNat. Testing no connectivity targets for $RegionName"
            return $executionTargets
        }

        Import-AzStackHciConnectivityTarget -LocalOnly:$LocalOnly -Uri $Uri -RuntimeConnectivityTarget $RuntimeConnectivityTarget -RegionName $RegionName

        # Additive allows the user to "-OR" their parameter values
        if ($Additive)
        {
            Write-Verbose -Message "Getting targets additively"
            if (-not [string]::IsNullOrEmpty($Service))
            {
                Write-Verbose -Message ("Getting targets by Service: {0}" -f ($Service -join ','))
                foreach ($svc in $Service)
                {
                    $executionTargets += $Script:AzStackHciConnectivityTargets | Where-Object { $svc -in $_.Service }
                }
            }
            if (-not [string]::IsNullOrEmpty($OperationType))
            {
                Write-Verbose -Message ("Getting targets by Operation Type: {0}" -f ($OperationType -join ','))
                foreach ($Op in $OperationType)
                {
                    $executionTargets += $Script:AzStackHciConnectivityTargets | Where-Object { $Op -in $_.OperationType }
                }
            }
            if ([string]::IsNullOrEmpty($OperationType) -and [string]::IsNullOrEmpty($Service))
            {
                $executionTargets += $Script:AzStackHciConnectivityTargets
            }
        }
        else
        {
            if ([string]::IsNullOrEmpty($OperationType) -and [string]::IsNullOrEmpty($Service))
            {
                $executionTargets += $Script:AzStackHciConnectivityTargets
            }
            elseif (-not [string]::IsNullOrEmpty($Service) -and [string]::IsNullOrEmpty($OperationType))
            {
                Write-Verbose -Message ("Getting targets by Service: {0}" -f ($Service -join ','))
                foreach ($svc in $Service)
                {
                    $executionTargets += $Script:AzStackHciConnectivityTargets | Where-Object { $svc -in $_.Service }
                }
            }
            elseif (-not [string]::IsNullOrEmpty($OperationType) -and [string]::IsNullOrEmpty($Service))
            {
                Write-Verbose -Message ("Getting targets by Operation Type: {0}" -f ($OperationType -join ','))
                foreach ($Op in $OperationType)
                {
                    $executionTargets += $Script:AzStackHciConnectivityTargets | Where-Object { $Op -in $_.OperationType }
                }
            }
            else
            {
                Write-Verbose -Message ("Getting targets by Operation Type: {0} and Service: {1}" -f ($OperationType -join ','), ($Service -join ','))
                $executionTargetsByOp = @()
                foreach ($Op in $OperationType)
                {
                    $executionTargetsByOp += $Script:AzStackHciConnectivityTargets | Where-Object { $Op -in $_.OperationType }
                }
                foreach ($svc in $Service)
                {
                    $executionTargets += $executionTargetsByOp | Where-Object { $svc -in $_.Service }
                }
            }
        }

        # Always add Mandatory targets
        $executionTargets += $Script:AzStackHciConnectivityTargets | Where-Object Mandatory | ForEach-Object {
            if ($PSITEM -notin $executionTargets)
            {
                $PSITEM
            }
        }

        # Check the local agent incase we haven't been passed the ARCGateway switch
        if (-not $ARCGateway)
        {
            $ARCGateway = Get-AzStackHciARCGatewaySetting
        }

        if ($ARCGateway)
        {
            # Log substractions
            $substractions = $executionTargets | Where-Object { $_.ARCGateway }
            Write-Verbose "Removing the following definitions due to ARCGateway support: $($substractions | Format-table Name, ARCGateway, EndPoint | Out-String)"
            # Any endpoint defined as an ARCGateway does not need to be checked explicitly
            $executionTargets = $executionTargets | Where-Object { !$_.ARCGateway }
        }

        # AzureLocal should only be AzureLocal
        # Fairfax should only be Fairfax
        # Regular regions should be region + global e.g. EastUS + Global
        if ($RegionName -eq 'AzureLocal')
        {
            $executionTargets = $executionTargets | Where-Object { $_.Region -eq 'AzureLocal' }
        }
        elseif ($RegionName -eq 'usgovvirginia')
        {
            $executionTargets = $executionTargets | Where-Object { $_.Region -eq 'usgovvirginia' }
        }
        else
        {
            $executionTargets = $executionTargets | Where-Object { $RegionName -in $_.Region -or 'Global' -in $_.Region }
        }

        if ($IncludeSystem)
        {
            return $executionTargets
        }
        else
        {
            return ($executionTargets | Where-Object Service -NotContains 'System')
        }
    }
    catch
    {
        throw "Get failed: $($_.exception)"
    }
}

function Validate-RuntimeConnectivityTarget
{
    <#
    .SYNOPSIS
        Validate Runtime Connectivity Target
    .DESCRIPTION
        Validate Runtime Connectivity Target
    .EXAMPLE
        PS C:\> Validate-RuntimeConnectivityTarget
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject[]]
        $RuntimeConnectivityTarget
    )
    try
    {
        foreach ($target in $RuntimeConnectivityTarget)
        {
            # this maybe bolstered to include more checks as needed like valid hostname, valid protocol, etc.
            ##### QUESTION: should we only allow 1 endpoint and 1 protocol per custom rule?
            if (-not $target.DisplayName -or $target.DisplayName -isnot [string])
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f "DisplayName", 'a String'
            }
            if (-not $target.Description -or $target.Description -isnot [string])
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f "Description", 'a String'
            }
            if (-not $target.Service -or $target.Service -isnot [System.Array])
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f "Service", 'an Array'
            }
            if (-not $target.EndPoint -or $target.EndPoint -isnot [System.Array])
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f  "EndPoint", 'an Array'
            }
            if (-not $target.Protocol -or $target.Protocol -notmatch 'http|https')
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f "Protocol", 'http or https'
            }
            if (-not $target.Severity -or $target.Severity -notmatch 'CRITICAL|WARNING')
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f "Severity", 'CRITICAL or WARNING'
            }
            if (-not $target.Remediation -or $target.Remediation -notmatch 'https?://.*')
            {
                throw $lcTxt.RuntimeConnectivityTargetFailed -f "Remediation", 'a URL'
            }
        }
    }
    catch
    {
        throw $_
    }

}

function Validate-CustomDefinitionUri
{
    <#
    .SYNOPSIS
        Validate Custom Definition Uri
    .DESCRIPTION
        Validate Custom Definition Uri
    .EXAMPLE
        PS C:\> Validate-CustomDefinitionUri -Uri $Uri
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [system.uri]
        $Uri
    )
    try
    {
        if ($Uri.Scheme -ne 'https')
        {
            throw $lcTxt.CustomDefinitionUriFailed -f "Uri"
        }
    }
    catch
    {
        throw $_
    }
}

function Import-AzStackHciConnectivityTarget
{
    <#
    .SYNOPSIS
        Retrieve Endpoints from built target packs
    .DESCRIPTION
        Retrieve Endpoints from built target packs
    .EXAMPLE
        PS C:\> Import-AzStackHciConnectivityTarget
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        PSObject
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [switch]
        $LocalOnly,

        [Parameter()]
        [system.uri]
        $Uri = 'https://aka.ms/hciconnectivitytargets',

        [Parameter()]
        [psobject[]]
        $RuntimeConnectivityTarget,

        [Parameter()]
        [string]
        $RegionName
    )
    try
    {
        $Script:AzStackHciConnectivityTargets = @()
        if (-not $LocalOnly)
        {
            Write-Verbose "Trying to get targets from: $Uri/$RegionName"
            $Script:AzStackHciConnectivityTargets += Get-CloudEndpointFromManifest -Uri "$Uri/$RegionName"
        }

        # if region specific targets are not found, fall back to global targets
        if ((-not $LocalOnly) -and (-not $Script:AzStackHciConnectivityTargets))
        {
            Write-Verbose "Trying to get targets from: $Uri"
            $Script:AzStackHciConnectivityTargets += Get-CloudEndpointFromManifest -Uri $Uri
        }

        if ($Script:AzStackHciConnectivityTargets) {
            return
        }
        else
        {
            # Filter target files based on region to prevent duplicate target definitions in offline validation
            if ($RegionName -eq 'usgovvirginia') {
                $targetFiles = Get-ChildItem -Path "$PSScriptRoot\Targets\*Fairfax*.json" | Select-Object -ExpandProperty FullName
            } else {
                $targetFiles = Get-ChildItem -Path "$PSScriptRoot\Targets\*.json" | Where-Object { $_ -notlike "*Fairfax*" } | Select-Object -ExpandProperty FullName
            }

            Write-Verbose ("Importing {0}" -f ($targetFiles -join ','))
            ForEach ($targetFile in $targetFiles)
            {
                try
                {
                    #  TO DO - Add validations:
                    #  - protocol should not contain ://
                    $targetPackContent = Get-Content -Path $targetFile | ConvertFrom-Json -WarningAction SilentlyContinue
                    foreach ($target in $targetPackContent)
                    {
                        #Set Name of the individual test/rule/alert that was executed. Unique, not exposed to the customer.
                        $target | Add-Member -MemberType NoteProperty -Name HealthCheckSource -Value $ENV:EnvChkrId
                        $target.TargetResourceID = $target.EndPoint -join '_'
                        $target.TargetResourceName = $target.EndPoint -join '_'
                        $target.TargetResourceType = 'External Endpoint'
                        $Script:AzStackHciConnectivityTargets += [AzStackHciConnectivityTarget]$target
                    }
                }
                catch
                {
                    throw ("Unable to read {0}. Error: {1}" -f (Split-Path -Path $targetFile -Leaf), $_.Exception.Message)
                }
            }

            # adding this here so it is subject to any filters (include/exclude/file-based override) that the user may have set
            ##### QUESTION: should this throw an exception if the target is malformed, or continue with the rest of the targets/tests? (currently throws exception)
            if ($RuntimeConnectivityTarget.count -ge 1)
            {
                foreach ($rtTarget in $RuntimeConnectivityTarget)
                {
                    $Script:AzStackHciConnectivityTargets += ConvertTo-AzStackHciConnectivityTarget -RuntimeConnectivityTarget $rtTarget
                }
            }
        }
    }
    catch
    {
        throw "Import failed: $($_.exception)"
    }
}

function ConvertTo-AzStackHciConnectivityTarget
{
    <#
    .SYNOPSIS
        Convert Runtime connectivity (psobject) target to AzStackHciConnectivityTarget
    .DESCRIPTION
        Convert Runtime connectivity (psobject) target to AzStackHciConnectivityTarget
    .EXAMPLE
        PS C:\> ConvertTo-AzStackHciConnectivityTarget -RuntimeConnectivityTarget $RuntimeConnectivityTarget
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject]
        $RuntimeConnectivityTarget
    )
    try
    {
        Log-Info "Converting Runtime Connectivity Target to AzStackHciConnectivityTarget:"
        Log-Info ($RuntimeConnectivityTarget | Out-String)
        $hash = @{
            Name = "AzStackHci_Connectivity_{0}_{1}" -f ($RuntimeConnectivityTarget.Service | Select-Object -first 1), $RuntimeConnectivityTarget.DisplayName -replace '\s', '_'
            Service = $RuntimeConnectivityTarget.Service
            Title = $RuntimeConnectivityTarget.DisplayName
            Severity = $RuntimeConnectivityTarget.Severity
            Description = $RuntimeConnectivityTarget.Description
            Remediation = $RuntimeConnectivityTarget.Remediation
            TargetResourceID = $RuntimeConnectivityTarget.EndPoint -join '_' -replace '\*', 'www'
            TargetResourceName = $RuntimeConnectivityTarget.EndPoint -join '_' -replace '\*', 'www'
            TargetResourceType = 'External Endpoint'
            HealthCheckSource = $ENV:EnvChkrId
            Protocol = $RuntimeConnectivityTarget.Protocol
            EndPoint = $RuntimeConnectivityTarget.EndPoint
            # Any runtime endpoint will need to be global and ARCGateway:false to ensure it is not filtered out
            Region = 'Global'
            ARCGateway = $false
        }
        $target = New-Object -TypeName AzStackHciConnectivityTarget -Property $hash
        return $target
    }
    catch
    {
        throw $_
    }
}

function Get-SigningRootChain
{
    <#
    .SYNOPSIS
        Get signing root for https endpoint
    .DESCRIPTION
        Get signing root for https endpoint
    .EXAMPLE
        PS C:\> Get-SigningRoot -uri MicrosoftOnline.com
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Uri]
        $Uri,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession,

        [Parameter()]
        [string]
        $Proxy,

        [Parameter()]
        [pscredential]
        $proxyCredential
    )
    try
    {
        $sb = {
            $uri = $args[0]
            $proxy = $args[1]
            $proxyCredential = $args[2]
            $GetSslCertChainFunction = $args[3]

            if (-not (Get-Command -Name Get-SslCertificateChain -ErrorAction SilentlyContinue))
            {
                throw "Cannot find Get-SslCertificateChain in AzStackHci.EnvironmentChecker.PortableUtilities module"
            }
            else
            {
                Write-Verbose "Found Get-SslCertificateChain in AzStackHci.EnvironmentChecker.Utilities module"
                $chain = Get-SslCertificateChain -Url $Uri -Proxy $Proxy -ProxyCredential $ProxyCredential
            }
            return $chain.ChainElements.Certificate
        }
        $ChainElements = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList $Uri, $Proxy, $ProxyCredential,${function:Get-SslCertificateChain}
        }
        else
        {
            Invoke-Command -ScriptBlock $sb -ArgumentList $Uri, $Proxy, $ProxyCredential,${function:Get-SslCertificateChain}
        }
        return $ChainElements
    }
    catch
    {
        throw $_
    }
}

function Test-RootCA
{
    <#
    .SYNOPSIS
        Short description
    .DESCRIPTION
        Long description
    .EXAMPLE
        PS C:\> <example usage>
        Explanation of what the example does
    .INPUTS
        Inputs (if any)
    .OUTPUTS
        Output (if any)
    .NOTES
        General notes
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession,

        [Parameter()]
        [string]
        $Proxy,

        [Parameter()]
        [pscredential]
        $ProxyCredential
    )
    try
    {
        if ($Script:AzStackHciConnectivityTargets)
        {
            $rootCATarget = $Script:AzStackHciConnectivityTargets | Where-Object Name -EQ System_Check_SSL_Inspection_Detection
            if ($rootCATarget.count -ne 1)
            {
                throw "Expected 1 System_RootCA, found $($rootCATarget.count)"
            }
            if ($PsSession)
            {
                Copy-RemoteItem -PsSession $PsSession -SourcePath (Join-Path (Split-Path -Parent $PSScriptRoot) "AzStackHci.EnvironmentChecker.PortableUtilities.psm1") -CmdletName "Get-SslCertificateChain"
            }
            # We have two endpoints to check, they expire 6 months apart
            # meaning we should get a warning if criteria needs to change
            # 1 only require 1 endpoint to not be re-encrypted to succeed.
            $rootCATargetUrls = @()
            $rootCATarget.EndPoint | Foreach-Object {
                foreach ($p in $rootCATarget.Protocol) {
                    $rootCATargetUrls += "{0}://{1}" -f $p,$PSITEM
                }
            }

            $AdditionalData = @()

            foreach ($rootCATargetUrl in $rootCATargetUrls) {
                Log-Info "Testing SSL chain for $rootCATargetUrl"
                [array]$ChainElements = Get-SigningRootChain -Uri $rootCATargetUrl -PsSession $PsSession -Proxy $Proxy -ProxyCredential $ProxyCredential
                # This is our canary internet endpoint, if we can't get the chain we probably don't have internet access.
                if ($null -eq $ChainElements)
                {
                    $Status = 'FAILURE'
                    $detail = "Failed to get certificate chain for $rootCATargetUrl. Ensure the endpoint is accessible and proxy configuration is correct."
                    Log-Info $detail -Type Warning
                }
                else
                {
                    # Remove the leaf as this will always contain O=Microsoft in its subject
                    $ChainElements = $ChainElements[1..($ChainElements.Length-1)]
                    $subjectMatchCount = 0
                    # We check for 2 expected subjects and only require 1 to succeed
                    $rootCATarget.Tags.ExpectedSubject | Foreach-Object {
                        if ($ChainElements.Subject -match $PSITEM)
                        {
                            $subjectMatchCount++
                        }
                    }
                    if ($subjectMatchCount -ge 1)
                    {
                        $Status = 'SUCCESS'
                        $detail = "Expected at least 1 chain certificate subject to match $($rootCATarget.Tags.ExpectedSubject -join ' or '). $subjectMatchCount matched."
                        Log-Info $detail
                    }
                    else
                    {
                        $Status = 'FAILURE'
                        $detail = "Expected at least 1 chain certificate subjects to match $($rootCATarget.Tags.ExpectedSubject -join ' or '). $subjectMatchCount matched. Actual subjects $($ChainElements.Subject -join ','). SSL decryption and re-encryption detected."
                        Log-Info $detail -Type Error
                    }
                }
                $AdditionalData += @{
                    Source    = if ([string]::IsNullOrEmpty($PsSession.ComputerName)) { $ENV:COMPUTERNAME } else { $PsSession.ComputerName }
                    Resource  = $rootCATargetUrl
                    Status    = $Status
                    Detail    = $detail
                    TimeStamp = [datetime]::UtcNow
                }
            }

            $result = @()
            $result += $AdditionalData | ForEach-Object {
                $params = @{
                    Name               = $rootCATarget.Name
                    Title              = $rootCATarget.Title
                    DisplayName        = $rootCATarget.Title
                    Severity           = $rootCATarget.Severity
                    Description        = $rootCATarget.Description
                    Tags               = @{
                        Service = 'System'
                        Mandatory = $true
                    }
                    Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-checklist'
                    TargetResourceID   = "$($PsItem.Source)/$($PsItem.Resource)"
                    TargetResourceName = $PsItem.Resource
                    TargetResourceType = $rootCATarget.TargetResourceType
                    Timestamp          = $PsItem.TimeStamp
                    Status             = $PsItem.Status
                    AdditionalData     = $PsItem
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                New-AzStackHciResultObject @params
            }
            return $result
        }
        else
        {
            throw "No AzStackHciConnectivityTargets"
        }
    }
    catch
    {
        Log-Info "Test-RootCA failed with error: $($_.exception.message)" -Type Warning
    }
}

function Get-UniqueEndpoint
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsObject]
        $Target
    )
    # Build list of unique endpoints
    $uriList = @()
    foreach ($t in $Target)
    {
        foreach ($u in $t.EndPoint)
        {
            foreach ($p in $t.Protocol)
            {
                $uriList += "{0}://{1}" -f $p.tolower(), ($u -Replace '\*', 'www')
            }
        }
    }
    Log-Info "Uri Count (total): $($uriList.count)"
    $uriList = $uriList | Sort-Object -Unique
    Log-Info "Uri Count (Unique): $($uriList.count)"
    return $uriList
}

function Invoke-WebRequestEx
{
    <#
    .SYNOPSIS
        Get Connectivity via Invoke-WebRequest
    .DESCRIPTION
        Get Connectivity via Invoke-WebRequest, supporting proxy.
        This function takes a connectivity target definition, creates a PS(5) Job for each endpoint and protocol and returns the results.
        If PsSession is provided, the jobs are run on the remote machine.
        Success is defined as a 200 status code or a valid status code (not service available),
        with a GET method and the response Uri is the same as the request Uri.
    .EXAMPLE
        PS C:\> Invoke-WebRequestEx -Target $Target
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
        In the case of a proxy being provided, the proxy is used for all endpoints.
        In the case of a proxy being configured on the box, invoke-webrequest will use the wininet proxy for all calls.
        Certificate Validation is disabled for the calls.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject[]]
        $Target,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter()]
        [string]
        $Proxy,

        [Parameter()]
        [pscredential]
        $ProxyCredential

    )

    if (-not $Target)
    {
        Log-Info "No targets to test. Returning No_Target result"
        $params = @{
            Name               = 'AzStackHci_Connectivity_No_Targets'
            Title              = 'No Connectivity Targets to Test'
            DisplayName        = 'No Connectivity Targets to Test'
            Severity           = 'INFORMATIONAL'
            Description        = 'No Connectivity Targets to Test'
            Tags               = @{
                Service        = $_.Service
                Mandatory      = $_.Mandatory
                ARCGateway     = $_.ARCGateway
                Region         = $_.Region
            }
            Remediation        = 'No action required'
            TargetResourceID   = $PsSession -join ','
            TargetResourceName = $PsSession -join ','
            TargetResourceType = 'Endpoint'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{}
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return (New-AzStackHciResultObject @params)
    }
    $Target | Add-Member -MemberType NoteProperty -Name TimeStamp -Value [datetime]::UtcNow -Force
    $ScriptBlock = {
        $Uri = $args[0]
        $TimeoutSecs = $args[1]
        $maxJobs = $args[2]
        $Proxy = $args[3]
        $ProxyCredential = $args[4]

        $timeoutSecondsDefault = 10
        if ([string]::IsNullOrEmpty($TimeoutSecs))
        {
            $timeout = $timeoutSecondsDefault
        }
        else
        {
            $timeout = $TimeoutSecs
        }
        # Create an array of jobs for all uris and protocols
        $inProgressJobList = @()
        $totalJobList = @()
        $results = @()
        foreach ($u in $uri)
        {
            $iwrScriptBlock = {
                # Define function for tracing redirects to enhance diagnostics
                function Trace-Redirects
                {
                    param (
                        [Parameter(Mandatory = $true)]
                        [hashtable]$iwrSplat
                    )
                    # Run invoke-webrequest while headers are being redirected
                    $traceLog = ""
                    # Don't double up on MaximumRedirection if already set
                    if (-not $iwrSplat.ContainsKey('MaximumRedirection'))
                    {
                        $iwrSplat.Add('MaximumRedirection', 0)
                    }
                    $maximumRedirectsCount = 5 # guard against too many redirects
                    $redirectCount = 0
                    do {
                        $redirectCount++
                        try {
                            $traceLog += "Testing {0}... " -f $iwrSplat.Uri
                            $traceOutput = Invoke-WebRequest @iwrSplat -ea SilentlyContinue
                            if ($traceOutput.StatusCode -ge 300 -and $traceOutput.StatusCode -lt 400)
                            {
                                if ($traceOutput.Headers.Location -ne $null)
                                {
                                    $traceLog += "Redirected ({0})`r`n" -f $traceOutput.StatusCode
                                    $iwrSplat.Uri = $traceOutput.Headers.Location
                                }
                                else
                                {
                                    $traceLog += "Headers Location Empty. Not expected"
                                    break
                                }
                            }
                            else
                            {
                                    $traceLog += ("StatusCode: {0}`r`n" -f $traceOutput.StatusCode)
                                    break
                            }
                        }
                        catch
                        {
                            $traceLog += "Exception: {0}" -f $_.Exception.Message
                            break
                        }
                    }
                    while (($traceOutput.StatusCode -ge 300 -and $traceOutput.StatusCode -lt 400) -or $redirectCount -lt $maximumRedirectsCount)
                    # only return traceLog if we have a redirect else the original response/exception is sufficient
                    if ($redirectCount -gt 1)
                    {
                        return $traceLog
                    }
                    else
                    {
                        return $null
                    }
                }

                # Test endpoint
                $retry = 0
                $maxRetry = 3
                do {
                    $retry++
                    if ($retry -gt 1)
                    {
                        Start-Sleep -Seconds 5
                    }

                    try
                    {
                        $uri = $args[0]
                        $proxy = $args[1]
                        $proxyCred = $args[2]
                        $Timeout = $args[3]
                        $iwrParams =@{
                            Uri = $Uri
                            UseBasicParsing = $true
                            TimeoutSec = 30
                            MaximumRedirection = 0
                            ErrorAction = 'SilentlyContinue'
                        }

                        # Ignore certificate validation and use TLS 1.2
                        if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type)
                        {
                            $certCallback = @"
                            using System;
                            using System.Net;
                            using System.Net.Security;
                            using System.Security.Cryptography.X509Certificates;
                            public class ServerCertificateValidationCallback
                            {
                                public static void Ignore()
                                {
                                    if(ServicePointManager.ServerCertificateValidationCallback == null)
                                    {
                                        ServicePointManager.ServerCertificateValidationCallback +=
                                            delegate
                                            (
                                                Object obj,
                                                X509Certificate certificate,
                                                X509Chain chain,
                                                SslPolicyErrors errors
                                            )
                                            {
                                                return true;
                                            };
                                    }
                                }
                            }
"@
                            $null = Add-Type $certCallback
                            $null = [ServerCertificateValidationCallback]::Ignore()
                            $null = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        }

                        if ($proxy) {
                            $iwrParams.Add('Proxy', $proxy)
                            $iwrParams.Add('ProxyUseDefaultCredentials', $true)
                        }

                        if ($proxyCred) {
                            $iwrParams.Remove('ProxyUseDefaultCredentials')
                            $iwrParams.Add('ProxyCredential', $proxyCred)
                        }
                        $stopwatch = [System.Diagnostics.Stopwatch]::new()
                        $Stopwatch.Start()
                        $webOut = Invoke-WebRequest @iwrParams
                        $Stopwatch.Stop()
                        $statusCode = $webout.StatusCode
                        $webResponse = $webOut.BaseResponse
                        $headers = $webOut.Headers
                        $content = $webOut.Content
                    }
                    catch {
                        if ($stopwatch.IsRunning)
                        {
                            $stopwatch.Stop()
                        }
                        $webResponse = $_.Exception.Response

                        if ($webResponse) {
                            try {
                                $statusCode = [int]$webResponse.StatusCode
                                $headers = @{}
                                $content = [System.Text.Encoding]::UTF8.GetString($webResponse.GetResponseStream().ToArray())
                                foreach ($header in $webResponse.Headers) {
                                    $headers.$header = $webResponse.GetResponseHeader($header)
                                }
                                if ($webResponse.ContentType -eq 'application/json') {
                                    $content = ConvertFrom-Json -InputObject $content
                                }
                            }
                            catch {}
                        }
                        $exception = @{ExceptionMessage = $_.Exception.Message; ErrorDetails = $_.ErrorDetails.Message; NonHTTPFailure = [System.String]::IsNullOrEmpty($webResponse) }
                    }

                    # Response Analysis
                    # if status code is 200 return true
                    # otherwise if the status code is a HTTP status code and the response Uri is the same as the request Uri and the method is GET, return true
                    $isHttpStatusCode = $webResponse.StatusCode -is [System.Net.HttpStatusCode]
                    $responseUriMatch = ([system.uri]$webResponse.ResponseUri).Host -eq ([system.uri]$uri).Host
                    $responseMethodIsGet = $webResponse.Method -eq 'GET'
                    $serviceUnavailable = $webResponse.StatusCode -eq [System.Net.HttpStatusCode]::ServiceUnavailable
                    $isRedirect = $webResponse.StatusCode -ge 300 -and $webResponse.StatusCode -lt 400
                    $test = $webResponse.StatusCode -eq [System.Net.HttpStatusCode]::OK -or ($isHttpStatusCode -and $responseUriMatch -and $responseMethodIsGet -and !$serviceUnavailable) -or $isRedirect

                    # If needed, fetch redirect location for telemetry
                    $redirectLocation = "No redirect."
                    if ($isRedirect)
                    {
                        $redirectLocation = $webResponse.Headers['Location']
                    }

                    # Initialize some strings to feedback to the user in the detail field. Debug field still remains for troubleshooting with log.
                    $Detail = ""
                    $Detail += "Test Analysis - Overall Result: $test`r`n"
                    $WebResponseDetail = ""
                    $TestAnalysisDetail = ""
                    $CertificateChainDetail = ""
                    $RedirectAnalysisDetail = ""
                    $ExceptionDetail = ""

                    # Gather TCP net connection to test connectivity if it failed.
                    if (-not $test -and $retry -eq $maxRetry)
                    {
                        # We will try to get the certificate chain and redirect analysis
                        $TestAnalysisDetail += "Test Analysis - Exception Message: $($exception.ExceptionMessage)`r`n"
                        try
                        {
                            Import-Module AzStackHci.EnvironmentChecker -ErrorAction SilentlyContinue
                            $CertificateChainOutput = Get-SslCertificateChain -url $Uri | Select-Object -ExpandProperty ChainElements | Select-Object -Expand Certificate | ForEach-Object { $_.Subject } | Out-String
                            $CertificateChainDetail += $CertificateChainOutput
                        }
                        catch
                        {
                            $CertificateChainDetail += "Failed to get certificate chain for $Uri. Error: $($_.Exception.Message)`r`n"
                        }
                        try
                        {
                            $RedirectOutput = Trace-Redirects -iwrSplat $iwrParams | Out-String
                            $RedirectAnalysisDetail += $RedirectOutput
                        }
                        catch
                        {
                            $RedirectAnalysisDetail += "Failed to get redirect analysis for $Uri. Error: $($_.Exception.Message)`r`n"
                        }
                        $tnc = Test-NetConnection -ComputerName ([system.uri]$uri).Host -Port ([system.uri]$uri).Port -InformationLevel Quiet -WarningAction SilentlyContinue
                        $TestAnalysisDetail += "Test Analysis - Layer 3 (tnc): $tnc`r`n"
                    }

                    # web response detail
                    if ($isHttpStatusCode)
                    {
                        $WebResponseDetail += "`r`nWeb Response Data - StatusCode: $statusCode`r`n"
                        $WebResponseDetail += "Web Response Data - RequestUri: $uri`r`n"
                        $WebResponseDetail += "Web Response Data - ResponseUri: $($webResponse.ResponseUri)`r`n"
                        $WebResponseDetail += "Web Response Data - Method: $($webResponse.Method)`r`n"
                        $WebResponseDetail += "Web Response Data - Server: $($webResponse.Server)`r`n"
                        $WebResponseDetail += "`r`nWeb Response Analysis - ServiceUnavailable: $serviceUnavailable`r`n"
                        $WebResponseDetail += "Web Response Analysis - ResponseUriHostMatch: $responseUriMatch`r`n"
                        $WebResponseDetail += "Web Response Analysis - ResponseMethodIsGet: $responseMethodIsGet`r`n"
                    }
                    else
                    {
                        $WebResponseDetail += "Web Response Analysis - Not Applicable, no web response received`r`n"
                    }

                    # ExceptionDetail
                    if ($exception)
                    {
                        $ExceptionDetail += "Exception Data - ExceptionMessage: $($exception.ExceptionMessage)`r`n"
                    }

                    # Add all the details to the final output
                    $Detail += $TestAnalysisDetail
                    $Detail += "$WebResponseDetail`r`n"
                    $Detail += if (!$test) { "TLS Data:`r`n$CertificateChainDetail`r`n" }
                    $Detail += if (!$test) { "Redirect Data:`r`n$RedirectAnalysisDetail`r`n" }
                    $Detail += if (!$test) { "`r`n$ExceptionDetail`r`n" }

                    # Add more simple redirect detail if test passes
                    if ($isRedirect)
                    {
                        $Detail += "Redirected to $redirectLocation`r`n"
                    } elseif ( $test ) {
                        $Detail += "No redirect detected.`r`n"
                    }

                } while ($test -eq $false -and $retry -lt $maxRetry)
                return @{
                    Source              = $env:ComputerName
                    Retry               = "$retry / $maxRetry"
                    LatencyInMs         = $stopwatch.ElapsedMilliseconds
                    ExceptionMessage    = $Exception.ExceptionMessage
                    Resource            = $Uri
                    Protocol            = $p
                    Status              = if ($test) { "SUCCESS" } else { "FAILURE" }
                    TimeStamp           = [datetime]::UtcNow
                    StatusCode          = $StatusCode
                    Detail              = $Detail
                    DebugDtls           = @{
                        'Test' = $test
                        'Retries' = "$retry / $maxRetry"
                        'Uri' = $Uri
                        'StatusCode'= $statusCode
                        'TCPNetConnection' = $tnc
                        'WebResponse' = $webResponse
                        'Headers' = $headers
                        'Exception' = $exception
                        'serviceUnavailable' = $serviceUnavailable
                        'ResponseUriMatch' = $responseUriMatch
                        'ResponseMethodIsGet' = $responseMethodIsGet
                        'ResponseUri' = $webResponse.ResponseUri
                        'ExceptionMessage' = $Exception.ExceptionMessage
                        'ErrorDetails' = $Exception.ErrorDetails
                        'NonHTTPFailure' = $Exception.NonHTTPFailure
                        'Server' = $webResponse.Server
                        'PowerShellVersion' = $PSVersionTable.PSVersion.Major
                        'LatencyInMs' = $stopwatch.ElapsedMilliseconds
                        'RedirectLocation' = $redirectLocation
                    }
                }
            }

            # Start job for a url
            # add job to inProgressJobList and totalJobList
            # check inProgressJobList is greater or equal than maxJobs
            # if so wait for any job to finish before adding more
            $job = Start-Job -PSVersion 5.1 -ArgumentList $u, $proxy, $proxyCred, $timeout -ScriptBlock $iwrScriptBlock
            $inProgressJobList += $job
            $totalJobList += $job.id
            if ($inProgressJobList.Count -ge $maxJobs) {
                $finishedJob = @()
                $finishedJob = $inProgressJobList | Wait-Job -Any
                if ($finishedJob) {
                    $inProgressJobList = $inProgressJobList | Where-Object { $_ -ne $finishedJob }
                }
            }
        }
        Wait-Job -Id $totalJobList | Out-Null
        $results += Receive-Job -Id $totalJobList
        Remove-Job -Id $totalJobList
        return $results
    }
    # Set max concurrent jobs
    if ($ENV:EnvChkrId -like 'PreUpdate*')
    {
        $maxJobs = 3
    }
    else
    {
        $maxJobs = 10
    }
    # Create a copy of the Target object
    $result = $Target | Select-Object -Property *
    $UriList = Get-UniqueEndpoint -Target $Target
    $sessionArgs = @()
    if ($result)
    {
        $sessionArgs += @($uriList,$result.Tags.TimeoutSecs, $maxJobs)
    }
    if ($Proxy)
    {
        $sessionArgs += $Proxy
    }
    if ($ProxyCredential)
    {
        $sessionArgs += $ProxyCredential
    }
    # Run Invoke-WebRequests on remote machines if PsSession is provided
    $AdditionalDataResults = @()
    $AdditionalDataResults += if ($PsSession)
    {
        Log-Info "Sending requests to $($PsSession.ComputerName -join ',') to test $($UriList.Count) URIs, this may take a while."
        Invoke-Command -Session $PsSession -ScriptBlock $ScriptBlock -ArgumentList $sessionArgs
        Log-Info "Received responses from $($PsSession.ComputerName -join ',')."
    }
    else
    {
        Log-Info "Sending requests to $ENV:COMPUTERNAME to test $($UriList.Count) URIs, this may take a while."
        Invoke-Command -ScriptBlock $ScriptBlock -ArgumentList $sessionArgs
        Log-Info "Received responses from $ENV:COMPUTERNAME."
    }
    $finalResult = Update-TargetWithResult -Target $Target -AdditionalDataResults $AdditionalDataResults
    return $finalResult
}

function Log-EndPointResult
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject]
        $Result,

        [string]
        $Name,

        [string]
        $Severity
    )
    # In the case of failures, log the debug info to aid troubleshooting
    if ( $Result.Status -eq 'FAILURE' ){
        Log-Info ("{0}: {1} {2} ({3})" -f $Result.Status, $Result.Source, $Result.Resource, $result.ExceptionMessage) -Type $Severity -Function 'Invoke-WebrequestEx'
        Log-Info ("Debug {0}: {1} {2}" -f $Result.Source, $Result.Resource, ($Result.DebugDtls | ConvertTo-Json)) -Type $Severity -Function 'Invoke-WebrequestEx'
    }
    else {
        Log-Info ("{0}: {1} {2} ({3}ms)" -f $Result.Status, $Result.Source, $Result.Resource, $result.LatencyInMs) -Function 'Invoke-WebrequestEx'
    }
}

function Update-TargetWithResult
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsObject[]]
        $Target,

        [Parameter()]
        [PsObject[]]
        $AdditionalDataResults
    )
    # Match the test result to all the target that match the endpoint
    $result = $Target | Select-Object -Property *
    $finalResult = @()

    # Inspect each result
    foreach ($dataResult in $AdditionalDataResults)
    {
        # find the target that matches the endpoint
        $matchingResult = @()
        $matchingResult = $result | Where-Object { ([system.uri]$dataResult.Resource).Scheme -in $_.Protocol -and ($dataResult.Resource -replace "https?://", "") -in $_.EndPoint}
        $matchingResult | Foreach-Object {
            Log-EndPointResult -Result $dataResult -Severity $PsItem.Severity -Name $PsItem.Name
            $dataResult.DebugDtls = 'redacted'
             # Create output
             $params = @{
                Name               = $PsItem.Name
                Title              = $PsItem.Title
                DisplayName        = $PsItem.Title
                Severity           = $PsItem.Severity
                Description        = $PsItem.Description
                Tags               = @{
                    Service        = $_.Service
                    Mandatory      = $_.Mandatory
                    ARCGateway     = $_.ARCGateway
                    Region         = $_.Region
                }
                Remediation        = $PsItem.Remediation
                TargetResourceID   = "$($dataResult.Source)/$($dataResult.Resource)"
                TargetResourceName = $dataResult.Resource
                TargetResourceType = $PsItem.TargetResourceType
                Timestamp          = $dataResult.TimeStamp
                Status             = $dataResult.Status
                AdditionalData     = $dataResult
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $finalResult += New-AzStackHciResultObject @params
        }
    }
    return $finalResult
}

function Get-ProxyDiagnostics
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter()]
        [switch]
        $ARCGateway
    )
    Log-Info "Gathering proxy diagnostics"
    $proxyConfigs = @()
    if ($PsSession)
    {
        foreach ($session in $PsSession)
        {
            $proxyConfigs += Get-WinHttpProxyHelper -PsSession $session
            $proxyConfigs += Get-ProxyEnvironmentVariable -PsSession $session
            $proxyConfigs += Get-WinInetProxyHelper -PsSession $session
        }
    }
    else {
        $proxyConfigs += Get-WinHttpProxyHelper
        $proxyConfigs += Get-ProxyEnvironmentVariable
        $proxyConfigs += Get-WinInetProxyHelper
    }
    $simplifiedProxyConfig = Get-SimpleProxyConfigObject -ProxyConfigurations $proxyConfigs

    $nodeArcAgentConnected = Check-NodeArcAgentConnected;
    if ($ARCGateway -and $nodeArcAgentConnected)
    {
        $arcGatewayProxyConfigTestResult = Test-ArcGatewayProxyConfig -ProxyConfigurations $simplifiedProxyConfig
    }

    $proxyByPassListRecommendations = Test-ProxyByPassListRecommendations -ProxyConfigurations $simplifiedProxyConfig
    $proxyConfigConsistency = Test-ProxySettingsConsistency -ProxyConfigurations $simplifiedProxyConfig

    return ($proxyConfigs + $proxyByPassListRecommendations + $proxyConfigConsistency + $arcGatewayProxyConfigTestResult)
}

function Get-WinHttpProxyHelper
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession
    )
    Log-Info "Gathering WinHttp Proxy settings"
    $proxyHelperSb = {
        function Get-WinHttpProxyConfiguration
        {
            Import-Module WinHttpProxy -Verbose:$false
            $proxySetting = Get-WinHttpProxy -Default
            $winHttp_http = ""
            $winHttp_https = ""
            $winHttp_bypass = ""

            foreach ($setting in $proxySetting) {
                if ($setting -match "Proxy Server\(s\)\s*:\s*(.+)"){
                    $rawProxies = $Matches[1].Trim()
                    $proxyServers = $rawProxies -split ';'
                    foreach ($server in $proxyServers)
                    {
                        if($server -like "*http=*")
                        {
                            $winHttp_http = $server -split "=", 2 | Select-Object -Last 1
                            $winHttp_http = $winHttp_http.Trim()
                        }
                        elseif($server -like "*https=*")
                        {
                            $winHttp_https = $server -split "=", 2 | Select-Object -Last 1
                            $winHttp_https = $winHttp_https.Trim()
                        }
                        else {
                            # if there is a single proxy, then it is not prefixed
                            # with either http= or https=; treat single proxy as both http and https proxy.
                            $winHttp_http = $server.Trim()
                            $winHttp_https = $winHttp_http
                        }
                    }
                }
                elseif ($setting -like "*Bypass*")
                {
                    $winHttp_bypass = $setting -split ":", 2 | Select-Object -Last 1
                    $winHttp_bypass = $winHttp_bypass.Trim()
                }
            }
            # Construct the proxy settings object to return
            $proxySettings = @{
                HttpProxy            = $winHttp_http
                HttpsProxy           = $winHttp_https
                ProxyBypass          = $winHttp_bypass
                ProxyIsEnabled       = -not [string]::IsNullOrEmpty($winHttp_http)
            }
            return $proxySettings
        }

        $proxySettings = Get-WinHttpProxyConfiguration



        # Make sure we return the same object type as the other proxy functions
        $AdditionalData = @()
        $AdditionalData += @{
            Detail      =  $proxySettings | ConvertTo-Json
            Source      = $ENV:COMPUTERNAME
            Resource    = 'WinHttp'
            Status      = 'SUCCESS'
            TimeStamp   = [datetime]::UtcNow
        }
        return $AdditionalData
    }

    $winHttpOutput = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $proxyHelperSb
        $TargetResourceName = "WinHttp_Proxy_$($PsSession.ComputerName)"
    }
    else
    {
        Invoke-Command -ScriptBlock $proxyHelperSb
        $TargetResourceName = "WinHttp_Proxy_$($ENV:COMPUTERNAME)"
    }

    # Write our findings to the log and create output objects
    $results = @()
    $results += foreach ($AdditionalData in $winHttpOutput | Sort-Object Source)
    {
        Log-Info "Machine Scope Proxy for $($AdditionalData.Source) (Get-WinhttpProxy -Default):"
        $AdditionalData.Detail | Format-List | Out-String -Stream | ForEach-Object {if (![string]::IsNullOrEmpty($_)){ Log-Info $_}}
        # Create output object
        $params = @{
            Name               = 'AzStackHci_Connectivity_Collect_Proxy_Diagnostics_WinHttp'
            Title              = 'WinHttp Proxy Settings'
            DisplayName        = "$($AdditionalData.Source) WinHttp Proxy Settings"
            Severity           = 'INFORMATIONAL'
            Description        = 'Collects proxy configuration for WinHttp'
            Tags               = @{
                Service = 'System'
            }
            Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings#configure-proxy-settings-for-azure-stack-hci-operating-system"
            TargetResourceID   = "$($AdditionalData.Source)/$($AdditionalData.Resource)"
            TargetResourceName = $AdditionalData.Resource
            TargetResourceType = 'Proxy Settings'
            Timestamp          = [datetime]::UtcNow
            Status             = $AdditionalData.Status
            AdditionalData     = $AdditionalData
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    return $results
}

function Get-WinInetProxyHelper
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession
    )
    Log-Info "Gathering WinInet Proxy settings"
    $proxyHelperSb = {
        function Get-WinInetProxyConfiguration
        {
            Import-Module WinHttpProxy -Verbose:$false
            $proxySetting = Get-WinHttpProxy -Advanced
            $winInet_http = ""
            $winInet_https = ""
            $winInet_bypass = ""

            foreach ($setting in $proxySetting) {
                if ($setting -match "^Proxy\s*:\s*(.+)$")
                {
                    $rawProxies = $Matches[1].Trim()
                    $proxyServers = $rawProxies -split ';'
                    foreach ($server in $proxyServers)
                    {
                        if($server -like "*http=*")
                        {
                            $winInet_http = $server -split "=", 2 | Select-Object -Last 1
                            $winInet_http = $winInet_http.Trim()
                        }
                        elseif($server -like "*https=*")
                        {
                            $winInet_https = $server -split "=", 2 | Select-Object -Last 1
                            $winInet_https = $winInet_https.Trim()
                        }
                        else {
                            # Single proxy applies to both
                            $winInet_http = $server.Trim()
                            $winInet_https = $winInet_http
                        }
                    }
                }
                elseif ($setting -like "*bypass*")
                {
                    $winInet_bypass = $setting -split ":", 2 | Select-Object -Last 1
                    $winInet_bypass = $winInet_bypass.Trim()
                }
            }
            # Construct the proxy settings object to return
            $proxySettings = @{
                HttpProxy            = $winInet_http
                HttpsProxy           = $winInet_https
                ProxyBypass          = $winInet_bypass
                ProxyIsEnabled       = -not [string]::IsNullOrEmpty($winInet_http)
            }
            return $proxySettings
        }

        $proxySettings = Get-WinInetProxyConfiguration

        $AdditionalData = @()
        $AdditionalData += @{
            Detail      =  $proxySettings | ConvertTo-Json
            Source      = $ENV:COMPUTERNAME
            Resource    = 'WinInet'
            Status      = 'SUCCESS'
            TimeStamp   = [datetime]::UtcNow
        }
        return $AdditionalData
    }

    $winInetOutput = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $proxyHelperSb
        $TargetResourceName = "WinInet_Proxy_$($PsSession.ComputerName)"
    }
    else
    {
        Invoke-Command -ScriptBlock $proxyHelperSb
        $TargetResourceName = "WinInet_Proxy_$($ENV:COMPUTERNAME)"
    }

    # Write our findings to the log and create output objects
    $results = @()
    $results += foreach ($AdditionalData in $winInetOutput | Sort-Object Source)
    {
        Log-Info "Machine Scope Proxy for $($AdditionalData.Source) (Get-WinhttpProxy -Advanced):"
        $AdditionalData.Detail | Format-List | Out-String -Stream | ForEach-Object {if (![string]::IsNullOrEmpty($_)){ Log-Info $_}}
        # Create output object
        $params = @{
            Name               = 'AzStackHci_Connectivity_Collect_Proxy_Diagnostics_WinInet'
            Title              = 'WinInet Proxy Settings'
            DisplayName        = "$($AdditionalData.Source) WinInet Proxy Settings"
            Severity           = 'INFORMATIONAL'
            Description        = 'Collects proxy configuration for WinInet'
            Tags               = @{
                Service = 'System'
            }
            Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings#configure-proxy-settings-for-azure-stack-hci-operating-system"
            TargetResourceID   = "$($AdditionalData.Source)/$($AdditionalData.Resource)"
            TargetResourceName = $AdditionalData.Resource
            TargetResourceType = 'Proxy Settings'
            Timestamp          = [datetime]::UtcNow
            Status             = $AdditionalData.Status
            AdditionalData     = $AdditionalData
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    return $results
}

function Get-ProxyEnvironmentVariable
{
    <#
    .SYNOPSIS
        Get Proxy configuration from environment variables
    .DESCRIPTION
        Get Proxy configuration from environment variables
    .EXAMPLE
        PS C:\> Get-ProxyEnvironmentVariable
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession
    )
    Log-Info "Gathering machine Proxy settings from environment variables"

    $envProxySb = {
        $AdditionalData = @()
        $AdditionalData += @{
            Detail      =  @{
                HttpProxy       = [Environment]::GetEnvironmentVariable("HTTP_PROXY","MACHINE")
                HttpsProxy      = [Environment]::GetEnvironmentVariable("HTTPS_PROXY","MACHINE")
                ProxyBypass     = [Environment]::GetEnvironmentVariable("NO_PROXY","Machine")
                ProxyIsEnabled  = [bool]([Environment]::GetEnvironmentVariable("HTTP_PROXY","MACHINE"))
            } | ConvertTo-Json
            Source      = $ENV:COMPUTERNAME
            Resource    = 'Environment'
            Status      = 'SUCCESS'
            TimeStamp    = [datetime]::UtcNow
        }
        return $AdditionalData
    }
    [array]$EnvironmentProxyOutput = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $envProxySb
        $TargetResourceName = "Environment_Proxy_$($PsSession.ComputerName)"
    }
    else
    {
        Invoke-Command -ScriptBlock $envProxySb
        $TargetResourceName = "Environment_Proxy_$($ENV:COMPUTERNAME)"
    }
    # Write our findings to the log
    $results = @()
    $results += foreach ($AdditionalData in $EnvironmentProxyOutput | Sort-Object Source)
    {
        Log-Info "Environment Scope Proxy for $($AdditionalData.Source) (ENV:HTTPS_PROXY):"
        $AdditionalData.Detail | Format-List | Out-String -Stream | ForEach-Object {if (![string]::IsNullOrEmpty($_)){ Log-Info $_}}
        # Create output object
        $params = @{
            Name               = 'AzStackHci_Connectivity_Collect_Proxy_Diagnostics_Environment'
            Title              = 'Environment Proxy Settings'
            DisplayName        = "$($AdditionalData.Source) Environment Proxy Settings"
            Severity           = 'Information'
            Description        = 'Collects proxy configuration from environment variables'
            Tags               = @{
                Service = 'System'
            }
            Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings#configure-proxy-settings-for-azure-arc-enabled-servers"
            TargetResourceID   = "$($AdditionalData.Source)/$($AdditionalData.Resource)"
            TargetResourceName = $AdditionalData.Resource
            TargetResourceType = 'Proxy Settings'
            Timestamp          = $AdditionalData.TimeStamp
            Status             = $AdditionalData.Status
            AdditionalData     = $AdditionalData
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    return $results
}

function Test-ProxySettingsConsistency
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Array]
        $ProxyConfigurations
    )

    Log-Info "Testing all proxy settings are consistent"

    if (Compare-PSObjectArray -Array $ProxyConfigurations -Property HttpProxy)
    {
        # Check all winHttp are configured
        $dtl = $lcTxt.ProxySettingsConsistencyPass
        Log-Info $dtl
        $status = 'SUCCESS'
    }
    else
    {
        $dtl = $lcTxt.ProxySettingsConsistencyFail -f ([string]($ProxyConfigurations | Format-Table | Out-String) -replace '\r\n','')
        Log-Info $dtl -Type 'Critical'
        $status = 'FAILURE'
    }

    $params = @{
        Name               = 'AzStackHci_Connectivity_HttpProxy_Settings_Consistency'
        Title              = 'Http Proxy Settings Consistency'
        DisplayName        = "$($ProxyConfigurations.Source -join ',') Environment Http Proxy Settings"
        Severity           = 'Critical'
        Description        = 'Checks that all nodes are configured with the same Http Proxy Settings'
        Tags               = @{
            Service = 'System'
        }
        Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings"
        TargetResourceID   = "$($ProxyConfigurations.Source -join ',')/Http_Proxy_Settings"
        TargetResourceName = "Http_Proxy_Settings_AllServers"
        TargetResourceType = 'Proxy Settings'
        Timestamp          = [datetime]::UtcNow
        Status             = $Status
        AdditionalData     = @{
            Source = $ProxyConfigurations.Source -join ','
            Resource = 'Http Proxy Settings'
            Status = $status
            Detail = $dtl
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    [array]$result = New-AzStackHciResultObject @params


    if (Compare-PSObjectArray -Array $ProxyConfigurations -Property HttpsProxy)
    {
        # Check all winHttp are configured
        $dtl = $lcTxt.ProxySettingsConsistencyPass
        Log-Info $dtl
        $status = 'SUCCESS'
    }
    else
    {
        $dtl = $lcTxt.ProxySettingsConsistencyFail -f ([string]($ProxyConfigurations | Format-Table | Out-String) -replace '\r\n','')
        Log-Info $dtl -Type 'Critical'
        $status = 'FAILURE'
    }
    $params = @{
        Name               = 'AzStackHci_Connectivity_HttpsProxy_Settings_Consistency'
        Title              = 'Https Proxy Settings Consistency'
        DisplayName        = "$($ProxyConfigurations.Source -join ',') Environment Https Proxy Settings"
        Severity           = 'Critical'
        Description        = 'Checks that all nodes are configured with the same Https Proxy Settings'
        Tags               = @{
            Service = 'System'
        }
        Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings"
        TargetResourceID   = "$($ProxyConfigurations.Source -join ',')/Https_Proxy_Settings"
        TargetResourceName = "Https_Proxy_Settings_AllServers"
        TargetResourceType = 'Proxy Settings'
        Timestamp          = [datetime]::UtcNow
        Status             = $Status
        AdditionalData     = @{
            Source = $ProxyConfigurations.Source -join ','
            Resource = 'Https Proxy Settings'
            Status = $status
            Detail = $dtl
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    $result += New-AzStackHciResultObject @params
    return @($result)
}

function Get-SimpleProxyConfigObject
{
    param(
        [Parameter()]
        [System.Array]
        $ProxyConfigurations
    )
    try {
        $simplifiedProxyConfig = @()
        $simplifiedProxyConfig += foreach ($p in $ProxyConfigurations)
        {
            $ProxyConfigObject = ConvertFrom-Json -InputObject $p.AdditionalData.Detail
            $hash = @{
                Source    = $p.AdditionalData.Source
                Resource  = $p.AdditionalData.Resource
                ProxyIsEnabled  = $ProxyConfigObject.ProxyIsEnabled
                HttpProxy       = $ProxyConfigObject.HttpProxy -replace 'http://|https://',''
                HttpsProxy      = $ProxyConfigObject.HttpsProxy -replace 'http://|https://',''
                ProxyBypass     = $ProxyConfigObject.ProxyBypass -replace ';',','
            }
            New-Object -TypeName PsObject -Property $hash
        }
        return $simplifiedProxyConfig
    }
    catch {
        throw $_
    }

}

function Test-ArcGatewayProxyConfig
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Array]
        $ProxyConfigurations
    )

    $results = @()
    $status = 'SUCCESS'
    foreach ($config in $ProxyConfigurations)
    {
        if ($config.HttpsProxy -ne 'localhost:40343')
        {
            $dtl = ($lcTxt.ARCGatewayProxySettingsFail -f $config.Source, $config.Resource, $config.HttpsProxy)
            Log-Info $dtl -Type 'Critical'
            $status = 'FAILURE'
            $params = @{
                Name               = 'AzStackHci_Connectivity_ARCGateway_Proxy_Settings'
                Title              = 'ARCGateway Proxy Settings'
                DisplayName        = "$($config.Source) ARCGateway Proxy Settings"
                Severity           = 'CRITICAL'
                Description        = "Checks that each node's proxy settings are configured correctly for this ArcGateway enabled cluster"
                Tags               = @{
                    Service = 'System'
                }
                Remediation        = "Set Https Proxy for $($config.Source)/$($config.Resource) to http://localhost:40343."
                TargetResourceID   = "$($config.Source)/ARCGateway_Proxy_Settings"
                TargetResourceName = $config.Resource
                TargetResourceType = 'ARC Gateway Proxy Settings'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $config.Source
                    Resource  = $config.Resource
                    Status    = $status
                    Detail    = $dtl
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $results += New-AzStackHciResultObject @params
        }
    }

    if ($status -eq 'SUCCESS')
    {
        $dtl = $lcTxt.ArcGatewayProxySettingsPass
        Log-Info $dtl
        $params = @{
            Name               = 'AzStackHci_Connectivity_ARCGateway_Proxy_Settings'
            Title              = 'ARCGateway Proxy Settings'
            DisplayName        = 'ARCGateway Proxy Settings'
            Severity           = 'Critical'
            Description        = "Checks that each node's proxy settings are configured correctly for this ArcGateway enabled cluster"
            Tags               = @{
                Service = 'System'
            }
            Remediation        = "No remediation required, HTTPS proxy for all proxy setting sources on all nodes are set to http://localhost:40343."
            TargetResourceID   = "ARCGateway_Proxy_Settings"
            TargetResourceName = "ARCGateway_Proxy_Settings"
            TargetResourceType = 'ARC Gateway Proxy Settings'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Status = $status
                Detail = $dtl
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return New-AzStackHciResultObject @params
    }
    return $results

}

function Test-ProxyByPassListRecommendations
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Array]
        $ProxyConfigurations
    )

    if ($true -in $ProxyConfigurations.ProxyIsEnabled)
    {
        $envVariableRecommendedByPassList = @("localhost","127.0.0.1",".svc","kubernetes.default.svc",".svc.cluster.local","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16")
        $winInetAndWinHttpRecommendedByPassList = @("localhost", "127.0.0.1")
        Log-Info ($lcTxt.EnvVariableProxyByPassListRecommendations -f ($envVariableRecommendedByPassList -join ','))
        Log-Info ($lcTxt.WinInetAndWinHttpProxyByPassListRecommendations -f ($winInetAndWinHttpRecommendedByPassList -join ','))

        $result = @()
        foreach ($config in $ProxyConfigurations)
        {
            if ($config.Resource -eq "Environment")
            {
                $recommendedByPassList = $envVariableRecommendedByPassList
            }
            else
            {
                $recommendedByPassList = $winInetAndWinHttpRecommendedByPassList
            }
            # Check if each entry is present
            $missingByPassEntry = @()
            foreach ($entry in $recommendedByPassList)
            {
                if ($entry -notin ($config.ProxyBypass -split ','))
                {
                    $missingByPassEntry += $entry
                }
            }

            # Set status based on missing entries
            if ($missingByPassEntry.count -gt 0)
            {
                $ByPassDtl = ($lcTxt.ProxyByPassListRecommendationsMissing -f ($missingByPassEntry -join ','), $config.Resource, $config.Source)
                Log-Info $ByPassDtl -Type Warning
                $status = 'FAILURE'
            }
            else
            {
                $ByPassDtl = ($lcTxt.ProxyByPassListRecommendationsPass -f $config.Resource, $config.Source)
                Log-Info $ByPassDtl
                $status = 'SUCCESS'
            }

            $params = @{
                Name               = 'AzStackHci_Connectivity_Proxy_ByPassList_Recommendations'
                Title              = 'Proxy ByPassList Recommendations'
                DisplayName        = "$($config.Source) Proxy ByPassList Recommendations"
                Severity           = 'Informational'
                Description        = 'Checks that all nodes are configured with recommended proxy bypass list items'
                Tags               = @{
                    Service = 'System'
                }
                Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings"
                TargetResourceID   = "$($config.Source)/Proxy_Bypass_List"
                TargetResourceName = $config.Resource
                TargetResourceType = 'Proxy Settings'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $config.Source
                    Resource  = "Proxy_ByPassList_Recommendations_$($config.Source)"
                    Status    = $status
                    Detail    = $ByPassDtl
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $result += New-AzStackHciResultObject @params

            #region Critical Failure for proxy bypass invalid entries
            [System.String] $bypassCriticalRstStatus = "SUCCESS"
            [System.String] $bypassCriticalRstDetail = ""

            if ($config.ProxyBypass -match ",,")
            {
                $bypassCriticalRstStatus = "FAILURE"
                $bypassCriticalRstDetail += "Proxy bypass list contains ',,' in $($config.Resource) on $($config.Source)."
            }

            if (($config.Resource -eq "Environment") -and ($config.ProxyBypass.Contains("*")))
            {
                $bypassCriticalRstStatus = "FAILURE"
                $bypassCriticalRstDetail += "Proxy bypass list from environment variable contains '*' in $($config.Resource) on $($config.Source)."
            }

            if ($config.ProxyBypass -match "<local>")
            {
                $bypassCriticalRstStatus = "FAILURE"
                $bypassCriticalRstDetail += "Proxy bypass list contains '<local>' in $($config.Resource) on $($config.Source)."
            }

            if ([System.String]::IsNullOrEmpty($bypassCriticalRstDetail))
            {
                $bypassCriticalRstDetail = "Entries in proxy bypass list in $($config.Resource) on $($config.Source) are valid."
            }

            $proxyByPassInvalidEntriesCheckRstObject = @{
                Name               = 'AzStackHci_Connectivity_Proxy_ByPassList_InvalidEntries'
                Title              = 'Proxy ByPassList Invalid Entries'
                DisplayName        = "$($config.Source) Proxy Invalid Entries"
                Severity           = 'CRITICAL'
                Description        = 'Checks that all nodes proxy bypass list does not have invalid entries in it'
                Tags               = @{
                    Service = 'System'
                }
                Remediation        = "https://learn.microsoft.com/en-us/azure-stack/hci/manage/configure-proxy-settings"
                TargetResourceID   = "$($config.Source)/Proxy_Bypass_List"
                TargetResourceName = $config.Resource
                TargetResourceType = 'Proxy Settings'
                Timestamp          = [datetime]::UtcNow
                Status             = $bypassCriticalRstStatus
                AdditionalData     = @{
                    Source    = $config.Source
                    Resource  = "Proxy_ByPassList_InvalidEntries_$($config.Source)"
                    Detail    = $bypassCriticalRstDetail
                    Status    = $bypassCriticalRstStatus
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }

            $result += New-AzStackHciResultObject @proxyByPassInvalidEntriesCheckRstObject
            #endregion
        }
        return $result
    }
    else
    {
        Log-Info "No proxy is configured. Skipping proxy bypass list recommendations"
    }
}

function Write-FailedUrls
{
    [CmdletBinding()]
    param (
        $result
    )
    if (-not [string]::IsNullOrEmpty($Global:AzStackHciEnvironmentLogFile))
    {
        $file = Join-Path -Path (Split-Path $Global:AzStackHciEnvironmentLogFile -Parent) -ChildPath FailedUrls.txt
    }
    $FailedUrls = ($result.AdditionalData | Where-Object Status -NE 'SUCCESS').Resource | Sort-Object -Unique
    if ($FailedUrls.count -gt 0)
    {
        Log-Info ("[Over]Writing {0} to {1}" -f ($FailedUrls -split ','), $file)
        $FailedUrls | Out-File $file -Force
        Log-Info "`nFailed Urls log: $file" -ConsoleOut
    }
}

function Select-AzStackHciConnectivityTarget
{
    <#
    .SYNOPSIS
        Apply user exclusions to Connectivity Targets
    #>

    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject]
        $Targets,

        [Parameter()]
        [string[]]
        $Exclude
    )

    try
    {
        $returnList = @($Targets)
        if ($exclude)
        {
            Log-Info "Removing tests $($exclude -join ',')"
            $returnList = $returnList | Where-Object { $_.Service | Select-String -Pattern $exclude -NotMatch }
        }
        if ($returnList.count -eq 0)
        {
            throw "No tests to perform after filtering"
        }

        # check and apply file exclusions
        $fileExclusion = @()
        $fileExclusion = Get-FileExclusion
        if ($fileExclusion -and $fileExclusion.count -gt 0)
        {
            $returnList = $returnList | Where-Object {( $_.Service | Select-String -Pattern $fileExclusion -NotMatch ) -and ( $_.endpoint | Select-String -Pattern $fileExclusion -NotMatch )}
        }
        else
        {
            Log-Info "No file exclusions found or file is empty."
        }

        Log-Info "Test list: $($returnList.Name -join ',')"
        if ($returnList.Count -eq 0)
        {
            Log-Info -Message "No tests to run." -ConsoleOut -Type Warning
            break noTestsBreak
        }
        return $returnList
    }
    catch
    {
        Log-Info "Failed to filter test list. Error: $($_.exception)" -Type Warning
    }
}

function Get-CloudEndpointFromManifest
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [system.uri]
        $Uri
    )

    try
    {
        $tempXmlFile = Join-Path -Path $env:temp -ChildPath 'AzStackHciConnectivityTarget.xml'
        Write-Verbose "Retrieving connectivity targets from $Uri to temp location: $tempXmlFile..."
        $iwrParams = @{
            Uri = $Uri
            UseBasicParsing = $true
            OutFile = $tempXmlFile
        }
        $response = Invoke-WebRequest @iwrParams

        # Use the Test-XmlSignature script from the parent EnvironmentChecker directory
        $testSigningScript = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Test-XmlSignature.ps1'
        if (-not (Test-Path -Path $testSigningScript)) {
            throw "Test-XmlSignature.ps1 not found at: $testSigningScript"
        }
        Write-Verbose "Validating signature of $tempXmlFile using $testSigningScript..."
        [bool]$checkSigningResult = Start-Job -PSVersion 5.1 -ScriptBlock { & $USING:testSigningScript -XmlPath $USING:tempXmlFile } | Wait-Job | Receive-Job -ErrorAction SilentlyContinue
        Write-Verbose "Signature validation result: $checkSigningResult"
        if (-not $checkSigningResult)
        {
            throw "Failed to validate signature of $tempXmlFile from $Uri"
        }
        [xml]$manifest = Get-Content -Path  $tempXmlFile
        $version = $manifest.Objects.Object.Property | Where-Object Name -eq Version | Select -ExpandProperty '#text'
        $title = $manifest.Objects.Object.Property | Where-Object Name -eq Title | Select -ExpandProperty '#text'
        $targets = $manifest.Objects.Object.Property | Where-Object Name -eq Targets | Select -ExpandProperty 'Property'
        [AzStackHciConnectivityTarget[]]$targets = New-AzStackHciConnectivityTargetFromXml -TargetXml $targets
        if ($targets.count -eq 0)
        {
            throw "No connectivity targets found in $tempXmlFile"
        }
        # Make sure DNS and SSL tests are present
        if ('System_Check_DNS_External_Hostname_Resolution' -notin $targets.Name)
        {
            Log-Info 'System_Check_DNS_External_Hostname_Resolution is missing from the connectivity targets' -Type Warning
        }
        if ('System_Check_SSL_Inspection_Detection' -notin $targets.Name)
        {
            throw 'System_Check_SSL_Inspection_Detection is missing from the connectivity targets'
        }
        $msg = "Retrieved $($targets.count) connectivity targets from $($title) version $($version)"
        Write-Verbose $msg
        return $targets
    }
    catch
    {
        $msg = "Failed to get connectivity targets from $Uri. Error: $($_.exception.message)"
        Write-Verbose $msg
    }
    finally
    {
        if (Test-Path -Path $tempXmlFile)
        {
            Remove-Item -Path $tempXmlFile -ErrorAction SilentlyContinue
        }
    }
}


function Export-AzStackHciConnectivityTargetToXml
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $TargetDirectory,

        [Parameter(Mandatory)]
        [string]
        $TargetFileName,

        [Parameter(Mandatory)]
        [string]
        $Version,

        [string]
        $Region
    )
    [array]$targetsForXml = Get-AzStackHciConnectivityTarget -LocalOnly -IncludeSystem -RegionName $Region
    if ($targetsForXml.Count -eq 0)
    {
        Write-Warning "No connectivity targets found for region $Region. Exiting..."
        return
    }
    Write-Host ("Found {0} connectivity targets for manifest" -f [int]($targetsForXml.Count))
    Write-Host "Creating manifest with version $version"
    $manifest = New-Object AzStackHciConnectivityManifest -Property @{
        Title = 'AzStackHci Connectivity Endpoint Definitions'
        Version = $Version
        Targets = $targetsForXml
    }
    $manifest | ConvertTo-Xml -Depth 5 -As Stream | Out-File $TargetDirectory\$TargetFileName -Encoding utf8
}

function New-AzStackHciConnectivityTargetFromXml
{
    param ($TargetXml)
    foreach ($target in $TargetXml)
    {
        $ErrorActionPreference = 'Stop'
        $AzStackHciConnectivityTargetObject = New-Object AzStackHciConnectivityTarget
        # Arrays
        'EndPoint', 'Protocol', 'Service', 'OperationType' | Foreach-Object {
            $AzStackHciConnectivityTargetObject.$PSITEM = ($target.Property | Where-Object Name -eq $PSITEM).ChildNodes.'#text'
        }

        # Booleans
        'Mandatory', 'System', 'ArcGateway' | ForEach-Object {
            $AzStackHciConnectivityTargetObject.$PSITEM = if (($target.Property | Where-Object Name -eq $PSITEM).'#text' -eq 'True') { $true } else { $false }
        }

        # Strings
        'Name', 'Title', 'Severity', 'Description', 'Remediation', 'TargetResourceID', 'TargetResourceName', 'TargetResourceType', 'Group', 'Region' | Foreach-Object {
            $AzStackHciConnectivityTargetObject.$PSITEM = ($target.Property | Where-Object Name -eq $PSITEM).'#text'
        }

        # Tags
        $ErrorActionPreference = 'SilentlyContinue'
        $tagsProperties = $target.Property | Where-Object Name -eq Tags | Select-Object -ExpandProperty Property

        $Groups = $tagsProperties | Where-Object Name -eq Group
        $Mandatory = $tagsProperties | Where-Object Name -eq Mandatory
        $Service = $tagsProperties | Where-Object Name -eq Service
        $OperationType = $tagsProperties | Where-Object Name -eq OperationType
        $ExpectedSubject = $tagsProperties | Where-Object Name -eq ExpectedSubject
        $ArcGateway = $tagsProperties | Where-Object Name -eq ARCGateway

        # Tags are optional, we iterate through them to
        $tagHash = @{}
        if ($Groups) { $tagHash += @{Group = $Groups.'#text'}}
        if ($Service) { $tagHash += @{Service = $Service.ChildNodes.'#text'}}
        if ($Mandatory) { $tagHash += @{Mandatory = if ($Mandatory.'#text' -eq 'True') { $true } else { $false }}}
        if ($OperationType) { $tagHash += @{OperationType = $OperationType.ChildNodes.'#text'}}
        if ($ExpectedSubject) { $tagHash += @{ExpectedSubject = $ExpectedSubject.ChildNodes.'#text'}}
        if ($ArcGateway) { $tagHash += @{ARCGateway = if ($ArcGateway.'#text' -eq 'True') { $true } else { $false }}}

        $AzStackHciConnectivityTargetObject.Tags = New-Object PsObject -Property $tagHash
        $AzStackHciConnectivityTargetObject
    }
}

function Compare-PSObjectArray {
    param (
        [Parameter(Mandatory=$true)]
        [PSObject[]]$Array,
        [Parameter(Mandatory=$true)]
        [string[]]$property
    )

    # Get the first PSObject in the array
    $first = $Array[0]
    Log-Info "Comparing first object (below) objects with properties '$($property -join ',')':"
    Log-Info ($first | Sort-Object Source | Format-List | Out-String)

    # Compare the first PSObject to the rest of the PSObjects in the array
    $fail = @()
    for ($i = 1; $i -lt $Array.Count; $i++) {
        $result = Compare-Object $first $Array[$i] -Property $property
        # If the PSObjects do not match, return false
        if ($result) {
            $fail += $Array[$i]
        }
    }
    if ($fail.count -gt 0)
    {
        Log-Info "Objects properties '$($property -join ',')' do not match:"
        Log-Info ($fail | Sort-Object Source | Format-List | Out-String)
        return $false
    }
    # If all PSObjects match, return true
    return $true
}

# Convert PsObject to Hashtable
function ConvertTo-Hashtable {
    param (
        [Parameter(Mandatory=$true)]
        [PSObject]$Object
    )

    $hash = @{}
    foreach ($property in $Object.PsObject.Properties) {
        $hash[$property.Name] = $property.Value
    }
    return $hash
}


function New-ARCGatewayRuntimeTarget
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $ARCGatewayName
    )
    try
    {
        $properties = @{
            Name = 'AzStackHci_Connectivity_ARCGateway_RuntimeTarget'
            DisplayName = 'ARC Gateway Runtime Target'
            Description = 'ARC Gateway Runtime Target'
            Service = @('ARCGateway')
            Endpoint = @("$ARCGatewayName.gw.arc.azure.net")
            Protocol = @('HTTPS')
            Severity = 'CRITICAL'
            # TO DO UPDATE THIS REMEDIATION LINK
            Remediation = 'https://aka.ms/ARC-Gateway-Connectivity-Requirements'
            ARCGateway = $false
            Region = 'Global'
        }
        return (New-Object -TypeName PSObject -Property $properties)
    }
    catch
    {
        throw "Failed to create ARC Gateway runtime target. Error: $($_.exception.message)"
    }
}

function Check-NodeArcAgentConnected {
    if(Test-Path -Path "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe")
    {
        $arcAgentStatus = Invoke-Expression -Command "& 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' show -j"
        Log-Info "Arc agent status: $arcAgentStatus"

        # Parsing the status received from Arc agent
        $arcAgentStatusParsed = $arcAgentStatus | ConvertFrom-Json

        # Check if the Arc agent is connected
        # Agent can be is "Connected"  or disconnected state,
        if ($arcAgentStatusParsed.status -ieq "Connected")
        {
           return $true
        }
        return $false
    }
}

function Get-AzStackHciARCGatewaySetting
{
    [CmdletBinding()]
    param()
    # attempt to detect if the user is using the ARCGateway scenario
    try
    {
        $ArcGateway = $false
        $azcmagent =  "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
        if (Test-Path $azcmagent)
        {
            Write-Verbose "Detected Azure Connected Machine Agent"
            $arcConnectionType =  & $azcmagent config get connection.type
            Write-Verbose "ARC Gateway setting: $arcConnectionType"
            if ( $arcConnectionType -eq "gateway")
            {
                $ArcGateway = $true
            }
        }
        else
        {
            Write-Verbose "Azure Connected Machine Agent not detected"
        }
    }
    catch
    {
        Write-Verbose "Error checking ARC gateway settings: $($_.exception.message)"
    }
    return $ArcGateway
}

function Convert-EndpointsToAzureLocal
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $CloudFqdn
    )

    $azureLocalDefaultFqdn = 'autonomous.cloud.private'
    $azureLocalEndpointsPath = Get-ChildItem -Path "$PSScriptRoot\Targets\*.json" -Include "*AzureLocal*" | Select-Object -ExpandProperty FullName
    try
    {
        (Get-Content -Path $azureLocalEndpointsPath).Replace($azureLocalDefaultFQDN, $CloudFqdn) | Set-Content -Path $azureLocalEndpointsPath
    }
    catch
    {
    throw "Failed to replace Default FQDN with AzureLocal FQDN. Error: $($_.exception.message)"
    }
}
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA9NPfA9qglF+AO
# 7TcL+XeuyIX3lFjQsmPqONTWKFgMsKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIBBz6ROwfU7dagoCrumpeJzeWJ1eegojhuxKC54FxGP0MEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEACtPW8W+7zJeCgMaGh5Bf
# C7PC6kZwfN6hszrC82iv+n8bUgN/mslYUXWlrMWxLWO9qj0IQEiAha/LjKej6BCS
# i9MBYq7WC/ZI5HMofH4Jr764spn/+Y19SoIlmvMIGnqpAUJhJX/YtJczHXGd1Vl5
# rcV9H13/404HI4tZ5rBnwpJesZ/ULvoVLY9DfLmWyQ2xkaMJ1/4xEGqgNOKZoxVC
# 9nmoxiNJplsDlZrZQDTWANeUF5aGEAo5k0ZVzd9AyJVV49ry0XLjJiHTZQn4ZR16
# TtJHbX6/4H2mqAZ6rNMw532nW1PdI0Cl/hqKs11zTOlB2W/eDtiibu+kiDMiKX3E
# saGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAauf/L3AwHt6DMdp1H
# lurF83K85aabnhsIzLnluMaKgAIGaeugEigIGBMyMDI2MDUwMzE0MzExMC42MDVa
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
# CRABBDAvBgkqhkiG9w0BCQQxIgQgG2fXcGeg8CfuGUzWw/XeTUJDFOc+oDxyrxuC
# WGEmMJEwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDD1SHufsjzY59S1iHU
# QY9hnsKSrJPg5a9Mc4YnGmPHxjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEKvN5BYY7zmwAAEAAAIQMCIEIIT70NF/aOTBRnL/Ym5d
# CJI5L5fhiGpS2xzTAo0XyaBPMA0GCSqGSIb3DQEBCwUABIICAHHB226lwnScql+w
# GD8721vdxxVNOQUo+J1BkHw1+Kgt599xU76nmcnIUVZBVViZTP+jq3xjzFMeeHXC
# nc6dOt12JbbkXpQm9WKa15Hiiv9KtpLeZwSG+DFoUVLdPRPHzkgv3BziG3Wybzj/
# s0L2O2ilnMl05/I1GzuzSPhJ946374DD232eyLKdDENplMjpSSbvLU10NQrDdpx9
# FEhRHsNhrHwq5BuSu43MfK5XeXfw34IPbD9FUo2drb1m/0HF1nddZJnwDIolUIE3
# inO8GW8veSmpN7O2e9ySAdPJWomnH1aBEiKHo32XpWiRIXx8AcClf5ZgiPsAh3rX
# 9tT+VzfMBv8DJ62CTPtGiuDNUpVmBKlzJivldaTVaDyjBxjgp+zqKh1rZ6YTu7Kk
# WNxIljJhd31m97tBgfvyn8jwf8zAOWwhEomfbFJaua0IbQz1EHkCAkYb94Midc71
# 9my+QVWm1W8+/4+bA7axgRkd1lAOQfCyM+Ku5an3QTCtoalyL48JRIklGwhtil2e
# 2L/OlctguX4THSUZpuFpFAlQP/5XWkCSFXSYRXUMLQ5I6Ziky61JOhSBJCYW8Vyj
# WhdIKwJ6KPvbDarIY+3mKfWayT0uoKyDNu6hrWCz5vibF5tUY4LSJVMtw5KuOhhk
# lzt/heCf9uMbUckLi/j9w5kLBUsx
# SIG # End signature block
