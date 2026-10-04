# UI-settings transactions only in fresh build fixtures; never touches production AppData.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\StandaloneTools.ps1')
$script:Checks = 0
function Check($Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $failed ('Expected refusal: ' + $Action.ToString()) }
$work = Join-Path $root ('build\standalone-settings-' + [guid]::NewGuid().ToString('N'))
$unicode = [string][char]0x7528 + [char]0x6237
$wegame = Join-Path $work ($unicode + ' WeGame space')
$editor = Join-Path $work 'Editor'
New-Item -ItemType Directory -Path (Join-Path $wegame 'apps\Pallas\tp_deps'),$editor | Out-Null
$bytes = [Text.Encoding]::ASCII.GetBytes('own fixture only')
[IO.File]::WriteAllBytes((Join-Path $wegame 'apps\Pallas\pallas.exe'),$bytes)
[IO.File]::WriteAllBytes((Join-Path $wegame 'apps\Pallas\tp_deps\TenPallas.dll'),$bytes)
$path = Join-Path $editor 'settings.json'
Check ($null -eq (Read-StandaloneSettings $path)) 'No settings on fresh launch'
$record = Save-StandaloneSettings $path $wegame $null
Check ((Read-StandaloneSettings $path).Root -ceq $wegame) 'Chinese path roundtrip'
$second = Save-StandaloneSettings $path $wegame $record.Hash
Check ($second.Hash -eq $record.Hash) 'Repeated selection retains stable JSON'
Reject { Save-StandaloneSettings $path $work $second.Hash }
Reject { Save-StandaloneSettings $path $wegame $null }
[IO.File]::WriteAllText($path,'external edit',[Text.Encoding]::UTF8)
Reject { Save-StandaloneSettings $path $wegame $second.Hash }
Check ([IO.File]::ReadAllText($path) -ceq 'external edit') 'Settings CAS preserves external edit'
[IO.File]::WriteAllText($path,('{"version":1,"sid":"foreign","wegame_root":"x"}'),[Text.Encoding]::UTF8)
Reject { Read-StandaloneSettings $path }
$source = Join-Path $editor 'messages.json'
$scheme = (Read-HotkeyDocument (Join-Path $root 'portable\messages.example.json') -FormatVersion 3).Compiled.Scheme
$saved = Save-HotkeyDocument $scheme $source $null -FormatVersion 3
Check ((Read-HotkeyDocument $source -FormatVersion 3).Hash -eq $saved.Hash) 'Own separate editor source persistence'
$encoded = ConvertTo-StandaloneBase64 ($unicode + ' text with spaces')
Check ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) -ceq ($unicode + ' text with spaces')) 'Native argv Unicode encoding'
Check (@(Get-ChildItem -LiteralPath $work -Recurse -Filter '*.tmp').Count -eq 0) 'No abandoned stages'
Write-Host ('PASS: ' + $script:Checks + ' standalone settings/source/argv checks. ' + $work)
