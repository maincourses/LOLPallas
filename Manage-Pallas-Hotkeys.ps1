[CmdletBinding(SupportsShouldProcess = $true)]
param([ValidateSet('Status','Validate','Install','Apply','Restore')][string]$Mode = 'Status',
    [switch]$AcceptUnsignedExperiment, [switch]$FunctionsOnly, [string]$SchemePath,
    [string]$BuildDirectory)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'lib\HotkeyTools.ps1')
if (-not $SchemePath) { $SchemePath = Join-Path $root 'messages.json' }
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $root 'build\hotkeys-v2' }
$dll = 'D:\Program Files (x86)\WeGame\apps\Pallas\tp_deps\TenPallas.dll'
$loader = 'D:\Program Files (x86)\WeGame\apps\Pallas\pallas.exe'
$baselineHash = 'BEB422999A6E8E7F87D93937D9010B15DCAAACCE237FD7B11C280D5CF88CCA10'
$candidateHash = '4AE8AB0793EEBCEA5E23C1B8931A6C0057393BBCF413A9AF323D91750D3EE143'
$loaderHash = '803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935'
$dataRoot = 'C:\Users\zly\AppData\Local\PallasCustomShout'
$response = Join-Path $dataRoot 'local-response.json'
$library = Join-Path $dataRoot 'hotkeys-v2.bin'
$baselineLibrary = Join-Path $dataRoot 'library20-v1.json'
$v1StatePath = Join-Path $dataRoot 'LocalLibraryExperiment\state.json'
$stateRoot = Join-Path $dataRoot 'HotkeysV2Experiment'
$statePath = Join-Path $stateRoot 'state.json'
$dllBackup = Join-Path $stateRoot 'TenPallas.before-hotkeys.dll'
$responseBackup = Join-Path $stateRoot 'response.before-hotkeys.json'
$libraryBackup = Join-Path $stateRoot 'library.before-hotkeys.json'
$script:HotkeyStateHash = $null

function Assert-HotkeyProfile {
    if ([IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'PallasCustomShout')) -ne $dataRoot) { throw 'Profile-specific candidate: other accounts are not supported.' }
    Assert-ShoutHash $loader $loaderHash
}
function Backup-HotkeyFile([string]$Source, [string]$Destination, [string]$Hash) {
    Assert-ShoutHash $Source $Hash; [IO.File]::Copy($Source, $Destination, $false); Assert-ShoutHash $Destination $Hash
}
function Write-HotkeyData([byte[]]$Bytes, [string]$Path, $Before, [string]$ExpectedDll) {
    Write-LibraryFile $Bytes $Path $Before $dll $ExpectedDll $loader $loaderHash
}
function Write-HotkeyDll([string]$Source, [string]$Hash, [string]$Before) {
    Assert-ShoutHash $Source $Hash; $bytes = [IO.File]::ReadAllBytes($Source)
    if ((Get-ShoutByteHash $bytes) -ne $Hash) { throw 'DLL changed while reading.' }
    Write-HotkeyData $bytes $dll $Before $Before; Assert-ShoutHash $dll $Hash
}
function Save-HotkeyState($Record) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Depth 6))
    $current = Get-ShoutFileHash $dll
    if ($current -notin @($baselineHash, $candidateHash)) { throw 'Unknown DLL: state commit refused.' }
    Write-HotkeyData $bytes $statePath $script:HotkeyStateHash $current
    $script:HotkeyStateHash = Get-ShoutByteHash $bytes
}
function Read-HotkeyState {
    $hash = Get-ShoutFileHash $statePath
    $record = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.experiment -ne 'local-hotkeys-v2' -or $record.dll_path -ne $dll -or
        $record.response_path -ne $response -or $record.library_path -ne $library -or
        $record.baseline_library_path -ne $baselineLibrary -or $record.baseline_dll_sha256 -ne $baselineHash -or
        $record.candidate_dll_sha256 -ne $candidateHash) { throw 'Unrecognized installation state.' }
    foreach ($field in @('previous_response_sha256','previous_library_sha256','installed_response_sha256','installed_library_sha256')) {
        if ($record.$field -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Missing state hash.' }
    }
    Assert-ShoutHash $dllBackup $baselineHash
    Assert-ShoutHash $responseBackup $record.previous_response_sha256
    Assert-ShoutHash $libraryBackup $record.previous_library_sha256
    Assert-ShoutHash $statePath $hash; $script:HotkeyStateHash = $hash
    return $record
}
function Restore-Hotkeys($Record, [bool]$Manual) {
    Assert-ShoutStopped
    $current = Get-ShoutFileHash $dll; $currentResponse = Get-ShoutFileHash $response
    $currentLibrary = Get-ShoutFileHash $baselineLibrary
    if ($current -notin @($baselineHash, $candidateHash)) { throw 'Unknown DLL; restore refused.' }
    # Preflight every destination before touching any of the working set.
    if (-not $Manual -and ($currentResponse -notin @($Record.previous_response_sha256, $Record.installed_response_sha256) -or
        $currentLibrary -ne $Record.previous_library_sha256)) { throw 'Concurrent data change; automatic rollback refused.' }
    if ($Manual) {
        foreach ($item in @(@($response, $currentResponse, 'response'), @($baselineLibrary, $currentLibrary, 'library'))) {
            if ($item[1]) { Backup-HotkeyFile $item[0] (Join-Path $stateRoot ($item[2] + '-preserved-' + [guid]::NewGuid().ToString('N') + '.json')) $item[1] }
        }
    }
    if ($current -eq $candidateHash) { Write-HotkeyDll $dllBackup $baselineHash $current }
    if ($currentLibrary -ne $Record.previous_library_sha256) {
        Write-HotkeyData ([IO.File]::ReadAllBytes($libraryBackup)) $baselineLibrary $currentLibrary $baselineHash
    }
    if ($currentResponse -ne $Record.previous_response_sha256) {
        Write-HotkeyData ([IO.File]::ReadAllBytes($responseBackup)) $response $currentResponse $baselineHash
    }
    Assert-ShoutHash $dll $baselineHash; Assert-ShoutHash $response $Record.previous_response_sha256
    Assert-ShoutHash $baselineLibrary $Record.previous_library_sha256
    # New messages.json, binary and every backup remain recoverable, never deleted.
}
function Install-Hotkeys($Compiled, [string]$Candidate) {
    Assert-ShoutStopped; Assert-ShoutHash $dll $baselineHash; Assert-ShoutHash $Candidate $candidateHash
    if (Test-Path -LiteralPath $stateRoot) { throw 'Existing v2 state/backups are preserved. Reinstallation requires review.' }
    if (Test-Path -LiteralPath $library) { throw 'Existing v2 library is preserved.' }
    $previousHash = Get-ShoutFileHash $response; $previousLibrary = Get-ShoutFileHash $baselineLibrary
    $v1Hash = Get-ShoutFileHash $v1StatePath
    $v1 = Get-Content -LiteralPath $v1StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($v1.experiment -ne 'local-library-v1' -or $v1.candidate_dll_sha256 -ne $baselineHash -or
        $v1.installed_response_sha256 -ne $previousHash -or $v1.installed_library_sha256 -ne $previousLibrary) {
        throw 'The known v1 DLL/library/response are not a consistent installed set.'
    }
    [void](ConvertTo-TwentyResponse (Get-Content -LiteralPath $baselineLibrary -Raw -Encoding UTF8) -MaximumSchemeBytes 8192)
    Assert-ShoutHash $v1StatePath $v1Hash; Assert-ShoutHash $response $previousHash; Assert-ShoutHash $baselineLibrary $previousLibrary
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    Backup-HotkeyFile $dll $dllBackup $baselineHash; Backup-HotkeyFile $response $responseBackup $previousHash
    Backup-HotkeyFile $baselineLibrary $libraryBackup $previousLibrary
    $record = [ordered]@{ experiment = 'local-hotkeys-v2'; status = 'prepared'; dll_path = $dll
        response_path = $response; library_path = $library; baseline_library_path = $baselineLibrary
        baseline_dll_sha256 = $baselineHash; candidate_dll_sha256 = $candidateHash
        previous_response_sha256 = $previousHash; previous_library_sha256 = $previousLibrary
        installed_response_sha256 = $Compiled.ResponseHash; installed_library_sha256 = $Compiled.LibraryHash
        installed_at = [DateTime]::UtcNow.ToString('o'); user_approved_unsigned_experiment = $true
        message_count = $Compiled.Scheme.count; library_capacity_bytes = 65536; maximum_message_count = 512
        transport_unchanged_bytes = 2046; single_message_utf16_units = 50
        runtime_verified = $false; game_send_verified = $false }
    Save-HotkeyState $record
    try {
        Write-HotkeyData $Compiled.LibraryBytes $library $null $baselineHash
        Write-HotkeyDll $Candidate $candidateHash $baselineHash
        Write-HotkeyData $Compiled.ResponseBytes $response $previousHash $candidateHash
        $record.status = 'installed-awaiting-manual-validation'; Save-HotkeyState $record
    } catch {
        $failure = $_.Exception.Message
        try { Restore-Hotkeys $record $false; $record.status = 'rolled-back-to-v1'; Save-HotkeyState $record }
        catch { Write-Warning ('Rollback needs review: ' + $_.Exception.Message + '. Backups: ' + $stateRoot) }
        throw ('Install failed: ' + $failure)
    }
    return $record
}
function Apply-Hotkeys($Compiled) {
    $record = Read-HotkeyState; Assert-ShoutStopped
    Assert-ShoutHash $dll $candidateHash; Assert-ShoutHash $library $record.installed_library_sha256
    Assert-ShoutHash $response $record.installed_response_sha256
    $beforeLibrary = $record.installed_library_sha256; $beforeResponse = $record.installed_response_sha256
    $savedLibrary = Join-Path $stateRoot ('library-before-edit-' + [guid]::NewGuid().ToString('N') + '.bin')
    $savedResponse = Join-Path $stateRoot ('response-before-edit-' + [guid]::NewGuid().ToString('N') + '.json')
    Backup-HotkeyFile $library $savedLibrary $beforeLibrary; Backup-HotkeyFile $response $savedResponse $beforeResponse
    try {
        Write-HotkeyData $Compiled.LibraryBytes $library $beforeLibrary $candidateHash
        Write-HotkeyData $Compiled.ResponseBytes $response $beforeResponse $candidateHash
        $record.installed_library_sha256 = $Compiled.LibraryHash; $record.installed_response_sha256 = $Compiled.ResponseHash
        $record.message_count = $Compiled.Scheme.count
        $record.runtime_verified = $false; $record.game_send_verified = $false
        Save-HotkeyState $record
    } catch {
        $failure = $_.Exception.Message; $nowLibrary = Get-ShoutFileHash $library; $nowResponse = Get-ShoutFileHash $response
        if ($nowLibrary -notin @($beforeLibrary, $Compiled.LibraryHash) -or $nowResponse -notin @($beforeResponse, $Compiled.ResponseHash)) {
            throw ('Concurrent data change prevents rollback; backups retained: ' + $stateRoot)
        }
        if ($nowLibrary -ne $beforeLibrary) { Write-HotkeyData ([IO.File]::ReadAllBytes($savedLibrary)) $library $nowLibrary $candidateHash }
        if ($nowResponse -ne $beforeResponse) { Write-HotkeyData ([IO.File]::ReadAllBytes($savedResponse)) $response $nowResponse $candidateHash }
        throw ('Apply rolled back: ' + $failure)
    }
}

if ($FunctionsOnly) { return }
$writeMutex = $null; $mutexHeld = $false
try {
    if ($Mode -eq 'Status') {
        Write-Host ('64 KiB independent-hotkeys installed: ' + ((Get-ShoutFileHash $dll) -eq $candidateHash))
        Write-Host ('Known 8 KiB v1 DLL: ' + ((Get-ShoutFileHash $dll) -eq $baselineHash))
        Write-Host ('Known loader: ' + ((Get-ShoutFileHash $loader) -eq $loaderHash))
        Write-Host ('Editable source: ' + $SchemePath)
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $record = Read-HotkeyState
            Write-Host ('State: ' + $record.status)
            Write-Host ('Local library matching: ' + ((Get-ShoutFileHash $library) -eq $record.installed_library_sha256))
            Write-Host ('Bootstrap matching: ' + ((Get-ShoutFileHash $response) -eq $record.installed_response_sha256))
            Write-Host ('Messages: ' + $record.message_count + '; capacity: 65536 bytes; count ceiling: 512')
        }
        Write-Host 'Readback proves file consistency only; actual game sending requires manual verification.'; exit 0
    }
    if ($Mode -eq 'Validate') {
        $document = Read-HotkeyDocument $SchemePath
        Write-Host ('VALID: ' + $document.Compiled.Scheme.count + ' messages; ' + $document.Compiled.LibraryBytes.Length + ' / 65536 bytes. No live changes.'); exit 0
    }
    Assert-HotkeyProfile
    $writeMutex = New-Object Threading.Mutex($false, 'Local\LOLPallas-HotkeysV2-zly')
    try { $mutexHeld = $writeMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
    if (-not $mutexHeld) { throw 'Another v2 install/apply/restore is running. No files changed; retry after it finishes.' }
    if ($Mode -eq 'Restore') {
        $record = Read-HotkeyState
        if ($PSCmdlet.ShouldProcess($dll, 'Restore the user-tested 8 KiB v1 DLL/library/response; retain all v2 text and backups')) {
            Restore-Hotkeys $record $true; $record.status = 'restored-to-v1'; Save-HotkeyState $record
            Write-Host 'RESTORED to the previous 8 KiB / twenty-message v1. All v2 text and backups retained.'
        }; exit 0
    }
    $document = Read-HotkeyDocument $SchemePath
    if ($Mode -eq 'Apply') {
        if ($PSCmdlet.ShouldProcess($library, 'Apply local messages and independent bindings; no game messages sent')) {
            Assert-ShoutHash $SchemePath $document.Hash; Apply-Hotkeys $document.Compiled
            Write-Host 'APPLIED AND READ BACK. Restart WeGame manually. No game sends.'
        }; exit 0
    }
    if (-not $AcceptUnsignedExperiment) { throw 'Install requires explicit -AcceptUnsignedExperiment.' }
    $candidate = Join-Path $BuildDirectory 'TenPallas.hotkeys.experimental.dll'
    Assert-ShoutHash $candidate $candidateHash
    if ((Get-AuthenticodeSignature -LiteralPath $candidate).Status.ToString() -ne 'HashMismatch') { throw 'Unexpected signature result. Do not bypass validation.' }
    $validation = Get-Content -LiteralPath (Join-Path $BuildDirectory 'validation.hotkeys.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($validation.candidate_dll_sha256 -ne $candidateHash -or $validation.unit_tests_passed -ne $true -or
        $validation.unit_tests -ne 8 -or $validation.native.passed -ne $true -or $validation.native.cases -lt 123 -or
        $validation.native_file_io.passed -ne $true -or $validation.native_file_io.cases -lt 16) { throw 'Required offline validation missing/mismatched.' }
    if ($PSCmdlet.ShouldProcess($dll, 'Install unsigned 64 KiB independent-hotkey candidate; back up the user-tested 8 KiB v1')) {
        Assert-ShoutHash $SchemePath $document.Hash; [void](Install-Hotkeys $document.Compiled $candidate)
        Write-Host 'INSTALLED AND READ BACK. Actual WeGame loading and game sending remain UNVERIFIED.'
        Write-Host 'Start WeGame manually; test in training only. If integrity/loading rejects it, restore; never bypass checks.'
    }; exit 0
} catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($mutexHeld) { $writeMutex.ReleaseMutex() }; if ($writeMutex) { $writeMutex.Dispose() } }
