Import-LocalizedData -BindingVariable lnTxt -FileName AzStackHci.Storage.Strings.psd1

# Test Methods

function Test-HciStoragePool {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Pool configuration xml from Storage role.")]
        [XML]
        $PoolConfigXml,

        [Parameter(Mandatory = $true, HelpMessage = "Total number of cluster nodes.")]
        [uint32]
        $NodeCount
    )
    try {

        $instanceResult = @{}
        $instanceResult.Name = 'AzStackHci_Storage_Test_Storage_Pool'
        $instanceResult.Title = 'Test Storage Pool'
        $instanceResult.DisplayName = 'Test Storage Pool'
        $instanceResult.Severity = 'CRITICAL'
        $instanceResult.Description = 'Checking storage pool for upgrade readiness'
        $instanceResult.TargetResourceID = 'StoragePool'
        $instanceResult.TargetResourceName = '(None)'
        $instanceResult.TargetResourceType = 'Storage Pool'
        $instanceResult.Timestamp = [datetime]::UtcNow
        $instanceResult.HealthCheckSource = $ENV:EnvChkrId
        $instanceResult.Status = 'SUCCESS'

        # Get storage pool
        $pool = Get-StoragePool -IsPrimordial:$false -ErrorAction Ignore
        Log-Info -Message "Storage Pool: `n$($pool | Format-Table | Out-String)"

        # Get S2D status
        $s2d = Get-ClusterS2D -ErrorAction Ignore
        Log-Info -Message "ClusterS2D: `n$($s2d | Format-List | Out-String)"
        $s2dEnabled = $s2d -and $s2d.State -eq 'Enabled'

        # Check pool existence vs S2D status, only below combinations are valid
        #   1. S2D is enabled and single storage pool found
        #   2. S2D is not enabled and no storage pool is found
        Log-Info -Message "Checking storage pool existence vs S2D status"
        if ($pool) {
            if (@($pool).Count -eq 1) {
                $instanceResult.TargetResourceName = $pool.FriendlyName
                if (-not $s2dEnabled) {
                    $instanceResult.Status = 'FAILURE'
                    $instanceResult.Remediation = ($lnTxt.RemNonS2DStoragePoolFound -f $pool.FriendlyName)
                    return (New-AzStackHciResultObject @instanceResult)
                }
            }
            else {
                $instanceResult.Status = 'FAILURE'
                $instanceResult.Remediation = $lnTxt.RemMultipleStoragePoolFound
                return (New-AzStackHciResultObject @instanceResult)
            }
        }
        else {
            if ($s2dEnable) {
                $instanceResult.Status = 'FAILURE'
                $instanceResult.Remediation = $lnTxt.RemS2DEnabledWithoutStoragePool
                return (New-AzStackHciResultObject @instanceResult)
            }
        }

        # Check pool health status
        if ($pool)
        {
            Log-Info -Message "Checking health state for storage pool '$($pool.FriendlyName)'"
            if ($pool.OperationalStatus -ne 'OK' -or $pool.HealthStatus -ne 'Healthy') {
                $instanceResult.Status = 'FAILURE'
                $instanceResult.Remediation = ($lnTxt.RemStoragePoolNotHealthy -f $pool.FriendlyName, $pool.OperationalStatus, $pool.HealthStatus)
                return (New-AzStackHciResultObject @instanceResult)
            }
            elseif ($pool.IsReadOnly) {
                $instanceResult.Status = 'FAILURE'
                $instanceResult.Remediation = ($lnTxt.RemStoragePoolIsReadOnly -f $pool.FriendlyName)
                return (New-AzStackHciResultObject @instanceResult)
            }

            # Check pool version
            $requiredVersion = 28 # which corresponds to 'Windows Server vNext' ON 23H2 and 'Windows Server 2025' ON 24H2
            $poolVersion = 0
            try
            {
                $poolVersion = (Get-CimInstance -Namespace root/microsoft/windows/storage -ClassName MSFT_StoragePool -Filter 'IsPrimordial = false').CimInstanceProperties['Version'].Value
            }
            catch
            {
                Log-Info -Message "Failed to get storage pool version, assuming version 0. Error: $_"
            }
            $SuppressHCIPoolCheck = ("1" -eq [Environment]::GetEnvironmentVariable("SuppressHCIPoolCheck", "Machine"))
            Log-Info -Message "Storage pool '$($pool.FriendlyName)' version is $poolVersion, required version is at least $requiredVersion"
            if (!$SuppressHCIPoolCheck -and ($poolVersion -lt $requiredVersion))
            {
                $instanceResult.Status = 'FAILURE'
                $instanceResult.Remediation = ($lnTxt.RemStoragePoolVersion -f $pool.FriendlyName, $poolVersion, ($requiredVersion -join ', '))
                return (New-AzStackHciResultObject @instanceResult)
            }
        }

        # Check pool capacity for infrastructure volumes creation
        if ($pool) {
            Log-Info -Message "Checking remaining capacity in storage pool '$($pool.FriendlyName)'"
            $remainingCapacity = $pool.Size - $pool.AllocatedSize
            $requiredInfraCapacity = GetRequiredInfraVolumeRawSizeTotalInBytes -PoolConfigXml $PoolConfigXml -NodeCount $NodeCount
            if ($remainingCapacity -lt $requiredInfraCapacity) {
                $instanceResult.Status = 'FAILURE'
                $instanceResult.Remediation = ($lnTxt.RemInsufficientPoolCapacityForInfraVolumes -f $pool.FriendlyName, $remainingCapacity, $requiredInfraCapacity)
                return (New-AzStackHciResultObject @instanceResult)
            }
        }

        return (New-AzStackHciResultObject @instanceResult)
    }
    catch {
        throw $_
    }
}

function Test-HciStorageVolumes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Pool configuration xml from Storage role.")]
        [XML]
        $PoolConfigXml,

        [Parameter(Mandatory = $true, HelpMessage = "Total number of cluster nodes.")]
        [uint32]
        $NodeCount
    )
    try {
        $instanceResults = @()

        # Get the preserved names of infra volumes
        $infraVolumeNames = @(GetRequiredInfraVolumeNames -PoolConfigXml $PoolConfigXml -NodeCount $NodeCount)

        # Get current volumes on the stamp
        $currentVDs = Get-VirtualDisk -ErrorAction Ignore
        Log-Info -Message "Virtual Disks: `n$($currentVDs | Format-Table | Out-String)"
        $currentVolumeNames = @($currentVDs | ForEach-Object FriendlyName)

        # Check if current volume name conflicts with preserved infrastructure volumes
        Log-Info -Message "Checking storage volume name conflicts"
        foreach ($infraName in $infraVolumeNames) {
            if ($currentVolumeNames -contains $infraName) {
                $status = 'FAILURE'
                $dtl = ($lnTxt.RemInfraVolumeNameConflict -f $infraName)
                Log-Info $dtl -type CRITICAL
            }
            else {
                $status = 'SUCCESS'
            }
            $params = @{
                Name               = 'AzStackHci_Storage_Test_Storage_Volume'
                Title              = 'Test Storage Volume'
                DisplayName        = 'Test Storage Volume'
                Severity           = 'CRITICAL'
                Description        = 'Checking storage volumes for upgrade readiness'
                Tags               = @{}
                Remediation        = 'https://aka.ms/UpgradeRequirements'
                TargetResourceID   = $infraName
                TargetResourceName = $infraName
                TargetResourceType = 'Storage Volume'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                    Source    = $infraName
                    Resource  = 'Storage Volume'
                    Detail    = ($lnTxt.RemInfraVolumeNameConflict -f $infraName)
                    Status    = $status
                    TimeStamp = [datetime]::UtcNow
                }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }

        return $instanceResults
    }
    catch {
        throw $_
    }
}

function Test-StoragePoolCapacity {
    [CmdletBinding()]
    param(
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Simple", "Mirror", "Parity")]
        [string]$ResiliencySettingName,

        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1, 2, 3)]
        [Int]$PhysicalDiskRedundancy,

        [Parameter()]
        [ValidateSet("Standard", "RackAware")]
        [String]$ClusterPattern = 'Standard'
    )

    $scriptBlock = {
        Import-Module Storage -Verbose:$false
        $logDtl = ""
        # Get physical disks that are eligible for S2D
        $eligibleDisks = Get-PhysicalDisk | Where-Object {
            $_.CanPool -eq $true -and $_.OperationalStatus -eq 'OK'
        }

        # Classify by media type
        $ssdDisks = $eligibleDisks | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'SAS|10|SATA|11'}
        $nvmeDisks = $eligibleDisks | Where-Object {$_.MediaType -match 'SSD|4' -and $_.BusType -match 'NVMe|17'}
        $scmDisks = $eligibleDisks | Where-Object {$_.MediaType -match 'SCM|5'}
        $hddDisks = $eligibleDisks | Where-Object {$_.MediaType -match 'HDD|3'}
        $logDtl += ("Drive types detected HDD: {0}, SSD:{1}, NVMe:{2}, SCM:{3}" -f [bool]$hddDisks, [bool]$ssdDisks, [bool]$nvmeDisks, [bool]$scmDisks)

        $cacheTier = 'None'
        $capacityDisks = @()

        if ($scmDisks.Count -gt 0) {
            # SCM exists -> SCM = cache, all others = capacity
            $capacityDisks = $eligibleDisks | Where-Object { $_.MediaType -ne 'SCM' }
            $cacheTier = 'SCM'
        }
        elseif ($nvmeDisks.Count -gt 0 -and ($ssdDisks.Count -gt 0 -or $hddDisks.Count -gt 0)) {
            # NVMe + SSD/HDD -> NVMe = cache
            $capacityDisks = $ssdDisks + $hddDisks
            $cacheTier = 'NVMe'
        }
        else {
            # All one type -> all used for capacity
            $capacityDisks = $eligibleDisks
            $cacheTier = 'None'
        }

        if (-not $capacityDisks) {
            $logDtl += "`r`n$($ENV:COMPUTERNAME): No eligible physical disks found for S2D."
            $logDtl += "`r`n$($ENV:COMPUTERNAME): Capacity disks: $($capacityDisks | Format-Table | Out-String)"
            $logDtl += "`r`n$($ENV:COMPUTERNAME): Eligible disks: $($eligibleDisks | Format-Table | Out-String)"
            $logDtl += "`r`n$($ENV:COMPUTERNAME): Cache tier: $cacheTier"
            throw "No eligible physical disks found for S2D."
        }

        $rawCapacity = ($capacityDisks | Measure-Object -Property Size -Sum).Sum

        return @{
            ComputerName     = $ENV:COMPUTERNAME
            RawCapacityBytes = $rawCapacity
            Efficiency       = $efficiency
            DiskCount        = $capacityDisks.Count
            CacheTier        = $cacheTier
            LogDtl          = $logDtl
        }
    }

    $poolData += if ($PsSession) {
        Invoke-Command -Session $PSSession -ScriptBlock $scriptBlock
    }
    else {
        Invoke-Command -ScriptBlock $scriptBlock
    }

    Log-Info -Message "Storage Pool Data: `n$($poolData | Format-Table | Out-String)"

    $instanceResult = @()
    $clusterStoragePoolRawCapacity = ($poolData.RawCapacityBytes | Measure-Object -Sum).Sum
    $storagePoolDiskCount = ($poolData.DiskCount | Measure-Object -Sum).Sum

    if ($ClusterPattern -eq 'RackAware') {
        $efficiency = 1 / 4 # Assuming 4-way rack-aware mirroring
    }
    else {
        switch ($ResiliencySettingName) {
            "Simple" {
                $efficiency = 1
            }
            "Mirror" {
                switch ($PhysicalDiskRedundancy) {
                    1 {
                        $efficiency = 1 / 2
                    } # 2-way mirror
                    2 {
                        $efficiency = 1 / 3
                    } # 3-way mirror
                    default {
                        throw "Unsupported redundancy level for Mirror: $PhysicalDiskRedundancy"
                    }
                }
            }
        }
    }

    $status = 'SUCCESS'

    $usableCapacityBytes = [uint64]($clusterStoragePoolRawCapacity * $efficiency)
    Log-Info -Message "Storage Pool Capacity: Raw Capacity: $($clusterStoragePoolRawCapacity / 1GB)GB, Usable Capacity: $($usableCapacityBytes / 1GB)GB, Efficiency: $($efficiency), Storage Pool Disk Count: $($storagePoolDiskCount), Node Count: $($PsSession.Count), ResiliencySettingName: $ResiliencySettingName, PhysicalDiskRedundancy: $PhysicalDiskRedundancy"
    if ($usableCapacityBytes -lt 450GB) {
        $status = 'FAILURE'
    }

    $params = @{
        Name               = 'AzStackHci_Hardware_Test_StoragePoolCapacity'
        Title              = 'Test Storage Pool Capacity'
        DisplayName        = "Test Storage Pool Capacity $computerName"
        Severity           = 'INFORMATIONAL'
        Description        = "Checking Storage Pool Capacity"
        Tags               = @{}
        Remediation        = 'https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2'
        TargetResourceID   = $computerName
        TargetResourceName = $computerName
        TargetResourceType = 'Disk'
        Timestamp          = [datetime]::UtcNow
        Status             = $status
        AdditionalData     = @{
            Source    = 'Version'
            Resource  = $computerName
            Detail    = "Storage Pool Capacity is $($usableCapacityBytes / 1GB) GB; Expected >= 450 GB. Raw capacity: $($clusterStoragePoolRawCapacity / 1GB) GB, Efficiency: $($efficiency)"
            Status    = $status
            TimeStamp = [datetime]::UtcNow
            NodeCount  = $PsSession.Count
            StoragePoolDiskCount = $storagePoolDiskCount
            ResiliencySettingName = $ResiliencySettingName
            PhysicalDiskRedundancy = $PhysicalDiskRedundancy
        }
        HealthCheckSource  = $ENV:EnvChkrId
    }

    $instanceResult = New-AzStackHciResultObject @params

    return $instanceResult
}

# Internal Methods

function GetRequiredInfraVolumeRawSizeTotalInBytes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [XML]
        $PoolConfigXml,

        [Parameter(Mandatory = $true)]
        [uint32]
        $NodeCount
    )

    $poolConfig = $PoolConfigXml.StoragePool

    # Compute total size of (fixed-size) infrastructure volumes
    $totalInfraVolSize = 0
    foreach ($volConfig in $poolConfig.Volumes.Volume | Where-Object { $_.Size -and $NodeCount -ge $_.MinNodeCount -and $_.Usage -ne 'Disconnected' }) {
        $volSize = Invoke-Expression $volConfig.Size
        $totalInfraVolSize += $volSize
    }

    # Compute raw size after mirroring
    $storageEfficiency = if ($NodeCount -le 2) {
        1 / 2
    }
    else {
        1 / 3
    }
    $totalInfraVolSize = [uint64]($totalInfraVolSize / $storageEfficiency)
    Log-Info -Message "Total infrastructure volumes raw size required: $totalInfraVolSize, with storage efficiency: $storageEfficiency"

    return $totalInfraVolSize
}

function GetRequiredInfraVolumeNames {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [XML]
        $PoolConfigXml,

        [Parameter(Mandatory = $true)]
        [uint32]
        $NodeCount
    )

    $poolConfig = $PoolConfigXml.StoragePool

    $infraVolumeNames = $poolConfig.Volumes.Volume | Where-Object { $_.Size -and $NodeCount -ge $_.MinNodeCount } | ForEach-Object Name
    Log-Info -Message "Required infrastructure volumes: [$infraVolumeNames]"

    return $infraVolumeNames
}
# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBxzSnhs9Fw9out
# oyBXZYgAooIiWMF3NxU3EBdC0tpx7aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIF7oobZ1+oCXoQ86PxGABxeHqEZKjXUwhcNl1zH6l98HMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAeux8y8fO0j+iLU0GazCr
# fiP7+P0xSUeuXGcedr7h+AC+S9j1g0u6RdEc4tLxl6zWvYC4yVP6FH/RF9m8403y
# 2EyYNUU8tdmXV/v/JtyugzQIRjBD2kl/XmBfTox/I7UBrdWSMWoC8An4IYsPNUYG
# slSFXAJCInR7RWjbRr0v8oh5tHqQ++CBa2WykakcomQCxcO+F4fEHOcXWgvz8q6t
# myMXOvcwW+ppVn7ufb9AUx1QR06ES4EHJc8EeYkkwv8rYjNg+K9uF8zapJ/BB0oW
# dSIrBaA6kSiPSvZu+WQhXeUB8iy6TCJf4rRHNc4uHfZ2BiAVadwFY+yF1Bx7gBzW
# FKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCWYJIAXWm5EnM0VnyH
# XdCqxcGMpl78pBN1cOhmhVPqQAIGaewOASLxGBMyMDI2MDUwMzE0MzExMS45MTNa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyM1oXDTI2MTExMzE4
# NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNhRM+BzF2AYiq5dUpZpJFPRjCc
# ipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU/W6fecujjILkPqn9pngtWRkf
# QgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY/Qk/jtjsHdFXVBe+tshlIkSJ
# 3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQMJP7tO8/BJ7ITs4/AV3D2bv8e
# Hk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf5x1lXxAwEw5a7dpS+CKTanht
# v+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1S9e8h1TszXFzjLLvE9EmjnNf
# IewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J60fGOl7A1UoUyAkhpb2Bja+S
# wSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6FZlPO8iuNyk680Di8VnbSNpI
# dJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asNt/Ng6o4m2dnooWOdM3yKsJaW
# jyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+XSvI2m1yN4iibqjm5HPaAO3O
# J+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C/+n1KFBpDGdDMw9gmu8CAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5ZQqnF5x8S1bJQzAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg5I/5S+gx67aR6RiW8ZAwtE3m
# z8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyvh3e2q/BV8rjHE3ud9PyYyq32
# euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZsSypbXDBbQkWkNl6g82yTy3A
# bBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dMSkSZweCNDXqd9r/9W2VdRZsD
# JKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69/N5CP/Tq3YgI1ub4b9+3MJFK
# WhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2NFXJFQHef6AdRe1ERvYQeqty
# rBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67oNwR4pEEJyAIEREvkdhjjfWc
# gsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D59r7/qebNSyQPTfwI9++jEY0
# Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HEovbA69qGlZ3OpUE3H1RBGDVp
# /FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IEXO2SeD1aD3IqvAOdHFKHg1vp
# bPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7zw64aO5hmJ7eQwoMfTu0Vay6
# r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hwK8wIhgPMjAyNjA1MDMx
# MjQwMTVaGA8yMDI2MDUwNDEyNDAxNVowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7aHArwIBADAHAgEAAgIRWTAHAgEAAgIS3zAKAgUA7aMSLwIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQBv6Qjzp7J+rBr0Y1HtxvKd1FBqoOCNUibMp9FyCAGI
# 7NQ8lHAtlYYqtzc8doabOBnyzfRjC1j8KIOhhKwyVL+mm3OzGouFuBblXCLcqgEA
# BOzo+B0X+bK7VbeUEv3jpiGd6QLlkegS6TdCM0/H2+Uo3oE2L5+ej8SR7Gi71VFF
# TypE6Fcz77TMBnKvM/IPrshH9SCPvnJPDXBE8oexuAqLVR9buz6reOtEKLdsLXM2
# 7N7yojnxaEnpzjaSBr4SZyBH46D7X9XFoh8spAo0EoMbT8w2NgtlM1FVZk+e/k/T
# S49i7FUXm4EdJHrOKtscyLbQDcBPRAlBCNWtmqWaaA6jMYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIXcfsupa8BHeoAAQAA
# AhcwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgLVozkXVVRGfU9qT/pjfTbRhsZTS/HGTBmPeVtuMP
# P0gwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDQ8lBgPl23yZ0SzUSt5phO
# IegHPywrkNwevxe2k+RaWzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACF3H7LqWvAR3qAAEAAAIXMCIEIGys7TSPvakkbNeCcJdbT7L4
# rXjj4bFl+DI/zU6lcSAHMA0GCSqGSIb3DQEBCwUABIICALKtcaVpBucOie1FyZdO
# M3R0FTZT/241MKLJBaCMt2KuB0hLFxoOh5lfKlpVEAWzmXOQC5UdRxferXEW323R
# AMaJLlHT1z+Bya7rgyYWRlA8fmW8iXEsJlqub7xfoFTLYBpBcnKssXYjbiA3+Fp0
# v6XJYPrS4mU/9Yu9d7kMapACs+5/iR050lHWlr6ynfy5HD8UMLKpSp1OlPJ3tPxT
# sgt072MdvYq4QQjohuxdF4tBgqnvtGn+WbXQXHQKbLTOC9nRyxGgr0CmUCXDmlGu
# 766KwK5soqzPnRjRQWdXlp/OSPUQmZIK6PJswphYMx40PK5bWl86Aft/tgGtY4lw
# N4mjigqfbbcgdhLVoTAif0kcP7jkPoQIrGZ2tSUgG1Sdq7YG3CVp8VDLfbCnmG28
# cl7n/t8mYcI7zdtTbIIu5Aa41JoIIQ8rX2goF6BaMCCrtsuaUwxA95aRZgHAhENf
# 4ydQiq7yZsuRlgULiZ34gHZUjKCzkouHb8unh2iL8WMn723igLIliYaCvPJt/kg5
# ZvjXHJJFDKBxODQyb8emFsF39TlDxb8xhdujd5SShtd6FbJf8uuNYk2Tp6mij5eW
# FjOzuZVDuFJa1Kz/YAz5H+2UEBnvzGgufLqTyExQSMS+/3v/jBVBmRsupbNyA8PZ
# BzSMDafMSKye8ol/Z7eH05yN
# SIG # End signature block
