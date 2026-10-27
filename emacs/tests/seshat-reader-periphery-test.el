;;; seshat-reader-periphery-test.el --- Tests for the T8 periphery adaptation  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026  Tushar

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

;; P1 批次 7（T8）的 ERT 套件：把**外围模块**从单页 overlay 语义迁到多页语义
;; 之后的行为断言，全部围绕「页号从哪来、页内偏移怎么记、装饰怎么刷新」：
;;
;;   · 选区：`seshat-reader-select-posn-page' 按 posn 落在哪一页行反查页号，
;;     跨页拖选按页取文（P2-A T2 起不再 `user-error'），同页拖选行为不变，
;;     拖拽不动选中窗口/window-start。
;;   · 书签/saveplace：page + offset（页内像素偏移）+ hscroll + scale +
;;     fit-mode 的保存与恢复，以及旧记录 `vscroll' → `offset' 的迁移。
;;   · 搜索/引用跳转：落在页首（vscroll 归 0），页号取视口顶页。
;;   · 装饰刷新：`seshat-reader--multipage-refresh-decorations' 逐驻留页重渲染
;;     （装饰烘在位图里），非驻留页不动，且不再调用
;;     `--refresh-highlights'（单页 overlay 已不存在）。
;;
;; 纪律：不触网、不碰真实文档、不触 GUI；动态模块入口与窗口访问函数一律
;; `cl-letf' 桩替；`skipped' 必须恒为 0，故不用 `skip-unless'。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
(require 'seshat-reader-select)
(require 'seshat-reader-bookmark)
(require 'seshat-reader-saveplace)
(require 'seshat-reader-search)
(require 'seshat-reader-reference)

;;;; 夹具

(defun seshat-reader-periphery-test--reader-buffer (&optional pages width height)
  "Create a reader buffer holding one page row per page in PAGES.
Each row displays a fake image spec of WIDTH x HEIGHT (600x800 by default) and
records the matching native size at scale 1.0, the state a first render leaves
behind.  Returns the buffer."
  (let ((buffer (generate-new-buffer " *seshat-reader-periphery-test*")))
    (with-current-buffer buffer
      (setq major-mode 'seshat-reader-mode
            mode-name "Seshat Reader")
      (setq-local seshat-reader--multipage-base-scale 1.0
                  seshat-reader--multipage-fit-mode 'contain
                  seshat-reader--recent-scale-fallback 1.0)
      (use-local-map seshat-reader-mode-map)
      (dolist (page (or pages '(1 2 3)))
        (let ((spec (list 'image :type 'pbm :data "x"
                          :width (or width 600) :height (or height 800))))
          (seshat-reader--multipage-insert-page page spec)
          (seshat-reader--multipage-record-native page spec 1.0))))
    buffer))

(defun seshat-reader-periphery-test--row-start (page)
  "Return the first buffer position of the row of PAGE."
  (when-let* ((entry (assq page seshat-reader--pages))
              (marker (cadr entry)))
    (marker-position marker)))

(defmacro seshat-reader-periphery-test--with-window-buffer (buffer &rest body)
  "Display BUFFER in the selected window while BODY runs."
  (declare (indent 1) (debug t))
  `(let ((window (selected-window))
         (original (window-buffer (selected-window))))
     (unwind-protect
         (progn (set-window-buffer window ,buffer) ,@body)
       (set-window-buffer window original))))

(defun seshat-reader-periphery-test--load-select-source ()
  "Reload `seshat-reader-select' from source so `posn-*' stubs take effect.
`posn-window'/`posn-object'/`posn-object-x-y'/`posn-point' 在 Emacs 31 里可内联，
`.elc' 已把调用内联进 `seshat-reader-select-posn->page'，`cl-letf' 拦不住；改载
同源的 `.el' 即恢复运行时查找（语义不变）。"
  (let* ((elc (symbol-file 'seshat-reader-select-posn->page 'defun))
         (el (and elc (concat (file-name-sans-extension elc) ".el"))))
    (when (and el (file-exists-p el))
      (load el nil t t))))

(defun seshat-reader-periphery-test--fake-posn (window point &optional xy)
  "Return a fake position list for WINDOW at buffer POINT.
XY is the image pixel offset (`posn-object-x-y'), (10 . 20) by default."
  (list window 5 point (cons 0 0) 100
        (list 'image :type 'pbm :data "x")
        (cons 0 0)
        (or xy (cons 10 20))))

(defmacro seshat-reader-periphery-test--with-posn-stubs (window &rest body)
  "Run BODY with the `posn-*' accessors answering for WINDOW.
`posn-window' returns WINDOW, `posn-point' the buffer position stored in the
third element of the fake position list, `posn-object' a page image and
`posn-object-x-y' the pixel offset in its eighth element."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'posn-window) (lambda (_posn) ,window))
             ((symbol-function 'posn-point) (lambda (posn) (nth 2 posn)))
             ((symbol-function 'posn-object) (lambda (posn) (nth 5 posn)))
             ((symbol-function 'posn-object-x-y) (lambda (posn) (nth 7 posn)))
             ((symbol-function 'frame-scale-factor) (lambda (&optional _f) 1.0)))
     ,@body))

;;;; 1. 选区：页号反查

(ert-deftest seshat-reader-periphery-test--posn-page-reverse-lookup ()
  "The page of a click is the row it landed on, not the top of the viewport.

`seshat-reader-select-posn-page' 按 `posn-point' 反查页号：同一个窗口里，落在
第 2、3 页行的 posn 必须分别答 2 和 3，即使视口顶页是第 1 页。`posn->page' 的
坐标换算不变（图像像素 × frame scale ÷ 页 scale）。"
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (should (= 1 (seshat-reader-current-doc-pagenumber window)))
            (seshat-reader-periphery-test--with-posn-stubs window
              (let ((posn2 (seshat-reader-periphery-test--fake-posn
                            window (seshat-reader-periphery-test--row-start 2)))
                    (posn3 (seshat-reader-periphery-test--fake-posn
                            window (seshat-reader-periphery-test--row-start 3))))
                (should (= 2 (seshat-reader-select-posn-page posn2 window)))
                (should (= 3 (seshat-reader-select-posn-page posn3 window)))
                ;; 坐标仍是该页图内的像素坐标
                (should (equal (cons 10.0 20.0)
                               (seshat-reader-select-posn->page posn2 window)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--posn-page-falls-back-to-top-page ()
  "A position that maps to no page row falls back to the viewport top page."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (seshat-reader-periphery-test--with-posn-stubs window
              ;; 落在 buffer 开头之后、第一页行之前的 newline 上
              (should (= 1 (seshat-reader-select-posn-page
                            (seshat-reader-periphery-test--fake-posn window 1)
                            window))))))
      (kill-buffer buffer))))

;;;; 2/3. 选区：跨页取文与同页不变

(ert-deftest seshat-reader-periphery-test--select-extract-cross-page-extracts-text ()
  "A drag spanning two pages extracts both pages instead of signalling.
P2-A T2 移除了「暂不支持跨页选择」：跨页拖选按页取文、页间插一个换行，
`:page' / `:rect' 仍归属**起点页**。跨页取文的逐页几何与页号换算见
`seshat-reader-select-cross-page-test'，此处只钉住本套件的集成点。"
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (seshat-reader-select-last nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (seshat-reader-periphery-test--with-posn-stubs window
              (cl-letf (((symbol-function 'posn-object-width-height)
                         (lambda (_posn) (cons 600 800)))
                        ((symbol-function 'seshat-reader-dyn--text-in-rect)
                         (lambda (page &rest _) (format "p%d" (1+ page))))
                        ((symbol-function 'seshat-reader-select--rects-in-rect)
                         (lambda (&rest _) nil))
                        ((symbol-function 'seshat-reader-select--flash-selection)
                         (lambda (&rest _) t))
                        ((symbol-function 'message) (lambda (&rest _) nil)))
                (let ((start (seshat-reader-periphery-test--fake-posn
                              window (seshat-reader-periphery-test--row-start 1)))
                      (end (seshat-reader-periphery-test--fake-posn
                            window (seshat-reader-periphery-test--row-start 2)
                            (cons 200 300))))
                  (should (equal "p1\np2"
                                 (seshat-reader-select-extract start end)))
                  (should (= 1 (plist-get seshat-reader-select-last :page)))
                  ;; 首页从拖拽点裁到页底（页高 800，见上面的桩）。
                  (should (equal '(10.0 20.0 200.0 800.0)
                                 (plist-get seshat-reader-select-last :rect)))
                  ;; 无几何时 `:page-rects' 与 `:rects' 同为 nil（一一对应）。
                  (should-not (plist-get seshat-reader-select-last :rects))
                  (should-not (plist-get seshat-reader-select-last
                                         :page-rects)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--select-extract-same-page-returns-text ()
  "A same-page drag extracts text and records the page the click landed on."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (seshat-reader-select-last nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (seshat-reader-periphery-test--with-posn-stubs window
              (cl-letf (((symbol-function 'seshat-reader-dyn--text-in-rect)
                         (lambda (&rest _) "hello"))
                        ((symbol-function 'seshat-reader-select--rects-in-rect)
                         (lambda (&rest _) nil))
                        ((symbol-function 'seshat-reader-select--flash-selection)
                         (lambda (&rest _) t))
                        ((symbol-function 'message) (lambda (&rest _) nil)))
                (let ((start (seshat-reader-periphery-test--fake-posn
                              window (seshat-reader-periphery-test--row-start 2)))
                      (end (seshat-reader-periphery-test--fake-posn
                            window (1+ (seshat-reader-periphery-test--row-start 2))
                            (cons 200 400))))
                  (should (equal "hello" (seshat-reader-select-extract start end)))
                  (should (= 2 (plist-get seshat-reader-select-last :page)))
                  (should (equal '(10.0 20.0 200.0 400.0)
                                 (plist-get seshat-reader-select-last :rect))))))))
      (kill-buffer buffer))))

;;;; 4/5. 书签：保存/恢复与旧字段迁移

(defun seshat-reader-periphery-test--jump-calls (bookmark &optional new-document)
  "Jump to BOOKMARK with every UI side effect stubbed, return what was called.
NEW-DOCUMENT non-nil models a jump that *opens* a document: `derived-mode-p'
answers nil until `bookmark-default-handler' has switched the buffer, which is
exactly the gate the restore reads to decide whether the recorded fit applies.
nil models jumping inside a buffer that is already in `seshat-reader-mode'.

The returned plist holds :scale (args of `--multipage-set-scale'), :page (arg
of `--multipage-goto'), :vscroll (args of `set-window-vscroll'), :hscroll (args
of `set-window-hscroll') and :events, the calls in call order as a list of
\(NAME . ARGS).  The plist entries keep only the *last* call of each function
and therefore cannot carry an order assertion; the restore has to force a frame
*before* it writes the pixel offset, so the ordered :events list is what the
order tests read."
  (let ((calls nil)
        (events nil)
        (handled nil))
    (cl-letf (((symbol-function 'bookmark-default-handler)
               (lambda (&rest _) (setq handled t) nil))
              ((symbol-function 'file-exists-p) (lambda (&rest _) t))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil))
              ((symbol-function 'seshat-reader-mode) (lambda (&rest _) nil))
              ((symbol-function 'derived-mode-p)
               (lambda (&rest _)
                 (and (or handled (not new-document)) 'seshat-reader-mode)))
              ((symbol-function 'seshat-reader--multipage-set-scale)
               (lambda (&rest args)
                 (push (cons 'set-scale args) events)
                 (setq calls (plist-put calls :scale args))))
              ((symbol-function 'seshat-reader--multipage-goto)
               (lambda (page)
                 (push (cons 'goto page) events)
                 (setq calls (plist-put calls :page page))
                 page))
              ;; 固定基准页 fit：`width' 记录走这条路，桩掉才能在批处理里观察到
              ;; ① 步是否真的出手（真函数无窗口几何时返回 nil，会让
              ;; 「应用了 fit」与「没应用」看起来一样 → 假绿）。
              ((symbol-function 'seshat-reader--multipage-base-fit-scale)
               (lambda (&optional _mode _window) 0.42))
              ((symbol-function 'redisplay)
               (lambda (&rest args)
                 (push (cons 'redisplay args) events)
                 nil))
              ((symbol-function 'set-window-vscroll)
               (lambda (&rest args)
                 (push (cons 'set-window-vscroll args) events)
                 (setq calls (plist-put calls :vscroll args))))
              ((symbol-function 'set-window-hscroll)
               (lambda (&rest args)
                 (push (cons 'set-window-hscroll args) events)
                 (setq calls (plist-put calls :hscroll args)))))
      (seshat-reader-bookmark-jump bookmark))
    (plist-put calls :events (nreverse events))))

(defun seshat-reader-periphery-test--jump-event-names (calls &rest wanted)
  "Return the CALLS event names that are in WANTED, in call order."
  (delq nil (mapcar (lambda (event)
                      (and (memq (car event) wanted) (car event)))
                    (plist-get calls :events))))

(ert-deftest seshat-reader-periphery-test--bookmark-round-trip ()
  "Page, offset, hscroll and scale are restored, the zoom as `manual'.

整条记录（含缩放）的往返只在**新开文档**时成立：同一阅读 buffer 内跳转不应用
记录的 fit / scale（见 `--bookmark-jump-same-buffer-keeps-current-fit'）。"
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 7)
                         (cons 'offset 120)
                         (cons 'hscroll 40)
                         (cons 'scale 1.5)
                         ;; `manual' 记录才用记录里的 scale；fit 模式走基准页
                         ;; fit（见 `--bookmark-restores-recorded-fit-mode'）
                         (cons 'fit-mode 'manual)))
         (calls (seshat-reader-periphery-test--jump-calls bookmark :new-document)))
    (should (equal '(1.5 manual manual) (plist-get calls :scale)))
    (should (= 7 (plist-get calls :page)))
    ;; 工具把 nil 解析成 selected window 后才写给 `set-window-vscroll'
    (should (equal (list (selected-window) 120 t)
                   (plist-get calls :vscroll)))
    (should (equal (list nil 40) (plist-get calls :hscroll)))))

(ert-deftest seshat-reader-periphery-test--bookmark-jump-same-buffer-keeps-current-fit ()
  "A jump inside a reader buffer moves the place, never the current fit.

① 步（`fit-mode' / `scale'）整体跳过——跳转只该移动视图，不该改动用户正在使用
的视图；② page / ③ offset / ④ hscroll 仍按记录恢复，且事件序不变（goto → 落帧
→ 写偏移）。断言实参与顺序，不只断言「被调用过」。

`width'（走基准页 fit 分支）与 `manual'（走记录的 scale 分支）两条记录各跑一遍：
只测其中一条时，另一条分支若被误放行也照样绿。"
  (dolist (bookmark (list ;; fit 模式分支
                           (list (cons 'filename "/tmp/doc.pdf")
                                 (cons 'page 7)
                                 (cons 'offset 120)
                                 (cons 'hscroll 40)
                                 (cons 'scale 1.5)
                                 (cons 'fit-mode 'width))
                           ;; manual / 显式 scale 分支
                           (list (cons 'filename "/tmp/doc.pdf")
                                 (cons 'page 7)
                                 (cons 'offset 120)
                                 (cons 'hscroll 40)
                                 (cons 'scale 1.5)
                                 (cons 'fit-mode 'manual))))
    (let ((calls (seshat-reader-periphery-test--jump-calls bookmark)))
      ;; fit 与记录里的 scale 一个都不应用
      (should-not (plist-get calls :scale))
      (should-not (seshat-reader-periphery-test--jump-event-names
                   calls 'set-scale))
      ;; 位置照旧：页号 / 页内像素偏移 / 横向位置
      (should (= 7 (plist-get calls :page)))
      (should (equal (list (selected-window) 120 t)
                     (plist-get calls :vscroll)))
      (should (equal (list nil 40) (plist-get calls :hscroll)))
      (should (equal '(goto redisplay set-window-vscroll)
                     (seshat-reader-periphery-test--jump-event-names
                      calls 'goto 'redisplay 'set-window-vscroll))))))

(ert-deftest seshat-reader-periphery-test--bookmark-jump-new-buffer-restores-recorded-fit ()
  "A jump that opens a document still applies the recorded fit and scale.

跳转前不是阅读 buffer（从书签打开未读文档、saveplace 重开）时没有「当前视图」可
继承，故 ① 步照旧执行：`--multipage-set-scale' 被调用、实参为记录值，且发生在
跳页之前（页行高度变了，目标页的位置才稳定）。"
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 7)
                         (cons 'offset 120)
                         (cons 'hscroll 40)
                         (cons 'scale 1.5)
                         (cons 'fit-mode 'manual)))
         (calls (seshat-reader-periphery-test--jump-calls bookmark :new-document)))
    ;; 实参逐项：记录里的 scale + manual 来源（不是记录里那个 fit 模式）
    (should (equal '(1.5 manual manual) (plist-get calls :scale)))
    ;; 位置照旧恢复
    (should (= 7 (plist-get calls :page)))
    (should (equal (list (selected-window) 120 t)
                   (plist-get calls :vscroll)))
    (should (equal (list nil 40) (plist-get calls :hscroll)))
    (should (equal '(set-scale goto redisplay set-window-vscroll)
                   (seshat-reader-periphery-test--jump-event-names
                    calls 'set-scale 'goto 'redisplay 'set-window-vscroll)))))

(ert-deftest seshat-reader-periphery-test--bookmark-legacy-vscroll-migrates ()
  "A pre-P1 record carrying only `vscroll' is migrated to a pixel offset."
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 3)
                         (cons 'vscroll 80)))
         (calls (seshat-reader-periphery-test--jump-calls bookmark)))
    (should (= 3 (plist-get calls :page)))
    (should (equal (list (selected-window) 80 t)
                   (plist-get calls :vscroll)))
    ;; 旧记录没有 scale → 不缩放
    (should-not (plist-get calls :scale))))

(ert-deftest seshat-reader-periphery-test--bookmark-invalid-scale-is-skipped ()
  "A missing or non-numeric scale skips the zoom instead of signalling."
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 2)
                         (cons 'offset nil)
                         (cons 'scale "big")))
         (calls (seshat-reader-periphery-test--jump-calls bookmark)))
    (should-not (plist-get calls :scale))
    (should (= 2 (plist-get calls :page)))
    ;; offset 非法 → 不设 vscroll（落到页首）
    (should-not (plist-get calls :vscroll))))

(ert-deftest seshat-reader-periphery-test--bookmark-jump-redisplays-before-offset ()
  "The restore forces a frame before it writes the page-internal offset.

Emacs drops a pixel scroll that is set in the same frame as the new
`window-start' that `seshat-reader--multipage-goto' installed (real-frame
probe: 3090 -> 0), so the offset has to be written only after a displayed
frame.  Asserting the call *order* -- not just that both calls happen -- is
what catches the regression: the old implementation wrote the offset inside the
goto frame, where this order was impossible."
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 5)
                         (cons 'offset 120)))
         (calls (seshat-reader-periphery-test--jump-calls bookmark)))
    (should (equal '(redisplay set-window-vscroll)
                   (seshat-reader-periphery-test--jump-event-names
                    calls 'redisplay 'set-window-vscroll)))
    ;; 实参：解析后的窗口（selected window）+ 偏移 + 像素模式
    (should (equal (list (selected-window) 120 t)
                   (cdr (assq 'set-window-vscroll
                              (plist-get calls :events)))))))

(ert-deftest seshat-reader-periphery-test--bookmark-jump-without-offset-does-not-redisplay ()
  "A record without a usable offset forces no frame and writes no scroll.

这是**优化断言**——避免无谓刷新，不是行为契约：落帧只服务于「写偏移」，`offset'
缺失或为 0 时恢复就停在页首，没有任何偏移要写。将来若发现 offset=0 也需要落帧
（例如为了让居中属性立即刷新），放宽此例即可，不必改实现。"
  (dolist (bookmark (list (list (cons 'filename "/tmp/doc.pdf")
                                (cons 'page 4))
                          (list (cons 'filename "/tmp/doc.pdf")
                                (cons 'page 4)
                                (cons 'offset 0))))
    (let ((calls (seshat-reader-periphery-test--jump-calls bookmark)))
      (should (= 4 (plist-get calls :page)))
      (should-not (seshat-reader-periphery-test--jump-event-names
                   calls 'redisplay 'set-window-vscroll)))))

(ert-deftest seshat-reader-periphery-test--bookmark-record-has-p1-fields ()
  "The record carries page/offset/hscroll/scale/fit-mode and no `vscroll'."
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2))))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'bookmark-make-record-default)
                       (lambda (&rest _) nil)))
              (let ((record (seshat-reader-bookmark-make-record)))
                (should (= 1 (alist-get 'page record)))
                (should (numberp (alist-get 'offset record)))
                (should (assq 'hscroll record))
                (should (= 1.0 (alist-get 'scale record)))
                (should (eq 'contain (alist-get 'fit-mode record)))
                (should-not (assq 'vscroll record))))))
      (kill-buffer buffer))))

;;;; 6. saveplace 往返

(ert-deftest seshat-reader-periphery-test--saveplace-round-trip ()
  "Saveplace stores the bookmark record and restores it through the handler."
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
        (save-place-alist nil)
        (jumped nil))
    (unwind-protect
        (with-current-buffer buffer
          (setq buffer-file-name "/tmp/saveplace-doc.pdf")
          (cl-letf (((symbol-function 'bookmark-make-record-default)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-bookmark-jump)
                     (lambda (bookmark) (setq jumped bookmark) t))
                    ((symbol-function 'save-place-load-alist-from-file)
                     (lambda (&rest _) t)))
            (seshat-reader--saveplace-to-alist)
            (let* ((place (assoc "/tmp/saveplace-doc.pdf" save-place-alist))
                   (bookmark (aref (cdr place) 0)))
              (should place)
              (should (equal "seshat-reader-saveplace" (car bookmark)))
              (should (= 1 (alist-get 'page (cdr bookmark))))
              (should (assq 'offset (cdr bookmark)))
              ;; 往返：find-file 路径把记录交给同一处理函数
              (seshat-reader--saveplace-find-file)
              (should (equal (cdr bookmark) (cdr jumped))))))
      (kill-buffer buffer))))

;;;; 7. 搜索跳转停在页首

(ert-deftest seshat-reader-periphery-test--search-goto-lands-on-page-top ()
  "A search hit jump goes through the goto command and resets the pixel scroll."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (vscrolls nil)
         (gotos nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (&rest args) (push args vscrolls)))
                      ((symbol-function 'seshat-reader--multipage-sync)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage-render-page)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage--show-page)
                       (lambda (page) (push page gotos)
                              (seshat-reader-periphery-test--row-start page))))
              ;; 真实 `--multipage-goto'：必须把页内偏移清零
              (seshat-reader--multipage-goto 2)
              (should (equal (list (selected-window) 0 t) (car vscrolls)))
              ;; `--multipage-goto' 会 show 两次：先定位到目标页，sync 插入/回收
              ;; 页行之后再重定位一次（见其 docstring）。
              (should (equal '(2 2) gotos)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--search-jump-uses-goto-command ()
  "The search jump path calls the public goto command with the hit page."
  (let ((called nil))
    (cl-letf (((symbol-function 'seshat-reader-goto-page)
               (lambda (page) (setq called page))))
      (seshat-reader-search--goto-page 5))
    (should (= 5 called))))

;;;; 8. 引用 page:<n> 生成 → 跳回

(ert-deftest seshat-reader-periphery-test--reference-page-anchor-round-trip ()
  "A page anchor built from `page:<n>' jumps back to that page and reports it."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (messages nil)
         (called nil))
    (unwind-protect
        (with-current-buffer buffer
          ;; 生成：页号取**视口顶页**（多页布局下一屏多页，只能锚定顶页）。
          ;; 窗口几何本身由 multipage 套件覆盖，这里桩住页号以便断言锚点内容。
          (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                     (lambda (&optional _window) 2)))
            (let ((location (format "page:%d"
                                    (seshat-reader-current-doc-pagenumber))))
              (should (equal "page:2" location))
              (cl-letf (((symbol-function 'seshat-reader-goto-page)
                         (lambda (page) (setq called page)))
                        ((symbol-function 'message)
                         (lambda (fmt &rest args)
                           (push (apply #'format fmt args) messages))))
                (seshat-reader-reference--goto-location
                 (list :location location)))))
          (should (= 2 called))
          (should (seq-find (lambda (m) (string-match-p "2" m)) messages)))
      (kill-buffer buffer))))

;;;; 9/10. 装饰刷新

(ert-deftest seshat-reader-periphery-test--refresh-decorations-rerenders-resident ()
  "Every resident page is re-rendered once, old cached specs are dropped."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (renders 0))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            ;; 先塞一条「过期」缓存（第 1 页、另一个 scale）
            (setq seshat-reader--page-spec-cache
                  (list (cons (seshat-reader--page-spec-key 1 2.0 0) 'stale)))
            (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                       (lambda (page scale &optional _rotate)
                         (setq renders (1+ renders))
                         (list 'image :type 'pbm :data "x"
                               :width 600 :height 800 :page page :scale scale)))
                      ((symbol-function 'seshat-reader-dyn--refresh-highlights)
                       (lambda (&rest _) (error "Must not be called"))))
              (should (= 3 (seshat-reader--multipage-refresh-decorations window)))
              (should (= 3 renders))
              ;; 过期条目被清掉：第 1 页只留下新的（scale 1.0）那条
              (let ((page1 (cl-remove-if-not
                            (lambda (entry) (= 1 (car (car entry))))
                            seshat-reader--page-spec-cache)))
                (should (= 1 (length page1)))
                (should-not (eq 'stale (cdr (car page1))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--refresh-decorations-skips-non-resident ()
  "Only pages with a row are re-rendered, never a page outside the layout."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 3 5)))
         (window (selected-window))
         (visited nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'seshat-reader--multipage-rerender-page)
                       (lambda (page &optional _window)
                         (push page visited) t)))
              (should (= 3 (seshat-reader--multipage-refresh-decorations window)))
              (should (equal '(5 3 1) visited))
              ;; 第 2、4 页没有页行 → 从未被访问
              (should-not (memq 2 visited))
              (should-not (memq 4 visited)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--refresh-decorations-other-buffer-is-noop ()
  "A window showing another buffer triggers no re-render at all."
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
        (visited 0))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'seshat-reader--multipage-rerender-page)
                     (lambda (&rest _) (setq visited (1+ visited)) t)))
            (should (= 0 (seshat-reader--multipage-refresh-decorations
                          (selected-window))))
            (should (= 0 visited))))
      (kill-buffer buffer))))

;;;; 11. 拖拽不动选中窗口与 window-start

(ert-deftest seshat-reader-periphery-test--drag-keeps-window-start-and-selection ()
  "A drag leaves the selected window and `window-start' exactly as they were."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (selected-before (selected-window))
         (start-before nil)
         (extracted nil)
         (events (list 'move 'release)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-start window (seshat-reader-periphery-test--row-start 2))
            (setq start-before (window-start window))
            (cl-letf (((symbol-function 'read-event)
                       (lambda (&rest _)
                         (let ((kind (pop events)))
                           (if (eq kind 'move) 'mouse-movement 'drag-mouse-1))))
                      ((symbol-function 'event-start)
                       (lambda (event) (seshat-reader-periphery-test--fake-posn
                                        window
                                        (seshat-reader-periphery-test--row-start 2))))
                      ((symbol-function 'event-end)
                       (lambda (event) (seshat-reader-periphery-test--fake-posn
                                        window
                                        (seshat-reader-periphery-test--row-start 2))))
                      ((symbol-function 'mouse-movement-p)
                       (lambda (event) (eq event 'mouse-movement)))
                      ((symbol-function 'seshat-reader-select-extract)
                       (lambda (start end) (setq extracted t) "ok")))
              (seshat-reader-select-drag '(down-mouse-1)))
            (should extracted)
            ;; 选中窗口没变（没有被 `select-window' 换掉）
            (should (eq selected-before (selected-window)))
            ;; window-start 没动：拖拽不得打断像素滚动位置
            (should (= start-before (window-start window)))))
      (kill-buffer buffer))))

;;;; T9 回归：审查修复（多窗口 scale / 书签 fit 模式）

(ert-deftest seshat-reader-periphery-test--posn->page-uses-current-scale-across-windows ()
  "Selection geometry divides by the buffer level scale, not a stale mirror."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
         (window-a (selected-window))
         (window-b nil))
    (unwind-protect
        (progn
          (setq window-b (split-window window-a))
          (set-window-buffer window-a buffer)
          (set-window-buffer window-b buffer)
          (seshat-reader-periphery-test--load-select-source)
          (with-current-buffer buffer
            ;; buffer 级缩放 2.0，而窗口 B 的镜像被人为写脏成 1.0
            (setq seshat-reader--multipage-base-scale 2.0)
            (set-window-parameter window-a 'scale 2.0)
            (set-window-parameter window-b 'scale 1.0)
            (seshat-reader-periphery-test--with-posn-stubs window-b
              (let ((posn (seshat-reader-periphery-test--fake-posn
                           window-b 1 (cons 200 400))))
                ;; 200/2 = 100（不是 200/1 = 200）
                (should (equal (cons 100.0 200.0)
                               (seshat-reader-select-posn->page posn window-b)))
                (should-not (equal (cons 200.0 400.0)
                                   (seshat-reader-select-posn->page posn window-b)))))))
      (when (window-live-p window-b) (delete-window window-b))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--bookmark-restores-recorded-fit-mode ()
  "Opening a document from a bookmark applies the recorded fit mode.

这条用例是**新开文档**场景：跳转前 buffer 不是 `seshat-reader-mode'（`derived-mode-p'
在 handler 之前返回 nil），此时没有「当前视图」可继承，记录值才生效。同一阅读
buffer 内跳转不应用 fit 的行为由
`--bookmark-jump-same-buffer-keeps-current-fit' 覆盖。"
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
        (handled nil)
        (width-bookmark (list (cons 'filename "/tmp/doc.pdf")
                              (cons 'page 2)
                              (cons 'offset 0)
                              (cons 'scale 1.5)
                              (cons 'fit-mode 'width)))
        (manual-bookmark (list (cons 'filename "/tmp/doc.pdf")
                               (cons 'page 2)
                               (cons 'scale 1.5)
                               (cons 'fit-mode 'manual))))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'bookmark-default-handler)
                     (lambda (&rest _) (setq handled t) nil))
                    ((symbol-function 'file-exists-p) (lambda (&rest _) t))
                    ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil))
                    ((symbol-function 'derived-mode-p)
                     ;; 跳转前不是阅读 buffer（新开文档）；handler 之后才是。
                     (lambda (&rest _)
                       (and handled 'seshat-reader-mode)))
                    ((symbol-function 'seshat-reader--multipage-goto)
                     (lambda (&rest _) nil))
                    ((symbol-function 'set-window-vscroll) (lambda (&rest _) nil))
                    ((symbol-function 'set-window-hscroll) (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader--multipage-base-fit-scale)
                     (lambda (&optional _mode _window) 0.42))
                    ((symbol-function 'seshat-reader--apply-display-scale)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader--center-page)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader--multipage-refit-page)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader--multipage-sync)
                     (lambda (&rest _) nil)))
            ;; 记录 width → base = 该模式的基准页 fit（0.42），不是记录里的 1.5
            ;; 每次跳转前复位「已过 handler」标记：否则第二次跳转会被当成
            ;; 「同一 buffer 内跳转」，① 步整段跳过、记录的 fit 不生效。
            (setq handled nil)
            (seshat-reader-bookmark-jump width-bookmark)
            (should (eq 'width seshat-reader--multipage-fit-mode))
            (should (= 0.42 seshat-reader--multipage-base-scale))
            ;; 记录 manual → 用记录的显式 scale，并把 fit 模式置 manual
            (setq handled nil)
            (seshat-reader-bookmark-jump manual-bookmark)
            (should (eq 'manual seshat-reader--multipage-fit-mode))
            (should (= 1.5 seshat-reader--multipage-base-scale))))
      (kill-buffer buffer))))

(provide 'seshat-reader-periphery-test)

;;; seshat-reader-periphery-test.el ends here
