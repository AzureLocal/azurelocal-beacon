<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-LocalizedData -BindingVariable lanTxt -FileName AzStackHci.AddNode.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.AddNode.Helpers.psm1 -DisableNameChecking -Global

function Invoke-AzStackHciAddNodeValidation
{
    <#
    .SYNOPSIS
        Perform AzStackHci AddNode Validation
    .DESCRIPTION
        Perform AzStackHci AddNode Validation
    .EXAMPLE
        PS C:\> $AdCredential = Get-Credential -Message "Credential for Active Directory"
        PS C:\> $LocalCredential = Get-Credential -Message "Credential for new node"
        PS C:\> Invoke-AzStackHciAddNodeValidation -ComputerName Node05 -ActiveDirectoryCredential $AdCredential -LocalCredential $LocalCredential -Ip 192.168.1.5
        Perform all AddNode validations.
    .PARAMETER ComputerName
        ComputerName for new node(s)
    .PARAMETER ActiveDirectoryCredential
        Credential for Active Directory
    .PARAMETER LocalCredential
        Local credential for new node
    .PARAMETER Ip
        IP Address for new node. String because it could be host name
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
        [Parameter(Mandatory = $true, HelpMessage = "ComputerName for new node")]
        [string[]]
        $ComputerName,

        [Parameter(Mandatory = $true, HelpMessage = "Credential for Active Directory")]
        [pscredential]
        $ActiveDirectoryCredential,

        [Parameter(Mandatory = $true, HelpMessage = "Local credential for new node")]
        [pscredential]
        $LocalCredential,

        [Parameter(Mandatory = $false, HelpMessage = "IP Address for new node")]
        [string[]]
        $Ipv4OrHostName,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.AddNode.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.AddNode.Helpers) })]
        [string[]]
        $Include,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.AddNode.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.AddNode.Helpers) })]
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
        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependancies" -Status "Environment Configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        $testList = Get-TestListByFunction -ModuleName AzStackHci.AddNode.Helpers
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $TestList
        $totalTestCount = ($script:envchktestList).Count

        # Run validation
        $i = 0
        $Result = @()
        $ProgressActivity = "Checking AzStackHci AddNode Compatibility"
        $i = 0
        $ProgressStatus = "Testing $ENV:ComputerName"
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }
        Write-Progress @progressParams

        # Makes sure IP is in trusted hosts
        Set-TrustedHosts -Nodes $Ipv4OrHostName,$ComputerName

        :noTestsBreak foreach ($test in $script:envchktestList)
        {
            $OpMsg = "Checking {0} on {1}" -f $test, $ENV:ComputerName
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
            Write-Host 'AddNode Results'
            Write-AzStackHciResult -Title 'AddNode' -Result $Result
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
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'AddNode' -Value $Result -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA0s4M+RTmtfiGE
# +s+2eNb4sE5hWHCJRul8yyguFHyEg6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPrb0jhJ
# 87O+a5o+zxyl7KYtk/HmCqYZ43nN4lbGTLl4MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEArCoRRmiXYlIxeSGDFZuv1McUQftsnavt+7zY3fSB
# 3fB6qA5kdVt2+dFyob1AX4BQYTgRj3prZdqBhupZJ2SJPPrD/Q7XbtxMZJip+YOk
# g5SMAfi1qOwSNQGDSvPiMIsonyyTASIC1aE/l1TncbnF57SYPbQazg2RlJXJxCDM
# G3ZRWvZ1MX7EKpA7llsdOLvqOSj+tWjN9s2ujPrcd6zUNEqPdOsFxpmlmMRWwhCO
# SgnF419BAOzl4Zb2NjhOIcPL1Kib6H0ZmruUfy6hf9vvf/em+GYBlkTQr49w1oxm
# ycXFnpy9qJB/Bf4tJjOV45ODms062lTgaIOPKvwiIRTVr6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDuiwRvMpXgGJFaVXmpE3TtZMBl8ZjeLTDV3Ooo
# ZLdW2AIGaegM03WYGBMyMDI2MDUwMzE0MzExMi42MTFaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiEzwDX70g8hpAABAAAC
# ITANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTRaFw0yNzA1MTcxOTM5NTRaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDbcTACqU1YvRocyWL2PL9fyf/+
# ULs2qK7U1aZsRnDZSnlCr7K7jgA3eFCEJL5BZ7dUTC0DeZepf+ZC+7HEbB4IdzmJ
# fQAUDFFerqY5VTHmQvP2XA3lWSFj740idcGUHglP5H/PbCJU7GAHWP2HdcCjdx1l
# YAo0A+zLI7xwnTQeMyOXX212Eg4UmDPPJgxdTMw6WFVWsBPWRBi5gDixy2s+7R8A
# Dk5lbBBFDB5h0CjrNWIN7uCAzF5g7trrL8nXIKp10mj9RxhcGQ+tlht6VIvdygRV
# TUGdzFB2/nBvJqQ9kxxFltQST70fEdx4TyaKow/f5+BSh4z4/9f7NXIVVTLn/8kc
# JAfRqFmRrrFt3IKby7VrzmYuoQWD0lmNFtGQ57BrJkPrPFAPek1ALtcbb7FH3nQp
# vi8ngz/MFX/+cnmNFWFU29VVLmzB9XvLZxbYvkeett0mh5lfteeN2rEwUyrdrKuf
# z9h2S6pbate+C2h02CrXwSka0x6ezpTmGkIJLFt25ub/UYXNLdHdsxGD6EfckOIo
# JYsm4MS9F/vSqLNHK89I0vTLBngQEp6LIFkINanRT3PtNx3pNKRKJRALc6L6mhW4
# hL4aHL749qPfQ72t5qAMm5xiKYMgJ2WanidRLNuI251JIN7raaeA/2vb0XFkZcIb
# TR1pfQGsco4U0g5tjwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFOYjIs5qa6pfuquP
# yyK1FTr5QDCnMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQA4I/3bkdnTxD2rFum3
# MF8xVKdEkohAObbePrQ+0fr5bRimjz9sVkKT/7gcj4OMcClSYG+IdX6Mp3EYsLHW
# fjvwfzFoeZE+yTbdBj/1VHZQRuCmw6QqeVCTbw2nnS7nBxnWd9oZXbPUpqEawH5D
# qXQaWFgR9A4KWVK/IvXVDMj1PlPCES1P3JonNbdhkkkz49rJuKOm5b7e/BH8loqA
# mXOXRc22yxWVTMWrEp4pslmv8eT7VoY8X/jdKYTPVEXsfmLbVFcqzMuB8vFGfUyW
# sWROS8wgq7lQYfWcYqh7NymoATX+wWYK3zWG7aRciPGUAzznXdf+aHtIWnQLNa5H
# FmSXkiak3fSuprWYZiHhuYjE16hroApcBHpm+8S/kNqhm9WjQX+2BxnYv+Jejy6l
# qTi8fLBLS069WXVw/ptf5IV+FtYl34GvVoeg31UoUmVVZe1SDUJkm9dDXc8l/qBD
# YiAIT2CCsPTyt9XA9JVuHxdP63n7ChvWAO/47QRuCDsUlFJoWwyBwl7jeYpaRVMt
# Qt0iuJMGGjgEaJX1Q/2j8sXURvTceLHDD9ipWt092ZDWMQciDRmhHNFOX1dnjBvk
# /k1UMcg997j5oYznAnSpJvlg/4BP3aVE0h/YH2KgsKbU4NXZHAjJXj2Slqo1C115
# CG6qBZaFkM8W6vPZCm5qnSezOjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjMzMDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQALbEgZZnyYHXJ1DGb5fGjplXptuaCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aGyxzAiGA8y
# MDI2MDUwMzExNDA1NVoYDzIwMjYwNTA0MTE0MDU1WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtobLHAgEAMAoCAQACAglXAgH/MAcCAQACAhOvMAoCBQDtowRHAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBADrGuHPpc7CeLu8TiUQIOPBAH+XX
# ntp7jRQ6kuvBm7pyizTdh3iRKmccniCk7tIGNSi4ChdtPPmfxxgZQ33ThrSIdUad
# M0/EgrFbxfrrV3XZEUwBduweHL62/Kq1K/6banl6KVW/JT/jMbxb+qiIbuU0LY8i
# jJDxYSWfNS+0Cb2zPBgdS1dowQ58xv4jzNOYIjCbZP+r9YXSa/skn8Nc4+qGAw5d
# 1njWKiZq9/VPPWP80hdObwETV+p5vG0UTAH9qxaLhIVCIHcQedEu5juE3dvIBD0K
# 0wU2s2B2ByKk+2+E4AvR8tXGBI+TsWXqR9DvLrzNq7VOjdOOpNDDkntO1UcxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiEz
# wDX70g8hpAABAAACITANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBixB1o8QVy2oxHwkyHzl1PLqXY
# k5crLl5WX69wg6+NrzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIADvIQef
# FVUa4BJy8IZywMAvmGSKdUVqEmy9A++PCj1EMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIhM8A1+9IPIaQAAQAAAiEwIgQgIw9s0ghY
# /2NfQQlEyV4KLOoV/KIa0Z1/P1GDErJ2ajIwDQYJKoZIhvcNAQELBQAEggIAgKJR
# YPGJAc4AYuaFeOVziyH0N4435xUSwFfp5SkyigvuUiSpXA/lKxGYkzizHcyN7c/e
# CSNcVJD9hJ6CEP9XIPDDK0D7mRJHnJ/DATULpx28k8ahk1wm7uP0PiUz32zYVwvV
# n+QK7u9Lq1ziNmqaclidnBC8EslnV2TCSJc/Qz6IG4sJBCCLUM/E6SrMCdRsMfnm
# mCsbA4u8nnuCtaCUvDmB7VNuc+iEi7IQl4dOhuig6er0b+7SuNlZ1XOEEDlJRgVX
# oAPEOVZSKZG/E4Isg+Im3k3UT5JVK78BCnwI19/pD/lBP+aEY3P6VtNHHJddEovr
# vOBYeE6vOVLrnG9NLdt5qCzDje6sccP5pq7b0c7Owvdc5CmOAemGAC7UbyM1dfFa
# T6nQ9rXol17ORLc+AdM9C/AXdxQif+mEZWwggDRlIY3Qz7wX9HU3fEOKqbQTNiJz
# /mf79K7iRnuYzdc7amdZyLBa05iJ++TiQ8SEl5f86StbJaMPWpnWTkPRA0OkkNar
# kpNFc6EAEH0FjRjeiP/IXAHPvXEnvyc4tPS4dP2KTNloM4o7Ue7VmHlZjiijrLPm
# GxZr2bIwJ/VtHD/BYS19wEGu7miBGGYvDrRKnHSrY5gAwdgfvb5UmiZjmaf8iJb2
# ZLRgkntfKRlW1GqOdF6GQK27B6GYaONjAbdhzck=
# SIG # End signature block
