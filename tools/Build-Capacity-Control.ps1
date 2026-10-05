# OFFLINE legacy capacity-only control. Never install or alter runtime files.
param([string]$ArtifactDirectory, [string]$BaselinePath)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $ArtifactDirectory) {
    $ArtifactDirectory = Join-Path $project ('build\legacy-capacity64k-control-' + [guid]::NewGuid().ToString('N'))
}
if (-not $BaselinePath) {
    $BaselinePath = Join-Path $project 'build\local-library-v1\TenPallas.library.experimental.dll'
}
$python = 'D:\anaconda\python.exe'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $python (Join-Path $project 'tools\native\PallasCapacityControl.py') --scheme (Join-Path $project 'experiments\local-library\scheme20.example.json') --source (Join-Path $project 'engine\assets\TenPallas.original.dll') --baseline $BaselinePath --out-dir $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Capacity-only build failed; nothing installed.' }
& $python (Join-Path $project 'tests\Test-Capacity-Control.py') --build $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Single-variable proof failed; nothing installed.' }
& $python (Join-Path $project 'tests\Test-Library-Native.py') --build $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Own-process A/B boundary tests failed; nothing installed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Test-Library.ps1') -BuildDirectory $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Legacy JSON artifact/writer regression failed; nothing installed.' }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tests\Test-Library-Install.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Legacy deployment/rollback regression failed; nothing installed.' }
Write-Output ('OFFLINE 64 KiB CAPACITY-ONLY CONTROL VALIDATED, NOT INSTALLED: ' + $ArtifactDirectory)
