<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
 $MetaData = @{
    "OperationType" =  @("Deployment", "PreUpdate", "Upgrade","PreUpdateJIT")
    "UIName" = 'Azure Stack HCI ARC Integration Check'
    "UIDescription" = 'Check ARC Integration inputs meet requirements'
}
function Test-AzStackHciArcIntegration
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
        Import-Module Az.Accounts -Verbose:$false
        Import-Module Az.Resources -Verbose:$false

        # Import Module via Helper in case this is update
        [EnvironmentValidator]::EnvironmentValidatorImport($Parameters)
        $ENV:EnvChkrOp = $OperationType
        if (($OperationType -eq 'Deployment') -or ($OperationType -eq 'Upgrade') -or ($OperationType -eq 'PreUpdate'))
        {
            $nodeNames                      = $Parameters.Roles["BareMetal"].PublicConfiguration.Nodes.Node.Name
            $cloudRole                      = $Parameters.Roles["Cloud"].PublicConfiguration
            $securityInfo                   = $cloudRole.PublicInfo.SecurityInfo
            $EnvironmentName                = $cloudRole.PublicInfo.RegistrationCloudName
            $TenantId                       = $cloudRole.PublicInfo.RegistrationTenantId
            $ArcServerResourceGroupName     = $cloudRole.PublicInfo.RegistrationArcServerResourceGroupName
            $RegistrationResourceGroupName  = $cloudRole.PublicInfo.RegistrationResourceGroupName
            if([string]::IsNullOrEmpty($ArcServerResourceGroupName ))
            {
                $ArcServerResourceGroupName = $cloudRole.PublicInfo.RegistrationResourceGroupName
            }
            $PSSession = [EnvironmentValidator]::NewPsSessionAllHosts($Parameters)

            $TestParams = @{
                AzureEnvironment                = $cloudRole.PublicInfo.RegistrationCloudName
                TenantID                        = $cloudRole.PublicInfo.RegistrationTenantId
                SubscriptionID                  = $cloudRole.PublicInfo.RegistrationSubscriptionId
                RegistrationResourceGroupName   = $RegistrationResourceGroupName
                ArcResourceGroupName            = $ArcServerResourceGroupName
                NodeNames                       = $nodeNames
                PassThru                        = $true
                OutputPath                      = "$($env:LocalRootFolderPath)\MASLogs\"
                HardwareClass                   = $HardwareClass
                RegistrationResourceName        = $cloudRole.PublicInfo.RegistrationResourceName
                PsSession                       = $PSSession
            }

            if(-Not [string]::IsNullOrEmpty($cloudRole.PublicInfo.RegistrationRegion))
            {
                $TestParams += @{
                    Region = $cloudRole.PublicInfo.RegistrationRegion
                }
            }

            $cloudDeploymentNugetPath = Get-AsArtifactPath "Microsoft.AzureStack.Solution.Deploy.CloudDeployment"
            Import-Module "$cloudDeploymentNugetPath\content\Setup\Common\RegistrationHelpers.psm1" -Force
     	    $registrationParameterSet = $cloudRole.PublicInfo.RegistrationParameterSet
            if ($registrationParameterSet -eq "DefaultSet")
            {
                Trace-Execution "RegistrationParameterSet $registrationParameterSet, getting access tokens using user token cache"
                $registrationTokenCacheUser = $securityInfo.AADUsers.User | Where-Object Role -EQ 'RegistrationTokenCache'
                Trace-Execution "Registration token cache user is : $registrationTokenCacheUser"
                $registrationTokenCacheCred = $Parameters.GetCredential($registrationTokenCacheUser.Credential)
                $clientId = $cloudRole.PublicInfo.RegistrationClientId
                Trace-Execution "Using clientId $clientId to get access token"
                $armAccessToken     = Get-AccessToken -AzureEnvironment $EnvironmentName -TenantId $TenantId -TokenCacheCred $registrationTokenCacheCred -ClientId $clientId
                $AccountId           = $registrationTokenCacheCred.UserName
                $TestParams += @{
                    AccountId           = $AccountId
                    ArmAccessToken      = $armAccessToken.AccessToken
                }
            }
            else
            {
                $registrationSPUser = $securityInfo.AADUsers.User | ? Role -EQ $Parameters.Configuration.Role.PrivateInfo.Accounts.RegistrationSPID
                $registrationSPCred = $Parameters.GetCredential($registrationSPUser.Credential)
                Trace-Execution "RegistrationSPCred AppId $($registrationSPCred.UserName)"
                Login-AzAccount -Environment $EnvironmentName -Credential $registrationSPCred -Tenant $TenantId -ServicePrincipal | Out-Null
                $armAccessToken = Get-AzAccessToken -Verbose
                $TestParams += @{
                    AccountId           = $registrationSPCred.UserName
                    ArmAccessToken      = $armAccessToken.Token
                }
            }

            if (Get-Command Get-IdentifierForCloudDeployment -ErrorAction SilentlyContinue)
            {
                $deploymentType = Get-IdentifierForCloudDeployment
            }
            else
            {
                $deploymentType = $null
            }

            if ($OperationType -eq 'Deployment')
            {
                if ($null -ne $deploymentType -and $deploymentType -eq "CloudDeployment")
                {
                    Trace-Execution "Since this is cloud based deployment we are trying to skip the test : Test-ExistingArcResources"
                    $testsToExclude = @("Test-ExistingArcResources", "Test-ExistingHCIResource", "Test-AzureStackHCISubscriptionState")
                    $TestParams += @{
                        Exclude = $testsToExclude
                    }
                }
                else
                {
                    # Case where it's not cloud deployment
                    Trace-Execution "Since this is not cloud based deployment we are trying to skip the test :   Test-MandatoryRPRegistration"
                    $testsToExclude = @("Test-MandatoryRPRegistration")
                    $TestParams += @{
                        Exclude = $testsToExclude
                    }
                }
            }
            elseif (($OperationType -eq 'Upgrade') -or ($OperationType -eq 'PreUpdate'))
            {
                if ($null -ne $deploymentType -and $deploymentType -eq "CloudDeployment")
                {
                    Trace-Execution "Check Mandatory RP registration for Upgrade and PreUpdate for CloudDeployment"
                    # Exclude Test-AzureStackHCISubscriptionState for Azure.local environment
                    if ($TestParams.AzureEnvironment -eq "Azure.local")
                    {
                        Trace-Execution "Azure.local environment detected, excluding Test-AzureStackHCISubscriptionState"
                        $testsToInclude = @("Test-MandatoryRPRegistration")
                    }
                    else
                    {
                        $testsToInclude = @("Test-MandatoryRPRegistration", "Test-AzureStackHCISubscriptionState")
                    }
                    $TestParams += @{
                        Include = $testsToInclude
                    }
                }
                else
                {
                    # Case where it's not cloud deployment
                    Trace-Execution "Since this is not cloud based deployment we are not performing Test-MandatoryRPRegistration for Upgrade and PreUpdate"
                }
            }

            [array]$ArcIntegrationResult
            Trace-Execution "Starting ArcIntegration validation, detail output can be found in $($env:LocalRootFolderPath)\MASLogs\AzStackHciEnvironmentChecker*"
            $ArcIntegrationResult = AzStackHci.EnvironmentChecker\Invoke-AzStackHciArcIntegrationValidation @TestParams

            # Parse Result
            # Check if the ParseResult method supports the Parameters
            if ([EnvironmentValidator]::ParseResult.OverloadDefinitions -match 'EceInterfaceParameters')
            {
                Trace-Execution "ParseResult method supports EceInterfaceParameters argument"
                return [EnvironmentValidator]::ParseResult($ArcIntegrationResult, 'ArcIntegration', $FailFast, $Parameters)
            }
            else
            {
                Trace-Execution "ParseResult method does not support EceInterfaceParameters argument"
                return [EnvironmentValidator]::ParseResult($ArcIntegrationResult, 'ArcIntegration', $FailFast)
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
        if ($PSSession)
        {
            $PSSession | Microsoft.PowerShell.Core\Remove-PSSession
        }
    }
}

Export-ModuleMember -Function Test-AzStackHciArcIntegration -Variable MetaData
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDcqj0XiISNXg1d
# HqffbzidsZUOw7Q2MDyX+GXLJDoUh6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEILO3bPqpZW8ijbAjSvrzuUBWSCg0wEV3ujtElPHr24zwMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAu6wMmG34MixW4zowmsYg
# 2pI9h+83UxzIKgmj1ckWvuJjokg1Bu3DDLFnhHwsmCiPD91RqNoGOZtkcUOOiE/T
# bFy4I6OcJLuCXgJaEdeDBjIDjK/m/MSIfQ2WrG9b9NesWwD9GfRBs6BJxfMXv3Pr
# afNtOFGfWLrS96bfu5gMEslpq+lBBJkPrX+Ce4lLEq7VLi32GUKe9kQ6YW2F+TXO
# s5dP+0qCUj+3biR63BnCjHkL0t/7ay8f4LO5IvUI50iOvEVPrEUmBgLiROfqE9uI
# x6I0MN/X18JFiQMWA0DYnnaE89g48OmwQqYzFdUmF5GDnGk/xMtJ3xqBlnWoYcZ+
# WKGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBABzIuGjGrXBFKkNRd
# zPPP0AW8w1/+TrgbHrmEBX2ANAIGaeugEigOGBMyMDI2MDUwMzE0MzExMS4yMDZa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyQTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACEKvN5BYY7zmwAAEAAAIQMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxMloXDTI2MTExMzE4
# NDgxMlowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjJBMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAjcc4q057ZwIgpKu4pTXWLejvYEduRf+1mIpbiJEMFWWmU2xp
# ip+zK7xFxKGB1CclUXBU0/ZQZ6LG8H0gI7yvosrsPEI1DPB/XccGCvswKbAKckng
# OuGTEPGk7K/vEZa9h0Xt02b7m2n9MdIjkLrFl0pDriKyz0QHGpdh93X6+NApfE1T
# L24Vo0xkeoFGpL3rX9gXhIOF59EMnTd2o45FW/oxMgY9q0y0jGO0HrCLTCZr50e7
# TZRSNYAy2lyKbvKI2MKlN1wLzJvZbbc//L3s1q3J6KhS0KC2VNEImYdFgVkJej4z
# ZqHfScTbx9hjFgFpVkJl4xH5VJ8tyJdXE9+vU0k9AaT2QP1Zm3WQmXedSoLjjI7L
# WznuHwnoGIXLiJMQzPqKqRIFL3wzcrDrZeWgtAdBPbipglZ5CQns6Baj5Mb6a/EZ
# C9G3faJYK5QVHeE6eLoSEwp1dz5WurLXNPsp0VWplpl/FJb8jrRT/jOoHu85qRcd
# YpgByU9W7IWPdrthmyfqeAw0omVWN5JxcogYbLo2pANJHlsMdWnxIpN5YwHbGEPC
# uosBHPk2Xd9+E/pZPQUR6v+D85eEN5A/ZM/xiPpxa8dJZ87BpTvui7/2uflUMJf2
# Yc9ZLPgEdhQQo0LwMDSTDT48y3sV7Pdo+g5q+MqnJztN/6qt1cgUTe9u+ykCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBSe42+FrpdF2avbUhlk86BLSH5kejAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAvs4rO3oo8czOrxPqnnSEkUVq718QzlrIiy7/EW7J
# mQXsJoFxHWUF0Ux0PDyKFDRXPJVv29F7kpJkBJJmcQg5HQV7blUXIMWQ1qX0KdtF
# QXI/MRL77Z+pK5x1jX+tbRkA7a5Ft7vWuRoAEi02HpFH5m/Akh/dfsbx8wOpecJb
# YvuHuy4aG0/tGzOWFCxMMNhGAIJ4qdV87JnY/uMBmiodlm+Gz357XWW5tg3HrtNZ
# XuQ0tWUv26ud4nGKJo/oLZHP75p4Rpt7dMdYKUF9AuVFBwxYZYpvgk12tfK+/yOw
# q84/fjXVCdM83Qnawtbenbk/lnbc9KsZom+GnvA4itAMUpSXFWrcRkqdUQLN+JrG
# 6fPBoV8+D8U2Q2F4XkiCR6EU9JzYKwTuvL6t3nFuxnkLdNjbTg2/yv2j3WaDuCK5
# lSPgsndIiH6Bku2Ui3A0aUo6D9z9v+XEuBs9ioVJaOjf/z+Urqg7ESnxG0/T1dKc
# i7vLQ2XNgWFYO+/OlDjtGoma1ijX4m14N9qgrXTuWEGwgC7hhBgp3id/LAOf9BST
# WA5lBrilsEoexXBrOn/1wM3rjG0hIsxvF5/YOK78mVRGY6Y7zYJ+uXt4OTOFBwad
# Pv8MklreQZLPnQPtiwop4rlLUYaPCiD4YUqRNbLp8Sgyo9g0iAcZYznTuc+8Q8ZI
# rgwwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyQTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAOsyf2b6riPKnnXlIgIL2f53PUsKggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hUrgwIhgPMjAyNjA1MDMw
# NDUxMDRaGA8yMDI2MDUwNDA0NTEwNFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aFSuAIBADAKAgEAAgIP2wIB/zAHAgEAAgITyzAKAgUA7aKkOAIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQC8BD/jbO+hYI1cLwigLLq4vh+KzNiSSPNrYpjK
# 81EmkYyZs5aX5AMRAnKzZrP4zsNFkviAjAjcDcR62MFounzMKMdJW5L/Ak/LXwXt
# M34DfDJQcdZIA42apu7Gxus4gBy4l6dU2LN+j4ltCPCRJhdMPexSSf+OQbx8kO01
# Je3+DWhdgn9pdujhIj8ifSldthlXtNLStB9fWFll8TzvJx6wr8KKMuvcau4DRbnp
# b8VFIDpJYNDEwTAhl9aTGcKSTtPlNK0OXC56AgmwyMbDcy10gMlKbnqlX+/gE2Na
# W74yfYadFJ7YPleyZRz57qTs137kpL9OZd3T9tyb2gqNzRj0MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIQq83kFhjvObAA
# AQAAAhAwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgU05mswOzetjUeB16Gn6kojaN8eC2zi/1HFYR
# /rc6ii4wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDD1SHufsjzY59S1iHU
# QY9hnsKSrJPg5a9Mc4YnGmPHxjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEKvN5BYY7zmwAAEAAAIQMCIEIIT70NF/aOTBRnL/Ym5d
# CJI5L5fhiGpS2xzTAo0XyaBPMA0GCSqGSIb3DQEBCwUABIICAGzQTNvMdfjG/voB
# rCPnPHfouJPoen2mmq5lmIThbI3pAL3BV/sA6ADm8+/MKW6n3bIx8x0m6Mrxr3/b
# SUZf9POK/3igS00vs2+yliffLQf2ty7FXNJtXrWHnPaXIyMZBDwVr6JjFYR1C62S
# FXElvkp/rhbY+v0OOJYoodKGCjHjPkWZK6liQnxVoU2dlr5v4nmRbfosvxn5k5Vu
# 8YKx6pSy74OgBmRvKl4QqKSC9ocugesknr9cpZPOQ3oP6/b6LpKjW0TWnlxV6BxI
# Yw8tNewSiiBI4sq1wCnrwRipGZwCCJA+vFbYU8IN5kHLr9pLoIm90dRW4V1sZnwE
# nyfSa0TJ4Fo6q121c3lBa9kDg+YzYf+HXPmj7nfTtwIrgPODL49PnE7xES+WubUC
# D+3TKcbQZXWsyd1QMtEuBvTwQpAFs9zBogdVpN5baRh+JtaKmWfpp18ApHWjtnQj
# sr6yFHANLoh7MKCtmU1XfHdLaBuW+rWVqFhYZpnIkL4J1ZbuCGW5wn7hLhjnIHLY
# hmO30eobn9lx14Bc8Q3JgcJcGqZJKKI/D6oBW3dF8tnpg8KL477Wk0HUm+zL/c2t
# Jgyx3LfUOrLLlkYVMY7NOEqR7UwYn0ph6EOWaP8KH2rbigNpEf31/ucFUoZxzdiY
# Nk3SN/JBIImnqH2ZF0Wqo/5cdvzP
# SIG # End signature block
