#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""frames_to_base64.py — 把抽帧结果打包成"JPEG → base64"批次，交给多模态大模型理解。

输入：extract_frames.sh 的产物目录（含 manifest.json 与 frames/*.jpg），或直接给图片目录/文件。
输出：<out>/batch_0001.json ... 每批一个 JSON，内含可直接塞进多模态消息的 base64 图片。

用法：
  python3 frames_to_base64.py <抽帧目录|图片目录> [--out DIR] [--batch-size 20]
                             [--max-batch-mb 6] [--data-uri] [--start-index N] [--end-index N]

产物：
  batches/batch_0001.json   本批图片：index / tLabel / file / mime / bytes / base64（含 OCR 文本，如有）
  batches/batch_0001.txt    --data-uri 时额外产出：每行一个 data:image/jpeg;base64,... 便于直接粘贴
  batches/index.json        批次清单：每批覆盖哪些帧、总字节数、总 token 粗估
  batches/README.md         怎么喂给模型的说明

约定：帧按 manifest 顺序切批；单批同时受 --batch-size 与 --max-batch-mb 约束，
避免一次请求过大被截断或超时。
"""

import argparse
import base64
import json
import os
import sys

JPEG_MAGIC = b"\xff\xd8\xff"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def fail(msg):
    sys.stderr.write("frames_to_base64: %s\n" % msg)
    sys.exit(2)


def sniff_mime(path):
    with open(path, "rb") as fh:
        head = fh.read(8)
    if head.startswith(JPEG_MAGIC):
        return "image/jpeg"
    if head.startswith(PNG_MAGIC):
        return "image/png"
    return None


def load_manifest(root):
    """返回 [(index, tLabel, 绝对路径, ocr文本)]，按时间顺序。"""
    manifest_path = os.path.join(root, "manifest.json")
    items = []
    if os.path.isfile(manifest_path):
        with open(manifest_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        for f in data.get("frames", []):
            rel = f.get("file")
            if not rel:
                continue
            path = os.path.join(root, rel)
            if not os.path.isfile(path):
                # 允许 manifest 里是相对 frames/ 的名字
                alt = os.path.join(root, "frames", os.path.basename(rel))
                if os.path.isfile(alt):
                    path = alt
                else:
                    continue
            items.append((f.get("index", len(items) + 1), f.get("tLabel", ""), path, f.get("ocr")))
    if items:
        return items

    # 没有 manifest：直接扫目录里的图片
    exts = (".jpg", ".jpeg", ".png")
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.lower().endswith(exts):
                found.append(os.path.join(dirpath, name))
    if os.path.isfile(root) and root.lower().endswith(exts):
        found = [root]
    for i, path in enumerate(sorted(found), start=1):
        items.append((i, "", path, None))
    return items


def image_size(path):
    """不依赖 Pillow 读出 JPEG/PNG 的像素尺寸；失败返回 (None, None)。"""
    with open(path, "rb") as fh:
        data = fh.read()
    if data.startswith(PNG_MAGIC) and len(data) >= 24:
        import struct
        w, h = struct.unpack(">II", data[16:24])
        return int(w), int(h)
    if data.startswith(JPEG_MAGIC):
        i = 2
        n = len(data)
        while i + 9 < n:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            # SOF0..SOF3 / SOF5..SOF7 / SOF9..SOF11 / SOF13..SOF15
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h = (data[i + 5] << 8) + data[i + 6]
                w = (data[i + 7] << 8) + data[i + 8]
                return int(w), int(h)
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg = (data[i + 2] << 8) + data[i + 3]
            i += 2 + seg
    return None, None


def estimate_tokens(width, height):
    """视觉 token 粗估：按 28x28 一块计（Claude 系贴图方式），只用于量级判断。

    1280x720 ≈ 1.2k token/张；1024x576 ≈ 0.75k；768x432 ≈ 0.43k。
    不同厂商差异可达 2 倍，别当成账单。
    """
    if not width or not height:
        return 0
    import math
    return int(math.ceil(width / 28.0) * math.ceil(height / 28.0))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("input", help="抽帧目录（含 manifest.json）或图片目录/文件")
    ap.add_argument("--out", default=None, help="输出目录，默认 <input>/batches")
    ap.add_argument("--batch-size", type=int, default=20, help="每批最多图片数（默认 20）")
    ap.add_argument("--max-batch-mb", type=float, default=6.0, help="每批 base64 前的原始字节上限（默认 6MB）")
    ap.add_argument("--data-uri", action="store_true", help="额外输出 .txt，每行一个 data:image/jpeg;base64,...")
    ap.add_argument("--start-index", type=int, default=None, help="只打包 >= 该序号的帧")
    ap.add_argument("--end-index", type=int, default=None, help="只打包 <= 该序号的帧")
    args = ap.parse_args()

    root = os.path.abspath(os.path.expanduser(args.input))
    if not os.path.exists(root):
        fail("路径不存在: %s" % root)

    items = load_manifest(root)
    if args.start_index is not None:
        items = [it for it in items if it[0] >= args.start_index]
    if args.end_index is not None:
        items = [it for it in items if it[0] <= args.end_index]
    if not items:
        fail("没找到任何图片（检查 %s 是否为抽帧产物目录）" % root)

    out_dir = os.path.abspath(os.path.expanduser(args.out)) if args.out else os.path.join(root, "batches")
    os.makedirs(out_dir, exist_ok=True)

    max_bytes = int(args.max_batch_mb * 1024 * 1024)
    batches = []
    cur = []
    cur_bytes = 0

    def flush():
        nonlocal cur, cur_bytes
        if not cur:
            return
        batches.append(list(cur))
        cur = []
        cur_bytes = 0

    for index, t_label, path, ocr in items:
        size = os.path.getsize(path)
        if cur and (len(cur) >= args.batch_size or cur_bytes + size > max_bytes):
            flush()
        cur.append((index, t_label, path, ocr, size))
        cur_bytes += size
    flush()

    index_entries = []
    total_images = 0
    total_bytes = 0
    total_tokens = 0
    for bi, batch in enumerate(batches, start=1):
        images = []
        uri_lines = []
        for index, t_label, path, ocr, size in batch:
            mime = sniff_mime(path)
            if mime is None:
                sys.stderr.write("frames_to_base64: 跳过非图片文件 %s\n" % path)
                continue
            with open(path, "rb") as fh:
                raw = fh.read()
            b64 = base64.b64encode(raw).decode("ascii")
            width, height = image_size(path)
            tokens = estimate_tokens(width, height)
            entry = {
                "index": index,
                "tLabel": t_label,
                "file": os.path.relpath(path, root),
                "mime": mime,
                "width": width,
                "height": height,
                "bytes": len(raw),
                "estVisionTokens": tokens,
                "base64": b64,
            }
            if ocr:
                entry["ocr"] = ocr[:2000]
            images.append(entry)
            if args.data_uri:
                uri_lines.append("data:%s;base64,%s" % (mime, b64))
            total_images += 1
            total_bytes += len(raw)
            total_tokens += tokens

        if not images:
            continue

        batch_obj = {
            "batch": bi,
            "count": len(images),
            "note": "按 index 顺序理解；每条含 file/tLabel/base64（base64 为 JPEG 原图）",
            "images": images,
        }
        name = "batch_%04d" % bi
        with open(os.path.join(out_dir, name + ".json"), "w", encoding="utf-8") as fh:
            json.dump(batch_obj, fh, ensure_ascii=False)
        if args.data_uri:
            with open(os.path.join(out_dir, name + ".txt"), "w", encoding="utf-8") as fh:
                fh.write("\n".join(uri_lines))

        batch_bytes = sum(e["bytes"] for e in images)
        batch_tokens = sum(e["estVisionTokens"] for e in images)
        index_entries.append({
            "batch": bi,
            "file": name + ".json",
            "images": len(images),
            "indexRange": [images[0]["index"], images[-1]["index"]],
            "bytes": batch_bytes,
            "estVisionTokens": batch_tokens,
        })

    summary = {
        "source": root,
        "outDir": out_dir,
        "batchSize": args.batch_size,
        "maxBatchMB": args.max_batch_mb,
        "batches": index_entries,
        "totalImages": total_images,
        "totalBytes": total_bytes,
        "estVisionTokens": total_tokens,
        "tokenNote": "按 (宽/28)x(高/28) 粗估，仅用于量级判断；不同厂商差异可达 2 倍。",
        "usage": "把 batch_XXXX.json 中的 images[].base64 作为 image_url/data URI 交给多模态模型；"
                 "或直接用运行时自带的看图工具逐张读 frames/*.jpg（运行时会在内部完成 base64 编码）。",
    }
    with open(os.path.join(out_dir, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)

    readme = [
        "# 帧批次说明（JPEG → base64）",
        "",
        "- 共 %d 张图，切成 %d 批，原始字节 %.1f MB，视觉 token 粗估 ~%d。"
        % (total_images, len(index_entries), total_bytes / 1048576.0, total_tokens),
        "- 每批一个 `batch_XXXX.json`，其中 `images[].base64` 就是 JPEG 的 base64，",
        "  可直接作为多模态消息的 image 输入（data URI 形式：`data:image/jpeg;base64,<base64>`）。",
        "- 请**按批次顺序、按 index 顺序**理解，每批看完先写时间轴笔记，再读下一批。",
        "- 若运行时自带看图工具（如 read_image），优先直接读 `frames/*.jpg`，它会在内部完成同样的 base64 编码；",
        "  本目录的批次用于：换模型喂图、脚本化调用、或运行时没有看图能力时手工投喂。",
        "",
        "| 批次 | 文件 | 帧数 | 序号区间 | 字节 | token 粗估 |",
        "|---|---|---|---|---|---|",
    ]
    for e in index_entries:
        readme.append("| %d | %s | %d | %d–%d | %.2f MB | ~%d |" % (
            e["batch"], e["file"], e["images"], e["indexRange"][0], e["indexRange"][1],
            e["bytes"] / 1048576.0, e["estVisionTokens"]))
    with open(os.path.join(out_dir, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(readme) + "\n")

    print(json.dumps({
        "ok": True,
        "outDir": out_dir,
        "batches": len(index_entries),
        "images": total_images,
        "estVisionTokens": total_tokens,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
