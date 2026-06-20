<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
$MetaData = @{
    "OperationType" =  @("Deployment", "Upgrade", "AddNode")
    "UIName" = 'Azure Stack HCI MOCStack'
    "UIDescription" = 'Check MOC Stack requirements'
}
function Test-AzStackHciMOCStack
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters,

        [parameter(Mandatory = $true)]
        [ValidateSet('Deployment', 'Upgrade', 'PreUpdate', 'AddNode')]
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
    try
    {
        $backupPSModuleAutoLoadingPreference = $PSModuleAutoLoadingPreference
        # Disable module auto-loading and explicitly import modules needed.
        $PSModuleAutoLoadingPreference = [System.Management.Automation.PSModuleAutoLoadingPreference]::None
        Import-Module Microsoft.PowerShell.Utility -Verbose:$false
        Import-Module Microsoft.PowerShell.Management -Verbose:$false
        Import-Module FailoverClusters -Verbose:$false
        Import-Module CimCmdlets -Verbose:$false
        Import-Module Storage -Verbose:$false
        Import-Module NetTCPIP -Verbose:$false

        # Import Module via Helper in case this is update
        [EnvironmentValidator]::EnvironmentValidatorImport($Parameters)
        $ENV:EnvChkrOp = $OperationType
        if ($OperationType -match 'Deployment|PreUpdate|Upgrade|AddNode')
        {
			[array]$MOCStackResult
            if ($OperationType -eq 'Upgrade')
            {
                # During upgrade ECE has insufficient details for remote sessions
                # Make local session to this node
                $PsSession = New-PsSession
            }
            elseif ($OperationType -eq 'AddNode')
            {
                # for add node, get PsSession to localhost and the node being added
                $AddNodeNode = [EnvironmentValidator]::GetNodeContext($Parameters)
                $PsSession =  [EnvironmentValidator]::NewPsSessionByHost($Parameters, $AddNodeNode, $true)
            }
            else
            {
                $PsSession = [EnvironmentValidator]::NewPsSessionAllHosts($Parameters)
            }

            $params = @{
                PsSession = $PsSession
                OperationType = $OperationType
                PassThru = $true
                OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                HardwareClass = $HardwareClass
                ClusterPattern = $ClusterPattern
            }

            if ((Get-WmiObject -Class Win32_ComputerSystem).Model -eq "Virtual Machine")
            {
                Trace-Execution "Test-MOCStackCPUCore is skipped for virtual Azure Stack HCI environments."
                $params += @{
                    Exclude = 'Test-MOCStackCPUCore'
                }
            }

            $RegistrationCloudName = $Parameters.Roles["Cloud"].PublicConfiguration.PublicInfo.RegistrationCloudName
            if ($RegistrationCloudName -ieq 'Azure.local')
            {
                $params += @{
                    RegionName = 'AzureLocal'
                }
            }
            else
            {
                $cloudRole = $Parameters.Roles["Cloud"].PublicConfiguration
                $params += @{
                    RegionName = $cloudRole.PublicInfo.RegistrationRegion
                }
            }

			Trace-Execution "Starting MOCStack validation, detail output can be found in $($outputPath)\AzStackHciEnvironmentChecker*"
			$MOCStackResult = AzStackHci.EnvironmentChecker\Invoke-AzStackHciMOCStackValidation @params


            <# Example for CI supress MOCStack exception
            if (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\SQMClient -Name IsCIEnv -ErrorAction SilentlyContinue)
            {
                Trace-Execution "CI Environment. Suppress MOCStack volume"
                $MOCStackResult | Where-Object Name -eq 'AzStackHci_MOCStack_Volume' | Add-Member -NotePropertyName Severity -NotePropertyValue 'WARNING' -Force
            }#>

			# Parse MOCStack Result
            # Check if the ParseResult method supports the Parameters
            if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
            {
                Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
                return [EnvironmentValidator]::ParseResult($MOCStackResult, 'MOCStack', $FailFast, $Parameters)
            }
            else
            {
                Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
                return [EnvironmentValidator]::ParseResult($MOCStackResult, 'MOCStack', $FailFast)
            }
        }
        else
        {
            Trace-Execution "No interface found for $OperationType"
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
        if ($PsSession)
        {
            $PsSession | Microsoft.PowerShell.Core\Remove-PSSession
        }
    }
}

Export-ModuleMember -Function Test-AzStackHciMOCStack -Variable MetaData
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDGDsYZpD33AyWD
# F/C4zB0VOCy+Zver+XJC/Anp/uviu6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPI4ly/A
# ++KmeFrxbkaexUfm+iLSNWKtLwd1ZF3Eu7nBMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAv3Ao8trWbkIOaqcvJNbZL+4mpJoPAweDbw7MZQc5
# q/Qe66tecpW0z7I9YR7o9jBindKbSHRxyhObnToayezMpCdAjlnu+C86oayponlT
# zPq+uAp4Dif4tpPju5yV9b3T6pMXSyO9hXdR9h1PcI5RATi5szYiCS5mbSXDInqz
# qd5uQUpXmwTTSKi3f4Cg/bEErZKCQ8kCAX3uvPyYL4w/fFDbv+irZTp1NFGkYyEE
# pIwyr+Kp3n1T9c/87Rr3/6w+uIiEpG2A0EsnXJMnLGR3Na0M8pau6prmUdvi+U/R
# S53i5dwjLpyX/X1zRD+fC7sQOgviV9KLjIS+43gFMvp0IqGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCARlW4ToRZq524tkPsuxTHlPEDuSecPUgIyQVkk
# GSjs7QIGaed8mPPyGBMyMDI2MDUwMzE0MzExMC4yNDNaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiWAxzfGzap3SQABAAAC
# JTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMDFaFw0yNzA1MTcxOTQwMDFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCm8RIP0eLA46VcCPovvmqsIlN6
# qkmz5IsHWmUU0neUqp8uGxadeo+SwWBCwQ5alZI/DNdpXfyiZLZR6XYgpRPFzepI
# l7OCDb4NtEskJCIZDkQMNwrH9YwUyu71GGigsLIxeleHtA3utoVTeHjS1b8UnwOR
# RtknKkyrUArT6ZpB2rodIcmcLcv3x3wwgYlOs0FEg5EsVrZb7LNc/nd0bXDp+HTO
# WWui8eoTVwJeLxcVP869oF8li5SU81aa2tGJ6/Jsejiz9JMW8SJXKBT2DCXMOUkC
# sGjonPZRqfvoMSIQZgtaOTyAJlrvsy0TZ78XrGqoygtQimQnbOAL4KNLSCuW5TZE
# QGTHLOQJGgggb3j5gKC778+RIPJA+n/hmHJ/x4qT/HTTPoVeMCcuBKWrQXR1+/pY
# au3Fwe0tWIyG+LWzkRr/ZNPPupcA2Yci3qn8HR9RwvQopqSNJwn2Ri6am8AQyfVV
# y/BBw0t6jpoRPjwKvuUjfCzpae6duOxQtQ1XDN9PA2yl9sDko/+AXV/SOe8ea8Qo
# Qcv3s3ErkG+Lp6hnvw6OMPian4ggNkRtgtB7ro1OiopOUXJn9Y5EO3JUAXNcuM9m
# +5My1VEuvGytgAH3uxmslTnW3YbrfazaySCSSnWkhaOZ33hgbuUQfH7n2NFEAUc/
# cFzfmCQUikWisnJYywIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFLE40qoXTuMHX3Af
# ZUu1n8nx2h93MB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQAHnfc2yUyoHZbvvyVK
# FuXh5HxxHIvIaR9JWpIfITJlc/Ki03juR+vckzq3tp5fFH5LL7eIFXRIuoewMsvW
# eFrWufrrW4HhmhCwkqArfA1C0xk+HaYs2O48YSxMX9lgS1kTTIb3YsfoFdFpKurP
# f2nc2Yd4wLg+FgwmkxkeyE3MUKVna8SZeVpEjnS5ucFck4srPwK2ORAf70I23GGy
# PhqgIKZphNXhSscTAQsyIqB5GwDMdRV5LK37NfU4YmxvCYh3TFYE/Gh01Q6yJvf9
# HxiEZpwW+oUk0gruHobg3sgIR5rfgUo8l30vUnaDYMcPAClaFMC/QbHZSaUhWXZG
# 1OOcMp0g9vYQNLDEqFX2jlquvzVSSwtHtm1KTldCjRED+kdCybcPxbPalwJigXc1
# BsI9CitnTf0ljwb9NkZ/JVI8/D62rXXzhz4F3u0iVGzwncGaxRxHG/Xv4nTrpkOe
# epoYbNBbMWS2G1qP3Xj7pVf0+4qRyAqJ0stjQjoVOJImVPWRjz5PR3Dn6adQVMBJ
# DM6gDrj1rZTFVgCtTijqGZSGzvXpGkF3vYsyE6ZDma/kGdiUe5saeI6lH66PiWWX
# gqxt7sy2Ezv0yIjSVv+eMOT2QMUiZ6WCc7gVtAmXpfeIus+NmgFvM+Ic1X58e4I9
# EL4ZSAidSpWW0GZTLNC02mryLjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg2MDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQBTb+bKOPAjCBflhzw5EXBuSWxeDqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aHLODAiGA8y
# MDI2MDUwMzEzMjUxMloYDzIwMjYwNTA0MTMyNTEyWjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtocs4AgEAMAoCAQACAgkSAgH/MAcCAQACAhPHMAoCBQDtoxy4AgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAJV8kMndt1RaS2RHUeu9bTv3Ooq4
# sbCHczveImmDaZD+9+5yDMK1aidKHx38eLL6OhoR6wOP5qVwJPtP+1vjgrzudRM2
# cYOfXx/mK6i0OAJhoHSi+zl3+ZvDfaFjkILB2GVwxapBD5pwSYhmZq2OBuNNCc84
# HylnTF24l0zhrn3np+buejMVsjljsyKbS2rT+WwxwzwwMVDkwyFzsV6zDjj5d156
# mVbKefzLvVlVu/gE034l9o+piJbyDU8g819ygwR+W4CkYPqR7HRz+Unboa4CFhQ4
# F8fABmMet/ssAoLdTx4QBcHmemqrmgsujRbR82BUVKpJSFPK+w2LhDbea7cxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiWA
# xzfGzap3SQABAAACJTANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCHEvyJDp2bkRUPnWv6U3iw2P38
# f5t+cZ889VOou3k/GzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFYN7oh6
# ON3y92CmAl/lF0CYwrjWWQP6dCUxajPSHKEQMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIlgMc3xs2qd0kAAQAAAiUwIgQgOrqQiD8p
# rJMLOtfvraiqGafeCm8jnD39Hjc3g6/seDMwDQYJKoZIhvcNAQELBQAEggIAdURX
# f8UloinHCGUQTvjykWc9/ymctWcCJEJiDCcF2GzoY3e9RsoyIsrbgHM9WzZeCJmF
# 2BwtpF3aSHV7voN75OyyrE6Zjj5s7A0AzW1cOAvnKi9ztRwri8SQ1D3byZ7CLbxf
# qP0gCBCeG8JUSY+n8RlooBy9kL6yclm83c0+a4xDFuLHn91VLWoOFarGIL74he61
# J4xoJC1Q1q0toS1uirKwxqHkcLdptOR7WebQ4wI+dsBeialHqTCRDx3jHwGNi61A
# JyuullngkZlBkupZWKT2uan309ZjBIxFBEnySFRWokHWqvrbJCOmy6tdSuKBCmwD
# UFc7X9mjffjTPaji78YUn3gebJQDpoza0MIo0XqO0EB3YPB4Xg9Kf2UO0wk0RM3b
# E9kujr0dnvury8GamS3utahlWUHQM4SHCoDkzzxTMW3jy39UBAcNqwm+082MMpwl
# HwDTae/0qpRbkSDC1bArTtppjLXEF7EHnL/gVbb/qaBBtKeN4DkGDAAtFOPs7YvX
# 06vMAFWSyVADnuJUoyvuhijr2trZZgAg3SOUxUp1uXws0K95gvK00Re0wFQ7vQX/
# QJsaFtq1swJfOD15Puu2O0R/ubGWzY+CSj7fayAigcflgWZOzdQc/2pW9rcbtdro
# wkT/uWNWuLd4TgIXzJly7sem6jhlDsM6jcmjVfA=
# SIG # End signature block
