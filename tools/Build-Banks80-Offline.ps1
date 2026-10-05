# OFFLINE ONLY. No install, live writes, game input or Tencent DLL loading.
param(
    [string]$ArtifactDirectory,
    [string]$SeedLibrary,
    [string]$BaselineBuild
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $ArtifactDirectory) {
    $ArtifactDirectory = Join-Path $project ('build\legacy-banks80-chinese100-' + [guid]::NewGuid().ToString('N'))
}
if (-not $SeedLibrary) { $SeedLibrary = 'C:\Users\zly\AppData\Local\PallasCustomShout\library20-v1.json' }
if (-not $BaselineBuild) { $BaselineBuild = Join-Path $project 'build\legacy-capacity64k-control-recheck-20261005' }
$python = 'D:\anaconda\python.exe'
$baseline = Join-Path $BaselineBuild 'TenPallas.library.experimental.dll'
$source = Join-Path $project 'engine\assets\TenPallas.original.dll'
& $python (Join-Path $project 'tools\native\PallasBanks80.py') --seed-library $SeedLibrary --baseline $baseline --source $source --out-dir $ArtifactDirectory
if ($LASTEXITCODE -ne 0) { throw 'Offline bank candidate build failed; nothing installed.' }
& $python (Join-Path $project 'tests\Test-Count80.py') --build (Join-Path $ArtifactDirectory 'receive-control') --baseline-build $BaselineBuild
if ($LASTEXITCODE -ne 0) { throw 'Real Chinese receive/index comparison failed; nothing installed.' }
& $python (Join-Path $project 'tests\Test-Banks80.py') --build $ArtifactDirectory --baseline-build $BaselineBuild
if ($LASTEXITCODE -ne 0) { throw 'Own bank/adapter/UTF-8 tests failed; nothing installed.' }
# No test report is overwritten in the established capacity-control build.
foreach ($childMode in @('--child','--real-io-child')) {
    & $python (Join-Path $project 'tests\Test-Library-Native.py') --build $BaselineBuild $childMode
    if ($LASTEXITCODE -ne 0) { throw 'Established 64 KiB reader regression failed; nothing installed.' }
    & $python (Join-Path $project 'tests\Test-Library-Native.py') --build $BaselineBuild $childMode --control-baseline
    if ($LASTEXITCODE -ne 0) { throw 'Established 8 KiB reader regression failed; nothing installed.' }
}
Write-Output ('OFFLINE EIGHTY CHINESE MESSAGES / FOUR BANKS / 100-UNIT GUARD VALIDATED, NOT INSTALLED: ' + $ArtifactDirectory)
