# All data below are own plaintext fixtures. No production writes or DLL loads.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Restore-Pallas-OriginalDll.ps1') -FunctionsOnly
$script:Checks = 0
function Check($Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed 'Expected refusal' }
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $project ('build\original-dll-restore-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$compiled = ConvertTo-HotkeyArtifacts ([IO.File]::ReadAllText((Join-Path $project 'portable\messages.example.json'),$utf8)) -FormatVersion 3
function Assert-ShoutStopped { if ($script:Running) { throw 'Fixture process running' } }
function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    return [pscustomobject]@{ Status=$script:Signature; SignerCertificate=[pscustomobject]@{Subject='CN=Tencent Technology (Shenzhen) Company Limited'} }
}
$script:Signature = 'Valid'; $script:Running = $false
function New-Fixture {
    $folder = Join-Path $work ([guid]::NewGuid().ToString('N')); $root = Join-Path $folder 'WeGame'; $data = Join-Path $folder 'Profile'
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'apps\Pallas\tp_deps'),$data)
    $dll = Join-Path $root 'apps\Pallas\tp_deps\TenPallas.dll'; $loader = Join-Path $root 'apps\Pallas\pallas.exe'
    [IO.File]::WriteAllBytes($dll,$utf8.GetBytes('fixture install baseline')); [IO.File]::WriteAllBytes($loader,$utf8.GetBytes('fixture loader'))
    $script:PortableOriginalHash = Get-ShoutFileHash $dll; $script:PortableLoaderHash = Get-ShoutFileHash $loader
    $candidate = $utf8.GetBytes('fixture native candidate'); $script:PortableTargetHash = Get-ShoutByteHash $candidate
    $script:NativeKeysHash = $script:PortableTargetHash
    $context = New-PortableContext $root $data
    [void](Install-PortableComponent $context $compiled $candidate)
    $record = Read-PortableState $context; $record | Add-Member -NotePropertyName keyboard_mode -NotePropertyValue 'native20'; Save-PortableState $context $record
    $script:StockPath = Join-Path $folder 'own-stock-fixture.bin'
    [IO.File]::WriteAllBytes($script:StockPath,$utf8.GetBytes('fixture original signed DLL bytes'))
    $script:OriginalDllHash = Get-ShoutFileHash $script:StockPath
    return $context
}
$context = New-Fixture
$before = Read-PortableState $context; $stateBefore = Get-ShoutFileHash $context.State
$libraryBefore = Get-ShoutFileHash $context.Library; $sourceBefore = Get-ShoutFileHash $context.Source; $loaderBefore = Get-ShoutFileHash $context.Loader
$script:Running = $true; Reject { Restore-OriginalDllOnly $context $script:StockPath }; $script:Running = $false
Check ((Get-ShoutFileHash $context.State) -eq $stateBefore -and (Get-ShoutFileHash $context.Dll) -eq $before.candidate_dll_sha256) 'Running process guard no writes'
$script:Signature = 'HashMismatch'; Reject { Restore-OriginalDllOnly $context $script:StockPath }; $script:Signature = 'Valid'
Check ((Get-ShoutFileHash $context.Dll) -eq $before.candidate_dll_sha256) 'Invalid stock signature no replacement'
$record = Restore-OriginalDllOnly $context $script:StockPath
Check ((Get-ShoutFileHash $context.Dll) -eq $script:OriginalDllHash) 'Original DLL hash readback'
Check ($record.status -eq 'original-dll-restored' -and $record.keyboard_mode -eq 'original') 'State clearly marks original restoration'
Check ($record.baseline_dll_sha256 -eq $before.baseline_dll_sha256 -and $record.backup_id -eq $before.backup_id) 'Initial experimental restore baseline retained'
Check (-not $record.runtime_verified -and -not $record.game_send_verified) 'No game verification claimed'
Check ((Get-ShoutFileHash (Join-Path $record.original_dll_restore_backup 'TenPallas.previous.dll')) -eq $before.candidate_dll_sha256) 'Immediate DLL backup exact'
Check ((Get-ShoutFileHash (Join-Path $record.original_dll_restore_backup 'state.previous.json')) -eq $stateBefore) 'Previous state backup exact'
Check ((Get-ShoutFileHash $context.Library) -eq $libraryBefore -and (Get-ShoutFileHash $context.Source) -eq $sourceBefore -and (Get-ShoutFileHash $context.Loader) -eq $loaderBefore) 'Texts/library/launcher untouched'
[void](Restore-OriginalDllOnly $context $script:StockPath)
Reject { Apply-PortableMessages $context $compiled }
Reject { Restore-PortableComponent $context (Read-PortableState $context) }
$context = New-Fixture; $before = Read-PortableState $context; $stateBefore = Get-ShoutFileHash $context.State
$realWrite = ${function:Write-PortableFile}; $script:FaultPath = $context.State
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) { $script:FaultPath = $null; throw 'Fixture state commit failure' }
    & $realWrite $Context $Bytes $Path $Before $ExpectedDll
}
Reject { Restore-OriginalDllOnly $context $script:StockPath }
Check ((Get-ShoutFileHash $context.Dll) -eq $before.candidate_dll_sha256 -and (Get-ShoutFileHash $context.State) -eq $stateBefore) 'State failure restores prior DLL and state'
[IO.File]::WriteAllBytes($context.Dll,$utf8.GetBytes('fixture unknown updated DLL'))
Reject { Restore-OriginalDllOnly $context $script:StockPath }
Check ([IO.File]::ReadAllText($context.Dll) -eq 'fixture unknown updated DLL') 'Unknown component never overwritten'
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned temporary stages'
Write-Host ('PASS: ' + $script:Checks + ' original DLL restoration/backup/guards/rollback checks; own fixtures only.')
