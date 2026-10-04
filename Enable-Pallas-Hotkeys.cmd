@echo off
setlocal
title Pallas Local Hotkeys - Enable
echo This is a version/profile-pinned UNSIGNED experiment.
echo Existing 8 KiB files will be backed up. Exit the game and WeGame first.
choice /C YN /N /M "Install this candidate? [Y/N] "
if errorlevel 2 exit /b 0
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Edit-Hotkeys-GUI.ps1" -InitializeOnly
set "LPS_EXIT=%ERRORLEVEL%"
if errorlevel 1 goto done
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Pallas-Hotkeys.ps1" -Mode Install -AcceptUnsignedExperiment
set "LPS_EXIT=%ERRORLEVEL%"
:done
pause
exit /b %LPS_EXIT%
