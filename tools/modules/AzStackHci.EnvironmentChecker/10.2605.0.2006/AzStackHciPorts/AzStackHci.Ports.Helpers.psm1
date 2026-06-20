Import-LocalizedData -BindingVariable lpTxt -FileName AzStackHci.Ports.Strings.psd1

class HealthModel
{
    # Attributes for Azure Monitor schema
    [string]$Name #Name of the individual test/rule/alert that was executed. Unique, not exposed to the customer.
    [string]$Title #User-facing name; one or more sentences indicating the direct issue.
    [string]$Severity #Severity of the result (Critical, Warning, Informational, Hidden) – this answers how important the result is. Critical is the only update-blocking severity.
    [string]$Description #Detailed overview of the issue and what impact the issue has on the stamp.
    [psobject]$Tags #Key-value pairs that allow grouping/filtering individual tests. For example, "Group": "ReadinessChecks", "UpdateType": "ClusterAware"
    [string]$Status #The status of the check running (i.e. Failed, Succeeded, In Progress) – this answers whether the check ran, and passed or failed.
    [string]$Remediation #Set of steps that can be taken to resolve the issue found.
    [string]$TargetResourceID #The unique identifier for the affected resource (such as a node or drive).
    [string]$TargetResourceName #The name of the affected resource.
    [string]$TargetResourceType #The type of resource being referred to (well-known set of nouns in infrastructure, aligning with Monitoring).
    [datetime]$Timestamp #The Time in which the HealthCheck was called.
    [psobject[]]$AdditionalData #Property bag of key value pairs for additional information.
    [string]$HealthCheckSource #The name of the services called for the HealthCheck (I.E. Test-AzureStack, Test-Cluster).
}

class AzStackHciPort
{
    [int[]]$PortNumber
    [string[]]$Protocol
    [string]$ProcessName
}

class AzStackHciPortTarget : HealthModel
{
    # Attribute for performing check
    [AzStackHciPort]$Port

    # Additional Attributes for end user interaction
    [string[]]$Service # short cut property to Service from tags
    [string[]]$OperationType # short cut property to Operation Type from tags
    [string[]]$Group # short cut property to group from tags
    [bool]$System # targets for system checks such as proxy traversal
}

function Get-AzStackHciPortTarget
{
    <#
        .SYNOPSIS
            Retrieve Ports from built target packs
        .DESCRIPTION
            Retrieve Ports from built target packs
        .EXAMPLE
            PS> Get-AzStackHciPortTarget
            Get all port targets
        .EXAMPLE
            Get-AzStackHciPortTarget -Service ARC | ft Name, Title, Service, OperationType -AutoSize
            Get all ARC port targets
        .EXAMPLE
            PS> Get-AzStackHciPortTarget -Service ARC -OperationType Workload | ft Name, Title, Service, OperationType -AutoSize
            Get all ARC targets for workloads
        .EXAMPLE
            PS> Get-AzStackHciPortTarget -OperationType Workload | ft Name, Title, Service, OperationType -AutoSize
            Get all targets for workloads
        .EXAMPLE
            PS> Get-AzStackHciPortTarget -OperationType ARC -OperationType Update -Additive | ft Name, Title, Service, OperationType -AutoSize
            Get all ARC targets and all targets for Update
        .INPUTS
            Service - String array
            OperationType - String array
            Additive - Switch
        .OUTPUTS
            PSObject
        .NOTES
    #>
    [CmdletBinding()]
    param (

        [Parameter(Mandatory = $false)]
        [string[]]
        $Service,

        [Parameter(Mandatory = $false)]
        [string[]]
        $OperationType,

        [Parameter(Mandatory = $false)]
        [string[]]
        $FilePath,

        [Parameter(Mandatory = $false)]
        [switch]
        $Additive,

        [Parameter(Mandatory = $false)]
        [switch]
        $IncludeSystem

    )
    try
    {
        Import-AzStackHciPortTarget -FilePath $FilePath
        $executionTargets = @()
        # Additive allows the user to "-OR" their parameter values
        if ($Additive)
        {
            Log-Info -Message $lpTxt.Additively
            if (-not [string]::IsNullOrEmpty($Service))
            {
                Log-Info -Message ($lpTxt.ByService -f ($Service -join ','))
                foreach ($svc in $Service)
                {
                    $executionTargets += $Script:AzStackHciPortTargets | Where-Object { $svc -in $_.Service }
                }
            }
            if (-not [string]::IsNullOrEmpty($OperationType))
            {
                Log-Info -Message ($lpTxt.ByOp -f ($OperationType -join ','))
                foreach ($Op in $OperationType)
                {
                    $executionTargets += $Script:AzStackHciPortTargets | Where-Object { $Op -in $_.OperationType }
                }
            }
            if ([string]::IsNullOrEmpty($OperationType) -and [string]::IsNullOrEmpty($Service))
            {
                $executionTargets += $Script:AzStackHciPortTargets
            }
        }
        else
        {
            if ([string]::IsNullOrEmpty($OperationType) -and [string]::IsNullOrEmpty($Service))
            {
                $executionTargets += $Script:AzStackHciPortTargets
            }
            elseif (-not [string]::IsNullOrEmpty($Service) -and [string]::IsNullOrEmpty($OperationType))
            {
                Log-Info -Message ($lpTxt.ByService -f ($Service -join ','))
                foreach ($svc in $Service)
                {
                    $executionTargets += $Script:AzStackHciPortTargets | Where-Object { $svc -in $_.Service }
                }
            }
            elseif (-not [string]::IsNullOrEmpty($OperationType) -and [string]::IsNullOrEmpty($Service))
            {
                Log-Info -Message ($lpTxt.ByOp -f ($OperationType -join ','))
                foreach ($Op in $OperationType)
                {
                    $executionTargets += $Script:AzStackHciPortTargets | Where-Object { $Op -in $_.OperationType }
                }
            }
            else
            {
                Log-Info -Message ($lpTxt.ByOpAndService -f ($OperationType -join ','), ($Service -join ','))
                $executionTargetsByOp = @()
                foreach ($Op in $OperationType)
                {
                    $executionTargetsByOp += $Script:AzStackHciPortTargets | Where-Object { $Op -in $_.OperationType }
                }
                foreach ($svc in $Service)
                {
                    $executionTargets += $executionTargetsByOp | Where-Object { $svc -in $_.Service }
                }
            }
        }
        if ($IncludeSystem)
        {
            return $executionTargets
        }
        else
        {
            return ($executionTargets | Where-Object Service -NotContains 'System')
        }
    }
    catch
    {
        throw "Get failed: $($_.exception)"
    }
}

function Import-AzStackHciPortTarget
{
    <#
    .SYNOPSIS
        Retrieve Ports from built target packs
    .DESCRIPTION
        Retrieve Ports from built target packs
    .EXAMPLE
        PS C:\> Import-AzStackHciPortTarget
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        PSObject
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [string[]]
        $FilePath
    )
    try
    {
        $Script:AzStackHciPortTargets = @()
        if ([string]::IsNullOrEmpty($FilePath))
        {
            $FilePath = "$PSScriptRoot\Targets\*.json"
        }
        $targetFiles = Get-ChildItem -Path $FilePath | Select-Object -ExpandProperty FullName
        if (-not $targetFiles)
        {
            throw $lpTxt.NoTargets
        }
        Log-Info ("Importing {0}" -f ($targetFiles -join ','))
        ForEach ($targetFile in $targetFiles)
        {
            try
            {
                #  TO DO - Add validations:
                #  - protocol should not contain ://
                $targetPackContent = Get-Content -Path $targetFile | ConvertFrom-Json -WarningAction SilentlyContinue
                foreach ($target in $targetPackContent)
                {
                    #Set Name of the individual test/rule/alert that was executed. Unique, not exposed to the customer.
                    $target | Add-Member -MemberType NoteProperty -Name Name -Value ("AzStackHci_Port_{0}" -f $Target.TargetResourceName) -Force
                    $target | Add-Member -MemberType NoteProperty -Name HealthCheckSource -Value $ENV:EnvChkrId -Force
                    $target | Add-Member -MemberType NoteProperty -Name Service -Value $Target.Tags.Service -Force
                    $target | Add-Member -MemberType NoteProperty -Name OperationType -Value $Target.Tags.OperationType -Force
                    $target | Add-Member -MemberType NoteProperty -Name Group -Value $Target.Tags.Group -Force

                    # TO DO: Determine the proper use of TargetResourceID
                    $target.TargetResourceID = (New-Guid).Guid.ToString()
                    $Script:AzStackHciPortTargets += [AzStackHciPortTarget]$target
                }
            }
            catch
            {
                Log-Info -Type Warning -Message ($lpTxt.CannotReadTargetFile -f (Split-Path -Path $targetFile -Leaf), $_.Exception.Message)
            }
        }
    }
    catch
    {
        throw "Import failed: $($_.exception)"
    }
}

function Get-AzStackHciPortServiceName
{
    <#
    .SYNOPSIS
        Retrieve Services from built target packs
    .DESCRIPTION
        Retrieve Services from built target packs
    .EXAMPLE
        PS C:\> Get-AzStackHciPortServiceName
        Explanation of what the example does
    .INPUTS
        Service
    .OUTPUTS
        PSObject
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Service,

        [Parameter(Mandatory = $false)]
        [switch]
        $IncludeSystem
    )
    try
    {
        Get-AzStackHciPortTarget -IncludeSystem:$IncludeSystem | Select-Object -ExpandProperty Service | Sort-Object | Get-Unique
    }
    catch
    {
        throw "Failed to get services names. Error: $($_.Exception.Message)"
    }
}

function Get-AzStackHciPortOperationName
{
    <#
    .SYNOPSIS
        Retrieve Operation Types from built target packs
    .DESCRIPTION
        Retrieve Operation Types from built target packs e.g. Deployment, Update, Secret Rotation.
    .EXAMPLE
        PS C:\> Get-AzStackHciPortOperationName
        Explanation of what the example does
    .INPUTS
        Service
    .OUTPUTS
        PSObject
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $OperationType
    )
    try
    {
        Get-AzStackHciPortTarget | Select-Object -ExpandProperty OperationType | Sort-Object | Get-Unique
    }
    catch
    {
        throw "Failed to get services names. Error: $($_.Exception.Message)"
    }
}

function Invoke-PortConnection
{
    <#
    .SYNOPSIS
        Get port via Get-NetTCPConnection & Get-NetUDPEndpoint
    .DESCRIPTION
        Get port via Get-NetTCPConnection & Get-NetUDPEndpoint
    .EXAMPLE
        PS C:\> Invoke-NetTCPConnectionEx -Target $Target
        Explanation of what the example does
    .INPUTS
        URI
    .OUTPUTS
        Output (if any)
    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject]
        $Target,

        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $ProgressPreference = 'SilentlyContinue'
        $target.TimeStamp = [datetime]::UtcNow
        $Target.HealthCheckSource = $ENV:EnvChkrId

        # Create ScriptBlock
        $scriptBlock = {
            $Target = $args[0]
            $AdditionalData = @()
            if ( -not (Get-Command Get-NetTCPConnection, Get-NetUDPEndpoint -ea SilentlyContinue))
            {
                throw "Get-NetTCPConnection and Get-NetUDPEndpoint commands not available. Ensure NetTCPIP module is installed."
            }

            foreach ($rule in $target.Port)
            {
                foreach ($port in $rule.PortNumber)
                {
                    # Placeholder AdditionalData
                    $AddData = New-Object -TypeName PSObject -Property @{
                        Source    = $ENV:COMPUTERNAME
                        Resource  = $port
                        Status    = "In Progress"
                        TimeStamp = [datetime]::UtcNow
                        Detail    = $null
                    }
                    # Test the port
                    if ('UDP' -in $rule.protocol)
                    {
                        $udpResult = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
                    }
                    if ('TCP' -in $rule.protocol)
                    {
                        $tcpResult = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
                    }

                    # Make uniform output
                    if ($tcpResult)
                    {
                        $AddData.Detail += $tcpResult | Select-Object LocalAddress, RemoteAddress, RemotePort, State, OwningProcess, `
                        @{ 'Label' = 'LocalPort'; Expression = { "TCP:$($_.LocalPort)" } }, `
                        @{ 'Label' = 'Protocol'; Expression = { 'tcp' } }, `
                        @{ 'Label' = 'ProcessName'; Expression = { (Get-Process -Id $_.OwningProcess).ProcessName } },
                        @{ 'Label' = 'Status'; Expression = { if ((Get-Process -Id $_.OwningProcess).ProcessName -eq $rule.ProcessName) { 'Succeeded' } else { 'Failed' } } }
                        $tcpResult | Where-Object Status -EQ 'Failed' | ForEach-Object { Write-Verbose -Verbose "$($_.LocalPort) owned by $($_.ProcessName). Expected $($rule.ProcessName)" }
                    }
                    if ($udpResult)
                    {
                        $AddData.Detail += $udpResult | Select-Object LocalAddress, OwningProcess, `
                        @{ 'Label' = 'LocalPort'; Expression = { "UDP:$($_.LocalPort)" } }, `
                        @{ 'Label' = 'Protocol'; Expression = { 'udp' } }, `
                        @{ 'Label' = 'ProcessName'; Expression = { (Get-Process -Id $_.OwningProcess).ProcessName } },
                        @{ 'Label' = 'Status'; Expression = { if ((Get-Process -Id $_.OwningProcess).ProcessName -eq $rule.ProcessName) { 'Succeeded' } else { 'Failed' } } }
                        $udpResult | Where-Object Status -EQ 'Failed' | ForEach-Object { Write-Verbose -Verbose "$($_.LocalPort) owned by $($_.ProcessName). Expected $($rule.ProcessName)" }
                    }
                    # Determine success/failure
                    $addData.Status = if ($AddData.Detail.Status -Contains 'Failed')
                    {
                        "Failed"
                    }
                    else
                    {
                        "Succeeded"
                    }
                    $AdditionalData += $AddData
                }
            }
            if ($AdditionalData.Status -contains 'Failed')
            {
                $target.Status = 'Failed'
                Log-Info "$($target.Title) failed:"
            }
            else
            {
                $target.Status = 'Succeeded'
                Log-Info "$($target.Title) succeeded:"
            }
            $AdditionalData | ForEach-Object { Log-Info ("Port detail {0}: {1}, {2}" -f $_.Status, $_.Resource, (($_.Detail | ConvertTo-Json -Depth 5) -replace "`r`n", " " -replace "  ", "")) }
            $target.AdditionalData = $AdditionalData
            $Target.HealthCheckSource = $ENV:EnvChkrId
            return $target
        }
        # Run Invoke-Command
        $icmParam = @{
            ScriptBlock  = $scriptBlock
            ArgumentList = $Target
        }
        if ($PsSession)
        {
            $icmParam += @{
                Session = $PsSession
            }
        }
        Invoke-Command @icmParam
    }
    catch
    {
        throw $_
    }
    finally
    {
        $ProgressPreference = 'Continue'
    }
}
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBFTdHg68nJ4YWA
# RpbQ/rGRG0bGqTtpJ9oc+wcQHRqXsKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIDuyu0oe
# kbVXvc1Ohg2rrBOBgBiVBlYXOhl5WPegc/Q4MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAL80Pk5At48RgCjpXKnfXD/+7/jq60JVh/3Eljkee
# 7j1043wXPcrVLzuPtzFJJ3tXl3KAGN1ojnZYM/8WVDQtxRZiVhUGb0sRnI6IvTm5
# eOC/Ov9SpkfP7eOTe4Skj1D0Unvtd2KKKiyaMYUVj6oyQwuKzs33k1upZyYZAtvZ
# KYU2Unf1OZxFVNLRv4aui0RXVNb5aUJruVW5swEr1x/hmE1ujH0VygF93aSob5gm
# lrKXppeIGneLhW0qzKuCKz+LHPh9h3HrCJIiOlK7ZYJJyvvIUcNoa6kzfQN+qvtA
# 11FfYnAr/lkxsrFmAH/KiiBq3bfo3E69f0ucCfLrKleha6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBwj8L6aDeS3lRCu+l5Lwcrhmg+LtvCZkx4RuxT
# okNkeQIGaeegqJ4KGBMyMDI2MDUwMzE0MzExMS4wNDdaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDi+CUV9z3jnAIBmBJLgW10haFF
# VR8N+xixnGLGJzvq4DCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIC+BXWrz
# 9geMgM8Bvn8bqxHjhHXJ29EBizITIw0B9vOCMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIeo6ykbjlvfEkAAQAAAh4wIgQgJ1jdQD+0
# szm+d0/kpKtiIuKHE8oW2d9Vtqy9flj8PCswDQYJKoZIhvcNAQELBQAEggIAW5Yu
# wiV1XCbstDUO1JVKXGPotr7lu0XkMSiKTVGyb0uqHTCX2s9V8jZ+RHCodttYQEMu
# ZQj58gqc++Bdg9i4B93wD5M6CHFEWW19Il9En0Xo2H5Yb2Q0JoNNH6jLGW4+aRAG
# Lla0DxSM5OXVgN2P5l4ctklsC3TAxInl4SK4v/hzhi5aXxoNEmvj501o24GNzoUl
# ZpW9Utwg3TwkU8NwX8a0Xowxanjs1aaEKJh9DHtRgwHI1Lg592ZyJIzd2dNfScRM
# 1gTEVHTqfc12UWvjqGvi0myqaPhIHC18fKe4EQUIuH3vg9zuCXCTu32Y9/cc6V6z
# YsCZwqPQ/Ot3gC7cX9yw5ztQ3YuAAj4ju13mtgq5uMu75qEvOwbdIabiYak7WTRr
# VbyFAO6SeRxy1ev/86ElGprnMBL/slRfq2OP3pH/SDd/majjYsAlOj+qFKwwPsDG
# J1LoL5zMVhlpRdsXpS4dojehjRyB6FieOOcLFxel0kNoZmlh9sRhjJrlmYakFqZR
# m8UzDVofg9sCdgXahjuFPdQyoCdtWV2ZTGe3MvjqwVZFGDEy98QAZu+6JHfdWReM
# 5alhcJ9H/P/+AA/De4AyCnbz+C3VJLlxONfeuBV4MfNp9BO4lpunCTCvqEaVjQhL
# pGzgUeS/gVG1BFJ7lAjUkZpffM9oulSgtHJCPeE=
# SIG # End signature block
