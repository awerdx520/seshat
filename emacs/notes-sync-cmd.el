;;; notes-sync-cmd.el --- 笔记同步命令（手动 + 定时） -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块把 WebDAV 文件同步（`notes-sync'）、REST 状态同步（`notes-rest'）
;; 与冲突检测/三方合并（`notes-conflict'）封装成面向用户的「手动 + 定时」
;; 同步命令，是 M2 桌面端 Emacs 插件的顶层入口。
;;
;; 一次完整同步（`notes-sync-now'）依次执行三个阶段：
;;
;;   1. 拉取（`notes-sync-pull-all'）：PROPFIND 远端目录，逐个 GET 到本地；
;;   2. 推送（`notes-sync-push-all'）：遍历本地 .org 文件，条件 PUT 回远端，
;;      远端被他人改动时自动进入三方合并（smerge-mode）流程；
;;   3. 状态（`notes-sync-status'）：拉取阅读进度（MVP 仅拉取，不推送批注）。
;;
;; 手动触发：M-x notes-sync-now。
;; 定时触发：M-x notes-sync-enable-timer 启用（间隔 `notes-sync-interval' 秒），
;;           M-x notes-sync-disable-timer 停用。定时器对象记录在
;;           `notes-sync-cmd--timer' 中，重复启用不会创建多个定时器。
;;
;; 使用前需先配置 `notes-sync-server-url'、`notes-sync-username'、
;; `notes-sync-token'、`notes-sync-local-dir'、`notes-sync-remote-dir'
;; （见 notes-sync.el），以及 `notes-rest-base-url'、`notes-rest-token'
;; （见 notes-rest.el）。

;;; Code:

(require 'notes-sync)
(require 'notes-rest)
(require 'notes-conflict)
(require 'subr-x)
(require 'url-util)

(defgroup notes-sync-cmd nil
  "笔记同步命令（手动 + 定时）。"
  :group 'tools
  :prefix "notes-sync-")

(defcustom notes-sync-interval 300
  "定时同步的间隔秒数。
变量 `notes-sync-enable-timer' 以该值作为周期性调用 `notes-sync-now' 的
间隔（同时也是首次触发的延迟）。默认 300 秒（5 分钟）。"
  :type 'number
  :group 'notes-sync-cmd)

(defvar notes-sync-cmd--timer nil
  "当前正在运行的定时同步 timer 对象；nil 表示未启用。
由 `notes-sync-enable-timer' 与 `notes-sync-disable-timer' 维护，用于保证
启用操作的幂等性（已存在运行中的定时器时不重复创建）。")


;;; 响应解析辅助

(defun notes-sync-cmd--extract-hrefs (xml)
  "从 PROPFIND 响应 XML 中按出现顺序提取全部 href 元素的内容。
兼容带命名空间前缀的写法（例如 <D:href>），返回字符串列表；
XML 为空或未含 href 时返回 nil。"
  (let ((case-fold-search t)
        (start 0)
        hrefs)
    (while (string-match
            "<\\(?:[A-Za-z0-9_-]+:\\)?href[^>]*>\\([^<]*\\)</" xml start)
      (push (match-string 1 xml) hrefs)
      (setq start (match-end 0)))
    (nreverse hrefs)))

(defun notes-sync-cmd--href-relative (href)
  "把 PROPFIND 响应中的 HREF 转换为相对远端笔记目录的编码路径。
HREF 可为完整 URL、以 \"/\" 开头的绝对路径或相对路径。处理时先剥离
\"scheme://host\" 与查询串/片段，再匹配远端笔记目录前缀
（即 `notes-sync--webdav-url' 的路径部分），返回其后的子串（保留原有
百分号编码，可直接用于 WebDAV GET）。不属于远端目录内时返回 nil。"
  (let ((href (string-trim href)))
    ;; 去掉绝对 URL 的 scheme://host 部分，只保留路径。
    (when (string-match "\\`[A-Za-z][A-Za-z0-9+.-]*://[^/]*" href)
      (setq href (substring href (match-end 0))))
    ;; 去掉查询串与片段。
    (setq href (car (split-string href "[?#]")))
    (let* ((base (notes-sync--webdav-url ""))
           (base-path (if (string-match "\\`[A-Za-z][A-Za-z0-9+.-]*://[^/]*"
                                        base)
                          (substring base (match-end 0))
                        base)))
      (when (string-prefix-p base-path href)
        (let ((rel (substring href (length base-path))))
          (unless (string-empty-p rel)
            rel))))))


;;; 顶层命令

(defun notes-sync-pull-all ()
  "拉取远端笔记目录下的全部文件到本地目录。
对远端笔记目录（`notes-sync-remote-dir'）执行 PROPFIND（Depth: 1），从响应
XML 提取全部 href 条目，跳过目录项，逐个 GET 到 `notes-sync-local-dir' 下
对应的相对路径（必要时自动创建子目录）。返回成功拉取的文件数。"
  (interactive)
  (let* ((xml (notes-sync-profind ""))
         (hrefs (notes-sync-cmd--extract-hrefs xml))
         (local-dir (file-name-as-directory
                     (expand-file-name notes-sync-local-dir)))
         (count 0))
    (dolist (href hrefs)
      (let ((rel (notes-sync-cmd--href-relative href)))
        ;; rel 为 nil 表示目录项或不在远端目录内，跳过。
        (when (and rel (not (string-suffix-p "/" rel)))
          (let ((target (expand-file-name (url-unhex-string rel) local-dir)))
            (make-directory (file-name-directory target) t)
            (when (eql 0 (notes-sync-get rel target))
              (setq count (1+ count)))))))
    (message "notes-sync: 已从远端拉取 %d 个文件" count)
    count))

(defun notes-sync-push-all ()
  "把本地笔记目录下的全部 .org 文件推送到远端。
递归遍历 `notes-sync-local-dir' 下扩展名为 .org 的文件，对每个文件调用
`notes-conflict-resolve-and-put'（带 If-Match 条件写入 + 冲突检测，冲突时
自动进入三方合并），远端相对路径即该文件相对于本地目录的路径。
返回成功推送的文件数。"
  (interactive)
  (let* ((local-dir (file-name-as-directory
                     (expand-file-name notes-sync-local-dir)))
         (files (directory-files-recursively local-dir "\\.org\\'"))
         (count 0))
    (dolist (file files)
      (when (file-regular-p file)
        (let ((rel (file-relative-name file local-dir)))
          (when (notes-conflict-resolve-and-put file rel)
            (setq count (1+ count))))))
    (message "notes-sync: 已向远端推送 %d 个文件" count)
    count))

(defun notes-sync-status ()
  "同步阅读进度状态（MVP：仅拉取，暂不自动推送批注）。
遍历本地笔记目录下的 .org 文件，以其相对路径作为文档标识（document-id）
调用 `notes-rest-get-progress' 拉取服务端当前阅读进度，并在 message 区提示
有进度的文档数与其中一个示例。返回有进度的文档数。"
  (interactive)
  (let* ((local-dir (file-name-as-directory
                     (expand-file-name notes-sync-local-dir)))
         (files (directory-files-recursively local-dir "\\.org\\'"))
         (total (length files))
         (found 0)
         (sample nil))
    (dolist (file files)
      (when (file-regular-p file)
        (let* ((id (file-relative-name file local-dir))
               (progress (notes-rest-get-progress id)))
          (when progress
            (setq found (1+ found))
            (unless sample
              (setq sample (format "%s @ %s" id
                                   (or (cdr (assq 'position progress))
                                       "?"))))))))
    (message "notes-sync: 阅读进度同步（拉取）完成，%d/%d 个文档有进度%s"
             found total
             (if sample (format "，示例：%s" sample) ""))
    found))

(defun notes-sync-now ()
  "立即执行一次完整同步：拉取 → 推送 → 状态。
依次调用 `notes-sync-pull-all'、`notes-sync-push-all'、`notes-sync-status'，
每步在 message 区提示进度，最后输出完成摘要。任一步骤出错时捕获异常、提示
错误并继续后续步骤，避免单步失败中断整体同步。返回 (拉取 推送 状态) 列表，
各元素为成功计数或符号 `error'（该步失败）。"
  (interactive)
  (message "notes-sync: 开始同步…")
  (let ((pull (condition-case err
                  (notes-sync-pull-all)
                (error
                 (message "notes-sync: 拉取失败：%s" (error-message-string err))
                 'error)))
        (push (condition-case err
                  (notes-sync-push-all)
                (error
                 (message "notes-sync: 推送失败：%s" (error-message-string err))
                 'error)))
        (status (condition-case err
                    (notes-sync-status)
                  (error
                   (message "notes-sync: 状态同步失败：%s"
                            (error-message-string err))
                   'error))))
    (message "notes-sync: 同步完成（拉取 %s，推送 %s，状态 %s）"
             pull push status)
    (list pull push status)))

(defun notes-sync-enable-timer ()
  "启用周期性同步定时器。
每隔 `notes-sync-interval' 秒调用一次 `notes-sync-now'；定时器对象记录在
`notes-sync-cmd--timer'。幂等：已存在运行中的定时器时不重复创建，仅提示。
返回该定时器对象。"
  (interactive)
  (if (timerp notes-sync-cmd--timer)
      (message "notes-sync: 定时同步已启用（每 %s 秒）" notes-sync-interval)
    (setq notes-sync-cmd--timer
          (run-at-time notes-sync-interval notes-sync-interval #'notes-sync-now))
    (message "notes-sync: 已启用定时同步，每 %s 秒执行一次" notes-sync-interval))
  notes-sync-cmd--timer)

(defun notes-sync-disable-timer ()
  "停用周期性同步定时器。
若存在运行中的定时器则取消并清空 `notes-sync-cmd--timer'，否则提示未启用。"
  (interactive)
  (if (timerp notes-sync-cmd--timer)
      (progn
        (cancel-timer notes-sync-cmd--timer)
        (setq notes-sync-cmd--timer nil)
        (message "notes-sync: 已停用定时同步"))
    (message "notes-sync: 定时同步未启用")))

(provide 'notes-sync-cmd)
;;; notes-sync-cmd.el ends here
