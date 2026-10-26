;;; seshat-transport.el --- 统一 HTTP 传输层（url.el / curl 双后端） -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块把「发一次 HTTP 请求」收敛为单一契约，供 `seshat-rest.el' 等上层
;; 复用。后端可切换（`seshat-transport-backend'）：
;;
;; - `rest'（默认）：`url.el'，Bearer 令牌（`seshat-rest-token'）。凭据只出现
;;   在内存里，不落盘。
;; - `webdav'：curl，Basic Auth（`seshat-sync-username' / `seshat-sync-token'）。
;;   凭据写入 0600 权限的临时 curl 配置文件，不出现在命令行参数中——本模块
;;   **内部自实现**该逻辑，不调用 `seshat-sync--make-config-file'（那是
;;   `seshat-sync.el' 的私有函数）。此后端为 WebDAV 灰度期保留。
;;
;; 统一契约：成功返回 plist `(:status N :headers ALIST :body STRING)'；
;; 连接失败返回 `(:status nil :error SYMBOL :message STRING)'，SYMBOL 取
;; `connection-failed' / `timeout' / `dns-failed' 之一。
;;
;; 二进制响应：`seshat-transport-request' 的 `:binary' 关键字为 nil（默认）时
;; `:body' 是文本（`rest' 后端按 UTF-8 解码、`webdav' 后端本就是原始字节）；
;; 非 nil 时 `:body' 是**原始字节的 unibyte 字符串**，全程不经任何
;; coding-system（不得 decode、不得 encode）。二进制下载（EPUB / PDF / 附件）
;; 必须传 `:binary t'，否则非 UTF-8 字节会被解码改写。
;;
;; 分层：**本模块永不抛错**（只回报 `:status nil' + `:error'）；抛错责任在上层
;; 薄包装 `seshat-rest--request'——它把整型 `:status' 转回 `(STATUS . BODY)'，
;; 并对 `:status nil' 重新抛出 error。改动时不得把抛错逻辑上提到本模块。
;;
;; 可脱网单测的部分：纯函数 `seshat-transport--parse-url-response'、
;; `seshat-transport--parse-curl'、`seshat-transport-header'，以及测试注入点
;; `seshat-transport--raw'。

;;; Code:

;; cl-lib 是 Emacs 自带库（仓库 `seshat-reader' 各模块亦已使用），这里只为
;; `cl-defun' 的关键字参数——普通 `defun' 不支持 `&key'（`&key' 会被当作
;; 必需形参名，导致调用方按关键字传参时报 wrong-number-of-arguments）。
(require 'cl-lib)
(require 'url)
(require 'url-util)
(require 'url-http)
(require 'subr-x)

;; 外部变量声明（不赋值）：避免为了读凭据而 `require' 上层模块造成依赖倒置。
;; 变量未绑定时各读取函数按各自的缺省值回落，因此这里只做编译期声明。
(defvar seshat-rest-token)
(defvar seshat-sync-username)
(defvar seshat-sync-token)

(defgroup seshat-transport nil
  "统一 HTTP 传输层。"
  :group 'data
  :prefix "seshat-transport-")

(defcustom seshat-transport-backend 'rest
  "传输后端。
`rest' 用 `url.el' 并携带 `Authorization: Bearer <token>'（令牌取自
`seshat-rest-token'，不落盘）；`webdav' 用 curl 并携带 Basic Auth
（凭据取自 `seshat-sync-username' / `seshat-sync-token'，写入 0600 权限的
临时 curl 配置文件），仅用于 WebDAV 灰度期。"
  :type '(choice (const :tag "REST（url.el + Bearer）" rest)
                 (const :tag "WebDAV（curl + Basic Auth）" webdav))
  :group 'seshat-transport)

(defvar seshat-transport--raw nil
  "测试注入点：非 nil 时 `seshat-transport-request' 直接 funcall 它。
桩函数接受与被选后端相同的参数 (METHOD URL &key BODY HEADERS TIMEOUT BINARY)，
返回值即 `seshat-transport-request' 的返回值。生产环境恒为 nil。")

(defconst seshat-transport--backend-functions
  '((rest . seshat-transport--url)
    (webdav . seshat-transport--curl))
  "后端符号到实现函数的映射。")


;;; 后端无关的纯函数

(defconst seshat-transport--curl-error-symbols
  '((6 . dns-failed)
    (7 . connection-failed)
    (28 . timeout))
  "curl 退出码到传输层错误符号的映射（其余退出码一律 `connection-failed'）。")

(defun seshat-transport--parse-curl (exit-code output http-code)
  "把 curl 的 EXIT-CODE、标准输出 OUTPUT 与 HTTP-CODE 归一化为传输 plist。
EXIT-CODE 为 `call-process' 的返回值（整数退出码，或表示被信号终止的字符串）；
OUTPUT 为 curl `-w %{http_code}' 写出的标准输出；HTTP-CODE 为调用方已解析出的
整数状态码（可为 nil，此时从 OUTPUT 解析）。

退出码非 0 时按 `seshat-transport--curl-error-symbols' 映射为错误符号，
其余映射为 `connection-failed'。成功（退出码 0）时返回 `(:status N)'；
退出码 0 却拿不到合法状态码时返回 `(:status nil :error connection-failed)'。
本函数为纯函数，不触网、不读文件；`:body' 与 `:headers' 由后端补齐。"
  (cond
   ((not (integerp exit-code))
    (list :status nil :error 'connection-failed))
   ((zerop exit-code)
    (let ((code (or http-code
                    (let ((trimmed (string-trim (or output ""))))
                      (and (string-match-p "\\`[0-9]+\n?\\'" trimmed)
                           (string-to-number trimmed))))))
      (if (and (integerp code) (> code 0))
          (list :status code)
        (list :status nil :error 'connection-failed))))
   (t
    (list :status nil
          :error (or (alist-get exit-code seshat-transport--curl-error-symbols)
                     'connection-failed)))))

(defun seshat-transport--buffer-bytes (buffer start end)
  "以二进制方式取出 BUFFER 中 START..END 范围的内容，返回 unibyte 字符串。
不做任何编码转换（既不解码也不编码）：多字节缓冲区里装的是逐字节原值的
raw-byte 字符，搬进 unibyte 临时缓冲区后即为原始字节序列。二进制下载
（`:binary t'）必须走这条路径，`decode-coding-string' 会改写非 UTF-8 字节。"
  (with-current-buffer buffer
    (if (not enable-multibyte-characters)
        (buffer-substring-no-properties start end)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-buffer-substring-no-properties buffer start end)
        (buffer-string)))))

(defun seshat-transport--parse-url-response (buffer status &optional binary)
  "把 url.el 的响应 BUFFER 与 STATUS 归一化为传输 plist。
BUFFER 为 `url-retrieve-synchronously' 返回的响应缓冲区（首行为状态行，随后是
响应头，空行之后是响应体）；STATUS 为调用方读到的 HTTP 状态码整数。
返回 `(:status N :headers ALIST :body STRING)'；STATUS 不是整数时视为连接
失败，返回 `(:status nil :error connection-failed)'。

响应体的处理口径按 BINARY 分两档：
- BINARY 为 nil（默认，文本响应）：已是多字节字符串则原样返回，否则按 UTF-8
  解码——与既有行为完全一致；
- BINARY 非 nil（二进制响应）：经 `seshat-transport--buffer-bytes' 直接取原始
  字节，返回 unibyte 字符串，**不做任何 coding-system 往返**。
本函数不触网、不杀缓冲区。"
  (if (not (integerp status))
      (list :status nil :error 'connection-failed)
    (with-current-buffer buffer
      (save-excursion
        (let ((headers nil)
              (body ""))
          (goto-char (point-min))
          (when (re-search-forward "\r?\n\r?\n" nil t)
            (let ((body-start (match-end 0))
                  (header-end (match-beginning 0)))
              ;; 跳过状态行后逐行收集「Name: value」，直到空行。
              (goto-char (point-min))
              (forward-line 1)
              (while (and (< (point) header-end)
                          (looking-at "\\([^:\n]+\\):[ \t]*\\(.*\\)$"))
                (push (cons (match-string-no-properties 1)
                            (string-trim-right (match-string-no-properties 2)
                                               "[\r\t ]"))
                      headers)
                (forward-line 1))
              (if binary
                  (setq body (seshat-transport--buffer-bytes
                              buffer body-start (point-max)))
                (let ((raw (buffer-substring-no-properties body-start (point-max))))
                  (setq body (if (multibyte-string-p raw)
                                 raw
                               (decode-coding-string raw 'utf-8)))))))
          (list :status status :headers (nreverse headers) :body body))))))

(defun seshat-transport-header (headers name)
  "在 HEADERS（`(NAME . VALUE)' 组成的 alist）中取 NAME 的值，大小写不敏感。
NAME 可写作 \"ETag\" 或 \"etag\"，两者都能命中同一响应头；未找到返回 nil。"
  (cdr (assoc-string name headers t)))

(defun seshat-transport-error-message (error-symbol)
  "把传输层错误符号 ERROR-SYMBOL 转成人类可读的中文描述。"
  (pcase error-symbol
    ('timeout "连接超时")
    ('dns-failed "域名解析失败")
    ('connection-failed "连接失败")
    (_ (format "未知传输错误（%s）" error-symbol))))


;;; 凭据路由

(defun seshat-transport--rest-token ()
  "取 `rest' 后端的 Bearer 令牌。
优先 `seshat-rest-token'（由 `seshat-rest.el' 定义）；该变量尚未绑定时退回
环境变量 SESHAT_AUTH_TOKEN。空串照原样返回——空令牌仍会发送
`Authorization: Bearer ' 头，与既有行为一致。"
  (if (boundp 'seshat-rest-token)
      (if (stringp seshat-rest-token) seshat-rest-token "")
    (or (getenv "SESHAT_AUTH_TOKEN") "")))

(defun seshat-transport--rest-auth-header ()
  "构造 `rest' 后端的认证头，返回 `(\"Authorization\" . \"Bearer TOKEN\")'。
令牌为空串时仍返回 `\"Bearer \"' 形式（不跳过认证头）。"
  (cons "Authorization" (concat "Bearer " (seshat-transport--rest-token))))

(defun seshat-transport--webdav-username ()
  "取 `webdav' 后端 Basic Auth 的用户名（`seshat-sync-username'）。
变量未绑定时回落为 \"seshat\"（与 `seshat-sync.el' 的默认值一致）。"
  (if (and (boundp 'seshat-sync-username) (stringp seshat-sync-username))
      seshat-sync-username
    "seshat"))

(defun seshat-transport--webdav-token ()
  "取 `webdav' 后端 Basic Auth 的密码/令牌（`seshat-sync-token'）。
变量未绑定时回落为空串。"
  (if (and (boundp 'seshat-sync-token) (stringp seshat-sync-token))
      seshat-sync-token
    ""))

(defun seshat-transport--webdav-auth-header ()
  "构造 `webdav' 后端的认证头，返回 `(\"Authorization\" . \"Basic BASE64\")'。
BASE64 为 `用户名:令牌' 的 base64 编码；令牌为空串时仍照常构造。"
  (cons "Authorization"
        (concat "Basic "
                (base64-encode-string
                 (encode-coding-string
                  (format "%s:%s" (seshat-transport--webdav-username)
                          (seshat-transport--webdav-token))
                  'utf-8)
                 t))))

(defun seshat-transport--auth-header ()
  "按 `seshat-transport-backend' 返回当前后端的认证头 cons。"
  (if (eq seshat-transport-backend 'webdav)
      (seshat-transport--webdav-auth-header)
    (seshat-transport--rest-auth-header)))

(defun seshat-transport--make-curl-config ()
  "创建仅含认证头的临时 curl 配置文件，返回其绝对路径。
文件内容为一行 `header = \"Authorization: Basic ...\"'，以 0600 权限（仅属主
可读写）写入；凭据因此不出现在命令行参数中，避免暴露于进程列表（ps 可见）。

**权限先于内容**：`make-temp-file' 之后立刻 `set-file-modes' 到 0600，再写内容；
写完再复核一次。反过来（先写后 chmod）会让 base64 可逆的凭据在权限还是
`0666 & ~umask'（常见 0644）的瞬间对同机其它用户可读。
调用方负责使用后删除该文件（见 `seshat-transport--curl'）。"
  (let ((file (make-temp-file "seshat-transport-" nil ".curlrc"))
        (header (seshat-transport--webdav-auth-header)))
    (condition-case err
        (progn
          ;; ① 收紧权限必须在写入之前：此时文件还是空文件，泄露面为零。
          (set-file-modes file #o600)
          (with-temp-file file
            ;; %S 输出带双引号并转义 \\ 与 \"，与 curl 配置文件语法兼容。
            (insert (format "header = %S\n"
                            (format "%s: %s" (car header) (cdr header)))))
          ;; ② 写完复核：`write-region' 对已存在文件不会重置权限，这里再断言
          ;; 一次，防止将来某次改动把顺序改回「先写后 chmod」而无人察觉。
          (set-file-modes file #o600)
          file)
      (error
       (when (file-exists-p file)
         (delete-file file))
       (error "seshat-transport: 无法创建 curl 配置文件：%s"
              (error-message-string err))))))


;;; 后端实现

(cl-defun seshat-transport--url (method url &key body headers timeout binary)
  "用 `url.el' 发送一次请求（`rest' 后端）。
METHOD 为请求方法字符串；URL 为完整地址；BODY 为请求体字符串或 nil；
HEADERS 为附加请求头 alist（认证头由本函数前置添加）；TIMEOUT 为超时秒数，
作为 `url-retrieve-synchronously' 的 TIMEOUT 形参传入（nil 或非正数时传 nil，
即 url.el 默认「不限时」）；BINARY 非 nil 时
响应体按原始字节返回（unibyte 字符串，不做 UTF-8 解码），nil 时维持既有文本口径。
返回统一契约 plist，永不抛错。

请求体的编码口径：BODY 是**多字节**字符串时按 UTF-8 编码（JSON / 文本调用方）；
已是 **unibyte** 字节串时**原样发送**——它本身就是 wire 格式的字节序列
（`seshat-rest-upload-file' 传的就是 `seshat-rest--binary-string' 的产物）。
这里显式分支而不依赖「`encode-coding-string' 对 unibyte 串是逐字节直通」这个
实现细节（实测 Emacs 31.1 确实如此，但那是 Emacs 内部语义，不该由本模块默默
承担），口径因此与 `seshat-transport--curl' 完全一致。"
  (condition-case err
      (let* ((url-request-method method)
             (url-request-extra-headers
              (cons (seshat-transport--rest-auth-header) headers))
             (url-request-data
              (when body
                (if (multibyte-string-p body)
                    (encode-coding-string body 'utf-8)
                  body)))
             ;; 第三参 INHIBIT-COOKIES 恒为 t；第四参 TIMEOUT 只在给出正数秒数时
             ;; 生效（url.el 的契约是「nil 或非正数 = 不限时」）。
             (buffer (url-retrieve-synchronously
                      url t t (and (numberp timeout) (> timeout 0) timeout))))
        (if (not (buffer-live-p buffer))
            (list :status nil :error 'connection-failed
                  :message "未返回有效响应缓冲区")
          (unwind-protect
              (seshat-transport--parse-url-response
               buffer
               (with-current-buffer buffer
                 (and (boundp 'url-http-response-status)
                      (symbol-value 'url-http-response-status)))
               binary)
            (when (buffer-live-p buffer)
              (kill-buffer buffer)))))
    (error
     (list :status nil :error 'connection-failed
           :message (error-message-string err)))))

(defun seshat-transport--curl-headers (file)
  "解析 curl `-D' 写出的响应头文件 FILE，返回 `(NAME . VALUE)' alist。
文件不存在或为空时返回 nil；状态行（`HTTP/1.1 200 OK'）与续行被忽略。"
  (if (not (file-exists-p file))
      nil
    (with-temp-buffer
      (insert-file-contents file)
      (let ((headers nil))
        (goto-char (point-min))
        (while (not (eobp))
          (when (looking-at "\\([^:\n]+\\):[ \t]*\\(.*\\)$")
            (push (cons (match-string-no-properties 1)
                        (string-trim-right (match-string-no-properties 2)
                                           "[\r\t ]"))
                  headers))
          (forward-line 1))
        (nreverse headers)))))

(defun seshat-transport--read-file-literally (file)
  "以二进制方式读回 FILE 的全部内容并返回字符串（不解码）。
文件不存在时返回空串。返回值为 unibyte 字符串，二进制安全。"
  (if (not (file-exists-p file))
      ""
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-string))))

(defun seshat-transport--curl-args (method url config-file body-file header-file
                                           request-file headers timeout)
  "构造 curl 的参数列表（**不含程序名**，供 `call-process' 使用）。
METHOD 为 HTTP 方法；URL 为请求地址；CONFIG-FILE 为含认证头的 0600 配置文件；
BODY-FILE 为 `-o' 写响应体的临时文件；HEADER-FILE 为 `-D' 写响应头的临时文件；
REQUEST-FILE 为请求体临时文件（BODY 为 nil 时为 nil）；HEADERS 为附加请求头
alist；TIMEOUT 为秒数或 nil（映射为 `--max-time'）。
关键点：`-w %{http_code}' 只写 stdout，响应体经 `-o' 落盘，两者严格分离。"
  (append
   (list "-s" "-X" method
         "--config" config-file
         "-D" header-file
         "-o" body-file
         "-w" "%{http_code}")
   (when (and (numberp timeout) (> timeout 0))
     (list "--max-time" (number-to-string timeout)))
   (let ((header-args nil))
     (dolist (header headers)
       (setq header-args
             (append header-args
                     (list "-H" (format "%s: %s" (car header) (cdr header))))))
     header-args)
   (when request-file
     (list "--data-binary" (concat "@" request-file)))
   (list url)))

(cl-defun seshat-transport--curl (method url &key body headers timeout binary)
  "用 curl 发送一次请求（`webdav' 后端，Basic Auth）。
METHOD 为请求方法字符串；URL 为完整地址；BODY 为请求体字符串或 nil；
HEADERS 为附加请求头 alist（认证头写入 0600 的 curl 配置文件，不进命令行）；
TIMEOUT 为 curl `--max-time' 秒数（nil 表示不限）；BINARY 仅用于接口对齐——
本后端的响应体本来就经 `insert-file-contents-literally' 读回，恒为原始字节，
不需要也不应该为它改变取法。
响应体经 `-o' 落盘后用 `insert-file-contents-literally' 读回，HTTP 状态码经
`-w %{http_code}' 单独取得，二者互不污染；临时文件由 `unwind-protect' 清理。
返回统一契约 plist（`:body' 为原始字节的 unibyte 字符串），永不抛错。"
  (ignore binary)
  (let ((config-file nil)
        (body-file (make-temp-file "seshat-transport-body-"))
        (header-file (make-temp-file "seshat-transport-headers-"))
        (request-file (and body (make-temp-file "seshat-transport-request-")))
        (stdout ""))
    (unwind-protect
        (condition-case err
            (progn
              (setq config-file (seshat-transport--make-curl-config))
              (when request-file
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert (if (multibyte-string-p body)
                              (encode-coding-string body 'utf-8)
                            body))
                  (write-region (point-min) (point-max) request-file nil
                                'no-message)))
              (let ((exit-code
                     (with-temp-buffer
                       (prog1 (apply #'call-process "curl" nil (current-buffer) nil
                                     (seshat-transport--curl-args
                                      method url config-file body-file header-file
                                      request-file headers timeout))
                         (setq stdout (buffer-string)))))
                    (http-code nil))
                (let ((trimmed (string-trim (or stdout ""))))
                  (when (string-match-p "\\`[0-9]+\\'" trimmed)
                    (setq http-code (string-to-number trimmed))))
                (let ((parsed (seshat-transport--parse-curl exit-code stdout
                                                            http-code)))
                  (if (plist-get parsed :status)
                      (append parsed
                              (list :headers
                                    (seshat-transport--curl-headers header-file)
                                    :body (seshat-transport--read-file-literally
                                           body-file)))
                    parsed))))
          (error
           (list :status nil :error 'connection-failed
                 :message (error-message-string err))))
      (dolist (file (list config-file body-file header-file request-file))
        (when (and file (file-exists-p file))
          (delete-file file))))))

(cl-defun seshat-transport-request (method url &key body headers timeout binary)
  "向 URL 同步发送一次 METHOD 请求并等待响应。
METHOD 为请求方法字符串（\"GET\"、\"PUT\"、\"POST\"、\"DELETE\" 等）；
URL 为完整绝对地址；BODY 为可选的请求体字符串（UTF-8 编码后发送）；
HEADERS 为可选附加请求头 alist（`(NAME . VALUE)'），认证头由本模块按
`seshat-transport-backend' 前置添加，调用方不要重复提供；
TIMEOUT 为可选超时秒数（两个后端都生效：`rest' 后端传入
`url-retrieve-synchronously' 的 TIMEOUT，`webdav' 后端映射为 curl
`--max-time'；nil 或非正数表示不限）；
BINARY 为可选「响应体是二进制」标志：nil（默认）时 `rest' 后端把响应体按
UTF-8 解码（既有文本口径，JSON / 纯文本调用方依赖它）；非 nil 时 `:body' 为
**原始字节的 unibyte 字符串**，全程不经编码转换——下载 EPUB / PDF / 附件等
必须传 `:binary t'。

成功返回 plist `(:status N :headers ALIST :body STRING)'，STATUS 为整数 HTTP
状态码、BODY 为响应体字符串（无响应体时为 \"\"）。连接失败返回
`(:status nil :error SYMBOL :message STRING)'，SYMBOL 为 `connection-failed'、
`timeout' 或 `dns-failed' 之一，MESSAGE 为底层错误描述（可选字段）。

本函数**永不抛错**：调用方应按 `:status' 分支处理失败。抛错由上层薄包装
（`seshat-rest--request'）负责。`seshat-transport--raw' 非 nil 时直接
funcall 该桩函数（测试注入）。"
  (funcall (or seshat-transport--raw
               (alist-get seshat-transport-backend
                          seshat-transport--backend-functions)
               #'seshat-transport--url)
           method url :body body :headers headers :timeout timeout
           :binary binary))

(provide 'seshat-transport)
;;; seshat-transport.el ends here
