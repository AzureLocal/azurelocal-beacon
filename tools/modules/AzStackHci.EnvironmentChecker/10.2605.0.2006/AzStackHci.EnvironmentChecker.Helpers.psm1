<#
    .SYNOPSIS
        Validation Helper functions for AzStackHci Environment Checker
    .DESCRIPTION
        This module contains validation helper functions for AzStackHci Environment Checker that can be used across multiple validators.
    .NOTES
        See individual function documentation for details and usage.
#>

function Assert-ServiceState
{
    <#
    .SYNOPSIS
        Asserts and corrects the state of one or more services on local or remote computers.

    .DESCRIPTION
        This function validates the running state and startup type of specified Windows services.
        It supports both local and remote execution via PSSession, can attempt automatic remediation,
        and returns standardized AzStackHciResultObject(s) for integration with environment validation workflows.

        When remediation is enabled, the function will:
        1. Check current service state
        2. Attempt to correct any mismatches (startup type first, then running state)
        3. Wait for the specified duration to allow service stabilization
        4. Re-verify the service state
        5. Report success or failure with detailed error information

        Results can be returned per-service or grouped (one result per computer covering all services).

        Two modes are supported:
        - Simple mode: All services use the same DesiredState, DesiredStartupType, and WaitTimeSeconds
        - Advanced mode: Each service can have individual configuration via ServiceConfiguration hashtable

    .PARAMETER ServiceName
        One or more service names to validate. Use the service name (not display name).
        Example: 'WinRM', 'W32Time', 'WinHttpAutoProxySvc'
        Used in simple mode where all services share the same configuration.

    .PARAMETER ServiceConfiguration
        Hashtable where keys are service names and values are hashtables containing:
        - DesiredState: 'Running' or 'Stopped' (optional)
        - DesiredStartupType: 'Automatic', 'Manual', 'Disabled', or 'AutomaticDelayedStart' (optional)
        - WaitTimeSeconds: Integer 1-300 (optional, defaults to global WaitTimeSeconds)

        Example:
        @{
            'WinRM' = @{ DesiredState = 'Running'; DesiredStartupType = 'Automatic'; WaitTimeSeconds = 60 }
            'Spooler' = @{ DesiredState = 'Stopped'; DesiredStartupType = 'Disabled'; WaitTimeSeconds = 15 }
        }

    .PARAMETER DesiredState
        The expected running state of the service(s).
        Valid values: 'Running', 'Stopped'
        If not specified, only startup type is validated.
        Applies to all services when using ServiceName parameter.

    .PARAMETER DesiredStartupType
        The expected startup type of the service(s).
        Valid values: 'Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart'
        If not specified, only running state is validated.
        Applies to all services when using ServiceName parameter.

    .PARAMETER PsSession
        Existing PSSession(s) to use for remote service validation.
        If not specified, validates services on the local computer.

    .PARAMETER Remediate
        When specified, attempts to correct service state if it doesn't match desired configuration.
        - Sets startup type to DesiredStartupType if specified and mismatched
        - Starts/stops service to match DesiredState if specified and mismatched
        - Waits for WaitTimeSeconds after changes
        - Re-validates state before returning results

    .PARAMETER WaitTimeSeconds
        Number of seconds to wait after remediation attempts before re-checking service state.
        Default: 30 seconds
        This allows time for services to fully initialize or stop.
        Can be overridden per-service when using ServiceConfiguration parameter.

    .PARAMETER MaxRetries
        Maximum number of remediation attempts before giving up.
        Default: 1 (single attempt)
        Range: 1-5
        Each retry includes the full cycle: attempt fix → wait → verify.

    .PARAMETER Severity
        Severity level for the result object.
        Valid values: 'CRITICAL', 'WARNING', 'INFORMATIONAL', 'Hidden'

    .PARAMETER ValidatorName
        Name of the parent validator calling this function.
        Used for result object naming and categorization.

    .PARAMETER TestName
        Custom name for the test result object. Overrides the default naming pattern.
        Use placeholders: {ValidatorName}, {ServiceName}, {ComputerName}
        Example: 'AzStackHci_{ValidatorName}_Custom_{ServiceName}'

    .PARAMETER TestTitle
        Custom title for the test result object. Overrides the default title.
        Use placeholders: {ServiceName}, {ComputerName}
        Example: 'Validate {ServiceName} Configuration'

    .PARAMETER TestDisplayName
        Custom display name for the test result object. Overrides the default display name.
        Use placeholders: {ServiceName}, {ComputerName}
        Example: '{ServiceName} on {ComputerName}'

    .PARAMETER GroupResults
        When specified, returns one result object per computer covering all services.
        When omitted (default), returns one result object per service per computer.
        Useful for reducing result object count when validating multiple services.

    .OUTPUTS
        Returns one or more AzStackHciResultObject instances.

    .EXAMPLE
        Assert-ServiceState -ServiceName 'WinRM' -DesiredState 'Running' -DesiredStartupType 'Automatic' -Severity 'CRITICAL' -ValidatorName 'Network'

        Validates that WinRM service is running with automatic startup on the local computer.

    .EXAMPLE
        $sessions = New-PSSession -ComputerName 'Server01', 'Server02'
        Assert-ServiceState -ServiceName @('WinRM', 'WinHttpAutoProxySvc') -DesiredState 'Running' -PsSession $sessions -Remediate -WaitTimeSeconds 60 -Severity 'WARNING' -ValidatorName 'Prerequisites'
        Remove-PSSession $sessions

        Checks two services on two remote servers via PSSession, attempts to start them if stopped, waits 60 seconds, then verifies.

    .EXAMPLE
        $sessions = New-PSSession -ComputerName 'Node01', 'Node02', 'Node03'
        Assert-ServiceState -ServiceName 'ClusSvc' -DesiredState 'Running' -DesiredStartupType 'Automatic' -PsSession $sessions -GroupResults -Severity 'CRITICAL' -ValidatorName 'Cluster'

        Uses existing PSSessions to validate cluster service on multiple nodes, returning one result per node.

    .EXAMPLE
        $serviceConfig = @{
            'WinRM' = @{ DesiredState = 'Running'; DesiredStartupType = 'Automatic'; WaitTimeSeconds = 60 }
            'Spooler' = @{ DesiredState = 'Stopped'; DesiredStartupType = 'Disabled'; WaitTimeSeconds = 15 }
            'W32Time' = @{ DesiredState = 'Running'; DesiredStartupType = 'Automatic' }
        }
        Assert-ServiceState -ServiceConfiguration $serviceConfig -Remediate -Severity 'WARNING' -ValidatorName 'Services'

        Validates multiple services on the local computer with individual configurations and wait times.

    .EXAMPLE
        Assert-ServiceState -ServiceName 'BITS' -DesiredStartupType 'Manual' -Severity 'INFORMATIONAL' -ValidatorName 'Services' -TestName 'AzStackHci_MyValidator_BITS_Check' -TestTitle 'BITS Configuration Check'

        Validates startup type with custom result object naming.

    .NOTES
        - Requires appropriate permissions on target computers
        - When using PSSession, WinRM must be enabled on target computers
        - Remediation requires administrative privileges
        - Callers are responsible for creating and managing PSSessions for remote execution
        - Error details are captured in the AdditionalData.Detail property of failed results
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'SimpleMode')]
        [string[]]
        $ServiceName,

        [Parameter(Mandatory = $true, ParameterSetName = 'AdvancedMode')]
        [hashtable]
        $ServiceConfiguration,

        [Parameter(ParameterSetName = 'SimpleMode')]
        [ValidateSet('Running', 'Stopped')]
        [string]
        $DesiredState,

        [Parameter(ParameterSetName = 'SimpleMode')]
        [ValidateSet('Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart')]
        [string]
        $DesiredStartupType,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter()]
        [switch]
        $Remediate,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]
        $WaitTimeSeconds = 30,

        [Parameter()]
        [ValidateRange(1, 5)]
        [int]
        $MaxRetries = 1,

        [Parameter(Mandatory = $true)]
        [ValidateSet('CRITICAL', 'WARNING', 'INFORMATIONAL', 'Hidden')]
        [string]
        $Severity,

        [Parameter(Mandatory = $true)]
        [string]
        $ValidatorName,

        [Parameter()]
        [string]
        $TestName,

        [Parameter()]
        [string]
        $TestTitle,

        [Parameter()]
        [string]
        $TestDisplayName,

        [Parameter()]
        [switch]
        $GroupResults
    )

    try
    {
        # Build service configuration list
        $serviceConfigList = @{}

        if ($PSCmdlet.ParameterSetName -eq 'SimpleMode')
        {
            # Validate that at least one desired property is specified
            if (-not $DesiredState -and -not $DesiredStartupType)
            {
                throw "At least one of DesiredState or DesiredStartupType must be specified."
            }

            # All services use same configuration
            foreach ($svcName in $ServiceName)
            {
                $serviceConfigList[$svcName] = @{
                    DesiredState = $DesiredState
                    DesiredStartupType = $DesiredStartupType
                    WaitTimeSeconds = $WaitTimeSeconds
                }
            }
        }
        else
        {
            # Advanced mode - validate and normalize configuration
            foreach ($svcName in $ServiceConfiguration.Keys)
            {
                $config = $ServiceConfiguration[$svcName]

                # Validate that at least one desired property is specified
                if (-not $config.DesiredState -and -not $config.DesiredStartupType)
                {
                    throw "Service '$svcName': At least one of DesiredState or DesiredStartupType must be specified."
                }

                $serviceConfigList[$svcName] = @{
                    DesiredState = $config.DesiredState
                    DesiredStartupType = $config.DesiredStartupType
                    WaitTimeSeconds = if ($config.WaitTimeSeconds) { $config.WaitTimeSeconds } else { $WaitTimeSeconds }
                }
            }
        }

        # Determine execution mode
        if ($PsSession)
        {
            Log-Info "Testing services on computers via PSSession: $($PsSession.ComputerName -join ', ')"
        }
        else
        {
            Log-Info "Testing services on local computer"
        }

        # Script block to execute on each computer
        $scriptBlock = {
            param($ServiceConfigs, $Remediate, $MaxRetries)

            $results = @()
            $computerName = $env:COMPUTERNAME

            foreach ($svcName in $ServiceConfigs.Keys)
            {
                $config = $ServiceConfigs[$svcName]
                $result = @{
                    ServiceName = $svcName
                    ComputerName = $computerName
                    Status = 'SUCCESS'
                    CurrentState = $null
                    CurrentStartupType = $null
                    ErrorMessage = $null
                    Details = @()
                }

                try
                {
                    # Get service
                    $service = Get-Service -Name $svcName -ErrorAction Stop
                    $result.CurrentState = $service.Status.ToString()

                    # Get startup type
                    $wmiService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction Stop
                    $startMode = $wmiService.StartMode
                    if ($startMode -eq 'Auto' -and (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName" -Name 'DelayedAutostart' -ErrorAction SilentlyContinue).DelayedAutostart -eq 1)
                    {
                        $startMode = 'AutomaticDelayedStart'
                    }
                    elseif ($startMode -eq 'Auto')
                    {
                        $startMode = 'Automatic'
                    }
                    $result.CurrentStartupType = $startMode

                    # Check startup type
                    if ($config.DesiredStartupType -and $result.CurrentStartupType -ne $config.DesiredStartupType)
                    {
                        $result.Status = 'FAILURE'
                        $result.Details += "Startup type is '$($result.CurrentStartupType)', expected '$($config.DesiredStartupType)'"

                        if ($Remediate)
                        {
                            try
                            {
                                $setParams = @{
                                    Name = $svcName
                                    StartupType = $config.DesiredStartupType
                                    ErrorAction = 'Stop'
                                }
                                Set-Service @setParams
                                $result.Details += "Attempted to set startup type to '$($config.DesiredStartupType)'"
                            }
                            catch
                            {
                                $result.ErrorMessage = "Failed to set startup type: $($_.Exception.Message)"
                                $result.Details += $result.ErrorMessage
                            }
                        }
                    }
                    elseif ($config.DesiredStartupType)
                    {
                        $result.Details += "Startup type is '$($result.CurrentStartupType)' as expected"
                    }

                    # Check running state
                    if ($config.DesiredState)
                    {
                        if ($result.CurrentState -ne $config.DesiredState)
                        {
                            $result.Status = 'FAILURE'
                            $result.Details += "Service state is '$($result.CurrentState)', expected '$($config.DesiredState)'"

                            if ($Remediate)
                            {
                                try
                                {
                                    if ($config.DesiredState -eq 'Running')
                                    {
                                        Start-Service -Name $svcName -ErrorAction Stop
                                        $result.Details += "Attempted to start service"
                                    }
                                    else
                                    {
                                        Stop-Service -Name $svcName -Force -ErrorAction Stop
                                        $result.Details += "Attempted to stop service"
                                    }
                                }
                                catch
                                {
                                    $result.ErrorMessage = "Failed to change service state: $($_.Exception.Message)"
                                    $result.Details += $result.ErrorMessage
                                }
                            }
                        }
                        else
                        {
                            $result.Details += "Service state is '$($result.CurrentState)' as expected"
                        }
                    }

                    # If remediation was attempted, wait and re-check (with retries)
                    if ($Remediate -and $result.Status -eq 'FAILURE' -and -not $result.ErrorMessage)
                    {
                        $attemptNumber = 1
                        $remediationSuccessful = $false

                        while ($attemptNumber -le $MaxRetries -and -not $remediationSuccessful)
                        {
                            $waitTime = $config.WaitTimeSeconds
                            Start-Sleep -Seconds $waitTime
                            $result.Details += "Waited $waitTime seconds for service stabilization (Attempt $attemptNumber of $MaxRetries)"

                            # Re-check service
                            $service = Get-Service -Name $svcName -ErrorAction Stop
                            $result.CurrentState = $service.Status.ToString()

                            $wmiService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction Stop
                            $startMode = $wmiService.StartMode
                            if ($startMode -eq 'Auto' -and (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName" -Name 'DelayedAutostart' -ErrorAction SilentlyContinue).DelayedAutostart -eq 1)
                            {
                                $startMode = 'AutomaticDelayedStart'
                            }
                            elseif ($startMode -eq 'Auto')
                            {
                                $startMode = 'Automatic'
                            }
                            $result.CurrentStartupType = $startMode

                            # Validate current state
                            $finalStatus = 'SUCCESS'
                            if ($config.DesiredStartupType -and $result.CurrentStartupType -ne $config.DesiredStartupType)
                            {
                                $finalStatus = 'FAILURE'
                            }
                            if ($config.DesiredState -and $result.CurrentState -ne $config.DesiredState)
                            {
                                $finalStatus = 'FAILURE'
                            }

                            if ($finalStatus -eq 'SUCCESS')
                            {
                                $result.Status = 'SUCCESS'
                                $result.Details += "Remediation successful on attempt $attemptNumber of ${MaxRetries}: Service is now in desired state"
                                $remediationSuccessful = $true
                            }
                            else
                            {
                                # Still not in correct state
                                if ($attemptNumber -lt $MaxRetries)
                                {
                                    # Try remediation again
                                    $result.Details += "Attempt $attemptNumber verification: Service still not in desired state, retrying..."

                                    # Retry startup type change if needed
                                    if ($config.DesiredStartupType -and $result.CurrentStartupType -ne $config.DesiredStartupType)
                                    {
                                        try
                                        {
                                            $setParams = @{
                                                Name = $svcName
                                                StartupType = $config.DesiredStartupType
                                                ErrorAction = 'Stop'
                                            }
                                            Set-Service @setParams
                                            $result.Details += "Retry attempt $($attemptNumber + 1): Attempted to set startup type to '$($config.DesiredStartupType)'"
                                        }
                                        catch
                                        {
                                            $result.ErrorMessage = "Failed to set startup type on retry: $($_.Exception.Message)"
                                            $result.Details += $result.ErrorMessage
                                            break
                                        }
                                    }

                                    # Retry service state change if needed
                                    if ($config.DesiredState -and $result.CurrentState -ne $config.DesiredState)
                                    {
                                        try
                                        {
                                            if ($config.DesiredState -eq 'Running')
                                            {
                                                Start-Service -Name $svcName -ErrorAction Stop
                                                $result.Details += "Retry attempt $($attemptNumber + 1): Attempted to start service"
                                            }
                                            else
                                            {
                                                Stop-Service -Name $svcName -Force -ErrorAction Stop
                                                $result.Details += "Retry attempt $($attemptNumber + 1): Attempted to stop service"
                                            }
                                        }
                                        catch
                                        {
                                            $result.ErrorMessage = "Failed to change service state on retry: $($_.Exception.Message)"
                                            $result.Details += $result.ErrorMessage
                                            break
                                        }
                                    }
                                }
                                else
                                {
                                    # Final attempt failed
                                    if ($config.DesiredStartupType -and $result.CurrentStartupType -ne $config.DesiredStartupType)
                                    {
                                        $result.Details += "After ${MaxRetries} attempt(s): Startup type is still '$($result.CurrentStartupType)', expected '$($config.DesiredStartupType)'"
                                    }
                                    if ($config.DesiredState -and $result.CurrentState -ne $config.DesiredState)
                                    {
                                        $result.Details += "After ${MaxRetries} attempt(s): Service state is still '$($result.CurrentState)', expected '$($config.DesiredState)'"
                                    }
                                }

                                $attemptNumber++
                            }
                        }
                    }
                }
                catch
                {
                    $result.Status = 'FAILURE'
                    $result.ErrorMessage = $_.Exception.Message
                    $result.Details += "Error: $($_.Exception.Message)"
                }

                $results += [PSCustomObject]$result
            }

            return $results
        }

        # Execute script block
        $allResults = @()

        if ($PsSession)
        {
            # Remote execution via PSSession - execute in parallel across all sessions
            Log-Info "Checking services on computers via PSSession: $($PsSession.ComputerName -join ', ')"

            try
            {
                # Invoke-Command with multiple sessions executes in parallel
                $serviceResults = Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock -ArgumentList @($serviceConfigList, $Remediate.IsPresent, $MaxRetries) -ErrorAction SilentlyContinue -ErrorVariable remoteErrors
                $allResults += $serviceResults

                # Handle any computers that failed
                if ($remoteErrors)
                {
                    # Determine which computers succeeded
                    $succeededComputers = $serviceResults | Select-Object -ExpandProperty ComputerName -Unique
                    $allComputers = $PsSession | Select-Object -ExpandProperty ComputerName
                    $failedComputers = $allComputers | Where-Object { $_ -notin $succeededComputers }

                    # Create failure results for computers that didn't respond
                    foreach ($computer in $failedComputers)
                    {
                        # Find the error for this computer
                        $errorForComputer = $remoteErrors | Where-Object { $_.OriginInfo.PSComputerName -eq $computer -or $_.TargetObject -eq $computer } | Select-Object -First 1
                        $errorMsg = if ($errorForComputer) { $errorForComputer.Exception.Message } else { "Failed to execute on $computer" }

                        Log-Info "Failed to check services on $computer`: $errorMsg" -Type Error

                        foreach ($svcName in $serviceConfigList.Keys)
                        {
                            $failureResult = [PSCustomObject]@{
                                ServiceName = $svcName
                                ComputerName = $computer
                                Status = 'FAILURE'
                                CurrentState = $null
                                CurrentStartupType = $null
                                ErrorMessage = "Failed to connect or execute: $errorMsg"
                                Details = @("Failed to connect or execute: $errorMsg")
                            }
                            $allResults += $failureResult
                        }
                    }
                }
            }
            catch
            {
                # Complete failure across all sessions (rare)
                $errorMsg = $_.Exception.Message
                Log-Info "Failed to execute Invoke-Command: $errorMsg" -Type Error

                # Create failure results for all computers and services
                foreach ($session in $PsSession)
                {
                    $computer = $session.ComputerName
                    foreach ($svcName in $serviceConfigList.Keys)
                    {
                        $failureResult = [PSCustomObject]@{
                            ServiceName = $svcName
                            ComputerName = $computer
                            Status = 'FAILURE'
                            CurrentState = $null
                            CurrentStartupType = $null
                            ErrorMessage = "Failed to connect or execute: $errorMsg"
                            Details = @("Failed to connect or execute: $errorMsg")
                        }
                        $allResults += $failureResult
                    }
                }
            }
        }
        else
        {
            # Local execution
            try
            {
                Log-Info "Checking services on local computer"
                $serviceResults = & $scriptBlock -ServiceConfigs $serviceConfigList -Remediate $Remediate.IsPresent -MaxRetries $MaxRetries
                $allResults += $serviceResults
            }
            catch
            {
                # Create failure result for all services
                $errorMsg = $_.Exception.Message
                Log-Info "Failed to check services locally: $errorMsg" -Type Error

                foreach ($svcName in $serviceConfigList.Keys)
                {
                    $failureResult = [PSCustomObject]@{
                        ServiceName = $svcName
                        ComputerName = $env:COMPUTERNAME
                        Status = 'FAILURE'
                        CurrentState = $null
                        CurrentStartupType = $null
                        ErrorMessage = "Failed to execute: $errorMsg"
                        Details = @("Failed to execute: $errorMsg")
                    }
                    $allResults += $failureResult
                }
            }
        }

        # Generate result objects
        $resultObjects = @()
        $allServiceNames = $serviceConfigList.Keys

        if ($GroupResults)
        {
            # One result per computer
            $groupedByComputer = $allResults | Group-Object -Property ComputerName

            foreach ($group in $groupedByComputer)
            {
                $computer = $group.Name
                $services = $group.Group
                $overallStatus = if ($services.Status -contains 'FAILURE') { 'FAILURE' } else { 'SUCCESS' }

                $detailLines = @()
                $detailLines += "Services checked: $($allServiceNames -join ', ')"
                foreach ($svc in $services)
                {
                    $detailLines += "[$($svc.ServiceName)]"
                    $detailLines += $svc.Details
                }
                $detail = $detailLines -join "`r`n"

                if ($overallStatus -eq 'FAILURE')
                {
                    Log-Info "Service validation failed on $computer" -Type Warning
                    Log-Info $detail -Type Warning
                }
                else
                {
                    Log-Info "Service validation passed on $computer"
                    Log-Info $detail
                }

                # Apply custom naming or use defaults
                $resultName = if ($TestName)
                {
                    $TestName -replace '\{ValidatorName\}', $ValidatorName -replace '\{ComputerName\}', $computer
                }
                else
                {
                    'AzStackHci_{0}_Test_Services_State' -f $ValidatorName
                }

                $resultTitle = if ($TestTitle)
                {
                    $TestTitle -replace '\{ComputerName\}', $computer
                }
                else
                {
                    'Test Services State'
                }

                $resultDisplayName = if ($TestDisplayName)
                {
                    $TestDisplayName -replace '\{ComputerName\}', $computer
                }
                else
                {
                    'Test Services State'
                }

                $params = @{
                    Name               = $resultName
                    Title              = $resultTitle
                    DisplayName        = $resultDisplayName
                    Severity           = $Severity
                    Description        = 'Validating service state: {0}' -f ($allServiceNames -join ', ')
                    Tags               = @{}
                    Remediation        = Get-DeviceRequirementsUrl
                    TargetResourceID   = "Machine: $computer, Services: $($allServiceNames -join ', ')"
                    TargetResourceName = "Machine: $computer, Services: $($allServiceNames -join ', ')"
                    TargetResourceType = 'Service'
                    Timestamp          = [datetime]::UtcNow
                    Status             = $overallStatus
                    AdditionalData     = @{
                        Source    = $computer
                        Resource  = $allServiceNames -join ', '
                        Detail    = $detail
                        Status    = $overallStatus
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $resultObjects += New-AzStackHciResultObject @params
            }
        }
        else
        {
            # One result per service per computer
            foreach ($svcResult in $allResults)
            {
                $computer = $svcResult.ComputerName
                $svcName = $svcResult.ServiceName
                $detail = $svcResult.Details -join "`r`n"

                if ($svcResult.Status -eq 'FAILURE')
                {
                    Log-Info "Service $svcName validation failed on $computer" -Type Warning
                    Log-Info $detail -Type Warning
                }
                else
                {
                    Log-Info "Service $svcName validation passed on $computer"
                    Log-Info $detail
                }

                $resourceValue = "State: $($svcResult.CurrentState), StartupType: $($svcResult.CurrentStartupType)"

                # Apply custom naming or use defaults
                $resultName = if ($TestName)
                {
                    $TestName -replace '\{ValidatorName\}', $ValidatorName -replace '\{ServiceName\}', $svcName -replace '\{ComputerName\}', $computer
                }
                else
                {
                    'AzStackHci_{0}_Test_Service_{1}_State' -f $ValidatorName, $svcName
                }

                $resultTitle = if ($TestTitle)
                {
                    $TestTitle -replace '\{ServiceName\}', $svcName -replace '\{ComputerName\}', $computer
                }
                else
                {
                    'Test Service {0} State' -f $svcName
                }

                $resultDisplayName = if ($TestDisplayName)
                {
                    $TestDisplayName -replace '\{ServiceName\}', $svcName -replace '\{ComputerName\}', $computer
                }
                else
                {
                    'Test Service {0} State' -f $svcName
                }

                $params = @{
                    Name               = $resultName
                    Title              = $resultTitle
                    DisplayName        = $resultDisplayName
                    Severity           = $Severity
                    Description        = 'Validating service {0} state' -f $svcName
                    Tags               = @{}
                    Remediation        = Get-DeviceRequirementsUrl
                    TargetResourceID   = "Machine: $computer, Service: $svcName"
                    TargetResourceName = "Machine: $computer, Service: $svcName"
                    TargetResourceType = 'Service'
                    Timestamp          = [datetime]::UtcNow
                    Status             = $svcResult.Status
                    AdditionalData     = @{
                        Source    = $computer
                        Resource  = $resourceValue
                        Detail    = $detail
                        Status    = $svcResult.Status
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $resultObjects += New-AzStackHciResultObject @params
            }
        }

        return $resultObjects
    }
    catch
    {
        Log-Info "Error in Assert-ServiceState: $($_.Exception.Message)" -Type Error
        throw $_
    }
}

function Get-DeviceRequirementsUrl
{
    if ($ENV:EnvChkrId -like '*Small*')
    {
        return 'https://aka.ms/azurelocallowcapacityrequirements'
    }
    else
    {
        return 'https://aka.ms/hci-envch'
    }
}

Export-ModuleMember -Function Assert-ServiceState
Export-ModuleMember -Function Get-DeviceRequirementsUrl

# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB7NGTFoRtASY7N
# fNnMhWTz48ww54agXnyKTJxZwUtWFKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIHwEgB4xwZJTlXyo3Umi0elyjEdqJVwMe2xpW1rKmCpMMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAstZEiw+2kpQpylVVDitm
# F9UGOUWW2nuOApbWA4X3WoIROM9xo2iD1gJiuVYXYr17DWgLsRElawbk5gby3ay+
# qKMy0VGfACq0tN4ednUXOs6TArT+Za/JBdQ1kVyxLxZo57sTnEQaAQCGpNCw7Acg
# YinKdRBJJ2Vub+tDMYHiSMakqVFFcC0e5X8rXtad+2qEnWIrZHWNkLDxmkOGgAvP
# emS/ZAu+rMlNjbdrA3im85oE49w3M1CUiO5MLEgveUAA92fGGzttZWCyeiBlLxDM
# H0J2gOtrmnVBKy1hU7rFE22+/AVfQVHNxvaK+kA8vvfR9cM4c5dj97cDV+4eBCsf
# d6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDguUdeH7rjfbyRBFtU
# r65tx1VQao2Vgvvg/xij5t+miwIGaexvE19PGBMyMDI2MDUwMzE0MzExMS40MDZa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACFRgD04EHJnxTAAEAAAIVMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyMFoXDTI2MTExMzE4
# NDgyMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjY1MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAw3HV3hVxL0lEYPV03XeNKZ517VIbgexhlDPdpXwDS0BYtxPw
# i4XYpZR1ld0u6cr2Xjuugdg50DUx5WHL0QhY2d9vkJSk02rE/75hcKt91m2Ih287
# QRxRMmFu3BF6466k8qp5uXtfe6uciq49YaS8p+dzv3uTarD4hQ8UT7La95pOJiRq
# xxd0qOGLECvHLEXPXioNSx9pyhzhm6lt7ezLxJeFVYtxShkavPoZN0dOCiYeh4Kg
# oKoyagzMuSiLCiMUW4Ue4Qsm658FJNGTNh7V5qXYVA6k5xjw5WeWdKOz0i9A5jBc
# bY9fVOo/cA8i1bytzcDTxb3nctcly8/OYeNstkab/Isq3Cxe1vq96fIHE1+ZGmJj
# ka1sodwqPycVp/2tb+BjulPL5D6rgUXTPF84U82RLKHV57bB8fHRpgnjcWBQuXPg
# VeSXpERWimt0NF2lCOLzqgrvS/vYqde5Ln9YlKKhAZ/xDE0TLIIr6+I/2JTtXP34
# nfjTENVqMBISWcakIxAwGb3RB5yHCxynIFNVLcfKAsEdC5U2em0fAvmVv0sonqnv
# 17cuaYi2eCLWhoK1Ic85Dw7s/lhcXrBpY4n/Rl5l3wHzs4vOIhu87DIy5QUaEupE
# syY0NWqgI4BWl6v1wgse+l8DWFeUXofhUuCgVTuTHN3K8idoMbn8Q3edUIECAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBSJIXfxcqAwFqGj9jdwQtdSqadj1zAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAd42HtV+kGbvxzLBTC5O7vkCIBPy/BwpjCzeL53hA
# iEOebp+VdNnwm9GVCfYq3KMfrj4UvKQTUAaS5Zkwe1gvZ3ljSSnCOyS5OwNu9dpg
# 3ww+QW2eOcSLkyVAWFrLn6Iig3TC/zWMvVhqXtdFhG2KJ1lSbN222csY3E3/BrGl
# uAlvET9gmxVyyxNy59/7JF5zIGcJibydxs94JL1BtPgXJOfZzQ+/3iTc6eDtmaWT
# 6DKdnJocp8wkXKWPIsBEfkD6k1Qitwvt0mHrORah75SjecOKt4oWayVLkPTho12e
# 0ongEg1cje5fxSZGthrMrWKvI4R7HEC7k8maH9ePA3ViH0CVSSOefaPTGMzIhHCo
# 5p3jG5SMcyO3eA9uEaYQJITJlLG3BwwGmypY7C/8/nj1SOhgx1HgJ0ywOJL9xfP4
# AOcWmCfbsqgGbCaC7WH5sINdzfMar8V7YNFqkbCGUKhc8GpIyE+MKnyVn33jsuaG
# AlNRg7dVRUSoYLJxvUsw9GOwyBpBwbE9sqOLm+HsO00oF23PMio7WFXcFTZAjp3u
# jihBAfLrXICgGOHPdkZ042u1LZqOcnlr3XzvgMe+mPPyasW8f0rtzJj3V5E/EKiy
# QlPxj9Mfq2x9himnlXWGZCVPeEBROrNbDYBfazTyLNCOTsRtksOSV3FBtPnpQtLN
# 754wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAj6eTejbuYE1Ifjbfrt6tXevCUSCggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2heQUwIhgPMjAyNjA1MDMw
# NzM0MjlaGA8yMDI2MDUwNDA3MzQyOVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aF5BQIBADAKAgEAAgIJowIB/zAHAgEAAgISdDAKAgUA7aLKhQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCrOcIVaAkw/PrB8wJN9p73l7REfyz7iPnOfU9C
# 8PEXMkvj+YPwV0roGlbTSNv0bidbON1MUk8WgjEFBBwSp/0k65COmh/ppW11Gl2S
# rfhOpprUrJmzOl1auKqxVTdbRE+CED52BnszfZrqmk4Mj238iP0VO6oxW9t4pfB/
# hVeTaf2igpMoTHdOoFV+wKOeDDk1XRR2+3GLmthZzSVSfvEqo+fD9Kpd8tmHsuW8
# ADnqYRlGxCwhDhsR5ElK105kpOGIj9VDNbwrvT9I6RLNj4Q/Dnhg8zRB5VtI807q
# MWC8EKhsvMP1XhuFuV78ZuFyXeV+XfS4jx/WoAJhJMAFiUNkMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIVGAPTgQcmfFMA
# AQAAAhUwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgipGl8Kd6OdmF5sCgakJ3BTZ+XJVmmeB7vGXF
# H57sIHQwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBwEPR2PDrTFLcrtQsK
# rUi7oz5JNRCF/KRHMihSNe7sijCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACFRgD04EHJnxTAAEAAAIVMCIEIBqc8pIbgkUBl+m5tNCz
# IFlR5RUBapAjgKe/JVm88ntNMA0GCSqGSIb3DQEBCwUABIICAH/PpVrFQkhF4hIw
# Onpk00pZ8+J9PgoKeGx6DKapRsu4IlYq3YnoOfed5eW3Qt//v/onnCRL9lmq3ror
# 00Vigoy+IDivPdmRhBK97ZiIiOYxEURC9RUOp2LY0MKgM8IrLkn4HGu/NxTinbuu
# vqn9NGLGOu9HSBgmRL9q9RH7y99/IEKVvqYXMt2lttzNpxherbUUpws58TcBdlvR
# KFyTfN+iHXsWg1Ix/1h5nplLqAHL+hwbz7H1OXXOv3gEgjx91Afi5niiS2vQiMrR
# Oi/4vBPoJBpvPqNsc8qWZWNNExHRBHRxTU8qf6O6XlTIT/vN783ZBZW9u8mxLIK7
# 0mTBRI/pBCHfY2Hp4pfluKPWTWp4nOVsTBgnaVlOXgSXy0S4FfqkevFlxzGsWjJy
# ea6OMjURym34cWLgTUYSSIZgHeneomF9T7+hIdOTOiYxn/nXhUkZsi4M7NFr0IYn
# 3lel/7cf6WQBRBWSlU17OUrIPoVa8Akc0STGjvknxEIt8TcRBhICIG6WeX9saB9W
# Ng38QK80176Xt49oWMukUF60CGJP/J6L2quk8Hoq/0yjI0cTKAQd+l8DMj2BAWCv
# spssQCXlY4m7/gj+NXLyM4KjX5HCehBM8XUtzzoVwYnMVx/9lKhMhE3VXE0lewH/
# 3Jcveck9ZqYQ+eKWZ32WV+jS2q1Q
# SIG # End signature block
