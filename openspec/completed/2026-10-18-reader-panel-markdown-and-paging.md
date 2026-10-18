# 阅读器面板渲染重构：译文/解释改 Markdown 文本 buffer + 批注分页（M11.10）

## 当前状态

- 阶段：Phase 4（Review & Document）· 实施完成（T0–T7），代码审查与 L3 手工验证进行中
- 已确认：方案 ✅（B1「面板内 Markdown 文本 buffer，ETAF 只保留批注卡片」；用户 2026-10-18 确认）
- 已确认参数：批注每页 20 条、翻页键 `]`/`[`、面板自适应高度上限 0.8×frame、原文区默认不显示
- 下一步：① code-reviewer 审查结论处理 → ② 用户 GUI 实测 L3 六项 → ③ 全部通过后计划归档到 openspec/completed/

## 目标

1. 译文/解释在底部面板中以 **Markdown 文本 buffer** 完整展示（原生滚动、折行、复制、isearch），不再受 ETAF 固定 20 行画布限制。
2. 去掉与阅读无关的噪声：`来源：第 N 页` 行、自绘 `q 关闭` 提示。
3. 面板高度随内容自适应（上限 0.8 × frame 高度），内容超出才滚动。
4. 批注列表改为**分页**：每页 20 条，`]`/`[` 翻页，标题显示「第 x/y 页」。
5. ETAF 渲染层职责收敛为「批注卡片列表」；译文/解释不再依赖 ETAF。

## 设计

### 现状（已核对的代码事实）

- `seshat-reader-etaf.el` 的 `seshat-reader-etaf-render-annotations` / `render-translate` 挂载时传固定 `:viewport-height seshat-reader-etaf--default-viewport-height`（20）与像素宽度；ebox 的 `ebox--measure-viewport` 在 fixed-vh 非 nil 时不跟随窗口，故窗口 resize 不重排。
- 译文视图 `seshat-reader-etaf--translate-view` 把每个 Markdown 段落塞进一个 `text` 节点，不做 Markdown 解析。
- 译文视图含结构化 `来源：第 N 页`（`seshat-reader-etaf--selection-origin`）与底部 `q 关闭` 提示。
- `seshat-reader-etaf--annotations-view` 的列表为固定 `(lh 12)` + `:overflow 'scroll`，无分页。
- `seshat-reader-translate--gt-buffer-text` 取不到 `gt-result` 片段时回退整个 gt buffer 文本（会把引擎区块带进正文）。
- `seshat-reader-translate--capture-result-sidebar` 依赖 buffer 名 `*Seshat Sidebar*`，仅在 gt 直接渲染展示 buffer 时生效。
- `seshat-reader-translate--render-object` 的既有权衡：`render` 取 `sidebar` **且** `seshat-reader-sidebar-enabled` 非 nil 时走面板，否则回退 `gt-posframe-pop-render`（该回退契约有三处文档/测试约定，必须保留）。
- `seshat-reader-etaf--translate-meta` 有**两处定义**：`etaf.el` 顶部变量（refs 组）与同名函数（"Compose the badge text"）。

### D1 译文/解释改用 Markdown 文本 buffer（用户已确认）

- 载体：底部面板内的普通**只读** buffer，名字沿用 `*Seshat Sidebar*`（popper 正则、`seshat-reader-sidebar-buffer-p`、用户配置 `init-window.el` 都依赖它，**不得改名**）。
- 渲染：优先 `gfm-view-mode`（markdown-mode 提供，支持 GFM 表格/任务列表）；不可用时依次回退 `markdown-view-mode` → `text-mode`，均不得报错。
- 视图要求：隐藏 Markdown 标记、标题分级、列表缩进、代码块；`truncate-lines` 为 nil 且**显式** `(setq-local word-wrap t)`，保证 CJK 折行（T0 实测 `gfm-view-mode` 不设 `word-wrap`，不显式设置就只在字符边界硬折行）。
- panel 内键位：`q` → `seshat-reader-sidebar-toggle`；`C-c C-s` → `seshat-reader-translate-save-as-annotation`。
- **回退语义保持不变**：`render` 取 `pop`/`pin`，或取 `sidebar` 但 `seshat-reader-sidebar-enabled` 为 nil 时，仍走 posframe 与 `--install-capture-hooks`。
- 被否的备选：继续用 ETAF（自写 Markdown→节点转换 + 动态 viewport + 依赖 ebox 内部 API 测内容高；画布内容不可选中复制；CJK 按 2 列测量易错位）。

### D2 面板高度自适应内容（仅 translate 面板）

- 渲染完成后用 `window-text-pixel-size` 测量面板 buffer 内容像素高，换算为行数，调整面板窗口高度。
- 适用范围（两重限制）：**仅 kind 为 `translate`** 的面板窗口，且该 buffer **未挂载 ETAF runtime**（`etaf-runtime-for-buffer` 返回 nil）。理由：ETAF 画布 buffer 的文本高度与其布局高度不一致，对批注列表面板做 fit 会破坏其固定 12 行卡片布局。
- 上下限：≥ 5 行，≤ `seshat-reader-sidebar-max-height`（默认 0.8 × frame 高度）。
- 调整成功后把最终高度写入 per-kind 高度记忆（`seshat-reader-sidebar--state`）；失败时保留原高度。
- 所有窗口操作 `ignore-errors` 包裹：自适应是体验增强，失败不得影响内容展示。
- 垂直空间守恒：同帧内面板增高会按比例压缩上方阅读窗口，这是预期行为；不变的是阅读窗口对象与其 buffer。

### D3 内容忠实与失败语义

- 删除 `seshat-reader-translate--clean-gt-text`：不再剔除分隔线行、不再压缩空行（Markdown 结构原样交付渲染层）。
- 删除 `seshat-reader-etaf--drop-origin-lines`：不再剔除正文中以「来源：」开头的行。
- `--gt-buffer-text` 不再回退 `(buffer-string)`；新增 `--panel-result`：在隐藏中转 buffer 内直接调 `--extract-result` 取 `(TEXT . FAILED)`，再交 `--record-result`（保留 error face 失败判定），返回写入结果；`TEXT` 为 nil 时提示失败并保留上次译文。
- 面板标题按用途区分：`--translator` 的 `context`（`translate` / `explain`）→ `--render-object` 的 `title` 参数 → `:then` 回调 → `--render-panel`。落地方式：① `--render-object` 签名改为 `(mode &optional title)`；② `--translator` 的 `oset render` 处传 `(if (eq context 'explain) "Seshat 解释" "Seshat 译文")`；③ `:then` 体为 `(let ((result (seshat-reader-translate--panel-result))) (when result (seshat-reader-translate--render-panel result title)))`。`&optional` 保证全部既有单参调用（pop/pin/nil 共 6 处、sidebar 3 处）无需改动。标题写在 buffer 的 `header-line`（不占正文行）。

### D4 批注分页状态放在 annotation 层

- 分页是渲染无关的领域状态，ETAF 与纯文本两条路径共享，避免两套行为。
- 新增 `seshat-reader-annotation-page-size`（默认 20）、buffer-local `seshat-reader-annotation-list-page`（1-based）、命令 `seshat-reader-annotation-list-next-page` / `-prev-page` / `-first-page` / `-last-page`、函数 `-page-count` / `-page-items`（当页切片）/ `-all-items`（全量合并，供移动与收敛判断）。
- 服务端项在前、本地待同步项在后合并后**统一切片**；`--page-items` 与 `--all-items` 必须是同一次合并的两个视图（禁止各自重复合并导致顺序漂移）。
- 页号收敛：当前页超出总页数（删除/刷新导致）时回退到最后一页，至少 1 页；页内无条目但总条目非空时同样回退。
- 键位：`seshat-reader-annotation-list-mode-map` 绑 `]`/`[`（纯文本路径）；ETAF `:keys` 同键位（T4）。

### D5 ETAF 层只保留批注卡片

- 删除 refs：`--translate-title`、`--translate-meta`（**变量**）、`--translate-source`、`--translate-body`、`--translate-origin`、`--translate-source-open`。
- 删除函数/常量：`--translate-keys`、`--translate-meta`（**同名函数**，与上面的变量两处都要删）、`--paragraphs`、`--origin-line-regexp`、`--drop-origin-lines`、`--selection-origin`、`--toggle-translate-source`、`--save-translate-as-annotation`、`--translate-source-excerpt-limit`、`--translate-source-excerpt`、`--translate-view`、`render-translate`。
- 删除后同步清理该文件内所有 docstring 交叉引用（`seshat-reader-etaf--translate-view`、`--drop-origin-lines` 等在其它函数的 docstring 中被引用）。

## 任务

- [x] **T0 技术预验证** ✅（2026-10-18 完成，三条结论见下）
  在独立 Emacs 实例（`emacs --batch -Q` + 必要 `-L`，GUI 行为另用一次 `emacs -Q` 手工确认）验证三条并记录结论：
  ① `gfm-view-mode` / `markdown-view-mode` 是否存在；在 `display-buffer-below-selected` 弹出的小窗口 buffer 中能否隐藏 `**`/`-`/`###` 标记并保持 CJK 折行；
  ② `window-text-pixel-size` 测得的内容像素高换算行数是否与 `count-lines` 一致（给出实测数值）；
  ③ `(window-resize win delta nil t)` 能否调整 `below-selected` 面板窗口高度并保持上方阅读窗口不变。
  验收：三条各给「通过/不通过 + 实测数据」；任一不通过立即停止并报告。**只读实验，不改仓库文件。**
  **T0 结论（2026-10-18）**：
  - EXP1（view mode 与标记隐藏）：**通过** —— `gfm-view-mode=t`、`markdown-view-mode=t`、`markdown-hide-markup=t`、`truncate-lines=nil`、`masked-chars=18`（sample 前 3 项：`("#" nil "")`、`(" " nil "")`、`("*" markdown-markup nil)`；18 恰等于样例中全部标记字符数：标题 `# `=2、粗体 `*`×4、行内代码反引号×2、列表 `- `×2=4、代码围栏×6）
  - EXP2（测高换算）：**通过** —— `pixel-height/line-pixel-height = 20.00`，`count-lines = 20`（误差 0 行，判据 ≤1 行）
  - EXP3（窗口调整）：**通过** —— `resize-ok=t`、`after=12`、阅读区窗口 before/after 均为 2 行；原脚本 `before` 已为 12（前序实验遗留布局使 delta=0，属空操作），故补充实验（干净布局、非零 delta）复核：`panel 8→20`（delta=12）、`panel 20→5`（delta=-15）均精确命中目标且不报错
  - 附注（batch 模式局限与实测发现）：
    - batch 帧 `char-height=1`、`char-width=1`、`frame-height=25`，EXP2 的「1px/行」是退化值，`EXP1d content-pixel-width=28` 无参考意义；**真实字体度量、CJK 双宽与折行未覆盖，留待 L3（GUI `emacs -Q`）**。
    - `gfm-view-mode` **不会**设置 `word-wrap`（实测 `word-wrap=nil`、`wrap-prefix=nil`）；T1 的视图 mode 必须显式 `(setq-local word-wrap t)` 才能保证「按词/按字」折行。
    - 面板增高时上方阅读窗口高度必然按空间守恒缩小（实测 16→4），故 EXP3 原始判据「阅读区窗口高度不变」字面不可满足；**D2/T2 应表述为「阅读区窗口对象与 buffer 不变，仅高度让位」**。
    - `display-buffer-below-selected` 在 `emacs --batch` 下可正常返回窗口（`windowp=t`），但窗口尺寸受帧几何退化影响，最终长宽比例需 GUI 侧确认。

- [x] **T1 译文/解释改 Markdown 渲染** ✅（2026-10-18 完成；L2 translate 28 / sidebar 18 / etaf 16 全绿）（依赖：T0；文件：`emacs/seshat-reader/seshat-reader-translate.el`、`emacs/tests/seshat-reader-translate-test.el`、`emacs/tests/seshat-reader-sidebar-test.el`、`emacs/tests/seshat-reader-etaf-test.el`）
  先写失败测试再实现：
  ① 新增 `seshat-reader-translate-view-mode`（派生 + 降级链 + 只读 + `word-wrap`）；
  ② 新增 `seshat-reader-translate--render-panel (text title)`：写 buffer（`inhibit-read-only`）、设 mode 与 header-line、`seshat-reader-sidebar-show buffer 'translate t`；
  ③ 签名与调用链（第 2 轮审查 N1）：`--render-object` 改为 `(mode &optional title)`；`--translator` 的 `oset render` 处传 `(if (eq context 'explain) "Seshat 解释" "Seshat 译文")`；`sidebar` 分支（`seshat-reader-sidebar-enabled` 非 nil）统一走 `gt-buffer-render :name seshat-reader-translate--gt-buffer-name :window-config '((display-buffer-no-window) (allow-no-window . t)) :then (lambda (&rest _) (let ((result (seshat-reader-translate--panel-result))) (when result (seshat-reader-translate--render-panel result title))))`；`enabled` 为 nil 时**保持** `gt-posframe-pop-render`；`pop`/`pin` 分支不变；
  ④ 删除 `--render-sidebar-etaf`、`--capture-result-sidebar`、`--install-sidebar-capture-hook`；`--install-capture-hook-for-mode` 在 `sidebar`+`enabled` 时不安装任何 hook（捕获由 `:then` 完成），posframe 路径仍安装；
  ⑤ 按 D3：删除 `--clean-gt-text`；`--gt-buffer-text` 去掉 `buffer-string` 回退；新增 `--panel-result`（`--extract-result` → `--record-result`）；
  ⑥ 新增 defcustom `seshat-reader-translate-show-source`（默认 nil）：为 t 时在正文前插入原文 `> ` 引用块（不截断）；
  ⑦ 删除 `来源` 行逻辑；`q` / `C-c C-s` 绑到面板 local map；
  ⑧ 删除不再需要的死声明与死变量：`declare-function seshat-reader-etaf-available-p`、`declare-function seshat-reader-etaf-render-translate`、`(defvar gt-buffer-render-output-hook)`（三者已确认全仓无其它使用者，直接删）；
  ⑨ **既有用例必须显式处理**（第 1 轮审查指出）：
     - `sidebar-test.el` 的 `--translate-sidebar-render-object`：改写为断言新语义（`:name` = 隐藏中转 buffer ` *Seshat gt*`、`:window-config` 含 `display-buffer-no-window`、`:then` 非 nil）；
     - `sidebar-test.el` 的 `--translate-sidebar-disabled-posframe`：保留并通过（`enabled`=nil 仍回退 posframe）；
     - `etaf-test.el` 的 `--sidebar-render-object-uses-hidden-gt-buffer`：复核断言并与新实现对齐（该用例测的正是隐藏中转 buffer）；同时**移除非必要的 ETAF 相关 `skip-unless`**（新分支不再依赖 ETAF 可用性），并评估与 `sidebar-test.el` 的 `--translate-sidebar-render-object` 是否重复——断言完全重合则合并为一条，否则保留各自覆盖点。
  验收：ERT 新增用例覆盖「写入正文与 mode」「mode 降级链」「取不到 gt-result 时提示失败且保留上次译文」「show-source 开关」「header-line 标题区分 translate/explain」；上述 3 个既有用例改写后全绿。

- [x] **T2 面板高度自适应** ✅（2026-10-18 完成；新增 7 条用例）（依赖：T0；文件：`emacs/seshat-reader/seshat-reader-sidebar.el`、`emacs/tests/seshat-reader-sidebar-test.el`）
  新增 `seshat-reader-sidebar-max-height`（默认 0.8）与内部 `--fit-height-for-content (window)`：按 D2 的两重限制（kind=`translate` 且 buffer 未挂载 ETAF runtime）测量并调整窗口高度，成功后写入 per-kind 记忆；在 `seshat-reader-sidebar--display` 末尾 `ignore-errors` 调用。
  验收：ERT 断言 ① 已知 20 行内容的 translate 面板窗口高度被调整到接近 20±2（阅读区窗口对象与 buffer 不变，仅高度让位）；② 超过上限时夹到 `0.8×frame-height`；③ kind=`annotations` 的窗口**不被调整**；④ 挂载了假 ETAF runtime 的 buffer 不被调整。

- [x] **T3 批注分页（领域层）** ✅（2026-10-18 完成；页面脚注仅在总页数 > 1 时显示——避免单页列表增加无意义行、且不破坏 `seshat-reader-annotation-queue-test` 的既有行数断言）（依赖：无；文件：`emacs/seshat-reader/seshat-reader-annotation.el`、`emacs/tests/seshat-reader-annotation-test.el`）
  按 D4 实现页大小、buffer-local 当前页、`-page-count` / `-page-items` / `-all-items` / `-next-page` / `-prev-page` / `-first-page` / `-last-page`；`--render-list` 的**纯文本路径**只渲染当页并在末行插入页脚提示（如 `-- 第 1/2 页 --`）；`list-mode-map` 绑 `]`/`[`；删除后页号收敛。
  验收：ERT 断言「19 条=1 页、20 条=1 页、21 条=2 页」「翻页边界夹紧」「删除末页最后一条后页号回退」「纯文本渲染只含当页条目且页脚正确」「`-page-items` 与 `-all-items` 顺序一致」。
  **实现偏差（2026-10-18）**：页脚 `-- 第 x/y 页 --` 仅在 `y > 1` 时插入；单页列表不显示页脚。

- [x] **T4 ETAF 批注分页渲染** ✅（2026-10-18 完成；新增 6 条用例）（依赖：T3；文件：`emacs/seshat-reader/seshat-reader-etaf.el`、`emacs/tests/seshat-reader-etaf-test.el`）
  ① 卡片列表只渲染 `-page-items`（经 `expr` 读取），标题徽章显示 `第 x/y 页`（`x`/`y` 来自 annotation 层）；
  ② `--annotation-keys` 增 `[`/`]` → 翻页命令；`n`/`p` 移动选中跨页时先切页再 `etaf-scroll-into-view`；
  ③ `--ensure-selection` 使用**全量** items（`-all-items`）以保证跨页选中不丢失；
  ④ 删除/刷新后若当前页为空，渲染前先把页号收敛到合法页。
  验收：ERT 断言「徽章文案」「当页卡片数 = 页大小或余数」「翻页后选中项属于新页」「跨页 `n` 自动翻页且页号 +1」；本任务的用例全部不与 T5 的删除清单交叉。

- [x] **T5 删除 ETAF 译文视图与测试清理** ✅（2026-10-18 完成；etaf.el 929→690 行，残留 grep 为空）
  按 D5 删除全部译文变量/常量/函数，清理 docstring 交叉引用；测试侧删除 `etaf-test.el` 顶部 `declare-function seshat-reader-etaf-render-translate` 及译文相关用例（含 `--render-translate-panel`、`--translate-origin-line-not-duplicated` 之类），保留并复核 `--sidebar-render-object-uses-hidden-gt-buffer`。
  验收：`grep -n 'render-translate\|translate-view\|translate-origin\|drop-origin\|clean-gt-text' emacs/seshat-reader/ emacs/tests/` 为空；ERT 全绿。

- [x] **T6 集成回归 + L3 清单** ✅（2026-10-18 完成；新增 2 条端到端用例）
  用 `cl-letf` 桩 gt 跑「选区 → 译文 → 面板内容与 mode → 存为批注」端到端断言；把 L3 手工清单细化为可勾选项写入本文件「验证标准」节。
  验收：ERT 全绿；L3 清单 ≥6 条可勾选项。
  **T6 结论（2026-10-18）**：新增 `--integration-selection-to-panel` 与 `--integration-panel-to-annotation` 两条端到端用例，5 个测试文件全绿（translate 30 / etaf 20 / sidebar 25 / annotation 31 / queue 26）。

- [x] **T7 文档沉淀** ✅（2026-10-18 完成；10 个文件更新，配置项/roadmap/CHANGELOG 验证命令全部命中）（依赖：T1–T6）
  逐项落实「文档清单」；额外按第 1 轮审查补齐：
  ① `docs/configuration.md:121` 行 `seshat-reader-sidebar-translate-buffer-name` 的说明（`*Seshat Sidebar*` 不再是 gt 的 `:name`，改为「展示 buffer 名；gt 中转使用隐藏 buffer」）；
  ② `docs/llm.md` 节标题「客户端接入（Emacs：go-translate + posframe）」及其正文（翻译 + 解释现在走面板 Markdown buffer，posframe 仅为回退）；
  ③ `seshat-reader-sidebar--last-kind` docstring 的「译文不经过 show」表述（新设计已通过 show）；
  ④ `openspec/tech-debt.md` 三条明确处理：M11.7「`toggle` 无法重开译文面板」→ 已解决；M11.7「`window-height` 只对新建窗口生效」→ T2 部分缓解（写清剩余局限）；M11.5「全局 render hook 时间窗局限」→ 标注「sidebar 路径已消除，posframe 路径仍存」；并新增「markdown-mode 为软依赖」；
  ⑤ `openspec/decisions.md` 新增一条**表格行**（沿用文件既有 `| # | 决策 | 理由 + 日期 |` 格式），内容：阅读器译文/解释改用面板内 Markdown 文本 buffer，ETAF 只保留批注卡片（理由：画布不可复制/固定 viewport 裁剪/CJK 2 列测量风险；日期 2026-10-18）；
  ⑥ `openspec/active/roadmap.md` 在 M11.9 行后新增 M11.10 行并标 ✅；
  ⑦ `CHANGELOG.md` 新增条目；
  ⑧ `seshat-reader-sidebar.el` 的三处 docstring 同步（第 2 轮审查 N2）：`seshat-reader-sidebar-translate-buffer-name`（不再作 gt `:name`、不再作捕获守卫）、`seshat-reader-sidebar-show`（译文路径改为 `--render-panel`）、`seshat-reader-sidebar-select-window`（ETAF 不再渲染译文）。
  验收（可机检）：三个新 defcustom（`seshat-reader-annotation-page-size`、`seshat-reader-sidebar-max-height`、`seshat-reader-translate-show-source`）在各文件被 `grep` 命中；`grep -c 'M11.10' openspec/active/roadmap.md` ≥1；`grep -c 'markdown' docs/architecture.md` ≥1。

## 文档清单

| 文档 | 变更 |
|---|---|
| `docs/configuration.md` | 新增三个 defcustom；改写面板/ETAF 两节职责；改写 `translate-buffer-name` 说明 |
| `docs/architecture.md` | 渲染层章节改写：ETAF = 批注卡片；译文/解释 = Markdown 文本 buffer |
| `docs/llm.md` | 「客户端接入」节标题与正文更新（面板 Markdown 为主、posframe 为回退） |
| `emacs/seshat-reader/VENDORED.md` | 自研扩展表：`-etaf.el` / `-translate.el` 职责更新 |
| `CHANGELOG.md` | 新增变更条目 |
| `openspec/tech-debt.md` | 收敛 3 条既有条目 + 新增 markdown-mode 软依赖条目 |
| `openspec/decisions.md` | 新增 1 条表格行（渲染载体选型，2026-10-18） |
| `openspec/active/roadmap.md` | 新增 M11.10 行（✅） |
| `openspec/completed/2026-10-18-reader-panel-markdown-and-paging.md` | 本计划（进度勾选与 L3 清单） |
| `emacs/tests/seshat-reader-{translate,etaf,sidebar,annotation}-test.el` | 新增/改写 ERT 用例共 29 条（Markdown 面板 6、高度自适应 7、分页 14、集成 2） |

## 验证标准

- **L1（静态检查）**：`cd /home/thomas/WorkSpace/notes/emacs/seshat-reader && make all`
  - check-parens 通过、byte-compile 零 error；
  - checkdoc：**改动前**先跑一次 `make checkdoc 2>&1 | grep -c 'Warning'` 存基线，改动后同样计数，要求**不增加**（`seshat-reader-saveplace.el` 的既有告警属基线，不计新增）。
- **L2（ERT，逐文件；本项目无 test 构建目标，不能靠 make 跑）**：前置 `cd /home/thomas/WorkSpace/notes/emacs/seshat-reader && make all`（生成 `seshat-render-core.so`），然后每个受影响测试文件各跑一次；命令模板取自 `emacs/tests/seshat-reader-etaf-test.el` 头部注释（其 `-L` 是其它文件的超集，复用同模板、多余 `-L` 无害）；缺 ETAF/gt 时用例会 `ert-skip`，须记录 skip 数量：
  ```
  cd /home/thomas/WorkSpace/notes && \
  "emacs" --batch -Q \
    -L "emacs" -L "emacs"/seshat-reader \
    -L /home/thomas/WorkSpace/emacs-taf/ecss       -L /home/thomas/WorkSpace/emacs-taf/ecss/lisp \
    -L /home/thomas/WorkSpace/emacs-taf/ebox       -L /home/thomas/WorkSpace/emacs-taf/ebox/lisp \
    -L /home/thomas/WorkSpace/emacs-taf/etaf       -L /home/thomas/WorkSpace/emacs-taf/etaf/lisp \
    -L /home/thomas/WorkSpace/emacs-taf/etaf-ui    -L /home/thomas/WorkSpace/emacs-taf/etaf-ui/lisp \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/compat \
    -l "emacs"/tests/<TEST-FILE>.el \
    -f ert-run-tests-batch-and-exit
  ```
  受影响的 5 个文件：`seshat-reader-translate-test.el`、`seshat-reader-etaf-test.el`、`seshat-reader-sidebar-test.el`、`seshat-reader-annotation-test.el`、`seshat-reader-annotation-queue-test.el`。
  验收：每个文件 `0 unexpected`（失败=0），记录 `passed/skipped` 数。
- **L3（GUI 手工，用户执行）**：以下 6 条在 GUI `emacs -Q` + 真实 PDF 下逐条勾选（batch 环境下 `line-pixel-height`/字体度量退化，L3 是唯一覆盖面）：
  - [ ] L3-1 选文本 → `C-c C-t` 翻译：面板内显示完整译文，无「来源」行、无「q 关闭」提示，`q` 可关（预期：面板 buffer 内容 = 译文全文，`header-line` 显示「Seshat 译文」，按 `q` 后面板窗口消失且不影响主窗口布局）
  - [ ] L3-2 选文本 → `C-c C-e` 解释：Markdown 标题/列表/粗体被渲染（不显示 `**`、`-`、`###`），CJK 折行正常，长内容可滚动看全（预期：`major-mode` 为 `gfm-view-mode`（未装 markdown-mode 时降级 `text-mode`），`truncate-lines`=nil、`word-wrap`=t、`buffer-read-only`=t，`header-line` 显示「Seshat 解释」，滚动到底可见末段）
  - [ ] L3-3 面板高度随内容自适应：20 行 CJK 内容（预期：面板窗口高度落在 18–22 行区间且 ≤ 0.8 × frame 高度；内容再长时面板停在 0.8 × frame 上限并可正常滚动）
  - [ ] L3-4 打开批注列表并分页（预期：标题徽章显示「第 x/y 页」，`]`/`[` 各翻一页且徽章页号同步 ±1，`n`/`p` 移到当页末条/首条时自动翻页且选中项始终可见）
  - [ ] L3-5 删除一条批注（末页最后一条）后页号回退（预期：页数 y 减 1，当前页停留在 x（末页清空时经 `--clamp-page` 回退为 `x-1`），列表不空白、余下卡片正常、选中项合法；删到只剩一页时徽章由「第 x/y 页」变为「N 条」）
  - [ ] L3-6 `M-x seshat-reader-translate-save-as-annotation` 存为批注（预期：迷你缓冲区提示「已把译文存为批注 <id>」，服务端批注正文 = 面板中译文全文，位置含 `page:<n>;rect:...`，原文档文件内容不被改写）
- **L3 状态**：清单已细化（见上），等待用户在 GUI 下逐条勾选；batch 环境无法覆盖字体度量与真实折行。

## 注意事项

- **buffer 名不得改**：`*Seshat Sidebar*` 被 popper 正则、`seshat-reader-sidebar-buffer-p`、用户配置 `init-window.el` 依赖。
- **ETAF 仍是软依赖**：`seshat-reader-etaf.el` 顶部硬 `require 'etaf-ui`，接入点继续用 `(require 'seshat-reader-etaf nil t)` 并降级。
- **markdown-mode 是新增软依赖**：`gfm-view-mode` / `markdown-view-mode` 加载失败不得报错，按降级链回退到 `text-mode`。
- **`enabled`=nil 的回退契约不得破坏**：`sidebar` + `sidebar-enabled`=nil 时仍走 posframe（三处文档/测试约定）。
- **fit 的双重限制**：只对 kind=`translate` 且未挂载 ETAF runtime 的 buffer 生效。
- **evil 干扰**：`special-mode` 系按键可能被 evil 接管，`q`/`C-c C-s`/`]`/`[` 需在 ETAF `:keys` 与 local map 两侧都验证（L3）。
- **不要改 thomas-emacs 用户配置**（popper 正则、`init-reader.el` 无需变更）。
- **不要动 `seshat-reader-saveplace.el` 等 vendored 文件**。
- 删除函数后必须全仓 grep 残留引用（含 `declare-function`、docstring、测试）。
- 每个任务先写失败测试再实现；L1 修复循环上限 3 轮、L2/L3 上限 2 轮，仍失败则回滚并报告。
