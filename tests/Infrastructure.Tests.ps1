#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# infrastructure.yml (azurelocal-toolkit registry, schema 5) -> Beacon's validation config, results folder and context.
# Fixture: tests/fixtures/infrastructure.example.json is the toolkit's config/variables/examples/infrastructure.example.yml
# as JSON (no YAML module needed). With AZL_TOOLKIT_ROOT and powershell-yaml the live toolkit examples are read too.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    foreach ($f in 'Beacon.Version', 'Beacon.Common', 'Beacon.Results', 'Beacon.Infrastructure') { . (Join-Path $script:Root "src\lib\$f.ps1") }
    $script:FixturePath = Join-Path $PSScriptRoot 'fixtures\infrastructure.example.json'
    $script:SchemaPath = Join-Path $script:Root 'docs\reference\results.schema.json'
    function script:Get-Fixture { Get-Content $script:FixturePath -Raw | ConvertFrom-Json }
}

Describe 'ConvertTo-BeaconValidationConfig' {
    BeforeAll { $script:Cfg = ConvertTo-BeaconValidationConfig -Infrastructure (Get-Fixture) }

    It 'takes every engagement value from its registry key' {
        $c = $script:Cfg
        $c.azureRegion | Should -Be 'eastus'
        $c.dnsServers | Should -Be @('192.0.2.4', '192.0.2.5')
        $c.ntpServers | Should -Be @('192.0.2.4', '192.0.2.5')
        $c.adDomainFqdn | Should -Be 'improbability.cloud'
        $c.adNetbios | Should -Be 'IIC'
        $c.dcIps | Should -Be @('192.0.2.4', '192.0.2.5')
        $c.managementGateway | Should -Be '192.0.2.1'
        $c.managementSubnetCidr | Should -Be '192.0.2.0/24'
        $c.managementVlan | Should -Be 0
        $c.nodeIps | Should -Be @('192.0.2.11', '192.0.2.12')
        $c.nodeFqdns | Should -Be @('iic-azl-n01.improbability.cloud', 'iic-azl-n02.improbability.cloud')
        $c.keyVaultName | Should -Be 'kv-iic-azl-01'
        $c.keyVaultFqdn | Should -Be 'kv-iic-azl-01.vault.azure.net'
        $c.clusterName | Should -Be 'iic-azl-01'
        $c.infraIpPools[0].StartingAddress | Should -Be '192.0.2.20'
        $c.infraIpPools[0].EndingAddress | Should -Be '192.0.2.29'
        $c.arcResourceGroup | Should -Be 'rg-iic-azl-01'
        $c.arcNodeNames | Should -Be @('iic-azl-n01', 'iic-azl-n02')
        $c.oem | Should -Be 'dell'
    }

    It 'maps the Network ATC intents to the Environment Checker shape' {
        $i = @($script:Cfg.hostNetworkIntents)
        $i.Count | Should -Be 2
        ($i | Where-Object Name -eq 'compute_storage').TrafficType | Should -Be @('Compute', 'Storage')
        ($i | Where-Object Name -eq 'management').Adapter | Should -Be @('Port1', 'Port2')
    }

    It 'names the source of every field' {
        foreach ($p in $script:Cfg.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            $script:Cfg._sources.PSObject.Properties.Name | Should -Contain $p.Name -Because $p.Name
            "$($script:Cfg._sources.($p.Name))" | Should -Not -BeNullOrEmpty -Because $p.Name
        }
    }

    It 'covers every field Start-AzlValidation reads' {
        $c = Resolve-ConfigDefaults -Config ([pscustomobject]@{ clusterName = 'x' })
        foreach ($n in $c.PSObject.Properties.Name) { $script:Cfg.PSObject.Properties.Name | Should -Contain $n -Because $n }
    }

    It 'leaves the domain empty on the local identity path' {
        $x = Get-Fixture
        $x.scenario.identity = 'local_identity'
        $c = ConvertTo-BeaconValidationConfig -Infrastructure $x
        $c.adDomainFqdn | Should -Be ''
        @($c.dcIps).Count | Should -Be 0
        @($c.nodeFqdns).Count | Should -Be 0
    }

    It 'reads the management address from network_adapters (schema 5.2) and uses the OS port name' {
        $x = Get-Fixture
        foreach ($n in $x.nodes) {
            $ip = $n.management.ip_address
            $n.PSObject.Properties.Remove('management')
            $n | Add-Member -NotePropertyName network_adapters -NotePropertyValue @(
                [pscustomobject]@{ name = 'Port1'; os_name_override = 'Mgmt1'; roles = @('management'); ip_address = $ip },
                [pscustomobject]@{ name = 'Port3'; roles = @('storage') }
            )
        }
        $c = ConvertTo-BeaconValidationConfig -Infrastructure $x
        $c.nodeIps | Should -Be @('192.0.2.11', '192.0.2.12')
        ($c.hostNetworkIntents | Where-Object Name -eq 'management').Adapter | Should -Be @('Mgmt1', 'Port2')
    }

    It 'reads the proxy for the proxy and private_path outbound paths' {
        $x = Get-Fixture
        $x.scenario.outbound_path = 'proxy'
        $x.networking | Add-Member -NotePropertyName outbound -NotePropertyValue ([pscustomobject]@{ proxy = [pscustomobject]@{ url = 'http://proxy.improbability.cloud:3128'; bypass = @('*.improbability.cloud', '192.0.2.0/24') } })
        $c = ConvertTo-BeaconValidationConfig -Infrastructure $x
        $c.proxyUrl | Should -Be 'http://proxy.improbability.cloud:3128'
        $c.proxyBypass | Should -Be @('*.improbability.cloud', '192.0.2.0/24')

        $x.scenario.outbound_path = 'private_path'
        $x.networking.outbound | Add-Member -NotePropertyName private_path -NotePropertyValue ([pscustomobject]@{ firewall_private_ip = '192.0.2.200'; firewall_port = 8443; proxy_bypass = @('localhost') })
        $c2 = ConvertTo-BeaconValidationConfig -Infrastructure $x
        $c2.proxyUrl | Should -Be 'http://192.0.2.200:8443'
        $c2.proxyBypass | Should -Be @('localhost')

        $x.scenario.outbound_path = 'direct'
        (ConvertTo-BeaconValidationConfig -Infrastructure $x).proxyUrl | Should -Be ''
    }

    It 'uses the government Key Vault suffix for scenario.cloud government' {
        $x = Get-Fixture
        $x.scenario.cloud = 'government'
        (ConvertTo-BeaconValidationConfig -Infrastructure $x).keyVaultFqdn | Should -Be 'kv-iic-azl-01.vault.usgovcloudapi.net'
    }

    It 'takes only Beacon''s own settings from its config and ignores engagement keys there' {
        $settings = [pscustomobject]@{ oem = ''; arcGatewayFqdn = 'example.gw.arc.azure.com'; tcpConnectTimeoutMs = 9000; pingTimeoutMs = 750; tlsInspectionHosts = @('login.microsoftonline.com'); brand = 'IIC'; clusterName = 'stale-name'; dnsServers = @('203.0.113.9') }
        $c = ConvertTo-BeaconValidationConfig -Infrastructure (Get-Fixture) -Settings $settings
        $c.arcGatewayFqdn | Should -Be 'example.gw.arc.azure.com'
        $c.tcpConnectTimeoutMs | Should -Be 9000
        $c.pingTimeoutMs | Should -Be 750
        $c.tlsInspectionHosts | Should -Be @('login.microsoftonline.com')
        $c.brand | Should -Be 'IIC'
        $c.clusterName | Should -Be 'iic-azl-01'
        $c.dnsServers | Should -Be @('192.0.2.4', '192.0.2.5')
        $c._sources.tcpConnectTimeoutMs | Should -Match 'Beacon setting'
    }
}

Describe 'Get-BeaconEvidenceDirectory' {
    It 'is the beacon folder in the evidence discovery folder that Sonar''s Discovery view reads' {
        Get-BeaconEvidenceDirectory -Infrastructure (Get-Fixture) | Should -Be 'D:\Data\azl-ztp\iic-azl-01\evidence\discovery\beacon'
    }
    It 'prefers hardware.discovery.output_directory' {
        $x = Get-Fixture
        $x.hardware | Add-Member -NotePropertyName discovery -NotePropertyValue ([pscustomobject]@{ output_directory = 'E:\evidence\discovery\' })
        Get-BeaconEvidenceDirectory -Infrastructure $x | Should -Be 'E:\evidence\discovery\beacon'
    }
    It 'falls back to the ZTP default folder of the site, then to nothing' {
        $x = Get-Fixture
        $x.provisioning.simplified.PSObject.Properties.Remove('evidence_path')
        Get-BeaconEvidenceDirectory -Infrastructure $x | Should -Be ([Environment]::ExpandEnvironmentVariables('%ProgramData%\AzureLocalZtp\iic-site-01\evidence\discovery\beacon'))
        $x.PSObject.Properties.Remove('provisioning')
        Get-BeaconEvidenceDirectory -Infrastructure $x | Should -Be ''
    }
}

Describe 'Get-BeaconInfrastructureScopeNote' {
    It 'is silent for a full file and warns for a file cut for another tool' {
        Get-BeaconInfrastructureScopeNote -Infrastructure (Get-Fixture) | Should -Be ''
        $x = Get-Fixture
        $x._metadata | Add-Member -NotePropertyName scope -NotePropertyValue 'ztp'
        Get-BeaconInfrastructureScopeNote -Infrastructure $x | Should -Match "scope 'ztp'"
        $x._metadata.scope = 'beacon'
        Get-BeaconInfrastructureScopeNote -Infrastructure $x | Should -Be ''
    }
}

Describe 'results document from an infrastructure file' {
    BeforeAll {
        $script:Ctx = Get-BeaconInfrastructureContext -Path $script:FixturePath -Infrastructure (Get-Fixture)
        $script:AllResults = New-Object System.Collections.Generic.List[object]
        Add-ValidationResult -Category 'Cat-2-DNS' -Name 'DNS-TCP53-192.0.2.4' -Target '192.0.2.4:53' -Status 'Pass' -Detail '3ms' 6>$null
        $script:Doc = New-BeaconResultsDocument -Results $script:AllResults -Context @{
            RunId = (New-BeaconRunId); Started = [DateTime]::UtcNow.AddSeconds(-5); Finished = [DateTime]::UtcNow; Node = [pscustomobject]@{ hostname = 'NODE01'; serialNumber = 'SN1'; smbiosUuid = ''; manufacturer = 'x'; model = 'y' }
            Region = 'eastus'; RegionRequested = 'eastus'; Oem = 'dell'; ArcGatewayMode = $false; ProxyConfigured = $false
            Categories = @(2); EndpointSource = 'https://example.test/eastus.md'; Infrastructure = $script:Ctx
        }
    }
    It 'records which file the run read and conforms to the schema' {
        $script:Doc.schemaVersion | Should -Be '1.2'
        $script:Doc.context.infrastructure.fileName | Should -Be 'infrastructure.example.json'
        $script:Doc.context.infrastructure.sha256 | Should -Match '^[0-9a-f]{64}$'
        $script:Doc.context.infrastructure.schemaVersion | Should -Be '5.6.0'
        $script:Doc.context.infrastructure.clusterName | Should -Be 'iic-azl-01'
        Test-Json -Json ($script:Doc | ConvertTo-Json -Depth 8) -SchemaFile $script:SchemaPath | Should -BeTrue
    }
    It 'hides the file name when redacted' {
        $red = Invoke-BeaconRedaction -Document $script:Doc -Map (Get-RedactionMap -Config (ConvertTo-BeaconValidationConfig -Infrastructure (Get-Fixture)) -Node $script:Doc.node)
        $red.context.infrastructure.fileName | Should -Be '<infrastructure-file>'
        $red.context.infrastructure.clusterName | Should -Be '<cluster>'
        Test-Json -Json ($red | ConvertTo-Json -Depth 8) -SchemaFile $script:SchemaPath | Should -BeTrue
    }
    It 'leaves the context unchanged without a file' {
        $d = New-BeaconResultsDocument -Results @() -Context @{ RunId = 'r'; Started = [DateTime]::UtcNow; Finished = [DateTime]::UtcNow; Node = $null; Region = 'eastus'; RegionRequested = ''; Oem = ''; ArcGatewayMode = $false; ProxyConfigured = $false; Categories = @(1); EndpointSource = '' }
        $d.context.PSObject.Properties.Name | Should -Not -Contain 'infrastructure'
    }
}

Describe 'Start-AzlValidation -InfrastructureFile' {
    It 'Get-ArcInputs falls back to the infrastructure values' {
        . (Join-Path $script:Root 'src\Start-AzlValidation.ps1')
        $env:BEACON_ARC_SUBSCRIPTION = ''; $env:BEACON_ARC_RG = ''; $env:BEACON_ARC_NODES = ''; $env:BEACON_ARC_TENANT = ''
        $cfg = ConvertTo-BeaconValidationConfig -Infrastructure (Get-Fixture)
        $a = Get-ArcInputs -Subscription '' -Tenant '' -ResourceGroup '' -Nodes @() -Cloud 'AzureCloud' -ProxyUrl '' -Infrastructure $cfg
        $a.ResourceGroup | Should -Be 'rg-iic-azl-01'
        $a.NodeNames | Should -Be @('iic-azl-n01', 'iic-azl-n02')
        (Get-ArcInputs -Subscription 'p' -Tenant '' -ResourceGroup 'rg-param' -Nodes @() -Cloud 'AzureCloud' -ProxyUrl '' -Infrastructure $cfg).ResourceGroup | Should -Be 'rg-param'
    }

    It '-Plan prints every value with its source, probes nothing and exits 0' {
        $cfgDir = Join-Path $TestDrive 'config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Copy-Item (Join-Path $script:Root 'src\config\endpoints.json') $cfgDir
        $out = & pwsh -NoProfile -File (Join-Path $script:Root 'src\Start-AzlValidation.ps1') -InfrastructureFile $script:FixturePath -ConfigPath $cfgDir -Plan 6>&1 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'from azure\.location'
        $out | Should -Match 'from networking\.management\.infrastructure_pool'
        $out | Should -Match 'evidence\\discovery\\beacon'
        $out | Should -Not -Match '00000000-0000'
    }

    It 'exits 2 with a message when the file does not exist' {
        & pwsh -NoProfile -File (Join-Path $script:Root 'src\Start-AzlValidation.ps1') -InfrastructureFile (Join-Path $TestDrive 'missing.yml') -Plan 6>&1 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
}

Describe 'ConvertTo-BeaconValidationConfig.ps1' {
    It 'writes validation-config.json without the Azure targets unless asked' {
        $out = Join-Path $TestDrive 'validation-config.json'
        & pwsh -NoProfile -File (Join-Path $script:Root 'src\ConvertTo-BeaconValidationConfig.ps1') -InfrastructureFile $script:FixturePath -OutputPath $out 6>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        $j = Get-Content $out -Raw | ConvertFrom-Json
        $j.clusterName | Should -Be 'iic-azl-01'
        $j.PSObject.Properties.Name | Should -Not -Contain 'arcSubscriptionId'
        $j.PSObject.Properties.Name | Should -Not -Contain 'arcTenantId'
        $j._sources.azureRegion | Should -Be 'azure.location'
    }
}

Describe 'the live toolkit examples (AZL_TOOLKIT_ROOT)' {
    BeforeAll {
        $script:Tk = $env:AZL_TOOLKIT_ROOT
        $script:CanRun = $script:Tk -and (Test-Path (Join-Path $script:Tk 'config\variables\examples')) -and (Get-Module -ListAvailable powershell-yaml)
    }
    It 'reads <_> and sources every field' -ForEach @('infrastructure.example.yml') {
        if (-not $script:CanRun) { Set-ItResult -Skipped -Because 'AZL_TOOLKIT_ROOT is not set or powershell-yaml is missing'; return }
        $x = Import-BeaconInfrastructureFile -Path (Join-Path $script:Tk "config\variables\examples\$_")
        $c = ConvertTo-BeaconValidationConfig -Infrastructure $x
        $c.clusterName | Should -Not -BeNullOrEmpty
        @($c.nodeIps).Count | Should -BeGreaterThan 0
        @($c.hostNetworkIntents).Count | Should -BeGreaterThan 0
        $c.managementSubnetCidr | Should -Not -BeNullOrEmpty
    }
}
