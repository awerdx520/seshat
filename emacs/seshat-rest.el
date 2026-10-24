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

(require 'cl-lib)
(require 'url)
(require 'url-util)
(require 'url-http)
(require 'json)
(require 'subr-x)
(require 'seshat-transport)

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
BODY-STRING 为响应体文本（无响应体时为 \"\"）。网络错误等异常情形抛出 error。

本函数是传输层 `seshat-transport-request' 的薄包装：传输层永不抛错（只回报
`:status nil'），而本层负责把整型状态码转回 cons，并把连接失败重新抛成
error——4 处生产调用方依赖该抛错行为，不得改成返回 (nil . BODY)。

本函数**不传** `:binary'（进度 / 批注 / 版本等调用方全是 JSON 文本，依赖传输层
既有的 UTF-8 解码口径）；需要字节保真的文件下载走
`seshat-rest-download-file'，它另传 `:binary t'。"
  (let* ((url (concat (string-remove-suffix "/" seshat-rest-base-url) path))
         (response (seshat-transport-request
                    method url
                    :body body
                    :headers (append '(("Accept" . "application/json"))
                                     (when body
                                       '(("Content-Type" . "application/json"))))))
         (status (plist-get response :status)))
    (unless (integerp status)
      (error "seshat-rest: 请求 %s %s 失败：%s"
             method url
             (or (plist-get response :message)
                 (seshat-transport-error-message (plist-get response :error)))))
    (cons status (or (plist-get response :body) ""))))

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


;;; 新端点（清单 / 资源 / 变更）：URL 构造、状态码解释与字段映射
;;
;; 下面这一族函数**不经** `seshat-rest--request'，而是直接用
;; `seshat-transport-request'：薄包装把响应压成 (STATUS . BODY) 会丢掉响应头，
;; 而新端点需要 ETag / Content-Type 等头做条件请求（T2b），且需要「2xx 之外
;; 按契约映射为字段而不抛错」的语义。旧包装的契约保持不变（reader 侧 48+ 例以
;; 它为桩点）。

(defconst seshat-rest--accept-json-headers
  '(("Accept" . "application/json"))
  "新端点的默认请求头：只声明接受 JSON。
认证头由传输层（`seshat-transport-request'）按后端前置添加，调用方不要重复提供。")

(defun seshat-rest--headers (&optional extra)
  "返回新端点使用的请求头 alist：`Accept: application/json' 加 EXTRA。
EXTRA 为附加请求头 alist（如条件写的 `If-Match'），可为 nil。"
  (append seshat-rest--accept-json-headers extra))

(defun seshat-rest--url (path)
  "把请求路径 PATH 拼成完整 URL。
PATH 以 \"/\" 开头；`seshat-rest-base-url' 末尾的 \"/\" 会被去掉，与
`seshat-rest--request' 内部的拼接口径一致。"
  (concat (string-remove-suffix "/" seshat-rest-base-url) path))

(defun seshat-rest--query-string (params)
  "把 PARAMS（`(NAME . VALUE)' 的列表）编码为查询串（不含前导 `?'）。
NAME 为服务端参数名（字符串）；VALUE 为字符串、整数或 nil——nil 表示**省略**
该参数，交给服务端默认值（`limit' 缺省 500、`include_deleted' 缺省 false）。
键与值都经 `url-hexify-string' 编码，因此含 `/` 或空格的路径前缀也能安全传输。
PARAMS 中所有 VALUE 均为 nil 时返回空串。"
  (let ((parts nil))
    (dolist (param params)
      (let ((name (car param))
            (value (cdr param)))
        (when (and name value)
          (push (format "%s=%s"
                        (url-hexify-string name)
                        (url-hexify-string (format "%s" value)))
                parts))))
    (mapconcat #'identity (nreverse parts) "&")))

(defun seshat-rest--url-with-query (path params)
  "把请求路径 PATH 与查询参数 PARAMS 拼成完整 URL。
PARAMS 的语义见 `seshat-rest--query-string'；全部省略时结果与
`seshat-rest--url' 相同。查询串的键序不保证与 PARAMS 顺序一致。"
  (let ((query (seshat-rest--query-string params)))
    (seshat-rest--url (if (string-empty-p query)
                          path
                        (concat path "?" query)))))

(defun seshat-rest--encode-path (path)
  "把根内相对路径 PATH 逐段 URL 编码后以 \"/\" 重新拼接。
保留目录分隔符 \"/\"：`url-hexify-string' 会把 `/` 编成 %2F，整条路径于是变成
单个路径段，服务端将解析成不存在的资源。PATH 前导的 \"/\" 会先被去掉。"
  (mapconcat #'url-hexify-string
             (split-string (string-remove-prefix "/" path) "/" t)
             "/"))

(defun seshat-rest--2xx-p (status)
  "判断 STATUS 是否为 2xx 成功状态码（206 Partial Content 亦在此列）。"
  (and (integerp status) (>= status 200) (< status 300)))

(defconst seshat-rest--json-literal-symbols '(:false :null)
  "`json-parse-string' 用来表示 JSON false / null 的符号。
两者都是**非 nil 符号**，直接当条件会被误判为真，因此凡需要判定「JSON 假值」的
地方（`seshat-rest--json-true-p' / `seshat-rest--json-value'）都走这份单一清单，
避免两处口径漂移。")

(defun seshat-rest--json-true-p (value)
  "把 `json-parse-string' 读出的布尔 VALUE 转成 Elisp 布尔。
JSON 的 false 与 null 分别被读成符号 `:false' / `:null'（都是非 nil），直接当
条件会误判为真，故一律转成 nil（清单见 `seshat-rest--json-literal-symbols'）。"
  (and value (not (memq value seshat-rest--json-literal-symbols))))

(defun seshat-rest--json-value (value)
  "把 JSON 对象里的单个值 VALUE 规整为 Elisp 值。
JSON 的 false / null 一律转 nil（判定与 `seshat-rest--json-true-p' 同源，见
`seshat-rest--json-literal-symbols'）；其余值（字符串、数字、t、数组 list）原样
返回——plist 场景要保留真正的值，故不能直接套布尔谓词。"
  (if (memq value seshat-rest--json-literal-symbols) nil value))

(defun seshat-rest--json-kebab (name)
  "把 JSON 键名 NAME 转成 kebab-case 字符串。
`old_path' → \"old-path\"；无下划线的键（如 `uid'）原样返回。"
  (replace-regexp-in-string "_" "-" (format "%s" name)))

(defun seshat-rest--json-plist (alist)
  "把 JSON 对象 ALIST（符号键 alist）转为关键字键 plist。
键名统一做下划线 → kebab-case 转换（`created_at' → `:created-at'）；值为 nil 时
也保留该键，便于调用方按固定形状读取。数组仍保持为 list，不做递归转换。

值一律经 `seshat-rest--json-value' 规整：JSON 的 false / null 转成 nil，否则
`json-parse-string' 读出的符号 `:false' / `:null' 是真值——`changes' /
`resources' 将来若增 boolean 字段会被静默误判为真。"
  (let ((result nil))
    (dolist (pair alist)
      (push (intern (concat ":" (seshat-rest--json-kebab (car pair)))) result)
      (push (seshat-rest--json-value (cdr pair)) result))
    (nreverse result)))

(defun seshat-rest--parse-body (body)
  "把响应体 BODY 按 JSON 解析，返回 (PARSED . ERROR)。
PARSED 为 `json-parse-string' 的结果（对象为 alist、数组为 list）；BODY 为 nil、
空串或纯空白时 PARSED 为 nil 且 ERROR 为 nil。解析失败返回 (nil . invalid-json)
而**不抛错**，由调用方按 `:error' 字段处理。

只有成功状态码的响应体才会走到这里：`416' 的响应体是纯文本（见
`seshat-rest--interpret'），绝不能送进本函数。"
  (if (or (not (stringp body)) (string-empty-p (string-trim body)))
      (cons nil nil)
    (condition-case nil
        (cons (json-parse-string body :object-type 'alist :array-type 'list) nil)
      (error (cons nil 'invalid-json)))))

(defun seshat-rest--plist-drop (plist keys)
  "返回 PLIST 去掉 KEYS（关键字列表）各字段后的新 plist，其余字段保持原顺序。"
  (let ((result nil))
    (while plist
      (unless (memq (car plist) keys)
        (push (car plist) result)
        (push (cadr plist) result))
      (setq plist (cddr plist)))
    (nreverse result)))

(defun seshat-rest--interpret (response &optional success-p)
  "把传输层响应 RESPONSE 解释为统一的语义 plist（新端点共用）。
RESPONSE 为 `seshat-transport-request' 的返回值：成功是
\(:status N :headers ALIST :body STRING)，失败是
\(:status nil :error SYMBOL :message STRING)。本函数**永不抛错**：2xx 之外的
状态码按服务端契约映射为字段，而不是抛异常或返回 nil。

SUCCESS-P 为可选的「成功判定」函数，接收整数状态码、成功时返回非 nil；缺省
`seshat-rest--2xx-p'（2xx 全部算成功，含 206）。需要更窄的判定（例如只认
200/201）时传入自己的谓词即可，因此本函数可被 T2b 的下载 / 上传 / 删除 /
移动 / 版本端点直接复用，无需另写状态码分支。

返回的 plist 恒含 `:status'（整数或 nil），并按状态码补充下列字段之一：

- 被 SUCCESS-P 判为成功：`:json'（解析后的响应体，空响应体为 nil）与
  `:headers'（原样带出，供调用方读 ETag / Content-Type）；
- 304：`:not-modified-p t'（无响应体，不解析）；
- 401：`:unauthorized t'（不重试）；
- 403：`:read-only-root t'（`ondemand' 根写被拒，不重试）；
- 404：`:not-found t'（`unknown_uid' / 未登记 / 已墓碑）；
- 409：`:conflict' 为 `state-conflict'（进度时间戳、move 目标被占、无共同祖先）；
- 412：`:conflict' 为 `etag-mismatch'（条件写前提不成立且内容未被修改）；
- 416：`:range-not-satisfiable t'——**响应体是纯文本，绝不按 JSON 解析**；
- 其它整数码：`:error'，取传输层的 `:error' 符号，没有则 `unexpected-status'；
- 状态码不是整数：`:error' 为传输层错误符号，并带上可选的 `:message'。

成功但响应体不是合法 JSON 时额外给出 `:error' 为 `invalid-json'（不抛错）。"
  (let ((status (plist-get response :status))
        (headers (plist-get response :headers))
        (body (plist-get response :body)))
    (cond
     ((not (integerp status))
      (append (list :status nil
                    :error (or (plist-get response :error) 'connection-failed))
              (let ((message (plist-get response :message)))
                (when message (list :message message)))))
     ((funcall (or success-p #'seshat-rest--2xx-p) status)
      (let ((parsed (seshat-rest--parse-body body)))
        (append (list :status status :json (car parsed) :headers headers)
                (when (cdr parsed)
                  (list :error (cdr parsed))))))
     ((= status 304) (list :status status :not-modified-p t))
     ((= status 401) (list :status status :unauthorized t))
     ((= status 403) (list :status status :read-only-root t))
     ((= status 404) (list :status status :not-found t))
     ((= status 409) (list :status status :conflict 'state-conflict))
     ((= status 412) (list :status status :conflict 'etag-mismatch))
     ((= status 416) (list :status status :range-not-satisfiable t))
     (t (list :status status
              :error (or (plist-get response :error) 'unexpected-status))))))

(defun seshat-rest--result (base fields)
  "以 FIELDS（`(:key VALUE …)'）为业务字段，把解释结果 BASE 收尾成统一 plist。
BASE 为 `seshat-rest--interpret' 的返回值。返回的 plist 恒以 `:status' 开头，
随后是 FIELDS，最后是 BASE 中除 `:status' / `:json' / `:headers' 之外的语义字段
（`:error'、`:not-found'、`:unauthorized' 等）——成功与失败因此共用同一形状，
调用方先看 `:status' 与 `:error' 即可。`:json' 与 `:headers' 属内部取值手段，
不外泄到公开返回值。"
  (append (list :status (plist-get base :status))
          fields
          (seshat-rest--plist-drop base '(:status :json :headers))))


;;; 根映射

(defun seshat-rest--root-from-json (alist)
  "把 `GET /api/roots' 的单个根对象 ALIST 转为 plist (:tag :mode :default)。
`default' 由 JSON 布尔转为 Elisp 布尔（`json-parse-string' 把 false 读成
`:false'）；`mode' 取 \"mirror\" 或 \"ondemand\"。响应不含物理路径——物理根目录
属服务端部署细节，客户端只按 tag 引用根。"
  (list :tag (alist-get 'tag alist)
        :mode (alist-get 'mode alist)
        :default (seshat-rest--json-true-p (alist-get 'default alist))))

(defun seshat-rest-roots ()
  "列举服务端配置的根映射（`GET /api/roots'）。
成功（200）返回 plist `(:status 200 :roots LIST)'：LIST 的每项是
`(:tag TAG :mode MODE :default BOOL)'，顺序与服务端配置一致（首项即默认根）。

非 2xx 时 `:roots' 为 nil，其余字段按 `seshat-rest--interpret' 映射
（`:unauthorized t'、`:error SYMBOL' 等），不抛错。"
  (let* ((base (seshat-rest--interpret
                (seshat-transport-request
                 "GET" (seshat-rest--url "/api/roots")
                 :headers (seshat-rest--headers))))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :roots (when (listp json)
                    (mapcar #'seshat-rest--root-from-json
                            (alist-get 'roots json)))))))


;;; 资源清单

(cl-defun seshat-rest-list-resources (&key root prefix since-mtime
                                          include-deleted limit)
  "列举服务端资源登记（`GET /api/resources'）。
ROOT 为根 tag（nil 表示全部根）；PREFIX 为根内路径段前缀——服务端按**路径段**
匹配，`\"a\"' 命中 `a' 与 `a/b' 但不命中 `ab'；LIMIT 为页大小（服务端缺省 500，
夹紧到 [1, 2000]）；三者传 nil 表示交给服务端默认值。

SINCE-MTIME 是**文件 mtime 的 Unix 秒**，语义为「仅返回 mtime >= SINCE-MTIME 的
资源」。它与 `seshat-rest-changes' 的 SINCE-SEQ（单调递增的 seq 游标，语义
「seq > SINCE-SEQ」）**完全不同**：本端点按修改时间过滤、响应里没有 `next_cursor'，
两个 since 不可互换、不可共用同一个变量（服务端参数名都叫 `since'，客户端必须
靠形参名区分）。

INCLUDE-DELETED 非 nil 时把墓碑一并返回（服务端参数 `include_deleted=true'）；
nil 表示用服务端默认（不含墓碑）。

成功（200）返回 plist `(:status 200 :items LIST :has-more BOOL)'：
ITEMS 的每项是 plist，键为 `:uid :root :path :kind :blob :rev :size :mtime
:created-at :updated-at :deleted-at'——JSON 的下划线键已转为 kebab-case
（`created_at' → `:created-at'），`:deleted-at' 为空串表示资源存活。`:has-more'
为 Elisp 布尔（JSON false 转为 nil）。

非 2xx 时 `:items' 与 `:has-more' 为 nil，其余字段按 `seshat-rest--interpret'
映射（`:unauthorized t' 等），不抛错。"
  (let* ((base (seshat-rest--interpret
                (seshat-transport-request
                 "GET"
                 (seshat-rest--url-with-query
                  "/api/resources"
                  (list (cons "root" root)
                        (cons "prefix" prefix)
                        (cons "since" since-mtime)
                        (cons "include_deleted" (and include-deleted "true"))
                        (cons "limit" limit)))
                 :headers (seshat-rest--headers))))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :items (when (listp json)
                    (mapcar #'seshat-rest--json-plist
                            (alist-get 'items json)))
           :has-more (seshat-rest--json-true-p (alist-get 'has_more json))))))


;;; 单资源元数据

(defun seshat-rest-get-resource (uid)
  "取单个资源的元数据（`GET /api/resources/{uid}'）。
UID 为服务端权威身份，只含 `[0-9A-Z]'（26 位 Crockford Base32），因此直接拼进
路径、无需 URL 编码。

成功（200）返回 plist `(:status 200 :resource PLIST)'：PLIST 的字段与
`seshat-rest-list-resources' 的 `:items' 项同构（`:uid :root :path :kind :blob
:rev :size :mtime :created-at :updated-at :deleted-at'，下划线键已转 kebab-case）。

未登记或已墓碑（404）返回 `(:status 404 :not-found t :resource nil)'；
其它状态码按 `seshat-rest--interpret' 映射，均不抛错。"
  (let* ((base (seshat-rest--interpret
                (seshat-transport-request
                 "GET"
                 (seshat-rest--url (format "/api/resources/%s" uid))
                 :headers (seshat-rest--headers))))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :resource (when (listp json)
                       (seshat-rest--json-plist json))))))


;;; 变更流

(cl-defun seshat-rest-changes (&key since-seq limit)
  "拉取增量变更事件（`GET /api/changes'）。
SINCE-SEQ 是**全局单调递增的 seq 游标**，语义为「只返回 seq > SINCE-SEQ 的
事件」；传 nil 表示从 0 开始（服务端默认）。它与
`seshat-rest-list-resources' 的 SINCE-MTIME（mtime 秒）**完全不同**：两者不可
互换，形参名据此区分。LIMIT 为批大小（服务端缺省 500，夹紧到 [1, 2000]）。

成功（200）返回 plist `(:status 200 :changes LIST :next-cursor INT :has-more BOOL)'：
CHANGES 的每项是 plist，键为 `:seq :uid :op :root :path :old-path :blob :rev
:changed-at'——JSON 的 `old_path' 已转为 `:old-path'（仅 `rename' 事件有值，
其余为空串），`op' 取 `create' / `update' / `rename' / `delete'。`:next-cursor'
取自 JSON 的 `next_cursor'（本批最后一条的 seq；**空批次时回传请求的
SINCE-SEQ**，游标不倒退，因此重试安全）。`:has-more' 为 Elisp 布尔（JSON false
转为 nil），为 t 时应立即用 `:next-cursor' 再拉一轮。

非 2xx 时三个业务字段为 nil，其余字段按 `seshat-rest--interpret' 映射，不抛错。"
  (let* ((base (seshat-rest--interpret
                (seshat-transport-request
                 "GET"
                 (seshat-rest--url-with-query
                  "/api/changes"
                  (list (cons "since" since-seq)
                        (cons "limit" limit)))
                 :headers (seshat-rest--headers))))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :changes (when (listp json)
                      (mapcar #'seshat-rest--json-plist
                              (alist-get 'changes json)))
           :next-cursor (alist-get 'next_cursor json)
           :has-more (seshat-rest--json-true-p (alist-get 'has_more json))))))

;;; 文件读写的公共辅助（条件头 / URL / 二进制落盘）
;;
;; 文件端点与前面的 JSON 端点有两个实质差别：① 请求体与响应体是**原始字节**
;; （`PUT /api/files' 的 body 不是 JSON；`GET /api/files' 的响应是文件内容），
;; ② 条件请求靠 ETag 头（`If-Match' / `If-None-Match'）而不是查询参数。
;; 因此这里先把「条件头规范化」「文件 URL 拼装」「二进制落盘」抽成三个内部
;; 辅助，再让五个端点函数共用。

(defun seshat-rest--etag-value (value)
  "把条件头的取值 VALUE 规范成可放进请求头的字符串；VALUE 为 nil 时返回 nil。
服务端要求强 ETag 带双引号（`If-Match: \"<blob>\"'，见 `docs/api.md' §8.2），
故按下列规则处理：

- nil → nil，调用方据此**整个省略**该请求头（绝不发空值头）；
- \"*\" → \"*\"：HTTP 通配符（`If-None-Match: *' 表示「仅允许创建」）不加重引号；
- 已带成对双引号的字符串 → 原样返回（避免包成 `\"\"abc\"\"'）；
- 其它（含空串）→ 用双引号包裹。空串因此得到 `\"\"'，服务端的语义是
  **永不匹配**（`if-match' 空值 → 412），而不是「无条件写」——这正是不允许把
  空串当 nil 处理的原因。"
  (cond
   ((null value) nil)
   ((not (stringp value)) (seshat-rest--etag-value (format "%s" value)))
   ((equal value "*") "*")
   ((and (>= (length value) 2)
         (string-prefix-p "\"" value)
         (string-suffix-p "\"" value))
    value)
   (t (concat "\"" value "\""))))

(defun seshat-rest--condition-headers (if-match if-none-match)
  "构造条件请求头 alist：IF-MATCH → `If-Match'，IF-NONE-MATCH → `If-None-Match'。
任一为 nil 时对应的头**整个省略**（不发 `If-Match: ' 这种空值头——服务端把空
`If-Match' 判为「永不匹配」并回 412，与「不发条件头」的语义完全不同）；取值
规范化见 `seshat-rest--etag-value'。两个头同时给出时服务端**都会校验**，任一
前提不成立即 412（不是二选一）。"
  (let ((headers nil))
    (when if-match
      (push (cons "If-Match" (seshat-rest--etag-value if-match)) headers))
    (when if-none-match
      (push (cons "If-None-Match" (seshat-rest--etag-value if-none-match)) headers))
    (nreverse headers)))

(defun seshat-rest--file-url (path root)
  "拼出 `/api/files/{path}' 端点的完整 URL。
PATH 为根内逻辑相对路径，逐段编码后保留 `/`（见 `seshat-rest--encode-path'）；
ROOT 为根 tag，作为查询参数 `root' 发送，nil 时省略（交给服务端默认根）。"
  (seshat-rest--url-with-query
   (format "/api/files/%s" (seshat-rest--encode-path path))
   (list (cons "root" root))))

(defun seshat-rest--binary-string (content)
  "把 CONTENT 转成可直接落盘的 unibyte 字节串（二进制安全）。
多字节字符串按 UTF-8 编码——这是服务端 wire 格式；已是 unibyte 的串原样返回
（`seshat-rest-download-file' 走 `:binary t' 取回的响应体就是原始字节，不得再做
一次编解码往返，否则高位字节被改写）；nil 视为空串。

注意本函数只处理**出向**（落盘 / 上传）的字节化；入向的字节保真由
`seshat-transport-request' 的 `:binary' 参数保证，两者互不替代。"
  (cond ((null content) "")
        ((multibyte-string-p content) (encode-coding-string content 'utf-8))
        (t content)))

(defun seshat-rest--write-binary-file (target payload)
  "把 PAYLOAD 以二进制安全方式**原子**写入 TARGET，返回写入的绝对路径。
原子性：先在同一目录下 `make-temp-file' 建临时文件、写入、再用 `rename-file'
替换 TARGET——中途失败不会留下半截文件；失败时删除临时文件并重新抛出 error。
TARGET 的父目录不存在时递归创建（`make-directory' DIR t）。

写入不经 UTF-8 往返：缓冲区设为 unibyte 后用 `write-region' 直接落字节。"
  (let* ((file (expand-file-name target))
         (dir (file-name-directory file))
         (temp nil))
    (make-directory dir t)
    (setq temp (make-temp-file (expand-file-name "seshat-download-" dir)))
    (condition-case err
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (seshat-rest--binary-string payload))
            (write-region (point-min) (point-max) temp nil 'no-message))
          (rename-file temp file t)
          (setq temp nil)
          file)
      (error
       (when (and temp (file-exists-p temp))
         (ignore-errors (delete-file temp)))
       (signal (car err) (cdr err))))))

(defun seshat-rest--file-response-base (response)
  "把文件端点的传输响应 RESPONSE 解释为语义 plist BASE。
2xx 时**不解析响应体**：文件内容是原始字节，送进 `json-parse-string' 既浪费
（大文件白跑一遍解析）又会把合法为非 JSON 的内容误判成 `invalid-json' 错误；
因此成功分支只取 `:status' 与 `:headers'（调用方自行读 ETag / Content-Type）。

2xx 之外（304 / 401 / 403 / 404 / 409 / 412 / 416 / 传输失败）一律交给
`seshat-rest--interpret' 按统一契约映射——416 的纯文本响应体在那里被显式排除，
不会被当 JSON 解析。"
  (let ((status (plist-get response :status)))
    (if (seshat-rest--2xx-p status)
        (list :status status :headers (plist-get response :headers))
      (seshat-rest--interpret response))))


;;; 文件下载

(cl-defun seshat-rest-download-file (path target &key root if-none-match)
  "把远端文件 PATH 下载到本地 TARGET（`GET /api/files/{path}'）。
PATH 为根内逻辑相对路径（可含 `/`，逐段编码后保留分隔符）；ROOT 为根 tag
（nil 用服务端默认根，读对所有根开放）；IF-NONE-MATCH 为本地已知的 ETag，
非 nil 时附加 `If-None-Match' 头做条件下载（命中时服务端回 304，省一次传输）。

**落盘语义**：
- 先把响应体（原始字节）写入 TARGET 同目录的临时文件，再 `rename-file' 替换
  TARGET——中途失败不会留下半截文件；父目录不存在时递归创建。
- 2xx 才写盘。`304` / `416` / `403` / `404` 一律**不触碰 TARGET**（既不新建也不
  清空/重写），调用方保留原有本地副本即可。
- 响应体按二进制安全方式写出（unibyte 缓冲区 + `write-region'），不经 UTF-8
  往返；且请求时传 `:binary t' 让传输层**跳过 UTF-8 解码**，因此两个后端都
  字节保真——EPUB / PDF / 附件经 `ondemand' 根（只走 REST）下载不会被改写。

返回 plist `(:status :etag :content-type :not-modified-p :not-found
:read-only-root :range-not-satisfiable :error …)'：`:status' 为整数状态码
（传输失败为 nil），`:etag' / `:content-type' 取自响应头——`:etag' **带双引号**
（服务端原样），可直接作为下次 `seshat-rest-upload-file' 的 IF-MATCH 使用。
304 → `:not-modified-p t'；416 → `:range-not-satisfiable t'（响应体是纯文本，
不解析 JSON）；403 → `:read-only-root t'；404 → `:not-found t'。任何状态都不
抛错。"
  (let* ((response (seshat-transport-request
                    "GET"
                    (seshat-rest--file-url path root)
                    ;; 文件内容是原始字节（EPUB / PDF / 附件），必须让传输层
                    ;; 跳过 UTF-8 解码，否则非 UTF-8 字节会被改写。
                    :binary t
                    :headers (seshat-rest--headers
                              (seshat-rest--condition-headers nil if-none-match))))
         (base (seshat-rest--file-response-base response))
         (headers (plist-get base :headers))
         (success (seshat-rest--2xx-p (plist-get base :status))))
    (when success
      (seshat-rest--write-binary-file target (or (plist-get response :body) "")))
    (seshat-rest--result
     base
     (list :etag (and success (seshat-transport-header headers "ETag"))
           :content-type (and success
                              (seshat-transport-header headers "Content-Type"))))))


;;; 文件上传（条件写）

(cl-defun seshat-rest-upload-file (path content &key root if-match if-none-match)
  "把 CONTENT 写入远端文件 PATH（`PUT /api/files/{path}'，原始字节请求体）。
PATH 为根内逻辑相对路径；ROOT 为根 tag——只有 `mirror' 根可写，对 `ondemand'
根写入返回 403（应回退为只读展示，不要重试）；CONTENT 为字符串（多字节按
UTF-8 编码，unibyte 原样发送）。

条件写（乐观锁，`docs/api.md' §8.2）：
- IF-MATCH 非 nil → 发 `If-Match: \"<blob>\"'，仅当远端内容匹配才写入；
- IF-NONE-MATCH 非 nil → 发 `If-None-Match'；传 \"*\" 表示「仅允许创建」；
- 两者为 nil → 无条件写（不存在则创建、存在则覆盖）；
- IF-MATCH 传空串 → 发 `If-Match: \"\"'，服务端语义是**永不匹配**（412），不会
  退化成无条件写；调用方不要用空 ETag 表达「首次写入」，那种场景用
  `if-none-match' \"*\"。
两个条件头同时给出时服务端两者都校验，任一不成立即 412 且内容未被修改。

成功（200 覆盖 / 201 新建）返回 plist，字段为 `:status'（200 或 201）、
`:uid'、`:etag'、`:rev' 与按状态码映射的 `:conflict' / `:read-only-root' /
`:not-found' / `:error' 之一。
`:uid' / `:etag' / `:rev' 取自响应 JSON（`:etag' 缺省时回落到响应头 ETag）；
412 → `:conflict' 为 `etag-mismatch'（应拉远端内容做三方合并，见
`seshat-conflict'）；403 → `:read-only-root t'；404 → `:not-found t'。不抛错。"
  (let* ((response (seshat-transport-request
                    "PUT"
                    (seshat-rest--file-url path root)
                    :body (seshat-rest--binary-string content)
                    :headers (seshat-rest--headers
                              (append (seshat-rest--condition-headers
                                       if-match if-none-match)
                                      '(("Content-Type" . "application/octet-stream"))))))
         (base (seshat-rest--interpret response))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :uid (alist-get 'uid json)
           :etag (or (alist-get 'etag json)
                     (seshat-transport-header (plist-get base :headers) "ETag"))
           :rev (alist-get 'rev json)))))


;;; 删除（文件或目录子树）

(cl-defun seshat-rest-delete-file (path &key root)
  "删除远端 PATH（`DELETE /api/files/{path}'），PATH 为文件或目录。
ROOT 为根 tag——只有 `mirror' 根可写，否则 403（不重试）。
目录删除按**路径段边界**收敛（服务端对子树下所有存活资源逐个写墓碑），删除
`a/b' 不会误伤 `a/bc'。

成功（200）返回 plist `(:status 200 :uid :uids :not-found :read-only-root
:error …)'：`:uids' 为被写墓碑的 uid 列表；`:uid' **只在单资源删除时有值**，
目录删除时为空串（调用方应只看 `:uids'）。
404 → `:not-found t'（路径未登记；物理文件可能仍在磁盘上，应重新拉取清单而不是
重复删除）；403 → `:read-only-root t'。不抛错。"
  (let* ((response (seshat-transport-request
                    "DELETE"
                    (seshat-rest--file-url path root)
                    :headers (seshat-rest--headers)))
         (base (seshat-rest--interpret response))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :uid (alist-get 'uid json)
           :uids (alist-get 'uids json)))))


;;; 移动 / 改名

(defun seshat-rest-move-resource (uid to)
  "把 UID 对应的资源移动到同一根内的新路径 TO（`POST /api/resources/{uid}/move'）。
UID 为服务端权威身份（26 位 Crockford Base32，只含 `[0-9A-Z]'），直接拼进路径；
TO 为目标相对路径（相对**同一个根**，不允许 `..` 逃逸、不允许 `.git' 或点段），
以 JSON 请求体 `{\"to\": \"…\"}' 发送。移动后 uid 不变，事件为 `rename'。

成功（200）返回 plist `(:status 200 :uid :from :to :conflict :read-only-root
:not-found :error …)'：`:from' 为移动前路径，`:to' 为移动后路径。

**409 的语义需要特别处理**：`:conflict' 为 `state-conflict'，此时服务端可能是
「目标路径被其它 uid（含**墓碑**）占用」——而 docs/api.md §15 已知限制指出这种
情况下**物理移动可能已经完成**（墓碑占着 `UNIQUE(root,path)'）。因此调用方
**不应立即重试**本次移动（重试只会再得一个 409），应先 `POST /api/resources/rescan'
或按 `:from' / `:to' 拉清单核对真实状态，再决定后续动作。
403 → `:read-only-root t'（资源所属根不可写）；404 → `:not-found t'。不抛错。"
  (let* ((response (seshat-transport-request
                    "POST"
                    (seshat-rest--url (format "/api/resources/%s/move" uid))
                    :body (json-encode `((to . ,to)))
                    :headers (seshat-rest--headers
                              '(("Content-Type" . "application/json")))))
         (base (seshat-rest--interpret response))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :uid (alist-get 'uid json)
           :from (alist-get 'from json)
           :to (alist-get 'to json)))))


;;; 版本查询

(defun seshat-rest-versions (path &optional blob)
  "查询远端 PATH 的版本信息（`GET /api/versions/{path}'）。
PATH 为根内逻辑相对路径，逐段编码后保留 `/`。
BLOB 为可选的版本标识（服务端叫 `hash'，即 git commit / blob 引用）：
- BLOB 为 nil → 取**文件历史**：返回 `:head'（当前 HEAD hash）与 `:content'
  为 nil；
- BLOB 非 nil → 取**该版本的内容**：返回 `:content' 为该版本的文件内容，`:head'
  为 nil。
注意线缆参数名是 `hash'（`docs/api.md' §12.2 / `internal/api/server.go' 的
`Query().Get(\"hash\")'），本函数的形参沿用计划里的 `BLOB' 命名但发送时映射为
`hash='；不要把 `blob=' 发出去——服务端会忽略它并退化成「取历史」。

成功（200）返回 plist `(:status 200 :head :content :not-found :error …)'；
404 → `:not-found t'（文件在该版本不存在）；400（版本无法解析）→ `:error'
`unexpected-status'。不抛错。"
  (let* ((response (seshat-transport-request
                    "GET"
                    (seshat-rest--url-with-query
                     (format "/api/versions/%s" (seshat-rest--encode-path path))
                     (list (cons "hash" blob)))
                    :headers (seshat-rest--headers)))
         (base (seshat-rest--interpret response))
         (json (plist-get base :json)))
    (seshat-rest--result
     base
     (list :head (alist-get 'head json)
           :content (alist-get 'content json)))))

(provide 'seshat-rest)
;;; seshat-rest.el ends here
