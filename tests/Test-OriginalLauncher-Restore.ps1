# Isolated plaintext fixtures only; no Tencent binaries loaded or production writes.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'StockRestoreFixtures.ps1')
$script:Checks = 0
function Check($Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed 'Expected refusal' }
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $project ('build\original-loader-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$compiled = ConvertTo-HotkeyArtifacts ([IO.File]::ReadAllText((Join-Path $project 'portable\messages.example.json'),$utf8)) -FormatVersion 3
function Assert-ShoutStopped { if ($script:Running) { throw 'Fixture process running' } }
function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    return [pscustomobject]@{Status=$script:Signature;SignerCertificate=[pscustomobject]@{Subject='CN=Tencent Technology (Shenzhen) Company Limited'}}
}
$script:Signature = 'Valid'; $script:Running = $false
function New-Fixture {
    return New-StockRestoreFixture $work $compiled
}
$context = New-Fixture
$before = Read-PortableState $context; $beforeState = Get-ShoutFileHash $context.State; $beforeLegacy = Get-ShoutFileHash $script:LegacyPath
$beforeDll = Get-ShoutFileHash $context.Dll; $beforeLibrary = Get-ShoutFileHash $context.Library; $beforeSource = Get-ShoutFileHash $context.Source
$script:Running = $true; Reject { Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath }; $script:Running = $false
Check ((Get-ShoutFileHash $context.Loader) -eq $script:ModifiedLauncherHash) 'Running guard no writes'
$script:Signature = 'HashMismatch'; Reject { Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath }; $script:Signature = 'Valid'
Check ((Get-ShoutFileHash $context.State) -eq $beforeState) 'Signature failure preserves state'
$after = Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath
Check ((Get-ShoutFileHash $context.Loader) -eq $script:OriginalLauncherHash) 'Launcher readback'
Check ((Read-PortableState $context).status -eq 'original-components-restored') 'Portable state readback with original launcher'
Check ((Get-Content -LiteralPath $script:LegacyPath -Raw | ConvertFrom-Json).status -eq 'restored') 'Legacy state clearly restored'
Check ($after.backup_id -eq $before.backup_id -and $after.baseline_dll_sha256 -eq $before.baseline_dll_sha256) 'Initial restore baseline retained'
Check (-not $after.runtime_verified -and -not $after.game_send_verified) 'No game verification claimed'
Check ((Get-ShoutFileHash $context.Dll) -eq $beforeDll -and (Get-ShoutFileHash $context.Library) -eq $beforeLibrary -and (Get-ShoutFileHash $context.Source) -eq $beforeSource) 'DLL and texts retained'
Check ((Get-ShoutFileHash (Join-Path $after.original_launcher_restore_backup 'pallas.previous.exe')) -eq $script:ModifiedLauncherHash) 'Modified launcher backup'
Check ((Get-ShoutFileHash (Join-Path $after.original_launcher_restore_backup 'portable-state.previous.json')) -eq $beforeState -and (Get-ShoutFileHash (Join-Path $after.original_launcher_restore_backup 'local-scheme-state.previous.json')) -eq $beforeLegacy) 'Both state backups exact'
[void](Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath)
Reject { Apply-PortableMessages $context $compiled }
$context = New-Fixture; $beforeState = Get-ShoutFileHash $context.State; $beforeLegacy = Get-ShoutFileHash $script:LegacyPath
$realWrite = ${function:Write-PortableFile}; $script:FaultPath = $script:LegacyPath
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) { $script:FaultPath = $null; throw 'Fixture legacy-state commit failure' }
    & $realWrite $Context $Bytes $Path $Before $ExpectedDll
}
Reject { Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath }
Check ((Get-ShoutFileHash $context.Loader) -eq $script:ModifiedLauncherHash -and (Get-ShoutFileHash $context.State) -eq $beforeState -and (Get-ShoutFileHash $script:LegacyPath) -eq $beforeLegacy) 'Commit failure restores launcher and both states'
[IO.File]::WriteAllBytes($context.Loader,$utf8.GetBytes('fixture unknown launcher update'))
Reject { Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath }
Check ([IO.File]::ReadAllText($context.Loader) -eq 'fixture unknown launcher update') 'Unknown update not overwritten'
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$entry = Join-Path $project 'Restore-Pallas-OriginalLauncher.ps1'
$entryLoaderBefore = Get-ShoutFileHash $context.Loader
$entryOutput = (& $shell -NoProfile -ExecutionPolicy Bypass -File $entry -WeGameRoot $context.Root -ExpectedSid (Get-PortableSid) -WhatIf 2>&1 | Out-String)
Check ($LASTEXITCODE -eq 0) 'CLI WhatIf succeeds'
Check ($entryOutput -match [regex]::Escape($context.Loader)) 'CLI reaches ShouldProcess with explicit root; imports cannot swallow parameters'
Check ((Get-ShoutFileHash $context.Loader) -eq $entryLoaderBefore) 'CLI WhatIf does not write'
$entryOutput = (& $shell -NoProfile -ExecutionPolicy Bypass -File $entry -WeGameRoot $context.Root -ExpectedSid 'S-1-5-foreign-fixture' -WhatIf 2>&1 | Out-String)
Check ($LASTEXITCODE -eq 1 -and $entryOutput -match 'Elevation changed Windows accounts') 'CLI retains and enforces expected SID'
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned stages'
Write-Host ('PASS: ' + $script:Checks + ' original launcher restoration/backup/state/guard/rollback checks; own fixtures only.')
