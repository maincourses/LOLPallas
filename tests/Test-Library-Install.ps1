# Exercise deployment helpers on FAKE bytes in build/test-work only.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'experiments\local-library\Manage-Pallas-Library.ps1') -FunctionsOnly
function Assert-ShoutStopped { if ($script:FakeRunning) { throw 'Fixture is running.' } }
$passed = 0
function Check([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:passed++
    Write-Output ('PASS: ' + $Label)
}
function Reject([scriptblock]$Action, [string]$Label) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Label
}
$dataRoot = Join-Path $project ('build\test-work\library-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataRoot | Out-Null
$dll = Join-Path $dataRoot 'fake-live.dll'
$loader = Join-Path $dataRoot 'fake-loader.bin'
$response = Join-Path $dataRoot 'response.json'
$library = Join-Path $dataRoot 'library.json'
$stateRoot = Join-Path $dataRoot 'backups'
New-Item -ItemType Directory -Path $stateRoot | Out-Null
$statePath = Join-Path $stateRoot 'state.json'
$dllBackup = Join-Path $stateRoot 'baseline.dll'
$responseBackup = Join-Path $stateRoot 'baseline-response.json'
$candidate = Join-Path $dataRoot 'candidate.dll'
[IO.File]::WriteAllBytes($dll, [byte[]]@(1,2,3))
[IO.File]::WriteAllBytes($loader, [byte[]]@(4,5,6))
[IO.File]::WriteAllBytes($response, [byte[]]@(7,8,9))
[IO.File]::WriteAllBytes($candidate, [byte[]]@(10,11,12))
$baselineHash = Get-ShoutFileHash $dll
$candidateHash = Get-ShoutFileHash $candidate
$loaderHash = Get-ShoutFileHash $loader
$previousHash = Get-ShoutFileHash $response
Backup-File $dll $dllBackup $baselineHash
Backup-File $response $responseBackup $previousHash
Check ((Get-ShoutFileHash $dllBackup) -eq $baselineHash -and (Get-ShoutFileHash $responseBackup) -eq $previousHash) 'Exact backups of the working twenty-version pair'
$record = [ordered]@{
    experiment = 'local-library-v1'; status = 'prepared'; dll_path = $dll
    library_path = $library; response_path = $response
    baseline_dll_sha256 = $baselineHash; candidate_dll_sha256 = $candidateHash
    previous_response_sha256 = $previousHash
    installed_library_sha256 = Get-ShoutByteHash ([byte[]]@(20,21))
    installed_response_sha256 = Get-ShoutByteHash ([byte[]]@(30,31))
}
$script:StateHash = $null
Save-State $record
Check ((Read-State).experiment -eq 'local-library-v1') 'State identity and backup hashes read back'
Write-Data ([byte[]]@(20,21)) $library $null $baselineHash
Write-Dll $candidate $candidateHash $baselineHash
Write-Data ([byte[]]@(30,31)) $response $previousHash $candidateHash
Check ((Get-ShoutFileHash $dll) -eq $candidateHash -and (Get-ShoutFileHash $response) -eq $record.installed_response_sha256) 'Isolated library/DLL/bootstrap deployment'
Restore-Baseline $record $false
Check ((Get-ShoutFileHash $dll) -eq $baselineHash -and (Get-ShoutFileHash $response) -eq $previousHash) 'Automatic rollback returns to exact working twenty pair'
Check ((Get-ShoutFileHash $library) -eq $record.installed_library_sha256) 'Rollback retains text instead of deleting it'
Write-Dll $candidate $candidateHash $baselineHash
[IO.File]::WriteAllBytes($response, [byte[]]@(99))
$editedHash = Get-ShoutFileHash $response
Reject { Restore-Baseline $record $false } 'Automatic rollback refuses concurrent response changes'
Check ((Get-ShoutFileHash $response) -eq $editedHash -and (Get-ShoutFileHash $dll) -eq $candidateHash) 'Refused rollback leaves both files intact'
Restore-Baseline $record $true
$preserved = @(Get-ChildItem -LiteralPath $stateRoot -Filter 'response-preserved-*.json')
Check ($preserved.Count -eq 1 -and (Get-ShoutFileHash $preserved[0].FullName) -eq $editedHash) 'Manual restore preserves edited response in a new backup'
Check ((Get-ShoutFileHash $response) -eq $previousHash -and (Get-ShoutFileHash $dll) -eq $baselineHash) 'Manual restore returns exact previous twenty version'
[IO.File]::WriteAllBytes($dll, [byte[]]@(88))
Reject { Restore-Baseline $record $true } 'Unknown or updated DLL is never overwritten'
[IO.File]::WriteAllBytes($dll, [byte[]]@(1,2,3))
$script:FakeRunning = $true
Reject { Restore-Baseline $record $true } 'Running-process guard blocks restoration before writes'
$script:FakeRunning = $false
$beforeState = Get-ShoutFileHash $statePath
[IO.File]::WriteAllBytes($statePath, [byte[]]@(77))
Reject { Save-State $record } 'Stale installation state cannot overwrite a concurrent edit'
Check ((Get-ShoutFileHash $statePath) -eq (Get-ShoutByteHash ([byte[]]@(77)))) 'Concurrent state preserved'
Check (@(Get-ChildItem -LiteralPath $dataRoot -Recurse -Filter '*.tmp').Count -eq 0) 'Isolated deployment stages cleaned after failures'
Write-Output ('INSTALL HELPER CHECKS PASSED: ' + $passed)
