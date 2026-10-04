@echo off
setlocal
cd /d "%~dp0"
set "LOLPALLAS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "LOLPALLAS_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%LOLPALLAS_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Portable.ps1" -Action Install
pause
