;;; notes-rest.el --- 笔记阅读进度/批注 REST 同步 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块通过服务端 REST API 同步笔记的阅读进度与批注（结构化小状态），
;; 只依赖 Emacs 内置的 url.el 与 json.el，不引入任何第三方 HTTP 库。
;;
;; 使用前需设置 `notes-rest-base-url' 与 `notes-rest-token'：
;;
;;   (setq notes-rest-base-url "https://example.com"
;;         notes-rest-token "your-token")
;;
;; 同步阅读进度：
;;
;;   (notes-rest-set-progress "book-1" "chapter-3:42")
;;   (notes-rest-get-progress "book-1")
;;
;; 管理批注：
;;
;;   (notes-rest-create-annotation "book-1" "chapter-1:10" "第一条批注")
;;   (notes-rest-list-annotations "book-1")
;;   (notes-rest-delete-annotation 1)
;;
;; 端点、字段与错误码约定见项目 `docs/api.md'。注意服务端把 `{document_id}'
;; 当作 URL 路径中的单个路径段，不能包含斜杠；本模块统一用 `url-hexify-string'
;; 对标识做 URL 编码后再拼接路径。
;;
;; 认证失败（401）由服务端公共认证中间件产生，响应体是纯文本 "Unauthorized"，
;; 不是 `docs/api.md' 所述的 JSON 错误体；因此响应体不保证可被 JSON 解析，
;; 调用方应先看状态码再解析。

;;; Code:

(require 'url)
(require 'url-util)
(require 'url-http)
(require 'json)
(require 'subr-x)

(defgroup notes-rest nil
  "笔记阅读进度与批注的 REST 同步。"
  :group 'data
  :prefix "notes-rest-")

(defcustom notes-rest-base-url "https://example.com"
  "服务端基地址，不含末尾斜杠，例如 \"https://example.com\"。"
  :type 'string
  :group 'notes-rest)

(defcustom notes-rest-token ""
  "REST 接口的 Bearer 令牌（即服务端的 NOTES_AUTH_TOKEN）。
请求时以 `Authorization: Bearer <token>' 请求头发送。"
  :type 'string
  :group 'notes-rest)


;;; 底层 HTTP 封装

(defun notes-rest--request (method path &optional body)
  "向服务端同步发送一次 HTTP 请求并等待响应。
METHOD 为请求方法字符串（\"GET\"、\"PUT\"、\"POST\"、\"DELETE\" 等）。
PATH 为以 \"/\" 开头的请求路径，可含查询串，例如
\"/api/annotations?document_id=book-1\"。
BODY 为可选的请求体字符串（通常由 `json-encode' 生成）。

请求会携带 Bearer 令牌（`notes-rest-token'）与 Accept 头；当 BODY 非空时
额外携带 `Content-Type: application/json'，并按 UTF-8 编码正文。

返回 (STATUS . BODY-STRING)：STATUS 为整数 HTTP 状态码，
BODY-STRING 为响应体文本（无响应体时为 \"\"）。网络错误等异常情形抛出 error。"
  (let* ((url (concat (string-remove-suffix "/" notes-rest-base-url) path))
         (url-request-method method)
         (url-request-extra-headers
          (append
           `(("Authorization" . ,(concat "Bearer " notes-rest-token))
             ("Accept" . "application/json"))
           (when body
             '(("Content-Type" . "application/json")))))
         (url-request-data
          (when body
            (string-make-unibyte (encode-coding-string body 'utf-8))))
         (buffer (condition-case err
                     (url-retrieve-synchronously url t t)
                   (error (error "notes-rest: 请求 %s %s 失败：%s"
                                 method url (error-message-string err))))))
    (unless (buffer-live-p buffer)
      (error "notes-rest: 请求 %s %s 未返回有效响应" method url))
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

(defun notes-rest--json (response)
  "若 RESPONSE 是 2xx 且有响应体，解析其 JSON 并返回；否则返回 nil。
RESPONSE 为 `notes-rest--request' 的返回值 (STATUS . BODY-STRING)。
JSON 对象解析为 alist（键为符号），数组解析为 list。"
  (let ((status (car response))
        (body (cdr response)))
    (when (and (integerp status)
               (>= status 200)
               (< status 300)
               (stringp body)
               (not (string-empty-p body)))
      (json-parse-string body :object-type 'alist :array-type 'list))))


;;; 阅读进度

(defun notes-rest-set-progress (document-id position)
  "设置文档 DOCUMENT-ID 的阅读进度为 POSITION。
POSITION 为不透明的进度位置字符串（页码、CFI、行号等，由客户端定义）。
DOCUMENT-ID 为不含斜杠的稳定标识，会先做 URL 编码。
成功时返回服务端实际保存的记录（alist，含 position、updated_at）；
非 2xx 响应返回 nil。"
  (notes-rest--json
   (notes-rest--request
    "PUT"
    (format "/api/progress/%s" (url-hexify-string document-id))
    (json-encode `((position . ,position))))))

(defun notes-rest-get-progress (document-id)
  "获取文档 DOCUMENT-ID 的阅读进度。
DOCUMENT-ID 为不含斜杠的稳定标识，会先做 URL 编码。
成功（200）返回解析后的 alist（含 position、updated_at 等字段）；
尚无进度（404）或其他非 2xx 响应返回 nil。"
  (notes-rest--json
   (notes-rest--request
    "GET"
    (format "/api/progress/%s" (url-hexify-string document-id)))))


;;; 批注

(defun notes-rest-create-annotation (document-id location text)
  "为文档 DOCUMENT-ID 在位置 LOCATION 创建内容为 TEXT 的批注。
LOCATION 与 TEXT 均不可为空。DOCUMENT-ID 会先做 URL 编码（用于请求体）。
成功（201）返回服务端创建的完整批注对象（alist，含 id 与时间戳）；
非 2xx 响应返回 nil。"
  (notes-rest--json
   (notes-rest--request
    "POST"
    "/api/annotations"
    (json-encode `((document_id . ,document-id)
                   (location . ,location)
                   (text . ,text))))))

(defun notes-rest-list-annotations (document-id)
  "列出文档 DOCUMENT-ID 的全部批注。
DOCUMENT-ID 会先做 URL 编码后作为查询参数 `document_id' 发送。
成功（200）返回批注对象列表（每个对象为 alist，按 id 升序）；
无批注时为 nil，非 2xx 响应亦返回 nil。"
  (notes-rest--json
   (notes-rest--request
    "GET"
    (format "/api/annotations?document_id=%s"
            (url-hexify-string document-id)))))

(defun notes-rest-delete-annotation (id)
  "删除编号为 ID 的批注。
ID 为服务端分配的批注标识（正整数或字符串）。
成功（2xx，通常为 204）返回 t，否则返回 nil。"
  (let ((status (car (notes-rest--request
                      "DELETE"
                      (format "/api/annotations/%s" id)))))
    (and (integerp status)
         (>= status 200)
         (< status 300))))

(provide 'notes-rest)
;;; notes-rest.el ends here
