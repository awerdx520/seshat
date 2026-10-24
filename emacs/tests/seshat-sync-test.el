;;; seshat-sync-test.el --- ERT tests for seshat-sync  -*- lexical-binding: t; -*-

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

;; `seshat-sync' 的 M8-B 引擎测试，当前覆盖 T1a（首同步：预建索引）：
;; `/api/resources' 分页 → 每页写入状态库 → 每页落盘一次。
;;
;; 全部用例**零网络**：统一桩替 `seshat-transport-request'（`seshat-rest' 的
;; 唯一出口），由被测代码真实走 `seshat-rest-list-resources' 的 URL 拼装与
;; JSON 解析，因此查询参数名（`root' / `since' / `limit'）与 `has_more' 语义都
;; 是真实实现的一部分，而不是被桩掉的口径。
;;
;; 状态库一律绑到临时目录里的 "sync-state.eld"，**绝不写用户的
;; `~/.local/share/seshat/'**；`seshat-state-save' 被桩成「计数 + 调真实实现」，
;; 用来断言「每页落盘一次」。`display-warning' 被桩成收集消息，避免测试输出
;; 噪音，同时可断言「只读根只警告一次」。

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

(defun seshat-sync-test--transport (method url &rest args)
  "桩替 `seshat-transport-request'：按 URL 返回排队响应，零网络.
`/api/roots' 返回 `seshat-sync-test--roots-response'；`/api/resources' 依次
消费 `seshat-sync-test--pages'，队列耗尽时回一个空页——既能让用例收尾，也能在
「本该终止却没终止」时避免测试挂死（用例改为断言请求次数来暴露问题）。"
  (push (list method url args) seshat-sync-test--requests)
  (cond
   ((string-match-p "/api/roots" url)
    (or seshat-sync-test--roots-response
        (list :status 200 :headers nil
              :body "{\"roots\":[]}")))
   ((string-match-p "/api/resources" url)
    (or (pop seshat-sync-test--pages)
        (list :status 200 :headers nil
              :body "{\"items\":[],\"has_more\":false}")))
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

(provide 'seshat-sync-test)

;;; seshat-sync-test.el ends here
