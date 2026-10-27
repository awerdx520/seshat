# 阅读器页间分隔线与 0.5 行间距

## 当前状态
- 阶段：已完成（Phase 4）
- 已确认：方案 ✅、计划 ✅（用户 2026-10-27 确认；plan-reviewer 独立审查通过）
- 结果：T0–T6 全部完成；代码审查通过（1 should-fix + 3 nit 已修）；文档已同步；已归档到 `openspec/completed/`

## 目标

多页连续布局中，每两页之间出现一条贯穿窗口宽度的细横线，线上下合计留白 0.5 行（默认，可调），使页边界在视觉上明确可辨；默认开启，且可一键退回改造前的「两页紧贴」表现。

验收标准：
1. 默认配置：页间一条 2px 实线（`seshat-reader-page-separator-thickness`，可配；实测渲染下限约 2px，1px 拿不到），线上下合计 ≈0.5 行，线垂直居中；
2. `seshat-reader-page-separator` 为 nil 且 `seshat-reader-page-gap-lines` 为 0 时，页间不产生任何附加像素，行为与改造前一致。
3. 几何口径唯一：实际渲染高度与 `seshat-reader--multipage-page-gap-pixels` 完全一致；跨页滚动、末页到底、跨页后 point 落点行为不变。
4. 缩放（`+` / `-` / `W` / `H` / `0`）、窗口 resize、面板开关、宽页横向滚动之后，线条仍贯穿窗口、间距不变。

## 现状事实（代码走查，2026-10-27）

- `seshat-reader-page-gap-lines`：`emacs/seshat-reader/seshat-reader.el:1146`，默认 0，整数行。
- `seshat-reader--multipage-page-row`（:1192）：页行 = 一个 `:align-to` 居中空格 + 一个承载 image spec 的空格 + 换行，一页一行。
- `seshat-reader--multipage-insert-page`（:1376）：页行插入后执行 `(dotimes (_ seshat-reader-page-gap-lines) (insert "\n"))`，即仅追加裸换行。
- `seshat-reader--multipage-page-gap-pixels`（:1906）：= `page-gap-lines` × `seshat-reader--default-line-pixels`（取 `frame-char-height`，不是 `line-pixel-height`）。
- `seshat-reader--multipage-page-span`（:1917）：= 页高 + gap 像素，floor 到 1。
- `seshat-reader--multipage-page-max-offset`（:1926）：中间页上限 = span − 1，末页上限 = 页高 − 窗高，依赖 span。
- `seshat-reader--multipage-page-at-pos`（:1450）：gap 行归前一页，仅比较 marker 位置。
- `seshat-reader--multipage--place-point`（:1999）：落点用页行 marker，不数 gap 行。
- `seshat-reader--multipage-remove-page`（:1419）：删除到下一页行首，天然覆盖分隔行与 gap 行。
- `(space :align-to (- right N))` 全宽对齐已有先例：`emacs/seshat-reader/seshat-reader-outline.el:285`。
- 测试基建：`emacs/tests/Makefile`（`ert` / `check-criteria` 目标，判据见 `emacs/tests/ert-judge.sh`）；多页用例在 `emacs/tests/seshat-reader-multipage-test.el`（100 例，本轮从 92 增至 100）。

## 设计

### D1 buffer 结构

每个页行之后插入一个「分隔区」，默认总高 0.5 行，线在垂直中部。分隔区由 **3 个 buffer 行**组成：

| 顺序 | 内容 | 行高 | 作用 |
|---|---|---|---|
| 1 | 空白行（仅换行） | 上线留白像素 | 页底到线 |
| 2 | 全宽 stretch space + 分隔 face | 线厚度像素（默认 2） | 那条线 |
| 3 | 空白行（仅换行） | 下线留白像素 | 线到下一页顶 |

`seshat-reader-page-gap-lines` 的整行空白排在分隔区**之前**（保持既有语义），两者叠加。

### D2 新增选项与 face

| 名称 | 默认 | 语义 |
|---|---|---|
| `seshat-reader-page-separator` | `t` | 是否显示页间分隔区。nil 且 gap-lines=0 时完全回到改造前行为 |
| `seshat-reader-page-separator-height` | `0.5` | 分隔区**总高**，单位为行，允许小数；0 表示不占空间 |
| `seshat-reader-page-separator-thickness` | `2` | 线的像素粗细（整数）；实测渲染下限约 2px，取 1 也会被渲染成 2px |
| `seshat-reader-page-separator-face` | `((t (:background "gray70")))` | 线的颜色；暗色主题可改 gray40。用 background 填充而非下划线 |
| `seshat-reader-page-gap-lines` | `0`（不变） | 分隔区之外再追加的整行空白 |

四个新定义全部放在 `seshat-reader-page-gap-lines` 附近，`:group 'seshat-reader`，docstring 用英文并包含「改选项后对新打开/重排的布局生效」说明。

### D3 几何单一来源（硬约束）

新增一个函数（例如 `seshat-reader--multipage-separator-segments`）返回三元组 `(TOP THICKNESS BOTTOM)`（像素），保证 `TOP + THICKNESS + BOTTOM` 等于 `seshat-reader--multipage-page-gap-pixels` 中分隔区部分的返回值；行构造函数用同一函数产出的像素值设置三行行高。**禁止在两处独立计算**，否则会在页底产生滚动死区或末页出现假空白（P1 已在 `--multipage-page-max-offset` 的注释中记录过该缺陷）。

分隔区总像素 H = round(height × `seshat-reader--default-line-pixels`)；THICKNESS = min(thickness, H)；上线 = floor((H − THICKNESS)/2)；下线 = H − THICKNESS − 上线。H = 0 时不插入任何行。

### D4 绘制选型与回退阶梯

**首选（T0 实测后确定）**：行高用 **face `:height` 浮点相对缩放**（`ratio = 目标像素 / frame-char-height`），线用 `(space :align-to (- right 0))` 拉满窗口宽的 stretch space + `seshat-reader-page-separator-face` 的背景色。`line-height` 文本属性被实测否决（只能加高、不能压矮）。

回退顺序（只换压缩手段，不改 D1 结构与 D3 口径）：
1. face `:height` 不可用（例如某些终端不按倍率缩放）→ 退到整行（1 行）+ 线，即 `seshat-reader-page-separator-height` 实际取 1；
2. 仍不可用 → 考虑按 `window-body-width` 填充 U+2500 字符（改动面最大、窗口缩放需重写，需重新评估计划）。

### D5 明确不动的部分

- `seshat-reader--multipage-page-row` / `--multipage-write-row`（只碰页行前两个字符）。
- 页号派生 `--multipage-page-at-pos`（分隔行位于下一页行首之前，归前一页，与既有 gap 行语义一致）。
- 跨页滚动 `--multipage-scroll`、`--multipage--place-point`、`--multipage-page-max-offset` 的判定逻辑（只经由 gap 像素函数间接变化）。
- 居中 `--center-page`、缩放与 refit（`--apply-display-scale` / `--refit-window`）、C 侧渲染与 `.so`：零改动。

## T0 实测结论（2026-10-27）

测量环境：verify 隔离实例内自建 pgtk GUI frame（`make-frame-on-display wayland-0`），套用户真实字体 `CaskaydiaCove Nerd Font :height 150`；`frame-char-height` = **24px**、`frame-char-width` = 12px、`window-body-width` = 810px、`frame-scale-factor` = 1.0。

主实例门禁事实：`elisp_mcp_set_task(task="config")` 被拒（报文要求用户执行 `M-x +thomas/elisp-mcp-unlock`，默认 10 分钟；解锁态只存进程内存、无文件旁路）。因此 T0 改为「verify 实例 + 自建 GUI frame」测量，主实例未被写入。**后续任何需要主实例 eval 的验证都要用户先解锁。**

| 项 | 实测 | 结论 |
|---|---|---|
| `line-height` 文本属性（空行，挂换行符） | 0.25 / 1 / 8 → 全部 **24px**；1.5 → 30px；2 → 40px；`t` → 0px | **只能加高、不能压矮**，下限 = 默认行高 |
| `line-height` 挂可见字符 | 全部 24px | 对被挂行无效 |
| 整数语义 | 40 → 40px、60 → 60px | **整数 = 像素**；float = 默认行高倍数；`(nil . RATIO)` = 内容高度倍数 |
| face `:height` 缩放 | 0.15→4px、0.2→5px、0.25→7px、0.5→13px | **可压矮，下限 2px**；空行与含字符行一致 |
| `(space :align-to (- right 0))` | 行宽 810 == `window-body-width` 810（多轮不同 frame 宽均相等） | **精确拉满窗口宽**，无需监听 resize |
| 1px 可行性 | 1px 高图像在真实字体 frame 渲染为 **2px**；face 下限亦 2px | 1px 不可达 → `thickness` 默认取 **2** |
| 中文行 | 25px（拉丁 24px） | gap 基准仍用 `frame-char-height`，与既有口径一致 |

**对设计的影响（已按下述执行，结构 D1 与口径 D3 不变）**：
1. 假设 A1 被推翻 → 放弃 `line-height`，改用**回退阶梯 1**：face `:height` 相对缩放；
2. 分隔区三段的像素高度由 face 倍率 `px / frame-char-height` 表达，映射是**阶梯函数**，实际渲染与名义像素可能差 ±1–2px——记为已知近似，滚动几何使用名义值，测试不得在 ±1px 上做严格断言；
3. `seshat-reader-page-separator-thickness` 默认值由 1 改为 **2**。

**T1–T3 实现后的实测偏差（2026-10-27）**：`Warning|Error` 真实基线是 **18**（强制重编实测，改动后仍 18、逐条指纹 NO-DIFF）；分隔区三段名义 12px（5/2/5）实测渲染为 5/3/5 = 13px，线宽 713 与 `window-body-width` 713 精确相等——确认 face `:height` 阶梯取整带来的 +1px 偏差在容差内，滚动几何继续使用名义值。

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | ~~`line-height` 文本属性可把空行压到亚行高度~~ **✗ 被推翻（T0 实测）**：`line-height` 只能加高、不能压矮（下限 = 默认行高）；改用 face `:height` 相对缩放（下限 2px） | 实测（见「T0 实测结论」） |
| A2 | stretch space 上 face 的 `:background` 必定被绘制（不依赖字体） | 假设?（背景填充机制上比下划线确定） |
| A3 | 分隔行只改 buffer 文本与像素几何，不影响页号派生、跨页滚动、选区坐标 | 事实✓（已核对 page-at-pos / page-span / place-point / remove-page 四条路径） |
| A4 | 默认开启分隔区后，既有几何类 ERT 只需在 fixture 显式绑 nil 即可保持断言强度，无需修改断言数值 | 假设?（multipage-test 92 → 100 例；构造入口是 `--geometry-buffer`（:417），`--scroll-fixture`（:953）经它构造。**已知绝对像素断言三处**：:1170（用例 `--geometry-scroll-up-crosses-page-with-gap`，`gap-lines` 绑定行 :1178）、:1672（用例 `--geometry-scroll-gap-pixels-uses-default-line-height`，断言 :1688 `gap-pixels=40` / :1690 `span=540`）、:1385（用例 `--geometry-page-max-offset-last-page-bounds`，断言 :1414 `max-offset=499` 走中间页公式 `1- span`）。最终以全量 ERT 失败清单为准，上述清单只是起点） |
| A5 | 「0.5 行」指分隔区总高（线垂直居中，上下各约 0.25 行），不是「线下方空 0.5 行」 | 用户显式（2026-10-27） |
| A6 | ~~1px 线在 HiDPI 下仍可见~~ **⚠️ 部分被推翻（T0）**：1px 不可达（face/图像的渲染下限约 2px），默认已取 2；想更粗可调 3–4 | 实测（见「T0 实测结论」） |
| A7 | `line-height` 与 `(space :align-to ...)` 的像素效果只在 GUI frame 生效；`emacs --batch` 下没有 redisplay，ERT 只能断言文本结构与属性（行数、`display`、`face`），像素正确性依赖 T0 的 GUI 探针与 L3 真机目视 | 事实✓（batch 无 redisplay，见 `emacs/tests/Makefile` 头部注释） |

## 任务

- [x] T0 渲染机制探针（依赖：无；**config 主实例**）：在用户当前 Emacs 中新建临时 buffer，分别插入 ① `(propertize "\n" 'line-height 0.5)`、② `(propertize "\n" 'line-height 8)`、③ 整行 face `(:height 0.5)` 的候选行，用 `line-pixel-height` 与 `window-text-pixel-size` 测量实际像素高，并记录 `(frame-char-height)` 作为默认行高基线。产出：可用手段 + 像素换算公式，写入 T2 实现的代码注释。验收：三种手段的实际高度数据齐全，明确选定一种并说明整数单位语义。约束：config 任务下总耗时 <5 秒、禁跑 ERT；收尾 `elisp_mcp_set_task(auto)`。若三种手段都压不动，立即停止并回报，按 D4 回退阶梯 2 处理。测量时用 `with-temp-buffer` + 临时窗口，测完立即 kill buffer 并恢复原窗口，避免干扰用户工作区。
- [x] T1 新增 4 个 defcustom 与 1 个 defface（依赖：T0）：按 D2 的名称、默认值、类型、docstring 落地，位置紧邻 `seshat-reader-page-gap-lines`。验收：`checkdoc` 对新增 docstring 0 报错；`make -C emacs/seshat-reader all` EXIT 0 且 `Warning|Error` 计数 ≤ 基线 18（2026-10-27 强制重编实测基线；CHANGELOG 旧条目里的 24 是更早版本计数，不是当前基线；这 18 是 `Warning|Error` 口径，不是 byte-compile warning）。
- [x] T2 几何单一来源（依赖：T1）：新增 `seshat-reader--multipage-separator-segments`（返回 `(TOP THICKNESS BOTTOM)` 像素三元组）与分隔区总像素辅助函数；改造 `seshat-reader--multipage-page-gap-pixels`，返回「整行 gap 像素 + 分隔区像素」。验收：三元组之和恒等于 gap 像素中的分隔区部分（新增 ERT 守护）；height=0 / separator=nil 时返回 0；thickness 大于 H 时被夹紧且不产生负值。
- [x] T3 插入分隔行（依赖：T2）：新增 `seshat-reader--multipage-separator-rows`（按段生成 3 个 buffer 行的字符串拼接）并在 `seshat-reader--multipage-insert-page` 的 gap 循环之后插入。验收：插入后页行与下一页行之间的行数 = gap-lines + 3（separator 开启且 H>0）；每个分隔行的内容与文本属性符合 D1/D4；`--multipage-remove-page` 仍能整体删除且 marker 不泄漏。
- [x] T4 ERT 用例（依赖：T3）：**机制**——`seshat-reader-page-separator` 是普通全局 defcustom（不是 buffer-local），因此 `let` 绑定必须写在**用例级**（ert-deftest 体内，包住 fixture 构造与随后所有断言），**不得**写在 `--geometry-buffer`（:417）内部——那里的 `let` 在 fixture 返回后即失效，只覆盖「插入阶段」，后续 `--multipage-page-gap-pixels` / `--multipage-page-span` 读回全局默认 `t`，会出现「buffer 里没有分隔行、像素却算入分隔区」的口径分叉，直接违反 D3 与注意事项 1。**起点清单（三处已知绝对像素断言，不改断言数值，只在用例级绑 `seshat-reader-page-separator nil`）**：:1170（`--geometry-scroll-up-crosses-page-with-gap`，`gap-lines` 绑定行 :1178，注释里 `span = 500 + 2 × 10 = 520`）、:1672（`--geometry-scroll-gap-pixels-uses-default-line-height`，:1688 断言 `gap-pixels = 40`、:1690 断言 `span = 540`）、:1385（`--geometry-page-max-offset-last-page-bounds`，:1414 断言 `max-offset = 499`）。**受影响主体还包括触发跨页的 scroll 用例**（例如 :1036 `--geometry-scroll-down-crosses-multiple-pages`，`(should (= 100 (--multipage-scroll 700)))` 依赖 `span = 500` 的精确值；同类还有 :1063、:1136 等）；上述三处绝对像素断言只是可直接定位的示例。**执行顺序（以实测为准，静态清单不是封闭清单）**：先不加任何绑定跑一次 `make -C emacs/tests ert`，收集全部失败用例；逐个在用例级 `let` 绑 nil；重复直到 0 unexpected。**不受影响、不要改动的**：结构/相对量断言（:157、:195、:212、:238、:277、:307、:328、:375 等，涉及 `display-count`、marker 顺序、`page-at-pos`、`count-lines` 差值）；:1400 / :1407 / :1415（末页公式被 `min` 夹掉 gap）；:2866 / :2870（已 stub `--multipage-page-gap-pixels`）。**新增用例**至少覆盖：① separator=nil + gap=0 时无附加像素（span 与基线一致）；② 默认配置下 gap 像素 ≈ round(0.5 × 行高) 且 buffer 中恰有 3 个分隔行；③ 三段像素之和 == gap 像素中的分隔区部分；④ 线行属性断言（`display` 为 `(space :align-to (- right 0))`、`face` 为 `seshat-reader-page-separator-face`）；⑤ gap-lines=2 + separator 时总高 = 2 行 + 分隔区；⑥ height ≤ thickness 的退化分支；⑦ 分隔区开启时跨页滚动的 span 断言按新几何更新（不沿用旧数值）。**ERT 只断言文本结构与属性，不断言像素渲染**（见 A7）。验收：`make -C emacs/tests ert` 0 unexpected / 0 skipped，`make -C emacs/tests check-criteria` PASS。
- [x] T5 文档沉淀（依赖：T4）：更新 `docs/emacs-reader.md` §7 多页连续布局表格与 §选项表（`seshat-reader-page-gap-lines` 相邻处，含 4 个新选项）、`docs/architecture.md` 的「多页连续布局（P1）」小节（:334-338，buffer 结构描述需从「每页一行 + 空行」改为「每页一行 + gap 行 + 分隔区 3 行」）、`CHANGELOG.md` 新增条目（标注**行为变更**：默认页间出现 0.5 行分隔区）、`openspec/decisions.md` 新增决策（分隔区三段结构 + 背景填充选型 + 几何单一来源）、`openspec/tech-debt.md`（若 T0 发现 `line-height` 有版本依赖则登记降级条款）；核对 `docs/configuration.md` 是否收录阅读器选项，收录则同步（已确认 `emacs/seshat-reader/README.org` 不收录，无需改）。验收：逐文件列出更新状态与理由。
- [x] T6 验证与收尾（依赖：T5）：L1（`make -C emacs/seshat-reader all` EXIT 0、`Warning|Error` ≤ 基线 18、checkdoc 0、受影响文件 check-parens 通过）+ L2（`make -C emacs/tests ert` + `check-criteria`）；elisp 验证走 `verify` 隔离实例，收尾三步 `set_task auto` → `instance stop` → `instance_status` 确认。产出 L3 真机验收清单交用户目视，并按批次输出阶段报告。

## 文档清单

- `docs/emacs-reader.md`：§7 多页连续布局（一屏多页、滚动行为表）+ 选项表
- `docs/architecture.md`：「多页连续布局（P1）」小节（:334-338）的 buffer 结构描述
- `CHANGELOG.md`：Unreleased / 新增段
- `openspec/decisions.md`：本轮设计与取舍
- `openspec/tech-debt.md`：仅在 T0 发现版本依赖时新增条目
- `docs/configuration.md`：先核对是否收录阅读器选项，收录则同步（`emacs/seshat-reader/README.org` 已确认不收录，无需改）

## 验证标准

- **L1**：`make -C emacs/seshat-reader all` EXIT 0；`Warning|Error` 计数不超过基线 **18**（零新增；2026-10-27 强制重编实测；byte-compile warning 另有口径，但本仓当前基线以此 18 为准）；`checkdoc` 0 报错；改动的 `.el` 文件 `check-parens` 全部通过。
- **L2**：`make -C emacs/tests ert` → `0 unexpected` 且 `0 skipped`（由 `emacs/tests/ert-judge.sh` 数值判定）；`make -C emacs/tests check-criteria` PASS。
- **L3（真机必需，batch 无 redisplay）**：
  1. 页间可见一条横贯窗口的线，粗细与位置居中，默认配色在明/暗主题下都可辨；
  2. 页间距目视约 0.5 行，两页不再粘成一张；
  3. `+` / `-` / `W` / `H` / `0` 缩放后线仍满宽、间距不变；
  4. 拖动窗口、开关面板后线仍满宽；
  5. 宽页横向滚动（`S-<wheel>`、`C-a` / `C-e`）不破坏线；
  6. 跨页滚动（`j` / `k` / `SPC` / `DEL`）手感不变，末页到底仍停住，`n` / `p` 仍停在页首；
  7. 状态行 `[N/M]` 与 `M-:` 读到的页号正确；
  8. 分别把 separator 设 nil、height 设 0 / 2、thickness 设 2 后，表现符合语义。

## 注意事项

1. **几何口径不能分叉**：任何「插入多少行/多高」的决定必须来自同一函数，`--multipage-page-gap-pixels` 与行构造函数共用它。
2. **不复活单页 overlay**（P1 决策 4）：所有实现都在多页 buffer 布局内。
3. **既有用例的断言数值不得下调**：默认值变更导致的失败，用**用例级 `let` 绑 nil** 隔离（separator 是全局变量，fixture 内部的绑定只覆盖插入阶段，会与断言阶段口径分叉），而不是把断言改成新数值；新增一条「分隔区开启」的独立用例覆盖新几何。执行时以全量 ERT 失败清单为准逐条处理，已知起点为 :1170 / :1672 / :1385 三处，不得预设清单已封闭。
4. **配置变更的生效范围**：插入是增量的，已存在的 gap 行不会被重写；本轮不实现 defcustom `:set` 自动重排，只在 docstring 与文档中说明「改选项后对新打开/重排的布局生效」。若实现成本低（单次 `--multipage-relayout`）可另开任务，不得顺手扩大范围。
5. **C 侧零改动**：不触碰 `render/`、不需要重建 `.so`、不要求重启 Emacs 才能验证（除非 L3 目视）。
6. **不要并入 P2 候选池**：本计划独立编号，`openspec/active/2026-10-27-reader-multipage-p2-followups.md` 保持原样。

## 风险与处置

| 风险 | 处置 |
|---|---|
| ~~`line-height` 压不动空行~~（T0 已确认不可用） | 已按 D4 阶梯 1 采用 face `:height`；若该路径在某终端也失效，退整行（阶梯 1） |
| 背景填充在 stretch glyph 上不出色 | 改 face 为 `:underline` 或 `:box` 再试；仍不行退到填充字符方案（需重评计划） |
| 默认值变更导致大量既有 ERT 失败 | 用例级 `let` 绑 nil（A4），以全量 ERT 失败清单逐条处理，不改断言数值 |
| 0.5 行在 HiDPI 下过窄或过宽 | 选项可调；L3 目视后按用户观感调整默认值并记入 CHANGELOG |
