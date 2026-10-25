;;; seshat-reader-select-scope-test.el --- ERT tests for the selection highlight scope  -*- lexical-binding: t; -*-

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

;; `seshat-reader-select--rects-in-rect' 的 ERT 测试套件：它按
;; `seshat-reader-select-highlight-scope' 在两条路径之间分派——
;;
;;   `line'   （默认）整行吸附：调用模块的 `seshat-reader-dyn--lines-in-rect'
;;            （一个矩形覆盖一整行，不再经过 `--merge-char-rects'）；
;;   `region' 旧路径：调用 `seshat-reader-dyn--rects-in-rect' 拿逐字符矩形，
;;            再按行合并。
;;
;; 分派是纯 Lisp 逻辑，所以这里全部用 **桩**：用 `cl-letf' 临时把模块函数
;; 的函数单元绑成记录调用的 lambda（`fboundp' 因此在体内为真），既不加载
;; 动态模块，也不需要打开的文档。分派若选错函数，桩的调用记录会立刻为空，
;; 用例失败。
;;
;; 另有一条用例把 `--lines-in-rect' 的函数单元置为 nil（等价 `fmakunbound'），
;; 断言 `line' 作用域**静默回落**到 `region' 路径而不报错——这是老版本动态
;; 模块（没有新入口）下的行为。
;;
;; 最后两条用例断言两种作用域下垂直收缩都生效：高度 × 比值、垂直中心不变、
;; X 范围不变。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader-select)

(defmacro seshat-reader-select-scope-test--with-stubs (lines-rects chars calls
                                                                  &rest body)
  "Run BODY with both module entry points stubbed.
LINES-RECTS is what `seshat-reader-dyn--lines-in-rect' returns, CHARS
what `seshat-reader-dyn--rects-in-rect' returns.  CALLS is a one-element
list (or cons cell) whose car receives the symbol of the function that
was called, so the caller can assert which path the dispatcher took.
The stubs live for the whole of BODY — hence a macro, not a function:
a `cl-letf' inside a function body would be undone on return."
  (declare (indent 4) (debug (form form form body)))
  `(cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
              (lambda (_page _x0 _y0 _x1 _y1)
                (setcar ,calls 'lines)
                ,lines-rects))
             ((symbol-function 'seshat-reader-dyn--rects-in-rect)
              (lambda (_page _x0 _y0 _x1 _y1)
                (setcar ,calls 'rects)
                ,chars)))
     ,@body))

(ert-deftest seshat-reader-select-scope-test--defaults ()
  "新 defcustom 的默认值是 `line'，类型是 choice，含两个成员."
  (should (eq 'line seshat-reader-select-highlight-scope))
  (let ((type (get 'seshat-reader-select-highlight-scope 'custom-type)))
    (should (eq 'choice (car type)))
    ;; 每个成员是 (const :tag "..." VALUE)：取值在最后一位
    (should (equal '(line region)
                   (mapcar (lambda (spec) (car (last spec))) (cdr type))))))

(ert-deftest seshat-reader-select-scope-test--line-calls-lines-entry ()
  "scope=line 且 `--lines-in-rect' 可用：只调它，不调 `--rects-in-rect'."
  (let ((calls (list nil))
        (seshat-reader-select-highlight-scope 'line)
        (seshat-reader-select-highlight-shrink-ratio 1.0))
    (seshat-reader-select-scope-test--with-stubs
        '((10 100 200 110) (10 112 200 122)) nil calls
      (should (equal (seshat-reader-select--rects-in-rect
                      0 200.0 70.0 300.0 110.0)
                     '((10 100 200 110) (10 112 200 122))))
      (should (eq 'lines (car calls))))))

(ert-deftest seshat-reader-select-scope-test--line-does-not-merge ()
  "scope=line 的结果**不**经过合并：相邻两行的矩形条数保持为 2."
  (let ((calls (list nil))
        (seshat-reader-select-highlight-scope 'line)
        (seshat-reader-select-highlight-shrink-ratio 1.0)
        ;; 两条矩形 y 范围无缝相接：若被 `--merge-char-rects' 处理
        ;; （同一行聚类），会并成一条；不合并则仍是两条。
        (rects '((10 100 200 110) (10 110 200 120))))
    (seshat-reader-select-scope-test--with-stubs rects nil calls
      (should (equal (seshat-reader-select--rects-in-rect 0 0.0 0.0 1.0 1.0)
                     rects)))))

(ert-deftest seshat-reader-select-scope-test--region-calls-rects-entry ()
  "scope=region：调 `--rects-in-rect' 并按行合并，不调新入口."
  (let ((calls (list nil))
        (seshat-reader-select-highlight-scope 'region)
        (seshat-reader-select-highlight-shrink-ratio 1.0)
        (seshat-reader-select-highlight-granularity 'line))
    (seshat-reader-select-scope-test--with-stubs
        nil '((10 100 15 110) (15 100 20 110)) calls
      (should (equal (seshat-reader-select--rects-in-rect 0 0.0 0.0 1.0 1.0)
                     '((10 100 20 110))))
      (should (eq 'rects (car calls))))))

(ert-deftest seshat-reader-select-scope-test--line-falls-back-when-unavailable ()
  "scope=line 但 `--lines-in-rect' 不可用：静默回落 `--rects-in-rect'."
  (let ((calls (list nil))
        (seshat-reader-select-highlight-scope 'line)
        (seshat-reader-select-highlight-shrink-ratio 1.0)
        (seshat-reader-select-highlight-granularity 'line))
    (seshat-reader-select-scope-test--with-stubs
        nil '((10 100 15 110) (15 100 20 110)) calls
      ;; 置空函数单元 == fmakunbound：`fboundp' 在体内为 nil
      (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect) nil))
        (should-not (fboundp 'seshat-reader-dyn--lines-in-rect))
        (should (equal (seshat-reader-select--rects-in-rect 0 0.0 0.0 1.0 1.0)
                       '((10 100 20 110))))
        (should (eq 'rects (car calls)))))))

(ert-deftest seshat-reader-select-scope-test--line-shrinks-vertically ()
  "scope=line 下垂直收缩仍生效：高度 ×0.5、中心与 X 范围不变."
  (let ((calls (list nil))
        (seshat-reader-select-highlight-scope 'line)
        (seshat-reader-select-highlight-shrink-ratio 0.5))
    (seshat-reader-select-scope-test--with-stubs '((10 100 200 110)) nil calls
      ;; 高 10 → 5，中心 105 不变；X 范围 10..200 原样
      (should (equal (seshat-reader-select--rects-in-rect 0 0.0 0.0 1.0 1.0)
                     '((10 102.5 200 107.5)))))))

(ert-deftest seshat-reader-select-scope-test--region-shrinks-vertically ()
  "scope=region 下垂直收缩同样生效（同一比值、同一中心）."
  (let ((calls (list nil))
        (seshat-reader-select-highlight-scope 'region)
        (seshat-reader-select-highlight-granularity 'line)
        (seshat-reader-select-highlight-shrink-ratio 0.5))
    (seshat-reader-select-scope-test--with-stubs
        nil '((10 100 20 110) (20 100 30 110)) calls
      (should (equal (seshat-reader-select--rects-in-rect 0 0.0 0.0 1.0 1.0)
                     '((10 102.5 30 107.5)))))))

(provide 'seshat-reader-select-scope-test)
;;; seshat-reader-select-scope-test.el ends here
