param([switch]$SelfTest, [switch]$InitializeOnly, [string]$PreviewPath, [switch]$Portable, [switch]$NativeKeys,
    [switch]$Standalone, [string]$SourcePath, [string]$HostExecutable, [string]$HostExecutableHash)
$ErrorActionPreference = 'Stop'
trap {
    if (-not $SelfTest -and -not $InitializeOnly) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Local hotkey editor startup failed', 'OK', 'Error')
    } else { Write-Host ('ERROR: ' + $_.Exception.Message) }
    exit 1
}
. (Join-Path $PSScriptRoot 'lib\HotkeyTools.ps1')
if (-not $Portable) { . (Join-Path $PSScriptRoot 'lib\EditorTools.ps1') }
$script:BinaryVersion = 2
if ($Portable) { . (Join-Path $PSScriptRoot 'lib\PortableTools.ps1'); $script:BinaryVersion = 3 }
if ($NativeKeys) {
    if (-not $Portable -or $Standalone) { throw 'Native-key control editor requires portable mode, not the earlier standalone host.' }
    . (Join-Path $PSScriptRoot 'lib\NativeKeyTools.ps1')
}
$providedSourcePath = $SourcePath
$script:SourcePath = Join-Path $PSScriptRoot 'messages.json'
if ($providedSourcePath) { $script:SourcePath = [IO.Path]::GetFullPath($providedSourcePath) }
if ($Standalone) {
    if (-not $Portable) { throw 'Standalone editor requires portable mode.' }
    . (Join-Path $PSScriptRoot 'lib\StandaloneTools.ps1')
    if (-not $SelfTest) { Assert-ShoutHash $HostExecutable $HostExecutableHash }
    [void](Assert-PortablePath $script:SourcePath)
    $script:EditorRoot = Split-Path -Parent $script:SourcePath
    $script:SettingsPath = Join-Path $script:EditorRoot 'settings.json'
    $script:Settings = $null; $script:SelectedWeGame = ''
    if (-not $SelfTest) {
        New-Item -ItemType Directory -Path $script:EditorRoot -Force | Out-Null
        $script:Settings = Read-StandaloneSettings $script:SettingsPath
        if ($script:Settings -and (Test-PortableRoot $script:Settings.Root)) { $script:SelectedWeGame = $script:Settings.Root }
    }
}
if ($SelfTest) {
    $script:SourcePath = Join-Path $PSScriptRoot 'messages.example.json'
    if ($NativeKeys) { $script:SourcePath = Join-Path $PSScriptRoot 'portable\messages.example.json' }
}
if (-not (Test-Path -LiteralPath $script:SourcePath)) {
    $legacy = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PallasCustomShout\library20-v1.json'
    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf)) { $legacy = Join-Path $PSScriptRoot 'scheme20.json' }
    if ($Portable) {
        $applied = Join-Path (Get-PortableDataRoot) 'applied-messages.json'
        $statePath = Join-Path (Get-PortableDataRoot) 'state.json'
        if ((Test-Path -LiteralPath $statePath -PathType Leaf) -and (Test-Path -LiteralPath $applied -PathType Leaf)) {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.experiment -ne 'portable-hotkeys-v3' -or $state.sid -ne (Get-PortableSid) -or $state.source_path -ne $applied) { throw 'Unrecognized installed source record.' }
            Assert-ShoutHash $applied $state.installed_source_sha256
            $scheme = (Read-HotkeyDocument $applied -FormatVersion 3).Compiled.Scheme
        } else { $scheme = (Read-HotkeyDocument (Join-Path $PSScriptRoot 'messages.example.json') -FormatVersion 3).Compiled.Scheme }
    } elseif (Test-Path -LiteralPath $legacy -PathType Leaf) {
        $before = Get-ShoutFileHash $legacy
        $scheme = ConvertFrom-LegacyHotkeys (Get-Content -LiteralPath $legacy -Raw -Encoding UTF8)
        Assert-ShoutHash $legacy $before
    } else { $scheme = (Read-HotkeyDocument (Join-Path $PSScriptRoot 'messages.example.json')).Compiled.Scheme }
    [void](Save-HotkeyDocument $scheme $script:SourcePath $null -FormatVersion $script:BinaryVersion)
}
$script:Document = Read-HotkeyDocument $script:SourcePath -FormatVersion $script:BinaryVersion
if ($InitializeOnly) { Write-Host ('Source ready: ' + $script:SourcePath); exit 0 }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:Ui = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lib\hotkeys-ui.zh-CN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Portable) { $script:Ui.title = $script:Ui.portableTitle; $script:Ui.applyNote = $script:Ui.portableApplyNote }
if ($Standalone) { $script:Ui.title = $script:Ui.standaloneTitle; $script:Ui.applyNote = $script:Ui.standaloneApplyNote }
if ($NativeKeys) {
    Assert-NativeKeyScheme $script:Document.Compiled.Scheme
    $script:Ui.title = $script:Ui.nativeKeysTitle; $script:Ui.subtitle = $script:Ui.nativeKeysSubtitle
    $script:Ui.warning = $script:Ui.nativeKeysWarning; $script:Ui.applyNote = $script:Ui.nativeKeysNote
}
$script:Loading = $false; $script:SavedDraft = ''; $script:Dirty = $false; $script:Valid = $false
$script:View = @{}
$form = New-Object Windows.Forms.Form
$form.Text = $script:Ui.title; $form.Size = New-Object Drawing.Size(1100, 780)
if ($Standalone) { $form.Size = New-Object Drawing.Size(1150, 850) }
$form.MinimumSize = New-Object Drawing.Size(950, 640); $form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$form.BackColor = [Drawing.Color]::WhiteSmoke
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.Padding = New-Object Windows.Forms.Padding(16)
$layout.ColumnCount = 1; $layout.RowCount = 8
if ($Standalone) { $layout.RowCount = 10 }
foreach ($height in @(40, 48, 38)) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
if ($Standalone) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 40))) }
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$bottomHeights = @(40,40,48,34); if ($Standalone) { $bottomHeights = @(40,40,40,56,34) }
foreach ($height in $bottomHeights) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
$form.Controls.Add($layout)
function Add-Label([string]$Text, [int]$Row) {
    $label = New-Object Windows.Forms.Label; $label.Text = $Text; $label.Dock = 'Fill'; $label.TextAlign = 'MiddleLeft'
    $label.AutoEllipsis = $true; $layout.Controls.Add($label, 0, $Row); return $label
}
[void](Add-Label $script:Ui.subtitle 0)
$warning = Add-Label $script:Ui.warning 1; $warning.ForeColor = [Drawing.Color]::DarkGoldenrod
$titlePanel = New-Object Windows.Forms.FlowLayoutPanel; $titlePanel.Dock = 'Fill'
$titleLabel = New-Object Windows.Forms.Label; $titleLabel.Text = $script:Ui.schemeTitle; $titleLabel.AutoSize = $true
$titleBox = New-Object Windows.Forms.TextBox; $titleBox.Width = 380; $titleBox.MaxLength = 0
$titlePanel.Controls.Add($titleLabel); $titlePanel.Controls.Add($titleBox); $layout.Controls.Add($titlePanel, 0, 2)
$buttons = @{}; $wegameBox = $null
if ($Standalone) {
    $pathPanel = New-Object Windows.Forms.FlowLayoutPanel; $pathPanel.Dock = 'Fill'
    $pathLabel = New-Object Windows.Forms.Label; $pathLabel.Text = $script:Ui.wegamePath; $pathLabel.AutoSize = $true
    $pathPanel.Controls.Add($pathLabel)
    $wegameBox = New-Object Windows.Forms.TextBox; $wegameBox.Width = 480; $wegameBox.ReadOnly = $true; $wegameBox.Text = $script:SelectedWeGame
    $pathPanel.Controls.Add($wegameBox)
    foreach ($name in @('choose','detect')) {
        $button = New-Object Windows.Forms.Button; $button.Text = $script:Ui.$name; $button.Tag = $name
        $button.AutoSize = $true; $button.Height = 32; $pathPanel.Controls.Add($button); $buttons[$name] = $button
    }
    $layout.Controls.Add($pathPanel,0,3)
}
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.AllowUserToOrderColumns = $false; $grid.MultiSelect = $false; $grid.SelectionMode = 'FullRowSelect'
$grid.RowHeadersVisible = $false; $grid.BackgroundColor = [Drawing.Color]::White
$grid.AutoSizeRowsMode = 'AllCells'; $grid.AutoSizeColumnsMode = 'Fill'; $grid.EditMode = 'EditOnKeystrokeOrF2'
foreach ($entry in @(@('index', 45, $true), @('binding', 160, $false), @('message', 580, $false), @('length', 75, $true))) {
    $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $entry[0]; $column.HeaderText = $script:Ui.($entry[0]); $column.FillWeight = $entry[1]
    $column.ReadOnly = $entry[2]; $column.SortMode = 'NotSortable'; $column.MaxInputLength = 0
    [void]$grid.Columns.Add($column)
}
$grid.Columns['message'].DefaultCellStyle.WrapMode = 'True'
if ($NativeKeys) { $grid.Columns['binding'].ReadOnly = $true }
$gridRow = 3; if ($Standalone) { $gridRow = 4 }
$layout.Controls.Add($grid, 0, $gridRow)
foreach ($row in ($gridRow + 1)..($gridRow + 2)) {
    $panel = New-Object Windows.Forms.FlowLayoutPanel; $panel.Dock = 'Fill'
    $names = @('add', 'remove', 'capture', 'reload'); if ($row -eq ($gridRow + 2)) { $names = @('save', 'apply', 'status') }
    if ($Standalone -and $row -eq ($gridRow + 1)) { $names += @('import','export') }
    foreach ($name in $names) {
        $button = New-Object Windows.Forms.Button; $button.Text = $script:Ui.$name; $button.Tag = $name
        $button.AutoSize = $true; $button.Height = 32; $panel.Controls.Add($button); $buttons[$name] = $button
    }
    $layout.Controls.Add($panel, 0, $row)
}
if ($Standalone) {
    $panel = New-Object Windows.Forms.FlowLayoutPanel; $panel.Dock = 'Fill'
    foreach ($name in @('install','restore','help')) {
        $button = New-Object Windows.Forms.Button; $button.Text = $script:Ui.$name; $button.Tag = $name
        $button.AutoSize = $true; $button.Height = 32; $panel.Controls.Add($button); $buttons[$name] = $button
    }
    $layout.Controls.Add($panel,0,7)
}
$summaryRow = 6; if ($Standalone) { $summaryRow = 8 }
$summary = Add-Label '' $summaryRow; $sourceLabel = Add-Label ($script:Ui.source + $script:SourcePath) ($summaryRow + 1)
$script:View = @{ Form = $form; Grid = $grid; Title = $titleBox; Summary = $summary; Buttons = $buttons; WeGame = $wegameBox }
function Get-Draft {
    $draft = [ordered]@{ version = 2; title = $script:View.Title.Text; count = $script:View.Grid.Rows.Count }
    foreach ($row in $script:View.Grid.Rows) {
        $draft[$row.Index.ToString()] = [string]$row.Cells['message'].Value
        $draft['bind' + $row.Index] = [string]$row.Cells['binding'].Value
    }
    return $draft
}
function Update-View {
    if ($script:Loading) { return }
    $draft = Get-Draft
    $script:Dirty = (($draft | ConvertTo-Json -Compress) -cne $script:SavedDraft)
    foreach ($row in $script:View.Grid.Rows) {
        $row.Cells['index'].Value = $row.Index + 1
        $size = ([string]$row.Cells['message'].Value).Length
        $row.Cells['length'].Value = $size.ToString() + '/50'
        $row.Cells['length'].Style.ForeColor = [Drawing.Color]::Black
        if ($size -gt 50) { $row.Cells['length'].Style.ForeColor = [Drawing.Color]::Firebrick }
    }
    try {
        $compiled = ConvertTo-HotkeyArtifacts ($draft | ConvertTo-Json -Depth 4) -FormatVersion $script:BinaryVersion
        if ($NativeKeys) { Assert-NativeKeyScheme $compiled.Scheme }
        $script:Valid = $true
        $script:View.Summary.Text = ($script:Ui.usage -f $draft.count, $compiled.LibraryBytes.Length) + "`r`n" + $script:Ui.applyNote
        $script:View.Summary.ForeColor = [Drawing.Color]::DarkGreen
    } catch {
        $script:Valid = $false; $script:View.Summary.Text = $script:Ui.invalid + $_.Exception.Message
        $script:View.Summary.ForeColor = [Drawing.Color]::Firebrick
    }
    $script:View.Buttons.save.Enabled = $script:Valid; $script:View.Buttons.apply.Enabled = $script:Valid
    $script:View.Buttons.add.Enabled = $script:View.Grid.Rows.Count -lt 512
    $script:View.Buttons.remove.Enabled = $script:View.Grid.Rows.Count -gt 1
    if ($NativeKeys) { foreach ($name in @('add','remove','capture')) { $script:View.Buttons[$name].Enabled = $false } }
}
function Set-Draft($Scheme) {
    $script:Loading = $true
    try {
        $script:View.Title.Text = $Scheme.title; $script:View.Grid.Rows.Clear()
        foreach ($i in 0..($Scheme.count - 1)) {
            [void]$script:View.Grid.Rows.Add(($i + 1), $Scheme.('bind' + $i), $Scheme.($i.ToString()), '')
        }
        $script:SavedDraft = (Get-Draft | ConvertTo-Json -Compress)
    } finally { $script:Loading = $false }
    Update-View
}
function Add-Message {
    if ($script:View.Grid.Rows.Count -ge 512) { return }
    $used = @($script:View.Grid.Rows | ForEach-Object {
        try { (Get-HotkeyBinding ([string]$_.Cells['binding'].Value)).Label } catch { '' }
    })
    $next = $null
    foreach ($mask in @(3, 7, 8, 5, 1, 2, 4, 6, 9, 10, 11, 12, 13, 14, 15)) {
        $parts = @()
        foreach ($item in @(@('Ctrl',1),@('Alt',2),@('Shift',4),@('~',8))) { if ($mask -band $item[1]) { $parts += $item[0] } }
        $prefix = ($parts -join '+') + '+'
        foreach ($key in @(1..9 | ForEach-Object { $_.ToString() }) + @('0') + @(0x41..0x5A | ForEach-Object { [string][char]$_ }) + @(1..24 | ForEach-Object { 'F' + $_ }) + @(0..9 | ForEach-Object { 'NUMPAD' + $_ }) + @('PAGEUP','PAGEDOWN','END','HOME','LEFT','UP','RIGHT','DOWN','INSERT','DELETE')) {
            $candidate = $prefix + $key
            try { [void](Get-HotkeyBinding $candidate) } catch { continue }
            if ($candidate -notin $used) { $next = $candidate; break }
        }
        if ($next) { break }
    }
    if (-not $next) { $next = 'Ctrl+Alt+Q' }
    $index = $script:View.Grid.Rows.Add(($script:View.Grid.Rows.Count + 1), $next, $script:Ui.newMessage, '')
    $script:View.Grid.CurrentCell = $script:View.Grid.Rows[$index].Cells['message']; Update-View
}
function Confirm-Discard {
    if (-not $script:Dirty) { return $true }
    return [Windows.Forms.MessageBox]::Show($script:Ui.dirtyPrompt, $script:Ui.title, 'YesNo', 'Question') -eq 'Yes'
}
function Invoke-HotkeyBackend([string]$Mode) {
    if ($Standalone) {
        $root = Get-SelectedWeGame
        return Invoke-StandaloneTask $HostExecutable $HostExecutableHash $Mode $root $script:SourcePath $script:EditorRoot
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $backend = 'Manage-Pallas-Hotkeys.ps1'; if ($Portable) { $backend = 'Manage-Pallas-Portable.ps1' }
    if ($NativeKeys) { $backend = 'Manage-Pallas-NativeKeys.ps1' }
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $backend) + '" -Mode ' + $Mode
    if ($NativeKeys) { $start.Arguments += ' -SchemePath ' + (ConvertTo-PortableArgument $script:SourcePath) }
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false); $start.StandardErrorEncoding = $start.StandardOutputEncoding
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start backend.' }
        $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
        $text = $out.GetAwaiter().GetResult() + $err.GetAwaiter().GetResult()
        if ($process.ExitCode) { throw $text }; return $text
    } finally { $process.Dispose() }
}
function Set-SelectedWeGame([string]$Root) {
    if (-not (Test-PortableRoot $Root)) { throw $script:Ui.invalidWeGame }
    $hash = $null; if ($script:Settings) { $hash = $script:Settings.Hash }
    $script:Settings = Save-StandaloneSettings $script:SettingsPath $Root $hash
    $script:SelectedWeGame = $script:Settings.Root; $script:View.WeGame.Text = $script:SelectedWeGame
}
function Choose-WeGame {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog; $dialog.Description = $script:Ui.chooseHint; $dialog.ShowNewFolderButton = $false
    if ($script:SelectedWeGame) { $dialog.SelectedPath = $script:SelectedWeGame }
    try { if ($dialog.ShowDialog($script:View.Form) -eq 'OK') { Set-SelectedWeGame $dialog.SelectedPath; return $true }; return $false }
    finally { $dialog.Dispose() }
}
function Get-SelectedWeGame {
    if (-not (Test-PortableRoot $script:SelectedWeGame)) {
        try { Set-SelectedWeGame (Resolve-PortableRoot '' (Get-PortableDataRoot)) }
        catch { if (-not (Choose-WeGame)) { throw $script:Ui.cancelled } }
    }
    return $script:SelectedWeGame
}
function Import-Messages {
    if (-not (Confirm-Discard)) { return }
    $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter = 'JSON (*.json)|*.json'; $dialog.Title = $script:Ui.import
    try {
        if ($dialog.ShowDialog($script:View.Form) -eq 'OK') {
            $imported = Read-HotkeyDocument $dialog.FileName -FormatVersion 3
            $oldSaved = $script:SavedDraft; Set-Draft $imported.Compiled.Scheme; $script:SavedDraft = $oldSaved; Update-View
            $script:View.Summary.Text = $script:Ui.imported
        }
    } finally { $dialog.Dispose() }
}
function Export-Messages {
    [void]$script:View.Grid.EndEdit()
    $compiled = ConvertTo-HotkeyArtifacts (Get-Draft | ConvertTo-Json -Depth 4) -FormatVersion 3
    $dialog = New-Object Windows.Forms.SaveFileDialog; $dialog.Filter = 'JSON (*.json)|*.json'; $dialog.FileName = 'messages.json'; $dialog.Title = $script:Ui.export
    try {
        if ($dialog.ShowDialog($script:View.Form) -eq 'OK') {
            if ([IO.Path]::GetFullPath($dialog.FileName) -eq $script:SourcePath) { Save-Draft }
            else { [void](Save-HotkeyDocument $compiled.Scheme $dialog.FileName (Get-ShoutFileHash $dialog.FileName) -FormatVersion 3) }
            $script:View.Summary.Text = $script:Ui.exported
        }
    } finally { $dialog.Dispose() }
}
function Install-FromEditor {
    Save-Draft; $root = Get-SelectedWeGame
    $context = New-PortableContext $root (Get-PortableDataRoot)
    $upgrading = (Get-ShoutFileHash $context.Dll) -eq $script:PortablePreviousHash
    if ((Get-ShoutFileHash $context.Dll) -eq $script:PortableTargetHash -and (Test-Path -LiteralPath $context.State)) {
        [void](Read-PortableState $context)
        [void][Windows.Forms.MessageBox]::Show($script:Ui.alreadyInstalled,$script:Ui.title); return
    }
    if ([Windows.Forms.MessageBox]::Show($script:Ui.installPrompt,$script:Ui.title,'YesNo','Warning') -ne 'Yes') { return }
    Assert-ShoutStopped
    [void](Invoke-HotkeyBackend 'Install')
    # Re-enabling preserves its earlier library; explicitly apply the visible draft if different.
    $record = Read-PortableState $context
    if (-not $upgrading -and $record.installed_library_sha256 -ne $script:Document.Compiled.LibraryHash) { [void](Invoke-HotkeyBackend 'Apply') }
    $script:View.Summary.Text = $script:Ui.installed
    if ($upgrading) { $script:View.Summary.Text = $script:Ui.upgraded }
}
function Save-Draft {
    [void]$script:View.Grid.EndEdit(); Update-View
    $saved = Save-HotkeyDocument (Get-Draft) $script:SourcePath $script:Document.Hash -FormatVersion $script:BinaryVersion
    $script:Document = [pscustomobject]@{ Hash = $saved.Hash; Compiled = $saved.Compiled }
    Set-Draft $saved.Compiled.Scheme
}
function Capture-Binding {
    if (-not $script:View.Grid.CurrentRow) { return }
    $dialog = New-Object Windows.Forms.Form; $dialog.Text = $script:Ui.captureTitle
    $dialog.Size = New-Object Drawing.Size(620, 170); $dialog.StartPosition = 'CenterParent'; $dialog.KeyPreview = $true
    $hint = New-Object Windows.Forms.Label; $hint.Text = $script:Ui.captureHint; $hint.Dock = 'Fill'; $hint.Padding = New-Object Windows.Forms.Padding(12)
    $dialog.Controls.Add($hint); $dialog.Tag = @{ Tilde = $false; Binding = $null }
    $dialog.Add_KeyDown({ param($sender, $e)
        $e.SuppressKeyPress = $true
        if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $sender.DialogResult = 'Cancel'; return }
        if ([int]$e.KeyCode -eq 0xC0) { $sender.Tag.Tilde = $true; return }
        if ([int]$e.KeyCode -in @(0x10,0x11,0x12,0x5B,0x5C)) { return }
        $parts = @(); if ($e.Control) { $parts += 'Ctrl' }; if ($e.Alt) { $parts += 'Alt' }; if ($e.Shift) { $parts += 'Shift' }; if ($sender.Tag.Tilde) { $parts += '~' }
        $primary = $e.KeyCode.ToString().ToUpperInvariant()
        if ($primary -match '^D[0-9]$') { $primary = $primary.Substring(1) }
        if ($primary -eq 'PRIOR') { $primary = 'PAGEUP' }; if ($primary -eq 'NEXT') { $primary = 'PAGEDOWN' }
        try {
            $binding = Get-HotkeyBinding (($parts + @($primary)) -join '+')
            $sender.Tag.Binding = $binding.Label; $sender.DialogResult = 'OK'
        } catch { $sender.Controls[0].Text = $_.Exception.Message }
    })
    $dialog.Add_KeyUp({ param($sender, $e) if ([int]$e.KeyCode -eq 0xC0) { $sender.Tag.Tilde = $false } })
    try { if ($dialog.ShowDialog($script:View.Form) -eq 'OK') { $script:View.Grid.CurrentRow.Cells['binding'].Value = $dialog.Tag.Binding; Update-View } }
    finally { $dialog.Dispose() }
}
$grid.Add_CellEndEdit({ Update-View }); $titleBox.Add_TextChanged({ Update-View })
foreach ($button in $buttons.Values) { $button.Add_Click({ param($sender, $eventArgs)
    try {
        [void]$script:View.Grid.EndEdit(); Update-View
        switch ($sender.Tag) {
            'add' { Add-Message }
            'remove' {
                if ($script:View.Grid.Rows.Count -gt 1 -and $script:View.Grid.CurrentRow -and
                    [Windows.Forms.MessageBox]::Show($script:Ui.removePrompt, $script:Ui.title, 'YesNo', 'Question') -eq 'Yes') {
                    $script:View.Grid.Rows.RemoveAt($script:View.Grid.CurrentRow.Index); Update-View
                }
            }
            'capture' { Capture-Binding }
            'reload' { if (Confirm-Discard) { $script:Document = Read-HotkeyDocument $script:SourcePath -FormatVersion $script:BinaryVersion; Set-Draft $script:Document.Compiled.Scheme } }
            'save' { Save-Draft; $script:View.Summary.Text = $script:Ui.saved }
            'apply' { Save-Draft; [void](Invoke-HotkeyBackend 'Apply'); $script:View.Summary.Text = $script:Ui.applied }
            'status' { [void][Windows.Forms.MessageBox]::Show((Invoke-HotkeyBackend 'Status'), $script:Ui.title) }
            'choose' { [void](Choose-WeGame) }
            'detect' { Set-SelectedWeGame (Resolve-PortableRoot '' (Get-PortableDataRoot)) }
            'import' { Import-Messages }
            'export' { Export-Messages }
            'install' { Install-FromEditor }
            'restore' {
                if ([Windows.Forms.MessageBox]::Show($script:Ui.restorePrompt,$script:Ui.title,'YesNo','Warning') -eq 'Yes') {
                    Assert-ShoutStopped; [void](Invoke-HotkeyBackend 'Restore'); $script:View.Summary.Text = $script:Ui.restored
                }
            }
            'help' { [void][Windows.Forms.MessageBox]::Show($script:Ui.standaloneHelp,$script:Ui.title) }
        }
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, $script:Ui.error, 'OK', 'Warning') }
}) }
$form.Add_FormClosing({ param($sender, $e) [void]$script:View.Grid.EndEdit(); Update-View; if (-not (Confirm-Discard)) { $e.Cancel = $true } })
Set-Draft $script:Document.Compiled.Scheme
if ($Standalone -and -not $SelfTest -and -not $script:SelectedWeGame) {
    try { Set-SelectedWeGame (Resolve-PortableRoot '' (Get-PortableDataRoot)) } catch { $script:View.WeGame.Text = $script:Ui.wegameNotSelected }
}
if ($SelfTest) {
    if ($NativeKeys) {
        if (-not $script:Valid -or $grid.Rows.Count -ne 20 -or $script:Dirty -or -not $grid.Columns['binding'].ReadOnly) { throw 'Native-key initial model invalid.' }
        foreach ($name in @('add','remove','capture')) { if ($buttons[$name].Enabled) { throw 'Native-key controls must be disabled.' } }
        $grid.Rows[0].Cells['message'].Value = 'x' * 51; Update-View
        if ($script:Valid -or ([string]$grid.Rows[0].Cells['message'].Value).Length -ne 51) { throw 'Native-key overflow guard failed.' }
        Set-Draft $script:Document.Compiled.Scheme
        $grid.Rows[0].Cells['binding'].Value = 'Ctrl+Alt+Q'; Update-View
        if ($script:Valid -or $buttons.apply.Enabled) { throw 'Native-key binding mismatch accepted.' }
        if ((Get-ShoutFileHash $script:SourcePath) -ne $script:Document.Hash) { throw 'Native-key test changed source.' }
        $script:Dirty = $false; $form.Dispose()
        Write-Host 'PASS: native-key GUI guards, fixed twenty rows, disabled rebinding/add/delete, nontruncating text limit; no live writes.'; exit 0
    }
    if ($PreviewPath) {
        $absolute = [IO.Path]::GetFullPath($PreviewPath)
        $buildPrefix = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'build')) + [IO.Path]::DirectorySeparatorChar
        if (-not $absolute.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $absolute)) { throw 'Preview must be a NEW generated file under build.' }
        # Render only our detached control tree; never show/capture a desktop.
        $layout.Parent = $null; $layout.Dock = 'None'; $layout.Size = $form.ClientSize
        $layout.Font = $form.Font; $layout.BackColor = $form.BackColor
        $layout.CreateControl(); $layout.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($layout.Width, $layout.Height)
        try { $layout.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height))); $bitmap.Save($absolute) }
        finally { $bitmap.Dispose(); $layout.Dock = 'Fill'; $form.Controls.Add($layout) }
    }
    $checks = 0
    $initialCount = $script:Document.Compiled.Scheme.count
    if (-not $script:Valid -or $grid.Rows.Count -ne $initialCount -or $script:Dirty) { throw 'Initial model invalid' }; $checks++
    Add-Message
    if (-not $script:Valid -or $grid.Rows.Count -ne ($initialCount + 1) -or -not $script:Dirty) { throw 'Add row failed' }; $checks++
    $grid.Rows[$initialCount].Cells['binding'].Value = $grid.Rows[0].Cells['binding'].Value; Update-View
    if ($script:Valid -or $buttons.save.Enabled -or $buttons.apply.Enabled) { throw 'Duplicate binding allowed' }; $checks++
    $grid.Rows.RemoveAt($initialCount); Update-View
    if (-not $script:Valid) { throw 'Delete row failed' }; $checks++
    $grid.Rows[0].Cells['message'].Value = 'x' * 51; Update-View
    if ($script:Valid -or ([string]$grid.Rows[0].Cells['message'].Value).Length -ne 51) { throw 'Overflow truncated/accepted' }; $checks++
    Set-Draft $script:Document.Compiled.Scheme
    $grid.Rows[0].Cells['binding'].Value = 'Shift+Ctrl+Q'; Update-View
    if (-not $script:Valid -or -not $script:Dirty) { throw 'Custom independent binding failed' }; $checks++
    $before = Get-ShoutFileHash $script:SourcePath
    if ($before -ne $script:Document.Hash) { throw 'SelfTest changed source' }; $checks++
    if ($Standalone) {
        if ($buttons.Count -ne 14 -or $layout.RowCount -ne 10 -or -not $wegameBox.ReadOnly) { throw 'Standalone toolbar/layout failed' }; $checks++
        foreach ($name in @('choose','detect','install','restore','import','export','help')) {
            if ($buttons[$name].Text -ne $script:Ui.$name) { throw ('Missing translated standalone action: ' + $name) }; $checks++
        }
    }
    $script:Dirty = $false; $form.Dispose()
    Write-Host ('PASS: ' + $checks + ' GUI self-tests (no window shown, no source/live writes).'); exit 0
}
try { [void]$form.ShowDialog() } finally { $form.Dispose() }
