# Visible interactive console: show install errors/results after normal UAC.
param([ValidateSet('Install','Restore')][string]$Mode, [string]$WeGameRoot, [string]$ExpectedSid)
$ErrorActionPreference = 'Stop'
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$options = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Manage-Pallas-Portable.ps1'),
    '-Mode',$Mode,'-WeGameRoot',$WeGameRoot,'-ExpectedSid',$ExpectedSid)
if ($Mode -eq 'Install') { $options += '-AcceptUnsignedExperiment' }
& $shell @options
$code = $LASTEXITCODE
Write-Host ('Exit code: ' + $code)
[void](Read-Host 'Press Enter to close this result window')
exit $code
