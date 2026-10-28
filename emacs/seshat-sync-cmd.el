;;; seshat-sync-cmd.el --- 笔记同步命令（手动 + 定时） -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: comm, notes, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; 本模块把 REST 增量同步引擎（`seshat-sync'）与 REST 状态同步
;; （`seshat-rest'）封装成面向用户的「手动 + 定时」同步命令，是桌面端 Emacs
;; 插件的顶层入口。M8 起引擎内部由 `seshat-conflict' 承担 412 的三方合并，
;; 本模块不再直接调用它。
;;
;; 一次完整同步（`seshat-sync-now'）依次执行四个阶段：
;;
;;   1. 拉取（`seshat-sync-pull'）：首同步建索引 + changes 追平，增量走游标；
;;   2. 改名检测（`seshat-sync-detect-renames'）：本地内容改动标脏、rename
;;      上报 `move-resource'。**必须排在推送之前**——否则改名产生的 dirty 与
;;      uid 路径变更会漏推；
;;   3. 推送（`seshat-sync-push'）：对脏条目做条件写（`If-Match' /
;;      `If-None-Match'），412 时引擎内部自动三方合并；
;;   4. 状态（`seshat-sync-status'）：按 uid 拉取阅读进度（MVP 仅拉取，不推送
;;      批注）；失败只告警，不影响前两步的内容同步成果。
;;
;; 手动触发：M-x seshat-sync-now。
;; 修改 `seshat-sync-roots'（增删根、改根目录）之后：M-x seshat-sync-reset-roots
;; 让新配置立即生效（状态库里的旧根映射会挡住新配置，见该命令的文档串）。
;; 未配置 `seshat-sync-roots' 时 `seshat-sync-now' 只提示一条说明并短路返回，
;; 不会假装「同步完成（0 批 / 0 个事件）」。
;; 定时触发：M-x seshat-sync-enable-timer 启用（间隔 `seshat-sync-interval' 秒），
;;           M-x seshat-sync-disable-timer 停用。定时器对象记录在
;;           `seshat-sync-cmd--timer' 中，重复启用不会创建多个定时器。
;;
;; 使用前需先配置 `seshat-sync-server-url'、`seshat-sync-username'、
;; `seshat-sync-token'、`seshat-sync-local-dir'、`seshat-sync-remote-dir'
;; （见 seshat-sync.el），以及 `seshat-rest-base-url'、`seshat-rest-token'
;; （见 seshat-rest.el）。

;;; Code:

(require 'seshat-sync)
(require 'seshat-rest)
(require 'seshat-conflict)
(require 'subr-x)
(require 'url-util)

(defgroup seshat-sync-cmd nil
  "笔记同步命令（手动 + 定时）。"
  :group 'tools
  :prefix "seshat-sync-")

(defcustom seshat-sync-interval 300
  "定时同步的间隔秒数。
变量 `seshat-sync-enable-timer' 以该值作为周期性调用 `seshat-sync-now' 的
间隔（同时也是首次触发的延迟）。默认 300 秒（5 分钟）。"
  :type 'number
  :group 'seshat-sync-cmd)

(defvar seshat-sync-cmd--timer nil
  "当前正在运行的定时同步 timer 对象；nil 表示未启用。
由 `seshat-sync-enable-timer' 与 `seshat-sync-disable-timer' 维护，用于保证
启用操作的幂等性（已存在运行中的定时器时不重复创建）。")


;;; 响应解析辅助

(defun seshat-sync-cmd--safe-local-path (rel)
  "把远端返回的相对路径 REL 规范化为安全的本地相对路径。
REL 为已按百分号解码的相对路径。返回规范化后的相对路径（以 \"/\" 分隔，
不含 \".\" 与 \"..\" 段）；下列情况视为越界/不安全并返回 nil：

  - REL 为空；
  - REL 为绝对路径（以 \"/\" 开头）、以 \"~\" 开头（`expand-file-name'
    会把它展开到家目录）或带 Windows 盘符前缀（如 \"C:\"）；
  - REL 经规范化（消去 \".\"/\"..\" 段）后上溯到起始目录之外，例如
    \"../x\"、\"a/../../b\"。

该函数不触碰文件系统，是纯函数，便于单元测试；落盘前仍应再用
`expand-file-name' + `file-in-directory-p' 做一次边界校验，以覆盖符号链接等
运行时情形。"
  (when (and (stringp rel)
             (not (string-empty-p rel))
             (not (string-prefix-p "/" rel))
             (not (string-prefix-p "~" rel))
             (not (string-match-p "\\`[A-Za-z]:" rel)))
    (let ((stack nil)
          (escape nil))
      (dolist (seg (split-string rel "/" t))
        (cond
         ((string= seg ".") nil)
         ((string= seg "..")
          (if stack (pop stack) (setq escape t)))
         (t (push seg stack))))
      (unless escape
        (when stack
          (mapconcat #'identity (nreverse stack) "/"))))))


;;; 统计汇报辅助
;;
;; 引擎层（`seshat-sync'）返回统计 plist 且不发 message，汇报统一在本层做，
;; 沿用 M8 之前「每步一行 message + 末行摘要」的观感。

(defun seshat-sync-cmd--report-pull (stats)
  "汇报拉取统计 STATS（`seshat-sync-pull' 的返回值）并原样返回。
首同步与增量共用一行格式，只切换前缀。

`:configured' 为 nil 表示根映射不可用（未配置 `seshat-sync-roots' 或其中没有
有效项），此时 `seshat-sync-pull' 直接返回、什么都没拉——汇报成「拉取完成
（0 批 / 0 个事件）」会误导用户，故改报未配置并给出配置提示。"
  (if (null (plist-get stats :configured))
      (message "seshat-sync: 未配置 `seshat-sync-roots'，本次跳过同步（请先配置根映射）")
    (let* ((changes (plist-get stats :changes))
           (batches (or (plist-get changes :batches) 0))
           (events (or (plist-get changes :events) 0)))
      (message "seshat-sync: %s完成（%d 批 / %d 个事件）"
               (if (plist-get stats :first-sync) "首同步" "拉取")
               batches events)))
  stats)

(defun seshat-sync-cmd--report-renames (stats)
  "汇报改名 / 本地改动检测统计 STATS（`seshat-sync-detect-renames' 的返回值）."
  (message "seshat-sync: 改名检测完成（标脏 %d，改名 %d，冲突 %d，失败 %d）"
           (or (plist-get stats :dirty-marked) 0)
           (or (plist-get stats :renamed) 0)
           (or (plist-get stats :conflict) 0)
           (or (plist-get stats :failed) 0))
  stats)

(defun seshat-sync-cmd--report-push (stats)
  "汇报推送统计 STATS（`seshat-sync-push' 的返回值）."
  (message "seshat-sync: 推送完成（成功 %d，冲突 %d，跳过 %d，失败 %d）"
           (or (plist-get stats :pushed) 0)
           (or (plist-get stats :conflicted) 0)
           (or (plist-get stats :skipped) 0)
           (or (plist-get stats :failed) 0))
  stats)

(defun seshat-sync-cmd--outcome (value keys)
  "把一步的结果 VALUE 渲染成摘要用的短字符串。
VALUE 为符号 `error' 时返回 \"失败\"；为 plist 时按 KEYS（关键字列表，逐层
下钻）取计数，取不到按 0 计；其余情形（如 `seshat-sync-status' 的整数计数）
直接格式化。"
  (cond
   ((eq value 'error) "失败")
   ((and (listp value) (keywordp (car-safe value)))
    (let ((cursor value))
      (dolist (key keys)
        (setq cursor (plist-get cursor key)))
      (format "%s" (or cursor 0))))
   (t (format "%s" value))))


;;; 根解析辅助（`seshat-sync-status' 用）

(defun seshat-sync-cmd--root-relative (path)
  "把本地绝对路径 PATH 解析为状态库根内的 `(TAG . REL-PATH)'；解析不出返回 nil。
按 `seshat-state-roots' 各元素的本地目录做**最长前缀**匹配：根目录允许嵌套
（例如 `~/notes' 与 `~/notes/archive'），取最短前缀会把内层根下的路径错判成
外层根，进而用错 uid。REL-PATH 与 `seshat-state-uid-for-path' 的 PATH 同口径。

本函数**不复用** `seshat-conflict--root-for-path'：那是冲突模块的私有函数，
且只覆盖 `seshat-sync-status' 需要的「绝对路径」一种输入。"
  (when (and (stringp path) (file-name-absolute-p path))
    (let ((expanded (expand-file-name path))
          (best nil)
          (best-length -1))
      (dolist (entry (seshat-state-roots))
        (let* ((tag (nth 0 entry))
               (dir (nth 1 entry))
               (dir (when (and (stringp dir) (not (string-empty-p dir)))
                      (file-name-as-directory (expand-file-name dir)))))
          (when (and (stringp tag) dir
                     (string-prefix-p dir expanded)
                     (> (length dir) best-length))
            (setq best (cons tag (file-relative-name expanded dir)))
            (setq best-length (length dir)))))
      best)))

(defun seshat-sync-cmd--uid-for-file (path)
  "返回本地文件 PATH 在状态库里登记的 uid；未登记 / 不在任何已配置根内返回 nil。
`seshat-state-uid-for-path' 只接受 `(ROOT . 相对路径)' 复合键，故先解析根；
墓碑与孤儿条目的路径已被清空，同样返回 nil。"
  (let ((root-relative (seshat-sync-cmd--root-relative path)))
    (when root-relative
      (seshat-state-uid-for-path (car root-relative) (cdr root-relative)))))


;;; 顶层命令

(defun seshat-sync-pull-all ()
  "拉取服务端变更到本地（兼容入口，等价于一次 `seshat-sync-pull'）。
M8 起走 REST 增量引擎；旧的 WebDAV 全量实现已由新引擎替代（必要时可回滚到
提交 `203d2c3' 之前的实现）。命令名与调用签名保持不变，原有键位与
`seshat-sync-now' 的定时调用仍可照旧使用。返回 `seshat-sync-pull' 的统计
plist（`(:first-sync :index :changes)'）。"
  (interactive)
  (seshat-sync-cmd--report-pull (seshat-sync-pull)))

(defun seshat-sync-push-all ()
  "检测本地改名并把脏条目推送到服务端（兼容入口）。
等价于 `seshat-sync-detect-renames' + `seshat-sync-push'：先标脏 / 上报
rename，再做条件写推送。M8 起走 REST 增量引擎；旧的 WebDAV 全量实现已由新
引擎替代（必要时可回滚到提交 `203d2c3' 之前的实现）。命令名与调用签名保持
不变。返回 `seshat-sync-push' 的统计 plist
\(`(:pushed :conflicted :skipped :failed)')。"
  (interactive)
  (seshat-sync-cmd--report-renames (seshat-sync-detect-renames))
  (seshat-sync-cmd--report-push (seshat-sync-push)))

(defun seshat-sync-status ()
  "同步阅读进度状态（MVP：仅拉取，暂不自动推送批注）。
遍历本地笔记目录下的 .org 文件，按状态库登记的 uid（服务端权威文档标识，
经 `seshat-sync-cmd--uid-for-file' 用根 tag + 根内相对路径解析）调用
`seshat-rest-get-progress' 拉取当前阅读进度。

未登记的文件（本地新文件，尚未经 `seshat-sync-now' 建立 uid）跳过并提示；
`seshat-sync-status' 曾在 M8 之前把相对路径当 uid 传（既有 bug，已修）。返回
有进度的文档数。"
  (interactive)
  (let* ((local-dir (file-name-as-directory
                     (expand-file-name seshat-sync-local-dir)))
         (files (directory-files-recursively local-dir "\\.org\\'"))
         (total (length files))
         (found 0)
         (sample nil))
    (dolist (file files)
      (when (file-regular-p file)
        (let ((uid (seshat-sync-cmd--uid-for-file file)))
          (cond
           ((null uid)
            (message "seshat-sync: %s 未登记，先运行 `seshat-sync-now'"
                     (file-relative-name file local-dir)))
           (t
            (let ((progress (seshat-rest-get-progress uid)))
              (when progress
                (setq found (1+ found))
                (unless sample
                  (setq sample
                        (format "%s（%s）@ %s"
                                uid (file-relative-name file local-dir)
                                (or (cdr (assq 'position progress)) "?")))))))))))
    (message "seshat-sync: 阅读进度同步（拉取）完成，%d/%d 个文档有进度%s"
             found total
             (if sample (format "，示例：%s" sample) ""))
    found))

(defun seshat-sync-now ()
  "立即执行一次完整同步：拉取 → 改名检测 → 推送 → 状态。
依次调用 `seshat-sync-pull'、`seshat-sync-detect-renames'、`seshat-sync-push'
与 `seshat-sync-status'（M8 起走 REST 增量引擎）。**顺序不可调换**：rename 产生
的 dirty 与 uid 路径变更必须先落到 state，push 才能按新路径推送，否则改名会
漏推。

每步在 message 区提示统计，最后输出完成摘要。任一步骤出错时捕获异常、提示
错误并继续后续步骤，避免单步失败中断整体同步——因此 `seshat-sync-status'
失败（只影响进度展示）不会撤销前面已完成的内容同步。返回
\(拉取 改名 推送 状态) 列表，各元素为该步的统计（plist 或计数）或符号
`error'（该步失败）。

**未配置根映射时短路**：`seshat-sync-pull' 的返回里 `:configured' 为 nil 表示
状态库没有根映射（未配置 `seshat-sync-roots'，或其中的项全部无效）。此时拉取
什么都没做，改名检测与推送也只能在空集上空转、状态同步无 uid 可用——本函数
仅提示一条说明便返回 `(unconfigured)'，不再调用后三步，也不打印「同步完成」
摘要（那会让用户误以为同步已成功跑过一轮）。"
  (interactive)
  (message "seshat-sync: 开始同步…")
  (let ((pull (condition-case err
                  (seshat-sync-cmd--report-pull (seshat-sync-pull))
                (error
                 (message "seshat-sync: 拉取失败：%s" (error-message-string err))
                 'error))))
    (if (and (consp pull) (null (plist-get pull :configured)))
        (progn
          (message (concat "seshat-sync: 本次同步跳过（未配置 `seshat-sync-roots'，"
                           "请先配置根映射；配置后运行 M-x seshat-sync-reset-roots "
                           "或再运行一次本命令）"))
          (list 'unconfigured))
      (let ((renames (condition-case err
                         (seshat-sync-cmd--report-renames
                          (seshat-sync-detect-renames))
                       (error
                        (message "seshat-sync: 改名检测失败：%s"
                                 (error-message-string err))
                        'error)))
            (push (condition-case err
                      (seshat-sync-cmd--report-push (seshat-sync-push))
                    (error
                     (message "seshat-sync: 推送失败：%s" (error-message-string err))
                     'error)))
            (status (condition-case err
                        (seshat-sync-status)
                      (error
                       (message "seshat-sync: 状态同步失败：%s"
                                (error-message-string err))
                       'error))))
        (message "seshat-sync: 同步完成（拉取 %s，改名 %s，推送 %s，状态 %s）"
                 (seshat-sync-cmd--outcome pull '(:changes :events))
                 (seshat-sync-cmd--outcome renames '(:renamed))
                 (seshat-sync-cmd--outcome push '(:pushed))
                 (seshat-sync-cmd--outcome status nil))
        (list pull renames push status)))))

(defun seshat-sync-reset-roots ()
  "清空状态库里的根映射并按 `seshat-sync-roots' 重新初始化。
修改 `seshat-sync-roots' 后运行本命令让新配置生效；下一次 `seshat-sync-now'
也会自动完成初始化。

`seshat-sync--ensure-roots' 只在状态库的根映射**为空**时才读 `seshat-sync-roots'
（已初始化就直接返回，避免每次 pull 都请求 `/api/roots' 并覆盖用户的映射）。
于是用户增删根、改根目录之后，状态库里的旧映射一直挡在前面，新配置永远不生效。
本命令先 `seshat-state-set-roots' 置空、`seshat-state-save' 落盘，再调
`seshat-sync--ensure-roots' 按当前配置重建并落盘。

返回重建后的根映射列表（`(TAG DIR MODE)' 的元素列表，DIR 已展开为绝对路径）；
`seshat-sync-roots' 未配置或其中没有有效项时返回 nil（此时状态库的根映射保持为
空，`seshat-sync-now' 会按「未配置」短路）。不加键位：`M-x' 调用即可。"
  (interactive)
  (seshat-state-set-roots nil)
  (seshat-state-save)
  (let ((roots (seshat-sync--ensure-roots)))
    (cond
     (roots
      (dolist (root roots)
        (message "seshat-sync: 根映射已重建：%s → %s（%s）"
                 (nth 0 root) (nth 1 root) (nth 2 root))))
     ((null seshat-sync-roots)
      (message (concat "seshat-sync: 根映射重建失败：`seshat-sync-roots' 未配置，"
                       "状态库的根映射已清空")))
     (t
      (message (concat "seshat-sync: 根映射重建失败：`seshat-sync-roots' 里没有"
                       "有效项（检查各根的 TAG / DIR / MODE），状态库的根映射已清空"))))
    roots))

(defun seshat-sync-enable-timer ()
  "启用周期性同步定时器。
每隔 `seshat-sync-interval' 秒调用一次 `seshat-sync-now'；定时器对象记录在
`seshat-sync-cmd--timer'。幂等：已存在运行中的定时器时不重复创建，仅提示。
返回该定时器对象。"
  (interactive)
  (if (timerp seshat-sync-cmd--timer)
      (message "seshat-sync: 定时同步已启用（每 %s 秒）" seshat-sync-interval)
    (setq seshat-sync-cmd--timer
          (run-at-time seshat-sync-interval seshat-sync-interval #'seshat-sync-now))
    (message "seshat-sync: 已启用定时同步，每 %s 秒执行一次" seshat-sync-interval))
  seshat-sync-cmd--timer)

(defun seshat-sync-disable-timer ()
  "停用周期性同步定时器。
若存在运行中的定时器则取消并清空 `seshat-sync-cmd--timer'，否则提示未启用。"
  (interactive)
  (if (timerp seshat-sync-cmd--timer)
      (progn
        (cancel-timer seshat-sync-cmd--timer)
        (setq seshat-sync-cmd--timer nil)
        (message "seshat-sync: 已停用定时同步"))
    (message "seshat-sync: 定时同步未启用")))

(provide 'seshat-sync-cmd)
;;; seshat-sync-cmd.el ends here
