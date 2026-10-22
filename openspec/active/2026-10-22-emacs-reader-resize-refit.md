# Emacs 阅读器窗口尺寸变化自适应（方案 A）

## 当前状态

- 阶段：Phase 2（Plan）· 计划待独立审查
- 已确认：方案 ✅（用户 2026-10-22 确认：方案 A —— 自动重贴合 + 手动缩放保留）
- 已确认：计划 ⏳（待复审 + 用户确认）
- 下一步：独立审查（plan-reviewer）→ 计划确认门禁 → Phase 3 实施

## 目标

1. 打开/关闭信息面板（`C-c C-l` 批注列表、`C-c C-t` 译文）与目录（`o` → `*Outline of …*`）导致 reader 窗口尺寸变化后，页面**重新贴合**当前窗口（不再出现「页面尺寸变了、不再适配窗口」）。
2. 同时消除「页面被推到一边、边缘被裁掉」——居中重算 + 垂直滚动位置夹紧到合法区间。
3. 用户**手动**缩放过（`+`/`-`/`=`/`0`/`C-wheel-up` 等）的窗口，尺寸变化时**保留其缩放比例**，只把滚动位置归位；不得因为开关面板悄悄改回 fit。
4. 不改变既有 `presentation-mode`、`window-configuration-change-hook`、面板/目录显示路径的行为。

## 背景与既有事实（勘察结论，实施时可直接引用；行号已逐个核实）

- `seshat-reader.el:927` 进入 mode 时执行一次 `(funcall seshat-reader-default-fit)`；`seshat-reader-default-fit` 默认值为 `seshat-reader-fit-to-height`（`:101`，可选 `fit-to-width`）。
- `seshat-reader.el:928` 仅把 `seshat-reader--center-page` 挂到 `window-size-change-functions`（buffer-local）。`--center-page`（`:411-428`）只写 overlay 的 `line-prefix` 与 `set-window-hscroll`，**不重算渲染分辨率、不碰 vscroll**——这是「页面尺寸不再适配窗口」的直接原因。
- `--center-page` 里 `doc-center-offset = (/ (- window-width doc-image-width) 2)`、`scroll-offset = (round (/ doc-center-offset pixel-per-col))`，并**以 `unconstrained = t`** 调 `--set-window-hscroll`（`:428`；`:377-395` 的上限夹紧被显式关闭）。当渲染宽 > 窗口宽时 `scroll-offset` 为负 → `set-window-hscroll` 收到负值 → 页面整体偏移、一侧被裁——这是「被推到一边、边缘被裁掉」的直接原因（不是参数类型问题）。
- 窗口级的 vscroll 夹紧只存在于 `seshat-reader--set-window-vscroll`（`:332-349`），且**只由滚动命令调用**（`:438`/`:448`/`:524`/`:534`/`:311`），窗口尺寸变化路径完全没走到。该函数把 VSCROLL 默认按「窗口行」解释、`PIXELS-P` 非 nil 时按像素；上限为 `image-height - window-body-pixel-height`，**无下界夹紧**，且该上限为负时会把负值传给 `set-window-vscroll`。
- 缩放公共路径 `seshat-reader-doc-scale-page`（`:269-276`）内部：`seshat-reader-dyn--scale-page` → 写 `seshat-reader--recent-scale-fallback` → `(set-window-parameter nil 'scale factor-clamped)`。调用者共 5 个命令（`:278` enlarge / `:287` shrink / `:296` reset / `:302` fit-to-height / `:313` fit-to-width）+ 3 个恢复路径（`:670` `--restore-display-on-quit` / `:693` `refresh-doc-buffer` / `:765` `--window-create-function`）；mwheel 变体（`:606`/`:622`）最终转调 enlarge/shrink，天然覆盖。
- C 侧 `render/render-core.c:949-957`：`new_res = fz_clamp(scale_factor * 72.0, MINRES, MAXRES)`，**仅当 `win_state->resolution != new_res` 时才 `nullify_window_cache`**，但随后**总是**执行 `build_cache_window` + `wait_for_cached_page` + `display_cached_page`（同步渲染）。故「调用一次 scale-page」的代价与 scale 是否变化无关，必须去抖。模块函数注册见 `:1464`。
- `seshat-reader-sidebar.el:74` `seshat-reader-sidebar-position` 默认 `below-selected`；显示经 `--display-params`（`:279`）→ `display-buffer-below-selected`（`:299`）→ `--display`（`:307`），即在当前窗口下方分割，reader 窗口被**缩小**（不是被替换）。- `seshat-reader-outline.el:64` `seshat-reader-outline-show`，`:85` `pop-to-buffer bufname`（**不是** `:87`）；`o` 键绑定在 `seshat-reader.el:860`（**不是** `seshat-reader-outline.el` 的内容——该文件仅 157 行）。
- `window-size-change-functions` 的 buffer-local 函数**收到的是 window 参数**（Emacs Lisp 手册「Window Hooks」节：「Functions specified buffer-locally are called for any window showing the corresponding buffer … In this case the window is passed as argument」；只有 default/global 值才收到 frame）。故 `:928` 当前的参数类型没有错，缺的是「尺寸变化后重算分辨率 + 夹紧滚动」。
- 既有窗口尺寸变化路径的顺序（手册同节）：buffer change → size change → selection → state → **configuration change**。`window-configuration-change-hook`（`:929` → `--manage-window-overlays` `:730`）在 size-change 之后运行，负责 overlay 生命周期；`--window-create-function`（`:739-766`）创建 overlay 时用 `(window-parameter window 'scale)` 恢复 scale，**不改 scale 语义**。
- `seshat-reader-presentation-mode`（`:956-963`）开启时 `setq-local mode-line-format nil` + `(seshat-reader-fit-to-height)`，关闭时只 `kill-local-variable 'mode-line-format`（不恢复 scale，属既有行为）。
- `seshat-reader--set-window-vscroll` 的调用者与 `--center-page` 的调用者遍布滚动/翻页/旋转命令；二者均为公共依赖，本轮**不改其内部语义**。
- 测试：`emacs/tests/` 下 6 个 ERT 文件（annotation / annotation-queue / etaf / reference / sidebar / translate），**无 `make test` 目标**；`emacs/seshat-reader/Makefile` 只有 `all`（`$(LIB_NAME)` + autoloads + `.elc` + `checkdoc`）、`clean`、`checkdoc`。ERT 需 `emacs -Q --batch` 并带 ecss/ebox/etaf/etaf-ui/gt/pdd/posframe/compat 的 `-L`。
- **ERT 基线（2026-10-22 T0 实测，HEAD `38eea5f`）**：181 例 / 179 通过 / 2 跳过 / 0 unexpected（2 例跳过全在 `seshat-reader-translate-test.el`）。

> 与委派说明的行号差异（已核实更正）：`outline.el` 是 `:85`（非 `:87`）；`doc-scale-page` 定义在 `:269`（`:274-276` 是其函数体）；`presentation-mode` 定义在 `:956`、`fit-to-height` 调用在 `:962`（非 970）；`--set-window-vscroll` 定义在 `:332`（`:334-350` 覆盖函数体）。其余引用（`:101`/`:411-428`/`:927-929`/`:74`/`render-core.c` scale 路径）核实一致。

## 根本问题与假设

**根本问题**：`seshat-reader-mode` 把「窗口尺寸变化」当成纯排版问题（只需重新居中），但页面位图的尺寸是**渲染期固化的**（`resolution = scale × 72`，C 侧只在 `scale-page` 时更新），窗口尺寸变化后位图与窗口的适配关系失效；同时 vscroll 是像素量、没有随窗口高度重新夹紧。于是需要「尺寸变化 → 重新决定 scale → 重渲染 → 夹紧滚动 → 居中」这条链，而这条链当前不存在。

| 假设 | 来源 |
|---|---|
| H1 症状根因是「尺寸变化后只调 `--center-page`，不重算 resolution、不夹紧 vscroll」 | 事实✓（`:928`、`:411-428`、`:332-349` 调用点清点、`render-core.c:949-957`） |
| H2 「被推到一边/边缘被裁」在「渲染宽 > 窗口宽」时由 `--center-page` 的负 `scroll-offset`（unconstrained 写入）造成，无需改 `--center-page` 本身 | 事实✓（`:415-428` 算术 + `:377-395` 的 unconstrained 分支）+ 假设?（是否还有其它成因，L3 观察确认） |
| H3 fit 分支应复用 `seshat-reader-default-fit`（可能是 fit-to-width），不得硬编码 `fit-to-height` | 用户显式 + 事实✓（`:101` defcustom 有两个合法值） |
| H4 手动缩放后应保留 scale、只夹紧滚动 | 用户显式 |
| H5 `run-with-idle-timer` 在本场景（GUI 客户端 / daemon 客户端）能可靠触发 | 假设?（仓库既有 `seshat-reader-annotation-queue.el:431` 注释称 idle timer 在 `--daemon` 下不可靠，但那是后台周期同步场景；本场景有 L3-8 专门验证，失败走降级路径） |
| H6 0.1–0.2s 去抖足以合并一次分割线拖拽（拖动期间始终非 idle，计时不断重置） | 假设?（L3-5 实测） |
| H7 面板/目录开关不改 scale，只改窗口尺寸 | 事实✓（`--window-create-function` 用 `window-parameter 'scale` 恢复；`display-buffer-below-selected` 不触 scale） |

## 设计

### D1 scale-source：用 window parameter 记录缩放来源

- 载体：window parameter `'scale-source`，取值符号 `fit` / `manual`；未设置视为 `fit`（首次进入 mode 即 `default-fit`，见 `:927`）。
- 读取单一入口：

  ```elisp
  (defun seshat-reader--window-scale-source (&optional window)
    "Return WINDOW's scale source, `fit' or `manual' (default `fit')."
    (or (window-parameter (or window (selected-window)) 'scale-source) 'fit))
  ```

- 写入落点：给公共路径加**显式可选参数**，而不是「在里面猜调用者」：

  ```elisp
  (defun seshat-reader-doc-scale-page (factor &optional source)
    "...当 SOURCE 非 nil 时，把它记为该窗口的 scale 来源（`fit' / `manual'）。"
    (when-let* ((factor-clamped (seshat-reader-dyn--scale-page factor)))
      (setq seshat-reader--recent-scale-fallback factor-clamped)
      (set-window-parameter nil 'scale factor-clamped)
      (when source (set-window-parameter nil 'scale-source source))))
  ```

- 调用点改动（**只有 5 处**，均在既有命令内，各加一个实参）：
  | 命令 | 位置 | 传值 |
  |---|---|---|
  | `seshat-reader-enlarge-size` | `:284` | `'manual` |
  | `seshat-reader-shrink-size` | `:293` | `'manual` |
  | `seshat-reader-reset-size` | `:299` | `'manual` |
  | `seshat-reader-fit-to-height` | `:309` | `'fit` |
  | `seshat-reader-fit-to-width` | `:320` | `'fit` |
  mwheel 变体（`:618`/`:633` 转调 enlarge/shrink）自动继承；3 个恢复路径（`:670`/`:693`/`:765`）原本的调用是 `(seshat-reader-doc-scale-page scale)`——**只传 1 个实参**；加 `&optional source` 后**保持原 1 参调用**（不传 source → source 取 nil → 不写 `scale-source`，即不改变原有来源）。恢复语义是「回到窗口原本的状态」，不是用户的新缩放指令。
- 取舍说明（写进代码注释）：
  - 不在 `doc-scale-page` 内用 `this-command` / `backtrace` 判定调用者——脆弱（`refresh-doc-buffer`、`--window-create-function`、queue-command 宏都会污染判定），且不可被 docstring 表达；
  - 不在各命令里各自 `set-window-parameter`——那样 `scale` 与 `scale-source` 会分两步写，存在「scale 已变、source 未变」的中间态，且新增缩放命令必漏；
  - 显式参数把「写 scale」与「写 source」收敛到同一次原子更新，唯一写入点是 `doc-scale-page`。

### D2 窗口尺寸变化处理：去抖 + 两分支

新增入口与处理函数，替换 `:928` 的注册（`:927` 的首次 fit 保留不动）；另有两个配套函数 `seshat-reader--refit-window` 与 `seshat-reader--clamp-window-vscroll`，见下。

```elisp
(defvar-local seshat-reader--resize-timer nil
  "本 buffer 待执行的窗口尺寸变化处理定时器（去抖用）。")

(defvar seshat-reader--resize-debounce 0.15
  "窗口尺寸变化后延迟处理的秒数。")

(defun seshat-reader--handle-window-size-change (&optional window)
  "窗口尺寸变化入口：取消上一个定时器后重排一次处理（buffer 取自 WINDOW）。"
  (let ((window (or window (selected-window))))
    (when (and (window-live-p window)
               (with-current-buffer (window-buffer window)
                 (derived-mode-p 'seshat-reader-mode)))
      (when (timerp seshat-reader--resize-timer)
        (cancel-timer seshat-reader--resize-timer))
      (let ((buffer (window-buffer window)))
        (setq seshat-reader--resize-timer
              (run-with-idle-timer
               seshat-reader--resize-debounce nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq seshat-reader--resize-timer nil)
                     (seshat-reader--apply-window-size-change))))))))))

(defun seshat-reader--apply-window-size-change ()
  "对显示当前 buffer 的每个窗口做 refit 或仅夹紧。"
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (seshat-reader--refit-window window)))
```

`seshat-reader--refit-window` 的判定顺序（**先守卫、后动作**）：

1. `(window-live-p window)`；否则静默跳过。
2. `(eq (window-buffer window) (current-buffer))`；否则跳过（窗口已换 buffer）。
3. `(overlayp (window-parameter window 'overlay))`；否则跳过（overlay 已失效，交给 `--manage-window-overlays` 重建）。
4. `with-selected-window` 内 `(derived-mode-p 'seshat-reader-mode)`；否则跳过。
5. 分支：
   - `scale-source` = `fit` → `(funcall seshat-reader-default-fit)`（重算 resolution 并重渲染；`fit-to-height` 内部会把 vscroll 归零，`fit-to-width` 不会——下面统一夹紧）；
   - `scale-source` = `manual` → **不调用任何 fit**，scale 与 source 都保持不变。
6. 两个分支都执行：`(seshat-reader--clamp-window-vscroll window)` → `(seshat-reader--center-page)`。
7. 全程 `condition-case` 包住单个窗口的处理（`error` 记 `message` 后继续下一个窗口），避免一个坏窗口中断其余窗口。

替换注册：

```elisp
(add-hook 'window-size-change-functions #'seshat-reader--handle-window-size-change nil t)
```

**buffer 来源**：handler 一律用 `(window-buffer WINDOW)` 取 buffer，不依赖 `(current-buffer)` 的隐式语义——buffer-local 的 `window-size-change-functions` 虽在该 buffer 内被调用，但窗口参数才是真实来源（同一 buffer 显示在多个窗口时 `current-buffer` 与 `window-buffer` 可能不一致；若将来改成 global/default hook，`current-buffer` 语义完全不同）。`window-buffer` 要求 live window，故 handler 先用 `window-live-p` 守卫（已提前到 `and` 第一项）。mode 守卫同样不依赖 `current-buffer`：`(with-current-buffer (window-buffer window) (derived-mode-p 'seshat-reader-mode))` —— `derived-mode-p` 只检查 current-buffer 的 `major-mode`、**不接受 buffer 实参**（其签名为 `(derived-mode-p MODES &rest DEPRECATED-ARGS)`），必须用 `with-current-buffer` 显式切到该窗口的 buffer 才能检查到正确的 mode。

timer 生命周期：`kill-buffer-hook` 已挂 `seshat-reader--clear-doc-memory`（`:648-651`），在其中补 `(when (timerp seshat-reader--resize-timer) (cancel-timer seshat-reader--resize-timer))` 并置 nil，避免 buffer 被 kill 后 timer 泄漏。`seshat-reader--resize-timer` 为 **buffer-local**，不同 reader buffer 互不干扰。

### D3 去抖窗口与性能

- **为什么必须去抖**：拖分割线 / 拖动窗口边缘时每次 redisplay 都可能触发 `window-size-change-functions`；而一次 fit 会走 C 侧 `emacs_doc_scale_page`（`render-core.c:936-988`，核心在 `:949-970`）——`wait_for_win_jobs` → 可能 `nullify_window_cache` → `build_cache_window` → `wait_for_cached_page`（等待渲染完成）→ `display_cached_page`，**同步**重渲染；且 hook 在多窗口/多次 redisplay 下会重复调用。不去抖就是「连续同步重渲染」，必然卡顿并与拖动竞争。
- **为什么用 idle timer 而非固定 timer**：拖动期间 Emacs 始终不 idle，idle 计时被反复重置 → 天然「只在停手后触发一次」；固定 `run-with-timer` 会在拖动中途触发重渲染，造成视觉抖动。这与仓库既有 `seshat-reader-annotation-queue.el:431`「一律用 `run-with-timer`」的结论不冲突——那是**后台周期同步**（必须按时执行、不能等用户空闲），本处是**纯 UI 重排**（应当等用户停手）。此差异需在代码注释中写明，避免后人误改。
- **0.15s 的依据**：C 侧单次重渲染中位耗时在数十毫秒量级（T4 实测记录），0.1–0.2s 区间取中；<0.1s 易与拖动中的 redisplay 竞争，>0.2s 用户可感知延迟。该值用内部 `defvar`（不做 defcustom，避免新增用户配置面与文档负担）。
- **降级路径（L3 实测不达标时按序执行，并记 `openspec/tech-debt.md`）**：
  1. 去抖提至 0.3s（改一个 `defvar` 值）；
  2. 若仍卡：`fit` 分支加**偏差闸**——仅当 `(|渲染高 - 窗口高| / 窗口高) > 2%` 或宽度偏差 > 2% 时才 refit（避免「尺寸变化很小也全量重渲染」）；
  3. 若仍卡：`fit` 分支退化为「只 clamp + center，不 refit」（即与 `manual` 分支相同），并明确记 tech-debt（症状回到「页面略不适配」但无卡顿）。
  - 上述行为开关统一由内部 `defvar seshat-reader--resize-refit-enabled`（默认 `t`）承载，禁止新增 defcustom。

### D4 vscroll / hscroll 夹紧口径

- 单位口径：`seshat-reader--set-window-vscroll` 的 `vscroll` 参数默认按**窗口行**解释，`PIXELS-P` 非 nil 时按**像素**。新逻辑统一走**像素**口径，因为窗口高度变化是像素级的。
- 夹紧公式（新函数 `seshat-reader--clamp-window-vscroll`，不改动既有 `--set-window-vscroll`）：

  ```elisp
  (defun seshat-reader--clamp-window-vscroll (&optional window)
    "把 WINDOW 的像素 vscroll 夹到 [0, max(0, image-height - body-pixel-height)]。"
    (let* ((window (or window (selected-window)))
           (image-height (cdr (seshat-reader--get-current-doc-image-size window)))
           (body-height (window-body-height window t))
           (max-pixel (max 0 (- image-height body-height)))
           (current (window-vscroll window t))
           (clamped (max 0 (min current max-pixel))))
      (unless (= current clamped)
        (set-window-vscroll window clamped t))))
  ```

- **为什么不直接复用 `seshat-reader--set-window-vscroll`**：它只夹上限（`(min pixel-vscroll max-pixel-vscroll)`，`max-pixel-vscroll` 可能为负），在「页面比窗口矮」时会传入负值（图像被下推、顶部露空白），且它被全部滚动命令依赖——改它会改变滚动语义，违反「不破坏既有行为」。本函数**复述同一上限公式**（语义一致）并补 `max 0` 下界，只用于尺寸变化路径。
- hscroll 不动：仍由 `--center-page` 负责——它以 `unconstrained = t` 调 `seshat-reader--set-window-hscroll`（`:428`；该函数 `:377-395` 支持上限夹紧，但 `--center-page` 显式关闭了它），因此「渲染宽 > 窗口宽」时会得到**负 hscroll**（页面被偏移、左右裁切）。本轮靠 `fit` 分支重新贴合来消除绝大多数该情形，不改 `--center-page` 的这条语义；`fit-to-width` 之外的极端情形（用户手动放大到超过窗口宽）记 `openspec/tech-debt.md`。

### D5 与既有 hook / mode 的关系

- `window-configuration-change-hook` → `seshat-reader--manage-window-overlays`（`:929`）**保持原样**：它负责 overlay 生命周期，且在 size-change 之后运行；我们的处理延后到 idle，因此总是看到已重建/已校验的 overlay（守卫 3 保证这一点）。
- `window-buffer-change-functions`（`:930` → `--handle-window-buffer-change`）**保持原样**。
- `seshat-reader-presentation-mode`（`:956-963`）**行为不变**：它照旧调 `fit-to-height`，只是现在会把 `scale-source` 记为 `fit`（与它的意图一致：演示视图就该贴合）；关闭时仍不恢复 scale（既有行为，不扩大范围）。
- `:927` 的首次 `(funcall seshat-reader-default-fit)` 保留——它会写入 `scale-source = fit`，与「未设置视为 fit」的读取默认值一致。
- 修改的是 vendored 派生文件 `seshat-reader.el`，按 `VENDORED.md` 的「按文件的本地改动清单」追加记录；**不触碰**任何自研扩展文件（`-select.el` / `-annotation*.el` / `-sidebar.el` / `-etaf.el` / `-reference.el` / `-translate.el`）。

## 任务

- [ ] T0 基线与安全点（依赖：无）
  - 打安全点（沿用仓库既有 `pre-*` 轻量 tag 惯例，如 `pre-reader-resize`，只打 tag 不动 index/工作区）。
  - 记录基线：`cd emacs/seshat-reader && make all`；6 个 ERT 文件按统一命令各跑一次，记录 Ran / passed / skipped / unexpected。
  - 验收：计划末尾「## 基线」节写入命令、退出码、用例数；ERT 合计与「181 / 179 / 2 / 0」一致或写明差异。

- [ ] T1 记录 scale-source（依赖：T0）
  - `seshat-reader.el`：`seshat-reader-doc-scale-page` 增可选参数 `source`（`:(when source (set-window-parameter nil 'scale-source source))`），docstring 说明取值与「nil 表示不改变」。
  - 5 个命令各传实参：enlarge/shrink/reset → `'manual`；fit-to-height/fit-to-width → `'fit`。
  - 新增读取函数 `seshat-reader--window-scale-source`（未设置返回 `fit`）。
  - 新增/扩展 ERT（可放 T3 的新测试文件）：`'fit` / `'manual` / 未设置 三个方向各 ≥1 例。
  - 验收（**主判据**）：`grep -n "seshat-reader-doc-scale-page"` 逐行核对全部 8 处调用的实参——5 个命令中 `:284`/`:293`/`:299` 传 `'manual`、`:309`/`:320` 传 `'fit`；3 个恢复路径（`:670`/`:693`/`:765`）仍是原有 **1 参**调用 `(seshat-reader-doc-scale-page scale)`（不传 source → source 为 nil → 不写 `scale-source`）。（辅助，不作判据）`grep -c "'manual"` 应为 3；`grep -c "'fit"` 仅作参考（`"'fit"` 子串会误命中其它含 `fit` 的符号，如 `'fit-to-width` 相关字样，不得单独据此判定）。ERT 覆盖由 T3 验证（T1 自身不含测试断言）。

- [ ] T2 新增尺寸变化处理并替换 hook 注册（依赖：T1）
  - 新增 `seshat-reader--resize-timer`（`defvar-local`）、`seshat-reader--resize-debounce`（`defvar`，0.15）、`seshat-reader--resize-refit-enabled`（`defvar`，t）。
  - 新增 `seshat-reader--handle-window-size-change`（cancel + `run-with-idle-timer` + 闭包捕获 buffer）、`seshat-reader--apply-window-size-change`（`get-buffer-window-list` 遍历）、`seshat-reader--refit-window`（守卫 1-4 + 两分支 + clamp + center，`condition-case` 包单窗口）、`seshat-reader--clamp-window-vscroll`。
  - `:928` 的 `add-hook` 目标改为 `seshat-reader--handle-window-size-change`。
  - `seshat-reader--clear-doc-memory` 内补 timer 取消（`timerp` + `cancel-timer` + 置 nil）。
  - 验收：`make all` 零 warning/error；`grep -n "window-size-change-functions"` 只剩一行且指向新函数；`--center-page` 与 `--set-window-vscroll` 的函数体 `git diff` 为空（不改公共函数）；handler 内不出现 `(current-buffer)` 作为 buffer 来源（`--handle-window-size-change` 用 `(window-buffer WINDOW)` 取 buffer，`grep -n "current-buffer"` 在该函数体内零命中）。

- [ ] T3 ERT 覆盖（依赖：T2）
  - 新建 `emacs/tests/seshat-reader-resize-test.el`（第 7 个 ERT 文件），`(require 'seshat-reader)` + `ert` + `cl-lib`；所有窗口相关调用用 `cl-letf` 桩（`run-with-idle-timer` / `cancel-timer` / `get-buffer-window-list` / `window-live-p` / `window-buffer` / `buffer-live-p` / `window-parameter` / `window-vscroll` / `set-window-vscroll` / `seshat-reader-dyn--scale-page` / `seshat-reader--center-page` / `--get-current-doc-image-size` / `window-body-height`），**不触碰真实 GUI**。
  - 用例清单（13 条）：
    1. 去抖：同帧内调用 handler 两次 → `cancel-timer` 被调用 1 次、`run-with-idle-timer` 被调用 2 次、`seshat-reader--resize-timer` 最终为最后一次返回值。
    2. 去抖到期：执行 timer 回调（`timer-event-handler` 或直接调 `--apply-window-size-change`）→ 每窗口只处理一次；处理完 `seshat-reader--resize-timer` 为 nil。
    3. `fit` 分支：`scale-source` = `fit` → `seshat-reader-default-fit` 被调用 1 次（用 `cl-letf` 桩 `funcall` 目标：绑定 `seshat-reader-default-fit` 为一个记录调用的 lambda）、`--center-page` 被调用。
    4. `manual` 分支：`scale-source` = `manual` → fit 桩零调用、`window-parameter 'scale` 值不变、`--center-page` 仍被调用。
    5. 未设置：`window-parameter 'scale-source` 为 nil → 走 fit 分支。
    6. 已删除窗口：`window-live-p` 返回 nil → 无 fit、无 center、无 error。
    7. buffer 已非 reader mode：`derived-mode-p` 返回 nil → 跳过。
    8. overlay 失效：`window-parameter 'overlay` 返回 nil → 跳过。
    9. `--clamp-window-vscroll` 三态：`image 2000 / body 600 / current 1500` → 夹到 1400；`image 400 / body 600 / current 100` → 夹到 0；`current 已 ≤ max` → `set-window-vscroll` 零调用。
    10. `doc-scale-page` 的 source 参数：传 `'manual` → source 变 manual；传 nil → source 保持原值（先设 `'fit` 再调 2 参）。
    11. presentation-mode 不回归：`(seshat-reader-presentation-mode 1)` 后 `scale-source` = `fit`（`mode-line-format` 局部变 nil），且 handler 仍走 fit 分支。
    12. 多窗口：`get-buffer-window-list` 桩返回 2 个窗口 → `--refit-window` 对两个窗口各处理一次（fit 桩与 `--center-page` 调用计数均为 2），且去抖计数正确（同帧内两次 handler → `cancel-timer` 1 次、`run-with-idle-timer` 2 次、`seshat-reader--resize-timer` 为最后一次返回值）。
    13. buffer 已杀：直接执行 timer 回调且 `buffer-live-p` 桩返回 nil → 不调用 `--apply-window-size-change`（fit / center 零调用）、无 error 传播、不留活跃 timer（回调内不再 `run-with-idle-timer`，`seshat-reader--resize-timer` 可被安全取消）。
  - 验收：用例数 11 → 13（新增第 12 条「多窗口」与第 13 条「buffer 已杀」）；新文件全绿且 `unexpected = 0`；6 个既有 ERT 文件仍全绿（跳过数 ≤ 2）。

- [ ] T4 真机 L3 验收（依赖：T2、T3）
  - 由用户在 GUI Emacs + 真实 PDF 上逐条勾选「## 验证标准」L3 清单（L3-1…L3-8）。
  - 记录结果到本节（勾选 + 实测现象）；若 L3-5（拖分割线）或 L3-8（daemon）不达标，按 D3 的降级路径 1→2→3 依次尝试并把最终取值写回计划。
  - 验收：8 条全部勾选或明确记录「降级到第 N 档 + 原因」。

- [ ] T5 文档同步（依赖：T1–T4）
  - `emacs/seshat-reader/VENDORED.md`：「按文件的本地改动清单」中 `seshat-reader.el` 行追加 ④「窗口尺寸变化自适应：`scale-source` window parameter、`--handle-window-size-change` 去抖重贴合、`--clamp-window-vscroll`（不动 `--center-page` / `--set-window-vscroll` 语义）」。
  - `CHANGELOG.md`：`[Unreleased]` 的「修复」下新增一条（用户可感知：开关面板/目录后页面重新贴合、手缩放不被重置）。
  - `openspec/decisions.md`：新增决策——① 缩放来源用 window parameter `'scale-source`（fit/manual）而非 buffer-local 变量或 `this-command` 推断；② 尺寸变化用 idle timer 去抖（与 annotation-queue 的 run-with-timer 惯例的差异理由）；③「不改公共函数 `--center-page` / `--set-window-vscroll`，新逻辑外挂」。
  - `openspec/tech-debt.md`：新增两条——`--set-window-vscroll` 缺下界夹紧（尺寸变化路径已在外部规避，函数本身未修）；`--center-page` 以 `unconstrained` 设 hscroll，手动放大到超过窗口宽时页面呈对称裁切（未改为「夹紧 + 允许横向滚动」）。
  - `openspec/active/roadmap.md`：新增 M11.15 行（或按现有编号续），状态随本计划归档更新。
  - 验收：五处文档与实际代码逐条 grep 核对（函数名、parameter 名、`defvar` 默认值），禁止照抄计划措辞；`make validate`（若有）或 Markdown 结构自检通过。

- [ ] T6 归档与沉淀（依赖：T5）
  - 勾选全部任务、更新「## 当前状态」与「## 基线」，计划移入 `openspec/completed/`。
  - `memory_save` 记架构决策（scale-source 机制、idle 去抖取舍）；`memory_lesson_save` 记实施坑（如 ERT 中 `funcall` 的桩法、idle timer 闭包必须 `buffer-live-p`、`--set-window-vscroll` 缺下界）。
  - 验收：`openspec/active/` 无残留本计划；记忆可检索（`memory_lesson_recall` 命中）。

## 依赖关系

`T1 → T2 → T3 → T4 → T5 → T6`（严格串行：T2 依赖 T1 的 `scale-source` 与读取函数；T3 依赖 T2 的函数名与 `defvar`；T4 依赖 T3 的用例通过后才能判断真机现象；T5 需 T4 的最终降级档位）。
可并行：T5 中 `VENDORED.md` / `CHANGELOG.md` / `tech-debt.md` 三条互不依赖，可在 T4 完成后同时写。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `emacs/seshat-reader/VENDORED.md` | vendored 派生文件的本地改动清单 | T5 |
| `CHANGELOG.md` | 用户可感知的修复 | T5 |
| `openspec/decisions.md` | 架构决策（scale-source 机制、去抖取舍、公共函数不动） | T5 |
| `openspec/tech-debt.md` | 技术债登记（vscroll 下界、宽度不居中的既有语义） | T5 |
| `openspec/active/roadmap.md` | 里程碑状态 | T5 |
| 本计划文件 | 当前状态 / 基线 / L3 结果 | T0、T4、T6 |

> 不新增 defcustom → `docs/configuration.md` **不改**（该文件只列用户可配置变量）。若评审要求把去抖时长暴露为 defcustom，则需同时更新 `docs/configuration.md`。

本任务不触及 API 文档 / 错误码文档 / README（无新接口、无错误码、无用户配置项变更）。

## 验证标准（L1/L2/L3）

**L1（静态检查，必须通过）**

- `cd emacs/seshat-reader && make all` → 退出码 0，**零 warning、零 error**（`make all` 内含 `checkdoc`；既有基线为 11 个 `.el` 全通过）。
- 判据：`make all 2>&1 | grep -E "Warning|Error"` 无输出（注意：`grep -i error` 会误命中 `with-demoted-errors` 字样，勿据此判 error）。
- `elisp-dev-mcp` 的 `elisp_check_parens` 对 `seshat-reader.el` 与 `emacs/tests/seshat-reader-resize-test.el` 均 ok。

**L2（ERT，功能验证）**

- 执行：`cd /home/thomas/WorkSpace/notes/emacs/seshat-reader && make all`（生成 `seshat-render-core.so`；否则 `require 'seshat-reader` 会触发 `yes-or-no-p` 阻塞）→ 然后每个测试文件各跑一次：

  ```
  cd /home/thomas/WorkSpace/notes && \
  emacs --batch -Q \
    -L emacs -L emacs/seshat-reader \
    -L /home/thomas/WorkSpace/emacs-taf/ecss    -L /home/thomas/WorkSpace/emacs-taf/ecss/lisp \
    -L /home/thomas/WorkSpace/emacs-taf/ebox    -L /home/thomas/WorkSpace/emacs-taf/ebox/lisp \
    -L /home/thomas/WorkSpace/emacs-taf/etaf    -L /home/thomas/WorkSpace/emacs-taf/etaf/lisp \
    -L /home/thomas/WorkSpace/emacs-taf/etaf-ui -L /home/thomas/WorkSpace/emacs-taf/etaf-ui/lisp \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
    -L /home/thomas/thomas-emacs/.local/straight/build-31.1/compat \
    -l emacs/tests/<TEST-FILE>.el \
    -f ert-run-tests-batch-and-exit; echo "EXIT=$?"
  ```

- 判据：
  - `emacs/tests/seshat-reader-resize-test.el`（新）：`unexpected = 0`，用例 = 13，覆盖「去抖次数 / 两分支选择 / vscroll 夹紧值」三类断言（见 T3 清单）。
  - 6 个既有文件：`unexpected = 0`；**跳过数 ≤ 2**（当前 `seshat-reader-translate-test.el` 的 2 例既有跳过），合计用例数 ≥ 194（181 + 新增 13）。
  - 任一文件 `unexpected > 0` 或跳过数 > 2 → 不通过。

**L3（真机 GUI 手工，逐条勾选）**

- [ ] L3-1 `C-c C-l` 开批注面板：reader 窗口变矮后页面**完整可见且贴合高度**、水平居中、无右侧裁切；再按一次关闭 → 页面重新贴满高度。预期 `scale-source` 为 `fit`（`M-: (window-parameter nil 'scale-source)` 得 `fit`）。
- [ ] L3-2 `C-c C-t` 译文面板：同上（面板高度不同，验证第二种尺寸）。
- [ ] L3-3 `o` 打开 `*Outline of …*` 目录：reader 窗口变窄后页面贴合高度、左右无裁切；`q` 关闭目录后恢复原样。
- [ ] L3-4 先手动缩放（按 `+` 三次）再开关面板：**缩放比例不变**（`M-: (seshat-reader-current-doc-scale-value)` 前后相同）、`scale-source` 为 `manual`；页面顶端不被推出窗口、底部无异常空白（vscroll 已夹紧）。
- [ ] L3-5 鼠标拖动 reader 与面板之间的分割线：拖动过程中不卡顿、无连续重排抖动；停手约 0.15s 后页面贴合一次；连续拖 3 次无残留错位（这是去抖窗口 H6 的实测判据）。
- [ ] L3-6 按 `W`（fit-to-width）后开关面板：宽度贴合、左右无裁切；`scale-source` 为 `fit`。
- [ ] L3-7 `M-x seshat-reader-presentation-mode` 开/关：页面贴合行为与改动前一致（`mode-line-format` 局部为 nil / 恢复），无额外闪烁。
- [ ] L3-8 `emacs --daemon` + `emacsclient -c` 下重复 L3-1：若 idle timer 正常触发则勾选；若不触发，记录现象并执行 D3 降级路径 1（改固定 timer），改后重新勾选。

> batch 环境无窗口系统（`seshat-reader-fit-to-height` 会报 `Window system frame should be used`），故 L3 不可自动化，必须由用户在 GUI 下逐条确认。

**回滚**：改动集中在 `seshat-reader.el` 一个文件 + 一个新测试文件 + 文档；验证循环耗尽时 `git checkout -- emacs/seshat-reader/seshat-reader.el`（删新测试文件）即回到 T0 状态；T0 的 `pre-reader-resize` tag 为最终兜底。

## 注意事项

- **ERT 必须用 `emacs -Q --batch`，禁止 `emacsclient`**：不得干扰用户正在使用的 Emacs 会话。`-L` 路径按上文命令写全（ecss / ebox / etaf / etaf-ui 各含 `lisp` 子目录两条；gt / pdd / posframe / compat 指向 `straight/build-31.1/`），缺任一路径会导致部分测试文件加载失败。
- **修改的是 vendored 派生文件** `seshat-reader.el`：按 `VENDORED.md`「按文件的本地改动清单」追加记录（T5）。**不得删除或覆盖**任何自研扩展文件：`seshat-reader-select.el`、`seshat-reader-annotation.el`、`seshat-reader-annotation-queue.el`、`seshat-reader-sidebar.el`、`seshat-reader-etaf.el`、`seshat-reader-reference.el`、`seshat-reader-translate.el`。
- **timer 必须 buffer-local 且可取消**：`seshat-reader--resize-timer` 用 `defvar-local`；每次触发先 `cancel-timer`（`timerp` 守卫）；回调闭包捕获 buffer 并 `buffer-live-p` 检查；`kill-buffer-hook` 里补取消。多个 reader buffer（分屏开两个文档）不得互相取消对方的 timer。
- **不得改变 `seshat-reader--center-page` 的既有语义**：它是滚动/翻页/旋转/恢复等十余处命令的公共依赖，改它风险高；新逻辑必须外挂在 handler 里，`--center-page` 保持零改动（L1 用 `git diff` 核对）。
- **不得改变 `seshat-reader--set-window-vscroll` 的语义**：新夹紧函数独立实现（补 `max 0` 下界），不改原函数（否则滚动命令行为变化）。
- **`scale-source` 的 window parameter 写入统一走 `doc-scale-page`**：禁止在命令里分别 `set-window-parameter`，避免 source 与 scale 分步更新的中间态。
- **不新增 defcustom**：去抖时长与降级开关用内部 `defvar`，避免新增用户配置面与 `docs/configuration.md` 同步义务。
- **任务边界**：本计划只做「尺寸变化自适应」，不顺手改 PDF 文本选区层、不改 `--center-page` 的宽度居中语义（后者记 tech-debt）、不动面板/目录的显示策略。
- **`git status` 期望**：本批次完成后仅 `emacs/seshat-reader/seshat-reader.el`（M）、`emacs/tests/seshat-reader-resize-test.el`（??）与五处文档（M）属本计划改动；其它 `M`/`??`（如 M10.3 的 Go/Android 改动）属并行批次，**不得触碰**。
- **提交纪律**：每次 commit 使用简体中文提交信息；禁止 `git add .`，按精确路径 add。

## 基线

> **占位**：T0 执行后填写（不要凭推测填数）。

### S1 git 安全点

| 项 | 值 |
|---|---|
| 分支 / HEAD | 待填 |
| 轻量 tag | 待填（建议 `pre-reader-resize`） |
| 工作区状态 | 待填 |

### S2 Emacs L1 基线

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cd emacs/seshat-reader && make all` | 待填 | 待填 |

### S3 ERT 基线

| 测试文件 | Ran | passed | skipped | unexpected |
|---|---|---|---|---|
| `seshat-reader-annotation-queue-test.el` | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-annotation-test.el` | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-etaf-test.el` | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-reference-test.el` | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-sidebar-test.el` | 待填 | 待填 | 待填 | 待填 |
| `seshat-reader-translate-test.el` | 待填 | 待填 | 待填 | 待填 |
| **合计** | 待填 | 待填 | 待填 | 待填 |

> 参考：2026-10-22 的 M10.3 T0 实测（同一 HEAD `38eea5f`）为 181 / 179 / 2 / 0，本计划 T0 需独立复核（不得直接抄写）。
