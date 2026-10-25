# 阅读器文本搜索与手写轨迹显示

## 当前状态
- 阶段：Phase 3 · 已完成
- 已确认：方案 ✅（用户 2026-10-25 确认需求矩阵：文本版需搜索，两端需显示手写轨迹）
- 计划 ✅（用户 2026-10-25 确认）
- 前置：依赖 `reader-decoration-and-text-highlight` 的 T3（装饰表：rect + stroke + 颜色）——已具备
- 下一步：归档 `completed/`，进入 Phase 4 审查

## 目标

补齐第一批计划未覆盖的三条需求：① 文本型 PDF 的**文本搜索**；② Emacs 端**显示** Android 手写轨迹（不输入）；③ 手写**存储策略落地**（侧车为主 + 可选导出 PDF 副本）。同时明确扫描版与 OCR 的边界。

### 不在本计划范围

- 手写**输入**：Emacs 无笔事件/压感，只做显示；输入在 Android。
- OCR：本期不做，记 tech-debt（识别出文本层后即可复用文本版全部能力）。
- 扫描版：仅位置书签 + 手写（现状已覆盖，本计划只补文档）。

## 设计

### 文本搜索
- C 侧新增 `seshat-reader-dyn--search-page(page needle limit)`，内部用 MuPDF 的 `fz_search_page`（返回命中 quad 数组），不重建文本索引。
- Lisp 侧实现跨页搜索：当前页向后搜 → 未命中则翻页 → 到文末停止并回绕提示；命中项以装饰表 rect 投喂（专用颜色，与批注高亮区分）。
- 交互：绑定 `C-s` 于 `seshat-reader-mode-map`（该前缀当前未被占用，需在执行时复核），输入走 `read-string` 或接 `isearch-mode-hook`；执行时优先做「minibuffer 输入 + n/p 跳转」的最小可用版本，isearch 集成作为可选增强。
- 页内命中计数与当前序号显示在 echo area。

### 手写轨迹显示
- `ink:` 段格式（已定稿，见 `docs/api.md` §4.5.1）：`page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`，一笔一条批注。
- Lisp 解析：`#AARRGGBB` → RGB 三元组、线宽 pt、点列（页面 pt 坐标）；空点列/降级形态（只有 color+width）解析为「无几何」，仅计数不渲染。
- 投喂：调用 decoration 计划引入的 stroke 入口（`--add-stroke` 或等价），圆头圆角。
- **坐标方向必须实测**：Android 屏幕坐标 y 向下，MuPDF page space 与现有 rect 高亮的对齐口径需对照验证；若方向相反，在 Lisp 侧翻转 y（或 C 侧统一）。

### 手写存储策略（已确认：侧车为主）
- 真身：Android `PdfInkStore`（本地 JSON，渲染唯一真相）；同步投影：`kind=ink` 批注（一笔一条）。
- 新增可选能力：**导出到 PDF 副本**——Android 端把笔迹与高亮写入 `xxx.seshat.pdf`（MuPDF/PdfBox 的 ink annotation），保留原文件不动。通用阅读器可见。
- Emacs 端不实现写 PDF（只显示与同步侧车）。

## 任务

- [x] **T1 C 侧搜索函数**：新增 `seshat-reader-dyn--search-page(page needle limit)`，用 `fz_search_page` 取命中 quad 并转为 rect 列表返回；无命中返回 nil；页越界/无文本层给出与既有函数一致的处理。（依赖：decoration T3；验收：对含已知单词的页面返回非空且命中数与外部工具（如 `mutool draw -F stext`/`pdftotext`）一致；空串/超长 needle 有界处理）
  （执行记录：`emacs_search_page` + `search_needle_is_blank`；命中 quad 经 `fz_rect_from_quad` 转 rect，与 `--text-in-rect` 共享同一条 `rect_to_page_space`，故命中矩形可直接投给装饰入口；单页收集上限 `SEARCH_PAGE_MAX_QUADS` = 1024，`limit` 另夹到 1..10000（nil / 0 / 非数按 1000）；页号 **1-based**（`resolve_page_arg`）；空 needle 与无文本层静默返回 nil，只有页越界发消息。）

- [x] **T2 Emacs 搜索交互**：新增 `seshat-reader-search`（`C-s`）、`seshat-reader-search-next` / `-prev`（`n`/`p`）；跨页循环与回绕提示；命中项以专用颜色投喂装饰表；echo area 显示「第 i/N 个命中 · 第 p 页」。（依赖：T1；验收：ERT 用假 `--search-page` 桩点覆盖「同页多命中 / 跨页 / 到末尾回绕 / 无命中」四种情形；隔离实例实测三页文档可连续跳转）
  （执行记录：`seshat-reader-search.el` ~560 行 + 17 例；`C-s` 搜索 / transient-map 的 n/p/RET/C-g；`--search-page` 整本扫描 797 页 1.1s；装饰共存经 `seshat-reader-annotation-extra-decorations-function` 钩子；1024 单页与 20000 总量双上限提示；L3 三态 sha256 互异且 C-g 后复原。已完成接线：thomas-emacs `init-reader.el` 增加 `(require 'seshat-reader-search nil t)`。）

- [x] **T3 ink location 解析（纯 Lisp）**：新增 `seshat-reader-annotation--ink-strokes-from-location`，解析 `page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...` 为 `((color-rgb width points page) ...)`；非法输入（非数字、点数不成对、颜色格式错）逐项跳过而不是整体失败。（依赖：无；验收：ERT 覆盖正常 / 降级形态（无点列）/ 颜色格式错 / 点数不成对 / 超长串截断五种情形）
  （执行记录：`--ink-strokes-from-location` + `--ink-stroke-from-segment` + `--ink-color-from-hex` + `--ink-coordinate`；颜色只认恰好 8 位 `#AARRGGBB`；`--ink-max-points` 1024 超限**截断并置 TRUNCATED**（不丢整笔）；无几何的降级形态返回 nil；`seshat-reader-annotation-ink-test.el` 24 例覆盖解析与投喂（含「ink 与 rect 同时投喂」「ink 非法不影响 rect」）。）

- [x] **T4 坐标方向对照实验**：用一条已知笔迹（同一页同一形状）分别在 Android 与 Emacs 渲染，比对 y 方向与缩放；记录结论（一致 / 需翻转 / 需缩放）到计划执行报告与 `docs/emacs-reader.md`。（依赖：T3；验收：结论明确且有截图或数值证据；若需翻转，在 T5 中实现并加 ERT 用例）
  （执行记录：数值验证同向无需 y 翻转——ink 线差异行中心 80.0 vs highlight 行中心 80.0，PNM 612×792、1px=1pt；实现未加翻转。）

- [x] **T5 ink 投喂渲染**：`--redraw-highlights` 系列扩展为同时投喂批注 rect 与 ink stroke（顺序与失败隔离沿用现有约定）；`seshat-reader-annotation-highlight-enabled` 语义扩展为「是否渲染标注装饰」，或新增独立开关 `seshat-reader-annotation-ink-enabled`（执行时二选一并说明理由）。（依赖：T3、T4、decoration T3；验收：隔离实例打开含手写批注的文档可见笔迹；ERT 覆盖「ink 与 rect 同时投喂」「ink 解析失败不影响 rect」）
  （执行记录：`ink-enabled` 默认 t；`--annotation-strokes` / `--cached-entries`（统一跨文档过滤）/ `--feed-stroke`；投喂顺序 clear→批注→闪现→搜索命中→ink→refresh；返回值仍只计批注 rect；ERT +8（文件 24 例）；页号基数经核对统一为 1-based。）

- [x] **T6 手写导出 PDF 副本（Android）**：新增「导出到 `.seshat.pdf` 副本」入口，把 `PdfInkStore` 笔迹与 `kind=highlight` 的 rect 写成标准 PDF annotation；原文件只读不动；导出失败给出可读错误。（依赖：无（Android 侧独立）；验收：JVM 单测覆盖导出路径构造与降级（无笔迹时不生成文件）；真机验收标注「待真机」）
  （执行记录：`reader/PdfInkExporter` + `PdfReaderActivity.exportInkCopy`（溢出菜单「导出手写副本」）；`/Subtype /Ink`（`/Rect` `/C` `/CA` `/F` `/BS` `/InkList`）+ `PDInkAppearanceHandler` 生成 `/AP`，`/Highlight` + `/QuadPoints` + `PDHighlightAppearanceHandler` 生成 `/AP`；命名 `<base>.seshat.pdf` 并以 `-1`/`-2` 去重、先写 `.part` 再 `renameTo`；源文件只读、旋转页跳过（回报页数）、`content://` 拒绝、无内容不建文件；JVM `PdfInkExporterTest`；真机 5 项待验收见「执行记录 ⑥」。）

- [x] **T7 文档与边界声明**：`docs/emacs-reader.md`（搜索用法、ink 显示、坐标口径）、`docs/api.md`（搜索不涉契约，补 ink 显示说明）、`docs/android.md`（导出手写副本）、`docs/architecture.md`（搜索/装饰流程）、`CHANGELOG.md`、`openspec/tech-debt.md`（OCR 不做、扫描版边界、旋转页、ink 一笔一行导致批注表膨胀）。（依赖：T1–T6；验收：文档与代码一致）
  （执行记录：`docs/emacs-reader.md`（搜索用法 / ink 显示 / 坐标口径 / 键位表 / 配置表 / 已知限制 / 模块与套件清单）、`docs/android.md`（§6.9 导出手写副本）、`docs/api.md`（§4.5 与 §4.5.1 的 ink 表述全部改写为「已渲染」）、`docs/architecture.md`（新增「搜索与 ink 渲染流程」节 + 入口清单 + 防御上限两行）、`docs/configuration.md`（补 `ink-enabled` 与 4 个搜索 defcustom）、`CHANGELOG.md`、`openspec/decisions.md`（新增「C 侧页号基数约定」）、`openspec/tech-debt.md`（追加导出去向 / `content://` / 旋转页 / 基数并存 4 条）。）

## 文档清单

`docs/emacs-reader.md`、`docs/android.md`、`docs/api.md`、`docs/architecture.md`、`CHANGELOG.md`、`openspec/tech-debt.md`、`openspec/decisions.md`（若搜索/ink 渲染引入新决策）。

## 验证标准

- L1：`make check-parens`；`make -C emacs/seshat-reader clean all` 无警告。
- L2：ERT 全量（含新增解析/搜索用例）；`./gradlew test`（Android 导出用例）。
- L3：`verify` 隔离实例——`elisp_mcp_set_task(task=verify)` → `elisp_mcp_instance(action=start, instance=verify)` → 轮询 `elisp_mcp_instance_status(instance=verify)` 的 `alive`（5–10 次 × 1s）→ 实测搜索跳转与笔迹渲染；收尾三步：`set_task auto` → `instance(action=stop)` → `instance_status` 确认。Android 导出走真机（无设备则标注待验收）。

## 注意事项

- 手写输入永不进 Emacs（无笔事件），只显示；不要为「输入」写 elisp 交互。
- ink 一笔一条批注会让列表接口数据量膨胀（既知 tech-debt），本计划不改变存储粒度。
- 搜索必须对「无文本层的扫描页」优雅退化为「本页无结果」，不得报错。
- 导出 PDF 副本必须是**新文件**，绝不修改原 PDF（WebDAV 同步与签名 PDF 风险）。

## 执行记录

### ① 批次分工（7 批，串行）

| 批次 | 范围 | 产出 |
|---|---|---|
| C1 | C 侧搜索 | `--search-page`（`fz_search_page` → `fz_rect_from_quad` → 与 `--text-in-rect` 同一 `rect_to_page_space`）；`SEARCH_PAGE_MAX_QUADS = 1024`；空 needle / 无文本层静默返回 nil |
| C2a | 搜索 UI | `seshat-reader-search.el`（约 560 行）+ 17 例 ERT；`C-s` + transient-map（`n` / `p` / `RET` / `C-g`）；按页缓存、跨页回绕、双上限提示、`--extra-decorations-function` 共存钩子 |
| C2b1 | ink 解析（纯 Lisp） | `--ink-strokes-from-location` / `--ink-stroke-from-segment` / `--ink-color-from-hex` / `--ink-coordinate`；整笔跳过判据与 1024 点截断 |
| C2b2 | ink 渲染 + 坐标验证 | `ink-enabled` 开关、`--annotation-strokes` / `--cached-entries` / `--feed-stroke`；投喂顺序 clear → 批注 → 闪现 → 搜索命中 → ink → refresh；T4 坐标实验 |
| — | 页号基数核对 | 逐入口核对基数，`--search-page` 由 0-based 改为 1-based；Lisp 侧去掉 `(1- page)`；桩与断言同步 |
| C3a | Android 导出 | `PdfInkExporter`（`/Ink` + `/AP`、`/Highlight` + `/QuadPoints` + `/AP`、`.seshat.pdf` 去重、`.part` 原子改名、旋转页跳过、`content://` 拒绝）+ JVM 单测 |
| C3b | 文档与接线（本批） | `docs/emacs-reader.md` / `docs/android.md` / `docs/api.md` / `docs/architecture.md` / `docs/configuration.md` / `CHANGELOG.md` / `openspec/decisions.md` / `openspec/tech-debt.md`；thomas-emacs `init-reader.el` 接线 + 仓库侧 CHANGELOG |

### ② 关键实测

- **整本扫描 797 页 1.1 秒**（`--search-page` 逐页，不重建文本索引）；结果按页缓存，跳转不重扫。
- **单测文档 225 命中**：小文档搜索命中数 225，跨页跳转与回绕索引一致。
- **三态 sha256 互异**：进入搜索（有命中装饰）/ 跳转到另一命中 / `C-g` 复原，三次页面 PNM 的 sha256 两两不同 → 装饰确实改变且能复原（验证时按 tech-debt「`--refresh-highlights` 一步错位」的可靠做法：refresh → 等待 → refresh 再取图）。
- **ink 差异行中心 80.0 vs 80.0**：同一页同一形状，ink 笔迹与 highlight 矩形的差异行中心均为 80.0（PNM `612×792`，该分辨率下 1px = 1pt）→ 同向、**无需 y 翻转**。
- **导出的 annotation 路径与 mutool 渲染验证**：导出副本经 `mutool` 解析确认 `/Subtype /Ink`（含 `/InkList`）与 `/Subtype /Highlight`（含 `/QuadPoints`）均带 `/AP` 外观流，且 `mutool draw` 渲染出的页面上笔迹与高亮位置正确。

### ③ 三处纠错（实现相对计划的偏差）

1. **`--search-page` 页号基数 0-based → 1-based**：初版与装饰入口（1-based）相反，跨页搜索整体错一页（Lisp 侧 `(1- page)` 掩盖）；现统一走 `resolve_page_arg`，Lisp 侧去掉换算。`--text-in-rect` / `--rects-in-rect` 保持 0-based（选区代码在页索引空间工作），**两套基数并存**，每个按页入口在注释首段显式声明基数。已记 `openspec/decisions.md` 与 `openspec/tech-debt.md`。
2. **`--add-stroke` 的页号是 1-based**：装饰表计划里未写明该入口的基数，实现时按「与 `--add-highlight` / `--add-decoration` 一致」定为 1-based 并在注册注释里写明，ink 投喂按此传 1-based 页号。
3. **T4 无需 y 翻转**：计划假设「Android y 向下、MuPDF 可能相反，必要时翻转」，实测同向（差异行中心均 80.0）→ 解析层不加翻转，保持与 `location` 契约逐字对应。**代价**：该结论只有数值证据，Android 真机肉眼对照仍待做（见 ⑥）。

### ④ 验证数字

- **ERT：765 例**（23 个测试文件逐文件求和，0 unexpected / 0 skipped；新增 `seshat-reader-search-test.el` 17 例、`seshat-reader-annotation-ink-test.el` 24 例、`seshat-reader-annotation-decoration-test.el` 21 例、`seshat-reader-select-merge-test.el` 12 例）。
- **Go：13 包全 PASS**（`go test ./...`，本轮服务端零改动，纯回归）。
- **JVM：954 tests**（`./gradlew test`，含 `PdfInkExporterTest`）。
- **lint**：`make -C emacs/seshat-reader clean all` 构建成功（warning 与基线持平）、checkdoc 0 报错；thomas-emacs 侧 `make check-parens` 全通过。

### ⑤ 回滚点

- **C 侧基线 tag `pre-reader-decoration`** → `bc2d038`（2026-10-24 23:58，装饰表改造前的提交），本计划全部改动都在该 tag 之后、且**均未 commit**。
- **各批 `git stash create` 安全点**：`git stash create` 只产生**悬空 commit**、不落引用，本轮各批的 hash 未持久化，`git fsck` 现在只能看到其中一个（`45836b1`，2026-10-25 01:49，术语批次的安全点，含本计划开始前的工作区状态）。**因此逐批回滚不可复核**，实际可用的回滚手段是：① `git checkout -- <file>` / `git stash` 退回 `bc2d038`（= 本计划全部改动一起撤销，未提交故无丢失风险）；② 单文件回退用 `git diff bc2d038 -- <file>` 查看并手工回退。
- **教训**：`git stash create` 的 hash 必须写进计划文件或 decisions，否则 GC 后无法找回——后续批次应改用 `git stash create` + 立刻 `git update-ref refs/safety/<batch> <hash>`。

### ⑥ 待真机项（Android，无 AVD / 设备）

1. 导出副本 `xxx.seshat.pdf` 在**第三方阅读器**（系统 PDF 查看器 / 桌面阅读器）里笔迹与高亮是否可见、位置是否一致（`/AP` 已显式生成，仍需端上确认）。
2. 导出后 toast 文案的实际观感：「已导出 X」/「已导出 X（N 页未导出）」/「没有手写或高亮，无需导出」/「仅本地文件可导出副本」。
3. 导出副本落在书库目录后，书架是否真的把它当**新书**显示（对应 tech-debt 的待产品决策：是否改导出到「下载」目录）。
4. Emacs 端 ink 笔迹与 Android 端同一形状的**肉眼对照**（数值已验证同向，真机仍需看一眼确认缩放/线宽观感）。
5. 旋转页（`/Rotate ≠ 0`）导出跳过的行为在真实旋转页文档上的提示与「全部页被跳过 → 不产出空副本」路径。
