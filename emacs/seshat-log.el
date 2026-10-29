;;; seshat-log.el --- 分级日志与静默层 -*- lexical-binding: t; -*-

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

;; 本模块是 seshat 全项目**唯一的日志出口**，解决一个具体矛盾：自动路径
;; （定时器同步、书架渲染、打开文档、批注队列）不能往 echo area 打印——
;; 用户没在等结果，刷屏只会打断输入；但完全不报又会让故障彻底不可见。
;;
;; 三件事必须说清：
;;
;; 1. **为什么存在**：自动路径一律走 `seshat-log'，默认（`seshat-log-quiet'
;;    为 t）不写 echo area，只追加到 `*Seshat Log*'。用户何时被告知？
;;    靠启动后**一次**汇总（`seshat-status'）与用户主动
;;    `M-x seshat-show-log' 查看，而不是靠逐条 message。
;; 2. **quiet 语义与 error 例外**：`seshat-log-quiet' 为 t 时**不** message；
;;    **唯一例外**是 `error' 级——真正的错误必须可见，且错误是低频事件，
;;    不会「一直打印」。`seshat-log-quiet' 设 nil 则恢复全部 echo 输出
;;    （前缀 `Seshat: '），这是静默化出问题时的回退开关。
;; 3. **ring 上限与惰性创建**：日志 buffer 只保留最近
;;    `seshat-log-max-lines' 行（默认 2000），超出后从**头部**裁剪，因此最新
;;    写入的一定在。buffer 惰性创建：加载本模块**不**建 buffer，首次
;;    `seshat-log' 或 `seshat-show-log' 时才 `get-buffer-create'。
;;
;; 零依赖：不 require 任何 seshat 模块、也不 require 第三方包，避免日志层被
;; 依赖图拖住（`seshat-reader/**' 的 vendored 边界尤其不能反向依赖）。
;;
;; 健壮性不变量：`seshat-log' **绝不抛错**。它跑在自动路径里，抛错会把一次
;; 「记日志失败」升级成「同步 / 渲染失败」——那是最坏的因果倒置。

;;; Code:

(defgroup seshat-log nil
  "Seshat 的分级日志与静默层。"
  :group 'tools
  :prefix "seshat-log-")

(defcustom seshat-log-level 'info
  "写入 `*Seshat Log*' 的最低级别.
取值为 `debug' / `info' / `warn' / `error'，权重依次 0/1/2/3；
`seshat-log' 只在调用级别的权重 ≥ 本值权重时才写 buffer。未知级别
按 `info' 处理（权重 1）。"
  :type '(choice (const :tag "全部（debug）" debug)
                 (const :tag "信息（info）" info)
                 (const :tag "警告（warn）" warn)
                 (const :tag "仅错误（error）" error))
  :group 'seshat-log)

(defcustom seshat-log-quiet t
  "非 nil 时 `seshat-log' 不写 echo area（`error' 级例外）.
为 t（默认）时日志只进 `*Seshat Log*'；`error' 级仍然 message——真正的
错误必须可见，且它不会「一直打印」。设 nil 则恢复全部 echo 输出（前缀
`Seshat: '），用于排障或回退到静默化之前的行为。"
  :type 'boolean
  :group 'seshat-log)

(defcustom seshat-log-max-lines 2000
  "`*Seshat Log*' 保留的最大行数.
超出后从 buffer **头部**裁剪，因此最新写入的行一定保留。"
  :type 'integer
  :group 'seshat-log)

(defconst seshat-log--buffer-name "*Seshat Log*"
  "日志 buffer 的名字.")

(defconst seshat-log--levels '((debug . 0) (info . 1) (warn . 2) (error . 3))
  "级别符号到权重数值的映射（数值越大越严重）.")

(defconst seshat-log--echo-prefix "Seshat: "
  "写 echo area 时的前缀.")

(defun seshat-log--level-value (level)
  "返回 LEVEL 的权重数值.
未知 LEVEL 按 `info' 处理，返回 1。"
  (or (alist-get level seshat-log--levels)
      (alist-get 'info seshat-log--levels)))

(defun seshat-log--threshold ()
  "返回当前 `seshat-log-level' 的权重数值。"
  (seshat-log--level-value seshat-log-level))

(defun seshat-log--line-count ()
  "返回当前 buffer 的逻辑行数（末尾换行不额外算一行）。"
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (not (eobp))
        (setq count (1+ count))
        (forward-line 1))
      count)))

(defun seshat-log--trim ()
  "按 `seshat-log-max-lines' 从 buffer 头部裁掉多余的行.
调用方必须已把 `inhibit-read-only' 绑为 t——`special-mode' 下 buffer 是
只读的，写日志（含裁剪）都要绕过只读检查。"
  (let ((total (seshat-log--line-count)))
    (when (> total seshat-log-max-lines)
      (goto-char (point-min))
      (forward-line (- total seshat-log-max-lines))
      (delete-region (point-min) (point)))))

(defun seshat-log--append (level text)
  "把一条 LEVEL 级日志 TEXT 追加到日志 buffer 末尾，并按上限裁剪.
LEVEL 只用于行首标签，级别过滤由调用方完成。行格式为
`HH:MM:SS [LEVEL] 文本'。"
  (with-current-buffer (get-buffer-create seshat-log--buffer-name)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format-time-string "%H:%M:%S")
                " [" (upcase (symbol-name level)) "] " text "\n")
        (seshat-log--trim)))))

(defun seshat-log--log-1 (level format-string args)
  "`seshat-log' 的实现体：LEVEL、FORMAT-STRING、ARGS（列表）.
允许抛错，由 `seshat-log' 兜住。返回 nil。"
  (let* ((value (seshat-log--level-value level))
         (text (condition-case err
                   (apply #'format format-string args)
                 (error (format "日志格式化失败：%S" err)))))
    (when (>= value (seshat-log--threshold))
      ;; echo area：quiet 时只有 error 级例外；非 quiet 时按级别过滤后全部输出。
      (when (or (not seshat-log-quiet)
                (>= value (seshat-log--level-value 'error)))
        (message "%s%s" seshat-log--echo-prefix text))
      ;; buffer 写入失败只能静默吞掉——这里再抛错就等于「记日志把主流程搞挂」。
      (condition-case nil
          (seshat-log--append level text)
        (error nil)))
    nil))

(defun seshat-log (level format-string &rest args)
  "写一条 LEVEL 级日志，格式串 FORMAT-STRING 与 ARGS 同 `format'.
LEVEL 取 `debug' / `info' / `warn' / `error'（权重 0/1/2/3），未知级别按
`info' 处理。

**级别过滤**：只有 LEVEL 的权重 ≥ `seshat-log-level' 的权重时才写
`*Seshat Log*'。

**echo area 规则**：`seshat-log-quiet' 为 t（默认）时不 message，唯一例外
是 `error' 级（安全阀：真正的错误必须可见，且它不会一直打印）；
`seshat-log-quiet' 为 nil 时，LEVEL 不低于阈值就 message，前缀
`Seshat: '。

**buffer 写入**：每行形如 `HH:MM:SS [LEVEL] 文本'（时间用
`format-time-string' 的 \"%H:%M:%S\"），追加到末尾；写完后按
`seshat-log-max-lines' 从头部裁剪多余行。buffer 惰性创建（首次调用才建）。

**绝不抛错**：本函数内任何异常（格式化失败、buffer 写入失败）都不上抛，
因为它是被自动路径调用的基础设施。恒返回 nil。"
  (condition-case nil
      (seshat-log--log-1 level format-string args)
    (error nil))
  nil)

(defun seshat-show-log ()
  "打开（或复用）`*Seshat Log*' buffer 并显示.
buffer 用 `special-mode'（只读，`q' 关闭）；首次调用时才创建。返回该
buffer。"
  (interactive)
  (let ((buffer (get-buffer-create seshat-log--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    (display-buffer buffer)
    buffer))

(defun seshat-log-clear ()
  "清空 `*Seshat Log*' buffer.
buffer 尚未创建时什么也不做（保持惰性，不因清空而创建）。返回 nil。"
  (interactive)
  (when-let* ((buffer (get-buffer seshat-log--buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))))
  nil)

(provide 'seshat-log)

;;; seshat-log.el ends here
