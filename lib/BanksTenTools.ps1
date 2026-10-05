# Version/profile-pinned data and transitions. Import defines functions only.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Switch-Pallas-Banks80.ps1') -FunctionsOnly
$script:BanksTenHash='5407DFA6A92640B216F5FBA143A5BAF63EC68E46A108FC664356DF3A037BF3E2'
$script:BanksTenStatus='suspended-for-legacy-banks10-control'

function ConvertTo-BanksTenArtifacts($Scheme) {
    $names=@($Scheme.PSObject.Properties.Name)
    $expected=@('title','key')+@(0..79 | ForEach-Object { $_.ToString() })
    if ($names.Count -ne 82 -or @(Compare-Object $names $expected).Count -or
        ($Scheme.key -isnot [int] -and $Scheme.key -isnot [long]) -or $Scheme.key -notin @(1,2)) { throw 'Requires exactly eighty messages, title and key.' }
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    foreach ($name in @('title')+@(0..79 | ForEach-Object { $_.ToString() })) {
        $value=$Scheme.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -match '[\x00-\x1f\x7f]') { throw ('Nonempty text without control characters required: '+$name) }
        [void]$utf8.GetBytes($value)
    }
    $ordered=[ordered]@{}
    foreach ($i in 0..79) { $ordered[$i.ToString()]=$Scheme.($i.ToString()) }
    $ordered['title']=$Scheme.title; $ordered['key']=$Scheme.key
    $raw=$utf8.GetBytes(($ordered | ConvertTo-Json -Depth 4 -Compress))
    if ($raw.Length -gt 65536) { throw 'Whole UTF-8 JSON library exceeds 65536 bytes. No text was truncated.' }
    $preview=[ordered]@{_lps_local_v1=('{0:X8}:{1:X8}' -f $raw.Length,(Get-LibraryChecksum $raw))}
    foreach ($i in 0..19) {
        $preview[$i.ToString()]=''
        if ($i -lt 10) { $preview[$i.ToString()]=Get-BanksTenPreview $Scheme.($i.ToString()) }
    }
    $preview['title']=Get-BanksTenPreview $Scheme.title; $preview['key']=$Scheme.key
    $short=$utf8.GetBytes(($preview | ConvertTo-Json -Depth 4 -Compress))
    if ($short.Length -gt 2046) {
        foreach ($i in 0..9) { $preview[$i.ToString()]='' }
        $short=$utf8.GetBytes(($preview | ConvertTo-Json -Depth 4 -Compress))
    }
    if ($short.Length -gt 2046) { throw 'Native preview transport overflow.' }
    $response=$utf8.GetBytes(([ordered]@{result=[ordered]@{error_code=0};shout_message=[Convert]::ToBase64String($short)} | ConvertTo-Json -Depth 4 -Compress))
    return [pscustomobject]@{Scheme=$Scheme;Library=$raw;Response=$response;BootstrapBytes=$short.Length}
}
function Get-BanksTenPreview([string]$Text) {
    if ($Text.Length -le 32) { return $Text }
    $length=32
    if ([char]::IsHighSurrogate($Text[$length-1])) { $length-- }
    return $Text.Substring(0,$length)+[char]0x2026
}
function Read-BanksTenRecord($Context,[string]$LegacyRoot) {
    $path=Assert-PortablePath (Join-Path $Context.Data 'legacy-banks10-control.json')
    $hash=Get-ShoutFileHash $path
    $r=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($r.experiment -ne 'legacy-eight-ten-key-banks-no-character-cap-v1' -or $r.sid -ne $Context.Sid -or
        $r.root -ne $Context.Root -or $r.dll_path -ne $Context.Dll -or $r.loader_sha256 -ne $script:Working8KLoaderHash -or
        $r.baseline_dll_sha256 -ne $script:Banks80Hash -or $r.candidate_dll_sha256 -ne $script:BanksTenHash -or
        $r.message_count -ne 80 -or $r.bank_count -ne 8 -or $r.bank_size -ne 10 -or
        $null -ne $r.single_message_utf16_limit -or $r.capacity_bytes -ne 65536) { throw 'Foreign ten-key bank record.' }
    [void](Get-PortableRestoreBackup $Context $r.backup 'legacy-banks10-')
    $expected=@(@((Join-Path $LegacyRoot 'library20-v1.json'),'library80.before.json'),@((Join-Path $LegacyRoot 'local-response.json'),'response.before.json'),
        @($Context.Dll,'TenPallas.before.dll'),@($Context.State,'portable-state.before.json'),
        @((Join-Path $LegacyRoot 'LocalLibraryExperiment\state.json'),'library-state.before.json'),
        @((Join-Path $Context.Data 'legacy-banks80-control.json'),'banks80-control.before.json'))
    if ($r.changes.Count -ne 6) { throw 'Unknown ten-key restore layout.' }
    foreach ($i in 0..5) {
        $e=$r.changes[$i]
        if ($e.Path -ne $expected[$i][0] -or $e.BackupName -ne $expected[$i][1] -or
            $e.BeforeHash -notmatch '^[a-fA-F0-9]{64}$' -or $e.TargetHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Foreign restore target.' }
        Assert-ShoutHash (Join-Path $r.backup $e.BackupName) $e.BeforeHash
    }
    if ($r.changes[2].BeforeHash -ne $script:Banks80Hash -or $r.changes[2].TargetHash -ne $script:BanksTenHash) { throw 'Unknown restore component.' }
    Assert-ShoutHash $path $hash
    $bytes=[IO.File]::ReadAllBytes($path)
    if ((Get-ShoutByteHash $bytes) -ne $hash) { throw 'Journal changed during readback.' }
    return [pscustomobject]@{Record=$r;Path=$path;Hash=$hash;Bytes=$bytes}
}
function Get-BanksTenPreserved($Context,[string]$LegacyRoot) {
    $result=@()
    foreach ($item in @(@($Context.Loader,'pallas.unchanged.exe'),@($Context.Library,'modern-library.unchanged.bin'),
        @($Context.Source,'applied-messages.unchanged.json'),@((Join-Path $Context.Data 'Editor\messages.json'),'editor-draft.unchanged.json'),
        @((Join-Path $Context.Data 'Editor\settings.json'),'editor-settings.unchanged.json'),
        @((Join-Path $LegacyRoot 'LocalSchemeExperiment\state.json'),'loader-state.unchanged.json'),
        @((Join-Path $Context.Data 'legacy-capacity-control.json'),'capacity-control.unchanged.json'))) {
        $result+=New-Working8KEntry $item[0] ([IO.File]::ReadAllBytes($item[0])) $item[1]
    }
    return $result
}
function Assert-BanksTenPlan($Context,$Plan) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    Assert-ShoutHash $Context.Dll $Plan.ExpectedDll
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) { Assert-ShoutHash $e.Path $e.BeforeHash }
}
function New-BanksTenInstallPlan($Context,[string]$LegacyRoot,$Artifacts) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash; Assert-ShoutHash $Context.Dll $script:Banks80Hash
    if ((Get-ShoutByteHash $Artifacts.Dll) -ne $script:BanksTenHash) { throw 'Unknown ten-key DLL.' }
    $control=Assert-PortablePath (Join-Path $Context.Data 'legacy-banks10-control.json')
    if (Test-Path -LiteralPath $control) { throw 'Existing ten-key history retained; use Status/Restore.' }
    $saved=Read-Banks80Record $Context $LegacyRoot; $old=$saved.Record
    if ($old.status -ne 'installed-awaiting-game-test') { throw 'Requires current four-bank profile.' }
    foreach ($e in $old.changes) { Assert-ShoutHash $e.Path $e.TargetHash }
    $current=Get-Content -LiteralPath $old.changes[0].Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $compiled=ConvertTo-BanksTenArtifacts $current
    if ((Get-ShoutByteHash $compiled.Library) -ne (Get-ShoutByteHash $Artifacts.Library) -or
        (Get-ShoutByteHash $compiled.Response) -ne (Get-ShoutByteHash $Artifacts.Response)) { throw 'All eighty personal texts must be preserved.' }
    $modern=Read-PortableState $Context
    $legacy=Get-Content -LiteralPath $old.changes[4].Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($r in @($modern,$legacy)) {
        if ($r.status -ne $script:BanksSuspendedStatus -or $r.active_control_dll_sha256 -ne $script:Banks80Hash) { throw 'Inconsistent prior bank state.' }
    }
    $time=[DateTime]::UtcNow.ToString('o')
    $backup=Assert-PortablePath (Join-Path $Context.Data ('backups\legacy-banks10-'+[guid]::NewGuid().ToString('N')))
    foreach ($r in @($modern,$legacy)) {
        $r.status=$script:BanksTenStatus; $r.runtime_verified=$false; $r.game_send_verified=$false
        $r.active_control_dll_sha256=$script:BanksTenHash; $r.active_control_bank_count=8; $r.active_control_utf16_guard=$null
        foreach ($pair in @(@('active_control_bank_size',10),@('banks10_installed_at',$time),@('banks10_backup',$backup))) {
            $r | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
        foreach ($name in @('text_test_max_utf16','text_test_applied_at','text_test_backup')) { $r.PSObject.Properties.Remove($name) }
    }
    $legacy.installed_library_sha256=Get-ShoutByteHash $compiled.Library
    $legacy.installed_response_sha256=Get-ShoutByteHash $compiled.Response
    $old.status='suspended-for-banks10-control'
    $old | Add-Member -NotePropertyName banks10_backup -NotePropertyValue $backup -Force
    $entries=@((New-Working8KEntry $old.changes[0].Path $compiled.Library 'library80.before.json'),
        (New-Working8KEntry $old.changes[1].Path $compiled.Response 'response.before.json'),
        (New-Working8KEntry $Context.Dll $Artifacts.Dll 'TenPallas.before.dll'),
        (New-Working8KEntry $Context.State (Get-CapacityJsonBytes $modern) 'portable-state.before.json'),
        (New-Working8KEntry $old.changes[4].Path (Get-CapacityJsonBytes $legacy) 'library-state.before.json'),
        (New-Working8KEntry $saved.Path (Get-CapacityJsonBytes $old) 'banks80-control.before.json'))
    $indices=@(0,1,2,3,4)
    foreach ($i in $indices) { if ($entries[$i].BeforeHash -ne $saved.Record.changes[$i].TargetHash) { throw 'Prior file changed while planning.' } }
    if ($entries[5].BeforeHash -ne $saved.Hash) { throw 'Prior journal changed.' }
    $journal=[ordered]@{experiment='legacy-eight-ten-key-banks-no-character-cap-v1';status='installed-awaiting-game-test'
        sid=$Context.Sid;root=$Context.Root;dll_path=$Context.Dll;loader_sha256=$script:Working8KLoaderHash
        baseline_dll_sha256=$script:Banks80Hash;candidate_dll_sha256=$script:BanksTenHash;capacity_bytes=65536
        message_count=80;bank_count=8;bank_size=10;single_message_utf16_limit=$null;backup=$backup;installed_at=$time
        library_bytes=$compiled.Library.Length;bootstrap_bytes=$compiled.BootstrapBytes;game_send_verified=$false;runtime_verified=$false
        changes=@($entries | Select-Object Path,BeforeHash,TargetHash,BackupName)}
    return [pscustomobject]@{Entries=$entries;Preserved=@(Get-BanksTenPreserved $Context $LegacyRoot);Backup=$backup
        ControlPath=$control;JournalBytes=(Get-CapacityJsonBytes $journal);ExpectedDll=$script:Banks80Hash;LegacyRoot=$LegacyRoot}
}
function Invoke-BanksTenInstall($Context,$Plan) {
    Assert-BanksTenPlan $Context $Plan
    if (Test-Path -LiteralPath $Plan.ControlPath) { throw 'Ten-key journal appeared concurrently.' }
    [void](New-Item -ItemType Directory -Path $Plan.Backup)
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) { Backup-PortableFile $e.Path (Join-Path $Plan.Backup $e.BackupName) $e.BeforeHash }
    Assert-BanksTenPlan $Context $Plan
    $journalHash=Get-ShoutByteHash $Plan.JournalBytes
    try {
        $current=$script:Banks80Hash
        foreach ($e in $Plan.Entries) {
            foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
            Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash $current
            if ($e.Path -eq $Context.Dll) { $current=$script:BanksTenHash }
        }
        Write-PortableFile $Context $Plan.JournalBytes $Plan.ControlPath $null $script:BanksTenHash
        foreach ($e in $Plan.Entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
        [void](Read-BanksTenRecord $Context $Plan.LegacyRoot)
    } catch {
        $failure=$_.Exception.Message
        Undo-CapacityEntries $Context $Plan.Entries
        if ((Get-ShoutFileHash $Plan.ControlPath) -eq $journalHash) {
            $record=(New-Object Text.UTF8Encoding($false)).GetString($Plan.JournalBytes) | ConvertFrom-Json
            $record.status='rolled-back-to-four-banks'
            Write-PortableFile $Context (Get-CapacityJsonBytes $record) $Plan.ControlPath $journalHash $script:Banks80Hash
        }
        throw ('Ten-key install failed; previous four banks restored. Backup: '+$Plan.Backup+'. '+$failure)
    }
}
function New-BanksTenApplyPlan($Context,[string]$LegacyRoot,$Scheme) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash; Assert-ShoutHash $Context.Dll $script:BanksTenHash
    $saved=Read-BanksTenRecord $Context $LegacyRoot; $r=$saved.Record
    if ($r.status -ne 'installed-awaiting-game-test') { throw 'Ten-key profile not active.' }
    foreach ($e in $r.changes) { Assert-ShoutHash $e.Path $e.TargetHash }
    $compiled=ConvertTo-BanksTenArtifacts $Scheme
    $modern=Read-PortableState $Context
    $legacy=Get-Content -LiteralPath $r.changes[4].Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $time=[DateTime]::UtcNow.ToString('o')
    foreach ($state in @($modern,$legacy)) {
        if ($state.status -ne $script:BanksTenStatus -or $state.active_control_dll_sha256 -ne $script:BanksTenHash) { throw 'Inconsistent ten-key state.' }
        $state.runtime_verified=$false; $state.game_send_verified=$false
        $state | Add-Member -NotePropertyName text_test_applied_at -NotePropertyValue $time -Force
    }
    $legacy.installed_library_sha256=Get-ShoutByteHash $compiled.Library
    $legacy.installed_response_sha256=Get-ShoutByteHash $compiled.Response
    $entries=@((New-Working8KEntry $r.changes[0].Path $compiled.Library 'library80.before.json'),
        (New-Working8KEntry $r.changes[1].Path $compiled.Response 'response.before.json'),
        (New-Working8KEntry $Context.State (Get-CapacityJsonBytes $modern) 'portable-state.before.json'),
        (New-Working8KEntry $r.changes[4].Path (Get-CapacityJsonBytes $legacy) 'library-state.before.json'))
    $indices=@(0,1,3,4)
    foreach ($i in 0..3) {
        if ($entries[$i].BeforeHash -ne $r.changes[$indices[$i]].TargetHash) { throw 'Data changed during planning.' }
        $r.changes[$indices[$i]].TargetHash=$entries[$i].TargetHash
    }
    $r | Add-Member -NotePropertyName text_test_applied_at -NotePropertyValue $time -Force
    $r.library_bytes=$compiled.Library.Length; $r.bootstrap_bytes=$compiled.BootstrapBytes
    $r.runtime_verified=$false; $r.game_send_verified=$false
    $journal=New-Working8KEntry $saved.Path (Get-CapacityJsonBytes $r) 'banks10-control.before.json'
    if ($journal.BeforeHash -ne $saved.Hash) { throw 'Journal changed during planning.' }
    $entries+=,$journal
    $preserved=@(Get-BanksTenPreserved $Context $LegacyRoot)
    $preserved+=New-Working8KEntry $Context.Dll ([IO.File]::ReadAllBytes($Context.Dll)) 'TenPallas.unchanged.dll'
    $backup=Assert-PortablePath (Join-Path $r.backup ('text-'+[guid]::NewGuid().ToString('N')))
    return [pscustomobject]@{Entries=$entries;Preserved=$preserved;Backup=$backup;ExpectedDll=$script:BanksTenHash;LegacyRoot=$LegacyRoot}
}
function Invoke-BanksTenApply($Context,$Plan) {
    Assert-BanksTenPlan $Context $Plan
    [void](New-Item -ItemType Directory -Path $Plan.Backup)
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) { Backup-PortableFile $e.Path (Join-Path $Plan.Backup $e.BackupName) $e.BeforeHash }
    Assert-BanksTenPlan $Context $Plan
    try {
        foreach ($e in $Plan.Entries) { Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash $script:BanksTenHash }
        foreach ($e in $Plan.Entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
        [void](Read-BanksTenRecord $Context $Plan.LegacyRoot)
    } catch {
        $failure=$_.Exception.Message; Undo-CapacityEntries $Context $Plan.Entries
        throw ('Text apply failed; previous text state restored. Backup: '+$Plan.Backup+'. '+$failure)
    }
}
function Invoke-BanksTenRestore($Context,[string]$LegacyRoot) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Dll $script:BanksTenHash; Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    $saved=Read-BanksTenRecord $Context $LegacyRoot; $r=$saved.Record
    if ($r.status -ne 'installed-awaiting-game-test') { throw 'Ten-key profile not active.' }
    $entries=@()
    foreach ($e in $r.changes) {
        Assert-ShoutHash $e.Path $e.TargetHash
        $entries+=New-Working8KEntry $e.Path ([IO.File]::ReadAllBytes((Join-Path $r.backup $e.BackupName))) $e.BackupName
    }
    $archive=Assert-PortablePath (Join-Path $r.backup ('restore-'+[guid]::NewGuid().ToString('N')))
    [void](New-Item -ItemType Directory -Path $archive)
    foreach ($e in $entries) { Backup-PortableFile $e.Path (Join-Path $archive $e.BackupName) $e.BeforeHash }
    $restoredHash=$null
    try {
        $current=$script:BanksTenHash
        foreach ($e in $entries) {
            Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash $current
            if ($e.Path -eq $Context.Dll) { $current=$script:Banks80Hash }
        }
        foreach ($e in $entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        $r.status='restored-to-four-banks'
        $r | Add-Member -NotePropertyName active_files_before_restore -NotePropertyValue $archive -Force
        $bytes=Get-CapacityJsonBytes $r; $restoredHash=Get-ShoutByteHash $bytes
        Write-PortableFile $Context $bytes $saved.Path $saved.Hash $script:Banks80Hash
        [void](Read-Banks80Record $Context $LegacyRoot)
    } catch {
        $failure=$_.Exception.Message; Undo-CapacityEntries $Context $entries
        $current=Get-ShoutFileHash $saved.Path
        if ($current -ne $saved.Hash) {
            if ($current -ne $restoredHash) { throw 'Concurrent journal retained; inspect backups.' }
            Write-PortableFile $Context $saved.Bytes $saved.Path $current $script:BanksTenHash
        }
        throw ('Restore failed; ten-key state restored, archive retained: '+$archive+'. '+$failure)
    }
}
