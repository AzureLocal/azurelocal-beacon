<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-LocalizedData -BindingVariable lcTxt -FileName AzStackHci.Connectivity.Strings.psd1
Import-Module $PSScriptRoot\AzStackHci.Connectivity.Helpers.psm1 -DisableNameChecking -Global
function Invoke-AzStackHciConnectivityValidation
{
    <#
    .SYNOPSIS
        Perform AzStackHci Network Validation
    .DESCRIPTION
        Perform AzStackHci Network Validation against a mandatory set of endpoints.
    .EXAMPLE
        PS C:\> Invoke-AzStackHciConnectivityValidation
        Perform network validation against all built in service targets from localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for local cluster"
        PS C:\> Invoke-AzStackHciConnectivityValidation -Credential $Credential
        Perform network validation against all built in service targets from all cluster nodes of local system.
    .EXAMPLE
        PS C:\> Invoke-AzStackHciConnectivityValidation -Service 'Azure Kubernetes Service'
        Perform network validation against all mandatory targets and Azure Kubernetes targets from localhost.
    .EXAMPLE
        PS C:\> Invoke-AzStackHciConnectivityValidation -Include 'Windows Admin Center','Windows Admin Center in Azure Portal'
        Perform network validation against all mandatory targets, Windows Admin Center targets and Windows Admin Center in Azure Portal targets from localhost.
    .EXAMPLE
        PS C:\> Invoke-AzStackHciConnectivityValidation -Exclude 'Qualys','Arc For Servers'
        Perform network validation against all targets excluding Qualys & Arc for Servers from localhost.
    .EXAMPLE
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> $RemoteSystemSession = New-PSSession -Computer 10.0.0.4 -Credential $Credential
        PS C:\> Invoke-AzStackHciConnectivityValidation -PsSession $RemoteSystemSession
        Perform network validation against all built in service target from pre-existing remote PS session.
    .EXAMPLE
        PS C:\> $RemoteSystem = 'node01.contoso.com'
        PS C:\> $Credential = Get-Credential -Message "Credential for $RemoteSystem"
        PS C:\> Invoke-AzStackHciConnectivityValidation -ComputerName $RemoteSystem -Credential $Credential
        Perform network validation against all built in service target from a remote system.
    .EXAMPLE
        PS C:\> Invoke-AzStackHciConnectivityValidation -RegionName EastUS -ARCGateway
        Perform network validation for ARCGateway support in EastUS region.
    .PARAMETER PsSession
        Specify the PsSession(s) used to validation from. If null the local machine will be used.
    .PARAMETER Service
        Specify the services to target for connectivity validation. (Aliases: Include)
    .PARAMETER OperationType
        Specify the Operation Type to target for connectivity validation. e.g. Deployment, Update, etc.
    .PARAMETER Exclude
        Specify the services to exclude for connectivity validation.
    .PARAMETER Proxy
        Specify proxy server.
    .PARAMETER ProxyCredential
        Specify proxy server credential.
    .PARAMETER CustomDefinitionUri
        Specify a Uri to retrieve a custom definition of endpoints to check.
    .PARAMETER RuntimeConnectivityTarget
        Specify runtime targets. Must contain DisplayName, Description, Service, Endpoint, Protocol, Severity, Remediation. e.g. @{'DisplayName'='Bing Home';'Description'='Bing Homepage';'Service'='Bing';'Endpoint'='bing.com';'Protocol'='HTTPS'; 'Severity'='CRITICAL'; 'Remediation' = 'https://aka.ms/myserviceconnnectionrequirements}
    .PARAMETER UseLocalDefinitionsOnly
        Retrieve endpoint definitions locally.
    .PARAMETER RegionName
        Specify the region name to target for connectivity validation.
    .PARAMETER ARCGatewayName
        Specify the ARC Gateway Name support to target for connectivity validation. It will be similar to contoso.gw.arc.azure.net, where contoso is unique for each gateway.
    .PARAMETER CloudFqdn
        Only for Local Disconnected scenario, specify the customer FQDN.
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
        https://docs.microsoft.com/en-us/azure-stack/hci/manage/use-environment-checker?tabs=connectivity
    .NOTES
        Mandatory Targets are always invoked, unless explicitly excluded. Use Get-AzStackHciConnectivityTarget | Select Service, Title, Mandatory, Endpoint for more information.
        File-based exclusions can be made by creating a file exlcudetests.txt in the root modules root folder (e.g. PSModulePath\AzStackHci.EnvironmentChecker\<version>).
        This file can support multiple exclusions for all validators e.g.
        --Start sample--
        Test-Processor
        Observability
        microsoftonline
        --End sample--
        This file would have the following affect.  After any include/exclude filtering from the parameter inputs:
        Invoke-AzStackHciHardwareValidation would exclude Test-Processor in its tests
        Invoke-AzStackHciConnectivityValidation would exclude the Observability service AND any service target who's endpoints contains a match for microsoftonline.
    #>
    [CmdletBinding()]
    param (

        [Parameter(Mandatory = $false, HelpMessage = "Specify the PsSession(s) used to validation from. If null the local machine will be used.")]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the services to target for connectivity validation.")]
        #[ArgumentCompleter({ Get-AzStackHciConnectivityServiceName })]
        [ValidateScript({ $_ -in (Get-AzStackHciConnectivityServiceName) })]
        [Alias("Include")]
        [string[]]
        $Service,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the Operation Type to target for connectivity validation. e.g. Deployment, Update, etc...")]
        #[ArgumentCompleter({ Get-AzStackHciConnectivityOperationName })]
        [ValidateScript({ $_ -in (Get-AzStackHciConnectivityOperationName) })]
        [string[]]
        $OperationType,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the services to exclude for connectivity validation.")]
        #[ArgumentCompleter({ Get-AzStackHciConnectivityServiceName })]
        [ValidateScript({ $_ -in (Get-AzStackHciConnectivityServiceName) })]
        [string[]]
        $Exclude,

        [Parameter(Mandatory = $false, HelpMessage = "Specify proxy server.")]
        [string]
        $Proxy,

        [Parameter(Mandatory = $false, HelpMessage = "Specify proxy server credential.")]
        [pscredential]
        $ProxyCredential,

        [Parameter(Mandatory = $false, HelpMessage = "Specify a Uri to retrieve a custom definition of endpoints to check.")]
        [system.uri]
        $CustomDefinitionUri,

        [Parameter(Mandatory = $false, HelpMessage = "Specify runtime targets. Must contain DisplayName, Description, Service, Endpoint, Protocol, Severity, Remediation. e.g. @{'DisplayName'='Bing Home';'Description'='Bing Homepage';'Service'='Bing';'Endpoint'='bing.com';'Protocol'='HTTPS'; 'Severity'='CRITICAL'; 'Remediation' = 'https://aka.ms/myserviceconnnectionrequirements}")]
        [psobject[]]
        $RuntimeConnectivityTarget,

        [Parameter(Mandatory = $false, HelpMessage = "Retrieve endpoint definitions locally.")]
        [switch]
        $UseLocalDefinitionsOnly,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the region name to target for connectivity validation.")]
        [string]
        $RegionName,

        [Parameter(Mandatory = $false, HelpMessage = "Specify the ARC Gateway scenario")]
        [switch]
        $ARCGateway,

        [Parameter(Mandatory = $false, HelpMessage = "Only for Local Disconnected scenario, specify the customer FQDN.")]
        [string]
        $CloudFqdn = $null,

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

        # Validate customdefinition
        if ($CustomDefinitionUri)
        {
            Validate-CustomDefinitionUri -Uri $CustomDefinitionUri
        }
        # Validate any runtime targets
        if ($RuntimeConnectivityTarget)
        {
            Validate-RuntimeConnectivityTarget -RuntimeConnectivityTarget $RuntimeConnectivityTarget
        }

        # Add ARCGateway to the list of targets
        if ( -not $ARCGateway)
        {
            $ARCGateway = Get-AzStackHciARCGatewaySetting
        }

        # Set default region name
        if ([string]::IsNullOrEmpty($RegionName))
        {
            $RegionName = 'Global'
        }

        # Update Disconnected scenario to use the customer FQDN
        if ($CloudFqdn -and $RegionName -eq 'AzureLocal') {
            Convert-EndpointsToAzureLocal -CloudFqdn $CloudFqdn
        }

        # TO DO: Omit system?
        $gtParams = @{}
        if ($PSBoundParameters.ContainsKey('Service')) { $gtParams.Service = $Service }
        if ($PSBoundParameters.ContainsKey('OperationType')) { $gtParams.OperationType = $OperationType }
        if ($PSBoundParameters.ContainsKey('CustomDefinitionUri')) { $gtParams.Uri = $CustomDefinitionUri }
        if ($PSBoundParameters.ContainsKey('RuntimeConnectivityTarget')) { $gtParams.RuntimeConnectivityTarget = $RuntimeConnectivityTarget }
        if ($PSBoundParameters.ContainsKey('UseLocalDefinitionsOnly')) { $gtParams.LocalOnly = $UseLocalDefinitionsOnly }
        $gtParams.RegionName = $RegionName
        if ($RegionName -eq 'AzureLocal') { $gtParams.LocalOnly = $true }
        $ConnectivityTargets = Get-AzStackHciConnectivityTarget @gtParams -ARCGateway:$ARCGateway
        $ConnectivityTargets = Select-AzStackHciConnectivityTarget -Targets $ConnectivityTargets -Exclude $Exclude

        Write-Progress -Id 1 -Activity "Checking AzStackHci Dependancies" -Status "Environment configuration" -PercentComplete 0 -ErrorAction SilentlyContinue

        # Run validation
        $i = 0
        $webResult = @()
        $diagnosticResults = @()
        $skipTests = $false
        if ($PsSession)
        {
            # Collect proxy info before TLS inspection probe.
            # ARCGateway flag omits consistency checks because they are not applicable.
            $diagnosticResults += Get-ProxyDiagnostics -PsSession $PsSession -ARCGateway:$ARCGateway
            foreach ($Session in $PsSession)
            {
                if ($Session.State -ne 'Opened')
                {
                    try
                    {
                        Connect-PSSession -Session $Session
                    }
                    catch
                    {
                        $PsSessionFail = $lcTxt.PsSessionFail -f $Session.ComputerName, $_.Exception.Message
                        Log-Info ($PsSessionFail) -type Error
                        throw $PsSessionFail
                    }
                }
                if (($diagnosticResults | Where-Object Severity -eq Critical).Status -contains 'FAILURE')
                {
                    $failedDiagnosticResult = $diagnosticResults | Where-Object {$_.Status -EQ 'FAILURE' -and $_.Severity -eq 'CRITICAL'} | Format-List | Out-String
                    $failedDiagnosticDetailMsg = ($diagnosticResults | Where-Object {$_.Status -EQ 'FAILURE' -and $_.Severity -eq 'CRITICAL'} | Select-Object -ExpandProperty AdditionalData).Detail -join "`r`n"
                    Log-Info ($lcTxt.DiagnosticSystemFailure -f $failedDiagnosticDetailMsg, $failedDiagnosticResult) -Type Critical -ConsoleOut
                    $skipTests = $true
                }

                # Tolerance on SSL inspection: any success is good enough.
                # TODO: remove this check for USSec and USNat when endpoint manifests are created.
                if ($RegionName -ne 'AzureLocal' -and !(Get-RegionIsUSSecOrUSNat -RegionName $RegionName))
                {
                    $sslInspectionResults = @()
                    $sslInspectionResults += Test-RootCA -PsSession $Session -Proxy $Proxy -ProxyCredential $ProxyCredential
                    $diagnosticResults += $sslInspectionResults
                    if ($sslInspectionResults.Status -notcontains 'SUCCESS')
                    {
                        $failedDiagnosticResult = $sslInspectionResults | Where-Object {$_.Status -EQ 'FAILURE'} | Format-List | Out-String
                        $failedDiagnosticDetailMsg = ($sslInspectionResults | Where-Object {$_.Status -EQ 'FAILURE'} | Select-Object -ExpandProperty AdditionalData).Detail -join "`r`n"
                        Log-Info ($lcTxt.DiagnosticSystemFailure -f $failedDiagnosticDetailMsg, $failedDiagnosticResult) -Type Critical -ConsoleOut
                        $skipTests = $true
                    }
                }
            }
            if (-not $skipTests)
            {
                # Run connectivity tests
                $webResult += Invoke-WebRequestEx -Target $ConnectivityTargets -PsSession $PsSession -Proxy $Proxy -ProxyCredential $ProxyCredential
            }
        }
        else
        {
            # ARCGateway flag omits consistency checks because they are not applicable.
            $diagnosticResults += Get-ProxyDiagnostics -ARCGateway:$ARCGateway
            if (($diagnosticResults | Where-Object Severity -eq Critical).Status -contains 'FAILURE')
            {
                $failedDiagnosticResult = $diagnosticResults | Where-Object {$_.Status -EQ 'FAILURE' -and $_.Severity -eq 'CRITICAL'} | Format-List | Out-String
                $failedDiagnosticDetailMsg = ($diagnosticResults | Where-Object {$_.Status -EQ 'FAILURE' -and $_.Severity -eq 'CRITICAL'} | Select-Object -ExpandProperty AdditionalData).Detail -join "`r`n"
                Log-Info ($lcTxt.DiagnosticSystemFailure -f $failedDiagnosticDetailMsg, $failedDiagnosticResult) -Type Critical -ConsoleOut
                $skipTests = $true
            }

            # Tolerance on SSL inspection: any success is good enough.
            # TODO: remove this check for USSec and USNat when endpoint manifests are created.
            if ($RegionName -ne 'AzureLocal' -and !(Get-RegionIsUSSecOrUSNat -RegionName $RegionName))
            {
                $sslInspectionResults = @()
                $sslInspectionResults += Test-RootCA -Proxy $Proxy -ProxyCredential $ProxyCredential
                $diagnosticResults += $sslInspectionResults
                if ($sslInspectionResults.Status -notcontains 'SUCCESS')
                {
                    $failedDiagnosticResult = $sslInspectionResults | Where-Object {$_.Status -EQ 'FAILURE'} | Format-List | Out-String
                    $failedDiagnosticDetailMsg = ($sslInspectionResults | Where-Object {$_.Status -EQ 'FAILURE'} | Select-Object -ExpandProperty AdditionalData).Detail -join "`r`n"
                    Log-Info ($lcTxt.DiagnosticSystemFailure -f $failedDiagnosticDetailMsg, $failedDiagnosticResult) -Type Critical -ConsoleOut
                    $skipTests = $true
                }
            }

            if (-not $skipTests)
            {
                # Run connectivity tests
                $webResult += Invoke-WebRequestEx -Target $ConnectivityTargets -Proxy $Proxy -ProxyCredential $ProxyCredential
            }
        }

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Connectivity Results'
            $printed = @()
            $targetServices = $webresult.Tags.Service | Sort-Object | Get-Unique | Where-Object { $PSITEM -ne 'System' }
            Foreach ($targetService in $targetServices) {
                $thisResult = $webResult | Where-Object { $PSITEM -notin $printed -and $_.Tags.Service -EQ $targetService }
                Write-AzStackHciResult -Title $targetService -Result $thisResult
                $printed += $webResult | Where-Object Service -EQ $targetService
            }
            Write-AzStackHciResult -Title 'Diagnostics' -Result $diagnosticResults -Expand
            Write-Summary -Result $webResult -Property1 Source -Property2 Resource
            Write-FailedUrls -Result $webResult
        }
    }
    catch
    {
        Log-Info -Message "" -ConsoleOut
        Log-Info -Message "$($_.Exception.Message)" -ConsoleOut -Type Error
        Log-Info -Message "$($_.ScriptStackTrace)" -ConsoleOut -Type Error
        $cmdletException = $_
        throw $_.exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        # Write result to telemetry channel
        foreach ($r in ($webResult + $diagnosticResults))
        {
            Write-ETWResult -Result $r
        }
        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'Connectivity' -Value $webResult -Force
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'Diagnostics' -Value $diagnosticResults -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
        Write-AzStackHciFooter -invocation $MyInvocation -Exception $cmdletException -PassThru:$PassThru
        Remove-Variable -Name AzStackHciConnectivityTargets -Scope GLOBAL -ErrorAction SilentlyContinue
        if ($PassThru)
        {
            Write-Output ($webResult + $diagnosticResults)
        }
    }
}

# SIG # Begin signature block
# MIInRwYJKoZIhvcNAQcCoIInODCCJzQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA/bXnYkRkt0a+4
# NOSQZIMyeDjO1NEcRuWNJ6kH0UPu8qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnjMIIZ3wIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICFZ8eTl
# fKty9wcVRnF4S1ANMwMmXerQvFa+Mpa2K6/2MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAxpeW5Xkl4BcSpESUGOS8Kjbz9C1Pd9E3dFE4sDBZ
# 8cqCNePvW5yCYZ3OZVewvIya19AufFYeHFJ5kbWv6IVeWu5eVbc9tckUl/f53/5N
# tUx34B/RQZNhA5os0pGz5KvMsiy+LkyaVkxehOzut6iDc2WNM8cZt0cIDQrQcdrI
# imQriwwCYpoVvRDDNQnWG0jCRQlOJJFR+Ry0VChgN/JMtEFB55ygGMh+89lcaiMm
# lnrz6fE919/rEP/2Y6muLRFAMp7yWPoINGh2BLabHc1DCt0I1zYzKAGuzMPzOwiX
# yMC4dON4de2phHGxMDIGbiOumQgvVC6sSiOFVXWGUAMbFqGCF5UwgheRBgorBgEE
# AYI3AwMBMYIXgTCCF30GCSqGSIb3DQEHAqCCF24wghdqAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFQBgsqhkiG9w0BCRABBKCCAT8EggE7MIIBNwIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCB2k6mIWx/powVXJvStyaJTX7DYOdpcpJEJbGLA
# cxqCVwIGaedvdqK0GBEyMDI2MDUwMzE0MzEwOS40WjAEgAIB9KCB0aSBzjCByzEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWlj
# cm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1Mg
# RVNOOkE5MzUtMDNFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNloIIR7TCCByAwggUIoAMCAQICEzMAAAIn1cCDw7EuVy0AAQAAAicw
# DQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcN
# MjYwMjE5MTk0MDA0WhcNMjcwNTE3MTk0MDA0WjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE5MzUtMDNFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA4sVstXwzki+Ko9wNaWncvnpSAy8J
# xd1Li8ySDlsBh3BIK8ccLZ8r4lCA5pscpU1JdbvtqwT6ds0+AcMEIbxmiaRMarzy
# 5QxZW35kn5SiPOnhaqH4me4/DU0TuJe8BoPTY5vprjWrk3BVtqnXyIyhPedDpK5v
# TJzDhmMvn4mzWHcUz0T6tU+DC2St7N73TMjBDpXXDkJEiqcQ+v9RpOoDpgrtioCP
# H9Hser2MZyg5fVtDi0hGv+svNqCG7JvtUAYnzkOO8VikxtQpr7Rq/OS8wO+fzAHF
# JkcOf6H/6hE9FBVdVrpTHCayOgwEgLDQjQfuli66LbgWQI/lTJam5+UTGekOCGOy
# cGgIiF4e1Y8a58FDmGRvFhBoX6wPfHYvuyxJ/QKr7xDshvlEHI1YQgmzBl4oCV0g
# KXsnlrqQrA9I4EDDQsXweQSwQ1sYHWN3SQRD4MX5IEw0CwYILVb9neQmMRyoCCLQ
# eGyOXkm+Y5CBtlqLZxXrU9JXoKcPxKM8H9/WqOrRDWNtXlViM0cPxrJr8I2EBer1
# a8Tg9KRlbH6hhfLN1T3mO4SNk8RxTKjQNCAf2tjS2OyU8WACgD/9dRCWbe8W6gyz
# IA9WA3RhMxqUIo5t5wDwi9gnmz/45rvdGmydluNucoJRh0yP5wga8EqX0QoMM63x
# XpSWgijOvt+WhX8CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBTS1ufDeDBkhurne41q
# oE/dqK30XjAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8E
# WDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYB
# BQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEw
# KDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4G
# A1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAKp3LneD0gtbXm9h+p0bs
# u7A4iitdxVyYq1QeE38I3aNjG/kC+I+8Gf5OBvT9AgDR2Raw0HCtFRQ08rK2LvGd
# AIWteGnA2T7MiKD7wBkUYWhxLn+zXJEY5H2v8paNSsiCPI2y/TfbCQKgTy/FeBTQ
# Y5Y7/tRhwzsNdu62c+WUkz6AD29kgNL+cg4HKVDH8YJT8qenJzz6EKU7Q/ThsfA8
# Jtj/qNUz8QSMuiNE/UWrrpaIFQrysH5X3i03CgL50htawo3q0l5lNQzVzrAA/27K
# 0o4G1+ZgGw+100TBf72sAFhEhXJ/wY44s8XlmW9NGmEpZCQNq1bRZTDOPNWlVl3Q
# G1zz+Uc1Ilk5YMh3/xu5QsR2FhiGbgdd092iOmPJhIJ/6LuNGohSaPK9PotD+RnT
# Z3lrcYkdAjClH5KPubP+93MHtVn6fASl2tu9HInFUGrBX+bEVe6RZvle3zUV8Aru
# 2p0zpoGu+szu/9rfszpYm76YU/kOmXfgdqmLEp+MQWmPmMx6Z8nC1uXLycoT8QQn
# G9aEWH4UcwgA29rrSNhLRgo3Nj9oouC8keEDG/5/HDsHi/SKlUyis81ZPs2ScVd7
# 66eC8rkF8NDt9JWugXB3TQAAAfVAvN87NxvXfgJSH2SzPe7TFDSlo2waSIqxcei0
# wxV1bWUHe4asy2Aco24x9LowggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAA
# AAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBB
# dXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YB
# f2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKD
# RLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus
# 9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTj
# kY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56
# KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39
# IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHo
# vwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJo
# LhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMh
# XV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREd
# cu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEA
# AaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqn
# Uv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnp
# cjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0w
# EwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# CwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/o
# olxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNy
# b3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYt
# MjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5j
# cnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+
# TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2Y
# urYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4
# U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJ
# w7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb
# 30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ
# /gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGO
# WhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFE
# fnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJ
# jXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rR
# nj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUz
# WLOhcGbyoYIDUDCCAjgCAQEwgfmhgdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9w
# ZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBOTM1LTAzRTAtRDk0
# NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcG
# BSsOAwIaAxUAIx86rYT8DtBg3JAzAOseeJSIjCqggYMwgYCkfjB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hvhEwIhgPMjAy
# NjA1MDMxMjI5MDVaGA8yMDI2MDUwNDEyMjkwNVowdzA9BgorBgEEAYRZCgQBMS8w
# LTAKAgUA7aG+EQIBADAKAgEAAgIRxwIB/zAHAgEAAgISZjAKAgUA7aMPkQIBADA2
# BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIB
# AAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQBRm1MM3Lfo9ntHhu80EY+ttYdXHAbs
# 6dA7MPXKEFxZHTpfPnED4C8rEBQ6YUoze5Pw7EgxAInaBnooUrtEXOtomRIHknch
# IASqyMEorPJPuZSeeCTC0gYKLBSmM7BxpB8SMpaG+wzUw4xqYAdnzF3j2mMzhWTh
# FoOdCCedc8W+5n/sGUyfwAxSAQVm/PQWJFVKJp+41sniw+f/OIRumNwKCJKQIIfp
# 50wWR/lklEdY+orelJsoWcWHESwIcXmfwHI3WtyLYzmfzV7LtNEiWsuhfWmByeSS
# AGIB56jcwUn2Hcfdu3C0AOBdJRnif995QeYfVlvm2U4Sp55JRcIv9wtoMYIEDTCC
# BAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIn1cCD
# w7EuVy0AAQAAAicwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsq
# hkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgNehHXXBngBpfB6U5z2cs6P+1gnpv
# bO4RzIxniygW0gUwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDl5wEaNaFS
# HDiySg6pRNGnav42fU13ZZ11kXFxk4QRcjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwAhMzAAACJ9XAg8OxLlctAAEAAAInMCIEIEWCar2xLK9O
# DqPiVMyhD4KwwOEucdIgtwHRkUpycUx8MA0GCSqGSIb3DQEBCwUABIICALyN1HaW
# EyvEtOlSIt0zaM/U2DcpAZNKwk0Aeq5Dqq0H7HTwuxO71llYZ6ncFMEa7iEqNMoG
# ralpqwDc7I5lh0Mn+2cDED2afRYTfX9BxlEw2nCkyD99HBGd4x2hBDAqlhPZFp04
# xNqu6W+eWURuFtEPmCZtjdGHaMNE01xCvXh5weVOyExjY8Zh7E5hhkIBBQdFf/8L
# mikFHxw4H1HMBmEpY15J4+atAiuLtqRW/KzXQ/tZV9W1wTb5TR2ONdEo+dy9qZy1
# xlXy18dTkD7wS6Bv7nxQGLQrcJGaHvJrscFCn0Z2QNbadwRmO6Wo+sL7qlG/M1yB
# VFFKbq/LPx2W8YKd1MEC+KtTfKZMoEBLATyZ5Q9Kt8ie3fJnGc++vJvQUcYlFM7u
# dlkijP7ioDA5lOvTZKB/ZjI/JKOSSG1KRn+4xgOukGgdyhjcFVSnTfJHQNVq/F03
# gat+JICZOxKJvcw7BJ3+J4VR0PBnSWhqxyIsf1IxDuNTgoxVjRxGbb7X33bVa6Dl
# zmXd7j6XhCP4pj5bQX4eaZwJgJwWqBDWHHU+OXuCJ3SsnRucBkgPUNcyY3n5WwAA
# pn4HU/D47IwpvPMxQWdTlYw9b67qfWVPZYDh982237z0+irxbr7AjxOfNMDgEoa6
# PwseLAT0ZdXIfZCaOJxQnY5/GNamREmtnNIA
# SIG # End signature block
