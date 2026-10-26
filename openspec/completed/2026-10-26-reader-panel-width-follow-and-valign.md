# 阅读器译文/解释面板：正文宽度跟随窗口 + valign 表格对齐

## 当前状态
- 阶段：Phase 4（完成）· T1–T6 全部完成，计划已归档（`openspec/completed/2026-10-26-reader-panel-width-follow-and-valign.md`）
- 已确认：方案 ✅（用户 2026-10-26 确认：方案 B，ratio=0.94，valign 默认开）、计划 ✅（用户 2026-10-26 确认并委派执行）
- 验证：L1 `make -C emacs/seshat-reader clean all` EXIT 0、warning 33（= 基线）、checkdoc 0 报错；L2 逐文件 ERT 28 个文件合计 **1150** 例，`unexpected = 0` / `skipped = 0`（translate 套件 **159**、sidebar 套件 **143**）；L3 六项用户真机实测通过（① 扩宽后正文同步变宽；② 再按 `w` 恢复且正文同步收窄；③ 阅读 buffer 中按 `w` 正文同样跟随；④ 解释面板 Markdown 表格列对齐；⑤ ratio `nil` 回退旧行为；⑥ 窄面板 + 宽表格裁切表现符合预期）
- 文档：八份已同步（`docs/emacs-reader.md`、`docs/configuration.md`、`docs/architecture.md`、`emacs/seshat-reader/VENDORED.md`、`CHANGELOG.md`、`openspec/decisions.md`、`openspec/tech-debt.md`、`openspec/active/roadmap.md`），外加兜底批次补充（`seshat-reader-sidebar--refresh-panel-text-width`）
- 审查：plan-reviewer 已审（PASS，1 major + 4 minor + 2 nit，**本文件已按建议全部修订**）；code-reviewer 已审（PASS，3 minor **已修**）；现场诊断后补 hook 兜底（`w` / `C-c w` 的 resize 出口显式 `--vfcm-refresh`，sidebar 套件 +4 例）

## 目标

修复译文/解释面板的宽度自适应缺陷：按 `w` / `C-c w`（`seshat-reader-sidebar-toggle-width`）把面板扩宽后，窗口确实变宽，但正文文本区宽度不变、新增宽度全部变成空白。修复后正文宽度跟随面板窗口（默认占窗口文本区 94%，可配置），并在面板内启用 `valign-mode` 让 Markdown 表格列视觉对齐。

## 根本问题（第一性原理）

| 事实 | 依据 |
|---|---|
| `--prepare-view` 只调 `(visual-fill-column-mode 1)`，全程从不设置 `visual-fill-column-width` | `emacs/seshat-reader/seshat-reader-translate.el:756-765` |
| vfcm 的 `--set-margins` 取 `(or visual-fill-column-width fill-column)`；本机 `visual-fill-column-width` 为 nil、`fill-column` 为整数 | `visual-fill-column.el` v2.7.1 源码 + `describe-variable` 实测 |
| vfcm 在 Emacs 28+ 注册 buffer-local `window-state-change-functions`（`'append`），窗口尺寸变化时**主动重算 margin 以维持固定正文宽**——这正是「扩宽后只有空白变多」的机制 | vfcm `visual-fill-column-mode--enable` + elisp Info 29.30 |
| 常态面板（约 0.25×frame ≈ 50 列）窄于 `fill-column`（默认 70）→ margin 被夹为 0，故缺陷只在扩大态/宽 frame 暴露 | 推演，L3 实测确认 |
| 译文与解释**共用同一 buffer** `*Seshat Sidebar*`（单一常量 `seshat-reader-sidebar-translate-buffer-name`，仅 header-line 不同）→ valign 无法按 context 只对解释生效 | 代码事实 |

**设计冲突**：`toggle-width` 的语义是「用户主动放宽→看更多内容」，vfcm 的语义是「正文宽度恒定→宽窗口只加留白」，二者对立。M11.14（`openspec/completed/2026-10-18-reader-panel-visual-fill-column.md`）引入 vfcm 时面板宽度尚不可切换，该动机已失效。

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | 正文宽度被锁在全局 `fill-column` 是唯一根因 | 事实✓ |
| A2 | 本机 `visual-fill-column-width` = nil、`fill-column` 为整数 | 事实✓ |
| A3 | vfcm 在窗口尺寸变化时主动重算 margin 以维持固定宽度 | 事实✓ |
| A4 | buffer-local `window-state-change-functions` 中「我们 prepend、vfcm append」可决定执行顺序 | 事实✓（Info 语义 + vfcm 用 `'append`）；实现后须实测确认 |
| A5 | `gfm-view-mode` 派生自 `markdown-mode`，valign 据此走 markdown 表格解析；降级 `text-mode` 时回落按 org 规则推断 | 假设?（实现时实测） |
| A6 | 译文/解释共用 buffer，valign 只能统一启用 | 事实✓ |
| A7 | 折行模式（`seshat-reader-panel-truncate-lines` 为 nil）下宽表格溢出属既有行为，valign 不加剧 | 假设?（实测确认） |
| A8 | 用户接受正文占窗口文本区 94%（左右各约 3% 留白） | 用户显式（2026-10-26 确认） |

## 设计

### D1 vfcm 宽度跟随面板窗口

- 新增 defcustom `seshat-reader-translate-visual-fill-column-ratio`，默认 `0.94`；`nil` 表示回退旧行为（沿用全局 `fill-column`）。
- 新增函数 `seshat-reader-translate--vfcm-follow-window (window)`：
  - `with-current-buffer (window-buffer window)`；
  - 仅当 `(bound-and-true-p visual-fill-column-mode)` 时生效；
  - 可用总宽 `avail` **必须与 vfcm 的 `--window-max-text-width` 同源**：`truncate((window-width window 'remap) + Σmargin×remap-scale)`，其中 `remap-scale = (window-width window 'remap) / (window-width window)`（vfcm v2.7.1 `--window-max-text-width` 的等价式）。**不得**用 `window-body-width`：它不含 fringes / scroll-bar / divider，会比 vfcm 的口径少 2–4 列，导致实际正文比 `ratio` 算出的比例窄、L3 场景①「左右各约 3% 留白」对不上；
  - **ratio 为 nil 时直接返回**（`(when (numberp seshat-reader-translate-visual-fill-column-ratio) …)` 守卫），不得把 nil 传进乘法——那会报 `wrong-type-argument`；nil 语义是「沿用全局 `fill-column`」；
  - `setq-local visual-fill-column-width (max 1 (round (* avail ratio)))`；
  - 调 `(with-selected-window window (visual-fill-column-adjust))` 立即重算 margin（公开命令，避免依赖私有函数）。
- 注册刷新 hook：`--prepare-view` 内 `add-hook 'window-state-change-functions #'seshat-reader-translate--vfcm-refresh nil 'local`（**不加 append**，排在 vfcm 的 `'append` adjust 之前，保证「先改宽度、后算 margin」）。
- 包装函数 `seshat-reader-translate--vfcm-refresh (&optional window)`：WINDOW 缺省取 `(get-buffer-window (current-buffer) t)`，取不到则静默返回。
- 首次显示修正：`--render-panel` 在 `seshat-reader-sidebar-show` 之后调用一次 `--vfcm-refresh`（`(visual-fill-column-mode 1)` 在 `--prepare-view` 时以 selected-window 计算首次 margin，可能算到阅读窗口上，这是 M11.14 已记录的已知副作用，本轮做显示后收口）。
- 关闭分支：`seshat-reader-translate-visual-fill-column` 为 nil 时不注册 hook。`kill-local-variable 'visual-fill-column-width` 保留**仅作防御性冗余**——`--prepare-view` 每次 `funcall mode` 都会触发 `kill-all-local-variables`，width 本已被清空；不要把它写成「防残留的唯一机制」。
- `seshat-reader-sidebar-toggle-width` **零改动**：resize 触发 `window-state-change-functions` → 宽度重算，手动拖窗口同样生效。

### D2 valign-mode 集成

- 新增 defcustom `seshat-reader-translate-valign`，默认 `t`。
- `--prepare-view` 末尾：`(when (and seshat-reader-translate-valign (require 'valign nil t)) (valign-mode 1))`（软依赖，缺失静默跳过，与 vfcm 同一处理范式）。
- 面板 major-mode 为 `gfm-view-mode`（markdown 派生）→ valign 走 markdown 表格解析；markdown-mode 缺失降级 `text-mode` 时 valign 回落按 org 规则推断。
- 只读兼容：valign 用 `with-silent-modifications` 设置 `display` 文本属性与 overlay，`buffer-read-only` 为 t 不影响。
- 非图形环境（`display-graphic-p` 为 nil）valign-mode 自身只提示、不启用——batch 测试据此断言。

### D3 幂等与复用

`add-hook` 幂等、两个 minor mode 的 `-1/+1` 幂等、buffer 复用不残留（关闭分支 kill-local-variable）。valign 的全局 advice 由其自身 `kill-buffer-hook`（`valign--maybe-clean-advice`）清理，本包不额外挂摘。

## 任务

- [x] T1 新增两个 defcustom（`seshat-reader-translate-visual-fill-column-ratio` 默认 `0.94`、`seshat-reader-translate-valign` 默认 `t`），docstring 说明语义、回退方式与软依赖行为。验收：`M-x customize-group RET seshat-reader-translate` 可见两项且默认值正确。（依赖：无）
- [x] T2 实现 `seshat-reader-translate--vfcm-follow-window` / `--vfcm-refresh`，并在 `--prepare-view` 中接线（注册 local hook、设置 buffer-local 宽度、关闭分支 `kill-local-variable`）。验收：`--prepare-view` 后面板 buffer 的 `window-state-change-functions` buffer-local 值含 refresh 函数、全局值不含；`visual-fill-column-width` 在 vfcm 启用时被设为「窗口文本区宽 × 0.94」。（依赖：T1）
- [x] T3 `--render-panel` 在面板显示之后调用 `--vfcm-refresh`。验收：显示后 `visual-fill-column-width` 按面板实际窗口宽度算出（不是阅读窗口宽度）。（依赖：T2）
- [x] T4 新增 ERT 用例（`emacs/tests/seshat-reader-translate-test.el`，≥9 例）：① 按 ratio 计算宽度；② ratio 为 nil 时不设 width（回退 fill-column）；③ vfcm 未启用时不设、不报错；④ `--prepare-view` 注册 buffer-local hook 且不污染全局；⑤ valign 可用且选项 t 时启用 `valign-mode`（`cl-letf` 令 `display-graphic-p` 为 t）；⑥ 选项 nil 时不启用；⑦ valign 缺失时静默；⑧ 关闭 vfcm 时 `kill-local-variable` 生效（复用 buffer 无残留宽度）；⑨ `--render-panel` 确实调用了 refresh（cl-letf 计数）。⑩ 宽度公式与 vfcm 口径一致（用 remap 版 `window-width` 构造桩，断言 `visual-fill-column-width` 等于 remap 口径算出的值，而非 `window-body-width` 口径）。验收：新增用例全绿，既有 translate/sidebar 用例零改动零失败（实得 16 例）。（依赖：T2、T3）
- [x] T5 文档同步（详见「文档清单」）。验收：八份文档均已同步。（依赖：T2–T4）
- [x] T6 验证与归档：L1/L2/L3 全绿后勾选任务、更新「当前状态」、计划移入 `openspec/completed/`。（依赖：T1–T5）验收：L1/L2 全绿、L3 六项用户实测通过（含扩大/恢复/阅读 buffer 中按 `w`/表格对齐）、计划已归档。

## 文档清单

| 文档 | 需同步内容 |
|---|---|
| `docs/emacs-reader.md` | 面板配置表新增两个变量；面板渲染说明（约 367、614 行）改写「正文按全局 fill-column 缩窄」为「正文宽度跟随面板窗口（ratio 0.94，可配）」；补 valign 与宽表格溢出限制 |
| `docs/configuration.md` | `seshat-reader-translate-visual-fill-column`（约 192 行）与 `seshat-reader-panel-truncate-lines`（约 257 行）条目更新；新增 ratio 与 valign 两行；ratio 条目须写明「设为 nil = 恢复旧行为（正文固定为全局 fill-column，扩宽面板后仍只增留白）」——这是刻意保留的回退路径，不是「关闭修复但不回退」 |
| `docs/architecture.md` | 第 194 行「宽度缩窄（M11.14 起）」段落改写为跟随窗口 + valign |
| `emacs/seshat-reader/VENDORED.md` | `seshat-reader-translate.el` 条目追加本轮改动（含「重新复制上游 vendor 时不得覆盖」提示保持不变） |
| `CHANGELOG.md` | `[Unreleased]` 下新增修复条目，写明现象、根因、新变量与默认值、回退方式 |
| `openspec/decisions.md` | 新增决策：面板正文宽度跟随窗口 + valign；注明部分取代 2026-10-18「沿用全局 fill-column」决策 |
| `openspec/active/roadmap.md` | 新增一行里程碑条目（状态 ✅ 完成与指向本计划） |
| `openspec/tech-debt.md` | 新增一条**已知限制**：译文/解释面板宽表格溢出（valign `display '(space :align-to …)'` 绝对像素对齐 → 表格宽于文本区时右侧裁切、不能折行也不能横滚；本计划不解决，缓解=按 `w` 加宽面板） |

## 验证标准

- **L1（语法/编译）**：修改文件 `elisp_check_parens` 通过；`make -C emacs/seshat-reader all` EXIT 0、warning 数不超过基线 33、checkdoc 0 报错。
- **L2（测试）**：`emacs/tests/` 逐文件跑 ERT（必须带项目文档给出的 `-L` 依赖路径），`unexpected = 0`、`skipped = 0`；本轮新增 ≥9 例全绿，既有 translate / sidebar 套件零回归。
- **L3（手工验收，GUI）**：① 打开译文面板按 `w` → 正文随窗口变宽（左右各约 3% 留白）；② 再按 `w` 恢复原宽度且正文同步收窄；③ 在阅读 buffer 中按 `w`（面板非选中窗口）→ 正文同样跟随；④ 解释面板内含 Markdown 表格时列视觉对齐；⑤ `(setq seshat-reader-translate-visual-fill-column-ratio nil)` 后回退旧行为（正文固定 `fill-column`）；⑥ 窄面板 + 宽表格溢出裁切与预期一致。
- **任务类型**：elisp 验证一律声明 `verify`（隔离实例，禁止在 `config` 下跑 ERT）；收尾 `elisp_mcp_set_task auto` + `elisp_mcp_instance(action=stop, instance=verify)` + `elisp_mcp_instance_status` 确认。

## 注意事项

1. **hook 顺序是外部包契约**：vfcm 用 `'append` 注册 adjust。若依赖升级改变该行为，正文宽度会滞后一次重绘（观感为「第一次 resize 不变、第二次才变」），届时需改为在 refresh 内直接调 `visual-fill-column-adjust`（当前设计已调用，作为双保险）。
2. **宽表格溢出**：valign 用 `display '(space :align-to …)` 把列推到绝对像素位置，表格宽于文本区时右侧被裁切、不能折行也不能横滚。这是既有行为，valign 不加剧；缓解方式是按 `w` 加宽面板。不得为此擅自改 `seshat-reader-panel-truncate-lines` 默认值。
3. **valign 依赖 selected window 测量**：其内部多处用 `window-text-pixel-size nil …`（nil = selected window）。面板非选中时（阅读 buffer 里按 `w`）表格重对齐精度可能略有差异；若实测错位，补「refresh 后在面板窗口内 `jit-lock-refontify`」，不得改 valign 源码。
4. **不得触碰**：`seshat-reader-sidebar.el` 的宽度记忆与 toggle 逻辑（`--width-memory` / `--state` / `--resize-width`）不在本计划范围；panels 的承载分派（childframe / window）不改。另外说明：`childframe` 承载下按 `w` 本就只提示「不支持调整宽度」（`seshat-reader-sidebar-toggle-width` 的既有分支），因此本修复**仅对窗口承载 + 左右分栏**生效，不覆盖 childframe。
5. **零依赖边界**：`seshat-reader-sidebar.el` 零依赖，本计划所有新代码放在 `seshat-reader-translate.el`，不得让 sidebar 模块 require translate 或 valign / vfcm。
6. **不改默认缓冲名与模板机制**：`*Seshat Sidebar*`、`seshat-reader-translate-template` / `-explain-template` 不动。
7. **行为回退路径必须可用**：`(setq seshat-reader-translate-visual-fill-column nil)`、`(setq seshat-reader-translate-visual-fill-column-ratio nil)`、`(setq seshat-reader-translate-valign nil)` 三者任一都能独立关闭对应行为，不得互相耦合。
