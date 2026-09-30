#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 tasks/<task>.md 生成能力卡：**草稿**给全部任务，**正式卡**只给人工判定为只读的。

为什么要有这个工具
------------------
能力卡是 job-runner 调用任务的唯一接口，但一条任务该不该有卡、卡里 effects 是什么，
**不能靠脚本从散文里猜**：

* 实测反例：`create-product.md` 的「## 副作用」写的是"新建产品本身不改动**已有**数据"——
  按文字判定会得到"只读"，而它明明在创建业务数据。把写路径标成 `read` = **绕过写闸门**，
  这是本系统里最危险的错误方向。
* 播控技能 17 个配方**根本没有**「## 副作用」段（只有内联的 `**副作用**：无。`）。

所以本工具的定位是：**把能机械提取的都提取出来，把必须人判断的留成显式空缺**。

用法
----
    # 1) 体检：列出每个任务能提取到什么、脚本建议的分类（不改任何文件）
    scaffold_cards.py <技能目录>

    # 2) 给所有缺卡任务生成**草稿**到 tasks/.drafts/（不影响 validate / audit）
    scaffold_cards.py <技能目录> --draft-all

    # 3) 把**人工判定为只读**的任务提升成正式卡 tasks/<task>.json
    #    （判定由人/agent 负责，并在命令里写明，便于审计）
    scaffold_cards.py <技能目录> --promote-read query-devices-by-sn,view-dashboard

设计约束
--------
* 只读卡用**统一产物约定**：`artifacts/<task>/records.csv`（列 `step,item,value`，即"第几步·读到什么·值是什么"）
  + `artifacts/<task>/raw.txt`（原文）。这样不必臆造领域字段名；首次实跑后再按任务真正需要的字段细化。
* 选择器只从配方里**引号内的原文**提取（「按钮文字」/`菜单名`），不猜坐标、不编文案。
* 草稿里的 `effects` 留空并附 `_judgment`，**故意让 validate 不通过**——空缺必须由人来填，
  不许"看起来像张卡"就混过去（因此草稿放 .drafts/，不参与校验）。
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# 只读动词白名单：任务名以这些动词开头，才**可能**是只读。
# 不在名单里的一律当"需要人判定"（宁可保守）。
READ_VERBS = ("open", "query", "view", "preview", "list", "get", "show", "check",
              "login", "logout", "switch-tenant", "download", "export", "read")

READ_ACTION_WORDS = (("type", ("输入", "填写", "填入", "键入")),
                     ("click", ("点", "点击", "按", "选择", "选", "勾选", "展开", "打开")),
                     ("read", ("读", "查看", "核对", "确认", "等", "记录")))


def read(p: pathlib.Path) -> str:
    return p.read_text(encoding="utf-8")


def parse_title(text: str, stem: str) -> str:
    m = re.search(r"^#\s*任务[:：]\s*(.+)$", text, re.M)
    if m:
        return m.group(1).strip()
    m = re.search(r"^#\s*(.+)$", text, re.M)
    return m.group(1).strip() if m else stem


def parse_table(text: str, first_cell: str):
    """抓一个 markdown 表：表头的**第一格**必须等于 first_cell（不是"包含"）。

    为什么必须严格：实测 jenkins 的「前置条件」表里有一行提到 `#1~#3`，
    用"包含 #"去匹配会把前置条件表当成步骤表，于是步骤数为 0、选择器提不出来。
    """
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if not ln.strip().startswith("|"):
            continue
        first = ln.strip().strip("|").split("|")[0].strip()
        if first != first_cell:
            continue
        rows = []
        for ln2 in lines[i + 2:]:
            if not ln2.strip().startswith("|"):
                break
            cells = [c.strip() for c in ln2.strip().strip("|").split("|")]
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        return [ln], rows
    return None, []


def parse_params(text: str) -> list:
    _, rows = parse_table(text, "参数")
    out = []
    for cells in rows:
        if not cells:
            continue
        raw = cells[0]
        m = re.search(r"\$\{([A-Za-z0-9_]+)\}", raw)
        if not m:
            continue
        name = m.group(1)
        joined = " ".join(cells)
        required = ("必填" in joined) or ("用户提供" in joined)
        # 列布局有两种：参数|含义|来源|示例|必填  或  参数|含义|取值/来源  或  参数|来源|说明
        if len(cells) >= 5 and cells[4].strip() in ("是", "否", "必填", "可选"):
            desc = cells[1].strip()
            required = cells[4].strip() == "是"
            extra = f"来源：{cells[2].strip()}"
            if cells[3].strip():
                extra += f"；示例：{cells[3].strip().replace('`', '')}"
        elif len(cells) >= 3:
            desc = cells[1].strip() if len(cells) > 1 else ""
            extra = f"来源/取值：{cells[2].strip()}"
        else:
            desc, extra = (cells[1].strip() if len(cells) > 1 else ""), ""
        full = f"{desc}（{extra}）" if extra else desc
        out.append({"name": name, "desc": full.strip(), "required": required})
    return out


def parse_steps(text: str) -> list:
    _, rows = parse_table(text, "#")
    steps = []
    for cells in rows:
        if len(cells) < 3 or not cells[0].strip().isdigit():
            continue
        op = cells[1].strip()
        src = cells[2].strip() if len(cells) > 2 else ""
        expect = cells[3].strip() if len(cells) > 3 else ""
        steps.append({"n": int(cells[0].strip()), "do": op,
                      "input": src, "expect": expect})
    return steps


def parse_selectors(text: str, steps: list) -> dict:
    """只从**配方原文的引号**里提取语义定位，不编文案。

    过滤三类噪音（实测踩过）：
      * 纯符号（如菜单的 `⌄` 箭头）——不是可定位的语义文字；
      * `${...}` 参数占位符——那是入参，不是界面上的文字；
      * 同一段文字在同一格里重复出现。
    """
    entries, seen = [], set()
    for s in steps:
        # 语义文字可能出现在「操作」列，也可能在「动作细节 / 输入」列
        # （实测 jenkins 的元素名写在细节列的 `Build with Parameters` 里）
        haystack = f'{s["do"]} ｜ {s.get("input", "")}'
        quoted = re.findall(r"[「`\"']([^」`\"']{1,40})[」`\"']", haystack)
        for q in quoted:
            q = q.strip()
            if "${" in q or len(q) < 2:
                continue
            if not re.search(r"[0-9A-Za-z\u4e00-\u9fff]", q):
                continue          # 纯符号/箭头
            if re.search(r"[\[\]#]", q) or "=" in q:
                continue          # DOM/CSS 选择器（如 a[data-parameterized="true"]）不是语义文字
            if (s["n"], q) in seen:
                continue
            seen.add((s["n"], q))
            action = "click"
            for act, words in READ_ACTION_WORDS:
                if any(w in haystack for w in words):
                    action = act
                    break
            entries.append({"step": s["n"], "by": "text", "text": q,
                            "action": action, "confidence": "inferred",
                            "source": "从 tasks/<task>.md 步骤表引号内文字提取"})
    return {"page": "见同目录 <task>.md 的「前置条件」与步骤 1", "entries": entries,
            "waits": [], "_note": "本卡的选择器由配方机械提取（confidence=inferred），"
                                  "首次实跑后请按实测校正 by/action 并补 waits"}


def parse_side_effects(text: str) -> tuple:
    """返回 (是否明确只读, 原文摘要)。

    两种写法都认：
      * `## 副作用` 独立段（badge / iot 的写法）；
      * 内联 `**副作用**：无。**幂等**：可反复查。`（播控的写法）——必须**在下一条粗体字段处截断**，
        否则会把后面的「幂等 / 异常分支」整段吞进来，"无。"被淹没、判定失败。
    """
    m = re.search(r"^##\s*副作用\s*$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
    body = m.group(1) if m else ""
    if not body:
        m2 = re.search(r"\*\*副作用\*\*\s*[:：](.*?)(?=\*\*|\n\s*##|\Z)", text, re.S)
        body = m2.group(1) if m2 else ""
    flat = " ".join(body.split()).replace("**", "").replace("`", "")
    read_only = bool(re.search(
        r"^\s*(无|只读|纯只读)"
        r"|无\s*[（(]?\s*只读|无副作用|纯只读|只读[，,]?\s*无|不改(任何)?业务数据|不修改任何数据"
        r"|无业务数据变化|不改变任何业务数据|不会下发",
        flat))
    return read_only, flat[:180]


def name_is_read_verb(task: str) -> bool:
    return any(task == v or task.startswith(v + "-") for v in READ_VERBS)


def suggest(task: str, read_only_prose: bool) -> tuple:
    """脚本的建议（**不是**结论）：名字以只读动词开头 + 散文也说只读 → 建议只读；否则待判定。"""
    verb_ok = any(task == v or task.startswith(v + "-") for v in READ_VERBS)
    if verb_ok and read_only_prose:
        return "read", "任务名是只读动词 + 「副作用」段明确只读"
    if not verb_ok:
        return None, "任务名不是只读动词（可能是写操作）→ 必须人工判定"
    return None, "任务名像只读，但「副作用」段没有明确说只读 → 必须人工判定"


def build_card(skill: str, task: str, title: str, text: str, version: str) -> dict:
    params = parse_params(text)
    steps = parse_steps(text)
    sel = parse_selectors(text, steps)
    read_only, se_text = parse_side_effects(text)
    return {
        "_doc": "能力卡：job-runner 调用本任务的唯一接口。契约见 job-runner/references/job-format.md §5。",
        "_origin": f"由 learn-skill/scripts/scaffold_cards.py 从 tasks/{task}.md 派生"
                   f"（**未经编排实跑**）。首次实跑后请按实测更新 outputs/selectors，并把 evidenceLevel 升上去。",
        "card": "v2",
        "skill": skill,
        "task": task,
        "title": title,
        "version": version,
        "system": "",
        "channel": "playwright",
        "envClass": "unknown",
        "effects": "read",
        "evidenceLevel": "observed",
        "evidenceBasis": f"由 tasks/{task}.md（录屏学习所得）机械派生，尚未被 job-runner 实跑过一次。"
                         f"配方对副作用的原文：{se_text or '（配方未写副作用段）'}",
        "inputs": [{"name": p["name"], "type": "string", "required": p["required"],
                    "desc": p["desc"]} for p in params],
        "outputs": [
            {"name": "records", "path": f"artifacts/{task}/records.csv", "type": "csv",
             "desc": "统一只读产物约定：每读到一项写一行 step,item,value（第几步·读到什么·值是什么）。"
                     "首次实跑后请按本任务真正需要的字段细化"},
            {"name": "raw", "path": f"artifacts/{task}/raw.txt", "type": "txt",
             "desc": "页面/工具原文（原样保留，便于溯源与排障）"},
        ],
        "secretsRef": [],
        "_secrets_note": "本卡不写凭据值；登录所需凭据由用户在运行时提供（见 tasks/login.md）。",
        "selectors": sel,
        "automationBoundary": {
            "needsHuman": [],
            "notes": "本卡按「只读」判定生成，不产生业务数据变更。若实跑中发现它有写副作用，"
                     "必须立即把 effects 改为 write 并补 impact + readback（低报副作用会被 validate 拒绝）。",
        },
        "steps": [{"n": s["n"], "do": s["do"],
                   "expect": s["expect"] or "（配方未写预期反馈）"} for s in steps],
        "verify": [
            {"name": "not_empty", "path": f"artifacts/{task}/records.csv"},
            {"name": "columns_present", "path": f"artifacts/{task}/records.csv",
             "columns": ["step", "item", "value"]},
        ],
        "effectsDetail": {"changes": "无（只读判定，待实跑确认）", "outbound": "无",
                          "idempotent": "只读，可反复执行"},
        "evidence": {"frames": "见 tasks/" + task + ".md 的「证据」段", "assets": []},
        "unknowns": ["本卡为机械派生：选择器与产物字段未经实跑校正",
                     "任务名与「副作用」段之外，是否还有未记录的写副作用"],
        "updatedAt": "",
        "learnedBy": "learn-skill",
    }


def build_draft(card: dict, suggest_effects, why: str) -> dict:
    d = dict(card)
    d["effects"] = None
    d["_judgment"] = {
        "effects": suggest_effects,
        "why": why,
        "todo": ["判定 effects（read / write / outbound / irreversible）——脚本猜不出来，这是最危险的一个字段",
                 "若为写路径：补 evidenceLevel + impact（blastRadius/count/reversible）+ readback（只读任务 + expect 判据）",
                 "校正 selectors（by/action/waits）与 outputs（真正需要的字段）",
                 "填 system / envClass / 版本号，删除本 _judgment 块，再从 .drafts/ 移到 tasks/ 下"],
    }
    return d


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("skill_dir")
    ap.add_argument("--task", action="append", help="只处理这些任务（可多次）")
    ap.add_argument("--draft-all", action="store_true", help="给所有缺卡任务生成草稿到 tasks/.drafts/")
    ap.add_argument("--promote-read", help="把人工判定为只读的任务（逗号分隔）提升为正式卡")
    ap.add_argument("--justify", help="配方没明写『只读』时的依据（会记进卡片的 evidenceBasis，便于审计）")
    ap.add_argument("--force", action="store_true", help="覆盖已存在的卡/草稿")
    a = ap.parse_args(argv)

    base = pathlib.Path(a.skill_dir).expanduser()
    if not (base / "SKILL.md").is_file():
        print(f"ERR 不是技能目录（缺 SKILL.md）：{base}")
        return 1
    skill = base.name
    tasks_dir = base / "tasks"
    drafts_dir = tasks_dir / ".drafts"
    meta = {}
    mp = base / "state" / "meta.json"
    if mp.is_file():
        meta = json.loads(mp.read_text(encoding="utf-8"))
    version = str(meta.get("version") or "0.1.0")
    ch = (meta.get("channels") or {})
    channel = ch.get("preferred") or "playwright"
    envclass = meta.get("envClass") or "unknown"
    system = meta.get("system") or meta.get("title") or skill

    targets = []
    for p in sorted(tasks_dir.glob("*.md")):
        if p.name == "README.md":
            continue
        if a.task and p.stem not in a.task:
            continue
        if (tasks_dir / (p.stem + ".json")).is_file() and not a.force:
            continue   # 已经有卡
        targets.append(p)

    promote = {x.strip() for x in (a.promote_read or "").split(",") if x.strip()}
    if not (a.draft_all or promote):
        write_mode = False       # 只体检，不落任何文件
    else:
        write_mode = True
    made_cards, made_drafts, skipped = [], [], []
    for p in targets:
        text = read(p)
        title = parse_title(text, p.stem)
        card = build_card(skill, p.stem, title, text, version)
        card["system"] = system
        card["channel"] = channel
        card["envClass"] = envclass
        read_only, se_text = parse_side_effects(text)
        sug, why = suggest(p.stem, read_only)
        card["_origin"] += f"｜脚本建议：{sug or '待判定'}（{why}）"

        if not card["inputs"]:
            card["inputs"] = []
        if not card["selectors"]["entries"]:
            skipped.append((p.stem, "配方步骤表里没有引号内的语义文字 → 界面通道的卡不能没有 selectors"))
            continue

        if p.stem in promote:
            # ★ 安全闸：任务名不是只读动词 → **永远**不许提升为只读卡（哪怕给了 --justify）。
            #   把写路径标成 read = 绕过写闸门，是本系统里最危险的错误方向，所以这条是机械的、不可绕过的。
            if not name_is_read_verb(p.stem):
                skipped.append((p.stem, "任务名不是只读动词 → 拒绝提升为只读卡；"
                                        "写路径必须走实测补卡（补 impact + readback）"))
                continue
            if not read_only and not a.justify:
                skipped.append((p.stem, "配方没明确写『只读』，而没给 --justify 依据 → 拒绝；"
                                        "要么补依据，要么留成草稿"))
                continue
            if not write_mode:
                made_cards.append(p.stem)
                continue
            out = tasks_dir / (p.stem + ".json")
            if out.is_file() and not a.force:
                skipped.append((p.stem, "已有正式卡"))
                continue
            if not read_only and a.justify:
                card["_promotedWithOverride"] = {
                    "task": p.stem, "justification": a.justify,
                    "note": "配方的「副作用」段没有明确写只读，按人工依据提升为只读卡；"
                            "依据记在这里以备审计与将来复核",
                }
                card["evidenceBasis"] += f"｜人工依据（覆盖配方措辞）：{a.justify}"
            card["updatedAt"] = ""
            out.write_text(json.dumps(card, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            # 提升后清掉同名草稿，别留一份"看起来还没判定"的重复
            stale = drafts_dir / (p.stem + ".json")
            if stale.is_file():
                stale.unlink()
            made_cards.append(p.stem)
        else:
            if not write_mode:
                made_drafts.append((p.stem, sug, why))
                continue
            if not a.draft_all and p.stem not in promote:
                made_drafts.append((p.stem, sug, why))
                continue
            drafts_dir.mkdir(exist_ok=True)
            out = drafts_dir / (p.stem + ".json")
            if out.is_file() and not a.force:
                skipped.append((p.stem, "草稿已存在"))
                continue
            out.write_text(json.dumps(build_draft(card, sug, why), ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
            made_drafts.append((p.stem, sug, why))

    print(f"技能：{skill}（v{version}, 通道 {channel}, 环境 {envclass}）")
    if made_cards:
        print(f"\n✅ 生成正式卡 {len(made_cards)} 张（已人工判定为只读）：")
        for t in made_cards:
            print(f"   tasks/{t}.json")
    if made_drafts:
        print(f"\n📝 生成草稿 {len(made_drafts)} 份到 tasks/.drafts/（**待人工判定 effects**）：")
        for t, sug, why in made_drafts:
            print(f"   {t:38s} 建议={sug or '待判定'}  {why}")
    if skipped:
        print(f"\n⏭  跳过 {len(skipped)} 个：")
        for t, why in skipped:
            print(f"   {t:38s} {why}")
    if not (a.draft_all or a.promote_read or a.task):
        print("\n（未指定动作：加 --draft-all 生成草稿，或 --promote-read a,b 提升只读卡）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
