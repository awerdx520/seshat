# 阅读器双窗口独立滚动（P1 follow-up，草案）

> **本文件是草案 / 候选池**：未走 Phase 1（方案确认）与 Phase 2（计划独立审查）门禁，**不代表已同意实施**。范围、方案与验收标准都待用户圈定后再细化成可执行计划。

## 当前状态

- **阶段**：草案（候选池）· 未确认 · 未审查 · 未排期
- **来源**：P2-B 真机主观验收第 **⑥** 项（用户 2026-10-29 回报「双窗口各自滚动」**不通过**）。P2-B 只交付其中「D8 两处出口」这一半（队列级并集 / 窗口级强制同步，已修并归档于 `openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md`）；**布局模型级**问题（本文件范围）当时明确转出。
- **违反的不变量**：P1 计划「## 验证标准 · L3」第 ⑪ 项「双窗口各自滚动正常」（见 `openspec/completed/2026-10-26-reader-multipage-p1-layout.md`）。
- **前置**：P1 已归档；P2-A / P2-B 已归档；canvas 后端迁移已完成（2026-10-28）。
- **下一步**：待用户圈定方案（A / B / C，见「## 待用户决策」）→ 补「## 目标 / ## 非目标 / ## 任务 / ## 批次」→ plan-reviewer 审查 → 执行。

## 现象与证据

**用户真机回报（2026-10-29）**

| # | 现象 |
|---|---|
| 1 | 同一文档开两个窗口，滚窗口 A 时**窗口 B 跟着动**，且 B 的位置看起来**「随机」**（不是固定偏移，也不是不动） |
| 2 | B 的页变成**背景色**（占位态、无像素），并且**不再恢复** |
| 3 | 需 1 次显式 `M-g g`（goto-page）才把 B 拉回原处 |

**T9 客观测量量化（同批，独立 GUI + 双窗口桩/真机混合）**

| 项 | 数值 |
|---|---|
| 两窗口视口相隔页数 | 11 页 |
| B 的 `window-start` 塌陷 | p12 → **p6**（前移 6 页） |
| 2 条 `--multipage-sync` 之后的恢复程度 | 只到 **p7**（差 5 页未恢复） |
| 恢复手段 | 1 次显式 `goto-page` |
| D8 队列级现象 | 态 C 超时兜底整队清空 ⇒ 另一窗口登记的队项被丢、占位页失去驱动源（**这一半已在 P2-B 修掉**） |

**归因边界（重要）**：现象 2（永久空白）由 D8 违规放大，已修；现象 1、3（塌陷 / 随机）**不是**异步渲染引入的——P1 的单 buffer 布局模型在同步渲染时代就已如此，只是过去没有双窗口使用场景暴露它。

## 根因（已定位，带行号）

> 行号为 2026-10-29 在 `emacs/seshat-reader/seshat-reader.el` 实测；P2-B 之后该文件已整体后移约 100 行，**后续改动会让行号继续漂移**，请按函数名 `grep` 定位。

| # | 事实 | 位置 |
|---|---|---|
| ① | **驻留行表是 buffer 唯一的**：`seshat-reader--pages`（升序 alist `(PAGE MARKER . SPEC)`）一个 buffer 只有一份，不区分窗口 | `seshat-reader.el:462`（`defvar-local`） |
| ② | **回收循环按「本窗口」保留**：`--multipage-sync-blocking` 与 `--multipage-sync-async` 各自遍历整个 buffer 的页表，把**不在本窗口可见范围**的页 `delete-region` 掉 | `3011`（blocking，循环在 `3062`）、`3137`（async，循环在 `3194`） |
| ③ | **删行让另一窗口的 `window-start` 前移**：marker 随文本删除前移，B 的 `window-start` 因此从 p12 落到 p6 附近 | `delete-region` 在 `2025`（`--multipage-recycle-page` 族） |
| ④ | **`--ensure-window-layout` 对非当前窗口重锚**：当 `window-start` 不在页行上时，它显式 `set-window-start` 到「最小驻留页」——即 B 被钉在**当前驻留集的下沿**，这正是「塌到 p6」的直接动作 | `3816`（函数）、`3844`（`set-window-start`） |
| ⑤ | **`--multipage-last-range` 是 buffer 一份**：早退判据 `(equal range last-range)` 在多窗口下永远按「最后一个跑过的窗口」记账 ⇒ 早退与否取决于命令顺序 ⇒ 用户感到的**「随机」** | `2168`（`defvar-local`）、`3053` / `3057`（判定与写回）、`3118`（置 nil）、`3134`（早退分支） |
| ⑥ | **居中 / 贴左决策按单窗口宽度写入 buffer 全局文本属性**：居中是每页行的 `display` 属性（`align-to` + spec），贴左是窗口 hscroll 与 `line-prefix`；宽窄不同的两个窗口共享同一份 `display` ⇒ 至少一个窗口的页面位置/宽度是错的（**横向症状**，与 ①–⑤ 的纵向症状叠加） | `1736`（`--multipage-set-page-centered`）、`1784`（`--multipage-page-should-center-p`） |

**结论**：①–⑤ 是「窗口级视口 vs buffer 级布局」的错配（纵向），⑥ 是「窗口级宽度 vs buffer 级文本属性」的错配（横向）。二者同源不同面，**方案必须同时说明如何处置 ⑥**，否则改完 ①–⑤ 仍会出现「两个窗口里页面宽度只有一个是对的」。

## 候选方案

> 三个方案都**不引入第二套布局**（P1 决策 4：不得复活单页模式），差别只在「驻留集与布局状态放在哪一级」。

### 方案 A：驻留集并集化 + 每窗口 range 状态

- **改哪里**：① `--multipage-sync*` 的回收循环改为「保留**所有**显示本 buffer 的窗口可见范围的**并集**」（复用 P2-B 已有的 `--multipage-all-visible-pages`，它已遍历 `frame-list`）；② `--multipage-last-range` 从 buffer-local 改为 **window-parameter**（`(window-parameter w 'seshat-reader-range)`），早退判据按窗口；③ `--ensure-window-layout` 的重锚改为「只在本窗口 `window-start` 真的落在页行之外时重锚到**最近的**页行」，不再钉到驻留集下沿；④ 居中/贴左（⑥）按窗口分别处理：居中的 `align-to` 无法按窗口分叉（同一份 `display`），故需改为「按最宽窗口居中 + 每窗口 hscroll 补偿」或「贴左 + 每窗口 margin」——**这是本方案最难的一步**。
- **影响面**：`--multipage-sync` / `--multipage-sync-blocking` / `--multipage-sync-async` / `--multipage-recycle-page` / `--multipage-last-range` 的全部读写点 / `--ensure-window-layout` / 居中族；测试面覆盖 `seshat-reader-multipage-test.el`、`-sync-async-test.el`、`-async-render-test.el`、`-resize-test.el`。
- **是否破坏不变量**：P1 不变量①（占位/已渲染页高一致）、②（补位不动 marker）**不破坏**；P1 的「驻留集 = 视口 ± preload」**被改写为并集**（语义扩大，需重写对应断言）；P2-B 的 D8（队列并集）与之天然一致。
- **能否 batch 覆盖**：能覆盖 ①②③⑤（桩 `window-start` / `window-end` / 页表，断言回收后另一窗口的行仍在、range 按窗口）；⑥ 的横向几何**必须真机**（batch 无真实 redisplay）。
- **代价**：最大。内存随窗口数线性增长（见「影响与风险」）。

### 方案 B：禁止跨窗口重锚 + 窗口锚定页恢复

- **改哪里**：① `--ensure-window-layout` 不再对**非当前窗口**做 `set-window-start`（只对当前窗口生效）；② 每个窗口用 window-parameter 记住自己的**锚定页**（`(window-parameter w 'seshat-reader-anchor-page)`），窗口的页被回收后，由「本窗口下一次 `--multipage-sync`」把锚定页重新插入并落位；③ `--multipage-last-range` 同样按窗口（同 A 的 ②）；④ 居中/贴左（⑥）同 A 的 ④（仍需处置）。
- **影响面**：比 A 小——**不动回收循环的保留口径**（驻留集仍是「本窗口」的，只保证「另一窗口的页在被回收后能按锚定页重建」）；改动集中在 `--ensure-window-layout` + 一个新的「按窗口恢复」路径 + range 状态。
- **是否破坏不变量**：P1 不变量①②不破坏；「驻留集 = 视口 ± preload」保持原义；但**引入新状态**（每窗口锚定页）——它是 window-parameter，窗口删除即消失，无泄漏。
- **能否 batch 覆盖**：能覆盖「非当前窗口不被重锚」「锚定页重建」；「重建后的落点是否正确」仍需真机。
- **代价**：中。语义更保守（不扩大驻留集），但**观感可能是「B 不塌但会跳」**——B 的页被回收后在下次 sync 时重建，用户会看到 B 短暂空白后回位，而不是持续稳定。

### 方案 C：最小缓解（只保证「B 不塌」不保证「B 不跳」）

- **改哪里**：只改 `--ensure-window-layout`——把「重锚到最小驻留页」改为「重锚到**最近的**页行」并跳过非当前窗口；`--multipage-last-range` 仍 buffer 一份（接受早退顺序依赖）。
- **影响面**：最小，一个函数 + 一条断言。
- **是否破坏不变量**：不破坏任何既有不变量；但**不解决根因**（驻留集仍是单窗口的，B 的页仍会被回收，只是落点不再「塌到 p6」）。
- **能否 batch 覆盖**：能（断言「非当前窗口不被 set-window-start」）。
- **代价**：最小，但**只买到「不塌」**：B 仍会跟着 A 动（页被回收 → 行没了 → B 的视口内容变化），用户体感大概率仍判「不通过」。

**方案取舍速览**

| 方案 | 解决「不塌」 | 解决「不跳」 | 解决「横向」⑥ | 内存代价 | 改动面 |
|---|---|---|---|---|---|
| A | ✅ | ✅ | 需一并处置（最难） | 大（驻留集并集） | 大 |
| B | ✅ | ⚠️ 部分（重建后有短暂空白/回位） | 需一并处置 | 中 | 中 |
| C | ⚠️ 部分 | ❌ | ❌ | 无 | 小 |

## 影响与风险

| # | 风险 | 评估与处置 |
|---|---|---|
| R1 | **驻留行数可能翻倍**（方案 A）：每页 canvas 缓冲 ≈ **1.9 MB**（canvas 迁移后口径），75 MB 告警线在 `seshat-reader.el:1206` 附近（`seshat-reader-multipage-memory-warning-mb` 默认 75）⇒ 两窗口相距很远时驻留页数 = 两个「视口 ± preload」之和，4 页/窗口 × 2 ≈ 8 页 ≈ 15 MB（仍在线内），但**三窗口或 preload 调大即可能撞线** | 实施前先算上限：`2 × (视口页数 + 2×preload) × 1.9 MB`，并**显式复核告警线是否需要随窗口数调整**；超线时必须有降级（如并集只保留「最近的前 N 页」） |
| R2 | **回归面大**：T9 的 span / geometry 断言（`seshat-reader-multipage-test.el` 103 例）全部依赖「驻留集 = 本窗口 ± preload」；方案 A 改写该语义后**全部要重跑并逐条复核**，方案 B/C 影响较小但仍需复核 `--ensure-window-layout` 相关用例 | 实施时按「先补断言再改实现」（TDD），并保留变异测试（改回单窗口口径 ⇒ 新用例必须转红） |
| R3 | **横向症状（⑥）难解**：居中是 buffer 全局 `display` 属性，两个不同宽度的窗口无法同时「居中」；任何方案都要接受一个观感取舍（按最宽窗口居中 + hscroll 补偿 / 统一贴左 / 每窗口 margin） | 需要用户在三个取舍里选一个（见「待用户决策」），**不能由执行侧自行决定** |
| R4 | **必须真机验收**：batch 无真实 redisplay，`window-start` / hscroll / 居中位置都测不出来 | 真机 30 页交替滚动验收（见下） |
| R5 | **与 `--multipage-async-overdue-p` 的单 buffer 时间戳耦合**：多窗口各自有 range 后，超时判据仍是单值 ⇒ 强制同步频率偏高（性能退化，不会渲染错） | 本项可不动它（已记 `openspec/tech-debt.md`「两阶段异步渲染（P2-B）遗留」第 2 条）；若要一并改，队项结构要从「页号整数」升级为 `(PAGE . SINCE)`，回归面显著变大 |
| R6 | **与 sidebar 同类缺口同源**：`seshat-reader-sidebar.el:489` 的 `--windows` docstring 称「全体」但用无参 `window-list`（只答选中 frame） | 见「待用户决策」第 2 项：是否与本项合并处理 |

## 验收标准（草案）

1. **双窗口各自滚动 30 页互不干扰**（真机，同 frame 双窗口 + 跨 frame 双窗口各一轮）：滚 A 的 30 页过程中，B 的 `window-start` 页号变化 ≤ 0（不塌）；A 停止后 B 无需任何显式 `goto-page` 即回到原处。
2. **B 的页不塌陷、不永久空白**：B 视口内的页在 A 滚动期间始终有像素或**在 1 个超时窗内（`render-async-timeout`，默认 1.0 s）补上像素**；不允许「跟背景色一样且不恢复」。
3. **内存不越告警线**：两窗口相距 ≥ 20 页、`preload` 取默认 2 时，`--multipage-check-memory` 不触发 `message`；若触发，必须在本计划里给出新的上限口径与降级策略（而不是简单调大 75 MB）。
4. **P1 L3-⑪ 原文作为验收依据**：「双窗口各自滚动正常」——以用户真机主观判定为准，不以 batch 用例代替。
5. **回归**：全量 ERT `0 unexpected / 0 skipped` + `check-criteria` PASS；T9 的 span / geometry / 占位页高三态断言全部仍绿；L1 `make -C emacs/seshat-reader clean all` EXIT 0、C 0/0、elisp warning ≤ 基线、checkdoc 0。

## 待用户决策

1. **方案取舍**：A（并集化 + 每窗口 range，最彻底、内存与回归面最大）/ B（禁跨窗口重锚 + 锚定页恢复，折中，可能「不塌但会跳」）/ C（最小缓解，只买「不塌」）。**建议先做 C 观察体感，再决定是否上 A**——但 C 很可能仍判不通过，需用户接受「分两步走」。
2. **是否与 sidebar 同类缺口合并处理**：`seshat-reader-sidebar.el:489` 的 `--windows` 与本项 R6 同源（docstring 称「全体」、实现只答选中 frame）。合并的好处是一次把「跨 frame 遍历」这类不一致统一收口；坏处是两处失败面不同（面板窗口 vs 阅读窗口）、验收标准也不同。
3. **横向症状（⑥）的观感取舍**：三选一——① 按**最宽**窗口居中 + 每窗口 hscroll 补偿（窄窗口可能偏一侧）；② 统一**贴左**（居中特性在双窗口下退化）；③ 每窗口 margin（改动面最大，且 `align-to` 无法按窗口分叉，可能仍需 hscroll）。
4. **是否连带修 `--multipage-async-overdue-p` 的单 buffer 时间戳**（R5）：连带修会让队项结构升级，回归面变大；不修则多窗口下强制同步偏频繁（性能退化）。
5. **范围边界**：本项是否包含「双窗口 + 缩放（`W`/`H`/`+`/`-`）」组合？P2-B 的 T9 未覆盖该组合，且缩放会同时改每页 spec 尺寸与居中判定，风险叠加。
