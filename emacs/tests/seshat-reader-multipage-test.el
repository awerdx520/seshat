;;; seshat-reader-multipage-test.el --- Tests for the multi-page layout skeleton  -*- lexical-binding: t; -*-

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
              (let ((seshat-reader--multipage-preload 10))
                (should (equal (seshat-reader--multipage-visible-range window)
                               '(1 . 13))))
              (let ((seshat-reader--multipage-preload 100))
                ;; 下界恒为第 1 页，上界夹到文档页数
                (should (equal (seshat-reader--multipage-visible-range window)
                               '(1 . 40))))))
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
      (let* ((seshat-reader-current-doc-pagecount 5)
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
        (let ((spec (list 'image :type 'pbm :data "x"
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
      (list 'image :type 'pbm :data "x"
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
              (let ((wide (list 'image :type 'pbm :data "x"
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
              (let ((wide (list 'image :type 'pbm :data "x"
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
zoom the user had chosen is not silently replaced by the presentation one."
  (let* ((fixture (seshat-reader-multipage-test--geometry-buffer '(1 2) 600 1600))
         (buffer (car fixture))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-multipage-test--window-pixels 1000 800
          (seshat-reader-multipage-test--with-window-buffer buffer
            (with-current-buffer buffer
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
              (seshat-reader-presentation-mode -1)
              (should (eq 'manual seshat-reader--multipage-fit-mode))
              (should (< (abs (- seshat-reader--multipage-base-scale 2.0)) 1e-9))
              (should mode-line-format)
              (should (eql 1200 (image-property
                                 (seshat-reader--multipage-page-spec 1) :width))))))
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
                        ((symbol-function 'seshat-reader--multipage-rerender-page)
                         (lambda (&rest _) (cl-incf rendered))))
                (seshat-reader-dark-mode 1))
              (should (equal '(1) inverted))
              (should (= 3 rendered))
              (should-not seshat-reader--page-spec-cache)
              (setq rendered 0)
              (cl-letf (((symbol-function 'seshat-reader-dyn--doc-invert)
                         (lambda (flag) (push flag inverted)))
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
              (let ((tall (list 'image :type 'pbm :data "x"
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

(provide 'seshat-reader-multipage-test)

;;; seshat-reader-multipage-test.el ends here
