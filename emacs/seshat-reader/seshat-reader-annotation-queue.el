;;; seshat-reader-annotation-queue.el --- Offline queue for reader annotations -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, files, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

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

;; seshat-reader 批注的**离线队列**：服务端不可用时，批注的创建/删除操作
;; 先入本地队列暂存，待服务端恢复后再由 `seshat-reader-annotation-queue-sync'
;; 取出并同步到服务端。自动同步的定时调度由本模块负责：模块加载时若
;; `seshat-reader-annotation-queue-auto-sync' 非 nil，会自动经
;; `seshat-reader-annotation-queue-enable-timer' 注册「启动延迟一次 + 周期
;; 轮询」两个定时器（首次延迟由 `seshat-reader-annotation-queue-initial-delay'
;; 决定，周期由 `seshat-reader-annotation-queue-sync-interval' 决定）。
;;
;; 本模块分两层：队列文件的读取、原子写入与增删查为**纯函数层**（不发起
;; 任何服务端调用、不注册定时器、也不写回用户文档）；`-sync' 及其私有辅助
;; 函数则在此基础上逐条发起服务端调用，并在每条成功后即时从队列移除。
;;
;; 队列文件默认位于 \"~/.local/share/seshat/annotation-queue.eld\"（见
;; `seshat-reader-annotation-queue-file'）。写入采用**同目录临时文件 +
;; `rename-file' 原子替换**策略：先把内容 `prin1' 到同目录下的唯一临时
;; 文件，再 `rename-file' 原子覆盖目标文件，避免写入中途崩溃留下损坏内容；
;; 写入前会自动创建父目录。读取时若文件损坏导致 `read' 失败，本模块**报错
;; 并保留原文件不动**，绝不静默覆盖。
;;
;; 队列是一个列表，每个元素是一条批注操作 plist。`:uuid' 是队列内条目的
;; 本地唯一标识（由 `seshat-reader-annotation-queue--new-uuid' 生成），用于
;; 去重与按 UUID 移除；`:queued-at' 是入队时刻的 ISO8601 本地时间。
;;
;; create 条目标识 \"创建\"，形如
;;
;;   (:uuid \"20260101T120000-042917\" :action create
;;    :document-id \"ebook:x.pdf\"
;;    :location \"page:3;rect:10.00,20.00,110.00,40.00\"
;;    :text \"批注正文\"
;;    :queued-at \"2026-01-01T12:00:00+0800\")
;;
;; delete 条目标识 \"删除\"，按服务端批注 id 删除，形如
;;
;;   (:uuid \"20260101T120500-123456\" :action delete
;;    :id 7
;;    :queued-at \"2026-01-01T12:05:00+0800\")
;;
;; 公开接口：
;;
;;   `seshat-reader-annotation-queue-enqueue'  入队一条批注操作
;;   `seshat-reader-annotation-queue-entries'  查询条目（可按文档过滤）
;;   `seshat-reader-annotation-queue-remove'   按 UUID 移除一条条目
;;   `seshat-reader-annotation-queue-count'    统计队列条数
;;   `seshat-reader-annotation-queue-sync'     逐条同步队列并移除已成功条目
;;   `seshat-reader-annotation-queue-enable-timer'   启用自动同步定时器
;;   `seshat-reader-annotation-queue-disable-timer'  关闭自动同步定时器
;;
;; `-sync' 在每条成功后**重读队列并按 UUID 原子移除**（见
;; `seshat-reader-annotation-queue-remove'），因此与用户并发入队不冲突；
;; 任一条同步失败即停止本轮（保留该条及其后续未处理项，稍后重试），队列
;; 文件损坏等需要用户干预的问题则照常 `error' 抛出。本模块**不写回用户
;; 文档**。

;;; Code:

(require 'cl-lib)
(require 'url-util)
(require 'seshat-reader-annotation)

(defgroup seshat-reader-annotation-queue nil
  "批注离线队列（服务不可用时先本地暂存）."
  :group 'seshat-reader-annotation
  :prefix "seshat-reader-annotation-queue-")

(defcustom seshat-reader-annotation-queue-file
  (expand-file-name "annotation-queue.eld" "~/.local/share/seshat/")
  "离线队列文件的路径.

服务端不可用时采集到的批注先暂存于此文件，待服务端恢复后再从中取出同步。
默认值为 \"~/.local/share/seshat/annotation-queue.eld\"（经 `expand-file-name'
展开；路径可用 `~' 表示主目录）。文件内容是一个列表，每个元素是一条批注
操作 plist（`create' 或 `delete'，结构见文件 Commentary）；写入使用同目录
临时文件 + `rename-file' 的原子替换，父目录不存在时会自动创建。"
  :type 'file
  :group 'seshat-reader-annotation-queue)

(defcustom seshat-reader-annotation-queue-auto-sync t
  "是否自动同步离线队列.

为 t（默认）时，检测到服务端恢复后自动把队列中的批注同步到服务端；为 nil
时只在用户显式触发时同步。默认值为 t。自动同步由
`seshat-reader-annotation-queue-enable-timer' 注册的定时器驱动，模块加载时
若本选项非 nil 会自动启用。"
  :type 'boolean
  :group 'seshat-reader-annotation-queue)

(defcustom seshat-reader-annotation-queue-sync-interval 300
  "自动同步的检查间隔，单位为秒.

默认值为 300（即 5 分钟），取值为非负整数。启用
`seshat-reader-annotation-queue-auto-sync' 后，后台按此间隔检查服务端是否
恢复并尝试同步（周期定时器的延迟与间隔均取本值，见
`seshat-reader-annotation-queue-enable-timer'）。"
  :type 'natnum
  :group 'seshat-reader-annotation-queue)

(defcustom seshat-reader-annotation-queue-initial-delay 10
  "Emacs 启动后首次自动同步的延迟秒数.

默认值为 10，取值为非负整数。模块加载并启用自动同步后，首次同步在此延迟
之后触发一次（避免拖慢 Emacs 启动），此后的周期同步间隔由
`seshat-reader-annotation-queue-sync-interval' 决定。"
  :type 'natnum
  :group 'seshat-reader-annotation-queue)

(defcustom seshat-reader-annotation-queue-max-entries 1000
  "队列允许的最大条目数.

默认值为 1000，取值为非负整数。`seshat-reader-annotation-queue-enqueue'
在队列长度达到此值时拒绝入队并给出提示，避免离线期间队列无限增长。"
  :type 'natnum
  :group 'seshat-reader-annotation-queue)

(defun seshat-reader-annotation-queue--read ()
  "读取并返回队列文件中的条目列表.

文件不存在时返回 nil。文件存在但内容无法解析（文件损坏）时 `error'，错误
信息包含文件路径与底层原因；此时**不修改原文件**，保证损坏内容不被静默
覆盖。读回的值若既不是 nil 也不是列表（例如文件内容为 `42'、字符串或点对），
同样 `error'，错误信息含文件路径与实际类型，避免后续 `length' 抛出含义
不明的「Wrong type argument」。"
  (let ((file seshat-reader-annotation-queue-file))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((value (condition-case err
                         (read (current-buffer))
                       (error
                        (error "Seshat Reader annotation queue: 无法解析队列文件 %s：%s"
                               file (error-message-string err))))))
          (unless (or (null value) (listp value))
            (error "Seshat Reader annotation queue: 队列文件内容不是列表（%s）：实际类型为 %s"
                   file (type-of value)))
          value)))))

(defun seshat-reader-annotation-queue--write (queue)
  "把 QUEUE 原子写入 `seshat-reader-annotation-queue-file'.

QUEUE 是队列条目列表，可为 nil（此时写入 nil）。写入采用**同目录临时文件 +
`rename-file' 原子替换**：先在同目录创建唯一临时文件并 `prin1' 写入 QUEUE，
再 `rename-file' 覆盖目标文件，从而避免写入中途崩溃留下损坏文件。写入前用
`make-directory' 确保父目录存在。"
  (let* ((file seshat-reader-annotation-queue-file)
         (dir (file-name-directory file)))
    (make-directory dir t)
    (let* ((temporary-file-directory dir)
           (tmp (make-temp-file "annotation-queue" nil ".eld")))
      (unwind-protect
          (progn
            (with-temp-file tmp
              (let ((print-length nil)
                    (print-level nil))
                (prin1 queue (current-buffer))))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (delete-file tmp))))))

(defun seshat-reader-annotation-queue--new-uuid ()
  "生成一个队列条目 UUID.

格式为 \"<UTC 时间戳>-<6 位随机数>\"，例如 \"20260101T120000-042917\"。
时间戳经 `format-time-string' 以 UTC 生成（第三个参数传入非 nil），与本地时区无关。"
  (format "%s-%06d" (format-time-string "%Y%m%dT%H%M%S" nil t) (random 1000000)))

(defun seshat-reader-annotation-queue-enqueue (entry)
  "把一条批注操作 ENTRY 追加到离线队列并写回文件.

ENTRY 是表示批注操作的 plist（`create' 或 `delete'，结构见文件
Commentary）。本函数为其补齐 `:uuid'（若尚无）与 `:queued-at'（ISO8601
本地时间），追加到现有队列尾部并原子写回。

队列长度已达 `seshat-reader-annotation-queue-max-entries' 时**拒绝入队**：
`message' 提示当前条数与上限并返回 nil。

入队成功时返回补全后的 ENTRY。"
  (let ((queue (seshat-reader-annotation-queue--read)))
    (if (>= (length queue) seshat-reader-annotation-queue-max-entries)
        (progn
          (message "Seshat Reader annotation queue: 队列已达上限（当前 %d 条，上限 %d），拒绝入队 %S。"
                   (length queue) seshat-reader-annotation-queue-max-entries entry)
          nil)
      (let ((new (copy-sequence entry)))
        (unless (plist-get new :uuid)
          (setq new (plist-put new :uuid (seshat-reader-annotation-queue--new-uuid))))
        (setq new (plist-put new :queued-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
        (seshat-reader-annotation-queue--write (append queue (list new)))
        new))))

(defun seshat-reader-annotation-queue-entries (&optional document-id)
  "返回队列中的条目列表.

无 DOCUMENT-ID 时返回全部条目（保持入队顺序）。给定 DOCUMENT-ID 时只返回
`:document-id' 与之 `string=' 相等的条目。队列文件不存在时返回 nil。"
  (let ((all (seshat-reader-annotation-queue--read)))
    (if document-id
        (cl-remove-if-not
         (lambda (entry)
           (let ((id (plist-get entry :document-id)))
             (and (stringp id) (string= document-id id))))
         all)
      all)))

(defun seshat-reader-annotation-queue-remove (uuid)
  "按 UUID 从队列移除对应条目.

UUID 与条目的 `:uuid' 用 `string=' 精确比较。找到并移除（含写回）时返回 t；
找不到时**静默**返回 nil，且不改动队列文件。"
  (let* ((queue (seshat-reader-annotation-queue--read))
         (remaining (cl-remove-if
                     (lambda (entry)
                       (let ((id (plist-get entry :uuid)))
                         (and (stringp id) (string= uuid id))))
                     queue)))
    (when (< (length remaining) (length queue))
      (seshat-reader-annotation-queue--write remaining)
      t)))

(defun seshat-reader-annotation-queue-count ()
  "返回队列中的条目数量.

队列文件不存在时返回 0。"
  (length (seshat-reader-annotation-queue--read)))

;;; 同步到服务端

(defun seshat-reader-annotation-queue--sync-create (entry)
  "同步一条 create 条目 ENTRY，返回 `ok' 或 `stop'.

ENTRY 为队列中的 create 操作 plist（含 `:document-id'、`:location'、`:text'）。
先经 `seshat-reader-annotation--fetch' 拉取该文档的服务端批注：

- 返回失败哨兵 `seshat-reader-annotation--fetch-error' 时视为服务暂不可达，
  返回 `stop'（保留本条，稍后重试）；
- 返回批注列表时，若其中某条批注的 `location' 与 `text' 已与本条完全一致，
  视为已同步，返回 `ok' 且**不**发起 POST（去重）；
- 否则调用 `seshat-rest-create-annotation' 创建：成功（返回含 `id' 的 alist）
  返回 `ok'，失败（返回 nil 或抛 error）返回 `stop'。"
  (let* ((document-id (plist-get entry :document-id))
         (location (plist-get entry :location))
         (text (plist-get entry :text))
         (existing (seshat-reader-annotation--fetch document-id)))
    (cond
     ((eq existing seshat-reader-annotation--fetch-error)
      'stop)
     ((cl-some (lambda (item)
                 (and (equal (alist-get 'location item) location)
                      (equal (alist-get 'text item) text)))
               existing)
      'ok)
     (t
      (condition-case nil
          (let ((response (seshat-rest-create-annotation document-id location text)))
            (if (and (listp response) (alist-get 'id response))
                'ok
              'stop))
        (error 'stop))))))

(defun seshat-reader-annotation-queue--sync-delete (entry)
  "同步一条 delete 条目 ENTRY，返回 `ok' 或 `stop'.

ENTRY 为队列中的 delete 操作 plist（含 `:id'）。本函数**直接调用
`seshat-rest--request'** 以便按 HTTP 状态码区分结果（因为封装层
`seshat-rest-delete-annotation' 对 404 等非 2xx 统一返回 nil，无法区分
「原本已不存在」与「真正失败」）：状态码为 2xx，或为 **404**（批注已不存在，
删除幂等成功）时返回 `ok' 并移除该条。状态码为 **400** 时属**终态失败**
（请求非法，重试也不会成功）：返回 `ok' 以丢弃该条、避免它永久阻塞其后
条目，同时 `message' 告警提示该 id 被服务端拒绝。其它非 2xx 状态码或请求
抛 error 时返回 `stop'（保留该条待重试）。"
  (condition-case nil
      (let ((status (car (seshat-rest--request
                          "DELETE"
                          (format "/api/annotations/%s"
                                  (url-hexify-string
                                   (format "%s" (plist-get entry :id))))))))
        (cond
         ((and (integerp status)
               (or (and (>= status 200) (< status 300))
                   (= status 404)))
          'ok)
         ((eql status 400)
          (message "Seshat Reader annotation queue: 删除条目 id=%s 被服务端拒绝（HTTP 400），已从队列丢弃。"
                   (plist-get entry :id))
          'ok)
         (t 'stop)))
    (error 'stop)))

(defun seshat-reader-annotation-queue-sync (&optional document-id)
  "把离线队列中的批注操作同步到服务端并返回 (成功数 . 剩余数).

DOCUMENT-ID 非 nil 时只同步该文档的条目（经
`seshat-reader-annotation-queue-entries' 过滤，保持入队顺序），否则同步全部。

逐条处理并**在每条成功后立即**用 `seshat-reader-annotation-queue-remove'
按 UUID 重读队列、原子写回；因此与用户并发入队不冲突——本轮只会移除自己
处理过（并按 UUID 命中）的条目，新入队的条目不会被误删。各 action 的语义：

- create：先经 `seshat-reader-annotation--fetch' 拉取该文档的服务端批注；
  返回失败哨兵视为服务暂不可达，停止本轮；返回列表时若已有 `location' 与
  `text' 均与队列条目完全一致的批注，视为已同步、不重复创建；否则经
  `seshat-rest-create-annotation' 创建，失败即停止本轮。
- delete：直接查 `seshat-rest--request' 的 HTTP 状态码，2xx 或 404 视为
  成功并移除，其它非 2xx 或异常时停止本轮。

任一 action 停止后，该条及其后续未处理项均保留在队列中（「服务暂不可达，
已保留 N 条待下次同步」属预期路径，不是错误）。返回值中成功数为本轮已同步
并移除的条目数，剩余数由 `seshat-reader-annotation-queue-count' 现算（含
并发新入队的条目）。

队列文件损坏等需要用户干预的问题不在此吞掉，会照常 `error' 抛出。"
  (let ((entries (seshat-reader-annotation-queue-entries document-id))
        (synced 0)
        (stopped nil))
    (while (and entries (not stopped))
      (let* ((entry (car entries))
             (result (pcase (plist-get entry :action)
                       ('create (seshat-reader-annotation-queue--sync-create entry))
                       ('delete (seshat-reader-annotation-queue--sync-delete entry))
                       (_ 'stop))))
        (setq entries (cdr entries))
        (if (eq result 'ok)
            (progn
              (seshat-reader-annotation-queue-remove (plist-get entry :uuid))
              (setq synced (1+ synced)))
          (setq stopped t))))
    (let ((remaining (seshat-reader-annotation-queue-count)))
      (cond
       ((and (zerop synced) (zerop remaining))
        (message "Seshat Reader annotation queue: 批注队列同步：队列为空。"))
       (stopped
        (message "Seshat Reader annotation queue: 批注队列同步：已同步 %d 条，服务暂不可达，已保留 %d 条待下次同步。"
                 synced remaining))
       (t
        (message "Seshat Reader annotation queue: 批注队列同步：已同步 %d 条，剩余 %d 条。"
                 synced remaining)))
      (cons synced remaining))))

;;; 自动同步定时器

(defvar seshat-reader-annotation-queue--initial-timer nil
  "当前「启动后延迟首次同步」的一次性定时器，或 nil.

由 `seshat-reader-annotation-queue-enable-timer' 建立、
`seshat-reader-annotation-queue-disable-timer' 清除。")

(defvar seshat-reader-annotation-queue--timer nil
  "当前周期同步定时器，或 nil.

由 `seshat-reader-annotation-queue-enable-timer' 建立、
`seshat-reader-annotation-queue-disable-timer' 清除。")

(defun seshat-reader-annotation-queue--timer-sync ()
  "定时器回调：自动同步离线队列.

仅当 `seshat-reader-annotation-queue-auto-sync' 非 nil 且队列非空时，调用
`seshat-reader-annotation-queue-sync' 同步全部条目。本函数**永不抛错**：
读取队列或同步过程中的任何错误都在此捕获，只 `message' 一行说明；因为
定时器回调抛出的错误会打断后续周期，导致自动同步停摆。"
  (when seshat-reader-annotation-queue-auto-sync
    (condition-case nil
        (when (> (seshat-reader-annotation-queue-count) 0)
          (seshat-reader-annotation-queue-sync))
      (error
       (message "Seshat Reader annotation queue: 定时自动同步失败（本轮跳过，稍后重试）。")))))

(defun seshat-reader-annotation-queue-enable-timer ()
  "启用离线队列的自动同步定时器（幂等）.

若 `seshat-reader-annotation-queue-auto-sync' 为 nil，则不创建任何定时器，
只 `message' 一行说明并返回 nil。否则先取消已有的定时器（`--initial-timer'
与 `--timer' **两个都跟踪**，故重复调用不会堆积定时器），再注册两个
`run-with-timer' 定时器：首次同步延迟
`seshat-reader-annotation-queue-initial-delay' 秒后触发一次，其返回值存入
`seshat-reader-annotation-queue--initial-timer'；周期同步的延迟与间隔均取
`seshat-reader-annotation-queue-sync-interval'，其返回值存入
`seshat-reader-annotation-queue--timer' 并返回之。

一律使用 `run-with-timer' 而非 `run-with-idle-timer'：后者在
`emacs --daemon' 下不可靠。"
  (if seshat-reader-annotation-queue-auto-sync
      (progn
        (seshat-reader-annotation-queue-disable-timer)
        (setq seshat-reader-annotation-queue--initial-timer
              (run-with-timer seshat-reader-annotation-queue-initial-delay nil
                              #'seshat-reader-annotation-queue--timer-sync))
        (setq seshat-reader-annotation-queue--timer
              (run-with-timer seshat-reader-annotation-queue-sync-interval
                              seshat-reader-annotation-queue-sync-interval
                              #'seshat-reader-annotation-queue--timer-sync)))
    (message "Seshat Reader annotation queue: 自动同步已关闭（-auto-sync 为 nil），未启用定时器。")
    nil))

(defun seshat-reader-annotation-queue-disable-timer ()
  "关闭离线队列的自动同步定时器（幂等）.

对 `seshat-reader-annotation-queue--initial-timer'（一次性）与
`seshat-reader-annotation-queue--timer'（周期）**两个**定时器分别检查
`timerp'：为真时用 `cancel-timer' 取消，随后把两个变量都置为 nil；重复调用
是安全的 no-op。"
  (when (timerp seshat-reader-annotation-queue--initial-timer)
    (cancel-timer seshat-reader-annotation-queue--initial-timer))
  (when (timerp seshat-reader-annotation-queue--timer)
    (cancel-timer seshat-reader-annotation-queue--timer))
  (setq seshat-reader-annotation-queue--initial-timer nil)
  (setq seshat-reader-annotation-queue--timer nil))

;;; 模块加载时自动启用

(when seshat-reader-annotation-queue-auto-sync
  (seshat-reader-annotation-queue-enable-timer))

(provide 'seshat-reader-annotation-queue)
;;; seshat-reader-annotation-queue.el ends here
