#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Build-WinPEImage.ps1 pure functions. The ADK/DISM parts need a real build host (see docs/getting-started/verify-build.md).

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\Build-WinPEImage.ps1')
    $script:Hashes = @"
0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9 *PowerShell-7.6.6-win-x64.zip
ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100  PowerShell-7.6.6-win-arm64.zip
"@
}

Describe 'Get-ExpectedZipHash' {
    It 'finds the hash for a binary-mode entry' {
        Get-ExpectedZipHash -HashFileText $script:Hashes -FileName 'PowerShell-7.6.6-win-x64.zip' | Should -Be '0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9'
    }
    It 'finds the hash for a text-mode entry and lower-cases it' {
        Get-ExpectedZipHash -HashFileText $script:Hashes.ToUpperInvariant().Replace('POWERSHELL-7.6.6-WIN-ARM64.ZIP', 'PowerShell-7.6.6-win-arm64.zip') -FileName 'PowerShell-7.6.6-win-arm64.zip' | Should -Be 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100'
    }
    It 'returns $null for an unknown file or garbage' {
        Get-ExpectedZipHash -HashFileText $script:Hashes -FileName 'nope.zip' | Should -BeNullOrEmpty
        Get-ExpectedZipHash -HashFileText 'not a hash file' -FileName 'x' | Should -BeNullOrEmpty
    }
    It 'handles CRLF input' {
        Get-ExpectedZipHash -HashFileText ($script:Hashes -replace "`n", "`r`n") -FileName 'PowerShell-7.6.6-win-x64.zip' | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-ResolvedPS7Zip: SHA256 verification' {
    BeforeAll {
        $script:Zip = Join-Path $TestDrive 'PowerShell-7.6.6-win-x64.zip'
        Set-Content $script:Zip 'pretend zip' -NoNewline
        $script:Good = (Get-FileHash $script:Zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Mock Write-Step { }
    }
    It 'accepts a supplied zip whose hash matches, and reports the version from the file name' {
        $r = Get-ResolvedPS7Zip -ProvidedPath $script:Zip -ExpectedSha256 $script:Good
        $r.Verified | Should -BeTrue
        $r.Sha256 | Should -Be $script:Good
        $r.Version | Should -Be '7.6.6'
        $r.Source | Should -Be 'provided'
    }
    It 'is case-insensitive for the expected hash' {
        (Get-ResolvedPS7Zip -ProvidedPath $script:Zip -ExpectedSha256 $script:Good.ToUpperInvariant()).Verified | Should -BeTrue
    }
    It 'throws on a hash mismatch' {
        { Get-ResolvedPS7Zip -ProvidedPath $script:Zip -ExpectedSha256 ('0' * 64) } | Should -Throw '*mismatch*'
    }
    It 'refuses a supplied zip with no expected hash' {
        { Get-ResolvedPS7Zip -ProvidedPath $script:Zip } | Should -Throw '*no expected hash*'
    }
    It 'accepts it unverified only with -AllowUnverified and says so' {
        Mock Write-Warning { }
        $r = Get-ResolvedPS7Zip -ProvidedPath $script:Zip -AllowUnverified
        $r.Verified | Should -BeFalse
        $r.Sha256 | Should -Be $script:Good
        Should -Invoke Write-Warning -ParameterFilter { $Message -match 'UNVERIFIED' }
    }
    It 'downloads, verifies against the release hashes.sha256 and returns the verified zip' {
        $bytes = [Text.Encoding]::ASCII.GetBytes('downloaded zip bytes')
        $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        Mock Invoke-RestMethod {
            [pscustomobject]@{ prerelease = $false; tag_name = 'v7.6.6'; assets = @(
                    [pscustomobject]@{ name = 'PowerShell-7.6.6-win-x64.zip'; browser_download_url = 'https://example.test/ps.zip' },
                    [pscustomobject]@{ name = 'hashes.sha256'; browser_download_url = 'https://example.test/hashes.sha256' }) }
        }
        Mock Invoke-WebRequest {
            if ($Uri -like '*hashes.sha256') { return [pscustomobject]@{ Content = "$sha *PowerShell-7.6.6-win-x64.zip" } }
            [IO.File]::WriteAllBytes($OutFile, $bytes)
        }
        $r = Get-ResolvedPS7Zip -Version '7.6.6'
        $r.Verified | Should -BeTrue
        $r.Source | Should -Be 'github'
        $r.Version | Should -Be '7.6.6'
        $r.Sha256 | Should -Be $sha
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*/releases/tags/v7.6.6' }
        Remove-Item $r.Path -ErrorAction SilentlyContinue
    }
    It 'deletes the download and throws when the hash does not match' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ prerelease = $false; tag_name = 'v7.6.6'; assets = @(
                    [pscustomobject]@{ name = 'PowerShell-7.6.6-win-x64.zip'; browser_download_url = 'https://example.test/ps.zip' },
                    [pscustomobject]@{ name = 'hashes.sha256'; browser_download_url = 'https://example.test/hashes.sha256' }) }
        }
        Mock Invoke-WebRequest {
            if ($Uri -like '*hashes.sha256') { return [pscustomobject]@{ Content = ('a' * 64) + ' *PowerShell-7.6.6-win-x64.zip' } }
            [IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3))
        }
        { Get-ResolvedPS7Zip -Version '7.6.6' } | Should -Throw '*SHA256 mismatch*'
        Test-Path (Join-Path ([IO.Path]::GetTempPath()) 'PowerShell-7.6.6-win-x64.zip') | Should -BeFalse
    }
    It 'refuses a download when the release publishes no hash' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ prerelease = $false; tag_name = 'v7.6.6'; assets = @([pscustomobject]@{ name = 'PowerShell-7.6.6-win-x64.zip'; browser_download_url = 'https://example.test/ps.zip' }) }
        }
        Mock Invoke-WebRequest { throw 'must not download' }
        { Get-ResolvedPS7Zip -Version '7.6.6' } | Should -Throw '*No SHA256 published*'
    }
}

Describe 'ADK / WinPE add-on version expectation' {
    It 'matches a version with the tested prefix' {
        (Test-AdkVersionExpectation -Version '10.1.26100.2454' -ExpectedPrefix '10.1.26100').Ok | Should -BeTrue
    }
    It 'warns for another version and for an unreadable one' {
        (Test-AdkVersionExpectation -Version '10.1.22621.1' -ExpectedPrefix '10.1.26100').Ok | Should -BeFalse
        (Test-AdkVersionExpectation -Version '' -ExpectedPrefix '10.1.26100').Message | Should -Match 'could not be read'
    }
    It 'reads ADK and add-on versions from the uninstall keys' {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = 'Windows Assessment and Deployment Kit'; DisplayVersion = '10.1.26100.2454' },
                [pscustomobject]@{ DisplayName = 'Windows Assessment and Deployment Kit Windows Preinstallation Environment Add-ons'; DisplayVersion = '10.1.26100.2454' },
                [pscustomobject]@{ DisplayName = 'Something else'; DisplayVersion = '1.0' }
            )
        }
        $i = Get-AdkVersionInfo
        $i.AdkVersion | Should -Be '10.1.26100.2454'
        $i.WinPEAddonVersion | Should -Be '10.1.26100.2454'
    }
    It 'returns empty values when nothing is installed' {
        Mock Get-ItemProperty { @() }
        (Get-AdkVersionInfo).AdkVersion | Should -Be ''
    }
    It 'the expected prefix lives in the version file' {
        $script:BeaconAdkExpectation.AdkVersionPrefix | Should -Match '^\d+\.\d+\.\d+$'
    }
}

Describe 'Get-StartnetContent' {
    BeforeAll { $script:Tpl = Get-Content (Join-Path $script:Root 'src\startnet.cmd') -Raw }
    It 'the committed template has the tokens and no vendor text' {
        $script:Tpl | Should -Match '@@BEACON_VERSION@@'
        $script:Tpl | Should -Match '@@BRAND_LINE@@'
        $script:Tpl | Should -Not -Match '(?i)dell|HCS|AX 16G|tierpoint'
        $script:Tpl | Should -Not -Match 'v1\.0\.1'
    }
    It 'replaces the version and removes the brand line when none is set' {
        $o = Get-StartnetContent -Template $script:Tpl -Version '1.1.0'
        $o | Should -Match 'AzL Beacon v1\.1\.0'
        $o | Should -Not -Match '@@'
    }
    It 'adds a sanitised brand line' {
        $o = Get-StartnetContent -Template $script:Tpl -Version '1.1.0' -Brand 'Contoso & Sons | 100%'
        $o | Should -Match 'echo   Contoso \^& Sons \^\| 100%%'
        $o | Should -Not -Match '@@'
    }
    It 'drops non-ASCII characters from the brand' {
        (Get-StartnetContent -Template $script:Tpl -Version '1.1.0' -Brand "Caf$([char]0x00E9) Co") | Should -Match 'echo   Caf Co'
    }
    It 'prefers PowerShell 7 only when it exists and falls back to 5.1 on any failure' {
        $script:Tpl | Should -Match 'if exist X:\\Tools\\PowerShell7\\pwsh\.exe'
        $script:Tpl | Should -Match 'Falling back to Windows PowerShell 5\.1'
        $script:Tpl | Should -Match 'powershell\.exe -NoLogo'
    }
    It 'tells the operator to export results before rebooting' {
        $script:Tpl | Should -Match 'option 8'
    }
}

Describe 'New-BuildManifest' {
    It 'records versions, hashes, drivers and scripts' {
        $m = New-BuildManifest -Facts @{
            Version = '1.1.0'; ReleaseTrain = '12.2609 (latest)'; BuiltUtc = '2026-10-15T10:00:00Z'; GitCommit = 'abc123'
            BuilderPowerShell = '7.6.6'; BuilderOs = 'Windows'; AdkVersion = '10.1.26100.2454'; WinPEAddonVersion = '10.1.26100.2454'
            AdkExpectedPrefix = '10.1.26100'; AdkMatches = $true; PS7Version = '7.6.6'; PS7Sha256 = ('a' * 64); PS7Verified = $true; PS7Source = 'github'
            EnvCheckerVersion = '10.2605.0.2006'; EnvCheckerManifestSha256 = ('b' * 64); EndpointsSha256 = ('c' * 64); EndpointsGeneratedUtc = '2026-10-15T09:00:00Z'
            Scripts = @([pscustomobject]@{ path = 'Start-AzlBeacon.ps1'; sha256 = ('d' * 64) }); Drivers = @([pscustomobject]@{ path = 'x/y.inf'; sha256 = ('e' * 64) })
        }
        $j = $m | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $j.tool.version | Should -Be '1.1.0'
        $j.adk.adkVersion | Should -Be '10.1.26100.2454'
        $j.powershell7.verified | Should -BeTrue
        $j.environmentChecker.version | Should -Be '10.2605.0.2006'
        $j.scripts[0].path | Should -Be 'Start-AzlBeacon.ps1'
        $j.drivers[0].sha256 | Should -Be ('e' * 64)
    }
}

Describe 'Get-FileHashEntries' {
    It 'returns relative forward-slash paths with SHA256 and honours the filter' {
        $d = Join-Path $TestDrive 'h'
        New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force | Out-Null
        Set-Content (Join-Path $d 'a.ps1') 'a'; Set-Content (Join-Path $d 'sub\b.ps1') 'b'; Set-Content (Join-Path $d 'c.txt') 'c'
        $e = Get-FileHashEntries -Root $d -Include @('*.ps1')
        @($e).Count | Should -Be 2
        ($e | ForEach-Object { $_.path }) | Should -Contain 'sub/b.ps1'
        $e[0].sha256 | Should -Match '^[0-9a-f]{64}$'
    }
    It 'returns nothing for a missing folder' {
        @(Get-FileHashEntries -Root (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
}

Describe 'Build script wiring (static)' {
    BeforeAll { $script:B = Get-Content (Join-Path $script:Root 'src\Build-WinPEImage.ps1') -Raw }
    It 'copies lib/, writes build-manifest.json into the image and a sidecar next to the ISO' {
        $script:B | Should -Match "'lib'"
        $script:B | Should -Match 'build-manifest\.json'
        $script:B | Should -Match 'azl-beacon-\$script:BeaconVersion'
    }
    It 'checks the staged Environment Checker module before mounting anything' {
        $script:B.IndexOf('Fail early, before anything is mounted') | Should -BeLessThan $script:B.IndexOf('Step 3: Mounting boot.wim')
    }
    It 'every in-image script exists and every lib file referenced by them exists' {
        foreach ($f in 'Start-AzlValidation.ps1', 'Start-AzlBeacon.ps1', 'Start-NetworkBootstrap.ps1', 'startnet.cmd') {
            Test-Path (Join-Path $script:Root "src\$f") | Should -BeTrue
        }
        $refs = foreach ($f in 'Start-AzlValidation.ps1', 'Start-AzlBeacon.ps1') {
            [regex]::Matches((Get-Content (Join-Path $script:Root "src\$f") -Raw), "'lib\\(Beacon\.[A-Za-z]+\.ps1)'") | ForEach-Object { $_.Groups[1].Value }
        }
        foreach ($r in ($refs | Select-Object -Unique)) { Test-Path (Join-Path $script:Root "src\lib\$r") | Should -BeTrue -Because $r }
    }
    It 'no longer hard-codes a vendor in the build script or startnet' {
        $script:B | Should -Not -Match '(?i)Dell AX|HCS Platform'
    }
    It 'documents the -DriverPath mechanism and the PS7 hash parameters' {
        $script:B | Should -Match '\.PARAMETER PS7ZipSha256'
        $script:B | Should -Match '\.PARAMETER DriverPath'
    }
}
