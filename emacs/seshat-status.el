;;; seshat-status.el --- 启动汇总与状态详情 buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: tools
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

;; 启动后**一次性**把 Seshat 的整体状态汇总到 echo area，并提供
;; `*Seshat Status*' 详情 buffer。解决的问题是：用户打开 Emacs 时不知道
;; 书库下没下完、有多少笔记/批注还没同步、上次同步到底成没成——这些信息
;; 散落在状态库、离线队列与日志三处，逐个 `M-x' 去查太重。
;;
;; 三条设计红线：
;;
;; 1. **零网络**：本模块**不发任何请求**。服务端可达性用「上次运行结论」
;;    （`seshat-state-runtime' 的 `:last-sync-at' / `:last-sync-result' /
;;    `:last-sync-error'，由同步收尾写入），因此启动路径不依赖网络。也**不**
;;    require `seshat-rest' / `seshat-library' / `seshat-covers' /
;;    `seshat-reads'：书架、封面、阅读器都是重模块，启动汇总不该把它们拉起来
;;    （`seshat-sync' 自身会间接加载 `seshat-rest'，但那只带来定义、不带来
;;    请求；「零网络」判据是**不发起调用**，见测试里的 `seshat-rest--request'
;;    桩替断言）。
;;
;; 2. **不拖慢启动**：`emacs-startup-hook' 里只注册一个 `run-at-time' 延迟
;;    定时器，真正的计算与 `message' 都发生在延迟之后（默认 2 秒），且整体被
;;    `ignore-errors' 包住——汇总失败绝不能影响 Emacs 启动。
;;
;; 3. **只读快照可测**：`seshat-status-summary' 无写副作用（不写文件、不发请求、
;;    不 `message'、不建定时器），但**会读**状态库/队列/文件系统——它是「只读
;;    快照函数」而不是纯函数（零参 + 读全局，见其 docstring）；单条失败（根目录
;;    不可读、路径越界）按「未下载」处理，绝不让整个汇总抛错。
;;
;; 数据来源与口径：
;;
;; - 书库总数 N：状态库里 `:root' 属于 `seshat-state-roots' 中 MODE 为
;;   "ondemand" 的活条目数（`mirror' 根是整目录镜像，不按「本」计）。
;; - 本地已下载 M：上述条目按 `seshat-sync--root-dir' + `seshat-sync--local-path'
;;   拼出本地路径后 `file-exists-p' 为真的条数（文件可能被外部删掉，故不信任
;;   状态库的「有路径」）。
;; - 待同步笔记 X：`seshat-state-dirty-uids' 的长度。
;; - 待同步批注 Y：`seshat-reader-annotation-queue-count'，**软依赖**——批注
;;   队列模块不在 `load-path' 时 Y 为 nil（汇总照常工作，只是不提批注）。
;; - 状态库损坏：`seshat-state--load-was-corrupt'（`boundp' 守卫）。
;; - 从未同步：状态库无根映射**且**无运行记录。它与「状态库损坏」是**两个
;;   不同分支**：损坏的库可能仍留有根映射（用户手工改坏一两个字段），从未
;;   同步的库则既无根也无运行记录，二者不得合并成一个 nil 判断。

;;; Code:

(require 'cl-lib)
(require 'seshat-state)
(require 'seshat-sync)
(require 'seshat-log)

;; `seshat-sync' 的私有辅助函数：跨模块调用在本仓库是既有惯例（同步器与
;; 书架都这么用），这里显式 `declare-function' 只为消掉字节编译告警。
(declare-function seshat-sync--root-dir "seshat-sync" (root))
(declare-function seshat-sync--local-path "seshat-sync" (root-dir path))

;; 批注队列是**软依赖**（阅读器子模块，可缺席）；`seshat-show-log' 恒可用。
(declare-function seshat-reader-annotation-queue-count
                  "seshat-reader-annotation-queue" ())
(declare-function seshat-show-log "seshat-log" ())

(defgroup seshat-status nil
  "Seshat 启动汇总与状态详情。"
  :group 'tools
  :prefix "seshat-status-")

(defcustom seshat-status-startup-notify t
  "非 nil 时在 Emacs 启动后一次性在 echo area 汇总 Seshat 状态.
置为 nil 则完全不提醒（仍可随时 `M-x seshat-status' 看详情）。"
  :type 'boolean
  :group 'seshat-status)

(defcustom seshat-status-startup-delay 2
  "启动汇总延迟的秒数.
不在 `emacs-startup-hook' 里同步计算：既避免拖慢启动，也避免与启动期其他
`message'（`initial-buffer-choice'、包加载提示）抢 echo area。"
  :type 'number
  :group 'seshat-status)

(defconst seshat-status--buffer-name "*Seshat Status*"
  "详情 buffer 的名字。")

(defconst seshat-status--log-tail-lines 20
  "详情 buffer 里「日志摘要」一节展示的行数（末 N 行）。")

;;; 状态汇总（只读快照）

(defun seshat-status--ondemand-roots (roots)
  "从根映射列表 ROOTS 中筛出 MODE 为 \"ondemand\" 的根标签列表.
ROOTS 的元素形如 `(TAG DIR MODE)'（见 `seshat-state-roots'）；形状不合法
的元素被跳过——启动汇总不该因为一条畸形配置就整段失败。"
  (let (result)
    (dolist (root roots (nreverse result))
      (when (and (proper-list-p root)
                 (equal "ondemand" (nth 2 root)))
        (push (nth 0 root) result)))))

(defun seshat-status--downloaded-p (entry)
  "判断状态库条目 ENTRY 对应的本地文件是否存在.
按 `seshat-sync--root-dir' + `seshat-sync--local-path' 拼路径（后者同时做
越界校验）；根未配置、路径越界、目录不可读等任何异常都按「未下载」处理，
绝不上抛——单条失败不能拖垮整份汇总。"
  (ignore-errors
    (let ((root-dir (seshat-sync--root-dir (plist-get entry :root)))
          (path (plist-get entry :path)))
      (when (and root-dir path)
        (when-let* ((local (seshat-sync--local-path root-dir path)))
          (file-exists-p local))))))

(defun seshat-status--pending-annotations ()
  "返回离线批注队列的条目数；批注队列模块未加载或读取失败时返回 nil.
批注队列属阅读器子模块（`seshat-reader-annotation-queue'），可能不在
`load-path'。

**只查 `featurep'，不主动 `require'**：队列模块的顶层会在
`seshat-reader-annotation-queue-auto-sync' 非 nil 时立刻注册自动同步定时器。
启动汇总若为「数一下待同步批注」而 `require' 它，就会顺带把后台同步定时器
点起来——一个只读的启动汇总不该改变运行态。因此模块没加载时直接返回 nil，
由上层省略该字段（`seshat-status' 详情 buffer 显示「不可用」）。"
  (when (featurep 'seshat-reader-annotation-queue)
    (when (fboundp 'seshat-reader-annotation-queue-count)
      (ignore-errors (seshat-reader-annotation-queue-count)))))

(defun seshat-status--corrupt-p ()
  "返回状态库本次加载是否损坏（`seshat-state--load-was-corrupt' 为真）.
用 `boundp' 守卫：老版本状态库没有这个变量时按「未损坏」处理。"
  (and (boundp 'seshat-state--load-was-corrupt)
       (symbol-value 'seshat-state--load-was-corrupt)
       t))

(defun seshat-status-summary ()
  "返回 Seshat 状态的汇总 plist（**只读快照函数**）.

「只读快照」的确切含义：**无写副作用**——不写文件、不发请求、不 `message'、
不建定时器；但**会读**状态库（`seshat-state-entries' 等）、批注队列与本地文件
系统。因此它**不是**纯函数：同样的零参调用在不同时刻可以得到不同结果。

**为什么不做成纯函数**（例如显式传入 `(entries roots runtime pending)' 快照）：
唯一调用方就是启动汇总（`seshat-status-report' 与模式行），它们要的正是「此刻
的全局状态」；把快照做成入参只会让每个调用点各写一遍取数代码，多出几处可以
忘记刷新的地方，换不来任何可测性收益。取而代之的保证是：**入参为空 → 结果只
取决于环境**，测试靠绑状态库/队列/临时目录来控制输入（见
`seshat-status-test' 的用例）。

字段固定为：

  `:books'                书库总数（ondemand 根下的活条目数）
  `:downloaded'           其中本地文件确实存在的条数
  `:dirty'                待同步笔记数（脏 uid 数）
  `:pending-annotations'  待同步批注数；批注队列模块缺席时为 nil
  `:last-sync-at'         上次同步的 UNIX 秒；无记录时为 nil
  `:last-sync-result'     `success' / `failed' / nil
  `:last-sync-error'      上次失败的错误文本或 nil
  `:corrupt'             状态库本次加载是否损坏（布尔）
  `:never-synced'        是否从未建立过索引（布尔，与 `:corrupt' 是两个分支）

零网络：全部数据来自状态库、离线队列与本地文件系统。"
  (let* ((roots (ignore-errors (seshat-state-roots)))
         (runtime (ignore-errors (seshat-state-runtime)))
         (entries (ignore-errors (seshat-state-entries)))
         (ondemand (seshat-status--ondemand-roots roots))
         (books 0)
         (downloaded 0))
    (dolist (cell entries)
      (let ((entry (cdr cell)))
        (when (member (plist-get entry :root) ondemand)
          (setq books (1+ books))
          (when (seshat-status--downloaded-p entry)
            (setq downloaded (1+ downloaded))))))
    (list :books books
          :downloaded downloaded
          :dirty (or (ignore-errors (length (seshat-state-dirty-uids))) 0)
          :pending-annotations (seshat-status--pending-annotations)
          :last-sync-at (plist-get runtime :last-sync-at)
          :last-sync-result (plist-get runtime :last-sync-result)
          :last-sync-error (plist-get runtime :last-sync-error)
          :corrupt (seshat-status--corrupt-p)
          :never-synced (and (null roots) (null runtime) t))))

;;; 一行文案

(defun seshat-status--relative-time (seconds)
  "把 SECONDS 秒转成中文相对时间：\"刚刚\" / \"Nm 前\" / \"Nh 前\" / \"Nd 前\".
自己实现而不依赖 `timeago' 之类的外部包：启动路径不应为此多一条依赖，而
且只需要四个档位。负数（时钟回拨）按 0 处理。"
  (let ((s (max 0 (truncate seconds))))
    (cond
     ((< s 60) "刚刚")
     ((< s 3600) (format "%dm 前" (/ s 60)))
     ((< s 86400) (format "%dh 前" (/ s 3600)))
     (t (format "%dd 前" (/ s 86400))))))

(defun seshat-status--last-sync-text (summary)
  "根据 SUMMARY 的 `:last-sync-at' / `:last-sync-result' 生成「上次同步」片段.
形如 \"2h 前失败\" / \"3d 前成功\"；无时间戳时返回 \"尚未同步\"。结果字段
缺席（nil）时只写相对时间。"
  (let ((at (plist-get summary :last-sync-at))
        (result (plist-get summary :last-sync-result)))
    (if (null at)
        "尚未同步"
      (concat (seshat-status--relative-time (- (float-time) at))
              (cond ((eq result 'success) "成功")
                    ((eq result 'failed) "失败")
                    (t ""))))))

(defun seshat-status--log-has-problems-p ()
  "判断 `*Seshat Log*' 里是否有 warn / error 级记录.
buffer 未创建（从未记过日志）时返回 nil，文案据此省略「查看日志」尾段。"
  (when-let* ((buffer (get-buffer seshat-log--buffer-name)))
    (with-current-buffer buffer
      (and (string-match-p "\\[WARN\\]\\|\\[ERROR\\]" (buffer-string)) t))))

(defun seshat-status--notify-text (summary)
  "把汇总 plist SUMMARY 拼成一行中文文案（纯函数，不 `message'）.
段落按有无省略，顺序为：状态库异常 → 尚未建立索引 → 书库 → 待同步 →
上次同步 → 查看日志。段间用 \" · \" 分隔，整体前缀 \"Seshat: \"。"
  (let* ((books (or (plist-get summary :books) 0))
         (downloaded (or (plist-get summary :downloaded) 0))
         (dirty (or (plist-get summary :dirty) 0))
         (pending (plist-get summary :pending-annotations))
         (corrupt (plist-get summary :corrupt))
         (never (plist-get summary :never-synced))
         (segments nil))
    (when corrupt
      (push "⚠ 状态库异常（已备份为 .bak）" segments))
    (when never
      (push "尚未建立索引，运行 M-x seshat-sync-now" segments))
    (when (> books 0)
      (push (format "书库 %d 本（本地 %d）" books downloaded) segments))
    ;; 「待同步」段：笔记与批注都为零（或批注不可用）时整段省略；只有一个
    ;; 非零时只写那一个。
    (let ((note-text (and (> dirty 0) (format "笔记 %d" dirty)))
          (annotation-text (and (integerp pending) (> pending 0)
                                (format "批注 %d" pending))))
      (cond
       ((and note-text annotation-text)
        (push (format "待同步 %s / %s" note-text annotation-text) segments))
       (note-text
        (push (format "待同步 %s" note-text) segments))
       (annotation-text
        (push (format "待同步 %s" annotation-text) segments))))
    ;; 从未建立索引时已有置顶提示，不再重复「尚未同步」。
    (unless never
      (push (format "上次同步 %s" (seshat-status--last-sync-text summary))
            segments))
    (when (seshat-status--log-has-problems-p)
      (push "M-x seshat-show-log 查看" segments))
    (concat "Seshat: " (mapconcat #'identity (nreverse segments) " · "))))

(defun seshat-status-notify (&optional summary)
  "在 echo area 输出一行 Seshat 状态汇总.
SUMMARY 为 nil 时内部调用 `seshat-status-summary'。这是本模块**唯一**允许
`message' 的地方：它只在启动后延迟执行一次（或用户显式调用），不会刷屏。
返回输出的一行文本。"
  (let* ((summary (or summary (seshat-status-summary)))
         (text (seshat-status--notify-text summary)))
    (message "%s" text)
    text))

;;; 详情 buffer

(defun seshat-status--log-tail ()
  "返回 `*Seshat Log*' 末尾 `seshat-status--log-tail-lines' 行的列表.
buffer 不存在（从未记日志）时返回 nil。"
  (when-let* ((buffer (get-buffer seshat-log--buffer-name)))
    (with-current-buffer buffer
      (let* ((lines (split-string (buffer-string) "\n" t))
             (len (length lines)))
        (nthcdr (max 0 (- len seshat-status--log-tail-lines)) lines)))))

(defun seshat-status--render ()
  "在当前 buffer（`*Seshat Status*'）里重算并重绘全部内容.
分节：书库 / 同步 / 待同步 / 状态库 / 日志摘要。只读 buffer，靠
`inhibit-read-only' 临时放开写入。"
  (let ((inhibit-read-only t)
        (summary (seshat-status-summary)))
    (erase-buffer)
    (insert "Seshat 状态\n===========\n\n")
    ;; 书库
    (let ((books (or (plist-get summary :books) 0))
          (downloaded (or (plist-get summary :downloaded) 0)))
      (insert "书库\n")
      (insert (format "  总数：%d\n" books))
      (insert (format "  已下载：%d\n" downloaded))
      (insert (format "  未下载：%d\n\n" (max 0 (- books downloaded)))))
    ;; 同步
    (insert "同步\n")
    (if (plist-get summary :never-synced)
        (insert "  上次同步：尚未建立索引（运行 M-x seshat-sync-now）\n")
      (insert (format "  上次同步：%s\n"
                      (seshat-status--last-sync-text summary))))
    (insert (format "  结果：%s\n"
                    (let ((result (plist-get summary :last-sync-result)))
                      (cond ((eq result 'success) "成功")
                            ((eq result 'failed) "失败")
                            (t "无记录")))))
    (insert (format "  错误：%s\n\n"
                    (or (plist-get summary :last-sync-error) "无")))
    ;; 待同步
    (insert "待同步\n")
    (insert (format "  笔记：%d\n" (or (plist-get summary :dirty) 0)))
    (insert (format "  批注：%s\n\n"
                    (let ((pending (plist-get summary :pending-annotations)))
                      (if (integerp pending)
                          (number-to-string pending)
                        "不可用（批注队列模块未加载）"))))
    ;; 状态库
    (insert "状态库\n")
    (insert (format "  文件：%s\n" seshat-state-file))
    (insert (format "  版本：%d\n" seshat-state-version))
    (insert (format "  损坏：%s\n\n"
                    (if (plist-get summary :corrupt)
                        "是（已备份为 .bak）"
                      "否")))
    ;; 日志摘要
    (insert (format "日志摘要（末 %d 行）\n" seshat-status--log-tail-lines))
    (let ((tail (seshat-status--log-tail)))
      (if tail
          (dolist (line tail)
            (insert (format "  %s\n" line)))
        (insert "  （无日志）\n")))
    nil))

(defun seshat-status--refresh ()
  "重算并重绘 `*Seshat Status*'（详情 buffer 里 `g' 绑定的命令）。"
  (interactive)
  (when-let* ((buffer (get-buffer seshat-status--buffer-name)))
    (with-current-buffer buffer
      (seshat-status--render)))
  nil)

(defvar seshat-status-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'seshat-status--refresh)
    (define-key map (kbd "L") #'seshat-show-log)
    (define-key map (kbd "q") #'quit-window)
    map)
  "`*Seshat Status*' buffer 的局部按键映射（继承 `special-mode-map'）.")

(defun seshat-status ()
  "打开（或刷新）`*Seshat Status*' 详情 buffer 并返回该 buffer.
buffer 用 `special-mode'（只读）；`g' 重算刷新、`L' 打开 `*Seshat Log*'、
`q' 关闭。"
  (interactive)
  (let ((buffer (get-buffer-create seshat-status--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (use-local-map seshat-status-mode-map)
      (seshat-status--render))
    (pop-to-buffer buffer)
    buffer))

;;; 启动挂载

(defun seshat-status-startup ()
  "启动汇总入口，供 `emacs-startup-hook' 调用.
`seshat-status-startup-notify' 为 nil 时什么也不做；否则只注册一个
`run-at-time' 延迟定时器（延迟 `seshat-status-startup-delay' 秒），把计算
与 `message' 都推到延迟之后，并用 `ignore-errors' 兜住——汇总失败绝不能
影响 Emacs 启动。"
  (when seshat-status-startup-notify
    (run-at-time seshat-status-startup-delay nil
                 (lambda ()
                   (ignore-errors (seshat-status-notify)))))
  nil)

(defun seshat-status-uninstall ()
  "从 `emacs-startup-hook' 移除启动汇总（幂等）.
供测试清理与用户手动关闭用；已移除时是安全的 no-op。"
  (interactive)
  (remove-hook 'emacs-startup-hook #'seshat-status-startup)
  nil)

(add-hook 'emacs-startup-hook #'seshat-status-startup)

(provide 'seshat-status)

;;; seshat-status.el ends here
