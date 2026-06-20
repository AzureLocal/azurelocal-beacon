Import-LocalizedData -BindingVariable lSTxt -FileName AzStackHci.Security.Strings.psd1

# This file contains a list of discreet tests that can be run against the environment
# Each test named Test-* is exported and discovered to be run by the user-facing function.
# The user uses Include and Exclude parameters to run specific tests. (this provides a consistent experience across validators)
# If tests have dependencies on other tests, or they should be run in a specific order, the pattern describe above should be removed.
function Test-AsrRuleConfiguration
{
    <#
    .SYNOPSIS
        Validates ASR rule configuration for CAU compatibility
    .DESCRIPTION
        Checks Windows Defender Attack Surface Reduction rule 'Block process creations originating from PSExec and WMI commands'
        to determine if it will interfere with Cluster-Aware Updating operations. Returns informational results with
        remediation guidance when blocking or interference is detected.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $Severity = 'INFORMATIONAL'
        $instanceResults = @()

        # Execute ASR rule validation on remote systems to check for CAU compatibility
        # Returns detailed information about ASR rule configuration and impact on cluster operations
        $scriptBlock = {
            try
            {
                # Try to import ConfigDefender module if available (don't fail if not present)
                if (Get-Module -ListAvailable -Name ConfigDefender -ErrorAction SilentlyContinue) {
                    Import-Module ConfigDefender -Verbose:$false -ErrorAction SilentlyContinue
                }

                # Check ASR rule configuration using Get-MpPreference
                $mpPref = Get-MpPreference -ErrorAction SilentlyContinue
                $ruleIds = $mpPref.AttackSurfaceReductionRules_Ids
                $ruleActions = $mpPref.AttackSurfaceReductionRules_Actions

                $asrRuleFound = $false
                $asrAction = $null
                $asrActionText = "Not Configured"
                $warningMessage = ""

                if ($ruleIds) {
                    # Check for PSExec/WMI process creation blocking rule
                    $index = [array]::IndexOf($ruleIds, "d1e49aac-8f56-4280-b9ba-993a6d77406c")
                    if ($index -ge 0) {
                        $asrRuleFound = $true
                        $asrAction = $ruleActions[$index]
                        $asrActionText = switch ($asrAction) {
                            0 { "Disabled" }
                            1 { "Block" }
                            2 { "Audit" }
                            6 { "Warn" }
                            default { "Unknown ($asrAction)" }
                        }

                        # Generate descriptive warning messages based on ASR rule configuration
                        switch ($asrAction) {
                            1 { # Block mode
                                $warningMessage = "ASR rule 'Block process creations originating from PSExec and WMI commands' is set to BLOCK mode. This WILL prevent Cluster-Aware Updating (CAU) from functioning properly as CAU relies on PSExec and WMI for remote operations. Consider setting this rule to Audit mode or adding CAU-specific exclusions before running updates."
                            }
                            6 { # Warn mode
                                $warningMessage = "ASR rule 'Block process creations originating from PSExec and WMI commands' is set to WARN mode. This may interfere with Cluster-Aware Updating (CAU) operations by prompting users during automated update processes. Monitor CAU operations closely or consider Audit mode for automated environments."
                            }
                            2 { # Audit mode
                                $warningMessage = "ASR rule 'Block process creations originating from PSExec and WMI commands' is set to AUDIT mode. This is the recommended setting for environments using Cluster-Aware Updating (CAU) as it provides security monitoring without blocking legitimate CAU operations."
                            }
                            0 { # Disabled
                                $warningMessage = "ASR rule 'Block process creations originating from PSExec and WMI commands' is DISABLED."
                            }
                            default {
                                $warningMessage = "ASR rule 'Block process creations originating from PSExec and WMI commands' has an unknown configuration ($asrAction). Please verify the rule configuration manually."
                            }
                        }
                    } else {
                        $warningMessage = "ASR rule 'Block process creations originating from PSExec and WMI commands' is not configured."
                    }
                } else {
                    $warningMessage = "No Attack Surface Reduction (ASR) rules are configured on this system."
                }

                # Determine the overall result based on ASR rule status
                $result = if ($asrRuleFound -and $asrAction -eq 1) {
                    "BlockingCAU"  # ASR rule will block CAU operations
                } elseif ($asrRuleFound -and $asrAction -eq 6) {
                    "MayInterferWithCAU"  # ASR rule may interfere with CAU
                } elseif ($asrRuleFound -and $asrAction -eq 2) {
                    "OptimalForCAU"  # ASR rule is in audit mode - good for CAU
                } elseif ($asrRuleFound -and $asrAction -eq 0) {
                    "ASRDisabled"  # ASR rule is disabled
                } elseif (-not $asrRuleFound -and $ruleIds) {
                    "ASRRuleNotConfigured"  # Other ASR rules exist but not the one we care about
                } else {
                    "NoASRRules"  # No ASR rules configured at all
                }

                return (New-Object psobject -Property @{
                    ComputerName = $env:COMPUTERNAME
                    Result = $result
                    ASRRuleFound = $asrRuleFound
                    ASRAction = $asrAction
                    ASRActionText = $asrActionText
                    WarningMessage = $warningMessage
                    HasASRRules = ($null -ne $ruleIds -and $ruleIds.Count -gt 0)
                })
            }
            catch
            {
                return (New-Object psobject -Property @{
                    ComputerName = $env:COMPUTERNAME
                    Result = "Warning"
                    ASRRuleFound = $false
                    ASRAction = $null
                    ASRActionText = "Warning"
                    WarningMessage = "Failed to check ASR rule configuration: $($_.Exception.Message)"
                    HasASRRules = $false
                    Error = $_.Exception.Message
                })
            }
        }

        # run against remote system(s)
        $remoteOutput = Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock

        # parse remote output(s) and create result objects
        foreach ($remoteOutputItem in $remoteOutput) {
            # Use the WarningMessage from the ASR check for detailed feedback
            $detail = $remoteOutputItem.WarningMessage
            # Set remediation link only when blocking is occurring
            $remediation = $null
            # Determine status and severity based on ASR rule configuration impact on CAU
            switch ($remoteOutputItem.Result) {
                "BlockingCAU" {
                    $status = 'FAILURE'
                    $Severity = 'INFORMATIONAL'  # This will block CAU operations
                    $remediation = 'https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/Update/Solution-Update-CAU-Run-fails-due-to-Windows-Defender-blocking-WMI-commands.md'
                    Log-Info $detail
                }
                "MayInterferWithCAU" {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'   # This may cause issues but won't completely block
                    $remediation = 'https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/Update/Solution-Update-CAU-Run-fails-due-to-Windows-Defender-blocking-WMI-commands.md'
                    Log-Info $detail
                }
                "OptimalForCAU" {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'  # This is the recommended configuration
                    Log-Info $detail
                }
                "ASRDisabled" {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'   # Security feature is disabled - inform but don't block
                    Log-Info $detail
                }
                "ASRRuleNotConfigured" {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'  # Specific rule not configured but CAU should work
                    Log-Info $detail
                }
                "NoASRRules" {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'  # No ASR rules means no interference
                    Log-Info $detail
                }
                "Error" {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'   # Error checking but don't block operations
                    Log-Info $detail
                }
                default {
                    $status = 'SUCCESS'
                    $Severity = 'INFORMATIONAL'   # Unknown result - cautionary approach
                    Log-Info "Unknown ASR rule result: $($remoteOutputItem.Result)"
                }
            }

            $params = @{
                Name               = 'AzStackHci_Security_AsrRuleConfiguration'
                Title              = 'Attack Surface Reduction Rule Configuration'
                DisplayName        = 'Checking Defender Rule Blocking PSExec and WMI Commands'
                Severity           = $Severity
                Description        = 'Validates ASR rule configuration for compatibility with Cluster-Aware Updating (CAU)'
                Tags               = @{
                    ASRRuleFound = $remoteOutputItem.ASRRuleFound
                    ASRAction = $remoteOutputItem.ASRAction
                    ASRActionText = $remoteOutputItem.ASRActionText
                    HasASRRules = $remoteOutputItem.HasASRRules
                    TestResult = $remoteOutputItem.Result
                }
                Remediation        = $remediation
                TargetResourceID   = $remoteOutputItem.ComputerName
                TargetResourceName = $remoteOutputItem.ComputerName
                TargetResourceType = 'SecurityConfiguration'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                        Source    = $remoteOutputItem.ComputerName
                        Resource  = 'ASR Rule - Block process of defender creations originating from PSExec and WMI commands'
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return $instanceResults
    }
    catch
    {
        throw
    }
}

function Test-SecureBootUpdateStatus
{
    <#
    .SYNOPSIS
        Validates Secure Boot update status
    .DESCRIPTION
        Checks the status of Secure Boot updates to determine if the system is using the latest boot manager and UEFI certificates.
        Returns informational results.
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

        $scriptBlock = {
            $secureBootLastStateRegPath = 'HKLM:\SOFTWARE\Microsoft\AzureStack\SecureBoot'
            $secureBootBootMgrUpdatedTimeValueName = 'BootMgrUpdatedTimeUtc'

            $bootManagerStatus = "Unknown"
            $windowsUEFICAInstalled = "Unknown"
            $microsoftUEFICAInstalled = "Unknown"
            $microsoftOptionROMUEFICAInstalled = "Unknown"
            $kekInstalled = "Unknown"
            $errorMessage = $null
            try
            {
                function Test-BIOSCertInstalled
                {
                    param(
                        [string]$Database,
                        [string]$CertName
                    )

                    $uefiVar = Get-SecureBootUEFI $Database -ErrorAction Stop
                    $ascii = [System.Text.Encoding]::ASCII.GetString($uefiVar.bytes)
                    return $ascii -match [regex]::Escape($CertName)
                }

                function Test-SecureBootWindowsUEFICAInstalled
                {
                    return Test-BIOSCertInstalled -Database 'db' -CertName 'Windows UEFI CA 2023'
                }

                function Test-SecureBootMicrosoftUEFICAInstalled
                {
                    return Test-BIOSCertInstalled -Database 'db' -CertName 'Microsoft UEFI CA 2023'
                }

                function Test-SecureBootMicrosoftOptionROMUEFICAInstalled
                {
                    return Test-BIOSCertInstalled -Database 'db' -CertName 'Microsoft Option ROM UEFI CA 2023'
                }

                function Test-SecureBootKEKInstalled
                {
                    return Test-BIOSCertInstalled -Database 'kek' -CertName 'Microsoft Corporation KEK 2K CA 2023'
                }

                function Test-SecureBootEFISignerUpdated
                {
                    try
                    {
                        $driveLetterInUse = [System.IO.DriveInfo]::GetDrives() |
                            ForEach-Object { $_.Name[0].ToString().ToUpperInvariant() }
                        $driveLetter = $null
                        foreach ($currentChar in [byte][char]'H'..[byte][char]'Z')
                        {
                            $candidateDriveLetter = ([char]$currentChar).ToString()
                            if ($driveLetterInUse -notcontains $candidateDriveLetter)
                            {
                                $driveLetter = $candidateDriveLetter
                                break
                            }
                        }
                        if ($null -eq $driveLetter)
                        {
                            throw "No available drive letter found"
                        }

                        $efiPath = "$driveLetter`:\EFI\Microsoft\Boot\bootmgfw.efi"
                        mountvol $driveLetter`: /s
                        if (-not (Test-Path $efiPath))
                        {
                            throw "Boot EFI file not found at '$efiPath'."
                        }

                        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($efiPath)
                        $signerCertificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $certificate
                        if ($null -eq $signerCertificate)
                        {
                            throw 'Boot EFI file has no signer certificate.'
                        }
                        $issuer  = $signerCertificate.Issuer
                        $efiSignerUpdated = $issuer -match "Windows UEFI CA 2023"
                        return $efiSignerUpdated
                    }
                    finally
                    {
                        if ($null -ne $driveLetter) {
                            mountvol $driveLetter`: /D 2>$null
                        }
                    }
                }

                function Get-SecureBootBootMgrUpdatedTime
                {
                    [CmdletBinding()]
                    param()

                    $val = Get-ItemProperty -Path $secureBootLastStateRegPath -Name $secureBootBootMgrUpdatedTimeValueName -ErrorAction SilentlyContinue
                    $timestamp = if ($null -ne $val) { [string]$val.$($secureBootBootMgrUpdatedTimeValueName) } else { $null }
                    if ([string]::IsNullOrWhiteSpace($timestamp))
                    {
                        return $null
                    }
                    return [DateTime]::Parse($timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                }

                function Set-SecureBootBootMgrUpdatedTime
                {
                    [CmdletBinding()]
                    param()

                    if (-not (Test-Path $secureBootLastStateRegPath))
                    {
                        New-Item -Path $secureBootLastStateRegPath -Force | Out-Null
                    }

                    $existingTimestamp = Get-SecureBootBootMgrUpdatedTime
                    # Always store the first timestamp. If there is already a record, we return with no-op.
                    if ($null -ne $existingTimestamp)
                    {
                        return
                    }

                    $timestampUtc = [DateTime]::UtcNow.ToString('o')
                    Set-ItemProperty -Path $secureBootLastStateRegPath -Name $secureBootBootMgrUpdatedTimeValueName -Value $timestampUtc -Type String
                }

                $windowsUEFICAInstalled = [string](Test-SecureBootWindowsUEFICAInstalled)
                $microsoftUEFICAInstalled = [string](Test-SecureBootMicrosoftUEFICAInstalled)
                $microsoftOptionROMUEFICAInstalled = [string](Test-SecureBootMicrosoftOptionROMUEFICAInstalled)
                $kekInstalled = [string](Test-SecureBootKEKInstalled)
                $bootMgrUpdated = (Test-SecureBootEFISignerUpdated)
                if ($bootMgrUpdated)
                {
                    $bootEFIUpdatedTimeInRecord = Get-SecureBootBootMgrUpdatedTime
                    if ($null -eq $bootEFIUpdatedTimeInRecord)
                    {
                        Set-SecureBootBootMgrUpdatedTime
                        $bootEFIUpdatedTimeInRecord = [DateTime]::UtcNow
                    }
                    $lastBootUpTime = ([DateTime](Get-CimInstance Win32_OperatingSystem).LastBootUpTime)
                    if ($bootEFIUpdatedTimeInRecord -lt $lastBootUpTime)
                    {
                        $bootManagerStatus = "BootManagerUpdatedAndInUse"
                    }
                    else
                    {
                        $bootManagerStatus = "BootManagerUpdatedButUnableToDetermineInUseStatus"
                    }
                }
                else
                {
                    $bootManagerStatus = "BootManagerNotUpdated"
                }

                return (New-Object psobject -Property @{
                    ComputerName = $env:COMPUTERNAME
                    Status = "Success"
                    BootManagerStatus = $bootManagerStatus
                    WindowsUEFICAInstalled = $windowsUEFICAInstalled
                    MicrosoftUEFICAInstalled = $microsoftUEFICAInstalled
                    MicrosoftOptionROMUEFICAInstalled = $microsoftOptionROMUEFICAInstalled
                    KEKInstalled = $kekInstalled
                })
            }
            catch
            { 
                $errorMessage = $_.ToString()
                return (New-Object psobject -Property @{
                    ComputerName = $env:COMPUTERNAME
                    Status = "SUCCESS"  # Don't fail the check as all agreed for 2604
                    ErrorMessage = $errorMessage
                    BootManagerStatus = $bootManagerStatus
                    WindowsUEFICAInstalled = $windowsUEFICAInstalled
                    MicrosoftUEFICAInstalled = $microsoftUEFICAInstalled
                    MicrosoftOptionROMUEFICAInstalled = $microsoftOptionROMUEFICAInstalled
                    KEKInstalled = $kekInstalled
                })
            }
        }

        # run against remote system(s)
        $remoteOutput = Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock

        # parse remote output(s) and create result objects
        foreach ($remoteOutputItem in $remoteOutput)
        {
            $severity = 'INFORMATIONAL'
            $detail = $lSTxt.SecureBootUpdateStatus -f $remoteOutputItem.BootManagerStatus, $remoteOutputItem.WindowsUEFICAInstalled, $remoteOutputItem.MicrosoftUEFICAInstalled, $remoteOutputItem.MicrosoftOptionROMUEFICAInstalled, $remoteOutputItem.KEKInstalled
            if ($remoteOutputItem.ErrorMessage)
            {
                $detail += " An error occurred while checking Secure Boot status: $($remoteOutputItem.ErrorMessage)"
            }
            $status = $remoteOutputItem.Status
            $params = @{
                Name               = 'AzStackHci_Security_SecureBootStatus'
                Title              = 'Secure Boot Status'
                DisplayName        = 'Checking Secure Boot Update result'
                Severity           = $severity
                Description        = 'Validates Secure Boot Update result'
                Tags               = @{
                    BootManagerStatus = $remoteOutputItem.BootManagerStatus
                    WindowsUEFICAInstalled = $remoteOutputItem.WindowsUEFICAInstalled
                    MicrosoftUEFICAInstalled = $remoteOutputItem.MicrosoftUEFICAInstalled
                    MicrosoftOptionROMUEFICAInstalled = $remoteOutputItem.MicrosoftOptionROMUEFICAInstalled
                    KEKInstalled = $remoteOutputItem.KEKInstalled
                    ErrorMessage = if ($remoteOutputItem.ErrorMessage) { $remoteOutputItem.ErrorMessage } else { $null }
                }
                Remediation        = $null
                TargetResourceID   = $remoteOutputItem.ComputerName
                TargetResourceName = $remoteOutputItem.ComputerName
                TargetResourceType = 'SecureBootConfiguration'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                        Source    = $remoteOutputItem.ComputerName
                        Resource  = 'Secure Boot Update'
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                    }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return $instanceResults
    }
    catch
    {
        throw
    }
}

function Test-AsrRuleGPConflict
{
    <#
    .SYNOPSIS
        Validates ASR rule configuration is also managed by Group Policy
    .DESCRIPTION
        Checks if Windows Defender Attack Surface Reduction rule is also managed by Group Policy
        to determine if it will interfere with OSConfig DefenderAV document. Returns informational results with
        remediation guidance when interference is detected.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.Management.Automation.Runspaces.PSSession[]]
        $PsSession
    )
    try
    {
        $Severity = 'INFORMATIONAL'
        $instanceResults = @()

        # Execute ASR rule validation on remote systems to check for Group Policy conflicts
        # Returns detailed information about GP configuration and impact on OSConfig management of Defender settings
        $scriptBlock = {
            $rsopQuerySucceeded = $false
            try
            {
                $asrRuleEntries = @()

                $asrRuleCatalog = [ordered]@{
                    '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'ASRBlockAbuseOfExploitedVulnerableSignedDrivers'
                    '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'ASRBlockAdobeReaderFromCreatingChildProcesses'
                    'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'ASRBlockEXEFromEmailClientAndWebmail'
                    '01443614-cd74-433a-b99e-2ecdc07bfc25' = 'ASRBlockEXEFromRunningUnlessTrusted'
                    'd3e037e1-3eb8-44c8-a917-57927947596d' = 'ASRBlockJSVBSLaunchingDownloadedContent'
                    '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'ASRBlockLSASSCredentialStealing'
                    'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'ASRBlockOfficeApplicationsFromCreatingChildProcesses'
                    '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'ASRBlockOfficeCommunicationApplicationFromCreatingChildProcesses'
                    '3b576869-a4ec-4529-8536-b80a7769e899' = 'ASRBlockOfficeFromCreatingExecutableContent'
                    '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'ASRBlockOfficeFromInjectingCodeIntoProcesses'
                    'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'ASRBlockPersistenceThroughWMIEventSubscription'
                    '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'ASRBlockPotentiallyObfuscatedScripts'
                    'd1e49aac-8f56-4280-b9ba-993a6d77406c' = 'ASRBlockProcessCreationFromPSExecAndWMICommands'
                    '33ddedf1-c6e0-47cb-833e-de6133960387' = 'ASRBlockRebootingMachineInSafeMode'
                    'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'ASRBlockUntrustedAndUnsignedProcessesRunningFromUSB'
                    'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' = 'ASRBlockUseOfCopiedOrImpersonatedSystemTools'
                    'a8f5898e-1dc8-49a9-9878-85004b8a61e6' = 'ASRBlockWebshellCreationForServers'
                    '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'ASRBlockWIN32APIFromOfficeMacros'
                    'c1db55ab-c21a-4637-bb3f-a12568109d35' = 'ASRUseAdvancedProtectionAgainstRansomware'
                }

                # Build RSOP evidence map by querying each ASR UUID directly.
                # Pattern: Get-CimInstance ... -Filter "ValueName = '<uuid>'"
                $rsopEvidenceByGuid = @{}
                $expectedRsopRegistryKey = 'Software\\Policies\\Microsoft\\Windows Defender\\Windows Defender Exploit Guard\\ASR\\Rules'
                try
                {
                    $rsopClass = Get-CimClass -Namespace 'root\rsop\computer' -ClassName 'RSOP_RegistryPolicySetting' -ErrorAction SilentlyContinue
                    if ($null -ne $rsopClass) {
                        foreach ($catalogItem in $asrRuleCatalog.GetEnumerator()) {
                            $guid = [string]$catalogItem.Key
                            $filterGuid = $guid.Replace("'", "''")
                            $rsopMatch = Get-CimInstance -Namespace 'root\rsop\computer' -ClassName 'RSOP_RegistryPolicySetting' -Filter "ValueName = '$filterGuid' AND RegistryKey = '$expectedRsopRegistryKey'" -ErrorAction SilentlyContinue

                            $matchingItems = @($rsopMatch | Where-Object {
                                -not [string]::IsNullOrWhiteSpace($_.valueName) -and
                                $_.valueName -ieq $guid
                            })

                            $rsopEvidenceByGuid[$guid.ToLowerInvariant()] = [pscustomobject]@{
                                Exists = ($matchingItems.Count -gt 0)
                                SomIds = @($matchingItems | ForEach-Object { [string]$_.SOMID } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
                            }
                        }

                        $rsopQuerySucceeded = $true
                    }
                }
                catch
                {
                    throw "Failed to query RSOP data for ASR rules: $($_.Exception.Message)"
                }

                foreach ($catalogItem in $asrRuleCatalog.GetEnumerator()) {
                    $guid = [string]$catalogItem.Key
                    $ruleName = [string]$catalogItem.Value
                    $normalizedGuidName = $guid.ToLowerInvariant()
                    if (-not $rsopEvidenceByGuid.ContainsKey($normalizedGuidName)) {
                        continue
                    }

                    $rsopEvidence = $rsopEvidenceByGuid[$normalizedGuidName]
                    if (-not [bool]$rsopEvidence.Exists) {
                        continue
                    }

                    $asrRuleEntries += [pscustomobject]@{
                        Name       = $guid
                        RuleName   = $ruleName
                        RSOPSomIds = $rsopEvidence.SomIds
                    }
                }

                $result = if ($asrRuleEntries.Count -gt 0) {
                    'ASRGroupPolicyFound'
                }
                else {
                    'ASRGroupPolicyNotFound'
                }

                return (New-Object psobject -Property @{
                    ComputerName       = $env:COMPUTERNAME
                    Result             = $result
                    ASRPolicyRules     = $asrRuleEntries
                    RSOPQuerySucceeded = $rsopQuerySucceeded
                })
            }
            catch
            {
                return (New-Object psobject -Property @{
                    ComputerName       = $env:COMPUTERNAME
                    Result             = 'Error'
                    ASRPolicyRules     = @()
                    RSOPQuerySucceeded = $rsopQuerySucceeded
                    Error              = $_.ToString()
                })
            }
        }

        # run against remote system(s)
        $remoteOutput = Invoke-Command -Session $PsSession -ScriptBlock $scriptBlock

        # parse remote output(s) and create result objects
        foreach ($remoteOutputItem in $remoteOutput) {
            # Set remediation only when ASR settings are Group Policy-managed
            $remediation = $null
            # Determine status, severity, and detail from Result.
            switch ($remoteOutputItem.Result) {
                "ASRGroupPolicyFound" {
                    $status = 'SUCCESS'
                    $Severity = 'WARNING'
                    $remediation = $lSTxt.ASRGroupPolicyRemediation
                    $ruleDescriptions = @($remoteOutputItem.ASRPolicyRules | ForEach-Object {
                        "$($_.RuleName) ($($_.Name)) Scope(s)=$(@(@($_.RSOPSomIds) | ForEach-Object { '[{0}]' -f $_ }) -join ',')"
                    })
                    $detail = $lSTxt.ASRGroupPolicyFound -f $($ruleDescriptions -join '; ')
                }
                "ASRGroupPolicyNotFound" {
                    $status = 'SUCCESS'
                    $detail = $lSTxt.ASRGroupPolicyNotFound
                }
                "Error" {
                    $status = 'SUCCESS'
                    $Severity = 'WARNING'
                    $detail = $lSTxt.ASRGroupPolicyError -f $remoteOutputItem.Error
                }
                default {
                    $status = 'SUCCESS'
                    $Severity = 'WARNING'
                    $detail = $lSTxt.ASRGroupPolicyUnknownResult -f $remoteOutputItem.Result
                }
            }

            if (($remoteOutputItem.Result -ne 'Error' -or [string]::IsNullOrWhiteSpace($remoteOutputItem.Error)) -and
                $null -ne $remoteOutputItem.RSOPQuerySucceeded -and
                -not [bool]$remoteOutputItem.RSOPQuerySucceeded) {
                $detail = $lSTxt.ASRGroupPolicyRSOPFailed -f $detail
            }

            Log-Info $detail

            $params = @{
                Name               = 'AzStackHci_Security_AsrRuleGPConflict'
                Title              = 'Attack Surface Reduction Group Policy Conflict'
                DisplayName        = 'Checking Group Policy for Defender ASR rule management'
                Severity           = $Severity
                Description        = 'Validates Group Policy ASR settings for conflict with OSConfig DefenderAV management'
                Tags               = @{
                    RSOPQuerySucceeded = $remoteOutputItem.RSOPQuerySucceeded
                    TestResult = $remoteOutputItem.Result
                }
                Remediation        = $remediation
                TargetResourceID   = $remoteOutputItem.ComputerName
                TargetResourceName = $remoteOutputItem.ComputerName
                TargetResourceType = 'WindowsDefenderGroupPolicyConfiguration'
                Timestamp          = [datetime]::UtcNow
                Status             = $status
                AdditionalData     = @{
                        Source    = $remoteOutputItem.ComputerName
                        Resource  = 'ASR Group Policy Settings'
                        Detail    = $detail
                        Status    = $status
                        TimeStamp = [datetime]::UtcNow
                        Rules     = @($remoteOutputItem.ASRPolicyRules | ForEach-Object { $_.RuleName }) -join '; '
                        RSOPQuerySucceeded = $remoteOutputItem.RSOPQuerySucceeded
                    }
                HealthCheckSource  = $ENV:EnvChkrId
            }
            $instanceResults += New-AzStackHciResultObject @params
        }
        return $instanceResults
    }
    catch
    {
        throw
    }
}

Export-ModuleMember -Function Test-*
# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCv7Uf0OuTHB/w4
# b8Vn0ALUqJ5zvV7DhPCtYGfaoydcFaCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# hvcNAQkEMSIEIGy9uamiTXddAi48gBNdmA3Bm8dCi7qJGku5dp6KYGgyMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAiiNx0LXrBjLIpSHkHLtY
# J9VHsM5kG+JX+0g7/haFkhZrtlwX1+0yoPsuvBvuaDrQTlTCHTqTMpfBd2RpsOPX
# 6btPFejesqqYXq+JjAMaprSzvs67pQCoyALpi9XSWoG0THjdT3+rfGRBL+ZEMLxd
# X0ElvoxyZQVjvdNiHBqcujEq7W8+JAKDxUYszj6qZTD6je0MRGSwct4znASU2Z/C
# prd6YekToKy7eiAlkcjB5WMhM1cFs6mehMv/ztAvEuXQ62gFrZmvJH5KP16izYQ0
# PAvZOnYnH10ZqjZjWwvVHXaB9BFLdW8eQdHs9A3kRd5wmE7yqzY46yWhDL0x+I2D
# pqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBddssJ0U9ArflKmFsQ
# GxjCh954xCObuatyiNGT+Dc9TgIGaexb5ppTGBMyMDI2MDUwMzE0MzExMS41MjNa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1NTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACG9CyuAJn93LPAAEAAAIbMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgzMFoXDTI2MTExMzE4
# NDgzMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAjsWd52ZZkzB5Xe5g/l2GsOjAz30sg6jVxfFJV+w4xIDVyaI3
# LO8bIpmzYul3AZHg50UIQ8PrSRZGpQqFkRNu+o3YKJ4g2uGYBRksHnHYR0uVSCQg
# 58ThkYyeplGX3oAvGRVuPIpQtAiTsR76A/gdoU7HDwEbb73bJwTyrbKHhR+WaMy9
# DQHI4k5Qo4+bZDs0kj76bvhJvdGU+S8zxQBp7UAhjJnFqKxIusSITE7zCCR422EL
# hkhVVOFqK2w6h1MAvILe76hxRIcPj0SBL2r8O9tx5njU4+tg2rAdU153pmyhqazd
# pUccYBE9wDRFUd/e9CoWx7TdnUicB+Mai7RT6qse7e5aGqX1B7bnj/ZHvrrfF+BJ
# EIlS9iDXAUgekvXZ+FZmjvLwP+dN+0/crh++r4e8FknF7EX6IJfnmNeDN/68Z59k
# baJ1f+P5mnKYfydCeZmxrGpS0taWkDk36D3jPVZflvxrc+1rhCIlM5v9agLEFI12
# QiBTfpOBOBr3AGCPk+eH0+latjQajug+2/BD12qb82500LQytUWT2ota/HYnRgSv
# 1jvZ0/dml1FsxWYzOnCrjfdB/7N6pNySt4vn+PGN6dFLim7kxos+B9WfQPezJi3f
# uKyyDAB9zSHPj1Zu8nZfecZJ9um4zj7DFgvJXTDTnG5qlG4ZdbFRa/rrfzkCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBS2vp93/lxLppNK8OkauJ2AvNmIUDAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAZkU1XxQD4OTM3GTht32TXShIfPBoMfSsFsBQqFOZ
# qLJOxyJOllIBFpmpvOtGNPkC5Z8ldG8aCpvgFNo/jDWeT5FiW53dAj9KnZxpsQ3P
# f5fRzSGHRcxEMOdXIVzDJwcZUX0cjfxna7ydNv8eXB/Xk6G6SyrR2OH6S1LHMW11
# m3UvKF+eLjIPl45rximuDCoEd+ad0lOAXA5/vZOKN5n/ePYeP0LRchZX0Q6H8n/Z
# mSPMlbli3MO851Q09RmT/ZGHa+/Fdy+WLDrwcYykV9mUy/4TbwKw6FtdR6ZPHxMd
# Ii1pk8Y2mC/GzCq0LCsH0uTFeQ6Q7Nc3MRmER/3mLWUhbaWHgX1FbYchvR22b+Bu
# p+YPR5Q/0BhaaAN6AIBfcGs+u/nJoIByyZKA8cTyCmnUI/4vW6D4vywg3XBFf4f2
# DwFHy/evsC+58KMl+k2wa05X2kK0T/bCPLhaov9ZXyobawfNOLYGiauKT2FWvbwZ
# zHIFCTxjBww6Pt5uRvCE/jnUcf/xhlOGMn6iKO9Xt49vZTE2SfIBk/34iLTRBJ6H
# 7aGPTTQnza3OfWu1/dRycC6Wl5ons3PjnGXTSKSxXllJPmg6R/ulGonP/UCYoJ6m
# N+EXjfyDLPXLqsr91+VTG1rYzRCjPwBFAHv4EIwaE0ajCrf75eUGI3+oXU0UP6rl
# oZ8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
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
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1NTFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAhoV6r49M4GBd41K1RYB1Z0f4zuCggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2hZdYwIhgPMjAyNjA1MDMw
# NjEyMzhaGA8yMDI2MDUwNDA2MTIzOFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7aFl1gIBADAKAgEAAgIC9QIB/zAHAgEAAgITcDAKAgUA7aK3VgIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQBpGDLGwYrAfNhvL99FCFQaRCmKaEmKZDKCk4JB
# pCQ/pNVTICCdL454QZMWkMmLSa8kqRGYuR1wU34gxN9VwN6lty97Jywq64qPVtyl
# DEStzXpw8m+hJdfCd28tldZ5p2f5mRAg2gGCiCP3DVTntzzxXS6xTgObRauYoe9x
# NjMosx99h2SY1tgYK4AF99I7UEa7ajESdGk8S5GNNyovCiGrWuTRbI2hCryrMWwx
# ZUQd7LABMgLS9f0oVyrhC5/dD6LXFXuzvro5koI9oT+RRjEpE2RO0cIJRSwKEXty
# CKMBhG51Xl26QU7lOfir3B4VrlnDpvmSi48H+z8JAfIKxbAbMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIb0LK4Amf3cs8A
# AQAAAhswDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgZNFUrorHm+BwTQA3bj3v+Fzrb2z5PrHIlmmm
# rzICSiMwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCAwJRSVuD2jmMcQCFXd
# LuJAwDpUVNZ6bc6dfJU83Q2LgDCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACG9CyuAJn93LPAAEAAAIbMCIEIJpLJJrTCio60NOS1ov3
# dtjNylJ+5DkTKi/rzm6gsIMQMA0GCSqGSIb3DQEBCwUABIICAAPqY1XkzJcCcZak
# 1Bt/oTZutGSBp0jg4YWX7t3L+5ADxEvfWpRLYCPCRNk7gf6FRFtN5xXlbyGFzzO8
# 0KlAqAqE6Hpg/mdy0HPBt8RGUF9ZmfCVn2luBxzc+8GHguSJNyojnfZYIPgUvmZU
# xYRtp074KsxXjMfFYTuyKv8KUs6pQbnsV+r8SkcpyY7+Nvekb/COlf4lgeJfTvdI
# tdjYvcPVNWqUYElmoHdZHsF28JmXGSArBT0x2FS4Q7u5vd2X4osDq3cNRxaZhDfR
# mluq9ZEo2nnTIfxWEtB1A9McFiHjhkI5F3WU89JvHYdxIhwdc7b8sAKiqDjC3UfU
# zSYYm/ySlVbvPTkXM6uIT4Sdd6HvFEwmu7EHiPGRbFDU+JEf+zDVtlAIbQTMvMBi
# 4tfdHj+o+G06McDESYkQdJC6JQCvRCR5ZjIs9joY6p2/a4GRYQi8zkJTp19lwOlL
# WhuCk5hQiX/6b3A7tJdm+ruFO0qR4NxQA97k6XhghAe6U7RN3qCfsdh78ZPgncTR
# UMDq3Nvj5pYyTd5lKXXzxhnC3g5fE2DEyO7lK3e15W8Ns6+y52KBUcGo5JPS4dnI
# 1s6A4xk+KFp7zZumfU1RN+WFmIUQNkCxQXydYX3fSzpvnwCPzkK3za1QcDrLbGzu
# 8QvInJdiUQ2cwNfsrQtEyP2/vZmA
# SIG # End signature block
