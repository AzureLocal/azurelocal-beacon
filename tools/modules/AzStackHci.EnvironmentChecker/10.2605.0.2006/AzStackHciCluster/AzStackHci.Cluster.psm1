<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

Import-LocalizedData -BindingVariable lcluTxt -FileName AzStackHci.Cluster.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.Cluster.Helpers.psm1 -DisableNameChecking -Global

function Invoke-AzStackHciClusterValidation {
    <#
    .SYNOPSIS
        Perform AzStackHci Cluster Validation
    .DESCRIPTION
        Perform AzStackHci Cluster Validation
    .EXAMPLE
        PS C:\> Invoke-AzStackHciClusterValidation
        Perform all Cluster validations against localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer 10.0.0.4,10.0.0.5 -Credential $Credential
        PS C:\> Invoke-AzStackHciClusterValidation -PsSession $RemoteSystemSession
        Perform all Cluster validations pre-existing remote PS sessions.
    .PARAMETER PsSession
        Specify the PsSession(s) used to validation from.
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

        [Parameter(Mandatory = $false, HelpMessage = "Specify the Node(s) FQDN used to validate.")]
        [String[]]
        $Node,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.Cluster.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.Cluster.Helpers) })]
        [string[]]
        $Include,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzStackHci.Cluster.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzStackHci.Cluster.Helpers) })]
        [string[]]
        $Exclude,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Hardware class: Small, Medium, or Large")]
        [ValidateSet('Small', 'Medium', 'Large')]
        [String]
        $HardwareClass = "Medium",

        [Parameter(Mandatory = $false, HelpMessage = "Cluster Pattern: Standard, Stretch, or RackAware")]
        [ValidateSet('Standard', 'Stretch', 'RackAware')]
        [String]
        $ClusterPattern = "Standard",

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false,

        [Parameter(Mandatory = $true, HelpMessage = "Operation Type: Deployment or Upgrade")]
        [ValidateSet('Deployment', 'Upgrade', 'PreUpdate')]
        [string]$OperationType,

        [Parameter(Mandatory = $false, HelpMessage = "Storage Type: S2D or SAN")]
        [ValidateSet('S2D', 'SAN', '')]
        [string]$StorageType
    )

    try {
        $script:ErrorActionPreference = 'Stop'
        Set-AzStackHciOutputPath -Path $OutputPath

        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru
        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependancies" -Status "Environment Configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        $testList = Get-TestListByFunction -ModuleName AzStackHci.Cluster.Helpers
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $TestList
        $totalTestCount = ($script:envchktestList).Count

        # Run validation
        $i = 0
        $Result = @()
        $ProgressActivity = "Checking AzStackHci Cluster Compatibility"


        $ProgressStatus = "Testing $($PsSession.ComputerName -join ',')"
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }


        if (($OperationType -eq 'Upgrade') -or ($OperationType -eq 'PreUpdate')) {
            $clusterExistsResult = Validate-AzLocalClusterExists

            if ($clusterExistsResult.Status -ne "SUCCESS") {
                $Result += $clusterExistsResult
            }
        }

        if(((($OperationType -eq 'Upgrade') -or ($OperationType -eq 'PreUpdate')) -and $clusterExistsResult.Status -eq "SUCCESS") -or
           ($OperationType -eq 'Deployment')) {

            :noTestsBreak foreach ($test in $script:envchktestList) {
                $OpMsg = "Checking {0} on {1}" -f $test, ($PsSession.ComputerName -join ',')
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
                $Result += Start-ValidatorTest -TestName $test -Parameters $splat -ValidatorName 'Cluster' -EnableTelemetry
            }
        }

        # Feedback results - user scenario
        if (-not $PassThru) {
            Write-Host 'Cluster Results'
            Write-AzStackHciResult -Title 'Cluster' -Result $Result
            Write-Summary -Result $Result -Property1 Detail
        }
        else {
            return $Result
        }
    }
    catch {
        Log-Info -Message "" -ConsoleOut
        Log-Info -Message "$($_.Exception.Message)" -ConsoleOut -Type Error
        Log-Info -Message "$($_.ScriptStackTrace)" -ConsoleOut -Type Error
        $cmdletException = $_
        throw $_
    }
    finally {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        # Write result to telemetry channel
        foreach ($r in $result) {
            Write-ETWResult -Result $r
        }
        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'Cluster' -Value $Result -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAZ+AowoCR661br
# eVBMfQcGvNiSC7cAy4oz0aU61es/AaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIHzvSyTStVpqW0rFVIQ40p0EKeX0wI3/4FzJeOTWzubDMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAYS0DNcp47TwmTTtMU3QB
# axYXj7GvC8ttxAfO07YXo5msgBq2UPa1lHDNvCzo7Vy2HtbJElNyXCd9q5GI48Yv
# vFXGYaMlkyBlmz9yS1sSrAq915pj1+LHmYAcsfdPAuClaGAM6ySkfyfTRVk0obKU
# 4YeiV7G377PkbFfeapcL9s77BAYAcoUjTtayvv7LWczItcV8k2/+ThFT/CstTeZF
# ixyf1gjUCdz78LjwkADiMDJMFYi4mOrnzjZnyUtMv7+RCKONS9vI3mLqvW1a73sQ
# rQFiHllUmzEYUTtyPFn5MCneRkzvbakHHkinnLtcST1f0mbz+9Pa7D0H1JF836N3
# aqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAT3T51vDyS2NSznFGD
# Zx/SobUKyVr3rm5Gv29gCnEo1AIGaexvE19DGBMyMDI2MDUwMzE0MzEwOS45NDZa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACFRgD04EHJnxTAAEAAAIVMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyMFoXDTI2MTExMzE4
# NDgyMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjY1MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAw3HV3hVxL0lEYPV03XeNKZ517VIbgexhlDPdpXwDS0BYtxPw
# i4XYpZR1ld0u6cr2Xjuugdg50DUx5WHL0QhY2d9vkJSk02rE/75hcKt91m2Ih287
# QRxRMmFu3BF6466k8qp5uXtfe6uciq49YaS8p+dzv3uTarD4hQ8UT7La95pOJiRq
# xxd0qOGLECvHLEXPXioNSx9pyhzhm6lt7ezLxJeFVYtxShkavPoZN0dOCiYeh4Kg
# oKoyagzMuSiLCiMUW4Ue4Qsm658FJNGTNh7V5qXYVA6k5xjw5WeWdKOz0i9A5jBc
# bY9fVOo/cA8i1bytzcDTxb3nctcly8/OYeNstkab/Isq3Cxe1vq96fIHE1+ZGmJj
# ka1sodwqPycVp/2tb+BjulPL5D6rgUXTPF84U82RLKHV57bB8fHRpgnjcWBQuXPg
# VeSXpERWimt0NF2lCOLzqgrvS/vYqde5Ln9YlKKhAZ/xDE0TLIIr6+I/2JTtXP34
# nfjTENVqMBISWcakIxAwGb3RB5yHCxynIFNVLcfKAsEdC5U2em0fAvmVv0sonqnv
# 17cuaYi2eCLWhoK1Ic85Dw7s/lhcXrBpY4n/Rl5l3wHzs4vOIhu87DIy5QUaEupE
# syY0NWqgI4BWl6v1wgse+l8DWFeUXofhUuCgVTuTHN3K8idoMbn8Q3edUIECAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBSJIXfxcqAwFqGj9jdwQtdSqadj1zAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAd42HtV+kGbvxzLBTC5O7vkCIBPy/BwpjCzeL53hA
# iEOebp+VdNnwm9GVCfYq3KMfrj4UvKQTUAaS5Zkwe1gvZ3ljSSnCOyS5OwNu9dpg
# 3ww+QW2eOcSLkyVAWFrLn6Iig3TC/zWMvVhqXtdFhG2KJ1lSbN222csY3E3/BrGl
# uAlvET9gmxVyyxNy59/7JF5zIGcJibydxs94JL1BtPgXJOfZzQ+/3iTc6eDtmaWT
# 6DKdnJocp8wkXKWPIsBEfkD6k1Qitwvt0mHrORah75SjecOKt4oWayVLkPTho12e
# 0ongEg1cje5fxSZGthrMrWKvI4R7HEC7k8maH9ePA3ViH0CVSSOefaPTGMzIhHCo
# 5p3jG5SMcyO3eA9uEaYQJITJlLG3BwwGmypY7C/8/nj1SOhgx1HgJ0ywOJL9xfP4
# AOcWmCfbsqgGbCaC7WH5sINdzfMar8V7YNFqkbCGUKhc8GpIyE+MKnyVn33jsuaG
# AlNRg7dVRUSoYLJxvUsw9GOwyBpBwbE9sqOLm+HsO00oF23PMio7WFXcFTZAjp3u
# jihBAfLrXICgGOHPdkZ042u1LZqOcnlr3XzvgMe+mPPyasW8f0rtzJj3V5E/EKiy
# QlPxj9Mfq2x9himnlXWGZCVPeEBROrNbDYBfazTyLNCOTsRtksOSV3FBtPnpQtLN
# 754wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAj6eTejbuYE1Ifjbfrt6tXevCUSCggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2heQUwIhgPMjAyNjA1MDMw
# NzM0MjlaGA8yMDI2MDUwNDA3MzQyOVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aF5BQIBADAKAgEAAgIJowIB/zAHAgEAAgISdDAKAgUA7aLKhQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCrOcIVaAkw/PrB8wJN9p73l7REfyz7iPnOfU9C
# 8PEXMkvj+YPwV0roGlbTSNv0bidbON1MUk8WgjEFBBwSp/0k65COmh/ppW11Gl2S
# rfhOpprUrJmzOl1auKqxVTdbRE+CED52BnszfZrqmk4Mj238iP0VO6oxW9t4pfB/
# hVeTaf2igpMoTHdOoFV+wKOeDDk1XRR2+3GLmthZzSVSfvEqo+fD9Kpd8tmHsuW8
# ADnqYRlGxCwhDhsR5ElK105kpOGIj9VDNbwrvT9I6RLNj4Q/Dnhg8zRB5VtI807q
# MWC8EKhsvMP1XhuFuV78ZuFyXeV+XfS4jx/WoAJhJMAFiUNkMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIVGAPTgQcmfFMA
# AQAAAhUwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgzROXdKeC7Y9wPsHsPG9mHDrSrj4r47Zxl8XS
# 3/Y4l4wwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBwEPR2PDrTFLcrtQsK
# rUi7oz5JNRCF/KRHMihSNe7sijCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACFRgD04EHJnxTAAEAAAIVMCIEIBqc8pIbgkUBl+m5tNCz
# IFlR5RUBapAjgKe/JVm88ntNMA0GCSqGSIb3DQEBCwUABIICAGwcoTTsPjJPkoIm
# kLFnNhnXd4EDUm+mxDsHbMx3bntOgS0xpKkxcIeBIsYDTw+TJIF5oEPnC0pFtzyr
# CReKkOVAugJywQJVKWCfhyvm/4ccFad/zDfj8ChnCCCzCSy5JPd63lQ6Z41uRqei
# HGfAv6/wSY2LZFK/3SdHJrnQj0LK6QxcQv/Enmch46S3htC+nKsqopsqyLmyifmh
# E2w0DxypKkaorZhJEa+qIIneaKXFFmpxLpAkhNQKDt4NLpN0GC4hRZE1TW+ts9nM
# sjundLPuvpLnK788zqfXzeBzmWWtlmhvwVWH4m7TY9D6MpkN6B4HYDhyU2uknyNw
# 6UDrwSut3nKeeMCJdlIOzc0ImHm8JR5GdDzH3F/rl+5t2YOtIv4TU0sa1dgkNYZc
# SkUYMnymWu+2hT4sU5bVyQrJDj3S2w4yBLbGywik2rEb0NA847gH/fckTaBSwI5x
# AGY8VxBkOqpZQTchxoFbayepls1gdD6XNRNEUEhTJOzDRUuNPS06cOqFGqeARcgY
# E1+vsxF+Fu+zK5Rj2Oj7Zb20l+ls0jRNIme8q186wQSrdYfNmwGsKitXnbdT3xGW
# 3ta93RNdDork762TQAVwRIp/hYxdlYx5ArT5u8QcdMh+2F9gn3qtkMKowEJc4aBJ
# TvPFgFyXzXC+5dx1MHNqAzlQApZE
# SIG # End signature block
