<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>
Import-LocalizedData -BindingVariable lvsTxt -FileName AzStackHCI.RemoteSupport.Strings.psd1
Import-Module $PSScriptRoot\AzStackHCI.RemoteSupport.Helpers.psm1 -DisableNameChecking -Global

<#
.SYNOPSIS
    Enables Remote Support.

.DESCRIPTION
    Enables Remote Support allows authorized Microsoft Support users to remotely access the device for diagnostics or repair depending on the access level granted.

    During Remote Support JEA configuration, WinRM will be restarted twice and that can break the PsSession to node if you are installing Remote Support remotely. In that case, connect to remote node again and execute Enable cmdlet again after 4-5 minutes.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Enable-AzStackHciRemoteSupport -AccessLevel Diagnostics -ExpireInMinutes 1440 -SasCredential "Sample SAS" -PassThru

    Processing data from remote server v-host1 failed with the following error message: The I/O operation has been aborted because of either a thread exit or an application request. For more information, see the about_Remote_Troubleshooting Help topic.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Enable-AzStackHciRemoteSupport -AccessLevel Diagnostics -ExpireInMinutes 1440 -SasCredential "Sample SAS" -PassThru

.PARAMETER AccessLevel
    Controls the remote operations that can be performed. This can be either Diagnostics or DiagnosticsAndRepair.

.PARAMETER ExpireInDays
    Optional. Defaults to 8 hours.

.PARAMETER SasCredential
    Hybrid Connection SAS Credential.

.PARAMETER AgreeToRemoteSupportConsent
    Optional. If set to true then records user consent as provided and proceeds without prompt.

.EXAMPLE
    The example below enables remote support for diagnostics access level for specified duration. After expiration no more remote access is allowed.

    During Remote Support JEA configuration, WinRM will be restarted twice and that can break the PsSession to node if you are installing Remote Support remotely. In that case, connect to remote node again and execute Enable cmdlet again after 4-5 minutes.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Enable-AzStackHciRemoteSupport -AccessLevel Diagnostics -ExpireInMinutes 1440 -SasCredential "Sample SAS" -PassThru

    Processing data from remote server v-host1 failed with the following error message: The I/O operation has been aborted because of either a thread exit or an application request. For more information, see the about_Remote_Troubleshooting Help topic.

    PS C:\> Enter-PsSession -ComputerName <NodeName> -Credential $cred

    PS C:\> Enable-AzStackHciRemoteSupport -AccessLevel Diagnostics -ExpireInMinutes 1440 -SasCredential "Sample SAS" -PassThru

.NOTES
    Requires Support VM to have stable internet connectivity.
#>
function Enable-AzStackHciRemoteSupport
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Diagnostics","DiagnosticsRepair")]
        [string]
        $AccessLevel,

        [Parameter(Mandatory=$false)]
        [int]
        $ExpireInMinutes = 480,

        [Parameter(Mandatory=$false)]
        [string]
        $SasCredential,

        [Parameter(Mandatory=$false)]
        [switch]
        $AgreeToRemoteSupportConsent,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath='Enable',

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false
    )

    try
    {
        $OperationType = $MyInvocation.MyCommand
        $script:ErrorActionPreference = 'Stop'
        $LogSource = "AzStackHciEnvironmentChecker/RemoteSupport"
        $EventID = "18101"
        Set-AzStackHciOutputPath -Path $OutputPath -Source $LogSource

        # Ensure we are elevated
        if (Test-Elevation)
        {
            Log-Info -Message ($lvsTxt.ElevationModeInfo) -Type Info
        }
        else
        {
            Log-Info -Message ($lvsTxt.ElevationModeMsg) -Type Error -ConsoleOut
            throw $($lvsTxt.ElevationModeErrMsg)
        }

        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        $cmdResult = AzStackHCI.RemoteSupport.Helpers\Enable-AzStackHCIRemoteSupport -AccessLevel $AccessLevel -ExpireInMinutes $ExpireInMinutes -SasCredential $SasCredential -AgreeToRemoteSupportConsent:$AgreeToRemoteSupportConsent

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Remote Support Results'
            Write-AzStackHciResult -Title 'EnableRemoteSupport' -Result $cmdResult
            Write-Summary -Result $cmdResult -Property1 Detail
        }
        else
        {
            return $cmdResult
        }
    }
    catch
    {
        $exception = $_
        Trace-Execution "$OperationType failed. $exception"
        Trace-Execution "$($exception.ScriptStackTrace)"
        throw $exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        $enableResult = $($cmdResult.AdditionalData | Format-List | Out-String)
        # Write result to RemoteSupport channel
        Write-ETWLog -Source $LogSource -Message "Enable Remote Support: $enableResult `n Service Status : $(Get-Service "RemoteSupportAgent") `n JEA Endpoints: $(Get-PSSessionConfiguration "*SupportDiag*")" -EventId $EventID

        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'EnableRemoteSupport' -Value $enableResult -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
    }
}

<#
.SYNOPSIS
    Gets Remote Support Access.

.DESCRIPTION
    Gets remote support access.

.PARAMETER IncludeExpired
    Optional. Defaults to false. Indicates whether to include past expired entries.

.PARAMETER Cluster
    Optional. Defaults to false. Indicates whether to show remote support sessions across cluster.

.EXAMPLE
    The example below retrieves access level granted for remote support. The result will also include expired consents in the last 30 days.
    PS C:\> Get-AzStackHciRemoteSupportAccess -IncludeExpired -PassThru

.NOTES

#>
function Get-AzStackHciRemoteSupportAccess
{
    param(
        [Parameter(Mandatory=$false)]
        [switch]
        $IncludeExpired,

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath='GetAccess',

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $true
    )

    try
    {
        $OperationType = $MyInvocation.MyCommand
        $script:ErrorActionPreference = 'Stop'
        $LogSource = "AzStackHciEnvironmentChecker/RemoteSupport"
        $EventID = "18102"
        Set-AzStackHciOutputPath -Path $OutputPath -Source $LogSource

        # Ensure we are elevated
        if (Test-Elevation)
        {
            Log-Info -Message ($lvsTxt.ElevationModeInfo) -Type Info
        }
        else
        {
            Log-Info -Message ($lvsTxt.ElevationModeMsg) -Type Error -ConsoleOut
            throw $($lvsTxt.ElevationModeErrMsg)
        }

        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        $cmdResult = AzStackHCI.RemoteSupport.Helpers\Get-AzStackHCIRemoteSupportAccess -IncludeExpired:$IncludeExpired

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Remote Support Results'
            Write-AzStackHciResult -Title 'GetRemoteSupportAccess' -Result $cmdResult
            Write-Summary -Result $cmdResult -Property1 Detail
        }
        else
        {
            return $cmdResult
        }
    }
    catch
    {
        $exception = $_
        Trace-Execution "$OperationType failed. $exception"
        Trace-Execution "$($exception.ScriptStackTrace)"
        throw $exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        $accessResult = if (-not [string]::IsNullOrWhiteSpace($($cmdResult.AdditionalData.State))) {$($cmdResult.AdditionalData | Format-List | Out-String)} else {"No remote support access exists."}

        # Write result to RemoteSupport channel
        Write-ETWLog -Source $LogSource -Message "Get Remote Support Access: $accessResult" -EventId $EventID

        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'GetRemoteSupportAccess' -Value $accessResult -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
    }
}

<#
.SYNOPSIS
    Gets Remote Support Session History Details.

.DESCRIPTION
    Session history represents all remote accesses made by Microsoft Support for either Diagnostics or DiagnosticsRepair based on the Access Level granted.

.PARAMETER SessionId
    Optional. Session Id to get details for a specific session. If omitted then lists all sessions starting from date 'FromDate'.

.PARAMETER IncludeSessionTranscript
    Optional. Defaults to false. Indicates whether to include complete session transcript. Transcript provides details on all operations performed during the session.

.PARAMETER FromDate
    Optional. Defaults to last 7 days. Indicates date from where to start listing sessions from until now.

.EXAMPLE
    The example below retrieves session history with transcript details for the specified session.
    PS C:\> Get-AzStackHciRemoteSupportSessionHistory -SessionId 467e3234-13f4-42f2-9422-81db248930fa -IncludeSessionTranscript $true -PassThru

.EXAMPLE
    The example below lists session history starting from last 7 days (default) to now.
    PS C:\> Get-AzStackHciRemoteSupportSessionHistory -PassThru

.NOTES
#>
function Get-AzStackHciRemoteSupportSessionHistory
{
    param(
        [Parameter(Mandatory=$false)]
        [string]
        $SessionId,

        [Parameter(Mandatory=$false)]
        [switch]
        $IncludeSessionTranscript,

        [Parameter(Mandatory=$false)]
        [DateTime]
        $FromDate = (Get-Date).AddDays(-7),

        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath = 'GetSessionHistory',

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false
    )

    try
    {
        $OperationType = $MyInvocation.MyCommand
        $script:ErrorActionPreference = 'Stop'
        $LogSource = "AzStackHciEnvironmentChecker/RemoteSupport"
        $EventID = "18103"
        Set-AzStackHciOutputPath -Path $OutputPath -Source $LogSource

        # Ensure we are elevated
        if (Test-Elevation)
        {
            Log-Info -Message ($lvsTxt.ElevationModeInfo) -Type Info
        }
        else
        {
            Log-Info -Message ($lvsTxt.ElevationModeMsg) -Type Error -ConsoleOut
            throw $($lvsTxt.ElevationModeErrMsg)
        }

        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        $cmdResult = AzStackHCI.RemoteSupport.Helpers\Get-AzStackHCIRemoteSupportSessionHistory -SessionId $SessionId -FromDate $FromDate -IncludeSessionTranscript:$IncludeSessionTranscript

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Remote Support Results'
            Write-AzStackHciResult -Title 'GetRemoteSupportSessionHistory' -Result $cmdResult
            Write-Summary -Result $cmdResult -Property1 Detail
        }
        else
        {
            return $cmdResult
        }
    }
    catch
    {
        $exception = $_
        Trace-Execution "$OperationType failed. $exception"
        Trace-Execution "$($exception.ScriptStackTrace)"
        throw $exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        $sessionResult = $($cmdResult.AdditionalData | Format-List | Out-String)
        # Write result to RemoteSupport channel
        Write-ETWLog -Source $LogSource -Message "Get Remote Support Session History: $sessionResult" -EventId $EventID

        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'GetRemoteSupportSessionHistory' -Value $sessionResult -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
    }
}

<#
.SYNOPSIS
    Disables Remote Support.

.DESCRIPTION
    Disable Remote Support revokes all access levels previously granted. Any existing support sessions will be terminated, and new sessions can no longer be established.

.EXAMPLE
    The example below disables remote support.
    PS C:\> Disable-AzStackHCIRemoteSupport -PassThru

.NOTES

#>
function Disable-AzStackHciRemoteSupport
{
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath = 'Disable',

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false
    )

    try
    {
        $OperationType = $MyInvocation.MyCommand
        $script:ErrorActionPreference = 'Stop'
        $LogSource = "AzStackHciEnvironmentChecker/RemoteSupport"
        $EventID = "18104"
        Set-AzStackHciOutputPath -Path $OutputPath -Source $LogSource

        # Ensure we are elevated
        if (Test-Elevation)
        {
            Log-Info -Message ($lvsTxt.ElevationModeInfo) -Type Info
        }
        else
        {
            Log-Info -Message ($lvsTxt.ElevationModeMsg) -Type Error -ConsoleOut
            throw $($lvsTxt.ElevationModeErrMsg)
        }

        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport

        $cmdResult = AzStackHCI.RemoteSupport.Helpers\Disable-AzStackHCIRemoteSupport

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Remote Support Results'
            Write-AzStackHciResult -Title 'DisableRemoteSupportAccess' -Result $cmdResult
            Write-Summary -Result $cmdResult -Property1 Detail
        }
        else
        {
            return $cmdResult
        }
    }
    catch
    {
        $exception = $_
        Trace-Execution "$OperationType failed. $exception"
        Trace-Execution "$($exception.ScriptStackTrace)"
        throw $exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        $disableResult = $($cmdResult| Format-List | Out-String)
        # Write result to RemoteSupport channel
        Write-ETWLog -Source $LogSource -Message "Disable Remote Support: $disableResult" -EventId $EventID

        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'DisableRemoteSupport' -Value $disableResult -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
    }
}

<#
.SYNOPSIS
    Removes Remote Support.

.DESCRIPTION
    Remove-AzStackHCIRemoteSupport uninstalls Remote Support Deployment module.

.EXAMPLE
    C:\PS> Remove-AzStackHciRemoteSupport -PassThru

.NOTES
#>
function Remove-AzStackHciRemoteSupport
{
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Return PSObject result.")]
        [switch]
        $PassThru,

        [Parameter(Mandatory = $false, HelpMessage = "Directory path for log and report output")]
        [string]$OutputPath = 'Remove',

        [Parameter(Mandatory = $false, HelpMessage = "Remove all previous progress and create a clean report")]
        [switch]$CleanReport = $false
    )

    try
    {
        $OperationType = $MyInvocation.MyCommand
        $script:ErrorActionPreference = 'Stop'
        $LogSource = "AzStackHciEnvironmentChecker/RemoteSupport"
        $EventID = "18105"
        Set-AzStackHciOutputPath -Path $OutputPath -Source $LogSource

        # Ensure we are elevated
        if (Test-Elevation)
        {
            Log-Info -Message ($lvsTxt.ElevationModeInfo) -Type Info
        }
        else
        {
            Log-Info -Message ($lvsTxt.ElevationModeMsg) -Type Error -ConsoleOut
            throw $($lvsTxt.ElevationModeErrMsg)
        }

        Test-ModuleUpdate -PassThru:$PassThru

        # Call/Initialise reporting
        $envcheckerReport = Get-AzStackHciEnvProgress -clean:$CleanReport
        $envcheckerReport = Add-AzStackHciEnvJob -report $envcheckerReport
        
        $cmdResult = AzStackHCI.RemoteSupport.Helpers\Remove-AzStackHCIRemoteSupport

        # Feedback results - user scenario
        if (-not $PassThru)
        {
            Write-Host 'Remote Support Results'
            Write-AzStackHciResult -Title 'RemoveRemoteSupport' -Result $cmdResult
            Write-Summary -Result $cmdResult -Property1 Detail
        }
        else
        {
            return $cmdResult
        }
    }
    catch
    {
        $exception = $_
        Trace-Execution "$OperationType failed. $exception"
        Trace-Execution "$($exception.ScriptStackTrace)"
        throw $exception
    }
    finally
    {
        $Script:ErrorActionPreference = 'SilentlyContinue'
        $removeResult = $($cmdResult | Format-List | Out-String)
        # Write result to RemoteSupport channel
        Write-ETWLog -Source $LogSource -Message "Remove Remote Support: $removeResult" -EventId $EventID

        # Write validation result to report object and close out report
        $envcheckerReport | Add-Member -MemberType NoteProperty -Name 'RemoveRemoteSupport' -Value $removeResult -Force
        $envcheckerReport = Close-AzStackHciEnvJob -report $envcheckerReport
        Write-AzStackHciEnvReport -report $envcheckerReport
    }
}

Export-ModuleMember -Function Enable-AzStackHciRemoteSupport
Export-ModuleMember -Function Disable-AzStackHciRemoteSupport
Export-ModuleMember -Function Get-AzStackHciRemoteSupportAccess
Export-ModuleMember -Function Get-AzStackHciRemoteSupportSessionHistory
Export-ModuleMember -Function Remove-AzStackHciRemoteSupport

# SIG # Begin signature block
# MIInbgYJKoZIhvcNAQcCoIInXzCCJ1sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDA98oFt+grpte8
# mJBNNat7CZUGZSVrnmTKDtQqxRFK96CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIGrfQclv8BDao953Mzc2bzTsL6J+85anp8TeXnu5DZPwMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAJpv7XZSYibp8cYWlav2t
# sRbBa2zhqnACDL+Jr5Tbb5g1nWdXfjXiSvNm3Wivpuj6QRK5XZmIW8AM6EXgFMMc
# opCnd6X+sD1fRm0MYvv77HgCgrzbtD302NwpNe6nRMFthQhABmA+5cEgmVSZ7EVZ
# zdzt+FxB+2ZD5YARZakXH9mrJV1hM8Yes4KkuMMfrYc2ZxjnarZTAzL0j5eHS1N+
# mz2HlHHNpe07gNptCD4/ItPFikVg2d//x5WnwU5ztKoBZ13dxjjLt84NXzLoBmTB
# rNNQ9G2xqfr7O8DT9rCiyZSBO5x+HUUTChyAJIco/VtnHe8wuTT1NN/6UKQ7iAVk
# TKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBOz5mKD6bZhN3JCHWg
# dN3IaM/CfY40k6er3b+V7RLUsQIGaetNikkhGBMyMDI2MDUwMzE0MzExMS43MTVa
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
# BDAvBgkqhkiG9w0BCQQxIgQgNZyIILzWVSTXPoh97jmoPcTxZ7iNTq0MA2zk5gHz
# aVkwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCAsrTOpmu+HTq1aXFwvlhjF
# 8p2nUCNNCEX/OWLHNDMmtzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACEUUYOZtDz/xsAAEAAAIRMCIEIFHdqckqPztfPR5SHvAKDAqW
# eSRimzk9kmF7IPFYNiguMA0GCSqGSIb3DQEBCwUABIICAEgbv+ma2JsSpVyolujX
# oWtJyCNbMYJptmlfk1LtFyXqMkKrhALMHXYKM/k3LW5xkijPZxos7wh2O5k483Ad
# BxJHwjoUJ33qbXdH7EJkU2oVBWIHAiO36lGI8C+zDtZDXleX4zHekV3/zxGkqDhk
# 6QV0/Umhm/Bz7K9+tP8cTUiqPEPKTMNki52u3Mg8Et5AbJZOLDssQRYCDT1pLSs1
# W/9iXe0kMxKTictqmYnJCjsAoVMTK/pNxDOgnTS7FROw2K8aoIxsVrcHnhemG8vR
# rqtjK2xBMOxhUNg5ynL6ry/A2ZcYTYSRAL3UsV7XhS017bpbKAuVJssjpeeL1nrM
# TCzwqn4kmX87GP5FmzrLFnuSpJE0gxVnjS1llcYEM2W0PXNmGcdIFCI0VDLTazSy
# GcMnPQoUgk/SHp9bRBY8h7ANpH7QAocvIwHHCCubOi6mIBvmONkX+0u49gszmhQd
# q+Cfw8XErYzJiIAsIuHqWExmHrPI7SYeK/3qIjAuChFJGsAO7wWId/92YnrjtLwB
# h0pN6L0kHKLn3TXQgoTzKudPPFHYi2pwb2IAuFZ6dALD/yPgkKYSM7IZ9/JWsQZz
# 4zTvDIXOA3gGb5KyQ4OQiAV4JmPHkHNsXd6zEtWMr51BZCusQnyfq96lCw64IynR
# c0zLlzLbm55qqhUkt2wGpYNy
# SIG # End signature block
