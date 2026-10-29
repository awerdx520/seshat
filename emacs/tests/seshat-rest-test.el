;;; seshat-rest-test.el --- ERT tests for seshat-rest  -*- lexical-binding: t; -*-

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

;; `seshat-rest' 新增端点（M8-A T2a：`seshat-rest-roots'、
;; `seshat-rest-list-resources'、`seshat-rest-get-resource'、
;; `seshat-rest-changes'）及其统一状态码解释器 `seshat-rest--interpret' 的
;; ERT 测试套件。
;;
;; 全部用例**绝不触网**：统一用 `cl-letf' 桩替 `seshat-transport-request'
;; （传输层出口），断言四件事——URL / 查询参数构造、JSON → plist 的字段映射、
;; 2xx 之外的状态码映射、传输失败的容错（返回 `:error' 而不抛错）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url-util)
(require 'json)
(require 'seshat-rest)

;;; 测试辅助

(defvar seshat-rest-test--captured nil
  "最近一次被桩的传输调用记录，形态为 (METHOD URL ARGS-PLIST)。")

(defun seshat-rest-test--respond (response)
  "返回一个桩函数：把调用记录写入 `seshat-rest-test--captured'，并返回 RESPONSE。"
  (lambda (method url &rest args)
    (setq seshat-rest-test--captured (list method url args))
    response))

(defmacro seshat-rest-test--with (response &rest body)
  "在桩替 `seshat-transport-request' 为返回 RESPONSE 的前提下执行 BODY。
桩替期间被调用的 METHOD / URL / ARGS 记录在 `seshat-rest-test--captured'。"
  (declare (indent 1))
  `(let ((seshat-rest-test--captured nil))
     (cl-letf (((symbol-function 'seshat-transport-request)
                (seshat-rest-test--respond ,response)))
       ,@body)))

(defun seshat-rest-test--ok (json &optional status)
  "构造一个成功传输响应 plist：状态码 STATUS（缺省 200）、响应体 JSON。"
  (list :status (or status 200)
        :headers '(("ETag" . "\"blob1\""))
        :body json))

(defun seshat-rest-test--captured-method ()
  "返回最近一次被桩调用的 HTTP 方法。"
  (nth 0 seshat-rest-test--captured))

(defun seshat-rest-test--captured-url ()
  "返回最近一次被桩调用的完整 URL。"
  (nth 1 seshat-rest-test--captured))

(defun seshat-rest-test--captured-args ()
  "返回最近一次被桩调用的关键字参数列表。"
  (nth 2 seshat-rest-test--captured))

(defun seshat-rest-test--query-params (url)
  "把 URL 的查询串解析为 ((NAME . VALUE)…)，键值均做 URL 解码。
返回的列表顺序无关紧要——调用方一律用 `assoc' 取值，因此断言不受键序影响。"
  (let ((start (string-match "\\?" url)))
    (when start
      (mapcar (lambda (pair)
                (let ((eq-pos (string-match "=" pair)))
                  (cons (url-unhex-string (substring pair 0 eq-pos))
                        (url-unhex-string (substring pair (1+ eq-pos))))))
              (split-string (substring url (1+ start)) "&" t)))))

(defconst seshat-rest-test--resource-json
  "{\"items\": [{\"uid\": \"01K8Q3M7D2X9V6T1B8N5C0RDEX\",
                 \"root\": \"notes\",
                 \"path\": \"journal/2026-10-18.org\",
                 \"kind\": \"file\",
                 \"blob\": \"9f2c1a\",
                 \"rev\": \"4b825dc\",
                 \"size\": 1024,
                 \"mtime\": 1760785200,
                 \"created_at\": \"2026-10-18T08:00:00Z\",
                 \"updated_at\": \"2026-10-18T11:00:00Z\",
                 \"deleted_at\": \"\"}],
    \"has_more\": true}"
  "`GET /api/resources' 的成功响应体样例（字段与 keystone 仓 docs/api.md §5.1 一致）。")

(defconst seshat-rest-test--change-json
  "{\"changes\": [{\"seq\": 1042,
                  \"uid\": \"01K8Q3M7D2X9V6T1B8N5C0RDEX\",
                  \"op\": \"rename\",
                  \"root\": \"notes\",
                  \"path\": \"journal/2026/2026-10-18.org\",
                  \"old_path\": \"journal/2026-10-18.org\",
                  \"blob\": \"\",
                  \"rev\": \"4b825dc\",
                  \"changed_at\": \"2026-10-18T11:00:00Z\"}],
    \"next_cursor\": 1042,
    \"has_more\": false}"
  "`GET /api/changes' 的成功响应体样例（字段与 keystone 仓 docs/api.md §9 一致）。")

;;; seshat-rest-roots

(ert-deftest seshat-rest-roots-requests-api-roots ()
  "`seshat-rest-roots' 发 GET /api/roots，不带任何查询参数，且带 Accept 头。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"roots\": []}")
    (seshat-rest-roots)
    (should (equal (seshat-rest-test--captured-method) "GET"))
    (should (equal (seshat-rest-test--captured-url)
                   "https://example.com/api/roots"))
    (should-not (string-match-p "\\?" (seshat-rest-test--captured-url)))
    (should (equal (cdr (assoc "Accept"
                               (plist-get (seshat-rest-test--captured-args)
                                          :headers)))
                   "application/json"))))

(ert-deftest seshat-rest-roots-maps-tag-mode-default ()
  "`seshat-rest-roots' 把每个根的 tag / mode / default 映射成 plist。
JSON 的 false 必须转成 nil（`json-parse-string' 读出的是符号 `:false'）。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       (concat "{\"roots\": ["
               "{\"tag\": \"notes\", \"mode\": \"mirror\", \"default\": true},"
               "{\"tag\": \"ebooks\", \"mode\": \"ondemand\", \"default\": false}"
               "]}"))
    (let ((result (seshat-rest-roots)))
      (should (equal (plist-get result :status) 200))
      (should (equal (plist-get result :roots)
                     '((:tag "notes" :mode "mirror" :default t)
                       (:tag "ebooks" :mode "ondemand" :default nil))))
      (should-not (plist-get result :error)))))

;;; seshat-rest-list-resources

(ert-deftest seshat-rest-list-resources-builds-query-params ()
  "`seshat-rest-list-resources' 把 root / prefix / limit 编码成查询参数。
断言用 `assoc' 取值，因此与查询串的键序无关；含 `/` 的 prefix 必须能正确解码。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"items\": [], \"has_more\": false}")
    (seshat-rest-list-resources :root "notes" :prefix "journal/2026" :limit 5)
    (let* ((url (seshat-rest-test--captured-url))
           (params (seshat-rest-test--query-params url)))
      (should (string-match-p "\\`https://example\\.com/api/resources\\?" url))
      (should (equal (cdr (assoc "root" params)) "notes"))
      (should (equal (cdr (assoc "prefix" params)) "journal/2026"))
      (should (equal (cdr (assoc "limit" params)) "5"))
      ;; 未给出的参数必须完全省略（交给服务端默认值），不能写成空串。
      (should-not (assoc "since" params))
      (should-not (assoc "include_deleted" params))
      (should (equal (length params) 3)))))

(ert-deftest seshat-rest-list-resources-since-mtime-goes-to-since-param ()
  "`seshat-rest-list-resources' 的 SINCE-MTIME（mtime 秒）出现在 `/api/resources`
的 `since' 参数上；取值为 0 时也必须发送（0 在 Lisp 里为真，不是「省略」）。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"items\": [], \"has_more\": false}")
    (seshat-rest-list-resources :since-mtime 1760785200)
    (let ((params (seshat-rest-test--query-params
                   (seshat-rest-test--captured-url))))
      (should (equal (cdr (assoc "since" params)) "1760785200")))
    (seshat-rest-list-resources :since-mtime 0)
    (should (equal (cdr (assoc "since"
                              (seshat-rest-test--query-params
                               (seshat-rest-test--captured-url))))
                   "0"))))

(ert-deftest seshat-rest-list-resources-include-deleted-is-true-only ()
  "`INCLUDE-DELETED' 非 nil 时发 `include_deleted=true'，nil 时省略该参数。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"items\": [], \"has_more\": false}")
    (seshat-rest-list-resources :include-deleted t)
    (should (equal (cdr (assoc "include_deleted"
                              (seshat-rest-test--query-params
                               (seshat-rest-test--captured-url))))
                   "true"))
    (seshat-rest-list-resources)
    (should-not (assoc "include_deleted"
                       (seshat-rest-test--query-params
                        (seshat-rest-test--captured-url))))))

(ert-deftest seshat-rest-list-resources-maps-items-and-has-more ()
  "`seshat-rest-list-resources' 把 items 转为 plist 列表，下划线键转 kebab-case，
`has_more' 转 `:has-more' 且 JSON true 变 t。"
  (seshat-rest-test--with
      (seshat-rest-test--ok seshat-rest-test--resource-json)
    (let* ((result (seshat-rest-list-resources))
           (item (car (plist-get result :items))))
      (should (equal (plist-get result :status) 200))
      (should (eq (plist-get result :has-more) t))
      (should (equal (length (plist-get result :items)) 1))
      (should (equal (plist-get item :uid) "01K8Q3M7D2X9V6T1B8N5C0RDEX"))
      (should (equal (plist-get item :root) "notes"))
      (should (equal (plist-get item :path) "journal/2026-10-18.org"))
      (should (equal (plist-get item :kind) "file"))
      (should (equal (plist-get item :size) 1024))
      (should (equal (plist-get item :mtime) 1760785200))
      ;; 下划线键 → kebab-case 关键字。
      (should (equal (plist-get item :created-at) "2026-10-18T08:00:00Z"))
      (should (equal (plist-get item :updated-at) "2026-10-18T11:00:00Z"))
      (should (equal (plist-get item :deleted-at) ""))
      (should-not (plist-member item :created_at))
      ;; 公开返回值不外泄内部取值字段。
      (should-not (plist-member result :json))
      (should-not (plist-member result :headers)))))

(ert-deftest seshat-rest-list-resources-has-more-false-becomes-nil ()
  "JSON `has_more: false' 转成 nil（不是符号 `:false'）。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"items\": [], \"has_more\": false}")
    (let ((result (seshat-rest-list-resources)))
      (should-not (plist-get result :has-more))
      (should (eq (plist-get result :has-more) nil))
      (should-not (plist-get result :items)))))

;;; JSON 字面量规整（false / null → nil）

(ert-deftest seshat-rest-json-plist-normalizes-json-literals ()
  "`seshat-rest--json-plist' 把 JSON false / null 一律转成 nil、true 转成 t。
`json-parse-string' 把 false 读成符号 `:false'、null 读成 `:null'（两者都是非 nil
真值），若原样落进 plist，`changes' / `resources' 将来新增的 boolean 字段会被
静默误判为真。"
  (seshat-rest-test--with
      (seshat-rest-test--ok "{\"flag\": false, \"on\": true, \"missing\": null}")
    (let* ((result (seshat-rest-get-resource "01K8Q3M7D2X9V6T1B8N5C0RDEX"))
           (resource (plist-get result :resource)))
      (should (equal resource '(:flag nil :on t :missing nil)))
      ;; 三个键都必须存在（缺值仍是 :flag nil 而不是整个键消失）。
      (should (plist-member resource :flag))
      (should (plist-member resource :missing))
      (should-not (plist-get resource :flag))
      (should-not (plist-get resource :missing))
      (should (eq (plist-get resource :on) t))
      (should-not (plist-get result :error)))))

;;; seshat-rest-get-resource

(ert-deftest seshat-rest-get-resource-builds-uid-path ()
  "`seshat-rest-get-resource' 把 uid 直接拼进路径（uid 只含 [0-9A-HJKMNP-TV-Z]，不编码），
且不带查询参数。"
  (seshat-rest-test--with (seshat-rest-test--ok "{}")
    (seshat-rest-get-resource "01K8Q3M7D2X9V6T1B8N5C0RDEX")
    (should (equal (seshat-rest-test--captured-method) "GET"))
    (should (equal (seshat-rest-test--captured-url)
                   "https://example.com/api/resources/01K8Q3M7D2X9V6T1B8N5C0RDEX"))))

(ert-deftest seshat-rest-get-resource-maps-resource-plist ()
  "`seshat-rest-get-resource' 把单资源对象映射为 `:resource' plist（kebab-case 键）。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       (concat "{\"uid\": \"01K8Q3M7D2X9V6T1B8N5C0RDEX\","
               " \"root\": \"ebooks\","
               " \"path\": \"book/chapter-1.epub\","
               " \"kind\": \"file\","
               " \"blob\": \"\","
               " \"rev\": \"\","
               " \"size\": 2048,"
               " \"mtime\": 1760785200,"
               " \"created_at\": \"2026-10-18T08:00:00Z\","
               " \"updated_at\": \"2026-10-18T08:00:00Z\","
               " \"deleted_at\": \"\"}"))
    (let ((result (seshat-rest-get-resource "01K8Q3M7D2X9V6T1B8N5C0RDEX")))
      (should (equal (plist-get result :status) 200))
      (should (equal (plist-get (plist-get result :resource) :root) "ebooks"))
      (should (equal (plist-get (plist-get result :resource) :path)
                     "book/chapter-1.epub"))
      (should (equal (plist-get (plist-get result :resource) :created-at)
                     "2026-10-18T08:00:00Z"))
      (should-not (plist-get result :not-found)))))

(ert-deftest seshat-rest-get-resource-404-is-not-found ()
  "404（未登记或已墓碑）映射为 `:not-found t'，不抛错、`:resource' 为 nil。"
  (seshat-rest-test--with
      (list :status 404
            :headers nil
            :body "{\"error\":{\"code\":\"unknown_uid\"}}")
    (let ((result (seshat-rest-get-resource "01K8Q3M7D2X9V6T1B8N5C0RDEX")))
      (should (equal (plist-get result :status) 404))
      (should (eq (plist-get result :not-found) t))
      (should-not (plist-get result :resource))
      (should-not (plist-get result :error)))))

;;; seshat-rest-changes

(ert-deftest seshat-rest-changes-builds-query-params ()
  "`seshat-rest-changes' 的 SINCE-SEQ（seq 游标）与 limit 出现在
`/api/changes' 的 `since' / `limit' 参数上——与资源清单的 since 端点不同。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"changes\": [], \"next_cursor\": 0, \"has_more\": false}")
    (seshat-rest-changes :since-seq 1042 :limit 50)
    (let* ((url (seshat-rest-test--captured-url))
           (params (seshat-rest-test--query-params url)))
      (should (string-match-p "\\`https://example\\.com/api/changes\\?" url))
      (should (equal (cdr (assoc "since" params)) "1042"))
      (should (equal (cdr (assoc "limit" params)) "50"))
      (should (equal (length params) 2)))))

(ert-deftest seshat-rest-changes-maps-events-and-cursor ()
  "`seshat-rest-changes' 映射 changes 事件（`old_path' → `:old-path'）、
`next_cursor' → `:next-cursor'、`has_more' → `:has-more'。"
  (seshat-rest-test--with (seshat-rest-test--ok seshat-rest-test--change-json)
    (let* ((result (seshat-rest-changes :since-seq 0))
           (event (car (plist-get result :changes))))
      (should (equal (plist-get result :status) 200))
      (should (equal (plist-get result :next-cursor) 1042))
      (should-not (plist-get result :has-more))
      (should (equal (plist-get event :seq) 1042))
      (should (equal (plist-get event :op) "rename"))
      (should (equal (plist-get event :path) "journal/2026/2026-10-18.org"))
      (should (equal (plist-get event :old-path) "journal/2026-10-18.org"))
      (should (equal (plist-get event :changed-at) "2026-10-18T11:00:00Z"))
      (should-not (plist-member event :old_path)))))

(ert-deftest seshat-rest-changes-empty-batch-echoes-cursor ()
  "空批次时 `:next-cursor' 回传请求的 SINCE-SEQ（游标不倒退，重试安全）。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       "{\"changes\": [], \"next_cursor\": 1042, \"has_more\": false}")
    (let ((result (seshat-rest-changes :since-seq 1042)))
      (should (equal (plist-get result :next-cursor) 1042))
      (should-not (plist-get result :changes))
      (should-not (plist-get result :has-more)))))

;;; 统一状态码解释器 `seshat-rest--interpret'

(ert-deftest seshat-rest-interpret-304-not-modified ()
  "304 映射为 `:not-modified-p t'，且不解析（空）响应体。"
  (let ((result (seshat-rest--interpret (list :status 304 :headers nil :body ""))))
    (should (equal (plist-get result :status) 304))
    (should (eq (plist-get result :not-modified-p) t))
    (should-not (plist-get result :json))
    (should-not (plist-get result :error))))

(ert-deftest seshat-rest-interpret-401-unauthorized ()
  "401 映射为 `:unauthorized t'（不重试）。"
  (let ((result (seshat-rest--interpret
                 (list :status 401 :headers nil
                       :body "{\"error\":{\"code\":\"unauthorized\"}}"))))
    (should (equal (plist-get result :status) 401))
    (should (eq (plist-get result :unauthorized) t))
    (should-not (plist-get result :read-only-root))))

(ert-deftest seshat-rest-interpret-403-read-only-root ()
  "403 映射为 `:read-only-root t'（ondemand 根写被拒，不重试）。"
  (let ((result (seshat-rest--interpret
                 (list :status 403 :headers nil
                       :body "{\"error\":{\"code\":\"root_read_only\"}}"))))
    (should (equal (plist-get result :status) 403))
    (should (eq (plist-get result :read-only-root) t))
    (should-not (plist-get result :unauthorized))))

(ert-deftest seshat-rest-interpret-404-not-found ()
  "404 映射为 `:not-found t'。"
  (let ((result (seshat-rest--interpret
                 (list :status 404 :headers nil
                       :body "{\"error\":{\"code\":\"unknown_uid\"}}"))))
    (should (equal (plist-get result :status) 404))
    (should (eq (plist-get result :not-found) t))))

(ert-deftest seshat-rest-interpret-409-state-conflict ()
  "409 映射为 `:conflict 'state-conflict'。"
  (let ((result (seshat-rest--interpret
                 (list :status 409 :headers nil :body "{}"))))
    (should (equal (plist-get result :status) 409))
    (should (eq (plist-get result :conflict) 'state-conflict))))

(ert-deftest seshat-rest-interpret-412-etag-mismatch ()
  "412 映射为 `:conflict 'etag-mismatch'。"
  (let ((result (seshat-rest--interpret
                 (list :status 412 :headers nil :body "{}"))))
    (should (equal (plist-get result :status) 412))
    (should (eq (plist-get result :conflict) 'etag-mismatch))))

(ert-deftest seshat-rest-interpret-416-plain-text-body-is-not-parsed ()
  "强制用例：416 的响应体是**纯文本**，绝不能被当 JSON 解析。
断言不抛 JSON 错误、返回 `:range-not-satisfiable t'，且没有 `:invalid-json'。"
  (let ((result (seshat-rest--interpret
                 (list :status 416 :headers nil
                       :body "requested range not satisfiable"))))
    (should (equal (plist-get result :status) 416))
    (should (eq (plist-get result :range-not-satisfiable) t))
    (should-not (plist-get result :json))
    (should-not (plist-get result :error))))

(ert-deftest seshat-rest-interpret-other-status-is-error ()
  "其它整数状态码（如 500 / 503）映射为 `:error'（`unexpected-status'）。"
  (dolist (status '(400 413 500 503))
    (let ((result (seshat-rest--interpret
                   (list :status status :headers nil :body "plain text"))))
      (should (equal (plist-get result :status) status))
      (should (eq (plist-get result :error) 'unexpected-status))
      (should-not (plist-get result :json)))))

(ert-deftest seshat-rest-interpret-nil-status-keeps-transport-error ()
  "`:status nil' 时保留传输层的 `:error' 符号与 `:message'，不抛错。"
  (let ((result (seshat-rest--interpret
                 (list :status nil :error 'timeout :message "超时"))))
    (should-not (plist-get result :status))
    (should (eq (plist-get result :error) 'timeout))
    (should (equal (plist-get result :message) "超时")))
  (let ((result (seshat-rest--interpret (list :status nil))))
    (should (eq (plist-get result :error) 'connection-failed))))

(ert-deftest seshat-rest-interpret-invalid-json-does-not-signal ()
  "成功状态码但响应体不是合法 JSON 时给出 `:error 'invalid-json'`，不抛错。"
  (let ((result (seshat-rest--interpret
                 (list :status 200 :headers nil :body "<html>oops</html>"))))
    (should (equal (plist-get result :status) 200))
    (should-not (plist-get result :json))
    (should (eq (plist-get result :error) 'invalid-json))))

;;; 强制用例：四个函数在传输失败时返回 `:error' 而不抛错

(ert-deftest seshat-rest-endpoints-report-transport-error-without-signaling ()
  "强制用例：transport 返回 (:status nil :error connection-failed) 时，
四个新函数都返回 `:error' 字段且**不抛错**（`should-not' 抛）。"
  (dolist (entry (list (cons "roots" (lambda () (seshat-rest-roots)))
                       (cons "list-resources"
                             (lambda () (seshat-rest-list-resources :root "notes")))
                       (cons "get-resource"
                             (lambda () (seshat-rest-get-resource
                                         "01K8Q3M7D2X9V6T1B8N5C0RDEX")))
                       (cons "changes"
                             (lambda () (seshat-rest-changes :since-seq 0)))))
    (seshat-rest-test--with (list :status nil :error 'connection-failed)
      (let ((result nil))
        (should (condition-case nil
                    (progn (setq result (funcall (cdr entry))) t)
                  (error nil)))
        (should-not (plist-get result :status))
        (should (eq (plist-get result :error) 'connection-failed))
        (should-not (plist-member result :json))))))

;;; 路径编码（供按路径访问的端点使用，T2b）

(ert-deftest seshat-rest-encode-path-keeps-slashes ()
  "`seshat-rest--encode-path' 逐段编码但保留目录分隔符 `/`，并去掉前导 `/`。"
  (should (equal (seshat-rest--encode-path "journal/2026-10-18.org")
                 "journal/2026-10-18.org"))
  (should (equal (seshat-rest--encode-path "/a b/c.org") "a%20b/c.org"))
  (should (equal (seshat-rest--encode-path "a/b%c") "a/b%25c"))
  ;; 整条路径不得被压成单个路径段（那会把 `/` 编成 %2F）。
  (should-not (string-match-p "%2F" (seshat-rest--encode-path "a/b/c"))))

;;; 文件端点（M8-A T2b）的测试辅助
;;
;; 落盘类用例一律在 `make-temp-file' 建的临时目录里跑，绝不触碰
;; `~/.local/share/seshat/' 或仓库目录。

(defun seshat-rest-test--read-binary (file)
  "以二进制方式读回 FILE 的内容（unibyte 字符串，不做任何编码转换）。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun seshat-rest-test--read-text (file)
  "按默认编码读回 FILE 的文本内容。"
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defmacro seshat-rest-test--with-temp-dir (var &rest body)
  "把一个新建临时目录绑定到 VAR（以 `/` 结尾），在其中执行 BODY，结束后删除。"
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "seshat-rest-test-" t))))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory ,var t)))))

(defun seshat-rest-test--captured-header (name)
  "返回最近一次被桩调用中请求头 NAME 的值（大小写不敏感）；未发送该头时返回 nil。"
  (cdr (assoc-string name (plist-get (seshat-rest-test--captured-args) :headers) t)))

(defun seshat-rest-test--captured-header-present-p (name)
  "最近一次被桩调用是否**发送了**请求头 NAME（区别于「发送了但值为 nil」）。"
  (and (assoc-string name (plist-get (seshat-rest-test--captured-args) :headers) t)
       t))

;;; seshat-rest-download-file

(ert-deftest seshat-rest-download-file-requests-file-endpoint ()
  "`seshat-rest-download-file' 发 GET /api/files/{逐段编码的 path}?root=…。
没有 IF-NONE-MATCH 时不得出现 `If-None-Match' 头。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "note.org" dir)))
      (seshat-rest-test--with (list :status 200
                                    :headers '(("ETag" . "\"blob1\""))
                                    :body "x")
        (seshat-rest-download-file "journal/2026-10-18.org" target :root "notes")
        (should (equal (seshat-rest-test--captured-method) "GET"))
        (should (equal (seshat-rest-test--captured-url)
                       "https://example.com/api/files/journal/2026-10-18.org?root=notes"))
        (should-not (seshat-rest-test--captured-header-present-p "If-None-Match"))))))

(ert-deftest seshat-rest-download-file-writes-payload-and-maps-headers ()
  "`seshat-rest-download-file' 把响应体落盘（非 ASCII 文本按 UTF-8 字节写出），
并从响应头取 `:etag' / `:content-type'（ETag 保留服务端原样的双引号）。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "note.org" dir))
          (payload "hello 世界\n"))
      (seshat-rest-test--with
          (list :status 200
                :headers '(("ETag" . "\"blob1\"")
                           ("Content-Type" . "text/plain; charset=utf-8"))
                :body payload)
        (let ((result (seshat-rest-download-file "a.org" target)))
          (should (equal (plist-get result :status) 200))
          (should (equal (plist-get result :etag) "\"blob1\""))
          (should (equal (plist-get result :content-type)
                         "text/plain; charset=utf-8"))
          (should-not (plist-get result :not-modified-p))
          (should-not (plist-get result :error))
          (should (file-exists-p target))
          (should (equal (seshat-rest-test--read-binary target)
                         (encode-coding-string payload 'utf-8)))
          ;; 落盘后目录里不留临时文件（原子写：temp + rename）。
          (should (equal (directory-files dir nil "\\`[^.]") '("note.org"))))))))

(ert-deftest seshat-rest-download-file-preserves-raw-bytes ()
  "强制用例：响应体是原始字节串时，落盘内容必须**逐字节**相同——不得经 UTF-8
往返（那会把 0xff 之类改写成多字节序列）。样例为 zip 魔数加高位字节与 NUL。"
  (seshat-rest-test--with-temp-dir dir
    (let* ((target (expand-file-name "book.epub" dir))
           (payload (unibyte-string #x50 #x4b #x03 #x04 #xff #x00 #xc3)))
      (seshat-rest-test--with (list :status 200 :headers nil :body payload)
        (let ((result (seshat-rest-download-file "book.epub" target)))
          (should (equal (plist-get result :status) 200))
          (should-not (plist-get result :etag))
          (should (equal (string-to-list (seshat-rest-test--read-binary target))
                         '(#x50 #x4b #x03 #x04 #xff #x00 #xc3)))
          (should (equal (file-attribute-size (file-attributes target)) 7)))))))

(ert-deftest seshat-rest-download-file-304-does-not-touch-target ()
  "强制用例：304（If-None-Match 命中）时**不得触碰 TARGET**——预置的旧文件
内容必须保持原样（不能被清空、截断或重写），且返回 `:not-modified-p t'。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "note.org" dir)))
      (with-temp-file target (insert "旧内容\n"))
      (let ((mtime (file-attribute-modification-time (file-attributes target))))
        (seshat-rest-test--with (list :status 304
                                      :headers '(("ETag" . "\"blob1\""))
                                      :body "")
          (let ((result (seshat-rest-download-file "a.org" target
                                                   :if-none-match "\"blob1\"")))
            (should (equal (plist-get result :status) 304))
            (should (eq (plist-get result :not-modified-p) t))
            (should-not (plist-get result :etag))
            (should (equal (seshat-rest-test--read-text target) "旧内容\n"))
            (should (equal (file-attribute-modification-time
                            (file-attributes target))
                           mtime))))))))

(ert-deftest seshat-rest-download-file-416-plain-text-body ()
  "强制用例：416 的响应体是纯文本，不得当 JSON 解析；返回
`:range-not-satisfiable t' 且不创建 TARGET。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "sub/note.org" dir)))
      (seshat-rest-test--with
          (list :status 416 :headers '(("Content-Range" . "bytes */1024"))
                :body "requested range not satisfiable")
        (let ((result (seshat-rest-download-file "a.org" target)))
          (should (equal (plist-get result :status) 416))
          (should (eq (plist-get result :range-not-satisfiable) t))
          (should-not (plist-get result :error))
          (should-not (file-exists-p target))
          ;; 连父目录都不该被创建——落盘只发生在 2xx。
          (should-not (file-exists-p (file-name-directory target))))))))

(ert-deftest seshat-rest-download-file-404-keeps-target ()
  "404 映射 `:not-found t'，且不触碰已存在的 TARGET。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "note.org" dir)))
      (with-temp-file target (insert "本地副本\n"))
      (seshat-rest-test--with (list :status 404 :headers nil
                                    :body "{\"error\":{\"code\":\"not_found\"}}")
        (let ((result (seshat-rest-download-file "a.org" target)))
          (should (equal (plist-get result :status) 404))
          (should (eq (plist-get result :not-found) t))
          (should (equal (seshat-rest-test--read-text target) "本地副本\n")))))))

(ert-deftest seshat-rest-download-file-creates-parent-directories ()
  "TARGET 的父目录不存在时递归创建（`make-directory' DIR t）。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "x/y/z/note.org" dir)))
      (seshat-rest-test--with (list :status 200 :headers nil :body "hi")
        (seshat-rest-download-file "note.org" target :root "notes")
        (should (file-exists-p target))
        (should (equal (seshat-rest-test--read-text target) "hi"))))))

(ert-deftest seshat-rest-download-file-passes-if-none-match ()
  "IF-NONE-MATCH 非 nil 时发送 `If-None-Match'（条件下载）。"
  (seshat-rest-test--with-temp-dir dir
    (seshat-rest-test--with (list :status 200 :headers nil :body "x")
      (seshat-rest-download-file "a.org" (expand-file-name "n.org" dir)
                                 :if-none-match "\"blob1\"")
      (should (equal (seshat-rest-test--captured-header "If-None-Match")
                     "\"blob1\"")))))

(ert-deftest seshat-rest-download-file-passes-timeout ()
  "`seshat-rest-download-file' 的 `:timeout' 透传给传输层（`:timeout' 形参）。
（下载超时是 A3 的安全修复：不加超时一台慢服务的单次取书能无限期挂住 Emacs。）"
  (seshat-rest-test--with-temp-dir dir
    (seshat-rest-test--with (list :status 200 :headers nil :body "x")
      (seshat-rest-download-file "a.org" (expand-file-name "a.org" dir)
                                 :timeout 30)
      (should (equal (plist-get (seshat-rest-test--captured-args) :timeout) 30)))
    ;; 未传时为 nil（交给传输层默认：不设限）
    (seshat-rest-test--with (list :status 200 :headers nil :body "x")
      (seshat-rest-download-file "a.org" (expand-file-name "b.org" dir))
      (should-not (plist-get (seshat-rest-test--captured-args) :timeout)))))

(ert-deftest seshat-rest-download-file-too-large-skips-write ()
  "`Content-Length' 超过 `:max-bytes' 时**不写盘**，返回 `:too-large t' 与 `:size'。
（A3 的大小上限：先看头再落盘，避免一次取书把磁盘写满。）"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "big.epub" dir)))
      (seshat-rest-test--with
          (list :status 200
                :headers '(("Content-Length" . "2048")
                           ("ETag" . "\"blob9\""))
                :body "payload")
        (let ((result (seshat-rest-download-file "big.epub" target
                                                :max-bytes 1024)))
          (should (eq (plist-get result :too-large) t))
          (should (equal (plist-get result :size) 2048))
          (should (equal (plist-get result :status) 200))
          ;; 超限不写盘：目标文件与临时文件都不应存在
          (should-not (file-exists-p target))
          (should (equal (directory-files dir nil "\\`[^.]") nil))))))
  ;; 上限内照常写盘，且 `:size' 带上头部大小
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "ok.epub" dir)))
      (seshat-rest-test--with
          (list :status 200 :headers '(("Content-Length" . "7")) :body "payload")
        (let ((result (seshat-rest-download-file "ok.epub" target
                                                :max-bytes 1024)))
          (should-not (plist-get result :too-large))
          (should (equal (plist-get result :size) 7))
          (should (file-exists-p target))
          (should (equal (seshat-rest-test--read-text target) "payload")))))
    ;; Content-Length 缺失时**不再**跳过检查（旧行为，安全缺口）：
    ;; chunked / 无该头时先落盘、再按实际文件大小兜底，超限即删文件并报超限。
    (let ((target (expand-file-name "nolength.epub" dir)))
      (seshat-rest-test--with (list :status 200 :headers nil :body "payload")
        (let ((result (seshat-rest-download-file "nolength.epub" target
                                                :max-bytes 1)))
          (should (eq (plist-get result :too-large) t))
          (should (equal (plist-get result :size) 7))
          (should-not (file-exists-p target)))))))

(ert-deftest seshat-rest-download-file-too-large-by-actual-size ()
  "无 `Content-Length' 且 body 超大 → 落盘后兜底判定为超限，目标文件**被删除**。
修复 2 的核心断言：`Content-Length' 缺失时（chunked 分段响应是常态）第一道闸
整个失效，若不按实际文件大小兜底就会一直写到磁盘满。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "chunked.epub" dir))
          (big (make-string 4096 ?x)))
      (seshat-rest-test--with (list :status 200 :headers nil :body big)
        (let ((result (seshat-rest-download-file "chunked.epub" target
                                                :max-bytes 1024)))
          (should (eq (plist-get result :too-large) t))
          (should (equal (plist-get result :status) 200))
          ;; `:size' 回落到实际写入的字节数（头里没有这个信息）
          (should (equal (plist-get result :size) 4096))
          (should-not (file-exists-p target))
          ;; 也不留临时文件（`seshat-download-' 前缀）
          (should (equal (directory-files dir nil "\\`seshat-download-") nil)))))))

(ert-deftest seshat-rest-download-file-missing-content-length-within-limit ()
  "无 `Content-Length' 但 body 在上限内 → 照常落盘（兜底只删超限的，不是一律拒写）。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "chunked-ok.epub" dir)))
      (seshat-rest-test--with (list :status 200 :headers nil :body "payload")
        (let ((result (seshat-rest-download-file "chunked-ok.epub" target
                                                :max-bytes 1024)))
          (should-not (plist-get result :too-large))
          (should (file-exists-p target))
          (should (equal (seshat-rest-test--read-text target) "payload")))))))

(ert-deftest seshat-rest-download-file-too-large-accepts-float-max-bytes ()
  "`:max-bytes' 传浮点时上限**照旧生效**（判据用 `numberp' 而不是 `integerp'）。
A3 复核（low）：Elisp 里 `1.5e8' 是 float，`(integerp 1.5e8)' 为 nil——判据写成
`integerp' 时浮点配置会**静默失效**，用户以为自己设了 150 MB 上限，实际一道闸
都没有。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "big2.epub" dir)))
      (seshat-rest-test--with
          (list :status 200
                :headers '(("Content-Length" . "200000000"))
                :body "payload")
        (let ((result (seshat-rest-download-file "big2.epub" target
                                                :max-bytes 1.5e8)))
          (should (eq (plist-get result :too-large) t))
          (should (equal (plist-get result :size) 200000000))
          ;; 超限不写盘
          (should-not (file-exists-p target))
          (should (equal (directory-files dir nil "\\`[^.]") nil)))))))

;;; seshat-rest-download-file：`:binary' 二进制口径
;;
;; `ondemand' 根（书库）只走 REST，`seshat-rest-download-file' 是下载 EPUB / PDF
;; 的唯一通道，因此它必须传 `:binary t' 让传输层跳过 UTF-8 解码。

(ert-deftest seshat-rest-download-file-passes-binary-flag ()
  "强制用例：`seshat-rest-download-file' 调用传输层时**带上 `:binary t'**。
不带该标志时 `rest' 后端会把响应体按 UTF-8 解码，非 UTF-8 字节被改写。"
  (seshat-rest-test--with-temp-dir dir
    (seshat-rest-test--with (list :status 200 :headers nil :body "x")
      (seshat-rest-download-file "book.epub" (expand-file-name "book.epub" dir))
      (should (eq (plist-get (seshat-rest-test--captured-args) :binary) t))
      (should (equal (seshat-rest-test--captured-method) "GET")))))

(ert-deftest seshat-rest-download-file-binary-path-is-byte-exact ()
  "端到端（真实 `rest' 后端，桩 `url-retrieve-synchronously'）：传输层返回的
非 UTF-8 字节经 `:binary t' 取回后**逐字节**落盘，不经任何编码往返。"
  (seshat-rest-test--with-temp-dir dir
    (let* ((target (expand-file-name "book.epub" dir))
           ;; zip 魔数 + 高位字节（0xff / 0xe4 / 0xb8 是非法 UTF-8 片段）+ NUL
           (payload (unibyte-string #x50 #x4b #x03 #x04 #xff #x00 #xc3 #xe4 #xb8))
           (seshat-rest-token "")
           (seshat-transport-backend 'rest))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (let ((buffer (generate-new-buffer
                                  " *seshat-rest-test-binary*")))
                     (with-current-buffer buffer
                       (insert "HTTP/1.1 200 OK\r\n")
                       (insert "Content-Type: application/epub+zip\r\n")
                       (insert "ETag: \"blob-epub\"\r\n\r\n")
                       (insert payload)
                       (set (make-local-variable 'url-http-response-status) 200))
                     buffer))))
        (let ((result (seshat-rest-download-file "book.epub" target)))
          (should (equal (plist-get result :status) 200))
          (should (equal (plist-get result :etag) "\"blob-epub\""))
          (should (equal (plist-get result :content-type) "application/epub+zip"))
          (should (file-exists-p target))
          (should (equal (string-to-list (seshat-rest-test--read-binary target))
                         (string-to-list payload)))
          (should (equal (file-attribute-size (file-attributes target)) 9)))))))

(ert-deftest seshat-rest-request-does-not-pass-binary-flag ()
  "回归：薄包装 `seshat-rest--request' **不传** `:binary'（进度 / 批注 / 版本
等 4 处调用方都是 JSON 文本，依赖传输层既有的 UTF-8 解码口径）。"
  (seshat-rest-test--with '(:status 200 :headers nil :body "{}")
    (seshat-rest--request "GET" "/api/progress/X")
    (should-not (memq :binary (seshat-rest-test--captured-args)))
    (seshat-rest--request "PUT" "/api/progress/X" "{\"position\":\"p\"}")
    (should-not (memq :binary (seshat-rest-test--captured-args)))))

;;; seshat-rest-upload-file

(ert-deftest seshat-rest-upload-file-requests-put-with-raw-body ()
  "`seshat-rest-upload-file' 发 PUT /api/files/{path}?root=…，请求体是原始字节
（多字节内容按 UTF-8 编码），Content-Type 为八位字节流而非 JSON。"
  (seshat-rest-test--with (seshat-rest-test--ok "{}" 201)
    (seshat-rest-upload-file "journal/2026-10-18.org" "内容\n" :root "notes")
    (should (equal (seshat-rest-test--captured-method) "PUT"))
    (should (equal (seshat-rest-test--captured-url)
                   "https://example.com/api/files/journal/2026-10-18.org?root=notes"))
    (should (equal (plist-get (seshat-rest-test--captured-args) :body)
                   (encode-coding-string "内容\n" 'utf-8)))
    (should (equal (seshat-rest-test--captured-header "Content-Type")
                   "application/octet-stream"))))

(ert-deftest seshat-rest-upload-file-omits-condition-headers-when-nil ()
  "强制用例（形态一）：`if-match' / `if-none-match' 均为 nil 时**整个头省略**，
不得发送空值条件头（服务端会把空 `If-Match' 判为永不匹配）。"
  (seshat-rest-test--with (seshat-rest-test--ok "{}")
    (seshat-rest-upload-file "a.org" "x")
    (should-not (seshat-rest-test--captured-header-present-p "If-Match"))
    (should-not (seshat-rest-test--captured-header-present-p "If-None-Match"))))

(ert-deftest seshat-rest-upload-file-quotes-etag-and-keeps-wildcard ()
  "强制用例（形态二）：未带引号的 ETag 被包成 `\"abc\"'；已带引号的不重复包；
`*' 作为通配符不加重引号。"
  (seshat-rest-test--with (seshat-rest-test--ok "{}")
    (seshat-rest-upload-file "a.org" "x" :if-match "abc")
    (should (equal (seshat-rest-test--captured-header "If-Match") "\"abc\""))
    (seshat-rest-upload-file "a.org" "x" :if-match "\"abc\"")
    (should (equal (seshat-rest-test--captured-header "If-Match") "\"abc\""))
    (seshat-rest-upload-file "a.org" "x" :if-none-match "*")
    (should (equal (seshat-rest-test--captured-header "If-None-Match") "*"))
    (should-not (seshat-rest-test--captured-header-present-p "If-Match"))))

(ert-deftest seshat-rest-upload-file-empty-if-match-is-sent-not-dropped ()
  "强制用例（形态三）：`if-match' 为空串时发 `If-Match: \"\"'（服务端语义
「永不匹配」→ 412），**不得**退化成无头（无条件写）请求。"
  (seshat-rest-test--with (seshat-rest-test--ok "{}")
    (seshat-rest-upload-file "a.org" "x" :if-match "")
    (should (seshat-rest-test--captured-header-present-p "If-Match"))
    (should (equal (seshat-rest-test--captured-header "If-Match") "\"\""))))

(ert-deftest seshat-rest-upload-file-maps-uid-etag-rev ()
  "上传成功（201）时从响应 JSON 取 `:uid' / `:etag' / `:rev'，并保留 `:status' 201。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       (concat "{\"uid\": \"01K8Q3M7D2X9V6T1B8N5C0RDEX\","
               " \"root\": \"notes\","
               " \"path\": \"journal/2026-10-18.org\","
               " \"blob\": \"9f2c1a\","
               " \"etag\": \"9f2c1a\","
               " \"rev\": \"4b825dc642cb6eb9a060e54bf8d69288fbee4904\","
               " \"seq\": 1042,"
               " \"created\": true}")
       201)
    (let ((result (seshat-rest-upload-file "journal/2026-10-18.org" "x")))
      (should (equal (plist-get result :status) 201))
      (should (equal (plist-get result :uid) "01K8Q3M7D2X9V6T1B8N5C0RDEX"))
      (should (equal (plist-get result :etag) "9f2c1a"))
      (should (equal (plist-get result :rev)
                     "4b825dc642cb6eb9a060e54bf8d69288fbee4904"))
      (should-not (plist-get result :conflict))
      (should-not (plist-get result :error))
      ;; 内部取值字段不外泄。
      (should-not (plist-member result :json))
      (should-not (plist-member result :headers)))))

(ert-deftest seshat-rest-upload-file-412-is-etag-mismatch ()
  "412 → `:conflict' 为 `etag-mismatch'（条件写前提不成立，内容未被修改）。"
  (seshat-rest-test--with
      (list :status 412 :headers nil
            :body "{\"error\":{\"code\":\"etag_mismatch\"}}")
    (let ((result (seshat-rest-upload-file "a.org" "x" :if-match "abc")))
      (should (equal (plist-get result :status) 412))
      (should (eq (plist-get result :conflict) 'etag-mismatch))
      (should-not (plist-get result :uid))
      (should-not (plist-get result :error)))))

(ert-deftest seshat-rest-upload-file-403-is-read-only-root ()
  "403 → `:read-only-root t'（ondemand 根写被拒，不重试）。"
  (seshat-rest-test--with
      (list :status 403 :headers nil
            :body "{\"error\":{\"code\":\"root_read_only\"}}")
    (let ((result (seshat-rest-upload-file "a.org" "x" :root "ebooks")))
      (should (equal (plist-get result :status) 403))
      (should (eq (plist-get result :read-only-root) t))
      (should-not (plist-get result :conflict)))))

;;; seshat-rest-delete-file

(ert-deftest seshat-rest-delete-file-requests-delete ()
  "`seshat-rest-delete-file' 发 DELETE /api/files/{path}?root=…。"
  (seshat-rest-test--with (seshat-rest-test--ok "{\"uid\": \"u1\", \"uids\": [\"u1\"]}")
    (seshat-rest-delete-file "journal/2026-10-18.org" :root "notes")
    (should (equal (seshat-rest-test--captured-method) "DELETE"))
    (should (equal (seshat-rest-test--captured-url)
                   "https://example.com/api/files/journal/2026-10-18.org?root=notes"))))

(ert-deftest seshat-rest-delete-file-maps-uid-and-uids ()
  "目录删除的响应里 `uid' 为空串、`uids' 列出全部被写墓碑的资源。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       (concat "{\"uid\": \"\", \"uids\": [\"u1\", \"u2\"],"
               " \"root\": \"notes\", \"path\": \"dir\", \"seq\": 1043}"))
    (let ((result (seshat-rest-delete-file "dir" :root "notes")))
      (should (equal (plist-get result :status) 200))
      (should (equal (plist-get result :uid) ""))
      (should (equal (plist-get result :uids) '("u1" "u2")))
      (should-not (plist-get result :not-found)))))

(ert-deftest seshat-rest-delete-file-404-is-not-found ()
  "404 → `:not-found t'（路径未登记，应重新拉取清单而不是重复删除）。"
  (seshat-rest-test--with
      (list :status 404 :headers nil
            :body "{\"error\":{\"code\":\"unknown_uid\"}}")
    (let ((result (seshat-rest-delete-file "gone.org")))
      (should (equal (plist-get result :status) 404))
      (should (eq (plist-get result :not-found) t))
      (should-not (plist-get result :uids)))))

;;; seshat-rest-move-resource

(ert-deftest seshat-rest-move-resource-posts-json-to-move-endpoint ()
  "`seshat-rest-move-resource' 发 POST /api/resources/{uid}/move，
请求体为 JSON `{\"to\": \"…\"}'，且不带查询参数。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       (concat "{\"uid\": \"u1\", \"root\": \"notes\", \"from\": \"a.org\","
               " \"to\": \"b/a.org\", \"seq\": 1044}"))
    (seshat-rest-move-resource "u1" "b/a.org")
    (should (equal (seshat-rest-test--captured-method) "POST"))
    (should (equal (seshat-rest-test--captured-url)
                   "https://example.com/api/resources/u1/move"))
    (should-not (string-match-p "\\?" (seshat-rest-test--captured-url)))
    (let ((body (plist-get (seshat-rest-test--captured-args) :body)))
      (should (equal (alist-get 'to (json-parse-string body :object-type 'alist
                                                       :array-type 'list))
                     "b/a.org")))
    (should (equal (seshat-rest-test--captured-header "Content-Type")
                   "application/json"))))

(ert-deftest seshat-rest-move-resource-maps-from-and-to ()
  "成功时返回 `:uid' / `:from' / `:to'（服务端字段 `from' 与 Elisp 关键字同名）。"
  (seshat-rest-test--with
      (seshat-rest-test--ok
       (concat "{\"uid\": \"u1\", \"root\": \"notes\", \"from\": \"a.org\","
               " \"to\": \"b/a.org\", \"seq\": 1044}"))
    (let ((result (seshat-rest-move-resource "u1" "b/a.org")))
      (should (equal (plist-get result :status) 200))
      (should (equal (plist-get result :uid) "u1"))
      (should (equal (plist-get result :from) "a.org"))
      (should (equal (plist-get result :to) "b/a.org"))
      (should-not (plist-get result :conflict)))))

(ert-deftest seshat-rest-move-resource-409-is-state-conflict ()
  "409 → `:conflict' 为 `state-conflict'（含墓碑占用目标的已知限制）。"
  (seshat-rest-test--with
      (list :status 409 :headers nil
            :body "{\"error\":{\"code\":\"conflict\"}}")
    (let ((result (seshat-rest-move-resource "u1" "b/a.org")))
      (should (equal (plist-get result :status) 409))
      (should (eq (plist-get result :conflict) 'state-conflict))
      (should-not (plist-get result :to))
      (should-not (plist-get result :error)))))

;;; seshat-rest-versions

(ert-deftest seshat-rest-versions-with-blob-uses-hash-param ()
  "带 BLOB 时把值发到服务端参数 `hash'（**不是** `blob'——发 `blob=' 会被忽略
并退化成取历史），路径逐段编码保留 `/`。"
  (seshat-rest-test--with
      (seshat-rest-test--ok "{\"hash\": \"h1\", \"content\": \"body\"}")
    (seshat-rest-versions "sub/a.org" "4b825dc642cb")
    (let* ((url (seshat-rest-test--captured-url))
           (params (seshat-rest-test--query-params url)))
      (should (equal (seshat-rest-test--captured-method) "GET"))
      (should (string-match-p
               "\\`https://example\\.com/api/versions/sub/a\\.org\\?" url))
      (should (equal (cdr (assoc "hash" params)) "4b825dc642cb"))
      (should-not (assoc "blob" params))
      (should (equal (length params) 1)))))

(ert-deftest seshat-rest-versions-without-blob-has-no-query ()
  "不带 BLOB 时取文件历史：URL 不带任何查询参数。"
  (seshat-rest-test--with
      (seshat-rest-test--ok "{\"head\": \"h2\", \"history\": []}")
    (seshat-rest-versions "sub/a.org")
    (should (equal (seshat-rest-test--captured-url)
                   "https://example.com/api/versions/sub/a.org"))))

(ert-deftest seshat-rest-versions-maps-head-and-content ()
  "历史响应给 `:head'（`:content' 为 nil）；内容响应给 `:content'（`:head' 为 nil）。"
  (seshat-rest-test--with
      (seshat-rest-test--ok "{\"head\": \"h2\", \"history\": []}")
    (let ((result (seshat-rest-versions "a.org")))
      (should (equal (plist-get result :status) 200))
      (should (equal (plist-get result :head) "h2"))
      (should-not (plist-get result :content))))
  (seshat-rest-test--with
      (seshat-rest-test--ok "{\"hash\": \"h1\", \"content\": \"祖先内容\"}")
    (let ((result (seshat-rest-versions "a.org" "h1")))
      (should (equal (plist-get result :content) "祖先内容"))
      (should-not (plist-get result :head)))))

(ert-deftest seshat-rest-versions-404-is-not-found ()
  "404（文件在该版本不存在）→ `:not-found t'。"
  (seshat-rest-test--with
      (list :status 404 :headers nil :body "{\"error\":{\"code\":\"not_found\"}}")
    (let ((result (seshat-rest-versions "a.org" "h1")))
      (should (equal (plist-get result :status) 404))
      (should (eq (plist-get result :not-found) t))
      (should-not (plist-get result :content)))))

;;; 强制用例：五个文件端点在传输失败时返回 `:error' 而不抛错

(ert-deftest seshat-rest-file-endpoints-report-transport-error-without-signaling ()
  "强制用例：transport 返回 (:status nil :error timeout) 时，五个新函数都返回
`:error' 而不抛错，且下载失败时**不创建** TARGET。"
  (seshat-rest-test--with-temp-dir dir
    (let ((target (expand-file-name "never.org" dir)))
      (dolist (entry
               (list (cons "download-file"
                           (lambda () (seshat-rest-download-file "a.org" target)))
                     (cons "upload-file"
                           (lambda () (seshat-rest-upload-file "a.org" "x")))
                     (cons "delete-file"
                           (lambda () (seshat-rest-delete-file "a.org")))
                     (cons "move-resource"
                           (lambda () (seshat-rest-move-resource "u1" "b.org")))
                     (cons "versions"
                           (lambda () (seshat-rest-versions "a.org")))))
        (seshat-rest-test--with (list :status nil :error 'timeout
                                      :message "连接超时")
          (let ((result nil))
            (should (condition-case nil
                        (progn (setq result (funcall (cdr entry))) t)
                      (error nil)))
            (should-not (plist-get result :status))
            (should (eq (plist-get result :error) 'timeout))
            (should-not (plist-member result :json)))))
      (should-not (file-exists-p target)))))

(provide 'seshat-rest-test)
;;; seshat-rest-test.el ends here
