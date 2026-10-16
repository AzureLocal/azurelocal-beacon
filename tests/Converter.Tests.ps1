#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:Root 'src\Convert-EndpointsToJson.ps1')
    $script:Fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\junk-endpoints.md')
    $script:Parsed = ConvertFrom-EndpointMarkdown -Lines $script:Fixture -SourceUrl 'https://example.test/list.md' -Region 'eastus'
}

Describe 'Test-EndpointHostName' {
    It 'accepts <_>' -ForEach @('login.microsoftonline.com', '*.his.arc.azure.com', 'azgn*.servicebus.windows.net', 'eastus.dp.kubernetesconfiguration.azure.com', 'a-b.example.org') {
        Test-EndpointHostName $_ | Should -BeTrue
    }
    It 'rejects <_>' -ForEach @('Management network', 'SSH', 'Kubernetes API server', 'bad_host!.example.com', 'host`.example.com', 'nodots', 'a..b.com', 'x.y.123', '-lead.example.com', 'http://x.example.com', '10.0.0.1:443') {
        Test-EndpointHostName $_ | Should -BeFalse
    }
    It 'rejects the empty string' {
        Test-EndpointHostName '' | Should -BeFalse
    }
}

Describe 'Split-PortCell' {
    It '<Cell> -> <Expected>' -ForEach @(
        @{ Cell = '443'; Expected = '443' }
        @{ Cell = '80, 443'; Expected = '80,443' }
        @{ Cell = '80/443'; Expected = '80,443' }
        @{ Cell = '80 and 443'; Expected = '80,443' }
        @{ Cell = '123'; Expected = '123' }
    ) { (Split-PortCell $Cell) -join ',' | Should -Be $Expected }
    It 'returns $null for <_>' -ForEach @('abc', '0', '70000', '443x') {
        Split-PortCell $_ | Should -BeNullOrEmpty
    }
}

Describe 'Split-EndpointCell' {
    It 'strips backticks and splits multiple hosts' {
        $r = @(Split-EndpointCell '`pypi.org`, `*.pypi.org`')
        $r.Host | Should -Be @('pypi.org', '*.pypi.org')
    }
    It 'keeps the path separately and drops a trailing /*' {
        @(Split-EndpointCell 'crl.microsoft.com/pkiinfra')[0].Path | Should -Be '/pkiinfra'
        @(Split-EndpointCell 'http://crl3.digicert.com/*')[0].Path | Should -Be ''
    }
    It 'extracts an explicit port' {
        @(Split-EndpointCell 'host.example.com:8443')[0].Port | Should -Be 8443
    }
}

Describe 'ConvertFrom-EndpointMarkdown (strict)' {
    It 'rejects every non-host row instead of emitting junk' {
        $rejected = $script:Parsed.Rejected | ForEach-Object { $_.value }
        $rejected | Should -Contain 'Management network'
        $rejected | Should -Contain 'SSH'
        $rejected | Should -Contain 'Kubernetes API server'
        $rejected | Should -Contain 'HTTPS to private cloud control plane'
        $rejected | Should -Contain 'bad_host!.example.com'
    }
    It 'rejects a non numeric port' {
        @($script:Parsed.Rejected | Where-Object { $_.reason -match 'port' }).Count | Should -BeGreaterThan 0
    }
    It 'never produces an entry whose host is not a valid host name' {
        foreach ($e in $script:Parsed.Entries) { Test-EndpointHostName $e.host | Should -BeTrue -Because $e.host }
    }
    It 'never leaves a backtick in any field' {
        foreach ($e in $script:Parsed.Entries) {
            ($e.host + $e.notes + $e.component + $e.path) | Should -Not -Match '`'
        }
    }
    It 'splits multi-host/multi-port cells into one entry each' {
        $m = @($script:Parsed.Entries | Where-Object { $_.host -in 'multi.example.com', 'other.example.com' })
        $m.Count | Should -Be 4
        @($m | Where-Object { $_.host -eq 'multi.example.com' } | ForEach-Object { $_.port }) | Should -Be @(80, 443)
    }
    It 'splits the pypi cell into two entries' {
        @($script:Parsed.Entries | Where-Object { $_.host -like '*pypi.org' }).Count | Should -Be 2
    }
    It 'maps UDP/123 and HTTP/80 protocols' {
        ($script:Parsed.Entries | Where-Object { $_.host -eq 'time.windows.com' }).protocol | Should -Be 'UDP'
        ($script:Parsed.Entries | Where-Object { $_.host -eq 'crl.microsoft.com' }).protocol | Should -Be 'HTTP'
        ($script:Parsed.Entries | Where-Object { $_.host -eq 'crl.microsoft.com' }).path | Should -Be '/pkiinfra'
    }
    It 'flags port 8084 as not probed and informational' {
        $e = $script:Parsed.Entries | Where-Object { $_.port -eq 8084 }
        $e.probe | Should -BeFalse
        $e.severity | Should -Be 'informational'
        $e.skipReason | Should -Match '8084'
    }
    It 'flags the Arc gateway placeholder' {
        ($script:Parsed.Entries | Where-Object { $_.host -like 'yourarcgatewayendpointid*' }).placeholder | Should -Be 'arcGateway'
    }
    It 'fills source, requiredFor and arc gateway mode on every entry' {
        foreach ($e in $script:Parsed.Entries) {
            $e.source | Should -Be 'https://example.test/list.md'
            $e.requiredFor | Should -Not -BeNullOrEmpty
            $e.arcGateway | Should -BeIn @('yes', 'no', 'registration', 'notRequired')
        }
    }
    It 'uses a same-list sibling as representative host for a wildcard' {
        $w = $script:Parsed.Entries | Where-Object { $_.host -eq '*.prod.hot.ingest.monitor.core.windows.net' }
        $w.probeHost | Should -Be 'dc.prod.hot.ingest.monitor.core.windows.net'
        $w.probeHostBasis | Should -Be 'list'
    }
    It 'parses phase from the Required for column' {
        ($script:Parsed.Entries | Where-Object { $_.port -eq 8084 }).phase | Should -Be 'post-deployment'
        ($script:Parsed.Entries | Where-Object { $_.host -eq 'login.microsoftonline.com' }).phase | Should -Be 'both'
    }
}

Describe 'Merge-EndpointEntries' {
    It 'collapses duplicates on host+port+path and keeps the more severe entry' {
        $a = @{ host = 'a.example.com'; port = 443; path = ''; severity = 'warning'; component = 'x' }
        $b = @{ host = 'a.example.com'; port = 443; path = ''; severity = 'critical'; component = 'x' }
        $r = @(Merge-EndpointEntries -Entries @($a, $b))
        $r.Count | Should -Be 1
        $r[0].severity | Should -Be 'critical'
    }
}

Describe 'Snapshots from Learn-linked lists (committed in config/endpoints/learn)' {
    BeforeAll {
        $script:Sources = Get-Content (Join-Path $script:Root 'config\endpoints\sources.json') -Raw | ConvertFrom-Json
    }
    It 'parses <_> with zero rejected rows' -ForEach @('eastus', 'westeurope', 'australiaeast', 'canadacentral', 'centralindia', 'southeastasia', 'japaneast', 'southcentralus', 'usgovvirginia') {
        $def = $script:Sources.regions.$_
        $r = ConvertFrom-EndpointMarkdown -Lines (Get-Content (Join-Path $script:Root "config\endpoints\learn\$($def.file)")) -SourceUrl $def.page -Region $_
        $r.Rejected.Count | Should -Be 0
        $r.Entries.Count | Should -BeGreaterThan 60
        @($r.Entries | Where-Object { $_.host -match '^management\.' }).Count | Should -BeGreaterThan 0
    }
    It 'parses the Dell OEM list' {
        $def = $script:Sources.oem.dell
        $r = ConvertFrom-EndpointMarkdown -Lines (Get-Content (Join-Path $script:Root "config\endpoints\learn\$($def.file)")) -SourceUrl $def.page -DefaultComponent 'OEM (Dell)'
        $r.Rejected.Count | Should -Be 0
        ($r.Entries | ForEach-Object { $_.host }) | Should -Contain 'crl3.digicert.com'
        ($r.Entries | ForEach-Object { $_.host }) | Should -Contain 'downloads.dell.com'
    }
}

Describe 'Generated src/config/endpoints.json' {
    BeforeAll {
        $script:Data = Get-Content (Join-Path $script:Root 'src\config\endpoints.json') -Raw | ConvertFrom-Json
    }
    It 'has schemaVersion 2.0 and the release train' {
        $script:Data.schemaVersion | Should -Be '2.0'
        $script:Data.releaseTrain | Should -Be '12.2609 (latest)'
    }
    It 'has region <_>' -ForEach @('eastus', 'westeurope', 'australiaeast', 'canadacentral', 'centralindia', 'southeastasia', 'japaneast', 'southcentralus', 'usgovvirginia') {
        $script:Data.regions.PSObject.Properties.Name | Should -Contain $_
    }
    It 'has no rejected rows and none of the old junk names' {
        $all = foreach ($r in $script:Data.regions.PSObject.Properties) { $r.Value.endpoints }
        foreach ($r in $script:Data.regions.PSObject.Properties) { @($r.Value.rejected).Count | Should -Be 0 }
        (($all | ForEach-Object { $_.host }) -join ' ') | Should -Not -Match 'Management network|SSH|Kubernetes API|logical network|private cloud|MOC cloud'
        (($all | ForEach-Object { $_.host }) -join ' ') | Should -Not -Match '`'
    }
    It 'every entry has a valid host, a port, a source URL and requiredFor' {
        foreach ($r in $script:Data.regions.PSObject.Properties) {
            foreach ($e in $r.Value.endpoints) {
                Test-EndpointHostName $e.host | Should -BeTrue -Because "$($r.Name): $($e.host)"
                $e.port | Should -BeIn (1..65535)
                $e.source | Should -Match '^https://'
                $e.requiredFor | Should -Not -BeNullOrEmpty
                $e.severity | Should -BeIn @('critical', 'warning', 'informational')
            }
        }
    }
    It 'marks port 8084 rows as not probed' {
        foreach ($r in $script:Data.regions.PSObject.Properties) {
            foreach ($e in @($r.Value.endpoints | Where-Object { $_.port -eq 8084 })) { $e.probe | Should -BeFalse }
        }
    }
    It 'carries no lab or private names' {
        $json = Get-Content (Join-Path $script:Root 'src\config\endpoints.json') -Raw
        $json | Should -Not -Match '(?i)tier[p]oint|t[o]te|st[t]ote'
    }
    It 'has region specific hosts' {
        ($script:Data.regions.westeurope.endpoints | ForEach-Object { $_.host }) | Should -Contain 'weu.his.arc.azure.com'
        ($script:Data.regions.eastus.endpoints | ForEach-Object { $_.host }) | Should -Contain 'eus.his.arc.azure.com'
    }
}
