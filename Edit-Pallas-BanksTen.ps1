# Current eight-groups-of-ten JSON editor; never uses the modern hotkey format.
param([string]$WeGameRoot,[string]$SchemePath,[switch]$ValidateUI)
$ErrorActionPreference='Stop'
$editorOptions=@{Root=$WeGameRoot;Scheme=$SchemePath;ValidateUI=$ValidateUI}
. (Join-Path $PSScriptRoot 'lib\BanksTenTools.ps1')
$WeGameRoot=$editorOptions.Root; $SchemePath=$editorOptions.Scheme; $ValidateUI=$editorOptions.ValidateUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$utf8=New-Object Text.UTF8Encoding($false,$true)
$script:BankEditorDirty=$false; $script:BankEditorLoading=$false; $script:BankEditorIndex=-1
$script:BankEditorDraftHash=$null
try {
    if (-not $ValidateUI) {
        $data=Get-PortableDataRoot
        $context=New-PortableContext (Resolve-PortableRoot $WeGameRoot $data) $data
        $record=(Read-BanksTenRecord $context $script:Working8KProfile).Record
        if ($record.status -ne 'installed-awaiting-game-test') { throw '八组十条版尚未启用。请勿用本编辑器应用其他版本。' }
        Assert-ShoutHash $context.Dll $script:BanksTenHash
        $draft=Assert-PortablePath (Join-Path $data 'Editor\banks10-messages.json')
        $applied=Join-Path $script:Working8KProfile 'library20-v1.json'
        if (-not $SchemePath) {
            $SchemePath=$applied
            if (Test-Path -LiteralPath $draft -PathType Leaf) { $SchemePath=$draft }
        }
        $script:BankEditorDraftHash=Get-ShoutFileHash $draft
    } elseif (-not $SchemePath) { throw 'ValidateUI requires an own generated JSON fixture.' }
    $script:BankEditorScheme=Get-Content -LiteralPath $SchemePath -Raw -Encoding UTF8 | ConvertFrom-Json
    [void](ConvertTo-BanksTenArtifacts $script:BankEditorScheme)
    $form=New-Object Windows.Forms.Form
    $form.Text='LoL 本地快捷喊话 · 八组十条 · 无单条字数上限'
    $form.ClientSize=New-Object Drawing.Size(1100,740)
    $form.MinimumSize=New-Object Drawing.Size(920,660)
    $form.StartPosition='CenterScreen'
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(12)
    $layout.ColumnCount=1; $layout.RowCount=6
    foreach ($height in @(55,38,0,30,135,80)) {
        if ($height) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) }
        else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) }
    }
    $form.Controls.Add($layout)
    $help=New-Object Windows.Forms.Label
    $help.Dock='Fill'
    $help.Text="每组 1～9、0 选择十条；按住原面板键（~ 或 Ctrl）＋PageUp/PageDown 切组。F 键不发送。`r`n不设单条字数上限；整套 UTF-8 JSON 最多 65536 字节。长消息仍可能被游戏拒绝或引发异常。"
    $help.ForeColor=[Drawing.Color]::DarkGoldenrod
    $layout.Controls.Add($help,0,0)
    $titlePanel=New-Object Windows.Forms.FlowLayoutPanel
    $titlePanel.Dock='Fill'
    $titleLabel=New-Object Windows.Forms.Label
    $titleLabel.Text='方案名称'; $titleLabel.AutoSize=$true; $titleLabel.Margin=New-Object Windows.Forms.Padding(0,7,8,0)
    $title=New-Object Windows.Forms.TextBox
    $title.Width=420; $title.MaxLength=[int]::MaxValue; $title.Text=$script:BankEditorScheme.title
    $titlePanel.Controls.AddRange(@($titleLabel,$title)); $layout.Controls.Add($titlePanel,0,1)
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
    $grid.RowHeadersVisible=$false; $grid.MultiSelect=$false; $grid.SelectionMode='FullRowSelect'
    $grid.AutoSizeColumnsMode='Fill'; $grid.BackgroundColor=[Drawing.Color]::White
    foreach ($item in @(@('序号',60),@('分组',60),@('按键',85),@('消息预览',680),@('UTF-16单位',95))) {
        $column=New-Object Windows.Forms.DataGridViewTextBoxColumn
        $column.HeaderText=$item[0]; $column.FillWeight=$item[1]; $column.SortMode='NotSortable'; $column.MaxInputLength=[int]::MaxValue
        [void]$grid.Columns.Add($column)
    }
    foreach ($i in 0..79) {
        $key=($i%10+1).ToString(); if ($i%10 -eq 9) { $key='0' }
        $text=$script:BankEditorScheme.($i.ToString())
        [void]$grid.Rows.Add(@(($i+1).ToString(),([int][Math]::Floor($i/10)+1).ToString(),$key,(Get-BanksTenPreview $text),$text.Length.ToString()))
    }
    $layout.Controls.Add($grid,0,2)
    $selected=New-Object Windows.Forms.Label
    $selected.Dock='Fill'; $selected.Text='选中一条，在下方编辑完整文案；自动换行不影响文本，文案不能含回车或其他控制字符。'
    $layout.Controls.Add($selected,0,3)
    $body=New-Object Windows.Forms.TextBox
    $body.Dock='Fill'; $body.Multiline=$true; $body.WordWrap=$true; $body.ScrollBars='Vertical'
    $body.MaxLength=[int]::MaxValue; $body.AcceptsReturn=$false
    $layout.Controls.Add($body,0,4)
    $bottom=New-Object Windows.Forms.TableLayoutPanel
    $bottom.Dock='Fill'; $bottom.RowCount=2; $bottom.ColumnCount=1
    [void]$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40)))
    [void]$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    $buttons=New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock='Fill'
    $save=New-Object Windows.Forms.Button
    $save.Text='保存文案'; $save.AutoSize=$true
    $apply=New-Object Windows.Forms.Button
    $apply.Text='保存并应用'; $apply.AutoSize=$true
    $reload=New-Object Windows.Forms.Button
    $reload.Text='读取已应用文案'; $reload.AutoSize=$true
    $buttons.Controls.AddRange(@($save,$apply,$reload)); $bottom.Controls.Add($buttons,0,0)
    $status=New-Object Windows.Forms.Label
    $status.Dock='Fill'; $status.AutoEllipsis=$true
    $bottom.Controls.Add($status,0,1); $layout.Controls.Add($bottom,0,5)
    function Update-BankEditorStatus {
        try {
            $compiled=ConvertTo-BanksTenArtifacts $script:BankEditorScheme
            $status.ForeColor=[Drawing.Color]::DarkGreen
            $status.Text='80 条 · 8 组 × 10 条 · '+$compiled.Library.Length+' / 65536 字节 · 单条不按字数限制'+$(if($script:BankEditorDirty){' · 有未保存修改'}else{''})
        } catch { $status.ForeColor=[Drawing.Color]::Firebrick; $status.Text='无法保存：'+$_.Exception.Message }
    }
    function Show-BankEditorSelection {
        if (-not $grid.SelectedRows.Count) { return }
        $script:BankEditorLoading=$true
        try {
            $script:BankEditorIndex=$grid.SelectedRows[0].Index
            $body.Text=$script:BankEditorScheme.($script:BankEditorIndex.ToString())
        } finally { $script:BankEditorLoading=$false }
    }
    function Save-BankEditorDraft {
        if ($ValidateUI) { throw 'ValidateUI never writes.' }
        [void](ConvertTo-BanksTenArtifacts $script:BankEditorScheme)
        [void](Assert-PortablePath $draft)
        if ((Get-ShoutFileHash $draft) -ne $script:BankEditorDraftHash) { throw '草稿已被另一窗口修改，拒绝覆盖。请关闭并重新打开编辑器。' }
        $bytes=$utf8.GetBytes(($script:BankEditorScheme | ConvertTo-Json -Depth 4))
        $stage=Join-Path (Split-Path -Parent $draft) ('banks10-draft-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try {
            $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            if ((Get-ShoutFileHash $draft) -ne $script:BankEditorDraftHash) { throw '草稿发生并发修改，拒绝覆盖。' }
            if ($script:BankEditorDraftHash) { [IO.File]::Replace($stage,$draft,[NullString]::Value) }
            elseif (Test-Path -LiteralPath $draft) { throw '草稿位置存在非文件对象，拒绝覆盖。' }
            else { [IO.File]::Move($stage,$draft) }
            $script:BankEditorDraftHash=Get-ShoutByteHash $bytes; Assert-ShoutHash $draft $script:BankEditorDraftHash
            $script:BankEditorDirty=$false; Update-BankEditorStatus
        } finally { if(Test-Path -LiteralPath $stage -PathType Leaf){ Remove-Item -LiteralPath $stage } }
    }
    $grid.add_SelectionChanged({ Show-BankEditorSelection })
    $body.add_TextChanged({
        if ($script:BankEditorLoading -or $script:BankEditorIndex -lt 0) { return }
        $i=$script:BankEditorIndex
        $script:BankEditorScheme.($i.ToString())=$body.Text
        $grid.Rows[$i].Cells[3].Value=Get-BanksTenPreview $body.Text
        $grid.Rows[$i].Cells[4].Value=$body.Text.Length.ToString()
        $script:BankEditorDirty=$true; Update-BankEditorStatus
    })
    $title.add_TextChanged({ $script:BankEditorScheme.title=$title.Text; $script:BankEditorDirty=$true; Update-BankEditorStatus })
    $save.add_Click({
        try { Save-BankEditorDraft; [void][Windows.Forms.MessageBox]::Show('文案已保存。运行中的游戏不会自动更新；应用前请退出游戏和 WeGame。','已保存') }
        catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'保存未完成') }
    })
    $apply.add_Click({
        try {
            Save-BankEditorDraft
            $output=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Manage-Pallas-BanksTen.ps1') -Mode Apply -WeGameRoot $context.Root -SchemePath $draft 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('草稿已保存，但未应用。请退出游戏和托盘 WeGame。'+[Environment]::NewLine+($output -join [Environment]::NewLine)) }
            [void][Windows.Forms.MessageBox]::Show('已应用并备份旧文案。请重新启动 WeGame，进入新训练局测试。长消息仍可能被游戏拒绝。','应用完成')
        } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'应用未完成') }
    })
    $reload.add_Click({
        if ($ValidateUI) { return }
        if ($script:BankEditorDirty -and [Windows.Forms.MessageBox]::Show('丢弃当前未保存修改，重新读取已应用文案？','确认','YesNo') -ne 'Yes') { return }
        try {
            $new=Get-Content -LiteralPath $applied -Raw -Encoding UTF8 | ConvertFrom-Json
            [void](ConvertTo-BanksTenArtifacts $new); $script:BankEditorScheme=$new
            foreach($i in 0..79){ $text=$new.($i.ToString()); $grid.Rows[$i].Cells[3].Value=Get-BanksTenPreview $text; $grid.Rows[$i].Cells[4].Value=$text.Length.ToString() }
            $title.Text=$new.title; Show-BankEditorSelection
            $script:BankEditorDirty=$false; Update-BankEditorStatus
        } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'读取未完成') }
    })
    $form.add_FormClosing({
        if ($script:BankEditorDirty -and [Windows.Forms.MessageBox]::Show('存在未保存修改，确定关闭并放弃？','确认','YesNo') -ne 'Yes') { $_.Cancel=$true }
    })
    $grid.Rows[0].Selected=$true; Show-BankEditorSelection; Update-BankEditorStatus
    if ($ValidateUI) {
        if ($grid.Rows.Count -ne 80 -or $body.MaxLength -lt 65536 -or $title.MaxLength -lt 65536) { throw 'Own editor UI contract failed.' }
        $body.Text=([char]0x4E2D).ToString()*500
        if ($script:BankEditorScheme.'0'.Length -ne 500 -or $status.ForeColor -ne [Drawing.Color]::DarkGreen) { throw 'Long-message editor validation failed.' }
        Write-Output 'PASS: own editor 80 rows / eight groups / digits only / 500-unit edit accepted / no writes or displayed window.'
    } else { [void]$form.ShowDialog() }
    $form.Dispose()
} catch {
    if ($ValidateUI) { throw }
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'编辑器未能打开')
    exit 1
}
