# 操作通道：remote-a2desk / local-a2desk / Playwright

学习（模式 A）时这个文档用来**验证录屏里的操作**；补学与执行（模式 B）时用来**真机操作**。

---

## 0. 选择原则

| 优先级 | 通道 | 工具名前缀 | 什么时候用 |
|---|---|---|---|
| 1 | **remote-a2desk** | `mcp__remote-a2desk__*` | 默认首选。远程 Linux VM + 虚拟桌面，隔离、不打扰用户本机、可快照/可重放 |
| 2 | **local-a2desk** | `mcp__local-a2desk__*` | 远程不可用，或目标系统只能在本人本机访问 |
| 3 | **Playwright MCP** | `mcp__playwright__*`（或同类命名） | 目标是**浏览器里的网页**、且必须在本机操作 |

**为什么远程优先**：不占用用户鼠标键盘；环境可控可快照；可以放开手试错；网络/系统环境与生产隔离。只有在远程确实够不到目标系统时才降级。

**降级必须说明理由**，并在汇报里写清。禁止默默换成 local-a2desk。

---

## 1. 探测与就绪检查

MCP 工具在会话里的命名是 `mcp__<serverName>__<toolName>`（`serverName` 即配置里的 `remote-a2desk` / `local-a2desk` / `playwright`）。所以：

1. 看当前可用工具列表里有没有 `mcp__remote-a2desk__*`。
2. 有 → 做一次**就绪检查**（不要直接开始操作）：
   - `list_screens`：能列出屏幕与分辨率？
   - `screenshot`（小图，如 `max_width: 640`）：返回的是**真实画面**而不是全黑/全白/超时？
   - 目标系统在远程**可达且已就绪**（网络能打开、已登录到操作起点）？
3. 任何一项失败 → 记下失败原因，降级到下一通道，并**明确告知用户**。
4. 都不可用 → 停下来问用户，不要硬凑。

**远程不可用的典型信号：** 工具不存在（未配置 MCP）；连接报错/反复重连；`screenshot` 超时或纯黑；远程 VM 没有桌面会话（无 DISPLAY）；目标系统在内网/VPN 而 VM 进不去；VM 未开机。

---

## 2. a2desk 通用用法（remote 与 local 完全相同）

### 2.1 工具速查

| 工具 | 用途 | 关键参数 |
|---|---|---|
| `list_screens` | 屏幕分辨率/位置/缩放/主屏标记 | — |
| `screenshot` | 截屏（返回图片） | `screen`、`region{x,y,width,height}`、`scale`、`max_width`、`format`、`quality` |
| `mouse_move` | 移动鼠标 | `screen`、`x`、`y`、`duration_ms` |
| `mouse_click` | 点击 | `screen`、`x`、`y`、`button`、`count`(1 单击 / 2 双击) |
| `mouse_double_click` | 双击 | `screen`、`x`、`y` |
| `mouse_drag` | 拖拽 | `from_*`、`to_*`、`button`、`duration_ms` |
| `mouse_scroll` | 滚轮 | `screen`、`x`、`y`(可先移过去)、`direction`、`amount`(**1–100**) |
| `mouse_position` | 当前鼠标位置 | — |
| `keyboard_type` | 输入文本（支持 Unicode/中文） | `text`、`interval_ms` |
| `keyboard_press` | 按键/组合键 | `keys`（`["Enter"]`、`["ctrl+shift+s"]`）、`repeat` |
| `keyboard_key_down/up` | 长按/组合键 | `keys`，`["all"]` 松开全部 |
| `list_apps` | 运行中的应用与窗口 | `filter`、`only_with_windows` 等 |

### 2.2 坐标：一套坐标，别换算错

```
list_screens   → 该屏幕在虚拟桌面中的位置与尺寸
鼠标工具/region → 屏幕内局部坐标（相对该屏幕左上角 0,0）
screenshot(scale=1.0) → 1 图片像素 = 1 屏幕坐标单位
```

**标准流程（推荐）：**

1. `list_screens` 拿屏幕索引（`0` 通常是主屏）。
2. `screenshot`（**scale=1.0**，记下返回的 `pixel_ratio`）→ 在图上量像素坐标。
3. 把量到的 `(x, y)` **原样**填进 `mouse_click` 的 `x`/`y`，不做换算。

如果传了 `max_width` 或 `scale != 1.0`，必须换算：

```
屏幕坐标X = region.x + 图片X / pixel_ratio
屏幕坐标Y = region.y + 图片Y / pixel_ratio
```

其它要点：

- `screen` 可传索引（`"0"`）、名称关键字（`"DELL"`）、或 `"primary"`；省略 = 主屏。
- macOS 坐标单位是**逻辑点**（Retina 1 点 = 2 像素）；Windows/Linux 是**物理像素**。
- 坐标越界不会报错，会被裁剪到屏幕边缘并返回 `"clamped": true`——看到它说明你算错了。
- **点击前先移动再点击是有代价的**：a2desk 内部做了"移动后等位置同步再点击"的处理（最长 400ms）。所以**优先直接给 `mouse_click` 传 `x`/`y`**，不要自己先 `mouse_move` 再裸点。

### 2.3 操作循环（每一步都照这个来）

```
① 截图（确认当前状态 == 这一步的前置条件；不满足先补齐，比如先登录）
② 定位（在截图上找到目标元素的坐标或语义位置）
③ 操作（点击 / 输入 / 滚动 / 按键）
④ 再截图（确认反馈 == 预期）
   不符 → 判定是"操作没生效"还是"状态不同"，重试或走异常分支
```

**禁止盲连击**（一连串操作中间不验证）——GUI 操作最贵的错误就是把数据改错了还不知道。

细节纪律：

- **输入前先点击输入框**让它获得焦点；中文/特殊字符用 `keyboard_type`（支持 Unicode），别用按键模拟拼。
- **滚动**：`mouse_scroll` 的 `amount` 是 1–100；滚完等 300–500ms 再截图，否则截到滚动动画中间态。
- **弹窗/遮罩**：出现弹窗后先截图看清按钮文案再点，避免点到"删除"。
- **等待**：界面加载要靠"截图看到内容出现"来确认，不要用固定 sleep 硬等（慢的时候会截到空白）。
- **失败重试**：同一动作最多重试 2 次；连续失败就停下来重看截图，别重复点击同一个位置的按钮（可能已经点进去了）。

### 2.4 local-a2desk 的额外规矩

本机通道会**真的抢走用户的鼠标键盘**：

1. 开始前**告知用户**："接下来我会操作你本机的鼠标键盘，约 N 分钟，期间请不要动鼠标。"
2. 尽量缩短占用；能只读就不要写。
3. 结束后把鼠标移开关键区域，必要时用 `list_apps` 确认没有残留窗口。
4. macOS 权限：需要给**运行 a2desk 的进程**（终端 / MCP 客户端本体）授"屏幕录制"+"辅助功能"；**授权后必须重启该进程**才生效（TCC 在进程内缓存判定）。
5. 接入前可跑自检：`a2desk --selftest`；以及无副作用的输入冒烟 `python3 scripts/input-smoke.py`（会移动鼠标并精确还原，只按一下 Shift）。
6. Linux 桌面需要 X11 且 `DISPLAY` 可用；Wayland 下截屏与输入模拟是"尽力而为"，失败就换通道。

---

## 3. Playwright（浏览器 + 本机）

**什么时候用**：目标功能在网页里，而且**必须在本机**（例如只能在本人浏览器登录态/本机网络下访问）。这种情况 Playwright 通常比 a2desk 更稳：DOM 级定位、可断言、可等待、不抢鼠标。

**优先级**：无头（headless）优先；只有需要确认真实渲染/布局时才用 headed。

**定位策略（从稳到不稳）**：

1. `get_by_role` + 可访问名（按钮/链接/表格）
2. `get_by_label` / `get_by_placeholder`（表单字段）
3. `get_by_text`（可见文案）
4. CSS / XPath（前面的都不行时）
5. **坐标点击**（`page.mouse.click`）——最后手段，仅用于 Canvas/自绘控件

**等待纪律**：用"等元素可见/等文本出现/等网络空闲"，不要 `waitForTimeout` 硬等。提交类操作后要等**要么出现成功提示、要么出现错误提示**，两者都超时才判失败。

**证据**：每个关键步骤 `screenshot` 存证（命名见 §4），并把关键文本（状态字段、成功提示）记录下来作为断言来源。

**与 a2desk 的分工**：如果目标系统是网页但要求"在真实桌面上操作"（例如需要验证客户端渲染、证书、插件），仍走 a2desk；如果只是"打开网页做事"，Playwright 更快更稳。

---

## 4. 证据留存规范

学到的东西要能追溯，操作过程必须留证：

```
<技能包>/assets/            # 只放"能说明技能知识"的关键图，压缩过
  order-list-annotated.jpg  # 带标注的页面结构图
  submit-order-success.jpg  # 关键操作的实测结果

<缓存目录>/evidence/        # 过程证据（不必进技能包）
  20260912-143012-remote-a2desk-01-list.png
  20260912-143015-remote-a2desk-02-submit-confirm.png
```

命名建议：`<日期时间>-<通道>-<序号>-<步骤语义>.<ext>`。写进 `tasks/*.md` 和 `CHANGELOG.md` 时引用这些文件名。

**远程通道的截图要落盘**：MCP 返回的图片不落盘就没了，关键节点必须显式保存，否则回写技能时拿不出证据。

---

## 5. 通道降级说明模板

降级到 local-a2desk 或 Playwright 时，在给用户的汇报里写清：

```
操作通道：local-a2desk（降级）
降级原因：remote-a2desk 未在本会话配置（工具列表中无 mcp__remote-a2desk__*）
影响：会占用你本机鼠标键盘约 N 分钟；如不希望，可先配置远程通道，我改在远程执行
备选：若该功能在浏览器内可用，也可改用 Playwright（不占用桌面）
```

---

## 6. 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 工具列表里没有 `mcp__remote-a2desk__*` | MCP 未配置 / 服务名不是 `remote-a2desk` | 检查客户端 MCP 配置；确认 `serverName` |
| `screenshot` 全黑 | 远程无桌面会话 / 锁屏 / 权限缺失 / 硬件加速截屏失败 | 远程检查 DISPLAY 与会话；本机检查屏幕录制权限并重启进程 |
| 点击没反应 | 坐标算错（Retina/pixel_ratio）；元素被遮挡；窗口未聚焦 | 重新截图确认 `scale=1.0`；先点空白处聚焦窗口；核对 `clamped` |
| 输入文字丢失/乱码 | 未先聚焦输入框；输入法干扰 | 先点击输入框；用 `keyboard_type`（Unicode）而非按键拼写 |
| 滚动没效果 | 焦点不在可滚动区域 | 先点击列表/页面主体再滚动 |
| 画面与预期完全不同 | 远程环境不是录屏时的环境 / 未登录 / 数据不同 | 先对齐前置条件（§录屏外前置），再操作 |
| Playwright 找不到元素 | 页面未加载完 / 元素在 iframe / 动态 id | 等待可见；切 frame；改用 role/text 定位 |
