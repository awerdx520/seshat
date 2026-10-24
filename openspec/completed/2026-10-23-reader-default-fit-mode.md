# 阅读器适配模式默认值（`seshat-reader-default-fit` 重定义）+ 真机批量观测清债

> **行号约定**：简写 `:NNN` 一律指 `emacs/seshat-reader/seshat-reader.el` 的第 NNN 行；其它文件一律以 `文件名:行号` 全名书写。全部行号取自 HEAD `ff03666` 的实测勘察（2026-10-23）。

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成并归档（2026-10-23）**
- 已确认：方案 ✅（用户 2026-10-23 确认，选定 M1 档）、计划 ✅（用户 2026-10-23 确认）
- 执行结果：T0–T3 代码与单测完成（全仓 ERT 384 → 397 例，0 unexpected / 0 skipped；L1 警告集 33 → 33）；T5 文档 8 项完成；T4 真机观测 4/5 项完成（T4-5 按用户 2026-10-23 决定不执行）；T6 归档完成
- 后续：观测中发现一个**新缺陷**（`revert-buffer` 后 buffer 保持 modified，与自动保存类包冲突）已记入 `openspec/tech-debt.md`，为下一个计划候选

## 目标

1. **消除配置面失真**：`seshat-reader-default-fit` 从「自动 fit 路径零调用点的 no-op」重定义为「新窗口 / 新文档的初始适配模式」（`contain` / `width` / `height`），旧函数符号值做兼容映射，现有配置不失效。
2. **明确「持久」的边界**：`W` / `H` 管当前窗口（会话内），defcustom 管新窗口起点；docstring / 文档 / UI 措辞统一，不再暗示 `W`/`H` 跨会话。
3. **一次真机批量观测清 4–5 条技术债**（L3-6、L3-8、`image-flush` 移除后的回收、image cache 峰值、strip 与 `before-string` 居中交互）。

## 根本问题与假设

**根本问题（两条独立）**：

1. **配置面失真**：`seshat-reader-default-fit`（`:106` defcustom）在自动 fit 路径上已无任何调用点——首次打开走 `--first-fit`（`:471`）→ `--contain-scale`（`:445`），尺寸变化走 `--fit-scale`（`:493`）的 `contain` 分支。用户改该选项无任何效果，属信任损失而非功能缺陷（tech-debt 已有两条记录：`:975-978`、`:1010-1013`）。
2. **偏好不跨会话**：`fit-mode`（`:484-491` 读取，`:431` / `:443` 写入）是 window parameter，窗口销毁即丢；重开文档 / 重启 Emacs 一律回到 `contain`。文档里「持久适配模式」的「持久」实际只覆盖单窗口生命周期。

| # | 假设 | 来源 |
|---|---|---|
| H1 | `seshat-reader-default-fit` 全仓零调用点，只有 defcustom 定义与一处 docstring 提及 | 事实✓（grep：定义 `:106`；唯一 docstring 提及在 `--contain-scale` 的 `:451`；defcustom 自身 docstring（`:107-114`）不含该符号名） |
| H2 | `fit-mode` 是 window parameter，不跨会话、窗口销毁即失 | 事实✓（`:484-491` 读取实现 + Emacs window parameter 语义） |
| H3 | 用户要的是「新窗口默认起点」，不是「`W`/`H` 自动持久」 | 用户显式（2026-10-23 选定 M1） |
| H4 | 旧值兼容映射可避免破坏：`fit-to-width` → `width`；`fit-to-height`（旧默认）→ `contain`；未知 → `contain` | 假设?（旧默认映射为 `contain` 才能对所有未改配置保持现状；**显式**把旧默认设成 `fit-to-height` 期望按高的用户会得到 `contain`，两种意图不可区分，须在 CHANGELOG 明示绕法：设 `height`） |
| H5 | `--first-fit` 执行时 `--native-page-size` 可得——`--render-buffer` 在 `seshat-reader-mode` 定义中先于 `--first-fit` 调用 | 假设?（`seshat-reader.el:1723-1738` 的顺序支持；T0 实测确认，不成立则由 `--fit-scale` 的 1.0 兜底 + `--apply-display-scale` 回退链覆盖） |
| H6 | 首次 fit 之外无其它路径读 `default-fit`；接入点只有 `--first-fit` 与新窗口创建 | 事实✓（grep 零调用点 + `--manage-window-overlays` 定义在 `:1526`（其体内 `:1533` 的 `mapc` 调用 `--window-create-function`）+ `--window-create-function` `:1535`） |
| H7 | `--window-create-function` 是新窗口建 overlay 的唯一入口 | 事实✓（`--manage-window-overlays` `:1533` + `--handle-window-buffer-change`） |
| H8 | 5 项真机观测可一次 GUI 会话完成 | 假设?（L3-8 需 `--daemon` + `emacsclient -c`，其余同会话） |

## 设计

### D1 重定义 `seshat-reader-default-fit`（`:106`）

值域从「函数符号」改为「模式符号」，默认 `contain`（= 当前实际行为，未改配置者零变化）：

```elisp
(defcustom seshat-reader-default-fit 'contain
  "The fit mode a reader window starts with.

One of `contain' (the whole page is visible: the smaller of the width
fit and the height fit wins), `width' (fill the window width, scroll
vertically) or `height' (fill the window height, scroll horizontally).

This is only the starting point.  `W' and `H' override it for the
window they are used in, and that choice is not remembered across
sessions: a new window starts from this value again.

Legacy function values are still accepted: `seshat-reader-fit-to-width'
means `width', while `seshat-reader-fit-to-height' (the former default)
means `contain', which keeps the behaviour of unmodified
configurations."
  :group 'seshat-reader
  :type '(choice (const :tag "Whole page (contain)" contain)
                 (const :tag "Fill width" width)
                 (const :tag "Fill height" height)))
```

**旧值映射表（写入 CHANGELOG 与 docstring，作为契约）**：

| 配置值 | 归一化结果 | 说明 |
|---|---|---|
| `contain` | `contain` | 新值；与改造前实际行为一致 |
| `width` | `width` | 新值 |
| `height` | `height` | 新值 |
| `seshat-reader-fit-to-width` | `width` | 旧值，保留用户显式意图 |
| `seshat-reader-fit-to-height` | `contain` | 旧默认值；映射为 `contain` 以保现状（不可区分「从未改」与「显式设为按高」） |
| 其它任意值 | `contain` | 未知值兜底，不报错 |

### D2 两个纯函数（新增，紧跟 `--contain-scale` 之后）

```elisp
(defun seshat-reader--normalize-default-fit (value)
  "Return VALUE as a fit mode symbol: `contain', `width' or `height'."
  (pcase value
    ((or 'contain 'width 'height) value)
    ('seshat-reader-fit-to-width 'width)
    ('seshat-reader-fit-to-height 'contain)
    (_ 'contain)))

(defun seshat-reader--initial-fit-mode (&optional window)
  "Return the fit mode WINDOW should start with.

WINDOW defaults to the selected one.  A window that already recorded a
mode keeps it; otherwise WINDOW starts from
`seshat-reader-default-fit', normalised through
`seshat-reader--normalize-default-fit'."
  (or (window-parameter (or window (selected-window)) 'fit-mode)
      (seshat-reader--normalize-default-fit seshat-reader-default-fit)))
```

### D3 `--first-fit`（`:471`）改按模式求 scale

```elisp
(defun seshat-reader--first-fit ()
  "Fit the page to the selected window the first time it is displayed.

The target scale follows the window's initial fit mode
\(`seshat-reader--initial-fit-mode'), which is recorded as the window's
`fit-mode' first so that later resizes keep using it.  Uses a
display-level rescale instead of a re-render, so the very first frame
already shows the page at its final size; the bitmap is rendered at the
new resolution by the debounced refit afterwards.  Falls back to a
synchronous re-render when the page spec is not available yet."
  (let ((mode (seshat-reader--initial-fit-mode)))
    (set-window-parameter nil 'fit-mode mode)
    (let ((target (seshat-reader--fit-scale)))
      (unless (seshat-reader--apply-display-scale (selected-window) target)
        (seshat-reader-doc-scale-page target 'fit))))
  (seshat-reader--center-page)
  (seshat-reader--schedule-refit))
```

- **默认值下行为等价**：`contain` 时 `--fit-scale`（`:493-512`）直接转调 `--contain-scale`，与原 `--first-fit` 完全一致，因此未改配置者零行为变化。
- **兜底链不变**：`--native-page-size` 不可得 → `--fit-scale` 返回 `1.0`；`--apply-display-scale` 返回 nil → 走 `doc-scale-page target 'fit` 同步重渲染。

### D4 新窗口写初值（`--window-create-function`，`:1535`，保守版 A）

在 `(unless (window-parameter window 'overlay)` 分支内、`(seshat-reader-dyn--window-create window)` 之前插入：

```elisp
      ;; 新窗口的适配模式起点：已有 fit-mode 的窗口（用户按过 W/H 或
      ;; 由 --first-fit 记录）不被覆盖。
      (unless (window-parameter window 'fit-mode)
        (set-window-parameter window 'fit-mode
                              (seshat-reader--normalize-default-fit
                               seshat-reader-default-fit)))
```

**几何不在创建时同步重算**，交给既有 idle refit（`--schedule-refit` 链，`--resize-refit-delay` 0.15s）按 mode 校正。取舍见「已知取舍」第 3 条。

### D5 不动清单（硬约束）

- `--window-fit-mode`（`:484-491`）保持「未设置 → `contain`」，实现不改。
- `--contain-scale`（`:445`）、`--fit-scale`（`:493-512`）、`--apply-display-scale`、`--recenter-window`、`--refit-window`、`--centered-p`、`--center-page`、四条 hook 注册行（`:1739` `window-size-change-functions`、`:1740` `window-configuration-change-hook`、`:1741` `window-buffer-change-functions`、`:1742` `pre-redisplay-functions`）**函数体零改动**。
- `seshat-reader-fit-to-height`（`:421`）/ `seshat-reader-fit-to-width`（`:433`）命令本体不动（它们已写 `fit-mode`）。
- C 模块、`seshat-reader-bookmark.el`（书签格式）、`seshat-reader-sidebar.el`、`seshat-reader-outline.el` **零改动**。
- **不做** `customize-save-variable`、不新增状态文件、不新增 defcustom（除 D1 的值域变更）。

### 已知取舍

1. **`W` / `H` 不自动持久**：不写用户 init、不新增状态文件；代价是「按一次 `W`，下次开新文档回到默认」。要在同一窗口内保持，`fit-mode` 仍生效（窗口存活期间）。
2. **旧默认值映射为 `contain` 而非 `height`**：保护未改配置的多数人；显式想要按高的用户需显式设 `height`（CHANGELOG 说明）。
3. **新窗口几何交给 refit（D4-A）**：新窗口首帧可能沿用恢复的 `scale`，0.15s 后按 mode 校正。理由：创建时 `native` 尺寸可能不可得，硬算会把页面设成 `1.0`，风险高于一帧延迟。
4. **书签恢复的窗口按 `seshat-reader-default-fit` 起步**：书签 jump 会打开文档并触发 `--first-fit`，因而写入的是 defcustom 的归一化初值（默认 `contain`）；只有默认值下才表现为「按 `contain` 起步」。书签格式不携带 `fit-mode`，与既有 tech-debt「书签恢复不携带缩放来源」（`tech-debt.md:986`）同族，不在本计划扩大范围。

## 任务

### [x] T0 基线与安全点 + 观测脚本符号核验

- 动作：① `cd emacs/seshat-reader && rm -f *.elc && make all 2>&1 | tee /tmp/before-default-fit.log`，统计 `grep -cE "Warning|Error"`（基线应为 33）；② 全仓 ERT 基线（11 个测试文件；**当前源码 `ert-deftest` 计数为 384，以本次实跑 `ert-run-tests-batch-and-exit` 的输出为准**，要求 0 unexpected / 0 skipped；把实跑数字与逐文件计数补写到本节末尾的「实测」行）；③ `git tag pre-reader-default-fit`；④ **只读**确认主实例里 `seshat-reader-default-fit` 的当前值（`elisp_mcp_set_task` 声明 `config`，`elisp_eval_expression` 求 `(list :bound (boundp 'seshat-reader-default-fit) :value (and (boundp 'seshat-reader-default-fit) (prin1-to-string seshat-reader-default-fit)))`，随后 `elisp_mcp_set_task` 传 `auto` 清声明）——用于确认 H4 的实际影响面，**只记录，不改主实例**；⑤ 核验 T4 观测脚本涉及的符号存在且签名匹配：`image-cache-size`（**Emacs 28.1+ 原语**；本包 `Package-Requires` 仅要求 26.1，故 **< 28.1 的环境跳过 T4-3 / T4-4 并明确记录「跳过：无 image-cache-size」**）、`seshat-reader--centered-p`（定义 `:911`，需一个 window 实参）、`seshat-reader--page-max-vscroll-pixels`（`:766`）、`seshat-reader--join-strip-height`（`:600`）、`seshat-reader--resize-refit-timer`（`:143`）、`seshat-reader--resize-refit-delay`、`seshat-reader-outline-show`、`seshat-reader--drag-threshold`、`memory-info`；**注意 `seshat-reader-revert-buffer` 不存在**——T4-5 的「`g` 重渲染」实际走 `revert-buffer-function`（在 `:1712` 设为 `--non-queue-refresh-doc-buffer`），观测时用 `M-x revert-buffer` 并记录该事实；⑥ 实测 H5：在 `verify` 实例上确认 `--first-fit` 执行时 `--native-page-size` 是否非 nil（用 `load-file` 加载后观测，或读代码 + 在 ERT 中加临时断言），把结论写回本计划「假设复核」小节。
- 依赖：无
- 实测（2026-10-23）：警告 33 行（/tmp/before-default-fit.log）；ERT 合计 384 例 / 384 passed / 0 skipped / 0 unexpected；逐文件计数 annotation-queue:27, annotation:48, annotation-v8:14, etaf:18, outline:24, page-join:24, reference:50, resize:67, select-flash:8, sidebar:57, translate:47；tag `pre-reader-default-fit` → ff03666
- 验收：`make all` 退出码 0、警告行数与基线一致；ERT 实测基线（源码计数 384，以实跑输出为准）全绿；`git tag -l pre-reader-default-fit` 有输出；主实例变量值已记录（或「未加载」）；5 个符号的存在性与签名已记录；H5 结论已记录。
- H5 实测结论：成立——在 `verify` 隔离实例（elc / `.so` 均软链到本仓库刚构建的产物）真机 `find-file /usr/share/doc/potrace/placement.pdf`，`:before` advice 捕获 `--first-fit` 执行瞬间 `--page-image-spec` 非 nil 且 `--native-page-size` = `(536.0 . 363.0)`（`--contain-scale` = 0.0634）。

### [x] T1 D1 + D2：defcustom 重定义 + 两个纯函数

- 动作：按 D1 替换 `:106-117` 的 defcustom；在 `--contain-scale`（`:445`）之后新增 `--normalize-default-fit` 与 `--initial-fit-mode`。
- 依赖：T0
- 验收：新增 ERT ≥6 例 —— ① `--normalize-default-fit` 五态（`contain`/`width`/`height` 原样、`fit-to-width` → `width`、`fit-to-height` → `contain`、未知符号 → `contain`）；② `--initial-fit-mode` 两态（窗口无 `fit-mode` 时取 defcustom 归一值、已有 `fit-mode` 时不被覆盖）；`make all` 警告集零新增。
- ✅ 2026-10-23 完成：`--normalize-default-fit` / `--initial-fit-mode` 落地、defcustom 值域改为 `contain`/`width`/`height`（默认 `contain`）；新增 ERT 8 例（`resize` 67 → 75）。L1 `make all` EXIT=0、警告集 **33 → 33**（归一化 diff 为空）；L2 全仓 **392** 例 / 392 expected / 0 unexpected / 0 skipped；变异自检（`fit-to-height` 映射改 `'height`）仅 `--normalize-default-fit-legacy-height` 变红。坑：变异后必须 `rm -f seshat-reader.elc`，否则 batch 加载旧 .elc 造成假绿。

### [x] T2 D3：`--first-fit` 按模式求 scale

- 动作：按 D3 改 `--first-fit`（`:471-482`）。
- 依赖：T1
- 验收：新增 ERT ≥3 例 —— ① defcustom = `width` 时 `--first-fit` 写入 `fit-mode` = `width` 且 `--fit-scale` 被调用（桩计数）；② defcustom = `contain`（默认）时行为与改造前等价（桩 `--contain-scale` / `--apply-display-scale` / `doc-scale-page` 的调用序列断言）；③ `--apply-display-scale` 返回 nil 时回退 `(doc-scale-page target 'fit)` 且 `target` 来自 `--fit-scale`。现有 `resize-test` 67 例零回归。
- ✅ 2026-10-23 完成：`--first-fit` 改走 `--initial-fit-mode` + `--fit-scale`，并写入窗口 `fit-mode`；新增 ERT 3 例（`resize` 75 → 78，用例 78 因与既有第 59 节同名改为 `--first-fit-height-mode-falls-back-to-render`）。既有第 58/59 节用例**零调整**（`contain` 分支等价，D5 得到印证）。L1 警告集 33 → 33；L2 全仓 **395** 例 / 0 unexpected / 0 skipped；变异自检 A（删 `set-window-parameter` 行）→ 3 例红（三例均断言 `fit-mode` 写入），B（`--fit-scale` 换回 `--contain-scale`）→ 2 例红（77 因等价保持绿）。

### [x] T3 D4：新窗口写初值

- 动作：按 D4 在 `--window-create-function`（`:1535`）插入 4 行。
- 依赖：T2
- 验收：新增 ERT ≥2 例 —— ① 无 `fit-mode` 的新窗口被写入归一化初值；② 已有 `fit-mode` 的窗口不被覆盖。
- ✅ 2026-10-23 完成：`--window-create-function` 的 `(unless (window-parameter window 'overlay)` 分支内、`dyn--window-create` 之前插入 6 行（2 行中文注释 + `(unless (window-parameter window 'fit-mode)` 守卫 + `set-window-parameter` 及其 2 行续行，代码 4 行），不重算几何（D4-A 保守版）；新增 ERT 2 例（`resize` 78 → 80，第 79 / 80 节）。**第 80 节在实现前即为绿**（无写入时必然保留原值），故其判别力由变异自检给出：M1（删整块写入）→ 仅第 79 节红、第 80 节绿；M2（`unless` 守卫改无条件写）→ 第 80 节红（`(eq height width)` 失败）、第 79 节绿。L1 `make all` EXIT=0、警告集 **33 → 33**（归一化 diff 为空）、两文件 `check_parens` ok；L2 全仓 **397** 例 / 397 expected / 0 unexpected / 0 skipped（`resize` 80，其余 10 文件 27/48/14/18/24/24/50/8/57/47 不变）。坑同上：每次变异前 `rm -f seshat-reader.elc`。

### [x] T4 真机批量观测（4/5 项执行，用户执行；T4-5 按用户决定不执行）

- 动作：按下列脚本在 GUI Emacs 中逐项观测并记录数值（**不改代码**；结论回填 T5 的 tech-debt）：
  - **T4-1（L3-6 短页 vscroll 非负）**：按 `W` 适配 → 翻到短页 → `M-x seshat-reader-scroll-down-screen` 数次到底 → `M-:` 求值：

    ```elisp
    (list :vscroll-px (window-vscroll nil t)
          :page-max (seshat-reader--page-max-vscroll-pixels (selected-window))
          :centered (seshat-reader--centered-p (selected-window)))
    ```

    期望 `:vscroll-px` ≥ 0 且 ≤ `:page-max`。
  - **T4-2（L3-8 daemon 下 idle timer）**：`emacs --daemon` 启动 → `emacsclient -c` → 打开文档 → 按 `o` 两次（开/关目录）→ `(sit-for 0.5)` → 求值：

    ```elisp
    (list :timer-pending (bound-and-true-p seshat-reader--resize-refit-timer)
          :centered (seshat-reader--centered-p (selected-window))
          :delay seshat-reader--resize-refit-delay)
    ```

    期望 `:timer-pending` 为 nil、`:centered` 为 t。
  - **T4-3（`image-flush` 移除后旧位图回收 + 峰值）**：同一会话反复开/关目录 20 次，记录前后：

    ```elisp
    (let ((before (image-cache-size)))
      (dotimes (_ 20)
        (seshat-reader-outline-show) (sit-for 0.3)
        (seshat-reader-outline-show) (sit-for 0.3))
      (list :before before :after (image-cache-size)))
    ```

    记录数值，无硬阈值；`after` 若随次数线性增长则记「未回收」。
  - **T4-4（image cache 峰值，拖分割线）**：拖右侧分割线 10 秒，期间与停手后各求一次 `(image-cache-size)` 与 `(nth 1 (memory-info))`（**注意取 FREE-RAM 即 `nth 1`，`nth 0` 是总内存、恒定不变**，T0 实测确认）；若 `--drag-threshold` 生效应只见有界增长。
  - **T4-5（strip 与 `before-string` 居中交互）**：`(setq seshat-reader-page-join-lines 1)` → `M-x revert-buffer` 重渲染（`revert-buffer-function` = `--non-queue-refresh-doc-buffer`，见 `:1712`）→ 翻到非首页 → 目视 strip 与页面左右边界是否对齐，并求值：

    ```elisp
    (list :strip-height seshat-reader--join-strip-height
          :centered (seshat-reader--centered-p (selected-window)))
    ```

- 依赖：T3
- 验收：5 项逐条「通过 / 失败 + 数值 + 现象」记录写回本计划；T4 结论决定 `tech-debt.md` 哪几条删除、哪几条降级、哪几条保留。
- 实测（2026-10-23，GUI Emacs 31.1 / pgtk，`(daemonp)` = nil）：
  - **T4-1 通过（L3-6）**：contain 模式页面显示 608×771、窗口 1904×986（页面比窗口矮），`--page-max-vscroll-pixels` = 0，滚到底 `(window-vscroll nil t)` = 0（非负），`--centered-p` = t。附加：`W`（fit-mode = width）下页面 1904×2413、`page-max` = 1427、`vscroll` = 936（∈ [0,1427]）、scale = render-scale = 2.9795。
  - **T4-2 部分通过（L3-8）**：「用 `sit-for` 等待」是错误方法——按 `(elisp)Idle Timers`，Emacs 在「带超时等待输入」时不算 idle，idle timer 不运行；改用「真实空闲 ≥1 秒后再求值」后 `--resize-refit-timer` = nil、`--centered-p` = t。**daemon 场景（`emacs --daemon` + `emacsclient -c`）未验证**（当前实例非 daemon）。
  - **T4-3 通过**：开合目录 20 次，`image-cache-size` 59,985,948 → 61,860,828 B（+1.79 MB，≈90 KB/次）；free-ram 22,090,868 → 22,010,188 kB。无线性增长，说明 C 侧替换 spec 时旧位图确实被回收。
  - **T4-4 通过**：拖分割线 10 秒、51 个采样点；拖拽期间 cache 最大值 82,581,352 B 即起始值、末次采样 82,037,816 B（零增长、略降）；停手后 88,059,084 B（+6 MB ≈ 3 张位图）；free-ram 波动 <0.2%。`--drag-threshold` 0.12 秒确认生效。
  - **T4-5 未执行**：用户 2026-10-23 决定不做。观测时 `M-x revert-buffer` 触发 `super-save-delete-trailing-whitespace-maybe: Buffer is read-only: #<buffer …pdf>` 连续报错（成因见 tech-debt 新增条目）；替代方法（翻页触发 `--update-join-strip`，调用点 seshat-reader.el:310/322/334/344/354，避开 revert）已备但未执行。
  - 附带发现：`revert-buffer` 走的 `--non-queue-refresh-doc-buffer`（seshat-reader.el:1507）→ `--render-buffer`（:1531）重写 buffer 后**未清除 modified 标志**（`set-buffer-modified-p nil` 只在 mode 启用时执行一次，:1751），与 `super-save` 类自动保存包冲突；已记入 `openspec/tech-debt.md`。

### [x] T5 文档

- 动作：见「## 文档清单」。
- 依赖：T4（tech-debt 与 `docs/emacs-reader.md` §12 的结论需 T4 数据）
- 验收：8 个文件按要求更新；`docs/configuration.md` 新增小节含值域表与旧值兼容说明；`tech-debt.md` 的两条 `default-fit` no-op 条目**保留并标注「——已解决」**（**实施口径变更**：计划原文写「删除」，实际按仓库既有惯例保留标注以便追溯，与 `tech-debt.md:973` 的 hscroll 条、2026-10-22 进度 409 条同口径）；另三条按 T4 结论处置——`image-flush` 移除与 image cache 累积两条降级并附观测值，strip 与 `before-string` 交互条保留待观测（T4-5 未执行）。
- ✅ 2026-10-23 完成：8 项文档全部落地——`docs/configuration.md` 新增「Emacs 客户端配置（阅读器适配模式）」小节（:281 起，含值域表、旧值兼容映射表、`W`/`H` 与 `contain`/`width`/`height` 关系、4 段配置示例）；`docs/emacs-reader.md` §3（:86/:93/:95）、配置变量表行（:330）、§12 第 17 条（:437）；`CHANGELOG.md` 新条目（:12）；`VENDORED.md` 第 ⑩ 项（:43 末尾）；`openspec/decisions.md` 2026-10-23 M1 取舍条目（:600-602）；`openspec/active/roadmap.md` M12 后续条目。`tech-debt.md` 中两条 `default-fit` no-op 条目按仓库惯例**保留并标注「——已解决」**（不删除，与 `:973`、2026-10-22 进度 409 等既有条目同口径）；三条观测类条目与 L3-6/L3-8 条目按 T4 结论处置。`docs/api.md` / `docs/errors.md` / `NEWS` 确认不改。

### [x] T6 归档与沉淀

- 动作：计划移入 `openspec/completed/`、`## 当前状态` 收尾、`memory_lesson_save` 沉淀。
- 依赖：T5
- 验收：`openspec/active/` 无本计划残留；归档文件零未勾选任务；沉淀可检索。
- ✅ 2026-10-23 完成：计划移入 `openspec/completed/`；`roadmap.md` 状态更新；lessons 沉淀（`sit-for` 不触发 idle timer；`revert-buffer` 后 modified 未清）。

## 依赖关系

```
T0 ──▶ T1 ──▶ T2 ──▶ T3 ──▶ T4 ──▶ T5 ──▶ T6
```

全串行（T1–T3 改同一文件同一区域；T4 需 T3 的最终行为；T5 需 T4 数据）。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `docs/configuration.md` | **新增**「阅读器适配模式」小节（`seshat-reader-default-fit` 值域、旧值映射表、与 `W`/`H` 的关系、不跨会话说明）——本仓首次把阅读器 fit 配置纳入用户配置面 | T5 |
| `docs/emacs-reader.md` | ① §3（`:86-95`）补「新窗口起点由 `seshat-reader-default-fit` 决定」；② **`:330` 的配置变量表行**（当前写「默认 `seshat-reader-fit-to-height`，打开文档时的初始适配」）必须改为新值域 `contain` / `width` / `height` 与「仅决定新窗口起点、`W`/`H` 不跨会话」；③ §12（`:437`）删除「`default-fit` 在自动 fit 路径上已不生效」条，改述为「`W`/`H` 不跨会话，新窗口回到默认」 | T5 |
| `CHANGELOG.md` | 新增条目：选项值域变更 + 旧值映射表 + 语义澄清（**不标 BREAKING**：旧值仍被接受，但设为 `seshat-reader-fit-to-width` 的用户行为会从 `contain` 变为 `width`） | T5 |
| `emacs/seshat-reader/VENDORED.md` | 追加第 ⑩ 项（`default-fit` 重定义 + 两个纯函数 + `--first-fit` / `--window-create-function` 接入） | T5 |
| `openspec/tech-debt.md` | 删除「`default-fit` 在自动 fit 路径上已成 no-op」（`:975-978`）与「仍是 no-op（`fit-mode` 落地后复核）」（`:1010-1013`）；「`image-flush` 移除未验证」「image cache 条目累积」「strip 与 `before-string` 交互未验证」三条按 T4 结论删除或降级并附观测值 | T5 |
| `openspec/decisions.md` | 一条 2026-10-23：M1 取舍（defcustom 作初值、不做自动持久、旧值映射表、旧默认映射为 `contain` 的理由） | T5 |
| `openspec/active/roadmap.md` | M12 后续新增条目（阅读器适配默认值 + 真机批量观测清债）与状态 | T5 |
| `emacs/seshat-reader/NEWS` | **不改**：该文件是上游 emacs-reader 的发布说明，本项目所有本地改动一律记 `VENDORED.md` + `CHANGELOG.md`；`:30` 的 `reader-default-fit` 条目是上游历史记录，不追加、不修改 | — |
| `docs/api.md` / `docs/errors.md` | **不改**（无端点、请求响应体、错误码变更） | — |

## 验证标准

### L1 语法与静态检查

- `cd emacs/seshat-reader && rm -f *.elc && make all 2>&1 | grep -E "Warning|Error" > /tmp/after-default-fit.log`，与 T0 的 `/tmp/before-default-fit.log` 逐行 diff（行号归一化），要求**零新增**。
- `check-parens` 通过（新函数与改动的两处）。
- **不要**用 `make all | grep Warning` 判定零 warning（产物已最新时不重编译，是假阴性）。

### L2 功能验证

- 全仓 11 个 ERT 文件：基线以 T0 实跑为准（测得的 **384** 例 / 384 passed / 0 skipped / 0 unexpected，含 `resize` 67 例）→ 本计划新增 ≥11 例，要求 `unexpected = 0`、`skipped = 0`。**跑 ERT 必须带实测确认的 14 个 `-L` 目录**（`emacs`、`emacs/seshat-reader`、`gt`、`pdd`、`posframe`、`etaf`、`etaf/lisp`、`etaf-ui`、`ebox`、`ebox/lisp`、`ecss`、`ecss/lisp`、`markdown-mode`、`visual-fill-column`，前缀为 straight 的 `build-31.1/` 根；缺 `etaf-ui` 会让 annotation-v8 2 例报 `Cannot open load file`，缺 `ebox`/`ecss` 连琐失败，缺 `etaf/lisp` 会让 etaf 14 例 skipped），否则 `translate` 的 2 例会假 skipped；具体命令复用 T0 实际可用的那条（见 `/tmp/before-default-fit-ert.txt` 首行或 `docs/emacs-reader.md` 的「构建与测试」节）。
- `seshat-reader-resize-test.el` 现有 67 例**零回归**（尤其 fit-mode 与 `--first-fit` 相关用例：`:1178` 起的第 31 节、`:1577` 起的第 45/46 节）。
- 变异自检（可选但推荐）：把 `--normalize-default-fit` 的 `fit-to-height` 分支改成 `'height` → 对应用例必须变红。

### L3 真机手工验收

- 即 T4 的 5 项；batch 无法替代（`window-body-width` 在 batch 下恒 80，`image-cache-size` 在 batch 下无真实图像缓存）。

### 回滚

- 代码：`git checkout pre-reader-default-fit -- emacs/seshat-reader/seshat-reader.el`（只回滚源码）。
- 测试与文档：`emacs/tests/seshat-reader-resize-test.el` 与各文档**均为已跟踪文件**，`git checkout pre-reader-default-fit -- .` 会一并回滚，**无需手工删除或 `git clean`**（与历史计划中「新增文件未跟踪需 git clean」的情形不同）。

## 注意事项

1. **`contain` 默认路径必须零行为变化**：`--fit-scale` 的 `contain` 分支直接转调 `--contain-scale`，不得在 `--first-fit` 里另写算术。
2. **不要在 `--first-fit` 里 `with-selected-window`**：它作用于 `selected-window` 本身，再包一层会改变 `--apply-display-scale` 的目标窗口语义。
3. **`--normalize-default-fit` 必须是纯函数**（无副作用、不读 buffer/window 状态），否则单测无法覆盖五态。
4. **`--normalize-default-fit` 的 `pcase` 用符号精确匹配**：`'contain` / `'width` / `'height` 与 `'seshat-reader-fit-to-width` / `'seshat-reader-fit-to-height` 是不同符号，`pcase` 的 `'symbol` 分支是 `eq` 比较，不存在前缀误判；保持计划中的书写顺序只为可读性，调整顺序不会改变结果。
5. **不覆盖已有 `fit-mode`**：D4 的写入以 `(unless (window-parameter window 'fit-mode) ...)` 包裹，否则用户按过 `W` 的窗口在新开时会被重置。
6. **checkdoc**：新增/改写的 docstring 首句须为完整句并带句号（本仓 `make all` 含 checkdoc）。
7. **主实例只读纪律**：T0 第 ④ 步只允许 `config` 任务下的只读求值，取值后立刻 `set_task auto`；**禁止**在 `config` 任务下跑 ERT / 批量字节编译。
8. **T4 观测不改仓库状态**：观测脚本里 `(setq seshat-reader-page-join-lines 1)` 只在会话内生效，观测完 `(setq seshat-reader-page-join-lines 0)` 复位；不要写 init。

## 假设复核

Phase 3 执行中与 Phase 4 收尾时逐条回填；结论取值：成立 ✓ / 被推翻 ✗ / 未验证 ?。

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| H1 | `default-fit` 全仓零调用点 | 成立 ✓ | 计划期 grep 已验（定义 `:106`，唯一 docstring 提及 `:451`） |
| H2 | `fit-mode` 是 window parameter、不跨会话 | 成立 ✓ | `:484-491` 读取实现 + Emacs window parameter 语义 |
| H3 | 用户要「新窗口默认起点」，非 `W`/`H` 自动持久 | 成立 ✓ | 用户 2026-10-23 选定 M1 档 |
| H4 | 旧值兼容映射不破坏现有配置 | 已验：主实例值为 `seshat-reader-fit-to-height`（旧默认）→ 归一化得 `contain`，行为零变化 | T0 ④ 主实例只读求值：`:bound t` / `:value "seshat-reader-fit-to-height"` / `:loaded t`（该值即旧默认，映射为 `contain` 后与改造前容器适配行为一致） |
| H5 | `--first-fit` 执行时 `--native-page-size` 可得 | 成立 ✓ | T0 ⑥ 实测：`verify` 实例打开 `placement.pdf`，`--first-fit` :before 处 `--page-image-spec` 非 nil、`--native-page-size` = `(536.0 . 363.0)`；代码顺序 `--render-buffer`（`:1723-1724`）先于 `--first-fit`（`:1738`） |
| H6 | 首次 fit 之外无其它路径读 `default-fit` | 成立 ✓ | 计划期 grep + 独立审查逐条追踪 `revert-buffer` / `--restore-display-on-quit` / 书签 / `--handle-window-buffer-change` |
| H7 | `--window-create-function` 是新窗口建 overlay 的唯一入口 | 成立 ✓ | `--manage-window-overlays`（定义 `:1526`）+ `--handle-window-buffer-change` |
| H8 | 5 项真机观测可一次 GUI 会话完成 | 部分成立 ⚠️ | 2026-10-23 实测：T4-1~T4-4 同一次 GUI 会话完成；T4-5 因 `revert-buffer` 撞 `super-save`（buffer modified 未清）失败，且用户决定不再补做，故 4/5 完成 |
