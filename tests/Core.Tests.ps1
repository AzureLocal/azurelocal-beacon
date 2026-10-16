#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Common helpers, endpoint selection, Environment Checker mapping.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    foreach ($f in 'Beacon.Version', 'Beacon.Common', 'Beacon.Net', 'Beacon.Endpoints', 'Beacon.EnvChecker') {
        . (Join-Path $script:Root "src\lib\$f.ps1")
    }
    $script:Data = Get-Content (Join-Path $script:Root 'src\config\endpoints.json') -Raw | ConvertFrom-Json
    $script:Config = Get-Content (Join-Path $script:Root 'src\config\validation-config.example.json') -Raw | ConvertFrom-Json
}

Describe 'Version' {
    It 'is one semantic version 1.1.0' {
        $script:BeaconVersion | Should -Match '^\d+\.\d+\.\d+$'
        $script:BeaconVersion | Should -Be '1.1.0'
    }
    It 'names the release train as 12.2609 (latest) and never the private build' {
        $script:BeaconReleaseTrain | Should -Be '12.2609 (latest)'
    }
}

Describe 'ConvertTo-StringList' {
    It 'splits on commas, semicolons and spaces' {
        ConvertTo-StringList 'a, b;c  d' | Should -Be @('a', 'b', 'c', 'd')
    }
    It 'handles arrays, nulls and empty input' {
        ConvertTo-StringList @('a,b', 'c') | Should -Be @('a', 'b', 'c')
        @(ConvertTo-StringList $null).Count | Should -Be 0
        @(ConvertTo-StringList '').Count | Should -Be 0
    }
}

Describe 'ConvertTo-CategoryList' {
    It 'defaults to all six categories' {
        ConvertTo-CategoryList -Categories @() | Should -Be @(1, 2, 3, 4, 5, 6)
    }
    It 'parses comma and space separated input and drops invalid numbers' {
        ConvertTo-CategoryList -Categories @('1,2', '4 7', 'x', '9') | Should -Be @(1, 2, 4)
    }
    It 'falls back to all when nothing valid remains' {
        ConvertTo-CategoryList -Categories @('9', 'x') | Should -Be @(1, 2, 3, 4, 5, 6)
    }
}

Describe 'Resolve-ConfigDefaults' {
    It 'adds every optional field so StrictMode never throws' {
        $c = Resolve-ConfigDefaults -Config ([pscustomobject]@{ clusterName = 'x' })
        foreach ($n in 'managementGateway', 'nodeIps', 'dnsServers', 'adDomainFqdn', 'dcIps', 'azureRegion', 'oem', 'arcGatewayFqdn', 'proxyUrl', 'proxyBypass', 'ntpServers', 'keyVaultFqdn', 'tlsInspectionHosts') {
            $c.PSObject.Properties.Name | Should -Contain $n
        }
        $c.clusterName | Should -Be 'x'
    }
    It 'does not overwrite values that exist' {
        (Resolve-ConfigDefaults -Config ([pscustomobject]@{ azureRegion = 'japaneast' })).azureRegion | Should -Be 'japaneast'
    }
}

Describe 'validation-config.example.json' {
    It 'is valid JSON with example (non-routable) addresses only' {
        $raw = Get-Content (Join-Path $script:Root 'src\config\validation-config.example.json') -Raw
        { $raw | ConvertFrom-Json } | Should -Not -Throw
        $ips = [regex]::Matches($raw, '\b(?:\d{1,3}\.){3}\d{1,3}\b') | ForEach-Object { $_.Value }
        foreach ($ip in $ips) { $ip | Should -Match '^192\.0\.2\.' }
    }
    It 'carries no tenant, subscription or lab data' {
        $raw = Get-Content (Join-Path $script:Root 'src\config\validation-config.example.json') -Raw
        $raw | Should -Not -Match '(?i)tier[p]oint|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }
    It 'region is one the endpoint data knows' {
        (ConvertTo-BeaconRegionKey $script:Config.azureRegion) | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertTo-BeaconRegionKey' {
    It '<Name> -> <Key>' -ForEach @(
        @{ Name = 'East US'; Key = 'eastus' }, @{ Name = 'eastus'; Key = 'eastus' }, @{ Name = ' WESTEUROPE '; Key = 'westeurope' },
        @{ Name = 'Australia East'; Key = 'australiaeast' }, @{ Name = 'Canada Central'; Key = 'canadacentral' },
        @{ Name = 'India Central'; Key = 'centralindia' }, @{ Name = 'central india'; Key = 'centralindia' },
        @{ Name = 'Southeast Asia'; Key = 'southeastasia' }, @{ Name = 'Japan East'; Key = 'japaneast' },
        @{ Name = 'South Central US'; Key = 'southcentralus' }, @{ Name = 'US Gov Virginia'; Key = 'usgovvirginia' },
        @{ Name = 'mars'; Key = '' }, @{ Name = ''; Key = '' }
    ) { ConvertTo-BeaconRegionKey $Name | Should -Be $Key }
}

Describe 'Get-BeaconEndpointSet' {
    It 'returns the requested region list' {
        $s = Get-BeaconEndpointSet -Data $script:Data -Region 'West Europe'
        $s.Region | Should -Be 'westeurope'
        $s.FellBack | Should -BeFalse
        ($s.Endpoints | ForEach-Object { $_.host }) | Should -Contain 'weu.his.arc.azure.com'
        ($s.Endpoints | ForEach-Object { $_.host }) | Should -Not -Contain 'eus.his.arc.azure.com'
    }
    It 'falls back to eastus for an unknown or empty region and says so' {
        (Get-BeaconEndpointSet -Data $script:Data -Region 'mars').FellBack | Should -BeTrue
        (Get-BeaconEndpointSet -Data $script:Data -Region '').Region | Should -Be 'eastus'
    }
    It 'appends the OEM list only when requested' {
        $without = Get-BeaconEndpointSet -Data $script:Data -Region 'eastus'
        $with = Get-BeaconEndpointSet -Data $script:Data -Region 'eastus' -Oem 'Dell'
        $with.Endpoints.Count | Should -BeGreaterThan $without.Endpoints.Count
        ($with.Endpoints | ForEach-Object { $_.host }) | Should -Contain 'downloads.dell.com'
        ($without.Endpoints | ForEach-Object { $_.host }) | Should -Not -Contain 'downloads.dell.com'
    }
    It 'ignores an unknown OEM' {
        (Get-BeaconEndpointSet -Data $script:Data -Region 'eastus' -Oem 'nobody').Endpoints.Count | Should -Be (Get-BeaconEndpointSet -Data $script:Data -Region 'eastus').Endpoints.Count
    }
    It 'reports the sovereign cloud for US Gov Virginia' {
        (Get-BeaconEndpointSet -Data $script:Data -Region 'usgovvirginia').Cloud | Should -Be 'AzureUSGovernment'
    }
    It 'lists region keys' {
        (Get-BeaconRegionKeys $script:Data).Count | Should -Be 9
    }
}

Describe 'Get-PublicIpCheckTargets' {
    It 'finds the Arc endpoints that must resolve publicly' {
        $t = Get-PublicIpCheckTargets -Endpoints (Get-BeaconEndpointSet -Data $script:Data -Region 'eastus').Endpoints
        $t | Should -Contain 'gbl.his.arc.azure.com'
        $t | Should -Contain 'eus.his.arc.azure.com'
        $t | Should -Contain 'eastus.dp.kubernetesconfiguration.azure.com'
        $t | Should -Contain 'agentserviceapi.guestconfiguration.azure.com'
    }
    It 'skips wildcards and placeholders' {
        $t = Get-PublicIpCheckTargets -Endpoints @([pscustomobject]@{ host = '*.his.arc.azure.com'; wildcard = $true; placeholder = '' })
        @($t).Count | Should -Be 0
    }
}

Describe 'Resolve-EnvCheckerManifest' {
    It 'resolves the version sub folder of the vendored module (the real layout)' {
        $m = Resolve-EnvCheckerManifest -Roots @(Join-Path $script:Root 'tools\modules\AzStackHci.EnvironmentChecker')
        $m | Should -Match '10\.2605\.0\.2006[\\/]AzStackHci\.EnvironmentChecker\.psd1$'
        Test-Path $m | Should -BeTrue
    }
    It 'picks the highest version when several exist' {
        $d = Join-Path $TestDrive 'mod'
        foreach ($v in '1.2.0', '1.10.0', '1.9.0') { New-Item -ItemType Directory -Path (Join-Path $d $v) -Force | Out-Null; Set-Content (Join-Path $d "$v\AzStackHci.EnvironmentChecker.psd1") '@{}' }
        (Resolve-EnvCheckerManifest -Roots @($d)) | Should -Match '1\.10\.0'
    }
    It 'accepts a root that is already a version folder' {
        $d = Join-Path $TestDrive 'flat'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content (Join-Path $d 'AzStackHci.EnvironmentChecker.psd1') '@{}'
        (Resolve-EnvCheckerManifest -Roots @($d)) | Should -Be (Join-Path $d 'AzStackHci.EnvironmentChecker.psd1')
    }
    It 'returns $null when nothing is found' {
        Resolve-EnvCheckerManifest -Roots @('Z:\nope', (Join-Path $TestDrive 'empty')) | Should -BeNullOrEmpty
    }
    It 'searches the in-image path X:\Tools\Modules last' {
        @(Get-EnvCheckerModuleRoots -ScriptRoot 'C:\Tools')[-1] | Should -Be 'X:\Tools\Modules\AzStackHci.EnvironmentChecker'
    }
}

Describe 'ConvertFrom-EnvCheckerResult' {
    It 'maps statuses and severities and keeps name, target, remediation' {
        $raw = @(
            [pscustomobject]@{ Name = 'AzStackHci_Connectivity_a'; Status = 'SUCCESS'; Severity = 'CRITICAL'; Description = 'ok'; Remediation = ''; TargetResourceName = 'a.example.com' }
            [pscustomobject]@{ Name = 'AzStackHci_Connectivity_b'; Status = 'FAILURE'; Severity = 'CRITICAL'; Description = 'blocked'; Remediation = 'https://aka.ms/x'; TargetResourceName = 'b.example.com' }
            [pscustomobject]@{ Name = 'AzStackHci_Connectivity_c'; Status = 'FAILURE'; Severity = 'WARNING'; Description = 'slow'; Remediation = ''; TargetResourceName = 'c.example.com' }
        )
        # the module reports 'Succeeded' / 'Failed' in some validators; both spellings must work
        $raw[0].Status = 'Succeeded'; $raw[1].Status = 'Failed'; $raw[2].Status = 'Failed'
        $m = ConvertFrom-EnvCheckerResult -Results $raw -Category 'Cat-5-EnvChecker' -Prefix 'Connectivity'
        $m.Count | Should -Be 3
        $m[0].Status | Should -Be 'Pass'
        $m[1].Status | Should -Be 'Fail'
        $m[1].Severity | Should -Be 'critical'
        $m[1].Remediation | Should -Be 'https://aka.ms/x'
        $m[1].Target | Should -Be 'b.example.com'
        $m[1].Name | Should -Be 'Connectivity-AzStackHci_Connectivity_b'
        $m[2].Status | Should -Be 'Warn'
        $m[2].Severity | Should -Be 'warning'
    }
    It 'tolerates null and sparse objects' {
        @(ConvertFrom-EnvCheckerResult -Results @($null, [pscustomobject]@{ Name = 'x' }) -Category 'c').Count | Should -Be 1
        @(ConvertFrom-EnvCheckerResult -Results @([pscustomobject]@{ Name = 'x' }) -Category 'c')[0].Status | Should -Be 'Skip'
    }
    It 'produces splat tables Add-ValidationResult accepts' {
        $m = @(ConvertFrom-EnvCheckerResult -Results @([pscustomobject]@{ Name = 'x'; Status = 'Failed'; Severity = 'CRITICAL' }) -Category 'Cat-5')
        $script:AllResults = New-Object System.Collections.Generic.List[object]
        { $h = $m[0]; Add-ValidationResult @h 6>$null } | Should -Not -Throw
        $script:AllResults.Count | Should -Be 1
    }
}

Describe 'Get-EnvCheckerConnectivityParameters' {
    It 'passes region, PassThru and local definitions by default' {
        $p = Get-EnvCheckerConnectivityParameters -Config (Resolve-ConfigDefaults ([pscustomobject]@{})) -RegionKey 'westeurope'
        $p.RegionName | Should -Be 'westeurope'
        $p.PassThru | Should -BeTrue
        $p.UseLocalDefinitionsOnly | Should -BeTrue
        $p.ContainsKey('Proxy') | Should -BeFalse
        $p.ContainsKey('ARCGateway') | Should -BeFalse
    }
    It 'adds proxy and the Arc gateway switch from config' {
        $c = Resolve-ConfigDefaults ([pscustomobject]@{ proxyUrl = 'http://proxy.example.com:8080'; arcGatewayFqdn = 'abc.gw.arc.azure.com' })
        $p = Get-EnvCheckerConnectivityParameters -Config $c -RegionKey 'eastus'
        $p.Proxy | Should -Be 'http://proxy.example.com:8080'
        $p.ARCGateway | Should -BeTrue
    }
    It 'uses only parameters that the vendored Invoke-AzStackHciConnectivityValidation declares' {
        $src = Get-Content (Join-Path $script:Root 'tools\modules\AzStackHci.EnvironmentChecker\10.2605.0.2006\AzStackHciConnectivity\AzStackHci.Connectivity.psm1') -Raw
        $c = Resolve-ConfigDefaults ([pscustomobject]@{ proxyUrl = 'http://p:1'; arcGatewayFqdn = 'x.gw.arc.azure.com' })
        foreach ($k in (Get-EnvCheckerConnectivityParameters -Config $c -RegionKey 'eastus' -OutputPath 'C:\x').Keys) {
            $src | Should -Match ('\$' + $k + '\b') -Because "parameter -$k must exist in the module"
        }
    }
}

Describe 'Get-EnvCheckerNetworkParameters' {
    It 'cannot run without the real inputs and says what is missing' {
        $r = Get-EnvCheckerNetworkParameters -Config (Resolve-ConfigDefaults ([pscustomobject]@{}))
        $r.CanRun | Should -BeFalse
        $r.Reason | Should -Match 'infraIpPools'
        $r.Reason | Should -Match 'hostNetworkIntents'
    }
    It 'builds the EceParameter set from config' {
        $c = Resolve-ConfigDefaults ([pscustomobject]@{
                infraIpPools = @([pscustomobject]@{ StartingAddress = '192.0.2.100'; EndingAddress = '192.0.2.110' })
                managementSubnetCidr = '192.0.2.0/24'
                hostNetworkIntents = @([pscustomobject]@{ Name = 'Management'; TrafficType = @('Management') })
                nodeIps = @('192.0.2.21', '192.0.2.22')
            })
        $r = Get-EnvCheckerNetworkParameters -Config $c
        $r.CanRun | Should -BeTrue
        $r.Parameters.NodesInCluster | Should -Be 2
        $r.Parameters.ManagementSubnetValue | Should -Be '192.0.2.0/24'
        $r.Parameters.IpPools[0].StartingAddress | Should -Be '192.0.2.100'
        $r.Parameters.AtcHostIntents.Count | Should -Be 1
    }
    It 'matches the parameter names of the vendored Invoke-AzStackHciNetworkValidation' {
        $src = Get-Content (Join-Path $script:Root 'tools\modules\AzStackHci.EnvironmentChecker\10.2605.0.2006\AzStackHciNetwork\AzStackHci.Network.psm1') -Raw
        foreach ($k in 'IpPools', 'ManagementSubnetValue', 'NodesInCluster', 'AtcHostIntents', 'PassThru', 'PSSession') {
            $src | Should -Match ('\$' + $k + '\b')
        }
    }
}

Describe 'Update-BeaconModules lock' {
    BeforeAll { . (Join-Path $script:Root 'scripts\Update-BeaconModules.ps1') }
    It 'pins the committed module version and manifest hash' {
        $lock = Get-ModuleLock -LockPath (Join-Path $script:Root 'tools\modules\modules.lock.json')
        $lock.version | Should -Be '10.2605.0.2006'
        (Test-ModuleLockMatch -Root (Join-Path $script:Root 'tools\modules') -Entry $lock).Ok | Should -BeTrue
    }
    It 'detects a hash mismatch and an unpinned extra version' {
        $root = Join-Path $TestDrive 'modroot'
        $dir = Join-Path $root 'AzStackHci.EnvironmentChecker\1.0.0'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'AzStackHci.EnvironmentChecker\0.9.0') -Force | Out-Null
        Set-Content (Join-Path $dir 'AzStackHci.EnvironmentChecker.psd1') 'x'
        $r = Test-ModuleLockMatch -Root $root -Entry ([pscustomobject]@{ version = '1.0.0'; manifestSha256 = ('0' * 64) })
        $r.Ok | Should -BeFalse
        ($r.Problems -join ' ') | Should -Match 'differs from lock'
        ($r.Problems -join ' ') | Should -Match 'extra version'
    }
    It 'flags an unsigned file as not Valid' {
        $d = Join-Path $TestDrive 'unsigned'
        New-Item -ItemType Directory -Path $d | Out-Null
        Set-Content (Join-Path $d 'a.ps1') 'Write-Output 1'
        (Test-ModuleSignature -Path $d).Ok | Should -BeFalse
    }
    It 'accepts the genuinely signed vendored manifest' {
        $f = Join-Path $script:Root 'tools\modules\AzStackHci.EnvironmentChecker\10.2605.0.2006\AzStackHci.EnvironmentChecker.psd1'
        $sig = Get-AuthenticodeSignature -FilePath $f
        $sig.Status | Should -Be 'Valid'
        $sig.SignerCertificate.Subject | Should -Match 'O=Microsoft Corporation'
    }
}
