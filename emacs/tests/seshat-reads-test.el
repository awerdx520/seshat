;;; seshat-reads-test.el --- ERT tests for seshat-reads  -*- lexical-binding: t; -*-

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

;; `seshat-reads'（本地阅读进度侧车）的 ERT 测试套件，覆盖三类契约：
;;
;; 1. `seshat-reads-percent' 的边界（纯函数，必须严格：未知总页数 / 非正页号
;;    一律 nil，页号超出总页数夹到 100）；
;; 2. 记录 / 读取 / 落盘 / 重载的往返，以及**原子写**（写完目录里只剩进度
;;    文件本身，不留 `seshat-reads*' 临时文件）；
;; 3. 容错：坏文件与 `:version' 不匹配都降级为空表、**不抛错、不删文件**；
;;    以及落盘**去抖**（连续记录只武装一次定时器，显式 save 才写盘）。
;;
;; 全部用例**不触网**、不读写用户真实进度文件：每个用例都把
;; `seshat-reads-file' 绑到临时目录里的 "reads.eld"，并把模块级状态
;; （`seshat-reads--state' / `seshat-reads--timer' / `seshat-reads--pending'）
;; 绑成干净起点；结束时取消定时器并递归删除临时目录。
;;
;; 定时器用例一律**桩替** `run-at-time'（断言只武装一次），`unwind-protect'
;; 保证真定时器被 `cancel-timer' 清掉，避免污染其他测试。
;;
;; 页号采集（`seshat-reads--note-current-page'）的用例把 reader 的访问器
;; 桩替掉：本套件不加载 `seshat-reader'（进度侧车对它只是软依赖），
;; `cl-letf' 直接设函数单元即可让 `fboundp' 为真。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reads)

(declare-function seshat-reader-current-doc-pagenumber "seshat-reader" (&optional window))
(declare-function seshat-reader--multipage-pagecount "seshat-reader" ())

;;; 测试辅助

(defun seshat-reads-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根（ECA 客户端所为），那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-reads-test-" t))))

(defmacro seshat-reads-test--with-env (&rest body)
  "在独立的临时进度文件与干净模块状态下执行 BODY.
BODY 执行期间 `seshat-reads-file' 指向临时目录里的 \"reads.eld\"，
`seshat-reads--state' 为 nil（惰性加载从空起步）、`seshat-reads--timer' 与
`seshat-reads--pending' 为 nil。结束后取消可能挂着的定时器并递归删除临时
目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-reads-test--dir (seshat-reads-test--make-temp-dir))
          (seshat-reads-file (expand-file-name "reads.eld"
                                               seshat-reads-test--dir))
          (seshat-reads--state nil)
          (seshat-reads--timer nil)
          (seshat-reads--pending nil))
     (unwind-protect
         (progn ,@body)
       (when (timerp seshat-reads--timer)
         (cancel-timer seshat-reads--timer))
       (ignore-errors (delete-directory seshat-reads-test--dir t)))))

(defvar seshat-reads-test--dir nil
  "当前用例的临时目录（带结尾斜杠），由 `seshat-reads-test--with-env' 绑定.")

(defun seshat-reads-test--write (file contents)
  "把 CONTENTS 原样写入 FILE（用于构造坏文件 / 版本不符的文件）."
  (with-temp-file file
    (insert contents)))

(defun seshat-reads-test--contents (file)
  "以二进制安全方式读取 FILE 的全部内容并返回字符串."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun seshat-reads-test--text (file)
  "以 UTF-8 解码读取 FILE 的全部内容（文本断言用，避免 unibyte/multibyte 混比）."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

;;; `seshat-reads-percent'：纯函数边界

(ert-deftest seshat-reads-test-percent-total-nil ()
  "`:total' 为 nil（未知总页数）→ nil，不猜百分比."
  (should-not (seshat-reads-percent (list :page 3 :total nil :updated 0)))
  (should-not (seshat-reads-percent (list :page 3 :updated 0)))
  (should-not (seshat-reads-percent nil)))

(ert-deftest seshat-reads-test-percent-total-non-positive ()
  "`:total' 为 0 / 负数 / 非整数 → nil."
  (should-not (seshat-reads-percent (list :page 1 :total 0)))
  (should-not (seshat-reads-percent (list :page 1 :total -5)))
  (should-not (seshat-reads-percent (list :page 1 :total 3.0))))

(ert-deftest seshat-reads-test-percent-page-non-positive ()
  "`:page' 为 0 / 负数 / nil → nil."
  (should-not (seshat-reads-percent (list :page 0 :total 10)))
  (should-not (seshat-reads-percent (list :page -1 :total 10)))
  (should-not (seshat-reads-percent (list :page nil :total 10))))

(ert-deftest seshat-reads-test-percent-clamps-page-beyond-total ()
  "`:page' 大于 `:total' → 100（夹紧，绝不返回 >100）."
  (should (= 100 (seshat-reads-percent (list :page 11 :total 10))))
  (should (= 100 (seshat-reads-percent (list :page 999 :total 10)))))

(ert-deftest seshat-reads-test-percent-normal-thirds ()
  "正常值：1/3 → 33、2/3 → 67、3/3 → 100（四舍五入，不是截断）."
  (should (= 33 (seshat-reads-percent (list :page 1 :total 3))))
  (should (= 67 (seshat-reads-percent (list :page 2 :total 3))))
  (should (= 100 (seshat-reads-percent (list :page 3 :total 3))))
  (should (= 0 (seshat-reads-percent (list :page 1 :total 1000)))))

;;; 记录 / 读取往返

(ert-deftest seshat-reads-test-record-get-roundtrip-and-overwrite ()
  "`record' → `get' 往返一致；同一 uid 再次记录是覆盖写（条目只有一份）."
  (seshat-reads-test--with-env
    (let ((entry (seshat-reads-record "uid-a" 3 12)))
      (should (= 3 (plist-get entry :page)))
      (should (= 12 (plist-get entry :total)))
      (should (integerp (plist-get entry :updated)))
      (should (equal entry (seshat-reads-get "uid-a"))))
    (seshat-reads-record "uid-a" 7 12)
    (should (= 7 (plist-get (seshat-reads-get "uid-a") :page)))
    (should (= 1 (length (plist-get seshat-reads--state :reads))))
    ;; 未记录过的 uid 返回 nil
    (should-not (seshat-reads-get "uid-unknown"))))

(ert-deftest seshat-reads-test-multiple-uids-are-independent ()
  "多个 uid 互不干扰，条目顺序稳定（同一 uid 覆盖不改变位置）."
  (seshat-reads-test--with-env
    (seshat-reads-record "uid-a" 1 10)
    (seshat-reads-record "uid-b" 5 20)
    (seshat-reads-record "uid-a" 2 10)
    (should (= 2 (plist-get (seshat-reads-get "uid-a") :page)))
    (should (= 5 (plist-get (seshat-reads-get "uid-b") :page)))
    (should (= 20 (plist-get (seshat-reads-get "uid-b") :total)))
    (should (equal (mapcar #'car (plist-get seshat-reads--state :reads))
                   '("uid-a" "uid-b")))))

(ert-deftest seshat-reads-test-save-then-reload-roundtrip ()
  "`seshat-reads-save' 后把模块变量置 nil 重新加载，条目逐字段一致.
同时断言父目录不存在时被自动创建（默认路径的首个写入场景）。"
  (seshat-reads-test--with-env
    (let* ((nested (expand-file-name "nested/dir/reads.eld"
                                     seshat-reads-test--dir))
           (seshat-reads-file nested))
      (seshat-reads-record "uid-a" 4 9)
      (seshat-reads-save)
      (should (file-exists-p nested))
      (should (= 4 (plist-get (seshat-reads-get "uid-a") :page)))
      ;; 落盘兑现了挂起的写：定时器与 pending 都清空
      (should-not seshat-reads--pending)
      (should-not seshat-reads--timer)
      (let ((page (plist-get (seshat-reads-get "uid-a") :page))
            (total (plist-get (seshat-reads-get "uid-a") :total))
            (updated (plist-get (seshat-reads-get "uid-a") :updated)))
        (setq seshat-reads--state nil)
        (should (= page (plist-get (seshat-reads-get "uid-a") :page)))
        (should (= total (plist-get (seshat-reads-get "uid-a") :total)))
        (should (= updated (plist-get (seshat-reads-get "uid-a") :updated))))
      ;; 文件头带 `:version'
      (should (string-match-p ":version 1"
                              (seshat-reads-test--contents nested))))))

(ert-deftest seshat-reads-test-atomic-write-leaves-no-temp-file ()
  "原子写：写完目录里只剩 \"reads.eld\"，没有 `seshat-reads*' 临时文件残留."
  (seshat-reads-test--with-env
    (seshat-reads-record "uid-a" 1 2)
    (seshat-reads-save)
    (seshat-reads-record "uid-a" 2 2)
    (seshat-reads-save)
    (should (equal (directory-files seshat-reads-test--dir)
                   '("." ".." "reads.eld")))))

;;; 容错：坏文件与版本不符

(ert-deftest seshat-reads-test-corrupt-file-degrades-and-keeps-file ()
  "内容非法的文件 → `get' 返回 nil、不抛错、记一条 warn、**原文件仍在**."
  (seshat-reads-test--with-env
    (let ((logs nil))
      (seshat-reads-test--write seshat-reads-file "(这不是合法的进度 plist")
      (cl-letf (((symbol-function 'seshat-log)
                 (lambda (level format-string &rest args)
                   (push (cons level (apply #'format format-string args)) logs))))
        (should-not (seshat-reads-get "uid-a")))
      (should (file-exists-p seshat-reads-file))
      (should (equal (seshat-reads-test--text seshat-reads-file)
                     "(这不是合法的进度 plist"))
      (should (equal (car (car logs)) 'warn)))))

(ert-deftest seshat-reads-test-trailing-content-degrades-and-keeps-file ()
  "顶层 plist 之后还有多余 form（拼接 / 截断痕迹）→ 按空表处理、不抛错、文件保留."
  (seshat-reads-test--with-env
    (let ((content (concat
                    "(:version 1 :reads ((\"uid-a\" . (:page 1 :total 2 :updated 3))))\n"
                    "(:version 1 :reads nil)\n")))
      (seshat-reads-test--write seshat-reads-file content)
      (should-not (seshat-reads-get "uid-a"))
      (should (equal (seshat-reads-test--text seshat-reads-file) content)))))

(ert-deftest seshat-reads-test-version-mismatch-is-empty-and-keeps-file ()
  "`:version' 不等于 1 → 视为空表，**不删文件**、不抛错."
  (seshat-reads-test--with-env
    (let ((content "(:version 99 :reads ((\"uid-a\" . (:page 5 :total 10 :updated 1))))"))
      (seshat-reads-test--write seshat-reads-file content)
      (should-not (seshat-reads-get "uid-a"))
      (should (equal (seshat-reads-test--text seshat-reads-file) content)))
    ;; 缺失 `:version' 同样视为空
    (setq seshat-reads--state nil)
    (let ((content "(:reads ((\"uid-a\" . (:page 5 :total 10 :updated 1))))"))
      (seshat-reads-test--write seshat-reads-file content)
      (should-not (seshat-reads-get "uid-a"))
      (should (equal (seshat-reads-test--text seshat-reads-file) content)))))

;;; 清空

(ert-deftest seshat-reads-test-clear-single-uid ()
  "`seshat-reads-clear' 传 uid 只删该条，其余保留，且立即落盘."
  (seshat-reads-test--with-env
    (seshat-reads-record "uid-a" 1 10)
    (seshat-reads-record "uid-b" 2 10)
    (seshat-reads-clear "uid-a")
    (should-not (seshat-reads-get "uid-a"))
    (should (= 2 (plist-get (seshat-reads-get "uid-b") :page)))
    ;; 立即落盘：重新加载后仍是清空后的形状
    (setq seshat-reads--state nil)
    (should-not (seshat-reads-get "uid-a"))
    (should (= 2 (plist-get (seshat-reads-get "uid-b") :page)))))

(ert-deftest seshat-reads-test-clear-all ()
  "`seshat-reads-clear' 不传 uid 清空全部，且立即落盘."
  (seshat-reads-test--with-env
    (seshat-reads-record "uid-a" 1 10)
    (seshat-reads-record "uid-b" 2 10)
    (seshat-reads-clear)
    (should-not (seshat-reads-get "uid-a"))
    (should-not (seshat-reads-get "uid-b"))
    (should-not (plist-get seshat-reads--state :reads))
    (setq seshat-reads--state nil)
    (should-not (seshat-reads-get "uid-a"))
    (should (file-exists-p seshat-reads-file))))

;;; 落盘去抖

(ert-deftest seshat-reads-test-debounce-arms-once-then-save-flushes ()
  "连续 `record' 3 次只武装一次定时器；到点前不写盘，`seshat-reads-save' 才写一次."
  (seshat-reads-test--with-env
    (let ((armed 0))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest _args)
                   (setq armed (1+ armed))
                   nil)))
        (seshat-reads-record "uid-a" 1 10)
        (seshat-reads-record "uid-a" 2 10)
        (seshat-reads-record "uid-a" 3 10))
      (should (= 1 armed))
      (should seshat-reads--pending)
      ;; 定时器未到点：内存已更新，但文件还没写出
      (should (= 3 (plist-get (seshat-reads-get "uid-a") :page)))
      (should-not (file-exists-p seshat-reads-file))
      (seshat-reads-save)
      (should (file-exists-p seshat-reads-file))
      (should-not seshat-reads--pending)
      (should-not seshat-reads--timer)
      ;; 落盘内容是最新一次记录（不是第一次）
      (setq seshat-reads--state nil)
      (should (= 3 (plist-get (seshat-reads-get "uid-a") :page))))))

;;; 页号采集与唯一写入漏斗

(ert-deftest seshat-reads-test-note-current-page-records ()
  "`seshat-reads--note-current-page' 从 buffer 取页号与总页数并记录（单一漏斗）."
  (seshat-reads-test--with-env
    (with-temp-buffer
      (setq-local seshat-reader-current-doc-pagecount 12)
      (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) 5)))
        (seshat-reads--note-current-page "uid-a")
        (should (= 5 (plist-get (seshat-reads-get "uid-a") :page)))
        (should (= 12 (plist-get (seshat-reads-get "uid-a") :total)))
        ;; 显式传 PAGE 时不调用访问器（调用方已取值，避免重复读视口）
        (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                   (lambda (&optional _window)
                     (ert-fail "显式传 PAGE 时不应再调用页号访问器"))))
          (seshat-reads--note-current-page "uid-b" 7)
          (should (= 7 (plist-get (seshat-reads-get "uid-b") :page))))))))

(ert-deftest seshat-reads-test-note-current-page-skips-without-page ()
  "页号取不到（未加载 reader / 未渲染）或 uid 为空时静默不写，不抛错."
  (seshat-reads-test--with-env
    (with-temp-buffer
      ;; 未桩替访问器且 reader 未加载 → 页号 nil
      (should-not (seshat-reads--buffer-page))
      (should-not (seshat-reads--note-current-page "uid-a"))
      (should-not (seshat-reads-get "uid-a"))
      ;; 页号为 nil 的访问器（buffer 里还没有页行）
      (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) nil)))
        (should-not (seshat-reads--note-current-page "uid-a"))
        (should-not (seshat-reads-get "uid-a")))
      ;; uid 为空 → 不写（库外 / 未入库文档）
      (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) 3)))
        (should-not (seshat-reads--note-current-page nil))
        (should-not (seshat-reads--note-current-page ""))
        (should-not (seshat-reads-get ""))))))

;;; 惰性加载

(ert-deftest seshat-reads-test-lazy-load-does-not-create-file ()
  "首次读取才加载；文件不存在时返回空表且**不创建**文件."
  (seshat-reads-test--with-env
    (should-not seshat-reads--state)
    (should-not (seshat-reads-get "uid-a"))
    (should seshat-reads--state)
    (should-not (file-exists-p seshat-reads-file))
    (should-not (plist-get seshat-reads--state :reads))))

(provide 'seshat-reads-test)
;;; seshat-reads-test.el ends here
