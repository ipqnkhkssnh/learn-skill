# 技能包规范与自优化回写

学到的技能长什么样、放在哪、怎么被加载、用的时候怎么增量更新——都在这。

---

## 1. 存放位置与发现机制（决定了路径不能随便写）

DSH 扫描技能根目录，**只认一层深度**：

| 优先级 | 来源 | 路径 |
|---|---|---|
| 200 | 项目级 | `<projectRoot>/.agents/skills` |
| 500 | 用户级 | `$DSH_AGENTS_HOME/skills`，默认 `~/.agents/skills` |
| — | 自定义 | 部署配置里指定的目录 |

识别规则：

- **目录 bundle**：`<root>/<name>/SKILL.md`
- **平铺文件**：`<root>/<name>.md`
- **嵌套的 `**/SKILL.md` 故意不识别**（不要往里面再套一层）
- frontmatter 必填 `name`（必须是 **kebab-case**）与 `description`；可选 `whenToUse`、`metadata`、`disable-model-invocation`、`user-invocable`
- 目录被监视，新增/改名/删除**无需重启**即可被 agent 看到

**因此：**

- 学到的技能 → `~/.agents/skills/<skill-name>/SKILL.md`（DSH 扫描的规范路径）
- POSIX 上 `~/.agent` 通常是指向 `~/.agents` 的**符号链接**，两个路径是同一个目录：
  ```bash
  [ -e "$HOME/.agent" ] || ln -s "$HOME/.agents" "$HOME/.agent"   # 仅 macOS / Linux
  ```
  **Windows 不要建符号链接**（普通权限建不了，且 DSH 扫的是 `%USERPROFILE%\.agents\skills`）：
  用 `scripts/init_skill.ps1` / `scripts/install.ps1`，它们直接写规范路径。
- **抽帧缓存、原始录屏、证据截图**不要放进 `~/.agents/skills/` 根下的技能目录里，放：
  ```
  ~/.agents/skills/.learn-cache/<日期时间>-<录屏名>/
  ```
  以 `.` 开头的目录不会构成技能（没有 `<name>/SKILL.md` 结构），不会被当成技能误加载。

---

## 2. 目录结构

```
~/.agent/skills/<skill-name>/
├── SKILL.md              # 入口：frontmatter + 系统入口 + 前置条件 + 能力清单 + 索引
├── pages/                # 页面知识，每页一个 .md
│   ├── order-list.md
│   └── order-detail.md
├── tasks/                # 任务配方，每个任务一个 .md
│   ├── query-orders.md
│   └── view-order-detail.md
├── state/
│   └── meta.json         # 机器可读元数据：版本/来源/覆盖度/unknowns/使用统计
├── assets/               # 关键证据图（压缩过的少量图）
│   └── order-list-annotated.jpg
└── CHANGELOG.md          # 每次补学/修正追加一条
```

| 文件 | 职责 | 写作要点 |
|---|---|---|
| `SKILL.md` | 让人/模型**30 秒内知道这个技能能不能用、怎么开始** | 前置条件单独成节；能力清单标状态；索引指到具体文件 |
| `pages/*.md` | 回答"这个系统里有什么、每个页面能做什么" | 语义定位、字段/列/按钮、状态与反馈、副作用 |
| `tasks/*.md` | 回答"为了做成某件事，按什么顺序、带什么参数、看到什么算成功" | 参数化、每步预期反馈、失败分支、成功判据 |
| `state/meta.json` | 让工具与后续会话能程序化判断 | 版本、来源录屏、覆盖度、unknowns、使用统计 |
| `assets/` | 证据 | 只放能说明知识的关键图，别把整个抽帧目录搬进来 |
| `CHANGELOG.md` | 追溯"什么时候因为什么改了技能" | 倒序，最新在上；每条带证据与遗留问题 |

---

## 3. `SKILL.md` 规格

### 3.1 frontmatter

```yaml
---
name: erp-order-management              # 必填，kebab-case ASCII，与目录名一致
description: ERP 订单管理——在 ERP 中查询/查看/提交订单的能力（由 learn-skill 从录屏学习生成）…触发词：ERP、订单管理、查订单、提交订单。
whenToUse: 需要在 ERP 中查询订单、查看订单详情、提交订单时。
---
```

- `name` 决定调用键，**不要用中文**（中文放在 `title` 与正文里）。
- `description` 要同时写清 **做什么** 和 **什么场景触发**（触发词/近义说法都列上），否则未来会话里模型不会想起它。
- 可选 `metadata` 可放 `system`/`version` 等信息，但以 `state/meta.json` 为准。

### 3.2 正文章节顺序（固定，别随意改）

1. **系统入口与登录前置**（含"录屏外前置"——录屏开始前就已成立的）
2. **导航骨架**
3. **能力清单**（能力 / 状态 / 配方 / 备注）
4. **页面索引**
5. **任务索引**
6. **操作通道**（本技能的环境约束，如"只能内网访问，须 local-a2desk"）
7. **未知与待补（unknowns）**
8. **变更记录**（指向 CHANGELOG.md）

状态标记统一用：`✅ 录屏验证过` / `🟡 现场实测过` / `⚠️ 仅见入口` / `❌ 未知`。

---

## 4. `pages/*.md` 与 `tasks/*.md`

用 `templates/page.template.md` 与 `templates/task.template.md` 的骨架（`init_skill.sh` 会把它们放成 `pages/README.md`、`tasks/README.md` 供参考，正式写完后可以删掉）。

命名：

- 页面：`<模块>-<页面>.md`（`order-list.md`、`order-detail.md`）
- 任务：`<动词>-<宾语>.md`（`query-orders.md`、`submit-order.md`）

---

## 5. `state/meta.json` 字段

```json
{
  "name": "erp-order-management",
  "title": "ERP 订单管理",
  "system": "ERP",
  "version": "0.2.0",
  "origin": "learned-local",
  "createdAt": "2026-09-12",
  "updatedAt": "2026-09-13",
  "learnedBy": "learn-skill",
  "sourceRecordings": [
    {"path": "~/Desktop/erp-order.mov", "durationSeconds": 128, "learnedAt": "2026-09-12"}
  ],
  "environment": {
    "type": "unknown",
    "entry": "",
    "network": "",
    "writeOperationsAllowed": false
  },
  "coverage": {"pages": 2, "tasks": 2, "verifiedTasks": 2},
  "channels": {"preferred": "remote-a2desk", "fallback": ["local-a2desk", "playwright"]},
  "unknowns": [
    {"item": "提交订单流程", "reason": "仅见按钮未点击", "status": "needs-exploration"},
    {"item": "系统入口 URL", "reason": "录屏起始已登录", "status": "needs-user-input"}
  ],
  "usageCount": 3,
  "lastUsedAt": "2026-09-14T10:21:00Z"
}
```

`unknowns[].status` 取值：`needs-exploration`（需要真机点一遍）/ `needs-user-input`（要问用户）/ `blocked`（当前环境做不到）。
**补学完成后必须从 `unknowns` 里移除对应条目**，否则下次还会被当成未知。

---

## 6. 可选：技能登记表

`~/.agent/skills/learn-skill/state/registry.json` 用来快速回答"我学过哪些系统、各自覆盖到哪"：

```json
{
  "skills": [
    {
      "name": "erp-order-management",
      "title": "ERP 订单管理",
      "system": "ERP",
      "path": "~/.agent/skills/erp-order-management",
      "version": "0.2.0",
      "createdAt": "2026-09-12",
      "updatedAt": "2026-09-13",
      "sourceRecordings": ["~/Desktop/erp-order.mov"],
      "unknownCount": 2,
      "lastUsedAt": "2026-09-14T10:21:00Z"
    }
  ]
}
```

新建技能、或每次回写后**顺手更新一条**。模式 B 找不到"这次用的是哪个技能"时，先查这里。

---

## 7. 版本与 CHANGELOG 规则

| 变更 | 版本 |
|---|---|
| 新增一个任务配方或页面 | +0.1 |
| 纠正错误描述（界面变了/之前写错了） | +0.1 |
| 重大重构（系统升级、大部分流程重学） | +1.0 |

CHANGELOG 每条（倒序，最新在上）：

```markdown
## 2026-09-13 · v0.2.0 · 补学提交订单
- 触发场景：用户要求提交订单，技能里只有入口没有流程
- 新增：tasks/submit-order.md；pages/order-list.md 补充「提交订单」按钮行为
- 纠正：之前的「详情」按钮位置描述有误（在行尾，非行首）
- 仍未解决：批量提交、审批流
- 证据：assets/submit-order-confirm.jpg、evidence/20260913-1020-remote-a2desk-03-success.png
- 通道：remote-a2desk
```

---

## 8. 模式 B 回写算法（自优化闭环）

> 场景：用户要"提交订单"，但技能里只学过"查订单"。

### Step 1 · 定位正在使用的技能

优先级：当前会话正在读的技能包 → `state/registry.json` 里匹配系统/模块的条目 → 问用户。

### Step 2 · 读现状，列缺口清单

把技能包完整读一遍，明确写出**本次要用但技能里没有的**：

```
缺口：
1. 「提交订单」按钮点击后是什么表单？（技能里只有按钮存在的事实）
2. 需要填哪些字段？哪些必填？格式约束？
3. 有没有二次确认弹窗？文案是什么？
4. 成功后订单状态变成什么？
5. 需要什么权限？会不会触发下游（库存/财务）？
```

### Step 3 · 确认安全边界

涉及写操作（提交/审批/删除/支付/发货）时，**先向用户确认可以在当前环境实操**，并确认环境是测试还是生产。未获授权 → 只补只读部分，其余留在 `unknowns`。

### Step 4 · 边操作边记录

按 `references/execution-channels.md` 选通道，**每步先截图 → 操作 → 再截图**，同步填这张表：

| 步骤 | 实际动作（语义定位） | 输入/参数 | 系统反馈 | 截图文件 | 备注 |
|---|---|---|---|---|---|
| 1 | 列表页选中目标订单（行首复选框） | `${order_no}` | 行高亮，"提交订单"按钮由灰变亮 | evidence/xx-01.png | 未选中时按钮禁用 |

要额外抓的信息：

- **前置条件**：权限、数据状态（"只有待发货状态才能提交"）
- **校验规则**：试错一次看报错原文（如"收货电话格式错误"），原样记下来
- **副作用**：库存/状态/下游单据/通知

### Step 5 · 立即回写（别等下一个任务）

| 文件 | 改什么 |
|---|---|
| `tasks/<new>.md` | 新增任务配方（参数化、每步预期反馈、成功判据、副作用、异常分支） |
| `pages/*.md` | 补充/修正页面结构：新按钮的行为、前置条件、禁用规则 |
| `SKILL.md` | 能力清单状态更新（⚠️ → 🟡/✅）、任务索引加一行、unknowns 划掉 |
| `state/meta.json` | `version` +0.1、`updatedAt`、`coverage`、从 `unknowns` 移除已验证项、`usageCount`/`lastUsedAt` |
| `CHANGELOG.md` | 追加一条（按 §7 模板） |
| `state/registry.json`（learn-skill 的） | 更新对应条目 |
| `assets/` / evidence | 存关键证据图 |

### Step 6 · 矛盾以实测为准

实测与技能旧描述冲突时：**改旧描述**，并在 CHANGELOG 里标 `纠正`+原因（界面改版/之前理解错了）。**不要两份说法并存**——那会让下次执行时无从选择。

### Step 7 · 并发保护

同一技能可能被并行使用：回写前**重读文件**，只做增量合并（追加/替换特定段落），不要整文件覆盖。冲突无法自动判断时，保留两边内容并标注 `⚠️ 冲突待确认`。

### Step 8 · 校验与汇报

```bash
bash scripts/validate_skill.sh ~/.agent/skills/erp-order-management
```

汇报三件事：**补学了什么** / **还差什么（unknowns）** / **下次建议补什么**。

---

### 回写示例（提交订单）

```diff
# SKILL.md · 能力清单
- | 提交订单 | ⚠️ 仅见按钮，未点击 | — | needs-exploration |
+ | 提交订单 | 🟡 现场实测过 | tasks/submit-order.md | 需"订单提交"权限；仅待发货状态可提交 |

# SKILL.md · 未知与待补
- - [ ] 提交订单流程（按钮已见，未点击）
+ - [ ] 批量提交订单
+ - [ ] 提交后的审批流去向
```

```diff
# state/meta.json
- "version": "0.1.0",
+ "version": "0.2.0",
- "coverage": {"pages": 2, "tasks": 2, "verifiedTasks": 2},
+ "coverage": {"pages": 2, "tasks": 3, "verifiedTasks": 3},
- "unknowns": [{"item": "提交订单流程", "reason": "仅见按钮未点击", "status": "needs-exploration"}],
+ "unknowns": [{"item": "批量提交订单", "reason": "未探索", "status": "needs-exploration"}],
```

---

## 9. 哪些技能不该动

看 `state/meta.json` 的 `origin`：

| origin | 含义 | 回写策略 |
|---|---|---|
| `learned-local` | 本机学的，归你管 | 直接增量更新 |
| `imported` / `shared` / `git` | 来自他人或版本库 | **不要直接改**：产出补丁说明或复制成 `<name>-local` 副本，并告知用户 |
| 未知 | 说不清 | 视为 `shared`，先问用户 |

---

## 10. 落盘前质量门

- [ ] `validate_skill.sh` 通过（无致命问题）
- [ ] `name` kebab-case，与目录名一致；`description` 含做什么 + 触发词
- [ ] `SKILL.md` 八节齐全，前置条件（含录屏外前置）单独成节
- [ ] 每个任务参数化，无硬编码具体单号/手机号/身份证
- [ ] 无凭据、无密钥、无真实客户数据
- [ ] `unknowns` 如实列出，且每条有 `status`
- [ ] `CHANGELOG.md` 追加了本次变更，带证据与遗留
- [ ] 抽帧缓存没混进技能包目录
- [ ] 新人只看这个技能包能上手（最硬的一条）
