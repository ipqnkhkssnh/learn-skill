#Requires -Version 5.1
<#
install.ps1 — 把一个技能包安装到 DSH 扫描的用户技能根（Windows / PowerShell 版）

用法：
  pwsh -File install.ps1 [-Source <技能目录>] [-Name <技能名>] [-SkillsRoot <目录>] [-Force]

默认行为：
  * Source      = 本脚本所在目录的上一级（即 learn-skill 技能包本身）
  * Name        = Source 的目录名
  * SkillsRoot  = $env:LEARN_SKILLS_ROOT → $env:DSH_AGENTS_HOME\skills
                  → 已存在的 ~\.agents\skills → 已存在的 ~\.agent\skills → ~\.agents\skills
  * 复制时排除 .git / .build / __pycache__ / node_modules / .DS_Store

为什么不用符号链接：Windows 普通权限不能建 symlink，而且 DSH 扫的是 ~\.agents\skills，
所以这里直接复制到规范路径，不依赖 ~\.agent 别名。

示例：
  # 安装/更新 learn-skill 自身
  pwsh -File install.ps1 -Force

  # 把某个已学技能装进技能根
  pwsh -File install.ps1 -Source "$HOME\.agent\skills\erp-order-management"
#>
param(
  [string]$Source,
  [string]$Name,
  [string]$SkillsRoot,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Die  { param([string]$Message) [Console]::Error.WriteLine("install: $Message"); exit 2 }
function Info { param([string]$Message) [Console]::Error.WriteLine("install: $Message") }

function Resolve-SkillsRoot {
  if ($env:LEARN_SKILLS_ROOT) { return $env:LEARN_SKILLS_ROOT }
  if ($env:DSH_AGENTS_HOME) { return (Join-Path $env:DSH_AGENTS_HOME 'skills') }
  $agents = Join-Path (Join-Path $HOME '.agents') 'skills'
  $alias  = Join-Path (Join-Path $HOME '.agent') 'skills'
  if (Test-Path -LiteralPath $agents -PathType Container) { return $agents }
  if (Test-Path -LiteralPath $alias -PathType Container) { return $alias }
  return $agents
}

if (-not $Source) {
  $Source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Die "技能目录不存在：$Source" }
$Source = (Resolve-Path -LiteralPath $Source).Path

if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md') -PathType Leaf)) {
  Die "不是技能包（缺 SKILL.md）：$Source"
}

if (-not $Name) { $Name = Split-Path -Leaf $Source }
if ($Name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
  Die "技能名必须是小写 kebab-case ASCII：$Name"
}

if (-not $SkillsRoot) { $SkillsRoot = Resolve-SkillsRoot }
$Dest = Join-Path $SkillsRoot $Name

if ((Test-Path -LiteralPath $Dest) -and (-not $Force)) {
  Die "技能根已有同名技能：$Dest（要覆盖请加 -Force）"
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$exclude = '^(\.git|\.build|__pycache__|node_modules)(\\|$)'
$copied = 0
foreach ($item in (Get-ChildItem -LiteralPath $Source -Recurse -Force)) {
  $rel = $item.FullName.Substring($Source.Length).TrimStart('\', '/')
  $relNorm = $rel -replace '/', '\'
  if ($relNorm -match $exclude) { continue }
  if ($item.Name -eq '.DS_Store') { continue }
  $target = Join-Path $Dest $rel
  if ($item.PSIsContainer) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
  } else {
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    $copied++
  }
}

Info "已安装 $Name → $Dest（$copied 个文件）"
Info 'DSH 会自动发现新技能：新开一个会话即可在技能目录里看到它。'
exit 0
