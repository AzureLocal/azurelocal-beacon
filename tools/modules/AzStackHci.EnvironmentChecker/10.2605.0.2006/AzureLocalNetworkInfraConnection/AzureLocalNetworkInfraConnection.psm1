<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
$MetaData = @{
    "OperationType" =  @("Deployment", "Upgrade")
    "UIName" = 'Azure Local Network Infra Connection'
    "UIDescription" = 'Check infrastructure network connection requirements for Azure Local'
}

function Test-AzureLocalNetworkInfraConnection
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters,

        [parameter(Mandatory = $true)]
        [ValidateSet('Deployment','Upgrade')]
        [System.String] $OperationType,

        [parameter(Mandatory = $false)]
        [ValidateSet('Small','Medium','Large')]
        [System.String] $HardwareClass = "Medium",

        [parameter(Mandatory = $false)]
        [ValidateSet('Standard','Stretch','RackAware')]
        [System.String] $ClusterPattern = "Standard",

        [parameter(Mandatory = $false)]
        [Switch] $FailFast
    )

    Trace-Execution -Message "[NetworkInfraConnectionValidator] MetaData: $($MetaData | ConvertTo-Json | Out-String)"
    Import-Module $PSScriptRoot\..\CommonLibrary\AzureLocal.EnvValidator.CommonLibrary.psd1 -Force -DisableNameChecking -Global | Out-Null

    try {
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

        $networkRole = $Parameters.Roles["Network"].PublicConfiguration
        $mgmtNetValue = $networkRole.NetworkDefinitions.Node.Networks.Network | Where-Object { $_.Name -eq "Management"}

        $hostNetworkRole = $Parameters.Roles["HostNetwork"].PublicConfiguration
        $atcHostNetworkConfiguration = $hostNetworkRole.PublicInfo.ATCHostNetwork.Configuration | ConvertFrom-JSON

        $cloudRole = $Parameters.Roles["Cloud"].PublicConfiguration

        [PSObject[]] $allIntentInfoForTesting = @()

        switch ($OperationType) {
            "Deployment" {
                # In deployment scenario, we will get intent info from ECE configuration.
                $allIntentInfoForTesting = $atcHostNetworkConfiguration.Intents
            }
            "Upgrade" {
                # In upgrade scenario, we will always get intent info from the running system, as
                # we expect end user configured NetworkATC intents before launching upgrade.
                $allIntentInfoForTesting = EnvValidatorNwkLibCreateAtcHostIntentsInfoFromSystem
            }
            default {
                throw "No interface found for $OperationType"
            }
        }

        # At this point, we should have the valid intent info from ECE or the running system.
        if ($allIntentInfoForTesting.Count -eq 0) {
            throw "No ATC Host Intents found. Please provide ATC Host Intents in the configuration."
        }

        Trace-Execution "Starting network validation for $($OperationType), detail output can be found in $($env:LocalRootFolderPath)\MASLogs\AzStackHciEnvironmentChecker*"

        #region Prepare IP pools
        $IpPools = New-Object System.Collections.ArrayList

        # 1st pool
        $ipPool = [PSCustomObject]@{
            StartingAddress = $mgmtNetValue.IPv4.StartAddress # Infra IP Pool Starting Address
            EndingAddress   = $mgmtNetValue.IPv4.EndAddress # Infra IP Pool Ending Address
        }

        Trace-Execution "Found pool with StartingAddress: $($ipPool.StartingAddress) EndingAddress: $($ipPool.EndingAddress)"
        $IpPools.Add($ipPool) | Out-Null

        # Additional pool
        $AdditionalInfrastructureSubnetsValue = $null
        if ($hostNetworkRole.PublicInfo.AdditionalInternalSubnets) {
            try {
                $AdditionalInfrastructureSubnetsText = $hostNetworkRole.PublicInfo.AdditionalInternalSubnets.configuration
                $AdditionalInfrastructureSubnetsValue = ConvertFrom-JSON $AdditionalInfrastructureSubnetsText -ErrorAction Stop
            } catch {
                # In case of upgrade, the parameter won't have any value in it but just a string "[AdditionalInternalSubnets]""
                Trace-Execution "Failed to parse AdditionalInfrastructureSubnets.Configuration. $_. Ignore error and continue."
            }
        }

        if ($AdditionalInfrastructureSubnetsValue) {
            foreach ($pool in $AdditionalInfrastructureSubnetsValue) {
                $ipPool = [PSCustomObject]@{
                    StartingAddress = $pool.StartingAddress # Infra IP Pool Starting Address
                    EndingAddress   = $pool.EndingAddress # Infra IP Pool Ending Address
                }

                Trace-Execution "Found pool with StartingAddress: $($ipPool.StartingAddress) EndingAddress: $($ipPool.EndingAddress)"
                $IpPools.Add($ipPool) | Out-Null
            }
        }
        #endregion

        Trace-Execution "Starting Network Connection Validation for operation [ $($OperationType) ]"

        switch ($OperationType) {
            { $_ -in @("Deployment", "Upgrade") } {
                # Network Connection Validation Checks
                [System.Boolean] $isProxyEnabled= $false
                $proxySettings = Get-ASProxySettings -Parameters $Parameters
                $isProxyEnabled = $proxySettings -and ($proxySettings.HTTP -or $proxySettings.HTTPS)

                #region Prepare invoke validator parameters
                $param = @{
                    ATCHostIntents = $allIntentInfoForTesting
                    IpPools = $IpPools
                    ProxyEnabled = $isProxyEnabled
                    PassThru = $true
                    HardwareClass = $HardwareClass
                    ClusterPattern = $ClusterPattern
                    OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                    OperationType = $OperationType
                }

                $RegistrationCloudName = $cloudRole.PublicInfo.RegistrationCloudName
                if ($RegistrationCloudName -ieq 'Azure.local') {
                    $param += @{
                        RegionName = 'AzureLocal'
                    }
                }
                else {
                    $param += @{
                        RegionName = $cloudRole.PublicInfo.RegistrationRegion
                    }
                }
                #endregion

                [array] $Result = AzStackHci.EnvironmentChecker\Invoke-AzStackHciNetworkInfraConnectionValidation @param

                # Check if the ParseResult method supports the Parameters
                if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters') {
                    Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
                    return [EnvironmentValidator]::ParseResult($Result, 'NetworkInfraConnection', $FailFast, $Parameters)
                } else {
                    Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
                    return [EnvironmentValidator]::ParseResult($Result, 'NetworkInfraConnection', $FailFast)
                }
            }
            default {
                Trace-Execution "No interface found for $OperationType"
            }
        }
    } catch {
        Trace-Execution "Validator failed. $_"
        Trace-Execution "$($_.ScriptStackTrace)"
        throw $_
    } finally {
        if ($backupPSModuleAutoLoadingPreference) {
            $PSModuleAutoLoadingPreference = $backupPSModuleAutoLoadingPreference
        }
    }
}

Export-ModuleMember -Function Test-AzureLocalNetworkInfraConnection
Export-ModuleMember -Variable MetaData

# SIG # Begin signature block
# MIInSAYJKoZIhvcNAQcCoIInOTCCJzUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDKSTQn/jLETHJd
# dJyxb1fOQMaK7QYJ+zIdZqKgTIexMaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIbzYmmh
# kVlPRY65YKjiI9hOi6lAIHvzB5j8TSSXOMgoMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAkUn33eq2CqVITpZz3I+TfAj3G91N1MbR2NgfxxG/
# E4cB4oeMNXK6z9XYrbkm2Vcdl0wideTHiMWYaYRE2pwr/hQNUcOs8d7srKyljEoe
# 2EHlEIzH/ZPpldrR8yvNpOoF2dCC446KKlfCUgi/D+C3NkfCi8N5Cp1NZAH9mcFt
# O1Wuk2k2PHkXShq4QBMIcCGiL+kI560ww98GRuRmcncgkVfqx6PWtVkTgCabqniQ
# xjJ+AMtdV/deTcmHAynlQPiFltZp6HN48w2QaxOW/21amY0eSxbIokSV7Y+LNzXc
# 5OfSfjjILXTaZSYt2Ezn6t5q94Iy5ro5UF6uJSDy4xHDB6GCF5YwgheSBgorBgEE
# AYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCCM+hwoRmuOAGRBMEumy8qSgw9W+PYPXY1NJNCK
# MUdcWgIGaegM03WJGBIyMDI2MDUwMzE0MzExMS4yOVowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjozMzAzLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMzAAACITPANfvSDyGkAAEAAAIh
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5Mzk1NFoXDTI3MDUxNzE5Mzk1NFowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMzAzLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANtxMAKpTVi9GhzJYvY8v1/J//5Q
# uzaortTVpmxGcNlKeUKvsruOADd4UIQkvkFnt1RMLQN5l6l/5kL7scRsHgh3OYl9
# ABQMUV6upjlVMeZC8/ZcDeVZIWPvjSJ1wZQeCU/kf89sIlTsYAdY/Yd1wKN3HWVg
# CjQD7MsjvHCdNB4zI5dfbXYSDhSYM88mDF1MzDpYVVawE9ZEGLmAOLHLaz7tHwAO
# TmVsEEUMHmHQKOs1Yg3u4IDMXmDu2usvydcgqnXSaP1HGFwZD62WG3pUi93KBFVN
# QZ3MUHb+cG8mpD2THEWW1BJPvR8R3HhPJoqjD9/n4FKHjPj/1/s1chVVMuf/yRwk
# B9GoWZGusW3cgpvLtWvOZi6hBYPSWY0W0ZDnsGsmQ+s8UA96TUAu1xtvsUfedCm+
# LyeDP8wVf/5yeY0VYVTb1VUubMH1e8tnFti+R5623SaHmV+1543asTBTKt2sq5/P
# 2HZLqltq174LaHTYKtfBKRrTHp7OlOYaQgksW3bm5v9Rhc0t0d2zEYPoR9yQ4igl
# iybgxL0X+9Kos0crz0jS9MsGeBASnosgWQg1qdFPc+03Hek0pEolEAtzovqaFbiE
# vhocvvj2o99Dva3moAybnGIpgyAnZZqeJ1Es24jbnUkg3utpp4D/a9vRcWRlwhtN
# HWl9AaxyjhTSDm2PAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQU5iMizmprql+6q4/L
# IrUVOvlAMKcwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBADgj/duR2dPEPasW6bcw
# XzFUp0SSiEA5tt4+tD7R+vltGKaPP2xWQpP/uByPg4xwKVJgb4h1foyncRiwsdZ+
# O/B/MWh5kT7JNt0GP/VUdlBG4KbDpCp5UJNvDaedLucHGdZ32hlds9SmoRrAfkOp
# dBpYWBH0DgpZUr8i9dUMyPU+U8IRLU/cmic1t2GSSTPj2sm4o6blvt78EfyWioCZ
# c5dFzbbLFZVMxasSnimyWa/x5PtWhjxf+N0phM9URex+YttUVyrMy4Hy8UZ9TJax
# ZE5LzCCruVBh9ZxiqHs3KagBNf7BZgrfNYbtpFyI8ZQDPOdd1/5oe0hadAs1rkcW
# ZJeSJqTd9K6mtZhmIeG5iMTXqGugClwEemb7xL+Q2qGb1aNBf7YHGdi/4l6PLqWp
# OLx8sEtLTr1ZdXD+m1/khX4W1iXfga9Wh6DfVShSZVVl7VINQmSb10NdzyX+oENi
# IAhPYIKw9PK31cD0lW4fF0/refsKG9YA7/jtBG4IOxSUUmhbDIHCXuN5ilpFUy1C
# 3SK4kwYaOARolfVD/aPyxdRG9Nx4scMP2Kla3T3ZkNYxByINGaEc0U5fV2eMG+T+
# TVQxyD33uPmhjOcCdKkm+WD/gE/dpUTSH9gfYqCwptTg1dkcCMlePZKWqjULXXkI
# bqoFloWQzxbq89kKbmqdJ7M6MIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
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
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAAtsSBlmfJgdcnUMZvl8aOmVem25oIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtobLHMCIYDzIw
# MjYwNTAzMTE0MDU1WhgPMjAyNjA1MDQxMTQwNTVaMHcwPQYKKwYBBAGEWQoEATEv
# MC0wCgIFAO2hsscCAQAwCgIBAAICCVcCAf8wBwIBAAICE68wCgIFAO2jBEcCAQAw
# NgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgC
# AQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAOsa4c+lzsJ4u7xOJRAg48EAf5dee
# 2nuNFDqS68GbunKLNN2HeJEqZxyeIKTu0gY1KLgKF208+Z/HGBlDfdOGtIh1Rp0z
# T8SCsVvF+utXddkRTAF27B4cvrb8qrUr/ptqeXopVb8lP+MxvFv6qIhu5TQtjyKM
# kPFhJZ81L7QJvbM8GB1LV2jBDnzG/iPM05giMJtk/6v1hdJr+ySfw1zj6oYDDl3W
# eNYqJmr39U89Y/zSF05vARNX6nm8bRRMAf2rFouEhUIgdxB50S7mO4Td28gEPQrT
# BTazYHYHIqT7b4TgC9Hy1cYEj5OxZepH0O8uvM2rtU6N046k0MOSe07VRzGCBA0w
# ggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACITPA
# NfvSDyGkAAEAAAIhMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEILgYxTgVGnjFl+jD+W+gWhOeaYFi
# 1Ji3MWecHOwGdeUxMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgAO8hB58V
# VRrgEnLwhnLAwC+YZIp1RWoSbL0D748KPUQwgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiEzwDX70g8hpAABAAACITAiBCAjD2zSCFj/
# Y19BCUTJXgos6hX8ohrRnX8/UYMSsnZqMjANBgkqhkiG9w0BAQsFAASCAgCs1q6D
# 5S5MzulZQebYxiBKlbPknR39ATlu1lsyfLC8wp9dD/YxHj4v6lfIAOvT2TTbvCdM
# Kag+PcvrHQSxscRVN3QS13zAfZJk9jnEMYmrl7qhce2sk0dmfh7aNaAowXyecSmQ
# b+pXQqB2jxuq8Lr2zpgwT5/aIPSjP4MTqAasVBDpr67Ve4Y/dFwwXRGQtL3KFGO5
# GGC8/9rk27sTC9ewnJ2C+Ggadw3h+HEiPBdryr/GwuWR1MbJ7WXroWVT+aEdhX4J
# YGG9iJZ5BAyWsgcm997fhV4CPzshYqRfQHIAAVaLX67N2ko1OqNQsRV7rnrYxU2G
# zYace8W2kZvNZqLbk/s91US8q0Biuh7gCVg9NkzXDoUGtrmwEXiyv3uzAAERvkG3
# PaQ6Vv3kEJY5Ihe7r3x0QMqnEsOS/8AQWAxJbzFJxF9w2z4AbhRJKl9aZtoNTsLt
# RDSHT4wLHoTfBz8dXtGTerGePVsNEV6TaU17jFzoS4aty52IPdhJJHb9AzMBy4fY
# v7MpjM+kJ34rn5oUipwYY6Gia8L48VXRGiKXQOQGpmZZrR74liqsn5TZaiFkkSaD
# 0cnGL9sSFEudd8Xuz50s27va7AlfQOT7t/zYWGlMMy8F6a0X8pP9WPU9lTA55kV2
# 7qlZSpCfwjyPhF63Pp3kiTXVBvRxDjLfKCYPgQ==
# SIG # End signature block
