#Requires -Version 5.1
<#
validate_skill.ps1 — 校验一个"学到的技能包"是否合格（Windows / PowerShell 版）

与 validate_skill.sh 检查项一致：结构 / frontmatter / meta.json / 覆盖率 / 凭据泄漏 / 泛化。

用法：
  pwsh -File validate_skill.ps1 <技能目录 | 技能名>
  .\validate_skill.ps1 sunrise-badge-platform

退出码：0 = 通过（可能有警告）；1 = 有致命问题。

技能根解析顺序（与 init_skill.ps1 一致）：
  $env:LEARN_SKILLS_ROOT → $env:DSH_AGENTS_HOME\skills → ~\.agents\skills → ~\.agent\skills → ~\.agents\skills
#>
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

function Die  { param([string]$Message) [Console]::Error.WriteLine("validate_skill: $Message"); exit 2 }
function Show-Usage {
  try {
    $emit = $false
    foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
      if (-not $emit) { if ($line -match '^<#') { $emit = $true }; continue }
      if ($line -match '^#>') { break }
      [Console]::Error.WriteLine($line)
    }
  } catch {
    [Console]::Error.WriteLine('用法：validate_skill.ps1 <技能目录 | 技能名>')
  }
}

$script:Errors = 0
$script:Warnings = 0
function Fail { param([string]$m) Write-Host ('  [x] ' + $m); $script:Errors++ }
function Warn { param([string]$m) Write-Host ('  [!] ' + $m); $script:Warnings++ }
function Ok   { param([string]$m) Write-Host ('  [ok] ' + $m) }
function Note { param([string]$m) Write-Host ('  · ' + $m) }

if (-not $Rest -or $Rest.Count -lt 1) { Show-Usage; exit 2 }
if ($Rest[0] -in @('-h', '--help', 'help')) { Show-Usage; exit 0 }
$Target = $Rest[0]

function Resolve-SkillsRoot {
  if ($env:LEARN_SKILLS_ROOT) { return $env:LEARN_SKILLS_ROOT }
  if ($env:DSH_AGENTS_HOME) { return (Join-Path $env:DSH_AGENTS_HOME 'skills') }
  $agents = Join-Path (Join-Path $HOME '.agents') 'skills'
  $alias  = Join-Path (Join-Path $HOME '.agent') 'skills'
  if (Test-Path -LiteralPath $agents -PathType Container) { return $agents }
  if (Test-Path -LiteralPath $alias -PathType Container) { return $alias }
  return $agents
}

if (Test-Path -LiteralPath $Target -PathType Container) {
  $Dir = (Resolve-Path -LiteralPath $Target).Path
} else {
  $root = Resolve-SkillsRoot
  $cand = Join-Path $root $Target
  if (-not (Test-Path -LiteralPath $cand -PathType Container)) {
    Die "找不到技能目录：$Target（也不是 $root 下的技能名）"
  }
  $Dir = (Resolve-Path -LiteralPath $cand).Path
}

$NameExpected = Split-Path -Leaf $Dir
Write-Host "validate_skill: $Dir"

function Read-Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-MdFiles {
  param([string]$Root)
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue)
}

# ---------- 1. 必需文件 ----------
Write-Host ''
Write-Host '[1] 结构'
$SkillMd = Join-Path $Dir 'SKILL.md'
if (-not (Test-Path -LiteralPath $SkillMd -PathType Leaf)) {
  Die '缺 SKILL.md（技能包必须包含 SKILL.md，否则不会被加载）'
}
Ok 'SKILL.md 存在'

foreach ($f in @('CHANGELOG.md', (Join-Path 'state' 'meta.json'))) {
  if (Test-Path -LiteralPath (Join-Path $Dir $f) -PathType Leaf) { Ok "$f 存在" }
  else { Warn "缺 $f（建议补齐：$f 用于版本追溯）" }
}
if (-not (Test-Path -LiteralPath (Join-Path $Dir 'pages') -PathType Container)) { Warn '缺 pages\ 目录（页面知识放这里）' }
if (-not (Test-Path -LiteralPath (Join-Path $Dir 'tasks') -PathType Container)) { Warn '缺 tasks\ 目录（任务配方放这里）' }

# ---------- 2. frontmatter ----------
Write-Host ''
Write-Host '[2] frontmatter'
$lines = [System.IO.File]::ReadAllLines($SkillMd, [System.Text.Encoding]::UTF8)
$fm = @()
if ($lines.Count -ge 1) {
  $first = $lines[0].TrimStart([char]0xFEFF)
  if ($first -eq '---') {
    for ($k = 1; $k -lt $lines.Count; $k++) {
      if ($lines[$k] -eq '---') { break }
      $fm += $lines[$k]
    }
  }
}

if ($fm.Count -eq 0) {
  Fail 'SKILL.md 开头缺少 YAML frontmatter（--- name: ... description: ... ---）'
} else {
  $nameLine = @($fm | Where-Object { $_ -match '^name:' } | Select-Object -First 1)
  $descLine = @($fm | Where-Object { $_ -match '^description:' } | Select-Object -First 1)
  if ($nameLine.Count -eq 0) { Fail 'frontmatter 缺 name' }
  if ($descLine.Count -eq 0) { Fail 'frontmatter 缺 description' }

  if ($nameLine.Count -gt 0) {
    $nameVal = ($nameLine[0] -replace '^name:\s*', '').Trim().Trim('"').Trim("'")
    if ($nameVal -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
      Fail "name 必须是小写 kebab-case ASCII：$nameVal"
    } else {
      Ok "name = $nameVal"
    }
    if ($nameVal -ne $NameExpected) {
      Warn "name（$nameVal）与目录名（$NameExpected）不一致，建议统一"
    }
  }
  if ($descLine.Count -gt 0) {
    $descVal = ($descLine[0] -replace '^description:\s*', '').Trim()
    $descLen = [System.Text.Encoding]::UTF8.GetByteCount($descVal)
    if ($descLen -ge 30) { Ok "description 长度合适（$descLen 字节）" }
    else { Warn "description 偏短（$descLen 字节），应写清「做什么 + 触发场景」" }
  }
}

# ---------- 3. meta.json ----------
Write-Host ''
Write-Host '[3] state\meta.json'
$metaPath = Join-Path (Join-Path $Dir 'state') 'meta.json'
if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
  try {
    $meta = (Read-Text $metaPath) | ConvertFrom-Json
    Ok 'JSON 合法'
    $props = @($meta.PSObject.Properties.Name)
    $missing = @()
    foreach ($key in @('name', 'version', 'updatedAt', 'unknowns')) {
      if ($props -notcontains $key) { $missing += $key }
    }
    if ($missing.Count -gt 0) {
      Warn ('meta.json 缺字段: ' + ($missing -join ', '))
    } else {
      $uCount = if ($null -eq $meta.unknowns) { 0 } else { @($meta.unknowns).Count }
      Ok "关键字段齐全（version=$($meta.version), unknowns=$uCount 条）"
    }
  } catch {
    Fail 'meta.json 不是合法 JSON'
  }
}

# ---------- 4. 覆盖率 ----------
Write-Host ''
Write-Host '[4] 覆盖率'
function Count-PageFiles {
  param([string]$Sub)
  $p = Join-Path $Dir $Sub
  if (-not (Test-Path -LiteralPath $p -PathType Container)) { return 0 }
  return @(Get-ChildItem -LiteralPath $p -File -Filter '*.md' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'README.md' }).Count
}
$pages = Count-PageFiles 'pages'
$tasks = Count-PageFiles 'tasks'
Note "pages: $pages 个页面文件；tasks: $tasks 个任务文件"
if ($pages -lt 1) { Warn '没有任何页面知识（pages\*.md）——技能会缺少"系统里有什么"的部分' }
if ($tasks -lt 1) { Warn '没有任何任务配方（tasks\*.md）——技能无法直接执行' }

$todoFiles = 0
foreach ($f in (Get-MdFiles $Dir)) {
  if ((Read-Text $f.FullName) -match 'TODO|待补|待确认') { $todoFiles++ }
}
if ($todoFiles -gt 0) {
  Note "$todoFiles 个文件仍含 TODO/待补标记（对未验证内容这是**好事**，但要在汇报里说明）"
}

# ---------- 5. 凭据与敏感数据 ----------
Write-Host ''
Write-Host '[5] 凭据 / 敏感数据'
# 与 validate_skill.sh 的 grep -rInE 保持同一语义：主模式大小写敏感，忽略用词大小写不敏感。
$secretPattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}|(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)\s*[:=]\s*\S{3,}'
$secretIgnore = '(?i)TODO|待填|待补|xxx|<[^>]*>|\{\{|来源|placeholder|example'
$hits = @()
foreach ($f in (Get-ChildItem -LiteralPath $Dir -Recurse -File -Include '*.md', '*.json', '*.txt' -ErrorAction SilentlyContinue)) {
  $n = 0
  foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
    $n++
    if ($line -cmatch $secretPattern -and $line -notmatch $secretIgnore) {
      $hits += ("{0}:{1}: {2}" -f $f.FullName, $n, $line.Trim())
    }
  }
}
if ($hits.Count -gt 0) {
  Fail '疑似写入了凭据/密钥，必须移除（只保留"凭据来源"）:'
  $hits | Select-Object -First 20 | ForEach-Object { Write-Host ('      ' + $_) }
} else {
  Ok '未发现明显的凭据/密钥'
}

$piiPattern = '[0-9]{17}[0-9Xx]|1[3-9][0-9]{9}'
$piiIgnore = '(?i)示例|example|TODO|\{\{|xxxx'
$pii = @()
foreach ($f in (Get-ChildItem -LiteralPath $Dir -Recurse -File -Include '*.md' -ErrorAction SilentlyContinue)) {
  $n = 0
  foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
    $n++
    if ($line -match $piiPattern -and $line -notmatch $piiIgnore) {
      $pii += ("{0}:{1}: {2}" -f $f.FullName, $n, $line.Trim())
    }
  }
}
if ($pii.Count -gt 0) {
  Warn '疑似真实手机号/身份证号，请确认是否为占位示例:'
  $pii | Select-Object -First 10 | ForEach-Object { Write-Host ('      ' + $_) }
}

# ---------- 6. 硬编码具体值（泛化检查） ----------
Write-Host ''
Write-Host '[6] 泛化检查（可疑硬编码）'
$hardPattern = '\b(SO|PO|ORD|INV)[0-9]{6,}\b'
$hardIgnore = '(?i)示例|example|参数|占位|\{\{|\$\{'
$hard = @()
foreach ($f in (Get-MdFiles $Dir)) {
  $n = 0
  foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
    $n++
    if ($line -match $hardPattern -and $line -notmatch $hardIgnore) {
      $hard += ("{0}:{1}: {2}" -f $f.FullName, $n, $line.Trim())
    }
  }
}
if ($hard.Count -gt 0) {
  Warn '疑似把具体单号写死在技能里（应参数化为 ${...}）:'
  $hard | Select-Object -First 10 | ForEach-Object { Write-Host ('      ' + $_) }
} else {
  Ok '未发现明显的硬编码单号'
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '────────────────────────────'
if ($script:Errors -gt 0) {
  Write-Host "结果：不通过 —— $($script:Errors) 个致命问题，$($script:Warnings) 个警告"
  exit 1
}
Write-Host "结果：通过 —— $($script:Warnings) 个警告（警告项请自行判断是否需要补学/补齐）"
exit 0
