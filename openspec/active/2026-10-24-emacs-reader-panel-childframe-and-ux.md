# 阅读器面板改 childframe 覆盖承载 · 解释追问 · 复制回显

## 当前状态

- 阶段：Phase 2（Plan）· 进行中
- 已确认：方案 ✅（用户 2026-10-24 确认）、计划 ⏳（待确认）
- 独立审查：需修订（2 major / 8 minor）→ **已按审查意见修订**（M1 popper 功能处理、M2 H3 前置 T2a spike，及 m1–m8 全部吸收）
- 下一步：用户确认计划 → Phase 3 按 T0 → T1 → T2a → T2 → T3 → T4 → T5 → T6 → T7 → T8 实施

## 目标

1. **消除面板导致的阅读界面跳动**：outline 与 translate/explain 面板改 child frame 覆盖（右上角），不参与窗口树；显示、流式刷新、滚动全程阅读窗口像素尺寸零变化。
2. **面板尺寸固定、内容内部滚动**：宽高按父 frame 比例固定，流式增量默认开启，默认底部跟随。
3. **解释面板支持继续追问**：minibuffer 提问，messages 多轮上下文，面板追加「追问/回答」轮次。
4. **复制回显不含正文**：鼠标拖选后 echo area 只报行数与字数。
5. **不破坏既有能力**：批注列表保持窗口承载；非 GUI 环境整体回退窗口承载；旧 defcustom 保留可回退。

## 背景与根因

- 阅读器版面与窗口像素尺寸耦合：`seshat-reader--refit-window` 挂在 `window-size-change-functions` 上，窗口尺寸变化即重新适配、必要时重渲染（`emacs/tests/seshat-reader-resize-test.el` 80 例锁定该行为）。
- 现行面板经 `seshat-reader-sidebar--display-params` 用 `display-buffer-in-side-window`（左/右 side window）或底部窗口承载，必然压缩阅读窗口 → 触发 refit → 观感「跳动」。
- 根因不是「哪种分栏」而是「承载方式改变阅读窗口尺寸」，因此面板必须不参与窗口树，即 child frame 覆盖。
- 同一 buffer 上还挂着另外三条 buffer-local hook：`window-configuration-change-hook`（`--manage-window-overlays`）、`window-buffer-change-functions`（`--handle-window-buffer-change`）、`pre-redisplay-functions`（`--pre-redisplay-center`）。child frame 的创建/删除不改变父 frame 的窗口树与窗口尺寸，因此不应触发这四条 hook 中任何一条（T2a/T3 需实测确认；L3 的「阅读窗口像素尺寸零变化」为最终阻断判据）。

## 设计决策

### D1 承载层：carrier 分派，默认 childframe

在 `emacs/seshat-reader/seshat-reader-sidebar.el` 内新增承载分派（**不拆模块**：toggle/关闭/尺寸记忆/`--last-buffers` 状态高度共享，拆分会造成状态外泄或循环依赖）：

- `seshat-reader-panel-carrier`（defcustom，默认 `childframe`，可选 `window`）
- `seshat-reader-panel-carrier-alist`（defcustom，默认 `((annotations . window))`，per-kind 覆盖）
- 解析函数 `seshat-reader-sidebar--carrier-for-kind (kind)`：`display-graphic-p` 为 nil → 强制 `window`（child frame 只存在于 GUI）；否则 alist 命中优先，未命中取全局默认。
- 窗口后端（`seshat-reader-sidebar-position` / `seshat-reader-outline-sidebar-position` / 宽高变量 / slot / 尺寸记忆）**全部保留且语义不变**，仅在 carrier 为 `window` 时生效；`(setq seshat-reader-panel-carrier 'window)` 即完整回退到现状。

### D2 childframe 后端（同模块新增 `--cf-` 一节）

- 显示：`display-buffer` + `display-buffer-overriding-action` = `(display-buffer-in-child-frame . ALIST)`，`ALIST` 的 `child-frame-parameters` 至少含 `parent-frame`、`undecorated . t`、`no-other-frame . t`、`no-delete-other-frames . t`、`no-focus-on-map . t`、`internal-border-width`、`background-color`、`name`、以及本包标识 frame parameter `seshat-reader-panel-kind`。
- **不使用 `no-accept-focus`**：它会让点击也无法聚焦，导致面板不能滚动/复制；改用 `no-focus-on-map . t`（出现时不抢焦点，但可点击进入）。
- **幂等**：同 kind 的 child frame 已存在 → 只 `set-window-buffer` + 重新定位，不重建、不闪。
- 位置：父 frame 右上角，`seshat-reader-panel-margin`（默认 16px）作为右边距与上边距；坐标计算抽为纯函数（入参：父 frame 像素宽、面板像素宽高、margin、已存在面板的像素高度列表；出参：left/top 像素）以便 ERT 断言。
- **多面板防重叠**：同一时刻可能有多个 kind 的 child frame（outline + translate）。定位按已有本包 frame 在右边缘纵向堆叠：第一个贴右上角，后续每个的 top 下移「已存在 frame 高度 + margin」。
- 尺寸：像素宽 = 父 frame 像素宽 × `seshat-reader-panel-width`（默认 0.34），像素高 = 父 frame 像素高 × `seshat-reader-panel-height`（默认 0.45）；**打开即固定，全程不 resize**。
- 关闭：`delete-frame`（包 `ignore-errors`）；`q` 与 `seshat-reader-sidebar-toggle` 需支持「关当前 kind 的 frame」。
- 抽象升级：新增 `seshat-reader-sidebar--panels`，统一返回「承载单元」（window 或 frame），并提供 kind / buffer / close 的访问器；`--windows`、`--window-for-kind`、`--capture-state`、`--toggle-kind`、`--close-buffer-kind`、`seshat-reader-sidebar-toggle`、`seshat-reader-sidebar-display-buffer` 全部改为经该抽象工作。
- 生命周期：面板不自动消失；`seshat-reader-panel-hide-on-buffer-change`（默认 t）为真时，当前 buffer 不再是 `seshat-reader-mode` / `seshat-reading-mode` 派生模式则关闭本包 childframe 面板（内容仍留在 buffer，可 toggle 重开）。
- 父 frame 被删除时，其 child frame 由 Emacs 自动删除（预期行为，不做额外清理）。

### D3 固定尺寸 + 流式 + 底部跟随（`seshat-reader-translate.el`）

- `seshat-reader-translate-stream`（defcustom，默认 t）：为**克隆后的**引擎设置 `stream` 槽（不动用户预设对象）；引擎不支持 `stream` 槽时静默跳过（保持非流式）。
- 增量同步：把同步函数挂到 `gt-buffer-render-output-hook`（全局 hook），守卫为「`gt-buffer-render-translator` 的 `eq` 身份 + 本包 `--active` 时间窗」双重判定，避免捕获其它 gt 用法。
- **防跳变**：首个增量到达时先写最终模板骨架（原文引用块 + 分隔线 + 空正文占位），后续只替换正文 region（用 marker 记录起止）；完成时**不重写**面板，只更新 header-line 状态与历史记录。`stream` 为 nil 时退回现有「完成即整体渲染」路径。
- 滚动：内容超出即面板 window 内部滚动；`seshat-reader-panel-follow-bottom`（默认 t）为真时流式期间跟随底部（`set-window-point`），用户上滚即停止跟随，回到底部恢复跟随。
- 面板的 `header-line` 显示：`Seshat 译文` / `Seshat 解释` + 状态（`生成中…` / `已完成` / `追问 N`）。

### D4 追问：messages 多轮（不改 gt 源码）

- 命令 `seshat-reader-translate-follow-up`：minibuffer 读问题（`read-string "追问: "`）→ 面板追加 `### 追问 N`、`**问：**`、`**答：**` 占位 → 发起请求 → 增量/完整结果替换答案区。
- 多轮实现：`gt-chatgpt-send` 在 prompt 为**列表**时按 messages 数组发送；`gt-chatgpt-engine` 的 `gt-execute` 对**函数型** `prompt` 槽调用 `(pdd-funcall prompt (list item tgt))`。因此克隆预设 translator 的引擎，把 `prompt` 槽设为「返回 messages 列表的函数」即可，**不修改 gt 源码、不自行拼 JSON 请求**。
- messages 组装（抽为**纯函数**以便 ERT）：`system` = 引擎的 `root`；`user` = 原文 + 首轮解释请求；`assistant` = 首轮解释结果；随后按历史依次追加 `user`/`assistant`，最后追加本次追问（`user`）。
- 历史状态：buffer-local `seshat-reader-translate--follow-up-state`（原文、首轮答案、轮次列表、面板 buffer）；`seshat-reader-translate-follow-up-max-rounds`（defcustom，默认 6）超出时丢弃最早轮次（保留原文与首轮解释）。新翻译/新解释（`--render-panel` 重写）自动清空。
- 降级：预设引擎不是 `gt-chatgpt-engine` 实例时，退化为「历史拼成一段文本」的单轮请求，并在 header-line 标注「追问（单轮）」；不报错、不静默失真。
- 键位：`C-c C-q` 绑到 `seshat-reader-mode-map` 与 `seshat-reader-translate-panel-map`（`C-c C-a` 已被 `seshat-reader-annotation-create` 占用，不得复用）。

### D5 复制回显（`seshat-reader-select.el`）

- `seshat-reader-select--report` 改为只报告统计：`(message "Seshat Reader select: 已复制 %d 行 · %d 字")`；行数 = 换行符数 + 1，字数 = 字符数（CJK 按字符计）。
- 删除 `seshat-reader-select-message-limit` 常量与截断显示分支；空文本分支（`no text in the selected rectangle`）保持不变。
- 按用户要求去掉 `[C-c C-a 建批注]` 提示；计划记录「如需恢复，一行即可加回」。
- 微调 `seshat-reader-select-copy-to-kill-ring` 的 docstring 措辞：保留「同时报告在 echo area」语义，但明确报告内容是行数/字数统计而非正文。`kill-new` 行为不变（仍受该 defcustom 控制，默认 nil）。

## 假设与验证点

| # | 假设 | 来源 | 验证方式 | 不成立时的降级 |
|---|---|---|---|---|
| H1 | 窗口尺寸变化会触发阅读器 refit/重渲染 | 事实✓（源码 + 80 例 resize 测试） | 已确认 | — |
| H2 | `display-buffer-in-child-frame` 在 Emacs 31.1 可用，且 child frame 不进窗口树 | 事实✓（`M-x describe-function`） | 已确认 | — |
| H3 | pgtk 下 undecorated child frame 可正常显示、定位、设边框/背景，且创建/删除不改变父 frame 窗口尺寸、不触发上述四条 hook | 假设? | **T2a 前置 spike**（verify 实例 + GUI frame，5–10 分钟）通过后才进入 T2 实现 | 退回 posframe 或 window 承载（在投入实现成本前判定） |
| H4 | `gt-chatgpt-send` 在 prompt 为列表时按 messages 发送；函数型 prompt 会经 `pdd-funcall` 调用 | 事实✓（`gt-engine-chatgpt.el` 源码） | 已确认 | — |
| H5 | 预设 `gt-chatgpt-engine` 可 clone 并改 `prompt`/`root`/`stream` 槽而不污染预设单例 | 假设? | T5 单测（clone 后原预设槽不变） | 追问降级为文本拼接单轮 |
| H6 | 承载范围：仅 outline + translate 改 childframe，annotations 保持窗口；追问走 gt messages + minibuffer | 用户显式 | — | — |
| H7 | 跨 frame `select-window` 让 outline 的 `o`/`RET`/`f`/`s` 交互在 childframe 下仍可用 | 假设? | verify 实例实测 | outline 跳转改绑阅读器键位、面板只读 |
| H8 | 未聚焦 child frame 可被滚轮/点击聚焦滚动，且 `no-focus-on-map` 不干扰父 frame 焦点 | 假设? | verify 实例实测 | 在阅读器 map 增加「面板上滚/下滚」命令（不依赖焦点） |
| H9 | 固定尺寸 + 流式增量 + 底部跟随的观感可接受（无遮挡困扰、无抖动） | 假设? | 用户真机目视验收 | 提供 `seshat-reader-translate-stream` = nil 与 window 承载两种回退 |
| H10 | `gt-buffer-render-output-hook` 能稳定拿到本包 translator 的增量且不误捕；`seshat-reader-translate--active` 是全局非 buffer-local 变量，多文档并发翻译的时间窗边界沿用 `--capture-result` 既有语义（本计划不扩大范围） | 假设? | 单测（伪造外部 translator 应被拒） | 退回非流式（T4 开关） |

## 任务

### T0 安全点与基线（依赖：无）

- 计划文件处置：本计划文件目前是未跟踪文件。先 `git add openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md` 并提交（`docs: 新增阅读器面板 childframe 与追问计划`），使工作区干净，再做后续安全点。
- `git status` 确认工作区干净（若有**其它**未提交改动，先报告 harspower，不自行提交）。
- 创建 tag：`git tag pre-reader-panel-childframe`。
- 跑全仓 ERT 基线并记录到 `/tmp/baseline-ert-childframe.txt`（**逐文件**运行，23 个文件合计应 ≥ 773 例、0 unexpected、0 skipped）；命令按 `docs/emacs-reader.md` 「构建与测试」节（含 14 个 straight `-L` 路径，缺 `etaf/lisp` / `etaf-ui` / `ebox` / `ecss` 会假 skipped 或连锁失败）。
- 验收：tag 存在；基线数字被记录（文件行数与用例总数写进报告）。

### T1 承载分派骨架（依赖：T0）

- 文件：`emacs/seshat-reader/seshat-reader-sidebar.el`
- 新增 D1 列出的两个 defcustom 与解析函数；新增 `seshat-reader-sidebar--panels` 抽象与访问器（window 或 frame）。
- 验收：ERT 新增 ≥4 例——默认 kind 解析为 `childframe`、`annotations` 解析为 `window`、`display-graphic-p` 为 nil 时回退 `window`、未知 kind 走全局默认。

### T2a 可行性 spike：pgtk child frame（依赖：T1）

- 目的：在投入 `--cf-show` 实现前，用 5–10 分钟确认 H3，避免实现白做。
- 做法：`verify` 实例（`elisp_mcp_set_task verify`）+ 显式 `(make-frame '((window-system . pgtk)))`，用内置 `display-buffer-in-child-frame` 建一个 undecorated child frame，逐项验证：① 能显示；② 能定位到父 frame 右上角；③ 能设 `internal-border-width` / `background-color`；④ 创建与删除前后，父 frame 阅读窗口的 `window-pixel-width` / `window-pixel-height` 不变；⑤ 父 frame 的四条 buffer-local hook（`window-size-change-functions` / `window-configuration-change-hook` / `window-buffer-change-functions` / `pre-redisplay-functions`）触发计数不变。
- 收尾（不变量）：`elisp_mcp_set_task auto` → `elisp_mcp_instance(action=stop, instance=verify)` → `elisp_mcp_instance_status(instance=verify)` 确认。
- 验收：五项全部通过才进入 T2；任一项失败 → 立即回报 harspower，按风险表降级（posframe / window 承载），**不实现 T2**。

### T2 childframe 后端（依赖：T2a）

- 文件：同上。新增 `--cf-frames`、`--cf-frame-for-kind`、`--cf-parameters`（纯函数）、`--cf-position`（纯函数）、`--cf-size`（纯函数）、`--cf-show`、`--cf-close`。
- 验收：ERT ≥5 例——`--cf-parameters` 必含 `undecorated`/`no-other-frame`/`no-delete-other-frames`/`no-focus-on-map`/`seshat-reader-panel-kind` 且**不含** `no-accept-focus`；`--cf-position` 右上角与多面板纵向堆叠计算（给定父 frame 宽、面板宽高、margin、已存在面板高度列表）；`--cf-size` 比例换算；同 kind 幂等复用；关闭路径调用 `delete-frame`。批量测试不依赖真实 frame：用 `cl-letf` 桩替 `display-buffer` / `make-frame` 断言调用次数与参数，真实幂等、定位与视觉由 L3 验证。

### T3 承载接入与生命周期（依赖：T2）

- 文件：同上。`--display` 按 carrier 分派；`--toggle-kind` / `--close-buffer-kind` / `seshat-reader-sidebar-toggle` / `seshat-reader-sidebar-display-buffer` 经 `--panels` 工作；实现 `seshat-reader-panel-hide-on-buffer-change`。
- **不变量 1**：carrier 为 `window` 时全部既有 ERT 用例保持通过（旧行为不得回归）。
- **不变量 2（签名稳定）**：carrier 为 `window` 时 `--windows` / `--window-for-kind` / `--capture-state` / `--display` 的签名与返回形态（返回 window）保持不变——现有 sidebar-test 的 50+ 用例用 `cl-letf` 桩替这些内部函数，签名或返回形态变化会让桩替漂移失效。新抽象只允许加在 `--panels` 层，旧函数作为 window 后端的适配器保留。
- **范围确认**：`emacs/seshat-reader/seshat-reader-etaf.el`（批注列表渲染与 `seshat-reader-sidebar-toggle` 调用）保持 window 承载、不得改动；其 toggle 调用经 `--panels` 抽象后行为不变，须有回归断言。
- 验收：ERT ≥4 例——carrier=window 时仍走 `--display-params`；carrier=childframe 时走 `--cf-show`；toggle 关闭 frame；切到非阅读 buffer 触发隐藏。

### T3.5 真机反馈三项修复（依赖：T3）

用户真机验收后追加的三项修复：

1. **译文重复**：`reader` 预设含两个引擎（youdao + google），`seshat-reader-translate--extract-result`
   收集**全部** `gt-result` 片段并换行拼接，导致面板显示两份译文。修复：新增
   `seshat-reader-translate-engines-pick`（默认 `first`，可选 `last` / `all`），只取第一个
   **成功**片段；首个失败（error face）时顺延；`all` 保留旧行为供调试。`--panel-result`
   （面板）与 `--capture-result`（posframe）两条路径都经该函数，一并修复。
2. **childframe 去 mode-line**：面板窗口不再显示 mode-line（header-line 保留）。实现优先给
   child frame 的窗口设 window parameter `mode-line-format` 为 `none`；若本机不支持，
   回退为面板 buffer 的 buffer-local `mode-line-format` 置 nil。
3. **阅读器侧快捷关闭**：`C-c C-o` 绑到 `seshat-reader-sidebar-toggle`（无参：面板开着即全部
   关闭，关了就重开最近一个）；面板内 `q` 保留。

验收：ERT 覆盖三项（去重三取值、失败顺延、window parameter/modeline、键位绑定）；既有
translate/sidebar/outline/etaf 套件全绿。

### T3.6 面板内 `q` 关闭 childframe（依赖：T3.5）

用户要求「在弹出的界面中按 q 退出」。现状 `q` 的三种绑定不一致：translate 走无参
`seshat-reader-sidebar-toggle`（会连带关掉其它 kind）、outline 走 `quit-window`（对 child
frame 只删窗口、可能留下空 frame）、etaf 走 `seshat-reader-etaf-quit`（批注仍是窗口承载，
不动）。修复：新增统一命令 `seshat-reader-sidebar-quit` —— 按当前 buffer 名推断 kind，关闭
**该 kind** 的面板（frame → `delete-frame`、window → `delete-window`）；当前 buffer 不是面板
buffer 时退回「全部开合」旧语义。outline 的两处 `q`（mode-map 与 evil bindings）与 translate
面板的 `q` 改绑该命令；批注面板 `q` 保持不变。

验收：ERT 覆盖四分支（translate/outline 面板内关闭、非面板回退、frame 走 delete-frame）；
verify 实例 GUI 实测 childframe 内按 `q` 能真正关闭 frame。

### T4 流式渲染（依赖：T3）

- 文件：`emacs/seshat-reader/seshat-reader-translate.el`
- 新增 `seshat-reader-translate-stream`；克隆引擎设 `stream`；`gt-buffer-render-output-hook` 增量同步 + 双重守卫；模板骨架一次写入 + 正文 region 替换；完成不重写；底部跟随。
- 验收：ERT ≥5 例——外部 translator 的增量被拒（守卫）；骨架只写一次；增量只替换正文区（骨架区文本不变）；完成后 buffer 内容不被 erase 重写；`stream`=nil 时退回旧路径（`--render-panel` 整块渲染）。

### T5 追问（依赖：T4）

- 文件：同上。新增 `seshat-reader-translate-follow-up`、纯函数 `seshat-reader-translate--follow-up-messages`、buffer-local 历史状态、`seshat-reader-translate-follow-up-max-rounds`、降级分支、`C-c C-q` 键位（reader-mode + panel-mode）。
- 验收：ERT ≥6 例——messages 顺序与角色正确；超过轮次上限丢弃最早轮；非 `gt-chatgpt-engine` 引擎走文本拼接降级且标注；无面板/无原文时报 `user-error`；键位绑定正确（`lookup-key`）；clone 后预设槽未被污染（H5）。

### T6 outline 适配（依赖：T3）

- 文件：`emacs/seshat-reader/seshat-reader-outline.el`
- 关闭路径继续走 `seshat-reader-sidebar--toggle-kind`；`s`（回阅读窗口）与 `RET`（跳页）在 childframe 聚焦场景下可用；`o` 在面板内仍关闭。
- 调用点改造：`seshat-reader-outline-show` 里的 `--window-for-kind`（判断「面板是否已显示」，约 195/203/204 行）改为经 `--panels` 的 `--panel-for-kind`，使 childframe 承载时同样能判断已显示。
- 验收：ERT ≥2 例（关闭走 toggle-kind、无窗口时 `o` 打开）；verify 实例实测 H7。

### T7 复制回显（依赖：无，可与 T1–T6 并行）

- 文件：`emacs/seshat-reader/seshat-reader-select.el`
- 按 D5 改写 `seshat-reader-select--report`，删除 `seshat-reader-select-message-limit`，更新 docstring。
- 验收：ERT ≥3 例——单行/多行文本的行数与字数正确；回显**不含**正文片段；空文本仍报 `no text in the selected rectangle`。

### T8 验证、文档与归档（依赖：T0–T7）

- L1：`make -C emacs/seshat-reader all`（check-parens + byte-compile + checkdoc），警告集与基线逐条 diff，不得新增。
- L2：全仓 23 个测试文件逐文件 ERT，0 unexpected / 0 skipped，记录总数（≥ 基线 + 新增）。
- L3（`verify` 隔离实例 + **GUI frame**：daemon 的 selected-frame 是 terminal frame，须显式 `(make-frame '((window-system . pgtk)))`）：
  1. 打开 PDF，记录阅读窗口 `window-pixel-width` / `window-pixel-height`；按 `C-c C-t` 显示面板后两者**零变化**（核心不变量）。
  2. child frame 位于父 frame 右上角，宽高等于比例 × 父 frame 尺寸 ± margin，且是 `undecorated`。
  3. 流式期间面板内容增长，阅读窗口像素尺寸持续不变。
  4. `C-c C-q` 追问两轮，messages 顺序正确（可用纯函数断言 + 一次真实请求目视）。
  5. `q` 关闭后阅读窗口像素尺寸与打开前一致。
  6. 拖选复制：echo area 只显示「已复制 N 行 · M 字」。
- 文档：见「文档清单」，逐项落地并输出同步报告。
- 归档：勾选任务 → 计划移入 `openspec/completed/`。

## 文档清单

| 文档 | 更新内容 |
|---|---|
| `emacs/seshat-reader/seshat-reader-sidebar.el` Commentary | 说明本模块现在承载 window 与 childframe 两种后端、固定尺寸与滚动语义 |
| `emacs/seshat-reader/seshat-reader-translate.el` Commentary | 流式、模板骨架、追问 messages 与降级边界 |
| `docs/emacs-reader.md` | 面板承载（childframe/窗口）、尺寸固定与滚动、流式与追问用法、复制回显、验证命令 |
| `docs/configuration.md` | 新增 defcustom 全量清单（carrier / carrier-alist / width / height / margin / follow-bottom / hide-on-buffer-change / translate-stream / follow-up-max-rounds）；注：`seshat-reader-select-message-limit` 是模块内 defconst，本文件原本无该条目，只需代码删除 |
| `docs/adr/0005-reader-panel-carrier.md` | 新建 ADR：从 side window 转为 childframe 覆盖的决策与代价 |
| `openspec/decisions.md` | 三条决策：承载方式二次反转、流式+固定尺寸、复制回显改动 |
| `openspec/tech-debt.md` | 残余项：非 chatgpt 引擎追问降级、`no-focus-on-map` 下的滚轮/聚焦边界、childframe 在非 pgtk 后端未验证 |
| `openspec/active/roadmap.md` | 新增里程碑条目并记录完成状态 |
| `CHANGELOG.md` | 破坏性默认变更（面板承载）+ 新功能（追问、流式、固定尺寸）+ 复制回显 |
| `emacs/seshat-reader/VENDORED.md` | 记录自研文件的改动边界（sidebar / translate / select） |
| thomas-emacs 仓库 `lisp/init-reader.el` | 注释更新（承载 defcustom、popper 在 childframe 下不再生效的说明） |
| thomas-emacs 仓库 `lisp/init-window.el` | **功能改动**：从 popper 名单移除 `"\\*Seshat Sidebar\\*"`（childframe 承载后 popper 的 `C-'` toggle / `quit-window` 关闭路径对 frame 无效），保留 `"\\*Seshat Annotations\\*"`（批注仍是窗口承载）；`+popper-smart-popup-at-bottom` 的 seshat 分支补 childframe 守卫并加注释说明 |
| thomas-emacs 仓库 `AGENTS.md` | 若形成新不变量（「面板承载不得改变阅读窗口尺寸」）则登记并附机械检查说明 |

## 验证标准

- **L1**：`make -C emacs/seshat-reader all` 通过，check-parens 0 错，byte-compile 警告集与基线逐条 diff 无新增，checkdoc 0 告警。
- **L2**：全仓 ERT 逐文件运行 0 unexpected / 0 skipped；总数 ≥ 基线 773 + 本计划新增（预计 +25 以上）。
- **L3**：上节 6 项全部通过，其中第 1 项（阅读窗口像素尺寸零变化）为**阻断性不变量**，不通过即视为任务失败并回滚。
- **回归**：`(setq seshat-reader-panel-carrier 'window)` 下既有 sidebar/outline/translate ERT 全绿（旧承载可回退）。

## 注意事项

- **child frame 仅存在于 GUI**：`display-graphic-p` 为 nil 时必须回退 window 承载，不得报错；批量/终端环境下所有新用例要能跑（对 frame 相关纯函数做断言，不依赖真实 GUI）。
- **daemon 的 selected-frame 是 terminal frame**：L3 里必须显式 `(make-frame '((window-system . pgtk)))` 后再测 child frame，且不得使用 `make-frame-on-display ":0"`（X 依赖，本机不可用）。
- **sidebar 模块零第三方依赖**：新代码只允许用 Emacs 内置（`display-buffer-in-child-frame` 是 C 内置），不得 require posframe 或其它包；gt / markdown / visual-fill-column 的软依赖处理方式沿用现状。
- **不改 gt 源码、不改 C 模块、不改 `seshat-reading` 的 refit 机制、不改批注列表承载**。
- **HACK 注释规范**：凡绕过第三方公开接口的改动（如直改 frame parameter、hook 守卫）须加 `;; HACK: <改了什么 + 为什么>`；纯 `setq` 新 defcustom 不加。
- **测试必须逐文件运行**：一次加载全部测试文件会因 etaf-ui 可用性差异导致既有 3 例失败（既有基线特性，不是回归）。
- **破坏性默认变更**：面板承载默认从窗口改为 childframe，需在 CHANGELOG 与 decisions.md 明确写出回退写法 `(setq seshat-reader-panel-carrier 'window)`。
- **流式守卫不得放宽**：`gt-buffer-render-output-hook` 是全局 hook，守卫（translator 身份 + 时间窗）缺失会污染其它 gt 用法的结果。

## 风险与降级分支

| 风险 | 触发判据 | 降级动作 |
|---|---|---|
| pgtk 下 child frame 显示/定位异常（H3） | T2a spike 任一项失败（不显示 / 定位错 / 破坏父 frame 窗口尺寸 / 触发 hook） | 改走 posframe 承载（用户已有配置）并记录决策，不实现 T2 |
| 跨 frame 焦点不可用（H7） | outline 的 RET/`s` 在面板内失效 | outline 跳转改绑阅读器键位，面板降为只读展示 |
| 滚轮/点击无法进入 child frame（H8） | verify 实测滚轮无效 | 增加阅读器 map 的「面板上滚/下滚」命令 |
| 流式观感不可接受（H9） | 用户目视否决 | `seshat-reader-translate-stream` 设 nil（回退非流式）或 `seshat-reader-panel-carrier` 设 window |
| 增量捕获误伤其它 gt 用法（H10） | ERT 守卫用例失败 | 关闭流式（同上）并记 tech-debt |
