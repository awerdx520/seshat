# 阅读器多页布局 P2：异步渲染、跨页选区与单页 overlay 机制退役

## 当前状态
- 阶段：Phase 1（Brainstorm）· 范围待用户确认
- 前置：P1（T1–T10）已完成并归档 → `openspec/completed/2026-10-26-reader-multipage-p1-layout.md`
- 已确认：无（本文件仅登记候选范围，未细化任务、未审查、未排期）
- 下一步：用户圈定要做哪几项 → 逐项走 Phase 1 方案确认 → 细化为任务列表

## 背景

P1 把阅读器从「单页 overlay + 像素级 vscroll」改为「buffer 内多页纵向布局」，遗留项已登记在 `openspec/tech-debt.md` 的「2026-10-27 阅读器多页布局（P1）遗留」与 `openspec/decisions.md` 的 2026-10-27 条。本文件把这些遗留折成可排期候选，**不代表已同意全部实施**。

P2-2 / P2-8 已于 2026-10-27 交付并归档；池内剩余 P2-1 / P2-3 / P2-4 / P2-5 / P2-6 / P2-7。

## 候选任务（按建议优先级）

| # | 任务 | 来源 | 依赖 | 规模 | 风险 |
|---|---|---|---|---|---|
| P2-1 | **异步渲染 + idle 预取**：滚动进入新页时不再同步阻塞主线程（现 0.7–11 ms/页）；需先复验 daemon 下 idle timer 的可靠性（tech-debt 有历史记录） | tech-debt「异步渲染未做」 | 无 | 中 | 中（daemon/批量场景差异） |
| P2-2 | **跨页选区 ✅ 已完成（2026-10-27，见 `openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`）**：按阅读顺序拼接两页文本；`seshat-reader-select-last` 新增 `:page-rects`（带页号的分段矩形）；`location` 新增 `pages:<a>-<b>;rect@<p>:…` 形态（单页仍写旧形态、逐字节不变） | D7 / tech-debt | P1 | 中 | 中（协议、坐标、批注位置） |
| P2-3 | **横向滚动整栏平移**：`height` 模式与手动放大下宽页让整栏（含邻页）一起平移。候选方案：① 宽页改「缩到窗宽」不裁字（改变 `height` 语义）；② 每页加左右 margin 用 buffer 内空白模拟横向滚动；③ 保持现状 + 文档化 | D5b / tech-debt | 无 | 小–中 | 中（观感取舍） |
| P2-4 | **C 侧单页 overlay 机制退役**：`init_overlay` / `init_win_state_ptr` / `get_win_state_ptr` / `--refresh-highlights` / `--window-close` 现仅剩兼容外壳；先给 `elisp-helpers.c:279-287` 的 `overlay-put` 补 nil 守卫，再整族删除并重建 `.so` | tech-debt | P2-1（若同时改渲染线程） | 中 | 中（C 改动需真机重启验证） |
| P2-5 | **内存与驻留策略**：spec 在 Lisp 堆与 C 侧各存一份（≈2×）；评估「pin 引用而非复制」、`page-spec-cache-limit` 与 `preload` 上限的组合、把 75 MB 告警线做成可观测指标 | tech-debt | 无 | 中 | 中 |
| P2-6 | **L3 收尾确认**：把 P1 计划「## 验证标准 · L3」十五项逐条真机复核并记录结果（含 `page-gap-lines=2` 页底滚动、双窗口缩放后选区坐标） | P1 归档计划 | 无 | 小 | 低 |
| P2-7 | **渲染基准回退分支**：若真机观感显示「异常宽页被缩得过小」，评估「全文档最大页尺寸」基准（需新增 C 侧批量查页尺寸接口 `fz_bound_page`） | D5 回退分支 | P2-4 | 小 | 低 |
| P2-8 | **旋转页的高亮/选区坐标 ✅ 已完成（2026-10-27，见 `openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`）**：tech-debt 旧条目（旋转页高亮可能错位）在 P1 后的多页语义下重新核对 | tech-debt（M12） | P2-2 | 小 | 中 |

> **2026-10-27 追加**：本候选池之外新增两个真机缺陷（① 向上跨页后页内偏移被 redisplay 回滚、视口跳回上一页顶部；② 末页可滚出 PDF 页、出现空白「假页」），已单独立计划 `openspec/completed/2026-10-27-reader-cross-page-scroll-fix.md`，**不在本池内重复排期**。

## 假设与风险（初稿，细化时重写）

| # | 假设 | 来源 |
|---|---|---|
| A1 | 异步渲染可以只替换「取 spec」这一步，布局/居中/缓存层不动 | 假设? |
| A2 | 跨页选区的 `location` 协议可以向后兼容（旧 `page:<n>;rect:…` 仍可读） | 假设? |
| A3 | 横向滚动整栏平移在真机上只是「轻微观感」而非功能阻塞 | 假设?（待 L3 观察） |

风险：P2-2 与 P2-4 都触协议/ C 层，建议**不要并批**；P2-1 与 P2-5 涉及同一份内存模型，建议**同批**或先 P2-5 定结论。

## 验证标准（沿用 P1 的基建）

- **L1**：`make -C emacs/seshat-reader clean all` EXIT 0、warning 不超过基线 **24**（零新增）、checkdoc 0、`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → `0 unexpected` **且** 0 skipped（判据由 `emacs/tests/ert-judge.sh` 数值判定，含 `10 unexpected` / `Ran 0 tests` / `skipped` 三种假绿防护）；`make -C emacs/tests check-criteria` PASS。
- **L3**：凡触及几何/滚动/坐标的批次，必须真机肉眼验收（batch 不产生真实 redisplay）。
- 任务类型：elisp 验证走 `verify` 隔离实例；收尾 `set_task auto` + `instance stop` + `instance_status`。

## 文档清单（细化时按此同步）

`docs/architecture.md`（异步渲染 / overlay 退役后的结构）、`docs/emacs-reader.md`（跨页选区的使用与限制、横向滚动语义）、`docs/configuration.md`（若有新选项）、`emacs/seshat-reader/VENDORED.md`（C 改动）、`CHANGELOG.md`、`openspec/decisions.md`（协议与取舍）、`openspec/tech-debt.md`（勾销已解决项）、`openspec/roadmap.md`。

## 注意事项

1. **未确认不等于要做**：本文件是候选池，用户圈定后再补「## 目标 / ## 任务 / ## 批次执行」并走 plan-reviewer 审查。
2. **不引入第二套布局**（P1 决策 4）：所有后续方案都必须在「多页 buffer 布局」内实现，不得复活单页模式。
3. 每个批次结束必须跑 `make -C emacs/tests ert` + `check-criteria`，并在真机上复核受影响的行为。
