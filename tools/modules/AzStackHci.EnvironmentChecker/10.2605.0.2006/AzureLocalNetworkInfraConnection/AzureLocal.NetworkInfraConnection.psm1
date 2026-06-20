<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-LocalizedData -BindingVariable lnTxt -FileName AzureLocal.NetworkInfraConnection.Strings.psd1
Import-Module $PSScriptRoot\AzureLocal.NetworkInfraConnection.Helpers.psm1 -DisableNameChecking -Global
Import-Module $PSScriptRoot\..\AzStackHciConnectivity\AzStackHci.Connectivity.Helpers.psm1 -DisableNameChecking -Global



function Invoke-AzStackHciNetworkInfraConnectionValidation
{
    <#
    .SYNOPSIS
        Perform Azure Local network connection validation
    .DESCRIPTION
        Perform Azure Local network connection validation by attempting below tests:
        - Validate infrastructure IP pool connectivity to public endpoints needed for Azure Local to run
    .EXAMPLE
        # Using a deployment answer file to validate network configurations

        $answerFilePath = "<ANSWER_FILE_LOCATION>" # Like C:\MASLogs\Unattended-2024-07-18-20-44-48.json
        Invoke-AzStackHciNetworkInfraConnectionValidation -DeployAnswerFile $answerFilePath -ProxyEnabled $false
    .EXAMPLE
        # Using individual parameter to validate network configurations

        $answerFilePath = "<ANSWER_FILE_LOCATION>"
        $logOutputPath = "<LOG_FILE_LOCATION>"
        $answerFileContent = Get-Content $answerFilePath -Raw | ConvertFrom-Json
        $ipPools = New-Object System.Collections.ArrayList
        foreach ($ipPool in $answerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].ipPools) {
            $currentPoolObject = [PSCustomObject] @{
                StartingAddress =  $ipPool.StartingAddress
                EndingAddress= $ipPool.EndingAddress
            }
            $ipPools.Add($currentPoolObject)
        }
        [PSObject] $atcHostNetworkInfo = $answerFileContent.scaleUnits[0].deploymentData.hostNetwork
        Invoke-AzStackHciNetworkInfraConnectionValidation -IpPools $ipPools -OutputPath $logOutputPath -HostNetworkInfo $atcHostNetworkInfo
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
    .LINK
        https://docs.microsoft.com/en-us/azure-stack/hci/manage/use-environment-checker?tabs=network
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "Specify PSObject array of ATC Host Intents.")]
        [PSObject[]] $AtcHostIntents,

        [Parameter(Mandatory = $true, ParameterSetName = 'EceParameter', HelpMessage = "Specify end infra IP Range pools")]
        [System.Collections.ArrayList] $IpPools,

        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile', HelpMessage = "System proxy information")]
        [Parameter(Mandatory = $false, ParameterSetName = 'EceParameter', HelpMessage = "System proxy information")]
        [System.Boolean] $ProxyEnabled,

        [Parameter(Mandatory = $true, ParameterSetName = 'AnswerFile', HelpMessage = "Specify the answer file used for deployment validation.")]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [System.String] $DeployAnswerFile,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the region name to target for connectivity validation.")]
        [System.String] $RegionName,

        [Parameter(Mandatory = $false, HelpMessage = "Tests to include.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzureLocal.NetworkInfraConnection.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzureLocal.NetworkInfraConnection.Helpers) })]
        [System.String[]] $Include = @(),

        [Parameter(Mandatory = $false, HelpMessage = "Tests to exclude.")]
        [ArgumentCompleter({ Get-TestListByFunction -ModuleName AzureLocal.NetworkInfraConnection.Helpers })]
        [ValidateScript({ $_ -in (Get-TestListByFunction -ModuleName AzureLocal.NetworkInfraConnection.Helpers) })]
        [System.String[]] $Exclude = @(),

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [Switch] $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Hardware class: Small, Medium, or Large")]
        [ValidateSet('Small', 'Medium', 'Large')]
        [System.String] $HardwareClass = "Medium",

        [Parameter(Mandatory = $false, HelpMessage = "Cluster Pattern: Standard, Stretch, or RackAware")]
        [ValidateSet('Standard', 'Stretch', 'RackAware')]
        [System.String] $ClusterPattern = "Standard",

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [System.String] $OutputPath,

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [Switch] $CleanReport = $false,

        [Parameter(Mandatory = $false, HelpMessage = "Show only failed results on screen.")]
        [Switch] $ShowFailedOnly,

        [Parameter(Mandatory = $false, HelpMessage = "Indicating Operation Type")]
        [ValidateSet('AddNode', 'Deployment', 'Upgrade', 'PreUpdate')]
        [System.String]$OperationType = "Deployment"
    )

    $callingTestParam = @{}

    # Prepare validator call parameters
    switch ($PSCmdlet.ParameterSetName) {
        "AnswerFile" {
            # If the function is called with the AnswerFile parameter set, we need to set the other parameters
            Log-Info -Message "Performing Network Connection Validation using AnswerFile"
            $deployAnswerFileContent = Get-Content $DeployAnswerFile -Raw | ConvertFrom-Json

            Log-Info -Message "Get ATC intent info from answer file `"infrastructureNetwork | ipPools`" section"
            [PSObject] $hostNetworkInfoFromAnswerFile = $deployAnswerFileContent.scaleUnits[0].deploymentData.hostNetwork
            [PSObject[]] $atcHostIntentsInfo = $hostNetworkInfoFromAnswerFile.intents

            Log-Info -Message "Get IpPools info from answer file `"infrastructureNetwork | ipPools`" section"
            $allIpPools = New-Object System.Collections.ArrayList
            foreach ($ipPool in $deployAnswerFileContent.scaleUnits[0].deploymentData.infrastructureNetwork[0].ipPools) {
                $currentPoolObject = [PSCustomObject] @{
                    StartingAddress =  $ipPool.StartingAddress
                    EndingAddress= $ipPool.EndingAddress
                }

                $allIpPools.Add($currentPoolObject)
            }

            $callingTestParam = @{
                AtcHostIntents = $atcHostIntentsInfo
                IpPools = $allIpPools
                ProxyEnabled = $ProxyEnabled
                RegionName = $RegionName
            }
        }
        "EceParameter" {
            Log-Info -Message "Performing Network Connection Validation using ECE parameters"
            $callingTestParam = @{
                AtcHostIntents = $AtcHostIntents
                IpPools = $IpPools
                ProxyEnabled = $ProxyEnabled
                RegionName = $RegionName
            }
        }
    }

    try {
        $script:ErrorActionPreference = 'Stop'

        #region Get Include/Exclude list based on OperationType
        Log-Info -Message "[NetworkInfraConnectionValidator] Scenario [$($OperationType)]"
        switch ($OperationType)
        {
            "Deployment" {
                Log-Info -Message "Will check all infra connection needed for a successful deployment"

                if (Get-AzStackHciARCGatewaySetting) {
                    # Deployment with ArcGateway enabled, will skip Test-NwkInfraConnectionValidator_InfraIpPoolConnection
                    Log-Info -Message "Deployment with ArcGateway enabled, will skip Test-NwkInfraConnectionValidator_InfraIpPoolConnection"
                    $Exclude += 'Test-NwkInfraConnectionValidator_InfraIpPoolConnection'
                } else {
                    Log-Info -Message "Deployment without ArcGateway."
                }
            }
            "Upgrade" {
                Log-Info -Message "For upgrade, only need to run Test-NwkInfraConnectionValidator_InfraIpPoolConnection for non ArcGateway connection type"
                $Include += 'Test-NwkInfraConnectionValidator_InfraIpPoolConnection'

                if (Get-AzStackHciARCGatewaySetting) {
                    # Upgrade with ArcGateway enabled, will skip Test-NwkInfraConnectionValidator_InfraIpPoolConnection
                    Log-Info -Message "Upgrade with ArcGateway enabled, will skip Test-NwkInfraConnectionValidator_InfraIpPoolConnection"
                    $Exclude += 'Test-NwkInfraConnectionValidator_InfraIpPoolConnection'
                } else {
                    Log-Info -Message "Upgrade without ArcGateway."
                }
            }
            default {
                throw "Unsupported OperationType [$OperationType] for Network Connection Validator"
            }
        }
        #endregion

        Set-AzStackHciOutputPath -Path $OutputPath
        Write-AzStackHciHeader -invocation $MyInvocation -params $PSBoundParameters -PassThru:$PassThru
        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialize reporting
        $envCheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envCheckerReport = Add-AzStackHciEnvJob -report $envCheckerReport

        Write-Progress -Id 1 -Activity "Checking Azure Local dependencies" -Status "Network Connection" -PercentComplete 0 -ErrorAction SilentlyContinue

        $validationResult = @()

        # Get list of tests to run
        $testList = Get-TestListByFunction -ModuleName AzureLocal.NetworkInfraConnection.Helpers
        $script:envChkTestList = Select-TestList -Include $Include -Exclude $Exclude -TestList $TestList

        $totalTestCount = ($script:envChkTestList).Count

        if($totalTestCount -eq 0) {
            Log-Info "No test cases need to be run."
            return $validationResult
        }

        Log-Info -Message "Network connection validator to run during [ $($OperationType) ]: [ $($script:envChkTestList -join ', ') ]"

        # Run validation
        $i = 0
        $ProgressActivity = "Checking AzStackHci Network Connection Compatibility"
        $ProgressStatus = "Testing $ENV:ComputerName"
        $progressParams = @{
            Id          = 1
            Activity    = $ProgressActivity
            Status      = $ProgressStatus
            ErrorAction = 'SilentlyContinue'
        }
        Write-Progress @progressParams

        :noTestsBreak foreach ($test in $script:envChkTestList) {
            $OpMsg = "Run network infra connection validator [ {0} ] on machine [ {1} ]" -f $test, $ENV:ComputerName
            Log-Info -Message $OpMsg
            Write-Progress @progressParams -CurrentOperation $OpMsg -PercentComplete (($i++ / $totalTestCount) * 100)

            $invokeParameters = @{}
            Get-Command $test | Select-Object -ExpandProperty Parameters | Select-Object -ExpandProperty Keys | ForEach-Object {
                if ($callingTestParam.ContainsKey($PSITEM)) {
                    $invokeParameters += @{
                        $PSITEM = $callingTestParam[$PSITEM]
                    }
                }
            }

            # Save parameter information for current validator
            Log-Info "Parameters used for current validator: [ $test ]"
            foreach ($param in $invokeParameters.GetEnumerator()) {
                Log-Info -Message "Parameter: $($param.Key) = $($param.Value | ConvertTo-Json -Depth 5)"
            }

            $validationResult += Invoke-Expression "$test @invokeParameters"

            $OpMsg = "End run of network infra validator [ {0} ] on [ {1} ]`n" -f $test, $ENV:ComputerName
            Log-Info -Message $OpMsg
        }

        #region Feedback results - user scenario
        Log-Info "Network infra connection validation finished!" -ConsoleOut:(-not $PassThru)

        if (-not $PassThru) {
            $progressParams = @{
                Id              = 3
                Activity        = "Formatting Results"
                Status          = "Writing Results for $($ENV:ComputerName)"
                PercentComplete = 1
                ErrorAction     = 'SilentlyContinue'
            }
            Write-Progress @progressParams
            Write-AzStackHciResult -Title "$($ENV:COMPUTERNAME):" -Result $validationResult -ShowFailedOnly:$ShowFailedOnly -Seperator ': '
            Write-Summary -Result $validationResult -Property1 Detail
        } else {
            return $validationResult
        }
        #endregion
    } catch {
        Log-Info -Message "" -ConsoleOut
        Log-Info -Message "$($_.Exception.Message)" -ConsoleOut -Type Error
        Log-Info -Message "$($_.ScriptStackTrace)" -ConsoleOut -Type Error
        $cmdletException = $_
        throw $_
    } finally {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        # Write result to telemetry channel
        foreach ($r in $validationResult) {
            Write-ETWResult -Result $r
        }

        # Write validation result to report object and close out report
        $envCheckerReport | Add-Member -MemberType NoteProperty -Name 'NetworkInfraConnection' -Value $validationResult -Force
        $envCheckerReport = Close-AzStackHciEnvJob -report $envCheckerReport
        Write-AzStackHciEnvReport -report $envCheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
    }
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCEi+Q41y1LK2kN
# rzAdt16vqkpQWCnAHn8xTdAIDKMhcqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIDxjE2NU
# D4m5oIjJ67uJbaUlWImufTn2frr3FfYUEjqxMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEA0DBT9JRXkAQo+h8NuT7I0jU1wq0Z7rtyxHkV4VJs
# fwZQ5u9/sFveSHibauXm4vCxE8z9ebZiKm3fALtwk5J6mDZiz1XZTq505mCPtjXZ
# t7uBBi7WmOpBw8OrH9fQUYRoO5N4Sx2mJpBoC5Lb3H/KP55m1opX83XXGZ0EmWN9
# tTjyR9dJazLalzLYL/zO9cAzlOdmF5WtuFV0Z5y5IXIEfJLUMnJhkXSGdGQoLzkm
# gzZbJBufS+63xMBKsKKhk9CFDp9xMRG9mkecSrdCl7XCh4FdP0R1EeqFySrc3ULd
# C1HOe4stBaBDTGSLVZn0Du1d9/MEM3rSyJKA2Ll44hbtmqGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAyFl0hmCvNi6ntctoOtJ/zbqWj0Qpn5mETj6+F
# SBOc8AIGaeexRuRYGBMyMDI2MDUwMzE0MzEzMC41NDNaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiJB0vaq/8i1/wABAAAC
# IjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTZaFw0yNzA1MTcxOTM5NTZaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC1ueKJukIuUsAAJo/AY5DZRqH7
# bhgv7CWGNlEdbRGoITrdE6Wsn57NaNu1BTdjBbFcv7Rfixte0x+HRvXSqsD+WeSX
# /6/y9wE0Mz+xRPTGIY20K7aQDa68OyzVyUeUCypyZC/gW/3ytO/ZOnU9H2ri77kJ
# P8ABrqyy1UxX/OseEgvHsj8yikWT0ARtrjWbXMHFzSOo5hQcfUmMXKqWWz6+N0+U
# ynhGy1n+doW4WZgpH8Y5W7hpSokWj1M/Lu4wi3o6Dz9vVWukcgUFGjLAl4YZpOha
# h7HuiC/alXImMQf8C3A8q/6/1hFoeIZB4UGkywxB/OSTOSsL6+39pDqzM7CgOpf4
# V799kN94yM9uXJI5T/SiA5MdIZIhEW0+bh85RqDh5YW3/oav54RPxw5OPlH64QV6
# KJkl0FIElMVoLNo8UWRQcMD179x7WASjC6LsaNZ7yK0qcESIsL1wiQmdfQBxcqrF
# CpIQfnmQFkOp9IyXUWqza8tmpz8E6aXg9b1eiAT3PVTgrOlPi/hYZCfPxX/6jGty
# Pjy1CiwOmJamohmSU//COAenfRT2G2HMRUpCX1zs+AmDmdQM1XRab4YSALLAlDzG
# CsgI77nnuJjoXAliJmv7NfrvWAcA5KqCUOWQ6kSPt5r28MfKXWJJpSXtFeS/MkDz
# Jy/iJRVyHcFy/B+MtwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFFkHwGoDJ5ZbEEiu
# 8KstiusqaozQMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBiAM+nqrpwG29txSXv
# 42o+CsTe2C4boaRfFju9JaWkLTHwq7pknNONL3n+UG3x/B083EKXiFYrAmul7BTH
# CGXU63/xRsZ2wj3ZmR0A4d9nf9saCJVm4juPVFBai/oktOOYH2j+1+zM70woN5on
# gB/pvy7X8AfY6JB4XPvb80Qz7fY5eddbnwjzg1sZhUPFbbcweWeACINrzqFK62mM
# eXKmhtufMraoogJeJXfWY3x4/pbubgENT3+pXT65203CPF9kfdKE7GKAIRYy3xkB
# TDvFd8dufjOpCn38nK6qMlVtnBjDhWQG0PM3E/oxBs5UBrI6pBYkmIHtbjifDquH
# T+ThaVV7xHc6InoSc3aNzX49JHUgQmuvDdMjLkbYXeA0/1q5IxSg2U+ycZBOvAi3
# udZPKhA5VzODjf/ucu/vFtXrYcRkmGKN3jujaK3/yMZi2Ju5NEL3ISWorwp7RjeZ
# g+JMIK0fosuVj+YCm5r64LH/D9QJDAj+XfZaNeFdv90K5A0QRRGP/poB9yTIVjEX
# j/uJzp8L4Dd44sAquqDOiHdkLgxfK8nPqpCSWPZ9G+RCPm85o9cAfxENtrSuOwcp
# yKzxsRCYCL+PK4+98orit9EVJ/LLoCeG+jLlj0KaD4Qy6sZe4rWMr1brQLosTBZN
# wFnXxNjInCWBd0i7is1yTS/4qTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg5MDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQC7ycXVZx3bsDpJkr7VucgpksozuKCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFXLjAiGA8y
# MDI2MDUwMzA1MTAwNloYDzIwMjYwNTA0MDUxMDA2WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoVcuAgEAMAoCAQACAjeSAgH/MAcCAQACAhM5MAoCBQDtoqiuAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAICyoVbsfk2gYvYCk48bJIGhgFfS
# KFVqLcD1oCXuw4ZmsUQO23TTO/QU1Zn+BHz9eKaK3axV8+GObQIewpsToujmSps9
# 1jTosQ1Iwq1yKHKwboMjCf1HPiZL8ngWDJykry2EMhGjqy+o3Hc69OZbm1aI9moR
# I13oN4jtQZdZL3sTqt6pwPfqwFA3DBecu+uiv0ynq+gFtU9HTdjardpNN4OY1sQA
# e1MSbXS0KBXYWk244Ttv20MTGmMXACyiny1lTdRA1Co67pGPzA4h1z/Q/Vg3Y0Ps
# FgvWnRxG7oxIqyJewma19SYrajjDYVysNA/HNmieixNCTBNTJ7xUcruzArExggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiJB
# 0vaq/8i1/wABAAACIjANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCB0p6tkElN5DHTedOUdtkdCdax9
# 3VP92m0Zb1FQLYKNTzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIAVgXQEK
# BOfGgjNskmDOmbcEIOnHGNwA+QcRufDR5AkTMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIiQdL2qv/Itf8AAQAAAiIwIgQge0BYPU+G
# OOQNtThs8JIT4pVZxK+0CdTvxImeg/PVxbcwDQYJKoZIhvcNAQELBQAEggIAC85D
# 4sN6e32sm+FlLDCzJznZcnvGGkCmA87EknJGHx7014JBLRt4Iilruz/5oJz4FD4s
# ilo97hqIiK1q8VhdHG1zsqFkjpOKds/7fV53Zo+8jWxhrBXGBsr76S61FAALeqvk
# kNVIyCuFaukJls+KkV3bx3Qnfv4UfP0rPkjYxL1hR4aXdPsGO7QmUHdObPRDTJKq
# 6vop+383QDfNu9mHHtmPE++FgYCSyr0x93UNlwpWwPK6RjezGWvh765NaLJsiuge
# nKDbz/UUas2v0h5li/H1QwIqpiNoAj6EwtaG5nMd8wzS1Agk2M9Y3tWA9JDzAHM2
# We4sKn5w8hdHzFiQVD4kdiDEQM9/UYChv8E8wOcOO93TQDPJJ3/UWGmILVPDYAZ5
# TwfRge3/ZYjeXfV+z7IN+hgVBIcpkFIt30ysZ6ByJfK5PpMkPPw0qnDw7z6dbWUl
# 5AK/m+wRwY86QUqt6cRCsCmtzyd75A2yOWi6BIEdDR3M/OEmza8kj4OKZYck731i
# RVAo45xS1guOytelZc8SQbOKiijNcqz97ylGRyE2uNJ9duEn0KWhWMclr8A962wM
# 4xsQ5nq+VjiWl9dfKm1F/EFgaOrTYUfHyQHvV9k39Vug8S3E/njcoL5VWYuCA9x8
# 2ykH+rqeWyKBmnVzVaEuUKau16xfZJ4vChJ9cMM=
# SIG # End signature block
