[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Status', 'Install', 'Restore')][string]$Mode = 'Status',
    [switch]$AcceptUnsignedExperiment,
    [string]$BuildDirectory = (Join-Path $PSScriptRoot 'assets')
)

$ErrorActionPreference = 'Stop'
$DllPath = 'D:\Program Files (x86)\WeGame\apps\Pallas\tp_deps\TenPallas.dll'
$PallasPath = 'D:\Program Files (x86)\WeGame\apps\Pallas\pallas.exe'
$OriginalDllHash = '97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94'
$CandidateDllHash = '3BCEFF093D67F86400DD0F3F1ECE50F812D531926D5FF64CF72C227904DA5D00'
$PallasHash = '803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935'
$CandidateResponseHash = '9968B92BCFA0F5A9772F7B68EF31D7E89FFCB558FDCBC5E24675F58456C2A5A9'
$TemplateHash = '49B6D6992A3C0BC82D004BDCFAF36C7A4792EDF08238B601901B1D0BA2086089'
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is missing.' }
$DataDirectory = Join-Path $env:LOCALAPPDATA 'PallasCustomShout'
$ResponsePath = Join-Path $DataDirectory 'local-response.json'
$StateDirectory = Join-Path $DataDirectory 'TwentyMessageExperiment'
$StatePath = Join-Path $StateDirectory 'state.json'
$DllBackup = Join-Path $StateDirectory 'TenPallas.before-twenty.dll'
$ResponseBackup = Join-Path $StateDirectory 'response.before-twenty.json'
$InstalledResponseSource = Join-Path $StateDirectory 'response.installed-twenty.json'
$TemplatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scheme20.example.json'

function Get-ContentHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [System.IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-ContentHash $Path) -ne $Expected) { throw ('Hash mismatch or missing file: ' + $Path) }
}

function Assert-Stopped {
    $active = @(Get-Process | Where-Object {
        $_.ProcessName -match '^(wegame|pallas|League of Legends|LeagueClient|LeagueClientUx|LeagueClientUxRender|tgp_daemon|TenPallas)$'
    })
    if ($active.Count -gt 0) {
        $names = ($active | ForEach-Object { $_.ProcessName + ' (PID ' + $_.Id + ')' }) -join ', '
        throw ('Finish and exit the game; exit WeGame from the tray first. Running: ' + $names)
    }
}

function Assert-OriginalDll([string]$Path) {
    Assert-Hash $Path $OriginalDllHash
    if ((Get-AuthenticodeSignature -LiteralPath $Path).Status.ToString() -ne 'Valid') {
        throw ('Original Tencent DLL signature is not valid: ' + $Path)
    }
}

function Replace-VerifiedFile([string]$Source, [string]$SourceHash,
                              [string]$Destination, $ExpectedCurrentHash) {
    $directory = Split-Path -Parent $Destination
    $stage = Join-Path $directory ('pallas-twenty-stage-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::Copy($Source, $stage, $false)
        Assert-Hash $stage $SourceHash
        Assert-Stopped
        if ((Get-ContentHash $Destination) -ne $ExpectedCurrentHash) {
            throw ('Destination changed; refusing replacement: ' + $Destination)
        }
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [System.IO.File]::Replace($stage, $Destination, [NullString]::Value)
        } else {
            [System.IO.File]::Move($stage, $Destination)
        }
        Assert-Hash $Destination $SourceHash
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage }
    }
}

function Save-State($Record) {
    $stage = Join-Path $StateDirectory ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($stage, ($Record | ConvertTo-Json -Depth 8), $utf8)
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            [System.IO.File]::Replace($stage, $StatePath, [NullString]::Value)
        } else {
            [System.IO.File]::Move($stage, $StatePath)
        }
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage }
    }
}

function Read-ResponseScheme([string]$Path) {
    $envelope = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($envelope.result.error_code -ne 0 -or $envelope.shout_message -isnot [string]) {
        throw ('Invalid local response envelope: ' + $Path)
    }
    $raw = [Convert]::FromBase64String($envelope.shout_message)
    if ($raw.Length -gt 2046) { throw 'Decoded whole scheme exceeds the existing 2046-byte transport.' }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return ($strictUtf8.GetString($raw) | ConvertFrom-Json)
}

function Assert-TestResponse([string]$Path) {
    Assert-Hash $Path $CandidateResponseHash
    Assert-Hash $TemplatePath $TemplateHash
    $scheme = Read-ResponseScheme $Path
    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $names = @($scheme.PSObject.Properties | ForEach-Object { $_.Name })
    $expected = @('title', 'key') + @(0..19 | ForEach-Object { $_.ToString() })
    if ($names.Count -ne 22 -or @(Compare-Object $names $expected).Count -ne 0) {
        throw 'Twenty exact numeric message keys plus title/key are required.'
    }
    foreach ($name in $expected) {
        if ($scheme.$name -cne $template.$name) { throw ('Response differs from test template: ' + $name) }
    }
    if ($scheme.key -ne 1) { throw 'This approved test uses the tilde panel key.' }
    foreach ($index in 0..19) {
        $message = $scheme.($index.ToString())
        if ($message -isnot [string] -or [string]::IsNullOrWhiteSpace($message) -or
            $message.Length -gt 50 -or $message -match '[\x00-\x1F\x7F]') {
            throw ('Test message guard failed at entry ' + ($index + 1))
        }
    }
}

function Assert-State($Record) {
    if ($Record.experiment -ne 'Pallas twenty messages v2' -or
        $Record.dll_path -ne $DllPath -or $Record.response_path -ne $ResponsePath -or
        $Record.dll_backup_path -ne $DllBackup -or $Record.response_backup_path -ne $ResponseBackup -or
        $Record.original_dll_sha256 -ne $OriginalDllHash -or
        $Record.candidate_dll_sha256 -ne $CandidateDllHash -or
        $Record.candidate_response_sha256 -ne $CandidateResponseHash -or
        $Record.previous_response_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Installation state does not match this exact experiment and profile.'
    }
    Assert-OriginalDll $DllBackup
    Assert-Hash $ResponseBackup $Record.previous_response_sha256
}

function Restore-Pair($Record, [bool]$PreserveEditedResponse) {
    Assert-Stopped
    Assert-State $Record
    $currentDll = Get-ContentHash $DllPath
    if ($currentDll -ne $OriginalDllHash -and $currentDll -ne $CandidateDllHash) {
        throw 'DLL was changed/updated; refusing to overwrite an unknown version.'
    }
    $currentResponse = Get-ContentHash $ResponsePath
    $known = ($currentResponse -eq $CandidateResponseHash -or
              $currentResponse -eq $Record.previous_response_sha256 -or -not $currentResponse)
    if (-not $known) {
        if (-not $PreserveEditedResponse) {
            throw 'Response changed during installation; automatic rollback will not overwrite it.'
        }
        $preserved = Join-Path $StateDirectory ('response-preserved-' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::Copy($ResponsePath, $preserved, $false)
        Assert-Hash $preserved $currentResponse
        Write-Host ('Preserved edited response: ' + $preserved)
    }
    if ($currentDll -eq $CandidateDllHash) {
        Replace-VerifiedFile $DllBackup $OriginalDllHash $DllPath $CandidateDllHash
    }
    Assert-OriginalDll $DllPath
    if ($currentResponse -ne $Record.previous_response_sha256) {
        Replace-VerifiedFile $ResponseBackup $Record.previous_response_sha256 $ResponsePath $currentResponse
    }
    Assert-Hash $ResponsePath $Record.previous_response_sha256
}

function Show-Status {
    $dll = Get-ContentHash $DllPath
    $kind = 'UNKNOWN - do not overwrite'
    if ($dll -eq $OriginalDllHash) { $kind = 'ORIGINAL TEN-MESSAGE DLL' }
    if ($dll -eq $CandidateDllHash) { $kind = 'TWENTY-MESSAGE EXPERIMENT DLL' }
    Write-Host ('DLL: ' + $kind)
    Write-Host ('DLL SHA256: ' + $dll)
    if ($dll) { Write-Host ('DLL Authenticode: ' + (Get-AuthenticodeSignature -LiteralPath $DllPath).Status) }
    Write-Host ('Local-file Pallas loader unchanged/matching: ' + ((Get-ContentHash $PallasPath) -eq $PallasHash))
    Write-Host ('Twenty short test response matching: ' + ((Get-ContentHash $ResponsePath) -eq $CandidateResponseHash))
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $record = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ('Saved state: ' + $record.status)
        Write-Host ('Original DLL backup matching: ' + ((Get-ContentHash $DllBackup) -eq $OriginalDllHash))
        Write-Host ('Previous response backup matching: ' + ((Get-ContentHash $ResponseBackup) -eq $record.previous_response_sha256))
    }
    Write-Host 'Installation/hash checks are not proof of WeGame loading or actual game sending.'
}

try {
    if ($Mode -eq 'Status') { Show-Status; exit 0 }
    if ([System.IO.Path]::GetFullPath($ResponsePath) -ne 'C:\Users\zly\AppData\Local\PallasCustomShout\local-response.json') {
        throw 'The prerequisite Pallas loader is profile-specific; another account is not supported.'
    }
    Assert-Stopped
    if ($Mode -eq 'Restore') {
        if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'No installation state; nothing changed.' }
        $record = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-State $record
        if (-not $PSCmdlet.ShouldProcess($DllPath, 'Restore original DLL and pre-twenty response; preserve any edited twenty-response')) { exit 0 }
        Restore-Pair $record $true
        $record.status = 'restored'
        $record | Add-Member -NotePropertyName restored_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Save-State $record
        Write-Host 'RESTORED: signed original game-side DLL and the previous local ten-message response.'
        Write-Host 'Pallas EXE and source configs were not changed. All backups were kept.'
        exit 0
    }
    if (-not $AcceptUnsignedExperiment) { throw 'Install requires explicit -AcceptUnsignedExperiment approval.' }
    if (Test-Path -LiteralPath $StateDirectory) { throw 'Backup/state directory already exists; use Status/Restore, do not overwrite backups.' }
    $build = (Resolve-Path -LiteralPath $BuildDirectory).Path
    $candidate = Join-Path $build 'TenPallas.twenty.experimental.dll'
    $responseSource = Join-Path $build 'local-response20.json'
    $originalSource = Join-Path $build 'TenPallas.original.dll'
    $validation = Get-Content -LiteralPath (Join-Path $build 'validation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($validation.candidate_dll_sha256 -ne $CandidateDllHash -or
        $validation.offline_unit_tests_passed -ne $true -or $validation.offline_unit_tests -ne 10 -or
        $validation.isolated_native.passed -ne $true -or $validation.isolated_native.cases.f10_system_event_cases -ne 18) {
        throw 'Expected offline validation record is missing or inconsistent.'
    }
    Assert-Hash $PallasPath $PallasHash
    Assert-OriginalDll $DllPath
    Assert-OriginalDll $originalSource
    Assert-Hash $candidate $CandidateDllHash
    if ((Get-AuthenticodeSignature -LiteralPath $candidate).Status.ToString() -ne 'HashMismatch') {
        throw 'Unexpected candidate signature result; review rather than bypass validation.'
    }
    Assert-TestResponse $responseSource
    $previousHash = Get-ContentHash $ResponsePath
    if (-not $previousHash) { throw 'The pre-existing local response must be backed up, not guessed.' }
    $previousScheme = Read-ResponseScheme $ResponsePath
    if (@($previousScheme.PSObject.Properties).Count -ne 12) { throw 'Expected the pre-existing ten-message scheme.' }
    foreach ($index in 0..9) {
        if ($previousScheme.($index.ToString()) -isnot [string]) { throw 'Pre-existing scheme is not ten string messages.' }
    }
    if (-not $PSCmdlet.ShouldProcess($DllPath, 'Back up DLL and current response; install approved unsigned twenty-message short-text experiment')) { exit 0 }

    Assert-Stopped
    New-Item -ItemType Directory -Path $StateDirectory | Out-Null
    [System.IO.File]::Copy($DllPath, $DllBackup, $false)
    Assert-OriginalDll $DllBackup
    [System.IO.File]::Copy($ResponsePath, $ResponseBackup, $false)
    Assert-Hash $ResponseBackup $previousHash
    [System.IO.File]::Copy($responseSource, $InstalledResponseSource, $false)
    Assert-TestResponse $InstalledResponseSource
    $record = [ordered]@{
        experiment = 'Pallas twenty messages v2'
        status = 'prepared'
        dll_path = $DllPath
        response_path = $ResponsePath
        dll_backup_path = $DllBackup
        response_backup_path = $ResponseBackup
        original_dll_sha256 = $OriginalDllHash
        candidate_dll_sha256 = $CandidateDllHash
        previous_response_sha256 = $previousHash
        candidate_response_sha256 = $CandidateResponseHash
        unchanged_pallas_sha256 = $PallasHash
        user_approved_unsigned_experiment = $true
        installed_at = [DateTime]::UtcNow.ToString('o')
        file_readback_verified = $false
        native_runtime_verified = $false
        game_send_verified = $false
        message_count = 20
        visible_native_panel_messages = 10
    }
    Save-State $record
    try {
        Replace-VerifiedFile $InstalledResponseSource $CandidateResponseHash $ResponsePath $previousHash
        Replace-VerifiedFile $candidate $CandidateDllHash $DllPath $OriginalDllHash
        Assert-Stopped
        Assert-Hash $PallasPath $PallasHash
        Assert-Hash $DllPath $CandidateDllHash
        Assert-TestResponse $ResponsePath
        $record.status = 'installed-awaiting-manual-validation'
        $record.file_readback_verified = $true
        Save-State $record
    } catch {
        $failure = $_.Exception.Message
        $record['failure'] = $failure
        try {
            Restore-Pair $record $false
            $record.status = 'rolled-back'
            Save-State $record
        } catch {
            $record.status = 'restore-pending'
            try { Save-State $record } catch { Write-Warning 'Could not save rollback state.' }
            Write-Warning ('Rollback needs attention: ' + $_.Exception.Message)
            Write-Warning ('Close the game/WeGame and use Restore. Backups: ' + $StateDirectory)
        }
        throw ('Installation failed: ' + $failure)
    }
    Write-Host 'INSTALLED AND READ BACK: twenty-message DLL plus twenty short test messages.'
    Write-Host 'Pallas EXE, game files and original source configs were not changed.'
    Write-Host ('Verified DLL and previous response backups: ' + $StateDirectory)
    Write-Host 'Start WeGame manually. Test only in training mode; no messages were sent by this installer.'
    Write-Host 'If normal loading is refused or the game exits, stop and Restore; do not bypass validation.'
    Show-Status
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
