Import-LocalizedData -BindingVariable lswTxt -FileName AzStackHci.ValidatedRecipe.Strings.psd1

function TestResult {
    <#
    .SYNOPSIS
        Build up a params data structure to pass the
        New-AzStackHciResultObject function.
    .DESCRIPTION
        The New-AzStackHciResultObject function get information about the
        result of a test into the correct result files (log, json, etc.)
    #>
    Param([Parameter(Mandatory=$true,Position=0)] [array]$responses,
          [Parameter(Mandatory=$true,Position=1)] [string]$Name,
          [Parameter(Mandatory=$true,Position=2)] [string]$Title,
          [Parameter(Mandatory=$true,Position=3)] [string]$DisplayName,
          [Parameter(Mandatory=$true,Position=4)] [string]$Severity,
          [Parameter(Mandatory=$true,Position=5)] [string]$Description,
          [Parameter(Mandatory=$false,Position=6)] [string]$Remediation = 'https://learn.microsoft.com/en-us/azure/azure-local/update/update-troubleshooting-23h2',
          [Parameter(Mandatory=$false,Position=7)] [string]$TargetResourceType = 'ValidatedRecipe',
          [Parameter(Mandatory=$false,Position=8)] [string]$Resource = 'Validated Assembly Recipe')
    $instanceResults = @()
    foreach ($response in $responses) {
        $detailString = $($response.details) -join ';  '
        foreach ($msg in $($response.logLines)) {
            $msgArray = $msg.split('|')
            Log-Info $msgArray[0] -Type $msgArray[1]
        }
        try {
            $Status = 'SUCCESS'
            if ($($response.rc)) {
                $Status = 'FAILURE'
            }
            $params = @{
                Name               = $Name
                Title              = $Title
                DisplayName        = $DisplayName
                Severity           = $Severity
                Description        = $Description
                Tags               = @{}
                Remediation        = $Remediation
                TargetResourceID   = $($response.computername)
                TargetResourceName = $($response.computername)
                TargetResourceType = $TargetResourceType
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                HealthCheckSource  = $ENV:EnvChkrId
                AdditionalData     = @{Source    = $($response.computername)
                                       Resource  = $Resource
                                       Detail    = $detailString
                                       Status    = $status
                                       TimeStamp = [datetime]::UtcNow}}
            $instanceResults += New-AzStackHciResultObject @params
        }
        catch {
            throw $_
        }
    }
    return $instanceResults
}

function Test-PSModules
{
    <#
    .SYNOPSIS
        Test version of PS Modules installed is correct
    .DESCRIPTION
        Get installed PS module from local machine and validated its expected as per the current recipe.
        Expecting data from PsSessions to include local machine indicating ECE.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    $sb = {
        Param($lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $vcNugetPath = Get-ASArtifactPath -NugetName "Microsoft.AzureStack.VersionControl.Operations"
        Import-Module "$vcNugetPath\content\Scripts\VersionControlHelpers.psm1" -Force -DisableNameChecking -Verbose:$false | Out-Null
        $InstalledModules = Get-InstalledPowerShellModules
        foreach ($mod in $InstalledModules) {
            # Get-InstalledPowerShellModules will return 0.0.0 if a required module is not installed
            # it is OK if the module is not yet installed because we are looking to update/install the modules
            # this is true especially if they are not currently installed or they have an older version installed.
            # however, if the customer has a newer version installed we do not want to downgrade the version
            # just because the recipe calls for an older version.
            try {
                $InstalledVersionObj = [Version]::Parse($mod.InstalledVersion)
            }
            catch {
                $InstalledVersionObj = $null
                $mod.InstalledVersion = "N/A"
            }
            try {
                $RequiredVersionObj = [Version]::Parse($mod.RequiredVersion)
            }
            catch {
                $RequiredVersionObj = $null
                $mod.RequiredVersion = "N/A"
            }
            if (-not $InstalledVersionObj -and -not $RequiredVersionObj) {
                $rc += 1
                $res = ${resultSeverity}
                $msg = $lswTxt.PSModulesFailedToParseBothVersions -f $mod.Name, $localHost, $mod.InstalledVersion, $mod.RequiredVersion
                $dtl = $msg
            } elseif (-not $InstalledVersionObj) {
                $rc += 1
                $res = ${resultSeverity}
                $msg = $lswTxt.PSModulesFailedToParseInstalledVersion -f $mod.Name, $localHost, $mod.InstalledVersion
                $dtl = $msg
            } elseif (-not $RequiredVersionObj) {
                $rc += 1
                $res = ${resultSeverity}
                $msg = $lswTxt.PSModulesFailedToParseRequiredVersion -f $mod.Name, $localHost, $mod.RequiredVersion
                $dtl = $msg
            } elseif ($InstalledVersionObj -le $RequiredVersionObj) {
                $res = 'SUCCESS'
                $msg = $lswTxt.PSModulesSuccess -f $mod.Name, $localHost, $mod.InstalledVersion, $mod.RequiredVersion
                $dtl = $lswTxt.PSModulesDetailSuccess -f $mod.Name, $mod.InstalledVersion
            } else {
                $rc += 1
                $res = ${resultSeverity}
                $msg = $lswTxt.PSModulesFailure -f $mod.Name, $localHost, $mod.InstalledVersion, $mod.RequiredVersion
                $dtl = $msg
            }
            $detailList.Add($dtl)
            $logLines.Add("${msg}|${res}")
        }
        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
        Name        = "AzStackHci_ValidatedRecipe_PowerShellModule_Version"
        Title       = "Test PowerShell Module Version"
        DisplayName = "Test PowerShell Module Version"
        Severity    = $resultSeverity
        Description = "Validating that the PS modules installed on the host are the same versions defined in the validated recipe."}
    return (TestResult @splat)
}

function Test-AzCli
{
    <#
    .SYNOPSIS
        Validate that the installed version of Azure.CLI matched the required one
    .DESCRIPTION
        Get installed version using 'az version' and compare it to the required version defined by the VersionControl module
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    $sb = {
        Param($lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $vcNugetPath = Get-ASArtifactPath -NugetName "Microsoft.AzureStack.VersionControl.Operations"
        Import-Module "$vcNugetPath\content\Scripts\VersionControlHelpers.psm1" -Force -DisableNameChecking -Verbose:$false | Out-Null
        $name = 'AzCli'
        try {
            $installedVersion = (az version -o json |ConvertFrom-Json).'azure-cli'
        }
        catch {
            $installedVersion = "N/A"
        }
        try {
            $requiredVersion = (Get-ValidatedRecipe -TypesToInclude 'AzCli' -TagsToInclude 'Azure').RequiredVersion
        }
        catch {
            $requiredVersion = "N/A"
        }
        try {
            $InstalledVersionObj = [Version]::Parse($installedVersion)
        }
        catch {
            $InstalledVersionObj = $null
            $installedVersion = "N/A"
        }
        try {
            $RequiredVersionObj = [Version]::Parse($requiredVersion)
        }
        catch {
            $RequiredVersionObj = $null
            $requiredVersion = "N/A"
        }
        if (-not $InstalledVersionObj -and -not $RequiredVersionObj) {
            $rc += 1
            $res = ${resultSeverity}
            $msg = $lswTxt.AzCliFailedToParseBothVersions -f $name, $localHost, $installedVersion, $requiredVersion
            $dtl = $msg
        } elseif (-not $InstalledVersionObj) {
            $rc += 1
            $res = ${resultSeverity}
            $msg = $lswTxt.AzCliFailedToParseInstalledVersion -f $name, $localHost, $requiredVersion, $installedVersion
            $dtl = $msg
        } elseif (-not $RequiredVersionObj) {
            $rc += 1
            $res = ${resultSeverity}
            $msg = $lswTxt.AzCliFailedToParseRequiredVersion -f $name, $localHost, $requiredVersion
            $dtl = $msg
        } elseif ($InstalledVersionObj -eq $RequiredVersionObj) {
            $res = 'SUCCESS'
            $msg = $lswTxt.AzCliSuccess -f $name, $localHost, $installedVersion, $requiredVersion
            $dtl = $msg
        } else {
            $rc += 1
            $res = ${resultSeverity}
            $msg = $lswTxt.AzCliFailure -f $name, $localHost, $installedVersion, $requiredVersion
            $dtl = ''
            $dtl += $msg
            $dtl += " The Az-Cli version installed conflicts with updates; "
            $dtl += "Find the [Azure-Cli] msi file path in the C:/NugetStore and run: "
            $dtl += "(Start-Process msiexec.exe -Wait -ArgumentList (/I [fullPathToAzureCliMsiFile] /quiet))"
        }
        $detailList.Add($dtl)
        $logLines.Add("${msg}|${res}")

        $response = "" | Select-Object -Property rc, details, computername, logLines
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = if ($psSession) {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList (,$lswTxt, $resultSeverity)
    } else {
        Invoke-Command -ScriptBlock $sb -ArgumentList (,$lswTxt, $resultSeverity)
    }
    $splat = @{responses   = $responses
        Name        = "AzStackHci_ValidatedRecipe_AzureCli_Version"
        Title       = "Test Azure-Cli Module Version"
        DisplayName = "Test Azure-Cli Module Version"
        Severity    = $resultSeverity
        Description = "Validating that the installed version of Az.Cli is the required version."}
    return (TestResult @splat)
}

# This function should only be call during update scenarios health check. This is to avoid case where 2510 pnu was offered to 2508 build due to bug in VSR.
function Test-ServicesVersion
{
    <#
    .SYNOPSIS
        Validate that the services version is not 2508
    .DESCRIPTION
        This function checks if the services version is not 2508.
    #>
    $sb = {
        Param($lswTxt, $resultSeverity)
        $rc = 0
        $localHost = $ENV:ComputerName
        $detailList = New-Object System.Collections.Generic.List[System.Object]
        $logLines = New-Object System.Collections.Generic.List[System.Object]
        $remediation = $null
        Import-Module ECEClient 3>$null 4>$null
        $stampInformation = Get-StampInformation
        if ("Upgrade" -ne $stampInformation.InstallationMethod) {
            # Not brownfield env, skip checking
            $msg = $lswTxt.ServicesVersionNotCheckedBrownfield -f $localHost
            $res = 'SUCCESS'
            $dtl = $msg
        } else {
            $servicesVersion = $stampInformation.ServicesVersion
            try {
                $servicesVersionObj = [Version]::Parse($servicesVersion)
            }
            catch {
                $servicesVersionObj = $null
            }

            # Check for parsing versions errors
            if (-not $servicesVersionObj) {
                $rc += 1
                $res = ${resultSeverity}
                $msg = $lswTxt.ServicesVersionFailedToParse -f $localHost, $servicesVersion
                $dtl = $msg
            } else {
                $servicesVersionMinor = $servicesVersionObj.Minor
                if ($servicesVersionMinor -eq 2508) {
                    # 2508 services version, not supported.
                    $rc += 1
                    $res = ${resultSeverity}
                    $msg = $lswTxt.ServicesVersionWrong -f $localHost, $servicesVersion
                    $dtl = ''
                    $dtl += $msg
                    $dtl += "The services version is not supported in this Azure Local Update. "
                    $dtl += "Please follow this TSG to correct the stamp version: https://aka.ms/azhci-tsg-stampversion"
                    $remediation = "Please follow this TSG to correct the stamp version: https://aka.ms/azhci-tsg-stampversion"
                } else {
                    # Valid scenario
                    $res = 'SUCCESS'
                    $msg = $lswTxt.ServicesVersionSuccess -f $localHost, $servicesVersion
                    $dtl = $msg
                }
            }
        }

        $detailList.Add($dtl)
        $logLines.Add("${msg}|${res}")

        $response = "" | Select-Object -Property rc, details, computername, logLines, remediation
        $response.rc = $rc
        $response.details = $detailList
        $response.computername = $localHost
        $response.logLines = $logLines
        $response.remediation = $remediation
        return $response
    } #endSB
    $resultSeverity = "CRITICAL"
    $responses = Invoke-Command -ScriptBlock $sb -ArgumentList (,$lswTxt, $resultSeverity)
    $splat = @{responses   = $responses
        Name        = "AzStackHci_ValidatedRecipe_ServicesVersion"
        Title       = "Test Azure Local Services Version"
        DisplayName = "Test Azure Local Services Version"
        Severity    = $resultSeverity
        Description = "Validating that the services version is supported."
        Remediation = $responses.remediation
    }
    return (TestResult @splat)
}

Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDvFs/+wmGArkBg
# amMHef5LwBQlDh9vsozj/ZOJdlgA+qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGNCBjC8
# R89dMSy4FtEl8gHDu2te0ukENxIv9V7ScJYZMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEALO0rBtustr76QmiCfVn+dv8nYlsgYkAVFaxQgd7i
# zmK9CZ7AVffnQVFMFN7WEaYPcF5cDJ2wVtDU7bKyY6VoJtrtOk7ak4fsyPJw3SkR
# Nh05qNqhb9uswDO12r4d9sQlC5hcqr40uPO2NDbAR467E0vvL/ui0EIFREWivdEP
# ZGI88pDSwl6vpjcqrtoSO95ztKD0qEcewRqHBWvDlEMrWnSkS9AOY69UtFxotoWy
# Xw20BZMleT8dv+1XDcMN62c3pAU1D7oWt0I8dn6JHoUNYcFA5ZgFAMcT7Se6tq6O
# 9O8CVaqJgBZfuT1z5fgIMTCCdJx+oNLAbGlsIs/TsEDjbqGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBzP5WO+fCf1if81TqMnf9t48SJmfXQUUg/g/ne
# uwgq6AIGadfEjs1GGBMyMDI2MDUwMzE0MzExMC4zNDZaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiNP2WAkU8/+KwABAAAC
# IzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTdaFw0yNzA1MTcxOTM5NTdaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCK6Q2nk5WUdKzSCSafp+UjUARs
# WxHKS63rJhFC/zSabFumTBuaJ0QNrmqevub5Db7fSj5qtwwKnjIO92+HXF67192f
# ujL7DFot5WEj/AtEZ/XrzFHimKlN1h6gEQwP5I67wizaPW5ZzSBNpaLBg5oHvASP
# OZtwdNUoZ+DQKF3hJl1KZuoIlVK+qi7cLjgak6s5oOZcRCMrKnuC3aoVa6wRDbYv
# KUuj7rkFx9KO0PsHJ/k+LnZMggRheh4AVdawyh+oOzKPjlQGUNfSeWUgym2U9CLa
# 8tt0mQX4DxDz6+ram50gj1oAfyQ6TQ7r96PADFOKBgaU7+cpHnaZG89dTegQ6ydB
# RGIycOw1dRX2eKDRRzziK3cn0WaIm/7OeGsyQKjIzEQuUTDv0Jj/9zQ7truLOOpJ
# D98BJVOK7je84Sz2hb3HvUST7j1j2N8peD6olkpFHR/1Z8Jz4F+mkrUF7MmPAirY
# HRzunbIg3HrDMNwFYN7yBkDA4/VMo9CY0y9oGUoq2yjbCwTibz9VYl93nB3QQiTC
# T9nW3M+TOWB+PMrZpExq1BSHmKPzIqehKqrUDoM33PK+dEKwpYLET6uXq4HuQRMX
# WT//sPubUnQAaaUMfQhAZSy23HtxwtN3eK9+T4wCav2wQFt57eUOwUW5/DCzMF9t
# ua5He1hNvgcAXaiG1wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNbAh89v29nPY9bw
# Qb1QYCzxVgeXMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCHQwe7z5tp4NZwAf1c
# B+4c9J4svw3P6WqGBMxtqznS6DdzUzStXHCaPZhM41g1iKHNnmcnLjwLujOEaNjh
# SnUDiAZqQjW5ZapOBxgc7Egghh9k+r78qWAe3rJ4QohBbhSGdZtKivTRaeRqmnhy
# 8+ThrKhzCeEwaarXJimZwSpdQQUDbheWHeyAxASqultd5KO0m/UFvO03tfepqGXA
# 4tCg/WGECwKqOjJzpRAfPIB6y1HyVrk+vmL5rpEbTwwLOtX7WxFGG8+cYLk9HjaD
# kxraA/HYlKQRx1sdza+w/gulLwgOnByRJKF2rr8M7FNIlwoi6ywFpaNc8A7HewaG
# jgw/tfcE260I1XekGluANI9HnONOYWlI7BKBQbWE2teo6vsQ1Vg8B8rTZSePVdmX
# L1PPqqs3KVdFKM5kYocPCDM+6VL32IV96sESf2T7DjxanpCg2D2UYj4Z1i7cy8U1
# LLDGg55KWs4af2RRBjH2MulHgAmW5obKxiZCDQjRaroJ2XElXUhigE9BzvhCFbT/
# HDY2vpVpl5HnSpcCSxmL5i5lIT/xbAQMI7Luh75Xrm+IslfFWOGOGMlCp+24qEJE
# glXEP7xwsolNdBNndXihhyIefVGlI1DR7xGELiJrk8ifVWYo9XEbEXv/lbvp6F2R
# 2UsnweWckvq0y1HWnLHDqH6dPjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQA4RWFs+kTiZnoZiAj1BtYj8zCNaqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aE6szAiGA8y
# MDI2MDUwMzAzMDgzNVoYDzIwMjYwNTA0MDMwODM1WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoTqzAgEAMAoCAQACAgL2AgH/MAcCAQACAhJCMAoCBQDtoowzAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAK62FgK5K5XFuLoLHYR6IUW+ogJf
# KCdyOFrPfdTzuENPYK4pNJRhdSYBwZLnmbGbVkZDDTDbfoHKrru9aeR7Yz01YO+s
# KuJlnqXWr1KaCtN+3JD3UPXJVScMbMTniu6dkoWFw2h3TD8IvlxYAub419x2i42f
# Xee7sCLaYJYCyEYPuadY7XVpoveMOQeaaUy4CnFaXuxFE6H7kDC6MrIWN1G2mmkJ
# WNRsoKoA9Srs2ZfnRZuyX2F0j13KNLZ8Fy+lTnUATgAhEDJHsaKT+A2NJQumzsqy
# zINUNUVOO6KLYVQbO6Akb5xWoRsBzRw9dTPYNpAhbhqQtaoC3KGR899zWNsxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiNP
# 2WAkU8/+KwABAAACIzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDIniBvjVOKj9gacqr9XW9i/yhn
# xXd6cuFojwSqUENoUzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIJbwMywR
# bvcGiynjnwjAqcaD47yYvebKZRAvtEAR5u6zMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIjT9lgJFPP/isAAQAAAiMwIgQgit078tPa
# fcQnnQptmE1wsN7QTb6Exag5U1V1RqiSX9owDQYJKoZIhvcNAQELBQAEggIAJcCf
# LgfGAD1SDy+SvDsTyP+XyiA8oaDsw/c5yJ9OklHcBO76SgUbIrWZg+W1x6dgKvD4
# 3NH4vQ/Y1aqkfaA0S66UhZnnmA+/fOzVipR1qRlIe8YkwN/heha+yY16W4ZbOJ3H
# 1d0OJnRx5+TNNt2wXnXGTbgGGD6U5gGmBLiSstHQqfCk8Tbk/qdXprQlHCiG/N9I
# 1GLSmkKeiJBXkAO4DFJRSIUuddNpJ/pfB5vsNB+ZHKH5XZaWh4Etu6nuOhRfONi6
# iG+iMd5FqePGY+yXjTITrwicbC5aw/YzzLGtH5BX4+fOny1MIL5axiFQVtBK/vlk
# 2Z6Fx3g9ecvUUjXVEC0DrEFHtankKKFuydrWpwnQa4nlP3DuFGbgp47ZBjlmRmbS
# gmLmm1RXKcQMn0ynwPjIgnqR4c7Nn0ERVKjOvHnILLYhFOIw8IZyuZxqQYEvsyxt
# /2P5LI96iaVBm8z1M1O75++9AK2BBY+cjqAJwTFC6Qq0myNAShtQyC23X7Ou5TBa
# nkVivKJyrSRzCM6NemwfZMlqQUsRjw7EpL8bZrynyoQVt8vDJRa85CsKqrovNJPw
# Tfg3WmLmK0r/Qck2SYaiRYDX7L4/8Kwd/9Er/hZ4Ihk8VATRTIs1guymGlX453J8
# DnW+HdlbleC2EDwt9Gu671/q/0dL5VLxfLLydiU=
# SIG # End signature block
