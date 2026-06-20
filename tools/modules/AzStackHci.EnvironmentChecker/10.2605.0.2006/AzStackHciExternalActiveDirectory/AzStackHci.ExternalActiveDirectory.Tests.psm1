Import-LocalizedData -BindingVariable lcAdTxt -FileName AzStackHci.ExternalActiveDirectory.Strings.psd1

class ExternalADTest
{
    [string]$TestName
    [scriptblock]$ExecutionBlock
}

$ExternalAdTestInitializors = @(
)

$ExternalAdTests = @(
    (New-Object -Type ExternalADTest -Property @{
        TestName = "RequiredOrgUnitsExist"
        ExecutionBlock = {
            Param ([hashtable]$testContext)

            $serverParams = @{}
            if ($testContext["AdServer"])
            {
                $serverParams += @{Server = $testContext["AdServer"]}
            }
            if ($testContext["AdCredentials"])
            {
                $serverParams += @{Credential = $testContext["AdCredentials"]}
            }

            $requiredOU = $testContext["ADOUPath"]

            Log-Info -Message ("  Checking for the existance of OU: {0}" -f $requiredOU) -Type Info -Function "RequiredOrgUnitsExist"

            try {
                $resultingOU = Get-ADOrganizationalUnit -Identity $requiredOU -ErrorAction SilentlyContinue @serverParams
            }
            catch {
            }

            return @{
                Resource    = $_
                Status      = if ($resultingOU) { 'SUCCESS' } else { 'FAILURE' }
                TimeStamp   = [datetime]::UtcNow
                Source      = $ENV:COMPUTERNAME
                Detail = ($testContext["LcAdTxt"].MissingOURemediation -f $_)
           }
        }
    }),
    (New-Object -Type ExternalADTest -Property @{
        TestName = "LogPhysicalMachineObjectsIfExist"
        ExecutionBlock = {
            Param ([hashtable]$testContext)

            $serverParams = @{}
            if ($testContext["AdServer"])
            {
                $serverParams += @{Server = $testContext["AdServer"]}
            }
            if ($testContext["AdCredentials"])
            {
                $serverParams += @{Credential = $testContext["AdCredentials"]}
            }

            $adOUPath = $testContext["ADOUPath"]
            $domainFQDN = $testContext["DomainFQDN"]
            $seedNode = $ENV:COMPUTERNAME

            $detailedErrors = @()

            #Todo:: Check the domain status for all the nodes, till then don't fail this test case and just log the details for infomration purpose.

            Log-Info -Message (" Validating seednode : {0} is part of a domain or not " -f $seedNode) -Type Info -Function "PhysicalMachineObjectsExist"
            $isDomainJoined = (gwmi win32_computersystem).partofdomain

            $operationType = $ENV:EnvChkrId
            Log-Info -Message (" Env checker id :: {0}" -f $operationType) -Type Info -Function "PhysicalMachineObjectsExist"
                                   
            #Execute the below test if and only if when the machine is not domain joined and operationType does not contain "keepstorage"
            if ((-not $isDomainJoined) -and ($operationType -notmatch "keepstorage"))
            {
                $physicalHostsSetting = @($testContext["PhysicalMachineNames"] | Where-Object { -not [string]::IsNullOrEmpty($_) })
                Log-Info -Message ("  Validating settings for physical hosts: {0}" -f ($physicalHostsSetting -join ", ")) -Type Info -Function "PhysicalMachineObjectsExist"

                try {
                    $allComputerObjects = Get-ADComputer -SearchBase $adOUPath -Filter "*" @serverParams
                }
                catch {
                    Log-Info -Message ("  Failed to find any computer objects in ActiveDirectory.  Inner exception: {0}" -f $_) -Type Error -Function "PhysicalMachineObjectsExist"
                    $allComputerObjects = @()
                }

                $foundPhysicalHosts = @($allComputerObjects | Where-Object {$_.Name -in $physicalHostsSetting})
                if ($foundPhysicalHosts.count -gt 0)
                {
                    foreach ($physicalHost in $foundPhysicalHosts)
                    {
                        $detailedErrors += "  Computer object for {0} found in AD and it's DistinguishedName :: {1}. Please remove the computer object." -f $($physicalHost.Name), $($physicalHost.DistinguishedName)                    
                    }
                }

                $missingPhysicalHostEntries = @($physicalHostsSetting | Where-Object {$_ -notin $allComputerObjects.Name})

                Log-Info -Message ("  Found {0} entries in AD : {1}" -f $foundPhysicalHosts.Count,($foundPhysicalHosts.Name -join ", ")) -Type Info -Function "PhysicalMachineObjectsExist"
                $timeoutSeconds = 60

                if ($missingPhysicalHostEntries.Count -gt 0)
                {
                    $jobs = foreach ($physicalHost in $missingPhysicalHostEntries)
                            {
                                start-job -ScriptBlock {
                                    param($computerName, $serverparams)
                                    Import-Module ActiveDirectory
                                    Get-ADComputer -Filter "Name -eq '$computerName' " @serverparams
                                } -ArgumentList $physicalHost, $serverParams
                            }
                    # Wait for all jobs to complete or timeout
                    Wait-Job -Job $jobs -Timeout $timeoutSeconds | Out-Null

                    # Check the status of each job and display the results
                    foreach ($job in $jobs) {
                        $status = $job.State
                        if ($status -eq 'Completed') {
                            $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
                            if ($result) {
                                Log-Info -Message ("  Found physical host {0} in AD and it's DistinguishedName :: {1}. Please remove the computer object." -f $($result.Name), $($result.DistinguishedName)) -Type Error -Function "PhysicalMachineObjectsExist"
                                $detailedErrors += "  Found physical host {0} in AD and it's DistinguishedName :: {1}. Please remove the computer object." -f $($result.Name), $($result.DistinguishedName)
                            }
                        } elseif ($status -eq 'Running') {
                            Stop-Job -Job $job -ErrorAction Ignore | Out-Null
                        }
                        # Clean up the job
                        Remove-Job -Job $job -ErrorAction Ignore | Out-Null
                    }
                }
            }

            # We are not failing this test case and getting the information for logging purpose.
            if ($detailedErrors.Count -gt 0) {
                    $detail = $detailedErrors -join "; "
                    $statusValue = 'SUCCESS'
            }
            else
            {
                    $statusValue = 'SUCCESS'
                    $detail = ""
            }

            $results += @{
                    Resource    = "PhysicalHostAdComputerEntries"
                    Status      = $statusValue
                    TimeStamp   = [datetime]::UtcNow
                    Source      = $ENV:COMPUTERNAME
                    Detail = $detail
            }
            return $results
        }
    }),
    (New-Object -Type ExternalADTest -Property @{
        TestName = "LogClusterObjectIfExist"
        ExecutionBlock = {
            Param ([hashtable]$testContext)

            $serverParams = @{}
            if ($testContext["AdServer"])
            {
                $serverParams += @{Server = $testContext["AdServer"]}
            }
            if ($testContext["AdCredentials"])
            {
                $serverParams += @{Credential = $testContext["AdCredentials"]}
            }

            $adOUPath = $testContext["ADOUPath"]
            $domainFQDN = $testContext["DomainFQDN"]
            $seedNode = $ENV:COMPUTERNAME
            $clusterName = $testContext["ClusterName"]

                $detail = ""
                Log-Info -Message ("  Validating cluster object {0} is available in {1} " -f $clusterName, $adOUPath) -Type Info -Function "LogClusterObjectIfExist"
                $statusValue = 'SUCCESS'
                try {
                    $clusterObject = Get-ADComputer -SearchBase $adOUPath -Filter "Name -eq '$clusterName' " @serverParams
                }
                catch {
                    Log-Info -Message ("  Failed to find cluster objects in ActiveDirectory.  Inner exception: {0}" -f $_) -Type Error -Function "LogClusterObjectIfExist"
                    $detail = "  Failed to find cluster objects in ActiveDirectory.  Inner exception: {0}" -f $_
                    $statusValue = 'FAILURE'
                }

                if ($clusterObject)
                {
                    $detail = ("Cluster object {0} available in {1}" -f $clusterName, $adOUPath)
                }
                else
                {
                    $timeoutSeconds = 60
                    Log-Info -Message ("  Cluster object {0} not found in {1} " -f $clusterName, $adOUPath) -Type Info -Function "LogClusterObjectIfExist"

                    $job = start-job -ScriptBlock {
                                    param($clusterName, $serverparams)
                                    Import-Module ActiveDirectory
                                    Get-ADComputer -Filter "Name -eq '$clusterName' " @serverparams
                                } -ArgumentList $clusterName, $serverParams

                    Wait-Job -Job $job -Timeout $timeoutSeconds | Out-Null

                    $status = $job.State
                    if ($status -eq 'Completed') {
                        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
                        if ($result) {
                            Log-Info -Message ("  Found cluster {0} in AD and it's DistinguishedName :: {1}. Please remove the computer object." -f $($result.Name), $($result.DistinguishedName)) -Type Error -Function "LogClusterObjectIfExist"
                            $detail = "  Found cluster {0} in AD and it's DistinguishedName :: {1}. Please remove the computer object." -f $($result.Name), $($result.DistinguishedName)
                            $statusValue = 'FAILURE'
                        }
                        else
                        {
                            $detail = (" cluster object {0} not found in active directory." -f $clusterName)
                        }
                    }
                    elseif ($status -eq 'Running') {
                        $detail = " Unable to get the cluster object within the timeout and assuming that cluster object is not available on AD"
                        Stop-Job -Job $job -ErrorAction Ignore | Out-Null
                    }
                    else
                    {
                        $detail = " Unable to get the cluster object and assuming that cluster object is not available on AD"
                    }
                    Remove-Job -Job $job -ErrorAction Ignore | Out-Null
                }

                $results += @{
                    Resource    = "ClusterObject"
                    Status      = $statusValue
                    TimeStamp   = [datetime]::UtcNow
                    Source      = $ENV:COMPUTERNAME
                    Detail = $detail
                }
            return $results
        }
    }),
    (New-Object -Type ExternalADTest -Property @{
        TestName = "GpoInheritanceIsBlocked"
        ExecutionBlock = {
            Param ([hashtable]$testContext)

            $serverParams = @{}
            if ($testContext["AdServer"])
            {
                $serverParams += @{Server = $testContext["AdServer"]}
            }
            if ($testContext["AdCredentials"])
            {
                $serverParams += @{Credential = $testContext["AdCredentials"]}
            }

            $ouPath = $testContext["ADOUPath"]

            Log-Info -Message ("  Checking whether gpInheritance is blocked for the OU : {0} " -f $ouPath) -Type Info -Function "GpoInheritanceIsBlocked"
            $statusValue = 'FAILURE'

            try {
                $ou = Get-ADOrganizationalUnit -Identity $ouPath -Properties gpOptions @serverParams
                if ($ou.gpOptions -ne $null)
                {
                    if ($ou.gpOptions -eq 1)
                    {
                        $statusValue = 'SUCCESS'
                        Log-Info -Message ("  gpInheritance is blocked for the OU : {0} and the gpOptions value : {1} " -f $ouPath, $($ou.gpOptions)) -Type Info -Function "GpoInheritanceIsBlocked"
                    }
                    else
                    {
                        Log-Info -Message ("  gpInheritance is not blocked for the OU : {0} and the gpOptions value : {1} " -f $ouPath, $($ou.gpOptions)) -Type Info -Function "GpoInheritanceIsBlocked"
                    }
                }
                else
                {
                    Log-Info -Message ("  gpInheritance is not blocked for the OU : {0} and unable to get the gpOptions property." -f $ouPath) -Type Info -Function "GpoInheritanceIsBlocked"
                }
            }
            catch {
                Log-Info -Message ("  Failed to get the gpInheritance for the OU : {0} and Inner exception: {1}" -f $ouPath, $_) -Type Info -Function "GpoInheritanceIsBlocked"
            }


            return @{
                Resource    = "OuGpoInheritance"
                Status      = $statusValue
                TimeStamp   = [datetime]::UtcNow
                Source      = $ENV:COMPUTERNAME
                Detail = $testContext["LcAdTxt"].OuInheritanceBlockedMissingRemediation
            }
        }
    }),
    (New-Object -Type ExternalADTest -Property @{
        TestName = "ValidateComputerAccountsInAD"
        ExecutionBlock = {
            Param ([hashtable]$testContext)

            $adComputerObjectTests = Test-ADComputerObjects $testContext 

            return @{
                Resource    = "ValidateComputerAccountsInAD"
                Status      = if ($adComputerObjectTests["Result"]) { 'SUCCESS' } else { 'FAILURE' }
                TimeStamp   = [datetime]::UtcNow
                Source      = $ENV:COMPUTERNAME
                Detail = $adComputerObjectTests["FailureReasons"]
            }
        }
    }),
    (New-Object -Type ExternalADTest -Property @{
        TestName = "ConnectivityTests"
        ExecutionBlock = {
            Param ([hashtable]$testContext)

            $connectivityTests = Test-Connectivity $testContext 

            return @{
                Resource    = "ConnectivityTest"
                Status      = if ($connectivityTests["Result"]) { 'SUCCESS' } else { 'FAILURE' }
                TimeStamp   = [datetime]::UtcNow
                Source      = $ENV:COMPUTERNAME
                Detail = $connectivityTests["FailureReasons"]
            }
        }
    }),
    (New-Object -Type ExternalADTest -Property @{
        TestName = "ExecutingAsDeploymentUser"
        ExecutionBlock = {

            Param ([hashtable]$testContext)

            # Values retrieved from the test context
            $adOuPath = $testContext["ADOUPath"]
            [pscredential]$credentials = $testContext["AdCredentials"]
            $credentialName = $null
            $statusValue = 'FAILURE'
            $userHasOuPermissions = $false
            if ($credentials)
            {
                # Get the user SID so we can find it in the ACL
                $credentialParts = $credentials.UserName.Split("\\")
                $credentialName = $credentialParts[$credentialParts.Length-1]
            }
            else
            {
                $credentialName = $env:USERNAME
            }

            $serverParams = @{}
            if ($TestContext["AdServer"])
            {
                $serverParams += @{Server = $TestContext["AdServer"]}
            }
            if ($TestContext["AdCredentials"])
            {
                $serverParams += @{Credential = $TestContext["AdCredentials"]}
            }
            $timeoutSeconds = 300
            $failureReasons = @()
            try 
            {
                $deploymentUserIdentifier = Get-ADUser -Identity $credentialName -SearchBase $adOuPath @serverParams
            }
            catch 
            {
                Log-Info -Message ("  LCM user '{0}' not found in {1} " -f $credentialName, $adOuPath) -Type Info -Function "ExecutingAsDeploymentUser"
            }

            # If the LCM user is not part of the OUPath try to query the entire AD and get the details"
            if (-not $deploymentUserIdentifier)
            {
                $lcmUserJob = start-job -ScriptBlock {
                                param($lcmUserName, $serverparams)
                                Import-Module ActiveDirectory
                                Get-ADUser -Identity $lcmUserName @serverParams
                              } -ArgumentList $credentialName, $serverParams

                Wait-Job -Job $lcmUserJob -Timeout $timeoutSeconds | Out-Null
                $status = $lcmUserJob.State
                if ($status -eq 'Completed') {
                    $deploymentUserIdentifier = Receive-Job -Job $lcmUserJob -ErrorAction SilentlyContinue
                    if ($deploymentUserIdentifier)
                    {
                        Log-Info -Message ("  Found user '{0}' in Active Directory" -f $credentialName) -Type Info -Function "ExecutingAsDeploymentUser"
                    }
                    else
                    {
                        $detail = " Get-ADUser  -Identity $credentialName didn't return the $credentialName information. Ensure that $credentialName exist in AD."
                        Log-Info -Message ($detail) -Type Error -Function "ExecutingAsDeploymentUser"
                        $failureReasons += (" Get-ADUser -Identity $credentialName didn't return the $credentialName information. Ensure that $credentialName exist in AD.")
                    }

                }
                elseif ($status -eq 'Running') {
                    $detail = " Ensure Get-ADUser  -Identity $credentialName will return the results with-in $timeoutSeconds sec."
                    Log-Info -Message ($detail) -Type Error -Function "ExecutingAsDeploymentUser"
                    $failureReasons += (" Ensure Get-ADUser  -Identity $credentialName will return the results with-in $timeoutSeconds sec.")
                    Stop-Job -Job $lcmUserJob -ErrorAction Ignore | Out-Null
                }
                else
                {
                    $detail = " Unable to execute Get-ADUser  -Identity $credentialName. Ensure that $credentialName exist in AD."
                    Log-Info -Message ($detail) -Type Error -Function "ExecutingAsDeploymentUser"
                    $failureReasons += (" Unable to execute Get-ADUser -Identity $credentialName. Ensure that $credentialName exist in AD.")
                }
                Remove-Job -Job $lcmUserJob -ErrorAction Ignore | Out-Null
            }

            if ($deploymentUserIdentifier)
            {
                if ( (gwmi win32_computersystem).partofdomain ) 
                {
                   $identityReference = $credentialName
                }
                else
                {
                    $identityReference = $deploymentUserIdentifier.SID
                }

                # Test whether the AdCredentials user has all access rights to the OU
                try {

                    $adDriveName = "AD"
                    $tempDriveName = "hciad"
                    $adDriveObject = $null

                    try
                    {
                        $adProvider = Get-PSProvider -PSProvider ActiveDirectory
                        if ($adProvider -and $adProvider.Drives.Count -gt 0)
                        {
                            $adDriveObject = $adProvider.Drives | Where-Object {$_.Name -eq $adDriveName -or $_.Name -eq $tempDriveName}
                        }
                    }
                    catch {
                        Log-Info -Message ("  Error while trying to access active directory PS drive.  Will fall back to creating a new PS drive.  Inner exception: {0}" -f $_) -Type Warning -Function "ExecutingAsDeploymentUser"
                    }

                    if (-not $adDriveObject)
                    {
                        try {
                            # Add a new drive
                            $adDriveObject = New-PSDrive -Name $tempDriveName -PSProvider ActiveDirectory -Root '' @serverParams
                        }
                        catch {
                            Log-Info -Message ("  Error while trying to create active directory PS drive.  Inner exception: {0}" -f $_) -Type Error -Function "ExecutingAsDeploymentUser"
                            $failureReasons += (" Error while trying to create active directory PS drive.  Inner exception: {0}" -f $_)
                        }
                    }

                    $ouAcl = $null

                    if ($adDriveObject)
                    {
                        $adDriveName = $adDriveObject.Name

                        try
                        {
                            $ouPath = ("{0}:\{1}" -f $adDriveName,$adOuPath)
                            $ouAcl = Get-Acl $ouPath
                        }
                        catch
                        {
                            Log-Info -Message ("  Can't get acls from {0}.  Inner exception: {1}" -f $ouPath,$_) -Type Error -Function "ExecutingAsDeploymentUser"
                            $failureReasons += (" Can't get acls from {0}.  Inner exception: {1}" -f $ouPath,$_)
                        }
                        finally {
                            # best effort cleanup if we had added the temp drive
                            try
                            {
                                if ($adDriveName -eq $tempDriveName)
                                {
                                    $adDriveObject | Remove-PSDrive
                                }
                            }
                            catch {}
                        }
                    }

                    if ($ouAcl) {
                        try {
                            #Verify whether the user has generic all permissions or not.
                            $genericAllPermissions = $ouAcl.Access | Where-Object { `
                                $_.IdentityReference -match $identityReference -and `
                                $_.ObjectType -eq [System.Guid]::Empty -and `
                                $_.InheritedObjectType -eq [System.Guid]::Empty -and `
                                $_.ActiveDirectoryRights -eq [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
                                }
                            if ($genericAllPermissions)
                            {
                                Log-Info -Message ("  AD OU ({0}) has genericAll permissions to the SID {1}." -f $ouPath, $identityReference ) -Type Info -Function "ExecutingAsDeploymentUser"
                            }
                            else
                            {
                                $computerCreateAndDeleteChildPermissions = $ouAcl.Access | Where-Object { `
                                    $_.IdentityReference -match $identityReference -and `
                                    $_.ActiveDirectoryRights -eq [System.DirectoryServices.ActiveDirectoryRights]::CreateChild -bor [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild -and `
                                    $_.ObjectType -eq ([System.Guid]::New('bf967a86-0de6-11d0-a285-00aa003049e2'))
                                    }

                                $readPropertyPermissions = $ouAcl.Access | Where-Object { `
                                    $_.IdentityReference -match $identityReference -and `
                                    $_.ActiveDirectoryRights -eq [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -and `
                                    $_.InheritedObjectType -eq [System.Guid]::Empty -and `
                                    $_.ObjectType -eq [System.Guid]::Empty
                                    }

                                $msfveRecoverInformationobjectsPermissions = $ouAcl.Access | Where-Object { `
                                    $_.IdentityReference -match $identityReference -and `
                                    $_.ActiveDirectoryRights -eq [System.DirectoryServices.ActiveDirectoryRights]::GenericAll -and `
                                    $_.ObjectType -eq [System.Guid]::Empty -and `
                                    $_.InheritedObjectType -eq ([System.Guid]::New('ea715d30-8f53-40d0-bd1e-6109186d782c'))
                                    }

                                if ($computerCreateAndDeleteChildPermissions)
                                {
                                    Log-Info -Message ("  For AD OU ({0}) found active directory rights ({1}) and object type ({2}) " -f $ouPath, $computerCreateAndDeleteChildPermissions.ActiveDirectoryRights, $computerCreateAndDeleteChildPermissions.ObjectType ) -Type Info -Function "ExecutingAsDeploymentUser"
                                }
                                else
                                {
                                    Log-Info -Message ("  Found ACLs for AD OU ({0}), but user ({1})'s didn't have access rights to create/delete computer objects. " -f $ouPath,$credentialName) -Type Error -Function "ExecutingAsDeploymentUser"
                                    $failureReasons += ($testContext["LcAdTxt"].CurrentUserMissingCreateAndDeleteComputerObjectPermission -f $adOuPath)
                                }

                                if ($readPropertyPermissions)
                                {
                                    Log-Info -Message ("  For AD OU ({0}) found active directory rights ({1}) and object type ({2}) " -f $ouPath, $readPropertyPermissions.ActiveDirectoryRights, $readPropertyPermissions.ObjectType ) -Type Info -Function "ExecutingAsDeploymentUser"
                                }
                                else
                                {
                                    Log-Info -Message ("  Found ACLs for AD OU ({0}), but user ({1})'s didn't have access rights to read AD objects. " -f $ouPath,$credentialName) -Type Error -Function "ExecutingAsDeploymentUser"
                                    $failureReasons += ($testContext["LcAdTxt"].CurrentUserMissingReadObjectPermissions -f $adOuPath)
                                }

                                if ($msfveRecoverInformationobjectsPermissions)
                                {
                                    Log-Info -Message ("  For AD OU ({0}) found active directory rights ({1}) and object type ({2}) " -f $ouPath, $msfveRecoverInformationobjectsPermissions.ActiveDirectoryRights, $msfveRecoverInformationobjectsPermissions.ObjectType ) -Type Info -Function "ExecutingAsDeploymentUser"
                                }
                                else
                                {
                                    Log-Info -Message ("  Found ACLs for AD OU ({0}), but user ({1})'s didn't have access rights to msFVE-RecoverInformationobjects. " -f $ouPath,$credentialName) -Type Error -Function "ExecutingAsDeploymentUser"
                                    $failureReasons += ($testContext["LcAdTxt"].CurrentUserMissingMsfveRecoverInformationobjectsPermissions -f $adOuPath)
                                }

                            }
                        }
                        catch {
                            Log-Info -Message ("  Error while trying to get access rules for OU.  Inner exception: {0}" -f $_) -Type Error -Function "ExecutingAsDeploymentUser"
                            $failureReasons += (" Error while trying to get access rules for OU.  Inner exception: {0}" -f $_)
                        }

                    }
                }
                catch {
                    Log-Info -Message ("  FAILED to look up ACL for AD OU ({0}) and search for GenericAll ACE for user ({1}). Inner exception: {2}" -f $ouPath,$credentialName,$_) -Type Error -Function "ExecutingAsDeploymentUser"
                    $failureReasons += (" FAILED to look up ACL for AD OU ({0}) and search for user ({1}). Inner exception: {2}" -f $ouPath,$credentialName,$_)
                }
            }

            if ($failureReasons.Count -gt 0) {
                $allFailureReasons = $failureReasons -join "; "
                $detail = ($testContext["LcAdTxt"].CurrentUserFailureSummary -f $credentials.UserName,$allFailureReasons)
            }
            else
            {
                $statusValue = 'SUCCESS'
                $detail = ""
            }            return @{
                Resource    = "ExecutingAsDeploymentUser"
                Status      = $statusValue
                TimeStamp   = [datetime]::UtcNow
                Source      = $ENV:COMPUTERNAME
                Detail      = $detail
            }
        }
    })
)

function Test-ADComputerObjects {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]
        $testContext
    )

    $serverParams = @{}
    if ($testContext["AdServer"])
    {
                $serverParams += @{Server = $testContext["AdServer"]}
    }
    if ($testContext["AdCredentials"])
    {
                $serverParams += @{Credential = $testContext["AdCredentials"]}
    }

    $adOUPath = $testContext["ADOUPath"]
    $domainFQDN = $testContext["DomainFQDN"]
    $seedNode = $ENV:COMPUTERNAME

    $detailedErrors = @()
    $testResult = $true
    
    #Todo:: Check the domain status for all the nodes.
    Log-Info -Message (" Validating seednode : {0} is part of a domain or not " -f $seedNode) -Type Info -Function "Test-ADComputerObjects"
    $domainStatus = (gwmi win32_computersystem).partofdomain
    if ($domainStatus)
    {
        $physicalHosts = @($testContext["PhysicalMachineNames"] | Where-Object { -not [string]::IsNullOrEmpty($_) })
        foreach ($physicalHost in $physicalHosts)
        {
            try {
                Log-Info -Message (" Validating computer object : {0} in Domain." -f $physicalHost) -Type Info -Function "Test-ADComputerObjects"
                $computerObject = Get-ADComputer -SearchBase $adOUPath -Filter "Name -eq '$physicalHost' " @serverParams
                if ($computerObject -eq $null)
                {
                    $testResult = $false
                    $error = ("{0} not found in AD under {1} " -f $physicalHost, $adOUPath)
                    Log-Info -Message ($error) -Type Info -Function "Test-ADComputerObjects"
                    $failureReasons += $error
                }
                else
                {
                    Log-Info -Message (" Found the computer object : {0} in Domain." -f $physicalHost) -Type Info -Function "Test-ADComputerObjects"
                }
            }
            catch {
                $testResult = $false
                $error = ("Unable to get the computer object {0} from AD.Exception :: {1}" -f $physicalHost, $_.Exception)
                Log-Info -Message ($error) -Type Info -Function "Test-ADComputerObjects"
                $failureReasons += $error
            }
        }
    }
    $failureReason = $failureReasons -join "; "
    
    #As of now we added this test for logging purpose.
    $testResult = $true

    $adComputerObjectsTestResult =  @{ 
        Result = $testResult
        FailureReasons = $failureReason
    }

    return $adComputerObjectsTestResult

}

function Test-Connectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]
        $testContext
    )

    $connectivityTests = @{
       'RPCEndpointMapper' = @{
            'port'   = 135
            'target' = $testContext["AdServer"]
            'Description' = "RPC Endpoint Mapper (135) connectivity test"
        }
        'LDAP'      = @{
            'port'   = 389
            'target' = $testContext["AdServer"]
            'Description' = "LDAP port (389) connectivity test"
        }
        'LDAPGC'    = @{
            'port'   = 3268
            'target' = $testContext["AdServer"]
            'Description' = "LDAPGC port (3268) connectivity test"
        }
        'Kpasswd' = @{
            'port'   = 464
            'target' = $testContext["AdServer"]
            'Description' = "kerberos password change port (464) connectivity test"
        }
        'SMB' = @{
            'port'   = 445
            'target' = $testContext["AdServer"]
            'Description' = "SMB (445) connectivity test"
        }
    }

    $testResult = $true
    $failureReasons =@()

    foreach ($key in $connectivityTests.Keys)
    {
        $probe = $connectivityTests[$key]
         
        Log-Info -Message ($probe.Description) -Type Info -Function "Test-Connectivity"
        try {
            $result = Test-NetConnection -ComputerName $probe.target -Port $probe.port -WarningAction SilentlyContinue
            if ($result.TcpTestSucceeded)
            {
                Log-Info -Message ("{0} - Successful" -f $probe.Description) -Type Info -Function "Test-Connectivity"
            }
            else
            {
                Log-Info -Message ("{0} - Failed" -f $probe.Description) -Type Error -Function "Test-Connectivity"
                $testResult = $false
                $failureReasons += ("{0} - Failed" -f $probe.Description)
            }
        }
        catch {
            Log-Info -Message ("{0} - Failed. Exception :: {1}" -f $probe.Description, $_.Exception) -Type Error -Function "Test-Connectivity"
            $testResult = $false
            $failureReasons += ("{0} - Failed. Exception :: {1}" -f $probe.Description, $_.Exception)
        }
    }
    $failureReason = $failureReasons -join "; "
    
    $connectivityTestResult =  @{ 
        Result = $testResult
        FailureReasons = $failureReason
    }

    return $connectivityTestResult
}


function Test-CauClusterRole {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $HciClusterName
    )

    $ErrorActionPreference = 'Stop'

    try {
        Log-Info -Message ("Get CAU cluster role") -Type Info
        $statusValue = 'FAILURE'

        $cauClusterRole = Get-CauClusterRole -ClusterName $HciClusterName -ErrorAction SilentlyContinue
        if ($cauClusterRole)
        {
            Log-Info -Message ("CAU cluster role configured") -Type Info
            $statusValue = 'SUCCESS'
            $detailedResult = "CAU cluster role configured"
        }
        else
        {
            $detailedResult = "CAU cluster role not configured"
            Log-Info -Message ("CAU cluster role not configured") -Type Error
        }
    }
    catch {
        $detailedResult = 'Test-CauClusterRole failed with an exception : ' + $_
        Log-Info -Message (" Test-CauClusterRole Failed. {0}" -f $detailedResult) -Type Error
    }

    $result =  @{
        Status      = $statusValue
        TimeStamp   = [datetime]::UtcNow
        Source      = $ENV:COMPUTERNAME
        Detail = $detailedResult
    }
    $params = @{
        Name               = "AzStackHci_ExternalActiveDirectory_Test_CauClusterRole"
        Title              = "Test cau cluster role"
        DisplayName        = "Test cau cluster role"
        Severity           = 'CRITICAL'
        Description        = 'Tests that the cau cluster role is configured or not.'
        Tags               = @{}
        Remediation        = 'https://learn.microsoft.com/en-us/powershell/module/clusterawareupdating/add-cauclusterrole'
        TargetResourceID   = "Test_CauClusterRole"
        TargetResourceName = "Test_CauClusterRole"
        TargetResourceType = 'ActiveDirectory'
        Timestamp          = [datetime]::UtcNow
        Status             = $statusValue
        AdditionalData     = $result
        HealthCheckSource  = $ENV:EnvChkrId
    }
    return @( New-AzStackHciResultObject @params)
}


function Test-LcmUserCredentials {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [pscredential]
        $LcmUserCredentials,
        [Parameter(Mandatory=$true)]
        [string]
        $DomainFQDN
    )
    try {
        Add-Type -AssemblyName "System.DirectoryServices.AccountManagement"
        $statusValue = 'FAILURE'
        $detailedResult = ''
        $contextType = [System.DirectoryServices.AccountManagement.ContextType]::Domain
        $principalContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext($contextType, $DomainFQDN)
        # Extract username and password from PSCredential
        $credentialParts = $LcmUserCredentials.UserName.Split("\\")
        $username = $credentialParts[$credentialParts.Length-1]
        $password = $LcmUserCredentials.GetNetworkCredential().Password
        if ($principalContext.ValidateCredentials($username, $password))
        {
            $statusValue = 'SUCCESS'
            $detailedResult = 'Validated lcm user credentials.'
        }
        else
        {
            $detailedResult = 'Invalid lcm user credentials. UserName :: ' + $username
        }
    }
    catch {
        $detailedResult = 'Test-LcmUserCredentials failed with an exception : ' + $_
        Log-Info -Message (" Test_LcmUserCredentials Failed. {0}" -f $detailedResult) -Type Error
    }

    $result =  @{
        Status      = $statusValue
        TimeStamp   = [datetime]::UtcNow
        Source      = $ENV:COMPUTERNAME
        Detail = $detailedResult
    }
    $params = @{
        Name               = "AzStackHci_ExternalActiveDirectory_Test_LcmUserCredentials"
        Title              = "Test lcm user credentials"
        DisplayName        = "Test lcm user credentials"
        Severity           = 'CRITICAL'
        Description        = 'Tests that the lcm user credentials are synchronized with the AD '
        Tags               = @{}
        Remediation        = 'https://aka.ms/hci-envch'
        TargetResourceID   = "Test_LcmUserCredentials"
        TargetResourceName = "Test_LcmUserCredentials"
        TargetResourceType = 'ActiveDirectory'
        Timestamp          = [datetime]::UtcNow
        Status             = $statusValue
        AdditionalData     = $result
        HealthCheckSource  = $ENV:EnvChkrId
    }
    return @( New-AzStackHciResultObject @params)
}

function Test-OrganizationalUnitOnSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $ADOUPath,

        [Parameter(Mandatory=$true)]
        [string]
        $DomainFQDN,

        [Parameter(Mandatory=$true)]
        [string]
        $NamingPrefix,

        [Parameter(Mandatory=$true)]
        [string]
        $ClusterName,

        [Parameter(Mandatory)]
        [array]
        $PhysicalMachineNames,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.Runspaces.PSSession]
        $Session,

        [Parameter(Mandatory=$false)]
        [string]
        $ActiveDirectoryServer,

        [Parameter(Mandatory=$false)]
        [string]
        $OperationType = $null,

        [Parameter(Mandatory=$false)]
        [pscredential]
        $ActiveDirectoryCredentials
    )

    $testContext = @{
        ADOUPath = $ADOUPath
        ComputersADOUPath = "OU=Computers,$ADOUPath"
        UsersADOUPath = "OU=Users,$ADOUPath"
        DomainFQDN = $DomainFQDN
        NamingPrefix = $NamingPrefix
        ClusterName = $ClusterName
        LcAdTxt = $lcAdTxt
        AdServer = $ActiveDirectoryServer
        AdCredentials = $ActiveDirectoryCredentials
        AdCredentialsUserName = if ($ActiveDirectoryCredentials) { $ActiveDirectoryCredentials.UserName } else { "" }
        PhysicalMachineNames = $PhysicalMachineNames
        OperationType = $OperationType
    }

    $computerName = if ($Session) { $Session.ComputerName } else { $ENV:COMPUTERNAME }

    Log-Info -Message "Executing test on $computerName" -Type Info

    # Reuse the parameters for Invoke-Command so that we only have to set up context and session data once
    $invokeParams = @{
        ScriptBlock = $null
        ArgumentList = $testContext
    }
    if ($Session) {
        $invokeParams += @{Session = $Session}
    }

    # If provided, verify the AD server and credentials are reachable
    if ($ActiveDirectoryServer -or $ActiveDirectoryCredentials)
    {
        $params = @{}
        if ($ActiveDirectoryServer)
        {
            $params["Server"] = $ActiveDirectoryServer
        }
        if ($ActiveDirectoryCredentials)
        {
            $params["Credential"] = $ActiveDirectoryCredentials
        }
        try {
            $null = Get-ADDomain @params
        }
        catch {
            if (-not $ActiveDirectoryServer) {
                $ActiveDirectoryServer = "default"
            }
            $userName = "default"
            if ($ActiveDirectoryCredentials) {
                $userName = $ActiveDirectoryCredentials.UserName
            }
            throw ("Unable to contact AD server {0} using {1} credentials.  Internal exception: {2}" -f $ActiveDirectoryServer,$userName,$_)
        }
    }

    # Initialize the array of detailed results
    $detailedResults = @()

    # Test preparation -- fill in more of the test context that needs to be executed remotely
    $ExternalAdTestInitializors | ForEach-Object {
        $invokeParams.ScriptBlock = $_.ExecutionBlock
        $testName = $_.TestName

        Log-Info -Message "Executing test initializer $testName" -Type Info

        try
        {
            $results = Invoke-Command @invokeParams

            if ($results)
            {
                $testContext += $results
            }
        }
        catch {
            throw ("Unable to execute test {0} on {1}.  Inner exception: {2}" -f $testName,$computerName,$_)
        }
    }

    Log-Info -Message "Executing tests with parameters: " -Type Info
    foreach ($key in $testContext.Keys)
    {
        if ($key -ne "LcAdTxt")
        {
            Log-Info -Message "  $key : $($testContext[$key])" -Type Info
        }
    }

    # Update InvokeParams with the full context
    $invokeParams.ArgumentList = $testContext

    # For each test, call the test execution block and append the results
    $ExternalAdTests | ForEach-Object {
        # override ScriptBlock with the particular test execution block
        $invokeParams.ScriptBlock = $_.ExecutionBlock
        $testName = $_.TestName

        Log-Info -Message "Executing test $testName" -Type Info

        try
        {
            $results = Invoke-Command @invokeParams

            Log-Info -Message ("Test $testName completed with: {0}" -f $results) -Type Info

            $detailedResults += $results
        }
        catch {
            Log-Info -Message ("Test $testName FAILED.  Inner exception: {0}" -f $_) -Type Info
        }
    }

    return $detailedResults
}

function Test-OrganizationalUnit {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $ADOUPath,

        [Parameter(Mandatory=$true)]
        [string]
        $DomainFQDN,

        [Parameter(Mandatory=$true)]
        [string]
        $NamingPrefix,

        [Parameter(Mandatory=$true)]
        [string]
        $ClusterName,

        [Parameter(Mandatory=$true)]
        [array]
        $PhysicalMachineNames,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.Runspaces.PSSession]
        $PsSession,

        [Parameter(Mandatory=$false)]
        [string]
        $ActiveDirectoryServer = $null,

        [Parameter(Mandatory=$false)]
        [string]
        $OperationType = $null,


        [Parameter(Mandatory=$false)]
        [pscredential]
        $ActiveDirectoryCredentials = $null
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    Log-Info -Message "Executing Test-OrganizationalUnit"
    $fullTestResults = Test-OrganizationalUnitOnSession -ADOUPath $ADOUPath -DomainFQDN $DomainFQDN -NamingPrefix $NamingPrefix -ClusterName $ClusterName -Session $PsSession -ActiveDirectoryServer $ActiveDirectoryServer -ActiveDirectoryCredentials $ActiveDirectoryCredentials -PhysicalMachineNames $PhysicalMachineNames

    # Build the results
    $TargetComputerName = if ($PsSession.PSComputerName) { $PsSession.PSComputerName } else { $ENV:COMPUTERNAME }
    $remediationValues = $fullTestResults | Where-Object -Property Status -NE 'SUCCESS' | Select-Object $Remediation
    $remediationValues = $remediationValues -join "`r`n"
    if (-not $remediationValues)
    {
        $remediationValues = ''
    }

    $testOuResult = @()
    foreach ($result in $fullTestResults)
    {
        $params = @{
            Name               = "AzStackHci_ExternalActiveDirectory_Test_OrganizationalUnit_$($result.Resource)"
            Title              = "Test AD Organizational Unit - $($result.Resource)"
            DisplayName        = "Test AD Organizational Unit - $($result.Resource)"
            Severity           = 'CRITICAL'
            Description        = 'Tests that the specified organizational unit exists and contains the proper OUs'
            Tags               = @{}
            Remediation        = 'https://aka.ms/hci-envch'
            TargetResourceID   = "Test_AD_OU_$TargetComputerName"
            TargetResourceName = "Test_AD_OU_$TargetComputerName"
            TargetResourceType = 'ActiveDirectory'
            Timestamp          = [datetime]::UtcNow
            Status             = $result.Status
            AdditionalData     = $result
            HealthCheckSource  = $ENV:EnvChkrId
        }
        $testOuResult += New-AzStackHciResultObject @params
    }

    return $testOuResult
}
# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCHgxPZsbT4TUhL
# Z6To3O8y0+4ZMNTmHI0/cZK94Pc3Y6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnlMIIZ4QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEILwloS5P
# 3ZLKH/ttULcNrGO86+dMs3b3nRMn8Mjt7ulmMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEASMD01qyj/tii9r47673fiw3Vf+UoJtzv6LFTESyr
# gcsR3jwVVZ5jpH+zTJ9/jSt5X4VX2PwFcnbLeab9IPZ2/psgVDvuIBfLTM4IKDVg
# CtI95wgPq97lRvOZPl4Ir2cKOsUnshNaDaqZNGl411q1mNv0OmbLAbfBGm3Hyr0x
# puXHg6irxGlmyOFcGJaD42mfpK2/KKFRsNhBAG8F3OWXiHKWV4NQ5wtx9JgD1Uh5
# Nb+QYrTH7RBl8P/XMhcq0i+df2kWeX1Lpasd/9Pdrjtq9ebstCLgs4Rd74Y6Hv/P
# Cpo8QnZq/srsnYaVihPra9tg4UbzBHyMcK4+m57BY05rwaGCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCBKTAH/sCF4ILmS0LyVGhWT2mYmMzRbd6gllHgt
# CWscyAIGaeexRuPaGBMyMDI2MDUwMzE0MzExMC41ODNaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiJB0vaq/8i1/wABAAAC
# IjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTZaFw0yNzA1MTcxOTM5NTZaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC1ueKJukIuUsAAJo/AY5DZRqH7
# bhgv7CWGNlEdbRGoITrdE6Wsn57NaNu1BTdjBbFcv7Rfixte0x+HRvXSqsD+WeSX
# /6/y9wE0Mz+xRPTGIY20K7aQDa68OyzVyUeUCypyZC/gW/3ytO/ZOnU9H2ri77kJ
# P8ABrqyy1UxX/OseEgvHsj8yikWT0ARtrjWbXMHFzSOo5hQcfUmMXKqWWz6+N0+U
# ynhGy1n+doW4WZgpH8Y5W7hpSokWj1M/Lu4wi3o6Dz9vVWukcgUFGjLAl4YZpOha
# h7HuiC/alXImMQf8C3A8q/6/1hFoeIZB4UGkywxB/OSTOSsL6+39pDqzM7CgOpf4
# V799kN94yM9uXJI5T/SiA5MdIZIhEW0+bh85RqDh5YW3/oav54RPxw5OPlH64QV6
# KJkl0FIElMVoLNo8UWRQcMD179x7WASjC6LsaNZ7yK0qcESIsL1wiQmdfQBxcqrF
# CpIQfnmQFkOp9IyXUWqza8tmpz8E6aXg9b1eiAT3PVTgrOlPi/hYZCfPxX/6jGty
# Pjy1CiwOmJamohmSU//COAenfRT2G2HMRUpCX1zs+AmDmdQM1XRab4YSALLAlDzG
# CsgI77nnuJjoXAliJmv7NfrvWAcA5KqCUOWQ6kSPt5r28MfKXWJJpSXtFeS/MkDz
# Jy/iJRVyHcFy/B+MtwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFFkHwGoDJ5ZbEEiu
# 8KstiusqaozQMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBiAM+nqrpwG29txSXv
# 42o+CsTe2C4boaRfFju9JaWkLTHwq7pknNONL3n+UG3x/B083EKXiFYrAmul7BTH
# CGXU63/xRsZ2wj3ZmR0A4d9nf9saCJVm4juPVFBai/oktOOYH2j+1+zM70woN5on
# gB/pvy7X8AfY6JB4XPvb80Qz7fY5eddbnwjzg1sZhUPFbbcweWeACINrzqFK62mM
# eXKmhtufMraoogJeJXfWY3x4/pbubgENT3+pXT65203CPF9kfdKE7GKAIRYy3xkB
# TDvFd8dufjOpCn38nK6qMlVtnBjDhWQG0PM3E/oxBs5UBrI6pBYkmIHtbjifDquH
# T+ThaVV7xHc6InoSc3aNzX49JHUgQmuvDdMjLkbYXeA0/1q5IxSg2U+ycZBOvAi3
# udZPKhA5VzODjf/ucu/vFtXrYcRkmGKN3jujaK3/yMZi2Ju5NEL3ISWorwp7RjeZ
# g+JMIK0fosuVj+YCm5r64LH/D9QJDAj+XfZaNeFdv90K5A0QRRGP/poB9yTIVjEX
# j/uJzp8L4Dd44sAquqDOiHdkLgxfK8nPqpCSWPZ9G+RCPm85o9cAfxENtrSuOwcp
# yKzxsRCYCL+PK4+98orit9EVJ/LLoCeG+jLlj0KaD4Qy6sZe4rWMr1brQLosTBZN
# wFnXxNjInCWBd0i7is1yTS/4qTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg5MDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQC7ycXVZx3bsDpJkr7VucgpksozuKCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7aFXLjAiGA8y
# MDI2MDUwMzA1MTAwNloYDzIwMjYwNTA0MDUxMDA2WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtoVcuAgEAMAoCAQACAjeSAgH/MAcCAQACAhM5MAoCBQDtoqiuAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAICyoVbsfk2gYvYCk48bJIGhgFfS
# KFVqLcD1oCXuw4ZmsUQO23TTO/QU1Zn+BHz9eKaK3axV8+GObQIewpsToujmSps9
# 1jTosQ1Iwq1yKHKwboMjCf1HPiZL8ngWDJykry2EMhGjqy+o3Hc69OZbm1aI9moR
# I13oN4jtQZdZL3sTqt6pwPfqwFA3DBecu+uiv0ynq+gFtU9HTdjardpNN4OY1sQA
# e1MSbXS0KBXYWk244Ttv20MTGmMXACyiny1lTdRA1Co67pGPzA4h1z/Q/Vg3Y0Ps
# FgvWnRxG7oxIqyJewma19SYrajjDYVysNA/HNmieixNCTBNTJ7xUcruzArExggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiJB
# 0vaq/8i1/wABAAACIjANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCATF/ggXZkbmvnkNSEEG4tJFmCv
# Nz3+eSt1d8TCYKhtHTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIAVgXQEK
# BOfGgjNskmDOmbcEIOnHGNwA+QcRufDR5AkTMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIiQdL2qv/Itf8AAQAAAiIwIgQge0BYPU+G
# OOQNtThs8JIT4pVZxK+0CdTvxImeg/PVxbcwDQYJKoZIhvcNAQELBQAEggIACHw0
# 8IgheUwnP3Mdz2YMM/AMfBhx7LzuQQ7TUQN8E+GAnlEPKX5YupqjjPcU5bTgUchs
# HnRelRiMAPMlu4DwIHftjE/ilGJqVQRjJUiye2ZJy6FO5FqS3uCsBE761QUPs4w1
# 08q0CgLPdRcNBdRjatoQeGl5JE3bP050519WKwwf0vCBUyCPNvOh4HAsr44vPiMd
# lo+0+Ipwp77VTVBXQfYVJTJKOvRXr5IV4YcXzirkft09aDQ3ZPHy29nTh4+VW2bu
# LqDd/9PuioqsWriMP/anEkniN7x3JUSthkkug2G/EVwvoEN4FOLqck8eKLCPNzB7
# QyXOdMhJf2qLW6sKYZ+Sp8SfrupHcaeADTuIqCAD1OiAWGCRfi4mxiU62gyozE6n
# YQSL+x5wdCejEkqd3LbN77V9XdwmX/h5n9uv1D2ovCJL3pIUBbJ0R43Syqsk2huw
# HQQ+NJQ0zzj1OKRcPTm1DopqE2NCu4tzC+y31j4QbDE1BNmtcESdwVIngDY/R+Ot
# FMi78R5KhAnCDXJ8y9AnuoSvg/n2AEzpkPawNMdep2K4etZZrYDWiN+nQmec4VPS
# sDRoesxaQsLQElF96JyxMNumtCMA51ahy/AvLAAnpbgvs0AHRzb8Mc5GeNmqNLon
# NZn5dxxJDVdyhnj+YOcCqE6ECZ0VletS4qhwedE=
# SIG # End signature block
