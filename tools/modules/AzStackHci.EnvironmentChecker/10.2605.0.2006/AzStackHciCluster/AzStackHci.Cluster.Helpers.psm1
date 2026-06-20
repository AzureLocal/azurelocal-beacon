Import-LocalizedData -BindingVariable lcluTxt -FileName AzStackHci.Cluster.Strings.psd1

function Test-ClusterNameLength
{
    try
    {
        $clusterName = Get-Cluster | Select-Object -ExpandProperty Name
    }
    catch
    {
        throw $_
    }

    if ($clusterName.Length -gt 15)
    {
        $status = 'FAILURE'
        $detail = $lcluTxt.ClusterNameLength -f $clusterName, $clusterName.Length, 15
        Log-Info $detail -Type CRITICAL
    }
    else
    {
        $status = 'SUCCESS'
        $detail = $lcluTxt.ClusterNameLengthCheck -f $clusterName, $clusterName.Length
        Log-Info $detail
    }

    $params = @{
        Name               = 'AzStackHci_Upgrade_Cluster_NameLength'
        Title              = 'Test Cluster Name Length'
        DisplayName        = 'Test Cluster Name Length'
        Severity           = 'CRITICAL'
        Description        = 'Checking Cluster name is greater than 15 characters'
        Tags               = @{}
        Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-install-os'
        TargetResourceID   = $ENV:COMPUTERNAME
        TargetResourceName = $ENV:COMPUTERNAME
        TargetResourceType = 'Cluster'
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source    = $ENV:COMPUTERNAME
            Resource  = 'Cluster'
            Detail    = $detail
            Status    = $status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    return New-AzStackHciResultObject @params
}

function Validate-AzLocalClusterExists
{
    <#
    .SYNOPSIS
        Test cluster exists
    #>

    try
    {
        $cluster = Get-Cluster -ErrorAction Ignore
    }
    catch
    {
        $cluster = $null
    }

    if (-not $cluster)
    {
        $status = 'FAILURE'
        $detail = $lcluTxt.NoClusterFound -f $ENV:COMPUTERNAME
        Log-Info $detail -Type CRITICAL
    }
    else
    {
        $status = 'SUCCESS'
        $detail = $lcluTxt.ClusterFound -f $ENV:COMPUTERNAME, $cluster
        Log-Info $detail
    }

    $params = @{
        Name               = 'AzStackHci_Upgrade_Cluster_Exists'
        Title              = 'Test Cluster Exists'
        DisplayName        = 'Test Cluster Exists'
        Severity           = 'CRITICAL'
        Description        = 'Checking Cluster is installed'
        Tags               = @{}
        Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/deploy/deployment-tool-install-os'
        TargetResourceID   = $ENV:COMPUTERNAME
        TargetResourceName = $ENV:COMPUTERNAME
        TargetResourceType = 'Cluster'
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source    = $ENV:COMPUTERNAME
            Resource  = 'Cluster'
            Detail    = $detail
            Status    = $status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    return New-AzStackHciResultObject @params
}

function Test-AzLocalClusterResources
{
    try {
        $clusterGroup = (Get-ItemProperty -Path HKLM:\Cluster -Name ClusterGroup -ErrorAction Stop).ClusterGroup
        $clusterName = (Get-ItemProperty -Path HKLM:\Cluster -Name ClusterName -ErrorAction Stop).ClusterName
        $clusterNameResource = Get-ClusterGroup -Name $clusterGroup | Get-ClusterResource | Where-Object {$_.ResourceType -eq 'Network Name'} | Get-ClusterParameter -Name Name | Where-Object {$_.Value -eq $clusterName} | Select-Object -ExpandProperty ClusterObject
        if($clusterNameResource.State -ne 'Online'){
            $status = 'FAILURE'
            $detail = $lcluTxt.ClusterResourceCheck -f "Network Name", $clusterNameResource.State
            Log-Info $detail -Type CRITICAL
        }
        else {
           $status = 'SUCCESS'
           $detail = $lcluTxt.ClusterResourceCheck -f "Network Name", $clusterNameResource.State
           Log-Info $detail
        }
    }
    catch {
        Log-Info $_ -Type CRITICAL
        $status = 'FAILURE'
        $detail = $lcluTxt.ClusterResourceCheck -f "Network Name", "Not Found"
        Log-Info $detail -Type CRITICAL
    }

    $params = @{
        Name               = 'AzStackHci_Cluster_ResourceOnline'
        Title              = "Test Resource Network Name is Online."
        DisplayName        = "Test Resource Network Name is Online."
        Severity           = 'CRITICAL'
        Description        = "Test Resource Network Name is Online."
        Tags               = @{}
        Remediation        = 'https://aka.ms/UpgradeRequirements'
        TargetResourceID   = 'Cluster'
        TargetResourceName = 'Cluster'
        TargetResourceType = 'Cluster'
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source    = 'Cluster'
            Resource  = 'Cluster'
            Detail    = $detail
            Status    = $status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    $results = New-AzStackHciResultObject @params
    return $results
}

function Test-AzLocalClusterNodes
{
    $result = @()
    $clusterNodes = Get-ClusterNode

    foreach ($node in $clusterNodes)
    {
        if ($node.State -ne 'Up')
        {
            $status = 'FAILURE'
            $detail = "Nodes $($node.Name) are not in 'Up' state."
            Log-Info $detail -Type CRITICAL
        }
        else
        {
            $status = 'SUCCESS'
            $detail = "Node $($node.Name) is in 'Up' state."
            Log-Info $detail
        }
        $params = @{
            Name               = 'AzStackHci_Upgrade_ClusterNodeUp'
            Title              = 'Test Cluster Node is up'
            DisplayName        = "Test Cluster Node is up $($node.Name)"
            Severity           = 'CRITICAL'
            Description        = 'Checking cluster node is up'
            Tags               = @{}
            Remediation        = 'https://aka.ms/UpgradeRequirements'
            TargetResourceID   = $node.Name
            TargetResourceName = $node.Name
            TargetResourceType = 'ClusterNode'
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = 'Cluster'
                Resource  = 'ClusterNode'
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $result += New-AzStackHciResultObject @params
    }

    return $result
}

function Test-AzLocalClusterStretched
{
    $clusterFaultDomain = Get-ClusterFaultDomain -Type Site | Select-Object -Expand Name

    if (($clusterFaultDomain | Sort-Object | Get-Unique).Count -gt 1)
    {
        $status = 'FAILURE'
        $detail = $lcluTxt.StretchedClusterEnabled -f $output.Cluster
        Log-Info $detail -Type CRITICAL
    }
    else
    {
        $status = 'SUCCESS'
        $detail = $lcluTxt.StretchedClusterNotEnabled -f $output.Cluster
        Log-Info $detail
    }

    $params = @{
        Name               = 'AzStackHci_Upgrade_StretchedCluster'
        Title              = 'Test Stretched Cluster'
        DisplayName        = 'Test Stretched Cluster'
        Severity           = 'CRITICAL'
        Description        = 'Checking Stretched Cluster is enabled'
        Tags               = @{}
        Remediation        = 'https://aka.ms/UpgradeRequirements'
        TargetResourceID   = $ENV:COMPUTERNAME
        TargetResourceName = $ENV:COMPUTERNAME
        TargetResourceType = 'Cluster'
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source    = $ENV:COMPUTERNAME
            Resource  = 'Stretched Cluster'
            Detail    = $detail
            Status    = $status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    return New-AzStackHciResultObject @params
}

function Test-AzLocalClusterIpNotInPool
{
    $clusterIp = Get-ClusterGroup -Name 'Cluster Group' | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' | Get-ClusterParameter -Name Address | Select-Object -ExpandProperty Value

    [String[]] $allClusterIpReturned = $ClusterIP | Where-Object { -not [System.String]::IsNullOrEmpty($_) }
    [String] $clusterIpToCheck = $allClusterIpReturned[0]

    Log-Info "Cluster IP to validate: $($clusterIpToCheck)"
    $clusterIPNotInIpPoolStatus = 'SUCCESS'

    $clusterIP = [system.net.ipaddress]::Parse($clusterIpToCheck).GetAddressBytes()
    [array]::Reverse($clusterIP)
    $clusterIP = [system.BitConverter]::ToUInt32($clusterIP, 0)

    foreach ($ipPool in $IpPools)
    {
        $startingAddress = $ipPool.StartingAddress
        $endingAddress = $ipPool.EndingAddress
        Log-Info "Checking IP pool with starting address of $($startingAddress) and ending address of $($endingAddress)"

        $from = [system.net.ipaddress]::Parse($startingAddress).GetAddressBytes()
        [array]::Reverse($from)
        $from = [system.BitConverter]::ToUInt32($from, 0)

        $to = [system.net.ipaddress]::Parse($endingAddress).GetAddressBytes()
        [array]::Reverse($to)
        $to = [system.BitConverter]::ToUInt32($to, 0)

        if ($clusterIP -ge $from -and $clusterIP -le $to)
        {
            $clusterIPNotInIpPoolStatus = 'FAILURE'
            $clusterIPNotInIpPoolDetail = $lcluTxt.ClusterIPInIpPool -f $clusterIpToCheck, $startingAddress, $endingAddress
            Log-Info $clusterIPNotInIpPoolDetail -Type CRITICAL
            break
        }
    }

    if ($clusterIPNotInIpPoolStatus -eq 'SUCCESS')
    {
        $clusterIPNotInIpPoolDetail = $lcluTxt.ClusterIPNotInIpPool -f $clusterIpToCheck
        Log-Info $clusterIPNotInIpPoolDetail
    }

    $params = @{
        Name               = 'AzStackHci_Upgrade_ClusterIPExcludedFromIPPool'
        Title              = 'Cluster IP excluded from IP pool'
        DisplayName        = 'Cluster IP excluded from IP pool'
        Severity           = 'CRITICAL'
        Description        = 'The cluster IP should not be part of the provided IP pool'
        Tags               = @{}
        Remediation        = 'https://aka.ms/UpgradeRequirements'
        TargetResourceID   = 'Cluster'
        TargetResourceName = 'Cluster'
        TargetResourceType = 'Cluster'
        Timestamp          = [datetime]::UtcNow
        Status             = $clusterIPNotInIpPoolStatus
        AdditionalData     = @{
            Source    = 'Cluster'
            Resource  = 'Cluster'
            Detail    = $clusterIPNotInIpPoolDetail
            Status    = $clusterIPNotInIpPoolStatus
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    return New-AzStackHciResultObject @params
}

function Test-AzLocalClusterIPV6
{
    $clusterHasIpv6 = [bool](Get-ClusterGroup -Name 'Cluster Group' | Get-ClusterResource | Where-Object ResourceType -eq 'IPv6 Address')
    Log-Info "Make sure cluster group does not have IPv6 IP resource configured."
    if ($true -in $clusterHasIpv6)
    {
        $clusterIPNotIpv6Status = 'FAILURE'
        $clusterIPIpv6Detail = $lcluTxt.ClusterIPResourceIpv6CheckFail
        Log-Info $clusterIPIpv6Detail -Type CRITICAL
    }
    else
    {
        $clusterIPNotIpv6Status = 'SUCCESS'
        $clusterIPIpv6Detail = $lcluTxt.ClusterIPResourceIpv6CheckPass
        Log-Info $clusterIPIpv6Detail
    }

    $params = @{
        Name               = 'AzStackHci_Upgrade_ClusterIPNotIpv6'
        Title              = 'Test Cluster IP Resource is not IPv6'
        DisplayName        = 'Test Cluster IP Resource is not IPv6'
        Severity           = 'CRITICAL'
        Description        = 'Check cluster IP does not have IPv6 address'
        Tags               = @{}
        Remediation        = 'https://aka.ms/UpgradeRequirements'
        TargetResourceID   = 'Cluster'
        TargetResourceName = 'Cluster'
        TargetResourceType = 'Cluster'
        Timestamp          = [datetime]::UtcNow
        Status             = $clusterIPNotIpv6Status
        AdditionalData     = @{
            Source    = 'Cluster'
            Resource  = 'Cluster'
            Detail    = $clusterIPIpv6Detail
            Status    = $clusterIPNotIpv6Status
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    return New-AzStackHciResultObject @params
}

function Test-ClusterFunctionalLevel
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $remoteOutput = @()
        $sb = {
            $clusterFunctionalLevel = Get-Cluster | Select-Object -Expand ClusterFunctionalLevel
            return New-Object PSObject -Property @{
                ComputerName           = $ENV:COMPUTERNAME
                ClusterFunctionalLevel = $clusterFunctionalLevel
            }
        }
        if ($PsSession)
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb -Session $PsSession
        }
        else
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        $expectedClusterFunctionalLevel = 12
        foreach ($output in $remoteOutput)
        {
            $detail = $lcluTxt.ClusterFunctionalLevel -f $output.ClusterFunctionalLevel, $output.ComputerName, $expectedClusterFunctionalLevel
            if ($output.ClusterFunctionalLevel -eq $expectedClusterFunctionalLevel)
            {
                $status = 'SUCCESS'
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                Log-Info $detail -Type CRITICAL
            }

            $params = @{
                Name               = 'AzStackHci_Upgrade_ClusterFunctionalLevel'
                Title              = 'Test Cluster Functional Level'
                DisplayName        = 'Test Cluster Functional Level'
                Severity           = 'CRITICAL'
                Description        = "Checking Cluster Functional Level is $expectedClusterFunctionalLevel"
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $output.ComputerName
                TargetResourceName = $output.ComputerName
                TargetResourceType = 'Cluster'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $output.ComputerName
                    Resource  = 'Cluster'
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return $instanceResults
    }
    catch
    {
        throw $_
    }
}

function Test-ClusterPreReq
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [String[]]
        $Node,

        [Parameter(Mandatory = $false)]
        [String]
        $OperationType,

        [Parameter(Mandatory = $false)]
        [ValidateSet('S2D', 'SAN', '')]
        [String]
        $StorageType
    )

    $severity = 'CRITICAL'
    $clusterValResults = @()
    $clusterValResults += Invoke-TestCluster -Node $Node -OperationType $OperationType -StorageType $StorageType
    $clusterValResultObs = @()
    foreach ($valResult in $clusterValResults)
    {
        #region Overridden Warnings Tests
        # if valresult detail contains [!!FAILURE!!] - Validate Active Directory Configuration then downgrade severity to WARNING,
        # but valresult detail could contain multiple failures so only downgrade if no other failures exist
        # remove this region when AD validation is upgrade to critical
        $allFailures = $valResult.Detail -match "\[!!Failed!!\].*"
        if ($allFailures.Count -gt 0)
        {
            Log-Info "Cluster validation failures detected: `r`n$($allFailures -join "`r`n"). Evaluating severity..."
            if ($allFailures -match "\[!!Failed!!\] - Validate Active Directory Configuration" -and $allFailures.Count -eq 1)
            {
                Log-Info "Only Active Directory Configuration failure detected, downgrading severity to WARNING."
                $severity = 'WARNING'
            }
            else
            {
                Log-Info "Multiple failures detected or failure other than Active Directory Configuration, keeping severity at CRITICAL."
                $severity = 'CRITICAL'
            }
        }
        #endregion

        $params = @{
            Name               = 'AzStackHci_Cluster_Test-Cluster_Results'
            Title              = 'Test Cluster'
            DisplayName        = 'Test Cluster'
            Severity           = $severity
            Description        = 'Validating Cluster dependencies are met with Test-Cluster'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites'
            TargetResourceID   = $valResult.Source
            TargetResourceName = $valResult.Source
            TargetResourceType = 'Cluster'
            Timestamp          = [datetime]::UtcNow
            Status             = $valResult.Status
            AdditionalData     = @{
                Source    = $valResult.Source
                Resource  = 'Cluster'
                Detail    = $valResult.Detail
                Status    = $valResult.Status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $clusterValResultObs += New-AzStackHciResultObject @params

        # Write out the results to the log file
        $logType = if ($valResult.Status -eq 'FAILURE') { $severity } else { 'INFO' }
        $valResult.Detail | ForEach-Object { Log-Info ("{0} - {1}" -f $valResult.Source,$_) -Type $logType }
    }
    return $clusterValResultObs
}

function Invoke-TestCluster
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [String[]]
        $Node,

        [Parameter(Mandatory = $false)]
        [String]
        $OperationType,

        [Parameter(Mandatory = $false)]
        [ValidateSet('S2D', 'SAN', '')]
        [String]
        $StorageType
    )

    try
    {
        # Building node list the way test-cluster expects it
        $NodeNames = ($Node | ForEach-Object {"'$_'"}) -join ','
        Log-Info "Invoke-TestCluster called with OperationType=$OperationType, StorageType=$StorageType, Nodes=$NodeNames"

        $detail = "Failover Clustering not installed, skip Test Cluster Validation"
        $status = 'FAILURE'
        $clusterFeatureInstalled = Get-WindowsFeature -Name Failover-Clustering
        Log-Info "Failover-Clustering feature state: $($clusterFeatureInstalled.InstallState)"
        if ($clusterFeatureInstalled.InstallState -eq 'Installed') {

            $dateSuffix = [DateTime]::Now.ToString("yyyy-MM-dd.HH-mm-ss")
            $reportName = "AzStackHciEnvironmentChecker-ClusterValidationReport-{0}-{1}" -f $ENV:COMPUTERNAME,$dateSuffix
            try
            {
                # Need to pass an explicit set of tests
                # Storage Spaces Direct is not checked unless it is included (include and ignore params are not supported together in Test-Cluster)
                # exclude AD test if not domain joined
                # always exclude Network Communication test as some environments do not have NIC configured yet.
                $excludeTests = @('Validate Network Communication')
                $isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
                Log-Info "Domain joined: $isDomainJoined"
                if (!$isDomainJoined){
                    $excludeTests += @('Validate Active Directory Configuration')
                }

                # For SAN storage, data lives on shared FC/iSCSI LUNs (claimed by MPIO after this point);
                # local disks are intentionally not S2D-eligible. Exclude S2D-only and shared-storage tests
                # that require the cluster + MPIO to be fully formed before they can pass.
                if ($StorageType -eq 'SAN') {
                    Log-Info "SAN storage detected - excluding S2D-only and pre-cluster shared-storage tests"
                    $excludeTests += @(
                        'List All Disks for Storage Spaces Direct',
                        'List Disks',
                        'List Disks To Be Validated',
                        'List File Shares',
                        'List Storage Enclosures',
                        'List Storage Pools',
                        'List Storage Tiers',
                        'List Un-Poolable Disks',
                        'List Virtual Disks',
                        'List Volumes',
                        'Validate CSV Network Bindings',
                        'Validate CSV Settings',
                        'Validate Disk Access Latency',
                        'Validate Disk Arbitration',
                        'Validate Disk Failover',
                        'Validate File System',
                        'Validate Microsoft MPIO-based disks',
                        'Validate Multiple Arbitration',
                        'Validate SCSI device Vital Product Data (VPD)',
                        'Validate SCSI-3 Persistent Reservation',
                        'Validate Simultaneous Failover',
                        'Validate Storage Spaces Direct Support',
                        'Validate Storage Spaces Persistent Reservation',
                        'Verify Node and Disk Configuration',
                        'Verify Unique Device Identifiers',
                        'Verify Unique Enclosure Identifiers'
                    )
                }

                # For PreUpdate, only check Network tests and skip -List enumeration
                if ($OperationType -eq 'PreUpdate') {
                    Log-Info "PreUpdate operation - restricting to Network tests only"
                    $includeTests = 'Network'
                }
                else {
                    Log-Info "Enumerating available tests with Test-Cluster -List (excluding: $($excludeTests -join ', '))"
                    $includeTests = Test-Cluster -List | Select-Object -ExpandProperty DisplayName | Where-Object {$PsItem -notin $excludeTests}
                    Log-Info "Tests to include: $($includeTests -join ', ')"
                }

                $testClusterParams = @{
                    ReportName  = $reportName
                    Include     = $includeTests
                    ErrorAction = 'Stop'
                }

                # PreUpdate runs against an existing cluster - let Test-Cluster auto-discover
                # nodes. Passing explicit -Node with identically-named adapters (post Network ATC)
                # causes "An entry with the same key already exists" dictionary collisions.
                if ($OperationType -ne 'PreUpdate') {
                    $testClusterParams.Node = $Node
                    Log-Info "Passing explicit -Node list for $OperationType operation"
                }
                else {
                    Log-Info "PreUpdate: omitting -Node parameter, letting Test-Cluster auto-discover from existing cluster"
                }

                $nodeStr = if ($testClusterParams.Node) { "-Node $(($testClusterParams.Node | ForEach-Object {"'$_'"}) -join ',')" } else { '' }
                $includeStr = ($includeTests | ForEach-Object {"'$_'"}) -join ','
                $literalCmd = "Test-Cluster $nodeStr -ReportName '$reportName' -Include $includeStr"
                Log-Info "Executing: $literalCmd"
                # try and if we get access denied try remove fqdn from node names
                try
                {
                    $outputStreams = Test-Cluster @testClusterParams *>&1 | Out-String
                    Log-Info "Test-Cluster completed successfully"
                }
                catch
                {
                    Log-Info "Test-Cluster failed: $($_.Exception.Message)"
                    if ($_.Exception.Message -match 'Access is denied|An error occurred opening cluster|do not have administrative privileges')
                    {
                        if ($OperationType -ne 'PreUpdate')
                        {
                            Log-Info "Access denied executing Test-Cluster, retrying with short names."
                            $shortNames = $Node | ForEach-Object { ($_ -split '\.')[0] }
                            $testClusterParams.Node = $shortNames
                            $retryNodeStr = ($shortNames | ForEach-Object {"'$_'"}) -join ','
                            $literalCmd = "Test-Cluster -Node $retryNodeStr -ReportName '$reportName' -Include $includeStr"
                            Log-Info "Executing: $literalCmd"
                            $outputStreams = Test-Cluster @testClusterParams *>&1 | Out-String
                            Log-Info "Test-Cluster retry with short names completed successfully"
                        }
                        else
                        {
                            Log-Info "PreUpdate: access denied with auto-discovered nodes, re-throwing (no retry possible without -Node)"
                            throw $_
                        }
                    }
                    else
                    {
                        throw $_
                    }
                }
            }
            catch
            {
                $status = 'FAILURE'
                $detail = "Failed to execute Test-Cluster: $($_.Exception.Message)"
                Log-Info "Test-Cluster failed permanently: $($_.Exception.Message)"
                return @{
                    Source    = $ENV:COMPUTERNAME
                    Status    = $status
                    Detail    = $detail + "`r`nTest-Cluster Command:`r`n$literalCmd"
                }
            }

            # parse "Validation Data*.xml" for failure.
            $reportXmlPath = "C:\Windows\Cluster\Reports"
            $reportXml = (Get-ChildItem -Path $reportXmlPath -Filter "Validation Data*XML" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
            Log-Info "Parsing validation report: $reportXml"
            if ($reportXml)
            {
                [XML]$clusterValidationXML = Get-Content -Path $reportXML
                [int]$testStatus = $clusterValidationXML.Report.Channel.ValidationResult.Value.InnerText
                $decodedStatus = New-Object -TypeName psobject @{
                    'Completed'     = ($testStatus -band 0x1) -ne 0;
                    'HasUnselected' = ($testStatus -band 0x2) -ne 0;
                    'HasFailures'   = ($testStatus -band 0x4) -ne 0;
                    'HasWarnings'   = ($testStatus -band 0x8) -ne 0;
                    'Cancel'        = ($testStatus -band 0x10) -ne 0;
                    'NotApplicable' = ($testStatus -band 0x40) -ne 0
                }

                # Gather detailed output
                $channels = $clusterValidationXML.Report.Channel.Channel | Sort-Object -Property @{e={$_.Result.Value.'#cdata-section'}} -Descending
                $validationFailures = New-Object -TypeName System.Collections.ArrayList
                foreach ($channel in $channels)
                {
                    if ($channel.Type -eq 'Summary')
                    {
                        $channelId = $channel.id
                        foreach ($summaryChannel in $channels.Where({$_.SummaryChannel.Value.'#cdata-section' -eq $channelId}))
                        {
                            if ($summaryChannel.ResultDescription.Value.'#cdata-section' -match 'Fail|Warning')
                            {
                                $msg = ($summaryChannel.Message | Where-Object Level -ne 'Info').'#cdata-section' -join ' '
                                $null = $validationFailures.Add(("[!!{0}!!] - {1}: {2}" -f $summaryChannel.ResultDescription.Value.'#cdata-section', $summaryChannel.Title.Value.'#cdata-section', $msg ))
                            }
                            elseif ($summaryChannel.ResultDescription.Value.'#cdata-section' -match 'Not Applicable')
                            {
                                continue # Skip Not Applicable messages
                            }
                            else
                            {
                                $null = $validationFailures.Add(("[{0}] - {1}" -f $summaryChannel.ResultDescription.Value.'#cdata-section', $summaryChannel.Title.Value.'#cdata-section'))
                            }
                        }
                    }
                }

                # Determine success or failure
                Log-Info "Validation status bitmask=$testStatus Completed=$($decodedStatus.Completed), HasFailures=$($decodedStatus.HasFailures), HasWarnings=$($decodedStatus.HasWarnings)"
                if ($decodedStatus.Completed -and (-not $decodedStatus.HasFailures))
                {
                    $status = 'SUCCESS'
                    $detail = "Test Cluster Validation Results passed"
                    Log-Info "Cluster validation passed"
                }
                else
                {
                    $status = 'FAILURE'
                    Log-Info "Cluster validation failed with $($validationFailures.Count) issues"
                }
                $detail = "Test Cluster Validation Results: `r`n`r`n$(($validationFailures | Sort-Object) -join "`r`n"). `r`n$outputStreams Available on $ENV:COMPUTERNAME."
                Start-Sleep -Seconds 30 # wait for report files to be written
                # Attempt to copy the report files and test-cluster log to the log directory for EnvChkr
                $null = Copy-Item -Path "C:\Windows\Cluster\Reports\$reportName*" -Destination "$ENV:LocalRootFolderPath\MASLogs\" -Force -ErrorAction SilentlyContinue
                $null = Get-ChildItem -Path "C:\Windows\Cluster\Reports\" -Filter 'Test Cluster Log*' | `
                    Sort-Object LastWriteTime -Descending | `
                    Select-Object -First 1 | `
                    Copy-Item -Destination "$ENV:LocalRootFolderPath\MASLogs\" -Force -ErrorAction SilentlyContinue
                # rename the Test Cluster Logs we just copied to prefix them with AzStackHciEnvironmentChecker- plus their original name
                $null = Get-ChildItem -Path "$ENV:LocalRootFolderPath\MASLogs\" -Filter 'Test Cluster Log*' | `
                    Rename-Item -NewName { "AzStackHciEnvironmentChecker-$($_.Name)" } -ErrorAction SilentlyContinue

                $null = Copy-Item -Path "C:\Windows\Cluster\Reports\$reportName*" -Destination "$ENV:LocalRootFolderPath\MASLogs\" -Force -ErrorAction SilentlyContinue
            }
        }

        return @{
            Source    = $ENV:COMPUTERNAME
            Status    = $status
            Detail    = $detail + "`r`nTest-Cluster Command:`r`n$literalCmd"
        }
    }
    catch
    {
        throw "Executing test cluster failed: $($_.Exception)"
    }
}

Export-ModuleMember -Function Test-*, Validate-AzLocalClusterExists
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCFYKSeF7FI6349
# WlOHqL7PGkC9611RKhsFhnXHhx41dqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICiuXGse
# uU2gsxqlciSTwl2UBqEJ4ZofTPKM9F5lH10BMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEASnxH0qDlek2mh38fiHDegxrL8ibNJcJZQ+I3mpr9
# wAaCVd0aGCT/zqfLJwDvu9eDY+DT0fU7KIoXHP5Y35gYLRWG7vuYdF3Y188KfAj7
# vHvbw2ioR8DkH2E79tlHN9uma3cXx6PjctX7+5jU1PuPqWWpgXZ4qTm/2Ep0W4zv
# rVzOlJ/mDOWLdVxRFqHV2kGSFc/EJ91A+5KoUIhTSs1zLDKpJS3TWwRRiX27OOnR
# cqkOOtqSPN9qQTabyrjg69Xx5jNYn6FE//ZjcWYesR+vT1EqyWm9mq5ThAVBexXL
# DXHR3AwbTBb0/fU7rI/tTIlXCQULWE0oT85Rp7yriQO48KGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDeqmcC8L/IKwGGvzYJ1S19VUJbGmLf29WM6vX8
# IMJZ+QIGaefsSb9MGBMyMDI2MDUwMzE0MzExMC42MzlaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiAk4ebgF7m0jgABAAAC
# IDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTJaFw0yNzA1MTcxOTM5NTJaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDRYY7yr7ijW6CR178uKveIMufu
# tWOicxgJwKOce/2GOQceus6ZWfX14i3jNg3JOP7MGJMkOAucwWBwiA8URp+ZYkGj
# pVoVkGZsV27WjqLwpf2AwqBsJ/TzqwE7JFFaxup3Ldxj8GjdJymDFRrdVN/pYHoB
# FrjD1IkIDu8b1CWn8tgomiKRSY+STvJq99mVkdphMBIUGOegQny8qRd24VME0xi8
# Oomks9Zq9EjDeKHGpvAbXUEQ6m3cROoEPhTE/miweQH9TqJt3IOsqPv3L8urojB7
# 47XBC2y0CDIHlKLcLl3ZG8D7JXKnWTFen3msMPJpcvrQ3zUBVJrH/mI3RxHmCh9p
# pDP0uG1+PJwk6H/x+sfoG9hW64xoXkpx6DEfNZNfcXdKbXF28XEXdLNnzo3SLNVy
# meQJhNqOSKhnU84QnKmrjEk541JiurlDCkCWO9lUBUMb9x0nyfXUbNRPVLgP+PTM
# RdXOowJdYCzCQfN2ZqL0s4YI28F1Dbn7Bgw2E4P1E9unsvMzJHtzhS2Th3TpCfBb
# OGalIlF9x/DJZ/ssm/yyzT9YtIFeqmfNxBPTE3aOuh6HxmTICzfYAATvWNhBbo19
# QwsjPeA9JvhqTLC2KUNgrXroGy4eDZo0n7jFYjZkUih1Ty+8E6qEvV2Na6Z5gUyD
# 5a+tHGDmq69CmUiHfwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNvInOCIhxGA8mY7
# l1g07UHvyNgzMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCtKGBto1BSvm4WFI+J
# 0NSyVhU1LHL7F3fbjZ2d7F5Kn/FCTBZXpzrDVl63FLRNcIFpnJy4/nlg43r7T5sJ
# Pdo4Ms8ADSHQEJnHSu3x9UpjCzREBPi9+nHhvDgRx/1WmBD6gQUZJLOhcN2TxW4K
# JyhinMtiBFtkNRZ2vmZ1MAdNXTm5d0Lwk3wzj+/f7VCCTWCXJSoqNa3VU/6sACHI
# 97Evbnzg8bd3hxrfz6CcCVuf77egvRHinthJuwSRePP7aVmcevb1nWUIAICdBebH
# QOrzNIeWBIQwvcFaS3SFc+49rqrwQOMFDR4FYBzS7b0QeBVxFuLL2iVu4KAHMNUh
# LLSD4iKLDFBNTOtTzTlhGvMgG77A1cjeQrDMHa6oReMDeUDqHUrxv8g7IRdIh+h0
# gDLkzN0xIuzli0Bv7JtybGJbV6JxaDF4CzSCIMRpK59nI6iKo4LgnbQBZJW7+6ak
# YsKG/pXPlfxNv2InpD10tSCkCvw9kr6W1+NRN+EuZczRgAwWlcK9XJZ3uu/v/oxH
# tO7/kmVIs51F9qV6Y2QNXd6tU46YPrK98m2QDys+lvLNimK0e1xZ7Z1GawKohKGv
# lLALWDlZQqgHfJ31CB0LlIDI7iLyYTpd2iyKjqskbQiyMtICH+RmH/oCg7JOK0ZA
# 3XIMba9aSWgBF3QZ6pG3EGeQqjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkYwMDItMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCTGA9vpsJ6glqCLmI0rggGx4YEEqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aGSNjAiGA8y
# MDI2MDUwMzA5MjE1OFoYDzIwMjYwNTA0MDkyMTU4WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoZI2AgEAMAoCAQACAgf9AgH/MAcCAQACAhMdMAoCBQDtouO2AgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAFNfkdXeXF05NORxEvFIYKQz5V3n
# c0Db6P70ZyLIP1cg4irSQCsz0H+CrzudtVi3na5BvjzkqbsuH/eRUkQn+gBQUuAr
# 9ZK8p2f085QNPQ7fXOTjDSV5jOHO5L72Ys1TrzrFJdVvQjb1VlvBI3QOjvtLSkWG
# UbKYMrNNK1CyoZpNjutgmLezsK69Y+peVN2Y+x78jGhVOmXXYWGJrjrv1iG/WmPW
# QUvFavF/sCMBCexcYkoht6+c04bi2MX655+Szv/1FNF30avJm71dxnYegaarQipR
# ZD7IXG0H4muSnLfvf/neyx2w2zAwPi+p3YP+0shgQymgqolcDG0hYdYEp2UxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiAk
# 4ebgF7m0jgABAAACIDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAONTjIbEQXit6l2lcYw3bcb2Dz
# KECWCZNgaUkVub5lHTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EION7vyOl
# PA1VqlEp0QIVGlNd8S5YWBnKj97LuTWHSO2vMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIgJOHm4Be5tI4AAQAAAiAwIgQgJ/zFE03B
# CfUpoXjUtBZKerlMmArdnX03kdlRHISH7mUwDQYJKoZIhvcNAQELBQAEggIAhPkT
# x6u9Ua8WPBU4bCpEK57bozCA/qpV/pCmiXhK8k3FYCSyKHpuHcesl8vC35Oi7oTy
# TAdt1Rahmqn8+q7TsCsJrMPF4ZfXsyamXOkX7ny8Ie2BiTrkoEfIPnOd7QfKW6YW
# Pd+WGqWbGgzhXIvcghh6GWfhZcO8HrDpRwqqwFCJaChC56TFA6N+eYVPYtEhULWl
# Gq+BCnHw6DjTDU0wRIrTLgvm+BwWFf8jDsOGC/gfDYjPiA/AEdbmHLmpgMcv6ncM
# DFSBuKifrlIXP0bgZR6pUqjvslRGboyUBr2RIba9y81nWpIbEBfk1xVIW3onShl8
# EtLTbI+GfrxT6q7RBzMfeqQ6MqFnryPm6SdZ4Na2U1ktNmrCfS8CmPjQCiTzQbG8
# 9/SpxktKw2Ed/JGnJl6pMxGb9vNSfMh1JSEXlRy52ueZO1cffPL1Ona9qhchJbPi
# P0ND5N8vrJ2FAUCLOuwoOjEgFw2OrpvCqGfSIwmIkh7jay+n/285KD2JLdtLDTTB
# j4c49BqYAsPjN/5mjTq8O5E/wgsL/Qu/C1Fz6nHO5saiHSpb8+qLHITweYUrZR8b
# +DD4tmRiZMDkBW0GHHeYlL4QD/kJ36B4t0C7QHb/DHeALrdYgOqQS7rcY3xOhZoX
# Wby6WyaAF62pYcCPZSd5PMJviPM+jd5mXH8aT28=
# SIG # End signature block
