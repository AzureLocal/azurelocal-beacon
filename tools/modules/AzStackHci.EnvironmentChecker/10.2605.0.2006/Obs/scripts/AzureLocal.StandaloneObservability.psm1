<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

<#
.SYNOPSIS
    Sends diagnostics data using standalone observability pipeline.

.DESCRIPTION
    Sends diagnostics data using standalone observability pipeline.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Send-AzureLocalDiagnosticData

.PARAMETER ResourceGroupName
    Azure Resource group name where temporary Arc resource will be created. This can be same parameter as used in AzS Deployment.

.PARAMETER SubscriptionId
    Azure SubscriptionID where temporary Arc resource will be created. This can be same parameter as used in AzS Deployment.

.PARAMETER RegistrationRegion
    Optional. Azure registration region where Arc resource will be created. This can be same parameter as used in AzS Deployment.

.PARAMETER DiagnosticLogPath
    Diagnostic Log path which will be parsed and sent to Microsoft.

.PARAMETER Cloud
    Optional. Azure Cloud name default: AzureCloud.

.PARAMETER CacheFlushWaitTimeInSec
    Optional wait time to Flush the cache folder. default:600

.PARAMETER RegistrationCredential
    Azure credentials used for authentication to register ArcAgent. Needed only for DefaultSet

.PARAMETER RegistrationWithDeviceCode
    This is RegistrationWithDeviceCode switch to use device code for authentication.

.PARAMETER RegistrationWithExistingContext
    This is RegistrationWithExistingContext switch to use existing Azure context on the local machine.

.PARAMETER RegistrationSPCredential
    This is SPN crednetials used for authentication to register ArcAgent. Needed only for ServicePrincipal set

.EXAMPLE
    The example below .

    During Remote Support JEA configuration, WinRM will be restarted twice and that can break the PsSession to node if you are installing Remote Support remotely. In that case, connect to remote node again and execute Enable cmdlet again after 4-5 minutes.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Send-AzureLocalDiagnosticData

    Processing data from remote server v-host1 failed with the following error message: The I/O operation has been aborted because of either a thread exit or an application request. For more information, see the about_Remote_Troubleshooting Help topic.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Send-AzureLocalDiagnosticData

.NOTES
    Requires Support VM to have stable internet connectivity.
#>

function Send-AzureLocalDiagnosticData
{
    [CmdletBinding(PositionalBinding = $false, DefaultParameterSetName = "Interactive")]
    param(
        [Parameter(Mandatory = $true)]
        [System.String] $ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [System.String] $SubscriptionId,

        [Parameter(Mandatory = $true, ParameterSetName = "DefaultSet")]
        [PSCredential] $RegistrationCredential,

        [Parameter(Mandatory = $true, ParameterSetName = "Interactive")]
        [Switch] $RegistrationWithDeviceCode,

        [Parameter(Mandatory = $true, ParameterSetName = "PassThrough")]
        [Switch] $RegistrationWithExistingContext,

        [Parameter(Mandatory = $true, ParameterSetName = "ServicePrincipal")]
        [PSCredential] $RegistrationSPCredential,

        [Parameter(Mandatory = $true, ParameterSetName = "AccessToken")]
        [System.String] $AccessToken,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path -Path $_ -PathType Container })]
        [System.String] $DiagnosticLogPath,

        [Parameter(Mandatory=$false)]
        [System.String] $InstanceGuid = "",

        [Parameter(Mandatory=$false)]
        [System.String] $RegistrationRegion = "eastus",

        [Parameter(Mandatory=$false)]
        [System.String] $ObsRootFolderPath = "C:\StdObservability",

        [Parameter(Mandatory=$false)]
        [System.String] $Cloud = "AzureCloud",

        [Parameter(Mandatory=$false)]
        [Int] $CacheFlushWaitTimeInSec = 600,

        [Parameter(Mandatory=$false)]
        [System.String] $TenantJsonOverridePath,

        [Parameter(Mandatory=$false)]
        [Switch] $Cleanup,

        [Parameter(Mandatory=$false)]
        [Nullable[Int]] $LogParsingEngineTimeoutInMinutes
    )

    $functionName = $MyInvocation.MyCommand.Name

    $script:ErrorActionPreference = 'Stop'

    $skipArcForServer = $false
    try
    {
        $transcriptFileName = "{0}.{1:yyyy-MM-dd-hh-mm-ss}.log" -f $functionName, $(Get-Date)
        $transcriptFilePath = Join-Path -Path $ObsRootFolderPath -ChildPath $transcriptFileName
        Start-Transcript -Path $transcriptFilePath -Append

        Push-Location -Path $PSScriptRoot

        Import-Module "$PSScriptRoot\StandaloneObservabilityHelper.psm1" -Force

        # Fail if Arc Agent is already connected
        if(Test-IsArcAgentConnected)
        {
            $skipArcForServer = $true
        }
        if (Test-ArcExtensionWatchdogIsPresent)
        {
            throw "TelemetryAndDiagnostics ARC Extension Watchdog is present. Cannot continue with Standalone Observability operation."
        }

        # Ensure we are elevated
        if (Test-UserIsElevated)
        {
            Write-Host "Powershell running as Administrator. Continuing."
        }
        else
        {
            Write-Error -Message "Running as administrator is required for this operation. Please restart PowerShell as Administrator and retry."
            throw "$functionName requires elevated permissions."
        }

        $TenantId = Get-TenantId -AzureEnvironment $Cloud -SubscriptionId $SubscriptionId
        if ($PSCmdlet.ParameterSetName -eq "ServicePrincipal") {
            & .\Install-StandaloneObservability.ps1 -ResourceGroupName $ResourceGroupName `
                                                                -SubscriptionId $SubscriptionId `
                                                                -TenantId $TenantId `
                                                                -RegistrationSPCredential $RegistrationSPCredential `
                                                                -FactoryLogShare $DiagnosticLogPath `
                                                                -ObsRootFolderPath $ObsRootFolderPath `
                                                                -InstanceGuid $InstanceGuid `
                                                                -Cloud $Cloud `
                                                                -RegistrationRegion $RegistrationRegion `
                                                                -GcsRegion $RegistrationRegion `
                                                                -TenantJsonOverridePath $TenantJsonOverridePath `
                                                                -CacheFlushWaitTimeInSec $CacheFlushWaitTimeInSec `
                                                                -Cleanup:$Cleanup `
                                                                -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes `
                                                                -SkipArcForServer $skipArcForServer -ParseOnce | Out-Null
        }
        elseif ($PSCmdlet.ParameterSetName -eq "Interactive") {
            & .\Install-StandaloneObservability.ps1 -ResourceGroupName $ResourceGroupName `
                                                                -SubscriptionId $SubscriptionId `
                                                                -TenantId $TenantId `
                                                                -Interactive `
                                                                -FactoryLogShare $DiagnosticLogPath `
                                                                -ObsRootFolderPath $ObsRootFolderPath `
                                                                -InstanceGuid $InstanceGuid `
                                                                -Cloud $Cloud `
                                                                -RegistrationRegion $RegistrationRegion `
                                                                -GcsRegion $RegistrationRegion `
                                                                -TenantJsonOverridePath $TenantJsonOverridePath `
                                                                -CacheFlushWaitTimeInSec $CacheFlushWaitTimeInSec `
                                                                -Cleanup:$Cleanup `
                                                                -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes `
                                                                -SkipArcForServer $skipArcForServer -ParseOnce | Out-Null
        }
        elseif ($PSCmdlet.ParameterSetName -eq "PassThrough") {
            & .\Install-StandaloneObservability.ps1 -ResourceGroupName $ResourceGroupName `
                                                                -SubscriptionId $SubscriptionId `
                                                                -TenantId $TenantId `
                                                                -PassThrough `
                                                                -FactoryLogShare $DiagnosticLogPath `
                                                                -ObsRootFolderPath $ObsRootFolderPath `
                                                                -InstanceGuid $InstanceGuid `
                                                                -Cloud $Cloud `
                                                                -RegistrationRegion $RegistrationRegion `
                                                                -GcsRegion $RegistrationRegion `
                                                                -TenantJsonOverridePath $TenantJsonOverridePath `
                                                                -CacheFlushWaitTimeInSec $CacheFlushWaitTimeInSec `
                                                                -Cleanup:$Cleanup `
                                                                -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes `
                                                                -SkipArcForServer $skipArcForServer -ParseOnce | Out-Null
        }
        elseif ($PSCmdlet.ParameterSetName -eq "AccessToken") {
            & .\Install-StandaloneObservability.ps1 -ResourceGroupName $ResourceGroupName `
                                                                -SubscriptionId $SubscriptionId `
                                                                -TenantId $TenantId `
                                                                -AccessToken $AccessToken `
                                                                -FactoryLogShare $DiagnosticLogPath `
                                                                -ObsRootFolderPath $ObsRootFolderPath `
                                                                -InstanceGuid $InstanceGuid `
                                                                -Cloud $Cloud `
                                                                -RegistrationRegion $RegistrationRegion `
                                                                -GcsRegion $RegistrationRegion `
                                                                -TenantJsonOverridePath $TenantJsonOverridePath `
                                                                -CacheFlushWaitTimeInSec $CacheFlushWaitTimeInSec `
                                                                -Cleanup:$Cleanup `
                                                                -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes `
                                                                -SkipArcForServer $skipArcForServer -ParseOnce | Out-Null
        }
        else {
            & .\Install-StandaloneObservability.ps1 -ResourceGroupName $ResourceGroupName `
                                                                -SubscriptionId $SubscriptionId `
                                                                -TenantId $TenantId `
                                                                -RegistrationCredential $RegistrationCredential `
                                                                -FactoryLogShare $DiagnosticLogPath `
                                                                -ObsRootFolderPath $ObsRootFolderPath `
                                                                -InstanceGuid $InstanceGuid `
                                                                -Cloud $Cloud `
                                                                -RegistrationRegion $RegistrationRegion `
                                                                -GcsRegion $RegistrationRegion `
                                                                -TenantJsonOverridePath $TenantJsonOverridePath `
                                                                -CacheFlushWaitTimeInSec $CacheFlushWaitTimeInSec `
                                                                -Cleanup:$Cleanup `
                                                                -LogParsingEngineTimeoutInMinutes $LogParsingEngineTimeoutInMinutes `
                                                                -SkipArcForServer $skipArcForServer -ParseOnce | Out-Null
        }
    }
    catch
    {
        $exception = $_
        Write-Error "$functionName failed. $exception"
        Write-Error "$($exception.ScriptStackTrace)"
        throw $exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        try
        {
            New-GmaStateFolders -ObsRootFolderPath $ObsRootFolderPath
            Set-HandlerEnvInfo -ObsRootFolderPath $ObsRootFolderPath -CloudName $Cloud -RegionName $RegistrationRegion
            if ($PSCmdlet.ParameterSetName -eq "AccessToken")
            {
                & .\Uninstall-StandaloneObservability.ps1 -AccessToken $AccessToken -SkipArcForServer $skipArcForServer | Out-Null
            }
            else
            {
                Import-Module "$PSScriptRoot\StandaloneObservabilityHelper.psm1" -Force
                $TenantId = Get-TenantId -AzureEnvironment $Cloud -SubscriptionId $SubscriptionId

                Write-Host "Token was null. Going to try to use Connect-AzAccount to get the token."
                if ($PSCmdlet.ParameterSetName -eq "ServicePrincipal")
                {
                    Connect-AzAccount -Credential $RegistrationSPCredential -ServicePrincipal -Environment $Cloud -Tenant $TenantId -Subscription $SubscriptionId
                }
                elseif ($PSCmdlet.ParameterSetName -eq "Interactive")
                {
                    $token = Get-AzAccessTokenAsPlainText
                    if ($null -eq $token)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Environment $Cloud -Tenant $TenantId -Subscription $SubscriptionId
                    }
                }
                elseif ($PSCmdlet.ParameterSetName -eq "DefaultSet")
                {
                    Connect-AzAccount -Credential $RegistrationCredential -Environment $Cloud -Tenant $TenantId -Subscription $SubscriptionId
                }
                $token = Get-AzAccessTokenAsPlainText
                & .\Uninstall-StandaloneObservability.ps1 -AccessToken $token -SkipArcForServer $skipArcForServer | Out-Null
            }
        }
        finally
        {
            Pop-Location
            Stop-Transcript -ErrorAction SilentlyContinue
        }
    }

}

Export-ModuleMember -Function Send-AzureLocalDiagnosticData
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAJMfysaMpwgqQ/
# y3bXgTo6Z9mP3kZKHopOHLOr+/BiHKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIsx3DfO
# TFowWon2zDzQUOHaMWYby0aFoqU1kbyFISk+MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEASGb0Eo9IELKJb7vyxJeCoIIwKEiNZflBVq56Hc07
# nKY3gaIUPlxxcrDouKEjjSQzwO9aFTpyjnef8CRqxivWGSdJ89Ipmt0Q/UXDNdm4
# hhA6qWppr4/utBnhWRIXT15w/huRTSwH+m1AlvX/WtET6hfuoVrlQevUCVA4b0x/
# W1dt7MG1zx6CAUzRf80LeCkE1jAd5+CbmsHH7uoKQeu991mG7WIFLu5pRyJtor5k
# vrH0Y732ZIcCUHXICBVyloA2aSIgl3PCuZ/8/7US7W0r0EJ6ub7HaDp0MsDluzVv
# ANcUFyTumL6rqWMt4rFNFGge8775hbHGlefd5Fgdth/f8qGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBooxDVdoE7lYcKVQkhQaQCTvwp00r+OTqZSc8j
# Sf5VvgIGaeegqJ4IGBMyMDI2MDUwMzE0MzExMC45MjRaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAcwvkOPBZ3xbxmzEa/Av6Hg8OE
# ize8YBRn0JXunvCUCjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIC+BXWrz
# 9geMgM8Bvn8bqxHjhHXJ29EBizITIw0B9vOCMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIeo6ykbjlvfEkAAQAAAh4wIgQgJ1jdQD+0
# szm+d0/kpKtiIuKHE8oW2d9Vtqy9flj8PCswDQYJKoZIhvcNAQELBQAEggIAfKUq
# 3BZFwiekZtuqyoAHTq6AGOjGx75zGE69WwNVS0a/3IQdWLmGW5W1BMO9ekC+wuW6
# PNm57SaZD2uY1+6OeMduyoLIF7box/KiD4ZYvDnQ4p+tYxwC9iQn+rn6thXwd9F+
# aLliOJW0y76LnRHToayauTf85FRWFXn23kKp8Pv9k88WXkiKJRx2AU3voEVpgYau
# VvrI8DWaC9OA9hbvHqif+hwpkKQGjGg7TWOkUOeiPgPs7pPlvMZKLKYA5wKY3Uhc
# J7+g9jn9nZBxF0xLNkSXQyk8Zmdqrrhe8Ac/sifVEaDM1mfdjqBYSbghZaNFynHw
# mf+xqAYxgv2j9ev7qD0nZGb/au5lQl9nxKGa0/nnKwwCc36Aygz0i1vh03zUdLpT
# JGPrbxSmlOCpdTghKEcw0FO25hQXOcKZBqioT25jD+dHGYAXLwo8Qud42Sj7g/ls
# 44ZVFNDoHteNGpIvIxsmjB6u3zzO8lQBn83YIBZQY/4UUtqNp2ixI2h5gLioUSwV
# RoMzUZlAZixoLEiWwD4yEkHJoo+tVHrdW4LqeDV7e9IEAVfa8uQaIzGvVeWJzcti
# nF+tbcnRPxYhvbATUQ0PWx8rCCVu6Q5WXCnQ4+n4T0DZQK9iFucM9C2kU2CvrGeO
# 5s3PoydntOPfsiaP52s4K+xtVwOhNfq3BYmQlfY=
# SIG # End signature block
