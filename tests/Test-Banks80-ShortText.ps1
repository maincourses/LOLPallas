# Own generated files only; no game or live installation access.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tests\Test-Banks80-Install.ps1')
Set-Item -Path Function:\Write-PortableFile -Value $realWrite
$priorChecks=$script:Checks; $script:Checks=0
. (Join-Path $project 'Set-Pallas-Banks80-ShortText.ps1') -Mode Apply -WeGameRoot 'Own short root' -ExpectedSid 'Own short sid' -FunctionsOnly
Check ($Mode -eq 'Apply' -and $WeGameRoot -eq 'Own short root' -and $ExpectedSid -eq 'Own short sid' -and $FunctionsOnly) 'Import options retained'
function Assert-ShoutStopped { if ($script:Running) { throw 'Own running-process fixture' } }
$script:Running=$false; $script:FaultPath=$null; $script:ConcurrentPath=$null; $script:PostFault=$false
function New-ActiveShortFixture {
    $f=New-BankFixture
    $scheme=$utf8.GetString($f.Artifacts.Library) | ConvertFrom-Json
    $text=ConvertTo-BankTextArtifacts $scheme
    $f.Artifacts.Library=$text.Library; $f.Artifacts.Response=$text.Response
    $f.Artifacts.Proof.library_sha256=Get-ShoutByteHash $text.Library
    $f.Artifacts.Proof.response_sha256=Get-ShoutByteHash $text.Response
    $f.Artifacts.Proof.bootstrap_bytes=$text.BootstrapBytes
    $install=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
    [void](Invoke-Banks80Install $f.Context $install)
    return [pscustomobject]@{Fixture=$f;Installation=$install;Original=$scheme}
}
$a=New-ActiveShortFixture; $f=$a.Fixture
$script:Running=$true; Reject { New-BankShortTextPlan $f.Context $f.Legacy }; $script:Running=$false
$plan=New-BankShortTextPlan $f.Context $f.Legacy
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Planning never writes'
Check ($plan.LibraryBytes -gt 8192 -and $plan.LibraryBytes -le 65536) 'Actual short Chinese library still exceeds 8 KiB'
foreach ($name in @('title','key')+@(0..19 | ForEach-Object { $_.ToString() })) {
    Check ($plan.Scheme.$name -ceq $a.Original.$name) 'All original personal texts and metadata preserved'
}
foreach ($i in 20..79) { Check ($plan.Scheme.($i.ToString()).Length -in @(49,50)) 'New meaningful Chinese texts have 49/50 UTF-16 units' }
Check ($plan.Entries.Count -eq 5 -and @($plan.Entries | Where-Object { $_.Path -eq $f.Context.Dll -or $_.Path -eq $f.Context.Loader }).Count -eq 0) 'Five DATA writes, no DLL/loader writes'
$script:Running=$true; Reject { Invoke-BankShortTextApply $f.Context $plan }; $script:Running=$false
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Running refusal before backups'
[void](Invoke-BankShortTextApply $f.Context $plan)
foreach ($e in $plan.Entries) {
    Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Five data file readbacks'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $e.BackupName)) -eq $e.BeforeHash) 'Long texts and old states retained exactly'
}
foreach ($p in $plan.Preserved) {
    Check ((Get-ShoutFileHash $p.Path) -eq $p.BeforeHash) 'DLL/loader/draft/capacity untouched'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $p.BackupName)) -eq $p.BeforeHash) 'Preserved files backed up'
}
$r=(Read-Banks80Record $f.Context $f.Legacy).Record
Check ($r.utf16_guard -eq 100 -and $r.text_test_max_utf16 -eq 50 -and -not $r.game_send_verified) 'Data max50, native guard100, game result unknown'
foreach ($e in $r.changes) { Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Original restore journal retargeted to short text state'
}
$envelope=$utf8.GetString($plan.Entries[1].TargetBytes) | ConvertFrom-Json
$bootstrap=$utf8.GetString([Convert]::FromBase64String($envelope.shout_message)) | ConvertFrom-Json
$expected='{0:X8}:{1:X8}' -f $plan.Entries[0].TargetBytes.Length,(Get-LibraryChecksum $plan.Entries[0].TargetBytes)
Check ($bootstrap._lps_local_v1 -ceq $expected) 'Bootstrap exact size and FNV agree with actual library'
Reject { New-BankShortTextPlan $f.Context $f.Legacy }
# Existing Restore still returns EXACT proven twenty-message state after text-only change.
[void](Invoke-Banks80Restore $f.Context $f.Legacy)
foreach ($e in $a.Installation.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Existing restore stays valid after text-only update' }
Check ((Get-ShoutFileHash (Join-Path $plan.Backup 'library80.long.json')) -eq $a.Installation.Entries[0].TargetHash) 'Long library retained even after original restore'

$shortWrite=${function:Write-PortableFile}
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) {
        $script:FaultPath=$null
        if ($script:ConcurrentPath) { [IO.File]::WriteAllBytes($script:ConcurrentPath,$utf8.GetBytes('own concurrent text')); $script:ConcurrentPath=$null }
        if ($script:PostFault) { & $shortWrite $Context $Bytes $Path $Before $ExpectedDll }
        throw 'Own forced data-only update failure'
    }
    & $shortWrite $Context $Bytes $Path $Before $ExpectedDll
}
foreach ($post in @($false,$true)) {
    foreach ($index in 0..4) {
        $a=New-ActiveShortFixture; $f=$a.Fixture; $plan=New-BankShortTextPlan $f.Context $f.Legacy
        $script:PostFault=$post; $script:FaultPath=$plan.Entries[$index].Path
        Reject { Invoke-BankShortTextApply $f.Context $plan }
        foreach ($e in $plan.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Pre/post-write fault restores all five long text files' }
        foreach ($p in $plan.Preserved) { Check ((Get-ShoutFileHash $p.Path) -eq $p.BeforeHash) 'Fault never changes DLL/loader/private drafts' }
        [void](Read-Banks80Record $f.Context $f.Legacy)
    }
}
$script:PostFault=$false
$a=New-ActiveShortFixture; $f=$a.Fixture; $plan=New-BankShortTextPlan $f.Context $f.Legacy
[IO.File]::WriteAllBytes($plan.Entries[0].Path,$utf8.GetBytes('own newly edited text'))
Reject { Invoke-BankShortTextApply $f.Context $plan }
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Concurrent edit refuses before any write'
$a=New-ActiveShortFixture; $f=$a.Fixture; $plan=New-BankShortTextPlan $f.Context $f.Legacy
$script:FaultPath=$plan.Entries[2].Path; $script:ConcurrentPath=$plan.Entries[0].Path
Reject { Invoke-BankShortTextApply $f.Context $plan }
Check ([IO.File]::ReadAllText($plan.Entries[0].Path) -eq 'own concurrent text') 'Unknown concurrent text retained, not overwritten on rollback'
Check ((Get-ShoutFileHash (Join-Path $plan.Backup 'library80.long.json')) -eq $plan.Entries[0].BeforeHash) 'Exact old long-text backup kept on concurrent fault'
$scheme=New-BankShortScheme $a.Original
$scheme.'20'=([char]0x4E2D).ToString()*51
Reject { ConvertTo-BankTextArtifacts $scheme -MaximumUnits 50 }
$scheme.'20'=''; Reject { ConvertTo-BankTextArtifacts $scheme -MaximumUnits 50 }
Write-Host ('PASS: '+$script:Checks+' short-text checks plus '+$priorChecks+' bank and '+$capacityChecks+' reused capacity checks. Own generated files only.')
