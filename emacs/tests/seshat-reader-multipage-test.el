;;; seshat-reader-multipage-test.el --- Tests for the multi-page layout skeleton  -*- lexical-binding: t; -*-

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

;; 阅读器 P1 T1「多页布局骨架」的 ERT 测试套件：页行插入/移除、`display'
;; 文本属性承载 image spec、`seshat-reader-page-gap-lines' 的间隙行数、
;; 以及可见集区间（视口 ± preload）的计算。
;;
;; T1 **只测新增结构，不涉及显示路径**：夹具用 `with-temp-buffer' 直接调新
;; 函数，不进入 `seshat-reader-mode'、不渲染真实 PDF、不需要 native 模块；
;; fake spec 只用 `(list 'image :width N :height 10)'。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader -l ert \
;;     -l emacs/tests/seshat-reader-multipage-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 可见集用例依赖窗口：batch 下 `set-window-start' 可用（`should' 断言它确实
;; 生效，未生效即用例失败而不是静默退化）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
;; T7：选区（`seshat-reader-select-*'）与滚轮命令的用例需要 select 模块，
;; 它的 `with-eval-after-load' 只负责绑 `down-mouse-1'，batch 里无副作用。
(require 'seshat-reader-select)

;; `seshat-reader-current-doc-pagecount' 由 C 模块注册为永久 buffer-local；本套件
;; 不打开真实文档，故在此声明为 special，让 `let' 能临时模拟文档页数。
(defvar seshat-reader-current-doc-pagecount nil
  "Document page count, normally written by the native module.")

;;;; 夹具与辅助函数

(defun seshat-reader-multipage-test--fake-spec (&optional width)
  "Return a fake image spec WIDTH pixels wide."
  (list 'image :width (or width 10) :height 10))

(defun seshat-reader-multipage-test--insert-pages (pages)
  "Insert PAGES, a list of page numbers, each with a fake spec."
  (dolist (page pages)
    (seshat-reader--multipage-insert-page
     page (seshat-reader-multipage-test--fake-spec page))))

(defun seshat-reader-multipage-test--display-count ()
  "Return how many buffer positions display an image spec.

自 T4 起每页行有两个 `display' 属性：行首的引导空格携带
\\(space :align-to ...) 居中规格，第二个字符才是该页的 image spec。
因此这里只数 `(car-safe val)` 为 `image' 的，即「真正显示图片的位置」。"
  (let ((count 0)
        (pos (point-min)))
    (while (< pos (point-max))
      (if (eq (car-safe (get-text-property pos 'display)) 'image)
          (progn
            (setq count (1+ count))
            (setq pos (next-single-property-change pos 'display nil (point-max))))
        (setq pos (1+ pos))))
    count))

(defun seshat-reader-multipage-test--page-spec-at (pos)
  "Return the image spec displayed by the page row that starts at POS.

页行结构是「引导空格 + 图像占位空格 + 换行」，图像 spec 挂在行首的
下一个字符上（T4 引入的 `:align-to' 居中规格占据行首）。"
  (get-text-property (1+ pos) 'display))

(defun seshat-reader-multipage-test--page-numbers ()
  "Return the page numbers of the layout in buffer order."
  (mapcar #'car seshat-reader--pages))

(defun seshat-reader-multipage-test--marker-positions ()
  "Return the row marker positions of the layout in buffer order."
  (mapcar (lambda (entry) (marker-position (cadr entry))) seshat-reader--pages))

;;;; 用例

(ert-deftest seshat-reader-multipage-test--inserts-five-pages-in-order ()
  "Five pages give five displayed rows, ordered by page number."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
    (should (= (seshat-reader-multipage-test--display-count) 5))
    (should (equal (seshat-reader-multipage-test--page-numbers) '(1 2 3 4 5)))
    (let ((positions (seshat-reader-multipage-test--marker-positions)))
      (should (= (length positions) 5))
      (should (apply #'< positions)))))

(ert-deftest seshat-reader-multipage-test--inserts-sixth-page-at-the-end ()
  "A sixth page appends one more displayed row after the fifth."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
    (seshat-reader-multipage-test--insert-pages '(6))
    (should (= (seshat-reader-multipage-test--display-count) 6))
    (should (equal (seshat-reader-multipage-test--page-numbers)
                   '(1 2 3 4 5 6)))
    (let ((positions (seshat-reader-multipage-test--marker-positions)))
      (should (apply #'< positions)))))

(ert-deftest seshat-reader-multipage-test--removes-first-page ()
  "Removing page 1 hands its spec back and keeps the other rows intact."
  (with-temp-buffer
    (let ((spec-one (seshat-reader-multipage-test--fake-spec 101))
          (spec-two (seshat-reader-multipage-test--fake-spec 102)))
      (seshat-reader--multipage-insert-page 1 spec-one)
      (seshat-reader--multipage-insert-page 2 spec-two)
      (seshat-reader-multipage-test--insert-pages '(3 4 5 6))
      (should (= (seshat-reader-multipage-test--display-count) 6))
      (let ((removed (seshat-reader--multipage-remove-page 1)))
        ;; 返回的 spec 必须是插入时的那一个对象（调用方据此回收位图）。
        (should (eq removed spec-one))
        (should (= (seshat-reader-multipage-test--display-count) 5))
        (should (equal (seshat-reader-multipage-test--page-numbers)
                       '(2 3 4 5 6)))
        (should (null (seshat-reader--multipage-page-spec 1)))
        (should (eq (seshat-reader--multipage-page-spec 2) spec-two))
        ;; 剩余页的 marker 仍指向各自页行：行首的 display 属性即该页 spec，
        ;; 且 `--multipage-page-at-pos' 在行首返回该页号。
        (dolist (entry seshat-reader--pages)
          (let* ((page (car entry))
                 (pos (marker-position (cadr entry))))
            (should (eq (seshat-reader-multipage-test--page-spec-at pos)
                        (seshat-reader--multipage-page-spec page)))
            (should (= (seshat-reader--multipage-page-at-pos pos) page))))
        ;; 移除最后剩下的页后布局回到空状态。
        (dolist (page '(2 3 4 5 6))
          (seshat-reader--multipage-remove-page page))
        (should (null seshat-reader--pages))
        (should (= (seshat-reader-multipage-test--display-count) 0))))))

(ert-deftest seshat-reader-multipage-test--gap-lines-add-blank-lines ()
  "`seshat-reader-page-gap-lines' adds exactly that many lines per page."
  (let ((zero-lines (with-temp-buffer
                      (let ((seshat-reader-page-gap-lines 0))
                        (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
                        (count-lines (point-min) (point-max)))))
        (two-lines (with-temp-buffer
                     (let ((seshat-reader-page-gap-lines 2))
                       (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
                       (count-lines (point-min) (point-max))))))
    ;; 5 页各占 1 行，gap 每页再追加 2 行 → 差 = 2 × 5 = 10。
    (should (= (- two-lines zero-lines) 10))))

(ert-deftest seshat-reader-multipage-test--out-of-order-inserts-stay-sorted ()
  "Inserting pages 3, 1 and 2 keeps them sorted and each row addressable."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(3 1 2))
    (should (equal (seshat-reader-multipage-test--page-numbers) '(1 2 3)))
    (should (= (seshat-reader-multipage-test--display-count) 3))
    (let ((positions (seshat-reader-multipage-test--marker-positions)))
      (should (apply #'< positions))
      ;; 每个行首都必须反查回自己的页号。
      (dolist (entry seshat-reader--pages)
        (should (= (seshat-reader--multipage-page-at-pos
                    (marker-position (cadr entry)))
                   (car entry)))))))

(ert-deftest seshat-reader-multipage-test--insert-page-replaces-spec ()
  "Inserting an existing page only replaces its spec, it adds no row."
  (with-temp-buffer
    (let ((first (seshat-reader-multipage-test--fake-spec 111))
          (second (seshat-reader-multipage-test--fake-spec 222)))
      (should (markerp (seshat-reader--multipage-insert-page 1 first)))
      (should (null (seshat-reader--multipage-insert-page 1 second)))
      (should (= (seshat-reader-multipage-test--display-count) 1))
      (should (eq (seshat-reader--multipage-page-spec 1) second))
      (should (eq (seshat-reader-multipage-test--page-spec-at (point-min)) second)))))

(ert-deftest seshat-reader-multipage-test--page-at-pos-keeps-gaps-on-previous ()
  "The gap line after a page belongs to that page, not to the next one."
  (with-temp-buffer
    (let ((seshat-reader-page-gap-lines 2))
      (seshat-reader-multipage-test--insert-pages '(1 2))
      (let* ((first (marker-position (cadr (assq 1 seshat-reader--pages))))
             (second (marker-position (cadr (assq 2 seshat-reader--pages)))))
        (should (= (seshat-reader--multipage-page-at-pos (point-min)) 1))
        (should (= (seshat-reader--multipage-page-at-pos first) 1))
        ;; 第 1 页行尾与它后面两条 gap 空行都归第 1 页。
        (should (= (seshat-reader--multipage-page-at-pos (1- second)) 1))
        (should (= (seshat-reader--multipage-page-at-pos second) 2))
        (should (= (seshat-reader--multipage-page-at-pos (point-max)) 2))
        ;; 空布局与越界都返回 nil。
        (should (null (seshat-reader--multipage-page-at-pos (1+ (point-max))))))))
  (with-temp-buffer
    (should (null (seshat-reader--multipage-page-at-pos (point-min))))))

(ert-deftest seshat-reader-multipage-test--visible-range-widens-around-viewport ()
  "A viewport on page 3 of five asks for pages 1 through 5."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
    (let ((window (selected-window))
          (original (window-buffer))
          (third (cadr (assq 3 seshat-reader--pages))))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (set-window-start window (marker-position third))
            (should (= (window-start window) (marker-position third)))
            (let ((seshat-reader--multipage-preload 2))
              (should (equal (seshat-reader--multipage-visible-range window)
                             '(1 . 5)))))
        (set-window-buffer window original)))))

(ert-deftest seshat-reader-multipage-test--visible-range-clips-to-pagecount ()
  "A large preload is clipped to page 1 and to the document page count.

裁剪基准是文档页数而不是「已经插入的页」：视口在第 2 页、只有 1..3 页存在，
但文档共 40 页时，区间上界要越过第 3 页（否则滚动到第 4 页时范围会算成空集）。"
  (with-temp-buffer
    (let ((window (selected-window))
          (original (window-buffer)))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (let ((seshat-reader-current-doc-pagecount 40))
              (seshat-reader-multipage-test--insert-pages '(1 2 3))
              (set-window-start window (marker-position
                                        (cadr (assq 2 seshat-reader--pages))))
              (should (= (window-start window)
                         (marker-position (cadr (assq 2 seshat-reader--pages)))))
              ;; preload 本身被夹到 3（m5）：视口底页 3 + 3 = 6，下界夹到第 1 页
              (let ((seshat-reader--multipage-preload 10))
                (should (= 3 (seshat-reader--multipage-effective-preload)))
                (should (equal (seshat-reader--multipage-visible-range window)
                               '(1 . 6))))
              (let ((seshat-reader--multipage-preload 100))
                ;; preload 再大也只到 1..6，仍远小于 40 页
                (should (equal (seshat-reader--multipage-visible-range window)
                               '(1 . 6))))
              ;; 页数比「视口 + preload」更小时才体现页数裁剪
              (let ((seshat-reader-current-doc-pagecount 4)
                    (seshat-reader--multipage-preload 3))
                (should (equal (seshat-reader--multipage-visible-range window)
                               '(1 . 4))))))
        (set-window-buffer window original)))))

;;;; 批次 2（T1b/T2/T3）：可见集同步、页号派生、翻页边界

(defmacro seshat-reader-multipage-test--with-window-buffer (&rest body)
  "Run BODY with the current buffer displayed in the selected window."
  (declare (indent 0) (debug t))
  `(let ((window (selected-window))
         (original (window-buffer)))
     (unwind-protect
         (progn
           (set-window-buffer window (current-buffer))
           ,@body)
       (set-window-buffer window original))))

(ert-deftest seshat-reader-multipage-test--goto-puts-window-start-on-page ()
  "`--multipage-goto' 把窗口起点与 point 都放在目标页行首。"
  (with-temp-buffer
    (seshat-reader-multipage-test--with-window-buffer
      (let ((seshat-reader-current-doc-pagecount 5))
        (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
        (dolist (page '(3 5 1))
          (seshat-reader--multipage-goto page)
          ;; 行首位置取调用之后的 marker：同步会回收/补齐页行，文本位置会变。
          (let ((pos (marker-position (cadr (assq page seshat-reader--pages)))))
            (should (= (window-start) pos))
            (should (= (point) pos))
            (should (= (seshat-reader--multipage-window-start-page
                        (selected-window))
                       page))))))))

(ert-deftest seshat-reader-multipage-test--goto-returns-fresh-row-position ()
  "`--multipage-goto' 返回调用之后的页行位置，而不是同步之前的位置。"
  (with-temp-buffer
    (seshat-reader-multipage-test--with-window-buffer
      (let ((seshat-reader-current-doc-pagecount 20)
            (seshat-reader--multipage-preload 1))
        ;; 空 buffer：先跳到第 6 页，同步会在它前面插入 5、7 页行，位置必然变化
        (let ((returned (seshat-reader--multipage-goto 6)))
          (should returned)
          (should (= returned
                     (marker-position (cadr (assq 6 seshat-reader--pages)))))
          (should (= (window-start) returned))
          (should (= (point) returned)))))))

(ert-deftest seshat-reader-multipage-test--pagenumber-follows-window-start ()
  "`seshat-reader-current-doc-pagenumber' 随 `set-window-start' 变化。"
  (with-temp-buffer
    (seshat-reader-multipage-test--with-window-buffer
      (let ((seshat-reader-current-doc-pagecount 5))
        (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
        (set-window-start (selected-window)
                          (marker-position (cadr (assq 1 seshat-reader--pages))))
        (should (= 1 (seshat-reader-current-doc-pagenumber
                      (selected-window))))
        (set-window-start (selected-window)
                          (marker-position (cadr (assq 4 seshat-reader--pages))))
        (should (= 4 (seshat-reader-current-doc-pagenumber
                      (selected-window))))
        ;; 页行之间的 gap 空行归属上一个页行
        (set-window-start (selected-window)
                          (1- (marker-position
                               (cadr (assq 4 seshat-reader--pages)))))
        (should (= 3 (seshat-reader-current-doc-pagenumber
                      (selected-window))))))))

(ert-deftest seshat-reader-multipage-test--page-commands-stop-at-the-edges ()
  "`next-page' / `previous-page' 在第 1 页与末页都不越界。"
  (with-temp-buffer
    (seshat-reader-multipage-test--with-window-buffer
      (let ((seshat-reader-current-doc-pagecount 3))
        (seshat-reader-multipage-test--insert-pages '(1 2 3))
        (seshat-reader--multipage-goto 1)
        ;; 第 1 页再往前：无动作，返回 nil
        (should-not (seshat-reader--non-queue-previous-page))
        (should (= 1 (seshat-reader-current-doc-pagenumber (selected-window))))
        ;; 逐页向后
        (should (seshat-reader--non-queue-next-page))
        (should (= 2 (seshat-reader-current-doc-pagenumber (selected-window))))
        (should (seshat-reader--non-queue-next-page))
        (should (= 3 (seshat-reader-current-doc-pagenumber (selected-window))))
        ;; 末页再往后：无动作，返回 nil
        (should-not (seshat-reader--non-queue-next-page))
        (should (= 3 (seshat-reader-current-doc-pagenumber (selected-window))))))))

(ert-deftest seshat-reader-multipage-test--sync-is-idempotent-per-range ()
  "`--multipage-sync' 在区间不变时不再调用渲染入口。"
  (with-temp-buffer
    (seshat-reader-multipage-test--with-window-buffer
      ;; 本用例断言的是「区间内逐页同步渲染」的旧语义（T6 之前的唯一路径），
      ;; 故关掉异步分派，走态 A —— 异步态的同名契约由
      ;; `seshat-reader-multipage-async-render-test.el' 与 T6 的态 B 用例覆盖。
      (let* ((seshat-reader-render-async nil)
             (seshat-reader-current-doc-pagecount 5)
             (calls 0))
        (cl-letf (((symbol-function 'seshat-reader--page-spec)
                   (lambda (&rest _args)
                     (setq calls (1+ calls))
                     (seshat-reader-multipage-test--fake-spec)))
                  ;; batch 下整页行只占一行文本，真实 `window-end' 会把整个 buffer
                  ;; 算进视口；这里固定成「视口只含页顶那一页」，与 GUI 里一页约
                  ;; 一屏的情形一致。
                  ((symbol-function 'window-end)
                   (lambda (&optional _window _update)
                     (window-start (selected-window)))))
          (seshat-reader--multipage-goto 3)
          (let ((first calls))
            ;; 首轮既渲染目标页也补齐可见范围
            (should (> first 0))
            (should (= first (length seshat-reader--pages)))
            ;; 区间未变 → 零渲染调用
            (seshat-reader--multipage-sync (selected-window))
            (should (= calls first))
            (should (= 3 (seshat-reader--multipage-window-start-page
                          (selected-window))))))))))

(ert-deftest seshat-reader-multipage-test--sync-recycles-pages-outside-range ()
  "视口离开较远的页后，`--multipage-sync' 回收区间外的页行。"
  (with-temp-buffer
    (seshat-reader-multipage-test--with-window-buffer
      (let ((seshat-reader-current-doc-pagecount 20)
            ;; 本用例断言「区间外的页行被回收 + 区间内页**都已渲染**」的同步语义
            ;; （T6 之前的唯一路径），故显式走态 A；异步态下页行会先以占位态建立。
            (seshat-reader-render-async nil)
            (seshat-reader--multipage-preload 1))
        (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5 6 7))
        (cl-letf (((symbol-function 'seshat-reader--page-spec)
                   (lambda (&rest _args)
                     (seshat-reader-multipage-test--fake-spec)))
                  ((symbol-function 'window-end)
                   (lambda (&optional _window _update)
                     (window-start (selected-window)))))
          (seshat-reader--multipage-goto 1)
          (should (equal (seshat-reader-multipage-test--page-numbers) '(1 2)))
          ;; 跳到第 6 页：1..2 被回收，5..7 被补上
          (seshat-reader--multipage-goto 6)
          (should (equal (seshat-reader-multipage-test--page-numbers)
                         '(5 6 7)))
          (should (= (seshat-reader-multipage-test--display-count) 3)))))))

;;;; T4（批次 3）几何用例：逐页居中 / 宽页裁剪 / 批量缩放 / presentation·dark

;; 这些用例走完整的几何链路（页行 + `display' 属性 + 按页 native 缓存），用假
;; image spec 与桩窗口尺寸，因此不依赖真实 PDF 与 GUI 帧。真机验收（肉眼确认
;; 居中 / 贴左 / 目录开关后重新居中）仍由用户在批次间完成。

(defmacro seshat-reader-multipage-test--window-pixels (width height &rest body)
  "Run BODY with every window's pixel size stubbed to WIDTH x HEIGHT.

The batch frame is 80x23 pixels, so the real geometry would clip every page;
the stubs give the numbers a normal GUI frame would produce."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'window-body-width)
              (lambda (&optional _window _pixels-p) ,width))
             ((symbol-function 'window-body-height)
              (lambda (&optional _window _pixels-p) ,height)))
     ,@body))

(defmacro seshat-reader-multipage-test--with-window-buffer (buffer &rest body)
  "Display BUFFER in the selected window while BODY runs."
  (declare (indent 1) (debug t))
  `(let ((window (selected-window))
         (original (window-buffer (selected-window))))
     (unwind-protect
         (progn (set-window-buffer window ,buffer) ,@body)
       (set-window-buffer window original))))

(defun seshat-reader-multipage-test--geometry-buffer (&optional pages width height)
  "Create a reader buffer holding one page row per page in PAGES.

Each row displays a fake image spec of WIDTH x HEIGHT (600x800 by default) and
the matching native size is recorded at scale 1.0, exactly as the first render
does.  The buffer-local state is the one `--render-buffer' plus `--first-fit'
leave behind: `contain' fit mode and base scale 1.0.  The buffer is returned as
\(BUFFER . SPECS), SPECS being an alist PAGE -> SPEC."
  (let ((buffer (generate-new-buffer " *seshat-reader-multipage-test*"))
        (specs nil))
    (with-current-buffer buffer
      (setq major-mode 'seshat-reader-mode
            mode-name "Seshat Reader")
      (setq-local seshat-reader--multipage-base-scale 1.0
                  seshat-reader--multipage-fit-mode 'contain)
      (dolist (page (or pages '(1 2 3)))
        (let ((spec (list 'image :type 'canvas :data nil
                          :data-width (or width 600)
                          :data-height (or height 800)
                          :width (or width 600) :height (or height 800))))
          (push (cons page spec) specs)
          (seshat-reader--multipage-insert-page page spec)
          (seshat-reader--multipage-record-native page spec 1.0))))
    (cons buffer (nreverse specs))))

(defun seshat-reader-multipage-test--row-start (page)
  "Return the first buffer position of the row of PAGE."
  (when-let* ((entry (assq page seshat-reader--pages))
              (marker (cadr entry)))
    (marker-position marker)))

(defun seshat-reader-multipage-test--guide (page)
  "Return the `display' property of the centring space of PAGE."
  (when-let* ((start (seshat-reader-multipage-test--row-start page)))
    (get-text-property start 'display)))

(defun seshat-reader-multipage-test--image (page)
  "Return the `display' property of the image placeholder of PAGE."
  (when-let* ((start (seshat-reader-multipage-test--row-start page)))
    (get-text-property (1+ start) 'display)))

(defun seshat-reader-multipage-test--align-spec (page)
  "Return the spec object the centring form of PAGE refers to."
  (let* ((guide (seshat-reader-multipage-test--guide page))
         (align (and (consp guide) (eq (car guide) 'space)
                     (plist-get (cdr guide) :align-to))))
    (when (and (consp align) (eq (car align) '+))
      (let ((form (nth 2 align)))
        (and (consp form) (cdr form))))))

(defun seshat-reader-multipage-test--fake-renderer (counter &optional width height)
  "Return a counting stub for `seshat-reader-dyn--page-image-spec'.

COUNTER is a one-element list holding the number of render requests; the
returned spec is WIDTH x HEIGHT (600x800 by default) times the requested
scale, like the real renderer."
  (let ((w (or width 600))
        (h (or height 800)))
    (lambda (_page scale _rotate)
      (setcar counter (1+ (car counter)))
      (list 'image :type 'canvas :data nil
            :data-width (max 1 (round (* w scale)))
            :data-height (max 1 (round (* h scale)))
            :width (max 1 (round (* w scale)))
            :height (max 1 (round (* h scale)))))))

;;;; 用例

(ert-deftest seshat-reader-multipage-test--geometry-each-page-centred-on-own-spec ()
  "Three visible pages are each centred on their own spec object.

The centring form has to reference the very spec the row displays (`eq'), not
just a spec of the same size: that identity is what lets an in-place resize of
`:width' move the centring with the image, and it is what
`--multipage-page-centered-p' checks on every redisplay."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (dolist (page '(1 2 3))
                (let ((spec (seshat-reader--multipage-page-spec page)))
                  (should (eq (seshat-reader-multipage-test--align-spec page) spec))
                  (should (eq (seshat-reader-multipage-test--image page) spec))
                  (should (seshat-reader--multipage-page-centered-p page))))
              ;; 三个 spec 是不同对象（`equal' 但非 `eq'）：`delete-dups' 按内容
              ;; 去重会把它们合成一个，故这里逐个比较身份。
              (should-not (eq (seshat-reader--multipage-page-spec 1)
                              (seshat-reader--multipage-page-spec 2)))
              (should-not (eq (seshat-reader--multipage-page-spec 2)
                              (seshat-reader--multipage-page-spec 3)))
              (should (seshat-reader--centered-p (selected-window))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-wide-page-has-no-guide ()
  "A page wider than the window carries no centring space.

Centring it would clip both sides, so the row is left aligned and the kept
horizontal scroll commands are the way to see the rest of the page (decision
D5b).  The image property must survive: only the guide is dropped."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 2000 800))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'manual)
              (seshat-reader--apply-display-scale window)
              (seshat-reader--center-page window)
              (should (> (image-property (seshat-reader--multipage-page-spec 1)
                                         :width)
                         (window-body-width window t)))
              (should-not (seshat-reader-multipage-test--guide 1))
              (should (eq (seshat-reader-multipage-test--image 1)
                          (seshat-reader--multipage-page-spec 1)))
              (should-not (seshat-reader--multipage-page-centered-p 1))
              ;; 贴左也是「已就位」，否则 pre-redisplay 每帧都会重写它
              (should (seshat-reader--centered-p window)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-batch-apply-crops-to-window-width ()
  "In `contain' mode no visible page is wider than the window after an apply.

A wide page is cropped by width while a narrow one keeps the base scale, and
both keep the spec object their row already referenced, so the centring
follows the new size without rebuilding any row."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 第 2 页换成比窗口宽得多的页
              (let ((wide (list 'image :type 'canvas :data nil
                                :data-width 1200 :data-height 800
                                :width 1200 :height 800)))
                (seshat-reader--multipage-insert-page 2 wide)
                (seshat-reader--multipage-record-native 2 wide 1.0))
              (let ((specs (list (seshat-reader--multipage-page-spec 1)
                                 (seshat-reader--multipage-page-spec 2))))
                (should (seshat-reader--apply-display-scale window))
                (dolist (page '(1 2))
                  (should (<= (image-property (seshat-reader--multipage-page-spec page)
                                              :width)
                              (window-body-width window t)))
                  (should (eq (seshat-reader-multipage-test--align-spec page)
                              (seshat-reader--multipage-page-spec page))))
                ;; align-to 引用的仍是同一批对象（原地改尺寸，不换对象）
                (should (eq (nth 0 specs) (seshat-reader--multipage-page-spec 1)))
                (should (eq (nth 1 specs) (seshat-reader--multipage-page-spec 2)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-target-scale-contain-mode ()
  "`contain' is `min (base scale, width fit of that page)'.

Three data points pin the row of the D5 table: the base scale when the page
fits, the width fit when the base scale would overflow the window, and the
width fit of a page that is wider than the window at scale 1.0 (the crop)."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 1.0))
                         1e-9))
              (setq seshat-reader--multipage-base-scale 2.0)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 (/ 1000.0 600)))
                         1e-9))
              (let ((wide (list 'image :type 'canvas :data nil
                                :data-width 2000 :data-height 800
                                :width 2000 :height 800)))
                (seshat-reader--multipage-insert-page 2 wide)
                (seshat-reader--multipage-record-native 2 wide 1.0))
              (setq seshat-reader--multipage-base-scale 1.0)
              (should (< (abs (- (seshat-reader--multipage-target-scale 2 window)
                                 0.5))
                         1e-9)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-target-scale-width-mode ()
  "`width' ignores the base scale and the page height.

Every page is fitted to its own width, so pages of different widths all end up
exactly as wide as the window; a page taller than the window is expected and
does not change the answer."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 400
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'width
                    seshat-reader--multipage-base-scale 0.3)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 (/ 1000.0 600)))
                         1e-9)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-target-scale-height-mode-does-not-crop ()
  "`height' fits the height and leaves an overwide page overwide.

That is the pre-existing `fit-to-height' semantics decision D5 keeps: the page
is scaled on both dimensions, so a wide page overflows horizontally, gets left
aligned and is reached with the horizontal scroll commands."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 2000 800))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 1600
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'height)
              ;; 1600/800 = 2.0 → 页宽 4000，远宽于 1000 的窗口
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 2.0))
                         1e-9))
              (seshat-reader--apply-display-scale window)
              (should (> (image-property (seshat-reader--multipage-page-spec 1)
                                         :width)
                         (window-body-width window t)))
              (should-not (seshat-reader--multipage-page-should-center-p 1)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-target-scale-manual-mode ()
  "`manual' is the base scale itself, applied to every page unchanged.

The `+' / `-' zoom never crops by width: an unreadably wide page is the user's
own choice, and the horizontal scroll is what makes it usable."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'manual
                    seshat-reader--multipage-base-scale 1.5)
              (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                 1.5))
                         1e-9))
              (should (< (abs (- (seshat-reader--multipage-target-scale 2 window)
                                 1.5))
                         1e-9))
              (seshat-reader--apply-display-scale window)
              (dolist (page '(1 2))
                (should (eql 900 (image-property
                                  (seshat-reader--multipage-page-spec page)
                                  :width)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-presentation-mode-round-trip ()
  "Presentation view fits the height and restores zoom, fit mode and mode line.

Entry scales every page to the window height (300x800 here) and hides the mode
line; exit puts the previous fit mode *and* the previous base scale back, so a
zoom the user had chosen is not silently replaced by the presentation one.

Both commands now refit synchronously, so the renderer is stubbed: without a
stub the pages would be re-rendered through the real module, which has no
document here and would leave the rows without a spec.
"
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2) 600 1600))
         (buffer (car fixture))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-multipage-test--fake-renderer
                          counter 600 1600)))
                (setq seshat-reader--multipage-fit-mode 'manual
                      seshat-reader--multipage-base-scale 2.0)
                (set-window-parameter window 'fit-mode 'manual)
                (seshat-reader--apply-display-scale window)
                (seshat-reader-presentation-mode 1)
                (should (eq 'height seshat-reader--multipage-fit-mode))
                (should (< (abs (- seshat-reader--multipage-base-scale 0.5)) 1e-9))
                (should-not mode-line-format)
                (should (eql 300 (image-property
                                  (seshat-reader--multipage-page-spec 1) :width)))
                ;; 进入后两页都已按目标分辨率重渲染（同步 refit）
                (should (< (abs (- (seshat-reader--multipage-render-scale 1) 0.5))
                           1e-9))
                (seshat-reader-presentation-mode -1)
                (should (eq 'manual seshat-reader--multipage-fit-mode))
                (should (< (abs (- seshat-reader--multipage-base-scale 2.0)) 1e-9))
                (should mode-line-format)
                (should (eql 1200 (image-property
                                   (seshat-reader--multipage-page-spec 1) :width)))
                (should (< (abs (- (seshat-reader--multipage-render-scale 1) 2.0))
                           1e-9))))))
      (set-window-parameter window 'fit-mode nil)
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-dark-mode-inverts-and-rerenders ()
  "Dark mode inverts the document once and renders every resident page again.

The inversion is document level (the native module repaints the bitmaps), so
the spec cache is stale for every page at once: dropping it and re-rendering
the resident pages is the only way the visible pages come back consistent."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (inverted nil)
         (rendered 0))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'seshat-reader-dyn--doc-invert)
                         (lambda (flag) (push flag inverted)))
                        ((symbol-function 'seshat-reader-dyn--doc-tint)
                         (lambda (&rest _) t))
                        ((symbol-function 'seshat-reader--multipage-rerender-page)
                         (lambda (&rest _) (cl-incf rendered))))
                (seshat-reader-dark-mode 1))
              (should (equal '(1) inverted))
              (should (= 3 rendered))
              (should-not seshat-reader--page-spec-cache)
              (setq rendered 0)
              (cl-letf (((symbol-function 'seshat-reader-dyn--doc-invert)
                         (lambda (flag) (push flag inverted)))
                        ((symbol-function 'seshat-reader-dyn--doc-tint)
                         (lambda (&rest _) t))
                        ((symbol-function 'seshat-reader--multipage-rerender-page)
                         (lambda (&rest _) (cl-incf rendered))))
                (seshat-reader-dark-mode -1))
              (should (equal '(0 1) inverted))
              (should (= 3 rendered)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-refit-covers-every-resident-page ()
  "A refit re-renders every resident page whose resolution is stale.

Only the pages whose recorded render scale differs from the target are
rendered, and each of them exactly once: the window is refitted as a whole,
not page by page as the viewport moves."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 400
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-fit-mode 'height)
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-multipage-test--fake-renderer counter)))
                (seshat-reader--refit-window window))
              (should (= 3 (car counter)))
              (dolist (page '(1 2 3))
                (should (< (abs (- (seshat-reader--multipage-render-scale page) 0.5))
                           1e-9)))
              ;; 已经清晰 → 再 refit 一次零渲染
              (setcar counter 0)
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-multipage-test--fake-renderer counter)))
                (seshat-reader--refit-window window))
              (should (= 0 (car counter))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-prefix-width-is-zero-and-hscroll-margin ()
  "There is no line prefix any more; the scrollable margin is page width minus window.

`--get-prefix-width' has to stay 0: it is the calibration constant of
`--set-window-hscroll', so a non-zero value would turn \"scroll to the left
edge\" into \"scroll to the right edge\".  The margin that actually exists is
reported by `--right-most-window-hscroll' from the widest page."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2) 1200 800))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should (= 0 (seshat-reader--get-prefix-width window)))
              (should (= 1200 (seshat-reader--multipage-max-page-width)))
              (should (= 200 (seshat-reader--right-most-window-hscroll window)))
              (seshat-reader--multipage-set-scale 0.5 'manual 'manual)
              (should (= 0 (seshat-reader--right-most-window-hscroll window))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-center-page-keeps-buffer-text-untouched ()
  "Centring writes text properties only: no text, no window start, no point.

The buffer of a reader holds the document layout, so a centring command that
inserted or deleted anything would move every page marker and the scroll
position; the guide property is the only thing that may change."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let ((text (buffer-string))
                    (start (window-start window))
                    (point (point)))
                (seshat-reader--multipage-set-page-centered 1 nil)
                (cl-letf (((symbol-function 'set-window-hscroll)
                           (lambda (&rest _args) 0)))
                  (seshat-reader--center-page window))
                (should (equal text (buffer-string)))
                (should (= start (window-start window)))
                (should (= point (point)))
                (should (consp (seshat-reader-multipage-test--guide 1)))
                (should (seshat-reader--centered-p window))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-native-sizes-are-per-page ()
  "Native sizes are measured and cached per page, not per window.

Two pages of one document may differ in size, and the recorded value must
survive a display resize (it is the measurement, not the current spec size);
recycling a page drops its measurement so the page is measured again when it
comes back at a different rotation."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1)))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (let ((tall (list 'image :type 'canvas :data nil
                                :data-width 800 :data-height 600
                                :width 800 :height 600)))
                (seshat-reader--multipage-insert-page 2 tall)
                (seshat-reader--multipage-record-native 2 tall 1.0))
              (should (equal (cons 600.0 800.0)
                             (seshat-reader--multipage-native-size 1)))
              (should (equal (cons 800.0 600.0)
                             (seshat-reader--multipage-native-size 2)))
              ;; 显示尺寸改变不影响测量值
              (seshat-reader--apply-display-scale window 0.5)
              (should (equal (cons 600.0 800.0)
                             (seshat-reader--multipage-native-size 1)))
              ;; 回收第 2 页 → 测量值一起丢掉
              (seshat-reader--multipage-recycle-page 2)
              (should-not (seshat-reader--multipage-native-size 2))
              (should (equal (cons 600.0 800.0)
                             (seshat-reader--multipage-native-size 1))))))
      (kill-buffer buffer))))

;;;; T4-fix（像素级连续滚动）：一页一行的布局下 `scroll-up' 会整页跳，改为像素滚动

;; 每个用例都把「窗口」桩成：页高 500px、默认行高 10px、窗口体高 800px，并用一层
;; cl-letf 替掉 `window-start' / `set-window-start' / `window-vscroll' /
;; `set-window-vscroll' / `frame-char-height' / `--multipage-sync'，这样滚动结果
;; （视口在第几页、页内偏移多少像素）可以精确断言，且不需要真实 redisplay。

(defun seshat-reader-multipage-test--row-position (page)
  "Return the buffer position of the row of PAGE in the current buffer."
  (seshat-reader-multipage-test--row-start page))

(defconst seshat-reader-multipage-test--scroll-line-height 10
  "Stubbed `frame-char-height' in the scroll tests.

Stands for the height of a normal text line.  The scroll code must take its
one-line unit from here and never from `line-pixel-height', which on a page row
reports the whole page height (2400px on a real frame) — the bug that turned a
one-line scroll into a page turn.")

(defvar seshat-reader-multipage-test--scroll-offset 0
  "Simulated pixel vertical scroll of the window in the scroll tests.")

(defvar seshat-reader-multipage-test--scroll-start nil
  "Simulated `window-start' of the window in the scroll tests.")

(defvar seshat-reader-multipage-test--scroll-starts nil
  "Positions `set-window-start' was called with, newest first.")

(defvar seshat-reader-multipage-test--scroll-vscrolls nil
  "Values `set-window-vscroll' was called with, newest first.")

(defvar seshat-reader-multipage-test--scroll-syncs 0
  "How many times `--multipage-sync' was called.")

(defvar seshat-reader-multipage-test--scroll-redisplays 0
  "How many times `redisplay' was called by the code under test.

A forced redisplay is expensive, so only the page-crossing path may ask for
one: the scroll code flushes a frame there so that the new window start lands
before the pixel scroll is written (Emacs drops a scroll that is set in the
same frame as a new window start).  Scrolling inside a page must leave this
at 0.")

(defmacro seshat-reader-multipage-test--with-scroll-stubs (&rest body)
  "Run BODY with a stubbed window: no redisplay, recorded scroll calls.

The simulated window is described by the `--scroll-*' variables above; the
macro records the calls instead of applying them, so a test can assert both
\"which page the viewport moved to\" (via `set-window-start') and \"how many
pixels inside that page\" (via `set-window-vscroll').

Only `frame-char-height' is stubbed as the line height: `line-pixel-height' is
left to the real implementation, so a scroll that went back to measuring the
line under point would be caught instead of silently matching the stub."
  (declare (indent 0) (debug t))
  `(let ((seshat-reader-multipage-test--scroll-starts nil)
         (seshat-reader-multipage-test--scroll-vscrolls nil)
         (seshat-reader-multipage-test--scroll-syncs 0)
         (seshat-reader-multipage-test--scroll-redisplays 0))
     (cl-letf (((symbol-function 'window-start)
                (lambda (&optional _window)
                  seshat-reader-multipage-test--scroll-start))
               ((symbol-function 'set-window-start)
                (lambda (_window pos &optional _noforce)
                  (push pos seshat-reader-multipage-test--scroll-starts)
                  (setq seshat-reader-multipage-test--scroll-start pos)
                  pos))
               ((symbol-function 'window-vscroll)
                (lambda (&optional _window _pixels-p)
                  seshat-reader-multipage-test--scroll-offset))
               ((symbol-function 'set-window-vscroll)
                (lambda (_window value &optional _pixels-p)
                  (push value seshat-reader-multipage-test--scroll-vscrolls)
                  (setq seshat-reader-multipage-test--scroll-offset value)
                  value))
               ((symbol-function 'frame-char-height)
                (lambda (&optional _frame)
                  seshat-reader-multipage-test--scroll-line-height))
               ((symbol-function 'seshat-reader--multipage-sync)
                (lambda (&optional _window)
                  (setq seshat-reader-multipage-test--scroll-syncs
                        (1+ seshat-reader-multipage-test--scroll-syncs))
                  nil))
               ((symbol-function 'redisplay)
                (lambda (&optional _force _frame)
                  (setq seshat-reader-multipage-test--scroll-redisplays
                        (1+ seshat-reader-multipage-test--scroll-redisplays))
                  nil)))
       ,@body)))

(defun seshat-reader-multipage-test--scroll-fixture (pages)
  "Create a geometry buffer of PAGES 400x500 pages, ready for scrolling.

The document page count is set to the number of pages so that
`--multipage-page-neighbour' stops at the last page instead of clamping to a
page number the document does not have."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer pages 400 500))
         (buffer (car fixture)))
    (with-current-buffer buffer
      (setq-local seshat-reader-current-doc-pagecount (length pages)))
    buffer))

;;;; 用例

(ert-deftest seshat-reader-multipage-test--geometry-scroll-down-stays-inside-page ()
  "A scroll shorter than the rest of the page only moves the pixel offset.

No page change means no `set-window-start': moving the window start would land
the viewport on a line start, which cannot express \"half a page\"."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 100)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 130 (seshat-reader--multipage-scroll 30)))
                (should (= 130 seshat-reader-multipage-test--scroll-offset))
                (should-not seshat-reader-multipage-test--scroll-starts)
                ;; 滚动后必须同步一次驻留页
                (should (= 1 seshat-reader-multipage-test--scroll-syncs))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-down-crosses-one-page ()
  "Scrolling past the bottom of a page moves the viewport to the next page row.

The remainder of the distance becomes the pixel offset of the new page, which
is what makes the transition continuous instead of a jump to the page top.
Point follows the viewport to the row of the page below: the row start of page
2 is cut off by the 50px offset, and a point on a row that the offset pushed
out of sight would let the redisplay drop that offset again."
  ;; T13：本用例断言「页高即 span」的旧口径，把分隔区关掉做隔离。绑定必须在
  ;; 建 fixture **之前**生效（分隔行是插入页行时生成的），而 `let' 的初值先
  ;; 全部求值再绑定，所以这里用 `let*'。
  (let* ((seshat-reader-page-separator nil)
         (buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 450)
              (seshat-reader-multipage-test--with-scroll-stubs
                ;; 450 + 100 = 550 → 跨过 500px 的第 1 页，余 50px。第 3 页必须
                ;; 存在：末页的页内偏移受窗口高约束（页高 500 < 窗高 800 →
                ;; 上限 0），落在末页会把 50px 的余量夹成 0。
                (should (= 50 (seshat-reader--multipage-scroll 100)))
                (should (= 50 seshat-reader-multipage-test--scroll-offset))
                (should (equal (list (seshat-reader-multipage-test--row-position 2))
                               seshat-reader-multipage-test--scroll-starts))
                (should (= (seshat-reader-multipage-test--row-position 2)
                           seshat-reader-multipage-test--scroll-start))
                ;; point 落到视口里可见的下一个页行行首（第 3 页）
                (should (= (seshat-reader-multipage-test--row-position 3)
                           (point)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-down-crosses-two-pages ()
  "A long scroll crosses several pages in one call, keeping the last remainder.

1100px from 400px into page 1 lands 100px into page 3: the loop subtracts one
page span per iteration instead of stopping at the first page change.  Page 4 is
there so that the remainder is not clamped by the last-page ceiling (a 500px page
in the stubbed 800px window allows 0), and point ends on the row of page 4, the
page below the viewport."
  ;; T13：同上，页间不留分隔区（绑定须先于 fixture 构造生效，故用 `let*'）。
  (let* ((seshat-reader-page-separator nil)
         (buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3 4))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 400)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 100 (seshat-reader--multipage-scroll 700)))
                (should (= 100 seshat-reader-multipage-test--scroll-offset))
                (should (= (seshat-reader-multipage-test--row-position 3)
                           seshat-reader-multipage-test--scroll-start))
                (should (= (seshat-reader-multipage-test--row-position 4)
                           (point)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-down-clamps-at-last-page ()
  "Scrolling far past the last page clamps instead of walking off the document.

The clamp is also what terminates the loop when there is no page left to
cross: without it the target would keep growing and the scroll would show the
blank space below the last page.  The last page is bounded by the window height
too (`seshat-reader--multipage-page-max-offset'): page 2 is 500px high while the
stubbed window body is 800px, so the page already fits the window and allows no
in-page offset at all."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 2)
                    seshat-reader-multipage-test--scroll-offset 450)
              (seshat-reader-multipage-test--with-scroll-stubs
                ;; 末页上限 = 页高 500 − 窗高 800 → 0（不再是 页高 − 1 = 499）
                (should (= 0 (seshat-reader--multipage-scroll 5000)))
                (should (= 0 seshat-reader-multipage-test--scroll-offset))
                (should (= (seshat-reader-multipage-test--row-position 2)
                           seshat-reader-multipage-test--scroll-start))
                (should-not seshat-reader-multipage-test--scroll-starts)
                ;; 不越界：没有第 3 页行，也没有多出来的占位页
                (should (equal '(1 2)
                               (seshat-reader-multipage-test--page-numbers)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-up-stays-inside-page ()
  "A short upward scroll only reduces the pixel offset.

The page does not change, so `set-window-start` stays untouched and the view
does not snap to the page top.  Page 2 is followed by page 3 on purpose: the last
page of a document is bounded by the window height, and a 500px page in the
stubbed 800px window would clamp the offset to 0 instead of 170."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 2)
                    seshat-reader-multipage-test--scroll-offset 200)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 170 (seshat-reader--multipage-scroll -30)))
                (should (= 170 seshat-reader-multipage-test--scroll-offset))
                (should-not seshat-reader-multipage-test--scroll-starts)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-up-crosses-to-previous-page ()
  "Scrolling above the top of a page lands inside the previous page.

Going up by 60px from 10px into page 2 lands 450px into page 1 (500 - 50), not
at the top of page 1: the distance crosses the page boundary by 50px and the
remainder is measured from the *bottom* of the previous page.  Point moves to the
row of page 2, i.e. to a row the scrolled viewport shows, instead of the row start
that the offset hides."
  ;; T13：页间分隔区关掉，span 保持「页高」的旧口径（绑定先于 fixture 构造）。
  (let* ((seshat-reader-page-separator nil)
         (buffer (seshat-reader-multipage-test--scroll-fixture '(1 2))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 2)
                    seshat-reader-multipage-test--scroll-offset 10)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 450 (seshat-reader--multipage-scroll -60)))
                (should (= 450 seshat-reader-multipage-test--scroll-offset))
                (should (equal (list (seshat-reader-multipage-test--row-position 1))
                               seshat-reader-multipage-test--scroll-starts))
                (should (= (seshat-reader-multipage-test--row-position 1)
                           seshat-reader-multipage-test--scroll-start))
                ;; point 落在顶页下方那一页（第 2 页）的行首
                (should (= (seshat-reader-multipage-test--row-position 2)
                           (point)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-up-clamps-at-first-page ()
  "Scrolling above the first page clamps the offset at 0.

There is no previous page row to move to, so the clamp — not a page change —
stops the scroll; the viewport stays on page 1 with no pixel offset."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 10)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 0 (seshat-reader--multipage-scroll -100)))
                (should (= 0 seshat-reader-multipage-test--scroll-offset))
                (should-not seshat-reader-multipage-test--scroll-starts)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-screen-scroll-crosses-page ()
  "A screen scroll crosses a page and keeps its large remainder on screen.

`SPC' / `DEL' move by a whole screen (790px here: the 800px body minus one context
line), so the remainder after a page cross is close to a whole page: 100 + 790
crosses the 500px first page and leaves 390px of page 2 as the pixel offset.  That
offset is far larger than one text line, so point has to follow the viewport to the
row of page 3; leaving it on the row start of page 2 would let the redisplay drop
the whole offset."
  ;; T13：SPC/DEL 的跨页余量按「页高即 span」断言，关闭分隔区隔离。
  (let* ((seshat-reader-page-separator nil)
         (buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3)))
         (next-screen-context-lines 1))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 100)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 790 (seshat-reader--scroll-screen-pixels
                                (selected-window))))
                (seshat-reader-scroll-down-screen)
                (should (= 390 seshat-reader-multipage-test--scroll-offset))
                (should (equal (list (seshat-reader-multipage-test--row-position 2))
                               seshat-reader-multipage-test--scroll-starts))
                (should (= (seshat-reader-multipage-test--row-position 3)
                           (point)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-up-crosses-page-with-gap ()
  "Crossing a page upwards leads point to the next page row, never to a gap line.

With `seshat-reader-page-gap-lines` > 0 the line after a page row is one of the gap
lines of that page, so `(forward-line 1)` would leave point on a line whose screen
position is `page height - vscroll` -- above the top of the window after an upward
cross, which lets the redisplay drop the offset again.  The row of the page below
(page 2 here) is the only correct landing place."
  ;; T13：本用例只测 gap 空行，页间分隔区关掉（span = 页高 + gap）。
  (let ((seshat-reader-page-gap-lines 2)
        (seshat-reader-page-separator nil)
        (buffer nil))
    (unwind-protect
        (progn
          ;; gap 行在插入页行时生成，必须在建 fixture 之前绑定
          (setq buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3)))
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (let ((gap-line (save-excursion
                                  (goto-char
                                   (seshat-reader-multipage-test--row-position 1))
                                  (point))))
                  ;; fixture 真的有 gap 空行：第 1 页页行之后还不是第 2 页页行
                  (should-not (= gap-line
                                 (seshat-reader-multipage-test--row-position 2)))
                  (setq seshat-reader-multipage-test--scroll-start
                        (seshat-reader-multipage-test--row-position 2)
                        seshat-reader-multipage-test--scroll-offset 10)
                  (seshat-reader-multipage-test--with-scroll-stubs
                    ;; span = 500 + 2 × 10 = 520；10 − 60 → 上一页页内余 470
                    (should (= 470 (seshat-reader--multipage-scroll -60)))
                    (should (= 470 seshat-reader-multipage-test--scroll-offset))
                    (should (= (seshat-reader-multipage-test--row-position 1)
                               seshat-reader-multipage-test--scroll-start))
                    (should (= (seshat-reader-multipage-test--row-position 2)
                               (point)))
                    (should-not (= gap-line (point)))))))))
      (when buffer (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-syncs-before-vscroll ()
  "A crossed page is flushed before the pixel scroll is written.

Two Emacs behaviours shape this order: `seshat-reader--multipage-sync` inserts or
recycles page rows, and modifying the buffer invalidates the window state and
clears the pixel scroll that was just set; and a pixel scroll set in the same
frame as a *new* `window-start` is dropped as well (measured on a real frame:
3090 -> 0, while the same offset applied after the new start had been displayed
survived).  The crossing path therefore zeroes the old offset, sets the new
start, syncs, forces one `redisplay` and only then writes the offset.  What is
asserted here is the recorded *order* of those calls, not just that they happen."
  ;; T13：只断言调用顺序，几何仍按「页高即 span」的旧口径 → 关闭分隔区。
  (let* ((seshat-reader-page-separator nil)
         (buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3)))
         (events nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 450)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window)
                           seshat-reader-multipage-test--scroll-start))
                        ((symbol-function 'set-window-start)
                         (lambda (_window pos &optional _noforce)
                           (push (cons 'set-window-start pos) events)
                           pos))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels-p)
                           seshat-reader-multipage-test--scroll-offset))
                        ((symbol-function 'set-window-vscroll)
                         (lambda (_window value &optional _pixels-p)
                           (push (cons 'set-window-vscroll value) events)
                           (setq seshat-reader-multipage-test--scroll-offset value)
                           value))
                        ((symbol-function 'redisplay)
                         (lambda (&optional _force _frame)
                           (push (cons 'redisplay nil) events)
                           nil))
                        ((symbol-function 'seshat-reader--multipage-sync)
                         (lambda (&optional _window)
                           (push (cons 'sync nil) events)
                           nil))
                        ((symbol-function 'frame-char-height)
                         (lambda (&optional _frame)
                           seshat-reader-multipage-test--scroll-line-height)))
                ;; 跨页一次：450 + 100 跨过第 1 页，余 50
                (should (= 50 (seshat-reader--multipage-scroll 100)))
                (setq events (nreverse events))
                (should (equal '(set-window-vscroll set-window-start sync
                                 redisplay set-window-vscroll)
                               (mapcar #'car events)))
                ;; 旧页偏移先清零，避免把它带进新页那一帧
                (should (= 0 (cdr (nth 0 events))))
                ;; 新 start 落在第 2 页页行，然后才落帧
                (should (= (seshat-reader-multipage-test--row-position 2)
                           (cdr (nth 1 events))))
                ;; 落帧之后才写 clamp 后的最终偏移
                (should (= 50 (cdr (nth 4 events))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-inside-page-does-not-redisplay ()
  "Scrolling inside a page never forces a frame.

The forced `redisplay` exists only to give a new window start its own frame
before the pixel scroll is written; an in-page scroll uses the window it already
has, so it must not pay for a frame (and must not flash one)."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 100)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= 130 (seshat-reader--multipage-scroll 30)))
                (should (= 130 seshat-reader-multipage-test--scroll-offset))
                (should-not seshat-reader-multipage-test--scroll-starts)
                (should (= 0 seshat-reader-multipage-test--scroll-redisplays))
                (should (= 1 seshat-reader-multipage-test--scroll-syncs))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-place-point-ignores-small-offset ()
  "An offset of at most one text line leaves point on the page row start.

A small pixel offset only cuts a sliver off the page row, so the cursor stays
visible and Emacs keeps the scroll: point stays on the row start of the page at the
top of the window (the old behaviour) instead of moving to the row of the page
below.  One pixel more than a text line is already enough to move it."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-scroll-stubs
                ;; 行高桩为 10px：5px 与 10px 都不超过一行
                (dolist (vscroll (list 5 seshat-reader-multipage-test--scroll-line-height))
                  (goto-char (point-max))
                  (seshat-reader--multipage--place-point (selected-window) 1 vscroll)
                  (should (= (seshat-reader-multipage-test--row-position 1)
                             (point))))
                ;; 11px > 一行 → 落到第 2 页页行行首
                (goto-char (point-max))
                (seshat-reader--multipage--place-point (selected-window) 1 11)
                (should (= (seshat-reader-multipage-test--row-position 2)
                           (point)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-place-point-needs-next-page-row ()
  "Without a row for the page below, point stays on the current page row.

`seshat-reader--multipage--place-point` runs after `seshat-reader--multipage-sync`
settled the resident set, so it must not render the missing page: the row of the
page below is looked up in the resident set, and when it is absent point goes to
the row start of the page at the top of the window while no page row is added."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader--multipage-recycle-page 2)
              (should (equal '(1 3) (seshat-reader-multipage-test--page-numbers)))
              (goto-char (point-max))
              (seshat-reader-multipage-test--with-scroll-stubs
                (seshat-reader--multipage--place-point (selected-window) 1 400)
                (should (= (seshat-reader-multipage-test--row-position 1)
                           (point)))
                ;; 没有渲染出来的第 2 页行：驻留集原样
                (should (equal '(1 3)
                               (seshat-reader-multipage-test--page-numbers)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-apply-offset-after-redisplay ()
  "The offset is written only after a frame has been forced.

Confirmed on a real frame: a pixel scroll set in the same frame as a new window
start is dropped (3090 -> 0), so a restore path has to display the new start
first.  What is asserted here is the recorded *order* of the two calls plus the
arguments the scroll is written with: a nil WINDOW is resolved to the selected
window, the same reading `seshat-reader--multipage-scroll' uses."
  (let ((events nil))
    (cl-letf (((symbol-function 'redisplay)
               (lambda (&optional _force _frame)
                 (push (list 'redisplay nil) events)
                 nil))
              ((symbol-function 'set-window-vscroll)
               (lambda (&rest args)
                 (push (cons 'set-window-vscroll args) events)
                 nil)))
      (seshat-reader--multipage--apply-offset nil 120))
    (setq events (nreverse events))
    (should (equal '(redisplay set-window-vscroll) (mapcar #'car events)))
    ;; 实参：解析后的窗口（selected window）+ 偏移 + 像素模式
    (should (equal (list (selected-window) 120 t)
                   (cdr (nth 1 events))))))

(ert-deftest seshat-reader-multipage-test--geometry-apply-offset-skips-invalid ()
  "A non-positive or non-numeric offset costs neither a scroll nor a frame.

The guard inside the tool replaced the `ignore-errors' the callers used to
wrap the write with: an offset that cannot be written is rejected *before* the
forced frame, so restoring a record without a usable offset neither signals nor
flashes the page for nothing."
  (let ((events nil))
    (cl-letf (((symbol-function 'redisplay)
               (lambda (&optional _force _frame)
                 (push 'redisplay events)
                 nil))
              ((symbol-function 'set-window-vscroll)
               (lambda (&rest _args)
                 (push 'set-window-vscroll events)
                 nil)))
      (dolist (offset (list 0 -5 "x"))
        (seshat-reader--multipage--apply-offset nil offset)))
    (should-not events)))

(ert-deftest seshat-reader-multipage-test--geometry-page-max-offset-last-page-bounds ()
  "The last page is bounded by the window height, every other page by the span.

A last page taller than the window stops when its bottom reaches the bottom of the
window, i.e. at `page height - window body height`; a last page that already fits
the window allows no in-page offset at all; a page with a follower keeps the old
ceiling of `span - 1`.  The window body is stubbed to 800px, so the 1000px page
allows 200px and the 500px page 0.  The document page count is what tells the last
page apart, so every buffer sets it the way the native module does."
  ;; T13：span 的口径要可预测，页间分隔区一律关掉；三个子块的 fixture 都要在
  ;; 绑定之内构造，故都改成 `let*'。
  (seshat-reader-multipage-test--window-pixels 1000 800
    ;; 末页高于窗口：1000 − 800 = 200
    (let* ((seshat-reader-page-separator nil)
           (tall (seshat-reader-multipage-test--geometry-buffer '(1) 400 1000)))
      (unwind-protect
          (with-current-buffer (car tall)
            (setq-local seshat-reader-current-doc-pagecount 1)
            (should (= 200 (seshat-reader--multipage-page-max-offset 1))))
        (kill-buffer (car tall))))
    ;; 末页矮于窗口：0
    (let* ((seshat-reader-page-separator nil)
           (short (seshat-reader-multipage-test--geometry-buffer '(1) 400 500)))
      (unwind-protect
          (with-current-buffer (car short)
            (setq-local seshat-reader-current-doc-pagecount 1)
            (should (= 0 (seshat-reader--multipage-page-max-offset 1))))
        (kill-buffer (car short))))
    ;; 非末页：span − 1 = 499；同一 buffer 的末页：0
    (let* ((seshat-reader-page-separator nil)
           (pair (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
      (unwind-protect
          (with-current-buffer (car pair)
            (setq-local seshat-reader-current-doc-pagecount 2)
            (should (= 499 (seshat-reader--multipage-page-max-offset 1)))
            (should (= 0 (seshat-reader--multipage-page-max-offset 2))))
        (kill-buffer (car pair))))))

(ert-deftest seshat-reader-multipage-test--geometry-screen-scroll-pixels ()
  "One screen is the window body height minus the context lines, in pixels.

`SPC' / `DEL' must scroll a screen, not a step and not a whole page: the
distance is computed from the pixel body height, so it does not depend on
`seshat-reader-scroll-step-ratio' — the ratio is bound to 0.5 here and the
answer must still be 790."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (captured nil)
        (next-screen-context-lines 1)
        (seshat-reader-scroll-step-ratio 0.5)
        (seshat-reader-scroll-step-pixels nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 10))
                        ((symbol-function 'seshat-reader--multipage-scroll)
                         (lambda (pixels &optional _window)
                           (push pixels captured) pixels)))
                (seshat-reader-scroll-down-screen)
                (seshat-reader-scroll-up-screen)
                ;; 800 - 1 * 10 = 790
                (should (equal '(790 -790) (reverse captured)))
                (should (= 790 (seshat-reader--scroll-screen-pixels
                                (selected-window))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-mwheel-scales-with-notch ()
  "One wheel notch is one scroll step; double and triple notches are two and three.

The step is the ratio of the window text height here (0.15 × 800px = 120px), and
the notch count multiplies it: 120 / 240 / 360 downwards and the same upwards.
The wheel must never turn the page, so what is recorded is the distance handed
to `seshat-reader--multipage-scroll', not a page number."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (captured nil)
        (window (selected-window))
        (seshat-reader-scroll-step-ratio 0.15)
        (seshat-reader-scroll-step-pixels nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 20))
                        ((symbol-function 'seshat-reader--multipage-scroll)
                         (lambda (pixels &optional _window)
                           (push pixels captured) pixels)))
                (dolist (type '(wheel-down double-wheel-down triple-wheel-down))
                  (seshat-reader--non-queue-mwheel-scroll-down
                   (list type (list window 1 (list 1 1) nil 0))))
                (dolist (type '(wheel-up double-wheel-up triple-wheel-up))
                  (seshat-reader--non-queue-mwheel-scroll-up
                   (list type (list window 1 (list 1 1) nil 0))))
                (should (equal '(120 240 360 -120 -240 -360) (reverse captured)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-goto-resets-vscroll ()
  "A page jump lands on the top of the page, whatever offset was left.

Scrolling leaves a pixel offset inside the page it shows; `n' / `p' / `M-g g'
must not inherit it, otherwise jumping to a page would show it already
scrolled by however far the previous page was scrolled."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 321)
              (seshat-reader-multipage-test--with-scroll-stubs
                (should (= (seshat-reader-multipage-test--row-position 3)
                           (seshat-reader--multipage-goto 3)))
                (should (= 0 seshat-reader-multipage-test--scroll-offset))
                (should (equal '(0) seshat-reader-multipage-test--scroll-vscrolls))
                (should (= (seshat-reader-multipage-test--row-position 3)
                           seshat-reader-multipage-test--scroll-start))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-uses-pixel-vscroll ()
  "Every vertical scroll is set in pixel mode, never in lines.

`set-window-vscroll' measures lines unless the PIXELS argument is non-nil, so a
scroll that forgot it would be applied on a completely different scale (a
\"1\" would mean one whole line, i.e. a whole page here)."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (calls nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader-multipage-test--scroll-start
                    (seshat-reader-multipage-test--row-position 1)
                    seshat-reader-multipage-test--scroll-offset 0)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window)
                           seshat-reader-multipage-test--scroll-start))
                        ((symbol-function 'set-window-start)
                         (lambda (&rest _args) nil))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels-p) 0))
                        ((symbol-function 'set-window-vscroll)
                         (lambda (_window value &optional pixels-p)
                           (push (cons value pixels-p) calls)
                           value))
                        ((symbol-function 'frame-char-height) (lambda (&optional _frame) 10))
                        ((symbol-function 'seshat-reader--multipage-sync)
                         (lambda (&optional _window) nil)))
                (seshat-reader--multipage-scroll 25))
              (should (equal '((25 . t)) calls)))))
      (kill-buffer buffer))))

;;;; T4-fix2：滚动量必须用 frame 默认行高，不能用 `line-pixel-height'

;; 真机实测：多页布局里点所在行就是页行，`(line-pixel-height)' 返回整页高度
;; （2414px），于是「滚一行」= 滚一整页、`window-vscroll' 恒为 0、每次按键翻页。
;; 这三个用例把 `line-pixel-height' 桩成**页高**、把 `frame-char-height' 桩成真正
;; 的行高，因此一旦有人把取值改回 `line-pixel-height'，断言立刻变红。

(ert-deftest seshat-reader-multipage-test--geometry-scroll-step-ratio-scales-with-window ()
  "One scroll step is the ratio of the window text height, not a page.

`window-body-height' is stubbed to 800px and the ratio to 0.15, so a step is
120px.  `line-pixel-height' is stubbed to the page height (500px), which is what
a real frame answers on a page row: the step must not consult it, otherwise one
keypress moves a whole page and the pixel offset never grows."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (calls nil)
        (starts 0)
        (seshat-reader-scroll-step-ratio 0.15)
        (seshat-reader-scroll-step-pixels nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window)
                           (seshat-reader-multipage-test--row-position 1)))
                        ((symbol-function 'set-window-start)
                         (lambda (&rest _args) (setq starts (1+ starts)) nil))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels-p) 0))
                        ((symbol-function 'set-window-vscroll)
                         (lambda (_window value &optional pixels-p)
                           (push (cons value pixels-p) calls) value))
                        ;; 页行上的「真实」行高 = 整页高度
                        ((symbol-function 'line-pixel-height) (lambda () 500))
                        ((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 20))
                        ((symbol-function 'seshat-reader--multipage-sync)
                         (lambda (&optional _window) nil)))
                (seshat-reader-scroll-down 1)
                (should (= 120 (seshat-reader--scroll-step-pixels
                                (selected-window)))))
              (should (equal '((120 . t)) calls))
              (should (= 0 starts)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-step-absolute-pixels-wins ()
  "`seshat-reader-scroll-step-pixels' overrides the ratio.

With the window 800px tall the ratio (0.15) would give 120px per step; the
absolute value 37 must win, and the amount argument must still multiply it
\(so two steps are 74px on top of the current offset)."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (calls nil)
        (seshat-reader-scroll-step-ratio 0.15)
        (seshat-reader-scroll-step-pixels 37))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window)
                           (seshat-reader-multipage-test--row-position 1)))
                        ((symbol-function 'set-window-start)
                         (lambda (&rest _args) nil))
                        ((symbol-function 'window-vscroll)
                         (lambda (&optional _window _pixels-p)
                           seshat-reader-multipage-test--scroll-offset))
                        ((symbol-function 'set-window-vscroll)
                         (lambda (_window value &optional pixels-p)
                           (push (cons value pixels-p) calls)
                           (setq seshat-reader-multipage-test--scroll-offset value)
                           value))
                        ((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 20))
                        ((symbol-function 'seshat-reader--multipage-sync)
                         (lambda (&optional _window) nil)))
                ;; 全局模拟量由前面的用例留下过数值，先归零
                (setq seshat-reader-multipage-test--scroll-offset 0)
                (should (= 37 (seshat-reader--scroll-step-pixels
                               (selected-window))))
                (seshat-reader-scroll-down 1)
                (seshat-reader-scroll-down 2))
              ;; 37，然后 37 + 2 × 37 = 111（不是 120 / 360）
              (should (equal '((111 . t) (37 . t)) calls)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-step-falls-back-to-line-pixels ()
  "A ratio that cannot produce a pixel falls back to one default text line.

A ratio of 0, a non-number and a ratio so small that it rounds to 0 all have to
give `seshat-reader--default-line-pixels' (20px here): a step of 0 pixels would
make `j' silently do nothing instead of moving the view."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (seshat-reader-scroll-step-pixels nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 20))
                        ((symbol-function 'line-pixel-height) (lambda () 500)))
                (dolist (ratio (list 0 'x 0.00001))
                  (let ((seshat-reader-scroll-step-ratio ratio))
                    (should (= 20 (seshat-reader--scroll-step-pixels
                                   (selected-window))))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-screen-scroll-pixels-uses-default-line-height ()
  "One screen is the body height minus the context lines, in frame line heights.

With the page height (500) answered by `line-pixel-height' and the real line
height (20) by `frame-char-height', a screen of 800px and one context line must
give 780 — not 800 - 500 = 300, which is what the page-height confusion would
produce.

A screen is a viewful, not a step, so `seshat-reader-scroll-step-ratio' (bound
to 0.5 here, i.e. 400px if it were consulted) must not change the answer."
  (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
        (captured nil)
        (next-screen-context-lines 1)
        (seshat-reader-scroll-step-ratio 0.5)
        (seshat-reader-scroll-step-pixels nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'line-pixel-height) (lambda () 500))
                        ((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 20))
                        ((symbol-function 'seshat-reader--multipage-scroll)
                         (lambda (pixels &optional _window)
                           (push pixels captured) pixels)))
                (seshat-reader-scroll-down-screen)
                (should (= 780 (seshat-reader--scroll-screen-pixels
                                (selected-window)))))
              (should (equal '(780) captured)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-gap-pixels-uses-default-line-height ()
  "The page gap is measured in frame line heights, not in page heights.

An empty line after a page row has the default line height; measuring the line
under point would report the page height and make the scroll threshold wrong by
two orders of magnitude."
  ;; T13：本用例的期望值只含 gap 行，分隔区关掉（绑定先于 fixture 构造）。
  (let* ((seshat-reader-page-separator nil)
         (buffer (seshat-reader-multipage-test--scroll-fixture '(1 2)))
         (seshat-reader-page-gap-lines 2))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'line-pixel-height) (lambda () 500))
                        ((symbol-function 'frame-char-height)
                         (lambda (&optional _frame) 20)))
                ;; 2 行 × 20px（不是 2 × 500）
                (should (= 40 (seshat-reader--multipage-page-gap-pixels)))
                (should (= 500 (seshat-reader--multipage-page-pixel-height 1)))
                (should (= 540 (seshat-reader--multipage-page-span 1)))))))
      (kill-buffer buffer))))

;;;; T5：缩放口径（base × 系数 / W·H 基准页 / 首屏即清晰 / 跨页 scale 锚定）

;; 这些用例走真实缩放命令（`+` `-` `0` `W` `H` 与滚轮），因此必须桩掉
;; `seshat-reader-dyn--page-image-spec`：缩放会**同步** refit 驻留页，而真实渲染器
;; 在 batch 里没有文档，会返回 nil 并清空页行 spec。桩出来的 spec 按 scale 缩放，
;; 所以 native 尺寸（spec ÷ scale）保持稳定，页宽/页高断言才有意义。

(defmacro seshat-reader-multipage-test--with-fake-renderer (counter width height &rest body)
  "Run BODY with the per-page renderer stubbed to a counter.

COUNTER is a one-element list receiving the number of render requests; every
request returns a WIDTH x HEIGHT page scaled like the real renderer."
  (declare (indent 4) (debug t))
  `(cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
              (seshat-reader-multipage-test--fake-renderer ,counter ,width ,height)))
     ,@body))

(defmacro seshat-reader-multipage-test--with-silent-timers (&rest body)
  "Run BODY with the asynchronous render timers stubbed out.

Since T5 `seshat-reader--multipage-prefetch' queues a page and asks
`seshat-reader--schedule-async-render' to arm the idle and the periodic timer.
Arming real ones inside a batch test would leave a repeating timer behind for
the rest of the file, so every timer function is replaced by a no-op here; what
the timers are armed with, and what drives the queue, is asserted by
`seshat-reader-multipage-async-render-test.el'."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'run-with-idle-timer)
              (lambda (&rest _args) 'fake-idle-timer))
             ((symbol-function 'run-at-time)
              (lambda (&rest _args) 'fake-render-timer))
             ((symbol-function 'cancel-timer)
              (lambda (&rest _args) nil)))
     ,@body))

(defun seshat-reader-multipage-test--scale-fixture (pages width height)
  "Geometry buffer of PAGES WIDTH x HEIGHT pages, ready for the scale commands.

On top of `--geometry-buffer' it records the reference native size the way
`seshat-reader--first-fit' does and sets the document page count, so `W' /
`H' / `0' have a deterministic page to derive their base scale from."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer pages width height))
         (buffer (car fixture)))
    (with-current-buffer buffer
      (setq-local seshat-reader--multipage-reference-native
                  (cons (float width) (float height))
                  seshat-reader-current-doc-pagecount (length pages)))
    buffer))

(defun seshat-reader-multipage-test--page-width (page)
  "Return the displayed width of PAGE."
  (image-property (seshat-reader--multipage-page-spec page) :width))

(defun seshat-reader-multipage-test--page-height (page)
  "Return the displayed height of PAGE."
  (image-property (seshat-reader--multipage-page-spec page) :height))

(defun seshat-reader-multipage-test--all-sharp-p (window)
  "Return non-nil when every resident page was rendered at its target scale.

The comparison uses `seshat-reader--refit-scale-tolerance', i.e. the same
\"sharp enough\" notion the implementation refits on: the native size of a page
is the spec size divided by the scale it was rendered at, so rounding moves the
target by a fraction of a percent on every re-render."
  (let ((pages (seshat-reader--multipage-page-numbers))
        (ok t))
    (while (and pages ok)
      (let* ((page (car pages))
             (target (seshat-reader--multipage-target-scale page window))
             (rendered (seshat-reader--multipage-render-scale page)))
        (unless (and (numberp target) (numberp rendered)
                     (< (abs (- target rendered))
                        seshat-reader--refit-scale-tolerance))
          (setq ok nil)))
      (setq pages (cdr pages)))
    ok))

(defmacro seshat-reader-multipage-test--with-zoom-debounce-stub (&rest body)
  "Run BODY with the manual zoom re-render captured instead of armed.

A manual zoom (`+' / `-') re-renders the resident pages from an idle timer,
and a batch session has no idle time, so a real timer would never fire.  The
callback of the last timer armed for
`seshat-reader--run-pending-zoom-refit' is kept in the one-element list
`pending' as \\(FUNCTION . ARGS) and is run by
`seshat-reader-multipage-test--fire-zoom-refit'; `armed' counts those timers
and `cancelled' counts the ones `seshat-reader--schedule-zoom-refit'
cancelled.  Every other timer (the asynchronous render machinery) is armed as
an inert fake, exactly like `--with-silent-timers' does, so no real timer is
left behind by the test."
  (declare (indent 0) (debug t))
  `(let ((pending (list nil))
         (armed 0)
         (cancelled 0)
         (real-timerp (symbol-function 'timerp))
         (real-cancel (symbol-function 'cancel-timer)))
     (cl-letf* (((symbol-function 'timerp)
                 (lambda (object)
                   (or (and (consp object) (eq (car object) 'fake-zoom-timer))
                       (funcall real-timerp object))))
                ((symbol-function 'cancel-timer)
                 (lambda (timer)
                   (cond
                    ((and (consp timer) (eq (car timer) 'fake-zoom-timer))
                     (cl-incf cancelled) (setcar pending nil))
                    ;; 异步渲染的 timer 是同一套桩造出来的假对象：真实
                    ;; `cancel-timer' 会对它报 `wrong-type-argument timerp'，
                    ;; 这里按 `--with-silent-timers' 的口径静默丢弃。
                    ((and (consp timer)
                          (memq (car timer) '(fake-idle-timer fake-render-timer)))
                     nil)
                    (t (funcall real-cancel timer)))))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (delay repeat function &rest args)
                   (if (eq function 'seshat-reader--run-pending-zoom-refit)
                       (progn
                         (cl-incf armed)
                         (setcar pending (cons function args))
                         (list 'fake-zoom-timer delay repeat function args))
                     (list 'fake-idle-timer delay repeat function args)))))
       ,@body)))

(defun seshat-reader-multipage-test--fire-zoom-refit (pending)
  "Run the manual zoom re-render recorded in PENDING and clear it.

PENDING is the one-element list `--with-zoom-debounce-stub' fills; firing it
twice is a no-op, so a test can fire at one point and still see whether a
second timer was armed afterwards."
  (let ((call (car pending)))
    (when call
      (setcar pending nil)
      (apply (car call) (cdr call)))))

;;;; 用例

(ert-deftest seshat-reader-multipage-test--geometry-enlarge-multiplies-base-scale ()
  "`+' multiplies the base scale and re-renders every resident page once.

The base scale goes 1.0 -> 1.25 (`seshat-reader-enlarge-factor'), the fit mode
becomes `manual' (so no page is cropped for its own width) and every spec grows
by the same factor -- all of it before the command returns.  The pages
themselves are rendered exactly once each by the debounced re-render, which is
what makes the page sharp once the keypresses stop; nothing is rendered while
the timer is still pending."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0))
         (centers 0)
         (original-center (symbol-function 'seshat-reader--center-page)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 从 2.0 起而不是 1.0：这样「乘系数」与「拿系数当绝对 scale」
              ;; 会给出不同结果（2.5 vs 1.25），断言才真正钉住 D5 语义。
              (setq seshat-reader--multipage-base-scale 2.0)
              (seshat-reader--apply-display-scale window)
              (setcar counter 0)
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (cl-letf (((symbol-function 'seshat-reader--center-page)
                           (lambda (&optional window)
                             (setq centers (1+ centers))
                             (funcall original-center window))))
                  (seshat-reader-multipage-test--with-zoom-debounce-stub
                    (seshat-reader-enlarge-size)
                    ;; 命令返回时：scale / 模式 / spec 尺寸已就位，像素未动
                    (should (< (abs (- seshat-reader--multipage-base-scale 2.5)) 1e-9))
                    (should (eq 'manual seshat-reader--multipage-fit-mode))
                    (should (= 1 centers))
                    (should (= 0 (car counter)))
                    (dolist (page '(1 2 3))
                      (should (eql 1500 (seshat-reader-multipage-test--page-width page)))
                      (should (eql 2000 (seshat-reader-multipage-test--page-height page))))
                    ;; 去抖回调：三页各重渲染一次（不是每页两次，也不是只渲染顶页）
                    (should (= 1 armed))
                    (seshat-reader-multipage-test--fire-zoom-refit pending)
                    (should (= 3 (car counter)))
                    (dolist (page '(1 2 3))
                      (should (< (abs (- (seshat-reader--multipage-render-scale page) 2.5))
                                 1e-9)))
                    (should (seshat-reader-multipage-test--all-sharp-p window)))))))
      (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--geometry-shrink-multiplies-base-scale ()
  "`-' multiplies the base scale by `seshat-reader-shrink-factor'.

Mirroring `+': 1.0 -> 0.75, mode `manual' and every spec scaled by 0.75 before
the command returns; every page is then rendered once at the new resolution by
the debounced re-render."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 同样从 2.0 起：0.75 作为乘数给 1.5，作为绝对 scale 给 0.75
              (setq seshat-reader--multipage-base-scale 2.0)
              (seshat-reader--apply-display-scale window)
              (setcar counter 0)
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (seshat-reader-shrink-size)
                  ;; 命令返回时：scale / 模式 / spec 尺寸已就位，像素未动
                  (should (< (abs (- seshat-reader--multipage-base-scale 1.5)) 1e-9))
                  (should (eq 'manual seshat-reader--multipage-fit-mode))
                  (should (= 0 (car counter)))
                  (dolist (page '(1 2))
                    (should (eql 900 (seshat-reader-multipage-test--page-width page)))
                    (should (eql 1200 (seshat-reader-multipage-test--page-height page))))
                  ;; 去抖回调：两页各重渲染一次
                  (seshat-reader-multipage-test--fire-zoom-refit pending)
                  (should (= 2 (car counter))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-reset-size-re-fits-like-first-fit ()
  "`0' drops the manual zoom and re-fits the way the document was opened.

After a `+' the base scale is 1.25; `0' must bring it back to the fit of the
reference page under the initial fit mode -- `contain' gives 1.0 here, and a
`width' default gives 1000/600 -- instead of the old \"scale 1.0\" behaviour,
which ignored the document's geometry."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (unwind-protect
                  (progn
                    (set-window-parameter window 'fit-mode nil)
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader-enlarge-size)
                      (let ((seshat-reader-default-fit 'contain))
                        (seshat-reader-reset-size))
                      (should (eq 'contain seshat-reader--multipage-fit-mode))
                      (should (< (abs (- seshat-reader--multipage-base-scale 1.0))
                                 1e-9))
                      (should (eql 600 (seshat-reader-multipage-test--page-width 1)))
                      ;; 宽度默认：base 取首页 width-fit（先清掉窗口已记录的
                      ;; fit-mode，否则 `--initial-fit-mode' 会沿用上一次的 contain）
                      (seshat-reader-enlarge-size)
                      (set-window-parameter window 'fit-mode nil)
                      (let ((seshat-reader-default-fit 'width))
                        (seshat-reader-reset-size))
                      (should (eq 'width seshat-reader--multipage-fit-mode))
                      (should (< (abs (- seshat-reader--multipage-base-scale
                                         (/ 1000.0 600)))
                                 1e-9))
                      (should (eql 1000 (seshat-reader-multipage-test--page-width 1))))
                (set-window-parameter window 'fit-mode nil)))))
      (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--geometry-fit-to-width-uses-reference-page ()
  "`W' derives the base scale from the reference page and renders sharply.

Window 1000x800, reference page 600x800: width fit = 1000/600 = 1.667, so the
page is exactly as wide as the window, the fit mode is `width' and every page
is already at the target resolution."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (unwind-protect
                  (progn
                    (set-window-parameter window 'fit-mode nil)
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader-fit-to-width))
                    (should (eq 'width seshat-reader--multipage-fit-mode))
                    (should (< (abs (- seshat-reader--multipage-base-scale
                                       (/ 1000.0 600)))
                               1e-9))
                    (dolist (page '(1 2))
                      (should (= 1000 (seshat-reader-multipage-test--page-width page))))
                    (should (seshat-reader-multipage-test--all-sharp-p window)))
                (set-window-parameter window 'fit-mode nil)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-fit-to-height-uses-reference-page ()
  "`H' derives the base scale from the reference page height and renders sharply.

Window 1000x400 for a 600x800 reference page: height fit = 400/800 = 0.5, so the
page is 300x400 (narrower than the window, no horizontal scroll needed) and the
fit mode is `height'."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 400
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (unwind-protect
                  (progn
                    (set-window-parameter window 'fit-mode nil)
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader-fit-to-height))
                    (should (eq 'height seshat-reader--multipage-fit-mode))
                    (should (< (abs (- seshat-reader--multipage-base-scale 0.5)) 1e-9))
                    (should (eql 400 (seshat-reader-multipage-test--page-height 1)))
                    (should (seshat-reader-multipage-test--all-sharp-p window)))
                (set-window-parameter window 'fit-mode nil)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-mwheel-zoom-same-as-keys ()
  "The wheel zooms through exactly the same path as `+' and `-'.

A single C-wheel notch hands the multiplier to `seshat-reader-enlarge-size', so
base, fit mode and page size after a wheel notch are identical to what one `+'
produces; the same holds for the shrink direction.  The wheel is a manual zoom,
so the pixels follow the debounced re-render like they do for the keys: nothing
is rendered while the timer is pending, and one fire leaves every resident page
sharp at the final scale."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  ;; 轮子：一格放大
                  (seshat-reader-mwheel-enlarge-size
                   (list 'C-wheel-up (list window 1 (list 1 1) nil 0)))
                  (let ((wheel-base seshat-reader--multipage-base-scale)
                        (wheel-width (seshat-reader-multipage-test--page-width 1))
                        (wheel-mode seshat-reader--multipage-fit-mode))
                    ;; 回到 1.0 再按键：结果必须逐项相同
                    (seshat-reader--multipage-set-scale 1.0 'manual 'manual)
                    (seshat-reader-enlarge-size)
                    (should (< (abs (- seshat-reader--multipage-base-scale wheel-base))
                               1e-9))
                    (should (eq seshat-reader--multipage-fit-mode wheel-mode))
                    (should (= (seshat-reader-multipage-test--page-width 1) wheel-width)))
                  ;; 缩小方向：一格轮子 == 一次 `-'
                  (seshat-reader-mwheel-shrink-size
                   (list 'C-wheel-down (list window 1 (list 1 1) nil 0)))
                  (let ((wheel-base seshat-reader--multipage-base-scale))
                    (seshat-reader--multipage-set-scale 1.25 'manual 'manual)
                    (seshat-reader-shrink-size)
                    (should (< (abs (- seshat-reader--multipage-base-scale wheel-base))
                               1e-9)))
                  ;; 全程没有一页被渲染（像素等去抖回调）
                  (should (= 0 (car counter)))
                  (seshat-reader-multipage-test--fire-zoom-refit pending)
                  (should (seshat-reader-multipage-test--all-sharp-p window))))))
      (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--geometry-first-fit-leaves-every-page-sharp ()
  "`--first-fit' finishes the rendering, so the first frame is already sharp.

The rows were rendered at base 1.0 by `--render-buffer' while the window is
1000x400, so the contain fit of the reference page is 0.5: the specs are
resized in place and every resident page is rendered once more, which leaves no
page whose render scale differs from its target."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 400
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (unwind-protect
                  (progn
                    (set-window-parameter window 'fit-mode nil)
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader--first-fit))
                    (should (< (abs (- seshat-reader--multipage-base-scale 0.5)) 1e-9))
                    (should (eq 'contain seshat-reader--multipage-fit-mode))
                    ;; 基准页尺寸被记住，供 W / H / 0 复用
                    (should (equal (cons 600.0 800.0)
                                   seshat-reader--multipage-reference-native))
                    (should (= 3 (car counter)))
                    (should (seshat-reader-multipage-test--all-sharp-p window)))
                (set-window-parameter window 'fit-mode nil)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-manual-zoom-refits-visible-pages-once ()
  "A manual zoom renders every resident page exactly once.

Zooming multiplies the base scale, so the bitmaps of the pages that are on
screen are now too coarse for their new size: each of them has to be rendered
again, and exactly once -- a refit that rendered the page it just rendered
\(or the top page only) would show up in the counter.  The re-render happens in
the debounced callback, so the counter is still zero when the command returns
and the \"exactly once\" claim is checked after one fire, never by firing
twice."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (seshat-reader-enlarge-size 2.0)
                  ;; 命令返回时：base 2.0、页 1200x1600，像素未动
                  (should (< (abs (- seshat-reader--multipage-base-scale 2.0)) 1e-9))
                  (should (= 0 (car counter)))
                  (dolist (page '(1 2 3))
                    (should (eql 1200 (seshat-reader-multipage-test--page-width page))))
                  ;; 一次 fire：三页各渲染一次
                  (seshat-reader-multipage-test--fire-zoom-refit pending)
                  (should (= 3 (car counter)))
                  (dolist (page '(1 2 3))
                    (should (< (abs (- (seshat-reader--multipage-render-scale page) 2.0))
                               1e-9)))
                  (should (seshat-reader-multipage-test--all-sharp-p window))
                  ;; 再放大一次：只多渲染 3 次（每页一次）
                  (setcar counter 0)
                  (seshat-reader-enlarge-size 1.25)
                  (should (= 0 (car counter)))
                  (seshat-reader-multipage-test--fire-zoom-refit pending)
                  (should (= 3 (car counter)))))))
      (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--geometry-refit-is-idempotent ()
  "A second refit renders nothing: the render scale already matches the target.

The refit gate is `render-scale ≠ target', which is what keeps the debounced
resize path from re-rendering the whole resident set on every scroll or
redisplay."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader--refit-window window)
                (should (= 0 (car counter)))
                (seshat-reader--refit-window window)
                (should (= 0 (car counter)))
                ;; 破坏一页的分辨率后只重渲染那一页
                (setq seshat-reader--page-render-scales
                      (assq-delete-all 2 seshat-reader--page-render-scales))
                (seshat-reader--refit-window window)
                (should (= 1 (car counter))))))
      (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-does-not-change-base-scale ()
  "Scrolling across a page boundary keeps the zoom identical on both pages.

The base scale is only written by the zoom commands and `--first-fit'; a page
that the sync pulls in while scrolling is therefore rendered at exactly the
same scale as the page the reader was looking at (decision D5's reference page
anchoring).  This is the anti-regression for \"the page shrinks when I scroll\"."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 600 800))
         (buffer (car fixture))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local seshat-reader--multipage-reference-native (cons 600.0 800.0)
                        seshat-reader-current-doc-pagecount 2))
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                  ;; 先把缩放设成非 contain 的 2.0：如果滚动时谁重算了 base
                  ;; scale（例如拿顶页重新 fit），这里立刻会掉回 1.0
                  (setq seshat-reader--multipage-base-scale 2.0
                        seshat-reader--multipage-fit-mode 'manual)
                  (seshat-reader--apply-display-scale window)
                  (setq seshat-reader-multipage-test--scroll-start
                        (seshat-reader-multipage-test--row-position 1)
                        seshat-reader-multipage-test--scroll-offset 1500)
                  ;; 页高 1600（800 × 2.0）：1500 + 300 = 1800 → 跨到第 2 页，余 200
                  ;; 这里**不**桩 `--multipage-sync'：本用例要证明真实 sync 不会
                  ;; 重算缩放基准，桩掉它等于把被验证的代码换成空操作。
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window)
                               seshat-reader-multipage-test--scroll-start))
                            ((symbol-function 'set-window-start)
                             (lambda (_window pos &optional _noforce)
                               (setq seshat-reader-multipage-test--scroll-start pos)
                               pos))
                            ((symbol-function 'window-vscroll)
                             (lambda (&optional _window _pixels-p)
                               seshat-reader-multipage-test--scroll-offset))
                            ((symbol-function 'set-window-vscroll)
                             (lambda (_window value &optional _pixels-p)
                               (setq seshat-reader-multipage-test--scroll-offset value)
                               value)))
                    (seshat-reader--multipage-scroll 300)
                    ;; 断言必须在桩作用域内：`window-start' 用的是模拟值
                    (should (= 2 (seshat-reader--multipage-window-start-page window)))
                    (should (= (seshat-reader-multipage-test--row-position 2)
                               seshat-reader-multipage-test--scroll-start))
                    (should (= 200 seshat-reader-multipage-test--scroll-offset)))
                  ;; 缩放基准没被滚动改变
                  (should (< (abs (- seshat-reader--multipage-base-scale 2.0)) 1e-9))
                  (should (eq 'manual seshat-reader--multipage-fit-mode))
                  ;; 两页目标 scale 相同，新页也是按该 scale 渲染的
                  (should (< (abs (- (seshat-reader--multipage-target-scale 1 window)
                                     (seshat-reader--multipage-target-scale 2 window)))
                             1e-9))
                  (should (< (abs (- (seshat-reader--multipage-render-scale 2) 2.0))
                             1e-9))
                  (should (eql 1200 (seshat-reader-multipage-test--page-width 2)))
                  (should (eql 1600 (seshat-reader-multipage-test--page-height 2))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-resize-refits-every-resident-page ()
  "After a window resize every resident page is sharp again, not only the top one.

The debounced refit walks the whole resident set, so in `width' mode (where a
narrower window lowers the target of every page) all three pages end up at the
new render scale.  A refit that only handled the page at `window-start' would
leave the other pages stretched."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (unwind-protect
                (progn
                  (set-window-parameter window 'fit-mode nil)
                  (seshat-reader-multipage-test--window-pixels 1000 800
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader-fit-to-width)))
                  (should (< (abs (- (seshat-reader--multipage-render-scale 1)
                                     (/ 1000.0 600)))
                             1e-9))
                  (setcar counter 0)
                  ;; 窗口变窄 → 目标 scale 降到 500/600，refit 必须覆盖三页
                  (seshat-reader-multipage-test--window-pixels 500 800
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader--refit-window window)))
                  (should (= 3 (car counter)))
                  (dolist (page '(1 2 3))
                    (should (< (abs (- (seshat-reader--multipage-render-scale page)
                                       (/ 500.0 600)))
                               1e-9))))
              (set-window-parameter window 'fit-mode nil))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-zoom-clamps-at-renderer-bounds ()
  "Repeated zooming stops at the range the native renderer can draw.

Twenty presses of `+' (1.25 each) would need a scale of 87, and forty presses of
`-' a scale of 7e-5; both are clamped to `seshat-reader--multipage-clamp-scale'
\(6.0 and 0.25), so the commands stay usable and the module is never handed a
resolution it would silently clamp behind our back.  The top end is 6.0 and no
longer the 11.0 the renderer would allow: a resident page costs about 250 MB of
bitmap at 11.0 against 67 MB at 6.0 (T5b memory fix)."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1) 600 800))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (dotimes (_ 20) (seshat-reader-enlarge-size))
                (should (< (abs (- seshat-reader--multipage-base-scale 6.0)) 1e-9))
                (dotimes (_ 40) (seshat-reader-shrink-size))
                (should (< (abs (- seshat-reader--multipage-base-scale 0.25)) 1e-9))))))
      (kill-buffer buffer))))

;;;; T6：缓存与虚拟化（动态上限 / 视口优先淘汰 / 方向预取 / 内存告警）

(defun seshat-reader-multipage-test--cached-pages ()
  "Return the sorted page numbers that have an entry in the spec cache."
  (let (pages)
    (dolist (entry seshat-reader--page-spec-cache)
      (push (car (car entry)) pages))
    (sort (delete-dups pages) #'<)))

(defmacro seshat-reader-multipage-test--with-single-page-viewport (&rest body)
  "Run BODY with the viewport treated as one page tall.

In batch `window-end' reports the end of the buffer, which would make the
resident range grow without bound while a test jumps from page to page; the stub
makes the viewport the single page at `window-start', i.e. what a GUI window of
one page height shows."
  `(cl-letf (((symbol-function 'window-end)
              (lambda (&optional _window _update) (window-start))))
     ,@body))

;;;; 用例

(ert-deftest seshat-reader-multipage-test--geometry-cache-limit-follows-preload ()
  "The cache limit follows the preload, bounded by 3 pages, 8 (knob), 16.

The resident set is the viewport plus `preload' pages on each side, so the
cache needs `2 * preload + 2` entries, never less than 4: 0/1/2/3 pages of
preload give 4/4/6/8.  The preload itself is clamped to
`seshat-reader--multipage-preload-max' (3), so a huge value gives exactly the
same 8 as 3 -- an unbounded preload would grow the residency (and the memory)
linearly with no gain.  The `seshat-reader--page-spec-cache-limit' knob and the
16 of `decisions.md' stay as further upper bounds."
  (with-temp-buffer
    (let ((seshat-reader--page-spec-cache-limit 16))
      (dolist (case '((0 . 4) (1 . 4) (2 . 6) (3 . 8)))
        (let ((seshat-reader--multipage-preload (car case)))
          (should (= (cdr case) (seshat-reader--multipage-cache-limit)))))
      ;; preload 20 先被夹到 3 → 2*3+2 = 8
      (let ((seshat-reader--multipage-preload 20))
        (should (= 3 (seshat-reader--multipage-effective-preload)))
        (should (= 8 (seshat-reader--multipage-cache-limit)))
        (should (= 8 (seshat-reader--multipage-cache-limit)))))
    ;; 变量的默认值 8 是兜底：preload 再大也只给 8
    (let ((seshat-reader--page-spec-cache-limit 8)
          (seshat-reader--multipage-preload 20))
      (should (= 8 (seshat-reader--multipage-cache-limit))))))

(ert-deftest seshat-reader-multipage-test--geometry-cache-evicts-out-of-viewport-first ()
  "When the cache overflows, pages outside the resident set go first.

Five pages are resident, so their bitmaps are the ones on screen; a request for
pages 9 and 10 (both outside) must drop page 9 first, leaving the five resident
pages cached even though they are older."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3 4 5)))
         (buffer (car fixture))
         (counter (list 0)))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal (cons 1 5) (seshat-reader--multipage-resident-page-range)))
          (seshat-reader-multipage-test--with-fake-renderer counter 600 800
            (dolist (page '(1 2 3 4 5))
              (should (seshat-reader--page-spec page 1.0)))
            (should (= 5 (length seshat-reader--page-spec-cache)))
            ;; 上限 6：第 9 页只是填满，不触发淘汰
            (should (seshat-reader--page-spec 9 1.0))
            (should (= 6 (length seshat-reader--page-spec-cache)))
            ;; 第 10 页溢出 → 淘汰视口外的第 9 页，视口内 5 页全在
            (should (seshat-reader--page-spec 10 1.0))
            (should (= (seshat-reader--multipage-cache-limit)
                       (length seshat-reader--page-spec-cache)))
            (should (equal '(1 2 3 4 5 10)
                           (seshat-reader-multipage-test--cached-pages)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-cache-falls-back-to-fifo ()
  "Without page rows the cache has no viewport, so eviction is plain FIFO.

A buffer that is not a reader layout (before the first render, or a document
whose rows were dropped) must still keep the cache bounded, and the only fair
policy left is dropping the oldest entry."
  (with-temp-buffer
    (let ((counter (list 0)))
      (should-not (seshat-reader--multipage-resident-page-range))
      (seshat-reader-multipage-test--with-fake-renderer counter 600 800
        (let ((limit (seshat-reader--multipage-cache-limit)))
          (dotimes (i (+ limit 2))
            (should (seshat-reader--page-spec (1+ i) 1.0)))
          (should (= limit (length seshat-reader--page-spec-cache)))
          ;; 最新的 limit 页留下，最早的两页被 FIFO 淘汰
          (should (equal (number-sequence 3 (+ limit 2))
                         (seshat-reader-multipage-test--cached-pages))))))))

(ert-deftest seshat-reader-multipage-test--geometry-recycle-keeps-adjacent-page-spec ()
  "Recycling a page keeps its bitmap while it is one page from the viewport.

Scrolling one page back must hit the cache, so the spec of a page that just
left the resident set is kept as long as it is within one page of the set; a page
that ends up further away loses its bitmap, which is the order in which memory
is reclaimed.

The far case needs a non-contiguous layout: the rows are dropped with the raw
`--multipage-remove-page' (which does not touch the cache) so that page 1 is
three pages away from the remaining row when it is recycled."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 3 5 7)))
         (buffer (car fixture))
         (counter (list 0)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-multipage-test--with-fake-renderer counter 600 800
            (dolist (page '(1 2 3 4 5 6 7))
              (seshat-reader--page-spec page 1.0))
            ;; 回收第 1 页：驻留集变 3..7，保留区间 [2, 8] → 第 1 页太远，删
            (seshat-reader--multipage-recycle-page 1)
            (should-not (member 1 (seshat-reader-multipage-test--cached-pages)))
            ;; 回收第 3 页：驻留集变 5..7，保留区间 [4, 8] → 第 2、3 页都太远
            (should (member 2 (seshat-reader-multipage-test--cached-pages)))
            (seshat-reader--multipage-recycle-page 3)
            (should-not (member 3 (seshat-reader-multipage-test--cached-pages)))
            ;; 回收第 7 页：驻留集是 5，保留区间 [4, 6] → 第 7 页删，第 6 页留
            (seshat-reader--multipage-recycle-page 7)
            (should-not (member 7 (seshat-reader-multipage-test--cached-pages)))
            (should (member 6 (seshat-reader-multipage-test--cached-pages)))
            ;; 相邻保留的正面例子：还剩第 5 页一行，回收它时区间是 [4, 6]
            (should (seshat-reader--multipage-page-near-resident-p 4))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-recycle-keeps-just-left-page ()
  "The page that the viewport just left keeps its bitmap for the way back.

This is the positive half of the rule above, isolated: with the resident set
4..7 the page 3 is one page away and survives the recycle, which is what makes
scrolling back a cache hit."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(3 4 5 6 7)))
         (buffer (car fixture))
         (counter (list 0)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-multipage-test--with-fake-renderer counter 600 800
            (dolist (page '(3 4 5 6 7))
              (seshat-reader--page-spec page 1.0))
            (seshat-reader--multipage-recycle-page 3)
            (should (equal (cons 4 7) (seshat-reader--multipage-resident-page-range)))
            (should (member 3 (seshat-reader-multipage-test--cached-pages)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scroll-back-hits-cache ()
  "Scrolling one page back re-uses the bitmap of the page just left.

The P0 measurement was a 0% hit rate while scanning 20 pages, because every
page lost its bitmap the moment it left the resident set.  The renderer is
instrumented per page here, so the assertion is about the page itself: page 2 is
rendered once, and the row shows the very same spec object after the way back
\(the prefetch warms other pages, which is fine and does not touch page 2)."
  (let* ((buffer (seshat-reader-multipage-test--scroll-fixture '(1)))
         (renders nil)
         (window (selected-window)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local seshat-reader--multipage-preload 1
                        seshat-reader-current-doc-pagecount 10))
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                           (lambda (page scale _rotate)
                             (push page renders)
                             (list 'image :type 'canvas :data nil
                                   :data-width (max 1 (round (* 600 scale)))
                                   :data-height (max 1 (round (* 800 scale)))
                                   :width (max 1 (round (* 600 scale)))
                                   :height (max 1 (round (* 800 scale)))))))
                  (seshat-reader-multipage-test--with-single-page-viewport
                    (seshat-reader--multipage-goto 2)
                    (let ((spec-before (seshat-reader--multipage-page-spec 2)))
                      (seshat-reader--multipage-goto 3)
                      (seshat-reader--multipage-goto 2)
                      ;; 第 2 页只在第一次进入时渲染过一次
                      (should (= 1 (cl-count 2 renders)))
                      ;; 回来时用的是同一个 spec 对象（缓存命中）
                      (should (eq spec-before (seshat-reader--multipage-page-spec 2))))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-prefetch-warms-next-page-in-direction ()
  "The prefetch queues the page beyond the set in the scrolling direction.

Downwards that is the page after the last resident one, upwards the page before
the first.  Since T5 nothing is rendered on the scrolling path: the page is
queued and the asynchronous pass -- driven by hand here -- puts the bitmap in
the cache, so the reader finds it ready when it scrolls one page further."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(2 3 4)))
         (buffer (car fixture))
         (counter (list 0)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-multipage-test--with-fake-renderer counter 600 800
            (seshat-reader-multipage-test--with-silent-timers
              (setq-local seshat-reader--multipage-scroll-direction 1)
              (seshat-reader--multipage-prefetch
               (selected-window)
               (seshat-reader--multipage-resident-page-range))
              ;; 登记但未渲染：滚动这一步零像素成本。
              (should (equal '(5) seshat-reader--multipage-pending-renders))
              (should (= 0 (car counter)))
              (seshat-reader--async-render-tick buffer)
              (should (seshat-reader--multipage-spec-cached-p 5))
              (should-not (seshat-reader--multipage-spec-cached-p 1))
              ;; 清空后反向预取
              (seshat-reader--page-spec-clear-cache)
              (setq-local seshat-reader--multipage-scroll-direction -1)
              (seshat-reader--multipage-prefetch
               (selected-window)
               (seshat-reader--multipage-resident-page-range))
              (should (equal '(1) seshat-reader--multipage-pending-renders))
              (seshat-reader--async-render-tick buffer)
              (should (seshat-reader--multipage-spec-cached-p 1))
              (should-not (seshat-reader--multipage-spec-cached-p 5)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-prefetch-does-not-insert-rows ()
  "Prefetching queues the page without adding a page row.

The resident rows stay exactly what the viewport asked for: an extra row would
enlarge the layout (and the scroll range) for a page the reader has not reached.
The row count also stays put after the asynchronous pass ran, because a queued
page without a row is only cached."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(2 3 4)))
         (buffer (car fixture))
         (counter (list 0)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-multipage-test--with-fake-renderer counter 600 800
            (seshat-reader-multipage-test--with-silent-timers
              (let ((rows (length seshat-reader--pages)))
                (setq-local seshat-reader--multipage-scroll-direction 1)
                (seshat-reader--multipage-prefetch
                 (selected-window)
                 (seshat-reader--multipage-resident-page-range))
                (should (= rows (length seshat-reader--pages)))
                (should (equal '(5) seshat-reader--multipage-pending-renders))
                (should-not (assq 5 seshat-reader--pages))
                (seshat-reader--async-render-tick buffer)
                (should (= rows (length seshat-reader--pages)))
                (should (seshat-reader--multipage-spec-cached-p 5))
                (should-not (assq 5 seshat-reader--pages))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-prefetch-skips-when-cached ()
  "A page that is already cached is not queued by the prefetch.

The prefetch exists to save a render, so it has to be free when there is nothing
to warm: any cached entry of the page counts, whatever scale or rotation it was
rendered at."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(2 3 4)))
         (buffer (car fixture))
         (counter (list 0)))
    (unwind-protect
        (with-current-buffer buffer
          (seshat-reader-multipage-test--with-fake-renderer counter 600 800
            (seshat-reader-multipage-test--with-silent-timers
              (setq-local seshat-reader--multipage-scroll-direction 1)
              ;; 先用不同 scale 把第 5 页放进缓存
              (seshat-reader--page-spec 5 1.0)
              (let ((after-warm (car counter)))
                (seshat-reader--multipage-prefetch
                 (selected-window)
                 (seshat-reader--multipage-resident-page-range))
                (should (= after-warm (car counter)))
                (should-not seshat-reader--multipage-pending-renders)
                (should (seshat-reader--multipage-spec-cached-p 5))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-cache-bounded-while-scrolling ()
  "Scanning 30 pages keeps the cache and the row count bounded.

With preload 1 the resident range is `2 * 1 + 1 = 3` rows (viewport + one page
on each side) and the cache limit is `2 * 1 + 2 = 4`; the prefetch warms one
page beyond the rows but never inserts a row, so both numbers hold after every
single page turn -- that is the virtualisation budget of decision D4."
  (let* ((buffer (seshat-reader-multipage-test--scroll-fixture '(1)))
         (counter (list 0)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local seshat-reader--multipage-preload 1
                        seshat-reader-current-doc-pagecount 30))
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                  (seshat-reader-multipage-test--with-silent-timers
                    (seshat-reader-multipage-test--with-single-page-viewport
                      (let ((limit (seshat-reader--multipage-cache-limit))
                            (max-rows (+ (* 2 seshat-reader--multipage-preload) 1)))
                        (dotimes (i 30)
                          (seshat-reader--multipage-goto (1+ i))
                          (should (<= (length seshat-reader--page-spec-cache) limit))
                          (should (<= (length seshat-reader--pages) max-rows))
                          (should (<= (car counter) (* 30 3))))))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-sequential-scan-gets-cache-hits ()
  "Scanning 20 pages costs fewer than one render per page.

This is the P0 regression: with a fixed FIFO cache the page that was just
scrolled away was dropped first, so a sequential scan rendered every page and
scored a 0% hit rate.  Now the neighbour is kept and the next page is
prefetched, so the renderer is called strictly fewer than 20 times, and going
back one page costs nothing at all."
  (let* ((buffer (seshat-reader-multipage-test--scroll-fixture '(1)))
         (counter (list 0)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local seshat-reader--multipage-preload 1
                        seshat-reader-current-doc-pagecount 20))
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                  (seshat-reader-multipage-test--with-single-page-viewport
                    (dotimes (i 20)
                      (seshat-reader--multipage-goto (1+ i)))
                    (should (< (car counter) 20))
                    ;; 往回一页：命中缓存，零渲染
                    (let ((before (car counter)))
                      (seshat-reader--multipage-goto 19)
                      (should (= before (car counter))))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-memory-warning-fires-once ()
  "The memory budget is reported once per buffer, not on every scroll.

Six 600x800 canvases count as roughly 11 MB (the estimate takes one ARGB32
pixel per `:data-width' x `:data-height' pixel), which crosses a 0.5 MB budget;
the message is
recorded in a buffer-local flag, so a second check stays silent -- and the flag
is cleared when the document is reloaded with the cache."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3 4 5 6)))
         (buffer (car fixture))
         (messages 0))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                     (lambda (_page scale _rotate)
                       (list 'image :type 'canvas :data nil
                             :data-width (max 1 (round (* 600 scale)))
                             :data-height (max 1 (round (* 800 scale)))
                             :width (max 1 (round (* 600 scale)))
                             :height (max 1 (round (* 800 scale))))))
                    ((symbol-function 'message)
                     (lambda (&rest _args) (setq messages (1+ messages)))))
            (dolist (page '(1 2 3 4 5 6))
              (seshat-reader--page-spec page 1.0))
            (should (> (or (seshat-reader--multipage-resident-spec-megabytes) 0) 0))
            (let ((seshat-reader-multipage-memory-warning-mb 0.5))
              (seshat-reader--multipage-check-memory)
              (should (= 1 messages))
              (should seshat-reader--multipage-memory-warned)
              ;; 再查一次：本 buffer 已经报过，保持沉默
              (seshat-reader--multipage-check-memory)
              (should (= 1 messages))
              ;; 重载/清缓存后重新武装
              (seshat-reader--page-spec-clear-cache)
              (should-not seshat-reader--multipage-memory-warned))))
      (kill-buffer buffer))))

;;;; T5：缩放内存泄漏——替换 spec 时 flush 旧位图

(ert-deftest seshat-reader-multipage-test--geometry-rerender-flushes-the-old-spec ()
  "Re-rendering a page releases the bitmap of the spec it replaced.

The old spec is flushed exactly once and the argument is the **old** object:
flushing the new one would leave the row displaying a spec whose pixels were
just dropped.  The stub also records the row's spec at flush time -- it has to
be the new spec already, because the row is rewritten before the old bitmap is
released (flushing first would blank the row for one redisplay)."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (old (cdr (assq 1 (cdr fixture))))
         (flushed nil)
         (row-spec-at-flush 'unset))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-multipage-test--fake-renderer (list 0)))
                        ((symbol-function 'image-flush)
                         (lambda (image &optional _frame)
                           (push image flushed)
                           (setq row-spec-at-flush
                                 (seshat-reader--multipage-page-spec 1)))))
                (let ((new (seshat-reader--multipage-rerender-page 1 window)))
                  (should new)
                  (should-not (eq new old))
                  (should (equal (list old) flushed))
                  (should (eq (seshat-reader--multipage-page-spec 1) new))
                  ;; 先写行、后释放：flush 那一刻行里已经是新 spec。
                  (should (eq row-spec-at-flush new)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-rerender-keeps-a-shared-spec ()
  "A spec another row still displays is not flushed.

Two rows can share one spec object (two windows showing the same page).  The
old spec of the re-rendered page is then still displayed elsewhere, so the
guard has to keep it: flushing it would force that row to decode the whole
page again on the next redisplay -- the 1-2 s stall the old pbm backend caused
by flushing every frame."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (shared (cdr (assq 1 (cdr fixture))))
         (flushed nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; 第 2 行也显示第 1 页的 spec：两行共享同一对象。
              (seshat-reader--multipage-insert-page 2 shared)
              (should (eq (seshat-reader--multipage-page-spec 2) shared))
              (should (seshat-reader--multipage-spec-in-use-p shared))
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-multipage-test--fake-renderer (list 0)))
                        ((symbol-function 'image-flush)
                         (lambda (&rest _) (push t flushed))))
                (let ((new (seshat-reader--multipage-rerender-page 1 window)))
                  (should new)
                  (should-not (eq new shared))
                  (should-not flushed)
                  (should (eq (seshat-reader--multipage-page-spec 2) shared)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-rerender-survives-flush-failure ()
  "A signalling `image-flush' does not break the re-render.

Releasing the old bitmap is an optimisation: when the flush fails the bitmap
simply stays in the image cache until `image-cache-eviction-delay' expires.
The re-render itself must still succeed and the row must still carry the new
spec."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (old (cdr (assq 1 (cdr fixture))))
         (attempts 0))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                         (seshat-reader-multipage-test--fake-renderer (list 0)))
                        ((symbol-function 'image-flush)
                         (lambda (&rest _)
                           (setq attempts (1+ attempts))
                           (error "flush refused"))))
                (let ((new (seshat-reader--multipage-rerender-page 1 window)))
                  (should new)
                  (should-not (eq new old))
                  (should (= 1 attempts))
                  (should (eq (seshat-reader--multipage-page-spec 1) new)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-memory-warning-reports-image-cache ()
  "The budget message also reports the global image cache size.

The budget is compared against the spec cache only (at most six specs), so a
zoom cycle that left a dozen bitmaps behind in the image cache would stay
silent without this number; the message has to carry it."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3 4 5 6)))
         (buffer (car fixture))
         (messages nil))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                     (lambda (_page scale _rotate)
                       (list 'image :type 'canvas :data nil
                             :data-width (max 1 (round (* 600 scale)))
                             :data-height (max 1 (round (* 800 scale)))
                             :width (max 1 (round (* 600 scale)))
                             :height (max 1 (round (* 800 scale))))))
                    ((symbol-function 'image-cache-size)
                     (lambda () (* 123 1024 1024)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (dolist (page '(1 2 3 4 5 6))
              (seshat-reader--page-spec page 1.0))
            (let ((seshat-reader-multipage-memory-warning-mb 0.5))
              (seshat-reader--multipage-check-memory))
            (should (= 1 (length messages)))
            (should (string-match-p "image cache holds about 123 MB"
                                    (car messages)))))
      (kill-buffer buffer))))

;;;; T7：选区 / 滚轮 / 单页 overlay 残留（P1 批次 6）

(defun seshat-reader-multipage-test--load-select-source ()
  "Reload `seshat-reader-select' from source so `posn-*' stubs take effect.

`posn-window'/`posn-object'/`posn-object-x-y' 在 Emacs 31 里是可内联的函数，
`make all' 生成的 `seshat-reader-select.elc' 已把它们**内联**进
`seshat-reader-select-posn->page'，`cl-letf' 改 `symbol-function' 也拦不住。
测试里改载同源的 `.el'，这些访问器就恢复成运行时查找（语义不变）。"
  (let* ((elc (symbol-file 'seshat-reader-select-posn->page 'defun))
         (el (and elc (concat (file-name-sans-extension elc) ".el"))))
    (when (and el (file-exists-p el))
      (load el nil t t))))

;; 这一节钉住三件事：`seshat-reader-current-doc-overlay' 自 P1 起返回的是
;; **image spec** 而不是 overlay（真机 `Wrong type argument: overlayp, nil` 的
;; 根源是还有调用方把它当 overlay 用）；选区坐标换算只看 `posn-object-x-y'
;; 与页 scale；滚轮命令在 buffer 首尾静默，且 `pixel-scroll-precision-mode'
;; 的命令被重映射回本 mode。

(ert-deftest seshat-reader-multipage-test--current-doc-overlay-returns-spec ()
  "`seshat-reader-current-doc-overlay' returns the image spec of a page, never an overlay.

P1 起该访问器返回 image spec（`overlayp' 为 nil、`car-safe' 是 `image'），不再是单页时代的 overlay。"
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (let ((spec (seshat-reader-current-doc-overlay (selected-window) 2)))
              (should spec)
              (should-not (overlayp spec))
              (should (eq 'image (car-safe spec)))
              ;; 与按页访问器是**同一个对象**（不是拷贝）：引导空格的
              ;; `align-to' 靠对象身份跟随尺寸
              (should (eq spec (seshat-reader--multipage-page-spec 2)))
              ;; 不给 PAGE 时取视口顶页
              (should (eq (seshat-reader-current-doc-overlay)
                          (seshat-reader--multipage-page-spec
                           (seshat-reader--multipage-window-start-page)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--select-posn->page-divides-by-page-scale ()
  "Convert image pixels to page coordinates, independently of the visible page.

`posn-object-x-y' 已含滚动与居中偏移，故换算只需除掉页 scale；视口非首页时
`posn-object-x-y' 报的就是该页图内的坐标。"
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-multipage-test--load-select-source)
            ;; 视口停在第 2 页（非首页）
            (set-window-start window
                              (seshat-reader-multipage-test--row-start 2))
            (should (= 2 (seshat-reader-current-doc-pagenumber window)))
            ;; 缩放真值是 buffer 级的（M3）：窗口参数只是镜像，必须一起写
            (setq seshat-reader--multipage-base-scale 2.0)
            (set-window-parameter window 'scale 2.0)
            ;; A+ 修复起页面坐标换算的分母是**显示 scale**（行里那幅图的实际
            ;; 尺寸 ÷ native），因为窗口 resize 只重写 spec 而 base scale 不动。
            ;; 真实缩放同样会把每页 spec 重写为 native × 2.0
            ;; （`seshat-reader--apply-display-scale'），夹具必须一起缩放，
            ;; 否则「base 2.0 + 显示 1.0」是现实里不存在的状态。
            (dolist (entry (cdr fixture))
              (setf (image-property (cdr entry) :width) 1200)
              (setf (image-property (cdr entry) :height) 1600))
            (cl-letf (((symbol-function 'posn-window) (lambda (_posn) window))
                      ((symbol-function 'posn-object)
                       (lambda (_posn) (list 'image :type 'canvas :data nil)))
                      ((symbol-function 'posn-object-x-y)
                       (lambda (_posn) '(200 . 400)))
                      ((symbol-function 'frame-scale-factor)
                       (lambda (&optional _frame) 1.0)))
              (should (equal (cons 100.0 200.0)
                             (seshat-reader-select-posn->page '(dummy)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--select-extract-survives-a-non-page-position ()
  "`select-extract' returns nil, without signalling, when a drag ends outside a page.

T7 的验收是「不崩」：跨页选区的 `user-error' 属 T8，本批只要求
`seshat-reader-select-extract' 在两端页号不一时安静返回 nil。"
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window (selected-window))
         (messages 0))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-multipage-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (let ((seshat-reader-select-last nil))
              (cl-letf (((symbol-function 'posn-window) (lambda (_posn) window))
                      ;; 起点在图片上（`(image …)'），终点落在页间空隙（nil）
                        ((symbol-function 'posn-object)
                         (lambda (posn)
                           (when (eq (car-safe posn) 'image-pos)
                             (list 'image :type 'canvas :data nil))))
                        ((symbol-function 'posn-object-x-y)
                         (lambda (_posn) '(10 . 20)))
                        ((symbol-function 'frame-scale-factor)
                         (lambda (&optional _frame) 1.0))
                        ((symbol-function 'message)
                         (lambda (&rest _args) (cl-incf messages))))
                (should-not (seshat-reader-select-extract '(image-pos) '(gap)))
                (should (= 1 messages))
                (should-not seshat-reader-select-last)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--scroll-commands-swallow-buffer-limits ()
  "Scroll commands return nil silently at the buffer limits.

真机上滚轮停在文档首尾时会出现 `Beginning of buffer' / `End of buffer'；
`seshat-reader-scroll-*' 用 `ignore-errors' 吞掉这类信号，它们属于边界而非错误。"
  (cl-letf (((symbol-function 'seshat-reader--multipage-scroll)
             (lambda (&optional _pixels)
               (signal 'beginning-of-buffer nil))))
    (should-not (seshat-reader-scroll-up))
    (should-not (seshat-reader-scroll-down))
    (should-not (seshat-reader-scroll-up-screen))
    (should-not (seshat-reader-scroll-down-screen)))
  (cl-letf (((symbol-function 'seshat-reader--multipage-scroll)
             (lambda (&optional _pixels)
               (signal 'end-of-buffer nil))))
    (should-not (seshat-reader-scroll-up))
    (should-not (seshat-reader-scroll-down)))
  ;; 滚轮包装同样静默（走非队列版本，队列版只负责排队）
  (let ((window (selected-window)))
    (cl-letf (((symbol-function 'seshat-reader--multipage-scroll)
               (lambda (&optional _pixels)
                 (signal 'beginning-of-buffer nil))))
      (should-not (seshat-reader--non-queue-mwheel-scroll-up
                   (list 'wheel-up (list window 10 10) 0 nil '(0 . -1))))
      (should-not (seshat-reader--non-queue-mwheel-scroll-down
                   (list 'wheel-down (list window 10 10) 0 nil '(0 . 1)))))))

(ert-deftest seshat-reader-multipage-test--pixel-scroll-precision-is-remapped ()
  "`pixel-scroll-precision-mode' wheel commands are remapped to this mode's commands.

它是**全局** minor mode，键表优先级高于本 mode 的局部键表；命令重映射在命令
解析之后才查，故能把滚轮收回本 mode（否则 `<wheel-up>' 永远走不出它的像素滚动）。
`pixel-scroll-precision' 是它绑在 `<wheel-up>' 上的命令，另两个是它内部调用
的滚动函数，老版本可能直接绑它们。"
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (use-local-map seshat-reader-mode-map)
            (when (fboundp 'pixel-scroll-precision)
              (should (eq 'seshat-reader-mwheel-precision-scroll
                          (command-remapping 'pixel-scroll-precision))))
            (should (eq 'seshat-reader-scroll-up
                        (command-remapping 'pixel-scroll-precision-scroll-up)))
            (should (eq 'seshat-reader-scroll-down
                        (command-remapping 'pixel-scroll-precision-scroll-down)))
            ;; 未知命令没有重映射，证明上面不是恒真
            (should-not (command-remapping 'seshat-reader-next-page))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--precision-wheel-dispatcher-keeps-direction ()
  "Dispatch the remapped wheel event by direction and notch count, not by pixel delta.

`pixel-scroll-precision' 一档一步、按原始像素增量滚动；本 mode 的滚轮语义是
「一档 = 一个 `seshat-reader--scroll-step-pixels'」，故分发器只看事件符号与
档数，没有方向符号（触控板）时才回落到像素增量的符号。"
  (let ((window (selected-window))
        (up 0)
        (down 0))
    (cl-letf (;; 分发器转调的是队列命令（与直接绑 `<wheel-up>' 一致），这里让队列
              ;; 立即执行，计数才是同步可见的
              ((symbol-function 'seshat-reader--enqueue-command)
               ;; 注意 `args' 是**参数表**，要 `apply' 展开（生产代码里是
               ;; `(apply #\'apply-partially cmd args)'）
               (lambda (cmd args) (apply cmd args)))
              ((symbol-function 'seshat-reader-scroll-up)
               (lambda (&optional amount) (cl-incf up (or amount 1))))
              ((symbol-function 'seshat-reader-scroll-down)
               (lambda (&optional amount) (cl-incf down (or amount 1)))))
      ;; 一档上滚
      (seshat-reader-mwheel-precision-scroll
       (list 'wheel-up (list window 10 10) 0 nil '(0 . -1)))
      (should (= 1 up))
      (should (= 0 down))
      ;; 双击档下滚 = 两步
      (seshat-reader-mwheel-precision-scroll
       (list 'double-wheel-down (list window 10 10) 0 nil '(0 . 2)))
      (should (= 1 up))
      (should (= 2 down))
      ;; 没有方向符号：按像素增量符号（负 = 内容下移 = 本 mode 的上滚）
      (seshat-reader-mwheel-precision-scroll
       (list 'mouse-movement (list window 10 10) 0 nil '(0 . -3)))
      (should (= 2 up))
      ;; 增量缺失也没有方向符号：什么都不做，不报错
      (should-not (seshat-reader-mwheel-precision-scroll
                   (list 'mouse-movement (list window 10 10) 0 nil nil)))
      (should (= 2 up))
      (should (= 2 down)))))

;;;; T9：自愈、退化输入与重载（P1 批次 8）

;; 这一节补的是「异常路径也没坏」：页行被外部抹掉后能自愈、页数未知时的退化
;; 范围、重载不残留旧文档的页表与 spec 缓存、占位页上的滚动不会卡死、以及
;; 窗口不显示本 buffer 时页号访问器的回退值。

(ert-deftest seshat-reader-multipage-test--sync-rebuilds-rows-after-external-wipe ()
  "A sync re-inserts every page row after an external revert wiped them."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            ;; 自愈路径断言「sync 依视口范围重新渲染并插回页行」——这是态 A 的
            ;; 语义，故关掉异步分派（异步下页行会先以占位态插回，像素后才到）。
            ;; 用 buffer-local 置 nil：本 buffer 用完即 kill，不会泄漏到别的用例。
            (setq-local seshat-reader-render-async nil)
            (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                       (lambda (page scale &optional _rotate)
                         (list 'image :type 'canvas :data nil
                               :data-width 600 :data-height 800
                               :width 600 :height 800
                               :page page :scale scale)))
                      ((symbol-function 'seshat-reader--multipage-prefetch)
                       (lambda (&rest _) nil)))
              (should (= 3 (length seshat-reader--pages)))
              ;; 模拟外部 revert（`M-x revert-buffer' 走的就是这条路）：正文被
              ;; 抹掉、页表与「上次同步区间」一起作废。
              (let ((inhibit-read-only t)) (erase-buffer))
              (seshat-reader--multipage-clear)
              (should-not seshat-reader--pages)
              ;; 「上次同步区间」是**窗口**参数（D2）：所有显示本 buffer 的窗口
              ;; 都必须被清，只清一个窗口会留下「行表已空 + 区间恰好相等 → 早退
              ;; → 行永不重建」的永久空白。
              (let ((windows (get-buffer-window-list (current-buffer) nil t)))
                (should windows)
                (dolist (win windows)
                  (should-not (window-parameter
                               win seshat-reader--range-parameter))))
              ;; 页表为空时 `--multipage-visible-range' 只能靠文档页数判断有页可
              ;; 渲染：真机上这个值由原生模块写入 buffer-local，夹具里手工给。
              (setq seshat-reader-current-doc-pagecount 3)
              ;; 自愈：sync 依视口范围重新渲染并插回页行
              (should (seshat-reader--multipage-sync window))
              (should (equal '(1 2 3) (seshat-reader--multipage-page-numbers)))
              (dolist (page '(1 2 3))
                (should (seshat-reader--multipage-page-spec page))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--visible-range-without-pagecount ()
  "With an unknown page count the range is clipped to the rows that exist."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'window-start)
                       (lambda (&optional _w) (seshat-reader-multipage-test--row-start 1)))
                      ((symbol-function 'window-end)
                       (lambda (&optional _w _update) (seshat-reader-multipage-test--row-start 2))))
              ;; ① 文档页数已知（6）：范围按页数扩张（1 .. 2+preload）
              (cl-letf (((symbol-function 'seshat-reader--multipage-pagecount)
                         (lambda () 6)))
                (should (equal (cons 1 (+ 2 seshat-reader--multipage-preload))
                               (seshat-reader--multipage-visible-range window))))
              ;; ② 页数未知（nil）：不得越过现有页行（最高 3）
              (cl-letf (((symbol-function 'seshat-reader--multipage-pagecount)
                         (lambda () nil)))
                (should (equal (cons 1 3)
                               (seshat-reader--multipage-visible-range window)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--render-buffer-reload-leaves-no-leftovers ()
  "A second `--render-buffer' drops the rows and specs of the previous document."
  (let ((buffer (car (seshat-reader-multipage-test--geometry-buffer '(1 2 3))))
        (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (setq buffer-file-name "/tmp/t9-reload.pdf")
            (cl-letf (((symbol-function 'file-exists-p) (lambda (&rest _) t))
                      ((symbol-function 'seshat-reader-dyn--load-doc)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage-goto)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader-dyn--page-image-spec)
                       (lambda (page scale &optional _rotate)
                         (list 'image :type 'canvas :data nil
                               :data-width 600 :data-height 800
                               :width 600 :height 800
                               :page page :scale scale))))
              ;; 第一次渲染：3 页文档（页表与缓存都记到第 3 页）
              (setq seshat-reader-current-doc-pagecount 3)
              (seshat-reader--render-buffer 0)
              (should (memq 3 (seshat-reader--multipage-page-numbers)))
              (should (assq 3 seshat-reader--page-native-sizes))
              ;; 第二次渲染：2 页文档 —— 旧页行与旧 spec 必须全部作废
              (setq seshat-reader-current-doc-pagecount 2)
              (seshat-reader--render-buffer 0)
              (should (equal '(1 2) (seshat-reader--multipage-page-numbers)))
              (should-not (assq 3 seshat-reader--page-native-sizes))
              (should-not (assq 3 seshat-reader--page-render-scales))
              (should-not (cl-find 3 seshat-reader--page-spec-cache
                                   :key (lambda (entry) (car (car entry))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--scroll-on-placeholder-page-terminates ()
  "Scrolling over a page without a spec terminates instead of spinning."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (vscrolls nil))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            ;; 第 2 页变成占位页（渲染失败 → spec 为 nil，行高 0）
            (setcdr (cdr (assq 2 seshat-reader--pages)) nil)
            (should (= 0 (seshat-reader--multipage-page-pixel-height 2)))
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (&rest args) (push args vscrolls)))
                      ((symbol-function 'seshat-reader--multipage-sync)
                       (lambda (&rest _) nil)))
              ;; 下限 1 像素：每次迭代都必然推进，绝不因 span 0 死循环。
              ;; 这里只走一小段（不是 100000 像素）：batch 里没有命令循环，
              ;; `with-timeout' 的定时器不会触发，真死循环就永远不返回——所以
              ;; 判据是「这几次调用能返回」，而不是超时保护。
              (seshat-reader--multipage-scroll 10 window)
              (seshat-reader--multipage-scroll -10 window)
              (should vscrolls))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--pagenumber-when-window-shows-another-buffer ()
  "A window showing another buffer answers the first row, not an error."
  (let ((buffer (car (seshat-reader-multipage-test--geometry-buffer '(1 2))))
        (window (selected-window)))
    (unwind-protect
        (with-current-buffer buffer
          ;; 窗口此刻显示的是别的 buffer（未调用 with-window-buffer）
          (should-not (eq (window-buffer window) buffer))
          ;; 访问器仍按本 buffer 的页行解析出「最靠前的页」，不抛错
          (should (= 1 (seshat-reader-current-doc-pagenumber window)))
          ;; buffer 里没有页行时返回 nil（docstring：no page row → nil），
          ;; 即使 recent 回退值有内容也不编造页码。
          (let ((seshat-reader--recent-pagenumber-fallback 42))
            (seshat-reader--multipage-clear)
            (should-not (seshat-reader-current-doc-pagenumber window))))
      (kill-buffer buffer))))

;;;; T9 回归：审查修复（gap 滚动死区 / 多窗口 scale / preload 上限）

(ert-deftest seshat-reader-multipage-test--geometry-scroll-crosses-page-with-gap ()
  "Scrolling reaches the next page even when a page gap follows the bitmap."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2) 600 500))
         (buffer (car fixture))
         (window (selected-window))
         (vscroll 490)
         (page 1)
         (pages-seen nil))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'seshat-reader--multipage-page-gap-pixels)
                       (lambda (&optional _page) 20))
                      ((symbol-function 'seshat-reader--multipage-page-at-pos)
                       (lambda (&rest _) page))
                      ((symbol-function 'window-start) (lambda (&optional _w) 1))
                      ((symbol-function 'window-vscroll)
                       (lambda (&optional _w _pixels) vscroll))
                      ((symbol-function 'set-window-vscroll)
                       (lambda (_w value &optional _pixels) (setq vscroll value)))
                      ((symbol-function 'seshat-reader--multipage--scroll-to-page)
                       (lambda (_w target) (setq page target) (push target pages-seen) nil))
                      ((symbol-function 'seshat-reader--multipage-sync)
                       (lambda (&rest _) nil)))
              ;; 页高 500 + gap 20 = span 520；从页内 490 起每步 10 像素，
              ;; 5 次之内必须跨到第 2 页（页底不能是死区）。
              (dotimes (_ 5)
                (seshat-reader--multipage-scroll 10 window))
              (should (= 2 page))
              (should (memq 2 pages-seen)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-page-max-offset-covers-gap ()
  "The vscroll ceiling covers the page gap, not just the bitmap."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1) 600 500))
         (buffer (car fixture)))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'seshat-reader--multipage-page-gap-pixels)
                     (lambda (&optional _page) 20)))
            ;; 500（页高）+ 20（gap）− 1
            (should (= 519 (seshat-reader--multipage-page-max-offset 1)))
            ;; 没有 gap 时与旧口径一致
            (cl-letf (((symbol-function 'seshat-reader--multipage-page-gap-pixels)
                       (lambda (&optional _page) 0)))
              (should (= 499 (seshat-reader--multipage-page-max-offset 1))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-scale-value-is-buffer-level ()
  "The zoom is buffer level: a second window reads the scale the first set."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (window-a (selected-window))
         (window-b nil))
    (unwind-protect
        (progn
          (setq window-b (split-window window-a))
          (set-window-buffer window-a buffer)
          (set-window-buffer window-b buffer)
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'seshat-reader--apply-display-scale)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--center-page)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage-refit-page)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage-sync)
                       (lambda (&rest _) nil)))
              ;; 缩放窗口 A → 两个窗口的镜像与 buffer 级真值都应是 2.0
              (seshat-reader--multipage-set-scale 2.0 'manual 'manual)
              (should (= 2.0 seshat-reader--multipage-base-scale))
              (should (= 2.0 (seshat-reader-current-doc-scale-value window-a)))
              (should (= 2.0 (seshat-reader-current-doc-scale-value window-b)))
              (should (= 2.0 (window-parameter window-b 'scale)))
              ;; 即使 B 的镜像被人为写脏，读到的仍是 buffer 级真值
              (set-window-parameter window-b 'scale 1.25)
              (should (= 2.0 (seshat-reader-current-doc-scale-value window-b))))))
      (when (window-live-p window-b) (delete-window window-b))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--geometry-preload-is-clamped ()
  "A preload above the hard ceiling does not widen the resident range."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer
                   '(1 2 3 4 5 6 7 8 9 10 11 12)))
         (buffer (car fixture))
         (window (selected-window))
         (seshat-reader--multipage-preload 10))
    (unwind-protect
        (seshat-reader-multipage-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'seshat-reader--multipage-pagecount)
                       (lambda () 12))
                      ((symbol-function 'window-start)
                       (lambda (&optional _w)
                         (seshat-reader-multipage-test--row-start 6)))
                      ((symbol-function 'window-end)
                       (lambda (&optional _w _update)
                         (seshat-reader-multipage-test--row-start 6))))
              (should (= 3 seshat-reader--multipage-preload-max))
              (should (= 3 (seshat-reader--multipage-effective-preload)))
              ;; 视口停在第 6 页 → 两端各最多 3 页：3..9
              (should (equal (cons 3 9)
                             (seshat-reader--multipage-visible-range window))))))
      (kill-buffer buffer))))

;;;; T13：页间分隔区（结构 / 几何 / 跨页口径）

;; 分隔区的像素高度由「默认行高」（`seshat-reader--default-line-pixels'，即
;; `frame-char-height'）换算，batch 下真实行高是 1px（0.5 行四舍五入到 0），
;; 直接断言只会得到 0。这一节的用例统一把行高钉成 10px，像素断言才可整数核对。
;;
;; 注意：分隔行是 `--multipage-insert-page' 在**插入页行时**生成的，所以行高
;; 桩必须在建 fixture **之前**生效，否则会出现「buffer 里没有分隔行、像素却
;; 算进分隔区」的口径分叉（这正是 T13 之前若干用例失败的原因）。

(defmacro seshat-reader-multipage-test--with-line-height (pixels &rest body)
  "Run BODY with `frame-char-height' stubbed to PIXELS."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'frame-char-height)
              (lambda (&optional _frame) ,pixels)))
     ,@body))

(defun seshat-reader-multipage-test--lines-between (page-a page-b)
  "Return how many buffer lines lie between the rows of PAGE-A and PAGE-B."
  (- (line-number-at-pos (seshat-reader-multipage-test--row-position page-b))
     (line-number-at-pos (seshat-reader-multipage-test--row-position page-a))
     1))

(defun seshat-reader-multipage-test--separator-rule-position (start end)
  "Return the buffer position of the separator rule line between START and END."
  (save-excursion
    (goto-char start)
    (let ((found nil))
      (while (and (not found) (< (point) end))
        (when (equal '(space :align-to (- right 0))
                     (get-text-property (point) 'display))
          (setq found (point)))
        (forward-line 1))
      found)))

(defun seshat-reader-multipage-test--separator-rule-count (start end)
  "Return how many lines between START and END carry the separator rule."
  (save-excursion
    (goto-char start)
    (let ((count 0))
      (while (< (point) end)
        (when (equal '(space :align-to (- right 0))
                     (get-text-property (point) 'display))
          (setq count (1+ count)))
        (forward-line 1))
      count)))

(defun seshat-reader-multipage-test--row-string-lines (rows)
  "Return how many buffer lines the separator ROWS occupy."
  (let ((count 0)
        (start 0))
    (while (and rows (string-match "\n" rows start))
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest seshat-reader-multipage-test--separator-off-leaves-no-trace ()
  "With the separator and the gap off a page row is followed by nothing.

关掉分隔区、`seshat-reader-page-gap-lines' 为 0 时，布局必须回到「两页相
接」：buffer 行数、`display' 计数与像素口径三处一致，没有残留的空白行。"
  (seshat-reader-multipage-test--with-line-height 10
    (let* ((seshat-reader-page-separator nil)
           (seshat-reader-page-gap-lines 0)
           (buffer (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
      (unwind-protect
          (with-current-buffer (car buffer)
            (should (= 0 (seshat-reader--multipage-page-gap-pixels)))
            (should-not (seshat-reader--multipage-separator-rows))
            ;; 只有两个页行，没有任何附加行
            (should (= 2 (count-lines (point-min) (point-max))))
            (should (= 2 (seshat-reader-multipage-test--display-count)))
            ;; span 就是页高本身，跨页阈值不被多算
            (should (= 500 (seshat-reader--multipage-page-span 1))))
        (kill-buffer (car buffer))))))

(ert-deftest seshat-reader-multipage-test--separator-default-inserts-three-lines ()
  "The default separator puts one rule between two blank lines after a page.

默认 height 0.5 在 10px 行高下是 5px，厚度 2px 被切成「上留白 1px / 线 2px /
下留白 2px」三段，各占一行；页行到下一页行首之间因此恰有 gap-lines + 3 行，
其中只有一行是规则。"
  (seshat-reader-multipage-test--with-line-height 10
    (let* ((seshat-reader-page-separator t)
           (seshat-reader-page-gap-lines 0)
           (buffer (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
      (unwind-protect
          (with-current-buffer (car buffer)
            (should (= 5 (seshat-reader--multipage-separator-pixels)))
            (should (equal '(1 2 2) (seshat-reader--multipage-separator-segments)))
            ;; 结构：页行 → gap 行 → 三段分隔区 → 下一页页行
            (should (= (+ seshat-reader-page-gap-lines 3)
                       (seshat-reader-multipage-test--lines-between 1 2)))
            (should (= 3 (seshat-reader-multipage-test--row-string-lines
                          (seshat-reader--multipage-separator-rows))))
            ;; 三段里恰有一行是规则（整窗宽的 stretch space）
            (should (= 1 (seshat-reader-multipage-test--separator-rule-count
                          (seshat-reader-multipage-test--row-position 1)
                          (seshat-reader-multipage-test--row-position 2))))
            ;; 分隔区不影响页行的 `display' 规格
            (should (= 2 (seshat-reader-multipage-test--display-count))))
        (kill-buffer (car buffer))))))

(ert-deftest seshat-reader-multipage-test--separator-geometry-is-single-source ()
  "Every separator number comes from `--multipage-separator-segments'."
  (seshat-reader-multipage-test--with-line-height 10
    (dolist (height '(0.5 1 0.25))
      (dolist (thickness '(1 2 5))
        (let* ((seshat-reader-page-separator t)
               (seshat-reader-page-separator-height height)
               (seshat-reader-page-separator-thickness thickness)
               (total (seshat-reader--multipage-separator-pixels))
               (segments (seshat-reader--multipage-separator-segments)))
          ;; 总高 = height × 行高，四舍五入到整像素
          (should (= total (round (* 10 height))))
          (should (> total 0))
          (should (consp segments))
          ;; 三段之和 == 总高（单一来源：滚动与构造都从这里取数）
          (should (= total (+ (nth 0 segments) (nth 1 segments) (nth 2 segments))))
          ;; 线不超过总高，也不超过请求的厚度
          (should (<= (nth 1 segments) total))
          (should (<= (nth 1 segments) thickness))
          (should (>= (nth 0 segments) 0))
          (should (>= (nth 2 segments) 0))
          ;; 行数必须与三段非零的段数一致，否则像素与 buffer 又分叉了
          (should (= (seshat-reader-multipage-test--row-string-lines
                      (seshat-reader--multipage-separator-rows))
                     (+ (if (> (nth 0 segments) 0) 1 0)
                        (if (> (nth 1 segments) 0) 1 0)
                        (if (> (nth 2 segments) 0) 1 0)))))))))

(ert-deftest seshat-reader-multipage-test--separator-rule-row-carries-rule-face ()
  "The rule row is one space plus newline, window wide, painted by the face."
  (seshat-reader-multipage-test--with-line-height 10
    (let* ((seshat-reader-page-separator t)
           (seshat-reader-page-gap-lines 0)
           (buffer (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
      (unwind-protect
          (with-current-buffer (car buffer)
            (let* ((from (seshat-reader-multipage-test--row-position 1))
                   (to (seshat-reader-multipage-test--row-position 2))
                   (rule (seshat-reader-multipage-test--separator-rule-position from to)))
              (should rule)
              ;; 文本是「一个空格 + 换行」
              (should (equal " \n"
                             (buffer-substring-no-properties rule (+ rule 2))))
              ;; 一个字符承载「铺满窗口宽度」的 stretch space
              (should (equal '(space :align-to (- right 0))
                             (get-text-property rule 'display)))
              ;; 颜色取自分隔区 face，高度由几何决定：2px / 10px = 0.2
              (let ((face (get-text-property rule 'face)))
                (should (eq 'seshat-reader-page-separator-face
                            (plist-get face :inherit)))
                (should (= 2 (* 10 (plist-get face :height)))))
              ;; 其余两行是留白：只有 :height 面，没有 display
              (let ((blank 0))
                (save-excursion
                  (goto-char from)
                  (forward-line 1)
                  (while (< (point) to)
                    (unless (= rule (point))
                      (should-not (get-text-property (point) 'display))
                      (should (numberp (plist-get (get-text-property (point) 'face)
                                                  :height)))
                      (setq blank (1+ blank)))
                    (forward-line 1)))
                (should (= 2 blank)))))
        (kill-buffer (car buffer))))))

(ert-deftest seshat-reader-multipage-test--separator-adds-to-the-gap-lines ()
  "Gap lines and the separator stack instead of replacing each other.

2 条 gap 行（2 × 10px）+ 分隔区名义 5px + 规则行多占的 8px：规则行是
stretch space，行高恒为一个字符行高（10px），名义厚度只有 2px，差额由
\\(`seshat-reader--multipage-separator-extra-pixels') 补进滚动口径。"
  (seshat-reader-multipage-test--with-line-height 10
    (let* ((seshat-reader-page-separator t)
           (seshat-reader-page-gap-lines 2)
           (buffer (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
      (unwind-protect
          (with-current-buffer (car buffer)
            ;; 分隔区名义高度（三段之和）仍是 5px
            (should (= 5 (seshat-reader--multipage-separator-pixels)))
            ;; 规则行的实测溢出 = 行高 10 − 厚度 2
            (should (= 8 (seshat-reader--multipage-separator-extra-pixels)))
            ;; 2 条 gap 行（2 × 10px）+ 分隔区 5px + 溢出 8px
            (should (= 33 (seshat-reader--multipage-page-gap-pixels)))
            (should (= 533 (seshat-reader--multipage-page-span 1)))
            ;; 附加行数 = gap-lines + 3
            (should (= (+ 2 3)
                       (seshat-reader-multipage-test--lines-between 1 2)))
            ;; 叠加之后规则仍然只有一条
            (should (= 1 (seshat-reader-multipage-test--separator-rule-count
                          (seshat-reader-multipage-test--row-position 1)
                          (seshat-reader-multipage-test--row-position 2)))))
        (kill-buffer (car buffer))))))

(ert-deftest seshat-reader-multipage-test--separator-degenerate-geometry ()
  "A total no larger than the rule keeps the rule and drops both paddings."
  (seshat-reader-multipage-test--with-line-height 10
    ;; 0.1 行 = 1px：2px 的厚度被总高夹到 1px，上下留白都退化为 0
    (let ((seshat-reader-page-separator t)
          (seshat-reader-page-separator-height 0.1)
          (seshat-reader-page-separator-thickness 2))
      (should (= 1 (seshat-reader--multipage-separator-pixels)))
      (should (equal '(0 1 0) (seshat-reader--multipage-separator-segments)))
      (should (equal " \n"
                     (substring-no-properties
                      (seshat-reader--multipage-separator-rows)))))
    ;; height 0：整个分隔区消失
    (let ((seshat-reader-page-separator t)
          (seshat-reader-page-separator-height 0))
      (should (= 0 (seshat-reader--multipage-separator-pixels)))
      (should-not (seshat-reader--multipage-separator-segments))
      (should-not (seshat-reader--multipage-separator-rows)))
    ;; 开关关闭：同上，且与 height 取值无关
    (let ((seshat-reader-page-separator nil)
          (seshat-reader-page-separator-height 0.5))
      (should (= 0 (seshat-reader--multipage-separator-pixels)))
      (should-not (seshat-reader--multipage-separator-segments))
      (should-not (seshat-reader--multipage-separator-rows)))))

(ert-deftest seshat-reader-multipage-test--separator-on-cross-page-geometry ()
  "With the default separator the span is page + 13px and a cross lands 37px in.

分隔区打开时 span 必须含它**实际**占的高度：名义 5px 加上规则行多出的 8px
（行高 10 − 厚度 2）= 13px，500 → 513；非末页的 clamp 因此是 512。跨页一次
（450 + 100 = 550）余量是 37px 而不是 50px，落点仍是第 3 页页行 —— 像素口径与
buffer 里真实存在的分隔行由同一个行高支撑，两者不再分叉。"
  (seshat-reader-multipage-test--with-line-height 10
    (let ((buffer (seshat-reader-multipage-test--scroll-fixture '(1 2 3))))
      (unwind-protect
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (should (= 513 (seshat-reader--multipage-page-span 1)))
                (should (= 512 (seshat-reader--multipage-page-max-offset 1)))
                ;; 末页仍由窗口高约束：500 − 800 → 0
                (should (= 0 (seshat-reader--multipage-page-max-offset 3)))
                (setq seshat-reader-multipage-test--scroll-start
                      (seshat-reader-multipage-test--row-position 1)
                      seshat-reader-multipage-test--scroll-offset 450)
                (seshat-reader-multipage-test--with-scroll-stubs
                  (should (= 37 (seshat-reader--multipage-scroll 100)))
                  (should (= 37 seshat-reader-multipage-test--scroll-offset))
                  ;; 最后一次写入窗口的像素偏移就是跨页后的余量
                  (should (= 37 (car seshat-reader-multipage-test--scroll-vscrolls)))
                  (should (equal (list (seshat-reader-multipage-test--row-position 2))
                                 seshat-reader-multipage-test--scroll-starts))
                  ;; point 落到视口里可见的下一行（第 3 页）
                  (should (= (seshat-reader-multipage-test--row-position 3)
                             (point)))))))
        (kill-buffer buffer)))))

;;;; T9：分隔区实测高度补偿（规则行是 stretch space，恒占一个字符行高）

;; 分隔区的三段几何里，只有规则行不受 face `:height' 影响：它是
;; `(space :align-to (- right 0))' 拉伸空格，行高恒等于 `frame-char-height'，
;; 于是实际高度比名义高度多出「字符行高 − 厚度」。滚动算术必须把这部分算进去
;; （`--multipage-page-gap-pixels' 是唯一入口，span / max-offset 都由它派生），
;; 否则每翻一页少走一个字符行高，跨页落点逐页累积偏移。
;;
;; 视觉不改：`--multipage-separator-row' / segments 的三段分配 / face 全部不动，
;; 只让像素口径反映真实布局（用户已拍板）。

(ert-deftest seshat-reader-multipage-test--span-includes-separator-actual-height ()
  "The span covers the separator as drawn, not as nominal.

规则行行高恒等于 `frame-char-height'（stretch space 不吃 face 的相对高度），
上/下留白行是普通文本行、`:height' 精确生效。10px 行高 + 2px 厚度下，名义 5px
的分隔区实际多占 8px；span 必须含这 8px，否则每页少算一个字符行高。（真机实测：
20px 行高 + 默认 0.5 行 = 名义 10px、实测 28px，偏差恰为 18px。）"
  (seshat-reader-multipage-test--with-line-height 10
    (let* ((seshat-reader-page-separator t)
           (seshat-reader-page-separator-height 0.5)
           (seshat-reader-page-separator-thickness 2)
           (seshat-reader-page-gap-lines 2)
           (buffer (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
      (unwind-protect
          (with-current-buffer (car buffer)
            (let* ((nominal-gap (+ (* 2 10) 5))
                   (actual-gap (seshat-reader--multipage-page-gap-pixels))
                   (span (seshat-reader--multipage-page-span 1)))
              (should (= 8 (seshat-reader--multipage-separator-extra-pixels)))
              (should (= 25 nominal-gap))
              ;; 差值恰为「字符行高 − 厚度」
              (should (= 8 (- actual-gap nominal-gap)))
              (should (= 533 span))
              (should (= (+ 500 nominal-gap 8) span))
              ;; 不是恒等式：span 确实比「名义合计」多 8px
              (should-not (= span (+ 500 nominal-gap)))
              ;; 同时 max-offset 也跟着 span 走（跨页阈值与 clamp 同一数字）
              (should (= (1- span)
                         (seshat-reader--multipage-page-max-offset 1)))))
        (kill-buffer (car buffer))))))

(ert-deftest seshat-reader-multipage-test--span-unaffected-when-separator-off ()
  "With the separator off the span keeps the old numbers, pixel for pixel.

关闭分隔区时没有规则行，补偿必须为 0：span = 页高 + gap 行，与修复前逐值一致
（不因为修复给关掉分隔区的用户多算像素）。"
  (seshat-reader-multipage-test--with-line-height 10
    (dotimes (lines 3)
      (let* ((seshat-reader-page-separator nil)
             (seshat-reader-page-gap-lines lines)
             (buffer (seshat-reader-multipage-test--geometry-buffer '(1 2) 400 500)))
        (unwind-protect
            (with-current-buffer (car buffer)
              (should (= 0 (seshat-reader--multipage-separator-extra-pixels)))
              (should (= (* lines 10)
                         (seshat-reader--multipage-page-gap-pixels)))
              (should (= (+ 500 (* lines 10))
                         (seshat-reader--multipage-page-span 1))))
          (kill-buffer (car buffer)))))))

(ert-deftest seshat-reader-multipage-test--span-extra-pixels-clamps ()
  "The compensation degrades to 0 instead of signalling on odd geometry.

四种退化都不能把错误带进滚动算术：① 厚度远大于名义总高（clamp 后线 = 总高，规则
行**仍然存在**，补偿 = 行高 − 总高）；② 厚度非数字（`--multipage-separator-segments'
按 0 读 ⇒ 没有规则行 ⇒ 0）；③ 总高为 0（segments 为 nil ⇒ 0）；④ 行高读不到
（返回 nil 或抛错 ⇒ 0）。厚度/总高的读取口径只有 `--multipage-separator-segments'
一处，本函数不复制 clamp。"
  (seshat-reader-multipage-test--with-line-height 10
    ;; ① 厚度 40 > 总高 5：线被夹到 5，上下留白退化为 0，规则行仍在
    (let ((seshat-reader-page-separator t)
          (seshat-reader-page-separator-height 0.5)
          (seshat-reader-page-separator-thickness 40))
      (should (equal '(0 5 0) (seshat-reader--multipage-separator-segments)))
      (should (= 5 (seshat-reader--multipage-separator-extra-pixels)))
      (should (= 10 (seshat-reader--multipage-page-gap-pixels))))
    ;; ② 厚度非数字：按 0 读，没有规则行，补偿 0
    (let ((seshat-reader-page-separator t)
          (seshat-reader-page-separator-height 0.5)
          (seshat-reader-page-separator-thickness 'unknown))
      (should (equal '(2 0 3) (seshat-reader--multipage-separator-segments)))
      (should (= 0 (seshat-reader--multipage-separator-extra-pixels)))
      (should (= 5 (seshat-reader--multipage-page-gap-pixels))))
    ;; ③ 总高为 0 / 开关关闭：segments 为 nil，补偿 0
    (let ((seshat-reader-page-separator t)
          (seshat-reader-page-separator-height 0))
      (should-not (seshat-reader--multipage-separator-segments))
      (should (= 0 (seshat-reader--multipage-separator-extra-pixels))))
    (let ((seshat-reader-page-separator nil))
      (should (= 0 (seshat-reader--multipage-separator-extra-pixels))))
    ;; ④ 行高读不到：先取好 segments（它自己也需要行高），再桩掉行高只验容错
    (let* ((seshat-reader-page-separator t)
           (seshat-reader-page-separator-height 0.5)
           (segments (seshat-reader--multipage-separator-segments)))
      (should (equal '(1 2 2) segments))
      (cl-letf (((symbol-function 'seshat-reader--multipage-separator-segments)
                 (lambda (&optional _window) segments))
                ((symbol-function 'seshat-reader--default-line-pixels)
                 (lambda (&optional _window) nil)))
        (should (= 0 (seshat-reader--multipage-separator-extra-pixels))))
      (cl-letf (((symbol-function 'seshat-reader--multipage-separator-segments)
                 (lambda (&optional _window) segments))
                ((symbol-function 'seshat-reader--default-line-pixels)
                 (lambda (&optional _window) (error "frame without a font"))))
        (should (= 0 (seshat-reader--multipage-separator-extra-pixels)))))))

(ert-deftest seshat-reader-multipage-test--separator-uses-display-window-frame ()
  "`--multipage-insert-page' builds the separator rows for the display window.

分隔行的高度按窗口所属 frame 的字符高度烘焙成 face `:height' 倍率，滚动几何
按显示窗口测量，两者必须同源：`--multipage-insert-page' 收到 WINDOW 时先交给
\\(`seshat-reader--multipage--display-window') 解析，再把解析结果传给
\\(`seshat-reader--multipage-separator-rows')；不传时传的是解析出来的默认窗口，
而不是 nil。真实 `frame-char-height' 只接受 frame、`window-frame' 也不易桩，
故这里断言调用链透传的实参，而不是造两个字体不同的 frame 去比像素。"
  (with-temp-buffer
    (let ((default-window (selected-window))
          (explicit-window 'seshat-test-explicit-window)
          (received nil))
      (let ((seshat-reader-page-gap-lines 0))
        (cl-letf (((symbol-function 'seshat-reader--multipage--display-window)
                   ;; 与真实实现同形：显式 WINDOW 优先，nil 落到默认解析结果。
                   (lambda (&optional window) (or window default-window)))
                  ((symbol-function 'seshat-reader--multipage-separator-rows)
                   (lambda (&optional window)
                     (push window received)
                     "")))
          ;; 1. 不传 window：按 `--multipage--display-window' 的结果烘焙。
          (seshat-reader--multipage-insert-page
           1 (seshat-reader-multipage-test--fake-spec 1))
          (should (equal (list default-window) (nreverse received)))
          (setq received nil)
          ;; 2. 传 window：解析后透传该窗口，而不是丢弃。
          (seshat-reader--multipage-insert-page
           2 (seshat-reader-multipage-test--fake-spec 2) explicit-window)
          (should (equal (list explicit-window) (nreverse received)))
          ;; 3. 已有行的页只换 spec，不重建分隔区，因此不再消费窗口。
          (setq received nil)
          (seshat-reader--multipage-insert-page
           1 (seshat-reader-multipage-test--fake-spec 11) explicit-window)
          (should-not received))))))

;;;; T2 验收：手动缩放去抖（D2 / D5 / D6 的机械形式）

;; 手动缩放（`+' / `-' / `=' / `C-<wheel>'）只延后**像素**：scale、spec 尺寸、
;; 窗口参数在命令返回时就已就位，重渲与 sync 由 idle timer 完成。这些用例用
;; `--with-zoom-debounce-stub' 捕获那个 timer（batch 下真实 idle timer 永不 fire），
;; 用 `--with-fake-renderer' 数渲染次数。每例都至少有一条「实现回退就变红」的判据。

(ert-deftest seshat-reader-multipage-test--zoom-debounce-collapses-burst ()
  "A burst of `+' presses renders the resident pages once, not once per press.

Three presses multiply the base scale to 1.25^3 synchronously, and each press
rewrites the spec sizes in place, so the geometry is final before the timer
runs: the render counter is still zero, which is the whole point of the
debounce.  Firing the single surviving timer renders every resident page
exactly once -- three renders for three presses would mean the burst was not
collapsed at all."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-base-scale 1.0)
              (seshat-reader--apply-display-scale window)
              (setcar counter 0)
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (dotimes (_ 3)
                    (seshat-reader-enlarge-size))
                  (let ((base seshat-reader--multipage-base-scale))
                    (should (< (abs (- base (expt 1.25 3))) 1e-9))
                    ;; 三次按键一次都没渲染：像素还在等 timer
                    (should (= 0 (car counter)))
                    ;; 但 spec 尺寸已按最终 target 改写（同步写，选区/书签依赖）
                    (dolist (page '(1 2 3))
                      (should (< (abs (- (seshat-reader-multipage-test--page-width page)
                                         (* 600 base)))
                                 1.5))
                      (should (< (abs (- (seshat-reader-multipage-test--page-height page)
                                         (* 800 base)))
                                 1.5)))
                    ;; 三次按键 = 三次 arm、两次 cancel，只剩最后一个 timer
                    (should (= 3 armed))
                    (should (= 2 cancelled))
                    (seshat-reader-multipage-test--fire-zoom-refit pending)
                    (should (= 3 (car counter)))
                    (dolist (page '(1 2 3))
                      (should (< (abs (- (seshat-reader--multipage-render-scale page)
                                         base))
                                 1e-9)))
                    (should (seshat-reader-multipage-test--all-sharp-p window))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-debounce-fires-once ()
  "One fire renders every resident page once; a repeated fire adds nothing.

The callback clears `seshat-reader--zoom-refit-timer' before it works, so a
second run of the same callback (what a timer that was not cancelled would do)
finds the refit gate closed -- every page already matches its target -- and
renders nothing.  A callback without the gate or without the clear would show
up here as a counter that keeps growing."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (seshat-reader-enlarge-size)
                  (should (= 0 (car counter)))
                  (let ((call (car pending)))
                    (should call)
                    (seshat-reader-multipage-test--fire-zoom-refit pending)
                    (should (= 3 (car counter)))
                    (should (seshat-reader-multipage-test--all-sharp-p window))
                    ;; timer 变量已清：再跑一次同一回调（模拟重复触发）零渲染
                    (should-not seshat-reader--zoom-refit-timer)
                    (apply (car call) (cdr call))
                    (should (= 3 (car counter)))
                    (should-not seshat-reader--zoom-refit-timer)
                    ;; 重复触发也不重新排 timer
                    (should (= 1 armed))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-debounce-cancels-on-new-keypress ()
  "A second keypress cancels the pending timer instead of stacking another one.

Same counting rule as `seshat-reader-resize-test.el' for the resize refit: the
schedule is cancel-then-rearm, so N keypresses leave one armed timer and N-1
cancellations.  Stacking timers would render the burst once per press."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (seshat-reader-enlarge-size)
                  (should (= 1 armed))
                  (should (= 0 cancelled))
                  (should (eq 'fake-zoom-timer
                              (car seshat-reader--zoom-refit-timer)))
                  (seshat-reader-enlarge-size)
                  ;; 第二次按键：取消前一个，仍然只有 1 个 timer 在等
                  (should (= 2 armed))
                  (should (= 1 cancelled))
                  (should (eq 'fake-zoom-timer
                              (car seshat-reader--zoom-refit-timer)))
                  (should (= 0 (car counter)))
                  (seshat-reader-multipage-test--fire-zoom-refit pending)
                  (should (= 3 (car counter))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-debounce-survives-goto ()
  "A page jump during the debounce is respected by the deferred re-render.

The zoom is still pending when `goto-page' moves the viewport far away: the
rows of the old viewport are recycled, the new ones are rendered.  The
callback must re-render only what is resident *now*, and it has to clear the
recorded range of every window first -- a sync that keeps the range it is
asked for returns early, so the pages pulled in by the jump would never get
their pixels.  Both claims are asserted: the pages handed to the refit are the
new ones only, and the sync sees no recorded range at all."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3) 600 800))
         (buffer (car fixture))
         (window (selected-window))
         (counter (list 0))
         (refit-pages nil)
         (sync-ranges nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local seshat-reader--multipage-reference-native (cons 600.0 800.0)
                        seshat-reader-current-doc-pagecount 12))
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                  (seshat-reader-multipage-test--with-zoom-debounce-stub
                    (seshat-reader-enlarge-size)
                    (should (= 0 (car counter)))
                    (should (= 1 armed))
                    ;; 去抖未 fire 时跳到远处的第 10 页
                    (seshat-reader-goto-page 10)
                    (should (memq 10 (seshat-reader--multipage-page-numbers)))
                    (should-not (memq 1 (seshat-reader--multipage-page-numbers)))
                    (cl-letf* ((orig-refit
                                (symbol-function 'seshat-reader--multipage-refit-page))
                               (orig-sync
                                (symbol-function 'seshat-reader--multipage-sync))
                               ((symbol-function 'seshat-reader--multipage-refit-page)
                                (lambda (page &optional win)
                                  (push page refit-pages)
                                  (funcall orig-refit page win)))
                               ((symbol-function 'seshat-reader--multipage-sync)
                                (lambda (&optional win)
                                  (push (cons win
                                              (seshat-reader--multipage-last-range-for
                                               win))
                                        sync-ranges)
                                  (funcall orig-sync win))))
                      (seshat-reader-multipage-test--fire-zoom-refit pending))
                    (should refit-pages)
                    ;; 只重渲新视口的常驻页，旧视口的页不复活
                    (should (memq 10 refit-pages))
                    (should-not (memq 1 refit-pages))
                    (should-not (memq 2 refit-pages))
                    (should-not (memq 1 (seshat-reader--multipage-page-numbers)))
                    ;; 回调前清了所有窗口的 last-range：sync 看到的范围必须是 nil
                    (should sync-ranges)
                    (should (cl-every (lambda (entry) (null (cdr entry)))
                                      sync-ranges))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-debounce-cancelled-on-kill-buffer ()
  "Firing the pending zoom after the buffer died is a silent no-op.

Killing the buffer drops the timer variable with it, and the callback checks
`buffer-live-p' before touching anything: a timer that still fires after the
buffer is gone must not signal and must not render.  (The timer handle itself
is buffer-local, so \"no leftover timer variable\" is asserted through the
buffer being dead plus the callback doing nothing.)"
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (seshat-reader-enlarge-size)
                  (should (= 1 armed))
                  (let ((call (car pending)))
                    (should call)
                    (kill-buffer buffer)
                    (should-not (buffer-live-p buffer))
                    (should-not (condition-case err
                                    (progn (apply (car call) (cdr call)) nil)
                                  (error err)))
                    (should (= 0 (car counter)))
                    (should (= 1 armed))))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest seshat-reader-multipage-test--zoom-debounce-disabled-stays-synchronous ()
  "`seshat-reader-zoom-refit-enabled' = nil puts the manual zoom back on the sync path.

This is the equivalence switch (D6): the command has to leave the pixels sharp
when it returns and must not arm any timer, exactly like before the debounce
existed.  The debounce stub counts arms, so a path that scheduled anyway would
show up here."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (setq seshat-reader--multipage-base-scale 2.0)
              (seshat-reader--apply-display-scale window)
              (setcar counter 0)
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (let ((seshat-reader-zoom-refit-enabled nil))
                    (seshat-reader-enlarge-size)
                    (should (< (abs (- seshat-reader--multipage-base-scale 2.5))
                               1e-9))
                    ;; 命令返回时像素已就位，且没有排 timer
                    (should (= 3 (car counter)))
                    (should (= 0 armed))
                    (should-not seshat-reader--zoom-refit-timer)
                    (should (seshat-reader-multipage-test--all-sharp-p window))
                    ;; 没有 timer 可 fire：计数不变
                    (seshat-reader-multipage-test--fire-zoom-refit pending)
                    (should (= 3 (car counter)))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-debounce-refits-every-window ()
  "The deferred re-render covers every window showing the buffer.

Two windows on the same buffer are refitted page by page: the callback loops
over `get-buffer-window-list' with all frames, not over the selected window
alone, so a second window would keep its blurry bitmaps if the loop were
narrowed.  The per-window counts come from the `window' argument of
`seshat-reader--multipage-refit-page'."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (window (selected-window))
         (other (split-window window))
         (counter (list 0))
         (refits nil))
    (unwind-protect
        (progn
          (set-window-buffer other buffer)
          (seshat-reader-multipage-test--window-pixels 1000 800
            (seshat-reader-multipage-test--with-window-buffer buffer
              (with-current-buffer buffer
                (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                  (seshat-reader-multipage-test--with-zoom-debounce-stub
                    (cl-letf* ((orig-refit
                                (symbol-function 'seshat-reader--multipage-refit-page))
                               ((symbol-function 'seshat-reader--multipage-refit-page)
                                (lambda (page &optional win)
                                  (push (cons page win) refits)
                                  (funcall orig-refit page win))))
                      (seshat-reader-enlarge-size)
                      (should (= 0 (car counter)))
                      (should (= 1 armed))
                      (seshat-reader-multipage-test--fire-zoom-refit pending))
                    (should refits)
                    ;; 两个窗口各拿到一份完整的常驻页重渲（每页一次）
                    (let ((per (list (cons window 0) (cons other 0))))
                      (dolist (entry refits)
                        (let ((cell (assq (cdr entry) per)))
                          (when cell
                            (setcdr cell (1+ (cdr cell))))))
                      (dolist (cell per)
                        (should (= 3 (cdr cell)))))))))))
      (when (window-live-p other)
        (delete-window other))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-fit-stays-synchronous ()
  "`W' and `0' stay synchronous: the pixels are finished when the command returns.

Only the manual zoom is debounced (M3).  A fit switch is a one-shot geometry
change whose whole point is a finished frame, so both `fit-to-width' and
`reset-size' must leave the render counter equal to the resident page count
and must not arm the zoom timer."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (window (selected-window))
         (counter (list 0)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (unwind-protect
                  (progn
                    (set-window-parameter window 'fit-mode nil)
                    (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                      (seshat-reader-multipage-test--with-zoom-debounce-stub
                        ;; `W'：命令返回时两页都已渲染，没有排 timer
                        (seshat-reader-fit-to-width)
                        (should (= 2 (car counter)))
                        (should (= 0 armed))
                        (should-not seshat-reader--zoom-refit-timer)
                        (should (seshat-reader-multipage-test--all-sharp-p window))
                        (should (eql 1000
                                     (seshat-reader-multipage-test--page-width 1)))
                        ;; `0'（reset-size）：先制造一次 manual 去抖，再证明 reset 同步
                        (setcar counter 0)
                        (seshat-reader-enlarge-size)
                        (should (= 0 (car counter)))
                        ;; 清掉窗口记下的 fit 模式，让 `0' 回落到 `contain'（否则
                        ;; 沿用 `W' 的 `width'，base 不变、无可重渲的页）
                        (set-window-parameter window 'fit-mode nil)
                        (let ((armed-before armed))
                          (let ((seshat-reader-default-fit 'contain))
                            (seshat-reader-reset-size))
                          (should (= 2 (car counter)))
                          (should (= armed-before armed))
                          (should (eq 'contain seshat-reader--multipage-fit-mode))
                          (should (seshat-reader-multipage-test--all-sharp-p
                                   window))))))
                (set-window-parameter window 'fit-mode nil)))))
      (kill-buffer buffer))))

;;;; T5b：几何路径的孤儿位图（旧内容快照）

(ert-deftest seshat-reader-multipage-test--resize-spec-pushes-stale-snapshot ()
  "Resizing a spec in place records a snapshot of its **old** content.

The snapshot is taken before the `setf' pair, so it still carries the size the
page had -- which is what makes it `equal' to the entry the image cache holds
for the old bitmap, and the only thing `image-flush' can use to free it.  A
second size change pushes a second snapshot (each old content is a separate
cache entry), while re-applying the same size pushes nothing."
  (let* ((buffer (car (seshat-reader-multipage-test--geometry-buffer '(1) 600 800)))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              ;; manual 模式：target scale 就是 base scale，几何可算得死。
              (setq seshat-reader--multipage-fit-mode 'manual)
              (should-not seshat-reader--multipage-stale-specs)
              (seshat-reader--apply-display-scale window 2.0)
              (should (= 1 (length seshat-reader--multipage-stale-specs)))
              (let ((snapshot (car seshat-reader--multipage-stale-specs))
                    (live (seshat-reader--multipage-page-spec 1)))
                ;; 快照是另一个对象，内容仍是旧尺寸
                (should-not (eq snapshot live))
                (should (equal 600 (image-property snapshot :width)))
                (should (equal 800 (image-property snapshot :height)))
                ;; 原 spec 已被原地改成新尺寸
                (should (equal 1200 (image-property live :width)))
                (should (equal 1600 (image-property live :height)))
                ;; 快照绝不进任何页行（只用于 flush）
                (should-not (seshat-reader--multipage-spec-in-use-p snapshot)))
              ;; 第二次改尺寸：再 push 一份（旧内容 1200x1600 也是独立条目）
              (seshat-reader--apply-display-scale window 3.0)
              (should (= 2 (length seshat-reader--multipage-stale-specs)))
              (should (equal 1200 (image-property
                                   (car seshat-reader--multipage-stale-specs)
                                   :width)))
              ;; 尺寸没变 → 不 push（没有新孤儿产生）
              (seshat-reader--apply-display-scale window 3.0)
              (should (= 2 (length seshat-reader--multipage-stale-specs))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--flush-stale-specs-releases-and-clears ()
  "Every snapshot is handed to `image-flush' and the list is emptied.

The snapshots themselves are the argument: they are the only objects the image
cache can match for the old sizes, so flushing anything else would free
nothing."
  (with-temp-buffer
    (let ((first (seshat-reader-multipage-test--fake-spec 100))
          (second (seshat-reader-multipage-test--fake-spec 200)))
      (setq seshat-reader--multipage-stale-specs (list first second))
      (let (flushed)
        (cl-letf (((symbol-function 'image-flush)
                   (lambda (spec &rest _args)
                     (push spec flushed)
                     t)))
          (seshat-reader--multipage-flush-stale-specs))
        (should (= 2 (length flushed)))
        (should (memq first flushed))
        (should (memq second flushed))
        (should-not seshat-reader--multipage-stale-specs)))))

(ert-deftest seshat-reader-multipage-test--flush-stale-specs-skips-in-use ()
  "A snapshot whose bitmap is still on screen is left to the eviction delay.

Two guards: a row displaying the very same object (the `eq' guard of
`seshat-reader--multipage-spec-in-use-p', defensive because a snapshot is
never inserted into a row) and a row displaying a spec of the same *content*
-- the zoom-out-again case, where the cache key of the snapshot is the live
bitmap and flushing it would force a re-decode of a visible page.  The list is
emptied in both cases, so a skipped snapshot cannot block the next zoom."
  (with-temp-buffer
    (let ((live (seshat-reader-multipage-test--fake-spec 100)))
      (seshat-reader--multipage-insert-page 1 live)
      (setq seshat-reader--multipage-stale-specs (list (copy-sequence live)))
      (let ((flushes 0))
        (cl-letf (((symbol-function 'image-flush)
                   (lambda (&rest _args) (setq flushes (1+ flushes)) t)))
          (seshat-reader--multipage-flush-stale-specs))
        (should (= 0 flushes))
        (should-not seshat-reader--multipage-stale-specs))
      ;; `eq' 守卫单独验证：桩 `--multipage-spec-in-use-p' 返回 t 时不 flush。
      (setq seshat-reader--multipage-stale-specs
            (list (seshat-reader-multipage-test--fake-spec 300)))
      (let ((flushes 0))
        (cl-letf (((symbol-function 'seshat-reader--multipage-spec-in-use-p)
                   (lambda (&rest _args) t))
                  ((symbol-function 'image-flush)
                   (lambda (&rest _args) (setq flushes (1+ flushes)) t)))
          (seshat-reader--multipage-flush-stale-specs))
        (should (= 0 flushes))
        (should-not seshat-reader--multipage-stale-specs)))))

(ert-deftest seshat-reader-multipage-test--zoom-refit-drains-stale-specs ()
  "The debounced zoom re-render releases the geometry orphans of the burst.

`+' resizes every resident spec in place, so the command leaves one snapshot
per page behind; the idle callback is what drains them, after the pages have
been re-rendered and the geometry is final."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2) 600 800))
         (window (selected-window))
         (counter (list 0))
         (flushes 0))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (cl-letf (((symbol-function 'image-flush)
                             (lambda (&rest _args)
                               (setq flushes (1+ flushes))
                               t)))
                    (seshat-reader-enlarge-size)
                    ;; 命令返回时：几何已改，两页各留一份快照，尚未释放
                    (should (= 2 (length seshat-reader--multipage-stale-specs)))
                    (should (= 0 flushes))
                    (seshat-reader-multipage-test--fire-zoom-refit pending)
                    (should-not seshat-reader--multipage-stale-specs)
                    ;; 两页重渲各自 flush 旧位图 + 两份几何快照
                    (should (>= flushes 2))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--clamp-caps-at-six ()
  "The scale clamp stops at 6.0, the memory-safe top end of T5b."
  (should (= 6.0 (seshat-reader--multipage-clamp-scale 100)))
  (should (= 6.0 (seshat-reader--multipage-clamp-scale 11.0)))
  (should (= 5.5 (seshat-reader--multipage-clamp-scale 5.5)))
  (should (= 0.25 (seshat-reader--multipage-clamp-scale 0.1))))

(ert-deftest seshat-reader-multipage-test--image-cache-eviction-delay-is-thirty ()
  "The global image cache eviction delay is lowered to 30 s.

It is a global (C side) variable, so the reader sets it with `setq' at load
time; a `setq-local' would be read by nobody."
  (should (= 30 image-cache-eviction-delay))
  (should-not (local-variable-p 'image-cache-eviction-delay)))

(ert-deftest seshat-reader-multipage-test--insert-page-pushes-replaced-spec ()
  "Replacing the spec of an existing row records the old spec as an orphan.

`seshat-reader--multipage-insert-page' is the only place where a row changes
the **object** it displays, so it is the only place that can record the bitmap
that becomes unreachable.  The push has to happen before the swap: afterwards
no Lisp object matches the cached bitmap of the old content any more and
`image-flush' could never free it (T5c: the 1726 MB of unreachable bitmaps the
geometry path left behind, 10 MB of which the spec cache could account for)."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (old (cdr (assq 1 (cdr fixture))))
         (new (list 'image :type 'canvas :data nil :width 10 :height 20)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should-not seshat-reader--multipage-stale-specs)
              (seshat-reader--multipage-insert-page 1 new)
              (should (eq new (seshat-reader--multipage-page-spec 1)))
              (should (equal (list old) seshat-reader--multipage-stale-specs)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--insert-page-does-not-push-for-new-row ()
  "A page that gets its first row records no orphan.

There is no old spec on the insertion path -- nothing was displayed for that
page -- so pushing anything there would release a bitmap the layout may still
be showing (a nil spec would be a no-op, but a wrong object would not be)."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2)))
         (buffer (car fixture))
         (new (list 'image :type 'canvas :data nil :width 10 :height 20)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (should-not seshat-reader--multipage-stale-specs)
              (seshat-reader--multipage-insert-page 3 new)
              (should (eq new (seshat-reader--multipage-page-spec 3)))
              (should-not seshat-reader--multipage-stale-specs))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--sync-drains-stale-specs ()
  "A sync that renders a new range releases the recorded orphans.

The snapshots are flushed by the sync itself rather than only by the zoom
callback: a geometry change made by a scroll, a `goto-page' or a resize never
reaches that callback, and its orphans would then wait for
`image-cache-eviction-delay'."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (orphan (list 'image :type 'canvas :data nil :width 5 :height 5))
         (flushed nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-silent-timers
                (seshat-reader-multipage-test--with-fake-renderer (list 0) 600 800
                  (cl-letf (((symbol-function 'image-flush)
                             (lambda (image &optional _frame)
                               (push image flushed))))
                    (setq seshat-reader--multipage-stale-specs (list orphan))
                    (seshat-reader--multipage-sync window)
                    (should-not seshat-reader--multipage-stale-specs)
                    (should (equal (list orphan) flushed))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--sync-early-return-still-drains ()
  "The early return of a sync drains the orphans as well.

When the range did not change the sync renders nothing, but it is still the
last thing that runs after a zoom step: skipping the drain there would leave
the snapshots of that step behind until the next scroll -- which is exactly
the case of a user who stops pressing `+' and does nothing else."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2 3)))
         (buffer (car fixture))
         (window (selected-window))
         (orphan (list 'image :type 'canvas :data nil :width 5 :height 5))
         (flushed nil)
         (async-called nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-silent-timers
                (seshat-reader-multipage-test--with-fake-renderer (list 0) 600 800
                  (cl-letf (((symbol-function 'seshat-reader--multipage-visible-range)
                             (lambda (&optional _window) (cons 1 3)))
                            ((symbol-function 'seshat-reader--multipage-last-range-for)
                             (lambda (&optional _window) (cons 1 3)))
                            ((symbol-function 'seshat-reader--multipage-sync-async)
                             (lambda (&rest _args) (setq async-called t) nil))
                            ((symbol-function 'image-flush)
                             (lambda (image &optional _frame)
                               (push image flushed))))
                    (let ((seshat-reader-render-async t))
                      (setq seshat-reader--multipage-stale-specs (list orphan))
                      (seshat-reader--multipage-sync window))
                    ;; 早退确实发生了（没有进入渲染分支），但快照仍被释放。
                    (should-not async-called)
                    (should-not seshat-reader--multipage-stale-specs)
                    (should (equal (list orphan) flushed))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-multipage-test--zoom-refit-clears-cache-over-budget ()
  "A zoom re-render clears the frame image cache only when it is over budget.

The release pass can only free the bitmaps it can still name; the budget is
the backstop for whatever leaked past it, and clearing the whole cache of the
frame is what a manual `M-x clear-image-cache' does (measured: 1726 MB back to
3.34 MB).  It runs with **no argument**, i.e. the current frame only, and only
above `seshat-reader-image-cache-budget-mb' -- nil or a non-positive value
switches it off."
  (let* ((buffer (seshat-reader-multipage-test--scale-fixture '(1 2 3) 600 800))
         (counter (list 0))
         (clears nil))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
              (seshat-reader-multipage-test--with-fake-renderer counter 600 800
                (seshat-reader-multipage-test--with-zoom-debounce-stub
                  (cl-letf (((symbol-function 'image-cache-size)
                             (lambda () (* 900 1024 1024)))
                            ((symbol-function 'clear-image-cache)
                             (lambda (&optional frame) (push frame clears)))
                            ((symbol-function 'image-flush)
                             (lambda (&rest _args) t)))
                    ;; 预算 1024 MB > 900 MB：不触发
                    (let ((seshat-reader-image-cache-budget-mb 1024))
                      (seshat-reader-enlarge-size)
                      (seshat-reader-multipage-test--fire-zoom-refit pending)
                      (should-not clears))
                    ;; 预算 512 MB < 900 MB：触发一次，且不带 frame 参数
                    (let ((seshat-reader-image-cache-budget-mb 512))
                      (seshat-reader-enlarge-size)
                      (seshat-reader-multipage-test--fire-zoom-refit pending)
                      (should (equal '(nil) clears)))
                    ;; nil / 0：兜底关闭
                    (let ((seshat-reader-image-cache-budget-mb nil))
                      (seshat-reader-enlarge-size)
                      (seshat-reader-multipage-test--fire-zoom-refit pending))
                    (let ((seshat-reader-image-cache-budget-mb 0))
                      (seshat-reader-enlarge-size)
                      (seshat-reader-multipage-test--fire-zoom-refit pending))
                    (should (equal '(nil) clears))))))))
      (kill-buffer buffer))))

(provide 'seshat-reader-multipage-test)

;;; seshat-reader-multipage-test.el ends here
