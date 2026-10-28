;;; seshat-reader-select-report-test.el --- ERT tests for the selection report  -*- lexical-binding: t; -*-

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

;; `seshat-reader-select--report' 的 ERT 测试套件：拖选之后 echo area
;; **不回显正文**，只报统计——多少行、多少字。
;;
;; 所有用例都用 `cl-letf' 把 `message' 与 `kill-new' 的函数单元绑成记录用的
;; lambda，因此不需要真实选区、不需要动态模块，也不会往 echo area 写任何东西。
;;
;; 覆盖点：
;;
;;   - 行数 = 换行符数 + 1（TEXT 已 `string-trim'），字数按**字符**计（CJK 一字
;;     算一字，不是字节）；
;;   - 回显里**不含**正文片段；
;;   - 措辞随 `seshat-reader-select-copy-to-kill-ring' 切换：非 nil 时「已复制」
;;     且真的调了 `kill-new'，nil 时「已选中」且完全不碰 kill ring；
;;   - 空文本（nil / 空串 / 只有空白）仍报 `no text in the selected rectangle'；
;;   - 长文本不被截断：字数如实上报（旧的
;;     `seshat-reader-select-message-limit' 与截断分支应已删除）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader-select)

(defmacro seshat-reader-select-report-test--with-capture (&rest body)
  "Run BODY with `message' and `kill-new' stubbed out.
Return the cons (MESSAGE . KILLED): MESSAGE is the last string handed
to `message' (nil when nothing was reported), and KILLED is the list of
the arguments `kill-new' was called with, in call order.

A macro rather than a function: the `cl-letf' bindings must still be in
effect while BODY runs, and they are undone when the macro's `let'
exits."
  (declare (indent 0) (debug (body)))
  `(let ((messages nil)
         (killed nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (let ((text (apply #'format-message format-string args)))
                    (push text messages)
                    text)))
               ((symbol-function 'kill-new)
                (lambda (string &optional _replace)
                  (push string killed)
                  string)))
       ,@body)
     (cons (car messages) (nreverse killed))))

(ert-deftest seshat-reader-select-report-test--single-line ()
  "单行文本只报「1 行 · 字符数」，且回显里不含正文。"
  (let* ((seshat-reader-select-copy-to-kill-ring nil)
         (result (seshat-reader-select-report-test--with-capture
                   (seshat-reader-select--report "hello world")))
         (msg (car result)))
    (should (equal msg "Seshat Reader select: 已选中 1 行 · 11 字"))
    (should-not (string-match-p "hello" msg))
    ;; 未开复制：kill ring 不应被碰
    (should-not (cdr result))))

(ert-deftest seshat-reader-select-report-test--multi-line ()
  "多行文本的行数 = 换行符数 + 1，字数按字符计。"
  (let* ((seshat-reader-select-copy-to-kill-ring nil)
         (result (seshat-reader-select-report-test--with-capture
                   (seshat-reader-select--report "a\nb\nc")))
         (msg (car result)))
    (should (equal msg "Seshat Reader select: 已选中 3 行 · 5 字"))
    (should-not (string-match-p "a\nb" msg))))

(ert-deftest seshat-reader-select-report-test--cjk-counts-characters ()
  "CJK 文本按**字符**计字数（不是字节），行数为 1。"
  (let* ((seshat-reader-select-copy-to-kill-ring nil)
         (result (seshat-reader-select-report-test--with-capture
                   (seshat-reader-select--report "中文测试")))
         (msg (car result)))
    (should (equal msg "Seshat Reader select: 已选中 1 行 · 4 字"))
    (should-not (string-match-p "中文" msg))))

(ert-deftest seshat-reader-select-report-test--wording-follows-copy-option ()
  "措辞随 `seshat-reader-select-copy-to-kill-ring' 切换，且只有非 nil 时才复制。"
  ;; 非 nil：说「已复制」，并把（trim 过的）文本推进 kill ring
  (let* ((seshat-reader-select-copy-to-kill-ring t)
         (result (seshat-reader-select-report-test--with-capture
                   (seshat-reader-select--report "hello world"))))
    (should (equal (car result) "Seshat Reader select: 已复制 1 行 · 11 字"))
    (should (equal (cdr result) '("hello world"))))
  ;; nil：说「已选中」，kill ring 保持不变
  (let* ((seshat-reader-select-copy-to-kill-ring nil)
         (result (seshat-reader-select-report-test--with-capture
                   (seshat-reader-select--report "hello world"))))
    (should (equal (car result) "Seshat Reader select: 已选中 1 行 · 11 字"))
    (should-not (cdr result))))

(ert-deftest seshat-reader-select-report-test--empty-text-unchanged ()
  "空文本仍是旧提示，且不复制、不报统计。"
  (dolist (text (list nil "" "   "))
    ;; 即使打开了复制，空文本也不该进 kill ring、不该报行数字数
    (let* ((seshat-reader-select-copy-to-kill-ring t)
           (result (seshat-reader-select-report-test--with-capture
                     (seshat-reader-select--report text))))
      (should (equal (car result)
                     "Seshat Reader select: no text in the selected rectangle."))
      (should-not (cdr result)))))

(ert-deftest seshat-reader-select-report-test--long-text-not-truncated ()
  "长文本不截断统计：250 字就报 250 字（旧的 200 字上限已删除）。"
  (let* ((seshat-reader-select-copy-to-kill-ring nil)
         (result (seshat-reader-select-report-test--with-capture
                   (seshat-reader-select--report (make-string 250 ?x)))))
    (should (equal (car result) "Seshat Reader select: 已选中 1 行 · 250 字"))
    (should-not (string-match-p "xxx" (car result)))))

(ert-deftest seshat-reader-select-report-test--message-limit-removed ()
  "截断常量 `seshat-reader-select-message-limit' 已删除。"
  (should-not (boundp 'seshat-reader-select-message-limit)))

(provide 'seshat-reader-select-report-test)
;;; seshat-reader-select-report-test.el ends here
