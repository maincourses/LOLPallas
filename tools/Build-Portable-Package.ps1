# Whitelisted test package; no personal data or complete Tencent binaries.
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\portable-v3-c'))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\PortableTools.ps1')
$validation = Get-Content -LiteralPath (Join-Path $BuildDirectory 'validation.portable.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($validation.candidate_dll_sha256 -ne $script:PortableTargetHash -or $validation.unit_tests_passed -ne $true -or
    $validation.unit_tests -ne 8 -or $validation.native.passed -ne $true -or $validation.native.cases -lt 135 -or
    $validation.native_file_io.passed -ne $true -or $validation.native_file_io.cases -lt 16) { throw 'Required native validation missing/mismatched.' }
# Re-run transaction and detached GUI checks before producing a deliverable.
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-Portable.ps1') -BuildDirectory $BuildDirectory
if ($LASTEXITCODE) { throw 'Portable transaction tests failed.' }
& $shell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'Edit-Hotkeys-GUI.ps1') -Portable -SelfTest
if ($LASTEXITCODE) { throw 'Portable detached GUI tests failed.' }
$template = Read-HotkeyDocument (Join-Path $root 'portable\messages.example.json') -FormatVersion 3
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$stage = Join-Path $root ('build\portable-packages\' + $stamp + '\LOLPallas-Portable-Test')
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $stage,$dist -Force | Out-Null
$entries = [ordered]@{}
foreach ($name in @('Install.cmd','Choose-WeGame.cmd','Open-Editor.cmd','Check.cmd','Restore.cmd','messages.example.json','README.md')) {
    $entries[$name] = Join-Path $root ('portable\' + $name)
}
foreach ($name in @('Manage-Pallas-Portable.ps1','Start-Portable.ps1','Run-Portable-Admin.ps1','Edit-Hotkeys-GUI.ps1')) { $entries[$name] = Join-Path $root $name }
foreach ($name in @('PortableTools.ps1','HotkeyTools.ps1','LibraryTools.ps1','ShoutTools.ps1','hotkeys-ui.zh-CN.json')) { $entries['lib/' + $name] = Join-Path $root ('lib\' + $name) }
foreach ($name in @('original-to-portable.json','v2-to-portable.json')) {
    Assert-ShoutHash (Join-Path $BuildDirectory $name) $script:PortableDeltaHashes[$name]
    $entries['patches/' + $name] = Join-Path $BuildDirectory $name
}
$records = @(); $hashes = @{}
foreach ($entry in $entries.GetEnumerator()) {
    $destination = Join-Path $stage $entry.Key
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ($entry.Key.EndsWith('.cmd')) {
        # Mechanical normalization only; PS 5.1 / CMD files contain ASCII text.
        $text = [IO.File]::ReadAllText($entry.Value)
        [IO.File]::WriteAllText($destination, ($text -replace '\r?\n', "`r`n"), [Text.Encoding]::ASCII)
    } else { [IO.File]::Copy($entry.Value,$destination,$false) }
    if ($entry.Key -match '\.(ps1|cmd)$' -and @([IO.File]::ReadAllBytes($destination) | Where-Object { $_ -gt 127 }).Count) { throw ('Non-ASCII Windows script: ' + $entry.Key) }
    $hash = Get-ShoutFileHash $destination; $hashes[$entry.Key] = $hash
    $records += [ordered]@{ path = $entry.Key; bytes = (Get-Item -LiteralPath $destination).Length; sha256 = $hash }
}
$manifest = [ordered]@{ project = 'LOLPallas'; release = 'portable-v3-TEST'; created_utc = [DateTime]::UtcNow.ToString('o')
    game_send_verified = $false; fresh_pc_initialization_verified = $false; offline_native_cases = $validation.native.cases; offline_file_io_cases = $validation.native_file_io.cases
    offline_transaction_tests_passed = $true; offline_detached_gui_tests_passed = $true
    personal_messages_included = $false; full_proprietary_binaries_included = $false
    requires = '64-bit Windows, WeGame, fixed verified component hashes; manual training-mode validation'
    capacity_bytes = 65536; maximum_messages = 512; single_message_utf16_units = 50
    default_messages = $template.Compiled.Scheme.count; default_library_bytes = $template.Compiled.LibraryBytes.Length
    candidate_dll_sha256 = $script:PortableTargetHash; original_dll_sha256 = $script:PortableOriginalHash
    signature_warning = 'Modified component Authenticode digest INVALID. No integrity/anti-cheat bypass.'; files = $records }
$manifestPath = Join-Path $stage 'package-manifest.json'
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$hashes['package-manifest.json'] = Get-ShoutFileHash $manifestPath
$zipPath = Join-Path $dist ('LOLPallas-Portable-Test-' + $stamp + '.zip')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zipPath,[IO.Compression.CompressionLevel]::Optimal,$true)
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath); $verified = 0
try {
    foreach ($entry in $zip.Entries) {
        $normalized = $entry.FullName.Replace('\','/')
        if ($normalized.EndsWith('/')) { continue }
        if (-not $normalized.StartsWith('LOLPallas-Portable-Test/',[StringComparison]::Ordinal)) { throw 'Unexpected ZIP root.' }
        $name = $normalized.Substring('LOLPallas-Portable-Test/'.Length)
        if (-not $hashes.ContainsKey($name) -or $name -match '\.(dll|exe)$|(^|/)messages\.json$|(^|/)backups/') { throw ('Unexpected/private ZIP file: ' + $name) }
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') } finally { $sha.Dispose(); $stream.Dispose() }
        if ($hash -ne $hashes[$name]) { throw ('ZIP readback mismatch: ' + $name) }; $verified++
    }
} finally { $zip.Dispose() }
if ($verified -ne $hashes.Count) { throw 'ZIP file count mismatch.' }
Write-Host ('PACKAGE VERIFIED: ' + $verified + ' files; no private texts/backups or full DLL/EXE.')
Write-Host ('STAGE: ' + $stage)
Write-Host ('ZIP: ' + $zipPath)
Write-Host ('SHA256: ' + (Get-ShoutFileHash $zipPath))
