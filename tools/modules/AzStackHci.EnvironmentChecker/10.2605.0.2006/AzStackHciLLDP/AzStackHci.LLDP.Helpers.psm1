Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.LLDP.Strings.psd1

# In-memory cache to avoid redundant JSON file reads between tests
$script:LLDPDataCache = @{}

function Clear-LLDPDataCache {
    if ($script:LLDPDataCache) { $script:LLDPDataCache.Clear() }
}

function New-PsSessionWithRetriesInternal {
     <#
    .SYNOPSIS
    Establishes a PowerShell session to a remote node with built-in retry logic.
    .DESCRIPTION
    This internal function attempts to create a new PSSession to a specified node. It will retry the connection multiple times if the initial attempt fails. It also verifies that the established session has administrator privileges on the target node.
    .PARAMETER Node
    The hostname or IP address of the target node to connect to.
    .PARAMETER Credential
    The credentials used to authenticate the PSSession.
    .PARAMETER Retries
    The maximum number of times to retry the connection. Defaults to 60.
    .PARAMETER WaitSeconds
    The number of seconds to wait between retry attempts. Defaults to 10.
    .EXAMPLE
    $session = New-PsSessionWithRetriesInternal -Node "Node1" -Credential $cred -Retries 30
    #>
    param
    (
        [System.String] $Node,
        [PSCredential] $Credential = $null,
        [System.Int16] $Retries = 60,
        [System.Int16] $WaitSeconds = 10
    )

    for ($i=1; $i -le $Retries; $i++)
    {
        try
        {
            if ($Credential) {
                Log-Info "Creating PsSession ($i/$retries) to $Node as $($Credential.UserName)..."
                $psSessionCreated = Microsoft.PowerShell.Core\New-PSSession -ComputerName $Node -Credential $Credential -ErrorAction Stop
            } else {
                Log-Info "Creating PsSession ($i/$retries) to $Node with implicit credential..."
                $psSessionCreated = Microsoft.PowerShell.Core\New-PSSession -ComputerName $Node -ErrorAction Stop
            }
            $computerNameFromSession = Microsoft.PowerShell.Core\Invoke-Command -Session $psSessionCreated -ScriptBlock { $ENV:COMPUTERNAME } -ErrorAction Stop
            $isAdminSession = Microsoft.PowerShell.Core\Invoke-Command -Session $psSessionCreated -ScriptBlock {
                ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
            } -ErrorAction Stop

            if (-not $isAdminSession)
            {
                throw ("PsSession was successful but user: {0} is not an administrator on computer {1} " -f $psSessionCreated.Runspace.ConnectionInfo.Credential.Username, $computerName)
            }

            break
        }
        catch
        {
            Log-Info "Creating PsSession ($i/$Retries) to $Node failed: $($_.exception.message)"
            $errMsg = $_.tostring()
            Start-Sleep -Seconds $WaitSeconds
        }
    }

    if ($psSessionCreated -and $computerNameFromSession -and $isAdminSession)
    {
        Log-Info ("PsSession to {0} created after {1} retries. (Remote machine name: {2})" -f $Node, ("$i/$retries"), $computerNameFromSession)
        return $psSessionCreated
    }
    else
    {
        throw "Unable to create a valid session to $Node`: $errMsg"
    }
}

function EnsureTestSessionOpen {
    <#
    .SYNOPSIS
    Ensures PSSessions are open and valid, recreating them if necessary.
    .DESCRIPTION
    This function checks existing PSSessions and only recreates those that are not in the 'Opened' state.
    Sessions are created in parallel batches using New-PSSession with an array of computer names,
    grouped by credential. Admin privileges are validated in parallel via Invoke-Command.
    .PARAMETER PSSessions
    An array of PSSession objects to be refreshed.
    .EXAMPLE
    $refreshedSessions = EnsureTestSessionOpen -PSSessions $existingSessions
    #>
    param
    (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSessions
    )

    $validSessions = @()
    $nodesToRecreate = @()
    $seenNodes = @{}

    # Step 1: Deduplicate and check existing sessions — keep one open session per node
    foreach ($testSession in $PSSessions)
    {
        $nodeName = $testSession.ComputerName
        if ($seenNodes.ContainsKey($nodeName)) {
            # Duplicate session for same node — remove it
            Log-Info "[EnsureTestSessionOpen] Removing duplicate session to $nodeName"
            Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
            continue
        }
        $seenNodes[$nodeName] = $true

        if ($testSession.State -eq 'Opened') {
            Log-Info "[EnsureTestSessionOpen] Session to $nodeName is already open, reusing."
            $validSessions += $testSession
        } else {
            Log-Info "[EnsureTestSessionOpen] Session to $nodeName is $($testSession.State), will recreate."
            $nodesToRecreate += [PSCustomObject]@{
                ComputerName = $nodeName
                Credential   = $testSession.Runspace.ConnectionInfo.Credential
            }
            Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
        }
    }

    Log-Info "[EnsureTestSessionOpen] Unique nodes: $($seenNodes.Count), Open: $($validSessions.Count), Need recreation: $($nodesToRecreate.Count)"

    if ($nodesToRecreate.Count -eq 0) {
        Log-Info "[EnsureTestSessionOpen] All $($validSessions.Count) sessions are already open."
        return $validSessions
    }

    Log-Info "[EnsureTestSessionOpen] Recreating $($nodesToRecreate.Count) sessions in parallel..."

    # Step 2: Group nodes by credential for batch creation
    $credentialGroups = @{}
    foreach ($node in $nodesToRecreate) {
        $credKey = if ($node.Credential) { $node.Credential.UserName } else { '__implicit__' }
        if (-not $credentialGroups.ContainsKey($credKey)) {
            $credentialGroups[$credKey] = @{
                Credential = $node.Credential
                Nodes = @()
            }
        }
        $credentialGroups[$credKey].Nodes += $node.ComputerName
    }

    # Step 3: Create sessions in parallel per credential group with batch retry
    $maxRetries = 5
    $waitSeconds = 5
    foreach ($group in $credentialGroups.Values) {
        $remaining = @($group.Nodes)
        $credential = $group.Credential

        for ($attempt = 1; $attempt -le $maxRetries -and $remaining.Count -gt 0; $attempt++) {
            Log-Info "[EnsureTestSessionOpen] Batch session creation attempt $attempt/$maxRetries for $($remaining.Count) nodes..."
            try {
                $newSessions = if ($credential) {
                    Microsoft.PowerShell.Core\New-PSSession -ComputerName $remaining -Credential $credential -ErrorAction SilentlyContinue -ErrorVariable sessionErrors
                } else {
                    Microsoft.PowerShell.Core\New-PSSession -ComputerName $remaining -ErrorAction SilentlyContinue -ErrorVariable sessionErrors
                }

                if ($newSessions) {
                    foreach ($s in @($newSessions)) {
                        $validSessions += $s
                    }
                    $succeededNames = @($newSessions) | ForEach-Object { $_.ComputerName }
                    $remaining = @($remaining | Where-Object { $_ -notin $succeededNames })
                }

                if ($remaining.Count -eq 0) { break }
            }
            catch {
                Log-Info "[EnsureTestSessionOpen] Batch creation attempt $attempt failed: $_"
            }

            if ($remaining.Count -gt 0 -and $attempt -lt $maxRetries) {
                Log-Info "[EnsureTestSessionOpen] $($remaining.Count) nodes still pending. Waiting $waitSeconds seconds..."
                Start-Sleep -Seconds $waitSeconds
            }
        }

        if ($remaining.Count -gt 0) {
            Log-Info "[EnsureTestSessionOpen] WARNING: Failed to create sessions for nodes: $($remaining -join ', ') after $maxRetries attempts."
        }
    }

    # Step 4: Validate admin privileges in parallel on all new sessions
    if ($validSessions.Count -gt 0) {
        $newSessionsOnly = $validSessions | Where-Object { $_.Id -notin ($PSSessions | Where-Object { $_.State -eq 'Opened' } | ForEach-Object { $_.Id }) }
        if ($newSessionsOnly) {
            Log-Info "[EnsureTestSessionOpen] Validating admin privileges on $(@($newSessionsOnly).Count) new sessions..."
            try {
                $adminResults = Microsoft.PowerShell.Core\Invoke-Command -Session @($newSessionsOnly) -ScriptBlock {
                    [PSCustomObject]@{
                        ComputerName = $env:COMPUTERNAME
                        IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')
                    }
                } -ThrottleLimit 128 -ErrorAction SilentlyContinue

                foreach ($result in @($adminResults)) {
                    if (-not $result.IsAdmin) {
                        Log-Info "[EnsureTestSessionOpen] WARNING: Session to $($result.ComputerName) does not have admin privileges."
                    }
                }
            }
            catch {
                Log-Info "[EnsureTestSessionOpen] Admin validation failed: $_"
            }
        }
    }

    # Step 5: Deduplicate by actual remote hostname (catches sessions via different IPs to same node)
    if ($validSessions.Count -gt 1) {
        try {
            $remoteHostnames = Microsoft.PowerShell.Core\Invoke-Command -Session $validSessions -ScriptBlock { $env:COMPUTERNAME } -ThrottleLimit 128 -ErrorAction Stop
            $seenRemoteHosts = @{}
            $deduplicatedSessions = @()

            foreach ($session in $validSessions) {
                $remoteHost = ($remoteHostnames | Where-Object { $_.PSComputerName -eq $session.ComputerName }) | Select-Object -First 1
                $remoteHostName = if ($remoteHost) { [string]$remoteHost } else { $session.ComputerName }

                if ($seenRemoteHosts.ContainsKey($remoteHostName)) {
                    Log-Info "[EnsureTestSessionOpen] Removing duplicate session to $($session.ComputerName) (same remote host: $remoteHostName)"
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                } else {
                    $seenRemoteHosts[$remoteHostName] = $true
                    $deduplicatedSessions += $session
                }
            }

            if ($deduplicatedSessions.Count -lt $validSessions.Count) {
                Log-Info "[EnsureTestSessionOpen] Removed $($validSessions.Count - $deduplicatedSessions.Count) duplicate sessions (same remote hostname via different connection targets)"
                $validSessions = $deduplicatedSessions
            }
        }
        catch {
            Log-Info "[EnsureTestSessionOpen] Remote hostname dedup check failed (non-fatal): $_"
        }
    }

    Log-Info "[EnsureTestSessionOpen] Total sessions ready: $($validSessions.Count)"
    return $validSessions
}

function Enable-NetLldpAgentOnAllHosts {
    <#
    .SYNOPSIS
    Enables the NetLldpAgent on all physical ethernet adapters across all target hosts.
    .DESCRIPTION
    Connects to each host via its PSSession, finds all 'Up' physical ethernet adapters, and enables the NetLldpAgent on them. This is a prerequisite for gathering LLDP data. It gracefully handles cases where the agent is already enabled or the module is not present.
    .PARAMETER PSSessions
    An array of PSSession objects for the target hosts.
    .EXAMPLE
    $results = Enable-NetLldpAgentOnAllHosts -PSSessions $allNodeSessions
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSessions
    )

    $enableResults = @()

    Log-Info "Enabling NetLldpAgent on all ethernet adapters for $($PSSessions.Count) hosts in parallel..."

    $scriptBlock = {
        $hostName = $env:COMPUTERNAME
        $results = @{
            HostName = $hostName
            Success = $true
            Message = "Successfully ensured NetLldpAgent is active on host $hostName"
            AdapterResults = @()
            AnyAdapterNewlyEnabled = $false
        }

        if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
            $results.Success = $false
            $results.Message = "NetLldpAgent module is not installed on $hostName"
            return $results
        }

        try {
            Import-Module NetLldpAgent -ErrorAction Stop
        }
        catch {
            $results.Success = $false
            $results.Message = "Failed to import NetLldpAgent module on '$hostName': $_"
            return $results
        }

        $physicalAdapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' }

        if (-not $physicalAdapters) {
            $results.Success = $false
            $results.Message = "No physical ethernet adapters found in 'Up' state on $hostName"
            return $results
        }

        foreach ($adapter in $physicalAdapters) {
            $adapterResult = @{
                AdapterName = $adapter.Name
                Success = $true
                Message = ""
                NewlyEnabled = $false
            }

            try {
                # Check if LLDP agent already has valid neighbor data before enabling.
                # Enable-NetLldpAgent resets the LLDP state even when already active,
                # clearing the neighbor table and requiring fresh LLDP frames from switches.
                # Skipping Enable when data exists preserves the existing neighbor table.
                $existingAgent = $null
                $hasValidNeighbor = $false
                try {
                    $existingAgent = Get-NetLldpAgent -NetAdapterName $adapter.Name -ErrorAction SilentlyContinue |
                        Where-Object { $_.Scope -eq 'NearestBridge' }
                }
                catch {
                    # Get-NetLldpAgent failed - agent likely not enabled; fall through to enable
                }

                if ($existingAgent -and $existingAgent.Neighbor -and
                    $existingAgent.Neighbor.Tlvs -and @($existingAgent.Neighbor.Tlvs).Count -gt 0) {
                    $hasValidNeighbor = $true
                }

                if ($hasValidNeighbor) {
                    $adapterResult.Message = "LLDP agent already active with neighbor data on adapter: $($adapter.Name)"
                    $adapterResult.NewlyEnabled = $false
                }
                else {
                    Enable-NetLldpAgent -NetAdapterName $adapter.Name -ErrorAction Stop
                    $adapterResult.Message = "Successfully enabled NetLldpAgent on adapter: $($adapter.Name)"
                    $adapterResult.NewlyEnabled = $true
                    $results.AnyAdapterNewlyEnabled = $true
                }
            }
            catch {
                if ($_.Exception.Message -like "*already enabled*") {
                    $adapterResult.Message = "NetLldpAgent already enabled on adapter: $($adapter.Name)"
                    $adapterResult.NewlyEnabled = $true
                    $results.AnyAdapterNewlyEnabled = $true
                }
                else {
                    $adapterResult.Success = $false
                    $adapterResult.Message = "Failed to enable NetLldpAgent on adapter $($adapter.Name): $_"
                    $results.Success = $false
                }
            }

            $results.AdapterResults += $adapterResult
        }

        return $results
    }

    try {
        $parallelResults = Invoke-Command -Session $PSSessions -ScriptBlock $scriptBlock -ThrottleLimit 128 -ErrorAction Stop
        # Normalize to array (single result may not be array)
        if ($parallelResults) {
            foreach ($result in @($parallelResults)) {
                $enableResults += $result
                foreach ($adapterResult in $result.AdapterResults) {
                    Log-Info "  [$($result.HostName)] $($adapterResult.Message)"
                }
            }
        }
    }
    catch {
        Log-Info "Parallel Invoke-Command failed: $_. Falling back to individual session calls."
        foreach ($session in $PSSessions) {
            try {
                $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ErrorAction Stop
                $enableResults += $result
                foreach ($adapterResult in $result.AdapterResults) {
                    Log-Info "  [$($result.HostName)] $($adapterResult.Message)"
                }
            }
            catch {
                Log-Info "Failed to enable NetLldpAgent on host $($session.ComputerName): $_"
                $enableResults += @{
                    HostName = $session.ComputerName
                    Success = $false
                    Message = "Failed to connect to host: $_"
                    AdapterResults = @()
                }
            }
        }
    }

    $successCount = ($enableResults | Where-Object { $_.Success }).Count
    $totalCount = $enableResults.Count

    if ($successCount -eq $totalCount) {
        Log-Info "Successfully enabled NetLldpAgent on all $totalCount hosts"
    }
    else {
        Log-Info "NetLldpAgent enabled on $successCount out of $totalCount hosts"
    }

    return $enableResults
}

function GetLLDPNbrTLVs {
    <#
    .SYNOPSIS
    Retrieves LLDP neighbor TLVs (Type-Length-Value) from a local host.
    .DESCRIPTION
    This function scans all 'Up' physical ethernet adapters on the local machine where it's executed. It retrieves the raw LLDP TLV data from the nearest bridge neighbor (typically a ToR switch) and also collects local adapter details. Includes retry logic to wait for LLDP information to be populated.
    .PARAMETER ComputerName
    The name of the computer where the check is being performed. Used for logging and reporting.
    .EXAMPLE
    $result = GetLLDPNbrTLVs -ComputerName "Node1"
    # $result.CheckResult  - Pass/Fail status and message
    # $result.NbrLLDPTLVs  - Hashtable of adapter-name -> TLV arrays
    # $result.HostAdapter   - Hashtable of adapter-name -> local adapter details
    #>
    [CmdletBinding()]
    param (
        [string] $ComputerName
    )

    # When called via parallel Invoke-Command, ComputerName may be empty — use local hostname
    if ([string]::IsNullOrEmpty($ComputerName)) {
        $ComputerName = $env:COMPUTERNAME
    }

    $retVal = [PSCustomObject]@{
        Pass    = $true
        Message = "Check LLDP neighbor TLVs on Host $ComputerName"
    }

    $NbrLLDPTLVs = @{}
    $HostAdapter = @{}

    try {
        if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
            $retVal.Pass = $false
            $retVal.Message = $lnTxt.NoNetLldpAgentModule -f $ComputerName
            return [PSCustomObject]@{ CheckResult = $retVal; NbrLLDPTLVs = $NbrLLDPTLVs; HostAdapter = $HostAdapter }
        }

        try {
            Import-Module NetLldpAgent -ErrorAction Stop
        }
        catch {
            $retVal.Pass = $false
            $retVal.Message += "`nFailed to import NetLldpAgent module: $_"
            return [PSCustomObject]@{ CheckResult = $retVal; NbrLLDPTLVs = $NbrLLDPTLVs; HostAdapter = $HostAdapter }
        }

        $adapterList = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' }

        if (-not $adapterList) {
            $retVal.Pass = $false
            $retVal.Message += "`nNo physical ethernet adapters found in 'Up' state on $ComputerName"
            return [PSCustomObject]@{ CheckResult = $retVal; NbrLLDPTLVs = $NbrLLDPTLVs; HostAdapter = $HostAdapter }
        }

        Write-Verbose "Processing $($adapterList.Count) physical ethernet adapters on $ComputerName : $($adapterList.Name -join ', ')"

        $processedAdapters = 0
        $failedAdapters = @()

        foreach ($Adapter in $adapterList) {
            try {
                $NbrLLDPObj = $null
                $retryCount = 0
                $maxRetries = 2

                while ($retryCount -lt $maxRetries -and -not $NbrLLDPObj) {
                    Write-Verbose "[$ComputerName/$($Adapter.Name)] Getting LLDP Agent, attempt $($retryCount + 1)/$maxRetries"
                    $lldpAgent = Get-NetLldpAgent -NetAdapterName $Adapter.Name -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq 'NearestBridge' }

                    if ($lldpAgent -and $lldpAgent.Neighbor) {
                        $NbrLLDPObj = $lldpAgent.Neighbor
                        Write-Verbose "[$ComputerName/$($Adapter.Name)] LLDP neighbor found!"
                        break
                    }

                    if ($retryCount -lt ($maxRetries - 1)) {
                        Write-Verbose "[$ComputerName/$($Adapter.Name)] Neighbor not found. Waiting 5 seconds..."
                        Start-Sleep -Seconds 5
                    }
                    $retryCount++
                }

                $HostAdapterObj = Get-NetAdapter -Name $Adapter.Name -ErrorAction SilentlyContinue |
                    Select-Object Name, InterfaceDescription, DriverInformation, Status, MacAddress, LinkSpeed

                if ($null -eq $NbrLLDPObj -or $null -eq $NbrLLDPObj.Tlvs) {
                    $NbrLLDPTLVs[$Adapter.Name] = @()
                    Write-Verbose "No LLDP neighbor found on adapter $($Adapter.Name) after all retries"
                } else {
                    $NbrLLDPTLVs[$Adapter.Name] = $NbrLLDPObj.Tlvs
                    $processedAdapters++
                    $standardTlvCount = ($NbrLLDPObj.Tlvs | Where-Object { $_.TLVType -ne 127 }).Count
                    $orgTlvCount = ($NbrLLDPObj.Tlvs | Where-Object { $_.TLVType -eq 127 }).Count
                    Write-Verbose "LLDP neighbor found on adapter $($Adapter.Name): $standardTlvCount standard TLVs, $orgTlvCount organizational TLVs"
                }

                if ($null -ne $HostAdapterObj) {
                    $HostAdapter[$Adapter.Name] = $HostAdapterObj
                }
            }
            catch {
                Write-Verbose "Error processing adapter $($Adapter.Name): $_"
                $failedAdapters += $Adapter.Name
            }
        }

        if ($processedAdapters -eq 0 -and $NbrLLDPTLVs.Count -gt 0) {
            $retVal.Pass = $true
            $retVal.Message += "`nWarning: No LLDP neighbors found on any ethernet adapter on $ComputerName. Check if LLDP is enabled on connected switches."
        }
        elseif ($failedAdapters.Count -gt 0) {
            $retVal.Message += "`nWarning: Failed to process ethernet adapters: $($failedAdapters -join ', ')"
        }

    }
    catch {
        $retVal.Pass = $false
        $retVal.Message += "`nUnexpected error: $_"
    }

    return [PSCustomObject]@{ CheckResult = $retVal; NbrLLDPTLVs = $NbrLLDPTLVs; HostAdapter = $HostAdapter }
}

function Test-LLDPNbrTlvs {
    <#
    .SYNOPSIS
    Tests for the existence of LLDP neighbors on all hosts and saves the raw data.
    .DESCRIPTION
    This orchestrator function ensures sessions are active, enables the LLDP agent on all hosts, waits for discovery, and then invokes GetLLDPNbrTLVs on each host. The raw TLV and local adapter data is saved to JSON files in the specified output path for later analysis.
    .PARAMETER PSSession
    An array of PSSession objects for the target hosts.
    .PARAMETER OutputPath
    The directory path where the resulting LLDP JSON files should be saved.
    .EXAMPLE
    Test-LLDPNbrTlvs -PSSession $allNodeSessions -OutputPath "C:\Temp\LLDP_Logs"
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        [string] $OutputPath
    )
    try {
        # NetLldpAgent availability is checked on each remote node inside Enable-NetLldpAgentOnAllHosts.
        # Removed local Get-Module -ListAvailable check here — it scans all module paths and can take 30-60 seconds.

        [System.Management.Automation.Runspaces.PSSession[]] $allNodeSessions = EnsureTestSessionOpen -PSSessions $PSSession

        Log-Info "Enabling NetLldpAgent on all physical adapters across all hosts..."
        $enableResults = Enable-NetLldpAgentOnAllHosts -PSSessions $allNodeSessions

        # Check if any host failed to enable NetLldpAgent
        $failedHosts = $enableResults | Where-Object { -not $_.Success }
        $successfulHosts = $enableResults | Where-Object { $_.Success }

        if ($failedHosts.Count -eq $enableResults.Count) {
            # All hosts failed
            Log-Info "NetLldpAgent could not be enabled on any host. Skipping all LLDP tests."
            $skipResult = @{
                Name               = 'AzStackHci_LLDP_Test_Neighbor_Existance'
                Title              = 'Validate Host LLDP Neighbor Existence'
                DisplayName        = 'Validate Host LLDP Neighbor Existence'
                Severity           = 'INFORMATIONAL'
                Description        = 'NetLldpAgent enabling failed. This indicates either: (1) Data-Center-Bridging Windows feature is not installed, (2) Network adapters are not in UP state due to cable disconnection or switch port issues, or (3) Network adapters do not support LLDP protocol. Physical switch topology cannot be discovered.'
                Tags               = @{}
                Remediation        = 'Verify: (1) Install-WindowsFeature Data-Center-Bridging on all nodes, (2) Check physical network cables are connected and switch ports are enabled, (3) Confirm network adapters support LLDP (most modern NICs do). Check Event Viewer for adapter-specific errors.'
                TargetResourceID   = 'ValidateLLDPNeighborExistence'
                TargetResourceName = 'ValidateLLDPNeighborExistence'
                TargetResourceType = 'ValidateLLDPNeighborExistence'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = 'AllHosts'
                    Resource  = 'ValidateLLDPNeighborExistence'
                    Detail    = "NetLldpAgent could not be enabled on any host. Failed hosts: $($failedHosts.HostName -join ', ')"
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            return @(New-AzStackHciResultObject @skipResult)
        }

        if ($failedHosts.Count -gt 0) {
            # Some hosts failed
            Log-Info "Warning: NetLldpAgent could not be enabled on some hosts: $($failedHosts.HostName -join ', '). Continuing with available hosts..."
        }

        # Only wait 30 seconds if any adapter was actually (re-)enabled.
        # If all adapters already had valid LLDP neighbor data, the Enable call was
        # skipped to preserve existing data, so no wait is needed.
        $anyNewlyEnabled = $false
        foreach ($result in @($enableResults)) {
            if ($result.AnyAdapterNewlyEnabled) {
                $anyNewlyEnabled = $true
                break
            }
        }

        if ($anyNewlyEnabled) {
            Log-Info "Waiting 30 seconds for LLDP discovery to complete..."
            Start-Sleep -Seconds 30
        } else {
            Log-Info "All adapters already had valid LLDP neighbor data. Skipping 30-second discovery wait."
        }

        $LLDPTestResults = @()
        $LLDPNbrTestStatus = 'SUCCESS'
        $LLDPNbriDetailMsg = "Check LLDP Neighbor TLVs on Hosts"

        # Host-level retry loop: re-collect from hosts that got zero valid LLDP TLVs.
        # LLDP has a 30-second standard transmit interval, so switches may not have sent
        # frames to all ports within a single collection window.
        $hostsWithLLDPData = @{}
        $maxCollectionAttempts = 2

        for ($attempt = 1; $attempt -le $maxCollectionAttempts; $attempt++) {
            if ($attempt -eq 1) {
                $sessionsToCollect = $allNodeSessions
            } else {
                $sessionsToCollect = @($allNodeSessions | Where-Object { -not $hostsWithLLDPData.ContainsKey($_.ComputerName) })
                if ($sessionsToCollect.Count -eq 0) {
                    Log-Info "All hosts have LLDP neighbor data. No retry needed."
                    break
                }
                Log-Info "Retry: $($sessionsToCollect.Count) hosts still missing LLDP neighbor data ($($sessionsToCollect.ComputerName -join ', ')). Waiting 30 seconds for next LLDP cycle..."
                Start-Sleep -Seconds 30
            }

            Log-Info "Collecting LLDP Neighbor data from $($sessionsToCollect.Count) hosts in parallel (attempt $attempt/$maxCollectionAttempts)..."
            $allResults = Invoke-Command -Session $sessionsToCollect -ScriptBlock ${function:GetLLDPNbrTLVs} -ArgumentList @(, '') -ThrottleLimit 128

            # Process results locally (fast I/O)
            foreach ($resultObj in @($allResults)) {
                $computerName = $resultObj.PSComputerName
                Log-Info "Processing LLDP Neighbor data from Host [ $computerName ]"

                $tmpCheckRst = $resultObj.CheckResult
                $tmpNbrLldpTLVs = $resultObj.NbrLLDPTLVs
                $tmpHostAdapter = $resultObj.HostAdapter

                if (-not $tmpCheckRst.Pass) {
                    $LLDPNbrTestStatus = 'SUCCESS'
                    $LLDPNbriDetailMsg += $tmpCheckRst.Message
                }

                # After Invoke-Command deserialization, hashtables become PSObjects.
                # Check for both hashtable and PSObject property counts.
                $tlvCount = if ($tmpNbrLldpTLVs -is [hashtable]) { $tmpNbrLldpTLVs.Count }
                            elseif ($tmpNbrLldpTLVs) { @($tmpNbrLldpTLVs.PSObject.Properties).Count }
                            else { 0 }
                if ($tlvCount -eq 0) {
                    Log-Info "No LLDP Neighbor TLVs found for $computerName"
                    continue
                }

                # After Invoke-Command, hashtables become deserialized PSObjects.
                # Convert back to proper hashtables so ConvertTo-Json produces the correct structure.
                if ($tmpNbrLldpTLVs -isnot [hashtable]) {
                    $reconverted = @{}
                    foreach ($prop in $tmpNbrLldpTLVs.PSObject.Properties) {
                        if ($prop.Name -notin @('Keys','Values','Count','IsReadOnly','IsFixedSize','SyncRoot','IsSynchronized','PSComputerName')) {
                            $reconverted[$prop.Name] = $prop.Value
                        }
                    }
                    $tmpNbrLldpTLVs = $reconverted
                }
                $tmpNbrLldpTLVs['PSComputerName'] = $computerName

                if ($tmpHostAdapter -isnot [hashtable]) {
                    $reconverted = @{}
                    foreach ($prop in $tmpHostAdapter.PSObject.Properties) {
                        if ($prop.Name -notin @('Keys','Values','Count','IsReadOnly','IsFixedSize','SyncRoot','IsSynchronized','PSComputerName')) {
                            $reconverted[$prop.Name] = $prop.Value
                        }
                    }
                    $tmpHostAdapter = $reconverted
                }
                $tmpHostAdapter['PSComputerName'] = $computerName

                # Check if any adapter on this host has valid (non-empty) TLV data
                $hasValidTLVs = $false
                foreach ($adapterKey in $tmpNbrLldpTLVs.Keys) {
                    if ($adapterKey -eq 'PSComputerName') { continue }
                    $adapterTlvs = $tmpNbrLldpTLVs[$adapterKey]
                    if ($adapterTlvs -and @($adapterTlvs).Count -gt 0) {
                        $hasValidTLVs = $true
                        break
                    }
                }

                $NbrLldpJsonPath = "$OutputPath\NBRLLDPTLV_$($computerName).json"
                $HostAdapterJsonPath = "$OutputPath\HOSTADAPTER_$($computerName).json"

                $tmpNbrLldpTLVs  | ConvertTo-Json -Depth 5 | Set-Content -Path $NbrLldpJsonPath -Encoding utf8
                $tmpHostAdapter | ConvertTo-Json -Depth 5 | Set-Content -Path $HostAdapterJsonPath -Encoding utf8
                Log-Info "LLDP Neighbor TLVs saved to $NbrLldpJsonPath"
                Log-Info "LLDP Host TLVs saved to $HostAdapterJsonPath"

                if ($hasValidTLVs) {
                    $hostsWithLLDPData[$computerName] = $true
                }
            }
        }

        # Log final LLDP data collection summary
        $hostsStillMissing = @($allNodeSessions | Where-Object { -not $hostsWithLLDPData.ContainsKey($_.ComputerName) })
        if ($hostsStillMissing.Count -gt 0) {
            Log-Info "Warning: $($hostsStillMissing.Count) hosts still have no valid LLDP neighbor data after $maxCollectionAttempts attempts: $($hostsStillMissing.ComputerName -join ', ')"
        } else {
            Log-Info "All $($allNodeSessions.Count) hosts have valid LLDP neighbor data."
        }

        $LLDPNbrCheckRstObject = @{
            Name               = 'AzStackHci_LLDP_Test_Neighbor_Existance'
            Title              = 'Validate Host LLDP Neighbor Existence'
            DisplayName        = 'Validate Host LLDP Neighbor Existence'
            Severity           = 'INFORMATIONAL'
            Description        = 'Check if all hosts have LLDP neighbors'
            Tags               = @{}
            Remediation        = $lnTxt.NoNetLldpAgentModule.TestLLDPNbrTlvsRemidation
            TargetResourceID   = 'ValidateLLDPNeighborExistence'
            TargetResourceName = 'ValidateLLDPNeighborExistence'
            TargetResourceType = 'ValidateLLDPNeighborExistence'
            Timestamp          = [datetime]::UtcNow
            Status             = $LLDPNbrTestStatus
            AdditionalData     = @{
                Source    = 'AllHosts'
                Resource  = 'ValidateLLDPNeighborExistence'
                Detail    = $LLDPNbriDetailMsg
                Status    = $LLDPNbrTestStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $LLDPTestResults += New-AzStackHciResultObject @LLDPNbrCheckRstObject

        return $LLDPTestResults
    } catch {
        throw "An error occurred while running Test-LLDPNbrTlvs: $_"
    } finally {
        Log-Info "Completed Test-LLDPNbrTlvs for $($PSSession.ComputerName)"
    }
}

function Convert-TlvChassisIdData {
    <#
    .SYNOPSIS
    Decodes the Chassis ID TLV (Type 1) byte string.
    .DESCRIPTION
    Parses a space-delimited byte string from an LLDP Chassis ID TLV. It handles different subtypes, such as MAC address (subtype 4) and interface name (subtype 7), returning a human-readable string.
    .PARAMETER TLVByteString
    The 'data' property from a Chassis ID TLV object, represented as a string of space-separated byte values.
    .EXAMPLE
    Convert-TlvChassisIdData -TLVByteString "4 136 79 174 216 117 1" # Returns a MAC address
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -le 1) { return "Unknown" }
    [int]$chasIdType = $TLVBytes[0]
    switch ($chasIdType) {
        4 {
            if ($TLVBytes.Length -ge 7) {
                return ("{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}" -f $TLVBytes[1], $TLVBytes[2], $TLVBytes[3], $TLVBytes[4], $TLVBytes[5], $TLVBytes[6])
            } else { return "Unknown" }
        }
        7 { return ([System.Text.Encoding]::ASCII.GetString($TLVBytes[1..($TLVBytes.Length - 1)])) }
        Default {
            Log-Info "Unknown Chassis ID TLV: $($TLVBytes -join ', ')"
            return "Unknown"
        }
    }
}

function Convert-TlvSystemNameData {
    <#
    .SYNOPSIS
    Decodes the System Name TLV (Type 5) byte string.
    .DESCRIPTION
    Parses a space-delimited byte string from an LLDP System Name TLV and converts it to a human-readable ASCII string.
    .PARAMETER TLVByteString
    The 'data' property from a System Name TLV object.
    .EXAMPLE
    Convert-TlvSystemNameData -TLVByteString "115 119 105 116 99 104 45 48 49" # Returns "switch-01"
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -le 1) { return "Unknown" }
    return [System.Text.Encoding]::ASCII.GetString($TLVBytes[0..($TLVBytes.Length - 1)])
}

function Convert-TlvSystemDescData {
    <#
    .SYNOPSIS
    Decodes the System Description TLV (Type 6) byte string.
    .DESCRIPTION
    Parses a space-delimited byte string from an LLDP System Description TLV and converts it to a human-readable ASCII string.
    .PARAMETER TLVByteString
    The 'data' property from a System Description TLV object.
    .EXAMPLE
    $desc = Convert-TlvSystemDescData -TLVByteString "67 105 115 99 111 32 ...."
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -le 1) { return "Unknown" }
    return [System.Text.Encoding]::ASCII.GetString($TLVBytes)
}

function Convert-TlvPortIdData {
    <#
    .SYNOPSIS
    Decodes the Port ID TLV (Type 2) byte string.
    .DESCRIPTION
    Parses a space-delimited byte string from an LLDP Port ID TLV. It handles different subtypes, such as MAC address (subtype 3) and interface name (subtypes 1, 2, 5), returning a human-readable string.
    .PARAMETER TLVByteString
    The 'data' property from a Port ID TLV object.
    .EXAMPLE
    Convert-TlvPortIdData -TLVByteString "3 1 2 3 4 5 6" # Returns a MAC address
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if(-not $TLVBytes -or $TLVBytes.Length -le 1 ){ return "Unknown" }
    [int]$portIdType = $TLVBytes[0]
    switch -Regex ($portIdType) {
        "[1-2]|[5]"{ return ([System.Text.Encoding]::ASCII.GetString($TLVBytes[1..($TLVBytes.Length - 1)])) }
        "3"{ # Type 3 is a MAC address
            if ($TLVBytes.Length -ge 7) {
                return ("{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}" -f $TLVBytes[1], $TLVBytes[2], $TLVBytes[3], $TLVBytes[4], $TLVBytes[5], $TLVBytes[6])
            } else { return "Unknown" }
        }
        Default {
            Log-Info "Unknown Port ID TLV: $($TLVBytes -join ', ')"
            return "Unknown"
        }
    }
}

function Convert-TlvMaxFrameSize {
    <#
    .SYNOPSIS
    Decodes the Maximum Frame Size TLV (Type 4) byte string.
    .DESCRIPTION
    Parses a 2-byte value from an LLDP Maximum Frame Size TLV and converts it to an integer representing the MTU size in bytes.
    .PARAMETER TLVByteString
    The 'data' property from a Max Frame Size TLV object.
    .EXAMPLE
    Convert-TlvMaxFrameSize -TLVByteString "35 136" # Returns 9100
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if(-not $TLVBytes -or $TLVBytes.Length -lt 2){ return "Unknown" }
    $MaxFrameValue = ($TLVBytes[0] * 256) + $TLVBytes[1]
    return [int]$MaxFrameValue
}

function Convert-TlvPortVlanId {
    <#
    .SYNOPSIS
    Decodes the Port VLAN ID (PVID) TLV (Type 8 or Org-Specific 127/0-128-194/1) byte string.
    .DESCRIPTION
    Parses a 2-byte value from an LLDP PVID TLV and converts it to an integer representing the VLAN ID. Validates that the ID is within the standard 1-4094 range.
    .PARAMETER TLVByteString
    The 'data' property from a PVID TLV object.
    .EXAMPLE
    Convert-TlvPortVlanId -TLVByteString "0 100" # Returns 100
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -lt 2) { return "Unknown" }
    # The VLAN ID is a 2-byte integer (Big Endian)
    $vlanId = ($TLVBytes[0] -shl 8) + $TLVBytes[1]
    if ($vlanId -lt 1 -or $vlanId -gt 4094) { return "Invalid ($vlanId)" }
    return [int]$vlanId
}

function Convert-TlvVlanNameData {
    <#
    .SYNOPSIS
    Decodes the VLAN Name TLV (Org-Specific 127/0-128-194/3) byte string.
    .DESCRIPTION
    Parses a complex, organization-specific TLV that contains both a VLAN ID and a VLAN Name. Returns a custom object with both properties.
    .PARAMETER TLVByteString
    The 'data' property from a VLAN Name TLV object.
    .EXAMPLE
    $vlanInfo = Convert-TlvVlanNameData -TLVByteString "0 10 4 84 69 83 84" # Returns an object with VlanId=10 and VlanName="TEST"
    #>
    param ([string] $TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -lt 4) { return "Unknown" }
    try {
        $vlanId = ($TLVBytes[0] -shl 8) + $TLVBytes[1]
        $nameLength = $TLVBytes[2]
        $vlanName = [System.Text.Encoding]::ASCII.GetString($TLVBytes, 3, $nameLength)
        return [PSCustomObject]@{ VlanId = $vlanId; VlanName = $vlanName }
    } catch { return "ParseError" }
}

function Convert-TlvDcbxIeeePfc {
    <#
    .SYNOPSIS
    Decodes an IEEE compliant DCBX Priority Flow Control (PFC) TLV.
    .DESCRIPTION
    Parses a space-delimited byte string from an IEEE PFC TLV (Org-Specific 127/0-128-194/11). It uses bitwise operations to extract the 'willing' bit, MACsec bypass capability, and the bitmap of enabled PFC priorities.
    .PARAMETER TLVByteString
    The 'data' property from an IEEE PFC TLV object.
    .EXAMPLE
    $pfcConfig = Convert-TlvDcbxIeeePfc -TLVByteString "1 12 1 8"
    #>
    param([string]$TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -lt 4) { return "Unknown" }
    try {
        $willingBit = ($TLVBytes[2] -shr 0) -band 0x01
        $mbcBit = ($TLVBytes[2] -shr 1) -band 0x01
        $pfcEnableVector = $TLVBytes[3]
        $enabledPriorities = @()
        for ($i = 0; $i -lt 8; $i++) {
            if ((($pfcEnableVector -shr $i) -band 0x01) -eq 1) { $enabledPriorities += $i }
        }
        return [PSCustomObject]@{
            Type                 = "IEEE"
            Willing              = [bool]$willingBit
            MACsecBypassCapable  = [bool]$mbcBit
            PfcEnabledPriorities = $enabledPriorities
        }
    } catch { return "ParseError_IEEE_PFC" }
}

function Convert-TlvDcbxIeeeEts {
    <#
    .SYNOPSIS
    Decodes an IEEE 802.1Qaz-compliant DCBX Enhanced Transmission Selection (ETS) TLV.
    .DESCRIPTION
    Parses a space-delimited byte string from an IEEE ETS TLV (Org-Specific 127/0-128-194/9). It extracts the 'willing' bit, maximum supported traffic classes, and bandwidth allocation percentages.
    .PARAMETER TLVByteString
    The 'data' property from an IEEE ETS TLV object.
    .EXAMPLE
    $etsConfig = Convert-TlvDcbxIeeeEts -TLVByteString "1 14 4 0 0 0 0 0 0 50 50 0 0 0 0 0 0"
    #>
    param([string]$TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -lt 9) { return "Unknown" }
    try {
        $willingBit = ($TLVBytes[2] -shr 0) -band 0x01
        $maxTcs = ($TLVBytes[2] -shr 2) -band 0x07
        $tc0_Bandwidth = $TLVBytes[9]
        return [PSCustomObject]@{
            Type                       = "IEEE"
            Willing                    = [bool]$willingBit
            MaxTrafficClassesSupported = $maxTcs
            TrafficClass0_BandwidthPercent = $tc0_Bandwidth
        }
    } catch { return "ParseError_IEEE_ETS" }
}

function Convert-TlvDcbxCEE {
    <#
    .SYNOPSIS
    Decodes a legacy CEE (Converged Enhanced Ethernet) DCBX TLV.
    .DESCRIPTION
    Parses a space-delimited byte string from a CEE DCBX TLV (Org-Specific 127/0-27-33/2). This format contains its own sub-TLVs for PFC and ETS, which this function iterates through to extract the relevant configuration.
    .PARAMETER TLVByteString
    The 'data' property from a CEE DCBX TLV object.
    .EXAMPLE
    $ceeConfig = Convert-TlvDcbxCEE -TLVByteString "1 8 0 0 100 0 0 0 2 4 1 8"
    #>
    param([string]$TLVByteString)
    $TLVBytes = $TLVByteString -split ' ' | ForEach-Object { [byte]$_ }
    if (-not $TLVBytes -or $TLVBytes.Length -lt 4) { return "Unknown" }
    try {
        $pfcEnabledPriorities = @()
        $etsBandwidth = @{}
        $i = 0
        while ($i -lt $TLVBytes.Length) {
            $subTlvType = $TLVBytes[$i]
            $subTlvLength = $TLVBytes[$i+1]
            if (($i + 2 + $subTlvLength) -gt $TLVBytes.Length) { break }
            $subTlvData = $TLVBytes[($i + 2)..($i + 1 + $subTlvLength)]
            switch ($subTlvType) {
                1 { $etsBandwidth['Acknowledged'] = $true } # Priority Group (ETS)
                2 { # PFC
                    if ($subTlvData.Length -ge 2) {
                        $pfcEnableVector = $subTlvData[1]
                        for ($p = 0; $p -lt 8; $p++) {
                            if ((($pfcEnableVector -shr $p) -band 0x01) -eq 1) { $pfcEnabledPriorities += $p }
                        }
                    }
                }
            }
            $i += (2 + $subTlvLength)
        }
        return [PSCustomObject]@{
            Type                 = "CEE"
            PfcEnabledPriorities = $pfcEnabledPriorities
            EtsConfigured        = [bool]$etsBandwidth['Acknowledged']
        }
    } catch { return "ParseError_CEE" }
}

function Merge-AdapterData {
    param ([hashtable]$existingData, [hashtable]$newData)
    foreach ($key in $newData.Keys) {
        if ($existingData.ContainsKey($key)) {
            $existingData[$key] += $newData[$key]
        } else {
            $existingData[$key] = $newData[$key]
        }
    }
}

function Export-MergedLLDPDataToJson {
    <#
    .SYNOPSIS
    Merges all individual host and neighbor JSON files into a single, comprehensive JSON document.
    .DESCRIPTION
    This function discovers all raw `NBRLLDPTLV_*.json` and `HOSTADAPTER_*.json` files in the output directory. It iterates through them, parses the raw TLV data using the various `Convert-Tlv*` functions, and merges local and remote information into a structured, unified JSON file named `MergedLLDPData.json`.
    .PARAMETER OutputPath
    The directory path containing the raw LLDP JSON files to be merged.
    .PARAMETER NbrFilterString
    The file filter for neighbor LLDP data files. Defaults to 'NBRLLDPTLV_*.json'.
    .PARAMETER HostFilterString
    The file filter for host adapter data files. Defaults to 'HOSTADAPTER_*.json'.
    .EXAMPLE
    $mergedFile = Export-MergedLLDPDataToJson -OutputPath "C:\Temp\LLDP_Logs"
    #>
    param (
        [string] $OutputPath,
        [string] $NbrFilterString = 'NBRLLDPTLV_*.json',
        [string] $HostFilterString = 'HOSTADAPTER_*.json'
    )

    $outputFilePath = Join-Path -Path $OutputPath -ChildPath "MergedLLDPData.json"
    $nbrLldpJsonFiles = Get-ChildItem -Path $OutputPath -Filter $NbrFilterString
    $hostAdapterJsonFiles = Get-ChildItem -Path $OutputPath -Filter $HostFilterString

    if ($nbrLldpJsonFiles.Length -eq 0) {
        Log-Info "No Neighbor LLDP TLV JSON files found at '$OutputPath'."
        return
    }

    if ($hostAdapterJsonFiles.Length -eq 0) {
        Log-Info "No Host adapter JSON files found at '$OutputPath'."
        return
    }

    $mergedLLDPJson = @{}

    foreach ($file in $nbrLldpJsonFiles) {
        $jsonContent = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        $hciHost = $jsonContent.PSComputerName
        $adapterData = @{}
        foreach ($key in $jsonContent.PSObject.Properties.Name) {
            if ($key -eq 'PSComputerName') {
                continue
            }

            $adapterName = $key
            $tlvListObj = $jsonContent.$key

            $allTlvs = @{}
            foreach ($tlv in $tlvListObj) {
                $tlvKey = "$($tlv.TLVType)"
                if ($tlv.TLVType -eq 127) {
                    $tlvKey = "$($tlv.TLVType)_$($tlv.Oui)_$($tlv.OuiSubtype)"
                }
                if (-not $allTlvs.ContainsKey($tlvKey)) {
                    $allTlvs[$tlvKey] = @()
                }
                $allTlvs[$tlvKey] += $tlv
            }

            $chassisTlv = $allTlvs["1"] | Select-Object -First 1
            $portIdTlv = $allTlvs["2"] | Select-Object -First 1
            $maxFrameTlv = $allTlvs["4"] | Select-Object -First 1
            $systemNameTlv = $allTlvs["5"] | Select-Object -First 1
            $systemDescTlv = $allTlvs["6"] | Select-Object -First 1

            # Correctly look up PVID, prioritizing the IEEE 802.1-specific TLV.
            $ieeePvidTlv = $allTlvs["127_0 128 194_1"] | Select-Object -First 1 # OUI with spaces
            $genericPvidTlv = $allTlvs["8"] | Select-Object -First 1

            $remotePvid = "Unknown"
            if ($ieeePvidTlv) {
                $remotePvid = Convert-TlvPortVlanId $ieeePvidTlv.data
            } elseif ($genericPvidTlv) {
                if (($genericPvidTlv.data -split ' ').Length -eq 2) {
                    $remotePvid = Convert-TlvPortVlanId $genericPvidTlv.data
                }
            }

            # VLAN Names TLV (OUI with spaces)
            $vlanNameTlvs = $allTlvs["127_0 128 194_3"]

            $remoteETS = "Not Advertised"
            $remotePFC = "Not Advertised"

            # Check for modern IEEE standard first (OUI with spaces)
            $ieeeEtsTlv = $allTlvs["127_0 128 194_9"]
            $ieeePfcTlv = $allTlvs["127_0 128 194_11"]
            if ($ieeeEtsTlv -or $ieeePfcTlv) {
                $remoteETS = if ($ieeeEtsTlv) { Convert-TlvDcbxIeeeEts ($ieeeEtsTlv | Select -First 1).data } else { "Not Advertised" }
                $remotePFC = if ($ieeePfcTlv) { Convert-TlvDcbxIeeePfc ($ieeePfcTlv | Select -First 1).data } else { "Not Advertised" }
            } else {
                # If not found, check for legacy CEE version (OUI with spaces)
                $ceeDcbxTlv = $allTlvs["127_0 27 33_2"]
                if ($ceeDcbxTlv) {
                    $parsedCeeData = Convert-TlvDcbxCEE ($ceeDcbxTlv | Select -First 1).data
                    $remoteETS = $parsedCeeData
                    $remotePFC = $parsedCeeData
                }
            }

            $adapterData[$adapterName] = [ordered]@{
                "RemoteChassisID"    = if ($chassisTlv) { Convert-TlvChassisIdData $chassisTlv.data } else { "Unknown" }
                "RemoteSystemName"   = if ($systemNameTlv) { Convert-TlvSystemNameData $systemNameTlv.data } else { "Unknown" }
                "RemoteSystemDesc"   = if ($systemDescTlv) { Convert-TlvSystemDescData $systemDescTlv.data } else { "Unknown" }
                "RemotePortID"       = if ($portIdTlv) { Convert-TlvPortIdData $portIdTlv.data } else { "Unknown" }
                "RemoteMaxFrameSize" = if ($maxFrameTlv) { Convert-TlvMaxFrameSize $maxFrameTlv.data } else { "Unknown" }
                "RemotePortVLANID"   = $remotePvid
                "RemoteVLANNames"    = if ($vlanNameTlvs) { @($vlanNameTlvs | ForEach-Object { Convert-TlvVlanNameData $_.data }) } else { @() }
                "RemoteETS"          = $remoteETS
                "RemotePFC"          = $remotePFC
            }
        }

        if (-not $mergedLLDPJson.ContainsKey($hciHost)) {
            $mergedLLDPJson[$hciHost] = @{}
        }
        Merge-AdapterData -existingData $mergedLLDPJson[$hciHost] -newData $adapterData
    }

    foreach ($file in $hostAdapterJsonFiles) {
        $jsonContent = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        $hciHost = $jsonContent.PSComputerName
        $adapterData = @{}
        foreach ($key in $jsonContent.PSObject.Properties.Name) {
            if ($key -eq 'PSComputerName') {
                continue
            }
            $adapterName = $key
            $adapterObj = $jsonContent.$key
            $adapterData[$adapterName] = [ordered]@{
                "LocalAdapterName"              = $adapterObj.Name
                "LocalAdapterDescription"       = $adapterObj.InterfaceDescription
                "LocalAdapterDriverInformation" = $adapterObj.DriverInformation
                "LocalAdapterStatus"            = $adapterObj.Status
                "LocalAdapterMacAddress"        = $adapterObj.MacAddress
                "LocalAdapterLinkSpeed"         = $adapterObj.LinkSpeed
            }
        }

        if (-not $mergedLLDPJson.ContainsKey($hciHost)) {
            $mergedLLDPJson[$hciHost] = @{}
        }
        Merge-AdapterData -existingData $mergedLLDPJson[$hciHost] -newData $adapterData
    }

    $mergedJsonString = $mergedLLDPJson | ConvertTo-Json -Depth 10
    $mergedJsonString | Set-Content -Path $outputFilePath

    # Cache as PSObject (same format as ConvertFrom-Json) so consumers can iterate via .PSObject.Properties
    $script:LLDPDataCache['MergedLLDPData'] = $mergedJsonString | ConvertFrom-Json

    return $outputFilePath
}

function Test-MergedLLDPDataToJson {
    <#
    .SYNOPSIS
    Executes the merge process and validates its output.
    .DESCRIPTION
    A wrapper function that calls `Export-MergedLLDPDataToJson` and then performs a basic check to ensure the resulting `MergedLLDPData.json` file was created and is not empty.
    .PARAMETER OutputPath
    The directory path containing the raw LLDP JSON files.
    .EXAMPLE
    $results = Test-MergedLLDPDataToJson -OutputPath "C:\Temp\LLDP_Logs"
    #>
    [CmdletBinding()]
    param (
        [string] $OutputPath
    )

    # Check if NetLldpAgent module is available
    if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
        Log-Info "NetLldpAgent module is not installed. Skipping Merged LLDP Data to JSON test."
        $skipResult = @{
            Name               = 'AzStackHci_LLDP_Test_Merged_LLDP_To_Json'
            Title              = 'Export Merged LLDP to JSON'
            DisplayName        = 'Export Merged LLDP to JSON'
            Severity           = 'INFORMATIONAL'
            Description        = 'NetLldpAgent module is not installed. Test skipped.'
            Tags               = @{}
            Remediation        = 'Install NetLldpAgent by running: Install-WindowsFeature Data-Center-Bridging, RSAT-DataCenterBridging-LLDP-Tools'
            TargetResourceID   = 'AllHosts'
            TargetResourceName = 'GenerateMergedLLDPJson'
            TargetResourceType = 'GenerateMergedLLDPJson'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source    = 'AllHosts'
                Resource  = 'GenerateMergedLLDPJson'
                Detail    = 'NetLldpAgent module is not installed. Test was skipped.'
                Status    = 'SUCCESS'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return @(New-AzStackHciResultObject @skipResult)
    }

    $nbrLldpJsonFiles = Get-ChildItem -Path $OutputPath -Filter 'NBRLLDPTLV_*.json' -ErrorAction SilentlyContinue
    $hostAdapterJsonFiles = Get-ChildItem -Path $OutputPath -Filter 'HOSTADAPTER_*.json' -ErrorAction SilentlyContinue

    if ($null -eq $nbrLldpJsonFiles -or $nbrLldpJsonFiles.Count -eq 0) {
        Log-Info "No LLDP neighbor data files found. Switch LLDP advertisements were not received by any cluster node."
        $skipResult = @{
            Name               = 'AzStackHci_LLDP_Test_Merged_LLDP_To_Json'
            Title              = 'Export Merged LLDP to JSON'
            DisplayName        = 'Export Merged LLDP to JSON'
            Severity           = 'INFORMATIONAL'
            Description        = 'No LLDP neighbor data files found for processing. This indicates connected switches are not transmitting LLDP advertisements, LLDP is disabled on switch ports, or there is a fundamental network connectivity issue preventing LLDP protocol communication.'
            Tags               = @{}
            Remediation        = 'Verify: (1) LLDP is enabled globally on connected ToR switches, (2) LLDP transmission is enabled on switch ports connected to cluster nodes, (3) Physical cables are properly connected, (4) Switch ports are in UP/enabled state. Consult switch vendor documentation for LLDP configuration commands.'
            TargetResourceID   = 'AllHosts'
            TargetResourceName = 'GenerateMergedLLDPJson'
            TargetResourceType = 'GenerateMergedLLDPJson'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source    = 'AllHosts'
                Resource  = 'GenerateMergedLLDPJson'
                Detail    = 'No LLDP neighbor data files found in output path. Previous test may have been skipped.'
                Status    = 'SUCCESS'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return @(New-AzStackHciResultObject @skipResult)
    }

    $mergedLLDPJson = Export-MergedLLDPDataToJson -OutputPath $OutputPath
    if (-not (Test-Path -Path $mergedLLDPJson)) {
        throw $lnTxt.NoMergedLLDPJson -f $mergedLLDPJson
    }
    $retVal = [PSCustomObject]@{
        Pass    = $true
        Message = "Successfully generated the merged LLDP JSON file."
    }
    $mergedLLDPJsonObj = if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('MergedLLDPData')) {
        $script:LLDPDataCache['MergedLLDPData']
    } else {
        Get-Content -Path $mergedLLDPJson | ConvertFrom-Json
    }
    if ($mergedLLDPJsonObj.Count -eq 0) {
        $retVal.Pass = $false
        $retVal.Message += "`n" + $lnTxt.NoMergedLLDPJsonObj -f $mergedLLDPJson
    }
    $LLDPMergedJSONTestStatus = if ($retVal.Pass) { 'SUCCESS' } else { 'SUCCESS' }
    $LLDPMergedJSONDetailMsg = $retVal.Message
    $LLDPMergedJsonRstObject = @{
        Name               = 'AzStackHci_LLDP_Test_Merged_LLDP_To_Json'
        Title              = 'Export Merged LLDP to JSON'
        DisplayName        = 'Export Merged LLDP to JSON'
        Severity           = 'INFORMATIONAL'
        Description        = "Convert and generate the merged LLDP JSON file located at: $mergedLLDPJson."
        Tags               = @{ }
        Remediation        = $lnTxt.GenerateMergedLLDPJsonRemidation
        TargetResourceID   = 'AllHosts'
        TargetResourceName = 'GenerateMergedLLDPJson'
        TargetResourceType = 'GenerateMergedLLDPJson'
        Timestamp          = [datetime]::UtcNow
        Status             = $LLDPMergedJSONTestStatus
        AdditionalData     = @{
            Source    = 'AllHosts'
            Resource  = 'GenerateMergedLLDPJson'
            Detail    = $LLDPMergedJSONDetailMsg
            Status    = $LLDPMergedJSONTestStatus
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    $LLDPTestResults = @(New-AzStackHciResultObject @LLDPMergedJsonRstObject)
    return $LLDPTestResults
}

function Test-LLDPConnections {
    <#
    .SYNOPSIS
    Analyzes the merged LLDP data to validate the physical network topology.
    .DESCRIPTION
    This function reads the `MergedLLDPData.json` file and performs several validation checks. It identifies all connections, groups them by switch (`Switch2Node.json`) and by host (`Node2Switch.json`), and then checks for inconsistencies, such as hosts or switches having a different number of connections than their peers.
    .PARAMETER OutputPath
    The directory path containing `MergedLLDPData.json`.
    .PARAMETER PhysicalNodeList
    An array of physical node objects used to create a name-to-IP mapping file.
    .EXAMPLE
    Test-LLDPConnections -OutputPath "C:\Temp\LLDP_Logs" -PhysicalNodeList $nodes
    #>
    [CmdletBinding()]
    param (
        [string] $OutputPath,
        [array] $PhysicalNodeList
    )
    try {
        # Check if NetLldpAgent module is available
        if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
            Log-Info "NetLldpAgent module is not installed. Skipping LLDP Connections test."
            $skipResult = @{
                Name               = 'AzStackHci_Hosts_LLDP_Connections_Validation'
                Title              = 'LLDP Connections Validation'
                DisplayName        = 'LLDP Connections Validation'
                Severity           = 'INFORMATIONAL'
                Description        = 'NetLldpAgent module is not installed. Test skipped.'
                Tags               = @{}
                Remediation        = 'Install NetLldpAgent by running: Install-WindowsFeature Data-Center-Bridging, RSAT-DataCenterBridging-LLDP-Tools'
                TargetResourceID   = 'LLDPConnectionsValidated'
                TargetResourceName = 'LLDPConnectionsValidated'
                TargetResourceType = 'LLDPConnectionsValidated'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = 'MergedLLDPData.json'
                    Resource  = 'LLDPConnectionsValidated'
                    Detail    = 'NetLldpAgent module is not installed. Test was skipped.'
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            return @(New-AzStackHciResultObject @skipResult)
        }

        $LLDPJsonFile = Join-Path -Path $OutputPath -ChildPath "MergedLLDPData.json"
        if (-Not (Test-Path -Path $LLDPJsonFile)) {
            Log-Info "MergedLLDPData.json not found. Previous LLDP tests may have been skipped or failed. This indicates that connected switches failed to advertise LLDP information containing switch identity, port details, and network configuration. Physical network discovery could not complete."
            $skipResult = @{
                Name               = 'AzStackHci_Hosts_LLDP_Connections_Validation'
                Title              = 'LLDP Connections Validation'
                DisplayName        = 'LLDP Connections Validation'
                Severity           = 'INFORMATIONAL'
                Description        = 'Network topology data is unavailable for validation. This indicates that connected switches failed to advertise LLDP information containing switch identity, port details, and network configuration. Physical network discovery could not complete.'
                Tags               = @{}
                Remediation        = 'Verify switch LLDP configuration: (1) Enable LLDP globally on all ToR switches, (2) Enable LLDP transmission on ports connected to cluster nodes, (3) Ensure switch management is properly configured to generate LLDP advertisements. Some switches require explicit LLDP TLV selection for comprehensive data.'
                TargetResourceID   = 'LLDPConnectionsValidated'
                TargetResourceName = 'LLDPConnectionsValidated'
                TargetResourceType = 'LLDPConnectionsValidated'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = 'MergedLLDPData.json'
                    Resource  = 'LLDPConnectionsValidated'
                    Detail    = 'MergedLLDPData.json not found. Previous tests may have been skipped.'
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            return @(New-AzStackHciResultObject @skipResult)
        }

        $LLDPJson = if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('MergedLLDPData')) {
            $script:LLDPDataCache['MergedLLDPData']
        } else {
            Get-Content -Path $LLDPJsonFile | ConvertFrom-Json
        }
        $connections = @()
        $LLDPConnectionResults = @()
        $missingTlvFound = $false
        if ($PhysicalNodeList -and $PhysicalNodeList.Count -gt 0) {
            $name2IpPath = Join-Path $OutputPath 'NodeName2Ip.json'
            $name2Ip = @{}
            foreach ($n in $PhysicalNodeList) {
                $name2Ip[$n.name] = $n.ipv4Address
            }
            $name2Ip | ConvertTo-Json | Set-Content -Encoding utf8 $name2IpPath
            $script:LLDPDataCache['NodeName2Ip'] = $name2Ip
        }
        foreach ($node in $LLDPJson.PSObject.Properties) {
            $nodeName = $node.Name
            $nodeObject = $node.Value.PSObject.Properties

            foreach ($adapter in $nodeObject) {
                $a = $adapter.Value
                if ([string]::IsNullOrEmpty($a.RemoteSystemName) -or
                    [string]::IsNullOrEmpty($a.RemoteChassisID) -or
                    [string]::IsNullOrEmpty($a.RemotePortID) -or
                    $a.RemoteSystemName -eq "Unknown" -or
                    $a.RemoteChassisID -eq "Unknown" -or
                    $a.RemotePortID -eq "Unknown") {

                    if (-not $missingTlvFound) {
                        $warnObj = @{
                            Name               = 'AzStackHci_Hosts_Missing_LLDP_TLVs_To_Validated_Connections'
                            Title              = 'Missing LLDP TLVs for Validated Connections'
                            DisplayName        = 'Missing LLDP TLVs for Validated Connections'
                            Severity           = 'INFORMATIONAL'
                            Description        = $lnTxt.UnknownLLDPNeighbor
                            Tags               = @{}
                            Remediation        = $lnTxt.TestLLDPNbrTlvsRemidation
                            TargetResourceID   = 'MissingLLDPTLVsforValidatedConnections'
                            TargetResourceName = 'MissingLLDPTLVsforValidatedConnections'
                            TargetResourceType = 'MissingLLDPTLVsforValidatedConnections'
                            Timestamp          = [datetime]::UtcNow
                            Status             = 'SUCCESS'
                            AdditionalData     = @{
                                Source    = 'MergedLLDPData.json'
                                Resource  = 'LLDPConnectionsValidated'
                                Detail    = $lnTxt.MissingLLDPConnectionsDetail
                                Status    = 'SUCCESS'
                                TimeStamp = [datetime]::UtcNow
                            }
                            HealthCheckSource  = $ENV:EnvChkrId
                        }
                        $LLDPConnectionResults += New-AzStackHciResultObject @warnObj
                    }
                    $missingTlvFound = $true

                    Log-Info "Warning: Missing or unknown LLDP data for adapter $($a.LocalAdapterName) on host $nodeName"
                    continue
                }
                $remoteChassisId = $a.RemoteChassisID
                $normalizedChassisId = if ($remoteChassisId -and $remoteChassisId -ne "Unknown") {
                    $remoteChassisId.ToUpper()
                } else {
                    $remoteChassisId
                }
                $connections += [PSCustomObject]@{
                    LocalHostName           = $nodeName
                    LocalAdapterName        = $a.LocalAdapterName
                    LocalAdapterDescription = $a.LocalAdapterDescription
                    LocalMacAddress         = $a.LocalAdapterMacAddress
                    RemoteSystemName        = $a.RemoteSystemName
                    RemoteChassisID         = $normalizedChassisId
                    RemotePortId            = $a.RemotePortId
                }
            }
        }
        $connectionJsonFile = Join-Path -Path $OutputPath -ChildPath "Connections.json"
        $connections | ConvertTo-Json -Depth 5 | Out-File -FilePath $connectionJsonFile -Encoding utf8
        Log-Info "Full connection map saved to $connectionJsonFile"
        $LLDPConnectionStatusMessage = "Host LLDP Connections:"
        if ($connections.Count -le 0) {
            $LLDPConnectionStatusMessage += "`n" + $lnTxt.NoLLDPConnectionsFound
            Log-Info $LLDPConnectionStatusMessage
            $LLDPConnectionRstObject = @{
                Name               = "AzStackHci_Hosts_Have_No_LLDP_Connections"
                Title              = 'No LLDP Connections Detected'
                DisplayName        = 'No LLDP Connections Detected'
                Severity           = 'INFORMATIONAL'
                Description        = 'No physical network connections discovered via LLDP protocol. Connected switches are not advertising required LLDP TLVs (Type-Length-Values) including System Name, Chassis ID, and Port ID. This prevents physical topology validation and network configuration verification.'
                Tags               = @{ }
                Remediation        = 'Configure LLDP on all connected switches: (1) Enable LLDP globally, (2) Enable LLDP transmission on cluster-connected ports, (3) Verify required TLVs are advertised: System Name (Type 5), Chassis ID (Type 1), Port ID (Type 2). Some enterprise switches require explicit TLV selection. Consult switch documentation for vendor-specific LLDP commands.'
                TargetResourceID   = 'NoLLDPConnectionsFound'
                TargetResourceName = 'NoLLDPConnectionsFound'
                TargetResourceType = 'NoLLDPConnectionsFound'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = 'MergedLLDPData.json'
                    Resource  = 'LLDPConnectionsValidated'
                    Detail    = $LLDPConnectionStatusMessage
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $LLDPConnectionResults += New-AzStackHciResultObject @LLDPConnectionRstObject
            return $LLDPConnectionResults
        }
        $switch2NodeDict = @{}
        foreach ($connection in $connections) {
            $normalizedSystemName = $connection.RemoteSystemName.ToLower()
            if ($normalizedSystemName.Contains('.')) {
                $normalizedSystemName = $normalizedSystemName.Split('.')[0]
            }
            $switchKey = $normalizedSystemName
            $connectItem = [PSCustomObject]@{
                HostAdapterName = $connection.LocalAdapterName
                HostAdapterDescription = $connection.LocalAdapterDescription
                HostMacAddress = $connection.LocalMacAddress
                SwitchPortId = $connection.RemotePortId
            }
            $nodeKey = $connection.LocalHostName
            if ($switch2NodeDict.ContainsKey($switchKey)) {
                if ($switch2NodeDict[$switchKey].ContainsKey($nodeKey)) {
                    $switch2NodeDict[$switchKey][$nodeKey] += $connectItem
                } else {
                    $switch2NodeDict[$switchKey][$nodeKey] = @($connectItem)
                }
            } else {
                $switch2NodeDict[$switchKey] = @{ $nodeKey = @($connectItem) }
            }
        }
        $switch2NodeJsonFile = Join-Path -Path $OutputPath -ChildPath "Switch2Node.json"
        $switch2NodeDict | ConvertTo-Json -Depth 5 | Out-File -FilePath $switch2NodeJsonFile -Encoding utf8
        Log-Info "Connection map saved to $switch2NodeJsonFile"
        $firstKey = $switch2NodeDict.Keys | Select-Object -First 1
        $expectedLength = $switch2NodeDict[$firstKey].Count
        foreach ($switchKey in $switch2NodeDict.Keys) {
            $length = $switch2NodeDict[$switchKey].Count
            if ($length -ne $expectedLength) {
                $LLDPConnectionStatusMessage += "`n  Switch '$switchKey' expects to be connected to $expectedLength hosts but is connected to $length."
                Log-Info $LLDPConnectionStatusMessage
                $LLDPConnectionRstObject = @{
                    Name               = "Network_Switch_Connect_Different_Number_of_Nodes"
                    Title              = 'Switch Connected to a Different Number of Hosts'
                    DisplayName        = 'Switch Connected to a Different Number of Hosts'
                    Severity           = 'INFORMATIONAL'
                    Description        = "Switch '$switchKey' expects to be connected to $expectedLength hosts but is connected to $length."
                    Tags               = @{ }
                    Remediation        = $lnTxt.ConnectionMismatchRemidation
                    TargetResourceID   = 'SwitchHostConnectionMismatch'
                    TargetResourceName = 'SwitchHostConnectionMismatch'
                    TargetResourceType = 'SwitchHostConnectionMismatch'
                    Timestamp          = [datetime]::UtcNow
                    Status             = 'SUCCESS'
                    AdditionalData     = @{
                        Source    = 'Connections.json'
                        Resource  = 'LLDPConnectionsValidated'
                        Detail    = $LLDPConnectionStatusMessage
                        Status    = 'SUCCESS'
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $LLDPConnectionResults += New-AzStackHciResultObject @LLDPConnectionRstObject
                return $LLDPConnectionResults
            }
        }
        $node2SwitchDict = @{}
        foreach ($connection in $connections) {
            $nodeKey = $connection.LocalHostName
            $connectItem = [PSCustomObject]@{
                HostAdapterName = $connection.LocalAdapterName
                HostAdapterDescription = $connection.LocalAdapterDescription
                HostMacAddress = $connection.LocalMacAddress
                SwitchPortId = $connection.RemotePortId
            }
            $normalizedSystemName = $connection.RemoteSystemName.ToLower()
            if ($normalizedSystemName.Contains('.')) {
                $normalizedSystemName = $normalizedSystemName.Split('.')[0]
            }
            $switchKey = $normalizedSystemName
            if ($node2SwitchDict.ContainsKey($nodeKey)) {
                if ($node2SwitchDict[$nodeKey].ContainsKey($switchKey)) {
                    $node2SwitchDict[$nodeKey][$switchKey] += $connectItem
                } else {
                    $node2SwitchDict[$nodeKey][$switchKey] = @($connectItem)
                }
            } else {
                $node2SwitchDict[$nodeKey] = @{ $switchKey = @($connectItem) }
            }
        }
        $node2SwitchJsonFile = Join-Path -Path $OutputPath -ChildPath "Node2Switch.json"
        $node2SwitchJson = $node2SwitchDict | ConvertTo-Json -Depth 5
        $node2SwitchJson | Out-File -FilePath $node2SwitchJsonFile -Encoding utf8
        # Cache as PSObject so consumers don't need to re-serialize on every read
        $script:LLDPDataCache['Node2Switch'] = $node2SwitchJson | ConvertFrom-Json
        Log-Info "Connection map saved to $node2SwitchJsonFile"
        $firstKey = $node2SwitchDict.Keys | Select-Object -First 1
        $expectedLength = $node2SwitchDict[$firstKey].Count
        foreach ($nodeKey in $node2SwitchDict.Keys) {
            $length = $node2SwitchDict[$nodeKey].Count
            if ($length -ne $expectedLength) {
                $LLDPConnectionStatusMessage += "`n  Host '$nodeKey' expects to be connected to $expectedLength switches but is connected to $length."
                Log-Info $LLDPConnectionStatusMessage
                $LLDPConnectionRstObject = @{
                    Name               = "HCI_Node_Connect_Different_Number_of_Network_Device"
                    Title              = 'Host Connected to a Different Number of Switches'
                    DisplayName        = 'Host Connected to a Different Number of Switches'
                    Severity           = 'INFORMATIONAL'
                    Description        = "Host '$nodeKey' expects to be connected to $expectedLength switches but is connected to $length."
                    Tags               = @{ }
                    Remediation        = $lnTxt.ConnectionMismatchRemidation
                    TargetResourceID   = 'HostSwitchConnectionMismatch'
                    TargetResourceName = 'HostSwitchConnectionMismatch'
                    TargetResourceType = 'HostSwitchConnectionMismatch'
                    Timestamp          = [datetime]::UtcNow
                    Status             = 'SUCCESS'
                    AdditionalData     = @{
                        Source    = 'Connections.json'
                        Resource  = 'LLDPConnectionsValidated'
                        Detail    = $LLDPConnectionStatusMessage
                        Status    = 'SUCCESS'
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $LLDPConnectionResults += New-AzStackHciResultObject @LLDPConnectionRstObject
                return $LLDPConnectionResults
            }
        }
        $LLDPConnectionStatusMessage += "`nPassed all validation checks."
        $LLDPConnectionRstObject = @{
            Name               = "AzStackHci_Hosts_LLDP_Connections_Validation"
            Title              = 'LLDP Connections Validation Passed'
            DisplayName        = 'LLDP Connections Validation Passed'
            Severity           = 'INFO'
            Description        = 'All LLDP connections between hosts and switches were successfully validated.'
            Tags               = @{ }
            Remediation        = ''
            TargetResourceID   = 'LLDPConnectionsValidated'
            TargetResourceName = 'LLDPConnectionsValidated'
            TargetResourceType = 'LLDPConnectionsValidated'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source    = $LLDPJsonFile
                Resource  = 'LLDPConnectionsValidated'
                Detail    = $LLDPConnectionStatusMessage
                Status    = 'SUCCESS'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $LLDPConnectionResults += New-AzStackHciResultObject @LLDPConnectionRstObject
        return $LLDPConnectionResults
    } catch {
        Log-Info "An error occurred while testing LLDP connections: $_"
    } finally {
        Log-Info "Completed Test-LLDPConnections"
    }
}

function Get-LLDPTLVCapabilities {
    <#
    .SYNOPSIS
    Summarizes the capabilities advertised by all discovered network switches.
    .DESCRIPTION
    Parses the `MergedLLDPData.json` file to determine the overall capabilities of the connected network fabric. It checks for the presence of VLAN, MaxFrameSize, and DCBX (ETS/PFC) TLVs, and also attempts to identify switch vendors from the System Description TLV.
    .PARAMETER MergedLLDPData
    The PowerShell object resulting from converting `MergedLLDPData.json` from JSON.
    .EXAMPLE
    $capabilities = Get-LLDPTLVCapabilities -MergedLLDPData $lldpData
    #>
    param ([Parameter(Mandatory=$true)] [psobject] $MergedLLDPData)
    $capabilities = @{
        HasVLANList = $false
        HasNativeVLAN = $false
        HasMaxFrameSize = $false
        HasDCBX_ETS = $false
        HasDCBX_PFC = $false
        VendorsDetected = @()
    }
    foreach ($node in $MergedLLDPData.PSObject.Properties) {
        foreach ($adapter in $node.Value.PSObject.Properties) {
            $adapterData = $adapter.Value
            if ($adapterData.RemoteVLANNames -and $adapterData.RemoteVLANNames.Count -gt 0) { $capabilities.HasVLANList = $true }
            if ($adapterData.RemotePortVLANID -ne "Unknown") { $capabilities.HasNativeVLAN = $true }
            if ($adapterData.RemoteMaxFrameSize -ne "Unknown") { $capabilities.HasMaxFrameSize = $true }
            if ($adapterData.RemoteETS -ne "Not Advertised") { $capabilities.HasDCBX_ETS = $true }
            if ($adapterData.RemotePFC -ne "Not Advertised") { $capabilities.HasDCBX_PFC = $true }
            if ($adapterData.RemoteSystemDesc -ne "Unknown") {
                if ($adapterData.RemoteSystemDesc -match "Cisco") { $capabilities.VendorsDetected += "Cisco" }
                elseif ($adapterData.RemoteSystemDesc -match "Arista") { $capabilities.VendorsDetected += "Arista" }
                elseif ($adapterData.RemoteSystemDesc -match "Juniper") { $capabilities.VendorsDetected += "Juniper" }
                elseif ($adapterData.RemoteSystemDesc -match "Dell") { $capabilities.VendorsDetected += "Dell" }
                elseif ($adapterData.RemoteSystemDesc -match "HP|Aruba") { $capabilities.VendorsDetected += "HP/Aruba" }
                elseif ($adapterData.RemoteSystemDesc -match "Mellanox|NVIDIA") { $capabilities.VendorsDetected += "Mellanox/NVIDIA" }
            }
        }
    }
    $capabilities.VendorsDetected = $capabilities.VendorsDetected | Select-Object -Unique
    return $capabilities
}

function Test-LLDPDcbxConfiguration {
    <#
    .SYNOPSIS
    Validates the DCBX configuration advertised by network switches for RoCE deployments.
    .DESCRIPTION
    This test checks for the presence of DCBX (ETS and PFC) TLVs, which are critical for RDMA over Converged Ethernet (RoCE).
    It will PASS if DCBX is consistently configured (all switches have it) or consistently not configured (no switches have it).
    It will FAIL with a WARNING if the configuration is partial (only ETS or PFC is found) or inconsistent across different switches.
    .PARAMETER OutputPath
    The directory path containing `MergedLLDPData.json`.
    .EXAMPLE
    Test-LLDPDcbxConfiguration -OutputPath "C:\Temp\LLDP_Logs"
    #>
    param (
        [string] $OutputPath
    )

    if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
        Log-Info "NetLldpAgent module is not installed. Skipping DCBX Configuration test."
        $skipResult = @{
            Name               = 'AzStackHci_LLDP_Test_DCBX_Configuration_Detection'
            Title              = 'DCBX Configuration Detection'
            DisplayName        = 'DCBX Configuration Detection (For RDMA/RoCE)'
            Severity           = 'INFORMATIONAL'
            Description        = 'NetLldpAgent module is not installed. Test skipped.'
            Tags               = @{}
            Remediation        = 'Install NetLldpAgent by running: Install-WindowsFeature Data-Center-Bridging, RSAT-DataCenterBridging-LLDP-Tools'
            TargetResourceID   = 'DCBXConfiguration'
            TargetResourceName = 'DCBXConfiguration'
            TargetResourceType = 'NetworkConfiguration'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source               = 'MergedLLDPData.json'
                Resource             = 'DCBXConfiguration'
                Detail               = 'NetLldpAgent module is not installed. Test was skipped.'
                Status               = 'SUCCESS'
                TimeStamp            = [datetime]::UtcNow
                FullDCBXSwitches     = ''
                PartialDCBXSwitches  = ''
                NoDCBXSwitches       = ''
                TotalSwitches        = 0
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return @(New-AzStackHciResultObject @skipResult)
    }

    $mergedLLDPJson = Join-Path -Path $OutputPath -ChildPath "MergedLLDPData.json"
    if (-Not (Test-Path -Path $mergedLLDPJson)) {
        Log-Info "MergedLLDPData.json not found. Previous LLDP tests may have been skipped or failed."
        $skipResult = @{
            Name               = 'AzStackHci_LLDP_Test_DCBX_Configuration_Detection'
            Title              = 'DCBX Configuration Detection'
            DisplayName        = 'DCBX Configuration Detection (For RDMA/RoCE)'
            Severity           = 'INFORMATIONAL'
            Description        = 'Prerequisite LLDP data not found. Test skipped.'
            Tags               = @{}
            Remediation        = 'Ensure previous LLDP tests complete successfully and NetLldpAgent is enabled on network adapters.'
            TargetResourceID   = 'DCBXConfiguration'
            TargetResourceName = 'DCBXConfiguration'
            TargetResourceType = 'NetworkConfiguration'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
                Source               = 'MergedLLDPData.json'
                Resource             = 'DCBXConfiguration'
                Detail               = 'MergedLLDPData.json not found. Previous tests may have been skipped.'
                Status               = 'SUCCESS'
                TimeStamp            = [datetime]::UtcNow
                FullDCBXSwitches     = ''
                PartialDCBXSwitches  = ''
                NoDCBXSwitches       = ''
                TotalSwitches        = 0
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        return @(New-AzStackHciResultObject @skipResult)
    }

    $mergedLLDPJsonObj = if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('MergedLLDPData')) {
        $script:LLDPDataCache['MergedLLDPData']
    } else {
        Get-Content -Path $mergedLLDPJson | ConvertFrom-Json
    }

    # Store the detected configuration state for each switch ('Full', 'Partial', 'None')
    $switchDcbxStatus = @{}

    foreach ($node in $mergedLLDPJsonObj.PSObject.Properties) {
        foreach ($adapter in $node.Value.PSObject.Properties) {
            $adapterValue = $adapter.Value
            $switchName = $adapterValue.RemoteSystemName
            if ($switchName -eq "Unknown" -or -not $switchName) { continue }

            $hasEts = $adapterValue.RemoteETS -ne "Not Advertised"
            $hasPfc = $adapterValue.RemotePFC -ne "Not Advertised"

            $currentStatus = 'None'
            if ($hasEts -and $hasPfc) {
                $currentStatus = 'Full'
            } elseif ($hasEts -or $hasPfc) {
                $currentStatus = 'Partial'
            }

            # If a switch is ever marked 'Partial', its status is locked in as 'Partial'.
            # This prevents a good link from overwriting a bad link's status for the same switch.
            if ($switchDcbxStatus.ContainsKey($switchName)) {
                if ($switchDcbxStatus[$switchName] -ne 'Partial') {
                    $switchDcbxStatus[$switchName] = $currentStatus
                }
            } else {
                $switchDcbxStatus[$switchName] = $currentStatus
            }
        }
    }

    $fullDcbxSwitches = $switchDcbxStatus.Keys | Where-Object { $switchDcbxStatus[$_] -eq 'Full' }
    $partialDcbxSwitches = $switchDcbxStatus.Keys | Where-Object { $switchDcbxStatus[$_] -eq 'Partial' }
    $noDcbxSwitches = $switchDcbxStatus.Keys | Where-Object { $switchDcbxStatus[$_] -eq 'None' }

    # Build detailed message for the report
    $TestDetailMsg = @("DCBX TLV Detection Summary:")
    $TestDetailMsg += "========================="
    if ($fullDcbxSwitches) { $TestDetailMsg += "[INFO] Full DCBX Support (ETS & PFC) detected on switches: $($fullDcbxSwitches -join ', ')." }
    if ($partialDcbxSwitches) { $TestDetailMsg += "[WARNING] Partial DCBX Support detected on switches: $($partialDcbxSwitches -join ', ')." }
    if ($noDcbxSwitches) { $TestDetailMsg += "[WARNING] No DCBX Support detected on switches: $($noDcbxSwitches -join ', '). DCBX must be configured and advertised via LLDP for RoCE/RDMA deployments." }

    # Determine the final test status and severity
    $TestStatus = 'SUCCESS'
    $TestSeverity = 'INFORMATIONAL'
    $remediation = "If using RoCE/RDMA, ensure both ETS and PFC are fully configured on all switches. If using standard TCP/IP networking, no action is needed."

    if ($partialDcbxSwitches.Count -gt 0) {
        $TestStatus = 'SUCCESS'
        $TestSeverity = 'INFORMATIONAL'
        $TestDetailMsg += "`n`nRESULT: Failure due to partial DCBX configuration. This will prevent RoCE from functioning correctly."
        $remediation = "The switches $($partialDcbxSwitches -join ', ') are advertising an incomplete DCBX configuration. For RoCE/RDMA to function, both ETS and PFC TLVs must be advertised. Please check the switch configuration for these devices."
    } elseif ($fullDcbxSwitches.Count -gt 0 -and $noDcbxSwitches.Count -gt 0) {
        $TestStatus = 'SUCCESS'
        $TestSeverity = 'INFORMATIONAL'
        $TestDetailMsg += "`n`nRESULT: Failure due to inconsistent DCBX configuration across switches."
        $remediation = "Your switches are inconsistently configured. Switches '$($fullDcbxSwitches -join ', ')' are advertising full DCBX, while switches '$($noDcbxSwitches -join ', ')' are not. For a stable RoCE/RDMA deployment, all switches in the fabric should have the same DCBX configuration."
    } elseif ($noDcbxSwitches.Count -gt 0 -and $fullDcbxSwitches.Count -eq 0 -and $partialDcbxSwitches.Count -eq 0) {
        # All switches have no DCBX - generate WARNING
        $TestStatus = 'SUCCESS'
        $TestSeverity = 'INFORMATIONAL'
        $TestDetailMsg += "`n`nRESULT: Warning - No DCBX configuration detected on any switches."
        $TestDetailMsg += "`nDCBX (Data Center Bridging Exchange) configuration is not being advertised via LLDP from any connected switches."
        $remediation = "DCBX configuration has not been detected from switches: $($noDcbxSwitches -join ', '). " +
                      "If you plan to use RoCE/RDMA, you must configure and enable DCBX on your switches with both ETS (Enhanced Transmission Selection) and PFC (Priority Flow Control). " +
                      "Ensure your switches are configured to advertise DCBX TLVs via LLDP. This typically involves: " +
                      "1) Enabling DCBX on the switch, 2) Configuring ETS bandwidth allocation, 3) Configuring PFC for lossless priorities, " +
                      "4) Ensuring LLDP is enabled with DCBX TLV advertisement. Consult your switch vendor documentation for specific commands."
    } else {
        $TestDetailMsg += "`n`nRESULT: Success. The detected DCBX configuration is consistent across all switches (fully enabled on all switches)."
    }

    $TestRstObject = @{
        Name               = 'AzStackHci_LLDP_Test_DCBX_Configuration_Detection'
        Title              = 'DCBX Configuration Detection'
        DisplayName        = 'DCBX Configuration Detection (For RDMA/RoCE)'
        Severity           = $TestSeverity
        Description        = 'Detects if switches advertise DCBX (ETS+PFC) configuration required for lossless Ethernet and RDMA/RoCE deployments.'
        Tags               = @{}
        Remediation        = $remediation
        TargetResourceID   = 'DCBXConfiguration'
        TargetResourceName = 'DCBXConfiguration'
        TargetResourceType = 'NetworkConfiguration'
        Timestamp          = [datetime]::UtcNow
        Status             = $TestStatus
        AdditionalData     = @{
            Source               = 'MergedLLDPData.json'
            Resource             = 'DCBXConfiguration'
            Detail               = $TestDetailMsg -join "`n"
            Status               = $TestStatus
            TimeStamp            = [datetime]::UtcNow
            FullDCBXSwitches     = $fullDcbxSwitches -join ', '
            PartialDCBXSwitches  = $partialDcbxSwitches -join ', '
            NoDCBXSwitches       = $noDcbxSwitches -join ', '
            TotalSwitches        = $switchDcbxStatus.Count
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    return @(New-AzStackHciResultObject @TestRstObject)
}

function Test-LLDPAvailabilityZoneConnections {
    <#
    .SYNOPSIS
        Validates if network switch configurations are valid based on Availability Zones
    .DESCRIPTION
        This function performs two main checks for deployments configured with a 'RackAware' cluster pattern and multiple Availability Zones:
        1. Intra-Zone Consistency: Ensures all nodes within the same Availability Zone connect to the exact same set of switches.
        2. Cross-Zone Isolation: Ensures that nodes in different Availability Zones connect to completely separate sets of switches (no overlap).
    .PARAMETER ClusterPattern
        The cluster pattern specified in the deployment configuration (e.g., 'RackAware'). Validation is primarily relevant for 'RackAware'.
    .PARAMETER LocalAvailabilityZones
        An array of objects representing the defined local availability zones, each containing a name and a list of nodes.
    .PARAMETER OutputPath
        Path to the output directory containing Node2Switch.json and NodeName2Ip.json generated by previous LLDP tests.
    .NOTES
        Requires Node2Switch.json and NodeName2Ip.json to exist in the OutputPath.
        Generates WARNING level for configuration mismatches, allowing deployment to proceed.
    #>
    [CmdletBinding()]
    param (
        [System.String]
        $ClusterPattern,

        [array]
        $LocalAvailabilityZones,

        [System.String]
        $OutputPath
    )

    $TestResults = @()
    $availabilityZoneResults = @{}

    try {
        if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
            Log-Info "NetLldpAgent module is not installed. Skipping Availability Zone Connections test."
            $skipResult = @{
                Name               = 'AzStackHci_LLDP_Test_Availability_Zone_Connections'
                Title              = 'Availability Zone Connection Validation'
                DisplayName        = 'Availability Zone Connection Validation'
                Severity           = 'INFORMATIONAL'
                Description        = 'NetLldpAgent module is not installed. Test skipped.'
                Tags               = @{ ZoneValidation = 'Skipped' }
                Remediation        = 'Install NetLldpAgent by running: Install-WindowsFeature Data-Center-Bridging, RSAT-DataCenterBridging-LLDP-Tools'
                TargetResourceID   = 'AvailabilityZoneConnectionValidation'
                TargetResourceName = 'AvailabilityZoneConnectionValidation'
                TargetResourceType = 'AvailabilityZoneNetworkPolicy'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = $MyInvocation.MyCommand.Name
                    Resource  = 'AvailabilityZoneConnectionValidation'
                    Detail    = 'NetLldpAgent module is not installed. Test was skipped.'
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            return @(New-AzStackHciResultObject @skipResult)
        }

        $localZones = $LocalAvailabilityZones
        $clusterPattern = $ClusterPattern

        if (-not $PSBoundParameters.ContainsKey('ClusterPattern') -or -not $PSBoundParameters.ContainsKey('LocalAvailabilityZones')) {
            Log-Info "ClusterPattern or LocalAvailabilityZones parameters not provided. Skipping Availability Zone validation (Cluster Pattern Is Not RackAware)."
            return $TestResults
        }

        if ($null -eq $localZones -or $localZones.Count -eq 0) {
            Log-Info "No 'LocalAvailabilityZones' data provided. Skipping Availability Zone specific connection validation."
            return $TestResults
        }

        if ($null -eq $clusterPattern -or $clusterPattern -ne 'RackAware') {
            Log-Info "Cluster pattern is '$clusterPattern' (not 'RackAware'). Skipping Test"
            return $TestResults
        }

        if ($localZones.Count -lt 2) {
            Log-Info "Only one Availability Zone defined. Skipping cross-zone switch overlap check"
        }

        Log-Info "Starting Availability Zone Connection Validation."

        $node2SwitchJsonFile = Join-Path -Path $OutputPath -ChildPath "Node2Switch.json"
        $nodeName2IpJsonFile = Join-Path -Path $OutputPath -ChildPath "NodeName2Ip.json"
        if (-not (Test-Path -Path $node2SwitchJsonFile -PathType Leaf)) {
            $warnObj = @{
                Name               = 'AzStackHci_LLDP_Prerequisite_Missing_Node2Switch_File'
                Title              = 'Prerequisite File Missing for Availability Zone Validation'
                DisplayName        = 'Prerequisite File Missing for Availability Zone Validation'
                Severity           = 'INFORMATIONAL'
                Description        = "Node-to-switch mapping data not available. Network switches may not be advertising LLDP TLVs, or LLDP may be disabled on switch ports. Cannot perform Availability Zone connection validation."
                Tags               = @{ ZoneValidation = 'Prerequisite' }
                Remediation        = "Configure LLDP on ToR switches in each rack: (1) Enable LLDP transmission globally, (2) Enable System Name TLV (Type 5) with unique switch identifiers per rack, (3) Enable Chassis ID TLV (Type 1), (4) Enable Port ID TLV (Type 2). Verify LLDP is active on ports connected to cluster nodes. RackAware validation requires distinct switch identities to ensure proper rack isolation."
                TargetResourceID   = 'AvailabilityZoneConnectionValidation'
                TargetResourceName = 'Node2Switch.json'
                TargetResourceType = 'File'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = $MyInvocation.MyCommand.Name
                    Resource  = 'AvailabilityZoneConnectionValidation'
                    Detail    = "Node2Switch.json is missing, which is required for this validation."
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $TestResults += New-AzStackHciResultObject @warnObj
            Log-Info "Required file Node2Switch.json not found in '$OutputPath'. Skipping Availability Zone validation."
            return $TestResults
        }
        if (-not (Test-Path -Path $nodeName2IpJsonFile -PathType Leaf)) {
            $warnObj = @{
                Name               = 'AzStackHci_LLDP_Prerequisite_Missing_NodeName2Ip_File'
                Title              = 'Prerequisite File Missing for Availability Zone Validation'
                DisplayName        = 'Prerequisite File Missing for Availability Zone Validation'
                Severity           = 'INFORMATIONAL'
                Description        = "Node name to IP mapping not available. This indicates LLDP data collection did not complete. Network switches may not be advertising required TLVs."
                Tags               = @{ ZoneValidation = 'Prerequisite' }
                Remediation        = "Ensure 'Test-LLDPConnections' completes successfully and generated NodeName2Ip.json. Verify the OutputPath '$OutputPath'."
                TargetResourceID   = 'AvailabilityZoneConnectionValidation'
                TargetResourceName = 'NodeName2Ip.json'
                TargetResourceType = 'File'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = $MyInvocation.MyCommand.Name
                    Resource  = 'AvailabilityZoneConnectionValidation'
                    Detail    = "NodeName2Ip.json is missing, which is required for this validation."
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $TestResults += New-AzStackHciResultObject @warnObj
            Log-Info "Required file NodeName2Ip.json not found in '$OutputPath'. Skipping Availability Zone validation."
            return $TestResults
        }

        Log-Info "Loading data from Node2Switch.json and NodeName2Ip.json."
        $node2SwitchData = if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('Node2Switch')) {
            $script:LLDPDataCache['Node2Switch']
        } else {
            Get-Content $node2SwitchJsonFile -Raw | ConvertFrom-Json
        }
        $nodeName2IpMap = @{}
        if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('NodeName2Ip')) {
            $nodeName2IpMap = $script:LLDPDataCache['NodeName2Ip'].Clone()
            Log-Info "Successfully loaded NodeName to IP Map from cache."
        } else {
            $nodeName2IpObject = Get-Content $nodeName2IpJsonFile -Raw | ConvertFrom-Json
            if ($nodeName2IpObject) {
                foreach ($property in $nodeName2IpObject.PSObject.Properties) {
                    $nodeName2IpMap[$property.Name] = $property.Value
                }
                Log-Info "Successfully loaded NodeName to IP Map."
            } else {
                 Log-Info "NodeName2Ip.json file at '$nodeName2IpJsonFile' is empty or could not be parsed correctly."
                 return $TestResults
            }
        }

        $zoneSwitchSets = @{}
        $intraZoneFailures = @{}
        $crossZoneFailures = @()

        $intraZoneStatus = 'SUCCESS'
        $crossZoneStatus = 'SUCCESS'

        #TEST CASE 1: Intra-Zone Switch Isolation
        Log-Info "Starting Test Case 1: Intra-Zone Switch Consistency Validation."
        foreach ($zone in $localZones) {
            $zoneName = $zone.localAvailabilityZoneName
            if ([string]::IsNullOrWhiteSpace($zoneName)) {
                Log-Info "A zone with a null or empty name was found in the configuration data. Skipping it."
                continue
            }
            Log-Info "Validating Zone: '$zoneName'"
            $intraZoneFailures[$zoneName] = @()
            [string[]]$expectedSwitchSet = $null
            $firstNodeProcessed = $false

            if ($null -eq $zone.nodes -or $zone.nodes.Count -eq 0) {
                Log-Info "Zone '$zoneName' contains no nodes in the provided data. Skipping."
                $availabilityZoneResults[$zoneName] = [PSCustomObject]@{
                    ZoneName = $zoneName
                    Status = 'SKIPPED'
                    Messages = @("Zone definition contained no nodes.")
                    ExpectedSwitchSet = "N/A"
                }
                continue
            }

            foreach ($nodeName in $zone.nodes) {
                # Initialize variables for node lookup
                $nodeSwitchInfo = $null
                $nodeIdentifier = $null
                $nodeIp = $null
                
                # First, try to find switches using nodeName directly
                if ($node2SwitchData.PSObject.Properties.Name.Contains($nodeName)) {
                    $nodeSwitchInfo = $node2SwitchData.$nodeName
                    $nodeIdentifier = $nodeName
                    Log-Info "Found switch data for node '$nodeName' using node name directly."
                }
                # If not found by name, try to find using IP
                else {
                    # Look up the IP for this node
                    $nodeIp = $nodeName2IpMap[$nodeName]
                    if ($nodeIp -and $node2SwitchData.PSObject.Properties.Name.Contains($nodeIp)) {
                        $nodeSwitchInfo = $node2SwitchData.$nodeIp
                        $nodeIdentifier = $nodeIp
                        Log-Info "Found switch data for node '$nodeName' using IP '$nodeIp'."
                    }
                }
                
                # If still not found, log error and continue
                if ($null -eq $nodeSwitchInfo) {
                    $msg = if ($nodeIp) {
                        "Node '$nodeName' (IP: $nodeIp) in Zone '$zoneName' not found in Node2Switch data ($node2SwitchJsonFile). LLDP data might be missing or incomplete for this node."
                    } else {
                        "Node '$nodeName' in Zone '$zoneName' not found in Node2Switch data ($node2SwitchJsonFile). No IP mapping found in NodeName2Ip.json. LLDP data might be missing or incomplete for this node."
                    }
                    Log-Info "LLDP data lookup failed for a node in Zone '$zoneName'."
                    $intraZoneFailures[$zoneName] += $msg
                    $intraZoneStatus = 'SUCCESS'
                    if (-not $firstNodeProcessed) { $expectedSwitchSet = @("ERROR_NODE_LLDP_DATA_MISSING_FOR_$($nodeName)") }
                    continue
                }

                # Validate the switch info is not null or empty
                if ($nodeSwitchInfo.PSObject.Properties.Count -eq 0) {
                    $displayId = if ($nodeIp) { "'$nodeName' (IP: $nodeIp)" } else { "'$nodeName'" }
                    $msg = "Node $displayId in Zone '$zoneName' has null or empty switch data in Node2Switch data ($node2SwitchJsonFile). Unexpected format."
                    Log-Info "Node in Zone '$zoneName' has unexpected null switch data."
                    $intraZoneFailures[$zoneName] += $msg
                    $intraZoneStatus = 'SUCCESS'
                    if (-not $firstNodeProcessed) { $expectedSwitchSet = @("ERROR_NULL_SWITCH_DATA_FOR_$($nodeName)") }
                    continue
                }
                
                # Get the switch identifiers (keys) for the current node
                $currentNodeSwitches = ($nodeSwitchInfo.PSObject.Properties | Select-Object -ExpandProperty Name) | Sort-Object

                if (-not $firstNodeProcessed) {
                    $expectedSwitchSet = $currentNodeSwitches
                    $zoneSwitchSets[$zoneName] = $expectedSwitchSet
                    $firstNodeProcessed = $true
                    Log-Info "Zone '$zoneName': expected switch set established."
                } else {
                    if ($expectedSwitchSet -match "^ERROR_") {
                         Log-Info "Zone '$zoneName': Cannot compare node as the expected switch set could not be established due to previous errors."
                         continue
                    }

                    $comparison = Compare-Object -ReferenceObject $expectedSwitchSet -DifferenceObject $currentNodeSwitches -SyncWindow 0
                    if ($comparison) {
                        $intraZoneStatus = 'SUCCESS'
                        $missingSwitches = ($comparison | Where-Object SideIndicator -eq '<=').InputObject -join ', '
                        $extraSwitches = ($comparison | Where-Object SideIndicator -eq '=>').InputObject -join ', '
                        $displayId = if ($nodeIp) { "'$nodeName' (IP: $nodeIp)" } else { "'$nodeName'" }
                        $msg = "Node $displayId in Zone '$zoneName' has inconsistent switch connections."
                        if ($missingSwitches) { $msg += " Expected switches not found: [$missingSwitches]." }
                        if ($extraSwitches) { $msg += " Unexpected switches found: [$extraSwitches]." }
                        $msg += " Expected set from first node: [$($expectedSwitchSet -join ', ')]"

                        Log-Info "Node in Zone '$zoneName' has inconsistent switch connections. Ensure all nodes in the same zone are connected to same set of switches."
                        $intraZoneFailures[$zoneName] += $msg
                    }
                }
            }

            # Store results for this zone
            $zoneStatus = 'SUCCESS'
            if (-not $firstNodeProcessed -and $intraZoneFailures[$zoneName].Count -eq 0) {
                $zoneStatus = 'SUCCESS'
                if($null -eq $expectedSwitchSet) {$expectedSwitchSet = @("ERROR_NO_VALID_NODES_IN_ZONE")}
            } elseif ($intraZoneFailures[$zoneName].Count -eq 0 -and $firstNodeProcessed) {
                 $zoneStatus = 'SUCCESS'
            }

            $availabilityZoneResults[$zoneName] = [PSCustomObject]@{
                ZoneName          = $zoneName
                Status            = $zoneStatus
                Messages          = $intraZoneFailures[$zoneName]
                ExpectedSwitchSet = if($expectedSwitchSet -is [array]){$expectedSwitchSet -join ', '} else {$expectedSwitchSet}
            }
        }

        #TEST CASE 2: Cross-Zone Switch Isolation
        Log-Info "Starting Test Case 2: Cross-Zone Switch Isolation Validation."
        # Check if we have at least two zones with successfully determined switch sets
        $validZoneSwitchSets = $zoneSwitchSets.GetEnumerator() | Where-Object { $_.Value -ne $null -and $_.Value -notmatch "^ERROR_" } | Select-Object -Property Key, Value
        if ($validZoneSwitchSets.Count -ge 2) {
            $zoneNames = $validZoneSwitchSets.Key | Sort-Object
            for ($i = 0; $i -lt ($zoneNames.Count - 1); $i++) {
                for ($j = $i + 1; $j -lt $zoneNames.Count; $j++) {
                    $zoneA = $zoneNames[$i]
                    $zoneB = $zoneNames[$j]
                    $switchesA = $zoneSwitchSets[$zoneA]
                    $switchesB = $zoneSwitchSets[$zoneB]

                    # Find common switches (intersection)
                    if (($switchesA -is [array]) -and ($switchesB -is [array])) {
                        $overlap = Compare-Object -ReferenceObject $switchesA -DifferenceObject $switchesB -IncludeEqual -ExcludeDifferent -SyncWindow 0 | Select-Object -ExpandProperty InputObject

                        if ($overlap) {
                            $crossZoneStatus = 'SUCCESS'
                            $msg = "Switch overlap detected between Zone '$zoneA' (Switches: [$($switchesA -join ', ')]) and Zone '$zoneB' (Switches: [$($switchesB -join ', ')]). Shared switches: [$($overlap -join ', ')]. Zones should use distinct sets of switches in a RackAware clusyersn."
                            Log-Info "Switch overlap detected between Zone '$zoneA' and Zone '$zoneB'. This isn't recommended for RAC."
                            $crossZoneFailures += $msg
                        } else {
                            Log-Info "No switch overlap found between Zone '$zoneA' and Zone '$zoneB'."
                        }
                    } else {
                         Log-Info "Skipping overlap check between Zone '$zoneA' and Zone '$zoneB' due to invalid switch data format (expected array)."
                    }
                }
            }
        } else {
            Log-Info "Skipping cross-zone switch overlap check as fewer than two zones have complete and valid switch data."
        }


        #Generate Final Result Objects
        $intraZoneDetailMsg = "Intra-Zone Switch Consistency Check Results:`n"
        if ($availabilityZoneResults.Count -gt 0) {
            $intraZoneDetailMsg += ($availabilityZoneResults.Values | Format-Table -AutoSize | Out-String)
        } else {
             $intraZoneDetailMsg += "No zones processed or found."
        }


        $crossZoneDetailMsg = "Cross-Zone Switch Isolation Check Results:`n"
        if ($crossZoneFailures.Count -gt 0) {
            $crossZoneDetailMsg += ($crossZoneFailures -join "`n")
        } elseif ($localZones.Count -ge 2 -and $validZoneSwitchSets.Count -ge 2) {
            # Only report success if the check was actually performed
            $crossZoneDetailMsg += "No switch overlaps detected between different zones with valid data."
        } elseif ($localZones.Count -ge 2) {
             # Check was applicable but skipped due to lack of valid data
             $crossZoneDetailMsg += "Cross-zone Check skipped due to insufficient valid switch data from zones."
        } else {
            # Check was not applicable (fewer than 2 zones)
             $crossZoneDetailMsg += "Cross-zone Check not applicable (fewer than 2 zones defined)."
        }


        # Result for Intra-Zone Check
        $intraZoneResultObj = @{
            Name               = 'AzStackHci_LLDP_Test_Intra_Zone_Switch_Consistency'
            Title              = 'Validate Intra-Zone Switch Consistency (RackAware)'
            DisplayName        = 'Validate Intra-Zone Switch Consistency'
            Severity           = 'INFORMATIONAL'
            Description        = "Checks if all nodes within the same Availability Zone connect to the exact same set of switches, as expected in a RackAware pattern. Requires Node2Switch.json and NodeName2Ip.json."
            Tags               = @{ ZoneValidation = 'IntraZone' }
            Remediation        = "Ensure all nodes within a single zone (e.g., rack) are cabled identically to the same set of ToR switches. Verify LLDP is enabled and functioning correctly on all relevant host ports and switch ports. Check Node2Switch.json ($node2SwitchJsonFile) and NodeName2Ip.json ($nodeName2IpJsonFile) for details. Review detailed results." # Potentially use $lnTxt.IntraZoneRemediation
            TargetResourceID   = 'AllZones'
            TargetResourceName = 'IntraZoneSwitchConsistency'
            TargetResourceType = 'AvailabilityZoneNetworkPolicy'
            Timestamp          = [datetime]::UtcNow
            Status             = $intraZoneStatus
            AdditionalData     = @{
            Source      = $node2SwitchJsonFile
            Resource    = 'IntraZoneSwitchConsistency'
            Detail      = $intraZoneDetailMsg
            Status      = $intraZoneStatus
            TimeStamp   = [datetime]::UtcNow
            ZoneResults = ($availabilityZoneResults | ConvertTo-Json -Depth 10 -Compress)
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $TestResults += New-AzStackHciResultObject @intraZoneResultObj

        # Result for Cross-Zone Check
        if ($localZones.Count -ge 2) {
            $crossZoneResultObj = @{
                Name               = 'AzStackHci_LLDP_Test_Cross_Zone_Switch_Isolation'
                Title              = 'Validate Cross-Zone Switch Isolation (RackAware)'
                DisplayName        = 'Validate Cross-Zone Switch Isolation'
                Severity           = 'INFORMATIONAL'
                Description        = "Checks if different Availability Zones connect to completely distinct sets of switches, ensuring network isolation between zones (racks) as expected in a RackAware pattern. Requires Node2Switch.json."
                Tags               = @{ ZoneValidation = 'CrossZone' }
                Remediation        = "Ensure that nodes in different zones (e.g., racks) are connected to separate sets of ToR switches. There should be no shared switches between zones. Verify cabling and LLDP data. Check Node2Switch.json ($node2SwitchJsonFile) for details. Review detailed results."
                TargetResourceID   = 'AllZones'
                TargetResourceName = 'CrossZoneSwitchIsolation'
                TargetResourceType = 'AvailabilityZoneNetworkPolicy'
                Timestamp          = [datetime]::UtcNow
                Status             = $crossZoneStatus
                AdditionalData     = @{
                Source         = $node2SwitchJsonFile
                Resource       = 'CrossZoneSwitchIsolation'
                Detail         = $crossZoneDetailMsg
                Status         = $crossZoneStatus
                TimeStamp      = [datetime]::UtcNow
                ZoneSwitchSets = ($zoneSwitchSets | ConvertTo-Json -Depth 10 -Compress)
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $TestResults += New-AzStackHciResultObject @crossZoneResultObj
        }

        Log-Info "Finished Availability Zone Connection Validation."
        return $TestResults

    } catch {
        $errMsg = "An error occurred during Availability Zone Connection Validation: $($_.Exception.Message) - $($_.ScriptStackTrace)"
        Log-Info $errMsg

        # Create a generic error result for the function failure
        $errorObj = @{
            Name               = 'AzStackHci_LLDP_Test_Availability_Zone_Connection_Error'
            Title              = 'Availability Zone Connection Validation Failed'
            DisplayName        = 'Availability Zone Connection Validation Failed'
            Severity           = 'INFORMATIONAL'
            Description        = "An unexpected error occurred while performing the Availability Zone connection validation."
            Tags               = @{ ZoneValidation = 'Error' }
            Remediation        = "Review the error details and logs in '$OutputPath'. Check prerequisites like file existence and content format. Error: $($_.Exception.Message)"
            TargetResourceID   = 'AvailabilityZoneConnectionValidation'
            TargetResourceName = 'AvailabilityZoneConnectionValidation'
            TargetResourceType = 'AvailabilityZoneNetworkPolicy'
            Timestamp          = [datetime]::UtcNow
            Status             = 'SUCCESS'
            AdditionalData     = @{
            Source    = $MyInvocation.MyCommand.Name
            Resource  = 'AvailabilityZoneConnectionValidation'
            Detail    = $errMsg
            Status    = 'SUCCESS'
            TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $TestResults += New-AzStackHciResultObject @errorObj
        Log-Info "Finished Availability Zone Connection Validation."
        return $TestResults
    }
}

function Test-StandardClusterSwitchConsistency {
    <#
    .SYNOPSIS
        Validates switch consistency across nodes in a standard cluster deployment.
    
    .DESCRIPTION
        Verifies that all nodes in a standard cluster deployment connect to the same set of network switches
        based on LLDP data. This test helps ensure proper network configuration in standard deployments.
    
    .PARAMETER ClusterPattern
        Test only runs for Standard clusters.
    
    .PARAMETER PhysicalNodeList
        Array of physical node objects with Name to be validated.
    
    .PARAMETER OutputPath
        Directory containing the LLDP node-to-switch mapping files.
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.String]
        $ClusterPattern,
        
        [Parameter(Mandatory = $false)]
        [array]
        $PhysicalNodeList,
        
        [Parameter(Mandatory = $false)]
        [System.String]
        $OutputPath = (Get-Location).Path
    )
    
    $TestResults = @()
    $script:ErrorActionPreference = 'Stop'
    
    try {
        # Check if NetLldpAgent module is available
        if (-not (Get-Module -ListAvailable -Name NetLldpAgent)) {
            Log-Info "NetLldpAgent module is not installed. Skipping Standard Cluster Switch Consistency test."
            $skipResult = @{
                Name               = 'AzStackHci_LLDP_Test_Standard_Cluster_Switch_Consistency'
                Title              = 'Standard Cluster Switch Consistency Check'
                DisplayName        = 'Standard Cluster Switch Consistency'
                Severity           = 'INFORMATIONAL'
                Description        = 'NetLldpAgent module is not installed. Test skipped.'
                Tags               = @{ ClusterType = 'Standard'; Connectivity = 'Skipped' }
                Remediation        = 'Install NetLldpAgent by running: Install-WindowsFeature Data-Center-Bridging, RSAT-DataCenterBridging-LLDP-Tools'
                TargetResourceID   = 'StandardClusterSwitchConsistency'
                TargetResourceName = 'StandardClusterSwitchConsistency'
                TargetResourceType = 'ClusterNetworkPolicy'
                Timestamp          = [datetime]::UtcNow
                Status             = 'SUCCESS'
                AdditionalData     = @{
                    Source    = $MyInvocation.MyCommand.Name
                    Resource  = 'StandardClusterSwitchConsistency'
                    Detail    = 'NetLldpAgent module is not installed. Test was skipped.'
                    Status    = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                    BaselineNodeName = ''
                    ExpectedSwitchSet = ''
                    MismatchCount = 0
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            return @(New-AzStackHciResultObject @skipResult)
        }

        # Initial check for Standard cluster pattern
        Log-Info "Starting Standard Cluster Switch Consistency Validation."
        
        if ($ClusterPattern -eq 'RackAware') {
            Log-Info "Cluster pattern is 'RackAware'. Skipping test."
            $skipObj = @{ 
                Name = 'AzStackHci_LLDP_Test_Standard_Cluster_Switch_Consistency_Skipped'
                Title = 'Standard Cluster Switch Consistency Check'
                Status = 'SUCCESS'
                Severity = 'INFORMATIONAL'
                Description = "Test success as ClusterPattern is 'RackAware'."
            }
            $TestResults += New-AzStackHciResultObject @skipObj
            return $TestResults
        }
        
        # Check for prerequisites
        if ($null -eq $PhysicalNodeList -or $PhysicalNodeList.Count -eq 0) {
            Log-Info "PhysicalNodeList is empty. Skipping test."
            $skipObj = @{ 
                Name = 'AzStackHci_LLDP_Test_Standard_Cluster_Switch_Consistency_Skipped'
                Title = 'Standard Cluster Switch Consistency Check'
                Status = 'SUCCESS'
                Severity = 'INFORMATIONAL'
                Description = "Test success as PhysicalNodeList is empty."
            }
            $TestResults += New-AzStackHciResultObject @skipObj
            return $TestResults
        }
        
        if ([string]::IsNullOrEmpty($OutputPath)) {
            Log-Info "OutputPath is empty. Using current directory."
            $OutputPath = (Get-Location).Path
        }
        
        # Check prerequisite files
        $node2SwitchJsonFile = Join-Path -Path $OutputPath -ChildPath "Node2Switch.json"
        $nodeName2IpJsonFile = Join-Path -Path $OutputPath -ChildPath "NodeName2Ip.json"
        $ClusterPattern = 'Standard'
        
        if (-not (Test-Path -Path $node2SwitchJsonFile -PathType Leaf)) {
            $warnObj = @{
                Name = 'AzStackHci_LLDP_Prerequisite_Missing_Node2Switch_File_Standard'
                Title = 'Prerequisite File Missing for Switch Consistency Check'
                DisplayName = 'Missing Node2Switch.json'
                Severity = 'INFORMATIONAL'
                Description = "Node-to-switch mapping data not available. Network switches may not be advertising LLDP TLVs, or LLDP may be disabled on switch ports."
                Tags = @{ ClusterType = 'Standard'; Connectivity = 'Prerequisite' }
                Remediation = "Enable LLDP on all cluster-connected switches: (1) Configure LLDP transmission globally, (2) Enable System Name TLV with unique switch identifiers, (3) Enable Chassis ID and Port ID TLVs, (4) Verify LLDP is active on all cluster node ports. Standard clusters require all nodes to connect to the same set of switches for consistent network behavior."
                TargetResourceID = 'StandardClusterSwitchConsistency'
                TargetResourceName = 'Node2Switch.json'
                TargetResourceType = 'File'
                Timestamp = [datetime]::UtcNow
                Status = 'SUCCESS'
                AdditionalData = @{ 
                    Source = $MyInvocation.MyCommand.Name
                    Resource = 'StandardClusterSwitchConsistency'
                    Detail = "Node2Switch.json is missing."
                    Status = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource = $ENV:EnvChkrId
            }
            $TestResults += New-AzStackHciResultObject @warnObj
            Log-Info "Required file Node2Switch.json not found. Skipping test."
            return $TestResults
        }
        
        if (-not (Test-Path -Path $nodeName2IpJsonFile -PathType Leaf)) {
            $warnObj = @{
                Name = 'AzStackHci_LLDP_Prerequisite_Missing_NodeName2Ip_File_Standard'
                Title = 'Prerequisite File Missing for Switch Consistency Check'
                DisplayName = 'Missing NodeName2Ip.json'
                Severity = 'INFORMATIONAL'
                Description = "Node name to IP mapping not available. This indicates LLDP data collection did not complete. Network switches may not be advertising required TLVs."
                Tags = @{ ClusterType = 'Standard'; Connectivity = 'Prerequisite' }
                Remediation = "Verify Test-LLDPConnections completed successfully."
                TargetResourceID = 'StandardClusterSwitchConsistency'
                TargetResourceName = 'NodeName2Ip.json'
                TargetResourceType = 'File'
                Timestamp = [datetime]::UtcNow
                Status = 'SUCCESS'
                AdditionalData = @{ 
                    Source = $MyInvocation.MyCommand.Name
                    Resource = 'StandardClusterSwitchConsistency'
                    Detail = "NodeName2Ip.json is missing."
                    Status = 'SUCCESS'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource = $ENV:EnvChkrId
            }
            $TestResults += New-AzStackHciResultObject @warnObj
            Log-Info "Required file NodeName2Ip.json not found. Skipping test."
            return $TestResults
        }
        
        # Load data
        Log-Info "Loading LLDP data files."
        $node2SwitchData = if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('Node2Switch')) {
            $script:LLDPDataCache['Node2Switch']
        } else {
            Get-Content $node2SwitchJsonFile -Raw | ConvertFrom-Json
        }
        $nodeName2IpMap = @{}
        if ($script:LLDPDataCache -and $script:LLDPDataCache.ContainsKey('NodeName2Ip')) {
            $nodeName2IpMap = $script:LLDPDataCache['NodeName2Ip'].Clone()
            Log-Info "Successfully loaded node to IP mapping from cache."
        } else {
            $nodeName2IpObject = Get-Content $nodeName2IpJsonFile -Raw | ConvertFrom-Json
            if ($nodeName2IpObject) {
                foreach ($property in $nodeName2IpObject.PSObject.Properties) {
                    $nodeName2IpMap[$property.Name] = $property.Value
                }
                Log-Info "Successfully loaded node to IP mapping."
            } else {
                Log-Info "NodeName2Ip.json file is empty or invalid."
                return $TestResults
            }
        }
        
        # Core validation logic
        # Pass 1: Collect switch data for all nodes and find the best baseline
        # (the node with the MOST switch connections, which represents the most
        # complete LLDP data and the expected cabling topology).
        $mismatchDetails = @()
        $overallStatus = 'SUCCESS'
        $nodeSwitchMap = [ordered]@{}

        Log-Info "Checking switch consistency across nodes."
        foreach ($node in $PhysicalNodeList) {
            $nodeName = $node.Name
            if (-not $nodeName) {
                Log-Info "Node entry without a 'Name' property found. Skipping."
                $mismatchDetails += "Skipped node entry missing 'Name' property."
                continue
            }

            $nodeSwitchInfo = $null
            $nodeIp = $null

            # Try to find switches using nodeName directly
            if ($node2SwitchData.PSObject.Properties.Name.Contains($nodeName)) {
                $nodeSwitchInfo = $node2SwitchData.$nodeName
                Log-Info "Found switch data for node '$nodeName' using node name directly."
            }
            else {
                $nodeIp = $nodeName2IpMap[$nodeName]
                if ($nodeIp -and $node2SwitchData.PSObject.Properties.Name.Contains($nodeIp)) {
                    $nodeSwitchInfo = $node2SwitchData.$nodeIp
                    Log-Info "Found switch data for node '$nodeName' using IP '$nodeIp'."
                }
            }

            if ($null -eq $nodeSwitchInfo -or
                $null -eq $nodeSwitchInfo.PSObject.Properties -or
                $nodeSwitchInfo.PSObject.Properties.Count -eq 0) {
                Log-Info "Node '$nodeName' not found in switch data or has no switch connections."
                $nodeSwitchMap[$nodeName] = @()
                continue
            }

            $switches = @(($nodeSwitchInfo.PSObject.Properties | Select-Object -ExpandProperty Name) | Sort-Object)
            $nodeSwitchMap[$nodeName] = $switches
            Log-Info "Node '$nodeName' connected to $($switches.Count) switch(es): $($switches -join ', ')"
        }

        # Select baseline: the node with the most switch connections
        [string]$baselineNodeName = $null
        [string]$baselineNodeIp = $null
        $expectedSwitchSet = @()

        foreach ($entry in $nodeSwitchMap.GetEnumerator()) {
            if ($entry.Value.Count -gt $expectedSwitchSet.Count) {
                $expectedSwitchSet = $entry.Value
                $baselineNodeName = $entry.Key
                $baselineNodeIp = $nodeName2IpMap[$entry.Key]
            }
        }

        if (-not $baselineNodeName -or $expectedSwitchSet.Count -eq 0) {
            $msg = "Could not establish a baseline - no node has valid switch data."
            Log-Info $msg
            $mismatchDetails += $msg
        } else {
            Log-Info "Baseline established from node '$baselineNodeName' with $($expectedSwitchSet.Count) switch(es): $($expectedSwitchSet -join ', ')"

            # Pass 2: Compare all nodes against the baseline
            foreach ($entry in $nodeSwitchMap.GetEnumerator()) {
                $nodeName = $entry.Key
                $currentNodeSwitches = $entry.Value

                if ($nodeName -eq $baselineNodeName) {
                    continue
                }

                if ($currentNodeSwitches.Count -eq 0) {
                    $mismatchDetails += "Node '$nodeName' has no switch data (LLDP data may be incomplete)."
                    continue
                }

                $comparison = Compare-Object -ReferenceObject $expectedSwitchSet -DifferenceObject $currentNodeSwitches -SyncWindow 0
                if ($comparison) {
                    $missingSwitches = ($comparison | Where-Object SideIndicator -eq '<=').InputObject -join ', '
                    $extraSwitches = ($comparison | Where-Object SideIndicator -eq '=>').InputObject -join ', '
                    $msg = "Node '$nodeName' has inconsistent switch connections."
                    if ($missingSwitches) { $msg += " Missing: [$missingSwitches] (may be incomplete LLDP data)." }
                    if ($extraSwitches) { $msg += " Extra: [$extraSwitches]." }

                    Log-Info "Node '$nodeName' has inconsistent switch connections. Please see the generated report for more details"
                    $mismatchDetails += $msg
                } else {
                    Log-Info "Node '$nodeName' matches baseline switch set."
                }
            }
        }
        
        # Final checks are handled inline above (baseline selection and comparison)
        
        # Generate result object
        $finalSeverity = if ($overallStatus -eq 'SUCCESS') { 'INFORMATIONAL' } else { 'INFORMATIONAL' }
        $finalTitle = "Standard Cluster Switch Consistency"
        $finalDesc = "Validates that all nodes connect to the same set of network switches."
        
        $remediation = "Ensure all nodes are cabled identically to the same switches and LLDP is enabled on all ports."
        
        $detailMsg = "Switch Consistency Results:`n"
        if ($mismatchDetails.Count -gt 0) {
            $detailMsg += ($mismatchDetails -join "`n")
        } else {
            $detailMsg += "All nodes connect to the same set of switches: [$($expectedSwitchSet -join ', ')] (From node '$baselineNodeName')."
        }
        
        $resultObj = @{
            Name = 'AzStackHci_LLDP_Test_Standard_Cluster_Switch_Consistency'
            Title = $finalTitle
            DisplayName = 'Switch Consistency'
            Severity = $finalSeverity
            Description = $finalDesc
            Tags = @{ ClusterType = 'Standard'; Connectivity = 'SwitchConsistency' }
            Remediation = $remediation
            TargetResourceID = $ClusterPattern
            TargetResourceName = 'StandardClusterSwitchConsistency'
            TargetResourceType = 'ClusterNetworkPolicy'
            Timestamp = [datetime]::UtcNow
            Status = $overallStatus
            AdditionalData = @{
                Source = $node2SwitchJsonFile
                Resource = 'StandardClusterSwitchConsistency'
                Detail = $detailMsg
                Status = $overallStatus
                TimeStamp = [datetime]::UtcNow
                BaselineNodeName = $baselineNodeName
                ExpectedSwitchSet = if ($expectedSwitchSet -is [array]) { $expectedSwitchSet -join ', ' } else { $expectedSwitchSet }
                MismatchCount = $mismatchDetails.Count
            }
            HealthCheckSource = $ENV:EnvChkrId
        }
        $TestResults += New-AzStackHciResultObject @resultObj
        
        Log-Info "Switch consistency validation complete. Status: $overallStatus"
        return $TestResults
        
    } catch {
        $errMsg = "Error during switch consistency validation: $($_.Exception.Message)"
        Log-Info $errMsg
        
        # Create error result
        $errorObj = @{
            Name = 'AzStackHci_LLDP_Test_Standard_Cluster_Switch_Consistency_Error'
            Title = 'Switch Consistency Validation Error'
            DisplayName = 'Switch Consistency Error'
            Severity = 'INFORMATIONAL'
            Description = "An error occurred during switch consistency validation."
            Tags = @{ ClusterType = 'Standard'; Connectivity = 'Error' }
            Remediation = "Review error details: $($_.Exception.Message)"
            TargetResourceID = 'StandardClusterSwitchConsistency'
            TargetResourceName = 'StandardClusterSwitchConsistency'
            TargetResourceType = 'ClusterNetworkPolicy'
            Timestamp = [datetime]::UtcNow
            Status = 'SUCCESS'
            AdditionalData = @{ 
                Source = $MyInvocation.MyCommand.Name
                Resource = 'StandardClusterSwitchConsistency'
                Detail = $errMsg
                Status = 'SUCCESS'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource = $ENV:EnvChkrId
        }
        $TestResults += New-AzStackHciResultObject @errorObj
        return $TestResults
    } finally {
        $script:ErrorActionPreference = 'Continue'
    }
}

Export-ModuleMember -Function Clear-LLDPDataCache, Test-LLDPNbrTlvs, Test-MergedLLDPDataToJson, Test-LLDPConnections, Test-LLDPDcbxConfiguration, Test-LLDPAvailabilityZoneConnections, Export-MergedLLDPDataToJson, Test-StandardClusterSwitchConsistency
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCz4VlsvWY1Vr2M
# Ez2o1c1gpVKiX2a7G+Nx6sswr5Uv6KCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIEY/kosy
# oD8cVgGVh/uBgNO6ZrgwBXoHO1n6IQ/2GY5LMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAOqMztG2NOMSxCc7bM+XSKqc6dRgRqvSifctUhzca
# k1aaGzQDO2aCmjKGrdTOEEt02wfLImYTH426mnGPeivwTE+A15sz7Jnh6U1rCieE
# fAgaJ2gNdSujycfW+/ZDT044kds0SM0QmC/T7dcPtGpCctzZDDaWECB5+l9BOTYC
# n27iUpnOoupvGjsMHmUh4abXLvO+iswl4J8jJQYtQz6tznflamCaKgB4/dmYVECA
# 1aW+FVDh373nJyxm7IuWOPIJRndsVErUcLcPVvskZg2h+U6fTWX6BDvYz40e+suV
# G3KvEXNeVJME+GdajEoGqnMAnsu8U9G1pibit8QAyj9Lk6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAgRj+ZEwfnIEKvf4GbDkXei42jA4H1K8+KnJKT
# ed1lnQIGaefsSb9DGBMyMDI2MDUwMzE0MzExMC4wMzFaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAudly0taBwItssgxywzIZZ9b/z
# e/xSihyDsznAK68aNjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EION7vyOl
# PA1VqlEp0QIVGlNd8S5YWBnKj97LuTWHSO2vMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIgJOHm4Be5tI4AAQAAAiAwIgQgJ/zFE03B
# CfUpoXjUtBZKerlMmArdnX03kdlRHISH7mUwDQYJKoZIhvcNAQELBQAEggIAsq4H
# wXv63WFv+NSUaXf6vCKcVkwZTTheY6nPGPTTp4wiuiaMFsYhT0JcGf81mHfeNu8+
# QWTHjE5m2w5UGu0De0XywG+rDhD+3f6GSyd1OvJ6FkxsJD1IOb/2rnTZgFJ9p278
# eGDwHl2KqZxJ3RprdbPHF9wHT+7by95qIt0iiFIKNqmdhUnGsOzxVwBWd/DMEmOk
# 1oIbTRgoytcj0jOJeDRYGhCbXhXAyOWWH+s3kbKFmYpjTaUn9mpMDeLU8bH23Ds8
# M2/O9DYpuxx1rJRrvuRHe097wdpeDX7StfgwEMV3ryZkoJai71UdPrP3bojEZ9cX
# uO/6OnMQWUMiBkSK+/0kvsJzC7KWZVosjJ+8E1WF/LTWOzbRhdwLSFE8GIdlsmAe
# a1WC/Yanqfo6RssW4bk5hnPqJl1QLr5f5lh0YTPd2idVgnbf/F9+CDV3YdowxVzR
# JbZgz6n4Mqoj67pp27RNPUNXNbBpPa6FysSTk1HM+jyjwakvllHwlq5dca27WaYu
# N0R8SeXFWXlAqx2UUcWAiYoGd9k5xftsBMqpB5MVKc7V6/lQ7FsEjBp9ejraaKyu
# 4PYlYpmcxIln1zj/9KIIi4r0vb9B5nEE1dres/DvyYqYEcvX2BVkGA7HIp9K1m9P
# /mc6ygY7YIC1lHpTfV9hL+VY5i7vvhOZjjHY9dE=
# SIG # End signature block
