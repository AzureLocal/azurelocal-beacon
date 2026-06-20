Import-LocalizedData -BindingVariable lvsTxt -FileName AzStackHci.Observability.Strings.psd1

function Test-LogCollection
{
	<#
    .SYNOPSIS
		Check log collection component mets observability condition for update\upgrade
    .DESCRIPTION
        Check if log collection is in progress, if yes then indicate result with Warning
	.PARAMETER PsSession
        Specify the PsSession used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for observability validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

	try
	{
		Log-Info -Message ($lvsTxt.LogCollectiontInfo) -Type Info
        $logCollectiontErrMsg = $($lvsTxt.LogCollectiontInfo)

		# Scriptblock to check log collection status
		$testlogCollectionSb = {
			$AdditionalData = @()
			$status = 'SUCCESS'
			$errorMsg = $null
			$hardwareType = $null
			$logCollectionTime = $null
			$logCollectionStatus = $null
			$resource = $null

			try
			{
				# Get HardwareType
				    $hardwareType = (Get-WmiObject -Class Win32_ComputerSystem).Model

				    # Check check log collection status
				    $logCollectionHistory = Get-LogCollectionHistory -Verbose:$false -ErrorAction SilentlyContinue
				    if ($logCollectionHistory -ne $null `
                         -and $logCollectionHistory[0] -ne $null `
                         -and $logCollectionHistory[0].Status -eq "Running")
				    {
					    $logCollectionTime = $logCollectionHistory[0].TimeCollected
					    $logCollectionStatus = $logCollectionHistory[0].Status
					    $status = 'FAILURE'
						$resource = "Log Collection in progress"
					    throw $args[0]
				    }
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resource = "Error occurred in Environment Validator Log Collection test."
				$status = 'FAILURE'
			}
			finally
			{
				$AdditionalData += @{
                    LogCollectionTime = $logCollectionTime
					LogCollectionStatus = $logCollectionStatus
                    HardwareType  = $hardwareType
					Status    = $status
                    Source    = $ENV:COMPUTERNAME
                    Resource  = $resource
                    Detail    = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$logCollectionResult = Invoke-Command -Session $PsSession -ScriptBlock $testlogCollectionSb -ArgumentList $logCollectiontErrMsg

		# build result
		$logCollectionResultSet = @()
		foreach ($lc in $logCollectionResult)
		{
			$params = @{
				Name               = 'AzStackHci_Observability_LogCollection'
				Title              = 'Observability Log collection Requirement'
				DisplayName        = 'Observability Log collection Requirement'
				Severity           = 'WARNING'
				Description        = 'Test to check observability log collection requirement is met'
				Tags               = @{
					'OperationType' = $OperationType
				}
				Remediation        = 'Stop or Wait for log collection to be completed'
				TargetResourceID   = $lc.Source
				TargetResourceName = $lc.Source
				TargetResourceType = $lc.HardwareType | Get-Unique
				Timestamp          = [datetime]::UtcNow
				Status             = $lc.Status
				AdditionalData     = $lc
				HealthCheckSource  = $ENV:EnvChkrId
			}
			$logCollectionResultSet += New-AzStackHciResultObject @params
		}
		return $logCollectionResultSet
    }
	catch
	{
		throw $_
	}
}

function Test-RemoteSupport
{
    <#
    .SYNOPSIS
        Test Remote Support Session Terminal is active
    .DESCRIPTION
        Test if active Remote Support Session is in progress
	.PARAMETER PsSession
        Specify the PsSession used to validation from.
	.PARAMETER OperationType
        Specify the Operation Type to target for observability validation. e.g. Deployment, Update, etc
    #>
    [CmdletBinding()]
    param (

		[Parameter(Mandatory = $true)]
        $PsSession,

		[Parameter(Mandatory = $false)]
        [string[]]
        $OperationType
    )

    try
    {
		Log-Info -Message ($lvsTxt.RemoteSupportStartInfo) -Type Info
        $remoteSupportErrMsg = $($lvsTxt.RemoteSupportErrMsg)

        # Scriptblock to check remote support status
		$remoteSupportSessionSb = {
			$AdditionalData = @()
			$status = 'SUCCESS'
			$errorMsg = $null
			$hardwareType = $null
			$nodeName  = $null
			$startTime = $null
			$endTime = $null
			$resource = $null

			try
			{
				# Get HardwareType information
				$hardwareType = (Get-WmiObject -Class Win32_ComputerSystem).Model

				# Check remote support access state
                $getRemoteSupportAccessState = $(Get-AzStackHCIRemoteSupportAccess -Verbose:$false -ErrorAction SilentlyContinue).State
				if ($getRemoteSupportAccessState -eq "Active")
				{
					$remoteSupportSessionHistory = Get-AzStackHCIRemoteSupportSessionHistory -Verbose:$false -ErrorAction SilentlyContinue | where { $_.EndTime -gt $(Get-Date) }
					if ($remoteSupportSessionHistory -ne $null -and $($remoteSupportSessionHistory.count) -gt 0)
					{
						$startTime = $remoteSupportSessionHistory.StartTime
						$endTime = $remoteSupportSessionHistory.EndTime
						$nodeName = $remoteSupportSessionHistory.NodeName
						$status = 'FAILURE'
						$resource = "Open Remote Support Session terminal."
					    throw $args[0]
					}
				}
			}
			catch
			{
				$errorMsg = $_.Exception.Message
				$resource = "Error occurred in Environment Validator Remote Support test."
				$status = 'FAILURE'
			}
			finally
			{
				$AdditionalData += @{
                    HardwareType  = $hardwareType
					Status    = $status
                    RemoteSupportSessionEndTime  = $endTime
					RemoteSupportSessionStartTime = $startTime
					RemoteSupportSessionNodeName = $nodeName
                    Source = $ENV:COMPUTERNAME
					Resource = $resource
                    Detail = $errorMsg
                }
			}
			return $AdditionalData
		}

		# Run scriptblock
		$remoteSupportSessionResult = Invoke-Command -Session $PsSession -ScriptBlock $remoteSupportSessionSb -ArgumentList $remoteSupportErrMsg
		$remoteSupportSessionSet = @()
		foreach ($rSS in $remoteSupportSessionResult)
		{
			$params = @{
				Name               = 'AzStackHci_Observability_RemoteSupport'
				Title              = 'Observability RemoteSupport Requirement'
				DisplayName        = 'Observability RemoteSupport Requirement'
				Severity           = 'CRITICAL'
				Description        = 'Test to check observability RemoteSupport requirement is met'
				Tags               = @{
					'OperationType' = $OperationType
				}
				Remediation        = 'Active remote session terminal is open, please contact Microsoft Support'
				TargetResourceID   = $rSS.Source
				TargetResourceName = $rSS.Source
				TargetResourceType = $rSS.HardwareType | Get-Unique
				Timestamp          = [datetime]::UtcNow
				Status             = $rSS.Status
				AdditionalData     = $rSS
				HealthCheckSource  = $ENV:EnvChkrId
			}
			$remoteSupportSessionSet += New-AzStackHciResultObject @params
		}
		return $remoteSupportSessionSet
    }
	catch
	{
		throw $_
	}
}

Export-ModuleMember -Function Test-LogCollection
Export-ModuleMember -Function Test-RemoteSupport
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBFqw90/Q5zyktW
# plp0bIt9Kbe+FYaTbcFE7LIMIupjsKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn+MIIZ+gIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIMLpaXHhqNFd5Pw9IZPuSgzvtgbySMLN0+aMD8QEuznSMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEA0cjesnEPhhpdnLmiOvbS
# xY6aB9S2Ov7K06AhyxQs9IHCWd6VRTYFN0tGREcyesG2JTM40TmUumDw6F4VwRHX
# uXjGuY97pRlUK2eL72DEXarC14tmjs6CB/rcxI3BNfNKTS23q1ZnLOGUYAyD7+Qu
# Swm3JgFLe10qiSD066wXcIBMMOypd+z3rdiY26WGgsYFdFA/69QQu6Wln54dXDfl
# E0Ac4X2a9DOfsW6X4W69CMrjvFtuzgZygYg1l0UCNXue7JnRhF3FFdVVUPoSWB1t
# zl9vlR4UQR44asFAephBiYNF6zavqQDOBvTmytioxG1p1L5UrE33YNi1c6iGL3WQ
# fKGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCC5z9r7APfcZxklvSkc
# RvLjJXeSepUV+N2SwoEkdrFHjwIGaetf7Mk1GBMyMDI2MDUwMzE0MzExMC41NzVa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACE7BDNWbPr5XoAAEAAAITMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxN1oXDTI2MTExMzE4
# NDgxN1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjM2MDUtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEA9Jl64LoZxDINSFgz+9KS5Ozv5m548ePVzc9RXWe4T4/Mplfg
# a4eq12RGdp5cVvnjde5vxfq2ax/jnu7vUW4rZN4mOUm5vh+kcYsQlYQ53FwgIB3n
# EjcQHomrG3mZe/ozjFSAr6JbglKtIeAySPzAcFzyAer5lLNUHBEvQMM8BOjMyapC
# vh0xsg4xKFcVEJQLKEfCGBffMZI/amutHFb3CUTZ7aVpG2KHEFUNlZ1vwMKvxXTP
# RDnbwPGzyyqJJznfsLNHQ4vXt2ttS1PeCoGI0hN1Peq8yGsIXM9oocwC06DGNSM/
# 4LAx2uKvwmUn6NwLc0+tmvny6w28rZLejskRfnVWofEv1mWY0jHUnHrwSGBS8gVP
# 9gcBs6P5g0OpJPMfxdUkHXRkcMPPW0hIP8NbW8W5Sup8HuwnSKbjpyAlGBUdM/V5
# rZb0sZmkn714r6ULGK+cLLAN6R3FhX6N0nj64F27LTK2BbS0pJZaXjo0eDNz1Qcx
# eIFLUgF+RBsLYDn8E8cCkexK8Nlt3Gi9zJf55w6UfTZ+kwTMxMqFxh7+Tfx7+aBO
# bZ+nx961AtiqAy7zVV69o/LWRdKPZdvZn9ESyGbTnPfjkBERv22prSlETlRwzP6b
# mEVOKWLWVwxuwh7bUWUuUb1cj93zvttQYGQat5E9ALLJNmlvLKCskB7raLsCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBQTnhBKx+FryphQWMRipH49sMFAOjAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAgmxaJrGqQ2D6UJhZ6Ql2SZFOaNuGbW3LzB+ES+l2
# BB1MJtBRSFdi/hVY33NpxsJQhQ5TLVp0DXYOkIoPQc17rH+IVhemO8jCt+U6I1TI
# w6cR7c+tEo/Jjp6EqEU1c4/mraMjgHhQ+raC/OUAm98A1r4bIPHtsBmLROGmeE5X
# LIFaBIZWHvh2COXITKObXVd5wGtJ1dZZdwaHACXF506jta+uoUdyzAeuNlTPLTrZ
# 8nyhxGwk9Vh6eiDQ7CQMWSSa8DJS9PUXjeoi9vTdS7ZMXqu+tv6Qz3xtoBF5+YFK
# 4uE+miGs90Fxm0VK2lWrmFhjkRl5zyoHOdwG7spNYkDomCPNWIudUQmQYKpt/Hss
# pfcb+xpnWIDQdMzgE8pj1vpwLgWEnH7LtT4dZCeoDo9PK40RxBD8kKJ769ngkEwf
# wCD2EX/MQk79eIvOhpnH12GuVByvaKZk5XZvqtPONNwr8q/qA3877IuWwWgnaeX+
# prpw0dZ/QLtbGGVrgP+TRQjt+2dcZA5P3X4LwANhiPsy0Ol4XCdj7OxBLFvOzsCP
# DPaVnkp+dfDFG+NOBir7aqTJ68622pymg1V+6gc/1RvxC/wgvYyG033ecJqv0On0
# ZRNYr+i/OkwgA3HP1aLD0aHrEpw6lt0263iRkCvrcdcOW8w3jC8TJuaGWyC2S9jE
# jzgwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCCAkEC
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNjA1LTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAmBE8SCjxgjacmy8/VEdk7NxpR6aggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hu00wIhgPMjAyNjA1MDMx
# MjE3MTdaGA8yMDI2MDUwNDEyMTcxN1owdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aG7TQIBADAKAgEAAgIPKQIB/zAHAgEAAgISYDAKAgUA7aMMzQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQC0AYgtj+UpvwVb2CRr2AkSkCF1ougJpGP5LiZE
# JjCec1AmK86jjf+kkRiHxuyPZosa5p6+1Qaxal5Ga3qHYjOI+8LNRhj4lKblsLe1
# gr0v4B9GbdRwCvDVEj3pWO6BnT/rU0SwQ3TALtdHjCQzdXr/UFkWUiTOGETyhwxo
# /yd/8bcTU9HunRVdXcwPujXLzsQg8s1dFvUoGQtxUlaJg8/7lqaeuL1ljhKc03N0
# 4piwfhdAPEj8QZzq7AB8eiCq5cXfpKx1j1aH0dMeJUyL4/TSS521c/z0zz9qwK6n
# UQw1uD8e+zeD20zeMEjHrtiPTHc6TKdQsikJ0atRPDOfbCq3MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAITsEM1Zs+vlegA
# AQAAAhMwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgXTHJ3WWw+JiSnbU31wxStDewZw5VlwQrmw9a
# jC2rIbIwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDM4QltFIUz8J4DjAzP
# 4nVodZvQxYGleUIfp86Oa5xYaDCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACE7BDNWbPr5XoAAEAAAITMCIEIBrfrf4CbKQNVRrzdpPq
# jIdnysAs35FGOLEuYAcU0RZBMA0GCSqGSIb3DQEBCwUABIICAMVqFeaGVHSdcc7N
# D0GRnIi08zhWXXfh2enSJTsoVvrmOGQHUwojxyKK9jUSCCIvxOWOjxGylTMi7zrW
# VxRNYE/DQrMUW9FQjZwP/aDqaiqj89uBrWmYZllFIZID8mZSSmJaQXvu49gT7Kpt
# J8AGL3O29Vdc6yuF3NqmhY/a80uUNRM2mEaWHug0tNOAav30NQCYxEjB0N0So9+e
# EBgozAmMUx6dT4TC+PKc2h6w3dO+/vDJY5/vq/9lFEHduz5w3MoNUvZ0d0Cb/8Wj
# 1w7d7kLnt+pcpx6ykbLnLbaviJ8JEHWiJw5xLXNriXbfNxeNuZ4LL3XgDz2jFcvu
# +GbR6mQoml+wgd8i8tdAKmYpraPjZbd9o6K5ApgSngAWF6t5sz9ycDnNQgXesVj2
# f+ew+AHOIX5MTynSbeUtAIAq3PbYPIm5lVzAwdV5HrklxL4GyflhuzUm4zVz8+Bl
# 0sHdqqA4233Kf9H0KV5K9B9DhwD/XO6pZOqRwzATrQRRHV5iLYPz+kAi8l4KiODg
# NJFTKJIT+k52NxeFv5yVp7oUPP2Psn2F/0wTNUvoRkG8Uv5MikFinHjneWleNrY/
# EoAJn9tCQ3Ysjv1zfb36uhyCRmqHPFZWKgbYjGTBAf6XNcDC8R4U0iNuw9MvUGEw
# ihcUKI3iGYHzYlYl1d2u2Y/YY+Jo
# SIG # End signature block
