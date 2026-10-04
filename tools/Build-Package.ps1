# Build a clean current-computer package; never copy personal messages/backups.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\ShoutTools.ps1')
$originalHash = '97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94'
$candidateHash = '3BCEFF093D67F86400DD0F3F1ECE50F812D531926D5FF64CF72C227904DA5D00'
Assert-ShoutHash (Join-Path $root 'engine\assets\TenPallas.original.dll') $originalHash
Assert-ShoutHash (Join-Path $root 'engine\assets\TenPallas.twenty.experimental.dll') $candidateHash
$compiled = ConvertTo-TwentyResponse (Get-Content -LiteralPath (Join-Path $root 'scheme20.example.json') -Raw -Encoding UTF8)
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$stage = Join-Path $root ('build\packages\' + $stamp + '\LOLPallas')
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $stage,$dist -Force | Out-Null
$rootFiles = @('Open-Editor.cmd', 'Enable-Pallas-Twenty.cmd', 'Check-Pallas-Twenty.cmd',
    'Restore-Pallas-Twenty.cmd', 'Validate-Messages.cmd', 'Edit-Twenty-GUI.ps1',
    'Manage-Twenty-Release.ps1', 'scheme20.example.json', 'README.md')
foreach ($name in $rootFiles) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $stage }
foreach ($directory in @('lib', 'engine')) { Copy-Item -LiteralPath (Join-Path $root $directory) -Destination $stage -Recurse }
New-Item -ItemType Directory -Path (Join-Path $stage 'tools') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'tools\native') -Destination (Join-Path $stage 'tools') -Recurse
Copy-Item -LiteralPath (Join-Path $root 'scheme20.example.json') -Destination (Join-Path $stage 'scheme20.json')
$records = @(); $hashes = @{}
foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
    $relative = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
    $hash = Get-ShoutFileHash $file.FullName
    $hashes[$relative] = $hash
    $records += [ordered]@{ path = $relative; bytes = $file.Length; sha256 = $hash }
}
$manifest = [ordered]@{
    project = 'LOLPallas'; created_utc = [DateTime]::UtcNow.ToString('o')
    scope = 'Current zly profile and pinned WeGame build only; NOT a universal installer'
    personal_messages_included = $false; default_scheme_utf8_bytes = $compiled.SchemeBytes.Length
    original_dll_sha256 = $originalHash; candidate_dll_sha256 = $candidateHash
    signature_warning = 'Candidate Authenticode digest invalid. No integrity/anti-cheat bypass.'
    files = $records
}
$manifestPath = Join-Path $stage 'package-manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$hashes['package-manifest.json'] = Get-ShoutFileHash $manifestPath
$zipPath = Join-Path $dist ('LOLPallas-' + $stamp + '.zip')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath); $verified = 0
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        $name = $entry.FullName.Replace('\', '/')
        if (-not $name.StartsWith('LOLPallas/', [StringComparison]::Ordinal)) { throw 'Unexpected ZIP root.' }
        $name = $name.Substring(10)
        if (-not $hashes.ContainsKey($name)) { throw ('Unexpected ZIP file: ' + $name) }
        $stream = $entry.Open(); $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
        finally { $algorithm.Dispose(); $stream.Dispose() }
        if ($hash -ne $hashes[$name]) { throw ('ZIP readback mismatch: ' + $name) }
        $verified++
    }
} finally { $zip.Dispose() }
if ($verified -ne $hashes.Count) { throw 'ZIP file count mismatch.' }
Write-Output ('PACKAGE VERIFIED: ' + $verified + ' files. Personal messages excluded.')
Write-Output ('ZIP: ' + $zipPath)
Write-Output ('SHA256: ' + (Get-ShoutFileHash $zipPath))
