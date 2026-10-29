# 阅读器双窗口独立滚动（P1 follow-up）

## 当前状态

- **已完成（2026-10-29）**，已归档至 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`。
- **交付摘要**：① **驻留集并集化**——`--multipage-sync-blocking` / `--multipage-sync-async` 的回收判据由「本窗口 range」改为「所有显示该 buffer 的窗口可见范围的并集」（`--multipage-all-visible-pages`，`keep` 在渲染循环前取一次快照），渲染 / 失败清零 / 预取 / 早退仍按本窗口（T1）；② near-resident 与淘汰判据的**集合来源**改为并集成员，各自保留原边界口径（near-resident 仍 ±1、eviction-victim 不加 ±1）（T2）；③ **每窗口同步区间**——`--multipage-last-range` 换成 window-parameter `seshat-reader--range-parameter`（值 `(BUFFER . RANGE)`，读时校验 buffer），`--multipage-clear` 与态 A 复位全窗口清，`--multipage-force-sync` 走 `force` 形参（绕过早退且不记账）（T3）；④ **重锚换锚点**——`--ensure-window-layout` 保留对所有窗口执行，锚点改为「最近的页行」（新增 `--multipage-row-nearest`）（T4）；⑤ 预取边界改用调用窗口 range（`--multipage-prefetch` 保留 `window` 形参）（T5）；⑥ 文档 + tech-debt + 归档 + 最终全量验证（T6）。
- **真机结论（用户 2026-10-29 回报，6 项全部通过）**：重启正常 / 双窗口 30 页交替滚动不塌不跳 / 页间空行行为可接受 / 跨 frame 通过 / 单窗口无退化 / 内存无告警。
- **最终 L2 口径**：`make -C emacs/tests all` → `FILES=47 TOTAL=1610 UNEXPECTED=0`、0 skipped、`check-criteria: PASS`（基线 T4+T5 后 47/1610，T6 不新增用例；本批自身新增 **7** 例，逐条有变异测试）。L1：`clean all` EXIT 0、C 0 error 0 warning、elisp `Warning:` 20（基线）、checkdoc 1（并发会话文件）、4 个改动 `.el` check-parens 全 ok。
- **转为已知限制（不在本项范围）**：横向（居中/贴左按单窗口宽度写 buffer 全局几何）、视口不能停在页间空行（T4 的代价，真机确认可接受）、预取方向 buffer 级——见 `docs/emacs-reader.md` §7 与 `openspec/tech-debt.md`「P2-B 遗留」§7 / §8。
- **下一步**：无（本计划闭环）；后续可另立项处理横向 ⑥ 与预取方向。

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

> 行号为 2026-10-29 在 `emacs/seshat-reader/seshat-reader.el`（5499 行）实测；P2-B 之后该文件已整体后移约 100 行，**后续改动会让行号继续漂移**，请按函数名 `grep` 定位。
> 本轮改写时逐条 `rg` 复核了一遍：①–⑥ 的行号与下表「相关函数行号」一致；候选池旧稿与任务书里有 5 处旧值已按实测修正（`--cache-eviction-victim` `1140`→`1132`、`--multipage-page-near-resident-p` `2333`→`2328`、`--multipage-recycle-page` `2352`→`2339`、`--multipage-resident-spec-megabytes` `2968`→`2961`、`--multipage-clear` 函数头 `2204`→`2194`（`2204` 是函数内的复位行，仍然正确）；另 `--multipage-memory-warning-mb` 的 `1206` 已过时，现为 `1428`）。

| # | 事实 | 位置 |
|---|---|---|
| ① | **驻留行表是 buffer 唯一的**：`seshat-reader--pages`（升序 alist `(PAGE MARKER . SPEC)`）一个 buffer 只有一份，不区分窗口 | `seshat-reader.el:462`（`defvar-local`） |
| ② | **回收循环按「本窗口」保留**：`--multipage-sync-blocking` 与 `--multipage-sync-async` 各自遍历整个 buffer 的页表，把**不在本窗口可见范围**的页 `delete-region` 掉 | `3011`（blocking，循环在 `3062`、判据在 `3064`）、`3137`（async，循环在 `3194`、判据在 `3196`） |
| ③ | **删行让另一窗口的 `window-start` 前移**：marker 随文本删除前移，B 的 `window-start` 因此从 p12 落到 p6 附近 | `delete-region` 在 `2025`（`--multipage-recycle-page` 族） |
| ④ | **`--ensure-window-layout` 对非当前窗口重锚**：当 `window-start` 不在页行上时，它显式 `set-window-start` 到「最小驻留页」——即 B 被钉在**当前驻留集的下沿**，这正是「塌到 p6」的直接动作 | `3816`（函数）、`3844`（`set-window-start`）；「最小驻留页」的来源是 `--multipage-window-start-page` 的兜底 `first`，在 `3744` |
| ⑤ | **`--multipage-last-range` 是 buffer 一份**：早退判据 `(equal range last-range)` 在多窗口下永远按「最后一个跑过的窗口」记账 ⇒ 早退与否取决于命令顺序 ⇒ 用户感到的**「随机」** | `2168`（`defvar-local`）、`3053` / `3057`（判定与写回）、`3118`（置 nil）、`3134`（早退分支）、`3171` / `3173`（async 的读与写） |
| ⑥ | **居中 / 贴左决策按单窗口宽度写入 buffer 全局文本属性**：居中是每页行的 `display` 属性（`align-to` + spec），贴左是窗口 hscroll 与 `line-prefix`；宽窄不同的两个窗口共享同一份 `display` ⇒ 至少一个窗口的页面位置/宽度是错的（**横向症状**，与 ①–⑤ 的纵向症状叠加） | `1736`（`--multipage-set-page-centered`）、`1784`（`--multipage-page-should-center-p`） |

**结论**：①–⑤ 是「窗口级视口 vs buffer 级布局」的错配（纵向），⑥ 是「窗口级宽度 vs buffer 级文本属性」的错配（横向）。二者同源不同面，**方案必须同时说明如何处置 ⑥**，否则改完 ①–⑤ 仍会出现「两个窗口里页面宽度只有一个是对的」。

**相关函数行号（2026-10-29 `rg` 复核，供 T1–T6 定位）**

| 符号 | 行 | 备注 |
|---|---|---|
| `seshat-reader--pages` | `462` | `defvar-local`，buffer 唯一行表 |
| `--multipage-resident-page-range` | `1106` | 返回 `(FIRST . LAST)` **跨距** |
| `--cache-eviction-victim` | `1132`（判定 `1145-1154`） | 跨距外优先淘汰 |
| `seshat-reader-multipage-memory-warning-mb` | `1428` | defcustom，默认 75 |
| `--multipage-set-page-centered` / `--multipage-page-should-center-p` | `1736` / `1784` | ⑥ 横向 |
| `--multipage-page-at-pos` | `2032` | |
| `--multipage-visible-range` | `2048` | 本窗口视口 ± preload |
| `--multipage-all-visible-pages` | `2081` | 遍历 `frame-list` 的并集（P2-B D8 已有） |
| `--multipage-last-range` | `2168` | `defvar-local`，早退判据 |
| `--multipage-clear` | `2194`（复位行 `2204`） | |
| `--multipage-page-near-resident-p` | `2328`（判定 `2334-2337`） | 跨距 ±1 |
| `--multipage-recycle-page` | `2339`（保留守卫 `2358-2360`） | 释放 spec |
| `--multipage-prefetch` | `2902`（边界计算 `2941`） | |
| `--multipage-resident-spec-megabytes` | `2961` | 内存估算 |
| `--multipage-check-memory` | `2991` | buffer 级 `memory-warned` 只报一次 |
| `--multipage-sync-blocking` | `3011`（早退 `3053`、写回 `3057`、回收判据 `3064`、prefetch `3067`） | |
| `--multipage-sync-async` | `3137`（写回 `3173`、回收判据 `3196`、prefetch `3210`） | |
| `--multipage-force-sync` | `3216`（`let*` 遮蔽 `3249`） | |
| `--multipage-window-start-page` | `3734`（兜底 `first` 在 `3744`） | |
| `--ensure-window-layout` | `3816`（`set-window-start` 在 `3844`） | 唯一注册点 `5169` |

## 目标

1. 双窗口（同 frame 上下分窗、跨 frame 各一轮）各自滚动**互不干扰**：滚 A 时 B 的 `window-start` 页号不塌陷，A 停止后 B 无需显式 `goto-page` 即回原处。
2. 消灭「随机」感：早退判据按窗口记账，不再取决于「上一轮是哪个窗口跑的」。
3. 守住既有不变量：占位/已渲染页高三态一致、补位不动 marker、`render-async` = nil 时态 A 与旧路径等价。
4. 内存不越告警线（并集 = 两窗口之和）。

## 非目标（明确不做）

| 不做 | 理由 |
|---|---|
| 横向问题 ⑥（居中/贴左按单窗口宽度决策、写入 buffer 全局文本属性） | 上下分窗同宽时结果相同、不参与当前症状；左右分窗/跨 frame 不同宽时才会错。单独立项，tech-debt 已有条目 |
| `--multipage-scroll-direction` 按窗口 | 方向错的代价只是「预热了另一侧一页」，被 prune（并集）+ 缓存上限双重兜住；改造要动像素滚动路径，回归面覆盖所有滚动用例 |
| `--multipage-async-overdue-p` 的单 buffer 时间戳 | 需把队项结构升级为 `(PAGE . SINCE)`，回归面显著变大；已记 tech-debt |
| 给每个窗口独立布局（每窗口一套页行） | 等于复活多套布局，违背 P1 决策 4 |
| 改 C 侧 / canvas / 居中族 | 与本项正交 |

## 设计决策

**D1 驻留集并集化，但只改回收判据**：`--multipage-sync-blocking`（回收判据在 `3064`）与 `--multipage-sync-async`（回收判据在 `3196`）的 `(or (< page first) (> page last))` 改为 `(unless (memq page keep))`，`keep` 在循环**前**用 `--multipage-all-visible-pages win`（`2081`）算一次并缓存到局部变量。**渲染循环 / 失败清零 / 预取边界 / 早退判据仍用本窗口 range**。

**D2 每窗口 range 用 window-parameter**：删 `--multipage-last-range` defvar-local（`2168`），新增 `seshat-reader--range-parameter` 常量；所有读写点（`2204` / `3053` / `3057` / `3118` / `3134` / `3171` / `3173`）改 window-parameter。**`--multipage-clear`（复位行 `2204`）与态 A 复位（`3118`）必须遍历所有窗口清**（否则「行表已空 + range 恰好相等 → 早退 → 行永不重建」= 永久空白）。参数值存 `(BUFFER . RANGE)` 并校验 buffer（窗口切 buffer 再切回时参数不自动清除）。

**D3 重锚换锚点，保留对所有窗口执行**（**这是对原方案 ③ 的修正**）：`--ensure-window-layout`（`3837-3844`）**不移除**对非当前窗口的 `set-window-start`，而是把锚点从「最小驻留页」（来源是 `--multipage-window-start-page` 的兜底 `first`，`3734-3744`）改为「**最近的页行**」；为此新增 `--multipage-row-nearest (pos)`（遍历 `--pages`，比较 marker 位置，优先前驱、否则后继，约 8 行）。顺序必须保持 sync → 重锚 → `--ensure-centered`（sync 会移动 marker）。**依据**：它是 `split-window` / 换 buffer / `--render-buffer` 重载 / 回收删行四条路径上唯一的纠正点（唯一注册点 `5169`，无其他直接调用）；移除会引入新的错位。**兜底 `first` 不需改**：`--multipage-window-start-page`（`3734`）还被 `224` / `240` / `586` / `729` / `895` 五处用于「派生窗口顶页号（显示页码）」，first 兜底在那里是正确的；D3 只在 `--ensure-window-layout`（`3841`）把锚点来源换成 `--multipage-row-nearest`，`--multipage-window-start-page` 与其 first 兜底**保持不变**。

**D4 near-resident 与淘汰判据改集合成员**：两个函数都读 `--multipage-resident-page-range`（`1106`）的**跨距**，但边界口径本来就不同——`--multipage-page-near-resident-p`（`2328`，判定 `2334-2337`）是「跨距 **±1**」；`--cache-eviction-victim`（`1132`，判定 `1145-1154`）是「**跨距内保留、无 ±1**」（严格 `>= first` / `<= last`）。并集下跨距会把两窗口之间所有页算成驻留（spec 不释放、淘汰挑错页），故两者都改为按**并集成员**判定，但**各自保留原有边界口径**：near-resident 仍为「并集成员 ±1」（只把「跨距」换成「并集」，±1 语义不变）；eviction-victim 仍为「并集成员、**不加 ±1**」。**选择「不给 eviction-victim 加 ±1」的理由**：它的作用是把「已看不见的页」排到淘汰队首，边界 ±1 的页属于「即将看见」，提前放行会推迟边界页的淘汰时机、抬高缓存峰值，与目标 4「内存不越告警线」相左；且「只换集合来源、不动边界」是最小改动，淘汰时机与单窗口基线完全一致，回归面最小。**不得改 `--multipage-resident-page-range` 的返回值**（它还被 prefetch 当边界用）。

**D5 prefetch edge 用调用窗口 range**：签名定为 `(seshat-reader--multipage-prefetch window range)`（函数在 `2902`，边界计算在 `2941`）——**保留 `window`**、只**新增 `range`**；两处调用（`3067` / `3210`）传本窗口 range。**不得用 `range` 替换 `window`**：态 A 的同步分支要用 `window` 算 `--multipage-target-scale`（现实现 `2955-2956`：`(seshat-reader--multipage-target-scale page (if (window-live-p window) window (selected-window)))`），去掉它会让态 A 预取退化到 `selected-window`，非当前窗口同步时按错的窗口比例/尺寸预渲染。不改则双窗口下预取系统性预热错的一端。

**D6 `force` 形参替代 `let*` 遮蔽**：`--multipage-sync-blocking`（`3011`）加可选形参 `force`，早退判据改为 `(or force (not (equal range <param>)))`，`--multipage-force-sync`（`3216`）传 `t`。**`force` = t 时必须同时绕过写回**：`3057`（blocking）的 `set-window-parameter` 用 `(unless force …)` 包裹，保持「强制同步 ≠ 已同步」的契约——这正是原 `let*` 遮蔽的语义（写的是 let 局部、退出即丢弃；现注释见 `3245-3250`）。`3173`（async）按同一规则包裹，但**注意 `force` 目前只到 blocking**（唯一 force 调用点 `3250`；async 分支 `3135` 不经过 force，`--multipage-sync-async` 签名 `3137` 为 `(window range)`），故 T3 必须二选一：**① 推荐**——给 `--multipage-sync-async` 加可选 `force` 并由 `3173` 用 `(unless force …)` 包裹（与 blocking 对称，未来 async 强制路径也不会持久化）；**②** 保持 `3173` 无条件写回，并在函数注释写明「async 无 force 路径，故无条件记账」。**禁止**在 async 里写引用未绑定 `force` 的 `(unless force …)`（会 void-variable）。**禁止**「先 setq nil 再调用」（blocking 内部会写回 range，等价持久化）。

## 任务

- [x] **T1 并集回收**：`--multipage-sync-blocking`（`3011`，回收判据 `3064`）与 `--multipage-sync-async`（`3137`，回收判据 `3196`）的保留口径由「本窗口 range」改为「`--multipage-all-visible-pages` 的并集」，`keep` 在循环前算一次并缓存到局部变量；渲染循环、失败清零、预取、早退判据**不动**。验收：新增 `--residency-union-keeps-other-window-rows`（两窗口视口 (4 . 5) / (9 . 10)，A sync 后 `(memq 9 (page-numbers))` 为真、B 的行未被回收）；变异（`keep` 换回本窗口 range）⇒ 该例转红；既有全量 ERT 绿。（依赖：无；风险：中）
- [x] **T2 near-resident / 淘汰判据并集化**：`--multipage-page-near-resident-p`（`2328`，判定 `2334-2337`）与 `--cache-eviction-victim`（`1132`，判定 `1145-1154`）的**集合来源**由 `--multipage-resident-page-range` 跨距改为并集成员；**边界口径各自保留**——near-resident 仍「并集成员 ±1」，eviction-victim 仍「并集成员、**不加 ±1**」（理由见 D4）；`--multipage-resident-page-range`（`1106`）返回值**不变**（prefetch 依赖它）。验收：① 新增 `--recycle-keeps-specs-inside-union-not-span`（驻留 {1 9 10}、跨距 1..10：`(page-near-resident-p 5)` = nil、recycle 后 5 的 spec 已释放、淘汰优先 5 而非 9）；② 新增 `--eviction-victim-has-no-boundary-slack`（驻留并集 {1 9}、entries 依次为页 10 与页 1（newest first）：`--cache-eviction-victim` = **页 10**——若给 eviction-victim 加了 ±1，页 10 会落进 `9+1` 的边界松弛被当成驻留页、victim 退化为 FIFO 兜底的末项**页 1**，该例转红；同一夹具下 `(page-near-resident-p 10)` 必须 = **t**、`(page-near-resident-p 11)` = nil，证明 near-resident 的 ±1 未被一并去掉）；③ `--geometry-recycle-keeps-*` / `--geometry-cache-*` / `--scroll-back-hits-cache` 仍绿。（依赖：T1；风险：中）
- [x] **T3 per-window range（最高风险）**：删 `--multipage-last-range` defvar（`2168`）、新增 `seshat-reader--range-parameter`；`2204` / `3053` / `3057` / `3118` / `3134` / `3171` / `3173` 全部改 window-parameter（值 `(BUFFER . RANGE)`，读时校验 buffer）；`--multipage-clear`（`2194`，复位行 `2204`）与态 A 复位（`3118`）遍历所有窗口清；D6 的 `force` 形参（`3011` + `3216`；`3057` / `3173` 的写回用 `(unless force …)` 包裹，`force` 需先传到 async，见 D6 的二选一）；同步 `3026` / `3223` / `3243` 三处 docstring/注释。验收：新增 `--range-is-per-window`（A sync 后 A 参数 = A range、B 参数 nil；B sync 后各自独立；A 再 sync 必须重做，渲染计数 +1）、`--force-sync-does-not-persist-range`（**`--multipage-force-sync` 前后该窗口的 range parameter 值不变**——不是「不早退」那么弱；随后同一区间的 `--multipage-sync` 仍会重做一轮，渲染计数 +1）；迁移 `seshat-reader-multipage-sync-async-test.el:415` 与 `seshat-reader-multipage-test.el:2799` 两处变量断言；态 A 逐字节等价（sync-async 全 18 例绿）。（依赖：无，与 T1 同文件，**建议串行**；风险：**最高**）
- [x] **T4 重锚换锚点**：`--ensure-window-layout`（`3816`，`set-window-start` 在 `3844`）的锚点由「最小驻留页」改为「最近的页行」，**保留**对所有窗口执行；新增 `--multipage-row-nearest (pos)`（遍历 `--pages`，比较 marker 位置，优先前驱、否则后继）；顺序保持 sync → 重锚 → `--ensure-centered`。`--multipage-window-start-page`（`3734`）与其 first 兜底**不改**（`224` / `240` / `586` / `729` / `895` 五处页码消费依赖它，见 D3）。验收：新增 `--ensure-window-layout-anchors-nearest-row`（B 的 window-start 设到「行首 marker + 1」，调 `--ensure-window-layout win-b` ⇒ window-start 被设为最近行首且属于 B 自己的页，不是最小驻留页）；fit-window / resize 用例仍绿。（依赖：T1；风险：中高，batch 需桩 window-start）
- [x] **T5 预取边界**：`--multipage-prefetch`（`2902`，边界计算 `2941`）签名改为 `(window range)`——**保留 `window`**（态 A 用它算 `--multipage-target-scale`）、新增 `range`，两处调用（`3067` / `3210`）传本窗口 range。验收：新增 `--prefetch-uses-calling-window-edge`（两窗口 (4 . 5) / (9 . 10)，A sync 后预取页是 A 的边界 6 或 2，不是并集边界 11）；`--state-a-prefetches-next-page` / `--state-b-prefetch-still-queues` / `--prefetch-queues-instead-of-rendering` 仍绿。（依赖：T1；风险：低）
- [x] **T6 文档 + tech-debt + 真机验收**：按「## 文档清单」逐项更新；`openspec/tech-debt.md` 勾销「双窗口独立滚动」条目（**同时把该条目的旧行号 `:3100-3104` / `:2971-2976` / `:3727-3734` / `:2139` / `:3040` / `:3079` / `:1771` / `:2217` 更新为本计划「## 根因」节的行号**）并新增「⑥ 横向」「prefetch 方向按窗口」两条；真机 30 页交替滚动（同 frame 双窗口 + 跨 frame 各一轮）；内存按「## 验证标准 · L3 ③」的**数值断言**验收（不看 message）。验收：真机四项全过（见 L3 ①–④）；文档清单逐项落地；tech-debt 两条新增 + 一条勾销。（依赖：T1–T5；风险：低——**不做则验收必然不通过**）。**已执行（2026-10-29）**：真机 6 项全部通过（用户回报：重启正常 / 双窗口 30 页不塌不跳 / 页间空行行为可接受 / 跨 frame 通过 / 单窗口无退化 / 内存无告警）；文档与 tech-debt 已同步（`docs/architecture.md` 新增「多窗口布局状态的两级归属」、`docs/emacs-reader.md` §7 双窗口限制改为已支持 + 新增 3 条已知限制、`CHANGELOG.md`、`openspec/decisions.md` 三条、`openspec/tech-debt.md` 勾销 1 条 + 新增 2 条、`openspec/roadmap.md`）；最终 L1/L2 见下。

### T1+T2 执行记录（2026-10-29）

**安全点**：`git stash create` = `1d8a40175048edcb034649f9ac46a61033c53776`（HEAD `31a31b91b5ea340e0dea5b96750b5e0c8fb7a83e`）。未回滚（验证全绿，安全点丢弃）。

**改动点**（行号为改后实测；`seshat-reader.el` 共 5600 行）

| # | 符号 / 位置 | 改动 |
|---|---|---|
| 1 | **新增** `seshat-reader--multipage-resident-pages`（`2160`） | 返回「驻留集合」：`--multipage-all-visible-pages` 的并集（升序去重）；**无窗口报范围时回退到 `--multipage-resident-page-range` 的跨距展开**（batch 夹具 / 布局未建立的 buffer），使无窗口路径与并集化之前逐位等价，而不是「回收一切」 |
| 2 | `--cache-eviction-victim`（`1132`，判定 `1162-1166`） | 判据 `(and range (>= page (car range)) (<= page (cdr range)))` → `(memq page (--multipage-resident-pages))`；**不加 ±1**，docstring 写明与 near-resident 的口径差异及理由（D4） |
| 3 | `--multipage-page-near-resident-p`（`2376`） | 加可选 `keep`；判据改为「并集成员 ±1」：`(memq page pages)` 或 `(memq (1- page) pages)` 或 `(memq (1+ page) pages)`；`pages` 缺省 `(or keep (--multipage-resident-pages))` |
| 4 | `--multipage-recycle-page`（`2409`） | 加可选 `keep` 并透传给 near-resident-p；docstring 说明「驻留 = 所有窗口的并集」与 KEEP 的用途 |
| 5 | `--multipage-sync-blocking`（`3147` 取 `keep`，`3155` 回收调用） | `keep` 在**渲染循环之前**取一次快照，回收判据 `(or (< page first) (> page last))` → `(not (memq page keep))`，回收时把 `keep` 传下去；渲染循环、早退判据、预取、内存体检**逐字未动**（`first`/`last` 仍只喂渲染循环） |
| 6 | `--multipage-sync-async`（`3268` 绑定 `keep`，`3298` 回收调用） | 同上；`keep` 绑在函数入口的 `let` 里（`--multipage-last-range` 写回之前），渲染 / 失败清零 / prune / 预取全部保持原样。删掉因此失效的 `(last (cdr range))` 绑定（否则 byte-compiler 报 unused lexical variable） |
| 7 | 三处 docstring / 注释同步 | blocking 与 async 的「区间外回收」改为「并集外回收」；async 里「三个循环仍只看本窗口」的注释改为「渲染与失败清零看本窗口，回收看并集」 |

**`keep` 的取值时机（重要偏差，优于计划的字面写法）**：计划 D1 说「`keep` 在循环前算一次」，最初的实现放在**回收循环之前（渲染循环之后）**，实测会让既有 3 个用例转红（`--sync-is-idempotent-per-range` / `--sync-recycles-pages-outside-range` / `--state-c-keeps-other-windows-pending` 之一）。原因：`--multipage-visible-range` 的页号来自 `window-start` 的 `page-at-pos`，而渲染插行 / 回收删行都会让 `window-start` 落到另一个页行上——快照取得越晚，越可能漏掉本轮真正可见的页。改成**在渲染循环之前**取快照后，并集必然包含本窗口本轮的 `range`，三个用例恢复绿色。改动仍在「回收循环之前」，符合 D1 的字面要求。

**性能方案与复杂度**：`--multipage-resident-pages` 的开销是 `O(F × W + U)`（`F` = frame 数、`W` = 每 frame 窗口数、`U` = 并集页数；`--multipage-all-visible-pages` 既有成本）。若在回收循环内**每页**重算并集，复杂度是 `O(R × (F × W + U))` ≈ `O(R²)`（`R` = 行数，`U ≥ R` 量级），双窗口 + preload 3 时每次滚动多出十几次 frame/window 遍历。方案是**两个可选参数**：
- `--multipage-page-near-resident-p (page &optional keep)` 与 `--multipage-recycle-page (page &optional keep)`，`keep` 由调用方算一次传入 ⇒ 回收循环整体 `O(R × 1) = O(R)`，每次 sync 只多**一次**并集计算（`O(F × W + U)`）；
- 未传 `keep` 的既有调用点（非 sync 路径：测试、单页回收）行为不变，只是各自算一次并集（`O(F × W + U)`，单次调用可接受）；
- `--cache-eviction-victim` 每次淘汰算一次并集（淘汰频率 = 缓存溢出次数，远低于滚动频率），不做 memoize：memoize 会引入「行表变了但缓存没失效」的陈旧窗口，而它的调用点本就不在热路径。

**3 个新用例**（均落在 `emacs/tests/seshat-reader-multipage-async-render-test.el`，复用该文件既有的 `--with-body` + `--viewports` 双窗口夹具；`multipage-test.el` 的 geometry 夹具是「buffer 不在任何窗口里」的单窗口形态，**无法表达有间隙的并集**，故未在那里新造第二套夹具）

| 用例 | 夹具 | 断言 | 结果 |
|---|---|---|---|
| `--residency-union-keeps-other-window-rows`（T1） | 12 页、preload 1、A 视口 (4 . 5)、B 视口 (9 . 10) ⇒ 并集 3..6 ∪ 8..11；A 走态 A（blocking） | `(memq 9 (page-numbers))`、`(assq 9 pages)`、`(assq 10 pages)` 为真；A 范围外且无人可见的 1 / 7 / 12 行**已回收**（排除「不回收」的假通过）；A 自己的 3 / 6 行在 | PASS |
| `--recycle-keeps-specs-inside-union-not-span`（T2） | 行 {1 5 9 10}、preload 0、A 视口 (1 . 1)、B 视口 (9 . 10) ⇒ 并集 {1 9 10}，跨距 (1 . 10) | `(--multipage-page-near-resident-p 5)` = nil、`9` / `10` = t；recycle 5 后其 spec 已释放（`--multipage-spec-cached-p 5` = nil）、9 的 spec 保留；前置断言跨距确实是 `(1 . 10)`（证明 5 落在跨距内却不在并集里） | PASS |
| `--eviction-victim-has-no-boundary-slack`（T2，判别性） | 行 {1 9}、preload 0、A 视口 (1 . 1)、B 视口 (9 . 9) ⇒ 并集 {1 9}；`entries` 写死为「页 10 最新、页 1 最旧」 | `--cache-eviction-victim` = **页 10**（若给淘汰判据加 ±1，10 落进 `9+1` 被当驻留页，victim 退化为 FIFO 末项页 1）；同夹具 `(near-resident-p 10)` = t、`(near-resident-p 11)` = nil | PASS |

注：`--recycle-keeps-specs-inside-union-not-span` 的行必须**有像素**（`--multipage-recycle-page` 只对「删下来的 spec 非 nil」的行释放缓存），故用例里把 `--page-spec` 取到的 spec 用 `--multipage-insert-page` 装回行上（占位行 spec 为 nil）。

**变异测试（强制，两次都真实转红，md5 恢复确认）**

| 变异 | 做法 | 结果 |
|---|---|---|
| T1：`keep` 换回本窗口 range | blocking `keep` → `(number-sequence first last)`；async `keep` → `(number-sequence (car range) (cdr range))` | `--residency-union-keeps-other-window-rows` **转红**：`FAILED ... (should (memq 9 (seshat-reader--multipage-page-numbers)))`（`Ran 3 tests, 2 results as expected, 1 unexpected`）；另两例仍绿。恢复后 md5 回到 `afed8c00466c659ab8e171c24a40483c` |
| T2：成员判定换回跨距 | `--multipage-page-near-resident-p` 函数体换回 `--multipage-resident-page-range` 的 ±1 跨距 | `--recycle-keeps-specs-inside-union-not-span` **转红**：`FAILED ... (should-not (seshat-reader--multipage-page-near-resident-p 5)) :value t`（`Ran 3 tests, 2 results as expected, 1 unexpected`）；`--eviction-victim-has-no-boundary-slack` 仍绿（它锁的是淘汰判据那一侧）。恢复后 md5 一致 |

**L1**（`make -C emacs/seshat-reader clean all`，改后终态）：EXIT 0；C `error:`/`warning:` **0/0**；elisp `Warning` **20**（= 基线；其中 `seshat-reader.el` 17 条全部是既有类别：docstring >80、reload 三形参、8 条 `not known to be defined` 前向声明，**我的改动区段 0 条**）；checkdoc **1**（`seshat-reader-annotation-queue.el:290`，属并发会话的改动文件，不是本批）；check-parens：`seshat-reader.el` / `seshat-reader-multipage-async-render-test.el` / `seshat-reader-multipage-sync-async-test.el` 全 ok。

**L2**（`make -C emacs/tests all`）：`FILES=47 TOTAL=1606 UNEXPECTED=0`，`check-criteria: PASS`。**对账**：42 基线文件 + 5 个并发会话新增测试文件（`seshat-covers/log/offline-invariant/reads/status-test.el`，100 例）= 47；1410 基线例 + 100（新文件）+ 103（并发会话在已跟踪文件里新增的 `ert-deftest`）− 10（并发会话删除的 `ert-deftest`）+ **3（本批）** = 1606 ✓。

**偏差与遗留**

1. **T1 与预取边界的耦合（计划未预见）**：回收按并集保留后，行表跨距由「本窗口 range」变为「并集跨距」，而 `--multipage-prefetch`（`2902`）的边界仍取 `--multipage-resident-page-range` 的跨距（D5/T5 尚未落地）⇒ 多窗口夹具下的预取页会落到并集外侧。两个既有用例因此必须临时改期望值（**只改期望值与注释，不改用例意图**）：
   - `seshat-reader-multipage-async-render-test.el` 的 `--pending-union-across-two-windows`：第二轮队列 `(3 7)` → **`(3 7 2)`**；
   - `seshat-reader-multipage-sync-async-test.el` 的 `--state-c-keeps-other-windows-pending`：队列 `(8 7)` → **`(8)`**（预取页 8 已在队列里，故本轮不新增队项）。
   **T5 落地后两处期望值必须回到 `(3 7)` / `(8 7)`**（T5 的验收 `--prefetch-uses-calling-window-edge` 与本条同源），两处都已加「T1 中间态」注释标明。
2. **`--multipage-resident-pages` 的无窗口回退**：并集为空（buffer 不在任何窗口 / 布局未建立）时回退到跨距展开。这是为了让 batch 夹具与并集化之前逐位等价（既有 `--geometry-*` / `--scroll-back-hits-cache` 用例全绿依赖它），但**真机双窗口下并集恒非空**，回退只覆盖「没人看得见」的情形。
3. **未做**：T3–T6（本批只交付 T1+T2）；4 个 defcustom、C 侧、居中族、`--multipage-scroll-direction`、`--multipage-resident-page-range` 返回值、渲染循环 / 失败清零 / 预取边界 / 早退判据均未动（逐项对照 `git diff` 确认）。

### T3 执行记录（2026-10-29）

**安全点**：`git stash create` = `a49c979c22e0c3b36464cd6b58808ee76e76c39d`（HEAD `cc6644e86a36b6ee333d4f6ddda4731809afbc80`）。未回滚（验证全绿，安全点丢弃）。

**md5 取证**（改前 → 改后）

| 文件 | 改前 | 改后 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `afed8c00466c659ab8e171c24a40483c` | `e0d787f3ea9cdfbc40fe6920d1203bfe` |
| `emacs/tests/seshat-reader-multipage-sync-async-test.el` | `b01edea128b2f6b5b88b0c921df264a0` | `7b46d1247dd3479c799114cb169020d6` |
| `emacs/tests/seshat-reader-multipage-test.el` | `4aece9c27cd836878396c2dfa9166811` | `852e39e06110ed8794f366d9f97d3b11` |

**12 处读写点最终清单**（`seshat-reader.el`，改后实测行号；grep `multipage-last-range|range-parameter|clear-last-ranges` 穷举，**无第 13 处**——其余命中只有新增符号与历史文档）

| # | 原行号（计划） | 实测行号（改后） | 位置 | 改法 |
|---|---|---|---|---|
| 1 | `2168` defvar-local | **`2216`** | 定义 | 删 `defvar-local seshat-reader--multipage-last-range`，换 `defconst seshat-reader--range-parameter`（`'seshat-reader-range`），docstring 迁移原说明 + 补「为什么从 buffer 变量改成窗口参数（多窗口下早退判据必须按窗口）」+「为什么值里带 BUFFER」 |
| 2 | — | **`2244`** | 读（新增封装） | `seshat-reader--multipage-last-range-for (window)`：`window-live-p` 兜底 + **buffer 校验**，返回 RANGE 或 nil |
| 3 | — | **`2260`** | 写（新增封装） | `seshat-reader--multipage-set-last-range (window range)`：写 `(BUFFER . RANGE)` |
| 4 | — | **`2273`** | 复位（新增封装） | `seshat-reader--multipage-clear-last-ranges`：遍历**所有**显示本 buffer 的窗口清参数 |
| 5 | `2204` 复位行 | **`2314`** | `--multipage-clear` | `(setq --pages nil --last-range nil)` → `(setq --pages nil)` + `(--multipage-clear-last-ranges)` |
| 6 | `3026` docstring | **`3169`** | blocking docstring | 「previous run is remembered in `--multipage-last-range`」→ 窗口参数 `--range-parameter`；新增 FORCE 段落（绕过早退 **且** 不记账，原 let 遮蔽契约） |
| 7 | `3053` 早退判定 | **`3206`** | blocking | `(not (equal range <param>))` → `(or force (not (equal range (--multipage-last-range-for win))))` |
| 8 | `3057` 写回 | **`3214`** | blocking | `(setq --last-range range)` → `(unless force (--multipage-set-last-range win range))` |
| 9 | `3118` 态 A 复位 | **`3287`** | `--multipage-sync` 态 A | `(setq --last-range nil)` → `(--multipage-clear-last-ranges)`（**全窗口**） |
| 10 | `3134` 早退分支 | **`3303`** | `--multipage-sync` | `(equal range --last-range)` → `(equal range (--multipage-last-range-for win))` |
| 11 | `3171` 读 previous | **`3349`** | `--multipage-sync-async` | `(previous --last-range)` → `(previous (--multipage-last-range-for window))` |
| 12 | `3173` 写回 | **`3359`** | `--multipage-sync-async` | `(setq --last-range range)` → `(unless force (--multipage-set-last-range window range))` |
| 附 | `3216` / `3249` | **`3406`** / **`3440`** | `--multipage-force-sync` | 删 `let*` 遮蔽（含 `last-range` 绑定），改 `(--multipage-sync-blocking window t)`；docstring 与注释改述 FORCE |

测试侧 2 处引用（步骤 4 迁移，见下）。

**封装函数签名 + buffer 校验方案**（值 `(BUFFER . RANGE)`，读时校验）

```elisp
(defconst seshat-reader--range-parameter 'seshat-reader-range ...)

(defun seshat-reader--multipage-last-range-for (window)
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (window-live-p win)
      (let ((value (window-parameter win seshat-reader--range-parameter)))
        (when (eq (car-safe value) (current-buffer))   ; ← 关键：切 buffer 不清参数
          (cdr value))))))

(defun seshat-reader--multipage-set-last-range (window range)
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (window-live-p win)
      (set-window-parameter win seshat-reader--range-parameter
                            (cons (current-buffer) range)))))
```

**全窗口清理方案**（陷阱 3：只清本窗口 ⇒ 「行表已空 + 另一窗口区间恰好相等 → 早退 → 行永不重建」）

```elisp
(defun seshat-reader--multipage-clear-last-ranges ()
  (dolist (window (get-buffer-window-list (current-buffer) nil t))  ; 所有 frame
    (set-window-parameter window seshat-reader--range-parameter nil)))
```

`--multipage-clear`（`2314`）与态 A 复位（`3287`）都改调它。`--multipage-sync-blocking` / `--multipage-sync` 的默认窗口解析 `(if (window-live-p window) window (selected-window))` **保持不变**。

**force 对称实现（D6 ① 方案）**

| 位置 | 改动 |
|---|---|
| `--multipage-sync-blocking`（`3150`） | 签名 `(&optional window force)`；早退判据 `(or force (not (equal range <param>)))`；写回包在 `(unless force …)`（`3214`） |
| `--multipage-sync-async`（`3306`） | 签名 `(window range &optional force)`；写回同样 `(unless force …)`（`3359`）；`previous` 仍按窗口读（失败清零要看真实上一轮）；docstring 说明「当前无调用者传 force，保留形参是为了未来 async 强制路径不会静默把『强制』变成『已同步』；写回用 `unless` 而非未绑定变量」 |
| `--multipage-force-sync`（`3406`） | 删 `let*` 遮蔽，`(--multipage-sync-blocking window t)`（`3440`）；注释改述 FORCE 形参 |
| `--multipage-sync`（`3295`） | 签名**不变**（`(&optional window)`）：force 的唯一入口 `--multipage-force-sync` 直接调 blocking 并传 `t`，故无「分派处透传」可做；未引入未使用形参 |

**迁移的 2 处既有断言**（只改取值方式，语义不变）

| 位置 | 改法 |
|---|---|
| `seshat-reader-multipage-sync-async-test.el`（原 `415`，现 `414`–`417`） | `(should (equal '(1 . 5) seshat-reader--multipage-last-range))` → `(should (equal '(1 . 5) (seshat-reader--multipage-last-range-for (selected-window))))` |
| `seshat-reader-multipage-test.el`（原 `2799`，现 `2799`–`2806`） | `(should-not seshat-reader--multipage-last-range)` → 取 `(get-buffer-window-list (current-buffer) nil t)`，先断言非空，再逐窗口断言 `(window-parameter win seshat-reader--range-parameter)` 为 nil |

**2 个新用例**（均在 `seshat-reader-multipage-sync-async-test.el`，复用既有 `--with-buffer` + `--viewports` 双窗口夹具，未新造夹具）

| 用例 | 夹具 | 断言 | 结果 |
|---|---|---|---|
| `--range-is-per-window`（`921`） | 12 页、preload 1、A 视口 (4 . 5) ⇒ 范围 (3 . 6)、B 视口 (9 . 10) ⇒ 范围 (8 . 11)，态 A | ① A sync ⇒ 范围 (3 . 6)、A 的页全渲染、A 参数 `(BUFFER . (3 . 6))`（含 `car` = 当前 buffer）、B 参数 nil；② B sync ⇒ 范围 (8 . 11)、渲染页不含 3–6、两侧记账互不覆盖；③ A 区间未变 ⇒ **早退**（返回 nil、渲染 0 次）；④ A 移到 B 刚同步过的 (8 . 11) ⇒ **必须重做**（判据：A 旧范围的行 4 被回收，早退时它会留着）；⑤ 两窗口都有记账后 `--multipage-clear` 把**两个**窗口一起清掉 | PASS |
| `--force-sync-does-not-persist-range`（`1002`） | 8 页、preload 1、单窗口；视口逐轮下移使「记账区间 ≠ 本轮区间」 | ③ `--multipage-force-sync` 前后 `(window-parameter win --range-parameter)` **逐位相等**（不是「不早退」这种弱断言），且强制 pass 真的干活（渲染 `(6 7)`）；④ 同区间普通 `--multipage-sync` 仍重做（渲染 `(7)`）；⑤ 区间**未变**时强制同步仍绕过早退（渲染 `(7)`）——FORCE 的另一半 | PASS |

**变异测试（两次都真实转红，md5 恢复确认）**

| 变异 | 做法 | 结果 |
|---|---|---|
| T3 主变异：window-parameter → buffer 变量 | 在 `--multipage-clear-last-ranges` 之后追加临时 `defvar-local` + 三个 helper 重定义（读/写/清都走 buffer 级变量），`make -C emacs/seshat-reader all` 重编译 | `--range-is-per-window` **转红**：`FAILED … ((should-not (seshat-reader--multipage-last-range-for win-b)) :value (3 . 6))`（B 拿到 A 的记账，正是修前缺陷；`Ran 2 tests, 1 results as expected, 1 unexpected`）；`--force-sync-does-not-persist-range` 仍绿。撤掉后 md5 回到 `3f7eeeccd07aaec42af40d3a199b4e8d`（此后仅给 `--multipage-clear` 补了一段 docstring，终态见上表 `e0d787f3…`） |
| D6 变异：去掉 `unless force` | blocking `3214` 的 `(unless force (--multipage-set-last-range win range))` → 无条件写回，重编译 | `--force-sync-does-not-persist-range` **转红**：`FAILED … ((should (equal before (window-parameter …))) :form (equal (#<killed buffer> 2 . 5) (#<killed buffer> 3 . 6)))`（强制同步把记账改写了）；`--range-is-per-window` 仍绿。恢复后 md5 一致 |

**L1**（`make -C emacs/seshat-reader clean all`，改后终态）：EXIT 0；C `error:`/`warning:` **0/0**；elisp `Warning` **20**（= T1+T2 基线，逐条核对：`seshat-reader.el` **17 条**全是既有类别（docstring >80、reload 三形参、`not known to be defined` 前向声明），**本批改动区段 0 条**）；checkdoc **1**（`seshat-reader-annotation-queue.el:290`，并发会话的改动文件，不是本批）；check-parens：`seshat-reader.el` / `seshat-reader-multipage-sync-async-test.el` / `seshat-reader-multipage-test.el` 全 ok。

**L2**（`make -C emacs/tests all`）：`FILES=47 TOTAL=1608 UNEXPECTED=0`，`check-criteria: PASS`。**对账**：T1+T2 基线 47 文件 / 1606 例 + **本批 2 例** = 1608 ✓（`seshat-reader-multipage-sync-async-test` 18 → 20 例；其余 46 文件计数未变，故并发会话在本批期间未新增/删除用例）。

**偏差与遗留**

1. **计划/任务书的验收判据与 per-window 语义冲突（已改写，理由如下）**：原写「A 再 sync 必须重做（渲染计数 +1，证明没有按 B 的 range 早退）」。但在 per-window 记账下，A 自己的区间未变时**正确**行为就是早退（渲染 0 次）——「重做」恰好是 buffer 级变量（记账被 B 覆盖）的表现，且该断言在变异 A 下**同样成立**（非判别性，抓不到变异）。故 `--range-is-per-window` 改为两条判别性断言：③「A 区间未变 ⇒ 早退、0 渲染」（变异 A 下变红）＋④「A 移到 B 刚同步过的区间 ⇒ 必须重做」（变异 A 下 A 会早退、旧行不回收 → 变红，且这条正是「早退但行表已清 = 永久空白」的高危路径）。用例 docstring 已写明这层理由。
2. **态 A 的早退返回 nil**：`--multipage-sync-blocking` 的 `range` 在 `when` 体内（既有结构，未改），故态 A 早退返回 nil（「无事可做」），与 async 半侧「早退返回本区间」不同。③ 因此断言 `should-not`。这是既有契约，`--multipage-force-sync` 的 `(--multipage-clear-synced-pending synced)` 依赖它（nil ⇒ 不出队）。
3. **新用例里的预取页期望值按实测**：预取边界仍取 `--multipage-resident-page-range` 跨距（D5/T5 未落地），故 `--force-sync-does-not-persist-range` 的渲染序列是 `(1 2 3 4 5 6)` / `(6 7)` / `(7)` / `(7)`，与 T1+T2 的中间态期望值（`(3 7 2)` / `(8)`）**不冲突**（不同夹具、不同用例）。T5 落地后若预取边界改成本窗口 range，这两条期望值需同步复核。
4. **未做**：T4–T6（本批只交付 T3）；4 个 defcustom、渲染循环 `first`/`last`、T1/T2 的并集判据、`--multipage-resident-page-range` 返回值、`--multipage-sync` 签名均未动（逐项对照 `git diff` 确认）。`openspec/tech-debt.md` / `openspec/decisions.md` / `openspec/completed/*` 里的旧变量名 `--multipage-last-range` 属历史记录，未改；`docs/` 与 tech-debt 的同步归 T6。

### T4+T5 执行记录（2026-10-29）

**安全点**：`git stash create` = `a99b3a7d782852bd77c60ff766e6875fde1c7607`（HEAD `cc6644e86a36b6ee333d4f6ddda4731809afbc80`）。未回滚（验证全绿，安全点丢弃）。

**md5 取证**（改前 → 改后）

| 文件 | 改前 | 改后 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `e0d787f3ea9cdfbc40fe6920d1203bfe` | `0c3da9ef89be923a231b3b736ebb97b6` |
| `emacs/tests/seshat-reader-multipage-async-render-test.el` | `1cd265c8c751fe08ed1f48d14eeaa6d9` | `11fda56f939594fc1734e944bf10f6fa` |
| `emacs/tests/seshat-reader-multipage-sync-async-test.el` | `7b46d1247dd3479c799114cb169020d6` | `6a71005fd663c2e1dedb632a63591c97` |
| `emacs/tests/seshat-reader-multipage-test.el` | `852e39e06110ed8794f366d9f97d3b11` | `d042734fa77d75c174b2ff138cd5926f` |

**T4 改动点**（`seshat-reader.el`，行号为改后实测）

| # | 符号 / 位置 | 改动 |
|---|---|---|
| 1 | **新增** `seshat-reader--multipage-row-nearest (pos)`（`4013`） | 遍历 `--pages`（升序），返回「起点 ≤ POS 的最后一行的前驱」条目 `(PAGE . MARKER)`；无前驱时退回最近后继（POS 在第一行之前，实践中不可达，保留为防御）；无行或 POS 非整数返回 nil。docstring 写明为什么 `--multipage-page-at-pos` 答不了这件事（只答「包含 POS 的页」，POS 落在行外返回 nil，且没有「最近」的概念） |
| 2 | `--ensure-window-layout`（`4045`，`set-window-start` 在 `4104`） | 锚点由 `(assq (--multipage-window-start-page window) --pages)`（= 最小驻留页）改为 `--multipage-row-nearest (window-start window)`；顺序仍为 sync → 重锚 → `--ensure-centered` |
| 3 | `--multipage-window-start-page`（`4003`）及其 `first` 兜底 | **一字未动**（`git diff -U0` 里没有任何 hunk 触及它的 `defun`；`--ensure-window-layout` 内对它的唯一引用已删除，其余 5 处页码消费保持原样） |

**触发条件的偏差（必须记录，是对任务书字面的扩展）**：守卫由「`--multipage-page-at-pos (window-start)` 为 nil」改为「最近页行的 `marker-position` **小于** 窗口起点」，即窗口起点只要不在页行行首（行中间 / 页间空行 / 最后一个页行之后）就回到该行行首。理由三条：

1. 任务书的验收写法是「`window-start` = 某页行首 marker + 1 ⇒ 被设为最近页行的 marker」。`--multipage-page-at-pos` 对行中间的 POS **返回该页**，旧守卫不触发 ⇒ 该用例在旧守卫下恒红；
2. 真机缺陷路径（B 从 p12 塌到 p6）里，B 的 `window-start` 被删除操作推到**页间空行**上，而空行按 `--multipage-page-at-pos` 的语义属于上一页 ⇒ 旧守卫同样不触发，D3 的「换锚点」在这种情形下是死代码；
3. 新条件不改变「对哪些窗口执行」：窗口过滤（`window-live-p` + `(eq (window-buffer window) (current-buffer))` + `derived-mode-p`）与唯一注册点都未动，函数仍对 hook 报告的**每一个**窗口执行（陷阱 4）。

**行为代价（需真机 L3 复核）**：页行是单行、页间是 `seshat-reader-page-gap-lines` 个空行，因此视口不能再停在页间空行上（会被拉回上一页行行首）。这是「页号稳定」想要的效果，但确实是 T4 之外的一处行为变化；若真机上「停在页间」是期望行为，回退办法是把守卫换回 `page-at-pos` 并接受 D3 在空行情形下不生效。

**T5 改动点**

| # | 位置 | 改动 |
|---|---|---|
| 1 | `--multipage-prefetch`（`3046`） | 签名 `(&optional window)` → `(window range)`；边界计算删掉内部 `(let ((range (--multipage-resident-page-range)))`，直接用入参 RANGE；docstring 说明「不得用行表跨距（并集下跨距的另一端属于另一个窗口）」「保留 WINDOW 是因为态 A 同步分支要用它算 `--multipage-target-scale`」 |
| 2 | `--multipage-sync-blocking`（`3255`） | `(--multipage-prefetch win range)`（本窗口本轮 range） |
| 3 | `--multipage-sync-async`（`3421`） | `(--multipage-prefetch window range)` |
| 4 | `--multipage-resident-page-range`（`1106`） | **返回值与语义不变**，docstring 补「这是行表跨距、不是驻留集；不再用作 prefetch 边界（D5）」 |

**`--multipage-resident-page-range` 的消费方（因此不能删/不能改语义）**：`--multipage-resident-pages` 的**无窗口回退**（`2199`，batch 夹具与「buffer 不在任何窗口里」的路径靠它逐位等价）；测试 `seshat-reader-page-spec-test.el:410`、`seshat-reader-multipage-test.el:2264/2288/2347`、`seshat-reader-multipage-async-render-test.el:858`。

**5 处测试调用点迁移**（签名从可选到必填，只补实参，语义不变：这些夹具的 buffer 不在窗口里，跨距就是旧实现算出的值）

| 文件 | 位置 |
|---|---|
| `seshat-reader-multipage-test.el` | `--geometry-prefetch-*` 三处 + `--geometry-cache-bounded-while-scrolling` 一处（`2404` / `2416` / `2441` / `2470`） |
| `seshat-reader-multipage-async-render-test.el` | `--prefetch-queues-instead-of-rendering`（`520`） |

`seshat-reader-multipage-test.el:2799` 的 `(symbol-function 'seshat-reader--multipage-prefetch)` 桩是 `(&rest _)`，无需改。

**中间态期望值恢复（原值 vs 实测 vs 最终写入）**

| 用例 | T1 前的原值 | T5 后实测 | 最终写入 | 结论 |
|---|---|---|---|---|
| `--pending-union-across-two-windows`（第二轮队列） | `(3 7)` | `(3 7)` | `(3 7)` | 实测回到原值 ✓ |
| `--state-c-keeps-other-windows-pending` | `(8 7)` | `(8 7)` | `(8 7)` | 实测回到原值 ✓ |

两处的「T1 中间态」注释已删除，改为按 T5 口径描述（A 取 2 = 3−1、B 取 3 = 4−1；态 C 取 7 = 6+1）。

**顺带修掉一处 T3 之后失效的断言（`--pending-union-across-two-windows` 第三轮）**：该轮的 A 与第一轮区间相同，T3 的 per-window 记账让它**必然早退**（渲染 0 次、队列原样），所以 T3 时期望值 `(3 7 2)` 之所以「通过」只是因为第二轮留下的队列恰好就是 `(3 7 2)`，属巧合而非覆盖。T5 后第二轮队列是 `(3 7)`，第三轮实测 `(3 7)`，故该断言改为 `(3 7)` 并在注释里说明：本轮只锁「早退后队列不变」，「B 的队项穿过 A 的裁剪」由 `--state-c-keeps-other-windows-pending` 覆盖（那里是强制同步，一定真跑裁剪）。

**2 个新用例**（均在 `seshat-reader-multipage-async-render-test.el`，复用该文件既有的 `--with-body` + `--viewports` 双窗口夹具）

| 用例 | 夹具 | 断言 | 结果 |
|---|---|---|---|
| `--ensure-window-layout-anchors-nearest-row`（T4） | 行 `{3 4 5 6 9 10}`（9/10 属「本窗口」，3..6 属另一个窗口）、preload 1、12 页；`--multipage-sync` 桩成只记顺序，`window-start` / `set-window-start` 桩住记录实参 | ① `--multipage-row-nearest` 语义：行中间（页 5+1、页 9+1）取该页、`point-min` 取页 3、末行之后取页 10、无行返回 nil；② 起点 = 页 9 行首 + 1 ⇒ `set-window-start` 恰好一次、实参 = 页 9 行首，且**不是**最小驻留页 3 的行首；③ 顺序 `(sync anchor)`；④ 起点本来就在行首 ⇒ 一次都不调 | PASS |
| `--prefetch-uses-calling-window-edge`（T5） | 12 页、preload 0、方向向前；A 视口 (4 . 5)、B 视口 (9 . 10)；point 放 A 的首行使 4/5 走同步渲染 | A 一轮态 B 后队列 = `(6)`（A 的上沿 5 + 1），且不含 11（并集跨距 4..10 的边界 + 1） | PASS |

**变异测试（强制，两次都真实转红，md5 恢复确认）**

| 变异 | 做法 | 结果 |
|---|---|---|
| T4：锚点换回最小驻留页 | `(cadr entry)` → `(cadr (assq (car (car seshat-reader--pages)) seshat-reader--pages))` | `--ensure-window-layout-anchors-nearest-row` **转红**：`FAILED … (should (equal (seshat-reader-multipage-async-test--row-start 9) (cadr …))) :form (equal 13 1)`（实参变成页 3 的行首 1，期望页 9 的 13）；`--prefetch-uses-calling-window-edge` 仍绿。恢复后 md5 回到 `0c3da9ef…` |
| T5：边界换回行表跨距 | async 调用点 `range` → `(seshat-reader--multipage-resident-page-range)` | `--prefetch-uses-calling-window-edge` **转红**：`FAILED … (should (equal '(6) …)) :form (equal (6) (11))`（预取页变成并集跨距上沿 + 1 = 11）；T4 用例仍绿。恢复后 md5 一致 |

**踩到的坑（写进记录以免重犯）**：ERT 与 `emacs --batch -L` 加载的是 **`.elc`**，改完 `.el` 不重编译就会跑到旧字节码 —— 第一次 T4 变异因此**假绿**（`Ran 1 tests, 1 results as expected`），补跑 `make -C emacs/seshat-reader all` 后才转红。变异测试与「改盘后重验」都必须先重编译。

**L1**（`make -C emacs/seshat-reader clean all`，改后终态）：EXIT 0；C `error:`/`warning:` **0/0**；elisp `Warning` **20**（= 基线，逐条：`seshat-reader.el` 17 条全是既有类别（docstring >80、reload 三形参、8 条 `not known to be defined`）+ `seshat-reader-bookmark.el` 1 + `seshat-reader-saveplace.el` 1 + `seshat-reader-translate.el` 1；**本批改动区段 0 条**）；checkdoc **1**（`seshat-reader-annotation-queue.el:290`，并发会话的改动文件，不是本批）；check-parens：`seshat-reader.el` / `seshat-reader-multipage-async-render-test.el` / `seshat-reader-multipage-sync-async-test.el` / `seshat-reader-multipage-test.el` 全 ok。

**L2**（`make -C emacs/tests all`）：`FILES=47 TOTAL=1610 UNEXPECTED=0`，`check-criteria: PASS`。**对账**：T3 基线 47 文件 / 1608 例 + **本批 2 例** = 1610 ✓（`seshat-reader-multipage-async-render-test` 22 → 24 例；`seshat-reader-multipage-sync-async-test` 20 例、`seshat-reader-multipage-test` 103 例及其余 44 文件计数未变）。

**偏差与遗留**

1. **T4 的触发条件扩展**（见上「触发条件的偏差」）：守卫从 `page-at-pos` 改为「不在页行行首」。这是任务书验收写法与真实缺陷路径共同要求的，但它扩大了「什么时候重锚」的集合（行中 / 页间空行也会被拉回行首），需真机 L3 ① ② 复核「不塌不跳」。
2. **T4 用例把 `--multipage-sync` 桩成 no-op**：本用例只锁锚点来源与「sync → 重锚 → 居中」顺序；不桩的话，桩出来的 `window-start` 会先改变 sync 算出的范围，把回收副作用搅进锚点断言。sync 自身的渲染 / 回收由既有用例覆盖。
3. **`--pending-union-across-two-windows` 第三轮的语义降级**（见上）：T3 的 per-window 记账让该轮必然早退，原 `(3 7 2)` 断言在 T3 时已是非判别性的巧合。
4. **未做**：T6（文档 + tech-debt + 真机 L3）。4 个 defcustom、C 侧、居中族、`--multipage-scroll-direction`、T1/T2 的并集回收判据、T3 的 window-parameter 封装、`--multipage-window-start-page` 均未动（逐项对照 `git diff` 确认）。

### T6 执行记录（2026-10-29）

**真机验收（用户回报，6 项全部通过）**：① 重启正常；② 双窗口 30 页交替滚动不塌不跳；③ 页间空行行为可接受（T4 的行为代价被用户确认）；④ 跨 frame 通过；⑤ 单窗口无退化；⑥ 内存无告警。

**文档同步（逐项）**

| 文件 | 改动 |
|---|---|
| `docs/architecture.md` | 新增 `## 多窗口布局状态的两级归属（2026-10-29）`：buffer 级（`--pages` / spec 缓存 / 尺寸缓存 / `--multipage-scroll-direction`）vs 窗口级（可见范围派生 / window-parameter 区间 / vscroll·hscroll / fit 与缩放）、驻留集并集语义（回收按并集，渲染·失败清零·预取·早退按本窗口）、早退判据按窗口、重锚锚点=最近页行、与 P2-B D8 的一致性 |
| `docs/emacs-reader.md` | §7「多窗口页码各自派生（缺口）」→「多窗口各自滚动（纵向已支持）」；§7 末新增 `### 已知限制（多窗口滚动，2026-10-29）` 三条（横向按单窗口宽度写 buffer 全局几何 / 视口不能停在页间空行 / 预取方向 buffer 级） |
| `CHANGELOG.md` | `### 修复` 顶部新增一条（驻留集并集化 + 每窗口同步区间 + 重锚最近页行 + 7 例 ERT + 真机 6 项） |
| `openspec/decisions.md` | 追加三条 2026-10-29 决策（并集化只改回收判据 / 每窗口区间用 window-parameter 且值带 buffer 校验 / 重锚换锚点而非移除） |
| `openspec/tech-debt.md` | 「P2-B 遗留」§1 勾销为**已解决**（指向 completed 归档，旧行号更新为改后实测值并改为「函数名 + 行号」双定位）；新增 §7 横向（居中/贴左按单窗口宽度写 buffer 全局几何）、§8 预取方向 buffer 级 |
| `openspec/roadmap.md` | follow-up 条目标为**已完成**（指向 completed 路径）；候选池状态段同步 |

**共享文件并发纪律**：`CHANGELOG.md` / `openspec/decisions.md` / `openspec/tech-debt.md` 只做「追加 / 局部插入」，改前记 md5、改后 `git diff -U0` 核对删除行只落在本批目标条目内（CHANGELOG 2 insertions 0 deletions；decisions 30 insertions 0 deletions；tech-debt 20 insertions 5 deletions，删除行全部是本批要勾销/改写的 §1 条目自身的行）。未 commit / 未 push。

**L1**（`make -C emacs/seshat-reader clean all`）：EXIT **0**；C `error:`/`warning:` **0 / 0**；elisp 字节编译 `Warning:` **20** = 基线（`seshat-reader.el` 17 + `bookmark` 1 + `saveplace` 1 + `translate` 1，逐条核对全为既有类别，本批改动区段 0 条）；checkdoc **1**（`seshat-reader-annotation-queue.el:290`，属**并发会话**改动文件，不是本批）；`elisp_check_parens`（verify 隔离实例）：`seshat-reader.el` / `seshat-reader-multipage-async-render-test.el` / `seshat-reader-multipage-sync-async-test.el` / `seshat-reader-multipage-test.el` **全 ok**。

**L2**（`make -C emacs/tests all` = ert + check-criteria）：`FILES=47 TOTAL=1610 UNEXPECTED=0`，**0 skipped**（唯一一处 `skipped` 出现在 check-criteria 的「期望失败」自检夹具输出里，属夹具自身预期），`check-criteria: PASS`，EXIT **0**。

**L2 并发对账**：基线（T4+T5 后）= 47 文件 / 1610 例；T6 **不新增用例** ⇒ 期望 47 / 1610，实跑一致 ✓。核对方式：`git status` 无未跟踪的 `tests/*.el`（T1+T2 期间并发会话的 5 个新测试文件已被其提交）；`git diff -U0 -- emacs/tests | grep -c '^+.*(ert-deftest'` = **7**（全部来自 T1–T5：async-render-test 5 + sync-async-test 2）、删除 0 ⇒ 本批期间无并发会话新增/删除用例。

**偏差**：无功能偏差（T6 只改文档）。两处诚实标注：① `ctx_execute` 沙箱连续两次 120 s 超时（`rules/tooling.md` 回退纪律）⇒ 检索与命令回退 `eca__grep` / `eca__shell_command`；② `openspec/decisions.md` 中 2026-10-29「双窗口独立滚动另立项」旧条目内的 `active/...` 链接仍是旧路径（并发共享文件，按纪律**只报告不修改**）；`openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` 的同类旧链接已改为 `completed/`。

## 陷阱

1. **不要一起改渲染循环的 `first`/`last`**：只有回收循环换判据；渲染（约 `3058-3061` / `3180-3192`）、失败清零（约 `3204-3210`）、预取边界仍必须用本窗口 range。用并集喂渲染循环 = 把另一窗口的页当本窗口页渲染 + 态 B 下全登记进队列（队列膨胀到并集大小）。
2. **不要用「先 setq nil 再调用」替换 `let*` 遮蔽**（D6 已说明原因：blocking 内部会把 range 写回，等价于把「强制同步」持久化成「已同步」）。
3. **`--multipage-clear`（复位行 `2204`）与态 A 复位（`3118`）必须遍历所有窗口清参数**：只清本窗口会留下「行表已空 + range 恰好相等 → 早退 → 行永不重建」的永久空白，与用户报的现象 2 同形，排障极易误判为「异步渲染没补上」。
4. **不要移除 `--ensure-window-layout` 对非当前窗口的重锚，只换锚点**（D3）。
5. **`--multipage-resident-page-range`（`1106`）是跨距不是集合**：并集下跨距会把两窗口之间的页算成驻留 ⇒ near-resident 与淘汰偏好双双失效；改用集合成员判定，且不得改它的返回值（prefetch 依赖它）。
6. **内存验收不能靠 `--multipage-check-memory`（`2991`）的 message**：buffer 级 `--multipage-memory-warned` 保证每 buffer 只报一次，双窗口下首次越线后不再提示。改为：**用 elisp 表达式直接断言** `--multipage-resident-spec-megabytes`（`2961`）的数值 vs `seshat-reader-multipage-memory-warning-mb`（`1428`），**在真机 L3 ③ 做**（batch 里没有真实双窗口，写 ERT 也只能测到桩窗口）。

## 文档清单

`docs/architecture.md`（布局状态归属：buffer 级驻留集 vs 窗口级 range / 视口）、`docs/emacs-reader.md`（双窗口限制解除到「纵向不塌不跳」，横向 ⑥ 仍为已知限制）、`CHANGELOG.md`、`openspec/decisions.md`（并集化 + 每窗口 range + 重锚换锚点三条决策）、`openspec/tech-debt.md`（勾销「双窗口独立滚动」条目；新增「⑥ 横向」与「prefetch 方向按窗口」两条；**勾销该条目时一并把它的旧行号（`:3100-3104` / `:2971-2976` / `:3727-3734` / `:2139` / `:3040` / `:3079` / `:1771` / `:2217`）更新为本计划「## 根因」节的行号**）、`openspec/roadmap.md`。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` → EXIT 0；C 0 error 0 warning；elisp `Warning` ≤ 20（基线）；checkdoc 0；check-parens 通过。
- **L2**：`make -C emacs/tests ert` → 0 unexpected / 0 skipped；`check-criteria` PASS。**基线口径**：42 文件 / 1410 例（P2-B 归档口径）；因并发会话存在，实跑数字必须逐项对账，不得把实跑总数当本项成果。
- **L3 真机**：① 同 frame 上下分窗，滚 A 30 页，B 的 `window-start` 页号变化 ≤ 0，A 停止后 B 无需显式 goto 即回原处；② 跨 frame 双窗口各一轮；③ 内存：两窗口相距 ≥ 20 页、preload 默认 2 时 `--multipage-resident-spec-megabytes` < `seshat-reader-multipage-memory-warning-mb`（断言数值，不看 message）；④ 既有行为回归：单窗口滚动 30 页无退化、页间无跳变。
- **变异测试（强制）**：把 T1 的 `keep` 换回本窗口 range ⇒ `--residency-union-keeps-other-window-rows` 必须转红；把 D4 的集合成员判定换回 `--multipage-resident-page-range` 跨距 ⇒ `--recycle-keeps-specs-inside-union-not-span` 必须转红；把 T3 的 window-parameter 换回 buffer 变量 ⇒ `--range-is-per-window` 必须转红。**现有 103 例在单窗口夹具下「并集 == 本窗口」，无法抓到这几类变异**，故新用例是唯一红灯来源，不得省。
- **任务类型**：elisp 验证走 `verify` 隔离实例（`set_task verify` → 预拉起 → 轮询 alive → 验证 → `set_task auto` → `instance stop` → `instance_status` 确认）。
- **安全点与回滚**：每批开始前建 git 安全点（`git stash create`）；L1 失败 ≤3 轮、L2/L3 失败 ≤2 轮，耗尽即回滚该批并报告，不跨批回滚。
- **审查结论（plan-reviewer 2026-10-29，有条件通过）**：0 blocking / 1 major（D6 `force` 未写明绕过写回，与 T3 验收字面冲突）/ 5 minor（D4 的 ±1 差异、D5 prefetch 签名、陷阱 6 措辞、变异测试补 D4、D3 兜底 `first` 结论）/ 2 nit（tech-debt 旧行号等）——**均已在本文件修订**。

## 假设复盘

Phase 1 的两条假设已被推翻，必须记录（被推翻的假设已在 D3 / 非目标里改写为实际做法）：

| 假设 | 结果 | 说明 |
|---|---|---|
| H4 `--multipage-page-numbers` 的 8 处消费在并集下只是「浪费」 | **被推翻 ✗** | 5 处按窗口宽度写几何（`557` refit / `3937` centered-p / `3976` center-page / `4209` refit-window / `5242` redisplay-all-windows）在并集下会互相踩；**上下分窗同宽时结果相同**，故当前症状不受影响，但「不同宽」场景属 ⑥ 范围 |
| H5 可移除 `--ensure-window-layout` 对非当前窗口的重锚 | **被推翻 ✗** | 它是 `split-window` / 换 buffer / 重载 / 回收删行四条路径唯一的纠正点；移除会引入新错位 ⇒ 改为 D3「换锚点、保留执行」 |
