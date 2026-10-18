# 批注列表去掉分页，改为单列连续流（M11.13）

## 当前状态

- 阶段：Phase 4（Review）· 已完成并归档
- 已确认：方案 ✅（用户 2026-10-18 确认，单列连续流）、计划 ✅（用户 2026-10-18 确认）
- 实现：✅ T1–T5 完成（删除分页全套 + `]`/`[`；ETAF viewport 高度按内容计算；徽章「N 条」）
- 验证：L1 全绿（check-parens 4/4、byte-compile 零 warning、checkdoc 零告警）；L2 annotation 26/26、etaf 18/18、sidebar 29/29、translate 43/43
- 补测：新增 `--render-annotations-refit-grows-viewport`（条目增多时 refit 放大视口）
- 审查：code-reviewer 通过（无 blocking/major；3 处 minor 已修）
- 归档：`openspec/completed/2026-10-18-annotation-list-continuous-flow.md`

## 目标

用户要求「批注列表去掉分页」「瀑布流式展示」，已确认按**单列连续流**实现：

1. 删除批注列表的全部分页机制（页大小配置、当前页、页数/切片/夹紧函数、翻页命令、`]`/`[` 键位、页脚）；
2. 删除 ETAF 卡片列表的**固定 12 行高度 + 内部滚动**，改为按内容自然铺开、面板窗口整体滚动；
3. 徽章始终显示「N 条」；`n`/`p` 仍移动选中，但不再触发切页。

## 根本问题与假设

**根本问题**：分页 + 固定 12 行内部滚动把列表切碎——无法连续浏览、`isearch` 只能搜当前页、`n`/`p` 到页尾被迫切页。只删分页而不删固定高度，会退化为「12 行内部滚动」，问题依旧。

**假设清单**：

| # | 假设 | 来源 |
|---|---|---|
| A1 | 「瀑布流」= 单列连续流（非多列 masonry） | 用户显式（选项 A） |
| A2 | 面板高度仍用 `seshat-reader-sidebar-height`（0.35）固定，列表在**窗口**内滚动（不是 ETAF 画布内滚动） | 假设? |
| A3 | ETAF **根 viewport 高度固定**：`etaf-mount` 的 `:viewport-height` 决定 ebox 写入 buffer 的行数，容器 `:height` 只在 viewport 内 sizing；因此「只去掉容器高度即可自然撑开」**不成立**，必须按内容**显式计算 viewport 高度** | 事实✓（审查核对 `etaf-runtime.el` 与 `etaf-ui.el` 源码） |
| A4 | `]` / `[` 键位可直接删除（无其他语义复用） | 事实✓（全仓仅绑定为翻页） |
| A5 | `seshat-reader-annotation-page-size` 删除属破坏性变更（用户配置引用会失效），需在 CHANGELOG 标注 | 事实✓ |
| A6 | 批注位置解析函数 `--page-from-location` 与列表分页无关，必须保留 | 事实✓（reference/etaf 均依赖） |

## 设计

### D1 删除批注层分页（`seshat-reader-annotation.el`）

删除：
- defcustom `seshat-reader-annotation-page-size`
- buffer-local `seshat-reader-annotation-list-page`
- `seshat-reader-annotation--page-count` / `--clamp-page` / `--page-items`
- 4 个翻页命令（`seshat-reader-annotation-list-next-page` / `-prev-page` / `-first-page` / `-last-page`）
- 翻页辅助 `seshat-reader-annotation--set-list-page` 与 `seshat-reader-annotation--list-items`（翻页命令与 etaf 的跨页选中删除后成死代码）
- `seshat-reader-annotation-list-mode-map` 中的 `]` / `[` 绑定
- `--render-list` / `--render-list-etaf` 的 `page` / `page-count` 参数
- 纯文本渲染的页脚行 `-- 第 x/y 页 --` 及其「多页才显示」逻辑

保留（**不要误删**）：
- `seshat-reader-annotation--page-from-location`（批注**位置页码**，与列表分页无关）
- `seshat-reader-annotation--all-items`（保留为全量条目合并入口，**docstring 需去掉「分页的唯一条目来源」等过时表述**）
- 本地待同步项标记 `[待同步]`、`RET`/`d`/`C-c C-r` 绑定

`--render-list` 改为：全量条目一次性渲染，无页脚；空列表仍渲染一行提示。

### D2 ETAF 渲染层去分页（`seshat-reader-etaf.el`）

删除：
- `seshat-reader-etaf--page` / `seshat-reader-etaf--page-count` 两个 ref
- `seshat-reader-etaf--current-page`、`--page-of-index`、`--sync-page-with-selection`
- `--badge-text` 的多页分支（改为始终 `(format "%d 条" ...)`）
- `seshat-reader-etaf--annotation-keys` 中的 `]` / `[` 两项
- `seshat-reader-etaf-render-annotations` 的 `page` / `page-count` 可选参数
- `seshat-reader-etaf-annotation-next` / `-prev` 中的切页调用（保留移动选中 + 滚动到选中）
- 卡片列表容器的 `:height '(lh 12)` 与 `:overflow 'scroll`

改动：
- 卡片列表改为渲染**全量**条目（不再经 `--page-items` 切片）
- 删除容器固定 `:height '(lh 12)` 与 `:overflow 'scroll`
- **显式计算内容高度并传给 ETAF**：按条目数估算内容行数（每条卡片行高 × 条目数 + 标题栏/文档名/底部提示的 chrome 行数），经 `etaf-mount` 的 `:viewport-height`（或 `etaf-runtime-refit` 的 height 参数）设置根 viewport 高度，使 ebox 写入全部行；面板窗口再靠**窗口滚动**查看超出部分
- 视图 docstring 与注释去掉「分页 / 当页 / 跨页」表述

回退（L3 实测窗口滚动不可用时）：viewport 高度取面板窗口实际高度（`window-body-height` 换算为行），保留 canvas 内 `:overflow 'scroll`；**不得**恢复固定 12 行切片。

### D3 面板高度与滚动

批注列表面板高度仍由 `seshat-reader-sidebar-height`（0.35）决定（per-kind 记忆不变）；列表超出时由**窗口滚动**查看。不把批注面板纳入 `--fit-height-for-content` 的自适应（该逻辑仍只对 `translate` 生效）。

### D4 破坏性变更说明

- `seshat-reader-annotation-page-size` 删除；用户配置中引用该变量的 `setq` 不会报错（Emacs 允许未定义变量），但不再生效
- `]` / `[` 不再绑定翻页命令
- 徽章由「第 x/y 页」变为「N 条」

## 任务

- [x] T1：删除批注层分页（`emacs/seshat-reader/seshat-reader-annotation.el`）
  - 按 D1 删除 defcustom、buffer-local、3 个分页函数、4 个翻页命令、`]`/`[` 绑定、页脚、page/page-count 参数
  - `--render-list` 全量渲染；保留 `--page-from-location`
  - 验收：`grep -n "page-size\|--page-count\|--page-items\|--clamp-page\|set-list-page\|list-items\|next-page\|prev-page" seshat-reader-annotation.el` 应为 0 命中（`--page-from-location` 与位置页码相关项除外）（依赖：无）
- [x] T2：ETAF 渲染层去分页与去固定高度（`emacs/seshat-reader/seshat-reader-etaf.el`）
  - 按 D2 删除 page refs、`--badge-text` 多页分支、`--page-of-index`/`--sync-page-with-selection`、`:keys` 两项、render 参数
  - 卡片列表渲染全量、去掉 `:height '(lh 12)` 与 `:overflow 'scroll`
  - 验收：`--badge-text` 恒为「N 条」；30 条条目全部出现在面板文本中（说明 viewport 高度已按内容放大）；`]`/`[` 不在 `:keys` 表；`grep -n "seshat-reader-etaf--page\|--page-of-index\|--sync-page-with-selection" 应为 0 命中（依赖：T1 的渲染入口签名）
- [x] T3：更新与新增测试
  - `seshat-reader-annotation-test.el`：删除 **7 个**分页用例（`--page-count-boundaries` / `--page-items-slices-and-clamps` / `--clamp-page-range` / `--list-mode-paging-keys` / `--paging-commands-clamp` / `--plain-text-paging-renders-page` / `--delete-on-last-page-converges`）；**保留** `--all-items-matches-etaf-items`（验证 `--all-items` 与 `--etaf-items` 合并一致，与分页无关）；新增「21 条全部渲染且无页脚」「`]`/`[` 未绑定翻页命令」
  - `seshat-reader-etaf-test.el`：删除 6 个分页用例（page/count ref 写入、徽章多页、当页切片、按键、跨页选中）；新增「徽章恒为 N 条」「30 条全部渲染」「`:keys` 无 `]`/`[`」
  - 更新所有调用 `--render-annotations` / `--render-list` 的测试实参（去掉 page/page-count）
  - 验收：annotation 与 etaf 两套件 `unexpected = 0`（依赖：T1、T2）
- [x] T4：文档同步
  - `docs/configuration.md`：删除 `seshat-reader-annotation-page-size` 行；「分页」段改为「全量单列连续展示，面板窗口滚动」；ETAF 职责描述去掉「分页」
  - `docs/architecture.md`：删除「分页状态」段；数据流去掉「分页切片」；ETAF 职责去掉「分页」；**`:keys` 列表（约第 86 行）移除 `]` / `[` 两项**；补一句「全量连续渲染 + 按内容显式设置 viewport 高度」
  - `CHANGELOG.md`：`[Unreleased]` 的「变更」或「破坏性」新增一条（删除 page-size、`]`/`[`、分页；批注列表改单列连续流）
  - `docs/llm.md`：无需改动（核对后确认）
  - 验收：`grep -rn "annotation-page-size\|第 x/y 页" docs/` 无输出；CHANGELOG 历史条目零改写（依赖：T1、T2）
- [x] T5：OpenSpec 与验证收尾
  - `openspec/decisions.md` 追加决策（`## 2026-10-18 · 批注列表去分页改单列连续流` + 决策/理由/代价）
  - `openspec/tech-debt.md` 追加一条：批注列表全量渲染无虚拟化，条目极多时首次渲染成本线性增长（可选优化：按需渲染/懒加载）
  - `openspec/active/roadmap.md` M11 表追加 `M11.13` 行
  - L1：`check-parens`（2 源 + 2 测试，emacs-lisp-mode）、`batch-byte-compile` 零新增 warning、checkdoc 零新增告警
  - L2：annotation / etaf / sidebar / translate 四套件 ERT 全绿
  - 勾选 T1–T5、更新「## 当前状态」
  - 验收：四套件 unexpected 全为 0（依赖：T1–T4）

依赖关系：T1 → T2 → T3；T1/T2 → T4；T1–T4 → T5。

## 文档清单

| 文档 | 是否需要更新 | 理由 |
|---|---|---|
| `docs/configuration.md` | 是 | 删除 page-size 配置项与分页描述 |
| `docs/architecture.md` | 是 | 删除分页状态与切片数据流，补连续渲染 |
| `CHANGELOG.md` | 是 | 破坏性变更 + 行为变更 |
| `openspec/decisions.md` | 是 | 去分页决策（含代价） |
| `openspec/tech-debt.md` | 是 | 全量渲染无虚拟化 |
| `openspec/active/roadmap.md` | 是 | M11.13 行 |
| `docs/llm.md` | 否 | 不涉及 LLM 接入描述（核对确认） |
| `emacs/seshat-reader/VENDORED.md` | 否 | 职责描述未变化 |

## 验证标准

- **L1**：2 个源 `.el` + 2 个测试 `.el` check-parens 通过（emacs-lisp-mode）；byte-compile 零新增 warning；checkdoc 零新增告警
- **L2**：四套件 ERT 全绿（annotation / etaf / sidebar / translate），unexpected 全 0
- **L3**：在运行中 Emacs 打开含 30+ 条批注的列表，确认全部条目连续可见、无页脚、徽章为「N 条」、`n`/`p` 可一直移动到末条（不切页）、`]`/`[` 无绑定

## 注意事项

- **`--page-from-location` 必须保留**：它是批注**位置**（PDF 页码）解析，与列表分页无关；`seshat-reader-reference` 与 ETAF 卡片页码徽章都依赖它。
- **ETAF 自然高度风险**：M11.10 的记忆指出 ETAF 对固定 viewport 敏感；去掉 `:height` 后必须实测（L3），若布局异常按 D2 的回退方案处理，但**不得**恢复 12 行切片。
- **面板滚动**：列表超出面板高度时依赖窗口滚动；确认 `seshat-reader-sidebar-select-window` 与 `q` 关闭不受影响。
- **测试实参**：`--render-annotations` 与 `--render-list` 的 page/page-count 参数删除后，所有调用点（含 sidebar-test 的 `--render-panel` 无关）需同步；用 `grep` 全仓核对。
- **破坏性变更**：CHANGELOG 必须标注，避免用户误以为 page-size 仍生效。
- **不做虚拟化**：本次只做连续渲染，条目极多的性能问题记 tech-debt，不在本轮实现懒加载。
- **viewport 高度是本次核心**：仅删除容器 `:height` 不会让内容显示更多行——必须显式设置 `etaf-mount` 的 `:viewport-height`（内容高度），否则超出部分被固定 viewport 裁掉。L3 必须验证「30+ 条全部可见 + 窗口可滚动到末条」。
