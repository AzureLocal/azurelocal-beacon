Import-LocalizedData -BindingVariable lblTxt -FileName AzureLocal.SANValidator.Strings.psd1

function Test-SANFibreChannelConnectivity
{
    <#
    .SYNOPSIS
        Validate Fibre Channel HBA ports are online and configured SAN LUNs are visible on all nodes.
    .DESCRIPTION
        Enumerates Fibre Channel initiator ports on each node using Get-InitiatorPort,
        filters by ConnectionType 'Fibre Channel', and validates that at least one HBA
        port exists and all discovered ports report OperationalStatus 'Operational'.
        When SANVolumeMapping is provided, also verifies that each configured LUN
        (Infrastructure_1 and ClusterPerformanceHistory) is visible on each node by
        matching disk UniqueId against the specified LUN IDs.
        When PsSession is provided, runs the check on each remote node and returns
        one result object per node.
    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If not provided, runs locally.
    .PARAMETER SANVolumeMapping
        Optional SANVolumeMapping configuration from ECE parameters containing LUN IDs.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false)]
        $SANVolumeMapping
    )

    try
    {
        # Extract LUN IDs from configuration
        $lunIdList = @()
        if ($SANVolumeMapping) {
            $infraLunId = ($SANVolumeMapping.Volume | Where-Object Name -eq "Infrastructure_1").LunId
            if ($infraLunId -and $infraLunId -ne "" -and $infraLunId -notmatch '^\[') {
                $lunIdList += $infraLunId
            }
            $perfLunId = $SANVolumeMapping.PerfVolume.LunId
            if ($perfLunId -and $perfLunId -ne "" -and $perfLunId -notmatch '^\[') {
                $lunIdList += $perfLunId
            }
        }

        $scriptBlock = {
            param ($LunIdList)
            $fcPorts = Get-InitiatorPort | Where-Object { $_.ConnectionType -eq 'Fibre Channel' }
            $status = 'SUCCESS'
            $detail = ''

            if (-not $fcPorts -or $fcPorts.Count -eq 0)
            {
                $status = 'FAILURE'
                $detail = 'No Fibre Channel HBA adapters were detected on this node. Ensure FC HBAs are installed and connected.'
            }
            else
            {
                $offlinePorts = @($fcPorts | Where-Object { $_.OperationalStatus -ne 'Operational' })
                if ($offlinePorts.Count -gt 0)
                {
                    $status = 'FAILURE'
                    $detail = ($offlinePorts | ForEach-Object {
                        "Fibre Channel port '$($_.NodeAddress)' is not online. Current status: '$($_.OperationalStatus)'."
                    }) -join ' '
                }
                else
                {
                    $detail = "Fibre Channel connectivity validated. $($fcPorts.Count) HBA port(s) detected and online."
                }
            }

            # When connectivity passes and LUN IDs are configured, verify specific LUNs are visible
            if ($status -eq 'SUCCESS' -and $LunIdList -and $LunIdList.Count -gt 0) {
                $sanDisks = Get-Disk | Where-Object { $_.BusType -eq 'Fibre Channel' }
                $missingLuns = @()
                foreach ($lunId in $LunIdList)
                {
                    $matchedDisk = $sanDisks | Where-Object { $_.UniqueId -ieq $lunId }
                    if (-not $matchedDisk)
                    {
                        $missingLuns += $lunId
                    }
                }
                if ($missingLuns.Count -gt 0)
                {
                    $status = 'FAILURE'
                    $detail += " The following configured LUN(s) are not visible: $($missingLuns -join ', '). Verify SAN zoning and LUN masking for this host."
                }
            }

            return @{
                ComputerName = $ENV:COMPUTERNAME
                Status       = $status
                Detail       = $detail
                PortCount    = if ($fcPorts) { $fcPorts.Count } else { 0 }
            }
        }

        $nodeData = @()
        if ($PsSession) {
            $nodeData += Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock -ArgumentList (,$lunIdList)
        }
        else {
            $nodeData += Invoke-Command -ScriptBlock $scriptBlock -ArgumentList (,$lunIdList)
        }

        $instanceResults = @()
        foreach ($node in $nodeData)
        {
            $computerName = $node.ComputerName
            if ($node.Status -ne 'SUCCESS')
            {
                Log-Info $node.Detail -Type Warning
            }
            else
            {
                Log-Info $node.Detail
            }

            $diagnosticDetail = $node.Detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    Get-InitiatorPort | Where-Object { `$_.ConnectionType -eq 'Fibre Channel' }"
            $diagnosticDetail += "`n    Get-InitiatorPort | Where-Object { `$_.ConnectionType -eq 'Fibre Channel' } | Select-Object NodeAddress, PortAddress, OperationalStatus"

            $remediationMsg = $lblTxt.FCRemediation

            $params = @{
                Name               = 'AzureLocal_SAN_Test_FC_Connectivity'
                Title              = 'Test Fibre Channel Connectivity'
                DisplayName        = "Test Fibre Channel Connectivity $computerName"
                Severity           = 'CRITICAL'
                Description        = 'Enumerates Fibre Channel initiator ports using Get-InitiatorPort, validates that at least one HBA port is present, and checks that all discovered ports report OperationalStatus Operational. When configured LUN IDs are provided, also verifies each LUN is visible on the node.'
                Remediation        = $remediationMsg
                TargetResourceID   = "$computerName/FibreChannelHBA"
                TargetResourceName = "FibreChannelHBA-$computerName"
                TargetResourceType = 'FibreChannelHBA'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = $node.Status
                AdditionalData     = @{
                    Source    = $computerName
                    Resource  = 'FibreChannelHBA'
                    Detail    = $diagnosticDetail
                    Status    = $node.Status
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing Fibre Channel connectivity: {0}" -f $_.Exception)
    }
}

function Test-SANiSCSIConnectivity
{
    <#
    .SYNOPSIS
        Validate iSCSI initiator service is running, sessions are established, and configured LUNs are visible.
    .DESCRIPTION
        Checks each node for the MSiSCSI service using Get-Service, validates it is
        in a Running state, then enumerates active iSCSI sessions via Get-IscsiSession
        to confirm at least one session is established to a target.
        When SANVolumeMapping is provided, also verifies that each configured LUN
        (Infrastructure_1 and ClusterPerformanceHistory) is visible on each node by
        matching disk UniqueId against the specified LUN IDs.
        When PsSession is provided, runs the check on each remote node and returns
        one result object per node.
    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If not provided, runs locally.
    .PARAMETER SANVolumeMapping
        Optional SANVolumeMapping configuration from ECE parameters containing LUN IDs.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false)]
        $SANVolumeMapping
    )

    try
    {
        # Extract LUN IDs from configuration
        $lunIdList = @()
        if ($SANVolumeMapping) {
            $infraLunId = ($SANVolumeMapping.Volume | Where-Object Name -eq "Infrastructure_1").LunId
            if ($infraLunId -and $infraLunId -ne "" -and $infraLunId -notmatch '^\[') {
                $lunIdList += $infraLunId
            }
            $perfLunId = $SANVolumeMapping.PerfVolume.LunId
            if ($perfLunId -and $perfLunId -ne "" -and $perfLunId -notmatch '^\[') {
                $lunIdList += $perfLunId
            }
        }

        $scriptBlock = {
            param ($LunIdList)
            $status = 'SUCCESS'
            $detail = ''

            # Check iSCSI service
            $iscsiService = Get-Service -Name msiscsi -ErrorAction SilentlyContinue
            if (-not $iscsiService -or $iscsiService.Status -ne 'Running')
            {
                $serviceStatus = if ($iscsiService) { $iscsiService.Status } else { 'NotFound' }
                $status = 'FAILURE'
                $detail = "The MSiSCSI service is not running. Current status: '$serviceStatus'. Start the service with 'Start-Service msiscsi'."
            }
            else
            {
                # Check iSCSI sessions
                $iscsiSessions = Get-IscsiSession -ErrorAction SilentlyContinue
                if (-not $iscsiSessions -or $iscsiSessions.Count -eq 0)
                {
                    $status = 'FAILURE'
                    $detail = 'No iSCSI sessions are established. Ensure iSCSI targets are configured and connections are active.'
                }
                else
                {
                    $detail = "iSCSI connectivity validated. $($iscsiSessions.Count) active session(s) detected."
                }
            }

            # When connectivity passes and LUN IDs are configured, verify specific LUNs are visible
            if ($status -eq 'SUCCESS' -and $LunIdList -and $LunIdList.Count -gt 0) {
                $sanDisks = Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' }
                $missingLuns = @()
                foreach ($lunId in $LunIdList)
                {
                    $matchedDisk = $sanDisks | Where-Object { $_.UniqueId -ieq $lunId }
                    if (-not $matchedDisk)
                    {
                        $missingLuns += $lunId
                    }
                }
                if ($missingLuns.Count -gt 0)
                {
                    $status = 'FAILURE'
                    $detail += " The following configured LUN(s) are not visible: $($missingLuns -join ', '). Verify SAN zoning and LUN masking for this host."
                }
            }

            return @{
                ComputerName = $ENV:COMPUTERNAME
                Status       = $status
                Detail       = $detail
            }
        }

        $nodeData = @()
        if ($PsSession) {
            $nodeData += Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock -ArgumentList (,$lunIdList)
        }
        else {
            $nodeData += Invoke-Command -ScriptBlock $scriptBlock -ArgumentList (,$lunIdList)
        }

        $instanceResults = @()
        foreach ($node in $nodeData)
        {
            $computerName = $node.ComputerName
            if ($node.Status -ne 'SUCCESS')
            {
                Log-Info $node.Detail -Type Warning
            }
            else
            {
                Log-Info $node.Detail
            }

            $diagnosticDetail = $node.Detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    Get-Service -Name msiscsi"
            $diagnosticDetail += "`n    Get-IscsiSession | Select-Object SessionIdentifier, TargetNodeAddress, IsConnected"
            $diagnosticDetail += "`n    Get-IscsiTarget | Select-Object NodeAddress, IsConnected"

            $remediationMsg = $lblTxt.iSCSIRemediation

            $params = @{
                Name               = 'AzureLocal_SAN_Test_iSCSI_Connectivity'
                Title              = 'Test iSCSI Connectivity'
                DisplayName        = "Test iSCSI Connectivity $computerName"
                Severity           = 'CRITICAL'
                Description        = 'Checks the MSiSCSI service status using Get-Service, validates it is Running, and enumerates active iSCSI sessions via Get-IscsiSession to confirm at least one session is established to a target. When configured LUN IDs are provided, also verifies each LUN is visible on the node.'
                Remediation        = $remediationMsg
                TargetResourceID   = "$computerName/iSCSIInitiator"
                TargetResourceName = "iSCSIInitiator-$computerName"
                TargetResourceType = 'iSCSIInitiator'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = $node.Status
                AdditionalData     = @{
                    Source    = $computerName
                    Resource  = 'iSCSIInitiator'
                    Detail    = $diagnosticDetail
                    Status    = $node.Status
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing iSCSI connectivity: {0}" -f $_.Exception)
    }
}

function Test-SANLUNCapacity
{
    <#
    .SYNOPSIS
        Validate each SAN LUN meets its per-LUN minimum capacity requirement.
    .DESCRIPTION
        Enumerates disks using Get-Disk, filters by the specified BusType ('Fibre Channel'
        or 'iSCSI'), and validates each presented SAN LUN against its type-specific minimum
        capacity. When SANVolumeMapping is provided, identifies each disk's LUN type by
        matching disk UniqueId against configured LUN IDs and applies per-type
        minimums (Infrastructure_1 >= 250 GB by default, overridable via MinSize attribute, ClusterPerformanceHistory >= 20 GB).
        Unrecognized disks produce a warning but do not fail validation.
        Without SANVolumeMapping, falls back to a 20 GB minimum for all disks.
    .PARAMETER BusType
        The SAN bus type to filter disks. Valid values: 'Fibre Channel', 'iSCSI'.
    .PARAMETER SANVolumeMapping
        Optional SANVolumeMapping configuration from ECE parameters containing LUN IDs
        and MinSize attributes for per-LUN capacity validation.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Fibre Channel', 'iSCSI')]
        [string]
        $BusType,

        [Parameter(Mandatory = $false)]
        $SANVolumeMapping
    )

    try
    {
        $instanceResults = [System.Collections.Generic.List[object]]::new()
        $remediationMsg = $lblTxt.LUNCapacityRemediation

        # Build per-LUN minimum size lookup from SANVolumeMapping
        $lunMinSizes = @{}  # LunId -> @{ VolumeName; MinSizeBytes }
        $defaultMinSizeBytes = 20 * 1GB  # Fallback when no mapping provided

        if ($SANVolumeMapping)
        {
            # Infrastructure_1 - single LunId with optional MinSize attribute
            $infraVol = $SANVolumeMapping.Volume | Where-Object Name -eq "Infrastructure_1"
            if ($infraVol -and $infraVol.LunId -and $infraVol.LunId -ne "" -and $infraVol.LunId -notmatch '^\[')
            {
                $infraMinBytes = 250 * 1GB
                if ($infraVol.MinSize -and $infraVol.MinSize -match '(\d+)\s*(TB|GB|MB)')
                {
                    $sizeValue = [long]$Matches[1]
                    $infraMinBytes = switch ($Matches[2]) {
                        'TB' { $sizeValue * 1TB }
                        'GB' { $sizeValue * 1GB }
                        'MB' { $sizeValue * 1MB }
                    }
                }
                $lunMinSizes[$infraVol.LunId] = @{ VolumeName = 'Infrastructure_1'; MinSizeBytes = $infraMinBytes }
            }

            # PerfVolume (ClusterPerformanceHistory) - single LunId, minimum 20 GB
            $perfVol = $SANVolumeMapping.PerfVolume
            if ($perfVol -and $perfVol.LunId -and $perfVol.LunId -ne "" -and $perfVol.LunId -notmatch '^\[')
            {
                $lunMinSizes[$perfVol.LunId] = @{ VolumeName = 'ClusterPerformanceHistory'; MinSizeBytes = 20 * 1GB }
            }
        }

        $hasMapping = $SANVolumeMapping -and $lunMinSizes.Count -gt 0
        $descriptionMsg = if ($hasMapping) {
            "Enumerates disks using Get-Disk, filters by BusType '$BusType', identifies each LUN type from SANVolumeMapping, and validates per-LUN minimum capacity requirements."
        } else {
            "Enumerates disks using Get-Disk, filters by BusType '$BusType', and validates each presented SAN LUN has a capacity of at least $([math]::Round($defaultMinSizeBytes / 1GB)) GB."
        }

        $sanDisks = Get-Disk | Where-Object { $_.BusType -eq $BusType }

        if (-not $sanDisks -or $sanDisks.Count -eq 0)
        {
            $detail = $lblTxt.NoSANDisksFound -f $BusType
            Log-Info $detail -Type Warning

            $diagnosticDetail = $detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    Get-Disk | Where-Object { `$_.BusType -eq '$BusType' }"
            $diagnosticDetail += "`n    Get-Disk | Select-Object Number, FriendlyName, BusType, Size, OperationalStatus"

            $params = @{
                Name               = 'AzureLocal_SAN_Test_LUN_Capacity'
                Title              = 'Test SAN LUN Capacity'
                DisplayName        = "Test SAN LUN Capacity $($ENV:COMPUTERNAME)"
                Severity           = 'CRITICAL'
                Description        = $descriptionMsg
                Remediation        = $remediationMsg
                TargetResourceID   = "$($ENV:COMPUTERNAME)/SANDisk"
                TargetResourceName = "SANDisk-$($ENV:COMPUTERNAME)"
                TargetResourceType = 'SANDisk'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = 'FAILURE'
                AdditionalData     = @{
                    Source    = $ENV:COMPUTERNAME
                    Resource  = 'SANDisk'
                    Detail    = $diagnosticDetail
                    Status    = 'FAILURE'
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults.Add((New-AzStackHciResultObject @params))
        }
        else
        {
            $detailResults = @()
            foreach ($disk in $sanDisks)
            {
                $diskSizeGB = [math]::Round($disk.Size / 1GB, 2)
                $lunType = $null
                $minCapacityBytes = $defaultMinSizeBytes

                # Identify LUN type from SANVolumeMapping by matching UniqueId
                if ($hasMapping)
                {
                    foreach ($lunId in $lunMinSizes.Keys)
                    {
                        if ($disk.UniqueId -ieq $lunId)
                        {
                            $lunType = $lunMinSizes[$lunId].VolumeName
                            $minCapacityBytes = $lunMinSizes[$lunId].MinSizeBytes
                            break
                        }
                    }
                }

                $minCapacityGB = [math]::Round($minCapacityBytes / 1GB, 0)

                if ($hasMapping -and -not $lunType)
                {
                    # Unrecognized disk - warning only, do not fail
                    $status = 'SUCCESS'
                    $detail = $lblTxt.LUNCapacityUnrecognizedDisk -f $disk.Number, $disk.FriendlyName, $disk.BusType, $diskSizeGB
                    Log-Info $detail -Type Warning
                }
                elseif ($disk.Size -lt $minCapacityBytes)
                {
                    $status = 'FAILURE'
                    if ($lunType)
                    {
                        $detail = $lblTxt.LUNCapacityInsufficientPerLun -f $disk.Number, $disk.FriendlyName, $disk.BusType, $lunType, $diskSizeGB, $minCapacityGB
                    }
                    else
                    {
                        $detail = $lblTxt.LUNCapacityInsufficient -f $disk.Number, $disk.FriendlyName, $disk.BusType, $diskSizeGB, $minCapacityGB
                    }
                    Log-Info $detail -Type Warning
                }
                else
                {
                    $status = 'SUCCESS'
                    if ($lunType)
                    {
                        $detail = "Disk $($disk.Number) ($($disk.FriendlyName)) identified as $lunType, capacity $diskSizeGB GB meets minimum $minCapacityGB GB."
                    }
                    else
                    {
                        $detail = "Disk $($disk.Number) ($($disk.FriendlyName)) has capacity $diskSizeGB GB (meets minimum $minCapacityGB GB)."
                    }
                }

                $detailResults += New-LightweightResult `
                    -Name 'AzureLocal_SAN_Test_LUN_Capacity' `
                    -Status $status `
                    -Severity 'CRITICAL' `
                    -TargetResourceName "$($ENV:COMPUTERNAME)/SANDisk/$($disk.Number)" `
                    -Source $ENV:COMPUTERNAME `
                    -Resource "SANDisk-$($disk.Number)-$($disk.FriendlyName)" `
                    -Detail $detail
            }

            $successCount = @($detailResults | Where-Object { $_.Status -eq 'SUCCESS' }).Count
            if ($successCount -eq $sanDisks.Count)
            {
                $summaryDetail = $lblTxt.LUNCapacitySuccess -f $sanDisks.Count
                Log-Info $summaryDetail
            }

            $instanceResults = @(New-AggregatedTestResult `
                -TestName 'Test-SANLUNCapacity' `
                -DisplayName 'SAN LUN Capacity' `
                -Description $descriptionMsg `
                -DetailResults $detailResults `
                -ValidatorName 'SAN' `
                -ResourceType 'SANDisk' `
                -Remediation $remediationMsg)
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing SAN LUN capacity: {0}" -f $_.Exception)
    }
}

function Test-SANLUNPartitionStyle
{
    <#
    .SYNOPSIS
        Validate that SAN LUNs have a RAW partition style.
    .DESCRIPTION
        Enumerates disks using Get-Disk, filters by the specified BusType ('Fibre Channel'
        or 'iSCSI'), and validates that each presented SAN LUN has a PartitionStyle of
        'RAW'. Disks with existing partition tables (GPT or MBR) will fail validation
        because Azure Local requires uninitialized LUNs for deployment.
        Runs locally since SAN LUNs are shared storage and partition style is
        consistent across all nodes.
    .PARAMETER BusType
        The SAN bus type to filter disks. Valid values: 'Fibre Channel', 'iSCSI'.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Fibre Channel', 'iSCSI')]
        [string]
        $BusType
    )

    try
    {
        $instanceResults = @()
        $remediationMsg = $lblTxt.LUNPartitionStyleRemediation
        $descriptionMsg = "Enumerates disks using Get-Disk, filters by BusType '$BusType', and validates each SAN LUN has a PartitionStyle of 'RAW'. Disks with GPT or MBR partition tables must be wiped before deployment."

        $sanDisks = Get-Disk | Where-Object { $_.BusType -eq $BusType }

        if (-not $sanDisks -or $sanDisks.Count -eq 0)
        {
            $detail = $lblTxt.NoSANDisksFound -f $BusType
            Log-Info $detail -Type Warning

            $diagnosticDetail = $detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    Get-Disk | Where-Object { `$_.BusType -eq '$BusType' } | Select-Object Number, FriendlyName, PartitionStyle"

            $params = @{
                Name               = 'AzureLocal_SAN_Test_LUN_PartitionStyle'
                Title              = 'Test SAN LUN Partition Style'
                DisplayName        = "Test SAN LUN Partition Style $($ENV:COMPUTERNAME)"
                Severity           = 'CRITICAL'
                Description        = $descriptionMsg
                Remediation        = $remediationMsg
                TargetResourceID   = "$($ENV:COMPUTERNAME)/SANDisk"
                TargetResourceName = "SANDisk-$($ENV:COMPUTERNAME)"
                TargetResourceType = 'SANDisk'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = 'FAILURE'
                AdditionalData     = @{
                    Source    = $ENV:COMPUTERNAME
                    Resource  = 'SANDisk'
                    Detail    = $diagnosticDetail
                    Status    = 'FAILURE'
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        else
        {
            foreach ($disk in $sanDisks)
            {
                $isRaw = $disk.PartitionStyle -eq 'RAW'

                if ($isRaw)
                {
                    $status = 'SUCCESS'
                    $detail = $lblTxt.LUNPartitionStyleSuccess -f $disk.Number, $disk.FriendlyName, $ENV:COMPUTERNAME
                    Log-Info $detail
                }
                else
                {
                    $status = 'FAILURE'
                    $detail = $lblTxt.LUNPartitionStyleNotRaw -f $disk.Number, $disk.FriendlyName, $disk.PartitionStyle, $ENV:COMPUTERNAME
                    Log-Info $detail -Type Warning
                }

                $diagnosticDetail = $detail
                $diagnosticDetail += "`nDiagnostic commands:"
                $diagnosticDetail += "`n    Get-Disk -Number $($disk.Number) | Select-Object Number, FriendlyName, BusType, PartitionStyle, Size"
                $diagnosticDetail += "`n    Get-Disk | Where-Object { `$_.BusType -eq '$BusType' } | Format-Table Number, FriendlyName, PartitionStyle, @{N='SizeGB';E={[math]::Round(`$_.Size/1GB,2)}}"

                $params = @{
                    Name               = 'AzureLocal_SAN_Test_LUN_PartitionStyle'
                    Title              = 'Test SAN LUN Partition Style'
                    DisplayName        = "Test SAN LUN Partition Style Disk $($disk.Number) ($($disk.FriendlyName))"
                    Severity           = 'CRITICAL'
                    Description        = $descriptionMsg
                    Remediation        = $remediationMsg
                    TargetResourceID   = "$($ENV:COMPUTERNAME)/SANDisk/$($disk.Number)"
                    TargetResourceName = "SANDisk-$($disk.Number)-$($disk.FriendlyName)"
                    TargetResourceType = 'SANDisk'
                    Timestamp          = [datetime]::UtcNow
                    HealthCheckSource  = $ENV:EnvChkrId
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $ENV:COMPUTERNAME
                        Resource  = "SANDisk-$($disk.Number)-$($disk.FriendlyName)"
                        Detail    = $diagnosticDetail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                }
                $instanceResults += New-AzStackHciResultObject @params
            }
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing SAN LUN partition style: {0}" -f $_.Exception)
    }
}

function Test-SANSCSIReservation
{
    <#
    .SYNOPSIS
        Validate that SAN LUNs have no stale SCSI-3 Persistent Reservations.
    .DESCRIPTION
        Enumerates SAN disks (Fibre Channel and iSCSI) and checks each for
        active SCSI-3 Persistent Reservations using Get-StorageReliabilityCounter.
        Stale reservations from a previously destroyed cluster will prevent
        Clear-Disk and disk initialization during deployment.
    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If not provided, runs locally.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try
    {
        $instanceResults = @()
        $remediationMsg = $lblTxt.SCSIReservationRemediation
        $descriptionMsg = "Checks SAN disks for active SCSI-3 Persistent Reservations that would block deployment. Stale reservations from a previous cluster must be cleared with Clear-ClusterDiskReservation."

        $scriptBlock = {
            $sanBusTypes = @('Fibre Channel', 'iSCSI')
            $sanDisks = @(Get-Disk | Where-Object { $_.BusType -in $sanBusTypes })
            $results = @()

            foreach ($disk in $sanDisks)
            {
                $hasReservation = $false
                try
                {
                    # Check for SCSI PR by attempting to query reservation status
                    # Disks with active PRs will have IsOffline=$true or fail Set-Disk
                    $reservationCheck = Get-Disk -Number $disk.Number
                    if ($reservationCheck.IsOffline)
                    {
                        # Try to bring online - if it fails with access denied, there is a PR
                        try
                        {
                            Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
                            # Succeeded - put it back if it was offline
                            Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction SilentlyContinue
                        }
                        catch
                        {
                            if ($_.Exception.Message -match 'reserved|access|not ready')
                            {
                                $hasReservation = $true
                            }
                        }
                    }
                }
                catch {}

                # Also check via cluster disk reservation query
                try
                {
                    $prInfo = Get-CimInstance -Namespace root/MSCluster -ClassName MSCluster_DiskToPR -ErrorAction Stop |
                        Where-Object { $_.Antecedent -like "*DiskNumber=$($disk.Number)*" }
                    if ($prInfo)
                    {
                        $hasReservation = $true
                    }
                }
                catch {}

                $results += [PSCustomObject]@{
                    Number         = $disk.Number
                    FriendlyName   = $disk.FriendlyName
                    BusType        = $disk.BusType
                    SerialNumber   = $disk.SerialNumber
                    HasReservation = $hasReservation
                }
            }

            [PSCustomObject]@{
                ComputerName = $ENV:COMPUTERNAME
                DiskCount    = $sanDisks.Count
                Results      = $results
            }
        }

        $nodeResults = @()
        if ($PsSession)
        {
            $nodeResults = @(Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock -ErrorAction Stop)
        }
        else
        {
            $nodeResults = @(& $scriptBlock)
        }

        foreach ($nodeResult in $nodeResults)
        {
            $computerName = $nodeResult.ComputerName

            if ($nodeResult.DiskCount -eq 0)
            {
                continue
            }

            $reservedDisks = @($nodeResult.Results | Where-Object { $_.HasReservation })

            if ($reservedDisks.Count -eq 0)
            {
                $detail = $lblTxt.SCSIReservationSuccess -f $nodeResult.DiskCount, $computerName
                Log-Info $detail

                $params = @{
                    Name               = 'AzureLocal_SAN_Test_SCSI_Reservation'
                    Title              = 'Test SAN SCSI Persistent Reservation'
                    DisplayName        = "Test SAN SCSI Persistent Reservation $computerName"
                    Severity           = 'CRITICAL'
                    Description        = $descriptionMsg
                    Remediation        = $remediationMsg
                    TargetResourceID   = "$computerName/SANDiskReservation"
                    TargetResourceName = "SANDiskReservation-$computerName"
                    TargetResourceType = 'SANDisk'
                    Timestamp          = [datetime]::UtcNow
                    HealthCheckSource  = $ENV:EnvChkrId
                    Status             = 'SUCCESS'
                    AdditionalData     = @{
                        Source    = $computerName
                        Resource  = 'SANDiskReservation'
                        Detail    = $detail
                        Status    = 'SUCCESS'
                        TimeStamp = [datetime]::UtcNow
                    }
                }
                $instanceResults += New-AzStackHciResultObject @params
            }
            else
            {
                foreach ($disk in $reservedDisks)
                {
                    $detail = $lblTxt.SCSIReservationFound -f $disk.Number, $disk.FriendlyName, $computerName
                    Log-Info $detail -Type Warning

                    $diagnosticDetail = $detail
                    $diagnosticDetail += "`nDiagnostic commands:"
                    $diagnosticDetail += "`n    Clear-ClusterDiskReservation -Disk $($disk.Number) -Force"
                    $diagnosticDetail += "`n    Get-Disk -Number $($disk.Number) | Select-Object Number, FriendlyName, IsOffline, PartitionStyle"

                    $params = @{
                        Name               = 'AzureLocal_SAN_Test_SCSI_Reservation'
                        Title              = 'Test SAN SCSI Persistent Reservation'
                        DisplayName        = "Test SAN SCSI Persistent Reservation Disk $($disk.Number) ($($disk.FriendlyName))"
                        Severity           = 'CRITICAL'
                        Description        = $descriptionMsg
                        Remediation        = $remediationMsg
                        TargetResourceID   = "$computerName/SANDisk/$($disk.Number)"
                        TargetResourceName = "SANDisk-$($disk.Number)-$($disk.FriendlyName)"
                        TargetResourceType = 'SANDisk'
                        Timestamp          = [datetime]::UtcNow
                        HealthCheckSource  = $ENV:EnvChkrId
                        Status             = 'FAILURE'
                        AdditionalData     = @{
                            Source    = $computerName
                            Resource  = "SANDisk-$($disk.Number)-$($disk.FriendlyName)"
                            Detail    = $diagnosticDetail
                            Status    = 'FAILURE'
                            TimeStamp = [datetime]::UtcNow
                        }
                    }
                    $instanceResults += New-AzStackHciResultObject @params
                }
            }
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing SAN SCSI reservations: {0}" -f $_.Exception)
    }
}

function Test-SANMPIOInstalled
{
    <#
    .SYNOPSIS
        Validate that the Multipath I/O (MPIO) Windows feature is installed.
    .DESCRIPTION
        Checks each node for the MultiPath-IO Windows feature using Get-WindowsFeature.
        MPIO is required for SAN storage path redundancy and failover.
        When PsSession is provided, runs the check on each remote node and returns
        one result object per node. Captures Get-MPIOSetting output in AdditionalData
        for telemetry.
    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If not provided, runs locally.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try
    {
        $instanceResults = @()
        $remediationMsg = $lblTxt.MPIORemediation
        $descriptionMsg = "Checks that the Multipath I/O (MPIO) Windows feature is installed on each node using Get-WindowsFeature. MPIO is required for SAN storage path redundancy and failover."

        $scriptBlock = {
            $status = 'SUCCESS'
            $detail = ''
            $mpioSettingsOutput = ''

            $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
            if (-not $mpioFeature -or -not $mpioFeature.Installed)
            {
                $status = 'FAILURE'
                $detail = "The Multipath I/O (MPIO) feature is not installed on node '$($ENV:COMPUTERNAME)'. MPIO is required for SAN storage redundancy and failover."
            }
            else
            {
                $detail = "MPIO feature is installed on node '$($ENV:COMPUTERNAME)'."

                # Capture Get-MPIOSetting for telemetry
                try
                {
                    $mpioSettings = Get-MPIOSetting -ErrorAction SilentlyContinue
                    if ($mpioSettings)
                    {
                        $mpioSettingsOutput = ($mpioSettings | Format-List | Out-String).Trim()
                    }
                }
                catch
                {
                    $mpioSettingsOutput = "Error retrieving MPIO settings: $($_.Exception.Message)"
                }
            }

            return @{
                ComputerName      = $ENV:COMPUTERNAME
                Status            = $status
                Detail            = $detail
                MPIOSettingsOutput = $mpioSettingsOutput
            }
        }

        $nodeData = @()
        if ($PsSession) {
            $nodeData += Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock
        }
        else {
            $nodeData += Invoke-Command -ScriptBlock $scriptBlock
        }

        foreach ($node in $nodeData)
        {
            $computerName = $node.ComputerName
            if ($node.Status -ne 'SUCCESS')
            {
                Log-Info $node.Detail -Type Warning
            }
            else
            {
                Log-Info $node.Detail
            }

            $diagnosticDetail = $node.Detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    Get-WindowsFeature -Name Multipath-IO"
            $diagnosticDetail += "`n    Get-MPIOSetting"
            if ($node.MPIOSettingsOutput)
            {
                $diagnosticDetail += "`n`nGet-MPIOSetting output:`n$($node.MPIOSettingsOutput)"
            }

            $params = @{
                Name               = 'AzureLocal_SAN_Test_MPIO_Installed'
                Title              = 'Test MPIO Installed'
                DisplayName        = "Test MPIO Installed $computerName"
                Severity           = 'CRITICAL'
                Description        = $descriptionMsg
                Remediation        = $remediationMsg
                TargetResourceID   = "$computerName/MPIO"
                TargetResourceName = "MPIO-$computerName"
                TargetResourceType = 'MPIO'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = $node.Status
                AdditionalData     = @{
                    Source    = $computerName
                    Resource  = 'MPIO'
                    Detail    = $diagnosticDetail
                    Status    = $node.Status
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing MPIO installation: {0}" -f $_.Exception)
    }
}

function Test-SANMPIOHardwareClaimed
{
    <#
    .SYNOPSIS
        Validate that all connected MPIO hardware is claimed by MSDSM.
    .DESCRIPTION
        Runs Get-MPIOAvailableHW and Get-MSDSMSupportedHW on each node. For every
        entry in AvailableHW (VendorId+ProductId), asserts it also exists in
        SupportedHW. Devices that are connected but not claimed will not have
        multipath failover enabled and will cause deployment issues.
        When PsSession is provided, runs the check on each remote node and returns
        one result object per node.
    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If not provided, runs locally.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try
    {
        $instanceResults = @()
        $remediationMsg = $lblTxt.MPIOHWRemediation
        $descriptionMsg = "Enumerates MPIO available hardware (Get-MPIOAvailableHW) and MSDSM supported hardware (Get-MSDSMSupportedHW) on each node, and validates that every connected device is claimed for multipath I/O."

        $scriptBlock = {
            $status = 'SUCCESS'
            $detail = ''
            $unclaimed = @()
            $availableHWOutput = ''
            $supportedHWOutput = ''

            try
            {
                $availableHW = @(Get-MPIOAvailableHW -ErrorAction SilentlyContinue)
                $supportedHW = @(Get-MSDSMSupportedHW -ErrorAction SilentlyContinue)

                # Capture raw output for telemetry
                if ($availableHW -and $availableHW.Count -gt 0)
                {
                    $availableHWOutput = ($availableHW | Format-Table -AutoSize | Out-String).Trim()
                }
                if ($supportedHW -and $supportedHW.Count -gt 0)
                {
                    $supportedHWOutput = ($supportedHW | Format-Table -AutoSize | Out-String).Trim()
                }

                # Filter MPIO available hardware to SAN bus types only.
                # Get-MPIOAvailableHW returns ALL MPIO-aware devices including local boot disks
                # (e.g., 'Msft Virtual Disk' on SAS bus). Local drives MUST NOT be claimed by
                # MSDSM - only multi-pathed SAN targets (FibreChannel/iSCSI) need MSDSM claim.
                # Without this filter, the check incorrectly flags healthy SAN deployments
                # where any local SAS drive is visible. (Bug 37766288)
                $sanBusTypes = @('FibreChannel', 'iSCSI')
                $sanAvailableHW = @($availableHW | Where-Object { $_.BusType -in $sanBusTypes })

                if (-not $availableHW -or $availableHW.Count -eq 0)
                {
                    $status = 'FAILURE'
                    $detail = "No MPIO available hardware was detected on node '$($ENV:COMPUTERNAME)'. Ensure SAN devices are connected and MPIO is properly configured."
                }
                else
                {
                    foreach ($hw in $sanAvailableHW)
                    {
                        $vendorId = "$($hw.VendorId)".Trim()
                        $productId = "$($hw.ProductId)".Trim()
                        $claimed = $supportedHW | Where-Object {
                            "$($_.VendorId)".Trim() -eq $vendorId -and "$($_.ProductId)".Trim() -eq $productId
                        }
                        if (-not $claimed)
                        {
                            $unclaimed += [PSCustomObject]@{
                                VendorId  = $vendorId
                                ProductId = $productId
                            }
                        }
                    }

                    if ($unclaimed.Count -gt 0)
                    {
                        $status = 'FAILURE'
                        $unclaimedList = ($unclaimed | ForEach-Object { "'$($_.VendorId) $($_.ProductId)'" }) -join ', '
                        $detail = "MPIO hardware not claimed on node '$($ENV:COMPUTERNAME)': $unclaimedList. These devices are connected but not added to the MSDSM supported hardware list."
                    }
                    else
                    {
                        $detail = "All $($sanAvailableHW.Count) SAN MPIO available hardware device(s) (FibreChannel/iSCSI) are claimed in MSDSM supported hardware on node '$($ENV:COMPUTERNAME)'."
                    }
                }
            }
            catch
            {
                $status = 'FAILURE'
                $detail = "MPIO cmdlets are not available on node '$($ENV:COMPUTERNAME)': $($_.Exception.Message). Ensure the MPIO feature is installed."
            }

            return @{
                ComputerName      = $ENV:COMPUTERNAME
                Status            = $status
                Detail            = $detail
                AvailableCount    = if ($availableHW) { $availableHW.Count } else { 0 }
                UnclaimedItems    = $unclaimed
                AvailableHWOutput = $availableHWOutput
                SupportedHWOutput = $supportedHWOutput
            }
        }

        $nodeData = @()
        if ($PsSession) {
            $nodeData += Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock
        }
        else {
            $nodeData += Invoke-Command -ScriptBlock $scriptBlock
        }

        foreach ($node in $nodeData)
        {
            $computerName = $node.ComputerName
            if ($node.Status -ne 'SUCCESS')
            {
                Log-Info $node.Detail -Type Warning
            }
            else
            {
                Log-Info $node.Detail
            }

            $diagnosticDetail = $node.Detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    Get-MPIOAvailableHW"
            $diagnosticDetail += "`n    Get-MSDSMSupportedHW"
            $diagnosticDetail += "`n    New-MSDSMSupportedHW -VendorId '<VendorId>' -ProductId '<ProductId>'"
            if ($node.AvailableHWOutput)
            {
                $diagnosticDetail += "`n`nGet-MPIOAvailableHW output:`n$($node.AvailableHWOutput)"
            }
            if ($node.SupportedHWOutput)
            {
                $diagnosticDetail += "`n`nGet-MSDSMSupportedHW output:`n$($node.SupportedHWOutput)"
            }

            $params = @{
                Name               = 'AzureLocal_SAN_Test_MPIO_HW_Claimed'
                Title              = 'Test MPIO Hardware Claimed'
                DisplayName        = "Test MPIO Hardware Claimed $computerName"
                Severity           = 'CRITICAL'
                Description        = $descriptionMsg
                Remediation        = $remediationMsg
                TargetResourceID   = "$computerName/MPIOHardware"
                TargetResourceName = "MPIOHardware-$computerName"
                TargetResourceType = 'MPIOHardware'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = $node.Status
                AdditionalData     = @{
                    Source    = $computerName
                    Resource  = 'MPIOHardware'
                    Detail    = $diagnosticDetail
                    Status    = $node.Status
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing MPIO hardware claimed: {0}" -f $_.Exception)
    }
}

function Test-SANMPIOPaths
{
    <#
    .SYNOPSIS
        Validate that MPIO disk paths are active using mpclaim.
    .DESCRIPTION
        Runs 'mpclaim -s -d' on each node and validates that it returns at least
        one MPIO disk entry. The full mpclaim output and Get-MPIOSetting output
        are captured in AdditionalData for telemetry diagnostics.
        When PsSession is provided, runs the check on each remote node and returns
        one result object per node.
    .PARAMETER PsSession
        Optional array of PSSessions to remote nodes. If not provided, runs locally.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    try
    {
        $instanceResults = @()
        $remediationMsg = $lblTxt.MPIOPathsRemediation
        $descriptionMsg = "Runs 'mpclaim -s -d' on each node to validate active MPIO disk paths exist. Captures full mpclaim output and Get-MPIOSetting for telemetry diagnostics."

        $scriptBlock = {
            $status = 'SUCCESS'
            $detail = ''
            $mpclaimOutput = ''
            $mpioSettingsOutput = ''
            $diskCount = 0

            try
            {
                $mpclaimRaw = & mpclaim -s -d 2>&1
                $mpclaimOutput = ($mpclaimRaw | Out-String).Trim()

                # Count MPIO disk lines (lines like "MPIO Disk0", "MPIO Disk5" — not the header)
                $mpioLines = @($mpclaimRaw | Where-Object { $_ -match '^\s*MPIO\s+Disk\d' })
                $diskCount = $mpioLines.Count

                if ($diskCount -eq 0)
                {
                    $status = 'FAILURE'
                    $detail = "No MPIO disk paths were returned by 'mpclaim -s -d' on node '$($ENV:COMPUTERNAME)'. Ensure MPIO is configured and SAN LUNs are presented with multiple paths."
                }
                else
                {
                    $detail = "MPIO paths validated on node '$($ENV:COMPUTERNAME)'. $diskCount MPIO disk(s) detected."
                }
            }
            catch
            {
                $status = 'FAILURE'
                $detail = "Failed to run 'mpclaim -s -d' on node '$($ENV:COMPUTERNAME)': $($_.Exception.Message)"
                $mpclaimOutput = $_.Exception.Message
            }

            # Capture Get-MPIOSetting for telemetry
            try
            {
                $mpioSettings = Get-MPIOSetting -ErrorAction SilentlyContinue
                if ($mpioSettings)
                {
                    $mpioSettingsOutput = ($mpioSettings | Format-List | Out-String).Trim()
                }
            }
            catch
            {
                $mpioSettingsOutput = "Error retrieving MPIO settings: $($_.Exception.Message)"
            }

            return @{
                ComputerName       = $ENV:COMPUTERNAME
                Status             = $status
                Detail             = $detail
                DiskCount          = $diskCount
                MpclaimOutput      = $mpclaimOutput
                MPIOSettingsOutput = $mpioSettingsOutput
            }
        }

        $nodeData = @()
        if ($PsSession) {
            $nodeData += Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock
        }
        else {
            $nodeData += Invoke-Command -ScriptBlock $scriptBlock
        }

        foreach ($node in $nodeData)
        {
            $computerName = $node.ComputerName
            if ($node.Status -ne 'SUCCESS')
            {
                Log-Info $node.Detail -Type Warning
            }
            else
            {
                Log-Info $node.Detail
            }

            $diagnosticDetail = $node.Detail
            $diagnosticDetail += "`nDiagnostic commands:"
            $diagnosticDetail += "`n    mpclaim -s -d"
            $diagnosticDetail += "`n    Get-MPIOSetting"
            if ($node.MpclaimOutput)
            {
                $diagnosticDetail += "`n`nmpclaim -s -d output:`n$($node.MpclaimOutput)"
            }
            if ($node.MPIOSettingsOutput)
            {
                $diagnosticDetail += "`n`nGet-MPIOSetting output:`n$($node.MPIOSettingsOutput)"
            }

            $params = @{
                Name               = 'AzureLocal_SAN_Test_MPIO_Paths'
                Title              = 'Test MPIO Paths'
                DisplayName        = "Test MPIO Paths $computerName"
                Severity           = 'CRITICAL'
                Description        = $descriptionMsg
                Remediation        = $remediationMsg
                TargetResourceID   = "$computerName/MPIOPaths"
                TargetResourceName = "MPIOPaths-$computerName"
                TargetResourceType = 'MPIOPaths'
                Timestamp          = [datetime]::UtcNow
                HealthCheckSource  = $ENV:EnvChkrId
                Status             = $node.Status
                AdditionalData     = @{
                    Source    = $computerName
                    Resource  = 'MPIOPaths'
                    Detail    = $diagnosticDetail
                    Status    = $node.Status
                    TimeStamp = [datetime]::UtcNow
                }
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        return $instanceResults
    }
    catch
    {
        throw ("Error testing MPIO paths: {0}" -f $_.Exception)
    }
}

Export-ModuleMember -Function Test-*

# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD9n1K40z8YASEP
# ZQlny+ag7l/Oy+nCKcZpaG9xJ4+4JKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEINuVxtREEJSLCKeKV513ys6UYrh2ig2iJynPzrz1O8eLMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEALd4RbLs13f+tmpv1ARKW
# z8BzwgLGC8UBJgo3JEgNZS/OCkxV10IltnSbxEJZHxfiHwUNvyo863yNbrHwRFzu
# DKti4cR8EigHEuSLexWfZlQ8xQ5KJKxpGaamlURZ5gVYibGoOAsJG9Gjddou1d65
# w3ZAFx60s3WjsbCVaPcw/9BGzdtR4k/FARrboop6Ub9nsSrgG7vjYv7yBxqvvtzh
# rbt8f2TS7eylRR4gb0YHAKOcmxXk9hwe1LJy+pooE+JKw5Ub2owlYTVLPcGezYMF
# G8lNBCOs93Bud+7aq1Fk+Nq1OCBYMB+jZXqs9NlKe2Z082dHLuN18gJuOhNfFHKm
# NKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCB6V7+tYnC0O9GyJNpR
# foxpKOdAmgtNFWl1lo3t9qX3TAIGaet1mUk/GBMyMDI2MDUwMzE0MzExMS4xODZa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACGqmgHQagD0OqAAEAAAIaMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyOFoXDTI2MTExMzE4
# NDgyOFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjMyMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAmYEAwSTz79q2V3ZWzQ5Ev7RKgadQtMBy7+V3XQ8R0NL8R9mu
# pxcqJQ/KPeZGJTER+9Qq/t7HOQfBbDy6e0TepvBFV/RY3w+LOPMKn0Uoh2/8IvdS
# bJ8qAWRVoz2S9VrJzZpB8/f5rQcRETgX/t8N66D2JlEXv4fZQB7XzcJMXr1puhuX
# bOt9RYEyN1Q3Z7YjRkhfBsRc+SD/C9F4iwZqfQgo82GG4wguIhjJU7+XMfrv4vxA
# FNVg3mn1PoMWGZWio+e14+PGYPVLKlad+0IhdHK5AgPyXKkqAhEZpYhYYVEItHOO
# vqrwukxVAJXMvWA3GatWkRZn33WDJVtghCW6XPLi1cDKiGE5UcXZSV4OjQIUB8vp
# 2LUMRXud5I49FIBcE9nT00z8A+EekrPM+OAk07aDfwZbdmZ56j7ub5fNDLf8yIb8
# QxZ8Mr4RwWy/czBuV5rkWQQ+msjJ5AKtYZxJdnaZehUgUNArU/u36SH1eXKMQGRX
# r/xeKFGI8vvv5Jl1knZ8UqEQr9PxDbis7OXp2WSMK5lLGdYVH8VownYF3sbOiRkx
# 5Q5GaEyTehOQp2SfdbsJZlg0SXmHphGnoW1/gQ/5P6BgSq4PAWIZaDJj6AvLLCdb
# URgR5apNQQed2zYUgUbjACA/TomA8Ll7Arrv2oZGiUO5Vdi4xxtA3BRTQTUCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBTwqyIJ3QMoPasDcGdGovbaY8IlNjAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEA1a72WFq7B6bJT3VOJ21nnToPJ9O/q51bw1bhPfQy
# 67uy+f8x8akipzNL2k5b6mtxuPbZGpBqpBKguDwQmxVpX8cGmafeo3wGr4a8Yk6S
# y09tEh/Nwwlsyq7BRrJNn6bGOB8iG4OTy+pmMUh7FejNPRgvgeo/OPytm4NNrMMg
# 98UVlrZxGNOYsifpRJFg5jE/Yu6lqFa1lTm9cHuPYxWa2oEwC0sEAsTFb69iKpN0
# sO19xBZCr0h5ClU9Pgo6ekiJb7QJoDzrDoPQHwbNA87Cto7TLuphj0m9l/I70gLj
# Eq53SHjuURzwpmNxdm18Qg+rlkaMC6Y2KukOfJ7oCSu9vcNGQM+inl9gsNgirZ6y
# Jk9VsXEsoTtoR7fMNU6Py6ufJQGMTmq6ZCq2eIGOXWMBb79ZF6tiKTa4qami3US0
# mTY41J129XmAglVy+ujSZkHu2lHJDRHs7FjnIXZVUE5pl6yUIl23jG50fRTLQcSt
# dwY/LvJUgEHCIzjvlLTqLt6JVR5bcs5aN4Dh0YPG95B9iDMZrq4rli5SnGNWev5L
# LsDY1fbrK6uVpD+psvSLsNpht27QcHRsYdAMALXM+HNsz2LZ8xiOfwt6rOsVWXoi
# HV86/TeMy5TZFUl7qB59INoMSJgDRladVXeT9fwOuirFIoqgjKGk3vO2bELrYMN0
# QVwwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMjFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUA8YrutmKpSrubCaAYsU4pt1Ft8DaggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2h0PswIhgPMjAyNjA1MDMx
# MzQ5NDdaGA8yMDI2MDUwNDEzNDk0N1owdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7aHQ+wIBADAHAgEAAgIhgDAHAgEAAgISrTAKAgUA7aMiewIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQAt4XyGiakMgToaQFPDGT4RlDT8FTwxseZnHmF5mRNr
# 9vxze8Q/VUVdVDMuya3xejZgmDDNO5wo1os8GWlkeqt0BIXF6OZXFmmY3ZdcMAzR
# hXW82qPzJMaNHK882QP1KnT6Tc6jhjtRd50QbqwANTbkrW53yM15wNB1jd+heSyD
# xJGxeuplaUm4vNquAJ+7XvvEgPlDY1pJ2GJw/Q9s7KncEX9OTm4ygm7MkqGXn5Fd
# KVdnIxiN6yGRLTetLcBm/BCQZDouz5KQfqnnx+onS3xlHUIZB6ZQ+54aBbUXkF9/
# Ra6QxlFWKCDH3J+671RkPGBppuu1W9SzTCnAeyqKBED/MYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIaqaAdBqAPQ6oAAQAA
# AhowDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgA5bjGOmlncWR+QjFALcIjd62Fqh47mCYZmyYia8T
# KPMwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCdeiHHrbtpKcwB20doVU89
# WHIOH8S7w37uaHcDmemK+zCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACGqmgHQagD0OqAAEAAAIaMCIEIOSELbW1MhcEtuDKmViA3xip
# yavIHZTcYA5xN6GxveJWMA0GCSqGSIb3DQEBCwUABIICAAHDL13JCOX2WCSwc9TU
# TLQCLRYscQ6NemSCtHm8/VG4Eq1A5hUHd6eE/Q8naLl+LMi0DX0/+VR/o7dLFWg+
# nFg93pFEp5P3i3d0F2NRdwZg5vt0Ck05c/YdjOiHpDWEVY0MUG0tGhjRhko7NInB
# GGbl5v12n6tNOViLpV5JERNxGUuiAkihsz7itxctvy7lpD8q3nPJxRekCEE8Odfz
# mzEarSYBsnz10UnbcWv4s6isT1TlFr/4hFIXnXxnUJwFCKqD46ge2nMMc2xnaHnB
# qjDn7vHEHQl21uMxMUma9LmFhjOAo24ASrNlM61OkjVfbHb4AGP2be1vSwv5ROJs
# vM3P0THrdIQ18ZWAhrIWpH+8bV49GDc9aI8xbwCQCYgfEX8pplXDrWESHzt0Iqks
# bWpSs0b4Aqj61fgflSCUjWBXaumK8CweRsTAMXIGhaDq85dVeKmMB8zvs3x4y++x
# EtdWa953hzWS83NDH9YVl4fyE7bNif1Ye/fMNzPDKvFVYVqHxOLj8dDHLUhk0LKG
# bFEtjPsYbZ++hrv702pgAhjN5W7Xs/CvsvFXpUA92rHm3p6BD4J0k/RBS0UT6AO7
# U+cxorXsoxkF0WQUX5KxNGqx+jI1DlVH0XJ4uKB+N8ECNi8GQY7EPvsqe54LcHjJ
# 1+1e8ZXUNdHHMiCXk/uqnBXH
# SIG # End signature block
