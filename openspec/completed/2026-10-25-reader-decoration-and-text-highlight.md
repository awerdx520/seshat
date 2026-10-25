# 阅读器装饰通道重构与字级文本高亮

## 当前状态
- 阶段：Phase 3 · 已完成；计划 ✅（用户 2026-10-25 确认）
- 下一步：归档 `openspec/completed/`，进入计划 C（`2026-10-25-reader-search-and-ink.md`）
- 前置：**依赖**姊妹计划 `reader-terminology-and-kind-model` 的 T5 先行完成（`seshat-reader-annotation--location` → `--anchor` 改名），本计划 T7 使用新名
- 执行顺序：两份计划**严格串行，禁止并行**——两者都改 `seshat-reader-annotation.el`、`docs/api.md`、`CHANGELOG.md`、`openspec/decisions.md`
- 后续计划：`reader-search-and-ink`（文本搜索 / ink 轨迹显示 / 手写存储导出）
- 独立审查：✅ 已审查（2026-10-25），阻塞项已修订
- 落地：T1–T9 全部完成（三个批次 B1 / B2a / B2b + 收尾补丁），验证与回滚点见「执行记录」

## 目标

把 C 渲染层从「单色纯矩形表」升级为可表达颜色/类型的装饰表（行为等价重构），在此之上实现**字级框选高亮**：框选文本后，高亮贴合文字按行分段，而不是一个大矩形。

## 设计

### 为什么必须改 C 渲染层

`seshat-reader-mode` 每页只显示一个 image overlay，Emacs overlay 的 `display` 属性不叠加（`seshat-reader-select.el:60` 已记录），因此任何 elisp 侧「字上高亮」都不可行。高亮只能由 C 侧把矩形/笔迹 wash 到 pixmap 上。

### 装饰表（替代现有 highlight 表）

| 装饰类型 | 字段 | 用途 |
|---|---|---|
| rect | page + x0,y0,x1,y1 + color[3] + alpha | 高亮（半透明填充）、下划线/删除线（细条填充） |
| stroke | page + 点列 + 线宽 + color + 圆头 | 手写 ink（本计划只落结构，不接 `ink:` 解析） |

- 快照：`render-threads.c` 的 `hl` 数组同步扩展为装饰数组（每条退出路径释放，遵循现有所有权约定）。
- 绘制：rect 按颜色分组进同一 path 一次性填充（保持「重叠不叠深」）；stroke 用 `fz_stroke_path`，圆头圆角。
- 兼容：`seshat-reader-dyn--add-highlight(page x0 y0 x1 y1)` 签名与行为不变（默认黄色 alpha 0.35），新增带颜色/类型的入口。

### 字级高亮的算法分工

- **C 只负责「几何」**：新增 `seshat-reader-dyn--rects-in-rect(page x0 y0 x1 y1)`，复用 `emacs_text_in_rect` 的 stext 遍历，返回矩形内每个命中字符的 `fz_rect_from_quad(ch->quad)`。
- **Lisp 负责「合并」**：按 y 重叠聚类成行 → 行内按 x 排序 → 相邻字符水平间隙超过阈值（`seshat-reader-select-highlight-gap-ratio` × 行高）则断开，避免双栏排版被一条横条横穿。纯函数，可 ERT 单测。
- **粒度开关**：`seshat-reader-select-highlight-granularity` ∈ `line`（默认，按行合并）/ `character`（逐字符）。
- **存储**：`location` 写多段 rect（`page:N;rect:...;rect:...`）；解析侧已支持多段（`--rects-from-location`，上限 2000 段），服务端把 location 当不透明串，**后端零改动**。

## 任务

- [x] **T1 建立渲染基线**：改造前用真实 PDF 记录既有高亮渲染结果（同一页同一 rect 的截图 + 像素校验值），作为等价性对照基线。（依赖：无；验收：基线与脚本/命令记入计划执行报告，可复现）

- [x] **T2 备份与安全点**：备份 `emacs/seshat-reader/seshat-render-core.so` 为 `.so.bak`，并创建 git 安全点（若工作区干净）。（依赖：无；验收：备份文件存在；git 状态可回滚）

- [x] **T3 C 装饰表重构（行为等价）**：把 `Highlight` 扩展为 `Decoration`（类型 rect/stroke、颜色、alpha），`mupdf-helpers.c` 的表生命周期、`render-core.c` 的快照与绘制、`render-threads.c` 的 job 快照同步修改；`--add-highlight` 旧签名保留并映射到 rect + 默认色。（c）**快照所有权必须重新设计**：现有 `Highlight` 是 POD（`render-core.h:74-78`），`render-threads.c:278-289` 用结构体浅拷贝进渲染 job；一旦 `Decoration` 的 stroke 带堆分配点列，浅拷贝会导致渲染线程与 `doc_state` 共享点列 → `clear_highlights`（`render-core.c:1789`）释放后 use-after-free，或与 `free_draw_thread_args`（`render-core.c:127`）双 free。因此 T3 必须：① 点列优先用**定长数组**（上限固定，如每笔 ≤1024 点，超出截断）；若确需动态数组，则快照改为**逐 stroke 深拷贝**并明确所有权转移；② 逐一核对 `draw_page_thread` 每条退出路径（成功/失败/提前 return）与 `clear_highlights` 的释放责任，保证「谁分配谁释放、不双 free」；③ 该点在验收中必须显式记录（编译 + 像素等价**测不到**内存缺陷）。（依赖：T1、T2；验收：`make -C emacs/seshat-reader clean all` 成功；基线像素与改造后一致；旧调用路径行为不变）

- [x] **T4 新增 C 函数 `--rects-in-rect`**：在 `emacs_text_in_rect` 的循环里收集命中字符的 quad 矩形，返回 Elisp list（`((x0 y0 x1 y1) ...)`），空结果返回 nil；坐标空间与 `--text-in-rect`、`--add-highlight` 一致（`rect_to_page_space`）。（依赖：T3；验收：对已知页面返回非空且字符数与 `--text-in-rect` 命中长度一致；越界页/无文本层返回 nil 并给出与现有函数一致的提示）

- [x] **T5 Lisp 行合并纯函数**：新增 `seshat-reader-select--merge-char-rects` 与两个 defcustom（`-highlight-granularity`、`-highlight-gap-ratio`）；实现「y 重叠聚类 → x 排序 → 间隙断开」。（TDD：先写失败用例，RED 后再实现）（依赖：T4；验收：ERT 覆盖单行、多行、双栏断开、单字符、空输入、乱序输入六种情形）

- [x] **T6 选区接字级高亮**：`seshat-reader-select-extract` 用合并结果替换单 bbox，写入 `seshat-reader-select-last` 的 `:rects`（保留 `:rect` 为整体 bbox 以兼容既有消费方）；`--flash-selection` 支持多矩形闪现。（TDD：先写失败用例，RED 后再实现）（依赖：T5；验收：隔离实例实测框选三行文字，页面出现三条贴合文字的高亮；ERT 覆盖 flash 多矩形与单矩形两条路径）

- [x] **T7 多段 location 与批注建链**：`seshat-reader-annotation--anchor` 支持多 rect 段；`seshat-reader-annotation-create` 优先用 `:rects` ；解析侧复用既有 `--rects-from-location`。（TDD：先写失败用例，RED 后再实现）（依赖：T6；验收：ERT 往返编解码（单段/多段），服务端无改动；隔离实例建一条高亮并重开文档后高亮位置一致）

- [x] **T8 下划线/删除线落地**：新增 `kind=underline` / `strikeout` 的投喂路径——取行矩形把 `y0` 抬到 `y1 - 1.5pt` 作为细条，颜色与 alpha 走装饰表新参数；Lisp 侧按 `kind` 选择几何变换（不改 C 绘制路径）。（依赖：T3、T7；验收：ERT 覆盖 kind→几何变换；隔离实例目视下划线与高亮可区分）

- [x] **T9 文档与登记**：`docs/emacs-reader.md`（字级高亮、粒度开关、间隙阈值、下划线）、`docs/api.md`（多段 rect 与 underline 契约）、`docs/architecture.md`（装饰表替代 highlight 表）、`CHANGELOG.md`、`openspec/decisions.md`（装饰表决策）、`emacs/seshat-reader/VENDORED.md`（本地 C 改动登记，遵守 F23 不变量）。（依赖：T3–T8；验收：文档与代码一致，`VENDORED.md` 有本轮 C 改动条目）

## 文档清单

`docs/emacs-reader.md`、`docs/api.md`、`docs/architecture.md`、`CHANGELOG.md`、`openspec/decisions.md`、`openspec/tech-debt.md`（旋转页不支持、颜色不可配置等既有条目更新）、`emacs/seshat-reader/VENDORED.md`、thomas-emacs 仓库 `CHANGELOG.md`（straight rebuild 与主实例重启说明）。

## 验证标准

- L1：`make check-parens`；`make -C emacs/seshat-reader clean all` 无警告（或警告数与基线一致）。
- L2：ERT 全量（含新增合并算法用例）；`make test`。
- L3：`verify` 隔离实例——`elisp_mcp_set_task(task=verify)` → `elisp_mcp_instance(action=start, instance=verify)` → **轮询 `elisp_mcp_instance_status(instance=verify)` 的 `alive`（5–10 次 × 1s，冷启动 1–17s）** → 打开真实 PDF，框选多行文字、建批注、重开文档复验；像素对比 T1 基线。收尾三步：`set_task auto` → `instance(action=stop)` → `instance_status` 确认。主实例生效需用户重启 Emacs（由用户决定时机，不擅自 rebuild 主实例）。

## 注意事项

- **C 崩溃即全站失效**：任一 C 改动后先 `make clean all` 本地编译通过再进实例；失败立即从 `.so.bak` 回滚并报告。
- `config` 类任务下禁止长耗时验证（ERT/批量编译），一律走 `verify`。
- 旋转页面坐标系既不支持，字级高亮同样不适用，沿用既有限制并记 tech-debt。
- 多段 rect 上限 2000 段（`--rect-max-segments`）；行合并后通常每页几十段，不会触顶，但 `character` 粒度下需注意，必要时在 Lisp 侧截断。
- 主实例不自动回写（I2）：验证通过后是否立即生效由用户显式要求。
- **复制为既有功能**（`select.el` 的 `kill-new` 路径），本期不新增任务。
- **ink 轨迹显示与手写存储**不在本计划：C 侧只落 stroke 结构（不接 `ink:` 解析），渲染与存储见 `reader-search-and-ink`。
- **OCR 本期不做**，记 tech-debt。

## 执行记录

### ① 三个批次的分工与结果

- **B1 · C 侧装饰表 + 字级几何入口（T1–T4）**：`Highlight` → `Decoration`（`DECORATION_KIND_RECT` / `DECORATION_KIND_STROKE` + `color`/`alpha` + `width`/`pts`），rect 与 stroke 共表；rect 按颜色分组（≤ `DECORATION_MAX_STYLE_GROUPS` = 64 组）进同一 path 一次填充，保住「重叠不叠深」；stroke 走 `fz_stroke_path`（圆头圆角，`fz_stroke_state` 栈副本置 `dash_len = 0`）。**7 条退出路径逐一核对**：`args` 空、reloading/closing 早退、`dp` 未就绪、`ctx` clone 失败、渲染失败、`img_data` 分配失败、成功——`free_draw_thread_args` 仍是唯一漏斗（改为 `free_decoration_table(args->deco, args->deco_count)`），`free_decoration_table` 是装饰表的唯一释放路径（`--clear-highlights` / `free_doc_state` 共用），原先 `free(args->hl)` 的裸 free 会漏掉每笔 stroke 的 `pts`。**深拷贝方案**：stroke 点列堆分配、结构体浅拷贝会让渲染线程与 `DocState` 共享 `pts`（`clear_highlights` 后 use-after-free / 与 job 释放双 free），因此快照对每条 stroke **逐条深拷贝 `pts`**，所有权规则写进 `Decoration` 结构体注释（恒只有一份所有权），`mupdf-helpers.c` 与 `render-core.c` 共用同一释放函数、杜绝两端漂移。新增 `--rects-in-rect`（与 `--text-in-rect` 共享 `stext_query_in_rect`，实测同一 page+rect 命中字符数 **1401 = 1401**）。
- **B2a · 行合并 + 三态像素对照（T5–T6）**：`seshat-reader-select--merge-char-rects` 纯函数（y 重叠聚类 → 行内按 x 排序 → 间隙 > `gap-ratio` × 行高断开）+ 两个 defcustom（`-highlight-granularity` 默认 `line`、`-highlight-gap-ratio` 默认 `0.8`）；中文正文实测约 **3.4 段/页行**（西文约 1 段/行），因此 `gap-ratio` 保留可调。`extract` 写入 `:rects` 并保留 `:rect` 整体 bbox，`--flash-selection` 支持多矩形。**三态像素 hash 对照**（同一页同一矩形：无装饰 / 5 参 `--add-highlight` / 9 参 `--add-decoration`）：三态 PNM **逐字节一致**，证明默认配色下装饰表改造是行为等价重构。
- **B2b · 多段 location + 下划线/删除线（T7–T8）**：`--anchor` 接受单 rect 或 rect 列表，写出 `page:<n>;rect:…;rect:…`，解析端 `--rects-from-location` 原样读回（**往返一致**，51 段用例）；段数超 500 时只写前 500 段并提示一次（第二次不再提示）。`underline` / `strikeout` 走 Lisp 侧纯函数 `--decoration-for`（底部细条 / 垂直中线细条，颜色与粗细全 defcustom），`--feed-decoration` 按 kind + 配色在 5 参与 9 参入口间二选一。隔离实例实测 underline 像素出现在行矩形底边、与半透明黄高亮视觉可区分。

### ② 两条接口决策

- **`--add-stroke` 用扁平点列表、7 参**：`(page r g b alpha width points)`，`points` 为 `(x0 y0 x1 y1 …)` 而非 `((x y) …)`——扁平列表省掉每点一个 cons 的分配与二次遍历，C 侧逐对 `car`/`cdr` 读取 + `numberp` 守卫；超过 `DECORATION_MAX_POINTS`（1024）**截断而非拒绝**（一笔长笔迹丢掉尾部仍可绘），少于 2 个点返回 nil，点数组由 C 侧 `malloc`+`memcpy` 自持。`--add-decoration` 取 **9 参**（几何 4 + RGB 3 + alpha 1 + page 1），与 5 参 `--add-highlight` 保持「多了颜色与 alpha」的最小增量，调用点不必拼 plist。**`--rects-in-rect` 的空结果静默**：矩形内没有文本是**正常答案**而非错误（框到空白区），故返回 nil 且**不发 message**，与 `--text-in-rect` 的「No text found」提示刻意不同。
- **两条绘制/投喂路径并存而非合并**：默认配色下 highlight 继续走 5 参 `--add-highlight`（像素级等价、既有测试口径不变），只有「细条」或「用户改了配色」才走 9 参 `--add-decoration`——避免一次性改变所有渲染结果的字节，也避免为兼容旧调用点保留两套语义。`--add-highlight` 的名字、arity、行为三者全不变。

### ③ 收尾补丁（3 处）

1. **`seshat-reader-annotation-create` 的空选区守卫**：`:rects` 与 `:rect` 皆 nil **且**无文本、无 BODY 时抛 `user-error`。改造后 `--anchor` 允许 nil → `page:<n>`（页级锚是合法形态），但「什么都没选中」不该借用这条退化路径静默落成页级批注；守卫放在解析 uid 与发请求之前，并落在 `--anchor` 调用之前（先判语义、再构造串）。新增 ERT 1 例（`create-empty-selection-errors`：抛 `user-error`、两名网络桩 0 调用）。
2. **模块探测补全**：`--highlight-module-available-p` 增加 `--add-decoration` 的 `fboundp` 探测（与 `--clear-highlights` / `--add-highlight` / `--refresh-highlights` 并列）。否则加载旧版 `.so` 时探测通过、细条投喂逐个失败，只表现为「underline 画不出来」而无统一提示。新增 ERT 1 例（`probe-needs-decoration-entry`：`fmakunbound` 掉 `--add-decoration` → 探测返回 nil、underline 计 failed 并返回 0、提示只出现一次、不抛错）。
3. **不可用提示文案统一**：由「高亮模块未加载，跳过批注高亮」改为「装饰模块不可用（模块未加载或缺少装饰入口），跳过批注装饰」，覆盖两种成因（整个模块缺失 / 旧版缺装饰入口）；同步更新既有 2 处断言。

### ④ 验证数字

- **L1**：`make -C emacs/seshat-reader clean all` → EXIT 0，warning **33**（= 基线，`seshat-reader-annotation.el` 零新增告警），checkdoc **0** 报错。
- **L2**：逐文件全量 ERT → **724** 例（基线 722 + 本轮新增 2），**0 unexpected**，21 个测试文件全部通过（一次加载全部文件会有既有 3 例因 ETAF 渲染路径失败，属基线特性，故逐文件跑）。
- **像素等价**：默认配色下「无装饰 / 5 参 / 9 参」三态 PNM **逐字节一致**；underline 细条出现在行矩形底部（B2b 实测）。
- Go `go test ./...` **13** 包全 PASS；Android `./gradlew test` **940** tests。

### ⑤ 回滚点

- `git tag pre-reader-decoration`（改造前安全点）
- `emacs/seshat-reader/seshat-render-core.so.bak`（改造前动态模块备份；`make clean all` 会重建 `.so`，需要回退时先恢复该备份再重启 Emacs）
- 改造前 HEAD 提交 `bc2d0385`（`fix(reader): 修复高亮绘制变换双重应用导致框选高亮偏移`）
