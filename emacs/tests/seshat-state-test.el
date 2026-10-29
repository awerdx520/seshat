;;; seshat-state-test.el --- ERT tests for seshat-state  -*- lexical-binding: t; -*-

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

;; `seshat-state' 的 ERT 测试套件，覆盖数据形状与三条组合语义：remap 的
;; 冲突语义（索引改指新主、旧属主 `:path' 置 nil + `:orphan'）、墓碑 × dirty
;; × base-blob 的组合、以及原子写不留临时文件。
;;
;; 每个用例都用 `seshat-state-test--with-temp-state' 把 `seshat-state-file'
;; 绑定到临时目录里的 "sync-state.eld"，并把内存状态 `seshat-state--state'
;; 绑定为 nil（从空状态起步），结束递归删除临时目录——**绝不写用户真实的
;; `~/.local/share/seshat/'**，也绝不读写用户在用的状态文件。
;;
;; 全部用例**不触网**、不依赖运行中的 Emacs：本模块是纯状态库，测试只用
;; `emacs --batch' 即可跑通。涉及警告的用例统一桩替 `display-warning' 断言
;; 「确实发出了警告」。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-state)

;;; 测试辅助

(defvar seshat-state-test--dir nil
  "当前用例的临时目录（带结尾斜杠）.
由 `seshat-state-test--with-temp-state' 绑定，供需要枚举目录内容的用例使用。")

(defun seshat-state-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根（ECA 客户端所为），那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-state-test-" t))))

(defmacro seshat-state-test--with-temp-state (&rest body)
  "在独立的临时状态文件下执行 BODY.
BODY 执行期间 `seshat-state-file' 指向临时目录里的 \"sync-state.eld\"，
`seshat-state--state' 为 nil（空状态起步），临时目录路径见
`seshat-state-test--dir'。结束后递归删除临时目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-state-test--dir (seshat-state-test--make-temp-dir))
          (seshat-state-file (expand-file-name "sync-state.eld"
                                               seshat-state-test--dir))
          (seshat-state--state nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory seshat-state-test--dir t)))))

(defun seshat-state-test--warnings (function)
  "在调用 FUNCTION 期间捕获 `display-warning'，返回 `(RESULT . WARNINGS)'.
WARNINGS 是消息字符串列表（调用顺序），用于断言「确实发出了警告」。"
  (let (warnings)
    (let ((result (cl-letf (((symbol-function 'display-warning)
                             (lambda (_type message &optional _level _buffer)
                               (push message warnings))))
                   (funcall function))))
      (cons result (nreverse warnings)))))

(defun seshat-state-test--file-contents (file)
  "返回 FILE 的全部内容（字符串）."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun seshat-state-test--directory-entries (dir)
  "返回 DIR 下全部文件名的有序列表（含 \".\" 与 \"..\"）."
  (sort (directory-files dir) #'string<))

(defun seshat-state-test--write-state-file (state)
  "把 STATE 以 `prin1' 直接写入 `seshat-state-file'（模拟手工/旧版本文件）."
  (with-temp-file seshat-state-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 state (current-buffer)))))

(defun seshat-state-test--count-rebuilds (function)
  "在调用 FUNCTION 期间统计 `seshat-state--rebuild-paths' 的调用次数.
返回 `(RESULT . COUNT)'：RESULT 是 FUNCTION 的返回值，COUNT 是纯函数
`seshat-state--rebuild-paths' 被调用的次数（`cl-letf' 替换 symbol-function，
因此 `seshat-state--rebuild-paths-now' 与 `seshat-state--put-entry' 的调用都会
被数到）。用它是为了断言批量块把 O(n) 重建压成整批一次。"
  (let ((original (symbol-function 'seshat-state--rebuild-paths))
        (count 0))
    (let ((result
           (cl-letf (((symbol-function 'seshat-state--rebuild-paths)
                      (lambda (state)
                        (setq count (1+ count))
                        (funcall original state))))
             (funcall function))))
      (cons result count))))

;;; 默认值与空状态

(ert-deftest seshat-state-test-default-file-location ()
  "默认状态文件与离线队列同目录、文件名固定为 sync-state.eld。"
  (should (equal (eval (car (get 'seshat-state-file 'standard-value)) t)
                 (expand-file-name "sync-state.eld"
                                   "~/.local/share/seshat/"))))

(ert-deftest seshat-state-test-load-missing-file-is-empty ()
  "文件不存在时返回空状态，且不创建文件。"
  (seshat-state-test--with-temp-state
    (should-not (file-exists-p seshat-state-file))
    (let ((state (seshat-state-load)))
      (should (equal (plist-get state :version) 1))
      (should (equal (plist-get state :cursor) 0))
      (should (equal (plist-get state :roots) nil))
      (should (equal (plist-get state :uids) nil))
      (should (equal (plist-get state :paths) nil)))
    (should (equal (seshat-state-cursor) 0))
    (should-not (file-exists-p seshat-state-file))))

;;; save / load 往返

(ert-deftest seshat-state-test-save-load-roundtrip ()
  "save → 丢弃内存状态 → load 后 :roots / :uids / :paths / :cursor 全等值。"
  (seshat-state-test--with-temp-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")
                              ("ondemand" "/tmp/on" "ondemand")))
    (seshat-state-set-cursor 42)
    (seshat-state-set "uid-a" (list :root "notes" :path "journal/2026-10-24.org"))
    (seshat-state-set-base-blob "uid-b" "sha1:deadbeef" 4096 1761234567)
    (seshat-state-mark-dirty "uid-b")
    (seshat-state-save)
    (should (file-exists-p seshat-state-file))
    (let ((before seshat-state--state))
      (setq seshat-state--state nil)    ; 强制重新从磁盘读
      (let ((after (seshat-state-load)))
        (should (equal after before))
        (should (equal (plist-get after :version) 1))
        (should (equal (seshat-state-cursor) 42))
        (should (equal (seshat-state-roots)
                       '(("notes" "/tmp/notes" "mirror")
                         ("ondemand" "/tmp/on" "ondemand"))))
        (should (equal (seshat-state-uid-for-path "notes" "journal/2026-10-24.org")
                       "uid-a"))
        (should (equal (plist-get (seshat-state-get "uid-b") :base-blob)
                       "sha1:deadbeef"))
        (should (equal (seshat-state-dirty-uids) '("uid-b")))))))

(ert-deftest seshat-state-test-save-writes-version-and-header ()
  "落盘内容带生成标记且可被 `read' 读回，`:version' 为当前版本号。"
  (seshat-state-test--with-temp-state
    (seshat-state-set-cursor 3)
    (seshat-state-save)
    (let ((contents (seshat-state-test--file-contents seshat-state-file)))
      (should (string-match-p "请勿手工编辑" contents))
      (should (equal (plist-get (car (read-from-string contents)) :version) 1))
      (should (equal (plist-get (car (read-from-string contents)) :cursor) 3)))))

;;; 损坏文件容错

(ert-deftest seshat-state-test-corrupt-file-backed-up ()
  "内容无法解析 → 空状态 + 原文件改名为 .bak + 发出警告。"
  (seshat-state-test--with-temp-state
    (with-temp-file seshat-state-file (insert "("))
    (let* ((captured (seshat-state-test--warnings #'seshat-state-load))
           (state (car captured))
           (warnings (cdr captured)))
      (should (equal state (seshat-state--empty)))
      (should-not (file-exists-p seshat-state-file))
      (should (file-exists-p (concat seshat-state-file ".bak")))
      ;; 坏内容原样保留在备份里（不是被删除、也不是被覆盖成空状态）
      (should (equal (seshat-state-test--file-contents
                      (concat seshat-state-file ".bak"))
                     "("))
      (should (= 1 (length warnings))))))

(ert-deftest seshat-state-test-non-plist-content-backed-up ()
  "顶层值不是 plist（如 42）→ 同样按损坏处理。"
  (seshat-state-test--with-temp-state
    (with-temp-file seshat-state-file (insert "42\n"))
    (let* ((captured (seshat-state-test--warnings #'seshat-state-load)))
      (should (equal (car captured) (seshat-state--empty)))
      (should-not (file-exists-p seshat-state-file))
      (should (file-exists-p (concat seshat-state-file ".bak")))
      (should (= 1 (length (cdr captured)))))))

(ert-deftest seshat-state-test-trailing-content-backed-up ()
  "顶层 plist 之后还有多余内容（拼接/截断痕迹）→ 按损坏处理。"
  (seshat-state-test--with-temp-state
    (with-temp-file seshat-state-file
      (insert "(:version 1 :cursor 0)\n(:cursor 99)\n"))
    (let* ((captured (seshat-state-test--warnings #'seshat-state-load)))
      (should (equal (car captured) (seshat-state--empty)))
      (should-not (file-exists-p seshat-state-file))
      (should (file-exists-p (concat seshat-state-file ".bak")))
      (should (= 1 (length (cdr captured)))))))

(ert-deftest seshat-state-test-corrupt-file-overwrites-old-backup ()
  "已有 .bak 时再次损坏，新备份覆盖旧备份（不留下多份 .bak）。"
  (seshat-state-test--with-temp-state
    (with-temp-file (concat seshat-state-file ".bak") (insert "old"))
    (with-temp-file seshat-state-file (insert "("))
    (seshat-state-test--warnings #'seshat-state-load)
    (should-not (file-exists-p seshat-state-file))
    (should (equal (seshat-state-test--file-contents
                    (concat seshat-state-file ".bak"))
                   "("))))

;;; :paths 一致性

(ert-deftest seshat-state-test-load-rebuilds-inconsistent-paths ()
  ":paths 与 :uids 不一致 → 按 :uids 重建索引 + 警告。"
  (seshat-state-test--with-temp-state
    (seshat-state-test--write-state-file
     (list :version 1 :cursor 7 :roots nil
           :uids (list (cons "uid-a" (list :root "notes" :path "a.org")))
           :paths (list (cons (cons "notes" "bogus.org") "uid-x"))))
    (let* ((captured (seshat-state-test--warnings #'seshat-state-load)))
      (should (equal (seshat-state-uid-for-path "notes" "a.org") "uid-a"))
      (should-not (seshat-state-uid-for-path "notes" "bogus.org"))
      (should (= 1 (length (cdr captured))))
      (should (= 7 (seshat-state-cursor))))))

(ert-deftest seshat-state-test-load-consistent-paths-no-warning ()
  ":paths 与 :uids 一致时不重建、不告警。"
  (seshat-state-test--with-temp-state
    (seshat-state-test--write-state-file
     (list :version 1 :cursor 0 :roots nil
           :uids (list (cons "uid-a" (list :root "notes" :path "a.org")))
           :paths (list (cons (cons "notes" "a.org") "uid-a"))))
    (let* ((captured (seshat-state-test--warnings #'seshat-state-load)))
      (should-not (cdr captured))
      (should (equal (seshat-state-uid-for-path "notes" "a.org") "uid-a")))))

;;; uid ↔ path 双向

(ert-deftest seshat-state-test-uid-path-roundtrip ()
  "uid-for-path 与 path-for-uid 互为反函数；未知键返回 nil。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (should (equal (seshat-state-uid-for-path "notes" "a.org") "uid-a"))
    (should (equal (seshat-state-path-for-uid "uid-a") (cons "notes" "a.org")))
    (should-not (seshat-state-uid-for-path "notes" "missing.org"))
    (should-not (seshat-state-path-for-uid "uid-missing"))))

(ert-deftest seshat-state-test-same-path-different-roots ()
  "同一相对路径在不同根下不串扰。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-1" (list :root "notes" :path "a.org"))
    (seshat-state-set "uid-2" (list :root "work" :path "a.org"))
    (should (equal (seshat-state-uid-for-path "notes" "a.org") "uid-1"))
    (should (equal (seshat-state-uid-for-path "work" "a.org") "uid-2"))
    (should (equal (seshat-state-path-for-uid "uid-2") (cons "work" "a.org")))
    (should (= 2 (length (plist-get seshat-state--state :paths))))))

(ert-deftest seshat-state-test-set-replaces-entry ()
  "`seshat-state-set' 整体替换条目并同步索引。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org" :dirty t))
    (seshat-state-set "uid-a" (list :root "work" :path "a.org"))
    (should-not (plist-get (seshat-state-get "uid-a") :dirty))
    (should-not (seshat-state-uid-for-path "notes" "a.org"))
    (should (equal (seshat-state-uid-for-path "work" "a.org") "uid-a"))))

;;; base blob 与 dirty

(ert-deftest seshat-state-test-set-base-blob-clears-dirty ()
  "set-base-blob 写入三个字段、清 dirty，并保留既有 :root/:path。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-mark-dirty "uid-a")
    (should (equal (seshat-state-dirty-uids) '("uid-a")))
    (seshat-state-set-base-blob "uid-a" "sha1:1" 10 1761234567)
    (should-not (seshat-state-dirty-uids))
    (let ((entry (seshat-state-get "uid-a")))
      (should (equal (plist-get entry :base-blob) "sha1:1"))
      (should (equal (plist-get entry :size) 10))
      (should (equal (plist-get entry :mtime) 1761234567))
      (should-not (plist-get entry :dirty))
      (should (equal (plist-get entry :path) "a.org"))
      (should (equal (plist-get entry :root) "notes")))))

(ert-deftest seshat-state-test-set-base-blob-creates-entry ()
  "对未登记 uid 调 set-base-blob 会新建条目（不报错）。"
  (seshat-state-test--with-temp-state
    (should-not (seshat-state-get "uid-new"))
    (let ((entry (seshat-state-set-base-blob "uid-new" "sha1:x" 1 2)))
      (should (equal (plist-get entry :base-blob) "sha1:x"))
      (should-not (plist-get entry :path)))
    (should (seshat-state-get "uid-new"))))

(ert-deftest seshat-state-test-dirty-uids-tracks-marks ()
  "mark-dirty / mark-clean 反映到 dirty-uids，顺序按 :uids。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-set "uid-b" (list :root "notes" :path "b.org"))
    (should-not (seshat-state-dirty-uids))
    (seshat-state-mark-dirty "uid-a")
    (seshat-state-mark-dirty "uid-b")
    (should (equal (seshat-state-dirty-uids) '("uid-a" "uid-b")))
    (seshat-state-mark-clean "uid-a")
    (should (equal (seshat-state-dirty-uids) '("uid-b")))
    (should-not (plist-get (seshat-state-get "uid-a") :dirty))))

;;; 墓碑

(ert-deftest seshat-state-test-mark-deleted-tombstone ()
  "墓碑：置 :deleted-at、清 :dirty、保留 base-blob/size/mtime。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-set-base-blob "uid-a" "sha1:1" 10 1761234567)
    (seshat-state-mark-dirty "uid-a")
    (let ((entry (seshat-state-mark-deleted "uid-a")))
      (should (numberp (plist-get entry :deleted-at)))
      (should-not (plist-get entry :dirty))
      (should (equal (plist-get entry :base-blob) "sha1:1"))
      (should (equal (plist-get entry :size) 10))
      (should (equal (plist-get entry :mtime) 1761234567)))
    (should (equal (seshat-state-deleted-uids) '("uid-a")))
    (should-not (seshat-state-dirty-uids))
    ;; 墓碑即使事后被误标脏，也不进 dirty-uids
    (seshat-state-mark-dirty "uid-a")
    (should-not (seshat-state-dirty-uids))
    (should (equal (seshat-state-deleted-uids) '("uid-a")))))

(ert-deftest seshat-state-test-tombstone-not-indexed ()
  "墓碑不占本地路径：不进 :paths，uid-for-path 返回 nil。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-set "uid-b" (list :root "notes" :path "b.org"))
    (seshat-state-mark-deleted "uid-a")
    (should-not (seshat-state-uid-for-path "notes" "a.org"))
    (should-not (seshat-state-path-for-uid "uid-a"))
    (let ((rebuilt (seshat-state--rebuild-paths seshat-state--state)))
      (should (equal (plist-get rebuilt :paths)
                     (list (cons (cons "notes" "b.org") "uid-b")))))))

;;; 活性判据唯一实现（`--rebuild-paths' 复用 `--entry-active-p'）

(ert-deftest seshat-state-test-rebuild-paths-agrees-with-entry-active-p ()
  "`--rebuild-paths' 与 `--entry-active-p' 对四种条目给出一致判定.
四种条目：活（有路径）/ 墓碑（`:deleted-at'）/ 孤儿（`:orphan'）/ 无路径。
这是「活性定义只有一处实现」的机械保证——把内联三条件换成调用
`seshat-state--entry-active-p' 之后，两者不可能再各自漂移。"
  (seshat-state-test--with-temp-state
    (let* ((cases (list (cons "live" (list :root "books" :path "a.pdf"))
                        (cons "tomb" (list :root "books" :path "b.pdf"
                                           :deleted-at 1700000000))
                        (cons "orphan" (list :root "books" :path "c.pdf"
                                             :orphan t))
                        (cons "nopath" (list :root "books"))))
           (indexed-uids nil))
      (dolist (cell cases)
        (seshat-state-set (car cell) (cdr cell)))
      (let ((paths (plist-get (seshat-state--rebuild-paths seshat-state--state)
                              :paths)))
        (setq indexed-uids (mapcar #'cdr paths))
        (dolist (cell cases)
          (let* ((uid (car cell))
                 (entry (seshat-state-get uid))
                 (active (seshat-state--entry-active-p entry)))
            ;; 两处口径必须一致：活 ↔ 建索引
            (should (eq (and active t) (and (member uid indexed-uids) t)))
            ;; 逐个条目复核判据本身（防「两边都错得一样」）
            (pcase uid
              ("live" (should active))
              (_ (should-not active))))))
      ;; 正断言：四种里恰好 1 个活条目、1 个索引项（否则上面的「一致」是空断言）
      (should (equal (list "live") indexed-uids))
      (should (= 1 (length (cl-remove-if-not #'seshat-state--entry-active-p
                                             (mapcar (lambda (cell)
                                                       (seshat-state-get (car cell)))
                                                     cases))))))))

;;; 游标

(ert-deftest seshat-state-test-cursor-read-write ()
  "游标默认 0、可读写；非法值抛错且不改变原值。"
  (seshat-state-test--with-temp-state
    (should (equal (seshat-state-cursor) 0))
    (should (equal (seshat-state-set-cursor 99) 99))
    (should (equal (seshat-state-cursor) 99))
    (should-error (seshat-state-set-cursor -1))
    (should-error (seshat-state-set-cursor "x"))
    (should (equal (seshat-state-cursor) 99))))

;;; remap

(ert-deftest seshat-state-test-remap-moves-path ()
  "无冲突 rename：索引同步更新，旧路径不再命中。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "old.org"))
    (let ((result (seshat-state-remap "uid-a" "notes" "new.org")))
      (should-not (plist-get result :old-uid))
      (should-not (plist-get result :old-path)))
    (should (equal (seshat-state-path-for-uid "uid-a") (cons "notes" "new.org")))
    (should-not (seshat-state-uid-for-path "notes" "old.org"))
    (should (equal (seshat-state-uid-for-path "notes" "new.org") "uid-a"))))

(ert-deftest seshat-state-test-remap-across-roots ()
  "跨根 rename：:root 与 :path 一起更新，旧根下的索引被清除。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-remap "uid-a" "work" "a.org")
    (should (equal (seshat-state-path-for-uid "uid-a") (cons "work" "a.org")))
    (should-not (seshat-state-uid-for-path "notes" "a.org"))
    (should (equal (seshat-state-uid-for-path "work" "a.org") "uid-a"))))

(ert-deftest seshat-state-test-remap-unknown-uid-creates-entry ()
  "对未登记 uid 的 remap 新建条目而非报错。"
  (seshat-state-test--with-temp-state
    (let ((result (seshat-state-remap "uid-new" "notes" "fresh.org")))
      (should-not (plist-get result :old-uid)))
    (should (equal (seshat-state-path-for-uid "uid-new")
                   (cons "notes" "fresh.org")))))

(ert-deftest seshat-state-test-remap-same-path-is-not-conflict ()
  "remap 到自身已占的路径不算冲突。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (let ((result (seshat-state-remap "uid-a" "notes" "a.org")))
      (should-not (plist-get result :old-uid))
      (should-not (plist-get result :old-path)))
    (should (equal (seshat-state-path-for-uid "uid-a") (cons "notes" "a.org")))))

(ert-deftest seshat-state-test-remap-conflict-orphans-displaced-uid ()
  "强制用例：remap 冲突时索引改指新主、旧属主 :path 置 nil + :orphan，且回到
索引重建后仍指新主（防双索引回退）。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-b" (list :root "notes" :path "p.org"))
    (seshat-state-set-base-blob "uid-b" "sha1:b" 11 1111)
    (seshat-state-set "uid-a" (list :root "notes" :path "old.org"))
    (should (equal (seshat-state-uid-for-path "notes" "p.org") "uid-b"))
    (let ((result (seshat-state-remap "uid-a" "notes" "p.org")))
      ;; 返回值带旧属主与原路径，供调用方告警
      (should (equal (plist-get result :old-uid) "uid-b"))
      (should (equal (plist-get result :old-path) "p.org")))
    ;; 新主拿到路径，旧属主失去路径
    (should (equal (seshat-state-path-for-uid "uid-a") (cons "notes" "p.org")))
    (should-not (seshat-state-path-for-uid "uid-b"))
    (should (equal (seshat-state-uid-for-path "notes" "p.org") "uid-a"))
    ;; 旧属主条目：:path 已清、带 :orphan、其它字段保留
    (let ((old (seshat-state-get "uid-b")))
      (should-not (plist-get old :path))
      (should (eq t (plist-get old :orphan)))
      (should (equal (plist-get old :base-blob) "sha1:b")))
    ;; 关键：索引重建后仍指 A（若 B 残留旧 :path 就会被抢回去）
    (let ((rebuilt (seshat-state--rebuild-paths seshat-state--state)))
      (should (equal (plist-get rebuilt :paths)
                     (list (cons (cons "notes" "p.org") "uid-a"))))
      (should (equal (plist-get rebuilt :paths)
                     (plist-get seshat-state--state :paths))))
    ;; 存盘再加载后依然指 A（落盘形状也一致）
    (seshat-state-save)
    (setq seshat-state--state nil)
    (seshat-state-load)
    (should (equal (seshat-state-uid-for-path "notes" "p.org") "uid-a"))
    (should (eq t (plist-get (seshat-state-get "uid-b") :orphan)))))

;;; 原子写

(ert-deftest seshat-state-test-save-leaves-no-temp-file ()
  "强制用例：save 后目录里除状态文件外无任何其它文件（无残留临时文件）。"
  (seshat-state-test--with-temp-state
    (seshat-state-set-base-blob "uid-a" "sha1:1" 10 1761234567)
    (seshat-state-save)
    (should (equal (seshat-state-test--directory-entries seshat-state-test--dir)
                   '("." ".." "sync-state.eld")))
    ;; 再存一次（覆盖已存在文件的分支）仍然无残留
    (seshat-state-save)
    (should (equal (seshat-state-test--directory-entries seshat-state-test--dir)
                   '("." ".." "sync-state.eld")))
    ;; 且内容仍可读出
    (setq seshat-state--state nil)
    (should-not (seshat-state-dirty-uids))
    (should (equal (plist-get (seshat-state-get "uid-a") :base-blob) "sha1:1"))))

(ert-deftest seshat-state-test-save-creates-parent-directory ()
  "父目录不存在时自动创建，且仍不留临时文件。"
  (seshat-state-test--with-temp-state
    (let ((seshat-state-file (expand-file-name "nested/dir/sync-state.eld"
                                               seshat-state-test--dir)))
      (seshat-state-set-base-blob "uid-a" "sha1:1" 1 2)
      (seshat-state-save)
      (should (file-exists-p seshat-state-file))
      (should (equal (directory-files (file-name-directory seshat-state-file)
                                      nil "\\`[^.]")
                     '("sync-state.eld"))))))

;;; 纯函数

(ert-deftest seshat-state-test-rebuild-paths-is-pure-and-correct ()
  "`--rebuild-paths'：只索引活条目（排除孤儿 / 墓碑 / 无路径），且不修改入参。"
  (let* ((state (list :version 1 :cursor 0 :roots nil
                      :uids (list (cons "uid-a" (list :root "notes" :path "a.org"))
                                  (cons "uid-b" (list :root "notes" :path nil))
                                  (cons "uid-c" (list :root "work" :path "a.org"))
                                  (cons "uid-d" (list :root "notes" :path "d.org"
                                                      :orphan t))
                                  (cons "uid-e" (list :root "notes" :path "e.org"
                                                      :deleted-at 17)))
                      :paths (list (cons (cons "notes" "bogus.org") "uid-x"))))
         (original (copy-tree state))
         (rebuilt (seshat-state--rebuild-paths state)))
    (should (equal (plist-get rebuilt :paths)
                   (list (cons (cons "notes" "a.org") "uid-a")
                         (cons (cons "work" "a.org") "uid-c"))))
    (should (equal state original))))

(ert-deftest seshat-state-test-rebuild-paths-keeps-first-duplicate ()
  "`--rebuild-paths'：同一 `(root . path)' 出现多次时保留靠前的条目。"
  (let* ((state (list :version 1 :cursor 0 :roots nil
                      :uids (list (cons "uid-1" (list :root "notes" :path "x.org"))
                                  (cons "uid-2" (list :root "notes" :path "x.org")))
                      :paths nil))
         (rebuilt (seshat-state--rebuild-paths state)))
    (should (equal (plist-get rebuilt :paths)
                   (list (cons (cons "notes" "x.org") "uid-1"))))))

(ert-deftest seshat-state-test-normalize-tolerates-garbage ()
  "`--normalize'：非 plist → 空状态；类型错位字段被修正；坏 :uids/:roots 元素被丢弃。"
  (should (equal (seshat-state--normalize nil) (seshat-state--empty)))
  (should (equal (seshat-state--normalize "garbage") (seshat-state--empty)))
  (should (equal (seshat-state--normalize 42) (seshat-state--empty)))
  (let ((state (seshat-state--normalize
                (list :version 9
                      :cursor "oops"
                      :unknown-key 'dropped
                      :roots (list '("notes" "/tmp/n")          ; 只有两元
                                   '("ok" "/tmp/o" "mirror"))
                      :uids (list (cons "uid-a" (list :root "notes"
                                                      :path "a.org"
                                                      :size "big"
                                                      :dirty 'yes))
                                  (cons 42 :junk)                ; 键不是字符串
                                  "not-a-cell")))))              ; 不是 cons
    (should (equal (plist-get state :version) 1))
    (should (equal (plist-get state :cursor) 0))
    (should (equal (plist-get state :roots) '(("ok" "/tmp/o" "mirror"))))
    (should (= 1 (length (plist-get state :uids))))
    (should-not (plist-member state :unknown-key))
    (let ((entry (cdr (assoc "uid-a" (plist-get state :uids)))))
      (should (eq t (plist-get entry :dirty)))
      (should-not (plist-get entry :size)))
    (should (equal (plist-get state :paths) nil))))

;;; 根映射

(ert-deftest seshat-state-test-roots-set-and-get ()
  "`set-roots' 保存三元组并拒绝非法形状。"
  (seshat-state-test--with-temp-state
    (should-not (seshat-state-roots))
    (let ((roots '(("notes" "/tmp/notes" "mirror"))))
      (should (equal (seshat-state-set-roots roots) roots))
      (should (equal (seshat-state-roots) roots)))
    (should-error (seshat-state-set-roots '(("notes" "/tmp/notes"))))
    (should-error (seshat-state-set-roots '("notes")))
    (should (equal (seshat-state-roots) '(("notes" "/tmp/notes" "mirror"))))))

;;; 批量写入（seshat-state-batch）

(ert-deftest seshat-state-test-batch-rebuilds-paths-once ()
  "批量块内 N 次写入后 `--rebuild-paths' 只被调用 1 次（逐条写入则 N 次）。"
  (seshat-state-test--with-temp-state
    (seshat-state-load)                 ; 预热：后续 ensure 不再触发 load
    (let ((uids '("uid-1" "uid-2" "uid-3" "uid-4" "uid-5")))
      ;; 批量：5 次写入 → 1 次重建
      (let* ((captured
              (seshat-state-test--count-rebuilds
               (lambda ()
                 (seshat-state-batch
                   (dolist (uid uids)
                     (seshat-state-set
                      uid (list :root "notes" :path (concat uid ".org"))))))))
             (count (cdr captured)))
        (should (= 1 count))
        ;; 索引确实按 5 条写入重建过（不是「跳过重建导致索引为空」）
        (should (= 5 (length (plist-get seshat-state--state :paths))))
        (should (equal (seshat-state-uid-for-path "notes" "uid-3.org") "uid-3")))
      ;; 对照：同样的 5 次写入逐条执行（不在批量块内）→ 5 次重建
      (setq seshat-state--state (seshat-state--empty))
      (should (= 5 (cdr (seshat-state-test--count-rebuilds
                         (lambda ()
                           (dolist (uid uids)
                             (seshat-state-set
                              uid (list :root "notes"
                                        :path (concat uid ".org"))))))))))))

(ert-deftest seshat-state-test-batch-matches-sequential-writes ()
  "批量写入的最终状态与逐条写入完全一致（含 `:paths' / 墓碑 / dirty / 游标）。"
  (let (batched sequential)
    ;; 固定时钟：墓碑的 `:deleted-at' 取 `(truncate (float-time))'，
    ;; 两次运行跨秒边界会不等，与本用例要验证的东西无关。
    (cl-letf (((symbol-function 'float-time) (lambda () 2000000000.0)))
      (seshat-state-test--with-temp-state
        (seshat-state-batch
          (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
          (seshat-state-set "uid-b" (list :root "notes" :path "b.org"))
          (seshat-state-set-base-blob "uid-b" "sha1:b" 11 1111)
          (seshat-state-mark-dirty "uid-a")
          (seshat-state-set "uid-c" (list :root "work" :path "c.org"))
          (seshat-state-mark-deleted "uid-c")
          (seshat-state-set-base-blob "uid-d" "sha1:d" 22 2222))
        (seshat-state-set-cursor 7)
        (setq batched seshat-state--state))
      (seshat-state-test--with-temp-state
        (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
        (seshat-state-set "uid-b" (list :root "notes" :path "b.org"))
        (seshat-state-set-base-blob "uid-b" "sha1:b" 11 1111)
        (seshat-state-mark-dirty "uid-a")
        (seshat-state-set "uid-c" (list :root "work" :path "c.org"))
        (seshat-state-mark-deleted "uid-c")
        (seshat-state-set-base-blob "uid-d" "sha1:d" 22 2222)
        (seshat-state-set-cursor 7)
        (setq sequential seshat-state--state)
        ;; 派生查询必须在绑定内做（块外 `seshat-state-file' 已恢复为真实路径）
        (should (equal (seshat-state-dirty-uids) '("uid-a")))
        (should (equal (seshat-state-deleted-uids) '("uid-c")))
        (should (= 7 (seshat-state-cursor)))))
    (should (equal batched sequential))
    ;; 索引内容逐项核对（墓碑与无路径条目都不进索引）
    (should (equal (plist-get batched :paths)
                   (list (cons (cons "notes" "a.org") "uid-a")
                         (cons (cons "notes" "b.org") "uid-b"))))
    (should (equal (plist-get batched :paths)
                   (plist-get sequential :paths)))))

(ert-deftest seshat-state-test-batch-nested-rebuilds-once ()
  "嵌套批量（深度 2）只在最外层退出时重建一次索引。"
  (seshat-state-test--with-temp-state
    (seshat-state-load)
    (let* ((captured
            (seshat-state-test--count-rebuilds
             (lambda ()
               (seshat-state-batch
                 (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
                 (seshat-state-batch
                   (should (= 2 seshat-state--batch-depth))
                   (seshat-state-set "uid-b" (list :root "notes" :path "b.org")))
                 ;; 内层退出后深度回到 1：索引仍未重建
                 (should (= 1 seshat-state--batch-depth))
                 (should-not (seshat-state-uid-for-path "notes" "b.org"))
                 (seshat-state-set "uid-c" (list :root "notes" :path "c.org"))))))
           (count (cdr captured)))
      (should (= 1 count))
      (should (= 0 seshat-state--batch-depth))
      (should (equal (plist-get seshat-state--state :paths)
                     (list (cons (cons "notes" "a.org") "uid-a")
                           (cons (cons "notes" "b.org") "uid-b")
                           (cons (cons "notes" "c.org") "uid-c")))))))

(ert-deftest seshat-state-test-batch-error-still-rebuilds-once ()
  "body 抛错时仍重建一次索引（`unwind-protect'），深度归零，状态不半残。"
  (seshat-state-test--with-temp-state
    (seshat-state-load)
    (let* ((captured
            (seshat-state-test--count-rebuilds
             (lambda ()
               (should-error
                (seshat-state-batch
                  (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
                  (seshat-state-set "uid-b" (list :root "notes" :path "b.org"))
                  (error "批内失败"))))))
           (count (cdr captured)))
      (should (= 1 count))
      (should (= 0 seshat-state--batch-depth))
      ;; 批内已写入的条目退出后可查到（索引被补齐，不是半残）
      (should (equal (seshat-state-uid-for-path "notes" "a.org") "uid-a"))
      (should (equal (seshat-state-uid-for-path "notes" "b.org") "uid-b"))
      (should (= 2 (length (plist-get seshat-state--state :paths)))))))

(ert-deftest seshat-state-test-batch-paths-stale-during-block ()
  "批量期间 `:paths' 不更新：本批新写入的条目 `uid-for-path' 返回 nil，退出后可见。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-old" (list :root "notes" :path "old.org"))
    (should (equal (seshat-state-uid-for-path "notes" "old.org") "uid-old"))
    (let (inside-new inside-old inside-paths)
      (seshat-state-batch
        (seshat-state-set "uid-new" (list :root "notes" :path "new.org"))
        (setq inside-paths (plist-get seshat-state--state :paths))
        (setq inside-new (seshat-state-uid-for-path "notes" "new.org"))
        (setq inside-old (seshat-state-uid-for-path "notes" "old.org")))
      ;; 批内：新路径查不到；旧映射仍在（索引只是「没更新」，不是被清空）
      (should-not inside-new)
      (should (equal inside-old "uid-old"))
      (should (equal inside-paths
                     (list (cons (cons "notes" "old.org") "uid-old"))))
      ;; 批后：新路径可见，索引含两条
      (should (equal (seshat-state-uid-for-path "notes" "new.org") "uid-new"))
      (should (equal (plist-get seshat-state--state :paths)
                     (list (cons (cons "notes" "old.org") "uid-old")
                           (cons (cons "notes" "new.org") "uid-new")))))))

(ert-deftest seshat-state-test-batch-returns-last-body-value ()
  "宏返回 BODY 最后一个表达式的值，且退出后深度恒为 0（含空 body）。"
  (seshat-state-test--with-temp-state
    (should (equal (seshat-state-batch "first" 'second) 'second))
    (should (= 0 seshat-state--batch-depth))
    (should (equal (seshat-state-batch 1 2 3) 3))
    (should (= 0 seshat-state--batch-depth))
    (should-not (seshat-state-batch))
    (should (= 0 seshat-state--batch-depth))))

;;; 公开枚举（seshat-state-entries）

(ert-deftest seshat-state-test-entries-order-matches-uids ()
  "`seshat-state-entries' 返回 `(uid . entry)'，顺序与 `:uids' 完全一致（不重排）。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-c" (list :root "notes" :path "c.org"))
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-set "uid-b" (list :root "work" :path "b.org"))
    (should (equal (mapcar #'car (seshat-state-entries))
                   '("uid-c" "uid-a" "uid-b")))
    ;; 与状态库内部顺序逐项相同（没有重排、没有丢项）
    (should (equal (mapcar #'car (seshat-state-entries))
                   (mapcar #'car (plist-get seshat-state--state :uids))))
    ;; 条目就是状态库里的条目（引用，不深拷贝）
    (should (equal (cdr (assoc "uid-a" (seshat-state-entries)))
                   (seshat-state-get "uid-a")))
    (should (= 3 (length (seshat-state-entries t))))))

(ert-deftest seshat-state-test-entries-excludes-tombstones ()
  "默认过滤墓碑：`:deleted-at' 非 nil 的条目不出现；include-inactive 时出现。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-live" (list :root "notes" :path "live.org"))
    (seshat-state-set "uid-dead" (list :root "notes" :path "dead.org"))
    (seshat-state-mark-deleted "uid-dead")
    (should (equal (mapcar #'car (seshat-state-entries)) '("uid-live")))
    (should (equal (mapcar #'car (seshat-state-entries t))
                   '("uid-live" "uid-dead")))
    (should (numberp (plist-get (cdr (assoc "uid-dead" (seshat-state-entries t)))
                                :deleted-at)))))

(ert-deftest seshat-state-test-entries-excludes-orphans ()
  "默认过滤孤儿：带 `:orphan' 的条目不出现；include-inactive 时出现。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-b" (list :root "notes" :path "p.org"))
    (seshat-state-set "uid-a" (list :root "notes" :path "old.org"))
    ;; remap 冲突：uid-b 被挤出 → :path 置 nil + :orphan t
    (seshat-state-remap "uid-a" "notes" "p.org")
    (should (eq t (plist-get (seshat-state-get "uid-b") :orphan)))
    (should (equal (mapcar #'car (seshat-state-entries)) '("uid-a")))
    (should (equal (mapcar #'car (seshat-state-entries t)) '("uid-b" "uid-a")))))

(ert-deftest seshat-state-test-entries-excludes-pathless ()
  "默认过滤 `:path' 为 nil 的条目（如只记了 base-blob 的条目）。"
  (seshat-state-test--with-temp-state
    (seshat-state-set-base-blob "uid-blob" "sha1:1" 10 1761234567)
    (seshat-state-set "uid-live" (list :root "notes" :path "live.org"))
    (should-not (plist-get (seshat-state-get "uid-blob") :path))
    (should (equal (mapcar #'car (seshat-state-entries)) '("uid-live")))
    (should (equal (mapcar #'car (seshat-state-entries t))
                   '("uid-blob" "uid-live")))))

(ert-deftest seshat-state-test-entries-include-inactive-returns-all ()
  "include-inactive 非 nil 时墓碑 / 孤儿 / 无路径三类都出现，且顺序仍是 `:uids' 顺序。"
  (seshat-state-test--with-temp-state
    (seshat-state-set "uid-live" (list :root "notes" :path "live.org"))
    (seshat-state-set "uid-dead" (list :root "notes" :path "dead.org"))
    (seshat-state-mark-deleted "uid-dead")
    (seshat-state-set "uid-orphan" (list :root "notes" :path "orphan.org"))
    (seshat-state-set "uid-taker" (list :root "notes" :path "taken.org"))
    (seshat-state-remap "uid-taker" "notes" "orphan.org")  ; 挤掉 uid-orphan
    (seshat-state-set-base-blob "uid-blob" "sha1:b" 1 2)   ; 无 :path
    (should (equal (mapcar #'car (seshat-state-entries))
                   '("uid-live" "uid-taker")))
    (should (equal (mapcar #'car (seshat-state-entries t))
                   '("uid-live" "uid-dead" "uid-orphan" "uid-taker" "uid-blob")))
    (should (equal (mapcar #'car (seshat-state-entries t))
                   (mapcar #'car (plist-get seshat-state--state :uids))))))

(ert-deftest seshat-state-test-entries-empty-state-is-nil ()
  "空状态库（无任何条目）返回 nil 而不是报错。"
  (seshat-state-test--with-temp-state
    (should-not (seshat-state-entries))
    (should-not (seshat-state-entries t))
    (should-not (file-exists-p seshat-state-file))))

;;; 上次运行记录（:runtime）

(ert-deftest seshat-state-test-runtime-old-file-is-nil ()
  "旧文件（无 `:runtime' 键）加载后 runtime 为 nil，且**不**判为损坏、不告警。"
  (seshat-state-test--with-temp-state
    (seshat-state-test--write-state-file
     (list :version 1 :cursor 5 :roots nil
           :uids (list (cons "uid-a" (list :root "notes" :path "a.org")))
           :paths (list (cons (cons "notes" "a.org") "uid-a"))))
    (let* ((captured (seshat-state-test--warnings #'seshat-state-load)))
      (should-not (cdr captured))                     ; 无告警
      (should-not seshat-state--load-was-corrupt)
      (should-not (seshat-state-runtime))
      (should (= 5 (seshat-state-cursor)))
      (should (equal (seshat-state-uid-for-path "notes" "a.org") "uid-a"))
      ;; 文件既没被改名，也没被当成坏文件备份
      (should (file-exists-p seshat-state-file))
      (should-not (file-exists-p (concat seshat-state-file ".bak"))))))

(ert-deftest seshat-state-test-runtime-save-load-roundtrip ()
  "set-runtime → save → 丢弃内存状态 → load 后记录往返一致（成功与失败两条路径）。"
  (seshat-state-test--with-temp-state
    (should-not (seshat-state-runtime))
    (let ((success (list :last-sync-at 1761234567
                         :last-sync-result 'success
                         :last-sync-error nil)))
      (should (equal (seshat-state-set-runtime success) success))
      (should (equal (seshat-state-runtime) success))
      (seshat-state-save)
      (setq seshat-state--state nil)          ; 强制重新从磁盘读
      (seshat-state-load)
      (should (equal (seshat-state-runtime) success))
      (should (= 1761234567 (plist-get (seshat-state-runtime) :last-sync-at))))
    (let ((failed (list :last-sync-at 1761234600
                        :last-sync-result 'failed
                        :last-sync-error "HTTP 500")))
      (should (equal (seshat-state-set-runtime failed) failed))
      (seshat-state-save)
      (setq seshat-state--state nil)
      (seshat-state-load)
      (should (equal (seshat-state-runtime) failed))
      (should (equal (plist-get (seshat-state-runtime) :last-sync-error)
                     "HTTP 500")))))

(ert-deftest seshat-state-test-set-runtime-rejects-non-plist ()
  "非法入参（字符串 / 数字 / 非 keyword 开头的 list）→ error；nil 清空记录。"
  (seshat-state-test--with-temp-state
    (should-error (seshat-state-set-runtime "garbage"))
    (should-error (seshat-state-set-runtime 42))
    (should-error (seshat-state-set-runtime '("not-a-keyword" 1)))
    (should-error (seshat-state-set-runtime (vector :a 1)))
    ;; 合法形状不报错：字段名不做校验（将来会加字段）
    (should (equal (seshat-state-set-runtime (list :future-field 1))
                   (list :future-field 1)))
    ;; 抛错不改变既有记录
    (let ((runtime (list :last-sync-at 1 :last-sync-result 'success)))
      (seshat-state-set-runtime runtime)
      (should-error (seshat-state-set-runtime "garbage"))
      (should (equal (seshat-state-runtime) runtime)))
    ;; nil 表示清空
    (should-not (seshat-state-set-runtime nil))
    (should-not (seshat-state-runtime))))

(ert-deftest seshat-state-test-normalize-runtime-tolerance ()
  "`--normalize' 的 `:runtime' 归一化：非 plist 置 nil，合法 plist 原样保留。"
  (should-not (plist-get (seshat-state--normalize (list :runtime "garbage"))
                         :runtime))
  (should-not (plist-get (seshat-state--normalize (list :runtime 42)) :runtime))
  (should-not (plist-get (seshat-state--normalize (list :runtime '("k" 1)))
                         :runtime))
  (should-not (plist-get (seshat-state--normalize (list :runtime (vector :a 1)))
                         :runtime))
  ;; 合法 plist 原样保留（不清洗字段、不丢未知字段）
  (let ((runtime (list :last-sync-at 5 :future-field 'x)))
    (should (equal (plist-get (seshat-state--normalize (list :runtime runtime))
                              :runtime)
                   runtime)))
  ;; 缺键时补 nil（向后兼容）：键存在但值为 nil
  (should (plist-member (seshat-state--normalize (list :version 1)) :runtime))
  (should-not (plist-get (seshat-state--normalize (list :version 1)) :runtime)))

(ert-deftest seshat-state-test-version-unchanged-by-runtime ()
  "新增 `:runtime' 不构成格式版本升级：常量与落盘 `:version' 都仍为 1。"
  (seshat-state-test--with-temp-state
    (should (= seshat-state-version 1))
    (should (= (plist-get (seshat-state--ensure) :version) 1))
    (seshat-state-set-runtime (list :last-sync-at 1 :last-sync-result 'success))
    (should (= (plist-get (seshat-state--ensure) :version) 1))
    (seshat-state-save)
    (should (= (plist-get (seshat-state--ensure) :version) 1))
    (let ((contents (seshat-state-test--file-contents seshat-state-file)))
      (should (= (plist-get (car (read-from-string contents)) :version) 1))
      (should (equal (plist-get (car (read-from-string contents)) :runtime)
                     '(:last-sync-at 1 :last-sync-result success))))
    (setq seshat-state--state nil)
    (seshat-state-load)
    (should (= (plist-get (seshat-state--ensure) :version) 1))
    (should (= seshat-state-version 1))))

(provide 'seshat-state-test)

;;; seshat-state-test.el ends here
