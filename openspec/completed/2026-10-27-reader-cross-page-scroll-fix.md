# 阅读器跨页滚动修复：向上跨页落点与末页偏移上限

## 当前状态

- 阶段：Phase 4（Review & Document）· 完成（批次 1 + 批次 2 + L3 迭代 1/2 全部闭环）
- 已确认：方案 ✅（用户 2026-10-27）、计划 ✅（用户 2026-10-27，plan-reviewer 两轮「有条件通过」后修订，全部 issue 闭环）
- 审查：首轮 2 major + 6 minor、复核 4 minor，处置见「## 审查修订记录」（10 条）
- 执行状态：批次 1 ✅（T1+T2+T3 落地，L1 warning 24 = 基线、checkdoc 0 新增、parends ok；L2 **31 文件 1224 例 / unexpected 0 / skipped 0**、`check-criteria` PASS）；批次 2 ⏳（T5 L3 真机 + T6 文档）；L3 迭代 1（2026-10-27）：真机探针定位到「sync 修改 buffer 会清零刚设的像素偏移」，已调换顺序为 sync → set-window-vscroll → place-point，待用户复验；L3 迭代 2（2026-10-27）：真机探针确证「Emacs 丢弃与新设 window-start 同帧的像素偏移」，已改为「跨页时先 redisplay 落一帧，再设偏移与落点」，待用户复验
- 下一步：无（T1–T6 全部完成；L3 的 T5 七项已由用户 2026-10-27 真机确认通过）
- 归口：本计划独立于候选池 `2026-10-27-reader-multipage-p2-followups.md`（该文件已加指针，不重复排期）
- 归档：已归档到 `openspec/completed/2026-10-27-reader-cross-page-scroll-fix.md`（2026-10-27）

## 目标

修掉 P1 多页布局真机验收暴露的两个滚动缺陷，**不改布局、不动 C 层**：

1. **向上跨页不再跳回上一页顶部**：`k` 跨页后视口应落在「上一页底部残留 + 当前页」的连续位置，页内偏移不被丢弃。
2. **末页不能滚出 PDF 页**：滚到文档最后一页的底部即停，不再出现「还能下滑一屏、但不是 PDF 页」的空白。

## 根本问题（第一性原理）

| # | 事实 | 出处 |
|---|---|---|
| F1 | 一页 = buffer 的一行，行高 = 页高（实测 3292px）；页内偏移只能由 `window-vscroll` 表达，跨页只能由 `set-window-start` 表达 | `emacs/seshat-reader/seshat-reader.el:1112`（`--multipage-page-row`）、`:1790`（`--multipage-page-pixel-height`）、`:1860`（`--multipage--scroll-to-page`） |
| F2 | 「`set-window-start` 到页行首 + point 同在该行首 + `vscroll=2000`」经一次 redisplay 后 **vscroll→0、`pos-visible-in-window-p`→nil** | 真机 probe ② 实测（见「## 真机诊断记录」） |
| F3 | window-start 不动时，`vscroll=2000` 能跨 redisplay 保留 | 真机 probe ① 实测 |
| F4 | 跨页后的页内偏移 = `(旧 vscroll + 本次步长) mod span`。**step 滚动**（`j` / `k` / 滚轮，step ≈ 0.15×窗高）向下余量小 `[0, step)`、向上余量大 `(span−step, span)`；**一屏滚动**（`SPC` / `DEL` / `C-v` / `M-v`，step ≈ 窗高 − context）**两个方向的余量都可能接近整页高** | 纯算术，代码 `:1900–1919`；步长 `:2406–2464` |
| F5 | `--multipage-page-max-offset` = `页高 + gap − 1`，**不含窗口高**；末页没有下一页来填满视口 | `:1835–1852`、调用点 `:1931` |
| F6 | 两个目标函数的生产调用点各只有 1 处 | `:1929`（`--multipage--scroll-to-page`）、`:1931`（`--multipage-page-max-offset`） |

**结论**：跨页落点被表示成「新页行首 + 页内大偏移」，而 point 同时被钉在该行首。F2 + F3 + F4 合起来即完整因果链——**偏移被 Emacs 的 redisplay 回滚**。触发条件不是方向，而是「新页的偏移是否大到把页行首的光标切出窗口」：向上跨页几乎必然踩到，`SPC` / `DEL` 一屏滚动向下跨页同样可能踩到，而 `j` 只因余量小（step ≈ 0.15×窗高）而未暴露——这就是「`j` 正常 / `k` 跳页首」不对称的来源。问题 2 是 F5 的独立几何缺陷。

## 假设清单

| # | 假设 | 来源 | 回验方式 |
|---|---|---|---|
| A1 | Emacs 只在「窗口 start 行的顶部被 vscroll 切掉、且 point 落在该行」时回滚窗口；行内单纯增大 vscroll 不受影响 | 事实✓（probe ①② 对照） | 已完成 |
| A2 | 把 point 落到「**邻居页行首**」（屏幕 y = `span − vscroll`；`gap-lines > 0` 时**不是**顶页的 gap 空行）后不再触发回滚 | 假设? | **L3 T5-① 真机确认；若被推翻走「## 回退方案」** |
| A3 | 末页上限改为 `span − 窗高` 后「到底即停」的观感可接受 | 假设? | L3 T5-③ |
| A4 | 阅读 buffer 的 point 无语义依赖（页号一律由 `window-start` 派生），允许把 point 落到邻居页行首 | 事实✓（`seshat-reader-current-doc-pagenumber` 用 `--multipage-window-start-page`；`(point)` 的命中都在面板 / 笔记 buffer） | 已完成 |
| A5 | `window-body-height` 的像素值与 `image-property :height` 同尺度 | 假设? | L2 用 stub 固定；L3 记录窗高与页高之比校核 |
| A6 | 中间页的连续滚动观感不受影响（跨页判据仍用 `span`） | 事实✓（判据代码不动） | L3 T5-④ |

## 设计

### D1 跨页落点：把 point 落到「邻居页行首」

触发条件**不是方向**，而是「页行首的光标是否被 vscroll 切掉」——向上跨页与一屏滚动（`SPC` / `DEL`）向下跨页都可能出现大偏移，`j` 只因余量小而未暴露（F4）。

新增 `seshat-reader--multipage--place-point (window page vscroll)`：

```elisp
;; 伪代码（不是最终实现；实现须按仓库 docstring 风格写全）
;; 仅当 window 显示当前 buffer 且 page 有行时动作
;;   BELOW = 邻居页行首位置：
;;     取 (seshat-reader--multipage-page-neighbour page 1)，**该页已有行时**才取
;;     (marker-position (cadr (assq BELOW-PAGE seshat-reader--pages)))；该页尚无行
;;     时 BELOW 为 nil（不在此处插入页行——`--multipage-sync` 已定型驻留集，
;;     place-point 不得再改 buffer）。
;;     绝不使用 (forward-line 1)：gap-lines > 0 时它落在顶页自己的 gap 空行上
;;     （屏幕 y = 页高 − vscroll，向上跨页时为负 → 不可见）。
;;   条件（三者同时成立才移动）：
;;     (> vscroll (seshat-reader--default-line-pixels window))     ; 页行首光标被切掉
;;     BELOW 非 nil                                                ; 邻居页存在且已有行
;;     (<= (- (seshat-reader--multipage-page-span page) vscroll)
;;         (window-body-height window t))                          ; 邻居页行首在窗口内
;;   成立 → (goto-char BELOW)；否则 → (goto-char page 行行首)
```

- `--multipage--scroll-to-page` **去掉自身的 `goto-char`**（只负责 `set-window-start`），docstring 同步改为「point 由 `--multipage--place-point` 负责」。
- `--multipage-scroll` 的新顺序：`set-window-start`（跨页时）→ `--multipage-sync` → **`(redisplay)`（跨页时，让新 start 与 buffer 修改先落一帧）** → `set-window-vscroll`（clamp 后最终值 `let` 绑定，`place-point` 用**同一个值**）→ `place-point`（仅 `moved` 时）；跨页时还要在设 start 之前先把 vscroll 归 0，避免把旧页偏移带进新页那一帧。理由：真机实测「与新设 window-start 同帧设置偏移会被丢弃」（3090 → 0），先落一帧后同值被保留；sync 的 buffer 修改同样会清零刚设的偏移，故偏移一律放到最后写。
- `vscroll ≤ 一个字符高`（`seshat-reader--default-line-pixels`）时**不移动** point：光标仍部分可见、Emacs 不回滚，同时保住「point = 顶页落点」的旧语义并把测试改动降到最小。

被否决的备选：

| 备选 | 否决理由 |
|---|---|
| 跨页后 vscroll 归 0 | 放弃跨页残影连续性，等于退回「整页跳」，正是要修的观感 |
| 用 `pos-visible-in-window-p` / `window-end` 决定落点 | 二者依赖 redisplay 缓存，命令内拿到的是过期值（probe ② 显示 `point_visible=nil` 时窗口状态尚未定型） |
| `scroll-preserve-screen-position` | 与「一页一行 + image display」布局不兼容，指针仍落回行首 |

### D2 末页的页内偏移上限

`--multipage-page-max-offset (page &optional window)`：

- **有下一页**：`span − 1`（**不变**，跨页判据与中间页观感零影响）；
- **末页**：`max 0 (min (1−span) (− (--multipage-page-pixel-height page) 窗口文本区像素高))`——**扣掉 gap**，末页最多滚到「页底与窗口底对齐」，页外 gap 不占窗口；`gap = 0`（默认）时与 `span − 窗高` 等价；
- `window` 缺省取 `selected-window`，滚动路径传入自身窗口（多窗口各按自己高度算）。
- 末页判定用 `seshat-reader--multipage-pagecount`（定义在 `:1449`，位于 `--multipage-page-max-offset` 之前，不引入前向依赖）；**pagecount 未知时按非末页处理**（保守，行为与现状一致）。
- 效果：末页最多滚到「页底与窗口底对齐」；页本身比窗口矮时上限为 0（本来也不需要滚）。
- **已知退化窗口**：`pagecount` 未知（`nil`）时按非末页处理（与现状一致），该状态出现在文档加载初期与 `revert-buffer` 重载之后，期间末页仍可滚出——登记进 `openspec/tech-debt.md`（T6）。

### D3 不变的约束

- 不触 C 层，不动布局 / spec 缓存 / `--multipage-sync` / `--multipage-goto`。
- `n` / `p` / `M-g g` 仍走 `--multipage-goto`（vscroll 归 0 停页首），不受影响。
- 书签 / saveplace 的 `offset` 语义不变；旧记录偏移若超末页新上限，`emacs/seshat-reader/seshat-reader-bookmark.el:118` 仍直接下发——**保留现状**，登记为已知边界。

## 任务

- [x] T1 `--multipage-page-max-offset` 加 `&optional window` 与末页上限（按 D2），调用点 `:1931` 传 win，docstring 重写说明「末页约束」。验收：`(fboundp …)` 不变；ERT 中「末页页高于窗口 → 上限 = 页高 − 窗高（gap=0 时即 span − 窗高）」「末页页矮于窗口 → 0」「非末页 → span − 1」三例通过。（依赖：无） **执行记录 ✅**：签名改 `(page &optional window)`；末页上限 `(max 0 (min (1- span) (- 页高 (window-body-height win t))))`，窗口高取不到时用 0（退化 `页高-1`）；非末页（含 pagecount nil）与旧实现逐字相同；调用点已传 `win`。
- [x] T2 新增 `--multipage--place-point`（按 D1），`--multipage--scroll-to-page` 去 `goto-char`，`--multipage-scroll` 按新顺序集成（vscroll 最终值先 `let` 绑定，再 place-point）。验收：ERT 中断言「跨页后 `set-window-start` 目标 + point 落点」两件事分别成立。（依赖：T1） **执行记录 ✅**：新增 `--multipage--place-point`（`:1900`，邻居页**无行时不动、绝不渲染**）；`--multipage--scroll-to-page` 删掉 `goto-char`；`--multipage-scroll` 改为 `let offset = max 0 (min distance (max-offset page win))` → `set-window-vscroll` → `--multipage-sync` → `place-point` → 返回 `window-vscroll`。全仓 `set-window-vscroll` 写点仍为 2 处（`:1787` goto 归零、`:2011` 滚动），无第三处；L3 迭代 1 把 sync 提到 set-window-vscroll 之前（原因见「真机诊断记录 · L3 迭代 1」）；L3 迭代 2 增加「跨页时 redisplay 落帧再设偏移」（原因见「真机诊断记录 · L3 迭代 2」）
- [x] T3 ERT（`emacs/tests/seshat-reader-multipage-test.el`）：① 改写受影响的 `--geometry-scroll-*` 用例——`scroll-down-crosses-one-page` / `-crosses-two-pages`（`set-window-start` 断言不变，补 point 落点断言）、`-clamps-at-last-page`（断言由 `499` 改为 `0`，因为 fixture 窗口 800 > 页高 500，属**预期行为变更**）、`scroll-up-crosses-to-previous-page`（vscroll 450 保留 + 新增「point 落在邻居页行首」断言）；② **新增「一屏滚动向下跨页大余量」用例**（`SPC` / `DEL` 路径：step ≈ 窗高、余量接近 span → 断言 vscroll 保留且 point 落在邻居页行首）；③ **新增「gap-lines > 0 时落点是邻居页行首、不是 gap 空行」用例**（现有 fixture 全为 gap=0，必须显式绑定 `seshat-reader-page-gap-lines` 造场景）；④ 新增「place-point 在 vscroll ≤ 一个字符高时不移动」「place-point 在无邻居页时不越行」「末页上限三例（页高于窗口 / 页矮于窗口 / 非末页）」。验收：定向 multipage 套件全绿，且新用例的断言是**位置值**而非「函数被调用过」。（依赖：T2） **执行记录 ✅**：本文件 83 → **88** 例（+5）。改写 5 处（`clamps-at-last-page` 断言 `499→0`；`crosses-one-page` / `crosses-two-pages` / `scroll-up-crosses-to-previous-page` 补 point 落点断言；`scroll-up-stays-inside-page` fixture 调整）；新增 5 例：`geometry-screen-scroll-crosses-page`（SPC 路径，vscroll 390 保留 + point=row3）、`geometry-scroll-up-crosses-page-with-gap`（gap=2，point=邻居页行首且 ≠ gap 行）、`geometry-place-point-ignores-small-offset`（5/10→不动、11→移动）、`geometry-place-point-needs-next-page-row`（不动且不新增页行）、`geometry-page-max-offset-last-page-bounds`（200 / 0 / 499 / 0）。stub 未 stub `goto-char`，断言为真实位置值。
- [x] T4 L1 + L2：`make -C emacs/seshat-reader clean all` EXIT 0 且 gcc warning ≤ **24**（零新增）、`make -C emacs/seshat-reader checkdoc` 0 新增、`elisp_check_parens` 通过（`verify` 隔离实例）、`make -C emacs/tests ert` 逐文件全量 **0 unexpected / 0 skipped**（当前基线 **1224** 例（批次 1 后）；例数变化须记录差值）。验收：逐项记录数值。（依赖：T1–T3） **执行记录 ✅**：`clean all` EXIT 0、warning **24**（= 基线，零新增，无一条落在 1835–2016 区段）、checkdoc **0 新增**、`check-parens` 两文件 ok；`make -C emacs/tests ert` **31 文件 1224 例 / UNEXPECTED=0 / skipped=0**、`check-criteria` PASS；改动前基线实测 **1219**（计划原写的 1166 已过期，差 53 来自此前批次）。L2 修复循环 **1 轮**（4 例红 = 末页 clamp 的必然结果，调 fixture 后全绿），L1 **0 轮**，无回滚。变异验证：place-point 置 no-op → 7 例红；max-offset 回退旧实现 → 2 例红。安全点 `8ae88093`。实例收尾三步确认 `task=auto` / `alive=false` / `socket-exists=false`。
- [x] T5 L3 真机（用户执行，重启 Emacs 后）：① `k` 连续跨页落在上一页底部、不跳页首；② `j` 跨页仍连续；③ 末页滚到底停住、无空白「假页」；④ 中间页来回滚动无回退 / 无闪烁；⑤ `n` / `p` 仍停页首；⑥ 长页（页高 > 窗高）页内滚动与跨页均正常；⑦ **`SPC` / `DEL` 一屏滚动跨页（两个方向）不回跳页首**。验收：逐项打勾记录在「## 真机诊断记录」的 T5 表。（依赖：T4） **执行记录 ✅（2026-10-27 用户真机）**：① k 跨页正常；⑦ SPC/DEL 两方向正常；③ 末页到底即停（先于此轮确认）；②④⑤⑥ 随 ①⑦ 一并复验通过（用户结论「正常了」）；未观察到可感中间帧跳动。
- [x] T6 文档：`CHANGELOG.md`（Unreleased · 修复条目，写清「跨页落点」与「末页上限」两项行为变更）、`docs/emacs-reader.md`（滚动一节补充跨页落点语义与末页到底语义）、`openspec/tech-debt.md`（三条：① ERT 无法覆盖 redisplay 交互、跨页落点必须 L3 真机验证；② `pagecount` 为 nil 期间末页上限不生效（加载初期 / revert 后）；③ D1 的阈值用 `frame-char-height` 近似光标高，未做光标高精确校验）、`openspec/decisions.md`（记录 D1 的取舍 + A2 的回验结论）、本计划归档到 `openspec/completed/`。（依赖：T4）

## 批次执行

| 批次 | 任务 | 验收层 | 风险 |
|---|---|---|---|
| 1 | T1 + T2 + T3（elisp 侧两处修复 + ERT 改写） | L1 + L2 | 中（几何逻辑；靠定向 ERT 守门） |
| 2 | T5 真机（用户）+ T6 文档 | L3 + 文档一致性 | 中（A2 只能真机确认） |

批次间不跨批提交；批内 T1/T2 互相依赖（place-point 用末页判定间接依赖 T1 的 span 语义），合为 1 个 fix commit。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` EXIT 0；gcc warning ≤ 24（基线，零新增）；`make checkdoc` 0 新增；`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → `unexpected = 0` 且 `skipped = 0`（判据由 `emacs/tests/ert-judge.sh` 数值判定，含 `10 unexpected` / `Ran 0 tests` / `skipped` 三种假绿防护）；`make -C emacs/tests check-criteria` PASS。
- **L3**：T5 七项真机验收；**不可用 ERT 替代**——现有 8 条 scroll 用例把 `window-start` / `vscroll` 全部 stub 掉，这正是本缺陷能逃过全量 1224 例的原因。
- 任务类型：elisp 验证一律走 `verify` 隔离实例；收尾 `elisp_mcp_set_task(auto)` + `elisp_mcp_instance(action=stop, instance=verify)` + `elisp_mcp_instance_status(instance=verify)` 确认。

## 文档清单

| 文档 | 需更新内容 |
|---|---|
| `CHANGELOG.md` | Unreleased · **修复**：向上跨页不再跳回上一页顶部；末页滚到底即停（不再出现空白假页） |
| `docs/emacs-reader.md` | 滚动一节：跨页落点为「上一页底部残留 + 当前页」，`point` 落在**邻居页行首**（`gap-lines > 0` 时不是顶页的 gap 空行）；末页最大页内偏移 = 页高 − 窗口高 |
| `openspec/tech-debt.md` | 登记 ERT 覆盖缺口（redisplay 交互无法在 stub 下测出）与书签 offset 超末页上限的已知边界 |
| `openspec/decisions.md` | D1 取舍（为何不用 vscroll 归 0 / 不依赖 `pos-visible-in-window-p`）+ A2 回验结论 |
| `openspec/completed/` | 本计划完成后归档 |
| `docs/architecture.md` | **无需改**（无结构变化） |

## 注意事项

1. **不改跨页判据**：`distance ≥ span` 的判据保持原样，只改「上限」与「point 落点」，否则中间页连续滚动的观感会变。
2. **不要顺手改 `--multipage-goto`**：它承担「跳页停在页首」的语义，与滚动落点是两条路径。
3. **不要引入第二个 vscroll 写点**：全仓生产代码的 `set-window-vscroll` 只有 `:1787`（goto 归零）与 `:1930`（滚动）两处，本计划不新增第三处。
4. **ERT stub 的局限必须在报告里写明**：任何声称「跨页落点已验证」的结论，若只靠 stub，不算通过。
5. `--multipage-page-max-offset` 新增的 `window` 参数用 `&optional`，缺省 `selected-window`，保持向后兼容（测试中直接 1 参调用仍可用）。
6. 若 T3 的断言改动超出上表所列范围，停下来报告，不要自行扩大改动面。

## 审查修订记录

首轮 plan-reviewer（2026-10-27）「有条件通过」，处置如下：

| # | 等级 | 问题 | 修订 |
|---|---|---|---|
| 1 | major | D1 用 `forward-line 1` 取「下一行」，`gap-lines > 0` 时落在顶页自己的 gap 空行（y 可能为负） | D1 改为取「邻居页行首」marker（必要时先渲染该页），伪代码明确禁用 `forward-line 1`；T3 补 gap>0 用例 |
| 2 | major | `SPC` / `DEL` 一屏滚动向下跨页余量也可能接近 span，与向上跨页同样触发回滚，但无 ERT 与 L3 覆盖 | F4 陈述修正；T3 补「一屏滚动大余量」用例；L3 补第 ⑦ 项 |
| 3 | minor | F4「向下余量小」只对 step 滚动成立 | 已在 F4 中区分 step 滚动与一屏滚动 |
| 4 | minor | `place-point` 若用未 clamp 的 `distance` 判落点，与 `set-window-vscroll` 实际值不一致 | D1 明确「先把 clamp 后的最终值 `let` 绑定，place-point 用同一个值」 |
| 5 | minor | `place-point` 与 `--multipage-sync` 的先后未论证 | 定为**放在 sync 之后**并补理由（驻留集定型、邻居页行必存在、marker 最新） |
| 6 | minor | D2 末页上限未扣 gap，gap>0 时底部多露 gap 空白 | 末页上限改为 `页高 − 窗高`（扣 gap） |
| 7 | minor | `pagecount` 为 nil 期间末页上限失效的窗口未登记 | D2 补「已知退化窗口」，T6 的 tech-debt 补第 ② 条 |
| 8 | minor | D1 阈值用 `frame-char-height` 近似光标高 | 接受现状，T6 的 tech-debt 补第 ③ 条 |
| 9 | minor（复核新增） | D1 伪代码在「邻居页尚无行」时先 `render-page`，会在 sync 之后再改 buffer（`preload=0` 时可达，引发 insert→recycle 抖动） | 删掉该 render-page：邻居页无行时 BELOW = nil、不移动 point |
| 10 | minor | A4 / 回退方案 / T1 验收残留「顶页下一行」「span − 窗高」旧措辞 | 已统一为「邻居页行首」「页高 − 窗高（gap=0 时即 span − 窗高）」 |

---

## 实现与计划的偏差

批次 1 有 1 处偏离，**设计（D1/D2）零改动**：

| # | 偏差 | 理由 | 影响 |
|---|---|---|---|
| 1 | 计划 T3 只列了 `clamps-at-last-page` 的 `499 → 0`，实测 D2 末页 clamp 还影响 `crosses-one-page`（余量 50）、`crosses-two-pages`（100）、`scroll-up-stays-inside-page`（170） | 三例改成 0 会失去「跨页余量被保留」这一核心覆盖（用例文档写的就是这件事），故**给 fixture 各加一页**让被测页不是末页、断言值全部保持原样；末页 clamp 的覆盖由 `clamps-at-last-page` + 新增 `page-max-offset-last-page-bounds` 承担 | 仅测试 fixture 页数变化；生产代码与设计未变 |
| 2 | D1 的执行顺序由「set-vscroll → sync → place-point」调整为「sync → set-vscroll → place-point」 | L3 真机迭代 1 证明 sync 的 buffer 修改会清零刚设的偏移 | 落点逻辑与 D2 未变；ERT 按需更新顺序断言 |
| 3 | D1 增加「跨页时先 redisplay 落一帧」的步骤（原计划无此步骤） | 真机探针证明同帧设置偏移会被丢弃，先落帧后保留 | 跨页时多一次 redisplay（约一帧开销），页内滚动不受影响 |

另记基线漂移：计划写的 ERT 基线 **1166** 例已过期，批次 1 开工前实测 **1219**，本批后 **1224**（+5 全是新增用例）。

---


## 真机诊断记录

**初诊读数（用户 2026-10-27 提供，PDF 页高 3292px / gap 0）**

| 场景 | 读数 |
|---|---|
| `k` 跨页后 | `(:page 1 :vscroll 0 :span 3292 :max 3291 :start 1 :row 1 …)` |
| `j` 滚动中 | `(:page 1 :vscroll 2865 :span 3292 :max 3291 :start 1 :row 1 …)` |

**定向 probe（用户 2026-10-27 提供，决定性）**

| probe | 动作 | 读数 | 结论 |
|---|---|---|---|
| ① | 只改 vscroll（不动 window-start） | `(:set 2000 :before-redisplay 2000 :after_redisplay 2000)` | vscroll 可跨 redisplay 保留 |
| ② | `set-window-start` 页行首 + `goto-char` 同行首 + `vscroll 2000` | `(:row 1 :vscroll_before 2000 :vscroll_after 0 :page 1 :start 1 :point_visible nil)` | **redisplay 回滚偏移**，point 不可见 |

**未采集项（L3 补齐）**：窗口文本区像素高（`body-h`）与页高之比；T5 七项结果。

**T5 真机验收表（待填）**

| 项 | 结论 |
|---|---|
| ① `k` 跨页落在上一页底部 | ✅（用户 2026-10-27） |
| ② `j` 跨页仍连续 | ✅（用户 2026-10-27） |
| ③ 末页到底停住、无空白假页 | ✅（用户 2026-10-27） |
| ④ 中间页来回滚动无回退 | ✅（用户 2026-10-27） |
| ⑤ `n` / `p` 停页首 | ✅（用户 2026-10-27） |
| ⑥ 长页页内滚动与跨页正常 | ✅（用户 2026-10-27） |
| ⑦ `SPC` / `DEL` 一屏跨页不回跳页首 | ✅（用户 2026-10-27） |

### L3 迭代 1（2026-10-27，真机探针）

| # | 探针 | 读数 | 结论 |
|---|---|---|---|
| ① | `--multipage-scroll` 返回时（向上跨页） | `page 1 / vscroll 3090 / point 4 / point_page 2` | 落点逻辑正确：point 已落到邻居页（页 2）行首，偏移也写进去了 |
| ② | `--multipage--place-point` 内部现场 | `:pages (1 2 3 4) / :below 4 / :after_point 4` | 驻留集与落点均正确 |
| ③ | 隔离探针：手 `set-window-vscroll 3090` + `goto-char` 邻居页行首 + `redisplay` | `vscroll` 保留 **3090**（窗高仅 1345 < 3090） | Emacs 本身装得下大偏移，清零不是 Emacs 拒绝大偏移 |

**结论**：唯一差异是真实路径在 `set-window-vscroll` 之后还执行了 `--multipage-sync`（插入 / 回收页行 = 修改 buffer）——buffer 修改让窗口状态失效并把像素偏移清零；偏移清零后邻居页行（y = 3292）掉出窗高，Emacs 于是把 point 从行首挪回 `window-start`。

**已实施修复**：`--multipage-scroll` 尾部顺序调换为 `--multipage-sync` → `set-window-vscroll` → `place-point`（D1 顺序相应修订，见「## 实现与计划的偏差」第 2 条），待用户复验 T5-① / T5-⑦。

### L3 迭代 2（2026-10-27，真机探针定论）

| # | 探针 | 结果 |
|---|---|---|
| ① | 只 `set-window-vscroll 3090` + `redisplay`（不改 start） | **保留 3090** |
| ② | `set-window-start`（页 1 行首）+ `set-window-vscroll 3090` + `goto 页 2 行首` + `redisplay` | **丢弃 → 0** |
| ③ | `set-window-start` + `redisplay` + `set-window-vscroll 3090` + `goto 页 2 行首` + `redisplay` | **保留 3090，point = 4** |

**结论**：Emacs 会丢弃「与新设 `window-start` 同一帧内设置」的像素偏移；让新 start 先落一帧（`(redisplay)`）之后再设偏移，偏移就被保留。这是跨页失败（向上跨页回跳页首）的最终根因，也解释了迭代 1 换序（sync 提前）无效的原因——只要偏移与 start 同帧，sync 在不在一起都不影响结果。

**已实施修复**：跨页路径改为「先 `set-window-vscroll 0`（清旧页偏移，避免闪一帧错位）→ `set-window-start` → `--multipage-sync` → `(redisplay)` 落一帧 → `set-window-vscroll`（clamp 后最终值）→ `place-point`」；页内滚动不落帧（零额外开销）。ERT 用事件表断言该顺序（`set-window-vscroll(0) → set-window-start → sync → redisplay → set-window-vscroll(offset)`），并另有「页内滚动不得调用 `redisplay`」的用例。待用户复验 T5-① / T5-⑦。

## 回退方案

若 **A2 被 L3 推翻**（point 移到邻居页行首后 redisplay 仍回滚 vscroll）：

1. 退一步实现：跨页时把 `vscroll` 归 0 并让窗口 start 落在新页行首（退化为「整页跳」，但**位置正确、不丢页**）。
2. 在 `openspec/tech-debt.md` 记录真机结论与现象（保留 probe 读数），把「跨页残影连续性」列为需要另立方案（例如把每页拆成多行、用原生行滚动）的议题。
3. 回滚判据：L3 T5-① 连续两次不通过即触发，不需再试第三轮。
