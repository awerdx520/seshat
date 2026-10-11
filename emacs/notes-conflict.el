;;; notes-conflict.el --- 笔记同步冲突检测与三方合并 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块在 `notes-sync' 的 WebDAV 同步之上增加「条件写入 + 三方合并」，
;; 处理多端并发编辑同一笔记时的写冲突：
;;
;;   1. 读取远端当前 ETag（`notes-sync-etag'）；
;;   2. 带 `If-Match: <etag>' 条件头 PUT（`notes-sync-put-if-match'），
;;      远端未变时写入成功，被他人改动时服务端返回 412；
;;   3. 收到 412 时，以「上次成功同步记录的 head」为共同祖先做三方合并
;;      （`notes-conflict--merge-three-way'）：拉远端最新版、取祖先版本内容、
;;      调系统 `diff3 -m' 生成带冲突标记的结果，写入 buffer 并启用
;;      `smerge-mode' 供用户逐处解决；
;;   4. 用户确认解决后写回本地并重新条件 PUT
;;      （`notes-conflict-resolve-and-put'）。
;;
;; 顶层入口：
;;
;;   (notes-conflict-resolve-and-put "~/notes/a.org" "a.org")
;;
;; 依赖 notes-sync.el（WebDAV/ETag）与 notes-rest.el（Bearer REST，用于读取
;; 共同祖先版本内容与远端 HEAD）。三方合并依赖系统命令 diff3（GNU diffutils）；
;; 若环境缺失 diff3，则退化为「本地/远端整体作为一处冲突」的提示。

;;; Code:

(require 'notes-sync)
(require 'notes-rest)

(defgroup notes-conflict nil
  "笔记同步冲突检测与三方合并。"
  :group 'tools
  :prefix "notes-conflict-")

(defcustom notes-conflict-local-head-file "~/.emacs.d/notes-head"
  "记录本地上次成功同步的远端 HEAD hash 的文件路径。
每次成功 PUT 后，服务端当前 HEAD 的 hash 写入该文件；发生 412 冲突时，
它被用作三方合并的「共同祖先」版本号（交由服务端版本端点取内容）。"
  :type 'file
  :group 'notes-conflict)


;;; 内部辅助

(defun notes-conflict--encode-path (path)
  "把仓库内相对路径 PATH 逐段 URL 编码后以 \"/\" 拼接。
保留目录分隔符 \"/\"，使含子目录的路径可安全用作 REST 路径参数。"
  (mapconcat #'url-hexify-string
             (split-string (string-remove-prefix "/" path) "/" t)
             "/"))

(defun notes-conflict--read-file (path)
  "读取文件 PATH 的全部内容并返回字符串。"
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun notes-conflict--read-head ()
  "读取 `notes-conflict-local-head-file' 记录的上次同步 head hash。
文件不存在或内容为空时返回 nil。"
  (let ((file (expand-file-name notes-conflict-local-head-file)))
    (when (file-readable-p file)
      (let ((head (string-trim
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (unless (string-empty-p head)
          head)))))

(defun notes-conflict--remote-head (remote-path)
  "查询远端 REMOTE-PATH 对应文件的当前 HEAD hash（失败返回 nil）。
通过 REST 版本端点 GET /api/versions/{path} 读取响应的 head 字段。"
  (let* ((response (notes-rest--request
                    "GET"
                    (format "/api/versions/%s"
                            (notes-conflict--encode-path remote-path))))
         (data (notes-rest--json response)))
    (cdr (assq 'head data))))

(defun notes-conflict--record-head (remote-path)
  "把远端 REMOTE-PATH 的当前 HEAD hash 写入 `notes-conflict-local-head-file'。
写入成功返回该 hash；取不到 head 时返回 nil。"
  (let ((head (notes-conflict--remote-head remote-path)))
    (when (and (stringp head) (not (string-empty-p head)))
      (with-temp-file (expand-file-name notes-conflict-local-head-file)
        (insert head "\n"))
      head)))

(defun notes-conflict--diff3 (base-file local-file remote-file)
  "调用系统 `diff3 -m' 对 BASE-FILE LOCAL-FILE REMOTE-FILE 做三方合并。
参数顺序为「共同祖先 / 本地 / 远端」。存在冲突时 diff3 以状态码 1 退出，
其标准输出仍是带冲突标记的合并结果，故状态码 1 视为正常。
返回值：合并结果字符串；diff3 不可用时返回 nil（交由调用方降级处理）。"
  (condition-case nil
      (with-temp-buffer
        (let ((exit (call-process "diff3" nil (current-buffer) nil
                                  "-m" base-file local-file remote-file)))
          (cond
           ((and (integerp exit) (> exit 1))
            (error "notes-conflict: diff3 执行失败（退出码 %s）" exit))
           ((and (integerp exit) (< exit 0))
            nil)
           (t
            (buffer-string)))))
    (file-missing nil)
    (error nil)))

(defun notes-conflict--whole-file-conflict (local-file remote-file)
  "diff3 不可用时的降级：把本地与远端内容整体作为一处冲突返回。
生成的内容使用 `smerge-mode' 可识别的冲突标记，供用户手动解决。"
  (concat "<<<<<<< 本地\n"
          (notes-conflict--read-file local-file)
          (unless (string-suffix-p "\n" (notes-conflict--read-file local-file)) "\n")
          "=======\n"
          (notes-conflict--read-file remote-file)
          (unless (string-suffix-p "\n" (notes-conflict--read-file remote-file)) "\n")
          ">>>>>>> 远端\n"))


;;; 条件写入

(defun notes-sync-put-if-match (local-path remote-path etag)
  "带 `If-Match' 条件的 PUT：仅当远端 ETag 与 ETAG 一致时写入。
LOCAL-PATH 为本地文件，REMOTE-PATH 为远端相对路径；ETAG 为期望的远端
ETag（形如 \"\\\"abc\\\"\"；为 nil 或空串时不附加条件头，退化为无条件 PUT）。
底层复用 `notes-sync--request'，附加 `If-Match' 头并读取 HTTP 状态码。

返回 plist：
  :status  'ok（写入成功）/ 'conflict（412）/ 'error（curl 失败）；
  :code    HTTP 状态码整数，无法判定时为 nil；
  :output  curl 的原始输出（剥离首尾空白）。"
  (let* ((url (notes-sync--webdav-url remote-path))
         (extra (append
                 (when (and etag (not (string-empty-p etag)))
                   (list "-H" (format "If-Match: %s" etag)))
                 (list "-T" (expand-file-name local-path)
                       "-o" "/dev/null"
                       "-w" "%{http_code}")))
         (result (notes-sync--request "PUT" url extra))
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

(defun notes-conflict--merge-three-way (local-path remote-path base-hash)
  "对本地 LOCAL-PATH 与远端 REMOTE-PATH 做三方合并，返回待解决的 buffer。
BASE-HASH 为共同祖先的版本 hash，经服务端
GET /api/versions/{path}?hash={base-hash} 取其内容；为空时以空文件作祖先。

流程：① 拉取远端最新内容到临时文件；② 取共同祖先内容到临时文件；
③ 本地内容即本地文件；④ 调 `diff3 -m base local remote' 生成带冲突标记的
合并结果（diff3 不可用时降级为本地/远端整体冲突）；⑤ 结果写入名为
\"*notes-conflict <remote-path>*\" 的 buffer 并启用 `smerge-mode'，返回该 buffer。

远端或祖先内容获取失败时抛出 error。"
  (let* ((remote-file (make-temp-file "notes-remote-" nil ".tmp"))
         (base-file (make-temp-file "notes-base-" nil ".tmp"))
         (local-file (expand-file-name local-path))
         (encoded (notes-conflict--encode-path remote-path))
         (buffer-name (format "*notes-conflict %s*" remote-path)))
    (unwind-protect
        (progn
          ;; ① 拉取远端最新内容。
          (unless (zerop (notes-sync-get remote-path remote-file))
            (error "notes-conflict: 拉取远端 %s 失败" remote-path))

          ;; ② 取共同祖先内容；base-hash 为空时以空文件作祖先。
          (if (and base-hash (not (string-empty-p base-hash)))
              (let* ((response (notes-rest--request
                                "GET"
                                (format "/api/versions/%s?hash=%s"
                                        encoded (url-hexify-string base-hash))))
                     (data (notes-rest--json response))
                     (content (cdr (assq 'content data))))
                (unless (stringp content)
                  (error "notes-conflict: 获取共同祖先 %s 的内容失败" base-hash))
                (write-region content nil base-file nil 'silent))
            (write-region "" nil base-file nil 'silent))

          ;; ④ 三方合并（diff3 优先，缺失时降级）。
          (let ((merged (or (notes-conflict--diff3 base-file local-file remote-file)
                            (notes-conflict--whole-file-conflict
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

(defun notes-conflict-resolve-and-put (local-path remote-path)
  "把本地 LOCAL-PATH 同步到远端 REMOTE-PATH，必要时做三方合并。
步骤：
1. 取当前远端 ETag（`notes-sync-etag'）；
2. 带 `If-Match' 条件头 PUT（`notes-sync-put-if-match'）；
3. 写入成功后记录远端 HEAD（`notes-conflict-local-head-file'）并返回 t；
4. 若返回 412（远端已被他人改动），以上次记录的 head 为共同祖先做三方
   合并（`notes-conflict--merge-three-way'），弹出 buffer 供用户解决冲突；
   用户确认后写回本地并重新条件 PUT（递归，直到成功或用户放弃）。
用户放弃或 PUT 失败时返回 nil。"
  (interactive (list (read-file-name "本地文件: ")
                     (read-string "远端相对路径: ")))
  (let* ((etag (notes-sync-etag remote-path))
         (result (notes-sync-put-if-match local-path remote-path etag)))
    (pcase (plist-get result :status)
      ('ok
       (condition-case err
           (notes-conflict--record-head remote-path)
         (error (message "notes-conflict: 记录远端 HEAD 失败：%s"
                         (error-message-string err))))
       t)
      ('conflict
       (let ((buffer (notes-conflict--merge-three-way
                      local-path remote-path (notes-conflict--read-head))))
         (display-buffer buffer)
         (if (yes-or-no-p "已解决全部冲突并保存？")
             (progn
               (with-current-buffer buffer
                 (write-region (point-min) (point-max)
                               (expand-file-name local-path) nil 'silent))
               (notes-conflict-resolve-and-put local-path remote-path))
           (message "notes-conflict: 用户放弃解决 %s 的冲突" remote-path)
           nil)))
      (_
       (message "notes-conflict: PUT %s 失败：%s"
                remote-path (plist-get result :output))
       nil))))

(provide 'notes-conflict)
;;; notes-conflict.el ends here
