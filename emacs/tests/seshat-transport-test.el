;;; seshat-transport-test.el --- ERT tests for seshat-transport  -*- lexical-binding: t; -*-

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

;; `seshat-transport' 的 ERT 测试套件，同时覆盖它的上层薄包装
;; `seshat-rest--request'（M1 抛错语义）与 curl 后端的 body / http_code
;; 分离（M2）、后端凭据路由（M3）与空 token 行为（m2）。
;;
;; 全部用例**绝不触网**：统一用 `cl-letf' 桩替网络出口——
;; `seshat-transport--raw'（传输层注入点）与 `url-retrieve-synchronously'、
;; `call-process'；其余用例只断言纯函数
;; （`seshat-transport--parse-url-response'、`seshat-transport--parse-curl'、
;; `seshat-transport-header'）。任何真实 HTTP 调用都不会发生。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-transport)
(require 'seshat-rest)

;;; 测试辅助

(defun seshat-transport-test--url-buffer (headers body &optional status-line)
  "构造一个模拟 url.el 响应缓冲区并返回。
HEADERS 为响应头 alist，BODY 为响应体字符串；STATUS-LINE 缺省为 200 状态行。
调用方负责在用完后 kill 该缓冲区。"
  (let ((buffer (generate-new-buffer " *seshat-transport-test-response*")))
    (with-current-buffer buffer
      (insert (format "%s\r\n" (or status-line "HTTP/1.1 200 OK")))
      (dolist (header headers)
        (insert (format "%s: %s\r\n" (car header) (cdr header))))
      (insert "\r\n")
      (insert body))
    buffer))

(defun seshat-transport-test--write-file-literally (file content)
  "把 CONTENT（unibyte 字符串）以不解码的方式写入 FILE。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert content)
    (let ((coding-system-for-write 'no-conversion))
      (write-region (point-min) (point-max) file nil 'no-message))))

(defun seshat-transport-test--set-globals (alist)
  "把 ALIST（(变量名 . 值)…）设为全局值，返回用于恢复的旧值记录。
`seshat-sync-username' / `seshat-sync-token' 由 `seshat-sync.el' 定义，本套件
不加载该文件，故 `seshat-transport.el' 只做 bare `defvar' 声明（运行时**不是**
special 变量），`let' 绑定对被测代码不可见——这里改用全局赋值以真实检验凭据路由。"
  (mapcar (lambda (pair)
            (let* ((symbol (car pair))
                   (old (if (boundp symbol)
                            (cons t (symbol-value symbol))
                          (cons nil nil))))
              (set symbol (cdr pair))
              (cons symbol old)))
          alist))

(defun seshat-transport-test--restore-globals (saved)
  "恢复 `seshat-transport-test--set-globals' 记录的全局变量状态。"
  (dolist (entry saved)
    (let ((symbol (car entry))
          (old (cdr entry)))
      (if (car old)
          (set symbol (cdr old))
        (makunbound symbol)))))

;;; seshat-transport-request：桩 seshat-transport--raw

(ert-deftest seshat-transport-request-passes-get-without-body ()
  "GET 请求把 method / url / headers 原样交给后端，BODY 为 nil。"
  (let* ((captured nil)
         (seshat-transport--raw
          (lambda (method url &rest args)
            (setq captured (cons method (cons url args)))
            (list :status 200 :headers nil :body "ok")))
         (headers '(("Accept" . "application/json")))
         (response (seshat-transport-request
                    "GET" "https://example.com/api/x" :headers headers)))
    (should (equal (nth 0 captured) "GET"))
    (should (equal (nth 1 captured) "https://example.com/api/x"))
    (should (equal (plist-get (cddr captured) :headers) headers))
    (should-not (plist-get (cddr captured) :body))
    (should (equal response '(:status 200 :headers nil :body "ok")))))

(ert-deftest seshat-transport-request-passes-put-with-body-and-headers ()
  "PUT 请求把 body 与附加请求头一并交给后端。"
  (let* ((captured nil)
         (seshat-transport--raw
          (lambda (method url &rest args)
            (setq captured (cons method (cons url args)))
            (list :status 201 :headers nil :body "")))
         (headers '(("Accept" . "application/json")
                    ("Content-Type" . "application/json")))
         (response (seshat-transport-request
                    "PUT" "https://example.com/api/progress/X"
                    :body "{\"position\":\"p1\"}"
                    :headers headers
                    :timeout 5)))
    (should (equal (nth 0 captured) "PUT"))
    (should (equal (plist-get (cddr captured) :body) "{\"position\":\"p1\"}"))
    (should (equal (plist-get (cddr captured) :headers) headers))
    (should (equal (plist-get (cddr captured) :timeout) 5))
    (should (equal (plist-get response :status) 201))))

(ert-deftest seshat-transport-request-returns-error-plist-without-signaling ()
  "桩返回 (:status nil :error …) 时 `seshat-transport-request` 原样返回，不抛错。"
  (let ((seshat-transport--raw
         (lambda (&rest _args) (list :status nil :error 'connection-failed))))
    (let ((response (seshat-transport-request "GET" "https://example.com/api/x")))
      (should-not (plist-get response :status))
      (should (eq (plist-get response :error) 'connection-failed)))))

(ert-deftest seshat-transport-request-dispatches-to-curl-for-webdav ()
  "`seshat-transport-backend' 为 webdav 时请求走 curl（而非 url.el）。"
  (let ((called-program nil)
        (seshat-transport-backend 'webdav))
    (cl-letf (((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest _args)
                 (setq called-program program)
                 0)))
      (seshat-transport-request "GET" "https://example.com/dav/x")
      (should (equal called-program "curl")))))

;;; 纯函数：seshat-transport--parse-url-response

(ert-deftest seshat-transport-parse-url-response-200 ()
  "200 响应归一化为 (:status 200 :headers … :body …)，且解析出响应头。"
  (let ((buffer (seshat-transport-test--url-buffer
                 '(("ETag" . "\"blob123\"")
                   ("Content-Type" . "application/json"))
                 "{\"uid\":\"X\"}")))
    (unwind-protect
        (let ((parsed (seshat-transport--parse-url-response buffer 200)))
          (should (equal (plist-get parsed :status) 200))
          (should (equal (plist-get parsed :body) "{\"uid\":\"X\"}"))
          (should (equal (seshat-transport-header (plist-get parsed :headers)
                                                  "etag")
                         "\"blob123\"")))
      (kill-buffer buffer))))

(ert-deftest seshat-transport-parse-url-response-304-has-empty-body ()
  "304 响应无响应体，`:body` 归一化为空串（而非 nil）。"
  (let ((buffer (seshat-transport-test--url-buffer
                 nil "" "HTTP/1.1 304 Not Modified")))
    (unwind-protect
        (let ((parsed (seshat-transport--parse-url-response buffer 304)))
          (should (equal (plist-get parsed :status) 304))
          (should (equal (plist-get parsed :body) "")))
      (kill-buffer buffer))))

(ert-deftest seshat-transport-parse-url-response-412-keeps-text-body ()
  "412 响应保留状态码与响应体原文（body 不被丢弃、不被判成失败）。"
  (let* ((body "{\"error\":{\"code\":\"precondition_failed\"}}")
         (buffer (seshat-transport-test--url-buffer
                  nil body "HTTP/1.1 412 Precondition Failed")))
    (unwind-protect
        (let ((parsed (seshat-transport--parse-url-response buffer 412)))
          (should (equal (plist-get parsed :status) 412))
          (should (equal (plist-get parsed :body) body)))
      (kill-buffer buffer))))

(ert-deftest seshat-transport-parse-url-response-nil-status-is-connection-failed ()
  "状态码缺失（非整数）时归一化为连接失败，不返回整数状态。"
  (let ((buffer (seshat-transport-test--url-buffer nil "")))
    (unwind-protect
        (let ((parsed (seshat-transport--parse-url-response buffer nil)))
          (should-not (plist-get parsed :status))
          (should (eq (plist-get parsed :error) 'connection-failed)))
      (kill-buffer buffer))))

;;; 纯函数：seshat-transport--parse-curl

(ert-deftest seshat-transport-parse-curl-success ()
  "curl 退出码 0 且 http_code 为 200 时返回 (:status 200)。"
  (should (equal (seshat-transport--parse-curl 0 "200" 200) '(:status 200))))

(ert-deftest seshat-transport-parse-curl-timeout ()
  "curl 退出码 28 映射为 `timeout`。"
  (let ((parsed (seshat-transport--parse-curl 28 "" nil)))
    (should-not (plist-get parsed :status))
    (should (eq (plist-get parsed :error) 'timeout))))

(ert-deftest seshat-transport-parse-curl-dns-failed ()
  "curl 退出码 6 映射为 `dns-failed`。"
  (let ((parsed (seshat-transport--parse-curl 6 "" nil)))
    (should-not (plist-get parsed :status))
    (should (eq (plist-get parsed :error) 'dns-failed))))

(ert-deftest seshat-transport-parse-curl-connection-failed ()
  "curl 退出码 7（及其它未列出的非零码）映射为 `connection-failed`。"
  (let ((parsed (seshat-transport--parse-curl 7 "" nil)))
    (should-not (plist-get parsed :status))
    (should (eq (plist-get parsed :error) 'connection-failed)))
  (let ((parsed (seshat-transport--parse-curl 56 "" nil)))
    (should (eq (plist-get parsed :error) 'connection-failed))))

(ert-deftest seshat-transport-parse-curl-parses-http-code-from-output ()
  "HTTP-CODE 为 nil 时从 curl 标准输出解析状态码。"
  (should (equal (seshat-transport--parse-curl 0 " 206\n" nil) '(:status 206))))

;;; 纯函数：seshat-transport-header

(ert-deftest seshat-transport-header-is-case-insensitive ()
  "`seshat-transport-header` 对头名大小写不敏感（双向命中），未命中返回 nil。"
  (let ((headers '(("ETag" . "\"v1\"")
                   ("Content-Type" . "application/json"))))
    (should (equal (seshat-transport-header headers "etag") "\"v1\""))
    (should (equal (seshat-transport-header headers "ETAG") "\"v1\""))
    (should (equal (seshat-transport-header '(("etag" . "x")) "ETag") "x"))
    (should-not (seshat-transport-header headers "If-Match"))))

;;; 凭据路由（M3）与空 token 行为（m2）

(ert-deftest seshat-transport-rest-auth-header-keeps-empty-token ()
  "空令牌仍构造 `Authorization: Bearer ` 头（不跳过认证头）。"
  (let ((seshat-rest-token ""))
    (should (equal (seshat-transport--rest-auth-header)
                   '("Authorization" . "Bearer ")))
    (should (equal (seshat-transport--auth-header)
                   '("Authorization" . "Bearer ")))))

(ert-deftest seshat-transport-webdav-auth-header-is-basic ()
  "webdav 后端构造 `Authorization: Basic base64(user:token)` 头（M3）。"
  (let ((saved (seshat-transport-test--set-globals
                '((seshat-sync-username . "seshat")
                  (seshat-sync-token . "s3cret")))))
    (unwind-protect
        (progn
          (should (equal (seshat-transport--webdav-auth-header)
                         (cons "Authorization"
                               (concat "Basic "
                                       (base64-encode-string "seshat:s3cret" t)))))
          (let ((seshat-transport-backend 'webdav))
            (should (equal (seshat-transport--auth-header)
                           (seshat-transport--webdav-auth-header)))))
      (seshat-transport-test--restore-globals saved))))

(ert-deftest seshat-transport-webdav-config-file-is-0600-and-holds-header ()
  "webdav 凭据写入 0600 临时 curl 配置文件，以 Basic 头的形式（不出现在 argv）。"
  (let ((saved (seshat-transport-test--set-globals
                '((seshat-sync-username . "seshat")
                  (seshat-sync-token . "s3cret")))))
    (unwind-protect
        (let ((file (seshat-transport--make-curl-config)))
          (unwind-protect
              (progn
                (should (file-exists-p file))
                (should (equal (file-modes file) #o600))
                (with-temp-buffer
                  (insert-file-contents file)
                  (should (string-match-p
                           (regexp-quote
                            (format "Basic %s"
                                    (base64-encode-string "seshat:s3cret" t)))
                           (buffer-string)))
                  (should (string-match-p "header = " (buffer-string)))))
            (when (file-exists-p file) (delete-file file))))
      (seshat-transport-test--restore-globals saved))))

;;; url.el 后端：空 token 仍发送认证头

(ert-deftest seshat-transport-url-backend-sends-bearer-when-token-empty ()
  "走 url.el 后端时空 token 仍发送 `Bearer ` 头，且解析出状态码与响应体。"
  (let ((seshat-rest-token "")
        (captured nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (url &optional _silent _inhibit _timeout)
                 (setq captured (list url url-request-method
                                      url-request-extra-headers
                                      url-request-data))
                 (let ((buffer (generate-new-buffer
                                " *seshat-transport-test-router*")))
                   (with-current-buffer buffer
                     (insert "HTTP/1.1 200 OK\r\nETag: \"v9\"\r\n\r\n{}")
                     (set (make-local-variable 'url-http-response-status) 200))
                   buffer))))
      (let ((response (seshat-transport-request
                       "GET" "https://example.com/api/x"
                       :headers '(("Accept" . "application/json")))))
        (should (equal (plist-get response :status) 200))
        (should (equal (plist-get response :body) "{}"))
        (should (equal (seshat-transport-header (plist-get response :headers)
                                                "etag")
                       "\"v9\""))
        (should (equal (nth 0 captured) "https://example.com/api/x"))
        (should (equal (nth 1 captured) "GET"))
        (should (equal (cdr (assoc "Authorization" (nth 2 captured)))
                       "Bearer "))
        (should (equal (cdr (assoc "Accept" (nth 2 captured)))
                       "application/json"))
        (should-not (nth 3 captured))))))

;;; url.el 后端：请求体编码口径（M8-A 审查 blocking 项，强制用例）
;;
;; `seshat-rest-upload-file' 传给传输层的 `:body' 是 `seshat-rest--binary-string'
;; 产出的 **unibyte 字节串**（即 wire 字节）；`seshat-transport--curl' 也是
;; 「多字节才编码、unibyte 原样」的口径。`--url' 现按同一口径分支，下面三例分别
;; 锁定：unibyte 逐字节原样、多字节按 UTF-8 编码、unibyte 体不得送进编码器。
;;
;; 实测注记（Emacs 31.1）：`encode-coding-string' 对 unibyte 字符串是**逐字节
;; 直通**——`(unibyte-string #x50 #x4b #xff #x00 #xc3)' 编码后仍是同样 5 字节，
;; 因此「走了编码器」与「没走编码器」发出的字节完全相同，纯字节断言区分不出两者。
;; 第三例因此改为监视 `encode-coding-string' 是否被调用，使「无条件再编码」的回归
;; 能被真正打红（变异自检：改回无条件编码 → 该例红，前两例仍绿）。

(defun seshat-transport-test--capture-request-data (body)
  "用 `rest' 后端发一次 PUT（请求体 BODY），返回桩捕获到的 `url-request-data'。
桩同时返回一个合法的 200 响应缓冲区，使 `seshat-transport--url' 能走完整条链路
（`url-request-data' 是 `url-vars' 里的 special 变量，`--url' 的 `let*' 绑定因此
对桩函数可见）。"
  (let* ((captured 'not-captured)
         (seshat-rest-token "")
         (seshat-transport-backend 'rest))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _args)
                 (setq captured url-request-data)
                 (let ((buffer (seshat-transport-test--url-buffer nil "")))
                   (with-current-buffer buffer
                     (set (make-local-variable 'url-http-response-status) 200))
                   buffer))))
      (let ((response (seshat-transport-request
                       "PUT" "https://example.com/api/files/a.epub" :body body)))
        ;; 桩返回的是合法 200 响应，整条 `--url' 链路必须正常收尾。
        (should (equal (plist-get response :status) 200))))
    captured))

(ert-deftest seshat-transport-url-backend-passes-timeout ()
  "`seshat-transport--url' 把 TIMEOUT 作为第四个实参交给
`url-retrieve-synchronously'（第三参 INHIBIT-COOKIES 恒为 t）；TIMEOUT 为 nil
或非正数时该实参为 nil（交回 url.el 默认：不设限）。"
  (let ((captured 'not-captured))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest args)
                 (setq captured args)
                 nil)))
      (seshat-transport--url "GET" "https://example.com/api/x" :timeout 7)
      (should (equal (length captured) 4))
      (should (eq (nth 2 captured) t))
      (should (equal (nth 3 captured) 7))
      (setq captured 'not-captured)
      (seshat-transport--url "GET" "https://example.com/api/x")
      (should (null (nth 3 captured)))
      (setq captured 'not-captured)
      (seshat-transport--url "GET" "https://example.com/api/x" :timeout 0)
      (should (null (nth 3 captured)))
      (setq captured 'not-captured)
      (seshat-transport--url "GET" "https://example.com/api/x" :timeout -3)
      (should (null (nth 3 captured))))))

(ert-deftest seshat-transport-url-backend-sends-unibyte-body-verbatim ()
  "unibyte 请求体**逐字节原样**发出，wire 形态与输入完全相同。
与 `seshat-transport--curl' 的口径一致：unibyte 串本身就是 wire 字节序列，
不得再经任何 coding-system 往返。"
  (let* ((payload (unibyte-string #x50 #x4b #xff #x00 #xc3))
         (sent (seshat-transport-test--capture-request-data payload)))
    (should (equal sent payload))
    (should (equal (string-to-list sent) (string-to-list payload)))
    (should (= (length sent) 5))
    (should-not (multibyte-string-p sent))))

(ert-deftest seshat-transport-url-backend-encodes-multibyte-body-as-utf8 ()
  "多字节请求体（中文文本）仍按 UTF-8 编码成 wire 字节发出——
`seshat-rest--request' 等 JSON / 文本调用方依赖这一档口径。"
  (let* ((body "中文")
         (sent (seshat-transport-test--capture-request-data body)))
    (should (equal sent (encode-coding-string body 'utf-8)))
    (should (equal (string-to-list sent)
                   (string-to-list (encode-coding-string "中文" 'utf-8))))
    (should (= (length sent) 6))
    (should-not (multibyte-string-p sent))))

(ert-deftest seshat-transport-url-backend-does-not-encode-unibyte-body ()
  "口径锁定：unibyte 请求体**不得**送进 `encode-coding-string'（与 `--curl' 对齐）。
为什么需要监视调用而不是只比字节：实测 Emacs 31.1 下 `encode-coding-string' 对
unibyte 字符串是**逐字节直通**（`(unibyte-string 255)` 编码后仍是 `255`，长度不变），
因此「走了编码器」与「没走编码器」发出的字节完全相同、单看字节无法区分。
本用例监视 `encode-coding-string' 是否被调用，使「无条件再编码」的回归能被真正
打红；紧随其后的多字节对照组确保这条监视不是空转通过。"
  (let* ((payload (unibyte-string #x50 #x4b #xff #x00 #xc3))
         (encoded-args nil)
         (seshat-rest-token "")
         (seshat-transport-backend 'rest)
         (original (symbol-function 'encode-coding-string)))
    (cl-letf (((symbol-function 'encode-coding-string)
               (lambda (string &rest args)
                 (push string encoded-args)
                 (apply original string args)))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _args)
                 (let ((buffer (seshat-transport-test--url-buffer nil "")))
                   (with-current-buffer buffer
                     (set (make-local-variable 'url-http-response-status) 200))
                   buffer))))
      (seshat-transport-request "PUT" "https://example.com/api/files/a.epub"
                                :body payload)
      ;; ① unibyte 体：编码器一次都不该被调用。
      (should-not encoded-args)
      ;; ② 对照组：多字节体必须被调用（且参数就是原体），证明监视确实生效。
      (seshat-transport-request "PUT" "https://example.com/api/files/a.org"
                                :body "中文")
      (should (equal encoded-args '("中文"))))))

;;; curl 凭据文件：权限先于内容

(ert-deftest seshat-transport-curl-config-is-0600-before-content-is-written ()
  "凭据文件在**写入内容之前**就已是 0600（而非先写后 chmod），写完复核仍 0600。

为什么桩 `make-temp-file'：本机实测 `make-temp-file' 建出的文件本来就是 0600
（umask 022），旧代码「先写后 chmod」在这台机器上也不会留下可见窗口，纯看最终
权限无法区分两种顺序。因此本用例先把 `make-temp-file' 的结果 chmod 到 0666
（模拟按 `0666 & ~umask' 建文件的平台 / Emacs 版本），再用桩 `write-region'
记录「写入瞬间」的权限：先写后 chmod 时该瞬间读到 0666 → 用例红。"

  (let* ((saved (seshat-transport-test--set-globals
                 '((seshat-sync-username . "seshat")
                   (seshat-sync-token . "s3cret"))))
         (modes-at-write nil)
         (file nil)
         (original-write (symbol-function 'write-region))
         (original-make-temp-file (symbol-function 'make-temp-file)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'make-temp-file)
                     (lambda (&rest args)
                       (let ((created (apply original-make-temp-file args)))
                         ;; 模拟「初始权限 = 0666 & ~umask」的平台。
                         (set-file-modes created #o666)
                         created)))
                    ((symbol-function 'write-region)
                     (lambda (start end filename &rest args)
                       (when (and (stringp filename) (null modes-at-write))
                         (setq modes-at-write (file-modes filename)))
                       (apply original-write start end filename args))))
            (setq file (seshat-transport--make-curl-config)))
          (should (stringp file))
          (should (file-exists-p file))
          ;; ① 写入内容的那一刻权限必须已经是 0600（旧序此时读到 0666 → 红）。
          (should (equal modes-at-write #o600))
          ;; ② 写完后复核仍是 0600（`write-region' 不会重置权限）。
          (should (equal (file-modes file) #o600))
          ;; ③ 文件内容确实是 Basic 认证头（凭据不出现于命令行）。
          (let ((content (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))))
            (should (string-match-p "Authorization: Basic" content))
            (should (string-match-p
                     (regexp-quote (base64-encode-string "seshat:s3cret" t))
                     content))))
      (when (and file (file-exists-p file)) (delete-file file))
      (seshat-transport-test--restore-globals saved))))

;;; curl 后端：参数构造与 body / http_code 分离（M2，强制用例）

(ert-deftest seshat-transport-curl-args-exclude-program-name ()
  "curl 参数列表不含程序名（供 `call-process` 直接用），且关键参数成对出现。
这是实测回归点：列表里混入 \"curl\" 时 `call-process` 会把它当成第一个 URL。"
  (let ((args (seshat-transport--curl-args
               "PUT" "https://example.com/dav/x" "/cfg" "/body" "/hdrs" "/req"
               '(("Accept" . "application/json")) 7)))
    (should-not (member "curl" args))
    (should (equal (car args) "-s"))
    (should (equal (last args) (list "https://example.com/dav/x")))
    (should (equal (cadr (member "-o" args)) "/body"))
    (should (equal (cadr (member "-D" args)) "/hdrs"))
    (should (equal (cadr (member "-w" args)) "%{http_code}"))
    (should (equal (cadr (member "--config" args)) "/cfg"))
    (should (equal (cadr (member "--max-time" args)) "7"))
    (should (equal (cadr (member "-H" args)) "Accept: application/json"))
    (should (equal (cadr (member "--data-binary" args)) "@/req"))))

(ert-deftest seshat-transport-curl-separates-body-from-http-code ()
  "桩 `call-process` 时：body 含换行与二进制字节仍完整，`:status` 取自 http_code。
`-o <BODY-TEMP>` 与 `-w %{http_code}` 严格分离，状态码不污染 body。"
  (let* ((binary-body (concat (encode-coding-string "line-1\nline-2\n" 'utf-8)
                              (unibyte-string 0 1 255 10)))
         (seshat-transport-backend 'webdav)
         (captured-args nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile destination _display &rest args)
                 (setq captured-args args)
                 (let ((body-file (cadr (member "-o" args)))
                       (header-file (cadr (member "-D" args))))
                   (should body-file)
                   (should header-file)
                   (seshat-transport-test--write-file-literally
                    body-file binary-body)
                   (seshat-transport-test--write-file-literally
                    header-file
                    (encode-coding-string
                     "HTTP/1.1 200 OK\r\nETag: \"blob7\"\r\n\r\n" 'utf-8)))
                 (let ((target (if (bufferp destination) destination
                                 (current-buffer))))
                   (with-current-buffer target
                     (goto-char (point-max))
                     (insert "200")))
                 0)))
      (let ((response (seshat-transport-request
                       "GET" "https://example.com/dav/x")))
        (should (equal (plist-get response :status) 200))
        (should (equal (plist-get response :body) binary-body))
        (should-not (string-match-p "200" (plist-get response :body)))
        (should (equal (seshat-transport-header (plist-get response :headers)
                                                "etag")
                       "\"blob7\""))
        (should (equal (cadr (member "-w" captured-args)) "%{http_code}"))))))

;;; 薄包装 `seshat-rest--request`（M1，强制用例）

(ert-deftest seshat-rest-request-signals-on-transport-failure ()
  "传输层返回 (:status nil :error connection-failed) 时薄包装**抛 error**，
不返回 (nil . BODY)（4 处生产调用方依赖抛错），且沿用既有文案前缀。"
  (let ((seshat-transport--raw
         (lambda (&rest _args)
           (list :status nil :error 'connection-failed))))
    (let ((err (should-error (seshat-rest--request "GET" "/api/resolve")
                             :type 'error)))
      (should (string-match-p "seshat-rest: 请求 GET " (error-message-string err)))
      (should (string-match-p "失败" (error-message-string err))))))

(ert-deftest seshat-rest-request-success-keeps-cons-contract ()
  "薄包装成功路径仍返回 (STATUS . BODY-STRING) 形态（契约不变）。"
  (let ((seshat-transport--raw
         (lambda (&rest _args)
           (list :status 200 :headers '(("ETag" . "\"v1\""))
                 :body "{\"uid\":\"X\"}"))))
    (should (equal (seshat-rest--request "GET" "/api/resolve")
                   '(200 . "{\"uid\":\"X\"}"))))
  (let ((seshat-transport--raw
         (lambda (&rest _args) (list :status 204 :headers nil :body nil))))
    (should (equal (seshat-rest--request "DELETE" "/api/annotations/1")
                   '(204 . "")))))

(ert-deftest seshat-rest-request-builds-accept-and-content-type ()
  "薄包装按既有口径构造请求头：总有 Accept，仅带 body 时才有 Content-Type。"
  (let* ((captured nil)
         (seshat-transport--raw
          (lambda (method url &rest args)
            (setq captured (list method url args))
            (list :status 200 :headers nil :body ""))))
    (seshat-rest--request "GET" "/api/progress/X")
    (should (equal (nth 0 captured) "GET"))
    (should (equal (nth 1 captured) "https://example.com/api/progress/X"))
    (should (equal (cdr (assoc "Accept" (plist-get (nth 2 captured) :headers)))
                   "application/json"))
    (should-not (assoc "Content-Type" (plist-get (nth 2 captured) :headers)))
    (should-not (plist-get (nth 2 captured) :body))
    (seshat-rest--request "PUT" "/api/progress/X" "{\"position\":\"p\"}")
    (should (equal (cdr (assoc "Content-Type"
                               (plist-get (nth 2 captured) :headers)))
                   "application/json"))
    (should (equal (plist-get (nth 2 captured) :body) "{\"position\":\"p\"}"))))

;;; `:binary' 响应体口径（二进制下载，M8-A 缺口修复）
;;
;; `seshat-rest-download-file' 是 `ondemand' 根（只走 REST）下载 EPUB / PDF 的
;; 唯一通道，而 `rest' 后端默认按 UTF-8 解码响应体——非 UTF-8 字节因此被改写。
;; 下面四例锁定 `:binary' 的两档语义：nil 维持既有文本口径（硬约束），非 nil
;; 逐字节保真且 body 为 unibyte 字符串。

(ert-deftest seshat-transport-parse-url-response-binary-preserves-raw-bytes ()
  "强制用例：同一响应缓冲区，`:binary' 为 nil 时响应体**被破坏**（与原始字节
不相等），为 t 时**逐字节相等**且为 unibyte 字符串。
样例为 EPUB（zip 容器）魔数加高位字节与 NUL——`0xff' 在 UTF-8 口径下会被改写。"
  (let* ((payload (unibyte-string #x50 #x4b #x03 #x04 #xff #x00 #xc3))
         (buffer (seshat-transport-test--url-buffer
                  '(("Content-Type" . "application/epub+zip")
                    ("ETag" . "\"blob-epub\""))
                  payload)))
    (unwind-protect
        (progn
          ;; ① 现状（binary 为 nil）：解码口径破坏字节，与原始字节不相等。
          (let ((decoded-body (plist-get (seshat-transport--parse-url-response
                                          buffer 200)
                                         :body)))
            (should-not (equal decoded-body payload)))
          ;; ② binary 为 t：原始字节，逐字节相等，且是 unibyte 字符串。
          (let* ((parsed (seshat-transport--parse-url-response buffer 200 t))
                 (body (plist-get parsed :body)))
            (should (equal (plist-get parsed :status) 200))
            (should-not (multibyte-string-p body))
            (should (equal body payload))
            (should (equal (string-to-list body) (string-to-list payload)))
            (should (equal (length body) 7))
            ;; 响应头（ASCII）照常解析，不受二进制口径影响。
            (should (equal (seshat-transport-header (plist-get parsed :headers)
                                                    "content-type")
                           "application/epub+zip"))))
      (kill-buffer buffer))))

(ert-deftest seshat-transport-parse-url-response-default-decodes-utf8 ()
  "回归：`:binary' 为 nil（默认）时 UTF-8 文本仍正常解码为多字节字符串。
硬约束——`seshat-rest--request' 与 4 处 JSON 调用方全靠这一口径。"
  (let ((buffer (seshat-transport-test--url-buffer
                 '(("Content-Type" . "application/json"))
                 "{\"位置\":\"第三章 中文标题\"}")))
    (unwind-protect
        (let ((body (plist-get (seshat-transport--parse-url-response buffer 200)
                               :body)))
          (should (equal body "{\"位置\":\"第三章 中文标题\"}"))
          (should (multibyte-string-p body)))
      (kill-buffer buffer))))

(ert-deftest seshat-transport-request-passes-binary-flag-to-backend ()
  "`seshat-transport-request' 把 `:binary' 透传给后端：传 t 时桩收到 t，
未传时为 nil（`seshat-rest--request' 等 JSON 调用方不受影响）。"
  (let ((captured nil))
    (let ((seshat-transport--raw
           (lambda (method url &rest args)
             (setq captured (list method url args))
             (list :status 200 :headers nil :body ""))))
      (seshat-transport-request "GET" "https://example.com/api/files/a.epub"
                                :binary t)
      (should (eq (plist-get (nth 2 captured) :binary) t))
      (seshat-transport-request "GET" "https://example.com/api/progress/X")
      (should-not (plist-get (nth 2 captured) :binary)))))

(ert-deftest seshat-transport-url-backend-binary-body-is-unibyte ()
  "端到端（真实 `rest' 后端，桩 `url-retrieve-synchronously'）：`:binary t` 时
`:body` 为 unibyte 原始字节，逐字节等于响应缓冲区里的内容。"
  (let* ((payload (unibyte-string #x50 #x4b #x03 #x04 #xff #x00 #xc3))
         (seshat-rest-token "")
         (seshat-transport-backend 'rest))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _args)
                 (let ((buffer (seshat-transport-test--url-buffer nil payload)))
                   (with-current-buffer buffer
                     (set (make-local-variable 'url-http-response-status) 200))
                   buffer))))
      (let ((body (plist-get (seshat-transport-request
                              "GET" "https://example.com/api/files/a.epub"
                              :binary t)
                             :body)))
        (should-not (multibyte-string-p body))
        (should (equal body payload))))))

(ert-deftest seshat-transport-curl-binary-body-is-raw-bytes ()
  "curl 后端接受 `:binary' 且行为不变：`-o' 落盘的响应体经
`insert-file-contents-literally' 读回，`-w %{http_code}' 不污染 body——
`:binary t' 与非 nil 时都得到原始字节（unibyte）。"
  (let* ((payload (unibyte-string #x50 #x4b #x03 #x04 #xff #x00 #xc3))
         (seshat-transport-backend 'webdav))
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile destination _display &rest args)
                 (seshat-transport-test--write-file-literally
                  (cadr (member "-o" args)) payload)
                 (seshat-transport-test--write-file-literally
                  (cadr (member "-D" args))
                  "HTTP/1.1 200 OK\r\n\r\n")
                 (let ((target (if (bufferp destination) destination
                                 (current-buffer))))
                   (with-current-buffer target
                     (goto-char (point-max))
                     (insert "200")))
                 0)))
      (let* ((response (seshat-transport-request
                        "GET" "https://example.com/dav/a.epub" :binary t))
             (body (plist-get response :body)))
        (should (equal (plist-get response :status) 200))
        (should-not (multibyte-string-p body))
        (should (equal body payload))))))

(ert-deftest seshat-transport-parse-url-response-binary-with-unibyte-buffer ()
  "与真实现场一致的强制用例：`url-retrieve-synchronously' 返回的响应缓冲区是
**unibyte**（实测），此时 `:binary' 为 nil 会走 `decode-coding-string'，非 UTF-8
字节被改写；为 t 时逐字节保真。
本例与 `...-binary-preserves-raw-bytes' 互补：那例覆盖多字节缓冲区，本例覆盖
真实的 unibyte 缓冲区（即生产路径）。"
  (let* ((payload (unibyte-string #x50 #x4b #x03 #x04 #xff #x00 #xc3))
         (buffer (seshat-transport-test--url-buffer nil payload)))
    ;; 把响应缓冲区改成 unibyte——url.el 对二进制响应体就是这样交付的。
    (with-current-buffer buffer
      (set-buffer-multibyte nil))
    (unwind-protect
        (progn
          (should-not (buffer-local-value 'enable-multibyte-characters buffer))
          ;; ① 现状（binary 为 nil）：按 UTF-8 解码，字节被改写。
          (let ((decoded (plist-get (seshat-transport--parse-url-response buffer 200)
                                    :body)))
            (should (multibyte-string-p decoded))
            (should-not (equal decoded payload)))
          ;; ② binary 为 t：逐字节相等。
          (let ((body (plist-get (seshat-transport--parse-url-response buffer 200 t)
                                 :body)))
            (should-not (multibyte-string-p body))
            (should (equal body payload))))
      (kill-buffer buffer))))

(provide 'seshat-transport-test)
;;; seshat-transport-test.el ends here
