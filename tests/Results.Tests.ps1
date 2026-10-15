#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    foreach ($f in 'Beacon.Version', 'Beacon.Common', 'Beacon.Results') { . (Join-Path $script:Root "src\lib\$f.ps1") }
    $script:SchemaPath = Join-Path $script:Root 'docs\reference\results.schema.json'

    function New-SampleDocument {
        $script:AllResults = New-Object System.Collections.Generic.List[object]
        Add-ValidationResult -Category 'Cat-1-Network' -Name 'NIC-Up-WithIP' -Target 'adapter' -Status 'Pass' -Detail 'Example NIC / 192.0.2.21' 6>$null
        Add-ValidationResult -Category 'Cat-3-AD' -Name 'AD-LDAP-192.0.2.10' -Target '192.0.2.10:389' -Status 'Fail' -Severity 'critical' -Detail 'Timeout' -Remediation 'Allow TCP/389' -Source 'https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements' -DurationMs 5001 6>$null
        Add-ValidationResult -Category 'Cat-4-Endpoints' -Name 'EP-x.example.com' -Target 'x.example.com:443' -Status 'Warn' -Severity 'warning' -Detail 'corp.contoso.com resolved 20.1.2.3' 6>$null
        Add-ValidationResult -Category 'Cat-6-Arc' -Name 'Arc-RP-Microsoft.HybridCompute' -Target 'Microsoft.HybridCompute' -Status 'Skip' -Detail 'sub 11111111-2222-3333-4444-555555555555' 6>$null
        $node = [pscustomobject]@{ hostname = 'NODE01'; serialNumber = 'SN12345'; smbiosUuid = '4C4C4544-0000-1111-2222-333333333333'; manufacturer = 'Example'; model = 'Model X' }
        return (New-BeaconResultsDocument -Results $script:AllResults -Context @{
                RunId = (New-BeaconRunId); Started = [DateTime]::UtcNow.AddSeconds(-42); Finished = [DateTime]::UtcNow; Node = $node
                Region = 'eastus'; RegionRequested = 'East US'; Oem = ''; ArcGatewayMode = $false; ProxyConfigured = $false
                Categories = @(1, 3, 4, 6); EndpointSource = 'https://example.test/eastus.md'
            })
    }
}

Describe 'Add-ValidationResult' {
    BeforeEach { $script:AllResults = New-Object System.Collections.Generic.List[object]; $script:CriticalFail = $false }
    It 'records every field and flags Fail as critical' {
        Add-ValidationResult -Category 'c' -Name 'n' -Target 't' -Status 'Fail' -Severity 'critical' -Detail 'd' -Remediation 'r' -Source 's' 6>$null
        $r = $script:AllResults[0]
        $r.Name | Should -Be 'n'; $r.Severity | Should -Be 'critical'; $r.Remediation | Should -Be 'r'; $r.Source | Should -Be 's'
        $script:CriticalFail | Should -BeTrue
    }
    It 'does not flag Warn or Skip' {
        Add-ValidationResult -Category 'c' -Name 'n' -Target 't' -Status 'Warn' -Detail 'd' 6>$null
        Add-ValidationResult -Category 'c' -Name 'n' -Target 't' -Status 'Skip' -Detail 'd' 6>$null
        $script:CriticalFail | Should -BeFalse
    }
    It 'rejects an invalid status' {
        { Add-ValidationResult -Category 'c' -Name 'n' -Target 't' -Status 'Bogus' -Detail 'd' } | Should -Throw
    }
}

Describe 'Get-ResultSummary' {
    It 'counts and gives the verdict' {
        $s = Get-ResultSummary -Results @([pscustomobject]@{ Status = 'Pass' }, [pscustomobject]@{ Status = 'Pass' }, [pscustomobject]@{ Status = 'Warn' }, [pscustomobject]@{ Status = 'Skip' })
        $s.total | Should -Be 4; $s.pass | Should -Be 2; $s.warn | Should -Be 1; $s.skip | Should -Be 1; $s.fail | Should -Be 0
        $s.verdict | Should -Be 'PASS'
    }
    It 'FAIL when any Fail, NO_CHECKS when empty' {
        (Get-ResultSummary -Results @([pscustomobject]@{ Status = 'Fail' })).verdict | Should -Be 'FAIL'
        (Get-ResultSummary -Results @()).verdict | Should -Be 'NO_CHECKS'
    }
}

Describe 'ConvertTo-UtcStamp' {
    It 'is really UTC, not local time with a Z' {
        $local = [DateTime]::SpecifyKind([DateTime]::new(2026, 10, 15, 12, 0, 0), [DateTimeKind]::Local)
        ConvertTo-UtcStamp $local | Should -Be ($local.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    }
    It 'leaves a UTC value unchanged' {
        ConvertTo-UtcStamp ([DateTime]::new(2026, 10, 15, 12, 0, 0, [DateTimeKind]::Utc)) | Should -Be '2026-10-15T12:00:00Z'
    }
}

Describe 'Results document and schema' {
    BeforeAll { $script:Doc = New-SampleDocument }
    It 'conforms to docs/reference/results.schema.json' {
        $json = $script:Doc | ConvertTo-Json -Depth 8
        Test-Json -Json $json -SchemaFile $script:SchemaPath | Should -BeTrue
    }
    It 'carries run id, node identity, schema version, tool version and UTC timestamps' {
        $script:Doc.runId | Should -Match '^[0-9a-f-]{36}$'
        $script:Doc.node.serialNumber | Should -Be 'SN12345'
        $script:Doc.schemaVersion | Should -Be '1.1'
        $script:Doc.tool.version | Should -Be '1.1.0'
        $script:Doc.startedUtc | Should -Match 'Z$'
        $script:Doc.summary.fail | Should -Be 1
        $script:Doc.summary.verdict | Should -Be 'FAIL'
    }
    It 'is rejected by the schema when a required field or enum is wrong' {
        $bad = $script:Doc | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.results[0].status = 'Maybe'
        (Test-Json -Json ($bad | ConvertTo-Json -Depth 8) -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue) | Should -BeFalse
        $bad2 = $script:Doc | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad2.PSObject.Properties.Remove('runId')
        (Test-Json -Json ($bad2 | ConvertTo-Json -Depth 8) -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue) | Should -BeFalse
    }
    It 'the committed example results conform to the schema' {
        $ex = Join-Path $script:Root 'examples\sample-results.json'
        Test-Path $ex | Should -BeTrue
        Test-Json -Json (Get-Content $ex -Raw) -SchemaFile $script:SchemaPath | Should -BeTrue
    }
    It 'the schema file itself is valid JSON' {
        { Get-Content $script:SchemaPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Redaction' {
    BeforeAll {
        $script:Doc = New-SampleDocument
        $script:Cfg = [pscustomobject]@{ adDomainFqdn = 'corp.contoso.com'; clusterName = 'example-cluster'; dcFqdns = @('dc-01.corp.contoso.com'); nodeFqdns = @('node-01.corp.contoso.com') }
        $script:Map = Get-RedactionMap -Config $script:Cfg -Node $script:Doc.node
        $script:Red = Invoke-BeaconRedaction -Document $script:Doc -Map $script:Map
        $script:RedJson = $script:Red | ConvertTo-Json -Depth 8
    }
    It 'removes domain, hostname, serial, SMBIOS UUID, GUIDs and IPv4 addresses' {
        $script:RedJson | Should -Not -Match 'contoso'
        $script:RedJson | Should -Not -Match 'NODE01'
        $script:RedJson | Should -Not -Match 'SN12345'
        $script:RedJson | Should -Not -Match '4C4C4544'
        $script:RedJson | Should -Not -Match '11111111-2222'
        $script:RedJson | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
    }
    It 'uses stable tokens and marks the document redacted' {
        $script:Red.redacted | Should -BeTrue
        $script:RedJson | Should -Match '<domain>'
        $script:RedJson | Should -Match '<ip-1>'
    }
    It 'maps the same address to the same token' {
        $r = Invoke-BeaconRedaction -Document ([pscustomobject]@{ a = '10.1.1.1 and 10.1.1.1 and 10.2.2.2'; redacted = $false }) -Map @()
        $r.a | Should -Be '<ip-1> and <ip-1> and <ip-2>'
    }
    It 'redacts the longer name first' {
        $m = Get-RedactionMap -Config ([pscustomobject]@{ adDomainFqdn = 'contoso.com'; dcFqdns = @('dc.corp.contoso.com') }) -Node $null
        $m[0].Value.Length | Should -BeGreaterOrEqual $m[1].Value.Length
    }
    It 'still conforms to the schema (modulo tokens)' {
        Test-Json -Json $script:RedJson -SchemaFile $script:SchemaPath | Should -BeTrue
    }
    It 'does not modify the input document' {
        $script:Doc.redacted | Should -BeFalse
        ($script:Doc | ConvertTo-Json -Depth 8) | Should -Match 'contoso'
    }
}

Describe 'HTML and log output' {
    BeforeAll { $script:Doc = New-SampleDocument }
    It 'html-encodes values and has no script or external references' {
        $d = $script:Doc | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $d.results[0].detail = '<script>alert(1)</script> & "x"'
        $h = ConvertTo-BeaconHtml -Document $d
        $h | Should -Not -Match '<script'
        $h | Should -Match '&lt;script&gt;'
        $h | Should -Not -Match 'https?://(?!learn\.microsoft\.com|example\.test)'
    }
    It 'shows verdict, counts and the node' {
        $h = ConvertTo-BeaconHtml -Document $script:Doc
        $h | Should -Match 'FAIL'
        $h | Should -Match 'NODE01'
        $h | Should -Match 'Allow TCP/389'
    }
    It 'writes json, log and html with Save-BeaconResults' {
        $f = Save-BeaconResults -Document $script:Doc -Directory (Join-Path $TestDrive 'out')
        foreach ($p in $f.Json, $f.Log, $f.Html) { Test-Path $p | Should -BeTrue }
        $f.Json | Should -Match 'validation-\d{8}-\d{6}\.json$'
        (Get-Content $f.Log) -join "`n" | Should -Match 'Verdict'
    }
    It 'supports a suffix for redacted copies' {
        (Save-BeaconResults -Document $script:Doc -Directory (Join-Path $TestDrive 'out2') -Suffix '-redacted').Json | Should -Match '-redacted\.json$'
    }
}

Describe 'Resolve-ExportTarget' {
    It '<Target> -> <Kind>' -ForEach @(
        @{ Target = 'E'; Kind = 'Drive' }, @{ Target = 'e:'; Kind = 'Drive' }, @{ Target = 'E:\'; Kind = 'Drive' }, @{ Target = 'E:\exports'; Kind = 'Drive' },
        @{ Target = '\\server\share'; Kind = 'Smb' }, @{ Target = '\\server\share\sub\'; Kind = 'Smb' },
        @{ Target = 'https://example.com/beacon'; Kind = 'Http' },
        @{ Target = 'http://example.com/beacon'; Kind = 'None' },
        @{ Target = 'ftp://x'; Kind = 'None' }, @{ Target = ''; Kind = 'None' }, @{ Target = 'share'; Kind = 'None' }
    ) { (Resolve-ExportTarget -Target $Target).Kind | Should -Be $Kind }
    It 'allows plain http only when asked' {
        (Resolve-ExportTarget -Target 'http://example.com/x' -AllowInsecureHttp).Kind | Should -Be 'Http'
    }
    It 'normalises a drive letter' {
        (Resolve-ExportTarget -Target 'e').Value | Should -Be 'E:\'
    }
}

Describe 'Export-BeaconResults' {
    BeforeAll {
        $script:Doc = New-SampleDocument
        $script:Files = Save-BeaconResults -Document $script:Doc -Directory (Join-Path $TestDrive 'src')
    }
    It 'copies the three files to a drive/folder target' {
        $dest = Join-Path $TestDrive 'usb'
        New-Item -ItemType Directory -Path $dest | Out-Null
        $r = Export-BeaconResults -Files $script:Files -Target $dest
        $r.Ok | Should -BeTrue
        @(Get-ChildItem (Join-Path $dest 'beacon-results')).Count | Should -Be 3
    }
    It 'fails cleanly for a missing drive' {
        (Export-BeaconResults -Files $script:Files -Target 'Q:\nowhere').Ok | Should -BeFalse
    }
    It 'POSTs the JSON to https targets with an optional bearer token' {
        Mock Invoke-RestMethod { 'ok' }
        $r = Export-BeaconResults -Files $script:Files -Target 'https://example.com/ingest' -BearerToken 'tok'
        $r.Ok | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' -and $Uri -eq 'https://example.com/ingest' -and $Headers.Authorization -eq 'Bearer tok' -and $ContentType -eq 'application/json' }
    }
    It 'reports an HTTP failure without throwing' {
        Mock Invoke-RestMethod { throw 'boom' }
        $r = Export-BeaconResults -Files $script:Files -Target 'https://example.com/ingest'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'boom'
    }
    It 'refuses plain http' {
        (Export-BeaconResults -Files $script:Files -Target 'http://example.com/x').Ok | Should -BeFalse
    }
    It 'maps an SMB share through a temporary PSDrive and removes it' {
        Mock New-PSDrive { }
        Mock Remove-PSDrive { }
        Mock Copy-Item { }
        $r = Export-BeaconResults -Files $script:Files -Target '\\server\share'
        $r.Ok | Should -BeTrue
        Should -Invoke New-PSDrive -Times 1
        Should -Invoke Remove-PSDrive -Times 1
    }
}

Describe 'Get-BeaconNodeIdentity' {
    It 'never throws and always returns the five fields' {
        $n = Get-BeaconNodeIdentity
        foreach ($p in 'hostname', 'serialNumber', 'smbiosUuid', 'manufacturer', 'model') { $n.PSObject.Properties.Name | Should -Contain $p }
    }
    It 'degrades to empty values when CIM fails (WinPE without WMI)' {
        Mock Get-CimInstance { throw 'no wmi' }
        $n = Get-BeaconNodeIdentity
        $n.serialNumber | Should -Be ''
        $n.smbiosUuid | Should -Be ''
    }
}
