# Own plaintext fixtures only. No Tencent component is loaded or modified.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'Switch-Pallas-KnownWorking8K.ps1') -FunctionsOnly
$script:Checks=0; $script:Running=$false
function Check($Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $script:Checks++ }
function Reject([scriptblock]$Action) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed 'Expected refusal' }
$realStopped=${function:Assert-ShoutStopped}
function Get-Process { return [pscustomobject]@{ProcessName='CrossProxy';Id=1234} }
Reject { & $realStopped }
Remove-Item -LiteralPath 'Function:\Get-Process'
function Assert-ShoutStopped { if ($script:Running) { throw 'Own fixture running' } }
function Get-AuthenticodeSignature { param([string]$LiteralPath); return [pscustomobject]@{Status='Valid'} }
$utf8=New-Object Text.UTF8Encoding($false)
$work=Join-Path $project ('build\known-working-8k-tests-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$source=[ordered]@{version=2;title='Own fixture';count=20}
foreach ($i in 0..19) {
    $key=($i+1).ToString(); if ($i -eq 9) { $key='0' }; if ($i -ge 10) { $key='F'+($i-9) }
    $source[$i.ToString()]='Own text '+$i; $source['bind'+$i]='~+'+$key
}
$compiled=ConvertTo-HotkeyArtifacts ($source | ConvertTo-Json) -FormatVersion 3
$converted=ConvertTo-Working8K $compiled
foreach ($i in 0..19) { Check ($converted.Scheme.($i.ToString()) -ceq $source[$i.ToString()]) 'All twenty texts unchanged' }
Check ($converted.Scheme.key -eq 1 -and $converted.LibraryBytes.Length -le 8192) 'Old schema/capacity'
$source.bind0='Ctrl+Alt+Q'; $other=ConvertTo-HotkeyArtifacts ($source | ConvertTo-Json) -FormatVersion 3
Reject { ConvertTo-Working8K $other }; $source.bind0='~+1'
$other.Scheme.count=19; Reject { ConvertTo-Working8K $other }

function New-Fixture {
    $folder=Join-Path $work ([guid]::NewGuid().ToString('N'))
    $root=Join-Path $folder ('WeGame '+[char]0x7528+[char]0x6237)
    $data=Join-Path $folder 'Portable profile'; $legacy=Join-Path $folder 'Legacy profile'
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'apps\Pallas\tp_deps'),$data,(Join-Path $data 'Editor'),
        (Join-Path $legacy 'LocalSchemeExperiment'),(Join-Path $legacy 'LocalLibraryExperiment'),(Join-Path $legacy 'HotkeysV2Experiment'))
    $stockDll=$utf8.GetBytes('own original DLL'); $failed=$utf8.GetBytes('own failed 64K DLL')
    $stockLoader=$utf8.GetBytes('own original loader'); $localLoader=$utf8.GetBytes('own historical local loader')
    $working=$utf8.GetBytes('own tested 8K DLL'); $twenty=$utf8.GetBytes('own original twenty DLL')
    $script:PortableOriginalHash=Get-ShoutByteHash $stockDll
    $script:PortableTargetHash=Get-ShoutByteHash $failed
    $script:PortableLoaderHash=Get-ShoutByteHash $stockLoader
    $script:PortableV2LoaderHash=Get-ShoutByteHash $localLoader
    $script:Working8KLoaderHash=$script:PortableV2LoaderHash
    $script:Working8KDllHash=Get-ShoutByteHash $working
    $script:Working8KTwentyHash=Get-ShoutByteHash $twenty
    $dll=Join-Path $root 'apps\Pallas\tp_deps\TenPallas.dll'; $loader=Join-Path $root 'apps\Pallas\pallas.exe'
    [IO.File]::WriteAllBytes($dll,$stockDll); [IO.File]::WriteAllBytes($loader,$stockLoader)
    $context=New-PortableContext $root $data
    [void](Install-PortableComponent $context $compiled $failed)
    $dllSource=Join-Path $folder 'working.bin'; $loaderSource=Join-Path $folder 'local-loader.bin'
    [IO.File]::WriteAllBytes($dllSource,$working); [IO.File]::WriteAllBytes($loaderSource,$localLoader)
    $original=Join-Path $legacy 'LocalSchemeExperiment\pallas.original.exe'; [IO.File]::WriteAllBytes($original,$stockLoader)
    $response=Join-Path $legacy 'local-response.json'; $library=Join-Path $legacy 'library20-v1.json'
    [IO.File]::WriteAllBytes($response,$utf8.GetBytes('own old v2 response preserved'))
    [IO.File]::WriteAllBytes($library,$utf8.GetBytes('own previous library preserved'))
    [IO.File]::WriteAllBytes((Join-Path $legacy 'LocalLibraryExperiment\TenPallas.before-library.dll'),$twenty)
    $beforeResponse=Join-Path $legacy 'LocalLibraryExperiment\response.before-library.json'
    [IO.File]::WriteAllBytes($beforeResponse,$utf8.GetBytes('own pre-library bootstrap'))
    $localRecord=[ordered]@{experiment='Pallas local-file scheme v1';status='restored';program_path=$loader;response_path=$response
        original_sha256=$script:PortableLoaderHash;candidate_sha256=$script:Working8KLoaderHash;backup_path=$original
        native_runtime_verified=$false;game_send_verified=$false}
    [IO.File]::WriteAllBytes((Join-Path $legacy 'LocalSchemeExperiment\state.json'),$utf8.GetBytes(($localRecord | ConvertTo-Json)))
    $libraryRecord=[ordered]@{experiment='local-library-v1';status='installed-awaiting-manual-validation';dll_path=$dll
        response_path=$response;library_path=$library;candidate_dll_sha256=$script:Working8KDllHash
        baseline_dll_sha256=$script:Working8KTwentyHash;previous_response_sha256=(Get-ShoutFileHash $beforeResponse)
        installed_library_sha256=(Get-ShoutFileHash $library);installed_response_sha256=(Get-ShoutFileHash $response)
        runtime_verified=$false;game_send_verified=$false}
    [IO.File]::WriteAllBytes((Join-Path $legacy 'LocalLibraryExperiment\state.json'),$utf8.GetBytes(($libraryRecord | ConvertTo-Json)))
    [IO.File]::WriteAllBytes((Join-Path $data 'Editor\messages.json'),$utf8.GetBytes('own unapplied draft preserved'))
    [IO.File]::WriteAllBytes((Join-Path $data 'Editor\settings.json'),$utf8.GetBytes('own settings preserved'))
    [IO.File]::WriteAllBytes((Join-Path $legacy 'HotkeysV2Experiment\state.json'),$utf8.GetBytes('own older state unchanged'))
    [IO.File]::WriteAllBytes((Join-Path $legacy 'hotkeys-v2.bin'),$utf8.GetBytes('own older binary library unchanged'))
    return [pscustomobject]@{Context=$context;Legacy=$legacy;DllSource=$dllSource;LoaderSource=$loaderSource}
}
$f=New-Fixture
$script:Running=$true; Reject { New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource }; $script:Running=$false
$plan=New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Planning performs no writes'
$before=Read-PortableState $f.Context
$script:Running=$true; Reject { Invoke-Working8KSwitch $f.Context $plan }; $script:Running=$false
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Running guard precedes backups/writes'
$after=Invoke-Working8KSwitch $f.Context $plan
foreach ($entry in $plan.Entries) {
    Check ((Get-ShoutFileHash $entry.Path) -eq $entry.TargetHash) 'Each component/data/state committed'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $entry.BackupName)) -eq $entry.BeforeHash) 'Each exact previous file backed up'
}
foreach ($entry in $plan.Preserved) {
    Check ((Get-ShoutFileHash $entry.Path) -eq $entry.BeforeHash) 'Draft/source/library/settings/history unchanged'
    Check ((Get-ShoutFileHash (Join-Path $plan.Backup $entry.BackupName)) -eq $entry.BeforeHash) 'Preserved file snapshot exact'
}
$now=Read-PortableState $f.Context
Check ($now.status -eq 'suspended-for-known-working-8k-control') 'Modern editor explicitly suspended'
Check ($now.baseline_dll_sha256 -eq $before.baseline_dll_sha256 -and $now.backup_id -eq $before.backup_id) 'Original recovery baseline retained'
Check (-not $now.game_send_verified -and -not $now.runtime_verified) 'No runtime verification invented'
Check ((Get-Content -LiteralPath (Join-Path $plan.Backup 'transition.json') -Raw | ConvertFrom-Json).status -eq 'active-awaiting-game-test') 'Transaction journal completed'
Reject { Apply-PortableMessages $f.Context $compiled }
Reject { New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource }

$realWrite=${function:Write-PortableFile}
function Write-PortableFile($Context,[byte[]]$Bytes,[string]$Path,$Before,[string]$ExpectedDll) {
    if ($script:FaultPath -and $Path -eq $script:FaultPath) {
        $script:FaultPath=$null
        if ($script:ConcurrentPath) { [IO.File]::WriteAllBytes($script:ConcurrentPath,$utf8.GetBytes('own concurrent update')); $script:ConcurrentPath=$null }
        if ($script:PostCommitFault) { & $realWrite $Context $Bytes $Path $Before $ExpectedDll }
        throw 'Own fixture forced write failure'
    }
    & $realWrite $Context $Bytes $Path $Before $ExpectedDll
}
foreach ($index in 0..6) {
    $f=New-Fixture; $plan=New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource
    $script:FaultPath=$plan.Entries[$index].Path; $script:PostCommitFault=($index -eq 3)
    Reject { Invoke-Working8KSwitch $f.Context $plan }
    foreach ($entry in $plan.Entries) { Check ((Get-ShoutFileHash $entry.Path) -eq $entry.BeforeHash) 'Failure restores exact previous pair/data/states' }
    foreach ($entry in $plan.Preserved) { Check ((Get-ShoutFileHash $entry.Path) -eq $entry.BeforeHash) 'Failure does not alter any drafts/portable texts' }
    Check (Test-Path -LiteralPath $plan.Backup) 'Failure retains recovery backups'
}
$script:PostCommitFault=$false
$f=New-Fixture; $plan=New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource
$script:FaultPath=$plan.Entries[5].Path; $script:ConcurrentPath=$f.Context.Dll
Reject { Invoke-Working8KSwitch $f.Context $plan }
Check ([IO.File]::ReadAllText($f.Context.Dll) -eq 'own concurrent update') 'Automatic rollback never overwrites an unknown concurrent update'
Check ((Get-ShoutFileHash (Join-Path $plan.Backup 'TenPallas.previous.dll')) -eq $plan.Entries[2].BeforeHash) 'Concurrent failure retains exact prior component backup'
$f=New-Fixture; $plan=New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource
[IO.File]::WriteAllBytes($plan.Entries[1].Path,$utf8.GetBytes('own concurrent edit'))
Reject { Invoke-Working8KSwitch $f.Context $plan }
Check (-not (Test-Path -LiteralPath $plan.Backup)) 'Concurrent edits rejected before live writes'
Check ([IO.File]::ReadAllText($plan.Entries[1].Path) -eq 'own concurrent edit') 'Concurrent edit preserved'
[IO.File]::WriteAllBytes($f.DllSource,$utf8.GetBytes('own unknown updated source'))
Reject { New-Working8KPlan $f.Context $f.Legacy $f.DllSource $f.LoaderSource }
Check (@(Get-ChildItem -LiteralPath $work -Filter '*.tmp' -Recurse).Count -eq 0) 'No abandoned stages'
Write-Host ('PASS: '+$script:Checks+' known-working-pair migration/backup/conversion/rollback checks. Own fixtures only.')
