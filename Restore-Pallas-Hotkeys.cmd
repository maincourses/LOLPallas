@echo off
setlocal
title Pallas Local Hotkeys - Restore
echo This restores the previous 8 KiB / twenty-message version.
echo Exit the game and WeGame first. Your v2 text will be retained.
choice /C YN /N /M "Restore? [Y/N] "
if errorlevel 2 exit /b 0
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Pallas-Hotkeys.ps1" -Mode Restore
set "LPS_EXIT=%ERRORLEVEL%"
pause
exit /b %LPS_EXIT%
