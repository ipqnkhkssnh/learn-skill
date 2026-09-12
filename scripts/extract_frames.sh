#!/usr/bin/env bash
# extract_frames.sh — 录屏抽帧统一入口：从视频里按时间间隔取帧（JPEG），
# 自动去重、生成 manifest.json/index.md，可选打包成 base64 批次喂给多模态模型。
#
# 用法：
#   extract_frames.sh <视频> [输出目录] [选项]
#
# 常用选项：
#   --interval SEC     采样间隔秒（默认 1）。录屏越短越密：<60s 用 0.5；<10min 用 1；
#                      更长用 3~5。给定 --max 时若帧数超限会自动放大间隔以保证全程覆盖。
#   --max N            最多保留多少帧（默认 300）——这是成本闸门，先想清楚要给模型多少张图。
#   --width W          输出图最大宽度（默认 1280）。小字多的界面可上 1600，成本敏感可降到 1024。
#   --format jpg|png   图片格式，默认 jpg（JPEG 体积小、直接转 base64 喂模型）。
#   --threshold F      去重阈值：整幅画面平均每颜色分量的变化量（默认 2.0）。
#                      调大→保留更少（漏掉细微变化）；调小→保留更多。看到 diff 值可据此微调。
#   --min-gap SEC      即使画面没变化，也至少每 SEC 秒留一帧作时间锚点（默认 30，0 关闭）。
#   --start SEC        起始时间（默认 0）
#   --end SEC          结束时间（默认到片尾）——配合 --interval 0.25 可对关键片段二次加密。
#   --ocr on|off       用 macOS Vision 逐帧 OCR，把文字写进 manifest（默认 off）。
#                      表格/小字/需要精确抄字段名时打开，是"看图"之外的第二路证据。
#   --backend auto|swift|ffmpeg|python   强制指定后端（默认 auto）。
#   --base64           抽帧后自动调用 frames_to_base64.py 打包成 base64 批次。
#   --batch-size N     --base64 时每批图片数（默认 20）。
#
# 产物：
#   <输出目录>/frames/frame_00001.jpg ...
#   <输出目录>/manifest.json   每帧的序号、时间戳、尺寸、差异值、可选 OCR 文本
#   <输出目录>/index.md        给模型看的时间轴索引表
#   <输出目录>/batches/*.json  --base64 时的 base64 批次
#
# 后端优先级：macOS 用 Swift/AVFoundation（零依赖，顺带支持 OCR）；
# 否则用 ffmpeg；再否则用 Python+OpenCV。三者产出的目录结构一致。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'extract_frames: %s\n' "$*" >&2; exit 2; }
info() { printf 'extract_frames: %s\n' "$*" >&2; }

usage() {
  local end
  end="$(grep -n '^# ---------- 参数 ----------' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
  [ -n "$end" ] || end=60
  sed -n "2,$((end - 1))p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------- 参数 ----------
[ $# -ge 1 ] || { usage; exit 2; }
case "${1:-}" in -h|--help) usage; exit 0;; esac

VIDEO="$1"; shift
OUTDIR=""
if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then OUTDIR="$1"; shift; fi
[ -n "$OUTDIR" ] || OUTDIR="$(dirname "$VIDEO")/$(basename "${VIDEO%.*}").frames"

INTERVAL=1; MAX=300; WIDTH=1280; FORMAT=jpg; THRESHOLD=2.0; MINGAP=30
START=0; END=0; OCR=off; BACKEND=auto; BASE64=0; BATCH_SIZE=20
FORWARD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; FORWARD+=(--interval "$2"); shift 2;;
    --max)      MAX="$2";      FORWARD+=(--max "$2");      shift 2;;
    --width)    WIDTH="$2";    FORWARD+=(--width "$2");    shift 2;;
    --format)   FORMAT="$2";   FORWARD+=(--format "$2");   shift 2;;
    --threshold) THRESHOLD="$2"; FORWARD+=(--threshold "$2"); shift 2;;
    --min-gap)  MINGAP="$2";   FORWARD+=(--min-gap "$2");  shift 2;;
    --start)    START="$2";    FORWARD+=(--start "$2");    shift 2;;
    --end)      END="$2";      FORWARD+=(--end "$2");      shift 2;;
    --ocr)      OCR="$2";      FORWARD+=(--ocr "$2");      shift 2;;
    --backend)  BACKEND="$2";  shift 2;;
    --base64)   BASE64=1;      shift;;
    --batch-size) BATCH_SIZE="$2"; shift 2;;
    -h|--help)  usage; exit 0;;
    *) die "未知选项: ${1}（-h 看用法）";;
  esac
done

[ -f "$VIDEO" ] || die "视频不存在: $VIDEO"
VIDEO="$(cd "$(dirname "$VIDEO")" && pwd)/$(basename "$VIDEO")"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# ---------- 构建目录（可写优先，退到临时目录） ----------
pick_build_dir() {
  local cand
  for cand in "$SCRIPT_DIR/../.build" "/tmp/learn-skill-build-$(id -u)" "${TMPDIR:-/tmp}/learn-skill-build"; do
    if mkdir -p "$cand" 2>/dev/null && ( : > "$cand/.wtest" ) 2>/dev/null; then
      rm -f "$cand/.wtest"; printf '%s' "$cand"; return 0
    fi
  done
  return 1
}

# ---------- 后端：Swift / AVFoundation（macOS） ----------
swift_backend() {
  command -v swiftc >/dev/null 2>&1 || return 1
  local build bin src
  build="$(pick_build_dir)" || return 1
  src="$SCRIPT_DIR/extract_frames.swift"
  bin="$build/extract_frames_swift"
  [ -f "$src" ] || return 1
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    mkdir -p "$build/modulecache"
    info "编译 Swift 抽帧后端（首次约 10–40s，之后走缓存）…"
    # -module-cache-path 必须可写，否则 clang 会尝试写系统临时目录而失败
    swiftc -parse-as-library -module-cache-path "$build/modulecache" "$src" -o "$bin" \
      >"$build/swiftc.log" 2>&1 || { info "Swift 后端编译失败，见 $build/swiftc.log"; return 1; }
  fi
  "$bin" "$VIDEO" "$OUTDIR" "${FORWARD[@]+"${FORWARD[@]}"}"; return $?
}

# ---------- 后端：ffmpeg ----------
ffmpeg_backend() {
  command -v ffmpeg >/dev/null 2>&1 || return 1
  local frames="$OUTDIR/frames"
  rm -rf "$frames"; mkdir -p "$frames"
  local fps; fps="$(awk -v i="$INTERVAL" 'BEGIN{printf "%.6f", 1/i}')"
  local args=(-hide_banner -loglevel error -y)
  if [ "$START" != "0" ]; then args+=(-ss "$START"); fi
  args+=(-i "$VIDEO")
  if [ "$END" != "0" ]; then
    local dur; dur="$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.3f", e-s}')"
    args+=(-t "$dur")
  fi
  args+=(-vf "fps=$fps,scale='min($WIDTH,iw)':-2" -q:v 3 "$frames/frame_%05d.$FORMAT")
  info "ffmpeg 抽帧（fps=${fps}）…"
  ffmpeg "${args[@]}" || return 1

  if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/assemble_manifest.py" ]; then
    python3 "$SCRIPT_DIR/assemble_manifest.py" "$OUTDIR" "$VIDEO" --fps "$fps" \
      --start "$START" --threshold "$THRESHOLD" --max "$MAX"
  else
    printf '# 抽帧索引\n\n> 未找到 python3，仅输出图片。ffmpeg 后端不再做感知去重。\n' \
      > "$OUTDIR/index.md"
    info "提示：该后端未做视觉去重，帧数可能偏多；如有可能请用 swift 后端。"
  fi
}

# ---------- 后端：Python + OpenCV ----------
python_backend() {
  command -v python3 >/dev/null 2>&1 || return 1
  [ -f "$SCRIPT_DIR/extract_frames_cv2.py" ] || return 1
  python3 -c "import cv2" >/dev/null 2>&1 || return 1
  python3 "$SCRIPT_DIR/extract_frames_cv2.py" "$VIDEO" "$OUTDIR" "${FORWARD[@]+"${FORWARD[@]}"}"
}

# ---------- 选择后端 ----------
RC=1
case "$BACKEND" in
  swift)  swift_backend  || die "swift 后端不可用（需要 macOS + swiftc）"; RC=0;;
  ffmpeg) ffmpeg_backend || die "ffmpeg 后端不可用"; RC=0;;
  python) python_backend || die "python 后端不可用（需要 python3 + opencv-python）"; RC=0;;
  auto)
    if swift_backend; then RC=0
    elif ffmpeg_backend; then RC=0
    elif python_backend; then RC=0
    else
      die "没有可用后端。请安装其一：macOS 装 Xcode Command Line Tools（提供 swiftc）/ 安装 ffmpeg / pip install opencv-python"
    fi
    ;;
  *) die "未知 --backend: $BACKEND";;
esac
[ "$RC" = 0 ] || exit "$RC"

# ---------- 可选：打包 base64 ----------
if [ "$BASE64" = 1 ]; then
  command -v python3 >/dev/null 2>&1 || die "--base64 需要 python3"
  python3 "$SCRIPT_DIR/frames_to_base64.py" "$OUTDIR" --batch-size "$BATCH_SIZE" >&2
fi

info "完成：${OUTDIR}（frames/ + manifest.json + index.md）"
