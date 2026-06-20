Import-LocalizedData -BindingVariable lanTxt -FileName AzStackHci.AddNode.Strings.psd1

function Test-ADCredential {
    [CmdletBinding()]
    param (
        [pscredential]
        $ActiveDirectoryCredential
    )
    try
    {
        $severity = 'CRITICAL'
        $adModuleExists = [bool](Get-Module ActiveDirectory -ListAvailable -ErrorAction SilentlyContinue)
        if ($adModuleExists)
        {
            [bool]$adTest = QueryAD -ActiveDirectoryCredential $ActiveDirectoryCredential
            $detail = $lanTxt.TestAD -f $AdTest, $true
            if ($adTest)
            {
                $status = 'SUCCESS'
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }
        }
        else
        {
            $status = 'FAILURE'
            $detail = $lanTxt.NoADModule
            Log-info $detail -Type $severity
        }

        $params = @{
            Name               = 'AzStackHci_AddNode_AD_Credential_Check'
            Title              = 'Test AD Credential'
            DisplayName        = 'Test AD Credential'
            Severity           = $severity
            Description        = 'Checking AD Credential is valid'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/add-server'
            TargetResourceID   = 'AD Credential'
            TargetResourceName = 'AD Credential'
            TargetResourceType = 'Credential'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = $ENV:COMPUTERNAME
                Resource  = 'AD Credential'
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    catch
    {
        throw ("Error testing AD credential: {0}" -f $_.Exception)
    }
}

function QueryAD {
    [CmdletBinding()]
    param (
        [pscredential]
        $ActiveDirectoryCredential
    )
    try
    {
        $domain = $ActiveDirectoryCredential.GetNetworkCredential().domain
        if ([string]::IsNullOrEmpty($domain)) {
            if (($ActiveDirectoryCredential.UserName -split '@').count -le 1)
            {
                throw "Credential should contain domain"
            }
            else
            {
                $domain = ($ActiveDirectoryCredential.UserName -split '@')[1]
            }
        }
        return [bool](Get-ADDomain -Credential $ActiveDirectoryCredential -Server $domain -ErrorAction SilentlyContinue)
    }
    catch
    {
        throw ("Error retrieving AD Object: {0}" -f $_.Exception)
    }
}

function Test-LocalCredential {
    [CmdletBinding()]
    param (
        [pscredential]
        $LocalCredential,

        [string[]]
        $Ipv4OrHostName
    )
    try
    {
        $severity = 'CRITICAL'
        $PsSession = Microsoft.PowerShell.Core\New-PsSession -ComputerName $Ipv4OrHostName -Credential $LocalCredential
        Copy-RemoteItem -PsSession $PsSession -SourcePath (Join-Path (Split-Path -Parent $PSScriptRoot) "AzStackHci.EnvironmentChecker.PortableUtilities.psm1") -CmdletName "Test-Elevation"
        $IsAdmin = {
            if (Get-Command -Name Test-Elevation -ErrorAction SilentlyContinue)
            {
                Test-Elevation
            }
            else
            {
                throw "Cannot find Test-Elevation function"
            }
        }
        $results = @()
        $results += [bool](Microsoft.PowerShell.Core\Invoke-Command -Session $PsSession -ScriptBlock $IsAdmin -ErrorAction SilentlyContinue)
        $instanceResults = @()
        $instanceResults += foreach ($result in $results)
        {
            $detail = $lanTxt.TestLocalCredential -f $LocalCredential.UserName, $Ipv4OrHostName, $result, $true
            if ($result)
            {
                $status = 'SUCCESS'
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                Log-Info $detail -Type $severity
            }

            $params = @{
                Name               = 'AzStackHci_AddNode_Local_Credential_Check'
                Title              = 'Test Local Credential'
                DisplayName        = 'Test Local Credential'
                Severity           = $severity
                Description        = 'Checking Local Credential is valid'
                Tags               = @{}
                Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/add-server'
                TargetResourceID   = 'Local Credential'
                TargetResourceName = 'Local Credential'
                TargetResourceType = 'Credential'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $Ipv4OrHostName
                    Resource  = 'Local Credential'
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
        throw ("Error testing local credential {0} on {1}. Error: {2}" -f $LocalCredential.UserName, $Ipv4OrHostName, $_.Exception)
    }
    finally
    {
        Remove-UtilityModule -PsSession $PsSession
        $PsSession | Remove-PSSession -ErrorAction SilentlyContinue
    }
}

function Test-ClusterNodeName {
    [CmdletBinding()]
    param (
        [string[]]
        $ComputerName
    )
    try
    {
        $severity = 'CRITICAL'
        [string[]]$clusterNodes = Get-ClusterNodeNames
        [string[]]$nodeNamesInUse = $ComputerName | Where-Object { $_ -in $clusterNodes }
        $detail = $lanTxt.TestClusterNodeName -f ($computerName -join ','), [bool]$nodeNamesInUse, $false
        if ($nodeNamesInUse.Count -eq 0)
        {
            Log-Info $detail
            $status = 'SUCCESS'
        }
        else
        {
            $detail = $detail + "`r`n" + $lanTxt.RemoveClusterNodeName -f ($nodeNamesInUse -join ',')
            $status = 'FAILURE'
            Log-Info $detail -Type $severity
        }

        $clusterName = Get-LocalClusterName
        $params = @{
            Name               = 'AzStackHci_AddNode_ComputerName_Check'
            Title              = 'Test ComputerName'
            DisplayName        = 'Test ComputerName'
            Severity           = $severity
            Description        = 'Checking ComputerName(s) is not in use in existing cluster'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/add-server'
            TargetResourceID   = $clusterName
            TargetResourceName = $clusterName
            TargetResourceType = 'Computer Name'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = $ENV:COMPUTERNAME
                Resource  = $ComputerName -join ','
                Detail    = $detail
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    catch
    {
        throw ($lanTxt.NodeNameCheckError -f ($ComputerName -join ','), $_.Exception)
    }
}

function Get-ClusterNodeNames {
    <#
    .SYNOPSIS
        Get the cluster node names from the local cluster
    .OUTPUTS
        Returns the cluster node names.
    #>
    [CmdletBinding()]
    param ()

    try
    {
        $ClusterNodeNames = Get-ClusterNode | Select-Object -ExpandProperty Name
        Log-Info "Local Cluster Name: $($ClusterNodeNames -join ', ')"
        return $ClusterNodeNames
    }
    catch
    {
        throw ("Error retrieving cluster node names: {0}" -f $_.Exception)
    }
}

function Get-LocalClusterName {
    <#
    .SYNOPSIS
        Get the cluster name from the local cluster
    .OUTPUTS
        Returns the cluster name.
    #>
    [CmdletBinding()]
    param ()

    try
    {
        $ClusterName = Get-Cluster | Select-Object -ExpandProperty Name
        Log-Info "Local Cluster Name: $ClusterName"
        return $ClusterName
    }
    catch
    {
        throw ("Error retrieving cluster name: {0}" -f $_.Exception)
    }
}

function Test-ComputerName {
    [CmdletBinding()]
    param (
        [string[]]
        $ComputerName,

        [pscredential]
        $LocalCredential,

        [string[]]
        $Ipv4OrHostName
    )
    try
    {
        # if no IP is provided, we assume this is repair and return
        $severity = 'CRITICAL'
        if ($Ipv4OrHostName.Count -eq 0 -or -not $Ipv4OrHostName)
        {
            return
        }

        # Build a hashtable of IPs and computer names
        [array]$nodeIpMap += GetCsNameFromIps -LocalCredential $LocalCredential -Ipv4OrHostName $Ipv4OrHostName

        # verify all computername names
        if ($null -in $nodeIpMap.ComputerName)
        {
            throw "Failed to resolve ComputerName from all IP(s): $($Ipv4OrHostName -join ', ')"
        }

        $dtl = ""
        [string[]]$NodeMapComputerNames = $nodeIpMap | Select-Object -ExpandProperty ComputerName
        $compareResult = Compare-Object -ReferenceObject $ComputerName -DifferenceObject $NodeMapComputerNames
        if (-not $compareResult)
        {
            $status = 'SUCCESS'
            $dtl = "All ComputerName(s) match the IP(s): {0}" -f (($nodeIpMap | ForEach-Object { "'$($_.Ipv4OrHostName)' -> '$($_.ComputerName)'" }) -join ', ')
        }
        else
        {
            $status = 'FAILURE'
            $dtl += "Inconsistency found between ComputerName(s) and IP(s):"
            foreach ($cr in $compareResult)
            {
                if ($cr.SideIndicator -eq '=>')
                {
                    $foundOn = $nodeIpMap | Where-Object { $_.ComputerName -eq $cr.InputObject } | Select-Object -ExpandProperty Ipv4OrHostName
                    $dtl += "`r`n - ComputerName '$($cr.InputObject)' was found on $($foundOn -join ',')"
                }
                else
                {
                    $dtl += "`r`n - ComputerName '$($cr.InputObject)' was not found on the provided IPs.`r`nPlease check the IP(s) and ComputerName(s) provided are correct."
                }
            }

            Log-Info -Message $dtl -Type $severity
        }

        $params = @{
            Name               = 'AzStackHci_AddNode_ComputerNameIPs_Match'
            Title              = 'Test ComputerName IP'
            DisplayName        = 'Test ComputerName IP'
            Severity           = $severity
            Description        = 'Checking Computer(s) have correct IP(s) configured'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/add-server'
            TargetResourceID   = "$($Ipv4OrHostName -join ',')"
            TargetResourceName = "$($ComputerName -join ',')"
            TargetResourceType = 'Ip Configuration'
            Timestamp          = [datetime]::UtcNow
            Status             = $Status
            AdditionalData     = @{
                Source    = ($ComputerName -join ',')
                Resource  = ($Ipv4OrHostName -join ',')
                Detail    = $dtl
                Status    = $status
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        New-AzStackHciResultObject @params
    }
    catch
    {
        throw ("Error testing IP {0} is set locally on {1}. Error: {2}" -f ($Ipv4OrHostName -join ','), ($ComputerName -join ','), $_)
    }
}

function GetCsNameFromIps {
    <#
    .SYNOPSIS
        Get the computer name from the IP address
    .PARAMETER Ipv4OrHostName
        The IP address or host name to resolve
    .OUTPUTS
        Returns the computer name associated with the provided IP address or host name.
    #>
    [CmdletBinding()]
    param (
        [pscredential]
        $LocalCredential,

        [string[]]
        $Ipv4OrHostName
    )
    $sb = {
        (Get-WmiObject -ClassName Win32_OperatingSystem | Select-Object -expand CSName)
    }
    $ipNodeMap = @()
    foreach ($ip in $Ipv4OrHostName)
    {
        $csName = (Microsoft.PowerShell.Core\Invoke-Command -ComputerName $ip -Credential $LocalCredential -ScriptBlock $sb -ErrorAction SilentlyContinue)
        $ipNodeMap += New-Object -TypeName PSObject -Property @{
            ComputerName = $csName
            Ipv4OrHostName = $ip
        }
    }
    return $ipNodeMap
}

function Test-Quorum {
    <#
    .SYNOPSIS
        Check if single node cluster has correct quorum configuration
    #>
    [CmdletBinding()]
    param()
    try {
        # Get the current number of nodes in the cluster
        $severity = 'CRITICAL'
        $CurrentNumberOfNodes = (Get-ClusterNode).Count

        # if the cluster has only one node, check if the quorum is set to NodeandFileShareMajority or CloudWitness
        if ($CurrentNumberOfNodes -eq 1)
        {
            $Quorum = Get-ClusterQuorum
            $detail = $lanTxt.QuorumCheck -f $Quorum.Cluster.Name, $CurrentNumberOfNodes, $Quorum.QuorumResource.ResourceType.Name,'File Share Witness or Cloud Witness'
            if ($Quorum.QuorumResource.ResourceType.Name -eq 'File Share Witness' -or $Quorum.QuorumResource.ResourceType.Name -eq 'Cloud Witness')
            {
                Log-Info $detail
                $Status = 'SUCCESS'
            }
            else
            {
                Log-Info $detail -Type $severity
                $Status = 'FAILURE'
            }

            $params = @{
                Name               = 'AzStackHci_AddNode_Quorum_Resource_Check'
                Title              = 'Test Quorum Resource'
                DisplayName        = 'Test Quorum Resource'
                Severity           = $severity
                Description        = 'Checking Quorum Resource is set to File Share Witness or CloudWitness'
                Tags               = @{}
                Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/add-server'
                TargetResourceID   = "$($Quorum.Cluster.Name)/$($Quorum.QuorumResource.Name)"
                TargetResourceName = $Quorum.QuorumResource.Name
                TargetResourceType = 'Quorum Resource'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $Quorum.Cluster.Name
                    Resource  = $Quorum.QuorumResource.Name
                    Detail    = $detail
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            New-AzStackHciResultObject @params
        }
    }
    catch {
        throw ("Error cluster quorum on {0}. Error: {1}" -f (Get-Cluster).Name, $_.Exception)
    }
}

function Test-DriveLetterConsistency
{
    <#
    .SYNOPSIS
        Check if the DriveLetters are consistent across the cluster nodes.
    #>
    [CmdletBinding()]
    param (
        [pscredential]
        $LocalCredential,

        [string[]]
        $Ipv4OrHostName,

        [string[]]
        $DriveLetter = @('C','D')
    )
    try
    {
        $severity = 'CRITICAL'

        # get DriveLetters from the remote node
        $addNodeDriveLetters = @()
        $addNodeDriveLetters = Get-RemoteDriveLetter -LocalCredential $LocalCredential -Ipv4OrHostName $Ipv4OrHostName -DriveLetter $DriveLetter
        $localNodeDriveLetters = Get-LocalDriveLetter -DriveLetter $DriveLetter
        $instanceResults = @()
        foreach ($addNode in $addNodeDriveLetters)
        {
            if ($null -eq $addNode.DriveLetters)
            {
                $status = 'FAILURE'
                $detail = $lanTxt.DriveLetterConsistencyCheckError -f $addNode.ComputerName, ($addNode.DriveLetters -join ','), $DriveLetter -join ','
                Log-Info $detail -Type $severity
            }
            else
            {
                if (Compare-Object -ReferenceObject $addNode.DriveLetters -DifferenceObject $localNodeDriveLetters)
                {
                    $status = 'FAILURE'
                    $detail = $lanTxt.DriveLetterInconsistent -f $addNode.computername, ($addNode.DriveLetters -join ','), $env:computername, ($localNodeDriveLetters -join ','), ($DriveLetter -join ',')
                    Log-Info $detail -Type $severity
                }
                else
                {
                    $status = 'SUCCESS'
                    $detail = $lanTxt.DriveLetterConsistent -f  $addNode.computername, ($addNode.DriveLetters -join ','), $env:computername, ($localNodeDriveLetters -join ',')
                    Log-Info $detail
                }
            }
            $params = @{
                Name               = 'AzStackHci_AddNode_DriveLetter_Consistency_Check'
                Title              = 'Test DriveLetter Consistency'
                DisplayName        = 'Test DriveLetter Consistency'
                Severity           = $severity
                Description        = 'Checking DriveLetters are consistent across the cluster nodes'
                Tags               = @{}
                Remediation        = 'https://learn.microsoft.com/en-us/azure-stack/hci/manage/add-server'
                TargetResourceID   = $addNode.ComputerName
                TargetResourceName = $addNode.ComputerName
                TargetResourceType = 'DriveLetter'
                Timestamp          = [datetime]::UtcNow
                Status             = $Status
                AdditionalData     = @{
                    Source    = $addNode.ComputerName
                    Resource  = $addNode.DriveLetters -join ','
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
        throw ("Error checking DriveLetter consistency to node(s): $($Ipv4OrHostName -join ','). $($_.exception.StackTrace)")
    }
}

function Get-RemoteDriveLetter {
    [CmdletBinding()]
    param (
        [pscredential]
        $LocalCredential,

        [string[]]
        $Ipv4OrHostName,

        [string[]]
        $DriveLetter = @('C', 'D')
    )
    try
    {
        $addNodeDriveLetters = @()
        $addNodeDriveLetters = Microsoft.PowerShell.Core\Invoke-Command -ComputerName $Ipv4OrHostName -Credential $LocalCredential -ScriptBlock {
            $remoteDriveLetters = Get-Volume | Where-Object { $_.DriveLetter -in $USING:DriveLetter } | Select-Object -ExpandProperty DriveLetter | Sort-Object
            return (New-Object -TypeName PSObject -Property @{
                ComputerName = $env:COMPUTERNAME
                DriveLetters = $remoteDriveLetters
            })
        }
        return $addNodeDriveLetters
    }
    catch
    {
        throw ("Error retrieving DriveLetters from remote node {0}. Error: {1}" -f ($Ipv4OrHostName -join ','), $_.Exception)
    }
}

function Get-LocalDriveLetter {
    [CmdletBinding()]
    param (
        [string[]]
        $DriveLetter = @('C', 'D')
    )
    try
    {
        $driveLetters = @()
        $driveLetters = Get-Volume | Where-Object { $_.DriveLetter -in $DriveLetter } | Select-Object -ExpandProperty DriveLetter | Sort-Object
        return $driveLetters
    }
    catch
    {
        throw ("Error retrieving local DriveLetters. Error: {0}" -f $_.Exception)
    }
}

Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCApwxw3kJgGw4ds
# iqKuc99NSZXYgnZRIQJW+m0vwhj7SKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPp10wfN
# wdQWnyTBMP1WOWecvLbhMKFkGaoQR+M9tc27MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAvlFMYv0IJSE7CIOlf4ergO+guF3uiTAK4o2VuL7m
# ClS7phVJ95me9hFWphnIQcnYBRg1EPai+Kng/dpbFf1FU5RvX5YXZ7zvAUmU/ygM
# urxakOCHqBk6HzBBjX7Sv7G5b09W0nxKHfiNR7+Xc9es1q63R9fMAEGhS/Kqyhmu
# /P7pXTRAV9uBcOWCSW4PcvJvFJSrS6T1c3xQaByeWqYtdCmw8fZ7yweurMUQhHtR
# A8TkhNst84vs1O+JkIWXws85cOTYeBqRcFBsQRicaA/kNJ67dWCF44qyXa3Mz+tg
# jNt5Cz5doICIH0yDCm14w9Fu/8koNZPYDGpk/c637kdijKGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDmGOhvRnE451TDsdvZebrQEHk7BwVMRjr/yqGS
# ukbfcwIGaefB+1SLGBMyMDI2MDUwMzE0MzEwOS42MzZaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCC7ff3bqhK10OyAoGH5f4zeix/b
# GuTn+rQXTkAK+TukvDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILAkCt9W
# kCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wIgQgXDVXUUgM
# F2UJ5kLBUeKOgKL/uQDhW3pavs3L2zobM+AwDQYJKoZIhvcNAQELBQAEggIAB6Or
# Dk6fkF02LvIC8pvY8Z4KDL06IvMn+9HjA6utG2ty9pSPYK0etmZimjEVHwNvFzrX
# xMp7WPJ8Uc7hgXwbqMf85iuoL1cPO/7Gp3xxKcL/4BPa9x1an//59Rm0HeMHCfFz
# FiLyN9okffbG+215UXWGPPQo9Kd/uo+VKHEI2aguWgwtKI7V5fzV6h1oBKNgMcEI
# ePZk4ps/gB+gf6qJQDl2THkzs5Zf5MoQJ0/19wEEYIGIJSznYc2cRp96u8EDEuVs
# E1t76LsO0kLZXmOlErLYkEr6zKc9r0Y/fyG9Rc7YZcOaJfzjuy84kK+UfJmJzM8O
# VtKrhzztRgZ45dkkM7Vi1ewb/CcMvAdO893QPEPhTM7bnCTXu3EhmiWsXEi0qwOb
# MC6TxBP/6fX5F9A8quDbf5vHe+MLtxYFbaBEEjCTIJkwstI0WR/BP7X83TFWb6po
# rCkDeLC44+sRrUxfdzNd19n1nrEqLu2Cak4UXtFSlMaCNDk/Ojnp1tvej7s01on/
# DrGzNrGlij+qtUg9o6AJPlOlP9VL+IEQYoTAgxzS8Am71llw7+b9/g60nubCDIwN
# Fp+Ox6VjTqyRF5BRBvyPw2nvnjYabNDrjTznhqLHtEiZ1lKHKGvXXkFUyCRF45rX
# LViBrzXSWQX7T0MNtIMgPx5Af+XR0Kpv7fTiAGc=
# SIG # End signature block
