#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""assemble_manifest.py — 为"已经抽好的帧目录"生成 manifest.json 与 index.md。

主要给 ffmpeg 后端用：ffmpeg 负责解码取帧，这个脚本负责补齐时间戳、索引、
精确重复去重与给模型看的索引表，使各后端产物结构一致。

用法：
  assemble_manifest.py <帧目录> <原视频> --fps 1.0 [--start 0] [--threshold 2.0]
                      [--max 300] [--dedupe-md5]

目录约定：脚本读取 <帧目录>/frames/*.jpg（或 .png），原地重排编号后写回。
"""

import argparse
import hashlib
import json
import os
import sys


def fail(msg):
    sys.stderr.write("assemble_manifest: %s\n" % msg)
    sys.exit(2)


def time_label(seconds):
    total = max(0.0, seconds)
    minutes = int(total) // 60
    return "%02d:%04.1f" % (minutes, total - minutes * 60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("video")
    ap.add_argument("--fps", type=float, required=True, help="抽帧用的 fps（= 1/interval）")
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--threshold", type=float, default=2.0)
    ap.add_argument("--max", type=int, default=300)
    ap.add_argument("--dedupe-md5", action="store_true", help="去掉与前一帧逐字节相同的帧")
    args = ap.parse_args()

    root = os.path.abspath(os.path.expanduser(args.outdir))
    frames_dir = os.path.join(root, "frames")
    if not os.path.isdir(frames_dir):
        fail("找不到帧目录: %s" % frames_dir)

    names = sorted(
        n for n in os.listdir(frames_dir)
        if n.lower().endswith((".jpg", ".jpeg", ".png"))
    )
    if not names:
        fail("帧目录为空: %s" % frames_dir)
    if len(names) > args.max:
        sys.stderr.write(
            "assemble_manifest: 提示：帧数 %d 超过 --max %d（ffmpeg 后端不做感知去重，"
            "建议改用 swift 后端或调大 --interval）\n" % (len(names), args.max))

    kept = []
    last_md5 = None
    skipped = 0
    for name in names:
        path = os.path.join(frames_dir, name)
        if args.dedupe_md5:
            digest = hashlib.md5(open(path, "rb").read()).hexdigest()
            if digest == last_md5:
                skipped += 1
                os.remove(path)
                continue
            last_md5 = digest
        kept.append(name)

    # 重新编号，保证连续
    final = []
    for i, name in enumerate(kept, start=1):
        ext = os.path.splitext(name)[1].lower()
        new_name = "frame_%05d%s" % (i, ext)
        if new_name != name:
            os.rename(os.path.join(frames_dir, name), os.path.join(frames_dir, new_name))
        t = args.start + (i - 1) / args.fps
        final.append({
            "index": i,
            "file": "frames/" + new_name,
            "t": round(t, 2),
            "tLabel": time_label(t),
        })

    manifest = {
        "video": os.path.abspath(args.video),
        "outDir": root,
        "backend": "ffmpeg",
        "durationSeconds": None,
        "rangeStart": args.start,
        "intervalSeconds": round(1.0 / args.fps, 4),
        "dedupeThreshold": args.threshold,
        "exactDuplicateSkipped": skipped,
        "note": "ffmpeg 后端不做感知去重（阈值仅记录）；如帧数偏多请用 swift 后端。",
        "sampledFrames": len(names),
        "keptFrames": len(final),
        "frames": final,
    }
    with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    lines = [
        "# 抽帧索引 · %s" % os.path.basename(args.video),
        "",
        "- 采样间隔: %.2fs" % (1.0 / args.fps),
        "- 采样 %d 帧 → 保留 **%d** 帧" % (len(names), len(final)),
        "",
        "| # | 时间 | 文件 |",
        "|---|---|---|",
    ]
    for f in final:
        lines.append("| %d | %s | %s |" % (f["index"], f["tLabel"], f["file"]))
    with open(os.path.join(root, "index.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(json.dumps({"ok": True, "frames": len(final), "outDir": root}, ensure_ascii=False))


if __name__ == "__main__":
    main()
