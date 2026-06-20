Import-LocalizedData -BindingVariable lcAdTxt -FileName AzStackHci.ExternalActiveDirectory.Strings.psd1

function Get-ParamFromCommandLineOrConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $ConfigurationJsonPath,

        [Parameter(Mandatory=$true)]
        [string]
        $ParameterName,

        [Parameter(Mandatory=$false)]
        [string]
        $CommandLineParameterValue,

        [Parameter(Mandatory=$true)]
        [string]
        $ParameterDescription,

        [Parameter(Mandatory=$true)]
        [string]
        $ValidationRegex
    )

    # If CommandLineParameterValue is set, then use it and the config file doesn't matter
    if ([string]::IsNullOrEmpty($CommandLineParameterValue))
    {
        # If the configuration file is present, check to see if the value exists under the DeploymentData object
        # If we can find it, we'll overwrite $CommandLineParameterValue (so we can check for that later to see if it worked)
        if (-not [string]::IsNullOrEmpty($ConfigurationJsonPath))
        {
            $configData = Get-Content -Path $ConfigurationJsonPath -ErrorAction SilentlyContinue | ConvertFrom-Json

            $deployData = $configData.ScaleUnits.DeploymentData | Select-Object -First 1

            if ($deployData)
            {
                if ($deployData.PSobject.Properties.name -eq $ParameterName)
                {
                    $CommandLineParameterValue = $deployData.PSobject.Properties.Item($ParameterName).Value
                }
            }
        }

        if ([string]::IsNullOrEmpty($ConfigurationJsonPath))
        {
            throw ($lcAdTxt.MissingRequiredParameter -f $ParameterName,$ParameterDescription)
        }
    }

    if (-not ($CommandLineParameterValue -match $ValidationRegex))
    {
        throw ($lcAdTxt.MalformedRequiredParameter -f $ParameterName,$CommandLineParameterValue,$ValidationRegex)
    }

    return $CommandLineParameterValue
}

function Get-ClusterNameFromCommandLineOrConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $ConfigurationJsonPath,

        [Parameter(Mandatory=$false)]
        [string]
        $CommandLineParameterValue,

        [Parameter(Mandatory=$true)]
        [string]
        $ParameterDescription,

        [Parameter(Mandatory=$true)]
        [string]
        $ValidationRegex
    )

    # If CommandLineParameterValue is set, then use it and the config file doesn't matter
    if ([string]::IsNullOrEmpty($CommandLineParameterValue))
    {
        # If the configuration file is present, check to see if the value exists under the DeploymentData object
        # If we can find it, we'll overwrite $CommandLineParameterValue (so we can check for that later to see if it worked)
        if (-not [string]::IsNullOrEmpty($ConfigurationJsonPath))
        {
            $configData = Get-Content -Path $ConfigurationJsonPath -ErrorAction SilentlyContinue | ConvertFrom-Json

            $deployData = $configData.ScaleUnits.DeploymentData | Select-Object -First 1

            if ($deployData)
            {
                $clusterEntry = $deployData.Cluster
                $CommandLineParameterValue = if ($clusterEntry) { $clusterEntry.Name } else { "" }
            }
        }

        if ([string]::IsNullOrEmpty($ConfigurationJsonPath))
        {
            throw ($lcAdTxt.MissingRequiredParameter -f "ClusterName",$ParameterDescription)
        }
    }

    if (-not ($CommandLineParameterValue -match $ValidationRegex))
    {
        throw ($lcAdTxt.MalformedRequiredParameter -f "ClusterName",$CommandLineParameterValue,$ValidationRegex)
    }

    return $CommandLineParameterValue
}

function Get-PhysicalHostNamesFromCommandLineOrConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $ConfigurationJsonPath,

        [Parameter(Mandatory=$false)]
        [array]
        $CommandLineParameterValue,

        [Parameter(Mandatory=$true)]
        [string]
        $ParameterDescription,

        [Parameter(Mandatory=$true)]
        [string]
        $ValidationRegex
    )

    try {
        # If the command line argument is specified, always use it
        if (-not $CommandLineParameterValue -or $CommandLineParameterValue.Length -eq 0)
        {
            # If the command line argument is not specified, check the unattend
            $configData = Get-Content -Path $ConfigurationJsonPath -ErrorAction SilentlyContinue | ConvertFrom-Json

            $deployData = $configData.ScaleUnits.DeploymentData | Select-Object -First 1

            if ($deployData)
            {
                $clusterEntry = $deployData.PhysicalNodesV2 | ForEach-Object {$_.Name}
                if ($clusterEntry -and $clusterEntry.Length -gt 0)
                {
                    # No command line argument, but we found it in unattend, so overwrite command line value
                    $CommandLineParameterValue = $clusterEntry
                }
            }
        }
    }
    catch {}

    if (-not $CommandLineParameterValue -or $CommandLineParameterValue.Length -eq 0)
    {
        throw ($lcAdTxt.MissingRequiredParameter -f "PhysicalMachineNames",$ParameterDescription)
    }

    $failedValidationRegexItems = $CommandLineParameterValue | Where-Object {$_ -notmatch $ValidationRegex}

    if ($failedValidationRegexItems -and $failedValidationRegexItems.Length -gt 0)
    {
        throw ($lcAdTxt.MalformedRequiredParameter -f "PhysicalMachineNames",$failedValidationRegexItems -join ", ",$ValidationRegex)
    }

    return $CommandLineParameterValue
}


function Install-GroupPolicyModule
{
    $modulePresent = $false

    try
    {
        $result = Get-Module -All | Where-Object { $_.Name -eq 'GroupPolicy' }
        if (-not $result)
        {
            # Module is not already imported.  See if it's available.
            $result = Get-Module -Refresh -ListAvailable | Where-Object { $_.Name -eq 'GroupPolicy' }

            if ($result)
            {
                $result | Import-Module -WarningAction Ignore
                $modulePresent = $true
            }
        }
        else
        {
            $modulePresent = $true
        }
    }
    catch
    {
        # Module not present and not importable.
    }

    if (-not $modulePresent)
    {
        if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
        {
            throw $lcAdTxt.NotRunningElevated
        }

        try
        {
            $capability = $null

            try
            {
                # See if we're on Windows 10 Oct 2018 update or later where it's a windows capability
                $capability = Get-WindowsCapability -Online | Where-Object {$_.Name -like 'Rsat.GroupPolicy*'}
            }
            catch {}

            if ($capability)
            {
                # Yes, Windows 10 Oct 2018 or later.  Check if it's present and add it if not
                if ($capability.State -ne 'Installed')
                {
                    ($capability | Add-WindowsCapability -Online)
                }
                else
                {
                    # The capability is present and installed, but the Get-Module above failed, so we should just bail
                    throw ($lcAdTxt.RsatCapabilityPresentButCantImport -f $capability.Name)
                }
            }
            else
            {
                # We're not on Windows 10 Oct 2018 or later.  If we're on a server sku (or a client with RSAT installed), we
                # may be able to find the optional feature to install
                $optionalFeature = Get-WindowsOptionalFeature -Online | Where-Object {$_.FeatureName -eq 'Microsoft-Windows-GroupPolicy-ServerAdminTools-Update'}

                if ($optionalFeature)
                {
                    # Feature is known, so see if it's enabled or enable-able
                    if ($optionalFeature.State -eq 'Enabled')
                    {
                        # Feature is known, and enabled, but still the previous efforts didn't find the module.  We should just bail.
                        throw ($lcAdTxt.RsatOptionalFeaturePresentButCantImport -f 'Microsoft-Windows-GroupPolicy-ServerAdminTools-Update')
                    }
                    else
                    {
                        # Feature is known, but not enabled
                        $result = ($optionalFeature | Enable-WindowsOptionalFeature -Online)
                    }
                }
                else
                {
                    # We cannot find the module from WindowsCapability or from WindowsOptionalFeature, and it wasn't in the available modules
                    # Not much we can do here except prompt the user to install RSAT
                    throw $lcAdTxt.MissingModuleAndRsat
                }
            }
        }
        catch
        {
            throw ($lcAdTxt.FailedToInstallRsat -f $_)
        }
    }

    if (-not $modulePresent)
    {
        # If we're here, it's because the module wasn't originally present, and our attempt at installing it seemed to be successful.  Try to find it again
        try
        {
            $result = Get-Module -Refresh -ListAvailable | Where-Object { $_.Name -eq 'GroupPolicy' }
            if ($result)
            {
                # AD module warns about finding a default server, but we'll specify everything later
                $result | Import-Module -WarningAction Ignore
            }
            else
            {
                throw $lcAdTxt.ModuleStillMissingAfterRsatInstall
            }
        }
        catch
        {
            throw ($lcAdTxt.FailToLoadModuleAfterRsatInstall -f $_)
        }
    }
}

function Install-ActiveDirectoryModule
{
    $modulePresent = $false

    try
    {
        $result = Get-Module -All | Where-Object { $_.Name -eq 'ActiveDirectory' }
        if (-not $result)
        {
            # Module is not already imported.  See if it's available.
            $result = Get-Module -Refresh -ListAvailable | Where-Object { $_.Name -eq 'ActiveDirectory' }

            if ($result)
            {
                # AD module warns about finding a default server, but we'll specify everything later
                $result | Import-Module -WarningAction Ignore
                $modulePresent = $true
            }
        }
        else
        {
            $modulePresent = $true
        }
    }
    catch
    {
        # Module not present and not importable.
    }

    if (-not $modulePresent)
    {
        if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
        {
            throw $lcAdTxt.NotRunningElevated
        }

        $windowsFeature = $null

        # See if we're on a server version that installs AD Powershell with Add-WindowsFeature
        try {
            $windowsFeature = Get-WindowsFeature -Name "RSAT-AD-PowerShell"
        }
        catch {
        }

        if ($windowsFeature -and $windowsFeature.InstallState -ne [Microsoft.Windows.ServerManager.Commands.InstallState]::Installed)
        {
            Add-WindowsFeature -Name "RSAT-AD-PowerShell" -IncludeAllSubFeature
        }

        $result = Get-Module -Refresh -ListAvailable | Where-Object { $_.Name -eq 'ActiveDirectory' }

        $modulePresent = ($null -ne $result)
    }

    if (-not $modulePresent)
    {
        try
        {
            $capability = $null

            try
            {
                # See if we're on Windows 10 Oct 2018 update or later where it's a windows capability
                $capability = Get-WindowsCapability -Online | Where-Object {$_.Name -like 'Rsat.ActiveDirectory*'}
            }
            catch {}

            if ($capability)
            {
                # Yes, Windows 10 Oct 2018 or later.  Check if it's present and add it if not
                if ($capability.State -ne 'Installed')
                {
                    ($capability | Add-WindowsCapability -Online)
                }
                else
                {
                    # The capability is present and installed, but the Get-Module above failed, so we should just bail
                    throw ($lcAdTxt.RsatCapabilityPresentButCantImport -f $capability.Name)
                }
            }
            else
            {
                # We're not on Windows 10 Oct 2018 or later.  If we're on a server sku (or a client with RSAT installed), we
                # may be able to find the optional feature to install
                $optionalFeature = Get-WindowsOptionalFeature -Online | Where-Object {$_.FeatureName -eq 'RSAT-ADDS-Tools-Feature'}

                if ($optionalFeature)
                {
                    # Feature is known, so see if it's enabled or enable-able
                    if ($optionalFeature.State -eq 'Enabled')
                    {
                        # Feature is known, and enabled, but still the previous efforts didn't find the module.  We should just bail.
                        throw ($lcAdTxt.RsatOptionalFeaturePresentButCantImport -f 'RSAT-ADDS-Tools-Feature')
                    }
                    else
                    {
                        # Feature is known, but not enabled
                        $result = ($optionalFeature | Enable-WindowsOptionalFeature -Online)
                    }
                }
                else
                {
                    # We cannot find the module from WindowsCapability or from WindowsOptionalFeature, and it wasn't in the available modules
                    # Not much we can do here except prompt the user to install RSAT
                    throw $lcAdTxt.MissingModuleAndRsat
                }
            }
        }
        catch
        {
            throw ($lcAdTxt.FailedToInstallRsat -f $_)
        }
    }

    if (-not $modulePresent)
    {
        # If we're here, it's because the module wasn't originally present, and our attempt at installing it seemed to be successful.  Try to find it again
        try
        {
            $result = Get-Module -Refresh -ListAvailable | Where-Object { $_.Name -eq 'ActiveDirectory' }
            if ($result)
            {
                # AD module warns about finding a default server, but we'll specify everything later
                $result | Import-Module -WarningAction Ignore
            }
            else
            {
                throw $lcAdTxt.ModuleStillMissingAfterRsatInstall
            }
        }
        catch
        {
            throw ($lcAdTxt.FailToLoadModuleAfterRsatInstall -f $_)
        }
    }

    # Sometimes we seem to import the module, but don't get the PS provider as well.  Should be safe to just import again here to see
    if (-not (Get-PSProvider -PSProvider ActiveDirectory -ErrorAction SilentlyContinue))
    {
        Import-Module 'ActiveDirectory' -Force
    }
    if (-not (Get-PSProvider -PSProvider ActiveDirectory -ErrorAction SilentlyContinue))
    {
        throw ("Can't find ActiveDirectory PSProvider!")
    }
}
# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBEKnzkisn2Tg4q
# HD9TaBvG08+zK3iazEUgm4LusZASL6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIBnlAIDwxL12lvmIgqvJ/itJzmokfzqka9/BxSQiQ0HSMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAV/S/qxGJ17WNUidRkb5R
# wj0ezjt/G+5bjDAarAWyxCTrrqD3nTggxWaJkokExWaiRdJvwr8kB360Tn/0hHzf
# bvypgTRhb+bauycTuJk6dG8q5DboxdgrCApbS7KcoEcduRImCerCUFrxfW/ixCDN
# DHZZipM2M6lt80xgMVOkqfc24/ChzQahOFS8EGRySG8ylR5ZMYNrWf6HL74x2MMF
# THR0bcWfGpeEH8Hj0eYHjA9EHopdrmmATxciHOAeOH2fGPygI+IgZ9UNvCM7QbGT
# CyDEXFkQfoI049u3w6TPMCIN67nFNLxRfkj7qJ5DkP/WTOxekGLa77LI9EHjqUwV
# xKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBD9w9hU3DxxfOEPAyt
# aFPIeLSnyAiXm2wBaGO4EdSUhAIGaetNikkgGBMyMDI2MDUwMzE0MzExMS40NzJa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2QjA1LTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACEUUYOZtDz/xsAAEAAAIRMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxM1oXDTI2MTExMzE4
# NDgxM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjZCMDUtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAz7m7MxAdL5Vayrk7jsMo3GnhN85ktHCZEvEcj4BIccHKd/NK
# C7uPvpX5dhO63W6VM5iCxklG8qQeVVrPaKvj8dYYJC7DNt4NN3XlVdC/voveJuPP
# hTJ/u7X+pYmV2qehTVPOOB1/hpmt51SzgxZczMdnFl+X2e1PgutSA5CAh9/Xz5NW
# 0CxnYVz8g0Vpxg+Bq32amktRXr8m3BSEgUs8jgWRPVzPHEczpbhloGGEfHaROmHh
# VKIqN+JhMweEjU2NXM2W6hm32j/QH/I/KWqNNfYchHaG0xJljVTYoUKPpcQDuhH9
# dQKEgvGxj2U5/3Fq1em4dO6Ih04m6R+ttxr6Y8oRJH9ZhZ3sciFBIvZh7E2YFXOj
# P4MGybSylQTPDEFAtHHgpkskeEUhsPDR9VvWWhekhQx3qXaAKh+AkLmz/hpE3e0y
# +RIKO2AREjULJAKgf+R9QnNvqMeMkz9PGrjsijqWGzB2k2JNyaUYKlbmQweOabsC
# ioiY2fJbimjVyFAGk5AeYddUFxvJGgRVCH7BeBPKAq7MMOmSCTOMZ0Sw6zyNx4Uh
# h5Y0uJ0ZOoTKnB3KfdN/ba/eKHFeEhi3WqAfzTxiy0rMvhsfsXZK7zoclqaRvVl8
# Q48J174+eyriypY9HhU+ohgiYi4uQGDDVdTDeKDtoC/hD2Cn+ARzwE1rFfECAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBRifUUDwOnqIcvfb53+yV0EZn7OcDAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEApEKdnMeIIUiU6PatZ/qbrwiDzYUMKRczC4Bp/XY1
# S9NmHI+2c3dcpwH2SOmDfdvIIqt7mRrgvBPYOvJ9CtZS5eeIrsObC0b0ggKTv2wr
# TgWG+qktqNFEhQeipdURNLN68uHAm5edwBytd1kwy5r6B93klxDsldOmVWtw/ngj
# 7knN09muCmwr17JnsMFcoIN/H59s+1RYN7Vid4+7nj8FcvYy9rbZOMndBzsTiosF
# 1M+aMIJX2k3EVFVsuDL7/R5ppI9Tg7eWQOWKMZHPdsA3ZqWzDuhJqTzoFSQShnZe
# nC+xq/z9BhHPFFbUtfjAoG6EDPjSQJYXmogja8OEa19xwnh3wVufeP+ck+/0gxNi
# 7g+kO6WaOm052F4siD8xi6Uv75L7798lHvPThcxHHsgXqMY592d1wUof3tL/eDaQ
# 0UhnYCU8yGkU2XJnctONnBKAvURAvf2qiIWDj4Lpcm0zA7VuofuJR1Tpuyc5p1ja
# 52bNZBBVqAOwyDhAmqWsJXAjYXnssC/fJkee314Fh+GIyMgvAPRScgqRZqV16dTB
# Yvoe+w1n/wWs/ySTUsxDw4T/AITcu5PAsLnCVpArDrFLRTFyut+eHUoG6UYZfj8/
# RsuQ42INse1pb/cPm7G2lcLJtkIKT80xvB1LiaNvPTBVEcmNSvFUM0xrXZXcYcxV
# XiYwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2QjA1LTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAKyp8q2VdgAq1VGkzd7PZwV6zNc2ggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hqOowIhgPMjAyNjA1MDMx
# MDU4NTBaGA8yMDI2MDUwNDEwNTg1MFowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7aGo6gIBADAHAgEAAgIdSzAHAgEAAgITnTAKAgUA7aL6agIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQBgB57UTG3oW5laL+2dLFT2Xh45fqSkKXnPj73YYYj4
# kAJ/W9hiUutbpZPEI6gJlZKJ5WD232iB7AdZZ+YbYTWMgEOX+UITe7jeOT+2Aob+
# VAl1PJPgYQCzEvY0yExE08o4JW6IFlw7GgkfjXgyP98BTmo7y0veDx/e/BZ2CI2R
# kInF1EkGED5AQGwc3cQTvTt1EtIV/Q5PYkUA+fPGiXUIujEWODHtgV4FCxqBM1iu
# qbzwv2+I5AhmurQKaKGzGVqvOFfrDQNfxu08o7ZT/dA+v6esvkA/lixxjuPX9oRN
# +6yLscgMScRSZUCgxQI6tSogZ4XtBNINdjZr+p9FVjSaMYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIRRRg5m0PP/GwAAQAA
# AhEwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQganL0t1Ze5PyRHJD1ueFg5mDOgjTT0APB5Puuu3Wh
# 3mwwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCAsrTOpmu+HTq1aXFwvlhjF
# 8p2nUCNNCEX/OWLHNDMmtzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACEUUYOZtDz/xsAAEAAAIRMCIEIFHdqckqPztfPR5SHvAKDAqW
# eSRimzk9kmF7IPFYNiguMA0GCSqGSIb3DQEBCwUABIICAI+aPQX9wxl8r/4gijXA
# BFJaWEZEWUa39q/iyQRuFtKdGXsUDcVWT6/r3TEFDV7Dr8dCoOr1dULRNGew4A9x
# cshCp1ot7/1fI1GvblIZVcR75D+JFIqJuVNPvd13M+a/22xcMqMtjdSQG3dHu1oa
# LsGqOcosA9HbXfRh19Bmb+1qxJYYbi47F3TaDGAxayLmh13Kf86uy/INlYzMdHG6
# 3U8BznWn0u4bMeTPHii+ZiW+kFUYB5YnIT7/IrYsfhaT+9jZK0uv2nNTSC8LcQ0r
# qx5Bcpw/wJaXpMgEcZU77M6Bt9kBMZ+cL4/mq7iFvSrbHIS6PgSr4Vs+pvPUSLce
# JEV54q1z0P3cf7d2tS85/xkLZc18dMpHXsYm9BZKukvyJ+eJK8cbY98BVSYRJeAk
# W4BPq2ie/AIBQJoLdfq/O/671cX+oXnBApoWrTnkSCAnRsVfu4YZlt5GMXmU0cI7
# cDalR9l6v3R0UqqrVR+S2FZ0+EdrX6x6DPBcoDWq6Y1FNrc8q3lgLErqwnp7J7Fv
# WUR/WOtrpImyFteQdYCGPQRjPKkt7XEC5d7KK1lcd/6YnLbn8B5v27WtFufFJnug
# /gdrGpeVXiYT9Xy/spBgsP6/kv91RrOXJa9tZzYXcnmFiROsAiChVizJxfM5IPzK
# eu6xilrf8HzebgyIUwiwvnXq
# SIG # End signature block
