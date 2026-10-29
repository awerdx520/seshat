;;; seshat-status-test.el --- ERT tests for seshat-status  -*- lexical-binding: t; -*-

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

;; `seshat-status' 的 ERT 测试套件，覆盖四组语义：
;;
;; 1. **汇总口径**：书库总数只数 ondemand 根、已下载要真的存在文件、脏 uid
;;    与批注队列各自独立计数；「从未同步」与「状态库损坏」是两个不同分支。
;; 2. **一行文案**：段落按有无省略、相对时间四档、corrupt 置顶带 ⚠、
;;    never-synced 提示先同步。
;; 3. **启动挂载**：`seshat-status-startup-notify' 为 nil 时什么都不做；
;;    否则只注册 `run-at-time' 延迟定时器，绝不同步计算。
;; 4. **零网络**：把 `seshat-rest--request' 桩成 error，`summary' /
;;    `notify' / 详情 buffer 三者都必须照常工作。
;;
;; 隔离纪律：状态库文件、批注队列文件、书库根目录全部落在 `/tmp' 下的临时
;; 目录里（`seshat-state-file' / `seshat-reader-annotation-queue-file' 绑定
;; 到临时路径，`seshat-state--state' 绑为 nil 从空状态起步），结束递归删除；
;; 绝不读写用户真实的 `~/.local/share/seshat/'。日志 buffer 与详情 buffer
;; 每个用例前后都杀掉，用例之间零残留。
;;
;; 批注队列模块在加载时会按 `seshat-reader-annotation-queue-auto-sync' 建立
;; 自动同步定时器（默认开）。这里在 require 前把它绑成 nil，避免测试进程里
;; 挂上一个 10 秒后可能发请求的定时器。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-state)
(require 'seshat-log)
(require 'seshat-sync)

;; 队列模块加载时会按 `seshat-reader-annotation-queue-auto-sync'（默认 t）建立
;; 自动同步定时器；测试进程里立刻关掉它，免得留下一个稍后可能发请求的定时器。
;; 不能用 `let' 预绑定 defcustom：lexical-binding 下 `let' 会把它变成词法变量，
;; 随后 `custom-declare-variable' 报「Defining as dynamic an already lexical var」。
(require 'seshat-reader-annotation-queue)
(seshat-reader-annotation-queue-disable-timer)

(require 'seshat-status)

;;; 测试辅助

(defvar seshat-status-test--dir nil
  "当前用例的临时目录（带结尾斜杠），由 `seshat-status-test--with-temp-env' 绑定。")

(defun seshat-status-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根，那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-status-test-" t))))

(defmacro seshat-status-test--with-temp-env (&rest body)
  "在独立的临时状态库 + 临时队列 + 空日志 buffer 中执行 BODY.
BODY 期间 `seshat-state-file' 与 `seshat-reader-annotation-queue-file' 指向
临时目录，`seshat-state--state' 为 nil；`seshat-status-startup-delay' 绑 0。
结束（无论成败）移除启动 hook、杀掉日志/详情 buffer、递归删除临时目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-status-test--dir (seshat-status-test--make-temp-dir))
          (seshat-state-file (expand-file-name "sync-state.eld"
                                               seshat-status-test--dir))
          (seshat-state--state nil)
          (seshat-reader-annotation-queue-file
           (expand-file-name "annotation-queue.eld" seshat-status-test--dir))
          (seshat-status-startup-notify t)
          (seshat-status-startup-delay 0)
          (seshat-log-level 'info)
          (seshat-log-quiet t))
     (when (get-buffer seshat-log--buffer-name)
       (kill-buffer seshat-log--buffer-name))
     (when (get-buffer seshat-status--buffer-name)
       (kill-buffer seshat-status--buffer-name))
     (unwind-protect
         (progn ,@body)
       (seshat-status-uninstall)
       (dolist (name (list seshat-log--buffer-name seshat-status--buffer-name))
         (when (get-buffer name)
           (kill-buffer name)))
       (ignore-errors (delete-directory seshat-status-test--dir t)))))

(defmacro seshat-status-test--capture-messages (&rest body)
  "执行 BODY，返回期间 `message' 收到的文本列表（按时间顺序）.
`message' 被桩替，故不会真的往 echo area / stderr 打印。"
  (declare (indent 0) (debug t))
  `(let ((seshat-status-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        seshat-status-test--messages)
                  nil)))
       ,@body)
     (nreverse seshat-status-test--messages)))

(defvar seshat-status-test--messages nil
  "本轮用例捕获到的 echo area 文本（由 capture 宏绑定）。")

(defun seshat-status-test--touch (root-dir &rest paths)
  "在 ROOT-DIR 下创建 PATHS 对应的文件（父目录自动创建）."
  (make-directory root-dir t)
  (dolist (path paths)
    (let ((file (expand-file-name path root-dir)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "pdf")))))

(defun seshat-status-test--write-queue (count)
  "把 COUNT 条假批注写入当前用例的批注队列文件."
  (with-temp-file seshat-reader-annotation-queue-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 (cl-loop for i from 1 to count
                      collect (list :action 'create :uuid (format "uuid-%d" i)))
             (current-buffer)))))

(defun seshat-status-test--setup-library ()
  "在当前临时目录里铺一个「3 本 ondemand 书 + 1 个 mirror 根」的状态库.
返回书库根目录。其中 a.pdf / b.pdf 真实存在、c.pdf 不存在；uid-a 标脏；
运行记录为「2 小时前失败：超时」。"
  (let* ((root-dir (expand-file-name "library/" seshat-status-test--dir))
         (mirror-dir (expand-file-name "mirror/" seshat-status-test--dir)))
    (seshat-state-set-roots (list (list "lib" root-dir "ondemand")
                                  (list "mirror" mirror-dir "mirror")))
    (seshat-state-remap "uid-a" "lib" "a.pdf")
    (seshat-state-remap "uid-b" "lib" "b.pdf")
    (seshat-state-remap "uid-c" "lib" "c.pdf")
    (seshat-state-remap "uid-m" "mirror" "m.pdf")
    (seshat-state-mark-dirty "uid-a")
    (seshat-state-set-runtime (list :last-sync-at (- (float-time) 7200)
                                    :last-sync-result 'failed
                                    :last-sync-error "超时"))
    (seshat-status-test--touch root-dir "a.pdf" "b.pdf")
    root-dir))

;;; 1. 汇总口径

(ert-deftest seshat-status-test-summary-counts-library-and-sync ()
  "summary 的 N/M/X/Y 与 runtime 各字段来自正确的数据源。"
  (seshat-status-test--with-temp-env
    (seshat-status-test--setup-library)
    (seshat-status-test--write-queue 2)
    (let ((summary (seshat-status-summary)))
      (should (equal 3 (plist-get summary :books)))
      (should (equal 2 (plist-get summary :downloaded)))
      (should (equal 1 (plist-get summary :dirty)))
      (should (equal 2 (plist-get summary :pending-annotations)))
      (should (eq 'failed (plist-get summary :last-sync-result)))
      (should (equal "超时" (plist-get summary :last-sync-error)))
      (should (numberp (plist-get summary :last-sync-at)))
      (should-not (plist-get summary :corrupt))
      (should-not (plist-get summary :never-synced)))))

(ert-deftest seshat-status-test-summary-never-synced ()
  "空状态库 + 无运行记录时 never-synced 为 t、last-sync-at 为 nil。"
  (seshat-status-test--with-temp-env
    (let ((summary (seshat-status-summary)))
      (should (plist-get summary :never-synced))
      (should-not (plist-get summary :last-sync-at))
      (should-not (plist-get summary :last-sync-result))
      (should (equal 0 (plist-get summary :books)))
      (should (equal 0 (plist-get summary :downloaded))))))

(ert-deftest seshat-status-test-summary-corrupt-flag ()
  "`seshat-state--load-was-corrupt' 为 t 时 summary 的 corrupt 为 t。"
  (seshat-status-test--with-temp-env
    (seshat-status-test--setup-library)
    (let ((seshat-state--load-was-corrupt t))
      (should (plist-get (seshat-status-summary) :corrupt)))))

(ert-deftest seshat-status-test-summary-corrupt-and-never-synced-are-distinct ()
  "「损坏」与「从未同步」是两个独立分支：corrupt 时 never-synced 不一定为 t。"
  (seshat-status-test--with-temp-env
    ;; 分支一：库损坏，但根映射与运行记录都在 → corrupt t / never-synced nil
    (seshat-status-test--setup-library)
    (let ((seshat-state--load-was-corrupt t))
      (let ((summary (seshat-status-summary)))
        (should (plist-get summary :corrupt))
        (should-not (plist-get summary :never-synced))))
    ;; 分支二：库未损坏，但既无根映射也无运行记录 → never-synced t / corrupt nil
    (let ((seshat-state--state (seshat-state--empty))
          (seshat-state--load-was-corrupt nil))
      (let ((summary (seshat-status-summary)))
        (should-not (plist-get summary :corrupt))
        (should (plist-get summary :never-synced))))))

(ert-deftest seshat-status-test-summary-pending-annotations-nil-without-module ()
  "批注队列模块未加载时 `:pending-annotations' 为 nil（不是 0），且**不触发加载**.
启动汇总若为「数一下待同步批注」而 `require' 队列模块，就会顺带把它的自动
同步定时器点起来——只读的启动汇总不该改变运行态，故这里只查 `featurep'。

`features' 在 Emacs 32 里是 C 层直接读取的变量（let 绑定它**不影响**
`featurep'），因此这里桩替 `featurep' 本身来模拟「模块未加载」。"
  (seshat-status-test--with-temp-env
    (let ((required nil)
          (real-require (symbol-function 'require))
          (real-featurep (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feature &optional sub)
                   (if (eq feature 'seshat-reader-annotation-queue)
                       nil
                     (funcall real-featurep feature sub))))
                ((symbol-function 'require)
                 (lambda (feature &rest args)
                   (push feature required)
                   (apply real-require feature args))))
        (should-not (plist-get (seshat-status-summary) :pending-annotations))
        ;; 未尝试加载队列模块
        (should-not (memq 'seshat-reader-annotation-queue required))))))

(ert-deftest seshat-status-test-pending-annotations-counts-when-loaded ()
  "队列模块已加载时 `--pending-annotations' 返回队列条数（不是 nil）。"
  (seshat-status-test--with-temp-env
    (seshat-status-test--write-queue 2)
    (should (eq t (featurep 'seshat-reader-annotation-queue)))
    (should (equal 2 (seshat-status--pending-annotations)))))

;;; 2. 一行文案

(ert-deftest seshat-status-test-notify-omits-empty-sections ()
  "全零时省略「书库」与「待同步」段；只有笔记非零时只写笔记。"
  (seshat-status-test--with-temp-env
    (let ((empty (list :books 0 :downloaded 0 :dirty 0 :pending-annotations 0
                       :last-sync-at nil :last-sync-result nil
                       :last-sync-error nil :corrupt nil :never-synced nil)))
      (let ((text (seshat-status--notify-text empty)))
        (should-not (string-match-p "待同步" text))
        (should-not (string-match-p "书库" text))
        (should (string-match-p "\\`Seshat: " text)))
      ;; notify 确实调了 message（唯一允许刷 echo area 的地方）
      (let ((messages (seshat-status-test--capture-messages
                        (seshat-status-notify empty))))
        (should (equal 1 (length messages)))
        (should (equal (seshat-status--notify-text empty) (car messages)))))
    (let* ((only-notes (list :books 0 :downloaded 0 :dirty 2
                             :pending-annotations 0
                             :last-sync-at nil :last-sync-result nil
                             :last-sync-error nil :corrupt nil
                             :never-synced nil))
           (text (seshat-status--notify-text only-notes)))
      (should (string-match-p "待同步 笔记 2" text))
      (should-not (string-match-p "批注" text)))))

(ert-deftest seshat-status-test-notify-relative-time-buckets ()
  "相对时间四档：刚刚 / 5m 前 / 2h 前 / 3d 前，且不依赖外部包。"
  (should (equal "刚刚" (seshat-status--relative-time 5)))
  (should (equal "5m 前" (seshat-status--relative-time 300)))
  (should (equal "2h 前" (seshat-status--relative-time 7200)))
  (should (equal "3d 前" (seshat-status--relative-time 259200)))
  ;; 通过 notify 文案走一遍完整路径（含结果后缀）
  (seshat-status-test--with-temp-env
    (dolist (case '((300 . "5m 前成功") (7200 . "2h 前失败")))
      (let* ((summary (list :books 0 :downloaded 0 :dirty 0
                            :pending-annotations 0
                            :last-sync-at (- (float-time) (car case))
                            :last-sync-result (if (= 300 (car case)) 'success 'failed)
                            :last-sync-error nil :corrupt nil :never-synced nil))
             (text (seshat-status--notify-text summary)))
        (should (string-match-p (regexp-quote (concat "上次同步 " (cdr case)))
                                text))))))

(ert-deftest seshat-status-test-notify-corrupt-first-with-warning-sign ()
  "状态库损坏时 ⚠ 段置顶。"
  (seshat-status-test--with-temp-env
    (let* ((summary (list :books 0 :downloaded 0 :dirty 0
                          :pending-annotations 0
                          :last-sync-at nil :last-sync-result nil
                          :last-sync-error nil :corrupt t :never-synced nil))
           (text (seshat-status--notify-text summary)))
      (should (string-prefix-p "Seshat: ⚠ 状态库异常（已备份为 .bak）" text)))))

(ert-deftest seshat-status-test-notify-never-synced-hint ()
  "从未同步时提示先运行 `seshat-sync-now'，且不重复「尚未同步」段。"
  (seshat-status-test--with-temp-env
    (let* ((summary (list :books 0 :downloaded 0 :dirty 0
                          :pending-annotations 0
                          :last-sync-at nil :last-sync-result nil
                          :last-sync-error nil :corrupt nil :never-synced t))
           (text (seshat-status--notify-text summary)))
      (should (string-match-p "尚未建立索引，运行 M-x seshat-sync-now" text))
      (should-not (string-match-p "上次同步" text)))))

;;; 3. 启动挂载

(ert-deftest seshat-status-test-startup-silent-when-disabled ()
  "`seshat-status-startup-notify' 为 nil 时既不注册定时器也不 message。"
  (seshat-status-test--with-temp-env
    (let ((seshat-status-startup-notify nil)
          (calls nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest args) (push args calls) 'fake-timer)))
        (let ((messages (seshat-status-test--capture-messages
                          (seshat-status-startup))))
          (should-not messages)
          (should-not calls))))))

(ert-deftest seshat-status-test-startup-schedules-delayed-timer ()
  "启用时只注册 `run-at-time' 延迟定时器，延迟值取 defcustom，且不同步执行。"
  (seshat-status-test--with-temp-env
    (let ((seshat-status-startup-notify t)
          (seshat-status-startup-delay 3)
          (calls nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (secs repeat function &rest _)
                   (push (list secs repeat function) calls)
                   'fake-timer))
                ((symbol-function 'message)
                 (lambda (&rest _) (error "启动汇总不得同步 message"))))
        (seshat-status-startup)
        (should (= 1 (length calls)))
        (should (equal 3 (nth 0 (car calls))))
        (should-not (nth 1 (car calls)))
        (should (functionp (nth 2 (car calls))))))))

;;; 4. 详情 buffer 与零网络

(ert-deftest seshat-status-test-status-buffer-sections-and-keys ()
  "详情 buffer 名字、模式、各节标题与 g/L/q 键位齐备。"
  (seshat-status-test--with-temp-env
    (seshat-status-test--setup-library)
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (let ((buffer (seshat-status)))
        (should (equal seshat-status--buffer-name (buffer-name buffer)))
        (with-current-buffer buffer
          (should (derived-mode-p 'special-mode))
          (let ((content (buffer-string)))
            (dolist (section '("书库" "同步" "待同步" "状态库" "日志摘要"))
              (should (string-match-p section content))))
          (should (key-binding (kbd "g")))
          (should (key-binding (kbd "L")))
          (should (key-binding (kbd "q")))
          ;; `g' 的重算路径可跑通（不抛错、内容仍在）
          (seshat-status--refresh)
          (should (string-match-p "书库" (buffer-string))))))))

(ert-deftest seshat-status-test-no-network ()
  "把 `seshat-rest--request' 桩成 error，summary / notify / 详情 buffer 全通过。"
  (seshat-status-test--with-temp-env
    (seshat-status-test--setup-library)
    (cl-letf (((symbol-function 'seshat-rest--request)
               (lambda (&rest _) (error "启动汇总不得发任何请求")))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (let ((summary (seshat-status-summary)))
        (should (equal 3 (plist-get summary :books))))
      (seshat-status-test--capture-messages
        (seshat-status-notify))
      (let ((buffer (seshat-status)))
        (should (buffer-live-p buffer))))))

(provide 'seshat-status-test)

;;; seshat-status-test.el ends here
