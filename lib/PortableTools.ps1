# Windows PowerShell 5.1; importing defines functions only.
. (Join-Path $PSScriptRoot 'HotkeyTools.ps1')
$script:PortableTargetHash = '6B8CCD673E96817095933BDAA170DC76D7995D27EC6CB41921F9E794A92F5AE3'
$script:PortableOriginalHash = '97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94'
$script:PortableV2Hash = '4AE8AB0793EEBCEA5E23C1B8931A6C0057393BBCF413A9AF323D91750D3EE143'
$script:PortableLoaderHash = 'E17F8CE7CA6936A5984AF16BB2751F305B3F72F556D0C7D2AD31C2C9EE70D119'
$script:PortableV2LoaderHash = '803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935'
$script:PortableDeltaHashes = @{
    'original-to-portable.json' = '27A3B4235204C03C307FF97AD4E08D4C2D1453A901E0A708FD51266E1CE154E5'
    'v2-to-portable.json' = '16E24F3BC93044322B659E4A84F6B9AC104FA16C36756319E1DA5A731BAEB2FB'
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
    if ($current -notin @($script:PortableTargetHash,$Record.baseline_dll_sha256)) { throw 'Unknown DLL; state commit refused.' }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Depth 5))
    Write-PortableFile $Context $bytes $Context.State $Context.StateHash $current
    $Context.StateHash = Get-ShoutByteHash $bytes
}
function Read-PortableState($Context) {
    $hash = Get-ShoutFileHash $Context.State
    $record = Get-Content -LiteralPath $Context.State -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.experiment -ne 'portable-hotkeys-v3' -or $record.sid -ne $Context.Sid -or
        $record.wegame_root -ne $Context.Root -or $record.dll_path -ne $Context.Dll -or
        $record.library_path -ne $Context.Library -or $record.source_path -ne $Context.Source -or
        $record.candidate_dll_sha256 -ne $script:PortableTargetHash -or
        $record.baseline_dll_sha256 -notin @($script:PortableOriginalHash,$script:PortableV2Hash) -or
        $record.loader_sha256 -ne $Context.LoaderHash -or $record.backup_id -notmatch '^[a-f0-9]{32}$' -or
        $record.installed_library_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $record.installed_source_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Unrecognized/foreign installation state.'
    }
    $backup = Join-Path $Context.Data ('backups\' + $record.backup_id + '\TenPallas.before.dll')
    [void](Assert-PortablePath $backup); Assert-ShoutHash $backup $record.baseline_dll_sha256
    Assert-ShoutHash $Context.State $hash; $Context.StateHash = $hash; return $record
}
function Get-PortableSourceBytes($Compiled) {
    return ,(New-Object Text.UTF8Encoding($false,$true)).GetBytes(($Compiled.Scheme | ConvertTo-Json -Depth 4) + "`r`n")
}
function Restore-PortableComponent($Context, $Record) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    $current = Get-ShoutFileHash $Context.Dll
    if ($current -notin @($Record.baseline_dll_sha256,$script:PortableTargetHash)) { throw 'Component was updated/changed; restore refused. Backups retained.' }
    Assert-ShoutHash $Context.State $Context.StateHash
    $backup = Join-Path $Context.Data ('backups\' + $Record.backup_id + '\TenPallas.before.dll')
    Assert-ShoutHash $backup $Record.baseline_dll_sha256
    if ($current -eq $script:PortableTargetHash) {
        Write-PortableFile $Context ([IO.File]::ReadAllBytes($backup)) $Context.Dll $current $current
    }
    # All local texts and libraries are retained for recovery. Launcher never modified.
    $Record.status = 'restored'; Save-PortableState $Context $Record
}
function Install-PortableComponent($Context, $Compiled, [byte[]]$Candidate) {
    Assert-ShoutStopped; $baseline = Assert-PortableBaseline $Context
    if ((Get-ShoutByteHash $Candidate) -ne $script:PortableTargetHash) { throw 'Candidate hash mismatch.' }
    if (Test-Path -LiteralPath $Context.State) {
        $previous = Read-PortableState $Context
        if ($previous.baseline_dll_sha256 -ne $baseline -or $previous.status -ne 'restored') { throw 'Existing install: use the editor Apply button for edits. Prepared/failed records need review.' }
        Assert-ShoutHash $Context.Library $previous.installed_library_sha256
        Assert-ShoutHash $Context.Source $previous.installed_source_sha256
        # Reinstall reuses the exact previous applied texts; do not replace them with package defaults.
        try {
            Write-PortableFile $Context $Candidate $Context.Dll $baseline $baseline
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
function Apply-PortableMessages($Context, $Compiled) {
    Assert-ShoutStopped; Assert-PortableLoader $Context; $record = Read-PortableState $Context
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
