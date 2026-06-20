Import-LocalizedData -BindingVariable lswTxt -FileName AzStackHci.Software.Strings.psd1

function Test-OSVersion
{
    <#
    .SYNOPSIS
        Validates that all cluster nodes are running the required OS version.
    .DESCRIPTION
        Queries the OS build version on each node via PSSession using Get-ItemPropertyValue
        on the CurrentBuild and UBR registry keys. Uses the local machine (ECE host) as the
        minimum required version baseline.

        Compares each node's build number against the minimum. Nodes below the required
        version are reported as failures.

        Asserts: All nodes have an OS version >= the ECE host version.
        Severity: CRITICAL — mismatched OS versions block deployment.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node (must include local machine).
    .PARAMETER MinimumVersion
        Optional explicit minimum version string. If not specified, uses the local machine's version.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter()]
        [string]
        $MinimumVersion
    )
    try
    {
        # Get All OS versions
        $OsVersion = @()
        $OsVersion = GetOSVersion -PsSession $PsSession

        # Get OS Version from local machine to use as desired OS version
        # Expecting data from PsSessions to include local machine indicating ECE.
        $localOs = $OsVersion | Where-Object ComputerName -EQ $ENV:COMPUTERNAME
        if ($localOs)
        {
            # Check local machine for minimum OS
            $instanceResults = @()
            $params = @{
                Version = $localOs
            }
            if ($MinimumVersion)
            {
                $params += @{MinVersion = $MinimumVersion}
            }
            $instanceResults += TestOsMinimumVersion @params
            # Check other nodes for consistency against local node
            $localOsVersion = $localOs | Select-Object -ExpandProperty OSVersion

            foreach ($version in ($OsVersion | Where-Object ComputerName -NE $ENV:COMPUTERNAME))
            {
                $detail = $lswTxt.OSVersion -f $version.OSVersion, $localOsVersion
                if ($version.OSVersion -eq $localOsVersion)
                {
                    $status = 'SUCCESS'
                    Log-Info ("Checking {0}. {1}" -f $version.ComputerName, $detail)
                }
                else
                {
                    $status = 'FAILURE'
                    Log-Info ("Checking {0}. {1}" -f $version.ComputerName, $detail) -type Warning
                }

                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_Software_OperatingSystem_Version' `
                    -Status $status `
                    -Severity 'CRITICAL' `
                    -TargetResourceName $version.ComputerName `
                    -Source $version.ComputerName `
                    -Resource 'OS Version' `
                    -Detail $detail

                # Check for matching build
                if (([system.version]$localOsVersion).Build -eq ([system.version]$version.OSVersion).Build)
                {
                    $status = 'SUCCESS'
                    $detail = $lswTxt.OSBuild -f $version.ComputerName, ([system.version]$version.OSVersion).Build, ([system.version]$localOsVersion).Build
                    Log-Info $detail
                }
                else
                {
                    $status = 'FAILURE'
                    $detail = $lswTxt.OSBuild -f $version.ComputerName, ([system.version]$version.OSVersion).Build, ([system.version]$localOsVersion).Build
                    Log-Info $detail -Type CRITICAL
                }

                $instanceResults += New-LightweightResult `
                    -Name 'AzStackHci_Software_OperatingSystem_Build' `
                    -Status $status `
                    -Severity 'CRITICAL' `
                    -TargetResourceName $version.ComputerName `
                    -Source $version.ComputerName `
                    -Resource 'OS Build' `
                    -Detail $detail
            }
            $minVer = if ($MinimumVersion) { $MinimumVersion } else { '10.0.19045' }
            return @(New-AggregatedTestResult -TestName 'Test-OSVersion' `
                    -DisplayName 'OS Version' `
                    -Description "Validates OS version consistency across cluster nodes by comparing each node's version and build number against the local orchestrator ($localOsVersion, minimum $minVer). Uses GetOSVersion via Invoke-Command to retrieve Win32_OperatingSystem.Version and ntoskrnl.exe ProductVersion from each node." `
                    -DetailResults $instanceResults `
                    -ValidatorName 'Software' `
                    -ResourceType 'OperatingSystem' `
                    -Remediation $lswTxt.OSVersionRemediation)
        }
        else
        {
            Log-Info $lswTxt.OSVersionSkip
        }
    }
    catch
    {
        throw $_
    }
}

function GetOSVersion
{
    <#
    .SYNOPSIS
        Get OS Version from local or remote
    #>

    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    $sb = {
        $osVersion = (Get-CimInstance -ClassName Win32_OperatingSystem -Property Version).Version
        $ntoskrnl = (Get-Item -Path (Join-Path -Path ([System.Environment]::SystemDirectory) -ChildPath 'ntoskrnl.exe')).VersionInfo.ProductVersion
        return New-Object PSObject -Property @{
            ComputerName = $ENV:COMPUTERNAME
            OSVersion    = [System.Version]("{0}.{1}" -f $osVersion,($ntoskrnl -Split '\.')[-1])
        }
    }
    $osVersion = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sb
    }
    else
    {
        Invoke-Command -ScriptBlock $sb
    }
    return $osVersion
}

function TestOsMinimumVersion
{
    <#
    .SYNOPSIS
        A short one-line action-based description, e.g. 'Tests if a function is valid'
    #>

    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject]
        $Version,

        [Parameter()]
        [system.version]
        $MinVersion = '10.0.19045'

    )
    try {
        if ($version.OSVersion -ge $MinVersion)
        {
            $Status = 'SUCCESS'
            $detail = $lswTxt.MinOSCheck -f $Version.ComputerName, $Version.OsVersion, $MinVersion
            Log-Info $detail -Type Info
        }
        else
        {
            $Status = 'FAILURE'
            $detail = $lswTxt.MinOSCheck -f $Version.ComputerName, $Version.OsVersion, $MinVersion
            Log-Info $detail -Type Warning
        }
        $instanceResult = New-LightweightResult `
            -Name 'AzStackHci_Software_OperatingSystem_Version' `
            -Status $status `
            -Severity 'CRITICAL' `
            -TargetResourceName $version.ComputerName `
            -Source $version.ComputerName `
            -Resource 'OS Version' `
            -Detail $detail
        return $instanceResult
    }
    catch {
        throw $_
    }
}

function GetNTPServer
{
    <#
    .SYNOPSIS
        Get NTP server from local or remote
    #>

    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    $sb = {
        $ntpSource = & w32tm.exe /query /source
        $ntpServer = ($ntpSource -split ',' | Select-Object -first 1).Trim()
        $retry = 0
        $maxRetry = 3
        do {
            $retry++
            if ($retry -gt 1) { Start-Sleep -Seconds 5 }
            $stripchart = & w32tm.exe /stripchart /computer:$ntpServer /dataonly /samples:1
        } while ($stripchart -match 'error' -and $retry -le $maxRetry)
        return New-Object PSObject -Property @{
            ComputerName = $ENV:COMPUTERNAME
            NtpServer    = $ntpServer
            Stripchart   = $stripchart
            Retries      = "$retry/$maxRetry"
        }
    }
    $ntpServer = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sb
    }
    else
    {
        Invoke-Command -ScriptBlock $sb
    }
    return $ntpServer
}

function Test-NtpServer
{
    <#
    .SYNOPSIS
        Validates NTP server configuration consistency and time synchronisation across nodes.
    .DESCRIPTION
        Queries each node's NTP source via w32tm /query /source through PSSession.
        Performs three checks:
        1. NTP source must not be 'Local CMOS Clock' (must be an external time source)
        2. All nodes must have the same NTP server configured (consistency)
        3. All nodes must be synchronised within acceptable skew (w32tm /query /status)

        Uses the ECE host's NTP configuration as the expected baseline.

        Asserts: All nodes point to the same external NTP source and are time-synced.
        Severity: CRITICAL for missing/misconfigured NTP, WARNING for sync skew.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    #>
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try {
        $ntpServerConfig = GetNTPServer -PsSession $PsSession
        $instanceResults = @()

        # localNtp should be read from local machine when running in ECE
        $localNtp = $ntpServerConfig | Where-Object ComputerName -EQ $ENV:COMPUTERNAME | Select-Object -ExpandProperty ntpServer

        # if it's not set to an external source return immediately with failure
        if ($localNtp -eq 'Local CMOS Clock')
        {
            $detail = $lswTxt.NTPServerNotSet -f $ENV:COMPUTERNAME, $localNtp
            Log-Info $detail -Type CRITICAL
            $instanceResults += New-LightweightResult `
                -Name 'AzStackHci_Software_NTP_Server' `
                -Status 'FAILURE' -Severity 'CRITICAL' `
                -TargetResourceName $ENV:COMPUTERNAME `
                -Source $ENV:COMPUTERNAME `
                -Resource 'NTP Server' `
                -Detail $detail
            return @(New-AggregatedTestResult -TestName 'Test-NtpServer' `
                    -DisplayName 'NTP Server Configuration' `
                    -Description "Checking NTP server configuration (w32tm /query /source). Source is 'Local CMOS Clock' - must be an external time source" `
                    -DetailResults $instanceResults `
                    -ValidatorName 'Software' `
                    -ResourceType 'OperatingSystem' `
                    -Remediation $lswTxt.NTPServerRemediation)
        }

        # Determine expected NTP server: local node's value or the most common value
        $expectedNtp = if ($localNtp) { $localNtp } else {
            ($ntpServerConfig | Group-Object ntpServer | Sort-Object Count -Descending | Select-Object -First 1).Name
        }

        # Check consistency: each node's NTP source should match expected
        $consistencyResults = @()
        if ($PsSession.Count -gt 1)
        {
            Log-Info ("Checking all nodes are configured with NTP Server: {0}" -f $expectedNtp)
            foreach ($nodeNtp in $ntpServerConfig)
            {
                $detail = $lswTxt.NTPServerCheck -f $nodeNtp.ComputerName, $nodeNtp.ntpServer, $expectedNtp
                if ($nodeNtp.ntpServer -eq $expectedNtp)
                {
                    $status = 'SUCCESS'
                    Log-Info $detail -Type Info
                }
                else
                {
                    $status = 'FAILURE'
                    Log-Info $detail -Type Warning
                }
                $consistencyResults += New-LightweightResult `
                    -Name 'AzStackHci_Software_NTP_Server_Consistency' `
                    -Status $status -Severity 'WARNING' `
                    -TargetResourceName $nodeNtp.ComputerName `
                    -Source $nodeNtp.ComputerName `
                    -Resource 'NTP Server' `
                    -Detail $detail
            }
        }

        # Check sync: each node should be synchronizing with its NTP source (w32tm /stripchart)
        $syncResults = @()
        foreach ($ntpCfg in $ntpServerConfig)
        {
            $stripChart = $ntpCfg.Stripchart
            if ($stripchart.Count -ge 4 -and (($stripchart[3] -like '*, +*') -or ($stripchart[3] -like '*, -*'))) {
                $status = 'SUCCESS'
                $detail = $lswTxt.NtpStripChartPass -f $ntpCfg.ComputerName, $ntpCfg.NtpServer, $stripchart[3]
                Log-Info $detail
            }
            else {
                $status = 'FAILURE'
                $failureDetail = $stripchart | Select-String -Pattern 'error'
                $detail = $lswTxt.NtpStripChartFail -f $ntpCfg.ComputerName, $ntpCfg.NtpServer, $failureDetail
                Log-Info $detail -Type CRITICAL
                $stripchart | ForEach-Object { Log-Info $_ -Type Warning }
            }
            $syncResults += New-LightweightResult `
                -Name 'AzStackHci_Software_NTP_Server_Sync' `
                -Status $status -Severity 'CRITICAL' `
                -TargetResourceName $ntpCfg.ComputerName `
                -Source $ntpCfg.ComputerName `
                -Resource 'NTP Server Sync' `
                -Detail $detail
        }

        $results = @()
        if ($consistencyResults.Count -gt 0) {
            $results += @(New-AggregatedTestResult -TestName 'Test-NtpServer-Consistency' `
                    -DisplayName 'NTP Server Consistency' `
                    -Description "Checking all nodes have the same NTP source (w32tm /query /source, expected: $expectedNtp)" `
                    -DetailResults $consistencyResults `
                    -ValidatorName 'Software' `
                    -ResourceType 'OperatingSystem' `
                    -Remediation $lswTxt.NTPConsistencyRemediation)
        }
        $results += @(New-AggregatedTestResult -TestName 'Test-NtpServer-Sync' `
                -DisplayName 'NTP Server Sync' `
                -Description "Checking NTP time synchronization on each node (w32tm /stripchart /computer:$expectedNtp)" `
                -DetailResults $syncResults `
                -ValidatorName 'Software' `
                -ResourceType 'OperatingSystem' `
                -Remediation $lswTxt.NTPSyncRemediation)
        return $results
    }
    catch {
        throw $_
    }
}

function Test-LocalGroupEnumeration
{
    <#
    .SYNOPSIS
        Validates that the local Administrators group can be enumerated on each node.
    .DESCRIPTION
        Runs Get-LocalGroupMember against the built-in Administrators group (SID S-1-5-32-544)
        on each node via PSSession. This validation exists because certain environments have
        corrupted or orphaned SIDs in the local Administrators group which cause
        Get-LocalGroupMember to fail — blocking deployment operations that rely on local
        admin group membership queries.

        Asserts: Get-LocalGroupMember -SID S-1-5-32-544 succeeds on every node.
        Severity: CRITICAL — enumeration failure blocks deployment.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    #>

    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $instanceResults = @()
        $sb = {
            try {
                # Get-LocalGroupMember doesn't play nice with error stream, assigning to variable to get around this.
                $errorDetail = $null
                $localAdminGroup = Get-LocalGroupMember -SID S-1-5-32-544 -ErrorVariable errorDetail
            }
            catch {
                $localAdminGroup = $null
                if ([string]::IsNullOrEmpty($errorDetail))
                {
                    $errorDetail = $_.Exception.Message
                }
            }
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                LocalAdminGroupTest  = [bool]$localAdminGroup
                errorDetail = $errorDetail
            }
        }
        $localGroupTests = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb -ErrorAction SilentlyContinue
        }
        else
        {
            Invoke-Command -ScriptBlock $sb -ErrorAction SilentlyContinue
        }

        $localGroupTests | ForEach-Object {
            $localGroup = $_
            if ($localGroup.LocalAdminGroupTest)
            {
                $status = 'SUCCESS'
                $detail = $lswTxt.LocalGroupEnumerationSuccess -f $localGroup.ComputerName
                Log-Info $detail
            }
            else
            {
                $status = 'FAILURE'
                $detail = $lswTxt.LocalGroupEnumerationFailure -f $localGroup.ComputerName, $localGroup.errorDetail
                Log-Info $detail -Type CRITICAL
            }

            $instanceResults += New-LightweightResult `
                -Name 'AzStackHci_Software_LocalGroupEnumeration' `
                -Status $status `
                -Severity 'CRITICAL' `
                -TargetResourceName "$($localGroup.ComputerName)/Administrators" `
                -Source $localGroup.ComputerName `
                -Resource 'Local Group' `
                -Detail $detail
        }
        return @(New-AggregatedTestResult -TestName 'Test-LocalGroupEnumeration' `
                -DisplayName 'Local Group Enumeration' `
                -Description 'Validates local Administrators group (SID S-1-5-32-544) can be enumerated via Get-LocalGroupMember on each node. Enumeration failures indicate stale domain references or orphaned SIDs that block deployment.' `
                -DetailResults $instanceResults `
                -ValidatorName 'Software' `
                -ResourceType 'OperatingSystem' `
                -Remediation $lswTxt.LocalGroupRemediation)
    }
    catch {
        throw $_
    }
}

function Test-IsNotPartofDomain
{
    <#
    .SYNOPSIS
        Validates that no cluster node is pre-joined to an Active Directory domain.
    .DESCRIPTION
        Queries (Get-WmiObject Win32_ComputerSystem).PartOfDomain on each node via PSSession.
        Nodes must not be domain-joined before Azure Local deployment — the deployment process
        handles domain join as part of the EnvironmentValidatorFull action plan (Step 150).

        Asserts: PartOfDomain is $false on every node.
        Severity: CRITICAL — pre-joined nodes will cause domain join step to fail.
    .PARAMETER PsSession
        PowerShell remoting sessions to each cluster node.
    #>

    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $instanceResults = @()
        $sb = {
            $PartOfDomain = [bool](Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain
            return New-Object PSObject -Property @{
                ComputerName = $ENV:COMPUTERNAME
                PartOfDomain = $PartOfDomain
            }
        }
        $domainTests = if ($PsSession)
        {
            Invoke-Command -Session $PsSession -ScriptBlock $sb
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }

        foreach ($domainTest in $domainTests)
        {
            if ($domainTest.PartOfDomain)
            {
                $status = 'FAILURE'
                $detail = $lswTxt.IsNotPartofDomainFailure -f $domainTest.ComputerName
                Log-Info $detail -Type CRITICAL
            }
            else
            {
                $status = 'SUCCESS'
                $detail = $lswTxt.IsNotPartofDomainSuccess -f $domainTest.ComputerName
                Log-Info $detail
            }

            $instanceResults += New-LightweightResult `
                -Name 'AzStackHci_Software_IsNotPartofDomain' `
                -Status $status `
                -Severity 'CRITICAL' `
                -TargetResourceName $domainTest.ComputerName `
                -Source $domainTest.ComputerName `
                -Resource 'Domain' `
                -Detail $detail
        }
        return @(New-AggregatedTestResult -TestName 'Test-IsNotPartofDomain' `
                -DisplayName 'Domain Membership' `
                -Description 'Validates nodes are not pre-joined to an Active Directory domain by querying (Get-WmiObject Win32_ComputerSystem).PartOfDomain on each node. Nodes must not be domain-joined before Azure Local deployment.' `
                -DetailResults $instanceResults `
                -ValidatorName 'Software' `
                -ResourceType 'OperatingSystem' `
                -Remediation $lswTxt.DomainMembershipRemediation)
    }
    catch {
        throw $_
    }
}

Export-ModuleMember -Function Test-*
Export-ModuleMember -Function GetOSVersion
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCERGdsXlg4NUVj
# eUWOIgui/r7QBIJVeKLhvinFgdkBaKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIDUBGXeO
# WEz/zhjbP5gAr6V5XASD+1CKSj8vKMCY8xKLMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAnPox+TM7hUO4RkNnhmQWfHC7vFhrSbJAaXd+ERqB
# JFvPpUz3ZBwjslZ47qxmmBHy9LWTVy8jpLlHrlPoiq/YyEb4BbZqPPNFY2kSCVVV
# FuJyurkT5D0hnvSvn/w6POuqf2WemNJb/gwJUecqWVw+mYyV3/Z9keJwHYlcqmgQ
# FkcfIXgj+mRg21wIJ89YOw8c0E0AtdGa2Z8MsoFz6lXXlMbknk2NVrvHeLxTEGDp
# yNrBOV7rrDUf4uUCacym5ZiJ9hPYuBB2CD412VbDThIw8Pw00z+JhmR35qBetURD
# WQrdeJJQ3CQk7eVpyxGSjxYefx4iuQR/DFbl79/9kL70cqGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCATtyhVp15C5VD7ojNI9k7h2XyZQYPlTfZ82Oga
# vLDbKgIGaeexRuPgGBMyMDI2MDUwMzE0MzExMS4zOTdaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDFPbr05vxdPiLF4WXXQ4JmK87P
# TorVda9zo/YnqiD8VDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIAVgXQEK
# BOfGgjNskmDOmbcEIOnHGNwA+QcRufDR5AkTMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIiQdL2qv/Itf8AAQAAAiIwIgQge0BYPU+G
# OOQNtThs8JIT4pVZxK+0CdTvxImeg/PVxbcwDQYJKoZIhvcNAQELBQAEggIAVbMk
# wLiOqrCngYGRjtJYm7CVxhVOpl36OVPqmdBQom1jvxKbmkN99RJNsWlIUQxq5M0q
# G5j7jirF8xsL6tzgkuqLT7f8L8NP9ukIG+qO1V/Jtul6d2ZAVKJSiFdcv4iPNjQj
# 7BWBGE/CtPs7gOmnRTxw+TfeitLJctO3epJCEpGb7AfgOH52vVRg57Hd0ZiVP7Di
# bvFXIl29NPNpysQXXyA0hso4oFVJ44F7IdQLHIv90bTUv3fNG2Ekl4+zf7B2bnEq
# McMHu+XWxr+MGtOwVhAGvTINZvxpVu1sMUgNfhSVvAcWGa80EvQEXZd5d3B2nk/c
# PxMn1Efuu8XIUrfTMgCpRgPuLpmjmvwsYCp+OMfxuyjgQsVzF42J5rrobsyZ7u2L
# zYdEfe3JL0QfUnPEPbc6CIPMXYsyQvf77RbZN/Irr35ddzoe20oMNoDshCOmOmkR
# ZTnVc7f11Zpwmx8GlXPZ9GKGT8OLuPcYYbVPWODIsafkeHEHie67xLLsrKTR6pFy
# 15WckznkFVBEwdUiReS3O0OySUm3MP6bn/GtjpcJYEp8qkzSRXN+bDNoRIvQM6Js
# Xjge4m8Ur1+pyjYGP8cmdtzdiDw1lNruGhpDQneq524niWvGwNHnVUvnzAqZaQG/
# LtEPPmkv+cm41G0ydQtIQF7R+XR2h7eGXsbscjc=
# SIG # End signature block
