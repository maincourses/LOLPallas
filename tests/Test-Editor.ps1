# Own hidden form rendering and isolated generated-file tests only.
param([string]$PackageDirectory = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PackageDirectory 'lib\ShoutTools.ps1')
. (Join-Path $PackageDirectory 'lib\EditorTools.ps1')
. (Join-Path $PackageDirectory 'lib\EditorView.ps1')
$script:Passed = 0
function Assert-GuiTest([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('FAIL: ' + $Name) }
    $script:Passed++; Write-Output ('PASS: ' + $Name)
}
function Assert-GuiRejected([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-GuiTest $rejected $Name
}
$scratch = Join-Path $PackageDirectory ('build\test-work\editor-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$fixture = Join-Path $scratch 'scheme20.json'
Copy-Item -LiteralPath (Join-Path $PackageDirectory 'scheme20.example.json') -Destination $fixture
$before = Read-EditorDocument $fixture
$same = Save-EditorDocument $before.Compiled.Scheme $fixture $before.Hash
Assert-GuiTest (-not $same.Changed -and -not (Test-Path -LiteralPath (Join-Path $scratch 'backups'))) 'Unchanged save is a no-op'
$scheme = $before.Compiled.Scheme
$scheme.'0' = ([string][char]0x96C6) + ([string][char]0x5408) + ' "now" \\ path'
$saved = Save-EditorDocument $scheme $fixture $before.Hash
Assert-GuiTest ($saved.Changed -and (Test-Path -LiteralPath $saved.Backup)) 'Changed source saved with a new backup'
Assert-GuiTest ((Get-ShoutFileHash $saved.Backup) -eq $before.Hash) 'Source backup equals the prior file'
$loaded = Read-EditorDocument $fixture
Assert-GuiTest ($loaded.Compiled.Scheme.'0' -ceq $scheme.'0') 'Chinese, quotes and backslashes survive save/reload'
Assert-GuiRejected { Save-EditorDocument $scheme $fixture $before.Hash } 'Stale source hash rejected'
Assert-GuiTest ((Get-ShoutFileHash $fixture) -eq $saved.Hash) 'Concurrent-change protection preserves source'
$scheme.'0' = 'x' * 51
Assert-GuiRejected { Save-EditorDocument $scheme $fixture $saved.Hash } 'Overlength GUI save rejected'
Assert-GuiTest ((Get-ShoutFileHash $fixture) -eq $saved.Hash) 'Rejected save does not change source'
Assert-GuiTest (@(Get-ChildItem -LiteralPath $scratch -Filter '*.tmp').Count -eq 0) 'No leftover save stages'
$freshPath = Join-Path $scratch 'fresh-source.json'
Initialize-ShoutSource $freshPath (Join-Path $PackageDirectory 'scheme20.example.json')
Assert-GuiTest ((Get-ShoutFileHash $freshPath) -eq (Get-ShoutFileHash (Join-Path $PackageDirectory 'scheme20.example.json'))) 'Fresh checkout initializes source from template'
Initialize-ShoutSource $fixture (Join-Path $PackageDirectory 'scheme20.example.json')
Assert-GuiTest ((Get-ShoutFileHash $fixture) -eq $saved.Hash) 'Initialization never overwrites existing personal text'
Assert-GuiRejected { Initialize-ShoutSource $scratch (Join-Path $PackageDirectory 'scheme20.example.json') } 'Source path occupied by a directory is rejected'

$ui = Get-Content -LiteralPath (Join-Path $PackageDirectory 'lib\editor-ui.zh-CN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$view = New-TwentyEditorView $ui
$original = Read-EditorDocument (Join-Path $PackageDirectory 'scheme20.example.json')
try {
    $view.TitleBox.Text = $original.Compiled.Scheme.title
    foreach ($index in 0..19) {
        $view.Boxes[$index].Text = $original.Compiled.Scheme.($index.ToString())
        $view.Counts[$index].Text = $view.Boxes[$index].Text.Length.ToString() + ' / 50'
        if ($index -lt 10) { $key = ($index + 1).ToString(); if ($index -eq 9) { $key = '0' } }
        else { $key = 'F' + ($index - 9) }
        $view.KeyLabels[$index].Text = '~ + ' + $key
    }
    $view.Capacity.Text = $ui.capacity -f $original.Compiled.SchemeBytes.Length
    $view.Status.Text = $ui.loaded
    Assert-GuiTest ($view.Boxes.Count -eq 20 -and $view.Tabs.TabPages.Count -eq 2) 'Twenty native text boxes and two pages constructed'
    Assert-GuiTest (@($view.Boxes | Where-Object { $_.MaxLength -ne 0 }).Count -eq 0) 'Input does not silently truncate at fifty'
    # Render the editor's detached control tree, not the user's desktop. A
    # never-shown Form makes all children invisible to DrawToBitmap, so use
    # its standalone layout panel with no top-level window or Show() call.
    $root = $view.Form.Controls[0]
    $root.Parent = $null; $root.Dock = 'None'
    $root.Size = $view.Form.ClientSize; $root.Font = $view.Form.Font
    $root.BackColor = $view.Form.BackColor
    $root.CreateControl(); $root.PerformLayout()
    foreach ($bank in 0..1) {
        $view.Tabs.SelectedIndex = $bank
        $root.PerformLayout(); $view.Tabs.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($root.Width, $root.Height)
        try {
            $root.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            $preview = Join-Path $scratch ('editor-page-' + ($bank + 1) + '.png')
            $bitmap.Save($preview, [Drawing.Imaging.ImageFormat]::Png)
            Assert-GuiTest ((Get-Item -LiteralPath $preview).Length -gt 1000) ('Own hidden form render, page ' + ($bank + 1))
        } finally { $bitmap.Dispose() }
    }
} finally { if ($root) { $root.Dispose() }; $view.Tooltip.Dispose(); $view.Form.Dispose() }
$status = Invoke-EditorBackend $PackageDirectory 'Status'
Assert-GuiTest ($status.ExitCode -eq 0 -and $status.Output.Contains('Twenty-message DLL matching:')) 'Hidden child backend read-only status'
Assert-GuiTest ($status.Output.Contains($PackageDirectory)) 'Backend preserves the Unicode package path'
Write-Output ('TOTAL PASSED: ' + $script:Passed)
Write-Output ('Isolated generated test files and own-form previews: ' + $scratch)
