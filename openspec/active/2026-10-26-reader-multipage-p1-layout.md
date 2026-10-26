# 阅读器多页连续布局 P1：buffer 内多页纵向连续滚动

## 当前状态
- 阶段：Phase 2（Plan）· 计划待独立审查与用户确认
- 已确认：整体路线与决策 D1–D7 ✅（用户 2026-10-26 确认路线 3）、P0 已完成并归档 ✅（`openspec/completed/2026-10-26-reader-multipage-p0-page-spec-api.md`）
- 执行状态：**计划已定稿，等待排期**（触发条件：用户下达开工指令；本文件暂不执行）
- 下一步：plan-reviewer 独立审查 → 用户确认 → 分阶段执行（T1 起）

## 目标

把 PDF 阅读器从「单页 overlay + 像素级 vscroll」改为「buffer 内多页纵向连续布局」：向下滚动时页面自然接续，不再出现「滚到页底后整页跳变」；页号、批注、搜索、书签、选区在改造后保持语义不变或明确降级。

## 根本问题（第一性原理）

| 事实 | 依据 |
|---|---|
| 页面载体是**单页 overlay**：一页一张图，buffer 里没有第 2 页 | `seshat-reader.el` 的 `--get-current-doc-image-size` 经 `seshat-reader-current-doc-overlay` 访问器读窗口参数 `overlay` 的 `display` |
| 滚动上限 = 页高 + 页首条带 - 窗高；到底后 `scroll-down` 返回 0 → 直接 `--next-page` 并 `vscroll=0` | `--page-max-vscroll-pixels` / `--set-window-vscroll` / `scroll-down-or-next-page`（约 1348 行） |
| 「跨页连续性」只有向上方向的一半机制（页首条带），默认关闭且带已知几何缺陷 | `seshat-reader-page-join-lines` 默认 0；`openspec/tech-debt.md`「跨页衔接在 fit-to-height 下裁切」 |
| 页号由 C 侧写入 `selected-window` 的 `page` 参数；per-window 状态各自持有当前页 | `elisp-helpers.c` 的 `set_current_page_number`；`EmacsWinState.current_page_number` |
| P0 已提供「渲染任意页 → 返回 spec、不改显示状态」的入口 | `seshat-reader-dyn--page-image-spec`（arity 2..3）+ `seshat-reader--page-spec`（缓存上限 8） |
| P0 实测：单页 0.7–11 ms；**缓存上限 8 + FIFO 在顺序扫 20 页时命中率 0** | `openspec/completed/2026-10-26-reader-multipage-p0-page-spec-api.md` 的「## 实测数据」 |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | buffer 内用 `display` 文本属性承载多页 image spec 可行，且多窗口天然共享同一内容 | 事实✓（Emacs 文本属性语义；P0 已证 spec 可长期持有） |
| A2 | `seshat-reader-current-doc-pagenumber` 可改为「视口顶页」派生而保持 20+ 调用点零改动 | 假设?（需 T2 验证；调用点已 grep 全量）。假设仅覆盖 outline/bookmark/reference/search/mode-line，**不含 select** |
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

### D3 滚动定位原语

- 纵向定位以 `set-window-start` + 页 marker 为主；`window-vscroll` **仅**用于页内像素微调（平滑）。
- `seshat-reader-scroll-up/down`、`-screen`、`mwheel-*` 改为原生行滚动（`scroll-up-command` 语义），删掉「滚不动就翻页」的分支。
- `scroll-up-or-prev-page` / `scroll-down-or-next-page` 等命令**保留名字**但语义改为「滚动一屏」，不再换页；`n` / `p` 仍为整页跳转（`goto-page`）。

### D4 缓存与虚拟化

- 淘汰策略改为**按视口驻留**：`seshat-reader--page-spec-cache-limit` 由固定 8 改为「可见页数（2K+1）+ 预取 1」（预取方向 = 滚动方向，且**视口外最近的一页保留**，即前后各驻留 1 页）动态上限；缓存除 FIFO 外增加**视口优先**：视口外的条目在建立新页时优先淘汰。
- 同步渲染：滚动进入新页时立即渲染（P1 接受卡顿）；P2 再引入异步 + idle 预取。
- 明确内存预算：同时驻留 spec ≤ 6，按 150dpi ≈6.2 MB/页 × 2（Lisp + C）≈ 75 MB 为上限告警线，写入 tech-debt。

### D5 缩放与 refit

- scale 升为 buffer 级（D2）。
- `--apply-display-scale` 改为**批量**改写所有可见页 spec 的 `:width`/`:height`（不重渲染）。
- `--refit-window` 的重渲染范围 = 全部可见页；`render-scale` 改为按页记录（`alist` PAGE -> SCALE）。
- 宽页策略：**统一 scale**（基准页**不随滚动变化**，取文档首页尺寸或全文档最大页尺寸，二选一在 T5 首个提交时按真机效果定，见下条『基准页锚定』），不出现「某页宽于窗口导致整栏横滚」（决策 D2①）。
- **基准页锚定**：`contain` 口径的基准页**不随滚动变化**——取「文档首页尺寸」或「全文档最大页尺寸」（二选一，在 T5 首个提交时按真机效果定），避免过页边界时基准页切换导致 scale 跳变、全屏重排；若必须按页适配，则加 scale 迟滞阈值（变化 < 2% 不重算）。该决策与验收写入 T5。

### D6 删除跨页 strip 全族

删除 `seshat-reader-page-join-lines`、`--page-join-pixels`、`--page-image-specs`、`--join-strip-height`、`--join-strip-end`、`--remember-current-page-spec`、`--insert-join-strip`、`--remove-join-strip`、`--update-join-strip`、`--set-page-top-when-joined`、`--page-max-vscroll-pixels`、`--clamp-window-vscroll`、`--center-overlay`、`--ensure-center-overlay`，以及 `next-page` / `previous-page` / `first-page` / `last-page` / `goto-page` 里的 strip 调用。多页布局天然提供跨页上下文，上述机制的存在前提消失。迁移说明必须给出具体步骤：从 `custom-set-variables` 中删除 `seshat-reader-page-join-lines` 条目（否则老配置残留为 free variable，静默失效、无提示）；若希望更友好，可保留一个标记为 obsolete 的兼容变量并在首次使用时 `message` 提示。

### D7 多窗口与跨页选区

- 多窗口：接受「同内容、不同滚动位置」；`page` 参数降级为派生值（不再保证与显示一致），`docs/emacs-reader.md` 明写该行为变更。
- 跨页选区：首期 `user-error` 提示「暂不支持跨页选择」，单页内行为不变；`--text-in-rect` 等单页 API 调用不变。

## 任务

- [ ] T1 布局骨架：页行插入/移除、`seshat-reader--pages` 结构、`display` 属性承载 spec、`page-gap-lines`、可见集维护（进入/离开窗口时增删页）。验收：打开 PDF 后 buffer 内含 5 页行、滚动到页边界时第 6 页被插入、离开的第 1 页 spec 被回收（可断言 buffer 内 display 属性数）。（依赖：无）
- [ ] T1b 窗口与 overlay 管理重写：**分工边界**：T1b 只负责「每窗口 overlay 管理族」的删除/改写与布局骨架的建立（含去掉 strip 调用、重建 `--render-buffer` 的布局入口）；逐页居中、逐页 fit/重绘语义、`--native-page-size` 的按页缓存由 T4 完成——两者对 `--render-buffer`/`--first-fit`/`--native-page-size`/`--redisplay-all-windows`/dark-mode 的改动不得重复，T1b 只保证不悬空、T4 负责语义正确。D1 推翻了「每窗口一个 overlay」模型，必须整段重写或删除 `seshat-reader--manage-window-overlays`、`--window-create-function`、`--window-close-function`、`--handle-window-buffer-change` 及其 `window-configuration-change-hook` / `window-buffer-change-functions` 注册；`seshat-reader-current-doc-overlay` **定义保持原样、不删除**（T1b 只保证不悬空）；其**定义改造**（签名改 `(window &optional page)`、语义变为『读指定页的 spec』）与全部调用点改造**归 T4**；`--render-buffer` 去掉 `--update-join-strip` 与 `--page-image-specs` 清理，改为重建多页布局；`--first-fit` / `--native-page-size` / `--redisplay-all-windows` 按多页模型改造；dark-mode invert：**定为** C 侧 `--doc-invert`（文档级）后重渲染全部可见页（沿用既有 `--redisplay-all-windows` 改造），**不做** elisp 侧 spec 反色（`--page-image-spec` 无 invert 参数不影响该路径）。`seshat-reader-current-doc-overlay` 的**调用点**（`--get-current-doc-image-size` / `--page-image-spec` / `--center-page` / `--centered-p`，以及 `--get-prefix-width` 附近读 `--center-overlay` 的那一处（约 `seshat-reader.el:994`，属 T4 几何范畴））全部由 T4 改造；T1b 不得直接删除它，否则 T4 改造前会出现 void-function。验收：T1b 职责清单内的「每窗口 overlay」管理族（`--manage-window-overlays` / `--window-create-function` / `--window-close-function` / `--handle-window-buffer-change`）及其 hook 注册已删除或改写完成，grep 这四个函数名在 `seshat-reader.el` 中仅出现在注释/迁移说明里；**「全仓再无 `(window-parameter … 'overlay)` 读取」这一断言移到 T4 验收**（T1b 阶段 T4 职责函数尚未改造，此刻 grep 必然命中）。新窗口显示同一文档时正确建立布局；两个窗口可各自滚动。（依赖：T1）`seshat-reader--remember-current-page-spec` 的**调用点**（`next-page`/`previous-page`/`first-page`/`last-page`/`goto-page` 五处）随 strip 一并去掉；其**定义**由 T7 删除。
- [ ] T2 页号派生：`current-doc-pagenumber` 改视口顶页、`goto-page` 改 `set-window-start`、`--page-indicator` 与 mode-line 正常、`scale` 升 buffer 级。验收：滚到第 3 页时 `(seshat-reader-current-doc-pagenumber)` 返回 3；`M-g g` 跳到第 10 页后光标所在页为 10；outline 当前章高亮随之变化。（依赖：T1）
- [ ] T3 滚动命令重写：`scroll-up/down`、`-screen`、`mwheel`、`scroll-*-or-*-page`、`--at-page-top-p`、`--set-page-top/bottom`、`--set-window-vscroll`，并清理 `--page-max-vscroll-pixels` / `--clamp-window-vscroll` 的调用点（这两个函数在 T7 删除，T3 阶段若不清调用会悬空）。验收：向下滚到底后继续按 ↓ **不换页**，而是进入下一页内容的连续滚动；向上滚到顶同理；`SPC` / `DEL` 仍滚一屏。（依赖：T1、T2）
- [ ] T4 几何与居中：`seshat-reader-current-doc-overlay`（定义改造：签名改 `(window &optional page)`、语义变为『读指定页的 spec』）、`--get-current-doc-image-size`、`--page-image-spec`、`--center-page`（逐页 `before-string`/`:align-to`）、`--centered-p`、`--ensure-centered`、`--recenter-window`、`--right-most-window-hscroll`（按可见页宽）。验收：多页同时可见时每页各自水平居中；窗口尺寸变化后所有可见页在同一帧内重新居中；超宽页不再出现（统一 scale）；`seshat-reader-presentation-mode` 的行为按 T5 决策落地（单页全屏或整屏缩放），进入/退出后布局与缩放正确。同时覆盖：`--render-buffer`（重建布局而非单页 overlay）、`--first-fit`（首屏对全部可见页生效）、`--native-page-size`（按页缓存改为 alist）、`--redisplay-all-windows`（遍历窗口重绘可见页）、`seshat-reader-dark-mode`（反色后全部可见页重渲染）。本任务完成后全仓 grep `(window-parameter [^)]*'overlay` 应无读取点（仅允许出现在注释/迁移说明）。（依赖：T1、T1b、T2、T3）
- [ ] T5 缩放与 refit：`--apply-display-scale` 批量、`--refit-window` 重渲染可见页、`render-scale` 按页、`fit-mode` 基准页。验收：`W`/`H`/`+`/`-` 后所有可见页同步缩放；窗口 resize 后可见页全部清晰化（不只当前页）；`fit-mode` 语义不变；**滚动跨过页边界时 scale 不跳变**（基准页锚定策略生效）。（依赖：T4）
- [ ] T6 缓存与虚拟化：动态上限、视口优先淘汰、预取 1 页、内存告警线。验收：连续滚动 30 页时缓存长度始终 ≤ 可见页数+1；**往回滚 1 页**命中缓存（不调 C）；P0 的「顺序扫 20 页命中率 0」问题不复现。（依赖：T1、T3、T4）
- [ ] T7 删除 strip 全族（D6 清单）并清理相关 tech-debt 条目（912/1036 等）。验收：全仓 grep 无 `page-join-lines` / `--join-strip` / `--page-max-vscroll-pixels` 残留；`page-join-test.el` 删除或整体重写。（依赖：T3、T4）
- [ ] T8 外围适配：① 选区 `posn→page` 加「页号反查 + 页内 y 偏移」，跨页拖选 `user-error`；② 书签/saveplace 从 `vscroll` 改为「页号 + 页内像素偏移」（或直接存 buffer position）；**同时处理 `hscroll` 字段**（`seshat-reader-bookmark.el` 的 record 含 `hscroll`；统一 scale 后不再有「单页超宽横滚」，建议删除该字段并给旧记录的迁移规则：读到旧 `hscroll` 时忽略、按居中/左对齐重算）；③ 搜索 `goto-page` 语义复核（跳转后停在页首）；④ 高亮刷新范围扩到全部可见页（若需 C 改动则显式列出并评估）；⑤ `seshat-reader-select-drag` 的 `select-window` 假设复核。验收：单页内框选建批注坐标正确；跨页拖选给出明确提示；书签保存/恢复落到同一页同一偏移；搜索跳转后停在命中页。（依赖：T2–T5）
- [ ] T9 测试重写与新增：`page-join-test.el`（26 例，24 例作废）删除/重写；`resize-test.el` **80 例**（实测，其中约 55 例需改写断言、其余可保留）按「多页 + 批量 scale」改写；新增 `seshat-reader-multipage-test.el`（布局/页号派生/虚拟化/滚动边界 ≥15 例）；从零补 `posn→page` 用例（当前零覆盖）≥4 例。另需同步改写 P0 的 `seshat-reader-page-spec-test.el`（13 例）中受 D4 缓存策略与 T1b/T4 改造影响的用例：`--cache-drops-the-oldest-entry`（FIFO → 视口优先）、`--does-not-touch-window-state`（窗口参数语义变化）、`--render-buffer-drops-cache`（`--render-buffer` 重建布局）。验收：全仓 `unexpected = 0`、`skipped = 0`；新增用例覆盖 D1–D7 每条决策。（依赖：T1–T8）
- [ ] T10 文档与归档：`docs/architecture.md`（布局模型整章改写）、`docs/emacs-reader.md`（键位语义变化：↓ 不再换页、`n`/`p` 仍整页；多窗口语义变更；跨页选区限制）、`docs/configuration.md`（新增 `page-gap-lines`、删除 `page-join-lines` 条目并给迁移说明：迁移说明必须给出具体步骤：从 `custom-set-variables` 中删除 `seshat-reader-page-join-lines` 条目（否则老配置残留为 free variable，静默失效、无提示）；若希望更友好，可保留一个标记为 obsolete 的兼容变量并在首次使用时 `message` 提示）、`VENDORED.md`、`CHANGELOG.md`（行为变更段）、`decisions.md`（补 P1 落地记录）、`tech-debt.md`（勾销失效条目、登记新缺口）、`roadmap.md`（P1 ✅）；计划归档。验收：新人仅凭文档能理解连续滚动布局与键位语义。（依赖：T1–T9）

## 文档清单

| 文档 | 需同步内容 |
|---|---|
| `docs/architecture.md` | 「跨页衔接」整节替换为「多页连续布局」：buffer 结构、页 marker、可见集与虚拟化、页号派生、滚动原语 |
| `docs/emacs-reader.md` | 键位表（`↓`/`SPC` 语义变化、`n`/`p` 保持整页）、多窗口语义变更、跨页选区限制、已知限制更新 |
| `docs/configuration.md` | 新增 `seshat-reader-page-gap-lines`；删除 `seshat-reader-page-join-lines`（给迁移说明：改用连续布局后无需该开关） |
| `emacs/seshat-reader/VENDORED.md` | `seshat-reader.el` 条目追加 P1 改动（布局、页号派生、虚拟化、删除 strip） |
| `CHANGELOG.md` | `### 变更`（行为变更）+ `### 破坏性`（`page-join-lines` 移除、`↓` 语义变化、多窗口语义变化） |
| `openspec/decisions.md` | 补 P1 落地记录与实测（首屏时间、滚动流畅度、内存） |
| `openspec/tech-debt.md` | 勾销因改造失效的条目（strip 裁切、strip spec 旧尺寸、vscroll 下界、居中两套机制等）；登记 P1 遗留（异步预取未做、跨页选区未做、宽页统一 scale 的取舍） |
| `openspec/active/roadmap.md` | P1 状态改 ✅ 并指向归档计划 |

## 验证标准

- **L1**：`elisp_check_parens`（emacs-lisp-mode 侧）+ `make -C emacs/seshat-reader clean all` EXIT 0、warning 数不超过基线、checkdoc 0 报错。
- **L2**：`emacs/tests/` 逐文件 ERT（带完整 `-L` 依赖路径），`unexpected = 0`、`skipped = 0`；重写后的 `resize-test` 与新增 `multipage-test` 全绿。
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
9. **`seshat-reader-presentation-mode` 语义待定**：`seshat-reader-presentation-mode` 在多页布局下保留「单页全屏」语义（进入时 fit-to-height 且只显示当前页），或降级为「整屏缩放」，二选一并在 T4 验收里体现。
