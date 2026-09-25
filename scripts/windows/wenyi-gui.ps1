#requires -Version 5.1
<#
.SYNOPSIS
  wenyi 翻译助手 —— translate-doc 的图形界面。

.DESCRIPTION
  界面只负责把选项拼成 translate-doc.cmd 的命令行，翻译逻辑一套都不重复：

    检查配置 = -DryRun（打印将要执行的命令与预计输出路径，不翻译、不改状态）
    开始翻译 = 在独立命令行窗口里执行（进度显示和以前一样，跑完窗口保留）
    仅导出   = -Assemble（从已有译文重新导出，不调用模型、不需要 API key）

  上次的选项会记在 wenyi-gui.settings.json，下次打开自动带出来。

.PARAMETER SelfTest
  只在控制台验证参数拼接逻辑，不弹出界面。
#>

[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# 目录规则见 wenyi-paths.ps1：脚本放在工作目录里或放在仓库里都能跑。
$HelperDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) {
  Split-Path -Parent $PSCommandPath
} else {
  (Get-Location).Path
}
. (Join-Path $HelperDir 'wenyi-paths.ps1')

$Layout = Resolve-WenyiLayout
if (-not $Layout) {
  [System.Windows.Forms.MessageBox]::Show(
    "找不到 wenyi 仓库（需要含 pyproject.toml 的目录）：$HelperDir", 'wenyi') | Out-Null
  exit 1
}

$ScriptDir = $Layout.ScriptDir
$WenyiDir = $Layout.RepoDir
$ProjectRoot = $Layout.WorkDir
$BridgeDir = $Layout.BridgeDir
$TranslatePs1 = Join-Path $ScriptDir 'translate-doc.ps1'
$CompatPy = Join-Path $ScriptDir 'epub-compat.py'
$SettingsPath = Join-Path $ProjectRoot 'wenyi-gui.settings.json'
$DebugLogPath = Join-Path $ProjectRoot 'artifact-debug.log'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$Languages = @('zh', 'zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru')
$Backends = @('babeldoc', 'mineru')
$Formats = @('auto', 'epub', 'pdf', 'txt', 'html', 'markdown', 'docx')
# 公式处理方式（兼容 EPUB 用）：界面显示中文，传给 translate-doc 的是右边的值。
$FormulaModes = [ordered]@{ '混合' = 'hybrid'; '纯文本' = 'text'; '全部图片' = 'image' }

function Get-FormulaModeLabel([string]$Value) {
  foreach ($label in $FormulaModes.Keys) {
    if ($FormulaModes[$label] -eq $Value) { return $label }
  }
  return '混合'
}

function Quote([string]$Value) {
  # 参数传给 cmd/PowerShell 时统一加双引号，避免路径带空格时被拆开。
  $escaped = $Value -replace '"', '\"'
  return '"' + $escaped + '"'
}

function New-TranslateTokens {
  param(
    [string]$Document,
    [string]$Target = 'zh',
    [string]$Backend = 'babeldoc',
    [string]$Format = 'auto',
    [string]$StateDir = 'state',
    [string]$Out,
    [switch]$Reset,
    [switch]$RestartBridge,
    [switch]$SkipReview,
    [switch]$CompatEpub,
    [string]$FormulaMode = 'hybrid',
    [switch]$Assemble,
    [switch]$DryRun
  )

  $tokens = @($Document)
  if ($Target) { $tokens += @('-Target', $Target) }
  if ($Backend) { $tokens += @('-PdfBackend', $Backend) }
  if ($StateDir) { $tokens += @('-StateDir', $StateDir) }
  if ($Format -and $Format -ne 'auto') { $tokens += @('-Format', $Format) }
  if ($Out) { $tokens += @('-Out', $Out) }
  if ($Assemble) { $tokens += '-Assemble' }
  if ($SkipReview) { $tokens += '-SkipReview' }
  if ($CompatEpub) {
    $tokens += '-CompatEpub'
    if ($FormulaMode) { $tokens += @('-FormulaMode', $FormulaMode) }
  }
  if ($Reset) { $tokens += '-Reset' }
  if ($RestartBridge) { $tokens += '-RestartBridge' }
  if ($DryRun) { $tokens += '-DryRun' }
  return $tokens
}

function Format-Tokens([string[]]$Tokens) {
  $shown = foreach ($token in $Tokens) {
    if ($token -like '-*') { $token } else { Quote $token }
  }
  return ($shown -join ' ')
}

function New-TranslateCommandLine {
  param(
    [string]$Document,
    [string]$Target = 'zh',
    [string]$Backend = 'babeldoc',
    [string]$Format = 'auto',
    [string]$StateDir = 'state',
    [string]$Out,
    [switch]$Reset,
    [switch]$RestartBridge,
    [switch]$SkipReview,
    [switch]$CompatEpub,
    [string]$FormulaMode = 'hybrid',
    [switch]$Assemble,
    [switch]$DryRun
  )
  $tokens = New-TranslateTokens -Document $Document -Target $Target -Backend $Backend `
    -Format $Format -StateDir $StateDir -Out $Out -Reset:$Reset -RestartBridge:$RestartBridge `
    -SkipReview:$SkipReview -CompatEpub:$CompatEpub -FormulaMode $FormulaMode `
    -Assemble:$Assemble -DryRun:$DryRun
  return (Format-Tokens $tokens)
}

if ($SelfTest) {
  $samples = @(
    @{ doc = 'D:\a b\book.epub'; target = 'zh'; backend = 'babeldoc'; format = 'auto'; state = 'state' },
    @{ doc = 'D:\a b\paper.pdf'; target = 'zh-Hant'; backend = 'mineru'; format = 'pdf'; state = 'state-mineru' },
    @{ doc = 'D:\a b\paper.pdf'; target = 'zh'; backend = 'babeldoc'; format = 'auto'; state = 'state' }
  )
  foreach ($sample in $samples) {
    $line = New-TranslateCommandLine -Document $sample.doc -Target $sample.target -Backend $sample.backend `
      -Format $sample.format -StateDir $sample.state
    Write-Output ("translate-doc.cmd " + $line)
  }
  $withFlags = New-TranslateCommandLine -Document 'D:\a b\paper.pdf' -Backend 'mineru' -StateDir 'state-mineru' `
    -SkipReview -RestartBridge -DryRun
  Write-Output ("translate-doc.cmd " + $withFlags)
  $withCompat = New-TranslateCommandLine -Document 'D:\a b\paper.pdf' -Backend 'mineru' -StateDir 'state-mineru' `
    -CompatEpub -FormulaMode 'text'
  Write-Output ("translate-doc.cmd " + $withCompat)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Test-Path -LiteralPath $TranslatePs1)) {
  [System.Windows.Forms.MessageBox]::Show("找不到 translate-doc.ps1：$TranslatePs1", 'wenyi') | Out-Null
  exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'wenyi 翻译助手'
$form.ClientSize = New-Object System.Drawing.Size(690, 620)
$form.MinimumSize = New-Object System.Drawing.Size(706, 659)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

function Add-Label([string]$Text, [int]$X, [int]$Y, [int]$Width = 80) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, 22)
  $label.TextAlign = 'MiddleLeft'
  $form.Controls.Add($label)
  return $label
}

$docLabel = Add-Label '文档' 12 14 60
$docBox = New-Object System.Windows.Forms.TextBox
$docBox.Location = New-Object System.Drawing.Point(78, 12)
$docBox.Size = New-Object System.Drawing.Size(440, 25)
$form.Controls.Add($docBox)

$browseBtn = New-Object System.Windows.Forms.Button
$browseBtn.Text = '浏览…'
$browseBtn.Location = New-Object System.Drawing.Point(526, 11)
$browseBtn.Size = New-Object System.Drawing.Size(150, 27)
$form.Controls.Add($browseBtn)

$langLabel = Add-Label '目标语言' 12 48 70
$langBox = New-Object System.Windows.Forms.ComboBox
$langBox.DropDownStyle = 'DropDownList'
$langBox.Location = New-Object System.Drawing.Point(88, 46)
$langBox.Size = New-Object System.Drawing.Size(110, 25)
$langBox.Items.AddRange($Languages)
$langBox.SelectedItem = 'zh'
$form.Controls.Add($langBox)

$backendLabel = Add-Label 'PDF 后端' 212 48 70
$backendBox = New-Object System.Windows.Forms.ComboBox
$backendBox.DropDownStyle = 'DropDownList'
$backendBox.Location = New-Object System.Drawing.Point(288, 46)
$backendBox.Size = New-Object System.Drawing.Size(120, 25)
$backendBox.Items.AddRange($Backends)
$backendBox.SelectedItem = 'babeldoc'
$form.Controls.Add($backendBox)

$formatLabel = Add-Label '导出格式' 420 48 70
$formatBox = New-Object System.Windows.Forms.ComboBox
$formatBox.DropDownStyle = 'DropDownList'
$formatBox.Location = New-Object System.Drawing.Point(496, 46)
$formatBox.Size = New-Object System.Drawing.Size(180, 25)
$formatBox.Items.AddRange($Formats)
$formatBox.SelectedItem = 'auto'
$form.Controls.Add($formatBox)

$stateLabel = Add-Label '状态目录' 12 82 70
$stateBox = New-Object System.Windows.Forms.TextBox
$stateBox.Location = New-Object System.Drawing.Point(88, 80)
$stateBox.Size = New-Object System.Drawing.Size(200, 25)
$stateBox.Text = 'state'
$form.Controls.Add($stateBox)

$resetCheck = New-Object System.Windows.Forms.CheckBox
$resetCheck.Text = '先清空运行状态'
$resetCheck.Location = New-Object System.Drawing.Point(298, 80)
$resetCheck.Size = New-Object System.Drawing.Size(150, 25)
$form.Controls.Add($resetCheck)

$skipReviewCheck = New-Object System.Windows.Forms.CheckBox
$skipReviewCheck.Text = '跳过审校（更快）'
$skipReviewCheck.Location = New-Object System.Drawing.Point(455, 80)
$skipReviewCheck.Size = New-Object System.Drawing.Size(180, 25)
$form.Controls.Add($skipReviewCheck)

$restartCheck = New-Object System.Windows.Forms.CheckBox
$restartCheck.Text = '重启 BabelDOC 服务'
$restartCheck.Location = New-Object System.Drawing.Point(88, 106)
$restartCheck.Size = New-Object System.Drawing.Size(240, 25)
$form.Controls.Add($restartCheck)

$compatCheck = New-Object System.Windows.Forms.CheckBox
$compatCheck.Text = '兼容 EPUB（公式）'
$compatCheck.Location = New-Object System.Drawing.Point(340, 106)
$compatCheck.Size = New-Object System.Drawing.Size(186, 25)
# 默认打开：NeatReader 之类对 MathML 支持不佳的阅读器需要这一份兼容版。
$compatCheck.Checked = $true
$form.Controls.Add($compatCheck)

$formulaBox = New-Object System.Windows.Forms.ComboBox
$formulaBox.DropDownStyle = 'DropDownList'
$formulaBox.Location = New-Object System.Drawing.Point(530, 106)
$formulaBox.Size = New-Object System.Drawing.Size(148, 25)
$formulaBox.Items.AddRange(@($FormulaModes.Keys))
$formulaBox.SelectedItem = '混合'
$form.Controls.Add($formulaBox)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($compatCheck, "额外生成一份 <文件名>-compat.epub：`n公式按下面选的方式处理，NeatReader 这类阅读器才能正常显示。")
$toolTip.SetToolTip($formulaBox, "混合：简单公式转 Unicode 文本，分式/矩阵用 MiKTeX 渲染成图片（推荐）`n纯文本：公式全部转文本，不需要 MiKTeX`n全部图片：公式全部渲染成图片，最接近原版式")

$outLabel = Add-Label '输出路径' 12 136 70
$outBox = New-Object System.Windows.Forms.TextBox
$outBox.Location = New-Object System.Drawing.Point(88, 134)
$outBox.Size = New-Object System.Drawing.Size(430, 25)
$form.Controls.Add($outBox)

$outBrowseBtn = New-Object System.Windows.Forms.Button
$outBrowseBtn.Text = '另存为…'
$outBrowseBtn.Location = New-Object System.Drawing.Point(526, 133)
$outBrowseBtn.Size = New-Object System.Drawing.Size(150, 27)
$form.Controls.Add($outBrowseBtn)

$checkBtn = New-Object System.Windows.Forms.Button
$checkBtn.Text = '检查配置 / 预览命令'
$checkBtn.Location = New-Object System.Drawing.Point(12, 170)
$checkBtn.Size = New-Object System.Drawing.Size(180, 34)
$form.Controls.Add($checkBtn)

$runBtn = New-Object System.Windows.Forms.Button
$runBtn.Text = '开始翻译'
$runBtn.Location = New-Object System.Drawing.Point(202, 170)
$runBtn.Size = New-Object System.Drawing.Size(150, 34)
$runBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 244, 234)
$form.Controls.Add($runBtn)

$assembleBtn = New-Object System.Windows.Forms.Button
$assembleBtn.Text = '仅导出（不翻译）'
$assembleBtn.Location = New-Object System.Drawing.Point(362, 170)
$assembleBtn.Size = New-Object System.Drawing.Size(150, 34)
$form.Controls.Add($assembleBtn)

$openOutBtn = New-Object System.Windows.Forms.Button
$openOutBtn.Text = '打开输出目录'
$openOutBtn.Location = New-Object System.Drawing.Point(522, 170)
$openOutBtn.Size = New-Object System.Drawing.Size(154, 34)
$form.Controls.Add($openOutBtn)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(12, 214)
$logBox.Size = New-Object System.Drawing.Size(664, 358)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.WordWrap = $false
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Anchor = 'Top,Left,Right,Bottom'
$logBox.Text = "选好选项后先点『检查配置 / 预览命令』，它会打印将要执行的命令和预计输出路径，不会真的翻译。`r`n确认无误再点『开始翻译』——`r`n翻译会在新开的命令行窗口里跑，进度和结果都在那个窗口里看，跑完窗口会保留。"
$form.Controls.Add($logBox)

$debugBtn = New-Object System.Windows.Forms.Button
$debugBtn.Text = '查看诊断日志'
$debugBtn.Location = New-Object System.Drawing.Point(12, 580)
$debugBtn.Size = New-Object System.Drawing.Size(130, 28)
$debugBtn.Anchor = 'Bottom,Left'
$form.Controls.Add($debugBtn)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = '提示：babeldoc 需要本地服务（界面可自动重启）；mineru 走云端，需要 MINERU_API_KEY。'
$hintLabel.Location = New-Object System.Drawing.Point(150, 584)
$hintLabel.Size = New-Object System.Drawing.Size(530, 22)
$hintLabel.ForeColor = [System.Drawing.Color]::DimGray
$hintLabel.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($hintLabel)

function Get-DocumentPath {
  $raw = $docBox.Text.Trim()
  if (-not $raw) { return $null }
  if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) { return $null }
  return (Resolve-Path -LiteralPath $raw).Path
}

function Write-Log([string]$Text) {
  $logBox.Text = $Text
  $logBox.SelectionStart = $logBox.Text.Length
  $logBox.ScrollToCaret()
  [System.Windows.Forms.Application]::DoEvents()
}

function Get-CompatPython {
  # 公式图片要 Pillow + PyMuPDF，封面要 Pillow：挑第一个都装了的解释器。
  foreach ($candidate in @(
      (Join-Path $BridgeDir '.venv\Scripts\python.exe'),
      (Join-Path $WenyiDir '.venv\Scripts\python.exe'))) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    & $candidate -c "import PIL, fitz" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $candidate }
  }
  return $null
}

function Get-FormulaRendererReport {
  if (-not (Test-Path -LiteralPath $CompatPy)) { return "epub-compat.py 不存在：$CompatPy" }
  $python = Get-CompatPython
  if (-not $python) { return '没找到同时装了 Pillow 和 PyMuPDF 的解释器（检查 venv），公式会退化成纯文本。' }
  try {
    return (& $python $CompatPy --check-renderer *>&1 | Out-String)
  } catch {
    return ("自检失败：" + $_.Exception.Message)
  }
}

function Save-Settings {
  $data = [ordered]@{
    document      = $docBox.Text
    target        = $langBox.Text
    backend       = $backendBox.Text
    format        = $formatBox.Text
    stateDir      = $stateBox.Text
    out           = $outBox.Text
    reset         = [bool]$resetCheck.Checked
    restartBridge = [bool]$restartCheck.Checked
    skipReview    = [bool]$skipReviewCheck.Checked
    compatEpub    = [bool]$compatCheck.Checked
    formulaMode   = $FormulaModes[$formulaBox.Text]
  }
  try {
    ($data | ConvertTo-Json) | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
  } catch {
    # 记住设置只是便利功能，失败不影响使用。
  }
}

function Restore-Settings {
  if (-not (Test-Path -LiteralPath $SettingsPath)) { return }
  try {
    $saved = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
  } catch {
    return
  }
  if ($saved.document) { $docBox.Text = $saved.document }
  if ($saved.target -and $Languages -contains $saved.target) { $langBox.SelectedItem = $saved.target }
  if ($saved.backend -and $Backends -contains $saved.backend) { $backendBox.SelectedItem = $saved.backend }
  if ($saved.format -and $Formats -contains $saved.format) { $formatBox.SelectedItem = $saved.format }
  if ($saved.stateDir) { $stateBox.Text = $saved.stateDir }
  if ($saved.out) { $outBox.Text = $saved.out }
  $resetCheck.Checked = [bool]$saved.reset
  $restartCheck.Checked = [bool]$saved.restartBridge
  $skipReviewCheck.Checked = [bool]$saved.skipReview
  # 这两个是后加的选项：老设置文件里没有它们时保留新默认值（兼容 EPUB 默认开）。
  if ($saved.PSObject.Properties.Name -contains 'compatEpub') {
    $compatCheck.Checked = [bool]$saved.compatEpub
  }
  if ($saved.formulaMode) { $formulaBox.SelectedItem = Get-FormulaModeLabel $saved.formulaMode }
}

$browseBtn.Add_Click({
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = '选择要翻译的文档'
  $dialog.Filter = '支持的文档|*.pdf;*.epub;*.md;*.markdown;*.htm;*.html|PDF|*.pdf|EPUB|*.epub|Markdown|*.md;*.markdown|HTML|*.htm;*.html|所有文件|*.*'
  if ($dialog.ShowDialog() -eq 'OK') {
    $docBox.Text = $dialog.FileName
    if ($backendBox.Text -eq 'babeldoc' -and $dialog.FileName -match '(?i)\.pdf$') {
      Write-Log "已选择 PDF：默认用 babeldoc（保留原版式）。想对比 MinerU，把『PDF 后端』改成 mineru。"
    }
  }
})

$outBrowseBtn.Add_Click({
  $dialog = New-Object System.Windows.Forms.SaveFileDialog
  $dialog.Title = '指定输出文件'
  $dialog.Filter = '所有文件|*.*'
  if ($dialog.ShowDialog() -eq 'OK') { $outBox.Text = $dialog.FileName }
})

$checkBtn.Add_Click({
  $document = Get-DocumentPath
  if (-not $document) {
    Write-Log '请先选择一个存在的文档。'
    return
  }
  $tokens = New-TranslateTokens -Document $document -Target $langBox.Text -Backend $backendBox.Text `
    -Format $formatBox.Text -StateDir $stateBox.Text -Out $outBox.Text `
    -Reset:$resetCheck.Checked -RestartBridge:$restartCheck.Checked `
    -SkipReview:$skipReviewCheck.Checked -CompatEpub:$compatCheck.Checked `
    -FormulaMode $FormulaModes[$formulaBox.Text] -DryRun
  $shown = Format-Tokens $tokens
  Write-Log ("> translate-doc.cmd $shown`r`n`r`n（正在做只读检查，不会翻译、不会改状态…）")
  $form.Cursor = 'WaitCursor'
  try {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $TranslatePs1) + $tokens
    $output = & $PowerShellExe @psArgs *>&1 | Out-String
    if ($compatCheck.Checked) {
      $output += "`r`n--- 公式渲染器自检（--check-renderer）---`r`n"
      $output += Get-FormulaRendererReport
    }
    Write-Log ("> translate-doc.cmd $shown`r`n`r`n" + $output)
  } catch {
    Write-Log ("检查失败：" + $_.Exception.Message)
  } finally {
    $form.Cursor = 'Default'
  }
})

function Start-TranslateRun([bool]$assemble) {
  $document = Get-DocumentPath
  if (-not $document) {
    Write-Log '请先选择一个存在的文档。'
    return
  }
  $tokens = New-TranslateTokens -Document $document -Target $langBox.Text -Backend $backendBox.Text `
    -Format $formatBox.Text -StateDir $stateBox.Text -Out $outBox.Text `
    -Reset:$resetCheck.Checked -RestartBridge:$restartCheck.Checked `
    -SkipReview:$skipReviewCheck.Checked -CompatEpub:$compatCheck.Checked `
    -FormulaMode $FormulaModes[$formulaBox.Text] -Assemble:$assemble
  Save-Settings
  $shown = Format-Tokens $tokens
  $what = if ($assemble) { '仅导出' } else { '翻译' }
  Write-Log ("已在新窗口启动（$what）：`r`n> translate-doc.cmd $shown`r`n`r`n进度、结果以及出错细节都在那个命令行窗口里；跑完窗口会保留。")
  # Start-Process 只是用空格把参数拼成命令行，不会自动加引号，所以带空格的
  # 文档路径必须自己引起来，否则会被拆成多个参数（例如 "Special Report.pdf"）。
  $quoted = $tokens | ForEach-Object { if ($_ -like '-*') { $_ } else { Quote $_ } }
  $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
    '-File', (Quote $TranslatePs1)) + $quoted
  Start-Process -FilePath $PowerShellExe -ArgumentList $psArgs -WorkingDirectory $ProjectRoot
}

function Test-Layout {
  $controls = @($form.Controls)
  $overlaps = @()
  for ($i = 0; $i -lt $controls.Count; $i++) {
    for ($j = $i + 1; $j -lt $controls.Count; $j++) {
      $a = $controls[$i]
      $b = $controls[$j]
      $rectA = New-Object System.Drawing.Rectangle($a.Location, $a.Size)
      $rectB = New-Object System.Drawing.Rectangle($b.Location, $b.Size)
      if ($rectA.IntersectsWith($rectB)) {
        $overlaps += ("{0} <-> {1}" -f $a.Text, $b.Text)
      }
    }
  }
  $offscreen = @($controls | Where-Object {
      $_.Right -gt $form.ClientSize.Width -or $_.Bottom -gt $form.ClientSize.Height
    } | ForEach-Object { $_.Text })
  return [pscustomobject]@{ Overlaps = $overlaps; Offscreen = $offscreen }
}

if ($SelfTest) {
  $report = Test-Layout
  if ($report.Overlaps.Count) {
    Write-Output ("LAYOUT OVERLAP: " + ($report.Overlaps -join '; '))
  } else {
    Write-Output 'layout ok: no overlapping controls'
  }
  if ($report.Offscreen.Count) {
    Write-Output ("LAYOUT OFFSCREEN: " + ($report.Offscreen -join '; '))
  } else {
    Write-Output 'layout ok: every control fits inside the window'
  }
  exit 0
}

$runBtn.Add_Click({ Start-TranslateRun -assemble $false })
$assembleBtn.Add_Click({ Start-TranslateRun -assemble $true })

$openOutBtn.Add_Click({
  $document = Get-DocumentPath
  if (-not $document) {
    Write-Log '请先选择一个存在的文档。'
    return
  }
  if ($outBox.Text.Trim()) {
    $target = Split-Path -Parent $outBox.Text.Trim()
  } else {
    $target = Join-Path (Split-Path -Parent $document) 'output'
  }
  if (Test-Path -LiteralPath $target) {
    Start-Process explorer.exe $target
  } else {
    Write-Log ("输出目录还不存在：" + $target + "`r`n（翻译跑完并导出后才会生成。）")
  }
})

$debugBtn.Add_Click({
  if (Test-Path -LiteralPath $DebugLogPath) {
    Start-Process notepad.exe $DebugLogPath
  } else {
    Write-Log ("还没有诊断日志（说明内部工件校验没有失败过）。`r`n失败时会写到：" + $DebugLogPath)
  }
})

Restore-Settings
[void]$form.ShowDialog()
