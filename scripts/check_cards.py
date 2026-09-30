#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验「给 job-runner 用的接口」：能力卡（tasks/<task>.json）与选择器集（pages/selectors.json）。

被 validate_skill.sh / validate_skill.ps1 共用（避免两套实现漂移）。

卡片字段契约的**唯一权威实现**在 job-runner 的 `scripts/joblib/cards.py:validate_card`
（它才是消费方）。本脚本装了 job-runner 时会直接调它，避免"两边各写一套规则然后漂移"；
没装时才退回下面这份等价的轻量镜像，并明确提示"未经权威校验"。

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

# ---- v2：写路径三件套 + 通道（与 job-runner/references/job-format.md §5 对应）----
EVIDENCE_LEVELS = ("unknown", "observed", "verified-once", "verified-repeat")
CHANNELS = ("auto", "mcp", "api", "remote-a2desk", "local-a2desk", "playwright", "human")
WRITE_EFFECTS = ("write", "outbound", "irreversible")
READBACK_HOW = ("skill", "tool")
KNOWN_INVARIANTS = (
    "file_exists", "not_empty", "row_count_between", "columns_present", "keys_unique",
    "no_null", "sum_equals", "sums_equal", "equal_counts", "subset_keys", "rows_preserved",
    "field_equals", "field_in", "no_duplicate_side_effect",
)


def authoritative_checker(d: pathlib.Path):
    """找到 job-runner 的卡片校验器就用它（契约的唯一实现）。找不到返回 None。"""
    roots = []
    env = None
    # 技能根 = 被校验技能目录的父目录（<skills>/<skill> → <skills>）
    roots.append(d.resolve().parent)
    for cand in roots:
        scripts = cand / "job-runner" / "scripts"
        if scripts.is_dir():
            sys.path.insert(0, str(scripts))
            try:
                from joblib.cards import validate_card  # type: ignore
                return validate_card
            except Exception:
                return None
        env = cand
    return None


def mirror_check(c):
    """job-runner 没装时的等价轻量校验（规则与 job-runner 的 validate_card 保持一致）。"""
    problems = []
    effects = c.get("effects")
    channel = c.get("channel", "auto")
    if channel not in CHANNELS:
        problems.append("channel 不认识：%r（可用：%s）" % (channel, "/".join(CHANNELS)))
    if isinstance(channel, str) and channel.startswith("mcp"):
        mcp = c.get("mcp")
        if not isinstance(mcp, dict) or not mcp.get("server") or not mcp.get("tool"):
            problems.append("channel=mcp 时必须写 mcp.server + mcp.tool（否则只能退回点界面）")
    if effects in WRITE_EFFECTS:
        ev = c.get("evidenceLevel")
        if ev is None:
            problems.append("写路径必须写 evidenceLevel（%s）——"
                            "编排侧要靠它区分「录屏里看到过」和「实测跑通过」"
                            % "/".join(EVIDENCE_LEVELS))
        elif ev not in EVIDENCE_LEVELS:
            problems.append("evidenceLevel 非法：%r（可用：%s）" % (ev, "/".join(EVIDENCE_LEVELS)))
        imp = c.get("impact")
        if imp is None:
            problems.append("写路径必须写 impact（blastRadius / count / reversible / note）")
        elif not isinstance(imp, dict) or not imp.get("blastRadius"):
            problems.append("impact 缺 blastRadius（出错会波及什么）")
        rb = c.get("readback")
        if not rb:
            problems.append("写路径必须写 readback——没有回读就只剩「界面上看到成功提示」"
                            "这一种判据，那正是假成功的来源")
        elif not isinstance(rb, dict):
            problems.append("readback 必须是对象")
        else:
            if rb.get("how") not in READBACK_HOW:
                problems.append("readback.how 非法：%r（可用：skill/tool）" % rb.get("how"))
            if rb.get("how") == "skill" and not rb.get("use"):
                problems.append("readback.how=skill 时缺 use")
            if rb.get("how") == "tool" and not rb.get("run"):
                problems.append("readback.how=tool 时缺 run")
            for e in rb.get("expect") or []:
                nm = e if isinstance(e, str) else (e or {}).get("name")
                if nm not in KNOWN_INVARIANTS:
                    problems.append("readback.expect 里有未知不变量：%r" % nm)
    return problems


def main(argv):
    if len(argv) < 2:
        print("ERR 用法：check_cards.py <技能目录>")
        return 1
    d = pathlib.Path(argv[1])
    tasks_dir, pages_dir = d / "tasks", d / "pages"
    errors = 0
    AUTHORITATIVE = authoritative_checker(d)
    if AUTHORITATIVE is not None:
        print("INFO 用 job-runner 的权威卡片校验器（joblib.cards.validate_card）检查契约字段")
    else:
        print("INFO 没找到 job-runner，用本地镜像规则校验（未经权威校验；"
              "装好 job-runner 后请再跑一次 validate_skill）")

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
        if c.get("card") not in ("v1", "v2", "inline"):
            problems.append("card 版本应为 v1/v2（实际 %r）" % c.get("card"))
        if AUTHORITATIVE is not None:
            # 契约字段（含 v2 写路径三件套）交给 job-runner 的权威实现
            problems.extend(AUTHORITATIVE(c, p))
        else:
            if c.get("effects") not in EFFECTS:
                problems.append("effects 必须是 %s 之一（实际 %r）"
                                % ("/".join(EFFECTS), c.get("effects")))
            for i, o in enumerate(c.get("outputs") or []):
                pp = str((o or {}).get("path", "")) if isinstance(o, dict) else ""
                if not pp:
                    problems.append("outputs[%d] 缺 path" % i)
                elif pp.startswith("/") or ".." in pathlib.PurePosixPath(pp).parts:
                    problems.append("outputs[%d].path 必须是 run 目录内的相对路径（现在 %s）" % (i, pp))
            for s in c.get("secretsRef") or []:
                if not str(s).startswith("ref:"):
                    problems.append("secretsRef 只能写引用（ref:xxx），不能写凭据值")
            problems.extend(mirror_check(c))
        # 以下是 learn-skill 自己的落盘纪律（权威校验器不管这些）
        if not c.get("automationBoundary"):
            problems.append("缺 automationBoundary（哪一步必须人来，编排侧靠它决定是否允许自动）")
        # 只有**界面通道**才需要 selectors；接口通道（mcp/api）用 mcp 契约代替（job-format.md §5）
        ch = str(c.get("channel") or "auto")
        gui_channel = ch in ("remote-a2desk", "local-a2desk", "playwright", "human", "auto")
        if gui_channel and not c.get("selectors") and not c.get("locators") and not sel.is_file():
            problems.append("界面通道（%s）既没写卡内 selectors，也没有 pages/selectors.json"
                            % ch)
        if ch in ("mcp", "api") and not c.get("mcp") and ch == "mcp":
            problems.append("channel=mcp 缺 mcp.server/tool 调用契约")
        if not (tasks_dir / (name + ".md")).is_file():
            problems.append("有卡没有同名 .md（任务配方），人读的部分不能省")
        problems = list(dict.fromkeys(problems))
        if problems:
            for pr in problems:
                err("%s: %s" % (p.name, pr))
        else:
            print("OK 能力卡合格：%s（%s/%s v%s, effects=%s, 证据=%s, 回读=%s）"
                  % (p.name, c.get("skill"), c.get("task"), c.get("version"),
                     c.get("effects"), c.get("evidenceLevel") or "-",
                     "有" if c.get("readback") else "-"))

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
