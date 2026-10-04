# Plaintext, own-directory fixture factory shared by restoration/migration tests.
# Production restoration functions are exercised; no real DLL/EXE is loaded.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Restore-Pallas-OriginalDll.ps1') -FunctionsOnly
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Restore-Pallas-OriginalLauncher.ps1') -FunctionsOnly
function New-StockRestoreFixture([string]$Work,$Compiled,[switch]$FullyRestored) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $folder = Join-Path $Work ([guid]::NewGuid().ToString('N'))
    $root = Join-Path $folder ('WeGame space ' + [char]0x7528 + [char]0x6237)
    $data = Join-Path $folder 'Profile data'
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'apps\Pallas\tp_deps'),$data)
    $dll = Join-Path $root 'apps\Pallas\tp_deps\TenPallas.dll'; $loader = Join-Path $root 'apps\Pallas\pallas.exe'
    $stockDll = $utf8.GetBytes('fixture original signed DLL'); $stockExe = $utf8.GetBytes('fixture original signed launcher')
    $modifiedExe = $utf8.GetBytes('fixture modified local launcher'); $oldV2 = $utf8.GetBytes('fixture earlier v2 DLL')
    $control = $utf8.GetBytes('fixture native twenty-key DLL')
    $script:LatestCandidateBytes = $utf8.GetBytes('fixture repaired independent-key DLL')
    $script:PortableOriginalHash = Get-ShoutByteHash $stockDll; $script:OriginalDllHash = $script:PortableOriginalHash
    $script:PortableLoaderHash = Get-ShoutByteHash $stockExe; $script:OriginalLauncherHash = $script:PortableLoaderHash
    $script:PortableV2LoaderHash = Get-ShoutByteHash $modifiedExe; $script:ModifiedLauncherHash = $script:PortableV2LoaderHash
    $script:PortableV2Hash = Get-ShoutByteHash $oldV2
    $script:PortableTargetHash = Get-ShoutByteHash $control; $script:NativeKeysHash = $script:PortableTargetHash
    $script:PortableNativeControlHash = $script:NativeKeysHash
    $script:PortablePreviousHash = Get-ShoutByteHash ($utf8.GetBytes('fixture previous portable DLL'))
    [IO.File]::WriteAllBytes($dll,$stockDll); [IO.File]::WriteAllBytes($loader,$stockExe)
    $context = New-PortableContext $root $data
    [void](Install-PortableComponent $context $Compiled $control)
    $record = Read-PortableState $context
    # Reproduce the real historical v2 restore baseline, not a stock baseline.
    [IO.File]::WriteAllBytes((Join-Path $data ('backups\' + $record.backup_id + '\TenPallas.before.dll')),$oldV2)
    $record.baseline_dll_sha256 = $script:PortableV2Hash
    $record | Add-Member -NotePropertyName keyboard_mode -NotePropertyValue 'native20'
    [IO.File]::WriteAllBytes($loader,$modifiedExe); $context.LoaderHash = $script:ModifiedLauncherHash
    $record.loader_sha256 = $context.LoaderHash; Save-PortableState $context $record
    $legacyFolder = Join-Path $data 'LocalSchemeExperiment'; [void](New-Item -ItemType Directory -Path $legacyFolder)
    $script:StockPath = Join-Path $legacyFolder 'pallas.original.exe'
    $script:LegacyPath = Join-Path $legacyFolder 'state.json'
    [IO.File]::WriteAllBytes($script:StockPath,$stockExe)
    $legacy = [ordered]@{experiment='Pallas local-file scheme v1';status='installed';program_path=$loader
        backup_path=$script:StockPath;original_sha256=$script:OriginalLauncherHash;candidate_sha256=$script:ModifiedLauncherHash
        native_runtime_verified=$false;game_send_verified=$false}
    [IO.File]::WriteAllBytes($script:LegacyPath,$utf8.GetBytes(($legacy | ConvertTo-Json)))
    $stockDllPath = Join-Path $folder 'stock-original-dll-fixture.bin'; [IO.File]::WriteAllBytes($stockDllPath,$stockDll)
    [void](Restore-OriginalDllOnly $context $stockDllPath 6>$null)
    $editor = Join-Path $data 'Editor'; [void](New-Item -ItemType Directory -Path $editor)
    $draft = $Compiled.Scheme | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $draft.'0' = 'fixture unapplied draft'; $draft.bind0 = 'Ctrl+Alt+Q'
    [void](Save-HotkeyDocument $draft (Join-Path $editor 'messages.json') $null -FormatVersion 3)
    [IO.File]::WriteAllBytes((Join-Path $editor 'settings.json'),$utf8.GetBytes('fixture editor settings unchanged'))
    if ($FullyRestored) {
        [void](Restore-OriginalLauncherOnly $context $script:StockPath $script:LegacyPath 6>$null)
        $script:PortableTargetHash = Get-ShoutByteHash $script:LatestCandidateBytes
    }
    return $context
}
