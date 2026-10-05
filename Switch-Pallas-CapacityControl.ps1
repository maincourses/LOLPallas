# Profile-pinned DLL-only capacity experiment; no launcher/text writes or game IO.
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Status','Validate','Install','Restore')][string]$Mode='Status',
    [string]$WeGameRoot, [string]$ExpectedSid, [switch]$AcceptUnsignedExperiment,
    [switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
# Dot-sourced script parameters share scope; retain this command's own options.
$capacityCommandOptions=@{Mode=$Mode;Root=$WeGameRoot;Sid=$ExpectedSid;FunctionsOnly=$FunctionsOnly}
. (Join-Path $PSScriptRoot 'Switch-Pallas-KnownWorking8K.ps1') -FunctionsOnly
$Mode=$capacityCommandOptions.Mode; $WeGameRoot=$capacityCommandOptions.Root
$ExpectedSid=$capacityCommandOptions.Sid; $FunctionsOnly=$capacityCommandOptions.FunctionsOnly
$script:CapacityControlHash='60A14666E80B72A0C87807A89740D51E74E2B68074632E052513A91C7B313A28'
$script:CapacitySuspendedStatus='suspended-for-legacy-capacity64k-control'

function Get-CapacityJsonBytes($Value) {
    return ,((New-Object Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 9)))
}
function Get-CapacityCandidate([string]$Build) {
    [void](Assert-PortablePath $Build)
    $baseline=Join-Path $Build 'TenPallas.baseline8k.dll'
    $candidate=Join-Path $Build 'TenPallas.library.experimental.dll'
    Assert-ShoutHash $baseline $script:Working8KDllHash
    Assert-ShoutHash $candidate $script:CapacityControlHash
    $before=[IO.File]::ReadAllBytes($baseline); $after=[IO.File]::ReadAllBytes($candidate)
    if ($before.Length -ne $after.Length -or $after.Length -ne 1687080) { throw 'Unexpected candidate size.' }
    $allowed=@{1615584=@(0xDF,0xFF);1615585=@(0xFF,0xFE);1615589=@(0xE0,0x00)}
    foreach ($at in $allowed.Keys) {
        if ($before[$at] -ne $allowed[$at][0] -or $after[$at] -ne $allowed[$at][1]) { throw 'Capacity operands changed.' }
        $before[$at]=$after[$at]
    }
    if ((Get-ShoutByteHash $before) -ne $script:CapacityControlHash -or
        (Get-ShoutByteHash $after) -ne $script:CapacityControlHash) { throw 'Changes outside the three capacity bytes.' }
    $proof=Get-Content -LiteralPath (Join-Path $Build 'validation.capacity-control.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $native=Get-Content -LiteralPath (Join-Path $Build 'validation.library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($proof.candidate_dll_sha256 -ne $script:CapacityControlHash -or $proof.passed -ne $true -or
        $proof.unit_tests -ne 8 -or $proof.changed_byte_count -ne 3 -or
        $native.candidate_dll_sha256 -ne $script:CapacityControlHash -or $native.unit_tests_passed -ne $true -or
        $native.unit_tests -ne 7 -or $native.native.passed -ne $true -or $native.native.cases -ne 77 -or
        $native.native.capacity_boundary -ne 65536 -or $native.native_file_io.passed -ne $true -or
        $native.native_file_io.cases -ne 8 -or $native.baseline8k.child.passed -ne $true -or
        $native.baseline8k.child.capacity_boundary -ne 8192 -or $native.baseline8k.'real-io-child'.passed -ne $true) {
        throw 'Missing/mismatched capacity-only validation.'
    }
    if ((Get-AuthenticodeSignature -LiteralPath $candidate).Status.ToString() -ne 'HashMismatch') {
        throw 'Unexpected candidate signature result; no security/integrity bypass.'
    }
    return ,$after
}
function New-CapacityPlan($Context,[string]$LegacyRoot,[byte[]]$Candidate) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    Assert-ShoutHash $Context.Dll $script:Working8KDllHash
    if ((Get-ShoutByteHash $Candidate) -ne $script:CapacityControlHash) { throw 'Unknown capacity candidate.' }
    $control=Join-Path $Context.Data 'legacy-capacity-control.json'
    [void](Assert-PortablePath $control)
    if (Test-Path -LiteralPath $control) { throw 'Existing capacity history retained; inspect Status/Restore, do not overwrite.' }
    $record=Read-PortableState $Context
    if ($record.status -ne 'suspended-for-known-working-8k-control' -or
        $record.active_control_dll_sha256 -ne $script:Working8KDllHash -or $record.active_control_capacity_bytes -ne 8192) {
        throw 'Requires the currently active, consistent tested 8 KiB control.'
    }
    $modernBefore=$Context.StateHash
    Assert-ShoutHash $Context.Library $record.installed_library_sha256
    Assert-ShoutHash $Context.Source $record.installed_source_sha256
    $library=Join-Path $LegacyRoot 'library20-v1.json'; $response=Join-Path $LegacyRoot 'local-response.json'
    $legacyState=Join-Path $LegacyRoot 'LocalLibraryExperiment\state.json'
    $legacyBefore=Get-ShoutFileHash $legacyState
    $legacy=Get-Content -LiteralPath $legacyState -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($legacy.experiment -ne 'local-library-v1' -or $legacy.dll_path -ne $Context.Dll -or
        $legacy.library_path -ne $library -or $legacy.response_path -ne $response -or
        $legacy.candidate_dll_sha256 -ne $script:Working8KDllHash -or
        $legacy.status -ne 'installed-awaiting-manual-validation') { throw 'Unknown legacy library record.' }
    Assert-ShoutHash $library $legacy.installed_library_sha256
    Assert-ShoutHash $response $legacy.installed_response_sha256
    $compiled=ConvertTo-LibraryArtifacts (Get-Content -LiteralPath $library -Raw -Encoding UTF8)
    if ($compiled.LibraryHash -ne $legacy.installed_library_sha256 -or
        $compiled.ResponseHash -ne $legacy.installed_response_sha256) { throw 'Legacy JSON/bootstrap no longer match the working library.' }
    $backup=Assert-PortablePath (Join-Path $Context.Data ('backups\legacy-capacity64k-'+[guid]::NewGuid().ToString('N')))
    $time=[DateTime]::UtcNow.ToString('o')
    foreach ($r in @($record,$legacy)) {
        $r.status=$script:CapacitySuspendedStatus
        foreach ($pair in @(@('active_control_dll_sha256',$script:CapacityControlHash),
            @('active_control_capacity_bytes',65536),@('capacity_control_installed_at',$time),@('capacity_control_backup',$backup))) {
            $r | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
    }
    $entries=@((New-Working8KEntry $Context.Dll $Candidate 'TenPallas.working8k.dll'),
        (New-Working8KEntry $Context.State (Get-CapacityJsonBytes $record) 'portable-state.working8k.json'),
        (New-Working8KEntry $legacyState (Get-CapacityJsonBytes $legacy) 'library-state.working8k.json'))
    if ($entries[1].BeforeHash -ne $modernBefore -or $entries[2].BeforeHash -ne $legacyBefore) { throw 'State changed while planning.' }
    $preserved=@()
    foreach ($item in @(@($Context.Loader,'pallas.unchanged.exe'),@($library,'library20.unchanged.json'),
        @($response,'local-response.unchanged.json'),@($Context.Library,'modern-library.unchanged.bin'),
        @($Context.Source,'applied-messages.unchanged.json'),@((Join-Path $Context.Data 'Editor\messages.json'),'editor-draft.unchanged.json'),
        @((Join-Path $Context.Data 'Editor\settings.json'),'editor-settings.unchanged.json'),
        @((Join-Path $LegacyRoot 'LocalSchemeExperiment\state.json'),'loader-state.unchanged.json'))) {
        $preserved+=New-Working8KEntry $item[0] ([IO.File]::ReadAllBytes($item[0])) $item[1]
    }
    return [pscustomobject]@{Entries=$entries;Preserved=$preserved;Backup=$backup;ControlPath=$control
        LegacyRoot=$LegacyRoot;Time=$time;LibraryBytes=$compiled.LibraryBytes.Length;BootstrapBytes=$compiled.BootstrapBytes}
}
function Assert-CapacityPlan($Context,$Plan) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) { Assert-ShoutHash $e.Path $e.BeforeHash }
}
function Undo-CapacityEntries($Context,$Entries) {
    foreach ($e in $Entries) {
        if ((Get-ShoutFileHash $e.Path) -notin @($e.BeforeHash,$e.TargetHash)) {
            throw 'Unknown concurrent change; automatic rollback refused. All exact backups remain.'
        }
    }
    for ($i=$Entries.Count-1;$i -ge 0;$i--) {
        $e=$Entries[$i]; $current=Get-ShoutFileHash $e.Path
        if ($current -ne $e.BeforeHash) {
            Write-PortableFile $Context $e.BeforeBytes $e.Path $current (Get-ShoutFileHash $Context.Dll)
        }
    }
    foreach ($e in $Entries) { Assert-ShoutHash $e.Path $e.BeforeHash }
}
function Invoke-CapacityInstall($Context,$Plan) {
    Assert-CapacityPlan $Context $Plan
    if (Test-Path -LiteralPath $Plan.ControlPath) { throw 'Capacity state appeared concurrently; no writes.' }
    [void](New-Item -ItemType Directory -Path $Plan.Backup)
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) {
        Backup-PortableFile $e.Path (Join-Path $Plan.Backup $e.BackupName) $e.BeforeHash
    }
    $journal=[ordered]@{experiment='legacy-capacity-only-64k-control-v1';status='prepared';sid=$Context.Sid
        root=$Context.Root;dll_path=$Context.Dll;loader_sha256=$script:Working8KLoaderHash
        baseline_dll_sha256=$script:Working8KDllHash;candidate_dll_sha256=$script:CapacityControlHash
        capacity_bytes=65536;backup=$Plan.Backup;installed_at=$Plan.Time;game_send_verified=$false;runtime_verified=$false
        library_bytes=$Plan.LibraryBytes;bootstrap_bytes=$Plan.BootstrapBytes
        changes=@($Plan.Entries | Select-Object Path,BeforeHash,TargetHash,BackupName)
        preserved=@($Plan.Preserved | Select-Object Path,BeforeHash,BackupName)}
    $prepared=Get-CapacityJsonBytes $journal; $preparedHash=Get-ShoutByteHash $prepared
    $journalHash=$null; $finishedHash=$null
    try {
        Write-PortableFile $Context $prepared (Join-Path $Plan.Backup 'transition.prepared.json') $null $script:Working8KDllHash
        Write-PortableFile $Context $prepared $Plan.ControlPath $null $script:Working8KDllHash
        $journalHash=$preparedHash
        Assert-CapacityPlan $Context $Plan
        foreach ($e in $Plan.Entries) {
            foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
            Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash (Get-ShoutFileHash $Context.Dll)
        }
        foreach ($e in $Plan.Entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
        [void](Read-PortableState $Context)
        $journal.status='installed-awaiting-game-test'
        $bytes=Get-CapacityJsonBytes $journal; $finishedHash=Get-ShoutByteHash $bytes
        Write-PortableFile $Context $bytes $Plan.ControlPath $journalHash $script:CapacityControlHash
        Write-PortableFile $Context $bytes (Join-Path $Plan.Backup 'transition.installed.json') $null $script:CapacityControlHash
    } catch {
        $failure=$_.Exception.Message
        Undo-CapacityEntries $Context $Plan.Entries
        $current=Get-ShoutFileHash $Plan.ControlPath
        if ($current -and $current -in @($preparedHash,$finishedHash)) {
            $journal.status='rolled-back-to-working8k'; $journal['failure']=$failure
            Write-PortableFile $Context (Get-CapacityJsonBytes $journal) $Plan.ControlPath $current $script:Working8KDllHash
        }
        throw ('Capacity switch failed; exact 8 KiB DLL/states restored. Backups: '+$Plan.Backup+'. '+$failure)
    }
    return [pscustomobject]$journal
}
function Read-CapacityRecord($Context,[string]$LegacyRoot) {
    $path=Join-Path $Context.Data 'legacy-capacity-control.json'; [void](Assert-PortablePath $path)
    $hash=Get-ShoutFileHash $path
    $r=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($r.experiment -ne 'legacy-capacity-only-64k-control-v1' -or $r.sid -ne $Context.Sid -or
        $r.root -ne $Context.Root -or $r.dll_path -ne $Context.Dll -or $r.loader_sha256 -ne $script:Working8KLoaderHash -or
        $r.baseline_dll_sha256 -ne $script:Working8KDllHash -or $r.candidate_dll_sha256 -ne $script:CapacityControlHash -or
        $r.capacity_bytes -ne 65536) { throw 'Foreign/unknown capacity control state.' }
    [void](Get-PortableRestoreBackup $Context $r.backup 'legacy-capacity64k-')
    $expected=@(@($Context.Dll,'TenPallas.working8k.dll'),@($Context.State,'portable-state.working8k.json'),
        @((Join-Path $LegacyRoot 'LocalLibraryExperiment\state.json'),'library-state.working8k.json'))
    if ($r.changes.Count -ne 3) { throw 'Unknown capacity change list.' }
    foreach ($i in 0..2) {
        $e=$r.changes[$i]
        if ($e.Path -ne $expected[$i][0] -or $e.BackupName -ne $expected[$i][1] -or
            $e.BeforeHash -notmatch '^[a-fA-F0-9]{64}$' -or $e.TargetHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unknown capacity restore destination.' }
        Assert-ShoutHash (Join-Path $r.backup $e.BackupName) $e.BeforeHash
    }
    if ($r.changes[0].BeforeHash -ne $script:Working8KDllHash -or $r.changes[0].TargetHash -ne $script:CapacityControlHash) {
        throw 'Unknown capacity restore component.'
    }
    Assert-ShoutHash $path $hash
    $bytes=[IO.File]::ReadAllBytes($path)
    if ((Get-ShoutByteHash $bytes) -ne $hash) { throw 'Control state changed during readback.' }
    return [pscustomobject]@{Record=$r;Path=$path;Hash=$hash;Bytes=$bytes}
}
function Invoke-CapacityRestore($Context,[string]$LegacyRoot) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    $saved=Read-CapacityRecord $Context $LegacyRoot; $r=$saved.Record
    if ($r.status -ne 'installed-awaiting-game-test') { throw 'Capacity control is not active; no automatic replacement.' }
    $entries=@()
    foreach ($e in $r.changes) {
        Assert-ShoutHash $e.Path $e.TargetHash
        $entries+=New-Working8KEntry $e.Path ([IO.File]::ReadAllBytes((Join-Path $r.backup $e.BackupName))) $e.BackupName
    }
    $restoredHash=$null
    try {
        foreach ($e in $entries) { Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash (Get-ShoutFileHash $Context.Dll) }
        foreach ($e in $entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        [void](Read-PortableState $Context)
        $r.status='restored-to-working8k'; $r | Add-Member -NotePropertyName restored_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
        $bytes=Get-CapacityJsonBytes $r; $restoredHash=Get-ShoutByteHash $bytes
        Write-PortableFile $Context $bytes $saved.Path $saved.Hash $script:Working8KDllHash
    } catch {
        $failure=$_.Exception.Message
        Undo-CapacityEntries $Context $entries
        $current=Get-ShoutFileHash $saved.Path
        if ($current -ne $saved.Hash) {
            if ($current -ne $restoredHash) { throw ('Concurrent control-state change retained; review backups: '+$r.backup) }
            Write-PortableFile $Context $saved.Bytes $saved.Path $current $script:CapacityControlHash
        }
        throw ('Restore failed; previous capacity component/states retained. Backups: '+$r.backup+'. '+$failure)
    }
    return $r
}
if ($FunctionsOnly) { return }
$mutex=$null; $held=$false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Requires x64 Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Windows account changed; no changes.' }
    if ((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout') -ne $script:Working8KProfile) {
        throw 'Historical local library is pinned to this existing profile; not portable.'
    }
    $data=Get-PortableDataRoot
    $context=New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    if ($Mode -eq 'Status') {
        Write-Host ('DLL: '+(Get-ShoutFileHash $context.Dll))
        Write-Host ('Legacy launcher unchanged: '+((Get-ShoutFileHash $context.Loader) -eq $script:Working8KLoaderHash))
        if (Test-Path -LiteralPath (Join-Path $data 'legacy-capacity-control.json')) {
            $r=(Read-CapacityRecord $context $script:Working8KProfile).Record
            Write-Host ('Control: '+$r.status+'; backup: '+$r.backup)
            if ($r.status -eq 'installed-awaiting-game-test') {
                Write-Host ('Latest local game log: '+((Get-PortableRuntimeEvidence $context $r) | ConvertTo-Json -Compress))
            } else {
                Write-Host 'HISTORICAL/INACTIVE capacity control: its old log is not evidence for the currently loaded DLL. If bank control is active, use Switch-Pallas-Banks80.ps1 -Mode Status/Restore.'
            }
        }; exit 0
    }
    $mutexId=(Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex=New-Object Threading.Mutex($false,('Global\LOLPallasPortable-'+$mutexId))
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Another component operation is running.' }
    if ($Mode -eq 'Restore') {
        if ($PSCmdlet.ShouldProcess($context.Dll,'Restore exact game-tested 8 KiB DLL and management records; retain all texts/launcher/backups')) {
            [void](Invoke-CapacityRestore $context $script:Working8KProfile)
            Write-Host 'RESTORED AND READ BACK: exact working 8 KiB DLL; all text and launcher files untouched.'
        }; exit 0
    }
    $build=Join-Path $PSScriptRoot 'build\legacy-capacity64k-control-recheck-20261005'
    $plan=New-CapacityPlan $context $script:Working8KProfile (Get-CapacityCandidate $build)
    if ($Mode -eq 'Validate') { Assert-CapacityPlan $context $plan; Write-Host 'VALID: DLL-only capacity switch; no live writes.'; exit 0 }
    if (-not $AcceptUnsignedExperiment) { throw 'Explicit unsigned-experiment acceptance required; never bypass integrity/security.' }
    if ($PSCmdlet.ShouldProcess($context.Dll,'Back up working pair and all texts; change ONLY three capacity bytes in DLL plus management records')) {
        $r=Invoke-CapacityInstall $context $plan
        Write-Host ('INSTALLED AND READ BACK: capacity-only 64 KiB. Backup: '+$r.backup)
        Write-Host ('Existing texts: '+$r.library_bytes+' bytes; bootstrap: '+$r.bootstrap_bytes+' bytes; unchanged legacy loader/JSON/twenty keys.')
        Write-Host 'No game launched or message sent. Runtime/game sending is unverified; test 1 and 20 in training mode.'
    }; exit 0
} catch { Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
