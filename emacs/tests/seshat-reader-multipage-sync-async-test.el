;;; seshat-reader-multipage-sync-async-test.el --- Tests for the sync dispatcher  -*- lexical-binding: t; -*-

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

;; 阅读器 P2-B 两阶段渲染 T6 的 ERT 套件：`seshat-reader--multipage-sync' 的
;; 三态分流（在 T5 的调度器之上决定「谁来渲染」）。
;;
;; 覆盖（对应计划 T6 验收 ①–⑧）：
;;
;;   1) 态 A 等价：`seshat-reader-render-async' = nil 时 `--multipage-sync' 的
;;      渲染页序与 `--multipage-sync-blocking' 单独调用完全一致（含末尾的同步
;;      预取页）；
;;   1b) 态 A 同步预取：`--multipage-prefetch' 在 nil 下直接取 spec ⇒ 预取页进
;;      缓存、不插行；pending / timer / 时间戳全空；
;;   1c) 态 B 预取不变：开关为 t 时预取页只进队列，本轮页序不含它；
;;   2) 态 B 视口内同步：point 页 + 滚动方向第一页在 sync 内渲染，其余可见页
;;      只登记 pending（且已按最终尺寸建好占位行）；
;;   3) 态 B 裁剪：登记 [1..10]、可见范围 [4..6] ⇒ 队列只剩范围内的页；
;;   4) 态 B 失败清零：失败 2 次的页重新可见后计数归 0，允许重试；
;;   5) 态 C 超时：pending 存活超过 `seshat-reader-render-async-timeout' ⇒ 本轮
;;      走同步路径、队列清空、两个 timer 被取消；
;;   5b) 态 C 保队（T9，D8 的第二个出口）：强制同步只把**本窗口范围**的页出队，
;;      其它窗口登记的队项仍在，两个 timer 仍然有效、计时起点重置；队列只剩本
;;      窗口的页时仍然全清；态 A 的整队清空语义不变；
;;   6) 开关切换：t → nil → t 反复切换不残留 timer / pending；
;;   7) timer 不泄漏：三个 timer 函数全部桩住，nil 态下 buffer-local 变量为 nil；
;;   8) 全量回归（41 文件 1383 例）由 `make -C emacs/tests ert' 覆盖。
;;
;; 另附两条实现决策的机械守护：
;;
;;   - 占位行的尺寸必须按**目标 scale** 量（两阶段量法，见
;;     `seshat-reader--multipage-placeholder-row'）：超宽页在 contain 模式下
;;     目标 scale 小于 base scale，按 native 尺寸建行会让补位那一刻行高缩水；
;;   - 态 B 的同步页渲染完必须立刻出队，否则 tick 会白跑一遍。
;;
;; 所有 timer 函数（`run-with-idle-timer' / `run-at-time' / `cancel-timer'）与时钟
;; （`float-time'）都在用例内桩住：**不真等 timer、不 sleep**，与
;; `seshat-reader-multipage-async-render-test.el' 的先例一致。
;;
;; 运行方式（在仓库根目录执行，或直接 `make -C emacs/tests ert'）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader \
;;     -l ert -l emacs/tests/seshat-reader-multipage-sync-async-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; batch 的教训（见 `emacs/tests/README.md'）：这里只断言调度与调用序列，
;; 「滚动时的手感 / 空白页是否可见」属 T9 的真机 L3。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)


;;; 夹具

(defvar seshat-reader-sync-async-test--viewport '(1 . 1)
  "Page range the stubbed `window-start'/`window-end' report, as (FIRST . LAST).

`seshat-reader--multipage-visible-range' widens it by
`seshat-reader--multipage-preload', so the observable range is
\(FIRST - preload . LAST + preload) clipped to the document page count.

It is the fallback for every window that has no entry of its own in
`seshat-reader-sync-async-test--viewports', i.e. the single-window case.")

(defvar seshat-reader-sync-async-test--viewports nil
  "Per-window viewports for the stubbed `window-start'/`window-end'.

Each element is (WINDOW . (FIRST-PAGE . LAST-PAGE)); nil -- the default --
makes every window answer from `seshat-reader-sync-async-test--viewport', so
the tests written before the table existed see exactly what they saw then.

It exists for the two-window tests of decision D8: in batch a whole page row is
one text line, so the real `window-end' would give both windows on the same
buffer the same range and a test could not tell a window-level answer from a
buffer-level one.  Same shape as the table of
`seshat-reader-multipage-async-render-test--viewports' (T8), kept local to this
file because every ERT file is loaded in its own Emacs process.")

(defun seshat-reader-sync-async-test--row-start (page)
  "Return the buffer position of the page row of PAGE, or nil."
  (when-let* ((entry (assq page seshat-reader--pages)))
    (marker-position (cadr entry))))

(defun seshat-reader-sync-async-test--viewport-for (window)
  "Return the (FIRST . LAST) viewport the stubs report for WINDOW.

WINDOW's own entry in `seshat-reader-sync-async-test--viewports' wins; a
window without one falls back to
`seshat-reader-sync-async-test--viewport', which is the behaviour every
single-window test relies on."
  (or (cdr (assq window seshat-reader-sync-async-test--viewports))
      seshat-reader-sync-async-test--viewport))

(defun seshat-reader-sync-async-test--fake-spec (page)
  "Return a fake canvas spec of PAGE, 600x800 pixels."
  (list 'image :type 'canvas :data nil
        :data-width 600 :data-height 800
        :width 600 :height 800
        :page page))

(defmacro seshat-reader-sync-async-test--with-buffer (pages &rest body)
  "Create a reader buffer with a row per page in PAGES and run BODY.

The buffer is displayed in the selected window (every geometry lookup of the
layout resolves the window displaying the buffer) and carries the state
`--render-buffer' plus `--first-fit' leave behind: `contain' fit mode, base
scale 1.0, preload 1, scroll direction towards later pages.  The document page
count is the highest page in PAGES.

Four functions are stubbed for BODY, because none of them can be trusted in
batch:

- `window-body-width'/`-height' -- the batch frame is 80x23 **characters**, so
  the real numbers would clip every page; 1000x800 is what a normal GUI frame
  reports;
- `window-start'/`window-end' -- derived from
  `seshat-reader-sync-async-test--viewport' (or from
  `seshat-reader-sync-async-test--viewports' for a window that has an entry
  there), because in batch a whole page row is one text line and the real
  `window-end' would swallow the whole buffer;
- `seshat-reader-dyn--page-size' -- answers the page bounds at the requested
  scale (600x800 at scale 1.0), which is what the native entry point does
  without rendering.  Stubbing the symbol also makes `fboundp' true, so
  `seshat-reader--page-size' runs its real caching path."
  (declare (indent 1) (debug t))
  `(let ((buffer (generate-new-buffer " *seshat-sync-async-test*"))
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
                         seshat-reader--multipage-scroll-direction 1
                         seshat-reader-current-doc-pagecount
                         ;; PAGES 是调用点写的字面量列表（`'(1 2 3)'），宏展开时
                         ;; 原样插入即可（不是在运行时求值）。
                         (apply #'max ,pages))
             (dolist (page ,pages)
               (seshat-reader--multipage-insert-page page nil))
             (goto-char (seshat-reader-sync-async-test--row-start
                         (car ,pages)))
             (cl-letf (((symbol-function 'window-body-width)
                        (lambda (&optional _window _pixels-p) 1000))
                       ((symbol-function 'window-body-height)
                        (lambda (&optional _window _pixels-p) 800))
                       ((symbol-function 'window-start)
                        (lambda (&optional window)
                          (seshat-reader-sync-async-test--row-start
                           (car (seshat-reader-sync-async-test--viewport-for
                                 (or window (selected-window)))))))
                       ((symbol-function 'window-end)
                        (lambda (&optional window _update)
                          (seshat-reader-sync-async-test--row-start
                           (cdr (seshat-reader-sync-async-test--viewport-for
                                 (or window (selected-window)))))))
                       ((symbol-function 'seshat-reader-dyn--page-size)
                        (lambda (_page scale &optional _rotate)
                          (list (round (* 600 (or scale 1.0)))
                                (round (* 800 (or scale 1.0)))))))
               ,@body)))
       (set-window-buffer window original)
       (kill-buffer buffer))))

(defmacro seshat-reader-sync-async-test--with-timer-stubs
    (idle-calls periodic-calls cancel-calls &rest body)
  "Run BODY with the three timer functions stubbed, recording into CALLS.

IDLE-CALLS and PERIODIC-CALLS receive one (KIND SECONDS REPEAT FUNCTION ARGS)
record per arming call and CANCEL-CALLS one entry per `cancel-timer'.  Stubbing
them is what keeps a batch run from leaving a repeating timer behind."
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

(defmacro seshat-reader-sync-async-test--with-renderer (calls &rest body)
  "Run BODY with the native render entry point stubbed, recording into CALLS.

CALLS is bound to the pages that were rendered, in render order.  The stub
returns a recognisable spec, so the row that receives it can be checked."
  (declare (indent 1) (debug t))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'seshat-reader--page-spec)
                (lambda (page &optional _scale _rotate _generation)
                  (setq ,calls (append ,calls (list page)))
                  (seshat-reader-sync-async-test--fake-spec page))))
       ,@body)))

(defmacro seshat-reader-sync-async-test--with-caching-renderer (calls &rest body)
  "Run BODY with a renderer stub that also fills the spec cache.

CALLS is bound to the pages that were rendered, in render order.  Unlike
`--with-renderer', the stub remembers the spec under the key the real entry
point would use, so `seshat-reader--multipage-spec-cached-p' answers t
afterwards -- which is how the synchronous prefetch of state A becomes
observable as \"the page after the resident set is already warm\"."
  (declare (indent 1) (debug t))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'seshat-reader--page-spec)
                (lambda (page &optional scale rotate _generation)
                  (setq ,calls (append ,calls (list page)))
                  (let ((spec (seshat-reader-sync-async-test--fake-spec page)))
                    (seshat-reader--page-spec-remember
                     (seshat-reader--page-spec-key page (or scale 1.0)
                                                   (or rotate 0))
                     spec)
                    spec))))
       ,@body)))

(defmacro seshat-reader-sync-async-test--order (&rest body)
  "Run BODY and return the ordered list of pages `--page-spec' was called for."
  (declare (indent 0) (debug t))
  `(let (order)
     (seshat-reader-sync-async-test--with-renderer calls
       ,@body
       (setq order calls))
     order))


;;; 1) 态 A：与改造前逐字节等价

(ert-deftest seshat-reader-sync-async-test--state-a-equals-blocking ()
  "With `render-async' nil the dispatcher renders what the blocking path renders.

两条独立构造的等价缓冲区，一条走 `--multipage-sync'（开关为 nil），一条直接走
`--multipage-sync-blocking'（同一开关）：渲染页序必须完全一致。这是「回退口逐
字节等价」的机械形式 —— 开关只决定何时渲染，不决定渲染什么、按什么顺序。

文档 7 页、视口 (2 . 4) ⇒ 可见范围 [1..5]、预取页 6（驻留集外沿 +1）：**页序必
须是 (1 2 3 4 5 6)**。T6 首版态 A 丢掉了这一页（收尾清理把队列项扔了），页序是
\(1 2 3 4 5)；若本用例又退回那个页序，说明「态 A 无预取」的偏差复发了。

`--multipage-sync-blocking' 的 docstring 说它是「态 A 的那一半」，但它内部调用的
预取按开关分流 ⇒ 对照支必须同样绑定 nil，否则比较的是「态 A vs 态 C 的同步
pass」（后者在异步模式下只登记预取页，本来就不渲染它）。"
  (let ((async-order nil)
        (blocking-order nil))
    (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
      (setq seshat-reader-sync-async-test--viewport '(2 . 4)
            seshat-reader-current-doc-pagecount 7)
      (seshat-reader-sync-async-test--with-timer-stubs _idle _periodic _cancel
        (goto-char (seshat-reader-sync-async-test--row-start 3))
        (let ((seshat-reader-render-async nil))
          (setq async-order
                (seshat-reader-sync-async-test--order
                  (should (equal '(1 . 5) (seshat-reader--multipage-sync
                                           (selected-window)))))))
        ;; 态 A 不允许留下任何异步残留
        (should-not seshat-reader--multipage-pending-renders)
        (should-not seshat-reader--multipage-async-idle-timer)
        (should-not seshat-reader--multipage-async-render-timer)
        (should-not seshat-reader--multipage-async-pending-since)))
    (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
      (setq seshat-reader-sync-async-test--viewport '(2 . 4)
            seshat-reader-current-doc-pagecount 7)
      (seshat-reader-sync-async-test--with-timer-stubs _i2 _p2 _c2
        (goto-char (seshat-reader-sync-async-test--row-start 3))
        (setq blocking-order
              (seshat-reader-sync-async-test--order
                (let ((seshat-reader-render-async nil))
                  (should (equal '(1 . 5)
                                 (seshat-reader--multipage-sync-blocking
                                  (selected-window)))))))))
    ;; 旧路径 = 区间内逐页、按页序，末尾再同步预取一页
    (should (equal '(1 2 3 4 5 6) blocking-order))
    (should (equal blocking-order async-order))))

(ert-deftest seshat-reader-sync-async-test--state-a-prefetches-next-page ()
  "With `render-async' nil the page beyond the range is warmed synchronously.

态 A 的预取必须**真的预热**：`--multipage-prefetch' 走同步分支，直接取滚动方向
下一页的 spec（于是它进 `--page-spec-cache'），既不登记 pending 也不排 timer。
这是计划不变量③（nil 时逐字节等价）的具体内容 —— 改造前每轮 sync 都多一页提前
量，回退口不能少这一页。

夹具取「视口单页」：可见范围 [2..4]、预取页 5，缓存额度 4（= 2×preload+2）刚好
容得下 3 个驻留 spec + 1 个预取 spec，所以「已进缓存」这条断言不受淘汰策略干扰
\(缓存满时第一个被淘汰的正是非驻留页，见 `--cache-eviction-victim'）。"
  (seshat-reader-sync-async-test--with-buffer '(2 3 4)
    (setq seshat-reader-sync-async-test--viewport '(3 . 3)
          seshat-reader-current-doc-pagecount 7)
    (seshat-reader-sync-async-test--with-timer-stubs idle periodic _cancel
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      (let ((seshat-reader-render-async nil))
        (seshat-reader-sync-async-test--with-caching-renderer calls
          (should (equal '(2 . 4) (seshat-reader--multipage-sync
                                   (selected-window))))
          ;; 区间内逐页 + 末尾的预取页 5
          (should (equal '(2 3 4 5) calls))
          (should (= 1 (cl-count 5 calls)))
          (should (seshat-reader--multipage-spec-cached-p 5))
          ;; 但**没有**插行：预取不改变布局
          (should-not (assq 5 seshat-reader--pages))))
      ;; 零异步残留：无队列、无 timer、无时间戳
      (should-not seshat-reader--multipage-pending-renders)
      (should-not seshat-reader--multipage-pending-generation)
      (should-not seshat-reader--multipage-async-pending-since)
      (should-not seshat-reader--multipage-async-idle-timer)
      (should-not seshat-reader--multipage-async-render-timer)
      (should-not idle)
      (should-not periodic))))

(ert-deftest seshat-reader-sync-async-test--state-b-prefetch-still-queues ()
  "With `render-async' t the prefetch only queues, never renders.

同一份文档布局（7 页、视口 (2 . 4)、可见范围 [1..5]）：开关为 t 时预取页 6 只进
队列（末尾由 `--schedule-async-render' 排 timer），本轮 `--page-spec' 的调用页序
**不含** 6、缓存里也没有它。开关只改变「谁在什么时候渲染」，态 B 的行为不因本
批修复而变。"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4)
          seshat-reader-current-doc-pagecount 7)
    (seshat-reader-sync-async-test--with-timer-stubs idle periodic _cancel
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      (let ((seshat-reader-render-async t))
        (seshat-reader-sync-async-test--with-caching-renderer calls
          (should (equal '(1 . 5) (seshat-reader--multipage-sync
                                   (selected-window))))
          (should (equal '(3 4) calls))
          (should-not (memq 6 calls))
          (should-not (seshat-reader--multipage-spec-cached-p 6))))
      ;; 预取页在队列里（裁剪发生在预取之前，故它没被裁掉）
      (should (equal '(1 2 5 6) seshat-reader--multipage-pending-renders))
      ;; 预取与 sync 各排一次 timer（后者 cancel 前者），故各自两条记录
      (should (length idle))
      (should (= (length idle) (length periodic)))
      (should seshat-reader--multipage-async-idle-timer)
      (should seshat-reader--multipage-async-render-timer))))

(ert-deftest seshat-reader-sync-async-test--dispatcher-keeps-return-value ()
  "All three states return the range that was synchronised.

四类既有调用点（post-command-hook / window state change / 跨页滚动 / zoom-goto）
只读返回值，故三态都必须返回「本次同步的区间」或 nil。
"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4))
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      (let ((seshat-reader-render-async nil))
        (should (equal '(1 . 5) (seshat-reader--multipage-sync
                                 (selected-window)))))
      ;; 区间未变 ⇒ 早退，但仍返回该区间
      (should (equal '(1 . 5) (seshat-reader--multipage-sync (selected-window)))))))


;;; 2) 态 B：视口内同步 + 其余登记

(ert-deftest seshat-reader-sync-async-test--state-b-renders-point-and-direction ()
  "Only the point page and the next page in the scroll direction are rendered.

point 在第 3 页、方向向后 ⇒ 同步渲染 3、4；可见范围 [1..5] 里的 1、2、5 只登记
pending。占位行必须已按最终尺寸建好（600x800），否则滚动范围会跳。"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4))
    (seshat-reader-sync-async-test--with-timer-stubs idle periodic _cancel
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      (let ((order (seshat-reader-sync-async-test--order
                     (seshat-reader--multipage-sync (selected-window)))))
        (should (equal '(3 4) order))
        ;; 视口内这两页真的有像素了
        (should (seshat-reader--multipage-page-spec 3))
        (should (seshat-reader--multipage-page-spec 4))
        ;; 其余可见页只有占位行：登记进队列、行高已是最终值
        (should (equal '(1 2 5) seshat-reader--multipage-pending-renders))
        (dolist (page '(1 2 5))
          (should-not (seshat-reader--multipage-page-spec page))
          (should (= 800 (seshat-reader--multipage-page-pixel-height page))))
        ;; 队列非空 ⇒ idle 首轮 + 周期推进都排上
        (should (= 1 (length idle)))
        (should (= 1 (length periodic)))
        (should seshat-reader--multipage-async-idle-timer)
        (should seshat-reader--multipage-async-render-timer)
        (should seshat-reader--multipage-async-pending-since)
        (should (equal '(1 . 5) seshat-reader--multipage-last-range))))))

(ert-deftest seshat-reader-sync-async-test--state-b-inserts-placeholder-rows ()
  "A queued page without a row gets its row right away, at its final size.

页行是布局的一部分（滚动范围的来源），不能等像素到了才插：异步态下 sync 必须
先把行按尺寸建好，像素后补时只改属性。"
  (seshat-reader-sync-async-test--with-buffer '(3)
    (setq seshat-reader-sync-async-test--viewport '(3 . 3))
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      ;; 可见范围 = (2 . 3)（pagecount = 3）：2 没行，靠 sync 建
      (let ((order (seshat-reader-sync-async-test--order
                     (seshat-reader--multipage-sync (selected-window)))))
        (should (equal '(3) order))
        (should (equal '(2) seshat-reader--multipage-pending-renders))
        (should (assq 2 seshat-reader--pages))
        (should (= 800 (seshat-reader--multipage-page-pixel-height 2)))))))

(ert-deftest seshat-reader-sync-async-test--state-b-renders-backwards ()
  "Scrolling towards earlier pages renders the point page and the one before it."
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4)
          seshat-reader--multipage-scroll-direction -1)
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      (let ((order (seshat-reader-sync-async-test--order
                     (seshat-reader--multipage-sync (selected-window)))))
        (should (equal '(2 3) order))
        (should (equal '(1 4 5) seshat-reader--multipage-pending-renders))))))

(ert-deftest seshat-reader-sync-async-test--state-b-removes-rendered-from-queue ()
  "A page rendered synchronously leaves the queue in the same pass.

多窗口并集（D8）下同一页可能早先被另一窗口登记：本轮同步渲染完就必须出队，
否则 tick 会为它白跑一趟（且队列看起来永远非空，超时兜底会被误触发）。"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4))
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
      (should (seshat-reader--multipage-pending-add 3))
      (should (seshat-reader--multipage-pending-add 4))
      (goto-char (seshat-reader-sync-async-test--row-start 3))
      (seshat-reader-sync-async-test--order
        (seshat-reader--multipage-sync (selected-window)))
      (should-not (memq 3 seshat-reader--multipage-pending-renders))
      (should-not (memq 4 seshat-reader--multipage-pending-renders))
      (should (equal '(1 2 5) seshat-reader--multipage-pending-renders)))))


;;; 3) 态 B：裁剪

(ert-deftest seshat-reader-sync-async-test--state-b-prunes-to-visible-range ()
  "The queue is trimmed to the visible range, so scrolled-away pages never render.

登记 1..10 后把视口移到第 5 页（范围 [4..6]）：队列只剩范围内的第 4 页（5、6
本轮已同步渲染并出队），1、2、3、7、8、9、10 全部被裁掉。"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5 6 7 8 9 10)
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
      (dolist (page '(1 2 3 4 5 6 7 8 9 10))
        (should (seshat-reader--multipage-pending-add page)))
      (should (= 10 (length seshat-reader--multipage-pending-renders)))
      (setq seshat-reader-sync-async-test--viewport '(5 . 5))
      (goto-char (seshat-reader-sync-async-test--row-start 5))
      (let ((order (seshat-reader-sync-async-test--order
                     (seshat-reader--multipage-sync (selected-window)))))
        (should (equal '(5 6) order)))
      ;; 队列只剩范围内的第 4 页 + 预取页 7（`--multipage-prefetch' 在裁剪之后
      ;; 登记驻留集外沿的一页，它不属于「滚过去的页」）。
      (should (equal '(4 7) seshat-reader--multipage-pending-renders)))))


;;; 4) 态 B：失败清零

(ert-deftest seshat-reader-sync-async-test--state-b-clears-failure-on-reentry ()
  "A page that failed twice is retried once it comes back into view.

失败计数有两条清零路径：全量失效（T4）与本轮的「重新进入可见范围」（T6）。后者
是不变量④的落地 —— 纯滚动不推进代际，缺了它暂时性失败会被永久化。

页面走的是生产入口 `--multipage-goto'：先停在第 5 页（范围 [4..6]），让它离开
（跳到第 9 页）后再回来，第 4 页因此重新进入可见范围。"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5 6 7 8 9 10)
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
      ;; 第一站：范围 [4..6]
      (setq seshat-reader-sync-async-test--viewport '(5 . 5))
      (seshat-reader-sync-async-test--order
        (seshat-reader--multipage-goto 5))
      ;; 第 4 页连失败两次
      (seshat-reader--multipage-note-render-failure 4)
      (seshat-reader--multipage-note-render-failure 4)
      (should (= 2 (seshat-reader--multipage-render-failure-count 4)))
      ;; 第二站：范围 [8..10]，第 4 页离开
      (setq seshat-reader-sync-async-test--viewport '(9 . 9))
      (seshat-reader-sync-async-test--order
        (seshat-reader--multipage-goto 9))
      (should (= 2 (seshat-reader--multipage-render-failure-count 4)))
      ;; 回到第一站：第 4 页重新进入 ⇒ 计数清零、允许重试
      (setq seshat-reader-sync-async-test--viewport '(5 . 5))
      (seshat-reader-sync-async-test--order
        (seshat-reader--multipage-goto 5))
      (should (= 0 (seshat-reader--multipage-render-failure-count 4)))
      (should-not (seshat-reader--multipage-render-failed-p 4)))))


;;; 5) 态 C：超时兜底

(ert-deftest seshat-reader-sync-async-test--state-c-timeout-forces-sync ()
  "A queue older than the timeout is rendered synchronously on the next command.

时钟桩住：先跑一轮态 B 让队列有页，再把 `float-time' 推过
`seshat-reader-render-async-timeout'；同一个区间（本来会因「区间未变」早退）必须
走同步路径、队列清空、两个 timer 被取消。
"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4))
    (let ((now 1000.0))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _t) now)))
        (seshat-reader-sync-async-test--with-timer-stubs idle periodic cancelled
          (goto-char (seshat-reader-sync-async-test--row-start 3))
          (let ((seshat-reader-render-async-timeout 1.0))
            ;; 态 B：1、2、5 进队列，两个 timer 排上
            (seshat-reader-sync-async-test--order
              (seshat-reader--multipage-sync (selected-window)))
            (should (equal '(1 2 5) seshat-reader--multipage-pending-renders))
            (should (= 1 (length idle)))
            (should (= 1 (length periodic)))
            ;; 时钟走 0.5s：未超时，区间未变 ⇒ 早退，队列保持
            (setq now 1000.5)
            (seshat-reader-sync-async-test--order
              (seshat-reader--multipage-sync (selected-window)))
            (should (equal '(1 2 5) seshat-reader--multipage-pending-renders))
            ;; 推到 1.5s：超时 ⇒ 本轮强制同步
            (setq now 1001.5)
            (should (seshat-reader--multipage-async-overdue-p))
            (let ((order (seshat-reader-sync-async-test--order
                           (seshat-reader--multipage-sync (selected-window)))))
              ;; 整个范围同步渲染（3、4 已有 spec，不再渲染）
              (should (equal '(1 2 5) order)))
            (dolist (page '(1 2 3 4 5))
              (should (seshat-reader--multipage-page-spec page)))
            ;; 队列空（pagecount = 5，预取页被裁剪）⇒ timer 全取消、时间戳清空
            (should-not seshat-reader--multipage-pending-renders)
            (should-not seshat-reader--multipage-async-pending-since)
            (should-not seshat-reader--multipage-async-idle-timer)
            (should-not seshat-reader--multipage-async-render-timer)
            (should (>= (length cancelled) 2))))))))


;;; 6) 开关切换与 timer 不泄漏

(ert-deftest seshat-reader-sync-async-test--toggle-leaves-nothing-behind ()
  "Switching the option back and forth never leaves a timer or a queue.

三轮 t → nil：打开时「队列非空 ⇔ 两个 timer 都排上」，关掉后队列、代际、
时间戳与两个 timer 变量全部为空。第一轮必须真的登记过（否则本用例什么都没验）。

视口每轮在 (2 . 4) 与 (3 . 4) 之间交替，区间因此每轮都变 ⇒ 每轮都真的干活，
不会因为「区间未变」早退把断言变成空转。文档 7 页 ⇒ 预取页恒为 6（驻留集外沿
+1）。每轮还断言这页的归属随模式切换：t 轮**不**在本轮渲染它（只登记），nil 轮
**当场**渲染它（同步预取）—— 「开关只决定何时渲染」在往返切换下的机械形式。
"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-current-doc-pagecount 7)
    (seshat-reader-sync-async-test--with-timer-stubs _idle _periodic _cancelled
      (let ((first-round-pending nil))
        (dotimes (round 3)
          (setq seshat-reader-sync-async-test--viewport
                (if (cl-evenp round) '(2 . 4) '(3 . 4)))
          (goto-char (seshat-reader-sync-async-test--row-start 3))
          (let ((async-order
                 (seshat-reader-sync-async-test--order
                   (seshat-reader--multipage-sync (selected-window)))))
            ;; 态 B 不渲染预取页
            (should-not (memq 6 async-order)))
          ;; 队列非空 ⇔ 两个 timer 都在（每次打开都自洽）
          (let ((queued (and seshat-reader--multipage-pending-renders t)))
            (should (eq queued (and seshat-reader--multipage-async-idle-timer t)))
            (should (eq queued
                        (and seshat-reader--multipage-async-render-timer t))))
          (when (= round 0)
            (setq first-round-pending seshat-reader--multipage-pending-renders))
          ;; 关掉：预取页当场同步渲染，残留全部清干净
          (let ((seshat-reader-render-async nil))
            (let ((nil-order
                   (seshat-reader-sync-async-test--order
                     (seshat-reader--multipage-sync (selected-window)))))
              (should (memq 6 nil-order))))
          (should-not seshat-reader--multipage-pending-renders)
          (should-not seshat-reader--multipage-pending-generation)
          (should-not seshat-reader--multipage-async-pending-since)
          (should-not seshat-reader--multipage-async-idle-timer)
          (should-not seshat-reader--multipage-async-render-timer))
        (should (equal '(1 2 5 6) first-round-pending))))))


;;; 7) 占位行尺寸按目标 scale 量（两阶段量法的机械守护）

(ert-deftest seshat-reader-sync-async-test--placeholder-uses-target-scale ()
  "An overwide page is reserved at the scale it will be displayed at.

contain 模式下目标 scale = min(base, 宽向 fit)。页宽 1200、窗口 1000、base 1.0
⇒ 目标 0.8333 ⇒ 占位行 1000x667。若直接按 native 尺寸建行，补位那一刻行高会从
800 缩到 667 —— 正是「占位与已渲染同高」不变量要挡住的跳变。
"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3)
    (setq seshat-reader-sync-async-test--viewport '(2 . 2))
    (seshat-reader-sync-async-test--with-timer-stubs _i _p _cancelled
      ;; 覆盖尺寸桩：这一页 native 是 1200x800（比窗口宽）
      (cl-letf (((symbol-function 'seshat-reader-dyn--page-size)
                 (lambda (_page scale &optional _rotate)
                   (list (round (* 1200 (or scale 1.0)))
                         (round (* 800 (or scale 1.0)))))))
        (goto-char (seshat-reader-sync-async-test--row-start 2))
        (seshat-reader-sync-async-test--order
          (seshat-reader--multipage-sync (selected-window)))
        (should (= 667 (seshat-reader--multipage-page-pixel-height 1)))
        (should (= 1000 (seshat-reader--multipage-max-page-width)))))))

;;; T8：态 A 与基线路径的完整几何等价（不变量③的完整形态）

(defun seshat-reader-sync-async-test--geometry ()
  "Return the layout geometry of the current buffer as a plist.

Four views of the same layout, all of them things a user can see move:

- `:lines' -- the buffer extent, i.e. how many lines the layout produced;
- `:markers' -- (PAGE . POSITION) for every page row, in page order;
- `:specs' -- (PAGE WIDTH HEIGHT) from each row's spec, nil dimensions for a
  page that has none;
- `:max-width' -- the horizontal scroll bound (`--multipage-max-page-width');
- `:heights' -- (PAGE . PIXEL-HEIGHT), the vertical extent of every row.

Comparing two of these is what \"byte for byte equivalent\" means at the
observable level: same rows, same positions, same sizes."
  (list :lines (count-lines (point-min) (point-max))
        :markers (mapcar (lambda (entry)
                           (cons (car entry) (marker-position (cadr entry))))
                         seshat-reader--pages)
        :specs (mapcar (lambda (entry)
                         (let ((spec (cddr entry)))
                           (list (car entry)
                                 (and spec (image-property spec :width))
                                 (and spec (image-property spec :height)))))
                       seshat-reader--pages)
        :max-width (seshat-reader--multipage-max-page-width)
        :heights (mapcar (lambda (entry)
                           (cons (car entry)
                                 (seshat-reader--multipage-page-pixel-height
                                  (car entry))))
                         seshat-reader--pages)))

(ert-deftest seshat-reader-sync-async-test--state-a-matches-baseline-geometry ()
  "State A leaves a layout indistinguishable from the blocking baseline.

`--state-a-equals-blocking' 只比了**渲染页序**（谁在什么时候被渲染）；这里是
不变量③的完整形态：两个独立构造的等价缓冲区，一个走态 A（`--multipage-sync'
+ 开关 nil）、一个直接调 `--multipage-sync-blocking'，跑完之后的**布局**必须逐
项相同 —— 行数、每页 marker 位置、每页 spec 的 `:width'/`:height'、水平上限、
每页像素高。

为什么页序相同还不够：态 A 是多绕了一层（清异步状态 → 调 blocking → 再清一次），
这一层若顺手碰了布局（比如额外插了预取行、把 spec resize 了一次），页序完全可
以一模一样而屏幕上的滚动范围已经变了。"
  (let ((async-geometry nil)
        (blocking-geometry nil))
    (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
      (setq seshat-reader-sync-async-test--viewport '(2 . 4)
            seshat-reader-current-doc-pagecount 7)
      (seshat-reader-sync-async-test--with-timer-stubs _i _p _c
        (goto-char (seshat-reader-sync-async-test--row-start 3))
        (seshat-reader-sync-async-test--with-renderer _calls
          (let ((seshat-reader-render-async nil))
            (should (equal '(1 . 5) (seshat-reader--multipage-sync
                                     (selected-window))))
            (setq async-geometry (seshat-reader-sync-async-test--geometry))))))
    (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
      (setq seshat-reader-sync-async-test--viewport '(2 . 4)
            seshat-reader-current-doc-pagecount 7)
      (seshat-reader-sync-async-test--with-timer-stubs _i2 _p2 _c2
        (goto-char (seshat-reader-sync-async-test--row-start 3))
        (seshat-reader-sync-async-test--with-renderer _calls2
          (let ((seshat-reader-render-async nil))
            (should (equal '(1 . 5)
                           (seshat-reader--multipage-sync-blocking
                            (selected-window))))
            (setq blocking-geometry (seshat-reader-sync-async-test--geometry))))))
    ;; 两份快照都拿到了（否则下面的 equal 会在 nil 之间相等，成为假绿）。
    (should blocking-geometry)
    (should async-geometry)
    ;; 逐项断言，失败时能直接看出是哪一项漂了。
    (should (= (plist-get blocking-geometry :lines)
               (plist-get async-geometry :lines)))
    (should (equal (plist-get blocking-geometry :markers)
                   (plist-get async-geometry :markers)))
    (should (equal (plist-get blocking-geometry :specs)
                   (plist-get async-geometry :specs)))
    (should (equal (plist-get blocking-geometry :max-width)
                   (plist-get async-geometry :max-width)))
    (should (equal (plist-get blocking-geometry :heights)
                   (plist-get async-geometry :heights)))
    ;; 整份快照也相等（防止将来往快照里加字段却忘了断言）。
    (should (equal blocking-geometry async-geometry))))

;;; T6 的超时兜底会重新武装 pending 计时（态 C 的第二轮窗口）

(ert-deftest seshat-reader-sync-async-test--state-c-rearms-pending-since ()
  "The forced synchronous pass re-arms the pending timestamp and both timers.

超时兜底（态 C）清空队列后，同步路径的预取**仍会登记一页**（开关为 t 时）。那一
页必须拿到属于它自己的完整超时窗口：`--multipage-async-pending-since' 要重置成
强制同步那一刻的时间（不是保留旧值，也不是留 nil），两个 timer 要重新排上。否则
新登记的那页要么立刻被判超时（每轮命令都全量同步，异步彻底失效），要么永远没有
计时起点（超时兜底对它失效）。

时钟桩 1000.0 → 1001.5 → 1001.6 → 1002.6 四个点：态 B 登记、超时强制同步
\(1.5 s > 1.0 s）、新窗口尚未到期（0.1 s）、从重置点算满 1.0 s 后再次到期。
用独立 buffer 夹具、pagecount 7（预取页 6 因此存在且不在可见范围内），不改动
`--state-c-timeout-forces-sync' 依赖的 pagecount = 5。
"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5)
    (setq seshat-reader-sync-async-test--viewport '(2 . 4)
          seshat-reader-current-doc-pagecount 7)
    (let ((now 1000.0))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _time) now)))
        (seshat-reader-sync-async-test--with-timer-stubs idle periodic cancelled
          (goto-char (seshat-reader-sync-async-test--row-start 3))
          (let ((seshat-reader-render-async-timeout 1.0))
            (seshat-reader-sync-async-test--with-renderer _calls
              ;; 态 B：1、2、5 登记，预取页 6 也登记 ⇒ 计时起点 = 1000.0
              (should (equal '(1 . 5)
                             (seshat-reader--multipage-sync (selected-window))))
              (should (equal '(1 2 5 6)
                             seshat-reader--multipage-pending-renders))
              (should (= 1000.0 seshat-reader--multipage-async-pending-since))
              (should (>= (length idle) 1))
              (should (= (length idle) (length periodic)))
              (let ((idle-before (length idle))
                    (periodic-before (length periodic)))
                ;; 时钟推到 1.5 s：超时 ⇒ 强制同步
                (setq now 1001.5)
                (should (seshat-reader--multipage-async-overdue-p))
                (should (equal '(1 . 5)
                               (seshat-reader--multipage-sync
                                (selected-window))))
                ;; 预取页仍登记，计时起点换成强制同步那一刻（不是旧值 1000.0）
                (should (equal '(6) seshat-reader--multipage-pending-renders))
                (should (= 1001.5 seshat-reader--multipage-async-pending-since))
                (should-not (= 1000.0
                               seshat-reader--multipage-async-pending-since))
                ;; 两个 timer 重新排上（旧的已被强制同步取消）
                (should seshat-reader--multipage-async-idle-timer)
                (should seshat-reader--multipage-async-render-timer)
                (should (> (length idle) idle-before))
                (should (> (length periodic) periodic-before))
                (should (>= (length cancelled) 2)))
              ;; 新窗口刚起步：0.1 s 后当然还没到期
              (setq now 1001.6)
              (should-not (seshat-reader--multipage-async-overdue-p))
              (should (= 1001.5 seshat-reader--multipage-async-pending-since))
              ;; 从重置点算满 1.0 s ⇒ 再次到期（窗口是完整的，不是残值）
              (setq now 1002.6)
              (should (seshat-reader--multipage-async-overdue-p)))))))))

;;; T9：态 C 的清空路径（D8 的第二个出口）

(ert-deftest seshat-reader-sync-async-test--state-c-keeps-other-windows-pending ()
  "The forced synchronous pass drops its own range only, not another window's pages.

决策 D8 说队列是 **buffer 级并集**（每个显示本 buffer 的窗口各贡献一份），而态 C
（超时兜底）是 **窗口级** 操作：它只同步渲染调用窗口的可见范围。修前它调
`--multipage-clear-async-state' 整队清空，于是另一个窗口登记的页失去唯一的驱动
源 —— 它的占位页永远不会补上像素（用户真机实测：双窗口时另一窗口「跟背景色一
样」且不再恢复）。本用例是那个缺陷的机械形式。

夹具：文档 8 页、preload 1；窗口 A 视口 (4 . 5) ⇒ 范围 (3 . 6)；窗口 B 视口
\(5 . 6) ⇒ 范围 (4 . 7)。队列里先放三页：8（B 的范围之内、A 的范围之外，且不是
A 的预取页 7 —— 否则修前也会被预取重新登记，用例就分不出对错）、3 与 5（A 自己
的可见页，模拟「另一窗口登记过的同一页」）。时钟推过 timeout ⇒ A 这一轮走态 C。

期望：3/4/5/6 同步渲染并**全部出队**；8 仍在队列；A 的预取页 7 照旧入队（预取页
是本轮**新增**的，不属于「已渲染」）；两个 timer 仍有效；计时起点重置到强制同步
那一刻（1001.5，不是旧的 1000.0），否则存活队项会立刻再次超时、每轮命令都全量
同步。"
  (seshat-reader-sync-async-test--with-buffer (number-sequence 1 8)
    (setq seshat-reader-current-doc-pagecount 8)
    (let* ((win-a (selected-window))
           (win-b (split-window win-a)))
      (unwind-protect
          (let ((seshat-reader-sync-async-test--viewports
                 (list (cons win-a '(4 . 5))
                       (cons win-b '(5 . 6))))
                (now 1000.0))
            (cl-letf (((symbol-function 'float-time)
                       (lambda (&optional _time) now)))
              (seshat-reader-sync-async-test--with-timer-stubs
                  idle periodic _cancelled
                (let ((seshat-reader-render-async-timeout 1.0))
                  (goto-char (seshat-reader-sync-async-test--row-start 5))
                  (should (seshat-reader--multipage-pending-add 8))
                  (should (seshat-reader--multipage-pending-add 3))
                  (should (seshat-reader--multipage-pending-add 5))
                  (should (= 1000.0
                             seshat-reader--multipage-async-pending-since))
                  (setq now 1001.5)
                  (should (seshat-reader--multipage-async-overdue-p))
                  (seshat-reader-sync-async-test--with-renderer calls
                    (should (equal '(3 . 6)
                                   (seshat-reader--multipage-sync win-a)))
                    ;; 整个范围同步渲染（3、5 虽在队列里，像素现在已到位）
                    (should (equal '(3 4 5 6) calls)))
                  ;; 另一窗口的队项仍在（修前被整队清空丢掉）
                  (should (memq 8 seshat-reader--multipage-pending-renders))
                  ;; 本窗口已同步渲染的页全部出队
                  (dolist (page '(3 4 5 6))
                    (should-not (memq page
                                      seshat-reader--multipage-pending-renders)))
                  ;; 队列 = B 的 8 + 本轮同步预取的 7（预取页不是「已渲染」）
                  (should (equal '(8 7)
                                 seshat-reader--multipage-pending-renders))
                  ;; 队列非空 ⇒ 两个 timer 继续有效，计时起点重置
                  (should seshat-reader--multipage-async-idle-timer)
                  (should seshat-reader--multipage-async-render-timer)
                  (should (= 1001.5
                             seshat-reader--multipage-async-pending-since))
                  (should (>= (length idle) 1))
                  (should (= (length idle) (length periodic)))))))
        (delete-window win-b)))))

(ert-deftest seshat-reader-sync-async-test--state-c-clears-queue-when-empty ()
  "An empty queue after the forced pass still takes the whole asynchronous state.

态 C 的「全清」只该发生在**出队之后队列为空**时：那时没有东西可驱动，队列、
两个 timer 与时间戳一起走。这条是防回归 —— 保队不能变成「队列永不清空」。

夹具：文档 6 页、视口 (4 . 5) ⇒ 范围 (3 . 6)；预取页按 pagecount 裁剪回 6，而 6
已在驻留集里 ⇒ 预取不登记任何页。队列里只有本窗口的 3、5，出队后为空。"
  (seshat-reader-sync-async-test--with-buffer '(1 2 3 4 5 6)
    (setq seshat-reader-sync-async-test--viewport '(4 . 5)
          seshat-reader-current-doc-pagecount 6)
    (let ((now 1000.0))
      (cl-letf (((symbol-function 'float-time)
                 (lambda (&optional _time) now)))
        (seshat-reader-sync-async-test--with-timer-stubs
            _idle _periodic cancelled
          (let ((seshat-reader-render-async-timeout 1.0))
            (should (seshat-reader--multipage-pending-add 3))
            (should (seshat-reader--multipage-pending-add 5))
            ;; 先真的把两个 timer 排上（否则「取消」断言是空转：没有 timer 可取消）
            (should (equal '(3 5)
                           (seshat-reader--schedule-async-render
                            (current-buffer))))
            (should seshat-reader--multipage-async-idle-timer)
            (should seshat-reader--multipage-async-render-timer)
            (setq now 1001.5)
            (should (seshat-reader--multipage-async-overdue-p))
            (should (equal '(3 . 6)
                           (seshat-reader--multipage-sync (selected-window))))
            (should-not seshat-reader--multipage-pending-renders)
            (should-not seshat-reader--multipage-pending-generation)
            (should-not seshat-reader--multipage-async-pending-since)
            (should-not seshat-reader--multipage-async-idle-timer)
            (should-not seshat-reader--multipage-async-render-timer)
            (should (>= (length cancelled) 2))))))))

(ert-deftest seshat-reader-sync-async-test--state-a-still-clears-everything ()
  "State A keeps wiping the whole queue, including another window's pages.

态 A（`seshat-reader-render-async' = nil）不用队列：所有可见页由
`--multipage-sync-blocking' 同步渲染，所以整队清空仍然是对的 —— 本批只改态 C 的
清空路径，不许把态 A 一起改成「按范围出队」（那样每次切开关都会留下一队没人驱动
的队项）。

夹具与 `--state-c-keeps-other-windows-pending' 相同：窗口 B 的页 7 与窗口 A 的
页 3 都在队列里，走一轮态 A 之后队列必须整体为空。"
  (seshat-reader-sync-async-test--with-buffer (number-sequence 1 8)
    (setq seshat-reader-current-doc-pagecount 8)
    (let* ((win-a (selected-window))
           (win-b (split-window win-a)))
      (unwind-protect
          (let ((seshat-reader-sync-async-test--viewports
                 (list (cons win-a '(4 . 5))
                       (cons win-b '(5 . 6)))))
            (seshat-reader-sync-async-test--with-timer-stubs
                _idle _periodic _cancelled
              (goto-char (seshat-reader-sync-async-test--row-start 5))
              (should (seshat-reader--multipage-pending-add 7))
              (should (seshat-reader--multipage-pending-add 3))
              (should seshat-reader--multipage-async-pending-since)
              (let ((seshat-reader-render-async nil))
                (should (equal '(3 . 6)
                               (seshat-reader--multipage-sync win-a))))
              (should-not seshat-reader--multipage-pending-renders)
              (should-not seshat-reader--multipage-pending-generation)
              (should-not seshat-reader--multipage-async-pending-since)
              (should-not seshat-reader--multipage-async-idle-timer)
              (should-not seshat-reader--multipage-async-render-timer)))
        (delete-window win-b)))))

(provide 'seshat-reader-multipage-sync-async-test)

;;; seshat-reader-multipage-sync-async-test.el ends here
