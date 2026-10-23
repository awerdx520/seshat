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
;; **契约变更（2026-10-23）**：`--refit-window' 原先用「目标 scale 与当前
;; scale 相对差 ≤1% 则不重渲染」的偏差闸；改为「窗口的 `render-scale' 窗口
;; 参数（overlay 上次渲染所用的分辨率）与当前 `scale' 相等则不重渲染，不等
;; 则恰好重渲染一次」。原因：几何适配已由 `--apply-display-scale' 在尺寸变化
;; hook 内同步完成，重渲染前后几何相同，重渲染只负责提升清晰度，故判据是
;; 「已渲染分辨率 vs 显示比例」而不是「新旧目标比例差」。
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

(defun seshat-reader-resize-test--set-page-overlay (window buffer &optional source)
  "Give WINDOW a page overlay from BUFFER and record SOURCE as its scale source.

SOURCE is the `scale-source' window parameter: `fit', `manual' or nil for
`never recorded'."
  (let ((overlay (with-current-buffer buffer
                   (make-overlay (point-min) (point-min)))))
    (set-window-parameter window 'overlay overlay)
    (set-window-parameter window 'scale-source source)
    overlay))

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

(defun seshat-reader-resize-test--set-page-spec (window &optional width height)
  "Give WINDOW's page overlay an image spec of WIDTH x HEIGHT pixels.

The overlay is the one recorded by
`seshat-reader-resize-test--set-page-overlay'.  Return the spec, so tests can
read the properties back after calling `seshat-reader--apply-display-scale'."
  (let ((spec (seshat-reader-resize-test--image-spec width height)))
    (overlay-put (window-parameter window 'overlay) 'display spec)
    spec))

(cl-defun seshat-reader-resize-test--refit-counts (buffer window &key (live t) other-buffer (scale 1.5))
  "Call `seshat-reader--refit-window' on WINDOW in BUFFER and count its effects.

LIVE nil stubs `window-live-p' to nil, OTHER-BUFFER stubs `window-buffer'
to return it.  The fit step is counted where the refit actually rescales:
`seshat-reader--contain-scale' returns SCALE (default 1.5) and
`seshat-reader-doc-scale-page' applies it, so both are stubbed and the
counter increments on the apply call.  An implementation that went back to
`(funcall seshat-reader-default-fit)' would rescale through neither stub
and the counter would stay 0.

SCALE defaults to 1.5 so that it is farther than one percent away from the
scale the window carries when these tests run (nil, hence the 1.0
fallback): since 2026-10-23 the fit branch skips the re-render when the
target scale is within 1% of the current one, and a stub returning 1.0
would be swallowed by that gate instead of exercising the rescale.

`window-live-p' is left alone in the LIVE case: stubbing it breaks the
`with-selected-window' expansion used by the fit branch.  The windows passed
here are real batch-frame windows, hence live."
  (let ((fit 0)
        (clamp 0)
        (center 0)
        (target buffer))
    (cl-letf* (((symbol-function 'window-buffer)
                (lambda (&optional _window) (or other-buffer target)))
               ((symbol-function 'seshat-reader--contain-scale)
                (lambda (&optional _window) scale))
               ((symbol-function 'seshat-reader-doc-scale-page)
                (lambda (factor &optional _source)
                  (cl-incf fit)
                  (set-window-parameter nil 'scale factor)
                  (set-window-parameter nil 'scale-source 'fit)))
               ((symbol-function 'seshat-reader--clamp-window-vscroll)
                (lambda (&optional _window) (cl-incf clamp)))
               ((symbol-function 'seshat-reader--center-page)
                (lambda (&optional _window) (cl-incf center))))
      (if live
          (with-current-buffer target
            (seshat-reader--refit-window window))
        (cl-letf (((symbol-function 'window-live-p) (lambda (_window) nil)))
          (with-current-buffer target
            (seshat-reader--refit-window window)))))
    (list fit clamp center)))

(cl-defun seshat-reader-resize-test--run-pending-counts (buffer &key windows (scale 1.5))
  "Run `seshat-reader--run-pending-refit' for BUFFER and count the refit steps.

WINDOWS is what `get-buffer-window-list' is stubbed to return and SCALE is
what `seshat-reader--contain-scale' returns.  SCALE defaults to 1.5 so that
the 1% deviation gate of the fit branch lets the re-render through: the
windows here carry no `scale' parameter, so the current scale falls back to
1.0.  Returns (FIT CLAMP CENTER) aggregated over every window."
  (let ((fit 0)
        (clamp 0)
        (center 0)
        (target buffer)
        (wins windows))
    (cl-letf* (((symbol-function 'get-buffer-window-list) (lambda (&rest _) wins))
               ((symbol-function 'window-buffer)
                (lambda (&optional _window) target))
               ((symbol-function 'seshat-reader--contain-scale)
                (lambda (&optional _window) scale))
               ((symbol-function 'seshat-reader-doc-scale-page)
                (lambda (_factor &optional _source) (cl-incf fit)))
               ((symbol-function 'seshat-reader--clamp-window-vscroll)
                (lambda (&optional _window) (cl-incf clamp)))
               ((symbol-function 'seshat-reader--center-page)
                (lambda (&optional _window) (cl-incf center))))
      (seshat-reader--run-pending-refit target))
    (list fit clamp center)))

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

(ert-deftest seshat-reader-resize-test--refit-fit-branch ()
  "A window whose scale source is `fit' is rescaled to contain the page.

The contain stub supplies the new scale and the apply stub counts it once,
followed by one clamp and one recentre.  Reverting the fit branch to
`(funcall seshat-reader-default-fit)' produces (0 1 1)."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (should (equal '(1 1 1)
                         (seshat-reader-resize-test--refit-counts buffer window))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 4. refit：manual 分支保留 scale

(ert-deftest seshat-reader-resize-test--refit-manual-branch ()
  "A `manual' window keeps its scale: the geometry apply is skipped.

`render-scale' is set to the window's scale, so the clarity re-render of
`seshat-reader--refit-window' is skipped too and the counts stay (0 1 1).
The apply step is counted directly: removing the `manual' guard makes
`seshat-reader--apply-display-scale' run once even though the counts alone
would not notice it (`--contain-scale' is stubbed and there is no spec to
rewrite here).

契约变更（2026-10-23）：重渲染不再由「1% 偏差闸」决定，而由
`render-scale' 与 `scale' 是否相等决定；manual 窗口的 `scale' 不参与
几何适配，但同样受这条清晰度闸约束（相等即不重渲染）。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied 0))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'manual)
          (set-window-parameter window 'scale 2.25)
          (set-window-parameter window 'render-scale 2.25)
          (cl-letf (((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (&rest _) (cl-incf applied) nil)))
            (should (equal '(0 1 1)
                           (seshat-reader-resize-test--refit-counts
                            buffer window))))
          (should (= 0 applied))
          (should (eql 2.25 (window-parameter window 'scale)))
          (should (eq 'manual (window-parameter window 'scale-source))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 5. refit：未记录来源时按 fit 处理

(ert-deftest seshat-reader-resize-test--refit-unset-source ()
  "A window that never recorded a scale source counts as `fit'.

`scale-source' is left nil here.  An implementation that tests for the
literal `fit' value instead of `not manual' would skip the refit and
return (0 0 0)."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer nil)
          (set-window-parameter window 'scale-source nil)
          (should-not (window-parameter window 'scale-source))
          (should (eq 'fit (seshat-reader--window-scale-source window)))
          (should (equal '(1 1 1)
                         (seshat-reader-resize-test--refit-counts buffer window))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 6. 守卫：窗口已死

(ert-deftest seshat-reader-resize-test--refit-dead-window ()
  "A dead window is skipped silently: no fit, no clamp, no recentre, no error.

Everything else about the window is valid, so only the `window-live-p'
guard can produce the empty counts."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (should (equal '(0 0 0)
                         (seshat-reader-resize-test--refit-counts
                          buffer window :live nil))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 7. 守卫：窗口已换 buffer

(ert-deftest seshat-reader-resize-test--refit-wrong-buffer ()
  "A window that shows another buffer is skipped.

The other buffer is itself a `seshat-reader-mode' buffer, so removing the
`window-buffer' guard would let the refit run in it and the counts would
become (1 1 1)."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (other (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (should (equal '(0 0 0)
                         (seshat-reader-resize-test--refit-counts
                          buffer window :other-buffer other))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer other)
      (kill-buffer buffer))))

;;; 8. 守卫：overlay 参数失效

(ert-deftest seshat-reader-resize-test--refit-overlay-invalid ()
  "A window without a usable page overlay is skipped.

Both a nil and a non-overlay parameter value count as missing."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'overlay nil)
          (should (equal '(0 0 0)
                         (seshat-reader-resize-test--refit-counts buffer window)))
          (set-window-parameter window 'overlay "not-an-overlay")
          (should (equal '(0 0 0)
                         (seshat-reader-resize-test--refit-counts buffer window))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 9. vscroll 夹紧四态

(ert-deftest seshat-reader-resize-test--clamp-window-vscroll ()
  "Clamping covers the four states: above the maximum, negative, in range, empty page.

State 4 is the page-shorter-than-window case: the maximum is 0 while the
current scroll is positive, so the value must be clamped to 0 and sent.
Nothing is sent when the scroll is already inside the range, so a useless
redisplay is avoided."
  (let ((max-px 1400)
        (cur 1500)
        (sent nil))
    (cl-letf (((symbol-function 'seshat-reader--page-max-vscroll-pixels)
               (lambda (&optional _window) max-px))
              ((symbol-function 'seshat-reader--window-vscroll-pixels)
               (lambda (&optional _window) cur))
              ((symbol-function 'seshat-reader--set-window-vscroll)
               (lambda (_window vscroll &optional pixels-p)
                 (push (cons vscroll pixels-p) sent)
                 vscroll)))
      ;; ① image 2000 / body 600 / cur 1500 → 夹到 1400
      (should (= 1400 (seshat-reader--clamp-window-vscroll nil)))
      (should (equal '((1400 . t)) sent))
      ;; ② cur 为负 → 夹到 0
      (setq cur -50 sent nil)
      (should (= 0 (seshat-reader--clamp-window-vscroll (selected-window))))
      (should (equal '((0 . t)) sent))
      ;; ③ 已在区间内 → 不下发
      (setq cur 800 sent nil)
      (should (= 800 (seshat-reader--clamp-window-vscroll nil)))
      (should-not sent)
      ;; ④ 上限 0（页面比窗口矮）且 cur > 0 → 夹到 0 并下发
      (setq max-px 0 cur 120 sent nil)
      (should (= 0 (seshat-reader--clamp-window-vscroll nil)))
      (should (equal '((0 . t)) sent))
      ;; ④b 上限 0 且 cur 已为 0 → 零调用
      (setq cur 0 sent nil)
      (should (= 0 (seshat-reader--clamp-window-vscroll nil)))
      (should-not sent))))

;;; 10. doc-scale-page 的 source 语义

(ert-deftest seshat-reader-resize-test--doc-scale-page-source ()
  "Only a non-nil SOURCE is recorded; a one-argument call keeps the old source.

The scale itself is updated in both cases, so the nil-SOURCE assertions
cannot pass by accident: the 1-arg calls must have run."
  (let ((window (selected-window))
        (seshat-reader--recent-scale-fallback 1.0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-dyn--scale-page)
                   (lambda (factor) factor)))
          ;; 传 'manual → 写入来源与数值
          (seshat-reader-doc-scale-page 1.5 'manual)
          (should (eql 1.5 (window-parameter window 'scale)))
          (should (eq 'manual (window-parameter window 'scale-source)))
          (should (eql 1.5 seshat-reader--recent-scale-fallback))
          ;; 1 参调用不覆盖已有来源（先置 fit）
          (set-window-parameter window 'scale-source 'fit)
          (seshat-reader-doc-scale-page 2.0)
          (should (eql 2.0 (window-parameter window 'scale)))
          (should (eq 'fit (window-parameter window 'scale-source)))
          ;; 从未设置过来源时，1 参调用也不写入
          (set-window-parameter window 'scale-source nil)
          (seshat-reader-doc-scale-page 0.75)
          (should (eql 0.75 (window-parameter window 'scale)))
          (should-not (window-parameter window 'scale-source)))
      (seshat-reader-resize-test--clear-window window))))

;;; 11. presentation-mode 不回归

(ert-deftest seshat-reader-resize-test--presentation-mode-keeps-fit ()
  "`presentation-mode' records `fit' plus the `height' fit mode and keeps refitting.

Only the dynamic module entry points are stubbed, so the recorded `fit'
really comes from `seshat-reader-fit-to-height' passing it to
`seshat-reader-doc-scale-page'.

契约变更（2026-10-23）：`fit-to-height' 现在额外记录 `fit-mode' = `height'，
因此 refit 走 `--fit-scale' 的「按高度」分支（窗口像素高 / 页面 native 高），
不再经 `--contain-scale'；几何由同步 apply 完成，重渲染只在该窗口的
`render-scale' 与 `scale' 不等时发生一次。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer nil)
          ;; 真实 spec 让 refit 的同步 apply 真的能改写显示尺寸（否则
          ;; `--apply-display-scale' 无 spec 可改，`scale' 不会变）。
          (seshat-reader-resize-test--set-page-spec window 300 600)
          (set-window-parameter window 'scale 1.0)
          (let ((center 0))
            (cl-letf* (((symbol-function 'seshat-reader--get-current-doc-image-size)
                        (lambda (&optional _window) (cons 300 600)))
                       ((symbol-function 'window-body-height)
                        (lambda (&optional _window pixels-p)
                          (if pixels-p 300 30)))
                       ((symbol-function 'seshat-reader-dyn--scale-page)
                        (lambda (factor) factor))
                       ((symbol-function 'seshat-reader--center-page)
                        (lambda (&optional _window) (cl-incf center)))
                       ((symbol-function 'seshat-reader--set-window-vscroll)
                        (lambda (_window vscroll &optional _pixels-p) vscroll)))
              (seshat-reader-presentation-mode 1)
              (should seshat-reader-presentation-mode)
              (should-not mode-line-format)
              (should (eq 'fit (seshat-reader--window-scale-source window)))
              (should (eq 'height (seshat-reader--window-fit-mode window)))
              (should (eql 0.5 (window-parameter window 'scale)))
              (should (= 1 center))
              ;; 关闭前再 refit 一次：页面 300x600 在 scale 0.5 下的 native
              ;; 尺寸是 600x1200，窗口像素高 300 → 目标 scale 0.25。把
              ;; `render-scale' 设成 0.4 让它与目标不等，检验「真的重渲染」。
              (set-window-parameter window 'render-scale 0.4)
              (let ((rendered nil))
                (cl-letf* (((symbol-function 'window-buffer)
                            (lambda (&optional _window) buffer))
                           ((symbol-function 'seshat-reader--clamp-window-vscroll)
                            (lambda (&optional _window) nil))
                           ((symbol-function 'seshat-reader-doc-scale-page)
                            (lambda (factor &optional source)
                              (push (list factor source) rendered))))
                  (seshat-reader--refit-window window))
                ;; 契约变更（review-fix）：清晰化重渲染不再覆写
                ;; `scale-source'，故 `source' 实参为 nil。
                (should (equal '((0.25 nil)) rendered))
                (should (eql 0.25 (window-parameter window 'scale))))
              (seshat-reader-presentation-mode -1)
              (should mode-line-format)
              (should (eq 'fit (seshat-reader--window-scale-source window))))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 12. 多窗口各处理一次

(ert-deftest seshat-reader-resize-test--refit-multi-window ()
  "Two windows of the same buffer are refitted once each.

The refit is not restricted to the selected window: the counts are 2 for
the fit and 2 for the recentre, aggregated over both windows."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (w1 (selected-window))
         (w2 (split-window w1)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay w1 buffer 'fit)
          (seshat-reader-resize-test--set-page-overlay w2 buffer 'fit)
          (should (equal '(2 2 2)
                         (seshat-reader-resize-test--run-pending-counts
                          buffer :windows (list w1 w2)))))
      (seshat-reader-resize-test--clear-window w1)
      (seshat-reader-resize-test--clear-window w2)
      (delete-window w2)
      (kill-buffer buffer))))

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

(ert-deftest seshat-reader-resize-test--contain-scale-height-limited ()
  "The height-fitting scale wins when the page is proportionally taller.

Page 1000x1400 at scale 1.0 in a 900x1000 window: the width allows 0.9 but
the height only 1000/1400 = 0.714..., so the result must be the smaller
one.  An implementation returning `max' instead of `min' would return 0.9
and overflow the height."
  (let ((window (selected-window)))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons 1000 1400)))
              ((symbol-function 'seshat-reader-current-doc-scale-value)
               (lambda (&optional _window) 1.0))
              ((symbol-function 'window-body-width)
               (lambda (&optional _window pixels-p)
                 (if pixels-p 900 90)))
              ((symbol-function 'window-body-height)
               (lambda (&optional _window pixels-p)
                 (if pixels-p 1000 100))))
      (let ((got (seshat-reader--contain-scale window))
            (want (/ 1000.0 1400)))
        (should (< (abs (- got want)) 1e-9))
        ;; 必须严格小于按宽算出的 0.9，否则高度溢出
        (should (< got 0.9))))))

;;; 15. contain：宽度维胜出

(ert-deftest seshat-reader-resize-test--contain-scale-width-limited ()
  "The width-fitting scale wins when the window is narrow.

Same page in a 400x1000 window: the height allows 1000/1400 = 0.714...
but the width only 0.4, so 0.4 is the answer.  This is the regression the
real-machine report is about: reading only the height would return 0.714
and the rendered page would be about 1.8 times the window width."
  (let ((window (selected-window)))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons 1000 1400)))
              ((symbol-function 'seshat-reader-current-doc-scale-value)
               (lambda (&optional _window) 1.0))
              ((symbol-function 'window-body-width)
               (lambda (&optional _window pixels-p)
                 (if pixels-p 400 40)))
              ((symbol-function 'window-body-height)
               (lambda (&optional _window pixels-p)
                 (if pixels-p 1000 100))))
      (let ((got (seshat-reader--contain-scale window)))
        (should (< (abs (- got 0.4)) 1e-9))
        ;; 必须严格小于按高算出的 0.714...，否则宽度溢出
        (should (< got (/ 1000.0 1400)))))))

;;; 16. contain：退化输入

(ert-deftest seshat-reader-resize-test--contain-scale-degenerate ()
  "Unknown page size or a non-positive scale yields 1.0 instead of an error.

The size can be nil before the first render, and a width or height of 0 is
reported by the module for an empty page.  A scale of nil (never set) or 0
would divide by zero if it were used unguarded; both are treated as 1.0,
which is checked by the 0.5 result of the last two cases: the 500px wide
window against a 1000px wide page at scale 1.0."
  (let ((window (selected-window))
        (size (cons 1000 1400)))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) size))
              ((symbol-function 'seshat-reader-current-doc-scale-value)
               (lambda (&optional _window) 1.0))
              ((symbol-function 'window-body-width)
               (lambda (&optional _window pixels-p)
                 (if pixels-p 500 50)))
              ((symbol-function 'window-body-height)
               (lambda (&optional _window pixels-p)
                 (if pixels-p 2000 200))))
      ;; ① 尺寸未知
      (setq size nil)
      (should (eql 1.0 (seshat-reader--contain-scale window)))
      ;; ② 宽为 0
      (setq size (cons 0 1400))
      (should (eql 1.0 (seshat-reader--contain-scale window)))
      ;; ③ 高为 0
      (setq size (cons 1000 0))
      (should (eql 1.0 (seshat-reader--contain-scale window)))
      ;; ④ scale 为 nil → 按 1.0 处理
      (setq size (cons 1000 1400))
      (cl-letf (((symbol-function 'seshat-reader-current-doc-scale-value)
                 (lambda (&optional _window) nil)))
        (should (< (abs (- (seshat-reader--contain-scale window) 0.5)) 1e-9)))
      ;; ⑤ scale 为 0 → 按 1.0 处理，不得除零
      (cl-letf (((symbol-function 'seshat-reader-current-doc-scale-value)
                 (lambda (&optional _window) 0.0)))
        (should (< (abs (- (seshat-reader--contain-scale window) 0.5)) 1e-9))))))

;;; 17. --center-page：超宽时负偏移夹到 0

(ert-deftest seshat-reader-resize-test--center-page-clamps-negative-offset ()
  "A page wider than the window is not scrolled by a negative amount.

The page is 2000px wide while the batch window is narrower, so
`doc-center-offset' is negative and the un-clamped offset would be
negative; `seshat-reader--set-window-hscroll' must receive 0.  Before the
clamp the recorded NCOL was negative, which scrolled the page left and cut
it on both sides."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (sent nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((center-overlay (with-current-buffer buffer
                                 (make-overlay (point-min) (point-min)))))
            ;; 契约变更（2026-10-23）：图宽改由 `--page-image-spec' 提供（居中方案
            ;; 需要 image 对象本身），超宽判定与 hscroll 夹紧逻辑保持不变。
            (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                       (lambda (&optional _window)
                         (seshat-reader-resize-test--image-spec 2000 1000)))
                      ((symbol-function 'seshat-reader--ensure-center-overlay)
                       (lambda (&optional _window) center-overlay))
                      ((symbol-function 'seshat-reader--set-window-hscroll)
                       (lambda (target ncol &optional unconstrained)
                         (push (list target ncol unconstrained) sent)
                         ncol)))
              ;; 前提：页面确实宽于窗口，否则该用例没有牙
              (should (> 2000 (window-body-width window t)))
              (seshat-reader--center-page window)
              (should (= 1 (length sent)))
              (let ((ncol (nth 1 (car sent))))
                (should (numberp ncol))
                (should (>= ncol 0))
                (should (eql 0 ncol))))))
      (seshat-reader-resize-test--clear-window window)
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

(ert-deftest seshat-reader-resize-test--refit-fit-skip-when-scale-unchanged ()
  "A page already rendered at the displayed scale is not re-rendered.

契约变更（2026-10-23）：原判据是「目标 scale 与当前 scale 相对差 ≤1% 则
不重渲染」，现判据是「窗口参数 `render-scale'（overlay 上次渲染所用的
分辨率）与当前 `scale' 相等则不重渲染」；原因：几何适配已由
`--apply-display-scale' 在尺寸变化 hook 内同步完成，几何差恒为 0，
重渲染只剩下「提升清晰度」的作用，故按已渲染分辨率判断。

Re-rendering is synchronous (the C side waits for the cached page) and the
re-render changes `line-prefix' and vscroll, which can be reported back as
another size change; the gate breaks that loop.  Clamping and recentring
still run, so the counts are (0 1 1) and the `scale' window parameter keeps
its 1.6 value.  Without the gate the counts would be (1 1 1) and `scale'
would be written by `seshat-reader-doc-scale-page' even though nothing
changed."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied 0))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 1.6)
          (set-window-parameter window 'render-scale 1.6)
          (cl-letf (((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (&rest _) (cl-incf applied) nil)))
            (should (equal '(0 1 1)
                           (seshat-reader-resize-test--refit-counts
                            buffer window :scale 1.6))))
          (should (eql 1.6 (window-parameter window 'scale)))
          (should (eq 'fit (window-parameter window 'scale-source))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 21. 清晰度闸：`render-scale' 与 `scale' 不等 → 重渲染，参数为该 scale

(ert-deftest seshat-reader-resize-test--refit-fit-applies-when-scale-differs ()
  "A page rendered at another resolution is re-rendered once, with one argument.

契约变更（2026-10-23）：判据由「1% 偏差闸」改为 `render-scale' 与 `scale'
是否相等（见第 20 节）。此处 `render-scale' 是 1.2、当前 `scale' 是 1.6。

契约变更（review-fix）：清晰化重渲染**不再覆写** `scale-source'，因此
`seshat-reader-doc-scale-page' 只收到一个实参（`source' 为 nil），manual
窗口不会因为一次 resize 被静默转成 fit。

The apply step is stubbed to write the target scale, the way the real
`seshat-reader--apply-display-scale' does; the recorded re-render call then
pins both the value (the displayed scale, not the one the overlay was
rendered at) and the absence of a source.  Re-rendering at `render-scale'
instead of `scale', or passing a source, makes the assertion fail."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 1.6)
          (set-window-parameter window 'render-scale 1.2)
          (cl-letf (((symbol-function 'window-buffer)
                     (lambda (&optional _window) buffer))
                    ((symbol-function 'seshat-reader--contain-scale)
                     (lambda (&optional _window) 1.8))
                    ((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (target scale)
                       (set-window-parameter target 'scale scale)
                       t))
                    ((symbol-function 'seshat-reader-doc-scale-page)
                     (lambda (factor &optional source)
                       (push (list factor source) applied)))
                    ((symbol-function 'seshat-reader--clamp-window-vscroll)
                     (lambda (&optional _window) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) nil)))
            (with-current-buffer buffer
              (seshat-reader--refit-window window)))
          (should (equal '((1.8 nil)) applied))
          (should (eql 1.8 (window-parameter window 'scale)))
          (should (eq 'fit (window-parameter window 'scale-source))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

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

(ert-deftest seshat-reader-resize-test--size-change-recentres-synchronously ()
  "A size change recentres the window before the refit is queued.

`seshat-reader--center-page' writes a static `line-prefix' and a static
horizontal scroll, and redisplay recomputes neither, so a hook that only
schedules the refit leaves the frame which noticed the size change
off-centre until the idle timer fires (175px on the real machine).  The
order assertion is the point of this test: centring must happen
synchronously, inside the hook, before the debounced refit is armed."
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (events nil))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (cl-letf (((symbol-function 'seshat-reader--clamp-window-vscroll)
                     (lambda (&optional _window) (push 'clamp events)))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (push 'center events)))
                    ((symbol-function 'seshat-reader--schedule-refit)
                     (lambda () (push 'refit events) nil)))
            (with-current-buffer buffer
              (seshat-reader--window-size-change window)))
          (should (equal '(clamp center refit) (nreverse events))))
      (set-window-buffer window orig-buffer)
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 24. 尺寸变化：frame 形态居中每个匹配窗口，但只排一次 refit

(ert-deftest seshat-reader-resize-test--size-change-recentres-every-window ()
  "The frame shape recentres every matching window but queues one refit.

Both windows show the reader buffer, so both must be recentred
synchronously: a `throw' that stops at the first match leaves the second
window showing a stale, off-centre page.  The refit is buffer-wide — it
cancels and re-arms a single timer — so it is queued once, not once per
window."
  (let* ((window1 (selected-window))
         (orig-buffer (window-buffer window1))
         (buffer (seshat-reader-resize-test--reader-buffer))
         (window2 nil)
         (clamps 0)
         (centers 0)
         (refits 0))
    (unwind-protect
        (progn
          (setq window2 (split-window window1))
          (dolist (window (list window1 window2))
            (set-window-buffer window buffer)
            (seshat-reader-resize-test--set-page-overlay window buffer 'fit))
          (cl-letf (((symbol-function 'seshat-reader--clamp-window-vscroll)
                     (lambda (&optional _window) (cl-incf clamps)))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (cl-incf centers)))
                    ((symbol-function 'seshat-reader--schedule-refit)
                     (lambda () (cl-incf refits) nil)))
            (with-current-buffer buffer
              (seshat-reader--window-size-change (selected-frame))))
          (should (= 2 clamps))
          (should (= 2 centers))
          (should (= 1 refits)))
      (when (window-live-p window2)
        (ignore-errors (delete-window window2)))
      (dolist (window (list window1 window2))
        (when (window-live-p window)
          (set-window-buffer window orig-buffer)
          (seshat-reader-resize-test--clear-window window)))
      (kill-buffer buffer))))

;;; 25. 守卫：overlay 缺失时只跳过同步段，refit 照排

(ert-deftest seshat-reader-resize-test--recenter-skips-window-without-overlay ()
  "A window without a page overlay is skipped by the recentre, not the refit.

The overlay guard belongs to the synchronous recentre: a window whose
`overlay' parameter is missing — or holds something that is not an overlay —
must still get its refit queued, otherwise a page that lost its overlay for
a moment would never be re-rendered.  Zero clamps and zero centres with one
refit pin exactly that split."
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (clamps 0)
        (centers 0)
        (refits 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          ;; 非 overlay 的 'overlay 参数：守卫必须按 overlayp 判，而不是按存在性
          (set-window-parameter window 'overlay "not-an-overlay")
          (cl-letf (((symbol-function 'seshat-reader--clamp-window-vscroll)
                     (lambda (&optional _window) (cl-incf clamps)))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (cl-incf centers)))
                    ((symbol-function 'seshat-reader--schedule-refit)
                     (lambda () (cl-incf refits) nil)))
            (with-current-buffer buffer
              (seshat-reader--window-size-change window)))
          (should (= 0 clamps))
          (should (= 0 centers))
          (should (= 1 refits)))
      (set-window-buffer window orig-buffer)
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 26. 换 buffer 到同一个 reader buffer：已有 overlay 时补一次 recentre

(ert-deftest seshat-reader-resize-test--window-buffer-change-recentres-existing-overlay ()
  "A surviving page overlay gets recentred, and no second overlay is created.

`set-window-buffer' zeroes the window's horizontal scroll by itself, so a
window that shows an already-rendered reader buffer — the page overlay is
still there, no size change fired — must be recentred here.  Before the
recentre branch existed this test failed with zero recentres: the create
branch was skipped because the overlay parameter was set, and nothing else
re-aligned the page."
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (recentres 0)
        (creates 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (cl-letf (((symbol-function 'seshat-reader--recenter-window)
                     (lambda (_window) (cl-incf recentres)))
                    ((symbol-function 'seshat-reader--window-create-function)
                     (lambda (_window) (cl-incf creates))))
            (with-current-buffer buffer
              (seshat-reader--handle-window-buffer-change window)))
          (should (= 1 recentres))
          (should (= 0 creates)))
      (set-window-buffer window orig-buffer)
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 27. 换 buffer 到同一个 reader buffer：缺 overlay 时只创建，不 recentre

(ert-deftest seshat-reader-resize-test--window-buffer-change-creates-overlay-when-missing ()
  "Without a page overlay the create branch runs and the recentre does not.

The two branches are mutually exclusive because `--window-create-function'
centres the page itself; running both would do the alignment work twice.
One create with zero recentres pins the exclusivity."
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (recentres 0)
        (creates 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (seshat-reader-resize-test--clear-window window)
          (cl-letf (((symbol-function 'seshat-reader--recenter-window)
                     (lambda (_window) (cl-incf recentres)))
                    ((symbol-function 'seshat-reader--window-create-function)
                     (lambda (_window) (cl-incf creates))))
            (with-current-buffer buffer
              (seshat-reader--handle-window-buffer-change window)))
          (should (= 0 recentres))
          (should (= 1 creates)))
      (set-window-buffer window orig-buffer)
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 28. 换 buffer 到普通 buffer：两条分支都不走

(ert-deftest seshat-reader-resize-test--window-buffer-change-skips-non-reader-buffer ()
  "A window showing a non-reader buffer neither recentres nor creates an overlay.

The `derived-mode-p' guard must gate both branches: a plain buffer has no
page to align, and creating an overlay there would attach the reader's
display machinery to an unrelated buffer."
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (generate-new-buffer " *seshat-reader-resize-test-plain*"))
        (recentres 0)
        (creates 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (should (eq (with-current-buffer buffer major-mode) 'fundamental-mode))
          (cl-letf (((symbol-function 'seshat-reader--recenter-window)
                     (lambda (_window) (cl-incf recentres)))
                    ((symbol-function 'seshat-reader--window-create-function)
                     (lambda (_window) (cl-incf creates))))
            (with-current-buffer buffer
              (seshat-reader--handle-window-buffer-change window)))
          (should (= 0 recentres))
          (should (= 0 creates)))
      (set-window-buffer window orig-buffer)
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 29. image size 未知时 right-most-window-hscroll 返回 0 且不抛错

(ert-deftest seshat-reader-resize-test--right-most-window-hscroll-nil-image-size ()
  "An unrendered page yields 0 instead of a `wrong-type-argument' error.

`--get-current-doc-image-size' returns (nil . nil) until the overlay display
carries :width/:height, and this function runs during mode initialisation
from `--set-window-hscroll'.  Subtracting nil from the pixel width used to
signal; the nil guard turns that into a harmless 0."
  (let ((window (selected-window))
        (result 'unset))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons nil nil)))
              ((symbol-function 'seshat-reader--get-prefix-width)
               (lambda (&optional _window) 0))
              ((symbol-function 'seshat-reader--get-pixel-per-col)
               (lambda (&optional _window) 9)))
      (setq result (seshat-reader--right-most-window-hscroll window)))
    (should (= 0 result))))

;;; 30. image size 已知时公式不变

(ert-deftest seshat-reader-resize-test--right-most-window-hscroll-formula-regression ()
  "A known image size still goes through the original arithmetic.

The nil guard must only short-circuit the unknown-size case: with a 2000px
page, a 1000px window body and 10px per column the rightmost hscroll stays
the old (2000 - 1000) / 10 = 100."
  (let ((window (selected-window))
        (result 'unset))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons 2000 3000)))
              ((symbol-function 'seshat-reader--get-prefix-width)
               (lambda (&optional _window) 0))
              ((symbol-function 'seshat-reader--get-pixel-per-col)
               (lambda (&optional _window) 10))
              ((symbol-function 'window-body-width)
               (lambda (&optional _window _pixelwise) 1000)))
      (setq result (seshat-reader--right-most-window-hscroll window)))
    (should (= 100 result))))

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

;;; 32. --fit-scale：contain 模式等价于 --contain-scale

(ert-deftest seshat-reader-resize-test--fit-scale-contain-passes-through ()
  "In `contain' mode the target scale is exactly `--contain-scale'.

The stub counts its calls and returns a distinctive value, so an
implementation that recomputed the contain scale inline (or read the
window dimensions itself) would not produce 1.25 from one call."
  (let ((window (selected-window))
        (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader--contain-scale)
                   (lambda (&optional _window) (cl-incf calls) 1.25))
                  ;; 若 contain 分支被写坏成「按维度算」，这些桩会给出别的值。
                  ((symbol-function 'window-body-width)
                   (lambda (&optional _window _pixels-p) 99))
                  ((symbol-function 'window-body-height)
                   (lambda (&optional _window _pixels-p) 99)))
          (set-window-parameter window 'fit-mode nil)
          (should (= 1.25 (seshat-reader--fit-scale window)))
          (should (= 1 calls)))
      (set-window-parameter window 'fit-mode nil))))

;;; 33. --fit-scale：width 模式 = 窗口像素宽 / native 宽

(ert-deftest seshat-reader-resize-test--fit-scale-width-mode ()
  "In `width' mode the target scale fills the width and ignores the height.

The window is stubbed to 400 pixels wide and 100 pixels tall for a
200 x 100 page, so the width result is 2.0 while a stray height-based
computation would give 1.0."
  (let ((window (selected-window)))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader--native-page-size)
                   (lambda (&optional _window) (cons 200.0 100.0)))
                  ((symbol-function 'window-body-width)
                   (lambda (&optional _window pixels-p)
                     (if pixels-p 400 50)))
                  ((symbol-function 'window-body-height)
                   (lambda (&optional _window pixels-p)
                     (if pixels-p 100 10)))
                  ((symbol-function 'seshat-reader--contain-scale)
                   (lambda (&optional _window) 0.1)))
          (set-window-parameter window 'fit-mode 'width)
          (should (= 2.0 (seshat-reader--fit-scale window))))
      (set-window-parameter window 'fit-mode nil))))

;;; 34. --fit-scale：height 模式 = 窗口像素高 / native 高

(ert-deftest seshat-reader-resize-test--fit-scale-height-mode ()
  "In `height' mode the target scale fills the height and ignores the width.

The window is stubbed to 100 pixels wide and 300 pixels tall for a
200 x 100 page, so the height result is 3.0 while a stray width-based
computation would give 0.5."
  (let ((window (selected-window)))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader--native-page-size)
                   (lambda (&optional _window) (cons 200.0 100.0)))
                  ((symbol-function 'window-body-width)
                   (lambda (&optional _window pixels-p)
                     (if pixels-p 100 10)))
                  ((symbol-function 'window-body-height)
                   (lambda (&optional _window pixels-p)
                     (if pixels-p 300 30)))
                  ((symbol-function 'seshat-reader--contain-scale)
                   (lambda (&optional _window) 0.1)))
          (set-window-parameter window 'fit-mode 'height)
          (should (= 3.0 (seshat-reader--fit-scale window))))
      (set-window-parameter window 'fit-mode nil))))

;;; 35. --fit-scale：没有 native 尺寸时退回 1.0

(ert-deftest seshat-reader-resize-test--fit-scale-without-native-size ()
  "Without a native page size the width and height modes fall back to 1.0.

The page has not been rendered yet (or the spec carries no usable size), so
there is nothing to divide by; 1.0 keeps the page at its default size
instead of signalling an error."
  (let ((window (selected-window)))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader--native-page-size)
                   (lambda (&optional _window) nil)))
          (dolist (mode '(width height))
            (set-window-parameter window 'fit-mode mode)
            (should (= 1.0 (seshat-reader--fit-scale window)))
            (should (eql 1.0 (seshat-reader--fit-scale window)))))
      (set-window-parameter window 'fit-mode nil))))

;;; 36. --apply-display-scale：改 spec 与 'scale

(ert-deftest seshat-reader-resize-test--apply-display-scale-rewrites-spec ()
  "Halving the scale halves the spec's display size and records the scale.

`native-size' is stubbed to the page's unscaled size, so the expected spec
size is exact: 200 x 100 at 0.5 is 100 x 50.  The window's `scale' and the
buffer-local fallback must follow the spec, otherwise the invariant
\"spec size / `scale' = native size\" breaks for `--contain-scale' and the
vscroll upper bound."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((spec (seshat-reader-resize-test--set-page-spec window 200 100)))
            (set-window-parameter window 'scale 1.0)
            (cl-letf (((symbol-function 'seshat-reader--native-page-size)
                       (lambda (&optional _window) (cons 200.0 100.0))))
              (with-current-buffer buffer
                (should (seshat-reader--apply-display-scale window 0.5))
                ;; `seshat-reader--recent-scale-fallback' 是 buffer-local，
                ;; 必须在同一 buffer 内读回。
                (should (= 0.5 seshat-reader--recent-scale-fallback))))
            (should (eql 100 (image-property spec :width)))
            (should (eql 50 (image-property spec :height)))
            (should (eql 0.5 (window-parameter window 'scale)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 37. --apply-display-scale：尺寸未变时不重写 spec

(ert-deftest seshat-reader-resize-test--apply-display-scale-same-size ()
  "Applying the scale the spec already has returns nil and writes nothing.

The spec is read back afterwards: a no-op rewrite would still be invisible
in the return value, so the assertion is on the properties themselves.  Not
rewriting keeps redisplay from being invalidated for nothing.

返回 nil 无法区分「不 setf」与「setf 相同值」，故桩住 setf 的实际落点计数。
`setf' 的落点经实测确认：`(setf (image-property spec :width) V)' 的
`gv-expander' 展开为 `(image--set-property spec :width V)'，后者在 IMAGE
非空 plist 时执行 `(setcdr image (plist-put (cdr image) property value))'
（Emacs 31.1 image.el 第 600 行），因此桩 `plist-put' 并转发原函数即可覆盖
两条写入路径。注意 Emacs 31 的 `plist-put' 签名是 `(PLIST PROP VAL
&optional PREDICATE)'，桩必须用 `&rest' 转发，否则会与 4 参调用冲突。
第一段把 200 x 100 改成 100 x 50（计数 ≥ 1），第二段用同一 scale 复算
（尺寸相同，计数必须为 0）。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (writes 0)
         (original-plist-put (symbol-function 'plist-put))
         (changed-writes nil)
         (same-writes nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((spec (seshat-reader-resize-test--set-page-spec window 200 100)))
            (set-window-parameter window 'scale 1.0)
            (cl-letf (((symbol-function 'seshat-reader--native-page-size)
                       (lambda (&optional _window) (cons 200.0 100.0)))
                      ((symbol-function 'plist-put)
                       (lambda (&rest args)
                         (cl-incf writes)
                         (apply original-plist-put args))))
              (with-current-buffer buffer
                ;; 尺寸改变：spec 必须被真的写入
                (setq writes 0)
                (should (seshat-reader--apply-display-scale window 0.5))
                (setq changed-writes writes)
                ;; 尺寸相同：不得写入（setf 计数为 0）
                (setq writes 0)
                (should-not (seshat-reader--apply-display-scale window 0.5))
                (setq same-writes writes))
              (should (>= changed-writes 1))
              (should (= 0 same-writes)))
            (should (eql 100 (image-property spec :width)))
            (should (eql 50 (image-property spec :height)))
            ;; 读原始 plist：改的必须是 overlay 上那张表本身，不是副本。
            (should (eql 100 (plist-get (cdr spec) :width)))
            (should (eql 50 (plist-get (cdr spec) :height)))
            (should (eq spec (overlay-get (window-parameter window 'overlay)
                                          'display)))
            (should (eql 0.5 (window-parameter window 'scale)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 38. --apply-display-scale：无 spec（还不是图片）→ nil，不写 'scale

(ert-deftest seshat-reader-resize-test--apply-display-scale-without-spec ()
  "A page that is not an image yet is left alone, without signalling.

Tty sessions, a page whose overlay was just created, and the first frame
after opening a document all reach this path; writing `scale' anyway would
desynchronise the window parameter from a spec that was never resized."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 2.0)
          (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                     (lambda (_window) nil)))
            (with-current-buffer buffer
              (should-not (seshat-reader--apply-display-scale window 0.5))))
          (should (eql 2.0 (window-parameter window 'scale))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 39. --native-page-size：由 spec / scale 推算并写入缓存

(ert-deftest seshat-reader-resize-test--native-page-size-computes ()
  "The unscaled size is the spec size divided by the scale, cached by page.

The page is 200 x 100 at scale 1.0, so the native size is (200.0 . 100.0)
and the cache holds `(PAGE . SIZE)' = (1 200.0 . 100.0), a cons of the page
number and the size cons — not a flat three-element list."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (seshat-reader-resize-test--set-page-spec window 200 100)
          (set-window-parameter window 'page 1)
          (set-window-parameter window 'scale 1.0)
          (should (equal (cons 200.0 100.0)
                         (seshat-reader--native-page-size window)))
          (should (equal (cons 1 (cons 200.0 100.0))
                         (window-parameter window 'native-size))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 40. --native-page-size：命中缓存后不再读 spec

(ert-deftest seshat-reader-resize-test--native-page-size-cache-hit ()
  "The second measurement of the same page reuses the cached size.

`--page-image-spec' is counted: the cache exists so that the per-resize hook
does not walk the overlay display property on every event, and the second
call must not read the spec again."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (reads 0))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'page 1)
          (set-window-parameter window 'scale 1.0)
          (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                     (lambda (_window)
                       (cl-incf reads)
                       (seshat-reader-resize-test--image-spec 200 100))))
            (should (equal (cons 200.0 100.0)
                           (seshat-reader--native-page-size window)))
            (should (equal (cons 200.0 100.0)
                           (seshat-reader--native-page-size window)))
            (should (= 1 reads))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 41. --recenter-window：fit 窗口先 apply，再 clamp，再 center

(ert-deftest seshat-reader-resize-test--recenter-window-applies-first ()
  "A fit window is scaled first, then clamped, then recentred.

The order matters: the clamp and the recentre read the page geometry, so
computing them before the spec is resized would use the previous size.  The
symbols are pushed as the steps run, then compared in reverse."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (order nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (cl-letf* (((symbol-function 'window-buffer)
                      (lambda (&optional _window) buffer))
                     ((symbol-function 'seshat-reader--fit-scale)
                      (lambda (&optional _window) 1.5))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (_window scale)
                        (push (cons 'apply scale) order)
                        t))
                     ((symbol-function 'seshat-reader--clamp-window-vscroll)
                      (lambda (&optional _window) (push 'clamp order)))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) (push 'center order))))
            (with-current-buffer buffer
              (seshat-reader--recenter-window window)))
          (should (equal '(center clamp (apply . 1.5)) order)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 42. --recenter-window：manual 窗口跳过 apply

(ert-deftest seshat-reader-resize-test--recenter-window-skips-manual-apply ()
  "A `manual' window is clamped and recentred but never rescaled.

`scale-source' is `manual', so the synchronous geometry step is skipped: the
user's zoom must survive a resize.  The clamp and the recentre still run,
because they are read-only geometry fixes."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (order nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'manual)
          (cl-letf* (((symbol-function 'window-buffer)
                      (lambda (&optional _window) buffer))
                     ((symbol-function 'seshat-reader--fit-scale)
                      (lambda (&optional _window) 1.5))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (&rest _) (push 'apply order) t))
                     ((symbol-function 'seshat-reader--clamp-window-vscroll)
                      (lambda (&optional _window) (push 'clamp order)))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) (push 'center order))))
            (with-current-buffer buffer
              (seshat-reader--recenter-window window)))
          (should (equal '(center clamp) order)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 43. --refit-window：已渲染分辨率与显示比例一致 → 零重渲染

(ert-deftest seshat-reader-resize-test--refit-skips-render-when-scale-matches ()
  "A refit whose displayed scale equals `render-scale' renders nothing.

契约变更（2026-10-23）：判据是 `render-scale' 与 `scale' 相等（原为 1%
偏差闸）。The apply stub writes the scale the way the real apply does, so the
window's scale and `render-scale' end up equal and
`seshat-reader-doc-scale-page' is not called; clamp and recentre still run."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 1.6)
          (set-window-parameter window 'render-scale 1.6)
          (cl-letf (((symbol-function 'seshat-reader--contain-scale)
                     (lambda (&optional _window) 1.6))
                    ((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (target scale)
                       (set-window-parameter target 'scale scale)
                       nil)))
            (should (equal '(0 1 1)
                           (seshat-reader-resize-test--refit-counts
                            buffer window :scale 1.6))))
          (should (eql 1.6 (window-parameter window 'scale))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 44. --refit-window：从未渲染过（render-scale 为 nil）→ 恰好一次

(ert-deftest seshat-reader-resize-test--refit-renders-once-when-never-rendered ()
  "A page that was never rendered is re-rendered exactly once, with one argument.

`render-scale' is nil here — the state of a window whose overlay was created
without a scale change — so the equality check fails and the page is
rendered once at the displayed scale.  Rendering twice (once per branch)
would show up as a count of 2.

契约变更（review-fix）：清晰化重渲染不再覆写 `scale-source'，故实参只有
一个（`source' 为 nil）；断言用 `list' 而非 `cons' 才能区分
`(1.6 nil)' 与 `(1.6 . fit)'。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 1.6)
          (set-window-parameter window 'render-scale nil)
          (cl-letf (((symbol-function 'window-buffer)
                     (lambda (&optional _window) buffer))
                    ((symbol-function 'seshat-reader--contain-scale)
                     (lambda (&optional _window) 1.6))
                    ((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-doc-scale-page)
                     (lambda (factor &optional source)
                       (push (list factor source) applied)))
                    ((symbol-function 'seshat-reader--clamp-window-vscroll)
                     (lambda (&optional _window) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) nil)))
            (with-current-buffer buffer
              (seshat-reader--refit-window window)))
          (should (equal '((1.6 nil)) applied)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 45. fit-to-width：记录 fit-mode = width

(ert-deftest seshat-reader-resize-test--fit-to-width-records-mode ()
  "`fit-to-width' scales by width / native width and records `width'.

The dynamic-module entry point is stubbed with the page size, so the factor
is exact: 400 pixels of window over a 200 pixel page is 2.0.  The recorded
mode is what makes a later resize keep filling the width instead of falling
back to the containing scale."
  (let ((window (selected-window))
        (calls nil))
    (unwind-protect
        (cl-letf* (((symbol-function 'seshat-reader--get-current-doc-image-size)
                    (lambda (&optional _window) (cons 200 100)))
                   ((symbol-function 'window-body-width)
                    (lambda (&optional _window pixels-p)
                      (if pixels-p 400 50)))
                   ((symbol-function 'seshat-reader-current-doc-scale-value)
                    (lambda (&optional _window) 1.0))
                   ((symbol-function 'seshat-reader-doc-scale-page)
                    (lambda (factor &optional source)
                      (push (cons factor source) calls)))
                   ((symbol-function 'seshat-reader--center-page)
                    (lambda (&optional _window) nil))
                   ((symbol-function 'seshat-reader--set-page-top-when-joined)
                    (lambda (&optional _window) nil)))
          (seshat-reader-fit-to-width)
          (should (equal '((2.0 . fit)) calls))
          (should (eq 'width (window-parameter window 'fit-mode))))
      (set-window-parameter window 'fit-mode nil))))

;;; 46. fit-to-height：记录 fit-mode = height

(ert-deftest seshat-reader-resize-test--fit-to-height-records-mode ()
  "`fit-to-height' scales by height / native height and records `height'.

The factor is exact again: 300 pixels of window over a 100 pixel page is
3.0.  `presentation-mode' calls this function, so the recorded mode is also
what keeps presentation mode fitting by height after a resize."
  (let ((window (selected-window))
        (calls nil))
    (unwind-protect
        (cl-letf* (((symbol-function 'seshat-reader--get-current-doc-image-size)
                    (lambda (&optional _window) (cons 200 100)))
                   ((symbol-function 'window-body-height)
                    (lambda (&optional _window pixels-p)
                      (if pixels-p 300 30)))
                   ((symbol-function 'seshat-reader-current-doc-scale-value)
                    (lambda (&optional _window) 1.0))
                   ((symbol-function 'seshat-reader-doc-scale-page)
                    (lambda (factor &optional source)
                      (push (cons factor source) calls)))
                   ((symbol-function 'seshat-reader--center-page)
                    (lambda (&optional _window) nil))
                   ((symbol-function 'seshat-reader--set-page-top)
                    (lambda (&optional _window) nil)))
          (seshat-reader-fit-to-height)
          (should (equal '((3.0 . fit)) calls))
          (should (eq 'height (window-parameter window 'fit-mode))))
      (set-window-parameter window 'fit-mode nil))))

;;; 47. --native-page-size：页号 nil 且无 spec → nil，不写缓存

(ert-deftest seshat-reader-resize-test--native-page-size-no-document ()
  "Without a page number and without a spec the size is nil and not cached.

This is the state of a window that has not opened a document yet; caching a
nil size would make every later call return it for page nil."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer nil)
          (set-window-parameter window 'page nil)
          (set-window-parameter window 'native-size nil)
          (should-not (seshat-reader--native-page-size window))
          (should-not (window-parameter window 'native-size)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 48. --native-page-size：多窗口隔离，互不覆盖

(ert-deftest seshat-reader-resize-test--native-page-size-per-window ()
  "Two windows on two pages keep their own cached size.

`native-size' is a window parameter, so window one must keep its 200 x 100
page even after window two measured a 400 x 200 one; a buffer-level cache
would make the second measurement overwrite the first."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (w1 (selected-window))
         (w2 (split-window w1)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay w1 buffer 'fit)
          (seshat-reader-resize-test--set-page-overlay w2 buffer 'fit)
          (seshat-reader-resize-test--set-page-spec w1 200 100)
          (seshat-reader-resize-test--set-page-spec w2 400 200)
          (set-window-parameter w1 'page 1)
          (set-window-parameter w1 'scale 1.0)
          (set-window-parameter w2 'page 2)
          (set-window-parameter w2 'scale 1.0)
          (should (equal (cons 200.0 100.0)
                         (seshat-reader--native-page-size w1)))
          (should (equal (cons 400.0 200.0)
                         (seshat-reader--native-page-size w2)))
          (should (equal (cons 200.0 100.0)
                         (seshat-reader--native-page-size w1)))
          (should (equal (cons 1 (cons 200.0 100.0))
                         (window-parameter w1 'native-size)))
          (should (equal (cons 2 (cons 400.0 200.0))
                         (window-parameter w2 'native-size))))
      (seshat-reader-resize-test--clear-window w1)
      (seshat-reader-resize-test--clear-window w2)
      (delete-window w2)
      (kill-buffer buffer))))

;;; 49. 旋转：两个 rotate 命令都清掉 native-size 缓存

(ert-deftest seshat-reader-resize-test--rotate-clears-native-size ()
  "Rotating a page invalidates the cached native size.

Rotating swaps width and height, so a cached `(PAGE . (W . H))' would be
used unrotated by the next fit and the page would be fitted to the wrong
dimension.  The rotation itself is stubbed; only the invalidation matters."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (rotations nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'page 1)
          (cl-letf* (((symbol-function 'seshat-reader-dyn--rotate-page)
                      (lambda (degrees) (push degrees rotations)))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) nil))
                     ((symbol-function 'seshat-reader--set-page-top-when-joined)
                      (lambda (&optional _window) nil)))
            (set-window-parameter window 'native-size
                                  (cons 1 (cons 200.0 100.0)))
            (with-current-buffer buffer
              (seshat-reader-rotate-clockwise))
            (should-not (window-parameter window 'native-size))
            (set-window-parameter window 'native-size
                                  (cons 1 (cons 100.0 200.0)))
            (with-current-buffer buffer
              (seshat-reader-rotate-counter-clockwise))
            (should-not (window-parameter window 'native-size)))
          (should (equal '(-90 90) rotations)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 50. --handle-window-buffer-change：复用点对 fit 窗口 apply 一次

(ert-deftest seshat-reader-resize-test--window-buffer-change-applies-fit-once ()
  "A surviving overlay makes the buffer change reuse the recentre path.

That path now also adapts the geometry, so a fit window gets one apply and a
new `scale', while a `manual' window keeps its scale and is applied zero
times.  This is the documented reuse point of D8: showing the document in a
new window or frame gives it the right geometry in the first frame."
  (let ((window (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buffer (seshat-reader-resize-test--reader-buffer))
        (applied 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (cl-letf* (((symbol-function 'seshat-reader--fit-scale)
                      (lambda (&optional _window) 1.4))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (target scale)
                        (cl-incf applied)
                        (set-window-parameter target 'scale scale)
                        t))
                     ((symbol-function 'seshat-reader--clamp-window-vscroll)
                      (lambda (&optional _window) nil))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) nil)))
            (with-current-buffer buffer
              (seshat-reader--handle-window-buffer-change window))
            (should (= 1 applied))
            (should (eql 1.4 (window-parameter window 'scale)))
            ;; manual 窗口复用同一条路径，但几何不动。
            (setq applied 0)
            (set-window-parameter window 'scale-source 'manual)
            (set-window-parameter window 'scale 2.0)
            (with-current-buffer buffer
              (seshat-reader--handle-window-buffer-change window))
            (should (= 0 applied))
            (should (eql 2.0 (window-parameter window 'scale)))))
      (set-window-buffer window orig-buffer)
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 51. --apply-display-scale：边界输入静默返回 nil

(ert-deftest seshat-reader-resize-test--apply-display-scale-rejects-bad-scale ()
  "A scale that is not a positive number is ignored without signalling.

nil arises when the fit mode found no native size and 0 or a negative value
from a degenerate window; the spec, the `scale' parameter and the fallback
must all stay untouched instead of raising or writing a nonsensical size."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((spec (seshat-reader-resize-test--set-page-spec window 200 100)))
            (set-window-parameter window 'scale 1.0)
            (dolist (scale (list nil 0 -0.5 'x "1.0"))
              (with-current-buffer buffer
                (should-not (seshat-reader--apply-display-scale window scale))))
            (should (eql 200 (image-property spec :width)))
            (should (eql 100 (image-property spec :height)))
            (should (eql 1.0 (window-parameter window 'scale)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 52. --recenter-window：非拖拽（间隔大于阈值）→ 同步 apply 一次

(ert-deftest seshat-reader-resize-test--recenter-window-applies-when-not-dragging ()
  "A size change far apart from the previous one adapts the geometry synchronously.

`seshat-reader--last-size-change-delta' is 0.5 s here, above
`seshat-reader--drag-threshold': the event is a one-off change (opening the
outline panel), so the page geometry must be adapted in the very frame that
noticed it.  Dropping the drag branch would make this pass by accident, so
the zero call case is pinned by the next test."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied 0))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (with-current-buffer buffer
            (setq seshat-reader--last-size-change-delta 0.5))
          (cl-letf* (((symbol-function 'window-buffer)
                      (lambda (&optional _window) buffer))
                     ((symbol-function 'seshat-reader--fit-scale)
                      (lambda (&optional _window) 1.5))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (_window _scale) (cl-incf applied) t))
                     ((symbol-function 'seshat-reader--clamp-window-vscroll)
                      (lambda (&optional _window) nil))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) nil)))
            (with-current-buffer buffer
              (seshat-reader--recenter-window window)))
          (should (= 1 applied))
          ;; 前提：0.5 确实大于阈值，否则本用例测的是拖拽分支
          (should (< seshat-reader--drag-threshold 0.5)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 53. --recenter-window：拖拽中（间隔小于阈值）→ 零 apply，仍 clamp + center

(ert-deftest seshat-reader-resize-test--recenter-window-skips-apply-while-dragging ()
  "A burst of size changes only recentres, without rescaling the page bitmap.

`seshat-reader--last-size-change-delta' is 0.02 s, below
`seshat-reader--drag-threshold': the events arrive once per frame while the
user drags a window divider.  Rewriting the image spec on every one of them
makes redisplay rescale the whole page bitmap each frame, which is the
1–2 s stall reported on the real machine.  The geometry is therefore left
alone and adapted once by the debounced refit after the drag stops, while
the clamp and the recentre still run because they touch no bitmap."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied 0)
         (clamps 0)
         (centers 0))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (with-current-buffer buffer
            (setq seshat-reader--last-size-change-delta 0.02))
          (cl-letf* (((symbol-function 'window-buffer)
                      (lambda (&optional _window) buffer))
                     ((symbol-function 'seshat-reader--fit-scale)
                      (lambda (&optional _window) 1.5))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (_window _scale) (cl-incf applied) t))
                     ((symbol-function 'seshat-reader--clamp-window-vscroll)
                      (lambda (&optional _window) (cl-incf clamps)))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) (cl-incf centers))))
            (with-current-buffer buffer
              (seshat-reader--recenter-window window)))
          (should (= 0 applied))
          (should (= 1 clamps))
          (should (= 1 centers))
          ;; 前提：0.02 确实小于阈值
          (should (< 0.02 seshat-reader--drag-threshold)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 54. --center-page：只写 prefix/hscroll，不再强制标记窗口重算

(ert-deftest seshat-reader-resize-test--center-page-does-not-force-window-update ()
  "Centring writes the prefix and the hscroll, and forces no window update.

**契约变更（2026-10-23，prerender）**：本用例原先断言
`seshat-reader--center-page' 末尾调用一次 `force-window-update'。实测表明
`force-window-update' 只作用于**下一次** redisplay，无法修正当前帧——窗口变
窄后的第一帧仍带着旧 `line-prefix'（win-w 2016 而 lp 1527，页面右偏 252px）。
该行已删除，改由 `pre-redisplay-functions' 在「即将重显示前」校正（此时窗口
已是新尺寸，本帧即采用新 prefix）。因此本用例改为断言「不再 force」，并同时
钉住 prefix 与 hscroll 仍然写出，防止把整个居中逻辑一起删掉也能通过。

`force-window-update' 被桩替并计数，batch 帧不会被真正标记。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (forced 0)
         (hscrolls nil))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((center-overlay (make-overlay (point-min) (point-min))))
            (unwind-protect
                ;; 契约变更（2026-10-23）：图宽改由 `--page-image-spec' 提供；
                ;; 本用例走「页面比窗口宽」分支，line-prefix/hscroll 契约不变。
                (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                           (lambda (&optional _window)
                             (seshat-reader-resize-test--image-spec 2000 1000)))
                          ((symbol-function 'seshat-reader--ensure-center-overlay)
                           (lambda (&optional _window) center-overlay))
                          ((symbol-function 'seshat-reader--set-window-hscroll)
                           (lambda (_target ncol &optional _unconstrained)
                             (push ncol hscrolls)
                             ncol))
                          ((symbol-function 'set-window-hscroll)
                           (lambda (&rest _) nil))
                          ((symbol-function 'force-window-update)
                           (lambda (&rest _args) (cl-incf forced) nil)))
                  ;; 前提：走的是正常居中分支（页面宽于窗口，偏移夹到 0），
                  ;; 而不是 geometry 未知的 fallback 分支。
                  (should (> 2000 (window-body-width window t)))
                  (seshat-reader--center-page window)
                  (should (= 0 forced))
                  (should (= 1 (length hscrolls)))
                  (should (equal `(space :width (0))
                                 (overlay-get center-overlay 'line-prefix)))
                  (should-not (overlay-get (window-parameter window 'overlay)
                                           'line-prefix)))
              (delete-overlay center-overlay))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 55. --ensure-centered：before-string 缺失（stale）时重排一次居中

(ert-deftest seshat-reader-resize-test--ensure-centered-recalls-center-on-mismatch ()
  "A missing centring `before-string' is rebuilt by calling `--center-page' once.

**契约变更（2026-10-23）**：居中改由 `before-string' +
`(space :align-to (+ center (-0.5 . IMAGE)))' 承担，`--ensure-centered' 不再比较
prefix 宽度与 `window width - page width'，而是用 `--centered-p' 做「before-string
是否引用当前 image spec」的身份比对。页面 overlay 上没有 before-string（= 刚清空
或尚未居中，真机上窗口变窄后即为该状态）时，必须调用一次 `--center-page' 重建。
`pre-redisplay-functions` 在绘制前运行，因此修正落在显示新宽度的第一帧。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (centers 0))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                     (lambda (&optional _window)
                       (seshat-reader-resize-test--image-spec 500 700)))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (cl-incf centers) nil)))
            (with-current-buffer buffer
              (should (seshat-reader--ensure-centered window))))
          (should (= 1 centers)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 56. --ensure-centered：before-string 引用当前 spec 时零调用

(ert-deftest seshat-reader-resize-test--ensure-centered-noop-when-matching ()
  "A `before-string' that references the current image spec is left alone.

**契约变更（2026-10-23）**：稳态判据从「prefix 宽度 == 窗口宽 - 页宽」改为
「before-string 的 `:align-to' 引用的是当前 image spec 同一个对象」。这是稳态：
`pre-redisplay-functions' 每帧都会跑，误判即每帧重写 before-string 与 hscroll。
本用例把真实 spec 挂到页面 overlay 的 `display' 上，再用同一个 spec 对象构造
before-string，`--centered-p' 必须返回 t（`eq' 成立），`--center-page' 零调用。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (centers 0))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let* ((spec (seshat-reader-resize-test--set-page-spec window 500 700))
                 (overlay (window-parameter window 'overlay)))
            (overlay-put overlay 'before-string
                         (propertize " " 'display
                                     (list 'space :align-to
                                           (list '+ 'center (cons -0.5 spec)))))
            (cl-letf (((symbol-function 'window-body-width)
                       ;; **契约变更（2026-10-23，I1）**：`--centered-p' 现在先判
                       ;; 几何：页面比窗口宽时走 `line-prefix' 分支。batch 帧的
                       ;; `window-body-width'(px) 只有 80（`frame-char-width' = 1），
                       ;; 500px 的页面会被判成「超宽」，本用例必须显式给一个放得下的
                       ;; 窗口宽度，才能钉住 `before-string' 的稳态。
                       (lambda (&optional _window _pixels-p) 1200))
                      ((symbol-function 'seshat-reader--center-page)
                       (lambda (&optional _window) (cl-incf centers) nil)))
              (should (seshat-reader--centered-p window))
              (should-not (seshat-reader--ensure-centered window))))
          (should (= 0 centers)))
      (seshat-reader-resize-test--clear-window window)
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

(ert-deftest seshat-reader-resize-test--first-fit-uses-display-scale-when-available ()
  "The first fit rescales the display instead of re-rendering the page.

`seshat-reader--first-fit' is what `seshat-reader-mode' calls when a
document is opened.  Reaching the target scale by re-rendering produces two
frames: the default-size bitmap centred once, then the larger bitmap
centred again -- the \"small then large\" flash.  When the page spec is
already available the display-level rescale reaches the final size in the
very first frame, so `seshat-reader-doc-scale-page' must not run at all;
the crisp bitmap is left to the debounced refit."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (applied 0)
         (applied-scale nil)
         (centers 0)
         (refits 0)
         (renders 0))
    (unwind-protect
        (progn
          (cl-letf* (((symbol-function 'seshat-reader--contain-scale)
                      (lambda (&optional _window) 1.9))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (_window scale)
                        (cl-incf applied)
                        (setq applied-scale scale)
                        t))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) (cl-incf centers) nil))
                     ((symbol-function 'seshat-reader--schedule-refit)
                      (lambda () (cl-incf refits) nil))
                     ((symbol-function 'seshat-reader-doc-scale-page)
                      (lambda (&rest _) (cl-incf renders) nil)))
            (with-current-buffer buffer
              (seshat-reader--first-fit)))
          (should (= 1 applied))
          (should (eql 1.9 applied-scale))
          (should (= 0 renders))
          (should (= 1 centers))
          (should (= 1 refits)))
      (kill-buffer buffer))))

;;; 59. --first-fit：spec 不可用时回退到同步重渲染

(ert-deftest seshat-reader-resize-test--first-fit-falls-back-to-render ()
  "Without a page spec the first fit re-renders synchronously, as before.

`seshat-reader--apply-display-scale' returns nil while the page spec is not
available yet, so the old synchronous path must still run: one apply
attempt, exactly one re-render at the contain scale with `fit' as source,
then the centre.  Dropping the fallback would leave the first frame
unscaled instead of merely flashing."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (applied 0)
         (renders 0)
         (render-args nil)
         (centers 0)
         (refits 0))
    (unwind-protect
        (progn
          (cl-letf* (((symbol-function 'seshat-reader--contain-scale)
                      (lambda (&optional _window) 1.9))
                     ((symbol-function 'seshat-reader--apply-display-scale)
                      (lambda (_window _scale) (cl-incf applied) nil))
                     ((symbol-function 'seshat-reader--center-page)
                      (lambda (&optional _window) (cl-incf centers) nil))
                     ((symbol-function 'seshat-reader--schedule-refit)
                      (lambda () (cl-incf refits) nil))
                     ((symbol-function 'seshat-reader-doc-scale-page)
                      (lambda (factor &optional source)
                        (cl-incf renders)
                        (setq render-args (list factor source))
                        nil)))
            (with-current-buffer buffer
              (seshat-reader--first-fit)))
          (should (= 1 applied))
          (should (= 1 renders))
          (should (equal '(1.9 fit) render-args))
          (should (= 1 centers))
          (should (= 1 refits)))
      (kill-buffer buffer))))

;;; 60. --center-page：能放下时写 before-string（redisplay 自居中）

(ert-deftest seshat-reader-resize-test--center-page-sets-before-string-when-fits ()
  "A page that fits gets a `before-string' referencing the displayed spec.

The `:align-to' form must carry the very image spec object (`eq', not just
`equal'): `(space :align-to (+ center (-0.5 . IMAGE)))' needs an image
object to subtract half of the page width; a bare number is interpreted as
a character width and lands the page far off.  The page overlay keeps no
`line-prefix' and the window hscroll is reset, because the old
line-prefix + hscroll pair was off by −524 px on the first frame after a
window narrowed."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (spec (seshat-reader-resize-test--image-spec 500 700))
         (hscrolls nil))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((overlay (window-parameter window 'overlay)))
            (overlay-put overlay 'line-prefix '(space :width (700)))
            (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                       (lambda (&optional _window) spec))
                      ((symbol-function 'window-body-width)
                       (lambda (&optional _window _pixels-p) 1200))
                      ((symbol-function 'set-window-hscroll)
                       (lambda (&optional w ncol &rest _)
                         (push (list w ncol) hscrolls) 0)))
              (seshat-reader--center-page window)
              (should (= 1 (length hscrolls)))
              (should (eql 0 (nth 1 (car hscrolls))))
              (should-not (overlay-get overlay 'line-prefix))
              (let* ((before (overlay-get overlay 'before-string))
                     (display (and (stringp before)
                                   (get-text-property 0 'display before)))
                     (align (and (consp display)
                                 (plist-get (cdr display) :align-to)))
                     (form (and (consp align) (eq (car align) '+)
                                (nth 2 align))))
                (should (consp display))
                (should (eq (car display) 'space))
                (should (consp form))
                ;; 浮点不能用 `eq' 比较（不同 boxed 对象），用 `eql'
                (should (eql -0.5 (car form)))
                (should (eq (cdr form) spec))))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 61. --center-page：超宽时清 before-string、回到 line-prefix 左对齐

(ert-deftest seshat-reader-resize-test--center-page-clears-before-string-when-too-wide ()
  "A page wider than the window drops the `before-string' and uses the prefix.

Centring a page that does not fit would clip it on both sides, so the page
is left-aligned and scrolled with the width-based `line-prefix' instead.
The `before-string' left over from a previous fits-state must be removed,
otherwise redisplay keeps submitting the page to a centring position that
is negative and therefore clamped."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (spec (seshat-reader-resize-test--image-spec 2000 3000)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let ((overlay (window-parameter window 'overlay)))
            (overlay-put overlay 'before-string
                         (propertize " " 'display
                                     (list 'space :align-to
                                           (list '+ 'center (cons -0.5 spec)))))
            (cl-letf (((symbol-function 'seshat-reader--page-image-spec)
                       (lambda (&optional _window) spec))
                      ((symbol-function 'window-body-width)
                       (lambda (&optional _window _pixels-p) 1200))
                      ((symbol-function 'seshat-reader--set-window-hscroll)
                       (lambda (&optional _w _ncol &rest _) 0)))
              (should (> 2000 1200))
              (seshat-reader--center-page window)
              (should-not (overlay-get overlay 'before-string))
              (should (overlay-get seshat-reader--center-overlay 'line-prefix))
              (should-not (overlay-get overlay 'line-prefix)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 62. --centered-p：before-string 引用旧 spec（equal 但非 eq）→ nil

(ert-deftest seshat-reader-resize-test--centered-p-detects-stale-spec ()
  "A `before-string' referencing a previous spec object is reported as stale.

A re-render replaces the image spec object; the stored `before-string'
keeps pointing at the old one.  `equal' would still hold (the geometry is
identical), so only an identity comparison (`eq') can tell that the frame
would be laid out with the previous page object."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let* ((spec (seshat-reader-resize-test--set-page-spec window 500 700))
                 (old (copy-sequence spec))
                 (overlay (window-parameter window 'overlay)))
            (should (equal old spec))
            (should-not (eq old spec))
            (overlay-put overlay 'before-string
                         (propertize " " 'display
                                     (list 'space :align-to
                                           (list '+ 'center (cons -0.5 old)))))
            (should-not (seshat-reader--centered-p window))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 63. --centered-p：before-string 引用当前 spec → t

(ert-deftest seshat-reader-resize-test--centered-p-true-for-live-spec ()
  "A `before-string' referencing the displayed spec object is live.

This is the steady state after `--center-page' has run: the geometry needs
no further work, so `pre-redisplay-functions' must not rebuild anything.

**契约变更（2026-10-23，I1）**：`--centered-p' 现在先按几何分流——只有
`window-body-width' ≥ 页宽时才检查 `before-string'。batch 帧的像素宽度只有 80
（`frame-char-width' = 1），500px 的页面会被判成超宽，因此这里显式把窗口宽度
桩成 1200，本用例才真正落在 `before-string' 分支上。"
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (let* ((spec (seshat-reader-resize-test--set-page-spec window 500 700))
                 (overlay (window-parameter window 'overlay)))
            (overlay-put overlay 'before-string
                         (propertize " " 'display
                                     (list 'space :align-to
                                           (list '+ 'center (cons -0.5 spec)))))
            (cl-letf (((symbol-function 'window-body-width)
                       (lambda (&optional _window _pixels-p) 1200)))
              (should (eq spec (seshat-reader--page-image-spec window)))
              (should (seshat-reader--centered-p window)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 64. --ensure-centered：stale 时重建一次

(ert-deftest seshat-reader-resize-test--ensure-centered-rebuilds-when-stale ()
  "A stale centring is rebuilt exactly once by `--center-page'.

The check is the identity one provided by `--centered-p'; when it reports
stale (nil), `--ensure-centered' must call `--center-page' once and return
non-nil so `pre-redisplay-functions' callers can tell work was done."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (centers 0))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (cl-letf (((symbol-function 'seshat-reader--centered-p)
                     (lambda (&optional _window) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) (cl-incf centers) nil)))
            (should (seshat-reader--ensure-centered window))
            (should (= 1 centers))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 65. --centered-p：宽页 + 匹配的 line-prefix → t

(ert-deftest seshat-reader-resize-test--centered-p-true-for-wide-page-with-matched-prefix ()
  "A page wider than the window is centred once its `line-prefix' matches.

Wide pages are left-aligned through the buffer-wide centring overlay's
`line-prefix' (`(space :width (LEFTOVER))'), not through a page
`before-string'.  The live value of LEFTOVER is `max 0 (- WINDOW PAGE)',
which is 0 here because the page (2000px) overflows the window (1200px).
Reporting this state as centred is what keeps
`pre-redisplay-functions' from rebuilding the prefix and rewriting hscroll
on every single frame."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (seshat-reader-resize-test--set-page-spec window 2000 3000)
          (let ((center (seshat-reader--ensure-center-overlay)))
            (overlay-put center 'line-prefix '(space :width (0)))
            (cl-letf (((symbol-function 'window-body-width)
                       (lambda (&optional _window _pixels-p) 1200)))
              (should (> 2000 1200))
              (should (seshat-reader--centered-p window)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 66. --centered-p：宽页 + 过期 line-prefix（宽度不等于剩余宽度）→ nil

(ert-deftest seshat-reader-resize-test--centered-p-nil-for-wide-page-with-stale-prefix ()
  "A `line-prefix' width that does not match the geometry is reported as stale.

After a resize (or a re-render at a different scale) the leftover width
changes, so the stored `line-prefix' no longer describes where the page
has to be drawn.  `--centered-p' must then return nil exactly once, so
that `--center-page' rebuilds the prefix for the new geometry."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (seshat-reader-resize-test--set-page-spec window 2000 3000)
          (let ((center (seshat-reader--ensure-center-overlay)))
            (overlay-put center 'line-prefix '(space :width (300)))
            (cl-letf (((symbol-function 'window-body-width)
                       (lambda (&optional _window _pixels-p) 1200)))
              (should (= 300 (car (plist-get
                                   (cdr (overlay-get center 'line-prefix))
                                   :width))))
              (should-not (seshat-reader--centered-p window)))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 67. --ensure-centered：宽页一旦居中即零调用

(ert-deftest seshat-reader-resize-test--ensure-centered-noop-for-wide-page-once-centred ()
  "A wide page whose centring `line-prefix' is live needs no rebuilding.

This is the wide-page steady state: `--centered-p' reports t, so
`--ensure-centered' must not call `--center-page' at all.  Before the
`line-prefix' branch existed the check only knew the `before-string' form,
which a wide page never has, hence every frame redrew the prefix and
rewrote the horizontal scroll."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (centers 0))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (seshat-reader-resize-test--set-page-spec window 2000 3000)
          (let ((center (seshat-reader--ensure-center-overlay)))
            (overlay-put center 'line-prefix '(space :width (0)))
            (cl-letf (((symbol-function 'window-body-width)
                       (lambda (&optional _window _pixels-p) 1200))
                      ((symbol-function 'seshat-reader--center-page)
                       (lambda (&optional _window) (cl-incf centers) nil)))
              (should-not (seshat-reader--ensure-centered window))))
          (should (= 0 centers)))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; seshat-reader-resize-test.el ends here
