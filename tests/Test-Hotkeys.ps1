param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\hotkeys-v2'), [switch]$SkipArtifacts)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\HotkeyTools.ps1')
$script:Checks = 0
function Check($Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed 'Expected rejection' }
$text = Get-Content -LiteralPath (Join-Path $root 'messages.example.json') -Raw -Encoding UTF8
$compiled = ConvertTo-HotkeyArtifacts $text
if (-not $SkipArtifacts) {
    Check ($compiled.LibraryHash -eq (Get-ShoutFileHash (Join-Path $BuildDirectory 'hotkeys-v2.bin'))) 'PS/Python binary parity'
    Check ($compiled.ResponseHash -eq (Get-ShoutFileHash (Join-Path $BuildDirectory 'local-response.hotkeys.json'))) 'PS/Python bootstrap parity'
}
Check ($compiled.LibraryBytes.Length -eq 78) 'Expected library length'
Check ($compiled.BootstrapBytes -le 2046) 'Transport unchanged'
Check ((Get-HotkeyBinding ' alt + ctrl + q ').Label -ceq 'Ctrl+Alt+Q') 'Canonical independent binding'
foreach ($bad in @('Q', 'Ctrl+Ctrl+Q', 'Win+Q', 'Alt+F4', 'Ctrl+Alt+Delete', 'Ctrl+Enter', '~+~')) { Reject { Get-HotkeyBinding $bad } }
foreach ($suffix in @(',"extra":"x"', ',"0":"duplicate"', ',"\u0030":"escaped duplicate"')) {
    Reject { ConvertTo-HotkeyArtifacts ($text.Trim().TrimEnd('}') + $suffix + '}') }
}
foreach ($change in @(@('count', 0), @('count', 513), @('count', 1.5), @('version', 2.5),
    @('0', ('x' * 51)), @('0', ''), @('0', "x`n"), @('bind0', 'Ctrl+Alt+Q'))) {
    $bad = $text | ConvertFrom-Json; $bad.($change[0]) = $change[1]
    Reject { ConvertTo-HotkeyArtifacts ($bad | ConvertTo-Json) }
}
Reject { ConvertTo-HotkeyArtifacts ($text.Replace('Message one', '\ud800')) }
Check ((ConvertTo-HotkeyArtifacts ($text.Replace('Message one', '\ud83d\ude00'))).Scheme.'0'.Length -eq 2) 'Valid surrogate pair'
$legacy = ConvertFrom-LegacyHotkeys (Get-Content -LiteralPath (Join-Path $root 'experiments\local-library\scheme20.example.json') -Raw -Encoding UTF8)
Check ($legacy.count -eq 20 -and $legacy.bind0 -eq '~+1' -and $legacy.bind9 -eq '~+0' -and $legacy.bind19 -eq '~+F10') 'Legacy migration preserves ordering'
$folder = Join-Path ([IO.Path]::GetTempPath()) ('lps-hotkeys-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
$path = Join-Path $folder 'messages.json'
$saved = Save-HotkeyDocument $compiled.Scheme $path $null
Check ((Read-HotkeyDocument $path).Hash -eq $saved.Hash) 'Readback'
$same = Save-HotkeyDocument $compiled.Scheme $path $saved.Hash
Check ($null -eq $same.Backup -and $same.Hash -eq $saved.Hash) 'No-op save'
$changed = $text | ConvertFrom-Json; $changed.'0' = 'Edited locally'; $changed.bind0 = 'Ctrl+Shift+Q'
$next = Save-HotkeyDocument $changed $path $saved.Hash
Check ((Get-ShoutFileHash $next.Backup) -eq $saved.Hash) 'Source backup'
Reject { Save-HotkeyDocument $compiled.Scheme $path $saved.Hash }
Check ((Get-ShoutFileHash $path) -eq $next.Hash) 'CAS preserves concurrent changes'
Check (@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count -eq 0) 'Stages cleaned'
Write-Host ('PASS: ' + $script:Checks + ' hotkey source/serialization/persistence checks. Fixtures: ' + $folder)
