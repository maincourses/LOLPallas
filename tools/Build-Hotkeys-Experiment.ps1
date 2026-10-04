# OFFLINE ONLY. Builds to a NEW directory; never loads/installs a Tencent DLL.
param([string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $project ('build\hotkeys-v2-' + [guid]::NewGuid().ToString('N')) }
$python = 'D:\anaconda\python.exe'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $python (Join-Path $project 'tools\native\PallasHotkeys.py') --scheme (Join-Path $project 'messages.example.json') --out-dir $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Offline build failed; nothing installed.' }
& $python (Join-Path $project 'tests\Test-Hotkeys-Native.py') --build $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Native fixture failed; nothing installed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Test-Hotkeys.ps1') -BuildDirectory $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Artifact/source tests failed; nothing installed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Test-Hotkeys-Install.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Deployment/rollback fixture failed; nothing installed.' }
& $windowsPowerShell -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $project 'Edit-Hotkeys-GUI.ps1') -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'GUI test failed; nothing installed.' }
Write-Output ('OFFLINE CANDIDATE VALIDATED, NOT INSTALLED: ' + $ArtifactDirectory)
