# Restore the known original launcher after the signed original DLL restoration.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$WeGameRoot, [string]$ExpectedSid, [switch]$FunctionsOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\NativeKeyTools.ps1')
$script:OriginalDllHash = $script:PortableOriginalHash
$script:OriginalLauncherHash = $script:PortableLoaderHash
$script:ModifiedLauncherHash = $script:PortableV2LoaderHash
function Assert-SignedTencentFile([string]$Path,[string]$Hash) {
    Assert-ShoutHash $Path $Hash
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status.ToString() -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Tencent Technology \(Shenzhen\) Company Limited') {
        throw 'Original Tencent launcher signature verification failed.'
    }
    Assert-ShoutHash $Path $Hash
}
function Assert-OriginalLauncher([string]$Path) { Assert-SignedTencentFile $Path $script:OriginalLauncherHash }
function Assert-OriginalDll([string]$Path) { Assert-SignedTencentFile $Path $script:OriginalDllHash }
function Restore-OriginalLauncherOnly($Context,[string]$OriginalPath,[string]$LegacyState) {
    Assert-ShoutStopped; Assert-PortableLoader $Context; Assert-OriginalDll $Context.Dll
    $record = Read-PortableState $Context
    Assert-OriginalLauncher $OriginalPath
    $legacyHash = Get-ShoutFileHash $LegacyState
    $legacy = Get-Content -LiteralPath $LegacyState -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($legacy.experiment -ne 'Pallas local-file scheme v1' -or $legacy.program_path -ne $Context.Loader -or
        $legacy.backup_path -ne $OriginalPath -or $legacy.original_sha256 -ne $script:OriginalLauncherHash -or
        $legacy.candidate_sha256 -ne $script:ModifiedLauncherHash) { throw 'Unknown launcher installation record; no changes.' }
    Assert-ShoutHash $LegacyState $legacyHash
    if ($record.status -eq 'original-components-restored' -and $legacy.status -eq 'restored') {
        Assert-OriginalLauncher $Context.Loader; Write-Host 'Original launcher and DLL already restored.'; return $null
    }
    if ($record.status -ne 'original-dll-restored' -or $legacy.status -ne 'installed' -or
        $record.candidate_dll_sha256 -ne $script:NativeKeysHash -or
        $record.loader_sha256 -ne $script:ModifiedLauncherHash) { throw 'Restore the original DLL first; unsupported current state.' }
    Assert-ShoutHash $Context.Loader $script:ModifiedLauncherHash
    Assert-ShoutHash $Context.Library $record.installed_library_sha256
    Assert-ShoutHash $Context.Source $record.installed_source_sha256
    $beforeState = [IO.File]::ReadAllBytes($Context.State); $beforeStateHash = $Context.StateHash
    $beforeLegacy = [IO.File]::ReadAllBytes($LegacyState)
    $originalBytes = [IO.File]::ReadAllBytes($OriginalPath)
    if ((Get-ShoutByteHash $originalBytes) -ne $script:OriginalLauncherHash) { throw 'Original launcher source changed.' }
    $backup = Join-Path $Context.Data ('backups\original-loader-restore-' + [guid]::NewGuid().ToString('N'))
    [void](Assert-PortablePath $LegacyState); [void](Assert-PortablePath $backup)
    [void](New-Item -ItemType Directory -Path $backup)
    Backup-PortableFile $Context.Loader (Join-Path $backup 'pallas.previous.exe') $script:ModifiedLauncherHash
    Backup-PortableFile $Context.State (Join-Path $backup 'portable-state.previous.json') $beforeStateHash
    Backup-PortableFile $LegacyState (Join-Path $backup 'local-scheme-state.previous.json') $legacyHash
    $updated = $record | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $updated.status = 'original-components-restored'; $updated.loader_sha256 = $script:OriginalLauncherHash
    $updated.runtime_verified = $false; $updated.game_send_verified = $false
    $updated | Add-Member -NotePropertyName original_launcher_sha256 -NotePropertyValue $script:OriginalLauncherHash -Force
    $updated | Add-Member -NotePropertyName original_launcher_restore_backup -NotePropertyValue $backup -Force
    $updated | Add-Member -NotePropertyName original_launcher_restored_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $legacy.status = 'restored'; $legacy.native_runtime_verified = $false; $legacy.game_send_verified = $false
    $legacy | Add-Member -NotePropertyName restored_at -NotePropertyValue $updated.original_launcher_restored_at -Force
    $legacy | Add-Member -NotePropertyName restore_backup -NotePropertyValue $backup -Force
    $utf8 = New-Object Text.UTF8Encoding($false)
    $stateBytes = $utf8.GetBytes(($updated | ConvertTo-Json -Depth 5))
    $legacyBytes = $utf8.GetBytes(($legacy | ConvertTo-Json -Depth 5))
    $afterStateHash = Get-ShoutByteHash $stateBytes; $afterLegacyHash = Get-ShoutByteHash $legacyBytes
    try {
        Assert-ShoutHash $Context.State $beforeStateHash; Assert-ShoutHash $LegacyState $legacyHash
        Write-PortableFile $Context $originalBytes $Context.Loader $script:ModifiedLauncherHash $script:OriginalDllHash
        $Context.LoaderHash = $script:OriginalLauncherHash
        Assert-OriginalLauncher $Context.Loader
        Assert-ShoutHash $Context.Library $record.installed_library_sha256
        Assert-ShoutHash $Context.Source $record.installed_source_sha256
        Write-PortableFile $Context $stateBytes $Context.State $beforeStateHash $script:OriginalDllHash
        Write-PortableFile $Context $legacyBytes $LegacyState $legacyHash $script:OriginalDllHash
        $Context.StateHash = $afterStateHash
        [void](Read-PortableState $Context)
        Assert-ShoutHash $LegacyState $afterLegacyHash
    } catch {
        $failure = $_.Exception.Message
        $nowLoader = Get-ShoutFileHash $Context.Loader; $nowState = Get-ShoutFileHash $Context.State
        $nowLegacy = Get-ShoutFileHash $LegacyState
        if ($nowLoader -notin @($script:OriginalLauncherHash,$script:ModifiedLauncherHash) -or
            $nowState -notin @($beforeStateHash,$afterStateHash) -or $nowLegacy -notin @($legacyHash,$afterLegacyHash)) {
            throw ('Concurrent change; rollback refused, backups retained: ' + $backup)
        }
        $Context.LoaderHash = $nowLoader
        if ($nowLegacy -ne $legacyHash) { Write-PortableFile $Context $beforeLegacy $LegacyState $nowLegacy $script:OriginalDllHash }
        if ($nowState -ne $beforeStateHash) { Write-PortableFile $Context $beforeState $Context.State $nowState $script:OriginalDllHash }
        if ($nowLoader -ne $script:ModifiedLauncherHash) {
            Write-PortableFile $Context ([IO.File]::ReadAllBytes((Join-Path $backup 'pallas.previous.exe'))) $Context.Loader $nowLoader $script:OriginalDllHash
        }
        $Context.LoaderHash = $script:ModifiedLauncherHash; $Context.StateHash = $beforeStateHash
        throw ('Launcher restore failed; prior launcher and state recovered: ' + $failure)
    }
    Write-Host 'ORIGINAL LAUNCHER RESTORED: pinned Tencent signatures for both launcher and DLL verified. All text files retained.'
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
    $legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout\LocalSchemeExperiment'
    $mutexId = (Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex = New-Object Threading.Mutex($false,('Global\LOLPallasPortable-' + $mutexId))
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another installation/apply/restore is running.' }
    if ($PSCmdlet.ShouldProcess($context.Loader,'Restore signed original Pallas launcher; retain texts and initial backups')) {
        [void](Restore-OriginalLauncherOnly $context (Join-Path $legacyRoot 'pallas.original.exe') (Join-Path $legacyRoot 'state.json'))
    }
    exit 0
} catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
