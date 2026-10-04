# All tests are offline/readonly with generated fixtures under build/test-work.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($test in @('tests\Test-Guards.ps1', 'tests\Test-Editor.ps1')) {
    & $powershell -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $root $test)
    if ($LASTEXITCODE -ne 0) { throw ('Test failed: ' + $test) }
}
& $powershell -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $root 'Edit-Twenty-GUI.ps1') -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'GUI startup test failed.' }
Write-Output 'ALL TESTS PASSED. No live installs, response changes or game messages.'
