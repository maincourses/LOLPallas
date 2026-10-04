# Own fixture paths only; no production writes, Tencent DLL loads or game sends.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'lib\NativeKeyTools.ps1')
$script:Checks = 0
function Check($Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed 'Expected refusal' }
$utf8 = New-Object Text.UTF8Encoding($false)
$compiled = ConvertTo-HotkeyArtifacts ([IO.File]::ReadAllText((Join-Path $project 'portable\messages.example.json'),$utf8)) -FormatVersion 3
Assert-NativeKeyScheme $compiled.Scheme
Check ($compiled.Scheme.count -eq 20) 'Twenty native slots'
$bad = $compiled.Scheme | ConvertTo-Json | ConvertFrom-Json; $bad.bind0 = 'Ctrl+Alt+Q'
Reject { Assert-NativeKeyScheme $bad }
$bad.count = 19
Reject { Assert-NativeKeyScheme $bad }
$reconstructed = Expand-PortableDelta ([IO.File]::ReadAllBytes((Join-Path $project 'build\portable-v3-r2\TenPallas.portable.experimental.dll'))) (Join-Path $project 'build\nativekeys-64k-v1\portable-fixed-to-native20.json') $script:NativeKeysDeltaHash
Check ((Get-ShoutByteHash $reconstructed) -eq $script:NativeKeysHash) 'Pinned native reconstruction'
$work = Join-Path $project ('build\native-key-transactions-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
function Assert-ShoutStopped { if ($script:Running) { throw 'Fixture process running' } }
function Get-AuthenticodeSignature { param([string]$LiteralPath) return [pscustomobject]@{ Status = 'Valid' } }
$script:Running = $false
function New-Fixture {
    $fixture = Join-Path $work ([guid]::NewGuid().ToString('N'))
    $root = Join-Path $fixture ('Different WeGame ' + [char]0x7528 + [char]0x6237)
    $data = Join-Path $fixture 'Local Data'
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'apps\Pallas\tp_deps'),$data)
    $dll = Join-Path $root 'apps\Pallas\tp_deps\TenPallas.dll'
    $loader = Join-Path $root 'apps\Pallas\pallas.exe'
    [IO.File]::WriteAllBytes($dll,$utf8.GetBytes('fixture original'))
    [IO.File]::WriteAllBytes($loader,$utf8.GetBytes('fixture loader'))
    $script:PortableOriginalHash = Get-ShoutFileHash $dll
    $script:PortableLoaderHash = Get-ShoutFileHash $loader
    $previousBytes = $utf8.GetBytes('fixture independent')
    $script:PortableTargetHash = Get-ShoutByteHash $previousBytes
    $context = New-PortableContext $root $data
    [void](Install-PortableComponent $context $compiled $previousBytes)
    [void](New-Item -ItemType Directory -Path (Join-Path $data 'Editor'))
    [IO.File]::WriteAllBytes((Join-Path $data 'Editor\messages.json'),(Get-PortableSourceBytes $compiled))
    $script:PortablePreviousHash = $script:PortableTargetHash
    $script:CandidateBytes = $utf8.GetBytes('fixture native twenty')
    $script:PortableTargetHash = Get-ShoutByteHash $script:CandidateBytes
    return $context
}
$context = New-Fixture
$before = Read-PortableState $context
$beforeHashes = @{}
foreach ($path in @($context.Library,$context.Source,$context.Loader,(Join-Path $context.Data 'Editor\messages.json'))) { $beforeHashes[$path] = Get-ShoutFileHash $path }
$after = Upgrade-PortableComponent $context $script:CandidateBytes -Revision 'native-keys-64k-r1' -KeyboardMode 'native20'
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableTargetHash) 'Native component readback'
Check ($after.baseline_dll_sha256 -eq $before.baseline_dll_sha256 -and $after.backup_id -eq $before.backup_id) 'Initial restore baseline retained'
Check ($after.keyboard_mode -eq 'native20' -and $after.repair_revision -eq 'native-keys-64k-r1') 'Native mode metadata'
Check (-not $after.runtime_verified -and -not $after.game_send_verified) 'No game validation claimed'
foreach ($path in $beforeHashes.Keys) { Check ((Get-ShoutFileHash $path) -eq $beforeHashes[$path]) 'Texts/drafts/loader byte-exact preservation' }
$upgrade = @(Get-ChildItem -LiteralPath (Join-Path $context.Data 'backups') -Directory -Filter 'upgrade-*')
Check ($upgrade.Count -eq 1) 'Recoverable immediate component backup'
Check ((Get-ShoutFileHash (Join-Path $upgrade[0].FullName 'TenPallas.previous.dll')) -eq $script:PortablePreviousHash) 'Previous DLL backup readback'
Check ((Get-ShoutFileHash (Join-Path $upgrade[0].FullName 'state.previous.json')) -eq (Get-ShoutByteHash ($utf8.GetBytes(($before | ConvertTo-Json -Depth 5))))) 'Previous state backup readback'
Reject { Upgrade-PortableComponent $context $script:CandidateBytes -Revision 'native-keys-64k-r1' -KeyboardMode 'native20' }
$edited = $compiled.Scheme | ConvertTo-Json | ConvertFrom-Json; $edited.'0' = 'Native mode edited message'
$changed = ConvertTo-HotkeyArtifacts ($edited | ConvertTo-Json) -FormatVersion 3
Assert-NativeKeyScheme $changed.Scheme
Apply-PortableMessages $context $changed
Check ((Get-ShoutFileHash $context.Library) -eq $changed.LibraryHash) 'Native mode text apply'
Check ((Read-PortableState $context).keyboard_mode -eq 'native20') 'Text apply retains keyboard mode'
$context = New-Fixture
$stateBefore = Get-ShoutFileHash $context.State; $libraryBefore = Get-ShoutFileHash $context.Library
$sourceBefore = Get-ShoutFileHash $context.Source
$script:Running = $true
Reject { Upgrade-PortableComponent $context $script:CandidateBytes -Revision 'native-keys-64k-r1' -KeyboardMode 'native20' }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortablePreviousHash -and (Get-ShoutFileHash $context.State) -eq $stateBefore) 'Running guard has no writes'
$script:Running = $false
$realSave = ${function:Save-PortableState}
$script:FailCommit = $true
function Save-PortableState($Context,$Record) {
    if ($script:FailCommit -and $Record.candidate_dll_sha256 -eq $script:PortableTargetHash) { $script:FailCommit = $false; throw 'Fixture state commit failure' }
    & $realSave $Context $Record
}
Reject { Upgrade-PortableComponent $context $script:CandidateBytes -Revision 'native-keys-64k-r1' -KeyboardMode 'native20' }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortablePreviousHash -and (Get-ShoutFileHash $context.State) -eq $stateBefore) 'Failed state commit restores component/state'
Check ((Get-ShoutFileHash $context.Library) -eq $libraryBefore -and (Get-ShoutFileHash $context.Source) -eq $sourceBefore) 'Failed upgrade preserves texts'
[IO.File]::WriteAllBytes($context.Source,$utf8.GetBytes('fixture external edit'))
Reject { Upgrade-PortableComponent $context $script:CandidateBytes -Revision 'native-keys-64k-r1' -KeyboardMode 'native20' }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortablePreviousHash -and [IO.File]::ReadAllText($context.Source) -eq 'fixture external edit') 'Concurrent source change never overwritten'
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned staging files'
Write-Host ('PASS: ' + $script:Checks + ' native-key source/delta/upgrade/apply/preservation/rollback checks; own fixtures only. ' + $work)
