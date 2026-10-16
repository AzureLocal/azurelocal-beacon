#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Start-AzlBeacon.ps1 (menu) and Start-NetworkBootstrap.ps1 pure parts, banners and stale text.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\Start-AzlBeacon.ps1')
    . (Join-Path $script:Root 'src\Start-NetworkBootstrap.ps1')
    $script:MenuSource = Get-Content (Join-Path $script:Root 'src\Start-AzlBeacon.ps1') -Raw
}

Describe 'helpers' {
    It 'Test-YesAnswer' {
        foreach ($y in 'y', 'Y', 'yes', ' YES ') { Test-YesAnswer $y | Should -BeTrue }
        foreach ($n in '', 'n', 'no', 'maybe', 'yy') { Test-YesAnswer $n | Should -BeFalse }
    }
    It 'Split-InputList trims and drops empties' {
        Split-InputList ' a, b ,, c ' | Should -Be @('a', 'b', 'c')
        @(Split-InputList '').Count | Should -Be 0
    }
    It 'Resolve-MenuChoice accepts one digit only' {
        Resolve-MenuChoice '5' | Should -Be '5'
        Resolve-MenuChoice ' 0 ' | Should -Be '0'
        foreach ($bad in '', 'a', '10', '-1') { Resolve-MenuChoice $bad | Should -Be '' }
    }
    It 'Get-SweepCategories: AD = 1-6, Local Identity = no category 3' {
        Get-SweepCategories 'A' | Should -Be @('1', '2', '3', '4', '5', '6')
        Get-SweepCategories '' | Should -Be @('1', '2', '3', '4', '5', '6')
        Get-SweepCategories 'l' | Should -Be @('1', '2', '4', '5', '6')
        Get-SweepCategories 'L' | Should -Not -Contain '3'
    }
    It 'Get-EngineArguments builds the engine command line' {
        $a = Get-EngineArguments -ScriptPath 'X:\Tools\Start-AzlValidation.ps1' -Categories @('1', '2') -SkipEnvironmentChecker
        $a | Should -Contain '-File'
        $a[$a.IndexOf('-Categories') + 1] | Should -Be '1,2'
        $a | Should -Contain '-SkipEnvironmentChecker'
        $a | Should -Not -Contain '-Redact'
        (Get-EngineArguments -ScriptPath 'x' -Redact) | Should -Contain '-Redact'
    }
}

Describe 'Arc environment hand-over' {
    AfterEach { Clear-ArcEnvironment }
    It 'sets and clears the process variables' {
        Set-ArcEnvironment -Subscription 'sub' -Tenant 't' -ResourceGroup 'rg' -Nodes @('n1', 'n2')
        $env:BEACON_ARC_SUBSCRIPTION | Should -Be 'sub'
        $env:BEACON_ARC_NODES | Should -Be 'n1,n2'
        Clear-ArcEnvironment
        $env:BEACON_ARC_SUBSCRIPTION | Should -BeNullOrEmpty
        $env:BEACON_ARC_RG | Should -BeNullOrEmpty
    }
    It 'Invoke-ArcValidation clears the variables even when the engine throws' {
        Mock Read-Host { 'value' }
        Mock Invoke-ValidationEngine { throw 'engine crashed' }
        { Invoke-ArcValidation 6>$null } | Should -Throw
        $env:BEACON_ARC_SUBSCRIPTION | Should -BeNullOrEmpty
    }
    It 'Invoke-ArcValidation runs only category 6' {
        Mock Read-Host { 'value' }
        Mock Invoke-ValidationEngine { }
        Invoke-ArcValidation 6>$null
        Should -Invoke Invoke-ValidationEngine -ParameterFilter { ($Categories -join ',') -eq '6' }
    }
}

Describe 'menu paths call the engine with the right categories' {
    BeforeEach {
        Mock Invoke-ValidationEngine { }
        Mock Write-ValidationConfigOverrides { }
        Mock Invoke-PostRunPrompt { }
        Mock Write-BeaconHeader { }
        Mock Write-BeaconLine { }
        Mock Read-Host { 'n' }
    }
    It 'Active Directory path: 1-5, never 6 unless asked' {
        Mock Read-RequiredInput { 'corp.example.com' }
        Mock Read-OptionalInput { '' }
        Invoke-ADMenu
        Should -Invoke Invoke-ValidationEngine -ParameterFilter { ($Categories -join ',') -eq '1,2,3,4,5' } -Times 1
    }
    It 'Local Identity path: 1,2,4,5 and the Key Vault name goes to the config' {
        Mock Read-RequiredInput { '192.0.2.10' }
        Mock Read-OptionalInput { 'kv-example.vault.azure.net' }
        Invoke-LocalIdentityMenu
        Should -Invoke Invoke-ValidationEngine -ParameterFilter { ($Categories -join ',') -eq '1,2,4,5' } -Times 1
        Should -Invoke Write-ValidationConfigOverrides -ParameterFilter { $Overrides.keyVaultFqdn -eq 'kv-example.vault.azure.net' -and $Overrides.adDomainFqdn -eq '' }
    }
    It 'Networking path uses the bootstrap gateway and DNS' {
        Mock Read-OptionalInput { '' }
        Invoke-NetworkFirewallMenu -NetworkState @{ GatewayIp = '192.0.2.1'; DnsServer = '192.0.2.10' }
        Should -Invoke Invoke-ValidationEngine -ParameterFilter { ($Categories -join ',') -eq '1,2,4,5' }
        Should -Invoke Write-ValidationConfigOverrides -ParameterFilter { $Overrides.managementGateway -eq '192.0.2.1' -and $Overrides.dnsServers -contains '192.0.2.10' }
    }
    It 'Full sweep, AD path without Arc: 1-5 then no Arc prompt run' {
        Mock Read-MenuInput { 'A' } -ParameterFilter { $Prompt -like 'Path*' }
        Mock Read-MenuInput { 'n' } -ParameterFilter { $Prompt -notlike 'Path*' }
        Invoke-FullSweep
        Should -Invoke Invoke-ValidationEngine -ParameterFilter { ($Categories -join ',') -eq '1,2,3,4,5' }
    }
    It 'Full sweep, Local Identity path: no category 3' {
        Mock Read-MenuInput { 'L' } -ParameterFilter { $Prompt -like 'Path*' }
        Mock Read-MenuInput { 'n' } -ParameterFilter { $Prompt -notlike 'Path*' }
        Invoke-FullSweep
        Should -Invoke Invoke-ValidationEngine -ParameterFilter { ($Categories -join ',') -eq '1,2,4,5' }
    }
}

Describe 'banner and menu text has no stale or vendor-specific content' {
    It 'banner shows the single product version and release train, no vendor branding' {
        $b = (Get-BannerLines) -join "`n"
        $b | Should -Match ([regex]::Escape("v$script:BeaconVersion"))
        $b | Should -Match '12\.2609 \(latest\)'
        $b | Should -Not -Match '(?i)dell|HCS Platform|AX 16G|tier[p]oint'
    }
    It 'banner can show an optional brand line' {
        ((Get-BannerLines -Brand 'Contoso Labs') -join "`n") | Should -Match 'Contoso Labs'
    }
    It 'menu offers 0-9 and says 6 categories' {
        $m = (Get-MainMenuLines) -join "`n"
        foreach ($d in 0..9) { $m | Should -Match "$d\)" }
        $m | Should -Match 'all 6 categories'
    }
    It 'has none of the old wrong wording' {
        $script:MenuSource | Should -Not -Match 'Category 4 AD port'
        $script:MenuSource | Should -Not -Match 'Cat 6/7|Category 7|7 categories'
        $script:MenuSource | Should -Not -Match 'v1\.0\.1'
        $script:MenuSource | Should -Not -Match '(?i)Dell AX|HCS Platform'
        $script:MenuSource | Should -Match 'Category 3 AD port tests'
        $script:MenuSource | Should -Match 'skips Category 3'
    }
    It 'every menu line is ASCII and the same width' {
        $lines = Get-MainMenuLines
        foreach ($l in $lines) { $l | Should -Match '^[\x20-\x7E]+$' }
        @($lines | ForEach-Object { $_.Length } | Select-Object -Unique).Count | Should -Be 1
    }
    It 'the menu loop handles every choice the menu prints' {
        foreach ($d in 0..9) { $script:MenuSource | Should -Match "'$d' \{" }
    }
}

Describe 'Start-NetworkBootstrap validation helpers' {
    It 'Test-Ipv4Address' {
        foreach ($ok in '192.0.2.10', '0.0.0.0', '255.255.255.255') { Test-Ipv4Address $ok | Should -BeTrue }
        foreach ($bad in '', '256.1.1.1', '1.2.3', '1.2.3.4.5', 'a.b.c.d', '1.2.3.-4') { Test-Ipv4Address $bad | Should -BeFalse }
    }
    It 'Test-SubnetMask accepts contiguous masks only' {
        foreach ($ok in '255.255.255.0', '255.255.0.0', '255.255.254.0', '255.255.255.252', '128.0.0.0') { Test-SubnetMask $ok | Should -BeTrue }
        foreach ($bad in '255.0.255.0', '0.0.0.0', '255.255.255.1', '1.2.3', 'x') { Test-SubnetMask $bad | Should -BeFalse -Because $bad }
    }
    It 'the bootstrap refuses to apply invalid input' {
        (Get-Content (Join-Path $script:Root 'src\Start-NetworkBootstrap.ps1') -Raw) | Should -Match 'Invalid address, mask, gateway or DNS entry'
    }
}
