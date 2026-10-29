;;; seshat-reader-multipage-async-render-test.el --- Tests for the async render pass  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))

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

;; 阅读器 P2-B「两阶段渲染」T5 的 ERT 测试套件：异步渲染调度器
;; （`seshat-reader--schedule-async-render' / `--async-render-tick'）。
;;
;; 本层要钉的是**调度与写回的时序契约**，不是像素：谁登记、谁推进、什么时机
;; 丢弃、失败几次放弃。三个 timer 函数一律桩住（`run-with-idle-timer' /
;; `run-at-time' / `cancel-timer'），捕获回调后手动 funcall 驱动 —— **不真等
;; timer**，与 `seshat-reader-fit-window-test.el'、
;; `seshat-reader-select-flash-test.el' 的既有先例一致。
;;
;; 覆盖（对应计划 T5 验收 ①–⑧）：
;;
;;   1) 登记 → tick → 补位 → pending 清空，两个 timer 都被 cancel；
;;   2) 代际变化后不渲染、不写缓存、不补位，pending 被清；
;;   3) 每轮上限：pending 5 页 × batch 2 ⇒ 一次 tick 只渲染 2 页；
;;   4) 失败 3 次后该页移出 pending，第 4 次不再尝试（计数不再增）；
;;   5) 重新可见时 `--multipage-reset-render-failure' 清零后能重试；
;;   6) idle timer 的 REPEAT 为 nil，且 tick 内部不再重挂 idle timer（G3b 的
;;      机械守护）；周期 timer 的 REPEAT 非 nil（唯一驱动源）；
;;   7) buffer 已 kill：tick 不报错，周期 timer 的闭包自取消；
;;   8) 防重入：tick 期间再次 tick 直接返回，不重复渲染。
;;
;; 另附三条结构性断言：`--multipage-pending-add' 的去重与「已有 spec 不登记」、
;; `--multipage-prune-pending' 的裁剪语义、`--multipage-prefetch' 只登记不渲染。
;;
;; 运行方式（在仓库根目录执行，或直接 `make -C emacs/tests ert'）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader \
;;     -l ert -l emacs/tests/seshat-reader-multipage-async-render-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; batch 的教训（见 `emacs/tests/README.md'）：这里只断言调度与写回，
;; 「滚动时的手感 / 空白页是否可见」属 T9 的真机 L3。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)


;;; 夹具

(defun seshat-reader-multipage-async-test--spec (page &optional width height)
  "Return a fake canvas spec for PAGE, WIDTH x HEIGHT pixels.

The spec has the shape the native module returns, i.e. `:width'/`:height' at
the requested scale plus the canvas buffer size, which is all the layout and
the memory estimate read."
  (let ((w (or width 600))
        (h (or height 800)))
    (list 'image :type 'canvas :data nil
          :data-width w :data-height h
          :width w :height h
          :page page)))

(defvar seshat-reader-multipage-async-test--viewports nil
  "Per-window viewports used by the stubbed `window-start'/`window-end'.

Each element is (WINDOW . (FIRST-PAGE . LAST-PAGE)): the row of FIRST-PAGE is
what `window-start' answers for WINDOW, the row of LAST-PAGE what
`window-end' answers.  nil -- the default -- leaves both functions alone (the
stubs delegate to the real ones), so every test that does not bind this
variable sees exactly the batch behaviour it saw before the stub existed.

It exists for the two-window tests: without a per-window viewport both windows
on the same buffer would report the same visible range in batch (the real
`window-end' cannot be trusted there, a whole page row being one text line),
and the union test of decision D8 could not tell a union from an
intersection.")

(defun seshat-reader-multipage-async-test--row-start (page)
  "Return the buffer position of the row of PAGE, or nil when it has none."
  (when-let* ((entry (assq page seshat-reader--pages)))
    (marker-position (cadr entry))))

(defmacro seshat-reader-multipage-async-test--with-body (pages width height &rest body)
  "Create a reader buffer holding one row per page in PAGES and run BODY.

The buffer is registered in the selected window, because every geometry
lookup of the layout resolves the window displaying the buffer; the batch
frame is 80x23 **characters**, so `window-body-width'/`-height' are stubbed to
WIDTH x HEIGHT pixels, which is what a normal GUI frame would report.

`window-start'/`window-end' are stubbed too, but they only redirect to the
viewport table `seshat-reader-multipage-async-test--viewports' -- when that
table has no entry for the window they call the real functions, i.e. the
default behaviour is the one before the stub was introduced.

The rows are bare placeholders (no spec): that is the state T3 created, i.e.
the state a queued page is in while its pixels do not exist yet."
  (declare (indent 3) (debug t))
  `(let ((buffer (generate-new-buffer " *seshat-reader-async-test*"))
         (window (selected-window))
         (original (window-buffer (selected-window)))
         (real-window-start (symbol-function 'window-start))
         (real-window-end (symbol-function 'window-end)))
     (unwind-protect
         (progn
           (set-window-buffer window buffer)
           (with-current-buffer buffer
             (setq major-mode 'seshat-reader-mode
                   mode-name "Seshat Reader")
             (setq-local seshat-reader--multipage-base-scale 1.0
                         seshat-reader--multipage-fit-mode 'contain
                         seshat-reader--multipage-preload 1
                         seshat-reader-current-doc-pagecount 10)
             (dolist (page (or ,pages '(2)))
               (seshat-reader--multipage-insert-page page nil))
             (cl-letf (((symbol-function 'window-body-width)
                        (lambda (&optional _window _pixels-p) ,width))
                       ((symbol-function 'window-body-height)
                        (lambda (&optional _window _pixels-p) ,height))
                       ((symbol-function 'window-start)
                        (lambda (&optional window)
                          (let* ((win (or window (selected-window)))
                                 (cell (assq win
                                             seshat-reader-multipage-async-test--viewports)))
                            (if cell
                                (seshat-reader-multipage-async-test--row-start
                                 (car (cdr cell)))
                              (funcall real-window-start win)))))
                       ((symbol-function 'window-end)
                        (lambda (&optional window update)
                          (let* ((win (or window (selected-window)))
                                 (cell (assq win
                                             seshat-reader-multipage-async-test--viewports)))
                            (if cell
                                (seshat-reader-multipage-async-test--row-start
                                 (cdr (cdr cell)))
                              (funcall real-window-end win update))))))
               ,@body)))
       (set-window-buffer window original)
       (kill-buffer buffer))))

(defmacro seshat-reader-multipage-async-test--with-timer-stubs
    (idle-calls periodic-calls cancel-calls &rest body)
  "Run BODY with the three timer functions stubbed into three variables.

IDLE-CALLS receives one (idle SECONDS REPEAT FUNCTION ARGS) record per
`run-with-idle-timer' call, PERIODIC-CALLS the same shape per `run-at-time'
call, and CANCEL-CALLS the timer object handed to `cancel-timer'.  The stubs
return a plain list instead of a timer object, which is why the cancellation
helper of the implementation tests the variable and not `timerp'."
  (declare (indent 3) (debug t))
  `(let ((,idle-calls nil) (,periodic-calls nil) (,cancel-calls nil))
     (cl-letf (((symbol-function 'run-with-idle-timer)
                (lambda (seconds repeat function &rest args)
                  (let ((timer (list 'idle seconds repeat function args)))
                    (push timer ,idle-calls)
                    timer)))
               ((symbol-function 'run-at-time)
                (lambda (seconds repeat function &rest args)
                  (let ((timer (list 'periodic seconds repeat function args)))
                    (push timer ,periodic-calls)
                    timer)))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (push timer ,cancel-calls) nil)))
       ,@body)))

(defun seshat-reader-multipage-async-test--fire (timer)
  "Run the callback captured in TIMER, the way the timer system would.

TIMER is one record of the `--with-timer-stubs' shape, i.e.
\(KIND SECONDS REPEAT FUNCTION ARGS); FUNCTION is called with ARGS."
  (apply (nth 3 timer) (nth 4 timer)))

(defmacro seshat-reader-multipage-async-test--with-renderer
    (calls &rest body)
  "Run BODY with the native render entry point stubbed, counting into CALLS.

CALLS is the name of a variable bound to a one-element list holding the number
of render requests; the renderer returns a spec of the page it was asked for,
so the value the pass writes back is recognisable.  A render can be made to
fail by setting the variable to nil inside BODY."
  (declare (indent 1) (debug t))
  `(let ((,calls (list 0)))
     (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                (lambda (page _scale _rotate)
                  (setcar ,calls (1+ (car ,calls)))
                  (seshat-reader-multipage-async-test--spec page))))
       ,@body)))

(defun seshat-reader-multipage-async-test--row-image (page)
  "Return the `display' property of the image placeholder of PAGE."
  (when-let* ((entry (assq page seshat-reader--pages))
              (marker (cadr entry))
              (start (marker-position marker)))
    (get-text-property (1+ start) 'display)))


;;; 1) 登记 → tick → 补位 → pending 清空

(ert-deftest seshat-reader-multipage-async-test--tick-fills-row-and-empties-queue ()
  "一次 tick 把登记的页渲染完、补进占位行并清空队列（验收 ①）。

断言四件事：页表的 spec 被写入、行的 `display' 属性变成该 spec（补位只改
属性）、队列空、两个 timer 都被 cancel —— `cancel' 是队列空之后的收尾，
留下周期 timer 会让空闲的 reader 一直空转。"
  (seshat-reader-multipage-async-test--with-body '(1 2) 1000 800
    (seshat-reader-multipage-async-test--with-timer-stubs
        idle periodic cancelled
      (seshat-reader-multipage-async-test--with-renderer calls
        (should (seshat-reader--multipage-pending-add 2))
        (should (equal '(2) (seshat-reader--schedule-async-render
                             (current-buffer))))
        (should (= 1 (length idle)))
        (should (= 1 (length periodic)))
        ;; 补位前是占位态：页表没有 spec，行上也没有 image。
        (should-not (seshat-reader--multipage-page-spec 2))
        (seshat-reader-multipage-async-test--fire (car idle))
        (let ((spec (seshat-reader--multipage-page-spec 2)))
          (should spec)
          ;; 行显示的就是页表里那一个对象（补位没有复制 spec）。
          (should (eq spec (seshat-reader-multipage-async-test--row-image 2))))
        (should (= 1 (car calls)))
        (should-not seshat-reader--multipage-pending-renders)
        (should-not seshat-reader--multipage-pending-generation)
        ;; 两个 timer 都被取消：先 idle 后周期。
        (should (= 2 (length cancelled)))
        (should (eq (car (nth 0 idle)) 'idle))
        (should-not seshat-reader--multipage-async-idle-timer)
        (should-not seshat-reader--multipage-async-render-timer)))))


;;; 2) 代际变化后不补位

(ert-deftest seshat-reader-multipage-async-test--generation-change-drops-batch ()
  "登记后发生全量失效 ⇒ tick 不渲染、不写缓存、不补位，队列被清（验收 ②）。

这是决策 D4 在调度器里的落点：几何换了，在途的那批结果属于旧几何，一条都不
许写。注意断言「连渲染都没有发生」（计数 0）—— 丢弃发生在渲染之前，而不是
渲染后再判断，省掉一次主线程上的无用渲染。"
  (seshat-reader-multipage-async-test--with-body '(1 2) 1000 800
    (seshat-reader-multipage-async-test--with-timer-stubs
        idle _periodic _cancelled
      (seshat-reader-multipage-async-test--with-renderer calls
        (should (seshat-reader--multipage-pending-add 2))
        (should seshat-reader--multipage-pending-generation)
        (seshat-reader--schedule-async-render (current-buffer))
        ;; 缩放 / 切暗色 / 重载 / relayout 都走这一个入口。
        (seshat-reader--page-spec-clear-cache)
        (seshat-reader-multipage-async-test--fire (car idle))
        (should (= 0 (car calls)))
        (should-not seshat-reader--page-spec-cache)
        (should-not seshat-reader--multipage-page-sizes)
        (should-not (seshat-reader--multipage-page-spec 2))
        (should-not (seshat-reader-multipage-async-test--row-image 2))
        (should-not seshat-reader--multipage-pending-renders)))))


;;; 3) 每轮上限

(ert-deftest seshat-reader-multipage-async-test--tick-renders-one-batch ()
  "pending 5 页、batch 2 ⇒ 一次 tick 只渲染 2 页（验收 ③）。

上限的意义在主线程：一轮渲染整队等于把多次短停顿合并成一次长停顿。"
  (seshat-reader-multipage-async-test--with-body '(1 2 3 4 5) 1000 800
    (seshat-reader-multipage-async-test--with-renderer calls
      (let ((seshat-reader-render-idle-batch 2))
        (dolist (page '(1 2 3 4 5))
          (should (seshat-reader--multipage-pending-add page)))
        (should (= 5 (length seshat-reader--multipage-pending-renders)))
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 2 (car calls)))
        ;; 先登记的先渲染：剩下的是 3 4 5。
        (should (equal '(3 4 5) seshat-reader--multipage-pending-renders))
        ;; 再推一轮又是 2 页，队列剩 1。
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 4 (car calls)))
        (should (equal '(5) seshat-reader--multipage-pending-renders))))))

(ert-deftest seshat-reader-multipage-async-test--batch-default-is-two ()
  "默认 batch 为 2（本批新增的 defcustom）。"
  (should (= 2 seshat-reader-render-idle-batch))
  (should (= 0.05 seshat-reader-render-idle-delay)))


;;; 4) 失败 3 次后停止

(ert-deftest seshat-reader-multipage-async-test--gives-up-after-three-failures ()
  "渲染恒返回 nil ⇒ 3 次后该页不再被登记，第 4 次 tick 也不再尝试（验收 ④）。

不变量④的机械形式：失败计数到 3 就放弃（本次会话内不再尝试），而不是每次都
在滚动路径上再试一遍。"
  (seshat-reader-multipage-async-test--with-body '(1 2) 1000 800
    (let ((calls (list 0)))
      (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                 (lambda (&rest _args)
                   (setcar calls (1+ (car calls)))
                   nil)))
        (dotimes (_i 3)
          (should (seshat-reader--multipage-pending-add 2))
          (seshat-reader--async-render-tick (current-buffer))
          (should-not seshat-reader--multipage-pending-renders))
        (should (= 3 (car calls)))
        (should (= 3 (seshat-reader--multipage-render-failure-count 2)))
        (should (seshat-reader--multipage-render-failed-p 2))
        ;; 第 4 次：入口直接拒绝登记，tick 无事可做。
        (should-not (seshat-reader--multipage-pending-add 2))
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 3 (car calls)))
        ;; 该页始终没有 spec，也没有补位。
        (should-not (seshat-reader--multipage-page-spec 2))))))

(ert-deftest seshat-reader-multipage-async-test--success-clears-failure-count ()
  "成功的渲染把该页的失败计数清零（计数只描述连续失败）。"
  (seshat-reader-multipage-async-test--with-body '(2) 1000 800
    (let ((renderer (list nil)))
      (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                 (lambda (page _scale _rotate)
                   (if (car renderer)
                       (seshat-reader-multipage-async-test--spec page)
                     nil))))
        (should (seshat-reader--multipage-pending-add 2))
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 1 (seshat-reader--multipage-render-failure-count 2)))
        ;; 桩恢复后再来一轮（先清计数，模拟页面重新可见）。
        (seshat-reader--multipage-reset-render-failure 2)
        (setcar renderer t)
        (should (seshat-reader--multipage-pending-add 2))
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 0 (seshat-reader--multipage-render-failure-count 2)))
        (should (seshat-reader--multipage-page-spec 2))))))


;;; 5) 重新可见时清零后重试

(ert-deftest seshat-reader-multipage-async-test--reset-failure-lets-page-retry ()
  "失败 2 次后清零，再登记会重新尝试并成功（验收 ⑤）。"
  (seshat-reader-multipage-async-test--with-body '(2) 1000 800
    (let ((fail-p t)
          (calls 0))
      (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                 (lambda (page _scale _rotate)
                   (setq calls (1+ calls))
                   (unless fail-p
                     (seshat-reader-multipage-async-test--spec page)))))
        (dotimes (_i 2)
          (should (seshat-reader--multipage-pending-add 2))
          (seshat-reader--async-render-tick (current-buffer)))
        (should (= 2 (seshat-reader--multipage-render-failure-count 2)))
        ;; 页面重新进入可见范围（T6 在 sync 里对每个可见页调用）。
        (seshat-reader--multipage-reset-render-failure 2)
        (should (= 0 (seshat-reader--multipage-render-failure-count 2)))
        (setq fail-p nil)
        (should (seshat-reader--multipage-pending-add 2))
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 3 calls))
        (should (seshat-reader--multipage-page-spec 2))))))


;;; 6) idle 只消费一次（G3b 的机械守护）

(ert-deftest seshat-reader-multipage-async-test--idle-timer-fires-once ()
  "idle timer 的 REPEAT 是 nil，且 tick 内部不再重挂 idle timer（验收 ⑥）。

批次 0 的探针 G3b 实测：daemon 下一个 idle 窗口只 fire 一次，回调自续不会让
它重复触发。因此「队列推进」若写成「idle 回调重挂自己」会在真机上永远停在第一
轮 —— 本断言就是那条实测结果的机械守护。周期 timer 则必须是真的重复 timer
\(REPEAT 非 nil），它是唯一驱动源。"
  (seshat-reader-multipage-async-test--with-body '(1 2) 1000 800
    (seshat-reader-multipage-async-test--with-timer-stubs
        idle periodic _cancelled
      (seshat-reader-multipage-async-test--with-renderer _calls
        (should (seshat-reader--multipage-pending-add 1))
        (should (seshat-reader--multipage-pending-add 2))
        (seshat-reader--schedule-async-render (current-buffer))
        (should (= 1 (length idle)))
        (should (= 1 (length periodic)))
        (let ((idle-record (car idle))
              (periodic-record (car periodic)))
          ;; idle：REPEAT 必须 nil（一次性）。
          (should (equal 'idle (nth 0 idle-record)))
          (should (= seshat-reader-render-idle-delay (nth 1 idle-record)))
          (should-not (nth 2 idle-record))
          ;; 周期：REPEAT 必须非 nil，且等于周期推进间隔。
          (should (equal 'periodic (nth 0 periodic-record)))
          (should (= seshat-reader-render-idle-delay (nth 1 periodic-record)))
          (should (= seshat-reader-render-idle-delay (nth 2 periodic-record)))
          ;; 两轮 tick：idle 回调与周期回调各驱动一次，期间不得新排 idle。
          (seshat-reader-multipage-async-test--fire idle-record)
          (should (= 1 (length idle)))
          (seshat-reader-multipage-async-test--fire periodic-record)
          (should (= 1 (length idle)))
          (should (= 1 (length periodic)))
          (should-not seshat-reader--multipage-pending-renders))))))


;;; 7) buffer 已 kill

(ert-deftest seshat-reader-multipage-async-test--dead-buffer-is-harmless ()
  "对已 kill 的 buffer 调 tick 不报错；周期 timer 的闭包自取消（验收 ⑦）。

buffer 被 kill 之后没有人能再读它的 buffer-local 变量，所以周期 timer 只能由
自己的闭包取消 —— 否则会留下一个永远空转、每次 fire 都报错的 timer。"
  (let ((buffer (generate-new-buffer " *seshat-reader-dead*"))
        (periodic nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local seshat-reader--pages nil)
            (should (seshat-reader--multipage-pending-add 3))
            (seshat-reader-multipage-async-test--with-timer-stubs
                _idle periodic-calls cancelled
              (seshat-reader--schedule-async-render buffer)
              (setq periodic (car periodic-calls))))
          (kill-buffer buffer)
          (should-not (buffer-live-p buffer))
          ;; 直接调用：无错、无返回值。
          (should-not (seshat-reader--async-render-tick buffer))
          ;; 周期回调被驱动：闭包自己取消自己。
          (let ((cancelled nil))
            (cl-letf (((symbol-function 'cancel-timer)
                       (lambda (timer) (push timer cancelled) nil)))
              (seshat-reader-multipage-async-test--fire periodic)
              (should (equal (list periodic) cancelled)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))


;;; 8) 防重入

(ert-deftest seshat-reader-multipage-async-test--tick-is-not-reentrant ()
  "tick 期间再次调用 tick 直接返回，不重复渲染（验收 ⑧）。

渲染会写文本属性，可以经 window-state-change 路径回到 post-command，再回到
调度器；没有这道闸门就会同页渲染两次、两次写回交错。"
  (seshat-reader-multipage-async-test--with-body '(2) 1000 800
    (let ((calls 0))
      (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                 (lambda (page _scale _rotate)
                   (setq calls (1+ calls))
                   ;; 渲染过程中重入一次（真实路径下由写属性触发）。
                   (seshat-reader--async-render-tick (current-buffer))
                   (should seshat-reader--multipage-async-rendering)
                   (seshat-reader-multipage-async-test--spec page))))
        (should (seshat-reader--multipage-pending-add 2))
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 1 calls))
        ;; 闸门退出后复位（不是永久锁死）。
        (should-not seshat-reader--multipage-async-rendering)))))


;;; 结构性断言：登记去重、prune、prefetch
(ert-deftest seshat-reader-multipage-async-test--pending-add-dedupes ()
  "同一页重复登记只入队一次；已有 spec 的页不再登记。"
  (seshat-reader-multipage-async-test--with-body '(1 2 3) 1000 800
    (should (seshat-reader--multipage-pending-add 1))
    (should-not (seshat-reader--multipage-pending-add 1))
    (should (equal '(1) seshat-reader--multipage-pending-renders))
    ;; 页 2 先渲染出 spec（缓存里有），于是不再登记。
    (should (seshat-reader--page-spec-remember
             (seshat-reader--page-spec-key 2 1.0 0) 'warm))
    (should-not (seshat-reader--multipage-pending-add 2))
    ;; 页 3 没有行也没有 spec：正常登记。
    (should (seshat-reader--multipage-pending-add 3))
    (should (equal '(1 3) seshat-reader--multipage-pending-renders))
    ;; 移除与清空。
    (seshat-reader--multipage-pending-remove 1)
    (should (equal '(3) seshat-reader--multipage-pending-renders))
    (seshat-reader--multipage-pending-clear)
    (should-not seshat-reader--multipage-pending-renders)
    (should-not seshat-reader--multipage-pending-generation)))

(ert-deftest seshat-reader-multipage-async-test--prune-pending-keeps-visible ()
  "`--multipage-prune-pending' 只保留给定页集合中的条目，顺序不变。

nil 参数**不动队列**（T8 起的语义）：nil 表示「没有任何窗口报出页范围」，不是
「没有可见页」；在它上面清队会把仍然有效的队列工作丢掉。生产调用点的实参是
`--multipage-all-visible-pages' 的并集，只要有一个窗口有范围就不会是 nil。"
  (seshat-reader-multipage-async-test--with-body '(1 2 3 4) 1000 800
    (dolist (page '(1 2 3 4))
      (should (seshat-reader--multipage-pending-add page)))
    (should (equal '(3 4) (seshat-reader--multipage-prune-pending '(4 3 9))))
    ;; 代际随队列一起保留（队列非空时不重置）。
    (should seshat-reader--multipage-pending-generation)
    ;; nil = 「没有窗口报范围」⇒ 队列原样保留（不是清空）。
    (should (equal '(3 4) (seshat-reader--multipage-prune-pending nil)))
    (should seshat-reader--multipage-pending-generation)
    ;; 真的全裁掉（传入一个不含任何队项的集合）后，队列与代际都为空。
    (should-not (seshat-reader--multipage-prune-pending '(9)))
    (should-not seshat-reader--multipage-pending-generation)))

(ert-deftest seshat-reader-multipage-async-test--prefetch-queues-instead-of-rendering ()
  "`--multipage-prefetch' 只登记 + 排 timer，不再同步渲染（开关为 t）。

开关为 t 时预取是队列式的；开关为 nil 的同步分支由
`seshat-reader-multipage-sync-async-test.el' 覆盖。这里显式绑定开关，用例不依赖
defcustom 的默认值。"
  (seshat-reader-multipage-async-test--with-body '(2 3 4) 1000 800
    (setq-local seshat-reader--multipage-scroll-direction 1)
    (seshat-reader-multipage-async-test--with-timer-stubs
        idle periodic _cancelled
      (seshat-reader-multipage-async-test--with-renderer calls
        (should (equal 5 (let ((seshat-reader-render-async t))
                           (seshat-reader--multipage-prefetch
                            (selected-window)))))
        ;; 零渲染、零缓存、零新行：滚动这一步不付像素成本。
        (should (= 0 (car calls)))
        (should-not seshat-reader--page-spec-cache)
        (should-not (assq 5 seshat-reader--pages))
        (should (equal '(5) seshat-reader--multipage-pending-renders))
        (should (= 1 (length idle)))
        (should (= 1 (length periodic)))
        ;; 下一轮 tick 才真正取像素，且只有缓存、不插行。
        (seshat-reader-multipage-async-test--fire (car idle))
        (should (= 1 (car calls)))
        (should (seshat-reader--multipage-spec-cached-p 5))
        (should-not (assq 5 seshat-reader--pages))))))

;;; D8 修复：pending 是 buffer 内全部窗口可见页的并集（T8）

(ert-deftest seshat-reader-multipage-async-test--pending-union-across-two-windows ()
  "两个窗口各自滚动时，对方的待渲染队列项不被剪掉（D8 的机械形式）。

队列 `--multipage-pending-renders' 是 buffer-local 的，两个窗口共用一份；裁剪
`--multipage-prune-pending' 的实参因此必须是
`--multipage-all-visible-pages'（所有显示本 buffer 的窗口的可见页并集），而不是
调用窗口自己的可见页 —— 后者会把另一个窗口刚登记的页剪掉，于是两个相距较远的
窗口会互相删除对方的空白页。

夹具：文档 12 页、preload 1、滚动方向向前（-1，即朝更小的页号）。
窗口 A 视口 (4 . 5) ⇒ 范围 (3 . 6)；窗口 B 视口 (5 . 6) ⇒ 范围 (4 . 7)；
并集 3..7。两轮的预取页都朝前（A 取 2、B 取 3），不会把并集之外的页补回来，
所以下面的断言不会被预取掩盖。

第一轮（A，point 在 5）：同步渲染 5、4，登记 3、6，预取 2 ⇒ 队列 (3 6 2)。
第二轮（B，point 在 6）：同步渲染 6、5，登记 7，预取 3 ⇒ 队列 (3 2 7) 里 2 不在
并集内被裁掉 ⇒ (3 7)。**3 是 A 的队项且落在 B 的范围 (4..7) 之外** —— 按交集
裁剪的实现会在这里把它删掉。
第三轮（A，point 在 5）：同步渲染 5、4（已有 spec，不再取像素），登记 3（队列
里已有），预取 2 ⇒ 队列 (3 7 2)。**7 是 B 的队项且落在 A 的范围 (3..6) 之外**
—— 交集实现同样会删掉它。"
  (seshat-reader-multipage-async-test--with-body (number-sequence 1 12) 1000 800
    (setq seshat-reader-current-doc-pagecount 12
          seshat-reader--multipage-scroll-direction -1)
    (let* ((win-a (selected-window))
           (win-b (split-window win-a)))
      (unwind-protect
          (seshat-reader-multipage-async-test--with-timer-stubs
              _idle _periodic _cancelled
            (let ((seshat-reader-multipage-async-test--viewports
                   (list (cons win-a '(4 . 5))
                         (cons win-b '(5 . 6)))))
              ;; 并集本身：两个窗口的范围都算进去。
              (should (equal '(3 4 5 6 7)
                             (seshat-reader--multipage-all-visible-pages win-a)))
              (should (equal '(3 4 5 6 7)
                             (seshat-reader--multipage-all-visible-pages win-b)))
              (seshat-reader-multipage-async-test--with-renderer _calls
                ;; 第一轮：窗口 A
                (goto-char (seshat-reader-multipage-async-test--row-start 5))
                (should (equal '(3 . 6)
                               (seshat-reader--multipage-sync win-a)))
                (should (equal '(3 6 2)
                               seshat-reader--multipage-pending-renders))
                ;; 第二轮：窗口 B
                (goto-char (seshat-reader-multipage-async-test--row-start 6))
                (should (equal '(4 . 7)
                               (seshat-reader--multipage-sync win-b)))
                (should (equal '(3 7)
                               seshat-reader--multipage-pending-renders))
                ;; 第三轮：窗口 A 单独再跑一次
                (goto-char (seshat-reader-multipage-async-test--row-start 5))
                (should (equal '(3 . 6)
                               (seshat-reader--multipage-sync win-a)))
                ;; B 的队项 7 仍在（A 的范围 3..6 之外，靠并集保住）。
                (should (memq 7 seshat-reader--multipage-pending-renders))
                (should (memq 3 seshat-reader--multipage-pending-renders))
                (should (equal '(3 7 2)
                               seshat-reader--multipage-pending-renders)))))
        (delete-window win-b)))))

(ert-deftest seshat-reader-multipage-async-test--all-visible-pages-walks-every-frame ()
  "并集遍历 `frame-list' 的**每一个** frame，而不是只看选中 frame 的窗口。

batch 造不出第二个真实 frame，所以把 `frame-list' / `frame-live-p' /
`window-list' 三个函数桩住：`frame-list' 答 (frame-a frame-dead frame-b)，
`window-list' 按 frame 答窗口 —— **无参调用只答 frame-a 的窗口**，正是「只遍历
选中 frame」的旧实现会拿到的结果。窗口本身是真的（`split-window' 造出来），
`window-buffer' 也走真函数，所以「显示本 buffer」这条过滤不是桩。

两个窗口视口不同（3..4 与 6..7，preload 1 ⇒ 范围 2..5 与 5..8）：
新实现遍历 frame-list ⇒ 并集 2..8，含 frame-b 那个窗口贡献的 6/7/8；
旧实现（无参 `window-list'）⇒ 只有 2..5，本用例失败。已死的 frame 必须在
`window-list' 之前被 `frame-live-p' 挡掉（对它调用会 signal）。"
  (seshat-reader-multipage-async-test--with-body (number-sequence 1 10) 1000 800
    (let* ((win-a (selected-window))
           (win-b (split-window win-a))
           (asked nil))
      (unwind-protect
          (let ((seshat-reader-multipage-async-test--viewports
                 (list (cons win-a '(3 . 4))
                       (cons win-b '(6 . 7)))))
            (cl-letf (((symbol-function 'frame-list)
                       (lambda (&optional _frame)
                         '(frame-a frame-dead frame-b)))
                      ((symbol-function 'frame-live-p)
                       (lambda (frame)
                         (and (memq frame '(frame-a frame-b)) t)))
                      ((symbol-function 'window-list)
                       (lambda (&optional frame _minibuf _window)
                         (push frame asked)
                         (cond ((eq frame 'frame-a) (list win-a))
                               ((eq frame 'frame-b) (list win-b))
                               ;; 无参 = 只看选中 frame 的窗口（旧实现的路径）。
                               ((null frame) (list win-a))
                               (t (error "window-list on dead frame"))))))
              (should (equal '(2 3 4 5 6 7 8)
                             (seshat-reader--multipage-all-visible-pages win-a)))
              ;; 真的走到了 frame-b，而不是只看选中 frame 的窗口。
              (should (memq 'frame-b asked))
              ;; 已死 frame 被挡在 `window-list' 之前。
              (should-not (memq 'frame-dead asked))
              ;; 一次无参调用都没有（那正是旧实现的做法）。
              (should-not (memq nil asked))))
        (delete-window win-b)))))

;;; D7：队列中的页不占 spec 缓存（部分排空的角度）

(ert-deftest seshat-reader-multipage-async-test--queued-pages-stay-out-of-spec-cache ()
  "登记的页在轮到自己之前不进 `--page-spec-cache'（D7 的部分排空角度）。

batch = 1、登记 3 页、跑**一轮** tick：缓存里只有刚渲染的那 1 条，另两页既不在
缓存里、也还在队列里。这挡的是「先把整队渲染再统一写缓存」的实现 —— 它会让
pending 页在一瞬间把缓存挤满（P0 实测顺序扫 20 页命中率 0），而本设计的前提是
队列中的页零缓存占用。"
  (seshat-reader-multipage-async-test--with-body '(1 2 3) 1000 800
    (let ((seshat-reader-render-idle-batch 1))
      (seshat-reader-multipage-async-test--with-renderer calls
        (dolist (page '(1 2 3))
          (should (seshat-reader--multipage-pending-add page)))
        ;; 登记那一刻：零渲染、零缓存。
        (should (= 0 (car calls)))
        (should-not seshat-reader--page-spec-cache)
        (seshat-reader--async-render-tick (current-buffer))
        (should (= 1 (car calls)))
        ;; 缓存里只有刚渲染的第 1 页。
        (should (= 1 (length seshat-reader--page-spec-cache)))
        (should (equal '(1) (mapcar (lambda (entry) (car (car entry)))
                                    seshat-reader--page-spec-cache)))
        (should (seshat-reader--multipage-spec-cached-p 1))
        ;; 另两页：不在缓存、仍在队列（部分排空，不是「渲染完再写」）。
        (dolist (page '(2 3))
          (should-not (seshat-reader--multipage-spec-cached-p page))
          (should (memq page seshat-reader--multipage-pending-renders)))
        (should (equal '(2 3) seshat-reader--multipage-pending-renders))))))

;;; 不变量②的 tick 版本：补位只改属性，不动 marker 与文本

(ert-deftest seshat-reader-multipage-async-test--tick-fill-moves-no-marker ()
  "tick 补位不改任何页 marker 位置、不改 buffer 文本，页高也不变（不变量②）。

`insert-page' 层的断言已由占位行用例覆盖（`--tick-fills-row-and-empties-queue'
只比 spec 身份）；这里覆盖 tick 内更长的路径 —— 补位之后还有
`--multipage-resize-spec' 与 `--multipage-set-page-centered' 两步。滚动范围由
marker 位置与页高共同决定，所以两样都必须逐字节不变：marker 一动、页高一变，
补位那一刻用户就能看到跳动。

尺寸桩让占位行在 fixture 里就有 600x800 的确定高度（否则页高恒为 0，「不变」
失去意义）：先按尺寸重建两条占位行，再让 tick 补其中一页。"
  (seshat-reader-multipage-async-test--with-body '(1 2) 1000 800
    (cl-letf (((symbol-function 'seshat-reader-dyn--page-size)
               (lambda (_page scale &optional _rotate)
                 (list (round (* 600 (or scale 1.0)))
                       (round (* 800 (or scale 1.0)))))))
      ;; 占位行按测得的尺寸建好：两条都是 (space :width (600) :height (800))。
      (dolist (page '(1 2))
        (seshat-reader--multipage-placeholder-row page nil))
      (should (= 800 (seshat-reader--multipage-page-pixel-height 1)))
      (should (= 800 (seshat-reader--multipage-page-pixel-height 2)))
      (let ((text-before (buffer-substring-no-properties (point-min) (point-max)))
            (markers-before (mapcar (lambda (entry)
                                      (cons (car entry)
                                            (marker-position (cadr entry))))
                                    seshat-reader--pages)))
        (should (equal '(1 2) (mapcar #'car markers-before)))
        (seshat-reader-multipage-async-test--with-timer-stubs
            _idle _periodic _cancelled
          (seshat-reader-multipage-async-test--with-renderer calls
            (should (seshat-reader--multipage-pending-add 1))
            (seshat-reader--async-render-tick (current-buffer))
            (should (= 1 (car calls)))
            ;; 目标行拿到的是真 spec（不再占位）。
            (should (eq (seshat-reader--multipage-page-spec 1)
                        (seshat-reader-multipage-async-test--row-image 1)))
            ;; 另一页仍是占位：`display' 还是 space 规格。
            (should (eq 'space (car (seshat-reader-multipage-async-test--row-image 2))))
            ;; marker 位置逐条不变，文本逐字节不变。
            (should (equal markers-before
                           (mapcar (lambda (entry)
                                     (cons (car entry)
                                           (marker-position (cadr entry))))
                                   seshat-reader--pages)))
            (should (equal text-before
                           (buffer-substring-no-properties (point-min) (point-max))))
            ;; 页高不变（补位前后同高，滚动范围因此不跳）。
            (should (= 800 (seshat-reader--multipage-page-pixel-height 1)))
            (should (= 800 (seshat-reader--multipage-page-pixel-height 2)))))))))

;;; D4/T5：渲染期间代际变化 = 作废，不是失败

(ert-deftest seshat-reader-multipage-async-test--generation-move-during-render-is-not-a-failure ()
  "渲染过程中代际变化导致的 nil 不算失败：不计数、不清队以外的恢复、不补位。

`--page-spec' 在代际已变时不缓存并返回 nil（`--page-spec-remember' 的守卫），
`--async-render-batch' 必须把这种 nil 与「渲染器坏了」区分开：前者是几何作废
\(缩放 / 切暗色 / 重载），后者要计入失败计数、3 次后放弃。判错的后果是「用户缩
放一次就把页面记成失败」，或「作废的批次被当成成功继续补位到旧几何上」。
对应实现里的 invalidated 分支，本用例是它的唯一覆盖。

渲染桩在返回 nil 之前先清一次缓存 —— 这正是 flush 型失效的真实顺序。"
  (seshat-reader-multipage-async-test--with-body '(1 2) 1000 800
    (seshat-reader-multipage-async-test--with-timer-stubs
        idle _periodic cancelled
      (let ((calls 0)
            (generation-before seshat-reader--multipage-render-generation))
        (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                   (lambda (&rest _args)
                     (setq calls (1+ calls))
                     ;; 渲染途中几何被作废（缩放 / 切暗色 / 重载）。
                     (seshat-reader--page-spec-clear-cache)
                     nil)))
          (should (seshat-reader--multipage-pending-add 1))
          (should (seshat-reader--multipage-pending-add 2))
          (seshat-reader--schedule-async-render (current-buffer))
          (seshat-reader-multipage-async-test--fire (car idle))
          (should (= 1 calls))
          ;; 代际确实推进了（失效入口）。
          (should (= (1+ generation-before)
                     seshat-reader--multipage-render-generation))
          ;; 不是失败：计数为 0、未进「放弃」名单。
          (should (= 0 (seshat-reader--multipage-render-failure-count 1)))
          (should-not (seshat-reader--multipage-render-failed-p 1))
          (should-not seshat-reader--multipage-render-failures)
          ;; 整批被丢弃：队列与代际都清空，不补位、不入缓存。
          (should-not seshat-reader--multipage-pending-renders)
          (should-not seshat-reader--multipage-pending-generation)
          (should-not seshat-reader--page-spec-cache)
          (should-not (seshat-reader--multipage-page-spec 1))
          (should-not (seshat-reader-multipage-async-test--row-image 1))
          ;; 队列空了 ⇒ 两个 timer 都被取消。
          (should-not seshat-reader--multipage-async-idle-timer)
          (should-not seshat-reader--multipage-async-render-timer)
          (should (>= (length cancelled) 2)))))))

;;; T6 落地的两个 defcustom 的默认值

(ert-deftest seshat-reader-multipage-async-test--custom-defaults ()
  "T6 落地的两个开关的默认值：异步开启、超时 1.0 秒。

`--batch-default-is-two' 覆盖的是 T5 的 `render-idle-delay'/`render-idle-batch'；
这两个是 T6 的。默认值本身是产品决策（`render-async' = t 即「默认先空白后清
晰」），改动它必须是有意的，不能随着某次重构漂移。"
  (should (eq t seshat-reader-render-async))
  (should (equal 1.0 seshat-reader-render-async-timeout)))

(provide 'seshat-reader-multipage-async-render-test)

;;; seshat-reader-multipage-async-render-test.el ends here
