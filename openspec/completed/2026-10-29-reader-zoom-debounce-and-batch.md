# 阅读器缩放去抖与批渲染自适应（fit-width 卡顿优化）

## 当前状态

- 状态：**已完成（2026-10-30）** —— 本文件已归档在 `openspec/completed/`（原位于 `openspec/active/` 下同名文件；T1–T5c 全 `[x]`）。
- 来源：用户 2026-10-29 真机验收反馈（P2-B 与双窗口计划之后）——「fit-width 卡顿时间较长」「连按缩放卡顿特别明显」
- 前置：P2-B（两阶段异步渲染）与双窗口独立滚动均已归档
- 交付摘要：① **批渲染按页面积自适应**（T1，`seshat-reader-render-batch-area-threshold` 默认 800000 px²）——大页单轮渲 1 页，单轮最长停顿 ~100 ms → ~50 ms；② **manual 缩放去抖**（T2 / T3，`seshat-reader-zoom-refit-delay` 默认 0.2 s + `seshat-reader-zoom-refit-enabled` 回滚口）——连按 5 次由 5 轮整页渲染降为 1 轮，scale / 页尺寸 / 居中仍同步写入，`W` / `H` / `0` 保持同步；③ **缩放内存泄漏修复**（T5 / T5b / T5c，T4 真机暴露的既有缺陷）——resize 快照 + `insert-page` 旧 spec 回收 + 每次 `--multipage-sync` drain（早退分支也 drain）+ `seshat-reader-image-cache-budget-mb`（默认 512 MB，超预算清当前 frame）；同批 clamp 上限 **11.0 → 6.0**、`image-cache-eviction-delay` **300 s → 30 s**。
- 真机结论（用户 2026-10-30 回报）：**fit-width 有改善、缩放去抖生效、image cache 从 2125 MB 降到 224 MB（−89%）、接受当前状态**。
- 最终验证口径：**L2 = 47 文件 / 1634 例，0 unexpected / 0 skipped**，`check-criteria` PASS；L1 `make -C emacs/seshat-reader clean all` EXIT 0、C 0 error 0 warning、elisp `Warning:` 20 = 基线、checkdoc 仅 1 条既有告警（`seshat-reader-annotation-queue.el:290`）。
- 剩余（已登记 `openspec/tech-debt.md`）：`--page-spec-remember` 淘汰孤儿（剩余 ~200 MB 来源之一）、选区 `posn` 口径不对称（`seshat-reader-select.el:938`）、高亮（`'line`）与复制（矩形）口径不一致；`Blocking call to accept-process-output with quit inhibited` 已定位为 Emacs 异步 native-comp 的 sentinel，与阅读器无关。
- 执行顺序（全 ✅）：**T1**（批次 1，见「T1 执行记录」）→ **T2**（实现 + 8 例验收用例）/ **T3**（6 例迁移）→ **T4**（文档 6 处 + 真机 6 项）→ **T5**（内存泄漏：快照 + rerender flush）→ **T5b**（几何路径孤儿 + 兜底两行）→ **T5c**（`insert-page` 换对象漏记 + sync drain + 512 MB 兜底）。

> **行号口径**：本文件行号为 2026-10-29 在 `emacs/seshat-reader/seshat-reader.el`（5772 行；T1 落地后为 5842 行；T2+T3 落地后为 6012 行；T5 落地后为 6099 行；T5b 落地后为 6224 行；T5c 落地后为 6302 行）实测；后续改动会让行号继续漂移，**一律按函数名 `grep` 定位**，不要照抄行号跳转。
> **批次口径**：批次 1 = 乙（batch 面积自适应，T1）；批次 2 = 甲（缩放去抖，T2–T4）。两批各自建 git 安全点、各自独立可回滚，**不跨批回滚**。

## 目标

1. **批次 1（乙）**：`render-idle-batch` 按页面积自适应 —— 大页（fit-width / 扫描书）单轮渲染 1 页，小页（letter）仍 2 页；把单轮最长停顿从 ~100 ms 压到 ~50 ms。
2. **批次 2（甲）**：连按缩放去抖 —— 连按期间只更新尺寸（同步）与排队一次重渲染（延后），把「连按 5 次 = 5 轮整页渲染」降为 1 轮。**作用域仅 manual 缩放**（`+` / `-` / `=` / `C-<wheel-up|down>`）；`W` / `H` / `0` 保持同步渲染。
3. 不破坏既有契约：scale / 窗口参数 / spec 尺寸 / 居中的写入仍**同步**完成（选区与书签模块依赖命令返回时已就位）。

## 非目标（明确不做）

| 不做 | 理由 |
|---|---|
| 低清预览 → 停手高清（方案丙） | 需新增「预览/目标」两档状态，与 `--page-render-scales` 单值模型冲突（低清会让 refit 闸判定「不清晰」反复重渲，或记目标 scale 则永远停在低清）；收益与去抖重叠、风险更高 |
| 改 refit 路径 / 共用 `--resize-refit-timer` | 会引入三个静默退化（`--layout-frozen-p` 在 minibuffer 打开时不排 timer、`--resize-refit-enabled` = nil 时不排、`--refitting` 期间静默返回） |
| 改 C 侧 / 渲染分辨率语义 | 与本项正交；`fz_clamp(scale*72, MINRES, MAXRES)` 已是唯一旋钮 |
| 改 `--multipage-set-scale` 的同步写入（base scale / 窗口参数 / spec 尺寸 / 居中） | 选区（`seshat-reader-select.el`）与书签（`seshat-reader-bookmark.el`）依赖这些值在命令返回时就已就位 |
| 不对 `W` / `H` / `0` 去抖 | 它们是「一次性切换 fit 模式」，用户期望立即清晰；全部去抖会引入计划外的新行为变更（`0` 还会重置 fit 模式）。用户 2026-10-29 显式确认：只对 manual 缩放去抖 |

## 背景与第一性依据

**事实（已查证，带行号；行号 2026-10-29 实测，后续会漂移，按函数名 `grep` 定位）**

| # | 事实 | 依据 |
|---|---|---|
| F1 | 缩放链路：键（`5103-5113`）→ `--multipage-zoom`（`603`）→ `--multipage-set-scale`（`514`）→ 写 `--multipage-base-scale`（`543`）→ 写各窗口 `scale` 参数（`550-554`）→ `--apply-display-scale`（`555`，只改 `:width`/`:height` 不重渲染）→ `--center-page`（`556`）→ **逐页重渲染**（`557-558`，`--multipage-refit-page` `2436` → `--multipage-rerender-page` `2373` → `--page-spec` `1249`）→ `--multipage-sync`（`559`） | 实测 |
| F2 | **缩放不清缓存、不自增代际**：`--page-spec-clear-cache`（`1336`，唯一代际自增点）的调用点只有 rotate / close-doc / `--render-buffer` / `--redisplay-all-windows` 四处；缩放走单页粒度 `--multipage-forget-specs`（`1888`，注释明确「单页回收不得自增代际」） | 实测 |
| F3 | 每次缩放对**全部常驻页**各重渲染一次（常驻集 = 视口页 + preload 2×2，`1562`，上限 3 `963`），再加 sync 的 2 页 | 实测 |
| F4 | `render-idle-batch`（`1489`）唯一读取点 `--async-render-batch`（`2944`）的 `2972`；循环 `2976` 可中途退出（`attempted` 上限 / `invalidated` 代际） | 实测 |
| F5 | 页面积可零成本获得：`--multipage-page-display-size`（`1601`，优先 spec `:width`/`:height`、回退 `--multipage-page-cached-size` `1585`），各一次 **O(n) 小规模查找**（`--multipage-page-cached-size` 是 `dolist` + `throw`，**不是 `assq`**）；n = 页尺寸缓存条目数（常驻页量级），故仍是零成本 | 实测 |
| F6 | fit-width 位图面积 ≈ fit-height 的 `(W_win·native_h / (H_win·native_w))²` 倍；A4 + 1000×800 窗口 ≈ **2.62 倍** | 公式 + S1 分桶佐证 |
| F7 | S1 实测：扫描书单页 p50 19.05 / p95 49.45 / max 51.85 ms；letter p95 8.34 ms ⇒ `batch=2` 单轮最长 ~100 ms | P2-B 归档计划「S1 耗时分布」 |
| F8 | 已有去抖范式 `--schedule-refit`（`4407`）：`cancel-then-rearm` + `run-with-idle-timer 0.15 nil #'--run-pending-refit buffer`（`4423-4425`）+ `--refitting` 防重入（`144`）；回调 `--run-pending-refit`（`4427`）遍历 `get-buffer-window-list buffer nil t` 逐窗口 `--refit-window` | 实测 |
| F9 | `--multipage-set-scale` 的 docstring 明确「refit is synchronous on purpose … leaving the bitmap stretched until an idle timer fires shows a blurry page」——同步是 P1 的**故意**选择 | 实测 |
| F10 | `--multipage-sync`（`3268`）有区间相等早退 `(equal range (--multipage-last-range-for win))`；配套读写在 `2253` / `2269`，全窗口清在 `2282`（`--multipage-clear-last-ranges`，遍历 `get-buffer-window-list`） | 实测 |
| F11 | daemon 下一个 idle 窗口只 fire 一次（P2-B 的 G3b 实测）；batch 下 timer 不 fire ⇒ ERT 必须桩 `run-with-idle-timer` | P2-B 归档计划 |
| F12 | `--multipage-set-scale` 签名 `(base &optional source mode)`（`514`），**全部 7 处调用点**：manual 侧 = `--multipage-zoom`（`610`，传 `(or source 'manual)` + `'manual`；`=` / `+` / `-` / `C-<wheel-up>` / `C-<wheel-down>` 全走它）与 `seshat-reader-bookmark-jump`（`seshat-reader-bookmark.el:129`，传 `'manual 'manual`）；fit 侧 = `reset-size`（`647`）、`fit-to-height`（`664`）、`fit-to-width`（`679`）、书签 fit 分支（`bookmark.el:127`）、presentation-mode 退出（`5728`）——全部传 `'fit`。**`mode` 不可用作判据**：presentation-mode 退出路径的 `mode` 来自 `--multipage-current-fit-mode`（`753`），而 manual 缩放会把 buffer-local `--multipage-fit-mode` 设成 `'manual`，按 mode 判会把一次「同步恢复视图」误去抖 | 实测 grep |
| F13 | `--refit-window`（`4451`）函数体 = `--apply-display-scale` + 逐页 `--multipage-refit-page` + `--center-page`，**不含 `--multipage-sync`**；且入口 `when` 硬编码 `(not (--layout-frozen-p))`（`4476`） | 实测 |
| F14 | `--multipage-resize-spec`（`1916`）尺寸未变时返回 nil ⇒ `--apply-display-scale`（`900`）**幂等**，可重复调用（代价 = 遍历常驻页 ≤5，不渲染） | 实测 |
| F15 | 去抖 timer 与 async 渲染队列的互斥性：`--multipage-async-rendering`（`2583`）只防 **tick 自身重入**（`--async-render-tick` `3015` 的 `cond` 首支）；队列**与 scale 无关**——`--async-render-batch` docstring 明确「the scale is re-derived … so a page is rendered at the geometry that holds now rather than the one it was queued at」（`2944`） | 实测 |

**第一性拆解（从 F1–F7 直接推出，不是类比）**

| 量 | 表达式 | 代入 S1 实测 |
|---|---|---|
| 单轮停顿 | `batch × 单页渲染耗时` | 大页 `2 × ~50 ms` = **~100 ms**（letter `2 × 8.34 ms` ≈ 17 ms，故只有大页有问题） |
| 连按 N 次的渲染次数 | `N × 常驻页数` | N=5、常驻 5 页 ⇒ **25 次**渲染，其中 24 次被最后一次覆盖（纯浪费） |

两条独立的乘数 ⇒ 两个独立旋钮：**降 `batch`（乙）** 削第一个乘数，**去抖（甲）** 把 N 折成 1 削第二个乘数。二者互不依赖，可分批交付（这也正是「先乙后甲」的依据）。

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| H1 | 面积阈值能有效区分大页/小页（面积与耗时相关但**非线性**，故用保守阈值 + 可调 defcustom，不做精确预算） | 假设? |
| H2 | 去抖回调与 `--refit-window` 的逻辑**平行但不等价**：回调多一步 `--multipage-sync`、且**不查** `--layout-frozen-p`，因此不能复用（约 10 行重复，以注释说明理由）——复审 M2 修订，原「可直接调 `--refit-window`、零重复逻辑」已推翻（F13：它无 sync、含冻结守卫） | 事实✓（F13 / F10） |
| H3 | 去抖只延后像素、不延后 scale 写入，不会破坏选区/书签 | 事实✓（F1 的同步四步保留 + 陷阱 1 的依赖点表） |
| H4 | 0.2 s 去抖延迟足够覆盖连按间隔（用户连按通常 <200 ms） | 类比⚡（refit 用 0.15 s） |
| H5 | 用户可接受「缩放期间旧像素按新尺寸拉伸（短暂模糊），停手 0.2 s 后清晰」 | 用户显式（Phase 1 方案确认） |

> H1 与 H4 是**待真机回填**的两条：T4 的真机第 ② 项同时验证 H4（0.2 s 是否够）与 H5（模糊是否可接受）；H1 的阈值在真机后按实际耗时分布调整，**不做提前优化**。

## 设计决策

- **D1 批次 1：batch 按面积自适应**。在 `--async-render-batch`（`2972`）计算 `batch`：取本轮待渲页的 `--multipage-page-display-size`，若**任一页**面积 ≥ 阈值则 `batch` = 1，否则沿用 `seshat-reader-render-idle-batch`。新增 defcustom `seshat-reader-render-batch-area-threshold`（默认 `800000` px²；letter@1.0 ≈ 484k、A4 fit-width ≈ 1.29M）。**不改循环体**（F4）。**nil 面积口径**：`--multipage-page-display-size` 对无行 / 未测量页返回 nil（其 docstring：「nil means the size is unknown, i.e. a page that was neither rendered nor measured」）⇒ 本轮待渲页里只要有一页面积为 nil，就按**保守 `batch=1`** 处理（宁可慢一页，不可顿一下）；实现上把 nil 当「≥ 阈值」处理，不写额外分支。
- **D2 批次 2：缩放去抖只延后像素，且只对 manual 缩放生效**。`--multipage-set-scale` 保留 F1 的 `543` / `550-554` / `555` / `556` 四步同步；`557-558`（逐页重渲染）与 `559`（sync）改为「登记 + 排 timer」——**仅当 `(eq source 'manual)`**；`source` 为 `'fit` 或 nil 时**原样走现有同步路径**（一个 `if` 分支，不新增函数、不动函数体其余部分）。
  - **作用域判定条件（实测依据见 F12）**：`(eq source 'manual)`。manual 侧全部经 `--multipage-zoom`（`610` 传 `(or source 'manual)`）或书签 `'manual 'manual`；fit 侧（`W` / `H` / `0` / 书签 fit 分支 / presentation-mode 退出）全部传 `'fit`。**不用 `mode` 判定**（F12：presentation-mode 退出路径的 mode 可能是 `'manual`）。`source` = nil（当前无调用方）按 fit 处理，保守同步。
  - 因此：manual ⇒ 延后 `557-559`；fit / nil ⇒ 同步（走现有路径，行为零变化）。
- **D3 独立 timer + 独立门禁 + 回调自写重渲序列**：新增 buffer-local `--zoom-refit-timer` 与 `--zoom-refitting`，**不复用** `--resize-refit-timer` / `--refitting` / `--resize-refit-enabled` / `--layout-frozen-p`（F8 + 非目标：共用会引入三个静默退化）。新增 defcustom `seshat-reader-zoom-refit-delay`（默认 0.2）。
  - 回调**自写**一个精简重渲序列（D5 的 3a–3d），**不调用 `--refit-window`**，也**不查 `--layout-frozen-p`**。理由：缩放是用户主动命令，minibuffer 打开时按 `+` / `-` 也应生效——与 `--refit-window` / `--schedule-refit` 的「被动几何适配」语义不同（那两个由窗口尺寸变化被动触发，冻结是为了不打断 prompt 的布局）。若回调查冻结，minibuffer 打开时按 `+` 会静默停在「尺寸对、像素旧」且无任何提示，正是本计划要避免的退化。
  - 代价（诚实记账）：回调与 `--refit-window` 逻辑**平行但不等价**（多一次 `--multipage-sync`、不查冻结），约 10 行重复，**在回调 docstring 里写明为何不能复用**（H2 已按此修订）。
- **D4 回调前清 `last-range`（所有窗口）**：回调执行时先调 `--multipage-clear-last-ranges`（`2282`；F10：否则 sync 因区间未变早退，占位页永不补像素）。**不能用 `--multipage-sync-blocking` 的 `force`**：`force` 只对**传入的那一个窗口**生效（`3178`；跳过该窗口的区间相等早退且不写回，`3230-3240`），多窗口时另一窗口仍会早退、占位页永不补像素。`--multipage-clear-last-ranges` 遍历 `get-buffer-window-list` 清全部窗口，正是所需口径。
- **D5 回调口径：自写精简重渲序列（不照抄 `--refit-window`）**。完整有序步骤如下（顺序即实现顺序，`buffer` = timer 捕获的 buffer）：
  1. `(when (buffer-live-p buffer) (with-current-buffer buffer …))` → `derived-mode-p 'seshat-reader-mode` 守卫 → 清 `--zoom-refit-timer`（置 nil）→ `(let ((--zoom-refitting t)) …)`。
  2. **`--multipage-clear-last-ranges`**（`2282`）—— 清**所有**窗口的 last-range（不能用 `--multipage-sync-blocking` 的 `force`，那只覆盖单窗口，见 D4）。
  3. `(dolist (window (get-buffer-window-list buffer nil t)) …)` 逐窗口，顺序固定为：
     a. `--apply-display-scale`（`900`；按当前 base scale 改写 spec `:width`/`:height`，不渲染；幂等 F14）
     b. `(dolist (page (--multipage-page-numbers)) (--multipage-refit-page page window))`（`2436`；只重渲分辨率不匹配的常驻页，闸值 `--refit-scale-tolerance`）
     c. `--center-page`（`4228`；按行宽居中 / 超宽左对齐）
     d. `--multipage-sync`（`3268`；拉入占位页 + 同步 point 页）
  - **不复用 `--refit-window`**：它不含 sync（F13），且函数体内硬编码 `(not (--layout-frozen-p))` 守卫（`4476`）——会引入 D3 要避免的静默退化。
  - 顺序理由：a 幂等（F14），负责把「命令返回 → timer 触发」这段时间窗里可能发生的几何漂移（另一个窗口 resize、`goto-page` 重建的占位行）拉回当前 base scale；c 必须在 a 之后（居中按行宽判定，行宽来自 a 改写的 spec）；d 必须最后——它要与原 `557-558` → `559` 的顺序完全一致（b 重渲像素、d 再拉占位页），且它会把本轮区间写回 `last-range`，若 d 先跑则第 2 步的清 `last-range` 就白清了（d 写回后 b 的重渲不会重置它）。
- **D6 开关**：新增 `seshat-reader-zoom-refit-enabled`（默认 t），`nil` 时完全回到同步行为（回滚口 + L2 等价性对照分支）。开关判定放在 D2 的同一处 `if` 上：`enabled` = nil ⇒ 走同步路径。

## 任务

- [x] **T1 批次 1：batch 面积自适应**｜改哪里：`--async-render-batch`（`2944`，`batch` 绑定 `2972`）+ 新增 defcustom `seshat-reader-render-batch-area-threshold`（`:type 'number` / `:group 'seshat-reader`）｜验收：新增 `--batch-adapts-to-page-area`（桩 `--multipage-page-display-size` 喂大/小面积：大页单轮渲 1 页、letter 渲 2 页；**含 nil 面积 ⇒ batch=1** 的断言）；既有 `--tick-renders-one-batch`（`seshat-reader-multipage-async-render-test.el:278`）、`--batch-default-is-two`（同文件 `297`）仍绿；**变异**：把面积判定去掉（恒用 defcustom 2）⇒ 新用例转红｜依赖：无｜风险：低
- [x] **T2 批次 2：缩放去抖骨架**（**实现 + 8 例验收用例均已落地**，见「T2+T3 执行记录」与「T2 验收用例 + 变异」）｜改哪里：`--multipage-set-scale`（`557-559`，加 D2 的 `(eq source 'manual)` 分流）+ 新增 timer / 回调（D5 的 1–3 步）/ 2 个 defcustom（`seshat-reader-zoom-refit-delay`、`seshat-reader-zoom-refit-enabled`）｜验收：新增 8 例——①`--zoom-debounce-collapses-burst`（连按 3 次 `+`，timer 未 fire 前渲染计数 0、`base-scale` 已是 1.25³、spec 尺寸已按最终 target 改写）；②`--zoom-debounce-fires-once`（fire 一次后每常驻页恰渲一次 + `seshat-reader-multipage-test--all-sharp-p`）；③`--zoom-debounce-cancels-on-new-keypress`（两次按键之间只留 1 个 timer，照 `seshat-reader-resize-test.el:277` 的 cancel 计数口径）；④`--zoom-debounce-survives-goto`（未 fire 时 `goto-page` 到远处页 ⇒ 回调只渲染新视口页）；⑤`--zoom-debounce-cancelled-on-kill-buffer`（kill 后不报错、不留 timer）；⑥`--zoom-debounce-disabled-stays-synchronous`（**D6 等价性**：`zoom-refit-enabled` = nil ⇒ 命令返回时渲染计数 = 常驻页数、无 timer，与改造前一致）；⑦`--zoom-debounce-refits-every-window`（**多窗口**：两窗口，去抖回调后两个窗口的常驻页都重渲；**变异**：回调只处理 selected-window ⇒ 该例转红）；⑧`--zoom-fit-stays-synchronous`（**M3 作用域**：`W` / `H` / `0` 返回时渲染计数 = 常驻页数、无 timer；**变异**：去掉 `(eq source 'manual)` 判定（全部去抖）⇒ 该例转红）。**docstring 同步更新**：`--multipage-set-scale`（`514`，含 `515-541` 的「refit is synchronous on purpose」整段改为两段式——manual 去抖 / fit 同步）、`--multipage-zoom`（`603`）、`seshat-reader-enlarge-size`（`615`）、`seshat-reader-shrink-size`（`625`）的「synchronously」表述；`seshat-reader-reset-size`（`633`）/ `fit-to-height`（`649`）/ `fit-to-width`（`666`）的「synchronously / keep it sharp / sharp as soon as the command returns」表述**保留**（fit 路径仍同步），但各加一句区分「fit 同步、manual 去抖」。**变异**：把去抖改回同步 ⇒ `collapses-burst` 转红；把回调前的清 `last-range` 去掉 ⇒ `survives-goto` 或 `fires-once` 转红｜依赖：无（与 T1 不同函数，可并行；**建议串行**以简化安全点）｜风险：**中高**
- [x] **T3 既有用例迁移**｜改哪里：`emacs/tests/seshat-reader-multipage-test.el` 的 6 例——`--geometry-enlarge-multiplies-base-scale`（`1807`）、`--geometry-shrink-multiplies-base-scale`（`1848`）、`--geometry-fit-to-width-uses-reference-page`（`1913`）、`--geometry-fit-to-height-uses-reference-page`（`1941`）、`--geometry-mwheel-zoom-same-as-keys`（`1966`）、`--geometry-manual-zoom-refits-visible-pages-once`（`2032`）｜验收：上述 6 例**改为「命令返回后断言尺寸/模式/scale，再手动 fire 去抖回调后断言渲染计数与 `all-sharp-p`」**；**不得改断言语义**（只拆成两段）。`--geometry-reset-size-re-fits-like-first-fit`（`1874`，只断尺寸）与 `--geometry-zoom-clamps-at-renderer-bounds`（`2186`，只断 base clamp）**不改**（它们走 fit / clamp 路径，仍同步）｜依赖：T2｜风险：中
- [x] **T4 文档 + tech-debt + 真机**｜改哪里：见「## 文档清单」逐项落地｜验收：真机四项——① fit-width 连续滚动 30 页顿挫改善；② 连按 `+`/`-` 5 次期间可接受模糊、停手 0.2 s 内清晰；③ 缩放后选区/书签位置正确（命令返回即生效，按陷阱 1 的依赖点表逐项对照）；④ `render-async` = nil + `zoom-refit-enabled` = nil 时行为与改造前一致｜依赖：T1–T3｜风险：低（**不做则验收必然不通过**）｜**已执行（2026-10-30）**：文档 6 处（`docs/configuration.md` 4 个 defcustom 表项 + 说明 5 条 / `docs/emacs-reader.md` 表格与 §7 两小节 / `CHANGELOG.md` 两条修复 / `openspec/decisions.md` 2026-10-29 一条 + 2026-10-30 六条 / `openspec/tech-debt.md` §4 勾销 + `:1089` 作废 + 新增 4 条 / `openspec/roadmap.md`）+ 真机 6 项通过（用户回报：fit-width 有改善、缩放去抖生效、内存从 2125 MB 降到 224 MB、接受当前状态）；剩余 `--page-spec-remember` 孤儿与选区两项已登记 tech-debt
- [x] **T5 缩放内存泄漏修复（T4 真机发现，既有缺陷）**｜根因（只读分析已确认）：缩放每落到新 scale 就为每个驻留页新建 canvas 缓冲，而 `--multipage-forget-specs` / `--page-spec-clear-cache` **只丢 Lisp 引用**（reader 全仓 **0 处 `image-flush`**），旧尺寸位图只能等 `image-cache-eviction-delay`（默认 300 s）自然淘汰；量化：基准 scale 1.245 单页 3.0 MB，`+`×5 后 scale 3.80 单页 **28.0 MB**，常驻 5–6 页 = 140–168 MB，去抖关闭时峰值 ≈ 440 MB；且 `--multipage-resident-spec-megabytes` 只统计 `--page-spec-cache`（≤6 条）⇒ **75 MB 告警永不触发**｜改哪里：新增 `--multipage-spec-in-use-p`（行引用守卫，遍历 `(cddr entry)` 按 `eq` 比对）+ `--multipage-rerender-page` 在 **`--multipage-forget-specs` 之前**存旧 spec、在**新 spec 写入行之后** `(ignore-errors (image-flush old))`；新增 `--image-cache-megabytes`（`image-cache-size` 包装），`--multipage-check-memory` 的 message/docstring 改为「spec 缓存 X MB + image cache Y MB」双口径；`--page-spec-clear-cache` docstring 写明全量路径**有意不 flush**｜验收：新增 4 例（`--geometry-rerender-flushes-the-old-spec` / `--geometry-rerender-keeps-a-shared-spec` / `--geometry-rerender-survives-flush-failure` / `--geometry-memory-warning-reports-image-cache`）；**变异**：去掉守卫 ⇒ `keeps-a-shared-spec` 转红；去掉 flush 调用 ⇒ `flushes-the-old-spec` + `survives-flush-failure` 转红｜依赖：无（与 T1–T4 不同代码路径）｜风险：**中**（flush 命中仍在显示的 spec 会强制整页重解码，历史上逐帧 flush 曾致拖拽卡 1–2 s ⇒ 守卫不可省；clamp 值 0.25–11.0 **不改**）｜**后续追加两批（2026-10-30）**：T5b ✅（真机复验仍见 1726 MB 孤儿 ⇒ 几何路径快照 + 兜底两行；**clamp 上限改为 6.0**、`image-cache-eviction-delay` 改为 30 s，故上文「clamp 不改」已被推翻）与 T5c ✅（`--multipage-insert-page` 换对象路径漏记 ⇒ 登记旧 spec + sync 三处 drain + 512 MB 兜底），见文末「T5b 执行记录」与「T5c 执行记录」

## 陷阱

1. **绝不能延后 scale 写入**：`543` / `550-554` / `555` / `556` 必须同步完成——选区与书签依赖命令返回时值已就位；去抖只能延后「像素」（`557-559`）。具体依赖点（`grep -n "base-scale\|window-parameter.*scale\|scale-source" emacs/seshat-reader/seshat-reader-select.el emacs/seshat-reader/seshat-reader-bookmark.el` + 上游 `seshat-reader-current-doc-scale-value` 实测得出；T4 真机 ③ 按此表逐项对照）：

   | 依赖点 | 位置 | 读什么 | 为什么必须同步就位 |
   |---|---|---|---|
   | `seshat-reader-current-doc-scale-value` | `seshat-reader.el:248` | `--multipage-base-scale` → 窗口参数 `scale` 镜像 → `--recent-scale-fallback` | 缩放命令返回后立刻被选区/书签读；延后写 base scale 会让换算用旧值 |
   | `seshat-reader-select--page-spec` | `seshat-reader-select.el:755` | `(cddr (assq page seshat-reader--pages))` 的 spec | 取 spec 的 `:width`/`:height` 作为显示尺寸 |
   | `seshat-reader-select--page-native-size` | `select.el:773` | `--multipage-native-size`（buffer-local 表） | 除法的分母 |
   | `seshat-reader-select--display-scale` | `select.el:790` | spec `:width`（或 `:height`）÷ native | **断言点**：spec 尺寸必须已是新 scale 的尺寸（`555` 步），否则显示 scale 与 base scale 分叉 |
   | `seshat-reader-select--page-scale` | `select.el:837` | 上者，回退 `current-doc-scale-value` | 拖选主入口的 scale 来源 |
   | `seshat-reader-select-posn-page` / `--posn-page-extent` / `--page-space-size` | `select.el:870` / `1060` / `1095` | 上面的 scale | 把显示像素换算回页坐标（scale 错 ⇒ 选区位置错） |
   | `seshat-reader-bookmark-make-record` | `seshat-reader-bookmark.el:65` | 写 `(cons 'scale (seshat-reader-current-doc-scale-value))` | 加书签时记录当时的 scale |
   | `seshat-reader-bookmark-jump` | `bookmark.el:106` / `127` / `129` | 读记录的 `fit-mode` / `scale`，新开文档时调 `--multipage-set-scale` | 新开文档走 `'fit`（同步）；同 buffer 内跳转不动缩放 |

2. **回调前必须清 `last-range`，且必须清所有窗口**（F10 / D4）：否则 sync 因区间未变早退，占位页永不补像素（表现为「缩放后某些页永久背景色」）。`--multipage-sync-blocking` 的 `force` 只作用于单窗口，多窗口场景不可替代 `--multipage-clear-last-ranges`。
3. **不要共用 refit 的 timer / 门禁**（F8 + 非目标）：`--layout-frozen-p`（minibuffer 打开）、`--resize-refit-enabled`（用户关掉 resize refit）、`--refitting`（refit 执行中）三者任一命中都会让缩放静默停在「尺寸对、像素旧」。
4. **多窗口**：回调必须遍历 `get-buffer-window-list buffer nil t`（所有 frame），不能只处理 selected-window（用例 ⑦ 的变异专测这条）。
5. **ERT 必须桩 timer**：batch 下 timer 不 fire（F11）；仓库已有三处先例（`seshat-reader-resize-test.el:277`、`seshat-reader-fit-window-test.el:310`、`seshat-reader-multipage-async-render-test.el:278`）。
6. **`--geometry-manual-zoom-refits-visible-pages-once` 的语义**：它断言「再放大一次只多渲染 3 次」，迁移时若改成「fire 两次」会掩盖「重复渲染」缺陷——务必保留「恰好一次」的计数断言。
7. **去抖 timer 与 async 渲染周期 timer 的交互：不互斥，但安全**（F15 实测结论，非推断）：
   - **不互斥**：`--multipage-async-rendering`（`2583`）只防 **tick 自身重入**（`--async-render-tick` `3015` 的 `cond` 首支），它不覆盖去抖回调；回调的 d 步 `--multipage-sync` 内部各自 bind `--multipage-syncing`（`3178` blocking / `3336` async），但那是**单次 sync 调用粒度**，覆盖不了「窗口 A 的 sync 已返回、窗口 B 还没开始」这一段——跨窗口的守卫是回调自己的 `--zoom-refitting`（D3）。
   - **安全的三条理由**：① Emacs 的 timer 回调在主线程串行执行、不可抢占，回调与 tick 只可能**先后**发生，不会真正并发；② 队列与 scale 无关——tick 渲染时按**当前** target 重推 scale（F15 的 `--async-render-batch` docstring），所以缩放前入队的页不会产出旧分辨率的像素；③ sync 的 state B 在同步渲完 point 页与下一页后立即 `--multipage-pending-remove`（`3358` 区段），其余页入队后由 tick 接着渲，顺序自洽。
   - **纪律**：回调**不要** bind `--multipage-async-rendering`（绑上只会让 tick 白跳一轮、推迟占位页像素），**不要**调 `--multipage-force-sync`（那是 state C 超时兜底，会把整段范围同步渲完，等于绕过 batch）。
   - **已知的非新增代价**：回调 b 步同步渲过的非 point 页仍可能被 d 步重新入队、由 tick 再渲一次（`--multipage-render-page` 不自行出队）——这是**改造前既有**行为（原 `557-558` + `559` 同序），本计划不改变；若要顺带优化须另立计划。

## 文档清单

`docs/configuration.md`（3 个新 defcustom：`render-batch-area-threshold` / `zoom-refit-delay` / `zoom-refit-enabled`）、`docs/emacs-reader.md`（写明 **`+` / `-`（含 `=` 与 `C-<wheel>`）有 0.2 s 去抖，缩放期间短暂模糊、停手后清晰；`W` / `H` / `0` 立即清晰**；`zoom-refit-enabled` = nil 回到同步）、`CHANGELOG.md`、`openspec/decisions.md`（去抖取舍：为什么改 P1 的「故意同步」，以及为什么只对 manual 生效）、`openspec/tech-debt.md`（勾销「`fit-width` 单页渲染成本高 + 连按缩放无去抖」条目，即该文件 §4）、`openspec/roadmap.md`。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` → EXIT 0；C 0 error 0 warning；elisp `Warning` ≤ **20**；checkdoc 0；check-parens 通过。
- **L2**：`make -C emacs/tests ert` → 0 unexpected / 0 skipped；`check-criteria` PASS。基线 = **47 文件 / 1610 例**（含并发会话用例，实跑必须逐项对账，不得把实跑总数当本项成果）。
- **L3 真机**：T4 的四项（①–④）。
- **变异测试（强制）**：T1 去掉面积判定 ⇒ 新用例转红；T2 去抖改回同步 ⇒ `collapses-burst` 转红；T2 去掉回调前的 `clear-last-ranges` ⇒ `survives-goto` 或 `fires-once` 转红；T2 去掉 `(eq source 'manual)` 作用域判定 ⇒ `--zoom-fit-stays-synchronous` 转红；T2 回调只处理 selected-window ⇒ `--zoom-debounce-refits-every-window` 转红。
- **等价性**：`seshat-reader-zoom-refit-enabled` = nil 时与改造前行为等价（渲染计数在命令返回时即等于常驻页数）；`W` / `H` / `0` 在开关为 t 时也与改造前等价（fit 路径仍同步）。
- **任务类型**：elisp 验证走 `verify` 隔离实例；长命令 `timeout` 300000。
- **安全点与回滚**：每批开始前建 git 安全点（`git stash create`）；L1 失败 ≤3 轮、L2/L3 失败 ≤2 轮，耗尽即回滚该批并报告，**不跨批回滚**。
- **审查结论**（plan-reviewer 2026-10-29）：**不通过**——3 major（M1 回调步骤与 D2/D4/D5 自相矛盾、M2 D3 与 D5 的 `--layout-frozen-p` 冲突、M3 去抖作用域未限定）+ 6 minor + 1 nit，本文件已全部修订，待复审。

## 注意事项

1. 不改 C 侧、不改 refit 路径、不改 `--multipage-sync` 的三态分流。
2. 面积阈值默认 `800000` px² 是**保守起点**，真机后可调；不要为「凑效果」把默认值调激进。
3. 新增 defcustom 必须有 `:type` / `:group`（`seshat-reader` 组，`defgroup` 在 `97`），不重复定义。
4. 改文件前后 `md5sum`；并发会话文件一律不碰。

## 执行记录

### T1 执行记录（2026-10-29）

> 执行实测：2026-10-30 11:20–11:35（WSL2 宿主直跑；项目无容器验证入口，故未走容器）。行号为**本次实测**（`seshat-reader.el` 5772 → 5842 行，本批净增 70 行）。

**改动点**

| 文件 | 实测行号 | 改动 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `1503`（新 defcustom，紧跟 `seshat-reader-render-idle-batch` `1489` 之后） | 新增 `seshat-reader-render-batch-area-threshold`，默认 `800000`，`:type 'number` / `:group 'seshat-reader` |
| 同上 | `2972`（新函数，位于 `--async-render-batch` `3009` 之前） | 新增纯判定函数 `seshat-reader--async-render-batch-size (queue)` |
| 同上 | `3043`（`--async-render-batch` 的 `let*`） | `batch` 绑定 = `(seshat-reader--async-render-batch-size queue)`；`queue` 绑定提到它前面一行 |
| 同上 | `3009`–`3014` | docstring 首行改为「Render one bounded batch of queued pages.」并加一段面积判定说明 |
| `emacs/tests/seshat-reader-multipage-async-render-test.el` | `311` | 新增 `--batch-adapts-to-page-area`（5 个场景） |
| 同上 | `278` / `302` | `--tick-renders-one-batch` 显式绑阈值 nil（见「偏差 1」）；`--batch-default-is-two` 增一条默认阈值断言 |

**循环体未改**：`3046` 的 `while (and queue (< attempted batch) (not invalidated))` 结构、`attempted` / `invalidated` 逻辑逐字未动 —— 只有 `batch` 的**取值来源**变了（F4 的约束保持）。

**判定口径**（`--async-render-batch-size`，签名只收 `queue`，无需 window —— `--multipage-page-display-size` 实测签名是 `(page)`）

| 场景 | 判据 | 结果 |
|---|---|---|
| 队头前 `render-idle-batch` 页**任一页**面积 ≥ 阈值 | `(>= (* W H) threshold)` | `batch` = 1 |
| 全部 < 阈值 | —— | `batch` = `seshat-reader-render-idle-batch`（默认 2） |
| 面积 **nil**（既未渲染也未测量），或 cons 只有一维（`(W . nil)`） | `(and (numberp W) (numberp H) (* W H))` 为 nil | 视为 ≥ 阈值 ⇒ `batch` = 1（保守） |
| 阈值 **nil / 非正数** | `(and (numberp threshold) (> threshold 0))` 为 nil | 判定关闭，`batch` = `render-idle-batch` |
| 兜底 | `(max 1 (or render-idle-batch 1))` | 永不为 0（0 页的一轮等于把队列交给超时网） |

nil 与半维用同一个表达式一次判掉，不写额外分支（与 D1 的「把 nil 当 ≥ 阈值」一致）。

**用例表**（`--batch-adapts-to-page-area`，桩 `--multipage-page-display-size`，队列恒 3 页 1/2/3）

| 场景 | 面积桩 | 阈值 | 期望一次 tick | 实测 |
|---|---|---|---|---|
| ① 大页 | `(1600 . 2400)` = 3.84M | 默认 800000 | 渲 1 页，队列剩 `(2 3)` | 通过 |
| ② 小页 | `(612 . 792)` = 484704 | 默认 800000 | 渲 2 页，队列剩 `(3)` | 通过 |
| ③ 面积未知 | `nil` | 默认 800000 | 渲 1 页，队列剩 `(2 3)` | 通过 |
| ④ 阈值 nil | `(1600 . 2400)` | `nil` | 渲 2 页，队列剩 `(3)` | 通过 |
| ⑤ 阈值 0 | `(1600 . 2400)` | `0` | 渲 2 页，队列剩 `(3)` | 通过 |

**变异结果（强制）**：把 `3043` 改成 `(batch (max 1 (or seshat-reader-render-idle-batch 1)))`（去掉面积判定）⇒ 单文件 ERT `Ran 25 tests, 24 results as expected, 1 unexpected`，唯一红例即 `--batch-adapts-to-page-area`，失败点是场景 ① 的 `(should (= 1 (car calls)))` 实际为 2（日志 `/tmp/t1z-ert-mutant.log`）。恢复后 `md5sum` = `e166c28be19c73878fb63916adafcc0a`（与变异前备份逐字节一致），单文件 25/25 全绿。

**L1**：`make -C emacs/seshat-reader clean all` EXIT=0；C 侧（4 个 `.c`，`gcc -Wall -Wextra`）**0 error / 0 warning**；elisp `Warning:` **20** 条（判据 ≤20；全部为既有噪声 —— docstring >80 列、动态模块接口未声明、`visual-fill-column-width` free variable，`grep -n 'batch-area\|async-render-batch-size'` 在编译日志里**零命中**）；checkdoc **0** 输出；改动两文件 `check-parens` 均 ok。
**L2**：`make -C emacs/tests ert` → `FILES=47 TOTAL=1611 UNEXPECTED=0`（基线 1610 + 本批 1 例 = 1611，逐项对账一致）；`make -C emacs/tests check-criteria` → `check-criteria: PASS`。
**并发会话**：本次 `git status` 只有本计划的未跟踪文件与我的 3 个改动文件，全量 47 文件 1611 例 0 unexpected 0 skipped，未出现外来失败文件。

**偏差与说明**

1. **`--tick-renders-one-batch` 多一行绑定**：夹具是**裸占位行**（既未渲染也未测量 ⇒ 面积 nil ⇒ 按大页 batch=1），不显式关掉面积判定，该例就测不到「上限」本身。断言语义未变（仍断言 2 / 2 / 剩 1 页），面积行为由新用例覆盖；docstring 已写明理由。
2. **判定只看队头前 `render-idle-batch` 页**（不是整队）：与「本轮可能触碰的页」同口径；若看整队，一页大页会把后续所有轮次都降级成 1 页。
3. **不需要 window 参数**（陷阱 ⑤-3 无适用场景）：`--multipage-page-display-size` 只收 `page`，故判定函数签名 `(queue)`，未引入 `selected-window` 兜底。
4. **半维面积**（`(W . nil)`）按未知处理 ⇒ 大页：该函数的 docstring 明说「either field may be nil on its own」。
5. **行号漂移**：本批在 `1503` / `2972` 插入共 70 行，`--refit-window` 实测行号由 `4451` 漂到 `4521`、其冻结守卫由 `4476` 漂到 `4546`。F13 / D5 里改成的 `4476` 是复审时的实测值（按任务要求只修笔误数字），T2 实施前请按函数名重新定位。
6. **阈值默认值未动**：`800000` 是保守起点，H1 待 T4 真机按实际耗时分布回填（本批不提前优化）。
7. **未做**：L3 真机（属 T4）；`docs/configuration.md` 等文档（属 T4 的文档清单）；未 commit / 未 push。

### T2+T3 执行记录（2026-10-29）

> 执行实测：2026-10-30 11:28–11:50（WSL2 宿主直跑；项目无容器验证入口，故未走容器）。行号为**本次实测**（`seshat-reader.el` 5900 → 6012 行，本批净增约 112 行）。安全点 `git stash create` = `03bcdf5683ea6bcb7f6f7b90c940809c6e3aa187`（建在 T1 尚未提交的脏工作区上，**含 T1 改动**）。

**改动点**

| 文件 | 实测行号 | 改动 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `153` / `162` | 新增 buffer-local `seshat-reader--zoom-refit-timer` / `seshat-reader--zoom-refitting`（docstring 写明与 `--resize-refit-timer` / `--refitting` 分离的理由） |
| 同上 | `200` / `212` | 新增 defcustom `seshat-reader-zoom-refit-delay`（`0.2`，`:type 'number`）/ `seshat-reader-zoom-refit-enabled`（`t`，`:type 'boolean`，nil = 回滚到同步），均 `:group 'seshat-reader` |
| 同上 | `618`–`624` | `--multipage-set-scale` 的 `557-559` 改为 `if` 分流：`(and seshat-reader-zoom-refit-enabled (eq source 'manual))` ⇒ `--schedule-zoom-refit`；否则原样逐页 refit + sync |
| 同上 | `4599`–`4620` / `4622`–`4668` | 新增 `--schedule-zoom-refit`（cancel-then-rearm，**无任何门禁**）/ `--run-pending-zoom-refit (buffer)`（回调） |
| 同上 | `559`–`604` / `674` / `688` / `700` / `714` / `729` / `751` | docstring 两段式改写（manual 去抖 / fit 同步）；`reset-size` / `fit-to-height` / `fit-to-width` 各加一句「与 `+`/`-` 不同，fit 切换不去抖」 |
| `emacs/tests/seshat-reader-multipage-test.el` | `1805`–`1852` | 新增桩宏 `--with-zoom-debounce-stub` + `--fire-zoom-refit`（桩 `run-with-idle-timer` / `timerp` / `cancel-timer`，只捕获 `--run-pending-zoom-refit` 的 timer；其余 timer 退化为 inert fake） |
| 同上 | `1856` / `1904` / `2028` / `2102` | 4 例迁移（enlarge / shrink / mwheel / manual-zoom-once）；fit-to-width / fit-to-height **未动**（`'fit` 同步，原样绿） |

**回调序列（`--run-pending-zoom-refit`，实测 `4622`–`4668`）**

1. `(when (buffer-live-p buffer) (with-current-buffer buffer …))` → `(derived-mode-p 'seshat-reader-mode)` 守卫 → `(setq --zoom-refit-timer nil)` → `(let ((--zoom-refitting t)) …)`
2. `--multipage-clear-last-ranges`（清**所有**窗口，D4 / 陷阱 2）
3. `(dolist (window (get-buffer-window-list buffer nil t)) …)`（陷阱 4）：`--apply-display-scale` → `(dolist (--multipage-page-numbers) (--multipage-refit-page page window))` → `--center-page` → `--multipage-sync`
4. 不调 `--refit-window`（不含 sync + 函数体内硬编码 `(not (--layout-frozen-p))`）；不 bind `--multipage-async-rendering`；不调 `--multipage-force-sync`（陷阱 7）

**签名核对（实测，非推断）**：`--multipage-set-scale (base &optional source mode)`、`--apply-display-scale (&optional window scale)`、`--center-page (&optional window)`、`--multipage-refit-page (page &optional window)`、`--multipage-page-numbers ()`、`--multipage-clear-last-ranges ()`、`--multipage-sync (&optional window)`、`--schedule-refit ()`、`--refit-window (window)`。**除 `page-numbers` / `clear-last-ranges` 外全部接受 window**，故回调按窗口传参，无「需 window 却传 nil」的场景（注意事项 6 无适用）。

**分流判定**：`(and seshat-reader-zoom-refit-enabled (eq source 'manual))`。manual 侧来自 `--multipage-zoom` 的 `(or source 'manual)`（`+` / `-` / `=` / `C-<wheel>`）；fit 侧 `W` / `H` / `0` 与书签 fit 分支传 `'fit`；`source` = nil 按 fit 处理（保守同步）。`543` / `550-554` / `555` / `556` 四步**一行未动**——`git diff -U0` 中 `@@ -557,3 +618,7 @@` 之前没有任何覆盖 543–556 的 hunk。

**6 例迁移表**

| 用例 | 原断言 | 拆分后断言 |
|---|---|---|
| `--geometry-enlarge-multiplies-base-scale` | base=2.5 / mode `manual` / centers=1 / counter=3 / spec 1500x2000 / render-scale 2.5 / all-sharp | 命令后：base=2.5 / mode / centers=1 / **counter=0** / spec 1500x2000；fire 后：**counter=3** / render-scale 2.5 / all-sharp（另加 `armed=1`） |
| `--geometry-shrink-multiplies-base-scale` | base=1.5 / mode / counter=2 / spec 900x1200 | 命令后：base=1.5 / mode / **counter=0** / spec 900x1200；fire 后：counter=2 |
| `--geometry-fit-to-width-uses-reference-page` | 全部同步断言 | **未改**（`'fit` 同步，原样绿） |
| `--geometry-fit-to-height-uses-reference-page` | 同上 | **未改** |
| `--geometry-mwheel-zoom-same-as-keys` | base / mode / page-width 逐项相等 | 原断言不变 + 新增「命令后 counter=0」+「fire 后 all-sharp」 |
| `--geometry-manual-zoom-refits-visible-pages-once` | base=2.0 / counter=3 / spec 1200x1600 / render-scale 2.0 / all-sharp / 再放大 counter=3 | 命令后：base=2.0 / **counter=0** / spec 1200x1600；fire 后：counter=3 / render-scale 2.0 / all-sharp；再放大 counter=0 → fire → counter=3（**「恰好一次」语义保留**，陷阱 6） |

- **没有「语义确实变了」的用例**：6 例断言语义全部保留，只是把「渲染计数 / sharpness」移到 fire 之后。
- `centers` 在 enlarge 里只断「命令返回时 = 1」；回调会再居中一次（幂等重放），未对总数加断言。
- `--geometry-reset-size-re-fits-like-first-fit` / `--geometry-zoom-clamps-at-renderer-bounds` 未改（fit / clamp 路径，仍同步）。

**L1**：`make -C emacs/seshat-reader clean all` EXIT=0；C 侧（4 个 `.c`）0 error / 0 warning；elisp `Warning:` **20** 条（判据 ≤20；`grep -n 'zoom-refit\|zoom-debounce'` 在编译日志**零命中**，全部为既有噪声）；`make checkdoc` 仅 1 条既有告警（`seshat-reader-annotation-queue.el:290`，非本批文件）；改动两文件 `check-parens`（verify 实例 MCP）均 ok。
**L2**：`make -C emacs/tests ert` → `FILES=47 TOTAL=1611 UNEXPECTED=0`（与 T1 后基线 1611 逐项一致，无 skipped）；`make -C emacs/tests check-criteria` → `check-criteria: PASS`；单文件 `seshat-reader-multipage-test.el` → `Ran 103 tests, 103 results as expected`（定义数与 HEAD 的 103 一致）。
**变异（强制）**：`(setq-default seshat-reader-zoom-refit-enabled nil)`（等价于把 manual 路径改回同步）⇒ 单文件 `Ran 103 tests, 99 results as expected, 4 unexpected`，红例 = enlarge / shrink / mwheel / manual-zoom-once；fit 两例保持绿（证明 `(eq source 'manual)` 作用域判定只影响 manual）。

**偏差与说明**

1. **T2 的 8 例验收用例未写**：本批只做实现 + 6 例迁移（按任务 ①/② 的文件清单口径），故 T2 的勾选带注解。`--zoom-debounce-collapses-burst` / `fires-once` / `cancels-on-new-keypress` / `survives-goto` / `cancelled-on-kill-buffer` / `disabled-stays-synchronous` / `refits-every-window` / `zoom-fit-stays-synchronous` 待下一批补齐；桩宏已预留 `armed` / `cancelled` 计数，`cancels-on-new-keypress` 可直接用。
2. **fit-to-width / fit-to-height 未迁移**（任务表「W 走同步 ⇒ 若原本绿则不动」）：实测原样全绿。
3. **mwheel 例对变异的敏感性靠新增断言**：它在变异下也会红，但依据是新增的「命令后 counter=0」；若要求「不新增断言也不得红」，该例对变异不敏感 —— 更严的覆盖留给 T2 的 `disabled-stays-synchronous`。
4. **`--center-page` 在回调里再跑一次**：命令返回时一次、fire 后一次（共 2 次），是 D5 步骤 3c 的幂等重放，不产生额外渲染。
5. **行号漂移**：本批插入约 112 行，`--multipage-set-scale` 由 `514` 漂到 `559`、`--refit-window` 由 `4521` 漂到 `4670`；D2 里的 `557-559` 仍精确对应函数体内那三行（按函数名定位）。
6. **过程偏差（已修，留作教训）**：迁移时两处 `kill-buffer` 收尾括号数错，导致 4 个 deftest 被嵌套进前一个 deftest（`check-parens` **仍平衡**，但 `ert-select-tests` 只收 99 例）。靠「HEAD 文件 103 例 vs 实跑 99 例」对账发现，修正后 `DEFINED=103`。教训：**check-parens 通过不等于没有「少一层收尾但整体平衡」**，改了 deftest 结构后必须同时核对 `(length (ert-select-tests t t))` 与文件内 `ert-deftest` 条数。
7. **诊断插曲**：`--multipage-set-scale` 的新 docstring 一度留下重复的收尾引号（`debounced.""`），使 `seshat-reader.el` 不可 `read`；此时**所有** elisp MCP 调用（含对无关文件的 `check-parens`）都返回同一句 `Invalid read syntax: ".", 757, 69` —— 结论：**同一条错误位置出现在不同文件上，说明故障在共享加载链（本文件）而不在目标文件**。修复后 MCP 恢复正常。
8. **未做**：L3 真机（T4）；文档清单（T4）；未 commit / 未 push。

### T2 验收用例 + 变异（第二批，2026-10-30）

> 执行实测：2026-10-30 11:44–11:52（WSL2 宿主直跑；项目无容器验证入口）。本批**只改测试与文档**，`emacs/seshat-reader/seshat-reader.el` 逐字节未变（`md5` = `1017344bd84bc01d2968c8911c70f2a5`，四个变异后均已恢复并重编译核对）。

**改动点**

| 文件 | 实测行号 | 改动 |
|---|---|---|
| `emacs/tests/seshat-reader-multipage-test.el` | `1813`–`1822`（桩宏 `--with-zoom-debounce-stub` 的 `cancel-timer` 分支） | 修一个**上一批遗留的桩缺陷**：非 zoom 的假 timer（`fake-idle-timer` / `fake-render-timer`）原先落到真实 `cancel-timer`，对它报 `wrong-type-argument timerp`；现按 `--with-silent-timers` 口径静默丢弃（`survives-goto` 触发该路径：`goto` → sync → 排异步渲染 timer → 随即被取消） |
| 同上 | `3516`–`3860` | 新增 8 例验收用例（见下表），全部复用上一批的桩宏与夹具，未新造桩 |

**8 例验收表**（选择器 `seshat-reader-multipage-test--zoom-`，8/8 通过）

| # | 用例 | 关键判据（任一实现回退即红） |
|---|---|---|
| 1 | `--zoom-debounce-collapses-burst` | 连按 3 次 `+`：`base` = 1.25³、`counter` = 0、spec 宽高已按最终 target（±1.5 px）、`armed` = 3 / `cancelled` = 2；一次 fire 后 `counter` = 3（每页恰一次）且 `all-sharp-p` |
| 2 | `--zoom-debounce-fires-once` | fire 后 `counter` = 3、`all-sharp-p`、`--zoom-refit-timer` = nil；**直接重放同一回调**（模拟 timer 未取消）⇒ `counter` 仍 3、`armed` 仍 1（回调清了 timer + refit 闸幂等） |
| 3 | `--zoom-debounce-cancels-on-new-keypress` | 两次 `+`：`armed` = 2 / `cancelled` = 1，timer 变量始终是 `fake-zoom-timer`；fire 一次 `counter` = 3（没有叠加 timer） |
| 4 | `--zoom-debounce-survives-goto` | 去抖未 fire 时 `goto-page 10`（12 页文档）：回调只把**新视口**常驻页交给 `--multipage-refit-page`（含 10、不含 1/2），旧页不复活；且回调内 `--multipage-sync` 看到的 `last-range` **全为 nil**（清区间生效，否则 sync 早退） |
| 5 | `--zoom-debounce-cancelled-on-kill-buffer` | `kill-buffer` 后 buffer 已死；fire 回调**不抛错**（`condition-case` 断言）、`counter` = 0、不重排 timer |
| 6 | `--zoom-debounce-disabled-stays-synchronous` | `zoom-refit-enabled` = nil：命令返回时 `counter` = 3、`armed` = 0、timer = nil、`all-sharp-p`（与改造前等价） |
| 7 | `--zoom-debounce-refits-every-window` | `split-window` 双窗口：按 `--multipage-refit-page` 的 `window` 实参逐窗口计数，**两个窗口各 3 次**（= 常驻页数） |
| 8 | `--zoom-fit-stays-synchronous` | `W` 返回时 `counter` = 2、`armed` = 0、无 timer、`all-sharp-p`；随后 `+`（去抖 0 渲染）→ 清窗口 `fit-mode` 参数 → `0` 返回时 `counter` = 2、`armed` 不变、mode = `contain` |

- **第 8 例的夹具细节**：`0`（`reset-size`）按**窗口记录的 fit 模式**回落，`W` 会把窗口参数写成 `width`，不先 `(set-window-parameter window 'fit-mode nil)` 就会沿用 `width`、base 不变、无可重渲页（`counter` = 0）。这不是实现缺陷，是 `--initial-fit-mode` 的既有口径（`--geometry-reset-size-re-fits-like-first-fit` 同样先清该参数）。
- **第 5 例的诚实边界**：`--zoom-refit-timer` 是 buffer-local，buffer 死掉后变量随之消失，无法直接断言「变量已清」；故断言等价形式——buffer 已死 + 回调静默无渲染 + 不重排 timer。

**变异结果（4 组，全部按计划转红；每次变异后恢复源码并 `batch-byte-compile` 重编译）**

| # | 变异 | 红例（8 例中） | 失败点摘要 | 恢复后 md5 |
|---|---|---|---|---|
| 1 | `(and seshat-reader-zoom-refit-enabled (eq source 'manual))` → `(and nil (eq source 'manual))`（去抖改回同步） | **7 红**：collapses-burst / fires-once / cancels-on-new-keypress / survives-goto / cancelled-on-kill-buffer / refits-every-window / fit-stays-synchronous（`disabled-stays-synchronous` 仍绿 —— 它断言的正是同步行为） | `Ran 8 tests, 1 results as expected, 7 unexpected` | `1017344b…` |
| 2 | 删掉回调里的 `(seshat-reader--multipage-clear-last-ranges)` | **survives-goto**（唯一红例，与计划预测一致） | 回调内 sync 看到的 `last-range` 非 nil ⇒ `(null (cdr entry))` 失败 | `1017344b…` |
| 3 | `(if (and seshat-reader-zoom-refit-enabled (eq source 'manual))` → `(if seshat-reader-zoom-refit-enabled`（去掉作用域判定） | **fit-stays-synchronous**（唯一红例） | `W` 被去抖 ⇒ `(should (= 2 (car counter)))` 实得 0 | `1017344b…` |
| 4 | 回调的 `(dolist (window (get-buffer-window-list buffer nil t)) …)` → `(dolist (window (list (selected-window))) …)` | **refits-every-window**（唯一红例） | 非选中窗口的重渲计数 `(= 3 (cdr cell))` 实得 0 | `1017344b…` |

- 变异 4 的匹配串在该函数体内**不是唯一**（`--schedule-refit` 回调 `4587` 也有一行同形），故锚点取「该 `dolist` + 紧跟的 `--apply-display-scale`」两行，精确落在 `4666` 的回调里。

**L1**：`make -C emacs/seshat-reader clean all` EXIT=0；C 侧 0 error / 0 warning；elisp `Warning:` **20** 条（判据 ≤20，全部为既有类别：docstring >80 列 7 条、未声明动态模块接口若干、`visual-fill-column-width` free variable 1 条）；checkdoc 仅 1 条既有告警（`seshat-reader-annotation-queue.el:290`）；`check-parens`（verify 实例 MCP）对测试文件 ok。
**L2**：`make -C emacs/tests ert` → `FILES=47 TOTAL=1619 UNEXPECTED=0`（基线 1611 + 本批 8 例 = 1619，逐项对账一致）；`check-criteria: PASS`。单文件 `seshat-reader-multipage-test.el`：`DEFINED=111`（`grep -c '^(ert-deftest'` 与实跑 111 一致，避开上一批「deftest 嵌套导致定义数虚高」的坑）。

**偏差与说明**

1. **修了桩宏的一个遗留缺陷**（`cancel-timer` 对非 zoom 假 timer 调真实函数报错）：不修则 `survives-goto` 无法跑（`goto` 会取消异步渲染 timer）。属测试辅助代码，不影响 6 个已迁移用例（全文件 111/111 绿）。
2. **第 8 例多一步清窗口 `fit-mode` 参数**：见上文「第 8 例的夹具细节」，是夹具控制，不是放宽断言。
3. **`collapses-burst` 的 spec 尺寸断言用 ±1.5 px 容差**：spec 尺寸来自 `--multipage-resize-spec` 的取整（600×1.953125 → 1172），容差只吸收取整，不掩盖「没按最终 target 改写」（那种情况差值是数百 px）。
4. **未做**：L3 真机（T4）；文档清单（T4）；未 commit / 未 push。

### T5 执行记录（2026-10-30）

> 执行实测：2026-10-30 13:44–13:58（WSL2 宿主直跑；仓库无容器验证入口）。安全点 `git stash create` = `e5b06231330724c2ead2b3cb55a1934dd85dce21`（HEAD `bd9d0bf1`）。

**根因摘要（只读分析已确认，本批未重复测量）**

- 缩放每落到新 scale，`--page-spec` 就为每个驻留页调原生渲染，产出**新的 canvas 缓冲**；旧 spec 被 `--multipage-forget-specs`（单页）/ `--page-spec-clear-cache`（全量）从 `seshat-reader--page-spec-cache` 删掉时，**只删了 Lisp 引用**，canvas 缓冲仍由 Emacs image cache 持有，直到 `image-cache-eviction-delay`（默认 300 s）自然淘汰。reader 全仓改动前 **0 处 `image-flush`**。
- 量化：基准 scale 1.245 单页 3.0 MB；`+`×5 后 scale 3.80 单页 28.0 MB；常驻 5–6 页 = 140–168 MB；去抖关闭时峰值 ≈ 440 MB。
- 告警口径失明：`--multipage-resident-spec-megabytes` 只遍历 `--page-spec-cache`（≤6 条），不含 image cache 里滞留的旧尺寸位图 ⇒ 75 MB 告警**永不触发**。

**改动点**

| 文件 | 位置 | 改动 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `2077`–`2094` | 新增 `seshat-reader--multipage-spec-in-use-p`（行引用守卫） |
| 同上 | `2519`–`2555` | `--multipage-rerender-page`：forget 之前存旧 spec，渲染（新 spec 已写入行）之后 flush |
| 同上 | `3338`–`3353` | 新增 `seshat-reader--image-cache-megabytes`（`image-cache-size` 包装，`fboundp` 守卫） |
| 同上 | `3360`–`3395` | `--multipage-resident-spec-megabytes` docstring 补「只统计 spec 缓存，不含 image cache 滞留位图」 |
| 同上 | `3397`–`3428` | `--multipage-check-memory`：message 带 image cache 大小 + docstring 说明双口径差异 |
| 同上 | `1414`–`1452` | `--page-spec-clear-cache` docstring 写明全量路径**有意不 flush**（含边界理由与例外路径） |
| `emacs/tests/seshat-reader-multipage-test.el` | `2660`–`2786` | 新增 4 例（见下表），复用既有夹具 `--geometry-buffer` / `--fake-renderer` / `--window-pixels` / `--with-window-buffer` |

**旧 spec 的取得方式与守卫**

- 旧 spec 从**行**取：`seshat-reader--multipage-page-spec` = `(cddr (assq page seshat-reader--pages))`。`--multipage-forget-specs` 只删缓存条目（`(equal (car (car entry)) page)` 过滤），**不碰 spec 对象**，所以行的 `cddr` 是唯一还指向旧位图的引用。
- 守卫实现（`2077`–`2094`，遍历全部页行的 `cddr`，`eq` 比对；spec 从不复制，故两行共享同一 bitmap 时 `eq` 成立）：

```elisp
(defun seshat-reader--multipage-spec-in-use-p (spec)
  (let ((entries seshat-reader--pages)
        (found nil))
    (while (and entries (not found))
      (when (eq (cddr (car entries)) spec)
        (setq found t))
      (setq entries (cdr entries)))
    found))
```

**flush 落点（`2519` 起）与「为何在写行之后」的注释原文**

```elisp
    (let ((old (seshat-reader--multipage-page-spec page)))
      (seshat-reader--multipage-forget-specs page)
      (let ((spec (seshat-reader--multipage-render-page page t window)))
        (when spec
          (seshat-reader--multipage-set-page-centered
           page (seshat-reader--multipage-page-should-center-p page window)))
        ;; flush 落在**新 spec 已写进行之后**：`--multipage-render-page' 先经
        ;; `--multipage-insert-page' 把行的 `cddr' 换成新 spec 才返回，此时旧
        ;; 位图已无人显示，释放它不会让屏幕闪一帧空白。反过来（写行之前
        ;; flush）会让正在显示旧位图的行短暂失去图像。
        ;;
        ;; 守卫 `--multipage-spec-in-use-p' 不可省：同一 spec 可能被另一行
        ;; 共享（两个窗口显示同一页），flush 一个仍在显示的 spec 会强制它
        ;; 重新解码整页位图——历史上逐帧 flush 正是拖拽卡 1–2 s 的来源。加上
        ;; `(not (eq old spec))'，渲染失败返回 nil 时行已被换成占位（旧 spec
        ;; 同样无人引用），也走同一条释放路径。
        (when (and old
                   (not (eq old spec))
                   (not (seshat-reader--multipage-spec-in-use-p old)))
          ;; 释放失败只说明位图仍留在 image cache 里（等
          ;; `image-cache-eviction-delay' 自然淘汰），不该让重渲染整体失败。
          (ignore-errors (image-flush old)))
        spec))
```

- **判定依据（写行之后）**：`--multipage-render-page` 在返回前已调 `--multipage-insert-page`（entry 存在时 `write-row` + `setcdr (cdr entry) spec`），所以 flush 时行的 `cddr` 已是新 spec；用例 1 的桩在 `image-flush` 内回读 `--multipage-page-spec 1` 并断言 `eq` 新 spec，把这条时序钉住（变异 2 亦能反证）。

**全量失效路径不 flush 的判定与理由**

- 判定：`--page-spec-clear-cache`（`1414`）**不做 flush**，只在 docstring 写明旧位图依赖 `image-cache-eviction-delay`。
- 理由：① 该路径执行时**行里可能仍显示旧 spec** —— `--multipage-relayout`（rotate / reload）是「先清缓存、后 `erase-buffer` 重建行」，`--clear-doc-memory`（关文档）也不先清行；② flush 一个仍在显示的 spec 会强制整页重解码（历史卡 1–2 s 的直接原因），把内存问题换成卡顿问题；③ 单页路径能 flush 是因为它**先替换行**，全量路径没有这个前提。
- 边界说明（docstring 已写）：调用方 `--redisplay-all-windows` 在清缓存后**逐页走 `--multipage-rerender-page`**，因此那条路径的旧位图仍会被本批的 flush 释放；`--multipage-rotate-by` / reload / close 三条路径的旧位图留给 300 s 淘汰。这是**有意保留**的边界，不是遗漏。

**告警口径修正（最终文本）**

- `--multipage-resident-spec-megabytes` docstring 新增段：「This counts **only** `seshat-reader--page-spec-cache' … It does *not* count the bitmaps of older sizes that Emacs still holds in its image cache … see `seshat-reader--image-cache-megabytes' for the total that includes the stragglers.」
- `--multipage-check-memory` docstring 新增段：「The budget is compared against the **spec cache only** … the message reports `seshat-reader--image-cache-megabytes' next to it … Read the message as "the visible specs are X MB, the whole image cache is Y MB", not as "the reader uses X MB".」
- message 最终形态：
  `seshat-reader: %d page specs hold about %.0f MB of bitmaps (budget %s MB); the image cache holds %s (it also counts bitmaps of older sizes, which the budget above ignores); consider lowering seshat-reader--multipage-preload or the render resolution`
  其中 `%s` = `about %.0f MB`（`image-cache-size` 可得时）或 `an unknown amount`（Emacs < 29 / 取值失败）。
- 判定阈值与 clamp（0.25–11.0）**未改**；去抖与 batch 自适应**未改**。

**4 个用例（选择器 `seshat-reader-multipage-test--geometry-`，全绿）**

| # | 用例 | 判据 |
|---|---|---|
| 1 | `--geometry-rerender-flushes-the-old-spec`（`2662`） | 旧 spec 被 flush **恰一次**、实参是**旧对象**；行内已是新 spec；桩内回读行 spec = 新 spec（钉住「先写行后 flush」） |
| 2 | `--geometry-rerender-keeps-a-shared-spec`（`2696`） | 第 2 行与第 1 行共享同一 spec 对象 ⇒ `image-flush` **零调用**、共享行仍持旧对象 |
| 3 | `--geometry-rerender-survives-flush-failure`（`2728`） | 桩 `image-flush` 抛错 ⇒ 尝试 1 次、rerender 返回新 spec、行内是新 spec、**不抛错** |
| 4 | `--geometry-memory-warning-reports-image-cache`（`2757`） | 桩 `image-cache-size` = 123 MB ⇒ 告警 message 含 `image cache holds about 123 MB`，且只报一次 |

**变异测试（2 组，均按计划转红；每次恢复源码后 `make all` 重编译并核对 md5）**

| # | 变异 | 红例 | 失败输出摘要 | 恢复后 md5 |
|---|---|---|---|---|
| 1 | 去掉守卫：`(and old (not (eq old spec)) (not (…spec-in-use-p old)))` → `(and old (not (eq old spec)))` | **`--geometry-rerender-keeps-a-shared-spec`**（唯一红例） | `Ran 115 tests, 114 results as expected, 1 unexpected`；`FAILED … at seshat-reader-multipage-test.el:2696`（`(should-not flushed)`） | `9eb3425d995622d3bb72e2b453911974` ✓ |
| 2 | 去掉 flush 调用：`(ignore-errors (image-flush old))` → `(ignore-errors (identity old))` | **`--geometry-rerender-flushes-the-old-spec`**（`2662`）+ **`--geometry-rerender-survives-flush-failure`**（`2728`） | `Ran 115 tests, 113 results as expected, 2 unexpected`；失败点分别为 `(should (equal (list old) flushed))` 与 `(should (= 1 attempts))` | `9eb3425d995622d3bb72e2b453911974` ✓ |

**L1**：`make -C emacs/seshat-reader clean all` EXIT=0；C 侧 4 个 `.c`（`gcc -Wall -Wextra`）**0 error / 0 warning**；elisp `Warning: ` **20** 条（= 基线，判据 ≤20；`grep -nE "spec-in-use|image-cache-megabytes|image-flush"` 在编译日志**零命中**，即新增代码零警告）；checkdoc 仅 1 条既有告警（`seshat-reader-annotation-queue.el:290`，非本批文件）；改动两文件 `check-parens`（verify 实例 MCP）均 ok。首次编译曾多出 1 条（`2077` docstring >80 列），已折行修掉并重编回到 20。
**L2**：`make -C emacs/tests ert` → `FILES=47 TOTAL=1623 UNEXPECTED=0`（基线 1619 + 本批 4 例 = 1623，逐项对账一致）；`check-criteria: PASS`；`seshat-reader-multipage-test.el` 单文件 `Ran 115 tests, 115 results as expected, 0 unexpected`。先 `make all` 再跑 ERT（避开旧 `.elc` 陷阱）。

**真机待验证（用户手验，未做）**

1. 打开文档 → `+`×5 → `-`×5：观察内存是否在停手 0.2 s 后回落（`M-x memory-info` 看 FREE-RAM 差值，或 `(image-cache-size)` 数值），而不是单调爬升到数百 MB。
2. 缩放过程中是否**不再卡死**（既有缺陷的原始症状），以及拖拽/滚轮是否仍顺畅（守卫是否漏掉「仍在显示」的 spec —— 若卡顿复发，说明守卫判定不足，需回看 `--multipage-spec-in-use-p` 的 `eq` 口径）。
3. 反复缩放后页面是否出现空白/花屏（flush 误伤正在显示的 spec 的可见症状）。
4. 告警文本在真机 `*Messages*` 里的实际形态（含 image cache 数字），确认 `image-cache-size` 在 GUI 会话下取值正常。

**偏差与说明**

1. **flush 的落点比计划更保守**：条件里多加了 `(not (eq old spec))`，覆盖「渲染失败返回 nil、行已被换成占位」的分支（此时旧 spec 同样无人引用，一并释放）；不影响成功路径的语义。
2. **`--image-cache-megabytes` 用 `fboundp` 守卫**：Emacs < 29 无 `image-cache-size` 时返回 nil，message 退化为 `an unknown amount`，不抛错（与本仓库兼容旧 Emacs 的既有做法一致）。
3. **`--multipage-recycle-page` 未改**：它虽然返回被丢弃的 spec（注释说「caller needs it to release the bitmap」），但驻留集内的页会保留缓存、只有远页丢缓存；远页位图在 recycle 时通常已无人引用，可 flush，但本批任务范围只要求 rerender 路径，**留作后续技术债**（写入 `tech-debt` 时可引用本条）。
4. **未做**：真机四项（见上）；文档清单（T4 范围）；未 commit / 未 push。

### T5b 执行记录（2026-10-30）

> 执行实测：2026-10-30 16:20–16:40（WSL2 宿主直跑；仓库无容器验证入口）。安全点 `git stash create` = `8381088eefae4de5350118f8c636c4978df3e336`（HEAD `bd9d0bf1`）。

**真机诊断结论（本轮前置，已确证，本批未重复测量）**

1. `image-flush` 对 canvas spec **有效**：手动 flush 一次释放 5.12 MB，`:flush-error` 为 nil ⇒ T5 的释放手段本身没问题，问题是**覆盖率**。
2. **泄漏源 = 几何路径的孤儿条目**：`seshat-reader--multipage-resize-spec` 原地 `setf` 改 `:width`/`:height`，而 Emacs image cache 的键是 **spec 内容（`equal` 比较）**。改完之后，旧条目的键在 Lisp 世界里**再无任何对象能 `equal` 到**，`image-flush` 找不到它，只能等 `image-cache-eviction-delay` 淘汰 ⇒ 每按一次 `+` 新增约 5.12 MB 孤儿（每驻留页一块）。
3. refit 路径（T5 的 `--multipage-rerender-page` flush）净增长 0（有效），但覆盖率只有 **1/7** —— 它只覆盖「重渲染换新 spec」这一种，几何原地改尺寸的六种情形全漏。

**根因一句话**：T5 释放的是「**对象**被换掉」的旧位图；本批要释放的是「**内容**被改掉」的旧位图——后者的旧键只有一份**旧内容副本**能匹配。

**改动点**

| 文件 | 位置（函数名优先） | 改动 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `1125` `seshat-reader--multipage-stale-specs`（新 defvar-local） | 旧内容快照列表，docstring 写清「仅用于 flush，不显示、不改行、不改缓存条目」 |
| 同上 | `2120` `seshat-reader--multipage-resize-spec` | 在**任何 `setf` 之前** `(push (copy-sequence spec) …)`（尺寸确实会变才 push） |
| 同上 | `2159` `seshat-reader--multipage-spec-content-in-use-p`（新） | `equal` 口径的「内容仍在显示」守卫 |
| 同上 | `2181` `seshat-reader--multipage-flush-stale-specs`（新） | 逐条 `image-flush` + 清空列表 |
| 同上 | `4901` `seshat-reader--run-pending-zoom-refit` | 在**整个窗口循环之后**调 `--multipage-flush-stale-specs` |
| 同上 | `2584` `seshat-reader--multipage-clear` | 一并清空快照列表 |
| 同上 | `1515` `seshat-reader--page-spec-clear-cache` | 一并清空快照列表（rotate / reload / close / redisplay-all 全覆盖） |
| 同上 | `580` `seshat-reader--multipage-clamp-scale` | 上限 `11.0` → `6.0`，docstring 写明内存理由 |
| 同上 | `258` 顶层配置区 | `(setq image-cache-eviction-delay 30)` + 注释（全局变量、`setq-local` 无效、外溢代价） |
| `emacs/tests/seshat-reader-multipage-test.el` | `3979`–`4115` | 新增 6 例（见下表） |
| `emacs/tests/seshat-reader-multipage-test.el` | `2272`–`2290` | 既有 clamp 用例期望值 `11.0` → `6.0`（并改 docstring） |
| `emacs/tests/seshat-reader-fit-window-test.el` | `212`–`214` | 既有 clamp 用例期望值 `11.0` → `6.0`（**计划外文件，见偏差 1**） |

**快照机制（关键：copy 在 setf 之前）**

```elisp
        (unless (and (equal width new-width) (equal height new-height))
          ;; 快照必须在 `setf' **之前**取，且必须取在**同一个对象**上：此刻
          ;; 浅拷贝出来的内容仍是旧尺寸，因而 `equal' 匹配 image cache 里那条
          ;; 旧条目——这是唯一还能让 `image-flush' 找到旧位图的对象。…
          (push (copy-sequence spec) seshat-reader--multipage-stale-specs)
          (setf (image-property spec :width) new-width)
          (setf (image-property spec :height) new-height)
          t)
```

- **每次改尺寸都 push 一份**：每次改之前的**内容**各对应一个 cache 条目，少 push 一份就少释放一块位图。
- **浅拷贝足够**：`:width'/`:height' 是不可变整数，`copy-sequence` 复制 plist 即可；`:data' 仍指向同一个 canvas 缓冲（快照本身不持有像素，成本只有几个 cons）。
- **不改行、不改缓存条目**：快照是游离对象，`--multipage-spec-in-use-p` 对它的 `eq` 判定恒为 nil（用例 1 断言），视觉零变化。

**flush 落点与理由（`--run-pending-zoom-refit`，循环之后）**

```elisp
          (dolist (window (get-buffer-window-list buffer nil t))
            (seshat-reader--apply-display-scale window)
            (dolist (page (seshat-reader--multipage-page-numbers))
              (seshat-reader--multipage-refit-page page window))
            (seshat-reader--center-page window)
            (seshat-reader--multipage-sync window))
          (seshat-reader--multipage-flush-stale-specs)
```

选「循环之后」的三条理由（已写进代码注释）：

1. 循环里的 `--apply-display-scale` **自己也会 push 快照**（键位与定时器之间若发生过 `goto-page' 或窗口尺寸变化，几何会在回调里再改一次）；放在循环之前会把这些新快照留到下一次缩放。
2. 循环之后所有 spec 已是最终尺寸、所有旧位图也已由 `--multipage-rerender-page' 逐页 flush，此刻按内容匹配释放几何孤儿，屏幕上没有任何一行还在显示它们。
3. 保持「先换行、后释放」的纪律（先释放再重渲会让行短暂失去图像）。

**守卫：`eq` + `equal` 双口径**

```elisp
  (dolist (stale seshat-reader--multipage-stale-specs)
    (unless (or (seshat-reader--multipage-spec-in-use-p stale)
                (seshat-reader--multipage-spec-content-in-use-p stale))
      (ignore-errors (image-flush stale))))
  (setq seshat-reader--multipage-stale-specs nil))
```

- `eq` 守卫（`--multipage-spec-in-use-p`）是**防御**：快照从不进页行，正常恒 nil。
- `equal` 守卫（`--multipage-spec-content-in-use-p`）是**必需**：image cache 按键**内容**索引，`+` 后立刻 `-` 会把几何改回原值，此时快照的内容**等于**某个仍在显示的行 spec，flush 它等于强制重解码可见页（历史上 1–2 s 卡顿的来源）。
- 被跳过的快照不保留、列表照样清空 ⇒ 一次失败不会阻塞下一次缩放，滞留时间由 30 s 兜底接管。

**兜底两行（最终文本）**

- `seshat-reader.el:258`（顶层，defcustom 区之后）：

```elisp
;;; Image cache eviction (T5b memory fallback)

;; `image-cache-eviction-delay' 是**全局**变量（C 侧 DEFVAR_LISP，image.c），
;; `setq-local' 对它无效：一旦改成 buffer-local，Emacs 会为当前 buffer 复制一份
;; 绑定，而真正读它的 C 代码只认全局值，改动等于没做。故这里用 `setq'。
;;
;; 为什么改：阅读器的位图都是 canvas spec，每次原地改尺寸都会让旧尺寸的 cache
;; 条目失去所有 `equal' 引用（见 `seshat-reader--multipage-stale-specs'），几何
;; 路径的 flush 只覆盖其中一部分（refit 覆盖 1/7，T5b 真机诊断）。剩下的孤儿
;; 只能等淘汰；默认 300 s 意味着连续缩放几分钟就能把几百 MB 的位图钉在 cache
;; 里。30 s 把滞留时间缩短一个数量级，代价是**其他包**的图片（EWW、dired、
;; image-mode）在闲置 30 s 后也会重新解码——这是本包唯一会外溢到全局的设置，
;; 有意为之：孤儿位图是内存泄漏，重解码只是一次可感知的延迟。
(setq image-cache-eviction-delay 30)
```

- `seshat-reader.el:580`（clamp 上限）：

```elisp
  (cond ((not (numberp scale)) 1.0)
        ((<= scale 0) 1.0)
        (t (max 0.25 (min 6.0 (float scale))))))
```

  docstring 新增段：top end 6.0 而非渲染器允许的 11.0，因为驻留页位图随 scale 平方增长，A4 页在 11.0 约 250 MB、6.0 约 67 MB；6.0 仍能把整宽页放大 4 倍以上。

**6 个用例（`seshat-reader-multipage-test.el`，全绿）**

| # | 用例（行） | 判据 |
|---|---|---|
| 1 | `--resize-spec-pushes-stale-snapshot`（`3979`） | 改尺寸后列表长度 1；快照 `:width` = **旧值 600**、原 spec = **新值 1200**；快照与行 spec 非 `eq` 且 `--multipage-spec-in-use-p` 为 nil；再改尺寸 → 2 条（且新快照内容 1200）；同尺寸重复应用 → 仍 2 条（不产生假孤儿） |
| 2 | `--flush-stale-specs-releases-and-clears`（`4020`） | 桩 `image-flush` 记录实参 ⇒ 调用次数 = 快照数、实参**就是**快照对象（`memq`）、列表清空 |
| 3 | `--flush-stale-specs-skips-in-use`（`4041`） | ① 行显示**内容相同**的快照 ⇒ 0 次 flush、列表清空；② 桩 `--multipage-spec-in-use-p` 返回 t ⇒ 0 次 flush、列表清空 |
| 4 | `--zoom-refit-drains-stale-specs`（`4072`） | `+` 后列表 2 条、flush 0 次（命令返回时未释放）；fire 去抖回调后列表清空、flush ≥2（钉住 refit 里的调用点） |
| 5 | `--clamp-caps-at-six`（`4102`） | `100` → 6.0、`11.0` → 6.0、`5.5` 原样、`0.1` → 0.25 |
| 6 | `--image-cache-eviction-delay-is-thirty`（`4109`） | 全局值 = 30，且**不是** buffer-local（`local-variable-p` 为 nil，钉住用的是 `setq`） |

**变异测试（2 组，均按计划转红；每次恢复源码后核对 md5）**

| # | 变异 | 红例 | 失败输出摘要 | 恢复后 md5 |
|---|---|---|---|---|
| 1 | 删掉 `--multipage-resize-spec` 里的 `(push (copy-sequence spec) …)`（`2120` 行整行删除） | **`--resize-spec-pushes-stale-snapshot`**（`3979`）+ `--zoom-refit-drains-stale-specs`（`4072`） | `Ran 121 tests, 119 results as expected, 2 unexpected`；条件分别为 `(ert-test-failed ((should (= 1 (length …stale-specs))) :form (= 1 0) :value nil))` 与 `(should (= 2 (length …)) :form (= 2 0))` | `3db0cfe9afc69f6d44ba29d21a2b58f1` ✓ |
| 2 | 去掉 refit 里的调用：`(seshat-reader--multipage-flush-stale-specs)` → `(ignore seshat-reader--multipage-stale-specs)` | **`--zoom-refit-drains-stale-specs`**（`4072`，唯一红例） | `Ran 121 tests, 120 results as expected, 1 unexpected`；`(should-not seshat-reader--multipage-stale-specs)` 失败（列表仍 2 条） | `3db0cfe9afc69f6d44ba29d21a2b58f1` ✓ |

> **变异跑法注意（踩过的坑）**：`emacs --batch -L <reader> -l test.el` 默认优先加载 **`.elc`**（`load-prefer-newer` 为 nil），改 `.el` 源码后若不加 `--eval '(setq load-prefer-newer t)'`，跑的是**上一次编译的旧字节码**，变异会假绿。第一轮变异正是这样假绿的，加该开关后立刻转红。

**L1**：`make -C emacs/seshat-reader clean all` EXIT=0；C 侧 4 个 `.c`（`gcc -Wall -Wextra`）**0 error / 0 warning**；elisp `Warning:` **20** 条（= T5 基线，判据 ≤20；逐条对照「In <function>」清单，**无一落在本批新增/改动的函数上**：`--multipage-resize-spec` / `--multipage-flush-stale-specs` / `--multipage-spec-content-in-use-p` / `--multipage-clear` / `--page-spec-clear-cache` / `--run-pending-zoom-refit`）；checkdoc 仅 1 条既有告警（`seshat-reader-annotation-queue.el:290`，非本批文件；`checkdoc-file "seshat-reader.el"` 零输出）；`seshat-reader.el` / `seshat-reader-multipage-test.el` / `seshat-reader-fit-window-test.el` 三文件 `check-parens`（verify 实例 MCP）均 ok。
**L2**：`make -C emacs/tests all` → `FILES=47 TOTAL=1629 UNEXPECTED=0`（基线 1623 + 本批 6 例 = 1629，逐项对账一致）；`check-criteria: PASS`；`seshat-reader-multipage-test.el` 单文件 `Ran 121 tests, 121 results as expected, 0 unexpected`。先 `make all` 再跑 ERT（避开旧 `.elc` 陷阱）。首次跑 ERT 有 1 红：夹具 `--geometry-buffer` 返回 `(BUFFER . SPECS)` 而非 buffer，`kill-buffer` 收到 cons 报 `wrong-type-argument stringp`；改 `(car …)` 后转绿（属夹具用法，非实现缺陷）。

**真机待验证项（用户手验，未做）**

1. 打开文档 → `+`×5 → `-`×5，**重复三轮**，每轮停手 0.2 s 后取 `(image-cache-size)`（或 `M-x memory-info` 的 FREE-RAM）：期望稳定在低值区间、**不随轮次单调爬升**；对比 T5 复验时的爬升曲线。
2. 缩放过程中是否**无新的卡顿**（`equal` 守卫是否足够挡住「缩回原尺寸」的 flush；若出现一帧重解码卡顿，说明 `--multipage-spec-content-in-use-p` 的 `equal` 口径漏了某种共享情形）。
3. 反复缩放后页面是否**无空白/花屏**（flush 误伤可见位图的可见症状）。
4. 其他包的图片（EWW / dired / image-mode）在闲置 30 s 后重新解码是否可接受（`image-cache-eviction-delay` 的全局外溢代价）。
5. 缩放上限降到 6.0 后，`+` 到顶时页面是否仍满足使用需要（不再能到 11 倍）。

**偏差与说明**

1. **计划外修改了 `emacs/tests/seshat-reader-fit-window-test.el`**：该文件 `212`–`214` 的既有用例断言 clamp 上限 `11.0`，本批把上限改成 6.0 后必然转红；只改期望值与注释，未动用例结构。计划文件清单未列此文件，属必要连带修改。
2. **多加了 `equal` 口径守卫**（`--multipage-spec-content-in-use-p`）：计划只要求 `eq` 守卫（并注明「几乎总是 nil，保留守卫是防御」）。但 image cache 按键**内容**索引，`+` 后立刻 `-` 会让快照内容等于某个**仍在显示**的行 spec，只按 `eq` 判定就会 flush 可见位图、把内存问题换成卡顿问题——与「不改变任何视觉行为」的目标冲突。故补 `equal` 守卫，并在用例 3 中单列断言。`eq` 守卫按计划原样保留。
3. **清理点选择「清空不 flush」**：`--multipage-clear` / `--page-spec-clear-cache` 只清列表、不逐条 flush。理由：这两处执行时行里**可能仍显示**那些 spec（`--multipage-relayout` 是「先清缓存、后重建行」，关文档也不先清行），逐条 flush 会撞上 T5 已写明的禁区；这些路径的旧位图本来就被 30 s 兜底接管。
4. **`(setq image-cache-eviction-delay 30)` 放在顶层配置区**（defcustom 区之后、`auto-mode-alist` 之前），不在文件末尾：该位置紧跟缩放相关 defcustom，读者从「缩放」这一主题能直接看到内存兜底；文件末尾是 PoC helpers，语义不相关。
5. **未改**：去抖时序、batch 自适应、T5 的 rerender flush、`--multipage-recycle-page`（仍留技术债）。
6. **未做**：真机五项（见上）；文档清单（T4 范围，`docs/emacs-reader.md` 未提 30 s 与 6.0 上限——建议 T4 一并补）；未 commit / 未 push。

### T5c 执行记录（2026-10-30）

> 执行实测：2026-10-30 16:5x–17:15（WSL2 宿主直跑；项目无容器验证入口，故未走容器）。安全点 `git stash create` = `279fcd190c1159bd927ef4cadadc65b1f9bc6a77`（建在 T1–T5b 均未提交的脏工作区上，**含 T1–T5b 全部改动**）。行号为**本次实测**（`seshat-reader.el` 6224 → 6302 行，本批净增 78 行）。

#### 缺口分析（真机 2026-10-30）

| 观察 | 结论 |
|---|---|
| T5b 后 `+`/`-` 多轮 ⇒ cache **1726 MB**，spec-mb 仅 10 MB，`:stale` 快照 0 | 仍有**不可达孤儿**，且**不在** T5b 记录的两条路径（原地改尺寸 / rerender）上 |
| 最后一条记录突然降到 **3.34 MB**（用户手动 `clear-image-cache` 或淘汰懒触发） | 「整帧清空」是**可靠兜底**，应编码为超预算自动动作 |
| `:stale` 放大中为 5、缩小后为 0 | 快照机制本身工作，但**覆盖不到** `--multipage-insert-page` 换对象路径 |

根因（本批修复）：`--multipage-insert-page` 的 entry 分支用 `(setcdr (cdr entry) spec)` 把行的 spec **换成了另一个对象**。T5b 的两条记录点只覆盖「**同一个对象**被原地改尺寸」（`--multipage-resize-spec` 的 copy 快照）与「rerender 前后 flush」，**没有任何一处**记录「行不再显示的那个对象」。换完之后旧对象在 Lisp 世界再无引用，image cache 里以旧内容为键的位图再也 `equal` 不到（`image-flush` 按内容匹配），只能等 `image-cache-eviction-delay`（30 s）淘汰——而 `+`/`-` 多轮会在 30 s 内累积多份，正是 1726 MB 的来源。

#### 三处改动

| # | 位置（实测行号） | 改动 |
|---|---|---|
| ① 治本 | `2299`（`--multipage-insert-page` 的 entry 存在分支） | `(let ((old (cddr entry))) (when (and old (not (eq old spec))) (push old seshat-reader--multipage-stale-specs)))` 插在 `(setcdr (cdr entry) spec)` **之前**；**插入新行分支不 push**（没有旧 spec）；注释写明「为什么 insert-page 是唯一正确位置（所有换对象路径都经过它，原地改尺寸覆盖不到换对象）」 |
| ② 及时释放 | `3750`（`--multipage-sync` 态 A）、`3765`（**区间相等早退**分支）、`3769`（**正常**分支） | 三处返回前 `(when seshat-reader--multipage-stale-specs (seshat-reader--multipage-flush-stale-specs))`；列表空时只是一次 nil 判断（O(1)）。早退分支也 flush 的理由：用户停手后不会再有下一条命令，孤儿会一直留到淘汰延迟 |
| ③ 可靠兜底 | `4975`–`4979`（`--run-pending-zoom-refit` 末尾，**窗口循环之后**、`let` 结束之前，紧跟原有的 `--multipage-flush-stale-specs`） | `(when (and (numberp 预算) (> 预算 0) (> (image-cache-size) (* 预算 1048576))) (clear-image-cache))`；**无参 = 当前 frame**；注释写明代价（该 frame 其他 buffer 的图片重解码）与「只在超预算时触发」 |
| ④ 新 defcustom | `225`（紧跟 `seshat-reader-zoom-refit-enabled`） | `seshat-reader-image-cache-budget-mb`，默认 `512`，`:type 'number` / `:group 'seshat-reader`；docstring 写明「超过预算清当前 frame 的 image cache；nil / 非正数关闭」与「帧级总量、非本 buffer 份额」 |
| ⑤ 文档串同步 | `1165`–`1176`（`--multipage-stale-specs` defvar）、`2214` 前的 `--multipage-insert-page` docstring | 写明「条目有两个来源：resize-spec 的 **copy** 与 insert-page 的 **live object**」；「由**每一次 sync**（早退与正常）与缩放回调共同 drain」 |

- **`(image-cache-size)` 用 `(ignore-errors …)` 包了一层**（`(or … 0)`）：Emacs < 29 无此函数，未包装会在回调里报错；`--image-cache-megabytes` 已有同样的 `fboundp` 防御口径。
- **未改**：去抖时序 / batch 自适应 / clamp（6.0）/ `image-cache-eviction-delay`（30 s）/ `--multipage-flush-stale-specs` 的两个守卫（`eq` + `equal`）/ `--multipage-sync` 的三态分流。

#### 用例表（5 例，`seshat-reader-multipage-test.el:4117`–`4270`）

| # | 用例 | 判据 | 结果 |
|---|---|---|---|
| 1 | `--insert-page-pushes-replaced-spec`（`4117`） | 行里已有 A，插 B ⇒ 行里是 B **且** stale 列表恰为 `(A)` | 通过 |
| 2 | `--insert-page-does-not-push-for-new-row`（`4140`） | 页 3 无行，插入 ⇒ 列表**不增长**（仍 nil） | 通过 |
| 3 | `--sync-drains-stale-specs`（`4159`） | 列表预置一个孤儿 ⇒ 走 sync 正常分支 ⇒ 列表清空且 `image-flush` 收到**该对象** | 通过 |
| 4 | `--sync-early-return-still-drains`（`4186`） | 桩 `visible-range` = `last-range-for` ⇒ 早退（`sync-async` **未被调用**，断言 `async-called` nil）且列表仍被清空、flush 收到该对象 | 通过 |
| 5 | `--zoom-refit-clears-cache-over-budget`（`4223`） | 桩 `image-cache-size` = 900 MB；预算 1024 ⇒ clear 0 次；预算 512 ⇒ clear **1 次且实参为 nil**（无参 = 当前 frame）；预算 nil / 0 ⇒ 仍 0 次 | 通过 |

- 单文件：`Ran 126 tests, 126 results as expected, 0 unexpected`（定义数 `grep -c '^(ert-deftest'` = **126**，与实跑一致，避开 T2 那次「deftest 嵌套致定义数虚高」的坑）。

#### 变异结果（3 组，全部按计划转红；每次变异后 `make -C emacs/seshat-reader all` 重编译，避免旧 `.elc` 假绿）

| # | 变异 | 红例 | 输出摘要 | 恢复后 md5 |
|---|---|---|---|---|
| 1 | 去掉 insert-page 的 push（`(push old …)` → `nil`） | **`--insert-page-pushes-replaced-spec`**（唯一红例） | `Ran 126 tests, 125 results as expected, 1 unexpected` | `77c3a6e2bc8049c8eed8a6787ae26074` ✓ |
| 2 | 去掉 sync 三处 flush（态 A / 早退 / 正常 → `nil`） | **`--sync-drains-stale-specs`** + **`--sync-early-return-still-drains`** | `Ran 126 tests, 124 results as expected, 2 unexpected` | `77c3a6e2…` ✓ |
| 3 | 去掉超预算 clear（整个 `when` → `nil`） | **`--zoom-refit-clears-cache-over-budget`**（唯一红例） | `Ran 126 tests, 125 results as expected, 1 unexpected` | `77c3a6e2…` ✓ |

> **变异踩坑（两次 `Invalid read syntax`）**：用脚本替换 `when` 块时必须同步算清括号数（`(when … (clear-image-cache)))))))` 共 7 个收尾括号：clear 自身 + when + let + when + with-current-buffer + when + defun）。前两次少算，编译直接报 `Invalid read syntax: ")"`，`BUILD_EXIT=2`——**编译失败不算变异成功**，必须重算后重跑。

#### L1 / L2

- **L1**：`make -C emacs/seshat-reader clean all` → **EXIT=0**；C 侧 4 个 `.c` **0 error / 0 warning**；elisp `Warning:` **20 条**（= T5/T5b 基线，判据 ≤20；`grep -E "seshat-reader\.el:(2[0-9][0-9]|11[0-9][0-9]|22[0-9][0-9]|37[0-9][0-9]|49[0-9][0-9]):"` 对**本批全部改动行区间零命中**）；checkdoc 仅 1 条既有告警（`seshat-reader-annotation-queue.el:290`）；`seshat-reader.el` / `seshat-reader-multipage-test.el` 两文件 `check-parens`（verify 实例 MCP）均 ok。
  - 首轮曾出现 1 条**本批引入**的 checkdoc 告警：`seshat-reader.el:1165: Documentation strings should not start or end with whitespace` —— 原因是新 docstring 里写了裸双引号 `"a bitmap a row used to show"`（docstring 内双引号必须写成 `\"`）。改成 `\"…\"` 后归零。
- **L2**：`make -C emacs/tests ert` → `FILES=47 TOTAL=1634 UNEXPECTED=0`（基线 1629 + 本批 5 例 = 1634，逐项对账一致）；`make -C emacs/tests check-criteria` → **PASS**。**先 `make all` 再跑 ERT**（避开旧 `.elc`）。
- **并发对账**：`git status --porcelain` 前后逐行一致（只有 T1–T5b 的既有改动 + 本计划未跟踪文件，无外来文件）；全量 47 文件 1634 例 0 unexpected 0 skipped。

#### `Blocking call to accept-process-output with quit inhibited!!` 定位（只报告，未改代码）

**结论：与阅读器无关，是 Emacs 自带异步 native-comp 的 sentinel 触发的；`seshat-covers` 也不可能触发（它带超时）。**

证据链：

1. **阅读器零进程**：`grep -E "accept-process-output|sit-for|sleep-for" emacs/seshat-reader/*.el` → **无任何命中**；`grep -E "make-process|start-process|call-process"` 同目录也零命中。阅读器整条缩放路径（`--multipage-sync` / `--run-pending-zoom-refit` / `--multipage-refit-page`）不碰子进程。
2. **全仓唯一调用点带超时**：`emacs/seshat-covers.el:388` `(while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))`，且部署副本（`~/.local/straight/build-32.0.50/seshat-reader/seshat-covers.el`）与仓库**逐字节一致**（`diff -q` 无差异）。
3. **C 侧判据（Emacs master `src/process.c`，`wait_reading_process_output`）**：
   `if (time_limit == 0 && nsecs == 0 && wait_proc && !NILP (Vinhibit_quit) && !(CONSP (wait_proc->status) && EQ (XCAR (wait_proc->status), Qexit))) message1 ("Blocking call to accept-process-output with quit inhibited!!");`
   ⇒ 必须**同时**满足：**无超时**（`seconds` = nil）+ **指定了进程**（`wait_proc` 非空）+ **quit 被抑制**。带 `0.05` 的调用因此**不可能**报这条。
4. **本机实测（Emacs 32.0.50，batch 探针）**：
   - `(let ((inhibit-quit t)) (accept-process-output p 0.05))` → **不报**（与第 3 条一致）；
   - **进程 filter 内** `(accept-process-output proc)`（无超时）→ 打印 `FILTER inhibit-quit=t` **紧跟** `Blocking call to accept-process-output with quit inhibited!!`；
   - `run-at-time` 回调内 `inhibit-quit` = **t**，顶层为 nil（`timer-event-handler` 绑 `inhibit-quit`）；filter / sentinel 同理由 C 侧 `specbind (Qinhibit_quit, Qt)`（`process.c` 注释：「Inhibit quit so that random quits don't screw up a running filter」）。
5. **最可能的调用者**：`/usr/share/emacs/32.0.50/lisp/emacs-lisp/comp-run.el` 的 `comp--accept-and-process-async-output`（`257` / `262` 行 `(accept-process-output process)` **无超时**），由**异步 native-comp worker 的 sentinel** 调用（同文件 `367` 行 `:sentinel (lambda (process _event) … (comp--accept-and-process-async-output process))`）⇒ 只要后台 native 编译有输出就会报，与用户当前在做什么**无关**。用户 Emacs 是 **32.0.50**（开发版），与这条完全吻合。
6. **次可能**（同形态，均为无超时 + 指定进程）：`straight.el:1293`/`1294`（构建/重装包时的轮询）、`etaf-process.el`（**该包已在注释里明确规避**：结算一律用零超时，「a timeout-less wait from a sentinel prints "Blocking call to accept-process-output with quit inhibited"」——与本结论独立互证）、`transient.el:5346`（`--show-manpage`，位于普通函数、quit 未抑制 ⇒ **不会**报）。

**处置建议（未实施）**：无需改阅读器；若要消掉这条消息，可在配置里 `(setq native-comp-async-report-warnings-errors 'silent)`（只影响警告上报，不改变编译）或等上游修 `comp-run`；`seshat-covers` 保持现有 `0.05` 超时轮询即可（改成无超时反而会触发该消息）。

#### 真机待验证项（用户手验，未做）

1. 打开文档 → `+`×5 → `-`×5 **多轮**，每轮记录 `(image-cache-size)`：期望**不再单调爬升**（T5b 时为 1726 MB），稳定在低值或偶尔被 512 MB 兜底压回。
2. 兜底触发时是否出现**一次性整帧重解码卡顿**（当前 frame 其他 buffer 的图片）：预期是「偶发一帧」，若每次缩放都卡说明预算太小或孤儿仍在累积。
3. 反复缩放后页面**无空白 / 花屏**（flush 误伤可见位图的可见症状；`equal` 守卫覆盖不到的新共享形态会这样暴露）。
4. 把 `seshat-reader-image-cache-budget-mb` 设为 nil 复测一轮：应回到「只靠淘汰延迟」的旧曲线（用于确认兜底确实是差值来源）。
5. `--multipage-sync` 现在多了一次列表判空（每滚动一步一次 nil 判断）：滚动手感应无变化（O(1)，无可测差异）。

#### 偏差与说明

1. **`--multipage-sync` 多了一处 flush（态 A）**：计划写「早退分支与正常分支」两处；实现时把 `seshat-reader-render-async` = nil 的态 A 也加了（同一守卫、同一函数、零行为差异）。理由：态 A 是同步路径，缩放命令返回后**没有**去抖回调兜底，孤儿同样只能等淘汰——漏掉它等于在 `render-async` = nil 的用户那里保留原缺口。
2. **`(image-cache-size)` 加了 `ignore-errors` + `or 0`**：计划给的是裸调用；包一层是为 Emacs < 29（无该函数）不炸回调，判据不变（桩函数照常命中）。
3. **过程偏差（两次 `Invalid read syntax`）**：变异脚本替换 `when` 块时括号数少算，两次 `BUILD_EXIT=2`；第三次重算后编译通过并转红。记录在案以免下次重犯（**编译失败不是变异成功**）。
4. **首次 `check-parens` 失败**：`--multipage-sync` 的正常分支少一个收尾括号（`check-parens` 报 `line 3691 Unmatched bracket`，指向 defun 起点而非真实缺口行）。教训：报「defun 起点不匹配」说明该 defun **内部**某分支少括号，从尾部往前数比从头部找快。
5. **一次误插入（已修）**：编辑工具把「超预算 clear」块插进了 `--multipage-sync` 的正常分支（`original_content` 与 `--run-pending-zoom-refit` 尾部同形），`check-parens` 立即报错；改为带**唯一上下文锚点**（`;; ③ 放在逐页重渲之后…`）后落位正确。教训：**短锚点 + 多处同形代码 = 高概率误插**，改前先看 `grep` 命中数。
6. **未做**：真机五项（见上）；文档清单（T4 范围）；未 commit / 未 push。


