@echo off
setlocal
title Pallas Twenty - Check
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Twenty-Release.ps1" -Mode Status
set "TwentyExit=%ERRORLEVEL%"
echo.
echo Script exit code: %TwentyExit%
pause
exit /b %TwentyExit%
