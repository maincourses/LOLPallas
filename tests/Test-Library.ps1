# Offline only. No live paths, processes, installation or game input.
param([string]$BuildDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\LibraryTools.ps1')
$text = Get-Content -LiteralPath (Join-Path $root 'experiments\local-library\scheme20.example.json') -Raw -Encoding UTF8
$passed = 0
function Check([bool]$OK, [string]$Label) {
    if (-not $OK) { throw ('FAIL: ' + $Label) }
    $script:passed++
    Write-Output ('PASS: ' + $Label)
}
$rejected = $false
try { ConvertTo-TwentyResponse $text | Out-Null } catch { $rejected = $true }
Check $rejected 'Baseline still rejects the oversized scheme'
$compiled = ConvertTo-LibraryArtifacts $text
Check ($compiled.LibraryBytes.Length -eq 2294 -and $compiled.BootstrapBytes -eq 1280) 'Oversized 2294-byte library, short 1280-byte native packet'
Check ($compiled.Token -eq '000008F6:EBCBA822') 'Cross-language exact byte checksum'
Check ($compiled.LibraryHash -eq '15BD1E81C2C2B75557B3D27E4F799CBCFE3FE24F8B6D0C625FB46F0E0AFA5033') 'Expected full-library SHA256'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$response = $utf8.GetString($compiled.ResponseBytes) | ConvertFrom-Json
$preview = $utf8.GetString([Convert]::FromBase64String($response.shout_message)) | ConvertFrom-Json
$rawScheme = $utf8.GetString($compiled.LibraryBytes) | ConvertFrom-Json
Check ($preview._lps_local_v1 -ceq $compiled.Token -and $preview.'0' -ceq $rawScheme.'0') 'Native panel preview remains truthful'
Check ($preview.'19' -eq '' -and $rawScheme.'19'.EndsWith('LIB-END-20')) 'Second bank resides in complete local library'
$bad = $text | ConvertFrom-Json
$bad.'0' = 'x' * 51
$rejected = $false
try { ConvertTo-LibraryArtifacts ($bad | ConvertTo-Json -Depth 4) | Out-Null } catch { $rejected = $true }
Check $rejected 'Per-message precaution was not raised'
$bad = $text.Replace('"key": 1,', '"key": 1, "key": 1,')
$rejected = $false
try { ConvertTo-LibraryArtifacts $bad | Out-Null } catch { $rejected = $true }
Check $rejected 'Duplicate source keys still rejected'
if ($BuildDirectory) {
    Check ((Get-ShoutFileHash (Join-Path $BuildDirectory 'library20-v1.json')) -eq $compiled.LibraryHash) 'Python/PowerShell full library equal'
    Check ((Get-ShoutFileHash (Join-Path $BuildDirectory 'local-response.library.json')) -eq $compiled.ResponseHash) 'Python/PowerShell bootstrap equal'
}
# Fake files only: simulate success, stale writers and a stopped-process guard.
function Assert-ShoutStopped { if ($script:SimulateRunning) { throw 'Fixture process running.' } }
$scratch = Join-Path $root ('build\test-work\library-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$fakeDll = Join-Path $scratch 'fake.dll'
$fakeLoader = Join-Path $scratch 'loader.bin'
$destination = Join-Path $scratch 'library.json'
[IO.File]::WriteAllBytes($fakeDll, [byte[]]@(1,2,3))
[IO.File]::WriteAllBytes($fakeLoader, [byte[]]@(4,5,6))
$dllHash = Get-ShoutFileHash $fakeDll
$loaderHash = Get-ShoutFileHash $fakeLoader
Write-LibraryFile $compiled.LibraryBytes $destination $null $fakeDll $dllHash $fakeLoader $loaderHash
Check ((Get-ShoutFileHash $destination) -eq $compiled.LibraryHash) 'Create new bounded library atomically'
$rejected = $false
try { Write-LibraryFile ([byte[]]@(8)) $destination $null $fakeDll $dllHash $fakeLoader $loaderHash } catch { $rejected = $true }
Check ($rejected -and (Get-ShoutFileHash $destination) -eq $compiled.LibraryHash) 'Create-new never overwrites a concurrent file'
$script:SimulateRunning = $true
$rejected = $false
try { Write-LibraryFile ([byte[]]@(8)) $destination $compiled.LibraryHash $fakeDll $dllHash $fakeLoader $loaderHash } catch { $rejected = $true }
Check ($rejected -and (Get-ShoutFileHash $destination) -eq $compiled.LibraryHash) 'Running-process guard preserves library'
$script:SimulateRunning = $false
$rejected = $false
try { Write-LibraryFile ([byte[]]@(8)) $destination $compiled.LibraryHash $fakeDll ('0' * 64) $fakeLoader $loaderHash } catch { $rejected = $true }
Check $rejected 'Unknown native hash refuses a library commit'
Write-LibraryFile ([byte[]]@(8,9)) $destination $compiled.LibraryHash $fakeDll $dllHash $fakeLoader $loaderHash
Check ((Get-ShoutFileHash $destination) -eq (Get-ShoutByteHash ([byte[]]@(8,9)))) 'Replace existing library with complete readback'
Check (@(Get-ChildItem -LiteralPath $scratch -Filter '*.tmp').Count -eq 0) 'Failure staging files removed'
Write-Output ('LIBRARY CHECKS PASSED: ' + $passed)
