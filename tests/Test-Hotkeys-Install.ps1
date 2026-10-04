# Mock filesystem transactions only: no real DLL/WeGame paths are written.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'Manage-Pallas-Hotkeys.ps1') -FunctionsOnly
$script:Checks = 0; $script:FakeRunning = $false; $script:Fault = $false
function Check($Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed 'Expected refusal' }
function Assert-ShoutStopped { if ($script:FakeRunning) { throw 'Mock running-process guard' } }
function Write-HotkeyData([byte[]]$Bytes, [string]$Path, $Before, [string]$ExpectedDll) {
    if ($script:Fault -and $Path -eq $response -and (Get-ShoutByteHash $Bytes) -eq $script:FaultResponseHash) {
        $script:Fault = $false; throw 'Mock response commit failure'
    }
    Write-LibraryFile $Bytes $Path $Before $dll $ExpectedDll $loader $loaderHash
}
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $projectRoot ('build\hotkeys-deployment-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$source = Get-Content -LiteralPath (Join-Path $projectRoot 'messages.example.json') -Raw -Encoding UTF8
$compiled = ConvertTo-HotkeyArtifacts $source
$edited = $source | ConvertFrom-Json; $edited.'0' = 'New local message'; $edited.bind0 = 'Ctrl+Shift+Q'
$changed = ConvertTo-HotkeyArtifacts ($edited | ConvertTo-Json)
function Reset-Fixture {
    $folder = Join-Path $work ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $folder | Out-Null
    $script:dll = Join-Path $folder 'TenPallas.dll'; $script:loader = Join-Path $folder 'pallas.exe'
    $script:response = Join-Path $folder 'local-response.json'; $script:library = Join-Path $folder 'hotkeys-v2.bin'
    $script:baselineLibrary = Join-Path $folder 'library20-v1.json'; $script:v1StatePath = Join-Path $folder 'v1-state.json'
    $script:stateRoot = Join-Path $folder 'HotkeysV2Experiment'; $script:statePath = Join-Path $stateRoot 'state.json'
    $script:dllBackup = Join-Path $stateRoot 'TenPallas.before-hotkeys.dll'
    $script:responseBackup = Join-Path $stateRoot 'response.before-hotkeys.json'
    $script:libraryBackup = Join-Path $stateRoot 'library.before-hotkeys.json'; $script:HotkeyStateHash = $null
    $script:candidate = Join-Path $folder 'candidate.dll'
    [IO.File]::WriteAllBytes($dll, $utf8.GetBytes('fixture-v1')); [IO.File]::WriteAllBytes($candidate, $utf8.GetBytes('fixture-v2'))
    [IO.File]::WriteAllBytes($loader, $utf8.GetBytes('fixture-loader')); [IO.File]::WriteAllBytes($response, $utf8.GetBytes('fixture-response-v1'))
    [IO.File]::Copy((Join-Path $projectRoot 'experiments\local-library\scheme20.example.json'), $baselineLibrary)
    $script:baselineHash = Get-ShoutFileHash $dll; $script:candidateHash = Get-ShoutFileHash $candidate
    $script:loaderHash = Get-ShoutFileHash $loader
    $v1 = @{ experiment = 'local-library-v1'; candidate_dll_sha256 = $baselineHash
        installed_response_sha256 = Get-ShoutFileHash $response; installed_library_sha256 = Get-ShoutFileHash $baselineLibrary }
    [IO.File]::WriteAllBytes($v1StatePath, $utf8.GetBytes(($v1 | ConvertTo-Json)))
}
Reset-Fixture
$record = Install-Hotkeys $compiled $candidate
Check ((Get-ShoutFileHash $dllBackup) -eq $baselineHash) 'v1 DLL backup'
Check ((Get-ShoutFileHash $responseBackup) -eq $record.previous_response_sha256) 'v1 response backup'
Check ((Get-ShoutFileHash $libraryBackup) -eq $record.previous_library_sha256) 'v1 library backup'
Check ((Get-ShoutFileHash $dll) -eq $candidateHash -and (Get-ShoutFileHash $library) -eq $compiled.LibraryHash -and (Get-ShoutFileHash $response) -eq $compiled.ResponseHash) 'Three-file installation readback'
Check ((Read-HotkeyState).message_count -eq 3) 'State readback'
Apply-Hotkeys $changed
Check ((Get-ShoutFileHash $library) -eq $changed.LibraryHash -and (Get-ShoutFileHash $response) -eq $changed.ResponseHash) 'Apply new bindings/text'
$after = Read-HotkeyState; Restore-Hotkeys $after $true
Check ((Get-ShoutFileHash $dll) -eq $baselineHash -and (Get-ShoutFileHash $response) -eq $after.previous_response_sha256) 'Restore user-tested v1 pair'
Check ((Get-ShoutFileHash $baselineLibrary) -eq $after.previous_library_sha256) 'Restore v1 library'
Check ((Get-ShoutFileHash $library) -eq $changed.LibraryHash) 'Never delete edited v2 library'
Reject { Apply-Hotkeys $compiled }
Reset-Fixture; $record = Install-Hotkeys $compiled $candidate
[IO.File]::WriteAllBytes($response, $utf8.GetBytes('concurrent response'))
$concurrentHash = Get-ShoutFileHash $response
Reject { Restore-Hotkeys $record $false }
Check ((Get-ShoutFileHash $dll) -eq $candidateHash -and (Get-ShoutFileHash $response) -eq $concurrentHash) 'Rollback preflight preserves unknown edits'
Reject { Apply-Hotkeys $changed }
Check ((Get-ShoutFileHash $library) -eq $compiled.LibraryHash) 'Apply preflight before first write'
Restore-Hotkeys $record $true
Check (@(Get-ChildItem -LiteralPath $stateRoot -Filter 'response-preserved-*.json' | Where-Object { (Get-ShoutFileHash $_.FullName) -eq $concurrentHash }).Count -eq 1) 'Manual restore preserves external response'
Reset-Fixture; $record = Install-Hotkeys $compiled $candidate
$script:FaultResponseHash = $changed.ResponseHash; $script:Fault = $true
Reject { Apply-Hotkeys $changed }
Check ((Get-ShoutFileHash $library) -eq $compiled.LibraryHash -and (Get-ShoutFileHash $response) -eq $compiled.ResponseHash) 'Failed two-file apply rolled back'
Check ((Read-HotkeyState).installed_library_sha256 -eq $compiled.LibraryHash) 'Failed apply state remains consistent'
$script:FakeRunning = $true; Reject { Apply-Hotkeys $changed }; Reject { Restore-Hotkeys $record $true }
Check ((Get-ShoutFileHash $dll) -eq $candidateHash) 'Running guard preserves DLL'
$script:FakeRunning = $false
$stateHash = Get-ShoutFileHash $statePath
[IO.File]::WriteAllBytes($statePath, $utf8.GetBytes('foreign state'))
Reject { Save-HotkeyState $record }
Check ((Get-ShoutFileHash $statePath) -ne $stateHash) 'CAS preserves foreign state'
[IO.File]::WriteAllBytes($dll, $utf8.GetBytes('unknown DLL'))
Reject { Restore-Hotkeys $record $true }
Reset-Fixture; $script:FakeRunning = $true; Reject { Install-Hotkeys $compiled $candidate }
Check (-not (Test-Path -LiteralPath $stateRoot)) 'Blocked install creates no state/backup'
$script:FakeRunning = $false
[IO.File]::WriteAllBytes($baselineLibrary, $utf8.GetBytes('unknown v1 library'))
Reject { Install-Hotkeys $compiled $candidate }
Check (-not (Test-Path -LiteralPath $stateRoot)) 'Inconsistent v1 rejected before writes'
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned stages'
Write-Host ('PASS: ' + $script:Checks + ' mock installation/apply/restore checks. Fixtures: ' + $work)
