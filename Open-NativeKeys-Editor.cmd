@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Edit-Hotkeys-GUI.ps1" -Portable -NativeKeys -SourcePath "%LOCALAPPDATA%\LOLPallasPortable\Editor\messages.json"
if errorlevel 1 pause
