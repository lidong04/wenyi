#requires -Version 5.1
<#
.SYNOPSIS
  Translate a document into Chinese (default) with wenyi, in one command.

.DESCRIPTION
  One command does everything - after a reboot there is nothing to start by hand:

    1. Validates the input document and the API key.
    2. Writes a runtime config with the requested target language.
    3. For PDF input only, makes sure the local BabelDOC bridge listens on
       127.0.0.1:8765, starting it hidden in the background when needed.
    4. Runs `wenyi translate` (or `wenyi assemble`) and reports the output file.

  Accepted input formats: .pdf .md .markdown .htm .html .epub
  Default target language: zh (Chinese).

.PARAMETER Document
  Source document to translate. First positional argument.

.PARAMETER Target
  Target language code, default zh. Also: zh-Hant en ja ko fr de es it pt ru.

.PARAMETER PdfBackend
  PDF parser/output backend: babeldoc (default, layout-preserving; needs the local
  bridge) or mineru (cloud conversion via MINERU_API_KEY; exports EPUB by default).
  Ignored for non-PDF input.

.PARAMETER StateDir
  Run-state root, relative to the wenyi project (default: state). Give each
  comparison its own value so the two backends never reuse one another's state.

.PARAMETER Format
  Export format override: epub / pdf / txt / html / markdown / docx. Left unset,
  wenyi decides: babeldoc PDF state exports PDF, MinerU state exports EPUB.

.PARAMETER Out
  Explicit output path for the exported book.

.PARAMETER Assemble
  Skip translation and export from existing state (`wenyi assemble`): no model
  calls and no API key required.

.PARAMETER SkipReview
  Translate and export, then stop: skip the separate quality-review stage.

.PARAMETER CompatEpub
  After exporting an EPUB, also write a MathML-flattened copy next to it
  (<name>-compat.epub) for readers that cannot handle MathML, such as NeatReader.
  Formulas become Unicode text, and 2D structures (fractions, matrices) are
  rendered to PNG images with MiKTeX when it is available.

.PARAMETER FormulaMode
  How the CompatEpub copy handles formulas: hybrid (default), text or image.

.PARAMETER Reset
  Delete this book's existing run state before starting.

.PARAMETER RestartBridge
  Stop whatever currently listens on the bridge port and start a fresh bridge in
  this window before translating. Use it when a run failed with a bridge error
  (for example `extract failed with HTTP 502`) or when the bridge looks wedged.

.PARAMETER DryRun
  Run every check, make sure the bridge is up, print the command, then stop
  without translating and without deleting state.

.EXAMPLE
  .\translate-doc.cmd "D:\books\some book.epub"
.EXAMPLE
  .\translate-doc.cmd "D:\books\paper.pdf" -Target zh-Hant
.EXAMPLE
  .\translate-doc.cmd "D:\books\paper.pdf" -Assemble
.EXAMPLE
  .\translate-doc.cmd "D:\books\paper.pdf" -PdfBackend mineru -StateDir state-mineru
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [Alias('Input', 'Path', 'File')]
  [string]$Document,

  [string]$Target = 'zh',
  [ValidateSet('babeldoc', 'mineru')]
  [string]$PdfBackend = 'babeldoc',
  [string]$StateDir = 'state',
  [string]$Format,
  [string]$Out,
  [switch]$Assemble,
  [switch]$SkipReview,
  [switch]$CompatEpub,
  [string]$FormulaMode = 'hybrid',
  [switch]$Reset,
  [switch]$RestartBridge,
  [switch]$DryRun,
  [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'

$AllowedExtensions = @('.pdf', '.md', '.markdown', '.htm', '.html', '.epub')
$AllowedFormats = @('epub', 'pdf', 'txt', 'html', 'markdown', 'docx')
$TargetCodes = @('zh', 'zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru')

function Fail([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

function Get-Slug([string]$Name) {
  $slug = [regex]::Replace($Name, '[^\w\u4e00-\u9fff\u3040-\u30ff-]+', '_').Trim('_')
  if (-not $slug) { $slug = 'book' }
  return $slug
}

# --- 1. Locate the repository and the working directory ---------------------
# 目录规则见 wenyi-paths.ps1：脚本可以放在工作目录里，也可以放在仓库里。
$HelperDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) {
  Split-Path -Parent $PSCommandPath
} else {
  (Get-Location).Path
}
. (Join-Path $HelperDir 'wenyi-paths.ps1')

$Layout = Resolve-WenyiLayout
if (-not $Layout) {
  Fail "找不到 wenyi 仓库（需要含 pyproject.toml 的目录）：$HelperDir"
}

$ScriptDir   = $Layout.ScriptDir
$WenyiDir    = $Layout.RepoDir
$ProjectRoot = $Layout.WorkDir
$BridgeDir   = $Layout.BridgeDir
$BridgeExe  = Join-Path $BridgeDir '.venv\Scripts\wenyi-babeldoc-bridge.exe'
$SessionDir = Join-Path $ProjectRoot 'babeldoc-sessions'
$ConfigSrc  = Join-Path $WenyiDir 'config.yaml'
$WenyiPy    = Join-Path $WenyiDir '.venv\Scripts\python.exe'
$WenyiExe   = Join-Path $WenyiDir '.venv\Scripts\wenyi.exe'
$BridgePy   = Join-Path $BridgeDir '.venv\Scripts\python.exe'
$BridgeUrl  = "http://127.0.0.1:$Port"

$Usage = @"
Usage: translate-doc.cmd <document> [-Target zh] [-PdfBackend babeldoc|mineru]
                          [-StateDir state] [-Format epub|pdf|...] [-Out path]
                          [-Assemble] [-SkipReview] [-CompatEpub] [-Reset] [-RestartBridge] [-DryRun]
                          [-FormulaMode hybrid|text|image]
  Accepted input formats: $($AllowedExtensions -join ' ')
"@

# --- 2. Validate the request ------------------------------------------------
if (-not $Document) { Fail "No input document given.`n$Usage" }
if (-not (Test-Path -LiteralPath $Document -PathType Leaf)) {
  Fail "Input file not found: $Document"
}
if (-not (Test-Path -LiteralPath $WenyiDir)) { Fail "wenyi directory not found: $WenyiDir" }
if (-not (Test-Path -LiteralPath $ConfigSrc)) { Fail "config.yaml not found: $ConfigSrc" }
if (-not (Test-Path -LiteralPath $WenyiPy)) { Fail "wenyi virtualenv missing: $WenyiPy" }
if (-not (Test-Path -LiteralPath $WenyiExe)) { Fail "wenyi entry point missing: $WenyiExe" }

$TargetMatch = $TargetCodes | Where-Object { $_ -ieq $Target } | Select-Object -First 1
if (-not $TargetMatch) {
  Fail "Unsupported target language '$Target'. Accepted: $($TargetCodes -join ' ')"
}
$Target = $TargetMatch

$DocumentPath = (Resolve-Path -LiteralPath $Document).Path
$Ext          = [System.IO.Path]::GetExtension($DocumentPath).ToLowerInvariant()
if ($AllowedExtensions -notcontains $Ext) {
  Fail "Unsupported input format '$Ext'.`n$Usage"
}

if ($Format) {
  $FormatMatch = $AllowedFormats | Where-Object { $_ -ieq $Format } | Select-Object -First 1
  if (-not $FormatMatch) {
    Fail "Unsupported export format '$Format'. Accepted: $($AllowedFormats -join ' ')"
  }
  $Format = $FormatMatch
}

$FormulaModes = @('hybrid', 'text', 'image')
$FormulaModeMatch = $FormulaModes | Where-Object { $_ -ieq $FormulaMode } | Select-Object -First 1
if (-not $FormulaModeMatch) {
  Fail "Unsupported formula mode '$FormulaMode'. Accepted: $($FormulaModes -join ' ')"
}
$FormulaMode = $FormulaModeMatch

$Stem       = [System.IO.Path]::GetFileNameWithoutExtension($DocumentPath)
$IsPdf      = ($Ext -eq '.pdf')
$UsesBridge = ($IsPdf -and $PdfBackend -eq 'babeldoc')
$StateRoot  = Join-Path $WenyiDir $StateDir
$RunStateDir = Join-Path $StateRoot (Get-Slug $Stem)
$OutDir     = Join-Path (Split-Path -Parent $DocumentPath) 'output'

if ($Out) {
  $OutFile = $Out
} else {
  $OutExt = if ($Format) {
    if ($Format -eq 'markdown') { '.md' } else { ".$Format" }
  } elseif ($UsesBridge) {
    '.pdf'
  } else {
    '.epub'
  }
  $OutFile = Join-Path $OutDir "$Stem.$Target$OutExt"
}
$Action = if ($Assemble) { 'export from existing state' } else { 'translate, then review, then refresh export' }

$ExportArgs = @()
if ($Format) { $ExportArgs += @('--format', $Format) }
if ($Out) { $ExportArgs += @('--out', $Out) }

Write-Host "Document     : $DocumentPath"
Write-Host "Format       : $Ext"
Write-Host "Target       : $Target"
if ($IsPdf) {
  $backendNote = if ($UsesBridge) { 'babeldoc (layout-preserving, local bridge)' } else { 'mineru (cloud conversion)' }
  Write-Host "PDF backend  : $backendNote"
}
Write-Host "State root   : $StateDir"
Write-Host "Export format: $(if ($Format) { $Format } else { 'auto' })"
Write-Host "Action       : $Action"
Write-Host "Expected out : $OutFile"
Write-Host ""

# --- 3. Credentials (not needed to export existing state) -------------------
if (-not $Assemble) {
  if (-not $env:SILICONFLOW_API_KEY) {
    # A shell that predates `setx` (or a launcher without a fresh environment)
    # would otherwise fail hours into the run: fall back to the user-level value.
    $stored = [Environment]::GetEnvironmentVariable('SILICONFLOW_API_KEY', 'User')
    if ($stored) { $env:SILICONFLOW_API_KEY = $stored }
  }
  if (-not $env:SILICONFLOW_API_KEY) {
    Fail "SILICONFLOW_API_KEY is not set. Open a NEW terminal, or run: `$env:SILICONFLOW_API_KEY = 'sk-...' (or persist it with setx)."
  }

  # MinerU converts PDFs through its cloud API, so it needs its own token.
  if ($IsPdf -and $PdfBackend -eq 'mineru') {
    if (-not $env:MINERU_API_KEY) {
      $storedMineru = [Environment]::GetEnvironmentVariable('MINERU_API_KEY', 'User')
      if ($storedMineru) { $env:MINERU_API_KEY = $storedMineru }
    }
    if (-not $env:MINERU_API_KEY) {
      Fail (
        "MINERU_API_KEY is not set: the MinerU backend converts PDFs through the cloud API. " +
        "Use the API token from the MinerU console (the Bearer token value, not the Access Key ID / " +
        "Secret Access Key pair), then persist it with: setx MINERU_API_KEY `"your-token`" " +
        "and open a new terminal."
      )
    }
  }
}

# --- 4. Runtime config: target language, PDF backend, state root ------------
$ConfigRun = Join-Path ([System.IO.Path]::GetTempPath()) (
  "wenyi-run-$([regex]::Replace($Target, '[^A-Za-z0-9-]', '_'))-$PdfBackend-" +
  "$([regex]::Replace($StateDir, '[^A-Za-z0-9-]', '_')).yaml"
)
# Only single quotes: Windows PowerShell 5.1 strips double quotes from arguments
# passed to native executables, which would corrupt the embedded program.
$configScript = @'
import sys
import yaml

src, dst, target, backend, state_dir = sys.argv[1:6]
with open(src, encoding='utf-8') as handle:
    data = yaml.safe_load(handle) or {}
language = data.setdefault('language', {})
language['target'] = target
pipeline = data.setdefault('pipeline', {})
pipeline['pdf_backend'] = backend
paths = data.setdefault('paths', {})
paths['state_dir'] = state_dir
with open(dst, 'w', encoding='utf-8') as handle:
    yaml.safe_dump(data, handle, allow_unicode=True, sort_keys=False)
'@
& $WenyiPy -c $configScript $ConfigSrc $ConfigRun $Target $PdfBackend $StateDir
if ($LASTEXITCODE -ne 0) { Fail "Could not write the runtime config (from $ConfigSrc)." }
Write-Host "Runtime config: $ConfigRun"

# --- 5. Optional: wipe previous run state -----------------------------------
if ($Reset -or $DryRun) {
  if (Test-Path -LiteralPath $RunStateDir) {
    if ($DryRun) {
      Write-Host "[dry-run] would delete run state: $RunStateDir"
    } else {
      Remove-Item -LiteralPath $RunStateDir -Recurse -Force
      Write-Host "Deleted run state: $RunStateDir"
    }
  } else {
    Write-Host "No run state named: $RunStateDir"
    if (-not $IsPdf) {
      Write-Host "  (non-PDF state is named after the document's own title; check: $StateRoot)"
    }
  }
}

# --- 6. BabelDOC bridge, only for PDF input ---------------------------------
function Test-Bridge {
  try {
    Invoke-RestMethod -Uri "$BridgeUrl/health" -TimeoutSec 5 | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-BridgePid {
  foreach ($line in (netstat -ano)) {
    if ("$line" -match ":$Port\s+\S+\s+LISTENING\s+(\d+)") { return [int]$Matches[1] }
  }
  return 0
}

function Stop-Bridge {
  $bridgePid = Get-BridgePid
  if ($bridgePid -le 0) { return }
  Write-Host "Stopping the process listening on port $Port (pid $bridgePid)."
  Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-BridgePid) -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}

function Start-Bridge {
  Write-Host "Starting BabelDOC bridge (hidden background process)..."
  $env:WENYI_BABELDOC_STATE_DIR = $SessionDir
  $outLog = Join-Path $SessionDir 'bridge.out.log'
  $errLog = Join-Path $SessionDir 'bridge.err.log'
  # Windows PowerShell 5.1 throws "Item has already been added. Key in dictionary:
  # 'Path'" when Start-Process combines -RedirectStandardOutput with an environment
  # that carries both Path and PATH. Let a tiny shim do the redirection instead; it
  # is also runnable by hand when something needs debugging.
  $shim = Join-Path $SessionDir 'start-bridge.cmd'
  @"
@echo off
cd /d "$BridgeDir"
"$BridgeExe" > "$outLog" 2> "$errLog"
"@ | Set-Content -LiteralPath $shim -Encoding Default
  Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/c', "`"$shim`"" -WindowStyle Hidden |
    Out-Null

  $deadline = (Get-Date).AddSeconds(90)
  while (-not (Test-Bridge)) {
    if ((Get-Date) -gt $deadline) {
      if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Tail 20 | Write-Host }
      Fail "BabelDOC bridge did not become healthy within 90 seconds."
    }
    Start-Sleep -Seconds 2
  }
  Write-Host "BabelDOC bridge is up on $BridgeUrl"
}

if ($UsesBridge) {
  if (-not (Test-Path -LiteralPath $BridgeExe)) {
    Fail "BabelDOC bridge not installed: $BridgeExe"
  }
  New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null

  if ($RestartBridge) { Stop-Bridge }

  if (Test-Bridge) {
    Write-Host "BabelDOC bridge already running on $BridgeUrl"
  } else {
    Start-Bridge
  }
  $bridgePid = Get-BridgePid
  if ($bridgePid -gt 0) {
    $bridgeProcess = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
    if ($bridgeProcess) {
      Write-Host ("Bridge process: pid {0}, started {1:yyyy-MM-dd HH:mm:ss}" -f `
        $bridgeProcess.Id, $bridgeProcess.StartTime)
    }
  }
  Write-Host "Bridge sessions are kept in: $SessionDir"
} elseif ($IsPdf) {
  Write-Host "MinerU backend: PDF conversion runs through the cloud API, no local bridge needed."
} else {
  Write-Host "No PDF input: the BabelDOC bridge is not needed."
}

# --- 7. Translate or export -------------------------------------------------
# A local proxy attached to this shell (Clash and friends) can answer the
# bridge's slow responses with its own "502 Bad Gateway". Keep loopback direct.
$loopback = @('127.0.0.1', 'localhost', '::1')
$existingNoProxy = @($env:NO_PROXY, $env:no_proxy) | Where-Object { $_ } | Select-Object -First 1
if ($existingNoProxy) { $loopback += $existingNoProxy -split ',' }
$noProxyValue = ($loopback | Where-Object { $_ } | ForEach-Object { $_.Trim() } |
  Where-Object { $_ } | Select-Object -Unique) -join ','
$env:NO_PROXY = $noProxyValue
$env:no_proxy = $noProxyValue
# If an internal artifact guard ever trips, let it write the offending key, the
# resolved path and the call stack here so the failure is explainable.
$env:WENYI_ARTIFACT_DEBUG = Join-Path $ProjectRoot 'artifact-debug.log'

foreach ($proxyName in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy')) {
  $proxyValue = [Environment]::GetEnvironmentVariable($proxyName)
  if ($proxyValue) {
    Write-Host "Proxy $proxyName is set; loopback stays direct (NO_PROXY)."
  }
}

function Test-TranslationComplete {
  # Match the run state to this input by content hash, then require every chapter
  # to be done. Used to decide whether exporting is safe after a failed stage.
  try {
    $hash = (Get-FileHash -LiteralPath $DocumentPath -Algorithm SHA256).Hash.ToLowerInvariant()
  } catch {
    return $false
  }
  if (-not (Test-Path -LiteralPath $StateRoot)) { return $false }
  foreach ($book in Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue) {
    $manifestPath = Join-Path $book.FullName "targets\$Target\manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
    try {
      $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    } catch {
      continue
    }
    if ($manifest.source_sha256 -ne $hash) { continue }
    $pending = @($manifest.chapters | Where-Object { $_.status -ne 'done' })
    if ($pending.Count -eq 0) { return $true }
    Write-Host ("Run state found with {0} chapter(s) still pending." -f $pending.Count)
    return $false
  }
  return $false
}

if ($DryRun) {
  Write-Host ""
  Write-Host "[dry-run] would run, from $WenyiDir :"
  if ($Assemble) {
    Write-Host "          `"$WenyiExe`" --config `"$ConfigRun`" assemble `"$DocumentPath`" $($ExportArgs -join ' ')"
  } else {
    Write-Host "          `"$WenyiExe`" --config `"$ConfigRun`" translate `"$DocumentPath`" --no-review $($ExportArgs -join ' ')"
    Write-Host "          `"$WenyiExe`" --config `"$ConfigRun`" review    `"$DocumentPath`""
    Write-Host "          `"$WenyiExe`" --config `"$ConfigRun`" assemble `"$DocumentPath`" $($ExportArgs -join ' ')"
  }
  exit 0
}

Write-Host ""
if ($Assemble) {
  Write-Host "Exporting from existing state (no model calls)."
} else {
  if ($SkipReview) {
    Write-Host "Translating and exporting. The quality review is skipped."
  } else {
    Write-Host "Translating. The quality review runs afterwards as a separate step."
  }
}
Write-Host ""

$script:WenyiExitCode = 0
function Invoke-Wenyi {
  param([string[]]$CliArgs)
  # Progress output must reach the console, so the exit code travels through a
  # script-scope variable instead of the function's output stream.
  Push-Location $WenyiDir
  try {
    # Use the project virtualenv directly: no uv cache or environment resolution
    # at run time, so a translation cannot fail on that machinery.
    & $WenyiExe --config $ConfigRun @CliArgs
    $script:WenyiExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
}

if ($Assemble) {
  Invoke-Wenyi -CliArgs (@('assemble', $DocumentPath) + $ExportArgs)
} else {
  # Translate and export first, without the review: a review-stage problem must
  # never cost a finished translation.
  Invoke-Wenyi -CliArgs (@('translate', $DocumentPath, '--no-review') + $ExportArgs)
}

# One self-healing retry: if the bridge died during the run, nothing was lost on
# disk, and a fresh bridge plus the same command resumes from saved state.
if ($WenyiExitCode -ne 0 -and $UsesBridge -and -not (Test-Bridge)) {
  Write-Host ""
  Write-Host "The BabelDOC bridge stopped responding: restarting it and retrying once." -ForegroundColor Yellow
  Stop-Bridge
  Start-Bridge
  if ($Assemble) {
    Invoke-Wenyi -CliArgs (@('assemble', $DocumentPath) + $ExportArgs)
  } else {
    Invoke-Wenyi -CliArgs (@('translate', $DocumentPath, '--no-review') + $ExportArgs)
  }
}

$exitCode = $WenyiExitCode

# A failed quality stage must not cost the finished translation: when every
# chapter is translated, export the book anyway and report both outcomes.
if ($exitCode -ne 0 -and -not $Assemble -and (Test-TranslationComplete)) {
  Write-Host ""
  Write-Host "A later stage failed, but every chapter is translated." -ForegroundColor Yellow
  Write-Host "Exporting the book from the finished translation now..." -ForegroundColor Yellow
  $failedExit = $exitCode
  Invoke-Wenyi -CliArgs (@('assemble', $DocumentPath) + $ExportArgs)
  if ($WenyiExitCode -eq 0) {
    $exitCode = 0
    Write-Host "Export succeeded; the failed stage is recorded above." -ForegroundColor Yellow
  } else {
    $exitCode = $failedExit
  }
}

# Optional quality review, isolated from the book: it may reuse earlier review
# progress, and its failure leaves the exported book untouched.
if ($exitCode -eq 0 -and -not $Assemble -and -not $SkipReview) {
  Write-Host ""
  Write-Host "Running the quality review as a separate step." -ForegroundColor Cyan
  Invoke-Wenyi -CliArgs @('review', $DocumentPath)
  if ($WenyiExitCode -eq 0) {
    Write-Host "Review finished; refreshing the export with any published revisions." -ForegroundColor Cyan
    Invoke-Wenyi -CliArgs (@('assemble', $DocumentPath) + $ExportArgs)
    if ($WenyiExitCode -ne 0) {
      Write-Host "The export refresh failed; the book written by the translation step is still valid." -ForegroundColor Yellow
    }
  } else {
    Write-Host "The quality review failed; the exported book is unaffected." -ForegroundColor Yellow
    Write-Host "Diagnostics for that failure: $ProjectRoot\artifact-debug.log" -ForegroundColor Yellow
  }
}

Write-Host ""
if ($exitCode -ne 0) {
  Write-Host "Command failed (exit code $exitCode)." -ForegroundColor Red
  if ($IsPdf) {
    Write-Host "Bridge logs: $SessionDir\bridge.out.log / bridge.err.log"
    if (-not (Test-Bridge)) {
      Write-Host "The BabelDOC bridge is no longer answering on $BridgeUrl." -ForegroundColor Yellow
    }
    Write-Host "If the message above mentions the bridge (extract / fillback / HTTP 502)," -ForegroundColor Yellow
    Write-Host "re-run the same command with -RestartBridge; the run resumes from saved state." -ForegroundColor Yellow
  }
  exit $exitCode
}

$produced = @()
if ($Out) {
  if (Test-Path -LiteralPath $OutFile) { $produced = @(Get-Item -LiteralPath $OutFile) }
} elseif (Test-Path -LiteralPath $OutDir) {
  $produced = Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$Stem.*" } |
    Sort-Object LastWriteTime -Descending
}

if ($produced.Count) {
  Write-Host "Output:" -ForegroundColor Green
  foreach ($file in $produced) {
    Write-Host ("  {0}  ({1:N1} MB)" -f $file.FullName, ($file.Length / 1MB))
  }
} else {
  Write-Host "Finished, but no output file was found under:" -ForegroundColor Yellow
  Write-Host "  $OutDir"
}

# --- 8. Optional: MathML-flattened EPUB for picky readers --------------------
if ($CompatEpub -and $exitCode -eq 0) {
  $epubs = @($produced | Where-Object {
      $_.Extension -ieq '.epub' -and $_.Name -notlike '*-compat.epub'
    })
  if (-not $epubs.Count) {
    Write-Host "CompatEpub: no EPUB in this run's output, nothing to do." -ForegroundColor Yellow
  }
  foreach ($epub in $epubs) {
    Write-Host "Writing a MathML-free copy for readers such as NeatReader..." -ForegroundColor Cyan
    $helper = Join-Path $ScriptDir 'epub-compat.py'
    if (-not (Test-Path -LiteralPath $helper)) {
      Write-Host "  epub-compat.py is missing: $helper" -ForegroundColor Yellow
      break
    }
    # Cover art needs Pillow, which lives in the bridge venv; wenyi's venv lacks it.
    $compatPy = if (Test-Path -LiteralPath $BridgePy) { $BridgePy } else { $WenyiPy }
    Write-Host "  formula mode: $FormulaMode" -ForegroundColor DarkGray
    & $compatPy $helper $epub.FullName "--formulas=$FormulaMode"
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  epub-compat.py exited with code $LASTEXITCODE (translation itself is fine)." -ForegroundColor Yellow
    } else {
      # 原始 .zh.epub 没有封面、带 MathML，直接导入 NeatReader 会卡在“正在添加新书”。
      $compatName = [System.IO.Path]::GetFileNameWithoutExtension($epub.FullName) +
        '-compat' + $epub.Extension
      $compatPath = Join-Path $epub.DirectoryName $compatName
      Write-Host "  导入阅读器请用这一份 / import this file: $compatPath" -ForegroundColor Green
    }
  }
}
