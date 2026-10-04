# Offline regression checks only; fake files under this script's output folder.
param([string]$PackageDirectory = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PackageDirectory 'lib\ShoutTools.ps1')
$template = Get-Content -LiteralPath (Join-Path $PackageDirectory 'scheme20.example.json') -Raw -Encoding UTF8
$script:Passed = 0

function Assert-Test([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:Passed++
    Write-Output ('PASS: ' + $Label)
}

function Assert-Rejected([scriptblock]$Action, [string]$Label) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected $Label
}

function Make-SchemeText([string]$Value, [int]$PanelKey = 1, [switch]$AllMessages) {
    $base = $template | ConvertFrom-Json
    $obj = [ordered]@{ title = $base.title; key = $PanelKey }
    foreach ($index in 0..19) {
        $obj[$index.ToString()] = $base.($index.ToString())
        if ($AllMessages -or $index -eq 0) { $obj[$index.ToString()] = $Value }
    }
    return ($obj | ConvertTo-Json -Depth 4 -Compress)
}

$compiled = ConvertTo-TwentyResponse $template
Assert-Test ($compiled.ResponseHash -eq '9968B92BCFA0F5A9772F7B68EF31D7E89FFCB558FDCBC5E24675F58456C2A5A9') 'Default output equals pinned original response byte-for-byte'
$envelope = [Text.Encoding]::UTF8.GetString($compiled.ResponseBytes) | ConvertFrom-Json
$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($envelope.shout_message)) | ConvertFrom-Json
Assert-Test (@($decoded.PSObject.Properties).Count -eq 22 -and $compiled.SchemeBytes.Length -eq 531) 'Twenty entries, metadata, expected whole-scheme size'
Assert-Rejected { ConvertTo-TwentyResponse ($template.Replace('"key": 1,', '"key": 1, "key": 1,')) } 'Duplicate key rejected'
Assert-Rejected { ConvertTo-TwentyResponse ($template.Replace('"key": 1,', '"key": 1, "\u006bey": 1,')) } 'Escaped duplicate key rejected'
Assert-Rejected { ConvertTo-TwentyResponse ('[' + $template + ']') } 'Non-object JSON rejected'
$missing = $template | ConvertFrom-Json
$missing.PSObject.Properties.Remove('19')
Assert-Rejected { ConvertTo-TwentyResponse ($missing | ConvertTo-Json -Depth 4) } 'Missing entry rejected'
$extra = $template | ConvertFrom-Json
$extra | Add-Member -NotePropertyName extra -NotePropertyValue 'x'
Assert-Rejected { ConvertTo-TwentyResponse ($extra | ConvertTo-Json -Depth 4) } 'Extra key rejected'
Assert-Test ((ConvertTo-TwentyResponse (Make-SchemeText ('x' * 50))).Scheme.'0'.Length -eq 50) 'Fifty ASCII units accepted'
Assert-Rejected { ConvertTo-TwentyResponse (Make-SchemeText ('x' * 51)) } 'Fifty-one ASCII units rejected'
$emoji = [char]::ConvertFromUtf32(0x1F600)
Assert-Test ((ConvertTo-TwentyResponse (Make-SchemeText ($emoji * 25))).Scheme.'0'.Length -eq 50) 'Emoji UTF-16 counting accepted at fifty'
Assert-Rejected { ConvertTo-TwentyResponse (Make-SchemeText ($emoji * 26)) } 'Emoji over fifty units rejected'
Assert-Rejected { ConvertTo-TwentyResponse (Make-SchemeText "line1`nline2") } 'Control characters rejected'
Assert-Rejected { ConvertTo-TwentyResponse ([regex]::Replace($template, '"0"\s*:\s*"[^"]*"', '"0": "\ud800"')) } 'Unpaired escaped surrogate rejected'
Assert-Rejected { ConvertTo-TwentyResponse (Make-SchemeText (([string][char]0x6D4B) * 50) -AllMessages) } 'Whole-scheme overflow rejected without truncation'
Assert-Test ((ConvertTo-TwentyResponse (Make-SchemeText 'plain' -PanelKey 2)).Scheme.key -eq 2) 'Ctrl panel key accepted'
Assert-Rejected { ConvertTo-TwentyResponse ($template.Replace('"key": 1,', '"key": 1.0,')) } 'Floating-point panel key rejected'
Assert-Test ((ConvertTo-TwentyResponse (Make-SchemeText 'say "hi": \ path')).Scheme.'0' -ceq 'say "hi": \ path') 'Escaped quotes and backslashes preserved'
Assert-Rejected { ConvertTo-TwentyResponse ($template.Replace('"title":', '"Title":')) } 'Wrong-case schema key rejected'

# Writer tests use fake DLL/EXE bytes and isolated destinations. Do not query or
# stop real processes, load binaries or replace any live response.
function Assert-ShoutStopped { }
$scratch = Join-Path $PackageDirectory ('build\test-work\guards-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$fakeDll = Join-Path $scratch 'fake-dll.bin'
$fakeLoader = Join-Path $scratch 'fake-loader.bin'
$destination = Join-Path $scratch 'response.json'
[IO.File]::WriteAllBytes($fakeDll, [byte[]]@(1,2,3))
[IO.File]::WriteAllBytes($fakeLoader, [byte[]]@(4,5,6))
[IO.File]::WriteAllBytes($destination, [byte[]]@(7,8,9))
$dllHash = Get-ShoutFileHash $fakeDll
$loaderHash = Get-ShoutFileHash $fakeLoader
$beforeHash = Get-ShoutFileHash $destination
$different = ConvertTo-TwentyResponse (Make-SchemeText 'updated')
Write-ShoutResponse $different.ResponseBytes $destination $beforeHash $fakeDll $dllHash $fakeLoader $loaderHash
Assert-Test ((Get-ShoutFileHash $destination) -eq $different.ResponseHash) 'Isolated atomic response write/readback'
Assert-Rejected { Write-ShoutResponse $compiled.ResponseBytes $destination $beforeHash $fakeDll $dllHash $fakeLoader $loaderHash } 'Changed destination compare-and-swap rejected'
Assert-Test ((Get-ShoutFileHash $destination) -eq $different.ResponseHash) 'Changed destination preserved'
Assert-Rejected { Write-ShoutResponse $compiled.ResponseBytes $destination $different.ResponseHash $fakeDll ('0' * 64) $fakeLoader $loaderHash } 'Unknown DLL hash rejected'
Assert-Test (@(Get-ChildItem -LiteralPath $scratch -Filter '*.tmp').Count -eq 0) 'Temporary staging files cleaned after failure'
Write-Output ('TOTAL PASSED: ' + $script:Passed)
Write-Output ('Isolated generated test files kept: ' + $scratch)
