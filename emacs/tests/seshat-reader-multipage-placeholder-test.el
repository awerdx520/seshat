;;; seshat-reader-multipage-placeholder-test.el --- Tests for sized placeholder rows  -*- lexical-binding: t; -*-

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

;; 阅读器 P2-B「两阶段渲染」T3 的 ERT 测试套件：已定尺寸、尚未渲染的页行
;; （第三种状态，见计划 D2/D3）。
;;
;; 要钉的只有一条不变量：占位态的几何 == 已渲染态的几何。真机上它是「页面行高
;; 相等、居中位置相等」（批次 0 的 S2 已实测 4/4 组差 0 px），batch 里没有
;; redisplay，故这里把同一件事翻译成机械可查的等价断言：
;;
;;   1) 占位行的 display 属性是 (space :width (W) :height (H)) —— 括号形式，
;;      不是裸数字（裸数字被当作字体倍数，实测行高 19008px vs 792px）；
;;   2) 页高两态相等（--multipage-page-pixel-height）；
;;   3) 最大页宽两态相等（--multipage-max-page-width）；
;;   4) 居中判定两态相等（--multipage-page-should-center-p，用桩控制窗口宽度，
;;      不依赖真实 redisplay）；
;;   5) 补位（占位 -> 写入 spec）不改任何页 marker 位置、不改行文本；
;;   6) 尺寸未知（无模块 / 无缓存）时退回旧的零高占位且不报错；
;;   7) --multipage-resize-spec 对 spec=nil 安全（返回 nil、不抛错）；
;;   8) 占位行与已渲染行由同一个构造器产出（align-to 形态与居中逻辑同源）。
;;
;; 尺寸缓存用 seshat-reader-dyn--page-size 的桩喂入：桩不依赖已构建的 .so 与
;; 真实 PDF，整套用例在 Emacs -Q --batch 下恒可复现（skip-unless 恒 0）。
;; 真机验收（滚动无跳变）随 T6 的调度器一起做 —— 单 T3 完成时还没有任何路径会
;; 让页面停在「仅尺寸」态，故无法观察。
;;
;; 运行方式（在仓库根目录执行，或直接 make -C emacs/tests ert）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader \
;;     -l ert -l emacs/tests/seshat-reader-multipage-placeholder-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)


;;; 夹具

(defmacro seshat-reader-multipage-placeholder-test--with-buffer (&rest body)
  "Run BODY in a clean temporary buffer.

三个 buffer-local 状态（页表 + 两套缓存）显式清空，用例之间互不影响。
`seshat-reader-page-separator' 关掉：分隔行与页行几何无关，去掉它让断言只面
对页行本身（页行始终是「两个空格 + 换行」）。
`window-body-width' 桩成 2000 像素：`--batch' 的 frame 只有 80 像素宽，任何真实
页面都会被判成「比窗口宽」，占位行就会走贴左分支 —— 那是正确行为，但会让「居中
规格」相关断言失去意义。需要窄窗口的用例在内部再桩一次即可（内层优先）。"
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq-local seshat-reader--pages nil)
     (setq-local seshat-reader--page-spec-cache nil)
     (setq-local seshat-reader--multipage-page-sizes nil)
     (let ((seshat-reader-page-separator nil))
       (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 2000)))
         ,@body))))

(defmacro seshat-reader-multipage-placeholder-test--with-size (size &rest body)
  "Stub the native size entry point to answer SIZE within BODY.

SIZE 每次调用时求值，便于用例中途改它（nil 模拟「无尺寸」，如未构建模块）。
桩定义在符号上，故 `fboundp' 随之为真 —— `seshat-reader--page-size' 的
`fboundp' 守卫因此放行，走的是真实包装层（含写入缓存）。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'seshat-reader-dyn--page-size)
              (lambda (&rest _args) ,size)))
     ,@body))

(defun seshat-reader-multipage-placeholder-test--fake-spec (width height)
  "Return a fake image spec WIDTH x HEIGHT pixels."
  (list 'image :width width :height height))

(defun seshat-reader-multipage-placeholder-test--row-start (page)
  "Return the buffer position where the row of PAGE starts, or nil."
  (let ((entry (assq page seshat-reader--pages)))
    (and entry (marker-position (cadr entry)))))

(defun seshat-reader-multipage-placeholder-test--guide (page)
  "Return the display property of the first character of the row of PAGE."
  (get-text-property (seshat-reader-multipage-placeholder-test--row-start page)
                     'display))

(defun seshat-reader-multipage-placeholder-test--body (page)
  "Return the display property of the second character of the row of PAGE."
  (get-text-property
   (1+ (seshat-reader-multipage-placeholder-test--row-start page))
   'display))

(defun seshat-reader-multipage-placeholder-test--marker-positions ()
  "Return the marker positions of every page row, in layout order."
  (mapcar (lambda (entry) (marker-position (cadr entry)))
          seshat-reader--pages))

(defun seshat-reader-multipage-placeholder-test--warm-size (page &optional size)
  "Measure PAGE at scale 1.0 with the native stub, SIZE defaults to 612x792."
  (seshat-reader-multipage-placeholder-test--with-size
      (or size (list 612 792))
    (seshat-reader--page-size page 1.0 0)))


;;; 1) 占位行结构：space 规格的 W/H 是像素（括号形式）

(ert-deftest seshat-reader-multipage-placeholder-test--row-uses-pixel-form ()
  "A page of known size but no pixels gets a pixel-sized space row.

W/H 必须是 (612) / (792) 这样的列表元素：裸数字在 display 规格里是字体倍数，
批次 0 实测 (space :width 612 :height 792) 行高 19008px（= 792 x 24），而像素
形式正好 792px。故这里既断言值，也断言「不是裸数字」。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (let ((body (seshat-reader-multipage-placeholder-test--body 1)))
      (should (eq (car-safe body) 'space))
      (should (equal (plist-get (cdr body) :width) '(612)))
      (should (equal (plist-get (cdr body) :height) '(792)))
      (should-not (integerp (plist-get (cdr body) :width)))
      (should-not (integerp (plist-get (cdr body) :height))))
    ;; 行文本仍是两个空格 + 换行：字符数与已渲染态一致。
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "  \n"))
    ;; 居中规格来自同一个构造器，形态为 (+ center (-0.5 (W)))。
    (should (equal (seshat-reader-multipage-placeholder-test--guide 1)
                   (list 'space :align-to
                         (list '+ 'center (cons -0.5 '(612))))))))

(ert-deftest seshat-reader-multipage-placeholder-test--row-keeps-text-length ()
  "The placeholder row is the same three characters as a rendered one.

补位前后行文本必须一字不差，P1/P2 反复出问题的就是「换文本 -> 移动 marker」。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (let ((placeholder (buffer-substring-no-properties (point-min) (point-max)))
          (spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      (seshat-reader--multipage-insert-page 1 spec)
      (should (= 3 (length placeholder)))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     placeholder)))))


;;; 2) 页高两态一致

(ert-deftest seshat-reader-multipage-placeholder-test--height-equals-rendered ()
  "Placeholder height == rendered height for the same page.

这是把真机断言「占位行高 == 该页真实 image 行高」翻译成 batch 可机械检查的等
价形式：滚动范围只读 `--multipage-page-pixel-height'，两态相等即不跳变。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (let ((placeholder-height (seshat-reader--multipage-page-pixel-height 1))
          (spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      (should (= 792 placeholder-height))
      (should (= placeholder-height
                 (seshat-reader--multipage-page-span 1)))
      (seshat-reader--multipage-insert-page 1 spec)
      (should (= placeholder-height
                 (seshat-reader--multipage-page-pixel-height 1))))))

(ert-deftest seshat-reader-multipage-placeholder-test--height-without-size-is-zero ()
  "A page of unknown size still reports height 0 and reserves nothing."
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader--multipage-insert-page 1 nil)
    (should (= 0 (seshat-reader--multipage-page-pixel-height 1)))
    ;; span 下限 1：滚动循环永远推进（既有行为，不能被本批破坏）。
    (should (= 1 (seshat-reader--multipage-page-span 1)))))


;;; 3) 最大页宽两态一致

(ert-deftest seshat-reader-multipage-placeholder-test--max-width-equals-rendered ()
  "The horizontal bound is the same before and after the pixels arrive."
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (let ((spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      (should (= 612 (seshat-reader--multipage-max-page-width)))
      (seshat-reader--multipage-insert-page 1 spec)
      (should (= 612 (seshat-reader--multipage-max-page-width))))))

(ert-deftest seshat-reader-multipage-placeholder-test--max-width-uses-widest-page ()
  "A placeholder wider than every rendered page still widens the bound.

只读「已渲染页」的旧口径会漏掉这一页，横向滚动界因此在补位前后不同。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 2 (list 1200 900))
    (seshat-reader--multipage-insert-page
     1 (seshat-reader-multipage-placeholder-test--fake-spec 600 800))
    (seshat-reader--multipage-insert-page 2 nil)
    (should (= 1200 (seshat-reader--multipage-max-page-width)))))


;;; 4) 居中判定两态一致

(ert-deftest seshat-reader-multipage-placeholder-test--centering-equals-rendered ()
  "The centring decision is the same in both states, narrow and wide window.

窗口宽度用桩控制（`window-body-width'），不依赖真实 redisplay。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (let ((window (selected-window))
          (spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      ;; 占位态：窗口比页宽 -> 居中；窗口比页窄 -> 贴左。
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 1000)))
        (should (seshat-reader--multipage-page-should-center-p 1 window)))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500)))
        (should-not (seshat-reader--multipage-page-should-center-p 1 window)))
      ;; 已渲染态：同一判定，逐条相同。
      (seshat-reader--multipage-insert-page 1 spec)
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 1000)))
        (should (seshat-reader--multipage-page-should-center-p 1 window)))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 500)))
        (should-not (seshat-reader--multipage-page-should-center-p 1 window))))))

(ert-deftest seshat-reader-multipage-placeholder-test--centered-p-true ()
  "`--multipage-page-centered-p' answers t for a correctly centred placeholder.

它决定 `--centered-p' / `--ensure-centered' 是否每帧重写该行：返回 nil 会让
占位行在每一帧都被判为「摆放已过期」而重写一次 display 属性。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (should (seshat-reader--multipage-page-centered-p 1))
    ;; 贴左之后不再是居中态。
    (seshat-reader--multipage-set-page-centered 1 nil)
    (should-not (seshat-reader--multipage-page-centered-p 1))
    ;; 回到居中态。
    (seshat-reader--multipage-set-page-centered 1 t)
    (should (seshat-reader--multipage-page-centered-p 1))
    ;; 几何变了（更新的尺寸条目排在缓存最前）-> 判定过期，免得留下旧 align-to。
    (push (cons (seshat-reader--page-spec-key 1 2.0 0) (cons 1224 1584))
          seshat-reader--multipage-page-sizes)
    (should-not (seshat-reader--multipage-page-centered-p 1))))


;;; 5) 补位不改 marker、不改行文本

(ert-deftest seshat-reader-multipage-placeholder-test--fill-moves-no-marker ()
  "Filling a placeholder in changes properties only.

记录插入后各页 marker 的位置与整段文本，模拟「占位 -> 渲染完成写入 spec」，
断言 marker 全部不动、文本一字不差、该行属性换成 spec —— 这就是补位路径的全部
契约。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (dolist (page '(1 2 3))
      (seshat-reader-multipage-placeholder-test--warm-size page)
      (seshat-reader--multipage-insert-page page nil))
    (let* ((before (seshat-reader-multipage-placeholder-test--marker-positions))
           (text (buffer-substring-no-properties (point-min) (point-max)))
           (spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      (should (= 3 (length before)))
      ;; 补位：只写 display 属性（既有 `--multipage-write-row'）。
      (seshat-reader--multipage-insert-page 2 spec)
      (should (equal before
                     (seshat-reader-multipage-placeholder-test--marker-positions)))
      (should (equal text
                     (buffer-substring-no-properties (point-min) (point-max))))
      ;; 该行确实换成了 spec（按身份，不是等值的新对象）。
      (should (eq (seshat-reader-multipage-placeholder-test--body 2) spec))
      (should (eq (cddr (assq 2 seshat-reader--pages)) spec))
      ;; 另外两页仍是占位态，且几何未变。
      (should (= 792 (seshat-reader--multipage-page-pixel-height 1)))
      (should (= 792 (seshat-reader--multipage-page-pixel-height 3))))))

(ert-deftest seshat-reader-multipage-placeholder-test--fill-keeps-centring ()
  "The fill path keeps a centred placeholder centred (no sideways jump).

`--multipage-insert-page' 用 `--multipage-page-centered-p' 保留既有的居中状态；
占位态若判成「不居中」，补位那一刻会先贴左（再由 `--render-page' 纠正），视觉
上就是横向跳一下。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (let ((spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      (seshat-reader--multipage-insert-page 1 spec)
      ;; 引导空格仍带居中规格，且引用的是新 spec 对象。
      (should (equal (seshat-reader-multipage-placeholder-test--guide 1)
                     (seshat-reader--multipage-align-to spec)))
      (should (seshat-reader--multipage-page-centered-p 1)))))


;;; 6) 无尺寸时退回零高占位

(ert-deftest seshat-reader-multipage-placeholder-test--degrades-without-size ()
  "Without a measurable size the row is the old property-less placeholder.

尺寸未知（未构建模块 / 页越界 / 文档正在重载）时必须退回两个空格、无 display
属性、页高 0，且不报错 —— 降级不能比现状更差。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    ;; 桩返回 nil：包装层不写缓存，等价于「没有尺寸」。
    (seshat-reader-multipage-placeholder-test--with-size nil
      (should-not (seshat-reader--page-size 1 1.0 0)))
    (seshat-reader--multipage-insert-page 1 nil)
    (should-not (seshat-reader-multipage-placeholder-test--guide 1))
    (should-not (seshat-reader-multipage-placeholder-test--body 1))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "  \n"))
    (should (= 0 (seshat-reader--multipage-page-pixel-height 1)))
    (should-not (seshat-reader--multipage-max-page-width))))

(ert-deftest seshat-reader-multipage-placeholder-test--row-builder-without-page ()
  "The row builder still works when the page number is unknown.

`--multipage-page-row' 的两参调用是既有契约（测试与老路径都这么调），新增的第
三个参数必须是可选的。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (should (equal (seshat-reader--multipage-page-row nil) "  \n"))
    (should (equal (seshat-reader--multipage-page-row nil nil 42) "  \n"))
    (let* ((spec (seshat-reader-multipage-placeholder-test--fake-spec 10 10))
           (expected (concat (propertize " " 'display
                                         (seshat-reader--multipage-align-to spec))
                             (propertize " " 'display spec)
                             "\n")))
      (should (equal (seshat-reader--multipage-page-row spec) expected)))))


;;; 7) `--multipage-resize-spec' 对 spec=nil 安全

(ert-deftest seshat-reader-multipage-placeholder-test--resize-spec-safe ()
  "Resizing a placeholder is a no-op instead of a signal.

占位态没有 spec，`setf (image-property nil :width)' 会抛错，故这一步必须安全跳
过；页行尺寸由尺寸缓存决定，重排不该碰它。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (seshat-reader--multipage-insert-page 1 nil)
    (should-not (seshat-reader--multipage-resize-spec 1))
    (should (= 792 (seshat-reader--multipage-page-pixel-height 1)))
    (should (equal (seshat-reader-multipage-placeholder-test--body 1)
                   '(space :width (612) :height (792))))
    ;; 连行都没有的页同样安全。
    (should-not (seshat-reader--multipage-resize-spec 99))))


;;; 8) 占位与已渲染共用同一套构造

(ert-deftest seshat-reader-multipage-placeholder-test--single-constructor ()
  "Both states come out of `--multipage-row-properties'.

两套构造是 P1 的教训（页底死区）：这里直接断言「写进 buffer 的属性 == 同一个
构造器对同一入参的结果」，以及两态 align-to 形态完全同构。"
  (seshat-reader-multipage-placeholder-test--with-buffer
    (seshat-reader-multipage-placeholder-test--warm-size 1)
    (let ((spec (seshat-reader-multipage-placeholder-test--fake-spec 612 792)))
      ;; 占位态：构造器返回值与实际写进 buffer 的属性逐字相同。
      (seshat-reader--multipage-insert-page 1 nil)
      (should (equal (seshat-reader-multipage-placeholder-test--body 1)
                     (cdr (seshat-reader--multipage-row-properties 1 nil))))
      (should (equal (seshat-reader-multipage-placeholder-test--guide 1)
                     (car (seshat-reader--multipage-row-properties 1 nil))))
      ;; 已渲染态：同上，且 BODY 就是 spec 对象本身。
      (seshat-reader--multipage-insert-page 1 spec)
      (should (eq (seshat-reader-multipage-placeholder-test--body 1) spec))
      (should (eq (cdr (seshat-reader--multipage-row-properties 1 spec)) spec))
      ;; 两态 align-to 同构：(+ center (-0.5 . SOURCE))。
      (let* ((placeholder
              (plist-get (cdr (car (seshat-reader--multipage-row-properties 1 nil)))
                         :align-to))
             (rendered
              (plist-get (cdr (car (seshat-reader--multipage-row-properties 1 spec)))
                         :align-to)))
        (should (eq (car placeholder) '+))
        (should (eq (car rendered) '+))
        (should (eq (car (cdr placeholder)) 'center))
        (should (eq (car (cdr rendered)) 'center))
        (should (equal (cdr (nth 2 placeholder)) '(612)))
        (should (eq (cdr (nth 2 rendered)) spec))))))

(provide 'seshat-reader-multipage-placeholder-test)

;;; seshat-reader-multipage-placeholder-test.el ends here
