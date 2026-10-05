@echo off
setlocal
title LOLPallas - Restore working 64 KiB twenty messages
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-Pallas-Banks80.ps1" -Mode Restore
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo Restore refused or failed. Keep all backups and review the error above.
pause
exit /b %result%
