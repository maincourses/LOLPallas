# OWN generated fixtures only; no real candidate/launcher execution or live IO.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
# Reuse the already-tested fake historical pair/records fixture factory.
. (Join-Path $project 'tests\Test-Capacity-Install.ps1')
Set-Item -Path Function:\Write-PortableFile -Value $realWrite
. (Join-Path $project 'Switch-Pallas-Banks80.ps1') -Mode Validate -WeGameRoot 'Own bank root' -ExpectedSid 'Own bank sid' -AcceptUnsignedExperiment -FunctionsOnly
Check ($Mode -eq 'Validate' -and $WeGameRoot -eq 'Own bank root' -and $ExpectedSid -eq 'Own bank sid' -and $FunctionsOnly -and $AcceptUnsignedExperiment) 'Bank import preserves command options and explicit acceptance'
$capacityChecks=$script:Checks; $script:Checks=0
function Assert-ShoutStopped { if ($script:Running) { throw 'Own running-process fixture' } }
function Reject([scriptblock]$Action) {
    $bad=$false; try { & $Action | Out-Null } catch { $bad=$true }
    Check $bad ('Expected safe refusal: '+$Action.ToString())
}
$script:FaultPath=$null; $script:ConcurrentPath=$null; $script:PostFault=$false; $script:Running=$false
function New-BankFixture {
    $f=New-Fixture
    [void](Invoke-CapacityInstall $f.Context (New-CapacityPlan $f.Context $f.Legacy $f.Candidate))
    $dll=$utf8.GetBytes('own eighty-message DLL')
    $script:Banks80Hash=Get-ShoutByteHash $dll
    $seed=Join-Path $f.Legacy 'library20-v1.json'
    $scheme=Get-Content -LiteralPath $seed -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($i in 20..79) { $scheme | Add-Member -MemberType NoteProperty -Name ($i.ToString()) -Value (([char]0x4E2D).ToString()*86) }
    $library=$utf8.GetBytes(($scheme | ConvertTo-Json -Compress))
    $response=$utf8.GetBytes('own bank response')
    $proof=[pscustomobject]@{seed_library_sha256=(Get-ShoutFileHash $seed);library_sha256=(Get-ShoutByteHash $library)
        response_sha256=(Get-ShoutByteHash $response);bootstrap_bytes=521}
    return [pscustomobject]@{Context=$f.Context;Legacy=$f.Legacy;Artifacts=[pscustomobject]@{Dll=$dll;Library=$library;Response=$response;Proof=$proof}}
}
$f=New-BankFixture
$script:Running=$true; Reject { New-Banks80Plan $f.Context $f.Legacy $f.Artifacts }; $script:Running=$false
$plan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
Check (-not (Test-Path -LiteralPath $plan.Backup) -and -not (Test-Path -LiteralPath $plan.ControlPath)) 'Bank planning never writes'
$script:Running=$true; Reject { Invoke-Banks80Install $f.Context $plan }; $script:Running=$false
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Bank running guard precedes all writes/backups'
$r=Invoke-Banks80Install $f.Context $plan
foreach ($e in $plan.Entries) {
    Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Six bank entry readbacks'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $e.BackupName)) -eq $e.BeforeHash) 'Exact working64k backups'
}
foreach ($e in $plan.Preserved) {
    Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Loader and editor/source untouched'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $e.BackupName)) -eq $e.BeforeHash) 'Preserved files backed up'
}
Check ($r.status -eq 'installed-awaiting-game-test' -and -not $r.game_send_verified) 'Bank journal never invents game success'
Check ((Read-PortableState $f.Context).status -eq $script:BanksSuspendedStatus) 'Modern editor suspended'
Check ((Read-CapacityRecord $f.Context $f.Legacy).Record.status -eq 'suspended-for-banks80-control') 'Earlier capacity control suspended'
Reject { Invoke-CapacityRestore $f.Context $f.Legacy }
Reject { New-Banks80Plan $f.Context $f.Legacy $f.Artifacts }
Reject { Apply-PortableMessages $f.Context $null }
$script:Running=$true; Reject { Invoke-Banks80Restore $f.Context $f.Legacy }; $script:Running=$false
[IO.File]::WriteAllBytes((Join-Path $f.Context.Data 'Editor\messages.json'),$utf8.GetBytes('own newer draft'))
$restored=Invoke-Banks80Restore $f.Context $f.Legacy
foreach ($e in $plan.Entries) {
    Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Restore exact previous files'
    Check ((Get-ShoutFileHash (Join-Path $restored.active_files_before_restore $e.BackupName)) -eq $e.TargetHash) 'Active eighty-message files archived too'
}
Check ([IO.File]::ReadAllText((Join-Path $f.Context.Data 'Editor\messages.json')) -eq 'own newer draft') 'Restore retains newly edited draft'
Check ($restored.status -eq 'restored-to-working64k') 'Restore journal readback'
Reject { Invoke-Banks80Restore $f.Context $f.Legacy }

$originalBankWrite=${function:Write-PortableFile}
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) {
        $script:FaultPath=$null
        if ($script:ConcurrentPath) { [IO.File]::WriteAllBytes($script:ConcurrentPath,$utf8.GetBytes('own concurrent content')); $script:ConcurrentPath=$null }
        if ($script:PostFault) { & $originalBankWrite $Context $Bytes $Path $Before $ExpectedDll }
        throw 'Own forced bank write failure'
    }
    & $originalBankWrite $Context $Bytes $Path $Before $ExpectedDll
}
foreach ($post in @($false,$true)) {
    foreach ($index in 0..6) {
        $f=New-BankFixture; $plan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
        $script:FaultPath=$plan.ControlPath; if ($index -lt 6) { $script:FaultPath=$plan.Entries[$index].Path }
        $script:PostFault=$post
        Reject { Invoke-Banks80Install $f.Context $plan }
        foreach ($e in $plan.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Bank install pre/post-write fault rollback exact'
        }
        foreach ($e in $plan.Preserved) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Fault keeps preserved texts/loader exact' }
    }
    foreach ($index in 0..6) {
        $f=New-BankFixture; $plan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
        [void](Invoke-Banks80Install $f.Context $plan)
        $controlHash=Get-ShoutFileHash $plan.ControlPath
        $script:FaultPath=$plan.ControlPath; if ($index -lt 6) { $script:FaultPath=$plan.Entries[$index].Path }
        $script:PostFault=$post
        Reject { Invoke-Banks80Restore $f.Context $f.Legacy }
        foreach ($e in $plan.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Failed bank restore returns to active state' }
        Check ((Get-ShoutFileHash $plan.ControlPath) -eq $controlHash) 'Failed bank restore journal unchanged'
    }
}
$script:PostFault=$false
$f=New-BankFixture; $plan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
[IO.File]::WriteAllBytes($plan.Preserved[1].Path,$utf8.GetBytes('own concurrent source edit'))
Reject { Invoke-Banks80Install $f.Context $plan }
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Concurrent source edit refused before writes'
$f=New-BankFixture; $plan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
$script:FaultPath=$plan.Entries[3].Path; $script:ConcurrentPath=$f.Context.Dll
Reject { Invoke-Banks80Install $f.Context $plan }
Check ([IO.File]::ReadAllText($f.Context.Dll) -eq 'own concurrent content') 'Unknown concurrent DLL never overwritten'
Check ((Get-ShoutFileHash (Join-Path $plan.Backup 'TenPallas.working64k.dll')) -eq $script:CapacityControlHash) 'Exact previous DLL retained on concurrent fault'
$f=New-BankFixture; $plan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
[void](Invoke-Banks80Install $f.Context $plan)
$metadata=Get-Content -LiteralPath $plan.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
$metadata.changes[0].Path=Join-Path $project 'unauthorized.json'
[IO.File]::WriteAllBytes($plan.ControlPath,(Get-CapacityJsonBytes $metadata))
Reject { Invoke-Banks80Restore $f.Context $f.Legacy }
Check ((Get-ShoutFileHash $f.Context.Dll) -eq $script:Banks80Hash) 'Foreign restore destination refused without component writes'
Check (@(Get-ChildItem -LiteralPath $work -Recurse -Filter '*.tmp').Count -eq 0) 'No abandoned stages'
Write-Host ('PASS: '+$script:Checks+' bank install/restore/rollback checks plus '+$capacityChecks+' reused capacity checks. Own generated fixtures only.')
