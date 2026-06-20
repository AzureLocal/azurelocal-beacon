<#
    Small portable lightweight/standalone functions that are required to be called as signed local modules
    for the purpose of satisfying the Constraint Language Mode.
#>

function Get-SslCertificateChain
{
    <#
    .SYNOPSIS
        Retrieve remote ssl certificate & chain from https endpoint for Desktop and Core
    .NOTES
        Credit: https://github.com/markekraus
    #>
    [CmdletBinding()]
    param (
        [system.uri]
        $url,

        [Parameter()]
        [string]
        $Proxy,

        [Parameter()]
        [pscredential]
        $ProxyCredential
    )
    try
    {
        $cs = @'
    using System;
    using System.Collections.Generic;
    using System.Net.Http;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;

    namespace CertificateCapture
    {
        public class Utility
        {
            public static Func<HttpRequestMessage,X509Certificate2,X509Chain,SslPolicyErrors,Boolean> ValidationCallback =
                (message, cert, chain, errors) => {
                    CapturedCertificates.Clear();
                    var newCert = new X509Certificate2(cert);
                    var newChain = new X509Chain();
                    newChain.Build(newCert);
                    CapturedCertificates.Add(new CapturedCertificate(){
                        Certificate =  newCert,
                        CertificateChain = newChain,
                        PolicyErrors = errors,
                        URI = message.RequestUri
                    });
                    return true;
                };
            public static List<CapturedCertificate> CapturedCertificates = new List<CapturedCertificate>();
        }

        public class CapturedCertificate
        {
            public X509Certificate2 Certificate { get; set; }
            public X509Chain CertificateChain { get; set; }
            public SslPolicyErrors PolicyErrors { get; set; }
            public Uri URI { get; set; }
        }
    }
'@

        try
        {
            if (-not ('CertificateCapture.Utility' -as [type]))
            {
                if ($PSEdition -ne 'Core')
                {
                    Add-Type -AssemblyName System.Net.Http
                    Add-Type $cs -ReferencedAssemblies System.Net.Http
                }
                else
                {
                    Add-Type $cs
                }
            }
        }
        catch
        {
            if ($_.Exception.Message -notmatch 'Definition of new types is not supported in this language mode')
            {
                throw "Language mode does not allow this test Error: $_"
            }
        }

        $Certs = [CertificateCapture.Utility]::CapturedCertificates
        $Handler = [System.Net.Http.HttpClientHandler]::new()
        if ($Proxy)
        {
            $Handler.Proxy = New-Object System.Net.WebProxy($proxy)
            if ($proxyCredential)
            {
                $Handler.DefaultProxyCredentials = $ProxyCredential
            }
        }
        $Handler.ServerCertificateCustomValidationCallback = [CertificateCapture.Utility]::ValidationCallback
        $Client = [System.Net.Http.HttpClient]::new($Handler)
        $null = $Client.GetAsync($url).Result
        return $Certs.CertificateChain
    }
    catch
    {
        throw $_
    }
}

function Test-Elevation
{
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
}

function Copy-RemoteItem {
    <#
    .SYNOPSIS
        Copies a file or folder from a local source to a remote machine.

    .DESCRIPTION
        This robust function supports copying either a single file or an entire folder to a remote system.
        It checks SMB connectivity, maps a PSDrive to the remote UNC share, and uses robocopy to perform the copy.
        If DestinationPath is not specified, the remote system’s TEMP folder is used.
        Robocopy’s output is logged to a file under $env:LocalRootFolderPath\MasLogs.
        Optionally, if a CmdletName is provided (and the copy is a file), the module is imported on the remote system
        and the existence of the specified cmdlet is verified.

    .PARAMETER SourcePath
        Full local path of the file or folder to copy.

    .PARAMETER DestinationPath
        (Optional) Destination path on the remote machine (for example, "C:\Temp" or "C:\Temp\MyFolder").
        If not provided, defaults to the remote system’s TEMP folder.

    .PARAMETER PsSession
        (Optional) An array of active PSSessions representing remote machines.

    .PARAMETER TargetNodeName
        (Optional) The remote machine name (if PsSession is not provided).

    .PARAMETER Credential
        (Optional) Credential to use when accessing the remote machine.

    .PARAMETER ExcludeDirs
        (Optional) Array of directory names to exclude (used only for folder copies).

    .PARAMETER ExcludeFiles
        (Optional) Array of file names to exclude (used only for folder copies).

    .PARAMETER SkipFirewallCheck
        (Optional) If specified, the function will skip checking/enabling the SMB firewall rule.

    .PARAMETER CmdletName
        (Optional) If provided (and the copy is a file), after copying the file the function imports it as a module
        on the remote machine and verifies that the specified cmdlet exists.
    #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$SourcePath,

            [Parameter(Mandatory = $false)]
            [string]$DestinationPath,

            [Parameter(Mandatory = $false)]
            [System.Management.Automation.Runspaces.PSSession[]]$PsSession,

            [Parameter(Mandatory = $false)]
            [string]$TargetNodeName,

            [Parameter(Mandatory = $false)]
            [PSCredential]$Credential,

            [Parameter(Mandatory = $false)]
            [string[]]$ExcludeDirs,

            [Parameter(Mandatory = $false)]
            [string[]]$ExcludeFiles,

            [Parameter(Mandatory = $false)]
            [switch]$SkipFirewallCheck,

            [Parameter(Mandatory = $false)]
            [string]$CmdletName
        )

        try {
            # Ensure the log directory exists.
            $logDir = "$($env:LocalRootFolderPath)\MasLogs"
            if (-not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir | Out-Null
            }

            # Verify the source exists.
            if (-not (Test-Path -Path $SourcePath)) {
                throw "Source path '$SourcePath' does not exist."
            }
            $sourceIsDirectory = Test-Path -Path $SourcePath -PathType Container

            # Build a list of targets.
            $targets = @()
            if ($PsSession) {
                foreach ($session in $PsSession) {
                    $targets += [PSCustomObject]@{
                        ComputerName = $session.ComputerName
                        Credential   = $session.Runspace.ConnectionInfo.Credential
                        Session      = $session
                        IsLocal      = $false
                    }
                }
            }
            elseif ($TargetNodeName) {
                # Determine if the target is local.
                $targetIsLocal = $false
                if ($env:ComputerName -eq $TargetNodeName) {
                    $targetIsLocal = $true
                }
                else {
                    $dnsInfo = (Resolve-DnsName -Name $TargetNodeName -ErrorAction SilentlyContinue | Select-Object -First 1)
                    if ($dnsInfo.NameHost) {
                        # Case when IP is resolved
                        $thisComputerName = ($dnsInfo.NameHost).Split('.')[0]
                        if ($env:ComputerName -eq $thisComputerName) {
                            $targetIsLocal = $true
                        }
                    }
                    elseif ($dnsInfo.Name) {
                        # Case when hostname is resolved
                        $thisComputerName = ($dnsInfo.Name).Split('.')[0]
                        if ($env:ComputerName -eq $thisComputerName) {
                            $targetIsLocal = $true
                        }
                    }
                    else {
                        # No DNS match so try IP address instead
                        [array]$myIP = (Get-NetIPAddress).IPAddress
                        if ($TargetNodeName -in $myIP) {
                            $targetIsLocal = $true
                        }
                    }
                }
                $targets += [PSCustomObject]@{
                    ComputerName = $TargetNodeName
                    Credential   = $Credential
                    Session      = $null
                    IsLocal      = $targetIsLocal
                }
            }
            else {
                throw "Either PsSession or TargetNodeName must be provided."
            }

            foreach ($target in $targets) {
                $remoteComputer = $target.ComputerName

                # Determine the destination folder on the remote machine.
                # If no DestinationPath is provided, get the remote TEMP folder.
                $destPathForTarget = $DestinationPath
                if (-not $destPathForTarget) {
                    if ($target.Session) {
                        $destPathForTarget = Invoke-Command -Session $target.Session -ScriptBlock { return $env:TEMP }
                    }
                    else {
                        $destPathForTarget = Invoke-Command -ComputerName $remoteComputer -Credential $target.Credential -ScriptBlock { return $env:TEMP }
                    }
                }

                # Build log file name based on the destination folder’s leaf and remote computer.
                $destLeaf = Split-Path -Path $destPathForTarget -Leaf
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $logPath = "$logDir\AzStackHciEnvironment-envChecker-$destLeaf-$remoteComputer-Copy-$timestamp.log"

                Log-Info -Message "Initiating copy of '$SourcePath' to '$($remoteComputer):$($destPathForTarget)'" -Type Info

                # Check SMB connectivity (unless skipped) and enable the SMB firewall rule if needed.
                if (-not $SkipFirewallCheck) {
                    $firewallRulesChanged = @()
                    if (-not (Test-NetConnection -ComputerName $remoteComputer -Port 445 -InformationLevel Quiet)) {
                        Log-Info -Message "Cannot reach $remoteComputer on port 445. Enabling SMB firewall rule." -Type Info
                        if ($target.Session) {
                            $firewallRulesChanged += Enable-SmbAccess -PsSession $target.Session
                        }
                        else {
                            $firewallRulesChanged += Invoke-Command -ComputerName $remoteComputer -Credential $target.Credential -ScriptBlock {
                                param($computer)
                                # TODO : Would this function be available in the remote session?
                                Enable-SmbAccess -ComputerName $computer
                            } -ArgumentList $remoteComputer
                        }
                        if ($firewallRulesChanged.Count -gt 0) {
                            foreach ($node in $firewallRulesChanged.Keys) {
                                Log-Info -Message "SMB firewall rules enabled on '$($node)': $($firewallRulesChanged.$node -join ',')" -Type Info
                            }
                        }
                        # Retry the SMB connection check after enabling the firewall rule.
                        if (-not (Test-NetConnection -ComputerName $remoteComputer -Port 445 -InformationLevel Quiet)) {
                            Log-Info "Failed to reach $($remoteComputer) on port 445 after enabling SMB-In firewall rules."
                            Log-Info "Some other network policy, or a custom local firewall rule is blocking SMB access to '$($remoteComputer)'."
                            throw "Failed to reach $($remoteComputer) on port 445 after enabling SMB-In firewall rules."
                        }
                    }
                }

                # Determine the UNC path to map.
                # If the destination path is like "C:\Temp" (or the remote TEMP folder),
                # then build the UNC path as "\\RemoteComputer\C$\Temp".
                if ($destPathForTarget -match '^(\w):\\(.*)$') {
                    $driveLetter = $Matches[1]
                    $folderPath  = $Matches[2]
                    $remoteShare = "\\$remoteComputer\$($driveLetter + '$')"
                    if ($folderPath -ne "") {
                        $remoteUNC = Join-Path -Path $remoteShare -ChildPath $folderPath
                    }
                    else {
                        $remoteUNC = $remoteShare
                    }
                }
                else {
                    $remoteUNC = $destPathForTarget
                }
                Log-Info -Message "Mapping PSDrive 'RemoteCopy' to '$remoteUNC' on '$remoteComputer'" -Type Info

                # Remove any existing PSDrive mapping.
                if (Get-PSDrive -Name RemoteCopy -ErrorAction SilentlyContinue) {
                    Get-PSDrive -Name RemoteCopy -ErrorAction SilentlyContinue | Remove-PSDrive -Force
                }

                # Retry mapping the PSDrive.
                $maxRetry  = 4
                $attempt   = 0
                $driveMapped = $false
                while (-not $driveMapped -and $attempt -lt $maxRetry) {
                    $attempt++
                    Log-Info -Message "Attempt $($attempt) to map PSDrive to '$remoteUNC'" -Type Info
                    try {
                        New-PSDrive -Name RemoteCopy -PSProvider FileSystem -Root $remoteUNC -Credential $target.Credential -ErrorAction Stop | Out-Null
                        if (Get-PSDrive -Name RemoteCopy -ErrorAction SilentlyContinue) {
                            $driveMapped = $true
                            Log-Info -Message "PSDrive mapped successfully to '$remoteUNC'" -Type Info
                        }
                    }
                    catch {
                        Log-Info -Message "Mapping PSDrive failed on attempt $($attempt): $($_.Exception.Message)" -Type Info
                        if ($attempt -ge $maxRetry) {
                            throw "Failed to map PSDrive to '$remoteUNC' for file '$SourcePath' on node '$remoteComputer' after $attempt attempts."
                        }
                        Start-Sleep -Seconds 15
                    }
                }

                # Build the final destination path.
                # If the user provided a DestinationPath, do drive-letter replacement;
                # otherwise, simply use the mapped PSDrive’s root.
                if ($DestinationPath) {
                    if ($destPathForTarget -match '^\w:') {
                        $finalDestPath = $destPathForTarget -replace '^\w:', (Get-PSDrive -Name RemoteCopy).Root
                    }
                    else {
                        $finalDestPath = (Get-PSDrive -Name RemoteCopy).Root
                    }
                }
                else {
                    $finalDestPath = (Get-PSDrive -Name RemoteCopy).Root
                }
                Log-Info -Message "Final destination path set to '$finalDestPath'" -Type Info

                # Build the robocopy command.
                if ($sourceIsDirectory) {
                    $copyCmd = "robocopy.exe `"$SourcePath`" `"$finalDestPath`" *.* /MIR /NP /R:2 /W:10 /LOG:`"$logPath`""
                }
                else {
                    $sourceDir  = Split-Path -Path $SourcePath
                    $fileName   = Split-Path -Path $SourcePath -Leaf
                    $copyCmd = "robocopy.exe `"$sourceDir`" `"$finalDestPath`" `"$fileName`" /COPYALL /NP /R:2 /W:10 /LOG:`"$logPath`""
                }
                if ($ExcludeFiles) {
                    $copyCmd += " /XF " + ($ExcludeFiles -join ' ')
                }
                if ($ExcludeDirs) {
                    $copyCmd += " /XD " + ($ExcludeDirs -join ' ')
                }

                Log-Info -Message "Calling: $copyCmd" -Type Info

                try {
                    # Execute robocopy.
                    $output = Invoke-Command -ScriptBlock { param($cmd) cmd.exe /c $cmd } -ArgumentList $copyCmd
                    if ($LASTEXITCODE -ge 8) {
                        Log-Info -Message ("Robocopy failed with exit code {0}" -f $LASTEXITCODE) -ConsoleOut -Type Error
                        Log-Info -Message ($output | Out-String).Trim() -ConsoleOut -Type Info
                        throw "Robocopy failed with exit code $LASTEXITCODE"
                    }
                    else {
                        Log-Info -Message "Robocopy completed successfully." -Type Info
                    }
                }
                catch {
                    Log-Info -Message ("Copy operation failed: " + $_.Exception.Message) -Type Error
                    throw "Copy operation failed for file '$SourcePath' to destination '$destPathForTarget' on node '$remoteComputer': $($_.Exception.Message)"
                }
                finally {
                    # Clean up: remove the mapped PSDrive.
                    if (Get-PSDrive -Name RemoteCopy -ErrorAction SilentlyContinue) {
                        Get-PSDrive -Name RemoteCopy -ErrorAction SilentlyContinue | Remove-PSDrive -Force
                    }
                    # Revert the firewall rule if it was enabled.
                    if ($firewallRulesChanged.Count -gt 0) {
                        Log-Info -Message "Reverting SMB firewall rule on '$remoteComputer'" -Type Info
                        if ($target.Session) {
                            Disable-SmbAccess -PsSession $target.Session | Out-Null
                        }
                        else {
                            Invoke-Command -ComputerName $remoteComputer -Credential $target.Credential -ScriptBlock {
                                param($computer)
                                # TODO : Would this function be available in the remote session?
                                Disable-SmbAccess -ComputerName $computer
                            } -ArgumentList $remoteComputer | Out-Null
                        }
                    }
                }
                Log-Info -Message "Successfully copied '$SourcePath' to '$($remoteComputer):$($destPathForTarget)'" -Type Info

                # If a CmdletName is provided (and this is a file copy), import the module on the remote system.
                if ($CmdletName -and -not $sourceIsDirectory) {
                    $destinationFileName = Split-Path -Path $SourcePath -Leaf
                    # Use the local path (as returned by the remote system) for the module import.
                    $modulePath = Join-Path $destPathForTarget $destinationFileName
                    Log-Info -Message "Importing module from '$modulePath' on '$remoteComputer' to verify cmdlet '$CmdletName'" -Type Info
                    if ($target.Session) {
                        Invoke-Command -Session $target.Session -ScriptBlock {
                            param($modulePath, $CmdletName)
                            Import-Module $modulePath -Force
                            if (-not (Get-Command -Name $CmdletName -ErrorAction SilentlyContinue)) {
                                throw "Failed to import module on $($env:COMPUTERNAME) for cmdlet $CmdletName"
                            }
                        } -ArgumentList $modulePath, $CmdletName
                    }
                    else {
                        Invoke-Command -ComputerName $remoteComputer -Credential $target.Credential -ScriptBlock {
                            param($modulePath, $CmdletName)
                            Import-Module $modulePath -Force
                            if (-not (Get-Command -Name $CmdletName -ErrorAction SilentlyContinue)) {
                                throw "Failed to import module on $($env:COMPUTERNAME) for cmdlet $CmdletName"
                            }
                        } -ArgumentList $modulePath, $CmdletName
                    }
                    Log-Info -Message "Module imported and cmdlet '$CmdletName' verified on '$remoteComputer'" -Type Info
                }
            }
        }
        catch {
            throw "Copy-RemoteItem failed for file '$SourcePath' to destination '$destPathForTarget' on node '$remoteComputer'. Error: $($_.Exception.Message)"
        }
    }

function Enable-SmbAccess
{
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false)]
        [string[]]$Rules = @('FPS-SMB-In-TCP','FailoverCluster-SMB-TCP-In')
    )
    try
    {
        $rulesEnabled = @()
        foreach ($session in $PsSession)
        {
            Log-Info "Enabling SMB access through firewall on $($session.ComputerName)"
            [string[]]$enabled = Invoke-Command -Session $session -ScriptBlock {
                $fwRuleChanged = @()
                foreach ($name in $using:Rules)
                {
                    if ((Get-NetFirewallRule -Name $name).Enabled -eq 'False')
                    {
                        Set-NetFirewallRule -Name $name -Enabled True | Out-Null
                        $fwRuleChanged += $name
                    }
                }
                $fwRuleChanged
            }
            if ($enabled.Count -gt 0)
            {
                $rulesEnabled += @{$session.ComputerName = $enabled}
                foreach ($name in $enabled)
                {
                    Log-Info "SMB access enabled on $($session.ComputerName) for rule: $name"
                }
            }
            else
            {
                Log-Info "No changes made to SMB access on $($session.ComputerName)"
            }
        }
        return $rulesEnabled
    }
    catch
    {
        Log-Info "Failed to enable SMB access on '$($session.ComputerName)'. Error: $($_.Exception)"
    }
}

function Disable-SmbAccess
{
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession,

        [Parameter(Mandatory = $false)]
        [string[]]$Rules = @('FPS-SMB-In-TCP','FailoverCluster-SMB-TCP-In')
    )
    try
    {
        foreach ($session in $PsSession)
        {
            foreach ($name in $Rules)
            {
                Log-Info "Disabling SMB access through firewall on $($session.ComputerName) for rule $name"
                Invoke-Command -Session $session -ScriptBlock {
                    param($RuleName)
                    if ((Get-NetFirewallRule -Name $RuleName).Enabled -eq 'True')
                    {
                        Set-NetFirewallRule -Name $RuleName -Enabled False | Out-Null
                    }
                } -ArgumentList $name
            }
        }
    }
    catch
    {
        Log-Info "Failed to disable SMB access on '$($session.ComputerName)'. Error: $($_.Exception)"
    }
}

function Remove-UtilityModule
{
    <#
    .SYNOPSIS
        Remove EnvironmentChecker module
    .DESCRIPTION
        Removes EnvironmentChecker module
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        foreach ($Session in $PsSession)
        {
            Log-Info "Removing module from $($Session.ComputerName)"
            Invoke-Command -Session $Session -ScriptBlock {
                Remove-Item -Path "$env:TEMP\AzStackHci.EnvironmentChecker.PortableUtilities.psm1" -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch
    {
        Log-Info "Failed to remove EnvironmentChecker module. Error: $($_.exception)"
    }
}

Export-ModuleMember -Function Copy-RemoteItem
Export-ModuleMember -Function Remove-UtilityModule
Export-ModuleMember -Function Test-Elevation
Export-ModuleMember -Function Get-SslCertificateChain
Export-ModuleMember -Function Enable-SmbAccess
Export-ModuleMember -Function Disable-SmbAccess
# SIG # Begin signature block
# MIIncAYJKoZIhvcNAQcCoIInYTCCJ10CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBp5MpomCjVHdCW
# NdakDjzBnVNYeLW7CYcgNelMtk0vEKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn9MIIZ+QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIH1c4kA2Z8+QkU0u+yIwj7AjIy9AptdkaT9IPeoi3HGZMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAnjRI/beHUPEiVbDhZ6fN
# +Qld94lzKDyyO81yCZJRCeWGYst0iQt9mC8GgDAWEod7qbw3w5vIfN4AAGMH4ARR
# C2GawKtVVoob9YjhFuC1d5/QWbmQEeCiEX1PEYbm8IRh7kXNFsbC7700hTphL9Wi
# NxUqLboCF2VzcsgY++JLUMM4p87B1OeEiuMiUmSdEizRSz0PEJ/KnAnj9AIMA8/o
# m129rei9WsZhlhcLtwJS/cYR5Vm0RNsAfswCSFF5QByJK2hgq2Ey8LZ7EtBFzEpV
# iHeryCdlYTB2V5yxOkW/2LKWQwh4WgOHI/QfQKU7aiiALw1X7hYOBki1Oxwz15Oq
# sKGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cGCSqGSIb3DQEHAqCCF4gwgheE
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0BCRABBKCCAUgEggFEMIIB
# QAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCa1R5RdozcR/skXzkQ
# yS1oDMflv8TxLMI4Eb95fjYJ9gIGaeugEigKGBIyMDI2MDUwMzE0MzExMC43N1ow
# BIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJBMUEtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR/jCCBygwggUQoAMC
# AQICEzMAAAIQq83kFhjvObAAAQAAAhAwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0MTg0ODEyWhcNMjYxMTEzMTg0
# ODEyWjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsG
# A1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYD
# VQQLEx5uU2hpZWxkIFRTUyBFU046MkExQS0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCNxzirTntnAiCkq7ilNdYt6O9gR25F/7WYiluIkQwVZaZTbGmK
# n7MrvEXEoYHUJyVRcFTT9lBnosbwfSAjvK+iyuw8QjUM8H9dxwYK+zApsApySeA6
# 4ZMQ8aTsr+8Rlr2HRe3TZvubaf0x0iOQusWXSkOuIrLPRAcal2H3dfr40Cl8TVMv
# bhWjTGR6gUakvetf2BeEg4Xn0QydN3ajjkVb+jEyBj2rTLSMY7QesItMJmvnR7tN
# lFI1gDLaXIpu8ojYwqU3XAvMm9lttz/8vezWrcnoqFLQoLZU0QiZh0WBWQl6PjNm
# od9JxNvH2GMWAWlWQmXjEflUny3Il1cT369TST0BpPZA/VmbdZCZd51KguOMjstb
# Oe4fCegYhcuIkxDM+oqpEgUvfDNysOtl5aC0B0E9uKmCVnkJCezoFqPkxvpr8RkL
# 0bd9olgrlBUd4Tp4uhITCnV3Pla6stc0+ynRVamWmX8UlvyOtFP+M6ge7zmpFx1i
# mAHJT1bshY92u2GbJ+p4DDSiZVY3knFyiBhsujakA0keWwx1afEik3ljAdsYQ8K6
# iwEc+TZd334T+lk9BRHq/4Pzl4Q3kD9kz/GI+nFrx0lnzsGlO+6Lv/a5+VQwl/Zh
# z1ks+AR2FBCjQvAwNJMNPjzLexXs92j6Dmr4yqcnO03/qq3VyBRN7277KQIDAQAB
# o4IBSTCCAUUwHQYDVR0OBBYEFJ7jb4Wul0XZq9tSGWTzoEtIfmR6MB8GA1UdIwQY
# MBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYB
# BQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWlj
# cm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB
# /wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0G
# CSqGSIb3DQEBCwUAA4ICAQC+zis7eijxzM6vE+qedISRRWrvXxDOWsiLLv8RbsmZ
# BewmgXEdZQXRTHQ8PIoUNFc8lW/b0XuSkmQEkmZxCDkdBXtuVRcgxZDWpfQp20VB
# cj8xEvvtn6krnHWNf61tGQDtrkW3u9a5GgASLTYekUfmb8CSH91+xvHzA6l5wlti
# +4e7LhobT+0bM5YULEww2EYAgnip1Xzsmdj+4wGaKh2Wb4bPfntdZbm2Dceu01le
# 5DS1ZS/bq53icYomj+gtkc/vmnhGm3t0x1gpQX0C5UUHDFhlim+CTXa18r7/I7Cr
# zj9+NdUJ0zzdCdrC1t6duT+Wdtz0qxmib4ae8DiK0AxSlJcVatxGSp1RAs34msbp
# 88GhXz4PxTZDYXheSIJHoRT0nNgrBO68vq3ecW7GeQt02NtODb/K/aPdZoO4IrmV
# I+Cyd0iIfoGS7ZSLcDRpSjoP3P2/5cS4Gz2KhUlo6N//P5SuqDsRKfEbT9PV0pyL
# u8tDZc2BYVg7786UOO0aiZrWKNfibXg32qCtdO5YQbCALuGEGCneJ38sA5/0FJNY
# DmUGuKWwSh7FcGs6f/XAzeuMbSEizG8Xn9g4rvyZVEZjpjvNgn65e3g5M4UHBp0+
# /wySWt5Bks+dA+2LCiniuUtRho8KIPhhSpE1sunxKDKj2DSIBxljOdO5z7xDxkiu
# DDCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM
# 57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm
# 95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzB
# RMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBb
# fowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCO
# Mcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYw
# XE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW
# /aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/w
# EPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
# Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2
# BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfH
# CBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYB
# BAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8v
# BO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEF
# BQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBW
# BgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
# AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# L2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518Jx
# Nj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+
# iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2
# pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefw
# C2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7
# T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFO
# Ry3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhL
# mm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3L
# wUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
# m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNZMIICQQIB
# ATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJBMUEtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoD
# FQA6zJ/ZvquI8qedeUiAgvZ/nc9SwqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFSuDAiGA8yMDI2MDUwMzA0
# NTEwNFoYDzIwMjYwNTA0MDQ1MTA0WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDt
# oVK4AgEAMAoCAQACAg/bAgH/MAcCAQACAhPLMAoCBQDtoqQ4AgEAMDYGCisGAQQB
# hFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAw
# DQYJKoZIhvcNAQELBQADggEBALwEP+Ns76FgjVwvCKAsuri+H4rM2JJI82timMrz
# USaRjJmzlpfkAxECcrNms/jOw0WS+ICMCNwNxHrYwWi6fMwox0lbkv8CT8tfBe0z
# fgN8MlBx1kgDjZqm7sbG6ziAHLiXp1TYs36PiW0I8JEmF0w97FJJ/45BvHyQ7TUl
# 7f4NaF2Cf2l26OEiPyJ9KV22GVe00tK0H19YWWXxPO8nHrCvwooy69xq7gNFuelv
# xUUgOklg0MTBMCGX1pMZwpJO0+U0rQ5cLnoCCbDIxsNzLXSAyUpueqVf7+ATY1pb
# vjJ9hp0Untg+V7JlHPnupOzXfuSkv05l3dP23JvaCo3NGPQxggQNMIIECQIBATCB
# kzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAhCrzeQWGO85sAAB
# AAACEDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJ
# EAEEMC8GCSqGSIb3DQEJBDEiBCBvd7gvHW34UAtaP7ua8dKFjkEX6nPKmSusQ6/M
# GyMB9zCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMPVIe5+yPNjn1LWIdRB
# j2GewpKsk+Dlr0xzhicaY8fGMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAIQq83kFhjvObAAAQAAAhAwIgQghPvQ0X9o5MFGcv9ibl0I
# kjkvl+GIalLbHNMCjRfJoE8wDQYJKoZIhvcNAQELBQAEggIAVqTzxvgsRkaGarD5
# c2CX5qI5CWCQxUV8rQkzyAo/85Tenb563Yu6SXfGGZI+mYt2h7BuW2AJ1tyP3I+d
# XvBwMaNdTCUNhxl/MhtySl2RtkyOkMnxch7du1Mvc62rUoN1EhARojU+KXziFLTm
# uQ2g/k4MJTALkMEoLZr5rMkh4gpUvUQjwkrsGVybt9ZE4jq5gAvhKuwuV7dVycLn
# OBJZgVZRW69u9ilCU5EWubuSHuBuIWtEXlifWFlPh3A1qQLd1GlwpJHigC+AqOt+
# k81D/YylL1pYmRvfPWUatfn8HEZMer4GF2tZSJe39/sXxbCJuGNgP5/XKtNGGAv7
# A78sZ8naTfPrO5OEqu9yiOL6u4CVDnZEvm8Mc1hPIynroYIs0nXoQCyL/QKeqjcp
# pBKywF6qwdIbHun1pFVscC6w8IHDWwKM4140WhPPTD3s1IW/QSplbNwiW8XYKBIT
# oCyBZMCU19YBEcbs5EZ3a32qIapfVxBXnRAIUiGKECQy7p2RQcRUtb8niIcDTz4n
# 4caftfgJpZtOkUXdRzooIQBVluMpdfqNhKdi0z1HZk+ujsdxw4Xl31DdOdMoW1r3
# CAjjX+M4HUcWhBMZrOt2/kfTiYhrSjFMHy3N+9SpWwhDVR3yyDV8bxhAbiQoFAKO
# B5rgdpB3gqFofziC86ZCcNCEB64=
# SIG # End signature block
