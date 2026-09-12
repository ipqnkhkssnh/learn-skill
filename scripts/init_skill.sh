#!/usr/bin/env bash
# init_skill.sh — 初始化一个"学到的技能"骨架（供 learn-skill 使用）。
#
# 用法：
#   init_skill.sh <skill-name> [--base-dir DIR] [--system "ERP"] [--title "ERP 订单管理"] [--force]
#
# 说明：
#   * skill-name 必须是小写 kebab-case ASCII（如 erp-order-management），中文只放在 --title。
#   * 默认写到 ~/.agent/skills/（DSH 扫描的用户技能根，等价于 ~/.agents/skills）。
#   * 已存在同名技能时默认拒绝，除非 --force。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

die() { printf 'init_skill: %s\n' "$*" >&2; exit 2; }
info() { printf 'init_skill: %s\n' "$*" >&2; }

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# 技能根目录：~/.agent/skills 优先（用户可见路径），其次 ~/.agents/skills（DSH 扫描根）。
resolve_skills_root() {
  if [ -n "${LEARN_SKILLS_ROOT:-}" ]; then printf '%s' "$LEARN_SKILLS_ROOT"; return; fi
  if [ -d "$HOME/.agent/skills" ]; then printf '%s' "$HOME/.agent/skills"; return; fi
  if [ -d "$HOME/.agents/skills" ]; then printf '%s' "$HOME/.agents/skills"; return; fi
  printf '%s' "$HOME/.agent/skills"
}

SKILL_NAME=""; BASE_DIR=""; SYSTEM=""; TITLE=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir) BASE_DIR="${2:-}"; shift 2;;
    --system)   SYSTEM="${2:-}";   shift 2;;
    --title)    TITLE="${2:-}";    shift 2;;
    --force)    FORCE=1;           shift;;
    -h|--help)  usage; exit 0;;
    -*)         die "未知选项: ${1}（-h 看用法）";;
    *)          [ -z "$SKILL_NAME" ] || die "只接受一个技能名"; SKILL_NAME="$1"; shift;;
  esac
done

[ -n "$SKILL_NAME" ] || { usage; exit 2; }
case "$SKILL_NAME" in
  *[!a-z0-9-]*|--*|-*|*--*|"") die "技能名必须是小写 kebab-case ASCII（字母/数字/单个连字符），例如 erp-order-management";;
esac

[ -n "$SYSTEM" ] || SYSTEM="$SKILL_NAME"
[ -n "$TITLE" ]  || TITLE="$SKILL_NAME"
[ -n "$BASE_DIR" ] || BASE_DIR="$(resolve_skills_root)"

DEST="$BASE_DIR/$SKILL_NAME"
if [ -e "$DEST" ] && [ "$FORCE" != 1 ]; then
  die "已存在：${DEST}（要覆盖请加 --force，或改用 learn-skill 模式 B 增量更新）"
fi

# 可写性预检：给出可操作的提示，而不是等中途失败
mkdir -p "$BASE_DIR" 2>/dev/null || true
if ! ( : > "$BASE_DIR/.write-test" ) 2>/dev/null; then
  die "技能根目录不可写：$BASE_DIR
  · 当前沙箱可能只允许写工作区（workspace-write）。请对这一步申请更宽的文件权限，或改用 --base-dir <可写目录>。
  · 若 $HOME/.agent 不存在，可先建立别名：ln -s \"$HOME/.agents\" \"$HOME/.agent\""
fi
rm -f "$BASE_DIR/.write-test"

TODAY="$(date +%Y-%m-%d)"

# sed 替换值转义（& | \ 需转义）
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
E_NAME="$(esc "$SKILL_NAME")"; E_TITLE="$(esc "$TITLE")"; E_SYSTEM="$(esc "$SYSTEM")"; E_DATE="$(esc "$TODAY")"

render() { # <模板> <目标>
  [ -f "$1" ] || die "缺少模板：$1"
  sed -e "s|{{SKILL_NAME}}|$E_NAME|g" \
      -e "s|{{TITLE}}|$E_TITLE|g" \
      -e "s|{{SYSTEM}}|$E_SYSTEM|g" \
      -e "s|{{DATE}}|$E_DATE|g" "$1" > "$2"
}

mkdir -p "$DEST/pages" "$DEST/tasks" "$DEST/state" "$DEST/assets"
render "$TEMPLATE_DIR/SKILL.template.md"    "$DEST/SKILL.md"
render "$TEMPLATE_DIR/meta.template.json"  "$DEST/state/meta.json"
render "$TEMPLATE_DIR/CHANGELOG.template.md" "$DEST/CHANGELOG.md"
cp "$TEMPLATE_DIR/page.template.md" "$DEST/pages/README.md"
cp "$TEMPLATE_DIR/task.template.md" "$DEST/tasks/README.md"

info "已创建技能骨架：$DEST"
cat >&2 <<EOF

下一步（learn-skill 模式 A 的 Step 5）：
  1. 先读 pages/README.md 与 tasks/README.md 了解格式，然后**删掉**它们（或保留作模板）；
  2. 把归纳结果写进 SKILL.md（入口/前置条件/能力清单/索引）、pages/*.md、tasks/*.md；
  3. 更新 state/meta.json（coverage、unknowns、sourceRecordings）与 CHANGELOG.md；
  4. 自检：bash "$SCRIPT_DIR/validate_skill.sh" "$DEST"
EOF
printf '%s\n' "$DEST"
