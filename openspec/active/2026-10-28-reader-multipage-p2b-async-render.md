# 阅读器多页布局 P2-B：两阶段渲染（尺寸先行 + idle 补位）

## 当前状态
- 阶段：Phase 2（Plan）· 计划待独立审查与用户确认
- 已确认：方案 ✅（用户 2026-10-28 确认，范围 = 两阶段渲染 + idle 补位 + 批次 0 spike）
- 前置：P1 已归档（`openspec/completed/2026-10-26-reader-multipage-p1-layout.md`）、P2-A 已归档（`openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`）、canvas 后端迁移已提交（`3265652` 代码 + `7e76d15` 文档）
- 下一步：plan-reviewer 审查 → 用户确认计划 → Phase 3 批次 0 spike

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
| F5 | 页面承载 = 每页一行文本 + `display` 文本属性（`align-to` + image spec），页表 `seshat-reader--pages`（`(PAGE MARKER . SPEC)`） | `1247-1267`、`1313-1330`、`1477-1534` |
| F6 | 未渲染页已是既成占位态（`"  \n"`、无 `display` 属性），但页高按 0 参与滚动（span 下限 1） | `1247-1267`、`2010-2016`、`2093-2100` |
| F7 | 缓存键只有 `(PAGE SCALE ROTATE)`，**无代际号**；清缓存挂点 4 处 | `996-1007`、`2446`/`3294`/`3375`/`3874` |
| F8 | 预取**已实现但同步**，只暖滚动方向 1 页，方向变量 `--multipage-scroll-direction` | `1838-1866`、`1232`/`2310` |
| F9 | 已有 4 套可复用的防重入/去抖：`--multipage-syncing` / `--multipage-last-range` / `--refitting` / `--drag-threshold` + `--schedule-refit` 范式 | `1632`、`1641`、`144`、`164`/`170`、`2780-2790` |
| F10 | idle timer 在 daemon 下**从未验证**；且 `sit-for` 期间不算 idle（必须真实空闲） | `openspec/tech-debt.md:1131-1137` |
| F11 | 主线程硬约束：`create-image` / `env->canvas_data` / `canvas-refresh` 都在 `emacs_env` 生命周期内 | `render/elisp-helpers.c:203`、`238`、`255-270` |
| F12 | 渲染返回 nil 时**不报错不重试**，直接落占位行 | `seshat-reader.el:1707-1717`、`1316-1321` |

**关键拆解**：布局真正需要的只有**页高**，它来自页面 bounds（MediaBox/CropBox × scale × rotate），与栅格化无关。因此「异步」不必等于「后台线程」，可拆为「尺寸先行（同步、微秒级）+ 像素后补（idle）」。

**假设（待批次 0 验证）**

| # | 假设 | 来源 | 验证 |
|---|---|---|---|
| A1 | `fz_bound_page` 级别的页尺寸查询是微秒级、不发像素 | 假设? | S4（并入 T1 验收） |
| A2 | `(space :width W :height H)` 占位与同尺寸 canvas image 的**行像素高相等** | 假设? | S2 |
| A3 | 用户可感卡顿阈值 ≈ 单页 >10 ms | 类比⚡（60 Hz 帧预算） | S1 分布 + 真机 B8 主观 |
| A4 | 视口外页的 idle 补位不会被用户看见空白页 | 假设? | 设计约束（视口内同步）+ L3 |
| A5 | daemon 下 idle timer 可用 | 假设? | S3 |

## 设计决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | **两阶段渲染**：同步只查页尺寸，像素交 idle | F11 + 非目标第 1 条：线程池代价不成比例；页高与像素解耦是结构性事实 |
| D2 | **页高来源改为 bounds**（`fz_bound_page`），不再等像素渲染 | 唯一能让「占位」与「已渲染」两态页高一致的来源 |
| D3 | **占位形态优先 `(space :width W :height H)`**；若 S2 判定高度不等，退「1×1 占位 canvas image + `:width`/`:height`」 | space 无像素成本；备选保留同一位置语义 |
| D4 | **代际作废**：`seshat-reader--multipage-render-generation` 整数，统一在 `--multipage-forget-specs` 内自增；缓存写入与 idle 回调均比对代际 | F7：缓存键无代际，快速缩放/切暗色/relayout 后必须能丢弃在途结果 |
| D5 | **视口内同步 + 超时兜底**：point 所在页与滚动方向第一页始终同步；pending 超 `--render-async-timeout` 未清空则下一次 `post-command-hook` 强制同步 | F10/A5：idle 可靠性未知，必须有两条独立保险，且不能出现「用户长时间看空白页」 |
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
| **G1** | S1 的 p95 < 5 ms **且** max < 20 ms | 触发**降级方案 B**：取消 T2/T3（不做两阶段），只做 T4/T5/T8（idle 预取）；计划在本文件「## 验证记录」注明裁剪理由 |
| **G2** | S2 高度不等（差 ≥1 px） | T3 走备选（1×1 占位 canvas image）；若备选仍不等 ⇒ 停止，回到方案讨论，不硬推 |
| **G3** | S3 未触发 | `--render-async-timeout` 默认降到 0.2 s，并在决策日志记「idle 不可作为主链路依赖」；D5 的两条保险升级为三条（再加 `run-at-time` 兜底 timer） |

## 任务

- [ ] **T0 批次 0 spike 与判定**：按上表执行 S1 / S2 / S3（S4 随 T1），把数值与 Gate 判定写入本文件「## 验证记录 · 批次 0」。验收：S1 有 p50/p95/max + 分桶表；S2 有 px 差值；S3 有触发结论；G1–G3 逐条给出「触发/未触发 + 采纳的动作」。（依赖：无）
- [ ] **T1 C 侧 `--page-size` 入口**：新增 `seshat-reader-dyn--page-size`（arity 2..3：page 1-based、scale、可选 rotate），内部用 `fz_bound_page` + 与渲染同口径的 rotate/scale 换算，返回 `(W H)` 逻辑像素（含设备像素尺寸可选返回）；**零副作用**（不建 display list、不分配像素、不进 DocState 缓存）。验收：`make all` 0 error 0 warning；`nm` 入口数 14 → 15；真实 PDF 上单次耗时中位（A1 判定）；对 `9999` 页与 `0` 页返回 nil 不崩。（依赖：T0）
- [ ] **T2 elisp 页尺寸层**：`seshat-reader--page-size`（C 入口的包装 + `ignore-errors` + 无模块时返回 nil）；buffer-local 尺寸缓存（键 `(PAGE SCALE ROTATE)`，容量沿用 `--multipage-cache-limit`）；页表 `seshat-reader--pages` 增加「有尺寸、无 spec」态的表达（spec 占位为 `:size-only` 标记，或新增平行 alist —— 二选一，实现时选侵入面小的那个并在「## 执行记录」说明）。验收：批次 T2 的 ERT 覆盖「查尺寸不触发渲染」（用计数桩断言 C 渲染入口调用 0 次）。（依赖：T1）
- [ ] **T3 占位行与布局稳定性**：`--multipage-page-row` 增加「已定尺寸未渲染」分支（按 G2 结论选 `space` 或 1×1 占位 image），保证页高与已渲染态一致；`--multipage-insert-page` / `--multipage-resize-spec` 对占位态的处理；渲染完成「补位」时**不得移动任何页 marker**（只改 `display` 属性）。验收：ERT 断言「占位态页高 == 已渲染态页高」「补位前后页 marker 位置不变」；真机 L3-①（无跳变）。（依赖：T2、G2）
- [ ] **T4 代际作废**：`seshat-reader--multipage-render-generation`（buffer-local 整数），在 `--multipage-forget-specs` 内自增；`--page-spec-remember` 与 idle 回调入口比对代际，不匹配则丢弃（回调不写缓存、不补位）。验收：ERT 断言「先登记 pending → 清缓存 → 触发 idle 回调 ⇒ 缓存无新条目、行仍是占位」。（依赖：无，可与 T1 并行）
- [ ] **T5 idle 调度器（替换同步预取）**：`--schedule-async-render`（复用 `--schedule-refit` 的「cancel + 单 timer + buffer 入参」范式）；pending 集合按代际与可见范围整理，每轮最多渲染 `seshat-reader-render-idle-batch`（默认 2）页；渲染后补位并继续自续直到 pending 空或代际变化；`--multipage-prefetch` 改为向 pending 登记（不再同步取 spec）。验收：ERT（桩 `run-with-idle-timer` 捕获回调手动执行）覆盖「登记→补位→pending 清空」「代际变化后不补位」「每轮上限生效」。（依赖：T3、T4）
- [ ] **T6 `--multipage-sync` 改造**：视口内「point 所在页 + 滚动方向第一页」同步渲染（保持现状手感），其余可见页登记 pending；超时兜底（`--render-async-timeout`，默认 1.0 s，G3 触发则 0.2 s 并加 `run-at-time` 兜底）；`seshat-reader-render-async` 为 nil 时走旧路径（逐页同步 + 同步预取）。验收：ERT 覆盖三态（默认异步 / 超时强制同步 / 开关关闭等价旧行为）；真机 L3。（依赖：T5、T7）
- [ ] **T7 四个 defcustom**：`seshat-reader-render-async`（boolean，默认 t，nil 即旧行为）、`seshat-reader-render-idle-delay`（秒，默认 0.05）、`seshat-reader-render-async-timeout`（秒，默认 1.0）、`seshat-reader-render-idle-batch`（整数，默认 2）——共 **4 个**，均含 docstring 与 `:type`/`:group`；`docs/configuration.md` 同步。验收：`M-x customize-option` 可见；编译 warning 不新增。（依赖：无）
- [ ] **T8 测试补齐与等价性**：新增/改造用例覆盖 D1–D8；特别包含「`seshat-reader-render-async=nil` 时与旧路径行为等价（同一 PDF 同一页的 spec 几何一致、marker 一致）」与「双窗口 pending 并集」。验收：`make -C emacs/tests ert` 0 unexpected 0 skipped；`check-criteria` PASS。（依赖：T6）
- [ ] **T9 L1/L2 全量 + 真机 L3**：L1 `make -C emacs/seshat-reader clean all`（EXIT 0、C 0/0、elisp warning ≤ 20、checkdoc 0）；L2 全量 ERT + `check-criteria`；L3 真机：① 连续快速滚动无卡顿（且 B8 主观对比批次前后）；② 大页首次进入「先空白后瞬清」可接受；③ 缩放/切暗色期间不出现旧代际像素；④ daemon + `emacsclient -c` 真实空闲后 pending 清空；⑤ 双窗口各自滚动正常。**C 模块重编译后必须重启 Emacs**。（依赖：T8）
- [ ] **T10 文档沉淀与归档**：按「## 文档清单」逐项更新；计划移入 `openspec/completed/`；`openspec/tech-debt.md` 勾销 P2-1（异步渲染未做）；roadmap 更新 P2 池状态（P2-1 完成、P2-7 因 `--page-size` 落地只剩判定）。（依赖：T9）

## 文档清单

`docs/architecture.md`（两阶段渲染 + 代际作废 + 与 canvas 后端的关系）、`docs/emacs-reader.md`（异步行为、可能出现的「空白→清晰」过渡、降级条件）、`docs/configuration.md`（4 个新 defcustom）、`emacs/seshat-reader/VENDORED.md`（新增 `--page-size` 入口、入口数 14→15）、`CHANGELOG.md`、`openspec/decisions.md`（D1 两阶段 vs 线程池的取舍、D5 兜底策略）、`openspec/tech-debt.md`（勾销 P2-1；若 S3 未触发则新增「daemon idle 不可依赖」条目）、`openspec/roadmap.md`、`README.md`/`Readme.org`（若用户可见默认值变化）。

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` → EXIT 0；C **0 error 0 warning**；elisp 字节编译 warning **≤ 20**（当前基线 20，零新增）；checkdoc 0；`check-parens` 通过。
- **L2**：`make -C emacs/tests ert` → **0 unexpected 且 0 skipped**（判据走 `emacs/tests/ert-judge.sh`；当前基线 37 文件 / 1328 例）；`make -C emacs/tests check-criteria` PASS。
- **L3（真机必须）**：见 T9 五项；凡涉及几何/滚动/坐标一律真机，batch 无真实 redisplay。
- **不变量（可机械检查）**：① 占位态与已渲染态页高一致；② 补位不改任何页 marker 位置；③ `render-async` = nil 时与基线逐页 spec 几何一致；④ 无模块/渲染失败时落占位态、不抛错、不死循环。
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

**回滚**：每批开始前建 git 安全点（`git stash create` 或临时分支）；单批失败且修复循环（L1 ≤3 轮、L2/L3 ≤2 轮）耗尽 ⇒ 回滚该批并报告本 agent，不跨批回滚。`seshat-reader-render-async` = nil 是运行时回滚口。

## 注意事项

1. **不得改 `:data-width`/`:data-height` 只写一次的语义**，也不得跨调用缓存 `canvas_data`。
2. **视口内必须同步**：任何情况下「point 所在页」不能是空白占位。
3. **pending 必须有上限**：只保留当前可见范围（± preload）的页，超出即丢弃。
4. **C 改动后重启 Emacs**；`make clean all` 后再跑 ERT（`.d` 依赖已接入，注意 `-MMD` 生效）。
5. **测试桩范式**：idle 行为在 batch 下靠「桩 `run-with-idle-timer` 捕获回调 → 手动 funcall」，仓库已有两处先例（`seshat-reader-fit-window-test.el:355-420`、`seshat-reader-select-flash-test.el:57-77`），不要真等 timer。
6. **不要与 P2-3（横向滚动）/ P2-7（渲染基准）并批**：本项只动「何时渲染」，不动「渲染多大」。
7. 工作区可能有并发会话：改文件前后 `md5sum` 取证（历史教训）。

## 验证记录

（执行期间逐批追加：批次 / 日期 / L1 数字 / L2 例数 / S1–S4 数值 / Gate 判定 / L3 结果 / 备注。初始为空。）
