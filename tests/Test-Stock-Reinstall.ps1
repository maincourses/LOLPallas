# Exercise the native-control -> signed-stock -> new-install migration in own fixtures.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'StockRestoreFixtures.ps1')
$script:Checks = 0
function Check($Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed 'Expected refusal' }
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $project ('build\stock-reinstall-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$compiled = (Read-HotkeyDocument (Join-Path $project 'portable\messages.example.json') -FormatVersion 3).Compiled
$defaults = (Read-HotkeyDocument (Join-Path $project 'messages.example.json') -FormatVersion 3).Compiled
function Assert-ShoutStopped { if ($script:Running) { throw 'Fixture process running' } }
function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    return [pscustomobject]@{Status=$script:Signature;SignerCertificate=[pscustomobject]@{Subject='CN=Tencent Technology (Shenzhen) Company Limited'}}
}
$script:Running = $false; $script:Signature = 'Valid'
function New-Fixture { return New-StockRestoreFixture $work $compiled -FullyRestored }
function File-Snapshot($Context) {
    $result = @{}
    foreach ($path in @($Context.Library,$Context.Source,$Context.Loader,(Join-Path $Context.Data 'Editor\messages.json'),(Join-Path $Context.Data 'Editor\settings.json'),$script:LegacyPath)) {
        $result[$path] = Get-ShoutFileHash $path
    }
    return $result
}
function Check-Snapshot($Snapshot) { foreach ($path in $Snapshot.Keys) { Check ((Get-ShoutFileHash $path) -eq $Snapshot[$path]) 'No text/draft/settings/launcher/legacy changes' } }
$context = New-Fixture; $before = Read-PortableState $context; $beforeHash = $context.StateHash
Check ($before.candidate_dll_sha256 -ne $script:PortableTargetHash -and $before.candidate_dll_sha256 -ne $script:PortablePreviousHash) 'Exact formerly unsupported historical candidate reproduced'
$snapshot = File-Snapshot $context
$oldBaseline = Join-Path $context.Data ('backups\' + $before.backup_id + '\TenPallas.before.dll')
$oldBaselineHash = Get-ShoutFileHash $oldBaseline
$dllRestoreHash = Get-ShoutFileHash (Join-Path $before.original_dll_restore_backup 'TenPallas.previous.dll')
$loaderRestoreHash = Get-ShoutFileHash (Join-Path $before.original_launcher_restore_backup 'pallas.previous.exe')
$new = Install-PortableComponent $context $defaults $script:LatestCandidateBytes
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableTargetHash) 'New candidate installed/read back'
Check ($new.backup_id -ne $before.backup_id -and $new.baseline_dll_sha256 -eq $script:PortableOriginalHash) 'New restore baseline is stock, not historical v2'
Check ($new.loader_sha256 -eq $script:PortableLoaderHash -and -not $new.loader_modified) 'Original launcher remains unchanged'
Check ($new.repair_revision -eq 'stock-reinstall-r1' -and $new.keyboard_mode -eq 'independent') 'New mode/revision metadata'
Check (-not $new.runtime_verified -and -not $new.game_send_verified) 'Game compatibility not claimed'
Check ($new.message_count -eq 20 -and $new.installed_library_sha256 -eq $before.installed_library_sha256) 'Prior applied twenty texts preserved, not three-entry defaults'
Check ($new.predecessor_state_sha256 -eq $beforeHash -and (Get-ShoutFileHash $new.predecessor_state_path) -eq $beforeHash) 'Full previous state archived exactly'
Check ($new.predecessor_backup_id -eq $before.backup_id -and (Get-ShoutFileHash $oldBaseline) -eq $oldBaselineHash) 'Original historical baseline retained'
Check ((Get-ShoutFileHash (Join-Path $before.original_dll_restore_backup 'TenPallas.previous.dll')) -eq $dllRestoreHash -and
    (Get-ShoutFileHash (Join-Path $before.original_launcher_restore_backup 'pallas.previous.exe')) -eq $loaderRestoreHash) 'Both restoration backups retained'
Check-Snapshot $snapshot
$newBackup = Join-Path $context.Data ('backups\' + $new.backup_id)
Check ((Get-ShoutFileHash (Join-Path $newBackup 'TenPallas.before.dll')) -eq $script:PortableOriginalHash) 'Pinned stock DLL recoverable'
Check ((Get-ShoutFileHash (Join-Path $newBackup 'library.before.bin')) -eq $before.installed_library_sha256 -and
    (Get-ShoutFileHash (Join-Path $newBackup 'applied-messages.before.json')) -eq $before.installed_source_sha256) 'Applied data also archived'
$draft = (Read-HotkeyDocument (Join-Path $context.Data 'Editor\messages.json') -FormatVersion 3).Compiled
Apply-PortableMessages $context $draft
Check ((Get-ShoutFileHash $context.Library) -eq $draft.LibraryHash) 'Visible draft can be applied separately'
Restore-PortableComponent $context (Read-PortableState $context)
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash -and (Get-ShoutFileHash $context.Loader) -eq $script:PortableLoaderHash) 'Restore returns stock pair, never historical modified launcher/DLL'
Check ((Get-ShoutFileHash $context.Library) -eq $draft.LibraryHash) 'Restore retains latest applied texts'
$reinstalled = Install-PortableComponent $context $defaults $script:LatestCandidateBytes
Check ($reinstalled.backup_id -eq $new.backup_id -and $reinstalled.installed_library_sha256 -eq $draft.LibraryHash) 'Ordinary restore/re-enable remains compatible'
$context = New-Fixture; $stateHash = Get-ShoutFileHash $context.State
$script:Running = $true; Reject { Install-PortableComponent $context $defaults $script:LatestCandidateBytes }; $script:Running = $false
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash -and (Get-ShoutFileHash $context.State) -eq $stateHash) 'Running guard no mutation'
$script:Signature = 'HashMismatch'; Reject { Install-PortableComponent $context $defaults $script:LatestCandidateBytes }; $script:Signature = 'Valid'
Check ((Get-ShoutFileHash $context.State) -eq $stateHash) 'Signature refusal retains record'
foreach ($fault in @('sid','wegame_root','candidate_dll_sha256','original_launcher_sha256','original_dll_restore_backup','installed_source_sha256','partial-status')) {
    $context = New-Fixture; $record = Read-PortableState $context
    if ($fault -eq 'partial-status') { $record.status = 'original-dll-restored' }
    elseif ($fault -eq 'sid') { $record.sid = 'S-1-5-foreign-fixture' }
    elseif ($fault -eq 'wegame_root') { $record.wegame_root = $work }
    elseif ($fault -eq 'original_dll_restore_backup') { $record.original_dll_restore_backup = $work }
    else { $record.$fault = 'F' * 64 }
    [IO.File]::WriteAllBytes($context.State,$utf8.GetBytes(($record | ConvertTo-Json -Depth 5)))
    $stateHash = Get-ShoutFileHash $context.State
    Reject { Install-PortableComponent $context $defaults $script:LatestCandidateBytes }
    Check ((Get-ShoutFileHash $context.State) -eq $stateHash -and (Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash) 'Foreign/unknown/partial state never overwritten'
}
$context = New-Fixture; $record = Read-PortableState $context
[IO.File]::WriteAllBytes((Join-Path $record.original_launcher_restore_backup 'pallas.previous.exe'),$utf8.GetBytes('fixture corrupted backup'))
Reject { Install-PortableComponent $context $defaults $script:LatestCandidateBytes }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash) 'Bad restoration proof no component writes'
$context = New-Fixture
[IO.File]::WriteAllBytes($context.Source,$utf8.GetBytes('fixture externally edited applied source'))
Reject { Install-PortableComponent $context $defaults $script:LatestCandidateBytes }
Check ([IO.File]::ReadAllText($context.Source) -eq 'fixture externally edited applied source' -and (Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash) 'External source retained'
$context = New-Fixture
[IO.File]::WriteAllBytes($context.Dll,$utf8.GetBytes('fixture previous portable DLL'))
Reject { Read-PortableState $context }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortablePreviousHash) 'Previous DLL with restored-stock state refused without recursive state reads'
$realWrite = ${function:Write-PortableFile}
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) {
        $script:FaultPath = $null
        if ($script:FaultAfter) { & $realWrite $Context $Bytes $Path $Before $ExpectedDll }
        throw 'Fixture stock reinstall commit failure'
    }
    & $realWrite $Context $Bytes $Path $Before $ExpectedDll
}
foreach ($afterWrite in @($false,$true)) {
    $context = New-Fixture; $stateHash = Get-ShoutFileHash $context.State; $snapshot = File-Snapshot $context
    $script:FaultPath = $context.State; $script:FaultAfter = $afterWrite
    Reject { Install-PortableComponent $context $defaults $script:LatestCandidateBytes }
    Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash -and (Get-ShoutFileHash $context.State) -eq $stateHash) 'Failed commit restores signed stock DLL and exact historical record'
    Check-Snapshot $snapshot
    Check ((Read-PortableState $context).status -eq 'original-components-restored') 'Rollback state still recognized'
}
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned staging files'
Write-Host ('PASS: ' + $script:Checks + ' stock restoration/reinstall/rebaseline/preservation/rollback/foreign-state checks; own fixtures only. ' + $work)
