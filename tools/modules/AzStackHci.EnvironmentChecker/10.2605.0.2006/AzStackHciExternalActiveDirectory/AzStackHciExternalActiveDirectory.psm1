<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-Module $PSScriptRoot\AzStackHci.ExternalActiveDirectory.Helpers.psm1 -DisableNameChecking -Global
Import-Module $PSScriptRoot\AzStackHci.ExternalActiveDirectory.Tests.psm1 -DisableNameChecking -Global
$MetaData = @{
    "OperationType" =  @("Deployment","Upgrade","PreUpdate","PreUpdateJIT")
    "UIName" = 'Azure Stack HCI External Active Directory'
    "UIDescription" = 'Check external active directory preparation'
}

function Test-AzStackHciExternalActiveDirectory
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
        Import-Module ActiveDirectory -Verbose:$false

        # Import Module via Helper in case this is update
        [EnvironmentValidator]::EnvironmentValidatorImport($Parameters)
        $ENV:EnvChkrOp = $OperationType
        # Active Directory Checks
        Trace-Execution "Gathering External Active Directory validation assets."
        $asHciClusterName = $Parameters.Roles["Cluster"].PublicConfiguration.Clusters.Node.Name
        $domainFQDN = $Parameters.Roles["Domain"].PublicConfiguration.PublicInfo.DomainConfiguration.FQDN
        $hciDeploymentPrefix = $Parameters.Roles["Cloud"].PublicConfiguration.PublicInfo.DeploymentPrefix
        $physicalMachineNames = $Parameters.Roles["BareMetal"].PublicConfiguration.Nodes.Node | ForEach-Object  {$_.Name}
        $hciOUName = $Parameters.Roles["Cloud"].PublicConfiguration.PublicInfo.ADOUPath
        $domainAdminCredential = [EnvironmentValidator]::GetDomainAdminCredential($Parameters)

        $storageRole = $Parameters.Roles["Storage"].PublicConfiguration
        $configurationMode = $storageRole.PublicInfo.StorageConfiguration.Name
        Trace-Execution "Configuration mode: $configurationMode"
        if ($configurationMode -eq "KeepStorage")
        {
                $ENV:EnvChkrOp = "DeploymentKeepStorage"
        }

        if ($OperationType -match 'Deployment')
        {

            if (![string]::IsNullOrEmpty($asHciClusterName) -and ![string]::IsNullOrEmpty($domainFQDN) -and ![string]::IsNullOrEmpty($hciDeploymentPrefix))
            {

                Trace-Execution "Starting External Active Directory validation. Detail output can be found in $($env:LocalRootFolderPath)\MASLogs\AzStackHciEnvironmentChecker*"

                Install-ActiveDirectoryModule
                Install-GroupPolicyModule
                $exAdParams = @{
                    ADOUPath = $hciOUName
                    DomainFQDN = $domainFQDN
                    NamingPrefix = $hciDeploymentPrefix
                    ClusterName = $asHciClusterName
                    ActiveDirectoryServer = $domainFQDN
                    ActiveDirectoryCredential = $domainAdminCredential
                    PassThru = $true
                    OutputPath = "$($env:LocalRootFolderPath)\MASLogs\"
                    HardwareClass = $HardwareClass
                    ClusterPattern = $ClusterPattern
                    PhysicalMachineNames = $physicalMachineNames
                    OperationType = $OperationType
                }

                [array]$ExtAdCheckResult = AzStackHci.EnvironmentChecker\Invoke-AzStackHciExternalActiveDirectoryValidation @exAdParams
            }
            else
            {
                Trace-Execution "asHciClusterName: $asHciClusterName, domainFQDN: $domainFQDN, hciDeploymentPrefix: $hciDeploymentPrefix"
                Trace-Execution "Skipping External Active Directory validation unable to parse neccessary information from answer file."
            }
        }
        elseif ($OperationType -match 'PreUpdate')
        {
            $cloudRole = $Parameters.Roles["Cloud"].PublicConfiguration
            $deployADLess = $cloudRole.PublicInfo.DeployADLess

            # Local Identity environments use local admin credentials for LcmUser. Skip AD check
            if ($deployADLess -ne "True")
            {
                Import-Module $PSScriptRoot\AzStackHci.ExternalActiveDirectory.Tests.psm1 -Force -DisableNameChecking -Global
                Trace-Execution "Starting External Active Directory validation checks before update."
                [array]$ExtAdCheckResult = Test-LcmUserCredentials -LcmUserCredentials $domainAdminCredential -DomainFQDN  $domainFQDN
            }
        }
        elseif ($OperationType -match 'Upgrade')
        {
            Import-Module $PSScriptRoot\AzStackHci.ExternalActiveDirectory.Tests.psm1 -Force -DisableNameChecking -Global
            Trace-Execution "Starting External Active Directory validation checks before upgrade."
            [array]$ExtAdCheckResult = Test-CauClusterRole -HciClusterName $asHciClusterName
        }
        else
        {
            Trace-Execution "No interface found for $OperationType"
        }

        # Check if the ParseResult method supports the Parameters
        if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
        {
            Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
            return [EnvironmentValidator]::ParseResult($ExtAdCheckResult, 'ExternalAD', $FailFast, $Parameters)
        }
        else
        {
            Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
            return [EnvironmentValidator]::ParseResult($ExtAdCheckResult, 'ExternalAD', $FailFast)
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
        # Remove any PSSession created during the validation.
        if ($PsSession)
        {
            $PsSession | Microsoft.PowerShell.Core\Remove-PSSession
        }
    }
}

Export-ModuleMember -Function Test-AzStackHciExternalActiveDirectory -Variable MetaData

# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCdBwi0RxDfsWav
# SgRZqbL8zvamWm5siF6ta5DmDjDi0aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIIocj12tO+qOwTK0NE35eqzXOGu0rbdI7Lt979x7BQ34MEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAwg4cqis3BJ5gT2fHUBAK
# h4q1DO6qQ/XHZ7h8OD5lQao546Kpt6DiApDulsvSSpLOftJnUSYAMGjAc4yKI4/B
# MQXzN5MORZ6CflYWFOSK3uVkANM4w7LtHN4cKCphYdDdSjQEYJTR0F61PL91x63E
# voNhG6rQzwhXYPHM45fDGX6SOIbvl+dhM0AdqaDsunelW0Cb0J0OqwJxpvZ3zhNv
# hUmB3Y9hOqWkNuV2OayWkyGQS0QIjg9+0b54+G6hjZx18iHmI72JzlJVCOaNhKEJ
# e37Ytd8V9hM/LDYgbKvRKh9ncOfmpVOcPMiZ1MRXPMbULe62nNtj/N+NwtAtJFKB
# h6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDn0RP/+qN9rLyCwKgW
# u+wAD3FX0FvONmDNTs9lsG3nCAIGaeuJ1G3DGBMyMDI2MDUwMzE0MzExMC40MjZa
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
# CRABBDAvBgkqhkiG9w0BCQQxIgQgtU+mIobKmggHJa9nJ3ra0vJBi/R2kfyQYzIw
# IrIeabUwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBz+X5GvO7WngknH4BZ
# eYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIEIH62C3OysJpL+INwkKSZ
# fhuOdJ2Sj9gOYyp366y/mz5vMA0GCSqGSIb3DQEBCwUABIICAJd+BjXV83U5Wqhi
# yABuWpGXGOsgYFNjKjyPZ5yEXIvr75h1+PBZzpPJJCav1DZMJ/OR9T0NZer8GWri
# rWtwBkkA3ycd+SAZoS0I3ARK8+Y7VRtp53b/gw9+a8XZlHKrjDWQstmSO5n1Nwa8
# 5hmyzwizprEeD0shTepHxlSXa2Nd2VaY3cD1NPmsCA+IYcMg3PcV0iKj5PISimPk
# 2o9/A4ar1DHIXi17Xq+d1rvRlNhJP0QEXMac1b0WhTulCT4AlGpPGdjCJ8exTmkn
# 31Xbr3if1qtACJByMyVVO2DQl3K84MforeJS/IUR8c/aYwHo35N6Q5bbZE/2unVC
# v1n69ZmLBVLUjWZ7wQPkXdvbbUATxWez3WVQyIyJ2k5f7EebQMHHtgZzf9VUbTMJ
# gRhaStCWQtHx8vKt2AgIbZTmqPXdoesi46EMnNab0nrDhxdIQJ+t+7NOyqzRj0OL
# zoDdBAguFBZ6WWt+cueZpVTKWq/Q/zGPPFQXNCadoYfZXnv8iq64LKf7ZK/iMxwX
# 2yC+ZJfJ1Oyxt8KubN7OXtgv9Qp/5YWoyX1nPG+VP3mWh+37WGtubzcRwfGxtcT0
# ZFqrw3Z/3QArp0Dchpf5fDJpT7u/Ajuj42WjiIiV04MnuVlwAfZLjdjW6Uz3Qaux
# 3GU4FYUvJXcTGDDpJlJrej5hpvt5
# SIG # End signature block
