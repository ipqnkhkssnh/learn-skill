#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract_frames_cv2.py — 抽帧后端：Python + OpenCV（跨平台兜底）。

与 Swift 后端保持同一套语义：固定间隔取帧、32x32 RGB 签名做平均绝对差去重、
纯色帧不占额度、min-gap 时间锚点、超限自动放大间隔保证全程覆盖。
不做 OCR（如需文字证据请用 macOS swift 后端，或抽完单独 OCR）。

用法（一般由 extract_frames.sh 自动调用）：
  extract_frames_cv2.py <视频> <输出目录> [--interval 1] [--max 300] [--width 1280]
                        [--format jpg|png] [--threshold 2.0] [--min-gap 30]
                        [--start 0] [--end 0]
"""

import argparse
import json
import os
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    sys.stderr.write("extract_frames_cv2: 需要 opencv-python 与 numpy（pip install opencv-python）\n")
    sys.exit(2)

GRID = 32


def time_label(seconds):
    total = max(0.0, seconds)
    minutes = int(total) // 60
    return "%02d:%04.1f" % (minutes, total - minutes * 60)


def signature(frame_bgr):
    small = cv2.resize(frame_bgr, (GRID, GRID), interpolation=cv2.INTER_AREA)
    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
    return rgb.astype(np.int16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("outdir")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--max", type=int, default=300)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--format", default="jpg")
    ap.add_argument("--threshold", type=float, default=2.0)
    ap.add_argument("--min-gap", type=float, default=30.0)
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--end", type=float, default=0.0)
    args = ap.parse_args()

    video = os.path.abspath(os.path.expanduser(args.video))
    outdir = os.path.abspath(os.path.expanduser(args.outdir))
    if not os.path.isfile(video):
        sys.stderr.write("extract_frames_cv2: 视频不存在: %s\n" % video)
        sys.exit(2)

    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.stderr.write("extract_frames_cv2: 无法打开视频: %s\n" % video)
        sys.exit(2)

    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration = (total / fps) if total and fps else 0.0

    start = max(0.0, args.start)
    end = min(args.end, duration) if args.end > 0 else duration
    span = max(0.0, end - start)

    interval = args.interval
    adjusted = False
    if span > 0:
        wanted = int(span / interval) + 1
        if wanted > args.max:
            interval = span / max(1, args.max - 1)
            adjusted = True

    frames_dir = os.path.join(outdir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    for name in os.listdir(frames_dir):
        try:
            os.remove(os.path.join(frames_dir, name))
        except OSError:
            pass

    ext = "png" if args.format.lower() == "png" else "jpg"
    ext_flag = [cv2.IMWRITE_PNG_COMPRESSION, 6] if ext == "png" else [cv2.IMWRITE_JPEG_QUALITY, 72]

    kept = []
    sampled = 0
    skipped = 0
    last_sig = None
    last_kept_time = -1e18

    t = start
    while span <= 0 or t <= end + 1e-6:
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
        ok, frame = cap.read()
        if not ok:
            break
        sampled += 1

        sig = signature(frame)
        if last_sig is None:
            diff = 255.0
        else:
            diff = float(np.mean(np.abs(sig - last_sig)))
        uniform = int(sig.max() - sig.min()) < 4
        changed = diff > args.threshold
        anchor_due = (t - last_kept_time) >= args.min_gap

        keep = (not kept) or (changed and not uniform)
        if not keep and anchor_due and not uniform:
            keep = True

        if not keep:
            skipped += 1
            t += interval
            continue

        height, width = frame.shape[:2]
        if width > args.width:
            scale = args.width / float(width)
            frame = cv2.resize(frame, (args.width, int(round(height * scale))), interpolation=cv2.INTER_AREA)
            height, width = frame.shape[:2]

        index = len(kept) + 1
        name = "frame_%05d.%s" % (index, ext)
        cv2.imwrite(os.path.join(frames_dir, name), frame, ext_flag)
        kept.append({
            "index": index,
            "file": "frames/" + name,
            "t": round(t, 2),
            "tLabel": time_label(t),
            "width": width,
            "height": height,
            "diff": round(diff, 1),
        })
        last_sig = sig
        last_kept_time = t
        t += interval

    cap.release()

    manifest = {
        "video": video,
        "outDir": outdir,
        "backend": "python-opencv",
        "durationSeconds": round(duration, 2) if duration else None,
        "rangeStart": start,
        "rangeEnd": end,
        "intervalSeconds": round(interval, 3),
        "intervalAdjusted": adjusted,
        "maxWidth": args.width,
        "dedupeThreshold": args.threshold,
        "signatureGrid": GRID,
        "minGapSeconds": args.min_gap,
        "ocr": False,
        "sampledFrames": sampled,
        "keptFrames": len(kept),
        "skippedFrames": skipped,
        "frames": kept,
    }
    with open(os.path.join(outdir, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    lines = [
        "# 抽帧索引 · %s" % os.path.basename(video),
        "",
        "- 采样间隔: %.2fs%s" % (interval, "（因 --max 上限自动放大）" if adjusted else ""),
        "- 采样 %d 帧 → 去重保留 **%d** 帧" % (sampled, len(kept)),
        "",
        "| # | 时间 | 文件 |",
        "|---|---|---|",
    ]
    for f in kept:
        lines.append("| %d | %s | %s |" % (f["index"], f["tLabel"], f["file"]))
    with open(os.path.join(outdir, "index.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(json.dumps({"ok": True, "outDir": outdir, "frames": len(kept), "sampled": sampled}, ensure_ascii=False))


if __name__ == "__main__":
    main()
