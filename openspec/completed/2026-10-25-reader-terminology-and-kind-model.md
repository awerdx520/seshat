# 阅读器术语定案与 kind 两维语义修正

## 当前状态
- 阶段：Phase 3（Implement）· 已完成；计划 ✅（用户 2026-10-25 确认）；下一步：归档 completed/，进入计划 B
- 已确认：方案 ✅（用户 2026-10-25 确认「按行业模型修正两维语义」，选项 A）
- 姊妹计划：`reader-decoration-and-text-highlight`（装饰通道与字级高亮，**串行在本计划之后**）、`reader-search-and-ink`（文本搜索 / ink 显示 / 手写存储，后续批次）
- 独立审查：✅ 已审查（2026-10-25），阻塞项已修订

## 目标

按行业惯例统一阅读器术语，并修正三端数据模型的归类错误：`kind` 只表示标注**类型**，「有无备注」由 `text` 空/非空表达。本计划**不含 C 渲染层改动**（渲染通道与字级高亮见姊妹计划 `reader-decoration-and-text-highlight`）。

### 术语定案（行业基准）

| 概念 | 定名 | 载体 |
|---|---|---|
| 总称 | 批注 / 标注（annotation） | `kind` 字段、`seshat-reader-annotation.el` |
| 子类型 | 高亮 `highlight` / 下划线 `underline` / 删除线 `strikeout` / 便签 `note` / 手写 `ink` | `kind` + `location` 几何 |
| 位置标记 | 书签（bookmark） | `PdfBookmark`、`seshat-reader-bookmark.el` |
| 文档结构 | 目录 / 大纲（outline / TOC） | `PdfOutlineReader`、`seshat-reader-outline.el` |
| 断点 | 阅读进度（reading progress） | `reading_progress` / saveplace |

## 设计

### 数据模型（两维正交）

| 维度 | 载体 | 语义 |
|---|---|---|
| 类型 | `kind` ∈ `highlight` / `underline` / `strikeout` / `note` / `ink` | **只表类型**，与「有无备注」正交 |
| 几何 | `location` 的 `rect:` 段（可选、可多段） | 内容位置几何，仅渲染用 |
| 页锚 | `location` 的 `page:` 段 | 跳转用，唯一导航真值 |
| 备注 | `text` | 可空；`note` 必填 |
| 选中原文 | `selected_text` | 标记类（highlight / underline / strikeout）存 |
| 手写 | `location` 的 `ink:` 段 | 一笔一条 |

规则：选中页面文本 → `kind=highlight` + `selected_text` + `text=""`；加备注时 `kind` **不变**，只写 `text`；纯页级备注 → `kind=note` + `text`。

### 兼容与不可改契约

- 存量 `note` 一律不迁移：无法可靠判定哪些旧 note 实际是高亮（Emacs 旧记录有 `rect:` 但 kind=note，Android 旧 note 无几何）。记 tech-debt。
- 幂等键 `(uid, kind, location, text)` 不变；同一位置「旧 note」与「新 highlight」会成为两条独立记录，可接受。
- **禁止改动**：REST 路径 `/api/annotations`、JSON 字段名、已存 `kind` 字面量、`location` 三种串格式（`page:<n>` / `page:<n>;rect:...` / `page:<n>;ink:...` / `chapter:<i>@<s>-<e>`）、Android SharedPreferences 键前缀（`pdf_bookmark_` / `pdf_annotations_` / `pdf_ink_` / `pdf_progress_` / `reading_progress` / `pending_deletes_`）、进度 `position` 编码、`seshat:` 链接协议、Emacs 文本属性名、buffer 名 `*Seshat Annotations*`、bookmark 记录形状与 handler 名。

### 审计结论（本计划修正的具体错误）

| 编号 | 错误 | 位置 |
|---|---|---|
| E1 | Emacs 建标注不发 `kind`，服务端兜底 `note` → 跨端永远进不了「高亮」组 | `seshat-reader-annotation.el:336` → `internal/storage/state.go:150` |
| E3 | Android「高亮标注」菜单实际产 `kind=note` 且无几何 | `strings.xml:244` → `PdfReaderActivity.kt:974` |
| E5 | Android 注释把 outline 通篇称「书签」 | `PdfOutlineReader.kt:16,36,59,83,104,164,190,222,242` |
| E6 | `TocDrawer` 名义目录、实为「目录+书签」；状态行混页码与书签数 | `TocDrawer.kt:159-163,409-411`、`strings.xml:209` |
| E7 | 测试夹具与 decisions 把 `bookmark` 当 `kind` 取值 | `state_v8_test.go:187`、`annotations_v8_test.go:78`、`AnnotationGroupingTest.kt:204`、`openspec/decisions.md:365` |
| E8 | 分组文案内部漂移（批注/备注/标注/列表混用） | `AnnotationGrouping.kt:110-119`、`AnnotationDrawer.kt:89,208,407` |
| E9 | EPUB 渲染「点顶栏书签图标」但 EPUB 无书签入口 | `TocDrawer.kt:411`、`EpubReaderActivity.kt:1219-1227` |
| E10 | `kind` 同时编码「类型」与「有无备注」，两端不一致 | `EpubReaderActivity.kt:1549-1554`（改 kind）vs `PdfReaderActivity.kt:1106-1116`（不改） |

## 任务

- [x] **T1 决策落档**：在 `openspec/decisions.md` 末尾新增两条 `## 2026-10-25 · 标题`（格式对齐现有条目：决策 / 理由 / 代价与约束 / 影响）：①「阅读器术语定案（annotation vs bookmark vs outline）」；②「`kind` 改为单维类型 + 备注由 `text` 表达」。内容以上文「术语定案」「数据模型」「兼容与不可改契约」为准。（依赖：无；验收：两条例目存在，含「存量不迁移」与「幂等键不变」两条约束）

- [x] **T2 Android 文案与注释纠名**：（a）`strings.xml` 的 `pdf_menu_highlight`（「高亮标注」）改为「添加本页备注」；（b）`PdfOutlineReader.kt` 全部注释中的「书签」改为「目录/大纲」（**类名不改**）；（c）`TocDrawer` 状态行拆键：`pdf_toc_status` 只保留「第 %1$d/%2$d 页」，新增 `pdf_bookmark_count`（「%1$d 个书签」）；（d）`AnnotationGrouping.kt` 分组标题统一为「便签 / 高亮 / 手写 / 其它」；（e）入口与对话框文案统一「批注」，`AnnotationDrawer.kt` 的「编辑备注」改「编辑便签」。（依赖：无；验收：`grep -r "高亮标注" android/` 零命中；`grep -rn "书签" android/app/src/main/java/com/seshat/app/reader/PdfOutlineReader.kt` 零命中；ktlint 通过）

- [x] **T3 消除 EPUB 错误指引**：`TocDrawer.kt` 在 `bookmarks` 为空且 EPUB（无书签入口）时不渲染「阅读时点顶栏的书签图标可添加」提示。（依赖：无；验收：`EpubReaderActivity` 传 `bookmarks = emptyList()` 的路径下该文案不可达；单测覆盖 `TocDrawer` 提示可见性纯函数分支）

- [x] **T4 清理 `bookmark` 误作 kind**：`internal/storage/state_v8_test.go:187`、`internal/api/annotations_v8_test.go:78`、`android/.../AnnotationGroupingTest.kt:204,223` 的 `"bookmark"` 改为 `"underline"`；`openspec/decisions.md:365` 的「未来可能有 `bookmark` / `underline`」改为「未来可能有 `underline` / `strikeout`（bookmark 是位置而非标注，永不进入 annotations）」。（依赖：无；验收：`go test ./internal/...` 全绿；`./gradlew test` 相关用例全绿）

- [x] **T5 Emacs 命名与文档措辞**：（a）`seshat-reader-annotation--location` 改名为 `--anchor`，全部调用点同步，docstring 写明「页锚 + 可选几何尾段」；（b）`seshat-reader-reference.el` 中复用位置的函数注释改称「引用锚」并声明「本模块的 rect 不产生任何渲染」；（c）`seshat-reader-sidebar.el` docstring 首句明确「outline = 导航，annotations = 标注」。（TDD：先写失败用例，RED 后再实现）（依赖：无；验收：`make check-parens` 通过；ERT 全绿；`grep -rn "seshat-reader-annotation--location" emacs/` 零命中）

- [x] **T6 Emacs 发 `kind=highlight` + `selected_text`**：（a）`seshat-rest.el` 的 `seshat-rest-create-annotation` 增可选参数 `kind`、`selected-text`，序列化进 payload；（b）`seshat-reader-annotation-create`：无备注时发 `kind=highlight` + `selected_text`=选区文本 + `text=""`；`C-u` 输入备注时发 `kind=note` + `text`=备注 + `selected_text`=选区文本；（c）离线队列条目（`annotation-queue.el` 的 create entry）新增 `:kind` / `:selected-text` 字段——注意客户端去重键**已经**是 `(kind, location, text)`（`annotation-queue.el:272-294,349-350`），**不要改去重逻辑**，只需让 entry 携带这两个字段；（d）`--display-text` 回退链保持「text → selected_text → ink 聚合」不变。（c2）**核查并更新测试桩点**：`seshat-reader-annotation-v8-test.el:257/274/289` 与 `seshat-reader-translate-test.el:929` 的 `(lambda (uid location text))` 桩点只接受 3 个参数，create 改为 5 参数后会 `wrong-number-of-arguments`——须补可选形参或 `&rest`；（d2）**核查 Emacs 侧编辑备注路径**：若存在调用 `seshat-rest-update-annotation`（`seshat-rest.el:182`）的入口，PUT 必须显式携带原 `kind`（服务端 `UpdateAnnotationAt` 会把空 kind 兜底为 `note`，否则「高亮加备注」会被降级成 note）；若本期无编辑入口，在计划里明确声明「本期无编辑路径」。（TDD：先写失败用例，RED 后再实现）（依赖：T5；验收：ERT 新增用例——payload 含 `kind`/`selected_text` 断言、离线队列往返、去重键含 kind）

- [x] **T7 EPUB 端 kind 语义对齐**：`EpubReaderActivity.kt` 中「无备注→highlight、有备注→note」的逻辑改为「选中即 `highlight`，加备注不改 `kind`」；编辑备注**保存**时强制改写 `kind = KIND_NOTE` 的分支（`EpubReaderActivity.kt:1392`）；与 PDF 侧「编辑备注不改 kind」行为一致。（TDD：先写失败用例，RED 后再实现）（依赖：无；验收：`AnnotationStoreTest` / `AnnotationGroupingTest` 断言更新，新增用例「加备注后 kind 仍为 highlight」；`./gradlew test` 全绿）

- [x] **T8 文档与变更记录同步**：`docs/api.md`（§4.5 `kind` 语义改为单维类型 + 备注维度说明、§4.5 填充矩阵）、`docs/android.md`（文案、分组、书签/目录纠名）、`docs/emacs-reader.md`（批注类型与回退链）、`CHANGELOG.md`（新增条目）、`openspec/tech-debt.md`（存量 note 不可逆迁移、Android 无 AVD/设备导致 UI 仅人工验收）。（依赖：T1–T7；验收：上述文件变更齐全，`docs/` 中无「高亮标注」误导表述）

## 文档清单

`openspec/decisions.md`、`openspec/tech-debt.md`、`docs/api.md`、`docs/android.md`、`docs/emacs-reader.md`、`docs/architecture.md`（若涉及 location 语义表述）、`docs/configuration.md`（若涉及分组/文案配置）、`CHANGELOG.md`。

## 验证标准

- L1：`make check-parens`（Elisp）、`./gradlew ktlintCheck`（或项目既有 lint 入口）、`gofmt -l` 无输出。
- L2：`make test`（ERT 全量）、`go test ./...`、`./gradlew test`（JVM 单测）全绿。
- L3：Android UI 手工验收（无 AVD/设备时标注「待真机」）；Emacs 侧走 `verify` 隔离实例——`elisp_mcp_set_task(task=verify)` → `elisp_mcp_instance(action=start, instance=verify)` → **轮询 `elisp_mcp_instance_status(instance=verify)` 的 `alive`（5–10 次 × 1s）** → 用真实 PDF 验证「建标注 → 服务端 `kind=highlight`」与列表分组；收尾三步：`set_task auto` → `instance(action=stop)` → `instance_status` 确认。

## 注意事项

- 本计划**零 C 改动**，不需要重建 `seshat-render-core.so`。
- 存量数据只做前向修正，不做迁移脚本；不得因「统一」而重写用户已有批注。
- Android 文案改动涉及硬编码字面量（`AnnotationDrawer.kt`、`AnnotationGrouping.kt`、`TocDrawer.kt`、`PdfReaderActivity.kt`），改文案时须一并处理，避免资源与硬编码两套词。
- Emacs 侧 `VENDORED.md` 声明 `seshat-reader-annotation.el` 等为自研扩展，改名/搬函数时不得改变文件边界声明。
- **复制为既有功能**：`seshat-reader-select-copy-to-kill-ring` + `kill-new`（`seshat-reader-select.el`）已覆盖「框选→复制」，本期不新增任务，仅需在文档中说明。
- **OCR 本期不做**：记入 `openspec/tech-debt.md`，后续计划承接（扫描版识别文本后即可复用文本版的全部能力）。
- **扫描版「只加书签」**：现状已由 `PdfBookmarkStore`（Android）与 `bookmark.el`（Emacs）覆盖，本计划无需新代码，仅在文档中明确「扫描版支持位置书签 + 手写，不支持文本类标注」。

## 执行记录

**批次 1 的两条执行偏差**（已落地部分偏离计划字面之处及理由）：

1. **T2(c) 状态行拼接位置**：计划字面写「`TocDrawer` 状态行拆键」，实现把**拼接动作**放在 `PdfReaderActivity`（`statusLine = getString(R.string.pdf_toc_status, …) + TocDrawerText.STATUS_SEPARATOR + getString(R.string.pdf_bookmark_count, …)`，分隔符常量 `" · "` 定义在 `TocDrawerText` 而非 `TocDrawer`），`TocDrawer` 只接收成品 `statusLine`。理由：`TocDrawer` 的既有架构约束是「视图全部代码构建、**不引用任何 `R.string.`**」（两个阅读器共用同一实现），在抽屉内拼接就要引入 `R.string` 依赖，破坏该约束并让 EPUB 侧被迫提供 PDF 语义的键。代价：状态行文案的事实来源从「抽屉内部」移到「PDF 调用方」，EPUB 侧状态行仍自行拼「第 N 章」。
2. **`seshat-reader-annotation--location-max-length` 刻意保留原名**：T5 只把**函数** `--location` 改为 `--anchor`，守 64 KB 上限的 **defconst 仍叫 `--location-max-length`**。理由：它守的是 **API 字段 `location`**（不是「锚」），且被 `docs/security.md` 与 `openspec/tech-debt.md` 直接引用；跟着函数改名会让「守 location 字段」的语义变模糊。副作用：模块内出现「`--anchor` 函数 + `--location-max-length` 常量」两个词根并存，已在 `docs/api.md` 与本文档注明缘由。

**复审要求的 N6 已在本批次处理**：`docs/api.md` 两处旧函数名（§4.5 三形态表的「纯页号」行、§4.5 的「Emacs 侧文本批注恒产…」引用块）已由 `seshat-reader-annotation--location` 改为 `--anchor`；`grep -rn "seshat-reader-annotation--location" docs/` 现只剩 `docs/security.md` 的 `--location-max-length` 一处（按上条保留）。

**验证实测**（2026-10-25，本机）：

- L1：`make check-parens` 通过；`gofmt -l` 无输出；`./gradlew ktlintCheck` 通过。
- L2：ERT 全量 **686** 例（0 unexpected / 0 skipped）；`go test ./...` **13 包全 PASS**（466 例）；Android `./gradlew test` **940** tests 全绿。
- L3：Emacs 侧在 `verify` 隔离实例内用真实 PDF 验证「建标注 → 服务端 `kind=highlight`」与列表分组通过；Android UI **仅人工验收**（本机无 AVD / 设备，需人工确认的 5 点已记入 `openspec/tech-debt.md`）。

**回滚点**：HEAD `bc2d0385`（一个任务周期共用一个安全点；验证全绿，未回滚）。

