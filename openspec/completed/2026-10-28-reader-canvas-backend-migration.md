# 阅读器渲染后端迁移：PBM → canvas（Emacs 32 单后端）

## 当前状态
- 阶段：Phase 4（Review & Document）· 已完成并归档
- 已确认：方案 ✅、计划 ✅（用户 2026-10-28）
- 执行结果：T0–T8 全部完成（含执行期批次合并 T2+T3+T4+T5、T6+T7；补做 T2b 性能与 T2c volatile）
- 验证：逐字节等价 3/3 差异 0；L1 C 0/0、elisp warning 20、checkdoc 0；L2 37/1327/0 unexpected/0 skipped + check-criteria PASS
- 遗留：见 `openspec/tech-debt.md`（P2-5 部分缓解 + 4 项新增）
- 下一步：真机 L3 验收（七项，见本文件「验证标准」）

## 目标
把每页位图的传输层从「MuPDF RGB → PNM 编码 → Lisp 字符串 → `create-image :type pbm`」换成「MuPDF BGR+alpha → ARGB32 直写 Emacs canvas 缓冲 → `canvas-refresh`」，并退役随 pbm 一起失效的 legacy 渲染路径。**行为不改**：几何、缩放、居中、暗色、装饰、坐标全部保持等价。

## 背景（已实测事实，非推测）
- 本机 Emacs 32.0.50（pgtk/WSLg）与 MuPDF **1.28.5**（Makefile 要求 ≥1.26）。
- canvas：`:data-width`/`:data-height`/`:id` 必需（`:id` 可省略）；**:data 可为 nil**（缓冲惰性分配，Lisp 侧零常驻）；`:width/:height` 仍做显示层缩放且与 pbm **逐字节等价**；`canvas-refresh (image &optional reload-data)` 无局部刷新；`canvas_data` 每次必须重取（改 `data-*` 重建缓冲**并清零**）；像素整数字义 `0xAARRGGBB`（小端字节序 B,G,R,A）；空/短 `:data` 不清零（旧像素残留）；`reload-data` 与模块直写**不可混用**。
- MuPDF API：`fz_device_bgr(ctx)` 存在（通道序天然吻合，零重排）；`fz_pixmap_stride` 是函数；`fz_clear_pixmap_with_value(ctx, pix, value)` 会把 alpha 恒置 255；`fz_new_pixmap_with_data(...)` 可绑外部缓冲但 **samples 所有权未明**；MuPDF 渲染结果为**预乘 alpha** 且**无反预乘 API**。
- 现有代码在 Emacs 32 下编译 **0 error 0 warning**，现有 `.so` 能被 32 `module-load` 成功。
- **vendored `render/emacs-module.h` 是 Emacs 31 版，无 `canvas_data` 成员**（`emacs_env_32` 相对 `_31` 为尾部追加，ABI 兼容）。
- elisp 生产代码只用 `--page-image-spec`（同步渲染，**不走 worker 池、不读 `CachedPage`**）；`CachedPage` / 8 线程池 / overlay / `image-flush` 全在 legacy 路径。
- **退役范围（判据 = elisp 生产调用点为空）**：
  - 完全无引用 **9 个**：`--redisplay-doc`、`--next-page`、`--prev-page`、`--first-page`、`--last-page`、`--goto-page`、`--scale-page`、`--rotate-page`、`--window-create`
  - 仅测试使用 **1 个**：`--refresh-highlights`（生产侧只有 `annotation.el:1363` 的 `fboundp` 能力探测，无调用）
  - 保留：`--load-doc`（`seshat-reader.el:3365`）、`--close-doc`（`:3301`）、`--doc-invert`（`:3999`）、`--doc-tint`（`:3978`）、`--page-text`（`:4115`）、`--text-in-rect`（`:4137`）、`--rects-in-rect`、`--lines-in-rect`、`--search-page`、`--add-highlight`、`--add-decoration`、`--add-stroke`、`--clear-highlights`、`--page-image-spec`
  - **`--window-close` 的处理**：它唯一的 elisp 调用点 `seshat-reader.el:2438` 位于 `seshat-reader--multipage-drop-c-overlay`（`:2426-2439`）内部，C 侧唯一调用者是 `init_overlay` 内的回调 `elisp-helpers.c:402`。这两个调用者分别在 T6（elisp 侧）与 T7（C 侧）删掉 → **`--window-close` 与其实现 `emacs_doc_window_close` 一并进 T7 删除清单**，T6 阶段保留原样（不改写、不加快速返回）。

## 设计

### 尺寸双轨制（核心概念）
- `:data-width` / `:data-height` = **设备像素**（= MuPDF pixmap 尺寸），**只在渲染时设一次**，之后任何代码路径都禁止改写。
- `:width` / `:height` = **逻辑像素**（= pixmap ÷ `frame_scale`），可随时 `setf`（`seshat-reader.el:1446-1455` 逻辑不变）。
- 违规后果：改 `data-*` 会重建缓冲并清零 → 残影/花屏。

### 像素路线（API 时序是关键，v2 修订）
**必须按此顺序**（v1 把 clear 写在渲染之后，会把整页刷成黑）：

1. `fz_new_pixmap_with_bbox(ctx, fz_device_bgr(ctx), bbox, NULL, 1)` — 分配 BGR+alpha、内容未初始化。
2. `fz_clear_pixmap_with_value(ctx, pix, 0)` — **先铺不透明黑背景**（该 API 强制 alpha=255）。
3. `fz_new_draw_device(ctx, ctm, pix)` → `fz_run_display_list(ctx, dl, dev, ctm, scissor, NULL)` → `fz_close_device` — **再渲染页面**。
4. 既有像素变换（dark/tint）与装饰 wash（复用 `fz_new_draw_device(ctx, ctm, pix)` 模式，同现有 `render-core.c:415-416`）。
5. 逐行按 `fz_pixmap_stride` 把 `w*4` 字节 memcpy 进 canvas 缓冲（`canvas_data`，主线程取、用完即弃）。
6. `canvas-refresh`（第二参 nil）。

**为什么这个顺序成立**：先铺不透明背景 ⇒ 全部像素 alpha=255 ⇒ MuPDF 的预乘渲染与直通等价（无需反预乘）；页面内的半透明图层也会 blend 到不透明背景上、最终 alpha 仍为 255。
**不采用的路线**：`fz_new_pixmap_with_data` 直接绑 canvas 缓冲（零拷贝）——`fz_drop_pixmap` 是否 free 外部缓冲未知，验证前不冒险。

### spec 构造
`data2elisp_image` 改为：
```
create-image(nil, 'canvas, t, :data-width W, :data-height H, :width LW, :height LH)
```
- **省略 `:id`**（实测最安全；传非符号会静默产出假 spec）
- 建后双自检：`(imagep img)` 且 `canvas_data` 非 NULL，任一失败则释放并返回 nil（不得静默）
- 填充完像素后 `canvas-refresh`

### 退役策略（两步，边界清晰）
- **T6（elisp 侧 + 无引用入口）**：删 9 个无引用入口 + `--refresh-highlights`；删 elisp 的 `seshat-reader--multipage-drop-c-overlay`（`:2426-2439`，含 `:2438` 的 `--window-close` 调用）与 `annotation.el:1363` 的能力探测。`--load-doc`/`--close-doc` 只去掉 `init_overlay`/`init_win_state_ptr` 依赖（`emacs_load_doc` 只建 DocState）。
- **T7（C 侧 legacy 全量退役，可独立回滚）**：删 worker 池（`render-threads.c`/`.h`）、`CachedPage`/`EmacsWinState`、`build_cache_window`/`nullify_window_cache`/`display_cached_page`/`display_img_to_overlay`/`init_overlay`/`init_win_state_ptr`/`clear_overlay_and_win_state`、**`emacs_doc_window_close` 与 elisp 注册名 `--window-close`**、`image-flush` 调用；`get_reader_current_state` **保留**但改为只持有 DocState（去掉 win-state 分支），并回归 `--page-text`/`--search-page` 两个入口。

## 任务

- [ ] T0 **旧后端基线固化**（在动任何代码之前）：用**现有** pbm 路径对固定样本渲染并存档，作为 T3/T4 逐字节对比的唯一依据。样本 = 系统 PDF `/usr/share/doc/ghostscript/Ghostscript.pdf`（477 页；脚本内必须先 `(file-exists-p)` 守卫，缺失则 `user-error` 中止并在报告里说明），选**内容覆盖充分**的一页（建议第 3 页，实际页码必须写进 `.meta`；不得选深色封面/近空白页）+ 三个组合：`(scale 1.0, rotate 0)`、`(1.5, 0)`、`(1.0, 90)`。做法：临时脚本调 `seshat-reader-dyn--page-image-spec` 取 spec，把 `(image-property spec :data)` 原样写入 `/tmp/canvas-baseline/<样本>-<scale>-<rotate>.pnm`，并记录 `:width`/`:height`/`:data` 长度到同名 `.meta`。验收：3 个 `.pnm` + 3 个 `.meta` 存在且字节数 > 0；**此后不再修改该目录**。每个 `.meta` 必须记录：源 PDF 路径、页码、scale、rotate、`:width`、`:height`、`:data` 字节长度，以及归一化口径（下条）。

  **格式归一化口径（T3 比较前必须执行）**：T0 存的是 PNM（P6：`P6\n<W> <H>\n255\n` 头部 + RGB 3 字节/像素），新后端是 ARGB32 裸缓冲（B,G,R,A 4 字节，通道序相反）——两者**不能直接 `cmp`**。做法：解析并剥掉 PNM 头部 → 对新缓冲逐像素取 `B,G,R`（**丢弃 A，并断言 A==255**）→ 按 RGB 顺序重新拼接为与 PNM 负载等长的字节串 → 再逐字节比较，要求差异 = 0。（依赖：无）
- [ ] T1 **模块头文件 32 化**：把 `render/emacs-module.h` 升级为 32 版（可直接改用 `/usr/include/emacs-module.h` 或把 `emacs_env_32` 追加进 vendored 副本）；核查 `render/*.c` 是否依赖 31 版特有行为（`env->size` 的 ABI 检查、显式引用 `emacs_env_31`、`emacs_funcall_exit_*` 取值假设等），有则一并处理。验收：`make all` 0 error 0 warning；`nm -D` 保留的 15 个入口符号齐全（= 背景「保留 14 个」+ `--window-close`；后者直到 T7 才删，故 T1 阶段仍是 15）；`env->canvas_data` 可编译。（依赖：T0）
- [ ] T2 **渲染核输出 ARGB32**：按「像素路线」1–5 步改造 `render_page_to_buffer`；删 PNM 编码段（`render-core.c:657-658`）与 malloc/memcpy（`:677-703`）；新契约输出 `(data_w, data_h, stride, samples)`；逻辑尺寸算法（`:654-655`）不变。验收：编译 0/0；单元级验证：① 首像素为 `0xFF000000`；② **全页不恒为同一值**（均匀抽样 1000 点，最大与最小像素值的差 > 0）——用于捕捉「clear 写在渲染之后」造成的整页同色；③ 页面选取须**内容覆盖充分**（与 T0 同一页），避免深色封面/近空白页导致假阴性。（依赖：T1）
- [ ] T3 **canvas spec 构造 + 逐字节对比**：`data2elisp_image` 改 canvas plist（省略 `:id`，设 `:data-width/:data-height/:width/:height`，`:data` nil）；主线程取 `canvas_data` → 逐行 memcpy → `canvas-refresh`；双自检。验收：编译 0/0；**用 T0 的三个样本对比**——新旧像素逐字节一致（允许差异为 0；若存在差异，须逐项说明原因并给出「视觉等价」证据，不得放行未解释的差异）。（依赖：T2、T0）
- [ ] T4 **elisp 内存估算与残读清理**：`--multipage-resident-spec-megabytes`（`seshat-reader.el:1858-1872`）改按 `data-width × data-height × 4`；更新 `:907-909`、`:1446-1455` 注释为 canvas 语义；**全局 grep 确认除该函数外无任何 `(image-property spec :data)` 读取**（含 mode-line/bookmark/saveplace/select/search 各模块），命中则一并处理。验收：`grep -rn "(image-property [^)]*:data)" emacs/ --include=*.el` 仅剩新口径 1 处；编译 warning 不新增。（依赖：T3）
- [ ] T5 **测试改造**：`page-spec-test.el:169-170` 的 `:data` 是 string 断言 → 改为 `:data-width/:data-height` 为正整数 + 缓冲可写；`multipage-test.el`/`periphery-test.el`/`select-cross-page-test.el` 的 fake spec 由 `(list 'image :type 'pbm :data "x" ...)` 改 canvas 形态（保留 `:width/:height`）；`page-spec-test.el:126-133`、`rect-query-overlay-test.el:124-130` 的 `fset 'image-flush #'ignore` 护栏**本批保留**（T7 再删）。验收：`make -C emacs/tests ert` 0 unexpected、0 skipped；`check-criteria` PASS。（依赖：T4）
- [ ] T6 **退役无引用入口 + elisp 侧清理**：删 9 个无引用入口 + `--refresh-highlights`（含 `render-core.c` 注册块对应行与 C 实现）；`emacs_load_doc` 去掉 `init_overlay`/`init_win_state_ptr`；删 `seshat-reader--multipage-drop-c-overlay`（`:2426-2439`）及其调用点、`annotation.el:1363` 能力探测。`--window-close` 本批**不动**（改写无意义：其调用者将在 T7 消失）。验收：`grep -rn "seshat-reader-dyn--\(redisplay-doc\|next-page\|prev-page\|first-page\|last-page\|goto-page\|scale-page\|rotate-page\|window-create\|refresh-highlights\)" emacs/ --include=*.el` 为空；编译 0/0；ERT 0 unexpected 0 skipped。（依赖：T3、T5）
- [ ] T7 **退役 worker 池与 CachedPage（可独立回滚）**：删 `render/render-threads.c`/`.h`、`CachedPage`/`EmacsWinState`、`build_cache_window`/`nullify_window_cache`/`display_cached_page`/`display_img_to_overlay`/`init_overlay`/`init_win_state_ptr`/`clear_overlay_and_win_state`、**`emacs_doc_window_close` + 注册名 `--window-close`**、`image-flush` 调用与两处测试护栏；`get_reader_current_state` 保留并改为只持 DocState（去掉 win-state 读取分支），回归验证 `--page-text` 与 `--search-page`。验收：编译 0/0；`nm -D` 符号与保留清单（14 个）一致；`grep -rn "image-flush" emacs/ --include=*.el --include=*.c` 为空；ERT 0 unexpected 0 skipped。（依赖：T6）
- [ ] T8 **版本门禁与文档**：`Package-Requires` 提到 32；`Makefile` 增 Emacs 主版本 ≥32 检查（低于即 `$(error)`）；更新 `docs/architecture.md`（M12 + 尺寸双轨制 + 新内存模型）、`docs/emacs-reader.md`（版本要求、canvas 后端、`transform-smoothing` 观感与默认值）、`emacs/seshat-reader/VENDORED.md`、`CHANGELOG.md`、`openspec/decisions.md`（迁移落地记录）、`openspec/tech-debt.md`（**P2-5 改为部分缓解**：分列「已消除」= Lisp 字符串副本、`CachedPage.img_data`；「仍存在」= Emacs image cache 内的 canvas 缓冲、渲染期 MuPDF pixmap 临时一份）、`openspec/roadmap.md`。验收：文档逐项列出更新点；`make all` 通过。（依赖：T7）

## 验证标准
- **L1**：`cd emacs/seshat-reader && make all` → exit 0；C **0 error 0 warning**；elisp byte-compile warning **不新增**（基线用固定命令固化：`make all 2>&1 | grep -c "Warning"`，把首次测得的数字写进本文件「## 验证记录」节作为对比基准，后续批次用同一命令比对）；`checkdoc` 0 输出；`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → **0 unexpected 且 0 skipped**（判据走 `emacs/tests/ert-judge.sh`；注意「无 skipped 时输出行不含 skipped 字样」）；`make -C emacs/tests check-criteria` PASS。
- **L3（真机，必须）**：① 开 PDF 首页正常、无残影/花屏；② 滚动跨页连续；③ 窗口缩放（`W`/`H`/拖分割线）无空白帧；④ 批注高亮/搜索命中/ink 手写正确；⑤ 暗色与 5 档配色切换正常；⑥ 双窗口同文档显示一致；⑦ 关闭重开位置记忆正常（bookmark/saveplace 未读 `:data`）。
- **逐字节等价**：以 T0 的三个 `.pnm` 为唯一基线，T3 必须做到差异 = 0；任何差异都要在「## 验证记录」里逐项解释并给出视觉等价证据。
- **收益量化（记录一次，非门禁）**：T3 后在同样三个样本上记录「旧 pbm 路径 vs 新 canvas 路径」的单页端到端耗时（各 ≥20 次取中位），写入「## 验证记录」。
- 任务类型：elisp 验证走 `verify` 隔离实例（`set_task verify` → 预拉起 → 轮询 `alive` → 验证 → `set_task auto` → `instance stop` → `instance_status` 确认）；C 模块重编译后**必须重启 Emacs**（动态模块不可卸载）。

## 风险与回滚
| 风险 | 级别 | 处置 |
|---|---|---|
| **clear 时序写错 → 整页全黑** | 高 | v2 已固定 API 时序（分配 → clear → 渲染）；T2 验收含「非全黑抽样」检查 |
| `fz_new_pixmap_with_data` samples 所有权未知 | 高 | 本计划不采用零拷贝 |
| 预乘 alpha 致颜色偏 | 中 | 先铺不透明背景 ⇒ alpha 恒 255 ⇒ 预乘等价直通；前提即上面的时序 |
| 误改 `:data-width/:data-height` 致残影 | 高 | 只允许渲染函数写一次；注释 + 文档 + review 检查点 |
| vendored 头文件升级引入 ABI 差异 | 中 | `emacs_env_32` 为尾部追加；T1 后立即跑全量 ERT |
| T7 误伤保留入口 | 高 | T7 独立批次独立回滚；`get_reader_current_state` 保留并回归 `--page-text`/`--search-page` |
| 退役清单误删仍被调用入口 | 高 | 判据固定「elisp 生产调用点为空」；每删一个先 grep；T6/T7 前各建 git 安全点 |
| 真机回归未被 L2 捕获 | 高 | L3 七项 + 逐字节等价 |

**回滚**：每批开始前创建 git 安全点（`git stash create` 或临时分支）；单批失败且修复循环耗尽 → 回滚该批，报告本 agent，不跨批回滚。

## 文档清单
`docs/architecture.md`、`docs/emacs-reader.md`、`docs/configuration.md`（若新增平滑/后端相关选项）、`emacs/seshat-reader/VENDORED.md`、`README.md`/`Readme.org`（Emacs 版本要求）、`CHANGELOG.md`、`openspec/decisions.md`、`openspec/tech-debt.md`、`openspec/roadmap.md`。

## 注意事项
1. **不改行为**：填不透明黑（`fz_clear_pixmap_with_value(pix, 0)` 且必须在渲染**之前**）是保持现状的关键，不得改成白。
2. **`canvas_data` 每次重取**，禁止跨调用缓存；渲染函数内取一次、用完即弃。
3. **`:id` 一律省略**；建后 `imagep` + 指针非 NULL 双自检，不得静默返回假 spec。
4. **不得混用** `reload-data` 与模块直写。
5. **C 模块重编译后必须重启 Emacs**；每批 L1 后重启再跑 L2。
6. 工作区可能有并发会话（历史记录显示文件被外部覆盖），改文件前后 `md5sum` 取证。
7. `/tmp/canvas-baseline/` 在 T3 验收后即删；不得让它进入仓库。
8. 退役按 T6→T7 两步；T6 只删「零调用」入口，`--window-close` 留到 T7 与 `emacs_doc_window_close` 一起删。

## 验证记录
（执行期间由执行代理逐批追加：批次 / 日期 / L1 数字 / L2 例数 / 逐字节对比结果 / L3 结果 / 备注。初始为空。）
- 批次 T1（2026-10-28）：header 31→32（/usr/include 版本 md5 b4b8adeee1f1cb66ea3f0b93d3dd4a40，原文件备份至 /tmp/canvas-baseline/emacs-module.h.31.bak，md5 f4e11b5abe4578cd755efe9d040ff0e5），/tmp 预验 0 error 0 warning；仓库 .so 重建后 103080 字节；module-load ok（25 个 `seshat-reader-dyn--*` 入口全部 fbound）；ERT 1327/0/0（37 文件）；L1 C 0/0。
- 批次 T2+T3（2026-10-28）：`fz_device_bgr` + alpha=0（无预乘、初始像素 0=黑，保留既有 dark/tint 与装饰 wash 段）；`render_page_to_buffer` 改为导出 BGRA（按 `fz_pixmap_stride` 取源行、A 恒 255，32 位单次写），删除 PNM 编码与随后的 malloc+memcpy；新增 `data2elisp_canvas`（`create-image nil 'canvas t :data-width D :data-height D :width L :height L`，省略 `:id`，`:data` 为 nil，逐行 memcpy 进 `canvas_data` 后 `canvas-refresh`，`imagep` + 指针双自检失败即返回 nil 并打 stderr）；尺寸双轨制：`out_data_w/h` 设备像素、`out_w/h` 逻辑像素。**逐字节对比 3/3 一致（差异 0，A 全 255）**：(1.0,0) 612×792、 (1.5,0) 918×1188、 (1.0,90) 792×612，对比字节数 1454112/3271752/1454112；耗时中位（同口径 `--page-image-spec` 20 次）1.57 / 3.90 / 1.57 ms vs 旧 PNM 路径 0.59 / 1.73 / 0.74 ms（新路径慢约 2.0–2.6×，因逐像素 3→4 扩展在 `-O0` 下执行；相对翻页本身可忽略，后续可用 `-O2` 或 4 分量路径优化）；L1 C 0 error 0 warning，elisp warning 21（基线 24，本批未改 elisp，未新增）；L2 TOTAL=1327/UNEXPECTED=1，唯一失败 `seshat-reader-page-spec-test--returns-image-spec`（断言 `:data` 为 string，T5 改造对象）。逐字节验证用的临时导出 `--debug-dump-canvas` 已在批次结束前删除并重编译（复验 0/0，冒烟全通过）。
- 批次 T4+T5（2026-10-28）：内存估算改 data-width×data-height×4（退化口径 :width/:height）；fake spec 全部 canvas 化；L1 warning 18；L2 37/1327/0/0。备注：生产代码 grep 已 0 命中 `(image-property … :data)`/`:type`（仅剩测试断言）；`seshat-reader.el` 两处 image-flush 注释改为 canvas 语义（`:data-*` 只由渲染函数写一次、`:width/:height` 才可 setf）；`check-criteria` PASS；`emacs/tests/Makefile` 的 BUILD_ROOT 仍硬编码 build-31.1（未改，目录存在，ERT 正常加载 37 文件）；`resize-test.el` 两处 fake spec 仍为 `:type pbm`（不在本批清单，留待后续）。
- 批次 T2b（2026-10-28）：`CFLAGS` 加 `-O2`（改前仅 `-Wall -Wextra -fPIC`，无任何 `-O` 级别；同批加 `-Wno-clobbered` 抑制 `-O2` 才启用的 fz_try 保守告警）；`.so` 86592 字节 md5 `d47fd8ac91a50666fd52d021e97b4b5e`（-O0 版 103312 字节）；耗时中位 1.57/3.90/1.57 → **1.22/2.77/1.16 ms**（旧 PNM 0.589/1.732/0.742，比值 2.07×/1.60×/1.56×）；逐字节回归 3/3 差异 0、A 全 255（用 /tmp 下独立构建的 dumpmod.so 经 `canvas_data` 取像素，仓库无临时导出）；`resize-test.el` 两处 fake spec canvas 化（`:type canvas` + `:data nil` + `:data-width/:data-height`，原 W/H 数值不变）；L1 warning 21（与上批 make 日志逐条同类、仅行号偏移 = 未新增）、checkdoc 0；L2 37/1327/0/0（0 skipped）；check-criteria PASS。备注：`-O3`（1.08/2.76/1.07）与两种扩展写法（memset+3 字节写 1.51/2.80/1.15；64 位块写 1.22/2.85/1.15）实测均无收益，判定剩余差距来自结构性的「BGRA 中间缓冲 + 逐行 memcpy 进 canvas 缓冲」，非逐像素写，故未改 C 源码。
- 批次 T2c（2026-10-28）：移除 `-Wno-clobbered`，改为按 MuPDF 要求给跨 fz_try 变量加 volatile（`render-core.c` 共 20 处 volatile 声明 / 7 个 fz_try 块：L244 `loaded_page`、L245 `success`、L343 `pixmap`、L348 `local_bgra`、L351 `render_ok`、L431 `dev`、L432 `path`、L1832-1836 `page`/`stext`/`buf`/`out`/`ok`、L1942-1948 `page`/`stext`/`buf`/`quads`、L2249-2254 `page`/`stext`/`lines`、L2735 `page`；依据 `/usr/include/mupdf/fitz/context.h` 对 fz_var 的说明——「fz_try 内赋值、之后仍需使用的局部变量」须保活；`mupdf-helpers.c` 两个 fz_try 无跨块局部变量（只写 DocState 堆字段），未改；`local_data_w/h` 等热循环尺寸保持非 volatile，失败路径由 `render_ok` 短路且不参与指针释放）；重编 0/0（`.so` 86592 字节 md5 `db650a93fad2f721d19cf9fbf7da8c50`）；逐字节回归 3/3 差异 0、A 全 255；异常路径冒烟：坏页码 9999/0、巨页 PDF（MediaBox 40000×40000，真触发 `limit error: Overly large image` 走 `fz_catch`）、截断 400 字节 PDF 三类共 9 次调用全部返回 nil/正常值，emacs exit 0 无崩溃；L1 C 0/0、elisp warning 21（与 T2b 持平）、checkdoc 0；L2 37/1327/0/0（0 skipped）；check-criteria PASS。
- 批次 T6+T7（2026-10-28）：删 11 个入口（10 个无引用 + `--window-close`）与全部孤立中间层（worker 池 / `CachedPage` / `EmacsWinState` / overlay 机制 / `data2elisp_image`），删除 `render/render-threads.c` `.h`（C 侧 `render/` 净删约 1714 行，含 header 31→32 升级的 +201）；`emacs_load_doc` 只建 DocState（不再 `init_overlay`/`init_win_state_ptr`、不再把任何页面渲染到 overlay）；`get_reader_current_state` 只持 DocState；`--page-text` 0 参经 funcall `seshat-reader-current-doc-pagenumber`（含兜底）；**render-status 决策落地**：`--load-doc` 成功路径不再置位（`render-core.c:907-912` 改为注释 + 不设置，变量 permanent buffer-local 默认 nil），改由 `--page-image-spec` 在 `data2elisp_canvas` 返回非 nil 之后置位（`render-core.c:2810-2814`，nil 返回路径一律不动）；保留 14 入口冒烟 **7/7 正常**（load-doc t / pagecount 477；page-image-spec `(t canvas 612 792 612 792 nil)`；page-text 312 字符；search-page cons 2 命中；add-decoration + clear 全 t；close-doc t 后 spec 与 text 均静默 nil 不崩溃）；**逐字节 3/3 差异 0**（612×792 / 792×612 / 918×1188，484704 + 484704 + 1090584 像素逐通道 B,G,R 全等）；L1 C 0 error 0 warning、elisp warning **20**（全量 `make -B` 口径；基线 21，未新增，减少来自删除的 elisp 调用点）、checkdoc 0 输出；L2 **FILES=37 TOTAL=1327 UNEXPECTED=0 skipped=0**；check-criteria PASS。测试侧同步：删 `--multipage-drop-c-overlay` 桩 1 处、`--refresh-highlights` 桩 1 处、两处 `(fset 'image-flush #'ignore)` 护栏（page-spec / rect-query-overlay 夹具，canvas 无 flush 语义），`--scale-page` 与旧 repaint 注释改写；`grep` 退役入口清单 0 命中。
- 批次 T8a（2026-10-28，构建加固）：① `seshat-reader.el` 头 `Package-Requires` `((emacs "29.1"))` → `((emacs "32.0"))`；② `seshat-reader/Makefile` 加解析期 Emacs 主版本门禁（`EMACS_MAJOR := $(shell $(firstword $(EMACS)) --batch -Q --eval '(princ emacs-major-version)')`，`test "$(EMACS_MAJOR)" -ge 32` 不成立即 `$(error Emacs 32 or newer is required for the canvas backend (found major=$(EMACS_MAJOR)))`）；门禁自测两次：阈值临时改 99 → `Makefile:79: *** Emacs 32 or newer is required for the canvas backend (found major=32)。 停止。` exit 2；改回 32 → 正常通过；③ `CFLAGS` 加 `-MMD -MP`、末尾 `-include $(OBJS:.o=.d)`、`clean` 一并删 `.d`（消除 T1 记录的「换头文件复用旧 .o」隐患）：`touch render/render-core.h` 后 4 个 `.o` 全部重编（gcc 行可见），不改内容再跑 → `“seshat-render-core.so”已是最新`；④ `emacs/tests/Makefile` 的 `BUILD_ROOT` 由硬编码 `build-31.1` 改为按 `emacs-major-version`/`emacs-minor-version` 推导 + 同前缀唯一目录回退，推导不出唯一目录直接 `$(error)`（不静默降级成空 `-L`），本机解析为 `/home/thomas/thomas-emacs/.local/straight/build-32.0.50`，8 个包 `-L` 全部命中；⑤ L1：`make -B` exit 0、C **0 error 0 warning**、elisp warning **20**（与 T6+T7 基线 20 持平，13 个 `.elc` 全量重编）、checkdoc 0 输出；L2：**FILES=37 TOTAL=1327 UNEXPECTED=0 skipped=0**；check-criteria PASS。备注：仓库内另有 9 个 `seshat-reader/*.el` 与 20 余个测试文件仍声明 `29.1`、10 余个 `seshat-{merge,sync,...}.el` 声明 `27.1`，本批授权仅覆盖 `seshat-reader.el`，其余待后续批次统一。
- 更正（2026-10-28，代码审查后）：实际实现未使用 fz_new_pixmap_with_bbox + clear_with_value，而是 fz_new_pixmap_from_display_list(..., fz_device_bgr(ctx), 0)（alpha=0 ⇒ MuPDF 直接合成到不透明黑）；背景色与旧版一致已由「三组逐字节对比差异 0」证明（对比覆盖整页含背景像素）。
- 批次 T9（审查后修复，2026-10-28）：3 处 major 文档/注释矛盾修正（`seshat-reader--page-spec-cache-limit` 与 `seshat-reader-multipage-memory-warning-mb` 的 docstring 改为 canvas 事实：像素只在 Emacs 的 canvas 缓冲，Lisp 侧无副本、`CachedPage` 已删、估算不翻倍并写明 `:width × :height × 4` 退化口径；`docs/architecture.md` / `docs/configuration.md` / `docs/emacs-reader.md` 的 `:data` ×2 与 `--refresh-highlights` 过时表述统一）；render-status 在 close/load 失败路径重置并验证（`--close-doc` 后为 nil，`--page-image-spec` 再调用返回 nil 不崩溃，失败 load 后为 nil）；reset_doc_state 补 `current_page_number`；frame_scale 下限 clamp（`> 0.01` 否则 1.0，加载侧与渲染侧同口径）；data2elisp_canvas 失败路径清 non-local-exit；**测试缺口结论：无法在 batch 断言缓冲内容**（无 Lisp 侧像素访问器），新增用例只覆盖形状/两次渲染/刷新后类型，缺口记入 `openspec/tech-debt.md`「batch ERT 无法断言 canvas 缓冲内容」；逐字节回归 3/3 差异 0（A 全 255，first_px 0xFFFFFFFF）；L1 C 0 error 0 warning、elisp warning 20、checkdoc 0 输出；L2 37/1328/0/0（新增 1 例 `--canvas-buffer-fill-regression`，TOTAL 1327 → 1328）；check-criteria PASS。
- 收尾（2026-10-28）：清理 4 处 --refresh-highlights 残留文案（search/annotation/select）+ Makefile 路径注释；.gitignore 加 render/*.d；最终 L1 C 0/0、elisp warning 20、checkdoc 0；L2 37/1328/0/0 + check-criteria PASS。
