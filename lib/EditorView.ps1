function New-TwentyEditorView($Ui) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = $Ui.window
    $form.Size = New-Object Drawing.Size(1080, 840)
    $form.MinimumSize = New-Object Drawing.Size(940, 680)
    $form.StartPosition = 'CenterScreen'
    $form.AutoScaleMode = 'Dpi'
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
    $form.BackColor = [Drawing.Color]::FromArgb(247, 249, 252)
    $main = New-Object Windows.Forms.TableLayoutPanel
    $main.Dock = 'Fill'; $main.Padding = New-Object Windows.Forms.Padding(18)
    $main.ColumnCount = 1; $main.RowCount = 8
    foreach ($height in @(40, 30, 44)) { [void]$main.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
    [void]$main.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    foreach ($height in @(45, 34, 42, 48)) { [void]$main.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
    $form.Controls.Add($main)
    $heading = New-Object Windows.Forms.Label
    $heading.Text = $Ui.heading; $heading.Dock = 'Fill'
    $heading.Font = New-Object Drawing.Font('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
    $heading.ForeColor = [Drawing.Color]::FromArgb(27, 40, 59)
    $main.Controls.Add($heading, 0, 0)
    $subtitle = New-Object Windows.Forms.Label
    $subtitle.Text = $Ui.subtitle; $subtitle.Dock = 'Fill'
    $subtitle.ForeColor = [Drawing.Color]::FromArgb(91, 104, 124)
    $main.Controls.Add($subtitle, 0, 1)
    $settings = New-Object Windows.Forms.FlowLayoutPanel
    $settings.Dock = 'Fill'; $settings.WrapContents = $false
    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.Text = $Ui.titleLabel; $titleLabel.Width = 80; $titleLabel.Height = 30
    $titleLabel.TextAlign = 'MiddleLeft'
    $titleBox = New-Object Windows.Forms.TextBox
    $titleBox.Width = 380; $titleBox.MaxLength = 0
    $panelLabel = New-Object Windows.Forms.Label
    $panelLabel.Text = $Ui.panelLabel; $panelLabel.Width = 76; $panelLabel.Height = 30
    $panelLabel.TextAlign = 'MiddleRight'
    $panelBox = New-Object Windows.Forms.ComboBox
    $panelBox.Width = 175; $panelBox.DropDownStyle = 'DropDownList'
    [void]$panelBox.Items.Add($Ui.tilde); [void]$panelBox.Items.Add($Ui.ctrl)
    $panelBox.SelectedIndex = 0
    $settings.Controls.AddRange([Windows.Forms.Control[]]@($titleLabel, $titleBox, $panelLabel, $panelBox))
    $main.Controls.Add($settings, 0, 2)
    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $boxes = @(); $counts = @(); $keyLabels = @()
    $tooltip = New-Object Windows.Forms.ToolTip
    foreach ($bank in 0..1) {
        $page = New-Object Windows.Forms.TabPage
        if ($bank -eq 0) { $page.Text = $Ui.tabFirst } else { $page.Text = $Ui.tabSecond }
        $page.BackColor = [Drawing.Color]::White
        $scroll = New-Object Windows.Forms.Panel
        $scroll.Dock = 'Fill'; $scroll.AutoScroll = $true; $scroll.Padding = New-Object Windows.Forms.Padding(8)
        $table = New-Object Windows.Forms.TableLayoutPanel
        $table.Dock = 'Top'; $table.Height = 436; $table.ColumnCount = 4; $table.RowCount = 11
        [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 56)))
        [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 120)))
        [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
        [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 92)))
        [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 26)))
        foreach ($row in 1..10) { [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 41))) }
        $headers = @($Ui.columnNumber, $Ui.columnKey, $Ui.columnText, $Ui.columnCount)
        foreach ($column in 0..3) {
            $label = New-Object Windows.Forms.Label
            $label.Text = $headers[$column]; $label.Dock = 'Fill'
            $label.ForeColor = [Drawing.Color]::FromArgb(100, 112, 130)
            $table.Controls.Add($label, $column, 0)
        }
        foreach ($slot in 0..9) {
            $index = $bank * 10 + $slot
            $number = New-Object Windows.Forms.Label
            $number.Text = ('{0:D2}' -f ($index + 1)); $number.Dock = 'Fill'; $number.TextAlign = 'MiddleLeft'
            $keyLabel = New-Object Windows.Forms.Label
            $keyLabel.Dock = 'Fill'; $keyLabel.TextAlign = 'MiddleLeft'
            $box = New-Object Windows.Forms.TextBox
            $box.Dock = 'Fill'; $box.Margin = New-Object Windows.Forms.Padding(3, 7, 12, 3)
            $box.MaxLength = 0; $box.Tag = $index
            $count = New-Object Windows.Forms.Label
            $count.Dock = 'Fill'; $count.TextAlign = 'MiddleLeft'
            $tooltip.SetToolTip($count, $Ui.countTip)
            $table.Controls.Add($number, 0, $slot + 1)
            $table.Controls.Add($keyLabel, 1, $slot + 1)
            $table.Controls.Add($box, 2, $slot + 1)
            $table.Controls.Add($count, 3, $slot + 1)
            $boxes += $box; $counts += $count; $keyLabels += $keyLabel
        }
        $scroll.Controls.Add($table); $page.Controls.Add($scroll); [void]$tabs.TabPages.Add($page)
    }
    $main.Controls.Add($tabs, 0, 3)
    $tip = New-Object Windows.Forms.Label
    $tip.Text = $Ui.tip; $tip.Dock = 'Fill'; $tip.ForeColor = [Drawing.Color]::FromArgb(91, 104, 124)
    $main.Controls.Add($tip, 0, 4)
    $capacity = New-Object Windows.Forms.Label
    $capacity.Dock = 'Fill'; $capacity.TextAlign = 'MiddleLeft'
    $main.Controls.Add($capacity, 0, 5)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'; $buttons.WrapContents = $false
    $reload = New-Object Windows.Forms.Button; $reload.Text = $Ui.sourceReload
    $live = New-Object Windows.Forms.Button; $live.Text = $Ui.liveRead
    $check = New-Object Windows.Forms.Button; $check.Text = $Ui.check
    $save = New-Object Windows.Forms.Button; $save.Text = $Ui.save
    $apply = New-Object Windows.Forms.Button; $apply.Text = $Ui.saveApply
    foreach ($button in @($reload, $live, $check, $save, $apply)) {
        $button.Width = 155; $button.Height = 34
        $buttons.Controls.Add($button)
    }
    $apply.BackColor = [Drawing.Color]::FromArgb(35, 106, 227); $apply.ForeColor = [Drawing.Color]::White
    $apply.FlatStyle = 'Flat'; $apply.FlatAppearance.BorderSize = 0
    $main.Controls.Add($buttons, 0, 6)
    $status = New-Object Windows.Forms.Label
    $status.Dock = 'Fill'; $status.AutoEllipsis = $true
    $status.ForeColor = [Drawing.Color]::FromArgb(91, 104, 124)
    $main.Controls.Add($status, 0, 7)
    return [pscustomobject]@{
        Form = $form; TitleBox = $titleBox; PanelBox = $panelBox; Tabs = $tabs
        Boxes = $boxes; Counts = $counts; KeyLabels = $keyLabels; Tooltip = $tooltip
        Capacity = $capacity; Status = $status
        Reload = $reload; Live = $live; Check = $check; Save = $save; Apply = $apply
    }
}
