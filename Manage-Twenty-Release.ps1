[CmdletBinding(SupportsShouldProcess = $true)]
param([ValidateSet('Status', 'Validate', 'Enable', 'Apply', 'Restore')][string]$Mode = 'Status')

$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) }
. (Join-Path $PSScriptRoot 'lib\ShoutTools.ps1')
$SchemePath = Join-Path $PSScriptRoot 'scheme20.json'
$DllPath = 'D:\Program Files (x86)\WeGame\apps\Pallas\tp_deps\TenPallas.dll'
$PallasPath = 'D:\Program Files (x86)\WeGame\apps\Pallas\pallas.exe'
$OriginalHash = '97BA57FD47A393A3A4BBFA684D0F03D10CF04344FBD99CB2D2E8626675BE9C94'
$TwentyHash = '3BCEFF093D67F86400DD0F3F1ECE50F812D531926D5FF64CF72C227904DA5D00'
$LoaderHash = '803870E3FDA683443471E835699B065293724DC7E0F3289D0093FC84C8E30935'
$ResponsePath = 'C:\Users\zly\AppData\Local\PallasCustomShout\local-response.json'
$StateDirectory = 'C:\Users\zly\AppData\Local\PallasCustomShout\TwentyMessageExperiment'
$EnginePath = Join-Path $PSScriptRoot 'engine\Manage-Pallas-Twenty.ps1'
$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-ReleaseProfile {
    $expectedProfilePath = Join-Path $env:LOCALAPPDATA 'PallasCustomShout\local-response.json'
    if ([IO.Path]::GetFullPath($expectedProfilePath) -ne $ResponsePath) {
        throw 'This package requires the existing zly-profile local loader. It is not a universal installer.'
    }
    Assert-ShoutHash $PallasPath $LoaderHash
}

try {
    if ($Mode -eq 'Status') {
        Write-Host ('Twenty-message DLL matching: ' + ((Get-ShoutFileHash $DllPath) -eq $TwentyHash))
        Write-Host ('Required local-file loader matching: ' + ((Get-ShoutFileHash $PallasPath) -eq $LoaderHash))
        Write-Host ('Edit this file: ' + $SchemePath)
        try {
            $live = Read-ShoutScheme $ResponsePath
            $count = @($live.Scheme.PSObject.Properties | Where-Object { $_.Name -match '^(?:[0-9]|1[0-9])$' }).Count
            Write-Host ('Current local message count: ' + $count)
            Write-Host ('Current whole-scheme UTF-8 bytes: ' + $live.Bytes + ' / 2046')
        } catch { Write-Warning ('Could not read current response: ' + $_.Exception.Message) }
        try {
            $source = ConvertTo-TwentyResponse (Get-Content -LiteralPath $SchemePath -Raw -Encoding UTF8)
            Write-Host ('Source JSON valid. Matches current local response: ' + ((Get-ShoutFileHash $ResponsePath) -eq $source.ResponseHash))
        } catch { Write-Warning ('Source JSON needs attention: ' + $_.Exception.Message) }
        Write-Host 'Keys: hold tilde, release 1..9/0 for messages 1..10; release F1..F10 for messages 11..20.'
        Write-Host 'The panel displays only ten entries. File checks do not prove current game sending.'
        exit 0
    }
    if ($Mode -eq 'Restore') {
        Assert-ReleaseProfile
        Assert-ShoutStopped
        if (-not $PSCmdlet.ShouldProcess($DllPath, 'Restore the original TEN-message DLL and pre-twenty response, preserving edited response')) { exit 0 }
        & $WindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Mode Restore
        exit $LASTEXITCODE
    }

    $sourceHash = Get-ShoutFileHash $SchemePath
    $compiled = ConvertTo-TwentyResponse (Get-Content -LiteralPath $SchemePath -Raw -Encoding UTF8)
    Assert-ShoutHash $SchemePath $sourceHash
    Write-Host ('VALID: twenty messages; whole scheme ' + $compiled.SchemeBytes.Length + ' / 2046 UTF-8 bytes.')
    if ($Mode -eq 'Validate') { Write-Host 'Offline validation only. No live files changed.'; exit 0 }
    Assert-ReleaseProfile
    Assert-ShoutStopped
    $currentDll = Get-ShoutFileHash $DllPath
    if ($Mode -eq 'Enable' -and $currentDll -eq $OriginalHash) {
        if (Test-Path -LiteralPath $StateDirectory) {
            throw 'Original DLL and an existing experiment backup were found. Backups will not be overwritten; reinstall needs review. Your files were not changed.'
        }
        if (-not $PSCmdlet.ShouldProcess($DllPath, 'Install the version-pinned experimental twenty-message DLL; its Authenticode digest is invalid')) { exit 0 }
        & $WindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $EnginePath -Mode Install -AcceptUnsignedExperiment
        if ($LASTEXITCODE -ne 0) { throw 'Twenty-message installation did not complete. Stop and review its output.' }
    }
    Assert-ShoutHash $DllPath $TwentyHash
    $currentHash = Get-ShoutFileHash $ResponsePath
    if (-not $currentHash) { throw 'Existing local response missing; refusing to guess or replace a missing prerequisite.' }
    $before = Read-ShoutScheme $ResponsePath
    foreach ($index in 0..19) {
        if ($before.Scheme.($index.ToString()) -isnot [string]) { throw 'Existing response is not a twenty-message scheme.' }
    }
    if ($currentHash -eq $compiled.ResponseHash) {
        Write-Host 'Already applied. No files changed. Restart WeGame manually if needed.'
        exit 0
    }
    if (-not $PSCmdlet.ShouldProcess($ResponsePath, 'Back up the current response and apply scheme20.json; no DLL/game changes or messages')) { exit 0 }
    Assert-ShoutStopped
    Assert-ShoutHash $SchemePath $sourceHash
    Assert-ShoutHash $DllPath $TwentyHash
    Assert-ShoutHash $PallasPath $LoaderHash
    Assert-ShoutHash $ResponsePath $currentHash
    $backupDirectory = Join-Path $StateDirectory 'TextBackups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupPath = Join-Path $backupDirectory ('response-before-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::Copy($ResponsePath, $backupPath, $false)
    Assert-ShoutHash $backupPath $currentHash
    Write-ShoutResponse $compiled.ResponseBytes $ResponsePath $currentHash $DllPath $TwentyHash $PallasPath $LoaderHash
    Write-Host 'APPLIED AND READ BACK: your twenty messages. Start WeGame manually.'
    Write-Host ('Previous response backup: ' + $backupPath)
    Write-Host 'No game messages were sent. Do not edit these local messages in the cloud settings page.'
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'The script does not terminate processes or bypass unknown version/signature checks.'
    exit 1
}
