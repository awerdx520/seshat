;;; seshat-conflict.el --- 笔记同步冲突检测与三方合并 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块在 `seshat-sync' 的 WebDAV 同步之上增加「条件写入 + 三方合并」，
;; 处理多端并发编辑同一笔记时的写冲突：
;;
;;   1. 读取远端当前 ETag（`seshat-sync-etag'）；
;;   2. 带 `If-Match: <etag>' 条件头 PUT（`seshat-sync-put-if-match'），
;;      远端未变时写入成功，被他人改动时服务端返回 412；
;;   3. 收到 412 时，以「上次成功同步记录的 head」为共同祖先做三方合并
;;      （`seshat-conflict--merge-three-way'）：拉远端最新版、取祖先版本内容、
;;      调系统 `diff3 -m' 生成带冲突标记的结果，写入 buffer 并启用
;;      `smerge-mode' 供用户逐处解决；
;;   4. 用户确认解决后写回本地并重新条件 PUT
;;      （`seshat-conflict-resolve-and-put'）。
;;
;; 顶层入口：
;;
;;   (seshat-conflict-resolve-and-put "~/seshat/a.org" "a.org")
;;
;; 依赖 seshat-rest.el（REST：下载远端内容、读取版本与 HEAD）与
;; seshat-state.el（per-uid 的 `:base-blob' 即「上次成功同步的祖先版本」）。
;; `seshat-sync.el' 仍被 require——`seshat-sync-put-if-match' 走 WebDAV 条件
;; 写，且 `seshat-sync-cmd' 的手动入口依赖本模块的编译期可用性（T4b 把
;; push-all 切到新引擎后再评估移除）。
;;
;; 三方合并复用 `seshat-merge--diff3'（纯合并原语，内部按 GNU diff3 的
;; `-m MINE OLDER YOURS' 位置语义把共同祖先放在第二个参数）；若环境缺失
;; diff3，则退化为「本地/远端整体作为一处冲突」的提示。
;;
;; HEAD（共同祖先版本号）的存放：优先读写状态库的 per-uid
;; `:base-blob'（按「路径 → 根 tag → uid」解析）；
;; 解析不出根或 uid 时回退到旧的全局文件
;; `seshat-conflict-local-head-file'（已废弃，仅为兼容既有用户配置保留）。

;;; Code:

(require 'seshat-sync)
(require 'seshat-rest)
(require 'seshat-state)
(require 'seshat-merge)

(defgroup seshat-conflict nil
  "笔记同步冲突检测与三方合并。"
  :group 'tools
  :prefix "seshat-conflict-")

(defcustom seshat-conflict-local-head-file "~/.emacs.d/seshat-head"
  "**已废弃**（见文件末尾的 `make-obsolete-variable'）：全局的 HEAD 记录文件。
HEAD 指「上次成功同步的远端 HEAD hash」，发生 412 冲突时被用作三方合并的
「共同祖先」版本号（交由服务端版本端点取内容）。

正常路径**不**读写它：HEAD 存在状态库（`seshat-state-file'）的 per-uid
`:base-blob' 里（按「路径 → 根 tag → uid」解析）。只有当解析不出根 tag 或
uid（未配置根 / 资源未登记）时才回退到本文件，仍沿用「整个仓库共享一个
HEAD」的旧语义。保留该变量是为了让设过它的用户配置不报错。"
  :type 'file
  :group 'seshat-conflict)


;;; 内部辅助

(defun seshat-conflict--read-file (path)
  "读取文件 PATH 的全部内容并返回字符串。"
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun seshat-conflict--success-status-p (status)
  "判断 STATUS 是否为 2xx 成功状态码；非整数（传输层失败）一律视为失败。
远端下载与版本查询返回「语义 plist」，失败时 `:status' 可能是 4xx/5xx 整数，
也可能因传输层失败而为 nil——只看非 nil 会把 412 / 404 当成功。"
  (and (integerp status) (>= status 200) (< status 300)))


;;; 路径 → 根 tag → uid 的解析
;;
;; HEAD（祖先版本号）存在状态库的 per-uid `:base-blob' 里，因此
;; 「读/写 HEAD」的第一步是把调用方给的路径翻译成 uid。路径有两种来源：
;; 本地绝对路径（`seshat-conflict-resolve-and-put' 的 LOCAL-PATH）与根内相对
;; 路径（同一个入口的 REMOTE-PATH）；两种都要能解析。

(defun seshat-conflict--root-dir (root)
  "返回根 tag ROOT 在 `seshat-state-roots' 里的本地目录（带结尾斜杠）。
未配置该根、或 DIR 不是非空字符串时返回 nil。"
  (let ((dir (nth 1 (and (stringp root) (assoc root (seshat-state-roots))))))
    (when (and (stringp dir) (not (string-empty-p dir)))
      (file-name-as-directory (expand-file-name dir)))))

(defun seshat-conflict--root-for-path (path)
  "把 PATH 解析为根 tag；解析不出时返回 nil。
PATH 可以是本地绝对路径（含 `~'），也可以是根内相对路径：

- 绝对路径：按 `seshat-state-roots' 各元素的 DIR 做**最长前缀**匹配。取最长而
  不是第一个命中的前缀，是因为根目录允许嵌套（例如 `~/notes' 与
  `~/notes/archive'）；取最短前缀会把内层根下的路径错判成外层根，进而用错
  uid 与祖先版本。
- 相对路径：按状态库反查——返回第一个「该根下这条路径已登记 uid」的 tag。
  相对路径无法与任何 DIR 做前缀比较（它不含根目录信息），状态库的登记是唯一
  可靠依据。

两种情形都解析不出（未配置根、资源未登记）时返回 nil，调用方据此回退到旧的
全局 HEAD 文件。"
  (when (and (stringp path) (not (string-empty-p path)))
    (if (file-name-absolute-p path)
        (let ((expanded (expand-file-name path))
              (best nil)
              (best-length -1))
          (dolist (entry (seshat-state-roots))
            (let* ((tag (nth 0 entry))
                   (dir (seshat-conflict--root-dir tag)))
              (when (and (stringp tag) dir
                         (string-prefix-p dir expanded)
                         (> (length dir) best-length))
                (setq best tag)
                (setq best-length (length dir)))))
          best)
      (let (found)
        (dolist (entry (seshat-state-roots))
          (let ((tag (nth 0 entry)))
            (when (and (null found) (stringp tag)
                       (seshat-state-uid-for-path tag path))
              (setq found tag))))
        found))))

(defun seshat-conflict--relative-to-root (root path)
  "把 PATH 转成根 ROOT 内的相对路径；无法转换时返回 nil。
PATH 是根内相对路径时原样返回；是绝对路径时去掉 ROOT 的 DIR 前缀（前缀不匹配
或路径恰为根目录本身时返回 nil）。"
  (when (and (stringp root) (stringp path) (not (string-empty-p path)))
    (if (file-name-absolute-p path)
        (let ((dir (seshat-conflict--root-dir root))
              (expanded (expand-file-name path)))
          (when (and dir (string-prefix-p dir expanded) (not (equal dir expanded)))
            (substring expanded (length dir))))
      path)))

(defun seshat-conflict--uid-for-path (path)
  "把 PATH（本地绝对路径或根内相对路径）解析为服务端 uid。
先定根 tag（`seshat-conflict--root-for-path'），再按根内相对路径查状态库的
`:paths' 索引。任一环节解析不出（未配置根 / 资源未登记 / 条目为墓碑或孤儿）
时返回 nil。"
  (let* ((root (seshat-conflict--root-for-path path))
         (relative (seshat-conflict--relative-to-root root path)))
    (when (and root relative)
      (seshat-state-uid-for-path root relative))))


;;; HEAD 的读写（per-uid `:base-blob'，解析失败回退旧全局文件）

(defun seshat-conflict--head-file-head ()
  "读取旧全局 HEAD 文件（`seshat-conflict-local-head-file'）记录的内容。
文件不存在、不可读或内容为空时返回 nil。**仅作解析失败时的回退路径**。"
  (let ((file (expand-file-name seshat-conflict-local-head-file)))
    (when (file-readable-p file)
      (let ((head (string-trim
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (unless (string-empty-p head)
          head)))))

(defun seshat-conflict--head-for (path)
  "返回 PATH 上次成功同步的远端 HEAD（即共同祖先版本号）；未知时返回 nil。
uid 可解析时读状态库里该 uid 的 `:base-blob'（per-uid，多文件互不干扰——
旧的全局单值会把 A 文件的 HEAD 当成 B 文件的祖先）。
uid 解析不出时回退 `seshat-conflict-local-head-file'（旧行为，兼容未升级的
状态库）。"
  (let ((uid (seshat-conflict--uid-for-path path)))
    (if uid
        (let ((blob (plist-get (seshat-state-get uid) :base-blob)))
          (and (stringp blob) (not (string-empty-p blob)) blob))
      (seshat-conflict--head-file-head))))

(defun seshat-conflict--set-head-for (path blob)
  "把 PATH 的 HEAD 记为 BLOB，成功时返回 BLOB；BLOB 非法时空操作并返回 nil。
uid 可解析时写状态库的 `:base-blob'（`seshat-state-set-base-blob' 四参：
`size' / `mtime' 传**条目里已有的基线值**——传 nil 会把本地基线清空，
`seshat-sync--detect-local-edits' 下一次比对就会把这个文件误判为「本地已改」
并标脏，用户会看到一条凭空出现的待推送记录）。
uid 解析不出时回退写旧全局文件（保持旧语义与用户配置可用）。"
  (when (and (stringp blob) (not (string-empty-p blob)))
    (let ((uid (seshat-conflict--uid-for-path path)))
      (cond
       (uid
        (let ((entry (seshat-state-get uid)))
          (seshat-state-set-base-blob uid blob
                                      (plist-get entry :size)
                                      (plist-get entry :mtime)))
        blob)
       (t
        (with-temp-file (expand-file-name seshat-conflict-local-head-file)
          (insert blob "\n"))
        blob)))))

(defun seshat-conflict--read-head (&optional path)
  "读取 PATH 的上次同步 HEAD；PATH 为 nil 时只读旧全局文件。
PATH 可为本地绝对路径或根内相对路径（见 `seshat-conflict--head-for'）。
签名向后兼容：无参调用的语义与旧实现一致（读 `seshat-conflict-local-head-file'）。"
  (if path
      (seshat-conflict--head-for path)
    (seshat-conflict--head-file-head)))

(defun seshat-conflict--remote-head (remote-path)
  "查询远端 REMOTE-PATH 对应文件的当前 HEAD hash（失败返回 nil）。
经 `seshat-rest-versions'（`GET /api/versions/{path}'，不带 hash → 取文件
历史）读取响应的 `:head'；非 2xx（404 未登记、401 未认证、传输失败等）返回
nil，不抛错。"
  (let ((response (seshat-rest-versions remote-path)))
    (when (seshat-conflict--success-status-p (plist-get response :status))
      (plist-get response :head))))

(defun seshat-conflict--record-head (remote-path)
  "把远端 REMOTE-PATH 的当前 HEAD 记为该文件的上次同步版本，返回该 hash。
取不到 head（或 head 为空串）时返回 nil 且不写任何东西；写入位置见
`seshat-conflict--set-head-for'（per-uid `:base-blob'，解析失败回退旧文件）。"
  (let ((head (seshat-conflict--remote-head remote-path)))
    (when (and (stringp head) (not (string-empty-p head)))
      (seshat-conflict--set-head-for remote-path head)
      head)))

(defun seshat-conflict--diff3 (base-file local-file remote-file)
  "对 BASE-FILE / LOCAL-FILE / REMOTE-FILE 做三方合并，返回合并结果字符串。
形参顺序是「共同祖先 / 本地 / 远端」，直接转交 `seshat-merge--diff3'。

**为什么不再自己调 diff3**：GNU diff3 的位置语义是 `-m MINE OLDER YOURS'——
**第二个**参数才是共同祖先。旧实现按形参顺序原样传 `-m base local remote'，
于是 diff3 把 base 当「我方」、local 当祖先；两侧各自独立的改动（本地改第 2
行、远端改第 5 行）会被误报成冲突。参数重排与退出码 1 的语义都收敛到
`seshat-merge--diff3' 一处，本函数只做「三个文件 → 三段内容」的读取。

读取走 `seshat-merge--read-temp'（`insert-file-contents-literally' + unibyte），
因此远端下载到的临时文件按原始字节进入合并，不经编码往返。

返回值：合并结果字符串（unibyte 字节串）；diff3 不可用或执行失败时返回 nil
（交由调用方降级为「本地/远端整体一处冲突」）。"
  (seshat-merge--diff3 (seshat-merge--read-temp base-file)
                       (seshat-merge--read-temp local-file)
                       (seshat-merge--read-temp remote-file)))

(defun seshat-conflict--whole-file-conflict (local-file remote-file)
  "diff3 不可用时的降级：把本地与远端内容整体作为一处冲突返回。
生成的内容使用 `smerge-mode' 可识别的冲突标记，供用户手动解决。"
  (concat "<<<<<<< 本地\n"
          (seshat-conflict--read-file local-file)
          (unless (string-suffix-p "\n" (seshat-conflict--read-file local-file)) "\n")
          "=======\n"
          (seshat-conflict--read-file remote-file)
          (unless (string-suffix-p "\n" (seshat-conflict--read-file remote-file)) "\n")
          ">>>>>>> 远端\n"))


;;; 条件写入

(defun seshat-sync-put-if-match (local-path remote-path etag)
  "带 `If-Match' 条件的 PUT：仅当远端 ETag 与 ETAG 一致时写入。
LOCAL-PATH 为本地文件，REMOTE-PATH 为远端相对路径；ETAG 为期望的远端
ETag（形如 \"\\\"abc\\\"\"；为 nil 或空串时不附加条件头，退化为无条件 PUT）。
底层复用 `seshat-sync--request'，附加 `If-Match' 头并读取 HTTP 状态码。

返回 plist：
  :status  'ok（写入成功）/ 'conflict（412）/ 'error（curl 失败）；
  :code    HTTP 状态码整数，无法判定时为 nil；
  :output  curl 的原始输出（剥离首尾空白）。"
  (let* ((url (seshat-sync--webdav-url remote-path))
         (extra (append
                 (when (and etag (not (string-empty-p etag)))
                   (list "-H" (format "If-Match: %s" etag)))
                 (list "-T" (expand-file-name local-path)
                       "-o" "/dev/null"
                       "-w" "%{http_code}")))
         (result (seshat-sync--request "PUT" url extra))
         (exit (car result))
         (output (string-trim (cdr result)))
         (code (when (string-match "\\`\\([0-9]+\\)\\'" output)
                 (string-to-number (match-string 1 output)))))
    (cond
     ((and (integerp exit) (/= exit 0))
      (list :status 'error :code code :output output))
     ((or (eql code 412) (string-match-p "412" output))
      (list :status 'conflict :code (or code 412) :output output))
     (t
      (list :status 'ok :code code :output output)))))


;;; 三方合并

(defun seshat-conflict--merge-three-way (local-path remote-path base-hash)
  "对本地 LOCAL-PATH 与远端 REMOTE-PATH 做三方合并，返回待解决的 buffer。
BASE-HASH 为共同祖先的版本 hash：经 `seshat-rest-versions'（服务端
`GET /api/versions/{path}?hash={base-hash}'）取其内容；为空（或 nil）时以空
文件作祖先。

流程：① 拉取远端最新内容到临时文件（`seshat-rest-download-file'，
根 tag 由 LOCAL-PATH / REMOTE-PATH 在 `seshat-state-roots' 里解析）；
② 取共同祖先内容到临时文件（`seshat-rest-versions' 带 base blob）；
③ 本地内容即本地文件；④ 三方合并（`seshat-conflict--diff3' → 
`seshat-merge--diff3'，diff3 不可用时降级为本地/远端整体冲突）；
⑤ 结果写入名为 \"*seshat-conflict <remote-path>*\" 的 buffer 并启用
`smerge-mode'，返回该 buffer。

两个临时文件在 `unwind-protect' 里清理：无论成功、抛错还是降级，都不留残留。

远端或祖先内容获取失败（非 2xx / 祖先内容非字符串）时抛出 error。"
  (let* ((remote-file (make-temp-file "seshat-remote-" nil ".tmp"))
         (base-file (make-temp-file "seshat-base-" nil ".tmp"))
         (local-file (expand-file-name local-path))
         (root (or (seshat-conflict--root-for-path local-file)
                   (seshat-conflict--root-for-path remote-path)))
         (buffer-name (format "*seshat-conflict %s*" remote-path)))
    (unwind-protect
        (progn
          ;; ① 拉取远端最新内容。下载本身二进制安全（内部硬编码 `:binary t'），
          ;; 落盘的临时文件因此是原始字节，后续用 literally 方式读。
          (let ((response (seshat-rest-download-file remote-path remote-file
                                                     :root root)))
            (unless (seshat-conflict--success-status-p (plist-get response :status))
              (error "seshat-conflict: 拉取远端 %s 失败（HTTP %s）"
                     remote-path (plist-get response :status))))

          ;; ② 取共同祖先内容；base-hash 为空时以空文件作祖先。
          (if (and base-hash (not (string-empty-p base-hash)))
              (let* ((response (seshat-rest-versions remote-path base-hash))
                     (content (plist-get response :content)))
                (unless (and (seshat-conflict--success-status-p
                              (plist-get response :status))
                             (stringp content))
                  (error "seshat-conflict: 获取共同祖先 %s 的内容失败" base-hash))
                ;; 用合并模块的二进制安全写入口：多字节内容按 UTF-8 落盘，
                ;; 已是 unibyte 的字节串原样写出，不经编码往返。
                (seshat-merge--write-temp base-file content))
            (seshat-merge--write-temp base-file ""))

          ;; ③④ 三方合并（diff3 优先，缺失时降级）。
          (let ((merged (or (seshat-conflict--diff3 base-file local-file remote-file)
                            (seshat-conflict--whole-file-conflict
                             local-file remote-file))))
            ;; ⑤ 写入 buffer 并启用 smerge-mode。
            (with-current-buffer (get-buffer-create buffer-name)
              (erase-buffer)
              (insert merged)
              (goto-char (point-min))
              (when (fboundp 'smerge-mode)
                (smerge-mode 1))
              (current-buffer))))
      (ignore-errors (delete-file remote-file))
      (ignore-errors (delete-file base-file)))))


;;; 顶层入口

(defun seshat-conflict-resolve-and-put (local-path remote-path)
  "把本地 LOCAL-PATH 同步到远端 REMOTE-PATH，必要时做三方合并。
步骤：
1. 取当前远端 ETag（`seshat-sync-etag'）；
2. 带 `If-Match' 条件头 PUT（`seshat-sync-put-if-match'）；
3. 写入成功后记录远端 HEAD（per-uid `:base-blob'，解析不出时回退
   `seshat-conflict-local-head-file'）并返回 t；
4. 若返回 412（远端已被他人改动），以上次记录的 head 为共同祖先做三方
   合并（`seshat-conflict--merge-three-way'），弹出 buffer 供用户解决冲突；
   用户确认后写回本地并重新条件 PUT（递归，直到成功或用户放弃）。
用户放弃或 PUT 失败时返回 nil。"
  (interactive (list (read-file-name "本地文件: ")
                     (read-string "远端相对路径: ")))
  (let* ((etag (seshat-sync-etag remote-path))
         (result (seshat-sync-put-if-match local-path remote-path etag)))
    (pcase (plist-get result :status)
      ('ok
       (condition-case err
           (seshat-conflict--record-head remote-path)
         (error (message "seshat-conflict: 记录远端 HEAD 失败：%s"
                         (error-message-string err))))
       t)
      ('conflict
       (let ((buffer (seshat-conflict--merge-three-way
                      local-path remote-path
                      (seshat-conflict--read-head remote-path))))
         (display-buffer buffer)
         (if (yes-or-no-p "已解决全部冲突并保存？")
             (progn
               (with-current-buffer buffer
                 (write-region (point-min) (point-max)
                               (expand-file-name local-path) nil 'silent))
               (seshat-conflict-resolve-and-put local-path remote-path))
           (message "seshat-conflict: 用户放弃解决 %s 的冲突" remote-path)
           nil)))
      (_
       (message "seshat-conflict: PUT %s 失败：%s"
                remote-path (plist-get result :output))
       nil))))

;; 废弃声明放在文件末尾，而不是紧跟 `defcustom'：`make-obsolete-variable' 是
;; 顶层调用，字节编译本文件时**会被求值**，其属性一旦设上，本文件后面对
;; `seshat-conflict-local-head-file' 的引用就会触发「obsolete variable」编译
;; 警告。放在末尾因此不产生新警告（变量本身保留，用户配置里设过它也不会报错）。
(make-obsolete-variable 'seshat-conflict-local-head-file
                        'seshat-state-file "2026-10-24")

(provide 'seshat-conflict)
;;; seshat-conflict.el ends here
