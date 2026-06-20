Import-LocalizedData -BindingVariable VvsTxt -FileName AzStackHci.MOCStack.Strings.psd1
function Test-MOCStackVolume
{
	<#
    .SYNOPSIS
        Verify if the available free space in the volume, meets the size threshold required by MOCStack during the deployment scenario.
    .DESCRIPTION
        Verify if the available free space in the volume meets the size threshold required by MOCStack during the deployment scenario.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
	.PARAMETER PhysicalDriveLetter
        Specify PhysicalDriveLetter used to validation MOCStack Volume. Default C drive is used as MOCStack volume.
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType,

		[Parameter(Mandatory=$false, ParameterSetName="DefaultSet")]
		[string] $PhysicalDriveLetter = "C"
    )

	try
	{
		$defalutHC4MOCStackVolumeSize = 50
		$defalutVMMOCStackVolumeSize = 20
		Log-Info -Message ($VvsTxt.MOCStackVolumeStartInfo) -Type Info
		Log-Info -Message ($VvsTxt.MOCStackVolumeDriveInfo -f $PhysicalDriveLetter)
        $lowDiskMsg = ($VvsTxt.LowDiskSpaceMsg -f $PhysicalDriveLetter)

		# Scriptblock to test MOCStackVolumeSize on each server
		$testVolumeSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedMOCStackVolumeSizeInGB = $args[0]
			$freeSpaceInGB = 1
			$resourceMsg = $null

			try
			{
				# Check if env is Virtual
				$hardwareType = (Get-WmiObject -Class Win32_ComputerSystem).Model
				if ($hardwareType -eq "Virtual Machine")
				{
					$expectedMOCStackVolumeSizeInGB = $args[1]
				}

				# Check free space on physical volume
				$totalFreeSpace = (Get-Volume -DriveLetter $args[2]).SizeRemaining
				$freeSpaceInGB = [int]($totalFreeSpace / 1GB)
				if ($freeSpaceInGB -lt $expectedMOCStackVolumeSizeInGB)
				{
					$resourceMsg = "MOCStack volume '$($args[2])' needs, $($expectedMOCStackVolumeSizeInGB) GB free space."
					throw $args[3]
				}
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack Volume test."
				$status = "FAILURE"
			}
			finally
			{
				$AdditionalData = @{
                    HardwareType  = $hardwareType
					ExpectedMOCStackVolumeSize = $expectedMOCStackVolumeSizeInGB
                    CurrentMOCStackVolumeSize = $freeSpaceInGB
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackVolumeSizeResult = Invoke-Command -Session $PsSession -ScriptBlock $testVolumeSb -ArgumentList $defalutHC4MOCStackVolumeSize, $defalutVMMOCStackVolumeSize, $PhysicalDriveLetter, $lowDiskMsg
		# build result
		foreach ($result in $MOCStackVolumeSizeResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_Volume'
				Title              = 'MOCStack Volume Requirement'
				DisplayName        = 'MOCStack Volume Requirement {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check MOCStack volume ({0}) size requirement ({1}) is met' -f $PhysicalDriveLetter, $MOCStackVolumeSizeResult.ExpectedMOCStackVolumeSize
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Free up disk space for MOCStack Volume'
				TargetResourceID   = "$($result.Source)/$PhysicalDriveLetter"
				TargetResourceName = $PhysicalDriveLetter
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

function Test-MOCStackCPUCore
{
	<#
    .SYNOPSIS
        Verify if the host node meets the minimum CPU count requirement for MOCStack configuration
    .DESCRIPTION
        Verify if the host node meets the minimum CPU count requirement for MOCStack configuration
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
		$defalutCPUCount = 4
		Log-Info -Message ($VvsTxt.MOCStackCPUStartInfo) -Type Info
        $lowCpuMsg = ($lvsTxt.LowCPuMsg)


		# Scriptblock to test MOCStackCpu core on each server
		$testCpuSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedMOCStackCpuCoreCount = $args[0]
			$resourceMsg = $null
            $cpuCount = 1

			try
			{
				# Check CPU core count on each machince
				$cpuCount = $((Get-CimInstance -ClassName Win32_Processor -Property NumberOfCores).NumberOfCores | Measure-Object -Sum).Sum
				if ($cpuCount -lt $expectedMOCStackCpuCoreCount)
				{
					$resourceMsg = "MOCStack CPU validation expects at least the host to have $($expectedMOCStackCpuCoreCount) cores."
					throw $args[1]
				}
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack Cpu test."
				$status = "FAILURE"
			}
			finally
			{

				$AdditionalData = @{
                    HardwareType  = $hardwareType
					ExpectedMOCStackCPUCoreCount = $expectedMOCStackCpuCoreCount
                    CurrentMOCStackCPUCoreCount = $cpuCount
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackCPUResult = Invoke-Command -Session $PsSession -ScriptBlock $testCpuSb -ArgumentList $defalutCPUCount, $lowCpuMsg
		# build result
		foreach ($result in $MOCStackCPUResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_CpuCoreCount'
				Title              = 'MOCStack CPU Requirement'
				DisplayName        = 'MOCStack CPU Requirement {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check MOCStack CPU core count ({0}) requirement is met' -f $defalutCPUCount
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Upgrage the node CPU core configuration'
				TargetResourceID   = $result.Source
				TargetResourceName = $result.Source
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

function Test-MOCStackMemory
{
	<#
    .SYNOPSIS
        Verify physical memory ie RAM of the node satisfies the minimum requirements of MOCStack.
    .DESCRIPTION
        Verify physical memory ie RAM of the node satisfies the minimum requirements of MOCStack.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
		$defalutRAMSizeInGB = 8
		Log-Info -Message ($VvsTxt.MOCStackMemoryStartInfo) -Type Info
        $lowMemoryMsg = ($VvsTxt.LowMemoryMsg)

		# Scriptblock to test physical memory on each server
		$testRAMSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedRAMSizeInGB = $args[0]
			$freeSpaceInGB = 1
			$resourceMsg = $null

			try
			{
				# Check physical memory size
				$totalRAM = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property capacity -Sum).sum
				$totalRAMInGB = [int]($totalRAM / 1GB)
				if ($totalRAMInGB -lt $defalutRAMSize)
				{
					$resourceMsg = "MOCStack physical memory size validation expects at least the host to have $($expectedRAMSizeInGB) GB."
					throw $args[1]
				}
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack physical memory size test."
				$status = "FAILURE"
			}
			finally
			{
				$AdditionalData += @{
                    HardwareType  = $hardwareType
					ExpectedMOCStackRAM = $expectedRAMSizeInGB
                    CurrentMOCStackRAM = $totalRAMInGB
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackRAMSizeResult = Invoke-Command -Session $PsSession -ScriptBlock $testRAMSb -ArgumentList $defalutRAMSizeInGB, $lowMemoryMsg
		# build result
		foreach ($result in $MOCStackRAMSizeResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_RAM_Size'
				Title              = 'MOCStack RAM Requirement'
				DisplayName        = 'MOCStack RAM Requirement {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check MOCStack RAM ({0}) requirement is met' -f $defalutRAMSizeInGB
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Upgrage the node PhysicalMemory configuration'
				TargetResourceID   = $result.Source
				TargetResourceName = $result.Source
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

function Test-MOCStackNetworkPort
{
	<#
    .SYNOPSIS
        Verify that the required network ports for MOCStack are open.
    .DESCRIPTION
        Verify that the required network ports for MOCStack are open.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
		# Don't do this test in a proxy environment
		if (Get-IsProxyEnabled)
		{
			return
		}

		$portList = '443','80'
		Log-Info -Message ($VvsTxt.MOCStackPortInfo) -Type Info
        $disabledPortMsg = ($VvsTxt.DisablePortMsg)

		# Scriptblock to test network port on each server
		$testPortSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedPortList = $args[0]
			$failedPort = $null
			$resourceMsg = $null

			try
			{
                # Check each network port is enabled on the node
                foreach ($port in $expectedPortList)
                {
					# Added retry logic
					$retryCount = 0
					$tcpSucceeded = $false
					while (!$tcpSucceeded -and $retryCount -lt 5)
					{
						$tcpSucceeded = Test-NetConnection -Port $port -InformationLevel Quiet
						$retryCount ++
					}

					# Validate the TCP connection
                    if($tcpSucceeded -ne $true)
                    {
                        $failedPort += " $port,"
                        $status = "FAILURE"
                    }
                }

                # Check overall network port enable status
				if ($status -eq 'FAILURE')
				{
					$resourceMsg = "The network port validation for MOCStack requires $($failedPort) to be enabled."
					throw $args[1]
				}
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack network port test."
				$status = "FAILURE"
			}
			finally
			{
				$AdditionalData += @{
                    HardwareType  = $hardwareType
					ExpectedEnablePort = $portList
                    DisablePort = $FailedPort
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackPortResult = Invoke-Command -Session $PsSession -ScriptBlock $testPortSb -ArgumentList $portList, $disabledPortMsg
		# build result
		foreach ($result in $MOCStackPortResult)
		{
			# build result
			$params = @{
				Name               = 'AzStackHci_MOCStack_Network_Port'
				Title              = 'MOCStack Network Port Requirement'
				DisplayName        = 'MOCStack Network Port Requirement {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check MOCStack Network Port requirement is met'
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Enable the mandatory network port required for MOCStack'
				TargetResourceID   = $result.Source
				TargetResourceName = $result.Source
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

function Test-MOCStackFirewallUrl
{
	<#
    .SYNOPSIS
        Verify that the necessary URL for MOCStack is added to the allowlist in the firewall.
    .DESCRIPTION
        Verify that the necessary URL for MOCStack is added to the allowlist in the firewall.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType,

		[Parameter(Mandatory = $false)]
        [string]
        $RegionName
    )

	# This test has been converted to a service-defined target towards an external endpoint using connectivity validator
	try
	{
		Log-Info -Message ($VvsTxt.MOCStackFirewallURLInfo) -Type Info
		$connectivityParams = @{
			Exclude = (Get-AzStackHciConnectivityServiceName | ? {$_ -ne 'MOC Stack'})
			PassThru = $true
		}
		if ($RegionName) {
			$connectivityParams.RegionName = $RegionName
		}
		$MOCStackURLResult = Invoke-AzStackHciConnectivityValidation @connectivityParams | Where-Object Name -like *MOCStack*

		# build result
		foreach ($result in $MOCStackURLResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_Firewall_URL'
				Title              = 'MOCStack Firewall URL allowed list Requirement'
				DisplayName        = 'MOCStack Firewall URL allowed list Requirement {0}' -f $result.AdditionalData.Source
				Severity           = 'WARNING'
				Description        = 'Test to check MOCStack Firewall URL allowed list requirement is met'
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/azure-arc-vm-management-prerequisites#firewall-url-requirements'
				TargetResourceID   = $result.TargetResourceID
				TargetResourceName = $result.TargetResourceName
				TargetResourceType = $result.TargetResourceType
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result.AdditionalData
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

function Test-MOCStackNodeAgents
{
	<#
    .SYNOPSIS
        Verify MOC NodeAgent Service is up and running.
    .DESCRIPTION
        Verify MOC NodeAgent Service is up and running.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
        Log-Info -Message ($VvsTxt.MOCStackNodeAgentInfo) -Type Info
        $nodeAgentFailMsg = ($VvsTxt.NodeAgentFail)

		# Scriptblock to check MOC Node agent service on each server
		$testNodeAgentSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedAgentState = 'Running'
			$currentAgentStatus = $null
			$resourceMsg = $null

			try
			{
                # Check Node agent service is in running state
                $currentAgentStatus = $(Get-Service -Name 'wssdagent' | Select Status).Status
                if($currentAgentStatus -ne $expectedAgentState)
                {
                    $status = "FAILURE"
					$resourceMsg = "On node $($ENV:COMPUTERNAME), MOC NodeAgent service is in $($currentAgentStatus) status"
					throw $args[0]
                }
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack Node Agent test."
				$status = "FAILURE"
			}
			finally
			{
				$AdditionalData += @{
                    HardwareType  = $hardwareType
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackNodeAgentResult = Invoke-Command -Session $PsSession -ScriptBlock $testNodeAgentSb -ArgumentList $nodeAgentFailMsg
		# build result
		foreach ($result in $MOCStackNodeAgentResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_NodeAgent_Service'
				Title              = 'MOCStack Node agent Service State'
				DisplayName        = 'MOCStack Node agent Service State {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check if the MOCStack NodeAgent service is in the expected running state'
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Ensure the MOC NodeAgent service is in Online state'
				TargetResourceID   = $result.Source
				TargetResourceName = $result.Source
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

function Test-MOCStackCloudAgent
{
	<#
    .SYNOPSIS
        Verify MOC CloudAgent Service is in an online state.
    .DESCRIPTION
        Verify MOC CloudAgent Service is in an online state.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
        Log-Info -Message ($VvsTxt.MOCStackCloudAgentInfo) -Type Info
        $cloudAgentFailMsg = ($VvsTxt.CloudAgentFail)

		# Scriptblock to check MOC cloud agent service state
		$testCloudAgentSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedCloudAgentState = 'Online'
			$currentCloudAgentStatus = $null
			$resourceMsg = $null

			try
			{
                # Check Cloud agent service is in Online state
                $currentCloudAgentStatus = $(Get-ClusterResource -Name 'MOC Cloud Agent Service' | select State).State
                if($currentCloudAgentStatus -ne $expectedCloudAgentState)
                {
                    $status = "FAILURE"
					$resourceMsg = "MOC CloudAgent service is in $($currentCloudAgentStatus) state"
					throw $args[0]
                }
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack CloudAgent Agent test."
				$status = "FAILURE"
			}
			finally
			{
				$AdditionalData += @{
                    HardwareType  = $hardwareType
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackCloudAgentResult = Invoke-Command -Session $PsSession -ScriptBlock $testCloudAgentSb -ArgumentList $cloudAgentFailMsg
		# build result
		foreach ($result in $MOCStackCloudAgentResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_CloudAgent_Service'
				Title              = 'MOCStack CloudAgent Service State'
				DisplayName        = 'MOCStack CloudAgent Service State {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check if the MOCStack CloudAgent service is in the expected running state'
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Ensure the MOC CloudAgent service is in Online state'
				TargetResourceID   = $result.Source
				TargetResourceName = $result.Source
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

function Test-MOCStackClusterNode
{
	<#
    .SYNOPSIS
        Verify cluster node is up and running.
    .DESCRIPTION
        Verify cluster node is up and running.
	.PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for MOCStack validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
        Log-Info -Message ($VvsTxt.ClusterNodeInfo) -Type Info
        $clusterNodeFailMsg = ($VvsTxt.ClusterNodeFail)

		# Scriptblock to check cluster node state
		$testClusterNodeSb = {
			$AdditionalData = @()
			$status = "SUCCESS"
			$errorMsg = $null
			$hardwareType = $null
			$expectedClusterNodeState = 'Up'
			$offlineNode =  $null
			$resourceMsg = $null

			try
			{
                # Check cluster node state is up and running
                $offlineNode = $(Get-ClusterNode | Where State -ne $expectedClusterNodeState)
                if($offlineNode -ne $null -and $offlineNode.count -gt 0)
                {
                    $status = "FAILURE"
					$resourceMsg = "Cluster node $($offlineNode.Name), in $($offlineNode.State) state"
					throw $args[0]
                }
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resourceMsg = "Error occurred in Environment Validator MOCStack Cluster Node test."
				$status = "FAILURE"
			}
			finally
			{
				$AdditionalData += @{
                    HardwareType  = $hardwareType
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resourceMsg
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$MOCStackClusterNodeResult = Invoke-Command -Session $PsSession -ScriptBlock $testClusterNodeSb -ArgumentList $cloudAgentFailMsg
		# build result
		foreach ($result in $MOCStackClusterNodeResult)
		{
			$params = @{
				Name               = 'AzStackHci_MOCStack_ClusterNode_State'
				Title              = 'MOCStack Cluster Node State'
				DisplayName        = 'MOCStack Cluster Node State {0}' -f $result.Source
				Severity           = 'CRITICAL'
				Description        = 'Test to check if the cluster node is in the expected up state'
				Tags               = @{
					OperationType = $OperationType
				}
				Remediation        = 'Ensure the MOC CloudAgent service is in Online state'
				TargetResourceID   = $result.Source
				TargetResourceName = $result.Source
				TargetResourceType = 'Computer'
				Timestamp          = [datetime]::UtcNow
				Status             = $result.Status
				AdditionalData     = $result
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

Export-ModuleMember -Function Test-MOCStackCPUCore
Export-ModuleMember -Function Test-MOCStackMemory
Export-ModuleMember -Function Test-MOCStackNetworkPort
Export-ModuleMember -Function Test-MOCStackClusterNode
Export-ModuleMember -Function Test-MOCStackCloudAgent
Export-ModuleMember -Function Test-MOCStackNodeAgents
# Excluding Volume check function
#Export-ModuleMember -Function Test-MOCStackVolume
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCHL4im5rwogDQg
# wvRQyRnrYmhiRxVluKVHWgHLw+XBIqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGAt6B3R
# R7RPqu6V7wMLaW2KvWrVQQsBjZqljVZ/tjobMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAdgTUrxNPoWJoi8w4fdPjZ9jDCSKcnfrYVE9Lhj/g
# 0asUt51nhp9v2IWUQ3dqW/7QKAgIno2Jjh/IWeKwXoAIHMv3oWsqKN0AGFQCYNMr
# MKy+iozQjxMsBPlNK850pCDC1GW3J/g6oDLef74w4WpqIqh6gBl+UfKS3LQABw2g
# eKiMtFuFAbP5fvIalqT4b29hZ9U5bxk9SFf9i84OvTvrzAn1WSr4rHllqk83V3z4
# VHYUSrObCkj63CQt1lyQxexmonRmGAht2L7x5XBmdxX+fokzcR1Ff9Hl6dWyNdEa
# NkphWO2RNHixI8loC+ZNXuARylO2gJ6cmYmffh648lZ9MaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBVGf11kBdqH5P8K6gdAJvgSNzv2M611i1g7tj+
# VN5yAgIGaeegqJ4BGBMyMDI2MDUwMzE0MzExMC40MzJaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046N0YwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAh6jrKRuOW98SQABAAAC
# HjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NDlaFw0yNzA1MTcxOTM5NDlaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0YwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCl0TjtbDwsR7Fe8ac6ol5s1zht
# Tqd2AWpchQhLp9G5mmSM23N5fyQGCQ1D06rOA3PgXKF+76vXvOCs2VsLv1owj4mH
# EyEqiq8GJ5yC+/QNYRpZPA8e7OgekzDO6S/4vy/jTMYbp3rhuFiKKCzTWOQtdFcF
# +D0k369I7pm/E07SyNMGkuNd5lj5SJ91UqFuZfjMB6cQ2wh77mtiRUVdj53yjdNq
# j+GQl+Yaz29Bjrzn7U1ln+JpLlnb0xdGmZoIPKZbwBVcWtyL4uyhML7SSTmiOfWX
# U+g+yNl0CdoLGL8LtWHEi8FsuTPeSdSqmeMrvLaEmibTVTS4vQQY8NPnb6uI5y6i
# NV9vBFcm8LU/lDTjGTqPa7UBT4gdf5Jm3wYrfCFZ4P/j5MoqT0JONca50jt4TGI9
# 0SihXaDEYqk23S0IJZ3UkUpukDRTjK713BIykffxyBqMeQqfO0zvWfUx7BrmUpug
# Qcw99+DxLl2gf+uQEpRmnlbrVJ9dvW9ds4fqEPN2jG0QwF1PBSglNcV1SpqZKitQ
# gBGSwu/82AKztoCHwYRHRNwzwTVe/1KNTvmqAd4Uges4ywOH02haagT8wYY8OdWd
# jKn3k052w+kmc0UC0F+iVXTGZIMxvo9iBZQoXehzRtWJ/VOtKvCyS3csKzN7rStW
# JwjSWz6dtOf0l+ytLQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFOYKFprqBB0JZmJc
# FC4cPPmeF4JkMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCkoZB5NnJVFb5wKejR
# onk518a2TBNYpKcBMtfL6BS0ARaABOMGYLlPNuhI1HwmelP9hX3oq3TaEm/cDkkz
# NQAzDedPgoRI2R7+8poNSWvHXEAs7SZODm9x7KqlBkNZM9ex4XY1yNmVOAmWDjRr
# 7jKjaiQbntf7EC4GNikxGGaVWOjfYt3Q9X0r/Ks8KBlbzDR9zjA/TCctR4co1WpU
# 1ZRLFrB9bl8dRxsbnyT2qQ41E7dT12R30eIGUziEs5GN+26V/ovXOi20dJiM13hY
# Wvy1NNJAhkKOlLB1ONund6ffhPdUcHWsu8V+lR0aakMV64HqDbLumZrCNwUofVx3
# xMk8F4tCYJtQxLTywc30sZAD1S2sC1959x6KixA+p41FLUl8g64oHy3bfYnH5xd4
# JOBgQoaqndGjcctxr+8EknjhKyrgAzrTcKLJbUezgoye8brCLJ+y6PAoEjpXRkSY
# AU8wfQ3YWRck6ALwoV7Uin8+rpGQSbXhF6c1dTFakXmChClud4IADY/t6JRkJ+06
# FzL+jDd8KLV8Qj77JfiuTiPIG5G/xlnGoZFcX+yyBtDvzZE48d+Y+HYUd/cvhH1F
# Kl7AH+5AyotqJSFmvM/BuYRx2B20asVXilV2k2JbNO3LGCz3Q+dpElzwsfJrka1N
# /getma7fWpowsNvoIaEQvjad8TCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdGMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCD/QNkKDIW4VIF7j3oi2qbrR0a/6CBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFGjDAiGA8y
# MDI2MDUwMzAzNTkwOFoYDzIwMjYwNTA0MDM1OTA4WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoUaMAgEAMAoCAQACAhMyAgH/MAcCAQACAhMQMAoCBQDtopgMAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAAVi9xvlOh955n1ik5D1kDjxW5FS
# jTmAe2i5ti6Xo0Q8nen2zRj2DZiWYlmUxCXO+wcwd01IsjU0N1lo3LHT7+My0gjS
# WKdhsyj0t49HrZf479uUNdo4iK5OxxmLXEiDNc+nmrmp5PVME6eXxoA3kyhqace3
# ctTktUSzrD3GU+S3M2Lr/8B3g8ckRgnMEw55oPr9c5PIZYs6DpLjUbEmqrICkkf2
# Xf+kHVJF1isU6mmlcnvll7lhPAW6QCILPaKSb5ZEnLE3kTvhpZFTfVFxEyy1cNof
# 6rCDf8+5OC+BADB16rc7SWr1xf4t8qU9jcpWemVXnDqLBSo/CThYlr++Y2UxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh6j
# rKRuOW98SQABAAACHjANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCeT99ym30d2Hwoyfec5GWaUeJ0
# oZEFY6Ps6MTITqWiKDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIC+BXWrz
# 9geMgM8Bvn8bqxHjhHXJ29EBizITIw0B9vOCMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIeo6ykbjlvfEkAAQAAAh4wIgQgJ1jdQD+0
# szm+d0/kpKtiIuKHE8oW2d9Vtqy9flj8PCswDQYJKoZIhvcNAQELBQAEggIAJHY+
# o8bCgPEv5fh2Tica/1sHcdmlQK6hcmWbNXHUycaOLlFj2hOXe8YmujaCknIKZD5R
# 3ReEz0+WW/Ey5l7I2+eTnOkrdQhb3LfEmO+dGqf4Um7B4GDV75PAk9bU4nX6nD9g
# jmYHIecmF78DrnDkWPQVMpISq4HR2oQx/Pyzr1bkUhTMJbgydZhqvHl6if5H2o7D
# x+cFWp25kSi8gqF08flsLwJQQaOcWrr8G9nTCa8tG+L6IK6j5ol5YEHzuRKhzstd
# 5ByY47lVP6ShqfyZToQXwqngrsY3N9sQOqzSJHT8uHKrwV9EnjiVclGM2gKGk9jU
# gMciqhuCJwkV4qkEr+UAQXXsy8N4iTzO/s0JU6Y7ZXPTDHezUyt8Kses9/lk5/96
# rVaP3tT43JIkMcBkK2FOv1TPjAlH8lPP+wxieqIIw9VmZK+W2RPr6oMQ2g6st/rV
# PSjPTiDoOd4BdQzfAKjSMfzDJyZf8dLyci9EiyeHiQc93yGa3OkVvM0Wc5YPQOsB
# +1DwiQoO9WyGFSaOOVy7k+2zV+fh+VJZRcXag8DOWWrTey39JO1qecgGpJ2Fk9J7
# qbLgYKpPAs/Vjuflcf8y3DomtLNlfDFEYvLMxrsycK/OaeOO4qRJJ2QbMpXogYHq
# CiD/MSIC3kW7lssnuFZn5flRZeeRQa623wYFjTg=
# SIG # End signature block
