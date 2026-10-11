;;; notes-sync.el --- 笔记 WebDAV 文件同步 -*- lexical-binding: t; -*-

;; Copyright (C) 2025 notes project

;; Author: notes project
;; Version: 0.1.0
;; Keywords: tools, comm
;; Package-Requires: ((emacs "27.1"))

;; 本文件不属于 GNU Emacs。

;;; Commentary:

;; 通过 curl 命令封装 WebDAV 操作，实现本地 org 笔记目录与服务端之间的
;; 文件同步。选择 curl 而非 tramp-dav，是因为 curl 行为更可控、更可靠。
;;
;; 服务端使用 Basic Auth（用户名任意，令牌作为密码），WebDAV 端点前缀为
;; "/dav"，远端笔记位于 `notes-sync-remote-dir' 指定的子目录下。
;;
;; 使用方式：先设置 `notes-sync-server-url'、`notes-sync-username'、
;; `notes-sync-token'、`notes-sync-local-dir'、`notes-sync-remote-dir'，
;; 再调用 `notes-sync-profind'、`notes-sync-get'、`notes-sync-put'、
;; `notes-sync-delete' 等函数。

;;; Code:

(defgroup notes-sync nil
  "笔记 WebDAV 文件同步。"
  :group 'tools
  :prefix "notes-sync-")

(defcustom notes-sync-server-url "https://example.com"
  "服务端根 URL，例如 \"https://example.com\"。
末尾不要带斜杠，拼接时会自动规范。"
  :type 'string
  :group 'notes-sync)

(defcustom notes-sync-username "notes"
  "Basic Auth 用户名。服务端用户名任意，此处默认 \"notes\"。"
  :type 'string
  :group 'notes-sync)

(defcustom notes-sync-token ""
  "Basic Auth 密码，即访问令牌。"
  :type 'string
  :group 'notes-sync)

(defcustom notes-sync-local-dir "~/notes"
  "本地笔记目录的绝对路径。"
  :type 'directory
  :group 'notes-sync)

(defcustom notes-sync-remote-dir "notes"
  "远端笔记所在的子目录名（相对于 WebDAV 端点）。"
  :type 'string
  :group 'notes-sync)

(defun notes-sync--make-config-file ()
  "创建仅含 Basic Auth 凭据的临时 curl 配置文件，返回其绝对路径。
文件内容为 `user = \"用户名:令牌\"'，以 0600 权限（仅属主可读写）写入，
凭据因此不再出现在命令行参数中，避免暴露于进程列表（ps 可见）。
调用方负责使用后删除该文件（见 `notes-sync--request'）。"
  (let ((file (make-temp-file "notes-sync-" nil ".curlrc"))
        (credential (format "%s:%s" notes-sync-username notes-sync-token)))
    (condition-case err
        (progn
          (with-temp-file file
            ;; %S 输出带双引号并转义 \\ 与 \"，与 curl 配置文件语法兼容。
            (insert (format "user = %S\n" credential)))
          (set-file-modes file #o600)
          file)
      (error
       (delete-file file)
       (signal (car err) (cdr err))))))

(defun notes-sync--curl-args (method url extra-args config-file)
  "构造 curl 命令行参数列表。
METHOD 为 HTTP 方法字符串，例如 \"PROPFIND\"；
URL 为请求地址；
EXTRA-ARGS 为附加参数列表，例如 (\"-o\" \"file\") 或 (\"-H\" \"Depth: 1\")；
CONFIG-FILE 为含 Basic Auth 凭据的临时配置文件路径，凭据经 curl 的
--config CONFIG-FILE 读取，不再以 -u \"user:token\" 形式出现在命令行中。
返回值固定包含 -s、-X METHOD 以及 --config CONFIG-FILE 参数，
末尾追加 URL。"
  (append (list "-s" "-X" method "--config" config-file)
          extra-args
          (list url)))

(defun notes-sync--webdav-url (remote-path)
  "拼接 REMOTE-PATH 对应的完整 WebDAV URL。
REMOTE-PATH 为相对远端笔记目录的路径，可以带或不带前导斜杠。"
  (concat (replace-regexp-in-string "/+\\'" "" notes-sync-server-url)
          "/dav/"
          (replace-regexp-in-string "/+\\'" "" notes-sync-remote-dir)
          (if (string-prefix-p "/" remote-path)
              remote-path
            (concat "/" remote-path))))

(defun notes-sync--request (method url extra-args)
  "调用 curl 执行一次 WebDAV 请求。
METHOD 为 HTTP 方法，URL 为请求地址，EXTRA-ARGS 为附加参数列表。
Basic Auth 凭据写入 0600 权限的临时 curl 配置文件，经 --config 传给
curl，避免令牌出现在命令行参数中；请求结束后立即删除该临时文件，
unwind-protect 保证即使子进程调用出错也会删除。
返回 (EXIT-CODE . OUTPUT) 形式的 cons，其中 EXIT-CODE 为 curl 退出码
（0 表示成功），OUTPUT 为子进程写入标准输出/标准错误的内容。"
  (let ((config-file (notes-sync--make-config-file)))
    (unwind-protect
        (with-temp-buffer
          (let ((code (apply #'call-process "curl" nil (current-buffer) nil
                             (notes-sync--curl-args method url extra-args
                                                    config-file))))
            (cons code (buffer-string))))
      (when (file-exists-p config-file)
        (delete-file config-file)))))

(defun notes-sync-profind (remote-path)
  "对远端 REMOTE-PATH 执行 PROPFIND 请求（Depth: 1）。
返回响应 XML 字符串；请求失败时返回空字符串。"
  (cdr (notes-sync--request "PROPFIND"
                            (notes-sync--webdav-url remote-path)
                            (list "-H" "Depth: 1"))))

(defun notes-sync-get (remote-path local-path)
  "从远端 REMOTE-PATH 拉取文件，保存到本地 LOCAL-PATH。
返回 curl 退出码，0 表示成功。"
  (car (notes-sync--request "GET"
                            (notes-sync--webdav-url remote-path)
                            (list "-o" (expand-file-name local-path)))))

(defun notes-sync-put (local-path remote-path)
  "将本地 LOCAL-PATH 上传到远端 REMOTE-PATH。
返回 curl 退出码，0 表示成功。"
  (car (notes-sync--request "PUT"
                            (notes-sync--webdav-url remote-path)
                            (list "-T" (expand-file-name local-path)))))

(defun notes-sync-delete (remote-path)
  "删除远端 REMOTE-PATH。
返回 curl 退出码，0 表示成功。"
  (car (notes-sync--request "DELETE"
                            (notes-sync--webdav-url remote-path)
                            nil)))

(defun notes-sync-etag (remote-path)
  "获取远端 REMOTE-PATH 的 ETag（getetag 属性值）。
通过 PROPFIND 取得响应 XML，再用正则提取 <getetag> 元素内容。
返回值可能带有双引号（服务端格式为 \"value\"），获取不到时返回 nil。
供冲突检测（M2.2）使用。"
  (let ((xml (notes-sync-profind remote-path)))
    (when (string-match
           "<\\(?:[A-Za-z0-9_-]+:\\)?getetag[^>]*>\\([^<]*\\)</" xml)
      (match-string 1 xml))))

(provide 'notes-sync)

;;; notes-sync.el ends here
