@echo off
:: ============================================================
:: startnet.cmd — AzL Beacon WinPE validation boot script
:: Injected into \Windows\System32\startnet.cmd at image build.
:: ============================================================

:: Initialize the WinPE network stack (required before any network op)
wpeinit

echo.
echo ============================================================
echo   AzL Beacon — Azure Local Pre-Deployment Validation
echo ============================================================
echo.
echo Waiting 15 seconds for NIC driver init and DHCP lease...
ping -n 16 127.0.0.1 > nul

:: ---- IP check --------------------------------------------------
:: Capture the first routable IPv4 address (exclude 127.x and 169.254.x)
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "IPv4" ^| findstr /v "127\." ^| findstr /v "169\.254\."') do (
    set _IP=%%a
    goto :ip_found
)

:ip_found
if not defined _IP goto :no_ip
set _IP=%_IP: =%
echo Network: acquired address %_IP%
goto :launch_ps

:no_ip
echo.
echo WARNING: No IPv4 address detected. DHCP may not have responded.
echo.
echo To configure a static management address, open a second command window
echo and run:
echo.
echo   netsh interface ip set address "Ethernet" static ^<IP^> ^<MASK^> ^<GW^>
echo   netsh interface ip set dns "Ethernet" static ^<PRIMARY-DNS^>
echo.
echo Press any key to attempt script launch anyway (network tests will fail).
echo If you configure a static IP first, reboot is NOT required -- just
echo press a key after setting it.
pause > nul

:launch_ps
echo.
echo Launching validation script via PowerShell 7...
echo.

:: Prefer PS7 xcopy-deployed into the image
X:\Tools\PowerShell7\pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Tools\Start-AzlValidation.ps1
if %ERRORLEVEL% EQU 0 goto :script_done
if %ERRORLEVEL% EQU 1 goto :script_done
if %ERRORLEVEL% EQU 2 goto :script_done

:: PS7 binary not found or failed to start — fall back to WinPE built-in PowerShell
echo WARNING: pwsh.exe exited with code %ERRORLEVEL% or was not found.
echo Falling back to WinPE built-in PowerShell (5.1 subset)...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Tools\Start-AzlValidation.ps1

:script_done
echo.
echo ============================================================
echo   Validation complete. Dropping to command prompt.
echo   Results are in X:\results\ if the script ran successfully.
echo   DO NOT REBOOT unless you intend to exit the session.
echo ============================================================
echo.
cmd.exe /k
