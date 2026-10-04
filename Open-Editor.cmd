@echo off
setlocal
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Edit-Hotkeys-GUI.ps1"
