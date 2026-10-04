# ASCII source, Windows PowerShell 5.1. Importing performs no writes.
. (Join-Path $PSScriptRoot 'LibraryTools.ps1')

function Get-HotkeyBinding([string]$Text) {
    $keys = @{}
    foreach ($i in 0..9) { $keys[$i.ToString()] = 0x30 + $i; $keys['NUMPAD' + $i] = 0x60 + $i }
    foreach ($i in 0x41..0x5A) { $keys[([string][char]$i)] = $i }
    foreach ($i in 1..24) { $keys['F' + $i] = 0x6F + $i }
    $names = @('PAGEUP', 'PAGEDOWN', 'END', 'HOME', 'LEFT', 'UP', 'RIGHT', 'DOWN')
    foreach ($i in 0..7) { $keys[$names[$i]] = 0x21 + $i }
    $keys['INSERT'] = 0x2D; $keys['DELETE'] = 0x2E
    $modifiers = @{ CTRL = 1; ALT = 2; SHIFT = 4; '~' = 8 }
    $parts = @($Text.Split('+') | ForEach-Object { $_.Trim().ToUpperInvariant() })
    if ($parts.Count -lt 2 -or -not $keys.ContainsKey($parts[-1])) {
        throw 'Use modifiers + a primary key, e.g. Ctrl+Alt+Q or ~+F1. Bare keys/Win/Enter/Tab/Esc are not accepted.'
    }
    $mask = 0
    foreach ($part in $parts[0..($parts.Count - 2)]) {
        if (-not $modifiers.ContainsKey($part) -or ($mask -band $modifiers[$part])) {
            throw 'Unknown or duplicated hotkey modifier.'
        }
        $mask = $mask -bor $modifiers[$part]
    }
    $vk = $keys[$parts[-1]]
    if ((($mask -band 2) -and $vk -eq 0x73) -or (($mask -band 3) -eq 3 -and $vk -eq 0x2E)) {
        throw 'System-reserved shortcut is forbidden.'
    }
    $labels = @()
    foreach ($item in @(@('Ctrl', 1), @('Alt', 2), @('Shift', 4), @('~', 8))) {
        if ($mask -band $item[1]) { $labels += $item[0] }
    }
    $labels += $parts[-1]
    return [pscustomobject]@{ VK = [int]$vk; Modifiers = [int]$mask; Label = ($labels -join '+') }
}

function ConvertTo-HotkeyArtifacts([string]$Text, [ValidateSet(2,3)][int]$FormatVersion = 2) {
    if ($Text.Length -gt 262144) { throw 'Source JSON is unexpectedly large.' }
    $jsonString = '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"'
    $jsonName = '"(?<name>(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*)"'
    $number = '-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
    $pair = $jsonName + '\s*:\s*(?:' + $jsonString + '|' + $number + ')'
    $match = [regex]::Match($Text, '\A\s*\{\s*(?:' + $pair + '(?:\s*,\s*' + $pair + ')*)?\s*\}\s*\z')
    if (-not $match.Success) { throw 'Expected flat version/title/count and numbered text/bind fields.' }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    foreach ($token in [regex]::Matches($Text, $jsonString)) {
        $body = $token.Value.Substring(1, $token.Value.Length - 2)
        $unicode = [regex]::Replace($body, '\\(?:u(?<code>[0-9a-fA-F]{4})|["\\/bfnrt])', {
            param($escape)
            if ($escape.Groups['code'].Success) { return [string][char][Convert]::ToInt32($escape.Groups['code'].Value, 16) }
            return ' '
        })
        [void]$utf8.GetBytes($unicode)
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($capture in $match.Groups['name'].Captures) {
        $name = ('"' + $capture.Value + '"') | ConvertFrom-Json
        if (-not $seen.Add($name)) { throw ('Duplicate JSON key: ' + $name) }
    }
    $scheme = $Text | ConvertFrom-Json
    if (($scheme.version -isnot [int] -and $scheme.version -isnot [long]) -or $scheme.version -ne 2 -or
        ($scheme.count -isnot [int] -and $scheme.count -isnot [long]) -or $scheme.count -lt 1 -or $scheme.count -gt 512) {
        throw 'Version must be integer 2; message count must be integer 1..512.'
    }
    $expected = @('version', 'title', 'count')
    foreach ($i in 0..($scheme.count - 1)) { $expected += $i.ToString(); $expected += 'bind' + $i }
    if ($seen.Count -ne $expected.Count) { throw 'Missing or extra configuration fields.' }
    foreach ($name in $expected) { if (-not $seen.Contains($name)) { throw ('Missing exact field: ' + $name) } }
    foreach ($name in @('title') + @(0..($scheme.count - 1) | ForEach-Object { $_.ToString() })) {
        $value = $scheme.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 50 -or
            $value -match '[\x00-\x1F\x7F]') { throw ('Text ' + $name + ': nonempty, max 50 UTF-16 units, no controls. Nothing truncated.') }
        [void]$utf8.GetBytes($value)
    }
    $canonical = [ordered]@{ version = 2; title = $scheme.title; count = [int]$scheme.count }
    $bindings = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $stream = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($stream, $utf8, $true)
    try {
        $writer.Write([byte[]]@(76,80,83,75,69,89,(48 + $FormatVersion),0)); $writer.Write([uint32]0); $writer.Write([uint32]$scheme.count)
        if ($FormatVersion -eq 3) { $writer.Write([uint32]0) }
        foreach ($i in 0..($scheme.count - 1)) {
            $name = 'bind' + $i
            if ($scheme.$name -isnot [string]) { throw ('Hotkey must be text: ' + $name) }
            try { $binding = Get-HotkeyBinding $scheme.$name } catch { throw ('Message ' + ($i + 1) + ': ' + $_.Exception.Message) }
            if (-not $bindings.Add($binding.Label)) { throw ('Duplicate shortcut: ' + $binding.Label) }
            $raw = $utf8.GetBytes($scheme.($i.ToString()))
            $writer.Write([uint16]$binding.VK); $writer.Write([uint16]$binding.Modifiers); $writer.Write([uint32]$raw.Length)
            $writer.Write([byte[]]$raw); $writer.Write([byte]0)
            $canonical[$i.ToString()] = $scheme.($i.ToString()); $canonical[$name] = $binding.Label
        }
        if ($stream.Length -gt 65536) { throw ('Library uses ' + $stream.Length + ' / 65536 bytes. Nothing truncated.') }
        [void]$stream.Seek(8, [IO.SeekOrigin]::Begin); $writer.Write([uint32]$stream.Length); $writer.Flush()
        $data = $stream.ToArray()
        if ($FormatVersion -eq 3) {
            $checksum = Get-LibraryChecksum ([byte[]]$data[20..($data.Length - 1)])
            [Array]::Copy([BitConverter]::GetBytes([uint32]$checksum), 0, $data, 16, 4)
        }
    } finally { $writer.Dispose(); $stream.Dispose() }
    $token = '{0:X8}:{1:X8}' -f $data.Length, (Get-LibraryChecksum $data)
    $preview = [ordered]@{ _lps_keys_v2 = $token }
    foreach ($i in 0..19) { $preview[$i.ToString()] = '' }
    $preview.title = 'LOCAL HOTKEYS: USE LOCAL EDITOR'; $preview.key = 1
    $short = $utf8.GetBytes(($preview | ConvertTo-Json -Compress -Depth 4))
    if ($short.Length -gt 2046) { throw 'Unchanged bootstrap transport exceeded.' }
    $envelope = [ordered]@{ result = [ordered]@{ error_code = 0 }; shout_message = [Convert]::ToBase64String($short) }
    $response = $utf8.GetBytes(($envelope | ConvertTo-Json -Compress -Depth 4))
    return [pscustomobject]@{ Scheme = [pscustomobject]$canonical; LibraryBytes = $data; ResponseBytes = $response
        LibraryHash = Get-ShoutByteHash $data; ResponseHash = Get-ShoutByteHash $response
        BootstrapBytes = $short.Length; Token = $token }
}

function Read-HotkeyDocument([string]$Path, [ValidateSet(2,3)][int]$FormatVersion = 2) {
    $before = Get-ShoutFileHash $Path
    if (-not $before) { throw ('Missing source: ' + $Path) }
    $compiled = ConvertTo-HotkeyArtifacts (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) -FormatVersion $FormatVersion
    Assert-ShoutHash $Path $before
    return [pscustomobject]@{ Hash = $before; Compiled = $compiled }
}
function Save-HotkeyDocument($Scheme, [string]$Path, $ExpectedHash, [ValidateSet(2,3)][int]$FormatVersion = 2) {
    $compiled = ConvertTo-HotkeyArtifacts ($Scheme | ConvertTo-Json -Depth 4) -FormatVersion $FormatVersion
    if ((Get-ShoutFileHash $Path) -ne $ExpectedHash) { throw 'Source changed externally. Reload before saving.' }
    if (Test-Path -LiteralPath $Path) {
        if (-not $ExpectedHash) { throw 'Occupied source path.' }
        $previous = Read-HotkeyDocument $Path -FormatVersion $FormatVersion
        if ($previous.Compiled.LibraryHash -eq $compiled.LibraryHash -and $previous.Compiled.Scheme.title -eq $compiled.Scheme.title) {
            return [pscustomobject]@{ Hash = $ExpectedHash; Compiled = $compiled; Backup = $null }
        }
        $backupDir = Join-Path (Split-Path -Parent $Path) 'backups'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backup = Join-Path $backupDir ('hotkeys-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::Copy($Path, $backup, $false); Assert-ShoutHash $backup $ExpectedHash
    } else { $backup = $null }
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes(($compiled.Scheme | ConvertTo-Json -Depth 4) + "`r`n")
    $stage = Join-Path (Split-Path -Parent $Path) ('hotkeys-save-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        Assert-ShoutHash $stage (Get-ShoutByteHash $bytes)
        if ((Get-ShoutFileHash $Path) -ne $ExpectedHash) { throw 'Source changed while saving.' }
        if ($ExpectedHash) { [IO.File]::Replace($stage, $Path, [NullString]::Value) }
        else { [IO.File]::Move($stage, $Path) }
        Assert-ShoutHash $Path (Get-ShoutByteHash $bytes)
    } finally { if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage } }
    return [pscustomobject]@{ Hash = Get-ShoutByteHash $bytes; Compiled = $compiled; Backup = $backup }
}
function ConvertFrom-LegacyHotkeys([string]$Text) {
    $old = ConvertTo-TwentyResponse $Text -MaximumSchemeBytes 8192
    $scheme = [ordered]@{ version = 2; title = $old.Scheme.title; count = 20 }
    $prefix = '~'; if ($old.Scheme.key -eq 2) { $prefix = 'Ctrl' }
    foreach ($i in 0..19) {
        $primary = (($i + 1) % 10).ToString()
        if ($i -ge 10) { $primary = 'F' + ($i - 9) }
        $scheme[$i.ToString()] = $old.Scheme.($i.ToString()); $scheme['bind' + $i] = $prefix + '+' + $primary
    }
    return (ConvertTo-HotkeyArtifacts ($scheme | ConvertTo-Json)).Scheme
}
