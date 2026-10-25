;;; seshat-reader-annotation-decoration-test.el --- 多段锚与装饰映射测试  -*- lexical-binding: t; -*-

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

;; 本套件覆盖两类**纯函数级**行为，都不加载动态模块、不打开文档、不发请求：
;;
;; 1. **多段 location**：`seshat-reader-annotation--anchor' 接受单 rect 或
;;    rect 列表，多段时写出 `page:<n>;rect:...;rect:...'，并由解析端
;;    `seshat-reader-annotation--rects-from-location' 原样解析回来（往返一致）；
;;    段数超过 `seshat-reader-annotation--anchor-max-segments' 时只写前 N 段
;;    并提示一次。
;; 2. **装饰映射**：`seshat-reader-annotation--decoration-for' 把 (rect, kind)
;;    变换成 8 元素装饰规格（几何 + RGB + alpha），以及
;;    `seshat-reader-annotation--annotation-decorations' /
;;    `--redraw-highlights' 按 kind 走 `--add-highlight'（highlight）或
;;    `--add-decoration'（underline / strikeout）两条投喂路径。
;;
;; 运行方式见 `docs/emacs-reader.md' 的逐文件 ERT 命令（load-path 需含
;; `emacs' 与 `emacs/seshat-reader'）。

;;; Code:

(require 'ert)
(require 'seshat-reader-annotation)

;;; 多段 location：`--anchor'

(defun seshat-reader-annotation-decoration-test--rects (count)
  "构造 COUNT 条互不相同的两位小数矩形，形如 ((1.1 2.2 3.3 4.4) ...)."
  (let (rects)
    (dotimes (i count)
      (let ((base (+ 10.0 (* i 5.0))))
        (push (list base (+ base 1.5) (+ base 3.0) (+ base 4.5)) rects)))
    (nreverse rects)))

(defun seshat-reader-annotation-decoration-test--segments (location)
  "返回 LOCATION 中 \"rect:\" 段的条数（只数字符串，不解析坐标）."
  (let ((start 0)
        (count 0))
    (while (string-match "rect:" location start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest seshat-reader-annotation-decoration-test--anchor-single-rect ()
  "单 rect 调用（引用锚的老调用点形态）输出与改造前逐字一致."
  (should (equal (seshat-reader-annotation--anchor 1 '(10 20 30 40))
                 "page:1;rect:10.00,20.00,30.00,40.00"))
  ;; 单元素列表与裸 rect 等价（调用方把 `:rects' 原样传进来时即此形态）
  (should (equal (seshat-reader-annotation--anchor 1 '((10 20 30 40)))
                 "page:1;rect:10.00,20.00,30.00,40.00")))

(ert-deftest seshat-reader-annotation-decoration-test--anchor-page-only ()
  "rect 为 nil 时退化为纯页锚（只有页锚段，没有 rect 段）."
  (should (equal (seshat-reader-annotation--anchor 7 nil) "page:7"))
  (should (equal (seshat-reader-annotation--anchor 7 '()) "page:7")))

(ert-deftest seshat-reader-annotation-decoration-test--anchor-multi-segments ()
  "多矩形输出 page 段 + 逐段 rect 段，格式与单段逐字一致."
  (should (equal (seshat-reader-annotation--anchor
                  3 '((1.5 2.5 3.5 4.5) (5 6 7 8)))
                 (concat "page:3;rect:1.50,2.50,3.50,4.50"
                         ";rect:5.00,6.00,7.00,8.00"))))

(ert-deftest seshat-reader-annotation-decoration-test--anchor-roundtrip-51 ()
  "51 段矩形写出的 location 能被解析端原样读回（往返相等）."
  (let* ((rects (seshat-reader-annotation-decoration-test--rects 51))
         (location (seshat-reader-annotation--anchor 12 rects)))
    (should (= 51 (seshat-reader-annotation-decoration-test--segments location)))
    (should (= 12 (seshat-reader-annotation--page-from-location location)))
    (should (equal (seshat-reader-annotation--rects-from-location location)
                   rects))))

(ert-deftest seshat-reader-annotation-decoration-test--anchor-truncates-segments ()
  "超过锚段上限时只写前 N 段，并提示一次（第二次不再提示）."
  (let* ((max seshat-reader-annotation--anchor-max-segments)
         (rects (seshat-reader-annotation-decoration-test--rects (+ max 100)))
         (seshat-reader-annotation--anchor-truncation-warned nil)
         (messages nil)
         (location nil)
         (second nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (setq location (seshat-reader-annotation--anchor 1 rects))
      (setq second (seshat-reader-annotation--anchor 1 rects)))
    (should (= max (seshat-reader-annotation-decoration-test--segments location)))
    (should (equal location second))
    (should (= 1 (length messages)))
    (should (string-match-p "上限" (car messages)))
    ;; 截断后的段序列是原序列的前缀
    (should (equal (seshat-reader-annotation--rects-from-location location)
                   (butlast rects (- (length rects) max))))))

(ert-deftest seshat-reader-annotation-decoration-test--anchor-max-segments-below-parser ()
  "锚段上限必须远低于解析端上限，留出余量."
  (should (< seshat-reader-annotation--anchor-max-segments
             seshat-reader-annotation--rect-max-segments))
  (should (= 500 seshat-reader-annotation--anchor-max-segments)))

;;; 选区 → 矩形序列

(ert-deftest seshat-reader-annotation-decoration-test--selection-rects-prefers-rects ()
  ":rects 非 nil 时优先；为 nil 时回落单 rect；两者都缺时为 nil."
  (should (equal (seshat-reader-annotation--selection-rects
                  (list :rect '(0 0 1 1) :rects '((1 1 2 2) (3 3 4 4))))
                 '((1 1 2 2) (3 3 4 4))))
  (should (equal (seshat-reader-annotation--selection-rects
                  (list :rect '(0 0 1 1) :rects nil))
                 '((0 0 1 1))))
  (should-not (seshat-reader-annotation--selection-rects (list :rect nil)))
  (should-not (seshat-reader-annotation--selection-rects nil)))

;;; 装饰映射：`--decoration-for'

(ert-deftest seshat-reader-annotation-decoration-test--decorations-defaults ()
  "装饰相关 defcustom 的默认值；颜色 `:type' 为 (list number number number)."
  (should (equal seshat-reader-annotation-highlight-color '(1.0 0.85 0.0)))
  (should (= 0.35 seshat-reader-annotation-highlight-alpha))
  (should (equal seshat-reader-annotation-underline-color '(0.0 0.45 0.85)))
  (should (= 1.0 seshat-reader-annotation-underline-alpha))
  (should (equal seshat-reader-annotation-strikeout-color '(0.85 0.1 0.1)))
  (should (= 1.0 seshat-reader-annotation-strikeout-alpha))
  (should (= 1.5 seshat-reader-annotation-underline-thickness))
  (should (= 1.5 seshat-reader-annotation-strikeout-thickness))
  (dolist (variable '(seshat-reader-annotation-highlight-color
                      seshat-reader-annotation-underline-color
                      seshat-reader-annotation-strikeout-color))
    (should (equal (get variable 'custom-type)
                   '(list number number number)))))

(ert-deftest seshat-reader-annotation-decoration-test--decoration-for-highlight ()
  "highlight 原样返回矩形，颜色/alpha 与 C 侧默认黄 0.35 逐字一致."
  (should (equal (seshat-reader-annotation--decoration-for
                  '(10.0 20.0 30.0 40.0) "highlight")
                 '(10.0 20.0 30.0 40.0 1.0 0.85 0.0 0.35))))

(ert-deftest seshat-reader-annotation-decoration-test--decoration-for-underline ()
  "underline 把 y0 抬到 y1 - 粗细，形成页面底部的细条."
  (should (equal (seshat-reader-annotation--decoration-for
                  '(10.0 20.0 30.0 40.0) "underline")
                 '(10.0 38.5 30.0 40.0 0.0 0.45 0.85 1.0))))

(ert-deftest seshat-reader-annotation-decoration-test--decoration-for-strikeout ()
  "strikeout 取垂直中线 ± 粗细/2."
  (should (equal (seshat-reader-annotation--decoration-for
                  '(10.0 20.0 30.0 40.0) "strikeout")
                 '(10.0 29.25 30.0 30.75 0.85 0.1 0.1 1.0))))

(ert-deftest seshat-reader-annotation-decoration-test--decoration-for-unknown-kind ()
  "未知 kind（含 nil 与 \"note\"）按 highlight 处理，保持向后兼容."
  (dolist (kind (list nil "note" "ink" "weird" 42))
    (should (equal (seshat-reader-annotation--decoration-for
                    '(10.0 20.0 30.0 40.0) kind)
                   (seshat-reader-annotation--decoration-for
                    '(10.0 20.0 30.0 40.0) "highlight")))))

(ert-deftest seshat-reader-annotation-decoration-test--decoration-for-thin-rect ()
  "行高小于下线粗细时细条不越过矩形上沿（保持 y0 <= y1 的合法矩形）."
  (let ((spec (seshat-reader-annotation--decoration-for
               '(10.0 20.0 30.0 21.0) "underline")))
    (should (equal (list (nth 1 spec) (nth 3 spec)) '(20.0 21.0)))))

(ert-deftest seshat-reader-annotation-decoration-test--decoration-for-respects-custom ()
  "自定义颜色/透明度后映射结果随之变化（不是硬编码常量）."
  (let ((seshat-reader-annotation-underline-color '(0.2 0.3 0.4))
        (seshat-reader-annotation-underline-alpha 0.5)
        (seshat-reader-annotation-underline-thickness 2.0))
    (should (equal (seshat-reader-annotation--decoration-for
                    '(0.0 0.0 10.0 10.0) "underline")
                   '(0.0 8.0 10.0 10.0 0.2 0.3 0.4 0.5)))))

;;; 条目 → 装饰序列

(ert-deftest seshat-reader-annotation-decoration-test--annotation-decorations-kinds ()
  "`--annotation-decorations' 每段输出 6 元素 (PAGE X0 Y0 X1 Y1 KIND)."
  (should (equal (seshat-reader-annotation--annotation-decorations
                  (list (list :id 1 :kind "underline"
                              :location "page:2;rect:1,2,3,4;rect:5,6,7,8")
                        (list :id 2 :kind "strikeout"
                              :location "page:3;rect:9,10,11,12")
                        (list :id 3 :location "page:4;rect:13,14,15,16")
                        (list :id 4 :kind "note"
                              :location "page:5;rect:17,18,19,20")
                        (list :id 5 :location "page:6")))
                 '((2 1.0 2.0 3.0 4.0 "underline")
                   (2 5.0 6.0 7.0 8.0 "underline")
                   (3 9.0 10.0 11.0 12.0 "strikeout")
                   (4 13.0 14.0 15.0 16.0 "highlight")
                   (5 17.0 18.0 19.0 20.0 "highlight")))))

(ert-deftest seshat-reader-annotation-decoration-test--annotation-rects-still-five ()
  "`--annotation-rects' 保持 5 元素（省略 kind），既有调用方不受影响."
  (should (equal (seshat-reader-annotation--annotation-rects
                  (list (list :id 1 :kind "underline"
                              :location "page:2;rect:1,2,3,4")))
                 '((2 1.0 2.0 3.0 4.0)))))

;;; 投喂路径：highlight 走 `--add-highlight'，细条走 `--add-decoration'

(defmacro seshat-reader-annotation-decoration-test--with-stubs (cell &rest body)
  "在四个 C 层函数被桩替的环境中求值 BODY，调用记录进 CELL 的 car.
记录形态：`clear'、`refresh'、`(add PAGE X0 Y0 X1 Y1)'（highlight 路径）与
`(deco PAGE X0 Y0 X1 Y1 R G B ALPHA)'（装饰路径）。"
  (declare (indent 1) (debug t))
  (let ((var (make-symbol "cell")))
    `(let ((,var ,cell))
       (cl-letf (((symbol-function 'seshat-reader-dyn--clear-highlights)
                  (lambda () (push 'clear (car ,var)) t))
                 ((symbol-function 'seshat-reader-dyn--add-highlight)
                  (lambda (page x0 y0 x1 y1)
                    (push (list 'add page x0 y0 x1 y1) (car ,var))
                    t))
                 ((symbol-function 'seshat-reader-dyn--add-decoration)
                  (lambda (page x0 y0 x1 y1 r g b alpha)
                    (push (list 'deco page x0 y0 x1 y1 r g b alpha) (car ,var))
                    t))
                 ((symbol-function 'seshat-reader-dyn--refresh-highlights)
                  (lambda () (push 'refresh (car ,var)) t)))
         ,@body))))

(ert-deftest seshat-reader-annotation-decoration-test--redraw-routes-by-kind ()
  "highlight 走 `--add-highlight'，underline/strikeout 走 `--add-decoration'."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil))
    (seshat-reader-annotation-decoration-test--with-stubs cell
      (let ((count (seshat-reader-annotation--redraw-highlights
                    (seshat-reader-annotation--annotation-decorations
                     (list (list :id 1 :kind "highlight"
                                 :location "page:1;rect:1,2,3,4")
                           (list :id 2 :kind "underline"
                                 :location "page:1;rect:5,6,7,8")
                           (list :id 3 :kind "strikeout"
                                 :location "page:1;rect:9,10,11,12"))))))
        (should (= 3 count))
        (should (equal (nreverse (car cell))
                       '(clear
                         (add 1 1.0 2.0 3.0 4.0)
                         (deco 1 5.0 6.5 7.0 8.0 0.0 0.45 0.85 1.0)
                         (deco 1 9.0 10.25 11.0 11.75 0.85 0.1 0.1 1.0)
                         refresh)))))))

(ert-deftest seshat-reader-annotation-decoration-test--redraw-accepts-plain-rects ()
  "5 元素（无 kind）入参按 highlight 投喂——既有调用方口径不变."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil))
    (seshat-reader-annotation-decoration-test--with-stubs cell
      (should (= 1 (seshat-reader-annotation--redraw-highlights
                    '((2 1.0 2.0 3.0 4.0)))))
      (should (equal (nreverse (car cell))
                     '(clear (add 2 1.0 2.0 3.0 4.0) refresh))))))

(ert-deftest seshat-reader-annotation-decoration-test--redraw-custom-highlight-color ()
  "自定义 highlight 颜色后改走 `--add-decoration'（默认色才走旧入口）."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil)
        (seshat-reader-annotation-highlight-color '(0.1 0.2 0.3)))
    (seshat-reader-annotation-decoration-test--with-stubs cell
      (should (= 1 (seshat-reader-annotation--redraw-highlights
                    '((1 1.0 2.0 3.0 4.0)))))
      (should (equal (nreverse (car cell))
                     '(clear (deco 1 1.0 2.0 3.0 4.0 0.1 0.2 0.3 0.35) refresh))))))

(ert-deftest seshat-reader-annotation-decoration-test--redraw-decoration-failure-counted ()
  "单条装饰投喂失败不计入返回值、不抛错，且不冒充「模块不可用」.
归因分开后：模块入口齐全（`fboundp' 为 t）而某一条投喂抛错属「单条失败」，
默认只静默计数，不与「装饰模块不可用」共用同一条提示。"
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil)
        (seshat-reader-annotation--highlight-warned nil)
        (seshat-reader-annotation--feed-failure-report nil)
        (messages nil))
    (cl-letf (((symbol-function 'seshat-reader-dyn--clear-highlights) (lambda () t))
              ((symbol-function 'seshat-reader-dyn--add-highlight)
               (lambda (&rest _) t))
              ((symbol-function 'seshat-reader-dyn--add-decoration)
               (lambda (&rest _) (error "Module function not available")))
              ((symbol-function 'seshat-reader-dyn--refresh-highlights) (lambda () t))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      ;; 只有「模块不可用」才一次性提示；这里模块齐全，故默认完全静默
      (should (= 0 (seshat-reader-annotation--redraw-highlights
                    '((1 1.0 2.0 3.0 4.0 "underline")))))
      (should-not messages)
      (should-not seshat-reader-annotation--highlight-warned)
      ;; 打开失败回报开关后才提示，且措辞指向「投喂失败」而非「模块不可用」
      (let ((seshat-reader-annotation--feed-failure-report t))
        (should (= 0 (seshat-reader-annotation--redraw-highlights
                      '((1 1.0 2.0 3.0 4.0 "underline")))))
        (should (= 1 (length messages)))
        (should (string-match-p "投喂失败" (car messages)))
        (should-not (string-match-p "模块不可用" (car messages)))))
    (ignore cell)))

(ert-deftest seshat-reader-annotation-decoration-test--probe-needs-decoration-entry ()
  "模块探测必须包含 `--add-decoration'：缺该入口时提示一次、underline 计失败且不抛错."
  (let ((seshat-reader-select--flash-rects nil)
        (seshat-reader-annotation--highlight-warned nil)
        (real (and (fboundp 'seshat-reader-dyn--add-decoration)
                   (symbol-function 'seshat-reader-dyn--add-decoration)))
        (messages nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-dyn--clear-highlights)
                   (lambda () t))
                  ((symbol-function 'seshat-reader-dyn--add-highlight)
                   (lambda (&rest _) t))
                  ((symbol-function 'seshat-reader-dyn--refresh-highlights)
                   (lambda () t))
                  ((symbol-function 'seshat-reader-dyn--add-decoration)
                   (lambda (&rest _) t))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          ;; 桩替期间 `fboundp' 恒为 t，故单独取消定义来模拟「模块是装饰表之前
          ;; 的旧版、没有装饰入口」。
          (fmakunbound 'seshat-reader-dyn--add-decoration)
          (should-not (seshat-reader-annotation--highlight-module-available-p))
          ;; underline 投喂计为失败（返回 0），且只有一条提示
          (should (= 0 (seshat-reader-annotation--redraw-highlights
                        '((1 1.0 2.0 3.0 4.0 "underline")))))
          (should (= 1 (length messages)))
          (should (string-match-p "装饰模块不可用" (car messages)))
          (should (string-match-p "装饰入口" (car messages)))
          ;; 第二次刷新仍返回 0，但不重复提示
          (should (= 0 (seshat-reader-annotation--redraw-highlights
                        '((1 1.0 2.0 3.0 4.0 "strikeout")))))
          (should (= 1 (length messages))))
      (when real
        (fset 'seshat-reader-dyn--add-decoration real)))))

(provide 'seshat-reader-annotation-decoration-test)

;;; seshat-reader-annotation-decoration-test.el ends here
