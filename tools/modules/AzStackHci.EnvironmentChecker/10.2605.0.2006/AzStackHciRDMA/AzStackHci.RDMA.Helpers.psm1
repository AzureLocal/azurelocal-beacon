# Import required modules
Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.RDMA.Strings.psd1

#################################################################################################
# Helper Functions
#################################################################################################

function Get-CombinedAdapterInfo {
    <#
    .SYNOPSIS
        Internal helper to combine NetAdapter, RDMA, and IPv4 info with SMB Direct status.
    .DESCRIPTION
        Gets comprehensive information about network adapters including RDMA and SMB Direct status.
    .PARAMETER PSSession
        PowerShell session to run commands on. If not provided, runs locally.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession] $PSSession
    )

    # Determine target computer name
    $computerName = $env:COMPUTERNAME
    if ($PSSession) { $computerName = $PSSession.ComputerName }

    Write-Verbose "Gathering combined adapter info for '$computerName'..."

    try {
        $scriptBlock = {
            # Force IPv4 only for consistency
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ErrorActionPreference = 'Stop'

            # 1. Get all 'Up' NetAdapters (Base information)
            $netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            if (-not $netAdapters) {
                Write-Verbose "No 'Up' network adapters found on $($env:COMPUTERNAME)."
                return @()
            }
            Write-Verbose "Found $($netAdapters.Count) 'Up' NetAdapters on $($env:COMPUTERNAME)."

            # 2. Get all RDMA info, index by Name
            $rdmaInfoByName = @{}
            Get-NetAdapterRdma | ForEach-Object {
                if ($_.Name) {
                    if ($rdmaInfoByName.ContainsKey($_.Name)) { 
                        Write-Warning "Duplicate RDMA adapter name '$($_.Name)' found." 
                    }
                    $rdmaInfoByName[$_.Name] = $_
                } else {
                    # Try InterfaceDescription as a fallback key if Name is missing
                    $descKey = $_.InterfaceDescription
                    if ($descKey -and -not $rdmaInfoByName.ContainsKey($descKey)) {
                        Write-Warning "RDMA adapter object found without a Name property, using InterfaceDescription '$descKey' as key."
                         $rdmaInfoByName[$descKey] = $_
                    } else {
                         Write-Warning "RDMA adapter object found without a valid identifier. Skipping."
                    }
                }
            }
            Write-Verbose "Indexed $(@($rdmaInfoByName.Keys).Count) RDMA info entries."

            # 3. Get all *IPv4* IP addresses
            $ipAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                $_.AddressState -eq 'Preferred' -and
                $_.IPAddress -notlike '169.254.*' -and
                $_.IPAddress -ne '127.0.0.1'
            }
            # Group by InterfaceAlias for lookup
            $ipInfoByAlias = $ipAddresses | Group-Object InterfaceAlias -AsHashTable -AsString
            Write-Verbose "Indexed $($ipInfoByAlias.Count) InterfaceAliases with preferred IPv4 addresses."

            # 4. Check SMB Direct capability
            $smbClientConfig = Get-SmbClientConfiguration -ErrorAction SilentlyContinue
            $smbMultichannelEnabled = $smbClientConfig.EnableMultiChannel -eq $true
            
            # Check existing SMB connections using RDMA
            $rdmaConnectionsByInterface = @{}
            try {
                $smbMultichannelConnections = Get-SmbMultichannelConnection -ErrorAction SilentlyContinue
                foreach ($conn in $smbMultichannelConnections) {
                    if ($conn.ClientInterfaceIndex -and $conn.CurrentPathIsRdma) {
                        $rdmaConnectionsByInterface[$conn.ClientInterfaceIndex] = $true
                    }
                }
                Write-Verbose "Found $($rdmaConnectionsByInterface.Count) interfaces with active RDMA connections"
            }
            catch {
                Write-Verbose "Could not get SMB Multichannel connections: $_"
            }
            
            # Get Jumbo Packet/MTU settings
            $jumboPacketSettings = @{}
            try {
                $jumboProps = Get-NetAdapterAdvancedProperty -DisplayName "*Jumbo*" -ErrorAction SilentlyContinue
                foreach ($prop in $jumboProps) {
                    $jumboPacketSettings[$prop.Name] = $prop.DisplayValue
                }
            }
            catch {
                Write-Verbose "Could not get Jumbo Packet settings: $_"
            }

            # Check adapter speeds
            $adapterSpeeds = @{}
            try {
                $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
                foreach ($adapter in $adapters) {
                    if ($adapter.LinkSpeed -match "(\d+)\s*Gbps") {
                        $speedGbps = [int]$Matches[1]
                        $adapterSpeeds[$adapter.Name] = $speedGbps
                    }
                }
            }
            catch {
                Write-Verbose "Could not get adapter speeds: $_"
            }

            # 5. Check RDMA type for each adapter
            $rdmaTypeByName = @{}
            try {
                $ndTechProperties = Get-NetAdapterAdvancedProperty -DisplayName "*NetworkDirect Technology*" -ErrorAction SilentlyContinue
                foreach ($prop in $ndTechProperties) {
                    $adapterName = $prop.Name
                    if ($rdmaInfoByName.ContainsKey($adapterName)) {
                        $rdmaType = "Unknown"
                        
                        switch ($prop.DisplayValue) {
                            "RoCEv2" { $rdmaType = "RoCE" }
                            "RoCE" { $rdmaType = "RoCE" }
                            "iWARP" { $rdmaType = "iWARP" }
                            "InfiniBand" { $rdmaType = "InfiniBand" }
                            default { 
                                if ($prop.DisplayValue -and $prop.DisplayValue -ne "--") {
                                    $rdmaType = $prop.DisplayValue
                                }
                            }
                        }
                        
                        $rdmaTypeByName[$adapterName] = $rdmaType
                        Write-Verbose "Adapter '$adapterName' RDMA type: $rdmaType (from NetworkDirect Technology property)"
                    }
                }
            }
            catch {
                Write-Verbose "Could not determine RDMA types from advanced properties: $_"
            }

            # 6. Get DCB configuration for RoCE RDMA
            $dcbEnabled = $false
            $pfcEnabled = $false
            try {
                $dcbConfig = Get-NetQosPolicy -ErrorAction SilentlyContinue
                if ($dcbConfig) {
                    $dcbEnabled = $true
                }
                
                $pfcConfig = Get-NetQosFlowControl -ErrorAction SilentlyContinue
                if ($pfcConfig) {
                    $pfcEnabled = $true
                }
            }
            catch {
                Write-Verbose "Could not get DCB/PFC configuration: $_"
            }

            # 7. Combine information
            $combinedResults = [System.Collections.Generic.List[object]]::new()
            foreach ($adapter in $netAdapters) {
                $adapterName = $adapter.Name
                $adapterAlias = $adapter.ifAlias
                $adapterDesc = $adapter.InterfaceDescription
                $adapterIndex = $adapter.ifIndex
                $computerName = $adapter.PSComputerName
                if (-not $computerName) { $computerName = $env:COMPUTERNAME }

                # Find corresponding RDMA info
                $rdmaInfo = $null
                if ($rdmaInfoByName.ContainsKey($adapterName)) {
                    $rdmaInfo = $rdmaInfoByName[$adapterName]
                } elseif ($adapterDesc -and $rdmaInfoByName.ContainsKey($adapterDesc)) {
                     Write-Verbose "Found RDMA info by InterfaceDescription '$adapterDesc'."
                     $rdmaInfo = $rdmaInfoByName[$adapterDesc]
                }

                $isRdmaEnabled = $false
                $isRdmaOperational = $false
                $rdmaType = "None"
                if ($rdmaInfo) {
                    $isRdmaEnabled = $rdmaInfo.Enabled
                    if ($isRdmaEnabled) {
                        # Check OperationalState ONLY if Enabled is True
                        $rdmaOperationalState = (Get-NetAdapterRdma -Name $adapterName -ErrorAction SilentlyContinue).OperationalState
                        if ($rdmaOperationalState -eq 'Operational') {
                             $isRdmaOperational = $true
                        } else {
                             $isRdmaOperational = $false
                             Write-Verbose "Adapter '$adapterName': RDMA Enabled but OperationalState is '$rdmaOperationalState'."
                        }
                        
                        # Get RDMA type
                        if ($rdmaTypeByName.ContainsKey($adapterName)) {
                            $rdmaType = $rdmaTypeByName[$adapterName]
                        }
                    }
                }

                # Check if adapter is using SMB Direct (RDMA for SMB)
                $hasSmbDirectConnection = $false
                $supportsSmbDirect = $false

                if ($smbMultichannelEnabled -and $isRdmaEnabled -and $isRdmaOperational) {
                    $supportsSmbDirect = $true
                    
                    # Check if there's an active SMB Direct connection on this interface
                    if ($rdmaConnectionsByInterface.ContainsKey($adapterIndex)) {
                        $hasSmbDirectConnection = $true
                    }
                }

                # Get Jumbo Packet setting
                $jumboPacketSetting = "Unknown"
                if ($jumboPacketSettings.ContainsKey($adapterName)) {
                    $jumboPacketSetting = $jumboPacketSettings[$adapterName]
                }

                # Get adapter speed
                $adapterSpeedGbps = 0
                if ($adapterSpeeds.ContainsKey($adapterName)) {
                    $adapterSpeedGbps = $adapterSpeeds[$adapterName]
                }
                else {
                    if ($adapter.LinkSpeed -match "(\d+)\s*Gbps") {
                        $adapterSpeedGbps = [int]$Matches[1]
                    }
                }

                # Find corresponding IP info using InterfaceAlias
                $adapterIpObjects = @()
                if ($ipInfoByAlias.ContainsKey($adapterAlias)) {
                    $adapterIpObjects = $ipInfoByAlias[$adapterAlias]
                }

                # Create output object(s)
                if ($adapterIpObjects.Count -gt 0) {
                    # Create an entry for each valid IP found for this adapter
                    foreach ($ip in $adapterIpObjects) {
                        $combinedResults.Add(
                            [PSCustomObject]@{
                                PSComputerName       = $computerName
                                AdapterName          = $adapterName
                                ifAlias              = $adapterAlias
                                InterfaceIndex       = $adapter.ifIndex
                                InterfaceDescription = $adapterDesc
                                MacAddress           = $adapter.MacAddress
                                IPAddress            = $ip.IPAddress
                                PrefixLength         = $ip.PrefixLength
                                IPAddressState       = $ip.AddressState
                                Status               = $adapter.Status
                                LinkSpeed            = $adapter.LinkSpeed
                                SpeedGbps            = $adapterSpeedGbps
                                RDMAEnabled          = $isRdmaEnabled
                                RDMAOperational      = $isRdmaOperational
                                RDMAType             = $rdmaType
                                JumboPacketSetting   = $jumboPacketSetting
                                SMBMultichannelEnabled = $smbMultichannelEnabled
                                SupportsSMBDirect    = $supportsSmbDirect
                                HasActiveSMBDirect   = $hasSmbDirectConnection
                                RSSCapable           = $adapter.ReceiveSideScaling
                                DCBEnabled           = $dcbEnabled
                                PFCEnabled           = $pfcEnabled
                            }
                        )
                    }
                    Write-Verbose "Adapter '$adapterName' matched with $($adapterIpObjects.Count) IPv4 address(es)."
                } else {
                    # Still add the adapter info even if no *valid* IP was found
                    $combinedResults.Add(
                        [PSCustomObject]@{
                            PSComputerName       = $computerName
                            AdapterName          = $adapterName
                            ifAlias              = $adapterAlias
                            InterfaceIndex       = $adapter.ifIndex
                            InterfaceDescription = $adapterDesc
                            MacAddress           = $adapter.MacAddress
                            IPAddress            = $null
                            PrefixLength         = $null
                            IPAddressState       = $null
                            Status               = $adapter.Status
                            LinkSpeed            = $adapter.LinkSpeed
                            SpeedGbps            = $adapterSpeedGbps
                            RDMAEnabled          = $isRdmaEnabled
                            RDMAOperational      = $isRdmaOperational
                            RDMAType             = $rdmaType
                            JumboPacketSetting   = $jumboPacketSetting
                            SMBMultichannelEnabled = $smbMultichannelEnabled
                            SupportsSMBDirect    = $supportsSmbDirect
                            HasActiveSMBDirect   = $hasSmbDirectConnection
                            RSSCapable           = $adapter.ReceiveSideScaling
                            DCBEnabled           = $dcbEnabled
                            PFCEnabled           = $pfcEnabled
                        }
                    )
                    Write-Verbose "Adapter '$adapterName' had no matching preferred IPv4 addresses."
                }
            }

            return $combinedResults
        }

        if ($PSSession) {
            # Invoke remotely
            return Invoke-Command -Session $PSSession -ScriptBlock $scriptBlock -ErrorAction Stop
        } else {
            # Invoke locally
            return & $scriptBlock
        }
    } catch {
        Write-Error "Error in Get-CombinedAdapterInfo for node '$computerName': $_"
        throw "Failed to get combined adapter info from $computerName. Error: $_"
    }
}

function Get-RDMAEnabledNetworkAdapters {
    <#
    .SYNOPSIS
        Gets adapters with both RDMA and SMB Direct capability.
    .DESCRIPTION
        Returns a list of all network adapters that have RDMA enabled/operational 
        and are configured for SMB Direct.
    .PARAMETER PSSession
        PowerShell session(s) to run the command on.
    .PARAMETER RequireActiveSMBDirect
        If specified, only returns adapters that have active SMB Direct connections.
        If not specified, returns adapters that are capable of SMB Direct but may not
        have active connections yet.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession,
        
        [Parameter(Mandatory = $false)]
        [switch] $RequireActiveSMBDirect
    )
    
    $allResults = [System.Collections.Generic.List[object]]::new()
    $sessionsToProcess = @()
    if ($PSSession) { $sessionsToProcess = $PSSession } else { $sessionsToProcess = $null }

    if ($null -eq $sessionsToProcess) {
        # Local execution
        try {
            $combinedInfo = Get-CombinedAdapterInfo -ErrorAction Stop
            
            # Filter for RDMA Enabled, Operational, and SMB Direct capable
            $rdmaAdapters = $combinedInfo | Where-Object { 
                $_.RDMAEnabled -eq $true -and 
                $_.RDMAOperational -eq $true -and 
                $_.SupportsSMBDirect -eq $true -and
                (-not [string]::IsNullOrEmpty($_.IPAddress))
            }
            
            # Apply additional filter if RequireActiveSMBDirect is specified
            if ($RequireActiveSMBDirect) {
                $rdmaAdapters = $rdmaAdapters | Where-Object { $_.HasActiveSMBDirect -eq $true }
            }
            
            $allResults.AddRange($rdmaAdapters)
            
            if ($RequireActiveSMBDirect) {
                Write-Verbose "Local: Found $($rdmaAdapters.Count) adapters with active SMB Direct connections."
            } else {
                Write-Verbose "Local: Found $($rdmaAdapters.Count) RDMA+SMB Direct capable adapters."
            }
        } catch {
            Write-Error "Error getting RDMA/SMB Direct enabled adapters locally: $_"
            throw $_
        }
    } else {
        # Remote execution (loop through sessions)
        foreach ($singleSession in $sessionsToProcess) {
            $computerName = $singleSession.ComputerName
            try {
                $combinedInfo = Get-CombinedAdapterInfo -PSSession $singleSession -ErrorAction Stop
                
                # Filter for RDMA Enabled, Operational, and SMB Direct capable
                $rdmaAdapters = $combinedInfo | Where-Object { 
                    $_.RDMAEnabled -eq $true -and 
                    $_.RDMAOperational -eq $true -and 
                    $_.SupportsSMBDirect -eq $true -and
                    (-not [string]::IsNullOrEmpty($_.IPAddress))
                }
                
                # Apply additional filter if RequireActiveSMBDirect is specified
                if ($RequireActiveSMBDirect) {
                    $rdmaAdapters = $rdmaAdapters | Where-Object { $_.HasActiveSMBDirect -eq $true }
                }
                
                # Add PSComputerName if missing
                $rdmaAdapters | ForEach-Object { 
                    if (-not $_.PSComputerName) { $_.PSComputerName = $computerName } 
                }
                
                $allResults.AddRange($rdmaAdapters)
                
                if ($RequireActiveSMBDirect) {
                    Write-Verbose "Remote '$computerName': Found $($rdmaAdapters.Count) adapters with active SMB Direct connections."
                } else {
                    Write-Verbose "Remote '$computerName': Found $($rdmaAdapters.Count) RDMA+SMB Direct capable adapters."
                }
            } catch {
                Write-Error "Error getting RDMA/SMB Direct enabled adapters from '$computerName': $_"
                # Continue with other sessions
            }
        }
    }
    return $allResults
}

function Get-AllNetworkAdapters {
    <#
    .SYNOPSIS
        Gets all 'Up' adapters with RDMA status and valid IPv4 IPs.
    .DESCRIPTION
        Returns information about all network adapters that are 'Up'.
    .PARAMETER PSSession
        PowerShell session(s) to run the command on.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession
    )
    
    $allResults = [System.Collections.Generic.List[object]]::new()
    $sessionsToProcess = @()
    if ($PSSession) { $sessionsToProcess = $PSSession } else { $sessionsToProcess = $null }

    if ($null -eq $sessionsToProcess) {
        # Local execution
        try {
            $combinedInfo = Get-CombinedAdapterInfo -ErrorAction Stop
            $allResults.AddRange($combinedInfo)
            Write-Verbose "Local: Retrieved $($combinedInfo.Count) total 'Up' adapters with combined info."
        } catch {
            Write-Error "Error getting all adapters locally: $_"
            throw $_
        }
    } else {
        # Remote execution (loop through sessions)
        foreach ($singleSession in $sessionsToProcess) {
            $computerName = $singleSession.ComputerName
            try {
                $combinedInfo = Get-CombinedAdapterInfo -PSSession $singleSession -ErrorAction Stop
                # Add PSComputerName if missing
                $combinedInfo | ForEach-Object { 
                    if (-not $_.PSComputerName) { $_.PSComputerName = $computerName } 
                }
                $allResults.AddRange($combinedInfo)
                Write-Verbose "Remote '$computerName': Retrieved $($combinedInfo.Count) total 'Up' adapters with combined info."
            } catch {
                Write-Error "Error getting all adapters from '$computerName': $_"
                # Continue with other sessions
            }
        }
    }
    return $allResults
}

function Get-RDMAMultichannelConnections {
    <#
    .SYNOPSIS
        Gets SMB multichannel connections that are actively using RDMA.
    .DESCRIPTION
        Returns a list of all SMB multichannel connections where the current path is using RDMA.
    .PARAMETER PSSession
        PowerShell session(s) to run the command on.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]] $PSSession
    )

    try {
        $scriptBlock = {
            # Filter directly for connections *currently* using RDMA
            $connections = Get-SmbMultichannelConnection | Where-Object { $_.CurrentPathIsRdma -eq $true }
            Write-Verbose "Found $($connections.Count) SMB Multichannel connections actively using RDMA on $($env:COMPUTERNAME)."
            return $connections
        }

        if ($PSSession) {
            Write-Verbose "Executing Get-RDMAMultichannelConnections remotely on $($PSSession.ComputerName -join ', ')"
            return Invoke-Command -Session $PSSession -ScriptBlock $scriptBlock -ErrorAction Stop
        } else {
            Write-Verbose "Executing Get-RDMAMultichannelConnections locally on $($env:COMPUTERNAME)"
            $results = & $scriptBlock
            # Add PSComputerName if missing
            $localComputerName = $env:COMPUTERNAME
            return ($results | Select-Object *, @{
                Name='PSComputerName';
                Expression={ if($_.PSComputerName){$_.PSComputerName} else {$localComputerName} }
            })
        }
    }
    catch {
        Write-Error "Error getting RDMA SMB multichannel connections: $_"
        # Handle command not found error specifically
        if ($_.Exception.InnerException -is [System.Management.Automation.CommandNotFoundException] -or 
            $_.Exception -is [System.Management.Automation.CommandNotFoundException]) {
            Write-Warning "Get-SmbMultichannelConnection command not found. Cannot check RDMA multichannel status."
            return @()
        } else {
            throw $_
        }
    }
}

function Create-TestFileOnRemoteNode {
    <#
    .SYNOPSIS
        Creates a test file of specified size on a remote node.
    .DESCRIPTION
        Uses .NET methods to efficiently create a test file of specified size on a remote node.
    .PARAMETER PSSession
        PowerShell session to the remote node.
    .PARAMETER TestFilePath
        Path where the test file should be created on the remote node.
    .PARAMETER FileSizeGB
        Size of the test file in GB.
    .PARAMETER Force
        If specified, deletes and recreates the file if it already exists.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] $PSSession,

        [Parameter(Mandatory = $true)]
        [string] $TestFilePath,

        [Parameter(Mandatory = $false)]
        [int] $FileSizeGB = 10,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $computerName = $PSSession.ComputerName
    $fileSizeBytes = $FileSizeGB * 1GB

    Write-Verbose "Preparing to create test file '$TestFilePath' ($FileSizeGB GB) on '$computerName'."

    if (-not ($PSCmdlet.ShouldProcess("'$TestFilePath' ($FileSizeGB GB) on '$computerName'", "Create Test File"))) {
        Write-Warning "Test file creation skipped due to -WhatIf."
        return $false
    }

    try {
        # Check if file exists on remote node
        $fileExists = Invoke-Command -Session $PSSession -ScriptBlock {
            param($path)
            Test-Path $path -PathType Leaf
        } -ArgumentList $TestFilePath -ErrorAction Stop

        if ($fileExists -and -not $Force) {
            Write-Verbose "Test file '$TestFilePath' already exists on '$computerName'. Use -Force to overwrite."
            return $true # File exists and is usable
        }

        # Delete if exists and Force is specified
        if ($fileExists -and $Force) {
            Write-Verbose "Removing existing file at '$TestFilePath' on '$computerName'..."
            Invoke-Command -Session $PSSession -ScriptBlock {
                param($path)
                Remove-Item -Path $path -Force -ErrorAction Stop
            } -ArgumentList $TestFilePath
            Write-Verbose "Existing file removed."
        }

        # Create parent directory if needed
        $parentDir = Split-Path -Path $TestFilePath -Parent
        Write-Verbose "Ensuring directory '$parentDir' exists on '$computerName'."
        Invoke-Command -Session $PSSession -ScriptBlock {
            param($path)
            if (-not (Test-Path $path -PathType Container)) {
                Write-Verbose "Creating directory '$path'..."
                New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
            }
        } -ArgumentList $parentDir -ErrorAction Stop

        # Create the test file using .NET methods
        Write-Verbose "Creating '$TestFilePath' ($($FileSizeGB)GB) on '$computerName'..."
        $fileCreated = Invoke-Command -Session $PSSession -ScriptBlock {
            param($path, $sizeBytes)
            
            try {
                # Create an empty file first
                $fileStream = [System.IO.File]::Create($path)
                $fileStream.Close()
                $fileStream.Dispose()
                
                # Set the file size (creates a sparse file quickly)
                $fileStream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open)
                $fileStream.SetLength($sizeBytes)
                $fileStream.Close()
                $fileStream.Dispose()
                
                Write-Verbose "Created test file at '$path' with size $($sizeBytes/1GB) GB"
                return $true
            }
            catch {
                Write-Warning "Failed to create file using .NET: $_. Trying fallback method."
                
                try {
                    # Create an empty file
                    $newFile = New-Item -Path $path -ItemType File -Force
                    
                    # Create a 1MB block of zeroes for efficient writing
                    $blockSize = 1MB
                    $zeroBlock = New-Object byte[] $blockSize
                    
                    # Open the file for writing
                    $stream = [System.IO.File]::OpenWrite($path)
                    
                    # Calculate number of blocks needed
                    $fullBlocks = [Math]::Floor($sizeBytes / $blockSize)
                    $remainder = $sizeBytes % $blockSize
                    
                    # Write full blocks
                    Write-Verbose "Writing $fullBlocks blocks of $($blockSize/1MB) MB each..."
                    for ($i = 0; $i -lt $fullBlocks; $i++) {
                        $stream.Write($zeroBlock, 0, $blockSize)
                        
                        # Add progress indicator for large files
                        if ($i % 100 -eq 0) {
                            Write-Verbose "Wrote $($i * $blockSize / 1MB) MB of $($sizeBytes / 1MB) MB..."
                        }
                    }
                    
                    # Write remainder if any
                    if ($remainder -gt 0) {
                        $remainderBlock = New-Object byte[] $remainder
                        $stream.Write($remainderBlock, 0, $remainder)
                    }
                    
                    # Close and dispose the stream
                    $stream.Close()
                    $stream.Dispose()
                    
                    Write-Verbose "Successfully created test file using fallback method"
                    return $true
                }
                catch {
                    Write-Error "Failed with fallback method: $_"
                    return $false
                }
            }
        } -ArgumentList $TestFilePath, $fileSizeBytes

        # Verify the file exists
        $fileExistsAfter = Invoke-Command -Session $PSSession -ScriptBlock {
            param($path)
            Test-Path $path -PathType Leaf
        } -ArgumentList $TestFilePath -ErrorAction Stop

        if (-not $fileExistsAfter) {
            throw "Failed to create test file '$TestFilePath' on '$computerName'."
        }

        Write-Verbose "Successfully created test file on '$computerName'."
        return $true
    }
    catch {
        Write-Error "Error creating test file on '$computerName': $_"
        throw $_
    }
}

function Cleanup-TestFiles {
    <#
    .SYNOPSIS
        Removes test files created during testing.
    .DESCRIPTION
        Cleans up test files created on remote nodes during RDMA testing.
        Can handle single or multiple file paths per node.
    .PARAMETER Sessions
        PowerShell session(s) to the nodes for cleanup.
    .PARAMETER TestFilePaths
        Hashtable mapping computer names to test file paths (string or string array) to clean up.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.Runspaces.PSSession[]] $Sessions,

        [Parameter(Mandatory=$true)]
        [hashtable] $TestFilePaths
    )

    foreach ($session in $Sessions) {
        $computerName = $session.ComputerName
        if (-not $TestFilePaths.ContainsKey($computerName)) {
            Write-Verbose "No test files to clean up for node '$computerName'."
            continue
        }

        # Ensure we always work with an array, even if only one path was stored
        [array]$pathsToClean = $TestFilePaths[$computerName]

        if ($null -eq $pathsToClean -or $pathsToClean.Count -eq 0) {
            Write-Verbose "No valid file paths provided for node '$computerName'. Skipping."
            continue
        }

        foreach ($filePath in $pathsToClean) {
            if ([string]::IsNullOrWhiteSpace($filePath)) {
                Write-Verbose "Empty file path entry for node '$computerName'. Skipping this entry."
                continue
            }

            if ($PSCmdlet.ShouldProcess("'$filePath' on '$computerName'", "Remove Test File")) {
                try {
                    Write-Verbose "Removing test file '$filePath' on '$computerName'..."
                    Invoke-Command -Session $session -ScriptBlock {
                        param($path)
                        if (Test-Path $path -PathType Leaf) {
                            Remove-Item -Path $path -Force -ErrorAction Stop
                            Write-Verbose "Successfully removed file '$path'."
                        } else {
                            Write-Verbose "File '$path' not found or already removed."
                        }
                    } -ArgumentList $filePath -ErrorAction Stop
                } catch {
                    Write-Warning "Failed to remove test file '$filePath' on '$computerName': $_"
                }
            } else {
                 Write-Warning "Cleanup for '$filePath' on '$computerName' skipped due to -WhatIf."
            }
        }
    }
}

#################################################################################################
# RDMA Validator Functions
#################################################################################################

function Test-RDMAValidator_AdapterStatus {
    <#
    .SYNOPSIS
        Tests RDMA adapter status on nodes.
    .DESCRIPTION
        Validates that RDMA-capable network adapters are properly configured and operational.
    .PARAMETER Sessions
        PowerShell session(s) to the nodes to test.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]] $Sessions
    )

    $instanceResults = @()

    # Validate that instanceResults is properly initialized
    if ($null -eq $instanceResults) {
        $instanceResults = @()
    }

    # Set strict mode to catch any undefined variables
    Set-StrictMode -Version Latest

    # Get adapter info for all nodes
    $allAdapters = @()
    try {
        $allAdapters = Get-AllNetworkAdapters -PSSession $Sessions -ErrorAction Stop
    } catch {
        Write-Error "Failed to retrieve adapter information: $_"
        $collectionErrorResult = @{
            Name               = "AzStackHci_RDMA_Test_AdapterCollectionError"
            Title              = "RDMA Adapter Information Collection Error"
            DisplayName        = "RDMA Adapter Information Collection Error"
            Severity           = "CRITICAL"
            Description        = "Failed to retrieve network adapter information from one or more nodes."
            Remediation        = "Ensure all nodes are reachable via PowerShell Remoting and network adapter commands succeed."
            TargetResourceID   = "ClusterNodes"
            TargetResourceName = "NetworkAdapters"
            TargetResourceType = "Cluster"
            Timestamp          = [datetime]::UtcNow
            Status             = "FAILURE"
            AdditionalData     = @{ 
                Source     = "ClusterNodes"
                Resource   = "NetworkAdapters"
                Detail     = "Error during collection: $_"
                Status     = "FAILURE"
                TimeStamp  = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @collectionErrorResult
        return $instanceResults
    }

    # Group adapters by computer name
    $adaptersByNode = $allAdapters | Group-Object PSComputerName

    foreach ($nodeGroup in $adaptersByNode) {
        $computerName = $nodeGroup.Name
        $adaptersOnNode = $nodeGroup.Group
        Write-Verbose "Checking RDMA adapter status on '$computerName'..."

        if ($null -eq $adaptersOnNode -or $adaptersOnNode.Count -eq 0) {
            Write-Warning "No adapters found on '$computerName'."
            $noAdaptersResult = @{
                Name               = "AzStackHci_RDMA_Test_NoAdapterInfo"
                Title              = "RDMA Adapter Availability Check"
                DisplayName        = "RDMA Adapter Availability Check ($computerName)"
                Severity           = "WARNING"
                Description        = "No network adapter information available on this node."
                Remediation        = "Ensure the node was reachable during the check and network adapter commands succeed."
                TargetResourceID   = $computerName
                TargetResourceName = "NetworkAdapters"
                TargetResourceType = "Node"
                Timestamp          = [datetime]::UtcNow
                Status             = "FAILURE"
                AdditionalData     = @{ 
                    Source     = $computerName
                    Resource   = "NetworkAdapters"
                    Detail     = "No 'Up' adapters found."
                    Status     = "WARNING"
                    TimeStamp  = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @noAdaptersResult
            continue
        }

        # Filter for RDMA capable adapters
        $rdmaCapableAdapters = $adaptersOnNode | Where-Object { $_.RDMAEnabled -eq $true }

        if ($rdmaCapableAdapters.Count -eq 0) {
            Write-Warning "No RDMA-Enabled adapters found on '$computerName'."
            $rdmaNotFoundResult = @{
                Name               = "AzStackHci_RDMA_Test_NoRDMAAdapters"
                Title              = "RDMA adapter availability"
                DisplayName        = "RDMA adapter availability ($computerName)"
                Severity           = "WARNING"
                Description        = "No RDMA-capable network adapters that are enabled on this node."
                Remediation        = "Ensure RDMA-capable network adapters are installed and configured properly."
                TargetResourceID   = $computerName
                TargetResourceName = "RDMAAdapter"
                TargetResourceType = "NetworkAdapter"
                Timestamp          = [datetime]::UtcNow
                Status             = "FAILURE"
                AdditionalData     = @{ 
                    Source     = $computerName
                    Resource   = "RDMAAdapter"
                    Detail     = "No RDMA-Enabled adapters found among 'Up' adapters."
                    Status     = "WARNING"
                    TimeStamp  = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @rdmaNotFoundResult
        } else {
            Write-Verbose "Found $($rdmaCapableAdapters.Count) RDMA-Enabled adapters on '$computerName'."
        }

        # Check RDMA operational status for each adapter
        foreach ($adapter in $rdmaCapableAdapters) {
            $adapterName = $adapter.AdapterName
            $ifAlias = $adapter.ifAlias
            $ipAddress = $adapter.IPAddress
            $interfaceIndex = $adapter.InterfaceIndex

            Write-Verbose "Checking RDMA status for adapter '$adapterName' (IP: $ipAddress) on '$computerName'"

            $isOperational = $adapter.RDMAOperational

            $rdmaStatus = "FAILURE"
            $message = "RDMA is Enabled but NOT operational on adapter '$adapterName'."
            $severity = "CRITICAL"

            if ($isOperational) {
                $rdmaStatus = "SUCCESS"
                $message = "RDMA is Enabled and Operational on adapter '$adapterName'."
                $severity = "INFORMATIONAL"
            }

            $rdmaResult = @{
                Name               = "AzStackHci_RDMA_Test_AdapterOperationalStatus"
                Title              = "RDMA adapter operational status"
                DisplayName        = "RDMA operational status - $adapterName ($computerName)"
                Severity           = $severity
                Description        = "Checks if an RDMA-Enabled adapter is also RDMA-Operational."
                Remediation        = "If not operational, check network connectivity, switch configuration, and adapter drivers."
                TargetResourceID   = "$computerName/$adapterName"
                TargetResourceName = $adapterName
                TargetResourceType = "NetworkAdapter"
                Timestamp          = [datetime]::UtcNow
                Status             = $rdmaStatus
                AdditionalData     = @{
                    Source          = $computerName
                    Resource        = $adapterName
                    ifAlias         = $ifAlias
                    InterfaceIndex  = $interfaceIndex
                    IPAddress       = $ipAddress
                    Detail          = $message
                    Status          = $rdmaStatus
                    RDMAEnabled     = $adapter.RDMAEnabled
                    RDMAOperational = $isOperational
                    LinkSpeed       = $adapter.LinkSpeed
                    AdapterStatus   = $adapter.Status
                    TimeStamp       = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @rdmaResult
        }
    }

    return $instanceResults
}

function Test-RDMAValidator_MultichannelStatus {
    <#
    .SYNOPSIS
        Tests if SMB Multichannel connections are actively using RDMA.
    .DESCRIPTION
        Validates that there are active SMB Multichannel connections using RDMA.
    .PARAMETER Sessions
        PowerShell session(s) to the nodes to test.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]] $Sessions
    )

    $instanceResults = @()

    # Get connections for all nodes
    $allConnections = @()
    try {
        $allConnections = Get-RDMAMultichannelConnections -PSSession $Sessions
    } catch {
        Write-Error "Error retrieving SMB Multichannel connections: $_"
        $collectionErrorResult = @{
            Name               = "AzStackHci_RDMA_Test_MultichannelCollectionError"
            Title              = "SMB Multichannel Connection Collection Error"
            DisplayName        = "SMB Multichannel Connection Collection Error"
            Severity           = "CRITICAL"
            Description        = "Failed to retrieve SMB Multichannel connection information."
            Remediation        = "Ensure all nodes are reachable and Get-SmbMultichannelConnection command succeeds."
            TargetResourceID   = "ClusterNodes"
            TargetResourceName = "SMBMultichannel"
            TargetResourceType = "Cluster"
            Timestamp          = [datetime]::UtcNow
            Status             = "FAILURE"
            AdditionalData     = @{
                Source     = "ClusterNodes"
                Resource   = "SMBMultichannel"
                Detail     = "Error during collection: $_"
                Status     = "FAILURE"
                TimeStamp  = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @collectionErrorResult
        return $instanceResults
    }

    # Group connections by computer name
    $connectionsByNode = @{}
    if ($null -ne $allConnections -and $allConnections.Count -gt 0) {
        $connectionsByNode = $allConnections | Group-Object PSComputerName -AsHashTable -AsString
    }

    # Process each node session
    foreach ($session in $Sessions) {
        $computerName = $session.ComputerName
        Write-Verbose "Checking SMB Multichannel RDMA status on '$computerName'..."

        $nodeConnections = $null
        if ($connectionsByNode.ContainsKey($computerName)) {
            $nodeConnections = $connectionsByNode[$computerName]
        }

        # Determine result based on findings
        $resultStatus = "FAILURE"
        $resultSeverity = "WARNING"
        $resultDetail = "No active SMB Multichannel connections found using RDMA on this node."
        $resultName = "AzStackHci_RDMA_Test_NoActiveMultichannelRDMA"
        $resultTitle = "SMB Multichannel RDMA Usage Check"
        $resultDisplayName = "SMB Multichannel RDMA Usage ($computerName)"
        $resultRemediation = "Ensure RDMA is configured correctly and generate storage traffic to establish connections."
        $targetResourceName = "SMBMultichannel"
        $targetResourceType = "SMB"
        $connectionCount = 0
        $connectionDetails = @()

        if ($null -eq $nodeConnections) {
            # Check if command exists
            $commandExists = Invoke-Command -Session $session -ScriptBlock { 
                Get-Command Get-SmbMultichannelConnection -ErrorAction SilentlyContinue 
            } -ErrorAction SilentlyContinue
            
            if ($null -eq $commandExists) {
                $resultDetail = "Get-SmbMultichannelConnection command not found on this node."
                $resultSeverity = "INFORMATIONAL"
                $resultStatus = "NOTAPPLICABLE"
                $resultName = "AzStackHci_RDMA_Test_MultichannelCmdNotFound"
                $resultRemediation = "This check requires Get-SmbMultichannelConnection cmdlet (SMB 3.0 or later)."
            } else {
                $resultDetail = "No active SMB Multichannel connections found using RDMA on this node."
                # Keep Status as FAILURE/WARNING as we expect connections if RDMA is working
            }
        } elseif ($nodeConnections.Count -gt 0) {
            $resultStatus = "SUCCESS"
            $resultSeverity = "INFORMATIONAL"
            $resultDetail = "Found $($nodeConnections.Count) active SMB Multichannel connection(s) using RDMA."
            $resultName = "AzStackHci_RDMA_Test_ActiveMultichannelRDMA"
            $resultRemediation = "SMB Multichannel is actively using RDMA."
            $connectionCount = $nodeConnections.Count
            # Capture connection details
            $connectionDetails = $nodeConnections | Select-Object ServerName, ClientIPAddress, ServerIPAddress, ClientInterfaceIndex, ServerInterfaceIndex
        } else {
            # Command succeeded but returned 0 connections
            $connectionCount = 0
        }

        # Create result object
        $multichannelResult = @{
            Name               = $resultName
            Title              = $resultTitle
            DisplayName        = $resultDisplayName
            Severity           = $resultSeverity
            Description        = "Checks if any active SMB Multichannel connections are using RDMA on this node."
            Remediation        = $resultRemediation
            TargetResourceID   = $computerName
            TargetResourceName = $targetResourceName
            TargetResourceType = $targetResourceType
            Timestamp          = [datetime]::UtcNow
            Status             = $resultStatus
            AdditionalData     = @{
                Source          = $computerName
                Resource        = $targetResourceName
                Detail          = $resultDetail
                ConnectionCount = $connectionCount
                Status          = $resultStatus
                TimeStamp       = [datetime]::UtcNow
                Connections     = if ($connectionDetails.Count -gt 0) { $connectionDetails } else { $null }
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @multichannelResult
    }

    return $instanceResults
}

function Test-RDMAValidator_NodeCompatibility {
    <#
    .SYNOPSIS
        Tests RDMA technology compatibility between nodes.
    .DESCRIPTION
        Validates that all nodes with RDMA adapters are using the same RDMA technology.
    .PARAMETER Sessions
        PowerShell session(s) to the nodes to test. Requires at least 2 sessions.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]] $Sessions
    )

    $instanceResults = @()

    # Skip if fewer than two nodes
    if ($Sessions.Count -le 1) {
        Write-Verbose "Only one node provided, skipping RDMA node compatibility check."
        $skipResult = @{
            Name               = "AzStackHci_RDMA_Test_CompatibilitySkipped"
            Title              = "RDMA Node Compatibility Check"
            DisplayName        = "RDMA Node Compatibility Check"
            Severity           = "INFORMATIONAL"
            Description        = "Checks if RDMA technology is consistent across multiple nodes."
            Remediation        = "N/A"
            TargetResourceID   = "ClusterRDMACompatibility"
            TargetResourceName = "RDMACompatibility"
            TargetResourceType = "Cluster"
            Timestamp          = [datetime]::UtcNow
            Status             = "NOTAPPLICABLE"
            AdditionalData     = @{ 
                Source     = "Cluster"
                Resource   = "Compatibility"
                Detail     = "Skipped: Requires 2 or more nodes."
                Status     = "SKIPPED"
                TimeStamp  = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @skipResult
        return $instanceResults
    }

    Write-Verbose "Checking RDMA technology compatibility between nodes: $($Sessions.ComputerName -join ', ')"

    # Store technology per adapter
    $adapterTechnologies = @{}
    $errorsOccurred = $false
    $nodesWithNoRdma = [System.Collections.Generic.List[string]]::new()
    $nodesWithFetchErrors = [System.Collections.Generic.List[string]]::new()

    # Get all adapter info
    $allAdapters = @()
    try {
        $allAdapters = Get-AllNetworkAdapters -PSSession $Sessions -ErrorAction Stop
    } catch {
        Write-Error "Failed to retrieve adapter information: $_"
        $errorsOccurred = $true
    }

    # Group adapters by computer name
    $adaptersByNode = $allAdapters | Group-Object PSComputerName -AsHashTable -AsString

    foreach ($session in $Sessions) {
        $computerName = $session.ComputerName
        $adaptersOnNode = @()
        
        if ($adaptersByNode.ContainsKey($computerName)) {
            $adaptersOnNode = $adaptersByNode[$computerName]
        } else {
            Write-Verbose "No adapter data found for node '$computerName'."
            if (-not $nodesWithFetchErrors.Contains($computerName)) { 
                $nodesWithFetchErrors.Add($computerName) 
            }
            $errorsOccurred = $true
            continue
        }

        Write-Verbose "Getting RDMA adapter technology from '$computerName'..."

        # Filter for RDMA enabled adapters
        $rdmaAdaptersOnNode = $adaptersOnNode | Where-Object { $_.RDMAEnabled -eq $true }

        if ($rdmaAdaptersOnNode.Count -eq 0) {
            Write-Verbose "No RDMA-Enabled adapters found on '$computerName'."
            $nodesWithNoRdma.Add($computerName)
            continue
        }

        # Get technology for each RDMA adapter
        foreach ($adapter in $rdmaAdaptersOnNode) {
            $adapterName = $adapter.AdapterName
            $key = "$computerName/$adapterName"

            Write-Verbose "Checking RDMA technology for adapter '$adapterName' on '$computerName'..."
            try {
                $technologyInfo = Invoke-Command -Session $session -ScriptBlock {
                    param($adapterNameToUse)
                    # Try standard keyword
                    $tech = Get-NetAdapterAdvancedProperty -Name $adapterNameToUse -RegistryKeyword "*NetworkDirectTechnology" -ErrorAction SilentlyContinue

                    # Fallback for Mellanox
                    if (-not $tech) {
                        $tech = Get-NetAdapterAdvancedProperty -Name $adapterNameToUse -RegistryKeyword "*RoCE Mode" -ErrorAction SilentlyContinue
                        if ($tech) { Write-Verbose "Used fallback registry keyword '*RoCE Mode'" }
                    }

                    if ($tech -and $tech.DisplayValue) { return $tech.DisplayValue.Trim() }

                    # If not found, return "Unknown"
                    return "Unknown"
                } -ArgumentList $adapterName -ErrorAction Stop

                Write-Verbose "Adapter '$adapterName' on '$computerName' technology: '$technologyInfo'"
                # Map known values for better consistency
                switch -regex ($technologyInfo) {
                    'iWARP' { $adapterTechnologies[$key] = 'iWARP' }
                    'RoCEv[12]' { $adapterTechnologies[$key] = 'RoCE' }
                    'RoCE$' { $adapterTechnologies[$key] = 'RoCE' }
                    'InfiniBand' { $adapterTechnologies[$key] = 'InfiniBand'}
                    'Unknown' { $adapterTechnologies[$key] = 'Unknown' }
                    default {
                        Write-Warning "Unrecognized RDMA technology string '$technologyInfo'. Treating as 'Unknown'."
                        $adapterTechnologies[$key] = 'Unknown'
                    }
                }
            } catch {
                Write-Warning "Failed to get RDMA technology for adapter '$adapterName' on '$computerName': $_"
                $adapterTechnologies[$key] = "ErrorFetching"
                if (-not $nodesWithFetchErrors.Contains($computerName)) { 
                    $nodesWithFetchErrors.Add($computerName) 
                }
                $errorsOccurred = $true
            }
        }
    }

    # Analyze results
    $status = "FAILURE"
    $severity = "WARNING"
    $detail = ""
    $remediation = ""

    # Filter out Unknown/ErrorFetching
    $validTechnologiesFound = $adapterTechnologies.Values | Where-Object { 
        $_ -ne "Unknown" -and $_ -ne "ErrorFetching" 
    } | Select-Object -Unique

    $unknownCount = ($adapterTechnologies.Values | Where-Object { $_ -eq "Unknown" }).Count
    $errorCount = ($adapterTechnologies.Values | Where-Object { $_ -eq "ErrorFetching" }).Count

    if ($adapterTechnologies.Count -eq 0) {
        if ($errorsOccurred) {
            $status = "FAILURE"; $severity = "WARNING"
            $detail = "Could not perform compatibility check. Failed to retrieve adapter information."
            $remediation = "Review previous errors and ensure Get-NetAdapterAdvancedProperty works correctly."
        } elseif ($nodesWithNoRdma.Count -eq $Sessions.Count) {
            $status = "SUCCESS"; $severity = "INFORMATIONAL"
            $detail = "No RDMA-Enabled adapters were found on any nodes. Compatibility check skipped."
            $remediation = "N/A (No RDMA adapters detected)."
        } else {
            $status = "FAILURE"; $severity = "WARNING"
            $detail = "No RDMA-Enabled adapters with detectable technology found."
            if ($nodesWithNoRdma.Count -gt 0) { 
                $detail += " Nodes without RDMA adapters: $($nodesWithNoRdma -join ', ')." 
            }
            $remediation = "Verify RDMA adapters exist and are enabled."
        }
    } elseif ($validTechnologiesFound.Count -eq 1) {
        $status = "SUCCESS"; $severity = "INFORMATIONAL"
        $technology = $validTechnologiesFound[0]
        $detail = "All detected RDMA adapters use the same technology: '$technology'."
        $remediation = "All nodes use consistent RDMA technology ('$technology')."
        
        if ($unknownCount -gt 0 -or $errorCount -gt 0) {
            $detail += " (Note: Could not determine technology for some adapters)."
            $remediation = "Ensure consistent RDMA technology. Investigate adapters with unknown technology."
            $severity = "WARNING"
        }
    } elseif ($validTechnologiesFound.Count -gt 1) {
        $status = "FAILURE"; $severity = "CRITICAL"
        $detail = "INCONSISTENT RDMA technologies detected: $($validTechnologiesFound -join ', ')."
        $remediation = "All RDMA adapters must use the same technology. Mixing technologies is not supported."
    } else {
        $status = "FAILURE"; $severity = "WARNING"
        if ($errorsOccurred) {
            $detail = "Could not reliably determine RDMA technology consistency. Errors occurred during detection."
            $remediation = "Resolve errors encountered while querying adapter properties."
        } else {
            $detail = "RDMA-Enabled adapters were found, but their specific technology could not be determined."
            $remediation = "Manually verify RDMA technology using vendor tools."
        }
    }

    $compatibilityResult = @{
        Name               = "AzStackHci_RDMA_Test_TechnologyCompatibility"
        Title              = "RDMA technology compatibility"
        DisplayName        = "RDMA technology compatibility across nodes"
        Severity           = $severity
        Description        = "Checks if all nodes use the same RDMA technology (e.g. RoCE, iWARP)."
        Remediation        = $remediation
        TargetResourceID   = "ClusterRDMACompatibility"
        TargetResourceName = "RDMATechnology"
        TargetResourceType = "Cluster"
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source              = "ClusterNodes"
            Resource            = "RDMATechnology"
            Detail              = $detail
            DetectedTechnologies = if ($validTechnologiesFound.Count -gt 0) { $validTechnologiesFound } else { $null }
            AdapterTechMap      = $adapterTechnologies
            NodesWithoutRDMA    = ($nodesWithNoRdma -join ', ')
            NodesWithFetchErrors= ($nodesWithFetchErrors -join ', ')
            Status              = $status
            TimeStamp           = [datetime]::UtcNow
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }
    $instanceResults += New-AzStackHciResultObject @compatibilityResult

    return $instanceResults
}

function Get-DynamicRemoteS2DStoragePath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] $Session,
        
        [Parameter(Mandatory = $true)]
        [string] $RemoteNodeNameOrIP
    )

    try {
        $s2dVolumeInfo = Invoke-Command -Session $Session -ScriptBlock {
            # Find cluster shared volumes with S2D in the name
            $csvs = Get-ClusterSharedVolume | Where-Object { $_.Name -like "*-S2D*" }
            
            if ($null -eq $csvs -or $csvs.Count -eq 0) {
                Write-Verbose "No cluster shared volumes with S2D in the name found."
                return $null
            }
            
            # Select the first S2D volume found
            $selectedVolume = $csvs[0]
            Write-Verbose "Selected S2D volume: $($selectedVolume.Name)"
            
            # Extract volume name from cluster disk name
            if ($selectedVolume.Name -match '\((.*-S2D)\)') {
                $volumeName = $matches[1]
            } elseif ($selectedVolume.Name -match '.*-S2D') {
                $volumeName = $selectedVolume.Name
            } else {
                $volumeName = $selectedVolume.Name
            }
            
            # Construct the base storage path
            $basePath = "C:\ClusterStorage\$volumeName"
            
            # Find a subfolder containing "DiskIO" in the name
            $diskIOFolders = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -like "*DiskIO*" } | 
                Select-Object -First 1
            
            if ($diskIOFolders) {
                $diskIOPath = Join-Path -Path $basePath -ChildPath $diskIOFolders.Name
                Write-Verbose "Found DiskIO folder: $diskIOPath"
                
                # Check for the "data" hard disk image file
                $dataFile = Get-ChildItem -Path $diskIOPath -File -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -eq "data" -or $_.Name -eq "Data" -or $_.Name -eq "DATA" }
                
                if ($dataFile) {
                    Write-Verbose "Found 'data' file in DiskIO folder: $($dataFile.FullName)"
                }
                
                return @{
                    VolumeName = $volumeName
                    DiskIOFolder = $diskIOFolders.Name
                    LocalPath = $diskIOPath
                }
            } else {
                Write-Verbose "No DiskIO folder found, using base S2D volume path: $basePath"
                return @{
                    VolumeName = $volumeName
                    DiskIOFolder = $null
                    LocalPath = $basePath
                }
            }
        } -ErrorAction Stop
        
        if ($null -eq $s2dVolumeInfo) {
            Write-Verbose "No suitable S2D storage path found on $($Session.ComputerName)."
            return $null
        }
        
        # Construct the UNC path using C$ admin share instead of ClusterStorage
        if ($s2dVolumeInfo.DiskIOFolder) {
            $uncPath = "\\$RemoteNodeNameOrIP\C$\ClusterStorage\$($s2dVolumeInfo.VolumeName)\$($s2dVolumeInfo.DiskIOFolder)"
        } else {
            $uncPath = "\\$RemoteNodeNameOrIP\C$\ClusterStorage\$($s2dVolumeInfo.VolumeName)"
        }
        
        # Test the admin share path to verify access
        if (Test-Path $uncPath -ErrorAction SilentlyContinue) {
            Write-Verbose "Successfully verified access to admin share path: $uncPath"
        } else {
            Write-Warning "Admin share path exists but access may be restricted: $uncPath"
        }
        
        Write-Verbose "Using admin share path for S2D access: $uncPath"
        return $uncPath
    }
    catch {
        Write-Warning "Error determining S2D storage path on $($Session.ComputerName): $_"
        return $null
    }
}

# Helper function to retrieve network adapter statistics, including RDMA-specific counters if available.
function Get-RDMANetworkStats {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] $Session
    )

    try {
        $networkStatsResult = Invoke-Command -Session $Session -ScriptBlock {
            # Attempt to get SMB Direct-enabled and RDMA-capable network adapters
            $smbRdmaInterfaces = Get-SmbClientNetworkInterface | Where-Object { $_.RdmaCapable -eq $true }

            if ($null -eq $smbRdmaInterfaces -or $smbRdmaInterfaces.Count -eq 0) {
                Write-Verbose "No SMB Direct-enabled and RDMA-capable adapters found via Get-SmbClientNetworkInterface. Checking all 'Up' network adapters."
                $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            } else {
                $adapterNames = $smbRdmaInterfaces | ForEach-Object { $_.FriendlyName }
                Write-Verbose "Found SMB Direct-enabled and RDMA-capable adapters: $($adapterNames -join ', '). Getting corresponding NetAdapters."
                $adapters = Get-NetAdapter -Name $adapterNames | Where-Object { $_.Status -eq 'Up' }
            }

            if ($null -eq $adapters -or $adapters.Count -eq 0) {
                Write-Warning "No 'Up' network adapters found on $($env:COMPUTERNAME) to collect statistics from."
                return $null # Cannot proceed if no adapters are found
            }

            # Collect standard statistics for each selected adapter
            $adapterStatsData = @{}
            foreach ($adapter in $adapters) {
                try {
                    $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction Stop
                    $adapterStatsData[$adapter.Name] = @{
                        Name = $adapter.Name
                        ReceivedPackets = $stats.ReceivedPackets
                        SentPackets = $stats.SentPackets
                        ReceivedDiscardedPackets = $stats.ReceivedDiscardedPackets
                        OutboundDiscardedPackets = $stats.OutboundDiscardedPackets
                        ReceivedErrors = $stats.ReceivedErrors
                        OutboundErrors = $stats.OutboundErrors
                        TotalPacketsReceived = $stats.ReceivedUnicastPackets + $stats.ReceivedMulticastPackets + $stats.ReceivedBroadcastPackets
                        TotalPacketsSent = $stats.SentUnicastPackets + $stats.SentMulticastPackets + $stats.SentBroadcastPackets
                        ReceivedBytes = $stats.ReceivedBytes
                        SentBytes = $stats.SentBytes
                    }
                } catch {
                    Write-Warning "Failed to get statistics for adapter '$($adapter.Name)' on $($env:COMPUTERNAME): $_"
                }
            }

            # Attempt to get SMB Direct (RDMA specific) performance counters
            $smbDirectPerfData = $null
            try {
                $smbDirectCounterPaths = @(
                    '\SMB Direct Connection(*)\Inbound Bytes',
                    '\SMB Direct Connection(*)\Outbound Bytes',
                    '\SMB Direct Connection(*)\Inbound Bytes/sec',
                    '\SMB Direct Connection(*)\Outbound Bytes/sec',
                    '\SMB Direct Connection(*)\Reconnects',
                    '\SMB Direct Connection(*)\Connection Errors'
                )
                if (Get-Counter -ListSet 'SMB Direct Connection' -ErrorAction SilentlyContinue) {
                    $smbDirectRawStats = Get-Counter -Counter $smbDirectCounterPaths -ErrorAction SilentlyContinue
                    if ($smbDirectRawStats) {
                        $smbDirectPerfData = @{}
                        foreach ($counterSample in $smbDirectRawStats.CounterSamples) {
                            $smbDirectPerfData[$counterSample.Path] = $counterSample.CookedValue
                        }
                    } else { Write-Verbose "Get-Counter for SMB Direct returned no statistics on $($env:COMPUTERNAME)." }
                } else { Write-Verbose "SMB Direct Connection counter set not found on $($env:COMPUTERNAME)." }
            } catch {
                Write-Warning "Could not retrieve SMB Direct performance counters on $($env:COMPUTERNAME). Error: $_"
                $smbDirectPerfData = $null
            }

            # Collect RDMA Activity Performance Counters
            $rdmaActivityPerfData = $null
            try {
                $rdmaActivityCounterPaths = @(
                    '\RDMA Activity(*)\RDMA Inbound Frames Dropped',
                    '\RDMA Activity(*)\RDMA Outbound Frames Dropped',
                    '\RDMA Activity(*)\RDMA Inbound Errors',
                    '\RDMA Activity(*)\RDMA Outbound Errors',
                    '\RDMA Activity(*)\RDMA Connection Errors'
                )
                if (Get-Counter -ListSet 'RDMA Activity' -ErrorAction SilentlyContinue) {
                    $rdmaActivityRawStats = Get-Counter -Counter $rdmaActivityCounterPaths -ErrorAction SilentlyContinue
                    if ($rdmaActivityRawStats) {
                        $rdmaActivityPerfData = @{}
                        foreach ($counterSample in $rdmaActivityRawStats.CounterSamples) {
                            $rdmaActivityPerfData[$counterSample.Path] = $counterSample.CookedValue
                        }
                    } else { Write-Verbose "Get-Counter for RDMA Activity returned no statistics on $($env:COMPUTERNAME)." }
                } else { Write-Verbose "RDMA Activity counter set not found on $($env:COMPUTERNAME)." }
            } catch {
                Write-Warning "Could not retrieve RDMA Activity performance counters on $($env:COMPUTERNAME). Error: $_"
                $rdmaActivityPerfData = $null
            }

            return @{
                ComputerName = $env:COMPUTERNAME
                Timestamp = Get-Date
                AdapterStats = $adapterStatsData
                SMBDirectStats = $smbDirectPerfData
                RDMAActivityStats = $rdmaActivityPerfData
            }
        } -ErrorAction Stop 
        return $networkStatsResult
    }
    catch {
        Write-Warning "Failed to execute network statistics collection script on $($Session.ComputerName): $_. Network counter-based checks may be affected."
        return $null
    }
}

function Test-RDMAValidator_Stress {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([array])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]] $Sessions,

        [Parameter(Mandatory = $false)]
        [int] $TestFileSizeGB = 2,

        [Parameter(Mandatory = $false)]
        [int] $NumberOfFiles = 2,

        [Parameter(Mandatory = $false)]
        [string] $OutputPath = $env:TEMP,

        [Parameter(Mandatory = $false)]
        [Switch]$RunCleanup = $true,

        [Parameter(Mandatory = $false)]
        [int] $MaxWaitMinutes = 30,
        
        [Parameter(Mandatory = $false)]
        [int] $MonitorIntervalSeconds = 5
    )

    # Initialize core variables
    $instanceResults = @()
    $localComputerName = $env:COMPUTERNAME
    $nodeHostnames = @{}
    $s2dStoragePaths = @{}
    $remoteTestFilePaths = @{}
    $localSourceFiles = @()
    $jobList = @()
    $stressTestFailures = @()
    $overallStatus = "SUCCESS"
    $overallSeverity = "INFORMATIONAL"
    $criticalErrorOccurred = $false
    $nodePacketStats = @{}
    $smbConnectionLogs = @{}
    $globalPerformanceSummary = $null
    $logFilePath = Join-Path -Path $OutputPath -ChildPath "RDMA_SMB_Connections_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    # Display test parameters
    Write-Host "--- RDMA Stress Test Information ---"
    Write-Host "Source Node: $localComputerName"
    Write-Host "Destination Nodes: $($Sessions.ComputerName -join ', ')"
    Write-Host "Output/Temp Path: $OutputPath"
    Write-Host "Test File Size: $TestFileSizeGB GB"
    Write-Host "Number of Files per Node: $NumberOfFiles"
    Write-Host "Max Wait Time: $MaxWaitMinutes minutes"
    Write-Host "Cleanup Enabled: $RunCleanup"
    Write-Host "Monitor Interval: $MonitorIntervalSeconds seconds"
    Write-Host "Using Start-Job for concurrency with enhanced packet loss and interruption detection."
    Write-Host "Direct SMB/RDMA connection logging during file transfers."
    Write-Host "Target: S2D Cluster Storage"
    Write-Host "-------------------------------------"

    # Initialize log file
    "Timestamp,Node,Operation,TotalSMBConnections,RDMAEnabledConnections,ConnectionDetails" | Out-File -FilePath $logFilePath -Encoding UTF8 -Force
    Write-Verbose "SMB/RDMA Connection log file created at: $logFilePath"

    # Validate sessions
    if ($Sessions.Count -eq 0) {
        Write-Verbose "No destination sessions provided. Exiting."
        $noSessionResult = @{
            Name = "AzStackHci_RDMA_Test_StressNoSessions"
            Title = "RDMA Stress Test - No Sessions"
            DisplayName = "RDMA Stress Test Skipped - No Sessions Provided"
            Severity = "WARNING"
            Description = "RDMA stress test was skipped because no destination sessions were provided."
            Remediation = "Provide valid PS sessions to target nodes for RDMA testing."
            TargetResourceID = $localComputerName
            TargetResourceName = "LocalNode"
            TargetResourceType = "Node"
            Timestamp = [datetime]::UtcNow
            Status = "SKIPPED"
            AdditionalData = @{ Source=$localComputerName; Resource="SessionValidation"; Detail="No sessions provided"; Status="SKIPPED"; TimeStamp=[datetime]::UtcNow }
            HealthCheckSource = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @noSessionResult
        return $instanceResults
    }

    # Filter remote sessions
    $destinationSessions = $Sessions | Where-Object {
        $_.ComputerName -ne $localComputerName -and
        ($_.ComputerName -split '\.')[0] -ne $localComputerName -and
        $_.ComputerName -ne "localhost"
    }

    if ($destinationSessions.Count -eq 0) {
        Write-Verbose "No valid remote destination sessions found after filtering. Exiting."
        $noRemoteResult = @{
            Name = "AzStackHci_RDMA_Test_StressNoRemoteSessions"
            Title = "RDMA Stress Test - No Remote Sessions"
            DisplayName = "RDMA Stress Test Skipped - No Remote Sessions"
            Severity = "WARNING"
            Description = "RDMA stress test was skipped because all provided sessions target the local machine."
            Remediation = "Provide PS sessions that target remote nodes, not localhost or the local machine."
            TargetResourceID = $localComputerName
            TargetResourceName = "LocalNode"
            TargetResourceType = "Node"
            Timestamp = [datetime]::UtcNow
            Status = "SKIPPED"
            AdditionalData = @{ Source=$localComputerName; Resource="SessionValidation"; Detail="No remote sessions found"; Status="SKIPPED"; TimeStamp=[datetime]::UtcNow }
            HealthCheckSource = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @noRemoteResult
        return $instanceResults
    }

    Write-Verbose "Testing against $($destinationSessions.Count) remote node(s): $($destinationSessions.ComputerName -join ', ')"

    # Ensure output directory exists
    if (-not (Test-Path -Path $OutputPath -PathType Container)) {
        Write-Verbose "Local output/temp directory '$OutputPath' does not exist. Creating..."
        try {
            New-Item -Path $OutputPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Error "Failed to create local directory '$OutputPath'. Error: $_"
            $criticalErrorOccurred = $true
            $prepErrorResult = @{
                Name = "AzStackHci_RDMA_Test_StressPrepError_LocalDir"
                Title = "RDMA Stress Test Preparation Error"
                DisplayName = "Local Temp Directory Creation Error"
                Severity = "CRITICAL"
                Description = "Failed to create the local directory '$OutputPath'."
                Remediation = "Ensure path '$OutputPath' is valid and permissions exist."
                TargetResourceID = $localComputerName
                TargetResourceName = "LocalStorage"
                TargetResourceType = "Node"
                Timestamp = [datetime]::UtcNow
                Status = "FAILURE"
                AdditionalData = @{ Source=$localComputerName; Resource="LocalStorage"; Detail="Error creating '$OutputPath': $_"; Status="FAILURE"; TimeStamp=[datetime]::UtcNow }
                HealthCheckSource = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @prepErrorResult
            return $instanceResults
        }
    }

    # Create local source files
    Write-Verbose "Creating $NumberOfFiles local source file(s) of size $TestFileSizeGB GB each in '$OutputPath'..."
    for ($i = 1; $i -le $NumberOfFiles; $i++) {
        $localSourceFilePath = Join-Path $OutputPath "RDMAStress_SourceFile_${i}_${TestFileSizeGB}GB.dat"
        if ($PSCmdlet.ShouldProcess($localSourceFilePath, "Create Local Source File")) {
            try {
                Write-Verbose "Creating local source file: $localSourceFilePath"
                $fileSizeBytes = $TestFileSizeGB * 1GB
                $fs = [System.IO.File]::Create($localSourceFilePath); $fs.Close(); $fs.Dispose()
                $fs = [System.IO.FileStream]::new($localSourceFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
                $fs.SetLength($fileSizeBytes)
                $fs.Close()
                $fs.Dispose()

                if(Test-Path $localSourceFilePath -PathType Leaf) {
                    $localSourceFiles += $localSourceFilePath
                } else {
                    throw "File not found after creation: $localSourceFilePath"
                }
            } catch {
                Write-Error "Failed to create local source file '$localSourceFilePath'. Error: $_"
                $criticalErrorOccurred = $true
                $prepErrorResult = @{
                    Name = "AzStackHci_RDMA_Test_StressPrepError_LocalSource"
                    Title = "RDMA Stress Test Preparation Error"
                    DisplayName = "Local Source File Creation Error"
                    Severity = "CRITICAL"
                    Description = "Failed to create '$localSourceFilePath'."
                    Remediation = "Check disk space/permissions in '$OutputPath'. Error: $_"
                    TargetResourceID = $localComputerName
                    TargetResourceName = "LocalStorage"
                    TargetResourceType = "Node"
                    Timestamp = [datetime]::UtcNow
                    Status = "FAILURE"
                    AdditionalData = @{ Source=$localComputerName; Resource="LocalStorage"; Detail="Error creating '$localSourceFilePath': $_"; Status="FAILURE"; TimeStamp=[datetime]::UtcNow }
                    HealthCheckSource = $ENV:EnvChkrId
                }
                $instanceResults += New-AzStackHciResultObject @prepErrorResult
                if ($RunCleanup) {
                    $localSourceFiles | ForEach-Object {
                        if(Test-Path $_){ Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
                    }
                }
                return $instanceResults
            }
        } else {
            Write-Warning "Local source file creation skipped due to -WhatIf."
            $whatIfResult = @{
                Name = "AzStackHci_RDMA_Test_StressWhatIf"
                Title = "RDMA Stress Test - WhatIf Mode"
                DisplayName = "RDMA Stress Test Skipped - WhatIf Mode"
                Severity = "INFORMATIONAL"
                Description = "RDMA stress test was skipped due to -WhatIf parameter."
                Remediation = "Run without -WhatIf to execute the actual test."
                TargetResourceID = $localComputerName
                TargetResourceName = "LocalNode"
                TargetResourceType = "Node"
                Timestamp = [datetime]::UtcNow
                Status = "SKIPPED"
                AdditionalData = @{ Source=$localComputerName; Resource="WhatIfMode"; Detail="Test skipped due to -WhatIf"; Status="SKIPPED"; TimeStamp=[datetime]::UtcNow }
                HealthCheckSource = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @whatIfResult
            return $instanceResults 
        }
    }

    if ($localSourceFiles.Count -ne $NumberOfFiles) {
        Write-Error "Failed to create all required local source files. Expected $NumberOfFiles, created $($localSourceFiles.Count)."
        $criticalErrorOccurred = $true
        $prepErrorResult = @{
            Name = "AzStackHci_RDMA_Test_StressPrepError_InsufficientSourceFiles"
            Title = "RDMA Stress Test Preparation Error"
            DisplayName = "Insufficient Local Source Files Created"
            Severity = "CRITICAL"
            Description = "Not all required local source files were created. Expected $NumberOfFiles, but only $($localSourceFiles.Count) were created."
            Remediation = "Check disk space, permissions in '$OutputPath', and review any previous errors during file creation."
            TargetResourceID = $localComputerName
            TargetResourceName = "LocalStorage"
            TargetResourceType = "Node"
            Timestamp = [datetime]::UtcNow
            Status = "FAILURE"
            AdditionalData = @{ Source=$localComputerName; Resource="LocalStorage"; Detail="Expected $NumberOfFiles files, created $($localSourceFiles.Count)."; Status="FAILURE"; TimeStamp=[datetime]::UtcNow }
            HealthCheckSource = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @prepErrorResult
        return $instanceResults
    }

    Write-Host "Local source files created successfully." -ForegroundColor Green

    # Prepare destination nodes
    $preparedNodes = [System.Collections.Generic.List[string]]::new()
    Write-Verbose "Preparing destination nodes and identifying S2D storage paths..."
    
    foreach ($session in $destinationSessions) {
        $computerName = $session.ComputerName
        try {
            Write-Verbose "Preparing destination node '$computerName'..."
            
            # Collect initial network statistics
            $initialNetworkStats = Get-RDMANetworkStats -Session $session
            if ($null -eq $initialNetworkStats) {
                Write-Warning "Could not collect initial network statistics for node '$computerName'."
                $nodePacketStats[$computerName] = @{
                    Initial = $null; Final = $null; DroppedPackets = 0; NetworkAdapterDrops = 0;
                    StatsCollectionError = "Failed to collect initial stats."
                }
            } else {
                $nodePacketStats[$computerName] = @{ 
                    Initial = $initialNetworkStats; Final = $null; DroppedPackets = 0; NetworkAdapterDrops = 0; StatsCollectionError = $null 
                }
                Write-Verbose "Initial network statistics collected for '$computerName'."
            }

            # Get node hostname
            try {
                if ($computerName -match '^\d+\.\d+\.\d+\.\d+$') {
                    $nodeHostname = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
                    if ($nodeHostname) {
                        Write-Verbose "Resolved IP '$computerName' to hostname '$nodeHostname'"
                        $nodeHostnames[$computerName] = $nodeHostname
                    } else {
                        Write-Warning "Could not get hostname from node '$computerName'. Using IP address."
                        $nodeHostnames[$computerName] = $computerName
                    }
                } else {
                    $nodeHostnames[$computerName] = $computerName
                    Write-Verbose "Using hostname '$computerName' for RDMA connections"
                }
            } catch {
                Write-Warning "Could not resolve hostname for '$computerName': $_. Using connection name for UNC paths."
                $nodeHostnames[$computerName] = $computerName
            }

            # Find S2D cluster storage path
            Write-Verbose "Locating S2D cluster storage path on node '$computerName' using $($nodeHostnames[$computerName])..."
            $s2dStoragePath = Get-DynamicRemoteS2DStoragePath -Session $session -RemoteNodeNameOrIP $computerName
            
            if ($null -eq $s2dStoragePath) {
                $resolvedNodeNameForPath = $nodeHostnames[$computerName]
                Write-Verbose "No specific S2D path found. Searching for User folders in ClusterStorage on '$computerName'..."
                
                try {
                    $userFolders = Invoke-Command -Session $session -ScriptBlock {
                        $clusterStoragePath = "C:\ClusterStorage"
                        if (Test-Path $clusterStoragePath) {
                            Get-ChildItem -Path $clusterStoragePath -Directory | 
                                Where-Object { $_.Name -like "*User*" } | 
                                Select-Object -ExpandProperty Name
                        } else {
                            @()
                        }
                    } -ErrorAction Stop
                    
                    if ($userFolders -and $userFolders.Count -gt 0) {
                        $selectedUserFolder = $userFolders[0]
                        $fallbackS2DPath = "\\$resolvedNodeNameForPath\C$\ClusterStorage\$selectedUserFolder"
                        Write-Verbose "No specific S2D cluster storage path found on '$computerName'. Using User folder: '$fallbackS2DPath'"
                        Write-Host "Using S2D storage path on '$computerName': $fallbackS2DPath" -ForegroundColor Cyan
                        $s2dStoragePath = $fallbackS2DPath
                    } else {
                        throw "No User folders found in C:\ClusterStorage on node '$computerName'"
                    }
                } catch {
                    Write-Error "Failed to find suitable S2D storage path on node '$computerName'. No User folders found in ClusterStorage. Error: $_"
                    $criticalErrorOccurred = $true
                    
                    $prepErrorResult = @{
                        Name = "AzStackHci_RDMA_Test_StressNodePrepError_NoUserFolder"
                        Title = "RDMA Stress Test Node Preparation Error"
                        DisplayName = "No User Folder in ClusterStorage - $computerName"
                        Severity = "CRITICAL"
                        Description = "Failed to find any User folder in C:\ClusterStorage on node '$computerName' for S2D storage testing."
                        Remediation = "Ensure at least one folder containing 'User' in its name exists in C:\ClusterStorage on '$computerName' (e.g., UserStorage_1)."
                        TargetResourceID = $computerName
                        TargetResourceName = $computerName
                        TargetResourceType = "Node"
                        Timestamp = [datetime]::UtcNow
                        Status = "FAILURE"
                        AdditionalData = @{ 
                            Source=$computerName; 
                            Resource="S2DStorage"; 
                            Detail="No User folders found in ClusterStorage. Error: $_"; 
                            Status="FAILURE"; 
                            TimeStamp=[datetime]::UtcNow 
                        }
                        HealthCheckSource = $ENV:EnvChkrId
                    }
                    $instanceResults += New-AzStackHciResultObject @prepErrorResult
                    continue
                }
            }
            
            # Modify storage path to use hostname
            if ($s2dStoragePath -match '^\\\\(\d+\.\d+\.\d+\.\d+)\\(.+)$' -and $nodeHostnames[$computerName] -ne $computerName) {
                $pathPart = $matches[2]
                $newPath = "\\$($nodeHostnames[$computerName])\$pathPart"
                Write-Verbose "Modified UNC path from '$s2dStoragePath' to use hostname: '$newPath'"
                $s2dStoragePath = $newPath
            }
            
            $s2dStoragePaths[$computerName] = $s2dStoragePath
            Write-Verbose "Found S2D path for '$computerName': $s2dStoragePath"

            $remoteTestFilePaths[$computerName] = @()
            $preparedNodes.Add($computerName)
        } catch {
            Write-Error "Failed to prepare node '$computerName': $_"
            $criticalErrorOccurred = $true
            $prepErrorResult = @{
                Name = "AzStackHci_RDMA_Test_StressNodePrepError"
                Title = "RDMA Stress Test Node Preparation Error"
                DisplayName = "Node Preparation Error - $computerName"
                Severity = "WARNING"
                Description = "Failed to prepare node '$computerName' for the test."
                Remediation = "Check connectivity to '$computerName', permissions, and review error details: $_"
                TargetResourceID = $computerName; TargetResourceName = $computerName; TargetResourceType = "Node"
                Timestamp = [datetime]::UtcNow; Status = "FAILURE" 
                AdditionalData = @{ Source=$computerName; Resource="NodePreparation"; Detail="Error: $_"; Status="FAILURE"; TimeStamp=[datetime]::UtcNow }
                HealthCheckSource = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @prepErrorResult
        }
    }

    if ($preparedNodes.Count -eq 0) {
        Write-Error "No destination nodes were successfully prepared for the stress test. Aborting."
        $criticalErrorOccurred = $true
        $prepInsufficientResult = @{
            Name = "AzStackHci_RDMA_Test_StressInsufficientNodesPrepared"; Title = "RDMA Stress Test Execution"
            DisplayName = "Insufficient Nodes Prepared"; Severity = "CRITICAL"
            Description = "No destination nodes could be prepared for the test. See individual node preparation errors."
            Remediation = "Review node preparation errors logged previously for each target node."
            TargetResourceID = "ClusterRDMAConnectivity"; TargetResourceName = "RDMAStressTest"; TargetResourceType = "Cluster"
            Timestamp = [datetime]::UtcNow; Status = "FAILURE"
            AdditionalData = @{ Source="Cluster"; Resource="StressTest"; Detail="No nodes prepared."; Status="FAILURE"; TimeStamp=[datetime]::UtcNow }
            HealthCheckSource = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @prepInsufficientResult
        if ($RunCleanup) {
            $localSourceFiles | ForEach-Object { if(Test-Path $_){ Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue } }
        }
        return $instanceResults
    }

    Write-Host "Successfully prepared $($preparedNodes.Count) node(s) for S2D storage stress testing: $($preparedNodes -join ', ')" -ForegroundColor Green

    # Execute concurrent file copies
    Write-Host "Starting concurrent RDMA stress copy jobs to S2D storage..."
    $jobsStartTime = Get-Date

    foreach ($destNodeName in $preparedNodes) {
        $destSession = $destinationSessions | Where-Object { $_.ComputerName -eq $destNodeName }
        $targetUncPath = $s2dStoragePaths[$destNodeName]
        
        $scriptBlock = {
            param(
                [string]$TargetS2DPath,
                [string]$TargetNodeName,
                [string]$SourceNodeName,
                [array]$LocalSourceFilePaths,
                [string]$LogFilePath
            )
            $ErrorActionPreference = 'Stop'
            if ($PsBoundParameters.Verbose.IsPresent) { $VerbosePreference = 'Continue' } else { $VerbosePreference = 'SilentlyContinue' }

            $nodeResults = @{
                Node = $TargetNodeName;
                Status = 'Success'; 
                Errors = @();
                FilesTested = @(); 
                SMBConnections = @();
                RDMAStates = @();
                ResultType = "RDMA_STRESS_RESULT"
            }
            Write-Verbose "[$TargetNodeName] Job started (PID: $PID) to copy files to S2D path: $TargetS2DPath."

            function Get-SMBConnectionDetails {
                param([string]$NodeName, [string]$Operation)

                try {
                    $smbConnections = Get-SmbConnection -ErrorAction SilentlyContinue
                    $smbMultichannelConnections = Get-SmbMultichannelConnection -ErrorAction SilentlyContinue

                    $totalConnections = ($smbConnections | Measure-Object).Count

                    # Count actual RDMA channels, not unique server/share combinations
                    $rdmaCapableConnections = ($smbMultichannelConnections | 
                        Where-Object { $_.Selected -and $_.ClientRdmaCapable -and $_.ServerRdmaCapable } | 
                        Measure-Object).Count

                    # Build connection details
                    $connectionDetails = foreach ($conn in $smbConnections) {
                        $serverName = $conn.ServerName
                        $shareName = $conn.ShareName

                        # Find matching multichannel connections
                        $matchingMultiConnections = $smbMultichannelConnections | Where-Object { $_.ServerName -eq $serverName }
            
                        # Count RDMA-enabled channels for this connection
                        $rdmaChannelCount = ($matchingMultiConnections |
                            Where-Object { $_.Selected -and $_.ClientRdmaCapable -and $_.ServerRdmaCapable } |
                            Measure-Object).Count
            
                        $rdmaEnabled = $rdmaChannelCount -gt 0

                        [PSCustomObject]@{
                            ServerName = $serverName
                            ShareName = $shareName
                            RDMAEnabled = $rdmaEnabled
                            RDMAChannelCount = $rdmaChannelCount
                            MultiChannelCount = ($matchingMultiConnections | Measure-Object).Count
                            NumOpens = $conn.NumOpens
                        }
                    }

                    # Log to file
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                    $connectionDetailsJson = $connectionDetails | ConvertTo-Json -Compress
                    $logEntry = "$timestamp,$NodeName,$Operation,$totalConnections,$rdmaCapableConnections,$connectionDetailsJson"

                    # Thread-safe file writing with retries
                    $maxRetries = 5
                    $retryCount = 0
                    $retryDelay = 100
                    $writeSuccess = $false

                    while (-not $writeSuccess -and $retryCount -lt $maxRetries) {
                        try {
                            $fileStream = [System.IO.FileStream]::new(
                                $LogFilePath,
                                [System.IO.FileMode]::Append,
                                [System.IO.FileAccess]::Write,
                                [System.IO.FileShare]::ReadWrite
                            )
    
                            $streamWriter = [System.IO.StreamWriter]::new($fileStream)
                            $streamWriter.WriteLine($logEntry)
                            $streamWriter.Flush()
                            $streamWriter.Close()
                            $fileStream.Close()
    
                            $writeSuccess = $true
                        }
                        catch {
                            $retryCount++
                            if ($retryCount -lt $maxRetries) {
                                Start-Sleep -Milliseconds $retryDelay
                                $retryDelay *= 2
                            }
                            else {
                                Write-Warning "[$NodeName] Failed to write to log file after $maxRetries attempts: $_"
                            }
                        }
                        finally {
                            if ($null -ne $streamWriter) { $streamWriter.Dispose() }
                            if ($null -ne $fileStream) { $fileStream.Dispose() }
                        }
                    }

                    return @{
                        Timestamp = $timestamp
                        TotalConnections = $totalConnections
                        RDMACapableConnections = $rdmaCapableConnections
                        Details = $connectionDetails
                    }
                } 
                catch {
                    Write-Warning "[$NodeName] Failed to get SMB connection details: $_"
                    return $null
                }
            }

            for ($i = 0; $i -lt $LocalSourceFilePaths.Count; $i++) {
                $localSourcePath = $LocalSourceFilePaths[$i]
                $sourceFileName = Split-Path $localSourcePath -Leaf
                $remoteDestPath = Join-Path -Path $TargetS2DPath -ChildPath "S2D_StressCopy_${TargetNodeName}_${sourceFileName}"

                try {
                    Write-Verbose "[$TargetNodeName] Attempting copy: `"$localSourcePath`" -> `"$remoteDestPath`""

                    function Get-RDMAConnectionState {
                        param([string]$NodeName, [string]$Operation)
                        
                        try {
                            $smbMultiChannelConns = Get-SmbMultichannelConnection -ErrorAction SilentlyContinue
                            $rdmaConnections = $smbMultiChannelConns | Where-Object { 
                                $_.Selected -and $_.ClientRdmaCapable -and $_.ServerRdmaCapable 
                            }
                            $tcpConnections = $smbMultiChannelConns | Where-Object { 
                                $_.Selected -and (-not $_.ClientRdmaCapable -or -not $_.ServerRdmaCapable) 
                            }
                            
                            $connectionFingerprints = $rdmaConnections | ForEach-Object {
                                "$($_.ServerName)|$($_.ClientIpAddress)|$($_.ServerIpAddress)|$($_.ClientInterfaceIndex)|$($_.CurrentChannels)"
                            } | Sort-Object
                            
                            $state = @{
                                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                                Operation = $Operation
                                ActiveRDMAConnections = ($rdmaConnections | Measure-Object).Count
                                ActiveTCPConnections = ($tcpConnections | Measure-Object).Count
                                TCPFallbackActive = ($tcpConnections | Measure-Object).Count -gt 0
                                ConnectionFingerprints = $connectionFingerprints
                                FailureCounts = $rdmaConnections | Select-Object -ExpandProperty FailureCount
                                ConnectionDetails = $smbMultiChannelConns | Select-Object ServerName, Selected, ClientRdmaCapable, ServerRdmaCapable, FailureCount, ClientIpAddress, ServerIpAddress
                            }
                            return $state
                        } catch {
                            Write-Warning "[$NodeName] Failed to get RDMA connection state: $_"
                            return $null
                        }
                    }

                    function Get-RDMAReconnectCounters {
                        param([string]$NodeName)
                        
                        try {
                            $counters = @(
                                '\SMB Direct Connection(*)\Connection Count',
                                '\SMB Direct Connection(*)\RDMA Registrations/sec',
                                '\SMB Client Shares(*)\Connection Failures',
                                '\SMB Client Shares(*)\Failed Connection Attempts',
                                '\SMB Client Shares(*)\Reconnects'
                            )
                            
                            $results = @{}
                            foreach ($counter in $counters) {
                                try {
                                    $value = (Get-Counter -Counter $counter -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                                    $results[$counter] = $value
                                } catch {
                                    # Counter might not exist
                                }
                            }
                            
                            return $results
                        } catch {
                            Write-Warning "[$NodeName] Failed to get RDMA counters: $_"
                            return $null
                        }
                    }
                    
                    $rdmaStateBefore = Get-RDMAConnectionState -NodeName $TargetNodeName -Operation "BeforeCopy_$sourceFileName"
                    $smbConnBefore = Get-SMBConnectionDetails -NodeName $TargetNodeName -Operation "BeforeCopy_$sourceFileName"
                    $countersBefore = Get-RDMAReconnectCounters -NodeName $TargetNodeName
                    
                    # Initialize performance tracking
                    if (-not $nodeResults.ContainsKey('PerformanceMetrics')) {
                        $nodeResults['PerformanceMetrics'] = @()
                    }
                    
                    $copyStart = Get-Date
                    $copyStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
                    $performanceError = $null
                    
                    try {
                        # Perform the actual copy with performance measurement
                        Copy-Item -Path $localSourcePath -Destination $remoteDestPath -Force -ErrorAction Stop
                        
                        # Capture performance metrics immediately after successful copy
                        $copyEndTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
                        $copyDurationSeconds = ($copyEndTicks - $copyStartTicks) / [System.Diagnostics.Stopwatch]::Frequency
                        
                        # Get actual file size for accurate throughput calculation
                        try {
                            $fileInfo = Get-Item -Path $localSourcePath -ErrorAction Stop
                            $fileSizeBytes = $fileInfo.Length
                            
                            # Calculate throughput metrics
                            $throughputMBps = if ($copyDurationSeconds -gt 0) { 
                                ($fileSizeBytes / 1MB) / $copyDurationSeconds 
                            } else { 0 }
                            
                            $throughputGbps = if ($copyDurationSeconds -gt 0) { 
                                ($fileSizeBytes * 8) / 1GB / $copyDurationSeconds 
                            } else { 0 }
                            
                            # Store detailed performance metrics
                            $perfMetric = @{
                                FileName = $sourceFileName
                                FileSizeBytes = $fileSizeBytes
                                FileSizeMB = [Math]::Round($fileSizeBytes / 1MB, 2)
                                FileSizeGB = [Math]::Round($fileSizeBytes / 1GB, 3)
                                StartTime = $copyStart
                                DurationSeconds = [Math]::Round($copyDurationSeconds, 3)
                                ThroughputMBps = [Math]::Round($throughputMBps, 2)
                                ThroughputGbps = [Math]::Round($throughputGbps, 3)
                            }
                            
                            $nodeResults.PerformanceMetrics += $perfMetric
                            
                            Write-Verbose "[$TargetNodeName] Performance captured: $($perfMetric.FileName) = $($perfMetric.ThroughputMBps) MB/s ($($perfMetric.DurationSeconds)s)"
                        } catch {
                            $performanceError = "Failed to capture performance metrics: $_"
                            Write-Warning "[$TargetNodeName] $performanceError"
                        }
                    } catch {
                        throw
                    } finally {
                        $copyEnd = Get-Date
                        $copyDuration = ($copyEnd - $copyStart).TotalSeconds
                        
                        $countersAfter = Get-RDMAReconnectCounters -NodeName $TargetNodeName
                        
                        $reconnectsDetected = $false
                        if ($countersBefore -and $countersAfter) {
                            foreach ($counterName in $countersBefore.Keys) {
                                if ($countersAfter.ContainsKey($counterName)) {
                                    $delta = $countersAfter[$counterName] - $countersBefore[$counterName]
                                    if ($delta -gt 0 -and $counterName -match 'Connection Count|Registrations|Reconnects') {
                                        $reconnectsDetected = $true
                                        Write-Verbose "[$TargetNodeName] Counter '$counterName' increased by $delta during copy"
                                    }
                                }
                            }
                        }
                        
                        if ($rdmaStateBefore -and $rdmaStateAfter) {
                            if ($rdmaStateBefore.ConnectionFingerprints -and $rdmaStateAfter.ConnectionFingerprints) {
                                $fingerprintsDiffer = (Compare-Object -ReferenceObject $rdmaStateBefore.ConnectionFingerprints -DifferenceObject $rdmaStateAfter.ConnectionFingerprints)
                                if ($fingerprintsDiffer) {
                                    $reconnectsDetected = $true
                                    Write-Verbose "[$TargetNodeName] RDMA connection fingerprints changed - reconnect detected"
                                }
                            }
                            
                            $failuresBefore = ($rdmaStateBefore.FailureCounts | Measure-Object -Sum).Sum
                            $failuresAfter = ($rdmaStateAfter.FailureCounts | Measure-Object -Sum).Sum
                            if ($failuresAfter -gt $failuresBefore) {
                                $reconnectsDetected = $true
                                Write-Verbose "[$TargetNodeName] SMB connection failure count increased from $failuresBefore to $failuresAfter"
                            }
                        }
                        
                        if ($reconnectsDetected) {
                            $errorMessage = "[$TargetNodeName] RDMA reconnect detected during transfer of $sourceFileName (duration: ${copyDuration}s). This indicates packet loss occurred."
                            Write-Warning $errorMessage
                            $nodeResults.Errors += $errorMessage
                        }

                        try {
                            $rdmaEvents = Get-WinEvent -FilterHashtable @{
                                LogName = 'Microsoft-Windows-SMBClient/Connectivity', 'System'
                                StartTime = $copyStart
                                EndTime = $copyEnd
                            } -ErrorAction SilentlyContinue | Where-Object {
                                $_.Message -match 'lost connection|disconnect|reconnect|connection failure|transport failure|connection reset|connection terminated' -and
                                $_.Message -notmatch 'The SMB redirector selected the connection' -and
                                $_.Level -le 3
                            }
                            
                            if ($rdmaEvents) {
                                $errorMessage = "[$TargetNodeName] RDMA connection failure events found during transfer of '$sourceFileName': " +
                                               ($rdmaEvents | Select-Object -First 3 -ExpandProperty Message | Out-String)
                                Write-Warning $errorMessage
                                $nodeResults.Errors += $errorMessage
                                
                                if (-not $reconnectsDetected) {
                                    $reconnectsDetected = $true
                                }
                            }
                        } catch {
                            Write-Verbose "[$TargetNodeName] Could not check event logs: $_"
                        }
                    }
                    
                    $smbConnAfter = Get-SMBConnectionDetails -NodeName $TargetNodeName -Operation "AfterCopy_$sourceFileName"
                    $rdmaStateAfter = Get-RDMAConnectionState -NodeName $TargetNodeName -Operation "AfterCopy_$sourceFileName"
                    
                    if ($rdmaStateBefore -and $rdmaStateAfter) {
                        $isInitialEstablishment = ($rdmaStateBefore.ActiveRDMAConnections -eq 0 -and $rdmaStateAfter.ActiveRDMAConnections -gt 0)
                        $isNormalTeardown = ($rdmaStateBefore.ActiveRDMAConnections -gt 0 -and $rdmaStateAfter.ActiveRDMAConnections -eq 0)
                        $connectionIncreased = ($rdmaStateBefore.ActiveRDMAConnections -gt 0 -and 
                                               $rdmaStateAfter.ActiveRDMAConnections -gt $rdmaStateBefore.ActiveRDMAConnections)
                        $connectionDecreased = ($rdmaStateBefore.ActiveRDMAConnections -gt 0 -and 
                                               $rdmaStateAfter.ActiveRDMAConnections -gt 0 -and
                                               $rdmaStateAfter.ActiveRDMAConnections -lt $rdmaStateBefore.ActiveRDMAConnections)
    
                        # Check for actual disruption indicators
                        $fingerprintChanged = $false
                        if ($rdmaStateBefore.ConnectionFingerprints -and $rdmaStateAfter.ConnectionFingerprints) {
                            # Only consider it a disruption if we have the same or fewer connections but different fingerprints
                            if ($rdmaStateAfter.ActiveRDMAConnections -le $rdmaStateBefore.ActiveRDMAConnections) {
                                $fingerprintsDiffer = (Compare-Object -ReferenceObject $rdmaStateBefore.ConnectionFingerprints -DifferenceObject $rdmaStateAfter.ConnectionFingerprints)
                                if ($fingerprintsDiffer) {
                                    $fingerprintChanged = $true
                                }
                            }
                        }
    
                        # Check for increase in failure counts
                        $failureCountIncreased = $false
                        if ($rdmaStateBefore.FailureCounts -and $rdmaStateAfter.FailureCounts) {
                            $failuresBefore = ($rdmaStateBefore.FailureCounts | Measure-Object -Sum).Sum
                            $failuresAfter = ($rdmaStateAfter.FailureCounts | Measure-Object -Sum).Sum
                            if ($failuresAfter -gt $failuresBefore) {
                                $failureCountIncreased = $true
                            }
                        }
    
                        # Only flag as reconnection if connections decreased OR fingerprints changed OR failures increased
                        if ($connectionDecreased) {
                            $errorMessage = "[$TargetNodeName] RDMA connection drop detected during transfer of $sourceFileName. " +
                                           "RDMA connections decreased from $($rdmaStateBefore.ActiveRDMAConnections) to $($rdmaStateAfter.ActiveRDMAConnections). " +
                                           "This indicates potential packet loss or connection instability."
                            Write-Warning $errorMessage
                            $nodeResults.Errors += $errorMessage
                        }
                        elseif ($fingerprintChanged -or $failureCountIncreased) {
                            $errorMessage = "[$TargetNodeName] RDMA connection instability detected during transfer of $sourceFileName. "
                            if ($fingerprintChanged) {
                                $errorMessage += "Connection characteristics changed (possible reconnection). "
                            }
                            if ($failureCountIncreased) {
                                $errorMessage += "SMB connection failure count increased. "
                            }
                            $errorMessage += "This indicates potential packet loss."
                            Write-Warning $errorMessage
                            $nodeResults.Errors += $errorMessage
                        }
                        elseif ($connectionIncreased) {
                            Write-Verbose "[$TargetNodeName] RDMA connections increased from $($rdmaStateBefore.ActiveRDMAConnections) to $($rdmaStateAfter.ActiveRDMAConnections) (normal channel establishment)"
                        }
                        elseif ($isNormalTeardown) {
                            Write-Verbose "[$TargetNodeName] RDMA connections dropped to 0 after transfer of $sourceFileName."
                        }
                        elseif ($isInitialEstablishment) {
                            Write-Verbose "[$TargetNodeName] RDMA connections established: $($rdmaStateAfter.ActiveRDMAConnections) connections for $sourceFileName"
                        }
    
                        if ($rdmaStateAfter.TCPFallbackActive) {
                            $errorMessage = "[$TargetNodeName] TCP fallback detected during transfer of $sourceFileName. This indicates RDMA connection failure/packet loss."
                            Write-Warning $errorMessage
                            $nodeResults.Errors += $errorMessage
                        }
                    }
                    
                    if (-not $nodeResults.ContainsKey('RDMAStates')) {
                        $nodeResults['RDMAStates'] = @()
                    }
                    $nodeResults.RDMAStates += @{
                        FileName = $sourceFileName
                        Before = $rdmaStateBefore
                        After = $rdmaStateAfter
                    }
                    
                    $nodeResults.FilesTested += $remoteDestPath
                    $nodeResults.SMBConnections += @{
                        FileName = $sourceFileName
                        Before = $smbConnBefore
                        After = $smbConnAfter
                    }
                    
                    Write-Verbose "[$TargetNodeName] Successfully copied `"$remoteDestPath`"."
                } catch {
                    $errorMessage = "[$TargetNodeName] FAILED copy for '$localSourcePath' to '$remoteDestPath'. Error: $($_.Exception.Message)"
                    Write-Warning $errorMessage 
                    $nodeResults.Status = 'Failure'
                    $nodeResults.Errors += $errorMessage
                    Write-Verbose "[$TargetNodeName] Error during copy: $($_.Exception.Message)"
                    
                    $smbConnAfterError = Get-SMBConnectionDetails -NodeName $TargetNodeName -Operation "ErrorCopy_$sourceFileName"
                }
            }
            
            $smbConnFinal = Get-SMBConnectionDetails -NodeName $TargetNodeName -Operation "FinalCheck"
            $nodeResults.SMBConnections += @{
                FileName = "FinalCheck"
                Connection = $smbConnFinal
            }
            
            Write-Verbose "[$TargetNodeName] Job script block finished. Status: $($nodeResults.Status)."
            Write-Output -InputObject $nodeResults
        } 

        if ($PSCmdlet.ShouldProcess($destNodeName, "Start Stress Copy Job to S2D Path: $targetUncPath")) {
            Write-Verbose "Starting Job for node '$destNodeName' (S2D Target Path: $targetUncPath)"
            try {
                $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
                    $targetUncPath, 
                    $destNodeName, 
                    $localComputerName, 
                    [string[]]$localSourceFiles,
                    $logFilePath
                ) -ErrorAction Stop
                $jobList += $job

                $remotePathsForCleanup = @()
                foreach($localSrc in $localSourceFiles) {
                    $srcFileName = Split-Path $localSrc -Leaf
                    $remotePathsForCleanup += Join-Path -Path $targetUncPath -ChildPath "S2D_StressCopy_${destNodeName}_${srcFileName}"
                }
                $remoteTestFilePaths[$destNodeName] = $remotePathsForCleanup
            } catch {
                Write-Error "Failed to start job for node '$destNodeName': $_"
                $overallStatus = "FAILURE"; $criticalErrorOccurred = $true
                $stressTestFailures += "Node '$destNodeName': Failed to start job - $($_.Exception.Message)"
            }
        } else {
            Write-Warning "Stress copy job skipped for node '$destNodeName' due to -WhatIf."
        }
    } 

    # Wait for jobs and process results
    if ($jobList.Count -gt 0) {
        Write-Host "Waiting for $($jobList.Count) stress copy jobs to complete (Timeout: $MaxWaitMinutes minutes)..."
        $jobsStartTimeWait = Get-Date
        $timeoutTime = $jobsStartTimeWait.AddMinutes($MaxWaitMinutes)
        $completedJobs = @()
        $runningJobs = @()
        $runningJobs += $jobList

        while ($runningJobs.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
            $finishedJobs = $runningJobs | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'NotStarted' }
            if ($finishedJobs.Count -gt 0) {
                $completedJobs += @($finishedJobs)
                $runningJobs = $runningJobs | Where-Object { $_ -notin $finishedJobs }
                Write-Verbose "$($finishedJobs.Count) job(s) finished. Remaining: $($runningJobs.Count)"
            }
            if ($runningJobs.Count -gt 0) { Start-Sleep -Seconds 5 }
        }

        if ($runningJobs.Count -gt 0) {
            Write-Warning "$($runningJobs.Count) job(s) did not complete within $MaxWaitMinutes minutes."
            foreach($timedOutJob in $runningJobs) {
                $targetNodeForError = $timedOutJob.Name 
                try { 
                    if ($timedOutJob.Command -match '-ArgumentList(?:.+?,){1}\s*(''?"?)(?<NodeName>[^,''"]+)\1') {
                        $targetNodeForError = $matches['NodeName']
                    }
                } catch {} 

                $failMsg = "Node '$targetNodeForError' (Job ID: $($timedOutJob.Id)): Job timed out."
                $stressTestFailures += $failMsg
                $overallStatus = "FAILURE"; $criticalErrorOccurred = $true
                try { Stop-Job -Job $timedOutJob -Force } catch { Write-Warning "Failed to stop timed out job $($timedOutJob.Id): $_"}
                $completedJobs.Add($timedOutJob) 
            }
        }

        $jobsEndTime = Get-Date
        $jobsDuration = New-TimeSpan -Start $jobsStartTime -End $jobsEndTime
        Write-Host "All job processing finished in $($jobsDuration.ToString()). Analyzing results..."

        # ===== PERFORMANCE METRICS COLLECTION =====
        Write-Host "`nCollecting performance metrics from all nodes..." -ForegroundColor Cyan
        $allPerformanceMetrics = @{}
        $globalPerformanceStats = @{
            TotalFilesTransferred = 0
            TotalDataTransferredGB = 0
            OverallDurationSeconds = 0
            NodeCount = 0
            AllThroughputs = @()
        }
        
        # Collect performance data from all completed jobs
        foreach ($job in $completedJobs) {
            try {
                $jobResult = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
                if ($jobResult -and $jobResult.PerformanceMetrics -and $jobResult.Node) {
                    $nodeName = $jobResult.Node
                    
                    if (-not $allPerformanceMetrics.ContainsKey($nodeName)) {
                        $allPerformanceMetrics[$nodeName] = @{
                            Metrics = @()
                            TotalFiles = 0
                            TotalDataGB = 0
                            TotalDurationSeconds = 0
                            MinThroughputMBps = [double]::MaxValue
                            MaxThroughputMBps = 0
                            AvgThroughputMBps = 0
                            ThroughputStdDev = 0
                            AllThroughputs = @()
                        }
                    }
                    
                    foreach ($metric in $jobResult.PerformanceMetrics) {
                        $allPerformanceMetrics[$nodeName].Metrics += $metric
                        $allPerformanceMetrics[$nodeName].TotalFiles++
                        $allPerformanceMetrics[$nodeName].TotalDataGB += $metric.FileSizeGB
                        $allPerformanceMetrics[$nodeName].TotalDurationSeconds += $metric.DurationSeconds
                        $allPerformanceMetrics[$nodeName].AllThroughputs += $metric.ThroughputMBps
                        
                        # Track min/max
                        if ($metric.ThroughputMBps -lt $allPerformanceMetrics[$nodeName].MinThroughputMBps) {
                            $allPerformanceMetrics[$nodeName].MinThroughputMBps = $metric.ThroughputMBps
                        }
                        if ($metric.ThroughputMBps -gt $allPerformanceMetrics[$nodeName].MaxThroughputMBps) {
                            $allPerformanceMetrics[$nodeName].MaxThroughputMBps = $metric.ThroughputMBps
                        }
                        
                        # Global stats
                        $globalPerformanceStats.TotalFilesTransferred++
                        $globalPerformanceStats.TotalDataTransferredGB += $metric.FileSizeGB
                        $globalPerformanceStats.OverallDurationSeconds += $metric.DurationSeconds
                        $globalPerformanceStats.AllThroughputs += $metric.ThroughputMBps
                    }
                    
                    # Calculate statistics for this node
                    if ($allPerformanceMetrics[$nodeName].TotalFiles -gt 0) {
                        $avgThroughput = ($allPerformanceMetrics[$nodeName].AllThroughputs | Measure-Object -Average).Average
                        $allPerformanceMetrics[$nodeName].AvgThroughputMBps = [Math]::Round($avgThroughput, 2)
                        
                        # Calculate standard deviation
                        if ($allPerformanceMetrics[$nodeName].AllThroughputs.Count -gt 1) {
                            $variance = 0
                            foreach ($throughput in $allPerformanceMetrics[$nodeName].AllThroughputs) {
                                $variance += [Math]::Pow($throughput - $avgThroughput, 2)
                            }
                            $variance = $variance / ($allPerformanceMetrics[$nodeName].AllThroughputs.Count - 1)
                            $allPerformanceMetrics[$nodeName].ThroughputStdDev = [Math]::Round([Math]::Sqrt($variance), 2)
                        }
                    }
                }
            } catch {
                Write-Warning "Failed to extract performance metrics from job: $_"
            }
        }
        
        $globalPerformanceStats.NodeCount = $allPerformanceMetrics.Count
        
        # ===== PERFORMANCE REPORTING =====
        if ($allPerformanceMetrics.Count -gt 0) {
            Write-Host "`n================ RDMA TRANSFER PERFORMANCE ================" -ForegroundColor Cyan
            Write-Host "Performance metrics collected during file transfers" -ForegroundColor White
            Write-Host "==========================================================" -ForegroundColor Cyan
            
            foreach ($nodeName in ($allPerformanceMetrics.Keys | Sort-Object)) {
                $nodePerf = $allPerformanceMetrics[$nodeName]
                Write-Host "`nNode: $nodeName" -ForegroundColor Yellow
                Write-Host "-----------------------------------------" -ForegroundColor Gray
                
                if ($nodePerf.TotalFiles -gt 0) {
                    # Display metrics
                    Write-Host "  Files Transferred: $($nodePerf.TotalFiles)" -ForegroundColor White
                    Write-Host "  Total Data: $([Math]::Round($nodePerf.TotalDataGB, 2)) GB" -ForegroundColor White
                    Write-Host "  Total Duration: $([Math]::Round($nodePerf.TotalDurationSeconds, 2)) seconds" -ForegroundColor White
                    
                    # Throughput metrics
                    Write-Host "`n  Throughput Statistics:" -ForegroundColor Cyan
                    Write-Host "    Average: $($nodePerf.AvgThroughputMBps) MB/s" -ForegroundColor White
                    Write-Host "    Minimum: $($nodePerf.MinThroughputMBps) MB/s" -ForegroundColor White
                    Write-Host "    Maximum: $($nodePerf.MaxThroughputMBps) MB/s" -ForegroundColor White
                    
                    # Standard deviation (consistency indicator)
                    if ($nodePerf.ThroughputStdDev -gt 0) {
                        $coefficientOfVariation = [Math]::Round(($nodePerf.ThroughputStdDev / $nodePerf.AvgThroughputMBps) * 100, 1)
                        Write-Host "    Std Dev: $($nodePerf.ThroughputStdDev) MB/s (CV: $coefficientOfVariation%)" -ForegroundColor White
                    }
                    
                    # Effective transfer rate
                    if ($nodePerf.TotalDurationSeconds -gt 0) {
                        $effectiveRate = ($nodePerf.TotalDataGB * 1024) / $nodePerf.TotalDurationSeconds
                        Write-Host "    Effective Rate: $([Math]::Round($effectiveRate, 2)) MB/s (aggregate)" -ForegroundColor White
                    }
                    
                    # Show individual file performance if only a few files
                    if ($nodePerf.Metrics.Count -le 5) {
                        Write-Host "`n  Individual File Transfers:" -ForegroundColor Cyan
                        foreach ($metric in $nodePerf.Metrics) {
                            Write-Host "    - $($metric.FileName): $($metric.ThroughputMBps) MB/s in $($metric.DurationSeconds)s" -ForegroundColor White
                        }
                    }
                } else {
                    Write-Host "  No performance data collected" -ForegroundColor Gray
                }
            }
            
            # Global Performance Summary
            Write-Host "`n================ AGGREGATE PERFORMANCE SUMMARY ================" -ForegroundColor Cyan
            if ($globalPerformanceStats.TotalFilesTransferred -gt 0) {
                $globalAvgThroughput = ($globalPerformanceStats.AllThroughputs | Measure-Object -Average).Average
                $globalMinThroughput = ($globalPerformanceStats.AllThroughputs | Measure-Object -Minimum).Minimum
                $globalMaxThroughput = ($globalPerformanceStats.AllThroughputs | Measure-Object -Maximum).Maximum
                
                Write-Host "Total Files Transferred: $($globalPerformanceStats.TotalFilesTransferred)" -ForegroundColor White
                Write-Host "Total Data Transferred: $([Math]::Round($globalPerformanceStats.TotalDataTransferredGB, 2)) GB" -ForegroundColor White
                Write-Host "Total Nodes: $($globalPerformanceStats.NodeCount)" -ForegroundColor White
                Write-Host "`nAggregate Throughput Statistics:" -ForegroundColor Cyan
                Write-Host "  Average: $([Math]::Round($globalAvgThroughput, 2)) MB/s" -ForegroundColor White
                Write-Host "  Minimum: $([Math]::Round($globalMinThroughput, 2)) MB/s" -ForegroundColor White
                Write-Host "  Maximum: $([Math]::Round($globalMaxThroughput, 2)) MB/s" -ForegroundColor White
                
                # Performance distribution using absolute ranges
                Write-Host "`nThroughput Distribution:" -ForegroundColor Cyan
                
                # Determine range dynamically based on observed values
                $rangeSize = 200  # 200 MB/s buckets
                $minRange = [Math]::Floor($globalMinThroughput / $rangeSize) * $rangeSize
                $maxRange = [Math]::Ceiling($globalMaxThroughput / $rangeSize) * $rangeSize
                
                for ($rangeStart = $minRange; $rangeStart -lt $maxRange; $rangeStart += $rangeSize) {
                    $rangeEnd = $rangeStart + $rangeSize
                    $count = ($globalPerformanceStats.AllThroughputs | Where-Object { $_ -ge $rangeStart -and $_ -lt $rangeEnd }).Count
                    
                    if ($count -gt 0) {
                        $percentage = [Math]::Round(($count / $globalPerformanceStats.TotalFilesTransferred) * 100, 1)
                        $barLength = [Math]::Floor($percentage / 2)
                        $bar = "#" * $barLength
                        
                        $rangeLabel = "$rangeStart-$rangeEnd MB/s"
                        Write-Host ("  {0,-20} [{1,-50}] {2,5}% ({3} files)" -f $rangeLabel, $bar, $percentage, $count) -ForegroundColor White
                    }
                }
                
                # Calculate percentiles with proper interpolation
                $sortedThroughputs = $globalPerformanceStats.AllThroughputs | Sort-Object
                $count = $sortedThroughputs.Count
                if ($count -gt 0) {
                    # Function to calculate percentile with linear interpolation
                    function Get-Percentile {
                        param($values, $percentile)
                        $n = $values.Count
                        if ($n -eq 1) { return $values[0] }
                        
                        $pos = ($n - 1) * ($percentile / 100)
                        $lower = [Math]::Floor($pos)
                        $upper = [Math]::Ceiling($pos)
                        
                        if ($lower -eq $upper) {
                            return $values[$lower]
                        } else {
                            # Linear interpolation
                            $weight = $pos - $lower
                            return $values[$lower] * (1 - $weight) + $values[$upper] * $weight
                        }
                    }
                    
                    $p50Value = Get-Percentile -values $sortedThroughputs -percentile 50
                    $p90Value = Get-Percentile -values $sortedThroughputs -percentile 90
                    $p95Value = Get-Percentile -values $sortedThroughputs -percentile 95
                    $p99Value = Get-Percentile -values $sortedThroughputs -percentile 99
                    
                    Write-Host "`nPerformance Percentiles:" -ForegroundColor Cyan
                    if ($count -le 10) {
                        Write-Host "  Note: Limited data points ($count) - percentiles may not be meaningful" -ForegroundColor Gray
                    }
                    Write-Host "  50th percentile (median): $([Math]::Round($p50Value, 2)) MB/s" -ForegroundColor White
                    Write-Host "  90th percentile: $([Math]::Round($p90Value, 2)) MB/s" -ForegroundColor White
                    Write-Host "  95th percentile: $([Math]::Round($p95Value, 2)) MB/s" -ForegroundColor White
                    Write-Host "  99th percentile: $([Math]::Round($p99Value, 2)) MB/s" -ForegroundColor White
                }
            }
            
            Write-Host "===============================================================" -ForegroundColor Cyan
            
            # Store performance summary for final results
            $globalPerformanceSummary = @{
                NodePerformance = $allPerformanceMetrics
                GlobalStats = $globalPerformanceStats
            }
        } else {
            Write-Host "`nNo performance metrics collected during the test." -ForegroundColor Yellow
        }

        # Collect final network statistics
        Write-Host "Collecting final network statistics..."
        foreach ($destNodeName in $preparedNodes) {
            if ($nodePacketStats.ContainsKey($destNodeName) -and $null -ne $nodePacketStats[$destNodeName].Initial) {
                $destSession = $destinationSessions | Where-Object { $_.ComputerName -eq $destNodeName }
                Write-Verbose "Collecting final network statistics for '$destNodeName'..."
                $finalNetworkStats = Get-RDMANetworkStats -Session $destSession

                if ($null -ne $finalNetworkStats) {
                    $nodePacketStats[$destNodeName].Final = $finalNetworkStats
                    $initialStats = $nodePacketStats[$destNodeName].Initial
                    $finalStats = $nodePacketStats[$destNodeName].Final

                    Write-Host "DEBUG - Final stats for '$destNodeName':" -ForegroundColor Magenta
                    if ($finalNetworkStats) {
                        Write-Host "  - AdapterStats available: $($null -ne $finalNetworkStats.AdapterStats)" -ForegroundColor Magenta
                        Write-Host "  - RDMAActivityStats available: $($null -ne $finalNetworkStats.RDMAActivityStats)" -ForegroundColor Magenta

                        if ($finalNetworkStats.RDMAActivityStats) {
                            Write-Host "  - RDMAActivityStats counters: $($finalNetworkStats.RDMAActivityStats.Count)" -ForegroundColor Magenta
                            if ($finalNetworkStats.RDMAActivityStats.Count -gt 0 -and $finalNetworkStats.RDMAActivityStats.Count -le 10) {
                                Write-Host "  - RDMAActivityStats keys: $($finalNetworkStats.RDMAActivityStats.Keys -join ', ')" -ForegroundColor Magenta
                            } elseif ($finalNetworkStats.RDMAActivityStats.Count -gt 10) {
                                $sampleKeys = $finalNetworkStats.RDMAActivityStats.Keys | Select-Object -First 5
                                Write-Host "  - RDMAActivityStats sample keys (first 5): $($sampleKeys -join ', ')..." -ForegroundColor Magenta
                            }
                        }
                    }
                    
                    # Collect network adapter stats
                    $adapterStatsDrops = 0
                    foreach ($adapterName in $finalStats.AdapterStats.Keys) {
                        if ($initialStats.AdapterStats.ContainsKey($adapterName)) {
                            $initialAdapter = $initialStats.AdapterStats[$adapterName]
                            $finalAdapter = $finalStats.AdapterStats[$adapterName]
                            $receivedDiscardedDelta = ([long]$finalAdapter.ReceivedDiscardedPackets) - ([long]$initialAdapter.ReceivedDiscardedPackets)
                            $outboundDiscardedDelta = ([long]$finalAdapter.OutboundDiscardedPackets) - ([long]$initialAdapter.OutboundDiscardedPackets)
                            $receivedErrorsDelta = ([long]$finalAdapter.ReceivedErrors) - ([long]$initialAdapter.ReceivedErrors)
                            $outboundErrorsDelta = ([long]$finalAdapter.OutboundErrors) - ([long]$initialAdapter.OutboundErrors)
        
                            if ($receivedDiscardedDelta -gt 0) { $adapterStatsDrops += $receivedDiscardedDelta }
                            if ($outboundDiscardedDelta -gt 0) { $adapterStatsDrops += $outboundDiscardedDelta }
                            if ($receivedErrorsDelta -gt 0) { $adapterStatsDrops += $receivedErrorsDelta }
                            if ($outboundErrorsDelta -gt 0) { $adapterStatsDrops += $outboundErrorsDelta }
                        }
                    }
                    $nodePacketStats[$destNodeName].NetworkAdapterDrops = $adapterStatsDrops
                    Write-Verbose "Node '$destNodeName': Network adapter drops/errors for reporting = $adapterStatsDrops"

                    # Analyze RDMA activity and connection stability
                    $rdmaDisruptionDetected = $false
                    $rdmaDisruptionReasons = @()
                    $rdmaActivityDetails = @{}

                    if ($null -ne $initialStats.RDMAActivityStats -and $null -ne $finalStats.RDMAActivityStats) {
                        Write-Verbose "Node '$destNodeName': Analyzing RDMA activity statistics..."
                        
                        $rdmaActivityDetails = @{
                            InitialStats = $initialStats.RDMAActivityStats
                            FinalStats = $finalStats.RDMAActivityStats
                            Changes = @{}
                        }
                        
                        $allKeys = @($initialStats.RDMAActivityStats.Keys) + @($finalStats.RDMAActivityStats.Keys) | Select-Object -Unique
                        
                        foreach ($key in $allKeys) {
                            $initialValue = if ($initialStats.RDMAActivityStats.ContainsKey($key)) { $initialStats.RDMAActivityStats[$key] } else { 0 }
                            $finalValue = if ($finalStats.RDMAActivityStats.ContainsKey($key)) { $finalStats.RDMAActivityStats[$key] } else { 0 }
                            $delta = $finalValue - $initialValue
                            
                            if ($delta -ne 0) {
                                $rdmaActivityDetails.Changes[$key] = @{
                                    Initial = $initialValue
                                    Final = $finalValue
                                    Delta = $delta
                                }
                                
                                Write-Verbose "Node '$destNodeName': RDMA Activity - $key changed from $initialValue to $finalValue (delta: $delta)"
                                
                                # Detect disruptions
                                if ($key -match 'Error|Fail|Retry|Reset|Timeout|Drop' -and $delta -gt 0) {
                                    $rdmaDisruptionDetected = $true
                                    $rdmaDisruptionReasons += "RDMA activity counter '$key' increased by $delta"
                                }
                                
                                if ($key -match 'Connect|Disconnect|State' -and $delta -lt 0) {
                                    $rdmaDisruptionDetected = $true
                                    $rdmaDisruptionReasons += "RDMA activity counter '$key' decreased by $([Math]::Abs($delta)) (possible disconnection)"
                                }
                            }
                        }
                        
                        # Log RDMA activity summary
                        Write-Host "Node '$destNodeName' RDMA Activity Summary:" -ForegroundColor Cyan
                        Write-Host "  - Total RDMA counters monitored: $($allKeys.Count)" -ForegroundColor Gray
                        Write-Host "  - Counters with changes: $($rdmaActivityDetails.Changes.Count)" -ForegroundColor Gray
                        
                        if ($rdmaActivityDetails.Changes.Count -gt 0) {
                            Write-Host "  - Key changes detected:" -ForegroundColor Gray
                            $rdmaActivityDetails.Changes.GetEnumerator() | Sort-Object Name | ForEach-Object {
                                $changeColor = if ($_.Key -match 'Error|Fail|Retry|Reset|Timeout|Drop' -and $_.Value.Delta -gt 0) { "Red" } else { "Yellow" }
                                Write-Host "    * $($_.Key): $($_.Value.Initial) -> $($_.Value.Final) (D $($_.Value.Delta))" -ForegroundColor $changeColor
                            }
                        }
                        
                        $nodePacketStats[$destNodeName].RDMADisruptionDetected = $rdmaDisruptionDetected
                        $nodePacketStats[$destNodeName].RDMADisruptionReasons = $rdmaDisruptionReasons
                        $nodePacketStats[$destNodeName].RDMAActivityDetails = $rdmaActivityDetails
                        
                    } else {
                        Write-Verbose "Node '$destNodeName': RDMA activity statistics not available for analysis."
                        $nodePacketStats[$destNodeName].RDMAAnalysisError = "RDMA activity stats unavailable"
                        
                        if ($null -eq $initialStats.RDMAActivityStats) {
                            Write-Verbose "Node '$destNodeName': Initial RDMA activity stats were null"
                        }
                        if ($null -eq $finalStats.RDMAActivityStats) {
                            Write-Verbose "Node '$destNodeName': Final RDMA activity stats were null"
                        }
                    }

                    # Update overall status
                    if ($rdmaDisruptionDetected) {
                        $failMsg = "Node '$destNodeName': RDMA disruption detected - $($rdmaDisruptionReasons -join '; ')"
                        Write-Warning $failMsg
                        $stressTestFailures += $failMsg
                        $overallStatus = "FAILURE"
                    } else {
                        Write-Verbose "Node '$destNodeName': RDMA connection remained stable throughout the test."
                    }
                } else {
                    Write-Warning "Could not collect final network statistics for '$destNodeName'."
                    $nodePacketStats[$destNodeName].StatsCollectionError = "Failed to collect final stats."
                }
            } else { Write-Verbose "Skipping final stats for '$destNodeName' (initial failed or not collected)." }
        }

        # Process job results
        foreach ($job in $completedJobs) {
            $jobNodeName = $job.Name 
            $jobStatus = $job.State
            $nodeJobResult = $null 
            $jobOutput = $null
            $jobHadNetworkInterrupt = $false

            $targetNodeForError = $job.Name
            try {
                if ($job.Command -match '-ArgumentList(?:.+?,){1}\s*(''?"?)(?<NodeName>[^,''"]+)\1') {
                    $targetNodeForError = $matches['NodeName']; $jobNodeName = $targetNodeForError
                }
            } catch { Write-Verbose "Could not parse node name from job command for job $($job.Id)."}

            try {
                Receive-Job -Job $job -Keep | Out-Null
                if ($job.Warning.Count -gt 0) {
                    foreach ($warningRecord in $job.Warning) {
                        if ($warningRecord.Message -match "network connection .* has been interrupted" -or
                            $warningRecord.Message -match "Attempting to reconnect" -or
                            $warningRecord.Message -match "WinRM cannot complete the operation" -or
                            $warningRecord.Message -match "connection to the remote server .* failed") {
                            $failMsg = "Node '$targetNodeForError' (Job ID: $($job.Id)): Detected network interruption/remoting warning: $($warningRecord.Message)"
                            Write-Warning $failMsg; $stressTestFailures += $failMsg
                            $overallStatus = "FAILURE"; $criticalErrorOccurred = $true; $jobHadNetworkInterrupt = $true
                            break 
                        }
                    }
                }
                if ($job.Error.Count -gt 0) {
                     foreach ($errorRecord in $job.Error) {
                        $errorMessageText = $errorRecord.Exception.ToString() 
                        if ($errorMessageText -match "network" -or $errorMessageText -match "connection" -or
                            $errorMessageText -match "timeout" -or $errorMessageText -match "WinRM" -or
                            $errorMessageText -match "unreachable" -or $errorMessageText -match "host") {
                            if (-not $jobHadNetworkInterrupt) { 
                                $failMsg = "Node '$targetNodeForError' (Job ID: $($job.Id)): Detected network-related error in job stream: $($errorRecord.Exception.Message)"
                                Write-Warning $failMsg; $stressTestFailures += $failMsg
                                $overallStatus = "FAILURE"; $criticalErrorOccurred = $true; $jobHadNetworkInterrupt = $true
                            }
                        }
                     }
                }

                $jobOutput = $job | Receive-Job -ErrorAction SilentlyContinue
                if (-not $jobHadNetworkInterrupt) {
                    if ($jobStatus -eq 'Completed' -and $null -ne $jobOutput) {
                        if ($jobOutput -is [array]) {
                            $nodeJobResult = $jobOutput | Where-Object {
                                ($psitem -is [hashtable] -and $psitem.ContainsKey('ResultType') -and $psitem.ResultType -eq 'RDMA_STRESS_RESULT') -or
                                ($psitem -is [PSCustomObject] -and $psitem.PSObject.Properties.Name -contains 'ResultType' -and $psitem.ResultType -eq 'RDMA_STRESS_RESULT')
                            } | Select-Object -First 1
                            if ($null -eq $nodeJobResult) {
                                $nodeJobResult = $jobOutput | Where-Object { ($psitem -is [hashtable] -and $psitem.ContainsKey('Node')) -or ($psitem -is [PSCustomObject] -and $psitem.PSObject.Properties.Name -contains 'Node')} | Select-Object -Last 1
                            }
                        } elseif (($jobOutput -is [hashtable] -and (($jobOutput.ContainsKey('ResultType') -and $jobOutput.ResultType -eq 'RDMA_STRESS_RESULT') -or $jobOutput.ContainsKey('Node'))) -or
                                  ($jobOutput -is [PSCustomObject] -and (($jobOutput.PSObject.Properties.Name -contains 'ResultType' -and $jobOutput.ResultType -eq 'RDMA_STRESS_RESULT') -or $jobOutput.PSObject.Properties.Name -contains 'Node'))) {
                            $nodeJobResult = $jobOutput
                        }

                        if ($null -eq $nodeJobResult) {
                            $failMsg = "Node '$targetNodeForError' (Job ID: $($job.Id)): Job completed but no result object. Output type: $($jobOutput.GetType().FullName)."
                            Write-Warning $failMsg; $stressTestFailures += $failMsg
                            $overallStatus = "FAILURE"; $criticalErrorOccurred = $true
                        }
                    }

                    if ($null -ne $nodeJobResult) {
                        $jobNodeName = $nodeJobResult.Node 

                        # Process errors from job (including RDMA reconnections and TCP fallback)
                        if ($nodeJobResult.Errors -and $nodeJobResult.Errors.Count -gt 0) {
                            $rdmaIssuesDetected = $false
                            $tcpFallbackDetected = $false
                    
                            foreach ($error in $nodeJobResult.Errors) {
                                if ($error -match "RDMA reconnection detected" -or $error -match "RDMA connections changed") {
                                    $rdmaIssuesDetected = $true
                                    # Override any counter-based analysis
                                    if ($nodePacketStats.ContainsKey($jobNodeName)) {
                                        $nodePacketStats[$jobNodeName].RDMADisruptionDetected = $true
                                        if (-not $nodePacketStats[$jobNodeName].ContainsKey('RDMADisruptionReasons')) {
                                            $nodePacketStats[$jobNodeName].RDMADisruptionReasons = @()
                                        }
                                        $nodePacketStats[$jobNodeName].RDMADisruptionReasons += "Live monitoring detected: $error"
                                    }
                                }
                                if ($error -match "TCP fallback detected") {
                                    $tcpFallbackDetected = $true
                                    # Override any counter-based analysis
                                    if ($nodePacketStats.ContainsKey($jobNodeName)) {
                                        $nodePacketStats[$jobNodeName].RDMADisruptionDetected = $true
                                        if (-not $nodePacketStats[$jobNodeName].ContainsKey('RDMADisruptionReasons')) {
                                            $nodePacketStats[$jobNodeName].RDMADisruptionReasons = @()
                                        }
                                        $nodePacketStats[$jobNodeName].RDMADisruptionReasons += "Live monitoring detected: $error"
                                    }
                                }
                            }
                    
                            # Mark as failure if RDMA issues detected
                            if ($rdmaIssuesDetected -or $tcpFallbackDetected) {
                                if (-not $stressTestFailures.Contains("Node '$jobNodeName': RDMA issues detected during file transfer")) {
                                    $stressTestFailures += "Node '$jobNodeName': RDMA issues detected during file transfer (reconnections/TCP fallback)"
                                }
                                $overallStatus = "FAILURE"
                            }
                        }

                        # Process RDMA states
                        if ($nodeJobResult.RDMAStates -and $nodeJobResult.RDMAStates.Count -gt 0) {
                            $rdmaInstabilityDetected = $false
                    
                            foreach ($rdmaState in $nodeJobResult.RDMAStates) {
                                if ($rdmaState.Before -and $rdmaState.After) {
                                    $beforeCount = $rdmaState.Before.ActiveRDMAConnections
                                    $afterCount = $rdmaState.After.ActiveRDMAConnections
                            
                                    if ($beforeCount -gt 0 -and $afterCount -gt 0 -and $beforeCount -ne $afterCount) {
                                        $rdmaInstabilityDetected = $true
                                    }
                            
                                    if ($rdmaState.After.TCPFallbackActive) {
                                        $rdmaInstabilityDetected = $true
                                    }
                                }
                            }
                    
                            if ($rdmaInstabilityDetected) {
                                $failMsg = "Node '$jobNodeName': RDMA instability/reconnection detected during file transfer (packet loss likely)"
                                if (-not ($stressTestFailures -contains $failMsg)) {
                                    $stressTestFailures += $failMsg
                                }
                                $overallStatus = "FAILURE"
                                $nodePacketStats[$jobNodeName].RDMAInstabilityDetected = $true
                            }
                        }
                
                        # Process SMB connections
                        if ($nodeJobResult.SMBConnections -and $nodeJobResult.SMBConnections.Count -gt 0) {
                            $smbConnectionLogs[$jobNodeName] = $nodeJobResult.SMBConnections
    
                            $peakSMBConnections = 0
                            $peakRDMAChannels = 0
                            $peakTotalChannels = 0
                            $rdmaUsage = $false

                            foreach ($connLog in $nodeJobResult.SMBConnections) {
                                if ($connLog.Before) {
                                    if ($connLog.Before.TotalConnections -gt $peakSMBConnections) {
                                        $peakSMBConnections = $connLog.Before.TotalConnections
                                    }
                                    if ($connLog.Before.RDMACapableConnections -gt $peakRDMAChannels) {
                                        $peakRDMAChannels = $connLog.Before.RDMACapableConnections
                                    }
                                    if ($connLog.Before.RDMACapableConnections -gt 0) {
                                        $rdmaUsage = $true
                                    }
                                    # Calculate total channels from connection details
                                    if ($connLog.Before.Details) {
                                        $totalChannels = ($connLog.Before.Details | ForEach-Object { $_.MultiChannelCount } | Measure-Object -Sum).Sum
                                        if ($totalChannels -gt $peakTotalChannels) {
                                            $peakTotalChannels = $totalChannels
                                        }
                                    }
                                }

                                if ($connLog.After) {
                                    if ($connLog.After.TotalConnections -gt $peakSMBConnections) {
                                        $peakSMBConnections = $connLog.After.TotalConnections
                                    }
                                    if ($connLog.After.RDMACapableConnections -gt $peakRDMAChannels) {
                                        $peakRDMAChannels = $connLog.After.RDMACapableConnections
                                    }
                                    if ($connLog.After.RDMACapableConnections -gt 0) {
                                        $rdmaUsage = $true
                                    }
                                    # Calculate total channels from connection details
                                    if ($connLog.After.Details) {
                                        $totalChannels = ($connLog.After.Details | ForEach-Object { $_.MultiChannelCount } | Measure-Object -Sum).Sum
                                        if ($totalChannels -gt $peakTotalChannels) {
                                            $peakTotalChannels = $totalChannels
                                        }
                                    }
                                }

                                if ($connLog.Connection) {
                                    if ($connLog.Connection.TotalConnections -gt $peakSMBConnections) {
                                        $peakSMBConnections = $connLog.Connection.TotalConnections
                                    }
                                    if ($connLog.Connection.RDMACapableConnections -gt $peakRDMAChannels) {
                                        $peakRDMAChannels = $connLog.Connection.RDMACapableConnections
                                    }
                                    if ($connLog.Connection.RDMACapableConnections -gt 0) {
                                        $rdmaUsage = $true
                                    }
                                    # Calculate total channels from connection details
                                    if ($connLog.Connection.Details) {
                                        $totalChannels = ($connLog.Connection.Details | ForEach-Object { $_.MultiChannelCount } | Measure-Object -Sum).Sum
                                        if ($totalChannels -gt $peakTotalChannels) {
                                            $peakTotalChannels = $totalChannels
                                        }
                                    }
                                }
                            }

                            # Use total channels if available, otherwise use RDMA channels as total
                            if ($peakTotalChannels -eq 0) {
                                $peakTotalChannels = $peakRDMAChannels
                            }

                            $rdmaPercentage = if ($peakTotalChannels -gt 0) { 
                                [Math]::Round(($peakRDMAChannels / $peakTotalChannels) * 100, 1)
                            } else { 0 }
    
                            Write-Verbose "Node '$jobNodeName': RDMA was detected in $peakRDMAChannels out of $peakTotalChannels channels ($rdmaPercentage%)."
    
                            if ($nodePacketStats.ContainsKey($jobNodeName)) {
                                $nodePacketStats[$jobNodeName].PeakSMBConnections = $peakSMBConnections
                                $nodePacketStats[$jobNodeName].PeakRDMAChannels = $peakRDMAChannels
                                $nodePacketStats[$jobNodeName].PeakTotalChannels = $peakTotalChannels
                                $nodePacketStats[$jobNodeName].RDMAUsagePercentage = $rdmaPercentage
                                $nodePacketStats[$jobNodeName].RDMAUsed = $rdmaUsage
                            }
                        }
                
                        if ($nodeJobResult.Status -ne 'Success') {
                            $failMsg = "Node '$jobNodeName': Reported copy failure(s): $($nodeJobResult.Errors -join '; ')"
                            Write-Warning $failMsg; $stressTestFailures += $failMsg
                            $overallStatus = "FAILURE"; $criticalErrorOccurred = $true
                        } else {
                            Write-Verbose "Node '$jobNodeName': Copies reported successful."
                            # Don't report as PASSED if RDMA issues were detected
                            if ($nodePacketStats.ContainsKey($jobNodeName) -and -not $nodePacketStats[$jobNodeName].RDMADisruptionDetected) {
                                Write-Host "Node '$jobNodeName': S2D stress test sub-tasks PASSED (Copy OK, No RDMA issues detected)." -ForegroundColor Green
                            }
                        }
                    } else { 
                        $jobErrorReason = "Unknown Failure or Missing Output"
                        if ($job.JobStateInfo -and $job.JobStateInfo.Reason) { $jobErrorReason = $job.JobStateInfo.Reason.Message }
                        $errorMessage = "Node '$targetNodeForError' (Job ID: $($job.Id)): Job finished with state '$($jobStatus)'. Reason: $jobErrorReason."
                        Write-Warning $errorMessage; $stressTestFailures.Add($errorMessage)
                        $overallStatus = "FAILURE"; $criticalErrorOccurred = $true
                    }
                } else {
                     Write-Warning "Node '$targetNodeForError' (Job ID: $($job.Id)): Skipping result processing due to network interruption."
                }
            } catch {
                $errorProcessingJob = $_.Exception.Message
                Write-Warning "Error processing result for Job ID $($job.Id) (node '$targetNodeForError'): $errorProcessingJob"
                $overallStatus = "FAILURE"; $criticalErrorOccurred = $true
                $stressTestFailures.Add("Node '$targetNodeForError' (Job ID: $($job.Id)): Error during results processing - $errorProcessingJob")
            } finally {
                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    } else { 
        if (-not $PSCmdlet.ShouldProcess("AnyNode", "Start Stress Copy Job")) { 
            $overallStatus = "SKIPPED"
            $stressTestFailures.Add("Stress test skipped due to -WhatIf.")
        } else {
            if($overallStatus -ne "FAILURE"){ 
                $overallStatus = "FAILURE"; $criticalErrorOccurred = $true;
                $stressTestFailures.Add("No stress test jobs initiated. Check preparation errors.")
            }
        }
    }

    # RDMA Connection Stability Analysis
    Write-Host "======== RDMA CONNECTION STABILITY ANALYSIS ========" -ForegroundColor Cyan
    Write-Host "Analyzing RDMA connection stability during stress test..." -ForegroundColor Cyan
    Write-Host "" -ForegroundColor Cyan

    $overallRDMAStable = $true
    $totalNetworkDropsReported = 0

    foreach ($nodeName in ($nodePacketStats.Keys | Where-Object { $_ -notlike '_*' } | Sort-Object)) {
        if ($nodePacketStats[$nodeName].Initial -and $nodePacketStats[$nodeName].Final) {
            Write-Host "Node '$nodeName':" -ForegroundColor Cyan
            
            # Show network adapter stats
            if ($nodePacketStats[$nodeName].ContainsKey('NetworkAdapterDrops')) {
                $networkDrops = $nodePacketStats[$nodeName].NetworkAdapterDrops
                $totalNetworkDropsReported += $networkDrops
                Write-Host "  Network Adapter Statistics:" -ForegroundColor Gray
                Write-Host "    Drops/Errors Detected: $networkDrops" -ForegroundColor $(if ($networkDrops -gt 0) { "Yellow" } else { "Gray" })
                Write-Host "    (Informational only - not used for pass/fail)" -ForegroundColor Gray
            }
            
            # Show RDMA connection stability
            Write-Host "  RDMA Connection Stability:" -ForegroundColor Gray
            if ($nodePacketStats[$nodeName].ContainsKey('RDMADisruptionDetected')) {
                if ($nodePacketStats[$nodeName].RDMADisruptionDetected) {
                    $overallRDMAStable = $false
                    Write-Host "    Status: DISRUPTION DETECTED" -ForegroundColor Red
                    foreach ($reason in $nodePacketStats[$nodeName].RDMADisruptionReasons) {
                        Write-Host "      - $reason" -ForegroundColor Red
                    }
                    
                    # Show RDMA activity details if available
                    if ($nodePacketStats[$nodeName].ContainsKey('RDMAActivityDetails') -and 
                        $nodePacketStats[$nodeName].RDMAActivityDetails.Changes.Count -gt 0) {
                        Write-Host "    RDMA Activity Changes:" -ForegroundColor Yellow
                        $nodePacketStats[$nodeName].RDMAActivityDetails.Changes.GetEnumerator() | 
                            Where-Object { $_.Key -match 'Error|Fail|Retry|Reset|Timeout|Drop' } | 
                            Sort-Object Name | Select-Object -First 5 | ForEach-Object {
                            Write-Host "      - $($_.Key): +$($_.Value.Delta)" -ForegroundColor Yellow
                        }
                    }
                } else {
                    Write-Host "    Status: STABLE" -ForegroundColor Green
                    Write-Host "      - No RDMA activity errors detected" -ForegroundColor Green
                    
                    # Show positive RDMA activity if available
                    if ($nodePacketStats[$nodeName].ContainsKey('RDMAActivityDetails') -and 
                        $nodePacketStats[$nodeName].RDMAActivityDetails.Changes.Count -gt 0) {
                        $positiveChanges = $nodePacketStats[$nodeName].RDMAActivityDetails.Changes.GetEnumerator() | 
                            Where-Object { $_.Key -notmatch 'Error|Fail|Retry|Reset|Timeout|Drop' -and $_.Value.Delta -gt 0 } | 
                            Select-Object -First 3
                        if ($positiveChanges) {
                            Write-Host "    RDMA Activity (Normal):" -ForegroundColor Gray
                            $positiveChanges | ForEach-Object {
                                Write-Host "      - $($_.Key): +$($_.Value.Delta)" -ForegroundColor Gray
                            }
                        }
                    }
                }
            } else {
                Write-Host "    Status: UNKNOWN (analysis data unavailable)" -ForegroundColor Yellow
                if ($nodePacketStats[$nodeName].ContainsKey('RDMAAnalysisError')) {
                    Write-Host "      - $($nodePacketStats[$nodeName].RDMAAnalysisError)" -ForegroundColor Yellow
                }
            }
            Write-Host ""
        } else {
            Write-Host "Node '$nodeName': Stats collection failed - $($nodePacketStats[$nodeName].StatsCollectionError)" -ForegroundColor Red
            Write-Host ""
        }
    }

    if ($totalNetworkDropsReported -gt 0) {
        Write-Host "Network Adapter Drop/Error Summary (Informational):" -ForegroundColor Yellow
        Write-Host "  Total drops/errors across all nodes: $totalNetworkDropsReported" -ForegroundColor Yellow
        Write-Host "  Note: These statistics are for diagnostic purposes only." -ForegroundColor Gray
        Write-Host ""
    }

    if ($overallRDMAStable) {
        Write-Host "RESULT: RDMA connections remained stable throughout the test." -ForegroundColor Green
    } else {
        Write-Host "RESULT: RDMA connection disruptions detected. Test FAILED." -ForegroundColor Red
    }
    Write-Host "================================================" -ForegroundColor Cyan

    # Process SMB Connection Information
    Write-Host "======== SMB CONNECTION ANALYSIS ========" -ForegroundColor Cyan
    Write-Host "SMB Connection log file: $logFilePath" -ForegroundColor Cyan
    
    if ($smbConnectionLogs.Count -gt 0) {
        foreach ($nodeName in ($smbConnectionLogs.Keys | Where-Object { $_ -notlike '_*' } | Sort-Object)) {
            Write-Host "SMB Connections for node '$nodeName':" -ForegroundColor Cyan
    
            $nodeConnections = $smbConnectionLogs[$nodeName]
            $peakSMBConnections = 0
            $peakRDMAChannels = 0
            $peakTotalChannels = 0
            $rdmaUsage = $false
    
            foreach ($connEntry in $nodeConnections) {
                if ($connEntry.Before) {
                    if ($connEntry.Before.TotalConnections -gt $peakSMBConnections) {
                        $peakSMBConnections = $connEntry.Before.TotalConnections
                    }
                    if ($connEntry.Before.RDMACapableConnections -gt $peakRDMAChannels) {
                        $peakRDMAChannels = $connEntry.Before.RDMACapableConnections
                    }
                    if ($connEntry.Before.RDMACapableConnections -gt 0) {
                        $rdmaUsage = $true
                    }
                    if ($connEntry.Before.Details) {
                        $totalChannels = ($connEntry.Before.Details | ForEach-Object { $_.MultiChannelCount } | Measure-Object -Sum).Sum
                        if ($totalChannels -gt $peakTotalChannels) {
                            $peakTotalChannels = $totalChannels
                        }
                    }
                }
        
                if ($connEntry.After) {
                    if ($connEntry.After.TotalConnections -gt $peakSMBConnections) {
                        $peakSMBConnections = $connEntry.After.TotalConnections
                    }
                    if ($connEntry.After.RDMACapableConnections -gt $peakRDMAChannels) {
                        $peakRDMAChannels = $connEntry.After.RDMACapableConnections
                    }
                    if ($connEntry.After.RDMACapableConnections -gt 0) {
                        $rdmaUsage = $true
                    }
                    if ($connEntry.After.Details) {
                        $totalChannels = ($connEntry.After.Details | ForEach-Object { $_.MultiChannelCount } | Measure-Object -Sum).Sum
                        if ($totalChannels -gt $peakTotalChannels) {
                            $peakTotalChannels = $totalChannels
                        }
                    }
                }
        
                if ($connEntry.Connection) {
                    if ($connEntry.Connection.TotalConnections -gt $peakSMBConnections) {
                        $peakSMBConnections = $connEntry.Connection.TotalConnections
                    }
                    if ($connEntry.Connection.RDMACapableConnections -gt $peakRDMAChannels) {
                        $peakRDMAChannels = $connEntry.Connection.RDMACapableConnections
                    }
                    if ($connEntry.Connection.RDMACapableConnections -gt 0) {
                        $rdmaUsage = $true
                    }
                    if ($connEntry.Connection.Details) {
                        $totalChannels = ($connEntry.Connection.Details | ForEach-Object { $_.MultiChannelCount } | Measure-Object -Sum).Sum
                        if ($totalChannels -gt $peakTotalChannels) {
                            $peakTotalChannels = $totalChannels
                        }
                    }
                }
            }
    
            # Use total channels if available, otherwise use RDMA channels as total
            if ($peakTotalChannels -eq 0) {
                $peakTotalChannels = $peakRDMAChannels
            }
    
            $rdmaUsageText = if ($rdmaUsage) { "YES" } else { "NO" }
            $rdmaPercentage = if ($peakTotalChannels -gt 0) {
                [Math]::Round(($peakRDMAChannels / $peakTotalChannels) * 100, 1)
            } else { 0 }
    
            Write-Host "  - SMB Connections: $peakSMBConnections" -ForegroundColor Cyan
            Write-Host "  - Total Multichannel Connections: $peakTotalChannels" -ForegroundColor Cyan
            Write-Host "  - RDMA-enabled Channels: $peakRDMAChannels ($rdmaPercentage%)" -ForegroundColor $(if ($rdmaUsage) { "Green" } else { "Yellow" })
            Write-Host "  - RDMA Used: $rdmaUsageText" -ForegroundColor $(if ($rdmaUsage) { "Green" } else { "Yellow" })
    
            if ($nodePacketStats.ContainsKey($nodeName)) {
                $nodePacketStats[$nodeName].PeakSMBConnections = $peakSMBConnections
                $nodePacketStats[$nodeName].PeakRDMAChannels = $peakRDMAChannels
                $nodePacketStats[$nodeName].PeakTotalChannels = $peakTotalChannels
                $nodePacketStats[$nodeName].RDMAUsagePercentage = $rdmaPercentage
                $nodePacketStats[$nodeName].RDMAUsed = $rdmaUsage
            }
    
            if (-not $rdmaUsage) {
                $failMsg = "Node '$nodeName': RDMA not utilized during file copy operations. SMB connections did not use RDMA capability."
                Write-Warning $failMsg
                $stressTestFailures += $failMsg
                $rdmaDisruptionOccurred = $true
            }
        }
    } else {
        Write-Warning "No SMB connection data collected during the test."
    }
    Write-Host "================================================" -ForegroundColor Cyan

    # ===== COLLECT AND LOG RDMA DIAGNOSTICS ON FAILURE =====
    if ($overallStatus -eq "FAILURE") {
        Write-Host "`n======== COLLECTING RDMA DIAGNOSTICS (FAILURE DETECTED) ========" -ForegroundColor Yellow
        Write-Host "Running diagnostic commands and logging to: $logFilePath" -ForegroundColor Yellow
        
        # Helper function to append diagnostics to log file
        function Write-DiagnosticsToLog {
            param(
                [string]$NodeName,
                [string]$DiagnosticType,
                [object]$DiagnosticData
            )
            
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
            $diagJson = $DiagnosticData | ConvertTo-Json -Compress -Depth 3
            $logEntry = "$timestamp,$NodeName,DIAGNOSTIC_$DiagnosticType,0,0,$diagJson"
            
            # Thread-safe file writing
            $maxRetries = 5
            $retryCount = 0
            $retryDelay = 100
            $writeSuccess = $false
            
            while (-not $writeSuccess -and $retryCount -lt $maxRetries) {
                try {
                    $fileStream = [System.IO.FileStream]::new(
                        $LogFilePath,
                        [System.IO.FileMode]::Append,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::ReadWrite
                    )
                    
                    $streamWriter = [System.IO.StreamWriter]::new($fileStream)
                    $streamWriter.WriteLine($logEntry)
                    $streamWriter.Flush()
                    $streamWriter.Close()
                    $fileStream.Close()
                    
                    $writeSuccess = $true
                }
                catch {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Start-Sleep -Milliseconds $retryDelay
                        $retryDelay *= 2
                    }
                    else {
                        Write-Warning "Failed to write diagnostic data to log file: $_"
                    }
                }
                finally {
                    if ($null -ne $streamWriter) { $streamWriter.Dispose() }
                    if ($null -ne $fileStream) { $fileStream.Dispose() }
                }
            }
        }
        
        # Collect diagnostics from local node
        Write-Host "`nCollecting diagnostics from local node: $localComputerName" -ForegroundColor Cyan
        try {
            # Get-NetAdapterRdma
            $localRdmaAdapters = Get-NetAdapterRdma -ErrorAction SilentlyContinue | 
                Select-Object Name, InterfaceDescription, Enabled, Operational, 
                              MaxQueuePairCount, MaxCompletionQueueCount, MaxMemoryRegionCount
            
            if ($localRdmaAdapters) {
                Write-Host "  - Found $(@($localRdmaAdapters).Count) RDMA adapter(s)" -ForegroundColor Green
                Write-DiagnosticsToLog -NodeName $localComputerName -DiagnosticType "NetAdapterRdma" -DiagnosticData $localRdmaAdapters
            } else {
                Write-Host "  - No RDMA adapters found" -ForegroundColor Red
                Write-DiagnosticsToLog -NodeName $localComputerName -DiagnosticType "NetAdapterRdma" -DiagnosticData @{Error="No RDMA adapters found"}
            }
            
            # Get-NetAdapterQos
            $localQosConfig = Get-NetAdapterQos -ErrorAction SilentlyContinue | 
                Select-Object Name, Enabled, Operational, DcbxSupport, 
                              NumberOfTrafficClasses, PriorityFlowControl, EnhancedTransmissionSelection
            
            if ($localQosConfig) {
                Write-Host "  - Found QoS configuration for $(@($localQosConfig).Count) adapter(s)" -ForegroundColor Green
                Write-DiagnosticsToLog -NodeName $localComputerName -DiagnosticType "NetAdapterQos" -DiagnosticData $localQosConfig
            } else {
                Write-Host "  - No QoS configuration found" -ForegroundColor Red
                Write-DiagnosticsToLog -NodeName $localComputerName -DiagnosticType "NetAdapterQos" -DiagnosticData @{Error="No QoS configuration found"}
            }
            
        } catch {
            Write-Warning "Failed to collect diagnostics from local node: $_"
            Write-DiagnosticsToLog -NodeName $localComputerName -DiagnosticType "Error" -DiagnosticData @{Error=$_.ToString()}
        }
        
        # Collect diagnostics from remote nodes
        foreach ($session in $destinationSessions) {
            $nodeName = $session.ComputerName
            Write-Host "`nCollecting diagnostics from remote node: $nodeName" -ForegroundColor Cyan
            
            try {
                $remoteDiagnostics = Invoke-Command -Session $session -ScriptBlock {
                    $results = @{
                        RdmaAdapters = $null
                        QosConfig = $null
                        Errors = @()
                        QosFlowControl = $null
                        QosTrafficClass = $null
                        QosPolicy = $null
                        DcbxSettings = $null
                        SmbClientConfig = $null
                        SmbServerConfig = $null
                        SmbMultichannelConnections = $null
                        SmbSessions = $null
                        AdapterAdvancedProperties = $null
                        AdapterBindings = $null
                        FirewallRules = $null
                        NetworkRoutes = $null
                        RdmaPerformanceCounters = $null
                        RecentEventLogs = $null
                        NetOffloadSettings = $null
                    }
    
                    try {
                        $results.RdmaAdapters = Get-NetAdapterRdma -ErrorAction Stop | 
                            Select-Object Name, InterfaceDescription, Enabled, Operational, 
                                          MaxQueuePairCount, MaxCompletionQueueCount, MaxMemoryRegionCount
                    } catch {
                        $results.Errors += "Get-NetAdapterRdma failed: $_"
                    }
    
                    try {
                        $results.QosConfig = Get-NetAdapterQos -ErrorAction Stop | 
                            Select-Object Name, Enabled, Operational, DcbxSupport, 
                                          NumberOfTrafficClasses, PriorityFlowControl, EnhancedTransmissionSelection
                    } catch {
                        $results.Errors += "Get-NetAdapterQos failed: $_"
                    }
    
                    try {
                        $results.QosFlowControl = Get-NetQosFlowControl -ErrorAction Stop | 
                            Select-Object Priority, Enabled
                    } catch {
                        $results.Errors += "Get-NetQosFlowControl failed: $_"
                    }
    
                    try {
                        $results.QosTrafficClass = Get-NetQosTrafficClass -ErrorAction Stop | 
                            Select-Object Name, Priority, BandwidthPercentage, Algorithm
                    } catch {
                        $results.Errors += "Get-NetQosTrafficClass failed: $_"
                    }
    
                    try {
                        $results.QosPolicy = Get-NetQosPolicy -ErrorAction Stop | 
                            Select-Object Name, NetDirectPortMatchCondition, PriorityValue8021Action, 
                                          Template, Enabled, NetworkProfile
                    } catch {
                        $results.Errors += "Get-NetQosPolicy failed: $_"
                    }
    
                    try {
                        $results.DcbxSettings = Get-NetQosDcbxSetting -ErrorAction Stop | 
                            Select-Object InterfaceAlias, Willing, Mode
                    } catch {
                        $results.Errors += "Get-NetQosDcbxSetting failed: $_"
                    }
    
                    try {
                        $results.SmbClientConfig = Get-SmbClientConfiguration -ErrorAction Stop | 
                            Select-Object EnableMultiChannel, EnableLargeMtu, EnableBandwidthThrottling,
                                          EnableInsecureGuestLogons, UseOpportunisticLocking, 
                                          RequireSecuritySignature, ConnectionCountPerRssNetworkInterface,
                                          DirectoryCacheLifetime, MaximumConnectionCountPerServer
                    } catch {
                        $results.Errors += "Get-SmbClientConfiguration failed: $_"
                    }
    
                    try {
                        $results.SmbServerConfig = Get-SmbServerConfiguration -ErrorAction Stop | 
                            Select-Object EnableMultiChannel, EnableSMB1Protocol, EnableSMB2Protocol,
                                          EnableStrictNameChecking, AutoDisconnectTimeout,
                                          IrpStackSize, KeepAliveTime, MaxChannelPerSession,
                                          MaxSessionPerConnection, MaxThreadsPerQueue
                    } catch {
                        $results.Errors += "Get-SmbServerConfiguration failed: $_"
                    }
    
                    try {
                        $results.SmbMultichannelConnections = Get-SmbMultichannelConnection -ErrorAction Stop | 
                            Select-Object ServerName, ClientIpAddress, ServerIpAddress, 
                                          ClientInterfaceIndex, CurrentChannels, Failed, FailureCount,
                                          ClientRdmaCapable, ServerRdmaCapable, Selected,
                                          ClientRssCapable, ServerRssCapable
                    } catch {
                        $results.Errors += "Get-SmbMultichannelConnection failed: $_"
                    }
    
                    try {
                        $results.SmbSessions = Get-SmbSession -ErrorAction Stop | 
                            Select-Object ClientComputerName, ClientUserName, NumOpens,
                                          SessionId, Dialect, TransportName
                    } catch {
                        $results.Errors += "Get-SmbSession failed: $_"
                    }
    
                    try {
                        $rdmaAdapterNames = $results.RdmaAdapters | Where-Object { $_.Enabled } | Select-Object -ExpandProperty Name
                        $results.AdapterAdvancedProperties = @()
        
                        foreach ($adapterName in $rdmaAdapterNames) {
                            $props = Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction SilentlyContinue |
                                Where-Object { 
                                    $_.DisplayName -match 'Jumbo|MTU|RDMA|RoCE|Flow Control|Interrupt|RSS|VMQ|VLAN|Checksum|Offload|Buffer|PFC|DCB|QoS'
                                } | Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue
            
                            if ($props) {
                                $results.AdapterAdvancedProperties += $props
                            }
                        }
                    } catch {
                        $results.Errors += "Get-NetAdapterAdvancedProperty failed: $_"
                    }
    
                    try {
                        $results.AdapterBindings = Get-NetAdapterBinding -ErrorAction Stop | 
                            Where-Object { $_.Name -in $rdmaAdapterNames } |
                            Select-Object Name, DisplayName, ComponentID, Enabled
                    } catch {
                        $results.Errors += "Get-NetAdapterBinding failed: $_"
                    }
    
                    try {
                        $results.FirewallRules = Get-NetFirewallRule -ErrorAction Stop | 
                            Where-Object { 
                                $_.DisplayName -match 'SMB|445|5445|RDMA|Storage' -or 
                                $_.DisplayGroup -match 'File and Printer Sharing|Storage'
                            } | Select-Object DisplayName, Enabled, Direction, Action, 
                                             Protocol, LocalPort, RemotePort
                    } catch {
                        $results.Errors += "Get-NetFirewallRule failed: $_"
                    }
    
                    try {
                        $results.NetworkRoutes = Get-NetRoute -ErrorAction Stop | 
                            Where-Object { $_.DestinationPrefix -ne '0.0.0.0/0' } |
                            Select-Object DestinationPrefix, NextHop, InterfaceAlias, 
                                          InterfaceIndex, RouteMetric, State
                    } catch {
                        $results.Errors += "Get-NetRoute failed: $_"
                    }
    
                    try {
                        $rdmaCounters = @(
                            '\RDMA Activity(*)\*',
                            '\SMB Direct Connection(*)\*',
                            '\SMB Client Shares(*)\*',
                            '\Network Adapter(*)\*'
                        )
        
                        $results.RdmaPerformanceCounters = @{}
                        foreach ($counter in $rdmaCounters) {
                            try {
                                $samples = (Get-Counter -Counter $counter -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples |
                                    Select-Object Path, CookedValue
                                if ($samples) {
                                    $results.RdmaPerformanceCounters[$counter] = $samples
                                }
                            } catch {
                            }
                        }
                    } catch {
                        $results.Errors += "Performance counter collection failed: $_"
                    }
    
                    try {
                        $startTime = (Get-Date).AddMinutes(-10)
                        $results.RecentEventLogs = @{}
        
                        try {
                            $smbClientEvents = Get-WinEvent -FilterHashtable @{
                                LogName = 'Microsoft-Windows-SMBClient/Connectivity', 'Microsoft-Windows-SmbClient/Operational'
                                StartTime = $startTime
                                Level = 1,2,3
                            } -MaxEvents 50 -ErrorAction SilentlyContinue |
                                Select-Object TimeCreated, LevelDisplayName, Id, Message
            
                            if ($smbClientEvents) {
                                $results.RecentEventLogs['SMBClient'] = $smbClientEvents
                            }
                        } catch {}
        
                        try {
                            $systemEvents = Get-WinEvent -FilterHashtable @{
                                LogName = 'System'
                                StartTime = $startTime
                                ProviderName = 'Microsoft-Windows-Kernel-Network', 'NetBT', 'Tcpip'
                            } -MaxEvents 20 -ErrorAction SilentlyContinue |
                                Select-Object TimeCreated, LevelDisplayName, Id, Message
            
                            if ($systemEvents) {
                                $results.RecentEventLogs['System'] = $systemEvents
                            }
                        } catch {}
                    } catch {
                        $results.Errors += "Event log collection failed: $_"
                    }
    
                    try {
                        $results.NetOffloadSettings = @{}
                        foreach ($adapterName in $rdmaAdapterNames) {
                            $offloadSettings = Get-NetAdapterChecksumOffload -Name $adapterName -ErrorAction SilentlyContinue
                            $rscSettings = Get-NetAdapterRsc -Name $adapterName -ErrorAction SilentlyContinue
                            $lsoSettings = Get-NetAdapterLso -Name $adapterName -ErrorAction SilentlyContinue
            
                            $results.NetOffloadSettings[$adapterName] = @{
                                ChecksumOffload = $offloadSettings | Select-Object Name, IpIPv4Enabled, TcpIPv4Enabled, UdpIPv4Enabled
                                RSC = $rscSettings | Select-Object Name, IPv4Enabled, IPv6Enabled
                                LSO = $lsoSettings | Select-Object Name, IPv4Enabled, IPv6Enabled, MaximumPacketSize
                            }
                        }
                    } catch {
                        $results.Errors += "Network offload settings collection failed: $_"
                    }
    
                    return $results
                }
                
                # Log RDMA adapters
                if ($remoteDiagnostics.RdmaAdapters) {
                    Write-Host "  - Found $(@($remoteDiagnostics.RdmaAdapters).Count) RDMA adapter(s)" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetAdapterRdma" -DiagnosticData $remoteDiagnostics.RdmaAdapters
                } else {
                    Write-Host "  - No RDMA adapters found" -ForegroundColor Red
                    if ($remoteDiagnostics.Errors -match "Get-NetAdapterRdma") {
                        $errorMsg = $remoteDiagnostics.Errors | Where-Object { $_ -match "Get-NetAdapterRdma" } | Select-Object -First 1
                        Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetAdapterRdma" -DiagnosticData @{Error=$errorMsg}
                    } else {
                        Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetAdapterRdma" -DiagnosticData @{Error="No RDMA adapters found"}
                    }
                }
                
                # Log QoS config
                if ($remoteDiagnostics.QosConfig) {
                    Write-Host "  - Found QoS configuration for $(@($remoteDiagnostics.QosConfig).Count) adapter(s)" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetAdapterQos" -DiagnosticData $remoteDiagnostics.QosConfig
                } else {
                    Write-Host "  - No QoS configuration found" -ForegroundColor Red
                    if ($remoteDiagnostics.Errors -match "Get-NetAdapterQos") {
                        $errorMsg = $remoteDiagnostics.Errors | Where-Object { $_ -match "Get-NetAdapterQos" } | Select-Object -First 1
                        Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetAdapterQos" -DiagnosticData @{Error=$errorMsg}
                    } else {
                        Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetAdapterQos" -DiagnosticData @{Error="No QoS configuration found"}
                    }
                }

                if ($remoteDiagnostics.QosFlowControl) {
                    Write-Host "  - Found QoS Flow Control settings" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "QosFlowControl" -DiagnosticData $remoteDiagnostics.QosFlowControl
                }

                if ($remoteDiagnostics.QosTrafficClass) {
                    Write-Host "  - Found QoS Traffic Class configuration" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "QosTrafficClass" -DiagnosticData $remoteDiagnostics.QosTrafficClass
                }

                if ($remoteDiagnostics.QosPolicy) {
                    Write-Host "  - Found $(@($remoteDiagnostics.QosPolicy).Count) QoS policies" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "QosPolicy" -DiagnosticData $remoteDiagnostics.QosPolicy
                }

                if ($remoteDiagnostics.DcbxSettings) {
                    Write-Host "  - Found DCBx settings" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "DcbxSettings" -DiagnosticData $remoteDiagnostics.DcbxSettings
                }

                if ($remoteDiagnostics.SmbClientConfig) {
                    Write-Host "  - Collected SMB Client configuration" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "SmbClientConfig" -DiagnosticData $remoteDiagnostics.SmbClientConfig
                }

                if ($remoteDiagnostics.SmbServerConfig) {
                    Write-Host "  - Collected SMB Server configuration" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "SmbServerConfig" -DiagnosticData $remoteDiagnostics.SmbServerConfig
                }

                if ($remoteDiagnostics.SmbMultichannelConnections) {
                    Write-Host "  - Found $(@($remoteDiagnostics.SmbMultichannelConnections).Count) SMB Multichannel connections" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "SmbMultichannelConnections" -DiagnosticData $remoteDiagnostics.SmbMultichannelConnections
                }

                if ($remoteDiagnostics.AdapterAdvancedProperties -and $remoteDiagnostics.AdapterAdvancedProperties.Count -gt 0) {
                    Write-Host "  - Collected advanced properties for RDMA adapters" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "AdapterAdvancedProperties" -DiagnosticData $remoteDiagnostics.AdapterAdvancedProperties
                }

                if ($remoteDiagnostics.FirewallRules) {
                    Write-Host "  - Found $(@($remoteDiagnostics.FirewallRules).Count) relevant firewall rules" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "FirewallRules" -DiagnosticData $remoteDiagnostics.FirewallRules
                }

                if ($remoteDiagnostics.RdmaPerformanceCounters -and $remoteDiagnostics.RdmaPerformanceCounters.Count -gt 0) {
                    Write-Host "  - Collected RDMA performance counters" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "RdmaPerformanceCounters" -DiagnosticData $remoteDiagnostics.RdmaPerformanceCounters
                }

                if ($remoteDiagnostics.RecentEventLogs -and $remoteDiagnostics.RecentEventLogs.Count -gt 0) {
                    Write-Host "  - Collected recent event log entries" -ForegroundColor Yellow
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "RecentEventLogs" -DiagnosticData $remoteDiagnostics.RecentEventLogs
                }

                if ($remoteDiagnostics.NetOffloadSettings -and $remoteDiagnostics.NetOffloadSettings.Count -gt 0) {
                    Write-Host "  - Collected network offload settings" -ForegroundColor Green
                    Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "NetOffloadSettings" -DiagnosticData $remoteDiagnostics.NetOffloadSettings
                }

                if ($remoteDiagnostics.Errors.Count -gt 0) {
                    Write-Host "  - Diagnostic collection errors:" -ForegroundColor Red
                    foreach ($error in $remoteDiagnostics.Errors) {
                        Write-Host "    - $error" -ForegroundColor Red
                    }
                }
                
                # Log any other errors
                if ($remoteDiagnostics.Errors.Count -gt 0) {
                    foreach ($error in $remoteDiagnostics.Errors) {
                        Write-Warning "  - $error"
                    }
                }
                
            } catch {
                Write-Warning "Failed to collect diagnostics from node '$nodeName': $_"
                Write-DiagnosticsToLog -NodeName $nodeName -DiagnosticType "Error" -DiagnosticData @{Error=$_.ToString()}
            }
        }
        
        Write-Host "`nDiagnostic data has been appended to: $logFilePath" -ForegroundColor Green
        Write-Host "================================================================" -ForegroundColor Yellow
    }

    # Determine final severity
    if ($overallStatus -eq "FAILURE") {
        if ($criticalErrorOccurred) {
            $overallSeverity = "CRITICAL"
        } else {
            $overallSeverity = "WARNING"
        }
    } elseif ($overallStatus -eq "SUCCESS") {
        $overallSeverity = "INFORMATIONAL"
    } elseif ($overallStatus -eq "SKIPPED") {
        $overallSeverity = "INFORMATIONAL"
    }

    $finalDetail = ""
    $failureSummary = ""
    if ($stressTestFailures.Count -gt 0) {
        $failureSummary = "Failures reported: $($stressTestFailures -join ' | ')"
    }

    if ($overallStatus -eq "SKIPPED") {
        $finalDetail = "RDMA S2D Stress Test SKIPPED (e.g., due to -WhatIf)."
    } elseif ($overallStatus -eq "FAILURE") {
        $finalDetail = "RDMA S2D Stress Test resulted in $overallSeverity between '$localComputerName' and tested nodes ($($preparedNodes -join ', ')). $failureSummary"
    } else {
        $finalDetail = "RDMA S2D Stress Test PASSED between '$localComputerName' and $($preparedNodes.Count) node(s) ($($preparedNodes -join ', ')). Copies to S2D storage completed, no drops/errors, and no connection interruptions detected."
    }

    $remediationText = "N/A"
    if ($overallStatus -eq "FAILURE") {
        if ($overallSeverity -eq "CRITICAL") {
            $remediationText = "RDMA S2D Stress Test Failed (CRITICAL). "
            if ($failureSummary -match "interruption|WinRM|timeout|connection") { $remediationText += "Network connection/remoting errors detected. Check network stability, WinRM, firewalls, node resources. " }
            if ($totalNetworkDropsReported -gt 0) { $remediationText += "Packet drops/errors detected. Investigate network hardware, drivers, firmware, QoS, DCB, MTU. " }
            if ($failureSummary -match "FAILED copy|Access is denied|insufficient resources") { $remediationText += "File copy failures. Verify S2D cluster permissions, disk space, network paths. " }
            if ($failureSummary -match "timed out") { $remediationText += "Jobs timed out. Investigate performance bottlenecks or increase MaxWaitMinutes. " }
            if ($failureSummary -match "S2D path") { $remediationText += "S2D path issues detected. Verify S2D is correctly configured on cluster nodes. " }
            $remediationText += "Review all specific failure details logged."
        } elseif ($overallSeverity -eq "WARNING") { 
            if ($failureSummary -match "RDMA disruption detected") {
                $remediationText = "RDMA S2D Stress Test Warning: RDMA connection disruptions detected during file transfers. "
                $remediationText += "This indicates network instability causing RDMA reconnections or TCP fallback. "
                $remediationText += "Investigate: network hardware (NICs, switches, cables), drivers, firmware updates, "
                $remediationText += "QoS settings (PFC, ETS), DCB configuration, flow control, MTU consistency, switch buffer configuration. "
                $remediationText += "Review the detailed disruption reasons for each affected node."
            } elseif ($failureSummary -match "RDMA not utilized") {
                $remediationText = "RDMA S2D Stress Test Warning: RDMA capability not fully utilized during file transfers. "
                $remediationText += "Verify RDMA is properly configured on all nodes. Check network adapters support RDMA and have it enabled. Validate SMB Direct configuration. "
                $remediationText += "Review SMB connection details in the log file for more information."
            }
        }
    } elseif ($overallStatus -eq "SKIPPED") {
        $remediationText = "Test was skipped (e.g., due to -WhatIf)."
    }

    $stressTestResult = @{
        Name = "AzStackHci_RDMA_Test_S2DStressTestResult";
        Title = "RDMA S2D Concurrent Stress Test";
        DisplayName = "RDMA S2D Stress Test: $localComputerName -> $($preparedNodes.Count) Nodes";
        Severity = $overallSeverity;
        Description = "Performs concurrent large file copies to S2D cluster storage over RDMA. Verifies integrity, monitors network counters, detects interruptions.";
        Remediation = $remediationText;
        TargetResourceID = "ClusterRDMAConnectivity"; TargetResourceName = "RDMAS2DStressTest"; TargetResourceType = "Cluster";
        Timestamp = [datetime]::UtcNow; Status = $overallStatus;
        AdditionalData = @{
            Source = $localComputerName;
            Destinations = ($preparedNodes -join ', ');
            Resource = "RDMAS2DStressTest";
            Detail = $finalDetail;
            Status = $overallStatus;
            TimeStamp = [datetime]::UtcNow;
            PerformanceMetrics = if ($null -ne $globalPerformanceSummary) {
                @{
                    TotalFilesTransferred = $globalPerformanceSummary.GlobalStats.TotalFilesTransferred
                    TotalDataTransferredGB = [Math]::Round($globalPerformanceSummary.GlobalStats.TotalDataTransferredGB, 2)
                    AggregateAverageThroughputMBps = if ($globalPerformanceSummary.GlobalStats.AllThroughputs.Count -gt 0) {
                        [Math]::Round(($globalPerformanceSummary.GlobalStats.AllThroughputs | Measure-Object -Average).Average, 2)
                    } else { 0 }
                    AggregateMinThroughputMBps = if ($globalPerformanceSummary.GlobalStats.AllThroughputs.Count -gt 0) {
                        [Math]::Round(($globalPerformanceSummary.GlobalStats.AllThroughputs | Measure-Object -Minimum).Minimum, 2)
                    } else { 0 }
                    AggregateMaxThroughputMBps = if ($globalPerformanceSummary.GlobalStats.AllThroughputs.Count -gt 0) {
                        [Math]::Round(($globalPerformanceSummary.GlobalStats.AllThroughputs | Measure-Object -Maximum).Maximum, 2)
                    } else { 0 }
                    NodeMetrics = $globalPerformanceSummary.NodePerformance.Keys | ForEach-Object {
                        $nodeData = $globalPerformanceSummary.NodePerformance[$_]
                        @{
                            Node = $_
                            FilesTransferred = $nodeData.TotalFiles
                            DataTransferredGB = [Math]::Round($nodeData.TotalDataGB, 2)
                            AvgThroughputMBps = $nodeData.AvgThroughputMBps
                            MinThroughputMBps = $nodeData.MinThroughputMBps
                            MaxThroughputMBps = $nodeData.MaxThroughputMBps
                            StdDevMBps = $nodeData.ThroughputStdDev
                            CoefficientOfVariationPercent = if ($nodeData.AvgThroughputMBps -gt 0) {
                                [Math]::Round(($nodeData.ThroughputStdDev / $nodeData.AvgThroughputMBps) * 100, 1)
                            } else { 0 }
                        }
                    }
                }
            } else { $null };
            TestFileSizeGB = $TestFileSizeGB;
            NumberOfFilesPerNode = $NumberOfFiles;
            NetworkAdapterDropsInfo = $nodePacketStats.Keys | Where-Object { $_ -notlike '_*' } | ForEach-Object { 
                if ($nodePacketStats[$_].ContainsKey('NetworkAdapterDrops')) {
                    @{ $_ = $nodePacketStats[$_].NetworkAdapterDrops }
                }
            } | Where-Object { $null -ne $_ };
            RDMAStabilityAnalysis = $nodePacketStats.Keys | Where-Object { $_ -notlike '_*' } | ForEach-Object {
                if ($nodePacketStats[$_].ContainsKey('RDMADisruptionDetected')) {
                    @{ $_ = @{
                        Stable = -not $nodePacketStats[$_].RDMADisruptionDetected;
                        DisruptionReasons = $nodePacketStats[$_].RDMADisruptionReasons;
                        RDMAActivitySummary = if ($nodePacketStats[$_].ContainsKey('RDMAActivityDetails')) {
                            @{
                                TotalCounters = $nodePacketStats[$_].RDMAActivityDetails.InitialStats.Count
                                ChangedCounters = $nodePacketStats[$_].RDMAActivityDetails.Changes.Count
                                ErrorCounters = ($nodePacketStats[$_].RDMAActivityDetails.Changes.Keys | Where-Object { $_ -match 'Error|Fail|Retry|Reset|Timeout|Drop' }).Count
                                TopChanges = $nodePacketStats[$_].RDMAActivityDetails.Changes.GetEnumerator() | 
                                    Sort-Object { [Math]::Abs($_.Value.Delta) } -Descending | 
                                    Select-Object -First 5 | 
                                    ForEach-Object { @{ Counter = $_.Key; Delta = $_.Value.Delta } }
                            }
                        } else { $null }
                    }}
                }
            } | Where-Object { $null -ne $_ };
            FailuresReported = if ($stressTestFailures.Count -gt 0) { $stressTestFailures } else { $null };
            NodeStatCollectionErrors = $nodePacketStats.Keys | Where-Object { $_ -notlike '_*' -and $nodePacketStats[$_].StatsCollectionError } | ForEach-Object { @{ $_ = $nodePacketStats[$_].StatsCollectionError } };
            SMBConnectionLogFile = $logFilePath;
            SMBConnectionSummary = $nodePacketStats.Keys | Where-Object { $_ -notlike '_*' } | ForEach-Object {
                if ($nodePacketStats[$_].ContainsKey('RDMAUsed')) {
                    @{ $_ = @{
                        PeakSMBConnections = $nodePacketStats[$_].PeakSMBConnections;
                        PeakTotalChannels = $nodePacketStats[$_].PeakTotalChannels;
                        PeakRDMAChannels = $nodePacketStats[$_].PeakRDMAChannels;
                        RDMAUsagePercentage = $nodePacketStats[$_].RDMAUsagePercentage;
                        RDMAUsed = $nodePacketStats[$_].RDMAUsed
                    }}
                } else { $null }
            } | Where-Object { $null -ne $_ }
        };
        HealthCheckSource = $ENV:EnvChkrId 
    }

    $instanceResults += New-AzStackHciResultObject @stressTestResult

    # Cleanup
    if ($RunCleanup) {
        Write-Verbose "Running cleanup..."
        Write-Verbose "Cleaning up local source files in '$OutputPath'..."
        $localSourceFiles | ForEach-Object {
            $localFilePath = $_
            if (Test-Path -Path $localFilePath -PathType Leaf) {
                if ($PSCmdlet.ShouldProcess($localFilePath, "Remove Local Source File")) {
                    try { Remove-Item -Path $localFilePath -Force -ErrorAction Stop; Write-Verbose "Removed: $localFilePath" }
                    catch { Write-Warning "Failed to remove '$localFilePath': $_" }
                } else { Write-Warning "Cleanup skipped for local file '$localFilePath' (-WhatIf)." }
            }
        }

        Write-Verbose "Cleaning up remote destination files in S2D storage..."
        foreach ($nodeName in $remoteTestFilePaths.Keys) {
            $session = $destinationSessions | Where-Object {$_.ComputerName -eq $nodeName}
            if ($session -and $session.Runspace.RunspaceStateInfo.State -eq 'Opened') {
                $pathsToRemoveOnRemote = $remoteTestFilePaths[$nodeName]
                if ($pathsToRemoveOnRemote -and $pathsToRemoveOnRemote.Count -gt 0) {
                    Write-Verbose "Cleaning S2D files on '$nodeName': $($pathsToRemoveOnRemote -join ', ')"
                    if ($PSCmdlet.ShouldProcess($nodeName, "Remove Remote S2D Files")) {
                        try {
                            foreach ($path in $pathsToRemoveOnRemote) {
                                if (Test-Path $path -PathType Leaf) {
                                    Write-Verbose "Removing remote file: $path"
                                    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                                }
                            }
                        } catch { 
                            Write-Warning "Failed remote cleanup on '$nodeName': $_."
                        }
                    } else { 
                        Write-Warning "Cleanup skipped for remote S2D files on '$nodeName' (-WhatIf)."
                    }
                } else { 
                    Write-Verbose "No remote files recorded for cleanup on '$nodeName'."
                }
            } else { 
                Write-Warning "No usable session for '$nodeName' during cleanup. Manual cleanup may be needed."
            }
        }
        Write-Verbose "Cleanup process completed."
    } else {
         Write-Warning "Cleanup skipped (-RunCleanup not specified). Manual cleanup required for local files in '$OutputPath' and remote files in S2D storage paths."
    }

    Write-Host "SMB/RDMA connection log saved to: $logFilePath" -ForegroundColor Cyan
    if ($overallStatus -eq "FAILURE") {
        Write-Host "This log contains detailed metrics of SMB/RDMA connections and diagnostic data (Get-NetAdapterRdma, Get-NetAdapterQos)." -ForegroundColor Cyan
    } else {
        Write-Host "This log contains detailed metrics of SMB/RDMA connections during the test." -ForegroundColor Cyan
    }

    return $instanceResults
}


# Export Functions
Export-ModuleMember -Function Get-RDMAEnabledNetworkAdapters, Get-AllNetworkAdapters, Get-RDMAMultichannelConnections, `
                    Create-TestFileOnRemoteNode, Cleanup-TestFiles, `
                    Test-RDMAValidator_AdapterStatus, Test-RDMAValidator_MultichannelStatus, `
                    Test-RDMAValidator_NodeCompatibility, Test-RDMAValidator_Performance, Test-RDMAValidator_Stress
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAPvpWeNd2vOQ6n
# 8MQVbGabkRnOLtW2OpNESyPeKk8L2KCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIEBYKAHl
# LjmSbhM4DESHmdYFa31xUkq8PBb/TZ0gz26CMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAAFUObdhhxlkBsj1Uekx1WAYk80rahucko7LErCVt
# tapnDEo9CN5Tl32BbS/cFw4a+eT4MQkqlEkYEk5NMIlr15UyKOXF+UMVKx8kuXiH
# dEwBnbfmEDuf+cmtxYAnLst6JVU4K+50GCa7xvd/sfmYA1bmHZqqcKj9BTA1uPRj
# luHG5pOXmgYn+NmnIw7/DeddurI8ZyJJ4eO+nEjOlzRcH2nOxmmH8A8vFKn7TmKS
# g1/KUn+zIihDDWMtqo62ZP+PFwzMc+PuDy4mzE2K8/zrgqCOI7xPIr0t/9oQ/MH/
# 0ZlyICQ/tqXLgP2pRqDZauKdxPjmch3PDvFK6lP4VD59FKGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAC9F97OoxkwMF3s19KrbpIe/zdpYn0DI7aZ6vj
# t00XlgIGaefB+1SUGBMyMDI2MDUwMzE0MzExMC44NjRaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046MzcwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAh86cGnkojAulQABAAAC
# HzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTFaFw0yNzA1MTcxOTM5NTFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzcwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLO8XFOcfGqAqgiz0+AmQmFl3d
# Z0aTG4UFJkqqNdMHy28DaheCBs6ONufukye5x42CWkzgRIy9kE2VWwEntZ8Zkgyr
# ykC0bIqsID7+6FxguseTXf1Vwvm1D8104VmetoBJlJ4uGbuyJZUvXDx55nVh50yg
# LTzZ24WkQsnPpvRZv2kPc39f3bhLyHVtnHsa/W/86Vrftd+AfFveA+qN/EY+XGj5
# c/DPMXCYECb0arYb92dDJWtwzpyBrp4gfHlgY1UEpc4l4AGELrf2J4wrxTzTW+SM
# 8XhV1dOOPrYjD080IbZqL8B+IF0RCdn269YXrGK6QIHipznKZcCS8jN30YAHnTJV
# N5Zzs6t/2YsqBGDquvDad7934FFTwzvUcO3VoIyd93XWwvP8/SCFVJh21W8oGQTp
# tGHyly+Fl4henVMVZF1v6osOtirX8GFTiEhnf8nRdOg7yZYAJ0xy9CtDfbXaTn/c
# f3Lq3N/GCYKFjC+5mUCE+AJhmxMuMdvSUGmKiAFdiPAjUTqsWWBBZJm0eCwgeGJF
# mmQA+V7/98BKcE+gUL7O9eWRDQwKeAcvo6rxNv2Y4jKrHA6Z/wi3a/fKUhLCNZES
# 8qGdrpDAm7qh+6FjYxytAbkiKM6uTNy/ULPlwtlYZoAJDDQP7eYCywwVbNTbHXRB
# SS+NccC0sSB4W7U67wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNk72sGDlH0r5Dwv
# fGR5XwJI8B7bMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBlbu3IoynnPz0K1iPb
# eNnsej2b15l5sdl2FAFBBGT9lRdc2gNV8LAIusPYHHhUvRDcsx4lbMNhVKPGu4TD
# LaqNt/CI+SFtGuqdRLpVP1XE9cCLyKrKPpcJFJCqPpV+efoAtYBmIUQcxxwT7WIQ
# 7gag8+rkKvrMkCoRqKS0mKv8J1sKfi85+G2uhZ/1RteSVdYZOZOj+Sb4wzonTCTj
# 7EtgMN/BX35W5dTzd7wJdGepYkVi871dSrC2Tr1ZFzAR7S44drCWZpJ6phJabVNO
# sNxFJKgSykugOGWzQ318Rr3MTPg2s3Bns+pUPVgMijd4bUOH2BlEsLMMwOcolTTZ
# qg1HYrdY1jxpUAI9ipjBQRINL/O705Z+/f2LjNmJQooCVJVX24adpZ519SsfazGo
# qXGt91bmqKo0fI09Il4sUHh4ih6rpiQDBlyL7vmvCejwVxYevY4qVwTZ/o3gvl+R
# 0lFxYS9feIM4NeG0+WsDZ7jLci5MFeuNwosQY3z26Xg1oj0U9u+ncR9uTU+xBmJ8
# BtlCdhQ13RNMX5P+krRYPB3XCp9Jm6XaO1995q32AIZm1mzBGI6yHlviXaEC5TzG
# iO1LXuPtXZU2X93oQJbMoe3v8+5CPKrQalGWyYuh2a3V1pwbj+W0FEmEFPpu8TI+
# qYO1IIQWUSRvFjXth5Ob02hMMjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjM3MDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQBLIMg1P7sNuCXpmbH2IXT2tXeEEKCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFn5DAiGA8y
# MDI2MDUwMzA2MjEyNFoYDzIwMjYwNTA0MDYyMTI0WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoWfkAgEAMAoCAQACAhT3AgH/MAcCAQACAhNsMAoCBQDtorlkAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAHq7s9YMgMpIuyTAwWsMxFD0DDmR
# QoXeyij+UMPaYdsxa3ei47tU4WE0xqHP+0mYPcDDrbUyiue3JiyjGqyZhs63H39t
# kyIRrg787TNyIuzMJH04BSpAsjQL9jKHDPuDN03FtnZFcxLvnFz+i2e1OAQ5Odan
# ScUkOnVkC7TLm/DMelMwJm5tfFkMo6hKZS1tLtKyjJBB8ZMZlm+35LeUNJBgFRCA
# D0iG1bZFVD09Rf7diPhBQPHI70wqiFkIrPwgHUS8EKHQ1RrMajudvnX/GWgSZH2L
# As6VIoh8Xy8inHRClIVPQeQvEclLgJYcJ7qPQRmfh7UZHYThMVUooesH7aYxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh86
# cGnkojAulQABAAACHzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCKCTJO6qZsXcNNpPylOq2QHq5Q
# jJWVoqDunYHmX2njuzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILAkCt9W
# kCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wIgQgXDVXUUgM
# F2UJ5kLBUeKOgKL/uQDhW3pavs3L2zobM+AwDQYJKoZIhvcNAQELBQAEggIAY/rb
# tYABOOz9CXHNlFYtQiwiIks3WhNkEOdLM3fGfGTv1eyVwToKo2CZ5x5ZIepB2THZ
# 3/yl/xgAvcwJVYCP1aY94xALRx0VtESx/csqcuMTmCXyn6VJU86TIi7B+2qu9YVk
# IbpByolI8ReJG7SBD8A5o/fbh6LPOOZcEdOqrYuTHu75wmkVSktUtJv7SfDpLmB3
# VMCehl0uljorVP7GSSpMxrKvpYf4ZvY/UaKjnzmhHfRpDaNg3XF3BtyaG6IiOF5k
# 5bDbgi8C27EWTGPesPi/n/PbJzL5cEOFNLeIftVxPjbgLYwsM/FJOf/Qs+FlKLs5
# 098Z+U2FyIJiA/1aD+sx4Etb9WlMBuI1k8sGZUpq1YwFsFlJQKskES+atJswq/Ge
# NecrR8jVfJ8OHuZSaeZyXtkcxRiZzkPmh4iRpyUTDUxD7/PUOcp3IW0nsjhD3tCA
# zKHWgl91JvzpPGRTKGhNYen1qPPoZxHlPFOykquws4C6v2QA9EBnuF8iX5512qsA
# JVQjmw260ynS5UTxA+HH5140Qj0tPdnHP/vYypp8AwIAEVp9lvSSbIi2HinMvPa2
# N61geaya4ANq6xGd8n9sw1xOmWmIaJsxAsIxd0piiNsvc5uVzwbXw5JJVrF465y8
# 0XWH1scuZ6aBx96hc7gNtgZ6CAZKxJYwQWlHeAA=
# SIG # End signature block
