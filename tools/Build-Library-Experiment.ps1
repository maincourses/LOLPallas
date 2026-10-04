# OFFLINE build/test runner. No installation or game input.
param([string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $project 'build\local-library-v1' }
$python = 'D:\anaconda\python.exe'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $python (Join-Path $project 'tools\native\PallasLibrary.py') --scheme (Join-Path $project 'experiments\local-library\scheme20.example.json') --source (Join-Path $project 'engine\assets\TenPallas.original.dll') --out-dir $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Candidate build failed; nothing installed.' }
& $python (Join-Path $project 'tests\Test-Library-Native.py') --build $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Offline/native test failed; nothing installed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Test-Library.ps1') -BuildDirectory $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Library artifact/writer test failed; nothing installed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Test-Library-Install.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Deployment/rollback fixture failed; nothing installed.' }
Write-Output ('OFFLINE CANDIDATE VALIDATED, NOT INSTALLED: ' + $ArtifactDirectory)
