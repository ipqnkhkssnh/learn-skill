# learn-skill · 从录屏学技能

> 把「人怎么点」变成「**系统是什么、能做什么、怎么做**」，落成可复用技能；用的时候缺什么就补学什么，并自动回写。

`learn-skill` 是一个面向 Agent 的**技能生成器**：给它一段录屏，它抽帧后交给视觉模型逐帧理解，
把一次具体操作泛化成「系统地图 + 能力清单 + 任务配方」，写成新的 skill 包；之后执行该技能时
遇到没学过的分支（例如只录过「查订单」、这次要「提交订单」），还能边操作边补学、自动回写。

- **输入**：录屏 / 操作视频（或现场真机实操）
- **处理**：抽帧 → JPEG/base64 → 逐帧看图 + 可选 OCR → 归纳前置条件与目的
- **输出**：`~/.agents/skills/<skill-name>/` 技能包（DSH 自动发现，无需重启）
- **闭环**：执行中补学 → 增量回写 `tasks/` `pages/` `meta.json` `CHANGELOG.md`

---

## 它和「录屏转脚本」有什么不同

| | ❌ 录成脚本 | ✅ 学成技能 |
|---|---|---|
| 产物 | 一串点击坐标 + 固定单号 | 系统入口、页面能力清单、参数化任务配方 |
| 换台机器 | 分辨率一变就废 | 语义定位（菜单名/按钮文案）仍然有效 |
| 换个需求 | 重录一遍 | 已有知识 + 补学缺失分支 |
| 看不清的部分 | 猜着写进去 | 标 `unknowns` / `needs-exploration`，如实汇报 |

三条硬规则贯穿全程：**不臆造**（每句界面描述都要有帧证据或实测证据）、**学能力不学路径**（具体值全部参数化）、**凭据不入库**（只记录凭据来源）。

---

## 特性

- **抽帧一条命令**：按时间间隔取帧，32×32 签名去重 + 时间锚点 + 关键片段二次加密，产出 `frames/` + `manifest.json` + `index.md`。
- **三后端自动降级**：macOS 零依赖 Swift/AVFoundation → `ffmpeg` → Python+OpenCV，三者产物结构完全一致。
- **可选逐帧 OCR**：macOS Vision 把文字写进 manifest，与「看图」互为第二路证据（其他平台明确提示后忽略）。
- **JPEG → base64 批次**：`batches/*.json` 可直接塞进多模态消息，按 `index` 顺序分批喂，不让模型「总结式吞图」。
- **技能包脚手架**：`init_skill.sh/.ps1` 生成规范骨架，`validate_skill.sh/.ps1` 校验结构/frontmatter/凭据泄漏/覆盖率/泛化。
- **执行中自学习**：模式 B 把现场实测结果增量回写，`version` +0.1 并追加 `CHANGELOG.md`。
- **跨平台**：macOS / Linux 用 `.sh`，Windows 用 `.ps1`（不要求 bash），产物完全一致。

---

## 安装

### 1. 前置依赖（至少满足其一即可抽帧）

| 能力 | macOS | Linux | Windows |
|---|---|---|---|
| 抽帧（首选） | `swiftc`（Xcode Command Line Tools 自带，零依赖 + 支持 OCR） | — | — |
| 抽帧（通用） | `ffmpeg` | `ffmpeg`（`apt install ffmpeg`） | `winget install Gyan.FFmpeg` |
| 抽帧（兜底） | `python3` + `opencv-python` | 同左 | `python -m pip install opencv-python numpy` |
| base64 打包 | `python3`（标准库即可） | 同左 | 同左 |
| 脚本入口 | bash | bash | PowerShell 5.1+ |

### 2. 部署到技能根

技能根是 **`$DSH_AGENTS_HOME/skills`**，默认 **`~/.agents/skills`**（`~/.agent` 只是 POSIX 上的符号链接别名）。

**macOS / Linux**

```bash
git clone git@github.com:ipqnkhkssnh/learn-skill.git
mkdir -p "$HOME/.agents/skills"
cp -R learn-skill "$HOME/.agents/skills/"
```

**Windows（PowerShell，不要建符号链接）**

```powershell
git clone git@github.com:ipqnkhkssnh/learn-skill.git
pwsh -File learn-skill\scripts\install.ps1 -Force
```

安装后 DSH 自动发现（目录被监视），**新开一个会话**即可在技能目录里看到 `learn-skill`。
校验安装是否可用：

```bash
bash ~/.agents/skills/learn-skill/scripts/validate_skill.sh sunrise-badge-platform   # 校验任意已学技能
```

---

## 快速开始

### 模式 A · 从录屏学习

```bash
SKILL_DIR=~/.agents/skills/learn-skill
VIDEO=~/Desktop/erp-order.mov
OUT=~/.agents/skills/.learn-cache/$(date +%Y%m%d-%H%M%S)-erp

# 1) 抽帧（+ 打包 base64 批次）
bash "$SKILL_DIR/scripts/extract_frames.sh" "$VIDEO" "$OUT" \
     --interval 1 --max 300 --width 1280 --base64 --batch-size 20

# 2) 逐帧看图（对 frames/*.jpg 调用运行时看图能力，或喂 batches/*.json）→ 做时间轴笔记
# 3) 归纳：L1 系统层 / L2 页面层 / L3 任务层，前置条件单独成节，具体值全部参数化

# 4) 落盘技能包
bash "$SKILL_DIR/scripts/init_skill.sh" erp-order-management --system "ERP" --title "ERP 订单管理"
# 5) 填写 SKILL.md / pages/*.md / tasks/*.md / state/meta.json，然后自检
bash "$SKILL_DIR/scripts/validate_skill.sh" ~/.agents/skills/erp-order-management
```

Windows 等价命令（选项名完全相同）：

```powershell
$SkillDir = "$HOME\.agents\skills\learn-skill"
$Video = "$HOME\Desktop\erp-order.mov"
$Out = "$HOME\.agents\skills\.learn-cache\$(Get-Date -Format yyyyMMdd-HHmmss)-erp"
pwsh -File "$SkillDir\scripts\extract_frames.ps1" $Video $Out --interval 1 --max 300 --width 1280 --base64 --batch-size 20
pwsh -File "$SkillDir\scripts\init_skill.ps1" erp-order-management --system "ERP" --title "ERP 订单管理"
pwsh -File "$SkillDir\scripts\validate_skill.ps1" erp-order-management
```

采样密度、成本与 token 估算、二次加密、OCR 取舍见 [`references/frame-sampling.md`](references/frame-sampling.md)。

### 模式 B · 执行中补学回写

执行某个已学技能时，如果发现「只有入口、没有步骤」「界面与描述不符」「用户提了新场景」：

1. 读完整技能包，列出**本次要用但技能里没有**的点；
2. 写操作先确认环境（测试/生产）与授权，未授权就只补只读部分；
3. 按通道优先级选通道（`remote-a2desk` → `local-a2desk` → Playwright），**每步先截图 → 操作 → 再截图**；
4. 跑通后立即增量回写：`tasks/` `pages/` `SKILL.md` `state/meta.json`（`version` +0.1）`CHANGELOG.md`；
5. 与旧描述冲突时**以实测为准**，并标 `纠正`；最后跑 `validate_skill.*` 并汇报「补学了什么、还差什么」。

---

## 脚本参考

| 脚本 | 平台 | 作用 |
|---|---|---|
| `scripts/extract_frames.sh` | macOS / Linux | 抽帧统一入口：后端 `swift → ffmpeg → OpenCV` |
| `scripts/extract_frames.ps1` | Windows / PowerShell | 抽帧入口：后端 `ffmpeg → OpenCV`（选项与 `.sh` 同名） |
| `scripts/extract_frames.swift` | macOS | 零依赖抽帧后端（精确时间戳、画面去重、Vision OCR） |
| `scripts/extract_frames_cv2.py` | 跨平台 | Python+OpenCV 兜底后端 |
| `scripts/assemble_manifest.py` | 跨平台 | 为 ffmpeg 抽好的帧补 `manifest.json` / `index.md` |
| `scripts/frames_to_base64.py` | 跨平台 | 把帧打成 base64 批次喂多模态模型 |
| `scripts/init_skill.sh` / `.ps1` | 对应平台 | 初始化技能包骨架（`.sh` 与 `.ps1` 产物逐字节一致，UTF-8 无 BOM） |
| `scripts/validate_skill.sh` / `.ps1` | 对应平台 | 校验技能包（结构 / frontmatter / meta / 覆盖率 / 凭据 / 泛化） |
| `scripts/install.ps1` | Windows | 复制安装到 `~\.agents\skills`，不使用符号链接 |

### 抽帧常用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--interval SEC` | `1` | 采样间隔。`<60s` 用 `0.5`；`<10min` 用 `1`；更长用 `3~5`。帧数超 `--max` 时，Swift / OpenCV 后端会自动放大间隔保证全程覆盖（ffmpeg 后端仅提示） |
| `--max N` | `300` | 成本闸门：一遍最多喂多少帧（建议 60–300） |
| `--width W` | `1280` | 输出图最大宽度；小字密集的界面可上 `1600` |
| `--format` | `jpg` | `jpg` / `png` |
| `--threshold F` | `2.0` | 去重阈值（画面平均绝对差），调大保留更少 |
| `--min-gap SEC` | `30` | 即使画面不变也留一张时间锚点，`0` 关闭 |
| `--start` / `--end` | — | 时间段；配合 `--interval 0.25` 对关键片段二次加密 |
| `--ocr on` | `off` | **仅 macOS**（Vision）逐帧 OCR；其他后端提示后忽略 |
| `--base64` / `--batch-size N` | `20` | 抽完直接打包 base64 批次 |

---

## 平台支持

| 能力 | macOS | Linux | Windows |
|---|---|---|---|
| 抽帧 | ✅ swift / ffmpeg / OpenCV | ✅ ffmpeg / OpenCV | ✅ ffmpeg / OpenCV（`.ps1`） |
| 逐帧 OCR | ✅ Vision | ❌ → 用 tesseract / paddleocr 单独跑 | ❌ → 同上 |
| 初始化 / 校验技能包 | ✅ `.sh` | ✅ `.sh` | ✅ `.ps1` |
| base64 打包 | ✅ | ✅ | ✅（需 Python） |
| 操作通道 | a2desk ✅ / Playwright ✅ | a2desk ✅ X11（Wayland 尽力而为） | a2desk ✅ / Playwright ✅ |

技能根解析顺序（`.sh` 与 `.ps1` 完全一致）：

```
LEARN_SKILLS_ROOT → DSH_AGENTS_HOME/skills → 已存在的 ~/.agents/skills
                  → 已存在的 ~/.agent/skills → ~/.agents/skills
```

> Windows 上**不要**建 `~/.agent` 符号链接——普通权限建不了，且 DSH 扫的是 `%USERPROFILE%\.agents\skills`。
> 在 Git Bash / WSL 里跑 `.sh` 时，请显式设 `LEARN_SKILLS_ROOT="$HOME/.agents/skills"`。

---

## 产物结构

抽帧产物（三种后端一致）：

```
<输出目录>/
├── frames/frame_00001.jpg ...   # 按画面相似度去重后的帧
├── manifest.json                # 序号 / 时间戳 / 尺寸 / 差异值 / 可选 OCR 文本
├── index.md                     # 给人看的时间轴索引表
└── batches/batch_0001.json ...  # --base64 时的投喂批次（含 base64 / token 估算）
```

学到的技能包：

```
~/.agents/skills/<skill-name>/
├── SKILL.md          # 入口：frontmatter + 系统入口 + 前置条件 + 能力清单 + 任务索引
├── pages/            # 页面知识：每页一个文件（有什么、能做什么、怎么到达）
├── tasks/            # 任务配方：参数化步骤 + 验证点 + 异常分支
├── state/meta.json   # 机器可读元数据：版本 / 来源录屏 / 覆盖度 / unknowns / 使用统计
├── assets/           # 关键截图证据（压缩过的少量图）
└── CHANGELOG.md      # 每次补学 / 纠正追加一条
```

抽帧缓存、原始录屏、过程证据**不要**放进技能包，统一放 `~/.agents/skills/.learn-cache/`（以 `.` 开头，不会被当成技能加载）。

---

## 本仓库布局

```
learn-skill/
├── SKILL.md           # 运行期入口（Agent 加载的就是它）
├── references/        # 深度学习手册
│   ├── analysis-playbook.md    # 怎么从帧里读出前置条件与目的、怎么泛化（含完整 ERP 示例）
│   ├── frame-sampling.md       # 采样密度、成本估算、二次加密、OCR、base64 投喂
│   ├── execution-channels.md   # a2desk / Playwright 的正确用法与降级策略
│   └── skill-format.md         # 技能包格式、模板、版本与回写合并算法
├── scripts/           # 抽帧 / 脚手架 / 校验 / 安装（.sh + .ps1 + .py + .swift）
├── templates/         # 技能包模板（SKILL / page / task / meta / CHANGELOG）
└── README.md          # 本文件（给人看；Agent 运行期读 SKILL.md）
```

---

## 常见问题

**Q：Windows 上能用吗？**
能。用 `scripts/*.ps1`（不需要 bash，PowerShell 5.1+），后端为 `ffmpeg → OpenCV`。唯一的平台差异是**没有 OCR**（Vision 是 macOS 专属），脚本会明确提示后忽略，需要逐字文案时用 `tesseract frames/frame_00001.jpg stdout -l chi_sim+eng` 之类的工具补。

**Q：抽完帧没有 `manifest.json` / `index.md`？**
ffmpeg 后端依赖 `python3` 生成这两个文件；没有 Python 时脚本会在 `index.md` 里写明「仅输出图片」。装上 Python 即可，或改用 OpenCV 后端。

**Q：`--ocr on` 没反应？**
非 macOS 平台没有 OCR 实现。`.sh` 走 ffmpeg/OpenCV 时会打印「已按 --ocr off 继续」，`.ps1` 同理——不会报错，也不会静默丢弃。

**Q：技能写了，但 DSH 看不到？**
三个最常见原因：① 路径不是 `~/.agents/skills/<name>/SKILL.md`（DSH **只认一层深度**，`**/SKILL.md` 不识别）；② Windows 上写进了 `~/.agent/skills`（不存在的别名）；③ `SKILL.md` 的 frontmatter 缺 `name`（必须 kebab-case）或 `description`。跑一遍 `validate_skill.*` 即可定位。

**Q：帧太多 / 关键操作被漏掉？**
先在 `manifest.json` 看 `diff` 分布：有意义的操作节点一般 `diff > 5`。保留太多 → 调大 `--threshold` 或调大 `--interval`；漏了关键帧 → 调小 `--interval`，或用 `--start/--end --interval 0.25 --width 1600` 对那一段二次加密。

**Q：会把我机器上的鼠标键盘抢走吗？**
只有降级到 `local-a2desk` 时才会（会先告知并尽量缩短占用）。默认优先 `remote-a2desk`：远程 Linux VM + 虚拟桌面，隔离且可快照；网页类任务则优先 Playwright（不占桌面）。

---

## 更多文档

- 运行期完整工作流与铁律：[`SKILL.md`](SKILL.md)
- 理解与泛化方法（含完整 ERP 示例）：[`references/analysis-playbook.md`](references/analysis-playbook.md)
- 抽帧与投喂细节：[`references/frame-sampling.md`](references/frame-sampling.md)
- 操作通道与降级模板：[`references/execution-channels.md`](references/execution-channels.md)
- 技能包规范与回写算法：[`references/skill-format.md`](references/skill-format.md)

## 许可

[MIT](LICENSE) © 2026 ipqnkhkssnh
