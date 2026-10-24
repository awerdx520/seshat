;;; seshat-conflict-test.el --- ERT tests for seshat-conflict  -*- lexical-binding: t; -*-

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

;; `seshat-conflict' 在 M8-B T4a 之后的用例：三方合并的**远端与祖先改走
;; REST**（`seshat-rest-download-file' / `seshat-rest-versions'），HEAD 从
;; 「全局单文件」改为「状态库的 per-uid `:base-blob'（解析失败回退旧文件）」。
;;
;; 两个层次各用各的桩点：
;;
;; - **合并原语**（`seshat-conflict--diff3'）用**真实的** diff3：参数顺序
;;   （GNU diff3 的 `-m MINE OLDER YOURS' 第二个参数才是祖先）正是 T4a 修的
;;   那个 bug，桩掉就测不出来。第 1 例（7 行夹具、本地改第 2 行、远端改第 5
;;   行 → 干净合并）在旧实现（`-m base local remote'）下会红；
;; - **网络**零容忍：涉及 `seshat-rest-*' 的用例或桩 `seshat-transport-request'
;;   （传输层出口，断言 URL / 方法），或桩 `seshat-rest-download-file' /
;;   `seshat-rest-versions'（断言本模块传给它们的 path / root / blob 参数）。
;;   两类桩都不发真实请求。
;;
;; 状态库一律落在临时目录（`seshat-state-file' + `seshat-state--state' 双绑定），
;; 旧 HEAD 文件用临时文件，临时文件目录（`temporary-file-directory'）指向用例
;; 私有子目录，用于断言「合并后无残留」。**绝不碰**用户的
;; `~/.local/share/seshat/' 与 `~/.emacs.d/seshat-head'。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-conflict)

;;; 测试辅助

(defvar seshat-conflict-test--dir nil
  "当前用例的临时目录（带结尾斜杠），由 `--with-env' 绑定。")

(defvar seshat-conflict-test--tmp nil
  "当前用例存放临时文件的目录（带结尾斜杠），用于断言无残留。")

(defun seshat-conflict-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）。
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，本机 `TMPDIR'
可能被设为仓库根（ECA 客户端所为），那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-conflict-test-" t))))

(defmacro seshat-conflict-test--with-env (&rest body)
  "在独立的临时环境里执行 BODY。
期间：`seshat-state-file' 指向临时目录里的 \"sync-state.eld\"、
`seshat-state--state' 为 nil（空状态起步）、
`seshat-conflict-local-head-file' 指向临时目录里的 \"seshat-head\"、
`temporary-file-directory' 指向临时目录下的 \"tmp/\"（`make-temp-file'
只会落在这里）。结束后递归删除临时目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-conflict-test--dir (seshat-conflict-test--make-temp-dir))
          (seshat-conflict-test--tmp
           (file-name-as-directory
            (expand-file-name "tmp/" seshat-conflict-test--dir)))
          (seshat-state-file (expand-file-name "sync-state.eld"
                                               seshat-conflict-test--dir))
          (seshat-state--state nil)
          (seshat-conflict-local-head-file
           (expand-file-name "seshat-head" seshat-conflict-test--dir))
          (temporary-file-directory seshat-conflict-test--tmp))
     (make-directory seshat-conflict-test--tmp t)
     (unwind-protect
         (progn ,@body)
       ;; 合并产生的 UI buffer 一并清掉，避免跨用例串味
       (dolist (buffer (buffer-list))
         (when (string-prefix-p "*seshat-conflict " (buffer-name buffer))
           (ignore-errors (kill-buffer buffer))))
       (ignore-errors (delete-directory seshat-conflict-test--dir t)))))

(defmacro seshat-conflict-test--with-stub (symbol replacement &rest body)
  "在把 SYMBOL 的函数定义临时替换为 REPLACEMENT 的环境下执行 BODY。"
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function ',symbol) ,replacement))
     ,@body))

(defun seshat-conflict-test--write (file content)
  "把 CONTENT 写入 FILE（父目录不存在时递归创建）并返回 FILE。"
  (make-directory (file-name-directory (expand-file-name file)) t)
  (with-temp-file file (insert content))
  file)

(defun seshat-conflict-test--contents (buffer)
  "返回 BUFFER 的名字与全文，形如 (NAME . CONTENT)，便于断言。"
  (cons (buffer-name buffer) (with-current-buffer buffer (buffer-string))))

(defun seshat-conflict-test--residue (dir)
  "返回 DIR 里除 \".\" 与 \"..\" 之外的条目名列表。"
  (cl-remove-if (lambda (name) (member name '("." "..")))
                (directory-files dir)))

(defun seshat-conflict-test--register-root (dir)
  "在状态库里登记唯一根 `notes'（DIR 为其本地目录），返回 DIR。"
  (seshat-state-set-roots (list (list "notes" dir "mirror")))
  dir)

(defun seshat-conflict-test--register-uid (uid path blob)
  "在状态库的根 `notes' 下把 PATH 登记为 UID，并带上 base blob BLOB。"
  (seshat-state-set uid (list :root "notes" :path path
                              :base-blob blob :size 42 :mtime 1760785200))
  uid)

;;; 三方合并：参数顺序回归（真实 diff3）

(ert-deftest seshat-conflict-test-diff3-clean-three-way-fixture ()
  "**关键回归**：7 行夹具、本地改第 2 行、远端改第 5 行 → 干净合并、无冲突标记。
旧实现把形参顺序原样传给 diff3（`-m base local remote'），而 GNU diff3 的
位置语义是 `-m MINE OLDER YOURS'——第二个参数才是共同祖先。顺序颠倒时 diff3
把 base 当「我方」、local 当祖先，两侧各自独立的改动会被误报成冲突，因此本
用例在旧实现下**必然红**。"
  (seshat-conflict-test--with-env
    (let* ((base "l1\nl2\nl3\nl4\nl5\nl6\nl7\n")
           (local "l1\nL2\nl3\nl4\nl5\nl6\nl7\n")
           (remote "l1\nl2\nl3\nl4\nR5\nl6\nl7\n")
           (base-file (seshat-conflict-test--write
                       (expand-file-name "base.tmp" seshat-conflict-test--tmp)
                       base))
           (local-file (seshat-conflict-test--write
                        (expand-file-name "notes/l1.org"
                                          seshat-conflict-test--dir)
                        local))
           (remote-file (seshat-conflict-test--write
                         (expand-file-name "remote.tmp"
                                           seshat-conflict-test--tmp)
                         remote))
           (merged (seshat-conflict--diff3 base-file local-file remote-file)))
      (should (stringp merged))
      (should (equal "l1\nL2\nl3\nl4\nR5\nl6\nl7\n" merged))
      (should-not (seshat-merge-conflicted-p merged))
      (should-not (string-match-p "<<<<<<<" merged))
      (should-not (string-match-p ">>>>>>>" merged)))))

(ert-deftest seshat-conflict-test-diff3-real-conflict-keeps-markers ()
  "同一行被两侧改成不同内容 → 返回带 `<<<<<<<` / `>>>>>>>` 标记的结果。
`diff3' 以退出码 1 退出时标准输出仍是合并结果，必须当成功返回（当作失败会
退化成 nil，调用方会误判为「diff3 不可用」并改走整体降级）。"
  (seshat-conflict-test--with-env
    (let* ((base-file (seshat-conflict-test--write
                       (expand-file-name "base.tmp" seshat-conflict-test--tmp)
                       "a\nb\nc\n"))
           (local-file (seshat-conflict-test--write
                        (expand-file-name "notes/x.org"
                                          seshat-conflict-test--dir)
                        "a\nLOCAL\nc\n"))
           (remote-file (seshat-conflict-test--write
                         (expand-file-name "remote.tmp"
                                           seshat-conflict-test--tmp)
                         "a\nREMOTE\nc\n"))
           (merged (seshat-conflict--diff3 base-file local-file remote-file)))
      (should (stringp merged))
      (should (string-match-p "<<<<<<<" merged))
      (should (string-match-p ">>>>>>>" merged))
      (should (seshat-merge-conflicted-p merged)))))

;;; `--remote-head'：走 `seshat-rest-versions'

(ert-deftest seshat-conflict-test-remote-head-via-versions ()
  "`--remote-head' 经 `seshat-rest-versions' 取 `:head'（不再自己拼 URL）。
桩在传输层：断言方法 `GET'、URL 是 `/api/versions/<逐段编码后的路径>'、返回
响应的 `head' 字段。"
  (let ((captured nil)
        (body "{\"head\": \"deadbeef\"}"))
    (seshat-conflict-test--with-stub
        seshat-transport-request
        (lambda (method url &rest _args)
          (setq captured (cons method url))
          (list :status 200 :headers nil :body body))
      (should (equal "deadbeef"
                     (seshat-conflict--remote-head "journal/2026-10-18.org"))))
    ;; 方法 + 路径（子目录保留 "/"，不被编成 %2F）
    (should (equal "GET" (car captured)))
    (should (string-suffix-p "/api/versions/journal/2026-10-18.org"
                             (cdr captured)))))

(ert-deftest seshat-conflict-test-remote-head-nil-on-non-2xx ()
  "非 2xx（404 未登记 / 401 未认证）与传输层失败（`:status' nil）一律返回 nil。
旧实现用 `seshat-rest--request'，失败会**抛错**；新实现不抛错，调用方
（`--record-head'）据此静默跳过、不写任何 HEAD。"
  (dolist (status (list 404 401 500 nil))
    (seshat-conflict-test--with-stub
        seshat-transport-request
        (lambda (&rest _args) (list :status status :body "{}"))
      (should-not (seshat-conflict--remote-head "a.org")))))

;;; `--merge-three-way'：远端与祖先改走 REST

(ert-deftest seshat-conflict-test-merge-three-way-uses-download-file ()
  "远端内容由 `seshat-rest-download-file' 拉取，且传入解析出的 path 与 root。
`root' 由状态库的根映射按本地路径的最长前缀解析（这里只有 `notes' 一个根）；
祖先与本地/远端内容相同，因此合并结果应等于该内容、且不含冲突标记。"
  (seshat-conflict-test--with-env
    (let* ((notes (seshat-conflict-test--register-root
                   (expand-file-name "notes/" seshat-conflict-test--dir)))
           (local-file (seshat-conflict-test--write
                        (expand-file-name "a.org" notes) "same\ncontent\n"))
           (downloads nil)
           (buffer nil))
      (seshat-conflict-test--with-stub
          seshat-rest-download-file
          (lambda (path target &rest args)
            (push (list path target args) downloads)
            (with-temp-file target (insert "same\ncontent\n"))
            (list :status 200))
        (seshat-conflict-test--with-stub
            seshat-rest-versions
            (lambda (&rest _) (list :status 200 :content "same\ncontent\n"))
          (setq buffer (seshat-conflict--merge-three-way
                        local-file "a.org" "blob-base"))))
      (should (= 1 (length downloads)))
      (should (equal "a.org" (nth 0 (car downloads))))
      ;; `:root' 是关键字参数，值为解析出的根 tag
      (should (equal "notes" (plist-get (nth 2 (car downloads)) :root)))
      (let ((contents (seshat-conflict-test--contents buffer)))
        (should (equal "*seshat-conflict a.org*" (car contents)))
        (should (equal "same\ncontent\n" (cdr contents)))
        (should-not (seshat-merge-conflicted-p (cdr contents)))))))

(ert-deftest seshat-conflict-test-merge-three-way-uses-versions-for-ancestor ()
  "祖先内容由 `seshat-rest-versions' 带 base blob 取（第二个位置参数 → 线缆
`hash='）；三段合并后两侧独立改动都能出现在结果里。"
  (seshat-conflict-test--with-env
    (let* ((notes (seshat-conflict-test--register-root
                   (expand-file-name "notes/" seshat-conflict-test--dir)))
           (local-file (seshat-conflict-test--write
                        (expand-file-name "a.org" notes)
                        "l1\nL2\nl3\nl4\nl5\n"))
           (version-calls nil)
           (buffer nil))
      (seshat-conflict-test--with-stub
          seshat-rest-download-file
          (lambda (_path target &rest _args)
            (with-temp-file target (insert "l1\nl2\nl3\nl4\nR5\n"))
            (list :status 200))
        (seshat-conflict-test--with-stub
            seshat-rest-versions
            (lambda (path &optional blob)
              (push (list path blob) version-calls)
              (list :status 200 :content "l1\nl2\nl3\nl4\nl5\n"))
          (setq buffer (seshat-conflict--merge-three-way
                        local-file "a.org" "blob-base"))))
      (should (equal '(("a.org" "blob-base")) version-calls))
      (let ((contents (cdr (seshat-conflict-test--contents buffer))))
        (should (equal "l1\nL2\nl3\nl4\nR5\n" contents))
        (should-not (seshat-merge-conflicted-p contents))))))

;;; `--head-for' / `--set-head-for'：per-uid base-blob（带兼容回退）

(ert-deftest seshat-conflict-test-head-for-reads-state-base-blob ()
  "uid 可解析时读状态库的 `:base-blob'；绝对路径与根内相对路径两种入参都能
解析（绝对路径按 DIR 最长前缀定根，相对路径按状态库登记反查根）。"
  (seshat-conflict-test--with-env
    (let* ((notes (seshat-conflict-test--register-root
                   (expand-file-name "notes/" seshat-conflict-test--dir)))
           (local-file (expand-file-name "a.org" notes)))
      (seshat-conflict-test--write local-file "a\n")
      (seshat-conflict-test--register-uid "01K8Q3M7D2X9V6T1B8N5C0RDEF"
                                          "a.org" "blob-per-uid")
      ;; 绝对路径
      (should (equal "blob-per-uid" (seshat-conflict--head-for local-file)))
      ;; 根内相对路径
      (should (equal "blob-per-uid" (seshat-conflict--head-for "a.org")))
      ;; `--read-head' 传 path 时走同一路径，不传时只读旧全局文件（此处为空）
      (should (equal "blob-per-uid"
                     (seshat-conflict--read-head local-file)))
      (should-not (seshat-conflict--read-head)))))

(ert-deftest seshat-conflict-test-head-for-falls-back-to-legacy-file ()
  "uid 解析不出（未配置根）时回退旧全局文件 `seshat-conflict-local-head-file'。
升级过渡期用户的状态库里还没有 uid 登记，旧文件里的 HEAD 必须仍然可用。"
  (seshat-conflict-test--with-env
    (seshat-conflict-test--write
     (expand-file-name seshat-conflict-local-head-file) "legacy-head\n")
    ;; 未配置任何根 → 无从解析（绝对路径与相对路径都一样）
    (should (equal "legacy-head"
                   (seshat-conflict--head-for "/nowhere/at/all/a.org")))
    (should (equal "legacy-head" (seshat-conflict--head-for "a.org")))
    ;; 配了根但路径未登记 → 同样回退
    (seshat-conflict-test--register-root
     (expand-file-name "notes/" seshat-conflict-test--dir))
    (should (equal "legacy-head"
                   (seshat-conflict--head-for
                    (expand-file-name "unregistered.org"
                                      (expand-file-name "notes/"
                                                        seshat-conflict-test--dir)))))))

(ert-deftest seshat-conflict-test-set-head-for-writes-state-or-legacy ()
  "uid 可解析时写状态库的 `:base-blob'（并**保留**原有 `:size' / `:mtime'
基线——传 nil 会把基线清空，下一轮本地快照比对就会误标 dirty）；
解析不出时写旧全局文件。非法 blob（nil / 空串）两者都不写。"
  (seshat-conflict-test--with-env
    (let* ((notes (seshat-conflict-test--register-root
                   (expand-file-name "notes/" seshat-conflict-test--dir)))
           (uid "01K8Q3M7D2X9V6T1B8N5C0RDEF")
           (local-file (expand-file-name "a.org" notes)))
      (seshat-conflict-test--write local-file "a\n")
      (seshat-conflict-test--register-uid uid "a.org" "old-blob")
      (should (equal "new-blob"
                     (seshat-conflict--set-head-for local-file "new-blob")))
      (let ((entry (seshat-state-get uid)))
        (should (equal "new-blob" (plist-get entry :base-blob)))
        ;; 基线保留（不是 nil）
        (should (equal 42 (plist-get entry :size)))
        (should (equal 1760785200 (plist-get entry :mtime))))
      ;; 旧全局文件在「可解析」时**不该**被写
      (should-not (file-exists-p
                   (expand-file-name seshat-conflict-local-head-file)))
      ;; 非法 blob：不写状态、不写文件
      (should-not (seshat-conflict--set-head-for local-file ""))
      (should (equal "new-blob" (plist-get (seshat-state-get uid) :base-blob)))
      ;; 解析不出 → 回退旧文件
      (should (equal "legacy-blob"
                     (seshat-conflict--set-head-for "/nowhere/a.org"
                                                    "legacy-blob")))
      (should (equal "legacy-blob\n"
                     (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name seshat-conflict-local-head-file))
                       (buffer-string)))))))

;;; 临时文件与错误路径

(ert-deftest seshat-conflict-test-merge-three-way-leaves-no-temp-files ()
  "合并成功与合并抛错两条路径都不留临时文件（`unwind-protect' 清理）。
远端下载 / 祖先取用失败时必须抛错（让手动入口把原因报给用户），但仍要清理。"
  (seshat-conflict-test--with-env
    (let* ((notes (seshat-conflict-test--register-root
                   (expand-file-name "notes/" seshat-conflict-test--dir)))
           (local-file (seshat-conflict-test--write
                        (expand-file-name "a.org" notes) "a\n"))
           (buffer nil))
      ;; ① 成功路径
      (seshat-conflict-test--with-stub
          seshat-rest-download-file
          (lambda (_path target &rest _args)
            (with-temp-file target (insert "a\n"))
            (list :status 200))
        (setq buffer (seshat-conflict--merge-three-way local-file "a.org" nil)))
      (should buffer)
      (should (equal '() (seshat-conflict-test--residue seshat-conflict-test--tmp)))
      ;; ② 下载非 2xx → 抛错，且临时文件仍被清理
      (seshat-conflict-test--with-stub
          seshat-rest-download-file
          (lambda (&rest _) (list :status 412))
        (should-error (seshat-conflict--merge-three-way local-file "a.org" nil)
                      :type 'error))
      (should (equal '() (seshat-conflict-test--residue seshat-conflict-test--tmp)))
      ;; ③ 祖先取不到（非 2xx）→ 抛错，且临时文件仍被清理
      (seshat-conflict-test--with-stub
          seshat-rest-download-file
          (lambda (_path target &rest _args)
            (with-temp-file target (insert "a\n"))
            (list :status 200))
        (seshat-conflict-test--with-stub
            seshat-rest-versions
            (lambda (&rest _) (list :status 404 :content nil))
          (should-error (seshat-conflict--merge-three-way local-file "a.org" "nope")
                        :type 'error)))
      (should (equal '() (seshat-conflict-test--residue seshat-conflict-test--tmp))))))

(provide 'seshat-conflict-test)
;;; seshat-conflict-test.el ends here
