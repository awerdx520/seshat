# 阅读器尺寸变化：即时几何适配 + W/H 适配模式持久化

> 行号约定：简写 `:NNN` 指 `emacs/seshat-reader/seshat-reader.el` 第 NNN 行；其它文件写全名。行号取自 2026-10-23 实测（HEAD `9efafd1`）。

## 当前状态

- 阶段：**Phase 4（完成）** · T1–T6 全部 `[x]`，2026-10-23 归档到 `openspec/completed/`
- 已确认：方案 ✅（用户 2026-10-23 确认）、计划 ✅（用户 2026-10-23 确认）
- 验证：L1 `make all` EXIT=0、警告集 **33 → 33**（零新增，逐条 diff）；L2 全仓 ERT **379 例全绿** / 0 unexpected / 0 skipped（resize 30 → **67** 例）；L3 真机验收通过（开关目录第一帧即居中、`W` / `H` 后仍保持该维度、打开文档无「先小后大」、拖分割线无卡顿），隔离实例逐帧测量首帧误差 ≤0.5px
- 关键结论：**居中与几何都交给 redisplay**——居中用页面 overlay 的 `before-string` + `:align-to`（位置在布局阶段求值，Lisp 侧不需要知道窗口宽度），几何用改写 image spec 的 `:width` / `:height`（显示层缩放，不重渲染）；C 侧重渲染只负责事后提升清晰度，「先跳一下再重绘」的两帧因此结构性消失
- 2026-10-23 追加（第二轮）：契约变更——原「1% 偏差闸」改为「`render-scale` 与 `scale` 相等则不重渲染」；居中从 `line-prefix` + hscroll 改为 `before-string` + `:align-to`（超宽页仍走 `line-prefix`）；新增 `--first-fit`（首次打开不再渲染两次）与拖拽抑制 `--drag-threshold`

## 背景（真机反馈）

1. 按 `W`（按宽度适配）后按 `o` 打开目录，页面变成**按高度适配**。
2. 窗口尺寸变化时画面「先跳动一下、再重新绘制」。

## 根本问题

**根因 1（适配模式丢失）**：`seshat-reader-fit-to-width`（`:405`）与 `seshat-reader-fit-to-height`（`:396`）都把 `scale-source` 记成同一个值 `'fit`；`seshat-reader--refit-window`（`:935`）对任何非 `manual` 的窗口一律用 `seshat-reader--contain-scale`（`:416`）重算 `min(按宽, 按高)`。按宽适配时页面通常纵向溢出，`scale_h < scale_w`，于是 contain 必然退化成按高度。**适配维度信息在写入时被丢弃**。

**根因 2（结构性两帧）**：窗口尺寸变化 → `seshat-reader--window-size-change`（`:834`）同步调 `seshat-reader--recenter-window`（`:864`），后者只重算 `line-prefix`/hscroll 并夹 vscroll，**用的仍是旧渲染尺寸**（画面第 1 次变化：位置跳一下）；0.15s idle 后 `--refit-window` 才调 `seshat-reader-doc-scale-page`（`:343`）真正重新渲染（画面第 2 次变化：尺寸变）。这是「页面显示尺寸只能靠 C 侧同步重渲染才能改，而重渲染只能在 idle 安全执行」的结构性约束。

**破法（已实测）**：Emacs image spec 的 `:width`/`:height` 是**显示尺寸**，只改这两个属性即可改变显示与布局尺寸，原地修改**立即生效、无需 `image-flush`**（2026-10-23 在 pure 实例实测：spec 200×100 → 100×50 → 400×200，`image-size` 与 `window-text-pixel-size` 同步线性变化）。因此几何适配可以在尺寸变化 hook 内**同步**完成（同一次 redisplay 即最终几何），C 侧重渲染降级为「事后提升清晰度」，不再改变几何。

## 目标

1. `W` / `H` 成为**持久适配模式**：之后窗口尺寸变化仍按该维度适配（`W` 保持按宽度填满，允许纵向溢出需滚动）。
2. 尺寸变化的几何调整在**一次 redisplay** 内完成，消除「先跳一下再重绘」的两帧。
3. 保留清晰度：idle 时做一次重渲染，几何尺寸不变（画面只从模糊变清晰）。
4. 不改 C 模块；不改 `seshat-reader-sidebar.el` / `seshat-reader-outline.el`；不重写 vscroll 上限公式。

## 设计

### D1 适配模式持久化：window parameter `fit-mode`

- 取值 `contain` / `width` / `height`，未设置视作 `contain`。
- 写入点（只加一行，不改算术）：
  - `seshat-reader-fit-to-width`（`:405`）末尾 `(set-window-parameter nil 'fit-mode 'width)`；
  - `seshat-reader-fit-to-height`（`:396`）末尾 `(set-window-parameter nil 'fit-mode 'height)`；
  - `seshat-reader-presentation-mode`（开启时调 `fit-to-height`）因此自动得到 `height`，无需额外改动。
- `+` / `-` / `0`（`enlarge`/`shrink`/`reset`）仍写 `scale-source = manual`；`scale-source` 的优先级**高于** `fit-mode`（manual 时不看 fit-mode）。
- 首次打开、书签恢复等路径不写 `fit-mode` → 默认 `contain`，与现状一致（D6 的 contain 语义不变）。

### D2 `seshat-reader--fit-scale`：按模式求目标 scale

新增只读函数（`--contain-scale` 本体**不改**，保证既有 16 例测试零回归）：

```elisp
(defun seshat-reader--window-fit-mode (&optional window)
  "Return WINDOW's fit mode: `contain', `width' or `height'."
  (or (window-parameter (or window (selected-window)) 'fit-mode) 'contain))

(defun seshat-reader--fit-scale (&optional window)
  "Return the scale WINDOW's page should have, according to its fit mode."
  (let* ((window (or window (selected-window)))
         (mode (seshat-reader--window-fit-mode window)))
    (if (eq mode 'contain)
        (seshat-reader--contain-scale window)
      (let ((native (seshat-reader--native-page-size window)))
        (if (and native (> (car native) 0) (> (cdr native) 0))
            (if (eq mode 'width)
                (/ (window-body-width window t) (float (car native)))
              (/ (window-body-height window t) (float (cdr native))))
          1.0)))))
```

### D3 `seshat-reader--native-page-size`：原始（未缩放）像素尺寸缓存

```elisp
(defun seshat-reader--page-image-spec (window)
  "Return WINDOW's page image spec, or nil if it is not an image yet."
  (let ((overlay (seshat-reader-current-doc-overlay window)))
    (when (overlayp overlay)
      (let ((display (overlay-get overlay 'display)))
        (when (and (consp display) (eq (car display) 'image))
          display)))))

(defun seshat-reader--native-page-size (window)
  "Return the unscaled pixel size of WINDOW's page as (W . H), or nil.

The value is cached in the window parameter `native-size' as
\(PAGE . (W . H)), together with the page number it was measured on: two
pages of the same document may have different sizes, so a cached size is
reused only while the window still shows PAGE.  The cache is also dropped
when the page is re-rendered at a new resolution
\(`seshat-reader-doc-scale-page'), the document is reloaded
\(`seshat-reader--render-buffer') or the page is rotated
\(`seshat-reader-rotate-clockwise' / `-counter-clockwise')."
  (let* ((page (seshat-reader-current-doc-pagenumber window))
         (cached (window-parameter window 'native-size)))
    (if (and (consp cached) (equal (car cached) page) (consp (cdr cached)))
        (cdr cached)
      (let* ((spec (seshat-reader--page-image-spec window))
             (scale (seshat-reader-current-doc-scale-value window))
             (w (and spec (image-property spec :width)))
             (h (and spec (image-property spec :height))))
        (when (and (integerp w) (integerp h) (> w 0) (> h 0)
                   (numberp scale) (> scale 0))
          (let ((native (cons (/ (float w) scale) (/ (float h) scale))))
            (set-window-parameter window 'native-size (cons page native))
            native))))))
```

- **硬约束**：image spec 是 `(image :type … :width … :height …)`，整表**不是** plist；读写属性必须用 `image-property` / `(setf (image-property …))`，`(plist-put (copy-sequence spec) …)` 会报 `Wrong type argument: plistp`（2026-10-23 实测）。
- **缓存按页号失效**：`native-size` 的值形如 `(PAGE . SIZE)`，翻页后页号不符即重算，因此翻页路径（`next-page` / `previous-page` / `first-page` / `last-page` / `goto-page`）**不需要**显式清理缓存。同一文档不同页的尺寸可以不同（MuPDF 按每页 bbox 渲染）。

### D4 `seshat-reader--apply-display-scale`：即时几何缩放（不重渲染）

```elisp
(defun seshat-reader--apply-display-scale (window scale)
  "Resize WINDOW's page to SCALE by rewriting the image spec, without rendering.

Returns non-nil when the spec changed.  The window parameters `scale' and
the buffer-local `seshat-reader--recent-scale-fallback' are updated
together with the spec, so the invariant \"spec size / `scale' = native
size\" keeps holding for `--contain-scale', `--fit-scale' and the vscroll
upper bound."
  (when (and (windowp window) (numberp scale) (> scale 0))
    (let* ((spec (seshat-reader--page-image-spec window))
           (native (and spec (seshat-reader--native-page-size window)))
           (w (and spec (image-property spec :width)))
           (h (and spec (image-property spec :height)))
           (new-w (and native (max 1 (round (* (car native) scale)))))
           (new-h (and native (max 1 (round (* (cdr native) scale))))))
      (when (and (integerp new-w) (integerp new-h))
        (unless (and (equal w new-w) (equal h new-h))
          (ignore-errors (image-flush spec))
          (setf (image-property spec :width) new-w)
          (setf (image-property spec :height) new-h)
          (set-window-parameter window 'scale scale)
          (setq seshat-reader--recent-scale-fallback scale)
          t)))))
```

- 只改 `:width` / `:height`，**不动** `:data`；原地修改后无需 `image-flush`（实测）。
- 不改 `seshat-reader--get-current-doc-image-size`（`:334`）：它读的就是 spec 的 `:width`/`:height`，缩放后返回新显示尺寸，于是 `--center-page`、`--clamp-window-vscroll`、`--page-max-vscroll-pixels` 全部自动按新几何工作。
- 尺寸未变（`new-w`/`new-h` 与现值相同）时**不写** spec → 不触发无谓 redisplay。
- **改属性前先 flush 旧缓存**：`--apply-display-scale` 在写新尺寸之前调 `(ignore-errors (image-flush spec))`。image cache 以 spec 内容（含 `:width`/`:height`）为键，原地改尺寸会让旧键条目滞留到 `image-cache-eviction-delay`（默认 300s）；拖拽分割线可在数秒内造出几十个条目（A4 页面每条约 2 MB），提前 flush 可避免峰值内存膨胀。flush 在纯 tty 会话会因缺少 window-system frame 报错，故包在 `ignore-errors` 里——几何正确性不依赖 flush。

### D5 两阶段：hook 内同步几何 + idle 一次清晰化

**阶段 1（同步，hook 内）**：`seshat-reader--recenter-window`（`:864`）改为

```elisp
(unless (eq (seshat-reader--window-scale-source window) 'manual)
  (seshat-reader--apply-display-scale window (seshat-reader--fit-scale window)))
(seshat-reader--clamp-window-vscroll window)
(seshat-reader--center-page window)
```

即：先按模式把 spec 缩放到目标尺寸（纯 elisp、快），再夹 vscroll、再居中。三者都在同一次 redisplay 之前完成 → **第一帧就是最终几何，无中间帧**。manual 窗口不缩放，只夹紧 + 居中（语义不变）。

**阶段 2（idle，清晰化）**：`seshat-reader--refit-window`（`:935`）改为

```elisp
(unless (eq (seshat-reader--window-scale-source window) 'manual)
  (seshat-reader--apply-display-scale window (seshat-reader--fit-scale window)))
(let ((scale (seshat-reader-current-doc-scale-value window))
      (rendered (window-parameter window 'render-scale)))
  (unless (and (numberp scale) (numberp rendered) (= scale rendered))
    (with-selected-window window
      (seshat-reader-doc-scale-page scale 'fit))))
(seshat-reader--clamp-window-vscroll window)
(seshat-reader--center-page window)
```

- 语义变更：原「1% 偏差闸」替换为「**显示比例与已渲染分辨率不一致才重渲染**」。每次尺寸变化最多重渲染一次（idle 去抖已合并连续事件），且重渲染前后 spec 的 `:width`/`:height` 基本相同 → 无几何跳变。
- `render-scale` 是新的 window parameter，由 `seshat-reader-doc-scale-page`（`:343`）在成功后写入 `factor-clamped`，同时**清空 `native-size` 缓存**（渲染后的 spec 尺寸是权威值）。

**复用点的行为声明（`--handle-window-buffer-change`）**：D8 让该函数在「overlay 已存在」时复用 `--recenter-window`；改造后这里的 fit 窗口也会被 apply 一次并改写窗口 `'scale`。这是**有意为之**：新窗口/新 frame 显示同一文档时，尺寸往往与打开时不同，同步 apply 才能让第一帧就是正确几何；manual 窗口仍被 `unless manual` 守卫跳过。旧 `'scale` 被覆盖符合「显示比例跟随实际显示」的语义，跨 buffer 的页面/比例恢复仍由 `--window-create-function` 负责（它走 `doc-scale-page` 重新渲染）。该行为由 T4 第 20 例锁定，不再视为意外副作用。

### D6 失效点（必须清除缓存）

| 时机 | 位置 | 动作 |
|---|---|---|
| 重新渲染 | `seshat-reader-doc-scale-page`（`:343`） | `'render-scale = factor-clamped`；`'native-size = nil` |
| 重载文档 | `seshat-reader--render-buffer`（约 `:1300`，已有 `(set-window-parameter nil 'scale 1.0)`） | 追加 `'render-scale = nil`、`'native-size = nil` |
| 旋转 | `seshat-reader-rotate-clockwise`（`:1188`）/ `-counter-clockwise`（`:1195`） | 追加 `'native-size = nil`（页面宽高互换） |
| 窗口换 buffer / 重建 overlay | `seshat-reader--window-create-function`、`seshat-reader--handle-window-buffer-change` | 由 `doc-scale-page` 的清理间接覆盖；若实施时发现遗漏，在 overlay 重建处显式清 `native-size` |
| 翻页 | `next-page` / `previous-page` / `first-page` / `last-page` / `goto-page`（C 侧渲染另一页，页尺寸可能不同） | 无需显式清理：`native-size` 缓存带页号，页号不符即重算 |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| H1 | 只改 image spec 的 `:width`/`:height` 即改变显示与布局尺寸，原地修改立即生效、无需 `image-flush` | 事实✓（2026-10-23 pure 实例实测，含 `window-text-pixel-size` 真实布局像素） |
| H2 | image spec 是 `(image . PLIST)`，必须用 `image-property` 读写 | 事实✓（同上，`plist-put` 在整表上会报 `plistp` 错误） |
| H3 | `doc-scale-page` 在 resolution 相同时也强制重渲染并替换 overlay | 事实✓（`render/render-core.c:1102-1125`：无条件 `build_cache_window` + `wait_for_cached_page` + `display_cached_page`） |
| H4 | 用户 `W` 之后，窗口尺寸变化应继续按宽度填满（允许纵向溢出） | 用户显式（2026-10-23 确认） |
| H5 | 位图缩放后的画质损失可由一次 idle 重渲染补偿，用户可接受「模糊→清晰」替代「跳动→重绘」 | 假设?（L3 真机确认；不成立则退回 D5 阶段 2 之前的两帧行为并记 tech-debt） |
| H6 | 尺寸变化 hook 内做一次 elisp 层 image spec 缩放不会造成拖拽卡顿（A4 页面约 600×850 px） | 假设?（L3-5 确认；不成立则降级为「只在 idle 做 apply」，接受一帧中间态） |
| H7 | `--contain-scale` 不动不会影响新路径（新路径只经 `--fit-scale` 的 contain 分支调它） | 事实✓（`:416` 是纯计算函数，无副作用） |
| H8 | `render-scale` 与 `'scale` 用 `=` 比较是安全的：`doc-scale-page` 写回 C 侧 clamped scale（`fz_clamp(scale*72, MINRES, MAXRES)/72`，即 0.25–11.81），而 apply 写入的目标值可能超界；超界时两者不等 → 多一次重渲染，重渲染后写回 clamped 值 → 下一轮相等，不振荡 | 事实✓（`render/render-core.c:1108`、`render/render-core.h` 的 MINRES/MAXRES）+ 推理 |

## 任务

### [x] T1 适配模式（D1 / D2）

- 动作：新增 `seshat-reader--window-fit-mode`、`seshat-reader--fit-scale`；`fit-to-width` / `fit-to-height` 各追加一行 `fit-mode` 写入；`--contain-scale` **不改**。
- 依赖：无
- 验收：`fit-to-width` 后 `(window-parameter nil 'fit-mode)` = `width`；`fit-to-height` 后 = `height`；未设置时 `--window-fit-mode` 返回 `contain`；`--fit-scale` 三模式数值符合 `min`/width/height 语义；`make all` 警告集零新增。
- ✅ 2026-10-23 完成：L1 `make all` EXIT=0、警告集 33 条与基线逐条 diff **零新增**；实现要点：`fit-to-width` / `fit-to-height` 末尾各追加一行 `fit-mode` 写入，新增 `--window-fit-mode` + `--fit-scale`（`contain` / `width` / `height` 三值分支），`--contain-scale` 本体未动（既有测试零回归）。

### [x] T2 即时几何缩放（D3 / D4）

- 动作：新增 `seshat-reader--page-image-spec`、`seshat-reader--native-page-size`、`seshat-reader--apply-display-scale`。
- 依赖：T1
- 验收：对假 spec `(image :type pbm :data "x" :width 200 :height 100 :scale 1)` 与 `'scale` 1.0，`--apply-display-scale` 传 0.5 → spec 变 100×50、`'scale` = 0.5；传相同值不写 spec（用 `setf` 计数桩验证）；无 spec / size 非法时静默返回 nil 不报错；`--native-page-size` 在页号变化后不复用旧缓存（`cl-letf` 桩页号 1→2，断言第二次重新读取 spec）
- ✅ 2026-10-23 完成：L1 `make all` EXIT=0、警告集 33 条与基线逐条 diff **零新增**；实现要点：新增 `--page-image-spec` / `--native-page-size`（缓存 `(PAGE . (W . H))`，页号不符即重算）/ `--apply-display-scale`（只改 spec 的 `:width`/`:height` 并同步写窗口 `scale`，写前 `ignore-errors` flush 旧缓存）。

### [x] T3 两阶段接入 + 缓存失效（D5 / D6）

- 动作：改 `--recenter-window`（先 apply 再 clamp 再 center）、`--refit-window`（apply + 按 `render-scale` 决定重渲染）、`doc-scale-page`（写 `render-scale`、清 `native-size`）、`--render-buffer`（清两个参数）、两个 rotate 命令（清 `native-size`）。
- 依赖：T2
- 验收：`--recenter-window` 在 fit 模式下按「apply → clamp → center」顺序执行（用 `cl-letf` 桩断言调用序列），manual 模式**不**调 apply；`--refit-window` 在 `render-scale` 与 `scale` 相等时不调 `doc-scale-page`，不等时调一次且参数为该 scale 与 `'fit`；`doc-scale-page` 后有 `render-scale` 且 `native-size` 为 nil。
- ✅ 2026-10-23 完成：L1 `make all` EXIT=0、警告集 33 条与基线逐条 diff **零新增**；实现要点：`--recenter-window` 改为 hook 内**同步** apply（第一帧即最终几何），`--refit-window` 改为「apply + 仅当 `render-scale` ≠ `scale` 时重渲染一次」，`doc-scale-page` 写 `render-scale` 并清 `native-size`，`--render-buffer` 与两个 rotate 命令清缓存。

### [x] T4 新增 ERT（≥20 例，追加到 `emacs/tests/seshat-reader-resize-test.el`）

必须覆盖：

1. `--window-fit-mode` 默认 `contain`
2. `--fit-scale` contain 分支等价于 `--contain-scale`（桩）
3. `--fit-scale` width 分支 = 窗口像素宽 / native 宽
4. `--fit-scale` height 分支 = 窗口像素高 / native 高
5. `--fit-scale` 无 native（无 spec）→ 1.0
6. `--apply-display-scale` 修改 spec 与 `'scale`
7. `--apply-display-scale` 相同尺寸不重写（`setf` 计数为 0）
8. `--apply-display-scale` 无 spec → nil 且不报错
9. `--native-page-size` 由 spec/scale 推算并写入缓存
10. `--native-page-size` 命中缓存后不再读 spec（桩 `--page-image-spec` 计数）
11. `--recenter-window` fit 模式调用顺序 apply → clamp → center
12. `--recenter-window` manual 模式跳过 apply
13. `--refit-window` `render-scale` 与 `scale` 相等 → 零 `doc-scale-page` 调用
14. `--refit-window` `render-scale` 不等 → 恰好一次 `doc-scale-page`，参数为 `(scale 'fit)`
15. `fit-to-width` / `fit-to-height` 写入 `fit-mode`（两例，桩 `doc-scale-page`）
16. `--native-page-size` 缓存带页号：页号 1 时记录，页号变为 2 后重新推算（桩 `seshat-reader-current-doc-pagenumber` 与 `--page-image-spec`）
17. `--native-page-size` 页号 nil（未建立文档）且无 spec → 返回 nil、不写缓存、不报错
18. `--native-page-size` 多窗口隔离：两个窗口显示同一 buffer 的不同页，各自返回本页尺寸，互不覆盖
19. rotate 命令清除 `native-size`（桩 `seshat-reader-dyn--rotate-page`，断言该窗口的 `native-size` 参数变 nil）
20. `--handle-window-buffer-change` 复用点：fit 窗口经该路径调 `--recenter-window` 时 apply 一次并写 `'scale`；manual 窗口 apply 零次

- 桩点约定：`(setf (image-property …))` 的 setter 具体符号名在实施时先用 `(symbol-function 'image-property)` 与 `(get 'image-property 'gv-setter)` 确认后再桩；若难以桩，则改用「改前/改后读回 `image-property` 值」断言，**不得**为凑计数桩到无关函数。

- 依赖：T3
- 验收：新增用例全绿；整套 11 个文件 `unexpected = 0`；既有 30 例 resize 测试无回归（其中原先断言「偏差闸」的两例需按新契约改为「`render-scale` 相等则不重渲染」——这是**契约变更**，必须在该用例注释里注明，不得删除用例）。
- ✅ 2026-10-23 完成：L2 全量 11 个测试文件 **363 例 / 363 passed / 0 unexpected / 0 skipped**（resize 测试 30 → **51** 例，新增 **21** 例）；变异自检 **3 处**（删 `fit-mode` 写入 / apply 只改 spec 不写 `scale` / 去掉 `render-scale` 判断）全部按预期变红。

### [x] T5 文档

- `emacs/seshat-reader/VENDORED.md`：追加第 ⑧ 项（`fit-mode` / `--fit-scale` / `--apply-display-scale` / `native-size` / `render-scale`）
- `CHANGELOG.md`：新增条目（W/H 持久化 + 尺寸变化即时几何适配）
- `openspec/decisions.md`：记录「显示层缩放替代同步重渲染以消除两帧」与「fit-mode 取代单一 fit 来源」
- `openspec/tech-debt.md`：① `--contain-scale` 与 `--fit-scale` 的 contain 分支并存；② `seshat-reader-default-fit` 仍为 no-op；③ 位图缩放与 `image-flush` 的交互未在真机长时间验证；④ image cache 条目累积（原地改 spec 尺寸使旧键滞留，缓解手段是 apply 前 `ignore-errors` flush，但仍缺长时间真机内存观测）
- `docs/emacs-reader.md`：§3 补「W/H 是持久模式」；§12 更新已知限制
- `openspec/active/roadmap.md`：登记本项
- 依赖：T3
- 验收：上述 6 个文件更新完成，且不新增 defcustom。
- ✅ 2026-10-23 完成：6 个文档文件（`VENDORED.md` / `CHANGELOG.md` / `openspec/decisions.md` / `openspec/tech-debt.md` / `docs/emacs-reader.md` / `openspec/active/roadmap.md`）已更新，未新增 defcustom。

### [x] T6 真机验收与归档

- L3 清单（batch 不可自动化）：
  1. 按 `W` → 开 `o` 目录 → 页面保持**按宽度填满**（不被缩成按高度）
  2. 同上，再关 `o` → 页面重新按宽度填满，全程无位置跳动
  3. 按 `H` → 开关目录 → 保持按高度
  4. 手动 `+` 三次 → 开关目录 → scale 不变（manual 优先）
  5. 拖分割线 → 无卡顿；停手后只出现一次清晰化（无几何跳变）；同时观察拖拽期间峰值内存与响应（`memory-info` 或 `htop`），若出现明显卡顿或内存持续上涨，按 H6 降级
  6. 旋转 `r` 后再开关目录 → 几何正确（`native-size` 缓存失效生效）
- 归档：计划移入 `openspec/completed/`；`memory_lesson_save` 沉淀（按 `rules/workflow.md` 记忆归属：涉及 Emacs 全局行为时省略 `project`）
- 依赖：T4
- 验收：6 条逐条记录通过/失败；失败则按假设 H5/H6 的降级路径处理并记 tech-debt。
- ✅ 2026-10-23 完成：真机验收全过——`o` 开关目录第一帧即居中（无「先跳到一侧再居中」）、`W` / `H` 之后开关目录仍保持该维度、打开文档无「先小后大」两次变化、拖分割线全程跟手且停手后只清晰化一次、旋转后开关目录几何正确；隔离实例逐帧测量开关目录 / `W` / `H` / 新窗口的**首帧误差 Δ≤0.5px**（旧 `line-prefix` 实现窗口变窄首帧偏 −524px）。计划已 `git mv` 至 `openspec/completed/`。

## 文档清单

| 文档 | 变更域 |
|---|---|
| `emacs/seshat-reader/VENDORED.md` | 追加第 ⑧ 项本地改动 |
| `CHANGELOG.md` | 用户可感知行为变更 |
| `openspec/decisions.md` | 架构决策（显示层缩放、fit-mode） |
| `openspec/tech-debt.md` | 四条技术债 |
| `docs/emacs-reader.md` | 使用说明与已知限制 |
| `openspec/active/roadmap.md` | 里程登记 |

- 不新增 defcustom → `docs/configuration.md` 不改；不涉及端点/错误码 → `docs/api.md`、`docs/errors.md` 不改。

## 验证标准

- **L1**：`cd emacs/seshat-reader && rm -f *.elc && make all` 退出码 0，警告集相对基线（33 条）**零新增**（判据是与基线逐条 diff，不是 `grep Warning` 为空）。
- **L2**：`emacs/tests/` 全部 11 个文件，基线 **342 例 / 342 passed / 0 skipped / 0 unexpected**；改动后新增 ≥20 例、`unexpected = 0`、`skipped ≤ 2`。
- **L3**：上述 6 条真机验收。
- **变异自检**（至少 3 处）：① `fit-mode` 写入删掉 → T4 第 15 例红；② `--apply-display-scale` 改成只改 spec 不改 `'scale` → 第 6 例红；③ `--refit-window` 的 `render-scale` 判断去掉 → 第 13 例红。

## 回滚

- 代码集中在 `emacs/seshat-reader/seshat-reader.el` 一个文件 + `emacs/tests/seshat-reader-resize-test.el`。
- 代码回滚：`git checkout -- emacs/seshat-reader/seshat-reader.el emacs/tests/seshat-reader-resize-test.el` 回到 HEAD 状态；若新增测试文件仍为未跟踪状态，需 `git clean -fd -- emacs/tests/seshat-reader-resize-test.el` 一并清理。
- 文档回滚：T5 涉及 6 个文件（`emacs/seshat-reader/VENDORED.md` / `CHANGELOG.md` / `openspec/decisions.md` / `openspec/tech-debt.md` / `docs/emacs-reader.md` / `openspec/active/roadmap.md`），需逐个 `git checkout -- <路径>`；本计划文件本身移回 `openspec/active/` 或删除。

## 注意事项

1. **不得改 `--contain-scale` 本体**：既有 16+ 例测试直接锁定它。
2. **不得改 vscroll 上限公式**（`--page-max-vscroll-pixels`）与 `--set-window-vscroll`。
3. **image spec 读写只能用 `image-property`**，禁止对整表 `plist-put`。
4. `--apply-display-scale` 必须同时更新 spec 尺寸与 `'scale`，否则「spec / scale = native」不变式破裂，`--contain-scale` 与 vscroll 上限都会算错。
5. `--recenter-window` 在 hook 内**只做纯 elisp 几何**，禁止在其中调用 `doc-scale-page`（同步渲染会拖死 redisplay）。
6. 阶段 2 的重渲染必须包在 `with-selected-window` 里（C 侧按选中窗口工作），但 apply / clamp / center 都用显式 window 参数，不切换选中窗口（避免 mode-line 闪烁）。
7. `window-size-change-functions` 的 buffer-local 条目收到的是 **window**（不是 frame），两形态都要保留（既有 D2 结论）。

## 复盘：为什么绕了这么多轮

1. **方向一开始就错了**：以为「居中算得不够快」，实际是「算得再快也赶不上 redisplay」——`window-size-change-functions` 在 redisplay **之后**才跑，hook 内、命令内、`pre-redisplay-functions` 内的 Lisp 侧重算都只能把误差压到「一帧内的某处」；把位置交给 redisplay 求值（`:align-to`）才一步消掉中间帧。
2. **`align-to` 传数字的坑**：`(-0.5 . N)` 的 N 若是数字会被当成「字符宽倍数」，实测前缀宽度算成 0、页面贴左；必须传图像 spec 对象本身（`(cons -0.5 spec)`）。
3. **隔离实例的字体度量与真机不同**：字符宽/行高不同，`line-prefix` + hscroll 那套「像素换列」的算术在两边得出不同偏移，测量结论一度对不上；最终靠「不依赖字符宽度」的 `:align-to` 绕开了整类问题。
4. **`pre-redisplay-functions` 的 arity**：它按窗口逐个调用、每次传一个参数，零参函数在真机上直接报错，而 batch 不 redisplay、测试永远发现不了——凡 hook 都要先确认它传什么。
5. **教训**：遇到「位置/尺寸赶不上重绘」的问题，先问「能不能让 redisplay 自己算」；用 Lisp 追帧是徒劳，改 image spec 尺寸也比触发重渲染便宜两个数量级。
