# 阅读器多页连续布局 P1：buffer 内多页纵向连续滚动

> 已归档（2026-10-27）：T1–T10 全部完成；实现与偏差见文末「## 执行记录」。

## 当前状态
- 阶段：Phase 4（Review & Document）· T1–T10 全部完成，待代码审查（code-reviewer）与最终提交
- 已确认：路线 3 ✅、缩放基准 A ✅、缩放公式分模式 ✅、计划 v3 终审 ✅、D3 修正为像素级滚动 ✅、滚动步长可配置 ✅、跨页选区首期禁用（D7）✅
- 执行状态：批次 1–8 全部完成（commit `d7ef467` / `12d8911` / `4590f0b` / `19a5a91` / `80eb582` / `c6caf85` / `4751929` / `27bdbbe` / `78b273a` / `b82e03d` / `f83bb64` / `e27dd78` / `365198a` / `e2c6f02`）
- 验证基线：`make -C emacs/seshat-reader clean all` EXIT 0、warning **24**（P0 基线 33 → T7 后 24，零新增）、checkdoc 0；`make -C emacs/tests ert` → **31 文件 / 1213 例 / 0 unexpected / 0 skipped**
- 现象：多页连续像素级滚动 + 逐页居中 + 宽页裁剪 + `W`/`H`/`+`/`-`/`0` 缩放（首屏即清晰）+ 视口缓存/预取 + 选区页号反查 + 书签页内偏移
- 下一步：code-reviewer 审查 → 修复 blocking → 归档本计划到 `openspec/completed/`
- dark-mode 相关：存储粒度与配色预设由 `openspec/active/2026-10-27-reader-dark-tint-presets.md` 接管（D2 已定为 A（进程级，2026-10-27））；T4 的「反色后重渲染全部可见页」语义不变，但 T4 已落地的 dark-mode body 将是该计划的编辑点，两计划需串行合并。

## 目标

把 PDF 阅读器从「单页 overlay + 像素级 vscroll」改为「buffer 内多页纵向连续布局」：向下滚动时页面自然接续，不再出现「滚到页底后整页跳变」；页号、批注、搜索、书签、选区在改造后保持语义不变或明确降级。

## 根本问题（第一性原理）

| 事实 | 依据 |
|---|---|
| 页面载体是**单页 overlay**：一页一张图，buffer 里没有第 2 页 | `seshat-reader.el` 的 `--get-current-doc-image-size` 经 `seshat-reader-current-doc-overlay` 访问器读窗口参数 `overlay` 的 `display` |
| 滚动上限 = 页高 + 页首条带 - 窗高；到底后 `scroll-down` 返回 0 → 直接 `--next-page` 并 `vscroll=0` | `--page-max-vscroll-pixels` / `--set-window-vscroll` / `scroll-down-or-next-page`（1450 行） |
| 「跨页连续性」只有向上方向的一半机制（页首条带），默认关闭且带已知几何缺陷 | `seshat-reader-page-join-lines` 默认 0；`openspec/tech-debt.md`「跨页衔接在 fit-to-height 下裁切」 |
| 页号由 C 侧写入 `selected-window` 的 `page` 参数；per-window 状态各自持有当前页 | `elisp-helpers.c` 的 `set_current_page_number`；`EmacsWinState.current_page_number` |
| P0 已提供「渲染任意页 → 返回 spec、不改显示状态」的入口 | `seshat-reader-dyn--page-image-spec`（arity 2..3）+ `seshat-reader--page-spec`（缓存上限 8） |
| P0 实测：单页 0.7–11 ms；**缓存上限 8 + FIFO 在顺序扫 20 页时命中率 0** | `openspec/completed/2026-10-26-reader-multipage-p0-page-spec-api.md` 的「## 实测数据」 |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | buffer 内用 `display` 文本属性承载多页 image spec 可行，且多窗口天然共享同一内容 | 事实✓（Emacs 文本属性语义；P0 已证 spec 可长期持有） |
| A2 | `seshat-reader-current-doc-pagenumber` 可改为「视口顶页」派生而保持调用点零改动 | 假设?（需 T2 验证；实测调用点 **15 处**：`seshat-reader.el` 567/774/854/1621/2067/2078/2157、`seshat-reader-select.el` 792/807/818、`seshat-reader-bookmark.el` 28、`seshat-reader-outline.el` 126、`seshat-reader-search.el` 282、`seshat-reader-reference.el` 810/951）。假设仅覆盖 outline/bookmark/reference/search/mode-line，**不含 select** |
| A3 | 同步渲染在滚动到新页时体验可接受（P1 阶段；异步留 P2） | 假设?（P0 实测 0.7–11 ms/页支持） |
| A4 | 可见 ±2 页（5 页）驻留的内存可接受（72dpi ≈1.4 MB/页、150dpi ≈6.2 MB/页，双份 ≈ 2×） | 假设?（T6 实测校准） |
| A5 | 首期「禁止跨页选择」可被用户接受 | 用户显式（决策 D7，2026-10-26） |
| A6 | 删除 strip 全族不会影响其它模块（仅 reader 内部使用） | 事实✓（调用点全在 `seshat-reader.el`） |
| A7 | 多窗口「同内容不同滚动位置」可接受 | 用户显式（决策 D4，2026-10-26） |

## 设计

### D1 布局模型

- buffer 内容改为「每页一行（或一段）+ `display` 文本属性」，**不再用 per-window overlay 承载页面**；读取某页 spec 统一经 `seshat-reader-current-doc-overlay` 访问器（签名改造归 T4）。
- buffer-local 数据结构：`seshat-reader--pages`（`alist`：`PAGE -> (MARKER . SPEC)`，MARKER 指向该页行首）。
- 可见集：窗口 `window-start` 所在页 ±`seshat-reader--multipage-preload`（默认 2）页；越界页**移除 display 属性并回收 spec**（保留 marker 或删除占位行，二选一在 T1 定）。
- 页间间隙：新增 defcustom `seshat-reader-page-gap-lines`（默认 `0`，与 Android 端「整页 item 零间隙堆叠」一致）。
- buffer 保持只读；所有写入走 `inhibit-read-only` + `set-buffer-modified-p nil`（沿用既有纪律）。

### D2 页号派生

- `seshat-reader-current-doc-pagenumber` **保留函数名与签名**，内部改为「视口顶页」：取窗口 `window-start`，在 `seshat-reader--pages` 中定位所在页（按 marker 顺序线性/二分）。
- C 侧写入的 `page` 窗口参数**保留但 elisp 不再读取**（避免改 C）；`scale` 由窗口参数升为 **buffer-local** `seshat-reader--multipage-scale`。
- `goto-page` 改为「把该页 marker 的 buffer 位置 `set-window-start`」。
- `--page-indicator` / mode-line 页码、outline 当前章、search 当前页、bookmark 页号**经同一 API 自动适配**；但 **`seshat-reader-select.el` 的 4 处页号读取（约 792/807/818 行等）必须改**——拖选视口第二页时「视口顶页」会返回错页，由 T8① 的『页号反查』负责，不算零改动。

### D3 滚动定位原语（v2：真机验收推翻了「原生行滚动」方案）

- 纵向定位以 `set-window-start` + 页 marker 为主；`window-vscroll` 负责**页内像素偏移**。
- `seshat-reader-scroll-up/down`、`-screen`、`mwheel-*` 一律走新增的 `seshat-reader--multipage-scroll (pixels)`：视口顶页 + 该页内像素偏移，跨页时 `distance -= 页高(+gap)` 并 `set-window-start` 到下一页行首，**连续不跳变**。
- `scroll-up-or-prev-page` / `scroll-down-or-next-page` 等命令**保留名字**但语义为「滚动 N 行 / 一屏」，不再换页；`n` / `p` / `M-g g` 仍为整页跳转且**把 vscroll 归零**停在页首。
- **原方案为何作废（假设复盘 ✗）**：v1 写「改为原生行滚动（`scroll-up-command` 语义），删掉滚不动就翻页的分支」。真机验收（用户 2026-10-27）发现：多页布局里**每页 = buffer 的一个行**，行高 = 整页图片高度（≈窗口高或更高），而 Emacs 的 `scroll-up`/`scroll-down` 按**缓冲行**滚动 → 一次「滚一行」= 跨过整页，表现正是「不能滚动、直接下一页」。故必须回到像素级 vscroll（旧单页模型用 vscroll 的原因同源）。
- 一屏像素口径取 `(window-body-height WIN t)`（文本区高度，不含 mode-line/header-line），否则每次 `SPC` 会多滚一条 mode-line 高度、丢掉 `next-screen-context-lines` 的语义。

### D4 缓存与虚拟化

- 淘汰策略改为**按视口驻留**：`seshat-reader--page-spec-cache-limit` 由固定 8 改为「可见页数（2K+1）+ 预取 1」（预取方向 = 滚动方向，且**视口外最近的一页保留**，即前后各驻留 1 页）动态上限；缓存除 FIFO 外增加**视口优先**：视口外的条目在建立新页时优先淘汰。
- 同步渲染：滚动进入新页时立即渲染（P1 接受卡顿）；P2 再引入异步 + idle 预取。
- 明确内存预算：同时驻留 spec ≤ 6，按 150dpi ≈6.2 MB/页 × 2（Lisp + C）≈ 75 MB 为上限告警线，写入 tech-debt。

### D5 缩放与 refit（基准页策略已定案，公式分模式）

- scale 升为 buffer 级（D2），并设 **`base-scale`**：由「文档首页 native size + 当前窗口尺寸 + fit 模式」推出，**文档打开后固定，不随滚动变化**。
- **基准页策略 = 首页基准 + 宽页按宽裁剪**（用户 2026-10-26 确认，取代原「T5 首个提交时二选一」）。
- **每页目标 scale 按 fit 模式取，不做跨模式混用**：

| fit 模式 | 每页目标 scale | 是否可能超宽 |
|---|---|---|
| `contain` | `min(base-scale, 该页 width-fit)` | 否（宽页被裁剪到刚好不溢出） |
| `width` | `该页 width-fit`（每页正好填满宽度） | 否 |
| `height` | `该页 height-fit`（**不裁剪宽度**，保持既有 fit-to-height 语义） | 是 → hscroll 兜底（见 D5b） |
| 手动 `+` / `-` | `base-scale × 系数`（**不裁剪**） | 是 → hscroll 兜底（见 D5b） |

  - **「宽页按宽裁剪」只对 `contain` / `width` 生效**；`height` 与手动缩放不改既有「按单一维度缩放、允许超宽」的语义，避免静默改变 `seshat-reader-fit-to-height` 的行为。
  - 可机械断言的判据：`contain` / `width` 模式下任一可见页 `image :width` ≤ `window-body-width`。
  - 回退分支（仅当真机观感差、异常宽页被缩得过小时才评估）：改用「全文档最大页尺寸」作基准，**不作为首期实现**，须另开任务（含新增 C 侧批量查页尺寸接口）。
- **每页 native 尺寸的获取路径（无需 C 侧接口）**：首页 native size 由首屏渲染后的 spec 反推（`--first-fit` 既有路径，spec `:width`/`:height` ÷ scale）；第 N 页先以 `base-scale` 渲染得到 spec，再由 spec `:width` ÷ 当前 scale 反推 native 宽，算出该页 width-fit；超宽时用 `--apply-display-scale` 原地改写 spec 缩到 width-fit（**不重渲染**）。
- `--apply-display-scale` 改为**批量**改写所有可见页 spec 的 `:width`/`:height`（不重渲染），逐页套用上表。
- `--refit-window` 的重渲染范围 = 全部可见页；`render-scale` 改为按页记录（`alist` PAGE -> SCALE）。
- `W` / `H` / `+` / `-`：`W` / `H` 重定 `base-scale` 为首页 width-fit / height-fit 并切换 fit 模式；`+` / `-` 在 `base-scale` 上乘除系数（模式视为手动）。
- `--right-most-window-hscroll` 口径改为「可见页 hscroll 上限的最大值」（`height` 模式与手动放大下仍可横向滚动；`contain` / `width` 下应为 0）。

### D5b hscroll 存废（与 `openspec/decisions.md` 2026-10-26 代价③ 对齐）

- **保留全族，不进 D6 删除清单**：`--set-window-hscroll`、`--window-hscroll`、`--right-most-window-hscroll`，以及 `scroll-left` / `scroll-right` / `scroll-left-screen` / `scroll-right-screen` / `scroll-left-most` / `scroll-right-most` 及其 `mwheel` 与键位绑定全部保留。
- 理由：`height` 模式与 `+` 放大下页面必然宽于窗口，横向滚动是唯一出路；hscroll 是窗口级、会让整栏（含邻页）一起移动，这是 decisions.md 已登记的**本期不解决**缺陷，不在 P1 扩大范围。
- T4 只改 `--right-most-window-hscroll` 的计算口径（见 D5）；T10 把「横向滚动整栏平移」写进 `docs/emacs-reader.md` 已知限制与 `openspec/tech-debt.md`。

### D6 删除跨页 strip 全族

删除 `seshat-reader-page-join-lines`、`--page-join-pixels`、`--page-image-specs`、`--page-image-specs-limit`（defconst，`seshat-reader.el:727`）、`--join-strip-height`、`--join-strip-end`、`--remember-current-page-spec`、`--insert-join-strip`、`--remove-join-strip`、`--update-join-strip`、`--set-page-top-when-joined`、`--page-max-vscroll-pixels`、`--clamp-window-vscroll`、`--center-overlay`、`--ensure-center-overlay`，以及 `next-page` / `previous-page` / `first-page` / `last-page` / `goto-page` 里的 strip 调用。多页布局天然提供跨页上下文，上述机制的存在前提消失。`--right-most-window-hscroll` / `--set-window-hscroll` / `--window-hscroll` 与横向滚动命令族**不在**本清单内（见 D5b）。迁移说明必须给出具体步骤：从 `custom-set-variables` 中删除 `seshat-reader-page-join-lines` 条目（否则老配置残留为 free variable，静默失效、无提示）；若希望更友好，可保留一个标记为 obsolete 的兼容变量并在首次使用时 `message` 提示。

### D7 多窗口与跨页选区

- 多窗口：接受「同内容、不同滚动位置」；`page` 参数降级为派生值（不再保证与显示一致），`docs/emacs-reader.md` 明写该行为变更。
- 跨页选区：首期 `user-error` 提示「暂不支持跨页选择」，单页内行为不变；`--text-in-rect` 等单页 API 调用不变。

## 任务

- [x] T1 布局骨架（**纯新增、零破坏**）：新增 `seshat-reader--pages` 结构、页行插入/移除函数、`display` 属性承载 spec、`seshat-reader-page-gap-lines` defcustom、可见集维护函数（按页号增删页）。**本任务不接入 `--render-buffer`、不触碰任何既有单页路径**。验收（单元级，在临时 buffer 中直接调用插入/移除函数）：① 插入 5 页后 buffer 内 `display` 属性数为 5 且顺序与页号一致；② 再插入第 6 页后为 6；③ 移除第 1 页后为 5 且剩余页 marker 位置正确；④ `page-gap-lines` 取 0 与 2 时行数差 = 2×n（**每页行后（含末页）都追加 gap 空行**，实现取此口径，见执行记录偏差 D1）；⑤ 既有 ERT 全绿（本批不应有任何失败用例）。（依赖：无）**已完成（commit d7ef467）**：新增 172 行（`seshat-reader.el` 720–891 行）；ERT 1163 → **1172**（新增 `seshat-reader-multipage-test.el` 9 例），0 unexpected / 0 skipped；`make all` EXIT 0、warning 28 = 本机基线零新增、checkdoc 0 报错。
- [x] T1b 窗口与 overlay 管理重写：**分工边界**：T1b 只负责「每窗口 overlay 管理族」的删除/改写与布局骨架的建立（含去掉 strip 调用、重建 `--render-buffer` 的布局入口）；逐页居中、逐页 fit/重绘语义、`--native-page-size` 的按页缓存由 T4 完成——两者对 `--render-buffer`/`--first-fit`/`--native-page-size`/`--redisplay-all-windows`/dark-mode 的改动不得重复，T1b 只保证不悬空、T4 负责语义正确。D1 推翻了「每窗口一个 overlay」模型，必须整段重写或删除 `seshat-reader--manage-window-overlays`、`--window-create-function`、`--window-close-function`、`--handle-window-buffer-change` 及其 `window-configuration-change-hook` / `window-buffer-change-functions` 注册；`seshat-reader-current-doc-overlay` **定义保持原样、不删除**（T1b 只保证不悬空）；其**定义改造**（签名改 `(window &optional page)`、语义变为『读指定页的 spec』）与全部调用点改造**归 T4**；`--render-buffer` 去掉 `--update-join-strip` 与 `--page-image-specs` 清理，改为重建多页布局；对 `--first-fit` / `--native-page-size` / `--redisplay-all-windows` 只做**最小改动**保证不 void-function、不崩溃；语义正确归 T4；dark-mode invert：**定为** C 侧 `--doc-invert`（文档级）后重渲染全部可见页（沿用既有 `--redisplay-all-windows` 改造），**不做** elisp 侧 spec 反色（`--page-image-spec` 无 invert 参数不影响该路径）。`seshat-reader-current-doc-overlay` 的**调用点**（`--get-current-doc-image-size` / `--page-image-spec` / `--center-page` / `--centered-p`，以及 `--get-prefix-width` 附近读 `--center-overlay` 的那一处（约 `seshat-reader.el:994`，属 T4 几何范畴））全部由 T4 改造；T1b 不得直接删除它，否则 T4 改造前会出现 void-function。验收：T1b 职责清单内的「每窗口 overlay」管理族（`--manage-window-overlays` / `--window-create-function` / `--window-close-function` / `--handle-window-buffer-change`）及其 hook 注册已删除或改写完成，grep 这四个函数名在 `seshat-reader.el` 中仅出现在注释/迁移说明里；**「全仓再无 `(window-parameter … 'overlay)` 读取」这一断言移到 T4 验收**（T1b 阶段 T4 职责函数尚未改造，此刻 grep 必然命中）。新窗口显示同一文档时正确建立布局；两个窗口可各自滚动。**打开真实 PDF 后 buffer 内含 5 页行、滚动到页边界时第 6 页被插入、离开的第 1 页 spec 被回收（断言 buffer 内 `display` 属性数）——原 T1 的接入验收移到这里**；本批结束居中/尺寸/fit 语义暂失效（T4 恢复），但不得崩溃、不得 void-function。（依赖：T1）`seshat-reader--remember-current-page-spec` 的**调用点**（`next-page`/`previous-page`/`first-page`/`last-page`/`goto-page` 五处）随 strip 一并去掉；其**定义**由 T7 删除。**已完成（批次 2，commit 12d8911）**：新增 14 个 `--multipage-*` 驻留族函数（render/sync/goto/window-start-page/after-command/relayout/drop-c-overlay/rotate-by/ensure-window-layout 等）+ 3 个 buffer-local（`--multipage-rotate` / `--multipage-syncing` / `--multipage-last-range`）；`--multipage-visible-range` 改为按 `seshat-reader-current-doc-pagecount` 裁剪；`--render-buffer` 重建为「load-doc → 关 C overlay（经 `--window-close` 释放 `EmacsWinState`）→ erase → 复位窗口参数 → 清 spec 缓存 → 渲染 target±preload → goto」；hook 换装（删 `window-configuration-change-hook` / `window-buffer-change-functions`，新增 buffer-local `window-state-change-functions` + `post-command-hook`）；删除 4 个 per-window overlay 管理函数（全仓 0 命中）；几何/居中族 11 个符号保号 + 无 overlay 惰性守卫。

  **新窗口布局承接（删旧 → 挂新对应表）**：

  | 旧机制（删除/改写） | 新承担者 | 职责 |
  |---|---|---|
  | `--window-create-function`（建页 overlay + 写 `fit-mode` + `dyn--window-create`） | 新增 `seshat-reader--ensure-window-layout`（buffer-local `window-state-change-functions`） | 确保该窗口 `window-start` 落在记录位置（缺省 = 当前页 marker）、写 `fit-mode` 初值、调 `--first-fit` / `--center-page` |
  | `--window-close-function` | 无替代（无 per-window overlay 需清理） | 可选：清理窗口参数 `scale` / `fit-mode` / `native-size` |
  | `--handle-window-buffer-change` | `seshat-reader--render-buffer` 的布局入口 | buffer 级布局一次建立；换 buffer 后重建 `seshat-reader--pages` |
  | `--manage-window-overlays` + `window-configuration-change-hook` 注册 | `--schedule-refit` 既有路径 + `window-state-change-functions` | 尺寸变化只做 refit，不再重建 overlay |
- [x] T2 页号派生：`current-doc-pagenumber` 改视口顶页、`goto-page` 改 `set-window-start`、`--page-indicator` 与 mode-line 正常、`scale` 升 buffer 级。验收：滚到第 3 页时 `(seshat-reader-current-doc-pagenumber)` 返回 3；`M-g g` 跳到第 10 页后光标所在页为 10；outline 当前章高亮随之变化。（依赖：T1）**已完成（批次 2）**：`current-doc-pagenumber` 改视口顶页派生（不再读窗口参数 `page`）；next/prev/first/last/goto 改页 marker 定位（队列机制保留）；mode-line 页数补 nil 守卫。
- [x] T3 滚动命令重写：`scroll-up/down`、`-screen`、`mwheel`、`scroll-*-or-*-page`、`--at-page-top-p`、`--set-page-top/bottom`、`--set-window-vscroll`，并清理 `--page-max-vscroll-pixels` / `--clamp-window-vscroll` 的调用点（这两个函数在 T7 删除，T3 阶段若不清调用会悬空）。验收：向下滚到底后继续按 ↓ **不换页**，而是进入下一页内容的连续滚动；向上滚到顶同理；`SPC` / `DEL` 仍滚一屏。（依赖：T1、T2）**已完成（批次 2）**：`scroll-up/down/-screen` 与 `mwheel-*` 改原生行滚动 + `--multipage-sync`；四个 `*-or-*-page` 保留名字改纯滚动；vscroll 族外部调用点清零（定义留待 T7）；旋转改为真实实现（buffer-local 角度 → 清 spec 缓存 → 按视口顶页 relayout）。
- [x] T4 几何与居中：`seshat-reader-current-doc-overlay`（定义改造：签名改 `(window &optional page)`、语义变为『读指定页的 spec』）、`--get-current-doc-image-size`、`--page-image-spec`、`--center-page`（逐页 `before-string`/`:align-to`）、`--centered-p`、`--ensure-centered`、`--recenter-window`、`--right-most-window-hscroll`（按可见页宽）。验收：多页同时可见时每页各自水平居中；窗口尺寸变化后所有可见页在同一帧内重新居中；宽页按宽裁剪生效：任一可见页 `image :width` ≤ `window-body-width`（contain / width 模式）；`seshat-reader-presentation-mode`：**保留既有语义**（`mode-line-format` 置 nil + `fit-to-height`），多页布局下自然等价于「视口约装一页」；**不新增第二种布局**（决策 4）——进入时每页高度适配窗口、约一页可见，退出后恢复原 `base-scale` 与 `mode-line`。同时覆盖：`--render-buffer`（重建布局而非单页 overlay）、`--first-fit`（首屏对全部可见页生效）、`--native-page-size`（按页缓存改为 alist）、`--redisplay-all-windows`（遍历窗口重绘可见页）、`seshat-reader-dark-mode`（反色后全部可见页重渲染）、**超宽页对齐**：`height` 模式与手动放大下超宽页**贴左 + 横向滚动**，不再用 `line-prefix` 做居中补偿（`--center-overlay` 随 D6 删除）——`openspec/tech-debt.md`「居中两套机制」条目随之勾销。本任务完成后全仓 grep `(window-parameter [^)]*'overlay` 应无读取点（仅允许出现在注释/迁移说明）。（依赖：T1、T1b、T2、T3）**注意**：批次 2 用「无 overlay 即惰性」守卫保住了 `seshat-reader-resize-test.el` 的 53 例（它们仍断言单页 overlay 几何，靠守卫才通过），T4 必须把这些用例按多页语义重写或删除，不得依赖守卫继续绿。**已完成（批次 3，commit 19a5a91 + 80eb582）**：行结构升为「引导空格 `(space :align-to (+ center (-0.5 . SPEC)))` + 图像空格 + 换行」，逐页独立居中、超宽页摘除引导空格贴左；新增 `--multipage-base-scale` / `--multipage-fit-mode` / `--page-native-sizes` / `--page-render-scales`（窗口参数 `native-size`/`render-scale` 退场）、`--multipage-target-scale`（D5 分模式表）、`--multipage-resize-spec`、批量 `--apply-display-scale`、逐页 `--center-page`/`--centered-p`、全页 `--refit-window`；`seshat-reader-current-doc-overlay` 改为返回 spec（签名 `(window &optional page)`）；dark-mode/presentation-mode/`--redisplay-all-windows` 多页化（presentation 成对记住/恢复 fit-mode + base-scale）；生产代码 `(window-parameter … 'overlay)` 读取点 **0**。修掉 2 个实现缺陷：`--multipage-rerender-page` 早退导致 refit/dark/rotate 假重渲染、presentation 退出未恢复 base-scale。
- [x] T5 缩放与 refit：`--apply-display-scale` 批量、`--refit-window` 重渲染可见页、`render-scale` 按页、`fit-mode` 基准页。验收：`W`/`H`/`+`/`-` 后所有可见页同步缩放；窗口 resize 后可见页全部清晰化（不只当前页）；`fit-mode` 语义不变；**滚动跨过页边界时 scale 不跳变**（基准页锚定策略生效）。（依赖：T4）**已完成（批次 4，commit b82e03d）**：`+`/`-` 改为 `base-scale × seshat-reader-enlarge/shrink-factor`（mode 置 manual）、`0` 重新首屏适配、`W`/`H` 用基准页（打开文档首页的 native 尺寸，`--first-fit` 时缓存进 `--multipage-reference-native`）算 fit、滚轮与按键同路径；`--first-fit` 末尾同步逐页 refit（**首屏即清晰**）；`--multipage-refit-page` 加 `render-scale` 容差 0.005（避免 native 取整漂移导致每次重渲染）；`--multipage-set-scale` 收敛为「clamp → 批量 apply → 居中 → 逐页 refit → sync」五段同步流水线；跨页滚动只读 `base-scale`（不重算）。12 条新用例，4 个变异自检全被抓，真文档冒烟 11/11。
- [x] T6 缓存与虚拟化：动态上限、视口优先淘汰、预取 1 页、内存告警线。验收：连续滚动 30 页时缓存长度始终 ≤ 可见页数+1；**往回滚 1 页**命中缓存（不调 C）；P0 的「顺序扫 20 页命中率 0」问题不复现。（依赖：T1、T3、T4）**已完成（批次 5，commit f83bb64）**：动态上限 `--multipage-cache-limit`（2K+2，夹 4..16）、视口优先淘汰、回收时保留相邻页 spec、方向感知预取（只暖缓存不插行）、`seshat-reader-multipage-memory-warning-mb`（默认 75，每 buffer 一次）；12 例新用例 + 3 变异自检；P0 的「顺序扫 20 页 0 命中」不复现。
- [x] T7 删除 strip 全族（D6 清单）并清理相关 tech-debt 条目（912/1036 等）。验收：全仓 grep 无 `page-join-lines` / `--join-strip` / `--page-max-vscroll-pixels` 残留；`page-join-test.el` 删除或整体重写。（依赖：T3、T4）**注意**：像素级滚动所需的 `--multipage-scroll` / `--multipage-page-pixel-height` / `--multipage-page-gap-pixels` / `--multipage-page-span` / `--multipage-page-max-offset` / `--multipage-page-neighbour` / `--multipage--scroll-to-page` 是 P1 的新实现，**必须保留**；T7 只删与本清单冲突的旧 vscroll 族（`--set-window-vscroll` / `--clamp-window-vscroll` / `--page-max-vscroll-pixels` / `--window-vscroll-pixels` / `--at-page-top-p` / `--set-page-top*` / `--set-page-bottom`）。**已完成（批次 6，commit e27dd78）**：删除 strip / vscroll / center-overlay / 旧单页访问器全族（`seshat-reader.el` 净删约 270 行），`page-join-test.el` 整体删除；顺带修掉真机三报错——`pixel-scroll-precision` 用命令 remap 接管（全局 minor mode 的 `setq-local` 无效，实测 `/usr/share/emacs/31.1/lisp/pixel-scroll.el.gz` 优先级高于局部 map）、选区与滚动的 overlay 残留清零、滚动命令 `ignore-errors` 兜住首尾。
- [x] T8 外围适配：① 选区 `posn→page` 加「页号反查 + 页内 y 偏移」，跨页拖选 `user-error`；② 书签/saveplace 从 `vscroll` 改为「页号 + 页内像素偏移」（或直接存 buffer position）；**同时处理 `hscroll` 字段**（`seshat-reader-bookmark.el` 的 record 含 `hscroll`；**`hscroll` 字段保留**（D5b 下 `height` 模式与放大后仍有横向滚动），仅把定位语义从 `vscroll` 改为「页号 + 页内像素偏移 + hscroll」；旧记录（有 `vscroll` 无页内偏移）按「页号 + vscroll 近似换算为页内像素偏移」迁移，读不到时退回页首）；③ 搜索 `goto-page` 语义复核（跳转后停在页首）；④ 高亮刷新范围扩到全部可见页（若需 C 改动则显式列出并评估）；⑤ `seshat-reader-select-drag` 的 `select-window` 假设复核；⑥ `seshat-reader-reference.el` 的 `page:<n>` 生成与跳转语义复核（`seshat-reader-reference.el:810/951`），验收补「摘录到笔记的 `page:` 与从笔记跳回均落在正确页首」。验收：单页内框选建批注坐标正确；跨页拖选给出明确提示；书签保存/恢复落到同一页同一偏移；搜索跳转后停在命中页。（依赖：T2–T5）**已完成（批次 7，commit 365198a）**：选区页号反查（`posn-point` → 页行）+ 跨页 `user-error`、`select-drag` 去掉 `select-window` 副作用；书签/saveplace 改「页号 + 页内像素偏移 `offset` + hscroll + scale + fit-mode（恢复为 manual）」，旧 `vscroll` 记录可迁移；装饰刷新改走 `--multipage-refresh-decorations`（清 spec 重渲染可见页，`dyn--refresh-highlights` 在 elisp 侧 0 调用）；新增 `seshat-reader-periphery-test.el` 16 例。
- [x] T9 测试重写与新增。现有基线（P0 归档口径）：`emacs/tests/` **29 个测试文件 / 1163 例**；`seshat-reader-page-join-test.el` **26**、`seshat-reader-resize-test.el` **80**、`seshat-reader-page-spec-test.el` **13**。**批次 2 后的实际基线**：30 个测试文件 / **1131** 例（resize 80 → 53、page-join 26 → 6、page-spec 13 → 13 夹具适配、multipage 9 → 15），0 unexpected / 0 skipped。**批次 3 后的实际基线**：30 个测试文件 / **1144** 例（resize 53 例全部重写为多页语义、multipage 15 → 28 含 13 条几何用例），0 unexpected / 0 skipped。**批次 4 后的实际基线**：31 个测试文件 / **1183** 例（multipage 44 → 56），0 unexpected / 0 skipped。`page-join-test.el`（26 例，24 例作废）删除/重写；`resize-test.el` **80 例**（实测，其中约 55 例需改写断言、其余可保留）按「多页 + 批量 scale」改写；新增 `seshat-reader-multipage-test.el`（布局/页号派生/虚拟化/滚动边界 ≥15 例）；从零补 `posn→page` 用例（当前零覆盖）≥4 例。另需同步改写 P0 的 `seshat-reader-page-spec-test.el`（13 例）中受 D4 缓存策略与 T1b/T4 改造影响的用例：`--cache-drops-the-oldest-entry`（FIFO → 视口优先）、`--does-not-touch-window-state`（窗口参数语义变化）、`--render-buffer-drops-cache`（`--render-buffer` 重建布局）。验收：全仓 `unexpected = 0` 且 `skipped = 0`（`skipped > 0` 视为假绿）；新增用例覆盖 D1–D7 每条决策。本任务同时落地 `emacs/tests/Makefile` 的 `ert` 目标，固化 `-L` 路径集合（`-L emacs -L emacs/seshat-reader` + straight build 目录），此后 L2 一律用该目标执行。（依赖：T1–T8）**已完成（批次 8 上，commit e2c6f02）**：新增 `emacs/tests/Makefile`（`make -C emacs/tests ert`，自动发现 + 判据「0 unexpected 且无 skipped」）+ `emacs/tests/README.md`；resize 用例更名到新语义（数量不变）；补 6 例（自愈、pagecount nil 退化、重载无残留、dark/presentation 顺序无关、占位页不死循环、跨 buffer 页号）。当前基线 **31 文件 / 1213 例 / 0-0**。
- [x] T10 文档与归档：`docs/architecture.md`（布局模型整章改写）、`docs/emacs-reader.md`（键位语义变化：↓ 不再换页、`n`/`p` 仍整页；多窗口语义变更；跨页选区限制）、`docs/configuration.md`（新增 `page-gap-lines`、删除 `page-join-lines` 条目并给迁移说明：迁移说明必须给出具体步骤：从 `custom-set-variables` 中删除 `seshat-reader-page-join-lines` 条目（否则老配置残留为 free variable，静默失效、无提示）；若希望更友好，可保留一个标记为 obsolete 的兼容变量并在首次使用时 `message` 提示）、`VENDORED.md`、`CHANGELOG.md`（行为变更段）、`decisions.md`（补 P1 落地记录）、`tech-debt.md`（勾销失效条目、登记新缺口）、`roadmap.md`（P1 ✅）；计划归档。验收：新人仅凭文档能理解连续滚动布局与键位语义。（依赖：T1–T9）**已完成（批次 8 下）**：文档八处同步 + 计划归档（见下）。

## 批次执行（每批独立验收，批次间由用户真机确认）

| 批次 | 任务 | 验收 | 风险 |
|---|---|---|---|
| 0 | 计划修订定案 | plan-reviewer 复审通过 + 用户确认 | 低 |
| 1 | T1 | L1 + 布局/回收断言 | 中 |
| 2 | T1b + T2 + T3（同批连续完成，避免中间态悬空） | L1 + L2 + 双窗口滚动 + 页号派生 + 滚动不换页 | 高 |
| 3 | T4 | L1 + L2 + L3 逐项（居中 / 宽页裁剪 / presentation-mode / dark-mode） | 最高 |
| 4 | T5 | L2 + L3 缩放跨页不跳变 | 高 |
| 5 | T6 | L2 + 30 页缓存长度断言 + 回滚命中 | 高 |
| 6 | T7（可提前到批次 3（T4）之后） | L1 + grep 零残留 | 低 |
| 7 | T8 | L2 + L3 选区 / 书签 / 搜索 / 高亮 / reference | 高 |
| 8 | T9 + T10 | L1 / L2 全绿 + 文档八处同步 | 中 |

**批次 2 批内提交顺序**（必须按序，挂新与删旧在同一提交内完成）：① 挂 `seshat-reader--ensure-window-layout` → ② 删 `--window-create-function` / `--manage-window-overlays` / `--window-close-function` / `--handle-window-buffer-change` 及其 hook 注册 → ③ 重建 `--render-buffer` 布局入口（**此处才把多页布局接入打开路径**）→ ④ T2 页号派生 → ⑤ T3 滚动重写 → ⑥ 批内同步改写被破坏的 ERT（`page-join` 的 strip 断言、`resize` 的 overlay 假设、`page-spec` 的 `--render-buffer-drops-cache`）。**本批结束居中/尺寸/fit 语义暂失效（T4 恢复），但不得崩溃、不得 void-function。**

**执行纪律**：

1. **每批内同步改写被本批破坏的 ERT 用例**（红测试不得跨批）：T9 因此只负责「补新增用例 + 全量回归 + 基线固化」，不是「首次重写」。批次验收时 L2 必须是 0 unexpected **且** 0 skipped。
2. 每批开始前建 git 安全点（有未提交改动时先记录 `git status`），批次失败回滚到安全点。
3. 每批结束的 L1 口径：`elisp_check_parens` 通过 + `make -C emacs/seshat-reader all` EXIT 0 + warning ≤ 基线 **33**（P0 实测）+ `make checkdoc` 0 报错。
4. L3 真机项由用户在批次间确认，未确认不得进入下一批。

## 文档清单

| 文档 | 需同步内容 |
|---|---|
| `docs/architecture.md` | 「跨页衔接」整节替换为「多页连续布局」：buffer 结构、页 marker、可见集与虚拟化、页号派生、滚动原语 |
| `docs/emacs-reader.md` | 键位表（`↓`/`SPC` 语义变化、`n`/`p` 保持整页）、多窗口语义变更、跨页选区限制、已知限制更新 |
| `docs/configuration.md` | 新增 `seshat-reader-page-gap-lines`；删除 `seshat-reader-page-join-lines`（给迁移说明：改用连续布局后无需该开关）；新增 `seshat-reader-scroll-step-ratio`（默认 0.15）与 `seshat-reader-scroll-step-pixels`（默认 nil，覆盖比例）两个选项，并说明「一页一行」布局下 `j`/`k` 的步长语义 |
| `emacs/seshat-reader/VENDORED.md` | `seshat-reader.el` 条目追加 P1 改动（布局、页号派生、虚拟化、删除 strip） |
| `CHANGELOG.md` | `### 变更`（行为变更）+ `### 破坏性`（`page-join-lines` 移除、`↓` 语义变化、多窗口语义变化） |
| `openspec/decisions.md` | 补 P1 落地记录与实测（首屏时间、滚动流畅度、内存） |
| `openspec/tech-debt.md` | 勾销因改造失效的条目（strip 裁切、strip spec 旧尺寸、vscroll 下界、居中两套机制等）；登记 P1 遗留（异步预取未做、跨页选区未做、**横向滚动整栏平移未解决**、宽页按宽裁剪的取舍） |
| `openspec/active/roadmap.md` | P1 状态改 ✅ 并指向归档计划 |

## 验证标准

- **L1**：`elisp_check_parens`（emacs-lisp-mode 侧）+ `make -C emacs/seshat-reader clean all` EXIT 0、warning 数不超过基线 **33**（P0 实测）、checkdoc 0 报错。`clean` 口径：重建 `.so` 时必须带 `clean`；仅改 elisp 时可省 `clean`，改 C 必须 `clean all` 并重启 Emacs。
- **L2**：`emacs/tests/` 逐文件 ERT（带完整 `-L` 依赖路径），`unexpected = 0`、`skipped = 0`；重写后的 `resize-test` 与新增 `multipage-test` 全绿。ERT 运行口径：`emacs --batch -Q -L emacs -L emacs/seshat-reader` + straight build 目录集合（批次 8 起以 `make -C emacs/tests ert` 固化）；判据 `unexpected = 0` **且** `skipped = 0`。
- **L3（GUI 手工验收，必须逐项）**：① 打开 PDF 连续向下滚动 3 页，**无整页跳变**；② 向上滚动同理；③ `n`/`p` 仍整页跳转且停在页首；④ `M-g g` 跳页正确；⑤ 缩放 `+`/`-`/`W`/`H` 后所有可见页同步且清晰；⑥ 窗口 resize 后可见页全部重新居中/清晰化；⑦ 单页内框选建批注坐标正确；⑧ 跨页拖选给出提示；⑨ 书签保存后重开落到同一页同一偏移；⑩ 搜索命中跳转正确且高亮在可见页上出现；⑪ 两个窗口看同一文档可各自滚动（内容相同、位置不同）；⑫ 内存观察：连续滚动 30 页后 `VmRSS` 增量在告警线内；⑬ 缩放到 200% 与 50% 后各自连续滚动 2 页，无跳变、无错位；⑭ 连续快速滚动（长按/连按 ↓ 20 次）无卡顿可感（主观判定，记录现象）；⑮ 只读 buffer 下 `auto-revert-mode` 与 `super-save` 不报错（打开 PDF → 等 30 秒 → 查看 `*Messages*` 无 `super-save` / `buffer-read-only` 报错）。
- **任务类型**：elisp 验证一律 `verify` 隔离实例；收尾 `set_task auto` + `instance stop` + `instance_status`。

## 注意事项

1. **这是架构级替换**：预估 elisp 改动 **600–900 行**、测试重写 **100 例左右**（page-join 26 + resize 80 中的大部分），必须按 T1–T10 分批执行、每批独立验收，禁止一次性大改。
2. **行为变更必须显式告知**：`↓` 不再翻页、多窗口不再「各看不同页」、`page-join-lines` 移除、跨页选区暂不支持——四者都要进 `CHANGELOG` 的「破坏性」段。
3. **`point` 与 buffer 可变性**：buffer 从「1–2 行」变成「N 行 + 动态增删」，`buffer-read-only`、`auto-revert-mode`、`revert-buffer-function`、`set-buffer-modified-p nil` 纪律、外部包 `super-save` 的交互都要重新验证（tech-debt 已有相关条目）。
4. **缓存策略是 P1 的成败点**：P0 实测「上限 8 + FIFO 顺序扫命 0」，P1 必须改为视口驻留 + 优先淘汰视口外条目，否则滚动会反复重渲染。
5. **高亮/批注刷新范围**：现有 `--refresh-highlights` 只重建「当前窗口 ±5 页」且只显示当前页；多页可见时未刷新页看不到高亮。若 P1 不改 C，则必须在 elisp 侧对每个可见页各触发一次刷新（评估代价）；若改 C，需单列任务并重建 `.so`。
6. **不引入异步**：P1 保持同步渲染（P0 实测 0.7–11 ms/页），异步预取留给 P2；不得在 P1 顺手加 idle timer（daemon 下可靠性未复验，tech-debt 有记录）。
7. **删 strip 不可回退兼容**：`seshat-reader-page-join-lines` 直接移除，不保留别名；文档给迁移说明。
8. **每批完成后必须真机验收**：批量 ERT 不产生真实 redisplay，居中/对齐类问题只能肉眼发现（tech-debt 已记录该教训）。
9. **`seshat-reader-presentation-mode` 已定案**：保留既有语义（隐藏 mode-line + `fit-to-height`），多页布局下自然等价于『视口约装一页』，**不新增第二种布局**；归 T4 验收（原『二选一』作废）。

## 执行记录

### 批次 1 — T1 布局骨架（2026-10-26，commit `d7ef467`）

- **产出**：`seshat-reader.el` 新增 172 行（720–891），零删除/零修改；`emacs/tests/seshat-reader-multipage-test.el` 新建 9 例。
- **新增符号**：defcustom `seshat-reader-page-gap-lines`；defvar-local `seshat-reader--multipage-preload`（2）、`seshat-reader--pages`；函数 `--multipage-page-row` / `--multipage-page-spec` / `--multipage-insert-page` / `--multipage-remove-page` / `--multipage-page-at-pos` / `--multipage-visible-range`。
- **验证**：`make -C emacs/seshat-reader all` EXIT 0；byte-compile warning **28**（本机同日基线 28，零新增；计划原写「基线 33」是 P0 会话口径，判据仍以「零新增」为准）；checkdoc 0 报错；括号检查两文件 parens-ok；全仓 ERT 29 → **30 个文件、1163 → 1172 例、0 unexpected / 0 skipped**。
- **L3**：无（纯新增，不接入显示路径）。
- **偏差**：
  - **D1 gap 口径**：每页行后（含末页）都追加 `seshat-reader-page-gap-lines` 个空行，故 5 页时 gap 0/2 的行数差为 2×n = 10（非 2×(n-1) = 8）。取此口径的理由：插入/删除对称、实现简单；末尾空行不影响任何布局断言。
  - **D2 marker 创建顺序**：先 `insert` 再 `copy-marker row-start t`（在插入点先建 marker 会被随后插入的文本推到行尾）。
  - **D3 幂等插入同步属性**：`--multipage-insert-page` 对已存在页改写 spec 时同步 `put-text-property` / `remove-text-properties`，避免 `seshat-reader--pages` 与 buffer `display` 属性不一致。
  - **D4 删除长度按当前 gap 值**：`--multipage-remove-page` 依当前 `seshat-reader-page-gap-lines` 计算删除长度；会话内改 gap 会不精确（T1b 重建布局时兜底）。
  - **D5 ERT 运行命令**（T9 要固化）：`emacs --batch -Q -L emacs -L emacs/seshat-reader` + `-L /home/thomas/thomas-emacs/.local/straight/build-31.1/{gt,pdd,posframe,etaf,etaf-ui,ecss,ebox,visual-fill-column}`，逐测试文件 `-l emacs/tests/<FILE>.el -f ert-run-tests-batch-and-exit`。

### 批次 2 — T1b + T2 + T3（2026-10-27，commit `12d8911` + `4590f0b`）

- **产出**：`seshat-reader.el` 净 +284 行（+616/−332）；四个测试文件改写。
- **关键实现**：C 侧 `load-doc` 会在当前窗口建一个覆盖全文的 overlay（`init_overlay`）并把第 1 页图片塞进它的 `display`；多页布局必须先经 `seshat-reader-dyn--window-close` 关掉它（顺带释放 C 的 `EmacsWinState`），否则整页布局被覆盖。此后所有渲染只走 P0 的 `seshat-reader-dyn--page-image-spec`（`--page-spec` 包装），所有依赖 overlay 的 C 显示入口（next/prev/goto/redisplay/scale-page/rotate/refresh-highlights/window-create）在 elisp 侧**调用点清零**。
- **`--multipage-goto` 两次定位**：`--multipage-sync` 会在视口前插入/回收页行，若 `window-start` 恰为 `point-min` 会被留在新插入行之前 → 同步后必须再定位一次，并返回 fresh marker 位置。
- **`seshat-reader-open-doc` 简化**：不再自行 `load-doc`，只 `switch-to-buffer` + `seshat-reader-mode`，加载与布局统一由 `--render-buffer` 负责（否则 C 写的 `render-status` 会让 mode 跳过布局、buffer 只剩 C 的单页 overlay）。
- **旋转**：未降级，改为真实实现（buffer-local `--multipage-rotate` → 清 spec 缓存 → 按视口顶页 relayout，`--page-spec` 的 ROTATE 参数透传）。
- **验证**：`make -C emacs/seshat-reader clean all` EXIT 0；byte-compile warning 同口径 **28 → 20**（净减 8：`dyn--{first,last,next,prev,goto}-page` / `dyn--redisplay-doc` / `dyn--rotate-page` / `dyn--window-create` 的「not known to be defined」随调用点下线消失），全量 25 条（含 bookmark/saveplace 各 1 条既有）；checkdoc 0；五个改动文件 parens-ok；全仓 ERT 30 文件 **1131 例、0 unexpected / 0 skipped**。
- **测试结构变化**：`page-join` 26 → 6（删 20 个 strip/vscroll/overlay 用例，T7 整体删除该文件）；`resize` 80 → 53（删 27 个断言单页 overlay 几何/已删函数/`page` 窗口参数缓存的用例，其余 53 例靠「无 overlay 惰性守卫」仍绿，T4 必须重写）；`page-spec` 13 → 13（仅夹具适配：不再要求 overlay，走新 `--render-buffer`）；`multipage` 9 → 15（新增 goto 定位 / fresh 位置 / 页号随 window-start / 翻页边界 / sync 幂等 / sync 回收）。
- **commit 结构**：`seshat-reader.el` 单文件内 T1b/T2/T3 互相依赖（`--render-buffer`↔`--multipage-sync`↔`--multipage-goto`），按步拆分会产生不可编译的悬挂提交，故合为 1 个 feat commit + 1 个 test commit（计划允许的备选方案）。
- **遗留**：T4 几何族 11 个符号（惰性守卫态）、T5 scale buffer 级、T7 vscroll 族 8 个函数与 strip 全族删除、T8 bookmark `doc-scale-page` 与 `--refresh-highlights` 18 处调用点、L3 真机（本批不声称通过）。

### 批次 3 — T4 逐页几何与居中（2026-10-27，commit `19a5a91` + `80eb582`）

- **产出**：`seshat-reader.el` +796/−467（实现）+ 56（缺陷修复）；`seshat-reader-resize-test.el` 33 例重写（6 例改名并注明「P1 重写」），用例数 53 → 53；`seshat-reader-multipage-test.el` 15 → 28（新增 13 条 `--geometry-*`）。
- **居中手法**：每页行 = 引导空格（`display` = `(space :align-to (+ center (-0.5 . SPEC)))`，SPEC 为对象本身，原地改尺寸时 align-to 自动跟随）+ 图像空格 + 换行；超宽页摘除引导空格贴左，横向滚动仍由窗口级 hscroll 兜底（D5b）。
- **修掉的实现缺陷**：① `--multipage-rerender-page` 丢缓存后调 `--multipage-render-page`，后者「行内已有 spec 即早退」→ refit / dark-mode / rotate 的「重渲染」全是假动作；改为 `--multipage-render-page` 增加 `force` 形参。② presentation-mode 退出只恢复 fit-mode 未恢复 base-scale → 用户原缩放被静默改掉；改为 `--presentation-state = (MODE . BASE-SCALE)` 成对恢复。
- **两处偏离（已确认）**：`--get-prefix-width` 恒返回 0（它是 `--set-window-hscroll` 的校准常数，新布局不再画 line-prefix；返回溢出量会让 `C-a`/`scroll-left-most` 把页面滚到右边缘）；scale clamp 取 0.25..11.0（对齐 C 侧 MINRES/MAXRES 18/850 dpi，避免请求值被静默钳制后 native 反推失真）。
- **验证**：`make clean all` EXIT 0；warning 20（同集合、零新增）；checkdoc 0；`grep -rn "(window-parameter[^)]*'overlay" emacs/ --include=*.el` = 0（含测试）；全仓 ERT 30 文件 / 1144 例 / 双零。
- **L3**：待用户真机确认（五项：逐页居中、宽页贴左、开关目录后重新居中、`W`/`H`/`+`/`-`、连续滚动无跳变）；batch 下 16 项命令级冒烟全 PASS 但无真实 redisplay。
- **遗留**：T5（手动缩放系数口径、首屏即清晰、跨页 scale 不跳变断言）、T7（死符号：`doc-scale-page`、`--page-image-spec`、`--native-page-size`、`--contain-scale`、`--remember-current-page-spec`、`--center-overlay` 全族、join-strip 全族、vscroll 全族）、T8（选区页号反查、书签/saveplace `hscroll`、`--refresh-highlights` 18 处调用点）。

### 批次 3 修复轮 — 像素级连续滚动（2026-10-27，commit `c6caf85`）

- **触发**：用户真机验收报「不能滚动，直接就下一页（`j` 与 `n` 效果相同）」。
- **根因**：每页在 buffer 内是**一个 `display` 属性行**，行高 = 整页图片高度；`scroll-up`/`scroll-down` 按缓冲行滚动 → 一次滚动跨过整页。D3 v1「改原生行滚动」的假设被推翻（假设来源标注为 `假设?`，现已记 ✗）。
- **修复**：新增 7 个像素级原语（`--multipage-scroll`、`--multipage-page-pixel-height`、`-gap-pixels`、`-page-span`、`-page-max-offset`、`-page-neighbour`、`--multipage--scroll-to-page`）：视口顶页 + `window-vscroll` 像素偏移，跨页时扣页高（+gap）并 `set-window-start` 到下一页行首；`--multipage-goto` 显式把 vscroll 归 0（`n`/`p`/`M-g g` 停在页首）；`--multipage-sync` / `--ensure-window-layout` 确认不写 vscroll。
- **口径**：一屏像素 = `(window-body-height WIN t)` − `next-screen-context-lines × 行高`（不用 `window-pixel-height`，避免把 mode-line 高度算进滚动量）。
- **验证**：`make clean all` EXIT 0、warning 20 零新增、checkdoc 0、parens-ok；全仓 ERT 30 文件 **1155 例**（multipage 28 → 39，新增 11 条 `--geometry-scroll-*`，含「`set-window-vscroll` 必须以像素模式 `t` 调用」的防回归断言）双零；真文档 12 项冒烟 PASS。
- **遗留**：batch 帧无法保留 `window-vscroll`（设 100 读回 0），页内偏移观感只能由 GUI 真机确认；其余同批次 3。

### 批次 3 修复轮 2 — 行滚动量取值错误（2026-10-27，commit `4751929`）

- **触发**：用户第二次真机验收仍报「按 j 直接翻页」，并提供读数组：`(window-vscroll nil t)` = 0、`(line-pixel-height)` = 2414、当前页图片高 = 2414、`(fboundp 'seshat-reader--multipage-scroll)` = t（证明新代码已加载）。
- **根因**：`--scroll-line-pixels` 用 `(line-pixel-height)` 取「一行像素高」，但在多页布局里**视口顶行就是整页图片行**，该函数返回的是**整页高度**（真机 2414px）→ 一次 `j` 的滚动量 = 页高 → `distance ≥ span` 必然跨页、余量 0、`vscroll` 恒 0。同一陷阱也存在于 `--multipage-page-gap-pixels`（gap 空行被算成页高）。
- **修复**：新增 `seshat-reader--default-line-pixels`（`(frame-char-height (window-frame …))`，下限 1），`--scroll-line-pixels` 与 `--multipage-page-gap-pixels` 一律改用它；全仓 `seshat-reader.el` 内 `line-pixel-height` 调用点 0（只剩 docstring 说明）；`seshat-reader-sidebar.el` 的同类调用合法（普通文本 buffer）保持不变。
- **验证**：`make clean all` EXIT 0、warning 20 零新增、checkdoc 0、parens-ok；全仓 ERT 31 文件 **1169 例** 双零（multipage 39 → 42，新增 3 条用例：`line-pixel-height` 桩成页高、`frame-char-height` 桩成 20，断言步长只可能是 20；变异验证把实现改回旧取值 → 3/3 立刻红）；真文档冒烟 12/12 PASS。

### 批次 3 修复轮 3 — 滚动步长可配置（2026-10-27，commit `27bdbbe`）

- **触发**：用户验收通过但要求手感可调（「做成可配置项」）。
- **实现**：新增两个 defcustom —— `seshat-reader-scroll-step-ratio`（**number，默认 0.15**＝窗口文本区像素高 × 比例，`j`/`k` 与滚轮每档都按此）与 `seshat-reader-scroll-step-pixels`（**nil 或正整数，默认 nil**，非 nil 时覆盖比例、钉死绝对像素）；取值函数 `seshat-reader--scroll-step-pixels`（比例非数字/≤0/结果 <1 → 回退 `--default-line-pixels`）。
- **不动**：`SPC`/`DEL` 一屏量仍 = `(window-body-height WIN t)` − `seshat-reader-screen-context-lines × 默认行高`（与步长无关，用例里把 ratio 绑 0.5 断言结果不变）。
- **验证**：`make clean all` EXIT 0、warning 20 零新增、checkdoc 0；全仓 ERT 31 文件 **1171 例** 双零（multipage 42 → 44：步长随窗口缩放、绝对像素优先、非法比例回退、滚轮 1/2/3 档）；两处变异验证（忽略绝对像素 / 忽略比例）均被用例抓住。提交时用 hunk 精确入索引，未卷入并行会话的 theme 调色板改动。

### 批次 4 — T5 缩放与 refit（2026-10-27，commit `b82e03d`）

- **产出**：`seshat-reader.el` +287/−?（10 个 hunk）；`seshat-reader-multipage-test.el` 44 → 56（新增 12 例）；`seshat-reader-resize-test.el` 2 例改造（缩放改为同步 refit 后需桩渲染器）。
- **缩放口径**：`+`/`-` = `base-scale × factor`（1.25 / 0.75）、mode → `manual`；`0` = 基准 `--initial-fit-mode` 下的 fit（重新首屏适配）；`W`/`H` = 基准页 width/height-fit；滚轮与按键走同一路径（不再传绝对 scale）。
- **基准页**：新增 buffer-local `--multipage-reference-native`，在 `--first-fit` 时测量并缓存「打开文档那一页」的 native 尺寸；`reload` 与 `rotate` 时清空。理由：页 1 被 `--multipage-recycle-page` 回收后无法再测，回读会静默退回 1.0。
- **首屏即清晰**：`--first-fit` 末尾对全部驻留页同步 `--multipage-refit-page`，不再依赖 idle refit（代价 ≈5 页 × 0.7–11 ms，已写注释）；`--multipage-set-scale` 也改为「clamp → 批量 apply → 居中 → 逐页 refit → sync」五段**同步**流水线。
- **refit 闸门容差**：`--multipage-refit-page` 用 `|render − target| < 0.005`（新 defconst `--refit-scale-tolerance`）。精确比较会因 native = spec ÷ render-scale 的取整漂移而每次重渲染，破坏幂等。偏差在 1000px 页面上 ≤1px。
- **跨页 scale 锚定**：`base-scale` 的写点只有 `--multipage-set-scale` / `--first-fit` / `--render-buffer`（复位）；`--multipage-sync` / `--multipage-render-page` 只读，滚动补页用同一 base，故跨页不跳变（已在 sync docstring 明写）。
- **验证**：`make clean all` EXIT 0；warning 20 零新增；checkdoc 0；parens-ok；全仓 ERT 31 文件 **1183 例** 双零；4 个变异自检（系数当绝对 / first-fit 不 refit / refit 只顶页 / sync 重算 base）全部被抓；真文档冒烟 11/11 PASS。
- **L3**：待用户真机（首屏清晰、`+`/`-` 即时清晰、`W`/`H`、拖窗后全部可见页清晰、跨页不跳变、滚轮一致）。

### 批次 5 — T6 缓存与虚拟化（commit f83bb64）

- **产出**：动态缓存上限 `--multipage-cache-limit`（`2K+2`，夹 4..16）、视口优先淘汰、回收时保留相邻页 spec、方向感知预取（只暖缓存、不插行）、内存告警 `seshat-reader-multipage-memory-warning-mb`（默认 75 MB，每 buffer 只提示一次）；新增 12 例用例。
- **取舍**：预取只暖 spec 缓存，不提前插页行——避免滚动方向抖动时反复增删行（行增删仍只由 `--multipage-sync` 按视口决定）。
- **验证**：`make clean all` EXIT 0、checkdoc 0；L2 双零；3 个变异自检（去掉视口优先 / 上限退化为固定 8 / 预取插行）全部被抓；P0 的「顺序扫 20 页 0 命中」不再复现。
- **遗留**：内存告警线 75 MB 未经长时真机压测（150 dpi 下多为估算）。

### 批次 6 — T7 删除死族与三报错修复（commit e27dd78）

- **产出**：`seshat-reader.el` 净删约 270 行——strip 全族、vscroll 全族、`--center-overlay` 全族、旧单页访问器（`--page-image-spec` / `--native-page-size` / `--contain-scale` / `doc-scale-page` / `--remember-current-page-spec`）；`seshat-reader-page-join-test.el` 整体删除。
- **真机三报错修复**：① `pixel-scroll-precision` 改用**命令 remap** 接管（全局 minor mode 的 `setq-local` 无效，实测 `/usr/share/emacs/31.1/lisp/pixel-scroll.el.gz` 的优先级高于局部 keymap）；② 选区与滚动残留 overlay 清零；③ 滚动命令首尾用 `ignore-errors` 兜住（`point-min`/`point-max` 边界）。
- **验证**：`make clean all` EXIT 0、checkdoc 0、warning 24（P0 基线 33 → 24，零新增）；L2 双零（`page-join-test.el` 的 6 例随文件删除）。
- **偏差**：删除面比计划 D6 清单更宽（把旧单页访问器一并清掉），因 T4 后它们已无调用点。

### 批次 7 — T8 外围适配（commit 365198a）

- **产出**：选区页号反查（`posn-point` → 页行）+ 跨页 `user-error`；`select-drag` 去掉 `select-window` 副作用；书签/saveplace 记录改「页号 + 页内像素偏移 `offset` + hscroll + scale + fit-mode（恢复为 manual）」并支持旧 `vscroll` 迁移；装饰刷新改走 `--multipage-refresh-decorations`（清 spec 重渲染可见页），`dyn--refresh-highlights` 在 elisp 侧 0 调用；新增 `seshat-reader-periphery-test.el` 16 例。
- **取舍**：装饰刷新选择「清缓存 + 全可见页重渲染」而非逐页增量重绘——简单且与 P1 同步渲染一致，代价是刷新瞬间的重渲染量（≈可见页数 × 0.7–11 ms）。
- **验证**：`make clean all` EXIT 0、checkdoc 0、warning 24；L2 双零。
- **遗留**：跨页选区仍 `user-error`（决策 D7）；hscroll 仍是窗口级（整栏平移）。

### 批次 8 上 — T9 测试基建（commit e2c6f02）

- **产出**：`emacs/tests/Makefile`（`make -C emacs/tests ert`，自动发现测试文件 + 判据「`0 unexpected` 且无 `skipped`」）+ `emacs/tests/README.md`（记录 `-L` 集合与 `posn-*` 需加载同源 `.el` 的桩替注意事项）；resize 用例更名到新语义（数量不变）。
- **补 6 例**：自愈、`pagecount` nil 退化、重载无残留、dark/presentation 顺序无关、占位页不死循环、跨 buffer 页号。
- **验证**：`make -C emacs/tests ert` → **31 文件 / 1213 例 / 0 unexpected / 0 skipped**；`make clean all` EXIT 0、warning 24、checkdoc 0。
- **价值**：把「漏 `-L` 即静默 skip」的假绿风险编码为不变量（对应 tech-debt「ERT 假绿判据」条目的收口）。

### 批次 8 下 — T10 文档与归档

- **产出**：`docs/architecture.md`（多页布局整章）、`docs/emacs-reader.md`（键位语义 / 多窗口 / 跨页选区限制 / 已知限制）、`docs/configuration.md`（`page-gap-lines`、`scroll-step-ratio`、`scroll-step-pixels`、删除 `page-join-lines` 并给迁移说明）、`emacs/seshat-reader/VENDORED.md`、`CHANGELOG.md`（变更 + 破坏性）、`openspec/decisions.md`（P1 落地记录）、`openspec/tech-debt.md`（勾销失效条目 + 登记 P1 遗留）、`openspec/active/roadmap.md`（P1 ✅）；本计划归档到 `openspec/completed/`。
- **验证（文档侧）**：`make -C emacs/seshat-reader clean all` EXIT 0、`make -C emacs/tests ert` 31 文件 / 1213 例 / 双零；文档中的命令与键位均可直接复制执行。
- **遗留**：L3 真机全套项由用户在最终提交前确认（计划「验证标准」的 L3 十五项）。
