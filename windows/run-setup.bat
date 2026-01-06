@echo off
rem Double-clickable launcher for setup.ps1.
rem Bypasses PowerShell execution policy for this run only (no system change).
rem Extra arguments pass through, e.g.:  run-setup.bat -VerifyOnly

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
echo Setup finished with exit code %EXITCODE%. Press any key to close.
pause >nul
exit /b %EXITCODE%
