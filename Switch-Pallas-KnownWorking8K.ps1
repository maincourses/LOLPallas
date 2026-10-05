# This machine/profile-specific control restores an EXISTING tested pair.
# It does not build a new binary, load DLLs, launch games or send messages.
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Status','Validate','Switch')][string]$Mode='Status',
    [string]$WeGameRoot, [string]$ExpectedSid, [switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\PortableTools.ps1')
. (Join-Path $PSScriptRoot 'lib\LibraryTools.ps1')
$script:Working8KDllHash='BEB422999A6E8E7F87D93937D9010B15DCAAACCE237FD7B11C280D5CF88CCA10'
$script:Working8KLoaderHash=$script:PortableV2LoaderHash
$script:Working8KTwentyHash='3BCEFF093D67F86400DD0F3F1ECE50F812D531926D5FF64CF72C227904DA5D00'
$script:Working8KProfile='C:\Users\zly\AppData\Local\PallasCustomShout'

function ConvertTo-Working8K($Document) {
    if ($Document.Scheme.count -ne 20) { throw 'The tested baseline requires EXACTLY twenty messages. Nothing will be dropped.' }
    $scheme=[ordered]@{title=$Document.Scheme.title;key=1}
    foreach ($i in 0..19) {
        $key=($i+1).ToString(); if ($i -eq 9) { $key='0' }
        if ($i -ge 10) { $key='F'+($i-9) }
        if ($Document.Scheme.('bind'+$i) -ne ('~+'+$key)) {
            throw ('Binding '+($i+1)+' is not supported by the tested fixed-key version; no silent remapping.')
        }
        $scheme[$i.ToString()]=$Document.Scheme.($i.ToString())
    }
    return ConvertTo-LibraryArtifacts ($scheme | ConvertTo-Json -Depth 4)
}
function New-Working8KEntry([string]$Path,[byte[]]$Bytes,[string]$Name) {
    [void](Assert-PortablePath $Path)
    $before=Get-ShoutFileHash $Path
    if (-not $before) { throw ('Required existing file missing: '+$Path) }
    $saved=[IO.File]::ReadAllBytes($Path)
    if ((Get-ShoutByteHash $saved) -ne $before) { throw 'A file changed while being read.' }
    return [pscustomobject]@{Path=$Path;BeforeHash=$before;BeforeBytes=$saved
        TargetHash=(Get-ShoutByteHash $Bytes);TargetBytes=$Bytes;BackupName=$Name}
}
function New-Working8KPlan($Context,[string]$LegacyRoot,[string]$DllSource,[string]$LoaderSource) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Dll $script:PortableTargetHash
    Assert-ShoutHash $Context.Loader $script:PortableLoaderHash
    $record=Read-PortableState $Context
    if ($record.status -ne 'installed-awaiting-game-test') { throw 'Only the current, consistent failed compatibility control can be switched.' }
    Assert-ShoutHash $Context.Library $record.installed_library_sha256
    Assert-ShoutHash $Context.Source $record.installed_source_sha256
    foreach ($path in @($DllSource,$LoaderSource,$LegacyRoot)) { [void](Assert-PortablePath $path) }
    Assert-ShoutHash $DllSource $script:Working8KDllHash
    Assert-ShoutHash $LoaderSource $script:Working8KLoaderHash
    $document=Read-HotkeyDocument $Context.Source -FormatVersion 3
    $compiled=ConvertTo-Working8K $document.Compiled
    Assert-ShoutHash $Context.Source $document.Hash
    $loaderState=Join-Path $LegacyRoot 'LocalSchemeExperiment\state.json'
    $libraryState=Join-Path $LegacyRoot 'LocalLibraryExperiment\state.json'
    $response=Join-Path $LegacyRoot 'local-response.json'
    $library=Join-Path $LegacyRoot 'library20-v1.json'
    $loaderStateBefore=Get-ShoutFileHash $loaderState
    $libraryStateBefore=Get-ShoutFileHash $libraryState
    $localLoader=Get-Content -LiteralPath $loaderState -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($localLoader.experiment -ne 'Pallas local-file scheme v1' -or $localLoader.status -ne 'restored' -or
        $localLoader.program_path -ne $Context.Loader -or $localLoader.response_path -ne $response -or
        $localLoader.original_sha256 -ne $script:PortableLoaderHash -or $localLoader.candidate_sha256 -ne $script:Working8KLoaderHash) {
        throw 'Existing local-loader history does not match the pinned pair.'
    }
    Assert-ShoutHash $localLoader.backup_path $script:PortableLoaderHash
    $localLibrary=Get-Content -LiteralPath $libraryState -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($localLibrary.experiment -ne 'local-library-v1' -or $localLibrary.dll_path -ne $Context.Dll -or
        $localLibrary.response_path -ne $response -or $localLibrary.library_path -ne $library -or
        $localLibrary.candidate_dll_sha256 -ne $script:Working8KDllHash -or
        $localLibrary.baseline_dll_sha256 -ne $script:Working8KTwentyHash) {
        throw 'Existing 8 KiB history does not match the pinned pair.'
    }
    Assert-ShoutHash (Join-Path $LegacyRoot 'LocalLibraryExperiment\TenPallas.before-library.dll') $localLibrary.baseline_dll_sha256
    Assert-ShoutHash (Join-Path $LegacyRoot 'LocalLibraryExperiment\response.before-library.json') $localLibrary.previous_response_sha256
    $backup=Assert-PortablePath (Join-Path $Context.Data ('backups\known-working-8k-'+[guid]::NewGuid().ToString('N')))
    $time=[DateTime]::UtcNow.ToString('o')
    $record.status='suspended-for-known-working-8k-control'
    $record.loader_sha256=$script:Working8KLoaderHash
    $record.runtime_verified=$false; $record.game_send_verified=$false
    foreach ($pair in @(@('suspended_at',$time),@('known_8k_control_backup',$backup),
        @('active_control_dll_sha256',$script:Working8KDllHash),@('active_control_capacity_bytes',8192))) {
        $record | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
    }
    $localLoader.status='installed'; $localLoader.native_runtime_verified=$false; $localLoader.game_send_verified=$false
    $localLibrary.status='installed-awaiting-manual-validation'
    $localLibrary.installed_library_sha256=$compiled.LibraryHash; $localLibrary.installed_response_sha256=$compiled.ResponseHash
    $localLibrary.runtime_verified=$false; $localLibrary.game_send_verified=$false
    foreach ($legacy in @($localLoader,$localLibrary)) {
        $legacy | Add-Member -NotePropertyName known_8k_control_backup -NotePropertyValue $backup -Force
        $legacy | Add-Member -NotePropertyName control_reactivated_at -NotePropertyValue $time -Force
    }
    $utf8=New-Object Text.UTF8Encoding($false)
    $entries=@(
        (New-Working8KEntry $library $compiled.LibraryBytes 'library20.previous.json'),
        (New-Working8KEntry $response $compiled.ResponseBytes 'local-response.previous.json'),
        (New-Working8KEntry $Context.Dll ([IO.File]::ReadAllBytes($DllSource)) 'TenPallas.previous.dll'),
        (New-Working8KEntry $Context.Loader ([IO.File]::ReadAllBytes($LoaderSource)) 'pallas.previous.exe'),
        (New-Working8KEntry $Context.State ($utf8.GetBytes(($record | ConvertTo-Json -Depth 6))) 'portable-state.previous.json'),
        (New-Working8KEntry $loaderState ($utf8.GetBytes(($localLoader | ConvertTo-Json -Depth 6))) 'local-scheme-state.previous.json'),
        (New-Working8KEntry $libraryState ($utf8.GetBytes(($localLibrary | ConvertTo-Json -Depth 6))) 'local-library-state.previous.json'))
    if ($entries[2].BeforeHash -ne $script:PortableTargetHash -or $entries[3].BeforeHash -ne $script:PortableLoaderHash -or
        $entries[4].BeforeHash -ne $Context.StateHash -or $entries[5].BeforeHash -ne $loaderStateBefore -or
        $entries[6].BeforeHash -ne $libraryStateBefore) { throw 'Component or installation state changed during planning.' }
    if ($entries[2].TargetHash -ne $script:Working8KDllHash -or $entries[3].TargetHash -ne $script:Working8KLoaderHash) {
        throw 'A pinned component source changed during planning.'
    }
    $preserved=@()
    foreach ($item in @(@($Context.Library,'portable-library.preserved.bin'),@($Context.Source,'applied-messages.preserved.json'),
        @((Join-Path $Context.Data 'Editor\messages.json'),'editor-draft.preserved.json'),
        @((Join-Path $Context.Data 'Editor\settings.json'),'editor-settings.preserved.json'),
        @((Join-Path $LegacyRoot 'HotkeysV2Experiment\state.json'),'hotkeys-v2-state.preserved.json'),
        @((Join-Path $LegacyRoot 'hotkeys-v2.bin'),'hotkeys-v2-library.preserved.bin'))) {
        if (Test-Path -LiteralPath $item[0] -PathType Leaf) {
            $preserved+=New-Working8KEntry $item[0] ([IO.File]::ReadAllBytes($item[0])) $item[1]
        }
    }
    return [pscustomobject]@{Entries=$entries;Preserved=$preserved;Backup=$backup;Record=$record;Compiled=$compiled
        SourcePath=$Context.Source;SourceHash=$document.Hash;LegacyRoot=$LegacyRoot}
}
function Assert-Working8KPlan($Context,$Plan) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    foreach ($entry in @($Plan.Entries)+@($Plan.Preserved)) {
        [void](Assert-PortablePath $entry.Path); Assert-ShoutHash $entry.Path $entry.BeforeHash
    }
    Assert-ShoutHash $Plan.SourcePath $Plan.SourceHash
}
function Invoke-Working8KSwitch($Context,$Plan) {
    Assert-Working8KPlan $Context $Plan
    [void](New-Item -ItemType Directory -Path $Plan.Backup)
    foreach ($entry in @($Plan.Entries)+@($Plan.Preserved)) {
        Backup-PortableFile $entry.Path (Join-Path $Plan.Backup $entry.BackupName) $entry.BeforeHash
    }
    $journal=[ordered]@{experiment='known-working-8k-control';status='prepared';prepared_at=[DateTime]::UtcNow.ToString('o')
        sid=$Context.Sid;root=$Context.Root;candidate_dll_sha256=$script:Working8KDllHash
        candidate_loader_sha256=$script:Working8KLoaderHash;game_send_verified=$false
        changes=@($Plan.Entries | Select-Object Path,BeforeHash,TargetHash,BackupName)
        preserved=@($Plan.Preserved | Select-Object Path,BeforeHash,BackupName)}
    $utf8=New-Object Text.UTF8Encoding($false)
    $journalPath=Join-Path $Plan.Backup 'transition.json'
    Write-PortableFile $Context ($utf8.GetBytes(($journal | ConvertTo-Json -Depth 7))) $journalPath $null $script:PortableTargetHash
    $journalBefore=Get-ShoutFileHash $journalPath
    # Converted source is an immutable backup artifact, NOT a new draft to edit.
    Write-PortableFile $Context ($utf8.GetBytes(($Plan.Compiled.Scheme | ConvertTo-Json -Depth 4))) (Join-Path $Plan.Backup 'converted-scheme20.json') $null $script:PortableTargetHash
    Assert-Working8KPlan $Context $Plan
    $currentDll=$script:PortableTargetHash
    try {
        foreach ($entry in $Plan.Entries) {
            Assert-ShoutHash $Plan.SourcePath $Plan.SourceHash
            Write-PortableFile $Context $entry.TargetBytes $entry.Path $entry.BeforeHash $currentDll
            if ($entry.Path -eq $Context.Dll) { $currentDll=$entry.TargetHash }
            if ($entry.Path -eq $Context.Loader) { $Context.LoaderHash=$entry.TargetHash }
        }
        foreach ($entry in $Plan.Entries) { Assert-ShoutHash $entry.Path $entry.TargetHash }
        foreach ($entry in $Plan.Preserved) { Assert-ShoutHash $entry.Path $entry.BeforeHash }
        $Context.StateHash=Get-ShoutFileHash $Context.State
        [void](Read-PortableState $Context)
        $journal.status='active-awaiting-game-test'; $journal.activated_at=[DateTime]::UtcNow.ToString('o')
        Write-PortableFile $Context ($utf8.GetBytes(($journal | ConvertTo-Json -Depth 7))) $journalPath $journalBefore $currentDll
    } catch {
        $failure=$_.Exception.Message
        # Refuse to roll back over unrelated/concurrent changes. All exact backups remain.
        foreach ($entry in $Plan.Entries) {
            if ((Get-ShoutFileHash $entry.Path) -notin @($entry.BeforeHash,$entry.TargetHash)) {
                throw ('Concurrent change prevents automatic rollback. Exact backups retained: '+$Plan.Backup)
            }
        }
        $Context.LoaderHash=Get-ShoutFileHash $Context.Loader
        $currentDll=Get-ShoutFileHash $Context.Dll
        for ($i=$Plan.Entries.Count-1;$i -ge 0;$i--) {
            $entry=$Plan.Entries[$i]; $current=Get-ShoutFileHash $entry.Path
            if ($current -ne $entry.BeforeHash) {
                Write-PortableFile $Context $entry.BeforeBytes $entry.Path $current $currentDll
                if ($entry.Path -eq $Context.Dll) { $currentDll=$entry.BeforeHash }
                if ($entry.Path -eq $Context.Loader) { $Context.LoaderHash=$entry.BeforeHash }
            }
        }
        foreach ($entry in $Plan.Entries) { Assert-ShoutHash $entry.Path $entry.BeforeHash }
        throw ('Control switch failed; previous pair and states restored. All backups retained: '+$Plan.Backup+'. '+$failure)
    }
    Write-Host ('SWITCHED AND READ BACK: existing 8 KiB twenty-message pair. Backup: '+$Plan.Backup)
    Write-Host ('Library: '+$Plan.Compiled.LibraryBytes.Length+' / 8192 bytes; bootstrap: '+$Plan.Compiled.BootstrapBytes+' / 2046 bytes.')
    Write-Host 'All twenty texts retained. Keys: hold ~, release digit/F1..F10. The native panel displays only ten entries.'
    Write-Host 'Current training-mode sending is NOT yet verified. Do not apply the suspended 64 KiB editor during this control.'
    Write-Host 'Historical modified components remain UNSIGNED. If loading/integrity/security rejects them, stop; never bypass protection.'
    return $Plan.Record
}
if ($FunctionsOnly) { return }
$mutex=$null; $held=$false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Windows account changed; no changes.' }
    $data=Get-PortableDataRoot
    $context=New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    if ($Mode -eq 'Status') {
        $record=Read-PortableState $context
        Write-Host ('State: '+$record.status)
        Write-Host ('8 KiB DLL matching: '+((Get-ShoutFileHash $context.Dll) -eq $script:Working8KDllHash))
        Write-Host ('8 KiB local-loader matching: '+((Get-ShoutFileHash $context.Loader) -eq $script:Working8KLoaderHash))
        $since=[pscustomobject]@{installed_at=$record.suspended_at}
        Write-Host ('Latest local log: '+((Get-PortableRuntimeEvidence $context $since) | ConvertTo-Json -Compress))
        exit 0
    }
    if ((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout') -ne $script:Working8KProfile) {
        throw 'The historical pair is pinned to the existing zly profile; not a portable installer.'
    }
    $mutexId=(Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex=New-Object Threading.Mutex($false,('Global\LOLPallasPortable-'+$mutexId))
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Another component operation is running.' }
    $loaderSource=Join-Path $data 'backups\original-loader-restore-51d0dcdb3fc24286b234fc41435ba170\pallas.previous.exe'
    $plan=New-Working8KPlan $context $script:Working8KProfile (Join-Path $PSScriptRoot 'build\local-library-v1\TenPallas.library.experimental.dll') $loaderSource
    if ($Mode -eq 'Validate') {
        Write-Host ('VALID: existing pair and twenty unchanged texts; '+$plan.Compiled.LibraryBytes.Length+' / 8192 bytes. No live writes.'); exit 0
    }
    if ($PSCmdlet.ShouldProcess($context.Dll,'Back up both components, all active text/state files; reactivate the existing unsigned 8 KiB twenty-message pair')) {
        [void](Invoke-Working8KSwitch $context $plan)
    }
    exit 0
} catch { Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
