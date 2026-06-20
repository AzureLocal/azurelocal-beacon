@echo off
:: ============================================================
:: startnet.cmd — AzL Beacon WinPE boot entry point
:: Injected into \Windows\System32\startnet.cmd at image build.
::
:: v1.0.1 — launches the interactive Beacon menu orchestrator
:: (Start-AzlBeacon.ps1) which handles DHCP/static bootstrap
:: and presents the split validation menu.
:: ============================================================

:: Initialize the WinPE network stack (required before any network op)
wpeinit

echo.
echo ============================================================
echo   AzL Beacon v1.0.1
echo   Azure Local Pre-Deployment Validation
echo   Dell AX 16G  ^|  HCS Platform
echo ============================================================
echo.
echo Launching AzL Beacon (interactive menu)...
echo.

:: Prefer PS7 xcopy-deployed into the image
X:\Tools\PowerShell7\pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Tools\Start-AzlBeacon.ps1
if %ERRORLEVEL% EQU 0 goto :beacon_done
if %ERRORLEVEL% EQU 1 goto :beacon_done

:: PS7 not found or crashed — fall back to WinPE built-in PS 5.1
echo WARNING: pwsh.exe exited with code %ERRORLEVEL% or was not found.
echo Falling back to WinPE built-in PowerShell (5.1 subset)...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Tools\Start-AzlBeacon.ps1

:beacon_done
echo.
echo ============================================================
echo   AzL Beacon session ended. Dropping to command prompt.
echo   Results are in X:\results\ if any tests were run.
echo   DO NOT REBOOT unless you intend to exit the session.
echo ============================================================
echo.
cmd.exe /k
