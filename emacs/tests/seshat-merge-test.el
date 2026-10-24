;;; seshat-merge-test.el --- ERT tests for seshat-merge  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

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

;; `seshat-merge' 的用例：三方合并（`seshat-merge--diff3'）与冲突标记判定
;; （`seshat-merge-conflicted-p'）。
;;
;; 合并用例调用**真实的** `diff3'（本机 `/usr/sbin/diff3'），只有「程序缺失 /
;; 子进程失败」两类负向路径用桩。之所以不桩掉 `diff3'：参数顺序（`-m MINE
;; OLDER YOURS' 的第二个参数才是祖先）与退出码 1 的语义正是本模块最容易写错的
;; 地方，桩掉就测不出来了。
;;
;; 临时目录全部落在 /tmp 下的用例目录里（绑定 `temporary-file-directory'），
;; 断言「调用后无残留」时直接数该目录的条目。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-merge)

;;; 测试辅助

(defun seshat-merge-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）."
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-merge-test-" t))))

(defmacro seshat-merge-test--with-stub (symbol replacement &rest body)
  "在把 SYMBOL 的函数定义临时替换为 REPLACEMENT 的环境下执行 BODY.
用 `fset' 手工换装与还原，而不用 `cl-letf' 改 `symbol-function'：后者对
**subr**（`executable-find' / `call-process'）的换装约 0.5 秒/次（实测），
会给本套件带来无谓耗时。"
  (declare (indent 2) (debug t))
  `(let ((seshat-merge-test--old (symbol-function ',symbol)))
     (unwind-protect
         (progn
           (fset ',symbol ,replacement)
           ,@body)
       (fset ',symbol seshat-merge-test--old))))

(defmacro seshat-merge-test--with-temp-root (&rest body)
  "在 `temporary-file-directory' 指向用例私有目录的环境下执行 BODY.
`make-temp-file' 因此只会在该目录里建临时文件，BODY 结束后递归删除它。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-merge-test--root (seshat-merge-test--make-temp-dir))
          (temporary-file-directory seshat-merge-test--root))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory seshat-merge-test--root t)))))

(defun seshat-merge-test--residue (dir)
  "返回 DIR 里除 \".\" 与 \"..\" 之外的条目名列表（用于断言「无残留」）."
  (cl-remove-if (lambda (name) (member name '("." "..")))
                (directory-files dir)))

;;; 三方合并：正常路径（真实 diff3）

(ert-deftest seshat-merge-test-diff3-clean-three-way ()
  "两侧改动互不重叠时合并干净：结果含两侧改动、且**不含**冲突标记.
本用例同时锁定参数顺序：只有把共同祖先作为 `diff3' 的**第二个**参数
（`-m local base remote'）才能合并成功；顺序颠倒了会退化成冲突。"
  (let* ((base "l1\nl2\nl3\nl4\nl5\nl6\nl7\n")
         (local "l1\nL2\nl3\nl4\nl5\nl6\nl7\n")
         (remote "l1\nl2\nl3\nl4\nL5\nl6\nl7\n")
         (merged (seshat-merge--diff3 base local remote)))
    (should (stringp merged))
    (should (equal "l1\nL2\nl3\nl4\nL5\nl6\nl7\n" merged))
    (should-not (seshat-merge-conflicted-p merged))))

(ert-deftest seshat-merge-test-diff3-single-side-change ()
  "只有一侧改动时合并结果就是改动后的那一侧（祖先不残留、无标记）。"
  (let ((merged (seshat-merge--diff3 "a\nb\n" "a\nB\n" "a\nb\n")))
    (should (equal "a\nB\n" merged))
    (should-not (seshat-merge-conflicted-p merged))))

(ert-deftest seshat-merge-test-diff3-conflict-returns-markers ()
  "同一处被两侧改成不同内容：返回**非 nil** 的带标记结果（退出码 1 仍算成功）。
若把退出码 1 当失败，这里就会拿到 nil，push 会退化成「合并失败」而不是
「写回冲突标记让用户解决」。"
  (let* ((merged (seshat-merge--diff3 "a\n" "b\n" "c\n")))
    (should (stringp merged))
    (should (string-match-p "=======" merged))
    (should (seshat-merge-conflicted-p merged))))

(ert-deftest seshat-merge-test-diff3-preserves-bytes ()
  "合并结果按原始字节返回：CRLF 与非 ASCII 内容不经编码往返改写。
push 会把结果直接落盘，编码转换会破坏非 UTF-8 笔记/附件。"
  (let* ((base "x\r\n")
         (merged (seshat-merge--diff3 base "X\r\n" "x\r\n")))
    (should (equal "X\r\n" merged))
    ;; 多字节输入按 UTF-8 写进临时文件，diff3 原样输出对应字节
    (let ((merged2 (seshat-merge--diff3 "笔记\n" "笔记改\n" "笔记\n")))
      (should (equal "笔记改\n"
                     (decode-coding-string merged2 'utf-8))))))

;;; 三方合并：失败路径

(ert-deftest seshat-merge-test-diff3-nil-when-program-missing ()
  "`executable-find' 找不到 diff3 时返回 nil（调用方据此保留 dirty 并告警）。"
  (seshat-merge-test--with-stub executable-find (lambda (&rest _) nil)
    (should-not (seshat-merge--diff3 "a\n" "b\n" "c\n")))
  ;; 配置成空串 / 不存在的程序名同样返回 nil
  (let ((seshat-merge-diff3-program ""))
    (should-not (seshat-merge--diff3 "a\n" "b\n" "c\n")))
  (let ((seshat-merge-diff3-program "seshat-no-such-diff3-program"))
    (should-not (seshat-merge--diff3 "a\n" "b\n" "c\n"))))

(ert-deftest seshat-merge-test-diff3-nil-on-subprocess-failure ()
  "diff3 以大于 1 的退出码失败（真实报错）时返回 nil，且临时目录**无残留**。
退出码 2 是 diff3 的「自身出错」，与 1（有冲突但合并成功）必须区分。"
  (seshat-merge-test--with-temp-root
    (seshat-merge-test--with-stub call-process (lambda (&rest _) 2)
      (should-not (seshat-merge--diff3 "a\n" "b\n" "c\n")))
    (should (equal '("." "..")
                   (directory-files temporary-file-directory)))))

(ert-deftest seshat-merge-test-diff3-nil-on-subprocess-signal ()
  "子进程被信号终止（退出码为负）时返回 nil，且临时目录无残留。"
  (seshat-merge-test--with-temp-root
    (seshat-merge-test--with-stub call-process (lambda (&rest _) -9)
      (should-not (seshat-merge--diff3 "a\n" "b\n" "c\n")))
    (should (equal '("." "..")
                   (directory-files temporary-file-directory)))))

(ert-deftest seshat-merge-test-diff3-clears-temp-dir-on-success ()
  "成功路径同样不留临时目录：三次调用后用例目录里没有残留。"
  (seshat-merge-test--with-temp-root
    (should (seshat-merge--diff3 "a\n" "a\n" "a\n"))
    (should (seshat-merge--diff3 "a\n" "b\n" "c\n"))
    (should-not (seshat-merge-test--residue temporary-file-directory))))

(ert-deftest seshat-merge-test-diff3-tolerates-nil-sections ()
  "三段中的 nil 视为空串，不抛错（新建文件与空祖先的场景）。"
  (let ((merged (seshat-merge--diff3 nil "a\n" nil)))
    (should (stringp merged))
    (should (equal "a\n" merged))))

;;; 冲突标记判定（纯函数）

(ert-deftest seshat-merge-test-conflicted-p-detects-markers ()
  "行首的 `<<<<<<<` 或 `>>>>>>>` → 有冲突；两标记独占时也判定为有冲突。"
  ;; 完整的 diff3 冲突块
  (should (seshat-merge-conflicted-p
           "<<<<<<< local\na\n=======\nb\n>>>>>>> remote\n"))
  ;; 只有起始标记（残缺块）也算冲突——宁可让用户手工确认
  (should (seshat-merge-conflicted-p "<<<<<<< local\na\n"))
  ;; 只有结束标记
  (should (seshat-merge-conflicted-p "b\n>>>>>>> remote\n"))
  ;; 标记出现在文本**中途**（不是开头）时同样要命中
  (should (seshat-merge-conflicted-p "前言\n正文\n<<<<<<< local\na\n=======\nb\n")))

(ert-deftest seshat-merge-test-conflicted-p-ignores-separator-only ()
  "单独的 `=======` 不算冲突：普通文档里的分隔线不能被误判。
判据只认 `<<<<<<<` / `>>>>>>>`，不看分隔行。"
  (should-not (seshat-merge-conflicted-p "a\n=======\nb\n"))
  (should-not (seshat-merge-conflicted-p "=======\n"))
  ;; 缩进的标记不算行首标记（diff3 只会写行首）
  (should-not (seshat-merge-conflicted-p "  <<<<<<< local\n"))
  ;; 普通文本
  (should-not (seshat-merge-conflicted-p "普通笔记内容\n第二行\n")))

(ert-deftest seshat-merge-test-conflicted-p-safe-on-empty-and-nil ()
  "空串 / nil / 非字符串输入返回 nil 且不抛错（调用方常在合并失败后顺手判）。"
  (should-not (seshat-merge-conflicted-p ""))
  (should-not (seshat-merge-conflicted-p nil))
  (should-not (seshat-merge-conflicted-p 42))
  (should-not (seshat-merge-conflicted-p '("<<<<<<<")))
  ;; 无换行的单行标记仍算冲突（行首判定对整串首字符同样成立）
  (should (seshat-merge-conflicted-p "<<<<<<<")))

;;; defcustom

(ert-deftest seshat-merge-test-diff3-program-default ()
  "`seshat-merge-diff3-program' 默认 \"diff3\"，且可在 `exec-path' 中解析到。"
  (should (equal "diff3" (default-value 'seshat-merge-diff3-program)))
  (should (stringp (executable-find (default-value 'seshat-merge-diff3-program)))))

(provide 'seshat-merge-test)

;;; seshat-merge-test.el ends here
