;;; seshat-reader-select-cross-page-test.el --- ERT tests for cross-page selections  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))

;; This program is free software: you can redistribute it and/or modify
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

;; `seshat-reader-select-extract' 的跨页取文（P2-A T2）、
;; `seshat-reader-select-last' 的新字段 `:page-rects'（P2-A T1）与旋转页坐标
;; 逆变换（P2-A T3）的 ERT 套件。
;;
;; 用例全部**不加载动态模块、不依赖真实文档**：
;;
;;   - 页行是真的：夹具按 P1 的多页布局插入页行，因此
;;     `seshat-reader--multipage-page-at-pos' 的「gap 归上一页」由真实实现
;;     回答，「首末点落在页间分隔区」两条用例不需要另造页号桩；
;;   - 模块入口 `seshat-reader-dyn--text-in-rect'、
;;     `seshat-reader-select--rects-in-rect' 与 `--flash-selection' 桩替，并把
;;     收到的参数记进 `seshat-reader-select-cross-page-test--calls'，因此可以
;;     断言「逐页取」以及「传给模块的页号是 0-based」；
;;   - `posn-*' 访问器与 `--page-scale' / `frame-scale-factor' 桩替成一个图像
;;     像素 = 一个页面坐标、页高 800，换算结果因此可以逐值断言。
;;
;; 纪律：`skipped' 必须恒为 0，故不用 `skip-unless'。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
(require 'seshat-reader-select)

(defvar seshat-reader-select-cross-page-test--calls nil
  "Stubbed native entries recorded so far, most recent first.
Each item is (KIND PAGE X0 Y0 X1 Y1) with KIND either `text' or `rects';
PAGE is the page number the module received, hence 0-based.")

(defvar seshat-reader-select-cross-page-test--window nil
  "Window the fake position lists answer for, bound by `--with-reader'.")

;;;; 夹具

(defun seshat-reader-select-cross-page-test--reader-buffer (pages &optional sizes)
  "Create a reader buffer holding one page row per page in PAGES.
Each row displays a fake image spec and records the matching native size at
scale 1.0, which is the state a first render leaves behind.  SIZES is an
alist PAGE -> (W . H) overriding the default 600x800 page, so a document whose
pages differ in height (a cover page next to body pages) can be built.  The
buffer is returned."
  (let ((buffer (generate-new-buffer " *seshat-select-cross-page*")))
    (with-current-buffer buffer
      (setq major-mode 'seshat-reader-mode
            mode-name "Seshat Reader")
      (setq-local seshat-reader--multipage-base-scale 1.0
                  seshat-reader--multipage-fit-mode 'contain
                  seshat-reader--recent-scale-fallback 1.0)
      (use-local-map seshat-reader-mode-map)
      (dolist (page pages)
        (let* ((size (or (cdr (assq page sizes)) (cons 600 800)))
               (spec (list 'image :type 'canvas :data nil
                           :data-width (car size) :data-height (cdr size)
                           :width (car size) :height (cdr size))))
          (seshat-reader--multipage-insert-page page spec)
          (seshat-reader--multipage-record-native page spec 1.0))))
    buffer))

(defun seshat-reader-select-cross-page-test--row-start (page)
  "Return the first buffer position of the row of PAGE."
  (when-let* ((entry (assq page seshat-reader--pages))
              (marker (cadr entry)))
    (marker-position marker)))

(defun seshat-reader-select-cross-page-test--load-source ()
  "Reload `seshat-reader-select' from source so `posn-*' stubs take effect.
`posn-window'/`posn-object'/`posn-object-x-y'/`posn-point' 可被内联，`.elc' 已把
调用内联进 `seshat-reader-select-posn->page'，`cl-letf' 拦不住；改载同源的
`.el' 即恢复运行时查找（语义不变）。"
  (let* ((elc (symbol-file 'seshat-reader-select-posn->page 'defun))
         (el (and elc (concat (file-name-sans-extension elc) ".el"))))
    (when (and el (file-exists-p el))
      (load el nil t t))))

(defun seshat-reader-select-cross-page-test--fake-posn (point xy)
  "Return a fake position list at buffer position POINT.
XY is the image pixel offset, i.e. what `posn-object-x-y' answers."
  (list seshat-reader-select-cross-page-test--window 5 point (cons 0 0) 100
        (list 'image :type 'canvas :data nil)
        (cons 0 0)
        xy))

(defmacro seshat-reader-select-cross-page-test--with-reader (pages &rest body)
  "Run BODY in a reader buffer whose rows are PAGES.
A thin wrapper around `--with-reader-sizes' with the default 600x800 pages."
  (declare (indent 1) (debug t))
  `(seshat-reader-select-cross-page-test--with-reader-sizes ,pages nil ,@body))

(defmacro seshat-reader-select-cross-page-test--with-reader-sizes (pages sizes &rest body)
  "Run BODY in a reader buffer whose rows are PAGES, sized by SIZES.
SIZES is the PAGE -> (W . H) alist `--reader-buffer' takes; nil means every
page is 600x800.
The buffer is created and killed around BODY, `seshat-reader-select-last' is
bound to nil, the source of `seshat-reader-select' is reloaded and every
accessor the selection uses is stubbed:

  `posn-window' / `posn-point' / `posn-object' / `posn-object-x-y'
              answer from the fake position list of `--fake-posn';
  `posn-object-width-height' answers 600x800, the size of the fake page;
  `seshat-reader-select--page-scale' and `frame-scale-factor' answer 1.0, so
              one image pixel is one page coordinate;
  `seshat-reader-dyn--text-in-rect' and `seshat-reader-select--rects-in-rect'
              record their arguments in `--calls' and answer per page;
  `--flash-selection' does nothing and `message' is silenced."
  (declare (indent 2) (debug t))
  `(let* ((buffer (seshat-reader-select-cross-page-test--reader-buffer
                   ,pages ,sizes))
          (seshat-reader-select-cross-page-test--calls nil)
          (seshat-reader-select-cross-page-test--window (selected-window))
          (seshat-reader-select-last nil))
     (unwind-protect
         (with-current-buffer buffer
           (seshat-reader-select-cross-page-test--load-source)
           (cl-letf (((symbol-function 'posn-window)
                      (lambda (_posn)
                        seshat-reader-select-cross-page-test--window))
                     ((symbol-function 'posn-point)
                      (lambda (posn) (nth 2 posn)))
                     ((symbol-function 'posn-object)
                      (lambda (posn) (nth 5 posn)))
                     ((symbol-function 'posn-object-x-y)
                      (lambda (posn) (nth 7 posn)))
                     ((symbol-function 'posn-object-width-height)
                      (lambda (_posn) (cons 600 800)))
                     ((symbol-function 'frame-scale-factor)
                      (lambda (&optional _frame) 1.0))
                     ((symbol-function 'seshat-reader-select--page-scale)
                      (lambda (_window) 1.0))
                     ((symbol-function 'seshat-reader-dyn--text-in-rect)
                      (lambda (page x0 y0 x1 y1)
                        (push (list 'text page x0 y0 x1 y1)
                              seshat-reader-select-cross-page-test--calls)
                        (format "page-%d" (1+ page))))
                     ((symbol-function 'seshat-reader-select--rects-in-rect)
                      (lambda (page x0 y0 x1 y1)
                        (push (list 'rects page x0 y0 x1 y1)
                              seshat-reader-select-cross-page-test--calls)
                        (list (list (float (1+ page)) 5.0 15.0 25.0)
                              (list (float (1+ page)) 30.0 15.0 55.0))))
                     ((symbol-function 'seshat-reader-select--flash-selection)
                      (lambda (&rest _) t))
                     ((symbol-function 'message) (lambda (&rest _) nil)))
             ,@body))
       (kill-buffer buffer))))

(defun seshat-reader-select-cross-page-test--recorded (kind)
  "Return the stubbed calls of KIND, oldest first."
  (cl-remove-if-not (lambda (call) (eq (car call) kind))
                    (reverse seshat-reader-select-cross-page-test--calls)))

;;;; 1. T1：`:page-rects' 字段

(ert-deftest seshat-reader-select-cross-page-test--page-rects-mirrors-rects ()
  "A single-page selection keeps `:page-rects' one-to-one with `:rects'.
两条字段必须逐值对应（页号全等于 `:page'，顺序与数值与 `:rects' 一致），
这样批次 3 的绘制路径可以只读 `:page-rects' 而不改变单页观感。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2)
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 2)
                   (cons 10 20)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (1+ (seshat-reader-select-cross-page-test--row-start 2))
                 (cons 200 400))))
      (seshat-reader-select-extract start end)
      (let ((last seshat-reader-select-last))
        ;; 单页拖拽：页号是拖拽所在页（第 2 页），不是视口顶页。
        (should (= 2 (plist-get last :page)))
        (should (equal '(10.0 20.0 200.0 400.0) (plist-get last :rect)))
        (should (equal '((2.0 5.0 15.0 25.0) (2.0 30.0 15.0 55.0))
                       (plist-get last :rects)))
        ;; 逐值对应：页号全为 2，cdr 序列与 `:rects' 相等。
        (should (equal '(2 2) (mapcar #'car (plist-get last :page-rects))))
        (should (equal (plist-get last :rects)
                       (mapcar #'cdr (plist-get last :page-rects))))))))

(ert-deftest seshat-reader-select-cross-page-test--page-rects-page-order ()
  "A cross-page selection tags its rectangles with ascending page numbers.
`:page-rects' 是「逐页几何」的扁平化结果：每页的 `:rects' 各带页号，按阅读
顺序（页号升序）排列，因此消费方不必再排序。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2 3)
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 700)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (seshat-reader-select-cross-page-test--row-start 3)
                 (cons 20 100))))
      (seshat-reader-select-extract start end)
      (should (equal '((1 1.0 5.0 15.0 25.0) (1 1.0 30.0 15.0 55.0)
                       (2 2.0 5.0 15.0 25.0) (2 2.0 30.0 15.0 55.0)
                       (3 3.0 5.0 15.0 25.0) (3 3.0 30.0 15.0 55.0))
                     (plist-get seshat-reader-select-last :page-rects)))
      ;; 页号单调不减 —— 扁平化保留了页序。
      (should (equal '(1 1 2 2 3 3)
                     (mapcar #'car (plist-get seshat-reader-select-last
                                              :page-rects)))))))


(ert-deftest seshat-reader-select-cross-page-test--page-rects-degenerate ()
  "Empty and nil geometry is handled without an error.
三条纯函数必须对 nil / 空页 / 无几何的输入安静返回 nil，否则批注与绘制
路径上的「模块不可用」会变成报错。"
  (should-not (seshat-reader-select--page-selection nil))
  (should-not (seshat-reader-select--flatten-page-rects nil))
  (should-not (seshat-reader-select--flatten-page-rects '((1 nil))))
  (should-not (seshat-reader-select--join-page-texts nil))
  (should-not (seshat-reader-select--join-page-texts '(nil)))
  ;; 页号未知时退化成单页：页号取已知的那个，没有就是 1。
  (should (equal '((1 1 2 3 4))
                 (seshat-reader-select--selection-page-rects
                  (cons 1 2) nil (cons 3 4) nil nil nil)))
  (should (equal '((5 1 2 3 4))
                 (seshat-reader-select--selection-page-rects
                  (cons 1 2) nil (cons 3 4) 5 nil nil))))

;;;; 2. T2：跨页取文

(ert-deftest seshat-reader-select-cross-page-test--two-pages ()
  "A drag across two pages reads both pages and joins them with a newline.
首末页各自被裁剪：首页从拖拽点取到页底（页高 800），末页从页顶取到拖拽点；
每页单独调模块，页号换算成 0-based。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2)
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 500)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (seshat-reader-select-cross-page-test--row-start 2)
                 (cons 200 300))))
      (should (equal "page-1\npage-2"
                     (seshat-reader-select-extract start end)))
      ;; 逐页取文：页号 0-based，矩形被裁剪到页边界。
      (should (equal '((text 0 10.0 500.0 200.0 800.0)
                       (text 1 10.0 0.0 200.0 300.0))
                     (seshat-reader-select-cross-page-test--recorded 'text)))
      (should (equal '((rects 0 10.0 500.0 200.0 800.0)
                       (rects 1 10.0 0.0 200.0 300.0))
                     (seshat-reader-select-cross-page-test--recorded 'rects)))
      (let ((last seshat-reader-select-last))
        ;; :page / :rect / :rects 都是**起点页**（第 1 页）那一段。
        (should (= 1 (plist-get last :page)))
        (should (equal '(10.0 500.0 200.0 800.0) (plist-get last :rect)))
        (should (equal '((1.0 5.0 15.0 25.0) (1.0 30.0 15.0 55.0))
                       (plist-get last :rects)))
        (should (equal '((1 1.0 5.0 15.0 25.0) (1 1.0 30.0 15.0 55.0)
                         (2 2.0 5.0 15.0 25.0) (2 2.0 30.0 15.0 55.0))
                       (plist-get last :page-rects)))))))

(ert-deftest seshat-reader-select-cross-page-test--three-pages ()
  "A drag across three pages reads the pages in between in full.
中间页取整页（y 从 0 到页高），文本仍按页序拼接。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2 3)
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 700)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (seshat-reader-select-cross-page-test--row-start 3)
                 (cons 20 100))))
      (should (equal "page-1\npage-2\npage-3"
                     (seshat-reader-select-extract start end)))
      (should (equal '((text 0 10.0 700.0 20.0 800.0)
                       (text 1 10.0 0.0 20.0 800.0)
                       (text 2 10.0 0.0 20.0 100.0))
                     (seshat-reader-select-cross-page-test--recorded 'text)))
      (should (equal '(10.0 700.0 20.0 800.0)
                     (plist-get seshat-reader-select-last :rect)))
      (should (= 1 (plist-get seshat-reader-select-last :page))))))

(ert-deftest seshat-reader-select-cross-page-test--single-page-unchanged ()
  "A one-page drag is byte-identical to the pre-cross-page behaviour.
反向断言：这是 P2-A 之前 `seshat-reader-select-extract' 的算法给出的同一组
数值（两端坐标的 min/max 围出的 bbox、模块页号 0-based、`:rects' 原样），
跨页改造不得改动它们。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2)
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 400)))
           ;; 向上拖：末点的 y 比起点小，bbox 仍须是 min/max。
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (1+ (seshat-reader-select-cross-page-test--row-start 1))
                 (cons 200 20))))
      (should (equal "page-1" (seshat-reader-select-extract start end)))
      (should (equal '((text 0 10.0 20.0 200.0 400.0))
                     (seshat-reader-select-cross-page-test--recorded 'text)))
      (should (equal '((rects 0 10.0 20.0 200.0 400.0))
                     (seshat-reader-select-cross-page-test--recorded 'rects)))
      (let ((last seshat-reader-select-last))
        (should (= 1 (plist-get last :page)))
        (should (equal '(10.0 20.0 200.0 400.0) (plist-get last :rect)))
        (should (equal (plist-get last :rects)
                       (mapcar #'cdr (plist-get last :page-rects))))))))

(ert-deftest seshat-reader-select-cross-page-test--start-in-gap ()
  "A start point in the gap after a page row belongs to that page.
`seshat-reader--multipage-page-at-pos' 的既有语义：页行后的 gap 归上一页，
因此起点落在第 1 页行后的换行上仍是「从第 1 页开始」，不做「更近页」判定。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2)
    (let* ((gap (1- (seshat-reader-select-cross-page-test--row-start 2)))
           (start (seshat-reader-select-cross-page-test--fake-posn
                   gap (cons 10 700)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (seshat-reader-select-cross-page-test--row-start 2)
                 (cons 200 300))))
      ;; 前提：gap 位置真的被判断成第 1 页（否则本用例测的不是同一件事）。
      (should (= 1 (seshat-reader-select-posn-page start)))
      (should (equal "page-1\npage-2"
                     (seshat-reader-select-extract start end)))
      (should (equal '((text 0 10.0 700.0 200.0 800.0)
                       (text 1 10.0 0.0 200.0 300.0))
                     (seshat-reader-select-cross-page-test--recorded 'text)))
      (should (= 1 (plist-get seshat-reader-select-last :page)))
      (should (equal '(10.0 700.0 200.0 800.0)
                     (plist-get seshat-reader-select-last :rect))))))

(ert-deftest seshat-reader-select-cross-page-test--end-in-gap ()
  "An end point in the gap after a page row belongs to that page.
末点落在第 2 页行后的 gap 上仍是「到第 2 页为止」：第 3 页不参与选区，
因此文本只有两页、页区间只到 2。"
  (seshat-reader-select-cross-page-test--with-reader '(1 2 3)
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 500)))
           (gap (1- (seshat-reader-select-cross-page-test--row-start 3)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 gap (cons 200 300))))
      (should (= 2 (seshat-reader-select-posn-page end)))
      (should (equal "page-1\npage-2"
                     (seshat-reader-select-extract start end)))
      (should (equal '((text 0 10.0 500.0 200.0 800.0)
                       (text 1 10.0 0.0 200.0 300.0))
                     (seshat-reader-select-cross-page-test--recorded 'text)))
      (should (equal '(1 1 2 2)
                     (mapcar #'car (plist-get seshat-reader-select-last
                                              :page-rects)))))))

;;;; 3. T3：旋转页坐标逆变换

;; 正向映射（page space → 旋转后图像空间）由 `render-core.c' 的
;; `fz_transform_page' 推出，并用四象限灰度探针页在 0/90/180/270 四个角度逐像素
;; 核对过（2026-10-27）：页左上角 (0,0) 在 rotate=90 的位图里落在右上角，位图
;; 宽高交换。测试里自己写一遍正向映射，往返用例才能验证「逆变换真的是逆」。

(defun seshat-reader-select-cross-page-test--rotate-point (point rotate size)
  "Map POINT from page space to the image space of the page rotated by ROTATE.
SIZE is the unrotated page size (W . H), as everywhere else in this suite."
  (let ((x (car point))
        (y (cdr point))
        (w (car size))
        (h (cdr size)))
    (pcase rotate
      (90 (cons (- h y) x))
      (180 (cons (- w x) (- h y)))
      (270 (cons y (- w x)))
      (_ (cons x y)))))

(defun seshat-reader-select-cross-page-test--rotate-rect (rect rotate size)
  "Map RECT from page space to the image space of the page rotated by ROTATE."
  (let* ((a (seshat-reader-select-cross-page-test--rotate-point
             (cons (nth 0 rect) (nth 1 rect)) rotate size))
         (b (seshat-reader-select-cross-page-test--rotate-point
             (cons (nth 2 rect) (nth 3 rect)) rotate size)))
    (list (min (car a) (car b)) (min (cdr a) (cdr b))
          (max (car a) (car b)) (max (cdr a) (cdr b)))))

(defun seshat-reader-select-cross-page-test--close (a b)
  "Return non-nil when floats A and B differ by less than 1e-9."
  (< (abs (- a b)) 1e-9))

(ert-deftest seshat-reader-select-cross-page-test--unrotate-roundtrip ()
  "Un-rotating a rotated point gives the original point back, for all angles.
往返恒等是逆变换的定义性要求：正向映射（`--rotate-point'，取自 C 侧公式并经
像素探针核对）与 `seshat-reader-select--unrotate-point' 必须互逆。"
  (let ((size (cons 612.0 792.0)))
    (dolist (rotate '(0 90 180 270))
      (dolist (point '((0.0 . 0.0) (612.0 . 0.0) (0.0 . 792.0)
                       (612.0 . 792.0) (123.5 . 456.25)))
        (let ((back (seshat-reader-select--unrotate-point
                     (seshat-reader-select-cross-page-test--rotate-point
                      point rotate size)
                     rotate size)))
          (should (seshat-reader-select-cross-page-test--close
                   (car point) (car back)))
          (should (seshat-reader-select-cross-page-test--close
                   (cdr point) (cdr back))))))))

(ert-deftest seshat-reader-select-cross-page-test--unrotate-corners ()
  "The four corners of a rotated page map back to the documented corners.
页 600x800（宽 600、高 800）旋转后：90/270 的位图是 800x600，且页左上角在
rotate=90 的位图里落在右上角——这正是像素探针实测到的映射（灰度 0 的页左上角
出现在 90° 图的右上角），因此这里断言的是「实测几何」，不是自洽推演。"
  (let ((size (cons 600.0 800.0)))
    ;; rotate=0：恒等。
    (should (equal (cons 0.0 0.0)
                   (seshat-reader-select--unrotate-point (cons 0.0 0.0) 0 size)))
    (should (equal (cons 600.0 800.0)
                   (seshat-reader-select--unrotate-point
                    (cons 600.0 800.0) 0 size)))
    ;; 尺寸交换：90/270 交换，0/180 不交换。
    (should (equal (cons 800.0 600.0)
                   (seshat-reader-select--unrotate-size size 90)))
    (should (equal (cons 800.0 600.0)
                   (seshat-reader-select--unrotate-size size 270)))
    (should (equal size (seshat-reader-select--unrotate-size size 0)))
    (should (equal size (seshat-reader-select--unrotate-size size 180)))
    ;; rotate=90：位图 800x600 的四角 → 页空间四角（TL→右上、TR→右下…）。
    (should (equal (cons 0.0 800.0)
                   (seshat-reader-select--unrotate-point (cons 0.0 0.0) 90 size)))
    (should (equal (cons 0.0 0.0)
                   (seshat-reader-select--unrotate-point (cons 800.0 0.0) 90 size)))
    (should (equal (cons 600.0 800.0)
                   (seshat-reader-select--unrotate-point
                    (cons 0.0 600.0) 90 size)))
    (should (equal (cons 600.0 0.0)
                   (seshat-reader-select--unrotate-point
                    (cons 800.0 600.0) 90 size)))
    ;; rotate=180：位图仍 600x800，两个轴都镜像。
    (should (equal (cons 600.0 800.0)
                   (seshat-reader-select--unrotate-point (cons 0.0 0.0) 180 size)))
    (should (equal (cons 0.0 0.0)
                   (seshat-reader-select--unrotate-point
                    (cons 600.0 800.0) 180 size)))
    ;; rotate=270：位图 800x600，页左上角落在位图左下角。
    (should (equal (cons 600.0 0.0)
                   (seshat-reader-select--unrotate-point (cons 0.0 0.0) 270 size)))
    (should (equal (cons 0.0 0.0)
                   (seshat-reader-select--unrotate-point
                    (cons 0.0 600.0) 270 size)))
    (should (equal (cons 600.0 800.0)
                   (seshat-reader-select--unrotate-point
                    (cons 800.0 0.0) 270 size)))
    (should (equal (cons 0.0 800.0)
                   (seshat-reader-select--unrotate-point
                    (cons 800.0 600.0) 270 size)))
    ;; 矩形：90° 下两个对角互换，归一化后仍是最小/最大顺序（转置）。
    (should (equal '(100.0 200.0 300.0 500.0)
                   (seshat-reader-select--unrotate-rect
                    (seshat-reader-select-cross-page-test--rotate-rect
                     '(100.0 200.0 300.0 500.0) 90 size)
                    90 size)))))

(ert-deftest seshat-reader-select-cross-page-test--posn->page-rotate-zero-unchanged ()
  "At rotation 0 `posn->page' answers exactly what it answered before T3.
反向断言：0° 是绝大多数页面的情况，逆变换必须是恒等——返回值仍是「图像像素 ×
frame scale / page scale」，不做任何额外的浮点改写。"
  (seshat-reader-select-cross-page-test--with-reader '(1)
    (let* ((posn (seshat-reader-select-cross-page-test--fake-posn
                  (seshat-reader-select-cross-page-test--row-start 1)
                  (cons 10 20)))
           (window (selected-window))
           (page (seshat-reader-select-posn->page posn window)))
      (should (equal (cons 10.0 20.0) page))
      ;; 与「未施加逆变换」的公式逐值相等（frame scale / page scale 都是 1）。
      (should (equal page (cons (* (float 10) (/ 1.0 1.0))
                                (* (float 20) (/ 1.0 1.0))))))))

(ert-deftest seshat-reader-select-cross-page-test--posn->page-rotate-90 ()
  "At rotation 90 `posn->page' maps the rotated offset back to page space.
`posn-object-x-y' 报的是旋转后位图里的偏移；页 600x800 旋转 90° 后位图是
800x600，所以 (100, 50) 对应页空间的 (y, 高 - x) = (50, 700)。"
  (seshat-reader-select-cross-page-test--with-reader '(1)
    (setq-local seshat-reader--multipage-rotate 90)
    (cl-letf (((symbol-function 'posn-object-width-height)
               (lambda (_posn) (cons 800 600))))
      (let* ((posn (seshat-reader-select-cross-page-test--fake-posn
                    (seshat-reader-select-cross-page-test--row-start 1)
                    (cons 100 50)))
             (page (seshat-reader-select-posn->page posn (selected-window))))
        (should (equal (cons 50.0 700.0) page))))))

(ert-deftest seshat-reader-select-cross-page-test--posn-page-extent-rotated ()
  "`--posn-page-extent' answers the unrotated page size at every angle.
`posn-object-width-height' 报的是**已旋转**位图的尺寸，90/270 必须交换回来，
否则用它裁剪出来的矩形会落在页外或切掉页内文字。"
  (seshat-reader-select-cross-page-test--with-reader '(1)
    (let ((posn (seshat-reader-select-cross-page-test--fake-posn
                 (seshat-reader-select-cross-page-test--row-start 1)
                 (cons 0 0)))
          (window (selected-window)))
      ;; rotate=0：位图 600x800，页也是 600x800。
      (should (equal (cons 600.0 800.0)
                     (seshat-reader-select--posn-page-extent posn window)))
      ;; rotate=90：位图 800x600 → 页仍是 600x800。
      (setq-local seshat-reader--multipage-rotate 90)
      (cl-letf (((symbol-function 'posn-object-width-height)
                 (lambda (_posn) (cons 800 600))))
        (should (equal (cons 600.0 800.0)
                       (seshat-reader-select--posn-page-extent posn window))))
      ;; rotate=270 与 90 对称。
      (setq-local seshat-reader--multipage-rotate 270)
      (cl-letf (((symbol-function 'posn-object-width-height)
                 (lambda (_posn) (cons 800 600))))
        (should (equal (cons 600.0 800.0)
                       (seshat-reader-select--posn-page-extent posn window)))))))

(ert-deftest seshat-reader-select-cross-page-test--page-rects-single-page-regression ()
  "A single-page drag produces the same rectangle list as before T3.
反向断言：单页分支根本不看页尺寸，也不做任何旋转换算，值必须与批次 1 逐值相同。"
  (seshat-reader-select-cross-page-test--with-reader '(2)
    (let ((rects (seshat-reader-select--selection-page-rects
                  (cons 10.0 400.0) 2 (cons 200.0 20.0) 2 nil
                  (selected-window))))
      (should (equal '((2 10.0 20.0 200.0 400.0)) rects)))))

(ert-deftest seshat-reader-select-cross-page-test--page-rects-per-page-size ()
  "Every page is clipped to its own height, not to the start page's.
三页分别 600x800 / 600x1000 / 600x400：中间页被整页选中时 y1 必须是它自己的
1000（用起点页的 800 会丢字），末页的 y1 是拖拽点 300（不会超过它自己的 400）。"
  (seshat-reader-select-cross-page-test--with-reader-sizes
      '(1 2 3) '((1 . (600 . 800)) (2 . (600 . 1000)) (3 . (600 . 400)))
    (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 500)))
           (end (seshat-reader-select-cross-page-test--fake-posn
                 (seshat-reader-select-cross-page-test--row-start 3)
                 (cons 20 300))))
      (should (equal "page-1\npage-2\npage-3"
                     (seshat-reader-select-extract start end)))
      (should (equal '((text 0 10.0 500.0 20.0 800.0)
                       (text 1 10.0 0.0 20.0 1000.0)
                       (text 2 10.0 0.0 20.0 300.0))
                     (seshat-reader-select-cross-page-test--recorded 'text)))
      ;; 起点页仍是自己的高度（与批次 1 逐值相同），中间页换成自己的。
      (should (equal '((1 10.0 500.0 20.0 800.0)
                       (2 10.0 0.0 20.0 1000.0)
                       (3 10.0 0.0 20.0 300.0))
                     (seshat-reader-select--selection-page-rects
                      (cons 10.0 500.0) 1 (cons 20.0 300.0) 3 start
                      (selected-window)))))))

(ert-deftest seshat-reader-select-cross-page-test--page-rects-per-page-size-rotated ()
  "Per-page heights stay in page space when the pages are rotated.
rotate=90 时 native 尺寸记的是旋转后的位图（800x600），裁剪要用交换回来的
600x800；否则中间页的 y1 会变成 600，切掉页底 200 的正文。"
  (seshat-reader-select-cross-page-test--with-reader-sizes
      '(1 2 3) '((1 . (800 . 600)) (2 . (800 . 600)) (3 . (800 . 600)))
    (setq-local seshat-reader--multipage-rotate 90)
    (cl-letf (((symbol-function 'posn-object-width-height)
               (lambda (_posn) (cons 800 600))))
      (let ((start (seshat-reader-select-cross-page-test--fake-posn
                    (seshat-reader-select-cross-page-test--row-start 1)
                    (cons 10 500))))
        (should (equal '((1 10.0 500.0 20.0 800.0)
                         (2 10.0 0.0 20.0 800.0)
                         (3 10.0 0.0 20.0 300.0))
                       (seshat-reader-select--selection-page-rects
                        (cons 10.0 500.0) 1 (cons 20.0 300.0) 3 start
                        (selected-window))))))))

(ert-deftest seshat-reader-select-cross-page-test--page-extent-nil-fallback ()
  "A page whose size cannot be measured falls back instead of erroring.
`posn-object-width-height' 在批处理帧里返回 nil；此时既不能报错，也不能把
nil 当高度用——页自身尺寸取不到就退回起点的 extent，再退回常量兜底。

审查修复 F1 之后首页也退到 `height'：起点 extent 量不到就没有换算比例，而
`--page-space-size' 的绝对值与拖拽坐标口径不同（渲染 scale ≠ page scale 时
会偏短），故一概不采信（原来首页拿到 800.0，现在拿到常量 1.0e7——过长无害，
模块只报页内真有的字）。末页仍以拖拽点为下边界。"
  (seshat-reader-select-cross-page-test--with-reader '(1)
    (cl-letf (((symbol-function 'posn-object-width-height)
               (lambda (_posn) nil)))
      (let ((posn (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 1)
                   (cons 10 500))))
        (should-not (seshat-reader-select--posn-page-extent
                     posn (selected-window)))
        ;; 第 1 页有行（native 800）但比例不可用 → 常量；第 2、3 页没有行
        ;; → 同样是常量。
        (should (equal '((1 10.0 500.0 20.0 1.0e7)
                         (2 10.0 0.0 20.0 1.0e7)
                         (3 10.0 0.0 20.0 300.0))
                       (seshat-reader-select--selection-page-rects
                        (cons 10.0 500.0) 1 (cons 20.0 300.0) 3 posn
                        (selected-window))))))))

(ert-deftest seshat-reader-select-cross-page-test--page-rects-uncalibrated-own-not-short ()
  "An unmeasurable start page never lets a raw native height clip a page.
起点页 extent 量不到（批处理帧、无 redisplay 信息）时 `--selection-page-rects'
拿不到换算比例；此时若直接采信 `--page-space-size' 的绝对值（= native ×
frame scale），在渲染 scale ≠ page scale 的页上会偏**短**，矩形切在页内 →
丢字。修法（审查修复 F1）：比例不可用时统一回退到起点页高度（再退常量
`--page-extent-fallback'），宁可过长（模块只报页内真有的字，过长无害）不可
过短。

构造：第 2 页的位图按 scale 4.0 渲染（bitmap 600x3200 → native 600x800），
page scale 是 2.0，frame scale 是 1.0。于是按拖拽坐标口径（图像像素 ×
frame scale / page scale）这一页的真实高度是 3200 / 2.0 = 1600，而
`--page-space-size' 给的 own 只有 native 的 800——采信它就会丢掉下半页。"
  (seshat-reader-select-cross-page-test--with-reader-sizes
      '(1 2 3) '((1 . (600 . 800)) (2 . (600 . 3200)) (3 . (600 . 800)))
    ;; 夹具按 scale 1.0 记了 600x3200，这里改记为 scale 4.0 → native 600x800。
    (seshat-reader--multipage-record-native
     2 (list 'image :type 'canvas :data nil
             :data-width 600 :data-height 3200 :width 600 :height 3200) 4.0)
    (cl-letf (((symbol-function 'seshat-reader-select--page-scale)
               (lambda (_window) 2.0))
              ((symbol-function 'posn-object-width-height)
               (lambda (_posn) nil)))
      (let* ((window (selected-window))
             (start (seshat-reader-select-cross-page-test--fake-posn
                     (seshat-reader-select-cross-page-test--row-start 1)
                     (cons 10 500)))
             (rects (seshat-reader-select--selection-page-rects
                     (cons 10.0 500.0) 1 (cons 20.0 300.0) 3 start window))
             (middle (cdr (assoc 2 rects))))
        ;; 前提：起点页尺寸量不到 → 换算比例不可用。
        (should-not (seshat-reader-select--posn-page-extent start window))
        ;; 中间页的页高（RECT 的第 4 个元素，即 Y1）不是 own 的绝对值 800。
        (should-not (equal 800.0 (nth 3 middle)))
        ;; 也不短于「拖拽点到页底」的真实距离 1600（短了就会丢字）。
        (should (>= (nth 3 middle) 1600.0))
        ;; 具体值：比例不可用 → 退常量兜底（越过页底，模块只报页内真有的字）。
        (should (equal seshat-reader-select--page-extent-fallback
                       (nth 3 middle)))
        ;; 首页同样退兜底、末页仍以拖拽点为下边界。
        (should (equal '((1 10.0 500.0 20.0 1.0e7)
                         (2 10.0 0.0 20.0 1.0e7)
                         (3 10.0 0.0 20.0 300.0))
                       rects))))))

(ert-deftest seshat-reader-select-cross-page-test--join-page-texts-drops-empty-pages ()
  "Empty pages are dropped before joining; a single page keeps its text as is.
多页拼接若对 nil/空串用空串占位并以换行连接，首/末页无文本（图片页）时
`:text' 会出现首尾多余换行（如 \"\\nfoo\\n\"），进而写进批注正文与
`selected_text'。修法（审查修复 F3）：多页分支先过滤 nil 与空串再 `mapconcat'，
过滤后为空则 nil；**单页分支必须原样**（`(car texts)'，不 trim、不过滤），
以维持单页逐字节回归。"
  ;; 多页：首页 / 末页无文本都不留多余换行。
  (should (equal "b\nc" (seshat-reader-select--join-page-texts
                         (list nil "b" "c"))))
  (should (equal "a\nb" (seshat-reader-select--join-page-texts
                         (list "a" "b" nil))))
  ;; 空串与 nil 一视同仁。
  (should (equal "a\nc" (seshat-reader-select--join-page-texts
                         (list "a" "" "c"))))
  (should (equal "a\nc" (seshat-reader-select--join-page-texts
                         (list "" "a" "c" ""))))
  ;; 过滤后一个都不剩 → nil（没有文本可报）。
  (should-not (seshat-reader-select--join-page-texts (list nil "" nil)))
  ;; 单页分支原样返回：不 trim、不过滤空串（逐字节回归）。
  (should (equal "" (seshat-reader-select--join-page-texts (list ""))))
  (should (equal " a " (seshat-reader-select--join-page-texts (list " a "))))
  (should-not (seshat-reader-select--join-page-texts (list nil)))
  ;; 端到端：三页中首页无文本（图片页），`seshat-reader-select-last' 的
  ;; `:text' 不得以换行开头。
  (seshat-reader-select-cross-page-test--with-reader '(1 2 3)
    (cl-letf (((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (page x0 y0 x1 y1)
                 (push (list 'text page x0 y0 x1 y1)
                       seshat-reader-select-cross-page-test--calls)
                 (pcase page
                   (0 nil)
                   (1 "b")
                   (_ "c")))))
      (let* ((start (seshat-reader-select-cross-page-test--fake-posn
                     (seshat-reader-select-cross-page-test--row-start 1)
                     (cons 10 500)))
             (end (seshat-reader-select-cross-page-test--fake-posn
                   (seshat-reader-select-cross-page-test--row-start 3)
                   (cons 20 300))))
        ;; 坐标口径为 (PAGE X0 Y0 X1 Y1)，逐页取文仍按阅读顺序。
        (should (equal "b\nc" (seshat-reader-select-extract start end)))
        (should (equal "b\nc" (plist-get seshat-reader-select-last :text)))))))

;;; seshat-reader-select-cross-page-test.el ends here
