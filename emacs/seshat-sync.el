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
;; 只依赖纯合并原语（diff3 + 冲突标记判定）。**不得** require
;; `seshat-conflict'：它已 require 本文件，反向依赖会成环（见
;; `seshat-merge.el' 的 Commentary）。
(require 'seshat-merge)

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
;; REST 端点。参见 openspec/completed/2026-10-24-m8b-incremental-engine.md。

;;; 根映射初始化（`seshat-sync-roots' → `seshat-state-roots'）
;;
;; `seshat-state-roots' 是本文件所有「根 → 本地目录」解析的唯一来源
;; （`seshat-sync--root-entry' / `--root-dir' / `--mirror-roots' /
;; `--roots-for-index'，以及 `seshat-sync-cmd' 的 status 根解析），但它本身
;; **没有任何生产填充路径**：`seshat-state-set-roots' 只在测试里被调用。没有本
;; 节时，新引擎的根解析一律拿到 nil——`seshat-sync-now' 会「什么都没发生」，
;; 事件应用则逐文件报「根未配置」。本节是这条链路上唯一的生产入口：用户声明
;; `seshat-sync-roots'，pull 入口把它归一后落进状态库。

(defcustom seshat-sync-roots nil
  "同步根映射：每项为 (TAG DIR MODE).
TAG 必须与服务端 `GET /api/roots' 返回的 tag 一致；DIR 是该根在本地对应的
目录（`expand-file-name' 归一）；MODE 为 `mirror' 或 `ondemand'，nil 表示
由服务端 `GET /api/roots' 自动补齐（服务端是 mode 的权威来源，本地只需提供
TAG 与 DIR）。

未配置时同步不会做任何事（不会猜目录）——`seshat-sync-pull' 会发一次警告
提示配置。"
  :type '(repeat (list (string :tag "Tag")
                       (directory :tag "Local directory")
                       (choice (const :tag "从服务端取" nil)
                               (const :tag "mirror（笔记根，可写）" mirror)
                               (const :tag "ondemand（书库根，只读）" ondemand))))
  :group 'seshat-sync)

(defconst seshat-sync--root-modes '("mirror" "ondemand")
  "根模式的合法取值（**字符串**口径）.
`seshat-state-roots' 的 MODE 一律是字符串：`seshat-sync--mirror-mode' 是字符串
常量，`seshat-sync--apply-event' 也用 `(equal \"ondemand\" …)' 判定。")

(defun seshat-sync--normalize-root-mode (mode)
  "把根模式 MODE 归一为字符串 `\"mirror\"' / `\"ondemand\"'；无法识别时返回 nil.
`seshat-sync-roots' 经 `customize' 存的是**符号**（`mirror' / `ondemand'），而
`seshat-state-roots' 的口径是**字符串**（见 `seshat-sync--root-modes'）。两者
必须在写入状态库前统一：否则符号 `mirror' 会被 `seshat-sync--mirror-roots' 整
根过滤掉，rename 检测与 push 会静默什么都不做。"
  (let ((name (cond ((symbolp mode) (symbol-name mode))
                    ((stringp mode) mode)
                    (t nil))))
    (when (member name seshat-sync--root-modes)
      name)))

(defun seshat-sync--fetch-server-root-modes ()
  "请求一次 `GET /api/roots'，返回 `(TAG . MODE)' 的 alist；请求失败时返回 nil.
MODE 已由 `seshat-sync--normalize-root-mode' 归一为字符串，无法识别时值为
nil（调用方据此跳过该项）。整个初始化过程**只调本函数一次**：多个待补 mode 的
根共用这一次响应。"
  (let* ((response (seshat-rest-roots))
         (status (plist-get response :status)))
    (when (and (integerp status) (>= status 200) (< status 300))
      (mapcar (lambda (root)
                (cons (plist-get root :tag)
                      (seshat-sync--normalize-root-mode
                       (plist-get root :mode))))
              (plist-get response :roots)))))

(defun seshat-sync--ensure-roots ()
  "确保 `seshat-state-roots' 已初始化，返回根映射列表；无法初始化时返回 nil.
已初始化（`seshat-state-roots' 非空）时**直接返回**：不发请求、不写盘——本函数
每次 pull 都会调用，重复请求 `/api/roots' 既慢，也会把用户手工设好的映射覆盖掉。

未初始化时按 `seshat-sync-roots' 建立映射：

1. `seshat-sync-roots' 为空 → 发一次警告（说明同步无事可做并给出配置示例），
   返回 nil。**不猜目录**：服务端根与本地目录的对应关系只有用户说得清，自动
   兜底只会把文件写到意料之外的地方（与 `seshat-sync--root-dir' 同一条原则）；
2. MODE 为 nil 的项由服务端补：全体共用**一次** `GET /api/roots'（见
   `seshat-sync--fetch-server-root-modes'）；服务端没有该 tag、或回传的 mode
   无法识别 → 该项跳过并警告，其余项照常处理；
3. TAG 为空 / DIR 为空 / MODE 显式给出但无法识别 → 同样跳过并警告；
4. 有效项经 `seshat-state-set-roots' 归一（DIR 已由 `expand-file-name' 展开成
   绝对路径）→ `seshat-state-save' 落盘 → 返回该列表。

全部项无效时返回 nil 且**不写状态**：写入空 roots 与「未初始化」无法区分，下
一轮只会把初始化再走一遍（还多一次无意义的落盘）。"
  (or (seshat-state-roots)
      (let ((configured seshat-sync-roots))
        (if (null configured)
            (progn
              (display-warning
               'seshat-sync
               (concat
                "未配置 `seshat-sync-roots'，同步不会做任何事（不猜目录）。"
                "请为每个服务端根配置一项 (TAG DIR MODE)，例如：\n"
                "  (setq seshat-sync-roots '((\"notes\" \"~/seshat/notes\" mirror)\n"
                "                           (\"books\" \"~/seshat/books\" ondemand)))")
               :warning)
              nil)
          (let* ((need-mode (cl-some (lambda (entry)
                                       (and (listp entry)
                                            (null (ignore-errors (nth 2 entry)))))
                                     configured))
                 (server (when need-mode
                           (seshat-sync--fetch-server-root-modes)))
                 (roots nil))
            (dolist (entry configured)
              (let ((tag (ignore-errors (nth 0 entry)))
                    (dir (ignore-errors (nth 1 entry)))
                    (raw-mode (ignore-errors (nth 2 entry)))
                    (declared (seshat-sync--normalize-root-mode
                               (ignore-errors (nth 2 entry)))))
                (cond
                 ((not (and (stringp tag) (not (string-empty-p tag))))
                  (display-warning
                   'seshat-sync
                   (format "根配置项 %S 缺少有效 TAG（须为服务端根标签），跳过"
                           entry)
                   :warning))
                 ((not (and (stringp dir) (not (string-empty-p dir))))
                  (display-warning
                   'seshat-sync
                   (format "根 %s 缺少有效本地目录（%S），跳过" tag dir)
                   :warning))
                 ((and (null declared) (not (null raw-mode)))
                  (display-warning
                   'seshat-sync
                   (format "根 %s 的 mode %S 无法识别（只支持 mirror / ondemand），跳过"
                           tag raw-mode)
                   :warning))
                 (t
                  (let ((mode (or declared (cdr (assoc tag server)))))
                    (if (null mode)
                        (display-warning
                         'seshat-sync
                         (format "根 %s 既未声明 mode，也不在服务端 GET /api/roots 里，跳过"
                                 tag)
                         :warning)
                      (push (list tag (expand-file-name dir) mode) roots)))))))
            (if (null roots)
                (progn
                  (display-warning 'seshat-sync
                                   "根配置里没有有效项，同步不会做任何事"
                                   :warning)
                  nil)
              (let ((normalized (seshat-state-set-roots (nreverse roots))))
                (seshat-state-save)
                normalized)))))))

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

;;; 事件应用（T1b）：四类 changes 事件的唯一实现
;;
;; 首同步追平（T1c）与增量循环（T1d）**共用**本节这一个实现：事件应用只允许有
;; 一处，否则两条路径对 `rename' / `ondemand' 的口径迟早漂移。本节只做「单事件
;; → 本地文件 + 状态库」；批量块、`state-save' 与游标推进留给调用方。

(defun seshat-sync--root-entry (root)
  "返回根 tag ROOT 在 `seshat-state-roots' 里的三元组 `(TAG DIR MODE)'；未配置时返回 nil.
ROOT 非字符串（nil / 数字等）时同样返回 nil：事件里的 `:root' 可能因服务端异常
而缺失，不能让它落到 `assoc' 的比较上（`assoc' 用 `equal'，nil 会去匹配畸形
元素）。"
  (and (stringp root) (assoc root (seshat-state-roots))))

(defun seshat-sync--root-dir (root)
  "返回根 tag ROOT 对应的本地目录（`expand-file-name' 归一，带结尾斜杠）；未配置时返回 nil.
查找依据是 `seshat-state-roots' 的元素 `(TAG DIR MODE)'；DIR 不是非空字符串时
同样视为「未配置」。

返回 nil 时调用方应**跳过落盘**并发一次警告，**不得**凭空构造路径（例如退化成
其他本地目录或临时目录）：服务端的根与本地目录的对应关系只有用户配置说得清，
自动兜底只会把文件写到意料之外的地方。"
  (let ((dir (nth 1 (seshat-sync--root-entry root))))
    (when (and (stringp dir) (not (string-empty-p dir)))
      (file-name-as-directory (expand-file-name dir)))))

(defun seshat-sync--local-path (root-dir path)
  "把服务端下发的相对路径 PATH 拼到 ROOT-DIR 下，并校验结果仍在 ROOT-DIR 之内.
返回归一化后的绝对路径；下列任一情形返回 nil（调用方据此**不落盘、不删除**）：

- PATH 不是非空字符串；
- PATH 是绝对路径（以 \"/\" 开头）；
- PATH 以 \"~\" 开头（`expand-file-name' 会把它展开成家目录）；
- PATH 带 Windows 盘符前缀（如 \"C:\"）；
- PATH 经 `expand-file-name' 归一后仍在 ROOT-DIR **之外**，即含 `..' 穿越
  （例如 \"../../etc/passwd\"、\"a/../../b.org\"）。

二次确认：先做字符串前缀比较（快且可读），再用 `file-truename' 比对规范化后的
真实路径，覆盖符号链接逃逸（例如根目录是 `/tmp/link' → `/etc'，则
`/tmp/link/x' 的真实路径在 `/etc' 下）。不用 `file-in-directory-p'：该函数要求
DIR **已存在**，否则一律返回 nil——而首次下载时镜像根目录可能尚未创建，用它会把
合法路径全部误判为越界；`file-truename' 对不存在的路径同样有效（解析已存在的
祖先、其余原样保留）。`file-truename' 出错（父目录不可访问等）按「不安全」处理，
失败方向安全。

**与 `seshat-sync-cmd--safe-local-path' 的关系**：口径一致（那一个只做纯字符串
规范化，由 `seshat-sync-pull-all' 再配 `file-in-directory-p' 二次校验；本函数把
两步合成一处并直接返回绝对路径）。本文件**不能** require `seshat-sync-cmd'
（它是本文件的上层，反向依赖会成环），故此处自行实现；改口径时两处必须同步。

这是**安全底线**：服务端（或中间人）下发的路径不可信，任何越界都必须拒绝，
否则一条 `delete' 事件就能删掉根目录之外的任意文件。"
  (when (and (stringp root-dir) (not (string-empty-p root-dir))
             (stringp path) (not (string-empty-p path))
             (not (string-prefix-p "/" path))
             (not (string-prefix-p "~" path))
             (not (string-match-p "\\`[A-Za-z]:" path)))
    (let* ((dir (file-name-as-directory (expand-file-name root-dir)))
           (expanded (expand-file-name path dir))
           (true-dir (ignore-errors (file-name-as-directory (file-truename dir))))
           (true-file (ignore-errors (file-truename expanded))))
      (when (and (string-prefix-p dir expanded)
                 true-dir true-file
                 (string-prefix-p true-dir true-file))
        expanded))))

(defun seshat-sync--event-set-location (uid root path)
  "把 UID 在状态库里的位置改成 `(ROOT . PATH)'，返回新条目.
**merge 而非整体覆盖**：只改 `:root' / `:path'，其余字段（`:base-blob'
`:size' `:mtime' `:dirty' `:deleted-at' `:orphan'）保持原值。用
`seshat-state-set' 整体覆盖会清掉 `:base-blob'，下一轮 push 就会把服务端早已
存在的文件误判为新建（连发 `If-None-Match: *' 并撞 412）——见计划 D8 的
「状态条目 schema」。

不走 `seshat-state-remap'：remap 会顺带清 `:orphan'、并把占据同路径的旧属主标为
孤儿，那是**改名语义**（一个 uid 让位）；create / update 只是重申服务端的位置，
不该改动其它 uid。"
  (seshat-state--update-entry
   uid
   (lambda (entry)
     (setq entry (seshat-state--entry-put entry :root root))
     (seshat-state--entry-put entry :path path))))

(defun seshat-sync--apply-event (event)
  "应用一条 `changes' 事件 EVENT：更新本地文件与状态库，成功返回 t.

EVENT 是 `seshat-rest-changes' 解出的事件 plist（`:seq' `:uid' `:op' `:root'
`:path' `:old-path' `:blob' `:rev' `:changed-at'）。`:op' 是**字符串**（JSON 原值
\"create\" / \"update\" / \"rename\" / \"delete\"），故比较一律用 `equal'，不要用
`eq'（字符串 `eq' 依赖实现）或 `intern'（凭空造符号）。

四类事件的动作（对应计划 D3 第 3 步）：

- \"create\" / \"update\"：`mirror' 根按事件的 `:blob' 与状态库的 `:base-blob'
  比较——相同**且**本地文件存在时不下载（只把状态里的 `:root' / `:path' 对齐），
  否则用 `seshat-rest-download-file' 落盘（该函数内部已硬编码 `:binary t'，
  **不要**再传 `:binary' 关键字），落盘成功后 `seshat-state-set-base-blob' 写入
  BLOB（取事件的 `:blob'）、SIZE 与 MTIME（取**落盘后**本地 `file-attributes'，
  mtime 换算成 Unix 秒整数，D5 的基线依赖它）。`ondemand' 根**只在本地缺文件
  时**下载（书库按需）。
- \"rename\"：本地文件从 `:old-path' 搬到 `:path'，随后 `seshat-state-remap'
  （三参：UID、事件 `:root'、事件 `:path'）。旧文件不存在则跳过搬运；搬运失败
  （目标已存在等）只告警**仍 remap**——uid ↔ path 以服务端为准，本地搬运只是
  尽力而为。
- \"delete\"：删除本地文件（不存在则忽略），随后 `seshat-state-mark-deleted'
  （墓碑保留 `:base-blob'，见该函数 docstring）。

前置校验（任一不满足即整条事件跳过：不改状态、不落盘、不删除）：

1. 事件缺 uid；
2. `:op' 未知（例如 \"rescan\"）；
3. 根 `:root' 未在 `seshat-state-roots' 里配置（`seshat-sync--root-dir' 返回
   nil）——不凭空造路径；
4. 服务端路径经 `seshat-sync--local-path' 判定越界（安全底线）。

返回值：应用成功 t；跳过（上述四种，以及下载遇只读根 / 远端已不存在 / 其它
失败）nil。**除编程错误外不抛错**——单条事件失败不应中断整轮同步，下载失败、
删除失败、改名失败一律降级为 `display-warning' + nil（改名失败例外：仍 remap
并返回 t，因为状态已对齐服务端）。

批量语义：本函数**自身不进入** `seshat-state-batch'——下载是 I/O，且批量块应由
调用方包住**整批**事件（T1c 首同步追平 / T1d 增量循环）；调用方应在
`seshat-state-batch' 块内调用本函数，以减少 `:paths' 重建次数，并在每批结束后
`seshat-state-save' 一次、**最后**才推进游标。"
  (let* ((uid (plist-get event :uid))
         (op (plist-get event :op))
         (root (plist-get event :root))
         (path (plist-get event :path))
         (old-path (plist-get event :old-path))
         (seq (plist-get event :seq))
         (root-dir (seshat-sync--root-dir root))
         (ondemand (equal "ondemand" (nth 2 (seshat-sync--root-entry root)))))
    (cond
     ;; ---- 前置校验 ----
     ((not (and (stringp uid) (not (string-empty-p uid))))
      (display-warning 'seshat-sync
                       (format "事件 #%s %S：缺少 uid，跳过" seq op) :warning)
      nil)
     ((not (member op '("create" "update" "rename" "delete")))
      (display-warning 'seshat-sync
                       (format "事件 #%s：未知 op %S（uid %s），跳过" seq op uid)
                       :warning)
      nil)
     ((null root-dir)
      (display-warning 'seshat-sync
                       (format "事件 #%s %s：根 %S 未配置本地目录（uid %s），跳过"
                               seq op root uid)
                       :warning)
      nil)
     ;; ---- create / update ----
     ((member op '("create" "update"))
      (let ((local (seshat-sync--local-path root-dir path)))
        (if (null local)
            (progn
              (display-warning 'seshat-sync
                               (format "事件 #%s %s：服务端路径 %S 越界（uid %s），跳过"
                                       seq op path uid)
                               :warning)
              nil)
          (let* ((blob (plist-get event :blob))
                 (base-blob (plist-get (seshat-state-get uid) :base-blob))
                 (exists (file-exists-p local))
                 (need-download (if ondemand
                                    (not exists)
                                  (not (and exists (equal blob base-blob))))))
            (if (not need-download)
                ;; 内容未变（或 ondemand 根已有本地副本）：只对齐位置
                (progn (seshat-sync--event-set-location uid root path) t)
              (let* ((result (seshat-rest-download-file path local :root root))
                     (status (plist-get result :status)))
                (cond
                 ((plist-get result :read-only-root)
                  (seshat-sync--mark-root-read-only root)
                  nil)
                 ((plist-get result :not-found)
                  (display-warning 'seshat-sync
                                   (format "事件 #%s %s：远端 %S 已不存在（uid %s），跳过"
                                           seq op path uid)
                                   :warning)
                  nil)
                 ((not (and (integerp status) (>= status 200) (< status 300)))
                  (display-warning 'seshat-sync
                                   (format "事件 #%s %s：下载 %S 失败（状态 %S，%S），跳过"
                                           seq op path status
                                           (plist-get result :error))
                                   :warning)
                  nil)
                 (t
                  (seshat-sync--event-set-location uid root path)
                  (let* ((attrs (file-attributes local))
                         (mtime (nth 5 attrs)))
                    (seshat-state-set-base-blob
                     uid blob (nth 7 attrs)
                     (and mtime (truncate (float-time mtime)))))
                  t))))))))
     ;; ---- rename ----
     ((equal op "rename")
      (let ((new-local (seshat-sync--local-path root-dir path))
            (old-local (seshat-sync--local-path root-dir old-path)))
        (if (null new-local)
            (progn
              (display-warning 'seshat-sync
                               (format "事件 #%s rename：目标路径 %S 越界（uid %s），跳过"
                                       seq path uid)
                               :warning)
              nil)
          (when (and old-local (file-exists-p old-local))
            (condition-case err
                (progn
                  (make-directory (file-name-directory new-local) t)
                  (rename-file old-local new-local))
              (error
               (display-warning 'seshat-sync
                                (format "事件 #%s rename：本地改名 %S → %S 失败（%s），仍按服务端更新状态"
                                        seq old-path path
                                        (error-message-string err))
                                :warning))))
          (seshat-state-remap uid root path)
          t)))
     ;; ---- delete（前面已排除未知 op，这里即 delete）----
     (t
      (let ((local (seshat-sync--local-path root-dir path)))
        (if (null local)
            (progn
              (display-warning 'seshat-sync
                               (format "事件 #%s delete：服务端路径 %S 越界（uid %s），跳过"
                                       seq path uid)
                               :warning)
              nil)
          (when (file-exists-p local)
            (condition-case err
                (delete-file local)
              (error
               (display-warning 'seshat-sync
                                (format "事件 #%s delete：删除本地 %S 失败（%s），仍标记墓碑"
                                        seq local (error-message-string err))
                                :warning))))
          (seshat-state-mark-deleted uid)
          t))))))

;;; 首同步追平与增量循环（T1c / T1d）：游标推进的唯一实现
;;
;; 首同步追平（`seshat-sync--catch-up'）与增量循环（`seshat-sync--pull-changes'）
;; 的差别**只有起点游标**：前者固定从 0 追平（`changes?since=0' 是权威全集，见
;; 计划 H1），后者从状态库里的游标继续。循环体、批大小、批量块的位置、游标推进
;; 与落盘顺序必须完全一致，因此两条路径共用 `seshat-sync--pull-batches' 一个
;; 实现——否则「先写游标再 apply」这类顺序错误迟早只出现在其中一条路径上。

(defconst seshat-sync--changes-batch-limit 2000
  "每批 `changes' 请求的事件条数.
服务端把 `limit' 夹紧到 [1, 2000]，取上限以减少往返次数：首同步追平一个大
书库时，往返次数是主要成本（计划 D3 第 1.b 步）。")

(defun seshat-sync--apply-changes-batch (changes)
  "在一整块 `seshat-state-batch' 内应用事件列表 CHANGES，返回实际应用的条数.
返回值为 `seshat-sync--apply-event' 返回 t 的事件数（被跳过的事件——未知 op、
根未配置、路径越界、下载失败——不计入）。

顺序上的不变量有两处，都靠本函数的位置保证：

1. **一个批量块包住整批事件**：块内 `:paths' 不重建，块退出时由宏统一重建
   一次（否则每个事件都要付一次 O(n) 重建，见 `seshat-state-batch'）；
2. 本函数**只做 apply**——游标推进与 `state-save' 一律留给调用方，且必须在
   本函数返回（批量块已退出）之后：块内 `:paths' 还是批前形状，此时落盘会写出
   与 `:uids' 不一致的索引。"
  (let ((cool 0))
    (seshat-state-batch
      (dolist (event changes)
        (when (seshat-sync--apply-event event)
          (setq cool (1+ cool)))))
    cool))

(defun seshat-sync--pull-batches (since-seq)
  "从 SINCE-SEQ 起循环拉取 `changes' 并逐批应用，返回统计 plist.
首同步追平与增量循环共用本实现（调用方见 `seshat-sync--catch-up' /
`seshat-sync--pull-changes'）。

每一批的固定顺序（顺序本身是不变量，不得调整）：

1. 在 `seshat-state-batch' 块内应用该批全部事件（`seshat-sync--apply-changes-batch'）；
2. 批量块退出——由宏统一重建一次 `:paths'；
3. `(seshat-state-set-cursor (plist-get resp :next-cursor))'；
4. `seshat-state-save'。

**游标最后写**：中途 `C-g' 或下载报错时游标停在上一批，重放该批是幂等的
（事件应用按 uid upsert，`seshat-sync--event-set-location' 走 merge），既不会漏
事件、也不会产生重复条目。**第 3、4 步必须在批量块之外**：块内 `:paths' 陈旧，
这时落盘会写出「`:uids' 已更新、`:paths' 停留在批前形状」的不一致索引。

`:has-more' 为真时**立即**用本批的 `:next-cursor' 再拉一轮，不 `sleep-for'：
服务端游标单调递增，人为延迟只会把追平时间按批数放大。

非 2xx / 传输失败：发一条警告后**停止**本轮（不重试、不退避），返回已经完成的
统计。调用方（定时器或用户命令）下一轮会从状态库里的游标继续，本身就是一次
天然的重试，在函数内自旋只会刷屏。

返回 plist `(:batches N :events N :cool N)'：成功处理的批数、收到的事件数、
被实际应用的事件数。`cool' 小于 `events' 是正常的——被跳过的事件仍然消耗了
服务端的游标，游标照样要前进（否则同一批会被反复重放）。"
  (let ((since since-seq)
        (batches 0)
        (events 0)
        (cool 0)
        (done nil))
    (while (not done)
      (let* ((response (seshat-rest-changes
                        :since-seq since
                        :limit seshat-sync--changes-batch-limit))
             (status (plist-get response :status)))
        (if (not (and (integerp status) (>= status 200) (< status 300)))
            (progn
              (display-warning 'seshat-sync
                               (format "拉取变更：请求失败（状态 %S，since %s），停止本轮"
                                       status since)
                               :warning)
              (setq done t))
          (let* ((changes (plist-get response :changes))
                 (next (plist-get response :next-cursor))
                 ;; 畸形响应（成功但缺 next_cursor）时保持原游标，绝不前进到 nil
                 ;; （`seshat-state-set-cursor' 会因非整数直接报错）
                 (cursor (if (and (integerp next) (>= next 0)) next since)))
            (setq batches (1+ batches))
            (setq events (+ events (length changes)))
            (setq cool (+ cool (seshat-sync--apply-changes-batch changes)))
            ;; ① apply 已完成、② 批量块已退出 → ③ 推进游标 → ④ 落盘
            (seshat-state-set-cursor cursor)
            (seshat-state-save)
            (cond
             ;; 正常结束：服务端说没有更多了
             ((not (plist-get response :has-more))
              (setq done t))
             ;; 前进性守卫：`:has-more' 为真但游标没有前进（畸形响应：成功却缺
             ;; `next_cursor'，或回传的 next_cursor 不大于 since）→ 停止。没有这条
             ;; 守卫就会用同一个 since 无限重拉同一批（计划「不得无限重试」）。
             ((<= cursor since)
              (display-warning 'seshat-sync
                               (format "拉取变更：还有更多但游标未前进（%s），停止本轮以免重复拉取"
                                       cursor)
                               :warning)
              (setq done t))
             (t (setq since cursor)))))))
    (list :batches batches :events events :cool cool)))

(defun seshat-sync--catch-up ()
  "首同步第二步：`changes?since=0' 追平并取游标（计划 D3 第 1.b 步 / T1c）.
这是**权威全集**：`seq' 单调、按游标分页无损、事件应用幂等，因此可安全重放。
预建索引（`seshat-sync--build-index'）只是尽力而为的预建，索引缺失的条目由本步
补齐（兜底方向是「索引缺 → changes 补」，见计划 H1）。

固定从 0 起——首同步不信任状态库里的任何残留游标。其余语义（批量块、游标后写、
`:has-more' 立即再拉、非 2xx 停止）全部见 `seshat-sync--pull-batches'。"
  (seshat-sync--pull-batches 0))

(defun seshat-sync--pull-changes ()
  "增量：从状态库游标起拉取 `changes' 并逐批应用（计划 D3 第 2 步 / T1d）.
起点是 `(seshat-state-cursor)'，即上轮最后落盘的游标；语义为「只返回
`seq > cursor' 的事件」（服务端 `changes' 的 `since' 是 seq，不是 mtime，见
计划 D8）。`:has-more' 为真时立即再拉，不 sleep；游标与落盘顺序与首同步追平
完全一致（同一实现 `seshat-sync--pull-batches'）。"
  (seshat-sync--pull-batches (seshat-state-cursor)))

;;; 编排入口（T1d）

(defun seshat-sync--first-sync-p ()
  "判断本次 pull 是否属首同步.
判据：游标为 0 **且** 状态库没有任何 uid 登记。

两者都要看：只看游标会把「服务端变更流为空但索引已建好」的书库反复当首同步
（每次都重跑一遍全库索引）；只看 `:uids' 则会把「已有登记但从未追平过变更流」
的半成品当成增量。

`:uids' 没有公开访问器（`seshat-state' 只暴露 `-dirty-uids' / `-deleted-uids'
这类筛选过的视图），这里按计划 D8 的等价手段直接读内存状态——用 `--ensure'
而非 `plist-get' 裸取，保证首次调用前状态已从磁盘加载。"
  (and (= 0 (seshat-state-cursor))
       (null (plist-get (seshat-state--ensure) :uids))))

(defun seshat-sync-pull ()
  "同步引擎的 pull 入口：按首同步 / 增量两条路径把服务端变更拉到本地.
编排（计划 D3 第 1、2 步）：

- 开头 `seshat-sync--reset-read-only-roots'：只读根缓存跨轮必须清空，否则上一轮
  被判只读的根（服务端配置可能已经改回 `mirror'）会静默跳过整轮；
- 随后 `seshat-sync--ensure-roots'：确保根映射 `(TAG DIR MODE)' 已从
  `seshat-sync-roots' 落进状态库。未配置 `seshat-sync-roots'（或配置全无效）时
  它返回 nil，本函数**直接返回「未配置」结果**并跳过后续所有步骤——没有根映射
  时建索引拿不到根、事件应用全被跳过、push 也无处落盘，继续跑只会空转；
- **首同步**（`seshat-sync--first-sync-p'）：先 `seshat-sync--build-index' 预建
  索引，再 `seshat-sync--catch-up' 追平取游标；
- **增量**：只调 `seshat-sync--pull-changes'。

本函数**不做 push、不做 rename 检测**：那两步由 `seshat-sync-now' 的编排
（T4）串在 pull 之后。返回值 plist：

- `:configured' — 根映射是否可用；nil 表示未配置（此时其余字段都是 nil）；
- `:first-sync' — 是否走了首同步路径；
- `:index' — 首同步时的建索引统计（`seshat-sync--build-index' 的返回值）；
  增量路径为 nil（本轮没有建索引）；
- `:changes' — 追平 / 增量循环的统计 `(:batches N :events N :cool N)'。"
  (seshat-sync--reset-read-only-roots)
  (if (null (seshat-sync--ensure-roots))
      (list :configured nil :first-sync nil :index nil :changes nil)
    (if (seshat-sync--first-sync-p)
        (let ((index (seshat-sync--build-index)))
          (list :configured t
                :first-sync t
                :index index
                :changes (seshat-sync--catch-up)))
      (list :configured t
            :first-sync nil
            :index nil
            :changes (seshat-sync--pull-changes)))))

;;; push（T2）：条件写 + 412 三方合并
;;
;; push 只遍历 `seshat-state-dirty-uids'（H3：不做全量扫描），逐 uid 做**条件
;; 写**——无 `:base-blob' 时发 `If-None-Match: *'（仅创建），有 `:base-blob'
;; 时发 `If-Match: \"<blob>\"'（条件覆盖）。两条条件头不能并存：服务端两者都
;; 校验，任一不成立即 412（`docs/api.md' §8.2）。
;;
;; 本节的**不变量**（改动时必须保持）：
;;
;; 1. `dirty' 只在「真的推送成功」时清除（`seshat-state-set-base-blob' 顺带清
;;    dirty）；任何失败、放弃、冲突一律**保留 dirty**，否则下次不再重试。
;; 2. 412 的重发**只能一次**；409 / 403 **一律不重试**（403 还要把整根标只读）。
;; 3. 全程**零交互**：可能由定时器触发，不得 `yes-or-no-p' / `smerge-mode' /
;;    `pop-to-buffer'；冲突只写回带标记的内容并提示用户手动解决。
;; 4. base blob 取响应里的 `:etag'（服务端 etag 与 blob 同值，可直接作下次
;;    `If-Match' 的取值）；`:rev' 是提交 hash，**不得**用作条件写。

(defun seshat-sync--read-binary (file)
  "以二进制安全方式读取 FILE 的全部内容，返回 unibyte 字节串.
用 `insert-file-contents-literally'（完全不做编码嗅探与 EOL 转换），因此
EPUB / PDF 等非 UTF-8 内容和 CRLF 换行都能原样拿到、原样上传。
读不到时把错误交给调用方（push 的调用点已确认文件存在）。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun seshat-sync--write-binary (file content)
  "把 CONTENT 以二进制安全方式**原子**写回 FILE，返回写入的绝对路径.
先写同目录临时文件再 `rename-file' ——中途失败不会留下半截笔记；失败时删除
临时文件并把错误抛给调用方（调用方降级为 warning 并保留 dirty）。

为什么不用 `write-region' 直接覆盖：合并结果写回的是**用户正在编辑的笔记**，
半截内容比不写更糟；原子替换让「读到的永远是完整内容」成为不变量。"
  (let* ((target (expand-file-name file))
         (dir (file-name-directory target))
         (temp nil))
    (make-directory dir t)
    (setq temp (make-temp-file (expand-file-name "seshat-merge-out-" dir)))
    (condition-case err
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (seshat-rest--binary-string content))
            (let ((coding-system-for-write 'no-conversion))
              (write-region (point-min) (point-max) temp nil 'silent)))
          (rename-file temp target t)
          (setq temp nil)
          target)
      (error
       (when (and temp (file-exists-p temp))
         (ignore-errors (delete-file temp)))
       (signal (car err) (cdr err))))))

(defun seshat-sync--local-stats (file)
  "返回 FILE 的 `(SIZE . MTIME)'：字节数与 Unix 秒整数；取不到时返回 nil.
SIZE 即 `file-attributes' 的第八项（字节数），MTIME 由第六项换算成整数秒——
D5 的基线比对用的就是这个 `(size, mtime)' 对，push 写基线时必须同源同口径。"
  (let ((attrs (file-attributes file)))
    (when attrs
      (let ((mtime (nth 5 attrs)))
        (cons (nth 7 attrs)
              (and mtime (truncate (float-time mtime))))))))

(defun seshat-sync--record-pushed (uid file etag)
  "记录 UID 推送成功：把基线写成 ETAG 与 FILE 的当前 `(size, mtime)'，返回条目.
ETAG 取上传响应里的 `:etag'（**不是** `:rev'）：服务端的 etag 与 blob 同值，
可直接作为下一次 `If-Match' 的取值；`:rev' 是提交 hash，用它做条件写会永远
412。`seshat-state-set-base-blob' 顺带清除 `:dirty'——这是 dirty 唯一的正常
清除点。

ETAG 缺失（畸形响应）时仍写 nil 并发一次警告：此时条目退化为「无 base」，
下轮会以 `If-None-Match: *' 重试并撞 412 进入合并流程，比留着旧 base 更安全
（旧 base 已被服务端拒绝，说明它已过期）。"
  (let* ((stats (seshat-sync--local-stats file))
         (size (car-safe stats))
         (mtime (cdr-safe stats))
         (blob (and (stringp etag) (not (string-empty-p etag)) etag)))
    (unless blob
      (display-warning 'seshat-sync
                       (format "push：上传 %s 成功但响应缺少 etag，基线未记录" file)
                       :warning))
    (seshat-state-set-base-blob uid blob size mtime)))

(defun seshat-sync--push-upload (uid path root base local)
  "对 UID 做一次条件写，返回 `pushed' / `conflicted' / `skipped' / `failed'.
PATH 为根内相对路径，ROOT 为根 tag，BASE 为 `:base-blob'（nil 表示服务端尚无
此文件），LOCAL 为本地绝对路径。

条件头（二选一，**不得并存**）：

- BASE 为 nil → `:if-none-match \"*\"'（仅创建；带 `If-Match: \"\"' 的语义是
  「永不匹配」，不能拿来表达「首次写入」）；
- BASE 非 nil → `:if-match BASE'（条件覆盖）。

响应分支见 `seshat-sync--push-outcome'。"
  (let ((content (seshat-sync--read-binary local)))
    (seshat-sync--push-outcome
     uid path root base local
     (if (and (stringp base) (not (string-empty-p base)))
         (seshat-rest-upload-file path content :root root :if-match base)
       (seshat-rest-upload-file path content :root root :if-none-match "*")))))

(defun seshat-sync--push-outcome (uid path root base local response)
  "解释一次上传响应 RESPONSE 并执行对应动作，返回四态符号.
分支（计划 D4 第 3 步）：

- 2xx → 记录基线（blob 取 `:etag'、size/mtime 取本地 `file-attributes'），
  返回 `pushed'（`set-base-blob' 顺带清 dirty）；
- 412（`:conflict' 为 `etag-mismatch'）→ 交给
  `seshat-sync--push-merge' 做三方合并；
- 403（`:read-only-root'）→ 把整根标为只读（`ondemand' 根写被拒），**跳过该
  根其余条目**、保留 dirty，返回 `skipped'；
- 409（`:conflict' 为 `state-conflict'）→ **不重试**（墓碑占路径时物理移动可能
  已完成，重试只会再得 409），warning + 保留 dirty，返回 `failed'；
- 其它（含传输失败、5xx、404）→ warning + 保留 dirty，返回 `failed'。

`409' / `403' 与 412 的处理差别是本函数的核心：只有 412 蕴含「内容可合并」，
其余状态码重试都不会得到不同结果。"
  (let ((status (plist-get response :status))
        (conflict (plist-get response :conflict)))
    (cond
     ((seshat-rest--2xx-p status)
      (seshat-sync--record-pushed uid local (plist-get response :etag))
      'pushed)
     ((eq conflict 'etag-mismatch)
      (seshat-sync--push-merge uid path root base local))
     ((plist-get response :read-only-root)
      (seshat-sync--mark-root-read-only root)
      'skipped)
     ((eq conflict 'state-conflict)
      (display-warning 'seshat-sync
                       (format "push：%s 与服务端状态冲突（409），不重试，保留待推送标记"
                               path)
                       :warning)
      'failed)
     (t
      (display-warning 'seshat-sync
                       (format "push：上传 %s 失败（状态 %S，%S），保留待推送标记"
                               path status (plist-get response :error))
                       :warning)
      'failed))))

(defun seshat-sync--push-merge (uid path root base local)
  "412 分支：拉远端 + 取祖先 + diff3 三方合并，返回四态符号.
固定步骤（顺序本身是不变量，计划 D4 的 412 流程）：

1. `seshat-rest-download-file' 把远端内容落到临时文件（该函数内部已硬编码
   `:binary t'，**不要**再传 `:binary'）——失败则 warning + 保留 dirty +
   `failed'；
2. `seshat-rest-versions' 用**当前 base** 取祖先版本的 `:content'——取不到
   （非 2xx / 404 / content 不是字符串）则 warning + 保留 dirty + `failed'；
3. `seshat-merge--diff3' 合并（祖先 / 本地 / 远端）——返回 nil（diff3 不可用或
   执行失败）则 warning + 保留 dirty + `failed'；
4. 按 `seshat-merge-conflicted-p' 分流，见 `seshat-sync--push-merge-continue'。

临时目录一律 `unwind-protect' 递归清理；任何异常都降级为 `failed'（保留
dirty），绝不把错误抛给调用方——push 是批量循环，单条失败不能中断整轮。"
  (let ((temp-dir nil))
    (unwind-protect
        (condition-case err
            (progn
              (setq temp-dir (file-name-as-directory
                              (make-temp-file "seshat-push-" t)))
              (let* ((temp (expand-file-name "remote" temp-dir))
                     (response (seshat-rest-download-file path temp :root root)))
                (cond
                 ((plist-get response :read-only-root)
                  (seshat-sync--mark-root-read-only root)
                  'skipped)
                 ((not (seshat-rest--2xx-p (plist-get response :status)))
                  (display-warning 'seshat-sync
                                   (format "push：412 后拉取 %s 的远端内容失败（状态 %S），保留待推送标记"
                                           path (plist-get response :status))
                                   :warning)
                  'failed)
                 (t
                  (seshat-sync--push-merge-continue
                   uid path root base local temp (plist-get response :etag))))))
          (error
           (display-warning 'seshat-sync
                            (format "push：合并 %s 时出错（%s），保留待推送标记"
                                    path (error-message-string err))
                            :warning)
           'failed))
      (when (and temp-dir (file-directory-p temp-dir))
        (ignore-errors (delete-directory temp-dir t))))))

(defun seshat-sync--push-merge-continue (uid path root base local remote-file remote-etag)
  "412 合并流程的第 2–4 步（`seshat-sync--push-merge' 的下半段）.
REMOTE-FILE 为已落盘的远端内容，REMOTE-ETAG 为下载响应里的 `:etag'（**新
base**）。返回四态符号。

- **无冲突标记** → 把合并结果写回本地，带**新 base**（REMOTE-ETAG）重发
  上传**一次**：成功 → `pushed'；再次 412 → 放弃（保留 dirty）→ `conflicted'；
  其它失败 → `failed'。
- **有冲突标记** → **仍把含标记的合并结果写回本地**（用户下次打开文件即可用
  `smerge' 处理），保留 dirty，warning 提示手动解决，返回 `conflicted'。
  本分支**绝不进入任何交互**。

新 base 缺失（下载响应没带 ETag）时不做无条件重发：那会**静默覆盖**别人刚写
的内容，违反乐观锁的初衷 → warning + 保留 dirty + `failed'。"
  (let ((ancestor (seshat-rest-versions path base)))
    (if (not (seshat-rest--2xx-p (plist-get ancestor :status)))
        (progn
          (display-warning 'seshat-sync
                           (format "push：取 %s 的祖先版本（%s）失败（状态 %S），保留待推送标记"
                                   path base (plist-get ancestor :status))
                           :warning)
          'failed)
      (let* ((ancestor-content (plist-get ancestor :content))
             (merged (seshat-merge--diff3
                      (if (stringp ancestor-content) ancestor-content "")
                      (seshat-sync--read-binary local)
                      (seshat-sync--read-binary remote-file))))
        (cond
         ((null merged)
          (display-warning 'seshat-sync
                           (format "push：%s 三方合并失败（diff3 不可用或执行出错），保留待推送标记"
                                   path)
                           :warning)
          'failed)
         ((seshat-merge-conflicted-p merged)
          (seshat-sync--write-binary local merged)
          (display-warning 'seshat-sync
                           (format "%s 存在冲突，已写入冲突标记，请手动解决后重新同步"
                                   path)
                           :warning)
          'conflicted)
         ((not (and (stringp remote-etag) (not (string-empty-p remote-etag))))
          (display-warning 'seshat-sync
                           (format "push：%s 合并成功但远端未返回 etag，无法条件重发，保留待推送标记"
                                   path)
                           :warning)
          'failed)
         (t
          (seshat-sync--write-binary local merged)
          (let ((retry (seshat-rest-upload-file
                        path merged :root root :if-match remote-etag)))
            (cond
             ((seshat-rest--2xx-p (plist-get retry :status))
              (seshat-sync--record-pushed uid local (plist-get retry :etag))
              'pushed)
             ((eq (plist-get retry :conflict) 'etag-mismatch)
              (display-warning 'seshat-sync
                               (format "push：%s 合并后重发仍被拒（412），已放弃本次推送，保留待推送标记"
                                       path)
                               :warning)
              'conflicted)
             ((plist-get retry :read-only-root)
              (seshat-sync--mark-root-read-only root)
              'skipped)
             (t
              (display-warning 'seshat-sync
                               (format "push：%s 合并后重发失败（状态 %S），保留待推送标记"
                                       path (plist-get retry :status))
                               :warning)
              'failed)))))))))

(defun seshat-sync--push-entry (uid)
  "推送单个 UID，返回 `pushed' / `conflicted' / `skipped' / `failed'.
前置跳过（不改状态、不发请求）：条目缺失、根未配置本地目录、根已被判定只读
（本轮更早的 403）、根是 `ondemand'（**绝不主动写**，计划 D7）、条目无本地
路径（墓碑 / 孤儿）、服务端路径越界（安全底线，与 pull 共用
`seshat-sync--local-path'）、本地文件不存在（已被外部删除）。"
  (let* ((entry (seshat-state-get uid))
         (root (plist-get entry :root))
         (path (plist-get entry :path))
         (base (plist-get entry :base-blob))
         (root-dir (seshat-sync--root-dir root))
         (mode (nth 2 (seshat-sync--root-entry root))))
    (cond
     ((null entry)
      (display-warning 'seshat-sync
                       (format "push：uid %s 无状态条目，跳过" uid) :warning)
      'skipped)
     ((null root-dir)
      (display-warning 'seshat-sync
                       (format "push：根 %S 未配置本地目录（uid %s），跳过" root uid)
                       :warning)
      'skipped)
     ((seshat-sync--read-only-root-p root) 'skipped)
     ((equal "ondemand" mode)
      (display-warning 'seshat-sync
                       (format "push：根 %s 是 ondemand（只读），跳过 uid %s"
                               root uid)
                       :warning)
      'skipped)
     ((not (and (stringp path) (not (string-empty-p path))))
      (display-warning 'seshat-sync
                       (format "push：uid %s 没有本地路径（墓碑或孤儿条目），跳过" uid)
                       :warning)
      'skipped)
     (t
      (let ((local (seshat-sync--local-path root-dir path)))
        (cond
         ((null local)
          (display-warning 'seshat-sync
                           (format "push：服务端路径 %S 越界（uid %s），跳过" path uid)
                           :warning)
          'skipped)
         ((not (file-exists-p local))
          (display-warning 'seshat-sync
                           (format "push：本地文件 %s 不存在（可能被外部删除），跳过"
                                   local)
                           :warning)
          'skipped)
         (t (seshat-sync--push-upload uid path root base local))))))))

(defun seshat-sync-push ()
  "同步引擎的 push 入口：把本地脏条目按条件写推给服务端（计划 D4 / T2）.
遍历 `seshat-state-dirty-uids'（H3：只推脏条目，不做全量扫描），逐 uid 走
`seshat-sync--push-entry'。

返回统计 plist `(:pushed N :conflicted N :skipped N :failed N)'：

- `:pushed' — 真的推送成功（基线已更新、dirty 已清）；
- `:conflicted' — 因冲突放弃（含冲突标记已写回、或 412 重发仍被拒）；
- `:skipped' — 被前置条件跳过（根未配置 / 只读 / ondemand / 越界 /
  本地文件不存在）；
- `:failed' — 其它失败（5xx、传输失败、409、合并取不到远端或祖先、diff3 不可
  用）。**除 `:pushed' 之外，dirty 一律保留**，下一轮同步会重试。

批量语义：整个循环包在一个 `seshat-state-batch' 块里（逐 uid 写 base blob 时
`:paths' 只重建一次），块退出后 `seshat-state-save' 一次——基线不落盘等于下轮
重推，故必须保存。

**只读根缓存不在本函数重置**：`seshat-sync-pull' 开头已清空，pull → push 的
同轮编排（T4）希望整轮共享「本轮哪些根只读」的判定（计划 D7）。单独调用本
函数（无 pull）时缓存为空，403 仍会在本轮内被标记并跳过同根其余条目。"
  (let ((pushed 0)
        (conflicted 0)
        (skipped 0)
        (failed 0)
        (uids (seshat-state-dirty-uids)))
    (seshat-state-batch
      (dolist (uid uids)
        (let ((result (seshat-sync--push-entry uid)))
          (cond
           ((eq result 'pushed) (setq pushed (1+ pushed)))
           ((eq result 'conflicted) (setq conflicted (1+ conflicted)))
           ((eq result 'skipped) (setq skipped (1+ skipped)))
           (t (setq failed (1+ failed)))))))
    (seshat-state-save)
    (list :pushed pushed
          :conflicted conflicted
          :skipped skipped
          :failed failed)))

;;; move / rename 检测（T3）
;;
;; `seshat-sync-detect-renames' 在 push **之前**执行（T4 的编排是
;; `pull → detect-renames → push'），做三件事：把本地内容改动标脏（push 的
;; 唯一输入来源）、把「同一内容从旧路径消失 + 在新路径出现」判为 rename 并上报
;; `move-resource'、把无法配对的消失 / 新增分别计数。
;;
;; 本节的不变量（改动时必须保持）：
;;
;; 1. 第 2 步（同路径内容改动 → 标脏）与第 3 步（消失 / 新增）**作用域互斥**：
;;    前者只处理「本地文件存在」的已登记 uid，后者只处理「本地文件不存在」的
;;    （路径消失后无法 `stat'）。合并成一个循环会让同一 uid 被两处同时处理。
;; 2. rename 判据是 `size + mtime' **双双相等**（D5 的已知取舍：不读内容
;;    hash）；mtime 必须与 `seshat-state-set-base-blob' 同口径（Unix 秒整数），
;;    因此快照必须复用 `seshat-sync--local-stats'。
;; 3. **不做任何删除 / 创建 / 内容推送**：未配对的消失只计数（删除由服务端
;;    `delete' 事件驱动，见 T1b），未配对的新增也不上报（新文件由用户保存后
;;    标脏 + push 建立）。
;; 4. 零交互（可能由定时器触发）：409 只 warning，不进 `smerge'、不问用户。
;; 5. 只扫 `mode' 为 `mirror' 的根：`ondemand' 根的内容按需下载、本地目录可能
;;    几乎为空，扫描它会把「尚未下载的资源」误判为「消失」（D5 / D7）。

(defconst seshat-sync--mirror-mode "mirror"
  "可参与本地快照扫描的根模式.
只有 `mirror' 根的内容保证全量落在本地，快照比对（内容改动 / 消失）才有意义；
`ondemand' 根只按需下载，本地缺文件是常态，绝不主动写（计划 D7）。")

(defun seshat-sync--mirror-roots ()
  "返回 `seshat-state-roots' 中 `mode' 为 `mirror' 的三元组 `(TAG DIR MODE)' 列表."
  (cl-remove-if-not (lambda (root) (equal seshat-sync--mirror-mode (nth 2 root)))
                    (seshat-state-roots)))

(defun seshat-sync--snapshot-root (root-entry)
  "扫描单个 mirror 根 ROOT-ENTRY=（TAG DIR MODE），返回 `(TAG . ALIST)'；无法扫描时返回 nil.

ALIST 元素为 `(REL . (SIZE . MTIME))'：

- REL 是 `file-relative-name' 得到的**相对根的相对路径**（与 state 的 `:path'
  同形，rename 配对靠它生成 `move-resource' 的 `to'）；
- SIZE / MTIME 取自 `seshat-sync--local-stats'——与 push 写基线**同源同口径**
  （mtime 为 Unix 秒整数）；口径不一致会让 rename 判定永远匹配不上。

只收**普通文件**（`file-regular-p'）：目录不是资源；符号链接本身也不是——把
链接名单独收进快照会让「链接」与「实体」两条路径同时出现，制造假的 rename。

目录未配置 / 不存在 / 扫描出错时返回 nil（该根本轮跳过）并发一次警告，**不抛
错**：本函数可能由定时器触发，某个根被卸载或权限变更不该中断整轮同步。返回 nil
而不是空 alist 是关键——空 alist 会让该根下所有已登记 uid 都被当成「消失」。"
  (let ((tag (nth 0 root-entry))
        (dir (nth 1 root-entry)))
    (cond
     ((not (and (stringp dir) (not (string-empty-p dir))))
      (display-warning 'seshat-sync
                       (format "rename 检测：根 %s 未配置本地目录，跳过" tag)
                       :warning)
      nil)
     ((not (file-directory-p dir))
      (display-warning 'seshat-sync
                       (format "rename 检测：根 %s 的本地目录 %s 不存在，跳过该根"
                               tag dir)
                       :warning)
      nil)
     (t
      (condition-case err
          (let ((base (file-name-as-directory (expand-file-name dir)))
                (alist nil))
            (dolist (file (directory-files-recursively base "" nil))
              (when (file-regular-p file)
                (let ((stats (seshat-sync--local-stats file)))
                  (when stats
                    (push (cons (file-relative-name file base) stats) alist)))))
            (cons tag (nreverse alist)))
        (error
         (display-warning 'seshat-sync
                          (format "rename 检测：扫描根 %s 的目录 %s 失败（%s），跳过该根"
                                  tag dir (error-message-string err))
                          :warning)
         nil))))))

(defun seshat-sync--local-snapshot (roots)
  "对 mirror 根列表 ROOTS 逐个取快照，返回 `((TAG . ALIST) …)'（跳过的根不在其中）."
  (delq nil (mapcar #'seshat-sync--snapshot-root roots)))

(defun seshat-sync--path-index (tags)
  "返回 `(ROOT . PATH)' → uid 的哈希表，只含 TAGS 这些根下「已登记、未墓碑」的条目.
墓碑条目（`:deleted-at' 非 nil）不占本地路径（`seshat-state--rebuild-paths' 的
口径），因此不进索引：墓碑路径上出现的文件算「新增」，而不是「已登记」。
孤儿条目（`:path' 已清）自然也被排除。

一次性建表（而非对每个文件调 `seshat-state-uid-for-path'）是为了把第 3 步的
比对从 O(文件数 × 条目数) 降成一次线性建表 + 常数查找。"
  (let ((table (make-hash-table :test #'equal)))
    (dolist (uid (seshat-state--uids-where
                  (lambda (entry)
                    (and (member (plist-get entry :root) tags)
                         (not (plist-get entry :deleted-at))
                         (stringp (plist-get entry :path))
                         (not (string-empty-p (plist-get entry :path)))))))
      (let ((entry (seshat-state-get uid)))
        (puthash (cons (plist-get entry :root) (plist-get entry :path)) uid table)))
    table))

(defun seshat-sync--appeared-items (snapshot index)
  "第 3 步的「新增」列表：SNAPSHOT 里有、INDEX（`(ROOT . PATH)' → uid）里没有的路径.
每项为 `(:root TAG :path REL :size N :mtime N)'。列表顺序即快照顺序，配对时取
「第一项」因此是确定的。"
  (let (items)
    (dolist (root snapshot)
      (let ((tag (car root)))
        (dolist (cell (cdr root))
          (unless (gethash (cons tag (car cell)) index)
            (push (list :root tag
                        :path (car cell)
                        :size (cadr cell)
                        :mtime (cddr cell))
                  items)))))
    (nreverse items)))

(defun seshat-sync--vanished-items (tags)
  "第 3 步的「消失」列表：TAGS 这些根下已登记、未墓碑、但本地文件不存在的条目.
每项为 `(:uid UID :root TAG :path REL :size N :mtime N)'（size / mtime 是
**状态基线**，配对时要求与新增项双双相等）。

「本地文件不存在」包括路径越界（`seshat-sync--local-path' 返回 nil，安全底线）
的情形——那种路径同样无法 `stat'，归入消失（最终只会计入 `:vanished'，不产生
任何请求、也不碰本地文件）。"
  (let (items)
    (dolist (uid (seshat-state--uids-where
                  (lambda (entry)
                    (and (member (plist-get entry :root) tags)
                         (not (plist-get entry :deleted-at))
                         (stringp (plist-get entry :path))
                         (not (string-empty-p (plist-get entry :path)))))))
      (let* ((entry (seshat-state-get uid))
             (root (plist-get entry :root))
             (path (plist-get entry :path))
             (local (seshat-sync--local-path (seshat-sync--root-dir root) path)))
        (unless (and local (file-exists-p local))
          (push (list :uid uid
                      :root root
                      :path path
                      :size (plist-get entry :size)
                      :mtime (plist-get entry :mtime))
                items))))
    (nreverse items)))

(defun seshat-sync--detect-local-edits (tags)
  "第 2 步：把本地 `(size, mtime)' 与状态基线不同的已登记 uid 标脏，返回标脏条数.
TAGS 为本次扫描成功的 mirror 根 tag 列表（`ondemand' 根不参与）。

- 只处理「本地文件存在」的条目：路径消失（或路径越界取不到绝对路径）归第 3 步
  （D5 第 2 步的排优说明），两处作用域因此天然互斥；
- `(size, mtime)' 与基线**相同**时**不动**该条目：不能顺手清 dirty——dirty 可能
  来自上次推送失败，清了就永远不会重推（push 的不变量 1：只有真的推送成功才清
  dirty）；
- **本步是 push 的唯一输入来源**：没有它，`dirty-uids' 只会在 rename / 新增时
  被填充，用户对已有文件的编辑永远不会被推送。"
  (let ((dirty 0))
    (dolist (uid (seshat-state--uids-where
                  (lambda (entry)
                    (and (member (plist-get entry :root) tags)
                         (not (plist-get entry :deleted-at))
                         (stringp (plist-get entry :path))
                         (not (string-empty-p (plist-get entry :path)))))))
      (let* ((entry (seshat-state-get uid))
             (local (seshat-sync--local-path
                     (seshat-sync--root-dir (plist-get entry :root))
                     (plist-get entry :path))))
        (when (and local (file-exists-p local))
          (let ((stats (seshat-sync--local-stats local)))
            (when (and stats
                       (not (and (equal (car stats) (plist-get entry :size))
                                 (equal (cdr stats) (plist-get entry :mtime)))))
              (seshat-state-mark-dirty uid)
              (setq dirty (1+ dirty)))))))
    dirty))

(defun seshat-sync--paired-appeared (item appeared)
  "在「新增」列表 APPEARED 里为「消失」项 ITEM 找配对目标；找不到返回 nil.

配对条件是**同根 + `size' 与 `mtime' 双双相等**（D5 的判据：不读内容 hash；
代价是同尺寸同 mtime 的两个不同文件会被误判为 rename，由计划 C 用 blob 精化）：

- **必须同根**：`move-resource' 的目标路径是「相对同一个根」的
  （`docs/api.md' §15），跨根的「改名」只能表达成删 + 建，不能上报 move；
- 状态基线缺 `:size' / `:mtime'（刚建索引、从未推送过）时**不配对**：显式要求
  两者都是数字，否则 `nil' 与畸形值会让不相干的条目互配（`nil' 与 `nil' 相等，
  一旦某天新增项也带 nil 就会误配）。"
  (when (and (numberp (plist-get item :size))
             (numberp (plist-get item :mtime)))
    (cl-find-if (lambda (candidate)
                  (and (equal (plist-get item :root)
                              (plist-get candidate :root))
                       (equal (plist-get item :size)
                              (plist-get candidate :size))
                       (equal (plist-get item :mtime)
                              (plist-get candidate :mtime))))
                appeared)))

(defun seshat-sync--report-move (item target)
  "把「消失」项 ITEM 的改名上报服务端（`move-resource uid → TARGET'），返回结果符号.
ITEM 为 `(:uid :root :path :size :mtime)'，TARGET 为同根下的新相对路径。

四态符号（与 push 的处置口径一致）：

- `renamed' — 2xx：`seshat-state-remap'（三参：uid、root、新路径）把 uid 位置
  改到新路径，并把该 uid **标脏**（保守：新路径的元数据还需要 push 确认一次；
  remap 本身既不清 dirty 也不置 dirty）；
- `conflict' — 409（`:conflict' 为 `state-conflict'）：**不重试**——服务端的
  `UNIQUE(root, path)' 可能被墓碑占着，而**物理移动可能已经完成**
  （`docs/api.md' §15 的已知限制），重试只会再得一个 409。此时**不 remap**：
  本地状态与服务端真实状态此刻不一致，贸然改本地会让下一轮把文件推到错误位置；
  只 warning 建议先 rescan；
- `skipped` — 403（`:read-only-root'）：整根标只读（与 T1a / T1b / T2 共用同一
  处判定），不重试；
- `failed' — 其它（含传输失败、404、5xx、以及上报过程中抛错）：warning，不
  重试。

**不做任何本地文件操作**：物理移动是用户自己完成的，本地新路径上已有文件；本
函数只上报 + 改状态。异常一律降级为 `failed`（批量循环里单条失败不能中断整轮，
否则由定时器触发时后续 rename 永远轮不到）。"
  (let ((uid (plist-get item :uid))
        (root (plist-get item :root))
        (old-path (plist-get item :path)))
    (condition-case err
        (let* ((response (seshat-rest-move-resource uid target))
               (status (plist-get response :status)))
          (cond
           ((seshat-rest--2xx-p status)
            (seshat-state-remap uid root target)
            (seshat-state-mark-dirty uid)
            'renamed)
           ((plist-get response :read-only-root)
            (seshat-sync--mark-root-read-only root)
            'skipped)
           ((eq (plist-get response :conflict) 'state-conflict)
            (display-warning
             'seshat-sync
             (format "rename 检测：%s → %s 被服务端拒（409 state-conflict），不重试；物理移动可能已完成，请先 rescan 再对齐"
                     old-path target)
             :warning)
            'conflict)
           (t
            (display-warning
             'seshat-sync
             (format "rename 检测：%s → %s 上报失败（状态 %S，%S），跳过"
                     old-path target status (plist-get response :error))
             :warning)
            'failed)))
      (error
       (display-warning 'seshat-sync
                        (format "rename 检测：上报 %s → %s 时出错（%s），跳过"
                                old-path target (error-message-string err))
                        :warning)
       'failed))))

(defun seshat-sync-detect-renames ()
  "同步引擎的 move 检测入口（计划 D5 / T3）：push 之前发现本地内容改动与改名.

按 D5 的四步执行，**顺序不可调换**：

1. **本地快照**：只扫 `mode' 为 `mirror' 的根（`ondemand' 根不扫），得到
   `相对路径 → (size . mtime)'；
2. **本地内容修改检测**：已登记、未墓碑、本地文件存在且 `(size, mtime)' 与
   state 基线不同 → `seshat-state-mark-dirty'。**这一步是 push 的唯一输入
   来源**：没有它，用户对已有文件的编辑永远不会被推送；
3. **消失 / 新增判定与 rename 配对**：state 有但本地消失的记为「消失」，本地有
   但 state 索引没有的记为「新增」；同根下 `size' 与 `mtime' **都相同**的
   「消失 + 新增」判为 rename → `seshat-rest-move-resource'（两个位置参数）
   → 2xx 则 `seshat-state-remap' + 标脏。未配对的消失**不删本地、不上报删除**
   （删除由服务端 `delete' 事件驱动），未配对的新增**不创建、不上报**；
4. 返回统计 plist。

调用约定（T4）：`pull → detect-renames → push`。顺序不可颠倒——rename 产生的
dirty 与 uid 路径变更必须先落到 state，push 才能按新路径推送。**零交互**：本
函数可能由定时器触发，任何分支都不得询问用户、不得进入 `smerge'。

`state` 的写入整体包在一个 `seshat-state-batch' 块里（逐 uid 标脏 / remap 时
`:paths' 只重建一次），块退出后 `seshat-state-save' 一次——标脏不落盘等于下轮
重新发现，白做一遍全盘扫描。

返回 `(:scanned-roots N :dirty-marked N :renamed N :conflict N :skipped N
:failed N :vanished N :appeared N)'：

- `:scanned-roots' — 真正扫描成功的 mirror 根数（目录不存在 / 扫描失败的根不计）；
- `:dirty-marked' — 因本地 `(size, mtime)' 变化被标脏的 uid 数；
- `:renamed' / `:conflict' / `:skipped' / `:failed' — 上报 move 的四种结果；
- `:vanished' — 未配对的消失条目数（本地文件不删、不产生请求）；
- `:appeared' — 未配对的新增条目数（不创建、不产生请求）。"
  (let* ((roots (seshat-sync--mirror-roots))
         (snapshot (seshat-sync--local-snapshot roots))
         (tags (mapcar #'car snapshot))
         (dirty 0)
         (renamed 0)
         (conflict 0)
         (skipped 0)
         (failed 0)
         (vanished-unpaired 0)
         (appeared-unpaired 0))
    (seshat-state-batch
      ;; 第 2 步必须先于第 3 步：标脏只依赖「本地文件存在」的条目，而第 3 步
      ;; 只处理「本地文件不存在」的条目，两者作用域互斥（D5 第 2 步）。
      (setq dirty (seshat-sync--detect-local-edits tags))
      (let* ((index (seshat-sync--path-index tags))
             (appeared (seshat-sync--appeared-items snapshot index))
             (vanished (seshat-sync--vanished-items tags)))
        (dolist (item vanished)
          (let ((match (seshat-sync--paired-appeared item appeared)))
            (cond
             ((null match)
              (setq vanished-unpaired (1+ vanished-unpaired)))
             (t
              ;; 匹配到的新增项立即消费掉，避免两组 rename 交叉错配
              (setq appeared (delq match appeared))
              (let ((result (seshat-sync--report-move
                             item (plist-get match :path))))
                (cond
                 ((eq result 'renamed) (setq renamed (1+ renamed)))
                 ((eq result 'conflict) (setq conflict (1+ conflict)))
                 ((eq result 'skipped) (setq skipped (1+ skipped)))
                 (t (setq failed (1+ failed)))))))))
        (setq appeared-unpaired (length appeared))))
    (seshat-state-save)
    (list :scanned-roots (length snapshot)
          :dirty-marked dirty
          :renamed renamed
          :conflict conflict
          :skipped skipped
          :failed failed
          :vanished vanished-unpaired
          :appeared appeared-unpaired)))

(provide 'seshat-sync)

;;; seshat-sync.el ends here
