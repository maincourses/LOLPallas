@echo off
setlocal
title Pallas Local Hotkeys - Status
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Pallas-Hotkeys.ps1" -Mode Status
set "LPS_EXIT=%ERRORLEVEL%"
pause
exit /b %LPS_EXIT%
