<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-LocalizedData -BindingVariable lanTxt -FileName AzStackHci.ArcIntegration.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.ArcIntegration.Helpers.psm1 -DisableNameChecking -Global

function Invoke-AzStackHciArcIntegrationValidation
{
    <#
    .SYNOPSIS
        Perform AzStackHci ArcIntegration Validation
    .DESCRIPTION
        Checks if the Resource group already contains other ARC resources which match the HCI Nodes
    .EXAMPLE
        PS C:\> Connect-AzAccount -Tenant $tenantID -Subscription $subscriptionID -DeviceCode
        PS C:\>  $nodeNames = [string[]]("host1","host2","host3","host4")
        PS C:\>  Invoke-AzStackHciArcIntegrationValidation -SubscriptionID $subscriptionID -ArcResourceGroupName $resourceGroupName -NodeNames $nodeNames
    .PARAMETER ArcResourceGroupName
        Resource Group name, which will contain the ARC Resources. This is specified during HCI Cluster deployment. Is Mandatory Paratmer
    .PARAMETER SubscriptionID
        Specifies the Azure Subscription to create the resource. Is Mandatory Paratmer
    .PARAMETER NodeNames
        Specifies the hostname of each HCI Node that will be part of HCI Cluster. Is Mandatory Paratmer
    .PARAMETER AzureEnvironment
        Specifies the Azure Environment. Valid values are AzureCloud, AzureChinaCloud, AzureUSGovernment. Required only if ARMAccessToken is used.
    .PARAMETER TenantID
        Specifies the Azure TenantId.Required only if ARMAccessToken is used.
    .PARAMETER ArmAccessToken
        Specifies the ARM access token. Can be provided as either a string or SecureString. Specifying this along with AccountId will avoid Azure interactive logon. If not specified, Azure Context is expected to be setup.
    .PARAMETER AccountID
        Specifies the Account Id. Specifying this along with ArmAccessToken will avoid Azure interactive logon. Required only if ARMAccessToken is used.
    .PARAMETER PassThru
        Return PSObject result.
    .PARAMETER HardwareClass
        Hardware class: Small, Medium, or Large.
    .PARAMETER ClusterPattern
        Hardware class: Standard, Stretch, or RackAware.
    .PARAMETER OutputPath
        Directory path for log and report output.
    .PARAMETER CleanReport
        Remove all previous progress and create a clean report.
    .INPUTS
        Inputs (if any)
    .OUTPUTS
        Output (if any)
    #>
    [CmdletBinding(DefaultParametersetName='AZContext')]
    param (
        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Azure Environment used for HCI ARC Integration")]
        [string]
        $AzureEnvironment,

        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Azure Tenant used for HCI ARC Integration")]
        [string]
        $TenantID,

        [Parameter(ParameterSetName='AZContext', Mandatory=$true)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Azure Subscription used for HCI ARC Integration")]
        [string]
        $SubscriptionID,

        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Credential to connect to Azure cloud. Can be string or SecureString.")]
        [ValidateScript({
            if ($_ -is [string] -or $_ -is [System.Security.SecureString]) {
                return $true
            }
            throw "ArmAccessToken must be of type [string] or [System.Security.SecureString]. Received type: $($_.GetType().Name)"
        })]
        [object] $ArmAccessToken,

        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Credential to connect to Azure cloud")]
        [string] $AccountId,

        [Parameter(ParameterSetName='AZContext', Mandatory=$true)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Resource Group name into which ARC resources will be projected")]
        [string]
        $ArcResourceGroupName,

        [Parameter(ParameterSetName='AZContext', Mandatory=$true)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Resource Group name into which Azure Stack HCI resource will be projected")]
        [string]
        $RegistrationResourceGroupName,

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Azure Region name into which ARC resources will be projected")]
        [string]
        $Region,

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Resource Name of Azure Stack HCI Portal Resource")]
        [string]
        $RegistrationResourceName,

        [Parameter(ParameterSetName='AZContext', Mandatory=$true)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $true, HelpMessage = "Names of each individual HCI Cluster nodes")]
        [String[]]
        $NodeNames,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the PsSession(s) for all the nodes. If null, then the nodes arc state check will be ignored.")]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.ArcIntegration.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.ArcIntegration.Helpers) })]
        [string[]]
        $Include,

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.ArcIntegration.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.ArcIntegration.Helpers) })]
        [string[]]
        $Exclude,

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Hardware class: Small, Medium, or Large")]
        [ValidateSet('Small','Medium','Large')]
        [String]
        $HardwareClass = "Medium",

        [Parameter(Mandatory = $false, HelpMessage = "Cluster Pattern: Standard, Stretch, or RackAware")]
        [ValidateSet('Standard','Stretch','RackAware')]
        [String]
        $ClusterPattern = "Standard",

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath,

        [Parameter(ParameterSetName='AZContext', Mandatory=$false)]
        [Parameter(ParameterSetName='ARMToken', Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false
    )

    try
    {
        $script:ErrorActionPreference = 'Stop'
        Set-AzStackHciOutputPath -Path $OutputPath
        # Review Protect-SensitiveProperties (find "Redact sensitive parameters") to avoid logging sensitive information from the user
        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru
        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependencies" -Status "Environment Configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        # Determine calling context to adjust default test exclusions
        $stack = Get-PSCallStack
        $calledFromModule = $stack | Select-Object -Skip 1 | Where-Object { $_.ScriptName -like "*.psm1" }
        if ($calledFromModule)
        {
            Log-Info "Invoke-AzStackHciArcIntegrationValidation called from module."
        }
        else
        {
            Log-Info "Invoke-AzStackHciArcIntegrationValidation called from console. Excluding Test-AzureStackHCISubscriptionState by default."
            if (-not $Exclude) {
                $Exclude = @("Test-AzureStackHCISubscriptionState")
            }
        }
        # Get list of tests to run
        $testList = Get-TestListByFunction -ModuleName AzStackHci.ArcIntegration.Helpers
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $TestList
        $totalTestCount = ($script:envchktestList).Count

        if ((-not [string]::IsNullOrEmpty($ArmAccessToken)) -and ( -not [string]::IsNullOrEmpty($AccountId)))
        {
            $retryCount = 0
            $maxRetries = 3
            $retryDelay = 5 # seconds

            while ($retryCount -lt $maxRetries) {
                try {

                    $armTokenType = $ArmAccessToken.GetType().Name
                    if ($armTokenType -eq 'String') {
                        Log-Info "Using provided ARM Access Token string to connect to Azure."
                        Connect-AzAccount -Environment $AzureEnvironment -Tenant $TenantID -AccessToken $ArmAccessToken -AccountId $AccountId -Subscription $SubscriptionID | Out-Null
                    }
                    elseif ($armTokenType -eq 'SecureString') {
                        Log-Info "Provided ARM Access Token is secure string. Converting to plain string for connection to Azure."
                        $ArmAccessTokenString = [System.Net.NetworkCredential]::new("", $ArmAccessToken).Password
                        Connect-AzAccount -Environment $AzureEnvironment -Tenant $TenantID -AccessToken $ArmAccessTokenString -AccountId $AccountId -Subscription $SubscriptionID | Out-Null
                    }
                    else {
                        throw "Unsupported ARM Access Token type: $armTokenType. Expected String or SecureString."
                    }

                    break
                } catch {
                    $retryCount++
                    if ($retryCount -eq $maxRetries) {
                        throw $_
                    }
                    Log-Info "Failed to connect to Azure ($retryCount / $maxRetries). (Message: $($_.Exception.Message)). Retrying in $retryDelay seconds..." -Type Warning
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }

        # Run validation
        $i = 0
        $Result = @()
        $ProgressActivity = "Checking AzStackHci ArcIntegration Compatibility"
        $i = 0

        $ProgressStatus = "Testing $ENV:ComputerName"
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }
        Write-Progress @progressParams

        :noTestsBreak foreach ($test in $script:envchktestList)
        {
            $OpMsg = "Checking {0}" -f $test
            Log-Info -Message $OpMsg
            Write-Progress @progressParams -CurrentOperation $OpMsg -PercentComplete (($i++ / $TotalTestCount) * 100)
            $invokeParameters = @{}
            Get-Command $test | Select-Object -ExpandProperty Parameters | Select-Object -ExpandProperty Keys | ForEach-Object {
                if ($PSBoundParameters[$PSITEM]) {
                    $invokeParameters += @{
                        $PSITEM = $PSBoundParameters[$PSITEM]
                    }
                }
            }
            $Result += Invoke-Expression "$test @invokeParameters"
        }

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'ArcIntegration Results'
            Write-AzStackHciResult -Title 'ArcIntegration' -Result $Result
            Write-Summary -Result $Result -Property1 Detail
        }
        else
        {
            return $Result
        }
    }
    catch
    {
        Log-Info -Message "" -ConsoleOut
        Log-Info -Message "$($_.Exception.Message)" -ConsoleOut -Type Error
        Log-Info -Message "$($_.ScriptStackTrace)" -ConsoleOut -Type Error
        $cmdletException = $_
        throw $_
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        # Write result to telemetry channel
        foreach ($r in $result)
        {
            Write-ETWResult -Result $r
        }
        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'ArcIntegration' -Value $Result -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

# SIG # Begin signature block
# MIInSAYJKoZIhvcNAQcCoIInOTCCJzUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCliSwN18qlf4vl
# 1dYO5OJLb6TzWR5jYT+IkQgmX+R8L6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPhgvOWJ
# WvBIhe4/pyHW9tstNnk+n4hUBl24YFD549nKMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAehWWqFYPtYt3EW5cmbQunpfgH13iQdDKLjf7ZEqw
# d45lSYRacvHmhtJrbex0b0L8l8KfhNXCQvtVTdccFw+bEGD/TeavZN0GZKyayaxi
# uzThLOUaArY61oND5R3McEZgPmzJR0GL4wAPKk+EdNi6mqLbI5shKoXzX0zxZ6Xj
# 9RRogkrgRU3pD/q0V043q9ZNtTkbW8nR7/HihGW+uzM4y4l0HTQxxp1o6gacwDDf
# AAXQG34RR2EoPaHkULWmKLoAxbkyAVSp2Huj74CAP7J15ZZHNne1DxO6N+O/rxGH
# uO5PkbA0JZ9S6pH0uFrTkW2vKDShLNziUfD475ZfAF4qEaGCF5YwgheSBgorBgEE
# AYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDbMvoF60ZsmUBCyyM1HM/Ng7JY0VwHCJ/bMV14
# SubefAIGaedcMrc1GBIyMDI2MDUwMzE0MzExMC4xNVowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpBMDAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMzAAACK7sAUP9NO5qhAAEAAAIr
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5NDAxMVoXDTI3MDUxNzE5NDAxMVowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBMDAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJfeaLo4PezJSpCbhCqCSso9tywr
# 9DHd9hy0vz5UzW45jduiiLkbHBq5OBB/okUchNOjFLuCOoqUrw4UvMvpROXSPEQr
# m3oO45yAld2+62KahOU5LQLeTIhNcEBeiP+CnqFFH3PpZGKnUq2SKVvd0lcKNCpP
# 0/YK66Ov5XPyv5n6MOXT2OL+Jz/gbfiveZXCOz/8afH0+7fVXytcWJw2IDPGm5tr
# Clt3ymp/OVZPa+cbeQX2XoyJERu8ndcctTAdCyHS39OtIXH+z/IKqklZgnqgKUbv
# S2+wUfRpE/zAHhw/8IVrYgu+TbqLc5wkGX6moqMdNIHL2a/BM8QOWfNyjQ23xHql
# I9NdmAGyxweGgp8LRZCY7NjaR5dsCZFNxkzJfPm/8AluagjTLTsFrO+3k2Rd10b1
# MStBbC2wXIgqsSUOBZ8d4KhO7XC7ZyIPd0rvbPdxraDOgQPFPaP0FchQpqJPNN1A
# 9GwAxo7d1TTNobAwyXC1InIOHXhgSBmhS7m9Lwy6Ayp2s2OmHIvrnIqGOkBZuFiQ
# gc7/S5mO73m0/zNk2pchGHi119Yck8BOf2v5zGTK6HbHRUt1/HWWYr1fc2MfQ22A
# CzkkH/A6WTK653GYVN9ZXJGsvfuKyk5nxo8AWC/JHpw1OQamQWjfklGNyI2ZmJTi
# pP1S3L5XmC50WTWPAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUPhaO5BNQlu1t3eOa
# 9mS7QVnZ5TYwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAM78IqxyIQzySvV+ofhO
# V9ProQ2hOPFfDzXSnISrQ92uAvB+BPfH7WDPsJAe1R16+oxDmofIMuGbqlP3XUJi
# QY37qD4xTt8xhOvp3dLGJ4nAEihaR9HiDtKK0bMwpTjrkoRh6N912hSCi8L/FxGl
# oAs7mnf8DbjwHKEmIy20FA0O2xP8doIXBEUJRFvL9/xzWSTLwXzGQJcXP78y1nl3
# WVYWPA4jaB5kdar1eKEM6B57mdLaSijlXqfxcbbbRRN69V/6mCakgfvVcoNUhhMY
# ZkmzrI+V8nZperDUwTg1HqiQ2xjc/UzfUfoMxhF8kY0E16nn3mRcaHdjMDdwKLKD
# 6OYnnyH99O+OeAim5QV84OkOMXHSJzVigsA3GEIXdGFL2pgzsrjQ0SEqyFi5oCQg
# bZcEpiKDev/T9vSyO+MHCznkBiicybcDypxf/qT1V9zSa/122ice5YZ8DZv6oTaq
# kKeHMZt0MeruI5JkTDTWc26kAx/VzjWT0ihNDbPeLDrDhlmgs7KDhMoxunWSulPi
# 2uKn/LfQK/mSHKoIM2ppdCkGQ5g43wuC2hDdqZU5fuLHmN2ufH+9TFNRKKBe+tZ0
# vtSTySmZLTO2jZOjLtpPmgHMJO9+P2In8E38TW+EUGSEkK9ns9W+wxKdNOaTHYVq
# XaVWTO24Ajjh8P+7Isl1oxBLMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
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
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAAmsP3TKQemj/QAZvuWbC+wK2pE5oIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoarNMCIYDzIw
# MjYwNTAzMTEwNjUzWhgPMjAyNjA1MDQxMTA2NTNaMHcwPQYKKwYBBAGEWQoEATEv
# MC0wCgIFAO2hqs0CAQAwCgIBAAICCuICAf8wBwIBAAICEpEwCgIFAO2i/E0CAQAw
# NgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgC
# AQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAiXiD+RkIc56txiN9YZzcVjnnT/XK
# gaze+sKlgKI241+pUiSBb04PlPznv2nF/bVevRTUBw+UNdMmnTIOlRlJALmmJngZ
# WWdZF3xzBhy50kxNG+iFoqQHxGQhb8d1Md0EgF8o9KXR5uxjmwekYMxm+cvlVjeF
# 3lm4V5KHuBXthjYLmm3YIIr73tlawvpNrfw5T0PrznSzyAtxNHLFQHQsf3t9ROmL
# ghtWX2NV+QGfNSPWMhwYqDEwvCQjQ6OAKoJfmRpmCVqY8mmYTnp101vq3JF+1Ty7
# IGImIchtP4jQW6WDQ9J6dZKRUg7uptsQlFou3loa/7n6ELOFSQd12dcoMTGCBA0w
# ggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACK7sA
# UP9NO5qhAAEAAAIrMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIErFy/exDm0h9cxEnmZNIXvWBc2A
# nULLgRL+9U6DrfvrMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgcg4j9D+Q
# V+1gD4zY5j7UHHdqMEPr9YMC09Pa8WS/blIwgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7AFD/TTuaoQABAAACKzAiBCDhuKDBa8XH
# Tgn2Yh9JPY0NhOp4elLZUr/RvUkX/lpY7TANBgkqhkiG9w0BAQsFAASCAgB+vl/J
# Xv5SjvtTborV7T9uvYmXrIJehxBhIWm5Yjdcc5OF1N+h1f30Ojzg2L1guX6CjxR1
# xef94tBSPFaSbRc/PKAl+WZvE4GtBy/YRmjUSVYYbdNsSH/Bvmjc5Z6gBeC12hIe
# icNJy0+JkDX1xk1zWjmiHRa85QlQ++OTTWeCENWNMk2IhdyfcoV8qo3ZNU3IS7PU
# w4Zp1L3Tu7Yik87GaL7TG4mmiUZXRR32nSS1UaLb54Oy2U/Hus3pJz93p3/TKias
# kv8DfKihURlqL1DfIC7mRsKnxHiCOcIHJS0U70STV13/wHGLEpmri+PW7SW5X5w5
# a/jI0aSU8yz7t/9NjsIkYJAqvVd8KVhH4QpeONSAJAAJZgweYS7PVct1QMaJC1Wb
# GmB9s0QToNExqk7txeaneZSFTsKckwZumvr/yC5Z4DmLZRmduMbCTCqYnts59Xkw
# JOPHiK1fyCAwQkC3WsIC8x1fe7Lwi0QPuNoo9RHgqCUfWbGSu3HB1r7tEbCmnKJX
# /AFN8HmSKgAuvbVZWuxzVULeYVWOWirolmnSPqxgApzY2pxen1pGpfL/7NPlSqTf
# E2KmWdqp+0QvQOdmjnYEc4oEZvUEvsZwKrn2lICZJasHzovm8+YKTJf+rMVicIN8
# Q8mwqj0nWhAS1JxLktZZrZdjRsq+YglxxRxONg==
# SIG # End signature block
