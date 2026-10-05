# Pinned LOCAL experiment installer/restore; no game launch/input or DLL load.
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Status','Validate','Install','Restore')][string]$Mode='Status',
    [string]$WeGameRoot,[string]$ExpectedSid,[switch]$AcceptUnsignedExperiment,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
$bankOptions=@{Mode=$Mode;Root=$WeGameRoot;Sid=$ExpectedSid;FunctionsOnly=$FunctionsOnly;Accept=$AcceptUnsignedExperiment}
. (Join-Path $PSScriptRoot 'Switch-Pallas-CapacityControl.ps1') -FunctionsOnly
$Mode=$bankOptions.Mode; $WeGameRoot=$bankOptions.Root; $ExpectedSid=$bankOptions.Sid; $FunctionsOnly=$bankOptions.FunctionsOnly
$AcceptUnsignedExperiment=$bankOptions.Accept
$script:Banks80Hash='F261F5E75DC8DBF88D1EEAFE2D6B2DDF4F241803309C20100E50A08097177119'
$script:BanksSuspendedStatus='suspended-for-legacy-banks80-control'

function Get-Banks80Artifacts([string]$Build,[string]$Seed) {
    [void](Assert-PortablePath $Build); [void](Assert-PortablePath $Seed)
    $dll=Join-Path $Build 'TenPallas.banks80.experimental.dll'
    Assert-ShoutHash $dll $script:Banks80Hash
    $result=& 'D:\anaconda\python.exe' (Join-Path $PSScriptRoot 'tools\native\ValidateBanks80Install.py') --build $Build --seed-library $Seed
    if ($LASTEXITCODE -ne 0) { throw 'Read-only candidate validation failed; nothing installed.' }
    $proof=$result | ConvertFrom-Json
    if ($proof.passed -ne $true -or $proof.candidate_dll_sha256 -ne $script:Banks80Hash) { throw 'Unknown bank proof.' }
    if ((Get-AuthenticodeSignature -LiteralPath $dll).Status.ToString() -ne 'HashMismatch') {
        throw 'Unexpected signature status; no loader/integrity bypass.'
    }
    $dllBytes=[IO.File]::ReadAllBytes($dll)
    $libraryBytes=[IO.File]::ReadAllBytes((Join-Path $Build 'library80.json'))
    $responseBytes=[IO.File]::ReadAllBytes((Join-Path $Build 'local-response80.json'))
    if ((Get-ShoutByteHash $dllBytes) -ne $script:Banks80Hash -or
        (Get-ShoutByteHash $libraryBytes) -ne $proof.library_sha256 -or
        (Get-ShoutByteHash $responseBytes) -ne $proof.response_sha256) { throw 'Artifact changed after validation.' }
    return [pscustomobject]@{Dll=$dllBytes;Library=$libraryBytes;Response=$responseBytes;Proof=$proof}
}
function New-Banks80Plan($Context,[string]$LegacyRoot,$Artifacts) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    Assert-ShoutHash $Context.Dll $script:CapacityControlHash
    if ((Get-ShoutByteHash $Artifacts.Dll) -ne $script:Banks80Hash) { throw 'Unknown bank DLL.' }
    $control=Join-Path $Context.Data 'legacy-banks80-control.json'
    [void](Assert-PortablePath $control)
    if (Test-Path -LiteralPath $control) { throw 'Existing bank history retained; inspect Status/Restore first.' }
    $capacity=Read-CapacityRecord $Context $LegacyRoot
    if ($capacity.Record.status -ne 'installed-awaiting-game-test') { throw 'Working capacity control is not active.' }
    $record=Read-PortableState $Context; $modernBefore=$Context.StateHash
    $library=Join-Path $LegacyRoot 'library20-v1.json'; $response=Join-Path $LegacyRoot 'local-response.json'
    $legacyState=Join-Path $LegacyRoot 'LocalLibraryExperiment\state.json'
    $legacyBefore=Get-ShoutFileHash $legacyState
    $legacy=Get-Content -LiteralPath $legacyState -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($r in @($record,$legacy)) {
        if ($r.status -ne $script:CapacitySuspendedStatus -or $r.active_control_dll_sha256 -ne $script:CapacityControlHash -or
            $r.active_control_capacity_bytes -ne 65536) { throw 'Requires the consistent working capacity-only control.' }
    }
    if ($legacy.experiment -ne 'local-library-v1' -or $legacy.dll_path -ne $Context.Dll -or
        $legacy.library_path -ne $library -or $legacy.response_path -ne $response) { throw 'Foreign legacy record.' }
    Assert-ShoutHash $Context.Library $record.installed_library_sha256
    Assert-ShoutHash $Context.Source $record.installed_source_sha256
    Assert-ShoutHash $library $Artifacts.Proof.seed_library_sha256
    Assert-ShoutHash $library $legacy.installed_library_sha256
    Assert-ShoutHash $response $legacy.installed_response_sha256
    $libraryBefore=$legacy.installed_library_sha256; $responseBefore=$legacy.installed_response_sha256
    $old=ConvertTo-LibraryArtifacts (Get-Content -LiteralPath $library -Raw -Encoding UTF8)
    if ($old.LibraryHash -ne $legacy.installed_library_sha256 -or $old.ResponseHash -ne $legacy.installed_response_sha256) {
        throw 'Working JSON/bootstrap no longer match; existing texts retained.'
    }
    $backup=Assert-PortablePath (Join-Path $Context.Data ('backups\legacy-banks80-'+[guid]::NewGuid().ToString('N')))
    $time=[DateTime]::UtcNow.ToString('o')
    foreach ($r in @($record,$legacy)) {
        $r.status=$script:BanksSuspendedStatus
        $r.runtime_verified=$false; $r.game_send_verified=$false
        foreach ($pair in @(@('active_control_dll_sha256',$script:Banks80Hash),@('active_control_capacity_bytes',65536),
            @('bank_control_installed_at',$time),@('bank_control_backup',$backup),@('active_control_message_count',80),
            @('active_control_bank_count',4),@('active_control_utf16_guard',100))) {
            $r | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
    }
    $legacy.installed_library_sha256=$Artifacts.Proof.library_sha256
    $legacy.installed_response_sha256=$Artifacts.Proof.response_sha256
    $legacy.runtime_verified=$false; $legacy.game_send_verified=$false
    $capacity.Record.status='suspended-for-banks80-control'
    $capacity.Record | Add-Member -NotePropertyName bank_control_backup -NotePropertyValue $backup -Force
    $entries=@(
        (New-Working8KEntry $library $Artifacts.Library 'library20.working64k.json'),
        (New-Working8KEntry $response $Artifacts.Response 'local-response.working64k.json'),
        (New-Working8KEntry $Context.Dll $Artifacts.Dll 'TenPallas.working64k.dll'),
        (New-Working8KEntry $Context.State (Get-CapacityJsonBytes $record) 'portable-state.working64k.json'),
        (New-Working8KEntry $legacyState (Get-CapacityJsonBytes $legacy) 'library-state.working64k.json'),
        (New-Working8KEntry $capacity.Path (Get-CapacityJsonBytes $capacity.Record) 'capacity-control.working64k.json'))
    if ($entries[0].BeforeHash -ne $libraryBefore -or $entries[1].BeforeHash -ne $responseBefore -or
        $entries[2].BeforeHash -ne $script:CapacityControlHash -or
        $entries[3].BeforeHash -ne $modernBefore -or $entries[4].BeforeHash -ne $legacyBefore -or
        $entries[5].BeforeHash -ne $capacity.Hash) { throw 'Installation records changed while planning.' }
    $preserved=@()
    foreach ($item in @(@($Context.Loader,'pallas.unchanged.exe'),@($Context.Library,'modern-library.unchanged.bin'),
        @($Context.Source,'applied-messages.unchanged.json'),@((Join-Path $Context.Data 'Editor\messages.json'),'editor-draft.unchanged.json'),
        @((Join-Path $Context.Data 'Editor\settings.json'),'editor-settings.unchanged.json'),
        @((Join-Path $LegacyRoot 'LocalSchemeExperiment\state.json'),'loader-state.unchanged.json'))) {
        $preserved+=New-Working8KEntry $item[0] ([IO.File]::ReadAllBytes($item[0])) $item[1]
    }
    if ($preserved[0].BeforeHash -ne $script:Working8KLoaderHash -or
        $preserved[1].BeforeHash -ne $record.installed_library_sha256 -or
        $preserved[2].BeforeHash -ne $record.installed_source_sha256) { throw 'Preserved component/source changed while planning.' }
    return [pscustomobject]@{Entries=$entries;Preserved=$preserved;Backup=$backup;ControlPath=$control;Time=$time
        LegacyRoot=$LegacyRoot;LibraryBytes=$Artifacts.Library.Length;BootstrapBytes=$Artifacts.Proof.bootstrap_bytes}
}
function Assert-Banks80Plan($Context,$Plan) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) { Assert-ShoutHash $e.Path $e.BeforeHash }
}
function Invoke-Banks80Install($Context,$Plan) {
    Assert-Banks80Plan $Context $Plan
    if (Test-Path -LiteralPath $Plan.ControlPath) { throw 'Bank journal appeared concurrently; no writes.' }
    [void](New-Item -ItemType Directory -Path $Plan.Backup)
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) {
        Backup-PortableFile $e.Path (Join-Path $Plan.Backup $e.BackupName) $e.BeforeHash
    }
    $journal=[ordered]@{experiment='legacy-banks80-control-v1';status='prepared';sid=$Context.Sid;root=$Context.Root
        dll_path=$Context.Dll;loader_sha256=$script:Working8KLoaderHash;baseline_dll_sha256=$script:CapacityControlHash
        candidate_dll_sha256=$script:Banks80Hash;capacity_bytes=65536;message_count=80;bank_count=4;utf16_guard=100
        backup=$Plan.Backup;installed_at=$Plan.Time;library_bytes=$Plan.LibraryBytes;bootstrap_bytes=$Plan.BootstrapBytes
        game_send_verified=$false;runtime_verified=$false;panel_bank_display_updated=$false
        changes=@($Plan.Entries | Select-Object Path,BeforeHash,TargetHash,BackupName)
        preserved=@($Plan.Preserved | Select-Object Path,BeforeHash,BackupName)}
    $prepared=Get-CapacityJsonBytes $journal; $preparedHash=Get-ShoutByteHash $prepared
    $finishedHash=$null
    try {
        Write-PortableFile $Context $prepared (Join-Path $Plan.Backup 'transition.prepared.json') $null $script:CapacityControlHash
        Write-PortableFile $Context $prepared $Plan.ControlPath $null $script:CapacityControlHash
        Assert-Banks80Plan $Context $Plan
        $currentDll=$script:CapacityControlHash
        foreach ($e in $Plan.Entries) {
            foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
            Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash $currentDll
            if ($e.Path -eq $Context.Dll) { $currentDll=$e.TargetHash }
        }
        foreach ($e in $Plan.Entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
        [void](Read-PortableState $Context)
        $journal.status='installed-awaiting-game-test'
        $bytes=Get-CapacityJsonBytes $journal; $finishedHash=Get-ShoutByteHash $bytes
        Write-PortableFile $Context $bytes $Plan.ControlPath $preparedHash $script:Banks80Hash
        Write-PortableFile $Context $bytes (Join-Path $Plan.Backup 'transition.installed.json') $null $script:Banks80Hash
    } catch {
        $failure=$_.Exception.Message
        Undo-CapacityEntries $Context $Plan.Entries
        $current=Get-ShoutFileHash $Plan.ControlPath
        if ($current -and $current -in @($preparedHash,$finishedHash)) {
            $journal.status='rolled-back-to-working64k'; $journal['failure']=$failure
            Write-PortableFile $Context (Get-CapacityJsonBytes $journal) $Plan.ControlPath $current $script:CapacityControlHash
        }
        throw ('Bank installation failed; exact working64k files restored. Backups: '+$Plan.Backup+'. '+$failure)
    }
    return [pscustomobject]$journal
}
function Read-Banks80Record($Context,[string]$LegacyRoot) {
    $path=Assert-PortablePath (Join-Path $Context.Data 'legacy-banks80-control.json')
    $hash=Get-ShoutFileHash $path; $bytes=[IO.File]::ReadAllBytes($path)
    $r=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($r.experiment -ne 'legacy-banks80-control-v1' -or $r.sid -ne $Context.Sid -or $r.root -ne $Context.Root -or
        $r.dll_path -ne $Context.Dll -or $r.loader_sha256 -ne $script:Working8KLoaderHash -or
        $r.baseline_dll_sha256 -ne $script:CapacityControlHash -or $r.candidate_dll_sha256 -ne $script:Banks80Hash -or
        $r.message_count -ne 80 -or $r.bank_count -ne 4 -or $r.utf16_guard -ne 100 -or $r.capacity_bytes -ne 65536) {
        throw 'Foreign/unknown bank installation record.'
    }
    [void](Get-PortableRestoreBackup $Context $r.backup 'legacy-banks80-')
    $expected=@(@((Join-Path $LegacyRoot 'library20-v1.json'),'library20.working64k.json'),
        @((Join-Path $LegacyRoot 'local-response.json'),'local-response.working64k.json'),@($Context.Dll,'TenPallas.working64k.dll'),
        @($Context.State,'portable-state.working64k.json'),@((Join-Path $LegacyRoot 'LocalLibraryExperiment\state.json'),'library-state.working64k.json'),
        @((Join-Path $Context.Data 'legacy-capacity-control.json'),'capacity-control.working64k.json'))
    if ($r.changes.Count -ne 6) { throw 'Unknown bank restore layout.' }
    foreach ($i in 0..5) {
        $e=$r.changes[$i]
        if ($e.Path -ne $expected[$i][0] -or $e.BackupName -ne $expected[$i][1] -or
            $e.BeforeHash -notmatch '^[a-fA-F0-9]{64}$' -or $e.TargetHash -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Unknown restore destination or bytes.'
        }
        Assert-ShoutHash (Join-Path $r.backup $e.BackupName) $e.BeforeHash
    }
    if ($r.changes[2].BeforeHash -ne $script:CapacityControlHash -or $r.changes[2].TargetHash -ne $script:Banks80Hash) {
        throw 'Unrecognized restore component.'
    }
    Assert-ShoutHash $path $hash
    if ((Get-ShoutByteHash $bytes) -ne $hash) { throw 'Bank record changed while reading.' }
    return [pscustomobject]@{Record=$r;Path=$path;Hash=$hash;Bytes=$bytes}
}
function Invoke-Banks80Restore($Context,[string]$LegacyRoot) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    $saved=Read-Banks80Record $Context $LegacyRoot; $r=$saved.Record
    if ($r.status -ne 'installed-awaiting-game-test') { throw 'Bank control is not active; no replacement.' }
    $entries=@()
    foreach ($e in $r.changes) {
        Assert-ShoutHash $e.Path $e.TargetHash
        $entry=New-Working8KEntry $e.Path ([IO.File]::ReadAllBytes((Join-Path $r.backup $e.BackupName))) $e.BackupName
        if ($entry.BeforeHash -ne $e.TargetHash) { throw 'Active file changed during restore planning.' }
        $entries+=$entry
    }
    # Keep the active eighty texts and records too; never discard newer libraries.
    $archive=Assert-PortablePath (Join-Path $r.backup ('restore-'+[guid]::NewGuid().ToString('N')))
    [void](New-Item -ItemType Directory -Path $archive)
    foreach ($e in $entries) { Backup-PortableFile $e.Path (Join-Path $archive $e.BackupName) $e.BeforeHash }
    foreach ($e in $entries) { Assert-ShoutHash $e.Path $e.BeforeHash }
    $restoredHash=$null
    try {
        $currentDll=$script:Banks80Hash
        foreach ($e in $entries) {
            Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash $currentDll
            if ($e.Path -eq $Context.Dll) { $currentDll=$e.TargetHash }
        }
        foreach ($e in $entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        [void](Read-PortableState $Context)
        $r.status='restored-to-working64k'
        $r | Add-Member -NotePropertyName restored_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $r | Add-Member -NotePropertyName active_files_before_restore -NotePropertyValue $archive -Force
        $bytes=Get-CapacityJsonBytes $r; $restoredHash=Get-ShoutByteHash $bytes
        Write-PortableFile $Context $bytes $saved.Path $saved.Hash $script:CapacityControlHash
    } catch {
        $failure=$_.Exception.Message
        Undo-CapacityEntries $Context $entries
        $current=Get-ShoutFileHash $saved.Path
        if ($current -ne $saved.Hash) {
            if ($current -ne $restoredHash) { throw ('Concurrent bank journal retained; inspect backups: '+$r.backup) }
            Write-PortableFile $Context $saved.Bytes $saved.Path $current $script:Banks80Hash
        }
        throw ('Restore failed; active bank files restored, archive retained: '+$archive+'. '+$failure)
    }
    return $r
}
if ($FunctionsOnly) { return }
$mutex=$null; $held=$false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Requires x64 Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Windows account changed; no writes.' }
    if ((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout') -ne $script:Working8KProfile) {
        throw 'Candidate reader is pinned to the existing local profile; not portable.'
    }
    $data=Get-PortableDataRoot
    $context=New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    if ($Mode -eq 'Status') {
        $r=(Read-Banks80Record $context $script:Working8KProfile).Record
        Write-Host ('Control: '+$r.status+'; backup: '+$r.backup)
        Write-Host ('DLL matching bank candidate: '+((Get-ShoutFileHash $context.Dll) -eq $script:Banks80Hash))
        Write-Host ('Legacy loader unchanged: '+((Get-ShoutFileHash $context.Loader) -eq $script:Working8KLoaderHash))
        foreach ($e in $r.changes) { Write-Host ('File matching target: '+((Get-ShoutFileHash $e.Path) -eq $e.TargetHash)+'; '+$e.Path) }
        if ($r.text_test_max_utf16) { Write-Host ('DATA-ONLY length test: '+$r.text_test_max_utf16+' UTF-16 units; DLL/native guard unchanged at '+$r.utf16_guard+'. Backup: '+$r.text_test_backup) }
        if ($r.status -eq 'installed-awaiting-game-test') {
            Write-Host ('Latest local game log: '+((Get-PortableRuntimeEvidence $context $r) | ConvertTo-Json -Compress))
        } else { Write-Host 'HISTORICAL/INACTIVE four-bank record: old session logs do not verify current components. For eight ten-key groups use Manage-Pallas-BanksTen.ps1 -Mode Status.' }
        Write-Host 'Panel preview is FIRST BANK only. No visible group indicator. Game sending remains unverified.'
        exit 0
    }
    $mutexId=(Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex=New-Object Threading.Mutex($false,('Global\LOLPallasPortable-'+$mutexId))
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Another component operation is running.' }
    if ($Mode -eq 'Restore') {
        if ($PSCmdlet.ShouldProcess($context.Dll,'Restore exact working64k twenty-key files; keep all texts and backups')) {
            [void](Invoke-Banks80Restore $context $script:Working8KProfile)
            Write-Host 'RESTORED AND READ BACK: exact working64k twenty-message pair and JSON. Eighty-message library archived.'
        }; exit 0
    }
    $build=Join-Path $PSScriptRoot 'build\legacy-banks80-chinese100-final-20261005'
    $seed=Join-Path $script:Working8KProfile 'library20-v1.json'
    $plan=New-Banks80Plan $context $script:Working8KProfile (Get-Banks80Artifacts $build $seed)
    if ($Mode -eq 'Validate') { Assert-Banks80Plan $context $plan; Write-Host 'VALID: candidate, working64k, personal seed and rollback plan; no writes.'; exit 0 }
    if (-not $AcceptUnsignedExperiment) { throw 'Explicit unsigned-experiment acceptance required; never bypass security/integrity.' }
    if ($PSCmdlet.ShouldProcess($context.Dll,'Backup successful pair and all texts; install eighty Chinese messages with four native-key banks')) {
        $r=Invoke-Banks80Install $context $plan
        Write-Host ('INSTALLED AND READ BACK: four banks / eighty messages / 100 UTF-16 units. Backup: '+$r.backup)
        Write-Host 'Legacy launcher untouched. No game launched or message sent. Training-mode test still required.'
        Write-Host 'Panel preview remains first bank. Hold panel key + PageUp/PageDown to change bank, then digit/F1..F10.'
    }; exit 0
} catch { Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
