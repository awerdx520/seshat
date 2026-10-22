# Emacs 阅读器窗口尺寸变化自适应（方案 A，重写版）

> **行号约定**：简写 `:NNN` 一律指 `emacs/seshat-reader/seshat-reader.el` 的第 NNN 行；其它文件（`seshat-reader-sidebar.el` / `seshat-reader-outline.el` / `seshat-reader-bookmark.el` / `emacs/tests/*` / `docs/*` / `VENDORED.md`）一律以 `文件名:行号` 全名书写。全部行号取自 HEAD `f56dcce` 的实测勘察。

## 当前状态

- 阶段：Phase 3（Implement）· 进行中
- 已确认：方案 ✅（用户 2026-10-22 确认）、计划 ✅（用户 2026-10-22 确认）
- 实施：T0–T2 进行中
- 下一步：T0–T3 完成后停下，等用户做 T4 的 8 条真机验收，再执行 T5/T6

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
| H4 | 该 hook 必须保留 frame 参数语义与 `(window-list frame)` 遍历，不能改成按 window 参数设计 | 事实✓（docstring `:727-736` 明写「以 frame 为参数调用」；实现 `:737-739`；`docs/emacs-reader.md:373`（`docs/` 下的行号取自 HEAD `f56dcce` 实测）记录 M12 的同类回归已修） |
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

### D2 扩展现有 wrapper（不替换注册，不改参数语义）

- 注册点保持 `:1246`：`(add-hook 'window-size-change-functions #'seshat-reader--window-size-change nil t)` **原样不动**。
- `seshat-reader--window-size-change` 从「直接 center」改为「排入去抖队列」：

```elisp
(defun seshat-reader--window-size-change (frame)
  "在 FRAME 尺寸变化后为显示当前 buffer 的窗口安排一次重贴合。
`window-size-change-functions' 以 FRAME 为参数调用本函数。"
  (dolist (window (window-list frame))
    (when (eq (window-buffer window) (current-buffer))
      (seshat-reader--schedule-refit))))
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

### D3 去抖用 idle timer，但必须论证差异 + 留降级

- 实现：`run-with-idle-timer 0.15`，每次先 `cancel-timer` 前一个（buffer-local `defvar-local seshat-reader--resize-refit-timer`）。
- 内部开关：`(defvar seshat-reader--resize-refit-enabled t)`（**不新增 defcustom**），置 nil 等价于退回「只重居中」的旧行为。

**与 annotation-queue 惯例的差异论证**。`seshat-reader-annotation-queue.el:437-438` 原文要求「一律使用 `run-with-timer' 而非 `run-with-idle-timer'：后者在 `emacs --daemon' 下不可靠。」该告诫成立的前提是**无人交互的后台周期同步**：队列必须在给定时刻推进，而 idle 的定义是「用户停手」，无人操作的会话里 idle timer 可能永不到来，任务被无限推迟。本场景正相反——它是**前台用户操作后的 UI 重排**：① 触发者永远是用户动作（开关面板、拖分割线），必然伴随一次「从非 idle 回到 idle」；② 拖拽期间系统始终非 idle，计时不断重置，天然合并为「停手后一次」；③ 即使 idle timer 从未触发，最坏结果是「本次不重贴合」，用户下一次操作会再次触发，不会丢数据。因此此处用 idle timer 是恰当的，而不是对既有惯例的违背。

**降级路径（按顺序取第一个可行者）**：

1. **L3-8（daemon + `emacsclient -c`）通过** → 维持 idle timer。
2. L3-8 不通过 → 降级为 `run-with-timer` 0.15s + **偏差闸**：仅当「渲染尺寸与窗口尺寸偏差 > 2%」时才 refit（避免定时器在拖拽过程中反复重渲染造成卡顿）。

   第 2 级「偏差闸」的判据（执行时按此实现，勿现场臆定）：渲染尺寸取 `(seshat-reader--get-current-doc-image-size window)` 的宽/高，窗口尺寸取 `(window-body-width window t)` / `(window-body-height window t)`；宽偏差 `dw = |1 - 渲染宽/窗宽|`、高偏差 `dh = |1 - 渲染高/窗高|`，**取 `dw` 与 `dh` 中较小者**作为判定值，仅当该值 > 0.02 时才 refit。取较小者的理由：页面按较紧的一维贴合即是「已贴合」，另一维的富余属正常留白，不应触发重渲染。

3. 仍不通过 → 只 `clamp` + `center` 不 refit（即退回本设计 D2b 的「manual 分支」行为），并把「尺寸变化后不重算分辨率」记入 `openspec/tech-debt.md`。

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
- `seshat-reader-mode`（`:1196`）的 `:1245` 首次 `(funcall seshat-reader-default-fit)` **不动**。
- `--center-page`（`:685`）、`--set-page-top`（`:583`）、`--set-page-top-when-joined`（`:593`）、`--at-page-top-p`（`:572`）、`--join-strip-height`（`:393`）**全部不动**。

## 旧版计划的错误清单

| # | 旧版说法 | 实测事实（HEAD `f56dcce`） |
|---|---|---|
| 1 | `window-size-change-functions` 的 buffer-local 条目收到的是 **window** 参数（引手册），因此 `:928` 参数类型没问题 | 该 wrapper 是 **frame 参数**函数：docstring `seshat-reader.el:727-736` 明写「以 frame 为参数调用」，实现 `:737-739` 用 `(window-list frame)` 遍历；`docs/emacs-reader.md:373` 记录 M12 的「拿到 frame 而非 window」回归**已修**。设计必须保留 frame 语义 |
| 2 | `--set-window-vscroll` 已有下界夹紧（首版审查据此判定无需处理） | **无下界**：`:535` 的 `(max 0 …)` 只保证上限值非负，`:537` 的 `(min pixel-vscroll max-pixel-vscroll)` 只夹上限，负值原样下发 → 必须新增夹紧（D4）。该审查条目经复核为**误判** |
| 3 | `seshat-reader-sidebar-position` 默认 `below-selected`（`seshat-reader-sidebar.el:74`），面板在下方分割 | 默认 **`'right`**（`seshat-reader-sidebar.el:92`，M12 T3 破坏性变更，docstring `:115-121` 记录）；`--display-params`（`:571`）按方位分派，`left`/`right` 走 `display-buffer-in-side-window`（`:608-615`）→ 面板是**侧窗**，阅读区变窄而非被下方分割 |
| 4 | `seshat-reader-outline.el` 仅 157 行；`show` 在 `:64`、`:85` 走 `pop-to-buffer` | 文件 **677 行**；`seshat-reader-outline-show` 在 `:124`，`:186` 走 `(seshat-reader-sidebar-show (get-buffer bufname) 'outline t)`；全文唯一的 `pop-to-buffer` 在 `:554`（切回阅读窗口，与本流程无关） |
| 5 | `seshat-reader-doc-scale-page` 定义在 `:269`（函数体 `:274-276`），5 个缩放命令在 `:278/:287/:296/:302/:313` | 定义在 **`:311`**，函数体 **`:316-318`**；调用点 9 处全为 1 实参：`:326/:336/:343/:354/:365`（5 个命令）、`:985/:1008/:1083`（3 个恢复路径）、`seshat-reader-bookmark.el:48` |
| 6 | `emacs/tests/` 下 6 个 ERT 文件、基线 181 例（179 passed / 2 skipped），无 `page-join` / `outline` / `select-flash` / `annotation-v8` 测试 | **10 个文件 / 312 例**（310 passed / 2 skipped）：annotation-queue 27、annotation 48、annotation-v8 14、etaf 18、outline 20、page-join 24、reference 50、select-flash 8、sidebar 56、translate 47；`seshat-reader-page-join-test.el:208` 的 `--vscroll-max` 用例直接锁定 vscroll 上限公式 |

**据此重写，旧版所有行号作废**（旧版本的行号整体漂移约 300–700 行，且三个技术前提错误、ERT 清单漏 4 个文件）。

## 与旧版的技术差异

1. **hook 处理：wrapper 内扩展，而非替换注册**。旧版把 `add-hook` 换成自己的函数并假设收到 window 参数；本版保留 `:1246` 的注册与 frame 参数语义、保留 `(window-list frame)` 遍历，只在 wrapper 内把「直接 center」换成「排入去抖队列」——这样 M12 已修的「frame vs window」回归不会被重新引入。
2. **夹紧：复用 `--page-max-vscroll-pixels`，而非新写上限公式**。旧版另写一份 `max(0, 图高 + strip 高 - 窗高)` 并新增独立 helper；本版直接调既有 `:559`（公式 `:565-570`，已含 join-strip 高度），只补 `(max 0 …)` 下界，避免与 `seshat-reader-page-join-test.el:208` 锁定的公式产生第二份真相。
3. **去抖：idle timer 必须论证，并留三级降级**。旧版直接用 `run-with-idle-timer` 未处理 `seshat-reader-annotation-queue.el:437-438` 的既有告诫；本版给出「前台 UI 重排 vs 无人交互后台同步」的差异论证，并准备 `run-with-timer` + 2% 偏差闸 → 只 clamp+center 的两级降级，末级记 tech-debt。
4. **scale-source 的写入面更窄**：本版给 `doc-scale-page` 加 `&optional source`，只让 5 个缩放命令传值，**4 个恢复路径保持 1 参**（`:985`/`:1008`/`:1083`/`seshat-reader-bookmark.el:48`），`--recent-scale-fallback` 不动——旧版未区分「来源」与「兜底数值」，也未钉死恢复路径不传参。
5. **测试目标按真实基线设定**：旧版以 181 例为基线、只规划少量用例；本版基线 312 例、新增 13 例（合计 ≥325），并把「`page-join-test.el` 的 5 个 vscroll 用例零回归」写成硬性验收。

## 任务

### T0 基线与安全点

- 动作：① `cd emacs/seshat-reader && make all` 记录输出（应零 warning/error）；② 跑 `emacs/tests/` 全部 10 个文件，逐文件记录数字；③ 打轻量 tag `pre-reader-resize`（**只打 tag，不动工作区**）。
- 依赖：无
- 验收：`make all` 零 warning；合计 312 例 / 310 passed / 2 skipped / 0 unexpected；「## 基线」表填写完毕；`git tag -l pre-reader-resize` 有输出。

### T1 scale-source（D1）

- 动作：新增 `seshat-reader--window-scale-source`；`seshat-reader-doc-scale-page` 加 `&optional source`；5 个缩放命令各加一个实参（`enlarge`/`shrink`/`reset` → `'manual`，`fit-to-height`/`fit-to-width` → `'fit`）；逐一核对 8 个 elisp 调用点 + `seshat-reader-bookmark.el:48` 的实参数（`grep -n "seshat-reader-doc-scale-page" emacs/seshat-reader/`，应得 9 个调用点，其中 5 处 2 实参、4 处 1 实参）。
- 依赖：T0
- 验收：新增 ERT ≥3 例（`fit` / `manual` / 未设置 → `'fit`）；恢复路径调用点仍为 1 实参；`make all` 零 warning。

### T2 wrapper 扩展 + 新函数 + timer 生命周期（D2 / D2b / D3 / D4）

- 动作：改 `seshat-reader--window-size-change`（`:726`）；新增 `--schedule-refit` / `--run-pending-refit` / `--cancel-pending-refit` / `--refit-window` / `--clamp-window-vscroll`；新增 `defvar seshat-reader--resize-refit-enabled`、`defvar-local seshat-reader--resize-refit-timer`、`defvar seshat-reader--resize-refit-delay`；`--clear-doc-memory`（`:963`）内补 `--cancel-pending-refit`。
- 依赖：T1
- 验收：`:1246`/`:1247`/`:1248` 三条 hook 的注册行未变；`--center-page` / `--set-window-vscroll` / `--page-max-vscroll-pixels` 函数体零改动（`git diff` 核对）；`make all` 零 warning。

### T3 新增 `emacs/tests/seshat-reader-resize-test.el`（13 例）

- 动作：全部用 `cl-letf` 桩（stub `seshat-reader-default-fit` 指向的符号、`--clamp-window-vscroll`、`--center-page`、`--set-window-vscroll`、`--page-max-vscroll-pixels`），不触真实 GUI。
- 13 例清单：① 去抖——两次 schedule 后旧 timer 被 cancel、只留一个；② 去抖重排——多次 schedule 后回调只执行一次 refit；③ `fit` 分支调 default-fit；④ `manual` 分支不调 default-fit，只 clamp+center；⑤ 未设置 source 走 fit；⑥ 窗口已死（`delete-window` 后）不动作不报错；⑦ 非 `seshat-reader-mode` 的 buffer 不动作；⑧ `'overlay` 参数失效（非 overlay 对象）不动作；⑨ clamp 三态（cur < 0 / cur > max / 区间内，前两态下发、第三态不下发）**加 `max-px = 0` 且 `cur > 0` 的子情形**（页面比窗口矮：上限算出来为 0，`cur` 为正时夹到 0 并下发；`cur` 已为 0 时零调用）；⑩ `doc-scale-page` 的 source 参数语义（传 `'manual` 写入、传 nil 不覆盖已有值）；⑪ `presentation-mode` 开关不回归；⑫ 同一 buffer 两个窗口各处理一次；⑬ buffer 已 kill 时回调不报错且 `--clear-doc-memory` 清掉了 timer。
- 依赖：T2
- 验收：13 例全绿（`unexpected = 0`）；整套 10 + 1 个文件合计 ≥325 例、`skipped ≤ 2`。

### T4 L3 真机手工验收（8 条）

- 动作（batch 无法自动化——`fit-to-height` 在 `emacs -Q --batch` 下报 `Window system frame should be used`）：
  - **L3-1** 开批注面板（`C-c C-l`）→ 右侧 side window 出现、阅读区变窄 → 页面重新贴合，无单侧裁切。
  - **L3-2** 关批注面板 → 阅读区变宽 → 页面重新贴合，vscroll 夹回 `[0, 上限]`。
  - **L3-3** `o` 开目录 → **左侧** side window（默认 `'left`），阅读区再变窄 → 重新贴合；再 `o` 关闭同理。
  - **L3-4** 手动放大 3 次（`+`）后开/关面板 → scale 保持不变（`scale-source = manual`），只有滚动位置归位。
  - **L3-5** 拖动左右/上下分割线 → 不卡顿（停手后只出现一次 refit）。
  - **L3-6** 页面比窗口矮（`fit-to-width` 后的短页）→ 滚到底时 vscroll 不为负、图像不被下推。
  - **L3-7** `presentation-mode` 开/关 → 行为不回归（开时 `fit-to-height` 且 source 记 `fit`，模式行隐藏不变）。
  - **L3-8** `emacs --daemon` + `emacsclient -c` → idle timer 可靠触发；不通过则按 D3 降级并记录。
- 依赖：T3
- 验收：8 条逐条记录「通过 / 失败 + 现象」；L3-5 与 L3-8 是 D3 是否降级的判据。

### T5 文档

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

### T6 归档与沉淀

- 动作：计划移入 `openspec/completed/`、`## 当前状态` 收尾更新、`memory_lesson_save` 沉淀可复用经验（按 `rules/workflow.md` 记忆归属规则：涉及 elisp MCP / Emacs 全局行为时省略 `project`）。
- 依赖：T4、T5
- 验收：`openspec/active/` 无本计划残留；`openspec/completed/` 有归档文件；沉淀记录可检索。

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

- 命令：`cd emacs/seshat-reader && make all`
- 判据：零 warning / 零 error；检查用 `grep -E "Warning|Error"` 无输出（**勿用 `grep -i error`**——会误命中 `with-demoted-errors`）。

### L2 功能验证

- 范围：既有 **10 个**测试文件 + 新增 `seshat-reader-resize-test.el` 全跑。
- 基线：312 例 / 310 passed / 2 skipped / 0 unexpected。
- 改动后判据：合计 **≥325 例**、`unexpected = 0`、`skipped ≤ 2`（translate 的 2 例既有跳过）。
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

## 基线（待 T0 填写）

**期望值来自 HEAD `f56dcce` 勘察**；`实测` 列由 T0 填写，与期望不一致时先停下核对（可能意味着工作区有未提交改动）。

| 测试文件 | 期望用例数 | 实测（T0 填写） | 通过 | 跳过 | unexpected |
|---|---|---|---|---|---|
| `seshat-reader-annotation-queue-test.el` | 27 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-annotation-test.el` | 48 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-annotation-v8-test.el` | 14 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-etaf-test.el` | 18 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-outline-test.el` | 20 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-page-join-test.el` | 24 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-reference-test.el` | 50 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-select-flash-test.el` | 8 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-sidebar-test.el` | 56 | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-translate-test.el` | 47 | 待填 | 待填 | 待填 | 待填 |
| **合计** | **312**（310 passed / 2 skipped） | 待填 | 待填 | 待填 | 待填 |

- `make all` 基线输出：待填（判据：`grep -E "Warning|Error"` 无输出）
- 安全点 tag：待填（`git tag -l pre-reader-resize` 的输出）
- 基线 commit：`f56dcce`
