# Restore ONLY the pinned signed stock DLL. No launcher/config/data restoration.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$WeGameRoot, [string]$ExpectedSid, [switch]$FunctionsOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\NativeKeyTools.ps1')
$script:OriginalDllHash = $script:PortableOriginalHash
function Assert-OriginalDll([string]$Path) {
    Assert-ShoutHash $Path $script:OriginalDllHash
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status.ToString() -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Tencent Technology \(Shenzhen\) Company Limited') {
        throw 'Pinned original Tencent signature verification failed.'
    }
    Assert-ShoutHash $Path $script:OriginalDllHash
}
function Restore-OriginalDllOnly($Context, [string]$OriginalPath) {
    Assert-ShoutStopped; Assert-PortableLoader $Context
    $record = Read-PortableState $Context
    Assert-OriginalDll $OriginalPath
    if ($record.status -eq 'original-dll-restored') {
        Assert-OriginalDll $Context.Dll
        Write-Host 'Original signed DLL already restored; launcher and texts unchanged.'; return $null
    }
    if ($record.candidate_dll_sha256 -ne $script:NativeKeysHash) { throw 'Unsupported restoration source; no changes.' }
    $beforeDll = $record.candidate_dll_sha256
    Assert-ShoutHash $Context.Dll $beforeDll
    Assert-ShoutHash $Context.Library $record.installed_library_sha256
    Assert-ShoutHash $Context.Source $record.installed_source_sha256
    $stateBefore = [IO.File]::ReadAllBytes($Context.State); $stateHash = $Context.StateHash
    $originalBytes = [IO.File]::ReadAllBytes($OriginalPath)
    if ((Get-ShoutByteHash $originalBytes) -ne $script:OriginalDllHash) { throw 'Original source changed.' }
    $backup = Join-Path $Context.Data ('backups\original-dll-restore-' + [guid]::NewGuid().ToString('N'))
    [void](Assert-PortablePath $backup); [void](New-Item -ItemType Directory -Path $backup)
    Backup-PortableFile $Context.Dll (Join-Path $backup 'TenPallas.previous.dll') $beforeDll
    Backup-PortableFile $Context.State (Join-Path $backup 'state.previous.json') $stateHash
    $updated = $record | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $updated.status = 'original-dll-restored'; $updated.keyboard_mode = 'original'
    $updated.runtime_verified = $false; $updated.game_send_verified = $false
    $updated | Add-Member -NotePropertyName original_dll_sha256 -NotePropertyValue $script:OriginalDllHash -Force
    $updated | Add-Member -NotePropertyName original_dll_restored_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $updated | Add-Member -NotePropertyName original_dll_restore_backup -NotePropertyValue $backup -Force
    $stateBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($updated | ConvertTo-Json -Depth 5))
    $afterStateHash = Get-ShoutByteHash $stateBytes
    try {
        Assert-ShoutHash $Context.State $stateHash
        Write-PortableFile $Context $originalBytes $Context.Dll $beforeDll $beforeDll
        Assert-OriginalDll $Context.Dll
        Assert-ShoutHash $Context.Library $record.installed_library_sha256
        Assert-ShoutHash $Context.Source $record.installed_source_sha256
        Write-PortableFile $Context $stateBytes $Context.State $stateHash $script:OriginalDllHash
        Assert-ShoutHash $Context.State $afterStateHash
        $Context.StateHash = $afterStateHash
    } catch {
        $failure = $_.Exception.Message
        $currentDll = Get-ShoutFileHash $Context.Dll; $currentState = Get-ShoutFileHash $Context.State
        if ($currentDll -notin @($beforeDll,$script:OriginalDllHash) -or $currentState -notin @($stateHash,$afterStateHash)) {
            throw ('Concurrent change; rollback refused, backups retained: ' + $backup)
        }
        if ($currentDll -ne $beforeDll) { Write-PortableFile $Context ([IO.File]::ReadAllBytes((Join-Path $backup 'TenPallas.previous.dll'))) $Context.Dll $currentDll $currentDll }
        if ($currentState -ne $stateHash) { Write-PortableFile $Context $stateBefore $Context.State $currentState $beforeDll }
        $Context.StateHash = $stateHash
        throw ('Restore failed; previous DLL/state recovered: ' + $failure)
    }
    Write-Host 'ORIGINAL DLL RESTORED: pinned hash and valid Tencent signature read back. Launcher/texts untouched.'
    Write-Host ('Backup: ' + $backup)
    return $updated
}
if ($FunctionsOnly) { return }
$mutex = $null; $held = $false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Elevation changed Windows accounts; no files changed.' }
    $data = Get-PortableDataRoot
    $context = New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    $mutexId = (Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex = New-Object Threading.Mutex($false,('Global\LOLPallasPortable-' + $mutexId))
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another installation/apply/restore is running.' }
    if ($PSCmdlet.ShouldProcess($context.Dll,'Restore signed WeGame original DLL only; keep all texts and backups')) {
        [void](Restore-OriginalDllOnly $context (Join-Path $PSScriptRoot 'engine\assets\TenPallas.original.dll'))
    }
    exit 0
} catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
