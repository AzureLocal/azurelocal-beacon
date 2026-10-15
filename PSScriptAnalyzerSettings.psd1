@{
    # Used by CI (.github/workflows/ci.yml) and by: Invoke-ScriptAnalyzer -Path src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The menu is an interactive console UI for WinPE; Write-Host is the intended output channel there.
        'PSAvoidUsingWriteHost',
        # Internal helper names (Add-/Set-/Clear-/Save-) change in-memory or RAM-drive state of a boot session only.
        'PSUseShouldProcessForStateChangingFunctions',
        # Results/Endpoints/Categories are collective nouns on purpose.
        'PSUseSingularNouns',
        # Dot-sourced libraries share $script: state by design.
        'PSAvoidGlobalVars'
    )
    Rules        = @{
        # In-image scripts must run on Windows PowerShell 5.1 (WinPE). Applied to src/ by CI; build scripts need 7.4.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
