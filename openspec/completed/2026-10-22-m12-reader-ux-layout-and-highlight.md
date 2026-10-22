# M12 Emacs 阅读器：左右分栏版式 · 目录导航 · 批注页面高亮 · 跨页衔接 · 引用闭环

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成（2026-10-22）**
- 已确认：方案 ✅、计划 ✅（用户 2026-10-22 确认）
- 用户确认的范围：① 目录中文乱码修复 ② 左右分栏（左目录 / 右批注等信息）③ 目录美化 + avy 式跳转 ④ 批注 rect 页面高亮 ⑤ 翻页/滚动保留上页末行 ⑥ `seshat:` 引用补全与导出 + 摘录按位置插入
- 分批：P1（版式与目录，需重建 C）→ P2（渲染层：高亮 + 跨页衔接，需重建 C）→ P3（引用闭环，纯 elisp）→ P4（文档与归档）
- 左目录策略：**常驻左侧，`C-c C-o` 收起**（用户确认）
- 跨页衔接策略：P2 先做 PoC（PBM + `:slice` + 行高 + vscroll 四件事，约 30 分钟）；PoC 失败自动降级为「翻页落点定位到页面 1/3 处」并在报告中说明，不追加询问
- 审查：plan-reviewer 独立审查 ✅（2026-10-22，0 blocking / 3 major / 8 minor，修订已全部应用）
- 审查：code-reviewer ✅（0 blocking / 4 important）+ security-reviewer ✅（0 高危 / 3 中危）；C 侧加固已完成（T15 前）；elisp 侧 3 important + 3 minor 修复已完成（location 双上限 / sidebar 方向感知记忆 / 跨文档守卫 / 高亮提示一次 / headline 双守卫 / vscroll 非 clamp 回归测试），ERT 271 用例 0 unexpected
- 下一步：已归档到 openspec/completed/；残余视觉项待用户目视（不阻塞归档）；git commit 由用户决定时机
- P1 进展：T1 ✅（L1+L2 通过，中文乱码已修，imenu 与目录标题 1182/1182 一致）、T2 ✅（sidebar 支持 left/right，ERT 39→39 全绿）、T3 ✅（per-kind 多面板共存：左目录 / 右信息 / 中间阅读区三栏可并存；`--slot-for-kind` 按 kind 分槽、`--display` 只重建目标 kind、`toggle` 支持可选 kind、`C-c C-o` 开合目录；`seshat-reader-sidebar-position` 默认由 `below-selected` 改为 `right`（破坏性变更）；ERT 39→50 全绿）；T4 ✅（目录面板接入 sidebar 承载层：`seshat-reader-outline-show` 改经 `seshat-reader-sidebar-show <buf> 'outline`（禁用时由 sidebar-show 自身回退 `pop-to-buffer`，无循环依赖）；修复 F17 刷新缺陷——每次 show 都按当前文档 `erase-buffer` + 重建（`inhibit-read-only`、复用既有 mode、不 kill buffer）并刷新 `--doc-buffername` / `--doc-window`，无目录时先校验不清空；新增 `emacs/tests/seshat-reader-outline-test.el` 5 用例，L1 0 error / 34 warning 不变、L2 新测试 5→0 unexpected 且 0 skipped、其余 6 个测试文件 0 unexpected 无回归）；L3 真机目视待 P1 收尾统一验收；T5 ✅（目录面板美化 + 行模型纯函数化：新增纯函数 `--rows` / `--current-path`（DFS 前序行 plist、page 1-based、折叠子树剔除、当前章标记），渲染函数改为消费行列表——行首保留 `outline-regexp` 星号前缀 + 每级 2 空格 + `▾`/`▸` + 三级 face + 页码 `(space :align-to (- right 6))` 右对齐 + 当前章 `line-prefix` 竖线；新增 5 个 face；`show` 恢复 SELECT=`t`；L1 0 error / 34 warning（outline.el 0）；L2 outline 5→10 用例 0 unexpected / 0 skipped，其余 6 个文件无回归；未做 L3）；T6 ✅（avy 式单键跳转：目录面板内按 `f` → 可见行显示 1-2 字符标签 → 按键跳页。**实读本机 avy 源码后判定不复用**——`avy-process`（`avy.el:868`）的标签渲染由全局 `avy-style` 经 `avy--style-fn`（`:1254`）决定（设为 `ignore` 即不显示标签），并依赖 `avy-background` / `avy-pre-action` / `avy-action`；`avy-read`（`:509`）依赖 `avy-translate-char-function` / `avy-handler-function` 且树须由 `avy-tree`（`:400`）生成，两条都不满足「稳定、自包含」，故按计划走零依赖兜底、仅借 `avy-keys` 字符表。新增命令 `seshat-reader-outline-avy-jump` + 键位 `f`（不占 `p`/`n`/`o`/`q`/`RET`/`M-RET`）+ 两个纯函数 `--avy-labels (n &optional keys)`（n≤0 → nil；n≤keys 长度 → 单字符；更多 → 先 key1 再 key2 的等长双字符，覆盖 len² 个候选、无前缀冲突）+ `--avy-candidates (start end)`（区间内带 `seshat-reader-page` 的按钮 → `(POSITION . PAGE)`；`next-button` 需传 COUNT-CURRENT=t，否则起点落在按钮首字符上的那个会被跳过）+ 内部 `--avy-keys` / `--avy-read`；标签用 overlay `before-string`（不写 buffer 文本），`unwind-protect` 清理段删除全部 overlay（quit 中断同样清理）；新增 face `seshat-reader-outline-avy-label-face`（显式配色，不继承 `avy-lead-face`）；未引入依赖、未改 `Package-Requires`。L1 `rm -f *.elc && make all` 0 error / 34 warning（outline.el 0）；L2 outline 10→14 用例 0 unexpected / 0 skipped，其余 6 文件 0 unexpected（etaf 14 / translate 2 skipped 为既有可选依赖跳过）；**未做 L3**（真机按键交互留 P1 收尾验收，另记 tech-debt「目录折叠符号不与 TAB 联动」）；**P1 代码完成，待 L3 真机验收**
- P2 进展：T7 ✅、T8 ✅、T9 ✅、T10 ✅（批注高亮闭环代码完成，待 L3 真机）（T7 PoC 3 判据全过；T8 跨页衔接：T8a strip 静态结构 + T8b 翻页落点与页首语义；T9 C 层 rect 高亮绘制与导出函数：`DocState` 高亮表 + `DrawThreadArgs` 每页快照 + `--add-highlight` / `--clear-highlights` / `--refresh-highlights`，缓存失效取「标志 + 显式 refresh」策略，L1 0 error / C 0 warning / elisp 34 warning 不变，L2 batch 四条断言全过、绘制分支实测执行；T10 elisp 侧同步：`--rects-from-location` 解析 + `--apply-highlights` 全量投喂（clear → add × N → refresh）+ defcustom `seshat-reader-annotation-highlight-enabled` + 命令 `seshat-reader-annotation-refresh-highlights`（`C-c C-h`）+ 两处零新增请求的挂接点（拉取成功分支、新建成功分支增量追加），并复核修复 T9 遗留断言：`rect_to_page_space` 归一化前调 `fz_is_valid_rect` 使逆序角点被判非法（实现缺陷，已改为先归一化再校验，实测逆序 rect 现返回 t）；L1 0 error / C 0 warning / elisp 34 warning（annotation.el 0），L2 annotation 30→40 用例 0 unexpected / 0 skipped + 其余 7 文件 0 unexpected；真机高亮效果留 P2 收尾 L3）
- P3 进展：T11 ✅、T12 ✅、T13 ✅、T14 ✅（引用闭环完成）
- T16 进展（L1/L2 已完成，2026-10-22）：C 0 error / 0 warning；elisp 0 error / 34 warning（与基线一致，三个自研文件均 0）；ERT 271 用例 **0 unexpected / 0 skipped**（八个测试文件全绿）
- T16 附带修复：Makefile 的 ETAF 探测改两级（源码树 wildcard → straight build 回退，修正 WorkSpace/Workspace 大小写不符，etaf.el 现已参与编译且 0 warning）；etaf-test 一处长期假绿列宽断言（`▌ p.12` → `▌  p.12`）；测试临时目录改 /tmp（根因是 TMPDIR 被设为仓库根）

## 目标

把 Emacs 阅读器从「能翻页看书的 image 浏览器」补成「有版式、目录可导航、批注可见、跨页连续、引用可闭环」的阅读工作台：

1. **修复目录中文乱码**（当前中文标题显示为 `\346\226\207` 这类八进制转义）。
2. **左右分栏版式**：左侧目录面板、右侧批注/译文/解释面板、中间阅读区，三者共存不互相挤压；保留底部面板作为兼容选项。
3. **目录面板可用且好看**：层级缩进、折叠、页码对齐、当前章节高亮、avy 式单键跳转、内容随文档切换刷新。
4. **批注 rect 在页面上可见**：页面渲染时按 `page:<n>;rect:...` 绘制半透明高亮，缩放/旋转自动对齐。
5. **跨页衔接**：翻页/滚动跨页时保留上一页最后一行作为上下文。
6. **引用闭环**：`seshat:` 链接支持 `:complete` 补全与 `:export` 导出；摘录不再一律追加文件末尾，而是按 headline / 光标位置插入。

## 背景与关键事实

以下结论均有代码证据（探索阶段确认），实施时不得凭记忆推翻：

| # | 事实 | 证据 |
|---|---|---|
| F1 | 目录乱码根因：outline 标题用 `make_unibyte_string` 包 UTF-8 字节 | `emacs/seshat-reader/render/elisp-helpers.c:555-556`；`fz_load_outline` 在 `render/mupdf-helpers.c:134`；`outline2plist` 调用在 `render/render-core.c:540` |
| F2 | 同一模块的 `page-text` / `text-in-rect` / `message` 用 `make_string`（自动 UTF-8 解码），**不**乱码 | `render/render-core.c:1230-1232`、`:1395-1397`；`render/elisp-helpers.c:466` |
| F3 | `env->make_unibyte_string` 产出 unibyte 串，Emacs 显示为八进制转义 | Emacs 模块 API 语义 + `doc/lispref/nonascii.texi:88-89` |
| F4 | 选区文本 → 批注 `text` → 服务端 JSON 的链路**已经正确**（multibyte），不得在 elisp 侧二次 decode | `seshat-reader-select.el:227-233` → `seshat-reader-annotation.el:283` → `seshat-rest.el:92` |
| F5 | elisp 层**无法**在已有 image 上叠加半透明矩形（overlay `display` 互斥） | `osespec/completed/2026-10-12-m11.2b-reader-selection.md:25`；`seshat-reader-select.el:60-63` |
| F6 | C 层当前零绘图能力（全 render/ 目录 `fz_new_draw_device` 等 0 命中） | 探索结论（grep 零命中） |
| F7 | 高亮绘制的插入点：`draw_page_thread` 内 pixmap 生成（`render-core.c:175`）→ 反色（`:178-182`）→ 写 PNM（`:188`），应在反色之后绘制 | `render/render-core.c:175-188` |
| F8 | 渲染 ctm 为 `fz_transform_page(bbox, resolution, rotate)`，`resolution = scale * 72`（clamp 18–850） | `render-core.c:158-160`、`:950` |
| F9 | `rect` 坐标系为**页面点坐标**（PDF point 空间，原点左上、y 向下，不含缩放），Android 端归一化坐标是本地表示 | `docs/api.md:330-332`、`:352-354` |
| F10 | 上一页位图在 C 层保留（±5 页缓存窗口） | `render/render-core.h:27-28`、`render-core.c:334-339`、`:361` |
| F11 | 负 vscroll 在 Emacs 中不生效（负值按 0 处理）；`seshat-reader-scroll-up` 的「到页首」行为正依赖此点 | `(elisp)Vertical Scrolling`；`seshat-reader.el:436-448`、`:521-524` |
| F12 | 页面 image 由 C 侧 `create-image DATA 'pbm t :width W :height H :scale 1` 生成，无 `:slice` / `:ascent`；通过 per-window overlay 的 `display` 显示 | `render/elisp-helpers.c:152-164`、`:501-527` |
| F13 | 阅读窗口尺寸变化会自动重算居中（`window-size-change-functions` → `--center-page`），左右分栏无需额外 resize 钩子 | `seshat-reader.el:928`、`:411-430` |
| F14 | 现有面板走 `display-buffer` + `display-buffer-overriding-action`，位置仅 `below-selected` / `at-bottom`；切换 kind 会删除全部面板窗口再重建 | `seshat-reader-sidebar.el:74-81`、`:297-306`、`:346-352` |
| F15 | 面板尺寸/记忆全是高度语义（`window-height`、`window-total-height / frame-height`） | `seshat-reader-sidebar.el:83`、`:92`、`:100`、`:199`、`:272` |
| F16 | 目录面板走 `pop-to-buffer`，不受 `sidebar-enabled` / `position` 管辖 | `seshat-reader-outline.el:85`（tech-debt 已记「包内窗口语义不统一」） |
| F17 | 目录面板内容只在 buffer 为空时写入，文档切换后不重建 | `seshat-reader-outline.el:76-84` |
| F18 | 目录跳转基于 `insert-text-button` + `'action`，`button-at` / `next-button` 均已内置可用 | `seshat-reader-outline.el:97-104`、`:138-154` |
| F19 | avy 在本机已加载（`featurep 'avy` = true），但源码不在本仓库，API 须实读 | elisp-dev-mcp 实测 + 仓库 grep 零命中 |
| F20 | 本项目软依赖惯例：不进 `Package-Requires`，运行时探测后静默降级 | `seshat-reader-translate.el:339-346`、`:310-317`；`seshat-reader-etaf.el:123-140` |
| F21 | `seshat:` 链接只注册 `:follow` / `:store`，缺 `:complete` / `:export` | `seshat-reader-reference.el:299-301` |
| F22 | 摘录一律追加到文件末尾（`point-max`），不识别 headline / 光标 | `seshat-reader-reference.el:196-215` |
| F23 | 改 C 源必须同步 `VENDORED.md` 的本地改动清单（仓库不变量） | `emacs/seshat-reader/VENDORED.md:45` 附近 |
| F24 | 目录 buffer 名为动态 `*Outline of %s*`，而 `sidebar-buffer-p` 按名字精确 `member` 匹配 | `seshat-reader-outline.el:76`、`seshat-reader-sidebar.el:355-368` |

## 设计

### D1 版式：side window 三分栏

- `seshat-reader-sidebar-position` 扩展取值：`left` / `right`（新增），保留 `below-selected` / `at-bottom`（兼容）。
- 实现方式：`--display-params` 按方向返回 `(display-buffer-in-side-window (side . left|right) (slot . N) ...)`，**不自己 `split-window`**——side window 由 Emacs 维护独立窗口树，同侧同 slot 复用，三栏共存时阅读区不会逐次变窄（F14）。
- 尺寸语义抽象：新增方向感知的取/存函数（宽 vs 高），`seshat-reader-sidebar--state` 的 per-kind 记录按方向存宽度比例或高度比例。
- 新增 defcustom：
  - `seshat-reader-sidebar-width`（默认 `0.24`，右侧信息栏宽度比例）
  - `seshat-reader-outline-sidebar-width`（默认 `0.20`，左侧目录宽度比例）
  - 保留现有 `-height` / `-min-height` / `-max-height` 供底部模式使用
- per-kind 多窗口：`outline` / `annotations` / `translate` 各占独立窗口。`same`-kind 判定从「只看 `(car windows)`」改为按 kind 查找既有窗口；`seshat-reader-sidebar-toggle` 增加可选 `kind` 参数（无参时保持现有「全部关闭」语义）。
- `seshat-reader-sidebar-buffer-p` 从精确 `member` 改为「精确匹配两个常量名 + 正则匹配 `\\`\\*Outline of .*\\*\\'`」（F24）。
- 阅读区居中由既有 `window-size-change-functions` 钩子自动重算，不新增钩子（F13）。
- popper 分流同步：`seshat-reader-sidebar-display-buffer` 目前按 buffer 名二分 `translate`/`annotations`，接入 `outline` kind 后必须同步支持 outline，否则 popper 重开目录会被误判成批注面板。
- side 模式停用高度自适应：left/right 下 `--fit-height-for-content`（垂直语义，按内容行数调窗高）必须停用；translate 面板在 side 模式下按固定宽度、高度占满 frame。只有底部模式（below-selected / at-bottom）保留该行为。

### D2 目录面板：美化 + avy 跳转 + 刷新

- 接入承载层：`seshat-reader-outline-show` 改为 `seshat-reader-sidebar-show buf 'outline`，sidebar 禁用时回退 `pop-to-buffer`。
- 刷新缺陷（F17）：显示前总是重建内容（或按 `--doc-buffername` 比对后重建），并同步 `--doc-buffername` / `--doc-window`。
- 美化（全部纯 elisp、零新依赖）：
  - 层级：每级 2 空格缩进 + 折叠态符号（`▾` 展开 / `▸` 折叠；无子节点不显示符号）。
  - 页码：右对齐，用 `(space :align-to (- right <N>))` display 属性；页码 face 弱化（`shadow` 或自定义 face）。
  - 标题：按层级使用 `seshat-reader-outline-level-1-face` / `-level-2-face` / `-level-3-face`（3 级之后复用 3 级）。
  - 当前章节：按当前页码定位「包含该页的最深节点」，用 `seshat-reader-outline-current-face` + 左侧竖线（`(:box (:line-width ...))` 或 `before-string "▌"`）。
  - 折叠：沿用 `outline-mode` 的 `TAB`（`outline-regexp "^\\*+ "` 不变），美化不得破坏 `outline-hide-subtree` 等命令。
- avy 式跳转：
  - 新命令 `seshat-reader-outline-avy-jump`，绑定 `f`（目录面板内，避开 `n`/`p`/`RET`/`M-RET`/`o`/`q`）。
  - 优先复用 avy：`(require 'avy nil t)` 后**必须先实读本机 avy 源码确认 API**（EE-1：不得凭记忆调用 `avy-jump` / `avy-process`）；候选为当前可见区间内的按钮位置。
  - 兜底：零依赖实现（`window-start` / `window-end` 取可见区间 → `next-button` 收集 → 自维护标签字符表 → overlay `before-string` → `read-key` 循环 → 命中后 `goto-char` + 激活按钮）；`unwind-protect` 内清理 overlay。
  - 两条路径都不得写入 buffer 文本（overlay only）。

### D3 批注 rect 页面高亮（C 层绘制）

- 数据：`DocState` 增文档级高亮表 `{page_num, fz_rect, color, alpha}`；因渲染线程在克隆 ctx 中运行且 `DocState` 无 mutex（F7 上下文），**必须**在派发渲染任务时把高亮快照拷入 `DrawThreadArgs`（`render/render-threads.h:52-58`）或加锁，禁止渲染线程直接读可变表。
- 绘制位置：`draw_page_thread` 内 `fz_invert_pixmap_luminance`（`render-core.c:178-182`）**之后**、`fz_write_pixmap_as_pnm`（`:188`）**之前**；用 `fz_new_draw_device(ctx, ctm, pixmap)` + `fz_add_rect` + `fz_fill_path(..., alpha)` + `fz_close_device`，与页面共用同一 `ctm`（F8），缩放/旋转自动对齐。
- 导出模块函数（沿用现有标量传参风格，参考 `render-core.c:1489` 的 5 参注册）：
  - `seshat-reader-dyn--set-highlights`：接收「页号 + 扁平 float 数组 + 颜色 + alpha」或逐条 `--add-highlight (page x0 y0 x1 y1)`，二选一以代码简洁者为准；实施时在计划执行记录里说明最终签名。
  - `seshat-reader-dyn--clear-highlights`（0 参）。
- 缓存失效：新增/清除高亮后必须 `wait_for_win_jobs` → `nullify_window_cache` → `build_cache_window` → 重显示（参考 `emacs_redisplay_doc`，`render-core.c:671-704`），否则已缓存的 ±5 页仍是旧位图。
- elisp 侧：
  - 新增 `seshat-reader-annotation--rects-from-location`（解析 `;rect:x0,y0,x1,y1`，容错、返回 nil 表示无 rect）。
  - 打开文档 / 批注数据变化 / 手动刷新时，把该文档**所有**批注按页聚合成高亮表喂给 C；只在当前页变化时不做全量重传（以页为粒度增量）。
  - 新增 `seshat-reader-annotation-highlight-enabled`（默认 `t`）与颜色/透明度配置（默认半透明黄，alpha 约 0.35）。
  - ink 形态（`;ink:`）**本期不渲染**，仅在 tech-debt 记录「Emacs 端仍不显示手写笔迹」。
- y 轴方向：`docs/api.md` 约定 `rect` 为「原点在左上、y 向下」，而 MuPDF 页面坐标系原点在左下。绘制时必须复用 `emacs_text_in_rect`（`render/render-core.c:1265` 起）中已有的 y 翻转换算，否则高亮会上下镜像。实现前先读该函数的坐标处理，不得自行推导。
- 已知限制（写进文档，不在本期修）：旋转页的 `rect` 坐标本就采不准（`seshat-reader-select.el:53-56`），高亮在旋转页可能错位。

### D4 跨页衔接：保留上一页末行

- 前提 PoC（先行）：验证 ① C 侧 PBM 生成的 image spec 是否支持 `:slice` 裁出底部 strip；② image 行的行高与 `:ascent` 缺省行为；③ 在 buffer 当前页 image 之前插入一行 strip 后 `set-window-vscroll` 的定位精度；④ 该行为是否被 `--center-page` 的 `line-prefix` hack 破坏。
- 通过则实现（路线 A）：
  - 在显示当前页的 overlay 之前插入一行「上一页底部 strip」的 image（`display` 属性 + `:slice`），strip 高度取「上一页最后一行」的可配置像素/行高（新增 `seshat-reader-page-join-lines` 默认 1，`0` 关闭）。
  - 翻页顺序调整：新页显示后先把窗口定位到 strip 行、设**正** vscroll 使 strip 恰好占满一行，而不是 vscroll 归零（F11：不能依赖负 vscroll）。
  - 页面 image 的几何语义（`--get-current-doc-image-size`、`--set-window-vscroll` 的 clamp）**保持不变**，strip 行的高度不计入页高。
  - 书签保存的 `vscroll` 语义随之变化（页首 vscroll ≠ 0），需在 `seshat-reader-bookmark.el` 恢复逻辑里扣除 strip 高度。
  - 滚动边界重定义：`scroll-up` 到 strip 顶部视为「页首」，再往上滚才翻上一页。
- PoC 失败则降级：翻页后把 vscroll 定位到「页面 1/3 处之前」的弱化衔接（无上一页内容，只减少突兀感），并在报告与 tech-debt 中说明未达成原目标。

### D5 引用与导出闭环

- `:complete`：`org-link-set-parameters "seshat"` 增加 `:complete`，候选来源 = `seshat-reader-annotation-roots` 下的文件清单（doc-id 形态）；若当前上下文能确定 location，可补 `#page:<n>`。**不引入 uid 补全**（服务端 uid 目录需网络，超出本期）。
- `:export`：注册 `:export`，把 `[[seshat:<doc-id>#<location>]]` 导出为人类可读文本（`<文件名> 第 N 页`）或 org 脚注，具体形态在实现时按 `org-export` 的惯例二选一并记录。
- 摘录定位（不再固定末尾）：`seshat-reader-reference-insert` 增加前缀参数语义：
  - `C-u` 保持现有「读正文」语义不变；
  - 新增交互式选择插入位置：目标文件 + headline（`org-goto` / 补全 headline 标题）+ 插入点（headline 末尾 / 光标处）；
  - 无 visiting buffer 时仍用 `append-to-file` 语义但定位到指定 headline 末尾。
- 顺手修：`--parse-link` 对尾部 `#` 返回空串 location → 归一为 `nil`。

### D6 兼容、降级与文档不变量

- 所有新增能力都必须可关闭：`seshat-reader-sidebar-position` 回 `below-selected` 恢复旧版式；`seshat-reader-annotation-highlight-enabled` 为 nil 时零 C 调用；`seshat-reader-page-join-lines` 为 0 时关闭跨页衔接；avy 缺失时用兜底实现。
- 改 C 文件必须同步 `VENDORED.md` 的本地改动清单（F23）。
- 所有 vendored elisp 文件的改动也要在该清单登记。
- 新增软依赖（avy）不进 `Package-Requires`，按 F20 的探测-降级范式实现，并在 `docs/configuration.md` 登记。

## 任务

### P1 版式与目录（需重建 C）

- [x] **T1 修复目录中文乱码**：`render/elisp-helpers.c` 的 outline 标题构造改为 UTF-8 安全（保留 `make_unibyte_string` 后调 elisp `decode-coding-string 'utf-8`，或改 `make_string` 并用 `condition-case` 兜底非法字节；二选一需在报告中说明选择依据）。同步 `VENDORED.md`。验收：`make clean all` 无 error；加载 `.so` 后打开含中文目录的 PDF，`seshat-reader-current-doc-outline` 中 `:title` 满足 `(multibyte-string-p title)` 且能匹配中文字符；目录面板与 imenu 显示正常；imenu 路径同样验收（`seshat-reader-outline--outline-imenu-create-index` 产出的 title 与目录 buffer 显示一致，不得一条对一条错）。（依赖：无）
- [x] **T2 sidebar 支持 left/right side window**：扩展 `seshat-reader-sidebar-position`；`--display-params` 按方向返回 `display-buffer-in-side-window`；新增宽度 defcustom 与方向感知的尺寸取/存；`--buffer-p` 支持 outline buffer 名正则。验收：ERT 覆盖「位置 → display params / 尺寸读写键」的纯逻辑；L3 真机确认左右栏不挤压阅读区。（依赖：无）
- [x] **T3 per-kind 多面板共存**：kind→窗口映射，三栏共存；`sidebar-show` 增 kind 复用逻辑；`sidebar-toggle` 增可选 kind 参数。同时在本任务完成键位绑定：`seshat-reader-mode-map` 增加 `C-c C-o` → `seshat-reader-sidebar-toggle`（携带 `outline` kind）；保留 `o` → `seshat-reader-outline-show` 不变。验收：L3 依次打开 outline + annotations + translate 三栏共存，关闭其中一个不影响其余；ERT 覆盖 kind 查找与状态记录；按 `C-c C-o` 能收起左侧目录、再按一次展开。（依赖：T2）**✅ 2026-10-22 完成**：采用方案 a（新增 `seshat-reader-outline-sidebar-position` 默认 `left`，其余 kind 跟随 `seshat-reader-sidebar-position`，默认改为 `right`——破坏性变更）；`--slot-for-kind` 按 kind 分槽（同侧 0/1/2、不同侧各自从 0）；`--display` 只重建目标 kind；`toggle` 支持可选 `kind`（nil 保持全部开合）；`C-c C-o` → 新命令 `seshat-reader-sidebar-toggle-outline`（在 sidebar.el 内用 `with-eval-after-load` 注册）。L1 0 error（sidebar 0 / reader 32 warning 不变）；L2 sidebar ERT 39→50 全绿，其余 5 个测试文件无回归。**注意**：目录面板当前仍由 `seshat-reader-outline-show` 经 `pop-to-buffer` 显示（不在本包窗口集合内），故 `C-c C-o` 的端到端「收起/展开目录」要在 T4 把 outline 接入 `sidebar-show` 后才完整生效——T3 交付的是机制 + 键位 + 单测。
- [x] **T4 目录面板接入 sidebar + 刷新**：改为 `sidebar-show buf 'outline`（禁用时回退 `pop-to-buffer`）；修复「buffer 非空不重建」（F17）。验收：同一 buffer 内切换文档后目录内容更新；ERT 覆盖「不同文档 → 内容重建」判定函数。（依赖：T3）**✅ 2026-10-22 完成**：`seshat-reader-outline-show` 改经 `seshat-reader-sidebar-show (get-buffer bufname) 'outline`（`sidebar-show` 内部已在 `sidebar-enabled` 为 nil 时回退 `pop-to-buffer`，故未在调用方重复实现兜底；新增 `(require 'seshat-reader-sidebar)`，该模块零依赖 → 无循环依赖）；刷新缺陷修复：删除「只在 `(= 0 (buffer-size))` 时插入」的判定，改为**每次 show 都重建**——先校验 `seshat-reader-current-doc-outline`（无目录时 `user-error` 且不清空），再 `let ((inhibit-read-only t)) (erase-buffer)` + 重新插入 + `goto-char (point-min)`，不 kill/重建 buffer（面板窗口保持有效）、复用既有 `seshat-reader-outline-mode`，并每次刷新 `--doc-buffername` / `--doc-window`（`goto-entry` 跳页闭环仍成立，`select-doc-window` 的兜底未改）。调用签名按计划取两参（`select` 省略）：`o` 后光标留在阅读窗口、不再随 `pop-to-buffer` 移入目录面板——与 `C-c C-o` 重开路径（`toggle` 传 select=t）略有差异，如需跟随可后续调整。新增 `emacs/tests/seshat-reader-outline-test.el`（5 用例，cl-letf 桩替 `seshat-reader-sidebar-show` / `seshat-reader-goto-page` / `select-doc-window`）。验证：L1 `rm -f *.elc && make all` 0 error、34 warning 与基线逐条一致（outline.el 0 warning）；L2 新文件 5/5 通过（0 unexpected、0 skipped），其余 6 个测试文件 0 unexpected（etaf 14 skipped / translate 2 skipped 为既有可选依赖跳过，未受本次改动影响）；未做 L3。VENDORED.md 已补 `seshat-reader-outline.el` 条目。
- [x] **T5 目录面板美化**：重构前提：先把 `seshat-reader-outline--outline-insert-outline` 里的格式化逻辑抽成纯函数（入参：outline 树 + 折叠态集合 + 当前页；出参：行列表，每行含 depth / 折叠符号 / 标题 / 页码 / 是否当前章），buffer 插入只消费该行列表——否则本任务的 ERT 无法在 batch 下测。层级缩进 + 折叠符号 + 页码右对齐 + 三级 face + 当前章节高亮（含左侧竖线）。验收：ERT 覆盖上述纯函数行模型（含折叠态、页码对齐 offset、深度、当前章标记）；L3 真机目视确认对齐与配色。（依赖：T4）**✅ 2026-10-22 完成**：实际函数名沿用文件既有命名（无 `outline--` 双段前缀）——纯函数 `seshat-reader-outline--rows (tree collapsed current-page)`（行 plist `(:depth :title :page :collapsed-p :current-p :has-children)`，DFS 前序、page 1-based、根 depth 0、折叠子树不出现）与 `seshat-reader-outline--current-path (tree current-page)`（最深包含节点的标题路径；折叠态集合元素同为「行路径」，可区分同名节点），共用遍历原语 `--map-tree`；渲染函数 `seshat-reader--outline-insert-outline` 签名由 `(outline level)` 改为 `(rows)`，行首保留 `outline-regexp` 星号前缀（TAB 折叠不破）+ 每级 2 空格 + `▾`/`▸`（无子节点 2 空格占位）+ 标题按钮（face 按深度 1/2/3 级）+ 页码 `(space :align-to (- right 6))` 右对齐 + 当前章 `line-prefix` 竖线 `▌`（显示属性，非 buffer 文本，故不改缩进列/不破 outline-regexp）；新增 5 个 face（`-level-1/2/3-face`、`-page-face`、`-current-face`，均挂 `defgroup seshat-reader`，不用 variable-pitch）；`show` 增 `--doc-current-page` 适配层传当前页，并恢复 `sidebar-show` 的 SELECT=`t`（T4 遗留项）。验证：L1 `rm -f *.elc && make all` 0 error、warning 34 与基线逐条一致（outline.el 0 byte-compile / 0 checkdoc）；L2 outline 测试 5→10 用例全绿（0 unexpected / 0 skipped），其余 6 个文件 0 unexpected（etaf 14 skipped / translate 2 skipped 为既有可选依赖跳过）；未做 L3。**遗留**：目录 buffer 每次 show 都重建，`TAB` 折叠走 outline-mode 自身不可见性、折叠符号恒为 `▾`（折叠态集合恒传 nil，未做跨重建的折叠记忆）。
- [x] **T6 avy 式跳转**：新命令 + 键位 `f`；优先 avy（先实读本机 avy 源码确认 API），缺失时零依赖兜底。验收：ERT 覆盖标签生成与候选收集纯函数；L3 真机按 `f` 显示标签并跳转正确页。（依赖：T5）**✅ 2026-10-22 完成**：**实读 avy 源码后选择零依赖自实现**（`thomas-emacs/.local/straight/repos/avy/avy.el`；证据见 VENDORED.md 的 `seshat-reader-outline.el` 条目 ⑥ 与代码内注释）；`seshat-reader-outline-avy-jump` 键位 `f`；候选 = 可见区间（`window-start`…`window-end`）内带 `seshat-reader-page` 的按钮；标签 = overlay `before-string`（1-2 字符，face `seshat-reader-outline-avy-label-face`），`read-key` 逐键匹配（无匹配 → `user-error`，唯一候选 → 跳转），命中后 `goto-char` + `seshat-reader-outline-goto-entry`；`unwind-protect` 清理全部 overlay（quit 中断同样清理）；纯函数 `seshat-reader-outline--avy-labels` / `--avy-candidates`；标签表优先 `avy-keys`（未加载用内置 `(a s d f g h j k l)`）；不引入依赖、不改 `Package-Requires`。验证：L1 0 error / 34 warning（outline.el 0）；L2 outline 14 用例 0 unexpected / 0 skipped，其余 6 文件 0 unexpected；未做 L3

### P2 渲染层（需重建 C）

- [x] **T7 跨页衔接 PoC**：验证 `:slice` + 行高 + `:ascent` + vscroll 定位 + `--center-page` 兼容性（F12、F13、F11）。验收判据（三条，全部满足才算 PoC 通过，任一条失败即判定降级）：① `:slice` 能裁出上一页底部 strip 且 strip 内无整页缩放/空白残留；② 插入 strip 后 `set-window-vscroll` 定位误差 ≤ 1 个行高（用 `window-text-pixel-size` 量实际行高作基准）；③ 插入 strip 后 `seshat-reader--center-page` 仍按「页面 image 宽度」居中，不把 strip 当页图像处理、不产生水平偏移。产出物：PoC 结论表（三条判据各给实测数据 + 通过/不通过 + 最终决策）。不通过则记录降级决策并直接进 T9（T9 与 T7 无技术耦合）。（依赖：无）**✅ 2026-10-22（PoC 通过：`:slice` 生效、vscroll 误差 0 px、`--center-page` 兼容）**
- [x] **T8 跨页保留上页末行**：按 D4 实现 strip 行 + 翻页 vscroll 定位；书签 vscroll 语义同步；滚动边界重定义。vscroll 语义扩散（必须一并处理）：① 新增「页首 vscroll = strip 高度」这一常量/函数，被三处共用——`seshat-reader-fit-to-height` 末尾的 `(seshat-reader--set-window-vscroll nil 0)` 复位点、`scroll-up-or-prev-page` 里 `bottom-most-scroll-pixel` 的翻页复位计算、`seshat-reader-bookmark.el` 的 vscroll 恢复；② 「是否在页首」的判据从现在的 `(= 0 (seshat-reader-scroll-up amount))` 返回值约定改为显式谓词 `seshat-reader--at-page-top-p`，并更新全部消费点（`scroll-up-or-prev-page`、`scroll-up-screen-or-prev-page`、`mwheel-scroll-up` —— 改前先 grep 全部调用点）。验收：L3 真机翻页时上一页最后一行可见且不遮挡新页首行；`seshat-reader-page-join-lines 0` 时行为与当前完全一致；`seshat-reader-fit-to-height` 之后页面位置正确（不回退到 strip 之上）；`seshat-reader-page-join-lines` 为 0 时，上述三处（fit-to-height / 翻页复位 / 书签恢复）行为与当前版本完全一致。（依赖：T7）。**T8a ✅ 2026-10-22（静态结构完成）· T8b ✅ 2026-10-22（翻页落点与页首语义、`--at-page-top-p`、fit/缩放落点、关闭开关等价性）**
- [x] **T9 C 层 rect 高亮绘制**：`DocState` 高亮表 + 渲染线程快照 + `draw_page_thread` 绘制 + `--set-highlights` / `--clear-highlights` 导出 + 缓存失效重渲染。同步 `VENDORED.md`。与 T8 串行的理由：两者都修改 `draw_page_thread` 同一函数，串行避免同文件冲突。高亮与跨页衔接无技术耦合——T7 PoC 失败只影响 T8，T9 照常执行，不得因降级而跳过。验收：`make clean all` 无 error/warning；L3 真机在含批注的 PDF 上看到半透明高亮且位置与选区一致；暗色模式下高亮不被反色破坏。（依赖：T7 可与 T7 并行开始读代码，实现需在 T7 结论后）**T9 ✅ 2026-10-22（C 层绘制与导出函数；elisp 接入待 T10）**
- [x] **T10 elisp 侧高亮同步**：`--rects-from-location` 解析 + 按页聚合 + 触发重渲染 + `seshat-reader-annotation-highlight-enabled` 与颜色配置。验收：ERT 覆盖 rect 解析（合法/非法/缺字段/多段）；L3 新建批注后高亮即时出现、删除后消失。（依赖：T9）**T10 ✅ 2026-10-22（elisp 侧同步完成：解析纯函数 + 全量投喂 `--apply-highlights` + 开关 + 刷新命令 `C-c C-h` + 两处零请求挂接点；颜色/透明度配置本期未加——C 侧颜色为编译期常量 `HIGHLIGHT_COLOR_*`/`HIGHLIGHT_ALPHA`，改配置需新增模块函数，留 tech-debt；L3 真机待 P2 收尾）**

### P3 引用闭环（纯 elisp）

- [x] **T11 `seshat:` 链接 `:complete`**：候选来自 annotation-roots 的文件清单（doc-id 形态）+ 可选 `#page:<n>`。验收：ERT 覆盖候选生成与补全边界（含 `#`/`%` 文档名仍按既有约定报错）。（依赖：无）**✅ 2026-10-22**
- [x] **T12 `seshat:` 链接 `:export`**：导出为可读文本或脚注，形态在实现时二选一并记录决策。验收：ERT 覆盖导出函数对「有/无 location」「有/无 rect」的输出。（依赖：无）**✅ 2026-10-22**：**形态二选一取「可读文本」，不取 org 脚注**——导出函数的返回值优先于后端自身转义（`ox.el.gz:4352-4377`），脚注会在表格/标题等受限上下文里插入 `[fn:]` 引用并产生「脚注定义离正文很远」的排版噪声，而本链接本身不含可跳转目标（指向本机 PDF），用纯文本 `a.pdf 第 3 页` 更诚实。先实读 org 9.8.7 契约：`ol.el.gz:119-128`（`:export' 收四参：path / desc 或 nil / 后端符号 / 通信通道 plist；为 nil 时交回后端）+ `ox.el.gz:4352-4377`（`org-export-custom-protocol-maybe` 先 4 参、遇 `wrong-number-of-arguments` 退 3 参）；范例 `ol-doi.el.gz:47-71`、`ol-info.el.gz:181-194`。实现 `seshat-reader-reference-export-link (path desc format &optional _backend)`：DESC 优先，否则复用 `--description`；所有 FORMAT（`html`/`latex`/`ascii`/`md`/nil）输出同一份纯文本、不含裸协议串；非法 path 退回 `seshat:<path>` 不报错；**不生成假 URL**（无服务端 URL 方案，docstring 记取舍）。ERT：`--export-link` 3 个用例（有 DESC 四种 FORMAT / 无 DESC 覆盖无 location 与含 rect / 非法 path 回退 + 第 4 参透传），并翻转原有「未定制 :export」断言为「已注册」。L1 0 error / 34 warning（reference.el 0）；L2 reference 35→49 用例（新增 14）0 unexpected / 0 skipped，其余 7 文件 0 unexpected；另做端到端抽查：`org-export-string-as` 对 ascii 与 html 两后端导出 `[[seshat:ebook:a.pdf#page:3]]` 分别得到 `a.pdf 第 3 页`，输出中无裸 `seshat:` 协议串。
- [x] **T13 摘录按位置插入**：`seshat-reader-reference-insert` 增加目标 headline / 插入点选择；保留现有 `C-u` 语义与默认行为可配置。验收：ERT 覆盖插入位置计算纯函数（headline 末尾 / 光标处 / 无 headline 兜底）；L3 真机在长笔记中插入到指定 headline。（依赖：无）**✅ 2026-10-22**：新增 defcustom `seshat-reader-reference-insert-position`（`end-of-file` 默认 / `headline` / `point`）+ 纯函数 `seshat-reader-reference--insert-position (mode)`；`--insert-into-file` 消费它，无 visiting buffer 时仍 `append-to-file`（`headline`/`point` 回退 `end-of-file`，不强行打开文件，避免副作用）。`headline` 判定用 org 既有 API（签名均经 `elisp-describe-function` 核实）：`org-back-to-heading`（`org.el:21369`，可选 INVISIBLE-OK）→ `org-outline-level`（无参）→ 循环 `outline-next-heading`（无参）直到层级不深于当前或 `point-max`，即**整个子树（含子标题）之后**、下一个同级或更高级 headline 之前；`featurep 'org` 为 nil / 抛错（point 在首个 headline 前、buffer 无 headline）回退 `(point-max)`。**未新增键位、未加 `C-u C-u` 临时覆盖**（位置纯由 defcustom 决定），`C-u` 读正文语义与 `C-c C-r` 绑定不变。ERT：`--insert-position` 8 个用例（默认值 / end-of-file 与未知值 / point / 末子树 = `point-max` / 有同级兄弟 → 下一 headline 起点前 / 嵌套子标题 → 跳过子标题到下一同级前 / 无 headline / 首个 headline 之前 / org 不可用桩）+ 2 个接入用例（headline 模式经 visiting buffer 插到子树末尾、point 模式无 buffer 回退追加且不新开 buffer）。L1 0 error / 34 warning（reference.el 0）；L2 如上；**未做 L3**（真机长笔记插入留 P3/P4 验收）。
- [x] **T14 `--parse-link` 空 location 归一为 nil**。验收：ERT 覆盖 `seshat:ebook:a.pdf#` → location 为 nil。（依赖：无）**✅ 2026-10-22**

### P4 文档与收尾

- [x] **T15 文档沉淀**：`CHANGELOG.md`（新增/变更/修复/破坏性分类）、`docs/architecture.md`（展示层与渲染层章节）、`docs/configuration.md`（新增 defcustom + avy 软依赖）、`docs/api.md`（rect 高亮已实现的说明）、`openspec/decisions.md`（侧栏布局、C 层绘制两处决策）、`openspec/tech-debt.md`（销项 7 条：页面高亮缺口 M11.3 / `rect` 无高亮承载 M11.4 / 包内窗口语义不统一 M11.7 / `:complete` 未实现 / `:export` 未定制 / 摘录固定末尾插入 / `--parse-link` 尾部 `#` 空串（T14 修复）；新增已知限制：旋转页高亮可能错位、Emacs 端仍不显示 ink 手写笔迹、side 模式下 translate 面板不自适应高度）、`VENDORED.md`（C 与 vendored elisp 改动清单）、`openspec/active/roadmap.md`（M12 状态）。验收：新人仅凭文档可理解新版式与高亮机制；tech-debt 销项逐条对应。（依赖：T1–T14）**✅ 2026-10-22**：CHANGELOG（16 条：新增 7 / 变更 3 / 破坏性 1 / 修复 5）、docs/architecture.md（新增「Emacs 阅读器：展示层与渲染层（M12）」节 + 防御上限表）、docs/configuration.md（6 个 defcustom + avy 软依赖）、docs/api.md（rect 已渲染说明）、docs/security.md（新增「客户端防御上限」节）、openspec/decisions.md（2 条决策）、openspec/tech-debt.md（**销项 7 条** + 新增 3 条）、roadmap.md（M12 章节）、VENDORED.md（逐任务登记）
- [x] **T16 全量验证与归档**：`make clean all` + 全部 ERT（skipped 必须为 0，不能只看 unexpected）+ L3 验收清单逐项人工确认；计划移入 `openspec/completed/`。验收：报告列出每级验证的实际命令与结果，无 skipped 假绿。（依赖：T15）**✅ 2026-10-22**：L1 C 0 error/0 warning、elisp 0 error/34 warning（基线）；L2 ERT **271 用例 0 unexpected / 0 skipped**（修掉 ETAF_ROOT 大小写、etaf-test 列宽假绿断言、测试临时目录 TMPDIR 泄漏后达成）；L3 **功能级已用 elisp-dev-mcp 隔离实例（headless，等价重启后的 Emacs）在真机加载路径（straight/build-31.1 → repos）验证，46 条断言全过**（含中文书签 PDF `分布式原理介绍.pdf` 125 书签零八进制转义、--rows/--current-path/avy 标签/per-kind 方位/--display-params/rect 解析/:complete+:export 导出）；**残余视觉项待用户目视**：高亮实际绘制与像素对齐（headless 下 refresh 报 "Window system frame should be used"）、三栏布局观感、颜色与 avy 标签遮挡

## 文档清单

| 文档 | 用途 | 涉及任务 |
|---|---|---|
| `CHANGELOG.md` | 变更历史（新增/变更/修复/破坏性） | T15 |
| `docs/architecture.md` | 展示层（三分栏）与渲染层（C 绘制/跨页衔接）章节 | T15 |
| `docs/configuration.md` | 新增 defcustom（宽度、高亮、跨页行数）、avy 软依赖 | T15 |
| `docs/api.md` | `rect` 坐标系补充「Emacs 端已渲染高亮」 | T15 |
| `openspec/decisions.md` | 决策：side window 版式、C 层高亮绘制（为何不用 elisp 叠加） | T15 |
| `openspec/tech-debt.md` | 销项 7 条：页面高亮缺口 / `rect` 无高亮承载 / 包内窗口语义不统一 / `:complete` / `:export` / 摘录固定末尾插入 / `--parse-link` 尾部 `#` 空串；新增：旋转页高亮错位、ink 仍不显示、side 模式 translate 不自适应高度 | T15 |
| `emacs/seshat-reader/VENDORED.md` | C 与 vendored elisp 改动清单 | T1、T9、T15 |
| `openspec/active/roadmap.md` | M12 里程碑状态 | T15 |

注：「目录面板切换文档后不刷新」（F17）在 tech-debt 中无既有条目，属本次新发现的代码缺陷，修复后只在 CHANGELOG 记「修复」项，不计入 tech-debt 销项。

## 验证标准

- **L1（语法/编译）**：`cd emacs/seshat-reader && make clean all` 无 error、无新增 warning；`.el` 文件 `check-parens` 通过（用 elisp-dev-mcp 的 `elisp_check_parens`，任务类型 `verify`）。
- **L2（功能）**：全部 ERT 通过，**`skipped` 必须为 0**（历史教训：缺 `-L` 导致 `skip-unless` 静默跳过而 ERT 仍报 0 unexpected），须固化完整 `-L` 集合。新增 ERT 至少覆盖：rect 解析、目录行模型/当前章节定位、avy 标签与候选、sidebar 位置→params 与尺寸语义、kind 查找、链接导出与补全候选、摘录插入位置。
  测试文件落点：
  - 新建 `emacs/tests/seshat-reader-outline-test.el`：T4、T5、T6
  - 扩 `emacs/tests/seshat-reader-sidebar-test.el`：T2、T3（位置→params、宽度语义、kind 查找与状态记录）
  - 扩 `emacs/tests/seshat-reader-annotation-test.el`：T10 的 rect 解析
  - 扩 `emacs/tests/seshat-reader-reference-test.el`：T11、T12、T13、T14
- **L3（真机目视）**：Emacs GUI 下逐项确认：① 含中文目录的 PDF 目录与 imenu 正常；② 左目录 + 右批注 + 阅读区三栏共存且不挤压；③ 目录层级/折叠/页码对齐/当前章高亮；④ `f` 触发的 avy 标签跳转；⑤ 批注高亮位置准确、暗色模式正常；⑥ 翻页保留上页末行（或降级方案生效）；⑦ 批注新增/删除后高亮即时同步；⑧ 摘录插入到指定 headline。
- **验证环境纪律**：elisp 验证一律先声明任务类型（`config` / `verify` / `pure`）；长耗时验证（ERT、全量编译、批量 flycheck）只允许 `verify`；纯 elisp 测试用 `emacs -Q --batch`（`pure`）；`config` 下只允许单文件 <5s 操作。收尾 `set_task auto`，不再需要隔离实例时 `elisp_mcp_iso_stop`。

## 注意事项

1. **C 改动必须重建**：改 `render/*.c` 后必须 `make clean all`，并确认 `seshat-render-core.so` 的 mtime 更新；否则表现为「改了没效果」。
2. **`.elc` 陈旧陷阱**：改 elisp 后固定 `rm -f *.elc && make all`（历史踩坑：`make all` 按 mtime 判定可能留旧字节码）。
3. **不要二次解码**：`page-text` / `text-in-rect` 的返回值已是 multibyte，禁止在 elisp 侧统一 decode（F2、F4）；只处理 outline 标题这一处。
4. **不要动 PBM 的 `make_unibyte_string`**：`data2elisp_image`（`elisp-helpers.c:150`）处理二进制图像数据，误改会导致图像损坏。
5. **线程安全**：渲染线程在克隆 ctx 中运行，高亮表必须快照传入，禁止直接读 `DocState` 可变字段。
6. **缓存失效**：高亮变更后必须重建 ±5 页缓存，否则只有当前页生效、翻页后回退。
7. **暗色模式**：高亮必须在 `fz_invert_pixmap_luminance` **之后**绘制，否则颜色被反相。
8. **EE-1**：调用 avy 前必须实读本机 avy 源码确认 API（仓库内无 avy 源码，不得凭记忆写 `avy-jump` / `avy-process` 签名）；调用任何未用过的 Emacs 内建函数前先查 `elisp-describe-function`。
9. **EE-8**：改 `seshat-reader--set-window-vscroll` / `scroll-*-or-*-page` / 书签恢复前，先追踪全部调用点（`seshat-reader-select.el`、`seshat-reader-bookmark.el`、`seshat-reader-saveplace.el`）。
10. **不做的事**：不改 Android 端；不改服务端 API；不引入 uid 补全；不实现 ink 渲染；不改 popper 用户配置（`thomas-emacs` 侧需用户自行同步，只在本仓库文档中提示）。
11. **破坏性变更需在 CHANGELOG 标注**：若 `seshat-reader-sidebar-position` 默认值改为 `right`，或 `q` 键语义变化，必须写进「破坏性」小节。
12. **提交纪律**：不在本次任务中执行 `git commit`；用户自行决定提交时机。
