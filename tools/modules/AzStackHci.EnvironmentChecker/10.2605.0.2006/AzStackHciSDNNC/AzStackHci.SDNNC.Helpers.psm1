Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.SDNNC.Strings.psd1

function Test-NwkValidator_SDNNCDeployed {
    <#
    .SYNOPSIS
    Test if SDN Network Controller is deployed.
    .DESCRIPTION
    This function checks if the SDN Network Controller feature is deployed on the cluster nodes.
    .EXAMPLE
    Test-NwkValidator_SDNNCDeployed
    #>
    [CmdletBinding()]
    param (
    )
    # Note: $Parameters argument as follows is no long used as Check-NCServices has been modified to make it optional
    # [CloudEngine.Configurations.EceInterfaceParameters] $Parameters
    try {
        Log-Info "Checking if SDN Network Controller feature is deployed on cluster nodes..."
        Import-Module $PSScriptRoot\..\AzStackHciSBEHealth\AzStackHci.SBEHealth.Helpers.psm1 -Force -DisableNameChecking -Global | Out-Null
        $ncNugetPath = Get-ASArtifactPathLite -NugetName "Microsoft.AS.Network.Deploy.NC" 2>$null 3>$null 4>$null
        Import-Module (Join-Path $ncNugetPath "content\Powershell\Roles\NC\NC.psm1") -DisableNameChecking -Verbose:$false -Force -Scope Global | Out-Null

        $instanceResults = @()
        $sdnNCDeployedTestResult = Test-FCNCMOCDeployed -ErrorAction Stop -Verbose
        $sdnNCDeployedTestStatus = if ($sdnNCDeployedTestResult) { 'SUCCESS' } else { 'SDN not enabled' }

        $sdnNCDeployedRstObject = @{
            Name               = 'AzStackHci_SDN_NC_Deployed'
            Title              = 'Validate SDN Network Controller feature deployment'
            DisplayName        = 'Validate SDN Network Controller feature deployment'
            Severity           = 'INFORMATIONAL'
            Description        = 'Check if SDN Network Controller on Failover Cluster feature is deployed on cluster nodes'
            Tags               = @{}
            Remediation        = 'https://aka.ms/azurelocal'
            TargetResourceID   = 'FCNC'
            TargetResourceName = 'FCNCInstallFlag'
            TargetResourceType = 'ECE Parameters'
            Timestamp          = [datetime]::UtcNow
            Status             = $sdnNCDeployedTestStatus
            AdditionalData     = @{
                Source    = 'Host nodes'
                Resource  = 'FCNCInstallFlag'
                Detail    = if ($sdnNCDeployedTestResult) { $lnTxt.TestSDNNCDeployedTrue } else { $lnTxt.TestSDNNCDeployedFalse }
                Status    = $sdnNCDeployedTestStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @SDNNCDeployedRstObject

        return $instanceResults
    } catch {
        throw "An error occurred while running $($MyInvocation.MyCommand): $_"
    } finally {
        Log-Info "Completed $($MyInvocation.MyCommand)"
    }
}

function Test-NwkValidator_SDNNCServices {
    <#
    .SYNOPSIS
    Test if SDN Network Controller services are healthy.
    .DESCRIPTION
    This function checks if the SDN Network Controller services are healthy on the cluster nodes.
    .EXAMPLE
    Test-NwkValidator_SDNNCServices
    #>
    [CmdletBinding()]
    param (
    )
    try {
        Log-Info "Checking if SDN Network Controller services are healthy on cluster nodes..."
        Import-Module $PSScriptRoot\..\AzStackHciSBEHealth\AzStackHci.SBEHealth.Helpers.psm1 -Force -DisableNameChecking -Global | Out-Null
        $ncNugetPath = Get-ASArtifactPathLite -NugetName "Microsoft.AS.Network.Deploy.NC" 2>$null 3>$null 4>$null
        Import-Module (Join-Path $ncNugetPath "content\Powershell\Roles\NC\NC.psm1") -DisableNameChecking -Verbose:$false -Force -Scope Global | Out-Null

        $instanceResults = @()
        $sdnNCDeployedTestResult = Test-FCNCMOCDeployed -ErrorAction Stop -Verbose
        $sdnNCServicesTestResult = if ($sdnNCDeployedTestResult) { Check-NCServices -ErrorAction Stop -Verbose } else { "SDN not enabled" } # Show text if NC not deployed
        $sdnNCServicesTestStatus = if ($sdnNCServicesTestResult -is [bool] -and $sdnNCServicesTestResult) { 'SUCCESS' } elseif ($sdnNCServicesTestResult -is [bool]) { 'FAILURE' } else { "$sdnNCServicesTestResult. SKIPPED" }

        $sdnNCServicesRstObject = @{
            Name               = 'AzStackHci_SDN_NC_Services'
            Title              = 'Validate health of SDN Network Controller services when SDN is enabled'
            DisplayName        = 'Validate SDN NC services health'
            Severity           = 'INFORMATIONAL'
            Description        = 'Check if SDN Network Controller services running on cluster nodes are healthy when SDN is enabled'
            Tags               = @{}
            Remediation        = 'https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-sdn-integration'
            TargetResourceID   = 'FCNC'
            TargetResourceName = 'SDN Network Controller services'
            TargetResourceType = 'Cluster Service'
            Timestamp          = [datetime]::UtcNow
            Status             = $sdnNCServicesTestStatus
            AdditionalData     = @{
                Source    = 'Host nodes'
                Resource  = 'SDN Network Controller services'
                Detail    = if ($sdnNCServicesTestResult -is [bool] -and $sdnNCServicesTestResult) { $lnTxt.TestSDNNCServicesTrue } elseif ($sdnNCServicesTestResult -is [bool]) { $lnTxt.TestSDNNCServicesFalse } else { $lnTxt.TestSDNNCServicesSkipped }
                Status    = $sdnNCServicesTestStatus
                TimeStamp = [datetime]::UtcNow
            }
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $instanceResults += New-AzStackHciResultObject @sdnNCServicesRstObject

        return $instanceResults
    } catch {
        throw "An error occurred while running $($MyInvocation.MyCommand): $_"
    } finally {
        Log-Info "Completed $($MyInvocation.MyCommand)"
    }
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCcvudH1gxHDqOD
# 5hOungVUEAtKTweKFwyqASNbHqSlR6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIEekbXWJ
# IS65rzMdjWGBtnS1gGrDcEjAEjk23qkjIFfyMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAN4MeVhkkyFWqRct89PST4YBZ1Im3f0d6y4buQaX/
# nuACfbRrYqNSpVfmAu44M19PhJY7CVPy9Vp9q4QPj0XpL19HtFYLZPTelgFc3pBE
# 31qYvNGvIv0UMRwKYwmYteAy8sM3DSm2xJZu/hhAM4qVSkxqUjlBdKePFzvn8QCh
# lkIzN0bgrWTvb2kODThvQ2/rzgE+qZPBjF+2v6rQhTx3SR7LbgQjPhiUW1tTs1gP
# adl+TfEy22Tbdw1QN+SWuq80hox8gP/NHrhkrMj3TUob2mxbY8KDIezOK8n3Ha/d
# kj+gMTsEYbfulj6T7MPAq/1aEFNzC/dInEfV+He+LLnSx6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAytr8AhTxZmrAybwmL+cHH6lk/X3dJltrg3C/O
# ycciNQIGaedvdqK9GBMyMDI2MDUwMzE0MzExMC4zNjlaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTkzNS0wM0UwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAifVwIPDsS5XLQABAAAC
# JzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMDRaFw0yNzA1MTcxOTQwMDRaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0Uw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDixWy1fDOSL4qj3A1pady+elID
# LwnF3UuLzJIOWwGHcEgrxxwtnyviUIDmmxylTUl1u+2rBPp2zT4BwwQhvGaJpExq
# vPLlDFlbfmSflKI86eFqofiZ7j8NTRO4l7wGg9Njm+muNauTcFW2qdfIjKE950Ok
# rm9MnMOGYy+fibNYdxTPRPq1T4MLZK3s3vdMyMEOldcOQkSKpxD6/1Gk6gOmCu2K
# gI8f0ex6vYxnKDl9W0OLSEa/6y82oIbsm+1QBifOQ47xWKTG1CmvtGr85LzA75/M
# AcUmRw5/of/qET0UFV1WulMcJrI6DASAsNCNB+6WLrotuBZAj+VMlqbn5RMZ6Q4I
# Y7JwaAiIXh7VjxrnwUOYZG8WEGhfrA98di+7LEn9AqvvEOyG+UQcjVhCCbMGXigJ
# XSApeyeWupCsD0jgQMNCxfB5BLBDWxgdY3dJBEPgxfkgTDQLBggtVv2d5CYxHKgI
# ItB4bI5eSb5jkIG2WotnFetT0legpw/Eozwf39ao6tENY21eVWIzRw/GsmvwjYQF
# 6vVrxOD0pGVsfqGF8s3VPeY7hI2TxHFMqNA0IB/a2NLY7JTxYAKAP/11EJZt7xbq
# DLMgD1YDdGEzGpQijm3nAPCL2CebP/jmu90abJ2W425yglGHTI/nCBrwSpfRCgwz
# rfFelJaCKM6+35aFfwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNLW58N4MGSG6ud7
# jWqgT92orfReMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQAqncud4PSC1teb2H6n
# Ruy7sDiKK13FXJirVB4Tfwjdo2Mb+QL4j7wZ/k4G9P0CANHZFrDQcK0VFDTysrYu
# 8Z0Aha14acDZPsyIoPvAGRRhaHEuf7NckRjkfa/ylo1KyII8jbL9N9sJAqBPL8V4
# FNBjljv+1GHDOw127rZz5ZSTPoAPb2SA0v5yDgcpUMfxglPyp6cnPPoQpTtD9OGx
# 8Dwm2P+o1TPxBIy6I0T9RauulogVCvKwflfeLTcKAvnSG1rCjerSXmU1DNXOsAD/
# bsrSjgbX5mAbD7XTRMF/vawAWESFcn/BjjizxeWZb00aYSlkJA2rVtFlMM481aVW
# XdAbXPP5RzUiWTlgyHf/G7lCxHYWGIZuB13T3aI6Y8mEgn/ou40aiFJo8r0+i0P5
# GdNneWtxiR0CMKUfko+5s/73cwe1Wfp8BKXa270cicVQasFf5sRV7pFm+V7fNRXw
# Cu7anTOmga76zO7/2t+zOlibvphT+Q6Zd+B2qYsSn4xBaY+YzHpnycLW5cvJyhPx
# BCcb1oRYfhRzCADb2utI2EtGCjc2P2ii4LyR4QMb/n8cOweL9IqVTKKzzVk+zZJx
# V3vrp4LyuQXw0O30la6BcHdNAAAB9UC83zs3G9d+AlIfZLM97tMUNKWjbBpIirFx
# 6LTDFXVtZQd7hqzLYByjbjH0ujCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE5MzUtMDNFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQAjHzqthPwO0GDckDMA6x54lIiMKqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aG+ETAiGA8y
# MDI2MDUwMzEyMjkwNVoYDzIwMjYwNTA0MTIyOTA1WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtob4RAgEAMAoCAQACAhHHAgH/MAcCAQACAhJmMAoCBQDtow+RAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAFGbUwzct+j2e0eG7zQRj621h1cc
# Buzp0Dsw9coQXFkdOl8+cQPgLysQFDphSjN7k/DsSDEAidoGeihSu0Rc62iZEgeS
# dyEgBKrIwSis8k+5lJ54JMLSBgosFKYzsHGkHxIylob7DNTDjGpgB2fMXePaYzOF
# ZOEWg50IJ51zxb7mf+wZTJ/ADFIBBWb89BYkVUomn7jWyeLD5/84hG6Y3AoIkpAg
# h+nnTBZH+WSUR1j6it6UmyhZxYcRLAhxeZ/Acjda3ItjOZ/NXsu00SJay6F9aYHJ
# 5JIAYgHnqNzBSfYdx927cLQA4F0lGeJ/33lB5h9WW+bZThKnnklFwi/3C2gxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAifV
# wIPDsS5XLQABAAACJzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCXtCMEloyRf/yjjLHlOCQWCoHT
# q92ixvFeOD2nWYgAjTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIOXnARo1
# oVIcOLJKDqlE0adq/jZ9TXdlnXWRcXGThBFyMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIn1cCDw7EuVy0AAQAAAicwIgQgRYJqvbEs
# r04Oo+JUzKEPgrDA4S5x0iC3AdGRSnJxTHwwDQYJKoZIhvcNAQELBQAEggIAoBg4
# 4ai/chVutFEJSMCR1iuFkuJDe9WV644WCUi7bt66P5/aWlUOMMmwpgeHZhhmV8SV
# 9KPHWaxtxzhMLFA93+hJpicUM0R+nYQ3f6uVZTQ6L2mXW9ufhJ106tr6oTXrpgdz
# lDhU9IAcybDiqLYLiBFcEXYaZ3bHnDNagOnSJ2yr/U6lPp0lOf2FhbCcIQ48wuJN
# 9fRNOGf2agUSkxK3WrOeI7dEwVBG9vz2nrYpVM88R91GVFLZxIsDH/D8q1wBOh2r
# 9GBAVTJ3eQ44JSZRwImz3RwiSHFwnAYeecm7fPLoDmXP+xBDsplHh2e5hOupQBX0
# ELW/F8YQ4vvGK/PoZlfbMIuFAEHlyD3WXgiFvsUgjwbg+ZdwJI558pG27jBu1d/v
# izU8c+ugzQ/jq51g6pvkpfBkn2XergxzG0TIC5B365+7BbfWB7oBqGkliNqFYobt
# Eq4kntPYPO/m63uzViKX5aYbgTNQAJxl8MhLN0lZ3l9J59bnvdnYJmnwIwd6Olt3
# ZffoF3zkdBgdiP9TgfG2IJ1L4lM8ih/hmDWg0FRxSD2mah5/UIFB+7aUO0HOhBrm
# okcg4AI0/fBOyPK6MGavYqmKsSF+sioMt60kn3GNJGpT3Uze1eOni3FTv3y7NSzC
# UAF7kL8AMTYBcWChExMnIr8x56hUXzdxJupRDBA=
# SIG # End signature block
