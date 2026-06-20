<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
 $MetaData = @{
    "OperationType" =  @("Deployment", "AddNode", "Upgrade", "PreUpdate", "PreUpdateJIT")
    "UIName" = 'Azure Stack HCI Network'
    "UIDescription" = 'Check network requirements'
}
function Test-AzStackHciNetwork
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters,

        [parameter(Mandatory = $true)]
        [ValidateSet('AddNode','Deployment','Upgrade', 'PreUpdate')]
        $OperationType,

        [parameter(Mandatory = $false)]
        [ValidateSet('Small','Medium','Large')]
        [String]
        $HardwareClass = "Medium",

        [parameter(Mandatory = $false)]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String]
        $ClusterPattern = "Standard",

        [parameter(Mandatory = $false)]
        [switch]
        $FailFast
    )

    Import-Module $PSScriptRoot\..\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -Force -DisableNameChecking -Global | Out-Null

    try
    {
        $backupPSModuleAutoLoadingPreference = $PSModuleAutoLoadingPreference
        # Disable module auto-loading and explicitly import modules needed.
        $PSModuleAutoLoadingPreference = [System.Management.Automation.PSModuleAutoLoadingPreference]::None
        Import-Module Microsoft.PowerShell.Utility -Verbose:$false
        Import-Module Microsoft.PowerShell.Management -Verbose:$false
        Import-Module NetTCPIP -Verbose:$false
        Import-Module Hyper-V -Verbose:$false
        Import-Module NetAdapter -Verbose:$false
        Import-Module DnsClient -Verbose:$false

        # Import Module via Helper in case this is update
        [EnvironmentValidator]::EnvironmentValidatorImport($Parameters)
        $ENV:EnvChkrOp = $OperationType
        if (Get-Command -Name IsDHCPEnabled -ErrorAction SilentlyContinue)
        {
            $dhcpEnabled = IsDHCPEnabled -Parameters $Parameters
        }
        else
        {
            $dhcpEnabled = $false
        }

        Trace-Execution "DHCP Enabled (ECE): $dhcpEnabled"

        $networkRole = $Parameters.Roles["Network"].PublicConfiguration
        $mgmtNetValue = $networkRole.NetworkDefinitions.Node.Networks.Network | Where-Object { $_.Name -eq "Management"}
        $mgmtSubnetValue =  $mgmtNetValue.IPv4.Subnet

        $hostNetworkRole = $Parameters.Roles["HostNetwork"].PublicConfiguration
        $atcHostNetworkConfiguration = $hostNetworkRole.PublicInfo.ATCHostNetwork.Configuration | ConvertFrom-JSON

        $physicalMachinesPublicConfig = $Parameters.Roles["BareMetal"].PublicConfiguration
        $nodesCount = $physicalMachinesPublicConfig.Nodes.Node.Count

        [PSObject[]] $allIntentInfoForTesting = @()

        switch ($OperationType)
        {
            { $_ -in @("AddNode", "Upgrade", "PreUpdate") }
            {
                $allIntentInfoForTesting = EnvValidatorNwkLibCreateAtcHostIntentsInfoFromSystem
            }
            default
            {
                $allIntentInfoForTesting = $atcHostNetworkConfiguration.Intents

                if (($null -eq $allIntentInfoForTesting) -or ($allIntentInfoForTesting.Count -eq 0))
                {
                    # If no intents are provided in these scenarios, we will try to get info from the running system.
                    $allIntentInfoForTesting = EnvValidatorNwkLibCreateAtcHostIntentsInfoFromSystem
                }
            }
        }

        # At this point, we should have the valid intent info from ECE or the running system.
        if ($allIntentInfoForTesting.Count -eq 0)
        {
            throw "No ATC Host Intents found. Please provide ATC Host Intents in the configuration."
        }

        [PSObject[]] $storageNetworkDefinition = $atcHostNetworkConfiguration.storageNetworks

        [System.Collections.Hashtable] $storageNetworksVlanIdInfo = @{}
        foreach ($storagenetworkInfo in $storageNetworkDefinition)
        {
            $storageNetworksVlanIdInfo.Add($storagenetworkInfo.networkAdapterName, $storagenetworkInfo.VlanId)
        }

        Trace-Execution "Starting network validation for $($OperationType), detail output can be found in $($env:LocalRootFolderPath)\MASLogs\AzStackHciEnvironmentChecker*"

        $IpPools = New-Object System.Collections.ArrayList

        $ipPool = [PSCustomObject]@{
            StartingAddress = $mgmtNetValue.IPv4.StartAddress # Infra IP Pool Starting Address
            EndingAddress   = $mgmtNetValue.IPv4.EndAddress # Infra IP Pool Ending Address
        }

        $IpPools.Add($ipPool) | Out-Null

        $AdditionalInfrastructureSubnetsValue = $null
        if ($hostNetworkRole.PublicInfo.AdditionalInternalSubnets)
        {
            try
            {
                $AdditionalInfrastructureSubnetsText = $hostNetworkRole.PublicInfo.AdditionalInternalSubnets.configuration
                $AdditionalInfrastructureSubnetsValue = ConvertFrom-JSON $AdditionalInfrastructureSubnetsText -ErrorAction Stop
            }
            catch
            {
                # In case of upgrade, the parameter won't have any value in it but just a string "[AdditionalInternalSubnets]""
                Trace-Execution "Failed to parse AdditionalInfrastructureSubnets.Configuration. $_. Ignore error and continue."
            }
        }

        if ($AdditionalInfrastructureSubnetsValue)
        {
            foreach ($pool in $AdditionalInfrastructureSubnetsValue)
            {
                $ipPool = [PSCustomObject]@{
                    StartingAddress = $pool.StartingAddress # Infra IP Pool Starting Address
                    EndingAddress   = $pool.EndingAddress # Infra IP Pool Ending Address
                }

                $IpPools.Add($ipPool) | Out-Null
            }
        }

        Trace-Execution "Trying to get IP pools information"

        foreach ($ipPool in $ipPools)
        {
            $startingAddress = $ipPool.StartingAddress
            $endingAddress = $ipPool.EndingAddress
            Trace-Execution "Found pool with StartingAddress: $startingAddress EndingAddress: $endingAddress"
        }

        [System.Collections.Hashtable] $nodeToIPMap = Get-NetworkMgmtIPv4FromECEForAllHosts -Parameters $Parameters
        $domainCredential = [EnvironmentValidator]::GetDomainAdminCredential($Parameters)
        $localCredential = [EnvironmentValidator]::GetLocalAdminCredential($Parameters)

        Trace-Execution "Starting $($OperationType) Network Validation"

        # Detect storage type from ECE parameters
        [System.String] $detectedStorageType = "S2D"

        try {
            $storageConfig = $Parameters.Roles["Storage"].PublicConfiguration.PublicInfo.StorageConfiguration
            if ($storageConfig -and $storageConfig.Type) {
                $type = $storageConfig.Type
                if ($type -and $type -ne "" -and $type -notmatch '^\[\{') {
                    $detectedStorageType = $type
                }
            }
        } catch {
            Trace-Execution "Could not read StorageType from ECE parameters. Defaulting to S2D. More Info: $_"
        }

        switch ($OperationType)
        {
            { $_ -in @("Deployment", "Upgrade", "PreUpdate") }
            {
                # Network Validation Checks
                [System.Boolean] $isProxyEnabled= $false
                $proxySettings = Get-ASProxySettings -Parameters $Parameters
                $isProxyEnabled = $proxySettings -and ($proxySettings.HTTP -or $proxySettings.HTTPS)

                $psSession = [EnvironmentValidator]::NewPsSessionAllHosts($Parameters)

                $cloudRole = $Parameters.Roles["Cloud"].PublicConfiguration
                $deployADLess = $cloudRole.PublicInfo.DeployADLess

                if ($deployADLess -eq "true" -and $OperationType -eq "PreUpdate")
                {
                    Trace-Execution "Do not test credentials for AD'less update"
                }
                else
                {
                    $ConnectionCredential = [EnvironmentValidator]::GetDomainAdminCredential($Parameters)
                    $allStampNodes = [EnvironmentValidator]::GetAllHostNicIps($Parameters)
                    $testNode = $allStampNodes[-1]

                    Import-Module -Name Microsoft.WSMan.Management -Verbose:$false -Scope Global -ErrorAction SilentlyContinue | Out-Null

                    if (Test-WSMan -ComputerName $testNode -Credential $ConnectionCredential -Authentication Default -ErrorAction SilentlyContinue)
                    {
                        Trace-Execution "Attempting PsSession $testNode with domain credentials"
                    }
                    else
                    {
                        Trace-Execution "Attempting PsSession $testNode with local credentials"
                        $ConnectionCredential = [EnvironmentValidator]::GetLocalAdminCredential($Parameters)
                        if ($null -eq $ConnectionCredential)
                        {
                            throw "Unable to create a valid session to $testNode. No local admin credential found."
                        }
                    }
                }

                $param = @{
                    IpPools = $IpPools
                    ManagementSubnetValue = $mgmtSubnetValue
                    HostNetworkInfo = $atcHostNetworkConfiguration
                    ATCHostIntents = $allIntentInfoForTesting
                    ProxyEnabled = $isProxyEnabled
                    PSSession = $psSession
                    PassThru = $true
                    dhcpEnabled = $dhcpEnabled
                    OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                    OperationType = $OperationType
                    HardwareClass = $HardwareClass
                    ClusterPattern = $ClusterPattern
                    NodesInCluster = $nodesCount
                    NodeToManagementIPMap = $nodeToIPMap
                    ConnectionDomainAdminCredential = $domainCredential
                    ConnectionLocalAdminCredential = $localCredential
                    DeployADLess = $deployADLess
                    StorageType = $detectedStorageType
                }

                $RegistrationCloudName = $Parameters.Roles["Cloud"].PublicConfiguration.PublicInfo.RegistrationCloudName
                if ($RegistrationCloudName -ieq 'Azure.local')
                {
                    $param += @{
                        RegionName = 'AzureLocal'
                    }
                }

                [array]$Result = AzStackHci.EnvironmentChecker\Invoke-AzStackHciNetworkValidation @param

                # If this is a CI environment downgrade inbox driver test result
                if (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\SQMClient -Name IsCIEnv -ErrorAction SilentlyContinue)
                {
                    Trace-Execution "CI Environment. Downgrade inbox driver result severity from CRITICAL to WARNING"
                    $Result | Where-Object Name -eq 'AzStackHci_Network_Test_AdapterDriver' | Where-Object { if ($_.Severity -eq "CRITICAL") { $_.Severity = "WARNING" } }

                    if (($ClusterPattern -eq 'RackAware') -and ((Get-WmiObject -Class Win32_ComputerSystem).Model -eq "Virtual Machine"))
                    {
                        Trace-Execution "CI Virtual RackAware Environment. Downgrade network intent result severity from CRITICAL to WARNING"
                        $Result | Where-Object Name -eq 'AzStackHci_Network_Test_NetworkIntentRequirement' | Where-Object { if ($_.Severity -eq "CRITICAL") { $_.Severity = "WARNING" } }
                    }
                }

                # Check if the ParseResult method supports the Parameters
                if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
                {
                    Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
                    return [EnvironmentValidator]::ParseResult($Result, 'Network', $FailFast, $Parameters)
                }
                else
                {
                    Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
                    return [EnvironmentValidator]::ParseResult($Result, 'Network', $FailFast)
                }
            }
            "AddNode"
            {
                # Get nodes name from runtime parameters "NodeName", which is a string separated by space
                $runtimeParameters = $Parameters.RunInformation['RuntimeParameter']

                Trace-Execution "Node to be added: $($runtimeParameters['NodeName'])"
                [System.String[]] $allNodeNamesToBeAdded = $runtimeParameters['NodeName'].Split()
                [System.Management.Automation.Runspaces.PSSession[]] $psSession =  [EnvironmentValidator]::NewPsSessionByHost($Parameters, $allNodeNamesToBeAdded, $false)

                # IpAddress is not a runtime parameter during Repair-Server run, so set the array to null
                [System.String[]] $allNodeIpAddresses = if ($runtimeParameters['IpAddress']) { $runtimeParameters['IpAddress'].Split() } else { @() }
                Trace-Execution "Node IP found: $($allNodeIpAddresses -join ', ')"

                # Add the node to the map if it's not already there
                foreach ($nodeToBeAdded in $allNodeNamesToBeAdded)
                {
                    if ($nodeToBeAdded -notin $nodeToIPMap.Keys)
                    {
                        $Ipv4OrHostName = if ($allNodeIpAddresses.Count -gt 0) { $allNodeIpAddresses[$allNodeNamesToBeAdded.IndexOf($nodeToBeAdded)] } else { $null }

                        if ($dhcpEnabled -or ([string]::IsNullOrEmpty($Ipv4OrHostName)))
                        {
                            # IpAddress is not a runtime parameter during Repair-Server call, so need to get from network helper instead
                            $Ipv4OrHostName = ([EnvironmentValidator]::GetHostNicIpByName($Parameters, $nodeToBeAdded) | Select-Object -First 1)
                        }

                        $nodeToIPMap.Add($nodeToBeAdded, $Ipv4OrHostName)
                    }
                }

                # Check to see if BrownfieldUpgrade or GreenfieldDeployment
                $InstallationMethod = Get-InstallationMethod -Parameters $Parameters

                $param = @{
                    IpPools = $IpPools
                    ManagementSubnetValue = $mgmtSubnetValue
                    PSSession = $psSession
                    ATCHostIntents = $allIntentInfoForTesting
                    NodeToManagementIPMap = $nodeToIPMap
                    PassThru = $true
                    dhcpEnabled = $dhcpEnabled
                    OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                    OperationType = $OperationType
                    HardwareClass = $HardwareClass
                    ClusterPattern = $ClusterPattern
                    InstallationMethod = $InstallationMethod
                    NodesInCluster = $nodesCount
                    StorageType = $detectedStorageType
                }

                $RegistrationCloudName = $Parameters.Roles["Cloud"].PublicConfiguration.PublicInfo.RegistrationCloudName
                if ($RegistrationCloudName -ieq 'Azure.local')
                {
                    $param += @{
                        RegionName = 'AzureLocal'
                    }
                }

                [array]$Result = AzStackHci.EnvironmentChecker\Invoke-AzStackHciNetworkValidation @param

                # If this is a CI environment downgrade inbox driver test result
                if (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\SQMClient -Name IsCIEnv -ErrorAction SilentlyContinue)
                {
                    Trace-Execution "CI Environment. Downgrade inbox driver result severity from CRITICAL to WARNING"
                    $Result | Where-Object Name -eq 'AzStackHci_Network_Test_AdapterDriver' | Where-Object { if ($_.Severity -eq "CRITICAL") { $_.Severity = "WARNING" } }
                }

                # Check if the ParseResult method supports the Parameters
                if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
                {
                    Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
                    return [EnvironmentValidator]::ParseResult($Result, 'Network', $FailFast, $Parameters)
                }
                else
                {
                    Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
                    return [EnvironmentValidator]::ParseResult($Result, 'Network', $FailFast)
                }
            }
            default
            {
                Trace-Execution "No interface found for $OperationType"
            }
        }
    }
    catch
    {
        Trace-Execution "Validator failed. $_"
        Trace-Execution "$($_.ScriptStackTrace)"
        throw $_
    }
    finally
    {
        if ($backupPSModuleAutoLoadingPreference)
        {
            $PSModuleAutoLoadingPreference = $backupPSModuleAutoLoadingPreference
        }
        $PsSession | Microsoft.PowerShell.Core\Remove-PSSession -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Test-AzStackHciNetwork -Variable MetaData
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB7C7hF235Df6dL
# 8AuVjAWbo5y47dSyjr8m7krlWNs8naCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIOQbG9g8
# c6WFzTTKyCdYpTM1qJpcrgpoe7zVBHcQ1E18MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAL/VgMRIRw5ZEdnMURCUhKV/FGvhqq84/7gBKgVhG
# v+k3ODv2KcMgH3UFxomswkNGImqGBaJ4fnlrgmP+J157ZZAMMIJUIVkQqcdic/yH
# nkGSWqnugJRLoQzeaslRvC1F2VUd36ne2Jv8Evb7RK9PXNsVC4a2Lec1TSmeaNfp
# HxtRthRlIGa79BOwy2981XskkZJh2zEVL4ic3Jfvh3gh+RNpQ2jvKoww5HTapBrN
# 9NUPW7yjpiRbGGaJuYGnav++aLH7avDbj1Aes9tJdb00wpkiINWHz01Fy9O2QgDw
# vbNQRQgx5n3GCAWXP947uXJK8KSur5nR9sN2W8oF1TRGoKGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAF0IIuOxPHC3tJnH8fBC8Ykz3/N0QnGtMaw/IM
# roFPKQIGaefB+1SOGBMyMDI2MDUwMzE0MzExMC4yMDFaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAvG9sbchEx+GB6gs3Aj/V1Z9KI
# 5mv6IknkvKRZOAD8vzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILAkCt9W
# kCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wIgQgXDVXUUgM
# F2UJ5kLBUeKOgKL/uQDhW3pavs3L2zobM+AwDQYJKoZIhvcNAQELBQAEggIAPz7E
# LzUb4uqMbLej4tkw97MtSyIX2B0Kn1/I6cs46Tw5uhtLHrEtRWtsZvUfphpwPZuX
# VpK9K93FBRUzSMet2QAEgmJkE5cYHRu7cmHZ2lAPDxOUjEziwtbhWpsSXY6SpR5a
# wXZmH6UecWlyDpG+K5G9ISNm9rT3Y9uOBPGhqJCH0lBOL9xYQlt3HVtXV0ggGl8H
# e/9HS0Q4aDqsyML8tCkD2V0dnE0eexewfA2R/nDs3UjQMtElo6wcqfFlSAWzldXy
# XayiIAT08JndpAyQL4Ze53Cv7gK8mxtrEhNuGWxinsLic1Xzw529zcQkf43DRvu/
# TcJ8tRyiR5fAvqgQyMb/0XaBshzZIHW9+PeY6OPM7oOhV0M3OTe1Ckv8Ca+aOoHy
# Rjry5LlbhYIC/fZxGPF5THsXwWpvN5KUCk79g97w07ocTgPDUgy2KVTPHcHbNv/Q
# AABCC4NDx94EPyQap29ITHbG2ypm3jUnKrbanLgaU/A3ymXavhUeukQZgqlT5wBe
# 5dzntfrTaG4hQc1v/VG/TI+vo+e35pXq0YeU6w9OCGZN9mw1TGar1sIyxM01jt+3
# TWV6cy3MYEuXWFpMRfkG+lGdcKWQUfqhGETB5+AS8sN4EuAhImlCDapUk0nzzNzP
# xmLZUXCyYbAw+q5wDAEku8spz+2dexSmaD8ALfw=
# SIG # End signature block
