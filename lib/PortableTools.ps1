# Windows PowerShell 5.1; importing defines functions only.
. (Join-Path $PSScriptRoot 'HotkeyTools.ps1')
$script:PortableTargetHash = '3632DDE93AC267084F715CB60C551796FF6F12FC73D4916B2F8B39DAC514377F'
$script:PortablePreviousHash = '6B8CCD673E96817095933BDAA170DC76D7995D27EC6CB41921F9E794A92F5AE3'
$script:PortableFixedPreviousHash = '52776E6B2D105DF4CD0FF7EC8933E8170F7A404D1D6FD68288CA5C44AF0CC0AD'
$script:PortableOriginalHash = '97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94'
$script:PortableV2Hash = '4AE8AB0793EEBCEA5E23C1B8931A6C0057393BBCF413A9AF323D91750D3EE143'
$script:PortableLoaderHash = 'E17F8CE7CA6936A5984AF16BB2751F305B3F72F556D0C7D2AD31C2C9EE70D119'
$script:PortableV2LoaderHash = '803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935'
$script:PortableNativeControlHash = 'C7457983D5B09B8F1A4D4770F4386E5750077D1A29B4F285D1ABDFC83615C5CB'
$script:PortableDeltaHashes = @{
    'original-to-portable.json' = '299C25A4B519818E63410DA39BB54FC1F9B2C7724881A0A9C893FAE1177E4E07'
    'v2-to-portable.json' = '26B0CB8BB5F9667921D910487775EDA101B996DF62CA9A4EA0CC47F16F2C2C1F'
    'portable-v3-to-fixed.json' = '149E99D59E910C4E73C25BC3F267B344A991711677A166E3B9BB9B72D4E1C8B4'
    'portable-fixed-to-compatible.json' = '24D4F4B2137613AD6A8F420568DAF85745308DFC662414AB72CA338A848413E5'
}
function Get-PortablePreviousHashes { return @($script:PortablePreviousHash,$script:PortableFixedPreviousHash) }

function Read-PortableRuntimeEvents([byte[]]$Bytes,[byte[]]$Key) {
    if (-not ('LOLPallasRuntimeLogReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
public sealed class LOLPallasRuntimeEvent {
    public long UnixTime; public string Kind; public int Value;
}
public static class LOLPallasRuntimeLogReader {
    public static LOLPallasRuntimeEvent[] Read(byte[] bytes, byte[] key) {
        if (bytes.Length > 16777216 || key.Length != 128) throw new ArgumentException("Log/key bounds");
        var result = new List<LOLPallasRuntimeEvent>();
        var utf16 = new UnicodeEncoding(false, false, true);
        int at = 0;
        while (at + 168 <= bytes.Length) {
            uint size = BitConverter.ToUInt32(bytes, at);
            if (size < 170 || size > 1048576) throw new ArgumentException("TLG record size");
            if (size > bytes.Length - at) break; // Concurrent append, incomplete tail.
            int start = BitConverter.ToUInt16(bytes, at + 60);
            int end = BitConverter.ToUInt16(bytes, at + 62);
            if (start < 168 || end < start || end > size || ((end - start) & 1) != 0)
                throw new ArgumentException("TLG field bounds");
            byte[] plain = new byte[end - start];
            for (int i = 0; i < plain.Length; i++) plain[i] = (byte)(bytes[at + start + i] ^ key[i % 128]);
            string text = utf16.GetString(plain).TrimEnd('\0');
            string kind = null; int value = 0;
            if (text.StartsWith("OnGameStart, game_id:")) kind = "game-start";
            else if (text.StartsWith("lol game end, set tenpallas path empty.")) kind = "game-end";
            else if (text.StartsWith("OnGetShoutMessageRsp, send chat content to tp")) kind = "scheme-dispatched";
            else if (text.StartsWith("SendGetShoutMessage, req:")) kind = "scheme-requested";
            else if (text.StartsWith("ChekInGameRunStatus ten_pallas_run_flg=")) {
                kind = "assistant-run-flag";
                string token = text.Substring("ChekInGameRunStatus ten_pallas_run_flg=".Length).Split(',')[0];
                if (!Int32.TryParse(token, out value)) throw new ArgumentException("Run flag format");
            }
            if (kind != null) result.Add(new LOLPallasRuntimeEvent {
                UnixTime = BitConverter.ToInt64(bytes, at + 32), Kind = kind, Value = value });
            // No raw payloads, account IDs, commands, messages or tokens returned.
            at += (int)size;
        }
        return result.ToArray();
    }
}
'@
    }
    return [LOLPallasRuntimeLogReader]::Read($Bytes,$Key)
}
function Get-PortableRuntimeEvidence($Context,$Record) {
    $path = Join-Path $Context.Root 'apps\Pallas\log\pallas.tlg'
    $logger = Join-Path $Context.Root 'apps\Pallas\tx_log.dll'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-ShoutFileHash $logger) -ne '8548579CF3DC0A2EDEFDA388FAD2177BCEF98F0AA4B6F61F9EB87B56F1574F66') {
        return [pscustomobject]@{ Stage='unknown'; Reason='No supported local runtime log.' }
    }
    [void](Assert-PortablePath $path); [void](Assert-PortablePath $logger)
    $key = New-Object byte[] 128; $loggerBytes = [IO.File]::ReadAllBytes($logger)
    [Array]::Copy($loggerBytes,146712,$key,0,128)
    if ([BitConverter]::ToString($key,0,10) -ne 'E9-29-CE-76-E1-45-11-7E-33-51') { throw 'Unsupported logger table.' }
    $latest = $null
    foreach ($entry in @(Read-PortableRuntimeEvents ([IO.File]::ReadAllBytes($path)) $key)) {
        if ($entry.Kind -eq 'game-start') {
            $latest = [ordered]@{ Stage='unknown'; LastGameStartedUtc=([DateTimeOffset]::FromUnixTimeSeconds($entry.UnixTime).UtcDateTime.ToString('o'))
                RunFlag=$null; SchemeRequested=$false; SchemeDispatched=$false; GameClosed=$false
                MatchesCurrentInstall=$false; GameSendVerified=$false }
        } elseif ($latest) {
            switch ($entry.Kind) {
                'game-end' { $latest.GameClosed=$true }
                'assistant-run-flag' { $latest.RunFlag=$entry.Value }
                'scheme-requested' { $latest.SchemeRequested=$true }
                'scheme-dispatched' { $latest.SchemeDispatched=$true }
            }
        }
    }
    if (-not $latest) { return [pscustomobject]@{ Stage='unknown'; Reason='No game session in the available log.' } }
    $since = [DateTime]::MinValue
    foreach ($field in @('installed_at','upgraded_at','text_test_applied_at')) {
        if ($Record -and $Record.$field) {
            $value = [DateTimeOffset]::Parse([string]$Record.$field).UtcDateTime
            if ($value -gt $since) { $since=$value }
        }
    }
    $latest.MatchesCurrentInstall = $null -ne $Record -and
        [DateTimeOffset]::Parse($latest.LastGameStartedUtc).UtcDateTime -ge $since
    if ($latest.RunFlag -eq 0) { $latest.Stage='assistant-not-running' }
    elseif ($latest.SchemeDispatched) { $latest.Stage='scheme-dispatched-game-send-unverified' }
    elseif ($null -ne $latest.RunFlag -and $latest.RunFlag -gt 0) { $latest.Stage='assistant-running-awaiting-scheme' }
    return [pscustomobject]$latest
}

function Get-PortableSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Get-PortableDataRoot {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LOLPallasPortable'
}
function ConvertTo-PortableArgument([string]$Value) {
    if ($Value -match '[\x00-\x1F"]') { throw 'Invalid command argument.' }
    # Windows argv: duplicate a trailing backslash before the closing quote.
    return '"' + ($Value -replace '(\\+)$','$1$1') + '"'
}
function Assert-PortablePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw 'Network/UNC paths are not supported.' }
    $part = $full
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw ('Linked/reparse path refused: ' + $part)
            }
        }
        $parent = Split-Path -Parent $part
        if (-not $parent -or $parent -eq $part) { break }; $part = $parent
    }
    return $full
}
function Get-PortableCandidateRoots {
    # Only explicit registration and common locations, never crawl disks/accounts.
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($baseKey in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion')) {
        foreach ($name in @('wegame.exe','tgp_daemon.exe')) {
            $key = Join-Path $baseKey ('App Paths\' + $name)
            if (Test-Path -LiteralPath $key) {
                $value = (Get-Item -LiteralPath $key).GetValue('')
                if ($value -is [string] -and $value) { $found.Add((Split-Path -Parent $value.Trim('"'))) }
            }
        }
        $uninstall = Join-Path $baseKey 'Uninstall'
        if (Test-Path -LiteralPath $uninstall) {
            foreach ($key in Get-ChildItem -LiteralPath $uninstall -ErrorAction SilentlyContinue) {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if ($props.DisplayName -match '^(WeGame|Tencent WeGame|\u817e\u8baf.*WeGame|\u817e\u8baf\u6e38\u620f\u5e73\u53f0|TGP)(\s|$)' -and
                    $props.InstallLocation -is [string] -and $props.InstallLocation) { $found.Add($props.InstallLocation) }
            }
        }
    }
    foreach ($key in @('HKCU:\SOFTWARE\Tencent\WeGame','HKLM:\SOFTWARE\Tencent\WeGame',
        'HKLM:\SOFTWARE\WOW6432Node\Tencent\WeGame','HKCU:\SOFTWARE\Tencent\TGP')) {
        if (Test-Path -LiteralPath $key) {
            $props = Get-ItemProperty -LiteralPath $key
            foreach ($field in @('InstallPath','InstallDir','Path')) {
                if ($props.$field -is [string] -and $props.$field) { $found.Add($props.$field) }
            }
        }
    }
    foreach ($folder in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if ($folder) { foreach ($suffix in @('WeGame','Tencent\WeGame','Tencent\TGP')) { $found.Add((Join-Path $folder $suffix)) } }
    }
    return @($found | Select-Object -Unique)
}
function Test-PortableRoot([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'apps\Pallas\pallas.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'apps\Pallas\tp_deps\TenPallas.dll') -PathType Leaf)
}
function Resolve-PortableRoot([string]$Requested, [string]$DataRoot) {
    if ($Requested) {
        if (-not (Test-PortableRoot $Requested)) { throw 'Choose the WeGame installation folder containing apps\Pallas (not the LoL folder).' }
        return Assert-PortablePath $Requested
    }
    $state = Join-Path $DataRoot 'state.json'
    if (Test-Path -LiteralPath $state -PathType Leaf) {
        $saved = Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.experiment -eq 'portable-hotkeys-v3' -and $saved.sid -eq (Get-PortableSid) -and
            (Test-PortableRoot $saved.wegame_root)) { return Assert-PortablePath $saved.wegame_root }
    }
    $roots = @(Get-PortableCandidateRoots | Where-Object { Test-PortableRoot $_ } | ForEach-Object { Assert-PortablePath $_ } | Select-Object -Unique)
    if ($roots.Count -ne 1) { throw ('WeGame detection found ' + $roots.Count + ' installations. Use Install.cmd / Choose-WeGame.cmd to choose its folder.') }
    return $roots[0]
}
function New-PortableContext([string]$WeGameRoot, [string]$DataRoot) {
    $wegame = Assert-PortablePath $WeGameRoot; $data = Assert-PortablePath $DataRoot
    $library = Join-Path $data 'hotkeys.bin'
    if ($library.Length -ge 260) { throw 'Local library path exceeds the supported MAX_PATH length.' }
    $dll = Join-Path $wegame 'apps\Pallas\tp_deps\TenPallas.dll'
    $loader = Join-Path $wegame 'apps\Pallas\pallas.exe'
    [void](Assert-PortablePath $dll); [void](Assert-PortablePath $loader)
    return [pscustomobject]@{ Root = $wegame; Data = $data; Dll = $dll; Loader = $loader
        Library = $library; Source = (Join-Path $data 'applied-messages.json'); State = (Join-Path $data 'state.json')
        Sid = Get-PortableSid; StateHash = $null; LoaderHash = Get-ShoutFileHash $loader }
}
function Assert-PortableLoader($Context) {
    if ($Context.LoaderHash -notin @($script:PortableLoaderHash,$script:PortableV2LoaderHash)) { throw 'Unsupported Pallas launcher version. No files changed.' }
    Assert-ShoutHash $Context.Loader $Context.LoaderHash
}
function Assert-PortableBaseline($Context) {
    Assert-PortableLoader $Context
    $hash = Get-ShoutFileHash $Context.Dll
    if ($hash -in (Get-PortablePreviousHashes)) {
        $previous = Read-PortableState $Context
        if ($previous.candidate_dll_sha256 -ne $hash -or $previous.status -ne 'installed-awaiting-game-test') { throw 'Previous portable install needs review.' }
        Assert-ShoutHash $Context.Library $previous.installed_library_sha256
        Assert-ShoutHash $Context.Source $previous.installed_source_sha256
        return $hash
    }
    if ($hash -eq $script:PortableOriginalHash -and $Context.LoaderHash -eq $script:PortableLoaderHash) {
        foreach ($path in @($Context.Dll,$Context.Loader)) {
            if ((Get-AuthenticodeSignature -LiteralPath $path).Status.ToString() -ne 'Valid') { throw 'Original component signature is not valid. Refusing installation.' }
        }
        return $hash
    }
    if ($hash -eq $script:PortableV2Hash -and $Context.LoaderHash -eq $script:PortableV2LoaderHash) {
        # Only an internally consistent previous v2 install in this same profile.
        $legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout'
        $legacy = Get-Content -LiteralPath (Join-Path $legacyRoot 'HotkeysV2Experiment\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($legacy.experiment -ne 'local-hotkeys-v2' -or $legacy.dll_path -ne $Context.Dll -or
            $legacy.candidate_dll_sha256 -ne $hash -or $legacy.library_path -ne (Join-Path $legacyRoot 'hotkeys-v2.bin') -or
            $legacy.response_path -ne (Join-Path $legacyRoot 'local-response.json')) { throw 'Previous v2 install belongs to another profile/location.' }
        Assert-ShoutHash $legacy.library_path $legacy.installed_library_sha256
        Assert-ShoutHash $legacy.response_path $legacy.installed_response_sha256
        return $hash
    }
    throw ('Unsupported TenPallas / Pallas build. Refusing replacement; DLL SHA256: ' + $hash)
}
function Expand-PortableDelta([byte[]]$Before, [string]$Path, [string]$ExpectedDeltaHash) {
    Assert-ShoutHash $Path $ExpectedDeltaHash
    $plan = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-ShoutHash $Path $ExpectedDeltaHash
    if ($plan.format -ne 1 -or $plan.source_size -ne $Before.Length -or $plan.source_sha256 -ne (Get-ShoutByteHash $Before) -or
        $plan.target_sha256 -ne $script:PortableTargetHash -or $plan.target_size -lt 1 -or $plan.target_size -gt 4194304) { throw 'Invalid patch metadata/source.' }
    $result = New-Object byte[] ([int]$plan.target_size)
    [Array]::Copy($Before, $result, [Math]::Min($Before.Length,$result.Length)); $last = 0
    foreach ($row in $plan.edits) {
        if ($row.offset -isnot [int] -and $row.offset -isnot [long]) { throw 'Invalid patch offset type.' }
        $bytes = [Convert]::FromBase64String($row.data); [long]$at = $row.offset
        if ($at -lt $last -or $bytes.Length -eq 0 -or $at + $bytes.Length -gt $result.Length) { throw 'Invalid patch order/bounds.' }
        [Array]::Copy($bytes, 0, $result, $at, $bytes.Length); $last = $at + $bytes.Length
    }
    if ((Get-ShoutByteHash $result) -ne $script:PortableTargetHash) { throw 'Reconstructed component hash mismatch.' }
    return ,$result
}
function Write-PortableFile($Context, [byte[]]$Bytes, [string]$Path, $Before, [string]$ExpectedDll) {
    [void](Assert-PortablePath $Path); Assert-ShoutStopped; Assert-PortableLoader $Context
    Assert-ShoutHash $Context.Dll $ExpectedDll
    if ((Get-ShoutFileHash $Path) -ne $Before) { throw ('Concurrent change; refused: ' + $Path) }
    if (-not $Before -and (Test-Path -LiteralPath $Path)) { throw 'Non-file occupies destination.' }
    $stage = Join-Path (Split-Path -Parent $Path) ('portable-stage-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $hash = Get-ShoutByteHash $Bytes; Assert-ShoutHash $stage $hash
        Assert-ShoutStopped; Assert-PortableLoader $Context; Assert-ShoutHash $Context.Dll $ExpectedDll
        [void](Assert-PortablePath $Path)
        if ((Get-ShoutFileHash $Path) -ne $Before -or (-not $Before -and (Test-Path -LiteralPath $Path))) { throw 'Destination changed during staging.' }
        if ($Before) { [IO.File]::Replace($stage,$Path,[NullString]::Value) } else { [IO.File]::Move($stage,$Path) }
        Assert-ShoutHash $Path $hash
    } finally { if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage } }
}
function Backup-PortableFile([string]$Source, [string]$Destination, [string]$Hash) {
    [void](Assert-PortablePath $Source); [void](Assert-PortablePath $Destination)
    Assert-ShoutHash $Source $Hash; [IO.File]::Copy($Source,$Destination,$false); Assert-ShoutHash $Destination $Hash
}
function Save-PortableState($Context, $Record) {
    $current = Get-ShoutFileHash $Context.Dll
    if ($current -ne $script:PortableTargetHash -and $current -ne $Record.baseline_dll_sha256 -and
        $current -notin (Get-PortablePreviousHashes)) { throw 'Unknown DLL; state commit refused.' }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Depth 5))
    Write-PortableFile $Context $bytes $Context.State $Context.StateHash $current
    $Context.StateHash = Get-ShoutByteHash $bytes
}
function Read-PortableState($Context) {
    $hash = Get-ShoutFileHash $Context.State
    $record = Get-Content -LiteralPath $Context.State -Raw -Encoding UTF8 | ConvertFrom-Json
    $stockRestored = $record.status -eq 'original-components-restored'
    $knownCandidate = $record.candidate_dll_sha256 -eq $script:PortableTargetHash -or
        $record.candidate_dll_sha256 -in (Get-PortablePreviousHashes)
    if ($stockRestored -and $record.candidate_dll_sha256 -eq $script:PortableNativeControlHash) { $knownCandidate = $true }
    if ($record.experiment -ne 'portable-hotkeys-v3' -or $record.sid -ne $Context.Sid -or
        $record.wegame_root -ne $Context.Root -or $record.dll_path -ne $Context.Dll -or
        $record.library_path -ne $Context.Library -or $record.source_path -ne $Context.Source -or
        -not $knownCandidate -or
        $record.baseline_dll_sha256 -notin @($script:PortableOriginalHash,$script:PortableV2Hash) -or
        $record.loader_sha256 -ne $Context.LoaderHash -or $record.backup_id -notmatch '^[a-f0-9]{32}$' -or
        $record.installed_library_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $record.installed_source_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Unrecognized/foreign installation state.'
    }
    $backup = Join-Path $Context.Data ('backups\' + $record.backup_id + '\TenPallas.before.dll')
    [void](Assert-PortablePath $backup); Assert-ShoutHash $backup $record.baseline_dll_sha256
    if ($stockRestored) { Assert-PortableStockRestoration $Context $record }
    Assert-ShoutHash $Context.State $hash; $Context.StateHash = $hash; return $record
}
function Get-PortableRestoreBackup($Context,[string]$Path,[string]$Prefix) {
    if (-not $Path) { throw 'Missing stock restoration backup; no changes.' }
    $full = Assert-PortablePath $Path
    $parent = [IO.Path]::GetDirectoryName($full)
    $expected = [IO.Path]::GetFullPath((Join-Path $Context.Data 'backups'))
    if (-not $parent.Equals($expected,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($full) -notmatch ('^' + [regex]::Escape($Prefix) + '[a-f0-9]{32}$')) {
        throw 'Restoration backup is outside this profile or has an unknown layout.'
    }
    return $full
}
function Assert-PortableStockRestoration($Context,$Record) {
    # This is an explicit known transition, not acceptance of arbitrary old states.
    # Check before Assert-PortableBaseline: its previous-version branch reads state.
    Assert-ShoutHash $Context.Dll $script:PortableOriginalHash
    if ($Record.original_dll_sha256 -ne $script:PortableOriginalHash -or
        $Record.original_launcher_sha256 -ne $script:PortableLoaderHash -or
        $Record.loader_sha256 -ne $script:PortableLoaderHash -or $Record.keyboard_mode -ne 'original' -or
        (Assert-PortableBaseline $Context) -ne $script:PortableOriginalHash) { throw 'Restored stock pair does not match pinned signed originals.' }
    $dllBackup = Get-PortableRestoreBackup $Context $Record.original_dll_restore_backup 'original-dll-restore-'
    $loaderBackup = Get-PortableRestoreBackup $Context $Record.original_launcher_restore_backup 'original-loader-restore-'
    $savedDll = Assert-PortablePath (Join-Path $dllBackup 'TenPallas.previous.dll')
    $savedLoader = Assert-PortablePath (Join-Path $loaderBackup 'pallas.previous.exe')
    Assert-ShoutHash $savedDll $Record.candidate_dll_sha256
    Assert-ShoutHash $savedLoader $script:PortableV2LoaderHash
    $priorPath = Assert-PortablePath (Join-Path $loaderBackup 'portable-state.previous.json')
    $priorHash = Get-ShoutFileHash $priorPath
    $prior = Get-Content -LiteralPath $priorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in @('experiment','sid','wegame_root','dll_path','library_path','source_path',
        'baseline_dll_sha256','candidate_dll_sha256','backup_id','installed_library_sha256','installed_source_sha256','message_count')) {
        if ($prior.$key -ne $Record.$key) { throw ('Restoration history mismatch: ' + $key) }
    }
    if ($prior.status -ne 'original-dll-restored' -or $prior.loader_sha256 -ne $script:PortableV2LoaderHash -or
        $prior.original_dll_sha256 -ne $script:PortableOriginalHash) { throw 'Incomplete stock restoration history.' }
    Assert-ShoutHash $priorPath $priorHash
    Assert-ShoutHash (Assert-PortablePath $Context.Library) $Record.installed_library_sha256
    Assert-ShoutHash (Assert-PortablePath $Context.Source) $Record.installed_source_sha256
}
function Get-PortableSourceBytes($Compiled) {
    return ,(New-Object Text.UTF8Encoding($false,$true)).GetBytes(($Compiled.Scheme | ConvertTo-Json -Depth 4) + "`r`n")
}
function Restore-PortableComponent($Context, $Record) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    $current = Get-ShoutFileHash $Context.Dll
    if ($current -notin @($Record.baseline_dll_sha256,$Record.candidate_dll_sha256)) { throw 'Component was updated/changed; restore refused. Backups retained.' }
    Assert-ShoutHash $Context.State $Context.StateHash
    $backup = Join-Path $Context.Data ('backups\' + $Record.backup_id + '\TenPallas.before.dll')
    Assert-ShoutHash $backup $Record.baseline_dll_sha256
    if ($current -eq $Record.candidate_dll_sha256) {
        Write-PortableFile $Context ([IO.File]::ReadAllBytes($backup)) $Context.Dll $current $current
    }
    # All local texts and libraries are retained for recovery. Launcher never modified.
    $Record.status = 'restored'; Save-PortableState $Context $Record
}
function Install-PortableComponent($Context, $Compiled, [byte[]]$Candidate) {
    Assert-ShoutStopped; $baseline = Assert-PortableBaseline $Context
    if ((Get-ShoutByteHash $Candidate) -ne $script:PortableTargetHash) { throw 'Candidate hash mismatch.' }
    if ($baseline -in (Get-PortablePreviousHashes)) { return Upgrade-PortableComponent $Context $Candidate }
    if (Test-Path -LiteralPath $Context.State) {
        $previous = Read-PortableState $Context
        if ($previous.status -eq 'original-components-restored') { return Reinstall-PortableFromStock $Context $Candidate }
        if ($previous.baseline_dll_sha256 -ne $baseline -or $previous.status -ne 'restored') { throw 'Existing install: use the editor Apply button for edits. Prepared/failed records need review.' }
        Assert-ShoutHash $Context.Library $previous.installed_library_sha256
        Assert-ShoutHash $Context.Source $previous.installed_source_sha256
        # Reinstall reuses the exact previous applied texts; do not replace them with package defaults.
        try {
            Write-PortableFile $Context $Candidate $Context.Dll $baseline $baseline
            $previous.candidate_dll_sha256 = $script:PortableTargetHash
            $previous.runtime_verified = $false; $previous.game_send_verified = $false
            $previous.status = 'installed-awaiting-game-test'; Save-PortableState $Context $previous
        } catch {
            $failure = $_.Exception.Message
            try { Restore-PortableComponent $Context $previous } catch { Write-Warning ('Rollback needs review: ' + $_.Exception.Message) }
            throw ('Reinstall failed: ' + $failure)
        }
        Write-Host 'Reinstalled using the previous applied texts. Use editor Save and Apply to change them.'
        return $previous
    }
    foreach ($path in @($Context.Library,$Context.Source)) { if (Test-Path -LiteralPath $path) { throw 'Existing local data preserved. Review before installing.' } }
    $id = [guid]::NewGuid().ToString('N'); $backupRoot = Join-Path $Context.Data ('backups\' + $id)
    [void](Assert-PortablePath $backupRoot); New-Item -ItemType Directory -Path $backupRoot | Out-Null
    Backup-PortableFile $Context.Dll (Join-Path $backupRoot 'TenPallas.before.dll') $baseline
    $source = Get-PortableSourceBytes $Compiled
    $record = [ordered]@{ experiment = 'portable-hotkeys-v3'; status = 'prepared'; sid = $Context.Sid
        wegame_root = $Context.Root; dll_path = $Context.Dll; library_path = $Context.Library; source_path = $Context.Source
        baseline_dll_sha256 = $baseline; candidate_dll_sha256 = $script:PortableTargetHash
        loader_sha256 = $Context.LoaderHash; backup_id = $id; installed_library_sha256 = $Compiled.LibraryHash
        installed_source_sha256 = Get-ShoutByteHash $source; message_count = $Compiled.Scheme.count
        installed_at = [DateTime]::UtcNow.ToString('o'); game_send_verified = $false; runtime_verified = $false
        unsigned_experiment_accepted = $true; loader_modified = $false }
    Save-PortableState $Context $record
    try {
        Write-PortableFile $Context $Compiled.LibraryBytes $Context.Library $null $baseline
        Write-PortableFile $Context $source $Context.Source $null $baseline
        Write-PortableFile $Context $Candidate $Context.Dll $baseline $baseline
        $record.status = 'installed-awaiting-game-test'; Save-PortableState $Context $record
    } catch {
        $failure = $_.Exception.Message
        try { Restore-PortableComponent $Context $record } catch { Write-Warning ('Rollback requires review: ' + $_.Exception.Message + '. Backups: ' + $backupRoot) }
        throw ('Installation failed: ' + $failure + '. Texts/backups retained.')
    }
    return $record
}
function Reinstall-PortableFromStock($Context,[byte[]]$Candidate) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    $previous = Read-PortableState $Context
    if ($previous.status -ne 'original-components-restored' -or
        (Get-ShoutByteHash $Candidate) -ne $script:PortableTargetHash) { throw 'Not a supported stock reinstallation.' }
    $applied = Read-HotkeyDocument $Context.Source -FormatVersion 3
    if ($applied.Compiled.LibraryHash -ne $previous.installed_library_sha256 -or
        $applied.Compiled.Scheme.count -ne $previous.message_count) { throw 'Applied source/library mismatch; no changes.' }
    $beforeState = [IO.File]::ReadAllBytes($Context.State); $beforeHash = $Context.StateHash
    if ((Get-ShoutByteHash $beforeState) -ne $beforeHash) { throw 'Installation state changed before stock reinstallation.' }
    $id = [guid]::NewGuid().ToString('N'); $backup = Join-Path $Context.Data ('backups\' + $id)
    [void](Assert-PortablePath $backup); [void](New-Item -ItemType Directory -Path $backup)
    Backup-PortableFile $Context.Dll (Join-Path $backup 'TenPallas.before.dll') $script:PortableOriginalHash
    $history = Join-Path $backup 'previous-installation-state.json'
    Backup-PortableFile $Context.State $history $beforeHash
    Backup-PortableFile $Context.Library (Join-Path $backup 'library.before.bin') $previous.installed_library_sha256
    Backup-PortableFile $Context.Source (Join-Path $backup 'applied-messages.before.json') $previous.installed_source_sha256
    $updated = [ordered]@{ experiment='portable-hotkeys-v3'; status='installed-awaiting-game-test'; sid=$Context.Sid
        wegame_root=$Context.Root; dll_path=$Context.Dll; library_path=$Context.Library; source_path=$Context.Source
        baseline_dll_sha256=$script:PortableOriginalHash; candidate_dll_sha256=$script:PortableTargetHash
        loader_sha256=$Context.LoaderHash; backup_id=$id; installed_library_sha256=$previous.installed_library_sha256
        installed_source_sha256=$previous.installed_source_sha256; message_count=$previous.message_count
        installed_at=[DateTime]::UtcNow.ToString('o'); game_send_verified=$false; runtime_verified=$false
        unsigned_experiment_accepted=$true; loader_modified=$false; keyboard_mode='independent'
        repair_revision='stock-reinstall-r1'; predecessor_backup_id=$previous.backup_id
        predecessor_state_path=$history; predecessor_state_sha256=$beforeHash }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($updated | ConvertTo-Json -Depth 5))
    $afterHash = Get-ShoutByteHash $bytes
    try {
        Assert-ShoutHash $Context.State $beforeHash
        Assert-PortableStockRestoration $Context $previous
        Write-PortableFile $Context $Candidate $Context.Dll $script:PortableOriginalHash $script:PortableOriginalHash
        Assert-ShoutHash $Context.Library $previous.installed_library_sha256
        Assert-ShoutHash $Context.Source $previous.installed_source_sha256
        Write-PortableFile $Context $bytes $Context.State $beforeHash $script:PortableTargetHash
        $Context.StateHash = $afterHash
        $result = Read-PortableState $Context
    } catch {
        $failure = $_.Exception.Message; $nowDll = Get-ShoutFileHash $Context.Dll; $nowState = Get-ShoutFileHash $Context.State
        if ($nowDll -notin @($script:PortableOriginalHash,$script:PortableTargetHash) -or $nowState -notin @($beforeHash,$afterHash)) {
            throw ('Concurrent change; stock reinstall rollback refused. Backups retained: ' + $backup)
        }
        if ($nowDll -ne $script:PortableOriginalHash) {
            Write-PortableFile $Context ([IO.File]::ReadAllBytes((Join-Path $backup 'TenPallas.before.dll'))) $Context.Dll $nowDll $nowDll
        }
        if ($nowState -ne $beforeHash) { Write-PortableFile $Context $beforeState $Context.State $nowState $script:PortableOriginalHash }
        $Context.StateHash = $beforeHash
        throw ('Stock reinstall failed; signed original DLL and previous record recovered, texts untouched: ' + $failure)
    }
    Write-Host 'REINSTALLED FROM STOCK: signed original DLL is now the restore baseline; original launcher and existing texts unchanged. Earlier state/backups archived.'
    return $result
}
function Apply-PortableMessages($Context, $Compiled) {
    Assert-ShoutStopped; Assert-PortableLoader $Context; $record = Read-PortableState $Context
    if ($record.candidate_dll_sha256 -ne $script:PortableTargetHash) { throw 'Previous test component: use Install/Enable in the new EXE to upgrade first. All texts are retained.' }
    Assert-ShoutHash $Context.Dll $script:PortableTargetHash
    Assert-ShoutHash $Context.Library $record.installed_library_sha256; Assert-ShoutHash $Context.Source $record.installed_source_sha256
    $beforeLibrary = $record.installed_library_sha256; $beforeSource = $record.installed_source_sha256
    $source = Get-PortableSourceBytes $Compiled; $sourceHash = Get-ShoutByteHash $source
    $backupRoot = Join-Path $Context.Data ('backups\edit-' + [guid]::NewGuid().ToString('N'))
    [void](Assert-PortablePath $backupRoot); New-Item -ItemType Directory -Path $backupRoot | Out-Null
    $savedLibrary = Join-Path $backupRoot 'hotkeys.bin'; $savedSource = Join-Path $backupRoot 'messages.json'
    Backup-PortableFile $Context.Library $savedLibrary $beforeLibrary; Backup-PortableFile $Context.Source $savedSource $beforeSource
    try {
        Write-PortableFile $Context $Compiled.LibraryBytes $Context.Library $beforeLibrary $script:PortableTargetHash
        Write-PortableFile $Context $source $Context.Source $beforeSource $script:PortableTargetHash
        $record.installed_library_sha256 = $Compiled.LibraryHash; $record.installed_source_sha256 = $sourceHash
        $record.message_count = $Compiled.Scheme.count; $record.runtime_verified = $false; $record.game_send_verified = $false
        Save-PortableState $Context $record
    } catch {
        $failure = $_.Exception.Message; $nowLibrary = Get-ShoutFileHash $Context.Library; $nowSource = Get-ShoutFileHash $Context.Source
        if ($nowLibrary -notin @($beforeLibrary,$Compiled.LibraryHash) -or $nowSource -notin @($beforeSource,$sourceHash)) { throw 'Concurrent data change; rollback refused. Backups retained.' }
        if ($nowLibrary -ne $beforeLibrary) { Write-PortableFile $Context ([IO.File]::ReadAllBytes($savedLibrary)) $Context.Library $nowLibrary $script:PortableTargetHash }
        if ($nowSource -ne $beforeSource) { Write-PortableFile $Context ([IO.File]::ReadAllBytes($savedSource)) $Context.Source $nowSource $script:PortableTargetHash }
        throw ('Apply failed; previous texts restored: ' + $failure)
    }
}

function Upgrade-PortableComponent($Context, [byte[]]$Candidate,
    [string]$Revision = 'original-imports-compat-r1', [string]$KeyboardMode = 'independent') {
    Assert-ShoutStopped; Assert-PortableLoader $Context; $record = Read-PortableState $Context
    $previousHash = $record.candidate_dll_sha256
    if ($previousHash -notin (Get-PortablePreviousHashes) -or
        (Get-ShoutByteHash $Candidate) -ne $script:PortableTargetHash) { throw 'Unsupported upgrade source/target.' }
    Assert-ShoutHash $Context.Dll $previousHash
    Assert-ShoutHash $Context.Library $record.installed_library_sha256
    Assert-ShoutHash $Context.Source $record.installed_source_sha256
    $beforeState = $Context.StateHash
    $backupRoot = Join-Path $Context.Data ('backups\upgrade-' + [guid]::NewGuid().ToString('N'))
    [void](Assert-PortablePath $backupRoot); New-Item -ItemType Directory -Path $backupRoot | Out-Null
    $savedDll = Join-Path $backupRoot 'TenPallas.previous.dll'; $savedState = Join-Path $backupRoot 'state.previous.json'
    Backup-PortableFile $Context.Dll $savedDll $previousHash
    Backup-PortableFile $Context.State $savedState $beforeState
    $updated = $record | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $updated.candidate_dll_sha256 = $script:PortableTargetHash
    $updated.runtime_verified = $false; $updated.game_send_verified = $false
    $updated | Add-Member -NotePropertyName repair_revision -NotePropertyValue $Revision -Force
    $updated | Add-Member -NotePropertyName keyboard_mode -NotePropertyValue $KeyboardMode -Force
    $updated | Add-Member -NotePropertyName upgraded_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    try {
        Write-PortableFile $Context $Candidate $Context.Dll $previousHash $previousHash
        Assert-ShoutHash $Context.Library $record.installed_library_sha256
        Assert-ShoutHash $Context.Source $record.installed_source_sha256
        Save-PortableState $Context $updated
    } catch {
        $failure = $_.Exception.Message; $nowDll = Get-ShoutFileHash $Context.Dll
        $newStateHash = Get-ShoutByteHash ((New-Object Text.UTF8Encoding($false)).GetBytes(($updated | ConvertTo-Json -Depth 5)))
        $nowState = Get-ShoutFileHash $Context.State
        if ($nowDll -notin @($previousHash,$script:PortableTargetHash) -or
            $nowState -notin @($beforeState,$newStateHash)) { throw ('Concurrent change: upgrade rollback refused. Backups: ' + $backupRoot) }
        if ($nowDll -eq $script:PortableTargetHash) {
            Write-PortableFile $Context ([IO.File]::ReadAllBytes($savedDll)) $Context.Dll $nowDll $nowDll
        }
        if ($nowState -ne $beforeState) {
            Write-PortableFile $Context ([IO.File]::ReadAllBytes($savedState)) $Context.State $nowState $previousHash
        }
        $Context.StateHash = $beforeState
        throw ('Upgrade failed; previous component/state restored, texts untouched: ' + $failure)
    }
    Write-Host ('COMPONENT UPDATED (' + $Revision + '): existing texts, bindings and original restore baseline retained.')
    return $updated
}
