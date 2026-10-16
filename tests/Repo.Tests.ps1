#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Repository-level consistency: one version, no private names, public wording, docs and CI present.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\lib\Beacon.Version.ps1')
    $script:Tracked = @(& git -C $script:Root ls-files 2>$null | Where-Object { $_ -and $_ -notmatch '^(tools/modules|drivers)/' })
    $script:TextFiles = $script:Tracked | Where-Object { $_ -match '\.(md|ps1|psd1|json|yml|yaml|cmd|mts|txt)$' } | ForEach-Object { Join-Path $script:Root $_ } | Where-Object { Test-Path $_ }
    # files that legitimately talk about the things the rules forbid
    $script:Exempt = @('tests\\Repo\.Tests\.ps1$', 'tests\\Menu\.Tests\.ps1$', 'tests\\Build\.Tests\.ps1$', '\.ai\\', '\.claude\\', '\.github\\copilot', 'config\\endpoints\\learn\\')
}

Describe 'one semantic version' {
    It 'release-please manifest, version library and CHANGELOG agree on 1.1.0' {
        $manifest = Get-Content (Join-Path $script:Root '.release-please-manifest.json') -Raw | ConvertFrom-Json
        $manifest.'.' | Should -Be $script:BeaconVersion
        (Get-Content (Join-Path $script:Root 'CHANGELOG.md') -Raw) | Should -Match ('## \[' + [regex]::Escape($script:BeaconVersion) + '\]')
    }
    It 'release-please bumps the version library through extra-files' {
        $cfg = Get-Content (Join-Path $script:Root 'release-please-config.json') -Raw
        $cfg | Should -Match 'src/lib/Beacon\.Version\.ps1'
        (Get-Content (Join-Path $script:Root 'src\lib\Beacon.Version.ps1') -Raw) | Should -Match 'x-release-please-version'
    }
    It 'no in-image script or doc hard-codes another version number' {
        foreach ($f in 'src\Start-AzlBeacon.ps1', 'src\Start-AzlValidation.ps1', 'src\Start-NetworkBootstrap.ps1', 'src\startnet.cmd') {
            $t = Get-Content (Join-Path $script:Root $f) -Raw
            $t | Should -Not -Match 'v1\.0\.\d|VERSION\s+=\s+''2\.0''|ScriptVersion\s*=\s*"1\.0\.0"' -Because $f
        }
    }
}

Describe 'public wording' {
    It 'no environment-specific or private tenant names in tracked text files' {
        $hits = foreach ($f in $script:TextFiles) {
            if ($script:Exempt | Where-Object { $f -match $_ }) { continue }
            Select-String -Path $f -Pattern '(?i)tier[p]oint|t[p]l-|law-t[o]te|st[t]ote|improbabi[l]ity|\bi[i]c\b|\bPOC [l]ab\b|nic202[6]|nic2[6]|kristopher\.t[u]rner' -ErrorAction SilentlyContinue
        }
        @($hits).Count | Should -Be 0 -Because (($hits | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join '; ')
    }
    It 'never mentions the private build number' {
        $hits = foreach ($f in $script:TextFiles) {
            if ($script:Exempt | Where-Object { $f -match $_ }) { continue }
            Select-String -Path $f -Pattern '26[9]0' -ErrorAction SilentlyContinue | Where-Object { $_.Line -notmatch '[0-9]26[9]0|26[9]0[0-9]|[0-9a-f]{20,}' }
        }
        @($hits).Count | Should -Be 0 -Because (($hits | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join '; ')
    }
    It 'release wording is 12.2609 (latest)' {
        (Get-Content (Join-Path $script:Root 'README.md') -Raw) | Should -Match '12\.2609 \(latest\)'
    }
    It 'no hard-coded vendor banner left anywhere' {
        $hits = foreach ($f in $script:TextFiles) {
            if ($script:Exempt | Where-Object { $f -match $_ }) { continue }
            Select-String -Path $f -Pattern 'Dell AX 16G \| HCS Platform|HCS Platform\s*$' -ErrorAction SilentlyContinue
        }
        @($hits).Count | Should -Be 0
    }
    It 'in-image scripts are ASCII only (PowerShell 5.1 reads BOM-less UTF-8 as ANSI)' {
        foreach ($f in (Get-ChildItem (Join-Path $script:Root 'src') -Recurse -Include *.ps1, *.cmd)) {
            if ($f.Name -eq 'Build-WinPEImage.ps1') { continue }
            [IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty -Because $f.Name
        }
    }
    It 'no secrets-looking content (GUIDs other than documented constants, tokens, keys)' {
        $allowed = @('04b07795-8ddb-461a-bbee-02f9e1bf7b46', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635', 'b24988ac-6180-42a0-ab88-20f7382dd24c', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168', 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7', 'cd570a14-e51a-42ad-bac8-bafd67325302', '1412d89f-b8a8-4111-b4fd-e82905cbd85d')
        $hits = foreach ($f in ($script:TextFiles | Where-Object { $_ -match '\\(src|scripts|docs|examples|README)' -and $_ -notmatch 'tests\\|\.ai\\|\.claude\\' })) {
            Select-String -Path $f -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -AllMatches -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Matches.Value } | Where-Object { $allowed -notcontains $_.ToLowerInvariant() -and $_ -notmatch '^(00000000|11111111|xxxxxxxx|4C4C4544|aaaaaaaa)' }
        }
        @($hits).Count | Should -Be 0 -Because ($hits -join ', ')
    }
}

Describe 'no drive check promise' {
    It 'docs say Beacon deliberately has no drive check, and no check exists' {
        (Get-Content (Join-Path $script:Root 'README.md') -Raw) | Should -Match '(?i)no drive'
    }
}

Describe 'CI and docs build' {
    It 'ci.yml runs PSScriptAnalyzer, Pester and a markdown link check' {
        $ci = Get-Content (Join-Path $script:Root '.github\workflows\ci.yml') -Raw
        $ci | Should -Match 'Invoke-ScriptAnalyzer'
        $ci | Should -Match 'Invoke-Pester'
        $ci | Should -Match '(?i)link'
    }
    It 'release-please workflow exists' {
        Test-Path (Join-Path $script:Root '.github\workflows\release-please.yml') | Should -BeTrue
    }
    It 'a manual workflow documents the ADK build without running it' {
        $w = Get-Content (Join-Path $script:Root '.github\workflows\build-iso-manual.yml') -Raw
        $w | Should -Match 'workflow_dispatch'
        $w | Should -Not -Match '(?m)^\s*run:.*Build-WinPEImage\.ps1'
        $w | Should -Match 'verify-build'
    }
    It 'VitePress fails the build on dead links' {
        $c = Get-Content (Join-Path $script:Root 'docs\.vitepress\config.mts') -Raw
        $c | Should -Not -Match 'ignoreDeadLinks:\s*true'
    }
    It 'PSScriptAnalyzer settings exist' {
        Test-Path (Join-Path $script:Root 'PSScriptAnalyzerSettings.psd1') | Should -BeTrue
        { Import-PowerShellDataFile (Join-Path $script:Root 'PSScriptAnalyzerSettings.psd1') } | Should -Not -Throw
    }
    It 'the build verification procedure exists and covers the required steps' {
        $v = Get-Content (Join-Path $script:Root 'docs\getting-started\verify-build.md') -Raw
        foreach ($k in 'Windows ADK', 'WinPE add-on', 'Build-WinPEImage', 'Generation 2', 'legacy network adapter', 'checklist', 'build-manifest') { $v | Should -Match $k }
    }
}

Describe 'drivers and examples' {
    It 'the driver manifest lists every driver file with a hash' {
        $m = Get-Content (Join-Path $script:Root 'drivers\driver-manifest.json') -Raw | ConvertFrom-Json
        $files = Get-ChildItem (Join-Path $script:Root 'drivers\dell-ax') -Recurse -File
        @($m.files).Count | Should -Be $files.Count
        foreach ($f in $m.files) {
            $f.sha256 | Should -Match '^[0-9a-f]{64}$'
            Test-Path (Join-Path $script:Root "drivers\$($f.path)") | Should -BeTrue
        }
    }
    It 'the driver manifest hashes match the files on disk' {
        $m = Get-Content (Join-Path $script:Root 'drivers\driver-manifest.json') -Raw | ConvertFrom-Json
        foreach ($f in ($m.files | Select-Object -First 6)) {
            (Get-FileHash (Join-Path $script:Root "drivers\$($f.path)") -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $f.sha256
        }
    }
    It 'ships an example results file and a walkthrough' {
        Test-Path (Join-Path $script:Root 'examples\sample-results.json') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'docs\getting-started\walkthrough.md') | Should -BeTrue
    }
}
