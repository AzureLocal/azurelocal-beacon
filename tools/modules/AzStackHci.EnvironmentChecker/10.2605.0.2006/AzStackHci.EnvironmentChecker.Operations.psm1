<#############################################################
#                                                           #
# Copyright (C) Microsoft Corporation. All rights reserved. #
#                                                           #
#############################################################>

function Invoke-EnvironmentValidator
{
    <#
    .SYNOPSIS
    Wrapper command to Test Environment Readiness

    .DESCRIPTION
    Wrapper command to test environment readiness, run locally on HCI system.

    .PARAMETER OperationType
    Type of Operation.

    .PARAMETER WaitForResult
    Wait for action plan to complete.

    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('AddNode','Deploy','RepairNode','Upgrade','Update')]
        [String]
        $OperationType,

        [Parameter(Mandatory = $true, ParameterSetName = "AddNode")]
        [ValidateNotNullOrEmpty()]
        [String[]]
        $Name,

        [Parameter(Mandatory = $false, ParameterSetName = "AddNode", HelpMessage = 'Use Host IPv4 address to simulate AddNode. Omit for RepairNode.')]
        [ValidateNotNullOrEmpty()]
        [String[]]
        $HostIpv4,

        [Parameter(Mandatory = $false, HelpMessage = 'Start step for the action plan. Use Get-EnvironmentValidatorActionPlan to get the steps.')]
        [int]
        $Start,

        [Parameter(Mandatory = $false, HelpMessage = 'End step for the action plan. Use Get-EnvironmentValidatorActionPlan to get the steps.')]
        [int]
        $End,

        [Parameter(Mandatory = $false, ParameterSetName = "Update")]
        [ValidateNotNullOrEmpty()]
        [String]
        $EnvironmentCheckerResultPath,

        # Add Ignore warnings
        [Parameter(Mandatory = $false, ParameterSetName = "Update", HelpMessage = 'Ignore warnings and continue.')]
        [switch]$IgnoreWarnings,

        [Parameter(Mandatory = $false, HelpMessage = 'Wait for action plan to conclude. Shows progress if running on the ECE owning node.')]
        [switch]$Wait
    )
    $ErrorActionPreference = 'Stop'

    # Check if we are running Orchestrator as a service or lite
    $Script:OrchestratorSvc = IsOrchestratorSvc

    # Check if action plan is running
    $RunningActionPlans = Get-AzStackHciEnvironmentCheckerActionPlan | Where-Object Status -In 'Running', 'Queued'
    if ($RunningActionPlans)
    {
        throw "Environment Validator action plan in progress"
    }

    if ($OperationType -in 'AddNode', 'ScaleOut' -and [string]::IsNullOrEmpty($Name) -and [string]::IsNullOrEmpty($HostIpv4))
    {
        throw "Parameters missing: Name and HostIpv4 must be supplied when OperationType is AddNode or ScaleOut."
    }

    # Archive Log file
    ArchiveLogFiles

    $ActionType = Get-EnvironmentValidatorActionPlan -OperationType $OperationType
    Write-Verbose "Starting Environment Validator for $OperationType"

    # TODO check if Deploy, Upgrade or AddNode ops are running here?
    $params = @{
        RolePath   = 'Cloud\Infrastructure\EnvironmentValidator'
        ActionType = $ActionType
    }

    # Add needs a node name and IP, take these from the user
    # TO DO: Remove EnvironmentValidatorAddNode
    if ($ActionType -in 'EnvironmentValidatorAddNode','EnvironmentValidatorRepairNode')
    {
        if ([string]::IsNullOrEmpty($Name))
        {
            throw "Parameters missing: Name and HostIpv4 must be supplied when OperationType is AddNode."
        }

        if ($HostIpv4)
        {
            $params += @{
                runtimeParameters = @{
                    IpAddress = $HostIpv4 -join ' '
                    NodeName = $Name -join ' '
                }
            }
        }
        else
        {
            $params += @{
                runtimeParameters = @{
                    NodeName  = $Name -join ' '
                }
            }
        }
    }

    # Update needs a path to the result file, take this from the user, or set to a test value so we dont overwrite the real one.
    if ($ActionType -eq 'EnvironmentValidatorPreUpdate')
    {
        if ([string]::IsNullOrEmpty($EnvironmentCheckerResultPath))
        {
            $EnvironmentCheckerResultPath = "$($env:LocalRootFolderPath)\MasLogs\Invoke-EnvironmentValidator-EnvironmentCheckerUpdateResult.json"
        }
        $params += @{
            runtimeParameters = @{
                EnvironmentCheckerResultPath  = $EnvironmentCheckerResultPath
            }
        }

        # user to override IgnoreWarnings, but if it's update, we want to inject it as false by default.
        if (![string]::IsNullOrEmpty($PSBoundParameters['ignoreWarnings']))
        {
            $params.runtimeParameters += @{
                ignoreWarnings = $PSBoundParameters['ignoreWarnings']
            }
        }
    }

    if ($Start -and $End)
    {
        Write-Verbose "Starting Environment Validator for $OperationType from step $StartStep to $EndStep"
        $params += @{
            Start = $Start
            End = $End
        }
    }
    else
    {
        Write-Verbose "Starting Environment Validator for $OperationType"
    }

    if ($Script:OrchestratorSvc)
    {
        Write-Verbose "Invoke-ActionPlanInstance with params: `r`n $($params | fc | Out-String)"

        $ActionPlanInstanceId = Invoke-ActionPlanInstance @params 4>$null
        if (-not $wait) {
            Write-Verbose "To check progress, open a powershell session to $(GetOrchestratorOwner) and call: 'Get-AzStackHciEnvironmentCheckerProgress -Path $($env:LocalRootFolderPath)\MasLogs\AzStackHciEnvironmentProgress.json'"
            Write-Verbose "Run the following to get the action plan progress Get-ActionPlanInstance -actionPlanInstanceID $ActionPlanInstanceId"
        }
    }
    else
    {
        Invoke-EceAction @params
        if (-not $wait) {
            Write-Verbose "To check progress, call: 'Get-AzStackHciEnvironmentCheckerProgress -Path $($env:LocalRootFolderPath)\MasLogs\AzStackHciEnvironmentProgress.json'"
        }
    }

    Start-Sleep -Seconds 5
    for ($i = 0; $i -lt 30; $i++)
    {
        $ActionPlan = Get-AzStackHciEnvironmentCheckerActionPlan | Sort-Object LastModifiedDateTime -Descending | Select-Object -First 1
        switch ($ActionPlan.Status)
        {
            { $_ -in "Failed", "Cancelled" }
            {
                throw "$ActionType is $($actionPlan.Status). Please resume please review: `n $($actionPlan.ProgressAsXml)"
            }
            { $_ -in "Waiting", "Pending" }
            {
                Write-Verbose "$ActionType is currently $($actionPlan.Status)"
            }
            { $_ -eq "Running" }
            {
                Write-Verbose "$ActionType is currently $($actionPlan.Status)"
                if ($Wait)
                {
                    if ($ENV:COMPUTERNAME -eq (GetOrchestratorOwner))
                    {
                        Get-AzStackHciEnvironmentCheckerProgress | Format-Table Result, StartTime, EndTime, DurationSeconds, Name, Description -AutoSize
                    }
                }
                else
                {
                    break outer
                }
            }
            { $_ -eq 'Completed' }
            {
                if ($ENV:COMPUTERNAME -eq (GetOrchestratorOwner))
                {
                    Get-AzStackHciEnvironmentCheckerProgress | Format-Table Result, StartTime, EndTime, DurationSeconds, Name, Description -AutoSize
                }
                break outer
            }
            default
            {
                Write-Warning "$ActionType cannot be started due to unknown status of last run"
                return
            }
        }
        Start-Sleep -Seconds 30
    }
    Write-Verbose "$ActionType $($ActionPlanResult.Status) Action Plan ID: $($ActionPlanInstanceId.Guid)"
}


function Get-AzStackHciEnvironmentCheckerActionPlan
{
    <#
    .SYNOPSIS
        Get all Environment Validator action plan instances
    #>
    [CmdletBinding()]
    param ()

    $validatorLookup = 'EnvironmentValidator*'
    if (IsOrchestratorSvc)
    {
        Get-ActionPlanInstances | Where-Object { $_.ActionTypeName -like $validatorLookup }
    }
    else
    {
        Get-ActionProgress -ActionType $validatorLookup
    }
}

function Get-AzStackHciEnvironmentCheckerProgress
{
    <#
    .SYNOPSIS
        Intended for internal-use to retrieve multi-validator invocation progress using action plan
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Path = "$($env:LocalRootFolderPath)\MasLogs\AzStackHciEnvironmentProgress.json"
    )
    Get-Content $Path -ErrorAction SilentlyContinue | ConvertFrom-Json
}

function ArchiveLogFiles
{
    <#
    .SYNOPSIS
        INTERNAL USE ONLY - Archives any supporting files for environment checker.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Path = "$($env:LocalRootFolderPath)\MASLogs"
    )
    # Archive any logs
    'AzStackHciEnvironmentChecker.log', 'AzStackHciEnvironmentProgress.json', 'AzStackHciEnvironmentReport.json', 'AzStackHciEnvironmentReport.xml' | ForEach-Object {
        Get-ChildItem -Path $Path -Filter $PSITEM -ErrorAction SilentlyContinue | ForEach-Object {
            Rename-Item -Path $PSITEM.FullName -NewName ($PSITEM.fullname -replace '(\.)', ('_{0}.' -f (Get-Date -Format yyyyMMdd-HHmmss)))
        }
    }
}

function IsOrchestratorSvc
{
    [CmdletBinding()]
    param ()
    $orchestratorSvc = Get-Service | Where-Object {$_.Name -eq 'ECE Windows Service' -or $_.Name -eq 'Azure Stack HCI Orchestrator Service'}
    if ($orchestratorSvc)
    {
        return $true
    }
    else
    {
        Import-Module C:\CloudDeployment\ECEngine\EnterpriseCloudEngine.psd1 -Force
        return $false
    }
}

function GetOrchestratorOwner
{
    [CmdletBinding()]
    param ()
    try
    {
        Get-ClusterGroup | Where-Object {$_.Name -eq 'ECE Windows Service Cluster Group' -or $_.Name -eq 'Azure Stack HCI Orchestrator Service Cluster Group'} | Select-Object -expandProperty OwnerNode | Select-Object -ExpandProperty Name
    }
    catch
    {
        return $null
    }
}

function Get-EnvironmentValidatorActionPlan
{
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('AddNode','Deploy','RepairNode','Upgrade','Update')]
        [string]
        $OperationType
    )

    $ActionType = switch ($OperationType)
    {
        'Deploy' { 'EnvironmentValidatorFull' }
        'Upgrade' { 'EnvironmentValidatorUpgrade' }
        'AddNode' { 'EnvironmentValidatorAddNode' }
        'RepairNode' { 'EnvironmentValidatorRepairNode' }
        'Update' { 'EnvironmentValidatorPreUpdate' }
        Default {}
    }

    if ($Script:OrchestratorSvc)
    {
        [xml]$xml = (Get-CloudDefinition).CloudDefinitionAsXmlString
    }
    else
    {
        [xml]$xml = (Get-EceConfiguration).xml
    }
    $apDef = $xml.SelectNodes("//Action[@Type='$ActionType']")
    $Steps = $apDef.Steps.Step
    Write-Verbose ($Steps | Out-String) -Verbose
    return $ActionType
}
# SIG # Begin signature block
# MIInSAYJKoZIhvcNAQcCoIInOTCCJzUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCA3Kv/3lsj2VcK
# 5lIRDxospsVQb064+ABcgcaU25aQ7qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPxdWDOg
# r3uMf70zVf3sRFysaUMQfDLqYlb8+4bo+RDLMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAEYUW7jVQBBoe58tJGMv7XBU+3VBxIaVySDjInnr3
# R9mqBljwJ4jHAk2E9uR5By++IqwljqnQ65RopEi0aZKXSgAT9mLJTgwVgm7+rRHF
# /RajEoRuqW6UrL9SmKvYcye8aG2H3oPik5G73duSJkFtMTM9zJgGouTOUIkH/HUn
# KC1cU2CX/hNY3ljVtw1VxkUU8Q42ZzRvbndmSasAYBnQmPWV1CPxG7kj11kZl19v
# kC1ajq+8QVrtp2xbUACLM7kogib5SwunRJw3TIXV73hqZLFEMlmBUX6ZnJ5m9Bbc
# fO/98a/bj8e6LemhJxbfjoZje/83Sjzw62ePapcWK0Tx6aGCF5YwgheSBgorBgEE
# AYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBKrCpwfMr/0mCJ32+mqGp4Fd69tPi+duYNRaBN
# nYwBOQIGaefsSb9BGBIyMDI2MDUwMzE0MzEwOS43OVowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpGMDAyLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMzAAACICTh5uAXubSOAAEAAAIg
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5Mzk1MloXDTI3MDUxNzE5Mzk1MlowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpGMDAyLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANFhjvKvuKNboJHXvy4q94gy5+61
# Y6JzGAnAo5x7/YY5Bx66zplZ9fXiLeM2Dck4/swYkyQ4C5zBYHCIDxRGn5liQaOl
# WhWQZmxXbtaOovCl/YDCoGwn9POrATskUVrG6nct3GPwaN0nKYMVGt1U3+lgegEW
# uMPUiQgO7xvUJafy2CiaIpFJj5JO8mr32ZWR2mEwEhQY56BCfLypF3bhUwTTGLw6
# iaSz1mr0SMN4ocam8BtdQRDqbdxE6gQ+FMT+aLB5Af1Oom3cg6yo+/cvy6uiMHvj
# tcELbLQIMgeUotwuXdkbwPslcqdZMV6feaww8mly+tDfNQFUmsf+YjdHEeYKH2mk
# M/S4bX48nCTof/H6x+gb2FbrjGheSnHoMR81k19xd0ptcXbxcRd0s2fOjdIs1XKZ
# 5AmE2o5IqGdTzhCcqauMSTnjUmK6uUMKQJY72VQFQxv3HSfJ9dRs1E9UuA/49MxF
# 1c6jAl1gLMJB83ZmovSzhgjbwXUNufsGDDYTg/UT26ey8zMke3OFLZOHdOkJ8Fs4
# ZqUiUX3H8Mln+yyb/LLNP1i0gV6qZ83EE9MTdo66HofGZMgLN9gABO9Y2EFujX1D
# CyM94D0m+GpMsLYpQ2CteugbLh4NmjSfuMViNmRSKHVPL7wTqoS9XY1rpnmBTIPl
# r60cYOarr0KZSId/AgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQU28ic4IiHEYDyZjuX
# WDTtQe/I2DMwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAK0oYG2jUFK+bhYUj4nQ
# 1LJWFTUscvsXd9uNnZ3sXkqf8UJMFlenOsNWXrcUtE1wgWmcnLj+eWDjevtPmwk9
# 2jgyzwANIdAQmcdK7fH1SmMLNEQE+L36ceG8OBHH/VaYEPqBBRkks6Fw3ZPFbgon
# KGKcy2IEW2Q1Fna+ZnUwB01dObl3QvCTfDOP79/tUIJNYJclKio1rdVT/qwAIcj3
# sS9ufODxt3eHGt/PoJwJW5/vt6C9EeKe2Em7BJF48/tpWZx69vWdZQgAgJ0F5sdA
# 6vM0h5YEhDC9wVpLdIVz7j2uqvBA4wUNHgVgHNLtvRB4FXEW4svaJW7goAcw1SEs
# tIPiIosMUE1M61PNOWEa8yAbvsDVyN5CsMwdrqhF4wN5QOodSvG/yDshF0iH6HSA
# MuTM3TEi7OWLQG/sm3JsYltXonFoMXgLNIIgxGkrn2cjqIqjguCdtAFklbv7pqRi
# wob+lc+V/E2/YiekPXS1IKQK/D2SvpbX41E34S5lzNGADBaVwr1clne67+/+jEe0
# 7v+SZUiznUX2pXpjZA1d3q1Tjpg+sr3ybZAPKz6W8s2KYrR7XFntnUZrAqiEoa+U
# sAtYOVlCqAd8nfUIHQuUgMjuIvJhOl3aLIqOqyRtCLIy0gIf5GYf+gKDsk4rRkDd
# cgxtr1pJaAEXdBnqkbcQZ5CqMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
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
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAJMYD2+mwnqCWoIuYjSuCAbHhgQSoIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoZI2MCIYDzIw
# MjYwNTAzMDkyMTU4WhgPMjAyNjA1MDQwOTIxNThaMHcwPQYKKwYBBAGEWQoEATEv
# MC0wCgIFAO2hkjYCAQAwCgIBAAICB/0CAf8wBwIBAAICEx0wCgIFAO2i47YCAQAw
# NgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgC
# AQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAU1+R1d5cXTk05HES8UhgpDPlXedz
# QNvo/vRnIsg/VyDiKtJAKzPQf4KvO521WLedrkG+POSpuy4f95FSRCf6AFBS4Cv1
# krynZ/TzlA09Dt9c5OMNJXmM4c7kvvZizVOvOsUl1W9CNvVWW8EjdA6O+0tKRYZR
# spgys00rULKhmk2O62CYt7Owrr1j6l5U3Zj7HvyMaFU6ZddhYYmuOu/WIb9aY9ZB
# S8Vq8X+wIwEJ7FxiSiG3r5zThuLYxfrnn5LO//UU0XfRq8mbvV3Gdh6BpqtCKlFk
# PshcbQfia5Kct+9/+d7LHbDbMDA+L6ndg/7SyGBDKaCqiVwMbSFh1gSnZTGCBA0w
# ggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACICTh
# 5uAXubSOAAEAAAIgMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIJRIj8C6oz26yR55uXf8huhRRu69
# SjeMLn12MOKmVeg1MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQg43u/I6U8
# DVWqUSnRAhUaU13xLlhYGcqP3su5NYdI7a8wgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiAk4ebgF7m0jgABAAACIDAiBCAn/MUTTcEJ
# 9SmheNS0Fkp6uUyYCt2dfTeR2VEchIfuZTANBgkqhkiG9w0BAQsFAASCAgA3n8kH
# x17YeWUNJKooPzFInFCjsDn9/YEqR9f5wSgP1fjcK+i7lftPDNfZ3Ey985bNw0fg
# lRkrKW2AX0ELBhLC6IWqUdVLM+fQ3bC5SEwwv4ZPW3854XoaKPY7pRoN3s5/h+CA
# 7ddlHqHG2X6HPzvTtwEkKt1hQ16nj621D4iJPT6GfgsCVtQMlZZ26tZ7JQu8+1rK
# FHplWX4pEV7YijYxuDFuw0UguY8v8WcZCNB+5VeIuv38w2VNyfHvKEUlHE05Ncmz
# 8++38oUKysUZZpB3PUJuOeFN4LTwFgIhCHqYpdnqSTk2U/+Mwa6EqjFLVcrNBn1t
# w1FjIMORoU7eGfHz6JIQVOg0G2E1NCPFqw8M0eJvyf8+WJeZ61dJiPd4ytfb0Hqu
# S/2TO1pe/75P1xSNzmykmF1dmGgSn/lGv55mlE1CdyvhexSGjREgtMSPAHVmQBbN
# DDY5BCtRdhA1OU4VVS8gjl2ncSzW1zyL60j+cZlPBLqD5EAVKq1YO5y/ROa81fia
# lUfA/s/qQ0atMil0oq3qYAvCRo39iFGUgxb/ZQEJrw75E8cWMKBOW6fIDvzGR9PF
# 84CXleVwlLgg9RIBs3dCpJVJ83IT8247YePtoPEiC2GCKD/uOb5Uog84Cn/GDYkv
# M+aHwquldCoqr+bWKrSogBKo1WCR3r5rNAC4bg==
# SIG # End signature block
