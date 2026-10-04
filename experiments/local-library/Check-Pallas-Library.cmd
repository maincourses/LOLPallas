@echo off
setlocal
title Pallas Local Library - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Pallas-Library.ps1" -Mode Status
set "libraryResult=%errorlevel%"
echo.
pause
exit /b %libraryResult%
