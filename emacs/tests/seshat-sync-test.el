;;; seshat-sync-test.el --- ERT tests for seshat-sync  -*- lexical-binding: t; -*-

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

;; `seshat-sync' 的 M8-B 引擎测试，当前覆盖 T1a（首同步：预建索引）、
;; T1b（事件应用：四类 changes 事件的唯一实现）、T1c（首同步追平取游标）、
;; T1d（增量循环 + `seshat-sync-pull' 编排）与 T2（push 条件写）、T3（move /
;; rename 检测）：`/api/resources' 分页 → 每页写入状态库 → 每页落盘一次；
;; `seshat-sync--apply-event' 对 create / update / rename / delete 的落盘与状态
;; 更新（含路径穿越防御与只读根 403）；`/api/changes' 逐批 apply → 批量块退出
;; → 推进游标 → 落盘（游标后写因此可安全重放），以及首同步 / 增量的路径选择；
;; push 的条件头、412 三方合并与 409 / 403 处置；`seshat-sync-detect-renames'
;; 的快照比对、本地内容改动标脏（push 的唯一输入来源）与 `size + mtime' 双匹配
;; 的 rename 上报。
;;
;; 全部用例**零网络**：统一桩替 `seshat-transport-request'（`seshat-rest' 的
;; 唯一出口），由被测代码真实走 `seshat-rest-list-resources' /
;; `seshat-rest-changes' / `seshat-rest-download-file' 的 URL 拼装与状态码解释，
;; 因此查询参数名（`root' / `since' / `limit'）与 `has_more' / 403 语义都是真实
;; 实现的一部分，而不是被桩掉的口径。
;;
;; 状态库一律绑到临时目录里的 "sync-state.eld"，**绝不写用户的
;; `~/.local/share/seshat/'**；`seshat-state-save' 被桩成「计数 + 调真实实现」，
;; 用来断言「每页 / 每批落盘一次」。`display-warning' 被桩成收集消息，避免测试
;; 输出噪音，同时可断言「只读根只警告一次」。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'seshat-state)
(require 'seshat-sync)

;;; 测试辅助

(defvar seshat-sync-test--dir nil
  "当前用例的临时目录（带结尾斜杠）.")

(defvar seshat-sync-test--requests nil
  "本次用例中被桩的传输调用，反向累积的 (METHOD URL ARGS) 列表.")

(defvar seshat-sync-test--pages nil
  "本次用例排队等待消费的 `/api/resources' 响应列表（先进先出）.")

(defvar seshat-sync-test--roots-response nil
  "本次用例 `/api/roots' 的响应；nil 时回一个空的根列表.")

(defvar seshat-sync-test--downloads nil
  "本次用例排队等待消费的 `/api/files' 下载响应列表（先进先出）.
队列耗尽时回一个空的 200——既能让用例收尾，也能在「本该下载却没下载」时通过
调用次数断言暴露问题（而不是让用例挂死）。")

(defvar seshat-sync-test--versions nil
  "本次用例排队等待消费的 `/api/versions' 响应列表（先进先出）.
push 的 412 分支用它取祖先内容（`:content'）。队列耗尽时回一个 `content' 为空
串的 200，使「本该取祖先却没取」同样能靠调用次数断言暴露，而不是抛「未预期的
请求」把用例打断。")

(defvar seshat-sync-test--changes nil
  "本次用例排队等待消费的 `/api/changes' 响应列表（先进先出）.
队列耗尽时回一个「空批次、`has_more' 为 false」的 200，使循环必然终止；用例
靠请求次数断言暴露「本该多拉一批」的问题，而不是挂死。")

(defvar seshat-sync-test--moves nil
  "本次用例排队等待消费的 `POST /api/resources/{uid}/move' 响应列表（先进先出）.
队列耗尽时回一个空的 200——既能让用例收尾，也能在「本该上报 move 却没上报」时
通过调用次数断言暴露问题（而不是让用例挂死）。")

(defvar seshat-sync-test--calls nil
  "本次用例中 pull 编排各步骤的调用记录（反向累积的符号列表）.
只由 `seshat-sync-test--with-call-log' 填充，用于断言
`seshat-sync-pull' 的调用顺序（reset → build-index → catch-up）。")

(defvar seshat-sync-test--saves 0
  "本次用例 `seshat-state-save' 被调用的次数.")

(defvar seshat-sync-test--warnings nil
  "本次用例通过 `display-warning' 发出的消息（反向累积）.")

(defun seshat-sync-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根，那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-sync-test-" t))))

(defmacro seshat-sync-test--with-state (&rest body)
  "在临时状态文件 + 桩替传输层的环境下执行 BODY.
BODY 期间：`seshat-state-file' 指向临时目录里的 \"sync-state.eld\"，内存状态为
nil（空状态起步），`seshat-sync--read-only-roots' 为空，传输层与
`seshat-state-save' / `display-warning' 均被桩替。结束后递归删除临时目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-sync-test--dir (seshat-sync-test--make-temp-dir))
          (seshat-state-file (expand-file-name "sync-state.eld"
                                               seshat-sync-test--dir))
          (seshat-state--state nil)
          (seshat-sync--read-only-roots nil)
          (seshat-sync-test--requests nil)
          (seshat-sync-test--pages nil)
          (seshat-sync-test--downloads nil)
          (seshat-sync-test--versions nil)
          (seshat-sync-test--changes nil)
          (seshat-sync-test--roots-response nil)
          (seshat-sync-test--saves 0)
          (seshat-sync-test--warnings nil)
          (real-save (symbol-function 'seshat-state-save)))
     (unwind-protect
         (cl-letf (((symbol-function 'seshat-transport-request)
                    #'seshat-sync-test--transport)
                   ((symbol-function 'seshat-state-save)
                    (lambda ()
                      (setq seshat-sync-test--saves
                            (1+ seshat-sync-test--saves))
                      (funcall real-save)))
                   ((symbol-function 'display-warning)
                    (lambda (_type message &optional _level _buffer)
                      (push message seshat-sync-test--warnings))))
           ,@body)
       (ignore-errors (delete-directory seshat-sync-test--dir t)))))

(defmacro seshat-sync-test--without-sleep (&rest body)
  "在把 `sleep-for' 换成「一调就报错」的环境下执行 BODY。
用于断言增量循环不 sleep。用 `fset' 手工换装与还原，而不用
`cl-letf' 改 `symbol-function'：后者对 **subr** 的换装约 0.5 秒/次（实测），
会给本套件带来无谓的耗时，`fset' 只需约 0.05 秒。"
  (declare (indent 0) (debug t))
  `(let ((old-sleep-for (symbol-function 'sleep-for)))
     (unwind-protect
         (progn
           (fset 'sleep-for (lambda (&rest _) (error "增量循环不得 sleep")))
           ,@body)
       (fset 'sleep-for old-sleep-for))))

(defun seshat-sync-test--transport (method url &rest args)
  "桩替 `seshat-transport-request'：按 URL 返回排队响应，零网络.
`/api/roots' 返回 `seshat-sync-test--roots-response'；`/api/resources' 依次
消费 `seshat-sync-test--pages'，`/api/changes' 依次消费
`seshat-sync-test--changes'，`/api/files' 依次消费
`seshat-sync-test--downloads'，队列耗尽时回一个空响应——既能让用例收尾，也能在
「本该终止却没终止」时避免测试挂死（用例改为断言请求次数来暴露问题）。"
  (push (list method url args) seshat-sync-test--requests)
  (cond
   ((string-match-p "/api/roots" url)
    (or seshat-sync-test--roots-response
        (list :status 200 :headers nil
              :body "{\"roots\":[]}")))
   ((string-match-p "/move" url)
    (or (pop seshat-sync-test--moves)
        (list :status 200 :headers nil
              :body "{\"uid\":\"uid-a\",\"from\":\"\",\"to\":\"\"}")))
   ((string-match-p "/api/resources" url)
    (or (pop seshat-sync-test--pages)
        (list :status 200 :headers nil
              :body "{\"items\":[],\"has_more\":false}")))
   ((string-match-p "/api/changes" url)
    (or (pop seshat-sync-test--changes)
        (list :status 200 :headers nil
              :body "{\"changes\":[],\"next_cursor\":0,\"has_more\":false}")))
   ((string-match-p "/api/versions/" url)
    (or (pop seshat-sync-test--versions)
        (list :status 200 :headers nil
              :body (json-encode '((head . "") (content . ""))))))
   ((string-match-p "/api/files/" url)
    (or (pop seshat-sync-test--downloads)
        (list :status 200 :headers nil :body "")))
   (t (error "未预期的请求：%s %s" method url))))

(defun seshat-sync-test--query (url)
  "把 URL 的查询串解析为 ((NAME . VALUE)…)，键值均做 URL 解码。"
  (let ((start (string-match "\\?" url)))
    (when start
      (mapcar (lambda (pair)
                (let ((eq-pos (string-match "=" pair)))
                  (cons (url-unhex-string (substring pair 0 eq-pos))
                        (url-unhex-string (substring pair (1+ eq-pos))))))
              (split-string (substring url (1+ start)) "&" t)))))

(defun seshat-sync-test--param (call name)
  "返回被桩调用 CALL 的查询参数 NAME 的值（字符串）；无该参数时返回 nil。"
  (cdr (assoc name (seshat-sync-test--query (nth 1 call)))))

(defun seshat-sync-test--resource-calls ()
  "按发生顺序返回 `/api/resources' 的调用列表。"
  (cl-remove-if-not (lambda (call)
                      (string-match-p "/api/resources" (nth 1 call)))
                    (reverse seshat-sync-test--requests)))

(defun seshat-sync-test--all-urls ()
  "按发生顺序返回本次用例的全部请求 URL。"
  (mapcar (lambda (call) (nth 1 call)) (reverse seshat-sync-test--requests)))

(defun seshat-sync-test--item (uid path mtime &optional root)
  "构造一个 `/api/resources' 资源对象（JSON 对象对应的 alist）。
UID / PATH / MTIME 为 uid、根内相对路径与 mtime 秒；ROOT 缺省 \"notes\"。"
  (list (cons 'uid uid)
        (cons 'root (or root "notes"))
        (cons 'path path)
        (cons 'kind "file")
        (cons 'blob "blob0")
        (cons 'rev "rev0")
        (cons 'size 128)
        (cons 'mtime mtime)
        (cons 'created_at "2026-10-18T08:00:00Z")
        (cons 'updated_at "2026-10-18T09:00:00Z")
        (cons 'deleted_at "")))

(defun seshat-sync-test--page (items &optional has-more)
  "构造 `/api/resources' 的成功传输响应：资源列表 ITEMS、`has_more' = HAS-MORE。"
  (list :status 200
        :headers nil
        :body (json-encode (list (cons 'items (vconcat items))
                                 (cons 'has_more (if has-more t :json-false))))))

(defun seshat-sync-test--plist-item (uid path mtime)
  "构造一个**已解析**形态的资源 plist（关键字键），用于直接测内部函数。
`seshat-sync-test--item' 造的是待编码的 JSON alist（符号键），两者不可混用。"
  (list :uid uid :root "notes" :path path :mtime mtime))

(defun seshat-sync-test--read-only-page ()
  "构造 `/api/resources' 的 403 只读根传输响应。"
  (list :status 403
        :headers nil
        :body "{\"error\":{\"code\":\"root_read_only\"}}"))

(defun seshat-sync-test--roots-body (roots)
  "构造 `/api/roots' 的成功传输响应，ROOTS 为 (TAG MODE DEFAULT) 三元组列表。"
  (list :status 200
        :headers nil
        :body (json-encode
               (list (cons 'roots
                           (vconcat
                            (mapcar (lambda (root)
                                      (list (cons 'tag (nth 0 root))
                                            (cons 'mode (nth 1 root))
                                            (cons 'default (if (nth 2 root)
                                                               t
                                                             :json-false))))
                                    roots)))))))

(defun seshat-sync-test--warnings-matching (regexp)
  "返回本次用例中匹配 REGEXP 的警告消息列表。"
  (cl-remove-if-not (lambda (message) (string-match-p regexp message))
                    seshat-sync-test--warnings))

;;; 事件应用（T1b）用的辅助

(defun seshat-sync-test--local (rel)
  "返回本次用例临时目录下相对路径 REL 的绝对路径。"
  (expand-file-name rel seshat-sync-test--dir))

(defun seshat-sync-test--write-local (rel content)
  "在临时目录下写入内容为 CONTENT 的文件 REL，返回其绝对路径。"
  (let ((file (seshat-sync-test--local rel)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert content))
    file))

(defun seshat-sync-test--read-local (rel)
  "读取临时目录下相对路径 REL 的文件内容；不存在时返回 nil。"
  (let ((file (seshat-sync-test--local rel)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun seshat-sync-test--event (op uid path &rest overrides)
  "构造一条 `changes' 事件 plist（字段与 `seshat-rest-changes' 的结果同构）。
OP / UID / PATH 为事件类型（字符串）、uid 与根内相对路径；OVERRIDES 为覆盖字段
的 plist 片段，例如 (:root \"books\" :blob \"sha1:abc\" :old-path \"old.org\")
（可连续给多组，后者覆盖前者）。"
  (let ((event (list :seq 1 :uid uid :op op :root "notes" :path path
                     :old-path "" :blob "blob0" :rev "rev0"
                     :changed-at "2026-10-24T00:00:00Z")))
    (while overrides
      (setq event (plist-put event (car overrides) (cadr overrides)))
      (setq overrides (cddr overrides)))
    event))

(defun seshat-sync-test--download-calls ()
  "按发生顺序返回 `/api/files' 的调用列表。"
  (cl-remove-if-not (lambda (call) (string-match-p "/api/files/" (nth 1 call)))
                    (reverse seshat-sync-test--requests)))

(defun seshat-sync-test--file-ok (&optional content)
  "构造 `/api/files' 的成功传输响应，CONTENT 为文件内容（缺省 \"content\"）。
ETag 头带上双引号（服务端原样），调用方若读它可直接作 `If-Match' 取值。"
  (list :status 200
        :headers '(("ETag" . "\"blob0\""))
        :body (or content "content")))

(defun seshat-sync-test--file-status (status)
  "构造 `/api/files' 的非 2xx 传输响应（STATUS 为 403 / 404 等）。"
  (list :status status
        :headers nil
        :body "{\"error\":{\"code\":\"x\"}}"))

;;; seshat-sync--next-since-mtime（纯函数：不得死循环的全部判据）

(ert-deftest seshat-sync-test-next-since-mtime-advances ()
  "下一页 since 的四种情形：正常取末项 mtime、同秒 +1、空页 +1、畸形 +1。"
  ;; 正常：末项 mtime 大于本次 since → 直接用它
  (should (= 200 (seshat-sync--next-since-mtime
                  0 (list (seshat-sync-test--plist-item "u1" "a.org" 100)
                          (seshat-sync-test--plist-item "u2" "b.org" 200)))))
  ;; 同秒：末项 mtime 等于本次 since → 必须 +1 才能前进（代价是跳过该秒剩余记录）
  (should (= 501 (seshat-sync--next-since-mtime
                  500 (list (seshat-sync-test--plist-item "u1" "a.org" 500)
                            (seshat-sync-test--plist-item "u2" "b.org" 500)))))
  ;; items 为空但 has-more 为真（异常）：没有 mtime 可用，仍须前进
  (should (= 501 (seshat-sync--next-since-mtime 500 nil)))
  ;; mtime 不是数字（畸形响应）：退化为 +1
  (should (= 1 (seshat-sync--next-since-mtime
                0 (list (list :uid "u1" :path "a.org"))))))

;;; 分页

(ert-deftest seshat-sync-test-build-index-pages-until-has-more-nil ()
  "按 `:has-more' 循环到结束：两页两份请求，两页条目全部进索引。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 100)
                       (seshat-sync-test--item "uid-b" "b.org" 200))
                 t)
                (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-c" "c.org" 300)))))
    (let ((stats (seshat-sync--build-index)))
      (should (= 2 (length (seshat-sync-test--resource-calls))))
      (should (= 2 (plist-get stats :pages)))
      (should (= 3 (plist-get stats :items)))
      (should (= 1 (plist-get stats :roots)))
      (should (= 0 (plist-get stats :skipped-roots)))
      ;; 页大小固定 2000、根固定为配置里的 tag
      (should (equal "2000" (seshat-sync-test--param
                             (car (seshat-sync-test--resource-calls)) "limit")))
      (should (equal "notes" (seshat-sync-test--param
                              (car (seshat-sync-test--resource-calls)) "root")))
      ;; 两页条目都能按 (root . path) 反查
      (should (equal (cons "notes" "a.org") (seshat-state-path-for-uid "uid-a")))
      (should (equal (cons "notes" "b.org") (seshat-state-path-for-uid "uid-b")))
      (should (equal (cons "notes" "c.org") (seshat-state-path-for-uid "uid-c")))
      (should (equal "uid-c" (seshat-state-uid-for-path "notes" "c.org"))))))

(ert-deftest seshat-sync-test-build-index-next-since-is-last-mtime ()
  "第二次请求的 `:since-mtime' 取第一页最后一项的 mtime。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 1760785200)
                       (seshat-sync-test--item "uid-b" "b.org" 1760785300))
                 t)
                (seshat-sync-test--page nil)))
    (seshat-sync--build-index)
    (let ((calls (seshat-sync-test--resource-calls)))
      (should (= 2 (length calls)))
      (should (equal "0" (seshat-sync-test--param (nth 0 calls) "since")))
      (should (equal "1760785300" (seshat-sync-test--param (nth 1 calls) "since"))))))

(ert-deftest seshat-sync-test-build-index-same-second-forces-advance ()
  "同秒内有 more 时 since 必须 +1 前进，循环因此有限次终止。
该秒内剩余的记录会被跳过——这是已知代价（F7），由 changes 追平补齐。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 500)
                       (seshat-sync-test--item "uid-b" "b.org" 500))
                 t)
                (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-c" "c.org" 500))
                 t)
                (seshat-sync-test--page nil)))
    (let ((stats (seshat-sync--build-index))
          (calls (seshat-sync-test--resource-calls)))
      ;; 三次请求后终止：0 → 500（末项 mtime）→ 501（同秒强制前进）→ 空页
      (should (= 3 (length calls)))
      (should (equal '("0" "500" "501")
                     (mapcar (lambda (call)
                               (seshat-sync-test--param call "since"))
                             calls)))
      (should (= 3 (plist-get stats :pages)))
      ;; 该秒剩余记录（uid-c 与 uid-b 同秒）确实被跳过一次，但已在第一页写入
      (should (equal (cons "notes" "c.org") (seshat-state-path-for-uid "uid-c"))))))

(ert-deftest seshat-sync-test-build-index-saves-once-per-page ()
  "每页退出批量块后调用一次 `seshat-state-save'（计数 = 页数）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 100))
                 t)
                (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-b" "b.org" 200)))))
    (let ((stats (seshat-sync--build-index)))
      (should (= 2 (plist-get stats :pages)))
      (should (= 2 seshat-sync-test--saves))
      ;; 落盘内容自洽：重新加载不应触发「:paths 与 :uids 不一致」的告警
      (setq seshat-state--state nil)
      (seshat-state-load)
      (should-not (seshat-sync-test--warnings-matching "不一致")))))

;;; 按根分别发起 / 只读根

(ert-deftest seshat-sync-test-build-index-requests-each-root-separately ()
  "配置两个根时，各自分别发起请求（每根至少一次），条目归属各自的根。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")
                              ("journal" "/tmp/journal" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-n" "n.org" 100 "notes")))
                (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-j" "j.org" 200 "journal")))))
    (let ((stats (seshat-sync--build-index))
          (calls (seshat-sync-test--resource-calls)))
      (should (= 2 (length calls)))
      (should (= 2 (plist-get stats :roots)))
      (should (= 2 (plist-get stats :pages)))
      (should (= 2 (plist-get stats :items)))
      (should (equal '("notes" "journal")
                     (mapcar (lambda (call)
                               (seshat-sync-test--param call "root"))
                             calls)))
      (should (equal (cons "notes" "n.org")
                     (seshat-state-path-for-uid "uid-n")))
      (should (equal (cons "journal" "j.org")
                     (seshat-state-path-for-uid "uid-j")))
      ;; 不带 root 参数以外的根混入：每根请求的 since 都从 0 起
      (should (equal '("0" "0")
                     (mapcar (lambda (call)
                               (seshat-sync-test--param call "since"))
                             calls))))))

(ert-deftest seshat-sync-test-build-index-skips-read-only-root ()
  "某根返回 403 时跳过该根（不写入、只警告一次），其余根继续。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("ondemand-books" "/tmp/books" "ondemand")
                              ("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--read-only-page)
                (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-n" "n.org" 100)))))
    (let ((stats (seshat-sync--build-index))
          (calls (seshat-sync-test--resource-calls)))
      (should (= 2 (length calls)))
      (should (= 1 (plist-get stats :skipped-roots)))
      (should (= 1 (plist-get stats :items)))
      (should (= 1 (plist-get stats :pages)))
      ;; 只读根没有被跳过之后的任何写入（也没有重试）
      (should-not (seshat-state-uid-for-path "ondemand-books" "b.org"))
      (should (equal 1 (length (seshat-sync-test--warnings-matching
                                "只读（403"))))
      ;; 只读根进入共用缓存，供后续 push 复用同一判定
      (should (seshat-sync--read-only-root-p "ondemand-books"))
      (should-not (seshat-sync--read-only-root-p "notes"))
      ;; 另一个根照常写入
      (should (equal (cons "notes" "n.org")
                     (seshat-state-path-for-uid "uid-n"))))))

;;; 保留既有字段（关键回归）

(ert-deftest seshat-sync-test-build-index-preserves-existing-base-blob ()
  "索引只更新 `:path' / `:root'，既有 `:base-blob' / `:size' / `:mtime' /
`:dirty' 全部保留——否则下轮 push 会把已有文件误判为新建。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (seshat-state-set "uid-x" (list :root "notes"
                                    :path "old.org"
                                    :base-blob "sha1:x"
                                    :size 42
                                    :mtime 1760780000
                                    :dirty t))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-x" "new.org" 1760799999)))))
    (seshat-sync--build-index)
    (let ((entry (seshat-state-get "uid-x")))
      (should (equal "new.org" (plist-get entry :path)))
      (should (equal "notes" (plist-get entry :root)))
      (should (equal "sha1:x" (plist-get entry :base-blob)))
      (should (= 42 (plist-get entry :size)))
      (should (= 1760780000 (plist-get entry :mtime)))
      (should (eq t (plist-get entry :dirty)))
      ;; 索引不写 base-blob：新条目仍是「未下载」状态
      (should (equal (cons "notes" "new.org")
                     (seshat-state-path-for-uid "uid-x"))))))

(ert-deftest seshat-sync-test-build-index-does-not-download-or-write-base-blob ()
  "索引阶段只发 `/api/resources' 与（必要时）`/api/roots'，不下载文件、
不写 base-blob（下载属 T1b）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 100)))))
    (seshat-sync--build-index)
    (should (equal '("GET") (delete-dups
                             (mapcar #'car
                                     (reverse seshat-sync-test--requests)))))
    (should-not (cl-some (lambda (url) (string-match-p "/api/files" url))
                         (seshat-sync-test--all-urls)))
    ;; `/api/roots' 不需要（本地根配置非空）
    (should-not (cl-some (lambda (url) (string-match-p "/api/roots" url))
                         (seshat-sync-test--all-urls)))
    (should-not (plist-get (seshat-state-get "uid-a") :base-blob))
    (should-not (plist-get (seshat-state-get "uid-a") :mtime))))

;;; 根来源

(ert-deftest seshat-sync-test-build-index-uses-server-default-root-when-unset ()
  "`seshat-state-roots' 为空时用服务端 `:default' 根作为唯一根发起一次请求。"
  (seshat-sync-test--with-state
    (should-not (seshat-state-roots))
    (setq seshat-sync-test--roots-response
          (seshat-sync-test--roots-body '(("journal" "mirror" nil)
                                          ("notes" "mirror" t))))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-n" "n.org" 100 "notes")))))
    (let ((stats (seshat-sync--build-index))
          (calls (seshat-sync-test--resource-calls)))
      (should (= 1 (length calls)))
      (should (equal "notes" (seshat-sync-test--param (car calls) "root")))
      (should (= 1 (plist-get stats :roots)))
      (should (= 1 (plist-get stats :items)))
      ;; 服务端根列表只问一次
      (should (= 1 (length (cl-remove-if-not
                            (lambda (url) (string-match-p "/api/roots" url))
                            (seshat-sync-test--all-urls)))))
      (should (equal (cons "notes" "n.org")
                     (seshat-state-path-for-uid "uid-n"))))))

(ert-deftest seshat-sync-test-build-index-falls-back-to-first-server-root ()
  "服务端没有标记为 `:default' 的根时，退化为第一个根。"
  (seshat-sync-test--with-state
    (setq seshat-sync-test--roots-response
          (seshat-sync-test--roots-body '(("journal" "mirror" nil)
                                          ("notes" "mirror" nil))))
    (setq seshat-sync-test--pages (list (seshat-sync-test--page nil)))
    (let ((stats (seshat-sync--build-index))
          (calls (seshat-sync-test--resource-calls)))
      (should (= 1 (length calls)))
      (should (equal "journal" (seshat-sync-test--param (car calls) "root")))
      (should (= 1 (plist-get stats :roots))))))

(ert-deftest seshat-sync-test-build-index-no-roots-at-all ()
  "本地与服务端都没有根时：不发资源请求，统计全零（不死循环、不报错）。"
  (seshat-sync-test--with-state
    (let ((stats (seshat-sync--build-index)))
      (should-not (seshat-sync-test--resource-calls))
      (should (= 0 (plist-get stats :roots)))
      (should (= 0 (plist-get stats :pages)))
      (should (= 0 (plist-get stats :items)))
      (should (= 0 (plist-get stats :skipped-roots))))))

;;; 非 2xx（非只读根）

(ert-deftest seshat-sync-test-build-index-stops-on-other-error ()
  "非 403 的失败不重试：退出该根并记一条警告（索引只是尽力而为的预建）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots '(("notes" "/tmp/notes" "mirror")))
    (setq seshat-sync-test--pages
          (list (list :status 500 :headers nil :body "")))
    (let ((stats (seshat-sync--build-index)))
      (should (= 1 (length (seshat-sync-test--resource-calls))))
      (should (= 0 (plist-get stats :pages)))
      (should (= 0 (plist-get stats :items)))
      (should (= 0 (plist-get stats :skipped-roots)))
      (should (equal 1 (length (seshat-sync-test--warnings-matching
                                "请求失败")))))))

;;; T1b：事件应用（`seshat-sync--apply-event'）

(ert-deftest seshat-sync-test-apply-event-create-downloads-and-records-blob ()
  "create（mirror 根）：下载一次，base-blob / size / mtime 写入，root/path 正确。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "hello")))
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "create" "uid-a" "a.org" :blob "blob-new")))
    (let* ((calls (seshat-sync-test--download-calls))
           (entry (seshat-state-get "uid-a"))
           (local (seshat-sync-test--local "a.org")))
      (should (= 1 (length calls)))
      ;; 下载请求带上了根 tag，路径就是事件里的相对路径
      (should (equal "notes" (seshat-sync-test--param (car calls) "root")))
      (should (string-suffix-p "/api/files/a.org" (car (split-string (nth 1 (car calls)) "?"))))
      (should (equal "hello" (seshat-sync-test--read-local "a.org")))
      (should (equal "blob-new" (plist-get entry :base-blob)))
      ;; size / mtime 取**落盘后**的 file-attributes（mtime 换算为 Unix 秒整数）
      (should (= 5 (plist-get entry :size)))
      (should (integerp (plist-get entry :mtime)))
      (should (= (truncate (float-time (nth 5 (file-attributes local))))
                 (plist-get entry :mtime)))
      (should-not (plist-get entry :dirty))
      (should (equal (cons "notes" "a.org")
                     (seshat-state-path-for-uid "uid-a"))))))

(ert-deftest seshat-sync-test-apply-event-update-same-blob-skips-download ()
  "update 且 `:blob' 与 base-blob 相同 + 本地文件存在 → **不下载**，只对齐 root/path。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "b.org" "same")
    (seshat-state-set "uid-a" (list :root "notes" :path "stale.org"
                                    :base-blob "blob0" :size 4 :mtime 100))
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "update" "uid-a" "b.org" :blob "blob0")))
    ;; 桩断言：下载次数为 0
    (should-not (seshat-sync-test--download-calls))
    (let ((entry (seshat-state-get "uid-a")))
      (should (equal "notes" (plist-get entry :root)))
      (should (equal "b.org" (plist-get entry :path)))
      ;; merge 语义：base-blob / size / mtime 原样保留（不整体覆盖）
      (should (equal "blob0" (plist-get entry :base-blob)))
      (should (= 4 (plist-get entry :size)))
      (should (= 100 (plist-get entry :mtime)))
      (should (equal "same" (seshat-sync-test--read-local "b.org")))
      (should (equal (cons "notes" "b.org")
                     (seshat-state-path-for-uid "uid-a"))))))

(ert-deftest seshat-sync-test-apply-event-update-different-blob-downloads ()
  "update 且 `:blob' 与 base-blob 不同 → 下载并用新 blob 覆盖基线。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "old")
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"
                                    :base-blob "blob-old" :size 3 :mtime 100))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "new!")))
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "update" "uid-a" "a.org" :blob "blob-new")))
    (should (= 1 (length (seshat-sync-test--download-calls))))
    (should (equal "new!" (seshat-sync-test--read-local "a.org")))
    (let ((entry (seshat-state-get "uid-a")))
      (should (equal "blob-new" (plist-get entry :base-blob)))
      (should (= 4 (plist-get entry :size)))
      (should (equal (cons "notes" "a.org")
                     (seshat-state-path-for-uid "uid-a"))))))

(ert-deftest seshat-sync-test-apply-event-rename-moves-file-and-remaps ()
  "rename：本地文件从 old 搬到 new，`seshat-state-remap' 生效（三参）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "body")
    (seshat-state-set "uid-a" (list :root "notes" :path "old.org"
                                    :base-blob "blob0" :size 5 :mtime 100))
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "rename" "uid-a" "new.org" :old-path "old.org")))
    (should-not (file-exists-p (seshat-sync-test--local "old.org")))
    (should (equal "body" (seshat-sync-test--read-local "new.org")))
    (should (equal (cons "notes" "new.org")
                   (seshat-state-path-for-uid "uid-a")))
    (should-not (seshat-state-uid-for-path "notes" "old.org"))
    ;; 只搬文件，不下载；base-blob 保持不变
    (should-not (seshat-sync-test--download-calls))
    (should (equal "blob0" (plist-get (seshat-state-get "uid-a") :base-blob)))))

(ert-deftest seshat-sync-test-apply-event-rename-missing-old-file-still-remaps ()
  "rename 且旧文件不存在：不报错、不抛错，仍 remap（状态以服务端为准）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-state-set "uid-a" (list :root "notes" :path "gone.org"
                                    :base-blob "blob0"))
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "rename" "uid-a" "new.org" :old-path "gone.org")))
    (should (equal (cons "notes" "new.org")
                   (seshat-state-path-for-uid "uid-a")))
    (should-not (seshat-sync-test--warnings-matching "改名"))))

(ert-deftest seshat-sync-test-apply-event-delete-removes-file-and-marks-tombstone ()
  "delete：本地文件被删、`deleted-uids' 含该 uid、base-blob 仍在（墓碑保留基线）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "bye")
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"
                                    :base-blob "blob0" :size 3 :mtime 100))
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "delete" "uid-a" "a.org" :blob "")))
    (should-not (file-exists-p (seshat-sync-test--local "a.org")))
    (should (member "uid-a" (seshat-state-deleted-uids)))
    (let ((entry (seshat-state-get "uid-a")))
      (should (equal "blob0" (plist-get entry :base-blob)))
      (should (integerp (plist-get entry :deleted-at))))
    ;; 墓碑不占本地路径
    (should-not (seshat-state-path-for-uid "uid-a"))
    (should-not (seshat-state-uid-for-path "notes" "a.org"))
    ;; 本地文件本来就不存在时同样成功（忽略而非报错）
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "delete" "uid-b" "never.org")))))

(ert-deftest seshat-sync-test-apply-event-ondemand-downloads-only-when-missing ()
  "ondemand 根：本地缺文件才下载；本地已有副本时**不下载**（书库按需）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "books" seshat-sync-test--dir "ondemand")))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "epub")))
    ;; ① 本地缺文件 → 下载
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "create" "uid-book" "book.epub"
                                      :root "books" :blob "")))
    (should (= 1 (length (seshat-sync-test--download-calls))))
    (should (equal "epub" (seshat-sync-test--read-local "book.epub")))
    ;; ② 本地已有文件 → 不下载（哪怕 blob 与 base-blob 不同）
    (seshat-sync-test--write-local "cached.epub" "local-copy")
    (should (seshat-sync--apply-event
             (seshat-sync-test--event "update" "uid-cache" "cached.epub"
                                      :root "books" :blob "blob-x")))
    (should (= 1 (length (seshat-sync-test--download-calls))))
    (should (equal "local-copy" (seshat-sync-test--read-local "cached.epub")))
    (should (equal (cons "books" "cached.epub")
                   (seshat-state-path-for-uid "uid-cache")))))

(ert-deftest seshat-sync-test-apply-event-rejects-path-traversal ()
  "路径穿越防御：`..' / 绝对路径一律拒绝——不下载、不删除、不建根外文件。"
  (seshat-sync-test--with-state
    (let* ((root (expand-file-name "notes/" seshat-sync-test--dir))
           (base (file-name-nondirectory (directory-file-name seshat-sync-test--dir)))
           (leak (expand-file-name (concat base "-outside.org") "/tmp")))
      (seshat-state-set-roots (list (list "notes" root "mirror")))
      (seshat-sync-test--write-local "outside.org" "keep")
      (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "evil")))
      (should-not (file-exists-p leak))
      ;; ① create + `..' 穿越
      (should-not (seshat-sync--apply-event
                   (seshat-sync-test--event "create" "uid-evil" "../../etc/passwd")))
      ;; ② create + 绝对路径
      (should-not (seshat-sync--apply-event
                   (seshat-sync-test--event "create" "uid-abs" "/etc/passwd")))
      ;; ③ create + 会逃到 /tmp 的路径：断言根外文件确实没被创建
      (should-not (seshat-sync--apply-event
                   (seshat-sync-test--event "create" "uid-leak"
                                            (concat "../" base "-outside.org"))))
      (should-not (file-exists-p leak))
      ;; ④ delete + `..' 穿越：根外文件必须原样保留
      (should-not (seshat-sync--apply-event
                   (seshat-sync-test--event "delete" "uid-del" "../outside.org")))
      (should (file-exists-p (seshat-sync-test--local "outside.org")))
      (should (equal "keep" (seshat-sync-test--read-local "outside.org")))
      ;; 全程零下载、零状态改动，且每次跳过都有一条警告
      (should-not (seshat-sync-test--download-calls))
      (should-not (seshat-state-get "uid-evil"))
      (should-not (seshat-state-get "uid-abs"))
      (should-not (seshat-state-get "uid-leak"))
      (should-not (seshat-state-deleted-uids))
      (should (= 4 (length (seshat-sync-test--warnings-matching "越界")))))))

(ert-deftest seshat-sync-test-apply-event-read-only-root-marks-and-skips ()
  "下载返回 `:read-only-root'（403）→ 记入只读根缓存、返回 nil、不重试。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "books" seshat-sync-test--dir "ondemand")))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-status 403)
                (seshat-sync-test--file-ok "should-not-be-used")))
    (should-not (seshat-sync--apply-event
                 (seshat-sync-test--event "create" "uid-a" "a.epub" :root "books")))
    (should (seshat-sync--read-only-root-p "books"))
    (should-not (seshat-sync--read-only-root-p "notes"))
    ;; 不重试：只发了一次下载请求
    (should (= 1 (length (seshat-sync-test--download-calls))))
    ;; 不落盘、不写状态
    (should-not (file-exists-p (seshat-sync-test--local "a.epub")))
    (should-not (seshat-state-get "uid-a"))
    (should (= 1 (length (seshat-sync-test--warnings-matching "只读（403"))))))

(ert-deftest seshat-sync-test-apply-event-unknown-op-warns-and-skips ()
  "未知 op（如 \"rescan\"）→ 返回 nil + 警告，不发请求、不改状态。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (should-not (seshat-sync--apply-event
                 (seshat-sync-test--event "rescan" "uid-a" "a.org")))
    (should (= 1 (length (seshat-sync-test--warnings-matching "未知 op"))))
    (should-not seshat-sync-test--requests)
    (should-not (seshat-state-get "uid-a"))))

(ert-deftest seshat-sync-test-apply-event-unknown-root-skips-without-path ()
  "根未配置本地目录 → 跳过并警告，**不凭空造路径**、不发请求。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (should-not (seshat-sync--apply-event
                 (seshat-sync-test--event "create" "uid-a" "a.org" :root "ghost")))
    (should (= 1 (length (seshat-sync-test--warnings-matching
                          "未配置本地目录"))))
    (should-not seshat-sync-test--requests)
    (should-not (seshat-state-get "uid-a"))
    ;; 一个根都没配置时同理（也绝不能落到 `seshat-sync-local-dir' 之类的兜底）
    (seshat-state-set-roots nil)
    (should-not (seshat-sync--apply-event
                 (seshat-sync-test--event "create" "uid-b" "b.org")))
    (should-not seshat-sync-test--requests)
    (should-not (seshat-state-get "uid-b"))
    (should-not (file-exists-p (seshat-sync-test--local "b.org")))))

(ert-deftest seshat-sync-test-root-dir-and-local-path-guards ()
  "`--root-dir' 只认已配置的根；`--local-path' 拒绝绝对路径 / `~' / 盘符 / 空 / 穿越。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (let ((dir (seshat-sync--root-dir "notes")))
      (should (equal (file-name-as-directory (expand-file-name seshat-sync-test--dir))
                     dir))
      (should-not (seshat-sync--root-dir "ghost"))
      (should-not (seshat-sync--root-dir nil))
      ;; 正常相对路径
      (should (equal (expand-file-name "a/b.org" dir)
                     (seshat-sync--local-path dir "a/b.org")))
      ;; 绝对路径 / `~' / 盘符 / 空 / nil
      (should-not (seshat-sync--local-path dir "/etc/passwd"))
      (should-not (seshat-sync--local-path dir "~/evil.org"))
      (should-not (seshat-sync--local-path dir "C:/Windows/evil.org"))
      (should-not (seshat-sync--local-path dir ""))
      (should-not (seshat-sync--local-path dir nil))
      (should-not (seshat-sync--local-path nil "a.org"))
      ;; 穿越
      (should-not (seshat-sync--local-path dir "../outside.org"))
      (should-not (seshat-sync--local-path dir "a/../../outside.org"))
      ;; 归一后仍在根内的 `..' 允许（不误杀）
      (should (equal (expand-file-name "b.org" dir)
                     (seshat-sync--local-path dir "a/../b.org"))))))

;;; changes（T1c / T1d）用的辅助

(defun seshat-sync-test--change (seq uid op path &rest overrides)
  "构造一条 `changes' 事件（待 JSON 编码的 alist，符号键）。
SEQ / UID / OP / PATH 为序号、uid、事件类型（字符串）与根内相对路径；
OVERRIDES 为覆盖字段的 plist 片段，例如 (:root \"books\" :old_path \"a.org\")。
键名与 JSON 一致（`old_path' / `changed_at' 用下划线），由
`seshat-rest--json-plist' 转成 `:old-path' / `:changed-at'。"
  (let ((plist (list :seq seq :uid uid :op op :root "notes" :path path
                     :old_path "" :blob "blob0" :rev "rev0"
                     :changed_at "2026-10-24T00:00:00Z")))
    (while overrides
      (setq plist (plist-put plist (car overrides) (cadr overrides)))
      (setq overrides (cddr overrides)))
    (let (alist)
      (while plist
        (push (cons (intern (substring (symbol-name (car plist)) 1))
                    (cadr plist))
              alist)
        (setq plist (cddr plist)))
      (nreverse alist))))

(defun seshat-sync-test--changes-page (events next-cursor &optional has-more)
  "构造 `/api/changes' 的成功传输响应。
EVENTS 为事件列表（`seshat-sync-test--change' 的产物），NEXT-CURSOR 为
`next_cursor'（整数），HAS-MORE 非 nil 时 `has_more' 为 JSON true。"
  (list :status 200
        :headers nil
        :body (json-encode (list (cons 'changes (vconcat events))
                                 (cons 'next_cursor next-cursor)
                                 (cons 'has_more (if has-more t :json-false))))))

(defun seshat-sync-test--changes-calls ()
  "按发生顺序返回 `/api/changes' 的调用列表。"
  (cl-remove-if-not (lambda (call)
                      (string-match-p "/api/changes" (nth 1 call)))
                    (reverse seshat-sync-test--requests)))

(defun seshat-sync-test--projection ()
  "返回状态库的可比较投影：`(UID ROOT PATH BASE-BLOB)' 列表（按 uid 排序）。
不比较 `:mtime' / `:size'——它们取自**落盘时刻**的本地 `file-attributes'，
两次运行之间必然有细微差别；「重放结果与一次跑完相同」的语义不依赖它们。"
  (let (result)
    (dolist (cell (plist-get (seshat-state--ensure) :uids))
      (let ((entry (cdr cell)))
        (push (list (car cell)
                    (plist-get entry :root)
                    (plist-get entry :path)
                    (plist-get entry :base-blob))
              result)))
    (sort result (lambda (a b) (string< (car a) (car b))))))

(defmacro seshat-sync-test--with-call-log (&rest body)
  "在记录 pull 编排各步骤调用顺序的环境下执行 BODY。
BODY 期间 `seshat-sync-test--calls' 为反向累积的符号列表
（`reset' / `ensure-roots' / `build-index' / `catch-up' / `pull-changes'），
每个桩都会继续调用真实实现，因此顺序与真实行为可以同时断言。"
  (declare (indent 0) (debug t))
  `(let ((real-reset (symbol-function 'seshat-sync--reset-read-only-roots))
         (real-ensure (symbol-function 'seshat-sync--ensure-roots))
         (real-index (symbol-function 'seshat-sync--build-index))
         (real-catch-up (symbol-function 'seshat-sync--catch-up))
         (real-pull-changes (symbol-function 'seshat-sync--pull-changes))
         (seshat-sync-test--calls nil))
     (cl-letf (((symbol-function 'seshat-sync--reset-read-only-roots)
                (lambda ()
                  (push 'reset seshat-sync-test--calls)
                  (funcall real-reset)))
               ((symbol-function 'seshat-sync--ensure-roots)
                (lambda ()
                  (push 'ensure-roots seshat-sync-test--calls)
                  (funcall real-ensure)))
               ((symbol-function 'seshat-sync--build-index)
                (lambda ()
                  (push 'build-index seshat-sync-test--calls)
                  (funcall real-index)))
               ((symbol-function 'seshat-sync--catch-up)
                (lambda ()
                  (push 'catch-up seshat-sync-test--calls)
                  (funcall real-catch-up)))
               ((symbol-function 'seshat-sync--pull-changes)
                (lambda ()
                  (push 'pull-changes seshat-sync-test--calls)
                  (funcall real-pull-changes))))
       ,@body)))

;;; T1c：首同步追平（`seshat-sync--catch-up'）

(ert-deftest seshat-sync-test-catch-up-pages-until-has-more-nil ()
  "按 `:has-more' 循环到结束：两批两份请求，两批事件都被应用并落盘。
首批 `since' 为 0、页大小固定 2000（计划 D3 第 1.b 步的实参）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 1 "uid-a" "create" "a.org")) 1 t)
                (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 2 "uid-b" "create" "b.org")) 2)))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-ok "aaa")
                (seshat-sync-test--file-ok "bbb")))
    (let ((stats (seshat-sync--catch-up))
          (calls (seshat-sync-test--changes-calls)))
      (should (= 2 (length calls)))
      (should (= 2 (plist-get stats :batches)))
      (should (= 2 (plist-get stats :events)))
      (should (= 2 (plist-get stats :cool)))
      ;; 实参：首批 since=0、limit=2000（服务端上限）
      (should (equal "0" (seshat-sync-test--param (nth 0 calls) "since")))
      (should (equal "2000" (seshat-sync-test--param (nth 0 calls) "limit")))
      ;; 两批事件都落到本地与状态库
      (should (equal "aaa" (seshat-sync-test--read-local "a.org")))
      (should (equal "bbb" (seshat-sync-test--read-local "b.org")))
      (should (equal (cons "notes" "a.org")
                     (seshat-state-path-for-uid "uid-a")))
      (should (equal (cons "notes" "b.org")
                     (seshat-state-path-for-uid "uid-b"))))))

(ert-deftest seshat-sync-test-catch-up-advances-cursor-to-next-cursor ()
  "每批都把游标推进到响应的 `:next-cursor'，终值为最后一批的 `next_cursor'。
第二批的请求 `since' 即第一批的 `next_cursor'（分页靠它前进）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 4 "uid-a" "create" "a.org")) 4 t)
                (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 7 "uid-b" "create" "b.org")) 7)))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-ok "aaa")
                (seshat-sync-test--file-ok "bbb")))
    (seshat-sync--catch-up)
    (should (= 7 (seshat-state-cursor)))
    (should (equal '("0" "4")
                   (mapcar (lambda (call)
                             (seshat-sync-test--param call "since"))
                           (seshat-sync-test--changes-calls))))))

(ert-deftest seshat-sync-test-catch-up-replay-is-idempotent ()
  "幂等重放：同一批事件连续跑两次 `--catch-up'（中途把游标重置为 0），
状态库的 `:uids' 与 `:paths' 完全一致、无重复条目，且第二次不再下载。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-ok "aaa")
                (seshat-sync-test--file-ok "bbb")))
    (let ((pages (lambda ()
                   (list (seshat-sync-test--changes-page
                          (list (seshat-sync-test--change 1 "uid-a" "create" "a.org")
                                (seshat-sync-test--change 2 "uid-b" "create" "b.org"))
                          2)))))
      (setq seshat-sync-test--changes (funcall pages))
      (seshat-sync--catch-up)
      (let* ((first (copy-tree (seshat-state--ensure)))
             (downloads-after-first (length (seshat-sync-test--download-calls))))
        (should (= 2 downloads-after-first))
        ;; 模拟「游标被重置」（例如状态文件被回滚）后重放同一批事件
        (seshat-state-set-cursor 0)
        (setq seshat-sync-test--changes (funcall pages))
        (seshat-sync--catch-up)
        (should (equal (plist-get first :uids)
                       (plist-get (seshat-state--ensure) :uids)))
        (should (equal (plist-get first :paths)
                       (plist-get (seshat-state--ensure) :paths)))
        ;; 内容未变（blob 与 base-blob 相同 + 本地文件仍在）→ 不再下载
        (should (= downloads-after-first
                   (length (seshat-sync-test--download-calls))))
        ;; 条目没有重复：uid 计数仍为 2
        (should (= 2 (length (plist-get (seshat-state--ensure) :uids))))))))

(ert-deftest seshat-sync-test-catch-up-fills-missing-index-entry ()
  "索引缺失的条目由 changes 事件补齐（兜底方向：索引缺 → changes 补）。
构造 F7 的典型情形：预建索引因同秒跳过而少了 uid-b。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    ;; 预建索引只登记了 uid-a
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 500)))))
    (seshat-sync--build-index)
    (should (seshat-state-path-for-uid "uid-a"))
    (should-not (seshat-state-path-for-uid "uid-b"))
    ;; changes 追平带来 uid-b（索引里没有的那一条）
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 1 "uid-b" "create" "b.org")) 1)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "bbb")))
    (seshat-sync--catch-up)
    (should (equal (cons "notes" "b.org")
                   (seshat-state-path-for-uid "uid-b")))
    (should (equal "uid-b" (seshat-state-uid-for-path "notes" "b.org")))
    ;; 已在索引里的条目不受影响
    (should (equal (cons "notes" "a.org")
                   (seshat-state-path-for-uid "uid-a")))))

(ert-deftest seshat-sync-test-catch-up-saves-once-per-batch ()
  "每批结束（批量块退出后）调用一次 `seshat-state-save'：计数 = 批数。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 1 "uid-a" "create" "a.org")) 1 t)
                (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 2 "uid-b" "create" "b.org")) 2 t)
                (seshat-sync-test--changes-page nil 3)))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-ok "aaa")
                (seshat-sync-test--file-ok "bbb")))
    (let ((stats (seshat-sync--catch-up)))
      (should (= 3 (plist-get stats :batches)))
      (should (= 3 seshat-sync-test--saves))
      ;; 落盘内容自洽：重新加载不应触发「:paths 与 :uids 不一致」的告警
      (setq seshat-state--state nil)
      (seshat-state-load)
      (should (= 3 (seshat-state-cursor)))
      (should-not (seshat-sync-test--warnings-matching "不一致")))))

(ert-deftest seshat-sync-test-catch-up-stops-on-non-2xx ()
  "非 2xx：停止循环（不重试），游标停在上一批，返回已完成的统计。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 5 "uid-a" "create" "a.org")) 5 t)
                (list :status 500 :headers nil :body "")))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "aaa")))
    (let ((stats (seshat-sync--catch-up)))
      ;; 只有两次请求：第二批失败后不再重试
      (should (= 2 (length (seshat-sync-test--changes-calls))))
      (should (= 1 (plist-get stats :batches)))
      (should (= 1 (plist-get stats :events)))
      (should (= 1 (plist-get stats :cool)))
      ;; 失败批次不推进游标：停在上一批的 next_cursor
      (should (= 5 (seshat-state-cursor)))
      (should (= 1 seshat-sync-test--saves))
      (should (equal 1 (length (seshat-sync-test--warnings-matching
                                "请求失败")))))))

(ert-deftest seshat-sync-test-catch-up-stops-on-transport-failure ()
  "传输层失败（无状态码）：同样只警告一次就停，游标保持 0、事件一条不应用。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (list :status nil :error 'connection-failed :message "boom")
                (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 1 "uid-a" "create" "a.org")) 1)))
    (let ((stats (seshat-sync--catch-up)))
      (should (= 1 (length (seshat-sync-test--changes-calls))))
      (should (= 0 (plist-get stats :batches)))
      (should (= 0 (plist-get stats :events)))
      (should (= 0 (plist-get stats :cool)))
      (should (= 0 (seshat-state-cursor)))
      (should (= 0 seshat-sync-test--saves))
      (should-not (seshat-sync-test--download-calls))
      (should (= 1 (length (seshat-sync-test--warnings-matching
                            "请求失败")))))))

(ert-deftest seshat-sync-test-catch-up-writes-cursor-after-apply ()
  "游标后写：第 2 个事件应用时抛错 → 游标未被推进（仍为 0）、未落盘，
且错误向上传播（`seshat-state-batch' 的 `unwind-protect' 重建索引后重抛）。
第 1 个事件已应用——这正是「重放该批幂等」的前提。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 1 "uid-a" "create" "a.org")
                       (seshat-sync-test--change 2 "uid-b" "create" "b.org"))
                 2 t)))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-ok "aaa")
                (seshat-sync-test--file-ok "bbb")))
    (let ((applied 0)
          (real-apply (symbol-function 'seshat-sync--apply-event)))
      (cl-letf (((symbol-function 'seshat-sync--apply-event)
                 (lambda (event)
                   (setq applied (1+ applied))
                   (when (= applied 2)
                     (error "应用第 2 个事件时中断"))
                   (funcall real-apply event))))
        (should-error (seshat-sync--catch-up) :type 'error)))
    ;; 游标停在 0：本批的 set-cursor 从未执行
    (should (= 0 (seshat-state-cursor)))
    (should (= 0 seshat-sync-test--saves))
    ;; 第 1 个事件已落地，整批重放时它会被幂等覆盖
    (should (equal (cons "notes" "a.org")
                   (seshat-state-path-for-uid "uid-a")))
    (should-not (seshat-state-path-for-uid "uid-b"))))

(ert-deftest seshat-sync-test-catch-up-stops-when-cursor-does-not-advance ()
  "前进性守卫：`:has-more' 为真但 `next_cursor' 没有前进（畸形响应）时停止，
绝不空转重拉同一批（否则就是无限循环）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 0 "uid-a" "create" "a.org")) 0 t)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "aaa")))
    (let ((stats (seshat-sync--catch-up)))
      ;; 只拉了一次：第二轮就会用同一个 since 重拉，必须被守卫拦住
      (should (= 1 (length (seshat-sync-test--changes-calls))))
      (should (= 1 (plist-get stats :batches)))
      (should (= 1 (plist-get stats :cool)))
      (should (= 0 (seshat-state-cursor)))
      (should (equal 1 (length (seshat-sync-test--warnings-matching
                                "游标未前进")))))))

(ert-deftest seshat-sync-test-catch-up-advances-cursor-for-skipped-events ()
  "被跳过的事件（未知 op）仍计入 `:events' 但不计入 `:cool'，游标照样前进：
否则同一批会被反复重放。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 3 "uid-a" "rescan" "a.org")) 3)))
    (let ((stats (seshat-sync--catch-up)))
      (should (= 1 (plist-get stats :events)))
      (should (= 0 (plist-get stats :cool)))
      (should (= 3 (seshat-state-cursor)))
      (should (= 1 seshat-sync-test--saves))
      (should (= 1 (length (seshat-sync-test--warnings-matching "未知 op")))))))

;;; T1d：增量循环（`seshat-sync--pull-changes'）

(ert-deftest seshat-sync-test-pull-changes-starts-from-state-cursor ()
  "增量只拉 `seq > cursor'：首个请求的 `since' 就是状态库里的游标。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-state-set-cursor 42)
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 43 "uid-a" "create" "a.org")) 43)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "aaa")))
    (seshat-sync--pull-changes)
    (should (equal "42" (seshat-sync-test--param
                         (car (seshat-sync-test--changes-calls)) "since")))
    (should (= 43 (seshat-state-cursor)))
    (should (equal (cons "notes" "a.org")
                   (seshat-state-path-for-uid "uid-a")))))

(ert-deftest seshat-sync-test-pull-changes-refetches-immediately-without-sleep ()
  "`:has-more' 为真时立即再拉：两次传输调用，且全程不调 `sleep-for'。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-state-set-cursor 10)
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 11 "uid-a" "create" "a.org")) 11 t)
                (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 12 "uid-b" "create" "b.org")) 12)))
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--file-ok "aaa")
                (seshat-sync-test--file-ok "bbb")))
    (seshat-sync-test--without-sleep
      (let ((stats (seshat-sync--pull-changes)))
        (should (= 2 (plist-get stats :batches)))
        (should (= 2 (plist-get stats :events)))
        (should (= 2 (plist-get stats :cool)))))
    (should (= 2 (length (seshat-sync-test--changes-calls))))
    (should (= 12 (seshat-state-cursor)))
    (should (equal '("10" "11")
                   (mapcar (lambda (call)
                             (seshat-sync-test--param call "since"))
                           (seshat-sync-test--changes-calls))))))

(ert-deftest seshat-sync-test-pull-changes-persists-cursor ()
  "游标推进到 `:next-cursor' 并落盘：清空内存状态后重新加载仍是新值。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-state-set-cursor 100)
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 120 "uid-a" "create" "a.org")) 120)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "aaa")))
    (seshat-sync--pull-changes)
    (should (= 120 (seshat-state-cursor)))
    (setq seshat-state--state nil)
    (seshat-state-load)
    (should (= 120 (seshat-state-cursor)))
    (should (equal (cons "notes" "a.org")
                   (seshat-state-path-for-uid "uid-a")))))

(ert-deftest seshat-sync-test-pull-changes-resumes-after-interruption ()
  "中断重放：第一批落盘后第二批抛错，从落盘游标重跑 → 结果与一次跑完相同。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-state-set-cursor 5)
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 6 "uid-a" "create" "a.org")) 6 t)
                (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 7 "uid-b" "create" "b.org")) 7)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "aaa")))
    (let ((applied 0)
          (real-apply (symbol-function 'seshat-sync--apply-event)))
      (cl-letf (((symbol-function 'seshat-sync--apply-event)
                 (lambda (event)
                   (setq applied (1+ applied))
                   (when (= applied 2) (error "第二批中断"))
                   (funcall real-apply event))))
        (should-error (seshat-sync--pull-changes) :type 'error)))
    ;; 首批已落盘：游标 6，uid-a 已登记，uid-b 没有
    (should (= 6 (seshat-state-cursor)))
    (should (seshat-state-path-for-uid "uid-a"))
    (should-not (seshat-state-path-for-uid "uid-b"))
    ;; 从落盘游标重跑：只剩第二批事件
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 7 "uid-b" "create" "b.org")) 7)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "bbb")))
    (seshat-sync--pull-changes)
    (should (= 7 (seshat-state-cursor)))
    (let ((resumed (seshat-sync-test--projection)))
      (should (equal '(("uid-a" "notes" "a.org" "blob0")
                       ("uid-b" "notes" "b.org" "blob0"))
                     resumed))
      ;; 对照：清空状态后用一个批次一次跑完同样两条事件
      (when (file-exists-p seshat-state-file) (delete-file seshat-state-file))
      (setq seshat-state--state nil)
      (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
      (setq seshat-sync-test--changes
            (list (seshat-sync-test--changes-page
                   (list (seshat-sync-test--change 6 "uid-a" "create" "a.org")
                         (seshat-sync-test--change 7 "uid-b" "create" "b.org"))
                   7)))
      (setq seshat-sync-test--downloads
            (list (seshat-sync-test--file-ok "aaa")
                  (seshat-sync-test--file-ok "bbb")))
      (seshat-sync--catch-up)
      (should (equal resumed (seshat-sync-test--projection))))))

;;; T1d：`seshat-sync-pull' 的编排

(ert-deftest seshat-sync-test-pull-first-sync-builds-index-then-catch-up ()
  "首同步（cursor=0 且 uids 空）：先 `--build-index' 再 `--catch-up'，
两步都在 `--reset-read-only-roots' 之后。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-a" "a.org" 100)))))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 1 "uid-b" "create" "b.org")) 1)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "bbb")))
    (seshat-sync-test--with-call-log
      (let ((result (seshat-sync-pull)))
        (should (eq t (plist-get result :first-sync)))
        (should (eq t (plist-get result :configured)))
        (should (equal '(reset ensure-roots build-index catch-up)
                       (nreverse seshat-sync-test--calls)))
        ;; `:index' 是建索引的统计，`:changes' 是追平的统计
        (should (= 1 (plist-get (plist-get result :index) :items)))
        (should (= 1 (plist-get (plist-get result :changes) :batches)))
        ;; 索引与追平都生效
        (should (equal (cons "notes" "a.org")
                       (seshat-state-path-for-uid "uid-a")))
        (should (equal (cons "notes" "b.org")
                       (seshat-state-path-for-uid "uid-b")))
        (should (= 1 (seshat-state-cursor)))))))

(ert-deftest seshat-sync-test-pull-incremental-skips-index ()
  "增量（已有 uid 登记或游标非 0）：不建索引，只调 `--pull-changes'。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    ;; 已有登记但不是首同步（游标非 0）
    (seshat-state-set "uid-a" (list :root "notes" :path "a.org"))
    (seshat-state-set-cursor 9)
    (setq seshat-sync-test--pages
          (list (seshat-sync-test--page
                 (list (seshat-sync-test--item "uid-z" "z.org" 100)))))
    (setq seshat-sync-test--changes
          (list (seshat-sync-test--changes-page
                 (list (seshat-sync-test--change 10 "uid-b" "create" "b.org")) 10)))
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-ok "bbb")))
    (seshat-sync-test--with-call-log
      (let ((result (seshat-sync-pull)))
        (should-not (plist-get result :first-sync))
        (should-not (plist-get result :index))
        (should (equal '(reset ensure-roots pull-changes)
                       (nreverse seshat-sync-test--calls)))
        (should-not (seshat-sync-test--resource-calls))
        (should (= 10 (seshat-state-cursor)))
        (should (equal (cons "notes" "b.org")
                       (seshat-state-path-for-uid "uid-b")))))))

(ert-deftest seshat-sync-test-pull-resets-read-only-roots ()
  "`seshat-sync-pull' 开头清空只读根缓存：上一轮的判定不得残留到本轮。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-state-set-cursor 1)
    (setq seshat-sync--read-only-roots '("books"))
    (should (seshat-sync--read-only-root-p "books"))
    (seshat-sync-test--with-call-log
      (seshat-sync-pull)
      (should (eq 'reset (car (last seshat-sync-test--calls))))
      (should-not (seshat-sync--read-only-root-p "books")))
    ;; 首同步路径同样先清缓存
    (setq seshat-state--state nil)
    (delete-file seshat-state-file)
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (setq seshat-sync--read-only-roots '("books"))
    (seshat-sync-test--with-call-log
      (seshat-sync-pull)
      (should (equal '(reset ensure-roots build-index catch-up)
                     (nreverse seshat-sync-test--calls)))
      (should-not (seshat-sync--read-only-root-p "books")))))

;;; push（T2）用的辅助

(defun seshat-sync-test--register (uid rel &optional base)
  "把 UID 登记为根 \"notes\" 下的 REL（可选 BASE 为 `:base-blob'），返回 UID.
只登记**位置与基线**，不标脏——是否待推送由用例显式决定。"
  (seshat-state-set uid (list :root "notes" :path rel :base-blob base))
  uid)

(defun seshat-sync-test--register-dirty (uid rel &optional base)
  "登记 UID → REL（可选 BASE 基线）并标记为 dirty，返回 UID."
  (seshat-sync-test--register uid rel base)
  (seshat-state-mark-dirty uid)
  uid)

(defun seshat-sync-test--calls-matching (method regexp)
  "按发生顺序返回 METHOD 与 URL 同时匹配的调用列表（REGEXP 匹配 URL）。"
  (cl-remove-if-not (lambda (call)
                      (and (equal method (nth 0 call))
                           (string-match-p regexp (nth 1 call))))
                    (reverse seshat-sync-test--requests)))

(defun seshat-sync-test--uploads ()
  "按发生顺序返回 `PUT /api/files' 的调用列表（推送请求）。"
  (seshat-sync-test--calls-matching "PUT" "/api/files/"))

(defun seshat-sync-test--version-calls ()
  "按发生顺序返回 `/api/versions' 的调用列表（取祖先）。"
  (seshat-sync-test--calls-matching "GET" "/api/versions/"))

(defun seshat-sync-test--header (call name)
  "返回被桩调用 CALL 的请求头 NAME 的值（字符串）；无该头时返回 nil.
NAME 用服务端写法（如 \"If-Match\"），比较时大小写不敏感。"
  (let ((headers (plist-get (nth 2 call) :headers)))
    (cdr (assoc name headers
                (lambda (a b) (equal (downcase a) (downcase b)))))))

(defun seshat-sync-test--upload-ok (etag)
  "构造 `PUT /api/files' 的成功响应，JSON 里带 ETAG 与一个提交 hash `rev'.
`rev' 故意与 ETAG 不同：用例断言 base blob 取的是 `:etag' 而**不是** `:rev'。"
  (list :status 200
        :headers nil
        :body (json-encode (list (cons 'uid "uid-a")
                                 (cons 'etag etag)
                                 (cons 'rev "deadbeefrev")))))

(defun seshat-sync-test--upload-status (status)
  "构造 `PUT /api/files' 的失败响应（STATUS 为 409 / 412 / 5xx 等）。"
  (list :status status
        :headers nil
        :body "{\"error\":{\"code\":\"x\"}}"))

(defun seshat-sync-test--download-ok (content etag)
  "构造 `GET /api/files' 的成功响应：远端内 CONTENT、响应头 ETag 为 ETAG."
  (list :status 200
        :headers (list (cons "ETag" etag))
        :body content))

(defun seshat-sync-test--versions-ok (content)
  "构造 `/api/versions' 的成功响应，`:content' 为 CONTENT（祖先版本内容）。"
  (list :status 200
        :headers nil
        :body (json-encode (list (cons 'head "") (cons 'content content)))))

(defun seshat-sync-test--file-size (rel)
  "返回临时目录下 REL 的字节数（`file-attributes' 第八项）。"
  (nth 7 (file-attributes (seshat-sync-test--local rel))))

(defun seshat-sync-test--file-mtime (rel)
  "返回临时目录下 REL 的 mtime（Unix 秒整数，与 push 写基线同口径）。"
  (truncate (float-time (nth 5 (file-attributes (seshat-sync-test--local rel))))))

;;; push：条件头

(ert-deftest seshat-sync-test-push-new-file-uses-if-none-match ()
  "无 `:base-blob' 时只发 `If-None-Match: *'（仅创建），不发 `If-Match'。
两个条件头并存会让服务端**恒回 412**（keystone 仓 docs/api.md §8.2）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "本地内容\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-ok "\"blob-new\"")))
    (let ((stats (seshat-sync-push))
          (uploads (seshat-sync-test--uploads)))
      (should (= 1 (length uploads)))
      (should (equal "*" (seshat-sync-test--header (car uploads) "If-None-Match")))
      (should-not (seshat-sync-test--header (car uploads) "If-Match"))
      (should (= 1 (plist-get stats :pushed))))))

(ert-deftest seshat-sync-test-push-existing-file-uses-if-match ()
  "有 `:base-blob' 时发 `If-Match: \"<blob>\"'（条件覆盖），不发 `If-None-Match'。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "改过的内容\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-ok "\"blob1\"")))
    (let ((stats (seshat-sync-push))
          (uploads (seshat-sync-test--uploads)))
      (should (= 1 (length uploads)))
      ;; `seshat-rest--etag-value' 对已带双引号的 blob 原样发送
      (should (equal "\"blob0\"" (seshat-sync-test--header (car uploads) "If-Match")))
      (should-not (seshat-sync-test--header (car uploads) "If-None-Match"))
      (should (= 1 (plist-get stats :pushed))))))

;;; push：成功路径

(ert-deftest seshat-sync-test-push-success-records-etag-as-base ()
  "2xx：base blob 取响应 `:etag'（**不是** `:rev'），size/mtime 取本地
`file-attributes'，dirty 清除，且基线落盘（重载状态仍在）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "本地内容\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-ok "\"blob-new\"")))
    (let ((stats (seshat-sync-push)))
      (should (= 1 (plist-get stats :pushed)))
      (let ((entry (seshat-state-get "uid-a")))
        (should (equal "\"blob-new\"" (plist-get entry :base-blob)))
        (should-not (equal "deadbeefrev" (plist-get entry :base-blob)))
        (should (equal (seshat-sync-test--file-size "a.org")
                       (plist-get entry :size)))
        (should (equal (seshat-sync-test--file-mtime "a.org")
                       (plist-get entry :mtime)))
        (should-not (plist-get entry :dirty)))
      (should-not (seshat-state-dirty-uids))
      ;; 基线已落盘：清空内存后重新加载仍是新 etag
      (setq seshat-state--state nil)
      (seshat-state-load)
      (should (equal "\"blob-new\""
                     (plist-get (seshat-state-get "uid-a") :base-blob)))
      (should-not (seshat-state-dirty-uids)))))

;;; push：412 → 合并 → 重发一次

;; 三方合并用的固定夹具：7 行文本，两侧改动各在一行、且**中间隔了两行未改动
;; 的内容**（L2 与 L5）。这不是凑数——`diff3' 对**相邻行**的改动会判为重叠
;; hunk 而报冲突，只有中间留出未改动的上下文才能得到干净合并（实测：3 行文本
;; 改第 2、3 行必冲突）。
(defconst seshat-sync-test--merge-base
  "l1\nl2\nl3\nl4\nl5\nl6\nl7\n"
  "412 合并用例的共同祖先内容。")

(defconst seshat-sync-test--merge-local
  "l1\nL2\nl3\nl4\nl5\nl6\nl7\n"
  "412 合并用例的本地（我方）内容：只改了第 2 行。")

(defconst seshat-sync-test--merge-remote
  "l1\nl2\nl3\nl4\nL5\nl6\nl7\n"
  "412 合并用例的远端（服务端）内容：只改了第 5 行。")

(defconst seshat-sync-test--merge-merged
  "l1\nL2\nl3\nl4\nL5\nl6\nl7\n"
  "上面三段内容的干净合并结果（两侧改动都在、无冲突标记）。")

(ert-deftest seshat-sync-test-push-412-clean-merge-retries-with-new-base ()
  "412 → 三方合并无冲突 → 本地被更新为合并结果 → 带**新 base** 重发一次.
队列顺序即请求顺序：PUT(412) → GET 远端 → PUT(成功)；祖先走 `versions'，
线缆参数名 `hash' 取**当前** base。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (let ((temporary-file-directory
           (file-name-as-directory
            (expand-file-name "tmproot" seshat-sync-test--dir))))
      (make-directory temporary-file-directory t)
      (seshat-sync-test--write-local "a.org" seshat-sync-test--merge-local)
      (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
      (setq seshat-sync-test--downloads
            (list (seshat-sync-test--upload-status 412)
                  (seshat-sync-test--download-ok seshat-sync-test--merge-remote "\"blob-remote\"")
                  (seshat-sync-test--upload-ok "\"blob-new\"")))
      (setq seshat-sync-test--versions
            (list (seshat-sync-test--versions-ok seshat-sync-test--merge-base)))
      (let ((stats (seshat-sync-push))
            (uploads (seshat-sync-test--uploads))
            (versions (seshat-sync-test--version-calls)))
        (should (= 1 (plist-get stats :pushed)))
        (should (= 0 (plist-get stats :conflicted)))
        ;; 重发只发生一次，且带的是**远端** etag（新 base），不是旧 base
        (should (= 2 (length uploads)))
        (should (equal "\"blob0\"" (seshat-sync-test--header (nth 0 uploads) "If-Match")))
        (should (equal "\"blob-remote\""
                       (seshat-sync-test--header (nth 1 uploads) "If-Match")))
        ;; 祖先用当前 base 作为 hash 查询
        (should (= 1 (length versions)))
        (should (equal "\"blob0\"" (seshat-sync-test--param (car versions) "hash")))
        ;; 本地文件被替换为合并结果（两侧改动都在）
        (should (equal seshat-sync-test--merge-merged
                       (seshat-sync-test--read-local "a.org")))
        ;; 基线更新、dirty 清除
        (let ((entry (seshat-state-get "uid-a")))
          (should (equal "\"blob-new\"" (plist-get entry :base-blob)))
          (should-not (plist-get entry :dirty)))
        ;; 临时目录（下载远端内容用）无残留
        (should (equal '("." "..")
                       (directory-files temporary-file-directory)))))))

(ert-deftest seshat-sync-test-push-412-retry-conflict-gives-up ()
  "412 → 合并无冲突 → 重发**仍** 412 → 放弃：不无限重试（PUT 次数 = 2）、
dirty 保留、计入 `:conflicted'。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" seshat-sync-test--merge-local)
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-status 412)
                (seshat-sync-test--download-ok seshat-sync-test--merge-remote "\"blob-remote\"")
                (seshat-sync-test--upload-status 412)))
    (setq seshat-sync-test--versions
          (list (seshat-sync-test--versions-ok seshat-sync-test--merge-base)))
    (let ((stats (seshat-sync-push)))
      (should (= 2 (length (seshat-sync-test--uploads))))
      (should (= 1 (plist-get stats :conflicted)))
      (should (= 0 (plist-get stats :pushed)))
      ;; dirty 必须保留，否则下一轮不再重试
      (should (equal '("uid-a") (seshat-state-dirty-uids)))
      ;; base 仍是旧值（没被误写成远端 etag）
      (should (equal "\"blob0\""
                     (plist-get (seshat-state-get "uid-a") :base-blob))))))

(ert-deftest seshat-sync-test-push-412-marks-written-back-keeps-dirty ()
  "412 → 合并**有冲突标记** → 把带标记的结果写回本地、保留 dirty、
计入 `:conflicted'，且全程**不调用任何交互函数**（可能由定时器触发）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "本地改动\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-status 412)
                (seshat-sync-test--download-ok "远端改动\n" "\"blob-remote\"")))
    (setq seshat-sync-test--versions
          (list (seshat-sync-test--versions-ok "原始内容\n")))
    (let ((asked nil))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (setq asked t) t))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t))
                ((symbol-function 'smerge-mode)
                 (lambda (&rest _) (setq asked t)))
                ((symbol-function 'pop-to-buffer)
                 (lambda (&rest _) (setq asked t))))
        (let ((stats (seshat-sync-push)))
          (should (= 1 (plist-get stats :conflicted)))
          ;; 只有一次 PUT：有冲突时不重发
          (should (= 1 (length (seshat-sync-test--uploads))))
          ;; 冲突标记已写回本地，用户下次打开即可 smerge
          (let ((content (seshat-sync-test--read-local "a.org")))
            (should (string-match-p "^<<<<<<<" content))
            (should (string-match-p "=======" content))
            (should (string-match-p "^>>>>>>>" content))
            (should (seshat-merge-conflicted-p content))
            (should (string-match-p "本地改动" content))
            (should (string-match-p "远端改动" content)))
          (should (equal '("uid-a") (seshat-state-dirty-uids)))
          (should (seshat-sync-test--warnings-matching "存在冲突"))))
      (should-not asked))))

(ert-deftest seshat-sync-test-push-412-download-failure-keeps-dirty ()
  "412 后拉远端内容失败 → 保留 dirty、计入 `:failed'，且不再去取祖先。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "本地改动\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-status 412)
                (seshat-sync-test--file-status 500)))
    (let ((stats (seshat-sync-push)))
      (should (= 1 (plist-get stats :failed)))
      (should (= 0 (plist-get stats :pushed)))
      (should (equal '("uid-a") (seshat-state-dirty-uids)))
      (should-not (seshat-sync-test--version-calls))
      ;; 本地内容不被改动（合并都没开始）
      (should (equal "本地改动\n" (seshat-sync-test--read-local "a.org"))))))

(ert-deftest seshat-sync-test-push-412-merge-failure-keeps-dirty ()
  "diff3 不可用（`seshat-merge--diff3' 返回 nil）→ 保留 dirty、计入 `:failed'，
且**不**写回本地（没有合并结果可写）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" seshat-sync-test--merge-local)
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-status 412)
                (seshat-sync-test--download-ok seshat-sync-test--merge-remote "\"blob-remote\"")))
    (setq seshat-sync-test--versions
          (list (seshat-sync-test--versions-ok seshat-sync-test--merge-base)))
    (cl-letf (((symbol-function 'seshat-merge--diff3) (lambda (&rest _) nil)))
      (let ((stats (seshat-sync-push)))
        (should (= 1 (plist-get stats :failed)))
        (should (equal '("uid-a") (seshat-state-dirty-uids)))
        (should (equal seshat-sync-test--merge-local
                       (seshat-sync-test--read-local "a.org")))
        (should (seshat-sync-test--warnings-matching "合并失败"))))))

;;; push：409 / 403 / 其它失败

(ert-deftest seshat-sync-test-push-409-not-retried ()
  "409（`state-conflict'）：**不重试**（PUT 次数 = 1）、保留 dirty、计入 `:failed'。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "内容\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads (list (seshat-sync-test--upload-status 409)))
    (let ((stats (seshat-sync-push)))
      (should (= 1 (length (seshat-sync-test--uploads))))
      (should (= 1 (plist-get stats :failed)))
      (should (equal '("uid-a") (seshat-state-dirty-uids)))
      (should (seshat-sync-test--warnings-matching "409")))))

(ert-deftest seshat-sync-test-push-403-marks-root-read-only ()
  "403（`root_read_only'）→ 根被标为只读，**同根其余条目被跳过**（只发 1 次
请求），两条 dirty 都保留。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "a\n")
    (seshat-sync-test--write-local "b.org" "b\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (seshat-sync-test--register-dirty "uid-b" "b.org" "\"blob0\"")
    (setq seshat-sync-test--downloads (list (seshat-sync-test--file-status 403)))
    (let ((stats (seshat-sync-push)))
      (should (= 1 (length (seshat-sync-test--uploads))))
      (should (seshat-sync--read-only-root-p "notes"))
      (should (= 2 (plist-get stats :skipped)))
      (should (equal '("uid-a" "uid-b") (seshat-state-dirty-uids)))
      ;; 只读根只警告一次，不刷屏
      (should (= 1 (length (seshat-sync-test--warnings-matching "只读")))))))

(ert-deftest seshat-sync-test-push-server-error-keeps-dirty ()
  "其它失败（5xx）→ 保留 dirty、计入 `:failed'，不重试。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "内容\n")
    (seshat-sync-test--register-dirty "uid-a" "a.org" "\"blob0\"")
    (setq seshat-sync-test--downloads (list (seshat-sync-test--upload-status 502)))
    (let ((stats (seshat-sync-push)))
      (should (= 1 (length (seshat-sync-test--uploads))))
      (should (= 1 (plist-get stats :failed)))
      (should (equal '("uid-a") (seshat-state-dirty-uids))))))

;;; push：只遍历 dirty、前置跳过

(ert-deftest seshat-sync-test-push-only-iterates-dirty-uids ()
  "只遍历 `dirty-uids'：未标脏的已登记 uid 不产生任何请求。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "clean.org" "clean\n")
    (seshat-sync-test--write-local "dirty.org" "dirty\n")
    (seshat-sync-test--register "uid-clean" "clean.org" "\"blob0\"")
    (seshat-sync-test--register-dirty "uid-dirty" "dirty.org" "\"blob0\"")
    (setq seshat-sync-test--downloads
          (list (seshat-sync-test--upload-ok "\"blob1\"")))
    (let ((stats (seshat-sync-push))
          (uploads (seshat-sync-test--uploads)))
      (should (= 1 (length uploads)))
      (should (string-match-p "dirty\\.org" (nth 1 (car uploads))))
      (should (= 1 (plist-get stats :pushed)))
      (should (= 1 (length seshat-sync-test--requests))))))

(ert-deftest seshat-sync-test-push-skips-missing-local-file ()
  "已登记但本地文件被外部删除 → 跳过并 warning，不产生请求。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--register-dirty "uid-a" "gone.org" "\"blob0\"")
    (let ((stats (seshat-sync-push)))
      (should-not (seshat-sync-test--uploads))
      (should (= 1 (plist-get stats :skipped)))
      (should (equal '("uid-a") (seshat-state-dirty-uids)))
      (should (seshat-sync-test--warnings-matching "不存在")))))

(ert-deftest seshat-sync-test-push-skips-escaping-path ()
  "路径越界（`../'）→ 跳过、不产生请求、不读写根外文件（安全底线）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--register-dirty "uid-a" "../escape.org" "\"blob0\"")
    (let ((stats (seshat-sync-push)))
      (should-not (seshat-sync-test--uploads))
      (should (= 1 (plist-get stats :skipped)))
      (should (equal '("uid-a") (seshat-state-dirty-uids)))
      (should (seshat-sync-test--warnings-matching "越界")))))

(ert-deftest seshat-sync-test-push-skips-ondemand-root ()
  "`ondemand' 根**绝不主动写**（计划 D7）：dirty 条目被跳过、不发请求。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "books" seshat-sync-test--dir "ondemand")))
    (seshat-sync-test--write-local "b.epub" "bytes\n")
    (seshat-state-set "uid-b" (list :root "books" :path "b.epub"
                                    :base-blob "\"blob0\""))
    (seshat-state-mark-dirty "uid-b")
    (let ((stats (seshat-sync-push)))
      (should-not (seshat-sync-test--uploads))
      (should (= 1 (plist-get stats :skipped)))
      (should (equal '("uid-b") (seshat-state-dirty-uids)))
      (should (seshat-sync-test--warnings-matching "ondemand")))))

;;; move / rename 检测（T3）用的辅助

(defun seshat-sync-test--register-baseline (uid rel &optional base)
  "把 UID 登记为根 \"notes\" 下的 REL，基线取该文件**当前**的 `(size, mtime)'.
与 push 写基线同源同口径（`file-attributes' + Unix 秒整数），因此「内容没变」
的条目在 move 检测里既不会被标脏、也具备 rename 配对所需的基线。"
  (seshat-state-set uid (list :root "notes"
                              :path rel
                              :base-blob (or base "\"blob0\"")
                              :size (seshat-sync-test--file-size rel)
                              :mtime (seshat-sync-test--file-mtime rel)))
  uid)

(defun seshat-sync-test--move-calls ()
  "按发生顺序返回 `POST /api/resources/{uid}/move' 的调用列表（实际入队的调用）."
  (seshat-sync-test--calls-matching "POST" "/move"))

(defun seshat-sync-test--move-uid (call)
  "返回被桩的 move 调用 CALL 的 URL 里携带的 uid。"
  (when (string-match "/api/resources/\\([^/]+\\)/move" (nth 1 call))
    (match-string 1 (nth 1 call))))

(defun seshat-sync-test--move-to (call)
  "返回被桩的 move 调用 CALL 的请求体里的 `to' 路径（服务端收到的目标路径）。"
  (let ((body (plist-get (nth 2 call) :body)))
    (cdr (assoc 'to (json-read-from-string body)))))

(defun seshat-sync-test--move-ok (from to)
  "构造 `POST …/move' 的成功响应（200），`:from' / `:to' 为移动前后路径。"
  (list :status 200
        :headers nil
        :body (json-encode (list (cons 'uid "uid-a")
                                 (cons 'from from)
                                 (cons 'to to)))))

(defun seshat-sync-test--move-status (status)
  "构造 `POST …/move' 的失败响应（STATUS 为 409 / 403 / 5xx 等）。"
  (list :status status
        :headers nil
        :body "{\"error\":{\"code\":\"x\"}}"))

(defun seshat-sync-test--rename (from to)
  "把临时目录下的 FROM 物理改名为 TO（模拟用户的 `mv'），返回 TO 的绝对路径。"
  (let ((target (seshat-sync-test--local to)))
    (rename-file (seshat-sync-test--local from) target)
    target))

;;; move 检测：第 2 步（本地内容修改 → 标脏，push 的唯一输入来源）

(ert-deftest seshat-sync-test-detect-edits-marks-dirty ()
  "第 2 步：已登记 uid 的本地内容变化（`(size, mtime)' 与基线不同）→ 该 uid 出现在
`dirty-uids'，且**不**被判为 rename（本地文件仍在原路径），全程零请求。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a.org" "原始\n")
    (seshat-sync-test--register-baseline "uid-a" "a.org")
    (should-not (seshat-state-dirty-uids))
    ;; 本地编辑：内容变长（size 必然不同）——没有第 2 步就永远不会被推送
    (seshat-sync-test--write-local "a.org" "被本地编辑过的更长的内容\n")
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (plist-get stats :scanned-roots)))
      (should (= 1 (plist-get stats :dirty-marked)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :conflict)))
      (should (= 0 (plist-get stats :skipped)))
      (should (= 0 (plist-get stats :failed)))
      (should (= 0 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :appeared)))
      (should (equal '("uid-a") (seshat-state-dirty-uids)))
      ;; 路径未变（不是 rename）
      (should (equal (cons "notes" "a.org")
                     (seshat-state-path-for-uid "uid-a")))
      ;; 标脏是纯本地动作：不碰网络、不上报
      (should-not seshat-sync-test--requests))))

(ert-deftest seshat-sync-test-detect-edits-same-stats-not-dirty ()
  "第 2 步：`(size, mtime)' 与基线**相同** → 不标脏；已有 dirty 也**不被清除**
（dirty 可能来自上次推送失败，清了就永远不会重推）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "clean.org" "干净\n")
    (seshat-sync-test--register-baseline "uid-clean" "clean.org")
    (seshat-sync-test--write-local "dirty.org" "待推送\n")
    (seshat-sync-test--register-baseline "uid-dirty" "dirty.org")
    (seshat-state-mark-dirty "uid-dirty")
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (plist-get stats :scanned-roots)))
      (should (= 0 (plist-get stats :dirty-marked)))
      (should (= 0 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :appeared)))
      (should (equal '("uid-dirty") (seshat-state-dirty-uids)))
      (should-not seshat-sync-test--requests))))

;;; move 检测：第 3 步（消失 / 新增 / rename 配对）

(ert-deftest seshat-sync-test-detect-rename-paired-by-size-and-mtime ()
  "本地改名（`size' 与 `mtime' 都相同）→ 上报 `move-resource (uid to)'、`state-remap'
生效、该 uid 标脏、计入 `:renamed'；消失与新增都不再单独计数。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "同样的内容\n")
    (seshat-sync-test--register-baseline "uid-a" "old.org")
    ;; 用户用 mv 改名：内容不变 → size 与 mtime 都不变
    (seshat-sync-test--rename "old.org" "new.org")
    (setq seshat-sync-test--moves
          (list (seshat-sync-test--move-ok "old.org" "new.org")))
    (let ((stats (seshat-sync-detect-renames))
          (calls (seshat-sync-test--move-calls)))
      (should (= 1 (length calls)))
      ;; 服务端收到的是「uid + 目标路径」，且是 POST …/move（两位置参数、非 cons）
      (should (equal "uid-a" (seshat-sync-test--move-uid (car calls))))
      (should (equal "new.org" (seshat-sync-test--move-to (car calls))))
      (should (= 1 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :conflict)))
      (should (= 0 (plist-get stats :skipped)))
      (should (= 0 (plist-get stats :failed)))
      (should (= 0 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :appeared)))
      ;; state-remap 生效：uid 换到新路径，旧路径不再指向它
      (should (equal (cons "notes" "new.org")
                     (seshat-state-path-for-uid "uid-a")))
      (should-not (seshat-state-uid-for-path "notes" "old.org"))
      (should (equal "uid-a" (seshat-state-uid-for-path "notes" "new.org")))
      ;; 新路径的内容仍需 push 确认一次 → 标脏（保守）
      (should (equal '("uid-a") (seshat-state-dirty-uids))))))

(ert-deftest seshat-sync-test-detect-rename-size-differs-not-paired ()
  "本地改名但 **size** 不同 → 不判 rename（计入 `:vanished' + `:appeared'，无 move 请求）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "短\n")
    (seshat-sync-test--register-baseline "uid-a" "old.org")
    (seshat-sync-test--rename "old.org" "new.org")
    ;; 改名后又编辑：size 变了，判据不成立
    (seshat-sync-test--write-local "new.org" "改名之后又被编辑得明显更长的内容\n")
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 1 (plist-get stats :vanished)))
      (should (= 1 (plist-get stats :appeared)))
      (should-not (seshat-sync-test--move-calls))
      (should-not seshat-sync-test--requests)
      ;; 既不 remap 也不新建登记
      (should (equal (cons "notes" "old.org")
                     (seshat-state-path-for-uid "uid-a")))
      (should-not (seshat-state-uid-for-path "notes" "new.org"))
      (should-not (seshat-state-dirty-uids)))))

(ert-deftest seshat-sync-test-detect-rename-mtime-differs-not-paired ()
  "本地改名但 **mtime** 不同（size 相同）→ 同样不判 rename。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "同样的长度\n")
    (seshat-sync-test--register-baseline "uid-a" "old.org")
    (let ((target (seshat-sync-test--rename "old.org" "new.org")))
      ;; 只动 mtime，size 保持不变
      (set-file-times target (seconds-to-time 1600000000)))
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 1 (plist-get stats :vanished)))
      (should (= 1 (plist-get stats :appeared)))
      (should-not (seshat-sync-test--move-calls))
      (should (equal (cons "notes" "old.org")
                     (seshat-state-path-for-uid "uid-a"))))))

(ert-deftest seshat-sync-test-detect-two-renames-paired-independently ()
  "两组 rename 同时发生 → 各自配对正确，不交叉错配（按 size 唯一区分）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "a1.org" "AAAA\n")          ; 5 字节
    (seshat-sync-test--write-local "b1.org" "BBBBBBBBBBBB\n")  ; 13 字节
    (seshat-sync-test--register-baseline "uid-a" "a1.org")
    (seshat-sync-test--register-baseline "uid-b" "b1.org")
    (seshat-sync-test--rename "a1.org" "a2.org")
    (seshat-sync-test--rename "b1.org" "b2.org")
    (setq seshat-sync-test--moves
          (list (seshat-sync-test--move-ok "a1.org" "a2.org")
                (seshat-sync-test--move-ok "b1.org" "b2.org")))
    (let ((stats (seshat-sync-detect-renames))
          (calls (seshat-sync-test--move-calls)))
      (should (= 2 (length calls)))
      (should (equal '(("uid-a" . "a2.org") ("uid-b" . "b2.org"))
                     (mapcar (lambda (call)
                               (cons (seshat-sync-test--move-uid call)
                                     (seshat-sync-test--move-to call)))
                             calls)))
      (should (= 2 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :appeared)))
      (should (equal '("uid-a" "uid-b") (seshat-state-dirty-uids)))
      (should (equal (cons "notes" "a2.org")
                     (seshat-state-path-for-uid "uid-a")))
      (should (equal (cons "notes" "b2.org")
                     (seshat-state-path-for-uid "uid-b"))))))

(ert-deftest seshat-sync-test-detect-move-409-not-retried ()
  "`move-resource' 返回 409 → **不重试**（只调用 1 次）、**不** remap、计入
`:conflict'、有 warning（建议 rescan：物理移动可能已完成）。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "同样的内容\n")
    (seshat-sync-test--register-baseline "uid-a" "old.org")
    (seshat-sync-test--rename "old.org" "new.org")
    (setq seshat-sync-test--moves (list (seshat-sync-test--move-status 409)))
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (length (seshat-sync-test--move-calls))))
      (should (= 1 (plist-get stats :conflict)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :failed)))
      ;; 不 remap：本地状态与服务端真实状态此刻不一致，贸然改会让下轮推错位置
      (should (equal (cons "notes" "old.org")
                     (seshat-state-path-for-uid "uid-a")))
      (should-not (seshat-state-uid-for-path "notes" "new.org"))
      ;; 也不标脏（本轮未确认改名成功）
      (should-not (seshat-state-dirty-uids))
      (should (seshat-sync-test--warnings-matching "409")))))

(ert-deftest seshat-sync-test-detect-move-403-marks-root-read-only ()
  "`move-resource' 返回 403（`root_read_only'）→ 标记只读根、计入 `:skipped'、不 remap。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "同样的内容\n")
    (seshat-sync-test--register-baseline "uid-a" "old.org")
    (seshat-sync-test--rename "old.org" "new.org")
    (setq seshat-sync-test--moves (list (seshat-sync-test--move-status 403)))
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (plist-get stats :skipped)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :failed)))
      (should (seshat-sync--read-only-root-p "notes"))
      ;; 只读根只警告一次（与其他三处共用 `seshat-sync--mark-root-read-only'）
      (should (= 1 (length (seshat-sync-test--warnings-matching "只读"))))
      (should (equal (cons "notes" "old.org")
                     (seshat-state-path-for-uid "uid-a"))))))

(ert-deftest seshat-sync-test-detect-move-other-error-counts-failed ()
  "其它失败（5xx）→ 计入 `:failed'、不重试、不 remap。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "old.org" "同样的内容\n")
    (seshat-sync-test--register-baseline "uid-a" "old.org")
    (seshat-sync-test--rename "old.org" "new.org")
    (setq seshat-sync-test--moves (list (seshat-sync-test--move-status 502)))
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (length (seshat-sync-test--move-calls))))
      (should (= 1 (plist-get stats :failed)))
      (should (= 0 (plist-get stats :renamed)))
      (should (equal (cons "notes" "old.org")
                     (seshat-state-path-for-uid "uid-a")))
      (should (seshat-sync-test--warnings-matching "上报失败")))))

(ert-deftest seshat-sync-test-detect-unpaired-vanish-keeps-files-silent ()
  "未配对的消失 → 不删除本地任何文件、不产生任何请求、不标墓碑、计入 `:vanished'。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    ;; 仍在本地且基线一致的条目（用来证明「消失」不会连带删除别的文件）
    (seshat-sync-test--write-local "keep.org" "保留\n")
    (seshat-sync-test--register-baseline "uid-keep" "keep.org")
    ;; 已登记但本地文件消失（内容与某个新出现的文件并不相同 → 不配对）
    (seshat-state-set "uid-gone" (list :root "notes" :path "gone.org"
                                       :base-blob "\"blob0\""
                                       :size 7 :mtime 1760785200))
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :appeared)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :dirty-marked)))
      (should-not seshat-sync-test--requests)
      ;; 本地文件一个不少
      (should (equal "保留\n" (seshat-sync-test--read-local "keep.org")))
      ;; 不上报删除、不标墓碑（删除只由服务端 `delete' 事件驱动，见 T1b）
      (should-not (seshat-state-deleted-uids))
      (should (equal (cons "notes" "gone.org")
                     (seshat-state-path-for-uid "uid-gone"))))))

(ert-deftest seshat-sync-test-detect-unpaired-appear-does-nothing ()
  "未配对的新增 → 不创建、不上报、不标脏，只计入 `:appeared'；本地文件原样保留。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    (seshat-sync-test--write-local "new.org" "用户新写的\n")
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 1 (plist-get stats :appeared)))
      (should (= 0 (plist-get stats :renamed)))
      (should (= 0 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :dirty-marked)))
      (should-not seshat-sync-test--requests)
      ;; 不建登记（新文件由用户保存时标脏 + push 建立），也不标脏
      (should-not (seshat-state-uid-for-path "notes" "new.org"))
      (should-not (seshat-state-dirty-uids))
      ;; 本地文件集合不变（没有多出任何文件；状态文件本身不算）
      (should (equal '("." ".." "new.org")
                     (sort (cl-remove-if (lambda (file)
                                           (string-prefix-p "sync-state" file))
                                         (directory-files seshat-sync-test--dir))
                           #'string<)))
      (should (equal "用户新写的\n" (seshat-sync-test--read-local "new.org"))))))

(ert-deftest seshat-sync-test-detect-only-scans-mirror-roots ()
  "只扫 `mode' = `mirror' 的根：`ondemand' 根里的文件既不计入 `:appeared'，
也不会把该根的已登记 uid 标脏（不 `stat'、不扫目录）。"
  (seshat-sync-test--with-state
    (let ((mirror-dir (expand-file-name "notes" seshat-sync-test--dir))
          (books-dir (expand-file-name "books" seshat-sync-test--dir)))
      (make-directory mirror-dir t)
      (seshat-state-set-roots (list (list "notes" mirror-dir "mirror")
                                    (list "books" books-dir "ondemand")))
      ;; ondemand 根下：一个已登记的文件（基线故意给错，若被扫就会标脏）
      (seshat-sync-test--write-local "books/b.epub" "bytes\n")
      (seshat-state-set "uid-b" (list :root "books" :path "b.epub"
                                      :base-blob "\"blob0\""
                                      :size 0 :mtime 0))
      ;; ondemand 根下：一个未登记的文件（若被扫就会计入 `:appeared'）
      (seshat-sync-test--write-local "books/c.epub" "other bytes\n")
      (let ((stats (seshat-sync-detect-renames)))
        (should (= 1 (plist-get stats :scanned-roots)))
        (should (= 0 (plist-get stats :appeared)))
        (should (= 0 (plist-get stats :vanished)))
        (should (= 0 (plist-get stats :dirty-marked)))
        (should-not (seshat-state-dirty-uids))
        (should-not seshat-sync-test--requests)
        ;; ondemand 条目位置不变、也没被判为消失
        (should (equal (cons "books" "b.epub")
                       (seshat-state-path-for-uid "uid-b")))))))

(ert-deftest seshat-sync-test-detect-skips-tombstones ()
  "墓碑条目（`:deleted-at' 非 nil）不参与消失判定、不被标 dirty、不产生请求。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" seshat-sync-test--dir "mirror")))
    ;; 墓碑：本地文件已不存在，基线故意给错（若被 stat 就会标脏）
    (seshat-state-set "uid-dead" (list :root "notes" :path "dead.org"
                                       :base-blob "\"blob0\""
                                       :size 100 :mtime 200))
    (seshat-state-mark-deleted "uid-dead")
    ;; 另一条墓碑：本地文件存在（路径已不占索引，但也不得标脏）
    (seshat-sync-test--write-local "dead2.org" "残留\n")
    (seshat-state-set "uid-dead2" (list :root "notes" :path "dead2.org"
                                        :base-blob "\"blob0\""
                                        :size 0 :mtime 0))
    (seshat-state-mark-deleted "uid-dead2")
    (let ((stats (seshat-sync-detect-renames)))
      (should (= 0 (plist-get stats :vanished)))
      (should (= 0 (plist-get stats :dirty-marked)))
      ;; `dead2.org' 在本地但不占索引 → 只算「新增」，不产生请求
      (should (= 1 (plist-get stats :appeared)))
      (should (= 0 (plist-get stats :renamed)))
      (should-not seshat-sync-test--requests)
      (should (equal '("uid-dead" "uid-dead2") (seshat-state-deleted-uids)))
      (should-not (plist-get (seshat-state-get "uid-dead") :dirty))
      (should-not (plist-get (seshat-state-get "uid-dead2") :dirty)))))

;;; 根映射初始化：`seshat-sync-roots' → `seshat-state-roots'
;;
;; 这一节覆盖「生产环境没有任何代码填充 `seshat-state-roots'」这个缺口：
;; `seshat-sync--ensure-roots' 是唯一的生产填充路径，`seshat-sync-pull' 在
;; 只读根重置之后、首同步判定之前调用它；未配置时 pull 必须提前返回而不是空转。

(defun seshat-sync-test--roots-requests ()
  "按发生顺序返回 `/api/roots' 的调用列表。"
  (cl-remove-if-not (lambda (call)
                      (string-match-p "/api/roots" (nth 1 call)))
                    (reverse seshat-sync-test--requests)))

(defun seshat-sync-test--expand (rel)
  "返回临时目录下相对路径 REL 的 `expand-file-name' 结果（不补结尾斜杠）。"
  (expand-file-name rel seshat-sync-test--dir))

(ert-deftest seshat-sync-test-ensure-roots-returns-existing-without-request ()
  "`state :roots' 已非空 → 直接返回，不请求 `/api/roots'、不落盘。
每次 pull 都会调用本函数，重复请求既慢也会覆盖用户手设的映射。"
  (seshat-sync-test--with-state
    (seshat-state-set-roots (list (list "notes" "/tmp/notes" "mirror")))
    (let ((result (seshat-sync--ensure-roots)))
      (should (equal '(("notes" "/tmp/notes" "mirror")) result))
      (should (equal '(("notes" "/tmp/notes" "mirror")) (seshat-state-roots)))
      (should-not (seshat-sync-test--roots-requests))
      (should (= 0 seshat-sync-test--saves)))))

(ert-deftest seshat-sync-test-ensure-roots-uses-configured-modes ()
  "`state' 空 + 两项都显式给出 MODE → 不请求 `/api/roots'，两项写入 state 并落盘。
MODE 写入**字符串**（`seshat-state-roots' 的口径）：符号 `mirror' 必须归一，
否则 `seshat-sync--mirror-roots' 会把该根整根过滤掉。"
  (seshat-sync-test--with-state
    (let ((seshat-sync-roots (list (list "notes" (seshat-sync-test--expand "notes") 'mirror)
                                   (list "books" (seshat-sync-test--expand "books") 'ondemand))))
      (let ((result (seshat-sync--ensure-roots)))
        (should (equal (list (list "notes" (seshat-sync-test--expand "notes") "mirror")
                             (list "books" (seshat-sync-test--expand "books") "ondemand"))
                       result))
        (should (equal result (seshat-state-roots)))
        ;; 符号已归一为字符串：mirror 根能被子系统的口径认出来
        (should (equal '(("notes" "mirror")
                         ("books" "ondemand"))
                       (mapcar (lambda (root) (list (nth 0 root) (nth 2 root)))
                               result)))
        (should (= 1 (length (seshat-sync--mirror-roots))))
        (should-not (seshat-sync-test--roots-requests))
        (should (= 1 seshat-sync-test--saves))))))

(ert-deftest seshat-sync-test-ensure-roots-fills-mode-from-server-once ()
  "MODE 为 nil → 请求 `/api/roots' **一次**（多个待补共用同一响应），按 tag 补齐后写入。"
  (seshat-sync-test--with-state
    (setq seshat-sync-test--roots-response
          (seshat-sync-test--roots-body '(("notes" "mirror" t)
                                          ("books" "ondemand" nil))))
    (let ((seshat-sync-roots (list (list "notes" (seshat-sync-test--expand "notes") nil)
                                   (list "books" (seshat-sync-test--expand "books") nil))))
      (let ((result (seshat-sync--ensure-roots)))
        (should (= 1 (length (seshat-sync-test--roots-requests))))
        (should (equal (list (list "notes" (seshat-sync-test--expand "notes") "mirror")
                             (list "books" (seshat-sync-test--expand "books") "ondemand"))
                       result))
        (should (equal result (seshat-state-roots)))
        (should (= 1 seshat-sync-test--saves))))))

(ert-deftest seshat-sync-test-ensure-roots-skips-tag-missing-on-server ()
  "配置了服务端不存在的 tag → 该项跳过并警告，其余项照常写入。
服务端没有该 tag 时没有权威 mode，猜一个（比如默认 mirror）会把只读书库当成
可写根——宁可跳过并让用户看到警告。"
  (seshat-sync-test--with-state
    (setq seshat-sync-test--roots-response
          (seshat-sync-test--roots-body '(("notes" "mirror" t))))
    (let ((seshat-sync-roots (list (list "notes" (seshat-sync-test--expand "notes") 'mirror)
                                   (list "ghost" (seshat-sync-test--expand "ghost") nil))))
      (let ((result (seshat-sync--ensure-roots)))
        (should (equal (list (list "notes" (seshat-sync-test--expand "notes") "mirror"))
                       result))
        (should (equal result (seshat-state-roots)))
        ;; ghost 的 mode 待补 → 仍要问服务端一次（共用一次响应）
        (should (= 1 (length (seshat-sync-test--roots-requests))))
        (should (= 1 (length (seshat-sync-test--warnings-matching "ghost"))))
        (should (= 1 seshat-sync-test--saves))))))

(ert-deftest seshat-sync-test-ensure-roots-unconfigured-warns-and-writes-nothing ()
  "`seshat-sync-roots' 为空 → 返回 nil + 一次警告，不写 state、不请求 `/api/roots'。
「不猜目录」是硬约束：服务端根与本地目录的对应关系只有用户说得清。"
  (seshat-sync-test--with-state
    (let ((seshat-sync-roots nil))
      (should-not (seshat-sync--ensure-roots))
      (should-not (seshat-state-roots))
      (should-not (seshat-sync-test--roots-requests))
      (should (= 0 seshat-sync-test--saves))
      (should (= 1 (length (seshat-sync-test--warnings-matching
                            "未配置 `seshat-sync-roots'")))))))

(ert-deftest seshat-sync-test-pull-returns-early-when-roots-unconfigured ()
  "`--ensure-roots' 返回 nil 时 `seshat-sync-pull' 提前返回：不建索引、不追平、
不拉变更（桩断言三个后续步骤都未被调用）。"
  (seshat-sync-test--with-state
    (let ((seshat-sync-roots nil))
      (seshat-sync-test--with-call-log
        (let ((result (seshat-sync-pull)))
          (should-not (plist-get result :configured))
          (should-not (plist-get result :first-sync))
          (should-not (plist-get result :index))
          (should-not (plist-get result :changes))
          ;; 只发生了 reset 与（返回 nil 的）ensure-roots
          (should (equal '(reset ensure-roots)
                         (nreverse seshat-sync-test--calls)))
          ;; 零请求：连建索引的 `/api/resources' 都没发
          (should-not seshat-sync-test--requests)
          (should (= 0 (seshat-state-cursor)))
          (should (= 0 seshat-sync-test--saves)))))))

(ert-deftest seshat-sync-test-pull-ensures-roots-between-reset-and-index ()
  "成功路径：`--ensure-roots' 在 `--reset-read-only-roots' **之后**、
`--build-index' **之前**被调用，且本次 pull 就把根映射落进 state。
（顺序错误会让首同步在 roots 为空时建索引，或让只读根缓存跨轮残留。）"
  (seshat-sync-test--with-state
    (let ((seshat-sync-roots (list (list "notes" (seshat-sync-test--expand "notes") 'mirror))))
      (seshat-sync-test--with-call-log
        (let ((result (seshat-sync-pull)))
          (should (eq t (plist-get result :configured)))
          (should (eq t (plist-get result :first-sync)))
          (should (equal '(reset ensure-roots build-index catch-up)
                         (nreverse seshat-sync-test--calls)))
          ;; roots 已落盘，后续 status 的根解析才有依据
          (should (equal (list (list "notes" (seshat-sync-test--expand "notes") "mirror"))
                         (seshat-state-roots)))
          (should-not (seshat-sync-test--roots-requests))
          ;; 建索引确实按该根发起了 `/api/resources' 请求
          (should (= 1 (length (seshat-sync-test--resource-calls)))))))))

(provide 'seshat-sync-test)

;;; seshat-sync-test.el ends here
