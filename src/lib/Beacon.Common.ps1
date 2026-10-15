# AzL Beacon - shared helpers (console output, result recording, config loading).
# Dot-sourced by Start-AzlValidation.ps1 and Start-AzlBeacon.ps1. PowerShell 5.1 compatible.

if (-not (Get-Variable -Name AllResults -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AllResults = New-Object System.Collections.Generic.List[object]
}
if (-not (Get-Variable -Name CriticalFail -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CriticalFail = $false
}

function Out-ConsoleLine {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White
    )
    Write-Information -MessageData $Message -Tags @('AzlValidation', $Color.ToString()) -InformationAction Continue
}

function Add-ValidationResult {
    [CmdletBinding()]
    param(
        [string]$Category,
        [string]$Name,
        [string]$Target,
        [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')]
        [string]$Status,
        [string]$Detail,
        [long]$DurationMs = 0,
        [ValidateSet('critical', 'warning', 'informational', '')]
        [string]$Severity = '',
        [string]$Remediation = '',
        [string]$Source = ''
    )

    $result = [PSCustomObject][ordered]@{
        Category    = $Category
        Name        = $Name
        Target      = $Target
        Status      = $Status
        Severity    = $Severity
        Detail      = $Detail
        DurationMs  = $DurationMs
        Remediation = $Remediation
        Source      = $Source
    }
    $script:AllResults.Add($result)

    $symbol = switch ($Status) {
        'Pass' { '[PASS]' }
        'Fail' { '[FAIL]' }
        'Warn' { '[WARN]' }
        'Skip' { '[SKIP]' }
        default { '[INFO]' }
    }
    $color = switch ($Status) {
        'Pass' { [System.ConsoleColor]::Green }
        'Fail' { [System.ConsoleColor]::Red }
        'Warn' { [System.ConsoleColor]::Yellow }
        'Skip' { [System.ConsoleColor]::DarkGray }
        default { [System.ConsoleColor]::White }
    }
    $msg = '  {0} {1,-48} {2}' -f $symbol, $Name, $Target
    if ($Detail) { $msg = $msg + ' -- ' + $Detail }
    Out-ConsoleLine -Message $msg -Color $color

    if ($Status -eq 'Fail') { $script:CriticalFail = $true }
}

function Get-ConfigDirectory {
    param([string]$Provided, [string]$ScriptRoot)
    if ($Provided -ne '' -and (Test-Path $Provided -PathType Container)) {
        return (Resolve-Path $Provided).Path
    }
    $candidate = Join-Path $ScriptRoot 'config'
    if (Test-Path $candidate -PathType Container) { return $candidate }
    throw "Config directory not found. Pass -ConfigPath or place config/ next to this script."
}

function Get-ResultsDirectory {
    param([string]$Provided)
    if ($Provided -ne '') { return $Provided }
    if (Test-Path 'X:\') { return 'X:\results' }
    return $env:TEMP
}

function Import-JsonConfig {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { throw "Required config file not found: $FilePath" }
    return Get-Content $FilePath -Raw | ConvertFrom-Json
}

function Resolve-ConfigDefaults {
    # Fills missing optional fields so StrictMode never throws on property access.
    param([object]$Config)
    $defaults = [ordered]@{
        managementGateway   = ''
        pingTimeoutMs       = 2000
        tcpConnectTimeoutMs = 5000
        nodeIps             = @()
        dnsServers          = @()
        adDomainFqdn        = ''
        nodeFqdns           = @()
        dcIps               = @()
        clusterName         = ''
        azureRegion         = ''
        oem                 = ''
        arcGatewayFqdn      = ''
        keyVaultFqdn        = ''
        proxyUrl            = ''
        proxyBypass         = @()
        ntpServers          = @()
        brand               = ''
        managementSubnetCidr = ''
        hostNetworkIntents  = @()
        infraIpPools        = @()
        tlsInspectionHosts  = @('login.microsoftonline.com', 'management.azure.com')
    }
    foreach ($key in $defaults.Keys) {
        if (-not ($Config.PSObject.Properties.Name -contains $key)) {
            $Config | Add-Member -MemberType NoteProperty -Name $key -Value $defaults[$key] -Force
        }
    }
    return $Config
}

function ConvertTo-StringList {
    <# 'a, b;c' | @('a','b') -> @('a','b','c'). Empty input -> @(). #>
    param($Value)
    if ($null -eq $Value) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Value)) {
        foreach ($p in ("$v" -split '[,;\s]+')) {
            if ($p.Trim() -ne '') { $out.Add($p.Trim()) }
        }
    }
    return $out.ToArray()
}

function ConvertTo-CategoryList {
    <# Normalises -Categories input to an int[] limited to 1..6. #>
    param([string[]]$Categories, [int[]]$Allowed = @(1, 2, 3, 4, 5, 6))
    $parsed = @($Categories | ForEach-Object { "$_" -split '[,\s]+' } |
        Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } |
        Where-Object { $Allowed -contains $_ } | Select-Object -Unique)
    if ($parsed.Count -gt 0) { return $parsed }
    return $Allowed
}

function Enable-BeaconTls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'TLS 1.2 enable skipped' }
}

function Get-ClockSkewVerdict {
    <# Kerberos tolerates 5 minutes of skew by default. Pure. #>
    param([double]$OffsetSeconds, [double]$ToleranceSeconds = 300)
    $abs = [math]::Abs($OffsetSeconds)
    if ($abs -le $ToleranceSeconds) { return 'Pass' }
    return 'Warn'
}
