# Own fixture bytes only. No live paths, Tencent loading or game sends.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Switch-Pallas-CapacityControl.ps1') -FunctionsOnly
$script:Checks=0; $script:Running=$false
function Check($OK,[string]$Label) { if (-not $OK) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $bad=$false; try { & $Action | Out-Null } catch { $bad=$true }; Check $bad 'Expected safe refusal' }
. (Join-Path $project 'Switch-Pallas-CapacityControl.ps1') -Mode Validate -WeGameRoot 'Own root option' -ExpectedSid 'Own sid option' -FunctionsOnly
Check ($Mode -eq 'Validate' -and $WeGameRoot -eq 'Own root option' -and $ExpectedSid -eq 'Own sid option' -and $FunctionsOnly) 'Import preserves command parameters'
function Assert-ShoutStopped { if ($script:Running) { throw 'Own running-process fixture' } }
$utf8=New-Object Text.UTF8Encoding($false)
$work=Join-Path $project ('build\capacity-install-tests-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
function New-Fixture {
    $folder=Join-Path $work ([guid]::NewGuid().ToString('N')); $data=Join-Path $folder 'Data'
    $root=Join-Path $folder 'WeGame'; $legacy=Join-Path $folder 'Legacy'
    $id=[guid]::NewGuid().ToString('N')
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'apps\Pallas\tp_deps'),(Join-Path $data 'Editor'),
        (Join-Path $data ('backups\'+$id)),(Join-Path $legacy 'LocalLibraryExperiment'),(Join-Path $legacy 'LocalSchemeExperiment'))
    $baseline=$utf8.GetBytes('own working 8K DLL'); $candidate=$utf8.GetBytes('own capacity64 DLL')
    $loader=$utf8.GetBytes('own legacy loader'); $stock=$utf8.GetBytes('own signed original backup')
    $script:Working8KDllHash=Get-ShoutByteHash $baseline; $script:CapacityControlHash=Get-ShoutByteHash $candidate
    $script:Working8KLoaderHash=Get-ShoutByteHash $loader; $script:PortableV2LoaderHash=$script:Working8KLoaderHash
    $script:PortableOriginalHash=Get-ShoutByteHash $stock; $script:PortableTargetHash=Get-ShoutByteHash ($utf8.GetBytes('own failed modern DLL'))
    $dll=Join-Path $root 'apps\Pallas\tp_deps\TenPallas.dll'; $exe=Join-Path $root 'apps\Pallas\pallas.exe'
    [IO.File]::WriteAllBytes($dll,$baseline); [IO.File]::WriteAllBytes($exe,$loader)
    [IO.File]::WriteAllBytes((Join-Path $data ('backups\'+$id+'\TenPallas.before.dll')),$stock)
    $c=New-PortableContext $root $data
    foreach ($path in @($c.Library,$c.Source,(Join-Path $data 'Editor\messages.json'),(Join-Path $data 'Editor\settings.json'))) {
        [IO.File]::WriteAllBytes($path,$utf8.GetBytes('own preserved content '+[IO.Path]::GetFileName($path)))
    }
    $source=[ordered]@{title='Own fixture';key=1}
    foreach ($i in 0..19) { $source[$i.ToString()]='Own text '+$i }
    $compiled=ConvertTo-LibraryArtifacts ($source | ConvertTo-Json)
    $library=Join-Path $legacy 'library20-v1.json'; $response=Join-Path $legacy 'local-response.json'
    [IO.File]::WriteAllBytes($library,$compiled.LibraryBytes); [IO.File]::WriteAllBytes($response,$compiled.ResponseBytes)
    $modern=[ordered]@{experiment='portable-hotkeys-v3';status='suspended-for-known-working-8k-control';sid=$c.Sid
        wegame_root=$root;dll_path=$dll;library_path=$c.Library;source_path=$c.Source;baseline_dll_sha256=$script:PortableOriginalHash
        candidate_dll_sha256=$script:PortableTargetHash;loader_sha256=$script:Working8KLoaderHash;backup_id=$id
        installed_library_sha256=(Get-ShoutFileHash $c.Library);installed_source_sha256=(Get-ShoutFileHash $c.Source)
        active_control_dll_sha256=$script:Working8KDllHash;active_control_capacity_bytes=8192;game_send_verified=$false;runtime_verified=$false}
    [IO.File]::WriteAllBytes($c.State,(Get-CapacityJsonBytes $modern))
    $state=Join-Path $legacy 'LocalLibraryExperiment\state.json'
    $r=[ordered]@{experiment='local-library-v1';status='installed-awaiting-manual-validation';dll_path=$dll;library_path=$library
        response_path=$response;candidate_dll_sha256=$script:Working8KDllHash;installed_library_sha256=$compiled.LibraryHash
        installed_response_sha256=$compiled.ResponseHash;game_send_verified=$false;runtime_verified=$false}
    [IO.File]::WriteAllBytes($state,(Get-CapacityJsonBytes $r))
    [IO.File]::WriteAllBytes((Join-Path $legacy 'LocalSchemeExperiment\state.json'),$utf8.GetBytes('own launcher metadata unchanged'))
    return [pscustomobject]@{Context=$c;Legacy=$legacy;Candidate=$candidate}
}
$f=New-Fixture; $script:Running=$true; Reject { New-CapacityPlan $f.Context $f.Legacy $f.Candidate }; $script:Running=$false
$plan=New-CapacityPlan $f.Context $f.Legacy $f.Candidate
Check (-not (Test-Path -LiteralPath $plan.Backup) -and -not (Test-Path -LiteralPath $plan.ControlPath)) 'Planning has no writes'
$script:Running=$true; Reject { Invoke-CapacityInstall $f.Context $plan }; $script:Running=$false
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Running guard precedes all backups/writes'
$r=Invoke-CapacityInstall $f.Context $plan
foreach ($e in $plan.Entries) {
    Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'DLL and metadata readback'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $e.BackupName)) -eq $e.BeforeHash) 'Exact original backup'
}
foreach ($e in $plan.Preserved) {
    Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Launcher, texts, drafts and source not modified'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $e.BackupName)) -eq $e.BeforeHash) 'Preserved file backed up exactly'
}
Check ($r.status -eq 'installed-awaiting-game-test' -and -not $r.game_send_verified) 'No game success invented'
$modern=Read-PortableState $f.Context
Check ($modern.status -eq $script:CapacitySuspendedStatus -and $modern.active_control_capacity_bytes -eq 65536) 'Modern editor correctly suspended'
Reject { New-CapacityPlan $f.Context $f.Legacy $f.Candidate }
Reject { Apply-PortableMessages $f.Context $null }
$script:Running=$true; Reject { Invoke-CapacityRestore $f.Context $f.Legacy }; $script:Running=$false
[IO.File]::WriteAllBytes((Join-Path $f.Context.Data 'Editor\messages.json'),$utf8.GetBytes('own new draft after installation'))
$restore=Invoke-CapacityRestore $f.Context $f.Legacy
foreach ($e in $plan.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Restore exact 8K component/states' }
Check ([IO.File]::ReadAllText((Join-Path $f.Context.Data 'Editor\messages.json')) -eq 'own new draft after installation') 'Restore preserves even newly edited draft'
Check ($restore.status -eq 'restored-to-working8k') 'Restore journal readback'
Reject { Invoke-CapacityRestore $f.Context $f.Legacy }

$realWrite=${function:Write-PortableFile}
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) {
        $script:FaultPath=$null
        if ($script:ConcurrentPath) { [IO.File]::WriteAllBytes($script:ConcurrentPath,$utf8.GetBytes('own concurrent change')); $script:ConcurrentPath=$null }
        if ($script:PostFault) { & $realWrite $Context $Bytes $Path $Before $ExpectedDll }
        throw 'Own forced write failure'
    }
    & $realWrite $Context $Bytes $Path $Before $ExpectedDll
}
foreach ($post in @($false,$true)) {
    foreach ($index in 0..3) {
        $f=New-Fixture; $plan=New-CapacityPlan $f.Context $f.Legacy $f.Candidate
        $script:FaultPath=$plan.ControlPath; if ($index -lt 3) { $script:FaultPath=$plan.Entries[$index].Path }
        $script:PostFault=$post
        Reject { Invoke-CapacityInstall $f.Context $plan }
        foreach ($e in $plan.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Pre/postcommit failure restores 8K component/states' }
        foreach ($e in $plan.Preserved) { Check ((Get-ShoutFileHash $e.Path) -eq $e.BeforeHash) 'Failure leaves all text/launcher bytes alone' }
    }
    foreach ($index in 0..3) {
        $f=New-Fixture; $plan=New-CapacityPlan $f.Context $f.Legacy $f.Candidate
        [void](Invoke-CapacityInstall $f.Context $plan)
        $controlHash=Get-ShoutFileHash $plan.ControlPath
        $script:FaultPath=$plan.ControlPath; if ($index -lt 3) { $script:FaultPath=$plan.Entries[$index].Path }
        $script:PostFault=$post
        Reject { Invoke-CapacityRestore $f.Context $f.Legacy }
        foreach ($e in $plan.Entries) { Check ((Get-ShoutFileHash $e.Path) -eq $e.TargetHash) 'Failed restore returns exactly to active capacity state' }
        Check ((Get-ShoutFileHash $plan.ControlPath) -eq $controlHash) 'Failed restore retains consistent capacity journal'
    }
}
$script:PostFault=$false
$f=New-Fixture; $plan=New-CapacityPlan $f.Context $f.Legacy $f.Candidate
[IO.File]::WriteAllBytes($plan.Preserved[1].Path,$utf8.GetBytes('own concurrent text edit'))
Reject { Invoke-CapacityInstall $f.Context $plan }
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Concurrent text edit blocked before any writes'
$f=New-Fixture; $plan=New-CapacityPlan $f.Context $f.Legacy $f.Candidate
$script:FaultPath=$plan.Entries[1].Path; $script:ConcurrentPath=$f.Context.Dll
Reject { Invoke-CapacityInstall $f.Context $plan }
Check ([IO.File]::ReadAllText($f.Context.Dll) -eq 'own concurrent change') 'Unknown concurrent DLL never overwritten by rollback'
Check ((Get-ShoutFileHash (Join-Path $plan.Backup 'TenPallas.working8k.dll')) -eq $script:Working8KDllHash) 'Exact working backup retained on concurrent failure'
$f=New-Fixture; [IO.File]::WriteAllBytes($f.Context.Dll,$utf8.GetBytes('own unknown updated DLL'))
Reject { New-CapacityPlan $f.Context $f.Legacy $f.Candidate }
Check (@(Get-ChildItem -LiteralPath $work -Recurse -Filter '*.tmp').Count -eq 0) 'No abandoned staging files'
Write-Host ('PASS: '+$script:Checks+' capacity-control installation/restore/rollback checks; own fixtures only.')
