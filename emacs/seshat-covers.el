;;; seshat-covers.el --- 封面三级回退（本地缓存，零网络） -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: data, tools
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

;; 本模块把 `(uid file)' 变成**一个本地封面文件路径**，供书架显示。它只做
;; 「取封面」这一件事，**不碰 image**（不 `create-image'、不 display）——那是
;; 书架（`seshat-library'）的职责，分离之后本模块在 `emacs --batch -Q' 下
;; 无需图形环境即可完整测试。
;;
;; **零网络**：只读本地文件、只调本地子进程（`unzip' / `mutool'）。依赖方向
;; 见 ADR 0006：`seshat-covers' 禁止 require `seshat-rest' / `seshat-sync' /
;; `seshat-library' / `seshat-reader'。
;;
;; 三级回退（`seshat-covers-extract'）：
;;
;;   L1 EPUB  → `unzip -Z1' 列条目 + 文件名启发式选封面 + `unzip -p' 取原始字节
;;   L2 PDF   → `mutool draw -r 24 -o <tmp>.png <file> 1' 栅格化首页
;;   L3 占位  → 返回 nil（书架自行画「书名首字 + face」占位）
;;
;; 三条不变量（改动本模块时必须保持）：
;;
;; 1. **失败只降级、绝不抛错**：所有子进程调用与文件操作都经 `condition-case'
;;    兜住，失败只 `seshat-log' 一条 warn。封面是装饰，不能把书架打开搞挂。
;; 2. **负缓存避免重复试探**：`<uid>.none'（空文件）表示「已尝试且确定性
;;    失败」，再次 `seshat-covers-extract' 立即返回 nil，不再起子进程。
;;    代价是**装上新工具后不会自动重试**——需 `M-x seshat-covers-clear-cache'。
;; 3. **串行 + 限速 + 有界**：外部命令走串行 idle 队列（每次 1 本，两本之间
;;    间隔 `seshat-covers-queue-delay'），单次超时 `seshat-covers-timeout'，
;;    子进程输出**流式**受限（超过 `seshat-covers-max-bytes' 立即杀进程，见
;;    `seshat-covers--run'），源图超过上限不落盘。合起来保证「打开一个有 200
;;    本书的书架」不会一次拉起 200 个子进程、也不会把大图（或解压炸弹）读进
;;    内存。
;; 4. **连续失败熔断**：连续 `seshat-covers--failure-threshold' 次提取失败即暂停
;;    队列 `seshat-covers--cooldown-seconds' 秒（成功一次即清零）。没有它，
;;    「`unzip' 没装」这种整批失败会让一页 30 本各白等一次超时。
;;
;; 惰性：加载本模块不创建 `seshat-covers-dir'、不探测 `unzip' / `mutool'；
;; 目录只在**真正写缓存文件**（图片或负缓存）时才建。
;;
;; uid 是安全边界：它会被拼进文件名，因此必须是 26 位 Crockford Base32
;; （`seshat-covers--uid-valid-p'），否则 `/`、`..` 之类字符能构造路径穿越。

;;; Code:

(require 'cl-lib)
(require 'seshat-log)

(defgroup seshat-covers nil
  "封面三级回退与本地缓存."
  :group 'data
  :prefix "seshat-covers-")

(defcustom seshat-covers-dir (expand-file-name "~/.cache/seshat/covers/")
  "封面缓存目录.
目录**惰性创建**：只有真正写缓存文件（图片或负缓存）时才 `make-directory'，
因此只读路径（`seshat-covers-path' / `-cached' / `-failed-p'）不会建目录。"
  :type 'directory
  :group 'seshat-covers)

(defcustom seshat-covers-timeout 3
  "单次外部命令（`unzip' / `mutool'）的超时秒数.
超时即 `delete-process' 并按失败降级：一个挂住的 `unzip' 不能无限期占住
Emacs 主线程。用 `accept-process-output' 轮询实现——同步的 `call-process'
无法超时，故本模块不用它。

**默认值 3 秒（不是 10）**：队列是在 idle 定时器里**同步**跑的，一页 30 本
最坏就是 30 × 超时。10 秒的默认值下最坏 5 分钟无响应，而封面只是装饰——3 秒
足够任何正常的 `unzip -p' / `mutool draw -r 24' 跑完（低分辨率栅格化一本
普通 PDF 在百毫秒量级），超时的那本按失败降级即可。"
  :type 'integer
  :group 'seshat-covers)

(defcustom seshat-covers-max-bytes (* 4 1024 1024)
  "源图字节数上限；nil 表示不限.
超过上限的源图**不落盘**，按失败降级（最终写负缓存）：一张 20 MiB 的扫描
封面既没必要显示，也不该读进内存。设 0 等价于「所有封面都走占位」。

本值同时是 `unzip -p' 的**流式输出上限**（见 `seshat-covers--run'）：子进程
输出一旦超过它就当场 `delete-process'，因此内存峰值不会超过「上限 + 一个
chunk」，与解压后的真实体积无关——这是防 deflate 炸弹 OOM 的那道闸。"
  :type '(choice (const :tag "不限" nil) integer)
  :group 'seshat-covers)

(defcustom seshat-covers-queue-delay 0.2
  "串行队列两本封面之间的空闲间隔秒数.
用 idle 定时器实现，不抢用户输入；每次只处理 1 本。"
  :type 'number
  :group 'seshat-covers)

;;; 常量

(defconst seshat-covers--uid-regexp "\\`[0-9A-HJKMNP-TV-Z]\\{26\\}\\'"
  "封面缓存 uid 的权威形态：26 位 Crockford Base32（排除 I / L / O / U）.
与 `seshat-library--uid-valid-p' **同口径**，改动须同步（本模块不 require
`seshat-library'，避免依赖图出现环，故自带一份私有谓词）。匹配时必须绑
`case-fold-search' 为 nil。")

(defconst seshat-covers--extensions '("png" "jpg" "jpeg" "gif" "webp")
  "允许的封面缓存扩展名.
扩展名由源图**字节头嗅探**得出（见 `seshat-covers--sniff-ext'），不靠文件名
后缀——EPUB 内部的条目名常常没有后缀或后缀与内容不符。")

(defconst seshat-covers--negative-suffix ".none"
  "负缓存文件的后缀（空文件）.
存在即表示「这本已尝试且确定性失败」，`seshat-covers-extract' 直接返回 nil。")

(defconst seshat-covers--listing-max-bytes (* 1024 1024)
  "`unzip -Z1'（列条目）的 stdout 上限：1 MiB.
条目列表是纯文本，一万个条目也不过几百 KB；给一个**独立**的较小上限而不是
复用 `seshat-covers-max-bytes'，是为了让「清单被构造成超长」也无法把内存拖垮
（4 MiB 的清单本身就说明这不是一个正常 EPUB）。超限按 L1 失败降级。")

(defconst seshat-covers--failure-threshold 5
  "连续失败多少次触发熔断（暂停队列 `seshat-covers--cooldown-seconds' 秒）.
判据是**连续**：成功一次即清零。5 次足以区分「这本书有问题」与「整批都失败」
（例如 `unzip' 根本没装、或文件系统不可读）——后者每本都要白等一次超时，
30 本一页就是 90 秒的卡顿，熔断让代价止于 5 次。")

(defconst seshat-covers--cooldown-seconds 60
  "熔断后的冷却秒数；冷却期内 `seshat-covers--pump' 直接返回.
60 秒是「用户装了工具 / 换了书之后再回来」与「不要在坏环境里空转」之间的
折中：冷却结束后计数清零，队列照常继续。")

;;; 模块级状态（串行队列）

(defvar seshat-covers--queue nil
  "串行队列（FIFO），元素为 `(UID FILE . CALLBACK)'.
模块级而非 buffer-local：封面缓存跨 buffer 共享，且限速必须是全局的——两个
书架 buffer 各自排队等于把并发翻倍。")

(defvar seshat-covers--timer nil
  "当前武装的 idle 定时器，或 nil（未武装）.")

(defvar seshat-covers--running nil
  "非 nil 表示 `seshat-covers--pump' 正在处理队首条目（防重入）.")

(defvar seshat-covers--active-uid nil
  "正在处理的 uid，或 nil.
与 `seshat-covers--queue' 一起构成「去重」判据：同一个 uid 正在处理时再次入队
会被丢弃，避免同一本书被反复提取。")

(defvar seshat-covers--consecutive-failures 0
  "连续提取失败的次数（成功一次即清零）.
用于熔断：连续 `seshat-covers--failure-threshold' 次失败说明环境整体不可用
（`unzip' 未安装、文件系统不可读……），继续逐本白等超时只会让书架卡死。")

(defvar seshat-covers--cooldown-until nil
  "熔断冷却的截止时刻（`float-time' 口径），nil 表示不在冷却期.
冷却期内 `seshat-covers--pump' 直接返回（不处理队首），但会按剩余时间重新武装
定时器，因此冷却结束后队列能自己恢复，不需要用户手动触发。")

;;; uid 与路径

(defun seshat-covers--uid-valid-p (uid)
  "判断 UID 是否形如 26 位 Crockford Base32（**大小写敏感**）.
与 `seshat-library--uid-valid-p' 同口径，改动须同步。UID 会被拼进缓存文件名，
因此形态校验是安全边界：不校验就能用 `/`、`..` 之类字符穿越出
`seshat-covers-dir'。

必须绑 `case-fold-search' 为 nil——`string-match-p' 默认大小写不敏感，`[A-Z]'
会连小写字母一起匹配，小写 uid 会被误判合法。UID 非字符串时返回 nil。"
  (and (stringp uid)
       (let ((case-fold-search nil))
         (string-match-p seshat-covers--uid-regexp uid))))

(defun seshat-covers--dir ()
  "返回 `seshat-covers-dir' 的绝对路径（带结尾斜杠），不创建目录。"
  (file-name-as-directory (expand-file-name seshat-covers-dir)))

(defun seshat-covers--ensure-dir ()
  "确保 `seshat-covers-dir' 存在并返回其绝对路径（带结尾斜杠）.
**只在写缓存文件前调用**——这是本模块唯一的建目录点，惰性由此保证。"
  (let ((dir (seshat-covers--dir)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun seshat-covers-path (uid)
  "返回 UID 的缓存**基路径** `<dir>/<uid>'（不含扩展名）.
实际文件由 `seshat-covers-cached' 按 `directory-files' 匹配 `<uid>.*' 得到，
调用方不必猜扩展名（扩展名来自字节嗅探，调用方无从预知）。

UID 形态非法时返回 nil 并记一条 warn：不合法 uid 一律不拼进路径（防穿越）。"
  (cond
   ((not (seshat-covers--uid-valid-p uid))
    (seshat-log 'warn "封面：uid 形态非法，已忽略：%S" uid)
    nil)
   (t (expand-file-name uid (seshat-covers--dir)))))

(defun seshat-covers--cache-name-regexp (uid)
  "返回匹配 UID 的缓存文件名（不含目录）的正则表达式."
  (concat "\\`" (regexp-quote uid) "\\.\\(?:"
          (mapconcat #'identity seshat-covers--extensions "\\|")
          "\\)\\'"))

(defun seshat-covers-cached (uid)
  "返回 UID 已存在的封面缓存文件绝对路径，或 nil（**不生成**任何文件）.
匹配 `<dir>/<uid>.<ext>'（ext ∈ `seshat-covers--extensions'）；负缓存
`<uid>.none' 不算命中。目录不存在、uid 非法、无匹配文件一律返回 nil。"
  (when (seshat-covers--uid-valid-p uid)
    (let ((dir (seshat-covers--dir)))
      (when (file-directory-p dir)
        (let ((name-re (seshat-covers--cache-name-regexp uid))
              (case-fold-search nil))
          (car (cl-remove-if-not
                (lambda (file)
                  (string-match-p name-re (file-name-nondirectory file)))
                (directory-files dir t))))))))

(defun seshat-covers-failed-p (uid)
  "判断 UID 的负缓存是否存在（t / nil）.
负缓存是 `<dir>/<uid>.none' 空文件，表示「已尝试且确定性失败」。uid 非法时
返回 nil（非法 uid 本来就不会有缓存文件）。"
  (and (seshat-covers--uid-valid-p uid)
       (file-exists-p (expand-file-name
                       (concat uid seshat-covers--negative-suffix)
                       (seshat-covers--dir)))))

;;; 字节嗅探与写盘

(defun seshat-covers--sniff-ext (bytes)
  "按 BYTES 的头几个字节嗅探图片扩展名，识别不出返回 nil.
返回 \"png\" / \"jpg\" / \"gif\" / \"webp\"（JPEG 一律归一为 \"jpg\"）。
不看文件名后缀：EPUB 内部条目常无后缀，`unzip -p' 出来的字节才可信。"
  (cond
   ((not (stringp bytes)) nil)
   ((string-prefix-p "\x89PNG\r\n\x1a\n" bytes) "png")
   ((string-prefix-p "\xff\xd8\xff" bytes) "jpg")
   ((string-prefix-p "GIF8" bytes) "gif")
   ((and (>= (length bytes) 12)
         (string= (substring bytes 0 4) "RIFF")
         (string= (substring bytes 8 12) "WEBP"))
    "webp")
   (t nil)))

(defun seshat-covers--too-big-p (bytes)
  "判断 BYTES（内存里的字节串）是否超过 `seshat-covers-max-bytes'（nil 不限）.
只在**字节已经在内存里**时用；能先看磁盘大小时优先 `--file-too-big-p'，否则
判断之前内存峰值就已经发生了。"
  (and (integerp seshat-covers-max-bytes)
       (> (string-bytes bytes) seshat-covers-max-bytes)))

(defun seshat-covers--file-too-big-p (file)
  "判断 FILE 的**磁盘大小**是否超过 `seshat-covers-max-bytes'（nil 不限）.
`mutool draw -o FILE' 把输出写进文件而不是 stdout，因此没有流式上限可用；
但读它之前可以先 `file-attributes' 看大小——先看大小再决定读不读，内存峰值才
与「上限」挂钩，而不是与输出文件的实际体积挂钩。FILE 不存在时返回 nil。"
  (and (integerp seshat-covers-max-bytes)
       (let ((attrs (file-attributes file)))
         (and attrs (> (or (file-attribute-size attrs) 0)
                       seshat-covers-max-bytes)))))

(defun seshat-covers--write-bytes (target bytes)
  "把 BYTES 原样写入 TARGET（同目录临时文件 + 原子 rename）.
失败返回 nil（不抛错）：写到一半崩溃不会留下半截图片，正常结束后目录里只有
最终文件。"
  (condition-case err
      (let* ((dir (file-name-directory target))
             (tmp (make-temp-file (expand-file-name "seshat-cover-" dir)
                                  nil ".part")))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'no-conversion))
                (write-region bytes nil tmp nil 'silent))
              (rename-file tmp target t)
              target)
          (when (file-exists-p tmp)
            (ignore-errors (delete-file tmp)))))
    (error
     (seshat-log 'warn "封面：写缓存失败（%s）：%S" target err)
     nil)))

(defun seshat-covers--write-image (uid bytes)
  "把 BYTES 作为 UID 的封面落盘，返回最终路径或 nil.
扩展名由 `seshat-covers--sniff-ext' 决定；嗅探失败（不是已知图片格式）返回
nil，让调用方继续降级。"
  (let ((ext (seshat-covers--sniff-ext bytes)))
    (when ext
      (let ((dir (seshat-covers--ensure-dir)))
        (seshat-covers--write-bytes
         (expand-file-name (concat uid "." ext) dir)
         bytes)))))

(defun seshat-covers--mark-failed (uid)
  "为 UID 写负缓存 `<uid>.none'（空文件）；失败静默忽略.
写负缓存会创建 `seshat-covers-dir'——这是「惰性」的唯一例外，也是刻意的：
不写负缓存，每次书架渲染都会重新探测一次注定失败的书。"
  (condition-case err
      (let ((dir (seshat-covers--ensure-dir)))
        (let ((coding-system-for-write 'no-conversion))
          (write-region "" nil (expand-file-name
                                (concat uid seshat-covers--negative-suffix)
                                dir)
                        nil 'silent))
        t)
    (error
     (seshat-log 'warn "封面：写负缓存失败（%s）：%S" uid err)
     nil)))

;;; 子进程执行（带超时）

(defun seshat-covers--stderr-summary (buffer)
  "返回 BUFFER 内容的单行摘要（最多 200 字节），用于日志.
子进程 stderr 常是多行且可能极长；日志里只留能定位问题的一小段。"
  (let* ((text (string-trim (with-current-buffer buffer (buffer-string)))))
    (if (> (length text) 200)
        (concat (substring text 0 200) "…")
      text)))

(defun seshat-covers--run (command &optional max-output)
  "同步执行 COMMAND（字符串列表）并返回 `(STATUS . OUTPUT)'，超时返回 nil.
OUTPUT 是 **unibyte** 原始字节串（进程 `:coding` 设为 binary），因此二进制图片与
`unzip -Z1' 的文本列表走同一条通道；需要文本时调用方自行 decode。

MAX-OUTPUT 为 stdout 的**字节上限**（nil 表示不限）；越界时 `delete-process'
并返回特殊标记 `(:too-large t)'（**不是** cons，`car' 是 keyword）。

**为什么必须流式累计（安全，防 OOM）**：把子进程输出全部写进 buffer、事后再
`(buffer-string)' 判大小，内存峰值已经是**解压后**的体积——一个 deflate 炸弹
（压缩几十 KB、解压数 GB）能在 `seshat-covers-timeout' 秒内把 Emacs 撑到被内核
OOM 杀掉，用户未保存的笔记随之丢失。因此上限由 `:filter' **逐块**累计，越界
立即杀进程：内存峰值被钉在「上限 + 一个 chunk」，与真实解压体积无关。

**stdout / stderr 必须分开**：`unzip -p' 吐的是图片原始字节，若 stderr 混进同一
buffer（或让默认 sentinel 往 buffer 里插「Process ... finished」），落盘的图片就会
被尾部垃圾污染。因此 stdout 只经 `:filter' 进 buffer、stderr 进另一个 buffer，
且 `:sentinel' 设为 `ignore'（默认 sentinel 会写 buffer）。

**必须带超时**：同步 `call-process' 无法超时，一个挂住的 `unzip' 会永久占住
Emacs 主线程。这里用 `make-process' + `accept-process-output' 轮询，
超过 `seshat-covers-timeout' 秒就 `delete-process' 并返回 nil。

任何异常（命令不存在、进程创建失败）都在本函数内吞掉，只记 warn。"
  (condition-case err
      (let ((out-buf (generate-new-buffer " *seshat-covers-out*"))
            (err-buf (generate-new-buffer " *seshat-covers-err*"))
            (limit (and (integerp max-output) (> max-output 0) max-output))
            (seen 0)
            (too-large nil))
        ;; stdout buffer 必须是 **unibyte**：`:coding' 为 binary 时进程输出是原始
        ;; 字节，插进 multibyte buffer 会把 0x80-0xFF 转成 8 位字符，`buffer-string'
        ;; 回来就不再是字节串（落盘要靠编码系统兜一层）。unibyte buffer 让「读进来
        ;; 什么、还回去什么」严格成立，字节嗅探与写盘都不必再猜编码。
        (with-current-buffer out-buf
          (set-buffer-multibyte nil))
        (unwind-protect
            (let* ((proc (make-process
                          :name "seshat-covers"
                          :command command
                          :buffer out-buf
                          :stderr err-buf
                          :noquery t
                          :connection-type 'pipe
                          :sentinel #'ignore
                          :coding 'binary
                          ;; 流式累计 + 越界即杀：见 docstring「为什么必须流式」。
                          :filter (lambda (proc chunk)
                                    (setq seen (+ seen (length chunk)))
                                    (if (and limit (> seen limit))
                                        (progn
                                          (setq too-large t)
                                          (delete-process proc))
                                      (when (buffer-live-p out-buf)
                                        (with-current-buffer out-buf
                                          (insert chunk)))))))
                   (deadline (+ (float-time) seshat-covers-timeout)))
              (while (and (process-live-p proc) (< (float-time) deadline))
                (accept-process-output proc 0.05))
              (cond
               (too-large
                ;; 输出超限：进程已被杀，不再读 buffer（那里最多是「上限 + 一个
                ;; chunk」，但没必要为了日志再复制一遍）。
                (seshat-log 'warn "封面：命令输出超过 %s 字节上限，已中止：%S"
                            limit command)
                (list :too-large t))
               ((process-live-p proc)
                (delete-process proc)
                (seshat-log 'warn "封面：命令超时（%s 秒）：%S"
                            seshat-covers-timeout command)
                nil)
               ((zerop (process-exit-status proc))
                (cons (process-exit-status proc)
                      (with-current-buffer out-buf (buffer-string))))
               (t
                ;; 非零退出：把 stderr 摘要记进日志，否则「为什么失败」不可见。
                (seshat-log 'warn "封面：命令失败（退出码 %s）：%S；stderr：%s"
                            (process-exit-status proc) command
                            (seshat-covers--stderr-summary err-buf))
                (cons (process-exit-status proc)
                      (with-current-buffer out-buf (buffer-string))))))
          (kill-buffer out-buf)
          (kill-buffer err-buf)))
    (error
     (seshat-log 'warn "封面：命令执行异常：%S" err)
     nil)))

;;; L1：EPUB

(defun seshat-covers--entry-depth (entry)
  "返回 ENTRY 的路径层级（`/' 的个数），用于「取层级最浅的封面」。"
  (let ((count 0) (start 0))
    (while (string-match "/" entry start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun seshat-covers--pick-cover-entry (entries)
  "从 ENTRIES（EPUB 条目名列表）里按文件名启发式选封面条目，选不出返回 nil.
判据：扩展名 ∈ jpg / jpeg / png / gif / webp **且**路径含 `cover'（大小写
不敏感），且**条目名不以 `-' 开头**。多个候选取**路径层级最浅**的（`/' 最少），
再取字典序最小者——排序必须完全确定，否则同一本书在不同机器上缓存出不同文件。

**为什么额外拒绝 `-' 开头**：条目名来自压缩包内容，是**不可信输入**；它随后会
作为参数传给 `unzip -p'。命令侧已加 `--' 分隔符（见
`seshat-covers--epub-cover-bytes'），这里是纵深防御的第二道——两处都不依赖对方
成立，任一处单独正确就足以挡住「条目名被当成选项」。真实 EPUB 的封面条目名不会
以 `-' 开头，因此这条拒绝不损失可用性。

已知局限：这里**不解析 OPF**（`META-INF/container.xml' → `.opf' →
`cover-image' 属性），只用文件名启发式。代价是「封面文件名叫别的」的 EPUB
取不到（降级 L2/L3），收益是不引入 XML 解析依赖、实现可完全离线测试。"
  (let* ((case-fold-search t)
         (cands (cl-remove-if-not
                 (lambda (entry)
                   (and (stringp entry)
                        (not (string-prefix-p "-" entry))
                        (string-match-p
                         "\\.\\(?:jpe?g\\|png\\|gif\\|webp\\)\\'" entry)
                        (string-match-p "cover" entry)))
                 entries)))
    (car (sort cands
               (lambda (a b)
                 (let ((da (seshat-covers--entry-depth a))
                       (db (seshat-covers--entry-depth b)))
                   (if (/= da db) (< da db) (string< a b))))))))

(defun seshat-covers--epub-cover-bytes (file)
  "用 `unzip' 从 EPUB FILE 取封面原始字节；取不到返回 nil.
两步：`unzip -Z1' 列条目 → `seshat-covers--pick-cover-entry' 选条目 →
`unzip -p' 取该条目字节。任一步失败（含超时、退出码非零、输出为空）返回 nil。

**两条命令都带 `--' 分隔符**（`unzip -Z1 -- FILE' / `unzip -p -- FILE ENTRY'）：
FILE 恒为绝对路径（不可能以 `-' 开头），但**条目名**来自压缩包内容，可以被
构造成 `-x` 之类；没有 `--' 时参数解析依赖 unzip 的实现细节（本机 GNU unzip
恰好安全），加上 `--' 就把「条目名只当数据」变成显式保证。

**两步都传输出上限**（防 OOM，见 `seshat-covers--run' 的 MAX-OUTPUT）：
- 列条目用 `seshat-covers--listing-max-bytes'（1 MiB）——条目列表可以被构造成
  超长，没必要给它 4 MiB 的额度；
- 取封面用 `seshat-covers-max-bytes'——EPUB 内部的封面同样是可压缩的，一个
  deflate 炸弹能让 `unzip -p' 吐数 GB。
任一步超限时返回标记 `(:too-large t)'（调用方据此记一条 warn 后降级）。"
  (let ((listing (seshat-covers--run (list "unzip" "-Z1" "--" file)
                                     seshat-covers--listing-max-bytes)))
    (cond
     ((null listing) nil)
     ((eq (car-safe listing) :too-large) (list :too-large t))
     ((not (zerop (car listing))) nil)
     (t
      (let* ((text (decode-coding-string (cdr listing) 'utf-8))
             (entries (split-string text "[\r\n]+" t))
             (entry (seshat-covers--pick-cover-entry entries)))
        (when entry
          (let ((got (seshat-covers--run (list "unzip" "-p" "--" file entry)
                                         seshat-covers-max-bytes)))
            (cond
             ((null got) nil)
             ((eq (car-safe got) :too-large) (list :too-large t))
             ((and (zerop (car got)) (not (string-empty-p (cdr got))))
              (cdr got))
             (t nil)))))))))

(defun seshat-covers--try-epub (uid file)
  "L1：从 EPUB FILE 提取 UID 的封面，返回缓存路径或 nil.
先判扩展名再探 `unzip'（顺序有讲究：非 EPUB 不该白跑一次 `executable-find'）。

超限（`(:too-large t)'）按 L1 失败处理并记 warn：这本书的封面要么是炸弹、
要么大得没必要显示，两者都不该落盘。返回 nil 后 `seshat-covers-extract' 继续
降级 L2 / L3（最终写负缓存），**绝不抛错**。"
  (when (and (stringp file)
             (string-match-p "\\.epub\\'" file)
             (executable-find "unzip"))
    (let ((bytes (seshat-covers--epub-cover-bytes file)))
      (cond
       ((null bytes) nil)
       ;; 流式上限已在 `seshat-covers--run' 里记过 warn（含具体命令与上限），
       ;; 这里不重复记，只降级。
       ((eq (car-safe bytes) :too-large) nil)
       ((and (stringp bytes) (seshat-covers--too-big-p bytes))
        (seshat-log 'warn "封面：EPUB 内封面超过 %s 字节上限，已跳过（%s）"
                    seshat-covers-max-bytes uid)
        nil)
       (t (seshat-covers--write-image uid bytes))))))

;;; L2：PDF

(defun seshat-covers--pdf-cover-bytes (file)
  "用 `mutool draw' 把 PDF FILE 首页低分辨率栅格化，返回 PNG 字节或 nil.
`-r 24' 是刻意的低分辨率：封面只是缩略图，24 dpi 足够，也把内存与耗时压在
「一本书一次」的量级。临时文件放系统临时目录（不落 `seshat-covers-dir'），
避免失败路径污染缓存目录。

**读文件之前先看磁盘大小**（`seshat-covers--file-too-big-p'）：`mutool' 写的是
文件而不是 stdout，没有流式上限可用；若先 `insert-file-contents-literally' 再
判大小，内存峰值已经是输出体积——一个畸形的 PDF 可以让 `mutool' 输出上百 MB。
超限时返回 nil 并记 warn（调用方降级 L3 并写负缓存）。

命令里 `-o TMP' 之后、`FILE' 之前带 `--' 分隔符：FILE 恒为绝对路径，加 `--'
是为了让「文件名只当数据」不依赖 mutool 的参数解析实现（与 `unzip' 两条命令
同口径，见 `seshat-covers--epub-cover-bytes'）。"
  (let ((tmp (make-temp-file "seshat-cover-" nil ".png")))
    (unwind-protect
        (let ((res (seshat-covers--run (list "mutool" "draw" "-r" "24"
                                             "-o" tmp "--" file "1"))))
          (when (and res (not (eq (car-safe res) :too-large))
                     (zerop (car res)) (file-exists-p tmp))
            (if (seshat-covers--file-too-big-p tmp)
                (progn
                  (seshat-log 'warn
                              "封面：PDF 首页栅格化输出超过 %s 字节上限，已跳过（%s）"
                              seshat-covers-max-bytes file)
                  nil)
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally tmp)
                (let ((bytes (buffer-string)))
                  (unless (string-empty-p bytes) bytes))))))
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun seshat-covers--try-pdf (uid file)
  "L2：把 PDF FILE 首页栅格化成 UID 的封面，返回缓存路径或 nil。"
  (when (and (stringp file)
             (string-match-p "\\.pdf\\'" file)
             (executable-find "mutool"))
    (let ((bytes (seshat-covers--pdf-cover-bytes file)))
      (cond
       ((null bytes) nil)
       ((seshat-covers--too-big-p bytes)
        (seshat-log 'warn "封面：PDF 首页超过 %s 字节上限，已跳过（%s）"
                    seshat-covers-max-bytes uid)
        nil)
       (t (seshat-covers--write-image uid bytes))))))

;;; 三级回退入口

(defun seshat-covers-extract (uid file)
  "为 UID 从 FILE 提取封面并落盘，返回缓存路径或 nil（三级回退，同步执行）.
判定顺序（任一命中即返回）：

1. `seshat-covers-cached' 非 nil → 直接返回（零子进程、零探测）。
2. `seshat-covers-failed-p' 为 t → 返回 nil（**不重试**）。
3. L1 EPUB：`unzip -Z1' 列条目 + 文件名启发式选封面 + `unzip -p' 取字节，
   嗅探扩展名后原子落盘。
4. L2 PDF：`mutool draw -r 24' 栅格化首页，落盘为 `<uid>.png'。
5. L3 占位：返回 nil，并写负缓存 `<uid>.none'。

**负缓存写入条件**：走到第 5 步（L1 / L2 都不可用或都失败）才写，即「确定性
失败」；预期之外的异常（`condition-case' 兜住的那类）**不**写负缓存，避免把
一次瞬时故障固化成永久失败。

**装上新工具的注意**：`unzip' / `mutool' 缺失时同样写负缓存（否则每次渲染
都要重试探针）；装上工具后需 `M-x seshat-covers-clear-cache' 清掉负缓存才会
重试。

**不抛错**：任何异常只记 warn 并返回 nil。本函数不碰 image、不触网。"
  (cond
   ((not (seshat-covers--uid-valid-p uid))
    (seshat-log 'warn "封面：uid 形态非法，已忽略：%S" uid)
    nil)
   ((seshat-covers-cached uid))
   ((seshat-covers-failed-p uid) nil)
   (t
    (condition-case err
        (or (seshat-covers--try-epub uid file)
            (seshat-covers--try-pdf uid file)
            (progn (seshat-covers--mark-failed uid) nil))
      (error
       (seshat-log 'warn "封面：提取异常（%s）：%S" uid err)
       nil)))))

;;; 串行限速队列

(defun seshat-covers--cooling-down-p ()
  "判断是否处于熔断冷却期；冷却刚到期时顺便清零计数，返回 nil.
冷却期的存在理由是**整批失败**：`unzip' 没装、文件系统不可读时，每本书都要
白等一次 `seshat-covers-timeout'，一页 30 本就是 90 秒的卡顿。连续失败达到
`seshat-covers--failure-threshold' 次就暂停队列 `seshat-covers--cooldown-seconds'
秒，期间不碰任何子进程。

到期即清零：冷却结束后重新给环境一次机会（用户可能刚装好 `mutool'）。"
  (when seshat-covers--cooldown-until
    (if (< (float-time) seshat-covers--cooldown-until)
        t
      (setq seshat-covers--cooldown-until nil
            seshat-covers--consecutive-failures 0)
      nil)))

(defun seshat-covers--note-result (result)
  "按一次提取结果 RESULT（非 nil = 成功）更新连续失败计数并可能打开熔断.
成功一次即清零（「连续」的语义）；失败累计到阈值时设置
`seshat-covers--cooldown-until' 并**只** `seshat-log' 记一条 warn（不 `message'：
封面是装饰，不该用回显区打扰用户）。"
  (if result
      (setq seshat-covers--consecutive-failures 0)
    (setq seshat-covers--consecutive-failures
          (1+ seshat-covers--consecutive-failures))
    (when (and (>= seshat-covers--consecutive-failures
                    seshat-covers--failure-threshold)
               (null seshat-covers--cooldown-until))
      (setq seshat-covers--cooldown-until
            (+ (float-time) seshat-covers--cooldown-seconds))
      (seshat-log 'warn
                  "封面：连续 %s 次提取失败，暂停队列 %s 秒（可用 `seshat-covers-clear-cache' 或等冷却结束重试）"
                  seshat-covers--consecutive-failures
                  seshat-covers--cooldown-seconds)))
  result)

(defun seshat-covers--arm-timer (&optional delay)
  "武装 idle 定时器（已武装则不动）；DELAY 为触发前的空闲秒数.
DELAY 缺省为 `seshat-covers-queue-delay'；熔断冷却期用**剩余冷却秒数**武装，
避免在 60 秒冷却里每 0.2 秒醒一次空转。"
  (unless (timerp seshat-covers--timer)
    (setq seshat-covers--timer
          (run-with-idle-timer (or delay seshat-covers-queue-delay) nil
                               #'seshat-covers--pump))))

(defun seshat-covers--pump ()
  "处理队首**一个**条目，然后按需重新武装定时器.
`seshat-covers--running' 为 t 时直接返回（防重入）；callback 抛错被吞掉且不
影响后续条目——一本书的显示逻辑出错不该让整个队列停摆。

熔断冷却期内**不处理**队首，但按剩余冷却时间重新武装定时器：队列不丢，冷却
一结束就自己恢复。"
  (when (timerp seshat-covers--timer)
    (cancel-timer seshat-covers--timer)
    (setq seshat-covers--timer nil))
  (cond
   ((seshat-covers--cooling-down-p)
    ;; 冷却期内只等，不碰子进程；队列原样保留。
    (when seshat-covers--queue
      (seshat-covers--arm-timer
       (max 0.1 (- seshat-covers--cooldown-until (float-time))))))
   ((and (not seshat-covers--running) seshat-covers--queue)
    (let ((item (pop seshat-covers--queue)))
      (setq seshat-covers--running t
            seshat-covers--active-uid (car item))
      (unwind-protect
          (let* ((uid (car item))
                 (file (nth 1 item))
                 (callback (nth 2 item))
                 (result (condition-case err
                             (seshat-covers-extract uid file)
                           (error
                            (seshat-log 'warn "封面：队列提取异常（%s）：%S"
                                        uid err)
                            nil))))
            (seshat-covers--note-result result)
            (when (functionp callback)
              (condition-case err
                  (funcall callback uid result)
                (error
                 (seshat-log 'warn "封面：队列回调异常（%s）：%S" uid err)))))
        (setq seshat-covers--running nil
              seshat-covers--active-uid nil)))
    (when seshat-covers--queue
      (seshat-covers--arm-timer)))))

(defun seshat-covers-queue (uid file &optional callback)
  "把 `(UID FILE)' 加入串行 idle 队列；CALLBACK 收到 `(UID PATH-OR-NIL)'.
同一 uid 已在队列里或正在处理时**丢弃本次入队**（去重，返回 nil）：同一本书
被反复请求只该提取一次。入队成功返回 t。

定时器是 idle 的（`run-with-idle-timer'），且每次只处理 1 本、两本之间隔
`seshat-covers-queue-delay'——书架一次渲染 200 本时，用户输入不会被抢，
子进程也不会一次拉满。"
  (cond
   ((not (seshat-covers--uid-valid-p uid))
    (seshat-log 'warn "封面：uid 形态非法，不入队：%S" uid)
    nil)
   ((or (equal uid seshat-covers--active-uid)
        (cl-some (lambda (item) (equal uid (car item))) seshat-covers--queue))
    nil)
   (t
    (setq seshat-covers--queue
          (nconc seshat-covers--queue (list (list uid file callback))))
    (seshat-covers--arm-timer)
    t)))

(defun seshat-covers-queue-length ()
  "返回当前队列长度（不含正在处理的条目）。供测试与状态汇总使用。"
  (length seshat-covers--queue))

(defun seshat-covers-queue-clear ()
  "清空队列并取消定时器（同时复位熔断计数与冷却期）.
书架 buffer 关闭时调用，避免对已关闭 buffer 的 callback 继续触发。

熔断状态一并复位：队列都清了，说明用户/调用方主动重来一次，没有理由继续
惩罚新的一批请求。"
  (interactive)
  (setq seshat-covers--queue nil
        seshat-covers--consecutive-failures 0
        seshat-covers--cooldown-until nil)
  (when (timerp seshat-covers--timer)
    (cancel-timer seshat-covers--timer))
  (setq seshat-covers--timer nil)
  nil)

;;; 缓存清理

(defun seshat-covers--cache-file-p (file)
  "判断 FILE（绝对路径）是否是本模块的缓存文件（图片或负缓存）。"
  (let ((name (file-name-nondirectory file))
        (case-fold-search nil))
    (and (string-match-p
          (concat "\\`[0-9A-HJKMNP-TV-Z]\\{26\\}\\.\\(?:"
                  (mapconcat #'identity seshat-covers--extensions "\\|")
                  "\\|none\\)\\'")
          name)
         t)))

(defun seshat-covers-clear-cache (&optional uid)
  "清除封面缓存，返回删除的文件数.
UID 非空时只清该 uid 的缓存（**含负缓存** `<uid>.none'）；UID 为空时清
`seshat-covers-dir' 下所有本模块的缓存文件（目录本身保留）。UID 形态非法时
不删任何东西，只记 warn。

负缓存会让「已失败的书」永不重试，因此装好 `unzip' / `mutool' 之后、或书籍
文件被替换之后，用它手动重置。"
  (interactive "s清除哪个 uid 的封面缓存（留空 = 全部）: ")
  (let* ((dir (seshat-covers--dir))
         (targets
          (cond
           ((and (stringp uid) (not (string-empty-p uid)))
            (cond
             ((not (seshat-covers--uid-valid-p uid))
              (seshat-log 'warn "清封面缓存：uid 形态非法，已忽略：%S" uid)
              nil)
             ((not (file-directory-p dir)) nil)
             (t
              (let ((case-fold-search nil))
                (directory-files
                 dir t (concat "\\`" (regexp-quote uid) "\\."))))))
           ((not (file-directory-p dir)) nil)
           (t
            (cl-remove-if-not #'seshat-covers--cache-file-p
                              (directory-files dir t))))))
    (dolist (file targets)
      (ignore-errors (delete-file file)))
    (length targets)))

(provide 'seshat-covers)

;;; seshat-covers.el ends here
