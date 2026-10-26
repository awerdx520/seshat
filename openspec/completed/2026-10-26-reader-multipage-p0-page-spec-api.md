# 阅读器多页连续布局 P0：按页渲染返回 image spec 的 C 接口

## 当前状态
- 阶段：**Phase 4 完成 · 已归档（2026-10-26）**
- 任务：T0–T8 **全部完成**（`[x]`），无遗留子项
- 已确认：整体路线与决策 D1–D7 ✅（用户 2026-10-26 确认：路线 3 多页 buffer 连续布局，先落地 P0）、计划 ✅（plan-reviewer 独立审查通过后用户确认，进入 Phase 3）
- 审查记录：plan-reviewer **PASS**（4 项 major 已修订）；Phase 4 的渲染等价性以 PNM 字节 sha256 守门
- 实测数据：见本文件「## 实测数据」小节（1 / 5 / 20 页三档耗时、缓存收益、`VmRSS` 与 Lisp 侧口径局限）
- 验证：L1 `make -C emacs/seshat-reader clean all` EXIT 0、warning **33** = 基线、checkdoc 0 报错；L2 全仓 ERT **29** 个测试文件 **1163** 例（新增 `seshat-reader-page-spec-test.el` **13** 例）0 unexpected / 0 skipped；L3 由既有翻页 / 缩放 / 批注冒烟覆盖（C 侧抽取后 PNM 逐字节等价）
- 归档：`openspec/completed/2026-10-26-reader-multipage-p0-page-spec-api.md`
- 下一步：**P1（buffer 多页布局 + 页号派生 + 删 strip 全族）待启动**，见 `openspec/active/roadmap.md`「M12 后续：PDF 多页连续布局（路线 3）」

## 目标

为「PDF 多页连续滚动」（路线 3）打前置地基：在 C 模块新增一个**纯查询**入口，按页号渲染任意页并返回 image spec（不改变当前页、不触碰任何 overlay、不读写 per-window 渲染状态），elisp 侧提供带缓存的包装，并测量渲染耗时与内存，为 P1（buffer 多页布局）的虚拟化与预取策略提供定量依据。

**本计划零行为变更**：不修改任何现有命令、渲染路径、页号语义、overlay 结构；现有 1110 例 ERT 必须一行不改全绿。

## 根本问题（第一性原理）

路线 3 需要把多页图像同时摆进 buffer，但当前架构**没有任何「渲染指定页并取回图像」的能力**：

| 事实 | 依据 |
|---|---|
| 渲染结果由 C 直接写进 per-window overlay：`overlay-put overlay 'display <image-spec>`，从不返回调用方 | `render/elisp-helpers.c:511-531`（`display_img_to_overlay`）、`149-181`（`data2elisp_image`） |
| 所有翻页入口都走同一模板：`wait_for_win_jobs` → `build_cache_window` → `wait_for_cached_page`（**同步阻塞主线程**）→ `display_cached_page` → 写 `selected-window` 的 `page` 参数 | `render/elisp-helpers.c:840-871`、`331-343` |
| per-window 缓存固定 11 槽、`resolution`/`rotate` 变化即整窗失效，无法表达「按页维度的多页缓存」 | `render/render-core.h:27-28`、`render-core.c:1398-1402`、`1451-1456` |
| `DocPage`（每页 display list）已按 refcount 跨窗口共享，可安全复用 | `render/mupdf-helpers.c:194-233` |
| 借「隐藏窗口预渲染」替代（`--window-create` + `goto-page`）代价过高：每窗口独占 11 张位图、每次翻页再排 10 个后台任务、写 `selected-window` 页号、且会被 `--manage-window-overlays` 反复重建 | `render-core.c:1480-1596`、`seshat-reader.el:1568-1616` |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | `draw_page_thread` 里「pixmap → PNM → CachedPage」这一段可原样抽出，供新入口复用（含 invert / gamma / decoration 绘制与快照深拷贝） | 事实✓（`render-core.c:337-700` 单一路径；`render-threads.c:246-336` 快照逻辑） |
| A2 | 新入口可完全不碰 `EmacsWinState`，只需 `DocState` + `DocPage` | 事实✓（`--page-text` 等同形只读入口已是此形态，`render-core.c:1598-1690`） |
| A3 | `create-image` 在 batch / 非图形环境下仍能返回可断言的 spec（含 `:data` / `:width` / `:height`） | 假设?（仓库现有测试**一律伪造 spec**，无真实 `create-image` 证据；另有已知风险：`data2elisp_image` 以 `type "pbm"` 传入而 `fz_write_pixmap_as_pnm` 实际写 P6。**Phase 3 首日必须先做 spike 验证**，回退方案见 T0） |
| A4 | 单页渲染耗时与现有 `wait_for_cached_page` 同量级（无额外放大） | 假设?（P0 T5 实测） |
| A5 | 抽出后 `draw_page_thread` 行为逐字节不变 | 事实✓ 需验证（P0 用『旧路径 overlay spec 的 `:data` 字节与新入口 spec 的 `:data` 字节 sha256 相等』守门（同 scale / rotate / invert / decorations 前提）） |

## 设计

### D1 C 侧：抽出渲染段 + 新增纯查询入口

- 从 `draw_page_thread` 抽出 `render_page_to_buffer(doc_state, dp, resolution, rotate, deco_snapshot, deco_count, &w, &h, &data, &size)`，`draw_page_thread` 改为调用它（**行为、缓冲区字节、释放路径完全不变**；`free_draw_thread_args` 仍是唯一释放漏斗）。
- 新增模块函数 `seshat-reader-dyn--page-image-spec`，arity **2..3**：`(PAGE SCALE [ROTATE])`
  - `PAGE` **1-based**（与 `--search-page` / `--add-decoration` 等入口一致，复用 `resolve_page_arg` 做范围与整数校验）；
  - `SCALE` 为倍数（72 dpi = 1.0），内部按既有口径 clamp 到 `MINRES..MAXRES`；
  - `ROTATE` **缺省 0，且只接受 0 / 90 / 180 / 270 四个整数**；其它值（45、非整数、非法类型）→ 静默返回 nil，**不做就近钳制**（钳制会让调用方误以为旋转成功）。`SCALE` 为 nil 或非数字 → 静默返回 nil；数值按既有口径 clamp 到 `MINRES/72 .. MAXRES/72`；
  - 返回 `create-image` 产出的 spec（与 overlay `display` 同形）；
  - 页号非法（越界 / 0 / 负数 / NaN / inf / 非整数）一律**静默返回 nil、不发消息**（与 `--add-highlight` / `--add-decoration` 的既有语义一致；`resolve_page_arg` 本身静默返回 false，消息文案只在 `--search-page` 这类入口由调用方补）。`DocState.is_reloading` 为真时同样静默返回 nil。**不存在 `closing` 判据**——那是 `EmacsWinState` 字段，本入口不碰窗口状态；
  - **不读写 `win_state`、不改任何 overlay、不改 `page` 参数、不动缓存槽**；
  - `DocPage` 走 `acquire_doc_page` / `release_doc_page` 配对，渲染完即释放（P0 不引入 pin 语义）。
- 装饰（高亮/笔迹）：使用**当前文档装饰表的深拷贝快照**（与 `draw_page_thread` 同源），保证返回的位图与屏幕一致；若快照分配失败则按无装饰渲染（不报错）。
  - 装饰快照的所有权归本入口：渲染结束后由 `free_decoration_table(deco, deco_count)` 释放（worker 路径释放的是 `DrawThreadArgs->deco`，本入口无该结构，**不得**照抄 worker 的释放点）。

### D2 elisp 侧：包装 + 缓存

- 新增 `seshat-reader--page-spec (page &optional scale rotate)`：调 C 入口，返回 spec 或 nil。
- 新增 buffer-local 缓存 `seshat-reader--page-spec-cache`（alist，键 `(PAGE SCALE ROTATE)`，上限 `seshat-reader--page-spec-cache-limit` = 8，超出按最旧淘汰；`defvar` 而非 defcustom）。缓存仅 P0 用于性能测量与 P1 复用，**当前没有任何显示路径读它**。
- 新增 `seshat-reader--page-spec-clear-cache`（供 scale / rotate / reload / kill 时清理；P0 只在 `--clear-doc-memory` 与 `--render-buffer` 收尾挂一次，避免泄漏）。

### D3 明确不做（P0 边界）

不新增异步渲染、不新增回调、不改 `EmacsWinState` 缓存模型、不改 `--refresh-highlights` 的刷新范围、不改任何滚动/居中/页号代码、不引入多页布局、不删 strip。

## 实测数据

**口径**（2026-10-26，T6）：`emacs --batch -Q`（GNU Emacs 31.1），`-L emacs -L emacs/seshat-reader` + 12 个 straight build 目录；夹具 `/usr/share/doc/ghostscript/Ghostscript.pdf`（477 页）；`scale = 1.0`（72 dpi）、`rotate = 0`、页号 1-based；夹具内 `(fset 'image-flush #'ignore)`（batch 下连续渲染必需，不影响 PNM 字节）。每档测量前先 `garbage-collect`，档内逐页取 `(float-time)` 差值求和；`VmRSS` 取自 `/proc/self/status`；预热动作为渲染最后一页（只加载字体/图像库，不暖 pages 1–20 的 display list）。

### T6-1 三档首次渲染（直呼 C 入口，绕过 elisp 缓存）

| 档位 | 页 | 原生调用次数 | 总耗时 | 每页耗时 mean / min / max | `gcs-done` 增量 | `(memory-info)` 逐元素差 | `VmRSS` 增量 |
|---|---|---|---|---|---|---|---|
| 1 页 | 1 | 1 | **5.9 ms** | 5.9 / 5.9 / 5.9 ms | +0 | （0 −8100 0 0） | **+4.3 MB** |
| 5 页 | 1–5 | 5 | **9.5 ms** | 1.9 / 0.7 / 6.3 ms | +0 | （0 −9720 0 0） | **+9.6 MB** |
| 20 页 | 1–20 | 20 | **51.3 ms** | 2.6 / 0.7 / 11.0 ms | +2 | （0 −6012 0 0） | **+17.9 MB** |

逐页耗时（ms，页 1→20）：`6.0 0.7 0.9 0.8 0.9 10.4 3.9 3.2 1.7 0.8 0.8 0.9 1.8 1.5 2.4 11.0 1.0 0.8 1.1 0.7`——每档首页（display list 冷加载）与含复杂图形的页（6 / 16）是长尾，其余稳定在 0.7–1.2 ms。

### T6-2 缓存收益（`seshat-reader--page-spec`，8 页工作集）

| 顺序 | 场景 | 原生调用次数（=缓存缺失数） | 总耗时 | `VmRSS` 增量 |
|---|---|---|---|---|
| A | 首次请求 1–8 页（缓存空、display list 冷） | 8 | 22.3 ms | +12.4 MB |
| B | **同 8 页第二次请求**（应全命中） | **0** | **0.0 ms** | **+0 KB** |
| C | 清空缓存后再请求 1–8 页（display list 已暖） | 8 | 23.4 ms | +12.4 MB |

A ≈ C（22.3 vs 23.4 ms）说明 display list 是否预热对该口径影响很小；B 的 0.0 ms / 0 次原生调用说明**收益完全来自 Lisp 侧 spec 缓存**，与 C 侧暖缓存无关。

### T6-3 同 20 页第二次请求（缓存上限 8 的真实表现）

| 场景 | 原生调用次数 | 命中数 | 总耗时 | `VmRSS` 增量 |
|---|---|---|---|---|
| 直呼 C 入口，20 页首次 | 20 | — | 36.0 ms | +25.0 MB |
| `--page-spec` 20 页第 1 轮 | 20 | 0 | 34.3 ms | +24.9 MB |
| `--page-spec` **同 20 页第 2 轮** | **20** | **0** | 20.5 ms | +16.6 MB |
| `--page-spec` 1–8 页再来一轮 | 8 | 0 | 6.4 ms | +0 KB |

**第 2 轮命中率为 0**：缓存上限 8 + 先进先出淘汰，顺序访问 20 页时第 1 轮结束时槽内只剩 13–20 页；第 2 轮从第 1 页起每页都是缺失并顺手淘汰掉后 8 页，于是整轮零命中（20.5 ms 的下降只来自 C 侧暖 display list，不是缓存）。

### T6-4 既有翻页路径基线（`seshat-reader-goto-page`，用于「同量级」对比）

`wait_for_win_jobs` → `build_cache_window` → `wait_for_cached_page` → `display_cached_page` 全路径，连续 5 次（页 2→6）：**1.3 / 4.0 / 4.9 / 3.4 / 3.0 ms**（mean 3.3 ms），5 次共 `VmRSS` +19.5 MB。

### T6-5 单页位图体量（换算内存预算用）

| 分辨率 | `:width` × `:height` | `:data`（PNM P6）大小 |
|---|---|---|
| 72 dpi（scale 1.0） | 612 × 792 | 1.42 MB |
| 150 dpi（scale ≈2.08） | 1275 × 1650 | 6.16 MB |

### T6 结论

1. **单页耗时量级与既有 `wait_for_cached_page` 同量级**（假设 A4 成立✓）：新入口 0.7–11 ms / 页（mean 2.6 ms），全路径翻页 1.3–4.9 ms（mean 3.3 ms）。新入口没有额外放大，甚至略低（省掉 10 个后台 job 的排队与线程交接）。**但这是 72 dpi 口径**（612×792，PNM 1.42 MB）；代码里 P1 会按 fit scale 渲染（150 dpi 时像素数 4.3 倍），耗时须按像素数线性外推并在实际缩放档复测。
2. **缓存收益只在工作集 ≤ 上限（8）时成立**：8 页工作集第二轮 8/8 全命中、总耗时 22.3 → **0.0 ms**、`VmRSS` 零增长；而顺序扫 20 页（> 上限）第二轮命中率 **0**，等于纯抖动。→ P1 的硬约束：**视口同时驻留的页数必须 ≤ 缓存上限**，否则必须改淘汰策略（LRU / 按页号区间保留）或提高上限——这条直接决定 P1 虚拟化的窗口大小。
3. **Lisp 侧指标不能当内存指标（口径局限）**：`gcs-done` 几乎不动（1 / 5 页档 +0，20 页档 +2），`(memory-info)` 是**系统级**信号（4 个元素的差值在 −12 ~ +5 MB 之间随机抖动，对单进程增量无分辨力）。真正的旁证只有 `/proc/self/status` 的 `VmRSS`：首轮 20 页 **+17.9 MB（≈0.9 MB/页）**，同 20 页第二轮再 **+16.6 MB**（8 条驻留 + 12 条待 GC 的垃圾字符串）。且 Lisp 侧只持有 spec 的 `:data` 副本，C 侧 `cp->img_data` 与 MuPDF image cache 各自另存 → **进程总内存增量至少是 Lisp 侧观测值的 1.5–2 倍量级**，P1 的页池预算必须按 `VmRSS` 上限反推，不能按 spec 字符串大小算。
4. **复现**：`/tmp/t6-measure.el`（T6-1 / T6-2 / T6-3）与 `/tmp/t6-measure2.el`（T6-4 / T6-3 第二轮），命令模板
   `emacs --batch -Q -L emacs -L emacs/seshat-reader -L <straight build-31.1 各包> -l <脚本>`
   （脚本不入库：一次性测量工件，结论已固化在本节）。

## 任务

- [x] T0 **Phase 3 首日 spike（≤30 分钟，不改产品代码）**：① 在 batch 中 `module-load` 已构建的 `seshat-render-core.so` 并检查 `(fboundp 'seshat-reader-dyn--page-image-spec)`；② 打开一份真实 PDF（`/usr/share/doc/ghostscript/Ghostscript.pdf`），确认 batch 下能取到活文档的 `DocState`；③ 对 1 页调新入口，检查返回 spec 的 `(image-property spec :data/:width/:height/:type)` 是否可取。**若 ③ 失败**，把 T5 改为「elisp 包装语义用桩验证（参数传递 / 缓存 / 零副作用），真实 C 行为由 L3 GUI 冒烟覆盖」，并在本计划记录 spike 结论。（依赖：T2、T3）
- [x] T1 C 侧抽出 `render_page_to_buffer` 并让 `draw_page_thread` 改用（保持行为逐字节一致）。验收：编译 0 新增 warning；**渲染等价性**用「同一页经旧路径与新路径渲染后 `:data` 字节相同」守门——旧路径取数方式：改造前正常翻页一次，读窗口 overlay 的 `(overlay-get ov 'display)` 再用 `(image-property spec :data)` 取 PNM 字节，算 sha256；新路径对同一页调新入口取 `:data` 算 sha256；两者必须在 scale / rotate / invert / decorations 完全一致的前提下相等（建议做成一次性脚本，结果记入计划）。（依赖：无）
- [x] T2 新增并注册 `seshat-reader-dyn--page-image-spec`（arity 2..3）+ `render-core.h` 声明。验收：`(seshat-reader-dyn--page-image-spec 1 1.0)` 返回 spec；页号 0 / 越界 / 非整数返回 nil 且不崩溃。（依赖：T1）
- [x] T3 重建 `seshat-render-core.so` 并冒烟：打开一份真实 PDF（如 `/usr/share/doc/ghostscript/Ghostscript.pdf`），确认既有翻页/缩放/批注行为无变化。（依赖：T1、T2）
- [x] T4 elisp 包装 + 缓存 + 清理挂点。验收：`(seshat-reader--page-spec 3 1.0)` 与 `(seshat-reader--page-spec 3 1.0)` 第二次命中缓存（计数桩验证只调 C 一次）；上限 8 条生效；`--clear-doc-memory` 后缓存为空。（依赖：T2）
- [x] T5 ERT 新增 ≥10 例（`emacs/tests/seshat-reader-page-spec-test.el`），**夹具策略以 T0 结论为准**：
  - 若 T0 ③ 通过（batch 可加载真实 .so 且能取 spec）：用例走真实 C 入口 + 指定 PDF fixture；① 正常返回 spec 且 `:width/:height` 为正整数；② 页号 0/负/越界 → nil；③ 非整数页号（2.7）→ nil；④ scale 极端值（0.001 / 1000）被夹紧且返回 spec；⑤ `scale` 为 nil → nil；⑥ `rotate` = 45 → nil，`rotate` = 90/180 返回的 `:width/:height` 方向互换；⑦ 缓存命中（第二次数不调 C，用计数桩包住 elisp 包装层）；⑧ 缓存上限 8 条淘汰最旧；⑨ 调用前后 `(window-parameter nil 'page)`、`scale`、`native-size` 与 overlay `display` 全部不变（零副作用守门）。
  - 若 T0 ③ 失败：上述 ①④⑥ 降级为 L3 GUI 冒烟清单，ERT 只覆盖 elisp 包装层（②③⑤⑦⑧⑨ + 参数透传断言），并在测试文件头写明降级原因。
  验收：新增用例全绿；既有 1110 例零改动零失败。（依赖：T0、T2、T4）
- [x] T6 性能与内存测量：对真实 PDF 连续渲染 1 / 5 / 20 页，记录每页耗时、总耗时、`gcs-done`、`(memory-info)`，**并额外记录 `/proc/self/status` 的 `VmRSS` 增量作为 C 侧旁证**（Lisp 侧指标只覆盖 `:data` 副本，C 侧 `cp->img_data` 与 MuPDF image cache 不在其中，必须注明口径）。结果写入计划文件新增的「## 实测数据」小节。（依赖：T3）**验收✅（2026-10-26）**：batch 实测三档——1 页 5.9 ms / 5 页 9.5 ms / 20 页 51.3 ms（每页 0.7–11 ms，`VmRSS` 分别 +4.3 / +9.6 / +17.9 MB）；8 页工作集第二轮 8/8 全命中（22.3 → 0.0 ms），顺序扫 20 页第二轮命中率为 **0**（上限 8 + 先进先出淘汰）；Lisp 侧 `gcs-done` / `memory-info` 无分辨力，故以 `VmRSS` 为总内存旁证并注明「C 侧 `cp->img_data` 与 MuPDF image cache 另计」的口径局限。
- [x] T7 文档与决策同步（见「文档清单」）。（依赖：T2–T6）**验收✅（2026-10-26）**：七份文档全部同步——`VENDORED.md`（`render/render-core.c` 第 ⑬ 项、`seshat-reader.el` 第 ⑭ 项）、`docs/architecture.md`（新增「按页渲染查询接口（P0，2026-10-26）」小节）、`docs/emacs-reader.md`（§13 新增「按页渲染查询接口（P0，内部接口）」+ 测试清单同步 28→29 文件 / 1150→1163 例）、`openspec/decisions.md`（新增 2026-10-26 多页连续布局与 P0 接口形态）、`openspec/tech-debt.md`（新增「多页连续布局（路线 3）落地前必须处理」7 条）、`openspec/active/roadmap.md`（新增「M12 后续：PDF 多页连续布局」+ `## 当前状态` 进展 bullet）、`CHANGELOG.md`（`[Unreleased]`/新增 一条并标明无用户可见行为变更）。
- [x] T8 归档：勾选任务、更新「当前状态」、计划移入 `openspec/completed/`；在 `openspec/active/roadmap.md` 登记 P1 待启动。（依赖：T1–T7）

## 文档清单

| 文档 | 需同步内容 |
|---|---|
| `emacs/seshat-reader/VENDORED.md` | `render/render-core.c` 条目追加「抽出 `render_page_to_buffer` + 新增 `seshat-reader-dyn--page-image-spec`（全名）」；`seshat-reader.el` 条目追加 elisp 包装与缓存（含上限 8） |
| `docs/architecture.md` | 渲染管线一节补「按页查询接口（P0）」与「为什么需要它（多页布局前置）」 |
| `docs/emacs-reader.md` | 开发者接口说明补 `seshat-reader--page-spec` 与 C 入口、缓存上限、已知同步阻塞代价 |
| `openspec/decisions.md` | 新增一条：多页连续布局（路线 3）决策记录，含 D1–D7 定论与 P0 接口形态 |
| `openspec/tech-debt.md` | 登记 P1 起必须处理的已知缺口：per-window 11 槽缓存无法表达多页、`--refresh-highlights` 只刷当前窗口、hscroll 是窗口级、多窗口「各看不同页」能力将丢失、整页位图约 2 MB 的内存上限 |
| `openspec/active/roadmap.md` | 新增「多页连续布局」里程碑：P0 ✅ / P1 待启动 |
| `CHANGELOG.md` | `[Unreleased]` 下新增内部接口条目（标明「无用户可见行为变更」） |

## 验证标准

- **L1**：`elisp_check_parens` 对改动的 elisp 文件通过；`make -C emacs/seshat-reader all` EXIT 0、warning 数不超过基线 33、checkdoc 0 报错。
- **L2**：`emacs/tests/` 逐文件 ERT（带项目文档列出的 `-L` 依赖路径），**既有 1110 例零回归**（`unexpected = 0`、`skipped = 0`）+ 新增 ≥10 例全绿（夹具策略依 T0 结论：真实 .so 或桩 + GUI 冒烟）。
- **L3**：C 改动后必须 `make -C emacs/seshat-reader clean all` 重建 `.so` 并**重启 Emacs**；冒烟：打开真实 PDF、翻页 10 次、缩放 3 次、框选建批注 1 次，行为与改造前一致；T6 的性能数据已记录。
- **任务类型**：elisp 验证声明 `verify`（隔离实例）；收尾 `elisp_mcp_set_task auto` + `elisp_mcp_instance(action=stop, instance=verify)` + `elisp_mcp_instance_status` 确认。

## 注意事项

1. **零副作用是硬约束**：新入口不得写 `win_state`、不得写窗口参数 `page`/`scale`/`native-size`、不得碰 overlay；T5 用例⑨ 是这条约束的守门测试。
2. **同步渲染的主线程代价**：P0 的入口同步阻塞（与 `wait_for_cached_page` 同代价）。只允许显式调用/测量，**不得**接入任何滚动或显示路径（那是 P1/P2 的事）。
3. **PNM 双份内存**：spec 的 `:data` 是 Lisp 堆副本，C 侧 `cp->img_data` 与 image cache 各自另存；P0 缓存上限 8 条即为此设，不得调大超过 16。
4. **抽取必须逐字节等价**：`render_page_to_buffer` 抽取后，`draw_page_thread` 的 invert / gamma / decoration / PNM 写盘顺序不得重排；用 sha256 守门。
5. **页号基数**：新入口 1-based，与 `--search-page` / `--add-*` 一致；**不改** `--text-in-rect` / `--rects-in-rect` / `--lines-in-rect` 的 0-based 约定。
6. **不解决后续问题**：缓存模型重构、异步渲染、高亮刷新范围、hscroll 全局、多窗口页号语义都属于 P1–P4；P0 只提供接口与数据，不得顺手改。
7. **文档与决策先行**：D1–D7 定论必须写进 `openspec/decisions.md`，避免 P1 执行时重新讨论。
8. **DocPage 暖缓存属可接受副作用**：新入口会顺带填充 `dp->display_list`/`bbox`（`acquire_doc_page` 在 `ready == false` 时同步 `load_page_dl`）。这不违反「零副作用」——禁单只含 `EmacsWinState`、窗口参数与 overlay；但 P1 设计虚拟化时要把「暖缓存」计入内存预算。
9. **elisp 落点**：`seshat-reader--page-spec` 与缓存都写在**现有** `emacs/seshat-reader/seshat-reader.el`（不新建文件，`Makefile` 因此不变）；文档与 VENDORED.md 提及 C 入口时**必须用全名** `seshat-reader-dyn--page-image-spec`，不得简写 `--page-image-spec`。
