# Build a single unsigned Windows EXE. Development-only; never installs anything.
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\portable-v3-r2'))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\PortableTools.ps1')
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw 'The development machine needs the .NET Framework x64 compiler.' }
$native = Get-Content -LiteralPath (Join-Path $BuildDirectory 'validation.portable.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($native.candidate_dll_sha256 -ne $script:PortableTargetHash -or -not $native.unit_tests_passed -or
    -not $native.native.passed -or $native.native.cases -lt 159 -or -not $native.native_file_io.passed -or $native.native_file_io.cases -lt 17) { throw 'Pinned repaired v3 offline validation required.' }
$loader = Get-Content -LiteralPath (Join-Path $BuildDirectory 'validation.loader.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $loader.passed -or -not $loader.own_fixture_only -or $loader.candidate_dll_sha256 -ne $script:PortableTargetHash) { throw 'Own normal Windows loader validation required.' }
foreach ($test in @('tests\Test-Standalone.ps1','tests\Test-Portable.ps1','tests\Test-Stock-Reinstall.ps1')) {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $test)
    if ($LASTEXITCODE) { throw ('Test failed: ' + $test) }
}
& $shell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'Edit-Hotkeys-GUI.ps1') -Portable -Standalone -SelfTest
if ($LASTEXITCODE) { throw 'Standalone GUI regression failed.' }
$stamp = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'China Standard Time').ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$work = Join-Path $root ('build\single-exe\' + $stamp)
$stage = Join-Path $work 'LOLPallasApp'
New-Item -ItemType Directory -Path $stage | Out-Null
$entries = [ordered]@{
    'Edit-Hotkeys-GUI.ps1' = (Join-Path $root 'Edit-Hotkeys-GUI.ps1')
    'Manage-Pallas-Portable.ps1' = (Join-Path $root 'Manage-Pallas-Portable.ps1')
    'messages.example.json' = (Join-Path $root 'portable\messages.example.json')
    'README.md' = (Join-Path $root 'docs\single-exe.md')
}
foreach ($name in @('HotkeyTools.ps1','LibraryTools.ps1','ShoutTools.ps1','PortableTools.ps1','StandaloneTools.ps1','hotkeys-ui.zh-CN.json')) { $entries['lib/' + $name] = Join-Path $root ('lib\' + $name) }
foreach ($name in @('original-to-portable.json','v2-to-portable.json','portable-v3-to-fixed.json')) {
    Assert-ShoutHash (Join-Path $BuildDirectory $name) $script:PortableDeltaHashes[$name]
    $entries['patches/' + $name] = Join-Path $BuildDirectory $name
}
$records = @()
foreach ($entry in $entries.GetEnumerator()) {
    $path = Join-Path $stage $entry.Key
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::Copy($entry.Value,$path,$false)
    if ($entry.Key.EndsWith('.ps1') -and @([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count) { throw 'Non-ASCII PS 5.1 script.' }
    $records += [ordered]@{ path = $entry.Key; bytes = (Get-Item -LiteralPath $path).Length; sha256 = Get-ShoutFileHash $path }
}
$manifest = [ordered]@{ release = 'single-exe-v1-TEST'; game_send_verified = $false; fresh_pc_initialization_verified = $false
    personal_messages_included = $false; full_proprietary_binaries_included = $false; candidate_dll_sha256 = $script:PortableTargetHash
    installer_revision = 'stock-reinstall-r1'; restored_stock_reinstall_tested = $true
    files = $records }
[IO.File]::WriteAllText((Join-Path $stage 'package-manifest.json'),($manifest | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$payload = Join-Path $work 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$payload,[IO.Compression.CompressionLevel]::Optimal,$true)
$identity = Join-Path $work 'payload.sha256'
[IO.File]::WriteAllText($identity,(Get-ShoutFileHash $payload).ToLowerInvariant(),[Text.Encoding]::ASCII)
$exe = Join-Path $work 'LOLPallas-Test.exe'
$options = @('/nologo','/target:winexe','/platform:x64','/optimize+',('/out:' + $exe),
    ('/win32manifest:' + (Join-Path $root 'tools\desktop\LOLPallasApp.manifest')),
    ('/resource:' + $payload + ',LOLPallas.Payload.zip'),('/resource:' + $identity + ',LOLPallas.Payload.sha256'),
    '/reference:System.Windows.Forms.dll','/reference:System.IO.Compression.dll','/reference:System.Web.Extensions.dll',
    (Join-Path $root 'tools\desktop\LOLPallasApp.cs'))
& $csc @options
if ($LASTEXITCODE) { throw 'C# launcher compilation failed.' }
$output = Join-Path $work 'self-test.output.json'; $errorOutput = Join-Path $work 'self-test.error.txt'
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $exe; $start.Arguments = '--self-test'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
$start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false); $start.StandardErrorEncoding = $start.StandardOutputEncoding
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit(); $code = $process.ExitCode
    $testOutput = $stdout.GetAwaiter().GetResult(); $testError = $stderr.GetAwaiter().GetResult()
} finally { $process.Dispose() }
[IO.File]::WriteAllText($output,$testOutput,(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($errorOutput,$testError,(New-Object Text.UTF8Encoding($false)))
if ($code) { throw ('EXE self-test failed: ' + $testError) }
$result = Get-Content -LiteralPath $output -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $result.passed -or $result.checks -ne 16 -or -not $result.no_live_install_or_game_sends) { throw 'Unexpected EXE self-test result.' }
if ((Get-AuthenticodeSignature -LiteralPath $exe).Status.ToString() -ne 'NotSigned') { throw 'Unexpected launcher signature status.' }
$dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Path $dist -Force | Out-Null
$destination = Join-Path $dist ('LOLPallas-Reinstall-Test-' + $stamp + '.exe')
[IO.File]::Copy($exe,$destination,$false); Assert-ShoutHash $destination (Get-ShoutFileHash $exe)
$report = [ordered]@{ artifact = $destination; sha256 = Get-ShoutFileHash $destination; bytes = (Get-Item -LiteralPath $destination).Length
    exe_signature = 'NotSigned'; game_send_verified = $false; proprietary_components_loaded = $false; live_install_changed = $false
    payload_files = 14; personal_messages_included = $false; native_candidate_sha256 = $script:PortableTargetHash
    installer_revision = 'stock-reinstall-r1'; restored_stock_reinstall_tested = $true
    own_windows_loader_tests = $loader; native_input_cases = $native.native.cases
    exe_self_tests = $result; build_work = $work }
[IO.File]::WriteAllText((Join-Path $work 'build-report.json'),($report | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
Write-Host ('EXE VERIFIED: ' + $destination)
Write-Host ('SHA256: ' + $report.sha256)
Write-Host ('BYTES: ' + $report.bytes + '; isolated EXE tests: ' + $result.checks + '; GAME UNVERIFIED')
