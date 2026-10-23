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
;; refit 的 fit/manual/未设置三分支、fit 分支的 1% 偏差闸（目标 scale 与当前
;; 几乎相同则不重渲染）、`--refitting' 防重入、四级守卫（死窗口 / 异 buffer /
;; 模式已退出 / overlay 失效）、vscroll 夹紧四态、`scale-source' 语义、
;; presentation-mode 不回归、多窗口各处理一次、死 buffer 的生命周期。
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
  (dolist (parameter '(overlay scale scale-source))
    (set-window-parameter window parameter nil)))

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
  "A `manual' window keeps its scale and only gets clamped and recentred.

The apply stub writes `scale' and `scale-source'; if the manual branch were
removed, both would change and the counts would become (1 1 1)."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'manual)
          (set-window-parameter window 'scale 2.25)
          (should (equal '(0 1 1)
                         (seshat-reader-resize-test--refit-counts buffer window)))
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
  "`presentation-mode' records `fit' as the scale source and keeps refitting.

Only the dynamic module entry points are stubbed, so the recorded `fit'
really comes from `seshat-reader-fit-to-height' passing it to
`seshat-reader-doc-scale-page'.  The subsequent refit must take the fit
branch and rescale through `seshat-reader--contain-scale'."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-resize-test--set-page-overlay window buffer nil)
          (set-window-parameter window 'scale 1.0)
          (let ((center 0)
                (fit 0))
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
              (should (eql 0.5 (window-parameter window 'scale)))
              (should (= 1 center))
              ;; 关闭前再 refit 一次：来源是 fit，必须走 contain 分支。
              ;; 桩返回 0.6 而当前 scale 是 0.5（相差 20% > 1%）：若桩原样返回
              ;; 0.5，偏差闸会跳过重渲染，本用例就不再检验「真的重渲染」。
              (cl-letf* (((symbol-function 'window-buffer)
                          (lambda (&optional _window) buffer))
                         ((symbol-function 'seshat-reader--contain-scale)
                          (lambda (&optional _window) (cl-incf fit) 0.6))
                         ((symbol-function 'seshat-reader--clamp-window-vscroll)
                          (lambda (&optional _window) nil)))
                (seshat-reader--refit-window window))
              (should (= 1 fit))
              (should (eql 0.6 (window-parameter window 'scale)))
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
            (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
                       (lambda (&optional _window) (cons 2000 1000)))
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

;;; 20. 偏差闸：目标 scale 与当前一致 → 不重渲染，但仍夹紧+居中

(ert-deftest seshat-reader-resize-test--refit-fit-skip-when-scale-unchanged ()
  "A fit window whose target scale equals the current one is not re-rendered.

Re-rendering is synchronous (the C side waits for the cached page) and the
re-render changes `line-prefix' and vscroll, which can be reported back as
another size change; the 1% deviation gate breaks that loop.  Clamping and
recentring still run, so the counts are (0 1 1) and the `scale' window
parameter keeps its 1.6 value.  Without the gate the counts would be
\(1 1 1) and `scale' would be written even though nothing changed."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window)))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 1.6)
          (should (equal '(0 1 1)
                         (seshat-reader-resize-test--refit-counts
                          buffer window :scale 1.6)))
          (should (eql 1.6 (window-parameter window 'scale)))
          (should (eq 'fit (window-parameter window 'scale-source))))
      (seshat-reader-resize-test--clear-window window)
      (kill-buffer buffer))))

;;; 21. 偏差闸：目标 scale 相差超过 1% → 重渲染，参数为目标值与 'fit

(ert-deftest seshat-reader-resize-test--refit-fit-applies-when-scale-differs ()
  "A target scale 12.5% away from the current one is applied once, as a fit.

The recorded call pins both the value and the source: applying the current
scale instead of the contain scale, or dropping the `fit' source, makes the
assertion fail.  The threshold itself is 1% of the current scale (0.016
here), so 1.8 is far outside it."
  (let* ((buffer (seshat-reader-resize-test--reader-buffer))
         (window (selected-window))
         (applied nil))
    (unwind-protect
        (progn
          (seshat-reader-resize-test--set-page-overlay window buffer 'fit)
          (set-window-parameter window 'scale 1.6)
          (cl-letf (((symbol-function 'window-buffer)
                     (lambda (&optional _window) buffer))
                    ((symbol-function 'seshat-reader--contain-scale)
                     (lambda (&optional _window) 1.8))
                    ((symbol-function 'seshat-reader-doc-scale-page)
                     (lambda (factor &optional source)
                       (push (cons factor source) applied)))
                    ((symbol-function 'seshat-reader--clamp-window-vscroll)
                     (lambda (&optional _window) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&optional _window) nil)))
            (with-current-buffer buffer
              (seshat-reader--refit-window window)))
          (should (equal '((1.8 . fit)) applied)))
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

(provide 'seshat-reader-resize-test)

;;; seshat-reader-resize-test.el ends here
