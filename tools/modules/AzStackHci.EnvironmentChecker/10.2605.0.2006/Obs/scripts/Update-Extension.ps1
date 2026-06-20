##------------------------------------------------------------------
##  <copyright file="Update-Extension.ps1" company="Microsoft">
##    Copyright (C) Microsoft. All rights reserved.
##  </copyright>
##------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$functionName = $MyInvocation.MyCommand.Name

#region Imports
Import-Module "$PSScriptRoot\ExtensionHelper.psm1" -Global -DisableNameChecking -Verbose:$false
#endregion Imports

$WorkLoadName = "Update"

Set-HandlerLogFile

try {
    Write-Log "[$functionName] Entering. Update script started."

    ## During extension upgrade from ver N-1 to ver N, we need to install the latest packages (if not installed already) due to the sequence of operations.
    # Install-ObsPackages

    # Set-ObsPackageContentPath

    # ## Execute the script from ArcExtScripts
    # $scriptToExecute = Get-SetupScriptPath

    # ## Update script returns the status message, so we have added it only for Update operation.
    # $statusMessage = & $scriptToExecute -WorkLoadName $WorkLoadName

    ##------------------------------------------------------------------
    
    #region Figuring out which Ext version nuget store path to cleanUp
    
    $extVerToUpdateFrom = $null
    $extFolderPathBeforeVersions = $null

    $extVerToUpdateFrom = [System.Environment]::GetEnvironmentVariable("AZURE_GUEST_AGENT_UPDATING_FROM_VERSION")
    if ($null -eq $extVerToUpdateFrom) {
        Write-Log "[$functionName] AZURE_GUEST_AGENT_UPDATING_FROM_VERSION environment variable not found. Falling back to extension folder path."
    
        $extFolderPathBeforeVersions = [System.Environment]::GetEnvironmentVariable("AZURE_GUEST_AGENT_EXTENSION_PATH")
        if ($null -eq $extFolderPathBeforeVersions) {
            Write-Log "[$functionName] AZURE_GUEST_AGENT_EXTENSION_PATH environment variable not found." -Level "WARNING"
            $extFolderPathBeforeVersions = Split-Path -Parent $global:extensionRootLocation
        }
    
        Write-Log "[$functionName] ExtFolderPathBeforeVersions = $extFolderPathBeforeVersions."
        
        $currentExtVersion = [System.Environment]::GetEnvironmentVariable("AZURE_GUEST_AGENT_EXTENSION_VERSION")
        if ($null -eq $currentExtVersion) {
            Write-Log "[$functionName] AZURE_GUEST_AGENT_EXTENSION_VERSION environment variable not found. Setting it from extension folder path."
            $currentExtVersion = Split-Path -Leaf $global:extensionRootLocation
        }

        $currentExtVersion = [System.Version] $currentExtVersion
        Write-Log "[$functionName] Current extension version = $currentExtVersion."

        ## $global:extensionRootLocation gets us the Path until extension's current version folder, however we need to go one folder up so we can get all the version numbers that are installed.
        # $extFolderPathBeforeVersions = Split-Path -Parent $currentExtVersion

        ##  Get the installed version numbers (which are actually until versioned folder paths).
        $installedExtensionVersions = Get-ChildItem -Path $extFolderPathBeforeVersions -Directory -Name | ForEach-Object { [System.Version] $_ } | Sort-Object -Descending
        Write-Log "[$functionName] InstalledVersions of extensions are = $($installedExtensionVersions | ForEach-Object { $_.ToString() })"
        
        ## Compare the installed versions with the current version and select the one which doesn't match (here we assume that any point in time, there will be only two installed versions)
        foreach ($installedVersion in $installedExtensionVersions) {
            if ($installedVersion -lt $currentExtVersion) {
                $extVerToUpdateFrom = $installedVersion
                Write-Log "[$functionName] Lower version of extension selected = $extVerToUpdateFrom."
            }
        }
    }

    $returnStatusMessage = $null
    if ($extVerToUpdateFrom) {
        Write-Log "[$functionName] Extension version to update from = $extVerToUpdateFrom."

        $extVerToUpdateFrom = $extVerToUpdateFrom.ToString()

        ## Set the nuget store path which will be used to clean up the package files.
        $obsStoreRootPath = Set-ObsStoreRootFolderPath
        Set-ObsNugetStorePath -ObsStoreRootPath $obsStoreRootPath -ExtVersion $extVerToUpdateFrom -WorkLoadName $WorkLoadName

        $isFolderPathValid = $true
        $FolderPathToClean = $global:ObsNugetStorePath
        if (-not (Test-Path $FolderPathToClean)) {
            Write-Log "[$functionName] Nuget store path not found ($FolderPathToClean). Fallback to extension folder path (older version of ext)." -Level "WARNING"
            $FolderPathToClean = Join-Path $extFolderPathBeforeVersions -ChildPath "$extVerToUpdateFrom\bin"
            if (-not (Test-Path $FolderPathToClean)) {
                Write-Log "[$functionName] Extension folder path also not found ($FolderPathToClean)." -Level "WARNING"
                ## If both the paths are not found, then we can't proceed with cleaning up the process handles.
                $isFolderPathValid = $false
            }
        }

        if ($isFolderPathValid) {
            Write-Log "[$functionName] FolderPathToClean = $FolderPathToClean."
            ## Check for process handles locking any package files and then force stop these processes so that extension can be either Upgraded or Uinstalled.
            $returnStatusMessage = Close-ProcessHandles -FolderPathToClean $FolderPathToClean
        }
        else {
            $returnStatusMessage = "[$functionName] Neither nuget store path nor extension folder path is found. Skipping clean up of process handles locking files."
        }
    }
    else {
        $returnStatusMessage = "[$functionName] Lower version of extension not found. Nothing to clean up."
    }

    $statusMessage = "[$functionName] Exiting. "
    if (-not ([System.String]::IsNullOrEmpty($returnStatusMessage))) {
        $statusMessage += $returnStatusMessage
    }
    else {
        $statusMessage += "Successfully executed update script."
    }

    Write-Log $statusMessage

    Set-Status `
        -Name $WorkLoadName `
        -Operation "Update succeeded" `
        -Message $statusMessage `
        -Status "success" `
        -Code 0 ## PS Success code
}
catch {
    $customErrorMessage = "[$functionName] Exiting. Failed to update extension, "

    $errorCode, $exceptionMessage = Save-Exception `
        -ErrorObject $_ -CustomErrorMessage $customErrorMessage

    Set-Status `
        -Name $WorkLoadName `
        -Operation "Update failed" `
        -Message $exceptionMessage `
        -Status "error" `
        -Code $errorCode

    exit $errorCode
}
# SIG # Begin signature block
# MIInRgYJKoZIhvcNAQcCoIInNzCCJzMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC6aNdS6oqihbfK
# cbVC8DB0zSmcMtcn2kqqNTcLBzmsFaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghniMIIZ3gIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPTN/yuh
# +4/BG+hWvVMuqM9Xq6+kjBYt40SrkK15hyqgMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAXFk1jWQYCMT2g505bfxkmv9xf5BdvaXKRvr+D40+
# 4GexCJef3yn4chaD4Q572dSaIe0jpQFNyTKwTawGDkvGsU5hAMPSRk3o9fSNMpjb
# ROi4gWHESUWbxPtVQAWrLsdFJevSVACMr6Tu9UtfXHPquurI520BVzPovmZcN6n+
# bp67uIooVDsPumB5AqdfZaZ5iwlWjUrAsI3Q8AxOhsBy7L9woGk5pUzFlVXvukuA
# ZNtxSB+WuFaO/GGhlvyU45o+lRuFpQ/IQh8B8mHYMbJD+Fb63YXCq87lmIg4dk7+
# jdrK20bGVNzLPJ6JLAHKgjjYB+ZDCSrN2HZXlb1Ulxk+16GCF5QwgheQBgorBgEE
# AYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAI7bdBNR5qEiIdwaZfhTqfn1RcCERNH1xDOb0h
# wO89tQIGaeeNG/H7GBMyMDI2MDUwMzE0MzEzMS4yOTJaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgITMwAAAiQ7hCGwLKxkIgABAAAC
# JDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTlaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj6W3UaQ2Zr4hNvSy7j7UMPFVy
# s7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrLQCOZcgLvz6FkqmghzQxzmkgK
# tLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcViBX4LcHk38RusZiF7wxSa5t/
# Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9pU9uriGdDxfJXn/lc49CxbXq
# A3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfdrA29sWTSNKig9CtBC5tzQj0f
# lbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjlyUP9ZO38839NwSuiHtvsFCNk
# TNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PDERyrAs0pvfUWOLapVQajHPoC
# nuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8WwBtk3Yxyhjj0GXw909i0EkTk
# Vyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1YGnYwCjIwa5/lMW0pFn/HpJdB
# 6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v3E9kwN9VBC+wJESBECC1gZMC
# S5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3SNt0a0Q5Nc2Ul+rMlQxXoP9i
# sXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFHMfkX1u/zJLCMe0
# gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQA+wHSbmhIpM8CRVZ4t
# k624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko6diEDHXPNWvAagxastCewPzm
# 5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/Fwps1sbNUEu7Bzg004qULIVJ
# 963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQTHZgwuNB6QhcEEsgogLVwNRj3
# 7VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi6jlcfqfo619uDH9r8k2qAOHC
# eEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilUSon07wjHu0e0ssBmtBafPb4G
# d+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oczxC/4JT3Hf45JEtszToXwNsk
# V3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGElPl5GRoPtJiDEvRIbv5MFKIw
# 2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOkX4ug0/0mN2CSarhuSi9NmHIO
# pUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1objAGKdWMPCrlSyNAs0jZYzkh
# a535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbUVqMU1OrQbHfdyzJpbhJC1PbA
# ZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# VTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+46CBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aEy/DAiGA8y
# MDI2MDUwMzAyMzU0MFoYDzIwMjYwNTA0MDIzNTQwWjB0MDoGCisGAQQBhFkKBAEx
# LDAqMAoCBQDtoTL8AgEAMAcCAQACAg/aMAcCAQACAhIOMAoCBQDtooR8AgEAMDYG
# CisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEA
# AgMBhqAwDQYJKoZIhvcNAQELBQADggEBAL9QPClikC5HBBjkEV8kQCdOYgladCEK
# OVxs6xbIHbuWlp0Zx98nC6OKdOCDGy6v72cKF73oTc+MJIyg+V9MC5amxJhbOexC
# 6UhDv2K0e2UO29hd6bLMwJNSOG2cikQtrCx2HwUFMfA0cL5/v5JkCrGVOMC9+dqO
# l3UGJV2kDyUveA8XZTcOfE0uxhBi9WqI3+2o35c0pirxSDZ+e4a0Y1kfCvmV8SKX
# 03/4OobFPRKBe3Zen5G3X4q6a0kwFdb20958JGDQIOztpc1e9ozHpvw6EaLGJQf1
# XBgPBcpQHUAPzG2cxa2bFdeczcOxTadb9fhz54UjiqP4PlAqI2nMi0gxggQNMIIE
# CQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYw
# JAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiQ7hCGw
# LKxkIgABAAACJDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCt8edhZgwQOsD30IwuivZpS3tf7RG7
# 7tyyKucZtDz8/jCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEghPTdqm/dR
# yZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGYMIGApH4wfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCysZCIAAQAAAiQwIgQgA//oxm2fo5LO
# mmtYNHLZwfdHBrA0Jfu1dxOXSFqdBYowDQYJKoZIhvcNAQELBQAEggIAF0CO/D9D
# ug0FtD1iOABKCnK6HZyHDV57ftitt93LEKmsHHJAk8MFKSxpJWXyL86OiB3Ey1TL
# 9Qn3mfDM3S4ApavJIE6Hw1N0tYIp6dOLP78XZlFEcgFxxwTv4klD7THFnW49hHL8
# cg92Agi/8RVgBe1m1fhzgVcDuk/eeL7o3M4ElCGCw9KVyVrz+2hvnm50K6n3KmNZ
# sOdPqKxMvGMSqC4pfEqkL0DYspYQqD5YYRw/Gm/p0pt6901EvvpGir9JCDQg8suV
# B/KK3jucjaTIKJyUicQbbH6BgiXSNZFzwozbuCOSZcgWroDhZLnfVyTZf78mpiLv
# 2/iPRbrg7B+oEQhy2ljNUNOe+tokr9N7f95Ntnc59aSSCswg8tFuWO1D6YH8ZBKR
# sw0LZgDWV5QOKt0bLXs/H0nAdVPJUofiA+cjmJRFASWHbfAaxi5vmPqjq6qVICoP
# WCDa5BJcIziDJuzqm6zTcCyuuNbgtOBkJHx22FD8U/yYMx0LatvSYqpm+wPDeTp8
# XGq1NQDkT5RHBza8H/rzFZ8EZMzh2V+9R1JHcoSTG7aKGdJdxIm77Zg6INmEzYUR
# byGWswVFejnR2xWJ4azJQkLzHQiSgCVCzAE9y66/gGFlxmo46IIYf0/j3d2ZD5XN
# aHBZbR7x5NO0j06WJgnv9CapyWHaggpmJUA=
# SIG # End signature block
