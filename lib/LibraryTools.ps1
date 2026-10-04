# EXPERIMENTAL only. Dot-sourcing performs no IO, installs or process actions.
# The original editor/manager retain their default 2046-byte transport guard.
. (Join-Path $PSScriptRoot 'ShoutTools.ps1')

function Get-LibraryChecksum([byte[]]$Bytes) {
    [uint64]$value = 2166136261
    foreach ($item in $Bytes) {
        $value = (([uint64]($value -bxor [uint64]$item)) * [uint64]16777619) % [uint64]4294967296
    }
    return [uint32]$value
}

function ConvertTo-LibraryArtifacts([string]$Text) {
    $compiled = ConvertTo-TwentyResponse $Text -MaximumSchemeBytes 8192
    $raw = $compiled.SchemeBytes
    $token = '{0:X8}:{1:X8}' -f $raw.Length, (Get-LibraryChecksum $raw)
    $preview = [ordered]@{ _lps_local_v1 = $token }
    foreach ($index in 0..19) {
        $preview[$index.ToString()] = ''
        if ($index -lt 10) { $preview[$index.ToString()] = $compiled.Scheme.($index.ToString()) }
    }
    $preview['title'] = $compiled.Scheme.title
    $preview['key'] = $compiled.Scheme.key
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $short = $utf8.GetBytes(($preview | ConvertTo-Json -Compress -Depth 4))
    if ($short.Length -gt 2046) { throw 'The native preview still exceeds the unchanged 2046-byte transport.' }
    $envelope = [ordered]@{ result = [ordered]@{ error_code = 0 }; shout_message = [Convert]::ToBase64String($short) }
    $response = $utf8.GetBytes(($envelope | ConvertTo-Json -Compress -Depth 4))
    return [pscustomobject]@{
        Scheme = $compiled.Scheme; LibraryBytes = $raw; ResponseBytes = $response
        LibraryHash = Get-ShoutByteHash $raw; ResponseHash = Get-ShoutByteHash $response
        Token = $token; BootstrapBytes = $short.Length
    }
}

function Write-LibraryFile([byte[]]$Bytes, [string]$Path, $ExpectedHash,
    [string]$DllPath, [string]$DllHash, [string]$PallasPath, [string]$PallasHash) {
    $stage = Join-Path (Split-Path -Parent $Path) ('library-stage-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
        $hash = Get-ShoutByteHash $Bytes
        Assert-ShoutHash $stage $hash
        Assert-ShoutStopped
        Assert-ShoutHash $DllPath $DllHash
        Assert-ShoutHash $PallasPath $PallasHash
        if ((Get-ShoutFileHash $Path) -ne $ExpectedHash) { throw 'Destination changed; library replacement refused.' }
        if ($null -eq $ExpectedHash -and (Test-Path -LiteralPath $Path)) { throw 'A non-file occupies the destination.' }
        if ($ExpectedHash) { [IO.File]::Replace($stage, $Path, [NullString]::Value) }
        else { [IO.File]::Move($stage, $Path) }
        Assert-ShoutHash $Path $hash
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage }
    }
}
