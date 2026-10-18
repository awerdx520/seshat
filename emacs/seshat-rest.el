;;; seshat-rest.el --- 笔记阅读进度/批注 REST 同步 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块通过服务端 REST API 同步笔记的阅读进度与批注（结构化小状态），
;; 只依赖 Emacs 内置的 url.el 与 json.el，不引入任何第三方 HTTP 库。
;;
;; 使用前需设置 `seshat-rest-base-url' 与 `seshat-rest-token'：
;;
;;   (setq seshat-rest-base-url "https://example.com"
;;         seshat-rest-token "your-token")
;;
;; 同步阅读进度（参数均为服务端权威的文件 uid）：
;;
;;   (seshat-rest-set-progress "01K8Q3M7D2X9V6T1B8N5C0RDEF" "chapter-3:42")
;;   (seshat-rest-get-progress "01K8Q3M7D2X9V6T1B8N5C0RDEF")
;;
;; 管理批注：
;;
;;   (seshat-rest-create-annotation "01K8Q3M7D2X9V6T1B8N5C0RDEF" "chapter-1:10" "第一条批注")
;;   (seshat-rest-list-annotations "01K8Q3M7D2X9V6T1B8N5C0RDEF")
;;   (seshat-rest-delete-annotation 1)
;;
;; 由根标签与相对路径解析 uid（客户端取 uid 的唯一入口）：
;;
;;   (seshat-rest-resolve-uid "notes" "book/chapter-1.org")
;;
;; 端点、字段与错误码约定见项目 `docs/api.md'。注意文件身份是服务端权威的
;; uid（26 位 Crockford Base32），进度/批注端点一律以 uid 为键；旧的路径式
;; 文档标识已被废弃。服务端把 uid 当作 URL 路径中的单个路径段，不含斜杠；
;; 本模块统一用 `url-hexify-string' 对标识做 URL 编码后再拼接路径。
;;
;; 认证失败（401）由服务端公共认证中间件产生，响应体是 JSON 错误体
;; {"error":{"code":"unauthorized","message":"Unauthorized"}}（并保留
;; `WWW-Authenticate' 头）；调用方仍应先看状态码，再按 JSON 解析错误体。

;;; Code:

(require 'url)
(require 'url-util)
(require 'url-http)
(require 'json)
(require 'subr-x)

(defgroup seshat-rest nil
  "笔记阅读进度与批注的 REST 同步。"
  :group 'data
  :prefix "seshat-rest-")

(defcustom seshat-rest-base-url "https://example.com"
  "服务端基地址，不含末尾斜杠，例如 \"https://example.com\"。"
  :type 'string
  :group 'seshat-rest)

(defcustom seshat-rest-token ""
  "REST 接口的 Bearer 令牌（即服务端的 SESHAT_AUTH_TOKEN）。
请求时以 `Authorization: Bearer <token>' 请求头发送。"
  :type 'string
  :group 'seshat-rest)


;;; 底层 HTTP 封装

(defun seshat-rest--request (method path &optional body)
  "向服务端同步发送一次 HTTP 请求并等待响应。
METHOD 为请求方法字符串（\"GET\"、\"PUT\"、\"POST\"、\"DELETE\" 等）。
PATH 为以 \"/\" 开头的请求路径，可含查询串，例如
\"/api/annotations?uid=01K8Q3M7D2X9V6T1B8N5C0RDEF\"。
BODY 为可选的请求体字符串（通常由 `json-encode' 生成）。

请求会携带 Bearer 令牌（`seshat-rest-token'）与 Accept 头；当 BODY 非空时
额外携带 `Content-Type: application/json'，并按 UTF-8 编码正文。

返回 (STATUS . BODY-STRING)：STATUS 为整数 HTTP 状态码，
BODY-STRING 为响应体文本（无响应体时为 \"\"）。网络错误等异常情形抛出 error。"
  (let* ((url (concat (string-remove-suffix "/" seshat-rest-base-url) path))
         (url-request-method method)
         (url-request-extra-headers
          (append
           `(("Authorization" . ,(concat "Bearer " seshat-rest-token))
             ("Accept" . "application/json"))
           (when body
             '(("Content-Type" . "application/json")))))
         (url-request-data
          (when body
            (string-make-unibyte (encode-coding-string body 'utf-8))))
         (buffer (condition-case err
                     (url-retrieve-synchronously url t t)
                   (error (error "seshat-rest: 请求 %s %s 失败：%s"
                                 method url (error-message-string err))))))
    (unless (buffer-live-p buffer)
      (error "seshat-rest: 请求 %s %s 未返回有效响应" method url))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (let* ((status url-http-response-status)
                 (raw (if (re-search-forward "\r?\n\r?\n" nil t)
                          (buffer-substring-no-properties (point) (point-max))
                        ""))
                 (text (if (multibyte-string-p raw)
                           raw
                         (decode-coding-string raw 'utf-8))))
            (cons status text)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun seshat-rest--json (response)
  "若 RESPONSE 是 2xx 且有响应体，解析其 JSON 并返回；否则返回 nil。
RESPONSE 为 `seshat-rest--request' 的返回值 (STATUS . BODY-STRING)。
JSON 对象解析为 alist（键为符号），数组解析为 list。"
  (let ((status (car response))
        (body (cdr response)))
    (when (and (integerp status)
               (>= status 200)
               (< status 300)
               (stringp body)
               (not (string-empty-p body)))
      (json-parse-string body :object-type 'alist :array-type 'list))))


;;; uid 解析

(defun seshat-rest-resolve-uid (root path)
  "把根标签 ROOT 与相对路径 PATH 解析为服务端权威的文件 uid。
ROOT 为根标签（如 \"notes\"），PATH 为相对该根的文件路径（不含根目录，
例如 \"book/chapter-1.org\"）；二者都会被 URL 编码后作为查询参数发送。

请求 `GET /api/resolve?root=&path='，成功（2xx 且响应体含非空字符串
`uid'）时返回该 uid 字符串。**非 2xx、响应体缺少 uid、响应无法解析或
请求异常时一律返回 nil**，不抛错——「未登记」是预期路径，提示语由调用方
决定（例如 `seshat-reader-annotation--uid' 会转成 `user-error'）。"
  (condition-case nil
      (let* ((response (seshat-rest--request
                        "GET"
                        (format "/api/resolve?root=%s&path=%s"
                                (url-hexify-string root)
                                (url-hexify-string path))))
             (json (seshat-rest--json response))
             (uid (and (listp json) (alist-get 'uid json))))
        (and (stringp uid) (not (string-empty-p uid)) uid))
    (error nil)))


;;; 阅读进度

(defun seshat-rest-set-progress (uid position)
  "设置文档 UID 的阅读进度为 POSITION。
POSITION 为不透明的进度位置字符串（页码、CFI、行号等，由客户端定义）。
UID 为服务端权威的文件身份（26 位 Crockford Base32），会先做 URL 编码。
成功时返回服务端实际保存的记录（alist，含 position、updated_at）；
非 2xx 响应返回 nil。"
  (seshat-rest--json
   (seshat-rest--request
    "PUT"
    (format "/api/progress/%s" (url-hexify-string uid))
    (json-encode `((position . ,position))))))

(defun seshat-rest-get-progress (uid)
  "获取文档 UID 的阅读进度。
UID 为服务端权威的文件身份（26 位 Crockford Base32），会先做 URL 编码。
成功（200）返回解析后的 alist（含 position、updated_at 等字段）；
尚无进度（404）、uid 非法（400）或其他非 2xx 响应返回 nil。"
  (seshat-rest--json
   (seshat-rest--request
    "GET"
    (format "/api/progress/%s" (url-hexify-string uid)))))


;;; 批注

(defun seshat-rest-create-annotation (uid location text)
  "为文档 UID 在位置 LOCATION 创建内容为 TEXT 的批注。
LOCATION 与 TEXT 均不可为空。UID 作为 JSON 请求体的 `uid' 字段原样发送
（JSON 请求体无需 URL 编码）。
成功（201）返回服务端创建的完整批注对象（alist，含 id 与时间戳）；
非 2xx 响应返回 nil。"
  (seshat-rest--json
   (seshat-rest--request
    "POST"
    "/api/annotations"
    (json-encode `((uid . ,uid)
                   (location . ,location)
                   (text . ,text))))))

(defun seshat-rest-update-annotation (id location text)
  "更新编号为 ID 的批注的 LOCATION 与 TEXT。
ID 为服务端分配的批注标识（字符串），会先做 URL 编码（用于请求路径）。
LOCATION 与 TEXT 均不可为空。
成功（200）返回服务端更新后的完整批注对象（alist，含 id 与时间戳）；
非 2xx 响应（如批注不存在 404）返回 nil。"
  (seshat-rest--json
   (seshat-rest--request
    "PUT"
    (format "/api/annotations/%s" (url-hexify-string id))
    (json-encode `((location . ,location)
                   (text . ,text))))))

(defun seshat-rest-list-annotations (uid)
  "列出文档 UID 的全部批注。
UID 会先做 URL 编码后作为查询参数 `uid' 发送。
成功（200）返回批注对象列表（每个对象为 alist，按 id 升序）；
无批注时为 nil，非 2xx 响应亦返回 nil。"
  (seshat-rest--json
   (seshat-rest--request
    "GET"
    (format "/api/annotations?uid=%s"
            (url-hexify-string uid)))))

(defun seshat-rest-delete-annotation (id)
  "删除编号为 ID 的批注。
ID 为服务端分配的批注标识（正整数或字符串），会先字符串化再做 URL 编码
（用于请求路径）。
成功（2xx，通常为 204）返回 t，否则返回 nil。"
  (let ((status (car (seshat-rest--request
                      "DELETE"
                      (format "/api/annotations/%s"
                              (url-hexify-string (format "%s" id)))))))
    (and (integerp status)
         (>= status 200)
         (< status 300))))

(provide 'seshat-rest)
;;; seshat-rest.el ends here
