Import-LocalizedData -BindingVariable lWRMTxt -FileName AzStackHci.RemoteManagement.Strings.psd1

# This file contains a list of discreet tests that can be run against the environment
# Each test named Test-* is exported and discovered to be run by the user-facing function.
# The user uses Include and Exclude parameters to run specific tests. (this provides a consistent experience across validators)
# If tests have dependencies on other tests, or they should be run in a specific order, the pattern describe above should be removed.

function Test-CimSession
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $ComputerName,

        [Parameter()]
        [pscredential]
        $Credential,

        [int]
        $MaxRetries = 6,

        [int]
        $RetryDelaySeconds = 5
    )

    try
    {
        $severity = 'Warning'
        $instanceResults = @()
        foreach ($computer in $ComputerName)
        {
            $cimSession = $null
            $status = 'FAILURE'
            $dtl = @()
            try
            {
                # Create a new CIM session
                $attempt = 0
                do {
                    $attempt++
                    try {
                        $cimSession = New-CimSession -ComputerName $computer -Credential $Credential
                        if ($cimSession -is [CimSession]) {
                            break
                        }
                    } catch {
                        if ($attempt -ge $MaxRetries) {
                            throw
                        }
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                } while ($attempt -lt $MaxRetries)
                # Test the CIM session by querying a known class
                if ($cimSession -is [CimSession])
                {
                    $dtl += "CIM Session: Successful, ComputerName: {0}, Protocol: {1}, Attempts: {2}" -f $cimSession.ComputerName, $cimSession.Protocol, "$attempt/$maxRetries"
                    $result = Get-CimInstance -CimSession $cimSession -ClassName Win32_OperatingSystem
                    if ($result -is [CimInstance])
                    {
                        $status = 'SUCCESS'
                        $dtl += $lWRMTxt.CimQuerySuccess -f $env:computername, $computer, 'Win32_OperatingSystem'
                    }
                    else
                    {
                        $dtl += $lWRMTxt.CimQueryFailed -f $env:computername, $computer, 'Win32_OperatingSystem'
                    }
                }
                else
                {
                    $dtl += $lWRMTxt.CimSessionNotEstablished -f $env:computername, $computer
                }
            }
            catch
            {
                $dtl += $lWRMTxt.CimSessionAttemptsFailed -f $env:computername, $computer, $attempt, $MaxRetries, $_.Exception.Message
            }
            finally
            {
                $detail = $dtl -join ". "
                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_RemoteManagement_Cim_Test' `
                    -Status $status `
                    -Severity $severity `
                    -TargetResourceName $computer `
                    -Source $ENV:COMPUTERNAME `
                    -Resource $computer `
                    -Detail $detail
                Log-Info $detail -Type $(if ( $status -eq 'FAILURE' ){ $severity } else { "INFO" } )

                if ($cimSession -is [CimSession])
                {
                    Remove-CimSession -CimSession $cimSession
                    $cimSession = $null
                }
            }
        }
        return @(New-AggregatedTestResult -TestName 'Test-CimSession' `
            -DisplayName 'CIM Session Connectivity' `
            -Description 'Validates CIM (Common Information Model) connectivity to each cluster node by establishing a CimSession with credentials and querying Win32_OperatingSystem. Retries up to MaxRetries with configurable delays to handle transient WinRM/DCOM initialization. CIM connectivity is required for hardware inventory and remote management operations.' `
            -DetailResults $instanceResults `
            -ValidatorName 'RemoteManagement' `
            -ResourceType 'CimSession' `
            -Remediation $lWRMTxt.CimSessionRemediation)
    }
    catch
    {
        throw ("New CimSession test failed: {0}" -f $_.Exception)
    }
}

function Test-NewPsSession
{
        [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $ComputerName,

        [Parameter()]
        [pscredential]
        $Credential,

        [int]
        $MaxRetries = 6,

        [int]
        $RetryDelaySeconds = 5
    )

    try
    {
        $severity = 'CRITICAL'
        $instanceResults = @()
        foreach ($computer in $ComputerName)
        {
            $psSession = $null
            $status = 'FAILURE'
            $dtl = @()
            try
            {
                # Create a new PsSession session with retries
                $attempt = 0
                do {
                    $attempt++
                    try {
                        $psSession = New-PsSession -ComputerName $computer -Credential $Credential
                        if ($psSession -is [System.Management.Automation.Runspaces.PSSession]) {
                            break
                        }
                    } catch {
                        if ($attempt -ge $MaxRetries) {
                            throw
                        }
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                } while ($attempt -lt $MaxRetries)
                # Test the PS session by returning the computername and IP
                if ($psSession -is [System.Management.Automation.Runspaces.PSSession])
                {
                    $dtl += $lWRMTxt.PsSessionSuccess -f $ENV:ComputerName, $psSession.ComputerName, "$attempt/$maxRetries"
                    $result = Invoke-Command -Session $psSession -ScriptBlock {
                        [PSCustomObject]@{
                            ComputerName = $ENV:COMPUTERNAME
                            IPAddress    = (Get-NetIPAddress -AddressFamily IPv4).IPAddress
                        }
                    }
                    if ($result -is [PSCustomObject])
                    {
                        $status = 'SUCCESS'
                        $dtl += $lWRMTxt.InvokeCommandSuccess -f $env:computername, $computer
                    }
                    else
                    {
                        $dtl += $lWRMTxt.InvokeCommandFailed -f $env:computername, $computer
                    }
                }
                else
                {
                    $dtl += $lWRMTxt.PsSessionNotEstablished -f $env:computername, $computer
                }
            }
            catch
            {
                $dtl += $lWRMTxt.PsSessionAttemptsFailed -f $env:computername, $computer, $attempt, $MaxRetries, $_.Exception.Message
            }
            finally
            {
                $detail = $dtl -join ". "
                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_RemoteManagement_PowerShell_Test' `
                    -Status $status `
                    -Severity $severity `
                    -TargetResourceName $computer `
                    -Source $ENV:COMPUTERNAME `
                    -Resource $computer `
                    -Detail $detail
                Log-Info $detail -Type $(if ( $status -eq 'FAILURE' ){ $severity } else { "INFO" } )

                if ($psSession -is [System.Management.Automation.Runspaces.PSSession])
                {
                    Remove-PSSession -Session $psSession
                    $psSession = $null
                }
            }
        }
        return @(New-AggregatedTestResult -TestName 'Test-NewPsSession' `
            -DisplayName 'PowerShell Session Connectivity' `
            -Description 'Validates PowerShell Remoting (WinRM) connectivity to each cluster node by creating a PSSession and executing a remote command to retrieve hostname and IP address. Retries up to MaxRetries with configurable delays. PSSession connectivity is a prerequisite for all remote validation operations and deployment actions.' `
            -DetailResults $instanceResults `
            -ValidatorName 'RemoteManagement' `
            -ResourceType 'PsSession' `
            -Remediation $lWRMTxt.PsSessionRemediation)
    }
    catch
    {
        throw ("New PsSession test failed: {0}" -f $_.Exception)
    }
}

function Test-NewPsSessionWithCredSSP
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $ComputerName,

        [Parameter()]
        [pscredential]
        $Credential,

        [int]
        $MaxRetries = 6,

        [int]
        $RetryDelaySeconds = 5
    )

    try
    {
        $severity = 'INFORMATIONAL'
        $instanceResults = @()
        foreach ($computer in $ComputerName)
        {
            $psSession = $null
            $status = 'FAILURE'
            $dtl = @()
            try
            {
                # Create a new PsSession session with retries
                $attempt = 0
                do {
                    $attempt++
                    try {
                        $psSession = New-PsSession -ComputerName $computer -Credential $Credential -Authentication CredSSP
                        if ($psSession -is [System.Management.Automation.Runspaces.PSSession]) {
                            break
                        }
                    } catch {
                        if ($attempt -ge $MaxRetries) {
                            throw
                        }
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                } while ($attempt -lt $MaxRetries)
                # Test the PS session by returning the computername and IP
                if ($psSession -is [System.Management.Automation.Runspaces.PSSession])
                {
                    $dtl += $lWRMTxt.PsSessionSuccess -f $ENV:ComputerName, $psSession.ComputerName, "$attempt/$maxRetries"
                    $result = Invoke-Command -Session $psSession -ScriptBlock {
                        [PSCustomObject]@{
                            ComputerName = $ENV:COMPUTERNAME
                            IPAddress    = (Get-NetIPAddress -AddressFamily IPv4).IPAddress
                        }
                    }
                    if ($result -is [PSCustomObject])
                    {
                        $status = 'SUCCESS'
                        $dtl += $lWRMTxt.InvokeCommandSuccess -f $env:computername, $computer
                    }
                    else
                    {
                        $dtl += $lWRMTxt.InvokeCommandFailed -f $env:computername, $computer
                    }
                }
                else
                {
                    $dtl += $lWRMTxt.PsSessionNotEstablished -f $env:computername, $computer
                }
            }
            catch
            {
                $dtl += $lWRMTxt.PsSessionAttemptsFailed -f $env:computername, $computer, $attempt, $MaxRetries, $_.Exception.Message
            }
            finally
            {
                $detail = $dtl -join ". "
                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_RemoteManagement_AuthCredSSP_PowerShell_Test' `
                    -Status $status `
                    -Severity $severity `
                    -TargetResourceName $computer `
                    -Source $ENV:COMPUTERNAME `
                    -Resource $computer `
                    -Detail $detail
                Log-Info $detail -Type $(if ( $status -eq 'FAILURE' ){ $severity } else { "INFO" } )

                if ($psSession -is [System.Management.Automation.Runspaces.PSSession])
                {
                    Remove-PSSession -Session $psSession
                    $psSession = $null
                }
            }
        }
        return @(New-AggregatedTestResult -TestName 'Test-NewPsSessionWithCredSSP' `
            -DisplayName 'CredSSP PowerShell Session Connectivity' `
            -Description 'Validates CredSSP (Credential Security Support Provider) delegation to each cluster node by creating a PSSession with -Authentication CredSSP and executing a remote command. CredSSP enables double-hop authentication required for accessing network resources from remote sessions. Retries up to MaxRetries with configurable delays.' `
            -DetailResults $instanceResults `
            -ValidatorName 'RemoteManagement' `
            -ResourceType 'CredSSPSession' `
            -Remediation $lWRMTxt.CredSSPRemediation)
    }
    catch
    {
        throw ("New PsSession CredSSP test failed: {0}" -f $_.Exception)
    }
}

function Test-RemoteEventLog
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $ComputerName,

        [Parameter()]
        [pscredential]
        $Credential,

        [int]
        $MaxRetries = 6,

        [int]
        $RetryDelaySeconds = 5
    )

    try
    {
        $severity = 'Warning'
        $instanceResults = @()
        foreach ($computer in $ComputerName)
        {
            Log-Info ($lWRMTxt.TestWinEvent -f $ENV:COMPUTERNAME, $computer, $Credential.UserName)
            $status = 'FAILURE'
            $dtl = @()
            try
            {
                # Check the event log for a specific event ID
                $attempt = 0
                do {
                    $attempt++
                    try {
                        $eventLog = Get-WinEvent -LogName System -ComputerName $computer -Credential $Credential -ErrorAction Stop | Where-Object { $_.Id -eq 6005 }
                        if ($eventLog) {
                            break
                        }
                    } catch {
                        if ($attempt -ge $MaxRetries) {
                            throw
                        }
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                } while ($attempt -lt $MaxRetries)
                if ($eventLog)
                {
                    $status = 'SUCCESS'
                    $numReboots = ($eventLog | Measure-Object).Count
                    $lastRebootTime = (($eventLog | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated)#.ToString("yyyy-MM-dd HH:mm:ss")
                    $dtl += $lWRMTxt.RemoteEventLogSuccess -f $computer, "$attempt/$maxRetries", $numReboots, $lastRebootTime
                }
                else
                {
                    $dtl += $lWRMTxt.RemoteEventLogEmpty -f $computer, "$attempt/$maxRetries"
                }
            }
            catch
            {
                $dtl += $lWRMTxt.RemoteEventLogFailed -f $computer, "$attempt/$MaxRetries", $_.Exception.Message
            }
            finally
            {
                $detail = $dtl -join ". "
                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_RemoteManagement_EventLog_Test' `
                    -Status $status `
                    -Severity $severity `
                    -TargetResourceName $computer `
                    -Source $ENV:COMPUTERNAME `
                    -Resource $computer `
                    -Detail $detail
                Log-Info $detail -Type $(if ( $status -eq 'FAILURE' ){ $severity } else { "INFO" } )
            }
        }
        return @(New-AggregatedTestResult -TestName 'Test-RemoteEventLog' `
            -DisplayName 'Remote Event Log Access' `
            -Description 'Validates Windows Event Log accessibility on each cluster node by querying System log for EventID 6005 (Event Log Service started) entries via Get-WinEvent with credentials. Reports boot history including reboot count and last reboot time. Retries up to MaxRetries with configurable delays.' `
            -DetailResults $instanceResults `
            -ValidatorName 'RemoteManagement' `
            -ResourceType 'EventLog' `
            -Remediation $lWRMTxt.EventLogRemediation)
    }
    catch
    {
        throw ("Remote Windows Event Log test failed: {0}" -f $_.Exception)
    }
}

function Test-RemoteWmiQuery {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $ComputerName,

        [Parameter()]
        [pscredential]
        $Credential,

        [int]
        $MaxRetries = 6,

        [int]
        $RetryDelaySeconds = 5
    )
    try
    {
        $severity = 'WARNING'
        $instanceResults = @()
        foreach ($computer in $ComputerName)
        {
            if ($computer -like "$ENV:COMPUTERNAME*")
            {
                # If the computer name matches the local machine, skip the test
                Log-Info "Skipping Remote WMI query test for local machine: $computer"
                continue
            }
            Log-Info ($lWRMTxt.WmiTest -f $ENV:COMPUTERNAME, $computer, $Credential.UserName)
            $status = 'FAILURE'
            $dtl = @()
            try
            {
                # Check WMI for install date
                $attempt = 0
                do {
                    $attempt++
                    try {
                        $wmiInstallDate = (Get-WmiObject -Class Win32_OperatingSystem -ComputerName $computer -Credential $Credential).InstallDate
                        if ($wmiInstallDate) {
                            break
                        }
                    } catch {
                        if ($attempt -ge $MaxRetries) {
                            throw
                        }
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                } while ($attempt -lt $MaxRetries)

                if ($wmiInstallDate)
                {
                    $status = 'SUCCESS'
                    $windowsInstallDateFormatted = ([Management.ManagementDateTimeConverter]::ToDateTime($wmiInstallDate))#.ToString("yyyy-MM-dd HH:mm:ss")
                    $dtl += $lWRMTxt.WmiQuerySuccess -f $computer, "$attempt/$maxRetries", $windowsInstallDateFormatted
                }
                else
                {
                    $dtl += $lWRMTxt.WmiQueryEmpty -f $computer, "$attempt/$maxRetries"
                }
            }
            catch
            {
                $dtl += $lWRMTxt.WmiQueryFailed -f $computer, "$attempt/$MaxRetries", $_.Exception.Message
            }
            finally
            {
                $detail = $dtl -join ". "
                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_RemoteManagement_WMI_Test' `
                    -Status $status `
                    -Severity $severity `
                    -TargetResourceName $computer `
                    -Source $ENV:COMPUTERNAME `
                    -Resource $computer `
                    -Detail $detail
                Log-Info $detail -Type $(if ( $status -eq 'FAILURE' ){ $severity } else { "INFO" } )
            }
        }
        return @(New-AggregatedTestResult -TestName 'Test-RemoteWmiQuery' `
            -DisplayName 'Remote WMI Query' `
            -Description 'Validates WMI (Windows Management Instrumentation) connectivity to each remote cluster node by querying Win32_OperatingSystem.InstallDate via Get-WmiObject. Skips the local orchestrator machine. Retries up to MaxRetries with configurable delays. WMI access is required for legacy management and inventory operations.' `
            -DetailResults $instanceResults `
            -ValidatorName 'RemoteManagement' `
            -ResourceType 'WmiQuery' `
            -Remediation $lWRMTxt.WmiQueryRemediation)
    }
    catch
    {
        throw ("Remote WMI query test failed: {0}" -f $_.Exception)
    }
}

Export-ModuleMember -Function Test-*

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCrt3hErFny10HS
# uoyf+X1Os288bUNGVSbJdRJXdg+976CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHWpkPno
# hrDwXJfOJ+uXaHuSbbEwopB7aEKSh7HYhd7mMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEADVjGUFnDYM06kXeAe2h+XY91S/OAZXWRlI5EWh4n
# WmVJxP9kYAfdb9eTMWAJLP3uEn2ZYTVZ8ZK01+e0lIAzozR5YQ6UOZa5Z1Kdhjv+
# Qi2eKFOId8hE0WyIAKo8v92ZwvGHNruampOBNJmP+Kt1sll71EEPyoFzhb4PxQsX
# 8F0TCdA8yQ5FkBnSjZAc6Cqee/kaWmiVtJ0NEeiFcXtdLVItgAA3T9LH5u/AuTyv
# LigvnTUNQtNRq9auEldXLpyppPWCk649wqT52JX+LPSVEX3Qiv2W5fklRscr/tlZ
# eUB2VvD2AOqAIZS3IlWYD2eLavjOHg5pj3poIWcUX/Vl96GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCByLmYwhGkonkf4zclOMd22J6oJOcMlIc4dlxrz
# bTB80QIGaed8mPROGBMyMDI2MDUwMzE0MzEyMC4yMzZaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiWAxzfGzap3SQABAAAC
# JTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMDFaFw0yNzA1MTcxOTQwMDFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCm8RIP0eLA46VcCPovvmqsIlN6
# qkmz5IsHWmUU0neUqp8uGxadeo+SwWBCwQ5alZI/DNdpXfyiZLZR6XYgpRPFzepI
# l7OCDb4NtEskJCIZDkQMNwrH9YwUyu71GGigsLIxeleHtA3utoVTeHjS1b8UnwOR
# RtknKkyrUArT6ZpB2rodIcmcLcv3x3wwgYlOs0FEg5EsVrZb7LNc/nd0bXDp+HTO
# WWui8eoTVwJeLxcVP869oF8li5SU81aa2tGJ6/Jsejiz9JMW8SJXKBT2DCXMOUkC
# sGjonPZRqfvoMSIQZgtaOTyAJlrvsy0TZ78XrGqoygtQimQnbOAL4KNLSCuW5TZE
# QGTHLOQJGgggb3j5gKC778+RIPJA+n/hmHJ/x4qT/HTTPoVeMCcuBKWrQXR1+/pY
# au3Fwe0tWIyG+LWzkRr/ZNPPupcA2Yci3qn8HR9RwvQopqSNJwn2Ri6am8AQyfVV
# y/BBw0t6jpoRPjwKvuUjfCzpae6duOxQtQ1XDN9PA2yl9sDko/+AXV/SOe8ea8Qo
# Qcv3s3ErkG+Lp6hnvw6OMPian4ggNkRtgtB7ro1OiopOUXJn9Y5EO3JUAXNcuM9m
# +5My1VEuvGytgAH3uxmslTnW3YbrfazaySCSSnWkhaOZ33hgbuUQfH7n2NFEAUc/
# cFzfmCQUikWisnJYywIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFLE40qoXTuMHX3Af
# ZUu1n8nx2h93MB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQAHnfc2yUyoHZbvvyVK
# FuXh5HxxHIvIaR9JWpIfITJlc/Ki03juR+vckzq3tp5fFH5LL7eIFXRIuoewMsvW
# eFrWufrrW4HhmhCwkqArfA1C0xk+HaYs2O48YSxMX9lgS1kTTIb3YsfoFdFpKurP
# f2nc2Yd4wLg+FgwmkxkeyE3MUKVna8SZeVpEjnS5ucFck4srPwK2ORAf70I23GGy
# PhqgIKZphNXhSscTAQsyIqB5GwDMdRV5LK37NfU4YmxvCYh3TFYE/Gh01Q6yJvf9
# HxiEZpwW+oUk0gruHobg3sgIR5rfgUo8l30vUnaDYMcPAClaFMC/QbHZSaUhWXZG
# 1OOcMp0g9vYQNLDEqFX2jlquvzVSSwtHtm1KTldCjRED+kdCybcPxbPalwJigXc1
# BsI9CitnTf0ljwb9NkZ/JVI8/D62rXXzhz4F3u0iVGzwncGaxRxHG/Xv4nTrpkOe
# epoYbNBbMWS2G1qP3Xj7pVf0+4qRyAqJ0stjQjoVOJImVPWRjz5PR3Dn6adQVMBJ
# DM6gDrj1rZTFVgCtTijqGZSGzvXpGkF3vYsyE6ZDma/kGdiUe5saeI6lH66PiWWX
# gqxt7sy2Ezv0yIjSVv+eMOT2QMUiZ6WCc7gVtAmXpfeIus+NmgFvM+Ic1X58e4I9
# EL4ZSAidSpWW0GZTLNC02mryLjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg2MDMtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQBTb+bKOPAjCBflhzw5EXBuSWxeDqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aHLODAiGA8y
# MDI2MDUwMzEzMjUxMloYDzIwMjYwNTA0MTMyNTEyWjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtocs4AgEAMAoCAQACAgkSAgH/MAcCAQACAhPHMAoCBQDtoxy4AgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAJV8kMndt1RaS2RHUeu9bTv3Ooq4
# sbCHczveImmDaZD+9+5yDMK1aidKHx38eLL6OhoR6wOP5qVwJPtP+1vjgrzudRM2
# cYOfXx/mK6i0OAJhoHSi+zl3+ZvDfaFjkILB2GVwxapBD5pwSYhmZq2OBuNNCc84
# HylnTF24l0zhrn3np+buejMVsjljsyKbS2rT+WwxwzwwMVDkwyFzsV6zDjj5d156
# mVbKefzLvVlVu/gE034l9o+piJbyDU8g819ygwR+W4CkYPqR7HRz+Unboa4CFhQ4
# F8fABmMet/ssAoLdTx4QBcHmemqrmgsujRbR82BUVKpJSFPK+w2LhDbea7cxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiWA
# xzfGzap3SQABAAACJTANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBGMLJ83x+3DyjIPjJ4WnjKeZJf
# aZu0ymJAjiMTmZJXyDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFYN7oh6
# ON3y92CmAl/lF0CYwrjWWQP6dCUxajPSHKEQMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIlgMc3xs2qd0kAAQAAAiUwIgQgOrqQiD8p
# rJMLOtfvraiqGafeCm8jnD39Hjc3g6/seDMwDQYJKoZIhvcNAQELBQAEggIALApi
# tx/zgsBOmJcQbE6UVuS2dUcfToXaj2qk+zTfXTjUWOpGbGb6B/NZ6j7hwApJimG3
# u01gwZY/hL9EOBfjGPs4XrfIdsDqQOf0f/E6aEGG4A+jfRa5H/5+mCrInPtsnPch
# PxBB5SZMWfeH7vDw9u1e6U73GaLyjmn2s1CaBnDkUuikUvugtEov3wM2gaB0o27K
# VNiuBq+pJaOzSSpCN3fgHXnhdPvbHmXaYAsApLocYnrsfoX45cPpZMddHBCT5IHu
# 71kqL6ISzhx/j8K1gIkFtZZAi2CDUAV3eXpdUXpuLoF2SIwkHLdbzaMisaEqJ+Oh
# sgL2yDkTZ2pPH2jLyLIAI0IMNls4X/Asgy+hn+lE+x518Mg/+srQv0+6gMm3+1D3
# CJbFFaOHGWqS2d8WHzIRCP7YtDGEbgHSGrW3zgzi1z1kfKnCvS1+R4NHh+dH5sHP
# hkrLPVzYUwaJriU/Ruq4DUX+VY9S2c/Jcv2nX8vf58DFTpqpJPCfUkBB0F2+g7P8
# ALDdGcc/IpVjSoxdXISnSLuu043w4RzqgP/gNdMHyKAAtaTfXutKJRGsKR8SMJBc
# SJ5rQD6fev1/FZoVNaCzJQL8MQTorEx6Lb6U+9M/XdqYr+UW7b0HMIad0tgrLRmm
# I7InAlwei6keVq9hupXq/oxlWh4RMJDFHTO94Nc=
# SIG # End signature block
