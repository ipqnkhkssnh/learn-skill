#Requires -Version 5.1
<#
extract_frames.ps1 — 录屏抽帧（Windows / PowerShell 版，不需要 bash）

与 extract_frames.sh 功能对齐：按时间间隔取帧、去重、生成 manifest.json / index.md，
可选把帧打包成 base64 批次喂给多模态模型。产物目录结构与 .sh 版完全一致。

用法：
  pwsh -File extract_frames.ps1 <视频> [输出目录] [选项]
  # 在 PowerShell 会话里也可以直接：
  .\extract_frames.ps1 <视频> [输出目录] [选项]

选项（与 .sh 版同名同义，都写双横线）：
  --interval SEC     采样间隔秒（默认 1）。<60s 用 0.5；<10min 用 1；更长用 3~5。
  --max N            最多保留多少帧（默认 300）——成本闸门。
  --width W          输出图最大宽度（默认 1280）。小字多可上 1600。
  --format jpg|png   图片格式，默认 jpg。
  --threshold F      去重阈值（默认 2.0）。ffmpeg 后端只做"逐字节相同"的精确去重。
  --min-gap SEC      时间锚点间隔（默认 30，0 关闭）。仅 OpenCV 后端支持。
  --start SEC        起始时间（默认 0）
  --end SEC          结束时间（默认到片尾）——配合 --interval 0.25 做关键片段二次加密。
  --ocr on|off       本脚本**没有** OCR（Vision OCR 是 macOS 专属）；传 on 会提示后忽略。
  --backend auto|ffmpeg|python   后端（默认 auto：ffmpeg → OpenCV）
  --base64           抽帧后打包 base64 批次（需要 Python）
  --batch-size N     --base64 时每批图片数（默认 20）

依赖（至少满足其一）：
  ffmpeg  抽帧主力：winget install Gyan.FFmpeg   /  choco install ffmpeg
  python  30xx：https://www.python.org/downloads/ 然后 python -m pip install opencv-python numpy

产物：
  <输出目录>\frames\frame_00001.jpg ...
  <输出目录>\manifest.json / index.md
  <输出目录>\batches\*.json     （--base64 时）

提示：macOS / Linux 请用 extract_frames.sh（那里有零依赖的 swift 后端和 OCR）。
#>
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Die  { param([string]$Message) [Console]::Error.WriteLine("extract_frames: $Message"); exit 2 }
function Info { param([string]$Message) [Console]::Error.WriteLine("extract_frames: $Message") }
function Fmt  { param([double]$Value) return $Value.ToString($Invariant) }

function Show-Usage {
  try {
    $emit = $false
    foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
      if (-not $emit) { if ($line -match '^<#') { $emit = $true }; continue }
      if ($line -match '^#>') { break }
      [Console]::Error.WriteLine($line)
    }
  } catch {
    [Console]::Error.WriteLine('用法：extract_frames.ps1 <视频> [输出目录] [--interval 1 --max 300 ...]')
  }
}

# ---------- 参数 ----------
if (-not $Rest -or $Rest.Count -lt 1) { Show-Usage; exit 2 }
if ($Rest[0] -in @('-h', '--help', 'help')) { Show-Usage; exit 0 }

$Video  = $Rest[0]
$OutDir = $null
$i = 1
if ($i -lt $Rest.Count -and -not $Rest[$i].StartsWith('-')) { $OutDir = $Rest[$i]; $i++ }

$Interval  = 1.0
$Max       = 300
$Width     = 1280
$Format    = 'jpg'
$Threshold = 2.0
$MinGap    = 30.0
$StartSec  = 0.0
$EndSec    = 0.0
$Ocr       = 'off'
$Backend   = 'auto'
$DoBase64  = $false
$BatchSize = 20
$fwd = New-Object System.Collections.Generic.List[string]

function Need {
  param([int]$Index, [string]$Option)
  if ($Index -ge $Rest.Count) { Die "选项 $Option 缺参数值" }
}

while ($i -lt $Rest.Count) {
  $opt = $Rest[$i]
  switch -Exact ($opt) {
    '--interval' {
      Need ($i + 1) $opt
      $Interval = [double]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--interval'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--max' {
      Need ($i + 1) $opt
      $Max = [int]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--max'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--width' {
      Need ($i + 1) $opt
      $Width = [int]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--width'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--format' {
      Need ($i + 1) $opt
      $Format = $Rest[$i + 1].ToLowerInvariant()
      if ($Format -notin @('jpg', 'png')) { Die "--format 只接受 jpg / png" }
      $fwd.Add('--format'); $fwd.Add($Format); $i += 2
    }
    '--threshold' {
      Need ($i + 1) $opt
      $Threshold = [double]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--threshold'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--min-gap' {
      Need ($i + 1) $opt
      $MinGap = [double]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--min-gap'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--start' {
      Need ($i + 1) $opt
      $StartSec = [double]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--start'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--end' {
      Need ($i + 1) $opt
      $EndSec = [double]::Parse($Rest[$i + 1], $Invariant)
      $fwd.Add('--end'); $fwd.Add($Rest[$i + 1]); $i += 2
    }
    '--ocr' {
      Need ($i + 1) $opt
      $Ocr = $Rest[$i + 1].ToLowerInvariant()
      if ($Ocr -notin @('on', 'off')) { Die "--ocr 只接受 on / off" }
      $i += 2
    }
    '--backend' {
      Need ($i + 1) $opt
      $Backend = $Rest[$i + 1].ToLowerInvariant()
      $i += 2
    }
    '--base64' { $DoBase64 = $true; $i += 1 }
    '--batch-size' {
      Need ($i + 1) $opt
      $BatchSize = [int]::Parse($Rest[$i + 1], $Invariant)
      $i += 2
    }
    '-h' { Show-Usage; exit 0 }
    '--help' { Show-Usage; exit 0 }
    default { Die "未知选项: $opt（--help 看用法）" }
  }
}

if (-not (Test-Path -LiteralPath $Video -PathType Leaf)) { Die "视频不存在: $Video" }
$VideoPath = (Resolve-Path -LiteralPath $Video).Path

if (-not $OutDir) {
  $parent = [System.IO.Path]::GetDirectoryName($VideoPath)
  $stem   = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
  $OutDir = Join-Path $parent ($stem + '.frames')
}
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$ScriptDir = Split-Path -Parent $PSCommandPath

# ---------- 工具探测 ----------
function Get-ToolPath {
  param([string[]]$Names)
  foreach ($n in $Names) {
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

# 返回 @{ Exe = ...; Pre = @() }；Pre 给 py launcher 用（py -3）
function Get-PythonCmd {
  foreach ($n in @('python3', 'python', 'py')) {
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    $pre = @()
    if ($n -eq 'py') { $pre = @('-3') }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 1
    try {
      $probe = @()
      $probe += $pre
      $probe += @('-c', 'import sys')
      & $cmd.Source @probe 2>$null | Out-Null
      $code = $LASTEXITCODE
    } catch {
      $code = 1
    } finally {
      $ErrorActionPreference = $saved
    }
    if ($code -eq 0) { return [pscustomobject]@{ Exe = $cmd.Source; Pre = $pre } }
  }
  return $null
}

function Invoke-Python {
  param([object]$Py, [string[]]$Arguments, [switch]$Quiet)
  $all = @()
  if ($Py.Pre) { $all += $Py.Pre }
  $all += $Arguments
  if ($Quiet) { & $Py.Exe @all 2>$null | Out-Null } else { & $Py.Exe @all | Out-Host }
  return $LASTEXITCODE
}

function Warn-NoOcr {
  if ($Ocr -ne 'on') { return }
  Info '提示：PowerShell 版没有 OCR（Vision OCR 是 macOS 专属），已按 --ocr off 继续。'
  Info '      需要逐字文案时：在 macOS 上用 extract_frames.sh 抽帧，或抽完用 tesseract / paddleocr 单独识别 frames\*.jpg。'
}

# ---------- 后端：ffmpeg ----------
function Invoke-FfmpegBackend {
  $ffmpeg = Get-ToolPath @('ffmpeg')
  if (-not $ffmpeg) { return $false }
  Warn-NoOcr

  $framesDir = Join-Path $OutDir 'frames'
  if (Test-Path -LiteralPath $framesDir) { Remove-Item -LiteralPath $framesDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $framesDir | Out-Null

  $fps = Fmt (1.0 / $Interval)
  $ffArgs = @('-hide_banner', '-loglevel', 'error', '-y')
  if ($StartSec -ne 0) { $ffArgs += @('-ss', (Fmt $StartSec)) }
  $ffArgs += @('-i', $VideoPath)
  if ($EndSec -ne 0) { $ffArgs += @('-t', (Fmt ($EndSec - $StartSec))) }
  $ffArgs += @('-vf', "fps=$fps,scale='min($Width,iw)':-2", '-q:v', '3')
  $ffArgs += (Join-Path $framesDir ("frame_%05d." + $Format))

  Info "ffmpeg 抽帧（fps=$fps）…"
  & $ffmpeg @ffArgs | Out-Host
  if ($LASTEXITCODE -ne 0) { Die "ffmpeg 抽帧失败（退出码 $LASTEXITCODE）" }

  $manifest = Join-Path $ScriptDir 'assemble_manifest.py'
  $py = Get-PythonCmd
  if ($py -and (Test-Path -LiteralPath $manifest)) {
    $code = Invoke-Python -Py $py -Arguments @(
      $manifest, $OutDir, $VideoPath,
      '--fps', $fps, '--start', (Fmt $StartSec),
      '--threshold', (Fmt $Threshold), '--max', [string]$Max
    )
    if ($code -ne 0) { Die "assemble_manifest.py 失败（退出码 $code）" }
  } else {
    $md = "# 抽帧索引`r`n`r`n> 未找到 python，仅输出图片。ffmpeg 后端不做感知去重。`r`n"
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'index.md'), $md, (New-Object System.Text.UTF8Encoding($false)))
    Info '提示：未找到 python，已跳过 manifest.json/index.md（帧数可能偏多）。'
  }
  return $true
}

# ---------- 后端：Python + OpenCV ----------
function Invoke-PythonBackend {
  $py = Get-PythonCmd
  if (-not $py) { return $false }
  $cv2 = Join-Path $ScriptDir 'extract_frames_cv2.py'
  if (-not (Test-Path -LiteralPath $cv2)) { return $false }

  $probe = Invoke-Python -Py $py -Arguments @('-c', 'import cv2') -Quiet
  if ($probe -ne 0) { return $false }

  Warn-NoOcr
  $args = @($cv2, $VideoPath, $OutDir)
  $args += $fwd.ToArray()
  $code = Invoke-Python -Py $py -Arguments $args
  if ($code -ne 0) { Die "OpenCV 抽帧失败（退出码 $code）" }
  return $true
}

# ---------- 选择后端 ----------
switch -Exact ($Backend) {
  'ffmpeg' {
    if (-not (Invoke-FfmpegBackend)) { Die 'ffmpeg 后端不可用（未找到 ffmpeg，装：winget install Gyan.FFmpeg）' }
  }
  'python' {
    if (-not (Invoke-PythonBackend)) { Die 'python 后端不可用（需要 python + opencv-python：python -m pip install opencv-python numpy）' }
  }
  'swift' {
    Die 'swift 后端只在 macOS 的 extract_frames.sh 里可用；Windows 请用 --backend ffmpeg 或 python'
  }
  'auto' {
    if (-not (Invoke-FfmpegBackend)) {
      if (-not (Invoke-PythonBackend)) {
        Die '没有可用后端。请安装 ffmpeg（winget install Gyan.FFmpeg）或 python + opencv-python（python -m pip install opencv-python numpy）'
      }
    }
  }
  default { Die "未知 --backend: $Backend（auto / ffmpeg / python）" }
}

# ---------- 可选：打包 base64 ----------
if ($DoBase64) {
  $py = Get-PythonCmd
  if (-not $py) { Die '--base64 需要 Python（https://www.python.org/downloads/）' }
  $b64 = Join-Path $ScriptDir 'frames_to_base64.py'
  if (-not (Test-Path -LiteralPath $b64)) { Die "缺少 frames_to_base64.py：$b64" }
  $code = Invoke-Python -Py $py -Arguments @($b64, $OutDir, '--batch-size', [string]$BatchSize)
  if ($code -ne 0) { Die "frames_to_base64.py 失败（退出码 $code）" }
}

Info "完成：$OutDir（frames\ + manifest.json + index.md）"
exit 0
