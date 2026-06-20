#############################################################>
#                                                           #
# Copyright (C) Microsoft Corporation. All rights reserved. #
#                                                           #
#############################################################>

Import-LocalizedData -BindingVariable lswTxt -FileName AzStackHci.Upgrade.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.Upgrade.Helpers.psm1 -DisableNameChecking -Global
Import-Module $PSScriptRoot\..\AzStackHciArcIntegration\AzStackHci.ArcIntegration.Helpers.psm1 -DisableNameChecking -Global

function Invoke-AzStackHciUpgradeValidation
{
    <#
    .SYNOPSIS
        Perform AzStackHci Upgrade Validation
    .DESCRIPTION
        Perform AzStackHci Upgrade Validation
    .EXAMPLE
        PS C:\> Invoke-AzStackHciUpgradeValidation
        Perform all Upgrade validations against localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer 10.0.0.4,10.0.0.5 -Credential $Credential
        PS C:\> $IPPoolsToCheck = New-Object System.Collections.ArrayList
        PS C:\> $ipPool = [PSCustomObject]@{ StartingAddress = "192.168.200.97"; EndingAddress = "192.168.200.115" }
        PS C:\> $IPPoolsToCheck.Add($ipPool)
        PS C:\> Invoke-AzStackHciUpgradeValidation -PsSession $RemoteSystemSession -IpPools $IPPoolsToCheck
        Perform all Upgrade validations pre-existing remote PS sessions.
    .PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
    .PARAMETER IpPools
        ArrayList. Contains elements of PSCustomObject with StartingAddress and EndingAddress properties.
            $IpPools = New-Object System.Collections.ArrayList
            $tempIpPool = [PSCustomObject]@{ StartingAddress = "192.168.299.97"; EndingAddress = "192.168.200.115" }
            $IpPools.Add($tempIpPool)
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
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Specify the PsSession(s) used to validation from.")]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the IP Pools to be verified.")]
        [System.Collections.ArrayList]
        $IpPools,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.Upgrade.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.Upgrade.Helpers) })]
        [string[]]
        $Include,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.Upgrade.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.Upgrade.Helpers) })]
        [string[]]
        $Exclude,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
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

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false
    )

    try
    {
        $script:ErrorActionPreference = 'Stop'
        Set-AzStackHciOutputPath -Path $OutputPath

        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependancies" -Status "Environment Configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        $testList = Get-TestListByFunction -ModuleName AzStackHci.Upgrade.Helpers
        #Importing specific case for testing brownfield upgrade
        $testAzureStackHCISubscriptionState = Get-TestListByFunction -prefix "Test-AzureStackHCISubscriptionState" -ModuleName AzStackHCI.ArcIntegration.Helpers
        $testExecutionList = $testList + $testAzureStackHCISubscriptionState
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $testExecutionList
        $totalTestCount = ($script:envchktestList).Count

        # Run validation
        $i = 0
        $Result = @()
        $ProgressActivity = "Checking AzStackHci Upgrade Compatibility"

        if ($PSSession)
        {
            $loggingMachines = $PsSession.ComputerName -join ','
        }
        else
        {
            $loggingMachines = $ENV:ComputerName
        }

        $ProgressStatus = "Testing $($loggingMachines)"
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }
        Write-Progress @progressParams

        :noTestsBreak foreach ($test in $script:envchktestList)
        {
            $OpMsg = "Checking {0} on {1}" -f $test, $loggingMachines
            Log-Info -Message $OpMsg
            Write-Progress @progressParams -CurrentOperation $OpMsg -PercentComplete (($i++ / $TotalTestCount) * 100)

            $splat = @{}
            Get-Command $test | Select-Object -ExpandProperty Parameters | Select-Object -ExpandProperty Keys | ForEach-Object {
                if ($PSBoundParameters[$PSITEM]) {
                    $splat += @{
                        $PSITEM = $PSBoundParameters[$PSITEM]
                    }
                }
            }

            $Result += Start-ValidatorTest -TestName $test -Parameters $splat -ValidatorName 'Upgrade' -EnableTelemetry
        }

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Upgrade Results'
            Write-AzStackHciResult -Title 'Upgrade' -result $Result
            Write-Summary -result $Result -property1 Detail
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
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'Upgrade' -Value $Result -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDwosuzBRyI6Ofi
# gRJ+7zZ2fYszKcY6RTUL3svbKTEZ56CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIJ+wQ2VY
# Bm/hb80BTac9ikQejkOaPdI699kKDPDETE7VMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEApjSAPKQrMBQZYjmTlWW72x2yImg7c1pOjQP9+j5U
# Eec90qbK9OZECX/x7fz9K/gnXqGqMf1CmrxL8I/TgeuIGXyNBKVj2Qco0soVLffQ
# 4pyUXWLXlQ9O/LZLgywTNRuktNnlpFuNLHKXDHvhXlGs3BBVFYGgH/ASXtQr9pvR
# eWSaP7feQ4Qm+bfRhCm37Xag71oX3oQ8hJIBm7EDuwMxsvtUlzUQX3M5OLbzhsFe
# ZGGWX40CQd3H01iZ3kgx08L1kf3MBTV1fpYaByjnZWyDqjlbK9sn5CELD/x256MY
# eOewjle2m9Dm4fcz81EXXPh7Tqux9I0ZdOBsPQH8c9HwoaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAcK+Hf+mC7Au5JAyzRJiTTxyZ3KlAddIX8a9qo
# mOErdAIGaefB+1SRGBMyMDI2MDUwMzE0MzExMC4zODJaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAEaBXwKqU78nwPvrwRQU0c2xeE
# mvGW53femeNrf2DgvTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILAkCt9W
# kCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wIgQgXDVXUUgM
# F2UJ5kLBUeKOgKL/uQDhW3pavs3L2zobM+AwDQYJKoZIhvcNAQELBQAEggIAGnNj
# FvuEYNl2pRBBd2E+9+Q0Vn+orpCNw8Z3ovuH5on0wa4+CrU5ulOhosw1pWqsQBuo
# w22eXUJEbRGspNf50dmuyO81D/ikl4QHsCmif/wA+wHlwvM48k6iQuYHoGrdkwMX
# Mtc6avoxXbd58UQsb5qbeDnPiNorfUi2cnDuxrySRIHeVcgxBP3+VnjDtAZ00iny
# 8huNJpuOVisKsPD928mqNzASdRT13KnGGRv8pnIKNUiYsB3+aiMABJae4Yncc3YA
# EP6lnjYv9Uij/661n4pTPNFCJnBJzP5yeOurwMcyov6q3wyYx/eNffCwt5DKJZMa
# D6J0P3N4sQ+6ab6rBrTQj3Zyzwx0wYUzq+WasNcyj5hV5fTa2kmB/9aq0Rhub+O/
# aNSAMtcalveJQRIR1l8rHHSDDGJxYN4KFBgJYo6d/OhYj/c1arAl2TOibO5wPf5H
# z83x8rJb6M7G4sPsZZ5fvMP5OCD5/Q98l/H6LYIiv/n/uGXd+uK1mW5sh4uQUedc
# 47TecpzD3A/WZg5vBkfDgZu7R+aZJJc7We2ArDzE/A6+vfCpXUsq45IXxS++HvwA
# yggO+ANAv5n1QPO/BNvTPw5fqYZys1drhraD2WsMVkZGFyBRwRM/tpEWry5hjXpb
# yywedW6HNsV6qkqExiZXCCjvW7CYcBxc0VoIEW0=
# SIG # End signature block
