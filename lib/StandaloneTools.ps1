# Own UI configuration only. No component/runtime changes when imported.
. (Join-Path $PSScriptRoot 'PortableTools.ps1')
function Read-StandaloneSettings([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    [void](Assert-PortablePath $Path)
    $hash = Get-ShoutFileHash $Path
    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($value.version -ne 1 -or $value.sid -ne (Get-PortableSid) -or $value.wegame_root -isnot [string]) { throw 'Unrecognized editor settings.' }
    Assert-ShoutHash $Path $hash
    return [pscustomobject]@{ Hash = $hash; Root = $value.wegame_root }
}
function Save-StandaloneSettings([string]$Path, [string]$Root, $ExpectedHash) {
    if (-not (Test-PortableRoot $Root)) { throw 'Choose the WeGame folder containing apps\Pallas.' }
    $resolved = Assert-PortablePath $Root; [void](Assert-PortablePath $Path)
    if ((Get-ShoutFileHash $Path) -ne $ExpectedHash) { throw 'Editor settings changed externally; restart before selecting again.' }
    $value = [ordered]@{ version = 1; sid = Get-PortableSid; wegame_root = $resolved }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($value | ConvertTo-Json))
    $stage = Join-Path (Split-Path -Parent $Path) ('settings-stage-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        Assert-ShoutHash $stage (Get-ShoutByteHash $bytes)
        if ((Get-ShoutFileHash $Path) -ne $ExpectedHash -or (-not $ExpectedHash -and (Test-Path -LiteralPath $Path))) { throw 'Settings changed during saving.' }
        if ($ExpectedHash) { [IO.File]::Replace($stage,$Path,[NullString]::Value) } else { [IO.File]::Move($stage,$Path) }
        return Read-StandaloneSettings $Path
    } finally { if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage } }
}
function ConvertTo-StandaloneBase64([string]$Text) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Invoke-StandaloneTask([string]$Executable, [string]$ExpectedExecutableHash,
    [ValidateSet('Install','Apply','Restore','Status','Validate')][string]$Mode,
    [string]$Root, [string]$Source, [string]$EditorRoot) {
    Assert-ShoutHash $Executable $ExpectedExecutableHash
    [void](Assert-PortablePath $EditorRoot); [void](Assert-PortablePath $Source)
    $jobs = Join-Path $EditorRoot 'jobs'; [void](Assert-PortablePath $jobs)
    New-Item -ItemType Directory -Path $jobs -Force | Out-Null
    $job = [guid]::NewGuid().ToString('N'); $resultPath = Join-Path $jobs ($job + '.json')
    $arguments = '--action ' + $Mode.ToLowerInvariant() + ' --wegame ' + (ConvertTo-PortableArgument (ConvertTo-StandaloneBase64 $Root)) +
        ' --scheme ' + (ConvertTo-PortableArgument (ConvertTo-StandaloneBase64 $Source)) +
        ' --job ' + $job + ' --sid ' + (ConvertTo-PortableArgument (Get-PortableSid))
    if ($Mode -eq 'Install') { $arguments += ' --consent' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable; $start.Arguments = $arguments; $start.UseShellExecute = $true
    $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Mode -in @('Install','Restore') -and -not $admin) { $start.Verb = 'runas' }
    $process = [Diagnostics.Process]::Start($start)
    try { $process.WaitForExit(); $code = $process.ExitCode } finally { $process.Dispose() }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw ('Operation stopped/cancelled before reporting. Exit code: ' + $code + '. Use installation status to check; no forced retry.') }
    [void](Assert-PortablePath $resultPath)
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.job -ne $job -or $result.sid -ne (Get-PortableSid) -or $result.mode -ne $Mode.ToLowerInvariant() -or $result.exit_code -ne $code) { throw 'Unrecognized operation result.' }
    if ($code) { throw ($result.output + "`r`n" + $result.error) }
    return $result.output
}
