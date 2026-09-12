#!/usr/bin/env bash
# validate_skill.sh — 校验一个"学到的技能包"是否合格（结构 / frontmatter / 凭据泄漏 / 覆盖率）。
#
# 用法：
#   validate_skill.sh <技能目录 | 技能名>
#
# 退出码：0 = 通过（可能有警告）；1 = 有致命问题。
# 设计原则：结构问题算致命（技能会加载不了），内容问题算警告（由 agent 判断是否需要补学）。

set -uo pipefail

die() { printf 'validate_skill: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0;; esac

TARGET="$1"

resolve_skills_root() {
  if [ -n "${LEARN_SKILLS_ROOT:-}" ]; then printf '%s' "$LEARN_SKILLS_ROOT"; return; fi
  if [ -d "$HOME/.agent/skills" ]; then printf '%s' "$HOME/.agent/skills"; return; fi
  printf '%s' "$HOME/.agents/skills"
}

if [ -d "$TARGET" ]; then
  DIR="$(cd "$TARGET" && pwd)"
else
  CAND="$(resolve_skills_root)/$TARGET"
  [ -d "$CAND" ] || die "找不到技能目录：${TARGET}（也不是 $(resolve_skills_root) 下的技能名）"
  DIR="$(cd "$CAND" && pwd)"
fi

NAME_EXPECTED="$(basename "$DIR")"
ERRORS=0
WARNINGS=0

fail() { printf '  ✗ %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
warn() { printf '  ! %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
ok()   { printf '  ✓ %s\n' "$*"; }

printf 'validate_skill: %s\n' "$DIR"

# ---------- 1. 必需文件 ----------
printf '\n[1] 结构\n'
SKILL_MD="$DIR/SKILL.md"
[ -f "$SKILL_MD" ] || die "缺 SKILL.md（技能包必须包含 SKILL.md，否则不会被加载）"
ok "SKILL.md 存在"

for f in CHANGELOG.md state/meta.json; do
  if [ -f "$DIR/$f" ]; then ok "$f 存在"; else warn "缺 ${f}（建议补齐：$f 用于版本追溯）"; fi
done
[ -d "$DIR/pages" ] || warn "缺 pages/ 目录（页面知识放这里）"
[ -d "$DIR/tasks" ] || warn "缺 tasks/ 目录（任务配方放这里）"

# ---------- 2. frontmatter ----------
printf '\n[2] frontmatter\n'
FM="$(awk 'NR==1 && $0=="---"{inside=1; next} inside && $0=="---"{exit} inside{print}' "$SKILL_MD")"
if [ -z "$FM" ]; then
  fail "SKILL.md 开头缺少 YAML frontmatter（--- name: ... description: ... ---）"
else
  NAME_LINE="$(printf '%s\n' "$FM" | grep -E '^name:' | head -1 || true)"
  DESC_LINE="$(printf '%s\n' "$FM" | grep -E '^description:' | head -1 || true)"
  [ -n "$NAME_LINE" ] || fail "frontmatter 缺 name"
  [ -n "$DESC_LINE" ] || fail "frontmatter 缺 description"
  if [ -n "$NAME_LINE" ]; then
    NAME_VAL="$(printf '%s' "$NAME_LINE" | sed -E 's/^name:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')"
    case "$NAME_VAL" in
      *[!a-z0-9-]*|--*|-*|*--*) fail "name 必须是小写 kebab-case ASCII：$NAME_VAL";;
      *) ok "name = $NAME_VAL";;
    esac
    if [ "$NAME_VAL" != "$NAME_EXPECTED" ]; then
      warn "name（${NAME_VAL}）与目录名（${NAME_EXPECTED}）不一致，建议统一"
    fi
  fi
  if [ -n "$DESC_LINE" ]; then
    DESC_LEN="$(printf '%s' "$DESC_LINE" | wc -c | tr -d ' ')"
    [ "$DESC_LEN" -ge 30 ] && ok "description 长度合适（$DESC_LEN 字节）" \
      || warn "description 偏短（$DESC_LEN 字节），应写清「做什么 + 触发场景」"
  fi
fi

# ---------- 3. meta.json ----------
printf '\n[3] state/meta.json\n'
META="$DIR/state/meta.json"
if [ -f "$META" ]; then
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "$META" >/dev/null 2>&1; then
      ok "JSON 合法"
      python3 - "$META" <<'PY' || true
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
missing = [k for k in ("name", "version", "updatedAt", "unknowns") if k not in m]
if missing:
    print("  ! meta.json 缺字段: %s" % ", ".join(missing))
else:
    print("  ✓ 关键字段齐全（version=%s, unknowns=%d 条）" % (m.get("version"), len(m.get("unknowns") or [])))
PY
    else
      fail "meta.json 不是合法 JSON"
    fi
  else
    warn "没有 python3，跳过 JSON 校验"
  fi
fi

# ---------- 4. 覆盖率 ----------
printf '\n[4] 覆盖率\n'
count_files() { find "$1" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l | tr -d ' '; }
PAGES=0; TASKS=0
[ -d "$DIR/pages" ] && PAGES="$(count_files "$DIR/pages")"
[ -d "$DIR/tasks" ] && TASKS="$(count_files "$DIR/tasks")"
printf '  · pages: %s 个页面文件；tasks: %s 个任务文件\n' "$PAGES" "$TASKS"
[ "$PAGES" -ge 1 ] || warn "没有任何页面知识（pages/*.md）——技能会缺少"系统里有什么"的部分"
[ "$TASKS" -ge 1 ] || warn "没有任何任务配方（tasks/*.md）——技能无法直接执行"

TODO_COUNT="$(grep -rIl -E 'TODO|待补|待确认' "$DIR" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$TODO_COUNT" -gt 0 ] && printf '  · 有 %s 个文件仍含 TODO/待补标记（对未验证内容这是**好事**，但要在汇报里说明）\n' "$TODO_COUNT"

# ---------- 5. 凭据与敏感数据 ----------
printf '\n[5] 凭据 / 敏感数据\n'
SECRET_PATTERNS='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}|(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{3,}'
HITS="$(grep -rInE "$SECRET_PATTERNS" "$DIR" --include='*.md' --include='*.json' --include='*.txt' 2>/dev/null \
        | grep -viE 'TODO|待填|待补|xxx|<[^>]*>|\{\{|来源|placeholder|example' || true)"
if [ -n "$HITS" ]; then
  fail "疑似写入了凭据/密钥，必须移除（只保留"凭据来源"）:"
  printf '%s\n' "$HITS" | sed 's/^/      /' | head -20
else
  ok "未发现明显的凭据/密钥"
fi

PII="$(grep -rInE '[0-9]{17}[0-9Xx]|1[3-9][0-9]{9}' "$DIR" --include='*.md' 2>/dev/null \
        | grep -viE '示例|example|TODO|\{\{|xxxx' || true)"
if [ -n "$PII" ]; then
  warn "疑似真实手机号/身份证号，请确认是否为占位示例:"
  printf '%s\n' "$PII" | sed 's/^/      /' | head -10
fi

# ---------- 6. 硬编码具体值（泛化检查） ----------
printf '\n[6] 泛化检查（可疑硬编码）\n'
HARD="$(grep -rInE '\b(SO|PO|ORD|INV)[0-9]{6,}\b' "$DIR" --include='*.md' 2>/dev/null \
        | grep -viE '示例|example|参数|占位|\{\{|\$\{' || true)"
if [ -n "$HARD" ]; then
  warn "疑似把具体单号写死在技能里（应参数化为 \${...}）:"
  printf '%s\n' "$HARD" | sed 's/^/      /' | head -10
else
  ok "未发现明显的硬编码单号"
fi

# ---------- 汇总 ----------
printf '\n────────────────────────────\n'
if [ "$ERRORS" -gt 0 ]; then
  printf '结果：不通过 —— %d 个致命问题，%d 个警告\n' "$ERRORS" "$WARNINGS"
  exit 1
fi
printf '结果：通过 —— %d 个警告（警告项请自行判断是否需要补学/补齐）\n' "$WARNINGS"
exit 0
