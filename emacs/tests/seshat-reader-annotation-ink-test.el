;;; seshat-reader-annotation-ink-test.el --- ink location 解析测试  -*- lexical-binding: t; -*-

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

;; 本套件覆盖 `seshat-reader-annotation--ink-strokes-from-location' 与它的
;; 颜色解析辅助 `seshat-reader-annotation--ink-color-from-hex'——都是**纯
;; 函数级**行为：不加载动态模块、不打开文档、不发请求、不写文件。
;;
;; 契约（keystone 仓 `docs/api.md' §4.5.1）：
;;
;;   page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,<x1>,<y1>,...
;;
;; 断言集中在四件事上：
;;
;; 1. 合法笔迹的字段映射（页码 1-based 原样、`#AARRGGBB' → R/G/B/ALPHA
;;    0..1、宽度 pt、扁平点列、TRUNCATED 标记）；
;; 2. 一个 location 内的**多笔**顺序与串内一致；
;; 3. 降级形态（无点列）与无 `ink:' 段时返回 nil（无几何）；
;; 4. 单笔级的**整条跳过**：颜色非法、宽度非数字、点数成对、坐标有限，
;;    任一不满足即丢掉整笔而不是丢掉坏的那一个点。
;;
;; 运行方式见 `docs/emacs-reader.md' 的逐文件 ERT 命令（load-path 需含
;; `emacs' 与 `emacs/seshat-reader'）。

;;; Code:

(require 'ert)
(require 'seshat-reader-annotation)

;;; 辅助

(defun seshat-reader-annotation-ink-test--close (got want)
  "判断 GOT 与 WANT 在 1e-9 容差内相等（浮点字段断言用）."
  (and (numberp got) (numberp want) (< (abs (- got want)) 1e-9)))

(defun seshat-reader-annotation-ink-test--color (value)
  "返回 VALUE 除以 255 的浮点值（颜色分量归一化口径）."
  (/ (float value) 255.0))

(defun seshat-reader-annotation-ink-test--location (points)
  "按扁平坐标列表 POINTS 构造一条合法 ink location 字符串（页码 1）."
  (format "page:1;ink:#FF1E88E5,2.50%s"
          (mapconcat (lambda (value) (format ",%.2f" (float value)))
                     points "")))

(defun seshat-reader-annotation-ink-test--points (count)
  "构造 COUNT 个点的扁平坐标列表（第 i 点坐标为 (2i, 2i+1)）."
  (let (values)
    (dotimes (i count)
      (push (* 2.0 i) values)
      (push (+ (* 2.0 i) 1.0) values))
    (nreverse values)))

;;; 颜色解析

(ert-deftest seshat-reader-annotation-ink-test--color-from-hex ()
  "`#AARRGGBB' 解出 (R G B ALPHA)，alpha 取最高字节."
  (let ((color (seshat-reader-annotation--ink-color-from-hex "#FF1E88E5")))
    (should (= 4 (length color)))
    (should (seshat-reader-annotation-ink-test--close
             (nth 0 color) (seshat-reader-annotation-ink-test--color #x1E)))
    (should (seshat-reader-annotation-ink-test--close
             (nth 1 color) (seshat-reader-annotation-ink-test--color #x88)))
    (should (seshat-reader-annotation-ink-test--close
             (nth 2 color) (seshat-reader-annotation-ink-test--color #xE5)))
    (should (seshat-reader-annotation-ink-test--close (nth 3 color) 1.0)))
  ;; 半透明：alpha 是最高字节，不是最低字节
  (let ((color (seshat-reader-annotation--ink-color-from-hex "#80FF0000")))
    (should (seshat-reader-annotation-ink-test--close (nth 0 color) 1.0))
    (should (seshat-reader-annotation-ink-test--close (nth 1 color) 0.0))
    (should (seshat-reader-annotation-ink-test--close (nth 2 color) 0.0))
    (should (seshat-reader-annotation-ink-test--close
             (nth 3 color) (seshat-reader-annotation-ink-test--color #x80)))))

(ert-deftest seshat-reader-annotation-ink-test--color-from-hex-rejects ()
  "非 8 位形态（#RGB / #RRGGBB / 缺 # / 非十六进制）一律返回 nil."
  (should-not (seshat-reader-annotation--ink-color-from-hex "#FFF"))
  (should-not (seshat-reader-annotation--ink-color-from-hex "#FF1E88"))
  (should-not (seshat-reader-annotation--ink-color-from-hex "FF1E88E5"))
  (should-not (seshat-reader-annotation--ink-color-from-hex "#GGGGGGGG"))
  (should-not (seshat-reader-annotation--ink-color-from-hex "#FF1E88E"))
  (should-not (seshat-reader-annotation--ink-color-from-hex ""))
  (should-not (seshat-reader-annotation--ink-color-from-hex nil)))

;;; 正常形态

(ert-deftest seshat-reader-annotation-ink-test--single-stroke ()
  "单笔 3 点：页码、颜色、宽度、点列逐个断言，TRUNCATED 为 nil."
  (let* ((location (concat "page:3;ink:#FF1E88E5,2.50"
                           ",10.00,20.00,30.00,40.00,50.00,60.00"))
         (strokes (seshat-reader-annotation--ink-strokes-from-location location)))
    (should (= 1 (length strokes)))
    (let ((stroke (car strokes)))
      (should (= 8 (length stroke)))
      (should (equal (nth 0 stroke) 3))
      (should (seshat-reader-annotation-ink-test--close
               (nth 1 stroke) (seshat-reader-annotation-ink-test--color #x1E)))
      (should (seshat-reader-annotation-ink-test--close
               (nth 2 stroke) (seshat-reader-annotation-ink-test--color #x88)))
      (should (seshat-reader-annotation-ink-test--close
               (nth 3 stroke) (seshat-reader-annotation-ink-test--color #xE5)))
      (should (seshat-reader-annotation-ink-test--close (nth 4 stroke) 1.0))
      (should (seshat-reader-annotation-ink-test--close (nth 5 stroke) 2.5))
      (should (equal (nth 6 stroke) '(10.0 20.0 30.0 40.0 50.0 60.0)))
      (should-not (nth 7 stroke)))))

(ert-deftest seshat-reader-annotation-ink-test--multiple-strokes ()
  "同一 location 内的两个 ink 段解析为两条结果，顺序与串内一致."
  (let* ((location (concat "page:2;ink:#FF000000,1.00,1.00,2.00"
                           ";ink:#80112233,3.50,4.00,5.00,6.00,7.00"))
         (strokes (seshat-reader-annotation--ink-strokes-from-location location)))
    (should (= 2 (length strokes)))
    (should (equal (nth 0 (nth 0 strokes)) 2))
    (should (seshat-reader-annotation-ink-test--close
             (nth 5 (nth 0 strokes)) 1.0))
    (should (equal (nth 6 (nth 0 strokes)) '(1.0 2.0)))
    ;; 第二笔：alpha #x80、宽度 3.5、两点
    (should (seshat-reader-annotation-ink-test--close
             (nth 4 (nth 1 strokes)) (seshat-reader-annotation-ink-test--color #x80)))
    (should (seshat-reader-annotation-ink-test--close
             (nth 5 (nth 1 strokes)) 3.5))
    (should (equal (nth 6 (nth 1 strokes)) '(4.0 5.0 6.0 7.0)))))

(ert-deftest seshat-reader-annotation-ink-test--page-anchor-preserved ()
  "页码原样取 `page:<n>'，不做 +1/-1 换算；多点笔迹保持页面顺序."
  (let* ((location (concat "page:42;ink:#FF112233,0.50"
                           ",1.00,2.00,3.00,4.00,5.00,6.00,7.00,8.00"))
         (stroke (car (seshat-reader-annotation--ink-strokes-from-location
                       location))))
    (should (equal (nth 0 stroke) 42))
    (should (equal (nth 6 stroke) '(1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0)))))

;;; 降级 / 缺失形态

(ert-deftest seshat-reader-annotation-ink-test--degraded-no-points ()
  "降级形态（只有 color + width，无点列）解析为「无几何」→ nil."
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:5;ink:#FF1E88E5,2.50"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:5;ink:#FF1E88E5,2.50,")))

(ert-deftest seshat-reader-annotation-ink-test--absent-keeps-rects ()
  "只有 rect 段时 ink 返回 nil，而 `--rects-from-location' 照旧返回该 rect."
  (let ((location "page:7;rect:10.00,20.00,30.00,40.00"))
    (should-not (seshat-reader-annotation--ink-strokes-from-location location))
    (should (equal (seshat-reader-annotation--rects-from-location location)
                   '((10.0 20.0 30.0 40.0))))))

(ert-deftest seshat-reader-annotation-ink-test--both-segments-coexist ()
  "同一 location 同时含 rect 与 ink 段时互不干扰，各自返回自己的部分."
  (let* ((location (concat "page:9;rect:1.00,2.00,3.00,4.00"
                           ";ink:#FF1E88E5,2.50,5.00,6.00,7.00,8.00"))
         (strokes (seshat-reader-annotation--ink-strokes-from-location location)))
    (should (= 1 (length strokes)))
    (should (equal (nth 6 (car strokes)) '(5.0 6.0 7.0 8.0)))
    (should (equal (seshat-reader-annotation--rects-from-location location)
                   '((1.0 2.0 3.0 4.0))))))

(ert-deftest seshat-reader-annotation-ink-test--no-page-anchor ()
  "缺 `page:<n>' 段时无法定位页面，整条返回 nil（不猜页码）."
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "ink:#FF1E88E5,2.50,1.00,2.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location "page:1"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location ""))
  (should-not (seshat-reader-annotation--ink-strokes-from-location nil)))

;;; 整条跳过

(ert-deftest seshat-reader-annotation-ink-test--bad-color-skips-stroke ()
  "颜色格式非法（#XYZ / 6 位 / 缺 #）→ 丢掉整笔，其它笔不受影响."
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#XYZ,1.00,1.00,2.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88,1.00,1.00,2.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:FF1E88E5,1.00,1.00,2.00"))
  ;; 一笔坏、一笔好：只返回好的那笔
  (let ((strokes (seshat-reader-annotation--ink-strokes-from-location
                  (concat "page:1;ink:#XYZ,1.00,1.00,2.00"
                          ";ink:#FF1E88E5,2.50,3.00,4.00"))))
    (should (= 1 (length strokes)))
    (should (equal (nth 6 (car strokes)) '(3.0 4.0)))))

(ert-deftest seshat-reader-annotation-ink-test--bad-width-skips-stroke ()
  "宽度非数字 → 丢掉整笔."
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,abc,1.00,2.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,,1.00,2.00")))

(ert-deftest seshat-reader-annotation-ink-test--odd-points-skips-stroke ()
  "点数不成对（5 个数字）→ 丢掉整笔，而不是丢掉最后一个孤立坐标."
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,2.50,1.00,2.00,3.00,4.00,5.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,2.50,1.00")))

(ert-deftest seshat-reader-annotation-ink-test--non-finite-skips-stroke ()
  "任一坐标非有限数（nan / inf / 溢出成 inf 的指数）→ 丢掉整笔."
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,2.50,1.00,2.00,nan,4.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,2.50,inf,2.00,3.00,4.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,2.50,1.00,2.00,1e999,4.00"))
  (should-not (seshat-reader-annotation--ink-strokes-from-location
               "page:1;ink:#FF1E88E5,2.50,1.00,2.00,3.00,")))

;;; 上限

(ert-deftest seshat-reader-annotation-ink-test--truncates-points ()
  "超过 `--ink-max-points' 只保留前 N 点，并置 TRUNCATED 为 t."
  (let* ((max seshat-reader-annotation--ink-max-points)
         (points (seshat-reader-annotation-ink-test--points (1+ max)))
         (stroke (car (seshat-reader-annotation--ink-strokes-from-location
                       (seshat-reader-annotation-ink-test--location points))))
         (kept (nth 6 stroke)))
    (should (= 1024 max))
    (should (nth 7 stroke))
    (should (= max (/ (length kept) 2)))
    ;; 保留的是前缀（第一个点仍在、被丢掉的最后一个点不在）
    (should (equal (car kept) 0.0))
    (should (equal (car (last kept)) (float (- (* 2 max) 1))))))

(ert-deftest seshat-reader-annotation-ink-test--exactly-max-points ()
  "恰好等于上限时不标记 TRUNCATED."
  (let* ((max seshat-reader-annotation--ink-max-points)
         (points (seshat-reader-annotation-ink-test--points max))
         (stroke (car (seshat-reader-annotation--ink-strokes-from-location
                       (seshat-reader-annotation-ink-test--location points)))))
    (should (= max (/ (length (nth 6 stroke)) 2)))
    (should-not (nth 7 stroke))))

(ert-deftest seshat-reader-annotation-ink-test--long-location-bounded ()
  "超长 location（> `--location-max-length'）不报错，截断后仍解析前面合法段."
  (let* ((limit seshat-reader-annotation--location-max-length)
         (valid (concat "page:4;ink:#FF1E88E5,2.50,1.00,2.00,3.00,4.00"))
         (padding (make-string limit ?9))
         (location (concat valid ";rect:" padding))
         (strokes nil))
    (should (> (length location) limit))
    (setq strokes (seshat-reader-annotation--ink-strokes-from-location location))
    (should (= 1 (length strokes)))
    (should (equal (nth 0 (car strokes)) 4))
    (should (equal (nth 6 (car strokes)) '(1.0 2.0 3.0 4.0)))))

;;; 投喂渲染（T5：`--redraw-highlights' 的 ink 分支）

;; 下面这些用例与上面的纯解析用例不同：它们**不加载**动态模块，而是用桩函数
;; 顶替 C 层入口（`--clear-highlights' / `--add-highlight' / `--add-decoration' /
;; `--add-stroke' / `--refresh-highlights'），只断言 Lisp 侧的投喂逻辑——页码
;; 换算、开关生效、缺入口时跳过、以及返回值口径。

(defun seshat-reader-annotation-ink-test--call-with-stubs (stubs function)
  "在 STUBS（(SYMBOL . FUNCTION) 列表）生效期间调用 FUNCTION，随后恢复.
STUBS 中 FUNCTION 为 nil 的条目表示**临时取消定义**（模拟「旧版模块没有这个
入口」）。恢复逻辑区分「原本有定义」与「原本未定义」两种情况，故测试不会给
运行时留下桩定义。"
  (let ((saved (mapcar (lambda (stub)
                         (list (car stub)
                               (and (fboundp (car stub))
                                    (symbol-function (car stub)))))
                       stubs)))
    (unwind-protect
        (progn
          (dolist (stub stubs)
            (if (cdr stub)
                (fset (car stub) (cdr stub))
              (fmakunbound (car stub))))
          (funcall function))
      (dolist (entry saved)
        (if (nth 1 entry)
            (fset (nth 0 entry) (nth 1 entry))
          (fmakunbound (nth 0 entry)))))))

(defun seshat-reader-annotation-ink-test--stubs (cell &optional without-stroke)
  "返回一组记录型桩，调用记录推进 CELL 的 car；WITHOUT-STROKE 为 t 时
把 `--add-stroke' 设为「未定义」，用于模拟缺笔迹入口的旧版模块."
  (append
   (list (cons 'seshat-reader-dyn--clear-highlights
               (lambda () (push 'clear (car cell)) t))
         (cons 'seshat-reader-dyn--add-highlight
               (lambda (page x0 y0 x1 y1)
                 (push (list 'add page x0 y0 x1 y1) (car cell)) t))
         (cons 'seshat-reader-dyn--add-decoration
               (lambda (page x0 y0 x1 y1 r g b alpha)
                 (push (list 'deco page x0 y0 x1 y1 r g b alpha) (car cell)) t))
         (cons 'seshat-reader--multipage-refresh-decorations
               (lambda () (push 'refresh (car cell)) t)))
   (if without-stroke
       (list (cons 'seshat-reader-dyn--add-stroke nil))
     (list (cons 'seshat-reader-dyn--add-stroke
                 (lambda (page r g b alpha width points)
                   (push (list 'stroke page r g b alpha width points)
                         (car cell))
                   t))))))

(ert-deftest seshat-reader-annotation-ink-test--feed-stroke-page-passthrough ()
  "`--feed-stroke' 把 1-based 页号**原样**传给 7 参 `--add-stroke'（不做 ±1）.
C 侧 `--add-stroke' 与 `--add-highlight' 共用同一个 `resolve_page_arg'，两者
同为 1-based；隔离实例实测：当前页 0-based 10 传 11 画出笔迹、传 10 落到上一页。"
  (let ((cell (list nil)))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (seshat-reader-annotation-ink-test--stubs cell)
     (lambda ()
       (should (eq t (seshat-reader-annotation--feed-stroke
                      3 1.0 0.0 0.0 1.0 6.0 '(10.0 20.0 30.0 40.0))))))
    (should (equal (nreverse (car cell))
                   '((stroke 3 1.0 0.0 0.0 1.0 6.0 (10.0 20.0 30.0 40.0)))))))

(ert-deftest seshat-reader-annotation-ink-test--feed-stroke-nil-without-module ()
  "`--add-stroke' 缺失时 `--feed-stroke' 返回 nil 且不抛错（不调任何入口）."
  (let ((cell (list nil)))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (seshat-reader-annotation-ink-test--stubs cell t)
     (lambda ()
       (should-not (seshat-reader-annotation--feed-stroke
                    1 0.0 0.0 0.0 1.0 2.0 '(1.0 2.0 3.0 4.0)))))
    (should-not (car cell))))

(ert-deftest seshat-reader-annotation-ink-test--feed-stroke-requires-two-points ()
  "不足两个点（含一条退化笔迹）时不调用 C 入口，返回 nil——C 侧同样会拒."
  (let ((cell (list nil)))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (seshat-reader-annotation-ink-test--stubs cell)
     (lambda ()
       (should-not (seshat-reader-annotation--feed-stroke
                    1 0.0 0.0 0.0 1.0 2.0 '(1.0 2.0)))
       (should-not (seshat-reader-annotation--feed-stroke
                    1 0.0 0.0 0.0 1.0 2.0 nil))))
    (should-not (car cell))))

(ert-deftest seshat-reader-annotation-ink-test--redraw-feeds-strokes-last ()
  "投喂顺序：批注 rect → 闪现 → 附加装饰 → ink 笔迹 → refresh；返回值仍只计 rect."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil)
        (seshat-reader-annotation-extra-decorations-function
         (lambda () '((1 0.0 0.0 1.0 1.0 0.2 0.3 0.4 0.5)))))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (seshat-reader-annotation-ink-test--stubs cell)
     (lambda ()
       (should (= 2 (seshat-reader-annotation--redraw-highlights
                     '((1 1.0 2.0 3.0 4.0) (2 5.0 6.0 7.0 8.0))
                     '((3 0.1 0.2 0.3 1.0 6.0 (10.0 20.0 30.0 40.0)
                         nil)))))
       (should (equal (nreverse (car cell))
                      '(clear
                        (add 1 1.0 2.0 3.0 4.0)
                        (add 2 5.0 6.0 7.0 8.0)
                        (deco 1 0.0 0.0 1.0 1.0 0.2 0.3 0.4 0.5)
                        (stroke 3 0.1 0.2 0.3 1.0 6.0 (10.0 20.0 30.0 40.0))
                        refresh)))))))

(ert-deftest seshat-reader-annotation-ink-test--redraw-ink-disabled ()
  "`ink-enabled' 为 nil 时笔迹一个都不投（rect 照旧投），返回值不变."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil)
        (seshat-reader-annotation-ink-enabled nil))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (seshat-reader-annotation-ink-test--stubs cell)
     (lambda ()
       (should (= 1 (seshat-reader-annotation--redraw-highlights
                     '((1 1.0 2.0 3.0 4.0))
                     '((3 0.1 0.2 0.3 1.0 6.0 (10.0 20.0 30.0 40.0) nil)))))))
    (should (equal (nreverse (car cell))
                   '(clear (add 1 1.0 2.0 3.0 4.0) refresh)))))

(ert-deftest seshat-reader-annotation-ink-test--redraw-probe-needs-stroke-entry ()
  "模块探测必须包含 `--add-stroke'：缺该入口时判不可用、提示一次、不抛错."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil)
        (seshat-reader-annotation--highlight-warned nil)
        (messages nil))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (append (seshat-reader-annotation-ink-test--stubs cell t)
             (list (cons 'message
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args) messages)))))
     (lambda ()
       (should-not (seshat-reader-annotation--highlight-module-available-p))
       ;; 有笔迹要投但入口缺失：整体跳过（rect 也不投），返回 0
       (should (= 0 (seshat-reader-annotation--redraw-highlights
                     '((1 1.0 2.0 3.0 4.0))
                     '((3 0.1 0.2 0.3 1.0 6.0 (10.0 20.0 30.0 40.0) nil)))))
       (should (= 1 (length messages)))
       (should (string-match-p "装饰模块不可用" (car messages)))
       (should (string-match-p "笔迹入口" (car messages)))
       ;; 只有笔迹、没有 rect 时同样提示；第二次不再重复提示
       (should (= 0 (seshat-reader-annotation--redraw-highlights
                     nil
                     '((3 0.1 0.2 0.3 1.0 6.0 (10.0 20.0 30.0 40.0) nil)))))
       (should (= 1 (length messages)))))
    (should (equal (nreverse (car cell))
                   '(clear refresh clear refresh)))))

(ert-deftest seshat-reader-annotation-ink-test--apply-highlights-feeds-strokes ()
  "`--apply-highlights' 从同一批 ITEMS 派生笔迹并投喂，返回值仍是 rect 数."
  (let ((cell (list nil))
        (seshat-reader-select--flash-rects nil))
    (seshat-reader-annotation-ink-test--call-with-stubs
     (seshat-reader-annotation-ink-test--stubs cell)
     (lambda ()
       (should (= 1 (seshat-reader-annotation--apply-highlights
                     (list (list :id 1 :kind "highlight"
                                 :location "page:4;rect:1.00,2.00,3.00,4.00")
                           (list :id 2 :kind "ink"
                                 :location
                                 (concat "page:4;ink:#FF1E88E5,2.50"
                                         ",10.00,20.00,30.00,40.00"))))))))
    (should (equal (nreverse (car cell))
                   '(clear
                     (add 4 1.0 2.0 3.0 4.0)
                     (stroke 4 0.11764705882352941 0.5333333333333333
                             0.8980392156862745 1.0 2.5
                             (10.0 20.0 30.0 40.0))
                     refresh)))))

(ert-deftest seshat-reader-annotation-ink-test--cached-strokes-respects-document ()
  "缓存笔迹与缓存矩形同源同过滤：同文档取用、跨文档一律不投."
  (let* ((file (expand-file-name "ink-cache-test.pdf" temporary-file-directory))
         (list-buffer (get-buffer-create seshat-reader-annotation-list-buffer-name))
         (cell (list nil))
         (seshat-reader-select--flash-rects nil))
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq buffer-file-name file)
            (with-current-buffer list-buffer
              (setq-local seshat-reader-annotation-list-document-id
                          (seshat-reader-annotation--quiet-doc-id file))
              (setq-local seshat-reader-annotation-list-entries
                          (list (list (cons 'id 1)
                                      (cons 'location
                                            (concat "page:2;ink:#FF000000,1.00"
                                                    ",1.00,2.00,3.00,4.00"))))))
            ;; 同文档：缓存笔迹可用
            (should (= 1 (length (seshat-reader-annotation--cached-annotation-strokes))))
            (seshat-reader-annotation-ink-test--call-with-stubs
             (seshat-reader-annotation-ink-test--stubs cell)
             (lambda ()
               (should (= 0 (seshat-reader-annotation--redraw-highlights)))))
            (should (equal (nreverse (car cell))
                           '(clear
                             (stroke 2 0.0 0.0 0.0 1.0 1.0 (1.0 2.0 3.0 4.0))
                             refresh))))
          ;; 换成别的文档 id：缓存笔迹与矩形都不再取用
          (with-temp-buffer
            (setq buffer-file-name file)
            (with-current-buffer list-buffer
              (setq-local seshat-reader-annotation-list-document-id "lib:other.pdf"))
            (should-not (seshat-reader-annotation--cached-annotation-strokes))
            (let ((cell (list nil)))
              (seshat-reader-annotation-ink-test--call-with-stubs
               (seshat-reader-annotation-ink-test--stubs cell)
               (lambda ()
                 (should (= 0 (seshat-reader-annotation--redraw-highlights)))))
              (should (equal (nreverse (car cell)) '(clear refresh))))))
      (when (buffer-live-p list-buffer)
        (kill-buffer list-buffer)))))

(provide 'seshat-reader-annotation-ink-test)

;;; seshat-reader-annotation-ink-test.el ends here
