;;; seshat-sync-cmd-test.el --- ERT tests for seshat-sync-cmd  -*- lexical-binding: t; -*-

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

;; `seshat-sync-cmd' 的 M8-B T4b 测试：入口重接线（`seshat-sync-now' 的
;; `pull → 改名检测 → push → 状态' 编排、单步失败不中断）与 status 修复
;; （`seshat-sync-status' 用状态库登记的 uid 而不是相对路径调
;; `seshat-rest-get-progress'）。
;;
;; 全部用例**零网络、零引擎**：引擎的四个入口（`seshat-sync-pull' /
;; `-detect-renames' / `-push'、`seshat-rest-get-progress'）一律用 `cl-letf'
;; 换成记录调用的桩，因此断言的是**编排**本身——顺序、隔离、兼容入口的转发
;; 目标，而不是引擎内部行为（那是 `seshat-sync-test' 的职责）。
;;
;; 状态库绑到临时目录里的 "sync-state.eld"，绝不写用户的
;; `~/.local/share/seshat/'。
;;
;; M8-B T4d 追加两个用户可用性缺口：
;; 1. 未配置 `seshat-sync-roots' 时 `seshat-sync-now' 不再空转后打印「拉取完成
;;    （0 批 / 0 个事件）」这类误导摘要，而是只调 pull 并返回 `(unconfigured)'；
;; 2. 新增 `seshat-sync-reset-roots'，让用户改过的 `seshat-sync-roots' 能覆盖
;;    状态库里的旧根映射（`seshat-sync--ensure-roots' 只在根映射为空时读配置）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-state)
(require 'seshat-sync-cmd)

;;; 测试辅助

(defvar seshat-sync-cmd-test--base nil
  "当前用例的临时根目录（带结尾斜杠）.")

(defun seshat-sync-cmd-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根，那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-sync-cmd-test-" t))))

(defmacro seshat-sync-cmd-test--with-env (&rest body)
  "在临时状态文件 + 临时笔记目录的环境下执行 BODY.
BODY 期间 `seshat-state-file' 指向临时根目录里的 \"sync-state.eld\"，
`seshat-state--state' 为 nil（空状态起步），`seshat-sync-local-dir' 指向
临时根目录下的 \"notes/\"（由 `seshat-sync-cmd-test--notes-dir' 暴露），
临时根目录见 `seshat-sync-cmd-test--base' / `seshat-sync-cmd-test--notes-dir'。
结束后递归删除临时目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-sync-cmd-test--base (seshat-sync-cmd-test--make-temp-dir))
          (seshat-sync-cmd-test--notes-dir
           (file-name-as-directory
            (expand-file-name "notes" seshat-sync-cmd-test--base)))
          (seshat-state-file (expand-file-name "sync-state.eld"
                                               seshat-sync-cmd-test--base))
          (seshat-state--state nil)
          (seshat-sync-local-dir seshat-sync-cmd-test--notes-dir))
     (unwind-protect
         (progn (make-directory seshat-sync-cmd-test--notes-dir t)
                ,@body)
       (ignore-errors (delete-directory seshat-sync-cmd-test--base t)))))

(defvar seshat-sync-cmd-test--notes-dir nil
  "当前用例的本地笔记目录（带结尾斜杠），由 `seshat-sync-cmd-test--with-env' 绑定.")

(defvar seshat-sync-cmd-test--calls nil
  "本次用例中被桩的引擎调用记录（**反向**累积的符号列表）.")

(defun seshat-sync-cmd-test--pull-stats (&optional first-sync)
  "构造一个 `seshat-sync-pull' 的统计 plist；FIRST-SYNC 非 nil 表示首同步。
真实引擎**总是**带 `:configured'（根映射可用为 t，不可用为 nil），桩必须一样：
`seshat-sync-cmd--report-pull' 与 `seshat-sync-now' 都按该键判定是否短路。"
  (list :configured t
        :first-sync (and first-sync t)
        :index nil
        :changes (list :batches 1 :events 3 :cool 0)))

(defun seshat-sync-cmd-test--unconfigured-pull-stats ()
  "构造 `seshat-sync-pull' 在根映射不可用时的返回值（`:configured' 为 nil）."
  (list :configured nil :first-sync nil :index nil :changes nil))

(defun seshat-sync-cmd-test--rename-stats ()
  "构造一个 `seshat-sync-detect-renames' 的统计 plist."
  (list :scanned-roots 1 :dirty-marked 1 :renamed 1 :conflict 0
        :skipped 0 :failed 0 :vanished 0 :appeared 0))

(defun seshat-sync-cmd-test--push-stats ()
  "构造一个 `seshat-sync-push' 的统计 plist."
  (list :pushed 2 :conflicted 0 :skipped 0 :failed 0))

(defun seshat-sync-cmd-test--write-note (name &optional content)
  "在本地笔记目录下写入 NAME，内容为 CONTENT（缺省任意一行），返回绝对路径。"
  (let ((file (expand-file-name name seshat-sync-cmd-test--notes-dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert (or content "note\n")))
    file))

(defmacro seshat-sync-cmd-test--with-engine-stubs (&rest body)
  "把引擎的四个入口换成「记录调用 + 返回固定统计」的桩后执行 BODY.
桩的返回值：
- `seshat-sync-pull' → `seshat-sync-cmd-test--pull-stats'（带 `:configured t'，
  与真实引擎一致）；
- `seshat-sync-detect-renames' → `seshat-sync-cmd-test--rename-stats'；
- `seshat-sync-push' → `seshat-sync-cmd-test--push-stats'；
- `seshat-sync-status' → 0（有进度的文档数）。

桩的行为可用 body 内的 `cl-letf' 再覆盖：这里只是方便「全成功」这一最常见
场景，需要某一步抛错时在 body 里重新绑定对应符号。"
  (declare (indent 0) (debug t))
  `(let ((seshat-sync-cmd-test--calls nil))
     (cl-letf (((symbol-function 'seshat-sync-pull)
                (lambda ()
                  (push 'pull seshat-sync-cmd-test--calls)
                  (seshat-sync-cmd-test--pull-stats)))
               ((symbol-function 'seshat-sync-detect-renames)
                (lambda ()
                  (push 'detect-renames seshat-sync-cmd-test--calls)
                  (seshat-sync-cmd-test--rename-stats)))
               ((symbol-function 'seshat-sync-push)
                (lambda ()
                  (push 'push seshat-sync-cmd-test--calls)
                  (seshat-sync-cmd-test--push-stats)))
               ((symbol-function 'seshat-sync-status)
                (lambda ()
                  (push 'status seshat-sync-cmd-test--calls)
                  0)))
       ,@body)))

(defun seshat-sync-cmd-test--call-order ()
  "按发生顺序返回本次用例被桩的引擎调用符号列表。"
  (reverse seshat-sync-cmd-test--calls))

;;; 编排顺序（T4b 核心不变量）

(ert-deftest seshat-sync-cmd-test-now-orchestration-order ()
  "`seshat-sync-now' 的编排严格是 pull → 改名检测 → push → 状态。
顺序不可调换：rename 产生的 dirty 与 uid 路径变更必须先落 state，push 才能
按新路径推送。"
  (seshat-sync-cmd-test--with-engine-stubs
    (seshat-sync-now)
    (should (equal (seshat-sync-cmd-test--call-order)
                   '(pull detect-renames push status)))))

(ert-deftest seshat-sync-cmd-test-now-pull-error-does-not-abort ()
  "pull 抛错时后续三步仍被调用（既有的单步异常隔离语义保持）。"
  (seshat-sync-cmd-test--with-engine-stubs
    (cl-letf (((symbol-function 'seshat-sync-pull)
               (lambda ()
                 (push 'pull seshat-sync-cmd-test--calls)
                 (error "传输层不可用"))))
      (let ((result (seshat-sync-now)))
        (should (equal (seshat-sync-cmd-test--call-order)
                       '(pull detect-renames push status)))
        (should (eq (nth 0 result) 'error))
        (should (equal (plist-get (nth 1 result) :renamed) 1))
        (should (equal (plist-get (nth 2 result) :pushed) 2))))))

(ert-deftest seshat-sync-cmd-test-now-status-error-keeps-sync-result ()
  "status 抛错只影响进度展示：此时 push 已完成，其统计原样返回。"
  (seshat-sync-cmd-test--with-engine-stubs
    (cl-letf (((symbol-function 'seshat-sync-status)
               (lambda ()
                 (push 'status seshat-sync-cmd-test--calls)
                 (error "进度服务不可用"))))
      (let ((result (seshat-sync-now)))
        ;; push 在 status 之前完成：调用记录里 push 必须已出现且早于 status。
        (should (equal (seshat-sync-cmd-test--call-order)
                       '(pull detect-renames push status)))
        (should (equal (plist-get (nth 2 result) :pushed) 2))
        (should (eq (nth 3 result) 'error))))))

;;; 兼容入口

(ert-deftest seshat-sync-cmd-test-pull-all-delegates-to-engine ()
  "`seshat-sync-pull-all' 仍是命令，且函数体只调 `seshat-sync-pull'。"
  (seshat-sync-cmd-test--with-engine-stubs
    (should (commandp 'seshat-sync-pull-all))
    (should (equal (func-arity 'seshat-sync-pull-all) '(0 . 0)))
    (let ((stats (seshat-sync-pull-all)))
      (should (equal (seshat-sync-cmd-test--call-order) '(pull)))
      (should (equal (plist-get stats :changes)
                     '(:batches 1 :events 3 :cool 0))))))

(ert-deftest seshat-sync-cmd-test-push-all-detects-renames-then-pushes ()
  "`seshat-sync-push-all' 仍是命令，且依次调改名检测与 push（顺序固定）。"
  (seshat-sync-cmd-test--with-engine-stubs
    (should (commandp 'seshat-sync-push-all))
    (should (equal (func-arity 'seshat-sync-push-all) '(0 . 0)))
    (let ((stats (seshat-sync-push-all)))
      (should (equal (seshat-sync-cmd-test--call-order)
                     '(detect-renames push)))
      (should (equal (plist-get stats :pushed) 2)))))

;;; status 的 uid 修复

(ert-deftest seshat-sync-cmd-test-status-uses-uid-not-path ()
  "`seshat-sync-status' 用状态库登记的 uid 调 `seshat-rest-get-progress'。
修复前传的是根内相对路径（\"a.org\"），服务端只会 400/404。"
  (seshat-sync-cmd-test--with-env
    (seshat-state-set-roots
     (list (list "notes" (directory-file-name seshat-sync-cmd-test--notes-dir)
                 "mirror")))
    (seshat-state-remap "uid-a" "notes" "a.org")
    (seshat-sync-cmd-test--write-note "a.org")
    (let (received)
      (cl-letf (((symbol-function 'seshat-rest-get-progress)
                 (lambda (uid)
                   (push uid received)
                   '((position . "p12") (updated_at . "2026-10-18T09:00:00Z")))))
        (should (equal 1 (seshat-sync-status)))
        (should (equal received '("uid-a")))
        (should-not (member "a.org" received))))))

(ert-deftest seshat-sync-cmd-test-status-skips-unregistered-file ()
  "未登记 uid 的本地文件被跳过，不发起 `seshat-rest-get-progress' 请求。"
  (seshat-sync-cmd-test--with-env
    (seshat-state-set-roots
     (list (list "notes" (directory-file-name seshat-sync-cmd-test--notes-dir)
                 "mirror")))
    (seshat-sync-cmd-test--write-note "unregistered.org")
    (let (received)
      (cl-letf (((symbol-function 'seshat-rest-get-progress)
                 (lambda (uid) (push uid received) nil)))
        (should (equal 0 (seshat-sync-status)))
        (should-not received)))))

;;; 死代码已删

(ert-deftest seshat-sync-cmd-test-webdav-xml-helpers-removed ()
  "WebDAV 专用的 XML 解析辅助已随入口重接线删除（锁定不再复活）。"
  (should-not (fboundp 'seshat-sync-cmd--extract-hrefs))
  (should-not (fboundp 'seshat-sync-cmd--href-relative)))

(defmacro seshat-sync-cmd-test--collect-messages (&rest body)
  "在 BODY 期间把 `message' 的调用收集成字符串列表（按发生顺序）并返回。
每条消息已用 `format-message' 展开（message 的首参可能是 `concat' 拼出的字符串）。
不真正输出到 echo area，避免干扰 ERT 的进度行。"
  (declare (indent 0) (debug t))
  `(let ((collected nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (if (stringp fmt)
                            (apply #'format-message fmt args)
                          (format "%s" fmt))
                        collected)
                  nil)))
       ,@body)
     (nreverse collected)))

;;; 未配置根映射：不空转、不误导（T4d 缺口 1）

(ert-deftest seshat-sync-cmd-test-report-pull-unconfigured-message ()
  "pull 返回 `:configured nil' 时汇报「未配置」，不再谎称「拉取完成」。"
  (let* ((stats (seshat-sync-cmd-test--unconfigured-pull-stats))
         (messages (seshat-sync-cmd-test--collect-messages
                     (should (eq stats (seshat-sync-cmd--report-pull stats))))))
    (should (cl-some (lambda (m) (string-match-p "未配置" m)) messages))
    (should-not (cl-some (lambda (m) (string-match-p "拉取完成" m)) messages))
    (should-not (cl-some (lambda (m) (string-match-p "首同步完成" m)) messages))))

(ert-deftest seshat-sync-cmd-test-now-unconfigured-skips-rest ()
  "pull 返回 `:configured nil' 时 `seshat-sync-now' 只调 pull，返回 `(unconfigured)'。
改名检测 / 推送 / 状态同步都跳过：根映射为空时它们只能在空集上空转，状态同步
也没有可用 uid；此时再打印「同步完成」摘要会误导用户。"
  (seshat-sync-cmd-test--with-engine-stubs
    (cl-letf (((symbol-function 'seshat-sync-pull)
               (lambda ()
                 (push 'pull seshat-sync-cmd-test--calls)
                 (seshat-sync-cmd-test--unconfigured-pull-stats))))
      (let (result messages)
        (setq messages
              (seshat-sync-cmd-test--collect-messages
                (setq result (seshat-sync-now))))
        (should (equal result '(unconfigured)))
        (should (equal (seshat-sync-cmd-test--call-order) '(pull)))
        (should (cl-some (lambda (m) (string-match-p "跳过" m)) messages))
        (should-not (cl-some (lambda (m) (string-match-p "同步完成" m)) messages))))))

(ert-deftest seshat-sync-cmd-test-now-configured-keeps-orchestration ()
  "正常配置（`:configured t'）下编排仍是 pull → 改名检测 → push → 状态（回归）。
本轮改动只在 `:configured' 为 nil 时短路，配置正常时行为必须完全不变。"
  (seshat-sync-cmd-test--with-engine-stubs
    (let (result messages)
      (setq messages (seshat-sync-cmd-test--collect-messages
                       (setq result (seshat-sync-now))))
      (should (equal (seshat-sync-cmd-test--call-order)
                     '(pull detect-renames push status)))
      (should (= 4 (length result)))
      (should (equal (plist-get (nth 0 result) :configured) t))
      (should (equal (plist-get (nth 2 result) :pushed) 2))
      (should (cl-some (lambda (m) (string-match-p "拉取完成" m)) messages))
      (should (cl-some (lambda (m) (string-match-p "同步完成" m)) messages)))))

;;; 改配置后重建根映射（T4d 缺口 2）

(ert-deftest seshat-sync-cmd-test-reset-roots-rebuilds-from-config ()
  "`seshat-sync-reset-roots' 清掉状态库里的旧映射并按 `seshat-sync-roots' 重建。
`seshat-sync--ensure-roots' 只在根映射为空时读配置，所以旧映射会让用户改过的
`seshat-sync-roots' 永远不生效——本命令是让新配置落地的入口。"
  (seshat-sync-cmd-test--with-env
    ;; 上一次配置留下的旧映射（先落盘，模拟真实状态库）
    (seshat-state-set-roots (list (list "old" "/tmp/seshat-old-root" "mirror")))
    (seshat-state-save)
    (let* ((expected (list (list "notes"
                                 (directory-file-name
                                  seshat-sync-cmd-test--notes-dir)
                                 "mirror")))
           (seshat-sync-roots expected)
           (save-count 0)
           (real-save (symbol-function 'seshat-state-save)))
      (cl-letf (((symbol-function 'seshat-state-save)
                 (lambda ()
                   (cl-incf save-count)
                   (funcall real-save))))
        (should (equal expected (seshat-sync-reset-roots))))
      ;; 置空 + 重建各落盘一次
      (should (>= save-count 2))
      ;; 内存状态：旧映射没了，新映射是配置里的那一条
      (should (equal (seshat-state-roots) expected))
      (should-not (assoc "old" (seshat-state-roots)))
      ;; 落盘状态：从磁盘重读仍是新映射（清空被持久化了，不会被旧值复活）
      (setq seshat-state--state nil)
      (should (equal (seshat-state-roots) expected)))))

(ert-deftest seshat-sync-cmd-test-reset-roots-unconfigured-clears-and-returns-nil ()
  "`seshat-sync-roots' 为空时：清空旧映射、发一次 warning、返回 nil、不抛错。"
  (seshat-sync-cmd-test--with-env
    (seshat-state-set-roots (list (list "old" "/tmp/seshat-old-root" "mirror")))
    (seshat-state-save)
    (let ((seshat-sync-roots nil)
          (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest args)
                   (push args warnings)
                   nil)))
        (should-not (seshat-sync-reset-roots)))
      (should (= 1 (length warnings)))
      (should-not (seshat-state-roots)))))

(ert-deftest seshat-sync-cmd-test-reset-roots-is-a-command ()
  "`seshat-sync-reset-roots' 是可直接 `M-x' 调用的命令（无参数）。"
  (should (commandp 'seshat-sync-reset-roots))
  (should (equal (func-arity 'seshat-sync-reset-roots) '(0 . 0)))
  (should (interactive-form 'seshat-sync-reset-roots)))

(provide 'seshat-sync-cmd-test)
;;; seshat-sync-cmd-test.el ends here
