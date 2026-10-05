# Own generated file transitions only; never reads a live game/profile.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tests\Test-Banks80-Install.ps1')
Set-Item -Path Function:\Write-PortableFile -Value $realWrite
$oldChecks=$script:Checks; $script:Checks=0
. (Join-Path $project 'Manage-Pallas-BanksTen.ps1') -Mode Install -WeGameRoot 'Own ten root' -ExpectedSid 'Own ten sid' -AcceptUnsignedExperiment -FunctionsOnly
Check ($Mode -eq 'Install' -and $WeGameRoot -eq 'Own ten root' -and $ExpectedSid -eq 'Own ten sid' -and $AcceptUnsignedExperiment -and $FunctionsOnly) 'Import retains ten-profile command options'
function Assert-ShoutStopped { if ($script:Running) { throw 'Own running-process fixture' } }
$script:Running=$false; $script:FaultPath=$null; $script:PostFault=$false; $script:ConcurrentPath=$null
function New-TenFixture {
    $f=New-BankFixture
    $oldPlan=New-Banks80Plan $f.Context $f.Legacy $f.Artifacts
    [void](Invoke-Banks80Install $f.Context $oldPlan)
    $scheme=$utf8.GetString($f.Artifacts.Library) | ConvertFrom-Json
    $compiled=ConvertTo-BanksTenArtifacts $scheme
    $dll=$utf8.GetBytes('own eight banks ten keys unlimited characters')
    $script:BanksTenHash=Get-ShoutByteHash $dll
    $artifacts=[pscustomobject]@{Dll=$dll;Library=$compiled.Library;Response=$compiled.Response}
    return [pscustomobject]@{Context=$f.Context;Legacy=$f.Legacy;Artifacts=$artifacts;Scheme=$scheme;OldPlan=$oldPlan}
}
$f=New-TenFixture
$script:Running=$true; Reject { New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts }; $script:Running=$false
$plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'No writes while planning'
$script:Running=$true; Reject { Invoke-BanksTenInstall $f.Context $plan }; $script:Running=$false
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Running refusal before all backups/writes'
Invoke-BanksTenInstall $f.Context $plan
foreach($e in $plan.Entries){ Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Six install readbacks'; Check ((Get-ShoutFileHash (Join-Path $plan.Backup $e.BackupName)) -eq $e.BeforeHash) 'Exact old banks/text/state backups' }
foreach($p in $plan.Preserved){ Check ((Get-ShoutFileHash $p.Path) -eq $p.BeforeHash) 'Loader/private drafts/capacity unchanged'; Check ((Get-ShoutFileHash (Join-Path $plan.Backup $p.BackupName)) -eq $p.BeforeHash) 'Preserved files also backed up' }
$r=(Read-BanksTenRecord $f.Context $f.Legacy).Record
Check ($r.bank_count -eq 8 -and $r.bank_size -eq 10 -and $null -eq $r.single_message_utf16_limit -and -not $r.game_send_verified) 'Eight ten-key groups and no false runtime claim'
Check ((Read-Banks80Record $f.Context $f.Legacy).Record.status -eq 'suspended-for-banks10-control') 'Old installer/restore suspended'
Reject { Invoke-Banks80Restore $f.Context $f.Legacy }
Reject { New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts }
$applied=Get-Content -LiteralPath $r.changes[0].Path -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($name in @('title','key')+@(0..79 | ForEach-Object{$_.ToString()})){ Check ($applied.$name -ceq $f.Scheme.$name) 'All eighty personal messages and metadata exactly preserved' }
$long=$applied | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$long.'0'=([char]0x4E2D).ToString()*500
$long.'10'=[char]::ConvertFromUtf32(0x1F600)*500
$applyPlan=New-BanksTenApplyPlan $f.Context $f.Legacy $long
Check (@($applyPlan.Entries | Where-Object{$_.Path -eq $f.Context.Dll -or $_.Path -eq $f.Context.Loader}).Count -eq 0) 'Text application never writes DLL/loader'
$script:Running=$true; Reject { Invoke-BanksTenApply $f.Context $applyPlan }; $script:Running=$false
Check (-not(Test-Path -LiteralPath $applyPlan.Backup)) 'Apply refuses running client before backups'
Invoke-BanksTenApply $f.Context $applyPlan
$r=(Read-BanksTenRecord $f.Context $f.Legacy).Record
$value=Get-Content -LiteralPath $r.changes[0].Path -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($value.'0'.Length -eq 500 -and $value.'10'.Length -eq 1000) '500 Chinese characters / 500 emoji preserved without individual cap'
foreach($e in $r.changes){ Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Restore journal targets synchronized after long text application' }
$envelope=Get-Content -LiteralPath $r.changes[1].Path -Raw -Encoding UTF8 | ConvertFrom-Json
$bootstrap=$utf8.GetString([Convert]::FromBase64String($envelope.shout_message)) | ConvertFrom-Json
Check ($bootstrap.'0'.Length -le 33 -and $value.'0'.Length -eq 500) 'Only transport preview is shortened, never full message'
Check ($bootstrap._lps_local_v1 -ceq ('{0:X8}:{1:X8}' -f (Get-Item -LiteralPath $r.changes[0].Path).Length,(Get-LibraryChecksum ([IO.File]::ReadAllBytes($r.changes[0].Path))))) 'Full-file size/FNV synchronized'
$script:Running=$true; Reject { Invoke-BanksTenRestore $f.Context $f.Legacy }; $script:Running=$false
Invoke-BanksTenRestore $f.Context $f.Legacy
foreach($e in $plan.Entries){ Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Restores exact original four-bank state after long edit' }
$restored=(Read-BanksTenRecord $f.Context $f.Legacy).Record
Check ((Get-ShoutFileHash (Join-Path $restored.active_files_before_restore 'library80.before.json')) -eq $applyPlan.Entries[0].TargetHash) 'New long messages archived, never lost on restore'
Reject { Invoke-BanksTenRestore $f.Context $f.Legacy }

$tenWrite=${function:Write-PortableFile}
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if($script:FaultPath -and $Path -eq $script:FaultPath){
        $script:FaultPath=$null
        if($script:ConcurrentPath){ [IO.File]::WriteAllBytes($script:ConcurrentPath,$utf8.GetBytes('own concurrent bytes')); $script:ConcurrentPath=$null }
        if($script:PostFault){ & $tenWrite $Context $Bytes $Path $Before $ExpectedDll }
        throw 'Own forced ten-profile failure'
    }
    & $tenWrite $Context $Bytes $Path $Before $ExpectedDll
}
foreach($post in @($false,$true)){
    foreach($index in 0..6){
        $f=New-TenFixture; $plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts
        $script:FaultPath=$plan.ControlPath; if($index -lt 6){$script:FaultPath=$plan.Entries[$index].Path}; $script:PostFault=$post
        Reject { Invoke-BanksTenInstall $f.Context $plan }
        foreach($e in $plan.Entries){ Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Install pre/postcommit failure restores six exact old files' }
        foreach($p in $plan.Preserved){ Check ((Get-ShoutFileHash $p.Path) -eq $p.BeforeHash) 'Install faults preserve seven unrelated files' }
    }
    foreach($index in 0..4){
        $f=New-TenFixture; $plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts; Invoke-BanksTenInstall $f.Context $plan
        $long=$f.Scheme | ConvertTo-Json -Depth 4 | ConvertFrom-Json; $long.'0'=([char]0x4E2D).ToString()*500
        $applyPlan=New-BanksTenApplyPlan $f.Context $f.Legacy $long
        $script:FaultPath=$applyPlan.Entries[$index].Path; $script:PostFault=$post
        Reject { Invoke-BanksTenApply $f.Context $applyPlan }
        foreach($e in $applyPlan.Entries){ Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Text apply pre/postcommit failure restores five exact data files' }
        [void](Read-BanksTenRecord $f.Context $f.Legacy)
    }
    foreach($index in 0..6){
        $f=New-TenFixture; $plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts; Invoke-BanksTenInstall $f.Context $plan
        $before=Get-ShoutFileHash $plan.ControlPath
        $script:FaultPath=$plan.ControlPath; if($index -lt 6){$script:FaultPath=$plan.Entries[$index].Path}; $script:PostFault=$post
        Reject { Invoke-BanksTenRestore $f.Context $f.Legacy }
        foreach($e in $plan.Entries){ Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Restore failure returns complete ten-key profile' }
        Check ((Get-ShoutFileHash $plan.ControlPath) -eq $before) 'Restore failure returns journal exactly'
    }
}
$script:PostFault=$false
$f=New-TenFixture; $plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts
[IO.File]::WriteAllBytes($plan.Preserved[1].Path,$utf8.GetBytes('own newer private data'))
Reject { Invoke-BanksTenInstall $f.Context $plan }
Check (-not(Test-Path -LiteralPath $plan.Backup)) 'Concurrent private data change refused before write'
$f=New-TenFixture; $plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts
$script:FaultPath=$plan.Entries[3].Path; $script:ConcurrentPath=$f.Context.Dll
Reject { Invoke-BanksTenInstall $f.Context $plan }
Check ([IO.File]::ReadAllText($f.Context.Dll) -eq 'own concurrent bytes') 'Unknown concurrent DLL never overwritten by rollback'
$f=New-TenFixture; $plan=New-BanksTenInstallPlan $f.Context $f.Legacy $f.Artifacts; Invoke-BanksTenInstall $f.Context $plan
$record=(Read-BanksTenRecord $f.Context $f.Legacy).Record
$record.changes[0].Path=Join-Path $project 'unauthorized-target.json'
[IO.File]::WriteAllBytes($plan.ControlPath,(Get-CapacityJsonBytes $record))
Reject { Invoke-BanksTenRestore $f.Context $f.Legacy }
$bad=$f.Scheme | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$bad.'0'=([char]0x4E2D).ToString()*23000; Reject { ConvertTo-BanksTenArtifacts $bad }
$bad.'0'="bad`ntext"; Reject { ConvertTo-BanksTenArtifacts $bad }
$bad.'0'=[char]::ConvertFromUtf32(0x1F600)*500
Check ((ConvertTo-BanksTenArtifacts $bad).Library.Length -lt 65536) 'Unicode text without char cap accepted within whole-library capacity'
$rare=$f.Scheme | ConvertTo-Json -Depth 4 | ConvertFrom-Json
foreach($i in 0..9){ $rare.($i.ToString())='x'+([char]0x2028).ToString()*500 }
$rareArtifacts=ConvertTo-BanksTenArtifacts $rare
Check (($utf8.GetString($rareArtifacts.Library) | ConvertFrom-Json).'0'.Length -eq 501) 'Unusual escaped characters do not shorten full messages'
Check ($rareArtifacts.BootstrapBytes -le 2046) 'Unusual preview characters do not indirectly limit full messages'
Write-Host ('PASS: '+$script:Checks+' ten-key install/apply/restore/fault checks plus '+$oldChecks+' bank and '+$capacityChecks+' capacity checks. Own generated files only.')
