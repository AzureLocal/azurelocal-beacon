<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

Import-Module $PSScriptRoot\AzStackHci.LLDP.Helpers.psm1 -DisableNameChecking

function Invoke-AzStackHciLLDPValidation
{
    <#
    .SYNOPSIS
        Perform AzStackHci LLDP Validation.
    .DESCRIPTION
        This function validates LLDP and network topology configurations.
        It can be run using a deployment answer file or by providing configuration objects directly.
    .PARAMETER DeployAnswerFile
        The full path to the deployment answer file (JSON). Use this for manual validation runs.
    .PARAMETER PSSession
        A required array of PowerShell sessions to the target nodes.
    .PARAMETER PhysicalNodeList
        An array of physical node objects. Required for the 'DirectParameters' set.
    .PARAMETER ClusterPattern
        The cluster pattern ('Standard', 'RackAware'). Required for the 'DirectParameters' set.
    .PARAMETER LocalAvailabilityZones
        An array of local availability zone objects. Required for 'RackAware' clusters in the 'DirectParameters' set.
    .EXAMPLE
        Invoke-AzStackHciLLDPValidation -DeployAnswerFile C:\config\unattended.json -PSSession $allNodeSessions

    .EXAMPLE
        Invoke-AzStackHciLLDPValidation -PSSession $allNodeSessions -PhysicalNodeList $nodes -ClusterPattern 'RackAware' -LocalAvailabilityZones $zones
    #>
    [CmdletBinding(DefaultParameterSetName = 'AnswerFile')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile', HelpMessage = "Specify the answer file used for deployment validation.")]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [System.String]
        $DeployAnswerFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'DirectParameters', HelpMessage = "Provide an array of physical node objects.")]
        [array]
        $PhysicalNodeList,

        [Parameter(Mandatory = $true, ParameterSetName = 'DirectParameters', HelpMessage = "Provide the cluster pattern ('Standard', 'RackAware').")]
        [ValidateSet('Standard', 'RackAware')]
        [string]
        $ClusterPattern,
        
        [Parameter(Mandatory = $false, ParameterSetName = 'DirectParameters', HelpMessage = "Provide an array of availability zone objects for RackAware clusters.")]
        [array]
        $LocalAvailabilityZones,

        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DirectParameters')]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PSSession,

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output.")]
        [string]
        $OutputPath,
        
        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [string[]]
        $Include,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [string[]]
        $Exclude,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result instead of formatted output.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report.")]
        [switch]
        $CleanReport = $false,

        [Parameter(Mandatory = $false, HelpMessage = "Show only failed results on screen.")]
        [switch]
        $ShowFailedOnly
    )

    $ProgressActivity = "Validating AzStackHci Network LLDP Data"

    try
    {
        $script:ErrorActionPreference = 'Stop'
        if ([string]::IsNullOrEmpty($OutputPath)) {
            $OutputPath = Join-Path -Path $env:TEMP -ChildPath "LLDPValidation"
        }
        
        Set-AzStackHciOutputPath -Path $OutputPath

        if (-not (Test-Path -Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru

        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        # This hashtable will be populated based on the parameter set used
        $callingTestParam = @{
            PSSession  = $PSSession
            OutputPath = $OutputPath
        }
        
        if ($PSCmdlet.ParameterSetName -eq 'AnswerFile') {
            Log-Info "Running with 'AnswerFile' parameter set. Parsing $DeployAnswerFile..."
            $deployAnswerFileContent = Get-Content $DeployAnswerFile -Raw | ConvertFrom-Json

            if ($deployAnswerFileContent -and $deployAnswerFileContent.scaleUnits) {
                $deploymentData = $deployAnswerFileContent.scaleUnits[0].deploymentData
                if ($deploymentData) {
                    $callingTestParam['PhysicalNodeList'] = $deploymentData.physicalNodes
                    $callingTestParam['ClusterPattern'] = 'Standard' # Default
                    if ($deploymentData.cluster -and $deploymentData.cluster.clusterPattern) {
                        $callingTestParam['ClusterPattern'] = $deploymentData.cluster.clusterPattern
                    }
                    if ($callingTestParam['ClusterPattern'] -eq 'RackAware') {
                        $callingTestParam['LocalAvailabilityZones'] = $deploymentData.localAvailabilityZones
                    }
                }
            }
        }
        else {
            Log-Info "Running with 'DirectParameters' parameter set."
            $callingTestParam['PhysicalNodeList'] = $PhysicalNodeList
            $callingTestParam['ClusterPattern'] = $ClusterPattern
            $callingTestParam['LocalAvailabilityZones'] = $LocalAvailabilityZones
        }
        
        $allPossibleTests = @( "Test-LLDPNbrTlvs", "Test-MergedLLDPDataToJson", "Test-LLDPConnections", "Test-LLDPDcbxConfiguration", "Test-LLDPAvailabilityZoneConnections", "Test-StandardClusterSwitchConsistency" )
        $script:envchktestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $allPossibleTests

        if (($script:envchktestList).Count -eq 0) {
            Log-Info "No LLDP tests selected to run."
            return
        }

        $Result = @()
        $progressParams = @{ Id = 1; Activity = $ProgressActivity; Status = "Starting..."; ErrorAction = 'SilentlyContinue' }
        Write-Progress @progressParams

        for ($i = 0; $i -lt ($script:envchktestList).Count; $i++)
        {
            $test = $script:envchktestList[$i]
            $OpMsg = "Running LLDP test [{0}]" -f $test
            Log-Info -Message $OpMsg
            Write-Progress @progressParams -CurrentOperation $OpMsg -PercentComplete ((($i + 1) / ($script:envchktestList).Count) * 100)

            $invokeParameters = @{}
            $commandParams = (Get-Command $test).Parameters.Keys
            foreach ($paramName in $commandParams) {
                if ($callingTestParam.ContainsKey($paramName) -and ($null -ne $callingTestParam[$paramName])) {
                    $invokeParameters[$paramName] = $callingTestParam[$paramName]
                }
            }
            
            $testResult = & $test @invokeParameters
            if ($testResult) {
                foreach ($r in @($testResult)) { $Result += $r }
            }
        }

        if (-not $PassThru)
        {
            Write-AzStackHciResult -Title "LLDP Validation Results" -Result $Result -ShowFailedOnly:$ShowFailedOnly -Seperator ': '
            Write-Summary -Result $Result -Property1 Detail
        }
        else
        {
            return $Result
        }
    }
    catch
    {
        $cmdletException = $_
        throw $_
    }
    finally
    {
        $Script:ErrorActionPreference = 'Continue'
        # Clear the in-memory data cache to free memory
        Clear-LLDPDataCache
        foreach ($r in $Result) { Write-ETWResult -Result $r }
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'LLDP' -Value $Result -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
        Write-Progress -Id 1 -Activity $ProgressActivity -Completed -ErrorAction SilentlyContinue
    }
}
# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC6sDiGUAefgflM
# xjIkbUQw8RJabUpNAcrxKFt1rB/8VKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn7MIIZ9wIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIGFrJFZMyUBTcvcSH8WQZaECL32gD4fMrmiBIgjlRDGNMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAY6MdnlsffNLFf3T99E9Y
# KyXtpeYruqifZKyJX5JafGl2jST8FwX4/XpqmUNNDNhxJXZySARNQ8KE8CIpgYbV
# zRG8lBrM18Z5PNnm7NtsuVB2/W5kIM/d2asz0vHl2y+JGlDJyp+qpgiiCBz7FEdr
# cWpdIXDzgQcZun7X7Vy3C5DoRw23BTPSU6rviEFHO9Oyt4N7PQQHUcfiCsaYOme2
# EKtDKqk6zSa/Edv9oceN7Zxc5AxK+hD9jIo6oW1Wp0t/fzxyPpvqp+b6XEJ4Uyez
# G7Fbvqs6KeyV+4P0cQy7RUb1PEUrBBD11XCG4pO3BcvyAhW9bHcFTzXw6S4ARevA
# Z6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBsbDDD9WEjNSxlJgGF
# RJyHtTcvlQJRSABqYh+Up3JJ7QIGaewquMvAGBMyMDI2MDUwMzE0MzExMC44MjJa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1OTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACFI3NI0TuBt9yAAEAAAIUMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxOFoXDTI2MTExMzE4
# NDgxOFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjU5MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAyU+nWgCUyvfyGP1zTFkLkdgOutXcVteP/0CeXfrF/66chKl4
# /MZDCQ6E8Ur4kqgCxQvef7Lg1gfso1EWWKG6vix1VxtvO1kPGK4PZKmOeoeL68F6
# +Mw2ERPy4BL2vJKf6Lo5Z7X0xkRjtcvfM9T0HDgfHUW6z1CbgQiqrExs2NH27rWp
# UkyTYrMG6TXy39+GdMOTgXyUDiRGVHAy3EqYNw3zSWusn0zedl6a/1DbnXIcvn9F
# aHzd/96EPNBOCd2vOpS0Ck7kgkjVxwOptsWa8I+m+DA43cwlErPaId84GbdGzo3V
# oO7YhCmQIoRab0d8or5Pmyg+VMl8jeoN9SeUxVZpBI/cQ4TXXKlLDkfbzzSQriVi
# QGJGJLtKS3DTVNuBqpjXLdu2p2Yq9ODPqZCoiNBh4CB6X2iLYUSO8tmbUVLMMEeg
# bvHSLXQR88QNICjFoBBDCDydoTo9/TNkq80mO77wDM04tPdvbMmxT01GTod60JJx
# UGmMTgseghdBGjkN+D6GsUpY7ta7hP9PzLrs+Alxu46XT217bBn6EwJsAYAc9C28
# mKRUcoIZWQRb+McoZaSu2EcSzuIlAaNIQNtGlz2PF3foSeGmc/V7gCGs8AHkiKwX
# zJSPftnsH8O/R3pJw2D/2hHE3JzxH2SrLX1FdI7Drw145PkL0hbFL6MVCCkCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBTbX/bs1cSpyTYnYuf/Mt9CPNhwGzAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAP3xp9D4Gu0SH9B+1JH0hswFquINaTT+RjpfEr8Um
# UOeDl4U5uV+i28/eSYXMxgem3yBZywYDyvf4qMXUvbDcllNqRyL2Rv8jSu8wclt/
# VS1+c5cVCJfM+WHvkUr+dCfUlOy9n4exCPX1L6uWwFH5eoFfqPEp3Fw30irMN2So
# nHBK3mB8vDj3D80oJKqe2tatO38yMTiREdC2HD7eVIUWL7d54UtoYxzwkJN1t7gE
# EGosgBpdmwKVYYDO1USWSNmZELglYA4LoVoGDuWbN7mD8VozYBsfkZarOyrJYlF/
# UCDZLB8XaLfrMfMyZTMCOuEuPD4zj8jy/Jt40clrIW04cvLhkhkydBzcrmC2HxeE
# 36gJsh+jzmivS9YvyiPhLkom1FP0DIFr4VlqyXHKagrtnqSF8QyEpqtQS7wS7ZzZ
# F0eZe0fsYD0J1RarbVuDxmWsq45n1vjRdontuGUdmrG2OGeKd8AtiNghfnabVBbg
# pYgcx/eLyW/n40eTbKIlsm0cseyuWvYFyOqQXjoWtL4/sUHxlWIsrjnNarNr+POk
# L8C1jGBCJuvm0UYgjhIaL+XBXavrbOtX9mrZ3y8GQDxWXn3mhqM21ZcGk83xSRqB
# 9ecfGYNRG6g65v635gSzUmBKZWWcDNzwAoxsgEjTFXz6ahfyrBLqshrjJXPKfO+9
# Ar8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCCAj4C
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1OTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUA2RysX196RXLTwA/P8RFWdUTpUsaggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hNKgwIhgPMjAyNjA1MDMw
# MjQyNDhaGA8yMDI2MDUwNDAyNDI0OFowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7aE0qAIBADAHAgEAAgIA/DAHAgEAAgISUTAKAgUA7aKGKAIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQAc2Yzc77kwZuH46ShXvStPqvvycwk+yq9klOHFkRvR
# PgLHSofJciKLjwGzsi0wfb5jadJcoJxDENCEmkR/WpPliL61hemoHY/2cMGp7s5i
# 5jdqptQRrhwNBAZuRVAqB/EaG1AC6FNJhSM2xyaLEaRI6HWU6gDfuj1L0aCm3++b
# yPA6EH8tn5NVw4H4WdeLe99pW6k6PAMqgO+gj2QNX+TGgrABvYmUDbHunEyabbrZ
# rhZjJ2n0QwoDUeST9eIvD+nKNs6FxbnjCZ08rL61Z2AZM+k3BFBREhhVtdN/7Xvk
# k6ipnYxlAiF9uqOd3Cyjwb7P34igT8weR0PntEH6Rx+DMYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIUjc0jRO4G33IAAQAA
# AhQwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgugdYjLetIw8KIyW0lAcXqcWPmM3iLJZm9m+Nlbqy
# UCowgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCA2eKvvWx5bcoi43bRO3+Et
# tQUCvyeD2dbXy/6+0xK+xzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACFI3NI0TuBt9yAAEAAAIUMCIEIIuYD1reuH7VxpqskBn7uksa
# ptLeODyj6FjPBUD6JIKNMA0GCSqGSIb3DQEBCwUABIICAHnYw9atCT639eujptnX
# QggSY3gVQq6kL/gIxIl2B0chKLCWTREWHbYSK2gn2RB2IG57P1gnezR9cNkFwa8q
# bi4iJX9YAnGOq1MgT7DzcGX79mCedIpnB+4euzLOABdi2VEOV+larKgYu+VlEl7d
# 3TIoFxPM9k+ie5JwwsvaFS5Dv6EKZIQZIpMnK4FfRybutl06XL35uicyZkV5KWlL
# 8p7RWTdVtR/7H1l8ANC90LP5PTxCNZO5+gn7mlWEYsRwAQH/kQpn0wp1EgRQZxLv
# SzJ6srXAnRAkN1+NC5k1GmDHg4GxBFuyZZTJ5qdxx51zr+GbuNadxb3x3j6vBPri
# rzbdpbRAurIgDDI0NCoxPkSVbo+s/QmYt9jtFlrdjKsHhfEMLEcQh/cmNmJk2jlz
# 1ALSDq8NX4d+qddZ/ZX0OwnyRsBy8Zixat/lrqehug6FNlVY8mpD+q1vAoajihAn
# wZn8veebXcOxqF0hSWIrzMYA1f241U7Wd8Ab0ikSe3c2/wCg+zjvyBpMajMRHkGu
# fSiQ3k67Er+SUF8khY2l1Qn/jJBSTeOLbBIsAdOKMglpbyMfQJk8xNiZ6V7CtXwm
# ZwUftDWkvuLQbf/eu/eSNbUIdAPrAeoN/N046J2okTreOmP8g8a+s4nkYOgeUNdL
# fR6bmom3FlKlnzxT0KTMTjnZ
# SIG # End signature block
