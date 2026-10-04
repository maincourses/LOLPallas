[CmdletBinding(SupportsShouldProcess = $true)]
param([ValidateSet('Status','Validate','Install','Apply')][string]$Mode = 'Status',
    [string]$WeGameRoot, [string]$SchemePath, [string]$PatchDirectory,
    [string]$ExpectedSid, [switch]$AcceptUnsignedExperiment, [switch]$FunctionsOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\NativeKeyTools.ps1')
if ($FunctionsOnly) { return }
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$mutex = $null; $held = $false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Elevation switched accounts; no files changed.' }
    $data = Get-PortableDataRoot
    if (-not $SchemePath) { $SchemePath = Join-Path $data 'Editor\messages.json' }
    if ($Mode -eq 'Validate') {
        $document = Read-HotkeyDocument $SchemePath -FormatVersion 3
        Assert-NativeKeyScheme $document.Compiled.Scheme
        Write-Host 'VALID: twenty fixed native keys; 64 KiB storage; no live changes.'; exit 0
    }
    $context = New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    $record = Read-PortableState $context
    if ($Mode -eq 'Status') {
        Assert-PortableLoader $context
        Assert-ShoutHash $context.Dll $record.candidate_dll_sha256
        Assert-ShoutHash $context.Library $record.installed_library_sha256
        Assert-ShoutHash $context.Source $record.installed_source_sha256
        Write-Host ('Native twenty-key mode installed: ' + ($record.candidate_dll_sha256 -eq $script:NativeKeysHash))
        Write-Host ('Messages: ' + $record.message_count + '; capacity: 65536; game verification: pending')
        Write-Host 'Use ~+1..9,0 and ~+F1..F10. All texts/backups retained.'; exit 0
    }
    Assert-ShoutStopped; Assert-PortableLoader $context
    $mutexId = (Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex = New-Object Threading.Mutex($false,('Global\LOLPallasPortable-' + $mutexId))
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another install/apply/restore is running.' }
    $document = Read-HotkeyDocument $SchemePath -FormatVersion 3
    Assert-NativeKeyScheme $document.Compiled.Scheme
    if ($Mode -eq 'Apply') {
        if ($PSCmdlet.ShouldProcess($context.Library,'Apply twenty native-key messages; retain backups; no game sends')) {
            Assert-ShoutHash $SchemePath $document.Hash
            Apply-PortableMessages $context $document.Compiled
            Write-Host 'APPLIED AND READ BACK. Restart WeGame manually and test in training.'
        }; exit 0
    }
    if (-not $AcceptUnsignedExperiment) { throw 'Explicit -AcceptUnsignedExperiment required; never bypass signature/integrity/anti-cheat checks.' }
    if ($record.candidate_dll_sha256 -eq $script:NativeKeysHash) { throw 'Native keys already installed. Use Apply to edit messages.' }
    if ((Assert-PortableBaseline $context) -ne $script:IndependentKeysHash) { throw 'Requires the pinned current portable component.' }
    # Existing APPLIED data, not editor drafts/defaults, determines the rollback.
    $applied = Read-HotkeyDocument $context.Source -FormatVersion 3
    Assert-NativeKeyScheme $applied.Compiled.Scheme
    if ($applied.Compiled.LibraryHash -ne $record.installed_library_sha256) { throw 'Applied source/library mismatch.' }
    if (-not $PatchDirectory) { $PatchDirectory = Join-Path $PSScriptRoot 'build\nativekeys-64k-v1' }
    $validation = Get-Content -LiteralPath (Join-Path $PatchDirectory 'validation.nativekeys.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $loader = Get-Content -LiteralPath (Join-Path $PatchDirectory 'validation.loader.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $validation.passed -or $validation.static_checks -lt 20 -or -not $validation.receiver.passed -or
        $validation.receiver.checks -lt 36 -or -not $validation.receiver_file_io.passed -or
        $validation.receiver_file_io.checks -lt 18 -or $validation.candidate_dll_sha256 -ne $script:NativeKeysHash -or
        -not $loader.passed -or -not $loader.own_fixture_only -or $loader.candidate_dll_sha256 -ne $script:NativeKeysHash) { throw 'Pinned offline receiver/layout/loader validation required.' }
    $candidate = Expand-PortableDelta ([IO.File]::ReadAllBytes($context.Dll)) (Join-Path $PatchDirectory 'portable-fixed-to-native20.json') $script:NativeKeysDeltaHash
    if ($PSCmdlet.ShouldProcess($context.Dll,'Restore native twenty-key path; keep 64 KiB data and initial restore baseline')) {
        Assert-ShoutHash $SchemePath $document.Hash
        Assert-ShoutHash $context.Source $applied.Hash
        # Draft backup does not change the editable source or applied texts.
        $editorBackup = Join-Path $context.Data ('backups\editor-before-nativekeys-' + [guid]::NewGuid().ToString('N') + '.json')
        Backup-PortableFile $SchemePath $editorBackup $document.Hash
        [void](Upgrade-PortableComponent $context $candidate -Revision 'native-keys-64k-r1' -KeyboardMode 'native20')
        Write-Host 'NATIVE KEYS INSTALLED AND READ BACK. No texts or bindings changed; 64 KiB capacity retained.'
        Write-Host 'Only twenty fixed native keys are supported in this control version. Manual training test required.'
        Write-Host 'Use Open-NativeKeys-Editor.cmd for text edits. Do not use the earlier EXE Apply/Restore buttons.'
    }; exit 0
} catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
