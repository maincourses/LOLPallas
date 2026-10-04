# Called by the small ASCII .cmd launchers. No forced process shutdown.
param([ValidateSet('Install','Choose','Editor','Status','Restore')][string]$Action = 'Editor')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\PortableTools.ps1')
try {
    if ($Action -eq 'Editor') {
        & (Join-Path $PSScriptRoot 'Edit-Hotkeys-GUI.ps1') -Portable; exit $LASTEXITCODE
    }
    $data = Get-PortableDataRoot; $wegame = $null
    if ($Action -ne 'Choose') { try { $wegame = Resolve-PortableRoot '' $data } catch { Write-Host $_.Exception.Message } }
    if (-not $wegame) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select your WeGame INSTALLATION folder (contains apps\Pallas). Not the LoL game folder.'
        $dialog.ShowNewFolderButton = $false
        try { if ($dialog.ShowDialog() -ne 'OK') { Write-Host 'Cancelled. No files changed.'; exit 0 }; $wegame = Resolve-PortableRoot $dialog.SelectedPath $data }
        finally { $dialog.Dispose() }
    }
    $mode = $Action; if ($Action -eq 'Choose') { $mode = 'Install' }
    if ($mode -eq 'Install') {
        Write-Host 'TEST BUILD: this changes a WeGame component and invalidates its signature.' -ForegroundColor Yellow
        Write-Host 'No game/anti-cheat bypass. Backups first. Unknown versions are rejected. Game sending remains unverified.'
        Write-Host 'Exit LoL and exit WeGame from its system tray. Type YES to accept this unsigned experiment.'
        if ((Read-Host 'Consent') -cne 'YES') { Write-Host 'Cancelled. No files changed.'; exit 0 }
    }
    if ($mode -ne 'Status') { Assert-ShoutStopped }
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-PortableArgument (Join-Path $PSScriptRoot 'Manage-Pallas-Portable.ps1')) +
        ' -Mode ' + $mode + ' -WeGameRoot ' + (ConvertTo-PortableArgument $wegame) + ' -ExpectedSid ' + (ConvertTo-PortableArgument (Get-PortableSid))
    if ($mode -eq 'Install') { $arguments += ' -AcceptUnsignedExperiment' }
    $administrator = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $options = @{ FilePath = $shell; ArgumentList = $arguments; Wait = $true; PassThru = $true }
    if ($mode -in @('Install','Restore') -and -not $administrator) {
        # UI is needed to display installation progress / errors after UAC consent.
        $options.Verb = 'RunAs'
        $options.ArgumentList = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-PortableArgument (Join-Path $PSScriptRoot 'Run-Portable-Admin.ps1')) +
            ' -Mode ' + $mode + ' -WeGameRoot ' + (ConvertTo-PortableArgument $wegame) + ' -ExpectedSid ' + (ConvertTo-PortableArgument (Get-PortableSid))
        Write-Host 'A normal same-user administrator prompt will appear. Do not enter another Windows account.'
    } else { $options.NoNewWindow = $true }
    $process = Start-Process @options
    exit $process.ExitCode
} catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
