ConvertFrom-StringData @'
###PSLOC
FailTestFailedToParseVSRInfoJsonFile = Failed to parse the VSR info JSON file.
FailTestFailedToFindVSRInfoJsonFile = Failed to find the VSR info JSON file.
FailTestMissingRecipe = The host is missing the recipe XML file, it is nor correctly signed, or it is corrupt!
SkipTestMissingRecipe = The host is not based on a Composed OS Image so skipping the test.
SkipTestMissingVSRVersion = The host does not have the VSR version defined in the recipe so skipping the test.
SkipTestNotNodeAdd = The test is not for AddNode operation, skipping the test.
InstalledPackagesNotInstalled = Package [{0}] is NOT installed on host [{1}] and it should be.
InstalledPackagesRecipeVerConversionFail = Failed to determine determine which version to expect for package [{0}] on host [{1}].
InstalledPackagesLiveHostVerConversionFail = Failed to determine the running version of package [{0}] on host [{1}].
InstalledPackagesFail = Package [{0}] is installed on host [{1}] as version [{2}], but we expected a version equal to or greater than [{3}].
InstalledPackagesPass = Package [{0}] is installed on host [{1}] as version [{2}] and we expected a version equal to or greater than [{3}].
InstalledPackagesBootstrapInstalledFail = Package [{0}] is NOT installed on host [{1}].
InstalledPackagesBootstrapInstalledPass = Package [{0}] IS installed on host [{1}].
InstalledPackagesBootstrapVersionFail = Package [{0}] on host [{1}] is NOT the expected version [{2}].
InstalledPackagesBootstrapVersionPass = Package [{0}] on host [{1}] IS the expected version [{2}].
InstalledFilesFail = File [{0}] is NOT installed on host [{1}].
InstalledFilesPass = File [{0}] IS installed on host [{1}].
BaseOSimageVersionFail = On host [{0}] the installed base OS version does NOT match the version defined in the recipe - expected [{1}] but got [{2}].
BaseOSimageVersionPass = On host [{0}] the installed base OS version DOES match the version defined in the recipe - expected [{1}] and got [{2}].
BaseOSimageEditionStringFail = On host [{0}] the installed base OS edition string does NOT match the string defined in the recipe - expected [{1}] but got [{2}].
BaseOSimageEditionStringPass = On host [{0}] the installed base OS edition string DOES match the string defined in the recipe - expected [{1}] and got [{2}].
BuildIdFail = On host [{0}] the installed OS Image Version does NOT match the Version defined in the recipe - expected [{1}] but got [{2}].
BuildIdPass = On host [{0}] the installed OS Image Version DOES match the Version defined in the recipe - expected [{1}] and got [{2}].
NodeAddBuildIdFail = The OS image version on the node [{0}] does NOT match the version on node [{1}] - expected [{2}] but got [{3}].
NodeAddBuildIdPass = The OS image version on the node [{0}] matches the version on the node [{1}] - expected [{2}] and got [{3}].
SolutionVersionFail = On host [{0}] the installed solution version does NOT match the version defined in the recipe - expected [{1}] but got [{2}].
SolutionVersionPass = On host [{0}] the installed solution version DOES match the version defined in the recipe - expected [{1}] and got [{2}].
FeaturesOnDemandFail = FOD [{0}] is NOT installed on host [{1}] as the version defined in the recipe - expected [{2}], but got [{3}].
FeaturesOnDemandPass = FOD [{0}] IS installed on host [{1}] as the version defined in the recipe - expected [{2}], and got [{3}].
LatestCumulativeUpdateFail = LCU [{0}] is NOT installed on host [{1}] as the version defined in the recipe - expected [{2}], but got [{3}].
LatestCumulativeUpdatePass = LCU [{0}] IS installed on host [{1}] as the version defined in the recipe - expected [{2}], and got [{3}].
LatestCumulativeUpdateSkip = LCU [{0}::{1}] SKIP checking on host [{2}] because this HotFix is superseded by a newer HotFix.
'@

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBfjiAYipBiLbut
# qLt/sVjBING1FOz5nox9Yc4vRFHIk6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEILMLEvun
# G2Xsfr/p9cSzaAckxb3F0pzMG6X6i5Fl/NDuMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAUsfmnHl6WoayKn6LdVl55Hr+C9qKI5QsoK2clLlK
# zaUNQ25elX+TyAGTz8LsIrfqXvr1ajl7JmJfebbczeLRl29jmJcoA1dNnJgXAjmP
# t3D0pkE56wOGWqk/rpUMZdJe2BhN6kEyPoHucOsekSGQkioDyARMCSDEpG90kT/s
# /1qg1juwBKAeSNb/ajXU1b44QSLgF/MMCA0kaU5xtn/uo/y2eK8/LyFpESftkN9A
# 7hDbvGPHQ8v4U9ZLkY/5pyBzIdswk3sLzQuIeh284H/3dPdLpywRamSN7hKFGT0e
# /8vdxn35g/5AmgsifyzK/c+6Y+Ib6m0CqgjdOLGLnthQ46GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAUbJBUcB9eguFA2FxPoPUCBXLwiAojfAMqhLs/
# d9V5FQIGaedcMrc5GBMyMDI2MDUwMzE0MzExMC42OTFaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiu7AFD/TTuaoQABAAAC
# KzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTQwMTFaFw0yNzA1MTcxOTQwMTFaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCX3mi6OD3syUqQm4QqgkrKPbcs
# K/Qx3fYctL8+VM1uOY3booi5GxwauTgQf6JFHITToxS7gjqKlK8OFLzL6UTl0jxE
# K5t6DuOcgJXdvutimoTlOS0C3kyITXBAXoj/gp6hRR9z6WRip1Ktkilb3dJXCjQq
# T9P2Cuujr+Vz8r+Z+jDl09ji/ic/4G34r3mVwjs//Gnx9Pu31V8rXFicNiAzxpub
# awpbd8pqfzlWT2vnG3kF9l6MiREbvJ3XHLUwHQsh0t/TrSFx/s/yCqpJWYJ6oClG
# 70tvsFH0aRP8wB4cP/CFa2ILvk26i3OcJBl+pqKjHTSBy9mvwTPEDlnzco0Nt8R6
# pSPTXZgBsscHhoKfC0WQmOzY2keXbAmRTcZMyXz5v/AJbmoI0y07Bazvt5NkXddG
# 9TErQWwtsFyIKrElDgWfHeCoTu1wu2ciD3dK72z3ca2gzoEDxT2j9BXIUKaiTzTd
# QPRsAMaO3dU0zaGwMMlwtSJyDh14YEgZoUu5vS8MugMqdrNjphyL65yKhjpAWbhY
# kIHO/0uZju95tP8zZNqXIRh4tdfWHJPATn9r+cxkyuh2x0VLdfx1lmK9X3NjH0Nt
# gAs5JB/wOlkyuudxmFTfWVyRrL37ispOZ8aPAFgvyR6cNTkGpkFo35JRjciNmZiU
# 4qT9Uty+V5gudFk1jwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFD4WjuQTUJbtbd3j
# mvZku0FZ2eU2MB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQDO/CKsciEM8kr1fqH4
# TlfT66ENoTjxXw810pyEq0PdrgLwfgT3x+1gz7CQHtUdevqMQ5qHyDLhm6pT911C
# YkGN+6g+MU7fMYTr6d3SxieJwBIoWkfR4g7SitGzMKU465KEYejfddoUgovC/xcR
# paALO5p3/A248ByhJiMttBQNDtsT/HaCFwRFCURby/f8c1kky8F8xkCXFz+/MtZ5
# d1lWFjwOI2geZHWq9XihDOgee5nS2koo5V6n8XG220UTevVf+pgmpIH71XKDVIYT
# GGZJs6yPlfJ2aXqw1ME4NR6okNsY3P1M31H6DMYRfJGNBNep595kXGh3YzA3cCiy
# g+jmJ58h/fTvjngIpuUFfODpDjFx0ic1YoLANxhCF3RhS9qYM7K40NEhKshYuaAk
# IG2XBKYig3r/0/b0sjvjBws55AYonMm3A8qcX/6k9Vfc0mv9dtonHuWGfA2b+qE2
# qpCnhzGbdDHq7iOSZEw01nNupAMf1c41k9IoTQ2z3iw6w4ZZoLOyg4TKMbp1krpT
# 4trip/y30Cv5khyqCDNqaXQpBkOYON8LgtoQ3amVOX7ix5jdrnx/vUxTUSigXvrW
# dL7Uk8kpmS0zto2Toy7aT5oBzCTvfj9iJ/BN/E1vhFBkhJCvZ7PVvsMSnTTmkx2F
# al2lVkztuAI44fD/uyLJdaMQSzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
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
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkEwMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQAJrD90ykHpo/0AGb7lmwvsCtqROaCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aGqzTAiGA8y
# MDI2MDUwMzExMDY1M1oYDzIwMjYwNTA0MTEwNjUzWjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoarNAgEAMAoCAQACAgriAgH/MAcCAQACAhKRMAoCBQDtovxNAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAIl4g/kZCHOercYjfWGc3FY550/1
# yoGs3vrCpYCiNuNfqVIkgW9OD5T8579pxf21Xr0U1AcPlDXTJp0yDpUZSQC5piZ4
# GVlnWRd8cwYcudJMTRvohaKkB8RkIW/HdTHdBIBfKPSl0ebsY5sHpGDMZvnL5VY3
# hd5ZuFeSh7gV7YY2C5pt2CCK+97ZWsL6Ta38OU9D6850s8gLcTRyxUB0LH97fUTp
# i4IbVl9jVfkBnzUj1jIcGKgxMLwkI0OjgCqCX5kaZglamPJpmE56ddNb6tyRftU8
# uyBiJiHIbT+I0Fulg0PSenWSkVIO7qbbEJRaLt5aGv+5+hCzhUkHddnXKDExggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7
# AFD/TTuaoQABAAACKzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCC5IqGKKeGaBz1WhWZgH9ILVFX/
# lbjw5YgNtKNhRh+NwzCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHIOI/Q/
# kFftYA+M2OY+1Bx3ajBD6/WDAtPT2vFkv25SMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIruwBQ/007mqEAAQAAAiswIgQg4bigwWvF
# x04J9mIfST2NDYTqeHpS2VK/0b1JF/5aWO0wDQYJKoZIhvcNAQELBQAEggIAMsAW
# 0Eh//qviyDsWd+rjYXIgIsDkVWKmmYkLeKw5vJipypkk1cQV1XYPmnmX0x6zOVBg
# V889dPejKKYuDVJUR4YYT5FA1qx2C4WCwISsveIKnlajQRNnilTVhVJQHU9rNGGX
# K3w8Yi+QzSRrephSEE08Yvcfh1Nx2X72cZ9yZ6tR/aJ2lUVUcXdlqGfPbi5omtXQ
# 29Ic1qEhzUb/12E9N49V431z6/x+AhZUMb2K2oNUtX8O2ScetBdGEtCS4/p/b9+1
# P8HihujD9f+Lp530y3Kr7dvmrXOIGJI1gd1T0cM716PHNHkRL7+h5ZPuMiZQDIRZ
# 2llSmiIqIN0IqTfaUwDSS5x0pAIgEnRCdVzRaEdBhKuxVqsiP/76eWS92sCYNNLd
# VbvZXVuOa29Zfx3LW2G+NuSq3sqVVlph/2zumppQqHPKba5A188WOiN2n/mHbqZG
# Sq/i4hSaz+dA1WJSljgPhzEM4qTcsTGfQXksWXZi/touc7IhnG6jnyooUVsDVBu4
# 8jY67SbkrpjUQrK1qacTPKBnMxbaiXPspy4uYjGbTUrmPe5KWyirP4p0hjQJhUrx
# IT1++fSsKKgRdj5MQyWU50Ww5QGDXS+6pI2xaUifzVxKJ0mb61GNYNXzYmwoglRV
# IIgvHAeNE3lxqPoc70lAooUvgQq6Q0BNEGrQc54=
# SIG # End signature block
