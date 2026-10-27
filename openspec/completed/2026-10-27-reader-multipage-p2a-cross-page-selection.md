# 阅读器多页布局 P2-A：跨页选区 + 旋转页坐标

## 当前状态

- 阶段：Phase 4 完成 · 已归档
- 已确认：方案 ✅ / 计划 ✅ / 代码审查 ✅（有条件通过，4 项已修）/ T9 真机 ⚠️ 部分（崩溃修复生效，细项待观察）——方案细节：用户 2026-10-27 确认本轮范围 = 批次 A；跨页 location 用 `pages:` 新前缀形态；Android 本轮不改；P2-3 留批次 C；计划确认时要求「不得改坏现有功能」
- 前置：P1 已归档（`openspec/completed/2026-10-26-reader-multipage-p1-layout.md`）；候选池 `openspec/active/2026-10-27-reader-multipage-p2-followups.md`
- 审查：plan-reviewer 共 3 轮——第 1 轮**不通过**（3 major / 5 minor）、第 2 轮**不通过**（1 新 major：D5b 读写端不一致）、第 3 轮**通过（附建议）**（2 minor 已当场修订：D1 与 D5b 措辞统一、降级信号明确）
- 下一步：—（计划已归档到 `openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`；未逐项确认的 T9 细项转「使用中观察」，残余项已在 `openspec/tech-debt.md` 有覆盖）

## 目标

1. **P2-2 跨页选区**：拖选跨页时不再 `user-error`，按页分组取文与矩形，批注以新 location 形态写入，高亮在两页都正确。
2. **P2-8 旋转页坐标**：选区坐标感知 `seshat-reader--multipage-rotate`，旋转页框选不再错位。
3. **协议向后兼容**：旧形态 `page:<n>;rect:…` 的读写语义零变化；新形态对旧 Emacs 客户端**整条跳过**（不得画错）、对 Android 落到 `Parsed.Unknown`（不崩溃）。
4. **C 侧零改动**（批次 A 内）。

## 事实基线（已核实，执行时可直接引用）

| # | 事实 | 出处 |
|---|---|---|
| F1 | `seshat-reader-select-last` 是 plist（`:text :page :rect :rects :file`），**唯一写入点** `seshat-reader-select-extract`；`:rects` 元素不带页号 | `emacs/seshat-reader/seshat-reader-select.el:599`、`:851` |
| F2 | `--normalize-flash-rects` / `--flash-selection` **已支持** `(PAGE X0 Y0 X1 Y1)` 五元组 | `seshat-reader-select.el:282`、`:560` |
| F3 | 跨页拦截点唯一：`start-page`/`end-page` 都存在且不等 → `user-error "暂不支持跨页选择"`；**零 ERT 覆盖** | `seshat-reader-select.el:833-835` |
| F4 | C 侧取文接口均**单页 + 0-based**：`--text-in-rect`（纯文本、不保留换行）、`--rects-in-rect`（逐字 quad）、`--lines-in-rect`（行框） | `emacs/seshat-reader/render/render-core.c:2038`、`:2317`、`:2357`、`:2401` |
| F5 | 选区坐标换算 `select-posn->page` 只除 `page-scale`，**不感知 rotate**；`select.el:56-62` 注释「rotation lives only in C side」在 P1 后已失效（`--multipage-rotate` 在 Lisp 可读） | `seshat-reader-select.el:670`、`:56-62`、`seshat-reader.el:1612`、`:1696` |
| F6 | C 侧渲染 ctm 来自 `fz_transform_page(dp->bbox, resolution, rotate)`，位图已是旋转后；协议 rect 语义是**未旋转 page space** | `emacs/seshat-reader/render/render-core.c:327`、`:3503-3516` |
| F7 | 旧解析器：`--page-from-location` 取**第一个** `page:<n>`（正则未加锚点）；`--rects-from-location` 只按 `;` 切段、只认 `rect:` 前缀、**与页号无关** → 会把串内**所有** `rect:` 段当作同一页 | `seshat-reader-annotation.el:506`、`:822-855` |
| F8 | 页码取不到时整条批注不参与装饰（`when page` 跳过），不报错 | `seshat-reader-annotation.el:1187-1195` |
| F9 | 写入端段上限 500（`--anchor-max-segments`，超限提示），解析端 2000 段 / 65536 字符 | `seshat-reader-annotation.el:237`、`:809`、`:816` |
| F10 | 服务端**不解析** location，只校验非空；`docs/api.md` 已书面声明新形态无需服务端改动 | `internal/storage/state.go:151-165`、`docs/api.md:359`、`:461` |
| F11 | Android `LocationCodec.parsePage` 在 `segments.size > 2` 时返回 `Parsed.Unknown`（多段 `rect:` 今天已不支持），不抛异常 | `android/app/src/main/java/com/seshat/app/reader/LocationCodec.kt:97`、`:107-119` |
| F12 | `--multipage-page-at-pos` 可把 buffer 位置映射到页号 | `emacs/seshat-reader/seshat-reader.el:1555` |

## 设计决策

- **D1 数据结构**：`seshat-reader-select-last` 的 `:rects` 扩展为 `((PAGE X0 Y0 X1 Y1) …)`；保持 plist 形态与 `:page`（起点页）不变。读取方一律经归一化函数，4 元组按 `:page` 补齐、5 元组原样（向后兼容旧数据与旧测试）。
- `:rect`（整体 bbox）语义：**始终是「起点页上的选区 bbox」**——单页时与现状完全一致；跨页时仅是首页 bbox，供只支持单 bbox 的消费方（`translate.el` 的矩形路径、`reference.el` 的旧链接路径）使用。跨页时 `seshat:` 引用链接**降级为纯页锚 `page:<起点页>`**（见 D5b），并给出可见提示，不得静默降级。
- **D2 跨页取文**：移除 `user-error`；用 `--multipage-page-at-pos` 求页区间，**逐页**调 C 接口（单页 0-based，C 侧零改动）；文本按阅读顺序拼接、页间插一个换行；每页单独计算 bbox 与 rects。
- **D3 首末点落页间分隔区**：沿用 P1 既有语义——`--multipage-page-at-pos` 把页后 gap 归**上一页**（其 docstring 明写「answer only changes at the start of the next row」），**不实现「更近页」判定**，避免与页区间求值并存两套页号逻辑。当前「两端页号都非 nil 才判跨页」的条件保留；端点落 gap 时自然归上一页，ERT 覆盖该分支。
- **D4 旋转坐标**：新增逆变换，**仅在** `select-posn->page` 出口施加，输入是「已旋转 page space」坐标、输出「未旋转 page space」；90/270 交换宽高。`--multipage-rotate` 是唯一真源，不读 C 侧 `EmacsWinState.rotate`。宽高来源用 `posn-object-width-height`（当前 `select-posn->page` 只读 `posn-object-x-y`，不读宽高；90/270 需交换）。
- **D5 location 形态**：
  - 单页（含同页多矩形）：**继续输出旧形态** `page:<n>;rect:x0,y0,x1,y1;…`（零变更）。
  - 跨页：输出 `pages:<a>-<b>;rect@<page>:x0,y0,x1,y1;rect@<page>:…`。
  - **否决形态**「同串多 `page:` 段」：旧解析器会把第二页的 `rect:` 段也收集到第一页（F7），结果是**画错**而不是降级。
- **D5b `seshat:` 引用链接（采用「降级为纯页锚」方案）**：引用链接只需「可复现落点」，不承载选区几何（`emacs/seshat-reader/seshat-reader-reference.el:937` 的既有哲学：链接串短更利于阅读）。因此跨页选区时，引用链接输出**纯页锚** `page:<起点页>`（不带 `rect:`、不带 `pages:`），并 `message` 提示「跨页选区引用已降级为起点页锚点」；单页时输出与现状**逐字节一致**（现状形态由 `--current-location` 决定，不做改动）。**读端零改动**：`--goto-location`（`reference.el:697-709`）、`--description`（`:548`）、`--insert-annotation`（`:1059`）继续按旧形态工作。**写端两处都要接同一降级判定**：`--current-location`（`:945`）与 `--store`（org-store-link 路径，`:786-825`，它独立调 `--anchor` 不经过 `--current-location`）。
- **D6 兼容不变量**（必须有反向断言）：旧形态读写零变化；新形态下 `--page-from-location` 返回 nil → 装饰整条跳过（F8）；Android 落 `Unknown`（F11）。
- **D7 段数上限**：跨页形态按 `--anchor-max-segments` 计数时以「页数 + 矩形段数」计；超限时**降级**为「只保留首页的矩形并提示」，不得静默丢段也不得超长写入。降级时**文本同步截断到首页**（避免「文本含第二页、高亮只在第一页」的不一致），提示走 `display-warning` 而非 `message`（避免被后续消息冲掉）。
- **D8 范围纪律**：不改 C 侧、不改服务端、不改 Android（另记 tech-debt）、不做异步渲染、不动 hscroll、不复活单页 overlay。

## 假设清单

| # | 假设 | 来源 | 验证点 |
|---|---|---|---|
| A1 | 新前缀 `pages:` 能让旧客户端整条跳过 | 事实✓（F7+F8） | T6 反向断言 |
| A2 | 旋转逆变换可纯 elisp 完成、无需 C 改动 | 假设?（F6） | T3 ERT + L3 真机三角度 |
| A3 | 逐页调 C 接口的总耗时可接受（跨 2–3 页） | 假设?（单页 0.7–11 ms，F4） | 批次 1 实测记录 |
| A4 | 首末点落分隔区时「gap 归上一页」符合直觉、无需「更近页」特判 | 事实✓（`--multipage-page-at-pos` docstring）+ 假设?（真机观感） | L3 真机 |
| A5 | 旧形态在单页多矩形时保持原样不破坏既有批注 | 事实✓（F7 回归基线） | T4/T5 回归断言 |

## 任务

- [x] **T0 基线与安全点**（依赖：无）：`git -C /home/thomas/Workspace/seshat status --short`、`git log -1 --oneline`；记录当日实测基线——`make -C emacs/seshat-reader clean all` 的 EXIT 与 warning 数、`make -C emacs/tests ert` 的文件数与用例数、`make -C emacs/tests check-criteria` 结果。验收：基线数值写入「## 执行记录」。
- [x] **T1 选区结构扩展 + 归一化**（依赖：T0）：`seshat-reader-select.el` 更新 `seshat-reader-select-last` 的 docstring（`:rects` 元素为 `(PAGE X0 Y0 X1 Y1)`，旧 4 元组仍可读）；新增归一化函数（4 元组按 `:page` 补齐、5 元组原样），在 `--normalize-flash-rects` 与批注取 rects 的两处入口统一使用。验收：ERT 新增「4 元组兼容」「5 元组原样」「空/nil 输入」三例。
- [x] **T2 跨页取文**（依赖：T1）：移除 `select.el:833-835` 的 `user-error`；新增页区间计算（`--multipage-page-at-pos`）、逐页取文与 rects、逐页 bbox、按阅读顺序拼接（页间换行）；按 D3 沿用 `--multipage-page-at-pos` 的「gap 归上一页」语义（不做近页判定）。验收：ERT 覆盖「跨 2 页」「跨 3 页」「单页（行为不变）」「起点落 gap」「末点落 gap」五例；`C-c C-l` 列表页码取首页。另断言跨页时 `:rect` = 起点页 bbox、`:page` = 起点页号。
- [x] **T3 旋转页坐标逆变换**（依赖：T2）：新增逆变换函数（0/90/180/270，90/270 交换宽高），在 `select-posn->page` 出口按 `seshat-reader--multipage-rotate` 施加；删除/改写 `select.el:56-62` 已失效注释。验收：ERT 四个角度的坐标往返（含宽高交换）+ 一个「rotate=0 时与原行为逐值相等」的回归断言。
- [x] **T4 location 新形态构造**（依赖：T2）：`--anchor` 扩展——全部矩形在同一页时输出旧形态（逐字节不变），跨页时输出 `pages:<a>-<b>;rect@<page>:…`；`--selection-rects` 返回带页号形态；实现 D7 的段数上限与降级提示。验收：ERT「单页旧形态逐字节相等」「两页新形态」「段数超限降级」三例。**同时必须改造 `seshat-reader-annotation--anchor-segments`（`annotation.el:253`）**：其「`(nth 0..3 rect)` 全为数字即合法」的判定会把 5 元组 `(PAGE X0 Y0 X1 Y1)` 当前 4 个元素当作 rect（PAGE 当 x0、Y1 丢弃），属**确定性数据损坏**；改造为「元素长度 = 5 视为带页号」分支，或让跨页路径绕过它。必须补一条反向 ERT：5 元组不得落入 4 元组解析。**引用链接（D5b）另加两例**：单页时 `--current-location` 与 `--store` 输出逐字节不变；跨页时两者都输出纯 `page:<起点页>`（无 `rect:`/无 `pages:`）。降级判定信号 = `:rects` 归一化后去重页号 > 1（单页多矩形时页号全同，不会误判）；两处写端必须共用同一信号。
- [x] **T5 新形态解析与接入**（依赖：T4）：新增 `--pages-from-location` 与「带页号的 rects 解析」；`--annotation-decorations` 支持新形态（按段页号展开）；批注列表页码列对新形态显示 `a-b`。验收：ERT「新形态解析」「旧形态回归」「未知形态跳过」「装饰按页展开」四例。消费点清单（全部要支持 `pages:` 的 `a-b` 显示）：`--etaf-items`（`annotation.el:1587`/`:1602`/`:1614`）、`--all-items`、`--render-list`（`:684`）、**离线队列待同步条目**（queued 分支）；ERT 需覆盖「离线条目页码显示 `a-b`」。
- [x] **T6 兼容反向断言**（依赖：T5）：断言在新形态上 `--page-from-location` 返回 nil、`--annotation-decorations` 不产出该条装饰（证明旧客户端行为是「跳过」而非「画错」）；同时在 ERT 注释里写明依据 F7/F8。验收：该用例必须在「故意把新形态当旧形态解析」的变异下失败（做一次变异自检并记录）。
- [x] **T7 文档沉淀**（依赖：T2/T4/T5）：`docs/api.md` 新增 §4.5.3「跨页选区形态（`pages:`）」含旧/新形态兼容表与 Android 现状；`docs/emacs-reader.md` §5 更新「跨页拖选暂不支持」「旋转页不支持」两处；`CHANGELOG.md` 条目；`openspec/decisions.md` 新增一条（形态选择 + 为何否决多 `page:` 段）；`openspec/tech-debt.md` 勾销跨页选区与旋转坐标两条、新增「Android 不解析 `pages:`」；`openspec/roadmap.md` 更新。
- [x] **T8 L1 + L2 全量验证**（依赖：T1–T7）：`make -C emacs/seshat-reader clean all` EXIT 0 且 warning 不超过 T0 基线（零新增）、checkdoc 0、`check-parens` 通过；`make -C emacs/tests ert` 0 unexpected 且 0 skipped；`make -C emacs/tests check-criteria` PASS。
- [x] **T9 L3 真机验收（需用户）**（依赖：T8）：① 跨页拖选取文正确（2 页与 3 页）；② 跨页批注高亮在两页都落在正确位置；③ `C-c C-l` 列表页码显示 `a-b` 且 `RET` 跳到首页；④ 旋转 90°/180°/270° 后框选，高亮与选区一致；⑤ 旋转页 + 跨页组合；⑥ 旧批注（旧形态）高亮位置不变。
  - ✅ 已确认（用户 2026-10-27）：「生效了」——`overlayp nil` 崩溃修复后拖选取文可用、不再报错（① 的基本可用性；未分别验证跨 2 页 / 跨 3 页）。
  - ⚠️ **未逐项确认**（不视为通过，转「使用中观察」）：② 跨页批注高亮两页位置；③ 列表页码 `a-b` 与 `RET` 跳首页；④ 旋转 90°/180°/270° 框选位置；⑤ 旋转 + 跨页组合；⑥ 旧批注位置不变；批次 4 两个补充观察点：ETAF 卡片 `p.1-2`、500 段降级的 `*Warnings*` 提示。

## 文档清单

| 文档 | 变更 |
|---|---|
| `docs/api.md` | §4.5.3 新增 `pages:` 跨页形态 + 旧/新兼容表 + Android 现状 |
| `docs/emacs-reader.md` | §5 去掉「跨页拖选暂不支持」「旋转页不支持」限制 |
| `CHANGELOG.md` | 跨页选区 / 旋转坐标两条 |
| `openspec/decisions.md` | 新形态选择与「否决同串多 `page:`」的理由 |
| `openspec/tech-debt.md` | 勾销两条；新增「Android 不解析 `pages:`」 |
| `openspec/roadmap.md` | P2-2 / P2-8 状态 |
| `emacs/seshat-reader/VENDORED.md` | 不改（C 侧零改动，需在文档中显式写明「本轮未动 C」） |

## 验证标准

- **L1**：`make -C emacs/seshat-reader clean all` EXIT 0、warning ≤ T0 基线（零新增）、`make -C emacs/seshat-reader checkdoc` 0 报错、`check-parens` 通过
- **L2**：`make -C emacs/tests ert` → `0 unexpected` **且** 0 skipped（判据由 `emacs/tests/ert-judge.sh` 数值判定）+ `make -C emacs/tests check-criteria` PASS
- **L3**：T9 六项真机全过（ERT 不能证明 redisplay 与真实几何）——**实况**：仅第 ① 项可用性经用户 2026-10-27 确认（「生效了」，拖选取文可用、不再报错），②–⑥ 与两个补充观察点转「使用中观察」，见「执行记录 → T9 真机验收（用户）」
- 任务类型：elisp 验证走 `verify` 隔离实例；收尾 `set_task auto` + `instance stop` + `instance_status` 确认

## 注意事项

1. **不得**用「同串多 `page:` 段」实现跨页（会画错，见 D5/F7）。
2. 单页路径必须**逐字节**保持旧形态输出（回归基线，用 ERT `equal` 断言字符串）。
3. C 侧、服务端、Android **零改动**；发现必须改才能完成时停下报告，不要越界。
4. 旋转逆变换只在 `select-posn->page` 一处施加，避免多处换算叠加。
5. 段数上限要「降级 + 提示」，不得静默丢段。
6. 每个批次结束跑 `make -C emacs/tests ert` + `check-criteria`；涉及几何/坐标的批次必须真机复核。
7. 计划文件回写用「读全文 → 精确替换 → 整体写回」，并在写回后核对行数（本仓历史上有编辑工具静默截断计划文件的事故）。
8. 跨页选区做 explain/翻译上下文时**只覆盖起点页矩形**（`translate.el:1294-1358` 用 `:rect` 单 bbox），翻译对象本身仍用 `:text` 全量——这是 D1「`:rect` = 起点页 bbox」的必然结果，不是缺陷；若真机观感不可接受再另立条目。

## 执行记录

### 批次 1（T0 / T1 / T2）—— 2026-10-27

**T0 基线（改动前实测）**

- `git log -1 --oneline`：`3976942 docs(openspec): 归档阅读器暗色 5 档预设与 T 键循环两计划`
- `git status --short`（改动前）：`M openspec/roadmap.md`、`M openspec/tech-debt.md`（本轮之前既有）、`?? openspec/active/2026-10-27-…-cross-page-selection.md`
- git 安全点：`899319fda84031fcb213d4ff1ba3d45c44b55670`（`git stash create`，未动工作目录）
- `md5sum emacs/seshat-reader/seshat-reader-select.el`：改动前 `b890467df9f62bd8f305a03ddcf420d6` → 改动后 `2582ebf0f4211b1212d63fb1e17c36c5`
- `make -C emacs/seshat-reader clean all`：**EXIT 0**，warning **20** 条（与近期基线一致）
- `make -C emacs/tests ert`：**FILES=33 / TOTAL=1276 / UNEXPECTED=0**，EXIT 0
- `make -C emacs/tests check-criteria`：**PASS**

**事实核查（T1 路线决策依据）**

- `:rects` 读取点：`annotation.el:324`（`--selection-rects`，**唯一生产读取点**）、`select.el:612/814/859`（docstring 与唯一写入点）、`reference.el:809/938`（仅注释，实际只用 `:rect`）、测试侧 10 处（`annotation-decoration-test.el:69/124/126/129`、`annotation-test.el:283/289/584/585/593/613/618`）。
- `seshat-reader-select-last` 读取点：`annotation.el`（经 `--selection-rects` 取 `:rects`/`:rect`，另 `plist-get :page/:text/:file`）、`translate.el:650/710/1297-1299`（只读 `:text`/`:page`/`:rect`）、`reference.el`（只读 `:rect`），其余全是 ERT 自造 plist。
- `emacs/tests/Makefile`：`TEST_FILES := $(sort $(wildcard $(TESTS_DIR)/*.el))` → **wildcard 发现**，新增测试文件无需改 Makefile。

**偏差 D1′：T1 采用保守变体（不扩展 `:rects` 元素形态）**

- 计划原文 D1 = 「`:rects` 扩展为 `(PAGE X0 Y0 X1 Y1)` 五元组」。本批改为：**`:rects` 形态与语义零变化**（仍是**起点页内**的 4 元组列表），跨页信息放新字段 **`:page-rects`**（`(PAGE X0 Y0 X1 Y1)` 列表，页序、页内原顺序）。
- 理由：`:rects` 的唯一生产读取点 `annotation.el:324` 把元素直接交给 `--anchor-segments`（`annotation.el:253` 起，按 `(nth 0..3 rect)` 格式化成 `page:<n>;rect:x0,y0,x1,y1`），5 元组会被当 4 元组解析 → 确定性数据损坏（计划 T4 已预判）。改元素形态要同批改造解析端，回归面远大于收益；新字段可做到**旧消费者零改动**。
- 代价/收益：`--normalize-flash-rects` / `--flash-selection` 本批完全未动（本就吃 4 元组；批次 3 直接用 `:page-rects`）。
- 一致性保证：单页时 `:page-rects` 每元素页号 = `:page`，且 `(mapcar #'cdr :page-rects)` 与 `:rects` **逐值相等**（ERT 断言）。

**T0 / T1 / T2 完成情况**

- T0：基线数值已记录（见上）；安全点为 `git stash create` 引用，未创建提交。
- T1：`seshat-reader-select-last` docstring 补齐 `:page`（跨页时 = 起点页）、`:rect`/`:rects`（同属起点页）、新增 `:page-rects` 的语义差异与「单页时二者等价」；**未新增归一化函数**（保守变体不需要改旧读取路径）。
- T2：跨页 `user-error` 已删除（原位留注释指向新实现）；新增 6 个内部符号——`--page-extent-fallback`（常量）、`--posn-page-extent`（页尺寸，复用 `posn->page` 的同一换算因子）、`--selection-page-rects`（页区间 + 逐页裁剪矩形）、`--page-selection`（逐页调 C 侧 `--text-in-rect` / `--rects-in-rect`，页号 `(1- page)`）、`--join-page-texts`（页间一个换行）、`--flatten-page-rects`。页区间仍由 `--multipage-page-at-pos` 决定，「gap 归上一页」原样沿用，未做「更近页」判定。
- **单页路径逐值不变**：`--selection-page-rects` 在 `first = last` 时返回两端坐标的 min/max bbox，表达式与改动前完全一致；模块页号同为 `(1- first)`，`:page` 仍为 `(or start-page-number (current-doc-pagenumber))`。

**新增 ERT**：`emacs/tests/seshat-reader-select-cross-page-test.el`（345 行，8 例）——T1 三例（`:page-rects` 与 `:rects` 逐值相等 / 页序 / nil 与空输入）、T2 五例（跨 2 页、跨 3 页、单页逐值不变、起点落 gap、末点落 gap）。全部用桩替（`posn-*`、`--page-scale`、`frame-scale-factor`、`--text-in-rect`、`--rects-in-rect`、`--flash-selection`），页行是真的（gap 语义由真实 `--multipage-page-at-pos` 回答）。

**被推翻的既有断言（必须改，非意外回归）**：`seshat-reader-periphery-test.el` 的 `--select-extract-rejects-cross-page` 断言的正是 T2 要移除的 `user-error`，已改写为 `--select-extract-cross-page-extracts-text`（断言跨页取文 + `:page`/`:rect` 归起点页 + 无几何时 `:page-rects` 与 `:rects` 同为 nil）。该文件用例数不变（22 → 22）。

**批次 1 验证结果（改动后实测）**

- `make -C emacs/seshat-reader clean all`：**EXIT 0**，warning **20**（= 基线，**零新增**；无一条指向 `seshat-reader-select.el`）
- `make -C emacs/seshat-reader checkdoc`：**0 报错**
- `check-parens`（宿主 `emacs -Q --batch --visit`）：`seshat-reader-select.el` / 新测试文件 / `periphery-test.el` 全部 OK
- `make -C emacs/tests ert`：**FILES=34 / TOTAL=1284 / UNEXPECTED=0**，EXIT 0（= 基线 33 / 1276 + 新文件 8 例，文件数 +1，无 skipped）
- 新文件单跑：`Ran 8 tests, 8 results as expected, 0 unexpected`
- `make -C emacs/tests check-criteria`：**PASS**
- `git diff --stat`：仅 `seshat-reader-select.el`(+190/−39)、`seshat-reader-periphery-test.el`(+34/−12)、新测试文件、计划文件（另有本轮之前既有的 `openspec/roadmap.md` / `tech-debt.md`）；**无 C 文件 / server / android 改动**

**遗留问题**

- `:page-rects` 暂无生产消费者（批次 3 的绘制路径、批次 2 的 location 构造才会用）。
- 跨页 flash 仍只闪起点页几何（`--flash-selection` 调用未改，属批次 3）。
- `--posn-page-extent` 依赖 `posn-object-width-height`；批次帧无 redisplay 信息时退回常量 1.0e7（`ignore-errors` + 兜底）。真机需在 T9 复核「页高换算是否与 C 侧位图尺寸一致」。
- 跨页 `:text` 页间只插一个换行；若真机观感要求保留段落空行，另立条目（本批不做）。

### 批次 2（T3 旋转页坐标逆变换 + 两项补强）—— 2026-10-27

**安全点**：`git stash create` = `4a479083f295cd9e6bdb1c4e7655f5fd9512ec16`（批次 2 开始时的状态，含批次 1 改动；未动工作目录）。
**改动前 md5**：`seshat-reader-select.el` = `2582ebf0f4211b1212d63fb1e17c36c5`，`seshat-reader-select-cross-page-test.el` = `fd5a3948cd5c953be4839e49c6648ad4`。

#### 步骤 A：旋转语义依据（不靠猜测）

1. **C 侧构造**（`render/render-core.c`）：`render_page_to_buffer`（`:308`）在 `:327` 用
   `fz_transform_page(dp->bbox, resolution, rotate)` 造 ctm，位图就是旋转后的结果；
   `resolution = clamp(scale * 72, ...)`（`:3510`），`rotate` 由 `emacs_page_image_spec`（`:3477`）
   的可选第三参数进入，`:3503-3516` 只接受 `0 / 90 / 180 / 270`（其它值直接返回 nil）。
   输出尺寸 `local_imgw/local_imgh = fz_pixmap_width/height / frame_scale`（`:654-655`）。
2. **MuPDF 语义**（`/usr/include/mupdf/fitz/geometry.h:548` 只有一行 doc；
   实现在上游 `source/fitz/geometry.c`，按本机 mupdf-gl 1.28.5 取同版本源码核对）：
   - `fz_transform_page`：`pixel_w = floor(user_w*res/72+0.5)`、`pixel_h` 同理；
     `matrix = fz_pre_rotate(fz_scale(pixel_w/user_w, pixel_h/user_h), rotate)`，
     最后把 `pixel_box` 的原点平移到 (0,0)。
   - `fz_pre_rotate` 的 90/270 分支会交换 `a/d` 与 `b/c`，因此 **90/270 的输出位图宽高互换**；
     `fz_rotate(90)` 在 y 向下的设备坐标里把 +x 映到 +y，即**顺时针**旋转。
   - `fz_transform_point` 的约定是 `x' = a*x + c*y + e`、`y' = b*x + d*y + f`。
3. **Lisp 侧取值**：`seshat-reader--multipage-rotate`（`seshat-reader.el:1612`，defvar-local，
   注释写明取值 ∈ {0,90,180,270}），唯一写入点是 `--multipage-rotate-by`（`:2441`，
   `(mod (+ rotate delta) 360)`，delta 为 ±90，故结果恒为非负的 0/90/180/270）。
4. **实测复核（像素级，2026-10-27）**：自造四象限灰度 PDF（612×792，页左上=0、右上=0.25、
   左下=0.5、右下=0.75），用 C 侧 `seshat-reader-dyn--page-image-spec` 在四个角度渲染并解析
   PNM 采样象限中心，实测映射为：

   | rotate | 位图尺寸 | 页左上角落在位图的 | 页右上角 | 页左下角 | 页右下角 |
   |---|---|---|---|---|---|
   | 0 | 612×792 | 左上 | 右上 | 左下 | 右下 |
   | 90 | 792×612 | **右上** | 右下 | 左上 | 左下 |
   | 180 | 612×792 | 右下 | 左下 | 右上 | 左上 |
   | 270 | 792×612 | **左下** | 左上 | 右下 | 右上 |

   四个角点、四个角度，与下面推导出的公式**逐条吻合**，且宽高交换只发生在 90/270。

**公式（page space (x,y) → 旋转后图像空间）**，W/H 为**未旋转**页宽高：

| rotate | x' | y' | 位图宽 | 位图高 |
|---|---|---|---|---|
| 0 | x | y | W | H |
| 90 | H − y | x | H | W |
| 180 | W − x | H − y | W | H |
| 270 | y | W − x | H | W |

逆变换（本批实现）：0 → (x', y')；90 → (y', H − x')；180 → (W − x', H − y')；270 → (W − y', x')。
**判定：依据充分**（源码 + 同版本上游实现 + 像素实测三方一致），不需要「待 T9 真机确认公式」。
仍需 T9 复核的是**输入量的单位口径**（见「偏差」②）。

#### 步骤 B/C/D 改动摘要（`emacs/seshat-reader/seshat-reader-select.el`，+212/−39）

新增 5 个内部函数（全部纯函数或只读，无副作用，不渲染）：

| 函数 | 作用 |
|---|---|
| `--page-rotate (&optional window)` | 从 `window-buffer` 的 `seshat-reader--multipage-rotate` 读旋转（窗口 buffer 无该变量时退回当前 buffer，正是拖拽路径的情形）；非 90 倍数按 0 处理 |
| `--unrotate-size (size rotate)` | 90/270 交换宽高；0/180 原样。自逆，正反两向都用它 |
| `--unrotate-point (point rotate size)` | 上表的逆变换；`rotate=0` 返回 `(cons x y)` 原值，不做任何浮点改写 |
| `--unrotate-rect (rect rotate size)` | 映射两个对角后归一化（90/270 会换对角） |
| `--page-space-size (page window)` | 该页**未旋转**尺寸：`--multipage-native-size`（= 已旋转位图尺寸 ÷ 渲染 scale）过 `--unrotate-size`，再乘 frame scale；取不到返回 nil |

施加点与改动：

1. **`seshat-reader-select-posn->page`（唯一施加点）**：先按原公式算「旋转后 page space」坐标，再 `--unrotate-point`。
   `rotate=0` 走恒等分支，**逐值等于改动前**；`rotate≠0` 而页尺寸量不到时 `message` + 返回 nil（宁可明确失败，也不把旋转后坐标当页面坐标交给模块）。
2. **`--posn-page-extent`（旋转感知）**：`posn-object-width-height` 报的是已旋转位图尺寸，出口过 `--unrotate-size`，因此调用方拿到的恒是**未旋转**页尺寸。
3. **`--selection-page-rects`（每页自己的尺寸，步骤 C）**：非末页的 `y1` 改为该页自身高度（`--page-space-size`），回退顺序 = 该页 native → 起点页 extent → `--page-extent-fallback`。
   为消除两套换算口径的差异，用**起点页**的 `extent / native` 比例做标定（起点页结论与只用 extent 时逐值相同，其余页按同一比例缩放）——这条也让 T3 的单位问题不必先解决就先可用。
   顺带把 `(start-on-first (= first start-number))` 加了 `start-number` 守卫（cross-page 分支实际不会拿到 nil，属防御性）。
4. **失效注释**（`select.el:54-61` 原文「rotation lives only in the C side `EmacsWinState`」）改为「P1 后旋转是 Lisp 侧 `seshat-reader--multipage-rotate`，本模块据此逆变换」；`--granularity` 段那句「rotated pages remain unsupported」同步改为「按页空间水平行聚类，四分之一转的矩形仍是轴对齐」。
5. **`--posn-page-extent` / `posn->page` / `--selection-page-rects` 调用点清单（EE-8）**：
   - `seshat-reader-select-posn->page`：`seshat-reader-select-extract`（`:975`、`:976`，生产）、`seshat-reader-select-describe-posn`（`:1085`，交互式标定助手）；测试 `periphery-test.el:140/666/668`、`multipage-test.el:2580`（均对新返回值做 `numberp`/`consp` 断言，不依赖具体数值）。
   - `--posn-page-extent`：仅 `--selection-page-rects`（`:883` → 本批改为 `:1043`）+ `posn->page`（本批新增，rotate≠0 时）。
   - `--selection-page-rects`：仅 `seshat-reader-select-extract`（`:983`）+ 测试（`cross-page-test` 3 处）。
   - 影响面：几何只在 select.el 内部流转，`annotation` / `translate` / `reference` 消费的都是「页面坐标」语义，本批让旋转页的坐标**首次真正落在页面空间**，故对它们是修正而非语义变更。

#### 步骤 D：历史疑问核查结论（`--page-selection` 直接调 `text-in-rect` 无 `fboundp` 守卫）

`git show 899319f:emacs/seshat-reader/seshat-reader-select.el | grep -n -B6 -A6 'text-in-rect'` → 改动前 `seshat-reader-select-extract` 在 `:846` 就是
`(text (seshat-reader-dyn--text-in-rect page x0 y0 x1 y1))`，**同样没有 `fboundp` 守卫、也没有 `ignore-errors`**（该文件里 `fboundp` 只用于
`annotation--redraw-highlights` / `dyn--clear-highlights` / `dyn--add-highlight` / `multipage-page-at-pos` / `lines-in-rect` / `rects-in-rect`）。
**结论：无回归，不改。**（模块缺失时 `--text-in-rect` 本就是 void-function 错误，这是改动前既有行为。）

#### 新增 ERT（`emacs/tests/seshat-reader-select-cross-page-test.el`，8 → 17 例）

| 用例 | 断言 |
|---|---|
| `--unrotate-roundtrip` | 四个角度 × 五个点：正向映射（`--rotate-point`，取自 C 侧公式并经像素实测核对）∘ `--unrotate-point` = 恒等（容差 1e-9） |
| `--unrotate-corners` | 四个角点的逐值映射（含 90/270 宽高交换、页左上角→90° 图右上角等**实测**几何）；矩形往返 |
| `--posn->page-rotate-zero-unchanged` | **回归**：rotate=0 时 `posn->page` 与「未施加逆变换」的公式逐值相等 |
| `--posn->page-rotate-90` | rotate=90、位图 800×600、偏移 (100,50) → 页空间 (50.0, 700.0) |
| `--posn-page-extent-rotated` | 0/90/270 下都返回未旋转尺寸 (600.0 . 800.0) |
| `--page-rects-single-page-regression` | **回归**：单页分支输出与批次 1 逐值相等 |
| `--page-rects-per-page-size` | 三页 600×800/600×1000/600×400：中间页 `y1`=1000、末页 `y1`=拖拽点 300（≤400） |
| `--page-rects-per-page-size-rotated` | rotate=90 且 native 记的是旋转后 800×600：裁剪仍用未旋转 600×800（中间页 `y1`=800，不是 600） |
| `--page-extent-nil-fallback` | `posn-object-width-height` 返回 nil：`extent` 为 nil 不报错，无行的页回落常量 1.0e7 |

夹具加了两处能力：`--reader-buffer` 支持 `SIZES`（PAGE → (W . H)，默认 600×800），宏拆出 `--with-reader-sizes`（`--with-reader` 保留为 nil sizes 的薄包装，既有 8 例一字未改）。

#### 批次 2 验证结果（改动后实测）

- 新文件单跑：`Ran 17 tests, 17 results as expected, 0 unexpected`
- `make -C emacs/tests ert`：**FILES=34 / TOTAL=1293 / UNEXPECTED=0**，EXIT 0（= 批次 1 的 34 / 1284 + 新增 9 例；判据自检无 skipped 汇总行）
- `make -C emacs/tests check-criteria`：**PASS**
- `make -C emacs/seshat-reader clean all`：**EXIT 0**，warning **20**（= 基线，**零新增**；无一条指向 `seshat-reader-select.el`）
- `make -C emacs/seshat-reader checkdoc`：**0 报错**
- `check-parens`：`seshat-reader-select.el` / `seshat-reader-select-cross-page-test.el` / `seshat-reader-periphery-test.el` 全部 OK
- `git diff --stat`：仅 `seshat-reader-select.el`(+212/−39) / `seshat-reader-periphery-test.el`（批次 1 既有）/ `openspec/roadmap.md` / `openspec/tech-debt.md`（本轮之前既有）+ 新测试文件 + 本计划；**无 C / server / android 改动**

#### 偏差与遗留

1. **偏差 ①（保守选择）**：`--unrotate-*` 的 `SIZE` 语义定为「**未旋转**页尺寸 (W . H)」，而不是「旋转后位图尺寸」。理由：矩形/点的输出目标就是未旋转页空间，公式表以 W/H 为参数最直观，且 90/270 的交换只在 `--unrotate-size` 一处发生，避免调用方重复交换。
2. **偏差 ②（单位口径靠标定）**：`--page-space-size` 对「页面坐标单位」的假设是 `native × frame-scale`（与 `posn->page` 的 `image_px × frame_scale / page_scale` 对齐）。真机 `frame_scale ≠ 1` 或 `page_scale ≠ 渲染 scale` 时，这个假设可能偏一个因子——因此 `--selection-page-rects` **不直接采信绝对值**，而是用起点页 `extent / native` 的实测比例标定（起点页的结论与批次 1 逐值一致，其余页按同比例缩放），标定不可用时才退回绝对值。
   **待 T9 真机**：确认旋转页 + 跨页组合下高亮位置正确；若发现偏移，先查这里。
3. **`posn->page` 在 rotate≠0 且页尺寸量不到时返回 nil**（并 `message`）：这是有意选择的「明确失败」而非「静默错坐标」。真机 `posn-object-width-height` 可用，故不影响正常拖拽；批次帧（无 redisplay）才会命中。
4. **`:page-rects` 仍无生产消费者**（批次 3 的绘制路径、批次 2 的 location 构造才会用）；跨页 flash 仍只闪起点页（批次 3）。
5. **旋转页的文字形状（text shaping）**：本批只保证「矩形落在页空间、轴对齐」，`--lines-in-rect`（C 侧按页空间行框回答）随之正确；但**旋转页上的行聚类假设**（`--group-rects-into-lines` 按 y 聚类）在页空间仍然是水平行，故无额外改动。真机观感仍列 T9 第 ④⑤ 项。

### 批次 3（T4 / T5 / T6）—— 2026-10-27

**安全点**：`git stash create` = `3757b56847db20f568bf2be6a70dae8a48bfbf6b`（批次 3 开始时的状态，含批次 1/2 改动；未动工作目录）。
**改动前 md5**：`seshat-reader-annotation.el` = `2740dd38b54fbe7fcd1049e57bf4ec1e`，`seshat-reader-reference.el` = `486bfea490b5764ed7ac83216844830f`。

#### 步骤 0：调用点核查（改动前 grep 全仓 `*.el`）

| 函数 | 定义 | 全部调用点 |
|---|---|---|
| `--anchor` | `annotation.el:284` | `annotation.el:445`（create）、`reference.el:811`（store-link）、`reference.el:953`（current-location）、`translate.el:2870`；测试 `annotation-test.el:241/243/250`、`decoration-test.el:67/70/75/76/80/88/105/106` |
| `--anchor-segments` | `annotation.el:253` | **仅** `annotation.el:304`（`--anchor` 内部）；无测试直接调用 → 改签名（加可选 PAGE）安全 |
| `--selection-rects` | `annotation.el:319` | **仅** `annotation.el:421`（create）；测试 `decoration-test.el:123-132` |
| `--page-from-location` | `annotation.el:506` | `annotation.el:577`（ink-page）、`:684`（`--insert-entry`）、`:948`（ink strokes）、`:1188`（decorations）、`:1602`/`:1614`（etaf-items）；`reference.el:550`（description）、`:702`（goto-location）、`:1059`（insert-annotation）；`etaf.el:245`（`--item-page`）；测试 `v8-test:75/149/176/178`、`decoration-test:90` |
| `--rects-from-location` | `annotation.el:822` | `annotation.el:846`（自身）、`:1192`（decorations）；`ink-test:166/176`；`annotation-test:816-881` 多例；`decoration-test:112` |
| `--rect-from-segment` | `annotation.el:790` | **仅** `--rects-from-location`（`:846`）；本批新增的 `--page-rect-from-segment` 复用 |
| `--annotation-decorations` | `annotation.el:1174` | `annotation.el:1208`（annotation-rects）、`:1258`（cached-decorations）、`:1472`（redraw 内部）；测试 `decoration-test:197/248`、`annotation-test` 多例 |
| `--etaf-items` | `annotation.el:1580` | `annotation.el:1637`（all-items）；测试 `etaf-test:305/404/435`、`annotation-test:771`、`v8-test:97/188/220` |
| `--all-items` | `annotation.el:1622` | `annotation.el:1703`（render-list）、`:1781`（刷新路径） |
| `--render-list` | `annotation.el:1668` | `annotation.el:1718`（etaf 分支）、`:1766`/`:1775`（列表入口）、`:1845`；`etaf.el:536`；`sidebar.el:367/1612`（注释）；测试 `etaf-test:227/257/284`、`sidebar-test:212` |
| `reference--current-location` | `reference.el:930` | `reference.el:987`（copy-link）、`:1017`（insert）、`:1174`（测试桩）；`reference-test` 多例 |
| `reference--store`（`store-link`） | `reference.el:781` | `reference.el:907`（`org-link-set-parameters` 的 `:store`）；测试 `reference-test:390/400/405/1081/1093` |

离线队列路径：`--queued-create-entries`（`annotation.el:365`）→ `--etaf-items` 的第二参数（queued 分支 `:1614`）与 `--insert-entry` 的 `QUEUED-UUID` 参数（`[待同步]` 标记）；两处本批都改为跨页形态显示 `a-b`（`:page` 仍为首页数字以便跳转）。
上位上限实现：写入端 `--anchor-max-segments` = 500（`annotation.el:236`，超限走 `--warn-anchor-truncated` 的 `message`，只提示一次）；解析端 `--rect-max-segments` = 2000（`:816`）+ `--location-max-length` = 65536（`:809`），新解析函数复用同一组常量与同一 `while` 有界循环。

#### 步骤 1–2：改动摘要

**`emacs/seshat-reader/seshat-reader-annotation.el`（+404 / −72）**

| 改动 | 说明 |
|---|---|
| 新增 `--anchor-segment (rect page)` | 单段归一化为 `(PAGE X0 Y0 X1 Y1)`：**五元组用自身页号**、四元组用 PAGE 补齐；坏段 nil |
| 改造 `--anchor-segments (rects &optional page)` | 输出**统一带页号段**；新增「元素长度 = 5 视为带页号」分支（反向 ERT 见下） |
| 重写 `--anchor (page rects)` | 单页 → 旧形态（**逐字节不变**）；跨页 → `pages:<a>-<b>;rect@<p>:…`（段按页升序、页内原顺序，a/b 取实际存在矩形页号 min/max）；跨页超限 → 降级首页矩形 + `display-warning` |
| 新增 `--anchor-rect-segments` / `--anchor-page-segments` / `--anchor-pages` / `--anchor-degrades-p` / `--warn-anchor-degraded` | 串渲染与 D7 判定的单一来源 |
| 改 `--selection-rects` | **优先 `:page-rects`**（5 元组），否则 `:rects`，否则 `:rect` |
| 新增 `--selection-pages` / `--selection-cross-page-p` | 跨页判定唯一信号 = `:page-rects` 去重页号 > 1（单页多矩形不误判）；引用链接两处写端共用 |
| 新增 `--first-page-text` | D7 降级时取首页矩形包络内的文本（走 `seshat-reader-dyn--text-in-rect`，0-based 页号，模块不可用返回 nil） |
| 新增 `--pages-from-location` | 严格正则 `\\`pages:\\([0-9]+\\)-\\([0-9]+\\)\\(?:;\\|\\'\\)` |
| 新增 `--page-rect-from-segment` / `--page-rects-from-location` | 解析 `rect@<page>:` 段；字段级校验**复用** `--rect-from-segment`（拼成 `rect:` 后交付），上限沿用 2000 段 / 65536 字符 |
| 新增 `--page-label` / `--page-span-label` / `--location-page` | 显示页码串（旧形态数字 / 跨页 `a-b`）、仅跨页的跨度串、跳转页号（跨页取首页） |
| 改 `--annotation-decorations` | 旧形态走 `page` + `--rects-from-location`（**零变化**）；新形态走 `--page-rects-from-location` 按段页号展开 |
| 改 `--insert-entry` | 行首页码显示 `a-b`；行属性 `seshat-reader-annotation-page` = 首页（`RET` 跳首页） |
| 改 `--etaf-items` | `:page` = `--location-page`（首页数字，跳转/排序安全）、新增 `:page-label` = `--page-span-label`（旧形态 nil） |
| 改 `create` | 先算 D7 降级判定，降级时正文同步截断到首页 |
| 更新 docstring | Commentary 的 location 约定改为「两种形态 + 向后兼容为什么不能『修好』」；`--anchor` / `--anchor-segments` / `--selection-rects` / `--insert-entry` / `--etaf-items` / `create` 全部更新；另修正 `create` 里已失效的「旋转页面上的选区不受支持」 |

**`emacs/seshat-reader/seshat-reader-reference.el`（+38 / −6）**：`--current-location`（`:930`）与 `store-link`（`:781`）两处写端接同一判定 `--selection-cross-page-p` → 跨页时输出纯页锚 `page:<起点页>` + `message "跨页选区引用已降级为起点页锚点（第 N 页）"`；单页路径**逐字节不变**。读端（`--goto-location` / `--description` / `--insert-annotation`）**零改动**。

**未改**：`--page-from-location`、`--rects-from-location`、`--rect-from-segment`、`--chapter-from-location`、`--ink-*`、C 侧、服务端、Android、`etaf.el`。

#### 最终串样例（实测输出）

- 单页（含同页多矩形，逐字节等于改造前）：`page:1;rect:10.00,20.00,30.00,40.00;rect:5.00,6.00,7.00,8.00`
- 跨页（页 1 两段 + 页 2 一段）：`pages:1-2;rect@1:10.00,20.00,30.00,40.00;rect@1:12.00,22.00,32.00,42.00;rect@2:50.00,60.00,70.00,80.00`
- 跨页降级（`max=3`、2 页 3 段 → 5 > 3）：`page:1;rect:10.00,20.00,30.00,40.00;rect:12.00,22.00,32.00,42.00` + `display-warning`
- 引用链接跨页：`page:2`（起点页）+ `message` 降级提示（不带 `rect:`、不带 `pages:`）

#### 新增 ERT（`emacs/tests/seshat-reader-annotation-cross-page-location-test.el`，439 行 / 19 例）

| 用例 | 断言 |
|---|---|
| `--anchor-cross-page-new-form` | 跨页新形态逐字比对（含页 4→9 的跨度取实际页号） |
| `--anchor-single-page-byte-identical` | 5 元组/4 元组/裸 rect 三种入参在单页时**输出逐字节相等**；`nil` 仍为纯页锚 |
| `--anchor-orders-segments-by-page` | 乱序入参按页升序重排、页内保持原顺序 |
| `--anchor-segments-five-tuple` | **反向断言**：5 元组不得被当 4 元组（页号不当 x0、Y1 不丢）；坏元素跳过 |
| `--anchor-degrades-over-limit` | 超限降级为首页矩形 + `display-warning`（含「跨页」「上限」）+ 降级结果能被旧解析器读回；未超限仍新形态 |
| `--selection-rects-prefers-page-rects` | `:page-rects` > `:rects` > `:rect` > nil |
| `--selection-cross-page-signal` | 单页多矩形不误判；无 `:page-rects` 为 nil |
| `--current-location-cross-page-degrades` / `--current-location-single-page-unchanged` | 引用锚跨页降级 + message；单页逐字节不变且无多余提示 |
| `--store-link-cross-page-degrades` / `--store-link-single-page-unchanged` | `org-store-link` 路径同样降级 / 单页逐字节不变 |
| `--pages-from-location` | 严格前缀与尾部锚点（`xpages:` / `pages:1-2x` / `pages:a-b` 全 nil） |
| `--page-rects-from-location` | 逐段带页号；旧 `rect:` 段不误吞 |
| `--page-rects-reject-bad-segments` | 字段数 / 非数字 / 负面积 / 页号 0 只丢该段 |
| `--page-rects-caps-segment-count` | 2100 段输入 → 输出恰 2000 段（有界解析） |
| `--decorations-expand-by-segment-page` | 新形态按段页号展开（highlight / underline 两种 kind）；旧形态多段回归 |
| `--insert-entry-shows-page-span` | 行首显示 `1-2`、行属性 page = 首页 1；旧形态仍显示数字 |
| `--etaf-items-page-and-label` | server 与 **queued（离线待同步）** 两条都是 `:page` = 1、`:page-label` = `"1-2"`；旧形态 `:page-label` 为 nil |
| `--legacy-parsers-skip-new-form` | **T6 载体**：`--page-from-location` / `--rects-from-location` 对新形态均为 nil，旧实现 `when page` 分支永不进入（依据 F7/F8，注释里写明） |

#### 变异自检（T6 必做，完整记录）

1. **变异方式**：把 `--page-from-location` 改成「也认 `pages:`」——
   `(or (when (and (stringp location) (string-match "page:\\([0-9]+\\)" location)) (string-to-number (match-string 1 location))) (car (seshat-reader-annotation--pages-from-location location)))`，
   并删除陈旧 `.elc` 让测试加载源码。
2. **失败信息**（`Ran 19 tests, 16 results as expected, 3 unexpected`）：
   - `--legacy-parsers-skip-new-form`：`(should-not (seshat-reader-annotation--page-from-location "pages:1-2;rect@1:10,20,30,40;rect@2:50,60,70,80"))` **:value 1**（应为 nil）
   - `--decorations-expand-by-segment-page`（旧形态分支被新形态串命中 → 展开结果错）
   - `--insert-entry-shows-page-span`（页码显示退化）
3. **恢复**：还原 `--page-from-location` 原定义 → `grep -rn "MUTATION-FOR-T6" emacs/seshat-reader/` **无输出**；重新 `make -C emacs/seshat-reader clean all` 后新文件 **19/19 全绿**、全量 **1312 例 0 unexpected**；`git diff` 中无变异残留。

#### 批次 3 验证结果（改动后实测）

- 新测试文件单跑：`Ran 19 tests, 19 results as expected, 0 unexpected`
- 旧形态逐字节回归（单文件）：`annotation-test` 58 / `annotation-v8-test` 14 / `annotation-decoration-test` 21 / `annotation-ink-test` 24 / `etaf-test` 19 / `reference-test` 95 / `periphery-test` 22 / `sidebar-test` 143 —— 全部 `0 unexpected`
- `make -C emacs/tests ert`：**FILES=35 / TOTAL=1312 / UNEXPECTED=0**，EXIT 0（= 批次 2 的 34 / 1293 + 新文件 1 个 19 例；无 NORAN、无 skipped）
- `make -C emacs/tests check-criteria`：**PASS**
- `make -C emacs/seshat-reader clean all`：**EXIT 0**，`.el:行:列: Warning:` **20** 条（= 基线，**零新增**；无一条指向 `annotation.el` / `reference.el`）
- `make -C emacs/seshat-reader checkdoc`：**0 报错**（首轮曾报 3 条——首行非完整句、`--page-span-label` 缺 LOCATION、`--location-page` 含 keycode `C-l`——均已修）
- `check-parens`：`annotation.el` / `reference.el` / 新测试文件 全部 OK
- `git diff --stat`：本批仅 `annotation.el`(+404/−72)、`reference.el`(+38/−6)、新测试文件（untracked）、计划文件；其余为批次 1/2 既有（`select.el`、`periphery-test.el`、`select-cross-page-test.el`、`roadmap.md`、`tech-debt.md`）；**无 C / server / android 改动**
- 清理：删除了 `emacs --batch` 跑 native-comp 遗留的 `emacs/emacs-int-comp-subr--trampoline-*.el` 与 `test-nativecomp-cache-*/`

#### 偏差与遗留

1. **偏差 ①（ETAF 卡片页码仍是 `p.<首页>`）**：`--etaf-items` 已给出 `:page-label`（跨页 `"1-2"`），但 ETAF 卡片渲染（`seshat-reader-etaf.el:282` 的 `(format "p.%s" page)`）只读 `--item-page`，本批**未改 etaf.el**（不在本批文件范围）。文本列表（`--insert-entry`，即 `C-c C-l` 的实际渲染路径）已显示 `1-2` 且 `RET` 跳首页。若要让 ETAF 卡片也显示 `1-2`，需在 etaf.el 加一行 `(or (plist-get it :page-label) page)` —— 建议随 T7 文档批次或单独立项。
2. **`--page-label` 对旧形态返回数字字符串**（供 `--insert-entry` 复用），`:page-label`（ETAF 字段）因此另设 `--page-span-label` 只在跨页时产出；两者语义差异已写进 docstring。
3. **D7 降级的正文截断依赖动态模块**：`--first-page-text` 失败（模块不可用 / 首页无段）时保留原全量正文——极罕见（500+ 段跨页选区），此时高亮与正文可能不一致，属已知降级。
4. **跨页 flash 仍只闪起点页**（`--flash-selection` 未改，`select.el` 不在本批范围）——批次 3 遗留，仍列 T9 观察项。
5. `--anchor` 的跨页段序在入参乱序时按页升序重排（页内保持原顺序）；`:page-rects` 本身已是阅读顺序，重排只是防御。



### 批次 4（T7 / T8 + ETAF 页脚）—— 2026-10-27

**安全点**：`git stash create` = `b814def3bf971965fa24f443a8ef2888922d3973`（批次 4 开始时的状态，含批次 1–3 改动；未动工作目录）。
**改动前 md5**：`seshat-reader-etaf.el` = `43fc23a7dfd3f130d88a1f6d960ef1a9`，`seshat-reader-etaf-test.el`、六份文档的 md5 亦已记录（见执行时的 `md5sum` 输出）。

#### 步骤 1：ETAF 卡片页码（批次 3 遗留的偏差 ①）

**一行改动**（`emacs/seshat-reader/seshat-reader-etaf.el`，`--card`）：

```elisp
-  (let* ((page (seshat-reader-etaf--item-page it))
+  (let* ((page (or (plist-get it :page-label)
+                   (seshat-reader-etaf--item-page it)))
```

之所以改**入参**而不是改 `page-label` 的 `cond` 分支：`:page-label` 与 `:page` 同为「页码显示值」的候选，谁非 nil 用谁；改在一处即可，且 `chapter` 分支的 `(and (null page) …)` 判定语义自动保持正确（跨页时 `page` 为字符串，非 nil，故不会误判成章锚）。docstring 的页码列说明同步补三行（跨页显示 `p.1-2`，旧形态 `:page-label` 为 nil 故逐字节不变）。

**单页逐字节不变**：旧形态的 `--etaf-items` 给的 `:page-label` 是 nil（`--page-span-label` 只对 `pages:` 产出），`(or nil (--item-page it))` 等于原值。

**新增 ERT**：`emacs/tests/seshat-reader-etaf-test.el` 增 1 例 `--card-page-label-shows-page-span`（19 → 20 例）——用 `--etaf-items` 造「一条 `pages:1-2…` + 一条 `page:12…`」，渲染真实面板后断言 `p.1-2` 存在、`p.12` 仍在、且不存在「`p.1` 后紧跟空白」（列宽补位会让退化的 `p.1` 出现这种形态）。选该文件而非 `annotation-cross-page-location-test.el`：卡片渲染需要 ETAF 模块与真实面板，本仓的 ETAF 渲染断言全部集中在该文件（且本机 `straight/build-31.1/etaf` 存在，用例**不会被 skip**）。

**变异自检**：把该行改回只读 `--item-page`（并删除 `.elc` 强制加载源码）→ `Ran 20 tests, 19 results as expected, 1 unexpected`，失败点正是 `(should (string-match-p "p\\.1-2" text))@seshat-reader-etaf-test.el:431`；恢复后 20/20 全绿。

#### 步骤 2：T7 六份文档（逐份写了什么）

| 文件 | 实际改动 |
|---|---|
| `docs/api.md` | ① 新增 **§4.5.3 跨页选区形态（`pages:`）**（置于 §4.5.2 之后、§4.6 之前）：形态定义（`<a>/<b>` 取实际有矩形页号 min/max、段按阅读顺序）、坐标口径、旧形态零变化、**四行兼容表**（旧 Emacs 整条跳过 / 新 Emacs 按段页号绘制 / 服务端不解析原样存 / Android `segments.size > 2` → `Parsed.Unknown` 无高亮不崩溃）、限制与降级（写入端 500 按「页数 + 段数」计、降级为首页矩形 + `display-warning` + 正文同步截断、解析端 2000 段 / 65536 字符、引用链接降级为 `page:<起点页>`）、**「本轮未改动 C 侧」**声明与逐页调 0-based 单页接口的说明、一个真实串样例。② §4.5 的「共三形态」改为「共四形态」并补一行表格（页区间 + 逐页矩形）。③ §4.5 的「**不支持已旋转页面**」旧条目改写为「旋转页面：坐标是未旋转页面空间；Emacs 自 2026-10-27 起在采集点逆变换（0/90/180/270，90/270 交换宽高），Android 本轮未改动」——旧文案在批次 2 之后已与实现不符，属**必须同步**的文档一致性修正。④ §4.6 的 PDF/EPUB 形态并列表补一行跨页形态。 |
| `docs/emacs-reader.md` | ① §5「框选取文」末尾：把「**旋转页上的选区不受支持**」改为「已支持（2026-10-27）」，写清逆变换、页尺寸量不到时 `posn->page` 明确返回 nil 并提示。② §5 新增小节 **「跨页选区（2026-10-27）」**：页区间来源（`--posn-page-extent` / `--selection-page-rects` + `--multipage-page-at-pos`，gap 归上一页）、`:page-rects` 与 `:rect`/`:rects` 的分工、单页/跨页两种 location 分流与**真实串样例**、500 段降级、四条残余限制。③ §5「页面高亮与装饰」：删掉「（旋转页的坐标本身有误，见上）」，改为「坐标已在采集端逆变换回页面空间」。④ §5「手写轨迹显示」：旋转页偏移改述为**Android 侧**问题（ink 由 Android 采集，导出副本仍跳 `/Rotate ≠ 0`）。⑤ §7 多页布局新增「**选区跨页**」一段（可跨页、逐页几何、gap 归上一页）。⑥ §12 第 1 条（旋转页高亮可能错位）改写为「已修正但仍需真机复核」+ 两项残余（frame-scale 标定、Android 采集侧）；第 9 条（跨页拖选暂不支持）改写为「已支持，保留四类降级」。 |
| `CHANGELOG.md` | `## [Unreleased]` 的 `### 新增` 加 2 条、`### 变更` 加 1 条：跨页选区 + 旋转页坐标（含残余限制与验证数值）、ETAF 卡片 `p.1-2`（含变异自检）、location 新形态（含兼容表指针、旧形态零变化、上限降级、引用链接降级）。简体中文、无 emoji、验证数值全部取自本批实测。 |
| `openspec/decisions.md` | 新增 `## 2026-10-27 · 跨页选区的 location 形态与引用链接降级`，四点决策表格：① 为何新前缀 `pages:`/`rect@<page>:`、为何单页路径必须不动；② **为何否决「同串多 `page:` 段」**（`--page-from-location` 取第一个 `page:`、`--rects-from-location` 与页号无关 → 第二页矩形被收集到第一页 = **画错**而非降级；并把它抽象成不变量「新形态对旧读取方必须跳过而非误读」）；③ `:rects` 保持 4 元组 + 新增 `:page-rects` 的偏差原因（`--anchor-segments` 会按 `(nth 0..3)` 把 5 元组当 4 元组 → 确定性数据损坏；新字段让旧消费者零改动）；④ 引用链接降级的理由（引用只需可复现落点、写 `pages:` 会让旧客户端**无法跟随**）。另含上限/降级的取舍（降级而非截断的理由）与零改动边界。 |
| `openspec/tech-debt.md` | ① P1 遗留「跨页选区未实现」→ 追加 `——已解决（P2-A，2026-10-27）` + 落点。② M12「旋转页的 rect 采不准导致高亮可能错位」→ 标题追加 `——已解决（P2-A，2026-10-27：select-posn->page 逆变换）`，正文改为「解决前」并记采纳的方案（不新增 C 接口，复用 Lisp 侧 `--multipage-rotate`）。③ 新增「跨页选区的四类残余降级」（引用链接 / 解释上下文 / 闪现 / Android）。④ 新增「Android 不解析 `pages:` 跨页形态」（含 `LocationCodec.kt:97` 落点与改造建议）。⑤ 新增「`--page-space-size` 的 frame-scale 标定待真机」（批次 2 偏差 ② 记的假设，本轮确认仍在）。 |
| `openspec/roadmap.md` | 「M12 后续：PDF 多页连续布局」小节内：表格加 `P2-A` 行（🔄 已实现、待真机确认）；新增「2026-10-27 进展（P2-A 已实现，待真机验收）」与「候选池状态」两条（P2-2 / P2-8 已实现；P2-1 / P2-3 / P2-4 / P2-5 / P2-6 / P2-7 仍在池中）。**未动其它里程碑。** |

`emacs/seshat-reader/VENDORED.md` **未改**；「本轮未改动 C 侧」已写进 `docs/api.md` §4.5.3 与 `CHANGELOG.md` 两条。

#### 步骤 3：T8 全量验证（真实输出）

| 项 | 命令 | 结果 |
|---|---|---|
| L2 ERT | `make -C emacs/tests ert` | **`FILES=35 TOTAL=1313 UNEXPECTED=0`**，EXIT 0（= 批次 3 的 35 / 1312 + 本批 ETAF 1 例；文件数不变） |
| L2 判据 | `make -C emacs/tests check-criteria` | **PASS**（四条假汇总行 2 通过 2 拒绝，符合预期） |
| L1 编译 | `make -C emacs/seshat-reader clean all` | **EXIT 0**，`Warning:` **20**（= 基线，**零新增**；无一条指向 `seshat-reader-etaf.el`） |
| L1 checkdoc | `make -C emacs/seshat-reader checkdoc` | **0 报错**（无输出） |
| L1 括号 | 宿主 `emacs -Q --batch` + `check-parens` | `seshat-reader-etaf.el` / `seshat-reader-etaf-test.el` 均 **OK** |

**改动文件清单**（`git diff --stat`，含批次 1–3 累计）：`CHANGELOG.md`(+4)、`docs/api.md`(+43/−3)、`docs/emacs-reader.md`(+21/−6)、`seshat-reader-annotation.el`(+476/−72 累积)、`seshat-reader-etaf.el`(+5/−1)、`seshat-reader-reference.el`(+44/−6 累积)、`seshat-reader-select.el`(+441/−39 累积)、`seshat-reader-etaf-test.el`(+34/−1)、`seshat-reader-periphery-test.el`(批次 1)、`openspec/decisions.md`(+19)、`openspec/tech-debt.md`(+38/−)、`openspec/roadmap.md`；untracked：两个新测试文件 + 本计划。**`git status --porcelain` 过 `render/*.c|*.h` / `internal/` / `android/` 过滤器无命中 → 无 C / server / android 改动**。清理了 native-comp 遗留的 `emacs-int-comp-subr--trampoline-*.el`。

**文档一致性抽查**：`grep -c 'pages:' docs/api.md` = **7**（形态定义、兼容表、降级段、样例等）；`grep -n '1-2' docs/emacs-reader.md` 命中 §5「跨页选区」的真实样例 `pages:1-2;rect@1:…;rect@2:…`；串格式与批次 3 的 ERT 断言、`--anchor` 的实际输出（`pages:%d-%d` + `;rect@%d:%.2f,%.2f,%.2f,%.2f`）逐字一致，非臆造。

#### 偏差与遗留

1. **文档事实修正（超出任务字面范围但必须做）**：`docs/api.md` §4.5 原写「不支持已旋转页面…坐标会静默错误」，批次 2 之后已不成立，本批一并改写；`docs/emacs-reader.md` §5/§12 的同类表述同步。属「文档描述与实现不一致」的修正，非功能改动。
2. **ETAF 改动比「1 行」多 3 行 docstring**：代码只有 1 行（拆成两行），docstring 补了页码列对 `:page-label` 的取用说明，避免下一个人再从 `--item-page` 侧找答案。
3. **`docs/api.md` 的形态计数**：§4.5 由「共三形态」改为「共四形态」并补表格行，保持与 §4.5.3 一致。
4. **T9 仍未做（需用户）**：六项真机验收 + 本批两个补充观察点（ETAF 卡片是否显示 `p.1-2`；跨页且超 500 段时 `*Warnings*` 是否出现降级提示）。ERT 全绿不能证明 redisplay 与真实几何。
5. **未移动计划到 `completed/`**：T9 未完成，计划仍留 `openspec/active/`。

### 审查修复（code-reviewer 第 1 轮）—— 2026-10-27

**审查结论**：有条件通过——**无 blocking**，1 important（F1）+ 3 minor（F2/F3）+ 1 nit（F4）。本轮只修这 4 项，不改功能面（跨页选区 / 旋转坐标 / location 形态的对外语义零变化）。
**验证环境**：全程宿主 `emacs --batch`（`make` 入口）；未使用 elisp MCP 实例（任务类型语义为 `verify`，未触主实例）。

**安全点**：`git stash create` = `70e90ff9a56aa545dfa85814212afef1370c404c`（本轮开始时状态，含批次 1–4 改动；未动工作目录）。
**md5（改动前 → 改动后）**：
`seshat-reader-select.el` `a94e730fe6787b9c259008f27b3d28c4` → `00e56d2ef6b850831f752da928db2e6c`；
`seshat-reader-annotation.el` `112e5b3fe5e7cbb9c4bed5e8b8ae4216` → `afa2ea119f9b0b0c4a864118c002189e`；
`seshat-reader-select-cross-page-test.el` `b7d7c99f90295ed856a3f0a239280798` → `fd3c7148a87c1776a154b7f785f4114a`；
`seshat-reader-annotation-cross-page-location-test.el` `efbe3054f2909cb2e4d1ed330c9008ed` → `a77ad74c0ddeb8d14afa641696b22c27`。

#### F1（important）`--selection-page-rects` 的 `page-height` 兜底单位

- **问题**：`cl-labels page-height` 在换算比例 `ratio`（起点页 `extent / own native`）**不可用**时返回 `(cdr own)` = `native × frame-scale`，而拖拽坐标口径是 `image_px × frame_scale / page_scale`；两者只在「渲染 scale == page scale」时相等，否则页高偏**短** → 裁剪丢字。
- **做法**：`cond` 由「own 为 nil → `height`／有 `ratio` → `own × ratio`／否则 `own`」改为「有 `own` 且有 `ratio` → `own × ratio`／**否则一律 `height`**」，即比例不可用时统一回退到起点页高度（`--posn-page-extent`），起点 extent 也取不到时退常量 `--page-extent-fallback`（`1.0e7`）；**不再采信 `(cdr own)`**。docstring 改写为三条回退路径 + 为什么「宁可过长」（模块只报页内真有的字，过长无害；过短丢字）。单页分支（`first = last`）完全不走 `page-height`，逐值不变。
- **新增断言** `--page-rects-uncalibrated-own-not-short`（select-cross-page-test 17 → 19）：第 2 页位图按 scale 4.0 渲染（bitmap 600×3200 → native 600×800）、page-scale 2.0 / frame-scale 1.0、`posn-object-width-height` 返回 nil。断言 ①`--posn-page-extent` 为 nil（前提）；②中间页 Y1 **不是** own 的 800；③Y1 ≥ 拖拽口径下真实页高 1600（`3200 × frame / page`）；④Y1 = 常量兜底；⑤末页仍以拖拽点为下边界。
- **被推翻的既有断言（必须改，非意外回归）**：`--page-extent-nil-fallback` 原断首页 Y1 = `800.0`（在该夹具 page-scale = frame-scale = 1.0 时恰好等于真实页高），修后为常量 `1.0e7`——这正是 F1 的直接后果（比例不可用即不采信 own），已改写该用例并在 docstring 写明：这是「多页 + 无 redisplay 信息」的降级路径，「过长无害」；真机拖拽永远有 redisplay 信息（`posn-object-width-height` 可用），不命中此路径。

#### F2（minor）`--anchor-segment` 五元组的页号合法性收紧

- **做法**：五元组分支（len = 5 且五个元素都是数字）加 `(when (integerp (nth 0 rect)) …)`，浮点页号（`1.0`）返回 nil（坏段，由调用方跳过）；docstring 补「页号必须整数」的理由——写入端 `(format "page:%d" …)` / `(format "rect@%d:…" …)` 遇浮点会抛 `wrong-type-argument` 打断整条批注创建，解析端读回的页号也是 `[0-9]+` 口径的整数。
- **新增断言** `--anchor-segment-rejects-float-page`（annotation-cross-page-location-test 19 → 20）：`(1.0 10 20 30 40)` → nil；列表入口混入坏段只跳坏段、整数五元组行为不变；四元组「用 PAGE 补齐」口径不变；`--anchor` 对纯浮点页号段**不抛错**、退化为页级锚 `"page:1"`；混合入参只写整数段（`"page:2;rect:10.00,20.00,30.00,40.00"`）。

#### F3（minor）`--join-page-texts` 多页拼接的首尾空段

- **做法**：多页分支先 `cl-remove-if` 掉 nil 与空串再 `mapconcat`，过滤后为空则返回 nil；**单页分支原样**（`(car texts)`，不 trim、不过滤），维持单页逐字节回归。
- **新增断言** `--join-page-texts-drops-empty-pages`（select-cross-page-test 同批新增第 2 例）：纯函数层覆盖首页无文本（`"b\nc"`）、末页无文本（`"a\nb"`）、空串与 nil 一视同仁、全空 → nil、单页 `""` 与 `" a "` 原样返回；端到端用三页夹具（首页 `--text-in-rect` 返回 nil）断言 `seshat-reader-select-extract` 返回 `"b\nc"` 且 `seshat-reader-select-last` 的 `:text` 同为 `"b\nc"`（无前导换行）。

#### F4（nit）`--anchor` docstring 补两种降级的差异

- 补一段：D7 段数超限降级保留**页号最小页**（`pages:<a>-<b>` 的 a）、D5b 引用链接降级保留**起点页**（`page:<起点页>`），两者语义不同且各自自洽；反向拖拽（起点在较大页号页）时同一选区可能落到不同页，是预期行为而非缺陷。纯 docstring，无代码改动、无需新断言。

#### 本轮验证（真实输出）

| 项 | 命令 | 结果 |
|---|---|---|
| 改动文件单跑 | `emacs --batch -Q -L emacs -L emacs/seshat-reader … -l ert -l <file>` | `select-cross-page-test`：**`Ran 19 tests, 19 results as expected, 0 unexpected`**；`annotation-cross-page-location-test`：**`Ran 20 tests, 20 results as expected, 0 unexpected`**（各 +2 / +1 = 新增 3 例） |
| 相关回归文件（逐文件） | 同上 | `periphery-test` 22、`annotation-test` 58、`annotation-decoration-test` 21、`etaf-test` 20、`reference-test` 95 —— 全部 **0 unexpected** |
| L2 全量 | `make -C emacs/tests ert` | **`FILES=35 TOTAL=1316 UNEXPECTED=0`**，EXIT 0（= 1313 + 新增 3 例；文件数不变；无 skipped） |
| L2 判据 | `make -C emacs/tests check-criteria` | **PASS**（四条假汇总行：2 通过、2 拒绝，与预期一致） |
| L1 编译 | `make -C emacs/seshat-reader clean all` | **EXIT 0**，`Warning:` **20** 条（= 基线，**零新增**；无一条指向 `select.el` / `annotation.el`） |
| L1 checkdoc | `make -C emacs/seshat-reader checkdoc` | **0 报错**（无输出，EXIT 0） |
| L1 括号 | 宿主 `emacs -Q --batch` + `check-parens` | `select.el` / `annotation.el` / 两个测试文件 全部 **OK** |
| 零越界 | `git diff --name-only -- 'emacs/seshat-reader/render/**' 'internal/**' 'android/**'` | **无输出**；同口径 `git status --porcelain`（含 untracked）亦**无输出** → C 侧 / 服务端 / Android 零改动 |

**改动量**（相对安全点 `70e90ff9`）：`seshat-reader-select.el` +47/−13（F1 + F3）、`seshat-reader-annotation.el` +21/−5（F2 + F4）；两个测试文件是 untracked（17 → 19 例、19 → 20 例）。计划文件另计。

#### 过程记录（偏差与踩坑）

1. **首轮跑测出现 2 unexpected，均为测试侧问题、非实现缺陷**：① `annotation-cross-page-location-test` 加载到**陈旧 `.elc`**（`load-prefer-newer` 默认 nil，Emacs 优先读 `.elc`）→ 改源码后必须 `make -C emacs/seshat-reader clean all` 再跑 ERT（与批次 1–4 同一顺序）；② 我自己的新用例两处笔误：把 `(cdr (assoc PAGE rects))` 当五元组取 `(nth 4 …)`（`cdr` 后只剩 `(X0 Y0 X1 Y1)`，页高是 `(nth 3 …)`），以及把 `--anchor-segment` 的返回值误写成「列表的列表」。两处已修。
2. **F2 的改法比「加一个 `integerp` 守卫」多一步**：若只把 `integerp` 并进五元组分支的 `and`，浮点页号会**落回裸 rect 分支**（`(>= len 4)` 且前四个是数字）→ 页号变 x0、Y1 丢弃，等于把 F2 改造成新的数据损坏。故改为「len = 5 且五个元素都是数字」时**独占**该分支，页号非整数直接 nil、不下坠；`(1 10 20 30 "x")` 这类「五元素但第五个不是数字」仍按旧口径走裸 rect（行为不变）。
3. **本轮未动文档**：F1 / F3 只影响降级路径的取值（页高上限、空页拼接），`docs/api.md` / `docs/emacs-reader.md` 未就这两条写过具体数值，逐条核对后无需同步；`CHANGELOG.md` 亦不加条目（审查修复，不新增功能）。
4. **`:text` 首尾空段的另一个可能来源未动**：`seshat-reader-select--report` 自己 `string-trim` 后计数（提示不显示首尾换行），而 `:text` 与 `selected_text` 走的是本函数结果——F3 修在拼接点即可，`--report` 无需改。

### 真机缺陷修复：`overlayp nil` 崩溃 —— 2026-10-27

> 触发：用户第 1 轮真机验收（拖选取文）。**本批打破 D8「C 侧零改动」**，理由见下文「偏差」小节——P1 遗留缺陷直接阻断本轮核心功能（跨页取文选不到一个字），不修则整个 P2-A 不可用。

#### 现象与 backtrace（用户真机原文）

```
seshat-reader-select-extract: Wrong type argument: overlayp, nil [3 times]
```

关键帧：

```
overlay-buffer(nil)
seshat-reader-dyn--text-in-rect(3 98.85 318.32 271.19 321.46)
seshat-reader-select-extract(...)
```

#### 两个 bug 的机制

**Bug 1（防御失效，`render/elisp-helpers.c`）——用指针相等比较 `emacs_value`**

`elisp-helpers.h:26` 定义 `#define EMACS_NIL env->intern(env, "nil")`，而：

- `check_current_overlay`（原 `:425`）写 `if (overlay == EMACS_NIL) return false;`
- `get_current_doc_overlay`（原 `:453`）写 `if (current_overlay != EMACS_NIL && …)`

`emacs_value` 是不透明**句柄**，模块 API 只保证 `env->eq` 能正确判定两个句柄是否同一个 Lisp 对象；句柄本身的 `==` 在 Emacs 的实现里通常成立（同一符号的句柄多被缓存/复用），但**语义上没有保证**。更重要的是它掩盖了第二层问题：nil 真的到达时比较**漏判**，于是 `check_current_overlay` 不早退、继续执行 `overlay-buffer(nil)` → `(wrong-type-argument overlayp nil)`，连原本设计的「Invalid overlay state: reinitializing」提示都到不了。

修法（两处，全仓已无其它裸比较）：

```c
if (env->eq(env, overlay, EMACS_NIL))                                     /* :425 */
        return false;
if (!env->eq(env, current_overlay, EMACS_NIL) && !check_current_overlay(…)) /* :453 */
```

`grep -rn "== *EMACS_NIL\|!= *EMACS_NIL\|== *EMACS_T\|!= *EMACS_T"`（含反向写法、含 `EMACS_T`）在 `emacs/seshat-reader` 全仓**只有上述两处**；`EMACS_NIL` 宏本身未改（别处 `env->eq(env, x, EMACS_NIL)` 的用法是对的）。

**Bug 2（前提错误，`render/render-core.c` 的 `prepare_rect_query`）——矩形查询不该要求 overlay**

原实现经 `get_reader_current_state(env, &doc_state, &win_state, &overlay)` 取状态，而该函数要求**selected window 的 `overlay` 窗口参数**存在且 `check_current_overlay` 通过。P1 的多页布局里拖选**刻意不 `select-window`**（`seshat-reader-select-drag` 的 docstring 明写：整段手势在**被拖窗口的 buffer** 里执行，C 侧文本抽取按 buffer-local 的 `seshat-reader-current-doc-state-ptr` 解析文档；`select-window` 会移动 point 并打断像素滚动驻留），窗口上也不再有 overlay。于是：

- 只修 Bug 1 → 不再崩溃，但 `--text-in-rect` **静默返回 nil**（该函数的早退刻意不 `message`，因为调用方可能在 redisplay 中）→ 拖选「一个字符也取不到」，比崩溃更难排查；
- 两者都修 → 取文恢复。

修法：`prepare_rect_query` 改为只依赖 buffer-local 文档指针：

```c
DocState *doc_state = get_doc_state_ptr(env);   /* 读 buffer-local 变量 */
if (!doc_state) return false;                   /* 保持静默（redisplay 中） */
if (doc_state->is_reloading) return false;      /* 只用 doc 侧标志 */
```

页号范围校验、`rect_to_page_space` 换算、非有限坐标拒绝**逐字未变**；`win_state->closing` 检查删除（不再有 `win_state`）。`get_reader_current_state` 本体及其它 10 处调用者（旧翻页 / 显示族，P1 后已无 elisp 调用者）**一律未动**，`init_overlay` / `init_win_state_ptr` 未动。

**调用者复核（3 个，全部通过）**：`emacs_text_in_rect`（`:2327`）/ `emacs_rects_in_rect`（`:2367`）/ `emacs_lines_in_rect`（`:2411`）只使用 `prepare_rect_query` 输出的 `doc_state` / `page_number` / `rect` 三个值，**没有任何一个**读 `win_state` 或 `overlay`；`grep -n "prepare_rect_query"` 的 4 处命中即「1 定义 + 3 调用」，无遗漏。

#### 新增 ERT（`emacs/tests/seshat-reader-rect-query-overlay-test.el`，7 例）

夹具照 `seshat-reader-page-spec-test.el`：`module-load` 仓库内真实 `seshat-render-core.so`、真实 PDF（`/usr/share/doc/ghostscript/Ghostscript.pdf`，477 页）、`image-flush` 绑 `ignore` + `unwind-protect` 恢复。**关键差别**：既有 select 相关套件一律 `cl-letf` 桩掉 `seshat-reader-dyn--*`，覆盖不到 C 侧状态解析，所以本套件必须走真实模块。

| 用例 | 断言 |
|---|---|
| `--text-without-overlay` | `(set-window-parameter (selected-window) 'overlay nil)` 后 `--text-in-rect` 返回**非空字符串**、且不 signal |
| `--rects-without-overlay` | 同上条件下 `--rects-in-rect` 返回非空四元组列表 |
| `--lines-without-overlay` | 同上条件下 `--lines-in-rect` 返回非空列表（老 `.so` 无该入口时 `skip-unless`） |
| `--foreign-overlay-no-signal` | 窗口 overlay 换成**别的 buffer 的 overlay**（真机崩溃链的精确前置：`check_current_overlay` false → 清参数 → 返回 nil → 旧代码把 nil 喂给 `overlay-buffer`），断言不抛 `overlayp` 且仍取到文本 |
| `--overlay-state-is-irrelevant` | 同一矩形在「无 overlay」与「本 buffer 普通 overlay（无 `win-state` 属性）」两态下返回值 `equal` |
| `--no-doc-state-returns-nil` | 无 buffer-local 文档指针时三个入口**静默返回 nil、不报错**（守住早退的静默语义） |
| `--page-selection-without-overlay` | 无 overlay 时上层入口 `seshat-reader-select--page-selection`（真机 backtrace 里 `select-extract` 的直接被调者）返回 `((1 TEXT RECTS))` 且 TEXT 非空、RECTS 非 nil，顺带覆盖「1-based → 模块 0-based」换算 |

**红绿证据（同一份用例跑三个构建，真实输出）**：

| 构建 | 结果 |
|---|---|
| 修复前（HEAD 的 `render/`，配当前 `.el`） | `Ran 6 tests, 1 results as expected, **5 unexpected**`；失败原因原文 `(wrong-type-argument overlayp nil)`——与真机报错同一错误，崩溃被**离线复现**（当时只有 6 例；第 7 例是此后追加的上层入口用例，走同一条 C 路径，未再重跑旧构建） |
| 只修 Bug 1（`elisp-helpers.c` 修、`render-core.c` 保留原样） | `Ran 6 tests, 2 results as expected, 4 unexpected`；不再报 `overlayp`，改为 `(should (stringp text)) :form (stringp nil) :value nil`，即**静默取不到文**（这正是「必须同时修 Bug 2」的直接证据） |
| 两者都修（本批最终态，7 例） | `Ran 7 tests, 7 results as expected, 0 unexpected` |

顺带暴露了单测强度问题：`--overlay-state-is-irrelevant` 在「只修 Bug 1」时**也通过**（两态都返回 nil，`equal` 成立）——「两态一致」本身不足以证明功能正常，必须配「非 nil」断言，故两者同时保留。

#### 本批验证结果（真实输出）

| 项 | 命令 | 结果 |
|---|---|---|
| L1 编译 | `make -C emacs/seshat-reader clean all` | **EXIT 0**，`Warning:` **20** 条（= 前序批次基线，**零新增**；无一条指向 `render/*.c`，C 侧 0 warning） |
| L1 checkdoc | 同上（`all` 内建） | **0 报错**（`grep -cE "First sentence\|First line is not"` = 0） |
| L1 括号 | 宿主 `emacs --batch -Q` + `check-parens` | `seshat-reader-search.el` **OK**；新测试文件 **OK**（C 文件不适用） |
| L2 全量 | `make -C emacs/tests ert` | **`FILES=37 TOTAL=1327 UNEXPECTED=0`**（= 前序批次 36 / 1320 + 本批新增 7 例；无 skipped） |
| L2 判据 | `make -C emacs/tests check-criteria` | **PASS**（四条假汇总行 2 通过 / 2 拒绝，与预期一致） |
| 零越界 | `git status --porcelain` 全量 | `internal/**` / `android/**` **无任何改动** |

> 基线订正：上一轮记录写「现基线 35 / 1316」，实测前序批次已是 **36 / 1320**（差值 1 文件 4 例 = 同批新增的 `seshat-reader-undo-test.el`，其用例在上轮统计之后才落盘）。本批在 1320 之上新增 7 例（`FILES` 36 → 37）。

#### 偏差

- **打破 D8「C 侧零改动」（批次 A 内）**。理由：P1 遗留缺陷使拖选取文在真机上 100% 失败（先是崩溃，修 Bug 1 后是静默空结果），P2-A 的核心交付「跨页取文」因此完全不可用；不修则本批次无法验收。改动范围严格限定在 `render/elisp-helpers.c`（2 处比较）与 `render/render-core.c`（`prepare_rect_query` 前半段），未动 `internal/**`、`android/**`、`VENDORED.md`，也未动 `get_reader_current_state` 本体与旧翻页 / 显示族调用者。`docs/api.md` 原写「本轮未改动 C 侧」已按实修正。
- **一处计划外的小改**：`seshat-reader-search.el` 的注释（非代码）原写「`--lines-in-rect` / `--text-in-rect` 先经 `get_reader_current_state` 校验……overlay 的 buffer 还必须等于 `(current-buffer)`」，修复后该表述失真，改为「只读 buffer-local 文档指针 + 为何必须在阅读 buffer 里调用」。同口径同步了文档：`docs/api.md` §4.5.3 原「本轮未改动 C 侧」段落改写为「真机缺陷修复」+ 新增「矩形查询的 buffer 归属要求」两条；`openspec/tech-debt.md` 的「C 侧单页 overlay 机制仅剩兼容外壳」标注为已解决（并说明为何保留剩余外壳）；`CHANGELOG.md` 的 P2-A 条目原「C 侧零改动」按实修正，另在「### 修复」新增一条本缺陷的完整记录。
- **未修的地方（有意）**：`elisp-helpers.c` 的 `overlay-put` 处仍无 nil 守卫——该路径已无 elisp 调用者，加守卫等于给死代码加分支；`init_overlay` / `init_win_state_ptr` / `--refresh-highlights` 等兼容外壳保留，`--window-close` 仍要释放 `EmacsWinState`。

#### 仍需真机复核

1. **必须重新构建 `.so` 并重启 Emacs**（已加载的 C 模块不能热重载）——否则跑的还是旧模块，崩溃照旧。
2. 拖选取文（单页 / 跨页）恢复到「有字」，且高亮位置不变。
3. 顺带确认搜索侧栏的片段取文仍正常（同一族入口，`prepare_rect_query` 变更后行为应逐字不变；batch 下已由 `seshat-reader-search-test.el` 的桩用例与本次真实模块用例双侧覆盖）。

### T9 真机验收（用户）—— 2026-10-27

**用户报告**：`overlayp nil` 崩溃修复后「生效了」——即修复后拖选取文可用、不再报错。

**未逐项确认**（不视为通过，转「使用中观察」）：

- ② 跨页批注高亮在两页都落在正确位置
- ③ `C-c C-l` 列表页码显示 `a-b` 且 `RET` 跳到首页
- ④ 旋转 90° / 180° / 270° 后框选，高亮与选区一致
- ⑤ 旋转页 + 跨页组合
- ⑥ 旧批注（旧形态）高亮位置不变
- 批次 4 的两个补充观察点：ETAF 卡片页码 `p.1-2`、500 段降级时的 `*Warnings*` 提示

**已有 tech-debt 覆盖、不另立案的残余项**：

- 跨页选区确认时的闪现（flash）只落起点页
- Android `LocationCodec` 不解析 `pages:`（无高亮、不崩溃）
- `--page-space-size` 的单位口径靠起点页 `extent / native` 比例标定（`frame-scale` 相关）

**结论**：功能可用，残余项不阻塞归档；上述未确认项在后续使用中观察，出问题再单独立项。

