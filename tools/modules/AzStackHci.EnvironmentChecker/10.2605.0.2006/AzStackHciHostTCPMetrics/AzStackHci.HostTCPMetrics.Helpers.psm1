Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.HostTCPMetrics.Strings.psd1
function Export-ICMPFullMeshJSONReport {
    param (
        [System.Management.Automation.Runspaces.PSSession[]]$PSSession,    # Array of PSSession
        [string]$OutputPath,                                                # Local path for JSON report
        [string]$NICName                                                    # Host NIC Name
    )

    # Initialize a report object to store the results
    $report = @{}
    $hostIPs = @{ }

    # Retrieve all Ethernet adapters with IPv4 addresses from each host
    foreach ($session in $PSSession) {
        $hostname = $session.ComputerName
        $hostIPs[$hostname] = @{ }
        Log-Info "Retrieving IP addresses for host: $hostname"
        $ipAddresses = @(
            Invoke-Command -Session $session -ScriptBlock {
                Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match $using:NICName } | Select-Object ifIndex, InterfaceAlias, IPAddress
            }
        )

        if (-not $ipAddresses) {
            Log-Info "! No matching IP addresses found for $hostname"
            continue
        }
        # Filter for specific interfaces (Ethernet 3 and Ethernet 4) after retrieval
        foreach ($ip in $ipAddresses) {
            if ($ip.InterfaceAlias -and $ip.IPAddress) {
                $hostIPs[$hostname][$ip.InterfaceAlias] = $ip.IPAddress
            }
        }
    }
    Write-Progress $lnTxt.StartICMPTesting

    # Perform the full mesh ping test in a single loop
    foreach ($sourceSession in $PSSession) {
        $sourceHost = $sourceSession.ComputerName
        $sourceIPs = $hostIPs[$sourceHost]
        $report[$sourceHost] = @()

        foreach ($targetHost in $hostIPs.Keys) {
            if ($sourceHost -ne $targetHost) {  # Avoid self-pinging
                $targetIPs = $hostIPs[$targetHost]
                Log-Info "# Ping from host $sourceHost to host: $targetHost"

                foreach ($sourceIP in $sourceIPs.GetEnumerator()) {  # Loop through all source IPs
                    $sourceInterface = $sourceIP.Key
                    $sourceIPAddress = $sourceIP.Value

                    if ($targetIPs.ContainsKey($sourceInterface)) {
                        $targetIPAddress = $targetIPs[$sourceInterface]

                        try {
                            # Run ping command remotely on the source machine
                            $pingResult = Invoke-Command -Session $sourceSession -ScriptBlock {
                                param ($targetIP, $sourceIP)
                                $pingOutput = ping $targetIP -S $sourceIP -n 3 2>&1

                                # Ensure the ping output is not empty and contains "Average"
                                $pingMatch = $pingOutput | Select-String -Pattern "Average = (\d+)ms"

                                if ($pingMatch) {
                                    return [PSCustomObject]@{
                                        value = [int]$pingMatch.Matches.Groups[1].Value
                                    }
                                } else {
                                    return [PSCustomObject]@{
                                        value = -1
                                    }
                                }
                            } -ArgumentList $targetIPAddress, $sourceIPAddress -ErrorAction Stop

                            # Store only AvgPingRTT.value
                            $report[$sourceHost] += [PSCustomObject]@{
                                SourceHost      = $sourceHost
                                SourceIP        = $sourceIPAddress
                                SourceInterface = $sourceInterface
                                TargetHost      = $targetHost
                                TargetIP        = $targetIPAddress
                                TargetInterface = $targetInterface
                                AvgPingRTT      = $pingResult.value  # Extracting only the value
                            }

                            # Logging output
                            if ($pingResult.value -ne -1) {
                                Log-Info ($lnTxt.ICMPTestSuccess -f $sourceIPAddress, $targetIPAddress, $($pingResult.value))
                            } else {
                                Log-Info ($lnTxt.ICMPTestFail -f $sourceIPAddress, $targetIPAddress) -Type Warning
                            }
                        }
                        catch {
                            Log-Info "### Error pinging $targetIPAddress from $sourceIPAddress : $_" -Type Error
                        }
                    }
                }
            }
        }
    }

    # Save report as JSON
    $jsonReportPath = Join-Path -Path $OutputPath -ChildPath "ICMP_Full_Mesh_Report.json"
    if ($report -and $report.Keys.Count -gt 0) {
        $report | ConvertTo-Json -Depth 3 | Set-Content -Path $jsonReportPath
        Log-Info "ICMP Full Mesh Test Report saved to: $jsonReportPath"
    } else {
        Log-Info ($lnTxt.FailSaveICMPJSON) -Type Error
    }

    return [string]$jsonReportPath
}


function Test-FullMeshTCP {
    param (
        [System.Management.Automation.Runspaces.PSSession[]]$PSSession,
        [int]$Port,
        [string]$localToolPath,
        [string]$OutputPath,
        [string]$NICName
    )

    $TCPTestResults = @()

    if (-not $PSSession -or $PSSession.Count -eq 0) {
        $errorMsg = "No PSSession(s) provided to test."
        Log-Info $errorMsg -Type 'WARNING'
        $TCPTestRstObject = @{
            Name               = "HCI_Node_TCP_Connection_Test"
            Title              = 'Host TCP Connection Pre-check Failed'
            DisplayName        = 'Host TCP Connection Pre-check Failed'
            Severity           = 'Warning'
            Description        = $errorMsg
            Tags               = @{ }
            Remediation        = "Please provide valid PSSessions to the function."
            TargetResourceID   = 'HostTCPConnectionFailed'
            TargetResourceName = 'HostTCPConnectionFailed'
            TargetResourceType = 'HostTCPConnectionFailed'
            Timestamp          = [datetime]::UtcNow
            Status             = 'FAILURE'
            AdditionalData     = @{
                Source    = 'HostTCPConnectionValidation'
                Resource  = 'PSSession'
                Detail    = $errorMsg
                Status    = 'FAILURE'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $TCPTestResults += New-AzStackHciResultObject @TCPTestRstObject
        return $TCPTestResults
    }

    foreach ($Session in $PSSession) {
        if ($Session.State -ne 'Opened') {
            try {
                Connect-PSSession -Session $Session
            } catch {
                $PsSessionFail = "Failed to reconnect to $($Session.ComputerName): $($_.Exception.Message)"
                Log-Info $PsSessionFail -Type 'WARNING'
                $TCPTestRstObject = @{
                    Name               = "HCI_Node_TCP_Connection_Test"
                    Title              = "Failed to reconnect PSSession to $($Session.ComputerName)"
                    DisplayName        = "Failed to reconnect PSSession to $($Session.ComputerName)"
                    Severity           = 'Warning'
                    Description        = $PsSessionFail
                    Tags               = @{ }
                    Remediation        = "Ensure the host $($Session.ComputerName) is reachable and WinRM is configured correctly."
                    TargetResourceID   = $Session.ComputerName
                    TargetResourceName = $Session.ComputerName
                    TargetResourceType = 'Node'
                    Timestamp          = [datetime]::UtcNow
                    Status             = 'FAILURE'
                    AdditionalData     = @{
                        Source    = 'HostTCPConnectionValidation'
                        Resource  = $Session.ComputerName
                        Detail    = $PsSessionFail
                        Status    = 'FAILURE'
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $TCPTestResults += New-AzStackHciResultObject @TCPTestRstObject
                return $TCPTestResults
            }
        }
    }

    # Output the final report in JSON format
    if (-not $OutputPath) {
        $OutputPath = Get-Location
        Log-Info "OutputPath was empty. Using current directory: $OutputPath"
    }
    # Ensure the output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Create Raw Log File
    $LogFilePath = Join-Path $OutputPath "FullMeshTCPTest.log"
    if (Test-Path $LogFilePath) {
        Remove-Item $LogFilePath -Force
    }

    $PingReportPath = Export-ICMPFullMeshJSONReport -PSSession $PSSession -OutputPath $OutputPath -NICName $NICName

    # Validate JSON file
    if (Test-Path -Path $PingReportPath) {
        Log-Info "Found Full mesh ping test report saved at $PingReportPath"
    } else {
        Log-Info "Missing Full mesh ping test report." -Type Error
        return
    }

    # Read the JSON file
    $pingReportContent = Get-Content -Path $PingReportPath -Raw | ConvertFrom-Json

    $remoteToolPaths = @{}

    foreach ($session in $PSSession) {

    # Copy psping.exe to all hosts
        try {
            # Explicitly specify the destination to ensure consistency
            Copy-RemoteItem -SourcePath $localToolPath -PsSession $PSSession
            $tempPath = Invoke-Command -Session $session -ScriptBlock { $env:TEMP }

            $remoteToolPath = Join-Path -Path $tempPath (Split-Path -Leaf $localToolPath)
            $remoteToolPaths[$session.ComputerName] = $remoteToolPath
    
            # Verify the file exists on each remote machine
            $exists = Invoke-Command -Session $session -ScriptBlock {
                param($p) Test-Path -Path $p
            } -ArgumentList $remoteToolPath

            if (-not $exists) {
                $errorMsg = "psping.exe not found at $remoteToolPath on $($session.ComputerName) after copy attempt."
                Log-Info $errorMsg -Type 'WARNING'
                $TCPTestRstObject = @{
                    Name               = "HCI_Node_Tool_Deployment_Test"
                    Title              = "Failed to deploy psping.exe to $($session.ComputerName)"
                    DisplayName        = "Failed to deploy psping.exe to $($session.ComputerName)"
                    Severity           = 'Warning'
                    Description        = $errorMsg
                    Tags               = @{ }
                    Remediation        = "Ensure WinRM is configured correctly and there are no permission issues for copying files to the temp directory on $($session.ComputerName)."
                    TargetResourceID   = $session.ComputerName
                    TargetResourceName = $session.ComputerName
                    TargetResourceType = 'Node'
                    Timestamp          = [datetime]::UtcNow
                    Status             = 'FAILURE'
                    AdditionalData     = @{
                        Source    = 'ToolDeployment'
                        Resource  = $session.ComputerName
                        Detail    = $errorMsg
                        Status    = 'FAILURE'
                        TimeStamp = [datetime]::UtcNow
                    }
                    HealthCheckSource  = $ENV:EnvChkrId
                }
                $TCPTestResults += New-AzStackHciResultObject @TCPTestRstObject
                return $TCPTestResults
            }
            Log-Info "Verified psping.exe on $($session.ComputerName) at $remoteToolPath"
        } 
        catch {
            $errorMsg = "Failed to copy psping.exe to $($session.ComputerName): $($_.Exception.Message)"
            Log-Info $errorMsg -Type 'WARNING'
            $TCPTestRstObject = @{
                Name               = "HCI_Node_Tool_Deployment_Test"
                Title              = "Failed to deploy psping.exe to $($session.ComputerName)"
                DisplayName        = "Failed to deploy psping.exe to $($session.ComputerName)"
                Severity           = 'Warning'
                Description        = $errorMsg
                Tags               = @{ }
                Remediation        = "Ensure WinRM is configured correctly, check network connectivity, and verify permissions for copying files to the temp directory on $($session.ComputerName)."
                TargetResourceID   = $session.ComputerName
                TargetResourceName = $session.ComputerName
                TargetResourceType = 'Node'
                Timestamp          = [datetime]::UtcNow
                Status             = 'FAILURE'
                AdditionalData     = @{
                    Source    = 'ToolDeployment'
                    Resource  = $session.ComputerName
                    Detail    = $errorMsg
                    Status    = 'FAILURE'
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $TCPTestResults += New-AzStackHciResultObject @TCPTestRstObject
            return $TCPTestResults
        }
    }

    # Initialize report object to store results
    $report = @()

    # Accept EULA for psping on all remote machines
    foreach ($session in $PSSession) {
        Invoke-Command -Session $session -ScriptBlock {
            $localToolPath = Join-Path -Path $env:TEMP "psping.exe"
            if (Test-Path -Path $localToolPath) {
                & "$localToolPath" -accepteula
            }
        } > $null 2>&1
    }

    # Full mesh TCP test
    $latencyFlag = $true
    Write-Progress $lnTxt.StartTCPTesting
    foreach ($serverSession in $PSSession) {
        $serverHost = $serverSession.ComputerName

        $hostRecords = ($pingReportContent.PSObject.Properties | Where-Object { $_.Name -eq $serverHost }).Value
        if ($null -eq $hostRecords) {
            Log-Info "No data found for $serverHost"
            continue
        }

        $serverIPs = $hostRecords | Select-Object -ExpandProperty SourceIP -Unique
        Log-Info "Server IPs for ${serverHost}: $serverIPs"

        foreach ($serverIP in $serverIPs) {
            try {
                Write-Progress ($lnTxt.StartHostTCPServer -f $serverHost, $serverIP)
                Log-Info ($lnTxt.StartHostTCPServer -f $serverHost, $serverIP)
                Log-Info ($lnTxt.AddHostTCPFW -f $Port, $serverHost)
                Log-Info "[DEBUG] Starting psping server on ${serverHost}:${serverIP}:${Port}"
                Invoke-Command -Session $serverSession -ScriptBlock {
                    param ($serverIP, $Port)
                    $ruleName = "TmpAllowTCPPortForTesting"
    
                    # Construct the tool path locally on this remote machine
                    $localToolPath = Join-Path -Path $env:TEMP "psping.exe"
    
                    # Verify the tool exists
                    if (-not (Test-Path -Path $localToolPath)) {
                        throw "psping.exe not found at $localToolPath on $env:COMPUTERNAME"
                    }

                    # Step 1: Add firewall rule
                    try {
                        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Enabled True -ErrorAction Stop *>$null
                    } catch {
                        throw "Failed to create firewall rule '$ruleName' for port ${Port}: $($_.Exception.Message)"
                    }

                    # Step 2: Verify the rule was created and is enabled
                    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                    if (-not $rule -or $rule.Enabled -ne 'True') {
                        throw "Firewall rule '$ruleName' was not created or is not enabled."
                    }

                    # Step 3: Start the server tool
                    Push-Location (Split-Path -Path $localToolPath)
                    Start-Process -NoNewWindow -FilePath $localToolPath -ArgumentList "-s ${serverIP}:$Port -nobanner" *>$null
                    Pop-Location
                } -ArgumentList $serverIP, $Port -ErrorAction Stop
            }
            catch {
                $errorMsg = "Failed to start psping server on $serverHost ($serverIP): $($_.Exception.Message)"
                Log-Info $errorMsg -Type 'Warning'

                # Attempt to clean up resources on the server host in case of partial failure
                Invoke-Command -Session $serverSession -ScriptBlock {
                    Get-Process | Where-Object { $_.ProcessName -like "psping*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                    Remove-NetFirewallRule -DisplayName "TmpAllowTCPPortForTesting" -ErrorAction SilentlyContinue
                } -ErrorAction SilentlyContinue

                # Skip to the next server IP as tests cannot be performed
                continue
            }

            Start-Sleep -Seconds 5

            foreach ($clientSession in $PSSession) {
                $clientHost = $clientSession.ComputerName

                if ($clientHost -ne $serverHost) {

                    # Latency Test
                    $latencyMsg1 = "## Latency Test from client $clientHost to IP $serverIP on server $serverHost"
                    Write-Progress $latencyMsg1
                    Log-Info $latencyMsg1
                    Add-Content -Path $LogFilePath -Value $latencyMsg1

                    Try {
                        # Run the latency test
                        Log-Info "[DEBUG] Running psping client latency test from $clientHost to ${serverIP}:${Port}"
                        $latencyOutput = Invoke-Command -Session $clientSession -ScriptBlock {
                            param ($serverAddress, $Port)
    
                            # Construct the tool path locally on this remote machine
                            $localToolPath = Join-Path -Path $env:TEMP "psping.exe"
    
                            # Verify the tool exists
                            if (-not (Test-Path -Path $localToolPath)) {
                                throw "psping.exe not found at $localToolPath on $env:COMPUTERNAME"
                            }
    
                            Push-Location (Split-Path -Path $localToolPath)

                            # Run the remote tool and capture the output
                            $fullOutput = & $localToolPath -l 1m -n 5000 -h 5 "${serverAddress}:$Port" -nobanner
                            Pop-Location

                            # Filter the relevant latency data
                            $found = $false
                            $filteredOutput = @()
                            foreach ($line in $fullOutput) {
                                if ($line -match "TCP roundtrip latency statistics") { $found = $true }
                                if ($found) { $filteredOutput += $line }
                            }

                            if ($filteredOutput.Count -eq 0) {
                                throw $lnTxt.NetworkException
                            }

                            Write-Output $filteredOutput
                        } -ArgumentList $serverIP, $Port -ErrorAction Stop

                        # Log and display the output
                        $latencyOutput | Out-String | Add-Content -Path $LogFilePath
                        Log-Info "## Latency test completed successfully from $clientHost to $serverIP on server $serverHost."
                    }
                    Catch {
                        # Improved error logging with detailed information
                        $errorMsg = "## Latency test failed from $clientHost to $serverIP on server $serverHost. Reason: $($_.Exception.Message)"
                        Log-Info $errorMsg -Type Warning
                    }

                    # Bandwidth Test
                    $bwMsg1 = "## Bandwidth Test from client $clientHost to IP $serverIP on server $serverHost"
                    Write-Progress $bwMsg1
                    Log-Info $bwMsg1
                    Add-Content -Path $LogFilePath -Value $bwMsg1
                    Try {
                        # Run the bandwidth test
                        Log-Info "[DEBUG] Running psping bandwidth test from $clientHost to ${serverIP}:${Port}"
                        $bandwidthOutput = Invoke-Command -Session $clientSession -ScriptBlock {
                            param ($serverAddress, $Port)
    
                            # Construct the tool path locally on this remote machine
                            $localToolPath = Join-Path -Path $env:TEMP "psping.exe"
    
                            # Verify the tool exists
                            if (-not (Test-Path -Path $localToolPath)) {
                                throw "psping.exe not found at $localToolPath on $env:COMPUTERNAME"
                            }
    
                            Push-Location (Split-Path -Path $localToolPath)

                            # Execute the bandwidth test using the remote tool
                            $fullOutput = & $localToolPath -b -l 1m -n 5000 -h 5 "${serverAddress}:$Port" -nobanner
                            Pop-Location

                            # Process and filter the output for bandwidth statistics
                            $found = $false
                            $filteredOutput = @()
                            foreach ($line in $fullOutput) {
                                if ($line -match "TCP sender bandwidth statistics") { $found = $true }
                                if ($found) { $filteredOutput += $line }
                            }

                            # Handle missing bandwidth statistics
                            if ($filteredOutput.Count -eq 0) {
                                throw $lnTxt.NetworkException
                            }

                            Write-Output $filteredOutput
                        } -ArgumentList $serverIP, $Port -ErrorAction Stop

                        # Log and display the output
                        $bandwidthOutput | Out-String | Add-Content -Path $LogFilePath
                        Log-Info "## Bandwidth test completed successfully from $clientHost to $serverIP on server $serverHost."
                    }
                    Catch {
                        # Enhanced error message for clear diagnosis
                        $errorMsg = "## Bandwidth test failed from $clientHost to $serverIP on server $serverHost. Reason: $($_.Exception.Message)"
                        Log-Info $errorMsg -Type Warning
                    }

                    # Reset Value
                    $LatencyMinMS = $LatencyMaxMS = $LatencyAvgMS = $null
                    $BandwidthMinGBs = $BandwidthMaxGBs = $BandwidthAvgGBs = $null

                    # Extract latency min/max/avg
                    $latencyLine = $latencyOutput | Where-Object { $_ -match "Minimum = .*Maximum = .*Average =" }
                    if ($latencyLine -match "Minimum = ([\d.]+)ms, Maximum = ([\d.]+)ms, Average = ([\d.]+)ms") {
                        $LatencyMinMs = [decimal]$matches[1]
                        $LatencyMaxMs = [decimal]$matches[2]
                        $LatencyAvgMs = [decimal]$matches[3]
                    }

                    # Validation Use Case 1: Avg Latency is greater than 1ms then warning
                    if ($null -eq $LatencyAvgMS -or $LatencyAvgMS -ge 1) {
                        $latencyFlag = $false
                        $TCPTestFailStatusMsg += "`n TCP Latency Exceeds 1ms: Host $clientHost -> Host $serverHost IP $serverIP is $LatencyAvgMs ms!"
                    }

                    # Extract bandwidth min/max/avg (GB/s only)
                    $bandwidthLine = $bandwidthOutput | Where-Object { $_ -match "Minimum = .*Maximum = .*Average =" }
                    if ($bandwidthLine -match "Minimum\s*=\s*([\d.]+)\s*GB/s,\s*Maximum\s*=\s*([\d.]+)\s*GB/s,\s*Average\s*=\s*([\d.]+)\s*GB/s") {
                        $BandwidthMinGBs = [decimal]$matches[1]
                        $BandwidthMaxGBs = [decimal]$matches[2]
                        $BandwidthAvgGBs = [decimal]$matches[3]
                    }

                    # Save simplified result with GB/s and ms units hardcoded in property names
                    $report += [PSCustomObject]@{
                        SourceHost        = $clientHost
                        TargetHost        = $serverHost
                        TargetIP          = $serverIP
                        LatencyMinMs      = $LatencyMinMs
                        LatencyMaxMs      = $LatencyMaxMs
                        LatencyAvgMs      = $LatencyAvgMs
                        BandwidthMinGBs   = $BandwidthMinGBs
                        BandwidthMaxGBs   = $BandwidthMaxGBs
                        BandwidthAvgGBs   = $BandwidthAvgGBs
                    }

                }
            }

            # Stop the TCP server
            Invoke-Command -Session $serverSession -ScriptBlock {
                Get-Process | Where-Object { $_.ProcessName -like "psping*" } | Stop-Process -Force
                # Clean up firewall rule after the test
                Remove-NetFirewallRule -DisplayName "TmpAllowTCPPortForTesting"
            }
            Log-Info "Removing firewall rule on TCP port $Port on $serverHost"
            Log-Info "- Stopping TCP server on $serverHost..."
            Log-Info ($lnTxt.RemoveHostTCPFW -f $Port, $serverHost)
            Log-Info ($lnTxt.StopHostTCPServer -f $serverHost)
        }
    }

    # TCP JSON Report
    $jsonReportPath = Join-Path -Path $OutputPath -ChildPath "TCP_Full_Mesh_Report.json"
    Try {
        # Convert report to JSON and save it
        $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonReportPath -Encoding utf8
        # Success message
        Log-Info "TCP Full Mesh JSON Report saved at: $jsonReportPath"
    }
    Catch {
        Log-Info "Failed to save TCP Full Mesh JSON report: $_" -Type Error
    }

    # Raw Log File
    if (Test-Path $LogFilePath) {
        Log-Info "TCP Full Mesh Raw Log saved at: $LogFilePath"
    }else{
        Log-Info "Failed to save TCP Full Mesh Raw Log file: $_" -Type Error
    }

    # Validation Use Case 1: Avg Latency is greater than 1ms then warning
    if (-not $latencyFlag) {
        Log-Info $TCPTestFailStatusMsg -Type 'WARNING'
        $TCPTestRstObject = @{
            Name               = "HCI_Node_TCP_Latency_Test"
            Title              = 'Host TCP Latency Exceeds 1ms'
            DisplayName        = 'Host TCP Latency Exceeds 1ms'
            Severity           = 'Warning'
            Description        = $TCPTestFailStatusMsg
            Tags               = @{ }
            Remediation        = $lnTxt.TCPLatencyRemidation
            TargetResourceID   = 'HostTCPLatencyExceeds1Ms'
            TargetResourceName = 'HostTCPLatencyExceeds1Ms'
            TargetResourceType = 'HostTCPLatencyExceeds1Ms'
            Timestamp          = [datetime]::UtcNow
            Status             = 'FAILURE'
            AdditionalData     = @{
                Source    = 'HostTCPLatencyValidated'
                Resource  = 'TCP_Full_Mesh_Report.json'
                Detail    = $TCPTestFailStatusMsg
                Status    = 'FAILURE'
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }

        $TCPTestResults += New-AzStackHciResultObject @TCPTestRstObject
        return $TCPTestResults
    }

    $TCPTestSuccessStatusMsg = "All nodes meet the latency requirement."
    Log-Info $TCPTestSuccessStatusMsg -Type 'Info'

    $TCPTestRstObject = @{
        Name               = "HCI_Node_TCP_Latency_Test"
        Title              = 'Host TCP Latency Validation Passed'
        DisplayName        = 'Host TCP Latency Validation Passed'
        Severity           = 'INFO'
        Description        = 'All Nodes Meet The Latency Requirement'
        Tags               = @{ }
        Remediation        = ''
        TargetResourceID   = 'HostTCPLatencyValidated'
        TargetResourceName = 'HostTCPLatencyValidated'
        TargetResourceType = 'HostTCPLatencyValidated'
        Timestamp          = [datetime]::UtcNow
        Status             = 'SUCCESS'
        AdditionalData     = @{
            Source    = 'HostTCPLatencyValidated'
            Resource  = 'HostTCPLatencyValidated'
            Detail    = $TCPTestSuccessStatusMsg
            Status    = 'SUCCESS'
            TimeStamp = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    $TCPTestResults += New-AzStackHciResultObject @TCPTestRstObject
    return $TCPTestResults
}



# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBUFQCB96nktAgK
# 1QV/TbwNxiq/KXs/VW8uXU8udyufQaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIHBfP8S90JPgfgMOmlO0aWjv/GHUmaL5Cl8AC9iNOVWMMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAjaSy7vfVm9KgUZrZ7D30
# ID5ZGil4K6QX0qckhSe6mn/rzdPmXV1NPxFobZrQ2boasSrOJjOy/QhSfTxLN5L2
# lPqwEmSqBk/gJQPo42NYpDdZe0PqPCwc8KmBrVCWzo/O4rs86K97jco4KQDGp1nT
# jG1R9ea3HsEboLbRgg87i4bGK1AYHa5BV8+A3gC7QoC4HdX9AKJowKDOVQGsRF+c
# KQfG7LQK1D0BZY5JNmSFQ1yvOWLSb+oOIN8h9/WuH/lFSBAhzaaPh479a3+xglD4
# C53fUUvFFX+R6mKHG59xkpw+SC52wwBl6qvG8G9G1F5Wc8oF8u6NcBMGvqI4L8M2
# JKGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAA7UIDrQOVYXJvbaXZ
# rzYxK+XFQNeu7GNVz9ZgZqaurAIGaeuJ1G3MGBMyMDI2MDUwMzE0MzExMS41MTVa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACEtEIBjzKGE+qAAEAAAISMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxNVoXDTI2MTExMzE4
# NDgxNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAr0zToDkpWQtsZekS0cV0quDdKSTGkovvBaZH0OAIEi0O3CcO
# 77JiX8c4Epq9uibHVZZ1W/LoufE172vkRXO+QYNtWWorECJ2AcZQ10bpAltkhZNi
# XlVJ8L3QzhKgrXrmMkm2J+/g81U23JPcO4wXHEftonT3wpd//936rjmwxMm7Nkbs
# ygbJf+4AVBMNr4aMPQhBd76od0KMB6WrvyEGOOU0893OFufS5EDey4n44WgaxJE0
# Vnv3/OOvuOw5Kp1KPqjjYJ+L9ywLuBMtcDfLpNQO/h1eFEoMrbiEM67TOfNlXfxb
# Dz4MlsYvLioxgd2Xzey1QxrV1+i+JyVDJMiSe9gKOuzpiQQFE19DUPgsidyjLTzX
# EhSVLBlRor0eCVf7gC6Rfk8NY3rO2sggOL79vU5FuDKTh/sIOtcUHeHC42jBGB+t
# fdKC1KOBR+UlN9aOzg8mpUNI2FgqQvirVP9ppbeMUfvp2wA9voyTiRWvDgzCxo8x
# lJ1nscYTHIQrmkF9j/Ca0IDmt8fvOn64nnlJOGUYZYHMC1l0xtgkYTE1ESUqqkaw
# Kk7iqbxdnLyycS+dR+zaxPudMDLrQFz8lgfy9obk0D8HC2dzhWpYNn5hdkoPEzgC
# qQUOp8v3Qj/sd4anyupe5KoCkjABOP3yhSQ4W9Z+DrJnhM/rbsXC7oTv26cCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBRSBblSxb5cYKYOwvd/VfoXOfu33jAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAXnSAkmX79Rc7lxS1wOozXJ7V0ou5DntVcOJplIkD
# jvEN8BIQph4U+gSOLZuVReP/z9YdUiUkcPwL1PM245/kEX1EegpxNc8HDA6hKCHg
# 0ALNEcuxnGOlgKLokXfUer1D5hiW8PABM9R+neiteTgPaaRlJFvGTYvotc0uqGiE
# S5hMQhL8RNFhpS9RcIWHtnQGEnrdOUvCAhs4FeViawcmLTKv+1870c/MeTHi0QDd
# eR+7/Wg4qhkJ2k1iEHJdmYf8rIV0NRBZcdRTTdHee35SXP5neNCfAkjDIuZycRud
# 6jzPLCNLiNYzGXBswzJygj4EeSORT7wMvaFuKeRAXoXC3wwYvgIsI1zn3DGY625Y
# +yZSi8UNSNHuri36Zv9a+Q4vJwDpYK36S0TB2pf7xLiiH32nk7YK73Rg98W6fZ2I
# NuzYzZ7Ghgvfffkj4EUXg1E0EffY1pEqkbpDTP7h/DBqtzoPXsyw2MUh+7yvWcq2
# BGZSuca6CY6X4ioMuc5PWpsmvOOli7ARNA7Ab8kKdCc2gNDLacglsweZEc9/VQB6
# hls/b6Kk32nkwuHExKlaeoSVrKB5U9xlp1+c8J/7GJj4Rw7AiQ8tcp+WmfyD8KxX
# 2QlKbDi4SUjnglv4617R8+a/cDWJyaMt8279Wn7f2yMedN7kfGIQ5SZj66RdhdlZ
# Oq8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUA5VHBr4h00EN7jUdQ33SE+qbk/8CggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hPHgwIhgPMjAyNjA1MDMw
# MzE2MDhaGA8yMDI2MDUwNDAzMTYwOFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aE8eAIBADAKAgEAAgIqUwIB/zAHAgEAAgITfTAKAgUA7aKN+AIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQAob1ciAs9EnklvfxsjRuxn1EXgx4NOdLcKwO7r
# /m10QuGw3cDnK5jwhUNWdMeurIe4d2zoVwlJgrsFVTWv+nvZyWMlnmDEU98vaSfz
# 3JV2V0NV5kkFXpPHpgAfHt+9sECdSs0S5NBD1s6J01gk2n5kuYpvZxwhdnWuPgd2
# EU+7p6GemsEK6nFR0BnCQZuMemNqEoeAA9i+Vq9eMf7zaz7JPTPSDm+IhzYSvVNN
# KSqZoNx6r90e81uqbjDqpfPH8XKaD9ETB1R/lHk9ba4h9LiMKlS0pcn/hCfSXvlM
# DTtRk7xFgU16wGTho3HULYVtQGFdC6H06IGmCtpThd1CtjCeMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIS0QgGPMoYT6oA
# AQAAAhIwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgibqpdlvhw/l4FpIIbnpvH3QnJz3vdKFlClNE
# HXD7hVAwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBz+X5GvO7WngknH4BZ
# eYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIEIH62C3OysJpL+INwkKSZ
# fhuOdJ2Sj9gOYyp366y/mz5vMA0GCSqGSIb3DQEBCwUABIICAIAYGiyz2lTvJLtN
# C1v0v6hnRPQYIoN80cBU0+G0RO+CxwIq6CVxhQcojhGwZ5RJf7DhMvuUIIXm+793
# KnsU8cBrB4pM6GS2OcP+7VMSDYtiys96L3lxk4ZioiFNjlq7Zr9XB4PWAj/5HpPG
# wtQoDDFGvp3Y49zYXgY93/N0A6Rt7hnh3wkKPx9u6ahyIzgNCW2oIBA64Ipj2gO0
# XL2wBRl0Xse4OVFnLRWJF7Rzq5GNcCx/DHPv7FRSi7gksdBkXcPmxVqPgOxWe4w4
# dn99xg2RFmhOVfNfhwSxjvMBTQnHTtKdBrO6bkiz1++MdI4/II6aquIJT5Q5D7CP
# 2rCm8AH/teHZcdy8OzKomgTCcCALjFbQMWx2VFYkaL6JALURB6yQuUlXziCs0d+j
# My4CZYhLut90694lWO6e5sGExvdyLy1OH2QBUlMtkmFNSg6HC5hgRx0rfPAMRN1g
# Dx2vD2doTZ9ZO6OywhiBj9TQlqQXdvyIEqeK5puGQ/L8AhPXYtSxoMVZm1pxSirN
# wXo+wIYsYwHX7Ii8Wg9Fg5CGZe7LsxSAyW26GTTpTyCsbzRB3JdyV6/+2/neaQO9
# PkP+zAuv8pZk9JsOEmizf0N2JgCtpkFzjqpj+vCsloGGItoaXx4Z64HOM8llkYOk
# nNnBkSvKEZ1AFu82bWJD4k53xz2z
# SIG # End signature block
