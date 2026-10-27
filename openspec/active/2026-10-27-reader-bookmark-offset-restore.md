# 阅读器书签与 saveplace 的页内偏移恢复

## 当前状态

- 阶段：Phase 4（Review & Document）· 批次 1 与文档已收尾，仅剩 T5 真机待用户确认
- 已确认：方案 ✅（用户 2026-10-27）、计划 ✅（用户 2026-10-27）
- 代码：T1–T3 已落地（`--multipage--apply-offset` + bookmark 改调 + ERT 事件顺序断言）
- 验证：ERT 全量 1266 例（0 unexpected / 0 skipped）、warning 20、checkdoc 0 新增、check-parens 通过
- 文档：CHANGELOG / decisions / tech-debt 已同步
- 下一步：用户 L3 真机三项（书签跳回同页同偏移 / saveplace 重开 PDF / 宽页 hscroll）→ 通过后归档到 completed/

## 目标

让书签（`seshat-reader-bookmark-jump`）与 saveplace（`seshat-reader--saveplace-find-file`）**真正恢复页内像素偏移**，而不只是恢复到页首。不改书签记录格式、不改 `--multipage-goto` 语义、不动已通过真机验证的 `--multipage-scroll` 跨页序列。

## 根本问题（第一性原理）

| # | 事实 | 出处 |
|---|---|---|
| F1 | `seshat-reader-bookmark-jump` 的恢复顺序为：`--multipage-goto page`（内部 `set-window-start` + `set-window-vscroll 0`）→ **同帧** `(ignore-errors (set-window-vscroll nil offset t))`，两者之间没有落帧 | `emacs/seshat-reader/seshat-reader-bookmark.el:114-118` |
| F2 | 真机四探针已确证：与新设 `window-start` **同帧**设置的像素偏移会被一次 redisplay 丢弃（3090 → 0）；先落一帧后同值保留（3090 保留、point 落在邻居页行首） | `openspec/completed/2026-10-27-reader-cross-page-scroll-fix.md`「真机诊断记录 · L3 迭代 2」 |
| F3 | saveplace 的恢复路径 `seshat-reader--saveplace-find-file` → `seshat-reader-bookmark-jump`，因此**同一缺陷**同时影响两种恢复渠道 | `emacs/seshat-reader/seshat-reader-saveplace.el:47-52` |
| F4 | 现有 4 条书签 ERT 把 `set-window-vscroll` 整体 stub 掉、只断言实参 `(nil 120 t)`，**结构上测不到落帧**，故测试长期为绿而缺陷存在 | `emacs/tests/seshat-reader-periphery-test.el:209-232` |
| F5 | `offset == 0` 或非数字时不设置偏移（落到页首），属正确行为，不受影响 | `seshat-reader-bookmark.el:117` 的条件 |

⇒ **只要记录里 `offset > 0`，书签与 saveplace 都必然只恢复到页首**，这是确定缺陷而非偶发现象。

## 假设清单

| # | 假设 | 来源 | 回验方式 |
|---|---|---|---|
| A1 | `--multipage-goto` 内部不触发 redisplay（只有 `set-window-start` + `set-window-vscroll 0` + `--multipage-sync` + `--center-page`）；且它在 `--multipage-sync`（会改 buffer）之后用**第二次** `--show-page` 重定位 window-start，故 goto **返回时** window-start 已是最终态、无需在 goto 内部落帧 | 事实✓（读源确认：`seshat-reader.el` 的 `--multipage-goto` / `--show-page`） | 已完成 |
| A2 | 在 `--multipage-goto` 与写 offset 之间补一次强制落帧后，offset 能被保留 | 假设?（与跨页探针同构） | **L3 T5-① 真机确认** |
| A3 | `hscroll` 不受「同帧丢弃」影响（`set-window-start` 是否重置横向滚动未验证） | 假设? | L3 T5-③ 观察；若不成立另立条目 |
| A4 | 补落帧不破坏「跳页停在页首」的既有语义（`n` / `p` / `M-g g` 不走 bookmark 路径） | 事实✓（`--multipage-goto` 自身仍会把 vscroll 归零） | 已完成 |
| A5 | saveplace 无需单独改动即可受益（它复用同一 handler） | 事实✓（F3） | L3 T5-② 验证 |

## 设计

### D1 新增共享工具 `seshat-reader--multipage--apply-offset`

位置：`emacs/seshat-reader/seshat-reader.el`，紧邻 `--multipage--place-point` 之后。

语义：
```
(defun seshat-reader--multipage--apply-offset (window offset)
  "...先强制落一帧，再设置窗口的像素垂直偏移...")
  WINDOW 为 nil 时按 Emacs 惯例表示 selected window（内部解析为
  (if (window-live-p window) window (selected-window))，与 --multipage-scroll
  / --multipage-sync 同口径），因此**不得**对入参直接 (window-live-p window)
  判活——那会把 nil 拒掉，偏移永远设不上。
  守卫：解析后的窗口必须 live；OFFSET 必须是正数。二者任一不满足则
  什么都不做（也不落帧，避免无谓刷新）。
  动作： (redisplay t) → (set-window-vscroll 解析后的窗口 OFFSET t)
```

注意：`(redisplay t)` 会走 buffer-local `pre-redisplay-functions`，可能触发一次
`--center-page`（书签恢复顺序里刚改过缩放、刚重建过页行，居中状态通常已 stale）。
该副作用只改每页的居中属性（能放下的页改 `before-string` 的 `:align-to`，超宽页改 `line-prefix`）与横向滚动，不改 `window-start`、
不改垂直像素偏移、不改行结构，且偏移写在落帧之后，顺序安全；调用方随后设置
`hscroll`，因此横向位置也不会被这次 re-center 永久覆盖。

docstring 必须写清：Emacs 会丢弃「与新设 `window-start` 同帧设置」的像素偏移（真机实测 3090 → 0），因此必须先强制落帧（`(redisplay t)`，force 是有意的）；并注明跨页序列（`--multipage-scroll`）是同一约束的另一种形态（它在 sync 之后落帧），两处注释互相指向，避免表述漂移。

### D2 `seshat-reader-bookmark-jump` 改调 D1

第 ③ 步由
```
(when (and (numberp offset) (> offset 0))
  (ignore-errors (set-window-vscroll nil offset t)))
```
改为
```
(when (and (numberp offset) (> offset 0))
  (seshat-reader--multipage--apply-offset nil offset))
```
前置条件判断保留在调用方（工具内也做防御）；`ignore-errors` 去掉，改由工具内部只在参数合法时动作（避免吞掉真实错误）。
传入 `nil` 表示 selected window，由工具内部解析（不要改成 `(selected-window)` 实参——保持与 `--multipage-scroll` 的调用风格一致，也让测试能断言「解析后的窗口」）。

### D3 不动 `--multipage-scroll`

它是已通过真机验证的形态，本计划只在其注释处**追加一句**指向 `--multipage--apply-offset`（「同一约束的另一种形态」），不改任何代码行。

### D4 `hscroll` 保持原样

L3 观察是否恢复；若不恢复，登记 tech-debt，不在本计划扩大改动面。

## 任务

- [x] T1 `seshat-reader.el` 新增 `--multipage--apply-offset`（按 D1，含 docstring 约束说明）。验收：`(fboundp …)` 为 t；ERT 中「OFFSET 非正数或非数字时不调用 `set-window-vscroll`、也不调用 `redisplay`」与「WINDOW 传 nil 时按 selected window 处理（不得因 `window-live-p` 拒绝）」两例通过。（这两例属工具函数单测，放入 `emacs/tests/seshat-reader-multipage-test.el`；与 T3 ④ 的 bookmark 层守卫是不同层次，不重复。）（依赖：无）
- [x] T2 `seshat-reader-bookmark.el` 第 ③ 步改调 D1（按 D2），并同步该函数 docstring 第 3 步的措辞（说明先在 goto 之后落一帧才叠加偏移）。（依赖：T1）
- [x] T3 ERT（`emacs/tests/seshat-reader-periphery-test.el`）：① 把 `seshat-reader-periphery-test--jump-calls` 的记录机制由「plist 覆盖」改为（或额外维护）**有序事件列表**：plist 只保留最后一次实参、无法承载顺序断言；顺序断言必须基于有序表（`events` + `push` + `nreverse`，参考 `seshat-reader-multipage-test.el` 跨页序列测试的既有范式）。`:scale` / `:page` / `:hscroll` 的「最后一次实参」断言可保留在 plist 或从事件表反查；② 既有 4 条书签用例：`:vscroll` 断言值**需要**由 `(nil 120 t)` / `(nil 80 t)` 改为 `(list (selected-window) 120 t)` / `(list (selected-window) 80 t)`（工具把 nil 解析成 selected window 后传给 `set-window-vscroll`）——这是**必要调整，不是放宽断言**，断言强度不变（仍逐字段比较实参）；其余断言（`:scale` / `:page` / `:hscroll`）保持不变；③ 新增 1 例 `bookmark-jump-redisplays-before-offset`：断言事件序中 `redisplay` 早于 `set-window-vscroll`，且 `set-window-vscroll` 实参为 `(list (selected-window) 120 t)`（与 ② 同口径：工具把 nil 解析成 selected window）；④ 新增 1 例：`offset` 缺失或为 0 时**不调用** `redisplay` 与 `set-window-vscroll`（用例注释须标注「这是**优化断言**——避免无谓刷新，不是行为契约；将来若发现 offset=0 也需落帧，可放宽此例」）。（依赖：T2）
- [x] T4 L1 + L2：`make -C emacs/seshat-reader clean all` EXIT 0 且 gcc/byte-compile warning ≤ **24**（零新增）、`make -C emacs/seshat-reader checkdoc` 0 新增、`elisp_check_parens` 通过（`verify` 实例）、`make -C emacs/tests ert` 逐文件全量 **0 unexpected / 0 skipped**（基线 **1226** 例，例数变化须记录差值）、`check-criteria` PASS。执行前先跑一次 `make -C emacs/tests ert` 取**当日真实基线**（计划记 1226；若与实测不符，以实测为准并在报告记录差值——VENDORED.md ⑯ 记的 1213 是 P1 完成时的旧值）。（依赖：T1–T3）
- [ ] T5 L3 真机（用户执行）：① 在某页**中段**（页内偏移 > 0）存书签 → 关闭该 buffer → 从书签列表跳回 → 落点在同一页同一偏移；② 同一位置关掉 Emacs 重开该 PDF（saveplace）→ 自动回到同页同偏移；③ 宽页横向滚动到中段后同样验证 `hscroll` 是否恢复。验收：逐项打勾记录在「## 事实来源」的 T5 表。（依赖：T4）
- [x] T6 文档：`CHANGELOG.md`（Unreleased · 修复：书签 / saveplace 恢复页内偏移）、`openspec/tech-debt.md`（**勾销**「书签的页内偏移恢复疑似持续失效（2026-10-27，code-reviewer major）」条目，注明已由本计划修复并附验证方式）、`openspec/decisions.md`（并入既有「跨页落点两帧序列」决策：把「先落帧再写偏移」推广到书签 / saveplace 恢复）、本计划归档到 `openspec/completed/`。（依赖：T4）

## 批次执行

| 批次 | 任务 | 验收层 | 风险 |
|---|---|---|---|
| 1 | T1 + T2 + T3（工具函数 + 调用改造 + ERT） | L1 + L2 | 低（1 个新函数 + 1 行调用） |
| 2 | T5 真机（用户）+ T6 文档 | L3 + 文档一致性 | 中（书签恢复只能真机确认） |

批次间不跨批提交；批内 T1/T2 合为 1 个 fix commit。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` EXIT 0；warning ≤ 24（基线，零新增）；`make checkdoc` 0 新增；`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → `unexpected = 0` 且 `skipped = 0`（`ert-judge.sh` 数值判定）；`check-criteria` PASS。
- **L3**：T5 三项真机验收；ERT 只能证明「落帧发生在写偏移之前」，**不能证明偏移被真正保留**。
- 任务类型：elisp 验证走 `verify` 隔离实例；收尾 `set_task(auto)` → `instance(stop, verify)` → `instance_status(verify)` 确认。

## 文档清单

| 文档 | 需更新内容 |
|---|---|
| `CHANGELOG.md` | Unreleased · 修复：书签与 saveplace 恢复页内像素偏移（此前只恢复到页首） |
| `openspec/tech-debt.md` | 勾销「书签的页内偏移恢复疑似持续失效」条目，注明修复方式（落帧后写偏移）与验证方式（T5 真机） |
| `openspec/decisions.md` | 并入既有「两帧序列」决策：同一约束适用于书签 / saveplace 恢复路径 |
| `openspec/completed/` | 本计划完成后归档 |
| `docs/emacs-reader.md` | **无需改**（书签行为回归到「文档已声明的语义」，非新特性） |
| `docs/architecture.md` | **无需改**（无结构变化） |

## 注意事项

1. **不新增第二个跨页序列**：`--multipage-scroll` 不动，只加注释指向 D1。
2. **不改书签记录格式**：`page` / `offset` / `hscroll` / `scale` / `fit-mode` 字段保持不变，旧记录（`vscroll` 迁移）继续可用。
3. **不把 `ignore-errors` 原样搬进工具**：工具内部用参数守卫，避免吞掉真实错误。
4. **ERT 断言的强度**：新增用例必须断言**事件顺序**与**实参值**，不能只断言「函数被调用过」。
5. **`hscroll` 不在本计划范围**：若 L3 发现它也不恢复，登记 tech-debt 另议，不在本批扩大。
6. 单文件改动量小，但涉及用户数据（书签），**未经 L3 真机不得声称修复完成**。
7. **`(redisplay t)` 会跑 `pre-redisplay-functions`**：书签恢复后可能立即触发一次 re-center（居中属性重算、hscroll 归零），这是预期中间帧，不是缺陷；L3 若看到「横向位置先归零再回来」属正常。

## 回退方案

若 **A2 被 L3 推翻**（补落帧后仍不恢复偏移）：
1. 改用「一次性设置」路径：不调 `--multipage-goto`，直接 `set-window-start` 到目标页行首 + 同帧不设偏移，落帧后设偏移（即把跨页序列的等价流程内联到 bookmark 恢复）；
2. 或在恢复后追加一次 idle 重设（`run-with-idle-timer 0`）再写偏移；
（方案 1 的实现要点：内联路径必须自行完成 `--multipage-goto` 里那两步——`--multipage-sync` 之后**再次** `set-window-start` 到目标页行首，否则 sync 改 buffer 会让 start 漂移，落帧后设的偏移又会失准。）
3. 两种方案都必须真机复验 T5-①②；若均失败，将 `offset` 恢复标注为「已知限制」并登记 tech-debt + 文档说明（诚实降级，不静默失效）。

## 审查修订记录

首轮 plan-reviewer（2026-10-27）「有条件通过」，处置如下：

| # | 等级 | 问题 | 修订 |
|---|---|---|---|
| 1 | blocking | `--multipage--apply-offset` 的 `window` 参数语义在 D1 / D2 / T3 三处互斥：D1 要求「仅当 window-live-p」，D2 传 nil，T3 断言实参为 nil —— 照字面实现会把 nil 拒掉（偏移永不生效），或让断言矛盾 | 统一为「nil = selected window，工具内部解析」（与 `--multipage-scroll` 同口径）；D1 明确禁止对入参直接判活；T3 断言值改为 `(list (selected-window) 120 t)` / `(list (selected-window) 80 t)` 并注明是必要调整 |
| 2 | major | `(redisplay t)` 会触发 `pre-redisplay-functions` → `--center-page`（改 before-string / 归零 hscroll），计划未点明 | D1 补说明：该副作用不触碰 window-start 与垂直偏移、偏移写在落帧之后；hscroll 由调用方在落帧后设置，顺序安全 |
| 3 | minor | L2 基线 1226 无出处（VENDORED ⑯ 记 1213） | T4 补「执行前取当日真实基线，以实测为准」 |
| 4 | minor | 「offset=0 不落帧」锁死实现细节 | T3 ④ 标注为「优化断言、非行为契约」 |
| 5 | minor | F1/A1 未说明「goto 返回时 window-start 已稳定」的依据 | A1 补「sync 后第二次 `--show-page` 重定位」事实 |
| 6 | major（复核新增） | T3 ③ 要求断言「redisplay 早于 set-window-vscroll」，但 `--jump-calls` 的 plist 只保留最后一次实参、无法承载顺序 | T3 ① 改为（或额外维护）有序事件列表（沿用 multipage-test 既有范式） |
| 7 | minor | D1「只改 before-string」表述不精确（超宽页改的是 line-prefix）；T1 两例单测未指定文件 | 已精确化措辞；T1 补「放入 seshat-reader-multipage-test.el」 |
| — | 结论 | 落帧位置（goto 返回后）、hscroll 留 L3 观察、不变量回归、无第三条同源路径 | 均确认成立，计划不变 |

---

## 事实来源

| 来源 | 用途 |
|---|---|
| `emacs/seshat-reader/seshat-reader-bookmark.el:100-120` | 恢复顺序与字段语义 |
| `emacs/seshat-reader/seshat-reader-saveplace.el:47-52` | saveplace 复用同一 handler |
| `emacs/tests/seshat-reader-periphery-test.el:209-232` | 现有书签 ERT 的 stub 形态（测不到落帧） |
| `openspec/completed/2026-10-27-reader-cross-page-scroll-fix.md`「L3 迭代 2」 | 同帧丢弃偏移的真机探针数据 |

**T5 验收表（待填）**

| 项 | 结论 |
|---|---|
| ① 书签：页中段保存后跳回，同页同偏移 | 待验 |
| ② saveplace：重开 PDF 自动回原位 | 待验 |
| ③ 宽页 `hscroll` 是否恢复 | 待验 |
