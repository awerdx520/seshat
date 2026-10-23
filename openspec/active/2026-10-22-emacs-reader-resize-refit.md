# Emacs 阅读器窗口尺寸变化自适应（方案 A，重写版）

> **行号约定**：简写 `:NNN` 一律指 `emacs/seshat-reader/seshat-reader.el` 的第 NNN 行；其它文件（`seshat-reader-sidebar.el` / `seshat-reader-outline.el` / `seshat-reader-bookmark.el` / `emacs/tests/*` / `docs/*` / `VENDORED.md`）一律以 `文件名:行号` 全名书写。全部行号取自 HEAD `f56dcce` 的实测勘察。

## 当前状态

- 阶段：Phase 3（Implement）· T0–T3 + D6 + 抖动闸 + **T7（居中同步化）** 完成，L1+L2 全绿
- 已确认：方案 ✅（用户 2026-10-22 确认）、计划 ✅（用户 2026-10-22 确认）、T7 方案 A ✅（用户 2026-10-23 确认）
- 实施：T0–T3 ✅（commit `c47100c` / `0d5edbd` + 本批测试）；**T7 ✅ 2026-10-23**（新增 `--recenter-window`，两形态均在 hook 内同步 recentre）；T4 真机、T5 文档、T6 归档待做
- 验证：L1 警告集零新增（33 → 33 条，行号归一化后 diff 为空）；L2 **337** 例 / 337 passed / 0 unexpected / 0 skipped
- 下一步：**等用户在 GUI Emacs 上做 T4 的 8 条真机验收**（batch 无法自动化，`fit-to-height` 会报 `Window system frame should be used`），其中必须含 **D7 抖动复验**：开关目录 / 面板时页面须始终居中、不出现偏左中间帧；通过后再做 T5 文档 + T6 归档
- 2026-10-23 追加：真机验收发现窗口变窄时页面超宽裁切（主路径缺陷），按方案 C 修复（contain + 负偏移夹 0），详见 D6
- 2026-10-23 真机第二次纠正：hook 实际传 window（非 frame），refit 链路此前从未运行；`--center-page` 的 prefix/hscroll 改为同成同败。见 D2 与「旧版计划的错误清单」第 7 条。
- 2026-10-23 真机反馈：布局与居中已正常，但画面持续抖动；实现 D3 预留的偏差闸（1%）+ --refitting 防重入，阻断 refit 自我激发。
- 2026-10-23 真机抖动第二轮（截图实测偏左约 175px）：refit 只排 idle timer，居中不在 hook 内同步执行 → 必然出现中间帧。按方案 A 新增 `--recenter-window`，在尺寸变化 hook 内同步 recentre，见 D7 / T7。

## 目标

1. 开关信息面板（`C-c C-l` 批注 / `C-c C-t` 译文）与目录（`o`）导致窗口尺寸变化后，页面**重新贴合**当前窗口。
2. 消除「页面被推到一边、边缘被裁」——居中重算 + vscroll 夹紧到合法区间。
3. 用户**手动**缩放过（`+`/`-`/`=`/`0`/`C-wheel`）的窗口，尺寸变化时**保留缩放比例**，只归位滚动位置。
4. 不改 `seshat-reader--center-page`（`:685`）与 `seshat-reader--set-window-vscroll`（`:519`）的内部语义；不新增 defcustom。

## 根本问题与假设

**根本问题**：`seshat-reader--window-size-change`（`emacs/seshat-reader/seshat-reader.el:726`）是 `window-size-change-functions` 上的唯一入口，它当前**只调 `seshat-reader--center-page`**。而 `--center-page` 只写 overlay 的 `line-prefix` 与 `set-window-hscroll`，**不重算渲染分辨率**（C 侧 `resolution = scale × 72`，只在 `seshat-reader-doc-scale-page` 时更新），也**不夹紧 vscroll**。于是尺寸变化后有三条独立的失效路径：

1. **位图分辨率与窗口失配** → 页面不再贴合（放大后的页面被裁、缩小后的页面留白）。
2. **窗口变窄时负 hscroll**：`--center-page` 在 `:705-715` 算出 `doc-left-offset` / `doc-center-offset` / `scroll-offset`，渲染宽 > 窗口宽时 `doc-center-offset` 为负，随后以 `(seshat-reader--set-window-hscroll window scroll-offset t)`（`:715`，`t` = unconstrained）写入 → 页面整体偏移、单侧被裁。
3. **vscroll 无下界**：`seshat-reader--set-window-vscroll`（`:519`）的 `:535` 只保证上限值非负（`(max 0 (- (+ image-height (or seshat-reader--join-strip-height 0)) pixel-window-height))`），`:537` 的 `(min pixel-vscroll max-pixel-vscroll)` **只夹上限**，传入负值原样下发 → 页面比窗口矮时图像被下推。

因此需要「尺寸变化 → 重新决定 scale → 重渲染 → 夹紧 vscroll → 居中」这条链，而这条链当前不存在。

| # | 假设 | 来源 |
|---|---|---|
| H1 | 「页面不再贴合」的根因是尺寸变化路径只调 `--center-page`，不重算 C 侧渲染分辨率 | 事实✓（`:737-739` 只调 center；`doc-scale-page` 是 resolution 的唯一更新点，`:316-318`） |
| H2 | 「推到一边/边缘被裁」由 `--center-page` 的负 `scroll-offset` 以 unconstrained 写入造成，无需改 `--center-page` 本身 | 事实✓（`:705-715` 算术 + `:715` 的 `t` 实参）+ 假设?（是否还有其它成因由 L3-1 / L3-3 真机观察确认） |
| H3 | 「页面被下推」根因是 `--set-window-vscroll` 缺下界夹紧 | 事实✓（`:533-538`：`:535` 的 `max 0` 只作用于上限值，`:537` 只 `min`） |
| H4 | ~~该 hook 必须保留 frame 参数语义与 `(window-list frame)` 遍历~~ → **handler 必须同时接受 window 与 frame** | ✗ **被推翻**（2026-10-23 真机 `(error "Window is on a different frame")`）：buffer-local 条目收到的是 window；原判据（docstring `:727-736`、`docs/emacs-reader.md:373`）只对 global / default 值成立，见 D2「参数形态」与错误清单第 7 条 |
| H5 | fit 分支必须复用 `seshat-reader-default-fit`（可能是 `fit-to-width`），不得硬编码 `fit-to-height` | 用户显式 + 事实✓（defcustom `:106`，默认 `'seshat-reader-fit-to-height`） |
| H6 | 手动缩放过的窗口在尺寸变化时应保留 scale、只夹紧并归位滚动 | 用户显式 |
| H7 | 0.15s 的 idle 去抖足以合并一次分割线拖拽（拖动期间始终非 idle，计时不断重置） | 假设?（L3-5 实测；不成立按 D3 降级） |
| H8 | `run-with-idle-timer` 在 `emacs --daemon` + `emacsclient -c` 下可靠触发 | 假设?（L3-8 验证；`seshat-reader-annotation-queue.el:437-438` 的告诫针对无交互后台同步，差异论证见 D3） |
| H9 | 开关面板/目录只改窗口尺寸、不改 scale | 事实✓（`--window-create-function`（`:1057`）以 `'scale` / `--recent-scale-fallback`（`:1077`）恢复；sidebar 走 `display-buffer-in-side-window`（`:608-615`）） |
| H10 | vscroll 上限公式必须原样复用（含 join-strip 高度），不得重写 | 事实✓（`--page-max-vscroll-pixels` `:559`，公式 `:565-570`；`seshat-reader-page-join-test.el:208` 的 `--vscroll-max` 用例直接锁定） |

## 设计

### D1 scale-source：记录缩放来源（window parameter）

- 载体：window parameter `'scale-source`，取值 `fit` / `manual`；**未设置视为 `fit`**（首次进入 mode 即 `default-fit`，`seshat-reader-mode` `:1196` 的 `:1245`）。
- 只读入口：

```elisp
(defun seshat-reader--window-scale-source (&optional window)
  "返回 WINDOW 的缩放来源（`fit' 或 `manual'），未设置时为 `fit'。"
  (or (window-parameter (or window (selected-window)) 'scale-source) 'fit))
```

- 写入落点放在既有公共路径上，用**显式可选参数**而不是「在里面猜调用者」：

```elisp
(defun seshat-reader-doc-scale-page (factor &optional source)
  "把当前窗口的页面缩放设为 FACTOR。
SOURCE 非 nil 时，把它记为该窗口的缩放来源（`fit' 或 `manual'）。"
  (when-let* ((factor-clamped (seshat-reader-dyn--scale-page factor)))
    (setq seshat-reader--recent-scale-fallback factor-clamped)
    (set-window-parameter nil 'scale factor-clamped)
    (when source
      (set-window-parameter nil 'scale-source source))))
```

- 调用点：共 **9 处、全部 1 实参**；本轮只改前 5 处，后 4 处**保持 1 参不变**。

  | 调用者 | 定义 | 调用行 | 改动 |
  |---|---|---|---|
  | `seshat-reader-enlarge-size` | `:320` | `:326` | 加 `'manual` |
  | `seshat-reader-shrink-size` | `:330` | `:336` | 加 `'manual` |
  | `seshat-reader-reset-size` | `:340` | `:343`（字面量 1.0） | 加 `'manual` |
  | `seshat-reader-fit-to-height` | `:347` | `:354` | 加 `'fit` |
  | `seshat-reader-fit-to-width` | `:358` | `:365` | 加 `'fit` |
  | `seshat-reader--restore-display-on-quit` | `:977` | `:985` | **不动**（恢复路径） |
  | `refresh-doc-buffer` | `:990` | `:1008` | **不动**（恢复路径） |
  | `seshat-reader--window-create-function` | `:1057` | `:1083` | **不动**（恢复路径） |
  | （`seshat-reader-bookmark.el`） | — | `:48` | **不动**（恢复路径） |

- `seshat-reader--recent-scale-fallback`（`:130`，defvar-local，默认 1.0）**不动**——它是兜底数值，不是来源；读取方 `current-doc-scale-value`（defun `:156`，返回表达式在 `:160`）与 `--window-create-function`（`:1077`）不受影响。
- 全仓**不存在** `scale-source` 既有实现（零命中），`'scale` 只有裸数值；本设计不改变 `'scale` 的类型。

**已知取舍：跨会话恢复一律视为 `fit`。** 4 个恢复路径都不传 `source`，因此恢复后 `scale-source` 为 nil（按 `fit` 处理）。`seshat-reader-bookmark.el:48` 是其中最典型的一例：书签只存 `'scale` 数值（`:29` 写 / `:39` 读），不含来源信息 —— 用户手动放大到 2.0 后存书签，退出再恢复，`scale` 仍是 2.0 但 source 变成 `fit`，此后一旦窗口尺寸变化就会走 `fit-to-height` 把缩放重置。这**不是实现缺陷**，而是书签格式缺字段导致的信息缺失；当前取舍是「宁可重新贴合，也不保留一个可能不合适的旧缩放」（与方案 A 目标一致）。若要跨会话保留手动缩放来源，需扩展书签存储格式（`'scale` → `(scale . source)`）并考虑旧标签兼容，**超出本计划范围**，登记为技术债。

### D2 扩展现有 wrapper（不替换注册；handler 同时接受 window 与 frame）

**参数形态（2026-10-23 真机纠正）**：`window-size-change-functions` 的 buffer-local 条目实际收到的是 **window**（`add-hook ... local = t` 就是这种情形），只有 global / default 值才收到 frame。真机报错 `(error "Window is on a different frame")` 证实了这一点——`docs/emacs-reader.md:373` 记录的「拿到 frame 而非 window」只对 global 值成立。因此 handler 必须**同时接受两种形态**：`(windowp X)` 直接检查该 window，`(frame-live-p X)` 才遍历 `(window-list X)`。

- 注册点保持 `:1246`：`(add-hook 'window-size-change-functions #'seshat-reader--window-size-change nil t)` **原样不动**。
- `seshat-reader--window-size-change` 从「直接 center」改为「双形态判定 + 排入去抖队列」：

```elisp
(defun seshat-reader--window-size-change (window-or-frame)
  "Schedule a refit after a size change of WINDOW-OR-FRAME.
`window-size-change-functions' 传 window（buffer-local 条目）或 frame
（global / default 值），两种形态都要接受。"
  (cond
   ((windowp window-or-frame)
    (when (eq (window-buffer window-or-frame) (current-buffer))
      (seshat-reader--schedule-refit)))
   ((frame-live-p window-or-frame)
    (catch 'scheduled
      (dolist (window (window-list window-or-frame))
        (when (eq (window-buffer window) (current-buffer))
          (seshat-reader--schedule-refit)
          (throw 'scheduled nil)))))))
```

- 去抖与回调：

```elisp
(defun seshat-reader--schedule-refit ()
  "为当前 buffer 安排一次去抖后的重贴合。"
  (when seshat-reader--resize-refit-enabled
    (seshat-reader--cancel-pending-refit)
    (let ((buffer (current-buffer)))
      (setq seshat-reader--resize-refit-timer
            (run-with-idle-timer seshat-reader--resize-refit-delay nil
                                 #'seshat-reader--run-pending-refit buffer)))))

(defun seshat-reader--run-pending-refit (buffer)
  "定时器回调：对 BUFFER 的每个显示窗口执行一次重贴合。"
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq seshat-reader--resize-refit-timer nil)
      (dolist (window (get-buffer-window-list buffer nil t))
        (seshat-reader--refit-window window)))))

(defun seshat-reader--cancel-pending-refit ()
  "取消当前 buffer 待触发的重贴合定时器。"
  (when (timerp seshat-reader--resize-refit-timer)
    (cancel-timer seshat-reader--resize-refit-timer))
  (setq seshat-reader--resize-refit-timer nil))
```

- 定时器生命周期收在 `seshat-reader--clear-doc-memory`（`:963`）内补一行 `(seshat-reader--cancel-pending-refit)`（该函数已在 `:969` 被注册到 `kill-buffer-hook`），保证 buffer 被杀时不残留 timer。

**timer 生命周期覆盖三种情形**：① buffer 被 kill → `--clear-doc-memory`（`:963`，经 `:969` 的 buffer-local `kill-buffer-hook` 注册）里主动 `cancel-timer`；② 窗口被删除 / 已换 buffer → 回调里 `(get-buffer-window-list buffer nil t)` 自然为空，或 `--refit-window` 的 `(eq (window-buffer window) (current-buffer))` 守卫跳过；③ **退出 `seshat-reader-mode` 但不 kill buffer → 不主动 cancel**，靠 `--refit-window` 的 `(derived-mode-p 'seshat-reader-mode)` 守卫静默跳过（timer 最多残活 0.15s，无副作用）。第 ③ 种是刻意不做 cancel 的设计，避免在 mode 退出路径上引入额外状态清理耦合。

### D2b `--refit-window` 的守卫顺序

守卫顺序固定，任一不满足即静默返回；单窗口用 `condition-case` 兜住，避免一个窗口的异常吞掉其它窗口：

```elisp
(defun seshat-reader--refit-window (window)
  "把 WINDOW 的页面重新贴合当前尺寸：必要时重定缩放，然后夹紧 vscroll 并居中。"
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (overlayp (window-parameter window 'overlay)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'seshat-reader-mode)
        (condition-case err
            (progn
              (unless (eq (seshat-reader--window-scale-source window) 'manual)
                (funcall seshat-reader-default-fit))
              (seshat-reader--clamp-window-vscroll window)
              (seshat-reader--center-page window))
          (error
           (message "seshat-reader: resize refit skipped in %s: %S"
                    (buffer-name) err)))))))
```

- 分支语义：`fit`（含未设置）→ 调 `(funcall seshat-reader-default-fit)` 重算分辨率；`manual` → **不动 scale**；两支都执行 `--clamp-window-vscroll` + `--center-page`。
- `fit` 分支里 `seshat-reader-fit-to-height` 自身还会调一次 `--center-page`（`seshat-reader-mode` 中 fit 命令的后置动作），重复调用是幂等的，不做特例处理。

**fit 分支必须在目标窗口内求值**：`seshat-reader-default-fit` 默认指向 `fit-to-height`，其内部用 `(window-body-height nil t)` 读**当前选中窗口**；而 refit 遍历 `(get-buffer-window-list buffer nil t)` 的全部窗口。因此 fit 分支必须写成 `(with-selected-window window (funcall seshat-reader-default-fit))`，否则同一 buffer 显示在两个尺寸不同窗口时会按选中窗口重算非选中窗口的 scale。（clamp 与 center 已显式传 window，不需要包。）

### D3 去抖用 idle timer，但必须论证差异 + 留降级

- 实现：`run-with-idle-timer 0.15`，每次先 `cancel-timer` 前一个（buffer-local `defvar-local seshat-reader--resize-refit-timer`）。
- 内部开关：`(defvar seshat-reader--resize-refit-enabled t)`（**不新增 defcustom**），置 nil 等价于退回「只重居中」的旧行为。

**与 annotation-queue 惯例的差异论证**。`seshat-reader-annotation-queue.el:437-438` 原文要求「一律使用 `run-with-timer' 而非 `run-with-idle-timer'：后者在 `emacs --daemon' 下不可靠。」该告诫成立的前提是**无人交互的后台周期同步**：队列必须在给定时刻推进，而 idle 的定义是「用户停手」，无人操作的会话里 idle timer 可能永不到来，任务被无限推迟。本场景正相反——它是**前台用户操作后的 UI 重排**：① 触发者永远是用户动作（开关面板、拖分割线），必然伴随一次「从非 idle 回到 idle」；② 拖拽期间系统始终非 idle，计时不断重置，天然合并为「停手后一次」；③ 即使 idle timer 从未触发，最坏结果是「本次不重贴合」，用户下一次操作会再次触发，不会丢数据。因此此处用 idle timer 是恰当的，而不是对既有惯例的违背。

**降级路径（按顺序取第一个可行者）**：

1. **L3-8（daemon + `emacsclient -c`）通过** → 维持 idle timer。
2. **偏差闸 → 已实现为默认行为（2026-10-23，不再等 L3 不达标才用）**，详见下条。
3. 仍不通过 → 只 `clamp` + `center` 不 refit（即退回本设计 D2b 的「manual 分支」行为），并把「尺寸变化后不重算分辨率」记入 `openspec/tech-debt.md`。

**降级路径第 2 级（偏差闸）已实现为默认行为（2026-10-23）**：

- **动机（真机反馈）**：2026-10-23 用户在 GUI 上反馈「布局与居中已正常，但画面持续抖动」。`--refit-window` 里的 `seshat-reader-doc-scale-page` 是**同步**重渲染（C 侧 `wait_for_cached_page`），而重渲染会改变 overlay 的 `line-prefix` 与窗口 vscroll；这些变化可能被再次判定为「窗口尺寸变化」→ 再排 refit → 再重渲染，形成自我激发循环（refit ↔ 尺寸变化），表现为画面持续跳动。因此这道闸不再只作为 L3 不达标时的兜底，而是默认生效。
- **偏差闸（阈值 1%，相对差）**：fit 分支先算 `target = (seshat-reader--contain-scale window)` 与 `current = (seshat-reader-current-doc-scale-value)`，仅当 `|target - current| > 0.01 × max(current, 1e-6)` 时才 `doc-scale-page`。低于阈值时**只 `clamp` + `center`，不重渲染**——位置照旧归位，但不再触碰渲染分辨率。`target` 非数字或 ≤ 0 时同样不重渲染（`--contain-scale` 在尺寸未知时返回 1.0，守卫只是兜底）。阈值以 `max current 1e-6` 计算，避免 current 为 0 时阈值为 0（那会让任何浮点尾差都触发重渲染）。
- **阈值形态与原判据的差异**：原第 2 级写的是「渲染尺寸与窗口尺寸偏差 > 2%，取宽/高偏差较小者」。实现改为在**输入侧**（scale）比较，而不是在**输出侧**（渲染尺寸）比较：重渲染的触发量本来就是 scale，`target` 与 `current` 的相对差直接等于「这次重渲染会改变多少」，且不受非绑定维留白干扰。阈值由 2% 收紧到 1%：1% 足以吸收 scale 重算的浮点尾差，而真实尺寸变化（拖分割线、开关面板）带来的 visual 差异通常远大于 1%；小于 1% 的变化本身不可见，跳过重渲染是有意为之。
- **`--refitting` 防重入**：新增 `defvar-local seshat-reader--refitting`；`--run-pending-refit` 遍历窗口期间把它 `let`-bind 为 `t`，`--schedule-refit` 在它为 `t` 时**直接丢弃**事件（既不 `cancel-timer` 也不重排），这样同一次 redisplay 内由 refit 自身引起的尺寸变化不会被排队成下一次 refit。`--cancel-pending-refit` 不重置该标志（它只在执行期短暂为 `t`，由 `let` 自动恢复）。
- **可回退性**：`seshat-reader--resize-refit-enabled` 仍是内部开关（置 nil 退回「只重居中」的旧行为）；manual 分支与 clamp / center 语义未变；`--contain-scale` / `--center-page` / `--set-window-vscroll` / `--page-max-vscroll-pixels` 本体均未改动，只改调用处。

### D4 vscroll 夹紧复用既有 helper

```elisp
(defun seshat-reader--clamp-window-vscroll (window)
  "把 WINDOW 的像素 vscroll 夹到 [0, 上限] 内，越界才下发。
上限取 `seshat-reader--page-max-vscroll-pixels'（已含 join-strip 高度）。"
  (let* ((max-px (max 0 (seshat-reader--page-max-vscroll-pixels window)))
         (cur (seshat-reader--window-vscroll-pixels window))
         (clamped (max 0 (min cur max-px))))
    (unless (= cur clamped)
      (seshat-reader--set-window-vscroll window clamped t))
    clamped))
```

- 上限**复用** `seshat-reader--page-max-vscroll-pixels`（`:559`，公式 `:565-570`，**已含** `--join-strip-height`），并按需要补 `(max 0 …)` 下界；`(= cur clamped)` 时不下发，避免无谓的 `set-window-vscroll`。
- 像素读数复用 T8b 已落地的 `seshat-reader--window-vscroll-pixels`（见 `emacs/seshat-reader/VENDORED.md` 第 ⑥ 项），不新写换算。
- **明确不重写上限公式、不改 `seshat-reader--set-window-vscroll`**：`emacs/tests/seshat-reader-page-join-test.el:208` 的 `--vscroll-max` 用例在 `:216-224` 直接断言该上限公式（含 strip 高度 0 / 120 两态与按行换算），任何改动都必须与它同步；本轮只做「尺寸变化路径上的绕行」。
- 既有缺口处置：`--set-window-vscroll` 缺下界这件事**由本函数在尺寸变化路径上规避**，函数本身不修，记入 `openspec/tech-debt.md`。

### D5 既有 hook / mode 一律不动

- `:1247` `window-configuration-change-hook` → `--manage-window-overlays`、`:1248` `window-buffer-change-functions` → `--handle-window-buffer-change`（均 `nil t`）**不动**。
- `seshat-reader-presentation-mode`（`:1274`）**不动**：开启时清 `mode-line-format` + `fit-to-height`，关闭时 `kill-local-variable`。由于 `fit-to-height` 经 D1 会把 source 记为 `fit`，presentation-mode 的意图与新机制一致；它不改变 scale 语义，也不与新 hook 冲突。
- `seshat-reader-mode` 内首次 fit 那一行（原为 `(funcall seshat-reader-default-fit)`）在 D6 中**改为走 contain**（真机验收后追加，见 D6）。
- **不改 `--set-window-vscroll`**；`--center-page` 仅新增一处负值夹紧（`scroll-offset` 的 `(max 0 …)`），其余语义不动（真机验收后追加，见 D6）。
- `--set-page-top`（`:583`）、`--set-page-top-when-joined`（`:593`）、`--at-page-top-p`（`:572`）、`--join-strip-height`（`:393`）**全部不动**。

### D6 自动 fit 改为 contain（2026-10-22 真机验收后追加）

- **问题**：`seshat-reader-fit-to-height` 只按高度算 scale，**完全不读窗口宽度**；窗口变窄（打开目录 / 侧栏 / 分割）后 scale 不变，页面渲染宽度可达窗口宽度的 2 倍。`--center-page` 在「image 宽 > 窗口宽」时算出**负** `doc-center-offset`，并以 `unconstrained = t` 原样写入 → 页面左移，左右各被裁掉约一半。**首次 fit 也走同一路径**（`seshat-reader-mode` 内 `(funcall seshat-reader-default-fit)`），所以**打开文档时**就复现。用户 2026-10-22 截图证据：PDF 窗口约 750px，页面渲染宽约 1490px，两侧各裁约 370px。
- **方案**：新增 `seshat-reader--contain-scale`，取 `min(按高 scale, 按宽 scale)` 做**纯计算**（不调用 `fit-to-height` / `fit-to-width`，避免副作用式改 scale），由调用方再调 `seshat-reader-doc-scale-page`：
  - `--refit-window` 的 fit 分支（尺寸变化后）：`(seshat-reader-doc-scale-page (seshat-reader--contain-scale window) 'fit)`；
  - 首次 fit（`seshat-reader-mode` 内）：同上。
  - `--center-page` 的 `scroll-offset` 加 `(max 0 …)`，页面比窗口宽时左对齐而不是两侧裁切。
- **附带影响（必须写明）**：`seshat-reader-default-fit` 在「两维冲突」时**不再决定最终结果**（contain 的 `min` 会覆盖），它只在两者都放得下时决定优先填满哪一维；显式命令 `H`（`fit-to-height`）/ `W`（`fit-to-width`）**保持原语义**，用户主动选择时仍可能超宽（需横向滚动）。
- **取舍**：选择「页面变小但完整可见」而非「保持大小 + 横向滚动」，理由是真机默认场景（开目录）下后者等于看不全。
- **待确认**：实施中发现 `seshat-reader-default-fit` 在自动 fit 路径上已无任何调用点（`grep` 只剩 defcustom 自身），即该 defcustom 事实上变为 no-op；任何「让它覆盖 contain」的写法都会导致另一维溢出，故无法在不溢出的前提下恢复其区分度。是否删除该用户选项属破坏性变更，留给用户决定（见 tech-debt / decisions）。

### D7 居中同步化（2026-10-23 真机抖动第二轮，方案 A）

- **现象**：开关目录后页面「整体向左移一下再居中」。截图实测页面中心与阅读区中心相差约 175px，用户看到的是中间帧。
- **根因**：`--window-size-change` 只 `--schedule-refit`（idle 0.15s），`--center-page` 仅在 `--refit-window` 内被调；而 `--center-page` 写入的 `line-prefix` 与 hscroll 都是静态值，redisplay 不会随窗口宽窄重算 → 中间帧必然偏。
- **参照**：上游 emacs-reader（Codeberg `MonadicSheep/emacs-reader` master，2026-10-21）在 hook 内**同步**调 `reader--center-page`（`(add-hook 'window-size-change-functions #'reader--center-page nil t)`），故无中间帧；Emacs 内置 `doc-view.el:1693-1699` 更进一步，用 `(space :align-to (+ center (-0.5 . W)))` 让 redisplay 自动求值（无 hook 依赖），但其可否用于 `line-prefix` 未验证（H5），且超宽页仍需条件分支，暂不采用。
- **方案**：新增 `--recenter-window`（四道既有守卫 + `--clamp-window-vscroll` + `--center-page`，不重渲染）；`--window-size-change` 在两种参数形态下都先对**每个**匹配窗口同步 recentre，再排一次 idle refit。frame 分支由原来的 `throw` 提前退出改为 `matched` 汇总——否则多窗口只有第一个被居中。
- **不改**：`--center-page` / `--set-window-vscroll` / `--page-max-vscroll-pixels` / `--refit-window` / `--schedule-refit` 函数体、三条 hook 注册行、零新增 defcustom。
- **取舍**：位移型抖动消除；剩余的是「页面缩放到新尺寸」的一次变化，属 contain 需求本身（L3-1/L3-3 要求页面缩小到完整可见），不算抖动。

## 旧版计划的错误清单

| # | 旧版说法 | 实测事实（HEAD `f56dcce`） |
|---|---|---|
| 1 | `window-size-change-functions` 的 buffer-local 条目收到的是 **window** 参数（引手册），因此 `:928` 参数类型没问题 | 该 wrapper 是 **frame 参数**函数：docstring `seshat-reader.el:727-736` 明写「以 frame 为参数调用」，实现 `:737-739` 用 `(window-list frame)` 遍历；`docs/emacs-reader.md:373` 记录 M12 的「拿到 frame 而非 window」回归**已修**。设计必须保留 frame 语义 |
| 2 | `--set-window-vscroll` 已有下界夹紧（首版审查据此判定无需处理） | **无下界**：`:535` 的 `(max 0 …)` 只保证上限值非负，`:537` 的 `(min pixel-vscroll max-pixel-vscroll)` 只夹上限，负值原样下发 → 必须新增夹紧（D4）。该审查条目经复核为**误判** |
| 3 | `seshat-reader-sidebar-position` 默认 `below-selected`（`seshat-reader-sidebar.el:74`），面板在下方分割 | 默认 **`'right`**（`seshat-reader-sidebar.el:92`，M12 T3 破坏性变更，docstring `:115-121` 记录）；`--display-params`（`:571`）按方位分派，`left`/`right` 走 `display-buffer-in-side-window`（`:608-615`）→ 面板是**侧窗**，阅读区变窄而非被下方分割 |
| 4 | `seshat-reader-outline.el` 仅 157 行；`show` 在 `:64`、`:85` 走 `pop-to-buffer` | 文件 **677 行**；`seshat-reader-outline-show` 在 `:124`，`:186` 走 `(seshat-reader-sidebar-show (get-buffer bufname) 'outline t)`；全文唯一的 `pop-to-buffer` 在 `:554`（切回阅读窗口，与本流程无关） |
| 5 | `seshat-reader-doc-scale-page` 定义在 `:269`（函数体 `:274-276`），5 个缩放命令在 `:278/:287/:296/:302/:313` | 定义在 **`:311`**，函数体 **`:316-318`**；调用点 9 处全为 1 实参：`:326/:336/:343/:354/:365`（5 个命令）、`:985/:1008/:1083`（3 个恢复路径）、`seshat-reader-bookmark.el:48` |
| 6 | `emacs/tests/` 下 6 个 ERT 文件、基线 181 例（179 passed / 2 skipped），无 `page-join` / `outline` / `select-flash` / `annotation-v8` 测试 | **10 个文件 / 312 例**（310 passed / 2 skipped）：annotation-queue 27、annotation 48、annotation-v8 14、etaf 18、outline 20、page-join 24、reference 50、select-flash 8、sidebar 56、translate 47；`seshat-reader-page-join-test.el:208` 的 `--vscroll-max` 用例直接锁定 vscroll 上限公式 |
| 7 | `window-size-change-functions` 的 buffer-local 条目收到 frame（据此保留 `(window-list frame)`） | **收到 window**：真机 `(error "Window is on a different frame")` 直接证明；handler 必须接受两种形态（见 D2 参数形态） |

**据此重写，旧版所有行号作废**（旧版本的行号整体漂移约 300–700 行，且三个技术前提错误、ERT 清单漏 4 个文件）。

## 与旧版的技术差异

1. **hook 处理：wrapper 内扩展，而非替换注册**。旧版把 `add-hook` 换成自己的函数并假设收到 window 参数；本版保留 `:1246` 的注册，handler 改为同时接受 window 与 frame 两种形态（frame 形态保留 `(window-list frame)` 遍历），只在 wrapper 内把「直接 center」换成「排入去抖队列」——这样 M12 已修的「frame vs window」回归不会被重新引入，也不会像 2026-10-23 之前那样因传 window 而抛 `(error "Window is on a different frame")` 被 `safe_call` 吞掉。
2. **夹紧：复用 `--page-max-vscroll-pixels`，而非新写上限公式**。旧版另写一份 `max(0, 图高 + strip 高 - 窗高)` 并新增独立 helper；本版直接调既有 `:559`（公式 `:565-570`，已含 join-strip 高度），只补 `(max 0 …)` 下界，避免与 `seshat-reader-page-join-test.el:208` 锁定的公式产生第二份真相。
3. **去抖：idle timer 必须论证，并留三级降级**。旧版直接用 `run-with-idle-timer` 未处理 `seshat-reader-annotation-queue.el:437-438` 的既有告诫；本版给出「前台 UI 重排 vs 无人交互后台同步」的差异论证。第 2 级降级（偏差闸）已按真机抖动反馈**提前实现为默认行为**：阈值 1%（目标 scale 与当前 scale 的相对差），低于阈值只 clamp + center；并加 `--refitting` 防重入。第三级（只 clamp+center 不 refit）与 tech-debt 记录仍作为后备保留。
4. **scale-source 的写入面更窄**：本版给 `doc-scale-page` 加 `&optional source`，只让 5 个缩放命令传值，**4 个恢复路径保持 1 参**（`:985`/`:1008`/`:1083`/`seshat-reader-bookmark.el:48`），`--recent-scale-fallback` 不动——旧版未区分「来源」与「兜底数值」，也未钉死恢复路径不传参。
5. **测试目标按真实基线设定**：旧版以 181 例为基线、只规划少量用例；本版基线 312 例、新增 13 例（合计 ≥325），并把「`page-join-test.el` 的 5 个 vscroll 用例零回归」写成硬性验收。
6. **第三次修订（真机验收后，D6）**：首版把「不改 `--center-page`、不改首次 fit」当作不变量，真机验收证明这条不变量站不住——只按高度算 scale 的自动 fit 在窄窗口下必然超宽，而 `--center-page` 的负偏移会把超宽转成**两侧裁切**。本版据此放开两处最小改动（首次 fit 改 contain、`scroll-offset` 夹 `>= 0`），仍不动 `--set-window-vscroll`、`fit-to-height` / `fit-to-width` 本体与三条 hook 注册。

## 任务

### [x] T0 基线与安全点

- 动作：① `cd emacs/seshat-reader && make all` 记录输出（应零 warning/error）；② 跑 `emacs/tests/` 全部 10 个文件，逐文件记录数字；③ 打轻量 tag `pre-reader-resize`（**只打 tag，不动工作区**）。
- 依赖：无
- 验收：`make all` 零 warning；合计 312 例 / 310 passed / 2 skipped / 0 unexpected；「## 基线」表填写完毕；`git tag -l pre-reader-resize` 有输出。
- ✅ 2026-10-22 完成：`make all` EXIT=0、警告集 33 条（零新增）；10 个文件合计 312 例 / 310 passed / 2 skipped / 0 unexpected；tag `pre-reader-resize` → `ca01af6`。

### [x] T1 scale-source（D1）

- 动作：新增 `seshat-reader--window-scale-source`；`seshat-reader-doc-scale-page` 加 `&optional source`；5 个缩放命令各加一个实参（`enlarge`/`shrink`/`reset` → `'manual`，`fit-to-height`/`fit-to-width` → `'fit`）；逐一核对 8 个 elisp 调用点 + `seshat-reader-bookmark.el:48` 的实参数（`grep -n "seshat-reader-doc-scale-page" emacs/seshat-reader/`，应得 9 个调用点，其中 5 处 2 实参、4 处 1 实参）。
- 依赖：T0
- 验收：新增 ERT ≥3 例（`fit` / `manual` / 未设置 → `'fit`）；恢复路径调用点仍为 1 实参；`make all` 零 warning。
- ✅ 2026-10-22 完成：`--window-scale-source` + `doc-scale-page` 的 `&optional source` 落地；5 个缩放命令传 2 实参（3 manual / 2 fit）、4 个恢复路径仍 1 实参；source 语义由 T3 的 `--doc-scale-page-source` 等 3 例锁定。

### [x] T2 wrapper 扩展 + 新函数 + timer 生命周期（D2 / D2b / D3 / D4）

- 动作：改 `seshat-reader--window-size-change`（`:726`）；新增 `--schedule-refit` / `--run-pending-refit` / `--cancel-pending-refit` / `--refit-window` / `--clamp-window-vscroll`；新增 `defvar seshat-reader--resize-refit-enabled`、`defvar-local seshat-reader--resize-refit-timer`、`defvar seshat-reader--resize-refit-delay`；`--clear-doc-memory`（`:963`）内补 `--cancel-pending-refit`。
- 依赖：T1
- 验收：`:1246`/`:1247`/`:1248` 三条 hook 的注册行未变；`--center-page` / `--set-window-vscroll` / `--page-max-vscroll-pixels` 函数体零改动（`git diff` 核对）；**自动 fit 路径（首次 + refit）使用 `--contain-scale`；`--center-page` 负偏移夹 0 且有用例覆盖**（D6，2026-10-23 追加）；`make all` 零 warning。
- 验收追加（2026-10-23，真机纠正后）：handler 同时接受 window 与 frame 两种形态，且有 ERT 锁住 window 形态不抛错（`seshat-reader-resize-test--window-size-change-accepts-window`，变异回 `(window-list window)` 即变红）。原「`--center-page` 函数体零改动」一条已被 D6 与本轮修订取代：D6 放开负偏移夹 0，本轮放开 prefix/hscroll 同成同败。
- ✅ 2026-10-22 完成：5 个新函数 + 3 个内部变量落地，`--clear-doc-memory` 补 `--cancel-pending-refit`；三条 hook 注册行未变；`page-join-test` 24 例（含 5 个 vscroll 用例）零回归。
- 适配 `emacs/tests/seshat-reader-page-join-test.el` 中锁定了旧契约（size-change 同步 center）的两个用例：`--window-size-change` 改为断言 `--schedule-refit` 被调用 1 次且 `--center-page` 零调用；`--window-size-change-errors` 改为断言「同 buffer 多窗口只排一次 refit」，其「单窗口报错隔离」语义移交 `--refit-window` 的 `condition-case`（由 T3 覆盖）。**不得改动该文件其它 22 个用例。**

### [x] T3 新增 `emacs/tests/seshat-reader-resize-test.el`（17 例）

- 动作：全部用 `cl-letf` 桩（`--contain-scale`、`seshat-reader-doc-scale-page` 的 apply 步骤、`--clamp-window-vscroll`、`--center-page`、`--set-window-vscroll`、`--page-max-vscroll-pixels`），不触真实 GUI。
- 13 例清单：① 去抖——两次 schedule 后旧 timer 被 cancel、只留一个；② 去抖重排——多次 schedule 后回调只执行一次 refit；③ `fit` 分支走自动重算（原为「调 default-fit」，D6 起改为「走 contain + `doc-scale-page`」，用例改为桩 `--contain-scale` + `doc-scale-page` 计数）；④ `manual` 分支不重算 scale，只 clamp+center；⑤ 未设置 source 走 fit；⑥ 窗口已死（`delete-window` 后）不动作不报错；⑦ 非 `seshat-reader-mode` 的 buffer 不动作；⑧ `'overlay` 参数失效（非 overlay 对象）不动作；⑨ clamp 三态（cur < 0 / cur > max / 区间内，前两态下发、第三态不下发）**加 `max-px = 0` 且 `cur > 0` 的子情形**（页面比窗口矮：上限算出来为 0，`cur` 为正时夹到 0 并下发；`cur` 已为 0 时零调用）；⑩ `doc-scale-page` 的 source 参数语义（传 `'manual` 写入、传 nil 不覆盖已有值）；⑪ `presentation-mode` 开关不回归（refit 段改桩 `--contain-scale`）；⑫ 同一 buffer 两个窗口各处理一次；⑬ buffer 已 kill 时回调不报错且 `--clear-doc-memory` 清掉了 timer。
- **D6 追加的 4 例（⑭–⑰）**：
  - ⑭ `--contain-scale-height-limited`：image 1000×1400、scale 1.0、window 900×1000 → `min(0.9, 1000/1400) = 0.714…`（高度维胜出，`1e-9` 浮点容差）。
  - ⑮ `--contain-scale-width-limited`：同 image、window 400×1000 → `min(0.4, 0.714…) = 0.4`（宽度维胜出，即真机缺陷的回归用例）。
  - ⑯ `--contain-scale-degenerate`：size 为 nil / 宽 0 / 高 0 → `1.0`；scale 为 nil / 0 → 按 `1.0` 处理（不得除零，`0.5` 结果验证）。
  - ⑰ `--center-page-clamps-negative-offset`：桩 image 宽 2000 > 窗口宽、桩 `--ensure-center-overlay`、记录 `--set-window-hscroll` 实参 → 断言 `NCOL = 0`（改动前为负值，故该用例有牙）。
- 依赖：T2
- 验收：17 例全绿（`unexpected = 0`）；整套 10 + 1 个文件合计 ≥329 例、`skipped ≤ 2`。
- ✅ 2026-10-22 完成：13 例全绿（`unexpected = 0`）；11 个文件合计 **325** 例 / 323 passed / 2 skipped / 0 unexpected；4 处单点变异（manual 分支、clamp 下界、去抖 cancel、`--clear-doc-memory` cancel）各自只红对应用例。
- ✅ 2026-10-23 追加完成（D6）：17 例全绿；11 个文件合计 **329** 例 / 329 passed / 0 skipped / 0 unexpected；变异自检 —— 去掉 `(max 0 …)` → 仅 ⑰ 红；自动 fit 回到 `(funcall seshat-reader-default-fit)` → ③⑤⑪⑫ 红（4 例）；`contain` 的 `min` 改 `max` → ⑭⑮⑯ 红。

### [ ] T4 L3 真机手工验收（8 条）

- 动作（batch 无法自动化——`fit-to-height` 在 `emacs -Q --batch` 下报 `Window system frame should be used`）：
  - **L3-1** 开批注面板（`C-c C-l`）→ 右侧 side window 出现、阅读区变窄 → 页面重新贴合，无单侧裁切。**页面应缩小到完整可见**（contain 生效），而非仅居中。
  - **L3-2** 关批注面板 → 阅读区变宽 → 页面重新贴合，vscroll 夹回 `[0, 上限]`。
  - **L3-3** `o` 开目录 → **左侧** side window（默认 `'left`），阅读区再变窄 → 重新贴合；再 `o` 关闭同理。**页面应缩小到完整可见**（contain 生效），而非仅居中。
  - **L3-4** 手动放大 3 次（`+`）后开/关面板 → scale 保持不变（`scale-source = manual`），只有滚动位置归位。
  - **L3-5** 拖动左右/上下分割线 → 不卡顿（停手后只出现一次 refit）。
  - **L3-6** 页面比窗口矮（`fit-to-width` 后的短页）→ 滚到底时 vscroll 不为负、图像不被下推。
  - **L3-7** `presentation-mode` 开/关 → 行为不回归（开时 `fit-to-height` 且 source 记 `fit`，模式行隐藏不变）。
  - **L3-8** `emacs --daemon` + `emacsclient -c` → idle timer 可靠触发；不通过则按 D3 降级并记录。
- 依赖：T3
- 验收：8 条逐条记录「通过 / 失败 + 现象」；L3-5 与 L3-8 是 D3 是否降级的判据。

> **观察项（实施中发现）**：`--refit-window` 的 fit 分支用了 `with-selected-window`，在 idle timer 回调里会短暂切换选中窗口，可能触发 `window-selection-change-functions` 或 mode-line 重绘。若真机上观察到闪烁/mode-line 抖动，替代方案是不经 `seshat-reader-default-fit`，改按 `(window-body-height window t)` 直接算 scale 后调 `(seshat-reader-doc-scale-page factor 'fit)`。

### [ ] T5 文档

- 动作：见「## 文档清单」。
- 补充：`tech-debt.md` 除原有两条外，再加一条「书签恢复不携带缩放来源，跨会话手动缩放会被尺寸变化重置」。
- **VENDORED.md 拆成两部分，明确区分**：
  - **属于本计划变更域**：追加第 ⑦ 项（尺寸变化自适应：scale-source、`--refit-window`、`--clamp-window-vscroll`、idle 去抖）——与代码改动同一提交。
  - **独立 doc-fix（单独 commit，commit message 用 `docs(reader): 更正 VENDORED 中过期的默认值与测试数`）**，含三处过期信息更正：
    - 第 ⑤ 项「`page-join-lines` 默认 `1`」→ **默认 `0`**（代码 `seshat-reader.el:112` 实测）
    - sidebar 相关测试数记录 `53` → **`56`**
    - outline 相关测试数记录 `18` → **`20`**
  - 三处均为文档与实测不一致，与主体变更无关，独立提交以免稀释聚焦。
- 依赖：T2（T4 结论用于回填 `docs/emacs-reader.md` §12）
- 验收：6 个文件按要求更新；`VENDORED.md` 新增第 ⑦ 项（本计划变更域），三处过期信息由独立 doc-fix commit 更正。

### [ ] T6 归档与沉淀

- 动作：计划移入 `openspec/completed/`、`## 当前状态` 收尾更新、`memory_lesson_save` 沉淀可复用经验（按 `rules/workflow.md` 记忆归属规则：涉及 elisp MCP / Emacs 全局行为时省略 `project`）。
- 依赖：T4、T5
- 验收：`openspec/active/` 无本计划残留；`openspec/completed/` 有归档文件；沉淀记录可检索。

### [x] T7 居中同步化（D7，2026-10-23 用户确认方案 A 后实施）

- 动作：新增 `--recenter-window`；`--window-size-change` 两形态均先同步 recentre 再排 refit；frame 分支改 `matched` 汇总以居中全部匹配窗口。
- 依赖：T3
- 验收：新增 ERT 3 例（同步 recentre + 顺序、多窗口居中各 1 次且 refit 仅 1 次、overlay 缺失时只跳过同步段）；`resize-test` 全绿；11 个文件合计 `unexpected = 0`；`make all` 警告集零新增。
- ✅ 2026-10-23 完成：`emacs/tests/seshat-reader-resize-test.el` **25/25 全绿**（原 22 例 + 新 3 例）；11 个文件合计 **337 例 / 337 passed / 0 unexpected / 0 skipped**；`make all` 退出码 0、警告集 **33 → 33**（行号归一化后 diff 为空）；变异自检（`/tmp` 副本删掉两处 `--recenter-window` 调用）→ 仅 `--size-change-recentres-synchronously` 与 `--size-change-recentres-every-window` 变红，其余 23 例仍绿。

## 依赖关系

```
T0 ──▶ T1 ──▶ T2 ──┬──▶ T3 ──▶ T4 ──┐
                   │                ├──▶ T6
                   └──▶ T5 ─────────┘   （T5 的 §12 待 T4 结论回填）
```

- **串行主干**：T0 → T1 → T2（三者改同一文件 `seshat-reader.el`，不可并行）。
- **可并行批次**：T3（新测试文件）与 T5（纯文档）在 T2 完成后**可并行**。
- **收口**：T4 必须在 T3 之后（需要新测试兜住回归后再上真机）；T6 最后。
- T5 与 T4 有弱依赖：`docs/emacs-reader.md` §12 的已知限制条目需要 T4 的实测结论，故 T5 的该段落于 T4 之后回填。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `emacs/seshat-reader/VENDORED.md` | `seshat-reader.el` 本地改动清单：追加第 ⑦ 项（尺寸变化重贴合：scale-source、`--refit-window`、`--clamp-window-vscroll`、idle 去抖）；**另含独立 doc-fix 提交**（第 ⑤ 项 `page-join-lines` 默认 `1` → 默认 `0`、sidebar 测试数 `53` → `56`、outline 测试数 `18` → `20`） | T1、T2、T5 |
| `CHANGELOG.md` | 新增条目：阅读器窗口尺寸变化后自动重贴合（fit 重算分辨率 / manual 保比例）、vscroll 夹紧、新增 13 例测试 | T5 |
| `openspec/decisions.md` | 三条决策：① 用 `scale-source` window parameter 区分 fit/manual；② idle timer 与 `annotation-queue` 惯例的差异论证与降级路径；③ 不改公共函数（`--center-page` / `--set-window-vscroll`），只在外挂路径规避 | T5 |
| `openspec/tech-debt.md` | 三条：① `--set-window-vscroll` 缺下界夹紧（本轮仅绕行）；② `--center-page` 以 unconstrained 写 hscroll，手动放大超宽时对称裁切（根因未修）；③ 书签恢复不携带缩放来源，跨会话手动缩放会被尺寸变化重置（书签格式缺字段） | T5 |
| `openspec/active/roadmap.md` | 在 M12 后续条目记录本项（阅读器尺寸自适应）与状态 | T5 |
| `docs/emacs-reader.md` | §3（`:81` 打开与基本阅读，在 `:86`/`:98-100` 附近）补「尺寸变化后自动重贴合」；§7（`:196` 跨页衔接，`:206` strip 与 vscroll 上限的几何冲突）补与 strip 的交互；§12（`:406` 已知限制）更新仍存在的限制 | T5 |

- **不新增 defcustom → `docs/configuration.md` 不改**（D1 的 `scale-source` 是内部 window parameter，D3 的开关是内部 `defvar`）。
- 本次变更只改 emacs/seshat-reader 的内部 `--` 函数与 window parameter，不新增/修改任何 HTTP 端点、请求响应体或错误码 → `docs/api.md`、`docs/errors.md` 不改。

## 验证标准

### L1 语法与静态检查（必须通过）

- 命令：`cd emacs/seshat-reader && make all` 退出码 0。
- **判据是「警告集零新增」，不是「零 warning」**：本仓库基线本来就有存量警告（2026-10-22 实测 **33 条**，含 checkdoc 输出；口径为 `rm -f *.elc && make all 2>&1 | grep -E "Warning|Error"` 的全部匹配行；主体是 `cl` 动态模块函数 `not known to be defined`、若干 docstring 超 80 列、`with-demoted-errors` 缺参）。`make all | grep Warning` 在产物已是最新时为**假阴性**（不重编译就不输出警告），**不能用它判定零 warning**。正确做法：`rm -f *.elc && make all 2>&1 | grep -E "Warning|Error" > /tmp/after.txt`，与基线（`git stash` 或 pristine 副本编译得到的 `/tmp/before.txt`）逐条 diff，要求**无新增行**。
- `elisp_check_parens` 或 `check-parens` 对 `seshat-reader.el` 与新增测试文件通过。

### L2 功能验证

- 范围：既有 **10 个**测试文件 + 新增 `seshat-reader-resize-test.el` 全跑。
- 基线：312 例 / 310 passed / 2 skipped / 0 unexpected。
- 改动后判据：合计 **≥329 例**、`unexpected = 0`、`skipped ≤ 2`（2026-10-23 实测为 329 例 / 0 unexpected / 0 skipped，见 S3）。
- 特别要求：`seshat-reader-page-join-test.el` 的 `--vscroll-max`（`:208`）、`--vscroll-max-not-negative`（`:226`）、`--page-max-vscroll-pixels`（`:449`）等 5 个 vscroll 用例**零回归**——即上限公式与 `--set-window-vscroll` 未被改动。

### L3 真机手工验收

- 8 条清单见 T4；batch 无法自动化（`fit-to-height` 报 `Window system frame should be used`），必须图形会话手动执行并逐条记录。

### 回滚

- 改动集中在 `emacs/seshat-reader/seshat-reader.el` + 1 个新测试文件（`emacs/tests/seshat-reader-resize-test.el`）+ 文档。
- 代码回滚：`git checkout -- emacs/seshat-reader/seshat-reader.el` 即回到 T0 状态（新测试文件此时会失效，需一并删除）。
- 全量回滚：`git checkout pre-reader-resize -- .`（T0 打的轻量 tag）。

新增的 `emacs/tests/seshat-reader-resize-test.el` 是未跟踪文件，`git checkout` 不会删除它，回滚时需一并清理：

```sh
git checkout -- emacs/seshat-reader/seshat-reader.el
git clean -fd -- emacs/tests/seshat-reader-resize-test.el
```

（`git clean -fd -- <path>` 只删指定未跟踪路径，不影响工作区其它文件。）

## 注意事项

1. **只改 `seshat-reader.el` 一个代码文件**：`--center-page`、`--set-window-vscroll`、`--page-max-vscroll-pixels` 的函数体不得改动，D4 只做外挂夹紧；`git diff` 逐函数核对。
2. **不要「顺手」给 `--set-window-vscroll` 补下界**：`seshat-reader-page-join-test.el:208` 锁定其上限行为，任何改动都要与该用例同步，超出本计划范围（该缺口记 tech-debt）。
3. **不要改 `:1246`/`:1247`/`:1248` 的注册行**，也不要改 `seshat-reader--window-size-change` 的参数名与 frame 语义——`docs/emacs-reader.md:373` 记录过同类回归。
4. **`presentation-mode` 的 source 语义**：它内部调 `fit-to-height`，经 D1 会写 `'fit`，属预期，不要为它额外传 `'manual`。
5. **回调必须切换 buffer**：timer 回调在触发时的当前 buffer 上下文中运行，所有 buffer-local 变量（含 `--resize-refit-timer`）都必须在 `with-current-buffer` 内访问。
6. **`= cur clamped` 时不下发**：避免在无越界时调用 `set-window-vscroll` 引起额外的 redisplay。
7. **内部开关用 `defvar` 不用 `defcustom`**：D3 的 `seshat-reader--resize-refit-enabled` 默认 `t`，不进入用户配置面，因此 `docs/configuration.md` 不改。
8. **checkdoc**：`make all` 含 checkdoc，新增函数的 docstring 首句须为完整句并带句号（中英文均可，与文件既有风格一致）。
9. **L3 是唯一能验证 idle timer / 重渲染观感的环节**：L2 全绿不代表「页面贴合」，T4 的 L3-5（拖拽不卡顿）与 L3-8（daemon）是 D3 降级的判据，不得省略。

## 基线（2026-10-22 实测）

**期望值来自 HEAD `f56dcce` 勘察**；`实测` 列由 T0（2026-10-22，HEAD `ca01af6`，工作区干净）逐文件跑 `ert-run-tests-batch-and-exit` 填入——**与期望完全一致**，勘察的 312 例清单无误。

| 测试文件 | 期望用例数 | 实测 | 通过 | 跳过 | unexpected |
|---|---|---|---|---|---|
| `seshat-reader-annotation-queue-test.el` | 27 | 27 | 27 | 0 | 0 |
| `seshat-reader-annotation-test.el` | 48 | 48 | 48 | 0 | 0 |
| `seshat-reader-annotation-v8-test.el` | 14 | 14 | 14 | 0 | 0 |
| `seshat-reader-etaf-test.el` | 18 | 18 | 18 | 0 | 0 |
| `seshat-reader-outline-test.el` | 20 | 20 | 20 | 0 | 0 |
| `seshat-reader-page-join-test.el` | 24 | 24 | 24 | 0 | 0 |
| `seshat-reader-reference-test.el` | 50 | 50 | 50 | 0 | 0 |
| `seshat-reader-select-flash-test.el` | 8 | 8 | 8 | 0 | 0 |
| `seshat-reader-sidebar-test.el` | 56 | 56 | 56 | 0 | 0 |
| `seshat-reader-translate-test.el` | 47 | 47 | 45 | 2 | 0 |
| **小计（10 个既有文件 = T0 基线）** | **312**（310 passed / 2 skipped） | **312** | **310** | **2** | **0** |
| `seshat-reader-resize-test.el`（T3 新增，非基线） | 13 | 13 | 13 | 0 | 0 |
| **合计（11 个文件，T3 后）** | **325** | **325** | **323** | **2** | **0** |

### S1 git 安全点

- 分支 `master`；本轮工作起点 HEAD `0d5edbd`（T0 实测时为 `ca01af6`；中间 `c47100c` = D1–D4 实现，`0d5edbd` = 计划修正）。
- 安全点 tag：`pre-reader-resize` → **`ca01af6`**（`git tag -l pre-reader-resize` 有输出，`git rev-parse --short pre-reader-resize` = `ca01af6`）。
- 回滚方式见「### 回滚」；新测试文件是未跟踪文件，`git checkout` 不删它，须 `git clean -fd -- emacs/tests/seshat-reader-resize-test.el` 一并清理。

### S2 L1

- `cd emacs/seshat-reader && rm -f *.elc && make all` → **EXIT=0**。
- 警告集 **33 条**（口径 = `rm -f *.elc && make all 2>&1 | grep -E "Warning|Error"` 的**全部匹配行**，含 checkdoc 输出；主体是 `cl` 动态模块函数 `not known to be defined`、docstring 超 80 列、`with-demoted-errors` 缺参）。改动后重测仍 33 条，去掉行号前缀并排序后 `diff` **为空** → 零新增。
- 口径陷阱（已实测）：产物最新时 `make all` 不重编译，`grep Warning` 输出 **0 行**——假阴性，故必须先 `rm -f *.elc`。

### S3 L2

逐文件跑（11 个），命令模板 `emacs --batch -Q <13 个 -L> -l <TEST-FILE> -f ert-run-tests-batch-and-exit`：

| 测试文件 | Ran | passed | skipped | unexpected |
|---|---|---|---|---|
| `seshat-reader-annotation-queue-test.el` | 27 | 27 | 0 | 0 |
| `seshat-reader-annotation-test.el` | 48 | 48 | 0 | 0 |
| `seshat-reader-annotation-v8-test.el` | 14 | 14 | 0 | 0 |
| `seshat-reader-etaf-test.el` | 18 | 18 | 0 | 0 |
| `seshat-reader-outline-test.el` | 20 | 20 | 0 | 0 |
| `seshat-reader-page-join-test.el` | 24 | 24 | 0 | 0 |
| `seshat-reader-reference-test.el` | 50 | 50 | 0 | 0 |
| `seshat-reader-select-flash-test.el` | 8 | 8 | 0 | 0 |
| `seshat-reader-sidebar-test.el` | 56 | 56 | 0 | 0 |
| `seshat-reader-translate-test.el` | 47 | 47 | 0 | 0 |
| `seshat-reader-resize-test.el` | 25 | 25 | 0 | 0 |
| **合计** | **337** | **337** | **0** | **0** |

- 判据全部满足：合计 **337 ≥ 329**、`unexpected = 0`、`skipped = 0`（2026-10-22 实测时 translate 有 2 例跳过；2026-10-23 复跑为 0 跳过，该 2 例的跳过条件当日未触发）。
- **2026-10-23 抖动第二轮（D7）后的实测**（上表即此次实跑数字，逐文件与 `git diff` 同批）：`seshat-reader-resize-test.el` 由 17 例增至 **25 例**（22 例存量 + 3 例 D7 新增），合计 337。命令口径：`emacs --batch -Q -L emacs -L emacs/seshat-reader -L <straight build-31.1 中除 seshat-reader 外的全部包目录> -l <TEST-FILE> -f ert-run-tests-batch-and-exit`。
  - **口径陷阱（本轮实测）**：`emacs -Q` 不加载用户配置，`etaf-ui` / `gt`（go-translate）/ `pdd` 均不在默认 `load-path`，`annotation-v8`（2 例）、`etaf`（15 例）、`sidebar`（3 例）、`translate`（整文件加载失败）会假失败 / 假跳过；补齐 `~/.local/straight/build-31.1/*` 后全部转绿且 0 skipped。
  - **第二个陷阱**：该目录里存在 straight 自己的 `seshat-reader` 副本，若前置注入 `load-path` 会**遮蔽仓库版本**（`--recenter-window` 变成 void → 新用例红）。最终命令把 straight 目录**追加到末尾并排除名字含 `seshat` 的目录**，仓库版本始终优先。
  - D7 变异自检：`/tmp/mut` 副本删掉 `--window-size-change` 里两处 `--recenter-window` 调用 → 仅 `--size-change-recentres-synchronously`（顺序断言）与 `--size-change-recentres-every-window`（多窗口各居中）变红，其余 23 例仍绿。
- 2026-10-23 追加（D6）：`seshat-reader-resize-test.el` 由 13 例增至 17 例（新增 contain 三态 + `--center-page` 负偏移夹紧），合计 329；变异自检：①去掉 `scroll-offset` 的 `(max 0 …)` → 仅 `--center-page-clamps-negative-offset` 红；②自动 fit 回到 `(funcall seshat-reader-default-fit)` → `--refit-fit-branch` / `--refit-unset-source` / `--refit-multi-window` / `--presentation-mode-keeps-fit` 红；③`(min width-factor height-factor)` 改 `max` → 3 个 contain 用例红。
- `seshat-reader-page-join-test.el` 24 例全绿，含 `--vscroll-max` / `--vscroll-max-not-negative` / `--page-max-vscroll-pixels` 等 5 个 vscroll 用例 → 上限公式与 `--set-window-vscroll` 未被改动。
- 新测试文件的变异自检（在 `/tmp` 副本上改坏实现、不改仓库文件）：① 删 `--refit-window` 的 manual 分支 → 仅 `--refit-manual-branch` 红；② 去掉 `--clamp-window-vscroll` 的 `(max 0 …)` 下界 → 仅 `--clamp-window-vscroll` 红；③ 删 `--schedule-refit` 里的 `--cancel-pending-refit` → 仅 `--schedule-refit-debounce` 红；④ 删 `--clear-doc-memory` 里的 `--cancel-pending-refit` → 仅 `--run-pending-refit-dead-buffer` 红。未改动的副本 13/13 绿。

- `make all` 基线输出：EXIT=0，警告集 33 条（详见 S2）
- 安全点 tag：`pre-reader-resize` → `ca01af6`
- 基线 commit：勘察 `f56dcce` → T0 实测 `ca01af6` → T3 后 `0d5edbd`
