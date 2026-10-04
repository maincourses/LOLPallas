@echo off
setlocal
title Pallas Twenty - Enable or Apply Messages
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Twenty-Release.ps1" -Mode Enable
set "TwentyExit=%ERRORLEVEL%"
echo.
echo Script exit code: %TwentyExit%
pause
exit /b %TwentyExit%
