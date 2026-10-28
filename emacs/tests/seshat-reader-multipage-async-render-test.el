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

(defmacro seshat-reader-multipage-async-test--with-body (pages width height &rest body)
  "Create a reader buffer holding one row per page in PAGES and run BODY.

The buffer is registered in the selected window, because every geometry
lookup of the layout resolves the window displaying the buffer; the batch
frame is 80x23 **characters**, so `window-body-width'/`-height' are stubbed to
WIDTH x HEIGHT pixels, which is what a normal GUI frame would report.

The rows are bare placeholders (no spec): that is the state T3 created, i.e.
the state a queued page is in while its pixels do not exist yet."
  (declare (indent 3) (debug t))
  `(let ((buffer (generate-new-buffer " *seshat-reader-async-test*"))
         (window (selected-window))
         (original (window-buffer (selected-window))))
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
                        (lambda (&optional _window _pixels-p) ,height)))
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
  "`--multipage-prune-pending' 只保留给定页集合中的条目，顺序不变。"
  (seshat-reader-multipage-async-test--with-body '(1 2 3 4) 1000 800
    (dolist (page '(1 2 3 4))
      (should (seshat-reader--multipage-pending-add page)))
    (should (equal '(3 4) (seshat-reader--multipage-prune-pending '(4 3 9))))
    ;; 代际随队列一起保留（队列非空时不重置）。
    (should seshat-reader--multipage-pending-generation)
    ;; 全部裁掉后队列与代际都为空。
    (should-not (seshat-reader--multipage-prune-pending nil))
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

(provide 'seshat-reader-multipage-async-render-test)

;;; seshat-reader-multipage-async-render-test.el ends here
