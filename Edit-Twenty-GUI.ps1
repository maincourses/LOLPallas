param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ShoutTools.ps1')
. (Join-Path $PSScriptRoot 'lib\EditorTools.ps1')
. (Join-Path $PSScriptRoot 'lib\EditorView.ps1')
$ui = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lib\editor-ui.zh-CN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sourcePath = Join-Path $PSScriptRoot 'scheme20.json'
$script:Editor = $null

function Get-EditorDraft {
    $draft = [ordered]@{ title = $script:Editor.View.TitleBox.Text; key = ($script:Editor.View.PanelBox.SelectedIndex + 1) }
    foreach ($index in 0..19) { $draft[$index.ToString()] = $script:Editor.View.Boxes[$index].Text }
    return [pscustomobject]$draft
}

function Update-EditorDraft {
    if ($script:Editor.Loading) { return }
    $view = $script:Editor.View
    $panel = '~'; if ($view.PanelBox.SelectedIndex -eq 1) { $panel = 'Ctrl' }
    foreach ($index in 0..19) {
        if ($index -lt 10) { $key = ($index + 1).ToString(); if ($index -eq 9) { $key = '0' } }
        else { $key = 'F' + ($index - 9) }
        $view.KeyLabels[$index].Text = $panel + ' + ' + $key
        $length = $view.Boxes[$index].Text.Length
        $view.Counts[$index].Text = $length.ToString() + ' / 50'
        $view.Counts[$index].ForeColor = [Drawing.Color]::FromArgb(91, 104, 124)
        if ($length -gt 50) { $view.Counts[$index].ForeColor = [Drawing.Color]::Firebrick }
    }
    try {
        $compiled = ConvertTo-TwentyResponse ((Get-EditorDraft) | ConvertTo-Json -Depth 4)
        $view.Capacity.Text = $ui.capacity -f $compiled.SchemeBytes.Length
        $view.Capacity.ForeColor = [Drawing.Color]::FromArgb(27, 40, 59)
        $view.Save.Enabled = $true; $view.Apply.Enabled = $true
        $script:Editor.Dirty = ($compiled.ResponseHash -ne $script:Editor.SavedWireHash)
    } catch {
        $view.Capacity.Text = $ui.capacityInvalid + ' ' + $_.Exception.Message
        $view.Capacity.ForeColor = [Drawing.Color]::Firebrick
        $view.Save.Enabled = $false; $view.Apply.Enabled = $false
        $script:Editor.Dirty = $true
    }
    $view.Form.Text = $ui.window
    if ($script:Editor.Dirty) { $view.Form.Text += ' *'; $view.Status.Text = $ui.dirty }
}

function Set-EditorDraft($Scheme) {
    $script:Editor.Loading = $true
    try {
        $script:Editor.View.TitleBox.Text = $Scheme.title
        $script:Editor.View.PanelBox.SelectedIndex = [int]$Scheme.key - 1
        foreach ($index in 0..19) { $script:Editor.View.Boxes[$index].Text = $Scheme.($index.ToString()) }
    } finally { $script:Editor.Loading = $false }
    Update-EditorDraft
}

function Confirm-EditorDiscard {
    if (-not $script:Editor.Dirty) { return $true }
    return ([Windows.Forms.MessageBox]::Show($script:Editor.View.Form, $ui.discard, $ui.discardTitle,
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question) -eq [Windows.Forms.DialogResult]::Yes)
}

function Show-EditorError([string]$Message) {
    [void][Windows.Forms.MessageBox]::Show($script:Editor.View.Form, $Message, $ui.error,
        [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
}

function Save-EditorDraft {
    try {
        $saved = Save-EditorDocument (Get-EditorDraft) $sourcePath $script:Editor.FileHash
        $script:Editor.FileHash = $saved.Hash
        $script:Editor.SavedWireHash = $saved.Compiled.ResponseHash
        Update-EditorDraft
        $script:Editor.View.Status.Text = $ui.same
        if ($saved.Changed) {
            $script:Editor.View.Status.Text = $ui.saved
            $script:Editor.View.Tooltip.SetToolTip($script:Editor.View.Status, $saved.Backup)
        }
        return $true
    } catch { Show-EditorError $_.Exception.Message; return $false }
}

function Invoke-GuiBackend([string]$Mode) {
    $view = $script:Editor.View
    $view.Form.Enabled = $false; $view.Form.UseWaitCursor = $true
    $view.Status.Text = $ui.backendBusy; $view.Form.Refresh()
    try {
        $result = Invoke-EditorBackend $PSScriptRoot $Mode
        if ($Mode -eq 'Status') {
            [void][Windows.Forms.MessageBox]::Show($view.Form, $result.Output, $ui.checkTitle,
                [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
            $view.Status.Text = $ui.checked
        } elseif ($result.ExitCode -eq 0) { $view.Status.Text = $ui.applied }
        else { $view.Status.Text = $ui.applyFail; Show-EditorError ($ui.applyFail + "`r`n`r`n" + $result.Output) }
    } catch { $view.Status.Text = $_.Exception.Message; Show-EditorError $_.Exception.Message }
    finally { $view.Form.Enabled = $true; $view.Form.UseWaitCursor = $false }
}

try {
    if ($SelfTest) { $document = Read-EditorDocument (Join-Path $PSScriptRoot 'scheme20.example.json') }
    else {
        Initialize-ShoutSource $sourcePath (Join-Path $PSScriptRoot 'scheme20.example.json')
        $document = Read-EditorDocument $sourcePath
    }
    $view = New-TwentyEditorView $ui
    $script:Editor = [pscustomobject]@{
        View = $view; FileHash = $document.Hash; SavedWireHash = $document.Compiled.ResponseHash
        Loading = $true; Dirty = $false
    }
    $view.TitleBox.Add_TextChanged({ Update-EditorDraft })
    $view.PanelBox.Add_SelectedIndexChanged({ Update-EditorDraft })
    foreach ($box in $view.Boxes) { $box.Add_TextChanged({ Update-EditorDraft }) }
    $view.Save.Add_Click({ [void](Save-EditorDraft) })
    $view.Apply.Add_Click({ if (Save-EditorDraft) { Invoke-GuiBackend 'Apply' } })
    $view.Check.Add_Click({ Invoke-GuiBackend 'Status' })
    $view.Reload.Add_Click({
        if (-not (Confirm-EditorDiscard)) { return }
        try {
            $document = Read-EditorDocument $sourcePath
            $script:Editor.FileHash = $document.Hash; $script:Editor.SavedWireHash = $document.Compiled.ResponseHash
            Set-EditorDraft $document.Compiled.Scheme
            $script:Editor.View.Status.Text = $ui.loaded
        } catch { Show-EditorError $_.Exception.Message }
    })
    $view.Live.Add_Click({
        if (-not (Confirm-EditorDiscard)) { return }
        try {
            $path = Join-Path $env:LOCALAPPDATA 'PallasCustomShout\local-response.json'
            $live = Read-ShoutScheme $path
            $compiled = ConvertTo-TwentyResponse ($live.Scheme | ConvertTo-Json -Depth 4)
            Set-EditorDraft $compiled.Scheme
            $script:Editor.View.Status.Text = $ui.imported
        } catch { Show-EditorError $_.Exception.Message }
    })
    $view.Form.Add_FormClosing({ param($sender, $event) if (-not (Confirm-EditorDiscard)) { $event.Cancel = $true } })
    Set-EditorDraft $document.Compiled.Scheme
    $view.Status.Text = $ui.loaded
    $view.Tooltip.SetToolTip($view.Status, ($ui.file -f $sourcePath))
    if ($SelfTest) {
        if ($view.Boxes.Count -ne 20 -or $view.Tabs.TabPages.Count -ne 2 -or $script:Editor.Dirty) { throw 'Editor initialization check failed.' }
        if ($view.PanelBox.SelectedIndex -ne 0 -or $view.PanelBox.Text -cne $ui.tilde) { throw 'Panel selector initial text check failed.' }
        if ($view.KeyLabels[9].Text -ne '~ + 0' -or $view.KeyLabels[19].Text -ne '~ + F10') { throw 'Hotkey mapping check failed.' }
        $view.Boxes[0].Text = 'x' * 51
        if ($view.Save.Enabled -or $view.Apply.Enabled -or -not $script:Editor.Dirty) { throw 'Over-limit UI guard check failed.' }
        $view.Boxes[0].Text = $document.Compiled.Scheme.'0'
        if (-not $view.Save.Enabled -or $script:Editor.Dirty) { throw 'UI dirty reset check failed.' }
        $view.PanelBox.SelectedIndex = 1
        if ($view.KeyLabels[10].Text -ne 'Ctrl + F1' -or -not $script:Editor.Dirty) { throw 'Panel-key UI check failed.' }
        Write-Output 'GUI SELF TEST PASSED: twenty boxes, two banks, key mapping, dirty state and non-truncating guards. Form not shown; no saves/applications.'
        $view.Tooltip.Dispose(); $view.Form.Dispose()
        exit 0
    }
    [void]$view.Form.ShowDialog()
    $view.Tooltip.Dispose(); $view.Form.Dispose()
    exit 0
} catch {
    if ($SelfTest) { Write-Error $_; exit 1 }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($ui.startupFail + "`r`n`r`n" + $_.Exception.Message, $ui.error,
        [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
