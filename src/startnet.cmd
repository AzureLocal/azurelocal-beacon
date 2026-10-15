@echo off
:: ============================================================
:: startnet.cmd - AzL Beacon WinPE boot entry point.
:: Installed to \Windows\System32\startnet.cmd by Build-WinPEImage.ps1,
:: which also fills in the version and brand tokens below.
::
:: Launches the interactive Beacon menu (Start-AzlBeacon.ps1), which runs
:: the DHCP/static network bootstrap and shows the validation menu.
:: ============================================================

:: Initialize the WinPE network stack (required before any network operation)
wpeinit

echo.
echo ============================================================
echo   AzL Beacon @@BEACON_VERSION@@
echo   Azure Local Pre-Deployment Validation
@@BRAND_LINE@@
echo ============================================================
echo.
echo Launching AzL Beacon (interactive menu)...
echo.

:: Best effort: PowerShell 7 extracted into the image. WinPE lacks some of the
:: runtime PowerShell 7 expects, so any failure falls back to Windows PowerShell 5.1.
if exist X:\Tools\PowerShell7\pwsh.exe (
    X:\Tools\PowerShell7\pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Tools\Start-AzlBeacon.ps1
    if %ERRORLEVEL% EQU 0 goto :beacon_done
    echo.
    echo WARNING: pwsh.exe exited with code %ERRORLEVEL%.
) else (
    echo PowerShell 7 is not present in this image.
)

echo Falling back to Windows PowerShell 5.1 (WinPE built-in)...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Tools\Start-AzlBeacon.ps1

:beacon_done
echo.
echo ============================================================
echo   AzL Beacon session ended. Dropping to command prompt.
echo   Results are in X:\results\ if any tests were run.
echo   Copy them off (menu option 8) BEFORE rebooting; the RAM
echo   drive is lost on reboot.
echo ============================================================
echo.
cmd.exe /k
