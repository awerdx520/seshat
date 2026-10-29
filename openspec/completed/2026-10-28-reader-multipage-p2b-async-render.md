# 阅读器多页布局 P2-B：两阶段渲染（尺寸先行 + idle 补位）

## 当前状态
- 阶段：**已完成（2026-10-29）** · 归档路径：`openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` · T1–T10 全部完成（T0 批次 0 的 spike 与 Gate 判定在开工前完成，见「## 验证记录」）。**交付摘要**：两阶段异步渲染（尺寸先行 `--page-size` + 像素后补 idle/周期 timer）+ 4 个 defcustom + 三层兜底 + 运行时回滚开关（`seshat-reader-render-async` = nil）；同批修掉 `:scale 1` canvas 缺陷（页高少算 20%、单页最多 365 px）、页间分隔区 span 少算一个字符行高（5 页累计 90 px，修后实测 0 px）、D8 的两个出口（裁剪按交集 / 态 C 整队清空）。**真机主观验收 ①–⑤ 通过、⑥ 双窗口各自滚动不通过** ⇒ 根因 = P1 布局模型（单 buffer 行驻留集 + 窗口共享 buffer-local 布局状态），已转 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`；本批交付其中「D8 清空路径」半（已修 + 3 例 ERT + 变异测试）。逐批细节（T1 的 C 入口、T2 的尺寸层、T3 的占位行、T4 的代际、T5 的调度器、T6 的三态分流、T8 的 D8 裁剪口径、T9 的 span 修复与 D8 清空路径、代码审查的 4 项）各自见「## 验证记录」下对应小节，此处不复述。
- 审查：plan-reviewer 2026-10-28 有条件通过（0 blocking / 3 major / 7 minor）；本次修订落地 M1（G1 降级依赖闭环）、M2（L2 基线口径）、M3（T2 收敛为平行 alist + 消费方零改动验收；本轮复审已把口径修正为「读 `(cddr entry)` 的 4 处」）、6 项 minor（F5/F8 行号、T1 实现约束、不变量④ 断言、C 侧回滚、README 必改）；第二轮复审 2026-10-28：M2/M6 闭环、M1 闭环、新发现 N1（代际自增点必须挂在全量失效入口 `--page-spec-clear-cache` 而非单页的 `--multipage-forget-specs`，否则滚动回收会误作废全部 pending）已修订，另修 4 处 minor（T5/T8 的 G1 override 提示、T2 消费方归类、失败计数重置语义、T1 行号 195→196）
- 已确认：方案 ✅（用户 2026-10-28 确认）、计划 ✅（用户 2026-10-28 确认，经 plan-reviewer 两轮审查）、Gate 处置 ✅（G1 未触发 / G2 未触发 / G3b 周期 timer，2026-10-29 实测）
- 前置：P1 已归档（`openspec/completed/2026-10-26-reader-multipage-p1-layout.md`）、P2-A 已归档（`openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`）、canvas 后端迁移已提交（`3265652` 代码 + `7e76d15` 文档）
- **L2 最终口径（2026-10-29 归档时）**：**本计划自身口径 = 42 文件 / 1409 → 42 文件 / 1410 例（+1 例）**，0 unexpected / 0 skipped。算术依据（逐批记录逐项相加）：T5 41 / 1383 → T6 42 / 1396（+13）→ T8 42 / 1403（+7）→ T9 span 42 / 1406（+3）→ T9 D8 清空路径 42 / 1409（+3）→ 代码审查批 42 / **1410**（+1，`seshat-reader-multipage-async-render-test.el` 18 → 19）；T7 / T10 是纯文档批，**零新增用例**。**实跑数字含同一工作区的并发会话**：代码审查批实跑 **43 文件 / 1433 例**（= 1410 + 并发会话的 `seshat-log-test` 12 例 + `seshat-state-test` 新增 11 例；FILES 42 + 1 = 43）；T10 文档批实跑 **45 文件 / 1473 例**（再 + 并发会话的 `seshat-covers-test` 23 例 + `seshat-reads-test` 17 例；FILES 43 + 2 = 45），其中 `seshat-covers-test-invalid-uid-creates-nothing` 报 `(void-variable calls)`——属并发会话未完成的新用例（未跟踪文件），与本计划无关，故本轮实跑为 45 / 1473 / **1 unexpected（来自并发会话）**。**判定「零新增」必须用本计划口径（42 / 1410），不得用实跑总数。**
- **口径已确认（2026-10-29，harspower）**：本计划自身口径 = **42 文件 / 1410 例**（42/1409 + 代码审查批 1 例）。此前任务书给出的「+11 → 42/1420」系把并发会话 `seshat-state-test.el` 的新增 11 例误记到本计划，**已作废，不得引用**。各批执行记录里的实跑数字保留原值（它们是实测值，含并发会话）。
- 下一步：**无（本计划已归档）**。T1–T10 全部完成；真机 ①–⑤ 通过、⑥ 双窗口项转 P1 follow-up（`openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`，草案 / 候选池，待用户圈定方案 A/B/C）。后续动作：① 用户在重启后的主实例上按同口径复核 ①–⑤（本批只改 elisp、C 侧仅新增零副作用入口，重启即生效）；② 需要回滚时 `(setq seshat-reader-render-async nil)`（运行时、无需重启），C 侧回滚须回退源码 + `make clean all` + 重启；③ 遗留缺口见 `openspec/tech-debt.md`「阅读器两阶段异步渲染（P2-B）遗留（2026-10-29）」6 条。

## 目标

1. **把像素渲染移出滚动同步路径**：滚动进入新页时只同步做「页尺寸查询」，像素渲染延后到 idle。
2. **守住 P1 的不变量**：占位页的页高必须与真实 image 的 `:width`/`:height` 一致 ⇒ 滚动范围不跳变、`window-vscroll` 不被 redisplay 回滚。
3. **可降级、可回滚**：视口内关键页仍同步渲染；pending 超时强制同步；`seshat-reader-render-async` 设 `nil` 即回到现状行为（逐字节等价）。
4. **顺带交付 `--page-size` C 入口**：P2-7（渲染基准回退分支）所需的「批量查页尺寸」能力由此满足，P2-7 之后只剩「选哪个基准」的判定。

## 非目标（明确不做）

| 不做 | 理由 |
|---|---|
| 重建 worker 线程池 / 真后台栅格化 | `render-threads.c/.h`、`CachedPage`、`EmacsWinState` 已在 canvas 迁移中整族删除（`VENDORED.md:113`）；`DocState` 有单线程纪律（`render/render-core.h:113-118`），装饰表由主线程拥有（同文件 `140-145`）；`canvas_data` 指针不可跨调用缓存（`render/elisp-helpers.c:236-238`）⇒ 属「重建调度器 + 快照 + 生命周期」，规模远超本项 |
| 改缓存键加入 tint / 暗色 | 已有显式清缓存路径（`--redisplay-all-windows`，`seshat-reader.el:3874`），加键会让缓存翻倍、淘汰更早 |
| 改 `:data-width`/`:data-height` 只写一次的语义 | canvas 后端硬约束，动了就残影/花屏（`render/elisp-helpers.c:145-152`、`seshat-reader.el:1455-1462`） |
| 扩大驻留集 / 预取范围 | 每页 canvas 缓冲 ≈1.9 MB，扩大范围直接撞 75 MB 告警线（`seshat-reader.el:1206`）；本轮只把「驻留集内」的像素渲染异步化 |
| 改 location 协议、selection / annotation / search 行为 | 与本项正交 |

## 背景与第一性依据

**事实（已查证，带行号）**

| # | 事实 | 依据 |
|---|---|---|
| F1 | 取 spec 的生产路径只有 2 处：`--multipage-render-page`（视口路径）与 `--multipage-prefetch`（预热路径） | `seshat-reader.el:1707`、`1863` |
| F2 | `--multipage-sync` 在 range 变化时逐页同步渲染，随后同步预取、查内存 | `seshat-reader.el:1918-1963` |
| F3 | 触发点共 4 类：`post-command-hook`、`window-state-change-functions`、跨页滚动函数自身、zoom/goto | `3808`、`3803`、`2357`/`2311`/`2319`、`550`/`2003` |
| F4 | `pre-redisplay-functions` 上已有 hook（`--pre-redisplay-center`）但**不渲染**，只重写 `display` 属性（可复用的每帧挂点） | `3804`、`2632-2646` |
| F5 | 页面承载 = 每页一行文本 + `display` 文本属性（`align-to` + image spec），页表 `seshat-reader--pages`（`(PAGE MARKER . SPEC)`；结构定义在 `seshat-reader.el:462` 的 `defvar-local`，`1313-1330` 为 write-row 系、「`spec=nil` = 占位」语义所在） | `462`、`1247-1267`、`1313-1330`、`1477-1534` |
| F6 | 未渲染页已是既成占位态（`"  \n"`、无 `display` 属性），但页高按 0 参与滚动（span 下限 1） | `1247-1267`、`2010-2016`、`2093-2100` |
| F7 | 缓存键只有 `(PAGE SCALE ROTATE)`，**无代际号**；清缓存挂点 4 处 | `996-1007`、`2446`/`3294`/`3375`/`3874` |
| F8 | 预取**已实现但同步**，只暖滚动方向 1 页，方向变量 `--multipage-scroll-direction`（`defvar` 在 `1232`，实际 `setq` 在 `2321`；`2310` 是 `--multipage-scroll` 的 docstring） | `1838-1866`、`1232`/`2321` |
| F9 | 已有 4 套可复用的防重入/去抖：`--multipage-syncing` / `--multipage-last-range` / `--refitting` / `--drag-threshold` + `--schedule-refit` 范式 | `1632`、`1641`、`144`、`164`/`170`、`2780-2790` |
| F10 | idle timer 在 daemon 下**从未验证**；且 `sit-for` 期间不算 idle（必须真实空闲） | `openspec/tech-debt.md:1131-1137` |
| F11 | 主线程硬约束：`create-image` / `env->canvas_data` / `canvas-refresh` 都在 `emacs_env` 生命周期内 | `render/elisp-helpers.c:203`、`238`、`255-270` |
| F12 | 渲染返回 nil 时**不报错不重试**，直接落占位行 | `seshat-reader.el:1707-1717`、`1316-1321` |

**关键拆解**：布局真正需要的只有**页高**，它来自页面 bounds（MediaBox/CropBox × scale × rotate），与栅格化无关。因此「异步」不必等于「后台线程」，可拆为「尺寸先行（同步、微秒级）+ 像素后补（idle）」。

**假设（待批次 0 验证）**

| # | 假设 | 来源 | 验证 | 结果 |
|---|---|---|---|---|
| A1 | `fz_bound_page` 级别的页尺寸查询是微秒级、不发像素 | 假设? | S4（并入 T1 验收） | 待 T1 |
| A2 | `(space :width W :height H)` 占位与同尺寸 canvas image 的**行像素高相等** | 假设? | S2 | 成立 ✓（4/4 组差 0 px，独立 GUI 实例实测） |
| A3 | 用户可感卡顿阈值 ≈ 单页 >10 ms | 类比⚡（60 Hz 帧预算） | S1 分布 + 真机 B8 主观 | 成立 ✓（S1：letter 页 8–10 ms 尖峰、扫描书 p50 19 ms） |
| A4 | 视口外页的 idle 补位不会被用户看见空白页 | 假设? | 设计约束（视口内同步）+ L3 | 待 L3（视口内同步的设计约束） |
| A5 | daemon 下 idle timer 可用 | 假设? | S3 | **部分被推翻 ✗**（会触发，但一个 idle 窗口只 fire 一次，不可作为自续驱动） |

## 设计决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | **两阶段渲染**：同步只查页尺寸，像素交 idle | F11 + 非目标第 1 条：线程池代价不成比例；页高与像素解耦是结构性事实 |
| D2 | **页高来源改为 bounds**（`fz_bound_page`），不再等像素渲染 | 唯一能让「占位」与「已渲染」两态页高一致的来源 |
| D3 | **占位形态定稿 = `(space :width (W) :height (H))`（括号形式）**，W/H 取 spec 的 `:width`/`:height`（`:scale 1` 后的显示尺寸，与真实 image 行高一致）。**硬约束：W/H 必须是列表元素 `(W)`/`(H)`，裸数字会被当作字体尺寸倍数——实测 `(space :width 612 :height 792)` 行高 19008 px（= 792×24）**。备选「1×1 占位 canvas image」在批次 0 判定后不再需要（G2 未触发），仅作为将来若出现「space 与 image 高度不等」时的回退记录。 | space 无像素成本；备选保留同一位置语义 |
| D4 | **代际作废**：`seshat-reader--multipage-render-generation` 整数，统一在 **`--page-spec-clear-cache`（全量失效入口）** 内自增；缓存写入、尺寸缓存写入与 idle 回调都比对代际 | F7：缓存键无代际，快速缩放/切暗色/relayout 后必须能丢弃在途结果。**为什么不是 `--multipage-forget-specs`**：该函数是**单页粒度**（`seshat-reader.el:1431` 只删指定页条目），且 `--multipage-recycle-page`（滚动回收远页）也调它——若在此自增，则「每回收一页就作废全部在途 pending」，持续快速滚动时 idle 补位被系统性作废、退化为超时强制同步，直接吃掉本计划的核心收益。故：**全量失效才自增，单页 forget（recycle / 单页 rerender）不自增**；F7 的 4 处清缓存挂点（rotate / close / reload / redisplay-all）即全部作废时机 |
| D5 | **视口内同步 + 超时兜底**：point 所在页与滚动方向第一页始终同步；pending 超 `--render-async-timeout` 未清空则下一次 `post-command-hook` 强制同步 | F10/A5：idle 可靠性未知，必须有两条独立保险，且不能出现「用户长时间看空白页」。**第三条保险（G3b 实测后加）**：idle 仅作首轮启动，队列推进由 `run-at-time` 周期 timer 承担（`run-with-idle-timer` 在 daemon 下不会因回调自续而重复 fire —— 实测 ticks=1）。 |
| D6 | **开关** `seshat-reader-render-async` 默认 `t`，`nil` 时完全走旧路径 | 回滚口；亦作为 L2 等价性测试的对照分支 |
| D7 | **pending 不占 `--page-spec-cache`**：渲染完成才入缓存 | 否则 pending 页把缓存挤满、命中率归零（P0 实测顺序扫 20 页命中率 0 已说明缓存紧张） |
| D8 | **pending 为 buffer-local 集合并集**（多窗口取并集），非窗口级状态 | P1 L3-⑪ 要求双窗口各自滚动；窗口级状态会互相覆盖 |

## 批次 0：Spike 与判定门（先于任何生产代码）

| Spike | 做法 | 记录 |
|---|---|---|
| **S1 耗时分布** | batch 脚本（放 `/tmp`，不进仓库）：`emacs -Q --batch` 加载 `emacs/seshat-reader/*.el` + 动态模块，打开样本 PDF，逐页调 `seshat-reader--page-spec` 计时；样本 ≥2 份（`/usr/share/doc/ghostscript/Ghostscript.pdf` 前 100 页 + 一份大页/图纸 PDF，缺失则跳过并在报告说明）；输出 p50/p95/max 与「按页面面积分桶」（≤1.0×letter、1.0–2.0×、>2.0×） | 表格写进「## 验证记录 · 批次 0」 |
| **S2 占位高度等价（真机）** | 同一 PDF：A 页用 `(space :width W :height H)` 占位，B 页用同尺寸已渲染 canvas image；比较两页在 buffer 中的行像素高（`(window-lines-pixel-dimensions)` / 页 marker 到下一 marker 的像素距离） | 记「相等 / 差 N px」 |
| **S3 daemon idle（真机）** | `emacs --daemon=<临时名>` + `emacsclient -c`，起一个 `run-with-idle-timer 1` 打点，手离开键鼠静置 ≥2 s，看 `*Messages*` | 记「触发 / 未触发」；**注意 `sit-for` 不算 idle** |
| **S4 尺寸查询成本** | 并入 T1 验收：实现 `--page-size` 后测单次耗时（≥200 次中位） | >1 ms ⇒ 改批量入口（一次返回整本页尺寸），否则保持单页入口 |

**判定门（Gate）**

| Gate | 条件 | 后果 |
|---|---|---|
| **G1** | S1 的 p95 < 5 ms **且** max < 20 ms | 触发**降级方案 B**（现状已够快 ⇒ **显式放弃目标 1「把像素渲染移出滚动同步路径」**，改做纯 idle 预热）。裁剪细则（覆盖下文 T2–T8 的默认依赖，须逐条执行）：① **T2/T3 取消**；② **T5 退化为「纯 idle 预取」**——只预热 `--page-spec-cache`，**不补位、不读尺寸缓存、不依赖占位行**，故其依赖从「T3、T4」改为仅「T4」；③ **T6 取消改造**（不做「视口内同步 + 其余登记 pending」），仅保留「`--multipage-prefetch` 改为向 pending 登记」单条；④ **T8 的测试对象改为「代际作废 + 纯 idle 预取」**（原三态用例随 T6 取消），依赖从「T6」改为「T5」；⑤ **T1/T4/T7 照做**（`T7` 的 4 个 defcustom 仍加，但 `seshat-reader-render-async` 在 G1 下默认值取 `nil` 并在 docstring 注明「现状已够快，此开关仅作实验口」）；⑥ **T9/T10 照做**，其中 L3 收敛为「连续滚动无回归 + idle 预取确实生效」两项；⑦ 阈值依据：p95 < 5 ms 留 3× 余量以覆盖「滚动一屏 2 页 + 预取 1 页」的帧内叠加，严于 A3 的 10 ms 单页卡顿线。裁剪理由与判定写入「## 验证记录 · 批次 0」。**批次 0 判定：未触发**（合计 p95 29.87 ms / max 51.85 ms；最快样本 p95 仍有 8.34 ms）⇒ 不启用降级方案 B。 |
| **G2** | S2 高度不等（差 ≥1 px） | T3 走备选（1×1 占位 canvas image）；若备选仍不等 ⇒ 停止，回到方案讨论，不硬推。**批次 0 判定：未触发**（`:scale 1` 修复后 4/4 组差 0 px）⇒ T3 采用 `space` 方案。 |
| **G3** | S3 的 daemon idle 行为：① 完全不触发（idle 判定坏）② **只触发一次（无新输入不 re-arm）** ③ 可重复触发 | **批次 0 判定 = ②（实测 ticks=1，此后不重复；普通 run-with-timer 正常）** ⇒ idle 只作首轮启动，队列推进改用 `run-at-time` 周期 timer（间隔取 `seshat-reader-render-idle-delay`）；pending 超时强制同步保留为最后保险；若将来观测到 ① 则全链路只用周期 timer。 |

## 任务

- [ ] **T0 批次 0 spike 与判定**：按上表执行 S1 / S2 / S3（S4 随 T1），把数值与 Gate 判定写入本文件「## 验证记录 · 批次 0」。验收：S1 有 p50/p95/max + 分桶表；S2 有 px 差值；S3 有触发结论；G1–G3 逐条给出「触发/未触发 + 采纳的动作」。（依赖：无）
- [x] **T1 C 侧 `--page-size` 入口**：新增 `seshat-reader-dyn--page-size`（arity 2..3：page 1-based、scale、可选 rotate），内部用 `fz_bound_page` + 与渲染同口径的 rotate/scale 换算，返回 `(W H)` 逻辑像素（含设备像素尺寸可选返回）；**零副作用**（不建 display list、不分配像素、不进 DocState 缓存）。验收：`make all` 0 error 0 warning；`nm` 入口数 14 → 15；真实 PDF 上单次耗时中位（A1 判定）；对 `9999` 页与 `0` 页返回 nil 不崩。**实现约束**：**不得复用 `load_page_dl`**（`render/render-core.c:196` 把 `fz_bound_page` 与 `fz_new_display_list_from_page` 耦合在同一 `fz_try` 内；该函数体在 `230-232` 行），须新增独立路径 `fz_load_page → fz_bound_page → fz_drop_page`；「与渲染同口径」的具体换算 = 页面 bbox 经 `fz_transform_page` 的 rotate+scale 变换后除以 `frame_scale`。**口径约束**：`--page-size` 返回的 W/H 必须与 spec 的 `:width`/`:height`（`:scale 1` 后的**显示尺寸**）同口径，不得返回 PDF 逻辑 pt 或未乘设备 scale 的值；否则 T2/T3 的页高会与实际显示不一致。（依赖：T0）
- [x] **T2 elisp 页尺寸层**：`seshat-reader--page-size`（C 入口的包装 + `ignore-errors` + 无模块时返回 nil）；「有尺寸、无 spec」态统一采用**平行 alist**——新增 buffer-local `seshat-reader--multipage-page-sizes`（键 `(PAGE SCALE ROTATE)`，值 `(WIDTH . HEIGHT)`，容量沿用 `--multipage-cache-limit`），**不改 `seshat-reader--pages` 的 `(MARKER . SPEC)` 结构**。**理由（已收敛，不再二选一）**：`spec = nil` 仍是「未渲染」的唯一表达，读 `(cddr entry)` 的 4 处消费方零改动——`--multipage-page-pixel-height`（约 `seshat-reader.el:2013`）、`--multipage-max-page-width`（约 `1390`）、`--multipage-page-should-center-p`（约 `1351`，其判定依赖 spec 身份的 `eq` 比对，`:size-only` 会破坏该语义）、`--multipage-resize-spec`（约 `1452`）；另 `--multipage-native-size` **本就不读 spec**（它读独立缓存 `seshat-reader--page-native-sizes`，约 `1395-1399`），任何方案下都零改动，但「有尺寸无 spec」态下它返回 `nil`（不报错）。若改用 `:size-only` 标记，需加分支的是**读 `(cddr entry)` 的 4 处**。尺寸缓存与 spec 缓存**同域同步清理**（复用 F7 的同一组 4 处清缓存挂点）。验收（**已修订：T2 改为只交付尺寸层，消费方行为断言随 T3 的占位分支一起做**）：① ERT 断言「查尺寸不触发渲染」（计数桩断言 C 渲染入口调用 0 次）；② ERT 断言缓存的四条语义——未命中调 C 一次并写入、命中不再调 C、失败不缓存、容量与既有淘汰策略一致；③ ERT 断言两类清理挂点：`--page-spec-clear-cache`（全量失效入口）清空尺寸缓存、`--multipage-forget-specs`（单页，recycle 远页走这里）**保留**该页尺寸；④ 无模块（`fboundp` 为 nil）时返回 nil 且不抛错。原「② ERT 断言『仅尺寸已知（`spec=nil`）』态下**读 `(cddr entry)` 的 4 处**消费方…」已移入 T3 的验收。（依赖：T1）
- [x] **T3 占位行与布局稳定性**：`--multipage-page-row` 增加「已定尺寸未渲染」分支，按 G2 结论用 **`(space :width (W) :height (H))`（括号形式，W/H 取 spec 声明值）**，保证页高与已渲染态一致；`--multipage-insert-page` / `--multipage-resize-spec` 对占位态的处理；渲染完成「补位」时**不得移动任何页 marker**（只改 `display` 属性）。验收：ERT 断言「占位态页高 == 已渲染态页高」「补位前后页 marker 位置不变」；真机 L3-①（无跳变）；③ 用批次 0 的真机方法（独立 GUI 实例、`window-text-pixel-size` 放开 X/Y 上限）复验「占位行高 == 该页真实 image 行高」，4 组样本差 0 px；④（**由 T2 原验收②迁入**）ERT 断言「仅尺寸已知（`spec=nil`）」态下**读 `(cddr entry)` 的 4 处**消费方返回值/行为与「已渲染」态一致（页高相等、最大宽相同、居中判定一致、`--multipage-resize-spec` 不报错），`--multipage-native-size` 在该态返回 `nil` 且不报错。（依赖：T2、G2）
  - **T3 真机验收的时序更正（2026-10-29）**：本批单独完成时 L3-①「滚动无跳变」**无法观察**——此刻还没有任何调度器会让页面停在「仅尺寸」态（尺寸缓存目前只由显式 `--page-size` 调用填充，生产路径仍直接渲染）。故 L3-① **顺延到 T6 之后、与 T9 的第⑥项一起做**；**不得**因「T3 没做真机」判为「T3 未验证」。L3-③（占位行高 == 真实 image 行高）已由批次 0 的 S2 在 `.so` 重建后实测 4/4 组差 0 px 覆盖，也不再重复。批量等价断言见「验证记录 · T3 执行记录」。
- [x] **T4 代际作废**：`seshat-reader--multipage-render-generation`（buffer-local 整数），**在 `--page-spec-clear-cache` 内自增**（**不是** `--multipage-forget-specs`，理由见 D4：单页 forget 被 `--multipage-recycle-page` 调用，在此自增会让滚动回收误作废全部 pending）；`--page-spec-remember`、尺寸缓存写入与 idle 回调入口都比对代际，不匹配则丢弃（回调不写缓存、不写尺寸、不补位）。该入口同时清空 `--multipage-page-sizes` 与 `--multipage-render-failures`。验收：① ERT 断言「先登记 pending → 走 `--page-spec-clear-cache` 清缓存 → 触发 idle 回调 ⇒ 缓存无新条目、行仍是占位」；② ERT 断言「单页 `--multipage-forget-specs`（模拟 recycle）**不改变**代际、不丢弃在途 pending」——这条是防过度作废的回归守卫。（依赖：无，可与 T1 并行）
- [x] **T5 idle 调度器（替换同步预取）**：`--schedule-async-render`（复用 `--schedule-refit` 的「cancel + 单 timer + buffer 入参」范式）；pending 集合按代际与可见范围整理，每轮最多渲染 `seshat-reader-render-idle-batch`（默认 2）页；渲染后补位；**队列推进由 `run-at-time` 周期 timer 自续**（间隔 = `seshat-reader-render-idle-delay`），直到 pending 空或代际变化；**不得依赖 `run-with-idle-timer` 重复 fire**（G3b 实测：一个 idle 窗口只 fire 一次）；`--multipage-prefetch` 改为向 pending 登记（不再同步取 spec）。验收：ERT（桩 `run-with-idle-timer` 捕获回调手动执行）覆盖「登记→补位→pending 清空」「代际变化后不补位」「每轮上限生效」；④ ERT 断言「idle 回调只被消费一次、后续推进来自周期 timer」（桩住两种 timer 分别计数）。（依赖：T3、T4；**G1 触发时依赖改为仅 T4**）
- [x] **T6 `--multipage-sync` 改造**：视口内「point 所在页 + 滚动方向第一页」同步渲染（保持现状手感），其余可见页登记 pending；超时兜底（`--render-async-timeout`，默认 1.0 s，G3 触发则 0.2 s 并加 `run-at-time` 兜底）；`seshat-reader-render-async` 为 nil 时走旧路径（逐页同步 + 同步预取）。验收：ERT 覆盖三态（默认异步 / 超时强制同步 / 开关关闭等价旧行为）；真机 L3。（依赖：T5、T7）**执行记录见「## 验证记录 · T6 执行记录（2026-10-29）」**；「视口内」定稿为「point 页 + 沿 `--multipage-scroll-direction` 相邻的一页」（不是「视口两端都同步」），理由与取舍写在同一节。
- [x] **T7 四个 defcustom 的文档同步 + customize 验证**（**本批不新增任何变量**）：4 个变量已在 T5（`seshat-reader-render-idle-delay` 0.05 / `seshat-reader-render-idle-batch` 2）与 T6（`seshat-reader-render-async` t / `seshat-reader-render-async-timeout` 1.0）落地，T7 **只做**：① `docs/configuration.md` 同步这 4 个变量（语义、默认值、nil/0 的边界）；② `README.md`/`Readme.org` 说明默认行为由「全同步」变为「先空白后清晰」并给出回滚口径；③ `M-x customize-option` 逐个可见（`:type`/`:group` 已就位）；④ 编译 warning 不新增。**注意：不得重复定义**这 4 个 defcustom——重复 `defcustom` 会让 `customize` 里出现两份条目、`defcustom` 的 `:set` 语义失效（历史教训见 T5 记录的偏差第 4 条）。**4 个 defcustom 数量不变，仅语义澄清**（`--render-idle-delay` 由「idle 延迟」改义为「周期推进间隔」）。（依赖：无）**已执行（2026-10-29）**：`docs/configuration.md` 新增「阅读器两阶段渲染（P2-B，2026-10-29）」节（4 变量表 + 三层兜底说明 + `render-async-timeout` 的 `0`/负数/非数字边界如实写：`0`/负数 ⇒ 判据恒成立、几乎总是同步；非数字 ⇒ `numberp` 守卫使永不超时）；`README.md` 新增「阅读器渲染：默认两阶段异步」节（行为变更 + 回滚口径 + 4 变量简表），`Readme.org` 加对应小节；customize 可见性用 `emacs -Q --batch` 实测——4 个变量 `custom-variable-p` 全 `t`、`custom-type` 分别为 `boolean`/`number`/`number`/`integer`、全部在 `seshat-reader` 自定义组内；**零重复 `defcustom`**（未改 `seshat-reader.el`）。
- [x] **T8 测试补齐与等价性**：新增/改造用例覆盖 D1–D8；特别包含「`seshat-reader-render-async=nil` 时与旧路径行为等价（同一 PDF 同一页的 spec 几何一致、marker 一致）」与「双窗口 pending 并集」。验收：`make -C emacs/tests ert` 0 unexpected 0 skipped；`check-criteria` PASS。（依赖：T6；**G1 触发时依赖改为 T5**）**执行记录见「## 验证记录 · T8 执行记录（2026-10-29）」**——本批同时修掉 D8 的实现缺陷（裁剪口径由交集改为并集）。
- [x] **T9 L1/L2 全量 + 真机 L3**：L1 `make -C emacs/seshat-reader clean all`（EXIT 0、C 0/0、elisp warning ≤ 20、checkdoc 0）；L2 全量 ERT + `check-criteria`；L3 真机：① 连续快速滚动无卡顿（且 B8 主观对比批次前后）；② 大页首次进入「先空白后瞬清」可接受；③ 缩放/切暗色期间不出现旧代际像素；④ daemon + `emacsclient -c` 真实空闲后 pending 清空；⑤ 双窗口各自滚动正常；⑥ 页高与滚动几何一致：`:scale 1` 修复后，多页布局的页高/滚动范围与真实显示高度一致（修复前单页最多少算 365 px），主实例重启后同口径复验一次。**C 模块重编译后必须重启 Emacs**。（依赖：T8） **已执行（2026-10-29）**：①–⑤ 通过（用户真机回报）；⑥ 页高/滚动几何由独立 GUI 进程三方口径实测差 0 px（含分隔区 span 修复后），**双窗口各自滚动不通过** ⇒ 根因 P1 布局模型，转 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`（详见「## 验证记录 · T9 客观测量 / T9 真机主观验收」）。
  - **⑥ 转 P1 follow-up（2026-10-29 用户回报后判定）**：双窗口主观项**不通过**（另一窗口变背景色；滚 A 时 B 跟着动且随机）。根因不在本批的异步机制，而在 **P1 布局模型**（单 buffer 行驻留集 + 窗口共享 buffer-local 布局状态），本批的 D8 违规（态 C 整队清空丢掉另一窗口的 pending）只是**放大**了它 —— 该半已在本批修掉（见「### T9 D8 清空路径修复（2026-10-29）」）；「双窗口各自滚动 / 行驻留集按窗口」另立 P1 follow-up 计划。故本项 checkbox 在 D8 修复批次仍不勾，但⑥的归属与处置已闭环（**T10 归档时按 ①–⑤ 通过而勾选**，⑥ 的验收归属见本节第 3 条）。
  - **①–⑤ 已由用户 2026-10-29 回报通过**（重启正常、fit-height 正常 / fit-width 卡顿较长但比改造前变好、进入新页正常无跳变、缩放后清晰但连按缩放卡顿明显、切暗色正常），明细见「### T9 真机主观验收（用户 2026-10-29 回报）」；其中②④的「卡顿」属 `render-idle-batch` 默认值取舍（T6 记录末段的待确认建议），不在本批修改范围。
  - **归档时的勾选结论（T10，2026-10-29）**：本项**勾选**——主观 L3 的 ①–⑤ 已通过（用户真机回报），**⑥ 双窗口项转 P1 follow-up**（见 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`），①–⑤ 通过；本批交付的「D8 清空路径」半已修复并有 3 例 ERT + 变异测试守护；L1/L2 全量与 `check-criteria` 均在本批实跑通过（数字见「## 当前状态」）。勾选**不等于**「⑥ 通过」——⑥ 的验收归属见 follow-up 计划。
- [x] **T10 文档沉淀与归档**：按「## 文档清单」逐项更新；计划移入 `openspec/completed/`；`openspec/tech-debt.md` 勾销 P2-1（异步渲染未做）；roadmap 更新 P2 池状态（P2-1 完成、P2-7 因 `--page-size` 落地只剩判定）。（依赖：T9）**已执行（2026-10-29）**：`docs/architecture.md` 新增「阅读器两阶段异步渲染（P2-B，2026-10-29）」节（动机 / 拆分依据 / 代际作废 / D8 两出口 / 三层兜底 / 与 canvas 后端关系 / 与 `:scale 1` 修复的关系）；`docs/emacs-reader.md` §7 新增「两阶段异步渲染」小节（用户视角：过渡、降级条件、失败恢复）+ 修正多窗口与分隔区两条旧结论；`docs/configuration.md` 新增 4 变量节；`README.md` / `Readme.org` 说明默认行为变更与回滚口径；`emacs/seshat-reader/VENDORED.md` 的 `--page-size` 条目（入口数 14 → 15）**T1 已写**，本批复核无需改；`CHANGELOG.md` 新增 1 条（新增）+ 2 条（修复）；`openspec/decisions.md` 追加 5 条（2026-10-29）；`openspec/tech-debt.md` 勾销 P2-1、修正分隔区 ±1–2px 条目、新增「两阶段异步渲染（P2-B）遗留」6 条；`openspec/roadmap.md` 更新 P2 池状态；本计划移入 `openspec/completed/`；新建 follow-up 草案 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`。

## 文档清单

`docs/architecture.md`（两阶段渲染 + 代际作废 + 与 canvas 后端的关系）、`docs/emacs-reader.md`（异步行为、可能出现的「空白→清晰」过渡、降级条件）、`docs/configuration.md`（4 个新 defcustom）、`emacs/seshat-reader/VENDORED.md`（新增 `--page-size` 入口、入口数 14→15）、`CHANGELOG.md`、`openspec/decisions.md`（D1 两阶段 vs 线程池的取舍、D5 兜底策略）、`openspec/tech-debt.md`（勾销 P2-1；若 S3 未触发则新增「daemon idle 不可依赖」条目）、`openspec/roadmap.md`、`README.md`/`Readme.org`（**必改**：默认行为由「全同步渲染」变为「先空白后清晰」过渡，并新增 4 个 defcustom）。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` → EXIT 0；C **0 error 0 warning**；elisp 字节编译 warning **≤ 20**（当前基线 20，零新增）；checkdoc 0；`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → **0 unexpected 且 0 skipped**（判据走 `emacs/tests/ert-judge.sh`）；`make -C emacs/tests check-criteria` PASS。**基线口径**：文件数 **37**（`emacs/tests` 共 40 个文件，其中 `Makefile` / `README` / `ert-judge.sh` 3 个非测试文件）；**例数一律以批次 0 首次实跑输出的 TOTAL 为准**——仓库内两个同日记录互相矛盾（`CHANGELOG.md` 的矩形选区取文修复写「1328 → 1333」、`openspec/completed/2026-10-28-reader-canvas-backend-migration.md` 写「1328」），**不得按任一数字判「零新增」**；批次 0 实跑得到的文件数/例数写入「## 验证记录 · 批次 0」，此后以它为本轮基线。
- **L3（真机必须）**：见 T9 五项；凡涉及几何/滚动/坐标一律真机，batch 无真实 redisplay。
- **不变量（可机械检查）**：① 占位态与已渲染态页高一致；② 补位不改任何页 marker 位置；③ `render-async` = nil 时与基线逐页 spec 几何一致；④ 无模块/渲染失败时落占位态、不抛错、不死循环——**机械断言**：同页连续渲染失败 **3** 次后不再登记 pending（buffer-local alist `seshat-reader--multipage-render-failures`，**T5 修订**：键为页号 `(PAGE . COUNT)` 而非 `(PAGE SCALE ROTATE)`，因为 tick 每轮重新推导 scale，按完整请求计键会让计数在最需要它的场景被重置 —— 见「T5 执行记录 · 与计划/任务书的偏差」第 1 条）；清零时机有**两条且都必须实现**——① 代际变化时（`--page-spec-clear-cache`）整表清空；② **该页重新进入可见范围时**（每次 `--multipage-sync` 判定可见集后，按本次可见页调 `seshat-reader--multipage-reset-render-failure`）清零重试——否则用户滚走再滚回时，因「纯滚动不自增代际」会把**暂时性失败永久化**（该页本次会话内再也得不到 idle 补位）。ERT 用桩让渲染恒返回 nil 断言「第 4 次不再尝试」，再让桩恢复并模拟该页重新可见，断言「计数清零后重新登记」（T5 已实现前者与 `reset` 函数，后者由 T6 接入 sync）。
- **任务类型**：elisp 验证走 `verify` 隔离实例（`set_task verify` → 预拉起 → 轮询 `alive` → 验证 → `set_task auto` → `instance stop` → `instance_status` 确认）；**C 模块重编译后必须重启 Emacs**（动态模块不可卸载）。

## 风险与回滚

| 风险 | 级别 | 处置 |
|---|---|---|
| 占位页高与真实 image 差 1 px ⇒ 滚动微跳 | 中 | S2 先验；G2 走备选；L3 专验缩放与连续滚动 |
| idle 不触发 ⇒ 长期空白页 | 高 | D5 两条保险（视口内同步 + 超时兜底）；G3 追加 `run-at-time` |
| 快速滚动 pending 堆积 ⇒ 渲染过期页 | 中 | D4 代际作废 + pending 只保留最新可见范围 |
| 双窗口 pending 争用 | 中 | D8 buffer-local 并集 |
| 占位页与 `align-to` 居中交互异常 | 中 | T3 断言 + L3；异常则占位态不写 align-to（只占高） |
| 缓存被 pending 挤占 | 低 | D7 pending 不入缓存 |

**回滚**：每批开始前建 git 安全点（`git stash create` 或临时分支）；单批失败且修复循环（L1 ≤3 轮、L2/L3 ≤2 轮）耗尽 ⇒ 回滚该批并报告本 agent，不跨批回滚。`seshat-reader-render-async` = nil 是**运行时**回滚口（只覆盖 elisp 路径）。**C 侧回滚必须以源码 + 重编译 + 重启三步完成**：回滚 `render/*.c/.h` 后须 `make -C emacs/seshat-reader clean all` 重编 `.so` 并**重启 Emacs**（动态模块不可卸载，仅 git 回滚源码不生效、旧 `.so` 仍在运行）。

## 与已确认方案的偏差（请用户留意）

1. **新增 T0.5（范围外修复，已获用户确认）**：批次 0 的 S2 真机测量暴露 canvas 迁移的 `:scale` 回归（页高少算 20%、位图 1.2× 上采样），已在 `render/elisp-helpers.c` 加 `:scale 1` 修复并重建 `.so`；该改动不在原计划任务列表内，属「使本计划不变量①可成立」的前置修复。
2. **G3 新增第三态（原计划只预设「触发/未触发」）**：实测为「触发但只 fire 一次」，故 T5 的驱动机制由「idle 自续」改为「idle 首轮 + `run-at-time` 周期推进」。若用户不认可此方向，请在进入 T1 前叫停。

## 注意事项

1. **不得改 `:data-width`/`:data-height` 只写一次的语义**，也不得跨调用缓存 `canvas_data`。
2. **视口内必须同步**：任何情况下「point 所在页」不能是空白占位。
3. **pending 必须有上限**：只保留当前可见范围（± preload）的页，超出即丢弃。
4. **C 改动后重启 Emacs**；`make clean all` 后再跑 ERT（`.d` 依赖已接入，注意 `-MMD` 生效）。
5. **测试桩范式**：idle 行为在 batch 下靠「桩 `run-with-idle-timer` 捕获回调 → 手动 funcall」，仓库已有两处先例（`seshat-reader-fit-window-test.el:355-420`、`seshat-reader-select-flash-test.el:57-77`），不要真等 timer。
6. **不要与 P2-3（横向滚动）/ P2-7（渲染基准）并批**：本项只动「何时渲染」，不动「渲染多大」。
7. 工作区可能有并发会话：改文件前后 `md5sum` 取证（历史教训）。
8. **`(window-text-pixel-size)` 必须显式放开 X/Y 上限（如 `100000`）**，否则大地页返回 `(0 . 0)`，会被误判成「image 未渲染」。
9. **`-Q -l` 非交互上下文里 `window-lines-pixel-dimensions` 恒返回 nil**（glyph matrix 未 up-to-date），交叉验证须用第二口径（同一函数换参数）复算。

## 验证记录

（本节按批追加：批次 / 日期 / L1 数字 / L2 例数 / S1–S4 数值 / Gate 判定 / L3 结果 / 备注。）

### S1 耗时分布（2026-10-28）

**环境**：GNU Emacs 32.0.50（`emacs --version` 首行）；动态模块 `emacs/seshat-reader/seshat-render-core.so` 已构建（2026-10-27 02:44，本批**未**重编译、未跑 `make`）；测量全程走 `emacs -Q --batch`（不碰任何运行中的 Emacs 实例）。脚本在 `/tmp`（`s1-measure.el` / `s1-probe.el` / 生成样本用的 `s1-bigpage.ps`），仓库零改动。

**口径（逐条对应 spike 表要求）**：

- **测量点** = `seshat-reader--page-spec`（`scale=1.0`、`rotate=0`）单次调用耗时，即「现状同步渲染一页」的成本；用 `float-time` 差值，单位 ms，保留 2 位；未调 `gc-cons-threshold`（GC 成本计入，三份样本测量期间 GC 次数 5 / 1 / 3）。
- **warm-up**：每份样本的**第 1 次调用**（含模块首次渲染、字体/页资源首用等一次性开销）单独标记、**不计入分布**；分布从第 2 次调用起（= 各样本 p50/p95/max 的 n 比调用数少 1）。
- **避缓存**：按页序 1..N 顺序扫、每页只调 1 次 ⇒ 会话内缓存（实测上限 `min(8, 8, max(4, 2*2+2)) = 6`）不可能命中同一页；逐页记录调用前缓存状态，**`cache-hit` 实测 0 次**（150 次调用全 `cache-miss`），无「≈0 ms 被缓存命中」的条目需剔除。
- **分位口径**：升序排序后 **nearest-rank**，`p95 = 排序后第 ceil(0.95n) 个`（Elisp 写法 `(nth (min (1- n) (1- (ceiling (* 0.95 n)))) sorted)`）；`p50` 同法。附带核对 `(nth (floor (* 0.95 n)) sorted)` 口径：三份样本结果一致。
- **面积分桶口径（代理指标）**：`ratio = (:width × :height) ÷ (612 × 792)`，其中 `:width`/`:height` 是 scale 1.0 下 spec 的**逻辑像素**，分母是 letter @72 dpi（612×792 pt）。这是**面积量级代理**，不是真实 pt²（未乘页尺寸的物理 dpi，也未考虑裁剪框与内容密度）。桶：≤1.0× / 1.0–2.0× / >2.0×。

**样本与汇总**

| 样本 | 路径 | 页数（总 / 测） | 调用数 | warm-up (ms) | p50 (ms) | p95 (ms) | max (ms) |
|---|---|---|---|---|---|---|---|
| A 矢量手册 | `/usr/share/doc/ghostscript/Ghostscript.pdf` | 477 / 1–100 | 100 | 4.63 | 1.99 | 8.34 | 10.40 |
| B 大页（生成） | `/tmp/s1-bigpages.pdf`（由 `/tmp/s1-bigpage.ps` 经 ghostscript 生成，10 页：A1 ×4 / A3 ×3 / A4 ×3） | 10 / 1–10 | 10 | 18.23 | 1.34 | 18.19 | 18.19 |
| C 真实扫描书 | `/home/thomas/Workspace/seshat/《新赤脚医生手册》 .pdf` | 780 / 1–40 | 40 | 11.67 | 19.05 | 49.45 | 51.85 |
| **合计** | — | — | **150** | — | **2.34** | **29.87** | **51.85** |

分布统计 n = 147（150 次调用 − 3 条 warm-up）；合计的 mean = 8.17 ms，直方图：0–1 ms 10 条 / 1–2 ms 46 / 2–5 ms 44 / 5–10 ms 8 / 10–20 ms 21 / ≥20 ms 18。

**按面积分桶**（代理指标，口径见上）

| 桶 | n | p50 (ms) | max (ms) | 构成 |
|---|---|---|---|---|
| ≤1.0× | 99 | 1.99 | 10.40 | 全部 A（letter 612×792，ratio 1.000） |
| 1.0–2.0× | 42 | 18.63 | 51.85 | A4 595×842（1.034）×3 + 扫描书 737×1139（1.732）×39（另有 1 页 737×1103、1 页 737×1101，均 1.67×） |
| >2.0× | 6 | 1.43 | 18.19 | A3 842×1191（2.069）×3 + A1 1684×2384（8.283）×3 |

**G1 算术判定**（条件：`p95 < 5 ms` **且** `max < 20 ms`）

| 数据集 | p95 (ms) | p95 < 5 | max (ms) | max < 20 | 判定 |
|---|---|---|---|---|---|
| A 矢量 letter | 8.34 | ✗ | 10.40 | ✓ | 未触发 |
| B 大页 | 18.19 | ✗ | 18.19 | ✓ | 未触发 |
| C 扫描书 | 49.45 | ✗ | 51.85 | ✗ | 未触发 |
| 合计 | 29.87 | ✗ | 51.85 | ✗ | 未触发 |

**结论：G1 未触发**——没有任何数据子集同时满足两条条件。差距量级：最快的 A 也差 67%（p95 8.34 vs 5）；真实扫描书 p95 高 9.9×、max 高 2.6×。⇒ 两阶段渲染（目标 1）的收益成立，**不启用降级方案 B**；本批不做任何任务裁剪（S2/S3 未完成，裁剪由主 agent 统一处理）。

**加载方式与偏差（诚实记录）**

- 加载方式：`emacs -Q --batch -l /tmp/s1-measure.el`，`load-path` 加 `emacs/seshat-reader` → `(require 'seshat-reader)` → 该文件自身的 `(with-demoted-errors (require 'seshat-render-core))` 经 load-path 命中已构建的 `.so`（实测 `featurep` = t、`seshat-reader-dyn--page-image-spec` = t、日志有「dynamic module has been loaded successfully」）。**未**加载 evil / etaf / posframe 等：`seshat-reader.el` 本身只 `(require 'image)`，其余包用 `declare-function` + autoload，因此没有「为了跑通而绕开依赖」的额外偏差。文档打开走 `seshat-reader-dyn--load-doc`（不经 `seshat-reader-mode` / 多页布局），这样测的就是纯渲染，不含布局开销。
- 偏差 1（测量是**乐观下界**）：`scale` 固定 1.0；真机 `--multipage-target-scale` 常 >1.0（视口缩放），设备像素随 scale² 增长，成本更高。
- 偏差 2（同样是下界）：未计入 `seshat-reader--multipage-render-page` 的行构建 / `--multipage-resize-spec` / 居中判定开销，也未计入 redisplay（batch 无真实 redisplay）。
- 偏差 3（可能双向）：缓存上限 6 而非 8（resident range 为空时取 `max(4, 2*2+2)`），淘汰更频繁 —— 会让尖峰更明显；真机有视口驻留时淘汰策略不同。
- 偏差 4：样本 B 是**生成样本**（`/usr/share/doc` 下唯一 >1 MB 的 PDF 都是 ghostscript 自己的手册，无真实图纸 PDF，未遍历整个文件系统；为避免造假未把 GS9 手册当「大页样本」）；样本 C 借用了仓库目录内既有的真实扫描书，取前 40 页。
- 观察（未单独验证，供 T5/T6 参考）：A 的 5 条尖峰（8.34–10.40 ms，页号 5/20/41/62/83）大致每 ~20 页出现一次，与缓存淘汰 + canvas image 释放 + GC 的节奏吻合（假设?）；B 中同为 A1 的第 2/3/4 页 12.46/18.19/10.51 ms 而 A3/A4 各页仅 0.68–1.43 ms，提示「某尺寸首用」成本远高于同尺寸后续页（假设?）；C 每页 9.58–51.85 ms 的量级更像位图解码 + 缩放主导（假设?）。

### S3 daemon idle（2026-10-28）

**环境**：目标实例 `elisp-test`（verify）**本次启动失败**（2 次尝试均判「启动卡死」，socket 从未出现；偏差详见本节末「实例不可用的偏差」）。实测改用**临时隔离 daemon**（`ALTERNATE_EDITOR=/bin/false emacs --init-directory=/tmp/probe-* --daemon=<临时名>`，最小 init、不加载任何用户配置、不碰主实例 `thomas`）。`emacs --version` 首行 = `GNU Emacs 32.0.50`；无 frame 时 `(display-graphic-p)` = nil、`(frame-list)` 长度 1 且 `(framep (selected-frame))` = `t`（终端 frame）。等待期间**零 elisp 调用**：登记在 daemon 启动的 `init.el` 里完成，命中结果由 daemon 自身 `append-to-file` 写入 `/tmp/s3-*.log`，等待只用 shell `sleep`，**不连任何 emacsclient**（比「登记后 sleep 再求值」更严格，连读回都不打扰事件循环）。

| 探针 | 登记方式 | 等待时长 | 结果 | 结论 |
|---|---|---|---|---|
| A idle timer（无 frame、无客户端） | `(run-with-idle-timer 1 t <每次落盘>)` | 32 s（首 10 s 内已记 1 次） | `ticks = 1`，触发时 `current-idle-time` = `(1000575873 . 1000000000)` ≈ **1.0006 s** | 确实 fire；此后 32 s 内**不再重复** |
| B 对照组（普通 timer） | `(run-with-timer 1 nil <置 flag>)` | 8 s | `my-timer-fired = t` | timer 机制与事件循环**正常**，排除「整个 timer 子系统不跑」 |
| C 双 idle（安静回调 + 落盘回调） | `(run-with-idle-timer 1 t <仅自增>)` + `(run-with-idle-timer 2 t <自增并落盘>)` | 14 s | `quiet = 1`、`loud = 1`（loud 触发时 `current-idle-time` ≈ 2.0015 s） | 与「回调是否做事（IO）」无关，重复登记也只各 fire 一次 |
| D 同 C + 1 个 GUI frame | 同上，另用 `emacsclient -c` 附加图形 frame | ~18 s | `loud = 2`、`quiet = 3` 后**停住**（后 8 s 无新增） | 有 frame 时可多 fire 几次，但仍会停 |
| E 无 frame + 普通重复 timer(1 s) | C + `(run-with-timer 1 1 <自增>)` | 12 s | `loud = 1`、`quiet = 1` | 仅靠周期性普通 timer 也**带不动** idle timer 重发 |
| F 定量对照（决定性） | `(run-with-idle-timer 1 t <仅自增>)` + `(run-with-timer 1 1 <自增>)` + 每 3 s 落盘两计数 | 15 s | `wake = 3 / 6 / 9 / 12 / 15`，`quiet = 1` 恒定，`current-idle-time` = 3 s → 15 s **单调增长** | 普通 timer 每秒照跑、idle 时钟持续累积，idle timer 仍不重发 ⇒ **不是 idle 判定坏，是「无新输入不 re-arm」** |

**S3 判定**：**触发**（三选一中的第一种）——daemon 在无 frame、无客户端请求时 `run-with-idle-timer` **确实 fire**（实测 ticks = 1，触发点 idle ≈ 1.0006 s ≥ 登记的 1 s），且对照组普通 timer 正常触发（B）、idle 时钟本身正常累积到 15 s（F）⇒ 既非「idle 判定特有失效」也非「daemon 事件循环不跑」。**但附带一条硬限定**：**一个 idle 窗口只 fire 一次，没有新输入就不会再触发**（A/C/E/F 一致：重复登记的 idle timer 只有首次触发；D 显示有 frame 时也只多几次，输入事件耗尽后同样停止）。

**对 G3 的含义**：D5 的「idle 兜底」**方向可用，但不能按「idle 回调会被反复调用直到 pending 队列清空」来设计**——队列推进速度受「输入事件数」限，而非「idle 时长」限。处置要求（供主 agent 判定，本批不裁剪任务）：① idle 回调必须是**单轮有界的一批**（一次脉冲只做 1 页的量级），不能写成 while 循环排空队列；② 队列推进的持续性**只能靠 pending 超时强制同步**兜底，不能靠 idle 重入；③ 若确实需要「连续脉冲」，唯一的驱动源是输入事件（滚动/按键）或另设一个**周期性普通 timer**（但 F 证明普通 timer 本身并不能让 idle timer 重发，故「周期 timer」只能作为「直接检查并推进队列」的驱动，不能作为 idle timer 的唤醒源）。

**实例不可用的偏差（诚实记录）**

- `elisp_mcp_instance(start, verify)` 失败 1 次（`.elisp-test-start-failures` 计 1），显式 `bin/emacs-mcp-stdio-iso.sh start` 再失败 1 次（脚本内部重试，日志：`daemon 启动卡死（socket /run/user/1000/emacs/elisp-test 未出现）`）。`journalctl --user -u thomas-emacs-elisp-test.service` 显示该 unit 历史上**多次同形态失败**（Started → 20 s–3 min 后被 SIGTERM，CPU 累计 3–9 s、Mem peak 300–630 MB）。失败前 init 已推进到尾部（`seshat-reader: dynamic module has been loaded successfully.`、kill-ring 载入完成、`Starting Emacs daemon.`），socket 始终未创建；CPU time 零增长 ⇒ 卡在**等待**而非加载。
- 曾假设「`early-init.el:92` 的 `(setq server-name "thomas")` 与主实例 socket 冲突、`server-start` 交互式提示卡死」——**该假设已推翻**：`startup.el:1788-1792` 在 init 之后按命令行参数覆盖 `server-name`（early-init 注释亦已说明），`--daemon=elisp-test` 不受影响。根因**未定位**（`假设?`：init 尾部存在阻塞型等待，如网络/交互提示），留给主 agent 处置。
- 偏差：临时 daemon 用最小 init（**无用户配置**），故 S3 结论只对「Emacs 内核 daemon 语义」负责，不含用户配置的干扰（如常驻 timer / 输入源差异）；D 的 GUI frame 由 `emacsclient -c` 附加，非用户真实会话。

### S2 可行性（2026-10-28）

探测均在上述临时隔离 daemon（无客户端、无 frame）内求值，**未插入占位行、未渲染 canvas image**（按任务要求只探条件）：

| 探测式 | 返回值 |
|---|---|
| `(list (display-graphic-p) (framep (selected-frame)) (mapcar #'framep (frame-list)) (length (frame-list)))` | `(nil t (t) 1)` |
| `(list (image-type-available-p 'canvas) (fboundp 'window-lines-pixel-dimensions))` | `(t t)` |
| `(x-display-list)` / `(getenv "DISPLAY")` | `nil` / 已设置（set） |

**结论：S2 不能在 daemon 型实例做，必须回到用户的图形 Emacs。** 依据：`(display-graphic-p)` = nil 且唯一 frame 的 `framep` = `t`（终端 frame）——`window-lines-pixel-dimensions` / canvas image 的实际行像素高在 tty frame 下以字符格计量，测出的「px 差值」无意义，会污染 G2。`(image-type-available-p 'canvas)` = t 只说明**构建支持** canvas（PGTK/cairo），不代表当前 frame 能按像素排版。因此 `elisp-test`（即使能启动）与任何 daemon 后端的 MCP 实例都**不满足** S2 的前置条件；S2 只能在**图形 frame**上做（用户主实例的 GUI frame，或另起一个带图形 frame 的独立 `emacs -Q` 进程，后者需用户同意——弹窗打扰）。

### S2 占位高度等价（2026-10-28）

**环境**：Emacs **32.0.50**（pgtk 构建）、`(framep (selected-frame))` = `pgtk`、`(display-graphic-p)` = `t`；临时**可见** frame（`*seshat-s2-probe*`，130×60 字符，`(frame-char-width/height)` = 12/24 px，`(frame-scale-factor)` = **1.0**，字体 `Saja CaskaydiaCove Nerd Font 20`）；`(image-type-available-p 'canvas)` = `t`。

**测量方法（一句）**：在临时 frame 的窗口内单行显示 A = `(space :width (W) :height (H))`（W/H 取 `(image-size SPEC t)`，即该页在屏幕上的**实际像素**）与 B = 同尺寸已渲染 image spec，`(redisplay t)` 后取 `(window-text-pixel-size WIN FROM TO)` 的行高，并用 `(window-lines-pixel-dimensions WIN)` 首行高交叉验证；宽度自检 = B 行实测像素宽必须等于 image 的实际像素宽，不等即判「image 未渲染」并剔除该组。

| 组 | 样本页 | W | H | A 行高（space） | B 行高（image） | 差值 | 宽度自检 |
|---|---|---|---|---|---|---|---|
| 1 | `Ghostscript.pdf` p1 @1.0 | 612 | 792 | 792 | 792 | **0** | 612 = 612 ✓ |
| 2 | `《新赤脚医生手册》 .pdf` p1 @1.0 | 737 | 1139 | 1139 | 1139 | **0** | 737 = 737 ✓ |
| 3 | `d2l-zh-pytorch.pdf` p100 @1.0 | 612 | 792 | 792 | 792 | **0** | 612 = 612 ✓ |
| 4 | `《新赤脚医生手册》 .pdf` p1 @1.6 | 1178 | 1822 | 1822 | 1822 | **0** | 1178 = 1178 ✓ |

交叉验证：四组 `window-lines-pixel-dimensions` 的首行高（792 / 1139 / 792 / 1822）与主口径逐组一致。**剔除 0 组**（四组宽度自检全部通过，无「image 未渲染」）。

**两条硬约束（实测得到，直接影响 T3 写法）**

1. **像素必须写成 `(NUM)`**：`(space :width 612 :height 792)`（NUML）是「默认字体尺寸的**倍数**」，实测行高 **19008** px（= 792 × 24），组 2 为 27336、组 4 为 43728——比预期大一个数量级。T3 必须写 `(space :width (W) :height (H))`（`(elisp)Pixel Specification`：`(NUM)` = 绝对像素）。
2. **W/H 必须取「实际显示像素」，不能取 bounds 原始像素**：见下面的 canvas 偏差。

**G2 判定（分后端，结论不同）**

- **当前生产后端 = pbm**（主实例实载 `.so` 为 **2026-10-27** 构建，spec 的 `:type` = `pbm`、`:scale` = 1；canvas 源码尚未重建 `.so`）⇒ **G2 未触发**：4/4 组差值 **0 px**，`space` 方案在该后端的行高上**精确等价**。
- **canvas 后端（源码已切 canvas，`3265652`）⇒ G2 触发**。补测（Emacs 自建 canvas image，不依赖 seshat 后端，参数与 `data2elisp_canvas` 一致：`:data-width 612` / `:data-height 792` / `:width 612` / `:height 792`）：实际显示尺寸为 **735×951**（`(image-size SPEC t)` 亦报 735×951），而 `(space :width (612) :height (792))` 行高 792 ⇒ **差 +159 px**（宽差 +123 px）；把 `:width` 改为 510/660 后显示 613×793，差 +1 px。原因：canvas image 的 `:width`/`:height` 走 **CSS 像素**语义，本机按 **≈1.2009** 倍放大到设备像素，而 `(space … (NUM))` 是设备像素——两者只有在 W/H 取 `(image-size SPEC t)` 时才对齐。
- **采纳动作**：T3 **保留 `space` 方案**（当前后端差 0），但把上面两条硬约束写进实现（`(W)` 形式 + W/H 取 `(image-size SPEC t)`）；**并在 canvas 后端 `.so` 重建后复测本小节**——缺第 2 条约束时 canvas 后端会每页差 +159 px，G2 将转为触发、需退备选。

**测量缺口（诚实记录）**：① 未实测「`(space :width (735) :height (951))` vs canvas 行 735×951」这一对照（主实例门禁在补测阶段锁定，`M-x +thomas/elisp-mcp-unlock` 到期）；按 pbm 四组已证明 pixel-spec 行高精确等于其像素值，故推定为相等，标 `假设?`。② 主实例没有 canvas 后端（`.so` 未重建），canvas 口径结论来自「与 C 侧参数一致的自建 canvas spec」，不是 seshat 生产路径。

#### canvas 后端复测（2026-10-29，`.so` 重建后）

**环境**：GNU Emacs 32.0.50（pgtk）；`.so` = `emacs/seshat-reader/seshat-render-core.so`（2026-10-29 00:05 构建，spec 的 `:type` = `canvas`）；测量在用户图形 Emacs（主实例）内、临时可见 frame `*seshat-s2-probe*`（130×60 字符，body 1390 px）中进行：`(frame-scale-factor)` = **1.0**、`(frame-parameter nil 'scale-factor)` = nil、`(frame-char-width)`/`(frame-char-height)` = **12/24**、字体 `Saja CaskaydiaCove Nerd Font 20`、`(display-pixel-height)` = 1440、`image-scaling-factor` = `auto`；基线（开工前）= frame 3 / buffer 42 / timer 20 / idle-timer 14，收工复核同值。
**测量口径**：单行 buffer（`"  \n"`）+ `display` 文本属性，`(redisplay t)` 后取 `(window-text-pixel-size WIN 1 4 100000 100000)`——**必须显式放开 X/Y 上限**，否则高于窗口的行会被截断（实测 1178×1822 的 space 行不放开上限时返回 `(0 . 0)`/被裁），标定式 `(space :width (100) :height (100))` → 100×100 精确通过。`(window-lines-pixel-dimensions)` 首行底边作交叉验证（行高 > 窗口时返回 nil，组 4 因此无此交叉值）。

| 组 | 样本页 | ①声明 `:width`/`:height` | ②`image-size` t | ②`image-size` nil | ③真实行高（image 行） | ④space(① 声明) 行高 | ⑤space(② 实际) 行高 | 宽度自检 |
|---|---|---|---|---|---|---|---|---|
| 1 | `Ghostscript.pdf` p1 @1.0 | 612×792 | 735×951 | 61.25×39.625 | **735×951** | 612×792（差 **+159 px**） | 735×951（差 **0**） | 735 = 735 ✓ |
| 2 | `《新赤脚医生手册》 .pdf` p1 @1.0 | 737×1139 | 885×1367 | 73.75×56.958 | **885×1367** | 737×1139（差 **+228 px**） | 885×1367（差 **0**） | 885 = 885 ✓ |
| 3 | `d2l-zh-pytorch.pdf` p1 @1.0 | 612×792 | 735×951 | 61.25×39.625 | **735×951** | 612×792（差 **+159 px**） | 735×951（差 **0**） | 735 = 735 ✓ |
| 4 | `《新赤脚医生手册》 .pdf` p1 @1.6 | 1178×1822 | 1414×2187 | 117.833×91.125 | **1414×2187** | 1178×1822（差 **+365 px**） | 1414×2187（差 **0**） | 1414 = 1414 ✓ |

- 有效 **4/4** 组，剔除 **0** 组（四组宽度自检全部通过，无「未渲染」）；`window-lines-pixel-dimensions` 首行底边在组 1/2/3 与主口径一致（951 / 1367 / 951）。
- 4 组 spec 的 `:data-width`/`:data-height` 与 ① **完全一致**（组 1 实测 612×792），`:scale` = **`default`**。
- `(image-size SPEC nil)` 实测语义 = 「② 的像素值 ÷ `(frame-char-width)`/`(frame-char-height)`」的**字符单位**（735/12 = 61.25、951/24 = 39.625），与布局像素无关。

**放大因子的来源（补充测量；`:scale` 是根因，与 canvas 后端无关）**

| 测量 | 结果 |
|---|---|
| 生产 spec（`:scale default`）行高 | 735×951 |
| 同一 spec `(setf (image-property spec :scale) 1)` 后行高 | **612×792**，与 `(space :width (612) :height (792))` 行高 **差 0** |
| `splash.png`（文件真实 333×233）裸 `create-image` | 400×280（×**1.2012**） |
| 同上 `:scale 1` / `:width 100 :scale 1` | 333×233 / 100×70（**精确等于声明**） |
| 同一 PNG 在 40pt 字体 frame（char 23×48） | 766×536（×**2.3004** ≈ 23/10） |

⇒ 放大因子 = **`frame-char-width ÷ 10`**（本机 12/10 = 1.2；换 font 后随之变成 2.3），由 `image-scaling-factor` = `auto` 且 spec 未显式给 `:scale` 触发；**与 canvas 后端、与 `:data-width` 无关**（普通 PNG 同样复现）。`(frame-scale-factor)` 恒为 **1.0**，**不可**用作补偿口径。C 侧 `create-image` 调用（`render/elisp-helpers.c:201-215`，11 个参数：`:data-width`/`:data-height`/`:width`/`:height`）**未传 `:scale`**。

**布局层取值事实（源码，只记事实）**

| 位置 | 源码行 | 取值字段 |
|---|---|---|
| `seshat-reader--multipage-page-pixel-height` | `seshat-reader.el:2010`（defun），**`2017`**：`(or (and spec (image-property spec :height)) 0)` | **`:height` 声明值**，不调 `image-size` |
| `seshat-reader--multipage-max-page-width` | `seshat-reader.el:1384`（defun），**`1391`**：`(image-property (cddr entry) :width)` | **`:width` 声明值** |
| `seshat-reader--multipage-resize-spec` | `seshat-reader.el:1444`（defun），**`1457`/`1466`** 读/写 `:height`（`:width` 同理） | 声明值（native × target） |
| 消费方 | `2099`（页 span）、`2140`（页内 vscroll）、`2519`（`image-width`）、`3074`/`3085`/`3095`/`3103`（横向滚动界） | 均由上表两个函数派生 |

**判定：P2（真实显示放大成立）——放大是真的，且补偿方式已定位**

- 数值依据：4/4 组 ③ **等于** ②（735×951 / 885×1367 / 735×951 / 1414×2187，逐组差 0），③ **不等于** ①（宽差 +123/+148/+123/+236 px、高差 **+159/+228/+159/+365 px**）；⑤（space 取 ② 口径）与 ③ **逐组差 0**。
- ⇒ 上一轮「自建 canvas spec 显示 735×951」**不是假警报**：真实 seshat 渲染路径上每页确实放大约 20%（737×1139 → 885×1367）。
- ⇒ 现状下 `--multipage-page-pixel-height` 返回 792 而屏幕实际 951 ⇒ 页高少 **20.1%**；`--multipage-max-page-width` 返回 612 而实际 735 ⇒ 横向滚动界少 **20%**。滚动范围系统性偏小，可解释末页假页 / 跨页偏移。

**处置建议（供主 agent 统一裁定；本节不改 T2/T3/D2 的任务正文）**

1. **首选（治本，一行 C）**：`data2elisp_canvas` 的 `create-image` 调用（`render/elisp-helpers.c:201-215`）追加 `:scale 1`（`create_args` 11 → 13，第 11 个实参改为 12，`funcall` 的 nargs 同步）。实测该 spec 显示尺寸立刻回到 612×792、与 `space` 的声明口径**差 0**，同时消掉 1.2× 上采样（612 px 位图不再被拉到 735 px 显示）。须与 T1 一并 `make all` + **重启 Emacs** 复测。
2. **次选（治标，纯 elisp）**：布局层改用显示口径——`2017` 的 `(image-property spec :height)` 换成 `(cdr (image-size spec t))`、`1391` 的 `(image-property (cddr entry) :width)` 换成 `(car (image-size … t))`。若采此方案，T1 的 `--page-size` 返回口径、T2 `--multipage-page-sizes`、T3 的 space 必须**同步**改为显示口径，否则「占位 == 已渲染」的验收在真机上必然失败。
3. **G2 口径**：按 ① 声明口径判，canvas 后端 **G2 触发**（差 ≥1 px）；按 ② 显示口径判且采纳建议 1，则「占位 == 已渲染」**差 0**、G2 **未触发**，T3 可保留 `space` + `(NUM)` 形式。两种情形都要求口径唯一，**不得混合口径**继续 T3。
4. **附带风险（未验证，建议另案）**：`:data-width` 与声明相等（612 px 位图）却被显示在 735 px 上 ⇒ 当前 canvas 页在屏幕上是 1.2× 放大显示，栅格分辨率相对屏幕偏低 20%（观感/清晰度）；采纳建议 1 后此问题同时消失。

#### T0.5 `:scale` 回归修复（2026-10-29）

**根因**：`render/elisp-helpers.c` 的 canvas spec `create-image` 调用未传 `:scale`，spec 因此是 `default`，Emacs 按 `image-scaling-factor`（`auto` = `frame-char-width/10`，本机 1.2）放大显示；而布局层 `seshat-reader--multipage-page-pixel-height`（`seshat-reader.el:2010`，取值 `2017`）读的是声明 `:height`，页高系统性少算约 20%。

**改动**（`render/elisp-helpers.c`，本轮唯一改动的源码文件）：`create_args[11]` → `create_args[13]`，追加 `:scale` + 整数 `1`；`funcall(create-image)` 的 nargs `11` → `13`。其余代码零改动。

**batch 验证**（`emacs -Q --batch`，脚本 `/tmp/scale-verify.el`，`d2l-zh-pytorch.pdf` p1，scale 1.0 / rotate 0）：

| 断言 | 结果 |
|---|---|
| `(image-property spec :scale)` | **1**（修复前为 `default`） |
| `(image-property spec :width)` / `:height` | **612 / 792**（`:data-width` / `:data-height` 同为 612 / 792，`:type` = `canvas`） |
| `fboundp` 逐个检查 14 个 `seshat-reader-dyn--*` 入口 | **14 / 14 bound**，missing `nil` |
| `emacs -Q --batch -l /tmp/scale-verify.el` 退出码 | **0** |
| `make -C emacs/seshat-reader clean all` | **EXIT 0**，C `error:` **0** / C `warning:` **0** |
| elisp `Warning:` | 全部为既有基线（docstring 宽度 / 未定义函数引用等），本轮零新增 |
| `make -C emacs/tests ert`（回归） | **EXIT 0**，37 文件 **1333** 例、**0 unexpected / 0 skipped**（= 基线，零回归） |

`(image-size spec t)` 在 batch 下返回 **nil**（无真实 frame、无 redisplay），如实记录、不作判据。

**待办**：~~真机行高复测待用户重启后执行~~ **已完成（2026-10-29，独立 GUI 实例，见下一节）**——原预期：4/4 组 `image` 行高等于声明尺寸（612×792 / 737×1139 / 612×792 / 1178×1822 @1.6），与 `(space :width (W) :height (H))` 取声明值时差 0，即 S2 回到「差 0」、G2 未触发、T3 保留 `space` 方案。**实测与预期一致（4/4 差 0）**。

#### T0.5 真机复测（2026-10-29，独立 GUI 实例）

**实例方式（为何不是 daemon、不是 batch）**：用户主 daemon 仍加载旧 `.so`（未重启），`elisp-test` / `elisp-pure` 等 daemon 后端在 tty 或非图形上下文下 `window-lines-pixel-dimensions` / canvas 行像素高均无意义（见上文「S2 占位高度等价」的前置条件），故本轮起**独立非 daemon GUI 进程**：`timeout 90 emacs -Q -l /tmp/s2-gui.el`，脚本自取 spec、测量、写 `/tmp` 结果后自行 `(kill-emacs 0)`。**未触碰用户 daemon**：全程无 `emacsclient`、无 `elisp_mcp_set_task`、无 `elisp_mcp_instance(start/stop)`，未 kill 任何既有进程；收尾 `pgrep -af "emacs.*daemon"` 仍见 `emacs --init-directory=/home/thomas/thomas-emacs --daemon=thomas`（PID 65450）存活。**未进仓库**：脚本与输出仅 `/tmp/s2-gui.el` / `/tmp/s2-gui-out.txt`（`prin1` 可 parse 的 plist）/ `/tmp/s2-gui-readable.txt` / `/tmp/s2-gui.log`。

**环境**：GNU Emacs 32.0.50（pgtk，`(display-graphic-p)` = **t**）；`(frame-scale-factor)` = **1.0**、`(frame-parameter nil 'scale-factor)` = nil；`(frame-char-width)`/`(frame-char-height)` = **9/20**、字体 `Adwaita Mono 15`（`-Q` 默认，与用户 daemon 的 `Saja CaskaydiaCove Nerd Font 20` = 12/24 不同）；frame = 1932×1200 px；`(display-pixel-width)`/`(display-pixel-height)` = 4480/1440；`image-scaling-factor` = **auto** ⇒ 本实例 auto 因子 = 9/10 = **0.9**（用户 daemon 为 1.2）。加载的 `.so` = `emacs/seshat-reader/seshat-render-core.so`（2026-10-29 00:30 构建，含 `:scale 1`），spec 的 `:type` = **canvas**。

**测量口径**：单行 buffer（`"  "` + `display` 文本属性，行 A 用 `(space :width (W) :height (H))` 括号形式即绝对像素，行 B 用真实 canvas spec），每行独立 marker；`(set-window-buffer)` + `(set-window-start … t)` + `(set-window-hscroll 0)` + `(redisplay t)` 后取 `(window-text-pixel-size WIN FROM TO 100000 100000)`。**X-LIMIT/Y-LIMIT 必须显式放开**：docstring 明确 X-LIMIT 为 nil 时按 window body 宽度截断（上一轮「(0 . 0)」即此因）。交叉验证用备用口径 `(window-text-pixel-size WIN FROM TO t nil)` 逐组复算。

| 组 | 样本页 | ①声明 `:width`×`:height` | `(image-size SPEC t)` | `:scale` | 行 A（space 声明口径） | 行 B（真实 canvas image） | 差（B−A） | 宽度自检（B 宽 vs ①） |
|---|---|---|---|---|---|---|---|---|
| 1 | `Ghostscript.pdf` p1 @1.0 | 612×792 | 612×792 | **1** | 612×792 | **612×792** | **0** | 612 = 612 ✓ |
| 2 | `《新赤脚医生手册》 .pdf` p1 @1.0 | 737×1139 | 737×1139 | **1** | 737×1139 | **737×1139** | **0** | 737 = 737 ✓ |
| 3 | `d2l-zh-pytorch.pdf` p1 @1.0 | 612×792 | 612×792 | **1** | 612×792 | **612×792** | **0** | 612 = 612 ✓ |
| 4 | `《新赤脚医生手册》 .pdf` p1 @1.6 | 1178×1822 | 1178×1822 | **1** | 1178×1822 | **1178×1822** | **0** | 1178 = 1178 ✓ |

- 有效 **4/4** 组、剔除 **0** 组（四组宽度自检全部通过、无 `(0 . 0)`、无 `WIDTH-MISMATCH`）。
- 4 组 `:data-width`/`:data-height` 与①完全一致（612×792 / 737×1139 / 612×792 / 1178×1822）；`(image-size SPEC nil)` 为**字符单位**（68.0×39.6 / 81.89×56.95 / 68.0×39.6 / 130.89×91.1 = ① ÷ (9, 20)），与布局像素无关。

**三项判定（均有数值依据）**

1. **修复生效 ⇒ 是**。`(image-property SPEC :scale)` 4/4 组 = **1**（修复前为 `default`）；`(image-size SPEC t)` 4/4 组**等于**声明尺寸。反证（推断，依据上文两档实测 char 12→×1.2012、char 23→×2.3004；本轮未复测「缺省 `:scale`」情形，标 `假设?`）：本实例 `image-scaling-factor` = auto ⇒ 因子应为 0.9（char-width 9），若 `:scale` 仍缺省，组 1 应显示 **550.8×712.8**（612×0.9）；实测 **612×792** ⇒ 放大因子已完全不参与显示尺寸。
2. **G2 判定 ⇒ 未触发**。行 A（`(space :width (W) :height (H))`，W/H 取声明值）与行 B（真实 canvas image）行高**逐组差 0**（792 / 1139 / 792 / 1822），宽度亦逐组相等 ⇒ **T3 走 `space` 方案**，`W`/`H` 可继续取声明 `:width`/`:height`，**不需要**改用 `(image-size SPEC t)` 口径，`(NUM)` 括号形式（绝对像素）仍为硬约束。
3. **布局一致性 ⇒ 一致**。`(image-property SPEC :height)`（= 792 / 1139 / 792 / 1822，即 `seshat-reader--multipage-page-pixel-height` 在 `seshat-reader.el:2010`（取值 `2017`）读到的东西）**等于**实测行高 ⇒ 取到的页高与实际显示一致，**页高不再少算 20%**（对照修复前的 735×951：声明 792 vs 实际 951，少算 **159 px / 20.1%**）。同理 `--multipage-max-page-width`（`1391` 读 `:width`）也回到与实际一致（612/737/1178 逐组相等）。

**诚实记录（缺口与偏差）**

1. `window-lines-pixel-dimensions` 在本轮 `-Q` 脚本上下文**始终返回 nil**（docstring：glyph matrix 未 up-to-date），即使紧接 `(redisplay t)` 之后调用 —— 故本轮**无**该项交叉值（上一轮在主实例可见 frame 上能取到 951/1367/951）。交叉验证改由**备用口径** `(window-text-pixel-size WIN FROM TO t nil)` 承担：4/4 组与主口径**完全相同**（脚本对二者不等会写 mismatch note，实测零 note）。
2. 本实例字体/字符格（9×20）与用户 daemon（12×24）不同，差异只影响 `image-scaling-factor` 的 auto 因子（0.9 vs 1.2）；修复后该因子不参与显示尺寸，故结论方向可外推到主实例 —— 但**仍未在主实例实测**（`.so` 未重启），重启后建议补一次同口径复测（预期同值）。
3. 与本批指令的唯一偏差：straight 目录按 `(format "build-%s.%s" emacs-major-version emacs-minor-version)` 推导得 `build-32.0`，**该目录不存在**；脚本按候选列表回退 `(format "build-%s" emacs-version)` = `/home/thomas/thomas-emacs/.local/straight/build-32.0.50`（存在），并把 `:straight-derivation "emacs-version"` 与两个候选的存在性写进结果文件（非静默降级，已在报告标注）。
4. 脚本加载到的是 `seshat-reader.elc`（`load-prefer-newer` 下 `.elc` 更新）；本测量只用 C 入口 `--load-doc` / `--page-image-spec` / `--close-doc` 与 `image` API，不经过 `.el` 侧包装，故字节码新旧不影响结论。

#### 批次 0 Gate 汇总（2026-10-29）

| Gate | 实测 | 结论 |
|---|---|---|
| G1 | S1 合计 p95 **29.87 ms** / max **51.85 ms**（样本 A p95 8.34 / B 18.19 / C 49.45）；最快样本 p95 仍有 8.34 ms | **未触发** ⇒ 不启用降级方案 B，不裁剪任务 |
| G2 | `:scale 1` 修复后 4/4 组「`(space :width (W) :height (H))` 行高 == 真实 canvas image 行高」差 **0 px**（612×792 / 737×1139 / 612×792 / 1178×1822），布局层 `(image-property spec :height)` 与实测行高一致 | **未触发** ⇒ T3 采用 `space` 方案 |
| G3 | daemon 下 `run-with-idle-timer` **会触发但一个 idle 窗口只 fire 一次**（ticks=1，此后不重复；普通 `run-with-timer` 正常周期触发；周期 timer 带不动 idle 重发） | **G3b（新态）** ⇒ idle 只作首轮启动，队列推进改用 `run-at-time` 周期 timer |

结论：主线方案全部保留（G1 未触发不裁剪；G2 未触发用 space；G3b 改用周期 timer 推进），T0.5 范围外修复已获用户确认并落地。

### 待做

- ~~**S2 占位高度等价（真机）**：G2 输入；同页对比 `(space :width W :height H)` 占位与同尺寸 canvas image 的行像素高，记「相等 / 差 N px」。~~ **已完成**（结论见上「S2 占位高度等价（2026-10-28）」）
- ~~**S3 daemon idle（真机）**：G3 输入；`emacs --daemon=<临时名>` + `emacsclient -c`，`run-with-idle-timer 1` 打点，静置 ≥2 s 看 `*Messages*`（`sit-for` 不算 idle）。~~ **已完成（结论见 S3 小节：G3b）**
- **S4**：随 T1（`--page-size` 单次耗时，≥200 次中位）——**已完成，见下「T1 执行记录」**。

### T1 执行记录（2026-10-29）

**范围**：`emacs/seshat-reader/render/render-core.c`（+ 同目录 `render-core.h` 声明）、`emacs/seshat-reader/VENDORED.md`。验证全部在独立 `emacs -Q --batch` 进程内完成，**未调用任何 elisp-dev-mcp 工具、未触碰用户正在运行的 daemon**。

**实现要点**

- 新函数 `emacs_page_size`（`render/render-core.c:2915`，文档注释自 `2865` 起），注册名 `seshat-reader-dyn--page-size`、arity **2..3**（`register_module_func` 位置 `3177-3192`；`render-core.h:197` 补声明）。
- **轻量 bound 路径**：`fz_load_page → fz_bound_page → fz_drop_page`，**不复用** `load_page_dl`（该函数把 `fz_bound_page` 与 `fz_new_display_list_from_page` 耦合在同一 `fz_try`，会建 display list 并写 `DocPage` 缓存）。因此本入口**不建 display list、不分配 pixmap、不 snapshot 装饰、不写任何 `DocState` 字段**。
- **口径**：`ctm = fz_transform_page(page_bbox, resolution, rotate)` → `fz_round_rect(fz_transform_rect(page_bbox, ctm))` 取设备像素（= `fz_new_pixmap_from_display_list` 内部算 pixmap 尺寸的同一套两步；页面的 display list 以 `fz_bound_page` 结果为 mediabox 创建）→ `(int)(device / frame_scale)` 截断成逻辑像素。`resolution = fz_clamp(scale*72, MINRES, MAXRES)`、`frame_scale` 夹紧 `if (!(frame_scale > 0.01f)) frame_scale = 1.0f;` 均与 `render_page_to_buffer` 逐字一致。
- **ctx 选择 = `fz_clone_context`**（理由写进函数注释）：`fz_load_page` 会解析不可信页对象、可能 throw（损坏/加密文档），在克隆 ctx 上 throw 不会给文档自有 ctx 留下 pending error 或半成品对象；克隆共享文档锁集，可与同文档的其他读者并存；`fz_drop_context` 在所有退出路径释放。
- 返回值用 `(list W H)`（`env->funcall` 调 `list`）构造**两元素真列表**，非 dotted pair。
- 修正一处编译器告警：`bbox` 跨 `setjmp/longjmp` 边界被 `-Wclobbered` 报出，改为 `volatile fz_rect` + 成功路径上拷进普通局部（`if (!ok) return EMACS_NIL;` 短路所有读取）。

**L1 编译**：`make -C emacs/seshat-reader clean all` → **EXIT 0**、C **0 error / 0 warning**、elisp `Warning:` **20**（= 基线 20，零新增）；`checkdoc` 0。

**入口数 14 → 15**：`emacs -Q --batch` 加载模块后逐个 `fboundp`，**total=15 / present=15 / missing=nil**；`(help-function-arglist 'seshat-reader-dyn--page-size t)` = `(arg1 arg2 &optional arg3)`。新增名 `seshat-reader-dyn--page-size`。

**口径一致性（本项最重要）：36 组全部逐值相等，0 差异**

| 样本 | 页 | scale × rotate | `--page-size` | spec `:width`/`:height` | 结果 |
|---|---|---|---|---|---|
| `Ghostscript.pdf`（477 页） | 1 / 239 / 477 | 1.0×0 / 1.0×90 / 1.6×0 / 1.6×90 | 612×792 / 792×612 / 979×1267 / 1267×980 | 逐组相同 | 12/12 MATCH |
| `《新赤脚医生手册》 .pdf`（780 页） | 1 / 391 / 780 | 同上 | 737×1139 / 1140×737 / 1178×1822 / **1821×1179** | 逐组相同 | 12/12 MATCH |
| `d2l-zh-pytorch.pdf`（797 页） | 1 / 399 / 797 | 同上 | 612×792 / 792×612 / 979×1267 / 1267×980 | 逐组相同 | 12/12 MATCH |

合计 **n=36 / match=36 / diff=0**。⇒ `fz_bound_page` 与 `fz_bound_display_list` 在本批样本上**无 off-by-one**（扫描书的 rotate=90 组为 `1821×1179`，两入口同为奇数宽，说明这不是靠取整巧合对齐的）。

**A1 判定（S4）：单页入口成立**

| 样本（页） | n | 中位 | p95 | max |
|---|---|---|---|---|
| `Ghostscript.pdf` p30 | 220 | **0.0103 ms** | 0.0186 ms | 0.1817 ms |
| `《新赤脚医生手册》 .pdf` p30 | 220 | **0.0045 ms** | 0.0048 ms | 0.0508 ms |
| `d2l-zh-pytorch.pdf` p100 | 220 | **0.0079 ms** | 0.0107 ms | 0.0346 ms |

中位 4.5–10.3 **µs**，比 1 ms 门槛低两个数量级 ⇒ **保持单页入口，无需改批量入口**（S4 结论）。对照 S1：同一批样本上 `--page-image-spec` 单页 1.3–52 ms，即本入口把「取尺寸」的成本降到渲染的 **0.02%–0.8%**。

**边界**

| 探针 | 结果 |
|---|---|
| page `0` / `9999` / `-1` / `1.5` | `nil`，不崩（三份文档各测一遍） |
| `rotate` = 45 | `nil` |
| `scale` = NaN / +inf | `nil` |
| arity 1（缺 scale） | `ERROR:(wrong-number-of-arguments #<module function emacs_page_size …> 1)` —— Elisp 层报错，**无段错误** |
| 文档已 close（无 DocState） | `nil`（`--page-image-spec` 同） |
| `scale` = 0 / -1 | **非 nil**，返回 `(153 198)`（d2l / Ghostscript）、`(184 285)`（扫描书）—— 与渲染路径一样被 `MINRES`（18 dpi）夹紧，且 `--page-image-spec` 在同参数下产出**同值** spec（`(153 198)` 逐值相等）。**与任务书「scale 为 0/负 ⇒ 返回 nil」的表述不一致**，取口径一致性优先（任务书第 3 条要求两入口可互换），此处如实登记 |

**零副作用自检**

- **RSS**：每份样本连续 100 次 `--page-size` 后 `gc` 再读 `/proc/self/statm` resident，三份文档都是 `before 243652 kB → after 243652 kB`、`217208 → 217208`、`217208 → 217208`，增量 **0 kB**。
- **A/B 对照（更直接）**：全新进程渲染 `Ghostscript.pdf` p1 三次 —— 「不预热」14.84 / 17.33 / 13.68 ms（均值 15.28），「先 100 次 `--page-size` 再渲染」18.13 / 13.27 / 14.01 ms（均值 15.14）。若本入口建了 display list，预热组应显著变快；实测无差异 ⇒ **未写入任何渲染缓存**。
- 代码层证据：新函数体内**没有** `acquire_doc_page` / `load_page_dl` / `render_page_to_buffer` / `fz_new_display_list*` / `fz_new_pixmap*` 调用（`grep` 可机械复核）。

**L2 回归**：`make -C emacs/tests ert` → **FILES=37 / TOTAL=1333 / UNEXPECTED=0**，EXIT 0（与 L2 基线逐项一致：37 文件 1333 例、0 unexpected / 0 skipped）。

**副作用范围**：仅新增入口，**未改任何既有函数的行为/arity**（`--page-image-spec` 的渲染路径与返回口径逐字未动）。

### T2 执行记录（2026-10-29）

**范围**：`emacs/seshat-reader/seshat-reader.el`（主）、新增 `emacs/tests/seshat-reader-multipage-page-size-test.el`、`emacs/tests/README.md`（基线表）。**未调用任何 elisp-dev-mcp 工具、未 set_task / 未启停实例 / 未 eval 主实例、未重启用户 Emacs**；L1/L2 全部在独立 `emacs -Q --batch` 进程内完成。C 代码**未动**（`render/*.c` / `*.h` 本批零改动）。

**函数**：`seshat-reader--page-size (page scale &optional rotate)`（`seshat-reader.el:1183`）——`(fboundp 'seshat-reader-dyn--page-size)` 为 nil 直接返回 nil（批处理/未构建 `.so` 是常态）；否则按缓存键查 `seshat-reader--multipage-page-sizes`，**未命中才** `(ignore-errors (seshat-reader-dyn--page-size page scale rotate))`；返回两元素**真列表** `(W H)`。C 的返回值既是 `(W H)` 也容忍 dotted `(W . H)`（`car-safe` / `car-safe` of `cdr-safe` 取 W/H），非正整数一律按失败处理。

**缓存**：`seshat-reader--multipage-page-sizes`（`996`，buffer-local alist，(KEY . (W . H))，最新在前）。容量与排废**完全复用**既有实现——上限 `seshat-reader--multipage-cache-limit`（未自创），淘汰规则抽出 `seshat-reader--cache-eviction-victim (entries)`（`1079`，先丢离开驻留集的页、再 FIFO），`--page-spec-eviction-victim`（`1103`）退化为它的零参包装；写入函数 `--multipage-page-size-remember`（`1131`）与 `--page-spec-remember` 同形。**一套策略，两个缓存。**

**键复用**：直接用既有 `seshat-reader--page-spec-key (page &optional scale rotate)`——它本来就接受 scale/rotate 并在内部归一化（nil/1/1.0 → 1.0，rotate → 整数），**没有签名变更，也没有第二个键构造点**；`--page-spec` 与 `--page-size` 共用同一次归一化（`(nth 1 key)` / `(nth 2 key)` 兼作 C 的实参）。

**两类清理挂点（分清楚，不要混）**

| # | 入口 | 本批行为 | 理由 |
|---|---|---|---|
| ① | `--page-spec-clear-cache`（`1227`，全量失效：rotate / close / reload / redisplay-all 四处调用） | **整表置 nil**（`page-spec-cache` + `multipage-page-sizes` + 内存告警位） | 尺寸只在被测的几何下有效；四处调用都整体改几何。同时它是 D4 修订后的代际自增点（T4 落地） |
| ② | `--multipage-forget-specs`（`1537`，单页，被 `--multipage-recycle-page` 调用） | **只删 spec，尺寸保留**（代码内已写中文注释说明） | 若连尺寸一起删，回收远页时该页退回「高度 0 / span 下限 1」占位，**滚动范围在回收那一刻跳变**（P1/P2 反复踩过的坑）；尺寸每页两个整数、800 页仅几十 KB，无回收必要。T3 的「已定尺寸未渲染 == 已渲染页高」建立在此 |

**L1**：`make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**；elisp `Warning:` **20**（= 基线 20，**零新增**；新增代码所在行区间 `996–1262` 无任何 warning；只改 `seshat-reader.el` 的增量重建为 17 行，全为既有告警）；`checkdoc` **0 诊断**；改动 `.el` 的 `check-parens` 通过。`.so` 按既有 L1 流程重建（源码与 T1 交付内容一致，未改一行 C）。

**L2**：`make -C emacs/tests ert` → **FILES=38 / TOTAL=1345 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**。基线 37 文件 / 1333 例 ⇒ **新增 1 文件 / 12 例**（1345 − 1333 = 12，与逐条用例数对上）。skipped 恒 0（判据对含 `skipped` 的汇总行直接判失败，故 `UNEXPECTED=0` 已覆盖）。新测试文件单独跑：`Ran 12 tests, 12 results as expected, 0 unexpected`。

**验收 a–g 逐条**（用例全在 `seshat-reader-multipage-page-size-test.el`；夹具**只桩两个原生入口**，不用真实 PDF、不依赖已构建 `.so`，故无 `skip-unless`）

| 项 | 断言 | 用例 | 结果 |
|---|---|---|---|
| a | 未命中调 C 一次并写入缓存（键 = spec 缓存键）；再调计数不增 | `--miss-calls-native-once` / `--hit-skips-native` | 通过 |
| b | 查尺寸**不触发渲染**：`--page-image-spec` 计数恒为 0（命中/未命中都断言） | `--does-not-render` | 通过 |
| c | 失败不缓存：桩返回 nil ⇒ 两次调用计数 = 2；桩恢复后立刻能拿到并缓存 | `--failure-not-cached` / `--failure-recovers` | 通过 |
| d | 容量上限：`--multipage-cache-limit` 压到 2 后条目数 ≤ 2，FIFO 淘汰页 1；驻留页条目优先留下（页 3 自挤） | `--capacity-limit` / `--capacity-keeps-resident` | 通过 |
| e | `--page-spec-clear-cache` 后尺寸缓存为空，之后重新进 C | `--clear-cache-drops-sizes` | 通过 |
| f | **`--multipage-forget-specs`（单页）后该页尺寸仍在**且仍命中缓存（计数 0） | `--forget-specs-keeps-size` | 通过 |
| g | 无模块（函数单元置 nil ⇒ `fboundp` 为 nil）⇒ 返回 nil、不抛错、不动缓存 | `--without-module` | 通过 |
| 补充 | 键归一化共享（nil/1/1.0 一条条目，rotate 另算）；C 返回退化值（`(0 0)` / `(-1 10)` / `(:width 10)` / 字符串 / nil）按失败处理不缓存 | `--key-matches-spec-cache` / `--malformed-not-cached` | 通过 |

**本批不做（属 T3）**：4 处消费方（`--multipage-page-pixel-height`、`--multipage-max-page-width`、`--multipage-page-should-center-p`、`--multipage-resize-spec`）在「尺寸已知、spec=nil」态的行为——源码逐字未改；T2 原验收② 已按本节迁入 T3。`--multipage-native-size` 在该态仍返回 nil（不报错），亦待 T3 断言。

**真机**：本批无消费方改动，也无 redisplay 相关行为变化，故不涉及真机 L3；`render-async` 开关、占位行、idle 调度均在未来批次。


### T3 执行记录（2026-10-29）

**目标**：让页行支持第三态「已定尺寸、尚未渲染」（`spec=nil` 但尺寸缓存有条目），其页高、宽度、居中位置**与已渲染态完全相同**，从而「尺寸先行 + 像素后补」不改变布局。

**三态模型（T3 之后）**

| 态 | `seshat-reader--pages` 的 spec | 尺寸缓存 | 行文本 | 第二个字符的 `display` | 页高 |
|---|---|---|---|---|---|
| 未定尺寸未渲染（旧占位） | nil | 无条目 | `"  \n"` | 无 | 0（span 下限 1） |
| **已定尺寸未渲染（本批新增）** | nil | 有 `(W . H)` | `"  \n"` | `(space :width (W) :height (H))` | **H** |
| 已渲染 | spec | 可有可无 | `"  \n"` | spec 对象本身 | `:height` |

**几何口径收敛到一处**：新增 `--multipage-page-display-size`（spec 的 `:width`/`:height` 优先，缺项用尺寸缓存补，全缺返回 nil），四个消费方全部改为读它，不再各自摸 `(cddr entry)`：

| 消费方（当前行号） | T3 后的取值 |
|---|---|
| `--multipage-page-pixel-height`（`2271`） | `(or (cdr-safe (--multipage-page-display-size page)) 0)` —— 两态同值 |
| `--multipage-max-page-width`（`1613`） | 逐页 `(car-safe (--multipage-page-display-size page))` 取最大 —— 两态同值 |
| `--multipage-page-should-center-p`（`1585`） | 宽度同上来源；占位态因此**不再**落到「几何未知 ⇒ 假定居中」分支，宽页两态都判贴左 |
| `--multipage-resize-spec`（`1688`） | 源码逐字未改：既有 `(when (and spec (consp native) target) ...)` 已保证 spec=nil 时安全返回 nil（本批只补 docstring 说明） |

**行构造与补位（单一构造路径）**：新增 `--multipage-row-properties`（返回 `(GUIDE . BODY)`）作为**唯一**的 display 属性构造点，`--multipage-page-row`（建行）与 `--multipage-write-row`（改行）都调它：

- 占位态：`GUIDE = (space :align-to (+ center (-0.5 (W))))`，`BODY = (space :width (W) :height (H))`；`W/H` 一律 `(W)`/`(H)` 列表形式（裸数字 = 字体倍数，批次 0 实测 19008px vs 792px）。
- 已渲染态：`GUIDE = (space :align-to (+ center (-0.5 . SPEC)))`（仍是 spec **身份**引用，`:width` 就地重写后居中自动跟随），`BODY = SPEC`。
- 两态 `align-to` 同构（同一构造器、同一 `(+ center …)` 形态），且**像素等值**：`(-0.5 (W))` 与 `(-0.5 . SPEC)` 都解析为「半个 W」，前提是 `:scale 1`（C 侧已修，`.so` 已重建）。
- `--multipage-page-spacer` 单独承载「尺寸 → `space` 规格」的构造，只有宽高**都**是整数才产出（缺一项会塌行）。
- `--multipage-page-row` 新增**可选**第三参 `page`（两参调用契约不变）；`--multipage-insert-page` 建新行时传它，并据 `--multipage-page-should-center-p` 决定 `wide`（占位宽页从一开始就贴左，与补位后的状态一致）。
- `--multipage-page-centered-p` 增加占位分支（`equal` 比对 align-to 的像素宽度与 spacer）：否则 `--centered-p` 每帧都会把居中占位行判为「摆放过期」并重写一次 display 属性。

**marker 不变保证**：补位只经 `--multipage-write-row`，其实现仅 `put-text-property` / `remove-text-properties`，**不 insert/delete、不改行文本长度**（行始终 3 字符：两空格 + 换行）。`--multipage-insert-page` 的「已存在行」分支也只调 `write-row` + `setcdr`。ERT 用「记录 3 页 marker 位置 + 整段文本 → 补位页 2 → 断言逐项不变」直接钉住。

**L1**：`make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**；elisp `Warning:` **20**（= 基线 20，**零新增**）；`checkdoc` **0 诊断**；`seshat-reader.el` 与新增测试文件 `check-parens` 通过。

**L2**：`make -C emacs/tests ert` → **FILES=39 / TOTAL=1359 / UNEXPECTED=0**，EXIT 0；`check-criteria` → **PASS**。基线 38 文件 / 1345 例 ⇒ **新增 1 文件 / 14 例**（1345 + 14 = 1359）。新文件单跑：`Ran 14 tests, 14 results as expected, 0 unexpected`。

**验收 1–8 逐条**（全部在 `emacs/tests/seshat-reader-multipage-placeholder-test.el`；夹具只桩 `seshat-reader-dyn--page-size` 与 `window-body-width`，不用真实 PDF、不依赖真实 redisplay，无 `skip-unless`）

| 项 | 断言 | 用例 | 结果 |
|---|---|---|---|
| 1 | 占位行 `display` 恰为 `(space :width (612) :height (792))`，且 `:width`/`:height` **不是整数**（括号形式）；行文本 `"  \n"` | `--row-uses-pixel-form` | 通过 |
| 2 | 页高两态相等（792 == 792），且占位态页高 == `page-span` | `--height-equals-rendered` | 通过 |
| 3 | 最大页宽两态相等（612 == 612）；占位宽页（1200）参与取最大 | `--max-width-equals-rendered` / `--max-width-uses-widest-page` | 通过 |
| 4 | 居中判定两态一致：窗口 1000px ⇒ 两态均居中；窗口 500px ⇒ 两态均贴左；另断言居中占位行的 `--page-centered-p` 为 t、贴左为 nil、几何变化后判过期 | `--centering-equals-rendered` / `--centered-p-true` | 通过 |
| 5 | 补位（占位 → 写入 spec）后 3 个 marker 位置逐一不变、整段文本不变、该行 `display` 换成 spec（按 `eq`）；居中占位行补位后仍居中 | `--fill-moves-no-marker` / `--fill-keeps-centring` | 通过 |
| 6 | 尺寸未知（桩返回 nil）⇒ 行文本 `"  \n"`、两字符均无 `display`、页高 0、最大宽 nil、不报错 | `--degrades-without-size` / `--height-without-size-is-zero` / `--row-builder-without-page` | 通过 |
| 7 | `--multipage-resize-spec` 对 spec=nil 返回 nil 不抛错，页高与行属性不变；无行的页同样安全 | `--resize-spec-safe` | 通过 |
| 8 | 占位行属性 == `--multipage-row-properties` 对 `(1 nil)` 的结果；已渲染行同上且 `BODY` 是 spec 本身（`eq`）；两态 `align-to` 同构（car 同为 `+`、次元素同为 `center`、SOURCE 分别是 `(612)` 与 spec） | `--single-constructor` | 通过 |

**未覆盖项（诚实记录）**

1. **真机「滚动无跳变」（L3-①）未做，且本批无法做**：见 T3 条目的时序更正——T3 单独完成时没有任何路径让页面停在「仅尺寸」态，顺延到 T6 之后与 T9-⑥ 一起做。
2. **L3-③（占位行高 == 真实 image 行高）未重复测**：批次 0 的 S2（canvas 后端复测）已 4/4 组差 0 px（`:scale 1` 修复后），本批未改 C、未改 spec 尺寸语义，故不重复真机测量；batch 侧以「两态同值」的等价断言替代。
3. **尺寸缓存按页号取最新条目**（`--multipage-page-cached-size`）而非按 `(PAGE SCALE ROTATE)` 精确查：行构造器拿不到 scale，且按 scale 猜会让占位态与真实渲染几何不一致。若同一页在缓存里同时存在两个 scale 的条目，取最新一条；缩放后由 T5/T6 重新登记尺寸，T3 不处理该场景。
4. **`wide` 判定在建行时做**（`--multipage-page-should-center-p`）：渲染态仍沿用「先按居中建行、随后 `--set-page-centered` 纠正」的既有路径（未改），只有占位态在建行时即判定；两者最终状态一致（ERT `--centering-equals-rendered` 覆盖）。
5. `--batch` 的 frame 只有 80 像素宽，任何真实页面都会被判「比窗口宽」；测试夹具因此把 `window-body-width` 桩成 2000（用例内可再桩窄窗口）。


### T4 执行记录（2026-10-29）

**目标**：引入渲染代际，使**在途的异步渲染结果**在全量失效（缩放 / 切暗色 / 重载 / relayout）之后被丢弃，不能把旧几何的像素写回缓存或行属性（决策 D4）。本批只交付「代际 + 判定 + 清理」，调度器（idle / 周期 timer / pending）属 T5，未实现。

**代际变量与唯一自增点**

| 项 | 位置（当前行号） | 内容 |
|---|---|---|
| 变量 `seshat-reader--multipage-render-generation` | `seshat-reader.el:1024`（`defvar-local`，紧随尺寸缓存变量） | buffer-local 整数，初始 `0`；docstring 写明「只有全量失效才开新时代」与比对方式 |
| 占位变量 `seshat-reader--multipage-render-failures` | `seshat-reader.el:1044` | buffer-local alist `(KEY . COUNT)`，**T5 使用**（不变量④ 的「连续 3 次失败即不再登记」）；本批只定义 + 由全量失效清空，无写入者、无读取者 |
| 自增点（唯一） | `--page-spec-clear-cache`（`seshat-reader.el:1289` 起） | `(setq ... (1+ ...))` —— 用 `setq` 而非 `cl-incf`：本文件**未** `(require 'cl-lib)`，引入依赖会新增编译 warning |
| 显式**不**自增点 | `--multipage-forget-specs`（`seshat-reader.el:1749` 起的注释块） | 注释写明理由：该函数单页粒度且被 `--multipage-recycle-page` 高频调用，在此自增会让「滚动回收一页 ⇒ 作废全部在途 pending」，idle 补位被系统性作废、退化为超时强制同步（复审 N1）；并指名唯一入口 |

**同时清空（`--page-spec-clear-cache` 的 `setq` 一次清 5 项）**：`--page-spec-cache`、`--multipage-page-sizes`、`--multipage-render-failures`（T5 使用，注释已标注）、`--multipage-memory-warned`（既有），以及代际自增本身。

**比对能力（供 T5）**

| 名称 | 作用 |
|---|---|
| `seshat-reader--multipage-render-generation` | 直接读变量即当前代际 |
| `seshat-reader--multipage-generation-current-p (generation)` | 纯判定：`(and (integerp generation) (= generation <当前>))`；`nil` / 非整数一律 `nil`（缺代际的结果必须丢弃，不靠猜） |
| `--page-spec-remember (key spec &optional generation)` | `GENERATION` 非 nil 且非当前代 ⇒ **不写缓存、返回 `nil`**；nil = 不校验（旧行为逐字不变） |
| `--multipage-page-size-remember (key size &optional generation)` | 同上，作用于尺寸缓存 |

**`--page-spec-remember` 签名变化与调用点清单（grep 全仓 `--include=*.el`）**

| 调用点 | 实参 | 受新增 `&optional` 影响 |
|---|---|---|
| `seshat-reader.el:1242`（`--page-spec` 内，唯一生产调用点） | `(key spec)` 两参 | 无（`GENERATION` = nil ⇒ 不校验，行为逐字不变） |
| `seshat-reader.el:1285`（`--multipage-page-size-remember` 内部，唯一生产调用点，实际是尺寸缓存写入） | `(key (cons W H))` 两参 | 无 |
| 测试 `seshat-reader-multipage-generation-test.el`（本批新增 5 处） | 显式三参或两参 | 覆盖两条分支 |
| 其余文件 | **0 处**（`grep -rn "page-spec-remember\|page-size-remember" --include=*.el emacs/` 结果只有上述几行） | — |

⇒ **既有调用点零改动**（无一处被编辑），新增参数是纯向后兼容的扩展。

**「何时算旧几何」的时机表（本批落实的部分）**

| 时机 | 代际 | 在途结果 |
|---|---|---|
| rotate / close / reload / `--redisplay-all-windows`（4 处调用 `--page-spec-clear-cache`） | **+1** | 丢弃 |
| `--multipage-forget-specs`（单页；recycle 远页、单页重渲染） | 不变 | 保留（防过度作废） |
| 纯滚动（不改几何） | 不变 | 保留 |

**L1**：`make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**（gcc 编译行无诊断）；elisp `Warning:` **20**（= 基线 20，**零新增**；逐条核对均为既有项：bookmark/saveplace/translate 的 docstring 宽度与自由变量、`seshat-reader.el` 中既有行号 289/3471/3480/3489/3672 的 docstring 宽度、以及 `declare-function` 覆盖不到的 dyn 入口「not known to be defined」）；`checkdoc` **0 诊断**；`check-parens` 对 `seshat-reader.el` 与新增测试文件各自通过。

**L2**：`make -C emacs/tests ert` → **FILES=40 / TOTAL=1370 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**。基线 39 文件 / 1359 例 ⇒ **新增 1 文件 / 11 例**（1359 + 11 = 1370）。新文件单跑：`Ran 11 tests, 11 results as expected, 0 unexpected`。**旧 `.elc` 陷阱已规避**：先 `make -C emacs/seshat-reader all` 重建 `.elc` 再跑 ERT。

**验收 1–5 逐条**（全部在 `emacs/tests/seshat-reader-multipage-generation-test.el`；夹具沿用 T2 策略——`cl-letf` 桩 `seshat-reader-dyn--page-size`、不用真实 PDF、不依赖 `.so`、无 `skip-unless`、不碰任何 timer）

| # | 断言 | 用例 | 结果 |
|---|---|---|---|
| 1 | `--page-spec-clear-cache` 后代际 **+1**（连调 3 次 = 3，严格自增而非置 1）；尺寸缓存为空；失败计数表为空；spec 缓存为空；之后重新进 C | `--clear-cache-bumps` / `--clear-cache-drops-tables` / `--starts-at-zero` | 通过 |
| 2 | 单页 `--multipage-forget-specs`（模拟 recycle）后代际**不变**、`--generation-current-p` 仍为 t、该页**尺寸仍在**且命中缓存（C 计数 0）；spec 只掉该页 | `--forget-specs-keeps-generation` | 通过 |
| 3 | `--multipage-generation-current-p`：同代 t、跨代 nil；补充 nil / `"0"` / `0.0` / 符号一律 nil，且第 0 代有效 | `--predicate-same-generation` / `--predicate-across-generation` / `--predicate-rejects-non-integer` | 通过 |
| 4 | 模拟在途结果：记 `gen0` → `--page-spec-clear-cache` → `--generation-current-p gen0` ⇒ nil；带 `gen0` 调两个 remember 均返回 nil 且两张缓存仍空；同页在当前代际重查照常落缓存（丢弃不永久化） | `--inflight-result-dropped` | 通过 |
| 5 | 既有 40 文件 1370 例**零回归**（0 unexpected / 0 skipped） | 全量 `make -C emacs/tests ert` | 通过 |

**补充 3 例（向后兼容与隔离）**：两参 remember 旧行为不变（先让代际前进再两参写入，照常落缓存）、带当前代际的 remember 照常落缓存、代际是 buffer-local（外层 buffer 自增不影响内层 buffer）。

**未覆盖项（诚实记录）**

1. **计划 T4 验收①的「先登记 pending → 触发 idle 回调 ⇒ 行仍是占位」无法在本批做**：pending 集合与 idle 回调都是 T5 的交付物，本批还没有它们。等价断言改为「带旧代际调两个 remember 都不落缓存」（`--inflight-result-dropped`）——写回路径在 T4 之后只有这两个入口与（T5 的）补位函数，前两者已被钉住；**补位函数的代际判定与「行仍是占位」的断言留给 T5 的 ERT**。
2. **未跨批验证真机行为**：「缩放/切暗色期间不出现旧代际像素」是 T9 的 L3-③；本批无调度器，页面不会停在「仅尺寸」态，真机无可观察差异，故不涉及真机。
3. **代际不做 wrap 处理**：`1+` 单调增长，`bignum` 下等价于永不回绕（不引入模运算）；T5 只用 `=` 比较，不依赖大小。
4. **失败计数表本批无写入者**：`--multipage-render-failures` 仅定义 + 由全量失效清空；测试用手工塞条目验证清空语义。T5 落地时须同时实现不变量④ 的第二条清零路径（该页重新可见），本批不提前实现。

### T5 执行记录（2026-10-29）

**目标**：把「像素渲染」从滚动同步路径移到「idle 首轮 + 周期 timer 推进」的队列（决策 D5 的第三条保险 / 探针 G3b 的处置）。本批只交付**调度器 + prefetch 改造**；`--multipage-sync` 一行未动（T6 的活），因此视口内的页此刻仍同步渲染，异步链路目前只服务「预取页」。

**pending 结构（三项，均 buffer-local）**

| 变量 | 结构 | 语义 |
|---|---|---|
| `seshat-reader--multipage-pending-renders` | 页号列表，登记顺序（最老的在前） | 多窗口天然并集（D8）；只存页号，**不存 scale / rotate / window** —— 轮到时才用 `--multipage-target-scale` + `--multipage-rotate` 现算，故队列跨缩放依然有效 |
| `seshat-reader--multipage-pending-generation` | 整数或 nil | 队首登记时的代际；空队为 nil。tick 进场先比它，不匹配 ⇒ 整批作废（D4） |
| `seshat-reader--multipage-async-rendering` | 布尔 | tick 期间的防重入闸门 |

三个操作函数：`--multipage-pending-add`（去重 + 拒绝「已有 spec」+ 拒绝「已放弃」）、`--multipage-pending-remove`（队列变空时把代际一起清掉）、`--multipage-pending-clear`；另有 T6 用的 `--multipage-prune-pending (pages)`（只保留给定页集合，本批不接入 sync）。

**两个 timer 的分工与 REPEAT=nil 的机械依据**

| timer | 调用 | REPEAT | 作用 | 依据 |
|---|---|---|---|---|
| idle 首轮 | `(run-with-idle-timer seshat-reader-render-idle-delay nil #'--async-render-tick buffer)` | **nil（一次性）** | Emacs 安静下来后先跑一轮 | 探针 G3b：daemon 下一个 idle 窗口**只 fire 一次**（ticks = 1），回调自续不会让它再触发 ⇒ 它不能当驱动源，**tick 内部绝不重挂 idle timer** |
| 周期推进 | `(run-at-time delay delay #'--async-render-tick buffer)` | delay（重复） | 唯一可靠的持续驱动源 | G3b 的对照实验：普通重复 timer 每秒照跑（wake = 3/6/9/12/15） |

两者都存 buffer-local 变量（`--multipage-async-idle-timer` / `--multipage-async-render-timer`），`--schedule-async-render` **每次先 cancel 旧的再挂新的**（`--schedule-refit` 的「cancel + 单 timer + buffer 入参」范式），所以一次连滚只留两个 timer。周期 timer 的回调是捕获自身 `timer` 的闭包：buffer 被 kill 后没人能再读它的 buffer-local 变量，于是闭包在下一次 fire 时取消自己，不留空转 timer。取消函数刻意用 `(when var …)` 而**不是** `(timerp var)`，为的是让桩 `run-at-time` 返回 symbol 的测试也能断言「cancel 被调用」。

**tick 七步（`--async-render-tick` + `--async-render-batch`）**

| # | 动作 | 说明 |
|---|---|---|
| 1 | `(buffer-live-p buffer)` 守卫 → `with-current-buffer` | 死 buffer 是 no-op（取消由周期 timer 闭包负责） |
| 2 | 防重入：`--multipage-async-rendering` 非 nil ⇒ 直接返回 | 写文本属性可以经 window-state-change 回到 post-command 再回到这里 |
| 3 | 队列空 ⇒ cancel 两个 timer 并返回 | 空闲 reader 不留任何 timer |
| 4 | 队列代际 ≠ 当前代际 ⇒ 清队 + cancel 两个 timer 并返回 | D4；**在渲染之前**判断，省掉一次主线程无用功 |
| 5 | 置闸门，取队首 ≤ `seshat-reader-render-idle-batch` 页；每页现算 scale/rotate，调 `(--page-spec page scale rotate gen)` | 第 4 个实参是**队列代际**，渲染结果按代写入缓存 |
| 6 | 成功 ⇒ 清失败计数 → `--multipage-record-native` → 移出队 → **仅当该页有行时** `--multipage-insert-page`（内部即 `--multipage-write-row`：只写属性，marker 不动、文本不变）+ `--multipage-resize-spec` + 居中；无行的页只入缓存，不插行 | 无行页插行会把滚动范围撑大（T3/风险表） |
| 7 | 失败 ⇒ 该页计数 +1 并移出队（≥3 次后登记入口也拒绝）；batch 后队列空 ⇒ cancel 两个 timer | 第 3 次失败后该页本次会话内不再尝试 |

**失败计数（`--multipage-render-failures`）与两处清零**

- 结构 **`(PAGE . COUNT)`（页粒度）**，`--multipage-render-failure-limit` = 3。
- 清零路径①：`--page-spec-clear-cache`（全量失效，整表清空，T4 已实现）。
- 清零路径②：新增 `--multipage-reset-render-failure (page)`，供 T6 在「该页重新进入可见范围」时调用；tick 在渲染成功时也调它（计数只描述**连续**失败）。

**`--multipage-prefetch` 改造**

- 不再 `(--page-spec …)` 同步取像素，改为 `--multipage-pending-add` + `--schedule-async-render`，返回被登记的页号。滚动这一步既无渲染也无缓冲区修改（行数不变），与改造前「不插行」的约定一致。
- **函数名与调用点不变**：全仓 grep 只有一处生产调用点 —— `seshat-reader.el:2729`（`--multipage-sync` 末尾，`(--multipage-prefetch win)`）；其余命中都是测试与 docstring。`WINDOW` 参数保留但已不参与计算（`(ignore window)` + 注释），避免 byte-compile 的 unused-argument 警告。
- `--page-spec` 新增第 4 个可选参数 `GENERATION`（透传给 `--page-spec-remember`；nil = 不校验）。生产调用点 2 处：`--multipage-render-page`（3 参，行为逐字不变）与 `--async-render-batch`（4 参，传队列代际）。

**2 个新 defcustom（T7 的 4 个中的 2 个，本批因 T5 需要而提前落地）**

| 名字 | 默认 | 语义 |
|---|---|---|
| `seshat-reader-render-idle-delay` | `0.05` | **周期推进间隔**（秒），同时用作 idle 首轮延迟 |
| `seshat-reader-render-idle-batch` | `2` | 单轮最多渲染的页数 |

⇒ **T7 落地时必须只补另外 2 个（`--render-async` / `--render-async-timeout`），不要再重复定义这两个**（重复 `defcustom` 会让 customize 出现两个同名条目）。

**L1**：`make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**；elisp `Warning:` **20**（= 基线 20，**零新增**；逐条核对全是既有项：`seshat-reader-bookmark.el:70`、`seshat-reader.el:289/3889/3898/3907/4090`（docstring 宽度与 `revert-buffer` 的三个 `_` 参数）、`seshat-reader-saveplace.el:38`、`seshat-reader-translate.el:842`，以及 8 条 dyn 入口「not known to be defined」）；`checkdoc` **0 诊断**；`check-parens` 对 `seshat-reader.el` 与两个测试文件各自通过。

**L2**：`make -C emacs/tests ert` → **FILES=41 / TOTAL=1383 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**。基线 40 文件 / 1370 例 ⇒ **新增 1 文件 / 13 例**（1370 + 13 = 1383）。旧 `.elc` 陷阱已规避：改 `.el` 后先 `make all` 再跑 ERT。

**验收 1–8 逐条**（全部在 `emacs/tests/seshat-reader-multipage-async-render-test.el`；三个 timer 函数一律 `cl-letf` 桩住后手动 `funcall`，不真等 timer）

| # | 断言 | 用例 | 结果 |
|---|---|---|---|
| 1 | 登记 → tick → 页表写入 spec → 行 `display` 变成同一对象 → 队列空 → 两个 timer 都被 cancel | `--tick-fills-row-and-empties-queue` | 通过 |
| 2 | 登记后 `--page-spec-clear-cache`（代际 +1）⇒ tick 一次渲染都不做、不写缓存、不补位、队列被清 | `--generation-change-drops-batch` | 通过 |
| 3 | pending 5 页 × batch 2 ⇒ 单次 tick 只渲染 2 页，剩 3 页；再 tick 一轮累积 4 页、剩 1 页 | `--tick-renders-one-batch` | 通过 |
| 4 | 渲染恒返回 nil ⇒ 3 次后计数 = 3 且登记被拒，第 4 次 tick 不再渲染（计数器停在 3） | `--gives-up-after-three-failures` | 通过（补充 `--success-clears-failure-count`：成功后计数归零） |
| 5 | 失败 2 次 → `--multipage-reset-render-failure` → 再登记重试成功 | `--reset-failure-lets-page-retry` | 通过 |
| 6 | `run-with-idle-timer` 的 REPEAT = **nil**、周期 timer 的 REPEAT = delay；两轮 tick（idle 驱动 + 周期驱动）期间 idle 调用数恒为 1 | `--idle-timer-fires-once` | 通过（G3b 的机械守护） |
| 7 | 已 kill 的 buffer 上 tick 不报错；周期 timer 闭包在 fire 时 `cancel-timer` 自己 | `--dead-buffer-is-harmless` | 通过 |
| 8 | 渲染桩在渲染过程中重入 tick ⇒ 只渲染一次，闸门退出后复位 | `--tick-is-not-reentrant` | 通过 |

**补充 4 例**：`--pending-add-dedupes`（重复登记只入队一次、已有 spec 不登记、remove/clear 语义）、`--prune-pending-keeps-visible`（裁剪保留顺序、清空时代际一起清）、`--prefetch-queues-instead-of-rendering`（prefetch 零渲染零缓存零新行、排两个 timer；手动 tick 后才入缓存且仍不插行）、`--batch-default-is-two`（两个新 defcustom 的默认值）。

**旧用例改造（3 个 + 1 个加桩，均在 `seshat-reader-multipage-test.el`）**

| 用例 | 改动 |
|---|---|
| `--geometry-prefetch-warms-next-page-in-direction` | 断言从「缓存已被填」改为「队列里有该页且渲染计数 0」，再手动 tick 断言缓存被填；两个方向各一遍 |
| `--geometry-prefetch-does-not-insert-rows` | 增加「tick 之后仍不插行」（无行页只入缓存） |
| `--geometry-prefetch-skips-when-cached` | 断言从「不再渲染」改为「不再登记」（队列为空） |
| `--geometry-cache-bounded-while-scrolling` | 包一层新增的 `--with-silent-timers`（桩三个 timer 函数），避免 batch 里留下真的 0.05s 周期 timer |

**与计划/任务书的偏差（诚实记录）**

1. **失败计数的键从 `(PAGE SCALE ROTATE)` 改为 `PAGE`**：任务书与技术方案写 `(PAGE . COUNT)`，而 T4 的 `defvar-local` docstring 与不变量④括号里写的是 `(PAGE SCALE ROTATE)` —— 二者冲突。取**页粒度**并同步改 T4 的 docstring，理由是：tick 每轮都重新推导 scale，而「首次渲染记录 native 尺寸」会让 contain/width 模式下的目标 scale 在首渲染后变小，若按完整请求计键，计数会在最需要它的场景（渲染器持续返回 nil）被反复重置，「3 次后放弃」永远不触发。不变量④的语义（同一页连续失败 3 次即不再尝试）不变，实现更严（跨 scale 也累计）。
2. **pending 不记 scale / rotate**（任务书问「是否需记」）：不记。原因见上（几何在轮到时现算，队列跨缩放依然有效），代际已是「几何是否还成立」的判定。
3. **「tick 期间用户滚动」的处理**：本批不接入 sync，故 tick 期间滚动只会改变 `--multipage-scroll-direction` 与驻留集；tick 对「已不在驻留集」的页只写缓存、不插行（第 6 步的行存在性检查），因此不会撑大滚动范围。真正的「滚动后裁剪队列」由 T6 调 `--multipage-prune-pending` 完成。
4. **重复定义风险**：T7 计划交付 4 个 defcustom，本批已落地其中 2 个（见上）；T7 只补 `--render-async` 与 `--render-async-timeout`，不得重复定义。
5. **batch 默认值未改**：S1 实测扫描书单页 p50 19 ms / p95 49 ms ⇒ batch = 2 时单轮 40–100 ms（一次命令可感）。是否降到 1 或按页面积动态取 1/2 **留给用户决定**（本批不动默认值）。


### T6 执行记录（2026-10-29）

**一句话**：`--multipage-sync` 从「逐页同步渲染」变成三态分派器，滚动这一步只付「point 页 + 相邻一页」的像素成本，其余可见页先占位、像素交 T5 的调度器；`render-async` = nil 时原函数体逐字节等价可用，超时兜底保证「timer 失效也不会长期空白」。

**三态分流表**

| 态 | 触发条件 | 行为 | 返回 |
|---|---|---|---|
| **A（回退口）** | `seshat-reader-render-async` = nil | 清 pending + cancel 两个 timer + 清时间戳 → `--multipage-sync-blocking`（= T5 之前的原函数体，**未改一行**）；其末尾的预取按开关走**同步分支**（`--multipage-prefetch` 内部：取 spec 进缓存，不入队、不排 timer），跑完再清一次只是兜底。**2026-10-29 修复**：首版这里会把预取页随队列一起丢掉，等于「态 A 无预取」 | 同 blocking：区间或 nil |
| **B（默认）** | 开关为 t 且 pending 未超时 | ① 视口内同步渲染（见下）② 其余可见页：`--page-size` 定尺寸 → 占位行 → `--multipage-pending-add` ③ 回收区间外页 ④ `--multipage-prune-pending` 裁到可见范围 ⑤ 「本次重新进入」的页 `--multipage-reset-render-failure` ⑥ `--multipage-prefetch`（队列式）+ 内存体检 ⑦ `--schedule-async-render` + 记录 pending 起点 | 区间 |
| **C（超时兜底）** | 开关为 t **且** `--multipage-async-overdue-p` 为真 | `--multipage-clear-async-state`（清队 + cancel 两个 timer + 清时间戳）→ `last-range` 临时绑定 nil 后调 blocking（否则「区间未变」会早退）→ 重记 pending 起点（预取页仍会入队，给它完整的新窗口） | 同 blocking |

**形态细节**

- **视口内的定义**（定稿）：「point 所在页」+「沿 `--multipage-scroll-direction` 与该页**相邻**的一页」（direction 1 → point 页 +1；-1 → point 页 -1，clamped 到文档页数）。不是「视口上下两端都同步」，理由：`--multipage-visible-range` 已含 preload，若把整个视口都算同步就等于回到态 A；而「正在读的页 + 下一屏要读的页」才是「不能空白」的最小集（计划 D5 / 假设 A4 的落地形式）。其余可见页（含 preload 带）一律登记 pending，`render-idle-delay` 0.05 s 内补上。
- **为什么其余可见页必须同步建行**：页行就是布局（滚动范围的来源）。若等像素到了再插行，`--multipage-visible-range` 会在下一轮算出不同的区间，滚动范围跳变——正是 T3 用占位行消掉的那个坑。故 `--multipage-placeholder-row` 先 `--page-size` 定尺寸再 `--multipage-insert-page page nil`（只改属性、不改文本、不动 marker）。
- **尺寸按「目标 scale」量（两阶段量法）**：`--page-size page 1.0` 得 native，把 native 临时挂进 `--page-native-sizes` 让 `--multipage-target-scale` 走**同一张** fit 表算出目标 scale（不复制 D5 的表），再量一次得最终显示尺寸。绑定随函数返回撤掉：未渲染的页不得留下 native 尺寸（渲染证据是 `--page-render-scales`）。超宽页（contain 下目标 scale < base）因此不会「补位那一刻行高缩水」——机械守护见 `--placeholder-uses-target-scale`。
- **裁剪接入点**：`--multipage-prune-pending` 在「渲染 + 回收」之后、「预取」之前调用，参数是 `--multipage-visible-range` 展开的页号列表（即「可见范围 ± preload」，与任务书口径一致）。顺序很关键：先裁后预取，否则预取的那一页会被立刻裁掉。
- **失败清零接入点**：对「本次在范围内、上一轮不在范围内」且计数 > 0 的页调 `--multipage-reset-render-failure`。只对**新进入**的页清零（不是每轮对全部可见页）——否则一页停在视口里就会每次命令都被清零，「连续失败 3 次放弃」永远不触发。
- **同轮出队**：本轮同步渲染完的页立刻 `--multipage-pending-remove`（多窗口并集下它可能早先被别的窗口登记过），避免 tick 白跑、也避免队列「看起来永远非空」把超时兜底误触发。
- **超时时刻的记录方式**：新增 buffer-local `seshat-reader--multipage-async-pending-since`，在 `--multipage-pending-add` 里「队列由空变非空」的那一刻写 `(float-time)`；队列被清空的三条路径（`pending-clear` / `pending-remove` 至空 / `prune-pending` 至空）都把它置 nil；`--multipage-note-pending-since` 是幂等的补齐口（dispatch 与 forced pass 收尾各调一次）。判据 `--multipage-async-overdue-p` = 队列非空 ∧ 时间戳是数字 ∧ `(float-time)` − 时间戳 > `--render-async-timeout`。计的是**这一段 pending 的年龄**，不是最后一页的入队时刻。
- **不许同步等 timer**：`--multipage-sync` 三态内无 `sit-for` / `accept-process-output` / `sleep-for`（grep 空结果）。

**调用点清单（`--multipage-sync` 的 7 处生产调用，返回值语义全部不变）**

| 行 | 所在函数 | 类别 |
|---|---|---|
| 3482 | `seshat-reader--multipage--after-command` | `post-command-hook`（每命令） |
| 3561 | `seshat-reader--ensure-window-layout` | `window-state-change-functions` |
| 3447 | `seshat-reader--multipage-scroll` | 跨页滚动函数自身 |
| 3089 | `seshat-reader--multipage-goto` | 跨页跳转 / `next-page` / `previous-page` / `zoom-goto` |
| 559 | `seshat-reader--multipage-set-scale` | 缩放（`+`/`-`/`0`） |
| 3853 | `seshat-reader--recenter-window` | 重新居中 |
| 4970 | `seshat-reader--redisplay-all-windows` | 切暗色 / 全量重绘 |

**L1 / L2 数字**

- L1 `make -C emacs/seshat-reader clean all`：**EXIT 0**；C **0 error 0 warning**；elisp `Warning` **20**（= 基线，零新增）；checkdoc **0**（`Open parenthesis in column 0` 已修）；`check-parens` 通过。
- L2 `make -C emacs/tests ert`：**42 文件 / 1396 例**、**0 unexpected / 0 skipped**；`check-criteria` **PASS**。基线 41 文件 / 1383 例（T5 实测）⇒ 本批 **+1 文件 / +13 例**（首版 11 例 + 2026-10-29 态 A 等价性修复 2 例）。
- 新增用例文件：`emacs/tests/seshat-reader-multipage-sync-async-test.el`（13 例）。

| # | 断言 | 用例 | 结果 |
|---|---|---|---|
| 1 | 态 A 渲染页序 == `--multipage-sync-blocking` 单独调用（两条独立构造的等价缓冲区，两边同绑 `render-async` = nil），且态 A 不留 pending / timer / 时间戳；页序含末尾的同步预取页 | `--state-a-equals-blocking` | 通过（2026-10-29 修复后页序 `(1 2 3 4 5 6)`） |
| 1b | 态 A 的预取真的预热：预取页被渲染一次、进缓存、不插行；零异步残留 | `--state-a-prefetches-next-page` | 通过（2026-10-29 新增） |
| 1c | 态 B 的预取只登记：本轮页序不含预取页、缓存无它、队列含它 | `--state-b-prefetch-still-queues` | 通过（2026-10-29 新增） |
| 2 | 态 B：point 页 + 方向相邻页在 sync 内渲染，其余可见页只登记（占位行高已是最终值），两个 timer 排上 | `--state-b-renders-point-and-direction` | 通过 |
| 2b | 态 B 无行页立即建占位行（尺寸可信）、反向滚动取「point 页 + 前一页」、同步页当轮出队 | `--state-b-inserts-placeholder-rows` / `--state-b-renders-backwards` / `--state-b-removes-rendered-from-queue` | 通过 |
| 3 | 登记 [1..10]、范围 [4..6] ⇒ 队列只剩 4（+ 预取页 7） | `--state-b-prunes-to-visible-range` | 通过 |
| 4 | 失败 2 次的页离开后再回来 ⇒ 计数归 0、允许重试 | `--state-b-clears-failure-on-reentry` | 通过 |
| 5 | `float-time` 桩推进：未超时早退不动队列；超时后同区间强制同步、队列清空、两个 timer 取消、时间戳清空 | `--state-c-timeout-forces-sync` | 通过 |
| 6/7 | t → nil 三轮：打开时「队列非空 ⇔ 两个 timer 都在」，关掉后队列/代际/时间戳/两个 timer 变量全空；首轮确实登记过 | `--toggle-leaves-nothing-behind` | 通过 |
| 8 | 全量零回归 | `make -C emacs/tests ert` | 42/1394、0 unexpected |
| 附 | 占位行按目标 scale 量（1200×800 native + 1000 px 窗口 ⇒ 1000×667，不是 1200×800） | `--placeholder-uses-target-scale` | 通过 |

**既有用例改造（3 个，均在 `seshat-reader-multipage-test.el`）**

| 用例 | 改动 | 理由 |
|---|---|---|
| `--sync-is-idempotent-per-range` | `let*` 里加 `seshat-reader-render-async nil` | 断言的是「区间内逐页同步渲染」+ 渲染计数（首轮 = 页数），异步态下必然只有 2 页被同步渲染 |
| `--sync-recycles-pages-outside-range` | `let` 里加同一绑定 | 同上（`display-count` = 区间内页数） |
| `--sync-rebuilds-rows-after-external-wipe` | `setq-local seshat-reader-render-async nil` | 自愈断言「sync 之后每页都有 spec」，异步态下页行先以占位态插回 |

三条都**只加绑定、未改任何断言**：它们覆盖的是态 A 的语义，异步态的同名契约由本批新增文件覆盖（计划 T8 的「等价性」用例部分已提前落地）。

**与计划/任务书的偏差（诚实记录）**

1. **「视口内」定稿为「point 页 + 相邻页」**（任务书原文即如此），但**其余可见页必须同步建占位行 + 同步查尺寸**——任务书的态 B 步骤只写「其余可见页 ⇒ 登记 pending」，漏了「行是布局的一部分」。不加这一步滚动范围会在像素到达前塌陷（T3 的占位机制就是为此存在）。故态 B 的实际同步成本 = 「2 次 `--page-spec` + 其余页各 2 次 `--page-size`（µs 级）+ 建/改行属性」，仍远低于逐页渲染。
2. **`--multipage-sync-blocking` 的 docstring 末段被改写**：原末段写「把可见页像素移出本路径是 T6 的活，本批只把预取搬到队列」，搬进 blocking 后这句已失真，改成「同步那一半的定位」。**函数体一行未动**（可 diff 审计）。
3. **同步渲染完的页当轮出队**（任务书未提）：多窗口并集下这是必须的，否则 tick 会为已渲染页白跑，且队列非空会喂给超时兜底。
4. **态 A 下预取页不再被预热** —— **已修复（2026-10-29）**（批次报告中的「偏差 2」）。原状：T5 把 `--multipage-prefetch` 改成「登记 + 排程」的队列形态，态 A 又要求「零异步残留」，于是那条队列项在收尾时被丢弃——`render-async` = nil 时相当于「无预取」，比改造前少一页提前量：几何没变，但**行为不等价**，不变量③（nil 时逐字节等价）不成立、回退口不成立。
   - **修法（最小）**：**不新增调用点**——`--multipage-sync-blocking` 里本来就只有一处预取调用，改成在 `seshat-reader--multipage-prefetch` **内部按开关分流**：`render-async` 非 nil ⇒ 沿用 T5 的 `pending-add` + `--schedule-async-render`；为 nil ⇒ 恢复改造前的同步分支（`--multipage-spec-cached-p` 守卫 + `--page-spec page (--multipage-target-scale page WINDOW) --multipage-rotate`，于是 spec 进 `--page-spec-cache`），**不入 pending、不排 timer**。函数名、签名（含 `WINDOW`）与 5 个调用点全部未变；`WINDOW` 重新被同步分支用于算目标 scale（原本 `(ignore window)` 的注释随之删除）。
   - **每轮 sync 只预取一次**：同步路径的唯一预取调用点仍是 `--multipage-sync-blocking` 末尾那一处，分流发生在它内部 ⇒ 不存在「两次预取」。态 C 的 forced pass 走同一函数、开关为 t ⇒ 行为不变。
   - **ERT 证据（`make -C emacs/tests ert`，42 文件 / **1396** 例 / 0 unexpected / 0 skipped，`check-criteria` PASS；本批 +2 例）**：
     | 断言 | 用例 | 结果 |
     |---|---|---|
     | 态 A 页序 = `--multipage-sync-blocking`（同绑 nil）页序 = `(1 2 3 4 5 6)`（文档 7 页、可见范围 [1..5]、预取页 6） | `--state-a-equals-blocking` | 通过 |
     | 态 A 预取页 5 真的被渲染且进缓存（`--multipage-spec-cached-p` = t），不插行；pending / timer / 时间戳全空 | `--state-a-prefetches-next-page` | 通过 |
     | 态 B 不变：页序 `(3 4)` 不含预取页 6、缓存无 6、队列为 `(1 2 5 6)` | `--state-b-prefetch-still-queues` | 通过 |
     | 开关 t → nil 三轮（视口交替使区间每轮都变）：t 轮不渲染预取页、nil 轮当场渲染它；每轮收尾队列 / 代际 / 时间戳 / 两个 timer 全空 | `--toggle-leaves-nothing-behind` | 通过 |
   - **剩余偏差**（诚实记录）：夹具层面的一个事实——缓存额度 = 2×preload+2，与「驻留行 + 预取页」逐轮趋平，缓存满时第一个被淘汰的正是非驻留的预取页（`--cache-eviction-victim`）。故「预取页在缓存里」只能在「驻留行数 < 额度」的布局（本批用例取单页视口）稳定观察到；生产里预取的真实收益是「下一次滚动那一页的 native 解码已在模块侧就绪」，与缓存条目是否存活是两件事。此为既有设计性质，本批不处理。
5. **失败清零只对「新进入」的页生效**（任务书写「对本次重新进入可见范围的页」）：若对全部可见页每轮清零，「连续失败 3 次放弃」就不会触发。

**待用户确认的建议（本批未改默认值）**

- S1（批次 0 实测）扫描书单页 **p95 49 ms**、p50 19 ms ⇒ `seshat-reader-render-idle-batch` = 2 时**单轮 tick 最长约 100 ms**，这是一次命令可感的停顿（虽然它发生在 idle/周期 timer 里，不与按键同帧）。T5 的建议是「按页面积动态取 1/2」（letter 页 2 页、扫描书/大页 1 页）。**本批不动默认值**，留到 T9 真机做主观判定：若连续滚动仍有可感顿挫，再把 batch 的默认值改 1 或改成面积自适应。请在 T9 前给出取舍。

### T8 执行记录（2026-10-29）

**一句话**：本批补 7 例之外，**先修掉 D8 的实现缺陷**——pending 队列的裁剪口径原本是「调用窗口的可见页」（交集），而 `--multipage-pending-renders` 的 docstring 声明的是「所有显示该 buffer 的窗口请求的并集」；两个窗口滚到不同位置时会互相删掉对方刚登记的页。修法只动裁剪实参，渲染 / 回收 / 失败清零三个循环仍只看本窗口的范围。

**D8 缺陷（修前）**

| 项 | 位置 / 事实 |
|---|---|
| 声明 | `seshat-reader.el` 的 `seshat-reader--multipage-pending-renders` docstring：「holds the union of what every window showing the buffer asked for (decision D8)」 |
| 实现 | `--multipage-sync-async` 里唯一裁剪点（原 `seshat-reader.el:3040`）实参是 `pages` = `(number-sequence (car range) (cdr range))`，即**调用窗口**的可见范围 ⇒ 实际口径是「队列 ∩ 该窗口范围」 |
| 后果 | 窗口 A 登记了 3、6 号页，窗口 B 的下一轮 pass 在 B 的范围（4..7）上裁剪 ⇒ 3 被剪掉，A 的空白页要等到它自己下一轮 pass 才重登记（且若 A 与 B 交替滚动，每次都互相清空）。计划 D8 与风险表「双窗口 pending 争用」判的是并集语义 |
| 为什么此前没被发现 | 现有用例全是单窗口；`--state-b-prunes-to-visible-range` 只验证「滚过去的页要被裁掉」，单窗口下交集与并集等价 |

**修法（最终形态）**

| 项 | 内容 |
|---|---|
| 新函数 | `seshat-reader--multipage-all-visible-pages (&optional window)`，紧跟在 `seshat-reader--multipage-visible-range` 之后（布局层）。对每个窗口取 `--multipage-visible-range`（视口 ± preload）展开成页号，**取并集**（升序、去重，`delete-dups` + `sort`）；窗口集合 = `(window-list)` 里 `(eq (window-buffer w) (current-buffer))` 的那些，再把 `WINDOW` 参数显式并入（`window` 为 nil 时就是选中窗口，`window-list` 已覆盖，仍按任务书显式并入）；某窗口 range 为 nil 时跳过；全部为空时返回 nil。用 `window-list` 而非 `get-buffer-window-list`（前者在 batch/daemon 下行为更可预测，且过滤条件与布局其余部分同一条） |
| 调用点 diff | `--multipage-sync-async` 内**一行**：`(seshat-reader--multipage-prune-pending pages)` → `(seshat-reader--multipage-prune-pending (seshat-reader--multipage-all-visible-pages window))`，上方加 4 行注释说明「队列是共享的、布局不是」 |
| 未改的部分（如何确认） | 渲染循环 `(dolist (page pages) (if (memq page sync-pages) …))`、回收循环 `(dolist (entry (copy-sequence seshat-reader--pages)) … (< page first) (> page last) …)`、失败清零循环 `(dolist (page pages) …)` **三处实参仍是本窗口的 `pages`**。机械证据：`git diff` 里 `seshat-reader--multipage-sync-async` 的改动只有 docstring 段 + prune 那一行 + 注释；`grep -n "multipage-all-visible-pages" seshat-reader.el` 只有定义、prune 调用点与 docstring 三处命中 |
| `--multipage-prune-pending` 的 nil 语义 | 原实现「PAGES 为 nil ⇒ 队列被清空」。并集在「无窗口报出范围」时正好是 nil，此时清队会丢掉仍有效的工作 ⇒ 改为 **nil 时不动队列直接返回**。docstring 重写，明确「实参是并集而不是调用窗口的范围」以及「渲染/回收仍按窗口」。这条改动**要求更新一个既有用例**（见下） |
| 为什么改在 prune 侧而不是调用侧 | 任务书要求「nil 时应直接返回、不清队」；在 prune 侧收口后，任何将来新增的调用点都不会踩到「nil 把队清空」这个坑，代价只是 `--prune-pending-keeps-visible` 的一条断言需要按新语义改写（见偏差 1） |

**新增 7 例**

| # | 用例 | 断言要点 | 结果 |
|---|---|---|---|
| 1 | `seshat-reader-sync-async-test--state-a-matches-baseline-geometry` | 两个独立构造的等价缓冲区（态 A vs 直接调 `--multipage-sync-blocking`，两边 `render-async` = nil）：行数、每页 marker 位置序列、每页 spec 的 `:width`/`:height`、`--multipage-max-page-width`、逐页 `--multipage-page-pixel-height` **五项逐一相等**，最后整份快照也 equal（防止将来往快照加字段忘了断言） | 通过 |
| 2 | `seshat-reader-multipage-async-test--pending-union-across-two-windows` | `split-window` 造两窗口（A 视口 (4 . 5) ⇒ 范围 3..6；B 视口 (5 . 6) ⇒ 范围 4..7；并集 3..7），方向向前（-1，两轮预取都不把并集外的页补回来）：先 A 后 B —— A 的队项 3 不在 B 的范围里，仍留在队列；再 A 单独跑一轮 —— B 的队项 7 不在 A 的范围里，仍留在队列。断言队列精确为 `(3 6 2)` → `(3 7)` → `(3 7 2)` | 通过（**变异测试**：把 prune 实参改回 `pages` 后本用例失败，实测 `(3 7)` vs `(7 3)`） |
| 3 | `seshat-reader-multipage-async-test--queued-pages-stay-out-of-spec-cache` | `render-idle-batch` = 1、登记 3 页、跑一轮 tick：缓存恰 1 条且是刚渲染的第 1 页，另两页 `--multipage-spec-cached-p` = nil 且仍在队列（D7 的「部分排空」角度） | 通过 |
| 4 | `seshat-reader-multipage-async-test--tick-fill-moves-no-marker` | 两页占位（尺寸桩使页高已是 800）→ tick 补位：**全部页 marker 位置逐条不变、`buffer-substring-no-properties` 全文逐字节不变**、目标行 `display` 变成真 spec（`eq` 同一对象）、另一页仍是 `space` 占位、页高仍是 800（覆盖 tick 内 `resize-spec` + `set-page-centered` 之后的路径） | 通过 |
| 5 | `seshat-reader-multipage-async-test--generation-move-during-render-is-not-a-failure` | 渲染桩内部先 `--page-spec-clear-cache` 再返回 nil ⇒ 代际 +1、`--multipage-render-failure-count` 仍 0、`--multipage-render-failed-p` = nil、`--multipage-render-failures` 整表为空、队列与代际已清、无补位、无缓存、两个 timer 被取消（对应 `seshat-reader.el` 的 `invalidated` 分支，修前零覆盖） | 通过 |
| 6 | `seshat-reader-sync-async-test--state-c-rearms-pending-since` | `float-time` 桩 1000.0 → 1001.5 → 1001.6 → 1002.6，pagecount 7（独立 buffer 夹具，不动 `--state-c-timeout-forces-sync` 的 pagecount = 5）：态 B 起点 1000.0 → 超时强制同步后预取页 6 仍入队、`--multipage-async-pending-since` 重置为 **1001.5**（≠ 1000.0）、两个 timer 重新排上 → 1001.6 未到期 → 1002.6 再次到期（窗口是完整的，不是残值） | 通过 |
| 7 | `seshat-reader-multipage-async-test--custom-defaults` | `seshat-reader-render-async` = t、`seshat-reader-render-async-timeout` = 1.0（补 `--batch-default-is-two` 未覆盖的两个 T6 defcustom） | 通过 |

**夹具扩展（步骤 2）**

- `seshat-reader-multipage-async-test--with-body` 新增两个桩：`window-start` / `window-end`。默认行为**不变**：它们只在 `seshat-reader-multipage-async-test--viewports`（alist `WINDOW . (FIRST-PAGE . LAST-PAGE)`，默认 nil）里有该窗口时改答该页行首，否则转调进夹具前捕获的真实函数。这样既有 18 个用例零改动（除下面偏差 1 那一条断言）仍然通过。
- 另加 `--row-start` 辅助函数（页号 → 行首位置），供视口桩与新用例共用。
- 为什么必须按窗口查表：batch 下 `window-end` 不可信（一整页行只是一行文本），两个窗口会算出同一个范围，用例 2 就会在「交集实现」上也通过（假绿）。

**L1（实测）**

- `make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**；elisp 字节编译 `Warning:` **20**（= 基线 20，零新增）；`checkdoc` **0 诊断**；`check-parens` 3 个改动文件全部通过（shell 与 `verify` 隔离实例各一次）。
- 改动后曾用 `make -C emacs/seshat-reader all`（增量）复核过一次：EXIT 0 / 0 error / 该文件 17 条既有 warning（清空构建的总数 20 含其它文件）。

**L2（实测）**

- `make -C emacs/tests ert` → **FILES=42 / TOTAL=1403 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**（四条判据行全部按预期，含 `Ran 0 tests` 的假绿拦截）。基线 42 文件 / 1396 例 ⇒ **+7 例**，无新增文件。两个改动文件的单文件跑数：async-render-test 13 → **18**，sync-async-test 13 → **15**。
- 旧 `.elc` 陷阱复发一次（第一次跑新用例时 `--multipage-all-visible-pages` 报 `void-function`：加载的是上一次构建的 `seshat-reader.elc`）⇒ 改 `.el` 后必须先 `make -C emacs/seshat-reader all` 再跑 ERT；已按此顺序重跑并留证。

**elisp-mcp 三实例流程（实测痕迹）**

| 步骤 | 结果 |
|---|---|
| `elisp_mcp_set_task(verify)` | `{"status":"ok","task":"verify",...}` |
| `elisp_mcp_instance(verify, start)` | `{"status":"started",...}` |
| `elisp_mcp_instance_status(verify)` #1 | `socket-exists:false, alive:false` |
| `elisp_mcp_instance_status(verify)` #2 | `socket-exists:true, alive:true`（约 11 s 就绪，**未出现历史上那种启动卡死**） |
| 实例内 `elisp_check_parens` × 3 文件 | 全部 `{"status":"ok"}` |
| 实例内 flymake（trigger + get，`seshat-reader.el` 与 async 测试文件） | `未收集到诊断（未启用 Flymake 或后端未产生诊断）` —— 该实例没有启用 flymake 后端，**故本批没有 flymake 数值**；语法与定义层的把关由 `make all`（字节编译 + checkdoc）与 `check-parens` 承担 |
| 实例内 `elisp_eval_expression` + `load-file` | 被 MCP 黑名单拦下（`禁止调用危险符号: load-file`）⇒ 「外部改盘后在实例内重载文件」这条路走不通，未强行绕过 |
| 收尾 | `set_task(auto)` → `instance(verify, stop)` → `instance_status` 确认 `task:"auto"`、`alive:false`、`socket-exists:false`、`task-ttl-seconds:"auto（无 task 文件）"` |

**与计划的偏差（诚实记录）**

1. **改了一个既有用例的断言**：`seshat-reader-multipage-async-test--prune-pending-keeps-visible` 原来断言「`--prune-pending` 传 nil ⇒ 队列被清空」，与新语义（nil = 没有窗口报出范围 ⇒ 队列原样保留）冲突。改为断言 nil 不动队列 + 用一个**不含任何队项的集合** `'(9)` 验证「真的全裁掉时队列与代际都清空」，即原断言的语义（队列能被裁空）仍然被覆盖。这是任务书步骤 1 要求的语义变更的直接后果，不是顺手改断言；其余既有用例零改动。
2. **`--multipage-prune-pending` 的语义改在函数内部**（任务书列了「剪在调用点」与「改 prune」两条路，选择后者），理由见修法表最后一行。
3. **用例 2 的视口与方向是推算出来的**：为了让「A 的队项落在 B 范围之外」与「B 的队项落在 A 范围之外」两件事都能同时观察到，需要两窗口范围部分重叠（重叠是必然的：`--multipage-sync-async` 会回收本窗口范围外的行，两个相距很远的窗口在单 buffer 里本来就不可能同时驻留——这是既有设计性质，不在本批范围），且**滚动方向取 -1**（方向 +1 时 A 的预取页恰好是 B 的预载页，会在下一轮被重新登记，从而掩盖裁剪差异）。
4. **未做**：没有为「回收 + 双窗口」的组合做用例（两窗口相距较远时行会被互相回收，属既有设计限制，需 T9 真机观察，见下）；没有 flymake 数值（实例无后端）；没有提交 git（按任务书）。
5. **做得比计划多的**：对用例 2 做了一次**变异测试**（把 prune 实参改回 `pages`、重编译、重跑），实测该用例失败（`(3 7)` vs `(7 3)`），证明它不是「怎么改都绿」的空断言；随后已恢复源码并重新 `make all`（md5 回到 `daa2b119…`）。
6. **页码/行号漂移**：`seshat-reader.el` 因新增函数而整体后移约 45 行，计划其它小节里引用的行号（如 `3040`）已不再准确；本记录只按修前事实标注「原 `seshat-reader.el:3040`」。后续若要行号，请以 grep 函数名定位。

**改后 md5 / 安全点**

| 文件 | 改前 | 改后 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `15625c82b4768cb3b55f708520347569` | `daa2b119d486dd174567509ec736eaf6` |
| `emacs/tests/seshat-reader-multipage-async-render-test.el` | `5f0f0a7a11dcd8028670c27c97511fd6` | `086a30046be98bd5af5bc442048f091b` |
| `emacs/tests/seshat-reader-multipage-sync-async-test.el` | `5cd2fdbe619b38d14e26a2e86eeae062` | `f89dae6cc60e44aea78cbf964699f764` |

安全点 = 起点 `HEAD` = `d240b5616bfea3db42d7230904b5879d5fe27239`（工作区在开工时干净，故未 `git stash create`；回滚口径即 `git checkout -- <三个文件>`）。未提交、未 push。

### T9 客观测量（2026-10-29）

**口径**：独立 GUI 进程（`emacs -Q -l /tmp/t9-*.el`，pgtk frame 130×60、`(frame-char-height)` = 20、`(display-graphic-p)` = t），临时可见 frame + `(redisplay t)` + `window-text-pixel-size` 显式放开 X/Y 上限（`100000`）；**不碰主实例、不重启主实例**。样本：`Ghostscript.pdf`（矢量 477 页，`base-scale` 0.35）+ 真实扫描书（见「样本替换」），五页驻留。

| 项 | 方法 | 结果 |
|---|---|---|
| **M1 页高与滚动几何一致（三态）** | 同一页分别取「已渲染 / 占位（走生产路径 `--multipage-placeholder-row`）/ 恢复渲染」三态的行像素高 + `--multipage-page-pixel-height` | 三态**逐值相等，差 0 px**；`:scale 1` 修复后页高与真实 image 行高一致 |
| **M2 空闲后 pending 清空** | 态 B（异步默认）渲染 + 真实空闲（无输入） | pending 队列在 **≈2.5 s** 内清空，无残留占位页 |
| **M3 不抖动** | 连续采样 row→row 距离与页行高 | 无抖动（无 ±1 px 漂移） |
| **M4-a D8 真机生效** | 双窗口各自视口滚不同页 | 两窗口的 pending 队项互不删除（并集语义在真机成立，与 T8 的 ERT 变异测试同结论） |
| **M4-b 塌陷量化** | 两窗口视口相距较远时行被互相回收 | 已量化记录：属既有设计限制（单 buffer 行驻留集），不在本项范围，留给 T9 主观项观察 |
| **主实例是否已载入本批 `.so`** | 主实例启动时刻 **10:13:17** < `seshat-render-core.so` 构建时刻 **11:48:22** | **未重启** ⇒ 上述 M1–M4 只能由独立进程代表；**主观 L3-①/②/③/⑤/⑥ 必须在用户重启主实例后做** |
| **样本替换（诚实记录）** | 上一批用的 `/home/thomas/Workspace/seshat/《新赤脚医生手册》 .pdf` 已不在仓库（`file-exists-p` = nil） | 本批改用 `/home/thomas/Workspace/Tongji-University-Linear-algebra/线性代数 同济第六版【高清OCR可检索版本】.pdf`（真实扫描书 182 页）+ `Ghostscript.pdf`；`base-scale` 与三分段实测法与上一批**完全一致**，故「修复前 → 修复后」的数字可比 |

### T9 分隔区 span 修复（2026-10-29）

**缺陷（修前）**

| 项 | 位置 / 事实 |
|---|---|
| 现象 | `--multipage-page-gap-pixels` 报 10 px（默认 `page-separator-height` 0.5 / `thickness` 2 / char-h 20），实测页间实际高度 **28 px** |
| 偏差规律 | 恒为 `frame-char-height − thickness`（char-h 20/25/35/17 → +18/+25/+33/+15）；`seshat-reader-page-separator` 关掉后偏差归零（0/0） |
| 根因 | 分隔区**规则行**的 `display` 属性是 `(space :align-to (- right 0))`（`--multipage-separator-row`，修前行 1654），**没有 `:height` 语义**：stretch space 行高恒为一个字体行高，row 里烘焙的 face `:height` 比例对它无效；上/下**空白行**是普通文本行，`:height 0.2` 精确生效（4 px 精确） |
| 影响面 | `--multipage-page-span`（= 页行高 + gap，修前行 3277）是 `--multipage-scroll` 跨页累减距离的**唯一**依据（`seshat-reader.el:3512-3526`）⇒ 每页少算一个字符行高，**跨页落点累积偏移**（5 页 = 90 px @ char-h 20） |

**落点判定（为什么加在 `--multipage-page-gap-pixels` 里）**

| 判据 | 结论 |
|---|---|
| `--multipage-page-gap-pixels` 的语义 | docstring 原文是「the pixel height of **everything that follows** a page row」——即**实际**像素高度，不是名义值；它撒谎了才是缺陷本身 |
| 它的消费方清单（`grep` 全仓） | 代码消费方**只有** `--multipage-page-span` 一处（其余是 docstring 提及 `seshat-reader.el:1939` 与测试断言）；`--multipage-separator-segments` / `--multipage-separator-rows`（真正**生成**分隔行的路径）用的是**名义** `--multipage-separator-pixels`，**不经过** gap-pixels |
| 是否存在依赖名义值的消费方 | 无 ⇒ 补偿放在 gap-pixels 里，span / `--multipage-page-max-offset` / 跨页累减距离**全部自动受益**，且「实际高度」只有一处定义（单一事实来源） |
| 未动的部分（不变量） | `--multipage-separator-row` / `--multipage-separator-rows` / `--multipage-separator-pixels` / `--multipage-separator-segments` 的三段分配 / face / `:height` **逐字未改** ⇒ 视觉不变（页间距仍是 28 px，没有变窄成 10 px） |

**补偿函数（新增纯函数，可单测）**

`seshat-reader--multipage-separator-extra-pixels (&optional window)`，紧跟在 `--multipage-separator-segments` 之后：

- 取值：`(max 0 (- (seshat-reader--default-line-pixels) LINE))`，`LINE` = `--multipage-separator-segments` 的第二段（`nth 1`）。**厚度不复制读取逻辑**：`min THICKNESS TOTAL` 的 clamp 与「非数字按 0」都只在 segments 里实现一次，本函数只读结果 ⇒ 几何与补偿不会分叉。
- 边界：`separator` 关闭 / 总高 ≤ 0 / `thickness` 非数字或 ≤ 0（此时 `LINE` = 0，没有规则行）⇒ **0**；`frame-char-height` 读不到（`--default-line-pixels` 返回 nil 或抛错）⇒ **0**（`ignore-errors` + `numberp` 双保险，不把错误带进滚动算术）。
- docstring 写清了三件事（防回归）：① 为什么规则行恒为 `frame-char-height`（stretch space 不吃 face 相对高度）；② 补偿量 = `frame-char-height − thickness`，并附真机实测（10 名义 / 28 实际 / 18 偏差，25/35/17 → +25/+33/+15）；③ 为什么**不能**靠 face 的 `:height` 修、也不能缩短规则行（那是观感变更，已被用户排除）——布局是定点，算术跟随布局。
- `--multipage-page-gap-pixels` 改为三段相加（gap 行 + 名义分隔区 + 补偿），docstring 明确「answers with what the layout **measures**, not with what the customisation nominally asks for」；`--multipage-page-span` 的 docstring 补一句「gap 是实测值，含分隔区溢出，少算会让每次跨页少走一个字符行高」。

**回归用例（`emacs/tests/seshat-reader-multipage-test.el`，T13 小节，沿用 `--with-line-height` 同一套桩，未新造第二套）**

| # | 用例 | 断言要点 | 结果 |
|---|---|---|---|
| 1 | `--span-includes-separator-actual-height` | char-h 10 / thickness 2 / gap-lines 2：`extra` = 8、名义合计 25、实际 gap = 33（差恰为 8）、span = 533、`max-offset` = span−1，并**显式断言 `span ≠ 页高 + 名义合计`**（证明补偿生效，不是恒等式） | 通过 |
| 2 | `--span-unaffected-when-separator-off` | `page-separator` = nil，`gap-lines` 取 0/1/2：`extra` = 0、gap = `lines × 10`、span = 500 + gap（与补偿前逐值一致） | 通过 |
| 3 | `--span-extra-pixels-clamps` | ① thickness 40 > total 5 ⇒ segments `(0 5 0)`、extra = 5（规则行仍在）；② thickness 非数字 ⇒ segments `(2 0 3)`、extra = 0；③ total = 0 与 separator 关闭 ⇒ 0；④ 行高返回 nil / 抛错 ⇒ 0 且不抛错 | 通过 |

**同时按新语义更新 2 个既有用例**（补偿的直接后果，不是顺手改断言）：
`--separator-adds-to-the-gap-lines`（gap 25 → 33、span 525 → 533，并补 `separator-pixels` = 5 与 `extra` = 8 两条分项断言）、`--separator-on-cross-page-geometry`（span 505 → 513、max-offset 504 → 512、跨页余量 45 → 37、vscroll 断言 45 → 37，落点仍是第 3 页）。

**L1**：`make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**；elisp `Warning:` **20**（= 基线 20，零新增；中途曾因新 docstring 两个超 80 字符行与一个行首 `(` 报 21 与 checkdoc 1 条，均已修正）；`checkdoc` **0 诊断**；`check-parens`（`seshat-reader.el` + `seshat-reader-multipage-test.el`，verify 隔离实例）双双 `{"status":"ok"}`。

**L2**：`make -C emacs/tests ert` → **FILES=42 / TOTAL=1406 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**（四条判据行按预期，含 `Ran 0 tests` 假绿拦截）。基线 42 文件 / 1403 例 ⇒ **+3 例**，无新增文件；`seshat-reader-multipage-test.el` 单文件 100 → **103** 例、103 results as expected / 0 unexpected。

**独立 GUI 重测（修复后，口径与上一批完全一致）**

环境：`emacs -Q -l /tmp/t9b-measure.el`，GNU Emacs 32.0.50（pgtk）、`(frame-char-height)` = 20、`scale-factor` = 1.0、frame 130×60（body 1170×1160）、`base-scale` 0.35、五页驻留（`--multipage-render-page` 1..5）；`window-text-pixel-size` 显式放开 X/Y 上限；进程自行 `kill-emacs 0`，`timeout 240`。

| 指标 | 样本 | 修复前 | 修复后 |
|---|---|---|---|
| `--multipage-page-span` vs 实测 row→row | 矢量 letter（4 组） | +18 px/页 | **0 / 0 / 0 / 0** |
| 同上 | 真实扫描书（4 组） | +18 px/页 | **0 / 0 / 0 / 0** |
| 全文滚动范围 vs Σspan（5 页） | 矢量 letter | +90 px | **0**（Σspan 1525 = `window-text-pixel-size` 全文 1525） |
| 同上 | 真实扫描书 | +90 px | **0**（Σspan 1281 = 全文 1281） |
| 页高三态（渲染 / 占位 / 恢复） | 两样本各 1 页 | 0 px | **0 px**（277 / 277 / 277；243 / 243 / 243） |
| separator 关闭对照组 | 两样本 | 0 px | **0 px**（gap = 0、segments = nil、4 组 span 全等于实测） |

修复后 `gap-px` = **28**（名义 10 + 补偿 18），`segments` = `(4 2 4)`；关闭分隔区后 `gap-px` = 0、`extra` = 0。（`full-text-px` 与 `Σ(butlast spans) + 末页页高` 相差 28 px 属正常：末页之后也有分隔区，`Σspan` 全量口径才是主口径。）

**与任务书的两处偏差（诚实记录）**

1. **任务书的边界假设与实现不符**：任务书要求「`thickness ≥ total`（segments 为 nil）⇒ 补偿 0」。实测 `thickness ≥ total` 时 segments **不是 nil**，而是 `(0 TOTAL 0)`——规则行仍然渲染，实际高度仍是 `frame-char-height`，故补偿应为 `frame-char-height − TOTAL`（用例 3 ① 断言 5 而非 0）；若照抄任务书会给这类配置**少算** `TOTAL` 像素。反向的「`thickness` 非数字」任务书判断正确（`LINE` = 0 ⇒ 0）。实现按实际语义、用例按实际语义断言。
2. **首版实现返回 nil 而非 0**：`when` 无 else 分支使 extra 在「无分隔区」时返回 nil，`(+ … nil)` 直接抛 `wrong-type-argument`，第一轮单文件 ERT 13 例失败（多数是分隔区关闭的既有几何用例）。改为显式 `if` 返回 0 后全部转绿——已写进边界表与 docstring。

**改前 / 改后 md5 与安全点**

| 文件 | 改前 | 改后 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `daa2b119d486dd174567509ec736eaf6` | `a9db484476304a2774a66e6d3d1f2a2c` |
| `emacs/tests/seshat-reader-multipage-test.el` | `0b76cf2715e252d306d932f9b1c1bc5e` | `4aece9c27cd836878396c2dfa9166811` |
| `openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` | `bfdec3eb91c59e3743126be8e56c0b64` | `626aaf3a0e77b2069c1ffaefe6974df5`（追加本节后的最终值；本行在写入前计算，故不含自身回填） |

安全点 = `git stash create` → `cc4bb4ca9345bc02a8f21c2938b0a65728a843e1`（起点 `HEAD` = `d240b5616bfea3db42d7230904b5879d5fe27239`；工作区带 T8 的 4 项未提交改动，未 commit、未 stash 掉）。未提交、未 push。

**T9 checkbox 保持未勾**：主观 L3-①（连续快速滚动无卡顿 + B8 主观对比）、②（大页「先空白后瞬清」可接受）、③（缩放/切暗色不出旧代际像素）、⑤ 双窗口主观部分、⑥ 主实例重启后同口径复验，全部**必须在用户重启主实例后**才能观察（主实例启动 10:13:17 < `.so` 11:48:22）。

### T9 真机主观验收（用户 2026-10-29 回报）

**口径**：用户在**重启主实例之后**（故 `seshat-render-core.so` 与 elisp 改动均已载入）按「真实阅读」逐项主观判定，不用测量脚本。逐项原文结论：

| # | 主观项 | 结论 | 备注 |
|---|---|---|---|
| ① | 重启后阅读器正常 | **通过** | 无残留状态、无报错 |
| ② | fit-height 正常 / fit-width 的卡顿 | **通过（附注）** | fit-height 正常；fit-width 卡顿较长，但**比改造前变好** |
| ③ | 进入新页（跨页滚动） | **通过** | 正常、无跳变（P1 不变量①在异步路径下成立） |
| ④ | 缩放（`+`/`-`/`0`） | **通过（附注）** | 缩放后清晰；**连按缩放卡顿明显** |
| ⑤ | 切暗色 | **通过** | 无旧代际像素残留 |
| ⑥ | **双窗口各自滚动** | **不通过** | 另一窗口变成**背景色**（占位页无像素且不再恢复）；滚窗口 A 时 **B 跟着动，且位置随机** |

**⑥ 的根因归属（两项叠加，不是单一原因）**

| 层 | 事实 | 归属 |
|---|---|---|
| 布局模型（主因） | 单个 buffer 只有一份行驻留集与一份 buffer-local 布局状态；两个窗口视口不同 ⇒ 任一窗口的 `--multipage-sync` 都会回收「不在**本窗口**范围内」的行、并按本窗口重排 | **P1 布局模型缺陷**（与 P2-B 的异步机制无关）：窗口级视口 vs buffer 级布局的错配 |
| 本批 D8 违规（放大项） | 态 C（超时兜底）**整队清空** `--multipage-pending-renders`，而它只同步渲染**调用窗口**的可见范围 ⇒ 另一窗口登记的队项被丢掉，那些占位页失去唯一驱动源、**永远补不上像素**（= 用户看到的「跟背景色一样」且不恢复） | **D8 的第二个出口**，本批修掉（见下节） |

**处置**：① 本批修 D8 清空路径（只把本窗口已同步的页出队）；②「双窗口独立滚动 / 行驻留集按窗口 / 布局状态按窗口」属布局模型重构，**另立 P1 follow-up 计划**（T9 第⑥项转出，故 T9 checkbox 不勾）；③ ②④ 的「卡顿」属 `seshat-reader-render-idle-batch` 默认值（2）的取舍，见「T6 执行记录」末段的待用户确认建议，不在本批范围。

### T9 D8 清空路径修复（2026-10-29）

**一句话**：D8 说队列是 **buffer 级并集**，而态 C（超时兜底）是 **窗口级** 操作；修前它把整队清空，于是另一个窗口登记的队项被丢掉、那窗口的占位页永远没有驱动源。本批把它改成「只把本窗口这一轮同步渲染的页出队，其它窗口的队项保留，并给存活的队项重排两个 timer + 重启计时起点」；态 A 的整队清空语义不变。

**缺陷（修前）**

| 项 | 位置 / 事实 |
|---|---|
| 声明 | `seshat-reader--multipage-pending-renders` 的 docstring：「holds the union of what every window showing the buffer asked for (decision D8)」 |
| 第一个出口（T8 已修） | 裁剪口径按调用窗口的交集 —— `--multipage-prune-pending` 的实参（T8 改为 `--multipage-all-visible-pages`） |
| **第二个出口（本批）** | `--multipage-clear-async-state`（修前 `seshat-reader.el:2563`）调 `--multipage-pending-clear`（修前 `2571`）**整队清空** + `--cancel-async-render-timers` + 时间戳 nil |
| 调用点 | 态 C `--multipage-force-sync`（修前 `3122`，清空在 `3139`）；态 A `--multipage-sync`（修前 `3025` / `3030`） |
| 后果 | 态 C 只同步调用窗口的范围，却清掉其它窗口登记的队项 ⇒ 那些窗口的占位页**永远补不上像素**（用户真机 ⑥：双窗口时另一窗口「跟背景色一样」且不再恢复） |
| 为什么 T8 没覆盖 | 态 C 的清空路径**不经过** `--multipage-prune-pending`（后者只在态 B 调用），T8 的并集改造只覆盖了裁剪这一个出口 |

**顺序设计（先同步，再按同步前的 range 出队）**

| 判据 | 结论 |
|---|---|
| range 必须在**同步前**取 | `--multipage-sync-blocking` 会回收范围外的行、给范围内缺行的页建占位行 ⇒ 同步后布局已变，`--multipage-visible-range` 可能给出**不同**区间（同步后再取会把「已渲染」的集合算错） |
| 预取页为什么不该被出队 | blocking 末尾的 `--multipage-prefetch` 在开关为 t 时走**队列分支**：它把「驻留集外沿 ±1」的页登记进队列（本批新增的队项）。这页是**预取**、不是「已渲染」，若把它算进「本窗口已渲染」的出队集合，刚排上的预取页会当场被删掉 ⇒ 态 B/态 C 的预取收益归零 |
| 机械保证（预取页 ∉ 出队集合） | 预取页 = 驻留集外沿 ±1；blocking 结束时驻留集**恰等于**它的 range（范围内的行全在、范围外的行已回收）⇒ 预取页 = `first-1` 或 `last+1`，天然落在 `[first, last]` 之外 |
| 出队集合的实现取法 | 直接取 `--multipage-sync-blocking` 的**返回值**：它在函数入口（任何行被回收/插入之前）算一次 range 并原样返回 ⇒ 它就是「同步前的 range」。比另行调用 `--multipage-visible-range` 多两个正确性收益：① blocking 早退（range 为 nil / 重入守卫 / 窗口 buffer 不符）时返回 nil ⇒ **不出队**（否则会删掉根本没渲染的页）；② 返回的正是**实际被同步渲染**的区间，「已渲染」语义天然对齐 |
| 出队用什么 | 既有 `--multipage-pending-remove` 逐页出队（它自己处理「队空 ⇒ generation 与时间戳置 nil」），不新写清队逻辑 |
| 队非空时 | `(setq --multipage-async-pending-since (float-time))` + `--schedule-async-render`：**必须**重启计时起点 —— 否则存活队项继承「刚刚超时那一段」的年龄，下一条命令立刻再次判超时 ⇒ 每条命令都全量同步（异步路径被兜底网关死） |
| 队空时 | `--multipage-reset-async-state`（全清：队列 + 两个 timer + 时间戳），与修前态 C 的收尾一致 |

**改动点（`emacs/seshat-reader/seshat-reader.el`）**

| 位置（修后行号） | 改动 |
|---|---|
| `2565` | `--multipage-clear-async-state` **改名** `--multipage-reset-async-state`，语义收窄为「态 A 的全清」；docstring 写明「态 C 不得使用它：强制同步是窗口级操作、队列是 buffer 级资源（D8）」并指向新函数 |
| `2586` | **新增** `--multipage-clear-synced-pending (range)`：按 range 逐页 `--multipage-pending-remove` → 队非空则重置时间戳 + `--schedule-async-render`（两个 timer 重排）→ 队空则 `--multipage-reset-async-state`；返回剩余队列。docstring 写清「为什么态 A 全清 / 态 C 只出本窗口 / 并集队列下强制同步是窗口级操作、队列是 buffer 级资源」 |
| `3184`（`--multipage-force-sync`） | 改为 `let*` 绑 `last-range` = nil 拿 blocking 返回值 → `--multipage-clear-synced-pending`（调用在 `3213`）→ 返回该 range；删掉原 `prog1` 里的 `--multipage-note-pending-since`（计时起点改由新函数按队空/非空显式处理） |
| `3087` / `3092`（态 A） | 两处调用改名 `--multipage-reset-async-state`，**语义与顺序不变**（先清再 blocking、跑完再清一次兜底） |
| docstring 同步 | `--multipage-sync` 的态 C 描述（「整队清空」→「只出本窗口的页，其余保留并重排 timer」）；`--multipage-note-pending-since` 的调用方清单（删掉「forced synchronous pass」，指向新函数）；`--multipage-async-pending-since` 的 defvar 说明（新增「forced pass 在队项存活时重启它」） |
| **未改** | 4 个 defcustom 默认值；`--multipage-sync-blocking` 函数体（一行未动，`while (<= page last)` / `--multipage-recycle-page` / `--multipage-prefetch win` 三处仍在 `3027`/`3033`/`3035`）；`render/*`；`--multipage-async-overdue-p` 的判定模型（单一 buffer 时间戳的粗粒度近似照旧） |

**新增 3 例（`emacs/tests/seshat-reader-multipage-sync-async-test.el`，15 → 18 例）**

| # | 用例 | 断言要点 | 结果 |
|---|---|---|---|
| 1 | `--state-c-keeps-other-windows-pending` | 双窗口 A 视口 (4 . 5) ⇒ 范围 (3 . 6)、B 视口 (5 . 6) ⇒ 范围 (4 . 7)；队列预置 8（**B 的、A 范围外、且不是 A 的预取页 7**）、3、5；时钟 1000.0 → 1001.5 超时 ⇒ A 走态 C。断言：渲染页序 `(3 4 5 6)`；**8 仍在队列**；3/4/5/6 **全部出队**；队列 = `(8 7)`（7 = 本轮同步预取新增）；两个 timer 非 nil；时间戳 = 1001.5（重置，不是旧的 1000.0）。**变异测试**：把 `--multipage-force-sync` 改回「blocking 前整队清空」⇒ 本用例失败（同轮其余 3 个 state-c 用例仍绿），随后已恢复源码并重编译 | 通过 |
| 2 | `--state-c-clears-queue-when-empty` | pagecount 6（预取页被裁剪回驻留集内 ⇒ 不登记）、范围 (3 . 6)、队列只有本窗口的 3/5，且先真的排一次 timer；态 C 之后：队列空、generation nil、时间戳 nil、两个 timer 变量 nil、`cancel-timer` 被调 ≥ 2 次（**防回归**：保队不能变成「队列永不清空」） | 通过 |
| 3 | `--state-a-still-clears-everything` | 双窗口同夹具、队列 7（B 的范围 4..7 内）+ 3（A 的）、`render-async` = nil ⇒ 态 A 走一轮后**队列整体清空**、时间戳 nil、两个 timer 变量 nil（**态 A 语义不变**，不许被顺手改成「按范围出队」） | 通过 |

**夹具改动（1 处扩展，未新造第二套）**：`seshat-reader-sync-async-test--viewports`（alist `WINDOW . (FIRST . LAST)`）+ `--viewport-for`；stub 查不到该窗口时**回落**到既有的 `--viewport` ⇒ 既有 15 例零改动。形态与 T8 的 `seshat-reader-multipage-async-test--viewports` 一致，但不跨文件 `require`（`emacs/tests/Makefile` 每个文件各起一个 Emacs 进程，跨文件 require 会把另一个文件的用例算进本文件的 `Ran N tests`）。

**L1 / L2（实测）**

- L1 `make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**；elisp 字节编译 `Warning:` **20**（= 基线 20，**零新增**；新增/改写的 docstring 无超 80 列告警）；`checkdoc` **0 诊断**；`check-parens` 2 个改动 `.el` 在 `verify` 隔离实例内双双 `{"status":"ok"}`。
- L2 `make -C emacs/tests ert` → **FILES=42 / TOTAL=1409 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**。基线 42 / 1406 ⇒ **+3 例**，无新增文件；`seshat-reader-multipage-sync-async-test.el` 单文件 15 → **18** 例。
- 旧 `.elc` 陷阱：改 `.el` 后必须先 `make -C emacs/seshat-reader all` 再跑 ERT（本批按此顺序，未复发）。

**elisp-mcp 三实例流程（实测痕迹）**

| 步骤 | 结果 |
|---|---|
| `elisp_mcp_set_task(verify)` | `{"status":"ok","task":"verify",...}` |
| `elisp_mcp_instance(verify, start)` | `{"status":"started",...}` |
| `elisp_mcp_instance_status(verify)` | `socket-exists:true, alive:true`（首个轮询即就绪） |
| 实例内 `elisp_check_parens` × 2 文件 | 均 `{"status":"ok"}` |
| 收尾 | `set_task(auto)` → `instance(verify, stop)` → `instance_status` 确认 `task:"auto"`、`alive:false`、`socket-exists:false`、`task-ttl-seconds:"auto（无 task 文件）"` |

**与任务书的偏差（诚实记录）**

1. **出队集合取 `--multipage-sync-blocking` 的返回值，而不是另行调用 `--multipage-visible-range window`**（任务书写「态 C 的 range 必须取同步前的 `--multipage-visible-range window`」）。两者在正常路径下是**同一区间**（blocking 在入口算一次并原样返回）；用返回值额外覆盖两种情况：blocking 早退 ⇒ 返回 nil ⇒ 不出队；以及「返回的就是实际渲染的区间」。语义仍是「同步前的 range」，理由写进了两个函数的 docstring。
2. **态 C 不再调 `--multipage-note-pending-since`**：该函数的语义是「队空清 nil / 队非空且无时间戳才补」，而态 C 需要的是**无条件重启**（存活队项必须拿到完整的新窗口）。改为在 `--multipage-clear-synced-pending` 里按队空/非空显式处理，`note-pending-since` 只剩态 B 一个调用点（其 docstring 已同步）。
3. **`--multipage-clear-async-state` 改名 `--multipage-reset-async-state`**（任务书给了「拆两个函数或加参数」两条路，选前者）：`reset` = 全部三件状态一起走，`clear-synced-pending` = 窗口级出队 + 按需保留。仓库内该函数无测试直接引用（`grep` 空），改名零影响。
4. **渲染失败的页仍在出队集合里**（`--multipage-render-page` 返回 nil ⇒ 落占位行，但页已在本窗口范围内）—— 与态 B「同步渲染完立刻出队」同口径，属既有语义：这类页要等它下次重新进入可见范围才重试。本批不改。
5. **未做**：未动 `render-idle-batch` 默认值（②④的卡顿取舍留用户）；未做「双窗口独立滚动」（P1 follow-up）；未 commit / 未 push；未动 CHANGELOG / docs（T7 / T10 的活）。

**发现但未处理的风险（留 follow-up）**：若某个显示本 buffer 的窗口长期不可见（被 bury 到不可见 frame、或被其它窗口完全遮挡），它的页仍会留在并集口径里 ⇒ `--multipage-prune-pending` 不会裁掉它，队列可能长期非空 ⇒ 每条命令都可能因「超时」走强制同步（**性能退化，不会渲染错**）。建议 follow-up 二选一：① 并集口径纳入窗口/ frame 可见性（`window-visible-p` + `frame-visible-p`）；② 给队项加登记时间戳、按龄淘汰。本批按任务书要求**不自行加新机制**。

**改前 / 改后 md5 与安全点**

| 文件 | 改前 | 改后 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `a9db484476304a2774a66e6d3d1f2a2c` | `bbb9dedcf4b265f94eaabe2398b30487`（含一次 docstring 重复行修正；`b24e7a8550c7f7b46fa7741ce11f679b` 是修正前的中间值） |
| `emacs/tests/seshat-reader-multipage-sync-async-test.el` | `f89dae6cc60e44aea78cbf964699f764` | `54505853d3b529da991a9f4332cfd46f` |
| `openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` | `5ccb4999df9c2280f3a6025a34ecb6ad` | 追加本节后的值（本行在写入前计算，故不含自身回填） |

安全点 = 起点 `HEAD` = `d240b5616bfea3db42d7230904b5879d5fe27239`（工作区带 T8/T9 的未提交改动，**未 commit、未 stash**）；回滚口径 = `git checkout -- <两个 .el>`（本批未触发回滚）。

### 代码审查与修复（2026-10-29）

**一句话**：code-reviewer 对 P2-B 提了 3 项 + 1 个 nit，本批全部处置 —— ①（major）`--multipage-all-visible-pages` 用无参 `(window-list)` ⇒ 只遍历选中 frame，D8 的**跨 frame** 缺口；②（minor）`render-async-timeout` 的 docstring 还停在 T9 之前的语义；③（minor）`--multipage-clear-synced-pending` 的 nil RANGE docstring 与代码不一致；④（nit）`--multipage-force-sync` 的 `let*` 遮蔽缺注释。**只改 1 个实现文件 + 1 个测试文件 + 本计划**；可观察行为零变化（①补全并集口径、②③是注释与早退口径、④纯注释）。

**① major — 跨 frame 缺口（`--multipage-all-visible-pages`）**

| 项 | 内容 |
|---|---|
| 修前 | 窗口集合 = `(delq nil (cons WINDOW (mapcar … (window-list))))` —— `(window-list)` **无参**只答**选中 frame** 的窗口，docstring 却写「walks every frame」（错的），并以此解释「为什么显式并入 WINDOW」 |
| 后果 | 同一 buffer 显示在**另一个 frame** 时，那个 frame 的窗口不进并集 ⇒ `--multipage-prune-pending` 把它的队项裁掉 ⇒ 它的占位页永远没有驱动源（T9 用户 ⑥ 的「另一窗口跟背景色一样」在跨 frame 场景重现） |
| 修法 | `(frame-list)` → 每个 frame 用 `(frame-live-p)` 过滤（对已死 frame 调 `window-list` 会 signal）→ `(window-list FRAME)` → 只留 `(windowp W)` 且 `(eq (window-buffer W) (current-buffer))` 的窗口；再把 WINDOW 参数显式并入（`windowp` + `window-live-p` 双检查，nil / 已死窗口跳过） |
| 保留的既有语义 | range 为 nil 的窗口跳过、结果 `delete-dups` + 升序、全空返回 nil —— 三条逐条不变 |
| minibuffer-only frame | `window-list` 对它返回 nil（minibuffer 窗口默认不计入），自然跳过，不需要特判 |
| docstring | 重写为「`frame-list` → `window-list FRAME` → 过滤」，并**显式写明为什么不能用无参 `(window-list)`**（只答选中 frame ⇒ 另一 frame 的队项被裁 ⇒ 占位页永久空白），防后人改回 |

**① 的桩用例（做了，纯函数级）**

`seshat-reader-multipage-async-test--all-visible-pages-walks-every-frame`（`emacs/tests/seshat-reader-multipage-async-render-test.el`，18 → 19 例）：

- 桩的对象是 `frame-list` / `frame-live-p` / `window-list` 三个函数；**窗口是真的**（`split-window` 造），`window-buffer` 也走真函数 ⇒「显示本 buffer」这条过滤不是桩，桩不掩盖它。
- `frame-list` 答 `(frame-a frame-dead frame-b)`；`window-list` **按 frame** 答窗口，且**无参调用只答 frame-a 的窗口** —— 那正是旧实现会拿到的结果，所以这是**差分**用例而不是恒真断言。
- 四条断言：并集 `(2 3 4 5 6 7 8)`（frame-b 的窗口贡献 6/7/8）、`frame-b` 进过 `window-list`、`frame-dead` 没进过（被 `frame-live-p` 挡在调用之前）、**一次无参调用都没有**。
- **变异测试**（证明非空断言）：把 `(window-list frame)` 改回 `(window-list)`、增量重编译、单文件跑该用例 ⇒ **FAILED**，实测 `(equal (2 3 4 5 6 7 8) (2 3 4 5))`；随后从备份恢复源码（md5 回到 `e2abda85…`）并重编译，19 例全绿。

**② minor — `seshat-reader-render-async-timeout` 的 docstring（与 T9 后的实现逐句对齐）**

- 「renders the visible range of **its own window** synchronously and drops exactly the pages that pass covered from the queue」—— 不再是「renders the whole visible range … empties the queue」。
- 「What survives … is kept, gets the pending clock restarted and both timers re-armed, so it owns a full timeout window of its own」，并写明不重启的后果（幸存队项仍显超时 ⇒ 下一条命令再次强制同步 ⇒ 兜底网关死异步路径）。
- 「Only a queue that is empty after the drop takes the whole asynchronous state with it (queue, both timers and the timestamp)」。
- 新增一段：「队列是 buffer 级、强制同步是窗口级（D8）⇒ 强制同步永不整队清空」。
- 计时起点措辞改为「measured from the moment it first became non-empty, **or from the last forced pass that left entries behind**」（态 C 对幸存队项无条件重启）。

**③ minor — `--multipage-clear-synced-pending` 的 nil RANGE：选「nil 时提前返回、队列原样」**

- 实现：「出队 + 时间戳/timer 处置」整体收进 `(when (consp range) …)`，函数末尾照旧返回队列；nil 时**不重置时间戳、不重排 timer、不动队列**。
- 理由：① 与 docstring 原本的声明一致（「queue is left exactly as it is」），改代码比改文档风险低；② 语义最干净 —— nil 表示「这一轮什么都没渲染」，没有可丢的页，给一个什么都没做的 pass 重排 timer 只会掩盖「队列排不空」这个信号；③ 无实害 —— 唯一调用方 `--multipage-force-sync` 的 `synced` 来自 `--multipage-sync-blocking`，而 `--multipage-sync` 在派发态 C **之前**已 `(null range) ⇒ nil` 早退，故态 C 的 range 恒非 nil（理论上 blocking 因重入守卫返回 nil 时也只是「不重启计时」，不会渲染错）。
- docstring 同步补一句：nil 时「returns at once: the queue, the pending clock and both timers are left exactly as they are」。

**④ nit — `--multipage-force-sync` 的 `let*` 遮蔽：选「加注释」而非「先 setq nil」**

- 选注释，理由：`let*` 绑定**可证明零行为变化**；改成「先 setq nil 再调用」会让 blocking 内部的 `setq --multipage-last-range RANGE` 落到 buffer-local 上并**持久化**，于是强制同步之后的 `--multipage-sync` 会因「区间未变」早退 —— 这是可观察的行为变化（任务书要求「不要改变可观察行为」）。
- 注释内容：绑定只作用于本次调用（目的是让 blocking 绕过「区间未变即早退」）；blocking 内部的 `setq` 写的是 let 绑定、退出即丢弃，**不打算持久化**；并写明改成 setq 的后果，防后人「顺手修正」。

**L1（实测）**

- `make -C emacs/seshat-reader clean all` → **EXIT 0**；C **0 error / 0 warning**（`grep -E "warning:|error:"` 无命中）；elisp 字节编译 `Warning:` **20**（= 基线 20，零新增；新增 docstring 无超 80 列告警）；`checkdoc` **0 诊断**；`check-parens` 2 个改动 `.el` 在 `verify` 隔离实例内双双 `{"status":"ok"}`。
- 恢复源码后的增量 `make all`：EXIT 0、该文件 17 条既有 warning（清空构建的 20 含其它文件）。

**L2（实测）**

- `make -C emacs/tests ert` → **FILES=43 / TOTAL=1433 / UNEXPECTED=0**，EXIT 0；`make -C emacs/tests check-criteria` → **PASS**（四条判据行按预期，含 `Ran 0 tests` 假绿拦截）。
- 数字构成（**并发会话**在同一工作区写文件，必须逐项交代）：T9 基线 42 / 1409 **+ 本批 1 例**（async-render-test 18 → **19**）= 42 / 1410；实跑 43 / 1433 的差额 = 并发会话新增的 `emacs/tests/seshat-log-test.el`（12 例，`??` 未跟踪）+ `seshat-state-test.el` 新增 11 例（`git diff` 数 `+.*(ert-deftest` = 11）⇒ 1410 + 12 + 11 = 1433，FILES 42 + 1 = 43，逐项对得上。
- 本批相关文件的单文件数：`seshat-reader-multipage-async-render-test.el` **19 / 19**、`seshat-reader-multipage-sync-async-test.el` **18 / 18**（均 0 unexpected）。

**elisp-mcp 三实例流程（实测痕迹）**

| 步骤 | 结果 |
|---|---|
| `elisp_mcp_set_task(verify)` | `{"status":"ok","task":"verify","ttl":"30 分钟后自动回落到 auto"}` |
| `elisp_mcp_instance(verify, start)` | `{"status":"started","daemon":"elisp-test",...}` |
| `elisp_mcp_instance_status(verify)` | `socket-exists:true, alive:true, task:"verify", task-ttl-seconds:1788` |
| 实例内 `elisp_check_parens` × 2 文件 | 均 `{"status":"ok"}` |
| 收尾 | `set_task(auto)` → `instance(verify, stop)` → `instance_status` 确认 `task:"auto"`、`alive:false`、`socket-exists:false` |

（flymake 与实例内 `load-file` 的既有结论同 T8：该实例无 flymake 后端、`load-file` 被 MCP 黑名单拦，本批不重复尝试；语法与定义层由 `make all`（字节编译 + checkdoc）+ `check-parens` 承担。）

**与任务书的偏差 / 未做项（诚实记录）**

1. **① 的桩用例做了**（任务书给了「低成本能造就做」的裁量）：三个函数桩 + 真窗口，「差分性」由「无参调用只答 frame-a」这条桩行为保证，并用变异测试证明它不是空断言。
2. **③ 选了「nil 提前返回」**（任务书推荐项），理由见上；未改任何调用点。
3. **④ 选了「加注释」**（任务书两选项之一），理由是 setq 方案会改变 `last-range` 的可观察状态。
4. **未做**：跨 frame 的真机验收（需 GUI 两个 frame + 主实例重启，属 T9 主观项）；`get-buffer-window-list` 与 `frame-list` 两条路的性能对比（无测量需求）；未 commit / 未 push。
5. **未碰并发会话的文件**：`openspec/decisions.md`、`docs/adr/0006-offline-first-library.md`、`openspec/active/2026-10-29-emacs-offline-library.md`、`emacs/seshat-log.el`、`emacs/tests/seshat-log-test.el`、`emacs/seshat-reads.el`、`emacs/tests/seshat-reads-test.el`、`emacs/seshat-state.el`、`emacs/tests/seshat-state-test.el`、`emacs/seshat-reading.el` 一律未读改；本记录只在本计划文件内追加。

**改前 / 改后 md5 与安全点**

| 文件 | 改前 | 改后 |
|---|---|---|
| `emacs/seshat-reader/seshat-reader.el` | `bbb9dedcf4b265f94eaabe2398b30487` | `e2abda852f3a8a0885c3731e3dd26b74` |
| `emacs/tests/seshat-reader-multipage-async-render-test.el` | `086a30046be98bd5af5bc442048f091b` | `00db3636f47ce63e17c1e2bf478289a5` |
| `emacs/tests/seshat-reader-multipage-sync-async-test.el` | `54505853d3b529da991a9f4332cfd46f` | 未改（同值） |
| `openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` | `1793bf78c57fc33ff07432ed4cafb177` | 追加本节后的值（本行在写入前计算，故不含自身回填） |

安全点 = `git stash create` → `d86525c6261d80da66edd04b96fc8a63848583e7`（起点 `HEAD` = `d240b5616bfea3db42d7230904b5879d5fe27239`；工作区带 T8/T9 与并发会话的未提交改动，**未 commit、未 stash 掉**）。本批未触发回滚。
