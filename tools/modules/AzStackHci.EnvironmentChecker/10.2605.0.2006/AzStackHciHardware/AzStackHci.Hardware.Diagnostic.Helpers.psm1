Import-LocalizedData -BindingVariable lhwTxt -FileName AzStackHci.Hardware.Strings.psd1
function Get-NetAdapterSupport
{
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )

    $sb = {
        $NICSupportExplanation = $args[0]
        # Add ScriptProperty scriptBlocks to return the reason why a NIC is not supported
        $nicNotSupportedReasonSB = {
            if ($this.NdisMedium -eq 0 -and $this.Status -eq 'Up' -and $this.NdisPhysicalMedium -eq 14 -and $this.PnPDeviceID -notlike 'USB\*')
            {
                return $null
            }
            else
            {
                $reason = New-Object -TypeName PsObject -Property @{
                    NdisMediumIsEthernet = $this.NdisMedium -eq 0
                    StatusIsUp = $this.Status -eq 'Up'
                    NdisPhysicalMediumIsEthernet = $this.NdisPhysicalMedium -eq 14
                    PnPDeviceIDIsNotUSB = $this.PnPDeviceID -notlike 'USB\*'
                    Explanation = $NICSupportExplanation
                }
                return $reason
            }
        }

        # ScriptProeprty script block to return if the disk is supported (ie HCISupportedHelp is empty/null)
        $nicSupportedSB = {
            if ([string]::IsNullOrEmpty($this.HCISupportedHelp))
            {
                return $true
            }
            else
            {
                return $false
            }
        }

        $cimData = @(Get-NetAdapter -Physical)
        $cimData | Add-Member -MemberType ScriptProperty -Name HCISupportedHelp -Value $nicNotSupportedReasonSB
        $cimData | Add-Member -MemberType ScriptProperty -Name HCISupported -Value $nicSupportedSB

        return (New-Object PsObject -Property @{
            ComputerName = $ENV:ComputerName
            cimData = $cimData
        })
    }
    $remoteOutput = if ($PsSession)
    {
        Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList $lhwTxt.NICSupportExplanation
    }
    else
    {
        Invoke-Command -ScriptBlock $sb
    }
    return $remoteOutput
}

function Get-PhysicalDiskSupport
{
    [CmdletBinding()]
    param (
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $sb = {
            $fabricOp = $args[0]
            $eceNodeName = $args[1]
            $GreenfieldNotSupportedExplanation = $args[2]
            $RepairNotSupportedExplanation = $args[3]
            $ECEReferenceNotSupportedExplanation = $args[4]
            $allowedBusTypes = @('SATA', 'SAS', 'NVMe', 'SCM')
            $allowedMediaTypes = @('HDD', 'SSD', 'SCM')
            # SAN-attached disks (Fibre Channel, iSCSI) are validated by the SAN validator, not here
            $sanBusTypes = @('Fibre Channel', 'iSCSI')
            $bootPhysicalDisk = Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | Get-PhysicalDisk

            # Add ScriptProperty scriptBlocks to return the reason why a disk is not supported
            # This will change with each scenario...
            ## Greenfield - Disks must be clean (canpool:true, right bustype, mediatype and not a boot device)
            $greenfieldNotSupportedReasonSB = {
                if ($this.BusType -in $allowedBusTypes -and `
                    $this.MediaType -in $allowedMediaTypes -and `
                    $this.DeviceId -notin $bootPhysicalDisk.DeviceId -and `
                    $this.CanPool -eq $true)
                {
                    return $null
                }
                else
                {
                    $reason = New-Object -TypeName PsObject -Property @{
                        CanPool = $this.CanPool
                        CannotPoolReason = $this.CannotPoolReason
                        BusTypeIsSupported = $this.BusType -in $allowedBusTypes
                        MediaTypeIsSupported = $this.MediaType -in $allowedMediaTypes
                        IsBootDevice = $this.DeviceId -in $bootPhysicalDisk.DeviceId
                    } | Select-Object CanPool, CannotPoolReason, BusTypeIsSupported, MediaTypeIsSupported, IsBootDevice
                    return $reason
                }
            }

            ## Repair - Disks must be the right bustype, mediatype and not a boot device but they can be dirty we don't care.
            $repairNotSupportedReasonSB = {
                if ($this.BusType -in $allowedBusTypes -and `
                    $this.MediaType -in $allowedMediaTypes -and `
                    $this.DeviceId -notin $bootPhysicalDisk.DeviceId)
                {
                    return $null
                }
                else
                {
                    $reason = New-Object -TypeName PsObject -Property @{
                        BusTypeIsSupported = $this.BusType -in $allowedBusTypes
                        MediaTypeIsSupported = $this.MediaType -in $allowedMediaTypes
                        IsBootDevice = $this.DeviceId -in $bootPhysicalDisk.DeviceId
                    } | Select-Object BusTypeIsSupported, MediaTypeIsSupported, IsBootDevice
                    return $reason
                }
            }

            ## ECE reference - Disk must be in a pool already, we assume bustype and mediatype are correct, otherwise we wouldnt be here.
            $eceReferenceNotSupportedReasonSB = {
                if ($this.CanPool -eq $false -and $this.CannotPoolReason -eq 'In a Pool')
                {
                    return $null
                }
                else
                {
                    $reason = New-Object -TypeName PsObject -Property @{
                        CanPool = $this.CanPool
                        CannotPoolReason = $this.CannotPoolReason
                        BusTypeIsSupported = $this.BusType -in $allowedBusTypes
                        MediaTypeIsSupported = $this.MediaType -in $allowedMediaTypes
                        IsBootDevice = $this.DeviceId -in $bootPhysicalDisk.DeviceId
                    } | Select-Object CanPool, CannotPoolReason, BusTypeIsSupported, MediaTypeIsSupported, IsBootDevice
                    return $reason
                }
            }

            # Set the supported logic based on fabric operation as a scriptproperty applied against the cimdata
            if ($fabricOp -match 'AddNode|Repair')
            {
                if ($eceNodeName -eq $env:COMPUTERNAME)
                {
                    # In AddNode we need a seperate check command to return disks that are spaces disks
                    # to build a reference list for the new node
                    $diskSupportedDataSB = $eceReferenceNotSupportedReasonSB
                    $IsSupportedHelp = $ECEReferenceNotSupportedExplanation
                }
                else
                {
                    if ($fabricOp -like "*AddNode*")
                    {
                        # For AddNode node we expect CanPool true and to match ECE node above
                        $diskSupportedDataSB = $greenfieldNotSupportedReasonSB
                        $IsSupportedHelp = $GreenfieldNotSupportedExplanation
                    }
                    elseif ($fabricOp -like "*Repair*")
                    {
                        $diskSupportedDataSB = $repairNotSupportedReasonSB
                        $IsSupportedHelp = $RepairNotSupportedExplanation
                    }
                    else
                    {
                        throw "Invalid Fabric Operation: $fabricOp"
                    }
                }
            }
            else
            {
                if ($fabricOp -like '*KeepStorage*')
                {
                    $diskSupportedDataSB = $repairNotSupportedReasonSB
                    $IsSupportedHelp = $RepairNotSupportedExplanation
                }
                else
                {
                    $diskSupportedDataSB = $greenfieldNotSupportedReasonSB
                    $IsSupportedHelp = $greenfieldNotSupportedExplanation
                }
            }

            # return the reason why a disk is not supported
            $diskNotSupportedReasonHelpSB = {
                if ($this.HCISupportedData)
                {
                    return $this.HCISupportedData.Explanation
                }
                else
                {
                    return $null
                }
            }

            # ScriptProeprty script block to return if the disk is supported (ie HCISupportedHelp is empty/null)
            $diskSupportedSB = {
                if ([string]::IsNullOrEmpty($this.HCISupportedData))
                {
                    return $true
                }
                else
                {
                    return $false
                }
            }

            # Get all physical disks that are connected to the node in array and dertermine supportability
            # Exclude SAN-attached disks as they are validated by the SAN validator
            $cimData = @(Get-StorageNode -Name $env:COMPUTERNAME* | Get-PhysicalDisk -PhysicallyConnected | Where-Object { $_.BusType -notin $sanBusTypes })
            $cimData | Add-Member -MemberType ScriptProperty -Name HCISupportedData -Value $diskSupportedDataSB
            $cimData | Add-Member -MemberType ScriptProperty -Name HCISupported -Value $diskSupportedSB

            return (New-Object PsObject -Property @{
                    ComputerName = $ENV:ComputerName
                    DiskData     = $cimData | Select-Object @{l='ServerName';e={$_.CimSystemProperties.ServerName}}, UniqueId, HCISupported, HCISupportedData
                    IsSupportedHelp = $IsSupportedHelp
                    Scenario = $fabricOp
            })
        }
        $remoteOutput = if ($PsSession)
        {
            # When we are using PsSessions (every ECE fabric operation)
            # Inject our FabricOperation and local computer into the remote session,
            # so canPool expectation can be set for deployment and ScaleOut.
            Invoke-Command -Session $PsSession -ScriptBlock $sb -ArgumentList $ENV:EnvChkrId, $ENV:ComputerName, $lhwTxt.GreenfieldNotSupportedExplanation, $lhwTxt.RepairNotSupportedExplanation, $lhwTxt.ECEReferenceSupportedExplanation
        }
        else
        {
            Invoke-Command -ScriptBlock $sb
        }
        return $remoteOutput
    }
    catch
    {
        Log-Info -Message "Failed to get diagnostic disk information: Error: $($_.Exception.Message)" -Type Error
    }
}

function Get-PhysicalDiskSupportSummary
{
    [CmdletBinding()]
    param (
        [psobject[]]
        $PhysicalDiskSupportData
    )

    # Write a text summary to append to test that invoked this function
    $supporteddetail = "`r`n`r`n## Supported Data Disk Diagnostic Helper ##`r`n`r`n"
    foreach ($nodeOutput in $PhysicalDiskSupportData)
    {
        $supporteddetail += "`r`nNode: $($nodeOutput.ComputerName)`r`n"
        $supporteddetail += "HealthCheckSource: $($nodeOutput.Scenario)`r`n"
        $supporteddetail += "Requirements for data disks on this node: $($nodeOutput.IsSupportedHelp)`r`n"
        $supporteddetail += "`r`nUnsupported DataDisks:`r`n{0}" -f ($nodeOutput.DiskData | Where-Object {!$_.HCISupported} | Select-Object HCISupported, HCISupportedData, UniqueId | ConvertTo-Csv -NoTypeInformation | Out-String) -replace '"',''
        $supporteddetail += "`r`n"
        $supporteddetail += "Supported DataDisks:`r`n{0}" -f ($nodeOutput.DiskData | Where-Object {$_.HCISupported} | Select-Object HCISupported, UniqueId | ConvertTo-Csv -NoTypeInformation | Out-String) -replace '"',''
    }

    # Always write the output to log file
    Log-Info -Message "Retrieved supported data disk information for $($supportedDiskDetail.ComputerName | Sort-Object | Get-Unique | Measure-Object | Select-Object -ExpandProperty Count) nodes."
    $supporteddetail -split "`r`n" | Foreach-Object { if (-not [string]::IsNullOrEmpty($_)) { Log-Info $_ }}

    # If the detail is too long, we need to remove it and provide a link to the log file
    if ($supporteddetail -gt 20000)
    {
        $supporteddetail = "Disk Info too long to display. Use Get-PhysicalDiskSupport to see details. Or check $AzStackHciEnvironmentLogFile on $($ENV:COMPUTERNAME)"
    }
    return $supporteddetail
}

Export-ModuleMember -Function Get-*
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB48BUwfOBY2MW0
# hjB+tr1QSW0VInXAJBYsjHZEpKMIjaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIDeeCK1B
# 6WvDSpAHoHRMPk5XcpQ0qX8qARf3ZIbHH/qFMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAa/IN9UyROop/H5gG/HRlb2Wd3441NrbDRha85wsy
# 5i2UpyCSKZkyo2ror6lKkfbVSToJNzyxJcxhREUf4hi3DJAjyhTPBygIcsyNVs4t
# Aqy2vDGcOsMGxay7oDEn2TzMBklSnfbeRSp5/ZOYGshS4Wos1jiebQP5CblSin3J
# esu3q2WUxf01pab1h97YNZEWXs0k6xkpRF/++ILYImES1B+y98Nu6cXZSNY6VHKl
# JqmCo57dZhKR93iU9pC9INVbHGbGi1fFF2saSrXrUBrwRELwwDvgJBFPKjARr/Zx
# qFy2swE/kOdlU3ythE75E7fFyi7nZXzxcMfXPxGrhK6nD6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAs9miO+aK97jXrnCOVT0MpQvF3u2eibi+8Mzd/
# QgGwUAIGaed8mPPtGBMyMDI2MDUwMzE0MzEwOS44NzNaMASAAgH0oIHRpIHOMIHL
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
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDHq2eO12g4jpTEesqZPb+G8hgo
# PNqHy/2LzpXqkg4XLDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFYN7oh6
# ON3y92CmAl/lF0CYwrjWWQP6dCUxajPSHKEQMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIlgMc3xs2qd0kAAQAAAiUwIgQgOrqQiD8p
# rJMLOtfvraiqGafeCm8jnD39Hjc3g6/seDMwDQYJKoZIhvcNAQELBQAEggIALhlZ
# A46P2uXlbICgiqKnX9WPFpKrdvQs6poiZj/gwQvXA59pDjAGf4+HqU/svwfHhm50
# QkVonOP5D1FN0xzTUEYaopzYtaxJKmOE9ESBOqABdiiGQROBJdMzTfiO3MuU3AZS
# cKy9dP//WFfE0G+1PtB5FiNqoKv7O2iCLYu5eVjMWoo0dTbFr9kFOu/f9z+3aoAv
# Jq+gPQXQGJ3B1nRJmhVYCr4t4ph1pl/S2m0WxPIEQKGYT4S/T/PqKmihIm3DpCkU
# o9aTSDPdJXJiFApxFtq89l+N1VysU+uFsrGn4ad8XkEgCa7KFK1DTXFFQ+SnbwNf
# fKnHNvAlywf0wFv8pak6JEF/5KUhz+bYsGBsolj89sbnBAYwp3Nbfh/6+lwUtzow
# yBoto8fut0wP5ABNp/NNyFZpCIIi9r8lPl2gkgGe5KU4TSLRlMZQ5StjGyeM80V7
# OdJu2eJLzE00jOirGF64wQhQvdfNhmnkvHCSSi3Lcj6V5CP9qUAi+UmqYkQqqr3v
# 7VfeXSneoyGWyfVFZ1sPYOKppQMwLh6eNg8PZqpMhKEHBVkqpxwmS2KTDf3OEFs3
# Y5mu8LQEGSxZZTtEovYR0P4aF87bDmZDaBl4WsmHzfX9HMo3V5rih469k00ANPF7
# LiTfj1mOo1MczyF2oiOgjIdSKDjHJMs4QiFo3O4=
# SIG # End signature block
