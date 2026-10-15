#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    foreach ($f in 'Beacon.Version', 'Beacon.Common', 'Beacon.Net', 'Beacon.EnvChecker', 'Beacon.Arc') { . (Join-Path $script:Root "src\lib\$f.ps1") }

    $script:Sub = '11111111-2222-3333-4444-555555555555'
    $script:Oid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    function New-FakeJwt {
        param($Claims)
        $h = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $p = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "$h.$p.sig"
    }
    $script:Jwt = New-FakeJwt @{ oid = $script:Oid; tid = 'tenant' }
}

Describe 'pure helpers' {
    It 'masks ids but keeps the last four characters' {
        Format-MaskedId $script:Sub | Should -Be '********-****-****-****-********5555'
        Format-MaskedId '' | Should -Be ''
    }
    It 'decodes a JWT payload without validating it' {
        (ConvertFrom-JwtPayload $script:Jwt).oid | Should -Be $script:Oid
        ConvertFrom-JwtPayload 'garbage' | Should -BeNullOrEmpty
        ConvertFrom-JwtPayload '' | Should -BeNullOrEmpty
    }
    It 'uses the US Government audience management.core.usgovcloudapi.net for the token scope' {
        (Get-ArcCloudProfile -Cloud 'AzureUSGovernment').Scope | Should -Be 'https://management.core.usgovcloudapi.net/.default'
    }
    It 'knows the public and the US Government cloud' {
        (Get-ArcCloudProfile -Cloud 'AzureCloud').Arm | Should -Be 'https://management.azure.com'
        (Get-ArcCloudProfile -Cloud 'AzureUSGovernment').Login | Should -Be 'https://login.microsoftonline.us'
    }
    It 'Get-ProviderVerdict maps registration states' {
        Get-ProviderVerdict -State 'Registered' | Should -Be 'Pass'
        Get-ProviderVerdict -State 'Registering' | Should -Be 'Warn'
        Get-ProviderVerdict -State 'NotRegistered' | Should -Be 'Fail'
        Get-ProviderVerdict -State 'NotRegistered' -Required $false | Should -Be 'Warn'
        Get-ProviderVerdict -State 'whatever' | Should -Be 'Warn'
    }
    It 'requires the ten providers from the Learn prerequisites' {
        $ns = $script:ArcRequiredProviders | Where-Object { $_.Required } | ForEach-Object { $_.Namespace }
        foreach ($n in 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.Insights', 'Microsoft.Authorization') {
            $ns | Should -Contain $n
        }
    }
    It 'validates GUIDs' {
        Test-ValidGuid $script:Sub | Should -BeTrue
        Test-ValidGuid 'nope' | Should -BeFalse
    }
}

Describe 'Test-ArcRoleSanity' {
    It 'Owner passes' {
        (Test-ArcRoleSanity -RoleGuids @($script:ArcRoleIds.Owner)).Status | Should -Be 'Pass'
    }
    It 'the two Azure Connected Machine roles pass' {
        (Test-ArcRoleSanity -RoleGuids @($script:ArcRoleIds.ConnectedMachineOnboarding, $script:ArcRoleIds.ConnectedMachineResourceAdmin)).Status | Should -Be 'Pass'
    }
    It 'only one of the two Arc roles fails and names the missing one' {
        $r = Test-ArcRoleSanity -RoleGuids @($script:ArcRoleIds.ConnectedMachineOnboarding)
        $r.Status | Should -Be 'Fail'
        $r.Missing | Should -Be @('Azure Connected Machine Resource Administrator')
    }
    It 'Contributor plus access administrator only warns' {
        (Test-ArcRoleSanity -RoleGuids @($script:ArcRoleIds.Contributor, $script:ArcRoleIds.UserAccessAdministrator)).Status | Should -Be 'Warn'
        (Test-ArcRoleSanity -RoleGuids @($script:ArcRoleIds.Contributor, $script:ArcRoleIds.RbacAdministrator)).Status | Should -Be 'Warn'
    }
    It 'nothing fails with both roles missing' {
        $r = Test-ArcRoleSanity -RoleGuids @()
        $r.Status | Should -Be 'Fail'
        $r.Missing.Count | Should -Be 2
    }
    It 'is case insensitive' {
        (Test-ArcRoleSanity -RoleGuids @($script:ArcRoleIds.Owner.ToUpperInvariant())).Status | Should -Be 'Pass'
    }
    It 'extracts role GUIDs from a roleAssignments response' {
        $v = @([pscustomobject]@{ properties = [pscustomobject]@{ roleDefinitionId = "/subscriptions/$($script:Sub)/providers/Microsoft.Authorization/roleDefinitions/$($script:ArcRoleIds.Owner)" } })
        Get-RoleGuidsFromAssignments -Assignments $v | Should -Be @($script:ArcRoleIds.Owner)
    }
}

Describe 'Start-ArcDeviceCodeSignIn' {
    BeforeEach { Clear-ArcSession; Mock Start-Sleep { } }
    It 'polls through authorization_pending and keeps the token in memory only' {
        $script:calls = 0
        Mock Invoke-RestMethod {
            if ($Uri -like '*devicecode') { return [pscustomobject]@{ message = 'To sign in, open https://microsoft.com/devicelogin and enter code ABC123'; device_code = 'dc'; interval = 1; expires_in = 900 } }
            $script:calls++
            if ($script:calls -lt 3) {
                $ex = [System.Net.Http.HttpRequestException]::new('pending')
                $er = [System.Management.Automation.ErrorRecord]::new($ex, 'x', 'NotSpecified', $null)
                $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":"authorization_pending"}')
                throw $er
            }
            return [pscustomobject]@{ access_token = $script:Jwt }
        }
        $r = Start-ArcDeviceCodeSignIn -TenantId 'organizations'
        $r.Ok | Should -BeTrue
        $script:ArcToken | Should -Be $script:Jwt
        $script:calls | Should -Be 3
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like 'https://login.microsoftonline.com/organizations/oauth2/v2.0/*' }
    }
    It 'uses the sovereign login host for US Government' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*devicecode') { return [pscustomobject]@{ message = 'm'; device_code = 'dc'; interval = 1; expires_in = 900 } }
            return [pscustomobject]@{ access_token = 't' }
        }
        $null = Start-ArcDeviceCodeSignIn -Cloud 'AzureUSGovernment'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like 'https://login.microsoftonline.us/*' }
    }
    It 'stops on a declined or expired sign-in' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*devicecode') { return [pscustomobject]@{ message = 'm'; device_code = 'dc'; interval = 1; expires_in = 900 } }
            $er = [System.Management.Automation.ErrorRecord]::new([Exception]::new('x'), 'x', 'NotSpecified', $null)
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":"authorization_declined"}')
            throw $er
        }
        $r = Start-ArcDeviceCodeSignIn
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'authorization_declined'
        $script:ArcToken | Should -BeNullOrEmpty
    }
    It 'fails cleanly when the device code request itself fails' {
        Mock Invoke-RestMethod { throw 'network down' }
        (Start-ArcDeviceCodeSignIn).Ok | Should -BeFalse
    }
}

Describe 'Invoke-ArcReadinessChecks' {
    BeforeEach {
        $script:AllResults = New-Object System.Collections.Generic.List[object]
        $script:CriticalFail = $false
        $script:ArcToken = $script:Jwt
        Mock Test-ArcEnvCheckerPrerequisites { @{ CanRun = $false; Reason = 'not available in this image: Az.Accounts' } }
        $script:In = @{ SubscriptionId = $script:Sub; ResourceGroup = 'rg-example'; NodeNames = @('node01'); TenantId = 'organizations' }
        $script:ownerAssignment = @{ value = @(@{ properties = @{ roleDefinitionId = "/x/roleDefinitions/$($script:ArcRoleIds.Owner)" } }) }
        $script:ProviderState = @{}; $script:RgStatus = 200; $script:Assignments = $script:ownerAssignment; $script:MachineStatus = 404; $script:Paged = $false
        Mock Invoke-RestMethod {
            $fail = { param($code) $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$code); throw [Microsoft.PowerShell.Commands.HttpResponseException]::new("HTTP $code", $resp) }
            if ($Uri -match '/providers/(Microsoft\.[A-Za-z]+)\?api-version=2021-04-01') {
                $state = 'Registered'
                if ($script:ProviderState.ContainsKey($Matches[1])) { $state = $script:ProviderState[$Matches[1]] }
                return [pscustomobject]@{ registrationState = $state }
            }
            if ($Uri -match '/resourcegroups/[^/?]+\?') { if ($script:RgStatus -eq 200) { return [pscustomobject]@{ location = 'eastus' } } else { & $fail $script:RgStatus } }
            if ($Uri -match 'page=2') { return ($script:Assignments | ConvertTo-Json -Depth 6 | ConvertFrom-Json) }
            if ($Uri -match 'roleAssignments') {
                if ($script:Paged) { return [pscustomobject]@{ value = @(); nextLink = 'https://management.azure.com/next?page=2' } }
                return ($script:Assignments | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
            }
            if ($Uri -match 'HybridCompute/machines/') { if ($script:MachineStatus -eq 200) { return [pscustomobject]@{ name = 'node01' } } else { & $fail $script:MachineStatus } }
            if ($Uri -match '/subscriptions/[0-9a-f-]{36}\?api-version') { return [pscustomobject]@{ state = 'Enabled' } }
            throw "unexpected $Uri"
        }
    }
    AfterEach { Clear-ArcSession }

    It 'passes everything for a ready subscription and clears the token afterwards' {
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        @($script:AllResults | Where-Object { $_.Status -eq 'Fail' }).Count | Should -Be 0
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-RP-Microsoft.HybridCompute' }).Status | Should -Be 'Pass'
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-RoleAssignments' }).Status | Should -Be 'Pass'
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-NodeName-node01' }).Status | Should -Be 'Pass'
        $script:ArcToken | Should -BeNullOrEmpty
    }
    It 'itemises one result per resource provider' {
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        @($script:AllResults | Where-Object { $_.Name -like 'Arc-RP-*' }).Count | Should -Be $script:ArcRequiredProviders.Count
    }
    It 'fails an unregistered required provider with the register command' {
        $script:ProviderState = @{ 'Microsoft.ResourceConnector' = 'NotRegistered' }
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        $r = $script:AllResults | Where-Object { $_.Name -eq 'Arc-RP-Microsoft.ResourceConnector' }
        $r.Status | Should -Be 'Fail'
        $r.Severity | Should -Be 'critical'
        $r.Remediation | Should -Match 'az provider register --namespace Microsoft.ResourceConnector'
        $script:CriticalFail | Should -BeTrue
    }
    It 'only warns for the optional AKS provider' {
        $script:ProviderState = @{ 'Microsoft.HybridContainerService' = 'NotRegistered' }
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-RP-Microsoft.HybridContainerService' }).Status | Should -Be 'Warn'
    }
    It 'fails when the identity lacks the Arc roles' {
        $script:Assignments = @{ value = @() }
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        $r = $script:AllResults | Where-Object { $_.Name -eq 'Arc-RoleAssignments' }
        $r.Status | Should -Be 'Fail'
        $r.Remediation | Should -Match 'Azure Connected Machine Onboarding'
    }
    It 'follows nextLink when listing role assignments (Owner on page 2 is found)' {
        $script:Paged = $true
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-RoleAssignments' }).Status | Should -Be 'Pass'
    }
    It 'warns when the resource group does not exist and skips node checks' {
        $script:RgStatus = 404
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-ResourceGroup' }).Status | Should -Be 'Warn'
        @($script:AllResults | Where-Object { $_.Name -like 'Arc-NodeName-*' }).Count | Should -Be 0
    }
    It 'warns about an existing Arc machine with a node name' {
        $script:MachineStatus = 200
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-NodeName-node01' }).Status | Should -Be 'Warn'
    }
    It 'never writes the subscription id or the token into any result' {
        Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null
        $all = $script:AllResults | ConvertTo-Json -Depth 5
        $all | Should -Not -Match $script:Sub
        $all | Should -Not -Match [regex]::Escape($script:Jwt)
        $all | Should -Match '\*{8}-\*{4}-\*{4}-\*{4}-\*{8}5555'
    }
    It 'rejects a non-GUID subscription before any call' {
        Mock Invoke-RestMethod { throw 'must not be called' }
        $bad = $script:In.Clone(); $bad.SubscriptionId = 'not-a-guid'
        Invoke-ArcReadinessChecks -ArcInputs $bad -SkipSignIn 6>$null
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-Input-Subscription' }).Status | Should -Be 'Fail'
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'clears the token even when a check throws' {
        Mock Invoke-RestMethod { throw 'unexpected' }
        Mock Invoke-ArcRest { throw 'internal failure' }
        { Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null } | Should -Throw
        $script:ArcToken | Should -BeNullOrEmpty
    }
    It 'reports a failed sign-in as Fail and does not continue' {
        $script:ArcToken = $null
        Mock Start-ArcDeviceCodeSignIn { @{ Ok = $false; Error = 'sign-in failed: authorization_declined' } }
        Invoke-ArcReadinessChecks -ArcInputs $script:In 6>$null
        ($script:AllResults | Where-Object { $_.Name -eq 'Arc-SignIn' }).Status | Should -Be 'Fail'
        $script:AllResults.Count | Should -Be 1
    }
    It 'never writes anything to disk' {
        Mock Set-Content { throw 'disk write' }
        Mock Out-File { throw 'disk write' }
        Mock Add-Content { throw 'disk write' }
        { Invoke-ArcReadinessChecks -ArcInputs $script:In -SkipSignIn 6>$null } | Should -Not -Throw
    }
}

Describe 'Environment Checker Arc-integration validator (needs Az)' {
    BeforeEach { $script:AllResults = New-Object System.Collections.Generic.List[object] }
    It 'is Skipped with a clear reason when the Az modules are not in the image' {
        Mock Get-Module { $null } -ParameterFilter { $ListAvailable }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-AzureStackHCI' }
        $pre = Test-ArcEnvCheckerPrerequisites
        $pre.CanRun | Should -BeFalse
        $pre.Reason | Should -Match 'Az.Accounts'
        $pre.Reason | Should -Match 'Get-AzureStackHCI'
        Invoke-ArcEnvCheckerValidator -ArcInputs @{ SubscriptionId = 'x'; ResourceGroup = 'r'; NodeNames = @('n') } 6>$null
        $r = $script:AllResults[0]
        $r.Status | Should -Be 'Skip'
        $r.Detail | Should -Match 'Skipped'
    }
}

Describe 'Menu path (memory only)' {
    It 'the Arc menu passes ids only through environment variables and clears them' {
        $src = Get-Content (Join-Path $script:Root 'src\Start-AzlBeacon.ps1') -Raw
        $src | Should -Match 'Set-ArcEnvironment'
        $src | Should -Match 'finally\s*\{\s*Clear-ArcEnvironment'
        $src | Should -Not -Match 'arc-validate\.ps1'
        $src | Should -Not -Match 'Connect-AzAccount'
    }
    It 'no in-image script writes a token or subscription id to disk' {
        foreach ($f in Get-ChildItem (Join-Path $script:Root 'src\lib\Beacon.Arc.ps1')) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match 'Set-Content|Out-File|Add-Content|\[IO\.File\]::Write'
        }
    }
}
