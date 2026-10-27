# 阅读器 fit 计算误用 minibuffer 窗口（页面被压成极窄条）

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅（用户 2026-10-27）、计划 ✅（用户 2026-10-27）
- 批次 1 结果：ERT 1244 → 1266（+22，19 条本批新增 + 3 条补强），warning 24 零新增，变异自检 4/4 命中，code-reviewer 通过
- L3：四项真机验收全部通过（2026-10-27）
- 已知边界：冻结期间 `--multipage-sync` 仍按压缩后的可见范围回收页（已在 tech-debt 登记，真机未观察到异常）

## 目标

1. 消除「minibuffer 激活期间 fit 计算取到 minibuffer 窗口尺寸」导致页面 spec 被改写成 153×198（极窄条 / 观感空白）的缺陷；
2. minibuffer 激活期间不重排版面（可选 UX 冻结），退出后**主动**排一次 refit，使恢复不依赖用户再按一次键。

## 根本问题（第一性原理）

| # | 事实 | 出处 |
|---|---|---|
| F1 | `--multipage-target-scale` / `--multipage-fit-scale` / `--multipage-current-fit-mode` 三处的窗口解析统一写成 `(if (window-live-p window) window (selected-window))` | `seshat-reader.el:722 / 734 / 762` |
| F2 | minibuffer 激活时 `(selected-window)` 就是 minibuffer 的 mini-window；主实例实测该窗口 `window-body-height` = **102 px**（4 行字符高） | 探针 722 条事件：`win=(2544,102) :win-total=(213,4) :win-buf=" *Minibuf-1*" :minibuf=1` |
| F3 | `height` fit 得 `102 / 792 = 0.1288`，被 `--multipage-clamp-scale` 提到下限 **0.25** | `seshat-reader.el:470`；探针 min result = 0.250000 |
| F4 | `--multipage-resize-spec` 按该 scale 把 spec 写成 `612 × 0.25 = 153×198` | 探针 `resize-spec` 翻转 `985 → 153`（8 条一组，重复 3 轮） |
| F5 | `--multipage-rerender-page` 调 `--multipage-render-page page t` 时**丢弃了 window**，内部只能回落 `selected-window` | `seshat-reader.el:1516` |
| F6 | 退出 minibuffer 后 spec 会恢复 985，但要等一次 resize/size-change 事件才发生（表现为「要按键才渲染」） | 探针时间轴：t≈377 spec=153，t≈378 恢复 985 |

⇒ 只要 fit 计算在 minibuffer 激活期间发生、且调用方没显式传窗口，页面尺寸就会被 minibuffer 窗口高度改写。

## 假设清单

| # | 假设 | 来源 | 回验方式 |
|---|---|---|---|
| A1 | 正常路径（window 显式传入且显示当前 buffer）下，统一解析器返回结果与现状完全一致 | 事实✓（解析器优先返回入参） | T4 ERT + T5 L3 第 4 步 |
| A1b | **已声明的行为改进**：不传 window 且 `(selected-window)` 不显示当前 buffer 时，解析结果由 selected-window 变为 `get-buffer-window` 命中的窗口（多窗口 / 命令执行于他 buffer 的 edge case）。方向正确，但属行为改变，需在 CHANGELOG 与本计划记录 | 事实✓（解析器设计） | T1 ERT 覆盖该分支 |
| A2 | 排除 minibuffer 窗口后，minibuffer 期间所有渲染退回 base scale / buffer-local fit-mode，页面保持不变 | 假设? | T5 L3 第 1~3 步 |
| A3 | `--multipage-current-fit-mode` 返回 nil 时，`--multipage-target-scale` 的 `_` 分支仍会用 nil 窗口算 width-fit 并报错 ⇒ 必须在 target-scale 内**先判 nil 窗口并直接返回 base** | 事实✓（读码） | T1 ERT |
| A4 | 不冻结时：D1 修复后，minibuffer 期间 refit 已用**reader 窗口**尺寸（非 102px），不会产生窄条；冻结仅影响观感与裁切 | 事实✓（`--window-size-change` 的 `windowp` 分支传的是 reader 窗口，`seshat-reader.el:2412`） | T3 ERT + T5 |
| A5 | 书签跳转（consult 的 action 在 minibuffer 上下文里执行）走同一路径，D1 一并修复 | 假设? | T5 L3 第 3 步 |

## 设计

### D1 统一窗口解析（核心 · 正确性）

新增 `seshat-reader--multipage--display-window (&optional window)`，返回活窗口或 nil：
1. WINDOW 活、`(window-minibuffer-p WINDOW)` 为 nil、且显示当前 buffer → WINDOW；
2. 否则 `(get-buffer-window (current-buffer) t)` 满足同条件 → 它；
3. 否则 `(selected-window)` 满足同条件 → 它；
4. 否则 nil。

实现用手写 `dolist` + `catch`（不引入新依赖；`window-minibuffer-p` 是内置函数）。docstring 必须写明「minibuffer 窗口永不作为返回值」及其原因（引用 F2/F3）。

改三处：
- `--multipage-target-scale`：先解析窗口；**nil → 直接返回 `(seshat-reader--multipage-clamp-scale base)`**；非 nil 走现有逻辑。
- `--multipage-fit-scale`：解析窗口为 nil → 返回 nil（docstring 已有 nil 语义，补一句原因）。
- `--multipage-current-fit-mode`：解析窗口为 nil → 只返回 buffer-local `seshat-reader--multipage-fit-mode`（可能为 nil，见注意事项 7）。

改 `--multipage-render-page (page &optional force window)`：内部把 WINDOW 传给 `--multipage-target-scale` 与 `--multipage-resize-spec`；`--multipage-rerender-page` 把自己的 window 传下去。

**范围说明（不做）**：另外三处同款解析不在本计划范围——`--multipage-base-fit-scale`(≈540)、`--apply-display-scale`(≈818)、`--multipage-resize-spec`(≈1264)。理由：它们由「上游显式传参 + `--multipage-target-scale` 内的 `get-buffer-window` 兜底」间接安全；若后续发现同类问题，登记 tech-debt 另议。

### D2 minibuffer 期间冻结版面（**纯 UX 选择**）+ 退出后主动恢复

**定性**：冻结**不承担正确性**（正确性已由 D1 保证，见 A4）。它只消除「M-x 展开时页面先缩再放」的闪烁。

- 新增 `seshat-reader-freeze-layout-during-minibuffer`（defcustom，默认 **t**）。
- 为 t 时：`--refit-window` 在 minibuffer 激活期间直接返回 nil；`--schedule-refit` 在 minibuffer 激活期间不排 timer。
- 「minibuffer 激活」的判据用 `(window-minibuffer-p (selected-window))`，并在 T3 里用 ERT 断言；**不使用** `(> (minibuffer-depth) 0)` 作为唯一判据（递归 minibuffer 与 exit 时机差异，见 T3 实测要求）。
- **判据说明**：`window-minibuffer-p` 是**结构属性**（该窗口是否 minibuffer 窗口），已覆盖递归 minibuffer 与 child-frame minibuffer；只有「用户手动 select 了另一 frame 的**非 active** minibuffer window」会误判。因冻结是纯 UX、无正确性影响，接受该误判；实现处加注释说明更精确的替代是 `minibuffer-window-active-p`。
- **代价（用户已确认接受）**：minibuffer 展开 17 行 ≈ 400 px，reader 窗口高度 1275 → 859 px；冻结期间页面仍按 1275 px 高度显示，底部约 **416 px 被窗口裁切**（不可见、不丢失，退出后立即恢复）。
- 恢复：新增 `seshat-reader--after-minibuffer-exit` 挂 `minibuffer-exit-hook`：
  - **窗口来源（已实测修正）**：`minibuffer-exit-hook` 执行时 `(minibuffer-depth)` 仍为 **1**、`(selected-window)` 仍是 mini window、`(minibuffer-selected-window)` **非 nil**（verify 实例实测，Emacs 31.1；与首轮 plan-reviewer 依 docstring 的推断相反）。故实现为「`minibuffer-selected-window` 优先 + `selected-window` 兜底」——两种时序都成立；`emacs --batch` 不触发这两个 hook（走 `read_minibuf_noninteractive`），实测必须用交互式实例。
  - **不必走 `--schedule-refit`**：统一改用 `(run-with-idle-timer 0 nil #'seshat-reader--run-pending-refit buffer)`。理由**不是**「会被保护挡掉」——判据是 `window-minibuffer-p`，exit-hook 执行时 selected-window 已恢复为 reader 窗口，保护不会命中；真正的理由是**不依赖 exit-hook 内的窗口/深度时序**：idle timer 在 `read_minibuf` 返回、主循环 idle 后才跑，此时 depth 已归零、selected-window 已恢复，最稳。`--run-pending-refit` 会清掉 `--resize-refit-timer` 并 refit 该 buffer 的全部窗口。**返回值不需保存**（one-shot idle timer；`--run-pending-refit` 内本就会把 `--resize-refit-timer` 置 nil，存引用反而要额外清理）。
  - **实现前必须先在 verify 实例实测** exit-hook 内的真值：用 `run-with-timer` 注入 `(exit-minibuffer)` 的方式，记录 `(list (minibuffer-depth) (window-buffer (selected-window)) (minibuffer-selected-window))`；实测结果写入「## 审查修订记录」。若实测 `minibuffer-depth` 已归零，则允许改用 `--schedule-refit`（二选一，以实测为准）。
- `--recenter-window` **也要冻结**：它内部会调 `--apply-display-scale` 改写 spec 尺寸（原先「只改居中属性」的说法与实际代码不符）。冻结时跳过 `--apply-display-scale`，只保留居中动作，从而真正冻结几何（代价：minibuffer 期间页面按旧尺寸显示，底部约 416 px 被裁切）。

### 明确不做

- 不改 bookmark / saveplace 的 `--apply-offset`（B3「`(redisplay t)` 导致空白」未被证实）。
- 不动渲染 C 层、不动 `--multipage-sync` 的触发时机。
- 不改 `--multipage-clamp-scale` 的下限 0.25。
- 不改 `--multipage-base-fit-scale` / `--apply-display-scale` / `--multipage-resize-spec` 三处解析（见 D1 范围说明）。
- 不新增 `(> (minibuffer-depth) 0)` 作为判据（以 `window-minibuffer-p` 为准）。

## 任务

- [x] T1 `seshat-reader.el` 新增 `--multipage--display-window` 并替换三处解析（按 D1）。验收：`(fboundp ...)` 为 t；ERT 覆盖四分支（入参窗口可用 / 回落 `get-buffer-window` / 回落 `selected-window` / 全不满足→nil）+ 「minibuffer 窗口永不被返回」+ A1b 的 edge case（不传 window、selected-window 显示他 buffer 时返回 `get-buffer-window` 命中的窗口）。（依赖：无）
- [x] T2 `--multipage-render-page` 增 WINDOW 参数并向下传；`--multipage-rerender-page` 传自己的 window。**必须逐个核对的调用点**（grep 结果须写入报告）：`--multipage-render-page` 的全部调用点（含 `--multipage-sync` / `--multipage-goto` / `--multipage-set-scale`（**间接**：经 `--multipage-refit-page` → `--multipage-rerender-page` → `--multipage-render-page`，不直接调用） / `--multipage-refit-page` 等约 9 处）；`--multipage-rerender-page` 的调用点（约 3 处，**含 `seshat-reader--redisplay-all-windows`(≈3484) 只传 page、不传 window 的位置**）。验收：报告里逐一列出「调用点 → 传哪个窗口 → 是否需改」；ERT 断言渲染期间 `--multipage-target-scale` 收到的是「显示当前 buffer 的窗口」。（依赖：T1）
- [x] T3 D2 落地：`seshat-reader-freeze-layout-during-minibuffer` + refit/schedule 冻结 + `--after-minibuffer-exit`。**先做 exit-hook 实测**（见 D2 恢复小节），实测结果写入「## 审查修订记录」，再按实测结论选 `run-with-idle-timer` 或 `--schedule-refit`。验收：ERT 断言①`window-minibuffer-p` 为真时 `--refit-window` 不调用 `--multipage-rerender-page`；②`--schedule-refit` 不产生 timer；③`--after-minibuffer-exit` 在 reader 窗口下确实排到 `--run-pending-refit`（断言 `run-with-idle-timer` 收到 buffer 实参或 timer 被建立）；④defcustom 为 nil 时不冻结。（依赖：T1）
- [x] T4 L1 + L2：`make -C emacs/seshat-reader clean all` EXIT 0 且 warning ≤ 24（零新增）、`make -C emacs/seshat-reader checkdoc` 0 新增、`elisp_check_parens` 通过、`make -C emacs/tests ert` 0 unexpected / 0 skipped（**执行前先取当日真实基线**，计划记 1226，以实测为准并记录差值）、`check-criteria` PASS。**变异自检**：把 `--multipage--display-window` 改回 `(if (window-live-p window) window (selected-window))`，新增 ERT 必须变红（逐个变异点记录）。（依赖：T1–T3）
- [x] T5 L3 真机（用户执行）：① M-x 期间页面不出现窄条，退出后一帧内恢复原尺寸；② `bookmark-set` 用 rime 输中文回车后无空白/窄条；③ 书签跳转后落到目标页与偏移且无空白；④ `+` / `-` / fit 模式切换行为与修复前一致。验收判据见「## 验证标准」L3。（依赖：T4）
- [x] T6 文档：`CHANGELOG.md`（Unreleased · 修复 + A1b 行为改进说明）、`docs/emacs-reader.md`（补 fit 计算的窗口语义）、`openspec/decisions.md`（新增决策：fit/render 的窗口解析永不使用 minibuffer 窗口）、`openspec/tech-debt.md`（如有对应条目则勾销；并把「另三处同款解析」登记为观察项）、`openspec/completed/` 归档、**README / Readme.org 判定**（若描述了 fit/缩放行为则同步）。（依赖：T4）

## 批次执行

| 批次 | 任务 | 验收层 | 风险 |
|---|---|---|---|
| 1 | T1 + T2 + T3（解析器 + 渲染传参 + 冻结/恢复 + ERT + exit-hook 实测） | L1 + L2 | 中（触碰 fit 计算，影响全部渲染路径） |
| 2 | T5 真机（用户）+ T6 文档 | L3 + 文档一致性 | 中（窄条只能在真机确认） |

批次间不跨批提交；批内合为 1 个 fix commit。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` EXIT 0；warning ≤ 24（基线，零新增）；`checkdoc` 0 新增；`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → `unexpected = 0` 且 `skipped = 0`；`check-criteria` PASS。
- **L3 判据（改为相对跳变，不用绝对阈值）**：在三个场景里记录操作前后的 spec 宽度；判定「异常跳变」= 操作后 spec 宽度与操作前的比值 < 0.5 且 `fit-mode` 非 `manual`。`manual` 下单页缩到 0.25（spec 宽 153）属正常，不作为缺陷。
- 任务类型：elisp 验证走 `verify` 隔离实例；收尾 `set_task(auto)` → `instance(stop, verify)` → `instance_status(verify)` 确认。

## 文档清单

| 文档 | 需更新内容 |
|---|---|
| `CHANGELOG.md` | Unreleased · 修复：minibuffer 激活期间阅读器按 minibuffer 窗口高度重算 fit，页面被压成极窄条；另注明 A1b 的窗口解析行为改进 |
| `docs/emacs-reader.md` | 补「fit 计算使用哪个窗口」的语义：显示当前 buffer 的真实窗口；minibuffer 期间的行为 |
| `openspec/decisions.md` | 新增决策：fit / render 的窗口解析永不使用 minibuffer 窗口（附探针证据要点） |
| `openspec/tech-debt.md` | 勾销「页面尺寸异常 / 空白」类条目（如有）；登记「另三处同款解析待观察」 |
| `README.md` / `Readme.org` | **判定项**：若描述了 fit / 缩放行为则同步，否则注明无需改 |
| `openspec/completed/` | 本计划完成后归档 |

## 注意事项

1. **A3 是硬约束**：`--multipage-target-scale` 解析出 nil 窗口时必须**先返回 base**，不能继续走到 `window-body-width nil`。
2. 改 `--multipage-render-page` 签名后要 grep 全部调用点（EE-8）。**漏传 window 不会立刻出错**（解析器会用 `get-buffer-window` 兜底），但会让人误判「此处已正确传参」——所以显式传参是**一致性要求**，不是正确性要求。
3. D2 冻结几何：`--recenter-window` 也跳过 `--apply-display-scale`（其内部会改 spec 尺寸），只保留居中；`--multipage-sync` 不冻结（维持驻留集与视口一致）。
4. 递归 minibuffer（`enable-recursive-minibuffers t`）会多次触发 `minibuffer-exit-hook`；用 `(selected-window)` 判 buffer 的做法天然幂等。
5. 不在 minibuffer 期间调用 `(redisplay t)`。
6. ERT 模拟 minibuffer 用 `cl-letf` stub `window-minibuffer-p` 或 `with-selected-window (minibuffer-window)`，不要依赖真实交互。
7. `--multipage-current-fit-mode` 改造后可能返回 nil（原来经 `--window-fit-mode` 兜底为 `'contain`）。已核对 `seshat-reader-presentation-mode`(≈3687) 的 `(cons (current-fit-mode) ...)`：该路径是用户命令、窗口可用，`get-buffer-window` 必命中，不受影响；T1 需补一条 ERT 断言 nil 窗口下返回 buffer-local 值（可为 nil）。
8. 探针数据可复算：spec 尺寸 = `native(612×792) × clamp(height_fit, 0.25, 11.0)`，全部真机样本逐条吻合。

## 回退方案

- **D1**：单点解析器。若真机发现正常路径行为改变，把三处调用改回 `(if (window-live-p window) window (selected-window))` 即回退（新函数保留不调用）。
- **D2**：把 `seshat-reader-freeze-layout-during-minibuffer` 设为 nil 即恢复「跟随 minibuffer 缩放」；若 exit-hook 实测不成立，退化为「不主动恢复，保持现状（需要按键）」，并把该限制登记 tech-debt。

## L3 验收表

| 项 | 结论 |
|---|---|
| ① M-x 期间无窄条、退出即恢复 | ✅ 通过（2026-10-27 用户真机） |
| ② bookmark-set 输中文回车无空白 | ✅ 通过（2026-10-27 用户真机） |
| ③ 书签跳转落点正确且无空白 | ✅ 通过（2026-10-27 用户真机） |
| ④ 缩放 / fit 切换行为不变 | ✅ 通过（2026-10-27 用户真机） |

## 审查修订记录

首轮 plan-reviewer（2026-10-27）「不通过」，处置如下：

| # | 等级 | 问题 | 修订 |
|---|---|---|---|
| B1 | blocking | `minibuffer-exit-hook` 内 `(minibuffer-selected-window)` 返回 nil；且 `minibuffer-depth` 可能仍 ≥1，会让 `--schedule-refit` 的保护把恢复挡掉；T3 验收与实现自相矛盾 | D2 恢复改为「用 `(selected-window)` 取窗口 + 直接 `run-with-idle-timer 0 #'--run-pending-refit`」；T3 增加「实现前先实测 exit-hook 真值，按实测二选一」；验收同步改写 |
| M1 | major | D2 的冻结在 D1 修复后冗余，且引入裁切/溢出风险；动机（正确性 vs UX）写混 | 明确 D2 冻结是**纯 UX 选择**（正确性由 D1 保证，新增 A4 事实）；给出裁切量化（≈416 px）；新增 `seshat-reader-freeze-layout-during-minibuffer` defcustom 作为开关；回退方案补「设为 nil 即恢复现状」 |
| m1 | minor | `--multipage-render-page` 签名漏写 `page`；未指定 minibuffer 判定 API | 改为 `(page &optional force window)`；判定统一用 `window-minibuffer-p`（内置） |
| m2 | minor | 另三处同款解析（`--multipage-base-fit-scale` / `--apply-display-scale` / `--multipage-resize-spec`）未说明为何不改 | D1 增「范围说明（不做）」并给理由；T6 要求登记 tech-debt 观察项 |
| m3 | minor | `--redisplay-all-windows`(≈3484) 调 rerender-page 未传 window；注意事项 2 措辞夸大 | T2 明确把该点列入必查清单；注意事项 2 改为「一致性要求，非正确性要求」 |
| m4 | minor | L3 判据「spec < 200」会误伤 manual 缩放 | 改为相对跳变判据（比值 < 0.5 且 fit-mode 非 manual） |
| m5 | minor | `--multipage-current-fit-mode` 可能返回 nil，presentation-mode 未评估 | 注意事项 7 记录核对结论 + T1 补该分支 ERT |
| m6 | minor | A1 未覆盖「不传 window 且 selected-window 不显示 current-buffer」的行为改变 | 新增 A1b 声明该改进，并要求写入 CHANGELOG |
| m7 | minor | 文档清单缺 README 判定 | 文档清单增 `README.md` / `Readme.org` 判定项；T6 同步 |
| R1 | 实测 | 首轮 B1 的证据方向被推翻：exit-hook 内 `minibuffer-depth` 仍为 1、`selected-window` 仍是 mini window、`(minibuffer-selected-window)` 非 nil（verify 实例实测 Emacs 31.1） | 实现改为「`minibuffer-selected-window` 优先 + `selected-window` 兜底」；`emacs --batch` 不触发 hook 的结论一并记入 |
| R2 | 事实修正 | `--recenter-window` 会调 `--apply-display-scale` 改写 spec 尺寸，「recenter 只改居中属性」的说法与代码不符 ⇒ 只冻结 refit 不足以实现 D2 | `--recenter-window` 也纳入冻结（跳过 `--apply-display-scale`）；补两条 ERT（冻结跳过 / 非冻结仍调用） |

**待补实测**：exit-hook 内 `(list (minibuffer-depth) (window-buffer (selected-window)) (minibuffer-selected-window))` 的真值（T3 执行时填入本节）。

## 事实来源

| 来源 | 用途 |
|---|---|
| 运行期探针日志 `/tmp/seshat-diag-log.eld`（722 条：target-scale 399 / resize-spec 232 / page-spec 91） | 全部分母数据 |
| 最小 scale 0.250000 @ `win=(2544,102) win-total=(213,4) win-buf=" *Minibuf-1*" minibuf=1` | F2/F3 |
| spec 尺寸集合：153 / 340 / 360 / 485 / 664 / 837 / 925 / 983 / 985 / 1122 | F4 |
| `resize-spec` 翻转序列 `985→153`（8 条）、`153→153`、`153→985`（8 条） | F4/F6 |
| 与 posframe / 80×25 的 `F1` frame 相关事件：**0 条**（该假设被排除） | 排除对照假设 |
| `seshat-reader.el:470 / 722 / 734 / 762 / 1480 / 1516 / 2412 / 2527 / 3484 / 3687` | 代码位置 |
