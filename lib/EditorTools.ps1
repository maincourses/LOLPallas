# Shared source-file persistence. These functions never alter live WeGame data.
function Read-EditorDocument([string]$Path) {
    $before = Get-ShoutFileHash $Path
    if (-not $before) { throw ('Source file missing: ' + $Path) }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $compiled = ConvertTo-TwentyResponse $text
    Assert-ShoutHash $Path $before
    return [pscustomobject]@{ Path = $Path; Hash = $before; Compiled = $compiled }
}

function Save-EditorDocument($Scheme, [string]$Path, [string]$ExpectedHash) {
    $ordered = [ordered]@{ title = $Scheme.title; key = $Scheme.key }
    foreach ($index in 0..19) { $ordered[$index.ToString()] = $Scheme.($index.ToString()) }
    $text = ($ordered | ConvertTo-Json -Depth 4) + "`r`n"
    $compiled = ConvertTo-TwentyResponse $text
    Assert-ShoutHash $Path $ExpectedHash
    $previous = Read-EditorDocument $Path
    if ($previous.Compiled.ResponseHash -eq $compiled.ResponseHash) {
        return [pscustomobject]@{ Hash = $ExpectedHash; Compiled = $compiled; Backup = $null; Changed = $false }
    }
    $directory = Split-Path -Parent $Path
    $backupDirectory = Join-Path $directory 'backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backup = Join-Path $backupDirectory ('scheme20-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::Copy($Path, $backup, $false)
    Assert-ShoutHash $backup $ExpectedHash
    $stage = Join-Path $directory ('editor-save-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $bytes = $utf8.GetBytes($text)
    $newHash = Get-ShoutByteHash $bytes
    try {
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        Assert-ShoutHash $stage $newHash
        Assert-ShoutHash $Path $ExpectedHash
        [IO.File]::Replace($stage, $Path, [NullString]::Value)
        Assert-ShoutHash $Path $newHash
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage }
    }
    return [pscustomobject]@{ Hash = $newHash; Compiled = $compiled; Backup = $backup; Changed = $true }
}

function Invoke-EditorBackend([string]$PackageDirectory, [ValidateSet('Status', 'Apply')][string]$Mode) {
    $manager = Join-Path $PackageDirectory 'Manage-Twenty-Release.ps1'
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) { throw 'Package manager is missing.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $manager + '" -Mode ' + $Mode
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start the package manager.' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}
