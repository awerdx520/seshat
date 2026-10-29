;;; seshat-log-test.el --- ERT tests for seshat-log  -*- lexical-binding: t; -*-

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

;; `seshat-log' 的 ERT 测试套件，覆盖三组语义：
;;
;; 1. **echo area 规则**：quiet 为 t 时 `warn' 静默、`error' 仍可见；
;;    quiet 为 nil 时按级别过滤后带 `Seshat: ' 前缀输出。
;; 2. **buffer 语义**：级别过滤、行格式、按上限从头部裁剪（保留最新）、
;;    惰性创建、`special-mode' 只读下仍可写入、清空。
;; 3. **健壮性**：格式化失败与 buffer 写入失败都不得上抛（它跑在自动路径
;;    里，抛错会把「记日志失败」升级成主流程失败）。
;;
;; 每个用例都用 `seshat-log-test--with-clean-state' 先杀掉日志 buffer 并把
;; 三个 defcustom 绑回默认值，结束再杀一次——用例之间零残留，也绝不碰用户
;; 真实的 `*Seshat Log*' 内容（batch 下本就没有）。全部用例**不触网**、
;; 不需要真实窗口：`display-buffer' 一律桩替。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-log)

;;; 测试辅助

(defvar seshat-log-test--messages nil
  "本轮用例捕获到的 echo area 文本（按时间顺序）.
由 `seshat-log-test--capture-messages' 绑定并填充。")

(defmacro seshat-log-test--with-clean-state (&rest body)
  "在干净的日志状态中执行 BODY.
先杀掉 `seshat-log--buffer-name' 对应的 buffer（若有），并把三个 defcustom
绑回默认值；无论 BODY 是否出错，退出时再杀一次 buffer。"
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (when (get-buffer seshat-log--buffer-name)
           (kill-buffer seshat-log--buffer-name))
         (let ((seshat-log-level 'info)
               (seshat-log-quiet t)
               (seshat-log-max-lines 2000))
           ,@body))
     (when (get-buffer seshat-log--buffer-name)
       (kill-buffer seshat-log--buffer-name))))

(defmacro seshat-log-test--capture-messages (&rest body)
  "执行 BODY，返回期间 `message' 收到的文本列表（按时间顺序）.
`message' 被桩替，故不会真的往 echo area / stderr 打印。"
  (declare (indent 0) (debug t))
  `(let ((seshat-log-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        seshat-log-test--messages)
                  nil)))
       ,@body)
     (nreverse seshat-log-test--messages)))

(defun seshat-log-test--lines ()
  "返回日志 buffer 的文本行列表；buffer 不存在时返回 nil。"
  (when (get-buffer seshat-log--buffer-name)
    (with-current-buffer seshat-log--buffer-name
      (split-string (buffer-string) "\n" t))))

(defun seshat-log-test--stub-display-buffer ()
  "把 `display-buffer' 桩替为空操作（batch 下不需要真实窗口）。"
  (lambda (&rest _args) nil))

;;; echo area 规则

(ert-deftest seshat-log-test-quiet-suppresses-warn-echo-but-writes-buffer ()
  "quiet 为 t 时 warn 不进 echo area，但写进日志 buffer。"
  (seshat-log-test--with-clean-state
    (let ((messages (seshat-log-test--capture-messages
                      (seshat-log 'warn "同步失败：%s" "超时"))))
      (should-not messages)
      (let ((lines (seshat-log-test--lines)))
        (should (= 1 (length lines)))
        (should (string-match-p
                 "\\`[0-9][0-9]:[0-9][0-9]:[0-9][0-9] \\[WARN\\] 同步失败：超时\\'"
                 (car lines)))))))

(ert-deftest seshat-log-test-quiet-still-echoes-error ()
  "quiet 为 t 时 error 是唯一仍进 echo area 的级别，且同样写 buffer。"
  (seshat-log-test--with-clean-state
    (let ((messages (seshat-log-test--capture-messages
                      (seshat-log 'error "致命：%s" "磁盘已满"))))
      (should (equal '("Seshat: 致命：磁盘已满") messages))
      (should (= 1 (length (seshat-log-test--lines)))))))

(ert-deftest seshat-log-test-quiet-nil-echoes-info-with-prefix ()
  "quiet 为 nil 时 info 进 echo area，前缀为 `Seshat: '。"
  (seshat-log-test--with-clean-state
    (let ((seshat-log-quiet nil))
      (let ((messages (seshat-log-test--capture-messages
                        (seshat-log 'info "已同步 %d 个文件" 3))))
        (should (equal '("Seshat: 已同步 3 个文件") messages))))))

;;; buffer 语义

(ert-deftest seshat-log-test-level-filter-skips-lower-levels ()
  "`seshat-log-level' 为 warn 时 info / debug 不写 buffer。"
  (seshat-log-test--with-clean-state
    (let ((seshat-log-level 'warn))
      (seshat-log-test--capture-messages
        (seshat-log 'info "不该出现")
        (seshat-log 'debug "也不该出现"))
      (should-not (get-buffer seshat-log--buffer-name))
      (seshat-log-test--capture-messages
        (seshat-log 'warn "该出现"))
      (should (= 1 (length (seshat-log-test--lines)))))))

(ert-deftest seshat-log-test-trims-from-head-keeping-newest ()
  "行数超过 `seshat-log-max-lines' 时从头部裁剪，保留最新的若干条。"
  (seshat-log-test--with-clean-state
    (let ((seshat-log-max-lines 5))
      (seshat-log-test--capture-messages
        (dotimes (i 10)
          (seshat-log 'info "line-%d" i)))
      (let ((lines (seshat-log-test--lines)))
        (should (= 5 (length lines)))
        (should (string-match-p "line-5\\'" (nth 0 lines)))
        (should (string-match-p "line-9\\'" (nth 4 lines)))))))

(ert-deftest seshat-log-test-creates-buffer-lazily ()
  "加载后没有 buffer；首次 `seshat-log' 自动创建且不报错。"
  (seshat-log-test--with-clean-state
    (should-not (get-buffer seshat-log--buffer-name))
    (should-not (seshat-log-test--capture-messages
                  (seshat-log 'info "首次写入")))
    (should (get-buffer seshat-log--buffer-name))
    (should (= 1 (length (seshat-log-test--lines))))))

(ert-deftest seshat-log-test-show-log-reuses-buffer-in-special-mode ()
  "`seshat-show-log' 幂等复用同一 buffer，并把 buffer 置为 `special-mode'。"
  (seshat-log-test--with-clean-state
    (let (displayed)
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _args)
                   (push buffer displayed)
                   nil)))
        (let ((first (seshat-show-log))
              (second (seshat-show-log)))
          (should (eq first second))
          (should (eq first (get-buffer seshat-log--buffer-name)))
          (with-current-buffer first
            (should (eq major-mode 'special-mode))
            (should buffer-read-only))
          (should (= 2 (length displayed))))))))

(ert-deftest seshat-log-test-clear-empties-read-only-buffer ()
  "`seshat-log-clear' 在只读（special-mode）buffer 上也能清空且不报错。"
  (seshat-log-test--with-clean-state
    (cl-letf (((symbol-function 'display-buffer)
               (seshat-log-test--stub-display-buffer)))
      (seshat-log-test--capture-messages
        (seshat-log 'info "a")
        (seshat-log 'info "b"))
      (should (= 2 (length (seshat-log-test--lines))))
      (seshat-show-log)
      (should-not (seshat-log-clear))
      (with-current-buffer seshat-log--buffer-name
        (should (equal "" (buffer-string)))))))

(ert-deftest seshat-log-test-unknown-level-treated-as-info ()
  "未知级别按 info 处理：阈值 warn 时不写，阈值 info 时写且标签为级别名。"
  (seshat-log-test--with-clean-state
    (let ((seshat-log-level 'warn))
      (seshat-log-test--capture-messages
        (seshat-log 'verbose "不该写"))
      (should-not (get-buffer seshat-log--buffer-name)))
    (let ((seshat-log-level 'info))
      (seshat-log-test--capture-messages
        (seshat-log 'verbose "按 info 写"))
      (let ((lines (seshat-log-test--lines)))
        (should (= 1 (length lines)))
        (should (string-match-p "\\[VERBOSE\\] 按 info 写\\'" (car lines)))))))

(ert-deftest seshat-log-test-log-writes-after-show-log ()
  "日志 buffer 处于 `special-mode'（只读）时仍能继续写入。"
  (seshat-log-test--with-clean-state
    (cl-letf (((symbol-function 'display-buffer)
               (seshat-log-test--stub-display-buffer)))
      (seshat-show-log)
      (seshat-log-test--capture-messages
        (seshat-log 'info "只读下写入"))
      (with-current-buffer seshat-log--buffer-name
        (should (eq major-mode 'special-mode)))
      (should (= 1 (length (seshat-log-test--lines)))))))

;;; 健壮性

(ert-deftest seshat-log-test-never-signals-on-buffer-failure ()
  "buffer 写入抛错时 `seshat-log' 返回 nil 且不把异常上抛。"
  (seshat-log-test--with-clean-state
    (cl-letf (((symbol-function 'insert)
               (lambda (&rest _args) (error "模拟写入失败"))))
      (should-not (seshat-log 'warn "写不进去")))))

(ert-deftest seshat-log-test-bad-format-string-does-not-signal ()
  "格式串参数不足时不抛错，改为记一条「格式化失败」日志。"
  (seshat-log-test--with-clean-state
    (seshat-log-test--capture-messages
      (should-not (seshat-log 'warn "只有一个参数 %d %d" 1)))
    (let ((lines (seshat-log-test--lines)))
      (should (= 1 (length lines)))
      (should (string-match-p "日志格式化失败" (car lines))))))

(provide 'seshat-log-test)

;;; seshat-log-test.el ends here
