# ASCII source for Windows PowerShell 5.1. No live actions when dot-sourced.
$ErrorActionPreference = 'Stop'

function Initialize-ShoutSource([string]$Path, [string]$TemplatePath) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
    if (Test-Path -LiteralPath $Path) { throw 'A non-file occupies the source configuration path.' }
    [void](ConvertTo-TwentyResponse (Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8))
    [IO.File]::Copy($TemplatePath, $Path, $false)
}

function Get-ShoutByteHash([byte[]]$Bytes) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-ShoutFileHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [System.IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function ConvertTo-TwentyResponse([string]$Text) {
    if ($Text.Length -gt 65536) { throw 'The source JSON is unexpectedly large.' }
    # This scheme is a flat object with string/number values. Collect every key
    # before ConvertFrom-Json, which otherwise silently accepts duplicate keys.
    $jsonString = '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"'
    $jsonName = '"(?<name>(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*)"'
    $jsonNumber = '-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
    $pair = $jsonName + '\s*:\s*(?:' + $jsonString + '|' + $jsonNumber + ')'
    $match = [regex]::Match($Text, '\A\s*\{\s*(?:' + $pair + '(?:\s*,\s*' + $pair + ')*)?\s*\}\s*\z')
    if (-not $match.Success) { throw 'Expected a flat JSON object: title/key and twenty string messages.' }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    foreach ($token in [regex]::Matches($Text, $jsonString)) {
        # Validate Unicode escapes before the JSON library can replace an
        # unpaired surrogate with U+FFFD. Other escapes preserve a separator.
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
    $expected = @('title', 'key') + @(0..19 | ForEach-Object { $_.ToString() })
    if ($seen.Count -ne $expected.Count) { throw 'Keep exactly title/key and all message keys 0..19.' }
    foreach ($name in $expected) {
        if (-not $seen.Contains($name)) { throw ('Missing exact JSON key: ' + $name) }
    }
    if (($scheme.key -isnot [int] -and $scheme.key -isnot [long]) -or $scheme.key -notin @(1, 2)) {
        throw 'key must be integer 1 (tilde) or 2 (Ctrl).'
    }
    foreach ($name in @('title') + @(0..19 | ForEach-Object { $_.ToString() })) {
        $value = $scheme.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw ('Nonempty text required at key: ' + $name)
        }
        if ($value.Length -gt 50) { throw ('Key ' + $name + ' exceeds the precautionary 50 UTF-16 unit guard. Nothing was truncated.') }
        if ($value -match '[\x00-\x1F\x7F]') { throw ('Control characters are not supported at key: ' + $name) }
        [void]$utf8.GetBytes($value)
    }
    $ordered = [ordered]@{}
    foreach ($index in 0..19) { $ordered[$index.ToString()] = $scheme.($index.ToString()) }
    $ordered['title'] = $scheme.title
    $ordered['key'] = $scheme.key
    $raw = $utf8.GetBytes(($ordered | ConvertTo-Json -Compress -Depth 4))
    if ($raw.Length -gt 2046) {
        throw ('The complete scheme uses ' + $raw.Length + ' UTF-8 bytes; maximum is 2046. Shorten some messages. Nothing was truncated.')
    }
    $envelope = [ordered]@{ result = [ordered]@{ error_code = 0 }; shout_message = [Convert]::ToBase64String($raw) }
    $response = $utf8.GetBytes(($envelope | ConvertTo-Json -Compress -Depth 4))
    return [pscustomobject]@{
        Scheme = $scheme; SchemeBytes = $raw; ResponseBytes = $response
        ResponseHash = Get-ShoutByteHash $response
    }
}

function Read-ShoutScheme([string]$Path) {
    $envelope = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($envelope.result.error_code -ne 0 -or $envelope.shout_message -isnot [string]) {
        throw 'The existing local response is not a recognized successful response.'
    }
    $raw = [Convert]::FromBase64String($envelope.shout_message)
    if ($raw.Length -gt 2046) { throw 'Existing response exceeds the known whole-scheme transport.' }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return [pscustomobject]@{ Scheme = ($utf8.GetString($raw) | ConvertFrom-Json); Bytes = $raw.Length }
}

function Assert-ShoutStopped {
    $active = @(Get-Process | Where-Object {
        $_.ProcessName -match '^(wegame|pallas|League of Legends|LeagueClient|LeagueClientUx|LeagueClientUxRender|tgp_daemon|TenPallas)$'
    })
    if ($active.Count) {
        throw ('Exit the game and exit WeGame from the system tray first. Running: ' + (($active | ForEach-Object { $_.ProcessName + ' (PID ' + $_.Id + ')' }) -join ', '))
    }
}

function Assert-ShoutHash([string]$Path, [string]$Hash) {
    if ((Get-ShoutFileHash $Path) -ne $Hash) { throw ('File missing/changed; refusing replacement: ' + $Path) }
}

function Write-ShoutResponse([byte[]]$Bytes, [string]$Path, [string]$ExpectedHash,
                             [string]$DllPath, [string]$DllHash,
                             [string]$PallasPath, [string]$PallasHash) {
    $stage = Join-Path (Split-Path -Parent $Path) ('twenty-text-stage-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [System.IO.File]::Open($stage, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
        Assert-ShoutHash $stage (Get-ShoutByteHash $Bytes)
        Assert-ShoutStopped
        Assert-ShoutHash $DllPath $DllHash
        Assert-ShoutHash $PallasPath $PallasHash
        Assert-ShoutHash $Path $ExpectedHash
        [System.IO.File]::Replace($stage, $Path, [NullString]::Value)
        Assert-ShoutHash $Path (Get-ShoutByteHash $Bytes)
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage }
    }
}
