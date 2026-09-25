#requires -Version 5.1
<#
.SYNOPSIS
  wenyi Windows 启动脚本（translate-doc.ps1 / wenyi-gui.ps1）共用的目录解析。

.DESCRIPTION
  脚本放在哪儿都能用，不用改路径。支持的两种摆放方式：

  1) 脚本放在「工作目录」里，wenyi 仓库是它的子目录（本项目默认）
       C:\work\llm-translator\          工作目录：脚本、babeldoc-sessions\、state*\
       C:\work\llm-translator\wenyi\    wenyi 仓库（含 pyproject.toml）

  2) 脚本放在仓库里（例如 wenyi\scripts\windows\）
       ...\wenyi\scripts\windows\       脚本
       ...\wenyi\                       仓库
     此时工作目录取仓库的上一层，前提是那一层已经有 babeldoc-sessions\ 或
     wenyi-babeldoc-bridge\；否则就用仓库自身。

  想手动指定工作目录，设环境变量 WENYI_WORKSPACE=<路径> 即可。

  返回对象：ScriptDir（脚本所在处）、RepoDir（wenyi 仓库）、WorkDir（工作目录）、
  BridgeDir（wenyi-babeldoc-bridge）。
#>

function Resolve-WenyiLayout {
  param([string]$StartDir = '')

  if (-not $StartDir) {
    if ($PSScriptRoot) {
      $StartDir = $PSScriptRoot
    } elseif ($PSCommandPath) {
      $StartDir = Split-Path -Parent $PSCommandPath
    } else {
      $StartDir = (Get-Location).Path
    }
  }
  $scriptDir = [System.IO.Path]::GetFullPath($StartDir)

  # 仓库 = 最近的、带 pyproject.toml 的上层目录
  $repoDir = $null
  $probe = $scriptDir
  for ($depth = 0; $depth -lt 5; $depth++) {
    if (Test-Path -LiteralPath (Join-Path $probe 'pyproject.toml')) { $repoDir = $probe; break }
    $parent = Split-Path -Parent $probe
    if (-not $parent -or $parent -eq $probe) { break }
    $probe = $parent
  }
  # 旧布局：脚本在工作目录里，仓库是它的 wenyi\ 子目录
  if (-not $repoDir) {
    $nested = Join-Path $scriptDir 'wenyi'
    if (Test-Path -LiteralPath (Join-Path $nested 'pyproject.toml')) { $repoDir = $nested }
  }
  if (-not $repoDir) { return $null }

  $insideRepo = $scriptDir.StartsWith($repoDir, [System.StringComparison]::OrdinalIgnoreCase)
  $outer = Split-Path -Parent $repoDir

  $workDir = $env:WENYI_WORKSPACE
  if (-not $workDir) {
    if (-not $insideRepo) {
      # 脚本在工作目录里，仓库是子目录：工作目录就是脚本所在处
      $workDir = $scriptDir
    } elseif ($outer -and (Test-Path -LiteralPath (Join-Path $outer 'babeldoc-sessions'))) {
      $workDir = $outer
    } elseif ($outer -and (Test-Path -LiteralPath (Join-Path $outer 'wenyi-babeldoc-bridge'))) {
      $workDir = $outer
    } else {
      $workDir = $repoDir
    }
  }

  return [pscustomobject]@{
    ScriptDir = $scriptDir
    RepoDir   = $repoDir
    WorkDir   = [System.IO.Path]::GetFullPath($workDir)
    BridgeDir = Join-Path ([System.IO.Path]::GetFullPath($workDir)) 'wenyi-babeldoc-bridge'
  }
}

function Get-WenyiLayoutScriptDir {
  if ($PSScriptRoot) { return $PSScriptRoot }
  if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
  return (Get-Location).Path
}
