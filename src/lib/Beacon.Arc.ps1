# AzL Beacon - Arc readiness checks that need NO Az PowerShell modules.
#
# Design (see docs/validation/arc-readiness.md):
#   * Sign-in: OAuth2 device-code flow against the Microsoft identity platform with Invoke-RestMethod.
#   * Checks: Azure Resource Manager REST (resource provider state, resource group, node-name
#     collisions, role assignments of the signed-in identity).
#   * The access token and the subscription/tenant ids live in memory only. Nothing is written to
#     disk; results carry a MASKED subscription id. Clear-ArcSession runs in a finally block.
# PowerShell 5.1 (WinPE) and 7 compatible.

# Public client id of the Azure CLI (documented, public, not tenant data). Override with -ClientId.
$script:ArcDefaultClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'

# Learn: Azure Local deployment prerequisites and Arc-enabled servers prerequisites.
$script:ArcRequiredProviders = @(
    @{ Namespace = 'Microsoft.HybridCompute';          Required = $true;  Why = 'Arc-enabled servers (the nodes)' },
    @{ Namespace = 'Microsoft.GuestConfiguration';     Required = $true;  Why = 'Guest configuration / extension management' },
    @{ Namespace = 'Microsoft.HybridConnectivity';     Required = $true;  Why = 'Connectivity endpoints for Arc machines' },
    @{ Namespace = 'Microsoft.AzureStackHCI';          Required = $true;  Why = 'Azure Local resource provider' },
    @{ Namespace = 'Microsoft.Kubernetes';             Required = $true;  Why = 'Arc-enabled Kubernetes' },
    @{ Namespace = 'Microsoft.KubernetesConfiguration'; Required = $true; Why = 'Kubernetes extensions / Flux' },
    @{ Namespace = 'Microsoft.ExtendedLocation';       Required = $true;  Why = 'Custom locations' },
    @{ Namespace = 'Microsoft.ResourceConnector';      Required = $true;  Why = 'Arc resource bridge' },
    @{ Namespace = 'Microsoft.Insights';               Required = $true;  Why = 'Diagnostics and Key Vault audit logging during validation' },
    @{ Namespace = 'Microsoft.Authorization';          Required = $true;  Why = 'Role assignments' },
    @{ Namespace = 'Microsoft.HybridContainerService'; Required = $false; Why = 'AKS Arc (only if AKS workloads are planned)' }
)

# Built-in role definition ids (stable across tenants).
$script:ArcRoleIds = @{
    Owner                         = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    Contributor                   = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    UserAccessAdministrator       = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
    RbacAdministrator             = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
    ConnectedMachineOnboarding    = 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'
    ConnectedMachineResourceAdmin = 'cd570a14-e51a-42ad-bac8-bafd67325302'
}

$script:ArcToken = $null

#region ---- pure helpers ----

function Get-ArcCloudProfile {
    param([ValidateSet('AzureCloud', 'AzureUSGovernment')] [string]$Cloud = 'AzureCloud')
    if ($Cloud -eq 'AzureUSGovernment') {
        return @{ Cloud = $Cloud; Login = 'https://login.microsoftonline.us'; Arm = 'https://management.usgovcloudapi.net'; Scope = 'https://management.core.usgovcloudapi.net/.default' }
    }
    return @{ Cloud = $Cloud; Login = 'https://login.microsoftonline.com'; Arm = 'https://management.azure.com'; Scope = 'https://management.azure.com/.default' }
}

function Format-MaskedId {
    <# 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxa1b2' -> '********-****-****-****-********a1b2'. Results never contain full ids. #>
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    $tail = $Id.Substring([math]::Max(0, $Id.Length - 4))
    return "********-****-****-****-********$tail"
}

function ConvertFrom-JwtPayload {
    <# Decodes the payload of a JWT (no signature validation; read-only convenience). Returns $null if malformed. #>
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } 1 { return $null } }
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function Get-ProviderVerdict {
    param([string]$State, [bool]$Required = $true)
    switch -Regex ($State) {
        '^Registered$' { return 'Pass' }
        '^Registering$' { return 'Warn' }
        '^(NotRegistered|Unregistered|Unregistering)$' { if ($Required) { return 'Fail' } else { return 'Warn' } }
        default { return 'Warn' }
    }
}

function Test-ArcRoleSanity {
    <#
    Pure. Input: role-definition GUIDs held by the signed-in identity at (or inherited into) the target
    resource group. Learn: to register Arc machines you must be Owner of the resource group OR hold
    'Azure Connected Machine Onboarding' + 'Azure Connected Machine Resource Administrator'.
    For the Azure Local deployment itself Contributor + (User Access Administrator or RBAC Administrator)
    is also acceptable.
    #>
    param([string[]]$RoleGuids = @())
    $have = @($RoleGuids | ForEach-Object { "$_".ToLowerInvariant() })
    $has = { param($k) $have -contains $script:ArcRoleIds[$k] }
    if (& $has 'Owner') { return @{ Status = 'Pass'; Detail = 'Owner'; Missing = @() } }
    $arcOk = (& $has 'ConnectedMachineOnboarding') -and (& $has 'ConnectedMachineResourceAdmin')
    $deployOk = (& $has 'Contributor') -and ((& $has 'UserAccessAdministrator') -or (& $has 'RbacAdministrator'))
    if ($arcOk) { return @{ Status = 'Pass'; Detail = 'Azure Connected Machine Onboarding + Resource Administrator'; Missing = @() } }
    if ($deployOk) {
        return @{ Status = 'Warn'; Detail = 'Contributor + access administrator present, but the two Azure Connected Machine roles are missing (needed to register Arc machines unless you are Owner)'; Missing = @('Azure Connected Machine Onboarding', 'Azure Connected Machine Resource Administrator') }
    }
    $missing = New-Object System.Collections.Generic.List[string]
    if (-not (& $has 'ConnectedMachineOnboarding')) { $missing.Add('Azure Connected Machine Onboarding') }
    if (-not (& $has 'ConnectedMachineResourceAdmin')) { $missing.Add('Azure Connected Machine Resource Administrator') }
    return @{ Status = 'Fail'; Detail = 'Neither Owner nor the two Azure Connected Machine roles found on the resource group'; Missing = $missing.ToArray() }
}

function Get-RoleGuidsFromAssignments {
    <# value[] of a roleAssignments list response -> GUID list (last path segment of roleDefinitionId). #>
    param([object[]]$Assignments)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Assignments)) {
        $rid = ''
        if ($a.PSObject.Properties.Name -contains 'properties') { $rid = "$($a.properties.roleDefinitionId)" }
        if ($rid -match '([0-9a-fA-F-]{36})$') { $out.Add($Matches[1].ToLowerInvariant()) }
    }
    return $out.ToArray()
}

function Test-ValidGuid {
    param([string]$Text)
    $g = [guid]::Empty
    return [guid]::TryParse("$Text", [ref]$g)
}

#endregion

#region ---- REST plumbing ----

function Get-RestErrorInfo {
    <# Status code and body from an Invoke-RestMethod failure, PS 5.1 and 7. #>
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $status = 0
    $body = ''
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) { $status = [int]$resp.StatusCode }
    } catch { Write-Verbose 'no response object' }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    elseif ($status -gt 0) {
        try {
            $sr = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            $body = $sr.ReadToEnd()
            $sr.Close()
        } catch { Write-Verbose 'could not read error body' }
    }
    return @{ Status = $status; Body = $body; Message = $ErrorRecord.Exception.Message }
}

function Invoke-ArcRest {
    <# Wraps Invoke-RestMethod. Returns @{ Ok; Status; Body; Error }. Never throws. #>
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Token = '',
        [hashtable]$Form = $null,
        [string]$ProxyUrl = ''
    )
    $p = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = 30 }
    if ($Token) { $p.Headers = @{ Authorization = "Bearer $Token" } }
    if ($Form) { $p.Body = $Form; $p.ContentType = 'application/x-www-form-urlencoded' }
    if ($ProxyUrl) { $p.Proxy = $ProxyUrl }
    try {
        $body = Invoke-RestMethod @p
        return @{ Ok = $true; Status = 200; Body = $body; Error = '' }
    } catch {
        $info = Get-RestErrorInfo -ErrorRecord $_
        $parsed = $null
        if ($info.Body) { try { $parsed = $info.Body | ConvertFrom-Json } catch { $parsed = $null } }
        return @{ Ok = $false; Status = $info.Status; Body = $parsed; Error = $info.Message }
    }
}

#endregion

#region ---- sign-in ----

function Start-ArcDeviceCodeSignIn {
    <#
    OAuth2 device-code flow. Prints the verification URL and code, then polls until the operator
    signs in. Returns @{ Ok; Error }. On success the token is held in $script:ArcToken (memory only).
    #>
    param(
        [string]$TenantId = 'organizations',
        [string]$Cloud = 'AzureCloud',
        [string]$ClientId = $script:ArcDefaultClientId,
        [string]$ProxyUrl = '',
        [int]$MaxWaitSeconds = 900
    )
    Enable-BeaconTls12
    $prof = Get-ArcCloudProfile -Cloud $Cloud
    $dc = Invoke-ArcRest -Method POST -Uri "$($prof.Login)/$TenantId/oauth2/v2.0/devicecode" -ProxyUrl $ProxyUrl `
        -Form @{ client_id = $ClientId; scope = $prof.Scope }
    if (-not $dc.Ok) { return @{ Ok = $false; Error = "device code request failed: $($dc.Error)" } }
    $dcBody = $dc.Body
    Write-Information "" -InformationAction Continue
    Write-Information "  $($dcBody.message)" -InformationAction Continue
    Write-Information "" -InformationAction Continue

    $interval = [int]$dcBody.interval
    if ($interval -lt 1) { $interval = 5 }
    $deadline = [DateTime]::UtcNow.AddSeconds([math]::Min($MaxWaitSeconds, [int]$dcBody.expires_in))
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $tok = Invoke-ArcRest -Method POST -Uri "$($prof.Login)/$TenantId/oauth2/v2.0/token" -ProxyUrl $ProxyUrl `
            -Form @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $ClientId; device_code = $dcBody.device_code }
        if ($tok.Ok) {
            $script:ArcToken = $tok.Body.access_token
            return @{ Ok = $true; Error = '' }
        }
        $code = ''
        if ($tok.Body -and ($tok.Body.PSObject.Properties.Name -contains 'error')) { $code = "$($tok.Body.error)" }
        switch ($code) {
            'authorization_pending' { continue }
            'slow_down' { $interval += 5; continue }
            default { return @{ Ok = $false; Error = "sign-in failed: $code" } }
        }
    }
    return @{ Ok = $false; Error = 'sign-in timed out' }
}

function Clear-ArcSession {
    $script:ArcToken = $null
}

#endregion

#region ---- checks ----

function Invoke-ArcReadinessChecks {
    <#
    Runs the Arc checks and records itemised results (category Cat-6-Arc).
    $Inputs: @{ SubscriptionId; TenantId; ResourceGroup; NodeNames; Cloud; ProxyUrl; ClientId }
    -SkipSignIn is for callers that already hold a token in $script:ArcToken (tests).
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$ArcInputs,
        [switch]$SkipSignIn
    )
    $cat = 'Cat-6-Arc'
    $learn = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions'
    $sub = "$($ArcInputs.SubscriptionId)"
    $maskedSub = Format-MaskedId $sub
    $rg = "$($ArcInputs.ResourceGroup)"
    $cloud = 'AzureCloud'
    if ($ArcInputs.ContainsKey('Cloud') -and $ArcInputs.Cloud) { $cloud = $ArcInputs.Cloud }
    $proxy = ''
    if ($ArcInputs.ContainsKey('ProxyUrl') -and $ArcInputs.ProxyUrl) { $proxy = $ArcInputs.ProxyUrl }
    $tenant = 'organizations'
    if ($ArcInputs.ContainsKey('TenantId') -and $ArcInputs.TenantId) { $tenant = $ArcInputs.TenantId }
    $prof = Get-ArcCloudProfile -Cloud $cloud

    try {
        if (-not (Test-ValidGuid $sub)) {
            Add-ValidationResult -Category $cat -Name 'Arc-Input-Subscription' -Target 'subscription' -Status 'Fail' -Severity 'critical' `
                -Detail 'Subscription id is not a GUID' -Remediation 'Enter the subscription id (GUID) of the target Azure subscription.' -Source $learn
            return
        }

        # --- sign-in ---
        if (-not $SkipSignIn) {
            $clientId = $script:ArcDefaultClientId
            if ($ArcInputs.ContainsKey('ClientId') -and $ArcInputs.ClientId) { $clientId = $ArcInputs.ClientId }
            $si = Start-ArcDeviceCodeSignIn -TenantId $tenant -Cloud $cloud -ProxyUrl $proxy -ClientId $clientId
            if (-not $si.Ok) {
                Add-ValidationResult -Category $cat -Name 'Arc-SignIn' -Target $prof.Login -Status 'Fail' -Severity 'critical' `
                    -Detail $si.Error -Remediation 'Check outbound access to login.microsoftonline.com and complete the device-code prompt on another device.' -Source $learn
                return
            }
        }
        if (-not $script:ArcToken) {
            Add-ValidationResult -Category $cat -Name 'Arc-SignIn' -Target $prof.Login -Status 'Skip' -Detail 'No access token'
            return
        }
        $claims = ConvertFrom-JwtPayload $script:ArcToken
        $oid = ''
        if ($claims -and ($claims.PSObject.Properties.Name -contains 'oid')) { $oid = "$($claims.oid)" }
        Add-ValidationResult -Category $cat -Name 'Arc-SignIn' -Target $prof.Login -Status 'Pass' -Detail 'Device-code sign-in succeeded (token held in memory only)' -Source $learn

        $arm = $prof.Arm
        $tok = $script:ArcToken

        # --- subscription ---
        $s = Invoke-ArcRest -Uri "$arm/subscriptions/${sub}?api-version=2022-12-01" -Token $tok -ProxyUrl $proxy
        if ($s.Ok) {
            $state = "$($s.Body.state)"
            if ($state -eq 'Enabled') {
                Add-ValidationResult -Category $cat -Name 'Arc-Subscription' -Target $maskedSub -Status 'Pass' -Detail 'Subscription visible and Enabled'
            } else {
                Add-ValidationResult -Category $cat -Name 'Arc-Subscription' -Target $maskedSub -Status 'Fail' -Severity 'critical' -Detail "Subscription state is '$state'" -Remediation 'Use an Enabled subscription.'
            }
        } else {
            Add-ValidationResult -Category $cat -Name 'Arc-Subscription' -Target $maskedSub -Status 'Fail' -Severity 'critical' `
                -Detail "Cannot read subscription (HTTP $($s.Status))" -Remediation 'Confirm the id, the tenant you signed in to, and that your account has at least Reader on the subscription.'
            return
        }

        # --- resource providers ---
        foreach ($rp in $script:ArcRequiredProviders) {
            $r = Invoke-ArcRest -Uri "$arm/subscriptions/$sub/providers/$($rp.Namespace)?api-version=2021-04-01" -Token $tok -ProxyUrl $proxy
            if (-not $r.Ok) {
                Add-ValidationResult -Category $cat -Name "Arc-RP-$($rp.Namespace)" -Target $rp.Namespace -Status 'Warn' -Detail "Could not read provider state (HTTP $($r.Status))"
                continue
            }
            $verdict = Get-ProviderVerdict -State "$($r.Body.registrationState)" -Required $rp.Required
            $sev = 'warning'
            if ($rp.Required) { $sev = 'critical' }
            $rem = ''
            if ($verdict -ne 'Pass') { $rem = "az provider register --namespace $($rp.Namespace)   (needs Owner or Contributor on the subscription)" }
            Add-ValidationResult -Category $cat -Name "Arc-RP-$($rp.Namespace)" -Target $rp.Namespace -Status $verdict -Severity $sev `
                -Detail "$($r.Body.registrationState) -- $($rp.Why)" -Remediation $rem -Source 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions'
        }

        # --- resource group ---
        $rgExists = $false
        if ($rg) {
            $g = Invoke-ArcRest -Uri "$arm/subscriptions/$sub/resourcegroups/${rg}?api-version=2021-04-01" -Token $tok -ProxyUrl $proxy
            if ($g.Ok) {
                $rgExists = $true
                Add-ValidationResult -Category $cat -Name 'Arc-ResourceGroup' -Target $rg -Status 'Pass' -Detail "Exists in $($g.Body.location)"
            } elseif ($g.Status -eq 404) {
                Add-ValidationResult -Category $cat -Name 'Arc-ResourceGroup' -Target $rg -Status 'Warn' -Severity 'warning' -Detail 'Resource group does not exist yet' `
                    -Remediation 'Create it before registering the nodes (Learn: create a resource group for the machines).' -Source $learn
            } else {
                Add-ValidationResult -Category $cat -Name 'Arc-ResourceGroup' -Target $rg -Status 'Warn' -Detail "Could not read resource group (HTTP $($g.Status))"
            }
        } else {
            Add-ValidationResult -Category $cat -Name 'Arc-ResourceGroup' -Target 'resourceGroup' -Status 'Skip' -Detail 'No resource group given'
        }

        # --- role assignment sanity ---
        if ($oid -and (Test-ValidGuid $oid)) {
            $scopeLabel = 'subscription'
            $scope = "/subscriptions/$sub"
            if ($rgExists) { $scope = "/subscriptions/$sub/resourceGroups/$rg"; $scopeLabel = 'resourceGroup' }
            $uri = "$arm$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&%24filter=assignedTo(%27$oid%27)"
            $ra = Invoke-ArcRest -Uri $uri -Token $tok -ProxyUrl $proxy
            $allAssignments = New-Object System.Collections.Generic.List[object]
            $pages = 0
            while ($ra.Ok) {
                foreach ($v in @($ra.Body.value)) { $allAssignments.Add($v) }
                $pages++
                $next = ''
                if ($ra.Body -and ($ra.Body.PSObject.Properties.Name -contains 'nextLink')) { $next = "$($ra.Body.nextLink)" }
                if (-not $next -or $pages -ge 20) { break }
                $ra = Invoke-ArcRest -Uri $next -Token $tok -ProxyUrl $proxy
            }
            if ($ra.Ok) {
                $guids = Get-RoleGuidsFromAssignments -Assignments @($allAssignments.ToArray())
                $verdict = Test-ArcRoleSanity -RoleGuids $guids
                $sev = ''
                $rem = ''
                if ($verdict.Status -ne 'Pass') {
                    $sev = 'critical'
                    $rem = "Assign on the resource group: $($verdict.Missing -join ', '), or make the registering identity Owner of the resource group."
                }
                Add-ValidationResult -Category $cat -Name 'Arc-RoleAssignments' -Target $scopeLabel -Status $verdict.Status -Severity $sev `
                    -Detail "$($verdict.Detail) ($(@($guids).Count) assignment(s) seen incl. inherited)" -Remediation $rem -Source $learn
            } else {
                Add-ValidationResult -Category $cat -Name 'Arc-RoleAssignments' -Target 'roleAssignments' -Status 'Warn' `
                    -Detail "Could not read role assignments (HTTP $($ra.Status)); verify Azure Connected Machine Onboarding + Resource Administrator manually" -Source $learn
            }
        } else {
            Add-ValidationResult -Category $cat -Name 'Arc-RoleAssignments' -Target 'roleAssignments' -Status 'Skip' -Detail 'Token has no object id (oid) claim'
        }

        # --- node-name collisions ---
        if ($rg -and $rgExists) {
            foreach ($n in @($ArcInputs.NodeNames)) {
                if (-not $n) { continue }
                $m = Invoke-ArcRest -Uri "$arm/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/${n}?api-version=2024-07-10" -Token $tok -ProxyUrl $proxy
                if ($m.Ok) {
                    Add-ValidationResult -Category $cat -Name "Arc-NodeName-$n" -Target $n -Status 'Warn' -Severity 'warning' `
                        -Detail 'An Arc machine with this name already exists in the resource group' `
                        -Remediation 'Remove the stale Arc resource or choose a different node name before registration.'
                } elseif ($m.Status -eq 404) {
                    Add-ValidationResult -Category $cat -Name "Arc-NodeName-$n" -Target $n -Status 'Pass' -Detail 'No existing Arc machine with this name'
                } else {
                    Add-ValidationResult -Category $cat -Name "Arc-NodeName-$n" -Target $n -Status 'Warn' -Detail "Could not check (HTTP $($m.Status))"
                }
            }
        }

        # --- vendored Environment Checker Arc-integration validator (needs Az) ---
        Invoke-ArcEnvCheckerValidator -ArcInputs $ArcInputs
    } finally {
        Clear-ArcSession
    }
}

function Test-ArcEnvCheckerPrerequisites {
    <# Returns @{ CanRun; Reason }. The Arc validator in AzStackHci.EnvironmentChecker needs Az.Accounts/Az.Resources, a signed-in Az context and the Azure Local OS cmdlets. #>
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($m in @('Az.Accounts', 'Az.Resources')) {
        if (-not (Get-Module -ListAvailable -Name $m)) { $missing.Add($m) }
    }
    if (-not (Get-Command Get-AzureStackHCI -ErrorAction SilentlyContinue)) { $missing.Add('Get-AzureStackHCI (Azure Local OS cmdlet)') }
    if ($missing.Count -gt 0) {
        return @{ CanRun = $false; Reason = "not available in this image: $($missing -join ', ')" }
    }
    return @{ CanRun = $true; Reason = '' }
}

function Invoke-ArcEnvCheckerValidator {
    param([hashtable]$ArcInputs)
    $cat = 'Cat-6-Arc'
    $name = 'Arc-EnvChecker-IntegrationValidator'
    $target = 'Invoke-AzStackHciArcIntegrationValidation'
    $pre = Test-ArcEnvCheckerPrerequisites
    if (-not $pre.CanRun) {
        Add-ValidationResult -Category $cat -Name $name -Target $target -Status 'Skip' `
            -Detail "Skipped: $($pre.Reason). The REST checks above cover the same ground without Az."
        return
    }
    if (-not (Get-Command $target -ErrorAction SilentlyContinue)) {
        Add-ValidationResult -Category $cat -Name $name -Target $target -Status 'Skip' -Detail 'Skipped: Environment Checker module not loaded (run Category 5 first)'
        return
    }
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Add-ValidationResult -Category $cat -Name $name -Target $target -Status 'Skip' -Detail 'Skipped: no Az context (Connect-AzAccount -DeviceCode first)'
        return
    }
    try {
        $res = & $target -SubscriptionID $ArcInputs.SubscriptionId -ArcResourceGroupName $ArcInputs.ResourceGroup `
            -RegistrationResourceGroupName $ArcInputs.ResourceGroup -NodeNames @($ArcInputs.NodeNames) -PassThru -ErrorAction Stop
        foreach ($i in (ConvertFrom-EnvCheckerResult -Results $res -Category $cat -Prefix 'ArcIntegration')) {
            Add-ValidationResult @i
        }
    } catch {
        Add-ValidationResult -Category $cat -Name $name -Target $target -Status 'Warn' -Detail "Validator threw: $($_.Exception.Message)"
    }
}

#endregion
