@echo off
setlocal
title Pallas Local Library - Experimental Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Pallas-Library.ps1" -Mode Install -AcceptUnsignedExperiment
set "libraryResult=%errorlevel%"
echo.
if not "%libraryResult%"=="0" echo Installation failed. Read the error above; do not bypass validation.
pause
exit /b %libraryResult%
