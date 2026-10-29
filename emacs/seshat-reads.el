;;; seshat-reads.el --- 本地阅读进度侧车（离线可用，零网络） -*- lexical-binding: t; -*-

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

;; 本模块把「uid → 页码 / 总页数 / 时间」记到**一个本地 `.eld' 文件**，供
;; 离线书架显示阅读进度。**零网络**：只依赖文件系统，不 require
;; `seshat-rest' / `seshat-sync' / `seshat-library'（依赖图约束见 ADR 0006）。
;;
;; 数据形状（顶层 plist，`prin1' 序列化）：
;;
;;   (:version 1 :reads ((UID . (:page N :total M :updated UNIX秒)) ...))
;;
;; 四条不变量（改动本模块时必须保持）：
;;
;; 1. **`:version' 必须存在且为 1**：加载时缺失或不等 → 视为空表，但**保留原
;;    文件不删**（用户数据可能来自未来版本，删掉不可恢复）。
;; 2. **原子写**：同目录 `make-temp-file' + `write-region' + `rename-file'，
;;    与 `seshat-state-save' 同惯例；写到一半崩溃不会留下半截文件，正常结束后
;;    目录里只剩进度文件本身。
;; 3. **坏文件降级**：读失败 / 内容非法 → 空表 + `seshat-log' 记一条 warn，
;;    **不抛错、不删文件**。「记进度」永远不该把阅读或书架搞挂。
;; 4. **落盘去抖**：`seshat-reads-record' 只改内存 + 武装一个模块级单例定时器
;;    （`seshat-reads-debounce' 秒）；到点或显式 `seshat-reads-save' 才写盘。
;;    定时器与内存表都是**模块级**变量，不做 buffer-local——进度表跨 buffer
;;    共享，buffer-local 会让同一 uid 出现多份互相覆盖的副本。
;;
;; 惰性加载：加载本模块**不**读文件；首次 `seshat-reads-get' / `record' /
;; `clear' 才经 `seshat-reads--ensure' 触发一次磁盘读。
;;
;; 页号的**软依赖**：`seshat-reads--note-current-page' 需要当前页与总页数，它们
;; 来自 reader（`seshat-reader-current-doc-pagenumber' /
;; `seshat-reader-current-doc-pagecount'）。本模块用 `declare-function' +
;; `defvar' 前置声明 + `fboundp' / `boundp' 守卫，**不 require
;; `seshat-reader'**：reader 是 vendored 包，进度侧车不该反向拖住它的加载顺序，
;; 书架等离线场景也可能只加载本模块。取不到页号时静默不写（不猜、不用行号
;; 冒充页数）。
;;
;; 依赖方向：`seshat-log'（日志出口）+ `cl-lib'。禁止 require `seshat-rest'。

;;; Code:

(require 'cl-lib)
(require 'seshat-log)

(defgroup seshat-reads nil
  "Seshat 本地阅读进度侧车。"
  :group 'data
  :prefix "seshat-reads-")

(defcustom seshat-reads-file
  (expand-file-name "reads.eld" "~/.local/share/seshat/")
  "阅读进度侧车文件的路径.

默认值为 \"~/.local/share/seshat/reads.eld\"（经 `expand-file-name' 展开；路径
中可用 `~' 表示主目录），与同目录的 \"sync-state.eld\" /
\"annotation-queue.eld\" 保持同一惯例。文件内容是一个 plist（结构见模块
Commentary），由 `seshat-reads-save' 以**同目录临时文件 + `rename-file'' 的
原子替换方式写入。"
  :type 'file
  :group 'seshat-reads)

(defcustom seshat-reads-debounce 2
  "`seshat-reads-record' 落盘的去抖秒数.

翻页会连续触发记录（每页一次），每次都写盘既费 IO 也没必要；本值控制「最后
一次记录之后再等多久才真正落盘」。0 表示不延迟（仍然经定时器，语义一致）。"
  :type 'number
  :group 'seshat-reads)

(defconst seshat-reads-version 1
  "阅读进度侧车的数据版本号.
`:version' 字段恒为此值；加载时缺失或不等于此值一律按空表处理（文件保留）。
将来升级数据形状时应同时提升此常量并在 `seshat-reads-load' 内做迁移。")

(defvar seshat-reads--state nil
  "内存中的进度表 plist；nil 表示尚未从磁盘加载.
形状与文件一致：`(:version 1 :reads ((UID . ENTRY) ...))'。所有公开读写函数
都经 `seshat-reads--ensure' 惰性加载。测试可把它绑定为 nil 以获得干净的起点
（配合把 `seshat-reads-file' 绑到临时文件）。")

(defvar seshat-reads--timer nil
  "挂起的落盘定时器（模块级单例）；nil 表示没有挂起的定时器.")

(defvar seshat-reads--pending nil
  "是否有尚未落盘的记录.
用独立布尔量而不是 `(timerp seshat-reads--timer)' 判断「是否已武装」：测试里
`run-at-time' 常被桩替成返回 nil，靠 timer 对象判断会误判成「未武装」而重复
武装定时器。")

;; reader 侧访问器的**软依赖声明**：只声明，不 require（理由见模块 Commentary）。
;; `defvar' 不设值，不会覆盖 reader 里 `defvar-local' 的默认值。
(defvar seshat-reader-current-doc-pagecount)

(declare-function seshat-reader-current-doc-pagenumber "seshat-reader" (&optional window))
(declare-function seshat-reader--multipage-pagecount "seshat-reader" ())

;;; 内存状态的构造与归一化（纯函数）

(defun seshat-reads--empty ()
  "返回空的进度表 plist.
形状为 `(:version 1 :reads nil)'。"
  (list :version seshat-reads-version :reads nil))

(defun seshat-reads--normalize-entry (entry)
  "返回 ENTRY 归一化后的条目 plist（不修改入参）.
字段固定为 `:page' `:total' `:updated'，顺序如上：`:page' / `:total' 非正整数
时置 nil（未知），`:updated' 非数字时置 nil。ENTRY 为 nil 时得到字段齐备的
空条目。"
  (let ((page (plist-get entry :page))
        (total (plist-get entry :total))
        (updated (plist-get entry :updated)))
    (list :page (and (integerp page) (> page 0) page)
          :total (and (integerp total) (> total 0) total)
          :updated (and (numberp updated) updated))))

(defun seshat-reads--normalize (state)
  "返回 STATE 归一化后的合法进度表 plist（纯函数，不修改入参）.

容错规则：STATE 不是 plist（含 nil、数字、字符串、向量）时返回空表；
`:version' 一律置为 `seshat-reads-version'（**版本校验在 `seshat-reads-load'
里做**，本函数只负责形状）；`:reads' 中键不是字符串或值不是 plist 的元素丢弃，
其余条目逐字段归一化。"
  (if (not (keywordp (car-safe state)))
      (seshat-reads--empty)
    (let ((raw (plist-get state :reads))
          (reads nil))
      (dolist (cell (and (listp raw) raw))
        (when (and (consp cell) (stringp (car cell)) (listp (cdr cell)))
          (push (cons (car cell) (seshat-reads--normalize-entry (cdr cell)))
                reads)))
      (list :version seshat-reads-version :reads (nreverse reads)))))

(defun seshat-reads--put-entry (state uid entry)
  "返回把 UID 的条目设为 ENTRY 后的新状态 plist（不修改入参）.
UID 已存在（`equal' 比较）时原位替换，否则追加到末尾，因此条目顺序稳定
（与 `seshat-state--alist-put' 同口径，便于文件 diff 只显示变化的那一行）。"
  (let ((reads (plist-get state :reads))
        (replaced nil)
        (result nil))
    (dolist (cell reads)
      (if (equal (car cell) uid)
          (progn
            (setq replaced t)
            (push (cons uid entry) result))
        (push cell result)))
    (list :version seshat-reads-version
          :reads (if replaced
                     (nreverse result)
                   (append (nreverse result) (list (cons uid entry)))))))

(defun seshat-reads--delete-entry (state uid)
  "返回删掉 UID 条目后的新状态 plist（不修改入参）.
UID 不存在时返回与 STATE 等价的状态（不报错）。"
  (let ((result nil))
    (dolist (cell (plist-get state :reads))
      (unless (equal (car cell) uid)
        (push cell result)))
    (list :version seshat-reads-version :reads (nreverse result))))

;;; 加载与保存

(defun seshat-reads--read-file (file)
  "读取 FILE 并返回校验过的进度表 plist；无法读取、解析或版本不符时返回 nil.

**显式禁用 `read-eval'**（`(let ((read-eval nil)) (read ...))'）：本仓库把进度
侧车当**纯数据**读，不允许其中的任何构造被执行。`#.' 读语法在旧版 Emacs 上受
`read-eval' 控制，绑 nil 是**硬保护**；Emacs 32 已移除该变量（`#.' 直接报错），
此时绑定是**无害空操作**。换言之：本文件的安全性不依赖「当前 Emacs 版本的
默认行为」，也不依赖 `Package-Requires`（那只在 package.el 路径生效，手工
`load-path' 加载或降级版本时不成立），而是由本函数显式保证。

顶层值必须是 plist 且**之后不得再有内容**（多出一个 form 说明文件被拼接或
截断过）。`:version' 不等于 `seshat-reads-version' 时返回 nil（由调用方按空表
处理，**不删文件**）。本函数会抛错，容错在 `seshat-reads-load' 里做。"
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((raw (let ((read-eval nil))    ; 旧版 Emacs 上禁用 `#.'；32+ 无此变量，绑定为空操作
                 (ignore read-eval)      ; 32+ 里它是普通词法变量：读一次以免 "unused lexical variable"
                 (read (current-buffer)))))
      (unless (or (null raw) (keywordp (car-safe raw)))
        (error "顶层值不是 plist：%S" raw))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (error "顶层 plist 之后还有多余内容：%S"
               (buffer-substring-no-properties
                (point) (min (point-max) (+ (point) 40)))))
      (when (eql (plist-get raw :version) seshat-reads-version)
        (seshat-reads--normalize raw)))))

(defun seshat-reads-load ()
  "从 `seshat-reads-file' 读取进度表，装入内存并返回.

容错规则（**任何分支都不抛错、都不删文件**）：
- 文件不存在 → 空表（不创建文件）；
- 内容无法读取或解析（含顶层值不是 plist、plist 之后有多余内容）→ 空表 +
  `seshat-log' 记一条 warn，文件保留（便于事后排查/手工修复）；
- `:version' 缺失或不等于 `seshat-reads-version' → 空表 + warn，文件保留
  （可能来自未来版本，删掉不可恢复）。"
  (let* ((file seshat-reads-file)
         (state (if (not (file-exists-p file))
                    (seshat-reads--empty)
                  (condition-case err
                      (or (seshat-reads--read-file file)
                          (progn
                            (seshat-log
                             'warn
                             "阅读进度文件 %s 的 :version 不是 %d，按空表处理（文件保留）"
                             file seshat-reads-version)
                            (seshat-reads--empty)))
                    (error
                     (seshat-log
                      'warn
                      "阅读进度文件 %s 无法解析（%s），按空表处理（文件保留）"
                      file (error-message-string err))
                     (seshat-reads--empty))))))
    (setq seshat-reads--state state)
    state))

(defun seshat-reads--ensure ()
  "返回当前内存进度表；尚未加载时先从 `seshat-reads-file' 加载。"
  (or seshat-reads--state (seshat-reads-load)))

(defun seshat-reads-save ()
  "把当前内存进度表原子写入 `seshat-reads-file'，并返回写出的状态 plist.

写入前先 `seshat-reads--normalize' 归一化并把 `:version' 置为
`seshat-reads-version'。写入方式：`make-temp-file'（临时文件与目标文件**同
目录**，保证 `rename-file' 是同一文件系统内的原子替换）→ `write-region' →
`rename-file'；中途失败会删除临时文件，正常结束后目录里只剩进度文件本身。
父目录不存在时自动创建。

本函数是「立即落盘」入口（`kill-buffer' 路径用它避免丢最后一次），因此同时
兑现挂起的去抖写：清掉 `seshat-reads--pending' 并取消尚未到点的定时器。"
  (let* ((file seshat-reads-file)
         (dir (file-name-directory (expand-file-name file)))
         (state (seshat-reads--normalize (seshat-reads--ensure))))
    (when (timerp seshat-reads--timer)
      (cancel-timer seshat-reads--timer))
    (setq seshat-reads--timer nil
          seshat-reads--pending nil)
    (make-directory dir t)
    (let* ((temporary-file-directory dir)
           (tmp (make-temp-file "seshat-reads" nil ".eld")))
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert ";; -*- mode: emacs-lisp; coding: utf-8-unix; -*-\n")
              (insert ";; Seshat 阅读进度侧车，由 seshat-reads.el 自动生成，请勿手工编辑。\n")
              (let ((print-length nil)
                    (print-level nil)
                    (print-circle t)
                    (coding-system-for-write 'utf-8-unix))
                (prin1 state (current-buffer))
                (insert "\n")
                (write-region (point-min) (point-max) tmp nil 'silent)))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (ignore-errors (delete-file tmp)))))
    (setq seshat-reads--state state)
    state))

(defun seshat-reads--flush ()
  "去抖定时器到点的回调：清掉挂起状态并落盘.
先清状态再调用 `seshat-reads-save'，避免「到点后又被当成挂起」而重复取消
已触发的定时器。"
  (setq seshat-reads--timer nil
        seshat-reads--pending nil)
  (seshat-reads-save))

(defun seshat-reads--schedule-save ()
  "武装落盘定时器（模块级单例，已有挂起定时器时不再重复武装）."
  (unless seshat-reads--pending
    (setq seshat-reads--pending t)
    (setq seshat-reads--timer
          (run-at-time seshat-reads-debounce nil #'seshat-reads--flush))))

;;; 公开读写接口

(defun seshat-reads-get (uid)
  "返回 UID 的阅读进度条目 plist；无记录时返回 nil.
条目形状为 `(:page N :total M :updated UNIX秒)'，`:total' 未知时为 nil。"
  (alist-get uid (plist-get (seshat-reads--ensure) :reads) nil nil #'equal))

(defun seshat-reads-record (uid page &optional total)
  "记录 UID 的阅读进度：PAGE 是 1-based 页号，TOTAL 是总页数（可 nil）。
只改内存并武装去抖定时器，返回归一化后的条目；真正落盘由定时器到点
（`seshat-reads--flush'）或显式 `seshat-reads-save' 完成。

UID 必须是非空字符串、PAGE 必须是正整数，否则 `error'——那是调用方的编程
错误（自动路径请走 `seshat-reads--note-current-page'，它对取不到的页号静默
跳过）。TOTAL 非正整数时按 nil 记（未知总页数，**不用估算冒充**）。"
  (unless (and (stringp uid) (not (string-empty-p uid)))
    (error "Seshat reads: uid 必须是非空字符串：%S" uid))
  (unless (and (integerp page) (> page 0))
    (error "Seshat reads: page 必须是正整数：%S" page))
  (let ((entry (seshat-reads--normalize-entry
                (list :page page
                      :total total
                      :updated (truncate (float-time))))))
    (setq seshat-reads--state
          (seshat-reads--put-entry (seshat-reads--ensure) uid entry))
    (seshat-reads--schedule-save)
    (seshat-reads-get uid)))

(defun seshat-reads-percent (entry)
  "返回 ENTRY 的阅读百分比（0-100 的整数）；无法计算时返回 nil.

纯函数，边界严格：
- `:total' 非正整数（含 nil / 0 / 负数 / 浮点）→ nil；
- `:page' 非正数 → nil；
- `:page' 大于 `:total' → 100（夹紧，绝不返回 >100）；
- 其余 `(round (* 100.0 (/ page total)))'，并夹到 0..100。"
  (let ((page (plist-get entry :page))
        (total (plist-get entry :total)))
    (when (and (integerp total) (> total 0)
               (integerp page) (> page 0))
      (if (> page total)
          100
        (max 0 (min 100 (round (* 100.0 (/ (float page) total)))))))))

(defun seshat-reads-clear (&optional uid)
  "清空阅读进度：UID 非 nil 时只删该条，nil 时清空全部；返回 nil.
清空是显式动作（用户主动抹掉记录），因此**立即落盘**，不走去抖——否则用户
清完立刻退出 Emacs 时记录会「复活」。"
  (let ((state (seshat-reads--ensure)))
    (setq seshat-reads--state
          (if (and (stringp uid) (not (string-empty-p uid)))
              (seshat-reads--delete-entry state uid)
            (seshat-reads--empty))))
  (seshat-reads-save)
  nil)

;;; 页号采集（reader 的软依赖）与唯一写入漏斗

(defun seshat-reads--buffer-page ()
  "返回当前 buffer 视口顶页的页号（1-based）；取不到时返回 nil.

页号口径与 reader 一致：取 `seshat-reader-current-doc-pagenumber'（多页布局
下由 `window-start' 落在的页行派生，故是**视口顶页**、1-based）。未加载
`seshat-reader' 或 buffer 尚未渲染出页行时返回 nil——**不猜**。"
  (when (fboundp 'seshat-reader-current-doc-pagenumber)
    (let ((page (ignore-errors (seshat-reader-current-doc-pagenumber))))
      (and (integerp page) (> page 0) page))))

(defun seshat-reads--buffer-total ()
  "返回当前 buffer 的总页数；取不到时返回 nil.

两个来源都来自 reader：优先 buffer-local 变量
`seshat-reader-current-doc-pagecount'（reader 自己的 mode-line 读的就是它，
由动态模块维护），它缺失或非正时退回内部函数
`seshat-reader--multipage-pagecount'（多一层正整数校验）。两处都取不到就返回
nil——**不用行数或估算冒充总页数**。"
  (let ((count (and (boundp 'seshat-reader-current-doc-pagecount)
                    seshat-reader-current-doc-pagecount)))
    (unless (and (integerp count) (> count 0))
      (setq count (and (fboundp 'seshat-reader--multipage-pagecount)
                       (ignore-errors (seshat-reader--multipage-pagecount)))))
    (and (integerp count) (> count 0) count)))

(defun seshat-reads--note-current-page (uid &optional page total)
  "为 UID 记录当前 buffer 的阅读进度——**页号变化的唯一写入漏斗**.
PAGE / TOTAL 省略时从当前 buffer 取（`seshat-reads--buffer-page' /
`seshat-reads--buffer-total'）。UID 为空或页号取不到时静默返回 nil（不写、
不猜）。零网络、零阻塞：只改内存并武装去抖定时器。"
  (when (and (stringp uid) (not (string-empty-p uid)))
    (let ((page (or page (seshat-reads--buffer-page)))
          (total (or total (seshat-reads--buffer-total))))
      (when (and (integerp page) (> page 0))
        (seshat-reads-record uid page total)))))

(provide 'seshat-reads)

;;; seshat-reads.el ends here
