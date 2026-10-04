[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Status', 'Validate', 'Install', 'Apply', 'Restore')][string]$Mode = 'Status',
    [switch]$AcceptUnsignedExperiment,
    [switch]$FunctionsOnly,
    [string]$SchemePath,
    [string]$BuildDirectory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $SchemePath) { $SchemePath = Join-Path $PSScriptRoot 'scheme20.example.json' }
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $root 'build\local-library-v1' }
. (Join-Path $root 'lib\LibraryTools.ps1')
$dll = 'D:\Program Files (x86)\WeGame\apps\Pallas\tp_deps\TenPallas.dll'
$loader = 'D:\Program Files (x86)\WeGame\apps\Pallas\pallas.exe'
$baselineHash = '3BCEFF093D67F86400DD0F3F1ECE50F812D531926D5FF64CF72C227904DA5D00'
$candidateHash = 'BEB422999A6E8E7F87D93937D9010B15DCAAACCE237FD7B11C280D5CF88CCA10'
$loaderHash = '803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935'
$dataRoot = 'C:\Users\zly\AppData\Local\PallasCustomShout'
$response = Join-Path $dataRoot 'local-response.json'
$library = Join-Path $dataRoot 'library20-v1.json'
$stateRoot = Join-Path $dataRoot 'LocalLibraryExperiment'
$statePath = Join-Path $stateRoot 'state.json'
$dllBackup = Join-Path $stateRoot 'TenPallas.before-library.dll'
$responseBackup = Join-Path $stateRoot 'response.before-library.json'
$script:StateHash = $null

function Assert-Profile {
    if ([IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'PallasCustomShout')) -ne $dataRoot) {
        throw 'This experiment is pinned to the existing zly profile and loader.'
    }
    Assert-ShoutHash $loader $loaderHash
}
function Backup-File([string]$Source, [string]$Destination, [string]$Hash) {
    Assert-ShoutHash $Source $Hash
    [IO.File]::Copy($Source, $Destination, $false)
    Assert-ShoutHash $Destination $Hash
}
function Save-State($Record) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Depth 6))
    $currentDll = Get-ShoutFileHash $dll
    if ($currentDll -notin @($baselineHash, $candidateHash)) { throw 'Unknown DLL; state commit refused.' }
    Write-LibraryFile $bytes $statePath $script:StateHash $dll $currentDll $loader $loaderHash
    $script:StateHash = Get-ShoutByteHash $bytes
}
function Read-State {
    $beforeHash = Get-ShoutFileHash $statePath
    $record = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.experiment -ne 'local-library-v1' -or $record.dll_path -ne $dll -or
        $record.library_path -ne $library -or $record.response_path -ne $response -or
        $record.baseline_dll_sha256 -ne $baselineHash -or $record.candidate_dll_sha256 -ne $candidateHash -or
        $record.previous_response_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $record.installed_library_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $record.installed_response_sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Unrecognized experiment state.' }
    Assert-ShoutHash $dllBackup $baselineHash
    Assert-ShoutHash $responseBackup $record.previous_response_sha256
    Assert-ShoutHash $statePath $beforeHash
    $script:StateHash = $beforeHash
    return $record
}
function Write-Data([byte[]]$Bytes, [string]$Path, $Before, [string]$ExpectedDll) {
    Write-LibraryFile $Bytes $Path $Before $dll $ExpectedDll $loader $loaderHash
}
function Write-Dll([string]$Source, [string]$NewHash, [string]$Before) {
    Assert-ShoutHash $Source $NewHash
    $bytes = [IO.File]::ReadAllBytes($Source)
    if ((Get-ShoutByteHash $bytes) -ne $NewHash) { throw 'DLL source changed during read; replacement refused.' }
    # Validate current DLL before staging. Writer also rechecks before commit.
    Write-Data $bytes $dll $Before $Before
    Assert-ShoutHash $dll $NewHash
}
function Restore-Baseline($Record, [bool]$Manual) {
    Assert-ShoutStopped
    $currentDll = Get-ShoutFileHash $dll
    if ($currentDll -notin @($baselineHash, $candidateHash)) { throw 'Unknown/updated DLL; restoration refused.' }
    $currentResponse = Get-ShoutFileHash $response
    if ($currentResponse -ne $Record.previous_response_sha256) {
        if (-not $Manual -and $currentResponse -ne $Record.installed_response_sha256) {
            throw 'Concurrent response change; automatic rollback refused.'
        }
        if ($Manual -and $currentResponse) {
            Backup-File $response (Join-Path $stateRoot ('response-preserved-' + [guid]::NewGuid().ToString('N') + '.json')) $currentResponse
        }
    }
    if ($currentDll -eq $candidateHash) { Write-Dll $dllBackup $baselineHash $candidateHash }
    if ($currentResponse -ne $Record.previous_response_sha256) {
        Write-Data ([IO.File]::ReadAllBytes($responseBackup)) $response $currentResponse $baselineHash
    }
    # Keep the library on restore. It is inert without the experimental DLL;
    # edited text must never be deleted as part of an executable rollback.
    Assert-ShoutHash $dll $baselineHash
    Assert-ShoutHash $response $Record.previous_response_sha256
}

if ($FunctionsOnly) { return }

try {
    if ($Mode -eq 'Status') {
        Write-Host ('Experimental DLL matching: ' + ((Get-ShoutFileHash $dll) -eq $candidateHash))
        Write-Host ('Baseline twenty DLL matching: ' + ((Get-ShoutFileHash $dll) -eq $baselineHash))
        Write-Host ('Required local loader matching: ' + ((Get-ShoutFileHash $loader) -eq $loaderHash))
        Write-Host ('Source to edit: ' + $SchemePath)
        Write-Host ('Local library: ' + $library)
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $record = Read-State
            Write-Host ('State: ' + $record.status)
            Write-Host ('Library readback matching: ' + ((Get-ShoutFileHash $library) -eq $record.installed_library_sha256))
            Write-Host ('Bootstrap readback matching: ' + ((Get-ShoutFileHash $response) -eq $record.installed_response_sha256))
        }
        Write-Host 'Hash checks do not prove real WeGame loading or game sending.'
        exit 0
    }
    Assert-Profile
    if ($Mode -eq 'Restore') {
        $record = Read-State
        if (-not $PSCmdlet.ShouldProcess($dll, 'Restore the PRE-LIBRARY TWENTY-message DLL and response; keep all text/backups')) { exit 0 }
        Restore-Baseline $record $true
        $record.status = 'restored-to-twenty'
        Save-State $record
        Write-Host 'RESTORED to the previous twenty-message version and response. Library retained but unused.'
        exit 0
    }
    $sourceHash = Get-ShoutFileHash $SchemePath
    $compiled = ConvertTo-LibraryArtifacts (Get-Content -LiteralPath $SchemePath -Raw -Encoding UTF8)
    Assert-ShoutHash $SchemePath $sourceHash
    Write-Host ('VALID: full library ' + $compiled.LibraryBytes.Length + ' / 8192 bytes; bootstrap ' + $compiled.BootstrapBytes + ' / 2046 bytes.')
    if ($Mode -eq 'Validate') { Write-Host 'Offline only. No live files changed.'; exit 0 }
    if ($Mode -eq 'Apply') {
        $record = Read-State
        Assert-ShoutHash $dll $candidateHash
        Assert-ShoutHash $library $record.installed_library_sha256
        Assert-ShoutHash $response $record.installed_response_sha256
        if (-not $PSCmdlet.ShouldProcess($library, 'Back up and apply twenty local-library messages; no game sends')) { exit 0 }
        Assert-ShoutStopped
        Assert-ShoutHash $SchemePath $sourceHash
        $beforeLibrary = Get-ShoutFileHash $library
        $beforeResponse = Get-ShoutFileHash $response
        $savedLibrary = Join-Path $stateRoot ('library-before-edit-' + [guid]::NewGuid().ToString('N') + '.json')
        $savedResponse = Join-Path $stateRoot ('response-before-edit-' + [guid]::NewGuid().ToString('N') + '.json')
        Backup-File $library $savedLibrary $beforeLibrary
        Backup-File $response $savedResponse $beforeResponse
        try {
            Write-Data $compiled.LibraryBytes $library $beforeLibrary $candidateHash
            Write-Data $compiled.ResponseBytes $response $beforeResponse $candidateHash
            $record.installed_library_sha256 = $compiled.LibraryHash
            $record.installed_response_sha256 = $compiled.ResponseHash
            Save-State $record
        } catch {
            $failure = $_.Exception.Message
            $nowLibrary = Get-ShoutFileHash $library
            $nowResponse = Get-ShoutFileHash $response
            if ($nowLibrary -notin @($beforeLibrary, $compiled.LibraryHash) -or
                $nowResponse -notin @($beforeResponse, $compiled.ResponseHash)) {
                throw ('Apply failed and a concurrent change prevents rollback. Backups kept: ' + $stateRoot)
            }
            if ($nowLibrary -ne $beforeLibrary) { Write-Data ([IO.File]::ReadAllBytes($savedLibrary)) $library $nowLibrary $candidateHash }
            if ($nowResponse -ne $beforeResponse) { Write-Data ([IO.File]::ReadAllBytes($savedResponse)) $response $nowResponse $candidateHash }
            $record.installed_library_sha256 = $beforeLibrary
            $record.installed_response_sha256 = $beforeResponse
            Save-State $record
            throw ('Apply rolled back: ' + $failure)
        }
        Write-Host 'APPLIED AND READ BACK. Start WeGame manually. No messages sent.'
        exit 0
    }
    if (-not $AcceptUnsignedExperiment) { throw 'Install needs explicit -AcceptUnsignedExperiment approval.' }
    Assert-ShoutHash $dll $baselineHash
    if (Test-Path -LiteralPath $stateRoot) { throw 'Existing experiment state is preserved; do not reinstall over backups.' }
    if (Test-Path -LiteralPath $library) { throw 'Existing library is preserved; installation requires separate review.' }
    $candidate = Join-Path $BuildDirectory 'TenPallas.library.experimental.dll'
    Assert-ShoutHash $candidate $candidateHash
    if ((Get-AuthenticodeSignature -LiteralPath $candidate).Status.ToString() -ne 'HashMismatch') {
        throw 'Unexpected signature result; review candidate structure rather than bypass validation.'
    }
    $validation = Get-Content -LiteralPath (Join-Path $BuildDirectory 'validation.library.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($validation.candidate_dll_sha256 -ne $candidateHash -or $validation.unit_tests_passed -ne $true -or
        $validation.unit_tests -ne 7 -or $validation.native.passed -ne $true -or $validation.native.cases -ne 63 -or
        $validation.native_file_io.passed -ne $true -or $validation.native_file_io.cases -ne 3) {
        throw 'Expected offline validation is missing or mismatched.'
    }
    $previousHash = Get-ShoutFileHash $response
    $previous = Read-ShoutScheme $response
    foreach ($i in 0..19) { if ($previous.Scheme.($i.ToString()) -isnot [string]) { throw 'Expected current twenty-message response.' } }
    if (-not $PSCmdlet.ShouldProcess($dll, 'Install experimental UNSIGNED local-library component, backed up to the current twenty version')) { exit 0 }
    Assert-ShoutStopped
    Assert-ShoutHash $SchemePath $sourceHash
    Assert-ShoutHash $dll $baselineHash
    Assert-ShoutHash $response $previousHash
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    Backup-File $dll $dllBackup $baselineHash
    Backup-File $response $responseBackup $previousHash
    $record = [ordered]@{
        experiment = 'local-library-v1'; status = 'prepared'; dll_path = $dll
        response_path = $response; library_path = $library
        baseline_dll_sha256 = $baselineHash; candidate_dll_sha256 = $candidateHash
        previous_response_sha256 = $previousHash
        installed_library_sha256 = $compiled.LibraryHash; installed_response_sha256 = $compiled.ResponseHash
        installed_at = [DateTime]::UtcNow.ToString('o'); user_approved_unsigned_experiment = $true
        message_count = 20; library_capacity_bytes = 8192; transport_unchanged_bytes = 2046
        runtime_verified = $false; game_send_verified = $false
    }
    Save-State $record
    try {
        Write-Data $compiled.LibraryBytes $library $null $baselineHash
        Write-Dll $candidate $candidateHash $baselineHash
        Write-Data $compiled.ResponseBytes $response $previousHash $candidateHash
        $record.status = 'installed-awaiting-manual-validation'
        Save-State $record
    } catch {
        $failure = $_.Exception.Message
        try {
            Restore-Baseline $record $false
            $record.status = 'rolled-back-to-twenty'
            Save-State $record
        } catch {
            Write-Warning ('Rollback needs review: ' + $_.Exception.Message + '. Backups: ' + $stateRoot)
        }
        throw ('Install failed: ' + $failure)
    }
    Write-Host 'INSTALLED AND READ BACK. Real WeGame loading and actual game sending remain UNVERIFIED.'
    Write-Host 'Start WeGame manually and test messages 1 and 20 ONLY in training/private testing.'
    Write-Host 'If loading is refused or abnormal, stop and Restore. Never bypass integrity or anti-cheat checks.'
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
