# Current-profile experiment only. No game launch, injection, or automatic sends.
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Status','Validate','Install','Apply','Restore')][string]$Mode='Status',
    [string]$WeGameRoot,[string]$SchemePath,[string]$ExpectedSid,[switch]$AcceptUnsignedExperiment,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
$tenOptions=@{Mode=$Mode;Root=$WeGameRoot;Scheme=$SchemePath;Sid=$ExpectedSid;Accept=$AcceptUnsignedExperiment;FunctionsOnly=$FunctionsOnly}
. (Join-Path $PSScriptRoot 'lib\BanksTenTools.ps1')
$Mode=$tenOptions.Mode; $WeGameRoot=$tenOptions.Root; $SchemePath=$tenOptions.Scheme; $ExpectedSid=$tenOptions.Sid
$AcceptUnsignedExperiment=$tenOptions.Accept; $FunctionsOnly=$tenOptions.FunctionsOnly
function Get-BanksTenArtifacts([string]$Build,[string]$Seed) {
    [void](Assert-PortablePath $Build); [void](Assert-PortablePath $Seed)
    $dll=Join-Path $Build 'TenPallas.banks10.experimental.dll'
    Assert-ShoutHash $dll $script:BanksTenHash
    $proof=& 'D:\anaconda\python.exe' (Join-Path $PSScriptRoot 'tools\native\ValidateBanksTenInstall.py') --build $Build --seed-library $Seed
    if ($LASTEXITCODE -ne 0 -or ($proof | ConvertFrom-Json).passed -ne $true) { throw 'Read-only offline proof validation failed.' }
    if ((Get-AuthenticodeSignature -LiteralPath $dll).Status.ToString() -ne 'HashMismatch') { throw 'Unexpected signature status; no integrity/security bypass.' }
    return [pscustomobject]@{Dll=([IO.File]::ReadAllBytes($dll));Library=([IO.File]::ReadAllBytes((Join-Path $Build 'library80.json')))
        Response=([IO.File]::ReadAllBytes((Join-Path $Build 'local-response80.json')))}
}
if ($FunctionsOnly) { return }
$mutex=$null; $held=$false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Requires x64 Windows PowerShell.' }
    if ($ExpectedSid -and (Get-PortableSid) -ne $ExpectedSid) { throw 'Windows account changed; no writes.' }
    if ((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout') -ne $script:Working8KProfile) { throw 'This historical reader is profile-pinned; not portable.' }
    $data=Get-PortableDataRoot
    $context=New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
    if ($Mode -eq 'Status') {
        $r=(Read-BanksTenRecord $context $script:Working8KProfile).Record
        Write-Host ('Control: '+$r.status+'; eight groups of ten; no single-message character cap. Backup: '+$r.backup)
        Write-Host ('DLL matching: '+((Get-ShoutFileHash $context.Dll) -eq $script:BanksTenHash)+'; loader unchanged: '+((Get-ShoutFileHash $context.Loader) -eq $script:Working8KLoaderHash))
        foreach ($e in $r.changes) { Write-Host ('File matching target: '+((Get-ShoutFileHash $e.Path) -eq $e.TargetHash)+'; '+$e.Path) }
        Write-Host ('Latest local game log: '+((Get-PortableRuntimeEvidence $context $r) | ConvertTo-Json -Compress))
        Write-Host 'Panel is first-group preview only. Long-message game limits/safety are NOT changed or guaranteed.'; exit 0
    }
    $mutexId=(Get-ShoutByteHash ([Text.Encoding]::UTF8.GetBytes($context.Dll.ToUpperInvariant()))).Substring(0,24)
    $mutex=New-Object Threading.Mutex($false,('Global\LOLPallasPortable-'+$mutexId))
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Another component operation is running.' }
    if ($Mode -eq 'Restore') {
        if ($PSCmdlet.ShouldProcess($context.Dll,'Archive current texts and restore exact previous four-bank profile and records')) {
            Invoke-BanksTenRestore $context $script:Working8KProfile
            Write-Host 'RESTORED AND READ BACK: exact previous four groups of twenty. Current texts archived; drafts retained.'
        }; exit 0
    }
    if ($Mode -eq 'Apply') {
        if (-not $SchemePath) { throw 'SchemePath required; no implicit replacement with public defaults.' }
        [void](Assert-PortablePath $SchemePath); $sourceHash=Get-ShoutFileHash $SchemePath
        $scheme=Get-Content -LiteralPath $SchemePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $plan=New-BanksTenApplyPlan $context $script:Working8KProfile $scheme
        Assert-ShoutHash $SchemePath $sourceHash
        if ($PSCmdlet.ShouldProcess($plan.Entries[0].Path,'Backup and apply eighty local texts; no DLL/loader writes or character-count cap')) {
            Invoke-BanksTenApply $context $plan
            Write-Host ('TEXTS APPLIED AND READ BACK. Backup: '+$plan.Backup+'; restart WeGame and enter a NEW training session.')
        }; exit 0
    }
    $build=Join-Path $PSScriptRoot 'build\legacy-eight-banks-ten-20261005'
    $plan=New-BanksTenInstallPlan $context $script:Working8KProfile (Get-BanksTenArtifacts $build (Join-Path $script:Working8KProfile 'library20-v1.json'))
    Assert-BanksTenPlan $context $plan
    if ($Mode -eq 'Validate') { Write-Host 'VALID: eight groups of ten; eighty existing texts retained; no live writes.'; exit 0 }
    if (-not $AcceptUnsignedExperiment) { throw 'Explicit experiment acceptance required; never bypass security.' }
    if ($PSCmdlet.ShouldProcess($context.Dll,'Back up current successful profile and all texts; install eight ten-key banks without an individual character cap')) {
        Invoke-BanksTenInstall $context $plan
        Write-Host ('INSTALLED AND READ BACK: eight groups of ten / native digits / no individual character cap. Backup: '+$plan.Backup)
        Write-Host 'Loader unchanged. No game launched or message sent. New training-session test required.'
    }; exit 0
} catch { Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
finally { if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
