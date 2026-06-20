Import-LocalizedData -BindingVariable lhwTxt -FileName AzStackHci.Hardware.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.Hardware.Diagnostic.Helpers.psm1 -DisableNameChecking -Global

function Test-Processor
{
    <#
    .SYNOPSIS
        Test CPU
    .DESCRIPTION
        Test CPU
    .PARAMETER SummaryOnly
        When specified, returns only per-node summary results instead of individual property results.
        Use this at scale (>8 nodes) to reduce result count.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_Processor'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }
        $cimTest = Test-CimData -Data $remoteOutput -ClassName Processor -Severity WARNING -DiagnosticCommand 'Get-CimInstance -ClassName Win32_Processor -Property *'
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData

        $PropertyResult = @()
        $PropertySyncResult = @()
        $matchProperty = @(
            'Caption'
            'Family'
            'Manufacturer'
            'MaxClockSpeed'
            'NumberOfCores'
            'NumberOfEnabledCore'
            'NumberOfLogicalProcessors'
            'ThreadCount'
        )

        $warningDesiredPropertyValue = @{
            AddressWidth                            = @{ value = 64; hint = '64-bit' }
            Architecture                            = @{ value = 9; hint = '64-bit' } # x64
            Availability                            = @{ value = 3; hint = 'Running/Full Power' } # Running/Full Power
            CpuStatus                               = @{ value = 1; hint = 'CPU Enabled' } # CPU Enabled
            DataWidth                               = @{ value = 64; hint = '64-bit' } # x64
            ProcessorType                           = @{ value = 3; hint = 'Central Processor' } # Central Processor
            Status                                  = @{ value = 'OK'; hint = 'OK' }
        }

        $criticalDesiredPropertyValue = @{
            SecondLevelAddressTranslationExtensions = @{ value = $true; hint = 'Virtualization Support' }
            VirtualizationFirmwareEnabled           = @{ value = $true; hint = 'Virtualization Support' }
            VMMonitorModeExtensions                 = @{ value = $true; hint = 'Virtualization Support' }
        }

        # if Hypervisorpresent is all true, SecondLevelAddressTranslationExtensions, VirtualizationFirmwareEnabled, VMMonitorModeExtensions should not be tested
        $CheckHyperVisor = IsHypervisorPresent -PsSession $PsSession
        $hypervisorDtl = ($lhwTxt.HypervisorPresent -f (($CheckHyperVisor  | ForEach-Object {"{0}:{1}" -f $_.Name, $_.HypervisorPresent }) -join ','))
        if (($CheckHyperVisor | Select-Object -ExpandProperty HypervisorPresent) -notcontains $false)
        {
            Log-Info $hypervisorDtl
            Remove-Variable -Name criticalDesiredPropertyValue
        }
        else
        {
            Log-Info $hypervisorDtl -Type CRITICAL
        }
        Log-CimData -cimData $cimData -Properties $matchProperty,$warningDesiredPropertyValue,$criticalDesiredPropertyValue
        $instanceIdStr = 'Write-Output "Machine: $($instance.CimSystemProperties.ServerName), Class: $ClassName, Instance: $($instance.DeviceId)"'
        # Check property sync for nodes individually - using parallel processing for scale
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        $parallelResults = Invoke-ParallelPerNodeTest -SystemNames $SystemNames -CimData $cimData `
            -DesiredPropertyValue $warningDesiredPropertyValue `
            -CriticalDesiredPropertyValue $criticalDesiredPropertyValue `
            -MatchProperty $matchProperty -InstanceIdStr $instanceIdStr `
            -ValidatorName 'Hardware' -Severity Warning `
            -NodeLogMessage $lhwTxt.ProcessorCount
        $PropertyResult += $parallelResults
        # Check property sync for all nodes as well
        $PropertySyncResult += Test-PropertySync -CimData $cimData -MatchProperty $matchProperty -ValidatorName Hardware -Severity Warning

        # Return single aggregated result
        $allDetailResults = @($PropertyResult + $PropertySyncResult)
        return @(New-AggregatedTestResult -TestName 'Test-Processor' `
            -DisplayName 'Processor Properties' `
            -Description 'Checking Processor Properties (Cores, Speed, Manufacturer, Family, ThreadCount, etc.)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'Processor')
    }
    catch
    {
        throw $_
    }
}

function IsHypervisorPresent
{
    <#
    .SYNOPSIS
        Retrieves HypervisorPresent property from Win32_ComputerSystem
    #>
    [cmdletbinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_ComputerSystem'
                Property  = 'HypervisorPresent'
            }
            $cimData = @(Get-CimInstance @cimParams)
            return $cimData
        }
        $cimData = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }
        Log-CimData -cimData $cimData -Properties HypervisorPresent
        return $cimData
    }
    catch
    {
        throw $_
    }
}

function Test-NetAdapter
{
    <#
    .SYNOPSIS
        Test Network Adapter
    .DESCRIPTION
        Test Network Adapter
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity instead of individual property results.
        Use this at scale (>8 nodes) to reduce result count.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimData = @(Get-NetAdapter -Physical | Where-Object { $_.NdisMedium -eq 0 -and $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 14 -and $_.PnPDeviceID -notlike 'USB\*'})
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $cimTest = Test-CimData -Data $remoteOutput -ClassName NetAdapter -Severity CRITICAL -Detail $lhwTxt.NICSupportExplanation -DiagnosticCommand "Get-NetAdapter -Physical | Where-Object { `$_.NdisMedium -eq 0 -and `$_.Status -eq 'Up' -and `$_.NdisPhysicalMedium -eq 14 -and `$_.PnPDeviceID -notlike 'USB\*' }"
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData

        $PropertyResult = @()
        $PropertySyncResult = @()
        $GroupResult = @()
        $CountResult = @()

        # Blocking properties
        $criticalMatchProperty = @(
            'DriverDate'
            'DriverDescription'
            'DriverMajorNdisVersion'
            'DriverMinorNdisVersion'
            'DriverProvider'
            'DriverVersionString'
            'MajorDriverVersion'
            'MinorDriverVersion'
        )

        # non-block warning properties
        $warningMatchProperty = @(
            'ActiveMaximumTransmissionUnit'
            'ReceiveLinkSpeed'
            'Speed'
            'TransmitLinkSpeed'
            'VlanID'
            'MtuSize'
        )

        $desiredPropertyValue = @{
            AdminLocked                                      = $false
            ConnectorPresent                                 = $true
            EndpointInterface                                = $false
            ErrorDescription                                 = $null
            FullDuplex                                       = $true
            HardwareInterface                                = $true
            Hidden                                           = $false
            IMFilter                                         = $false
            InterfaceAdminStatus                             = @{ value = 1; hint = 'Up' } # Up
            InterfaceOperationalStatus                       = @{ value = 1; hint = 'Up' } # Up
            iSCSIInterface                                   = $false
            LastErrorCode                                    = $null
            MediaConnectState                                = @{ value = 1; hint = 'Connected' } # Connected
            MediaDuplexState                                 = 2
            NdisMedium                                       = @{ value = 0; hint = '802.3' } # 802.3
            NdisPhysicalMedium                               = @{ value = 14; hint = '802.3' } # 802.3
            OperationalStatusDownDefaultPortNotAuthenticated = $false
            OperationalStatusDownInterfacePaused             = $false
            OperationalStatusDownLowPowerState               = $false
            OperationalStatusDownMediaDisconnected           = $false
            #PromiscuousMode                                  = $false
            State                                            = @{ value = 2; hint = 'Started' } # 802.3  # Started
            #Status                                           = 'Up'
            Virtual                                          = $false
        }

        $groupProperty = @(
            'DriverDescription'
        )

        Log-CimData -cimData $cimData -Properties $desiredPropertyValue,$warningMatchProperty,$criticalMatchProperty

        $minimum = 1
        $instanceIdStr = 'Write-Output "Machine: $($instance.CimSystemProperties.ServerName), ClassName: $ClassName, Instance: $($instance.Name), Description: $($instance.InterfaceDescription), Address: $($instance.PermanentAddress)"'
        # Check property sync for nodes individually - using parallel processing for scale
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        $parallelResults = Invoke-ParallelPerNodeTest -SystemNames $SystemNames -CimData $cimData `
            -DesiredPropertyValue $desiredPropertyValue -InstanceIdStr $instanceIdStr `
            -ValidatorName 'Hardware' -Severity Critical -Minimum $minimum `
            -NodeLogMessage $lhwTxt.NicCount
        $PropertyResult += $parallelResults

        # Check property sync for all nodes as well
        $GroupResult += Test-GroupProperty -CimData $cimData -GroupProperty $groupProperty -MatchProperty $warningMatchProperty -ValidatorName Hardware -Severity Warning
        $GroupResult += Test-GroupProperty -CimData $cimData -GroupProperty $groupProperty -MatchProperty $criticalMatchProperty -ValidatorName Hardware -Severity Critical
        $InstanceCount += Test-InstanceCount -CimData $cimData -Severity Critical -ValidatorName 'Hardware'
        $InstanceCountByGroup += Test-InstanceCountByGroup -CimData $cimData -ValidatorName 'Hardware' -GroupProperty $groupProperty -Severity Critical

        # Return aggregated results per severity (excluding consistency/group results)
        $allDetailResults = @($PropertyResult + $InstanceCount + $InstanceCountByGroup)
        $GroupAggregated = @(New-AggregatedTestResult -TestName 'Test-NetAdapter-GroupConsistency' `
            -DisplayName 'Network Adapter Group Consistency' `
            -Description 'Checking Network Adapter group consistency across nodes (Driver, Speed, MTU, etc.)' `
            -DetailResults $GroupResult `
            -ValidatorName 'Hardware' `
            -ResourceType 'NetAdapter')
        return @(New-AggregatedTestResult -TestName 'Test-NetAdapter' `
            -DisplayName 'Network Adapter' `
            -Description 'Checking Network Adapter Properties (Status, Duplex, Speed, Driver, etc.)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'NetAdapter') + $GroupAggregated
    }
    catch
    {
        throw $_
    }
}

function Test-MemoryCapacity
{
    <#
    .SYNOPSIS
        Test Memory
    .DESCRIPTION
        Test Memory
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        if ((Get-WmiObject -Class Win32_ComputerSystem).Model -eq "Virtual Machine")
        {
            $environmentType = "Virtual"
            $minimumMemory = 24GB
        } else {
            $environmentType = "Physical"
            $minimumMemory = 32GB
        }
        Log-Info -Message ($lhwTxt.MemoryCapacityRequirement -f $minimumMemory, $environmentType)
        $instanceResults = @()

        $sb = {
            $cimParams = @{
                ClassName = 'Win32_PhysicalMemory'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $cimTest = Test-CimData -Data $remoteOutput -ClassName PhysicalMemory -Severity WARNING -DiagnosticCommand 'Get-CimInstance -ClassName Win32_PhysicalMemory -Property *'
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData
        Log-CimData -cimData $cimData -Properties Capacity

        # Check property sync for nodes individually
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        $totalMemoryLocalNode = $cimData | Where-Object { $_.CimSystemProperties.ServerName -like "$($ENV:COMPUTERNAME)*"} | Measure-Object -Property Capacity -Sum | Select-Object -ExpandProperty Sum
        $instanceResults += foreach ($systemName in $SystemNames)
        {
            $sData = $CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
            $instanceId = "Machine: $systemName, Class: PhysicalMemory, Instance: All"
            $totalMemory = $sData | Measure-Object -Property Capacity -Sum
            $dtl = $lhwTxt.MemoryCapacity -f $systemName, $totalMemory.Sum, $minimumMemory, $totalMemoryLocalNode
            if ($totalMemory.Sum -lt $minimumMemory -or $totalMemory.Sum -lt $totalMemoryLocalNode)
            {
                $Status = 'FAILURE'
                Log-Info $dtl -Type Warning
            }
            else
            {
                $Status = 'SUCCESS'
                Log-Info $dtl
            }

            $params = @{
                Name               = 'AzStackHci_Hardware_Test_MemoryCapacity'
                Title              = 'Test Memory Capacity'
                DisplayName        = "Test Memory Capacity $systemName"
                Severity           = 'WARNING'
                Description        = 'Checking Memory Capacity'
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'Memory'
                Timestamp          = [datetime]::UtcNow
                Status             =  $status
                AdditionalData     = @{
                    Source    = 'Memory Capacity'
                    Resource  = $totalMemory.Sum
                    Detail    = $dtl
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }

        $minimumMemoryGB = [math]::Round($minimumMemory / 1GB)
        return @(New-AggregatedTestResult -TestName 'Test-MemoryCapacity' `
            -DisplayName 'Memory Capacity' `
            -Description "Checking Memory Capacity (minimum ${minimumMemoryGB} GB per node, ${environmentType})" `
            -DetailResults $instanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'Memory')
    }
    catch
    {
        throw $_
    }
}

function Test-MemoryProperties
{
    <#
    .SYNOPSIS
        Test Memory
    .DESCRIPTION
        Test Memory
    .PARAMETER SummaryOnly
        When specified, returns only per-node summary results instead of individual DIMM/property results.
        Use this at scale (>8 nodes) to reduce result count.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_PhysicalMemory'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
            # Compute ECC at source before serialization - NoteProperty survives all boundaries
            foreach ($item in $cimData) {
                $item | Add-Member -MemberType NoteProperty -Name ECC -Value ($item.TotalWidth -gt $item.DataWidth) -Force
            }
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $cimTest = Test-CimData -Data $remoteOutput -ClassName PhysicalMemory -Severity WARNING -DiagnosticCommand 'Get-CimInstance -ClassName Win32_PhysicalMemory -Property *'
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData

        $PropertyResult = @()
        $PropertySyncResult = @()
        $matchProperty = @(
            'ConfiguredClockSpeed'
            'ConfiguredVoltage'
            'MaxVoltage'
            'MemoryType'
            'SMBIOSMemoryType'
            'Speed'
            'TotalWidth'
            'TypeDetail'
        )

        $warningdesiredPropertyValue = @{
            DataWidth  = @{ value = 64; hint = '64-bit' } # x64
            FormFactor = @{ value = 8; hint = 'DIMM' } # DIMM
        }

        $criticaldesiredPropertyValue = @{
            ECC  = $true # Error Correction Code (ECC) memory
        }
        Log-CimData -cimData $cimData -Properties $warningdesiredPropertyValue,$criticaldesiredPropertyValue,$matchProperty
        # Check property sync for nodes individually - using parallel processing for scale
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        $instanceIdStr = 'Write-Output "Machine: $($Instance.CimSystemProperties.ServerName), Class: $ClassName, Instance: $($instance.DeviceLocator), Tag: $($instance.Tag)"'
        $parallelResults = Invoke-ParallelPerNodeTest -SystemNames $SystemNames -CimData $cimData `
            -DesiredPropertyValue $warningdesiredPropertyValue `
            -CriticalDesiredPropertyValue $criticaldesiredPropertyValue `
            -MatchProperty $matchProperty -InstanceIdStr $instanceIdStr `
            -ValidatorName 'Hardware' -Severity Warning
        $PropertyResult += $parallelResults
        # Check property sync for all nodes as well
        $PropertySyncResult += Test-PropertySync -CimData $cimData -MatchProperty $matchProperty -ValidatorName Hardware -Severity Warning

        # Generate summary results per node
        # Return single aggregated result
        $allDetailResults = @($PropertyResult + $PropertySyncResult)
        return @(New-AggregatedTestResult -TestName 'Test-MemoryProperties' `
            -DisplayName 'Memory Properties' `
            -Description 'Checking Memory Properties (ECC, Capacity, Speed, Manufacturer, MemoryType, etc.)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'Memory')
    }
    catch
    {
        throw $_
    }
}

function Test-Gpu
{
    <#
    .SYNOPSIS
        Test Gpu
    .DESCRIPTION
        Test Gpu (VideoController)
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_VideoController'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $cimTest = Test-CimData -Data $remoteOutput -ClassName VideoController -Severity WARNING -DiagnosticCommand 'Get-CimInstance -ClassName Win32_VideoController -Property *'
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData

        $PropertyResult = @()
        $GroupResult = @()
        $InstanceCount = @()
        $InstanceCountByGroup = @()

        $matchProperty = @(
            'AdapterRam'
            'Name'
            'DriverDate'
            'DriverVersion'
            'VideoMemoryType'
            'VideoProcessor'
        )

        $desiredPropertyValue = @{
            ConfigManagerErrorCode = @{ value = 0; hint = 'The device is working properly' } # The device is working properly
            Status                 = 'OK'
        }

        $groupProperty = @(
            'Name'
        )

        Log-CimData -cimData $cimData -Properties $desiredPropertyValue,$matchProperty
        # Check property sync for nodes individually
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        foreach ($systemName in $SystemNames)
        {
            $sData = $CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
            $totalGpuRam = $sData | Measure-Object -Property AdapterRam -Sum
            Log-Info -Message ($lhwTxt.TotalGPUMem -f $systemName, $sData.Count, ($totalGpuRam.Sum / 1GB))
            $instanceIdStr = 'Write-Output "Machine: $($instance.CimSystemProperties.ServerName), Class: $ClassName, Instance: $($instance.DeviceID), Name: $($instance.Name)"'
            $PropertyResult += Test-DesiredProperty -CimData $sData -desiredPropertyValue $desiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName Hardware -Severity Warning
        }
        # Check property sync for all nodes as well
        $GroupResult += Test-GroupProperty -CimData $cimData -GroupProperty $groupProperty -MatchProperty $MatchProperty -ValidatorName Hardware -Severity Warning
        $InstanceCount += Test-InstanceCount -CimData $cimData -Severity Warning -ValidatorName 'Hardware'
        $InstanceCountByGroup += Test-InstanceCountByGroup -CimData $cimData -ValidatorName 'Hardware' -GroupProperty $groupProperty -Severity Warning

        # Return aggregated results per severity (excluding consistency/group results)
        $allDetailResults = @($PropertyResult + $InstanceCount)
        $GroupAggregated = @(New-AggregatedTestResult -TestName 'Test-Gpu-GroupConsistency' `
            -DisplayName 'Video Controller Group Consistency' `
            -Description 'Checking Video Controller group consistency across nodes (Driver, AdapterRam, etc.)' `
            -DetailResults $GroupResult `
            -ValidatorName 'Hardware' `
            -ResourceType 'VideoController')
        $CountAggregated = @(New-AggregatedTestResult -TestName 'Test-Gpu-InstanceCountByGroup' `
            -DisplayName 'Video Controller Instance Count By Group' `
            -Description 'Checking Video Controller instance count consistency by group across nodes' `
            -DetailResults $InstanceCountByGroup `
            -ValidatorName 'Hardware' `
            -ResourceType 'VideoController')
        return @(New-AggregatedTestResult -TestName 'Test-Gpu' `
            -DisplayName 'Video Controller' `
            -Description 'Checking Video Controller Properties (ConfigManagerErrorCode, Status)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'VideoController') + $GroupAggregated + $CountAggregated
    }
    catch
    {
        throw $_
    }
}

function Test-Baseboard
{
    <#
    .SYNOPSIS
        Test Baseboard
    .DESCRIPTION
        Test Baseboard (BIOS)
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_Bios'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
             return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $cimTest = Test-CimData -Data $remoteOutput -ClassName Bios -Severity WARNING -DiagnosticCommand 'Get-CimInstance -ClassName Win32_Bios -Property *'
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData

        $PropertyResult = @()
        $PropertySyncResult = @()
        $matchProperty = @(
            #'BiosVersion' # this property is a string array and non-trivial to compare
            'Caption'
            'Description'
            'EmbeddedControllerMajorVersion'
            'EmbeddedControllerMinorVersion'
            'Manufacturer'
            'Name'
            'ReleaseDate'
            'SMBIOSBIOSVersion'
            'SMBIOSMajorVersion'
            'SMBIOSMinorVersion'
            'SoftwareElementId'
            'SystemBiosMajorVersion'
            'SystemBiosMinorVersion'
            'Version'
        )

        $desiredPropertyValue = @{
            SMBIOSPresent        = $true
            SoftwareElementState = @{ value = 3; hint = 'Running' } # Running
            Status               = 'OK'
        }

        Log-CimData -cimData $cimData -Properties $desiredPropertyValue,$matchProperty

        # Check property sync for nodes individually
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        foreach ($systemName in $SystemNames)
        {
            $sData = $CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
            Log-Info -Message ($lhwTxt.TestBaseboard -f $systemName, $sData.Name, $sData.SerialNumber)
            $instanceIdStr = 'Write-Output "Machine: $($instance.CimSystemProperties.ServerName), Class: $ClassName, Serial: $($instance.SerialNumber)"'
            $PropertyResult += Test-DesiredProperty -CimData $sData -desiredPropertyValue $desiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName Hardware -Severity Warning
            $PropertySyncResult += Test-PropertySync -CimData $sData -MatchProperty $matchProperty -ValidatorName Hardware -Severity Warning
        }
        # Check property sync for all nodes as well
        $PropertySyncResult += Test-PropertySync -CimData $cimData -MatchProperty $matchProperty -ValidatorName Hardware  -Severity Warning

        # Return aggregated results per severity
        $allDetailResults = @($PropertyResult + $PropertySyncResult)
        return @(New-AggregatedTestResult -TestName 'Test-Baseboard' `
            -DisplayName 'BIOS' `
            -Description 'Checking BIOS Properties (SMBIOSPresent, SoftwareElementState, Status, Version consistency, etc.)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'BIOS')
    }
    catch
    {
        throw $_
    }
}

function Test-Model
{
    <#
    .SYNOPSIS
        Test Hardware Model is the same
    .DESCRIPTION
        Test Hardware Model is the same (Win32_ComputerSystem)
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_ComputerSystem'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $cimTest = Test-CimData -Data $remoteOutput -ClassName ComputerSystem -Severity CRITICAL -DiagnosticCommand 'Get-CimInstance -ClassName Win32_ComputerSystem -Property *'
        if ($cimTest | Where-Object { $_.Status -eq 'FAILURE' }) { return $cimTest }
        $cimData = $remoteOutput.cimData

        $PropertySyncResult = @()
        $matchProperty = @(
            'Manufacturer'
            'Model'
        )
        Log-CimData -cimData $cimData -Properties $matchProperty

        # Check property sync for nodes individually
        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        foreach ($systemName in $SystemNames)
        {
            $sData = $CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
            Log-Info -Message ($lhwTxt.TestModel -f $systemName, $sData.Manufacturer, $sData.Model)
            $PropertySyncResult += Test-PropertySync -CimData $sData -MatchProperty $matchProperty -ValidatorName Hardware -Severity Critical
        }
        # Check property sync for all nodes as well
        $PropertySyncResult += Test-PropertySync -CimData $cimData -MatchProperty $matchProperty -ValidatorName Hardware  -Severity Critical

        # Return aggregated results per severity
        $allDetailResults = @($PropertySyncResult)
        return @(New-AggregatedTestResult -TestName 'Test-Model' `
            -DisplayName 'Computer System' `
            -Description 'Checking Computer System Properties (Manufacturer, Model consistency)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'ComputerSystem')
    }
    catch
    {
        throw $_
    }
}

function Test-PhysicalDisk
{
    <#
    .SYNOPSIS
        Test Physical Disk
    .DESCRIPTION
        Test Physical Disk
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity instead of individual property results.
        Use this at scale (>8 nodes) to reduce result count.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [string]
        $HardwareClass = 'Medium',

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $fabricOp = $args[0]
            $eceNodeName = $args[1]
            $allowedBusTypes = @('SATA', 'SAS', 'NVMe', 'SCM')
            $allowedMediaTypes = @('HDD', 'SSD', 'SCM')
            $bootPhysicalDisk = Get-Disk | Where-Object {$_.IsBoot -or $_.IsSystem} | Get-PhysicalDisk
            if ($fabricOp -match 'AddNode|Repair')
            {
                if ($eceNodeName -eq $env:COMPUTERNAME)
                {
                    # In AddNode we need a seperate check command to return disks that are spaces disks
                    # to build a reference list for the new node
                    $cimData = @(Get-StorageNode -Name $env:COMPUTERNAME* | `
                        Get-PhysicalDisk -PhysicallyConnected | `
                        Where-Object { `
                            $_.BusType -in $allowedBusTypes -and `
                            $_.CanPool -eq $false -and `
                            $_.CannotPoolReason -eq 'In a Pool'
                        }
                    )
                }
                else
                {
                    if($fabricOp -like "*AddNode*")
                    {
                        # For AddNode node we expect CanPool true and to match ECE node above
                        $cimData = @(Get-StorageNode -Name $env:COMPUTERNAME* | `
                        Get-PhysicalDisk -PhysicallyConnected | `
                            Where-Object { `
                                $_.BusType -in $allowedBusTypes -and `
                                $_.MediaType -in $allowedMediaTypes -and `
                                $_.DeviceId -notin $bootPhysicalDisk.DeviceId -and `
                                $_.CanPool -eq $true
                            }
                        )
                    }
                    elseif ($fabricOp -like "*Repair*")
                    {
                        # For Repair we ignore CanPool and to match ECE node above
                        $cimData = @(Get-StorageNode -Name $env:COMPUTERNAME* | `
                        Get-PhysicalDisk -PhysicallyConnected | `
                            Where-Object { `
                                $_.BusType -in $allowedBusTypes -and `
                                $_.MediaType -in $allowedMediaTypes -and `
                                $_.DeviceId -notin $bootPhysicalDisk.DeviceId
                            }
                        )
                    }
                    else
                    {
                        throw "Invalid Fabric Operation: $fabricOp"
                    }
                }
            }
            else
            {
                if ($fabricOp -like '*KeepStorage*')
                {
                    $cimData = @(Get-StorageNode -Name $env:COMPUTERNAME* | `
                        Get-PhysicalDisk -PhysicallyConnected | `
                        Where-Object { `
                            $_.BusType -in $allowedBusTypes -and `
                            $_.MediaType -in $allowedMediaTypes -and `
                            $_.DeviceId -notin $bootPhysicalDisk.DeviceId
                        }
                    )
                }
                else
                {
                    $cimData = @(Get-StorageNode -Name $env:COMPUTERNAME* | `
                                Get-PhysicalDisk -PhysicallyConnected | `
                                Where-Object { `
                                    $_.BusType -in $allowedBusTypes -and `
                                    $_.MediaType -in $allowedMediaTypes -and `
                                    $_.DeviceId -notin $bootPhysicalDisk.DeviceId -and `
                                    $_.CanPool -eq $true
                                }
                            )
                }
            }
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                cimData = $cimData
            })
        }
        $remoteOutput = if ($PsSession)
        {
            # When we are using PsSessions (every ECE fabric operation)
            # Inject our FabricOperation and local computer into the remote session,
            # so canPool expectation can be set for deployment and ScaleOut.
            Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList $ENV:EnvChkrId, $ENV:ComputerName
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        # switch statement against $ENV:EnvChkrId to set support expectiation
        switch -Wildcard ($ENV:EnvChkrId)
        {
            '*AddNode*' { $notSupportedHelp = $lhwTxt.GreenfieldNotSupportedExplanation }
            '*Repair*' { $notSupportedHelp = $lhwTxt.RepairNotSupportedExplanation }
            '*KeepStorage*' { $lhwTxt.RepairNotSupportedExplanation}
            default { $notSupportedHelp = $lhwTxt.GreenfieldNotSupportedExplanation }
        }

        # Proactively get supported disk information
        # This is used to improve the feedback for any failed results later.
        $supportedDiskDetail = Get-PhysicalDiskSupport -PsSession $PsSession
        Get-PhysicalDiskSupportSummary -PhysicalDiskSupportData $supportedDiskDetail | Out-Null

        # Check if all nodes returned valid data disks.
        $cimTest = Test-CimData -Data $remoteOutput -ClassName PhysicalDisk -Severity CRITICAL -Detail $notSupportedHelp
        # If there are any failures, determine why they are not supported and update the guidance in the result
        [array] $cimFailures = $cimTest | Where-Object { $_.Status -eq 'FAILURE' }
        if ($cimFailures.count -gt 0)
        {
            # Improve the feedback for each cimTest failure
            foreach ($cimFail in $cimFailures)
            {
                # Get the matching node data
                $nodeSupportData = $supportedDiskDetail | Where-Object { $cimFail.TargetResourceID -like "*$($_.ComputerName)*" }
                # Get a succinct summary of the support data
                [string]$nodeSupportSummary = Get-PhysicalDiskSupportSummary -PhysicalDiskSupportData $nodeSupportData
                $cimFail.AdditionalData.Detail = $nodeSupportSummary
                $cimFail.Remediation = "See AdditionalData / Detail for more information. Or run Get-PhysicalDiskSupport -PsSession <node>"
            }
            # Return the cimTest in this case, there's no point in continuing.
            # Aggregate the CIM failures into a single result — use the localized explanation
            # as description, not the full diagnostic dump (that stays in AdditionalData.Detail)
            return @(New-AggregatedTestResult -TestName 'Test-PhysicalDisk' `
                -DisplayName 'Physical Disk' `
                -Description "$notSupportedHelp See AdditionalData.Detail for full diagnostics or run: Get-PhysicalDiskSupport -PsSession <node>" `
                -DetailResults $cimTest `
                -ValidatorName 'Hardware' `
                -ResourceType 'PhysicalDisk')
        }

        # If we get here, we have valid disks to work with.
        $cimData = $remoteOutput.cimData

        $PropertyResult = @()
        $GroupResult = @()
        $CountResult = @()
        $InstanceCount = @()
        $InstanceCountByGroup = @()

        $matchProperty = @(
            'FirmwareVersion'
        )

        $groupProperty = @(
            'FriendlyName'
        )

        $warningDesiredPropertyValue = @{
            HealthStatus        = @{ value = @('Healthy', 0); hint = 'Healthy' } # Healthy
            IsIndicationEnabled = @{ value = @($false, $null); hint = 'Indicator Off' }
            OperationalStatus   = @{ value = @('OK', 2); hint = 'OK' }
        }

        Log-Info -Message "Logging supported data disks and their properties prior to checking compliance."
        Log-CimData -cimData $cimData -Properties $groupProperty,$warningDesiredPropertyValue,$matchProperty, CanPool, CannotPoolReason, Size, PhysicalLocation, UniqueId, SerialNumber

        $instanceIdStr = 'Write-Output "Machine: $($instance.CimSystemProperties.ServerName), Class: $ClassName, Location: $($instance.PhysicalLocation), Unique ID: $($instance.UniqueId), Size: $("{0:N2}" -f ($instance.Size / 1TB)) TB"'
        # Check disk count for nodes individually
        [array]$SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        foreach ($systemName in $SystemNames)
        {
            $sData = $CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
            $totalSize = $sData | Measure-Object -Property Size -Sum
            Log-Info -Message ($lhwTxt.DiskTotal -f $systemName, $($sData.Count), ('{0:N2}' -f ($totalSize.Sum / 1TB)))
            $PropertyResult += Test-DesiredProperty -CimData $sData -desiredPropertyValue $warningDesiredPropertyValue -InstanceIdStr $InstanceIdStr -ValidatorName Hardware -Severity Warning

            # Split disks into type
            $SSD = $sData | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'SAS|10|SATA|11'}
            $NVMe = $sData | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'NVMe|17'}
            $SCM = $sData | Where-Object {$_.MediaType -match 'SCM|5'}
            $HDD = $sData | Where-Object {$_.MediaType -match 'HDD|3'}
            Log-Info ("Drive types detected HDD: {0}, SSD:{1}, NVMe:{2}, SCM:{3}" -f [bool]$HDD, [bool]$SSD, [bool]$NVMe, [bool]$SCM)

            $systemCountResult = @()
            $countCommonParams = @{
                ValidatorName = 'Hardware'
                Severity = 'CRITICAL'
            }

            # split into medium/large vs small
            # medium and large are subject to storage spaces direct requirements
            # small is subject to the minimum number of disks being 1.
            # consistency across bustype, mediatype, and size and other property is still checked in the property sync for both form factors.
            if ($HardwareClass -eq 'Medium' -or $HardwareClass -eq 'Large')
            {
                # As per https://docs.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-direct-hardware-requirements

                # all flash minimum should be 2
                # Drive type present (capacity only)	Minimum drives required (Windows Server)	Minimum drives required (Azure Stack HCI)
                # All persistent memory (same model)	4 persistent memory	                        2 persistent memory
                # All NVMe (same model)	                4 NVMe                                      2 NVMe
                # All SSD (same model)	                4 SSD                                       2 SSD
                if ($SSD -xor $NVMe -xor $SCM)
                {
                    $systemCountResult += Test-Count -cimData $sData -Minimum 2 @countCommonParams
                }

                # Drive type present                Minimum drives required
                # Persistent memory + NVMe or SSD   2 persistent memory + 4 NVMe or SSD
                # NVMe + SSD                        2 NVMe + 4 SSD
                # NVMe + HDD                        2 NVMe + 4 HDD
                # SSD + HDD                         2 SSD + 4 HDD

                if ($SCM -and ($NVMe -or $SSD)) {
                    $systemCountResult += Test-Count -cimData $SCM -Minimum 2 @countCommonParams
                    if ($NVMe) {
                        Log-Info ($lhwTxt.MinCountDiskType -f 'NVMe', '4', $systemName )
                        $systemCountResult += Test-Count -cimData $NVMe -Minimum 4 @countCommonParams
                    }
                    else {
                        Log-Info ($lhwTxt.MinCountDiskType -f 'SSD', '4', $systemName )
                        $systemCountResult += Test-Count -cimData $SSD -Minimum 4 @countCommonParams
                    }
                }

                if ($NVMe -and $SSD) {
                    Log-Info ($lhwTxt.MinCountDiskType -f 'NVMe', '2', $systemName )
                    $systemCountResult += Test-Count -cimData $NVMe -Minimum 2 @countCommonParams
                    Log-Info ($lhwTxt.MinCountDiskType -f 'SSD', '4', $systemName )
                    $systemCountResult += Test-Count -cimData $SSD -Minimum 4 @countCommonParams
                }

                if ($NVMe -and $HHD) {
                    Log-Info ($lhwTxt.MinCountDiskType -f 'NVMe', '2', $systemName )
                    $systemCountResult += Test-Count -cimData $NVMe -Minimum 2 @countCommonParams
                    Log-Info ($lhwTxt.MinCountDiskType -f 'HDD', '4', $systemName )
                    $systemCountResult += Test-Count -cimData $HDD -Minimum 4 @countCommonParams
                }

                if ($SSD -and $HHD) {
                    Log-Info ($lhwTxt.MinCountDiskType -f 'SSD', '2', $systemName )
                    $systemCountResult += Test-Count -cimData $SSD -Minimum 2 @countCommonParams
                    Log-Info ($lhwTxt.MinCountDiskType -f 'HDD', '4', $systemName )
                    $systemCountResult += Test-Count -cimData $HDD -Minimum 4 @countCommonParams
                }

                if ($systemCountResult.count -eq 0) {
                    Log-Info "We did not determine the disk combination correctly for $systemName. Checking minimum as per deployment guide." -Type Warning
                    $systemCountResult += Test-Count -cimData $sData -Minimum 3 @countCommonParams
                }
            }
            elseif ($HardwareClass -eq 'Small')
            {
                # here we effectively forego the storage spaces direct requirements and just check for the minimum number of 2 disks
                $systemCountResult += Test-Count -cimData $sData -Minimum 1 @countCommonParams
            }
            else
            {
                throw "Invalid HardwareClass: $HardwareClass"
            }
            $CountResult += $systemCountResult
        }
        # Check property sync for all nodes
        $GroupResult += Test-GroupProperty -CimData $cimData -GroupProperty $groupProperty -MatchProperty $matchProperty -ValidatorName Hardware -Severity Warning

        #region Disk Instance Count
        # Split disks into type and check each server has the same count
        # Then check all servers have the same count regardless of type
        # This should return a single succtint result summarizing the instance.
        $allSSD = $cimData | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'SAS|10|SATA|11'}
        $allNVMe = $cimData | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'NVMe|17'}
        $allSCM = $cimData | Where-Object {$_.MediaType -match 'SCM|5'}
        $allHDD = $cimData | Where-Object {$_.MediaType -match 'HDD|3'}
        $typeInstanceCount = @()
        $instParams = @{
            ValidatorName = 'Hardware'
            Severity = 'CRITICAL'
        }
        if ($allSSD) {
            Log-Info ($lhwTxt.DiskInstanceCountByType -f 'SSD')
            $typeInstanceCount += Test-InstanceCount -CimData $allSSD @instParams -NamePostfix "SSD"
        }
        if ($allNVMe) {
            Log-Info ($lhwTxt.DiskInstanceCountByType -f 'NVMe')
            $typeInstanceCount += Test-InstanceCount -CimData $allNVMe @instParams -NamePostfix "NVMe"
        }
        if ($allSCM) {
            Log-Info ($lhwTxt.DiskInstanceCountByType -f 'SCM')
            $typeInstanceCount += Test-InstanceCount -CimData $allSCM @instParams -NamePostfix "SCM"
        }
        if ($allHDD) {
            Log-Info ($lhwTxt.DiskInstanceCountByType -f 'HDD')
            $typeInstanceCount += Test-InstanceCount -CimData $allHDD @instParams -NamePostfix "HDD"
        }

        # Join all instance count by type details for an uber summary
        $typeInstanceCountDetail = ""
        $typeInstanceCountDetail = $typeInstanceCount | Foreach-Object {
            "`r`n[{0}] {1}`r`n" -f $_.Status, $_.AdditionalData.Detail
        }

        # Do all servers have the same count regardless of type
        $InstanceCount += Test-InstanceCount -CimData $cimData -Severity Critical -ValidatorName 'Hardware'
        # Override the instance count result with the worst of the type instance count e.g. If SSD is 1 less and NVMe is 1 more,
        # The overall count test should be in failure, even if the failures balance each other.
        # The user will get that feedback later in the detail.
        if ('FAILURE' -in $typeInstanceCount.Status)
        {
            $InstanceCount[-1].Status = 'FAILURE'
        }

        # Enhance the detail to add the instance count for each type to the result, and indicate the status of each one.
        $InstanceCountEnhancedDetail = ""
        $InstanceCountEnhancedDetail += "[$($InstanceCount[-1].Status)] "
        $InstanceCountEnhancedDetail += $InstanceCount[-1].AdditionalData.Detail
        $InstanceCountEnhancedDetail += "`r`n"
        $InstanceCountEnhancedDetail += $typeInstanceCountDetail
        $InstanceCount[-1].AdditionalData.Detail = $InstanceCountEnhancedDetail

        # if instancecount has a failure, we need to run Get-PhysicalDiskSupport and append detail to the result
        # Get-PhysicalDiskSupport will return a list of disks that are not supported and the reason why
        # If there are too many disks to display, it will tell the uer run to run the command manually or check the verbose log.
        if ($InstanceCount[-1].Status -eq 'FAILURE')
        {
            $supportedDetail = Get-PhysicalDiskSupportSummary -PhysicalDiskSupportData $supportedDiskDetail
            $InstanceCount[-1].AdditionalData.Detail = $InstanceCount[-1].AdditionalData.Detail + $supportedDetail
        }
        #endregion


        Log-Info ($lhwTxt.DiskInstanceCountByType -f 'ALL')
        # Finally, the all properties from the $matchProperty array (Firmware) have to be compared for all instances
        # across all nodes grouped by property (FriendlyName)
        $InstanceCountByGroup += Test-InstanceCountByGroup -CimData $cimData -ValidatorName 'Hardware' -GroupProperty $groupProperty -Severity Warning

        if (($null -eq $PsSession -or $PsSession.Count -eq 1) -and $null -eq $CheckDisksAreAllFlash)
        {
            # Single Node deployments should be all flash
            [array]$CheckDisksAreAllFlash = CheckDisksAreAllFlash -CimData $cimData
        }

        # Return aggregated results per severity (excluding consistency/group results)
        # AllFlash is excluded from aggregation — it's a standalone single-node result with its own CI override
        $allDetailResults = @($PropertyResult + $CountResult + $InstanceCount)
        $GroupAggregated = @(New-AggregatedTestResult -TestName 'Test-PhysicalDisk-GroupConsistency' `
            -DisplayName 'Physical Disk Group Consistency' `
            -Description 'Checking Physical Disk group consistency across nodes (Firmware, Model, etc.)' `
            -DetailResults $GroupResult `
            -ValidatorName 'Hardware' `
            -ResourceType 'PhysicalDisk')
        $CountAggregated = @(New-AggregatedTestResult -TestName 'Test-PhysicalDisk-InstanceCountByGroup' `
            -DisplayName 'Physical Disk Instance Count By Group' `
            -Description 'Checking Physical Disk instance count consistency by group across nodes' `
            -DetailResults $InstanceCountByGroup `
            -ValidatorName 'Hardware' `
            -ResourceType 'PhysicalDisk')
        return @(New-AggregatedTestResult -TestName 'Test-PhysicalDisk' `
            -DisplayName 'Physical Disk' `
            -Description 'Checking Physical Disk Properties (HealthStatus, OperationalStatus, CanPool, etc.)' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'PhysicalDisk') + $CheckDisksAreAllFlash + $GroupAggregated + $CountAggregated
    }
    catch
    {
        throw $_
    }
}

function Test-TpmVersion
{
    <#
    .SYNOPSIS
        Test TPM Version
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter()]
        $version = '2.0',

        [switch]
        $SummaryOnly
    )

    $tpms = @()
    $InstanceResults = @()
    $sb = {
            $tpm = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
            $result = New-Object -TypeName PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                TpmData = $tpm
            }
        return $result
    }
    $tpms += if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sb
    }
    else
    {
        Invoke-Command -ScriptBlock $sb
    }

    Log-CimData -CimData $tpms.TpmData

    foreach ($tpm in $tpms)
    {
        $computerName = $tpm.ComputerName
        # Test properties
        $InstanceResults += foreach ($instance in $tpm.TpmData)
        {
            $instanceId = "Machine: $computerName, Class: Tpm, Manufacturer ID: $($instance.ManufacturerId)"
            $instanceVersion = $instance.SpecVersion -split ',' | Select-Object -First 1
            $status = if ($instanceVersion -eq $version) { 'SUCCESS' } else { 'FAILURE' }
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_Tpm_Version'
                Title              = 'Test TPM Version'
                DisplayName        = "Test TPM Version $computerName"
                Severity           = 'CRITICAL'
                Description        = "Checking TPM for desired version ($version)"
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'Tpm'
                Timestamp          = [datetime]::UtcNow
                Status             =  $status
                AdditionalData     = @{
                    Source    = 'Version'
                    Resource  = $instanceVersion
                    Detail    = "$instanceId Tpm version is $instanceVersion. Expected $version"
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResult = New-AzStackHciResultObject @params

            if ($InstanceResult.AdditionalData.Status -eq 'SUCCESS')
            {
                Log-Info -Message $InstanceResult.AdditionalData.Detail
            }
            else
            {
                Log-Info -Message $InstanceResult.AdditionalData.Detail -Type Warning
            }
            $instanceResult
        }
    }

    return @(New-AggregatedTestResult -TestName 'Test-TpmVersion' `
        -DisplayName 'TPM Version' `
        -Description "Checking TPM for desired version ($version)" `
        -DetailResults $InstanceResults `
        -ValidatorName 'Hardware' `
        -ResourceType 'TPM')
}

function Test-TpmProperties
{
    <#
    .SYNOPSIS
        Test TPM properties
    .DESCRIPTION
        Test TPM properties
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $tpms = @()
        $InstanceResults = @()
        $sb = {
            $tpm = Get-Tpm
            New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                tpm = $tpm
            }
        }
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $tpms += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $tpms += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        foreach ($tpm in $tpms)
        {
            $passed = $false
            $computerName = $tpm.ComputerName
            $nodeResults = @()  # Collect results for this node
            $desiredPropertyValue = @{
                TpmPresent         = $true #(Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm) is null
                TpmReady           = $true #IsActivated()
                TpmEnabled         = $true #IsEnabled()
                TpmActivated       = $true #IsActivated()
                #TpmOwned           = $true #IsOwned()
                #RestartPending     = $false #GetPhysicalPresenceRequest()?
                ManagedAuthLevel   = 'Full' #GetOwnerAuth()??
                OwnerClearDisabled = $false #IsOwnerClearDisabled()
                AutoProvisioning   = 'Enabled' #IsAutoProvisioningEnabled()
                LockedOut          = $false #IsLockedOut()
                LockoutCount       = 0 #GetCapLockoutInfo()
            }
            Log-CimData -cimData $tpm -Properties $desiredPropertyValue
            Log-Info -Message ($lhwTxt.TestTpm -f $computerName, $tpm.tpm.ManufacturerIdTxt, $tpm.tpm.ManufacturerVersion)

            # Test properties - collect results for this node
            $nodeResults = foreach ($instance in $tpm.tpm)
            {
                $instanceId = "Machine: $computerName, Class: Tpm, Manufacturer ID: $($tpm.tpm.ManufacturerId)"
                # if TPMEnabled is false, skip the rest of the properties
                if (-not $instance.TpmEnabled)
                {
                    $dtl = $lhw.TpmNotEnabled -f $computerName
                    $params = @{
                        Name               = "AzStackHci_Security_Test_Tpm_TpmEnabled_Property"
                        Title              = "Test TPM Property TpmEnabled is true"
                        DisplayName        = "Test TPM Property TpmEnabled is true on $computerName"
                        Severity           = 'CRITICAL'
                        Description        = "Checking TPM is enabled"
                        Tags               = @{}
                        Remediation        = Get-DeviceRequirementsUrl
                        TargetResourceID   = $instanceId
                        TargetResourceName = $instanceId
                        TargetResourceType = 'Tpm'
                        Timestamp          = [datetime]::UtcNow
                        Status             = 'FAILURE'
                        AdditionalData     = @{
                            Source    = 'Enabled'
                            Resource  = $instance.TpmEnabled
                            Detail    = $dtl
                            Status    = 'FAILURE'
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    New-AzStackHciResultObject @params
                    Log-Info "$dtl Skipping all other TPM property checks." -Type CRITICAL
                    continue
                }
                foreach ($propertyName in $desiredPropertyValue.Keys)
                {
                    $detail = $null
                    $passed = $false
                    if ($instance.$propertyName -ne $desiredPropertyValue.$propertyName)
                    {
                        $passed = $false
                        $detail = $lhwTxt.UnexProp -f $propertyName, $instance.$propertyName, $desiredPropertyValue.$propertyName
                        Log-Info -Message $detail -Type Warning
                    }
                    else
                    {
                        $detail = $lhwTxt.Prop -f $propertyName, $instance.$propertyName, $desiredPropertyValue.$propertyName
                        $passed = $true
                    }
                    $status = if ($passed) { 'SUCCESS' } else { 'FAILURE' }
                    $params = @{
                        Name               = "AzStackHci_Hardware_Test_Tpm_$($propertyName)_Property"
                        Title              = "Test TPM Property $propertyName is $($desiredPropertyValue.$propertyName)"
                        DisplayName        = "Test TPM Property $propertyName is $($desiredPropertyValue.$propertyName) $computerName"
                        Severity           = 'CRITICAL'
                        Description        = "Checking TPM for desired properties"
                        Tags               = @{}
                        Remediation        = Get-DeviceRequirementsUrl
                        TargetResourceID   = $instanceId
                        TargetResourceName = $instanceId
                        TargetResourceType = 'Tpm'
                        Timestamp          = [datetime]::UtcNow
                        Status             =  $status
                        AdditionalData     = @{
                            Source    = $propertyName
                            Resource  = $instance.$propertyName
                            Detail    = $detail
                            Status    = $status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    New-AzStackHciResultObject @params
                }
            }

            # Add detail results
            $InstanceResults += $nodeResults
        }
        # Return single aggregated result
        return @(New-AggregatedTestResult -TestName 'Test-TpmProperties' `
            -DisplayName 'TPM Properties' `
            -Description 'Checking TPM Properties (TpmEnabled, TpmActivated, TpmReady, TpmPresent, ManufacturerVersion, etc.)' `
            -DetailResults $InstanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'TPM')
    }
    catch
    {
        throw $_
    }
}

function Test-TpmCertificates
{
    <#
    .SYNOPSIS
        Test TPM Certificates
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $allowedKeyUsage = '2.23.133.8.1' # Endorsement Key Certificate
        $allowedAlgorithms = @(
            '1.2.840.113549.1.1.11' # SHA256
            '1.2.840.113549.1.1.12' # SHA384
            '1.2.840.113549.1.1.13' # SHA512
            '1.2.840.10045.4.3.2' # SHA256ECDSA
            '1.2.840.10045.4.3.3' # SHA384ECDSA
            '1.2.840.10045.4.3.4' # SHA512ECDSA
        )
        $tpmKeys = @()
        $InstanceResults = @()
        $sb = {
            try
            {
                $tpmKeys = Get-TpmEndorsementKeyInfo -ErrorAction SilentlyContinue
            }
            catch {}
            return (New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                tpmKeys = $tpmKeys
            })
        }
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $tpmKeys += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $tpmKeys += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $tpmKeys

        # Use efficient list instead of array concatenation for better performance at scale
        $InstanceResults = [System.Collections.Generic.List[object]]::new()

        # Process TPM data - parallelize if more than 4 nodes for scale efficiency
        $nodeCount = @($tpmKeys).Count
        if ($nodeCount -gt 4)
        {
            # Parallel processing for scale
            $SystemNames = $tpmKeys | ForEach-Object { $_.ComputerName } | Sort-Object | Get-Unique
            $maxJobs = Get-OptimalParallelJobCount -NodeCount $nodeCount
            $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxJobs)
            $runspacePool.Open()

            $jobs = [System.Collections.Generic.List[object]]::new()

            foreach ($tpmKey in $tpmKeys)
            {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $runspacePool

                [void]$ps.AddScript({
                    param($tpmKey, $allowedAlgorithms, $allowedKeyUsage, $EnvChkrId, $DeviceRequirementsUrl)

                    $results = [System.Collections.Generic.List[object]]::new()
                    $computerName = $tpmKey.ComputerName
                    $tpmCert = @($tpmKey.tpmKeys.ManufacturerCertificates) + @($tpmKey.tpmKeys.AdditionalCertificates)
                    $instanceId = "Machine: $computerName, Class: TpmCertificates, Subject: $($tpmKey.tpmKeys.ManufacturerCertificates.subject), Thumbprint: $($tpmKey.tpmKeys.ManufacturerCertificates.Thumbprint)"

                    foreach ($cert in $tpmCert)
                    {
                        if (-not $cert) { continue }

                        # Test TPM certificate expiration
                        $now = [datetime]::UtcNow
                        $sinceIssued = New-TimeSpan -Start $cert.NotBefore -End $now
                        $untilExpired = New-TimeSpan -Start $now -End $cert.NotAfter
                        $currentCert = $sinceIssued.Days -gt 0 -and $untilExpired.Days -gt 0

                        # Test TPM signature algorithm
                        $validAlgo = $cert.SignatureAlgorithm.Value -in $allowedAlgorithms

                        # Test TPM certificate Enhanced Key Usage
                        $validUsage = $cert.EnhancedKeyUsageList.ObjectId -contains $allowedKeyUsage

                        $validCert = $currentCert -and $validAlgo -and $validUsage
                        [string[]]$certDetail = "TPM certificate $($cert.Thumbprint), valid = $validCert"
                        $certDetail += "   Issuer: $($cert.Issuer)"
                        $certDetail += "   Subject: $($cert.Subject)"
                        $certDetail += "   Key Usage: $($cert.EnhancedKeyUsageList.FriendlyName -join ', '), valid = $validUsage"
                        $certDetail += "   Valid from: $($cert.NotBefore) to $($cert.NotAfter), valid = $currentCert"
                        $certDetail += "   Algorithm: $($cert.SignatureAlgorithm.FriendlyName), valid = $validAlgo"

                        $status = if ($validCert) { 'SUCCESS' } else { 'FAILURE' }

                        # Return result data (will be converted to result object in main thread)
                        $results.Add(@{
                            ComputerName = $computerName
                            InstanceId = $instanceId
                            Thumbprint = $cert.Thumbprint
                            CurrentCert = $currentCert
                            ValidAlgo = $validAlgo
                            ValidUsage = $validUsage
                            Status = $status
                            CertDetail = ($certDetail -join "`r")
                        })
                    }
                    return $results
                })

                [void]$ps.AddParameter('tpmKey', $tpmKey)
                [void]$ps.AddParameter('allowedAlgorithms', $allowedAlgorithms)
                [void]$ps.AddParameter('allowedKeyUsage', $allowedKeyUsage)
                [void]$ps.AddParameter('EnvChkrId', $ENV:EnvChkrId)
                [void]$ps.AddParameter('DeviceRequirementsUrl', (Get-DeviceRequirementsUrl))

                $jobs.Add(@{
                    PowerShell = $ps
                    Handle = $ps.BeginInvoke()
                })
            }

            # Collect results from all parallel jobs
            foreach ($job in $jobs)
            {
                $jobResults = $job.PowerShell.EndInvoke($job.Handle)
                foreach ($resultData in $jobResults)
                {
                    if ($resultData)
                    {
                        $params = @{
                            Name               = 'AzStackHci_Hardware_Test_Tpm_Certificate_Properties'
                            Title              = "Test TPM Certificate Properties"
                            DisplayName        = "Test TPM $($resultData.ComputerName)"
                            Severity           = 'CRITICAL'
                            Description        = "Checking TPM for desired properties"
                            Tags               = @{}
                            Remediation        = Get-DeviceRequirementsUrl
                            TargetResourceID   = $resultData.InstanceId
                            TargetResourceName = $resultData.InstanceId
                            TargetResourceType = 'TpmEndorsementKeyInfo'
                            Timestamp          = [datetime]::UtcNow
                            Status             = $resultData.Status
                            AdditionalData     = @{
                                Source    = $resultData.Thumbprint
                                Resource  = "Current: $($resultData.CurrentCert). Valid Algorithm: $($resultData.ValidAlgo). Valid Key Usage: $($resultData.ValidUsage)."
                                Detail    = $resultData.CertDetail
                                Status    = $resultData.Status
                                TimeStamp = [datetime]::UtcNow
                            }
                            HealthCheckSource  = $ENV:EnvChkrId
                        }
                        $InstanceResults.Add((New-AzStackHciResultObject @params))
                    }
                }
                $job.PowerShell.Dispose()
            }

            $runspacePool.Close()
            $runspacePool.Dispose()
        }
        else
        {
            # Sequential processing for small node counts (runspace overhead not worth it)
            foreach ($tpmKey in $tpmKeys)
            {
                $computerName = $tpmKey.ComputerName
                $tpmCert = @($tpmKey.tpmKeys.ManufacturerCertificates) + @($tpmKey.tpmKeys.AdditionalCertificates)
                $instanceId = "Machine: $computerName, Class: TpmCertificates, Subject: $($tpmKey.tpmKeys.ManufacturerCertificates.subject), Thumbprint: $($tpmKey.tpmKeys.ManufacturerCertificates.Thumbprint)"

                foreach ($cert in $tpmCert)
                {
                    if (-not $cert) { continue }

                    $validCert = $false
                    $certDetail = $null
                    # Test TPM certificate expiration
                    $now = [datetime]::UtcNow
                    $sinceIssued = New-TimeSpan -Start $cert.NotBefore -End $now
                    $untilExpired = New-TimeSpan -Start $now -End $cert.NotAfter
                    $currentCert = $sinceIssued.Days -gt 0 -and $untilExpired.Days -gt 0

                    # Test TPM signature algorithm
                    $validAlgo = $cert.SignatureAlgorithm.Value -in $allowedAlgorithms

                    # Test TPM certificate Enhanced Key Usage
                    $validUsage = $cert.EnhancedKeyUsageList.ObjectId -contains $allowedKeyUsage

                    # Display certificate properties
                    $validCert = $currentCert -and $validAlgo -and $validUsage
                    [string[]]$certDetail = "TPM certificate $($cert.Thumbprint), valid = $validCert"
                    $certDetail += "   Issuer: $($cert.Issuer)"
                    $certDetail += "   Subject: $($cert.Subject)"
                    $certDetail += "   Key Usage: $($cert.EnhancedKeyUsageList.FriendlyName -join ', '), valid = $validUsage"
                    $certDetail += "   Valid from: $($cert.NotBefore) to $($cert.NotAfter), valid = $currentCert"
                    $certDetail += "   Algorithm: $($cert.SignatureAlgorithm.FriendlyName), valid = $validAlgo"
                    $foundValidCert = $foundValidCert -or $validCert

                    $status = if ($validCert) { 'SUCCESS' } else { 'FAILURE' }

                    $params = @{
                        Name               = 'AzStackHci_Hardware_Test_Tpm_Certificate_Properties'
                        Title              = "Test TPM Certificate Properties"
                        DisplayName        = "Test TPM $computerName"
                        Severity           = 'CRITICAL'
                        Description        = "Checking TPM for desired properties"
                        Tags               = @{}
                        Remediation        = Get-DeviceRequirementsUrl
                        TargetResourceID   = $instanceId
                        TargetResourceName = $instanceId
                        TargetResourceType = 'TpmEndorsementKeyInfo'
                        Timestamp          = [datetime]::UtcNow
                        Status             = $status
                        AdditionalData     = @{
                            Source    = $cert.Thumbprint
                            Resource  = "Current: $currentCert. Valid Algorithm: $validAlgo. Valid Key Usage: $validUsage."
                            Detail    = ($certDetail -join "`r")
                            Status    = $status
                            TimeStamp = [datetime]::UtcNow
                        }
                        HealthCheckSource  = $ENV:EnvChkrId
                    }
                    $InstanceResults.Add((New-AzStackHciResultObject @params))
                }
            }
        }

        $algoNames = 'SHA256, SHA384, SHA512, SHA256ECDSA, SHA384ECDSA, SHA512ECDSA'
        return @(New-AggregatedTestResult -TestName 'Test-TpmCertificates' `
            -DisplayName 'TPM Certificate Properties' `
            -Description "Checking TPM Endorsement Key Certificates (not expired, algorithm in [$algoNames], EK usage present)" `
            -DetailResults $InstanceResults.ToArray() `
            -ValidatorName 'Hardware' `
            -ResourceType 'TPM')
    }
    catch
    {
        throw $_
    }
}

function Test-SecureBoot
{
    <#
    .SYNOPSIS
        Test Secure Boot
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $secureBoots = @()
        $sb = {

            if ((Get-Command Confirm-SecureBootUEFI -ErrorAction  SilentlyContinue) -ne $null) {
                <#
                    For devices that Standard hardware security is not supported, this means that the device does not meet
                    at least one of the requirements of standard hardware security.
                    This causes the Confirm-SecureBootUEFI command to fail with the error:
                    Cmdlet not supported on this platform: 0xC0000002
                #>
                try {
                    $secureBoot = Confirm-SecureBootUEFI
                }
                catch {
                    $secureBoot = $false
                }
            }
            else {
                $secureBoot = $false
            }

            New-Object PsObject -Property @{
                SecureBoot = $secureBoot
                ComputerName = $env:COMPUTERNAME
            }
        }
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $secureBoots += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $secureBoots += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $secureboots
        $InstanceResults = @()
        $InstanceResults += foreach ($SecureBootUEFI in $secureBoots)
        {
            $dtl = $lhwTxt.SecureBoot -f $SecureBootUEFI.SecureBoot, $SecureBootUEFI.ComputerName, 'True'
            if ($SecureBootUEFI.SecureBoot)
            {
                $status = 'SUCCESS'
            }
            else
            {
                $status = 'FAILURE'
                $dtl = "{0} {1}" -f $dtl, $lhwTxt.SecureBootNotSupported
            }
            $instanceId = "Machine: $($SecureBootUEFI.ComputerName), SecureBoot"
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_Secure_Boot'
                Title              = "Test Secure Boot"
                DisplayName        = "Test Secure Boot $($SecureBootUEFI.computerName)"
                Severity           = 'CRITICAL'
                Description        = "Checking Secure Boot is enabled"
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'SecureBoot'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $SecureBootUEFI.ComputerName
                    Resource  = $SecureBootUEFI.SecureBoot
                    Detail    = $dtl
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }

        return @(New-AggregatedTestResult -TestName 'Test-SecureBoot' `
            -DisplayName 'Secure Boot' `
            -Description 'Checking Secure Boot is enabled' `
            -DetailResults $InstanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'SecureBoot')
    }
    catch
    {
        throw $_
    }
}

function Test-StoragePool
{
    <#
    .SYNOPSIS
        Test Storage Pools do not exist
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $StoragePoolsExist = @()
        $sb = {
            New-Object PsObject -Property @{
                StoragePoolExists = [bool](Get-StoragePool -IsPrimordial:$false -ErrorAction SilentlyContinue)
                ComputerName = $ENV:ComputerName
            }
        }
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $StoragePoolsExist += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $StoragePoolsExist += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $StoragePoolsExist

        $InstanceResults = @()
        $InstanceResults += foreach ($StoragePool in $StoragePoolsExist)
        {
            $status = if (-not $StoragePool.StoragePoolExists) { 'SUCCESS' } else { 'FAILURE' }
            $instanceId = "Machine: $($StoragePool.ComputerName), StoragePool"
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_No_StoragePools'
                Title              = "Test Storage Pools do not exist for new deployment"
                DisplayName        = "Test Storage Pools do not exist for new deployment $($StoragePool.computerName)"
                Severity           = 'CRITICAL'
                Description        = "Checking no storage pools exist for new deployment"
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'StoragePool'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = 'StoragePool'
                    Resource  = if ([bool]$StoragePool.StoragePoolExists) { "Present" } else { "Not present" }
                    Detail    = $lhwTxt.StoragePoolFail -f [bool]$StoragePool.StoragePoolExists, 'False'
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }

        return @(New-AggregatedTestResult -TestName 'Test-StoragePool' `
            -DisplayName 'Storage Pool' `
            -Description 'Checking no storage pools exist for new deployment' `
            -DetailResults $InstanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'StoragePool')
    }
    catch
    {
        throw $_
    }
}

function Test-SystemDriveFreeSpace
{
    <#
    .SYNOPSIS
        Test free space of system drive
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity.
    #>
    [CmdletBinding()]
    param (

        [Parameter()]
        [int64]
        $Threshold = 30GB,

        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $cimData = @()
        $InstanceResults = @()
        $sb = {
            $systemDrive = Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty SystemDrive
            $cimData = Get-CimInstance -ClassName Win32_LogicalDisk -Property DeviceId, FreeSpace | Where-Object DeviceID -EQ $systemDrive
            return New-Object PsObject -Property @{
                ComputerName = $ENV:ComputerName
                DeviceID = $cimData.DeviceID
                FreeSpace = $cimData.FreeSpace
            }
        }
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $results += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $results += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $results
        $InstanceResults += foreach ($result in $results)
        {
            $computerName = $result.ComputerName
            $freeSpaceStr = [int]($result.FreeSpace / 1GB)
            $thresholdStr = [int]($threshold / 1GB)
            $dtl = $lhwtxt.LocalRootFolderPathFreeSpace -f $computerName, $result.DeviceID, $freeSpaceStr, $thresholdStr
            if ($result.FreeSpace -gt $Threshold)
            {
                $status = 'SUCCESS'
                Log-Info $dtl
            }
            else
            {
                $status = 'FAILURE'
                Log-Info $dtl -Type CRITICAL
            }

            $instanceId = "Machine: $computerName, Class: Disk, DriveLetter: $($result.DeviceID)"
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_SystemDrive_Free_Space'
                Title              = "Test System Drive Free Space"
                DisplayName        = "Test System Drive Free Space"
                Severity           = 'CRITICAL'
                Description        = "Checking System Drive Free Space"
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'Disk'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $computerName
                    Resource  = $cim.DeviceID
                    Detail    = $dtl
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }

        $thresholdGB = [int]($Threshold / 1GB)
        return @(New-AggregatedTestResult -TestName 'Test-SystemDriveFreeSpace' `
            -DisplayName 'System Drive Free Space' `
            -Description "Checking System Drive Free Space (minimum ${thresholdGB} GB)" `
            -DetailResults $InstanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'Disk')
    }
    catch
    {
        throw $_
    }
}

function Test-Volume
{
    <#
    .SYNOPSIS
        Test free space
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $Drive = @('C'),

        # TO DO: Implement Free Space check
        [Parameter()]
        [int64]
        $Threshold = 30GB,

        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $cimData = @()
        $CountResult = @()
        $InstanceCountByGroup = @()

        $sb = {
            $cimData = Get-Volume | Where-Object DriveLetter -in $args
            return $cimData
        }
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $cimData += Invoke-Command -ScriptBlock $sb -ArgumentList $Drive
        }
        else
        {
            $cimData += Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList $Drive
        }

        $groupProperty = @(
            'DriveLetter'
        )

        Log-CimData -cimData $cimData -Properties $groupProperty

        $SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
        foreach ($systemName in $SystemNames)
        {
            $sData = @($CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName })
            #Log-Info -Message ($lhwTxt.VolumeCount -f $systemName, ($Drive -join ','), $sData.Count)
            # Make sure each system has the requisite number of drives labelled as expected drive letters (e.g. C, D, E)
            $CountResult += Test-Count -CimData $sData -minimum $Drive.Count -ValidatorName 'Hardware' -Severity Critical
        }
        # Make sure each node has the same count by group
        $InstanceCountByGroup += Test-InstanceCountByGroup -CimData $cimData -ValidatorName 'Hardware' -GroupProperty $groupProperty -Severity Critical
        # Finally, the all properties from the $matchProperty array have to be compared for all instances across all nodes.
        $allDetailResults = @($CountResult + $InstanceCountByGroup)
        return @(New-AggregatedTestResult -TestName 'Test-Volume' `
            -DisplayName 'Volume' `
            -Description 'Checking Volume count and consistency across nodes' `
            -DetailResults $allDetailResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'Volume')
    }
    catch
    {
        throw $_
    }
}

function CheckDisksAreAllFlash
{
        param ($cimData)
        # Split disks into type and check each server has the same count
        $allSSD = $cimData | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'SAS|10|SATA|11'}
        $allNVMe = $cimData | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'NVMe|17'}
        $allSCM = $cimData | Where-Object {$_.MediaType -match 'SCM|5'}
        $allHDD = $cimData | Where-Object {$_.MediaType -match 'HDD|3'}
        $className = $CimData.CimSystemProperties.ClassName -split '_' | Select-Object -Last 1
        $instanceId = $CimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique

        Log-Info ($lhwTxt.DisksAreAllFlash -f $instanceId)

        # check if they are all flash
        if ($allSSD -xor $allNVMe -and !$allSCM -and !$allHDD)
        {
            $Status = 'SUCCESS'
            $type = 'Info'
        }
        else
        {
            $Status = 'FAILURE'
            $type = 'CRITICAL'
        }

        $detail = $lhwTxt.DisksAreAllFlashDetail -f $instanceId,("HDD: {0}, SSD:{1}, NVMe:{2}, SCM:{3}" -f [bool]$allHDD, [bool]$allSSD, [bool]$allNVMe, [bool]$allSCM)
        Log-Info $detail -Type $type

        $params = @{
            Name               = 'AzStackHci_Hardware_Test_PhysicalDisk_AllFlash'
            Title              = "Test PhysicalDisks are All Flash"
            DisplayName        = "Test PhysicalDisks are All Flash"
            Severity           = 'CRITICAL'
            Description        = "Checking PhysicalDisks are all flash"
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-direct-hardware-requirements#minimum-number-of-drives-excludes-boot-drive'
            TargetResourceID   = $instanceId
            TargetResourceName = $instanceId
            TargetResourceType = $className
            Timestamp          = [datetime]::UtcNow
            Status             = $status
            AdditionalData     = @{
                Source    = "$className Drive Type"
                Resource  = "HDD: {0}, SSD:{1}, NVMe:{2}, SCM:{3}" -f [bool]$allHDD, [bool]$allSSD, [bool]$allNVMe, [bool]$allSCM
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
}

function Test-MinCoreCount
{
    <#
    .SYNOPSIS
        Get minimum core count
    .DESCRIPTION
        Get core count from local machine to use as minimum core count
        Expecting data from PsSessions to include local machine indicating ECE.
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_Processor'
                Property  = 'NumberOfCores'
            }
            $cimData = @(Get-CimInstance @cimParams)
            return $cimData
        }
        $cimData = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        $instanceResults = @()
        Log-CimData -cimData $cimData -Properties NumberOfCores

        if ((Get-WmiObject -Class Win32_ComputerSystem).Model -eq "Virtual Machine")
        {
            $environmentType = "Virtual"
            $RequiredTotalNumberOfCores = 4
        } else {
            $environmentType = "Physical"
            # Set min cores to local machine
            # This should only apply the scenario where there is a PsSession to all nodes,
            # and one of the nodes is also the local machine i.e. ECE invocation
            $RequiredTotalNumberOfCores = GetTotalNumberOfCores -cimData ($cimData | Where-Object { $_.CimSystemProperties.ServerName -like "$($ENV:COMPUTERNAME)*"})
        }
        Log-Info -Message ($lhwTxt.CoreCountRequirement -f $RequiredTotalNumberOfCores, $environmentType)

        if ($RequiredTotalNumberOfCores)
        {
            [array]$SystemNames = $cimData.CimSystemProperties.ServerName | Sort-Object | Get-Unique
            $instanceResults += foreach ($systemName in $SystemNames)
            {
                $sData = $CimData | Where-Object { $_.CimSystemProperties.ServerName -eq $systemName }
                $TotalNumberOfCores = GetTotalNumberOfCores -cimData $sData
                if ($TotalNumberOfCores)
                {
                    $detail = $lhwTxt.CheckMinCoreCount -f $SystemName, $TotalNumberOfCores, $RequiredTotalNumberOfCores
                    if ($TotalNumberOfCores -ge $RequiredTotalNumberOfCores)
                    {
                        $status = 'SUCCESS'
                        Log-Info -message $detail
                    }
                    else
                    {
                        $status = 'FAILURE'
                        Log-Info -message $detail -Type Warning
                    }
                }
                else
                {
                    $detail = $lhwTxt.UnexpectedCoreCount -f 'Unavailable','1'
                    $status = 'FAILURE'
                    Log-Info -message $detail -Type Warning
                }

                $params = @{
                    Name               = 'AzStackHci_Hardware_Test_Minimum_CPU_Cores'
                    Title              = 'Test Minimum CPU Cores'
                    DisplayName        = "Test Minimum CPU Cores $systemName"
                    Severity           = 'WARNING'
                    Description        = 'Checking minimum CPU cores'
                    Tags               = @{}
                    Remediation        = Get-DeviceRequirementsUrl
                    TargetResourceID   = $systemName
                    TargetResourceName = $systemName
                    TargetResourceType = $cimParams.className
                    Timestamp          = [datetime]::UtcNow
                    Status             = $status
                    AdditionalData     = @{
                        Source    = $systemName
                        Resource  = 'Core Count'
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                New-AzStackHciResultObject @params
            }
        }
        else
        {
            Log-info $lhwTxt.SkippedCoreCount -type Warning
        }

        return @(New-AggregatedTestResult -TestName 'Test-MinCoreCount' `
            -DisplayName 'Minimum CPU Cores' `
            -Description "Checking minimum CPU cores (minimum ${RequiredTotalNumberOfCores} cores per node, ${environmentType})" `
            -DetailResults $instanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'CPU')
    }
    catch
    {
        throw $_
    }
}

function Test-VirtualDisk
{
        <#
    .SYNOPSIS
        Test Virtual Disk
    .DESCRIPTION
        During repair test virtual disk
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $sb = {
            New-Object -Type PsObject -Property @{
                VirtualDiskExists = [bool](Get-StoragePool -IsPrimordial:$false -ErrorAction SilentlyContinue | Get-VirtualDisk)
                ComputerName = $ENV:COMPUTERNAME
            }
        }

        $VirtualDiskExists = @()
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $VirtualDiskExists += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $VirtualDiskExists += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $VirtualDiskExists
        $instanceResults = @()
        $instanceResults += foreach ($virtualDisk in $VirtualDiskExists)
        {
            if ($virtualDisk.VirtualDiskExists)
            {
                $status = 'SUCCESS'
                $detail = $lhwTxt.VirtualDiskExists -f $virtualDisk.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $lhwTxt.VirtualDiskNotExists -f $virtualDisk.ComputerName
                Log-Info $detail -Type Warning
            }

            $instanceId = "Machine: $($virtualDisk.ComputerName), Class: VirtualDisk"
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_VirtualDisk_Exists'
                Title              = 'Test Virtual Disk exists'
                DisplayName        = "Test Virtual Disk exists $($virtualDisk.ComputerName)"
                Severity           = 'CRITICAL'
                Description        = 'Checking virtual disk(s) exist for repair'
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'VirtualDisk'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $virtualDisk.ComputerName
                    Resource  = if ($virtualDisk.VirtualDiskExists) { "Present" } else { "Not present" }
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch
    {
        throw $_
    }
}

function Test-VirtualizationBasedSecurity
{
    <#
    .SYNOPSIS
        Test Virtualization-based Security (VBS)
    .DESCRIPTION
        Test if hardware supports VBS, which is required on HCI
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $vbsMethodDefinition = @'
public enum Values
{
    SecureKernelRunning,
    HvciEnabled,
    HvciStrictMode,
    DebugEnabled,
    FirmwarePageProtection,
    EncryptionKyAvailable,
    SpareFlags,
    TrustletRunning,
    HvciDisableAllowed,
    SpareFlags2,
    Sparce1,
    Sparce2,
    Sparce3,
    Sparce4,
    Sparce5,
    Sparce6
}

public enum SYSTEM_INFORMATION_CLASS_EX : uint
{
    SystemBootEnvironmentInformation = 90,
    SystemIsolatedUserModeInformation = 165,
    SystemDmaGuardPolicyInformation = 202
}

public struct SYSTEM_ISOLATED_USER_MODE_INFORMATION
{
    public Values Bits;
    public ulong Spare7;
}

public static bool GetVBSCapable()
{
    bool capable = false;
    bool enabled = false;

    GetVBSInfo(ref capable, ref enabled);
    return capable;
}

[DllImport("ntdll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern uint NtQuerySystemInformation(
  [In] SYSTEM_INFORMATION_CLASS_EX SystemInformationClass,
  [In][Out] IntPtr SystemInformation,
  [In] uint SystemInformationLength,
  [Out] uint ReturnLength);

public static void GetVBSInfo(ref bool capable, ref bool enabled)
{
    var outSize = (uint)0;
    var outBuffer = IntPtr.Zero;

    try
    {
        outSize = (uint)Marshal.SizeOf(typeof(SYSTEM_ISOLATED_USER_MODE_INFORMATION));
        outBuffer = Marshal.AllocHGlobal((int)outSize);

        for (long offset = 0; offset < outSize; offset++)
        {
            Marshal.WriteByte(outBuffer, (int)offset, 0);
        }

        uint retValue = NtQuerySystemInformation(SYSTEM_INFORMATION_CLASS_EX.SystemIsolatedUserModeInformation, outBuffer, outSize, 0);
        if (retValue != 0)
        {
            throw new Exception(Marshal.GetLastWin32Error().ToString());
        }

        SYSTEM_ISOLATED_USER_MODE_INFORMATION iumInfo = new SYSTEM_ISOLATED_USER_MODE_INFORMATION();
        iumInfo = (SYSTEM_ISOLATED_USER_MODE_INFORMATION)Marshal.PtrToStructure(outBuffer, typeof(SYSTEM_ISOLATED_USER_MODE_INFORMATION));

        capable = ((int)iumInfo.Bits | 0x01) != 0;
        enabled = ((int)iumInfo.Bits | 0x02) != 0;
    }
    finally
    {
        Marshal.FreeHGlobal(outBuffer);
    }
}
'@
            $null = Add-Type -MemberDefinition $vbsMethodDefinition -Name "VirtualizationBasedSecurity" -Namespace "Microsoft.PowerShell.AzStackHci.EnvironmentChecker.Hardware" -PassThru
            $vbsCapable = [Microsoft.PowerShell.AzStackHci.EnvironmentChecker.Hardware.VirtualizationBasedSecurity]::GetVBSCapable()

            New-Object -Type PsObject -Property @{
                VbsCapable = $vbsCapable
                ComputerName = $ENV:COMPUTERNAME
            }
        }

        $vbsCapabilities = @()
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $vbsCapabilities += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $vbsCapabilities += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $vbsCapabilities
        $instanceResults = @()
        $instanceResults += foreach ($vbsCapability in $vbsCapabilities)
        {
            if ($vbsCapability.VbsCapable)
            {
                $status = 'SUCCESS'
                $detail = $lhwTxt.VbsCapable -f $vbsCapability.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $lhwTxt.VbsIncapable -f $vbsCapability.ComputerName
                Log-Info $detail -Type Warning
            }

            $instanceId = "Machine: $($vbsCapability.ComputerName), Class: Virtualization-based Security"
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_VirtualizationBasedSecurity'
                Title              = 'Test Virtualization-based Security'
                DisplayName        = "Test Virtualization-based Security $($virtualDisk.ComputerName)"
                Severity           = 'CRITICAL'
                Description        = 'Checking Virtualization-based Security capability'
                Tags               = @{}
                Remediation        = Get-DeviceRequirementsUrl
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'Virtualization-based Security'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $vbsCapability.ComputerName
                    Resource  = if ($vbsCapability.VbsCapable) { "Present" } else { "Not present" }
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }

        return @(New-AggregatedTestResult -TestName 'Test-VirtualizationBasedSecurity' `
            -DisplayName 'Virtualization-based Security' `
            -Description 'Checking Virtualization-based Security capability' `
            -DetailResults $InstanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'VBS')
    }
    catch
    {
        throw $_
    }
}

function GetTotalNumberOfCores
{
    <#
    .SYNOPSIS
        Multiply number of cores by number of processors
    .DESCRIPTION
        Multiply number of cores by number of processors
    #>

    param ($cimData)

    try {
        if ($cimData)
        {
            $numberOfCores = $cimData | Select-Object -ExpandProperty NumberOfCores | Sort-Object | Get-Unique
            if ($numberOfCores.count -ne 1)
            {
                throw ($lhwTxt.UnexpectedCoreCount -f $numberOfCores.count, '1')
            }
            else
            {
                return ($numberOfCores * @($cimData).count)
            }
        }
        else
        {
            throw $lhwTxt.NoCoreReference
        }
    }
    catch
    {
        Log-Info ($lhwTxt.UnableCoreCount -f $_) -Type Warning
    }
}

function Test-MountedMedia
{
    <#
    .SYNOPSIS
        Test Mounted Media
    .DESCRIPTION
        Test is any media is mounted on the system such as CD, DVD, etc.
    .PARAMETER SummaryOnly
        When specified, returns aggregated results per severity.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [switch]
        $SummaryOnly
    )
    try
    {
        $sb = {
            $cimParams = @{
                ClassName = 'Win32_CDROMDrive'
                Property  = '*'
            }
            $cimData = @(Get-CimInstance @cimParams)
            New-Object -Type PsObject -Property @{
                MediaExists = [bool]$cimData.MediaLoaded
                cimData = $cimData
                ComputerName = $ENV:COMPUTERNAME
            }
        }

        $remoteOutput = @()
        if ([string]::IsNullOrEmpty($PsSession))
        {
            $remoteOutput += Invoke-Command -ScriptBlock $sb
        }
        else
        {
            $remoteOutput += Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        Log-CimData -cimData $remoteOutput.CimData
        $instanceResults = @()
        $instanceResults += foreach ($media in $remoteOutput)
        {
            if ($media.MediaExists)
            {
                $status = 'FAILURE'
                $detail = $lhwTxt.MediaExists -f $media.ComputerName, ($media.CimData | % { "Name: $($_.Name), Media: $($_.Caption), Drive: $($_.Drive)" }) -join '. '
                Log-Info $detail -Type CRITICAL
            }
            else
            {
                $status = 'SUCCESS'
                $detail = $lhwTxt.MediaNotExists -f $media.ComputerName
                Log-Info $detail
            }

            $instanceId = "Machine: $($media.ComputerName), Class: CDROMDrive"
            $params = @{
                Name               = 'AzStackHci_Hardware_Test_MountedMedia_Exists'
                Title              = 'Test No Mounted Media exists'
                DisplayName        = "Test No Mounted Media exists $($virtualDisk.ComputerName)"
                Severity           = 'CRITICAL'
                Description        = 'Checking mounted media does not exist'
                Tags               = @{}
                Remediation        = 'https://aka.ms/nomountedmedia'
                TargetResourceID   = $instanceId
                TargetResourceName = $instanceId
                TargetResourceType = 'CDROMDrive'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $media.ComputerName
                    Resource  = if ($virtualDisk.MediaExists) { "Present" } else { "Not present" }
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }

        return @(New-AggregatedTestResult -TestName 'Test-MountedMedia' `
            -DisplayName 'Mounted Media' `
            -Description 'Checking mounted media does not exist' `
            -DetailResults $instanceResults `
            -ValidatorName 'Hardware' `
            -ResourceType 'CDROMDrive')
    }
    catch
    {
        throw $_
    }

}

Export-ModuleMember -Function Test-*

# SIG # Begin signature block
# MIInSAYJKoZIhvcNAQcCoIInOTCCJzUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD5sAhRniAowDE8
# IwXkrjZ98R5Mgs6ebPy67gPe/CeXzaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnkMIIZ4AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGvPJAg4
# Q7S2i0ZIPYt48qKcEj3uxlxic3j6CUcjaLKTMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAt8f29KqMjeQHf7XH/DSswzNfK2YEA1Cxevomn+S3
# Fby4KbhOMPF/grVLYMb7EpIAx5BYpMd4PjIJSb+Icix2/Fpi0/IHvMnX/PpkJTac
# Nsgj6dXF4i7uQkYukfgCglKMr9KYHiRDcv1gLa4b53VRtjjMeZczFFYnoS+sBcBe
# b/IZP70tKW52CAgnZYY4FS0yxodbY4ck21n12J9L79zzvtMNmGqS013I8bS3zC2j
# nBNNPr+2DfY1dH+tVe9pjZm+UOh4YjL8neeoMhvdQhNm7q1nlUUZRPjNrQhAIFQD
# VBlzvc2JrV8hAQ29Oa36km4RkkYu0kdQMjXf/mb9qDdTyqGCF5YwgheSBgorBgEE
# AYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDla6sRVXlDdn/OEU2QyWGn/rKKIsOC/OuIu0Mb
# lecfMwIGaeexRuPdGBIyMDI2MDUwMzE0MzExMC44MlowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjo4OTAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMzAAACIkHS9qr/yLX/AAEAAAIi
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5Mzk1NloXDTI3MDUxNzE5Mzk1NlowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo4OTAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALW54om6Qi5SwAAmj8BjkNlGoftu
# GC/sJYY2UR1tEaghOt0Tpayfns1o27UFN2MFsVy/tF+LG17TH4dG9dKqwP5Z5Jf/
# r/L3ATQzP7FE9MYhjbQrtpANrrw7LNXJR5QLKnJkL+Bb/fK079k6dT0fauLvuQk/
# wAGurLLVTFf86x4SC8eyPzKKRZPQBG2uNZtcwcXNI6jmFBx9SYxcqpZbPr43T5TK
# eEbLWf52hbhZmCkfxjlbuGlKiRaPUz8u7jCLejoPP29Va6RyBQUaMsCXhhmk6FqH
# se6IL9qVciYxB/wLcDyr/r/WEWh4hkHhQaTLDEH85JM5Kwvr7f2kOrMzsKA6l/hX
# v32Q33jIz25ckjlP9KIDkx0hkiERbT5uHzlGoOHlhbf+hq/nhE/HDk4+UfrhBXoo
# mSXQUgSUxWgs2jxRZFBwwPXv3HtYBKMLouxo1nvIrSpwRIiwvXCJCZ19AHFyqsUK
# khB+eZAWQ6n0jJdRarNry2anPwTppeD1vV6IBPc9VOCs6U+L+FhkJ8/Ff/qMa3I+
# PLUKLA6YlqaiGZJT/8I4B6d9FPYbYcxFSkJfXOz4CYOZ1AzVdFpvhhIAssCUPMYK
# yAjvuee4mOhcCWIma/s1+u9YBwDkqoJQ5ZDqRI+3mvbwx8pdYkmlJe0V5L8yQPMn
# L+IlFXIdwXL8H4y3AgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUWQfAagMnllsQSK7w
# qy2K6ypqjNAwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAGIAz6equnAbb23FJe/j
# aj4KxN7YLhuhpF8WO70lpaQtMfCrumSc040vef5QbfH8HTzcQpeIVisCa6XsFMcI
# ZdTrf/FGxnbCPdmZHQDh32d/2xoIlWbiO49UUFqL+iS045gfaP7X7MzvTCg3mieA
# H+m/LtfwB9jokHhc+9vzRDPt9jl511ufCPODWxmFQ8VttzB5Z4AIg2vOoUrraYx5
# cqaG258ytqiiAl4ld9ZjfHj+lu5uAQ1Pf6ldPrnbTcI8X2R90oTsYoAhFjLfGQFM
# O8V3x25+M6kKffycrqoyVW2cGMOFZAbQ8zcT+jEGzlQGsjqkFiSYge1uOJ8Oq4dP
# 5OFpVXvEdzoiehJzdo3Nfj0kdSBCa68N0yMuRthd4DT/WrkjFKDZT7JxkE68CLe5
# 1k8qEDlXM4ON/+5y7+8W1ethxGSYYo3eO6Norf/IxmLYm7k0QvchJaivCntGN5mD
# 4kwgrR+iy5WP5gKbmvrgsf8P1AkMCP5d9lo14V2/3QrkDRBFEY/+mgH3JMhWMReP
# +4nOnwvgN3jiwCq6oM6Id2QuDF8ryc+qkJJY9n0b5EI+bzmj1wB/EQ22tK47BynI
# rPGxEJgIv48rj73yiuK30RUn8sugJ4b6MuWPQpoPhDLqxl7itYyvVutAuixMFk3A
# WdfE2MicJYF3SLuKzXJNL/ipMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
# AAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUg
# QXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2
# AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpS
# g0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2r
# rPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k
# 45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSu
# eik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09
# /SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR
# 6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxC
# aC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaD
# IV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMUR
# HXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMB
# AAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQq
# p1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ
# 6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBB
# MAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP
# 6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWlj
# cm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2
# LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMu
# Y3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2
# Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03d
# mLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1Tk
# eFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kp
# icO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKp
# W99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrY
# UP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QB
# jloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkB
# RH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0V
# iY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq
# 0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1V
# M1izoXBm8qGCA1AwggI4AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVALvJxdVnHduwOkmSvtW5yCmSyjO4oIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoVcuMCIYDzIw
# MjYwNTAzMDUxMDA2WhgPMjAyNjA1MDQwNTEwMDZaMHcwPQYKKwYBBAGEWQoEATEv
# MC0wCgIFAO2hVy4CAQAwCgIBAAICN5ICAf8wBwIBAAICEzkwCgIFAO2iqK4CAQAw
# NgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgC
# AQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAgLKhVux+TaBi9gKTjxskgaGAV9Io
# VWotwPWgJe7DhmaxRA7bdNM79BTVmf4EfP14pordrFXz4Y5tAh7CmxOi6OZKmz3W
# NOixDUjCrXIocrBugyMJ/Uc+JkvyeBYMnKSvLYQyEaOrL6jcdzr05lubVoj2ahEj
# Xeg3iO1Bl1kvexOq3qnA9+rAUDcMF5y766K/TKer6AW1T0dN2Nqt2k03g5jWxAB7
# UxJtdLQoFdhaTbjhO2/bQxMaYxcALKKfLWVN1EDUKjrukY/MDiHXP9D9WDdjQ+wW
# C9adHEbujEirIl7CZrX1JitqOMNhXKw0D8c2aJ6LE0JME1MnvFRyu7MCsTGCBA0w
# ggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACIkHS
# 9qr/yLX/AAEAAAIiMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIJk38WEkqQkhBTBLrf5Ex3sLoyBl
# GnJCWAjDWafMHUAnMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgBWBdAQoE
# 58aCM2ySYM6ZtwQg6ccY3AD5BxG58NHkCRMwgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiJB0vaq/8i1/wABAAACIjAiBCB7QFg9T4Y4
# 5A21OGzwkhPilVnEr7QJ1O/EiZ6D89XFtzANBgkqhkiG9w0BAQsFAASCAgAMjRfD
# TVNNwueu421L1I4COXs9w2qLoQ2XWSgEecVvjTgO1CubTDxFHuht3cECUk93kmGB
# 3NOqCmL3yt4aclJhvA+vftHeWXz8+ntT3jMRZTGIaJ2SzpcGrNKdhX2nha3AvGkV
# 3fqMa2X2YlMyLx0vg/dblZkH0LLNEjXq3ofYkXZval3AL3i43lrjlw/Tk6LVLivD
# KM83QrC5Nc+QjOm5+tX6EYF7dMmvSDwajtThZHFGBd/u/NkA+a0u8LgeZ0kEuR3N
# dELYqOdL5PnOZL7spAX3/YPPkZ71FxJa5MrbNo7cEV1DcEoagW09+6ubW2xsSSrp
# l637opo21OmnlsXyonbM2BlXmzReXoF3umwCv0tAdZCK/f7oAVDMLz0lyP4ci8Vr
# 3CkOxZOBRpqSPkhFEFIdqnTP06XxxrNOdpnKQZty98b/tjhuxqX8O/uvRyCL7WO1
# Uh5NDE5p91U2C0w/WuVp1KbGmNn31X5leia02p3OTD7IFJ902i+uY2MiT2k4pND/
# 3s/XER9HHAeR6MZdfSSfusQg/GIHYvuWzeyvLMD+3Gt2jHBZGhQUTMPFS9CtV6OO
# JW0vLaK/W3AQZUcRj3nljFtPMy+vF3Y98Pd94kiTlATBaewGRK4ME28v38Sru+Tq
# J2ly1ZZcOU881ddC9bkUFb3xsydL4QmVaNwpzQ==
# SIG # End signature block
