# Emacs 32 canvas：S0 可行性 spike（只读验证，不改仓库代码）

## 当前状态
- 阶段：Phase 4（Review & Document）· spike 已完成，待决策
- 已确认：方案 ✅（用户 2026-10-28 确认「先验证」）、计划 ✅（用户 2026-10-28 确认执行）
- 修订历史：v1 被 plan-reviewer 判「需修订（3 阻塞）」→ v2 修订后复审**通过**
- 执行结果：T1–T5 全部完成；五项假设 4 成立 / 1 被推翻（H1），详见「## 验证结果」
- 下一步：三项未验证项已于 2026-10-28 同日补齐（结论见 `openspec/decisions.md` 的 2026-10-28 条目「补充验证」段）→ 可进入实现阶段（方案 B：canvas 传输层替换）

## 目标
用一次真机 GUI 验证回答五个「未验证假设」，据以决定 canvas 能否替代 seshat-reader 现有 PBM 渲染管线。**本计划不改仓库任何源码**：探针模块与脚本全部放在 `/tmp`，验证结束即删除。

## 背景（已取证事实，非推测）
- 本机 Emacs 32.0.50，pgtk 编译；`canvas` 为编译期内置类型（batch 下 `image-type-available-p 'canvas` = t）。
- canvas spec 必需属性是 `:data-width` / `:data-height` / `:id`，**不支持** `:width` / `:height`（实测 `(create-image v 'canvas t :width 4 :height 4)` → `Invalid image specification`）。
- `canvas-refresh` 签名 `(image &optional reload-data)`，**无局部区域刷新**（实测 arity 与 `wrong-number-of-arguments 6`）。
- 模块 API：`uint32_t *(*canvas_data)(emacs_env*, emacs_value canvas)`，ARGB32 行主序裸指针，仅 canvas 存活且尺寸未变时有效（`/usr/include/emacs-module.h:1475-1481`）。
- `image-size` 在 batch 下必失败（`Window system frame should be used`）→ 必须真实 GUI frame。
- 现有渲染链路每页 3 份位图 + PNM 编码 + 两次拷贝（`render-core.c:345/653-660/690-698`、`elisp-helpers.c:160`）；装饰刷新 = 重渲染全部驻留页（`seshat-reader.el:1728-1768`）；缩放靠 `setf :width/:height`（`:1444-1455`）。
- 用户正在用的 `thomas` daemon 是 **headless**（`emacsclient --eval` 报 `Frames are not in use or not initialized`），不能做 GUI 验证；`server39209` 是用户真实 GUI 实例，**本 spike 不得触碰**。

## 待验证假设
| # | 假设 | 来源 | 证伪后果 |
|---|---|---|---|
| H5 | canvas spec 的尺寸能参与 `(space :align-to (+ center (-0.5 . SPEC)))` 计算，居中与 pbm 等价 | 假设? | P1 全部居中几何代码需重写 |
| H1 | canvas 无法承担浮点显示层缩放 | 事实✓（手册 + batch 实测 `:width/:height` → Invalid） | 若 H1 被推翻（canvas 能靠某属性缩放），缩放路径可不重渲染 |
| H4 | 主线程取 `canvas_data` 指针 → 后台线程写入 → 主线程 `canvas-refresh` 安全 | 假设? | 若不安全，worker 需写中间缓冲 + 主线程再 memcpy（收益减半） |
| H7 | 改 `:data-width/:data-height` 后旧指针失效 | 假设?（手册称会重建缓冲） | C 侧任何缓存指针必须作废重取 |
| H8 | `emacs -Q`（pgtk）在本 WSLg 环境能首次即出窗 | 假设?（同环境既有 GUI 实例正常，但本进程未实测） | 若无法出窗，S1/S2/S3 全部记「无法判定」，需改由用户手动跑 |

## 设计
**完全隔离**：不加载、不修改 `emacs/seshat-reader/` 任何文件；不改 `Makefile`；不影响用户正在使用的 Emacs（`server39209` / `thomas`）。

1. **探针模块** `/tmp/canvas-probe/canvas-probe.c`（最小 emacs 模块，`#include <emacs-module.h>`，`gcc -shared -fPIC -o canvas-probe.so`，无需 MuPDF）导出三个函数，**每个都返回读回值以自证写入生效**：
   - `probe-fill-sync(env, canvas, argb)`：主线程取 `canvas_data` → 全缓冲填 `argb` → 读回首像素 → `canvas-refresh`；返回 `(耗时微秒 . 首像素读回值)`。
   - `probe-fill-thread(env, canvas, argb, iters)`：主线程取指针 → 起 pthread 写缓冲 → join → 主线程读回首像素 → 主线程 `canvas-refresh`；重复 `iters` 次（默认 100），返回 `(最少微秒 中位微秒 最多微秒 读回一致次数/总次数 异常信息)`。
   - `probe-ptr-identity(env, canvas)`：返回当前 `canvas_data` 指针的整数值（供改尺寸前后比对）。
   安全阀：任何一步取到 NULL 立即返回 nil 而不解引用。**模块内不得缓存跨调用的指针**。
2. **spike 脚本** `/tmp/canvas-probe/canvas-spike.el`：`-Q` 干净环境。**每个 S 段完成后立即追加落盘**（`(write-region (prin1-to-string rec) nil RESULT t)`），崩溃前已完成段仍可读：
   - **S1（居中）**：程序化生成**同源 400×300 纯白图**——pbm 用文本 `P1` + `400 300` + 120000 个 `0`；canvas 用 `(make-vector (* 400 300) #xFFFFFFFF)` + `:data-width 400 :data-height 300`。在**同一个 window** 里先后插入 `(concat (propertize " " 'display '(space :align-to (+ center (-0.5 . SPEC)))) (propertize " " 'display SPEC))`，先 `(redisplay t)` 并 `(accept-process-output nil 0.05)` 等布局，再用 `(window-text-pixel-size nil (point-min) IMG-POS)` 取「行首→图像字符前」的像素宽度作为**居中起点**；同时记录窗口实际像素宽度。不写死 600px。
   - **S2（缩放）**：对 canvas spec 依次做 a) `(setf (image-property spec :width) 200)`（`:height` 同改），b) `(setf (image-property spec :data-width) 200)`，每步 `(image-size spec t)` 与 S1 同一测量，**每步用 `condition-case` 区分「返回尺寸」与「报错」**。
   - **S3（跨线程写入）**：对 400×300 canvas 跑 `probe-fill-thread` 100 次（每次不同 ARGB 色值），记录耗时与「读回一致次数」。仅以「无崩溃 + 无 NULL + 读回值 == 写入值 + refresh 无异常」为据；**「屏幕是否真的重绘」不可程序化验证，不列入判据**。
   - **S4（指针失效）**：`probe-ptr-identity` → `(setf (image-property spec :data-width) 200)` → `probe-ptr-identity` 比对。
   - 结果文件 `/tmp/canvas-probe/result.sexp`（每行一条 `(:spike S1 :status ok ...)` 记录）；段内异常只记 `:status error :msg ...`，不中断后续段。
3. **执行**（注意 `timeout` 必须是**命令内前缀**，`shell_command` 的 `timeout` 参数对 background 作业无效）：
   ```
   timeout 180 emacs -Q --name canvas-spike -L /tmp/canvas-probe \
     --eval '(progn (load "/tmp/canvas-probe/canvas-spike.el") (kill-emacs 0))' \
     > /tmp/canvas-probe/run.log 2>&1
   ```
   以 `background` 启动；会短暂弹出 WSLg 窗口（脚本 `kill-emacs` 后即关），不注册 server、不碰用户实例。
4. **判定**：按每项量化判据出「成立 / 被推翻 / 无法判定」，给出架构建议（方案 A / 方案 B / 混合）。

## 任务
- [x] T1 建 `/tmp/canvas-probe/` 并写 `canvas-probe.c`（三函数 + NULL 守卫 + 读回值），`gcc -shared -fPIC` 编译通过（验收：`.so` 非空、`nm -D canvas-probe.so | grep -c "probe_"` = 3）
- [x] T2 写 `canvas-spike.el`（S1–S4 四段 + 逐段即时落盘 + `condition-case`），两道验收：① `emacs -Q --batch -l canvas-spike.el` 加载无错且 `check-parens` 通过；② `emacs -Q --batch --eval '(module-load "/tmp/canvas-probe/canvas-probe.so")'` 成功（提前隔离 ABI/编译问题）
- [x] T3 以 background 启动 GUI 进程执行 spike，收集 `result.sexp` 与 `run.log`（验收：进程退出（正常或崩溃均可）、`result.sexp` 存在且**至少含已完成段**、`run.log` 可读）
- [x] T4 按判据给出五项结论 + 架构建议，写入本文件新增的「## 验证结果」节（验收：H5/H1/H4/H7/H8 各有 成立/被推翻/无法判定 + 证据数值；若 S3 崩溃导致 S4 未执行，S4 记「无法判定（进程在 S3 崩溃）」；含「建议方案 A / 方案 B / 混合」明确结论）
- [x] T5 清理 `/tmp/canvas-probe/`、确认无残留 emacs 进程（`pgrep -af canvas-spike` 为空）、`git status --porcelain` 仅含本计划文件（验收：三项全绿）

## 验证标准
| Spike | 判据（三分支以上，避免空判据） |
|---|---|
| S1 | 同一 window（记录实际像素宽）内，pbm 与 canvas 的居中起点**差 ≤ 1px** → H5 成立；差 > 1px，或 canvas 侧 `:align-to` 求值报错/图像未居中 → H5 被推翻；测量抛错无法取值 → 无法判定（记错误原文） |
| S2 | a) `setf :width/:height` 后 `image-size` 尺寸**不变** → H1 成立（属性被忽略）；b) 该 `setf` 或 `image-size` **报错**（`Invalid image specification` 等）→ H1 成立（属性被拒）；c) 尺寸**随之变化** → H1 被推翻（记录 canvas 可用的缩放通道名）；另记录 `:data-width` 变化后的 `image-size` 结果作为「canvas 唯一尺寸通道」事实 |
| S3 | `probe-fill-thread` 100 次：无崩溃、无 NULL、**读回值 100/100 与写入值一致**、`canvas-refresh` 无异常 → H4 成立；崩溃 / 出现 NULL / 读回不一致 → 被推翻（崩溃在独立进程内，崩溃本身即结论）。「屏幕是否重绘」不验证 |
| S4 | 改 `:data-width` 前后 `probe-ptr-identity` 返回值**不同** → H7 成立（指针失效，必须重取）；**相同** → 与手册不一致（记录，按「实测优先」处理并要求后续实现每次重取）；因崩溃未执行 → 无法判定 |
| H8 | `run.log` 中出现 `(window-system)` 非 nil 或结果段正常取值 → 出窗成功；`timeout` 到期无结果 / run.log 出现 Wayland 连接错误 → 无法出窗（S1/S2/S3 记无法判定，改走用户手动跑） |

## 风险与回滚
| 风险 | 处置 |
|---|---|
| 探针模块写野指针 segfault | 独立 `-Q` 进程，不影响用户 Emacs；崩溃即 S3/S4 证据；逐段落盘保证已得结论不丢 |
| WSLg 窗口遮挡用户桌面 | 脚本结束自 `kill-emacs`；命令内 `timeout 180` 兜底；窗口停留 ≤ 数十秒 |
| 误连用户实例 | 全程不使用 `emacsclient`；不以任何方式触碰 `server39209` / `thomas` |
| `emacs -Q` 无法出窗（H8） | 判据写明降级路径：记无法判定 + 建议改由用户手动 `M-x load-file` 跑同一脚本 |
| 模块编译失败 / `module-load` 失败 | T1/T2 失败即停，不进入 T3；报告错误原文 |
| 临时文件残留 | T5 显式清理并核对 |
| 仓库被误改 | 本计划只新增一个 `openspec/active/*.md`；T5 用 `git status --porcelain` 核对 |

## 文档清单
本 spike **不产生**产品文档变更（未改源码）。验证结论写入本文件；若结论建议改架构，则在后续实现计划中同步 `docs/architecture.md`（M12 节）、`docs/emacs-reader.md`、`emacs/seshat-reader/VENDORED.md`、`CHANGELOG.md`、`openspec/decisions.md`、`openspec/tech-debt.md`（与 P2-5 归并）。

## 注意事项
1. **不改仓库代码**：探针必须独立于 `emacs/seshat-reader/`；不重编译现有 `.so`（其与 32 的 ABI 兼容性不在本 spike 范围内，属后续实现阶段的独立门禁）。
2. **不碰用户 Emacs**：禁止 `emacsclient`；禁止在 `server39209` / `thomas` 里 eval。
3. **只用 `-Q`**：避免加载用户配置触发 `server-start` 冲突与 LSP 子进程。
4. 任一 S 项「无法判定」必须写明原因（错误原文或 timeout），不得用推测填补。
5. 结论若与既有 `decisions.md`（2026-10-23「显示层缩放替代同步重渲染以消除两帧」）冲突，须在「## 验证结果」里显式点出冲突点。
6. S1 判据**不写死窗口宽度**，改为「同一 window 内两种 spec 对比 + 记录实际像素宽」；测量前必须 `(redisplay t)` + `(accept-process-output nil 0.05)`，否则 layout 未完成会测到空值。
7. **不缓存跨调用指针**：`probe-ptr-identity` 仅用于比对，绝不在 elisp 侧保存指针值供后续使用。

## 验证结果

**执行环境**：Emacs 32.0.50（pgtk，WSLg），独立 `emacs -Q --name canvas-spike` 进程（不触碰用户 `server39209` / `thomas`）；探针模块与脚本全程在 `/tmp/canvas-probe/`，未改仓库源码。

### 判定汇总

| # | 假设 | 判定 | 关键证据 |
|---|---|---|---|
| H5 | canvas 可参与 `:align-to` 居中，与 pbm 等价 | **成立** | pbm `offset 160` vs `(body-px 720 − 400)/2 = 160`（精确吻合）；canvas `offset 156` vs `(713 − 400)/2 = 156.5`（精确吻合）。两值差 4px 由两次测量间窗口宽差 7px（`win-px` 752 vs 745，pgtk 自适应 resize）解释 |
| H1 | canvas 不能做浮点显示层缩放 | **被推翻** | `setf :width 200 :height 150` → `image-size` = `(200 . 150)`，居中 `offset 256 ≈ (713−200)/2` → canvas 接受 `:width/:height` 并按缩放尺寸参与排版 |
| H4 | 主线程取指针 → 线程写 → 主线程 refresh 安全 | **成立** | `probe-fill-thread` 100 次：中位 89µs（80–211µs），读回 100/100 与写入值一致，无崩溃、无 NULL |
| H7 | 改 `:data-width/height` 后旧指针失效 | **成立** | 400×300 → 800×600（扩大）后指针 `98410851808144` → `98410854208224`（+2.4 MB，新缓冲 1.92 MB），重取后可正常写入（`fill-after-grow` 读回一致） |
| H8 | `emacs -Q` 在 WSLg 能出窗 | **成立** | `(:spike DONE :emacs-version "32.0.50" :display (pgtk t))`，`run2.log` 0 字节无警告 |

### 原始数据（GUI 复跑，`result2.sexp` 全文）

```
(:spike S1 :spec pbm :status ok :offset 160 :prefix 160 :line-px 560 :body-px 720 :win-px 752 :img-pos 2 :image-size (400 . 300))
(:spike S1 :spec canvas :status ok :offset 156 :prefix 156 :line-px 556 :body-px 713 :win-px 745 :img-pos 2 :image-size (400 . 300))
(:spike S2 :step "a-width-height" :setf ok :size (200 . 150) :measure ok :offset 256 :prefix 256 :line-px 456 :body-px 713 :win-px 745 :img-pos 2 :image-size (200 . 150))
(:spike S2 :step "b-data-width" :setf ok :size (200 . 150) :measure ok :offset 256 :prefix 256 :line-px 456 :body-px 713 :win-px 745 :img-pos 2 :image-size (200 . 150))
(:spike S3 :status ok :thread (80 89 211 100 100 nil) :sync (12 . 4278255360) :argb-written-thread 16 :argb-written-sync 4278255360)
(:spike S4 :status ok :ptr-before 98410851808144 :setf-data-width ok :setf-data-height ok :ptr-after 98410854208224 :changed t :size (800 . 600) :fill-after-grow (16 . 4278255360))
(:spike DONE :emacs-version "32.0.50" :display (pgtk t))
```

### 判据修正（必须与结论一起读）

1. **S2 的 b 步证据不干净**：`:size (200 . 150)` 受前一步 `:width/:height` 残留影响，不能单独证明 `:data-width` 影响显示尺寸。干净证据来自 S4（新建 400×300 canvas → `setf :data-width 800 :data-height 600` → `:size (800 . 600)`）。
2. **S1 的 `win-px` 两次不同**（752 vs 745）是事实，非测量错误；用 `(body-px − 400)/2` 归一后两者均精确居中。
3. **首轮失败与修复**：v1 脚本第 78 行 `(propertize " " 'display` 未闭合，第 80 行成为外层第 4 实参 → 运行时 `wrong-number-of-arguments propertize 4`，S1/S2 无测量值。`check-parens` 与 batch 加载均通过（整体括号平衡）——**语法检查不能替代执行**。v2 用 `(cons -0.5 spec)` 构造 dotted pair 消除反引号嵌套后修复。

### 未验证项的补充验证结果（2026-10-28 同日补齐）

| 项 | 结论 | 关键证据 |
|---|---|---|
| `:width/:height` 缩放质量 | **与 pbm 逐字节等价，无退化** | `compare -metric AE = 0`（canvas vs pbm，放大/缩小均相同）；默认 `transform-smoothing=nil` → 放大 2x 与缩小 0.5x 整块仅 2 色（格子周期 16px / 4px 硬边）；`:transform-smoothing t` → 放大 6–10 色、缩小 18 色（平滑生效）；0.5x 后四角色块齐全 → **非裁剪** |
| ARGB 通道序与 alpha | **通道序正确、alpha 正常** | `0xFFFF0000`→`255,0,0`、`0xFF00FF00`→`0,255,0`、`0xFF0000FF`→`0,0,255`；50% 红叠白 = `#FF7F7F`；`0x00000000` 区露背景 |
| 异步渲染下 GC 与指针 | **安全** | worker 延迟 300ms 写缓冲期间，主线程 4×`garbage-collect` + 2 万 cons + 2×`redisplay`（施压 421ms/561ms）后两轮读回均 = `0xFFAABBCC`，`canvas-refresh` 无错 |
| 新增硬约束 | `setf :data-width` 重建缓冲后内容清零（首像素读回 `0`） | resize 后必须重画整页，不能假设内容保留 |

**方法论提示**：上述像素结论均基于「整块统计 + 以 8px 棋盘周期反推样本身份 + 逐字节模板匹配确认 crop 落点」。首轮曾用固定 60×60 采样窗判定，因导出图系统偏移（dx=−26, dy=−23）采到相邻的 smoothing on/off 变体，得出「同一配置 10 色 vs 2 色」的自相矛盾数据，经离线复核纠正。

### 架构建议

1. **第一步走方案 B**（传输层替换：PNM → ARGB32 直写 canvas 缓冲）：纯收益（省 PNM 编码 + `make_unibyte_string` 拷贝 + Emacs PBM 解码 + 两份位图），且 H1 被推翻意味着现有 `setf :width/:height` 显示层缩放手法可原样保留（`seshat-reader.el:1444-1455` 逻辑不变）。
2. **第二步评估方案 A**（C 侧保留未装饰底图 + 装饰合成）：解决「改一条批注要重渲染全部驻留页」（`seshat-reader.el:1728-1768`），与 P2-5 内存问题合并解。
3. `--multipage-rerender-page` 幂等逻辑无需改动（canvas 与 pbm 同构：spec + `:width/:height`）。
4. **实现期硬约束**：`canvas_data` 指针**必须每次重新获取**（H7 成立），禁止跨调用缓存；`canvas-refresh` 无局部刷新（粒度 = 整张 canvas，故按页切分 canvas 是唯一增量手段）。
5. 与 `decisions.md`（2026-10-23「显示层缩放替代同步重渲染以消除两帧」）**无冲突**：H1 被推翻使该决策在 canvas 后端继续成立。
