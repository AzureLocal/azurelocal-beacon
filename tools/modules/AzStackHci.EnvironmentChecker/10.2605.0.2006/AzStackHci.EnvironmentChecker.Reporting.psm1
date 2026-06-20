<#
.SYNOPSIS
    Common Reporting functions across all modules/scenarios
.DESCRIPTION
    Logging, Reporting
.INPUTS
    Inputs (if any)
.OUTPUTS
    Output (if any)
.NOTES
    General notes
#>

Import-LocalizedData -BindingVariable lTxt -FileName AzStackHci.EnvironmentChecker.Strings.psd1

# Cache for result object type - avoids reading DLL from disk on every New-AzStackHciResultObject call
$script:CachedResultType = $null
$script:ManifestModuleImported = $false

function Set-AzStackHciOutputPath
{

    param ($Path, $Source='AzStackHciEnvironmentChecker/Diagnostic')
    if ([string]::IsNullOrEmpty($Path))
    {
        $Path = Join-Path -Path $HOME -ChildPath ".AzStackHci"
    }
    $Global:AzStackHciEnvironmentLogFile = Join-Path -Path $Path -ChildPath 'AzStackHciEnvironmentChecker.log'
    $Global:AzStackHciEnvironmentReport = Join-Path -Path $Path -ChildPath 'AzStackHciEnvironmentReport.json'
    $Global:AzStackHciEnvironmentReportXml = Join-Path -Path $Path -ChildPath 'AzStackHciEnvironmentReport.xml'
    Assert-EventLog -source $Source
    Set-AzStackHciIdentifier
}

function Get-AzStackHciEnvProgress
{
    <#
    .SYNOPSIS
        Look for existing progress or create new progress.
    .DESCRIPTION
        Finds either the latest progress XML file or creates a new progress XML file
    .EXAMPLE
        PS C:\> <example usage>
        Explanation of what the example does
    .INPUTS
        Clean switch, in case the user wants to start fresh
        Path to search for progress run.
    .OUTPUTS
        PSCustomObject of progress.
    .NOTES
    #>
    param ([switch]$clean, $path = $PSScriptRoot)

    $latestReport = Get-Item -Path $Global:AzStackHciEnvironmentReportXml -ErrorAction SilentlyContinue
    try { $report = Import-Clixml $latestReport.FullName } catch {}
    if (-not $clean -and $latestReport -and $report)
    {
        Log-Info -Message ('Found existing report: {0}' -f $report.FilePath)
    }
    else
    {
        $hash = @{
            FilePath = $Global:AzStackHciEnvironmentReportXml
            Version  = $MyInvocation.MyCommand.Module.Version.ToString()
            Jobs     = @{}
        }
        $report = New-Object PSObject -Property $hash
        Log-Info -Message ('Creating new report {0}' -f $report.FilePath)
    }
    $report
}

function Write-AzStackHciEnvProgress
{
    <#
    .SYNOPSIS
        Write report output to JSON
    .DESCRIPTION
        After all processing, take results object and convert to JSON report.
        Any file already existing will be overwritten.
    .EXAMPLE
        Write-AzStackHciEnvProgress -report $report
        Writes $report to JSON file
    .INPUTS
        [psobject]
    .OUTPUTS
        XML file on disk (path on disk is expected to be embedded in psobject)
    .NOTES
        General notes
    #>
    param ([psobject]$report)

    try
    {
        $report | Export-Clixml -Depth 10 -Path $report.FilePath -Force
        Log-Info -Message ('AzStackHCI progress written: {0}' -f $report.FilePath)
    }
    Catch
    {
        Log-Info -Message ('Writing XML progress to disk error {0}' -f $_.exception.message) -Type Error
    }
}

function Add-AzStackHciEnvJob
{
    <#
    .SYNOPSIS
        Adds a 'Job' to the progress object.
    .DESCRIPTION
        If a user runs the tool multiple time to check different assets
        e.g. Certificates on one execution and Registration details on the next execution
        Those executions are added to the progress for tracking purposes.
        Execution/Job details include:
            start time,
            parameters,
            parameterset (indicating what is being checked, certificates or Azure Accounts),
            Placeholders for EndTime and Duration (later filled in by Close-AzStackHciEnvJob)
    .EXAMPLE
        Add-AzStackHciEnvJob -report $report
        Adds execution job to progress object ($report)
    .INPUTS
        Report - psobject - containing all progress to date
    .OUTPUTS
        Report - psobject - updated with execution job log.
    .NOTES
        General notes
    #>
    param ($report)

    $allJobs = @{}
    $alljobs = $report.Jobs

    # Index for jobs must be a string for json conversion later
    if ($alljobs.Count)
    {
        $jobCount = ($alljobs.Count++).tostring()
    }
    else
    {
        $jobCount = '0'
    }

    # Record current job
    $currentJob = @{
        Index             = $jobCount
        StartTime         = (Get-Date -f 'yyyy/MM/dd HH:mm:ss')
        EndTime           = $null
        Duration          = $null
    }
    Log-Info -Message ('Adding current job to progress: {0}' -f $currentJob)
    # Add current job
    $allJobs += @{"$jobcount" = $currentJob }
    $report.Jobs = $allJobs
    $report
}

function Close-AzStackHciEnvJob
{
    <#
    .SYNOPSIS
        Writes endtime and duration for jobs
    .DESCRIPTION
        Find latest job entry and update time and calculates duration
        calls function to update xml on disk
        and updates and returns report object
    .EXAMPLE
        Close-AzStackHciEnvJob -report $report
    .INPUTS
        Report - psobject - containing all progress to date
    .OUTPUTS
        Report - psobject - updated with finished execution job log.
    .NOTES
        General notes
    #>
    param ($report)

    try
    {
        $latestJob = $report.jobs.Keys -match '[0-9]' | ForEach-Object { [int]$_ } | Sort-Object -Descending | Select-Object -First 1
        $report.jobs["$latestJob"].EndTime = (Get-Date -f 'yyyy/MM/dd HH:mm:ss')
        $duration = (([dateTime]$report.jobs["$latestJob"].EndTime) - ([dateTime]$report.jobs["$latestJob"].StartTime)).TotalSeconds
        $report.jobs["$latestJob"].Duration = $duration
        Log-Info -Message ('Updating current job to progress with endTime: {0} and duration {1}' -f $report.jobs["$latestJob"].EndTime, $duration)
        Write-AzStackHciEnvProgress -report $report
    }
    Catch
    {
        Log-Info -Message ('Updating current job to progress failed with exception: {0}' -f $_.exception) -Type Error
    }
    $report
}

function Write-AzStackHciEnvReport
{
    <#
    .SYNOPSIS
        Writes progress to disk in JSON format
    .DESCRIPTION
        Write progress object to disk in JSON format, overwriting as neccessary.
        The resulting blob is intended to be a portable record of what has been checked
        including the results of that check
    .EXAMPLE
        Write-AzStackHciEnvReport -report $report
    .INPUTS
        Report - psobject - containing all progress to date
    .OUTPUTS
        JSON - file - named AzStackEnvReport.json
    .NOTES
        General notes
    #>
    param ([psobject]$report)
    try
    {
        ConvertTo-Json -InputObject $report -Depth 8 -WarningAction SilentlyContinue | Out-File $AzStackHciEnvironmentReport -Force -Encoding UTF8
        Log-Info -Message ('JSON report written to {0}' -f $AzStackHciEnvironmentReport)
    }
    catch
    {
        Log-Info -Message ('Writing JSON report failed:' -f $_.exception.message) -Type Error
    }
}

function Log-Info
{
    <#
    .SYNOPSIS
        Write verbose logging to disk
    .DESCRIPTION
        Formats and writes verbose logging to disk under scriptroot.  Log type (or severity) is essentially cosmetic
        to the verbose log file, no action should be inferred, such as termination of the script.
    .EXAMPLE
        Write-AzStackHciEnvironmentLog -Message ('Script messaging include data {0}' -f $data) -Type 'Info|Warning|Error' -Function 'FunctionName'
    .INPUTS
        Message - a string of the body of the log entry
        Type - a cosmetic type or severity for the message, must be info, warning or error
        Function - ideally the name of the function or the script writing the log entry.
    .OUTPUTS
        Appends Log entry to AzStackHciEnvironmentChecker.log under the script root.
    .NOTES
        General notes
    #>
    [cmdletbinding()]
    param(
        [string]
        $Message,

        [ValidateSet('INFO', 'INFORMATIONAL', 'WARNING', 'CRITICAL', 'ERROR', 'SUCCESS')]
        [string]
        $Type = 'INFORMATIONAL',

        [ValidateNotNullOrEmpty()]
        [string]$Function = ((Get-PSCallStack)[0].Command),

        [switch]$ConsoleOut,

        [switch]$Telemetry
    )
    $Message = RunMask $Message
    if ($ConsoleOut)
    {
        #if ($PSEdition -eq 'desktop')
        if ($true)
        {
            switch -wildcard ($function)
            {
                '*-AzStackHciEnvironment*' { $foregroundcolor = 'DarkYellow' }
                default { $foregroundcolor = "White" }
            }
            switch ($Type)
            {
                'SUCCESS' { $foregroundcolor = 'Green' }
                'WARNING' { $foregroundcolor = 'Yellow' }
                'CRITICAL' { $foregroundcolor = 'Red' }
                'ERROR' { $foregroundcolor = 'Red' }
                default { $foregroundcolor = "White" }
            }
            Write-Host $message -ForegroundColor $foregroundcolor
        }
        else
        {
            Write-Host $message
        }
    }
    else
    {
        Write-Verbose $message
    }

    if (-not [string]::IsNullOrEmpty($message))
    {
        # Log to ETW
        if ($Telemetry)
        {
            $source = "AzStackHciEnvironmentChecker/Telemetry"
            $EventId = 17201
        }
        else
        {
            $source = "AzStackHciEnvironmentChecker/Operational"
            $EventId = 17203
        }
        $logName = 'AzStackHciEnvironmentChecker'
        $EventType = switch ($Type)
        {
            "ERROR" { "Error" }
            "CRITICAL" { "Error" }
            "WARNING" { 'Warning' }
            "SUCCESS" { "Information" }
            "INFORMATIONAL" { "Information" }
            Default { "Information" }
        }

        # Only write telemetry or non-info entries to the eventlog to save time and noise.
        if ($Telemetry -or $EventType -ne "Information")
        {
            Write-ETWLog -Source $Source -logName $logName -Message $Message -EventType $EventType -EventId $EventId
        }
        # Log to file
        $entry = "[{0}] [{1}] [{2}] {3}" -f ([datetime]::now).tostring(), $type.ToUpper(), $function, ($Message -replace "`n|`t", "")

        # If the log file path doesnt exist, create it
        if ([string]::IsNullOrEmpty($AzStackHciEnvironmentLogFile))
        {
            Set-AzStackHciOutputPath
        }
        if (-not (Test-Path $AzStackHciEnvironmentLogFile))
        {
            New-Item -Path $AzStackHciEnvironmentLogFile -Force | Out-Null
        }
        $retries = 3
        for ($i = 1; $i -le $retries; $i++) {
            try {
                $entry | Out-File -FilePath $AzStackHciEnvironmentLogFile -Append -Force -Encoding UTF8
                $writeFailed = $false
                break
            }
            catch {
                $writeFailed = "Log-info $i/$retries failed: $($_.ToString())"
                start-sleep -Seconds 5
            }
        }
        if ($writeFailed)
        {
            throw $writeFailed
        }
    }
}

function RunMask
{
    [cmdletbinding()]
    [OutputType([string])]
    Param (
        [Parameter(ValueFromPipeline = $True)]
        [string]
        $in
    )
    Begin {}
    Process
    {
        try
        {
            <#$in | Get-PIIMask | Get-GuidMask#>
            $in | Get-GuidMask
        }
        catch
        {
            $_.exception
        }
    }
    End {}
}

function Get-PIIMask
{
    [cmdletbinding()]
    [OutputType([string])]
    Param (
        [Parameter(ValueFromPipeline = $True)]
        [string]
        $in
    )
    Begin
    {
        $pii = $($ENV:USERDNSDOMAIN), $($ENV:COMPUTERNAME), $($ENV:USERNAME), $($ENV:USERDOMAIN) | ForEach-Object {
            if ($null -ne $PSITEM)
            {
                $PSITEM
            }
        }
        $r = $pii -join '|'
    }
    Process
    {
        try
        {
            return [regex]::replace($in, $r, "[*redacted*]")
        }
        catch
        {
            $_.exception
        }
    }
    End {}
}

function Get-GuidMask
{
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $True)]
        [String]
        $guid
    )
    Begin
    {
        $r = [regex]::new("(-([a-fA-F0-9]{4}-){3})")

    }
    Process
    {
        try
        {
            return [regex]::replace($guid, $r, "-xxxx-xxxx-xxxx-")
        }
        catch
        {
            $_.exception
        }
    }
    End {}
}

function Write-AzStackHciHeader
{
    <#
    .SYNOPSIS
        Write invocation and system information into log and writes cmdlet name and version to screen.
    #>
    param (
        [Parameter()]
        [System.Management.Automation.InvocationInfo]
        $invocation,

        [psobject]
        $params,

        [switch]
        $PassThru
    )
    try
    {
        $paramToString = (($params | Protect-SensitiveProperties).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
        $cmdLetName = Get-CmdletName
        $cmdletVersion = (Get-Command $cmdletName -ErrorAction SilentlyContinue).version.tostring()
        Log-Info -Message ''
        Log-Info -Message ('{0} v{1} started.' -f `
                $cmdLetName, $cmdletVersion) `
            -ConsoleOut:(-not $PassThru)

        # if override env vars are set, append to param string
        if (![string]::IsNullOrEmpty($ENV:envchkroverrideseverity) -or ![string]::IsNullOrEmpty($ENV:envchkroverridetest))
        {
            $paramToString += ";OverrideSeverity=$ENV:envchkroverrideseverity;ExcludeTests=$ENV:envchkroverridetest"
        }

        Log-Info -Telemetry -Message ('{0} started version: {1} with parameters: {2}. Id:{3}' `
                -f $cmdLetName, (Get-Module AzStackHci.EnvironmentChecker).Version.ToString(), $paramToString, $ENV:EnvChkrId)
        Log-Info -Message ('OSVersion: {0} PSVersion: {1} PSEdition: {2} Security Protocol: {3} Language Mode: {4} PSModuleAutoLoadingPreference: {5}' -f `
                [environment]::OSVersion.Version.tostring(), $PSVersionTable.PSVersion.tostring(), $PSEdition, [Net.ServicePointManager]::SecurityProtocol, $ExecutionContext.SessionState.LanguageMode, $PSModuleAutoLoadingPreference)
        Write-PsSessionInfo -params $params
    }
    catch
    {
        if (-not $PassThru)
        {
            Log-Info ("Unable to write header to screen. Error: {0}" -f $_.exception.message)
        }
    }
}

function Write-AzStackHciFooter
{
    <#
    .SYNOPSIS
        Writes report, log and cmdlet to screen.
    #>
    param (
        [Parameter()]
        [System.Management.Automation.InvocationInfo]
        $invocation,

        [System.Management.Automation.ErrorRecord]
        $Exception,

        [switch]
        $PassThru
    )

    Log-Info -Message ("`nLog location: $AzStackHciEnvironmentLogFile") -ConsoleOut:(-not $PassThru)
    Log-Info -Message ("Report location: $AzStackHciEnvironmentReport") -ConsoleOut:(-not $PassThru)
    Log-Info -Message ("Use -Passthru parameter to return results as a PSObject.") -ConsoleOut:(-not $PassThru)
    if ($Exception)
    {
        Log-Info -Message ("{0} failed." -f (Get-CmdletName)) -ConsoleOut:(-not $PassThru) -Type Error
        Log-Info -Message ("{0} failed. Id:{1}. Exception: {2}" -f (Get-CmdletName),$ENV:EnvChkrId,$Exception) -Type Error -Telemetry
    }
    else
    {
        Log-Info -Message ("{0} completed. Id:{1} " -f (Get-CmdletName),$ENV:EnvChkrId) -Telemetry
    }
}

function Get-CmdletName
{
    try
    {
        foreach ($c in (Get-PSCallStack).Command)
        {
            $functionCalled = Select-String -InputObject $c -Pattern "Invoke-AzStackHci(.*)Validation"
            if ($functionCalled)
            {
                 break
            }
        }
        $functionCalled
    }
    catch
    {
        throw "Hci Validation"
    }
}

function Write-AzStackHciResult
{
    <#
    .SYNOPSIS
        Displays results to screen
    .DESCRIPTION
        Displays test results to screen, highlighting failed tests.
    #>
    param (
        [Parameter()]
        [string]
        $Title,

        [Parameter()]
        [psobject]
        $result,

        $seperator = ' -> ',

        [switch]
        $Expand,

        [switch]
        $ShowFailedOnly
    )

    try
    {
        if (-not $result)
        {
            throw "Results missing. Ensure tests ran successfully."
        }
        Log-Info ("`n{0}:" -f $Title) -ConsoleOut


        foreach ($r in ($result | Sort-Object Status, Title, Description))
        {
            if ($r.status -ne 'SUCCESS' -or $Expand)
            {
                Write-StatusSymbol -Status $r.Status -Severity $r.Severity
                Write-Host " " -NoNewline
                Write-Host @expandDownSymbol
                Write-Host " " -NoNewline
                if ($r.status -ne 'SUCCESS')
                {
                    switch ($r.Severity)
                    {
                        Critical { Write-Host @needsRemediation }
                        Warning { Write-Host @needsAttention }
                        Informational { Write-Host @forInformation }
                        Default { Write-Host @Critical }
                    }
                }
                Write-Host " " -NoNewline
                Write-Host ($r.TargetResourceType + " - " + $r.Title + " " + $r.Description)
                foreach ($detail in ($r.AdditionalData | Sort-Object Status -Descending))
                {
                    if ($ShowFailedOnly -and $detail.Status -eq 'SUCCESS')
                    {
                        continue
                    }
                    else
                    {
                        Write-Host "  " -NoNewline
                        Write-StatusSymbol -Status $detail.Status -Severity $r.Severity
                        Write-Host " " -NoNewline
                        Write-Host " " -NoNewline
                        Write-Host ("{0}{1}{2}" -f $detail.Source, $seperator, $detail.Resource)
                    }
                }
                if ($detail.Status -ne 'SUCCESS')
                {
                    Write-Host "  " -NoNewline
                    Write-Host @helpSymbol
                    Write-Host ("  Help URL: {0}" -f $r.Remediation)
                    Write-Host ""
                }
            }
            else
            {
                if (-not $ShowFailedOnly)
                {
                    Write-Host @expandOutSymbol
                    Write-Host " " -NoNewline
                    Write-Host @greenTickSymbol
                    Write-Host " " -NoNewline
                    Write-Host @isHealthy
                    Write-Host " " -NoNewline
                    Write-Host ($r.TargetResourceType + " " + $r.Title + " " + $r.Description)
                }
            }
        }
    }
    catch
    {
        Log-Info "Unable to write results. Error: $($_.exception.message)" -Type Warning
    }
}

function Write-ETWLog
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $source = 'AzStackHciEnvironmentChecker/Diagnostic',

        [Parameter()]
        [string]
        $logName = 'AzStackHciEnvironmentChecker',

        [Parameter(Mandatory = $true)]
        [string]
        $Message,

        [Parameter()]
        [string]
        $EventId = 0,

        [Parameter()]
        [string]
        $EventType = 'Information'
    )
    try
    {
        #if message length is beyond 30000 (32766 limit) characters, truncate it
        # this would break json parsing but will need to be examined for further improvements
        if ($Message.Length -gt 30000)
        {
            $Message = $Message.Substring(0, 30000) + " ... (too many characters, truncating.)"
        }
        Write-EventLog -LogName $LogName -Source $Source -EntryType $EventType -Message $Message -EventId $EventId
    }
    catch
    {
        throw "Writing event log failed. Error $($_.exception.message)"
    }
}

function Assert-EventLog
{
    param (
        [Parameter()]
        [string]
        $source = 'AzStackHciEnvironmentChecker/Diagnostic'
    )
    try
    {
        $eventLog = Get-EventLog -LogName AzStackHciEnvironmentChecker -Source $Source -ErrorAction SilentlyContinue
    }
    catch {}
    # Try to create the log
    if (-not $eventLog)
    {
        New-AzStackHciEnvironmentCheckerLog
    }
}

function Write-ETWResult
{
    <#
    .SYNOPSIS
        Write result to telemetry channel
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [psobject]
        $Result
    )

    try {
        $source = 'AzStackHciEnvironmentChecker/Telemetry'
        if (![string]::IsNullOrEmpty($ENV:EnvChkrId))
        {
            $Result | Add-Member -MemberType NoteProperty -Name 'HealthCheckSource' -Value $ENV:EnvChkrId -Force -ErrorAction SilentlyContinue
        }
        $Message = $Result | ConvertTo-Json -Depth 5
        $EventId = 17205
        $EventType = if ($Result.Status -ne 'SUCCESS') { 'WARNING' } else { 'Information' }
        Write-ETWLog -Source $Source -EventType $EventType -Message $Message -EventId $EventId

    }
    catch {
        Log-Info "Failed to write result to telemetry channel. Error: $($_.Exception.message)" -Type Warning
    }
}

function Write-ManifestTelemetry
{
    <#
    .SYNOPSIS
        Write manifest override decision to telemetry channel
    .DESCRIPTION
        Writes structured manifest override information including validator decisions,
        excluded tests, and severity overrides to the telemetry event log.
    .EXAMPLE
        Write-ManifestTelemetry -ManifestDecision $overrideDecision
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]
        $ManifestDecision
    )

    try {
        $source = 'AzStackHciEnvironmentChecker/Telemetry'
        Assert-EventLog -source $Source
        # Add timestamp if not present
        if ($null -eq $ManifestDecision.Timestamp)
        {
            $ManifestDecision | Add-Member -MemberType NoteProperty -Name 'Timestamp' -Value ([datetime]::UtcNow.ToString("o")) -Force -ErrorAction SilentlyContinue
        }

        $Message = $ManifestDecision | ConvertTo-Json -Depth 8 -Compress
        $EventId = 17206
        $EventType = 'Information'

        Write-ETWLog -Source $Source -EventType $EventType -Message $Message -EventId $EventId
    }
    catch {
        Log-Info "Failed to write manifest telemetry. Error: $($_.Exception.message)" -Type Warning
    }
}

function Get-AzStackHciEnvironmentCheckerEvents
{
    <#
    .SYNOPSIS
        Retrieve AzStackHCI Environment Checker events from event log
    .EXAMPLE
        Get-AzStackHciEnvironmentCheckerEvents -Verbose
        Retrieve AzStackHCI Environment Checker events from event log
    .EXAMPLE
        $results = Get-AzStackHciEnvironmentCheckerEvents | ? EventId -eq 17205 | Select -last 1 | Select -expand Message | Convertfrom-Json
        Write-AzStackHciResult -result $results
        Get last result and write to screen
    #>

    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Operational', 'Diagnostic', 'Telemetry')]
        [string]
        $Source
    )
    try
    {
        $sourceFilter = switch ($source)
        {
            Operational { "AzStackHciEnvironmentChecker/Operational" }
            Diagnostic { "AzStackHciEnvironmentChecker/Diagnostic" }
            Telemetry { "AzStackHciEnvironmentChecker/Telemetry" }
            Default { "*" }
        }
        try
        {
            Get-EventLog -LogName AzStackHciEnvironmentChecker -Source $SourceFilter
        }
        catch {}
    }
    catch
    {
        throw "Failed to retrieve AzStackHCI environment checker logs. Error: $($_.exception.message)"
    }
}

function New-AzStackHciEnvironmentCheckerLog
{
    try
    {
        $scriptBlock = {
            $logName = 'AzStackHciEnvironmentChecker'
            $sources = @('AzStackHciEnvironmentChecker/Operational', 'AzStackHciEnvironmentChecker/Diagnostic', 'AzStackHciEnvironmentChecker/Telemetry', 'AzStackHciEnvironmentChecker/RemoteSupport', 'AzStackHciEnvironmentChecker/StandaloneObservability')
            foreach ($source in $sources)
            {
                New-EventLog -LogName $logName -Source $Source -ErrorAction SilentlyContinue
                Limit-EventLog -LogName $logName -MaximumSize 250MB
                Write-EventLog -Message ('Initializing log provider {0}' -f $source) -EventId 0 -EntryType Information -Source $source -LogName $logName -ErrorAction Stop
            }
        }

        if (Test-Elevation)
        {
            Invoke-Command -ScriptBlock $scriptBlock
        }
        else
        {
            $psProcess = if (Join-Path -Path $PSHOME -ChildPath powershell.exe -Resolve -ErrorAction SilentlyContinue)
            {
                Join-Path -Path $PSHOME -ChildPath powershell.exe
            }
            elseif (Join-Path -Path $PSHOME -ChildPath pwsh.exe -Resolve -ErrorAction SilentlyContinue)
            {
                Join-Path -Path $PSHOME -ChildPath pwsh.exe
            }
            else
            {
                throw "Cannot find powershell process. Please run powershell elevated and run the following command: 'New-EventLog -LogName $logName -Source $sourceName'"
            }
            Write-Warning "We need to run an elevated process to register our event log.  `nPlease continue and accept the UAC prompt to continue.  `nAlternatively, run: `nNew-EventLog -LogName $logName -Source $source `nmanually and restart this command."
            if (Grant-UACConcent)
            {
                Start-Process $psProcess -Verb Runas -ArgumentList "-command (Invoke-Command -ScriptBlock {$scriptBlock})" -Wait
            }
            else
            {
                throw "Unable to elevate and register event log provider."
            }
        }
    }
    catch
    {
        throw "Failed to create Environment Checker log. Error: $($_.Exception.Message)"
    }
}

function Remove-AzStackHciEnvironmentCheckerEventLog
{
    <#
    .SYNOPSIS
        Remove AzStackHCI Environment Checker event log
    .EXAMPLE
        Remove-AzStackHciEnvironmentCheckerEventLog -Verbose
        Remove AzStackHCI Environment Checker event log
    #>
    [cmdletbinding()]
    param()
    Remove-EventLog -LogName "AzStackHciEnvironmentChecker"
}


function Grant-UACConcent
{
    $concentAnswered = $false
    $concent = $false
    while ($false -eq $concentAnswered)
    {
        $promptResponse = Read-Host -Prompt "Register the event log. (Y/N)"
        if ($promptResponse -imatch '^y$|^yes$')
        {
            $concentAnswered = $true
            $concent = $true
        }
        elseif ($promptResponse -imatch '^n$|^no$')
        {
            $concentAnswered = $true
            $concent = $false
        }
        else
        {
            Write-Warning "Unexpected response"
        }
    }
    return $concent
}

function Write-Summary
{
    param ($result, $property1, $property2, $property3, $seperator = '->')
    try
    {
        $summary = Get-Summary @PSBoundParameters

        # Write percentage
        Write-Host "`nSummary"
        Write-Host $lTxt.Summary
        if (-not ([string]::IsNullOrEmpty($summary.FailedResourceCritical)))
        {
            Write-Host " " -NoNewline
            Write-StatusSymbol -status 'FAILURE' -Severity Critical
            Write-Host (" {0} Critical Issue(s)" -f @($summary.FailedResourceCritical).Count)
        }

        if (-not ([string]::IsNullOrEmpty($summary.FailedResourceWarning)))
        {
            Write-Host " " -NoNewline
            Write-StatusSymbol -status 'FAILURE' -Severity Warning
            Write-Host (" {0} Warning Issue(s)" -f @($summary.FailedResourceWarning).Count)
        }

        if (-not ([string]::IsNullOrEmpty($summary.FailedResourceInformational)))
        {
            Write-Host " " -NoNewline
            Write-StatusSymbol -status 'FAILURE' -Severity Informational
            Write-Host (" {0} Informational Issue(s)" -f @($summary.FailedResourceInformational).Count)
        }

        if ($Summary.successCount -gt 0)
        {
            Write-Host " " -NoNewline
            Write-StatusSymbol -status 'SUCCESS'
            Write-Host (" {0} successes" -f ($Summary.successCount))
        }

        <#Write-Host @expandDownSymbol
        Write-Host "  " -NoNewline
        switch ($Severity)
        {
            'CRITICAL' { Write-Host @redCrossSymbol }
            'WARNING' { Write-Host @warningSymbol }
            Default { Write-Host @redCrossSymbol }
        }#>
        #Write-Host ("  {0} / {1} ({2}%)" -f $summary.SuccessCount, $Result.AdditionalData.Resource.Count, $summary.SuccessPercentage)

        # Write issues by severity
        foreach ($severity in 'CRITICAL', 'WARNING', 'INFORMATIONAL')
        {
            $SeverityProp = "FailedResource{0}" -f $severity
            $failedResources = $summary.$SeverityProp | Sort-Object | Get-Unique

            if ($failedResources -gt 0)
            {
                Write-Host ""
                Write-Severity -severity $Severity
                Write-Host ""
                #Write-Host "`n$Severity Issues:"
                $failedResources | Sort-Object | Get-Unique | ForEach-Object {
                    Write-Host "  " -NoNewline
                    switch ($Severity)
                    {
                        'CRITICAL' { Write-Host @redCrossSymbol }
                        'WARNING' { Write-Host @warningSymbol }
                        Default { Write-Host @redCrossSymbol }
                    }
                    Write-Host "  $PSITEM"
                }
            }
        }

        if ($Summary.HelpLinks)
        {
            Write-Host "`nRemediation: "
            $Summary.HelpLinks | ForEach-Object {
                Write-Host "  " -NoNewline
                Write-Host @helpSymbol
                Write-Host "  $PSITEM"
            }
        }

        if (-not $summary.FailedResourceCritical -and -not $summary.FailedResourceWarning -and -not $summary.FailedResourceInformational)
        {
            Write-Host "`nSummary"
            Write-Host @expandOutSymbol
            Write-Host "  " -NoNewline
            Write-Host @greenTickSymbol
            Write-Host ("  {0} / {1} ({2}%) resources test successfully." -f $summary.SuccessCount, $Result.AdditionalData.Resource.Count, $summary.SuccessPercentage)
        }
    }
    catch
    {
        Log-Info -Message "Summary failed. $($_.Exception.Message)" -ConsoleOut -Type Warning
    }
}

function Get-Summary
{
    param ($result, $property1, $property2, $property3, $seperator = '->')

    try
    {
        if (-not $result)
        {
            throw "Unable to write summary. Check tests run successfully."
        }
        [array]$success = $result | Select-Object -ExpandProperty AdditionalData | Where-Object Status -EQ 'SUCCESS'
        [array]$HelpLinks = $result | Where-Object Status -NE 'SUCCESS' | Select-Object -ExpandProperty Remediation | Sort-Object | Get-Unique
        [array]$nonSuccess = $result | Select-Object -ExpandProperty AdditionalData | Where-Object Status -NE 'SUCCESS'
        [array]$nonSuccessCritical = $result | Where-Object Severity -EQ Critical | Select-Object -ExpandProperty AdditionalData | Where-Object Status -NE 'SUCCESS'
        [array]$nonSuccessWarning = $result | Where-Object Severity -EQ Warning | Select-Object -ExpandProperty AdditionalData | Where-Object Status -NE 'SUCCESS'
        [array]$nonSuccessInformational = $result | Where-Object Severity -EQ Informational | Select-Object -ExpandProperty AdditionalData | Where-Object Status -NE 'SUCCESS'

        $successPercentage = if ($success.count -gt 0)
        {
            [Math]::Round(($success.Count / $result.AdditionalData.Resource.count) * 100)
        }
        else
        {
            0
        }

        $sourceDestsb = {
            if ([string]::IsNullOrEmpty($_.$property2) -and [string]::IsNullOrEmpty($_.$property3))
            {
                "{0}" -f $_.$property1
            }
            elseif ([string]::IsNullOrEmpty($_.$property3))
            {
                "{0}{1}{2}" -f $_.$property1, $seperator, $_.$property2
            }
            else
            {
                "{0}{1}{2}({3})" -f $_.$property1, $seperator, $_.$property2, $_.$property3
            }
        }
        $FailedResourceCritical = $nonSuccessCritical |
        Select-Object @{ label = 'SourceDest'; Expression = $sourceDestsb } -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SourceDest |
        Sort-Object |
        Get-Unique

        $FailedResourceWarning = $nonSuccessWarning |
        Select-Object @{ label = 'SourceDest'; Expression = $sourceDestsb } -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SourceDest |
        Sort-Object |
        Get-Unique

        $FailedResourceInformational = $nonSuccessInformational |
        Select-Object @{ label = 'SourceDest'; Expression = $sourceDestsb } -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SourceDest |
        Sort-Object |
        Get-Unique

        $summary = New-Object -Type PsObject -Property @{
            successCount                = $success.Count
            nonSuccessCount             = $nonSuccess.Count
            successPercentage           = $successPercentage
            HelpLinks                   = $HelpLinks
            FailedResourceCritical      = $FailedResourceCritical
            FailedResourceWarning       = $FailedResourceWarning
            FailedResourceInformational = $FailedResourceInformational
        }
        return $summary
    }
    catch
    {
        throw "Unable to calculate summary. Error $($_.exception.message)"
    }
}

# Symbols
$global:greenTickSymbol = @{
    Object          = [Char]0x2713     #8730
    ForegroundColor = 'Green'
    NoNewLine       = $true
}
$global:redCrossSymbol = @{
    Object          = [Char]0x2622 #0x00D7
    ForegroundColor = 'Red'
    NoNewLine       = $true
}

$global:WarningSymbol = @{
    Object          = [char]0x26A0
    ForegroundColor = 'Yellow'
    NoNewLine       = $true
}

$global:bulletSymbol = @{
    Object    = [Char]0x25BA
    NoNewLine = $true
}

# Text
$global:needsAttention = @{
    object          = $lTxt.NeedsAttention;
    ForegroundColor = 'Yellow'
    NoNewLine       = $true
}

$global:needsRemediation = @{
    object          = $lTxt.NeedsRemediation;
    ForegroundColor = 'Red'
    NoNewLine       = $true
}

$global:ForInformation = @{
    object    = $lTxt.ForInformation;
    NoNewLine = $true
}

$global:expandDownSymbol = @{
    object    = [Char]0x25BC # expand down
    NoNewLine = $true
}

$global:expandOutSymbol = @{
    object    = [Char]0x25BA # expand out
    NoNewLine = $true
}

$global:helpSymbol = @{
    object    = [char]0x270E   #0x263C # sunshine
    NoNewLine = $true
    #ForegroundColor = 'Yellow'
}

$global:Critical = @{
    object          = $lTxt.Critical;
    ForegroundColor = 'Red'
    NoNewLine       = $true
}

$global:Warning = @{
    object          = $lTxt.Warning;
    ForegroundColor = 'Yellow'
    NoNewLine       = $true
}

$global:Information = @{
    object    = $lTxt.Informational;
    NoNewLine = $true
}

$global:isHealthy = @{
    object    = $lTxt.Healthy
    NoNewLine = $true
}

function Write-StatusSymbol
{
    param ($status, $severity)
    switch ($status)
    {
        "SUCCESS" { Write-Host @greenTickSymbol }
        "FAILURE"
        {
            switch ($Severity)
            {
                'CRITICAL' { Write-Host @redCrossSymbol }
                'WARNING' { Write-Host @warningSymbol }
                Default { Write-Host @redCrossSymbol }
            }
        }
        Default { Write-Host @bulletSymbol }
    }
}

function Write-Severity
{
    param ($severity)
    switch ($severity)
    {
        'CRITICAL' { Write-Host @needsRemediation }
        'WARNING' { Write-Host @needsAttention }
        'INFORMATIONAL' { Write-Host @ForInformation }
        Default { Write-Host @Critical }
    }
}

function Set-AzStackHciIdentifier
{
    $ENV:EnvChkrId = $null
    if ([string]::IsNullOrEmpty($ENV:EnvChkrOp))
    {
        $ENV:EnvChkrOp = 'Manual'
    }
    # Check if validator implemented HardwareClass parameter and set it to Medium if not provided
    $cmdletHardwareClass = Get-CmdletParameter -ParameterName HardwareClass
    $cmdletClusterPattern = Get-CmdletParameter -ParameterName ClusterPattern

    # If the user passed hardwareclass to the validator, use it
    if (-not [string]::IsNullOrEmpty($cmdletHardwareClass))
    {
        $HardwareClass = $cmdletHardwareClass
    }
    else
    {
        $HardwareClass = 'Medium'
    }

    # If the user passed ClusterPattern to the validator, use it
    if (-not [string]::IsNullOrEmpty($cmdletClusterPattern))
    {
        $ClusterPattern = $cmdletClusterPattern
    }
    else
    {
        $ClusterPattern = 'Standard'
    }

    $validatorCmd = Get-CmdletName
    if(-not [string]::IsNullOrWhiteSpace($validatorCmd))
    {
        $ENV:EnvChkrId = "{0}\{1}\{2}\{3}\{4}" -f $ENV:EnvChkrOp, $ClusterPattern, $HardwareClass, $validatorCmd.matches.groups[1], (([system.guid]::newguid()) -split '-' | Select-Object -first 1)
    }
}

function Get-CmdletParameter
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $ParameterName
    )
    try
    {
        $cmdletHardwareClass = Get-PSCallStack | `
            Where-Object FunctionName -like 'Invoke-AzStackHci*Validation' | `
			Select-Object -First 1 | `
            Select-Object -ExpandProperty InvocationInfo | `
            Select-Object -ExpandProperty BoundParameters -ErrorAction SilentlyContinue

        $hardwareClass = $cmdletHardwareClass.$ParameterName
        return $hardwareClass
    }
    catch
    {
        Log-Info -Message "Failed to get cmdlet hardware class. Error: $($_.exception.message)" -Type Warning
        return $null
    }
}

function Write-PsSessionInfo
{
    <#
    .SYNOPSIS
        Write some pertainent information to the log about any PsSessions passed
    #>
    [CmdletBinding()]
    param (
        $params
    )
    try {
        if ($params['PsSession'])
        {
            foreach ($session in $params['PsSession'])
            {
                Log-Info -Message ("PsSession info: {0}, {1}, {2}, {3}, {4}, {5}" -f $session.ComputerName, $session.Name, $session.Id, $session.Runspace.ConnectionInfo.credential.username, $session.Runspace.SessionStateProxy.LanguageMode, $session.Runspace.ConnectionInfo.AuthenticationMechanism)
            }
        }
        else
        {
            Log-Info -Message "No PsSession info to write"
        }
    }
    catch
    {
        Log-Info -Message "Failed to write PsSession info: $($_.exception.message)"
    }
}

function Log-CimData
{
    <#
    .SYNOPSIS
        Logs CIM data in a compact, readable format for diagnostics
    .DESCRIPTION
        Outputs CIM instance data grouped by server. At scale, uses summary mode
        to avoid logging hundreds of lines for disk/adapter inventories.
    #>
    [CmdletBinding()]
    param (
        $cimData,
        [array]$properties
    )
    try {
        if ($null -eq $cimData -or @($cimData).Count -eq 0)
        {
            return
        }

        $totalInstances = @($cimData).Count

        # Use properties provided or key properties if none provided
        $selectProperties = @()
        if ($null -eq $Properties)
        {
            # Get all properties except CIM system properties for cleaner output
            $firstItem = @($cimData)[0]
            if ($firstItem.PSObject.Properties)
            {
                $selectProperties = @($firstItem.PSObject.Properties.Name | Where-Object { 
                    $_ -notmatch '^(Cim|PS)' -and $_ -ne 'CimClass' -and $_ -ne 'CimInstanceProperties' -and $_ -ne 'CimSystemProperties'
                })
            }
            else
            {
                $selectProperties = @("*")
            }
        }
        else 
        {
            foreach ($property in $Properties)
            {
                if ($property -is [hashtable])
                {
                    $selectProperties += $property.Keys
                }
                else
                {
                    $selectProperties += $property
                }
            }
        }

        # Group by server for compact logging
        $serverNames = @($cimData | ForEach-Object { 
            if ($_.CimSystemProperties.ServerName) { $_.CimSystemProperties.ServerName }
            elseif ($_.ComputerName) { $_.ComputerName }
            elseif ($_.PSComputerName) { $_.PSComputerName }
            else { $ENV:COMPUTERNAME }
        } | Sort-Object -Unique)

        [string]$className = @($cimData)[0].CimClass.CimClassName
        if ([string]::IsNullOrEmpty($className))
        {
            $className = "CimData"
        }

        # Scale threshold: if >100 total instances or >8 nodes, use summary mode
        $useSummaryMode = ($totalInstances -gt 100) -or ($serverNames.Count -gt 8)

        if ($useSummaryMode)
        {
            # Summary mode: log counts and unique values only
            Log-Info ("{0}: {1} instance(s) across {2} node(s) [summary mode]" -f $className, $totalInstances, $serverNames.Count)
            
            # Per-node counts
            $nodeCounts = @()
            foreach ($serverName in $serverNames)
            {
                $nodeCount = @($cimData | Where-Object {
                    ($_.CimSystemProperties.ServerName -eq $serverName) -or 
                    ($_.ComputerName -eq $serverName) -or
                    ($_.PSComputerName -eq $serverName)
                }).Count
                $nodeCounts += "{0}:{1}" -f $serverName, $nodeCount
            }
            Log-Info ("  Counts: {0}" -f ($nodeCounts -join ", "))

            # Log unique values for key identifying properties (first 3 non-trivial properties)
            $keyProps = @($selectProperties | Where-Object { $_ -notmatch '(Size|Count|Index|Number)$' } | Select-Object -First 3)
            foreach ($prop in $keyProps)
            {
                $uniqueVals = @($cimData.$prop | Where-Object { $_ } | Sort-Object -Unique)
                if ($uniqueVals.Count -gt 0 -and $uniqueVals.Count -le 20)
                {
                    Log-Info ("  {0}: {1}" -f $prop, ($uniqueVals -join ", "))
                }
                elseif ($uniqueVals.Count -gt 20)
                {
                    Log-Info ("  {0}: {1} unique values" -f $prop, $uniqueVals.Count)
                }
            }
        }
        else
        {
            # Detail mode: log each instance on one line
            Log-Info ("{0}: {1} instance(s) across {2} node(s)" -f $className, $totalInstances, $serverNames.Count)

            foreach ($serverName in $serverNames)
            {
                $sData = @($cimData | Where-Object {
                    ($_.CimSystemProperties.ServerName -eq $serverName) -or 
                    ($_.ComputerName -eq $serverName) -or
                    ($_.PSComputerName -eq $serverName)
                })
                
                if ($sData.Count -eq 0) { continue }

                # Build compact property string for each instance
                foreach ($instance in $sData)
                {
                    $propValues = @()
                    foreach ($prop in $selectProperties)
                    {
                        $val = $instance.$prop
                        if ($null -ne $val -and "$val" -ne "")
                        {
                            # Truncate long values
                            $valStr = "$val"
                            if ($valStr.Length -gt 40)
                            {
                                $valStr = $valStr.Substring(0, 37) + "..."
                            }
                            $propValues += "{0}={1}" -f $prop, $valStr
                        }
                    }
                    if ($propValues.Count -gt 0)
                    {
                        Log-Info ("  {0}: {1}" -f $serverName, ($propValues -join ", "))
                    }
                }
            }
        }
    }
    catch
    {
        Log-Info "Failed to write cimdata to log file. Error: $($_.Exception.Message)" -Type Error
    }
}

function New-AzStackHciResultObject
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $Name,

        [Parameter()]
        [String]
        $DisplayName,

        [Parameter()]
        [String]
        $Title,

        [Parameter()]
        [Hashtable]
        $Tags,

        [Parameter()]
        [String]
        $Status,

        [Parameter()]
        [String]
        $Severity,

        [Parameter()]
        [String]
        $Description,

        [Parameter()]
        [String]
        $Remediation,

        [Parameter()]
        [String]
        $TargetResourceID,

        [Parameter()]
        [String]
        $TargetResourceName,

        [Parameter()]
        [String]
        $TargetResourceType,

        [Parameter()]
        [datetime]
        $Timestamp,

        [Parameter()]
        [Hashtable]
        $AdditionalData,

        [Parameter()]
        [string]
        $HealthCheckSource
    )

    # Apply manifest severity override (import once per module load)
    if (-not $script:ManifestModuleImported)
    {
        Import-Module $PSScriptRoot\Manifest\AzStackHci.EnvironmentChecker.Manifest.Utilities.psm1
        $script:ManifestModuleImported = $true
    }
    $override = Get-ManifestSeverityOverride -Name $Name -Severity $Severity
    if ($override.OverrideApplied)
    {
        Log-Info -Message ("Severity override applied for {0}: {1} -> {2}" -f $Name, $Severity, $override.Severity.ToUpper())
        $Severity = $override.Severity.ToUpper()

        # Get the override message from the AdditionalData.Override object
        $overrideMessage = if ($override.AdditionalData -and $override.AdditionalData.Override) {
            $override.AdditionalData.Override.Message
        } else {
            $null
        }

        # Add override detail to AdditionalData
        if ($null -eq $AdditionalData)
        {
            Log-Info -Message "Creating AdditionalData hashtable to store override detail. "
            $AdditionalData = @{}
        }
        if ([string]::IsNullOrEmpty($AdditionalData.Detail))
        {
            Log-Info -Message "Adding override detail to AdditionalData. '$overrideMessage'"
            $AdditionalData.Detail = $overrideMessage
        }
        else
        {
            Log-Info -Message "Appending override detail to AdditionalData."
            $AdditionalData.Detail = "{0}`r`n`r`n{1}" -f $AdditionalData.Detail, $overrideMessage
            Log-Info -Message "New AdditionalData.Detail: '$($AdditionalData.Detail)'"
        }

        # Update PSBoundParameters with the modified AdditionalData so it gets applied to the result object
        $PSBoundParameters['AdditionalData'] = $AdditionalData
    }

    # Cache result type to avoid reading DLL from disk on every call
    if ($null -eq $script:CachedResultType)
    {
        $bytes = [system.io.file]::ReadAllBytes("$PsScriptRoot\Schema\Microsoft.EnvironmentReadiness.Validator.Client.dll")
        $assembly = [Reflection.Assembly]::Load($bytes)
        $script:CachedResultType = $assembly.GetType("Microsoft.EnvironmentReadiness.Client.Models.EnvironmentReadinessTestResult")
    }
    $resultObj = New-Object -TypeName $script:CachedResultType.FullName
    # Set properties from PSBoundParameters
    foreach ($param in $PSBoundParameters.Keys)
    {
        if ($PSBoundParameters[$param])
        {
            if ($PSBoundParameters[$param] -is [System.Collections.Hashtable])
            {
                $resultObj.$param = ConvertTo-Dictionary -hashTable $PSBoundParameters[$param]
            }
            else {
                $resultObj.$param = $PSBoundParameters[$param]
            }
        }
    }

    # Apply overridden values after PSBoundParameters processing
    if ($override.OverrideApplied)
    {
        $resultObj.Severity = $Severity
    }

    return $resultObj
}

# Convert hashtable to dictionary
function ConvertTo-Dictionary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [hashtable]$hashTable
    )
    begin {
        $dictionary = New-Object 'system.collections.generic.dictionary[string,string]'
    }
    process {
        foreach ($key in $hashTable.Keys) {
            if ([string]::IsNullOrEmpty($hashTable[$key]))
            {
                $value = ""
            }
            else {
                $value = $hashTable[$key]
            }
            $dictionary.Add($key, $value)
        }
    }
    end {
        return ,$dictionary
    }
}

# function to get psobject from pipeline and redact sensitive property values
function Protect-SensitiveProperties
{
    param (
        [Parameter(ValueFromPipeline = $true)]
        [psObject]
        $params
    )
    BEGIN
    {
        $array = @()
    }
    PROCESS
    {
        try
        {
            $ret = @{}
            foreach($key in $_.Keys)
            {
                # Redact sensitive parameters
                if($Key -match "ArmAccessToken|Account|PsSession")
                {
                    $ret += @{$Key = '[redacted]'}
                }
                else
                {
                    $ret += @{$Key = $_[$Key]}
                }
            }
            $array += $ret
        }
        catch
        {
            Log-Info "Error occurred trying to remove sensitive parameters. Error: $($_.Exception.Message)" -Type ERROR
        }
    }
    END
    {
        return $array
    }
}


# Convert result to json
function ConvertAzStackHciResultObjectTo-Json {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Microsoft.EnvironmentReadiness.Client.Models.EnvironmentReadinessTestResult]$resultObj
    )
    process {
        $properties = Get-Member -InputObject $resultObj -MemberType Properties | Select-Object -ExpandProperty Name
        $hashTable = @{}
        foreach ($property in $properties) {
            if ($property -eq 'TimeStamp') {
                $hashTable[$property] = $resultObj.$property.ToString("o")
            }
            elseif ($property -eq 'Severity' -or $property -eq 'Status') {
                $hashTable[$property] = $resultObj.$property.ToString()
            }
            else {
                $hashTable[$property] = $resultObj.$property
            }
        }
        return ($hashTable | ConvertTo-Json -Depth 5)
    }
}

Export-ModuleMember -function Add-AzStackHciEnvJob
Export-ModuleMember -function Close-AzStackHciEnvJob
Export-ModuleMember -function Get-AzStackHciEnvironmentCheckerEvents
Export-ModuleMember -function Get-AzStackHciEnvProgress
Export-ModuleMember -function Log-Info
Export-ModuleMember -function Set-AzStackHciOutputPath
Export-ModuleMember -function Write-AzStackHciEnvReport
Export-ModuleMember -function Write-AzStackHciFooter
Export-ModuleMember -function Write-AzStackHciHeader
Export-ModuleMember -function Write-AzStackHciResult
Export-ModuleMember -function Write-ETWLog
Export-ModuleMember -function Write-ETWResult
Export-ModuleMember -function Write-ManifestTelemetry
Export-ModuleMember -function Write-Summary
Export-ModuleMember -function Log-CimData
Export-ModuleMember -function New-AzStackHciResultObject
Export-ModuleMember -function ConvertAzStackHciResultObjectTo-Json
# SIG # Begin signature block
# MIInSAYJKoZIhvcNAQcCoIInOTCCJzUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAPPXAoEcac+0Tp
# 0i/xm65ZESYpc5Oqq5Kk+4pBOSGzzaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnkMIIZ4AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHDE6+tX
# 0ASIvcl1Cxtghj/kNuzDrXD8gp0O7SuENP13MEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAHW/uM2h51KI7dKdTXekWyH4ncsmvT2gwnMwKGc1e
# eIL6TPeMMkSeY3diFr5AKJyyJgIDGdwg0UdmqDzj68K+0qLYsWxaDVv8cZkrbZhD
# xmSTyPePfp6a9Wqqgq3YGpMR45VlSTo0WfrkEv7ICNuA7sCV6j5zq7j0p8Tp1R2B
# DmpdF2eGA6+sCi+es4IyQv7/NLngWISr2PMCNUnJXHq9cSDg+ejexCxLDtutfZli
# NI8kad0DIScmKXuTkNRx/ajB2x7jycJ9V1Z52ZE98j5jj+uJ8NeDw4SkhTLlW6dW
# Vebih/d4lSjwB7MwPwUjnHRIszTk0/n3Fmz7i1Z/IpRBfKGCF5YwgheSBgorBgEE
# AYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAjq/TV0GtKCmlvxcc1y2HwMmYVyXbgQ+Pnjnot
# PHBw/gIGaeegqJ38GBIyMDI2MDUwMzE0MzExMC4xNVowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjo3RjAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMzAAACHqOspG45b3xJAAEAAAIe
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5Mzk0OVoXDTI3MDUxNzE5Mzk0OVowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RjAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKXROO1sPCxHsV7xpzqiXmzXOG1O
# p3YBalyFCEun0bmaZIzbc3l/JAYJDUPTqs4Dc+BcoX7vq9e84KzZWwu/WjCPiYcT
# ISqKrwYnnIL79A1hGlk8Dx7s6B6TMM7pL/i/L+NMxhuneuG4WIooLNNY5C10VwX4
# PSTfr0jumb8TTtLI0waS413mWPlIn3VSoW5l+MwHpxDbCHvua2JFRV2PnfKN02qP
# 4ZCX5hrPb0GOvOftTWWf4mkuWdvTF0aZmgg8plvAFVxa3Ivi7KEwvtJJOaI59ZdT
# 6D7I2XQJ2gsYvwu1YcSLwWy5M95J1KqZ4yu8toSaJtNVNLi9BBjw0+dvq4jnLqI1
# X28EVybwtT+UNOMZOo9rtQFPiB1/kmbfBit8IVng/+PkyipPQk41xrnSO3hMYj3R
# KKFdoMRiqTbdLQglndSRSm6QNFOMrvXcEjKR9/HIGox5Cp87TO9Z9THsGuZSm6BB
# zD334PEuXaB/65ASlGaeVutUn129b12zh+oQ83aMbRDAXU8FKCU1xXVKmpkqK1CA
# EZLC7/zYArO2gIfBhEdE3DPBNV7/Uo1O+aoB3hSB6zjLA4fTaFpqBPzBhjw51Z2M
# qfeTTnbD6SZzRQLQX6JVdMZkgzG+j2IFlChd6HNG1Yn9U60q8LJLdywrM3utK1Yn
# CNJbPp205/SX7K0tAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQU5goWmuoEHQlmYlwU
# Lhw8+Z4XgmQwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAKShkHk2clUVvnAp6NGi
# eTnXxrZME1ikpwEy18voFLQBFoAE4wZguU826EjUfCZ6U/2FfeirdNoSb9wOSTM1
# ADMN50+ChEjZHv7ymg1Ja8dcQCztJk4Ob3HsqqUGQ1kz17HhdjXI2ZU4CZYONGvu
# MqNqJBue1/sQLgY2KTEYZpVY6N9i3dD1fSv8qzwoGVvMNH3OMD9MJy1HhyjValTV
# lEsWsH1uXx1HGxufJPapDjUTt1PXZHfR4gZTOISzkY37bpX+i9c6LbR0mIzXeFha
# /LU00kCGQo6UsHU426d3p9+E91Rwday7xX6VHRpqQxXrgeoNsu6ZmsI3BSh9XHfE
# yTwXi0Jgm1DEtPLBzfSxkAPVLawLX3n3HoqLED6njUUtSXyDrigfLdt9icfnF3gk
# 4GBChqqd0aNxy3Gv7wSSeOErKuADOtNwosltR7OCjJ7xusIsn7Lo8CgSOldGRJgB
# TzB9DdhZFyToAvChXtSKfz6ukZBJteEXpzV1MVqReYKEKW53ggANj+3olGQn7ToX
# Mv6MN3wotXxCPvsl+K5OI8gbkb/GWcahkVxf7LIG0O/NkTjx35j4dhR39y+EfUUq
# XsAf7kDKi2olIWa8z8G5hHHYHbRqxVeKVXaTYls07csYLPdD52kSXPCx8muRrU3+
# B62Zrt9amjCw2+ghoRC+Np3xMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
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
# M1izoXBm8qGCA1AwggI4AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0YwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAIP9A2QoMhbhUgXuPeiLaputHRr/oIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoUaMMCIYDzIw
# MjYwNTAzMDM1OTA4WhgPMjAyNjA1MDQwMzU5MDhaMHcwPQYKKwYBBAGEWQoEATEv
# MC0wCgIFAO2hRowCAQAwCgIBAAICEzICAf8wBwIBAAICExAwCgIFAO2imAwCAQAw
# NgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgC
# AQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEABWL3G+U6H3nmfWKTkPWQOPFbkVKN
# OYB7aLm2LpejRDyd6fbNGPYNmJZiWZTEJc77BzB3TUiyNTQ3WWjcsdPv4zLSCNJY
# p2GzKPS3j0etl/jv25Q12jiIrk7HGYtcSIM1z6eauank9UwTp5fGgDeTKGppx7dy
# 1OS1RLOsPcZT5LczYuv/wHeDxyRGCcwTDnmg+v1zk8hlizoOkuNRsSaqsgKSR/Zd
# /6QdUkXWKxTqaaVye+WXuWE8BbpAIgs9opJvlkScsTeRO+GlkVN9UXETLLVw2h/q
# sIN/z7k4L4EAMHXqtztJavXF/i3ypT2NylZ6ZVecOosFKj8JOFiWv75jZTGCBA0w
# ggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACHqOs
# pG45b3xJAAEAAAIeMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIFkvXqMTkmQ1u1CjMbDXs2ioA1xc
# VXtWI6E3CzUsUv7aMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgL4FdavP2
# B4yAzwG+fxurEeOEdcnb0QGLMhMjDQH284IwgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh6jrKRuOW98SQABAAACHjAiBCAnWN1AP7Sz
# Ob53T+Skq2Ii4ocTyhbZ31W2rL1+WPw8KzANBgkqhkiG9w0BAQsFAASCAgBsoRFk
# 8WCfYlN0BMAQLhffcbr0SyElWhvPwRq+4fPODq5koLNg19/pLml9V7vL6b5gcDP8
# Cna4Ijg7ZFzmk7KmAJBxldH27xCBYiB61LIME2tA4ZhwiBkl2jcKLg/Im4iUoFHR
# jjVFXxRjLN67o46MOi6jfMfUOBzQ8/4kNB7WBZ5oZxO6gCc6ew1SGbDaBYQjjOWj
# EYD2c2dIaUL+K3Lrt2qmsER9Fr2S99DTn+eTdA7FI5cYxFFfzaB1te95OpdbAMlL
# RrEbvc8SNv4cOM1cQObzbktGSQ0xWseG3T54n4BldFd8+zq4uN6K3WihKiV3rT6n
# xMU5uzJrCWY/x8vupRir9MZ8GQ04sNemeatyC4EtbjGKbY5iNTt4F+B90brqw5FQ
# aeMcu9apdFBLohHtfELrWzSbKpmHQGph4wodqA6e4gAfQEmDRpWcGxVoCxSZWAh0
# 6sHQM3XBA7iWdy+gH+5nln83zJQVutK85fZ7XYLSuhL2atfWsuYMD7PEM/6qS9IX
# Z+6IM4EzO+gpIx+vBs31KpYMmc7xXcWs1GMhLi3d2jUV0P4stA0qXI/kXy3oyLPj
# uQDISMW9aYwYWmEi2Be5pkaCAHpA3x8UzyKhoMpXyxPLCyZJByZ/MDg0HFQlzNNv
# p55DieCNhUZXQ38A5DjuhlZzoYWMyqGE6+IlsQ==
# SIG # End signature block
