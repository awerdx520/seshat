;;; seshat-offline-invariant-test.el --- 跨模块不变量 I-NONET / I-OOM  -*- lexical-binding: t; -*-

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

;; M9 T8：**跨模块**不变量收口。前面的测试文件各自守一段链路（数据层 / 视图层 /
;; 封面 / 进度 / 日志 / 启动汇总），本文件把整条离线链路当成一个整体，把两条核心
;; 不变量变成机械断言：
;;
;; - **I-NONET**：书架全链路（打开 / 翻页 / 过滤排序 / 删本地副本 / 批量删 /
;;   打开已下载书）、启动汇总、进度侧车、封面只读路径、日志写入，在「网络层被
;;   钉死」时全部可用。
;; - **I-OOM**：跨模块复核翻页时驻留 image 有界（≤ 页大小）。
;;
;; **为什么桩要钉三层**（`seshat-rest--request' / `seshat-transport-request' /
;; `url-retrieve-synchronously'）：本仓的 HTTP 有两条路径——`seshat-rest' 的
;; 大部分端点是「`seshat-rest--request' 薄包装 → `seshat-transport-request'」，
;; 而 `seshat-rest-list-resources'（书架远端清单的唯一入口）**直连**
;; `seshat-transport-request'，跳过薄包装。只钉一层就会被绕过，所以三层全钉，
;; 且任何一层被调用都抛错——「用例没抛错」本身就是「没触网」的证明。
;;
;; **反向自检**（防止断言空转）：桩抛错只能证明「没抛错」，不能证明「桩真的挡在
;; 必经路径上」。因此另有两例把桩换成「计数 + 假响应」：
;;
;; - I-NONET 侧：`seshat-library-refresh-remote'（`g'）在 error 桩下必须**失败**
;;   （说明它确实要联网），在计数桩下必须让传输层计数 ≥ 1（说明桩有效）。
;; - I-OOM 侧：**不桩** `display-graphic-p'（`emacs --batch' 下为 nil）时，
;;   `seshat-library--make-cover-image' 的调用次数必须为 0——与 T5b-2 的正断言 P
;;   互补：P 说「桩成图形环境时构造数 > 0」，本例说「不桩时构造数为 0」。
;;
;; 隔离纪律：状态库 / 清单缓存 / 进度侧车 / 封面缓存目录 / 批注队列侧车全部绑
;; 到一次性临时目录；封面队列与队列清理一律桩替（真队列会武装 idle 定时器并起
;; `unzip' / `mutool' 子进程）；每例收尾清日志、卸启动汇总、杀书架 buffer。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seshat-state)
(require 'seshat-sync)
(require 'seshat-library)
(require 'seshat-status)
(require 'seshat-reads)
(require 'seshat-covers)
(require 'seshat-log)

;; `RET' 打开书时 `seshat-library-open-at-point' 会 `(require 'seshat-reading nil
;; t)'。这里预声明签名并在顶层预加载：**必须先加载再桩**——若在桩之后才加载，
;; 命令内部的 `require' 会把桩定义覆盖掉（真 `seshat-reading-open' 会去 `find-file'
;; 并因文件不是受支持格式而 `user-error'）。本文件只验证「传进去的是本地路径」，
;; 不验证阅读器怎么渲染（那是 reader 包的测试职责）。
(declare-function seshat-reading-open "seshat-reading" (file))
(require 'seshat-reading nil t)

;;; 测试辅助

(defvar seshat-offline-invariant-test--dir nil
  "当前用例的临时根目录（带结尾斜杠）.")

(defvar seshat-offline-invariant-test--books-dir nil
  "当前用例里 `books' 根对应的本地目录（带结尾斜杠）.")

(defvar seshat-offline-invariant-test--messages nil
  "本次用例中被桩的 `message' 收到的实参列表（反向累积）.")

(defconst seshat-offline-invariant-test--uid-prefix
  "01J8ZKQ2AAAAAAAAAAAAAAAA"
  "构造合法 uid 的前 24 位（字符全部取自 Crockford Base32）.")

(defun seshat-offline-invariant-test--uid (index)
  "返回第 INDEX 本书的合法 uid（26 位 Crockford Base32）.
`seshat-library--uid-valid-p' 要求恰好 26 位且只含 Crockford 字符，因此用固定
前缀 24 位 + 两位十进制序号拼成；INDEX 超过 99 时长度会变、用例应改用更宽的
格式（本文件最多用到 100 本，`%02d' 足够）。"
  (format "%s%02d" seshat-offline-invariant-test--uid-prefix index))

(defun seshat-offline-invariant-test--resources-json ()
  "构造一份 `GET /api/resources' 的最小成功响应体（单条 `books' 根资源）.
字段名与 `seshat-rest--json-plist' 的 kebab 化口径一致（`created_at' →
`:created-at'）；`has_more' 为 JSON false，让 `--remote-entries' 只翻一页。"
  (json-encode
   `((items . [((uid . ,(seshat-offline-invariant-test--uid 0))
                (root . "books")
                (path . "book-00.pdf")
                (kind . "file")
                (blob . "")
                (rev . 1)
                (size . 3)
                (mtime . 100)
                (created_at . 0)
                (updated_at . 0)
                (deleted_at . ""))])
     (has_more . :json-false))))

(defmacro seshat-offline-invariant-test--no-network (&rest body)
  "在「网络三层全被钉死」的前提下执行 BODY.
三层缺一不可：`seshat-rest--request'（REST 薄包装）、`seshat-transport-request'
（传输层，`seshat-rest-list-resources' 直连它）、`url-retrieve-synchronously'
（`url.el' 底层）。任一被调用即抛错，因此用例正常返回就等于「零网络」。"
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'seshat-rest--request)
              (lambda (&rest _)
                (error "I-NONET 违规：调用了 seshat-rest--request")))
             ((symbol-function 'seshat-transport-request)
              (lambda (&rest _)
                (error "I-NONET 违规：调用了 seshat-transport-request")))
             ((symbol-function 'url-retrieve-synchronously)
              (lambda (&rest _)
                (error "I-NONET 违规：调用了 url-retrieve-synchronously"))))
     ,@body))

(defmacro seshat-offline-invariant-test--with-env (&rest body)
  "在隔离环境（临时目录 + 侧车全绑 + 队列桩）里执行 BODY.
隔离清单：`seshat-state-file' / `seshat-library-cache-file' /
`seshat-reads-file' / `seshat-covers-dir' /
`seshat-reader-annotation-queue-file' 全部指向临时目录——漏一个就会写用户的
`~/.local/share/seshat/' 或 `~/.cache/seshat/'。
`seshat-library--pending-feature' 绑到不存在的 feature：批注队列是软依赖，
用例默认走「模块缺失」分支，不去加载整个 reader 包。

桩替的四件事都是**副作用**而不是被测行为：`seshat-covers-queue'（真实现会武装
idle 定时器并起子进程）、`seshat-covers-queue-clear'（同上）、`pop-to-buffer' /
`display-buffer'（批处理无窗口，且不该切 buffer）、`message'（记录 echo area
文案，供断言「有提示」）。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-offline-invariant-test--dir
           (file-name-as-directory (make-temp-file "seshat-offline-inv-" t)))
          (seshat-offline-invariant-test--books-dir
           (expand-file-name "books/" seshat-offline-invariant-test--dir))
          (seshat-offline-invariant-test--messages nil)
          (seshat-state-file
           (expand-file-name "state.eld" seshat-offline-invariant-test--dir))
          (seshat-state--state nil)
          (seshat-state--batch-depth 0)
          (seshat-library-cache-file
           (expand-file-name "library-cache.eld"
                             seshat-offline-invariant-test--dir))
          (seshat-reads-file
           (expand-file-name "reads.eld" seshat-offline-invariant-test--dir))
          (seshat-reads--state nil)
          (seshat-reads--timer nil)
          (seshat-reads--pending nil)
          (seshat-covers-dir
           (expand-file-name "covers/" seshat-offline-invariant-test--dir))
          (seshat-reader-annotation-queue-file
           (expand-file-name "annotation-queue.eld"
                             seshat-offline-invariant-test--dir))
          (seshat-library--pending-feature
           'seshat-offline-invariant-test--no-such-feature)
          (seshat-log-quiet t))
     ;; 侧车路径只用于隔离，本文件不直接读写它：`ignore' 让字节编译器知道
     ;; 这个绑定是「有意的副作用绑定」，避免 14 个用例各报一条 unused 警告。
     (ignore seshat-reader-annotation-queue-file)
     (make-directory seshat-offline-invariant-test--books-dir t)
     (unwind-protect
         (cl-letf (((symbol-function 'message)
                    (lambda (&rest args)
                      (push args seshat-offline-invariant-test--messages)
                      nil))
                   ((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _args) buffer))
                   ((symbol-function 'display-buffer)
                    (lambda (buffer &rest _args) buffer))
                   ((symbol-function 'seshat-covers-queue)
                    (lambda (&rest _args) t))
                   ((symbol-function 'seshat-covers-queue-clear)
                    (lambda () nil)))
           ,@body)
       ;; 清理：先卸启动钩子与日志，再杀两个全局命名的 buffer，最后删临时目录。
       (seshat-status-uninstall)
       (seshat-log-clear)
       (when (timerp seshat-reads--timer)
         (cancel-timer seshat-reads--timer))
       (dolist (name (list seshat-library--buffer-name
                           seshat-status--buffer-name))
         (let ((buffer (get-buffer name)))
           (when buffer (kill-buffer buffer))))
       (delete-directory seshat-offline-invariant-test--dir t))))

(defun seshat-offline-invariant-test--populate (count downloaded)
  "在状态库里登记 COUNT 本书（根 `books'），其中前 DOWNLOADED 本在盘上有文件.
返回登记后的 uid 列表（按登记顺序）。写盘走 `with-temp-file'，只写一个短字符串
——本文件断言的是「文件存在与否」而不是文件内容。
`seshat-state-batch' 把 COUNT 次路径索引重建压成一次（100 本时是 O(n²) 与 O(n)
的差别）。"
  (seshat-state-set-roots
   (list (list "books" seshat-offline-invariant-test--books-dir "ondemand")))
  (let (uids)
    (seshat-state-batch
      (dotimes (i count)
        (let* ((uid (seshat-offline-invariant-test--uid i))
               (rel (format "book-%02d.pdf" i)))
          (when (< i downloaded)
            (let ((file (expand-file-name rel
                                          seshat-offline-invariant-test--books-dir)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file (insert "PDF"))))
          (seshat-state-set uid (list :root "books" :path rel :size 3 :mtime 100))
          (push uid uids))))
    (nreverse uids)))

(defun seshat-offline-invariant-test--library-buffer ()
  "返回书架 buffer；不存在时报错（说明 `seshat-library' 没建 buffer）."
  (or (get-buffer seshat-library--buffer-name)
      (error "书架 buffer 未创建")))

(defun seshat-offline-invariant-test--rows ()
  "返回书架 buffer 里各条目行的 uid（按 buffer 顺序）.
按行首 `seshat-library-uid' 文本属性收集，页脚提示行因此不会被算成条目。"
  (with-current-buffer (seshat-offline-invariant-test--library-buffer)
    (let (uids)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((uid (get-text-property (point) 'seshat-library-uid)))
            (when (stringp uid)
              (push uid uids)))
          (forward-line 1)))
      (nreverse uids))))

(defun seshat-offline-invariant-test--goto (uid)
  "把 point 移到书架 buffer 里 UID 那一行的行首；找不到则报错."
  (with-current-buffer (seshat-offline-invariant-test--library-buffer)
    (unless (seshat-library--goto-uid uid)
      (error "书架里找不到 uid %s 的行" uid))
    (goto-char (line-beginning-position))))

(defmacro seshat-offline-invariant-test--in-library (&rest body)
  "在书架 buffer 内执行 BODY.
书架的 15 个命令读的都是 buffer-local 状态（`--items' / `--filtered' /
`--page' / `--marked'）与 point 上的文本属性，**必须在书架 buffer 里调用**：
在别处调用等于操作一个没有这些状态的空 buffer（命令会报「当前行没有对应的书」
或静默改错 buffer）。"
  (declare (indent 0) (debug t))
  `(with-current-buffer (seshat-offline-invariant-test--library-buffer)
     ,@body))

(defun seshat-offline-invariant-test--set-page-size (size)
  "把书架 buffer 的页大小设为 SIZE 并重算重渲染（分页用例的准备步骤）."
  (with-current-buffer (seshat-offline-invariant-test--library-buffer)
    (setq seshat-library--page-size size)
    (seshat-library--apply-view)
    (seshat-library--render)))

(defun seshat-offline-invariant-test--current-page ()
  "返回书架 buffer 的当前页码."
  (with-current-buffer (seshat-offline-invariant-test--library-buffer)
    seshat-library--page))

(defun seshat-offline-invariant-test--message-texts ()
  "返回本用例记录的 `message' 文案（按发生顺序，已 `format' 成字符串）."
  (mapcar (lambda (args) (apply #'format args))
          (reverse seshat-offline-invariant-test--messages)))

;;; I-NONET：书架全链路（打开 / 翻页 / 过滤排序 / 删本地 / 批量删 / 打开已下载）

(ert-deftest seshat-offline-invariant-test-i-nonet-open-library ()
  "打开书架零网络：5 本已登记书（3 本有本地副本）全部出现在 buffer 里."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 5 3)
    (seshat-offline-invariant-test--no-network
      (let ((buffer (seshat-library)))
        (should (buffer-live-p buffer))
        (should (> (with-current-buffer buffer (buffer-size)) 0))
        (should (= 5 (with-current-buffer buffer
                       (length seshat-library--items))))
        (should (= 5 (length (seshat-offline-invariant-test--rows))))
        (should (= 3
                   (with-current-buffer buffer
                     (cl-count-if (lambda (item)
                                    (eq 'downloaded (plist-get item :state)))
                                  seshat-library--items))))
        (should (= 5 (length (with-current-buffer buffer
                               seshat-library--filtered))))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-paging ()
  "翻页全链路零网络：`n' × 3 + `p' × 2 + `M->' + `M-<'，页码与行数逐页对齐."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 20 0)
    (seshat-offline-invariant-test--no-network
      (let ((seshat-library-page-size 4))
        (seshat-library))
      (seshat-offline-invariant-test--set-page-size 4)
      ;; 20 本 / 每页 4 本 = 5 页；每页行数恰为 4（末页也满）。
      (dotimes (i 3)
        (with-current-buffer (seshat-offline-invariant-test--library-buffer)
          (seshat-library-next-page))
        (should (= (+ 2 i) (seshat-offline-invariant-test--current-page)))
        (should (= 4 (length (seshat-offline-invariant-test--rows)))))
      (dotimes (_ 2)
        (with-current-buffer (seshat-offline-invariant-test--library-buffer)
          (seshat-library-previous-page)))
      (should (= 2 (seshat-offline-invariant-test--current-page)))
      (with-current-buffer (seshat-offline-invariant-test--library-buffer)
        (seshat-library-last-page))
      (should (= 5 (seshat-offline-invariant-test--current-page)))
      (with-current-buffer (seshat-offline-invariant-test--library-buffer)
        (seshat-library-first-page))
      (should (= 1 (seshat-offline-invariant-test--current-page)))
      (should (= 4 (length (seshat-offline-invariant-test--rows)))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-filter-sort ()
  "过滤与排序零网络：关键词 `/`、状态循环 `F'、排序循环 `s' 都只改 buffer 局部状态."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 20 0)
    (seshat-offline-invariant-test--no-network
      (seshat-library)
      ;; `/`：关键词 book-1 命中 book-10..book-19 共 10 本（book-01 不含 "book-1"）
      (seshat-offline-invariant-test--in-library
        (seshat-library-filter-keyword "book-1"))
      (should (= 10 (with-current-buffer (seshat-offline-invariant-test--library-buffer)
                      (length seshat-library--filtered))))
      ;; `F'：状态循环 all → downloaded，全部未下载 ⇒ 过滤后为空（提示行）
      (seshat-offline-invariant-test--in-library
        (seshat-library-filter-state))
      (should (eq 'downloaded
                  (with-current-buffer (seshat-offline-invariant-test--library-buffer)
                    seshat-library--state-filter)))
      (should-not (with-current-buffer (seshat-offline-invariant-test--library-buffer)
                    seshat-library--filtered))
      (should (= 1 (seshat-offline-invariant-test--current-page)))
      ;; 清掉关键词与状态过滤，再走 `s' 排序循环（name → root）
      (seshat-offline-invariant-test--in-library
        (seshat-library-filter-keyword "")
        (seshat-library-filter-state)        ; downloaded → missing
        (seshat-library-filter-state)        ; missing → unregistered
        (seshat-library-filter-state))       ; unregistered → all
      (should (= 20 (with-current-buffer (seshat-offline-invariant-test--library-buffer)
                      (length seshat-library--filtered))))
      (seshat-offline-invariant-test--in-library
        (seshat-library-sort-cycle))
      (should (eq 'root
                  (with-current-buffer (seshat-offline-invariant-test--library-buffer)
                    seshat-library--sort-key)))
      (should (= 20 (length (seshat-offline-invariant-test--rows)))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-delete-local ()
  "`d' 删本地副本零网络：`delete-file' 恰被调用 1 次且参数是本地绝对路径."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 3 2)
    (let (deleted)
      (seshat-offline-invariant-test--no-network
        (cl-letf (((symbol-function 'delete-file)
                   (lambda (file &rest _args)
                     (push file deleted)
                     nil)))
          (seshat-library)
          (seshat-offline-invariant-test--in-library
            (seshat-offline-invariant-test--goto
             (seshat-offline-invariant-test--uid 0))
            (seshat-library-delete-local-at-point))))
      (should (= 1 (length deleted)))
      (should (equal (expand-file-name "book-00.pdf"
                                       seshat-offline-invariant-test--books-dir)
                     (car deleted))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-delete-marked ()
  "`m' + `x' 批量删零网络：只删有本地副本的 2 本，未下载的那本计入跳过."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 3 2)
    (let (deleted)
      (seshat-offline-invariant-test--no-network
        (cl-letf (((symbol-function 'delete-file)
                   (lambda (file &rest _args)
                     (push file deleted)
                     nil)))
          (seshat-library)
          (dolist (index '(0 1 2))
            (seshat-offline-invariant-test--in-library
              (seshat-offline-invariant-test--goto
               (seshat-offline-invariant-test--uid index))
              (seshat-library-toggle-mark)))
          (should (= 3 (with-current-buffer
                           (seshat-offline-invariant-test--library-buffer)
                         (length seshat-library--marked))))
          (seshat-offline-invariant-test--in-library
            (seshat-library-delete-marked))))
      (should (= 2 (length deleted)))
      (should-not (with-current-buffer (seshat-offline-invariant-test--library-buffer)
                    seshat-library--marked))
      (should (cl-some (lambda (text) (string-match-p "跳过 1 个" text))
                       (seshat-offline-invariant-test--message-texts))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-open-downloaded ()
  "`RET' 打开已下载的书零网络：`seshat-reading-open' 被调用 1 次，参数是本地路径."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 3 2)
    (let (opened)
      (seshat-offline-invariant-test--no-network
        (cl-letf (((symbol-function 'seshat-reading-open)
                   (lambda (file) (push file opened) file)))
          (seshat-library)
          (seshat-offline-invariant-test--in-library
            (seshat-offline-invariant-test--goto
             (seshat-offline-invariant-test--uid 1))
            (seshat-library-open-at-point))))
      (should (= 1 (length opened)))
      (should (equal (expand-file-name "book-01.pdf"
                                       seshat-offline-invariant-test--books-dir)
                     (car opened)))
      (should (file-exists-p (car opened))))))

;;; I-NONET：启动汇总 / 进度侧车 / 封面只读路径 / 日志

(ert-deftest seshat-offline-invariant-test-i-nonet-status-summary ()
  "启动汇总零网络：`seshat-status-summary' 计数正确，`notify' 出文案，详情 buffer 有内容."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 5 3)
    (seshat-offline-invariant-test--no-network
      (let ((summary (seshat-status-summary)))
        (should (= 5 (plist-get summary :books)))
        (should (= 3 (plist-get summary :downloaded)))
        (should (integerp (plist-get summary :dirty)))
        (should-not (plist-get summary :corrupt))
        ;; `seshat-status-notify' 是本模块唯一允许 message 的地方
        (let ((text (seshat-status-notify summary)))
          (should (stringp text))
          (should (string-match-p "\\`Seshat: " text)))
        (should (cl-some (lambda (line) (string-match-p "\\`Seshat: " line))
                         (seshat-offline-invariant-test--message-texts))))
      (let ((buffer (seshat-status)))
        (should (buffer-live-p buffer))
        (should (string-match-p "Seshat 状态"
                                (with-current-buffer buffer
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-reads-sidecar ()
  "进度侧车零网络：`record' → `get' → `percent' 自洽，且 percent 按 `:total' 夹紧."
  (seshat-offline-invariant-test--with-env
    (let ((uid (seshat-offline-invariant-test--uid 0)))
      (seshat-offline-invariant-test--no-network
        (let ((entry (seshat-reads-record uid 42 100)))
          (should (equal 42 (plist-get entry :page)))
          (should (equal 100 (plist-get entry :total)))
          (should (equal entry (seshat-reads-get uid)))
          (should (= 42 (seshat-reads-percent entry))))
        ;; 页号超过总页数时夹紧到 100（不返回 >100）
        (let ((entry (seshat-reads-record uid 150 100)))
          (should (= 100 (seshat-reads-percent entry))))
        ;; 总页数未知时不拿 0% 冒充「没有进度」
        (should-not (seshat-reads-percent
                     (seshat-reads-record uid 3 nil)))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-covers-readonly ()
  "封面只读路径零网络：`cached' / `failed-p' 只查目录，**绝不**调 `seshat-covers-extract'."
  (seshat-offline-invariant-test--with-env
    (let* ((uid (seshat-offline-invariant-test--uid 0))
           (failed-uid (seshat-offline-invariant-test--uid 1))
           (cover (expand-file-name (concat uid ".png")
                                    seshat-covers-dir))
           (negative (expand-file-name
                      (concat failed-uid seshat-covers--negative-suffix)
                      seshat-covers-dir)))
      (make-directory seshat-covers-dir t)
      (with-temp-file cover (insert "PNG"))
      (with-temp-file negative (insert ""))
      (seshat-offline-invariant-test--no-network
        (cl-letf (((symbol-function 'seshat-covers-extract)
                   (lambda (&rest _args)
                     (error "I-NONET 违规：只读路径不得生成封面"))))
          (should (equal cover (seshat-covers-cached uid)))
          (should-not (seshat-covers-cached failed-uid))
          (should (seshat-covers-failed-p failed-uid))
          (should-not (seshat-covers-failed-p uid)))))))

(ert-deftest seshat-offline-invariant-test-i-nonet-log ()
  "日志零网络：`seshat-log' 写进 buffer，`seshat-show-log' 复用同一个 buffer."
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--no-network
      (seshat-log 'info "离线不变量 %d" 1)
      (let ((buffer (seshat-show-log)))
        (should (buffer-live-p buffer))
        (should (equal seshat-log--buffer-name (buffer-name buffer)))
        (should (string-match-p "离线不变量 1"
                                (with-current-buffer buffer
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))
        ;; 幂等复用：第二次返回同一个 buffer 对象
        (should (eq buffer (seshat-show-log)))))))

;;; 反向自检：证明桩有效（不是摆设）

(ert-deftest seshat-offline-invariant-test-i-nonet-selfcheck-stub-is-effective ()
  "反向自检：error 桩下 `g' 必须失败；换成计数桩后传输层计数必须 ≥ 1.
两步缺一不可：第一步证明「`g' 确实要联网」（否则 I-NONET 的十个用例都可能只是
没走到网络路径）；第二步证明「桩真的能计数」（否则第一步的失败可能来自别处）。
另断言 `seshat-rest--request' 计数为 0——`seshat-rest-list-resources' 直连传输层，
不走薄包装，这正是 I-NONET 必须钉三层的原因。"
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 3 0)
    (let ((transport-calls 0)
          (rest-calls 0))
      ;; 书架 buffer 必须先建：`g' 读写的都是 buffer-local 状态。
      (seshat-library)
      ;; 第一步：网络桩抛错时 `g' 必须抛错（证明该路径必经网络层）
      (should-error
       (seshat-offline-invariant-test--in-library
         (cl-letf (((symbol-function 'seshat-transport-request)
                    (lambda (&rest _args)
                      (error "I-NONET 违规：调用了 seshat-transport-request"))))
           (seshat-library-refresh-remote)))
       :type 'error)
      ;; 第二步：计数桩下 `g' 成功，且传输层真的被调用
      (seshat-offline-invariant-test--in-library
        (cl-letf (((symbol-function 'seshat-transport-request)
                   (lambda (&rest _args)
                     (setq transport-calls (1+ transport-calls))
                     (list :status 200
                           :headers nil
                           :body (seshat-offline-invariant-test--resources-json))))
                  ((symbol-function 'seshat-rest--request)
                   (lambda (&rest _args)
                     (setq rest-calls (1+ rest-calls))
                     (error "不该走 REST 薄包装"))))
          (seshat-library-refresh-remote)))
      (should (>= transport-calls 1))
      (should (= 0 rest-calls))
      ;; 刷新成功：清单里那本远端书进了书架数据源
      (should (member (seshat-offline-invariant-test--uid 0)
                      (with-current-buffer
                          (seshat-offline-invariant-test--library-buffer)
                        (mapcar (lambda (item) (plist-get item :uid))
                                seshat-library--items)))))))

(ert-deftest seshat-offline-invariant-test-i-oom-selfcheck-no-graphic-stub ()
  "反向自检：**不桩** `display-graphic-p'（批处理为 nil）时构造次数必须为 0.
与 T5b-2 的正断言 P（桩成图形环境后构造数 > 0）互补：若这里构造数不是 0，
说明「构造与显示分层」被破坏（`--make-cover-image' 绕过 `--insert-cover' 的
守卫自己查了图形环境），I-OOM 的驻留上界随之失去意义。"
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 5 5)
    (let ((created 0))
      (seshat-offline-invariant-test--no-network
        (cl-letf (((symbol-function 'seshat-library--make-cover-image)
                   (lambda (uid _file)
                     (setq created (1+ created))
                     (seshat-library--register-cover uid (list 'image uid))))
                  ((symbol-function 'insert-image) (lambda (&rest _args) nil)))
          ;; 前置：批处理下确为非图形环境（否则本例的判据不成立）
          (should-not (display-graphic-p))
          (seshat-library)
          (should (= 0 created))
          ;; 占位分支仍然插了内容：非图形环境是「不构造」，不是「什么都不显示」
          (should (= 5 (length (seshat-offline-invariant-test--rows))))
          (should-not (with-current-buffer
                          (seshat-offline-invariant-test--library-buffer)
                        seshat-library--resident)))))))

;;; I-OOM：跨模块复核（翻页时驻留 image 有界）

(ert-deftest seshat-offline-invariant-test-i-oom-paging-bounded ()
  "I-OOM 跨模块复核：100 本 / 每页 10 本，连续 `n' 翻 10 页，每页驻留 ≤ 10.
收尾 `kill-buffer' 后驻留表为空（`kill-buffer-hook' 释放全部），且守恒式
「flush 次数 == 构造总次数」成立（无泄漏）。"
  (seshat-offline-invariant-test--with-env
    (seshat-offline-invariant-test--populate 100 100)
    (let ((created 0)
          (flushed 0)
          (resident-after-kill 'unset))
      (seshat-offline-invariant-test--no-network
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   (lambda (uid _file)
                     (or (alist-get uid seshat-library--resident nil nil #'equal)
                         (progn
                           (setq created (1+ created))
                           (seshat-library--register-cover
                            uid (list 'image uid))))))
                  ((symbol-function 'image-flush)
                   (lambda (&rest _args)
                     (setq flushed (1+ flushed))
                     nil)))
          (let ((seshat-library-page-size 10))
            (seshat-library))
          (seshat-offline-invariant-test--set-page-size 10)
          ;; 正断言：桩成图形环境后确实构造了封面（否则下面的上界是空断言）
          (should (> created 0))
          (should (= 10 (length (with-current-buffer
                                    (seshat-offline-invariant-test--library-buffer)
                                  seshat-library--resident))))
          (dotimes (_ 10)
            (with-current-buffer (seshat-offline-invariant-test--library-buffer)
              (seshat-library-next-page))
            (let ((resident (with-current-buffer
                                (seshat-offline-invariant-test--library-buffer)
                              seshat-library--resident)))
              (should (<= (length resident) 10))
              ;; 驻留集合 ⊆ 当前页（先算离开集合再释放，没有漏放也没有误放）
              (let ((page-uids (seshat-offline-invariant-test--rows)))
                (dolist (cell resident)
                  (should (member (car cell) page-uids))))))
          ;; 收尾：kill-buffer 后 `--resident' 必须为空。
          ;; `--release-all-covers' 由 mode 以 depth 0 挂上，这里用更大的 depth
          ;; （90）保证捕获发生在释放之后——否则捕获到的是释放前的值。
          (let ((buffer (seshat-offline-invariant-test--library-buffer)))
            (with-current-buffer buffer
              (add-hook 'kill-buffer-hook
                        (lambda ()
                          (setq resident-after-kill seshat-library--resident))
                        90 t))
            (kill-buffer buffer)))
        (should-not (buffer-live-p
                     (get-buffer seshat-library--buffer-name))))
      (should-not resident-after-kill)
      (should (= flushed created)))))

;;; I-EXPLICIT：把「依赖环境/实现细节」的安全属性变成显式保证
;;
;; 前三节的不变量都靠**行为**断言（不触网、内存有界）。本节把另外两类
;; 「其实已经正确、但正确性来自外部条件」的属性变成源码级机械断言：
;;
;; - **uid 正则双份同步**：`seshat-covers--uid-regexp' 与
;;   `seshat-library--uid-regexp' 是两份同口径代码（刻意不互相 require，避免依赖
;;   环），此前只靠 docstring 的「改动须同步」约定。这里读两份源码，断言字面量
;;   逐字符相等 + 两个谓词行为等价，约定升级为不变量。
;; - **`read-eval' 显式绑定**：两个侧车读取函数此前靠「Emacs 32 已移除该变量 /
;;   `Package-Requires' 挡住旧版」保证不执行 `#.'。这里断言源码里确实写了
;;   `(let ((read-eval nil)) ...)'，并用含 `#.' 的文件证明代码不会被执行。

(defun seshat-offline-invariant-test--source-file (feature)
  "返回 FEATURE（符号或字符串）对应模块的 `.el' 源文件绝对路径.
优先 `.el' 而不是 `.elc'：断言对象是**磁盘上的实现文本**。`-L' 加载下
`locate-library' 指向本仓库源码；straight 软链场景下 `.el' 与 `.elc' 同目录。"
  (let* ((name (if (symbolp feature) (symbol-name feature) feature))
         (lib (or (locate-library name) ""))
         (el (concat (file-name-sans-extension lib) ".el")))
    (if (file-exists-p el) el lib)))

(defun seshat-offline-invariant-test--definition (feature symbol)
  "返回 SYMBOL 在 FEATURE 源文件里的定义 form（`defun' / `defconst' 等），找不到返回 nil.
用 `read' 逐个顶层 form 扫描，不 eval、不加载——只读磁盘文本。"
  (let ((file (seshat-offline-invariant-test--source-file feature))
        (found nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while (not found)
            (let ((form (read (current-buffer))))
              (when (and (consp form)
                         (memq (car form) '(defun defconst defvar defmacro defcustom))
                         (eq symbol (cadr form)))
                (setq found form))))
        (end-of-file nil)))
    found))

(defun seshat-offline-invariant-test--definition-text (feature symbol)
  "返回 SYMBOL 在 FEATURE 源文件里的定义**原文**（含注释与 docstring），找不到返回 nil.
用 `buffer-substring-no-properties' 取原文而不是 `prin1-to-string'：后者会丢掉
注释，而 `(let ((read-eval nil))    ; 说明……' 这类写法里的注释正是我们要保留的。"
  (let ((file (seshat-offline-invariant-test--source-file feature))
        (found nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while (not found)
            (let ((start (point))
                  (form (read (current-buffer))))
              (when (and (consp form)
                         (memq (car form) '(defun defconst defvar defmacro defcustom))
                         (eq symbol (cadr form)))
                (setq found (buffer-substring-no-properties start (point))))))
        (end-of-file nil)))
    found))

(defun seshat-offline-invariant-test--uid-samples ()
  "返回 uid 谓词的样本集合（合法 / 非法 / 边界 / 注入字符 / 非字符串）.
刻意同时覆盖两个方向：只测非法样本时，「永远返回 nil」的实现也能通过。"
  (let ((legal "0123456789ABCDEFGHJKMNPQRS"))   ; 26 位 Crockford Base32
    (list legal
          "ZZZZZZZZZZZZZZZZZZZZZZZZZZ"
          (concat (substring legal 0 25) "I")    ; 排除字符 I
          (concat (substring legal 0 25) "L")
          (concat (substring legal 0 25) "O")
          (concat (substring legal 0 25) "U")
          (downcase legal)                       ; 小写
          (substring legal 0 25)                 ; 长度 25
          (concat legal "Z")                     ; 长度 27
          (concat (substring legal 0 25) "/")    ; 路径注入字符
          (concat ".." (substring legal 0 24))   ; `..'
          ""                                     ; 空串
          nil                                    ; 非字符串
          42
          (list legal))))

(ert-deftest seshat-offline-invariant-test-uid-regexp-identical ()
  "两份 `--uid-regexp' 字面量**逐字符相等**（同步从人工约定升级为机械不变量）."
  (let ((covers (nth 2 (seshat-offline-invariant-test--definition
                        "seshat-covers" 'seshat-covers--uid-regexp)))
        (library (nth 2 (seshat-offline-invariant-test--definition
                         "seshat-library" 'seshat-library--uid-regexp))))
    (should (stringp covers))
    (should (stringp library))
    ;; 逐字符比较（不用 `string=' 一句话了事：失败时能报出第一个不同的位置）
    (should (= (length covers) (length library)))
    (dotimes (i (length covers))
      (should (char-equal (aref covers i) (aref library i))))
    (should (equal covers library))))

(ert-deftest seshat-offline-invariant-test-uid-predicates-agree ()
  "两份 uid 谓词对同一组样本**返回值完全一致**（含合法样本，防「都返回 nil」）."
  (let ((legal-count 0)
        (samples (seshat-offline-invariant-test--uid-samples)))
    (dolist (sample samples)
      (let ((covers (and (seshat-covers--uid-valid-p sample) t))
            (library (and (seshat-library--uid-valid-p sample) t)))
        (should (eq covers library))
        (when covers (setq legal-count (1+ legal-count)))))
    ;; 正断言：样本里确实有合法 uid（否则「一致」可能只是两边都恒 nil）
    (should (= 2 legal-count))))

(ert-deftest seshat-offline-invariant-test-read-eval-bound-explicitly ()
  "两个侧车读取函数在源码里**显式**绑定 `read-eval' 为 nil.
安全性不能只靠「Emacs 32 已移除该变量」或 `Package-Requires'（后者只在
package.el 路径生效）：手工 `load-path' 加载或降级版本时，显式绑定才是硬保护。"
  (dolist (cell '((seshat-reads . seshat-reads--read-file)
                  (seshat-library . seshat-library--cache-read)))
    (let ((text (seshat-offline-invariant-test--definition-text
                 (car cell) (cdr cell))))
      (should (stringp text))
      (should (string-match-p (regexp-quote "(let ((read-eval nil))") text)))))

(ert-deftest seshat-offline-invariant-test-sharp-dot-is-not-executed ()
  "含 `#.' 读语法的侧车文件不会执行其中代码：进度表与书架缓存都按坏文件降级.
这是 `read-eval' 那条源码断言的行为侧对照——两者合起来才说明「纯数据读取」
不是纸面承诺。"
  (seshat-offline-invariant-test--with-env
    (let ((executed nil)
          (payload "#.(progn (setq executed t) nil)"))
      ;; ① 阅读进度侧车：`:reads' 的值位置塞一个 `#.' 形式
      (write-region (format "(:version 1 :reads %s)\n" payload)
                    nil seshat-reads-file nil 'silent)
      (setq seshat-reads--state nil)
      (should-not (seshat-reads-get (seshat-offline-invariant-test--uid 0)))
      (should-not executed)
      ;; ② 书架清单缓存：`:items' 的值位置塞一个 `#.' 形式
      (write-region (format "(:version 1 :items %s)\n" payload)
                    nil seshat-library-cache-file nil 'silent)
      (should-not (seshat-library--entries-cached))
      (should-not executed)
      ;; 两个侧车文件都**没被删**（坏文件保留以便排查）
      (should (file-exists-p seshat-reads-file))
      (should (file-exists-p seshat-library-cache-file)))))

(provide 'seshat-offline-invariant-test)
;;; seshat-offline-invariant-test.el ends here

