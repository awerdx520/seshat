;;; seshat-reader-resize-test.el --- Tests for window resize refit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `seshat-reader' 窗口尺寸变化自适应（M12 T3）的 ERT 测试套件：idle 去抖、
;; refit 的 fit/manual/未设置三分支、`--refitting' 防重入、四级守卫（死窗口 /
;; 异 buffer / 模式已退出 / overlay 失效）、vscroll 夹紧四态、`scale-source'
;; 语义、presentation-mode 不回归、多窗口各处理一次、死 buffer 的生命周期。
;;
;; 2026-10-23（smooth-fit T4）追加第 31~51 节：fit-mode 持久化、`--fit-scale'
;; 三模式、`--native-page-size' 缓存（含页号失效与多窗口隔离）、
;; `--apply-display-scale' 原地改 spec、`--recenter-window' 同步 apply、
;; `--refit-window' 的 `render-scale' 闸、rotate 清缓存与
;; `--handle-window-buffer-change' 的复用点。
;;
;; 2026-10-23（首帧两帧修复）追加第 58~59 节：`--first-fit' 的显示层缩放快
;; 路径（不重渲染，首帧即最终尺寸）与 spec 尚不可用时的同步重渲染回退。
;;
;; 2026-10-23（默认 fit 模式）追加第 68~75 节：`--normalize-default-fit' 把
;; `seshat-reader-default-fit' 的取值（含两个旧函数值与未知值的降级）规整为
;; `contain' / `width' / `height'，以及 `--initial-fit-mode' 的「已有
;; `fit-mode' 参数优先、否则取归一化默认值」语义。
;;
;; 2026-10-23（默认 fit 模式 T2）追加第 76~78 节：`--first-fit' 改按窗口的
;; 初始适配模式求 scale（先记录 `fit-mode'，再调 `--fit-scale'），`contain'
;; 默认路径仍等价于旧行为（转调 `--contain-scale'），spec 不可用时回退重渲染
;; 也用模式相关的 scale。
;;
;; 2026-10-23（默认 fit 模式 T3）追加第 79~80 节：`--window-create-function'
;; 为新窗口写入归一化后的初始 `fit-mode'，且已有 `fit-mode' 的窗口不被
;; `seshat-reader-default-fit' 覆盖。
;;
;; **契约变更（2026-10-23）**：`--refit-window' 原先用「目标 scale 与当前
;; scale 相对差 ≤1% 则不重渲染」的偏差闸；改为「窗口的 `render-scale' 窗口
;; 参数（overlay 上次渲染所用的分辨率）与当前 `scale' 相等则不重渲染，不等
;; 则恰好重渲染一次」。原因：几何适配已由 `--apply-display-scale' 在尺寸变化
;; hook 内同步完成，重渲染前后几何相同，重渲染只负责提升清晰度，故判据是
;; 「已渲染分辨率 vs 显示比例」而不是「新旧目标比例差」。
;;
;; **契约变更（2026-10-26，P1 多页布局批次 2）**：本文件删除 27 个用例
;; （first-fit 5 个、fit-to-height/width 各 1 个、native-page-size 2 个、
;; recenter-window 3 个、refit 6 个、rotate 1 个、size-change 2 个、
;; window-buffer-change 4 个、window-create 2 个）。这些用例断言的是**单页
;; overlay 几何**（页面挂在窗口参数 `overlay' 上、vscroll 夹紧、per-window
;; `native-size' 缓存以窗口参数 `page' 为键、`--window-create-function' /
;; `--handle-window-buffer-change' 的建/复用路径），而多页布局已把页面搬进
;; buffer 页行、把页号改为视口顶页派生、删掉那两个函数。T4 会以多页语义重写
;; 这批断言（逐页居中 / 逐页 native size / 批量 scale），届时不是「恢复旧用例」。
;; 保留的 53 个用例要么与多页布局无关（去抖、守卫、normalize、初始 fit 模式），
;; 要么其桩替仍模拟出 overlay 参数因而继续成立。
;;
;; **P1 批次 8（T9）：用例更名，断言未改。** 三个用例名还带着已删除的单页函数
;; 名（`--contain-scale-*` → `--base-fit-scale-*`、`--native-page-size-cache-hit`
;; → `--multipage-native-size-cache-hit`），两个已删除用例的占位名同步更名；
;; 另删掉第 76~80 五个空节标题（其正文在批次 2 删除，只剩标题）。
;;
;; **契约变更（2026-10-26，P1 多页布局批次 6 / T7）**：本文件删除第 9、
;; 10、16、47 四节，外加 `--refit-counts' / `--run-pending-counts' 两个助手与
;; `--set-page-overlay' / `--set-page-spec' 两个夹具函数。它们断言/模拟的都是
;; 单页机制：vscroll 夹紧、`doc-scale-page' 的 `scale-source' 语义、
;; `--contain-scale' 的「未知尺寸退 1.0」、per-window `native-size' 缓存。
;; 对应函数已在 T7 从 `seshat-reader.el' 删除；多页语义的等价断言在第
;; 14/15/35/40 节（已改为 `--multipage-base-fit-scale' /
;; `--multipage-native-size'）与 `seshat-reader-multipage-test.el'。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   cd /home/thomas/WorkSpace/notes && \
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader \
;;     -l emacs/tests/seshat-reader-resize-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建（`seshat-reader'
;; 模块加载需要它）。
;;
;; 纪律：**不触网、不碰真实文档、不触 GUI**。动态模块函数
;; （`seshat-reader-dyn--scale-page' / `seshat-reader-dyn--close-doc'）与窗口
;; 访问函数一律用 `cl-letf' 桩替；窗口对象取 batch 帧上的真实窗口，因此
;; `with-selected-window' / `split-window' 无需额外桩；页面 overlay 用
;; `make-overlay' 在临时 buffer 内构造，不依赖真实渲染。
;;
;; 本套件全部用例都不需要外部包，故不使用 `skip-unless' / `ert-skip'——
;; skipped 必须恒为 0。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)

;;; 辅助函数

(defun seshat-reader-resize-test--reader-buffer ()
  "Create a temporary buffer whose `major-mode' is `seshat-reader-mode'.

The real `seshat-reader-mode' command is not used: it would try to open a
document through the dynamic module.  Only `major-mode' matters for the
`derived-mode-p' guard of `seshat-reader--refit-window'."
  (let ((buffer (generate-new-buffer " *seshat-reader-resize-test*")))
    (with-current-buffer buffer
      (setq major-mode 'seshat-reader-mode)
      (setq mode-name "Seshat Reader"))
    buffer))

(defun seshat-reader-resize-test--clear-window (window)
  "Remove the reader window parameters set by the resize tests from WINDOW."
  (dolist (parameter '(overlay scale scale-source render-scale native-size
                               fit-mode page))
    (set-window-parameter window parameter nil)))

(defun seshat-reader-resize-test--image-spec (&optional width height)
  "Create a page image spec that is WIDTH x HEIGHT pixels.

WIDTH and HEIGHT default to 200 and 100.  The spec has the shape the dynamic
module produces, `(image :type … :width … :height …)', so `image-property'
reads and writes it and `seshat-reader--apply-display-scale' can rewrite its
display size in place.  It is a plain list on purpose: no image has to be
decodable, and `image-flush' failing without a window-system frame is
already handled by the caller (`ignore-errors')."
  (list 'image :type 'pbm :data "x"
        :width (or width 200)
        :height (or height 100)
        :scale 1))

;; P1 T7 删除：per-window 页 overlay 与单页缩放助手（`--set-page-overlay'、
;; `--set-page-spec'）随 overlay 机制一起退役；几何一律由
;; `--geometry-buffer' 构造页行 + spec。

;; P1 T7 删除：`--refit-counts` / `--run-pending-counts` 两个助手只服务旧用例，
;; 用来数 `--contain-scale` / `doc-scale-page` / `--clamp-window-vscroll` 的调用
;; 次数；这三个函数已随单页机制退役，助手本身也无调用方，一并删除。

;;;; T4 多页几何夹具（P1：per-window overlay → 页行 + `display' spec）

;; 页面由「页行 + `display' 文本属性」承载之后，几何函数读的是页行里的 spec 与
;; buffer-local 的按页缓存，因此下面的用例不再需要 per-window overlay。

(defmacro seshat-reader-resize-test--with-window-pixels (width height &rest body)
  "Run BODY with every window's pixel size stubbed to WIDTH x HEIGHT.

The batch frame is 80x23 *pixels* (`frame-char-width' is 1), so the real
geometry would clip every page; the stubs give the tests the window of a
normal GUI frame and make the expected numbers readable."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'window-body-width)
              (lambda (&optional _window _pixels-p) ,width))
             ((symbol-function 'window-body-height)
              (lambda (&optional _window _pixels-p) ,height)))
     ,@body))

(defun seshat-reader-resize-test--geometry-buffer (&optional pages width height)
  "Create a reader buffer holding one row per page in PAGES.

Each row carries a fake image spec of WIDTH x HEIGHT (600x800 by default) and
the matching native size is recorded the way the first render does it, with
`seshat-reader--multipage-record-native' at scale 1.0.  The buffer-local
state is the one `--render-buffer' plus `--first-fit' leave behind: a
`contain' fit mode and a base scale of 1.0.  PAGES defaults to (1 2 3).

The buffer is returned as (BUFFER . SPECS), SPECS being an alist PAGE -> SPEC
so a test can read a spec back without going through the layout."
  (let ((buffer (seshat-reader-resize-test--reader-buffer))
        (specs nil))
    (with-current-buffer buffer
      (setq-local seshat-reader--multipage-base-scale 1.0
                  seshat-reader--multipage-fit-mode 'contain)
      (dolist (page (or pages '(1 2 3)))
        (let ((spec (seshat-reader-resize-test--page-spec-copy
                     (or width 600) (or height 800))))
          (push (cons page spec) specs)
          (seshat-reader--multipage-insert-page page spec)
          (seshat-reader--multipage-record-native page spec 1.0))))
    (cons buffer (nreverse specs))))

(defun seshat-reader-resize-test--page-spec-copy (width height)
  "Return a fake image spec of WIDTH x HEIGHT pixels."
  (seshat-reader-resize-test--image-spec width height))

(defun seshat-reader-resize-test--guide-display (page)
  "Return the `display' property of the leading space of PAGE's row."
  (when-let* ((entry (assq page seshat-reader--pages))
              (start (marker-position (cadr entry))))
    (get-text-property start 'display)))

(defun seshat-reader-resize-test--image-display (page)
  "Return the `display' property of PAGE's image placeholder character."
  (when-let* ((entry (assq page seshat-reader--pages))
              (start (marker-position (cadr entry))))
    (get-text-property (1+ start) 'display)))

(defun seshat-reader-resize-test--align-form (page)
  "Return the `(+ center (-0.5 . SPEC))' form that centres PAGE, or nil."
  (let* ((guide (seshat-reader-resize-test--guide-display page))
         (align (and (consp guide) (eq (car guide) 'space)
                     (plist-get (cdr guide) :align-to))))
    (and (consp align) (eq (car align) '+) align)))

(defun seshat-reader-resize-test--align-spec (page)
  "Return the spec object the centring form of PAGE refers to.

The `:align-to' form is `(+ center (-0.5 . SPEC))', so the spec sits in the
cdr of its third element; that is the object whose identity decides whether
the row is still centred on the page it displays."
  (let ((form (seshat-reader-resize-test--align-form page)))
    (cdr (nth 2 form))))

(defun seshat-reader-resize-test--render-counter ()
  "Return a fresh counter for `seshat-reader-resize-test--stub-renderer'."
  (list 0 nil))

(defun seshat-reader-resize-test--render-count (counter)
  "Return how many render requests COUNTER recorded."
  (car counter))

(defun seshat-reader-resize-test--render-scales (counter)
  "Return the scales COUNTER recorded, newest first."
  (cadr counter))

(defun seshat-reader-resize-test--stub-renderer (counter &optional width height)
  "Return a counting stub for `seshat-reader-dyn--page-image-spec'.

Every call bumps COUNTER's count and records the requested scale; the
returned spec is WIDTH x HEIGHT (600x800 by default) scaled like the real
renderer does, so a test can check the resolution a page was rendered at
without decoding anything."
  (let ((w (or width 600))
        (h (or height 800)))
    (lambda (_page scale _rotate)
      (setcar counter (1+ (car counter)))
      (setcar (cdr counter) (cons scale (cadr counter)))
      (list 'image :type 'pbm :data "x"
            :width (max 1 (round (* w scale)))
            :height (max 1 (round (* h scale)))))))

(defmacro seshat-reader-resize-test--with-window-buffer (buffer &rest body)
  "Display BUFFER in the selected window while BODY runs.
The buffer is restored afterwards, so a failing assertion cannot leak the
display into the next test."
  (declare (indent 1) (debug t))
  `(let ((window (selected-window))
         (original (window-buffer (selected-window))))
     (unwind-protect
         (progn (set-window-buffer window ,buffer) ,@body)
       (set-window-buffer window original))))

;;; 1. 去抖：连续调度只留一个 timer

(ert-deftest seshat-reader-resize-test--schedule-refit-debounce ()
  "Three schedules cancel the two previous timers and keep the last one.

A missing cancel would leave three armed timers, so both the cancel count
and the argument identity are checked: the cancelled timers must be exactly
the ones returned by the previous schedules."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (cancelled nil)
         (armed nil)
         (counter 0))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf* (((symbol-function 'timerp)
                      (lambda (object)
                        (and (consp object) (eq (car object) 'fake-timer))))
                     ((symbol-function 'cancel-timer)
                      (lambda (timer) (push timer cancelled)))
                     ((symbol-function 'run-with-idle-timer)
                      (lambda (delay repeat function &rest args)
                        (cl-incf counter)
                        (let ((timer (list 'fake-timer counter delay repeat
                                           function args)))
                          (setq armed (append armed (list timer)))
                          timer))))
            (setq seshat-reader--resize-refit-timer nil)
            (dotimes (_ 3) (seshat-reader--schedule-refit))
            (should (= 3 counter))
            (should (= 3 (length armed)))
            ;; 第 1、2 次调度取消的是上一次排下的 timer
            (should (equal (reverse cancelled)
                           (list (nth 0 armed) (nth 1 armed))))
            ;; 变量里留的是最后一次调度排下的 timer
            (should (eq (nth 2 armed) seshat-reader--resize-refit-timer))
            ;; 参数语义：idle 延迟、不重复、回调函数、回调实参是当前 buffer
            (dolist (timer armed)
              (should (eql seshat-reader--resize-refit-delay (nth 2 timer)))
              (should-not (nth 3 timer))
              (should (eq (nth 4 timer) #'seshat-reader--run-pending-refit))
              (should (equal (nth 5 timer) (list buffer))))
            ;; 内部开关关闭时既不取消也不排新 timer
            (let ((seshat-reader--resize-refit-enabled nil))
              (seshat-reader--schedule-refit))
            (should (= 3 counter))
            (should (= 2 (length cancelled)))
            (should (eq (nth 2 armed) seshat-reader--resize-refit-timer))))
      (kill-buffer buffer))))

;;; 2. 回调：每个窗口只 refit 一次，结束后清空 timer

(ert-deftest seshat-reader-resize-test--run-pending-refit-once ()
  "The callback refits each window of the buffer exactly once and clears the timer.

A callback that refits the selected window only would count 1, one that
runs the loop twice would count 4; both are caught by the exact count and
the window identity set.  The `seshat-reader--refitting' flag must be
non-nil inside every refit call, so that the size changes caused by the
refit itself are dropped by `seshat-reader--schedule-refit' instead of
queueing the next refit."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (w1 (selected-window))
         (w2 (split-window w1))
         (timer (run-at-time 3600 nil #'ignore))
         (calls nil)
         (flags nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq seshat-reader--resize-refit-timer timer))
          (cl-letf (((symbol-function 'get-buffer-window-list)
                     (lambda (&rest _) (list w1 w2)))
                    ((symbol-function 'seshat-reader--refit-window)
                     (lambda (window)
                       (push seshat-reader--refitting flags)
                       (push window calls))))
            (seshat-reader--run-pending-refit buffer))
          (should (= 2 (length calls)))
          (should (memq w1 calls))
          (should (memq w2 calls))
          (should (= 2 (length (delete-dups (copy-sequence calls)))))
          ;; 执行期间防重入标志必须是 t（在 let 作用域内）
          (should (equal '(t t) flags))
          ;; 回调跑完后变量被清空，下一次调度不会取消已触发的 timer
          (should-not (with-current-buffer buffer seshat-reader--resize-refit-timer))
          (should-not (with-current-buffer buffer seshat-reader--refitting)))
      (when (timerp timer) (cancel-timer timer))
      (delete-window w2)
      (kill-buffer buffer))))

;;; 3. refit：fit 分支重算 scale 并夹紧+居中

;;; 4. refit：manual 分支保留 scale

;;; 5. refit：未记录来源时按 fit 处理

;;; 6. 守卫：窗口已死

(ert-deftest seshat-reader-resize-test--refit-dead-window ()
  "A dead window is skipped silently, while a live one is refitted.

P1 重写：per-window overlay 的失效判据（窗口参数 `overlay'）随单页布局一起移除，
`--refit-window' 现在只按「窗口存活 / 显示本 buffer / 仍在该 mode」守卫。计数点
改成新实现真正做的两段：批量 `--apply-display-scale' 与 `--center-page'；先跑
一次正向对照，零计数才不是桩坏了的假绿。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (applied 0)
         (centered 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'seshat-reader--multipage-refit-page)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (&optional _window _scale) (cl-incf applied) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (cl-incf centered) nil)))
            ;; 正向对照：窗口活着且显示本 buffer → 两段各一次
            (with-current-buffer buffer
              (seshat-reader--refit-window window))
            (should (equal '(1 1) (list applied centered)))
            (setq applied 0 centered 0)
            ;; 死窗口：零调用、不报错
            (cl-letf (((symbol-function 'window-live-p) (lambda (_window) nil)))
              (with-current-buffer buffer
                (seshat-reader--refit-window window)))
            (should (equal '(0 0) (list applied centered)))))
      (set-window-buffer window original)
      (kill-buffer buffer))))

;;; 7. 守卫：窗口已换 buffer

(ert-deftest seshat-reader-resize-test--refit-wrong-buffer ()
  "A window that shows another buffer is skipped.

The other buffer is itself a `seshat-reader-mode' buffer with page rows, so
removing the `window-buffer' guard would let the refit run in it and the
counts would become one.  The positive control runs first for the same
reason as in `--refit-dead-window'."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (other (car (seshat-reader-resize-test--geometry-buffer '(1 2))))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (applied 0)
         (centered 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'seshat-reader--multipage-refit-page)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (&optional _window _scale) (cl-incf applied) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (cl-incf centered) nil)))
            (with-current-buffer other
              (seshat-reader--refit-window window))
            (should (equal '(0 0) (list applied centered)))
            (set-window-buffer window other)
            (with-current-buffer other
              (seshat-reader--refit-window window))
            (should (equal '(1 1) (list applied centered)))))
      (set-window-buffer window original)
      (kill-buffer other)
      (kill-buffer buffer))))

;;; 8. 守卫：overlay 参数失效

(ert-deftest seshat-reader-resize-test--refit-skips-buffer-outside-reader-mode ()
  "A buffer that left `seshat-reader-mode' is not refitted at all.

P1 重写：旧用例守的是「窗口参数 `overlay' 失效」。窗口参数已不承载页面，
refit 剩下的守卫是模式判定（`derived-mode-p'）：一个还显示着这份文本、但已经
不是 reader buffer 的窗口，不许被改写几何。正向对照换成同内容但仍在 mode 里的
buffer，零计数才说明守卫生效。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1)))
         (buffer (car fixture))
         (plain (generate-new-buffer " *seshat-reader-resize-plain*"))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (rendered 0))
    (unwind-protect
        (progn
          ;; 同样的页行放进一个不是 seshat-reader-mode 的 buffer
          (with-current-buffer plain
            (setq-local seshat-reader--multipage-fit-mode 'contain)
            (dolist (entry (cddr fixture))
              (seshat-reader--multipage-insert-page (car entry) (cdr entry))
              (seshat-reader--multipage-record-native (car entry) (cdr entry) 1.0)))
          (set-window-buffer window plain)
          (cl-letf (((symbol-function 'seshat-reader--multipage-refit-page)
                     (lambda (&rest _) (cl-incf rendered)))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) nil)))
            (with-current-buffer plain
              (should-not (seshat-reader--refit-window window)))
            (should (= 0 rendered))
            ;; 正向对照：同一个窗口换回 reader buffer 后必须真的 refit
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (seshat-reader--refit-window window))
            (should (= 1 rendered))))
      (set-window-buffer window original)
      (kill-buffer plain)
      (kill-buffer buffer))))

;;; 9. vscroll 夹紧 —— P1 T7 删除
;;
;; vscroll 夹紧（`--clamp-window-vscroll` / `--page-max-vscroll-pixels` /
;; `--set-window-vscroll`）属单页机制：多页布局里一页是一行，滚动由
;; `seshat-reader--multipage-scroll` 直接搬 `window-start`，不再夹 vscroll。
;; 相关函数与用例一并退役。

;;; 10. 单页 `doc-scale-page` 的 source 语义 —— P1 T7 删除（vscroll/单页缩放族）
;;
;; 单页时代的 `seshat-reader-doc-scale-page`（走 C 侧 `--scale-page`）已删除，
;; 缩放口径改为 `seshat-reader--multipage-set-scale`；其 `scale-source` 语义
;; 由 `--multipage-set-scale` 自身的用例（第 33/34 节等）覆盖。

;;; 11. presentation-mode 不回归

(ert-deftest seshat-reader-resize-test--presentation-mode-keeps-fit ()
  "Presentation view fits the height and restores fit mode, zoom and mode line.

P1 重写：presentation 不再经窗口参数 `scale'/`render-scale' 与 overlay 分支，
它把 buffer-local 的 fit 模式切到 `height'、按首页高度重算 base-scale，退出时
连同 base-scale 一起复原 —— 只复原模式是不够的：此时重新推导出的 scale 仍是
presentation 的 scale，用户的缩放会被静默改掉。

页 native 600x1600、窗口 1000x800：`height' 模式给 800/1600 = 0.5（spec 变成
300x800），退出时回到进入前的 `manual' 模式与 2.0 倍缩放（spec 回到 1200x3200）。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2) 600 1600))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (seshat-reader-resize-test--with-window-pixels 1000 800
            (with-current-buffer buffer
              ;; 缩放命令现在同步 refit；本用例只关心 presentation 的状态机，
              ;; 故把重渲染桩成空操作（否则真实渲染器没有文档，会把页行 spec 清空）。
              (cl-letf (((symbol-function 'seshat-reader--multipage-rerender-page)
                         (lambda (&rest _args) nil)))
                ;; 进入前的状态：手动 2 倍缩放
                (setq-local seshat-reader--multipage-base-scale 2.0
                            seshat-reader--multipage-fit-mode 'manual)
                (set-window-parameter window 'fit-mode 'manual)
                (seshat-reader--apply-display-scale window)
                (should (eql 1200 (image-property
                                   (seshat-reader--multipage-page-spec 1) :width)))
                (seshat-reader-presentation-mode 1)
                (should seshat-reader-presentation-mode)
                (should-not mode-line-format)
                (should (eq 'height seshat-reader--multipage-fit-mode))
                (should (eq 'height (seshat-reader--window-fit-mode window)))
                (should (< (abs (- seshat-reader--multipage-base-scale 0.5)) 1e-9))
                (let ((spec (seshat-reader--multipage-page-spec 1)))
                  (should (eql 300 (image-property spec :width)))
                  (should (eql 800 (image-property spec :height))))
                ;; 300 ≤ 1000 → 仍然居中
                (should (seshat-reader--multipage-page-centered-p 1))
                ;; 退出：fit 模式、base scale、mode-line 全部复原
                (seshat-reader-presentation-mode -1)
                (should-not seshat-reader-presentation-mode)
                (should mode-line-format)
                (should (eq 'manual seshat-reader--multipage-fit-mode))
                (should (eq 'manual (seshat-reader--window-fit-mode window)))
                (should (< (abs (- seshat-reader--multipage-base-scale 2.0)) 1e-9))
              (should (eql 1200 (image-property (seshat-reader--multipage-page-spec 1)
                                                :width)))
              (should-not seshat-reader--presentation-state)))))
      (set-window-parameter window 'fit-mode nil)
      (set-window-buffer window original)
      (kill-buffer buffer))))

;;; 12. 多窗口各处理一次

;;; 13. buffer 已死

(ert-deftest seshat-reader-resize-test--run-pending-refit-dead-buffer ()
  "A dead buffer neither refits nor arms a new timer, and leftover timers are cancellable.

The first part uses a really killed buffer, so switching to it would
signal.  The second part checks that leaving the mode path
\(`seshat-reader--clear-doc-memory') cancels a pending refit."
  (let ((dead (generate-new-buffer " *seshat-reader-resize-test-dead*"))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (timer (run-at-time 3600 nil #'ignore))
        (timer2 (run-at-time 3600 nil #'ignore))
        (refit 0)
        (armed 0)
        (cancelled nil))
    (unwind-protect
        (progn
          (kill-buffer dead)
          (cl-letf* (((symbol-function 'seshat-reader--refit-window)
                      (lambda (_window) (cl-incf refit)))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) (cl-incf refit)))
                     ((symbol-function 'run-with-idle-timer)
                      (lambda (&rest _) (cl-incf armed) nil))
                     ((symbol-function 'cancel-timer)
                      (lambda (object) (push object cancelled))))
            ;; ① 死 buffer：不 refit、不排新 timer、不报错
            (should-not (seshat-reader--run-pending-refit dead))
            (should (= 0 refit))
            (should (= 0 armed))
            ;; ② 残留 timer 可被安全取消（nil 时 cancel-timer 不被调用）
            (with-current-buffer buffer
              (setq seshat-reader--resize-refit-timer nil)
              (seshat-reader--cancel-pending-refit)
              (should-not cancelled)
              (should-not seshat-reader--resize-refit-timer)
              (setq seshat-reader--resize-refit-timer timer)
              (seshat-reader--cancel-pending-refit)
              (should (equal (list timer) cancelled))
              (should-not seshat-reader--resize-refit-timer)
              ;; ③ 模式退出路径（`--clear-doc-memory'）清掉待触发的 timer
              (setq seshat-reader--resize-refit-timer timer2)
              (cl-letf (((symbol-function 'seshat-reader-dyn--close-doc)
                         (lambda () nil)))
                (seshat-reader--clear-doc-memory))
              (should-not seshat-reader--resize-refit-timer)
              (should (equal (list timer2 timer) cancelled)))))
      (when (timerp timer) (cancel-timer timer))
      (when (timerp timer2) (cancel-timer timer2))
      (kill-buffer buffer))))

;;; 14. contain：高度维胜出

(ert-deftest seshat-reader-resize-test--base-fit-scale-height-limited ()
  "The height-fitting scale wins when the page is proportionally taller.

P1 重写：`--contain-scale' 已退役，等价物是 `--multipage-base-fit-scale'，
按基准页的 native 尺寸算 document 级 base scale。页 native 1000x1400 在 900x1000 的窗口里：按宽 0.9、按高
1000/1400 = 0.714…，结果必须是更小的那个，否则高度溢出窗口。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 1000 1400))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 900 1000
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let ((got (seshat-reader--multipage-base-fit-scale 'contain window)))
                (should (< (abs (- got (/ 1000.0 1400))) 1e-9))
                ;; 必须严格小于按宽算出的 0.9，否则高度溢出
                (should (< got 0.9))))))
      (kill-buffer buffer))))

;;; 15. contain：宽度维胜出

(ert-deftest seshat-reader-resize-test--base-fit-scale-width-limited ()
  "The width-fitting scale wins when the window is narrow.

`--multipage-base-fit-scale' still returns the smaller of the two dimension fits, so a
narrow window crops the page by width instead of letting it overflow: same
1000x1400 page in a 400x1000 window gives 0.4 while a height-only answer
would give 0.714 and draw the page 1.8 times too wide."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 1000 1400))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 400 1000
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let ((got (seshat-reader--multipage-base-fit-scale 'contain window)))
                (should (< (abs (- got 0.4)) 1e-9))
                (should (< got (/ 1000.0 1400)))))))
      (kill-buffer buffer))))

;;; 16. contain：退化输入 —— P1 T7 删除
;;
;; 旧 `--contain-scale` 在 native 尺寸未知时返回 1.0；新的
;; `--multipage-base-fit-scale` 在该情况下返回 nil（调用方保留当前 scale，
;; 不跳到任意值），该语义由 `--fit-scale-without-native-size`（第 35 节）覆盖。

;;; 17. --center-page：超宽时负偏移夹到 0

(ert-deftest seshat-reader-resize-test--center-page-leaves-an-overwide-page-left-aligned ()
  "An overwide page is left aligned, not scrolled by a negative offset.

P1 重写：旧用例钉的是「line-prefix 的负偏移夹到 0」。line-prefix 居中整族随
`--center-overlay' 一起退役，超宽页现在是「没有引导空格 → 贴左 + 横向滚动」
（决策 D5b）。因此这里断言三件事：超宽页的引导空格被摘掉、图像属性还在、并且
居中过程**不**去动横向滚动（没有可居中的页时才复位 hscroll）。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 2000 1000))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (hscrolls nil))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'manual)
              (seshat-reader--apply-display-scale window)
              ;; 前提：页确实宽于窗口
              (should (> (image-property (seshat-reader--multipage-page-spec 1)
                                         :width)
                         (window-body-width window t)))
              (should-not (seshat-reader--multipage-page-should-center-p 1))
              ;; 引导空格此刻还引用着 spec（渲染时写下），几何上已过期
              (should (seshat-reader--multipage-page-centered-p 1))
              (should-not (seshat-reader--centered-p window))
              (cl-letf (((symbol-function 'set-window-hscroll)
                         (lambda (&rest args) (push args hscrolls) 0)))
                (seshat-reader--center-page window))
              ;; 贴左：没有引导空格，图像属性仍是同一个 spec
              (should-not (seshat-reader-resize-test--guide-display 1))
              (should (eq (seshat-reader-resize-test--image-display 1)
                          (seshat-reader--multipage-page-spec 1)))
              (should-not (seshat-reader--multipage-page-centered-p 1))
              (should (seshat-reader--centered-p window))
              ;; 超宽时不去动横向滚动（不能把用户滚到的位置复位）
              (should-not hscrolls))))
      (kill-buffer buffer))))

;;; 18. --window-size-change：buffer-local 条目实际收到的是 window

(ert-deftest seshat-reader-resize-test--window-size-change-accepts-window ()
  "A real window argument is accepted and never signals.

`add-hook ... local = t` 注册的 `window-size-change-functions' 条目收到的是
window 而不是 frame。把 window 当 frame 传给 `window-list' 会抛
`(error \"Window is on a different frame\")'，异常被 `safe_call' 吞掉后 refit
链路一次都跑不到（2026-10-23 真机复现）。本用例同时锁两件事：window 形态
不抛错，且确实排入一次 refit。"
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (refits 0)
        (signaled nil))
    (unwind-protect
        (progn
          ;; 真实 window，且它显示的正是当前 buffer
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'seshat-reader--schedule-refit)
                     (lambda () (setq refits (1+ refits)) nil)))
            (with-current-buffer buffer
              (condition-case err
                  (seshat-reader--window-size-change window)
                (error (setq signaled err)))
              ;; 回归锁：window 形态不得抛任何错
              (should-not signaled)
              (should (= 1 refits)))))
      (set-window-buffer window orig-buffer)
      (kill-buffer buffer))))

;;; 19. --window-size-change：frame 形态仍走遍历，且两形态判定一致

(ert-deftest seshat-reader-resize-test--window-size-change-accepts-frame ()
  "The frame shape still works and agrees with the window shape.

`window-size-change-functions' 的 global / default 值收到 frame，这条路径必须
继续用 `(window-list FRAME)' 遍历。行为一致性由一个反向断言钉住：当没有任何
窗口显示当前 buffer 时，两种形态都不排 refit。"
  (let ((window (selected-window))
        (frame (selected-frame))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (other (generate-new-buffer " *seshat-reader-resize-test-other*"))
        (refits 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'seshat-reader--schedule-refit)
                     (lambda () (setq refits (1+ refits)) nil)))
            ;; frame 形态：窗口显示当前 buffer → 排一次（与 window 形态一致）
            (with-current-buffer buffer
              (seshat-reader--window-size-change frame)
              (should (= 1 refits)))
            ;; 当前 buffer 没有任何窗口显示 → 两种形态都不排
            (with-current-buffer other
              (seshat-reader--window-size-change frame)
              (seshat-reader--window-size-change window)
              (should (= 1 refits)))))
      (set-window-buffer window orig-buffer)
      (kill-buffer buffer)
      (kill-buffer other))))

;;; 20. 清晰度闸：`render-scale' 与 `scale' 相等 → 不重渲染，但仍夹紧+居中

;;; 21. 清晰度闸：`render-scale' 与 `scale' 不等 → 重渲染，参数为该 scale

(ert-deftest seshat-reader-resize-test--refit-fit-applies-when-scale-differs ()
  "Every resident page whose bitmap resolution differs is rendered once more.

P1 重写：判据从窗口参数 `render-scale' 改成按页的
`seshat-reader--page-render-scales'，重渲染入口从 `seshat-reader-doc-scale-page'
改成 `--multipage-rerender-page'（它会强制重渲染：页行里已经有一个 spec 时
`--multipage-render-page' 会早退）。

页 native 600x800、窗口 1000x400、`height' 模式 → 目标 scale 0.5；两页都以
1.0 渲染过，所以 refit 必须各重渲染一次，并在之后再次 refit 时零重渲染。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (counter (seshat-reader-resize-test--render-counter)))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 400
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'height)
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-resize-test--stub-renderer counter)))
                (seshat-reader--refit-window window))
              (should (= 2 (seshat-reader-resize-test--render-count counter)))
              (should (equal '(0.5 0.5)
                             (seshat-reader-resize-test--render-scales counter)))
              (dolist (page '(1 2))
                (let ((spec (seshat-reader--multipage-page-spec page)))
                  (should (eql 300 (image-property spec :width)))
                  (should (eql 400 (image-property spec :height)))
                  (should (< (abs (- (seshat-reader--multipage-render-scale page)
                                     0.5))
                             1e-9)))
                (should (seshat-reader--multipage-page-centered-p page)))
              ;; 分辨率已经等于目标 → 再 refit 一次零重渲染
              (setcar counter 0)
              (setcar (cdr counter) nil)
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-resize-test--stub-renderer counter)))
                (seshat-reader--refit-window window))
              (should (= 0 (seshat-reader-resize-test--render-count counter)))))
      (kill-buffer buffer)))))

;;; 22. 防重入：refit 执行期间产生的事件不再排队

(ert-deftest seshat-reader-resize-test--schedule-refit-ignored-while-refitting ()
  "A size change arriving during a refit is dropped instead of being queued.

`run-with-idle-timer' must not be called and the pending timer must keep its
identity: cancelling and re-arming it from inside a refit is exactly how the
refit feeds itself.  The trailing counter-check schedules once with the flag
back to nil, so the zero count cannot pass for a broken stub."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (timer (run-at-time 3600 nil #'ignore))
         (armed 0))
    (unwind-protect
        (with-current-buffer buffer
          (setq seshat-reader--resize-refit-timer timer)
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (&rest _) (cl-incf armed) nil))
                    ((symbol-function 'cancel-timer)
                     (lambda (_object) nil)))
            (let ((seshat-reader--refitting t))
              (seshat-reader--schedule-refit))
            (should (= 0 armed))
            (should (eq timer seshat-reader--resize-refit-timer))
            (let ((seshat-reader--refitting nil)
                  (seshat-reader--resize-refit-enabled t))
              (seshat-reader--schedule-refit))
            (should (= 1 armed))))
      (when (timerp timer) (cancel-timer timer))
      (kill-buffer buffer))))

;;; 23. 尺寸变化：同步居中先于排 refit（D7，方案 A）

;;; 24. 尺寸变化：frame 形态居中每个匹配窗口，但只排一次 refit

;;; 25. 守卫：overlay 缺失时只跳过同步段，refit 照排

(ert-deftest seshat-reader-resize-test--window-size-change-skips-window-showing-another-buffer ()
  "A size change of a window that shows another buffer recentres nothing.

P1 重写：旧用例守的是「`overlay' 参数缺失时同步段跳过、refit 照排」。窗口参数
已不再承载页面，尺寸变化链路的守卫变成「窗口显示的是不是本 buffer」：不显示就
既不同步重排，也不排 refit。正向对照（窗口换回本 buffer）保证两个零不是桩坏了。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (other (generate-new-buffer " *seshat-reader-resize-other*"))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (recenters 0)
         (refits 0))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'seshat-reader--recenter-window)
                     (lambda (_window) (cl-incf recenters)))
                    ((symbol-function 'seshat-reader--schedule-refit)
                     (lambda () (cl-incf refits) nil)))
            (set-window-buffer window other)
            (with-current-buffer buffer
              (seshat-reader--window-size-change window))
            (should (equal '(0 0) (list recenters refits)))
            (set-window-buffer window buffer)
            (with-current-buffer buffer
              (seshat-reader--window-size-change window))
            (should (equal '(1 1) (list recenters refits)))))
      (set-window-buffer window original)
      (kill-buffer other)
      (kill-buffer buffer))))

;;; 26. 换 buffer 到同一个 reader buffer：已有 overlay 时补一次 recentre

;;; 27. 换 buffer 到同一个 reader buffer：缺 overlay 时只创建，不 recentre

;;; 28. 换 buffer 到普通 buffer：两条分支都不走

;;; 29. image size 未知时 right-most-window-hscroll 返回 0 且不抛错

(ert-deftest seshat-reader-resize-test--right-most-window-hscroll-nil-image-size ()
  "Without rendered pages the scrollable margin is 0 and nothing signals.

P1 重写：口径从「当前窗口 image 尺寸」改为「可见页最大宽度」，因此「尺寸未知」
就是「buffer 里还没有页行」。`--set-window-hscroll' 在 mode 初始化阶段就会调用
它，此时文档尚未渲染，必须返回 0 而不是抛 `wrong-type-argument'。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should-not (seshat-reader--multipage-max-page-width))
              (should (= 0 (seshat-reader--right-most-window-hscroll window)))
              ;; 只有占位行（无 spec）时同样是 0，不报错
              (seshat-reader--multipage-insert-page 1 nil)
              (should (= 0 (seshat-reader--right-most-window-hscroll window))))))
      (kill-buffer buffer))))

;;; 30. image size 已知时公式不变

(ert-deftest seshat-reader-resize-test--right-most-window-hscroll-formula-regression ()
  "The scrollable margin is the widest page minus the window width.

P1 重写：公式的输入从「当前窗口的 image 尺寸 + line-prefix 宽度」改为「可见页
最大宽度」（`--multipage-max-page-width'）。1200px 的页在 1000px 的窗口里给出
200 列（每列 1px）；一旦缩放让所有页都放得下，余量必须回到 0 —— 否则 contain /
width 模式下还会留下一个不存在的可滚动区间。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2) 1200 800))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (= 1200 (seshat-reader--multipage-max-page-width)))
              (should (= 200 (seshat-reader--right-most-window-hscroll window)))
              ;; 缩到 0.5 倍：所有页都放得下 → 余量 0。缩放命令会同步 refit，
              ;; 本用例只关心 hscroll 口径，故把重渲染桩成空操作（真实渲染器
              ;; 在此没有文档，会把页行 spec 清空）。
              (cl-letf (((symbol-function 'seshat-reader--multipage-rerender-page)
                         (lambda (&rest _args) nil)))
                (seshat-reader--multipage-set-scale 0.5 'manual 'manual))
              (should (= 600 (seshat-reader--multipage-max-page-width)))
              (should (= 0 (seshat-reader--right-most-window-hscroll window))))))
      (kill-buffer buffer))))

(provide 'seshat-reader-resize-test)

;;; 31. fit-mode：未设置视作 contain

(ert-deftest seshat-reader-resize-test--window-fit-mode-defaults-to-contain ()
  "A window without a `fit-mode' parameter reports `contain'.

The parameter is read back per window, so a recorded `width' / `height' is
returned as is; anything unset (opened before the option existed, restored
from a bookmark) means `contain', the pre-existing whole-page fit."
  (let ((window (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter window 'fit-mode nil)
          (should (eq 'contain (seshat-reader--window-fit-mode window)))
          (set-window-parameter window 'fit-mode 'width)
          (should (eq 'width (seshat-reader--window-fit-mode window)))
          (set-window-parameter window 'fit-mode 'height)
          (should (eq 'height (seshat-reader--window-fit-mode window))))
      (set-window-parameter window 'fit-mode nil))))

;;; 32. --fit-scale：contain 模式等价于 `--multipage-base-fit-scale`

(ert-deftest seshat-reader-resize-test--fit-scale-contain-passes-through ()
  "`contain' mode never lets a page exceed the base scale or the width.

P1 重写：target scale 的表由决策 D5 固定，`contain' 行是
`min (base scale, width fit)'。三组数据钉住它：base 1.0 且页比窗口窄时取 base；
base 2.0 时被 width fit 1.667 截住（否则宽度溢出）；页比窗口宽时取 width fit
0.5（宽页按宽裁剪）。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (wide (seshat-reader-resize-test--geometry-buffer '(1) 2000 800)))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (eq 'contain (seshat-reader--multipage-current-fit-mode window)))
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 1.0))
                         1e-9))
              (setq seshat-reader--multipage-base-scale 2.0)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 (/ 1000.0 600)))
                         1e-9))
              ;; `--fit-scale' 是同一张表的窗口化包装
              (should (< (abs (- (seshat-reader--fit-scale window)
                                 (/ 1000.0 600)))
                         1e-9))))
          (seshat-reader-resize-test--with-window-buffer (car wide)
            (with-current-buffer (car wide)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 0.5))
                         1e-9))
              (should (< (seshat-reader--multipage-target-scale 1 window) 1.0)))))
      (kill-buffer (car wide))
      (kill-buffer buffer))))

;;; 33. --fit-scale：width 模式 = 窗口像素宽 / native 宽

(ert-deftest seshat-reader-resize-test--fit-scale-width-mode ()
  "In `width' mode every page is scaled to fill the window width.

P1 重写：`width' 行只按宽度求值（1000/600 = 1.667），因此页面必然比窗口高 ——
这是决策 D5 明确保留的语义（只有 `height' 与手动缩放允许超宽，`width' 允许
超高）。base scale 与 native 高度都不参与。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-base-scale 0.3
                    seshat-reader--multipage-fit-mode 'width)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 (/ 1000.0 600)))
                         1e-9))
              (should (< (abs (- (seshat-reader--fit-scale window)
                                 (/ 1000.0 600)))
                         1e-9)))))
      (kill-buffer buffer))))

;;; 34. --fit-scale：height 模式 = 窗口像素高 / native 高

(ert-deftest seshat-reader-resize-test--fit-scale-height-mode ()
  "In `height' mode every page is scaled to fill the window height.

P1 重写：`height' 行只按高度求值（400/800 = 0.5），宽度不参与、也不裁剪 ——
这正是 D5 保留的旧 `fit-to-height' 语义：页面可以比窗口宽，横向滚动兜底。
base scale 与 native 宽度都不参与。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 400
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-base-scale 0.3
                    seshat-reader--multipage-fit-mode 'height)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 0.5))
                         1e-9))
              (should (< (abs (- (seshat-reader--fit-scale window) 0.5)) 1e-9)))))
      (kill-buffer buffer))))

;;; 35. --fit-scale：没有 native 尺寸时退回 1.0

(ert-deftest seshat-reader-resize-test--fit-scale-without-native-size ()
  "Without a native page size the width and height modes fall back to 1.0.

The page has not been rendered yet (or the spec carries no usable size), so
there is nothing to divide by; 1.0 keeps the page at its default size
instead of signalling an error.

P1 T7 重写：不再桩 `--native-page-size`（该访问器已删）。这里的 buffer 没有
页行，`--multipage-native-size` 自然返回 nil，正是「尚未渲染」的状态。"
  (let ((window (selected-window)))
    (unwind-protect
        (dolist (mode '(width height))
          (set-window-parameter window 'fit-mode mode)
          (should (= 1.0 (seshat-reader--fit-scale window)))
          (should (eql 1.0 (seshat-reader--fit-scale window))))
      (set-window-parameter window 'fit-mode nil))))

;;; 36. --apply-display-scale：改 spec 与 'scale

(ert-deftest seshat-reader-resize-test--apply-display-scale-rewrites-spec ()
  "Every resident page spec is resized in place, and the scale is recorded.

P1 重写：批量语义 —— 三个页行的 spec 全部被改成 300x400（native 600x800 乘
0.5），窗口参数 `scale' 与 buffer-local 的 fallback 跟着走，而**引导空格仍然
引用同一个 spec 对象**（`eq'）：`(space :align-to (+ center (-0.5 . SPEC)))'
靠对象身份跟随新尺寸，换对象就得重写整行。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (seshat-reader--apply-display-scale window 0.5))
              (should (= 0.5 seshat-reader--recent-scale-fallback))
              (dolist (page '(1 2 3))
                (let ((spec (seshat-reader--multipage-page-spec page)))
                  (should (eql 300 (image-property spec :width)))
                  (should (eql 400 (image-property spec :height)))
                  ;; align-to 仍然引用同一个 spec 对象
                  (should (eq (seshat-reader-resize-test--align-spec page) spec))
                  (should (eq (seshat-reader-resize-test--image-display page)
                              spec))))
              (should (eql 0.5 (window-parameter window 'scale)))))
      (kill-buffer buffer)))))

;;; 37. --apply-display-scale：尺寸未变时不重写 spec

(ert-deftest seshat-reader-resize-test--apply-display-scale-same-size ()
  "Applying the size a spec already has returns nil and changes nothing.

Nothing is rendered here either way; what has to hold is that a no-op apply
does not rewrite the plists (a rewrite invalidates redisplay for nothing) and
reports that it did nothing.  The scale is changed back at the end, so the
nil from the middle call cannot be confused with \"apply never works\"."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 尺寸真的变了 → t
              (should (seshat-reader--apply-display-scale window 0.5))
              (should (eql 300 (image-property (seshat-reader--multipage-page-spec 1)
                                               :width)))
              ;; 同一 scale 再来一次 → nil，属性不动
              (should-not (seshat-reader--apply-display-scale window 0.5))
              (should (eql 300 (image-property (seshat-reader--multipage-page-spec 1)
                                               :width)))
              (should (eql 400 (image-property (seshat-reader--multipage-page-spec 2)
                                               :height)))
              ;; 换回 1.0 → 又是 t
              (should (seshat-reader--apply-display-scale window 1.0))
              (should (eql 600 (image-property (seshat-reader--multipage-page-spec 1)
                                               :width)))))
      (kill-buffer buffer)))))

;;; 38. --apply-display-scale：无 spec（还不是图片）→ nil，不写 'scale

(ert-deftest seshat-reader-resize-test--apply-display-scale-without-spec ()
  "A row that carries no spec is skipped, and a buffer without rows is a no-op.

A placeholder row (the state of a page whose render failed) has nothing to
resize; its neighbours must still be resized, and the call has to report
that something changed only because of them.  A buffer without any row
returns nil instead of signalling."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (empty (seshat-reader-resize-test--reader-buffer)))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 第 2 页只有占位行（无 spec）
              (seshat-reader--multipage-insert-page 2 nil)
              (should (seshat-reader--apply-display-scale window 0.5))
              (should (eql 300 (image-property (seshat-reader--multipage-page-spec 1)
                                               :width)))
              (should-not (seshat-reader--multipage-page-spec 2))
              (should-not (seshat-reader-resize-test--guide-display 2))
              (should-not (seshat-reader-resize-test--image-display 2))
              ;; 只有占位行 → 没有可改的 spec → nil
              (seshat-reader--multipage-remove-page 1)
              (should-not (seshat-reader--apply-display-scale window 0.5))))
          (with-current-buffer empty
            (should-not (seshat-reader--apply-display-scale (selected-window) 0.5))))
      (kill-buffer empty)
      (kill-buffer buffer))))

;;; 39. `--multipage-native-size`：由 spec / scale 推算并写入缓存

;;; 40. `--multipage-native-size`：命中缓存后不再读 spec

(ert-deftest seshat-reader-resize-test--multipage-native-size-cache-hit ()
  "The native size is a per-page measurement, not the current spec size.

P1 重写：缓存从窗口参数 `native-size' 改为按页 alist
`seshat-reader--page-native-sizes'。判据是「改过尺寸的 spec 不会改变测量值」：
把第 1 页的 spec 原地缩到 300x400 之后，它的 native 仍然是 600x800（那是渲染
时用 `spec / scale' 记下的），否则 `contain' 会把自己的裁剪结果当成页面原始
尺寸、越滚越小。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (equal (cons 600.0 800.0)
                             (seshat-reader--multipage-native-size
                              (seshat-reader--multipage-window-start-page
                               window))))
              (should (equal (cons 600.0 800.0)
                             (seshat-reader--multipage-native-size 1)))
              ;; 第 2 页换成竖版尺寸，按页记录互不影响
              (let ((tall (seshat-reader-resize-test--page-spec-copy 800 600)))
                (seshat-reader--multipage-insert-page 2 tall)
                (seshat-reader--multipage-record-native 2 tall 1.0))
              (should (equal (cons 800.0 600.0)
                             (seshat-reader--multipage-native-size 2)))
              ;; 视口移到第 2 页 → 访问器跟着页号走
              (set-window-start window
                                (marker-position
                                 (cadr (assq 2 seshat-reader--pages))))
              (should (= 2 (seshat-reader-current-doc-pagenumber window)))
              (should (equal (cons 800.0 600.0)
                             (seshat-reader--multipage-native-size
                              (seshat-reader--multipage-window-start-page
                               window))))
              ;; 缩小第 1 页的 spec 不改变它的 native
              (let ((spec (seshat-reader--multipage-page-spec 1)))
                (setf (image-property spec :width) 300)
                (setf (image-property spec :height) 400))
              (should (equal (cons 600.0 800.0)
                             (seshat-reader--multipage-native-size 1)))
              ;; 回收第 2 页 → 测量值一起丢掉，回来时重新测量
              (seshat-reader--multipage-recycle-page 2)
              (should-not (seshat-reader--multipage-native-size 2))))
      (kill-buffer buffer)))))

;;; 41. --recenter-window：fit 窗口先 apply，再 clamp，再 center

;;; 42. --recenter-window：manual 窗口跳过 apply

;;; 43. --refit-window：已渲染分辨率与显示比例一致 → 零重渲染

;;; 44. --refit-window：从未渲染过（render-scale 为 nil）→ 恰好一次

(ert-deftest seshat-reader-resize-test--refit-renders-once-when-never-rendered ()
  "A page without a recorded render scale is rendered exactly once.

`seshat-reader--page-render-scales' is nil here — the state of a page that was
inserted without going through the renderer.  Every resident page must be
rendered once (two pages, two renders) and the resolution recorded, so the
next refit renders nothing.  Rendering twice per page (once per branch) would
show up as a count of 4."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (counter (seshat-reader-resize-test--render-counter)))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--page-render-scales nil)
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-resize-test--stub-renderer counter)))
                (seshat-reader--refit-window window))
              (should (= 2 (seshat-reader-resize-test--render-count counter)))
              (dolist (page '(1 2))
                (should (< (abs (- (seshat-reader--multipage-render-scale page)
                                   1.0))
                           1e-9)))
              (setcar counter 0)
              (setcar (cdr counter) nil)
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-resize-test--stub-renderer counter)))
                (seshat-reader--refit-window window))
              (should (= 0 (seshat-reader-resize-test--render-count counter)))))
      (kill-buffer buffer)))))

;;; 45. fit-to-width：记录 fit-mode = width

;;; 46. fit-to-height：记录 fit-mode = height

;;; 47. 单页 `--native-page-size`：页号 nil 且无 spec → nil —— P1 T7 删除
;;
;; 该用例断言的是窗口参数 native-size 缓存（以窗口参数 page 为键）；P1 的
;; 缓存已改为 buffer-local 的按页 alist `seshat-reader--page-native-sizes'，
;; 「未知尺寸 → nil」由第 35 节与 `--multipage-native-size` 自身的语义覆盖。

;;; 48. `--multipage-native-size`：按页缓存，多窗口互不覆盖

;;; 49. 旋转：两个 rotate 命令都清掉 native-size 缓存

;;; 50. --handle-window-buffer-change：复用点对 fit 窗口 apply 一次

;;; 51. --apply-display-scale：边界输入静默返回 nil

(ert-deftest seshat-reader-resize-test--apply-display-scale-rejects-bad-scale ()
  "A scale that is not a positive number is ignored without signalling.

nil arises when the fit mode found no native size and 0 or a negative value
from a degenerate window; the specs, the `scale' parameter and the buffer
local base scale must all stay untouched instead of raising or writing a
nonsensical size.  Page rows are present, so the zero effect is not just
\"there was nothing to resize\"."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (set-window-parameter window 'scale 1.0)
              (dolist (scale (list nil 0 -0.5 'x "1.0"))
                (should-not (seshat-reader--apply-display-scale window scale)))
              (dolist (page '(1 2))
                (let ((spec (seshat-reader--multipage-page-spec page)))
                  (should (eql 600 (image-property spec :width)))
                  (should (eql 800 (image-property spec :height)))))
              (should (eql 1.0 (window-parameter window 'scale)))
              (should (eql 1.0 seshat-reader--multipage-base-scale))))
      (kill-buffer buffer)))))

;;; 52. --recenter-window：非拖拽（间隔大于阈值）→ 同步 apply 一次

(ert-deftest seshat-reader-resize-test--recenter-window-applies-when-not-dragging ()
  "A one-off size change re-runs the geometry synchronously, then centres, then syncs.

`seshat-reader--last-size-change-delta' is 0.5 s here, above
`seshat-reader--drag-threshold', so the event is a one-off change (opening the
outline panel) and the very frame that noticed it must already show the final
geometry.  The recorded order pins the three steps of the new implementation
\(batch apply → centre → sync); a burst of changes (delta below the
threshold) keeps only the last two, because rewriting the specs per frame is
what makes dragging a divider stall."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (steps nil))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--last-size-change-delta 0.5)
              (cl-letf (((symbol-function 'seshat-reader--apply-display-scale)
                         (lambda (&optional _window _scale)
                           (push 'apply steps) nil))
                        ((symbol-function 'seshat-reader--center-page)
                         (lambda (&optional _window) (push 'center steps)))
                        ((symbol-function 'seshat-reader--multipage-sync)
                         (lambda (&optional _window) (push 'sync steps))))
                (seshat-reader--recenter-window window))
              (should (equal '(apply center sync) (reverse steps)))
              ;; 拖拽中：不重写 spec，只居中 + 同步
              (setq steps nil
                    seshat-reader--last-size-change-delta
                    (/ seshat-reader--drag-threshold 2.0))
              (cl-letf (((symbol-function 'seshat-reader--apply-display-scale)
                         (lambda (&optional _window _scale)
                           (push 'apply steps) nil))
                        ((symbol-function 'seshat-reader--center-page)
                         (lambda (&optional _window) (push 'center steps)))
                        ((symbol-function 'seshat-reader--multipage-sync)
                         (lambda (&optional _window) (push 'sync steps))))
                (seshat-reader--recenter-window window))
              (should (equal '(center sync) (reverse steps)))
              ;; 前提：0.5 确实大于阈值
              (should (< seshat-reader--drag-threshold 0.5))))
      (kill-buffer buffer)))))

;;; 53. --recenter-window：拖拽中（间隔小于阈值）→ 零 apply，仍 clamp + center

;;; 54. --center-page：只写 prefix/hscroll，不再强制标记窗口重算

(ert-deftest seshat-reader-resize-test--center-page-does-not-force-window-update ()
  "Centring rewrites text properties only: no text edit, no forced redisplay.

P1 重写：旧用例断言「不调 `force-window-update'、写 prefix/hscroll」。多页布局下
居中只改引导空格的 `display' 属性，因此更强的不变量成立，也更有意义：buffer 文本
一字不改、`window-start' 与 `point' 不动（否则滚动位置会被居中命令带跑）、
`force-window-update' 不被调用，而引导空格确实被写成 `:align-to' 形式。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (forced 0))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let ((text (buffer-string))
                    (start (window-start window))
                    (point (point)))
                (cl-letf (((symbol-function 'force-window-update)
                           (lambda (&rest _args) (cl-incf forced) nil))
                          ((symbol-function 'set-window-hscroll)
                           (lambda (&rest _args) 0)))
                  ;; 先把居中标称弄脏，保证 --center-page 真的干活
                  (seshat-reader--multipage-set-page-centered 1 nil)
                  (seshat-reader--center-page window))
                (should (= 0 forced))
                (should (equal text (buffer-string)))
                (should (= start (window-start window)))
                (should (= point (point)))
                (should (consp (seshat-reader-resize-test--align-form 1)))
                (should (seshat-reader--centered-p window)))))
      (kill-buffer buffer)))))

;;; 55. --ensure-centered：before-string 缺失（stale）时重排一次居中

(ert-deftest seshat-reader-resize-test--ensure-centered-recalls-center-on-mismatch ()
  "A row that lost its centring space is rebuilt by one `--center-page' call.

P1 重写：旧用例桩掉 `--page-image-spec' 来模拟「before-string 缺失」。多页布局里
等价的状态是「引导空格的属性不见了」（刚被清空，或窗口刚变宽）——`--centered-p'
报 nil，`--ensure-centered' 必须调一次 `--center-page' 并返回非 nil，让
`pre-redisplay-functions' 的调用方知道这一帧做了修复。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 500 700))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (centers 0))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1200 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader--multipage-set-page-centered 1 nil)
              (should-not (seshat-reader--centered-p window))
              (cl-letf (((symbol-function 'seshat-reader--center-page)
                         (lambda (&optional _window) (cl-incf centers) nil)))
                (should (seshat-reader--ensure-centered window)))
              (should (= 1 centers)))))
      (kill-buffer buffer))))

;;; 56. --ensure-centered：before-string 引用当前 spec 时零调用

(ert-deftest seshat-reader-resize-test--ensure-centered-noop-when-matching ()
  "A row whose guide references its own spec is left alone.

`--centered-p' compares the `:align-to' form with the displayed spec by
identity, which is the steady state every frame sees after a render; the
`pre-redisplay-functions' entry point must then not call `--center-page' at
all, or every frame would rewrite text properties."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (centers 0))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (seshat-reader--centered-p window))
              (cl-letf (((symbol-function 'seshat-reader--center-page)
                         (lambda (&optional _window) (cl-incf centers) nil)))
                (should-not (seshat-reader--ensure-centered window)))
              (should (= 0 centers)))))
      (kill-buffer buffer))))

;;; 57. --pre-redisplay-center：非 reader-mode buffer 不做任何事

(ert-deftest seshat-reader-resize-test--pre-redisplay-center-only-in-reader-mode ()
  "The `pre-redisplay-functions' entry point stays inert outside the reader.

The hook may be registered buffer-locally, but the same function can still
be called from a buffer that left `seshat-reader-mode' (or from a global
hook).  It must not touch any window then.

The hook is called with one argument, the window about to be redisplayed;
passing it here pins the arity, because a zero-argument definition makes
redisplay signal `wrong-number-of-arguments' on every frame instead of
centring (found by sampling an isolated instance)."
  (let ((buffer (generate-new-buffer " *seshat-reader-prerender-test*"))
        (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window-list)
                   (lambda (&rest _) (list (selected-window))))
                  ((symbol-function 'seshat-reader--ensure-centered)
                   (lambda (&optional _window) (cl-incf calls) t)))
          ;; 前提：该 buffer 确实不是 seshat-reader-mode
          (with-current-buffer buffer
            (should-not (derived-mode-p 'seshat-reader-mode))
            (should-not (seshat-reader--pre-redisplay-center (selected-window))))
          (should (= 0 calls)))
      (kill-buffer buffer))))

;;; 58. --first-fit：spec 可用时走显示层缩放，不重渲染

;;; 59. --first-fit：spec 不可用时回退到同步重渲染

;;; 60. --center-page：能放下时写 before-string（redisplay 自居中）

(ert-deftest seshat-reader-resize-test--center-page-centres-a-fitting-page ()
  "A page that fits is centred by an `:align-to' space on its own row.

P1 重写：居中载体从 overlay 的 `before-string' 换成页行引导空格的 `display'
属性。断言保持同样的内核：形式必须是 `(space :align-to (+ center (-0.5 . SPEC)))'
且 SPEC 是**当前这个** spec 对象（`eq'，不是 `equal'）——`-0.5 . IMAGE' 需要
image 对象来取半宽，换成裸数字会被当成字符数、把页面甩出窗口；同时没有超宽页时
横向滚动被复位到 0。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 500 700))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (hscrolls nil))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 先弄脏，再让 --center-page 修复
              (seshat-reader--multipage-set-page-centered 1 nil)
              (cl-letf (((symbol-function 'set-window-hscroll)
                         (lambda (&rest args) (push args hscrolls) 0)))
                (seshat-reader--center-page window))
              (let* ((spec (seshat-reader--multipage-page-spec 1))
                     (form (seshat-reader-resize-test--align-form 1))
                     (half (nth 2 form)))
                (should (consp form))
                (should (consp half))
                ;; 浮点不能用 `eq' 比较（不同 boxed 对象），用 `eql'
                (should (eql -0.5 (car half)))
                (should (eq (cdr half) spec))
                (should (eq (seshat-reader-resize-test--image-display 1) spec)))
              ;; 没有超宽页 → 横向滚动复位到 0（一次）
              (should (= 1 (length hscrolls)))
              (should (eql 0 (nth 1 (car hscrolls)))))))
      (kill-buffer buffer))))

;;; 61. --center-page：超宽时清 before-string、回到 line-prefix 左对齐

(ert-deftest seshat-reader-resize-test--center-page-drops-the-guide-for-an-overwide-page ()
  "An overwide page loses its centring space and stays left aligned.

P1 重写：超宽页不再走 line-prefix，而是「没有引导空格」——图片从最左边开始，
横向滚动（决策 D5b 保留）是看到其余部分的唯一办法。居中的超宽页会把两侧都裁掉，
所以渲染时留下的引导空格必须被摘掉；图像属性本身必须完好，否则页就没了。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 2000 3000))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'manual)
              (seshat-reader--apply-display-scale window)
              (should (> (image-property (seshat-reader--multipage-page-spec 1)
                                         :width)
                         (window-body-width window t)))
              ;; 渲染时写下的引导空格还在（几何上已过期）
              (should (consp (seshat-reader-resize-test--align-form 1)))
              (cl-letf (((symbol-function 'set-window-hscroll)
                         (lambda (&rest _args) 0)))
                (seshat-reader--center-page window))
              (should-not (seshat-reader-resize-test--guide-display 1))
              (should (eq (seshat-reader-resize-test--image-display 1)
                          (seshat-reader--multipage-page-spec 1)))
              (should (seshat-reader--centered-p window)))))
      (kill-buffer buffer))))

;;; 62. --centered-p：before-string 引用旧 spec（equal 但非 eq）→ nil

(ert-deftest seshat-reader-resize-test--centered-p-detects-stale-spec ()
  "A guide that references a previous spec object is reported as stale.

A re-render replaces the image spec object; the row keeps pointing at the old
one.  `equal' would still hold (the geometry is identical), so only an
identity comparison (`eq') can tell that the frame would be laid out with the
previous page object — and only `nil' makes `--ensure-centered' repair it."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 500 700))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let* ((entry (assq 1 seshat-reader--pages))
                     (start (marker-position (cadr entry)))
                     (spec (cddr entry))
                     (old (copy-sequence spec)))
                (should (equal old spec))
                (should-not (eq old spec))
                (put-text-property start (1+ start) 'display
                                   (seshat-reader--multipage-align-to old))
                (should-not (seshat-reader--multipage-page-centered-p 1))
                (should-not (seshat-reader--centered-p window))
                ;; 修复后就地恢复（同一行、同一 spec 对象）
                (cl-letf (((symbol-function 'set-window-hscroll)
                           (lambda (&rest _args) 0)))
                  (seshat-reader--center-page window))
                (should (seshat-reader--multipage-page-centered-p 1))
                (should (seshat-reader--centered-p window))))))
      (kill-buffer buffer))))

;;; 63. --centered-p：before-string 引用当前 spec → t

(ert-deftest seshat-reader-resize-test--centered-p-true-for-live-spec ()
  "A fresh page row is already centred: no repair, no hscroll write.

This is the steady state after a render: the guide references the spec the row
displays, the page fits, so `--centered-p' is t and `--ensure-centered' must
not rebuild anything.  `pre-redisplay-functions' runs on every frame, so a
false negative here would rewrite the row forever."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (centers 0))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (seshat-reader--multipage-page-centered-p 1))
              (should (seshat-reader--multipage-page-centered-p 2))
              (should (seshat-reader--centered-p window))
              (cl-letf (((symbol-function 'seshat-reader--center-page)
                         (lambda (&optional _window) (cl-incf centers) nil)))
                (should-not (seshat-reader--ensure-centered window)))
              (should (= 0 centers)))))
      (kill-buffer buffer))))

;;; 64. --ensure-centered：stale 时重建一次

(ert-deftest seshat-reader-resize-test--ensure-centered-rebuilds-when-stale ()
  "A stale centring is rebuilt exactly once and the repair is idempotent.

The staleness is real here (the guide references a copy of the spec, the state
a re-render leaves behind), so `--ensure-centered' returns non-nil after
calling `--center-page' once, and the second call — now that the row matches
its spec again — returns nil and calls nothing.  The counter-check is what
distinguishes \"repaired once\" from \"repaired on every redisplay\"."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1)))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (centers 0))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let* ((entry (assq 1 seshat-reader--pages))
                     (start (marker-position (cadr entry)))
                     (old (copy-sequence (cddr entry))))
                (put-text-property start (1+ start) 'display
                                   (seshat-reader--multipage-align-to old))
                (should-not (seshat-reader--centered-p window))
                (cl-letf (((symbol-function 'seshat-reader--center-page)
                           (lambda (&optional _window) (cl-incf centers) nil)))
                  (should (seshat-reader--ensure-centered window))
                  (should (= 1 centers))
                  ;; 真正的修复（`--center-page' 已桩掉，这里手动跑一次）
                  (setq centers 0))
                (cl-letf (((symbol-function 'set-window-hscroll)
                           (lambda (&rest _args) 0)))
                  (seshat-reader--center-page window))
                (should (seshat-reader--centered-p window))
                (cl-letf (((symbol-function 'seshat-reader--center-page)
                           (lambda (&optional _window) (cl-incf centers) nil)))
                  (should-not (seshat-reader--ensure-centered window))
                  (should (= 0 centers))))))
      (kill-buffer buffer)))))

;;; 65. --centered-p：宽页 + 匹配的 line-prefix → t

(ert-deftest seshat-reader-resize-test--centered-p-true-for-wide-page-with-matched-prefix ()
  "A correctly left-aligned overwide page counts as placed, though not centred.

P1 重写：旧用例的「宽页 = line-prefix 宽度匹配」判据随 line-prefix 退役，换成
三态语义：超宽页的正确状态是「贴左」——`--multipage-page-centered-p' 为 nil
（没有引导空格），而 `--centered-p' 仍为 t（放置已经符合几何）。把它判成未就位
会让 `pre-redisplay-functions' 每帧重写一次行属性。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 2000 3000))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'manual)
              (seshat-reader--apply-display-scale window)
              (cl-letf (((symbol-function 'set-window-hscroll)
                         (lambda (&rest _args) 0)))
                (seshat-reader--center-page window))
              (should (> 2000 (window-body-width window t)))
              (should-not (seshat-reader--multipage-page-centered-p 1))
              (should (seshat-reader--centered-p window)))))
      (kill-buffer buffer))))

;;; 66. --centered-p：宽页 + 过期 line-prefix（宽度不等于剩余宽度）→ nil

(ert-deftest seshat-reader-resize-test--centered-p-detects-a-centred-overwide-page ()
  "An overwide page that still carries a centring space is reported as stale.

P1 重写：旧用例的「line-prefix 宽度不等于剩余宽度」换成同一类过期的另一种形态：
页面缩放/窗口尺寸变化后，一行原本居中的页变得比窗口还宽，引导空格却还留在那里。
这会把页面两侧同时裁掉，所以 `--centered-p' 必须报 nil 一次，让
`--center-page' 把它改成贴左。"
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 2000 3000))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window))))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 手动 1 倍：2000px 的页在 1000px 窗口里必然超宽，而渲染时写下的
              ;; 引导空格仍然在
              (setq seshat-reader--multipage-fit-mode 'manual)
              (seshat-reader--apply-display-scale window)
              (should (consp (seshat-reader-resize-test--align-form 1)))
              (should-not (seshat-reader--centered-p window))
              (cl-letf (((symbol-function 'set-window-hscroll)
                         (lambda (&rest _args) 0)))
                (seshat-reader--center-page window))
              (should-not (seshat-reader-resize-test--guide-display 1))
              (should (seshat-reader--centered-p window)))))
      (kill-buffer buffer))))

;;; 67. --ensure-centered：宽页一旦居中即零调用

(ert-deftest seshat-reader-resize-test--ensure-centered-noop-for-wide-page-once-centred ()
  "A left-aligned overwide page is the steady state: zero repairs.

Before the three-state check existed, \"centred\" only knew the guide form, which
an overwide page never has, so every frame redrew the row and rewrote the
horizontal scroll of a page the user may just have scrolled sideways."
  (let* ((fixture (seshat-reader-resize-test--geometry-buffer '(1) 2000 3000))
         (buffer (car fixture))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (centers 0))
    (unwind-protect
        (seshat-reader-resize-test--with-window-pixels 1000 800
          (seshat-reader-resize-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'manual)
              (seshat-reader--apply-display-scale window)
              (cl-letf (((symbol-function 'set-window-hscroll)
                         (lambda (&rest _args) 0)))
                (seshat-reader--center-page window))
              (should (seshat-reader--centered-p window))
              (cl-letf (((symbol-function 'seshat-reader--center-page)
                         (lambda (&optional _window) (cl-incf centers) nil)))
                (should-not (seshat-reader--ensure-centered window)))
              (should (= 0 centers)))))
      (kill-buffer buffer))))

;;; 68. --normalize-default-fit：`contain' 原样返回

(ert-deftest seshat-reader-resize-test--normalize-default-fit-contain ()
  "A `contain' default stays `contain'."
  (should (eq 'contain (seshat-reader--normalize-default-fit 'contain))))

;;; 69. --normalize-default-fit：`width' 原样返回

(ert-deftest seshat-reader-resize-test--normalize-default-fit-width ()
  "A `width' default stays `width'."
  (should (eq 'width (seshat-reader--normalize-default-fit 'width))))

;;; 70. --normalize-default-fit：`height' 原样返回

(ert-deftest seshat-reader-resize-test--normalize-default-fit-height ()
  "A `height' default stays `height'."
  (should (eq 'height (seshat-reader--normalize-default-fit 'height))))

;;; 71. --normalize-default-fit：旧函数值 `fit-to-width' → width

(ert-deftest seshat-reader-resize-test--normalize-default-fit-legacy-width ()
  "The legacy `seshat-reader-fit-to-width' value means `width'."
  (should (eq 'width
              (seshat-reader--normalize-default-fit
               'seshat-reader-fit-to-width))))

;;; 72. --normalize-default-fit：旧默认 `fit-to-height' → contain

(ert-deftest seshat-reader-resize-test--normalize-default-fit-legacy-height ()
  "The legacy `seshat-reader-fit-to-height' value means `contain'.

That function was the default until 2026-10-23 and the automatic fit it
triggered already behaved like `contain', so an untouched configuration
must keep starting windows in whole-page mode."
  (should (eq 'contain
              (seshat-reader--normalize-default-fit
               'seshat-reader-fit-to-height))))

;;; 73. --normalize-default-fit：未知值降级为 contain，不报错

(ert-deftest seshat-reader-resize-test--normalize-default-fit-unknown ()
  "Unknown values degrade to `contain' instead of signalling.

A `defcustom' set before the `:type' changed, a hand-written `setq' or a
string from a customization file must not break opening a document."
  (dolist (value (list 'foo nil "width" 42))
    (should (eq 'contain (seshat-reader--normalize-default-fit value)))))

;;; 74. --initial-fit-mode：无 fit-mode 窗口取 `seshat-reader-default-fit'

(ert-deftest seshat-reader-resize-test--initial-fit-mode-uses-default ()
  "A window without a recorded mode starts from the normalized default.

`seshat-reader-default-fit' is bound with `let' (it is an option, not a
window parameter) so the test is independent of the user's value."
  (let ((window (selected-window))
        (seshat-reader-default-fit 'width))
    (unwind-protect
        (progn
          (set-window-parameter window 'fit-mode nil)
          (should (eq 'width (seshat-reader--initial-fit-mode window))))
      (seshat-reader-resize-test--clear-window window))))

;;; 75. --initial-fit-mode：已记录的 fit-mode 不被默认值覆盖

(ert-deftest seshat-reader-resize-test--initial-fit-mode-keeps-existing ()
  "A window that already recorded a mode keeps it.

Resizing a window (or refitting it) must not reset the user's explicit
`W' / `H' choice back to `seshat-reader-default-fit'."
  (let ((window (selected-window))
        (seshat-reader-default-fit 'width))
    (unwind-protect
        (progn
          (set-window-parameter window 'fit-mode 'height)
          (should (eq 'height (seshat-reader--initial-fit-mode window))))
      (seshat-reader-resize-test--clear-window window))))

;;; seshat-reader-resize-test.el ends here
