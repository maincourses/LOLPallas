# Full portable verification, no installs or real game input.
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\portable-v3-c'),
    [string]$Python = 'D:\anaconda\python.exe')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $Python (Join-Path $root 'tests\Test-Hotkeys-Native.py') --build $BuildDirectory --portable
if ($LASTEXITCODE) { throw 'Portable native tests failed.' }
& $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-Portable.ps1') -BuildDirectory $BuildDirectory
if ($LASTEXITCODE) { throw 'Portable transactions failed.' }
& $shell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'Edit-Hotkeys-GUI.ps1') -Portable -SelfTest
if ($LASTEXITCODE) { throw 'Portable GUI failed.' }
Write-Host 'ALL PORTABLE OFFLINE TESTS PASSED. No live changes or real game sends.'
