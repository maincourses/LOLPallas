# Data-only A/B test: keep installed DLL/loader/banks, shorten NEW texts only.
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Validate','Apply')][string]$Mode='Validate',
    [string]$WeGameRoot,[string]$ExpectedSid,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
$shortOptions=@{Mode=$Mode;Root=$WeGameRoot;Sid=$ExpectedSid;FunctionsOnly=$FunctionsOnly}
. (Join-Path $PSScriptRoot 'Switch-Pallas-Banks80.ps1') -FunctionsOnly
$Mode=$shortOptions.Mode; $WeGameRoot=$shortOptions.Root; $ExpectedSid=$shortOptions.Sid; $FunctionsOnly=$shortOptions.FunctionsOnly

function ConvertTo-BankTextArtifacts($Scheme,[int]$MaximumUnits=100) {
    $names=@($Scheme.PSObject.Properties.Name)
    $expected=@('title','key')+@(0..79 | ForEach-Object { $_.ToString() })
    if ($names.Count -ne 82 -or @(Compare-Object $names $expected).Count -or
        ($Scheme.key -isnot [int] -and $Scheme.key -isnot [long]) -or $Scheme.key -notin @(1,2)) { throw 'Unknown eighty-message JSON shape.' }
    $ordered=[ordered]@{}
    foreach ($name in @($expected | Where-Object { $_ -ne 'key' })) {
        $value=$Scheme.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt $MaximumUnits -or $value -match '[\x00-\x1f\x7f]') {
            throw ('Invalid text/UTF-16 length: '+$name)
        }
    }
    foreach ($i in 0..79) { $ordered[$i.ToString()]=$Scheme.($i.ToString()) }
    $ordered['title']=$Scheme.title; $ordered['key']=$Scheme.key
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    $raw=$utf8.GetBytes(($ordered | ConvertTo-Json -Depth 4 -Compress))
    if ($raw.Length -gt 65536) { throw 'Library exceeds unchanged 64 KiB reader.' }
    $token='{0:X8}:{1:X8}' -f $raw.Length,(Get-LibraryChecksum $raw)
    $preview=[ordered]@{_lps_local_v1=$token}
    foreach ($i in 0..19) {
        $preview[$i.ToString()]=''
        if ($i -lt 10) { $preview[$i.ToString()]=$Scheme.($i.ToString()) }
    }
    $preview['title']=$Scheme.title; $preview['key']=$Scheme.key
    $bootstrap=$utf8.GetBytes(($preview | ConvertTo-Json -Depth 4 -Compress))
    if ($bootstrap.Length -gt 2046) { throw 'Unchanged native preview limit exceeded.' }
    $envelope=[ordered]@{result=[ordered]@{error_code=0};shout_message=[Convert]::ToBase64String($bootstrap)}
    $response=$utf8.GetBytes(($envelope | ConvertTo-Json -Depth 4 -Compress))
    return [pscustomobject]@{Library=$raw;Response=$response;BootstrapBytes=$bootstrap.Length;Token=$token}
}
function New-BankShortScheme($Current) {
    [void](ConvertTo-BankTextArtifacts $Current)
    $scheme=$Current | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $digits='零一二三四五六七八九'
    foreach ($i in 20..79) {
        $number=$i+1; $tens=[int][Math]::Floor($number/10); $ones=$number%10
        $label=$digits[$tens].ToString()+'十'
        if ($ones) { $label+=$digits[$ones].ToString() }
        $scheme.($i.ToString())='容量检验第'+$label+'条：确认队友位置和敌方动向，做好河道视野再集合推进，避免落单，保持良好沟通。已核对。'
    }
    foreach ($name in @('title','key')+@(0..19 | ForEach-Object { $_.ToString() })) {
        if ($scheme.$name -cne $Current.$name) { throw 'Personal text/metadata changed.' }
    }
    [void](ConvertTo-BankTextArtifacts $scheme -MaximumUnits 50)
    return $scheme
}
function New-BankShortTextPlan($Context,[string]$LegacyRoot) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    Assert-ShoutHash $Context.Dll $script:Banks80Hash
    $saved=Read-Banks80Record $Context $LegacyRoot; $r=$saved.Record
    if ($r.status -ne 'installed-awaiting-game-test') { throw 'Eighty-message banks not active.' }
    foreach ($e in $r.changes) { Assert-ShoutHash $e.Path $e.TargetHash }
    $libraryPath=$r.changes[0].Path; $responsePath=$r.changes[1].Path
    $current=Get-Content -LiteralPath $libraryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $old=ConvertTo-BankTextArtifacts $current
    if ((Get-ShoutByteHash $old.Library) -ne $r.changes[0].TargetHash -or
        (Get-ShoutByteHash $old.Response) -ne $r.changes[1].TargetHash) { throw 'Current library/bootstrap mismatch.' }
    $scheme=New-BankShortScheme $current
    $new=ConvertTo-BankTextArtifacts $scheme -MaximumUnits 50
    if ($new.Library.Length -le 8192) { throw 'Real-text capacity test must still exceed 8 KiB.' }
    if ((Get-ShoutByteHash $new.Library) -eq $r.changes[0].TargetHash) { throw 'Short texts already applied; no changes.' }
    $modern=Read-PortableState $Context
    $legacyPath=$r.changes[4].Path
    $legacy=Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($state in @($modern,$legacy)) {
        if ($state.status -ne $script:BanksSuspendedStatus -or $state.active_control_dll_sha256 -ne $script:Banks80Hash) {
            throw 'Inconsistent active bank state.'
        }
    }
    if ($legacy.library_path -ne $libraryPath -or $legacy.response_path -ne $responsePath -or
        $legacy.installed_library_sha256 -ne $r.changes[0].TargetHash -or
        $legacy.installed_response_sha256 -ne $r.changes[1].TargetHash) { throw 'Foreign legacy text state.' }
    $time=[DateTime]::UtcNow.ToString('o')
    $backup=Assert-PortablePath (Join-Path $Context.Data ('backups\banks80-shorttext-'+[guid]::NewGuid().ToString('N')))
    foreach ($state in @($modern,$legacy,$r)) {
        $state.runtime_verified=$false; $state.game_send_verified=$false
        $state | Add-Member -NotePropertyName text_test_max_utf16 -NotePropertyValue 50 -Force
        $state | Add-Member -NotePropertyName text_test_applied_at -NotePropertyValue $time -Force
        $state | Add-Member -NotePropertyName text_test_backup -NotePropertyValue $backup -Force
    }
    # Keep native guard=100 truthful: only message DATA is changed in this test.
    $legacy.installed_library_sha256=Get-ShoutByteHash $new.Library
    $legacy.installed_response_sha256=Get-ShoutByteHash $new.Response
    $entries=@((New-Working8KEntry $libraryPath $new.Library 'library80.long.json'),
        (New-Working8KEntry $responsePath $new.Response 'local-response.long.json'),
        (New-Working8KEntry $Context.State (Get-CapacityJsonBytes $modern) 'portable-state.before.json'),
        (New-Working8KEntry $legacyPath (Get-CapacityJsonBytes $legacy) 'library-state.before.json'))
    $indices=@(0,1,3,4)
    foreach ($i in 0..3) {
        $change=$r.changes[$indices[$i]]
        if ($entries[$i].BeforeHash -ne $change.TargetHash) { throw 'File changed while planning.' }
        $change.TargetHash=$entries[$i].TargetHash
    }
    $r.library_bytes=$new.Library.Length; $r.bootstrap_bytes=$new.BootstrapBytes
    $journal=New-Working8KEntry $saved.Path (Get-CapacityJsonBytes $r) 'bank-control.before.json'
    if ($journal.BeforeHash -ne $saved.Hash) { throw 'Bank journal changed while planning.' }
    $entries+=,$journal
    $preserved=@()
    foreach ($item in @(@($Context.Dll,'TenPallas.unchanged.dll'),@($Context.Loader,'pallas.unchanged.exe'),
        @($Context.Library,'modern-library.unchanged.bin'),@($Context.Source,'applied-messages.unchanged.json'),
        @((Join-Path $Context.Data 'Editor\messages.json'),'editor-draft.unchanged.json'),
        @((Join-Path $Context.Data 'Editor\settings.json'),'editor-settings.unchanged.json'),
        @($r.changes[5].Path,'capacity-control.unchanged.json'),
        @((Join-Path $LegacyRoot 'LocalSchemeExperiment\state.json'),'loader-state.unchanged.json'))) {
        $preserved+=New-Working8KEntry $item[0] ([IO.File]::ReadAllBytes($item[0])) $item[1]
    }
    Assert-ShoutHash $Context.State $entries[2].BeforeHash
    return [pscustomobject]@{Entries=$entries;Preserved=$preserved;Backup=$backup;LibraryBytes=$new.Library.Length
        Scheme=$scheme;Time=$time;Record=$r}
}
function Assert-BankShortTextPlan($Context,$Plan) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Dll $script:Banks80Hash
    Assert-ShoutHash $Context.Loader $script:Working8KLoaderHash
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) { Assert-ShoutHash $e.Path $e.BeforeHash }
}
function Invoke-BankShortTextApply($Context,$Plan) {
    Assert-BankShortTextPlan $Context $Plan
    [void](New-Item -ItemType Directory -Path $Plan.Backup)
    foreach ($e in @($Plan.Entries)+@($Plan.Preserved)) {
        Backup-PortableFile $e.Path (Join-Path $Plan.Backup $e.BackupName) $e.BeforeHash
    }
    Assert-BankShortTextPlan $Context $Plan
    try {
        foreach ($e in $Plan.Entries) {
            foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
            Write-PortableFile $Context $e.TargetBytes $e.Path $e.BeforeHash $script:Banks80Hash
        }
        foreach ($e in $Plan.Entries) { Assert-ShoutHash $e.Path $e.TargetHash }
        foreach ($p in $Plan.Preserved) { Assert-ShoutHash $p.Path $p.BeforeHash }
        [void](Read-Banks80Record $Context (Split-Path -Parent $Plan.Entries[0].Path))
    } catch {
        $failure=$_.Exception.Message
        Undo-CapacityEntries $Context $Plan.Entries
        throw ('Text-only update failed; old texts/states restored. Backup: '+$Plan.Backup+'. '+$failure)
    }
    return $Plan
}
if ($FunctionsOnly) { return }
$mutex=$null; $held=$false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Requires x64 Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Account changed; no writes.' }
    if ((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout') -ne $script:Working8KProfile) {
        throw 'Historical profile-pinned experiment; not portable.'
    }
    $data=Get-PortableDataRoot
    $context=New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    $mutexId=(Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex=New-Object Threading.Mutex($false,('Global\LOLPallasPortable-'+$mutexId))
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Another operation is running.' }
    $plan=New-BankShortTextPlan $context $script:Working8KProfile
    Assert-BankShortTextPlan $context $plan
    if ($Mode -eq 'Validate') { Write-Host ('VALID: text-only / 80 messages / at most 50 UTF-16 units / '+$plan.LibraryBytes+' bytes; no writes.'); exit 0 }
    if ($PSCmdlet.ShouldProcess($plan.Entries[0].Path,'Backup all texts; shorten only new messages 21..80 to <=50 UTF-16 units; no component writes')) {
        [void](Invoke-BankShortTextApply $context $plan)
        Write-Host ('APPLIED AND READ BACK: original 20 unchanged; new 60 at most 50 units. Library '+$plan.LibraryBytes+' bytes. Backup: '+$plan.Backup)
        Write-Host 'DLL, loader and bank keys unchanged. Exit/restart WeGame and start a NEW training session. No game sending verified.'
    }; exit 0
} catch { Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
