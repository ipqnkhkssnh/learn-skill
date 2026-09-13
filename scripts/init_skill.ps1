#Requires -Version 5.1
<#
init_skill.ps1 — 初始化一个"学到的技能"骨架（Windows / PowerShell 版，不需要 bash）

与 init_skill.sh 行为一致，产物完全相同（UTF-8 无 BOM）。

用法：
  pwsh -File init_skill.ps1 <skill-name> [--base-dir DIR] [--system "ERP"] [--title "ERP 订单管理"] [--force]
  .\init_skill.ps1 <skill-name> --title "ERP 订单管理"

说明：
  * skill-name 必须是小写 kebab-case ASCII（如 erp-order-management），中文只放在 --title。
  * 默认写到 $HOME\.agents\skills\（DSH 实际扫描的用户技能根）。
    顺序：$env:LEARN_SKILLS_ROOT → $env:DSH_AGENTS_HOME\skills → 已存在的 ~\.agents\skills
          → 已存在的 ~\.agent\skills → ~\.agents\skills（新建）。
    注意：Windows 上不要建 ~\.agent 符号链接（普通权限建不了，DSH 也不扫它）。
  * 已存在同名技能时默认拒绝，除非 --force。
#>
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

function Die  { param([string]$Message) [Console]::Error.WriteLine("init_skill: $Message"); exit 2 }
function Info { param([string]$Message) [Console]::Error.WriteLine("init_skill: $Message") }

function Show-Usage {
  try {
    $emit = $false
    foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
      if (-not $emit) { if ($line -match '^<#') { $emit = $true }; continue }
      if ($line -match '^#>') { break }
      [Console]::Error.WriteLine($line)
    }
  } catch {
    [Console]::Error.WriteLine('用法：init_skill.ps1 <skill-name> [--base-dir DIR] [--system S] [--title T] [--force]')
  }
}

# ---------- 参数 ----------
if (-not $Rest -or $Rest.Count -lt 1) { Show-Usage; exit 2 }
if ($Rest[0] -in @('-h', '--help', 'help')) { Show-Usage; exit 0 }

$SkillName = $null
$BaseDir = $null
$System = $null
$Title = $null
$Force = $false

$i = 0
while ($i -lt $Rest.Count) {
  $opt = $Rest[$i]
  switch -Exact ($opt) {
    '--base-dir' {
      if ($i + 1 -ge $Rest.Count) { Die '选项 --base-dir 缺参数值' }
      $BaseDir = $Rest[$i + 1]; $i += 2
    }
    '--system' {
      if ($i + 1 -ge $Rest.Count) { Die '选项 --system 缺参数值' }
      $System = $Rest[$i + 1]; $i += 2
    }
    '--title' {
      if ($i + 1 -ge $Rest.Count) { Die '选项 --title 缺参数值' }
      $Title = $Rest[$i + 1]; $i += 2
    }
    '--force' { $Force = $true; $i += 1 }
    '-h' { Show-Usage; exit 0 }
    '--help' { Show-Usage; exit 0 }
    default {
      if ($opt.StartsWith('-')) { Die "未知选项: $opt（--help 看用法）" }
      if ($SkillName) { Die '只接受一个技能名' }
      $SkillName = $opt; $i += 1
    }
  }
}

if (-not $SkillName) { Show-Usage; exit 2 }
if ($SkillName -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
  Die "技能名必须是小写 kebab-case ASCII（字母/数字/单个连字符），例如 erp-order-management"
}

if (-not $System) { $System = $SkillName }
if (-not $Title)  { $Title = $SkillName }

function Resolve-SkillsRoot {
  if ($env:LEARN_SKILLS_ROOT) { return $env:LEARN_SKILLS_ROOT }
  if ($env:DSH_AGENTS_HOME) { return (Join-Path $env:DSH_AGENTS_HOME 'skills') }
  $agents = Join-Path (Join-Path $HOME '.agents') 'skills'
  $alias  = Join-Path (Join-Path $HOME '.agent') 'skills'
  if (Test-Path -LiteralPath $agents -PathType Container) { return $agents }
  if (Test-Path -LiteralPath $alias -PathType Container) { return $alias }
  return $agents
}

if (-not $BaseDir) { $BaseDir = Resolve-SkillsRoot }

$ScriptDir   = Split-Path -Parent $PSCommandPath
$TemplateDir = Join-Path (Split-Path -Parent $ScriptDir) 'templates'
$Dest = Join-Path $BaseDir $SkillName

if (Test-Path -LiteralPath $Dest) {
  if (-not $Force) {
    Die "已存在：$Dest（要覆盖请加 --force，或改用 learn-skill 模式 B 增量更新）"
  }
}

# 可写性预检：给出可操作的提示，而不是等中途失败
try {
  if (-not (Test-Path -LiteralPath $BaseDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
  }
  $probe = Join-Path $BaseDir ('.write-test-' + [Guid]::NewGuid().ToString('N'))
  [System.IO.File]::WriteAllText($probe, 'ok')
  Remove-Item -LiteralPath $probe -Force
} catch {
  Die "技能根目录不可写：$BaseDir
  · 当前沙箱可能只允许写工作区（workspace-write）。请对这一步申请更宽的文件权限，或改用 --base-dir <可写目录>。
  · 也可以直接指定：`$env:LEARN_SKILLS_ROOT='<可写目录>'; .\init_skill.ps1 ..."
}

$Today = (Get-Date).ToString('yyyy-MM-dd')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Render-Template {
  param([string]$Template, [string]$Destination)
  if (-not (Test-Path -LiteralPath $Template)) { Die "缺少模板：$Template" }
  $text = [System.IO.File]::ReadAllText($Template, [System.Text.Encoding]::UTF8)
  $text = $text.Replace('{{SKILL_NAME}}', $SkillName).Replace('{{TITLE}}', $Title).Replace('{{SYSTEM}}', $System).Replace('{{DATE}}', $Today)
  [System.IO.File]::WriteAllText($Destination, $text, $Utf8NoBom)
}

foreach ($sub in @('pages', 'tasks', 'state', 'assets')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Dest $sub) | Out-Null
}

Render-Template -Template (Join-Path $TemplateDir 'SKILL.template.md')      -Destination (Join-Path $Dest 'SKILL.md')
Render-Template -Template (Join-Path $TemplateDir 'meta.template.json')    -Destination (Join-Path (Join-Path $Dest 'state') 'meta.json')
Render-Template -Template (Join-Path $TemplateDir 'CHANGELOG.template.md') -Destination (Join-Path $Dest 'CHANGELOG.md')
Copy-Item -LiteralPath (Join-Path $TemplateDir 'page.template.md') -Destination (Join-Path (Join-Path $Dest 'pages') 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $TemplateDir 'task.template.md') -Destination (Join-Path (Join-Path $Dest 'tasks') 'README.md') -Force

Info "已创建技能骨架：$Dest"
$validateScript = Join-Path $ScriptDir 'validate_skill.ps1'
@"

下一步（learn-skill 模式 A 的 Step 5）：
  1. 先读 pages\README.md 与 tasks\README.md 了解格式，然后**删掉**它们（或保留作模板）；
  2. 把归纳结果写进 SKILL.md（入口/前置条件/能力清单/索引）、pages\*.md、tasks\*.md；
  3. 更新 state\meta.json（coverage、unknowns、sourceRecordings）与 CHANGELOG.md；
  4. 自检：pwsh -File "$validateScript" "$Dest"
"@ | ForEach-Object { [Console]::Error.WriteLine($_) }

Write-Output $Dest
exit 0
