<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
 # Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.HostTCPMetrics.Strings.psd1

 function Invoke-AzStackHciHostTCPMetricsValidation {
     <#
     .SYNOPSIS
        Perform AzStackHci HostTCPMetrics Validation
     .DESCRIPTION
        Performs HostTCPMetrics validation tests including:
          - Full mesh ping testing
          - Full mesh PsPing testing using the provided tool
          - Network storage connection validation
          - (Optionally) firewall port updates and session checks via helper functions

        The function dynamically determines the list of tests to run by checking for
        helper functions in the AzStackHci.HostTCPMetrics.Helpers module.

     .EXAMPLE
        # Using individual parameters for testing:
        $allServerSessions = New-PSSession -ComputerName ("server1", "server2") -Credential (Get-Credential)
        Invoke-AzStackHciHostTCPMetricsValidation -PSSession $allServerSessions"

     .INPUTS
        PSSession object(s) representing target servers.
     .OUTPUTS
        PSObject with test results.
     .LINK
        https://docs.microsoft.com/en-us/azure-stack/hci/manage/use-environment-checker?tabs=network
     #>
     param (

         # PSSession(s) to use for validation (required in both parameter sets)
         [Parameter(Mandatory = $true, HelpMessage = "Specify the PSSession(s) to perform validation from.")]
         [System.Management.Automation.Runspaces.PSSession[]]$PSSession,

         # Switch to return PSObject results rather than formatted output.
         [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
         [switch]$PassThru,

         # Tests to include from the HostTCPMetrics Helpers module (optional)
         [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
         [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.HostTCPMetrics.Helpers })]
         [string[]]$Include,

         # Tests to exclude from the HostTCPMetrics Helpers module (optional)
         [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
         [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.HostTCPMetrics.Helpers })]
         [string[]]$Exclude,

         # Directory path for log and report output
         [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output.")]
         [string]$OutputPath = (Join-Path -Path $env:TEMP -ChildPath "HostTCPMetricsValidation"),

         # Tool path for the PsPing executable
         [Parameter(Mandatory = $false, HelpMessage = "Path to the PsPing tool.")]
         [string]$localToolPath = "C:\Program Files\WindowsPowerShell\Modules\AzStackHci.EnvironmentChecker\PsPingTool\psping.exe",

         # TCP Port for Testing
         [Parameter(Mandatory = $false, HelpMessage = "TCP Port for Testing.")]
         [int]$Port = 8080,

         # Host Network Interface Name
         [Parameter(Mandatory = $false, HelpMessage = "Host Network Interface Name")]
         [string]$NICName = "ethernet",

         # Option to remove previous progress and create a clean report
         [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report.")]
         [switch]$CleanReport = $false,

         # Option to show only failed results
         [Parameter(Mandatory = $false, HelpMessage = "Show only failed results on screen.")]
         [switch]$ShowFailedOnly
     )

     $callingTestParam = @{
        PSSession                  = $PSSession
        OutputPath                  = $OutputPath
        localToolPath               = $localToolPath
        Port                        = $Port
        NICName                     = $NICName
    }

     try {
         $script:ErrorActionPreference = 'Stop'
         Set-AzStackHciOutputPath -Path $OutputPath

         Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru

         # Initialise reporting
         $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
         $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

         # Re-import the HostTCPMetrics Helpers module to ensure all functions are available
         Import-Module $PSScriptRoot\AzStackHci.HostTCPMetrics.Helpers.psm1 -DisableNameChecking -Global

         Write-Progress -Id 1 -Activity "Checking HostTCPMetrics Test Dependancies" -Status "Initializing" -PercentComplete 0 -ErrorAction SilentlyContinue

         $script:envchktestList = @(
             "Test-FullMeshTCP"
         )
         if ($Include) {
             $script:envchktestList = $script:envchktestList | Where-Object { $_ -in $Include }
         }
         if ($Exclude) {
             $script:envchktestList = $script:envchktestList | Where-Object { $_ -notin $Exclude }
         }

         $TotalTestCount = $script:envchktestList.Count

         # Run HostTCPMetrics tests
         $i = 0
         $Result = @()
         $ProgressActivity = "Validating AzStackHci HostTCPMetrics Data"
         Write-Progress -Id 1 -Activity $ProgressActivity -Status "Testing $ENV:ComputerName" -PercentComplete 0

         foreach ($test in $script:envchktestList) {
             $OpMsg = "Running HostTCPMetrics Test [$test] on $ENV:ComputerName"
             Log-Info -Message $OpMsg
             Write-Progress -Id 1 -Activity $ProgressActivity -Status $OpMsg -PercentComplete (($i++ / $TotalTestCount) * 100)

             # Prepare parameters for each test function by matching keys from our hashtable
             $invokeParameters = @{}
             Get-Command $test | Select-Object -ExpandProperty Parameters | Select-Object -ExpandProperty Keys | ForEach-Object {
                if ($callingTestParam.ContainsKey($_) -and
                $null -ne $callingTestParam[$_] -and
                ($callingTestParam[$_] -isnot [String] -or ![string]::IsNullOrWhiteSpace($callingTestParam[$_]))) {
                $invokeParameters[$_] = $callingTestParam[$_]
                }
            }

             Log-Info -Message ("Invoking $test with parameters:" + ($invokeParameters | Out-String))
             $Result += Invoke-Expression "$test @invokeParameters"
         }

         # Output results (formatted or as objects, based on $PassThru)
         Log-Info -Message "HostTCPMetrics Validation Completed" -ConsoleOut:(-not $PassThru)
         if (-not $PassThru) {
             Write-Progress -Id 3 -Activity "Formatting Results" -Status "Writing Results for $($ENV:ComputerNAME)" -PercentComplete 100 -ErrorAction SilentlyContinue
             Write-AzStackHciResult -Title "$($ENV:COMPUTERNAME):" -Result $Result -ShowFailedOnly:$ShowFailedOnly -Seperator ': '
             Write-Summary -Result $Result -Property1 Detail
         }
         else {
             return $Result
         }
     }
     catch {
         Log-Info -Message "" -ConsoleOut
         Log-Info -Message ("Error: " + $_.Exception.Message) -ConsoleOut -Type Error
         Log-Info -Message ("StackTrace: " + $_.ScriptStackTrace) -ConsoleOut -Type Error
         throw $_
     }
     finally {
         $script:ErrorActionPreference = 'SilentlyContinue'
         # Write results to telemetry
         foreach ($r in $Result) {
             Write-ETWResult -Result $r
         }
         # Finalize and write the report
         $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'HostTCPMetrics' -Value $Result -Force
         $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
         Write-AzStackHciEnvReport -report $envcheckerReport
         Write-AzStackHciFooter -invocation $MyInvocation -PassThru:$PassThru
     }
 }


# SIG # Begin signature block
# MIInRQYJKoZIhvcNAQcCoIInNjCCJzICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBycpRZ3CNL/uZj
# F9NqQOpdMsb4oGOsYRllaVy3PK97C6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnhMIIZ3QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHPI+hcs
# n4bpfB4hJKN9kYh9Tn/+GH4va1MTOg8J33vsMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAqKTn1JD80g2DbLbyigs5yAKAP9NLIcH+FGWmrEoW
# UpCj9C8dto3ZRiHIFHEH6KX8QofHBGol1yeIZ294yoULlJxeGadEQ5Gt+qszhUCk
# MGBQ7zPksnjhOsFsnOWcsEj5bqOKmvn9CVbFfrhdYp4zt1xZjs6EvgdrC228ARlJ
# kSNs0cx5EZmBzSOdE8JOGySIpUk5RwipIpXujd/eTODjcoe5ZionECbrGT6ViRC4
# vFmrJyXATqvipHfkkgiQP0qRU/n7uMhyOMW1tRLgZI/QgO3o1g6gEN0MJP4zkCoI
# rYEOvB1EK80zrQne98at6E0hWDpbYHOiIKAzjboVZsjTwaGCF5MwghePBgorBgEE
# AYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2wwghdoAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBNjfbiBsxRKkP4P6l07ELpvoJ1PqZOgJMSVIWH
# aRuDMAIGaedeW7IWGBIyMDI2MDUwMzE0MzExMC4wMVowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpBNDAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMzAAACKPClh9fzyB5AAAEAAAIo
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5NDAwNloXDTI3MDUxNzE5NDAwNlowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNDAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK6O9uT+ypwJJF5lol8K5/U3BFxz
# teSeETrCQuh+Q2PWbEQCDfmrLbFwWOCNqu1W8DT1bxAdynIypVJc5PE0cmyaTSo/
# YIMu9QC6VaDtpLmgE5GkRfWjPefRHac+p4fQgcrXMnGPFodbbUBu5nRn7AzdZg3O
# QGVweZV7TdkbuuWTbyHvavk/kwTwUakWZhbkeXumwpuAsR+tgCK2m22xv6xmwFQj
# 6EwqXi4slii0rJm/V7A4iKcF9FTxCiyK+Oh9oF7NR/011X6IataHfbVadKwrcD8m
# XoYu1tJZdwlZQuBvG6qehs8r5iUHfXvhMxZOBfhhaMbujQ63P+mMc0IoFsHvzx3K
# eEt0ZjoHTwT37hIatGmy3LiIkc7J0cIDkziLnJhHCx2636Ca/EilPzI1clyMkKDS
# 87ya/+cVj1bK2/aqYK0IUWK8ZRapTbT+xR5GihBkaJA4lCfT3kKPeKwiy9E/wpTu
# E38QMjwdWxv80/MwUu9HOetGePRM6cOI5NRydjCaT5d+hLWjCyRwIILAedsLTQPn
# zPzfLsrlkkHvjmFyfgITadHd7pEayvjbLmq23ox3P+zsxOcNLZSZUdZfVf8dl7dS
# VfyCP+3rcvnTEg+qREIER0zUAM1RpJ+j05CIpv9uPV2JkIZN8QNQEEuinWaGTAgX
# zZ9qmVXZu6xn5TiRAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUqsmljPjy3Oi69WQF
# W2EBIWlD3cMwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAJDo18uatFqGBW2BaDfz
# cZpLTt8fKh3puFxQ423a1637oFo24fSvsAGRUeF46nEF2tSs4RhURoiKL10rdy5k
# s2anWJQDH9VuY5liXvHP602uMJaquDWNCarShEHyIThAmnA2EY/ruhjmG5ghTQPi
# WEOhqGp+Aomf/QGT71QoM/DleVRiat4WYmWP1hDNw896nwzEFfGH9jkju9B5Fpbl
# KO2ItA4tGTeCC+toOzlJ/j0wlXr8HDFcLau9R8QVfpJQOiioogT02BUhGrRFm7s6
# 3SLQiz4e88/SEHorA7EyDVJYo59O0Wlal2jwwm+AoIeQ+lcTOCms/6nIge47uBVG
# VJOxtgEUuHbIh3+K0zi5gvRH7ZJIEFOlJJG2Gsa4SYSUjkEIczHMyD+iodI/BkAg
# CQzYLjHGLRK3uoy4D6b5nMViR+gXjVChImf4eOqGpZhDSb9I738qclEklTAx3lOI
# yeNn4T8MmJSvLm52JbJCm9+PaFAUjR2OFqGgBcNrN4RyIsXa4SdO6v1R+NzA66f+
# gxj5Qt+2c6LaMosyut5XT3tqTPP8nGmcOBglT+2BTt9B+WDsiqIv37Tbvr6OhAej
# bWZV5jlgPwqH+RRpjomb85Mzzwbt69PP+qdG6bGi9OMxK2+lsAc1GGZJN0g9NXfY
# LK7EMpL9XlrmLAD5/1WIGj7CMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
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
# M1izoXBm8qGCA00wggI1AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAHWtuYWTNLuoArU5q/TwBSeFs0hSoIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoaz2MCIYDzIw
# MjYwNTAzMTExNjA2WhgPMjAyNjA1MDQxMTE2MDZaMHQwOgYKKwYBBAGEWQoEATEs
# MCowCgIFAO2hrPYCAQAwBwIBAAICHfwwBwIBAAICE4wwCgIFAO2i/nYCAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAvCwvaZCaBeEQcg37dBxvx2idwiqz0ytH
# kt4lz7CQLW+/vt3RjB3KXZc0M0ImvOUBpaX52/8EUdMh1mP+sDj6Zgo33pRyLNUo
# JixtFmkBfeHs3AMciTdXZU1hQ3gQ07neIjvH5wfkIoJjXHrG4loa+KAv37Zj5xcQ
# FzKuI1h9wkv74BKp6CONR53FAbCvZtqGBQxCsEcx+2WKPgSOh3vMO9y2kFILH46g
# bvIQ6P3tQONH2MYaGyrUjepaKKpqfHzsUnXQsFqrDm+TlHE1ZYAesRQ4vv/4i1qq
# oKxwcXM+gy/nyab5yzJaM08HyRVWr3x+DcEUSe6e6i2VBFAVmeXUcTGCBA0wggQJ
# AgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAk
# BgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACKPClh9fz
# yB5AAAEAAAIoMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZI
# hvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEINcTUwdrSKUesi/dZRZ/NvmoC6Y/qHzM
# aLFedXZrI6KtMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgVbGKRlFgY1/i
# gRVkrV5Pjkf7cZDf+rFXvlXC4G36ItcwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDAiBCCngJvYXqC45nIN
# w/BRcmLSzsyfuqLajZnUFnktmUfbyzANBgkqhkiG9w0BAQsFAASCAgBsv+eWQbqd
# pLAzfEaqoTlQEPTPlDiuexIL9PJ9pZTYAuU98kxsLSCe6JhIgEN6oZSA/4+w5Bx9
# S4c5WeUczj2hdDiTMc5vY1W8ufVThYDrueJKHGj3ry0AlCHZPvgPf7gcFsA6NqUJ
# ZRSJptRomTwa5SI8EVx9Mzxi8CkB+qJdT+LBAniLTKcWWurSnFfFj3YW0HwpYc3j
# GTsDIHNaIssk4sX0V90JVs14ixppaF2SgrMS0xDz7K+YDBeBW2X/Ozjxe0P6fWLh
# x38Z5TElPCGHwZ5Z41vH7/L+AqCjG7GjvheCLXfCFXvPbv/DGAJ63v1VOKhOnNlw
# G7T/0Cn6SNvhUCu2C5oCSg8sI9bPmyFkAfLqSgrzyTkeXpN+/LSQNTY5GFGL918z
# vUfdDRQQKCNSFSrkr87jGIJw0Bcu2aeTAH9fiA8XYfhtBT19IX8oXIAufU3L86mf
# c1Mi8d/TUMdhkfV60d+sxFguO7d/laV+GybGBs0DSwbuQfLQBtiZFIeggzpE8sbI
# 7dk6SPXPIS5q/RD6c08esAVc5MJ2Hy4IBWXbEx0XKskMZ06oTIcK8kMpr7yxLRmB
# jMqQKjg1YIrzNSHOMleJfpz0pk14tYao5at69HuEW+4KziGp6IneNqXxeEbDiBFy
# yIK5611cXSqFkmluOgefEbc4nwFUQH6l6w==
# SIG # End signature block
