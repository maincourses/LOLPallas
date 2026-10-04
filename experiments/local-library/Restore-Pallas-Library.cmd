@echo off
setlocal
title Pallas Local Library - Restore Working Twenty Version
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Pallas-Library.ps1" -Mode Restore
set "libraryResult=%errorlevel%"
echo.
if not "%libraryResult%"=="0" echo Restore failed. Keep backups and read the error above.
pause
exit /b %libraryResult%
