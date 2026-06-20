<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>

<#
.SYNOPSIS
    Validates that an XML file is digitally signed by Microsoft.

.DESCRIPTION
    This script verifies the digital signature of an XML file to ensure it was signed
    by a trusted Microsoft certificate. It validates the certificate chain and ensures
    the signature is valid.

.PARAMETER XmlPath
    Path to the XML file to validate.

.EXAMPLE
    .\Test-XmlSignature.ps1 -XmlPath "C:\Temp\manifest.xml"
    Validates the signature of the specified XML file.

.OUTPUTS
    System.Boolean
    Returns $true if the XML is signed by Microsoft, $false otherwise.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [System.String]
    $XmlPath
)

function Test-XMLSignatureByMicrosoft
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.String]
        $XmlPath
    )

    # Read the xml file so we can test the signature.
    try
    {
        $XmlDocument = New-Object -TypeName System.Xml.XmlDocument
        $XmlDocument.PreserveWhitespace = $true

        # Use FileStream with FileShare.ReadWrite to prevent file locking issues
        $fileStream = New-Object System.IO.FileStream($XmlPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $xmlTextReader = New-Object -TypeName System.Xml.XmlTextReader -ArgumentList $fileStream
            try {
                $XmlDocument.Load($xmlTextReader)
            }
            finally {
                $xmlTextReader.Dispose()
            }
        }
        finally {
            $fileStream.Dispose()
        }
    }
    catch
    {
        Write-Warning "Failed to load XML document: $XmlPath - $_"
        return $false
    }

    $validSignature = $false
    $isSignedByMicrosoft = $false
    Write-Verbose "Testing $XmlPath"
    $signatures = $XmlDocument.GetElementsByTagName('Signature')
    if (-not [System.String]::IsNullOrEmpty($signatures))
    {

        foreach($signature in $signatures)
        {
            # Get the signed XML to validate the signature.
            Add-Type -AssemblyName System.Security
            $signedXml = New-Object System.Security.Cryptography.Xml.SignedXml -ArgumentList $XmlDocument
            $signedXml.LoadXml([System.Xml.XmlElement]$signature)

            $x509certificates = $signature.KeyInfo.x509Data
            if (-not [System.String]::IsNullOrEmpty($x509certificates))
            {
                # Find the signing certificate, and add intermediate certificate to enable disconnected validation
                foreach($x509certificate in $x509certificates.X509Certificate)
                {
                    $certBytes = [System.Convert]::FromBase64String($x509certificate)
                    $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $certBytes,$null
                    Write-Verbose $certificate.Thumbprint
                    if ($signedXml.CheckSignature($certificate,$true))
                    {
                        # This is the signing certificate
                        Write-Verbose "This is the signing certificate $($certificate.Thumbprint)"
                        Write-Verbose "$XmlPath,$($certificate.Thumbprint)"
                        $signingCertificate = $certificate
                    }
                    elseif (Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object {$_.Thumbprint -eq $certificate.Thumbprint})
                    {
                        # This is an existing trusted root
                        Write-Verbose "This is an existing trusted root $($certificate.Thumbprint)"
                    }
                    else
                    {
                        # This is not the signing certificate or an existing trusted root, add it to Intermediate CAs...
                        # ...this allows IsMicrosoftCertificate and x509Chain.Build to function, even when disconnected.
                        Write-Verbose "$($certificate.Thumbprint)"
                        if (Get-ChildItem -Path Cert:\LocalMachine\CA | Where-Object {$_.Thumbprint -eq $certificate.Thumbprint})
                        {
                            Write-Verbose "existing $($certificate.Thumbprint)"
                        }
                        else
                        {
                            Write-Verbose "Add $($certificate.Thumbprint)"
                            $x509Store = New-Object System.Security.Cryptography.X509Certificates.X509Store('CA','LocalMachine')
                            $x509Store.Open('ReadWrite')
                            $x509Store.Add($certificate)
                            $x509Store.Dispose()
                        }
                    }
                }

                # Test that the signing certificate is a trusted certificate.
                if ($signingCertificate)
                {
                    if (Test-MicrosoftCertificate -Certificate $signingCertificate)
                    {
                        Write-Verbose "Valid and msft $XmlPath,$($signingCertificate.Thumbprint)"
                        $validSignature = $true
                        $isSignedByMicrosoft = $true
                    }
                    elseif (Test-AlternateRoot -Certificate $signingCertificate)
                    {
                        Write-Verbose "Alt $XmlPath,$($signingCertificate.Thumbprint)"
                        $validSignature = $true
                        $isSignedByMicrosoft = $true
                    }
                    else
                    {
                        Write-Warning "Untrusted $XmlPath,$($signingCertificate.Thumbprint)"
                    }
                }
                else
                {
                    # We did not find a signing certificate, so the signature is not valid.
                    Write-Verbose "Invalid $XmlPath"
                }
            }
        }
    }
    else
    {
        Write-Warning "XML package is unsigned: $XmlPath"
    }

    # Return validation result
    if (-not $validSignature)
    {
        Write-Verbose "XML signature validation failed for: $XmlPath"
        return $false
    }

    return $isSignedByMicrosoft
}

# this function is based on code from PowerShellGet
function Test-MicrosoftCertificate
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]
        $Certificate
    )

    try
    {
        $requiredAssembly = @( [System.Management.Automation.PSCmdlet].Assembly.FullName,
                               [System.Net.IWebProxy].Assembly.FullName,
                               [System.Uri].Assembly.FullName )
        $source = @"
using System;
using System.Net;
using System.Management.Automation;
using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;
using System.Runtime.InteropServices;

namespace Microsoft.PowerShell.CodeSigning
{
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CERT_CHAIN_POLICY_PARA {
        public CERT_CHAIN_POLICY_PARA(int size) {
            cbSize = (uint) size;
            dwFlags = 0;
            pvExtraPolicyPara = IntPtr.Zero;
        }
        public uint   cbSize;
        public uint   dwFlags;
        public IntPtr pvExtraPolicyPara;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CERT_CHAIN_POLICY_STATUS {
        public CERT_CHAIN_POLICY_STATUS(int size) {
            cbSize = (uint) size;
            dwError = 0;
            lChainIndex = IntPtr.Zero;
            lElementIndex = IntPtr.Zero;
            pvExtraPolicyStatus = IntPtr.Zero;
        }
        public uint   cbSize;
        public uint   dwError;
        public IntPtr lChainIndex;
        public IntPtr lElementIndex;
        public IntPtr pvExtraPolicyStatus;
    }

    public class Helper
    {
        [DllImport("Crypt32.dll", CharSet=CharSet.Auto, SetLastError=true)]
        public extern static
        bool CertVerifyCertificateChainPolicy(
            [In]     IntPtr                       pszPolicyOID,
            [In]     SafeX509ChainHandle pChainContext,
            [In]     ref CERT_CHAIN_POLICY_PARA   pPolicyPara,
            [In,Out] ref CERT_CHAIN_POLICY_STATUS pPolicyStatus);

        [DllImport("Crypt32.dll", CharSet=CharSet.Auto, SetLastError=true)]
        public static extern
        SafeX509ChainHandle CertDuplicateCertificateChain(
            [In]     IntPtr pChainContext);

        public static bool IsMicrosoftCertificate([In] SafeX509ChainHandle pChainContext)
        {
            const uint MICROSOFT_ROOT_CERT_CHAIN_POLICY_ENABLE_TEST_ROOT_FLAG       = 0x00010000;

            CERT_CHAIN_POLICY_PARA PolicyPara = new CERT_CHAIN_POLICY_PARA(Marshal.SizeOf(typeof(CERT_CHAIN_POLICY_PARA)));
            CERT_CHAIN_POLICY_STATUS PolicyStatus = new CERT_CHAIN_POLICY_STATUS(Marshal.SizeOf(typeof(CERT_CHAIN_POLICY_STATUS)));
            int CERT_CHAIN_POLICY_MICROSOFT_ROOT = 7;

            PolicyPara.dwFlags = (uint) MICROSOFT_ROOT_CERT_CHAIN_POLICY_ENABLE_TEST_ROOT_FLAG;

            if(!CertVerifyCertificateChainPolicy(new IntPtr(CERT_CHAIN_POLICY_MICROSOFT_ROOT),
                                                 pChainContext,
                                                 ref PolicyPara,
                                                 ref PolicyStatus))
            {
                return false;
            }

            return (PolicyStatus.dwError == 0);
        }
    }
}
"@
        Add-Type -ReferencedAssemblies $requiredAssembly -TypeDefinition $source -Language CSharp -ErrorAction Stop
    }
    catch
    {
        Write-Verbose "Error $($_.ToString())"
        return $false
    }

    try
    {
        $X509Chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $null = $X509Chain.Build($Certificate)
    }
    catch
    {
        Write-Verbose "eror $($_.ToString())"
        return $false
    }

    $SafeX509ChainHandle = [Microsoft.PowerShell.CodeSigning.Helper]::CertDuplicateCertificateChain($X509Chain.ChainContext)
    return [Microsoft.PowerShell.CodeSigning.Helper]::IsMicrosoftCertificate($SafeX509ChainHandle)
}





function Test-AlternateRoot
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    Param (
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]
        $Certificate,

        # Alternate roots are select Microsoft roots published here --> https://www.microsoft.com/pkiops/docs/repository.htm
        [System.String[]]
        $AlternateRoots = @(
            '8F43288AD272F3103B6FB1428485EA3014C0BCFE'
            '3B1EFD3A66EA28B16697394703A72CA340A05BD5'
        )
    )

    $result = $false

    $x509Chain = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Chain
    $null = $x509Chain.Build($Certificate)
    foreach ($alternateRoot in $AlternateRoots)
    {
        if ($x509Chain.ChainElements.Certificate[-1].Thumbprint -eq $alternateRoot)
        {
            $result = $true
        }
    }

    return $result
}

Test-XMLSignatureByMicrosoft -XmlPath $XmlPath
# SIG # Begin signature block
# MIInRQYJKoZIhvcNAQcCoIInNjCCJzICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDaalnNQTOdqg1C
# AdVI44QMwE6ZlrJCUcEKQETzHgSvD6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnhMIIZ3QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIAE9wVZB
# 5DZDF0zQxPkRGeGnH+c/VY9v8zAa0eIXd7IaMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEApmzastaZzlr52ZZZRJTi80sfAxGg3vI7W4n1WzH9
# XuWmykeujggdrrTupRNZHyl+r4nZTyNi2T9k7WGdbWRFaoEsBxDBCvVUXlidzOpi
# lAqhs+lfVn6LxRdCYo9IA2g0klFXn6bADwbnuAUNfl7C/vGUDCnLHcupzAVTVC9g
# HtezGtPPPblPTSWtFyntx1YZoMklF7ncpZi3ljWJHsshO+V89xayFtTxaKz6pWb9
# lPbYQtF0yaR4gGmAdei/66vrWnGMocak+5U9/LKynHgZOsmfFwz/39+nXKwcnl97
# RZL1XR1XcEUpm2qjn/Aum9kY6ZIpXkqrgeTVWdR/H6EZFaGCF5MwghePBgorBgEE
# AYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2wwghdoAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBxX79c0RVa57VGx4h5XAeKonqPQvKlnlaj/UT6
# HzY0zAIGaedeW7JzGBIyMDI2MDUwMzE0MzEyMS4wNFowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpBNDAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMzAAACKPClh9fzyB5AAAEAAAIo
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5NDAwNloXDTI3MDUxNzE5NDAwNlowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNDAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK6O9uT+ypwJJF5lol8K5/U3BFxz
# teSeETrCQuh+Q2PWbEQCDfmrLbFwWOCNqu1W8DT1bxAdynIypVJc5PE0cmyaTSo/
# YIMu9QC6VaDtpLmgE5GkRfWjPefRHac+p4fQgcrXMnGPFodbbUBu5nRn7AzdZg3O
# QGVweZV7TdkbuuWTbyHvavk/kwTwUakWZhbkeXumwpuAsR+tgCK2m22xv6xmwFQj
# 6EwqXi4slii0rJm/V7A4iKcF9FTxCiyK+Oh9oF7NR/011X6IataHfbVadKwrcD8m
# XoYu1tJZdwlZQuBvG6qehs8r5iUHfXvhMxZOBfhhaMbujQ63P+mMc0IoFsHvzx3K
# eEt0ZjoHTwT37hIatGmy3LiIkc7J0cIDkziLnJhHCx2636Ca/EilPzI1clyMkKDS
# 87ya/+cVj1bK2/aqYK0IUWK8ZRapTbT+xR5GihBkaJA4lCfT3kKPeKwiy9E/wpTu
# E38QMjwdWxv80/MwUu9HOetGePRM6cOI5NRydjCaT5d+hLWjCyRwIILAedsLTQPn
# zPzfLsrlkkHvjmFyfgITadHd7pEayvjbLmq23ox3P+zsxOcNLZSZUdZfVf8dl7dS
# VfyCP+3rcvnTEg+qREIER0zUAM1RpJ+j05CIpv9uPV2JkIZN8QNQEEuinWaGTAgX
# zZ9qmVXZu6xn5TiRAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUqsmljPjy3Oi69WQF
# W2EBIWlD3cMwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAJDo18uatFqGBW2BaDfz
# cZpLTt8fKh3puFxQ423a1637oFo24fSvsAGRUeF46nEF2tSs4RhURoiKL10rdy5k
# s2anWJQDH9VuY5liXvHP602uMJaquDWNCarShEHyIThAmnA2EY/ruhjmG5ghTQPi
# WEOhqGp+Aomf/QGT71QoM/DleVRiat4WYmWP1hDNw896nwzEFfGH9jkju9B5Fpbl
# KO2ItA4tGTeCC+toOzlJ/j0wlXr8HDFcLau9R8QVfpJQOiioogT02BUhGrRFm7s6
# 3SLQiz4e88/SEHorA7EyDVJYo59O0Wlal2jwwm+AoIeQ+lcTOCms/6nIge47uBVG
# VJOxtgEUuHbIh3+K0zi5gvRH7ZJIEFOlJJG2Gsa4SYSUjkEIczHMyD+iodI/BkAg
# CQzYLjHGLRK3uoy4D6b5nMViR+gXjVChImf4eOqGpZhDSb9I738qclEklTAx3lOI
# yeNn4T8MmJSvLm52JbJCm9+PaFAUjR2OFqGgBcNrN4RyIsXa4SdO6v1R+NzA66f+
# gxj5Qt+2c6LaMosyut5XT3tqTPP8nGmcOBglT+2BTt9B+WDsiqIv37Tbvr6OhAej
# bWZV5jlgPwqH+RRpjomb85Mzzwbt69PP+qdG6bGi9OMxK2+lsAc1GGZJN0g9NXfY
# LK7EMpL9XlrmLAD5/1WIGj7CMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
# AAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUg
# QXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2
# AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpS
# g0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2r
# rPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k
# 45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSu
# eik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09
# /SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR
# 6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxC
# aC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaD
# IV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMUR
# HXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMB
# AAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQq
# p1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ
# 6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBB
# MAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP
# 6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWlj
# cm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2
# LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMu
# Y3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2
# Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03d
# mLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1Tk
# eFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kp
# icO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKp
# W99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrY
# UP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QB
# jloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkB
# RH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0V
# iY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq
# 0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1V
# M1izoXBm8qGCA00wggI1AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAHWtuYWTNLuoArU5q/TwBSeFs0hSoIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoaz2MCIYDzIw
# MjYwNTAzMTExNjA2WhgPMjAyNjA1MDQxMTE2MDZaMHQwOgYKKwYBBAGEWQoEATEs
# MCowCgIFAO2hrPYCAQAwBwIBAAICHfwwBwIBAAICE4wwCgIFAO2i/nYCAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAvCwvaZCaBeEQcg37dBxvx2idwiqz0ytH
# kt4lz7CQLW+/vt3RjB3KXZc0M0ImvOUBpaX52/8EUdMh1mP+sDj6Zgo33pRyLNUo
# JixtFmkBfeHs3AMciTdXZU1hQ3gQ07neIjvH5wfkIoJjXHrG4loa+KAv37Zj5xcQ
# FzKuI1h9wkv74BKp6CONR53FAbCvZtqGBQxCsEcx+2WKPgSOh3vMO9y2kFILH46g
# bvIQ6P3tQONH2MYaGyrUjepaKKpqfHzsUnXQsFqrDm+TlHE1ZYAesRQ4vv/4i1qq
# oKxwcXM+gy/nyab5yzJaM08HyRVWr3x+DcEUSe6e6i2VBFAVmeXUcTGCBA0wggQJ
# AgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAk
# BgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACKPClh9fz
# yB5AAAEAAAIoMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZI
# hvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIIGg38PhgwY7XkDqfmyYYGKDoSyVqiF3
# VIAeVm7bkQHSMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgVbGKRlFgY1/i
# gRVkrV5Pjkf7cZDf+rFXvlXC4G36ItcwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDAiBCCngJvYXqC45nIN
# w/BRcmLSzsyfuqLajZnUFnktmUfbyzANBgkqhkiG9w0BAQsFAASCAgBHFp9Jpb7X
# zKu2aMeVtBilRs2Dk8ES4+pCX+I8SeLMPOmpanoeXCppWfBRm6i58aJguu3ZkxZ6
# w1hXVBZWb6f5IUzmdQALV1W1/sLeKjQEzWERrYAOxTnH0+PRKIrPk3OQxLt50WV6
# 0B4Z7wzrnkyPMH6fKqsmZbhJGdMPqRSNQjnka9dn0rIOOYWBsksIG7q4SESepDPH
# PxegM0g+8jL2skA2GEnRy1ZVoQFg++jUQGUOjxVfdp7x4RkTR2iG8/+yxavZLCi4
# dPUQasjJQv2W7lyboFtT7GnzaICkn9nLornH2LoqRbeyvCL3K9BgpfTzFVDTcQZ+
# /6kEn/Ue3xNr0iDNOlbD9jkeSfcLTWWym/zkXr8PDGiCrEpDokEQfvVfbU75FpCo
# 2hhKDEz6y1uQ1qSjfbjbRMmR/shmfGJPmurR+UT7kKKjR5ANCB99j1YhYcWjHrhd
# +Pi1g7E2FxYQPX5EmcqgWXvFVChh61+QkC5M7PZwPCKLy/jK9In1z8X6mE76iEEZ
# L2XwNP5Y07AkGXs/OED5Tp6jDk+tnAWOUSQ+r4ULz04SvjFR0g763wqGX7cph/n6
# KvpISUMHDXnuKMd8WVfsrjTZojkVDfvbaHChqGg8fBkVGTCVG5zSC5Cmcuqkl0C6
# +VbCsNMxlOQZCeZoWuMLcPzy9yiGim07Dg==
# SIG # End signature block
