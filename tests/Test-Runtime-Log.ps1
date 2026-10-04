# Own synthetic TLG records only. Never reads a real account/game log.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\PortableTools.ps1')
$checks = 0
function Check($Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $script:checks++ }
$work = Join-Path $root ('build\runtime-log-fixture-' + [guid]::NewGuid().ToString('N'))
$pallas = Join-Path $work 'apps\Pallas'
[void](New-Item -ItemType Directory -Path (Join-Path $pallas 'log'))
$key = New-Object byte[] 128
for ($i=0; $i -lt 128; $i++) { $key[$i]=[byte](($i * 17) % 256) }
$prefix = [byte[]]@(0xE9,0x29,0xCE,0x76,0xE1,0x45,0x11,0x7E,0x33,0x51)
[Array]::Copy($prefix,$key,10)
$loggerPath = Join-Path $pallas 'tx_log.dll'
$logger = New-Object byte[] (146712 + 128); [Array]::Copy($key,0,$logger,146712,128)
[IO.File]::WriteAllBytes($loggerPath,$logger)
function Get-ShoutFileHash([string]$Path) {
    if ($Path -eq $loggerPath) { return '8548579CF3DC0A2EDEFDA388FAD2177BCEF98F0AA4B6F61F9EB87B56F1574F66' }
    throw 'Fixture hash called on unexpected path.'
}
function Row([string]$Text,[long]$Time) {
    $plain = [Text.Encoding]::Unicode.GetBytes($Text + [char]0)
    $row = New-Object byte[] (168 + $plain.Length)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$row.Length),$row,4)
    [Array]::Copy([BitConverter]::GetBytes($Time),0,$row,32,8)
    [Array]::Copy([BitConverter]::GetBytes([uint16]168),0,$row,60,2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$row.Length),0,$row,62,2)
    for ($i=0; $i -lt $plain.Length; $i++) { $row[168+$i]=$plain[$i] -bxor $key[$i % 128] }
    return ,$row
}
$bytes = (Row 'OnGameStart, game_id:1234567890, map_id:11' 1791132000) +
    (Row 'SendGetShoutMessage, req:{"token":"DO_NOT_RETURN","user_id":"Q:1234567890"}' 1791132001) +
    (Row 'OnGetShoutMessageRsp, send chat content to tp' 1791132002) +
    (Row 'ChekInGameRunStatus ten_pallas_run_flg=3, cross_run_flg=0' 1791132003) +
    (Row 'lol game end, set tenpallas path empty.' 1791132004)
$events = @(Read-PortableRuntimeEvents $bytes $key)
Check ($events.Count -eq 5) 'Expected bounded event count'
Check (($events | ConvertTo-Json -Compress) -notmatch 'DO_NOT_RETURN|1234567890') 'No raw tokens, messages or account IDs returned'
$path = Join-Path $pallas 'log\pallas.tlg'; [IO.File]::WriteAllBytes($path,$bytes)
$context = [pscustomobject]@{ Root=$work }
$record = [pscustomobject]@{ installed_at='2026-10-04T16:00:00Z' }
$good = Get-PortableRuntimeEvidence $context $record
Check ($good.Stage -eq 'scheme-dispatched-game-send-unverified' -and $good.RunFlag -eq 3) 'Running and dispatched is not game-send proof'
Check ($good.MatchesCurrentInstall -and $good.GameClosed -and -not $good.GameSendVerified) 'Session and verification fields'
$record | Add-Member -NotePropertyName upgraded_at -NotePropertyValue '2026-10-04T17:00:00Z'
Check (-not (Get-PortableRuntimeEvidence $context $record).MatchesCurrentInstall) 'Historical success cannot verify new installation'
$bytes += (Row 'OnGameStart, game_id:9876543210, map_id:11' 1791135200) +
    (Row 'ChekInGameRunStatus ten_pallas_run_flg=0, cross_run_flg=0' 1791135220)
[IO.File]::WriteAllBytes($path,$bytes)
$bad = Get-PortableRuntimeEvidence $context $record
Check ($bad.Stage -eq 'assistant-not-running' -and $bad.RunFlag -eq 0) 'Actual no-start stage identified'
Check (-not $bad.SchemeRequested -and -not $bad.SchemeDispatched) 'Earlier session events do not leak into latest session'
Check ($bad.MatchesCurrentInstall -and -not $bad.GameClosed) 'Active current session'
$tail = $bytes + [byte[]]@(250,0,0,0) + (New-Object byte[] 166)
Check (@(Read-PortableRuntimeEvents $tail $key).Count -eq 7) 'Partial concurrent append accepted only as incomplete tail'
$malformed = [byte[]]$bytes.Clone(); $malformed[60]=1; $malformed[61]=0
$rejected=$false; try { Read-PortableRuntimeEvents $malformed $key | Out-Null } catch { $rejected=$true }
Check $rejected 'Bad offsets refused'
$before = [IO.File]::ReadAllBytes($path)
[void](Get-PortableRuntimeEvidence $context $record)
Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -eq [Convert]::ToBase64String($before)) 'Read-only, no diagnostic state writes'
Write-Host ('PASS: ' + $checks + ' synthetic runtime-log decoding/privacy/session/readonly checks. ' + $work)
