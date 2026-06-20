<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
$MetaData = @{
    "OperationType" =  @("Deployment", "Upgrade", "AddNode")
    "UIName" = 'Azure Stack HCI Software'
    "UIDescription" = 'Check Operating System requirements'
}
function Test-AzStackHciSoftware
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Parameters,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
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
        Import-Module Microsoft.PowerShell.LocalAccounts -Verbose:$false

        # Import Module via Helper in case this is update
        [EnvironmentValidator]::EnvironmentValidatorImport($Parameters)
        $ENV:EnvChkrOp = $OperationType
        if ($OperationType -eq 'Deployment')
        {
            [array]$SoftwareResult
            $PsSession = [EnvironmentValidator]::NewPsSessionAllHosts($Parameters)
            $Params = @{
                PsSession = $PsSession
                OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                HardwareClass = $HardwareClass
                ClusterPattern = $ClusterPattern
                Exclude = @('Test-IsNotPartofDomain')
                PassThru = $true
            }
            # if part of domain only run ntp check
            # at this point OS has been validated, localgroup enumeration is not needed but ntp has just changed
            if ((Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain)
            {
               # remove Exclude from Params hashtable
               $Params.Remove('Exclude')
               $Params.Include += @('Test-NTPServer')
            }

            Trace-Execution "Starting Software validation, detail output can be found in $($outputPath)\AzStackHciEnvironmentChecker*"
            $SoftwareResult = AzStackHci.EnvironmentChecker\Invoke-AzStackHciSoftwareValidation @Params
        }
        elseif ($OperationType -eq 'Upgrade')
        {
            $Params = @{
                OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                HardwareClass = $HardwareClass
                ClusterPattern = $ClusterPattern
                PassThru = $true
            }
            $SoftwareResult = AzStackHci.EnvironmentChecker\Invoke-AzStackHciSoftwareValidation @Params
        }
        elseif ($OperationType -eq 'AddNode')
        {
            # for add node, get PsSession to localhost and the node being added
            $AddNodeNode = [EnvironmentValidator]::GetNodeContext($Parameters)
            $PsSession =  [EnvironmentValidator]::NewPsSessionByHost($Parameters, $AddNodeNode, $true)
            $params = @{
                PsSession = $PsSession
                PassThru = $true
                OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                HardwareClass = $HardwareClass
                ClusterPattern = $ClusterPattern
                Exclude = @('Test-IsNotPartofDomain')
            }
            $SoftwareResult = AzStackHci.EnvironmentChecker\Invoke-AzStackHciSoftwareValidation @Params
        }
        else
        {
            Trace-Execution "No interface found for $OperationType"
        }

        # Parse Software Result
        # Check if the ParseResult method supports the Parameters
        if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
        {
            Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
            return [EnvironmentValidator]::ParseResult($SoftwareResult, 'Software', $FailFast, $Parameters)
        }
        else
        {
            Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
            return [EnvironmentValidator]::ParseResult($SoftwareResult, 'Software', $FailFast)
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

Export-ModuleMember -Function Test-AzStackHciSoftware -Variable MetaData
# SIG # Begin signature block
# MIIncAYJKoZIhvcNAQcCoIInYTCCJ10CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCACULt0dos8OWYs
# lyjyRtm+IemHtt6V2DOsKPJPuvw3naCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn9MIIZ+QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIPo1sxvReIMoFxPUR/yjWCkBjI7oY3aNauFPBkVY+wS9MEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAn2m72HV6xVDWQZ2yxYXh
# Z6QYhCWWqTiD6F8xHJdc1gNLPCfiDrwUvf9l8s8NaZN5yM12NFnaEVskDlu4WSXZ
# CGt4CuiJ4zSyV5npWJOsWmSzCA3cAKJ/Ii65K3BpNWzKk1w4AOAqdeS58Vn7ULfZ
# 5zeMNrmWynWq1294QgESjd1zFtOamloQB8P82gL+FlICj/YH/ybsETApNbv4KHUL
# IHTakmSR1UxiB1edks7wPKk/UgHrAAACZp6lJ6/0rAALnM/nf0MYdaIyyflAlVhn
# jQUmkOdhHOn2qZ2bR19RaPHjDfsZFZ6QpbVPm9aGkNf5KRhrMAbWm9UudRkKHHIB
# haGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cGCSqGSIb3DQEHAqCCF4gwgheE
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0BCRABBKCCAUgEggFEMIIB
# QAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAQP9HSQynh5Ow4Vcrx
# XGNN/MAFWuOPlxcTRUi+bFs7cQIGaexb5pqSGBIyMDI2MDUwMzE0MzEyMC43OVow
# BIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR/jCCBygwggUQoAMC
# AQICEzMAAAIb0LK4Amf3cs8AAQAAAhswDQYJKoZIhvcNAQELBQAwfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0MTg0ODMwWhcNMjYxMTEzMTg0
# ODMwWjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsG
# A1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046NTUxQS0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCOxZ3nZlmTMHld7mD+XYaw6MDPfSyDqNXF8UlX7DjEgNXJojcs
# 7xsimbNi6XcBkeDnRQhDw+tJFkalCoWRE276jdgoniDa4ZgFGSwecdhHS5VIJCDn
# xOGRjJ6mUZfegC8ZFW48ilC0CJOxHvoD+B2hTscPARtvvdsnBPKtsoeFH5ZozL0N
# AcjiTlCjj5tkOzSSPvpu+Em90ZT5LzPFAGntQCGMmcWorEi6xIhMTvMIJHjbYQuG
# SFVU4WorbDqHUwC8gt7vqHFEhw+PRIEvavw723HmeNTj62DasB1TXnembKGprN2l
# RxxgET3ANEVR3970KhbHtN2dSJwH4xqLtFPqqx7t7loapfUHtueP9ke+ut8X4EkQ
# iVL2INcBSB6S9dn4VmaO8vA/5037T9yuH76vh7wWScXsRfogl+eY14M3/rxnn2Rt
# onV/4/macph/J0J5mbGsalLS1paQOTfoPeM9Vl+W/Gtz7WuEIiUzm/1qAsQUjXZC
# IFN+k4E4GvcAYI+T54fT6Vq2NBqO6D7b8EPXapvzbnTQtDK1RZPai1r8didGBK/W
# O9nT92aXUWzFZjM6cKuN90H/s3qk3JK3i+f48Y3p0UuKbuTGiz4H1Z9A97MmLd+4
# rLIMAH3NIc+PVm7ydl95xkn26bjOPsMWC8ldMNOcbmqUbhl1sVFr+ut/OQIDAQAB
# o4IBSTCCAUUwHQYDVR0OBBYEFLa+n3f+XEumk0rw6Rq4nYC82YhQMB8GA1UdIwQY
# MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYB
# BQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB
# /wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQBmRTVfFAPg5MzcZOG3fZNdKEh88Ggx9KwWwFCoU5mo
# sk7HIk6WUgEWmam860Y0+QLlnyV0bxoKm+AU2j+MNZ5PkWJbnd0CP0qdnGmxDc9/
# l9HNIYdFzEQw51chXMMnBxlRfRyN/GdrvJ02/x5cH9eTobpLKtHY4fpLUscxbXWb
# dS8oX54uMg+XjmvGKa4MKgR35p3SU4BcDn+9k4o3mf949h4/QtFyFlfRDofyf9mZ
# I8yVuWLcw7znVDT1GZP9kYdr78V3L5YsOvBxjKRX2ZTL/hNvArDoW11Hpk8fEx0i
# LWmTxjaYL8bMKrQsKwfS5MV5DpDs1zcxGYRH/eYtZSFtpYeBfUVthyG9HbZv4G6n
# 5g9HlD/QGFpoA3oAgF9waz67+cmggHLJkoDxxPIKadQj/i9boPi/LCDdcEV/h/YP
# AUfL96+wL7nwoyX6TbBrTlfaQrRP9sI8uFqi/1lfKhtrB804tgaJq4pPYVa9vBnM
# cgUJPGMHDDo+3m5G8IT+OdRx//GGU4YyfqIo71e3j29lMTZJ8gGT/fiItNEEnoft
# oY9NNCfNrc59a7X91HJwLpaXmiezc+OcZdNIpLFeWUk+aDpH+6Uaic/9QJignqY3
# 4ReN/IMs9cuqyv3X5VMbWtjNEKM/AEUAe/gQjBoTRqMKt/vl5QYjf6hdTRQ/quWh
# nzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM
# 57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm
# 95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzB
# RMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBb
# fowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCO
# Mcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYw
# XE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW
# /aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/w
# EPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
# Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2
# BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfH
# CBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYB
# BAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8v
# BO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEF
# BQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBW
# BgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
# AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# L2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518Jx
# Nj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+
# iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2
# pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefw
# C2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7
# T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFO
# Ry3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhL
# mm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3L
# wUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
# m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNZMIICQQIB
# ATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoD
# FQCGhXqvj0zgYF3jUrVFgHVnR/jO4KCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFl1jAiGA8yMDI2MDUwMzA2
# MTIzOFoYDzIwMjYwNTA0MDYxMjM4WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDt
# oWXWAgEAMAoCAQACAgL1AgH/MAcCAQACAhNwMAoCBQDtordWAgEAMDYGCisGAQQB
# hFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAw
# DQYJKoZIhvcNAQELBQADggEBAGkYMsbBisB82G8v30UIVBpEKYpoSYpkMoKTgkGk
# JD+k1VMgIJ0vjnhBkxaQyYtJrySpEZi5HXBTfiDE31XA3qW3L3snLCrrio9W3KUM
# RK3NenDyb6El18J3by2V1nmnZ/mZECDaAYKII/cNVOe3PPFdLrFOA5tFq5ih73E2
# MyizH32HZJjW2BgrgAX30jtQRrtqMRJ0aTxLkY03Ki8KIata5NFsjaEKvKsxbDFl
# RB3ssAEyAtL1/ShXKuELn90PotcVe7O+ujmSgj2hP5FGMSkTZE7RwglFLAoRe3II
# owGEbnVeXbpBTuU5+KvcHhWuWcOm+ZKLjwf7PwkB8grFsBsxggQNMIIECQIBATCB
# kzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAhvQsrgCZ/dyzwAB
# AAACGzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJ
# EAEEMC8GCSqGSIb3DQEJBDEiBCAHwKUltp7lwvwGe5I4d8CuPYkgQUtIOtMBq4cw
# BWWJBjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIDAlFJW4PaOYxxAIVd0u
# 4kDAOlRU1nptzp18lTzdDYuAMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAIb0LK4Amf3cs8AAQAAAhswIgQgmkskmtMKKjrQ05LWi/d2
# 2M3KUn7kORMqL+vObqCwgxAwDQYJKoZIhvcNAQELBQAEggIAO+6Yy3o0skAgo/M1
# 7n1n7HGGDUd4B7/asP+M54vu3ntWZt04L5POfEsyD9z1/KKpOLIJP/xK3XG6RJDw
# mSCzofJ873m2Yb4t9tvpFm9uvqy90i3uupU+1qtvLWaWuX8AWE61BRWIpmSVf9g1
# DK6aowo1KY6Uq51AvB/NLZyB9Wy8ouAqnNIB+i6f3dYG4tg1HmLidgCLbKZu49G0
# OOYdz6I/oFxeZtHNKgb2s2Hs2lp+dFu7v8l6n/VNrBbdb3w1u/4n4g/p4tiUjCre
# 69f4p6rn3G3NhNSUIf/9+xuZU5isCsc1oFfAow/fhTeFfgj9yfBi8/Lcf+0g6JSq
# Y7zOA3LkNt/FRiFfn0kD8WUnWBdrcmtI/uVbwKbM/NV3z8fy8burvYupTV/zG9ak
# yp5x4KMN7sclr5Bu8nxH0rSZWO4IL4/zACf8bpHTBlAqk1SoHsYzF8JnvsI+3lgy
# uKDEakfBWZnsi4CojThsAeqq1PB26s2M4kCxy0AWXOxmgWVA+Tv2nTSXthSQ8M46
# 2s+lmcayNjINc96IYBvHyEgZ6DGojL6/nlLiZGJ0hpK0I8aZoZx9NAoj88Ld8psB
# 1NvGU2pfcIEUi5yINrt50T0YsCIoGUbUtAQTdOuJmMCa3ic9gf7b4zTlrx199NfO
# ZguGNVFNN/6n52/ySDZo3eyxFgU=
# SIG # End signature block
