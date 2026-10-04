[CmdletBinding(SupportsShouldProcess = $true)]
param([ValidateSet('Status','Validate','Install','Apply','Restore')][string]$Mode = 'Status',
    [string]$WeGameRoot, [string]$SchemePath, [string]$PatchDirectory,
    [string]$ExpectedSid, [switch]$AcceptUnsignedExperiment, [switch]$FunctionsOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\PortableTools.ps1')
if ($FunctionsOnly) { return }
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$mutex = $null; $held = $false
try {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'Requires 64-bit Windows / Windows PowerShell 5.1.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Elevation switched Windows accounts. Use the same user account; no files changed.' }
    if (-not $SchemePath) {
        $SchemePath = Join-Path $PSScriptRoot 'messages.json'
        if (-not (Test-Path -LiteralPath $SchemePath)) { $SchemePath = Join-Path $PSScriptRoot 'messages.example.json' }
    }
    if ($Mode -eq 'Validate') {
        $document = Read-HotkeyDocument $SchemePath -FormatVersion 3
        Write-Host ('VALID: ' + $document.Compiled.Scheme.count + ' messages, ' + $document.Compiled.LibraryBytes.Length + ' / 65536 bytes. No live changes.'); exit 0
    }
    $data = Get-PortableDataRoot
    $resolvedRoot = Resolve-PortableRoot $WeGameRoot $data
    $context = New-PortableContext $resolvedRoot $data
    if ($Mode -eq 'Status') {
        $current = Get-ShoutFileHash $context.Dll
        Write-Host ('WeGame: ' + $context.Root)
        Write-Host ('Component SHA256: ' + $current)
        Write-Host ('Portable candidate installed: ' + ($current -eq $script:PortableTargetHash))
        Write-Host ('Local library: ' + $context.Library)
        if (Test-Path -LiteralPath $context.State -PathType Leaf) {
            $record = Read-PortableState $context
            Write-Host ('State: ' + $record.status + '; messages: ' + $record.message_count)
            Write-Host ('Library matching: ' + ((Get-ShoutFileHash $context.Library) -eq $record.installed_library_sha256))
            Write-Host ('Applied source matching: ' + ((Get-ShoutFileHash $context.Source) -eq $record.installed_source_sha256))
        } else { Write-Host 'No portable installation record. Install.cmd is required before Apply.' }
        Write-Host 'TEST BUILD: offline/file checks do NOT prove game sending. Manual training-mode test required.'; exit 0
    }
    Assert-ShoutStopped; Assert-PortableLoader $context
    # Serialize by component path across packages/user sessions. Normal same-user UAC only.
    $mutexId = (Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex = New-Object Threading.Mutex($false, ('Global\LOLPallasPortable-' + $mutexId))
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another install/apply/restore is running. Retry after it finishes.' }
    if ($Mode -eq 'Restore') {
        $record = Read-PortableState $context
        if ($PSCmdlet.ShouldProcess($context.Dll,'Restore the exact previous component; retain all local texts/backups')) {
            Restore-PortableComponent $context $record
            Write-Host 'RESTORED AND READ BACK. All editable messages, libraries and backups retained.'
        }; exit 0
    }
    $document = Read-HotkeyDocument $SchemePath -FormatVersion 3
    if ($Mode -eq 'Apply') {
        if ($PSCmdlet.ShouldProcess($context.Library,'Apply local texts and independent bindings; no game messages sent')) {
            Assert-ShoutHash $SchemePath $document.Hash; Apply-PortableMessages $context $document.Compiled
            Write-Host 'APPLIED AND READ BACK. Restart WeGame manually; game sending still needs verification.'
        }; exit 0
    }
    if (-not $AcceptUnsignedExperiment) { throw 'Explicit -AcceptUnsignedExperiment consent is required. Candidate signature is INVALID; do not bypass security/integrity checks.' }
    $baseline = Assert-PortableBaseline $context
    if (-not $PatchDirectory) { $PatchDirectory = Join-Path $PSScriptRoot 'patches' }
    $name = 'original-to-portable.json'; if ($baseline -eq $script:PortableV2Hash) { $name = 'v2-to-portable.json' }
    $before = [IO.File]::ReadAllBytes($context.Dll)
    $candidate = Expand-PortableDelta $before (Join-Path $PatchDirectory $name) $script:PortableDeltaHashes[$name]
    if ($PSCmdlet.ShouldProcess($context.Dll,'Install UNSIGNED EXPERIMENTAL local-hotkey component; backup first; never modify Pallas launcher')) {
        Assert-ShoutHash $SchemePath $document.Hash
        [void](Install-PortableComponent $context $document.Compiled $candidate)
        Write-Host 'INSTALLED AND READ BACK. Restart WeGame manually and enable one-key shout.'
        Write-Host 'TRAINING-MODE TEST REQUIRED. Fresh-PC loading and all independent combos are NOT game-verified.'
        Write-Host 'If integrity/security/loading rejects this experimental component, use Restore.cmd. Never disable/bypass protection.'
    }; exit 0
} catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
