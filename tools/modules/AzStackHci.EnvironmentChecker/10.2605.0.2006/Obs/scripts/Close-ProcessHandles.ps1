Param (
    [Parameter(Mandatory = $false)]
    [System.String] $FolderPathToClean = "C:\Packages\Plugins\Microsoft.AzureStack.Observability.TelemetryAndDiagnostics\*\bin"
)

function Get-ExceptionDetails {
    [CmdLetBinding()]
    Param (
        [Parameter(Mandatory=$True, ValueFromPipeline)]
        [System.Management.Automation.ErrorRecord] $ErrorObject
    )

    return @{
        Errormsg = $ErrorObject.ToString()
        Exception = $ErrorObject.Exception.ToString()
        Stacktrace = $ErrorObject.ScriptStackTrace
        Failingline = $ErrorObject.InvocationInfo.Line
        Positionmsg = $ErrorObject.InvocationInfo.PositionMessage
        PScommandpath = $ErrorObject.InvocationInfo.PSCommandPath
        Failinglinenumber = $ErrorObject.InvocationInfo.ScriptLineNumber
        Scriptname = $ErrorObject.InvocationInfo.ScriptName
    } | ConvertTo-Json ## The ConvertTo-Json will return the entire hashtable as string.
}

function Get-FileLockProcess {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [System.String] $FilePath
    )

    $functionName = $MyInvocation.MyCommand.Name

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    if (! $(Test-Path $FilePath)) {
        Write-Output "[$functionName] The path $FilePath was not found! Halting!"
        return
    }

    ##### END Variable/Parameter Transforms and PreRun Prep #####


    ##### BEGIN Main Body #####

    if ($PSVersionTable.PSEdition -eq "Desktop" -or $PSVersionTable.Platform -eq "Win32NT" -or 
    $($PSVersionTable.PSVersion.Major -le 5 -and $PSVersionTable.PSVersion.Major -ge 3)) {
        $CurrentlyLoadedAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies()
    
        $AssembliesFullInfo = $CurrentlyLoadedAssemblies | Where-Object {
            $_.GetName().Name -eq "Microsoft.CSharp" -or
            $_.GetName().Name -eq "mscorlib" -or
            $_.GetName().Name -eq "System" -or
            $_.GetName().Name -eq "System.Collections" -or
            $_.GetName().Name -eq "System.Core" -or
            $_.GetName().Name -eq "System.IO" -or
            $_.GetName().Name -eq "System.Linq" -or
            $_.GetName().Name -eq "System.Runtime" -or
            $_.GetName().Name -eq "System.Runtime.Extensions" -or
            $_.GetName().Name -eq "System.Runtime.InteropServices"
        }
        $AssembliesFullInfo = $AssembliesFullInfo | Where-Object {$_.IsDynamic -eq $False}
  
        $ReferencedAssemblies = $AssembliesFullInfo.FullName | Sort-Object | Get-Unique

        $usingStatementsAsString = @"
        using Microsoft.CSharp;
        using System.Collections.Generic;
        using System.Collections;
        using System.IO;
        using System.Linq;
        using System.Runtime.InteropServices;
        using System.Runtime;
        using System;
        using System.Diagnostics;
"@
        
        $TypeDefinition = @"
        $usingStatementsAsString
        
        namespace MyCore.Utils
        {
            static public class FileLockUtil
            {
                [StructLayout(LayoutKind.Sequential)]
                struct RM_UNIQUE_PROCESS
                {
                    public int dwProcessId;
                    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
                }
        
                const int RmRebootReasonNone = 0;
                const int CCH_RM_MAX_APP_NAME = 255;
                const int CCH_RM_MAX_SVC_NAME = 63;
        
                enum RM_APP_TYPE
                {
                    RmUnknownApp = 0,
                    RmMainWindow = 1,
                    RmOtherWindow = 2,
                    RmService = 3,
                    RmExplorer = 4,
                    RmConsole = 5,
                    RmCritical = 1000
                }
        
                [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
                struct RM_PROCESS_INFO
                {
                    public RM_UNIQUE_PROCESS Process;
        
                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
                    public string strAppName;
        
                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
                    public string strServiceShortName;
        
                    public RM_APP_TYPE ApplicationType;
                    public uint AppStatus;
                    public uint TSSessionId;
                    [MarshalAs(UnmanagedType.Bool)]
                    public bool bRestartable;
                }
        
                [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
                static extern int RmRegisterResources(uint pSessionHandle,
                                                    UInt32 nFiles,
                                                    string[] rgsFilenames,
                                                    UInt32 nApplications,
                                                    [In] RM_UNIQUE_PROCESS[] rgApplications,
                                                    UInt32 nServices,
                                                    string[] rgsServiceNames);
        
                [DllImport("rstrtmgr.dll", CharSet = CharSet.Auto)]
                static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
        
                [DllImport("rstrtmgr.dll")]
                static extern int RmEndSession(uint pSessionHandle);
        
                [DllImport("rstrtmgr.dll")]
                static extern int RmGetList(uint dwSessionHandle,
                                            out uint pnProcInfoNeeded,
                                            ref uint pnProcInfo,
                                            [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
                                            ref uint lpdwRebootReasons);
        
                /// <summary>
                /// Find out what process(es) have a lock on the specified file.
                /// </summary>
                /// <param name="path">Path of the file.</param>
                /// <returns>Processes locking the file</returns>
                /// <remarks>See also:
                /// http://msdn.microsoft.com/en-us/library/windows/desktop/aa373661(v=vs.85).aspx
                /// http://wyupdate.googlecode.com/svn-history/r401/trunk/frmFilesInUse.cs (no copyright in code at time of viewing)
                /// 
                /// </remarks>
                static public List<Int32> WhoIsLocking(string path)
                {
                    // Console.WriteLine("Looking for process handles for file {0}.", path);
                    uint handle;
                    string key = Guid.NewGuid().ToString();
                    var processes = new List<Int32>();
        
                    int res = RmStartSession(out handle, 0, key);
                    if (res != 0) throw new Exception("Could not begin restart session.  Unable to determine file locker.");
        
                    try
                    {
                        const int ERROR_MORE_DATA = 234;
                        uint pnProcInfoNeeded = 0,
                            pnProcInfo = 0,
                            lpdwRebootReasons = RmRebootReasonNone;
        
                        string[] resources = new string[] { path }; // Just checking on one resource.
        
                        res = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);
        
                        if (res != 0) throw new Exception("Could not register resource.");                                    
        
                        //Note: there's a race condition here -- the first call to RmGetList() returns
                        //      the total number of process. However, when we call RmGetList() again to get
                        //      the actual processes this number may have increased.
                        res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);
        
                        if (res == ERROR_MORE_DATA)
                        {
                            // Create an array to store the process results
                            RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
                            pnProcInfo = pnProcInfoNeeded;
        
                            // Get the list
                            res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons);
                            if (res == 0)
                            {
                                processes = new List<Int32>((int)pnProcInfo);
        
                                // Enumerate all of the results and add them to the 
                                // list to be returned
                                for (int i = 0; i < pnProcInfo; i++)
                                {
                                    try
                                    {
                                        processes.Add(processInfo[i].Process.dwProcessId);
                                    }
                                    // catch the error -- in case the process is no longer running
                                    catch (ArgumentException) { }
                                }
                            }
                            else {
                                var exceptionMessage = String.Format("Could not list processes locking file ({0}).", path);
                                throw new Exception(exceptionMessage);
                            }
                        }
                        else if (res != 0) {
                            var exceptionMessage = String.Format("Could not list processes locking file ({0}). Failed to get size of result.", path); 
                            throw new Exception(exceptionMessage);
                        }
                    }
                    finally
                    {
                        RmEndSession(handle);
                    }
        
                    return processes;
                }
            }
        }
"@

            $CheckMyCoreUtilsFileLockUtilLoaded = $CurrentlyLoadedAssemblies | Where-Object {$_.ExportedTypes -like "MyCore.Utils.FileLockUtil*"}
            if ($null -eq $CheckMyCoreUtilsFileLockUtilLoaded) {
                Add-Type -ReferencedAssemblies $ReferencedAssemblies -TypeDefinition $TypeDefinition
            }

            $Result = [MyCore.Utils.FileLockUtil]::WhoIsLocking($FilePath)
        }
        if ($null -ne $PSVersionTable.Platform -and $PSVersionTable.Platform -ne "Win32NT") {
            $lsofOutput = lsof $FilePath

            function Parse-lsofStrings ($lsofOutput, $Index) {
                $($lsofOutput[$Index] -split " " | ForEach-Object {
                    if (![String]::IsNullOrWhiteSpace($_)) {
                        $_
                    }
                }).Trim()
            }

            $lsofOutputHeaders = Parse-lsofStrings -lsofOutput $lsofOutput -Index 0
            $lsofOutputValues = Parse-lsofStrings -lsofOutput $lsofOutput -Index 1

            $Result = [pscustomobject]@{}
            for ($i=0; $i -lt $lsofOutputHeaders.Count; $i++) {
                $Result | Add-Member -MemberType NoteProperty -Name $lsofOutputHeaders[$i] -Value $lsofOutputValues[$i]
            }
        }

        return $Result
    
    ##### END Main Body #####

}

function Close-ProcessHandles {
        Param (
        [Parameter(Mandatory=$True)]
        [System.String] $FolderPathToClean
    )

    $functionName = $MyInvocation.MyCommand.Name
    Write-Output "[$functionName] Entering."

    $transcriptFileName = "CloseProcessHandles-$(Get-Date -Format 'yyyy-MM-dd').log"
    $transcriptFilePath = Join-Path -Path $PSScriptRoot -ChildPath $transcriptFileName
    Start-Transcript -Path $transcriptFilePath -Append

    ## Get the process handles that are locking files and save the fileName and corresponding ProcessIDs.
    $filesLockedByProcessesDict = @{}
    foreach ($folder in (Get-ChildItem $FolderPathToClean)) {
        Write-Output "[$functionName] Checking process handles inside folder: $($folder.FullName)"
        Get-ChildItem -Path $folder.FullName -Recurse | Where-Object { ! $_.PSIsContainer } | ForEach-Object {
            $filePath = $_.FullName
            try {
                $processHandles = Get-FileLockProcess -FilePath $filePath
                if ($null -ne $processHandles -and $processHandles.Count -gt 0) {
                    $filesLockedByProcessesDict[$filePath] = $processHandles
                }
            }
            catch {
                $excectionDetails = Get-ExceptionDetails -ErrorObject $_
                Write-Output "[$functionName] Exception occurred for file ($filePath). Exception is as follows: $excectionDetails"
            }
        }
    }

    if ($filesLockedByProcessesDict.Keys.Count -eq 0) {
        Write-Output "[$functionName] No files found with locked process handles."
    }
    else {
        Write-Output "[$functionName] Files locked by Processes are as follows = $($filesLockedByProcessesDict | ConvertTo-Json -Compress)."

        $currentPID = [System.Diagnostics.Process]::GetCurrentProcess().Id
        Write-Output "[$functionName] Current PID is $currentPID"

        $returnStatusMessage = [System.String]::Empty

        ## Loop through the ProcessIDs and force stop them accordingly (if needed).
        Write-Output "[$functionName] Looping through locked file processes and force stop them accordingly (if needed)."
        $stoppedPID = [System.Collections.Generic.HashSet[string]]@()
        foreach ($currentFile in $filesLockedByProcessesDict.Keys) {
            foreach ($procId in $filesLockedByProcessesDict[$currentFile]) {
                if ($procId -eq $currentPID) {
                    ## We do not want to stop the current process, so if the file is locked by the current process, we hope that the process will finish successfully and release the handle.
                    Write-Output "[$functionName] Ignoring file $currentFile as it is used by PID ($procId) which is running the current script."
                } 
                elseif ($stoppedPID.Contains($procId)) {
                    ## We do not want to stop the same process again (and get "PID not found" error)
                    Write-Output "[$functionName] Ignoring PID ($procId) as it was already stopped"
                }
                else {
                    $procDetails = gwmi win32_process | Where-Object {$_.ProcessId -eq $procId} | Select-Object ProcessName, ExecutablePath, CommandLine
                    $fileLockingProcDetails = @{
                        FilePath = $currentFile
                        ProcessName = $procDetails.ProcessName
                        ExecutablePath = $procDetails.ExecutablePath
                        CommandLine = $procDetails.CommandLine
                    }
                    Write-Output "[$functionName] Details of file and its locking process = $($fileLockingProcDetails | ConvertTo-Json -Compress)"
                    try {
                        Write-Output "[$functionName] Stopping process $procId = $(Stop-Process -Id $procId -Force -PassThru | Out-String)"
                        $stoppedPID.Add($procId) | Out-Null
                    }
                    catch{
                        $returnStatusMessage += "[$functionName] Cannot stop process $procId due to error $_"
                    }
                }
            }
        }
    }

    Write-Output "[$functionName] Exiting. Return status message = $returnStatusMessage"
    Stop-Transcript
}


## Invoke the main function
$resolvedPath = (Resolve-Path $FolderpathToClean).Path
Close-ProcessHandles -FolderPathToClean $resolvedPath
# SIG # Begin signature block
# MIInSAYJKoZIhvcNAQcCoIInOTCCJzUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAnSQKJOldQhnKf
# 3piB5QKh5CbQfpKxqRyWZKSwX8P16qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnkMIIZ4AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIBlFeuI
# Zk7aIAQh7ZG9swAGCUYIckqhPY6qRNBJpmbeMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAflK7555AYGvxGzs/lf7GviSvgGqVvmP5MzGM2wE7
# DIaoivsUudoPDHTlCRVXcf1n0szxc017yMVZKYfmt20SJBMnOUuRlT0JYkTiOJrx
# /s2Y51Cf3dNSbbw6MCUZgLY48pbNXy0zaGyiJHg0RH7HaghjCqelWZYwKiOzfPQ4
# ka+6a3bIiQRDbt51I1kpAHlNPUk3LBWELOw3lANXFh3qi3ErHwNzkVTaqdoehkG/
# 7pdu4Lq7p9QI1rKkh0+QjzTnjwqVsTVyV9strt1CJLhWZ2PzauG5e62mRJ8ahDmb
# 8bDj9FmSPzqPEoux5xeWfGYqJNKIxFFpdoYbWw85Dyji46GCF5YwgheSBgorBgEE
# AYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCAR71vSBEu8k//AzLvmaif5ON/tEvBGyocrKnCk
# YSziggIGaedcMrcvGBIyMDI2MDUwMzE0MzEwOS4yOFowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpBMDAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMzAAACK7sAUP9NO5qhAAEAAAIr
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5NDAxMVoXDTI3MDUxNzE5NDAxMVowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBMDAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJfeaLo4PezJSpCbhCqCSso9tywr
# 9DHd9hy0vz5UzW45jduiiLkbHBq5OBB/okUchNOjFLuCOoqUrw4UvMvpROXSPEQr
# m3oO45yAld2+62KahOU5LQLeTIhNcEBeiP+CnqFFH3PpZGKnUq2SKVvd0lcKNCpP
# 0/YK66Ov5XPyv5n6MOXT2OL+Jz/gbfiveZXCOz/8afH0+7fVXytcWJw2IDPGm5tr
# Clt3ymp/OVZPa+cbeQX2XoyJERu8ndcctTAdCyHS39OtIXH+z/IKqklZgnqgKUbv
# S2+wUfRpE/zAHhw/8IVrYgu+TbqLc5wkGX6moqMdNIHL2a/BM8QOWfNyjQ23xHql
# I9NdmAGyxweGgp8LRZCY7NjaR5dsCZFNxkzJfPm/8AluagjTLTsFrO+3k2Rd10b1
# MStBbC2wXIgqsSUOBZ8d4KhO7XC7ZyIPd0rvbPdxraDOgQPFPaP0FchQpqJPNN1A
# 9GwAxo7d1TTNobAwyXC1InIOHXhgSBmhS7m9Lwy6Ayp2s2OmHIvrnIqGOkBZuFiQ
# gc7/S5mO73m0/zNk2pchGHi119Yck8BOf2v5zGTK6HbHRUt1/HWWYr1fc2MfQ22A
# CzkkH/A6WTK653GYVN9ZXJGsvfuKyk5nxo8AWC/JHpw1OQamQWjfklGNyI2ZmJTi
# pP1S3L5XmC50WTWPAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUPhaO5BNQlu1t3eOa
# 9mS7QVnZ5TYwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAM78IqxyIQzySvV+ofhO
# V9ProQ2hOPFfDzXSnISrQ92uAvB+BPfH7WDPsJAe1R16+oxDmofIMuGbqlP3XUJi
# QY37qD4xTt8xhOvp3dLGJ4nAEihaR9HiDtKK0bMwpTjrkoRh6N912hSCi8L/FxGl
# oAs7mnf8DbjwHKEmIy20FA0O2xP8doIXBEUJRFvL9/xzWSTLwXzGQJcXP78y1nl3
# WVYWPA4jaB5kdar1eKEM6B57mdLaSijlXqfxcbbbRRN69V/6mCakgfvVcoNUhhMY
# ZkmzrI+V8nZperDUwTg1HqiQ2xjc/UzfUfoMxhF8kY0E16nn3mRcaHdjMDdwKLKD
# 6OYnnyH99O+OeAim5QV84OkOMXHSJzVigsA3GEIXdGFL2pgzsrjQ0SEqyFi5oCQg
# bZcEpiKDev/T9vSyO+MHCznkBiicybcDypxf/qT1V9zSa/122ice5YZ8DZv6oTaq
# kKeHMZt0MeruI5JkTDTWc26kAx/VzjWT0ihNDbPeLDrDhlmgs7KDhMoxunWSulPi
# 2uKn/LfQK/mSHKoIM2ppdCkGQ5g43wuC2hDdqZU5fuLHmN2ufH+9TFNRKKBe+tZ0
# vtSTySmZLTO2jZOjLtpPmgHMJO9+P2In8E38TW+EUGSEkK9ns9W+wxKdNOaTHYVq
# XaVWTO24Ajjh8P+7Isl1oxBLMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
# AAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUg
# QXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2
# AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpS
# g0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2r
# rPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k
# 45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSu
# eik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09
# /SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR
# 6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxC
# aC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaD
# IV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMUR
# HXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMB
# AAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQq
# p1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ
# 6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBB
# MAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP
# 6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWlj
# cm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2
# LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMu
# Y3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2
# Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03d
# mLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1Tk
# eFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kp
# icO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKp
# W99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrY
# UP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QB
# jloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkB
# RH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0V
# iY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq
# 0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1V
# M1izoXBm8qGCA1AwggI4AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAAmsP3TKQemj/QAZvuWbC+wK2pE5oIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtoarNMCIYDzIw
# MjYwNTAzMTEwNjUzWhgPMjAyNjA1MDQxMTA2NTNaMHcwPQYKKwYBBAGEWQoEATEv
# MC0wCgIFAO2hqs0CAQAwCgIBAAICCuICAf8wBwIBAAICEpEwCgIFAO2i/E0CAQAw
# NgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgC
# AQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAiXiD+RkIc56txiN9YZzcVjnnT/XK
# gaze+sKlgKI241+pUiSBb04PlPznv2nF/bVevRTUBw+UNdMmnTIOlRlJALmmJngZ
# WWdZF3xzBhy50kxNG+iFoqQHxGQhb8d1Md0EgF8o9KXR5uxjmwekYMxm+cvlVjeF
# 3lm4V5KHuBXthjYLmm3YIIr73tlawvpNrfw5T0PrznSzyAtxNHLFQHQsf3t9ROmL
# ghtWX2NV+QGfNSPWMhwYqDEwvCQjQ6OAKoJfmRpmCVqY8mmYTnp101vq3JF+1Ty7
# IGImIchtP4jQW6WDQ9J6dZKRUg7uptsQlFou3loa/7n6ELOFSQd12dcoMTGCBA0w
# ggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACK7sA
# UP9NO5qhAAEAAAIrMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIGvRoDRe8juhKlAkcEenfXqpOoE6
# lS0OMmbu6nUJUK5zMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgcg4j9D+Q
# V+1gD4zY5j7UHHdqMEPr9YMC09Pa8WS/blIwgZgwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiu7AFD/TTuaoQABAAACKzAiBCDhuKDBa8XH
# Tgn2Yh9JPY0NhOp4elLZUr/RvUkX/lpY7TANBgkqhkiG9w0BAQsFAASCAgCL7xdo
# 4OHp/5+OI0gQLMqCyACwqDoC9WxGuxdvg/OFntmtQ54G8Yy3fBFzL0fQYhsR8i64
# ur6aDA8yepTGTVvgPtWVuFULjA2otYnPxMBmrpATmo3YqLTfBr2BnNVLOry5wVMA
# /LHqBpSUrr0xKww6otHLFSO1CotOAQ9Rb1dUn8kCQtYsn+VBGmIryjX0z90qyQ8T
# kTMdwhtjlu4IptodAGZ+1AmCvz9fClyEs5Jnv2yy+Gs2XDqm22JBVvF5Ge2pHxtr
# 1n0nYQdZD9mA8Dy6r8lriICFAcQqqLzGLGHLOCo8V4Uztrx/Umm0azn4979eoGSQ
# ogKEFiYblUOG2cBzkiMCwcxJLVsnaIY9tkP5Dn60W3DdMa1YYHsn77cytEzKHluX
# iRLnyQEBKcxepypuX7IguwqFw+zi1gUf5ev9Ym01bjTf9oUb1A4eY4WWC8uRO1VK
# zPjnPyPu2Xso8BkfWI1ae58RXO+/gS/WsSPXbc9unUYrhcTBZlJUdooTIcFwLfrP
# hoTAzkTKkx5LjUjV5chCA6hNqKUEKJ/5PXw5f6BC8hf7E5nblLkCzWGKEmTf/M3F
# bC9ExFMwL32Zn9yR1VXU77iBbLifgIMCFNF/ETUCmbWjiyRiYXo4zfyBcc6n4YCR
# yWly2QPUlJ9nm0EdFQ5escK++BdFiX0oCRrSKQ==
# SIG # End signature block
