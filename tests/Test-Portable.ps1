# Isolated fixture files only. No production WeGame/profile writes or DLL loads.
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\portable-v3-r2'))
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Manage-Pallas-Portable.ps1') -FunctionsOnly
$script:Checks = 0
function Check($Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed ('Expected refusal: ' + $Action.ToString()) }
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $project ('build\portable-transactions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$text = Get-Content -LiteralPath (Join-Path $project 'messages.example.json') -Raw -Encoding UTF8
$compiled = ConvertTo-HotkeyArtifacts $text -FormatVersion 3
Check ($compiled.LibraryBytes.Length -eq 82) 'Portable header size'
Check ($compiled.LibraryHash -eq (Get-ShoutFileHash (Join-Path $BuildDirectory 'hotkeys-v3.bin'))) 'PS/Python portable binary parity'
Check ([Text.Encoding]::ASCII.GetString($compiled.LibraryBytes,0,7) -ceq 'LPSKEY3') 'Version marker'
Check ([BitConverter]::ToUInt32($compiled.LibraryBytes,16) -eq (Get-LibraryChecksum ([byte[]]$compiled.LibraryBytes[20..81]))) 'Payload checksum'
foreach ($entry in @(@('original-to-portable.json','engine\assets\TenPallas.original.dll'),
    @('v2-to-portable.json','build\hotkeys-v2\TenPallas.hotkeys.experimental.dll'),
    @('portable-v3-to-fixed.json','build\portable-v3-c\TenPallas.portable.experimental.dll'))) {
    $reconstructed = Expand-PortableDelta ([IO.File]::ReadAllBytes((Join-Path $project $entry[1]))) (Join-Path $BuildDirectory $entry[0]) $script:PortableDeltaHashes[$entry[0]]
    Check ((Get-ShoutByteHash $reconstructed) -eq $script:PortableTargetHash) 'Exact reconstruction including shorter v2 target'
}
Reject { Expand-PortableDelta ([byte[]]@(1,2,3)) (Join-Path $BuildDirectory 'original-to-portable.json') $script:PortableDeltaHashes['original-to-portable.json'] }
$tampered = Join-Path $work 'tampered-patch.json'
[IO.File]::WriteAllBytes($tampered,$utf8.GetBytes('{}'))
Reject { Expand-PortableDelta ([byte[]]@(1,2,3)) $tampered $script:PortableDeltaHashes['original-to-portable.json'] }
$savedPath = Join-Path $work 'saved-source.json'
$saved = Save-HotkeyDocument $compiled.Scheme $savedPath $null -FormatVersion 3
Check ((Read-HotkeyDocument $savedPath -FormatVersion 3).Compiled.LibraryHash -eq $compiled.LibraryHash) 'Portable source save/read parity'
$edited = $text | ConvertFrom-Json; $edited.'0' = 'Edited local text'; $edited.bind0 = 'Ctrl+Shift+Q'
$changed = ConvertTo-HotkeyArtifacts ($edited | ConvertTo-Json) -FormatVersion 3
$beforeState = $null
function Assert-ShoutStopped { if ($script:Running) { throw 'Fixture running process guard' } }
function Get-AuthenticodeSignature { param([string]$LiteralPath) return [pscustomobject]@{ Status = $script:Signature } }
$script:Signature = 'Valid'; $script:Running = $false
$realWrite = ${function:Write-PortableFile}
function Write-PortableFile($Context, [byte[]]$Bytes, [string]$Path, $Before, [string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath -and (Get-ShoutByteHash $Bytes) -eq $script:FaultHash) {
        $script:FaultPath = $null; throw 'Fixture injected commit failure'
    }
    & $realWrite $Context $Bytes $Path $Before $ExpectedDll
}
function Reset-Fixture {
    $fixture = Join-Path $work ([guid]::NewGuid().ToString('N'))
    $chinese = [string][char]0x7528 + [char]0x6237
    $root = Join-Path $fixture ('Different drive layout\' + $chinese + ' WeGame space')
    $profile = Join-Path $fixture ('Profiles\' + $chinese + ' Alice\Local\LOLPallasPortable')
    New-Item -ItemType Directory -Path (Join-Path $root 'apps\Pallas\tp_deps'),$profile | Out-Null
    $dll = Join-Path $root 'apps\Pallas\tp_deps\TenPallas.dll'; $loader = Join-Path $root 'apps\Pallas\pallas.exe'
    [IO.File]::WriteAllBytes($dll,$utf8.GetBytes('fixture original')); [IO.File]::WriteAllBytes($loader,$utf8.GetBytes('fixture launcher'))
    $script:PortableOriginalHash = Get-ShoutFileHash $dll; $script:PortableLoaderHash = Get-ShoutFileHash $loader
    $script:CandidateBytes = $utf8.GetBytes('fixture portable candidate'); $script:PortableTargetHash = Get-ShoutByteHash $script:CandidateBytes
    $created = New-PortableContext $root $profile; $script:Signature = 'Valid'
    return $created
}
$context = Reset-Fixture
Check ((ConvertTo-PortableArgument 'D:\') -ceq '"D:\\"') 'Trailing slash Windows command quoting'
Reject { ConvertTo-PortableArgument 'bad"arg' }
Reject { Assert-PortablePath '\\server\share\WeGame' }
$link = Join-Path $work 'fixture-junction'
New-Item -ItemType Junction -Path $link -Target $context.Root | Out-Null
Reject { Assert-PortablePath (Join-Path $link 'apps\Pallas\tp_deps\TenPallas.dll') }
Check (Test-PortableRoot $context.Root) 'Custom install location detected'
Check ((Resolve-PortableRoot $context.Root $context.Data) -eq $context.Root) 'Chinese path and spaces'
Reject { Resolve-PortableRoot $work $context.Data }
$roots = @($context.Root)
function Get-PortableCandidateRoots { return $script:roots }
Check ((Resolve-PortableRoot '' $context.Data) -eq $context.Root) 'Unique automatic discovery'
$script:roots = @(); Reject { Resolve-PortableRoot '' $context.Data }
$second = Reset-Fixture; $script:roots = @($context.Root,$second.Root)
Reject { Resolve-PortableRoot '' $context.Data }
Reject { New-PortableContext $context.Root (Join-Path $work ('a' * 240)) }
$context = Reset-Fixture; $script:Signature = 'HashMismatch'; Reject { Install-PortableComponent $context $compiled $script:CandidateBytes }
Check (-not (Test-Path -LiteralPath $context.State)) 'Invalid original signature no state created'
$script:Signature = 'Valid'; $script:Running = $true; Reject { Install-PortableComponent $context $compiled $script:CandidateBytes }
Check (-not (Test-Path -LiteralPath $context.State)) 'Running guard no install writes'
$script:Running = $false
$loaderBefore = Get-ShoutFileHash $context.Loader
$record = Install-PortableComponent $context $compiled $script:CandidateBytes
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableTargetHash -and (Get-ShoutFileHash $context.Library) -eq $compiled.LibraryHash) 'DLL and library installation'
Check ((Get-ShoutFileHash $context.Loader) -eq $loaderBefore) 'Launcher never changed'
Check ((Get-ShoutFileHash $context.Source) -eq $record.installed_source_sha256) 'Recoverable applied source stored'
Check ((Read-PortableState $context).message_count -eq 3) 'Install state readback'
Check ((Resolve-PortableRoot '' $context.Data) -eq $context.Root) 'Installed root lookup survives package relocation'
Reject { Install-PortableComponent $context $compiled $script:CandidateBytes }
Apply-PortableMessages $context $changed
Check ((Get-ShoutFileHash $context.Library) -eq $changed.LibraryHash) 'Independent binding/text apply'
Check ((Read-HotkeyDocument $context.Source -FormatVersion 3).Compiled.LibraryHash -eq $changed.LibraryHash) 'Applied source matches binary'
$record = Read-PortableState $context
Restore-PortableComponent $context $record
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash -and (Get-ShoutFileHash $context.Library) -eq $changed.LibraryHash) 'Restore baseline; retain current local text'
Check ((Read-PortableState $context).status -eq 'restored') 'Restore state'
$record = Install-PortableComponent $context $compiled $script:CandidateBytes
Check ((Get-ShoutFileHash $context.Library) -eq $changed.LibraryHash) 'Reinstall cannot reset edits to package defaults'
Check ((Get-ShoutFileHash $context.Loader) -eq $loaderBefore) 'Launcher unchanged across restore/reinstall'
# Model the known superseded v3 with its own valid original restore baseline.
$script:PortablePreviousHash = Get-ShoutByteHash ($utf8.GetBytes('fixture previous portable'))
$old = Read-PortableState $context; $old.candidate_dll_sha256 = $script:PortablePreviousHash
[IO.File]::WriteAllBytes($context.Dll,$utf8.GetBytes('fixture previous portable')); Save-PortableState $context $old
Reject { Apply-PortableMessages $context $compiled }
$upgradeLibrary = Get-ShoutFileHash $context.Library; $upgradeSource = Get-ShoutFileHash $context.Source
$upgradeBaseline = $old.baseline_dll_sha256; $upgradeBackup = $old.backup_id
$upgraded = Install-PortableComponent $context $compiled $script:CandidateBytes
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableTargetHash) 'Upgrade installs fixed component'
Check ((Get-ShoutFileHash $context.Library) -eq $upgradeLibrary -and (Get-ShoutFileHash $context.Source) -eq $upgradeSource) 'Upgrade never replaces existing texts with defaults'
Check ($upgraded.baseline_dll_sha256 -eq $upgradeBaseline -and $upgraded.backup_id -eq $upgradeBackup) 'Upgrade retains original restore baseline'
Check ((Read-PortableState $context).repair_revision -eq 'input-loader-r1') 'Upgrade state readback'
$oldStateBytes = [IO.File]::ReadAllBytes($context.State)
$old = Read-PortableState $context; $old.candidate_dll_sha256 = $script:PortablePreviousHash
[IO.File]::WriteAllBytes($context.Dll,$utf8.GetBytes('fixture previous portable')); Save-PortableState $context $old
$script:FaultPath = $context.State
$failedUpdate = $old | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$failedUpdate.candidate_dll_sha256 = $script:PortableTargetHash
# State failure needs to ignore the timestamp hash; intercept this path once.
$script:FailUpgradeState = $true
$realSaveState = ${function:Save-PortableState}
function Save-PortableState($Context,$Record) {
    if ($script:FailUpgradeState -and $Record.candidate_dll_sha256 -eq $script:PortableTargetHash) {
        $script:FailUpgradeState = $false; throw 'Fixture upgrade state commit failure'
    }
    & $realSaveState $Context $Record
}
$script:FaultPath = $null
Reject { Install-PortableComponent $context $compiled $script:CandidateBytes }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortablePreviousHash -and (Read-PortableState $context).candidate_dll_sha256 -eq $script:PortablePreviousHash) 'Failed upgrade restores previous component and state'
Check ((Get-ShoutFileHash $context.Library) -eq $upgradeLibrary -and (Get-ShoutFileHash $context.Source) -eq $upgradeSource) 'Failed upgrade retains texts'
[void](Install-PortableComponent $context $compiled $script:CandidateBytes)
$script:FaultPath = $context.Source; $script:FaultHash = Get-ShoutByteHash (Get-PortableSourceBytes $compiled)
Reject { Apply-PortableMessages $context $compiled }
Check ((Get-ShoutFileHash $context.Library) -eq $changed.LibraryHash) 'Apply failure rolls back binary'
Check ((Read-PortableState $context).installed_library_sha256 -eq $changed.LibraryHash) 'Apply failure retains consistent state'
$script:Running = $true; Reject { Apply-PortableMessages $context $compiled }; Reject { Restore-PortableComponent $context (Read-PortableState $context) }
$script:Running = $false
$state = Read-PortableState $context
[IO.File]::WriteAllBytes($context.Source,$utf8.GetBytes('external edit'))
$externalHash = Get-ShoutFileHash $context.Source
Reject { Apply-PortableMessages $context $compiled }
Check ((Get-ShoutFileHash $context.Source) -eq $externalHash -and (Get-ShoutFileHash $context.Library) -eq $changed.LibraryHash) 'Concurrent text preflight before binary mutation'
[IO.File]::WriteAllBytes($context.State,$utf8.GetBytes('external state'))
Reject { Save-PortableState $context $state }
Check ([IO.File]::ReadAllText($context.State) -ceq 'external state') 'State CAS preserves external edits'
[IO.File]::WriteAllBytes($context.Dll,$utf8.GetBytes('updated DLL'))
Reject { Restore-PortableComponent $context $state }
Check ([IO.File]::ReadAllText($context.Dll) -ceq 'updated DLL') 'Unknown update never overwritten by restore'
$context = Reset-Fixture; $script:FaultPath = $context.Dll; $script:FaultHash = $script:PortableTargetHash
Reject { Install-PortableComponent $context $compiled $script:CandidateBytes }
Check ((Get-ShoutFileHash $context.Dll) -eq $script:PortableOriginalHash) 'Install failure preserves baseline'
Check ((Read-PortableState $context).status -eq 'restored') 'Install failure saved recoverable record'
Check ((Get-ShoutFileHash $context.Library) -eq $compiled.LibraryHash) 'Failed install retains drafted text, not deleted'
$state = Read-PortableState $context; $state.sid = 'S-1-5-foreign'; Save-PortableState $context $state
Reject { Read-PortableState $context }
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned stages'
Write-Host ('PASS: ' + $script:Checks + ' portable delta/discovery/source/installation/apply/restore fixture checks. ' + $work)
