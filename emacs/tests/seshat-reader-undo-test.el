;;; seshat-reader-undo-test.el --- ERT tests for reader undo suppression  -*- lexical-binding: t; -*-

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

;; 阅读 buffer 的 undo 记录禁用（`buffer-undo-list' 为 `t'）回归套件。
;;
;; 背景：`seshat-reader-mode' 的 buffer 是**只读渲染视图**——正文由原生模块
;; 生成、`buffer-read-only' 为 t，undo 历史对用户没有任何用途。但 `find-file'
;; 会把整份文档文件读进 buffer，随后 `seshat-reader--render-buffer' 的
;; `erase-buffer' 把这整份内容记成一次 undo「saved text」，undo 记录量≈文件
;; 大小；多页布局的重排（`--multipage-relayout'，旋转/暗色）还会反复全量重写。
;; 实测打开 30.6 MB 的 PDF 时 Emacs 因 `undo-outer-limit'（默认 24 MB）丢弃
;; 了 32,086,307 字节的 undo 记录并弹警告，白白占内存。治本方案是在 reader
;; buffer 里禁用 undo 记录，而不是调大 `undo-outer-limit'。
;;
;; 用例全部**不加载动态模块、不需要真实文档、不接触运行中的 Emacs**：
;;
;;   - buffer 用 `insert-file-contents' 预填，模拟 `find-file' 已把整份文件
;;     读进 buffer 的状态；`buffer-file-name' 直接设，不走 `find-file'，
;;     从而避开 `auto-mode-alist' 自动进 mode 的副作用；
;;   - `seshat-reader--render-buffer'（要动态模块与真实 PDF）与
;;     `seshat-reader--first-fit'（要窗口几何）桩替为空操作：本文件断言的是
;;     mode 体里的 undo 设置，不是这两条路径；
;;   - 渲染那一步（`erase-buffer' + 重写正文）由用例自己按
;;     `seshat-reader--render-buffer' 的真实写法复现，用来钉住「改动之后 undo
;;     仍然不记录」。
;;
;; 纪律：`skipped' 必须恒为 0，故不用 `skip-unless'。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
(require 'seshat-reading)

;;; 测试辅助

(defun seshat-reader-undo-test--make-doc-file (bytes)
  "造一个 BYTES 字节的临时 .pdf 文件并返回其绝对路径.
内容是可打印字符（本文件不解析格式），只要求「文件足够大、被整份读进
buffer」这一点与真实文档一致；调用方负责删除。"
  (let ((file (make-temp-file "seshat-undo-" nil ".pdf")))
    (with-temp-file file
      (insert (make-string bytes ?P)))
    file))

(defmacro seshat-reader-undo-test--with-reader-buffer (mode &rest body)
  "在真正跑完 MODE 初始化体的 reader buffer 内执行 BODY 并返回其结果.
buffer 里先 `insert-file-contents' 写入文档内容，再 `funcall' MODE，因此
MODE 体（含父 mode 体）的副作用都是真实的。

`seshat-reader--render-buffer' 与 `seshat-reader--first-fit' 桩替为空操作：
前者要动态模块与真实文档，后者要窗口几何，batch 下都不可得，而 BODY 断言的
是 mode 体里的 undo 设置。

BODY 里可读 `pre-mode-undo'：进入 MODE **之前** `buffer-undo-list' 的取值。
它必须非 nil 才算复现了真实处境，原因见下面 `buffer-undo-list' 那两行注释。"
  (declare (indent 1) (debug t))
  `(let* ((file (seshat-reader-undo-test--make-doc-file 4096))
          (buffer (generate-new-buffer " *seshat-undo-test*"))
          (pre-mode-undo nil)
          (result nil))
     (unwind-protect
         (with-current-buffer buffer
           ;; `buffer-file-name' 天然 buffer-local；不走 `find-file' 是为了
           ;; 不让 `auto-mode-alist' 替我们进 mode（那会真的去渲染）。
           (setq buffer-file-name file)
           ;; `generate-new-buffer' 造的 buffer 起始 `buffer-undo-list' 就是
           ;; `t'（不记录 undo），而 `find-file' 打开的 buffer 是**开启** undo
           ;; 的——不先置 nil 就等于没复现真实处境，断言会假绿。
           (setq buffer-undo-list nil)
           (insert-file-contents file)
           (setq pre-mode-undo buffer-undo-list)
           (cl-letf (((symbol-function 'seshat-reader--render-buffer)
                      (lambda (&rest _) nil))
                     ((symbol-function 'seshat-reader--first-fit)
                      (lambda (&rest _) nil)))
             (funcall ,mode)
             (setq result (progn ,@body))))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (delete-file file))
     result))

;;; undo 记录禁用

(ert-deftest seshat-reader-undo-test-reader-mode-disables-undo ()
  "进入 `seshat-reader-mode' 后 `buffer-undo-list' 为 t（不记录 undo）.
`insert-file-contents' 已经往 undo 记录里塞了整份文件的插入条目，mode 体必须
把它们整体丢弃（置 t），否则 `--render-buffer' 的 `erase-buffer' 会把这整份
内容再记一次 undo saved text。"
  (seshat-reader-undo-test--with-reader-buffer 'seshat-reader-mode
    ;; 前提：进入 mode 之前的确开着 undo（否则本断言无意义）。
    (should pre-mode-undo)
    (should-not (eq pre-mode-undo t))
    (should (eq major-mode 'seshat-reader-mode))
    (should (eq buffer-undo-list t))
    ;; 只读渲染视图的两个既有不变量不应被本次改动破坏。
    (should buffer-read-only)
    (should-not (buffer-modified-p))))

(ert-deftest seshat-reader-undo-test-undo-disable-is-buffer-local ()
  "禁用只作用于 reader buffer：其他 buffer 照常记录 undo."
  (seshat-reader-undo-test--with-reader-buffer 'seshat-reader-mode
    (should (eq buffer-undo-list t))
    (with-temp-buffer
      ;; 同前：新 buffer 起始就是 t，先置 nil 才是「undo 开启」的普通 buffer。
      (setq buffer-undo-list nil)
      (insert "abc")
      (should-not (eq buffer-undo-list t))
      (should (consp buffer-undo-list)))))

(ert-deftest seshat-reader-undo-test-render-does-not-record-undo ()
  "复现渲染的 `erase-buffer' + 重写正文之后，undo 记录仍不增长.
`seshat-reader--render-buffer' 与 `--multipage-relayout' 都是在
`inhibit-read-only' 下 `erase-buffer' 再重写正文，本用例按同样写法改 buffer，
断言 `buffer-undo-list' 保持 t、buffer 仍不算「已修改」。"
  (seshat-reader-undo-test--with-reader-buffer 'seshat-reader-mode
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (make-string 200000 ?x)))
    (set-buffer-modified-p nil)
    (should (eq buffer-undo-list t))
    (should-not (buffer-modified-p))
    (should (= (buffer-size) 200000))))

(ert-deftest seshat-reader-undo-test-reading-mode-inherits-undo-disable ()
  "派生 mode `seshat-reading-mode' 经父 mode 体继承 undo 禁用.
用户平时打开的正是这个派生 mode，故必须由 `define-derived-mode' 的父体自动
生效，不在 `seshat-reading.el' 里重复设置。"
  (seshat-reader-undo-test--with-reader-buffer 'seshat-reading-mode
    (should (derived-mode-p 'seshat-reading-mode))
    (should (derived-mode-p 'seshat-reader-mode))
    (should (eq buffer-undo-list t))
    (should buffer-read-only)))

(provide 'seshat-reader-undo-test)
;;; seshat-reader-undo-test.el ends here
