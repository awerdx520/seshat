;;; seshat-sync.el --- 笔记 WebDAV 文件同步 -*- lexical-binding: t; -*-

;; Copyright (C) 2025 seshat project

;; Author: seshat project
;; Version: 0.1.0
;; Keywords: tools, comm
;; Package-Requires: ((emacs "27.1"))

;; 本文件不属于 GNU Emacs。

;;; Commentary:

;; 通过 curl 命令封装 WebDAV 操作，实现本地 org 笔记目录与服务端之间的
;; 文件同步。选择 curl 而非 tramp-dav，是因为 curl 行为更可控、更可靠。
;;
;; 服务端使用 Basic Auth（用户名任意，令牌作为密码），WebDAV 端点前缀为
;; "/dav"，远端笔记位于 `seshat-sync-remote-dir' 指定的子目录下。
;;
;; 使用方式：先设置 `seshat-sync-server-url'、`seshat-sync-username'、
;; `seshat-sync-token'、`seshat-sync-local-dir'、`seshat-sync-remote-dir'，
;; 再调用 `seshat-sync-profind'、`seshat-sync-get'、`seshat-sync-put'、
;; `seshat-sync-delete' 等函数。

;;; Code:

(require 'cl-lib)
(require 'seshat-rest)
(require 'seshat-state)

(defgroup seshat-sync nil
  "笔记 WebDAV 文件同步。"
  :group 'tools
  :prefix "seshat-sync-")

(defcustom seshat-sync-server-url "https://example.com"
  "服务端根 URL，例如 \"https://example.com\"。
末尾不要带斜杠，拼接时会自动规范。"
  :type 'string
  :group 'seshat-sync)

(defcustom seshat-sync-username "seshat"
  "Basic Auth 用户名。服务端用户名任意，此处默认 \"seshat\"。"
  :type 'string
  :group 'seshat-sync)

(defcustom seshat-sync-token ""
  "Basic Auth 密码，即访问令牌。"
  :type 'string
  :group 'seshat-sync)

(defcustom seshat-sync-local-dir "~/seshat"
  "本地笔记目录的绝对路径。"
  :type 'directory
  :group 'seshat-sync)

(defcustom seshat-sync-remote-dir "seshat"
  "远端笔记所在的子目录名（相对于 WebDAV 端点）。"
  :type 'string
  :group 'seshat-sync)

(defun seshat-sync--make-config-file ()
  "创建仅含 Basic Auth 凭据的临时 curl 配置文件，返回其绝对路径。
文件内容为 `user = \"用户名:令牌\"'，以 0600 权限（仅属主可读写）写入，
凭据因此不再出现在命令行参数中，避免暴露于进程列表（ps 可见）。
调用方负责使用后删除该文件（见 `seshat-sync--request'）。"
  (let ((file (make-temp-file "seshat-sync-" nil ".curlrc"))
        (credential (format "%s:%s" seshat-sync-username seshat-sync-token)))
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

(defun seshat-sync--curl-args (method url extra-args config-file)
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

(defun seshat-sync--webdav-url (remote-path)
  "拼接 REMOTE-PATH 对应的完整 WebDAV URL。
REMOTE-PATH 为相对远端笔记目录的路径，可以带或不带前导斜杠。"
  (concat (replace-regexp-in-string "/+\\'" "" seshat-sync-server-url)
          "/dav/"
          (replace-regexp-in-string "/+\\'" "" seshat-sync-remote-dir)
          (if (string-prefix-p "/" remote-path)
              remote-path
            (concat "/" remote-path))))

(defun seshat-sync--request (method url extra-args)
  "调用 curl 执行一次 WebDAV 请求。
METHOD 为 HTTP 方法，URL 为请求地址，EXTRA-ARGS 为附加参数列表。
Basic Auth 凭据写入 0600 权限的临时 curl 配置文件，经 --config 传给
curl，避免令牌出现在命令行参数中；请求结束后立即删除该临时文件，
unwind-protect 保证即使子进程调用出错也会删除。
返回 (EXIT-CODE . OUTPUT) 形式的 cons，其中 EXIT-CODE 为 curl 退出码
（0 表示成功），OUTPUT 为子进程写入标准输出/标准错误的内容。"
  (let ((config-file (seshat-sync--make-config-file)))
    (unwind-protect
        (with-temp-buffer
          (let ((code (apply #'call-process "curl" nil (current-buffer) nil
                             (seshat-sync--curl-args method url extra-args
                                                    config-file))))
            (cons code (buffer-string))))
      (when (file-exists-p config-file)
        (delete-file config-file)))))

(defun seshat-sync-profind (remote-path)
  "对远端 REMOTE-PATH 执行 PROPFIND 请求（Depth: 1）。
返回响应 XML 字符串；请求失败时返回空字符串。"
  (cdr (seshat-sync--request "PROPFIND"
                            (seshat-sync--webdav-url remote-path)
                            (list "-H" "Depth: 1"))))

(defun seshat-sync-get (remote-path local-path)
  "从远端 REMOTE-PATH 拉取文件，保存到本地 LOCAL-PATH。
返回 curl 退出码，0 表示成功。"
  (car (seshat-sync--request "GET"
                            (seshat-sync--webdav-url remote-path)
                            (list "-o" (expand-file-name local-path)))))

(defun seshat-sync-put (local-path remote-path)
  "将本地 LOCAL-PATH 上传到远端 REMOTE-PATH。
返回 curl 退出码，0 表示成功。"
  (car (seshat-sync--request "PUT"
                            (seshat-sync--webdav-url remote-path)
                            (list "-T" (expand-file-name local-path)))))

(defun seshat-sync-delete (remote-path)
  "删除远端 REMOTE-PATH。
返回 curl 退出码，0 表示成功。"
  (car (seshat-sync--request "DELETE"
                            (seshat-sync--webdav-url remote-path)
                            nil)))

(defun seshat-sync-etag (remote-path)
  "获取远端 REMOTE-PATH 的 ETag（getetag 属性值）。
通过 PROPFIND 取得响应 XML，再用正则提取 <getetag> 元素内容。
返回值可能带有双引号（服务端格式为 \"value\"），获取不到时返回 nil。
供冲突检测（M2.2）使用。"
  (let ((xml (seshat-sync-profind remote-path)))
    (when (string-match
           "<\\(?:[A-Za-z0-9_-]+:\\)?getetag[^>]*>\\([^<]*\\)</" xml)
      (match-string 1 xml))))

;;; M8-B 增量同步引擎
;;
;; 本节开始是 M8-B 的新引擎（增量游标 + uid 身份 + REST 条件写），与上面那批
;; WebDAV 函数**互不影响**：旧函数保留不动（灰度期仍可能需要，且
;; `seshat-conflict.el' 在编译期依赖它们），新引擎一律走 `seshat-rest' 的
;; REST 端点。参见 openspec/active/2026-10-24-m8b-incremental-engine.md。

;;; 只读根（403 `root_read_only'）的共用判定
;;
;; T1a（预建索引）、T1b（事件应用）、T2（push）三处都会遇到只读根的 403；
;; 判定与「每个根只警告一次」的语义必须共用同一处，否则会出现「某根被 push
;; 跳过、pull 却仍尝试写入」的不一致（计划 D7）。

(defvar seshat-sync--read-only-roots nil
  "本次同步中被判定为只读（服务端 403 `root_read_only'）的根 tag 列表.
只读根指 `ondemand' 根：任何写操作都会被拒（见 `docs/sync-protocol.md'），
因此**不重试**、也不重复告警。由 `seshat-sync--mark-root-read-only' 写入，
`seshat-sync--read-only-root-p' 读取；每次同步入口应用
`seshat-sync--reset-read-only-roots' 清空（服务端配置可能在两次同步之间变化）。")

(defun seshat-sync--reset-read-only-roots ()
  "清空只读根缓存，返回 nil.
每次同步开始时调用一次，使上一轮的判定不残留到本轮。"
  (setq seshat-sync--read-only-roots nil))

(defun seshat-sync--read-only-root-p (root)
  "判断 ROOT（根 tag）在本次同步中是否已被判定为只读.
ROOT 为 nil 时返回 nil（「无根」不能当成只读，否则会静默跳过默认根的处理）。"
  (and root (member root seshat-sync--read-only-roots) t))

(defun seshat-sync--mark-root-read-only (root)
  "把 ROOT 记入只读根缓存；首次记入时发一次警告.
重复调用不会重复告警——服务端对同一根的每次写都会回 403，若每次告警会在批量
同步里刷屏（计划 D3 第 4 步「不报错刷屏」）。ROOT 为 nil 时什么也不做。"
  (when (and root (not (seshat-sync--read-only-root-p root)))
    (push root seshat-sync--read-only-roots)
    (display-warning 'seshat-sync
                     (format "根 %s 只读（403 root_read_only），本次同步跳过该根"
                             root)
                     :warning)))

;;; 首同步：预建索引（T1a）

(defconst seshat-sync--index-page-limit 2000
  "首同步预建索引时每页请求的资源条数.
服务端把 `limit' 夹紧到 [1, 2000]，取上限以减少请求次数。")

(defun seshat-sync--roots-for-index ()
  "返回预建索引要遍历的根 tag 列表.
优先取本地根配置 `seshat-state-roots'（元素 `(TAG DIR MODE)'）；它为空时向
服务端问一次 `GET /api/roots'，取其中 `:default' 为真的根作为**唯一**根，
没有默认根时取第一个。服务端也没有配置根时返回 nil（不发起任何资源请求）。

DIR 不参与：索引只登记 `uid ↔ (ROOT PATH)'，本地目录的取用属下载阶段
（T1b）；MODE 属根级属性，由 `seshat-state-roots' 承载，不进条目（见
`seshat-sync--index-write-item'）。

返回值是 tag 字符串列表，顺序即请求顺序；**每个根单独发起请求**——服务端按根
返回 403（`seshat-rest-list-resources' 的请求粒度就是单根），把多个根塞进一次
调用会让只读根的 403 变成整批丢弃（计划 D3 第 1.a 步）。"
  (let ((configured (seshat-state-roots)))
    (if configured
        (mapcar #'car configured)
      (let* ((roots (plist-get (seshat-rest-roots) :roots))
             (default (or (cl-find-if (lambda (root) (plist-get root :default))
                                      roots)
                          (car roots)))
             (tag (plist-get default :tag)))
        (when (and (stringp tag) (not (string-empty-p tag)))
          (list tag))))))

(defun seshat-sync--next-since-mtime (since items)
  "返回下一页请求应使用的 `:since-mtime'（Unix 秒）.
SINCE 为本次请求用的值，ITEMS 为本次返回的资源列表。

服务端 `/api/resources' 的过滤语义是「mtime >= since」（不是 `>'），所以正常
情况用本页最后一项的 mtime 当下一页的 since 即可前进——同一 mtime 的记录会在
下一页重复出现一次，重复写入是幂等的。两种例外必须强制前进，否则死循环：

- 本页最后一项的 mtime 与 SINCE 相同（同秒，且该秒内的记录多于一页）：用
  `since = mtime' 会反复取到同一批记录，只能 `(1+ mtime)'。**代价是该秒内剩余
  的记录被跳过**，这是 `docs/api.md' §1.5 记录在案的已知行为，由 changes 追平
  （T1c）补齐；本函数**不做**任何「补救」尝试（补救只会重新引入死循环）。
- ITEMS 为空但 `:has-more' 为真（异常响应）：没有 mtime 可用，只能
  `(1+ since)'，保证游标严格前进。

mtime 不是数字时同样退化为 `(1+ SINCE)'（防御畸形响应）。"
  (let ((since (or since 0))
        (last-mtime (plist-get (car (last items)) :mtime)))
    (cond
     ((not (numberp last-mtime)) (1+ since))
     ((<= last-mtime since) (1+ since))
     (t last-mtime))))

(defun seshat-sync--index-write-item (root item)
  "把资源 ITEM 的 uid ↔ 路径登记写入状态库，归属根 ROOT.
ROOT 取**本地根配置的 tag**（不取响应里的 `:root'：请求本来就按单根发起，
归属以配置为准）。ITEM 缺 uid 或 path 时什么也不做（畸形响应防御）。

**必须 merge，不能整体覆盖**：既有条目的 `:base-blob' / `:size' / `:mtime' /
`:dirty' / `:deleted-at' / `:orphan' 是后续 push 判定与冲突检测的依据。用
`seshat-state-set' 整体覆盖会把 `:base-blob' 清空，下一轮 push 就会把一个服务端
早已存在的文件误判为新建（连发 `If-None-Match: *' 并撞 412）。因此这里走
`seshat-state--update-entry'（读旧条目 → 只改 `:root' / `:path'），它在
`seshat-state-batch' 块内同样跳过 `:paths' 重建。

`:mode' 与 `:dirty' 都不在这里写：mode 属根级属性（`seshat-state' 的条目
schema 固定为八个字段，见 `seshat-state--normalize-entry'，第九个字段会在写盘
归一化时被丢弃）；dirty 是「本地有未推送改动」的标记，索引只反映服务端现状，
不能碰它（否则会清掉用户的待推送改动）。"
  (let ((uid (plist-get item :uid))
        (path (plist-get item :path)))
    (when (and (stringp uid) (not (string-empty-p uid))
               (stringp path) (not (string-empty-p path)))
      (seshat-state--update-entry
       uid
       (lambda (entry)
         (setq entry (seshat-state--entry-put entry :root root))
         (seshat-state--entry-put entry :path path))))))

(defun seshat-sync--index-write-page (root items)
  "把属于根 ROOT 的一页资源 ITEMS 写入状态库并落盘一次，返回写入的条目数.
结构固定为「一个 `seshat-state-batch' 块写完本页 → 块退出（由宏统一重建
`:paths'）→ `seshat-state-save' 一次」：

- `seshat-state-batch' 块内 `:paths' 是**批前形状**，块内不得 `state-save'
  （见该宏 docstring：会把与 `:uids' 不一致的索引写进磁盘）；
- 每页退出后落盘一次，中断（`C-g'）后下次可从未落盘的那页之前继续，且不会
  留下半页状态。"
  (seshat-state-batch
    (dolist (item items)
      (seshat-sync--index-write-item root item)))
  (seshat-state-save)
  (length items))

(defun seshat-sync--index-root (root)
  "为单根 ROOT 分页拉取资源登记并写入状态库.
返回 `(:pages N :items N :skipped BOOL)'：成功页数、写入条目数、是否因只读
被跳过。

- 分页：每页 `:limit' 取 `seshat-sync--index-page-limit'，从 `:since-mtime' 0
  起循环，`since' 由 `seshat-sync--next-since-mtime' 推进（同秒必须前进，否则
  死循环）；
- `:read-only-root'（403）：记入只读缓存、警告一次、放弃本根，**不重试**；
- 其它非 2xx / 传输失败：同样不重试——索引只是尽力而为的预建，全集由
  `changes?since=0' 追平（T1c）负责，这里不因网络抖动把整个首同步打断。"
  (let ((since 0)
        (pages 0)
        (items 0)
        (done nil)
        (skipped nil))
    (while (not done)
      (let* ((response (seshat-rest-list-resources
                        :root root
                        :since-mtime since
                        :limit seshat-sync--index-page-limit))
             (status (plist-get response :status)))
        (cond
         ((plist-get response :read-only-root)
          (seshat-sync--mark-root-read-only root)
          (setq skipped t)
          (setq done t))
         ((not (and (integerp status) (>= status 200) (< status 300)))
          (display-warning 'seshat-sync
                           (format "预建索引：根 %s 请求失败（状态 %s），跳过该根"
                                   root status)
                           :warning)
          (setq done t))
         (t
          (let* ((page-items (plist-get response :items))
                 (has-more (plist-get response :has-more)))
            (setq pages (1+ pages))
            (setq items (+ items (seshat-sync--index-write-page root page-items)))
            (if has-more
                (setq since (seshat-sync--next-since-mtime since page-items))
              (setq done t)))))))
    (list :pages pages :items items :skipped skipped)))

(defun seshat-sync--build-index ()
  "首同步第一步：为服务端资源登记预建本地索引（M8-B 的 D3 第 1.a 步）.

按根分页遍历 `/api/resources'，把 `uid ↔ (root, path)' 写进 `seshat-state'：

- **不下载任何文件、不写 base-blob**（下载与基线属 T1b）；
- **不推进 `cursor'**（游标只由 changes 追平 T1c 推进）；
- 每页写完 `seshat-state-save' 一次（见 `seshat-sync--index-write-page'）；
- **每个根分别发起请求**：`seshat-rest-list-resources' 的请求粒度是单根，403
  也是按根返回，合并发请求会让只读根的 403 把整批结果吞掉；
- 只读根（403）跳过并各警告一次，其余根继续，不重试。

本步是**尽力而为的预建**，不是全集依据：`/api/resources' 的 `since` 语义是
`mtime >= since' 且无 offset 分页，同秒内记录超过一页时 `since' 只能前进到
`mtime + 1'，该秒剩余记录会被跳过（F7）。全集保证在 `changes?since=0' 追平
（T1c）——兜底方向是「索引缺 → changes 补」，不是反过来。

返回统计 plist `(:roots N :pages N :items N :skipped-roots N)'：参与遍历的根数、
成功页数、写入的资源条数、被跳过的只读根数。"
  (let ((roots (seshat-sync--roots-for-index))
        (pages 0)
        (items 0)
        (skipped 0))
    (dolist (root roots)
      (if (seshat-sync--read-only-root-p root)
          (setq skipped (1+ skipped))
        (let ((result (seshat-sync--index-root root)))
          (setq pages (+ pages (or (plist-get result :pages) 0)))
          (setq items (+ items (or (plist-get result :items) 0)))
          (when (plist-get result :skipped)
            (setq skipped (1+ skipped))))))
    (list :roots (length roots)
          :pages pages
          :items items
          :skipped-roots skipped)))

(provide 'seshat-sync)

;;; seshat-sync.el ends here
