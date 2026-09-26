#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验「给 job-runner 用的接口」：能力卡（tasks/<task>.json）与选择器集（pages/selectors.json）。

被 validate_skill.sh / validate_skill.ps1 共用（避免两套实现漂移）。

输出每行以 `OK ` / `WARN ` / `ERR ` / `INFO ` 开头，由调用方决定怎么计数与着色。
退出码：0 = 没有 ERR；1 = 有 ERR。
"""
from __future__ import annotations

import json
import pathlib
import sys

REQ = ("card", "skill", "task", "version", "outputs")
EFFECTS = ("read", "write", "outbound", "irreversible")
MAIN_KEYS = ("systems", "envClass", "capabilities", "secretsRef")


def main(argv):
    if len(argv) < 2:
        print("ERR 用法：check_cards.py <技能目录>")
        return 1
    d = pathlib.Path(argv[1])
    tasks_dir, pages_dir = d / "tasks", d / "pages"
    errors = 0

    def err(msg):
        nonlocal errors
        errors += 1
        print("ERR " + msg)

    mds = sorted(p for p in tasks_dir.glob("*.md") if p.name != "README.md") if tasks_dir.is_dir() else []
    cards = ({p.stem: p for p in tasks_dir.glob("*.json") if not p.name.startswith("_")}
             if tasks_dir.is_dir() else {})
    sel = pages_dir / "selectors.json"

    missing = [m.stem for m in mds if m.stem not in cards]
    if mds and missing:
        print("WARN 有 %d 个任务还没有能力卡（tasks/<task>.json）：%s"
              % (len(missing), ", ".join(missing[:8])))
        print("INFO 没有卡的任务无法被 job-runner 调用——复制 tasks/_capability.example.json 补齐，"
              "或在模式 B 回写时一并产出")
    elif mds:
        print("OK %d 个任务都配了能力卡" % len(mds))

    for name, p in sorted(cards.items()):
        try:
            c = json.loads(p.read_text(encoding="utf-8"))
        except Exception as exc:
            err("能力卡不是合法 JSON：%s（%s）" % (p.name, exc))
            continue
        if not isinstance(c, dict):
            err("能力卡必须是对象：%s" % p.name)
            continue
        problems = []
        for k in REQ:
            if k not in c:
                problems.append("缺字段 %s" % k)
        if c.get("card") != "v1":
            problems.append("card 版本应为 v1（实际 %r）" % c.get("card"))
        if c.get("effects") not in EFFECTS:
            problems.append("effects 必须是 %s 之一（实际 %r）" % ("/".join(EFFECTS), c.get("effects")))
        for i, o in enumerate(c.get("outputs") or []):
            pp = str((o or {}).get("path", "")) if isinstance(o, dict) else ""
            if not pp:
                problems.append("outputs[%d] 缺 path" % i)
            elif pp.startswith("/") or ".." in pathlib.PurePosixPath(pp).parts:
                problems.append("outputs[%d].path 必须是 run 目录内的相对路径（现在 %s）" % (i, pp))
        if not c.get("automationBoundary"):
            problems.append("缺 automationBoundary（哪一步必须人来，编排侧靠它决定是否允许自动）")
        if not c.get("selectors") and not sel.is_file():
            problems.append("既没写卡内 selectors，也没有 pages/selectors.json")
        for s in c.get("secretsRef") or []:
            if not str(s).startswith("ref:"):
                problems.append("secretsRef 只能写引用（ref:xxx），不能写凭据值")
        if not (tasks_dir / (name + ".md")).is_file():
            problems.append("有卡没有同名 .md（任务配方），人读的部分不能省")
        if problems:
            for pr in problems:
                err("%s: %s" % (p.name, pr))
        else:
            print("OK 能力卡合格：%s（%s/%s v%s, effects=%s）"
                  % (p.name, c.get("skill"), c.get("task"), c.get("version"), c.get("effects")))

    # md 与卡的入参名一致性
    for name, p in sorted(cards.items()):
        md = tasks_dir / (name + ".md")
        if not md.is_file():
            continue
        try:
            c = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        text = md.read_text(encoding="utf-8", errors="ignore")
        names = [i.get("name") for i in (c.get("inputs") or []) if isinstance(i, dict)]
        gap = [n for n in names if n and n not in text]
        if gap:
            print("WARN %s 的入参 %s 在同名 .md 里找不到，两边说法可能不一致" % (name, ", ".join(gap)))

    # 选择器集
    if sel.is_file():
        try:
            data = json.loads(sel.read_text(encoding="utf-8"))
        except Exception as exc:
            print("ERR pages/selectors.json 不是合法 JSON：%s" % exc)
            data = None
            errors += 1
        if isinstance(data, dict):
            pages = data.get("pages") or {}
            if not pages:
                print("WARN pages/selectors.json 里没有 pages 条目")
            for pid, pg in pages.items():
                pg = pg or {}
                if not (pg.get("identify") or pg.get("entries")):
                    print("WARN selectors.json 的 %s 缺 identify/entries" % pid)
                for e in (pg.get("entries") or []):
                    if str((e or {}).get("by", "")).lower() in ("xy", "coord", "coordinate", "pixel"):
                        err("selectors.json 的 %s 用了坐标定位（违反铁律 11：定位靠语义）" % pid)
            print("OK pages/selectors.json 可解析（%d 个页面）" % len(pages))
    else:
        print("WARN 没有 pages/selectors.json（编排侧只能靠模型临场找元素，稳定性差）")

    # meta.json 新增字段
    meta = d / "state" / "meta.json"
    try:
        m = json.loads(meta.read_text(encoding="utf-8")) if meta.is_file() else None
    except Exception:
        m = None
    if isinstance(m, dict):
        lack = [k for k in MAIN_KEYS if k not in m]
        if lack:
            print("WARN meta.json 缺新增字段：%s（编排侧判断多系统/环境/可自动化范围时要用）"
                  % ", ".join(lack))
        else:
            print("OK meta.json 已含 " + "/".join(MAIN_KEYS))

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
