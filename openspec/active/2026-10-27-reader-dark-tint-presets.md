# 阅读器暗色模式：5 档配色预设（tint）与进程级暗色偏好

## 当前状态
- 阶段：Phase 4（Review & Document）· 批次 3 完成，等待 L3 真机目测 + 配置侧收尾
- 已确认：方案要素 ✅（用户 2026-10-27 选「全做，先给一档试用」，默认预设 `charcoal`）；计划 ✅（用户 2026-10-27 确认，plan-reviewer 有条件通过后已修订）；**D2 定稿 = A（进程级 static，用户 2026-10-27 拍板）**
- D2 定稿的后续已落地：`openspec/decisions.md` 已写入决策条目、`2026-10-26-reader-multipage-p1-layout.md` 的注记行已更新为「D2 已定为 A」
- 与在飞计划的关系：`openspec/active/2026-10-26-reader-multipage-p1-layout.md` 的 **multipage T4 已落地（批次 3，commit `19a5a91` + `80eb582`）**，`seshat-reader--render-buffer` / `--redisplay-all-windows` / dark-mode body 都已是多页版；本计划在其结果上编辑，**只读** `--render-buffer` / `--redisplay-all-windows` / `--page-image-spec` 一族，不改其语义与布局逻辑
- **共同编辑点（必须串行，风险项）**：`seshat-reader-dark-mode` 的 body（`emacs/seshat-reader/seshat-reader.el:2883-2894`，`--doc-invert` 调用在 `:2893`）是**本计划 T3** 与 **multipage 计划 T4** 的**共同编辑点**——两处**不得在同一 worktree 并行编辑**，必须**串行合并**：先落地者先合，后落地者在其上 rebase（本计划 T3 先落地 → multipage T4 rebase 其上；反之亦然）。合并后**必须重跑定向 ERT**（`seshat-reading-test` / `seshat-reader-multipage-test` / `seshat-reader-theme-test`）。现实风险：T3 需在 T4 **已落地代码**上编辑，merge 冲突概率低但**语义需复核**（尤其 `--redisplay-all-windows` 现为多页重绘，一次 dark 切换会重渲染全部可见页 ±2 页）
- **已知影响（T4 落地后新增）**：dark-mode 每次切换 / 改配色都会触发多页重渲染（可见页 ±2，每页约 7ms 量级，**估算，L3 校准**；P0 实测单页 0.7–11 ms），切换预设时可见轻微延迟，属可接受开销
- 执行状态：批次 0 ✅（基线 + 安全点）/ 批次 1 ✅（T1+T2 C 侧；`.so` md5 `26caf7e758c1a4286032ca2e291b4198`，gcc warning 0，`make clean all` EXIT 0）/ 批次 2 ✅（T3+T4 elisp 侧 + 新建 `seshat-reader-theme-test.el` 11 例；定向 ERT theme 11/11、reading 49/49、multipage 39/39）/ 批次 3a ✅（T5 全量验证：**31 文件 / 1166 例 / `unexpected = 0` / `skipped = 0`**，86.8 秒；byte-compile 25 条 = 基线零新增；`.invert` 残留 0；未触发修复循环/回滚）
- 下一步：① **L3 真机目测**（T7，用户：重启 Emacs 后逐档确认 5 档观感 + 重载后保持暗色）；② **thomas-emacs 配置侧收尾**（T6 配置侧：删 `+seshat-reader-dark-after-render` advice、设 `(setq seshat-reader-dark-tint 'charcoal)`、配置仓 CHANGELOG 一条）
- 注记（2026-10-27）：T7 的真机目测可直接用 `seshat-reader-dark-tint-cycle`（配置层绑定在阅读 buffer 的 `T`，见 `openspec/active/2026-10-27-reader-dark-tint-cycle-key.md`）逐档检查 5 档观感与「切档后立即刷新」。
- 批次 0 ✅（2026-10-27）：基线 PNM 已采集并落盘（采集时 `HEAD = 80eb582`，`.so` 未重编、md5 `501eb339…`），安全点引用 `0f531f7`（`git stash create`，不改工作目录）。数据见下方「## 基线数据」；取证期间并行会话把 HEAD 推进到 `c6caf85`（仅 elisp），基线已在其上复验一致

## 目标

把「暗色模式只有一种观感（纯黑底 + 纯白字，对比 21:1）」改成「**5 档可选配色预设**，默认 `charcoal`（≈6:1，正文可久读）」：

1. 新增 1 个 C 模块入口 `seshat-reader-dyn--doc-tint`（`0xRRGGBB` 背景/文字两整数），像素变换用 MuPDF 现成的 `fz_tint_pixmap`。
2. 新增 1 个 defcustom `seshat-reader-dark-tint`（5 个 `const` + 自定义 `(cons INTEGER INTEGER)`），预设表留在 elisp 侧。
3. `graphite`（`#000000`/`#ffffff`）走**旧路径**，与改动前逐位一致，是一键回退口。
4. 若 D2 选 A：暗色开关与配色升为**进程级用户偏好**，重载/新开文档自动保持，删掉 thomas-emacs 配置里为「重载后回白底」打的 advice。

**不做**：单页内容分流（文字低对比、图片保色）；彩图保色（tint 按亮度映射到两色，必然单色，用户 2026-10-27 显式接受）。

## 根本问题（第一性原理）

| 事实 | 依据 |
|---|---|
| 暗色目前只有一种结果：**纯黑底 + 纯白字**，不存在第二档 | `render/render-core.c:337-341` 的 `if (doc_state->invert)` 分支里只有两步：`fz_invert_pixmap_luminance` + `fz_gamma_pixmap(ctx, pixmap, 1 / 1.4f)` |
| `fz_invert_pixmap_luminance` 是**满量程反色**（0↔255 双射，只跳过 alpha），白字黑底是它的必然产物 | `/usr/include/mupdf/fitz/pixmap.h`（该函数注释：`All components of all pixels are inverted (except alpha, which is unchanged). Only supports Grey and RGB bitmaps.`） |
| `fz_gamma_pixmap` 通常实现为 `out = 255·pow(v/255, γ)`，**0 与 255 都是不动点**，所以调 γ 只能改中间调 | 假设?（MuPDF 头文件只写 `Apply gamma correction to a pixmap. All components of all pixels are modified (except alpha…); gamma: The gamma value to apply; 1.0 for no change.`——**未给公式**；公式取自 gamma 校正的标准定义。端点不动这一点 T1 用 PNM 比对实测确认） |
| ⇒ 「对比太强」**不是参数问题，是路径问题**：只要终点钉在 0/255，两端就压不下来 | 由上两条直接得出 |
| MuPDF 已有「双端压缩」的现成 API，无需自写像素循环 | `pixmap.h:324`：`void fz_tint_pixmap(fz_context *ctx, fz_pixmap *pix, int black, int white);`，注释 `black: Map black to this hexadecimal RGB color. white: Map white to this hexadecimal RGB color.` |
| 页面 pixmap 正好是 tint 支持的类型（RGB、无 alpha 通道） | `render-core.c` 的 `fz_new_pixmap_from_display_list(ctx, dp->display_list, ctm, fz_device_rgb(ctx), 0)`（`fz_device_rgb` + alpha 位 0） |
| 暗色标志是**文档级**字段，且随文档重置清零 | `render/render-core.h:146` 的 `int invert;`；`render/mupdf-helpers.c:30` 的 `reset_doc_state()` 写 `.invert = 0`，只保留 `active_jobs` / `is_reloading`；`load_doc` 每次都调它 |
| elisp 侧暗色状态却是 **buffer 级 minor mode**，只在 toggle 时下发一次 | `emacs/seshat-reader/seshat-reader.el:2883`（define-minor-mode body 只调 `(seshat-reader-dyn--doc-invert …)` + `seshat-reader--redisplay-all-windows`） |
| ⇒ 已知不一致：**重载 / 新开文档后回白底，但 mode line 仍显示 `Dark`** | 上两条相加；thomas-emacs `lisp/init-reader.el` 为此打了 `+seshat-reader-dark-after-render`（advice on `seshat-reader--render-buffer`） |
| 像素变换**只有一处**，且顺序是不变量：栅格化 → 像素变换 → 装饰 wash → PNM 编码 | `render-core.c:274-281` 的 `render_page_to_buffer` 头注释；`docs/architecture.md:282`（「绘制顺序（不变）」）；`docs/architecture.md:348`（ink 段「反色/gamma 之后、写 PNM 之前」） |
| 彩图在 tint 下必然单色：tint 是「把黑映射到 A 色、白映射到 B 色」的线性插值，色相信息不被保留 | `pixmap.h:318-324` 注释；用户已接受该限制 |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | `fz_gamma_pixmap` 的 0 / 255 是不动点，故 `graphite` 路径下底色恒 `#000000`、字色恒 `#ffffff`，调 γ 只动中间调 | 假设?（由公式推断，未见文档明文；**T1 用同一页两种设置导出 PNM 比对确认**：纯黑/纯白区域仍为 0/255） |
| A2 | `fz_tint_pixmap` 丢色相（彩图变单色调） | 事实✓（`pixmap.h:318-324`：只有 black / white 两个目标色，线性映射） |
| A3 | 进程级 `static` 变量不随 `reset_doc_state()` 清零（因此 D2-A 下重载/新文档自动保持配色） | 事实✓（static 存储期 = 进程；`reset_doc_state` 只对传入的 `*state` 做定位初始化，见 `mupdf-helpers.c:36-57`） |
| A4 | multipage 计划 T4 对 `--render-buffer` / `--redisplay-all-windows` / `--page-image-spec` 的重构，不会与本计划的 advice 精简冲突 | 假设?（T4 改的是遍历与几何，本计划只依赖「mode body 下发状态 + 全局重绘」这一既有形状；**若 T4 改了 `--redisplay-all-windows` 的语义，需在批次 3 复核一次**） |
| A5 | 用户接受「彩图 / 彩色封面在 tint 下变单色调」 | 用户显式（2026-10-27） |
| A6 | 5 档对比度值可信 | 假设?（**按 WCAG 相对亮度公式重算**：graphite 21.00、midnight **9.74**、charcoal 6.05、night-sepia 8.20、sepia 9.28；其中 midnight 与素材手算值 10.9 差 1.16，**超出 ±0.3 容差已更正**，见「源码事实核对」；最终以 L3 目测校准） |
| A7 | `fz_tint_pixmap` 的头文件声明与语义：`black` / `white` 各映射到一个十六进制 RGB 色，支持 RGB / BGR / Gray pixmap | 事实✓（`/usr/include/mupdf/fitz/pixmap.h:319-324`：`Tint all the pixels in an RGB, BGR, or Gray pixmap.` + `black: Map black to this hexadecimal RGB color. white: Map white to this hexadecimal RGB color.`） |
| A7b | `fz_tint_pixmap` 在**本机 MuPDF 1.28.5** 上对本项目的 RGB pixmap（`fz_device_rgb` / alpha 0）**直接生效、无需额外 ctx 状态**（无 colourspace 转换、无需先 `fz_convert_pixmap`） | 假设?（头文件只保证声明与语义，不保证该版本实现细节；**T1 首档 tint 导出 PNM 后实测确认**：像素确实被压到 BG/FG 两端，且无 assert/报错） |
| A8 | 「逐位等同旧行为」可用 PNM 字节 `sha256` 做机械断言 | 假设?（依赖「同一 PDF 页 + 同一 MuPDF 版本 + 同一参数 → 确定性输出」；P0 已用同一口径证明 `render_page_to_buffer` 抽出前后 PNM sha256 一致） |

**回验结论（Phase 4，批次 0/1/2/3a 实测后逐条回验）**：

- **A1 成立 ✓（间接）**——`graphite`（tint 未设）下 p100 / p775 的 PNM sha256 与旧 `.so` **逐位一致**，故「端点不动点 + 旧路径零变化」未被推翻；但 p100 实测像素 **min = 13**（该页既无纯 0 像素、也无纯 255 像素），说明「该页未触及 0/255 端点」，端点不动点由「与旧 `.so` 输出逐位相等」间接支撑（旧 `.so` 走的就是同一条 invert + gamma 序列）。
- **A2 成立 ✓**——`charcoal` 下整页 R 通道 **max = 168、R > 175 的像素数 = 0**，彩图/封面被压到两色之间，色相丢失；用户已显式接受（A5）。
- **A3 成立 ✓**——进程级 `static` 不随 `reset_doc_state()` 清零：批次 1 实测「下发 tint → `load-doc` 另一文档」后仍出暗色；elisp 侧（T6 配置侧收尾后）重载保持暗色的前提由此成立。
- **A4 成立 ✓**——T3 只在 `seshat-reader-dark-mode` body 新增一次 `--doc-tint` 下发，**未动** `--render-buffer` / `--redisplay-all-windows` / `--page-image-spec` 的语义与布局逻辑；`seshat-reader-multipage-test` 39/39 全绿佐证无冲突。
- **A5 成立 ✓（用户显式）**——用户 2026-10-27 明确接受；观感层面的最终接受度归 L3（T7 项③）。
- **A6 成立 ✓（像素基础）/ 主观待 L3**——D3 表已用 WCAG 重算值；实测 `charcoal` 像素 **min = (38, 38, 43) = `#26262b`、max = (168, 164, 154) = `#a8a49a`，与表内两色零偏差**（`midnight` min = (28,28,34)、max = (200,196,186) 同理精确命中 `#1c1c22` / `#c8c4ba`），即对比度值的像素前提成立；「正文可久读」属观感，待 L3。
- **A7 成立 ✓**——落笔前已核对 `/usr/include/mupdf/fitz/pixmap.h:319-324`，实现按 `black` / `white` 两色映射使用，未误用其它重载。
- **A7b 成立 ✓**——本机 MuPDF 对 `fz_device_rgb` / alpha 0 的 pixmap **直接生效**：无 assert、无报错、无需 `fz_convert_pixmap`；`charcoal` 像素被压到 `(38,38,43)`–`(168,164,154)` 两端且零偏差。
- **A8 成立 ✓**——同页同参数两次渲染 sha256 相同、跨进程亦一致（批次 0 实测）；批次 1 在 `off` 态复跑 p100 / p775 与基线**逐字相等**，sha256 可作机械断言。
- **L3 相关（观感类）未验证 ?**——① `charcoal` 正文是否真能久读；② `sepia` 亮底可读且装饰（高亮/笔迹）仍可见；③ 彩图单色调在真实屏幕上是否可接受；④ 切预设后的主观延迟。四项均为批量 ERT 无法产生的结论，只能由 T7 目测填入。

## 设计

### D1 tint 与 invert 的关系：两条分支、同一位置

`render_page_to_buffer()` 里那处 `if` 变成三分支，**位置不变**（栅格化之后、装饰 wash 之前、PNM 编码之前）：

```c
if (dark_enabled())
  {
      if (tint_is_set())
          fz_tint_pixmap(ctx, pixmap, tint_bg(), tint_fg());
      else
          {
              fz_invert_pixmap_luminance(ctx, pixmap);
              fz_gamma_pixmap(ctx, pixmap, 1 / 1.4f);
          }
  }
```

| 预设 | 路径 | 像素语义 |
|---|---|---|
| `graphite` | **旧路径**（invert_luminance + gamma 1/1.4，两步、顺序、参数**逐字不变**） | 保留 chrominance（等价 `#000`/`#fff` 满对比），与改动前**逐位一致** |
| `midnight` / `charcoal` / `night-sepia` / `sepia` | `fz_tint_pixmap` | 亮度线性映射到 `black..white` 两色，**丢色相** |

「tint 未设置」用**哨兵**表达：`tint_bg < 0 || tint_fg < 0` → 走旧路径。不用 `0` 当哨兵的理由：`#000000` 是合法背景色（`graphite` 自己就是）。

### D2 配色与 invert 标志的存储粒度（**本计划最关键的决策，待用户拍板**）

| 维度 | 备选 A（推荐） | 备选 B |
|---|---|---|
| 存储 | 进程级 `static`（`static atomic_int g_dark_enabled; static atomic_int g_tint_bg, g_tint_fg;`） | `DocState` 字段（`invert` + `tint_bg` / `tint_fg`） |
| `reset_doc_state` | 不涉及（值自然保留） | 需保留/清零，语义不变（`load_doc` 后丢失） |
| 重载 / 新开文档 | **自动保持暗色与预设** | 回白底，需 elisp 侧补丁重设 |
| 语义 | 暗色 = **用户偏好**（进程级） | 暗色 = **文档属性**（与 multipage 计划 T4 的「文档级」表述一致） |
| thomas-emacs 配置 | **可删** `+seshat-reader-dark-after-render` advice 与 mode-hook 里的重新下发 | 保留，且每加一个预设都要重新下发一次 |
| 改动面 | `render-core.c`（新增 static + 分支）+ `render-core.h` / `mupdf-helpers.c` 各一行（删 `invert` 字段与初始化） | 同两文件（各加 2–3 字段）+ 上述两个文件仍需改 |
| 风险 | 改变既有语义 → 需 `openspec/decisions.md` 记录 + 用户显式确认 | 零语义变更，但与 elisp 的 buffer 级 mode 永远不同步 |

**推荐 A**，理由：

- a) 配色本质是**用户偏好**而非文档属性——同一本 PDF 没人希望换文档就换配色；
- b) 消灭「重载回白底、mode 仍显示 `Dark`」这一已知不一致（根因表中的倒数第三行），它是配置侧那个 advice 存在的唯一理由；
- c) 减少对 `--render-buffer` 的 advice 依赖——T4 即将重构该函数，**advice 越少越安全**（A4）；
- d) 让「暗色是否开启」只有一个真相来源：`DocState.invert` 字段随之删除，避免「有个字段叫 invert 但没人读」的下一轮误导。

> **对素材理由 d 的更正**：素材写「A 少改 `render-core.h` / `mupdf-helpers.c` 两个文件」不成立——A 与 B **都**要改这两个文件（B 加字段、A 删字段）。A 的真实收益是 b / c / d 三条，不是「少改文件」。

**风险与代价（选 A 必须一并接受）**：

1. `--doc-invert` 的语义从「改文档状态」变为「改进程开关」，arity（`1,1`）与返回契约不变；上游/第三方若依赖「文档级」语义会看到行为变化。
2. `openspec/decisions.md` 必须记一条（草稿见 T6，**D2 定稿后才写入**）。
3. `openspec/active/2026-10-26-reader-multipage-p1-layout.md` 的 T4 表述里「dark-mode invert 定为 C 侧 `--doc-invert`（文档级）」需加**一行注记**（只加注记，不改任务内容，见 T6）。
4. 进程级 = 同一 Emacs 里所有 reader buffer 共享同一配色（不同 buffer 不能各用一档）。这与「配色是用户偏好」自洽，但要在 `docs/emacs-reader.md` 写清。

### D3 预设定义位置：预设名留 elisp，C 只认两个整数

- **C 侧不认识预设名**，只接 `(BG, FG)` 两个 `0xRRGGBB` 整数。新增预设不需要改 C、不需要重编 `.so`。
- elisp 侧：
  - `defconst seshat-reader-dark-tint-presets`：5 档 alist，值形如 `(BG . FG)`，**用整数**（`#x26262b`）而非字符串——省掉运行时 `string-to-number` 与对 `#` 的解析。
  - `defcustom seshat-reader-dark-tint`（默认 `'charcoal`）：`:type '(choice (const graphite) (const midnight) (const charcoal) (const night-sepia) (const sepia) (cons integer integer))`。
  - `seshat-reader--dark-tint-colors`：解析函数，`graphite` → `nil`（走旧路径），预设符号 → alist 查表，cons → 原样返回（两个 `integerp` 校验，非法则回退 `nil` + 一次 `message`，**不静默换成另一档**）。

| 预设 | 背景 | 文字 | 对比度（重算） | elisp 值 `(BG . FG)` | 下发到 C 的两个整数 |
|---|---|---|---|---|---|
| `graphite` | `#000000` | `#ffffff` | 21.00:1 | `nil`（哨兵，不入表） | `(-1, -1)` |
| `midnight` | `#1c1c22` | `#c8c4ba` | **9.74**:1 | `(#x1c1c22 . #xc8c4ba)` | `(1842210, 13157562)` |
| `charcoal`（默认） | `#26262b` | `#a8a49a` | 6.05:1 | `(#x26262b . #xa8a49a)` | `(2500139, 11052186)` |
| `night-sepia` | `#201d18` | `#c0b49c` | 8.20:1 | `(#x201d18 . #xc0b49c)` | `(2104600, 12629148)` |
| `sepia` | `#e8dfc8` | `#3a342a` | 9.28:1 | `(#xe8dfc8 . #x3a342a)` | `(15261640, 3814442)` |

> 对比度按 WCAG 相对亮度公式重算（`(L1+0.05)/(L2+0.05)`），误差 ±0.3；与素材手算值的一致/差异见「源码事实核对」。

### D4 C 侧 API

- 新增 `emacs_doc_tint`（`render/render-theme.c` + `.h` 声明），2 参数 `BG FG`，`0xRRGGBB` 整数：
  - 每个参数 clamp 到 `[0, 0xFFFFFF]`；**任一为负 → 清空 tint（回旧路径）**。
  - 参数提取用 `env->extract_integer` + `non_local_exit_check` 清 pending（照 `render/elisp-helpers.c:578-585` 的 `non_local_exit_clear` 模式；**不要**用 `extract_float_coerced`——`0xFFFFFF` 虽在 float 的 24 位尾数内，但依赖该巧合不值得）。
  - 非整数入参 → 返回值仍然 `EMACS_T`，但**不改状态**并 `emacs_message` 一次说明期望 `0xRRGGBB`（避免「静默没生效」）。
  - 无 DocState 时同样返回 `EMACS_T`（D2-A 下它不读文档；B 下需 `get_doc_state_ptr` 守卫，见「分支差异」）。
- 注册（`render/render-core.c` 的 `emacs_module_init`，紧邻 `--doc-invert`，约 3567 行处）：
  `register_module_func(env, emacs_doc_tint, "seshat-reader-dyn--doc-tint", 2, 2, "<中文 + 英文 docstring，仓库风格：首行祈使句，说明参数与副作用>")`。
- **`--doc-invert` 保持向后兼容**：注册名、arity（`1,1`）、返回值、无文档时的 `message` + `nil` 守卫**全部不变**。D2-A 下它改为只翻转 `g_dark_enabled`；D2-B 下语义完全不变（写 `doc_state->invert`）。
- **重渲染**：与 `--doc-invert` 完全同一形状——**只改状态，不发任务**，由 elisp 侧 `seshat-reader--redisplay-all-windows` 重绘（它会先 `--page-spec-clear-cache`，因此 tint 变更必然穿透 spec 缓存）。
- **分支差异**（B 版）：`--doc-tint` 需 `get_doc_state_ptr` 守卫；`DocState` 增 `int tint_bg, tint_fg;` 且 `reset_doc_state` 里初始化回哨兵（`-1`），语义仍是「重载后丢配色」。

### D5 兼容与回退

- **未设置 tint 或选 `graphite` 时，必须与改动前逐位一致**：同一 `invert_luminance` + `gamma 1/1.4` 序列、同一顺序、同一参数。判据 = 同一 PDF 页在改动前后 `--page-image-spec` 的 `:data`（PNM）`sha256` 相等（T1/T5）。
- 默认值 `charcoal`；用户 `(setq seshat-reader-dark-tint 'graphite)` 一键退回旧观感，无需重编。
- **残留风险（显式登记）**：单独调用 `(seshat-reader-dyn--doc-invert 1)` 而不下发 tint 的第三方代码，会沿用**上一次**的 tint（进程级）。缓解：`--doc-invert` 的调用点清单 = **生产代码 1 处**（`emacs/seshat-reader/seshat-reader.el:2893` 的 `seshat-reader-dark-mode` body）+ **测试 2 文件 3 处 stub**（`emacs/tests/seshat-reading-test.el:182`、`emacs/tests/seshat-reader-multipage-test.el:706`、`:715`，均为 `cl-letf` 桩）。生产侧由本计划让它**总是**紧随其后下发 tint（含 `graphite` 的 `-1 -1`）；测试侧这 3 处 stub 在 T3 后必须同步补 `--doc-tint` 桩（否则 `void-function`，见 T4）；`docs/emacs-reader.md` 写明「同时设置两者才是完整语义」。

### D6 已知限制

1. **彩图 / 彩色封面变单色调**（tint 只按亮度映射到两色）。用户已接受；`openspec/tech-debt.md` 登记。
2. **不做单页内容分流**（文字低对比、图片保色）——需要像素分类或按内容流区域分色，属独立议题，超出本期。
3. `sepia` 是**亮底暗字**：它走 tint（`black → #e8dfc8`、`white → #3a342a`），因此装饰色（默认黄 α 0.35）在亮底上比暗底更不明显——本轮不调装饰配色，L3 目测记录实测观感。
4. 进程级配色 = 同一 Emacs 内所有 reader buffer 共享（D2-A 的必然结果）。

## 任务

- [x] T1 C 侧像素变换分支（`render/render-core.h` / `render/mupdf-helpers.c` / `render/render-core.c`）：按 D1 写三分支，按 D2 定稿的位置放状态（A：文件顶部 `static atomic_int g_dark_enabled / g_tint_bg / g_tint_fg`，初值 `0 / -1 / -1`；B：`DocState` 字段 + `reset_doc_state` 初始化回哨兵）。同步改 `render_page_to_buffer` 头注释里那句「deliberately still read from DOC_STATE is `invert' and `frame_scale'」（D2-A 后 `invert` 不再来自 DocState）。顺手核对另外两处通用注释的措辞：`render/render-core.c:665`（「uses the page's display list to generate a pixmap, optionally inverts and gamma-corrects」）与 `render/render-core.h:167`（「has specific properties such as invert, resolution, etc.」）——D2-A 删 `DocState.invert` 后这两句会显得指向不存在的字段，若措辞会误导则一并微调（**只改注释文字，不动任何逻辑**）。**不得改动装饰 wash 与 PNM 编码的相对次序**。验收：① `graphite` 路径与改动前**逐位一致**——同一 PDF 页（建议 `d2l-zh-pytorch.pdf` 第 100 页）在改动前后各导出一次 `--page-image-spec` 的 `:data` 求 `sha256`，两值相等（基线在 T1 动工**前**先采一次并记录在计划「执行记录」）；**①bis 再取一页含彩色插图或透明 image mask 的页，同样比对改动前后 `--page-image-spec :data`（PNM）的 `sha256` 相等**——理由：旧路径 `fz_invert_pixmap_luminance` **保留 chrominance**（`pixmap.h:307-315`：`luminance of each pixel is inverted, and the chrominance remains unchanged (as much as accuracy allows)`），纯文字 / 纯灰度页根本测不到这一半行为，只比对文字页等于放过 `graphite` 回退口最容易破的地方；② tint 分支只在开关为真时生效——关暗色时同一页的 PNM 与「从未开过暗色」的进程输出相同；③ 代码级比对：旧路径两行调用逐字未改。（依赖：无）

  **执行记录（批次 1 ✅）**：状态落在 `render/render-theme.c`（`static bool g_dark_enabled` / `g_tint_set` / `unsigned g_tint_bg` / `g_tint_fg` + 4 个只读访问器 `theme_dark_enabled` / `theme_tint_set` / `theme_tint_bg` / `theme_tint_fg`，声明在 `render/render-theme.h:27-30`）；`DocState.invert` 已删、`mupdf-helpers.c:45-46` 的 `reset_doc_state` 改为一段「无暗色字段需清零」的说明；`render-core.c:355-364` 落地为 `if (dark_on && theme_tint_set()) fz_tint_pixmap(...) else if (dark_on) { fz_invert_pixmap_luminance; fz_gamma_pixmap(1/1.4f); }`（**旧路径两行逐字未改**，见 `:361-362`）；三处注释措辞同步（`render-core.c:274-285`、`:689-690`、`:743-744`）。验收：`off` 态 p100 / p775 的 sha256 与批次 0 基线**逐字相等**（`bdadd357…` / `07c793bb…`）；`graphite` 等于「旧暗色路径」参考值（`ad7b38d5…` / `9b175a01…`）；`charcoal` 像素 min = `(38,38,43)`、max = `(168,164,154)`、R > 175 像素数 **0**；`midnight` min = `(28,28,34)`、max = `(200,196,186)`；`make clean all` EXIT 0、`-Wall -Wextra` gcc warning **0**、新 `.so` md5 **`26caf7e758c1a4286032ca2e291b4198`**。

- [x] T2 C 侧 module API（`render/render-theme.c` / `render/render-theme.h` / `render/render-core.c` 注册点）：新增 `emacs_doc_tint` 并注册为 `seshat-reader-dyn--doc-tint`（arity `2,2`），正面/防御行为按 D4；顺手修正 `render-theme.c` 里 `emacs_doc_invert` 的**陈旧 docstring**（现文写「re-renders the current page in a background thread」，实际只改状态、不重渲染——见「源码事实核对」第 3 条）。**同时更新 `--doc-invert` 注册处的 docstring**（实测 `render/render-core.c:3569`，现文 `"Sets the document-local invert state for dark mode."`）：D2 定稿为 A（进程级）→ 删除 `document-local` 一词，措辞与「## decisions.md 待写入草稿」的「语义改为翻转进程级暗色开关」对齐（如 `"Toggles the process-wide dark mode flag; pixel colours come from --doc-tint."`）；定稿为 B（`DocState` 字段）→ 保留 `document-local`，补一句「配色由 `--doc-tint` 提供」。验收：`(fboundp 'seshat-reader-dyn--doc-tint)` → `t`；`(seshat-reader-dyn--doc-tint #x26262b #xa8a49a)` 返回非 nil；`(seshat-reader-dyn--doc-tint -1 -1)` 返回非 nil 且后续渲染回到旧路径；`(seshat-reader-dyn--doc-tint "x" 1)` 不崩溃（不设 pending 泄露）。（依赖：T1）

  **执行记录（批次 1 ✅）**：`emacs_doc_tint` 实现在 `render/render-theme.c`（`render/render-theme.h:21` 声明），注册名 `seshat-reader-dyn--doc-tint`、arity `2,2`（`render-core.c:3603`，紧邻 `--doc-invert`）。契约按 D4 落地：参数为 `#xRRGGBB` 整数；**`-1 -1` 清空 tint → 回退旧 invert+gamma 路径**；**`> 0xFFFFFF` 返回 `nil` + 一次 `message`**；**非整数入参不改状态、返回 `t`**（`env->extract_integer` + `non_local_exit_clear` 清 pending）。`emacs_doc_invert` 的陈旧 docstring（原写「re-renders … in a background thread」）已改为「只改进程级开关」；`--doc-invert` 注册处 docstring（`render-core.c:3593-3597`）删掉 `document-local`，改为「翻转进程级暗色开关，像素颜色由 `--doc-tint` 提供」。**`emacs_doc_invert` 同时删掉了 `get_doc_state_ptr` 守卫**（进程级语义下无文档也应可设；实测无文档调用返回 `t`，且随后 `load-doc` 出来就是暗色）——理由见「## 实现与计划的偏差」④。

- [x] T3 elisp 侧（`emacs/seshat-reader/seshat-reader.el`）：新增 `defconst seshat-reader-dark-tint-presets`（5 档，值见 D3 表）+ `defcustom seshat-reader-dark-tint`（默认 `'charcoal`，`:type` 见 D3）+ `seshat-reader--dark-tint-colors`（解析 + 非法值回退）；`seshat-reader-dark-mode` 的 body 在 `--doc-invert` 之后下发 `--doc-tint`（**暗色关闭时不下发**，但保留上次值无副作用），并保持既有 `seshat-reader--redisplay-all-windows` 收尾（清 spec 缓存 + 逐页重绘）。**不得改** `--redisplay-all-windows` / `--render-buffer` / `--page-image-spec` 的语义与布局逻辑。验收：`(seshat-reader--dark-tint-colors 'charcoal)` → `(#x26262b . #xa8a49a)`；`'graphite` → `nil`；自定义 cons 原样返回；非法的预设符号回退 `nil` + 一次 `message`；`seshat-reader-dark-tint` 的 `customize` 界面出现 5 个 `const` + 自定义 cons 选项。（依赖：T2）

  **执行记录（批次 2 ✅）**：`defconst seshat-reader-dark-tint-presets`（`seshat-reader.el:3037`，5 档，`graphite` 存 `(-1 . -1)` 哨兵）+ `defcustom seshat-reader-dark-tint`（`:3053`，默认 `'charcoal`）+ 解析器 `seshat-reader--dark-tint-colors`（`:3075`：符号 → `assq` 查表，`(car colors) < 0` → `nil` = 不下发；非法 cons → `message` + `nil`；未知符号 → `message` + `nil`）。dark-mode body（`:3103-3125`）顺序为 `--doc-invert` → 开时 `--doc-tint` → `seshat-reader--redisplay-all-windows`；**关色时不下发 tint**（保留偏好，下次开启自动沿用同档；已在 docstring 写明）。`--doc-tint` 生产调用点**恰好 1 处**（`:3123`）。elisp 侧 `0x26262b` 是**符号**，全仓统一写 `#x26262b`（踩坑记录）。`--redisplay-all-windows` / `--render-buffer` / `--page-image-spec` 语义零改动。

- [x] T4 测试（新建 `emacs/tests/seshat-reader-theme-test.el`；既有两个 dark-mode 用例需按下方**最小补桩**改动，其余零改动）：用 `cl-letf` stub 掉 `seshat-reader-dyn--doc-tint` / `--doc-invert` / `seshat-reader--redisplay-all-windows`，断言：① 开 dark 时按预设下发正确 `(bg, fg)`（`charcoal` / `midnight` / `sepia` 各一例）；② 选 `graphite` 时下发 `(-1 -1)`（等价旧路径）；③ 关 dark 时不下发 tint（或下发但不影响渲染——取「不下发」口径）；④ 切预设会触发一次 redisplay（`redisplay-calls` = 1）；⑤ `seshat-reader--dark-tint-colors` 的解析与非法回退（纯函数，4 例）。

  **两个既有 dark-mode 用例并列登记，T3 后都需补桩**（T3 在 mode body 新增 `--doc-tint` 调用，二者都没 stub 它 → `void-function`）：

  | 文件:行 | 用例 | 现有 stub | 需补 |
  |---|---|---|---|
  | `emacs/tests/seshat-reading-test.el:175` | `seshat-reading-test-dark-mode-guard-in-derived-mode`（stub 在 `:182` 的 `cl-letf`） | `--doc-invert`、`--redisplay-all-windows` | `--doc-tint`（断言不变：`invert-args` = `'(1)`、`redisplay-calls` = 1） |
  | `emacs/tests/seshat-reader-multipage-test.el:691` | `seshat-reader-multipage-test--geometry-dark-mode-inverts-and-rerenders`（stub 在 `:706` 与 `:715` 两处 `cl-letf`） | `--doc-invert`、`--multipage-rerender-page` | 两处 `cl-letf` **各自**补 `--doc-tint`（断言不变：`inverted` = `'(1)` / `'(0 1)`、`rendered` = 3） |

  `seshat-reader-multipage-test.el` 那例**已计入 1144 例全量基线**（T5），漏改则 T5 必红——这是本计划唯一的强制「改既有测试」点。两处补桩属**允许的最小改动**，必须在实现报告与 T5 执行记录中逐处标注（文件:行 + 补了什么、断言为何不变）。若 multipage 计划的 T9（ERT Makefile / 测试重写）先改写这两个文件，则在**其改写结果上**补桩，并**串行协调**（不得两个 plan 并行编辑同一测试文件）。

  验收：新测试全绿；上述两处补桩后仍绿且断言内容未变。（依赖：T3）

  **执行记录（批次 2 ✅）**：新建 `emacs/tests/seshat-reader-theme-test.el`，**11 例**（覆盖 ① 三档下发正确 `(bg, fg)`、② `graphite` 下发 `(-1 -1)`、③ 关 dark 不下发 tint、④ redisplay 恰好 1 次、⑤ 解析器 4 例含非法回退）。两处既有用例的补桩落在 `emacs/tests/seshat-reading-test.el:184-185` 与 `emacs/tests/seshat-reader-multipage-test.el:708-709` / `:719-720`（行号较计划表记的 `:706` / `:715` 下移 2–4 行，属补桩前的既有偏移），**断言内容零改动**。定向 ERT：theme **11/11**、reading **49/49**、multipage **39/39**。

- [x] T5 构建与全量验证：`make -C emacs/seshat-reader clean all`（C 零新增 warning，同口径比对；elisp byte-compile warning 以当日实测为基线，判据「零新增」，**不写死数字**——multipage 批次 2 记录为 20 条）、`make -C emacs/seshat-reader checkdoc`（0 新增）、`elisp_check_parens`（改动的 `.el` + `.c`）、定向 ERT（theme / reading / page-spec / resize / multipage / annotation-decoration）+ **全量 ERT 1144 例零回归**（基线见 multipage 计划「当前状态」：批次 3 / T4 后 30 文件 / 1144 例 / 0 unexpected / 0 skipped；执行当日先跑一次全量确认基线仍为 **1144**，若期间 master 有新提交，以当日实测例数为准并在报告中记录差值）。验收：全绿 + 判据逐条记录（`unexpected = 0` 且 `skipped = 0`）。（依赖：T1–T4）

  **执行记录（批次 3a ✅）**：全量 ERT **31 文件 / 1166 例 / `unexpected = 0` / `skipped = 0` / 86.8 秒**（相对 1144 例基线 **+22**：新建 theme-test +11、multipage 28 → 39 即 +11）。**必须逐文件跑**——单进程一次跑完全量会出现 `annotation` / `annotation-queue` 共 **6 例既有假失败**，与本次改动无关，不是回归。`make -C emacs/seshat-reader clean all` EXIT 0、gcc warning **0**、`make checkdoc` **0 新增**；byte-compile 全仓 **25 条 = 基线**（其中 `seshat-reader.el` 单文件 **20 = 基线 20**）→ **零新增**。grep 不变量：`.invert` 残留 **0**、`DocState` 内 `invert` **0**、`doc-tint` 生产调用 **1** 处 + `declare-function` **1** 处 + 测试桩 **4** 处。**未触发修复循环、未触发回滚**（安全点 `0f531f7` 未使用，保留改动）。

- [ ] T6 文档同步 + thomas-emacs 配置侧（逐条对应「文档清单」）：若 D2 定稿为 A → ① 在 `openspec/decisions.md` **追加**本计划给出的草稿条目（附在下方「## decisions.md 待写入草稿」，格式与既有条目一致：`## 日期 · 标题` + `**决策**` / `**理由**` / `**代价与约束**`）；② 删除 `lisp/init-reader.el` 的 `+seshat-reader-dark-after-render`（advice 定义 + `advice-add` 注册 + 相关注释）与 mode-hook 里「每次重新下发」的必要性说明；③ `init-reader.el` 里加 `(setq seshat-reader-dark-tint 'charcoal)` 作为试用默认；④ thomas-emacs `CHANGELOG.md` 记一条。若定稿为 B → 只保留配置侧「新增默认预设」一项，advice 不动。另外：在 `openspec/active/2026-10-26-reader-multipage-p1-layout.md` 的 T4 条目**末尾追加一行注记**（内容见「文档清单」），**不改其任务内容**——**D2 未定稿不得写这一行**。（依赖：T5 + D2 定稿）

  - [x] **T6 文档部分 ✅（由批次 3b-1 代理执行）**：`openspec/decisions.md` 追加草稿条目（已于批次 0 落盘）+ `docs/architecture.md` / `docs/emacs-reader.md` / `docs/configuration.md` / `emacs/seshat-reader/VENDORED.md` / `CHANGELOG.md` / `emacs/seshat-reader/NEWS` / `openspec/tech-debt.md` + multipage 计划 T4 注记行（内容见「## 文档清单」）。
  - [ ] **T6 配置侧（thomas-emacs）——未勾，待收尾**：② 删 `lisp/init-reader.el` 的 `+seshat-reader-dark-after-render`（定义 + `advice-add` + 注释）与 mode-hook 说明；③ 加 `(setq seshat-reader-dark-tint 'charcoal)`；④ thomas-emacs `CHANGELOG.md` 记一条。**前置**：L3 目测通过后再动配置仓（避免回退时改两处）。

- [ ] T7 L3 真机目测（用户执行）：**重启 Emacs**（新 `.so` 无法热加载）后，用 5 档预设各打开同一 PDF 的同一页，逐项确认：① `charcoal` 正文可久读、对比度可接受；② `graphite` 与改动前观感一致（回退口有效）；③ 彩图/封面单色调可接受；④ `sepia` 亮底可读、装饰（高亮/笔迹）仍可见；⑤ 重载（`C-l` 或重开文档）后仍是暗色与当前预设（D2-A 生效判据；D2-B 下应表现为回白底，与现状相同）；⑥ 切预设后立即刷新（不需重启）。验收：逐项打勾记录在计划「执行记录」。（依赖：T5、T6）

## 执行顺序（每批独立验收）

| 批次 | 任务 | 验收层 | 风险 |
|---|---|---|---|
| 0 ✅ | 采「改动前」PNM sha256 基线（T1 验收用）+ `git stash create` 安全点（`0f531f7`）→ 已完成，数据见「## 基线数据」 | — | 低 |
| 1 ✅ | T1 + T2（C 侧，`clean all` 重编） | L1 + L2（`fboundp` / sha256 / 分支开关） | 中（像素级回归靠 sha256 守门） |
| 2 ✅ | T3 + T4（elisp + 测试） | L1 + L2（定向 ERT） | 低 |
| 3 ⏳（T5 ✅ / T6 文档 ✅、配置侧待） | T5（全量回归）+ T6（文档与配置侧，需 D2 定稿） | L1 + L2 + L3 文档一致性 | 低 |
| 4 | T7 L3 真机（用户） | L3 | 中（观感只能目测） |

- 批次间不跨批提交；批内 C 与 elisp 若互相依赖（`--doc-tint` 未注册时 elisp 侧会 `void-function`），则合为 1 个 feat commit，并在报告中说明理由。

## 实现与计划的偏差

批次 1 / 批次 2 落地时与本计划原文有 5 处不一致。逐条记「偏差 / 理由 / 影响」；**偏离均未改变 D1–D6 的决策内容与验收判据**。

**① 状态变量用 `static bool` / `unsigned`，不是 `static atomic_int`**

- **偏差**：D2 备选 A 的表格与 T1 描述写的是 `static atomic_int g_dark_enabled; static atomic_int g_tint_bg, g_tint_fg;`；实际落地为 `static bool g_dark_enabled` / `g_tint_set` + `static unsigned g_tint_bg` / `g_tint_fg`（`render/render-theme.c`）。
- **理由**：写者**只有一个**——Emacs 模块函数全部在主线程串行调用（`emacs_doc_invert` / `emacs_doc_tint`），读者是同线程的 `render_page_to_buffer`；不存在并发读写，`atomic` 只带来无收益的屏障与类型别扭（`atomic_int` 存颜色需要 `int` 而非 `unsigned`，`0xRRGGBB` 虽在 `int` 范围内但语义上更宜 `unsigned`）。
- **影响**：语义等价、无功能差；**若将来引入后台线程改写配色**（例如按 buffer 切换配色的异步实现），必须回到 `atomic`——已在此登记为约束。 **已被批次 3d 推翻**：评审指出 bg/fg 两次独立 load 会撕裂，最终实现为 `atomic_bool` × 2 + `atomic_uint_fast64_t` 打包（一次 64 位 acquire 读出），见代码 `render-theme.c`。

**② 分支形状是 `if (dark_on && tint_set) … else if (dark_on) …`，不是嵌套 `if`**

- **偏差**：D1 的骨架是 `if (dark_enabled()) { if (tint_is_set()) … else { 旧路径 } }`；实际为「先 `bool dark_on = theme_dark_enabled();` 读一次进程级标志，再 `if (dark_on && theme_tint_set()) fz_tint_pixmap(...) else if (dark_on) { fz_invert_pixmap_luminance; fz_gamma_pixmap(1/1.4f); }`」（`render/render-core.c:334-364`）。
- **理由**：① 进程级标志只读**一次**，两个分支不可能对「暗色是否开着」产生分歧（两次读取之间理论上可被另一次模块调用改掉）；② 旧路径的两行**逐字节等同 HEAD**，缩进层级少一层，`git diff` 上「旧路径未改」一眼可验（T1 验收 ③）。
- **影响**：行为等价；可读性更好，旧路径更易审计。

**③ 计划外新增 `declare-function`（必需）**

- **偏差**：T3 未列该改动；实际在 `emacs/seshat-reader/seshat-reader.el:3035` 新增 `(declare-function seshat-reader-dyn--doc-tint "seshat-render-core" (bg fg))`。
- **理由**：`--doc-tint` 是**新**模块函数，byte-compile 时 `seshat-reader.el` 里没有它的声明 → 新增 1 条 `unknown function` 类 warning，会破坏 T5 的「byte-compile warning 零新增」判据。声明与既有 `--doc-invert` 等模块函数的声明放在一起（同一区块）。
- **影响**：无副作用（`declare-function` 仅编译期）；加后全仓 byte-compile **25 条 = 基线**（`seshat-reader.el` 单文件 20 = 基线 20），零新增。

**④ `emacs_doc_invert` 删掉了 `get_doc_state_ptr` 守卫（外部可见行为变化）**

- **偏差**：D4 与「## decisions.md 待写入草稿」都写「`--doc-invert` 的**无文档时的 `message` + `nil` 守卫全部不变**」；实际实现**删除了该守卫**：无文档时也照常翻转进程级开关并返回 `EMACS_T`。
- **理由**：进程级语义下「暗色是用户偏好」，**设偏好不应要求先有文档**。保留守卫会让两条关键路径失效：① 「先 `(seshat-reader-dark-mode 1)` 再打开 PDF」——新开文档本应直接是暗色（这正是 D2-A 的核心收益）；② thomas-emacs 侧在 mode-hook / 启动早期下发偏好的任何写法。实测：无文档调用返回 `t`，随后 `load-doc` 出来即为暗色。
- **影响**：`--doc-invert` 在**无文档**时的返回契约由「`message` + `nil`」变为「`t`」——这是**外部可见**的行为变化，须在 `docs/emacs-reader.md` 与 `CHANGELOG` 的「变更」段显式写出（已列入「## 文档清单」，由批次 3b-1 执行）；已有文档时行为不变（返回 `t`、arity `1,1` 不变）。**回滚口不受影响**：`graphite` 仍走旧路径。

**⑤ 偏差③的措辞更正：`declare-function` 是孤立声明，不存在「同一区块」**

- **偏差**：③ 的「理由」末句写「声明与既有 `--doc-invert` 等模块函数的声明放在一起（同一区块）」——**这句不成立**。实际 `seshat-reader.el` 里只有 `seshat-reader-dyn--doc-tint` 这一条 `declare-function`（孤立的一条，紧邻 `seshat-reader-dark-tint-presets` 之上），**没有**任何「模块函数声明区块」，`--doc-invert` / `--page-text` / `--text-in-rect` 等其余模块函数至今都是**未声明**状态（byte-compile 因此对它们报 `the function … is not known to be defined`，与 HEAD 基线一致、非新增）。
- **理由**：批次 1 落笔时把「新加一条为压掉新 warning」误写成了「并入既有区块」；此处按事实更正，避免后来者去找一个不存在的区块、或误以为其余模块函数都已声明。
- **影响**：仅措辞更正，无代码改动。**未顺手补齐其余 `declare-function`**：那会把 3 条基线 warning 一并消掉，属于「warning 数量基线」判据的变更，超出本计划范围（登记为可选后续清理）。
- 另记：批次 3d 修掉了 `fz_tint_pixmap` 的实参极性（`(black, white)` 顺序被传反，导致 4 档预设全部极性反转），该修复与本计划 D1–D6 的决策无冲突，验收数据见批次 3d 记录。


## 基线数据（批次 0，2026-10-27 采集）

- [x] 批次 0：采「改动前」PNM sha256 基线（p100 文字页 + p775 彩图/透明 mask 页）+ `git stash create` 安全点（`0f531f7`）

采集时点：2026-10-27 00:47（+0800）｜仓库 `HEAD = 80eb582f6d9b90b95a666d1133149de79c26468a`｜`seshat-render-core.so` **未被重编译**（md5 `501eb33955c69e27d98669c6b904ce1a`，与开工时保护副本 `/tmp/seshat-render-core.baseline.so` 一致）｜安全点引用 `0f531f767cc87e80e32bc1ee526831ba4af8f03c`（`git stash create`，未改工作目录）

| 页号（1-based） | 用途 | 帧尺寸 | PNM 字节长度 | PNM `sha256` | 页文本长度 | 彩色像素占比（72 dpi，chroma>20） |
|---|---|---|---|---|---|---|
| **100** | 纯文字页 | 612×792 | 1454127 | `bdadd357b82f295ab314a1a7d425dbd62523a21034dcb43767b44b8ce65ce907` | 2338 字符 | 2.84% |
| **775** | 彩色插图 **+ 透明 image mask** 页 | 612×792 | 1454127 | `07c793bbd11211a002873afd9b00796c210e49ec3f3c3798bbed7b8ef9d203b6` | 750 字符 | **16.86%** |

**口径（必读，批次 1 补充）**：上表两行是 **暗色关闭（`off`）态**采集的——原采集脚本**未调** `--doc-invert`。因此它们是「改动前 · 暗色关闭」的参考值，对应 T1 验收 ② 的「关暗色时零变化」判据；**它们不是 `graphite` 的比对基准**。

**旧暗色路径参考值（`graphite` 的真正比对基准，旧 `.so` 实测）**：用保护副本 `/tmp/seshat-render-core.baseline.so`（旧 md5 `501eb33955c69e27d98669c6b904ce1a`）+ 显式 `--doc-invert 1` 实测，同页、同 scale（1.0）、同 rotate（0）：

| 页号（1-based） | 用途 | 旧暗色路径 PNM `sha256` |
|---|---|---|
| **100** | 纯文字页 | `ad7b38d566e328d6b12c3f9476768bff32b5d3311de13b393d2db1ca0cdbaea3` |
| **775** | 彩色插图 + 透明 image mask 页 | `9b175a018ad22deacad148f502cd4f5b5ad4bb3bb365f56559712efa6f855dce` |

**两条判据分开用**：`off` 态（未下发 tint、未开暗色）必须等于上方的 `bdadd357…` / `07c793bb…`；`graphite`（开暗色 + tint 哨兵 `-1 -1`，即走旧 invert+gamma 路径）必须等于本表的 `ad7b38d5…` / `9b175a01…`。两组合起来才证明「默认关闭不动」+「`graphite` 回退口逐位等同旧行为」。

**取数细节（踩坑记录）**：`--page-image-spec` 返回的 spec **首元素是符号 `image`**（形如 `(image :type pbm :data … :width … :height …)`），取 PNM 必须 `(cdr spec)` 之后再 `plist-get :data`；直接对 spec 本身 `plist-get :data` 得到 `nil`。

**页号判定依据**：

- **p100（文字页）**：`--page-text`（0-based `99`）返回 2338 字符，首行 `(continued from previous page)`；mutool `-F trace` 显示该页**零** `fill_image` / `clip_image_mask`；72 dpi 渲染帧里 chroma>20 仅 2.84%（来自文字抗锯齿，见 `maxdiff=187` 但无大面积色块），符合「纯文字页」。
- **p775（彩图 + 透明 mask 页）**：`--page-text`（0-based `774`）仅 750 字符（首 `16.3.3 安装库以运行代码`，即图版占主体而言文本稀薄）；mutool `-F trace` 显示该页有 **1 个 `fill_image`（`colorspace=ICCBased(RGB,MX27UC)`，1894×703）+ 1 个 `clip_image_mask`（1894×703）**——同时命中「彩色插图」与「透明 image mask」两条判据；72 dpi 帧 chroma>20 = **16.86%**。全文档 797 页按 20 dpi PAM 全量扫描的 chroma>20 中位数为 **0.88%**，本页为**最高值（20 dpi 口径 17.63%）**，次高 p237（12.95%）。选它是因为 `fz_invert_pixmap_luminance`「保留 chrominance」这半行为**只有大面积彩色像素才测得到**，纯文字/灰度页会放过 `graphite` 回退口最易破的地方。
- **备选页（同样已实测，可随时换用）**：p237（图 6.1.1 沃尔多游戏示例图，`ICCBased(RGB,c2)` 968×726 单图，chroma>20 = 12.50%，sha256 `622353074629771fcdc54ba73d75c3f08e71a625406de53b99ed804392dde171`）；p400（8×`DeviceRGB` + 8×`clip_image_mask`，chroma>20 = 3.10%，sha256 `4373f86303b226ff3dc6bd087dc90bf3c6737b121927e1a8f257dc8b852c21b5`）。

**指标定义**：`chroma = max(|R−G|, |G−B|, |R−B|)`（逐像素）；「彩色像素占比」= chroma > 20 的像素数 / 总像素数，统计对象是**本项目 C 侧** `render_page_to_buffer` 输出的 72 dpi PNM（不是 MuPDF 命令行输出）。

**采集口径与可复现命令**（batch 路径成功，**未用到 `verify` 实例**，因此无实例收尾动作）：

```bash
# 1) 取 PNM 并算 sha256（页号 1-based；load-doc 的页号 0-based）
cat > /tmp/baseline-collect.el <<'ELISP'
;;; -*- lexical-binding: t; -*-
(require 'seshat-reader)
(setq image-flush #'ignore)                    ; batch 下连续渲染必需
(with-current-buffer (get-buffer-create "*baseline*")
  (setq buffer-file-name "/home/thomas/Workspace/seshat/d2l-zh-pytorch.pdf")
  (seshat-reader-dyn--load-doc buffer-file-name 0)          ; 末位参数是 0-based 页
  (dolist (p '(100 775))                                    ; 1-based 页号
    (let* ((props (cdr (seshat-reader-dyn--page-image-spec p 1.0 0)))
           (data (plist-get props :data)))                  ; spec = (image :type pbm :data …)
      (with-temp-buffer
        (set-buffer-multibyte nil)                          ; PNM 是二进制，必须关多字节
        (insert data)
        (write-region (point-min) (point-max)
                      (format "/tmp/baseline-p%d.pnm" p) nil 'silent))
      (princ (format "page=%d bytes=%d sha256=%s type=%S %sx%s\n"
                     p (length data) (secure-hash 'sha256 data)
                     (plist-get props :type) (plist-get props :width) (plist-get props :height))))))
ELISP
cd /home/thomas/Workspace/seshat && \
  emacs --batch -Q -L emacs -L emacs/seshat-reader -l /tmp/baseline-collect.el
# → page=100 bytes=1454127 sha256=bdadd357…ce907 type=pbm 612x792
# → page=775 bytes=1454127 sha256=07c793bb…d203b6 type=pbm 612x792

# 2) 彩色像素占比（PNM 的 P6 头 = "P6\n612 792\n255\n"，之后是 RGB 原始字节）
python3 - <<'PY'
import numpy as np
def load(p):
    b = open(p,'rb').read(); i = 0; toks = []
    while len(toks) < 4:
        while b[i:i+1].isspace(): i += 1
        j = i
        while not b[j:j+1].isspace(): j += 1
        toks.append(b[i:j]); i = j
    w, h = int(toks[1]), int(toks[2]); i += 1
    return w, h, np.frombuffer(b[i:i+w*h*3], dtype=np.uint8).reshape(h, w, 3).astype(np.int16)
for p in (100, 775):
    w, h, a = load(f'/tmp/baseline-p{p}.pnm')
    d = a.max(axis=2) - a.min(axis=2)
    print(f"p{p}: {w}x{h} chroma>20={100*(d>20).mean():.2f}%")
PY
```

**确定性验证（假设 A8 的前提，已实测成立）**：同一进程内对 p100 / p775 各渲染两次，`equal` 均为 `t`、两次 sha256 完全相同；另起独立 `emacs --batch` 进程重跑，两页 sha256 与上表**逐字一致**——「同一 PDF 页 + 同一 MuPDF 版本 + 同一参数 → 确定性输出」在改动前成立，故 sha256 可作机械断言。

**跨 HEAD 复验（取证期间工作区被并行推进，已排除干扰）**：采集过程中并行会话把 `HEAD` 从 `80eb582` 推进到 `c6caf85`（`fix(reader): 像素级连续滚动替代行滚动（一页一行导致 j/k 直接跳页）`），该提交**只改 `emacs/seshat-reader/seshat-reader.el` 与 `emacs/tests/seshat-reader-multipage-test.el`，零 `.c` / `.h`**；`.so` 的内容 md5 始终为 `501eb339…`（mtime 被构建类操作更新到 00:50:19，字节内容未变）。在新 `HEAD` 上重跑同一脚本，p100 / p237 / p400 / p775 四页 sha256 与上表**逐字一致** ⇒ 基线只依赖 `.so` + PDF，与本轮 elisp 改动无关。批次 1 开工前请再确认一次 `md5sum emacs/seshat-reader/seshat-render-core.so` 仍为 `501eb33955c69e27d98669c6b904ce1a`（若已被重编，本表仍是「旧 `.so`」的正确基线，但需记录新的 md5 以说明重编时点）。

**使用约束**：批次 1 一旦 `make -C emacs/seshat-reader clean all` 重编 `.so`，本表即为唯一「改动前」判据来源（`/tmp/seshat-render-core.baseline.so` 只是产物备份，无法替代源码重建）。比对时须与基线取**同一页、同一 scale（1.0）、同一 rotate（0）**——`--page-image-spec` 的 scale 会被 clamp 到 MINRES/MAXRES，1.0 不受影响。

## 文档清单

| 文档 | 需更新内容 |
|---|---|
| `docs/architecture.md`（282、348 行附近） | 「绘制顺序（不变）」改为「装饰在 **tint 或 invert+gamma** **之后**、写 PNM **之前** 绘制」，并新增一句说明存在两条像素变换分支（`graphite` 走旧路径以保 chrominance，其余走 `fz_tint_pixmap`）；348 行 ink 段的同一表述同步 |
| `docs/emacs-reader.md`（168、908、1001 行） | 168 行键位表「暗色模式」一行补「**5 档配色预设，默认 `charcoal`**（`M-x customize-variable seshat-reader-dark-tint`）」；908 行 `render/render-theme.c` 一行补「tint（`fz_tint_pixmap`）与 `--doc-tint`」；1001 行「渲染层的不变量」那段同步 tint 分支 |
| `docs/configuration.md`（「阅读器版式、跨页衔接与批注高亮（M12）」小节） | **素材未列，按仓库惯例补**：新增 defcustom `seshat-reader-dark-tint` 的取值表（5 档 + 自定义 cons + 对比度 + `graphite` 回退说明） |
| `emacs/seshat-reader/VENDORED.md`（`render/render-core.c` / `render/render-theme.c` 条目） | **素材未列，按仓库纪律补**（`docs/emacs-reader.md:999` 的「改 C 的纪律」：任何 C 侧改动必须在该文件的本地改动清单登记）：登记 `render_page_to_buffer` 的 tint 分支、`emacs_doc_tint`、`--doc-tint` 注册、`--doc-invert` 语义改为进程级（D2-A） |
| `CHANGELOG.md`（seshat） | 按既有格式在 `## [Unreleased]` / `### 新增` 下新增一条：5 档配色预设、`--doc-tint`、默认 `charcoal`、`graphite` 逐位等同旧行为；若 D2-A 另起 `### 变更` 条（暗色状态升为进程级） |
| `emacs/seshat-reader/NEWS` | 该文件是 org 格式、按 `* Version X.Y.Z` 分节（当前 `;; Version: 0.3.2`、最新节 `* Version 0.4.0`）：在**最新节下**追加 `- Add =seshat-reader-dark-tint= with five colour presets for dark mode.`（不改版本号，版本号归发布流程） |
| `openspec/decisions.md` | **仅 D2 定稿为 A 时**追加一条（草稿见下节） |
| `openspec/tech-debt.md` | 新增条目：「彩图/封面在 tint 下列色丢失；内容分流（保色图片）未做」——含影响与建议（若将来要保色，需按内容流区域分色或对 image mask 单独处理，属独立议题） |
| `openspec/active/2026-10-26-reader-multipage-p1-layout.md` | **仅一行注记**（D2 定稿后加，加在 T4 条目末尾）：「注：dark-mode 的存储粒度按 `2026-10-27-reader-dark-tint-presets.md` 的 D2 调整（进程级 / 文档级以该计划 D2 定稿为准），T4 的『重渲染全部可见页』不变。」——**不改其任务内容** |
| `/home/thomas/thomas-emacs/CHANGELOG.md` + `lisp/init-reader.el` | 配置侧：`(setq seshat-reader-dark-tint 'charcoal)`；若 D2-A → 删 `+seshat-reader-dark-after-render`（定义 + `advice-add` + 注释）并简化 hook 说明，CHANGELOG 记一条「重载后保持暗色由 C 侧进程级状态保证，移除 advice」 |

## decisions.md 待写入草稿（D2 定稿为 A 后追加，格式对齐既有条目）

> ✅ **已于批次 0 落盘**：`openspec/decisions.md:873` 起已含该条目（含「来源计划」回指）。本节保留为计划内副本与审阅对照，**无需再次写入**。

```markdown
## 2026-10-27 · 阅读器暗色开关与配色升为进程级用户偏好（取代「dark-mode 是文档级」的隐含语义）

**决策**：暗色开关与 5 档配色预设不再存放在 `DocState`（文档级、随 `reset_doc_state()` 清零），改为 `render/render-core.c` 的进程级 `static` 状态（`g_dark_enabled` / `g_tint_bg` / `g_tint_fg`，初值 `0` / `-1` / `-1`）。`seshat-reader-dyn--doc-invert` 的注册名与 arity（`1,1`）不变，语义改为「翻转进程级暗色开关」；新增 `seshat-reader-dyn--doc-tint`（arity `2,2`，`0xRRGGBB` 背景/文字，负值 = 清空 tint 回旧 invert+gamma 路径）。像素变换仍在 `render_page_to_buffer()` 一处（栅格化后、装饰 wash 前、PNM 编码前），按「tint 已设置 → `fz_tint_pixmap`；否则 → `fz_invert_pixmap_luminance` + `fz_gamma_pixmap 1/1.4`」二分支。`DocState.invert` 字段随之删除，「暗色是否开启」只有一个真相来源。

**理由**：① 配色是用户偏好，不是文档属性——同一台机器上看任何一本书都该是同一个观感；② 消灭已知不一致「重载 / 新开文档后回白底、而 elisp 侧 `seshat-reader-dark-mode` 仍为 t」（`reset_doc_state()` 只保留 `active_jobs` / `is_reloading`，`invert` 恒被清零），该不一致正是 thomas-emacs 配置里 `advice-add 'seshat-reader--render-buffer` 的唯一存在理由；③ 多页布局 P1 的 T4 即将重构 `--render-buffer` / `--redisplay-all-windows`，对外部 advice 的依赖越少，重构风险越低；④ 保留 `DocState.invert` 字段却无人读，会成为下一轮的误导源。

**代价与约束**：① 语义变更——上游或第三方若依赖「dark-mode 是文档级」，重载后会看到「仍是暗色」；② 进程级意味着同一 Emacs 内所有 reader buffer 共享同一配色，不能逐 buffer 设置（与「用户偏好」自洽，已写入 `docs/emacs-reader.md`）；③ 单独调用 `--doc-invert 1` 而不下发 `--doc-tint` 的代码会沿用上一次的 tint：**生产代码**该调用点只有 1 处（`seshat-reader-dark-mode` 的 body，`seshat-reader.el:2893`），总是紧随其后下发 tint（含 `graphite` 的 `-1 -1`）；**测试侧**另有 2 文件 3 处 `cl-letf` stub（`seshat-reading-test.el:182`、`seshat-reader-multipage-test.el:706` / `:715`），T3 后需同步补 `--doc-tint` 桩；④ `graphite` 必须与改动前逐位一致（同一 invert + gamma 序列），以 `--page-image-spec` 的 PNM `sha256` 相等为判据；⑤ 多页计划 T4 的「dark-mode invert 定为 C 侧 `--doc-invert`（文档级）」表述只加一行注记，其「重渲染全部可见页」的任务内容不变。
```

## 验证标准

- **L1（语法/构建）**：
  - `elisp_check_parens`：改动的 `seshat-reader.el` 与 `emacs/tests/seshat-reader-theme-test.el` → `parens-ok`。
  - `make -C emacs/seshat-reader clean all` → EXIT 0；C 侧 **warning 数不增加**（与改动前同口径编译一次作对照；`clean` 必带，改 C 必须 `clean all`）。
  - elisp byte-compile warning **零新增**（基线以执行当日实测为对照，multipage 批次 2 记录 20 条；不写死数字，判据是「不增加」）。
  - `make -C emacs/seshat-reader checkdoc` → **0 新增**报错。
- **L2（功能）**：
  - `(fboundp 'seshat-reader-dyn--doc-tint)` → `t`；`(seshat-reader-dyn--doc-tint #x26262b #xa8a49a)` → 非 nil；`(-1 -1)` → 非 nil。
  - **逐位回归（两页口径）**：同一 PDF 页（`d2l-zh-pytorch.pdf` p100）在 `graphite`（tint 未设）下的 `--page-image-spec :data` `sha256` == 改动前基线（在 `verify` 隔离实例内取，`make clean all` 后 `instance stop` → `start` 让新 `.so` 生效，**绝不在主实例上换 `.so`**）；**另取一页含彩色插图或透明 image mask 的页**，同样比对改动前后 `--page-image-spec :data`（PNM）的 `sha256` 相等（与 T1 的 ①bis 同步）。理由：旧路径 `fz_invert_pixmap_luminance` **保留 chrominance**，纯文字页测不到该行为，只比对文字页等于放过 `graphite` 回退口最容易破的一半。
  - **预设生效**：`charcoal` / `midnight` / `sepia` 三种设置下同一页的 `:data` **sha256 互不相同**，且与 `graphite` 都不同（证明分支真的切换，而不是「参数没打通、永远走旧路径」）。
  - **缓存穿透**：切预设后 `seshat-reader--page-spec` 返回的 spec 与切换前不同（`--redisplay-all-windows` 先清缓存）。
  - **ERT**：定向（theme / reading / page-spec / resize / multipage / annotation-decoration）+ 全量 ERT 基线 1144 → **实测 1166 例零回归（31 文件，来源见 T5 执行记录）**，判据 `unexpected = 0` **且** `skipped = 0`（`skipped > 0` 视为假绿）。
  - ERT 命令口径（`emacs/tests/Makefile` 尚未落地，由 multipage T9 建立）：`emacs --batch -Q -L emacs -L emacs/seshat-reader` + straight build 目录集合，逐文件 `-l emacs/tests/<FILE>.el -f ert-run-tests-batch-and-exit`。
- **L3（GUI 手工验收，用户执行）**：T7 的 6 项——`charcoal` 可久读、`graphite` 与旧观感一致、彩图单色调可接受、`sepia` 亮底可读且装饰可见、重载后保持暗色与预设、切预设立即刷新。**批量 ERT 不产生真实 redisplay，观感类结论只能来自 L3。**
- **任务类型**：elisp 验证一律 `verify` 隔离实例（`elisp_mcp_set_task` 传 `verify`）；收尾三步 `set_task auto` → `instance stop` → `instance_status` 确认。

## 注意事项

1. **与活跃 multipage 计划 T4 的边界（硬约束）**：本计划**不得改** `seshat-reader--render-buffer` / `--redisplay-all-windows` / `--page-image-spec` 的语义与布局逻辑，也不得改逐页几何/居中。T4 要改这三者；本计划只在 `seshat-reader-dark-mode` 的 body 里加一次「下发 tint」，其余沿用既有 `--redisplay-all-windows`。若实现中发现必须动这三者之一 → 停下报告，不硬改。**另（共同编辑点）**：`seshat-reader-dark-mode` 的 body（`seshat-reader.el:2883-2894`）是本计划 **T3** 与 multipage 计划 **T4** 的**共同编辑点**——两处不得在同一 worktree 并行编辑，必须**串行合并**（先落地者先合、后落地者 rebase 其上，反之亦然），**合并后重跑定向 ERT**（`seshat-reading-test` / `seshat-reader-multipage-test` / 新建 `seshat-reader-theme-test`）。
2. **装饰绘制顺序是不变量**：像素变换（invert 或 tint）必须在装饰 wash **之前**、PNM 编码**之前**。把 tint 放到装饰之后会让装饰色一起被映射；放到 PNM 之后则进不了缓存位图（翻页回来装饰消失 / 配色丢失）。
3. **`.so` 无法热加载**：改 C 后必须 `make clean all` + **重启 Emacs**（或至少重启 `elisp-test` 实例）。**绝不在主实例上替换 `.so` 试新功能**——按 `rules/elisp-mcp.md` 走 `verify` 隔离实例。
4. **构建命令**：`make -C emacs/seshat-reader clean all`（`Makefile:154` 的 `all` 目标含 `.so` + autoloads + byte-compile + checkdoc）；只改 elisp 时可省 `clean`，改 C 必带。
5. **git 纪律**：worktree 有并行改动（multipage 批次 2 之后的未提交改动可能有）时**不要** `git stash` / `git commit` 无关文件；只用 `git stash create` 取安全点引用（不改工作目录），失败回滚用 `git stash apply <引用>`。提交前 `git status --short` 逐项确认。
6. **`graphite` 的「逐位一致」必须在动 C 之前先采基线**：改动一旦落地、重新编译后旧 `.so` 就没了，基线必须提前采（批次 0）。
7. **D2 未定稿前不要写 `openspec/decisions.md`、不要改 multipage 计划的注记行**——两者都以 D2 裁决为前提。
8. **`--doc-invert` 是外部可见 API**：arity/返回契约不变，但 D2-A 下语义变化必须在 `docs/emacs-reader.md` 与 `CHANGELOG` 的「变更」段显式写出（若有第三方代码依赖文档级语义）。

## 源码事实核对（落笔前抽查结果）

| # | 素材说法 | 实际 | 处置 |
|---|---|---|---|
| 1 | `seshat-reader-dark-mode` 在 `seshat-reader.el:2283` | 实测 `emacs/seshat-reader/seshat-reader.el:**2883**`（`define-minor-mode seshat-reader-dark-mode`；body 在 2891–2894） | 计划与任务全部改用 2883 |
| 2 | `midnight` 对比度 ≈10.9:1 | 按 WCAG 公式重算 **9.74:1**（差 1.16，超出 ±0.3）；`sepia` 素材 ≈9.4 重算 **9.28**（差 0.12，在容差内）；`charcoal` 6.05 / `night-sepia` 8.20 / `graphite` 21.00 与素材一致 | 计划采用重算值，D3 表已改；A6 与 L3 目测校准保留 |
| 3 | `emacs_doc_invert` 的注释描述 | `render-theme.c:25-27` 的 docstring 写「re-renders the current page in a background thread, waits for it to finish, and updates the Emacs overlay」——**与实现不符**：函数只做 `doc_state->invert = invert ? 1 : 0` 后 `return EMACS_T`（`render-theme.c:37-55`），重绘由 elisp 侧负责 | 素材「沿用 `--doc-invert` 的方式：只改状态」是对的；T2 顺手修正该陈旧 docstring |
| 4 | 「选 A 少改 `render-core.h` / `mupdf-helpers.c` 两个文件」 | A 与 B **都**要改这两个文件（A 删 `invert` 字段与初始化，B 加 2–3 字段与初始化） | D2 的推荐理由已更正为 b/c/d 三条（见 D2 的「对素材理由 d 的更正」） |
| 5 | 「`emacs/tests/` 下没有依赖 invert 画面的 ERT」 | 确认：`seshat-reading-test.el:175` 的 `seshat-reading-test-dark-mode-guard-in-derived-mode`（stub 在 `:182`）与 `seshat-reader-multipage-test.el:691` 的 `seshat-reader-multipage-test--geometry-dark-mode-inverts-and-rerenders`（stub 在 `:706` / `:715` 两处）都用 `cl-letf` stub `--doc-invert`，只断言参数与重渲染次数，不碰 C | 一致；但 T3 会在 mode body 里**新增** `--doc-tint` 调用，**两个用例**都未 stub 新函数 → 必 `void-function`（multipage 那例已计入 1144 例基线）；T4 已把两处补桩列为**必须**的最小改动并要求逐处报告 |
| 6 | 「`emacs/tests/Makefile` 固化 ERT 目标」 | 实测 **不存在**（由 multipage 计划的 T9 建立，该计划仍在 Phase 3） | L2 命令按逐文件 `emacs --batch -Q …` 口径写，不引用 `make -C emacs/tests ert` |
| 7 | 文档清单只列 8 个文件 | 仓库纪律要求「改 C 必须登记 `VENDORED.md`」（`docs/emacs-reader.md:999`），且新增 defcustom 按惯例进 `docs/configuration.md` | 文档清单补 2 行（标注「素材未列，按仓库纪律/惯例补」） |
| 8 | elisp byte-compile warning 基线 | 计划素材只说「零新增」；multipage 批次 2 记录为 **20 条**，P0 口径是 33，批次 1 口径是 28——**不同会话口径不同** | 判据写「零新增 + 当日实测对照」，不写死数字 |
