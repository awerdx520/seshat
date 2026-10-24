;;; seshat-merge.el --- 纯合并原语：diff3 三方合并与冲突标记判定 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, comm, notes
;; Package-Requires: ((emacs "27.1"))

;; 本文件不属于 GNU Emacs。

;;; Commentary:

;; 本模块只承载**纯合并原语**，不含任何网络、状态库或用户交互：
;;
;; - `seshat-merge--diff3'：调系统 `diff3 -m' 做三方合并（入参与返回值都是
;;   字符串，临时文件的创建与清理全在本模块内）；
;; - `seshat-merge-conflicted-p'：用**正则扫描**合并结果里的冲突标记，判定是否
;;   存在冲突。
;;
;; ## 为什么单独成文件（而不是复用 `seshat-conflict'）
;;
;; `seshat-conflict.el' **已经** `require 'seshat-sync'（它要用
;; `seshat-sync--request' / `seshat-sync--webdav-url' 走 WebDAV）。而 M8-B 的
;; 增量引擎（`seshat-sync-push'）在收到 412 时需要 diff3 与冲突标记判定——如果
;; `seshat-sync' 反过来 `require 'seshat-conflict'，两文件就成环（`require' 环
;; 在字节编译期不会报错，但运行期会拿到「尚未定义」的函数，属难以定位的故障）。
;; 因此把合并原语下沉到本模块：依赖方向固定为
;;
;;     seshat-sync  ──▶  seshat-merge
;;     seshat-conflict ─▶ seshat-sync ─▶ seshat-merge
;;
;; **本模块不 require `seshat-conflict'，也不 require `seshat-sync'。**
;;
;; `seshat-conflict.el' 里已有的 `seshat-conflict--diff3'（临时文件版）与
;; 「用 `smerge-mode' 判冲突」两条口径属 T4 的整合范围：T4 会让它改为复用
;; 本模块的实现（届时 `seshat-conflict--diff3' 收敛为
;; `seshat-merge--diff3' 的薄包装），本任务（T2）**不动** `seshat-conflict.el'。
;;
;; ## 为什么冲突判定用正则而不是 `smerge-mode'
;;
;; 自动 push 可能由定时器触发：`smerge-mode' 依赖 buffer 的交互状态（要真正
;; 在 window 里显示、要 `smerge-refine' 之类的惰性机制），在 batch 与定时器
;; 路径下不可靠，且它会「进入」文件——自动流程只应判断「有没有冲突标记」，
;; 处理冲突是用户的事（计划 D4 已固定该口径）。`diff3 -m' 的输出里冲突块以
;; 行首的 `<<<<<<<` / `>>>>>>>` 界定，正则扫描即可，且与 smerge 的判据同源
;; （都看 diff3 生成的标记）。

;;; Code:

(defgroup seshat-merge nil
  "笔记同步的纯合并原语（diff3 调用与冲突标记判定）。"
  :group 'tools
  :prefix "seshat-merge-")

(defcustom seshat-merge-diff3-program "diff3"
  "三方合并所用的 `diff3' 可执行文件名或绝对路径.
默认 \"diff3\"（GNU diffutils 的一部分，经 `executable-find' 在 `exec-path'
里查找）。为空串、nil 或在 `exec-path' 中找不到时，`seshat-merge--diff3'
一律返回 nil（调用方据此降级：保留 dirty、提示用户手工处理），本模块不会因
缺少 diff3 而报错。"
  :type 'string
  :group 'seshat-merge)

;;; 内部辅助：二进制安全的临时文件读写

(defun seshat-merge--binary-string (content)
  "把 CONTENT 转成可直接落盘的字节串（二进制安全）。
多字节字符串按 UTF-8 编码（服务端 wire 格式），已是 unibyte 的串原样返回
（`insert-file-contents-literally' 读到的本地内容就是这种形态，不得再做一次
编解码往返，否则高位字节被改写）；nil 视为空串。"
  (cond ((null content) "")
        ((multibyte-string-p content) (encode-coding-string content 'utf-8))
        (t content)))

(defun seshat-merge--write-temp (file content)
  "把 CONTENT 以二进制安全方式写入 FILE，返回 FILE.
不创建父目录（调用方用 `make-temp-file' 建好临时目录）、不做原子替换（临时
文件无需原子性）：unibyte 缓冲区 + `no-conversion' 直接落字节。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (seshat-merge--binary-string content))
    (let ((coding-system-for-write 'no-conversion))
      (write-region (point-min) (point-max) file nil 'silent)))
  file)

(defun seshat-merge--read-temp (file)
  "以二进制安全方式读取 FILE 的全部内容，返回 unibyte 字节串。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

;;; 三方合并

(defun seshat-merge--diff3 (base local remote)
  "对 BASE / LOCAL / REMOTE 三段内容做三方合并，返回合并结果字符串.
**Lisp 形参顺序是「共同祖先 / 本地 / 远端」**（与调用方
`seshat-conflict--diff3' 的习惯一致），但传给 `diff3' 时会重排成它自己的
`-m MINE OLDER YOURS' 顺序（见下）。三段都作为字符串传入，nil 视为空串。
返回值是 **unibyte 字节串**（合并结果原样字节，调用方可直接落盘，不经编码
往返）。

实现：把三段内容以二进制安全方式写进同一个临时目录的三个文件，再用
`call-process' 调 diff3（程序名取 `seshat-merge-diff3-program'）。**注意 diff3
自己的位置语义是 `-m MINE OLDER YOURS'**：共同祖先必须是**第二个**参数，故
实际调用为 `-m local base remote'。顺序颠倒（把 base 放第一位）时 diff3 会把
base 当「我方」、local 当祖先，两侧各自独立的改动会被误报成冲突（实测：只有
`local base remote' 能正确合并）。**退出码 1
表示「有冲突但合并成功」**（标准输出仍是带冲突标记的合并结果），因此 1 与 0
都返回内容；大于 1 的退出码与负值（被信号终止）一律视为失败。临时目录用
`unwind-protect' 递归清理，无论成功、失败还是抛错都不留残留。

返回 nil 的四种情形（调用方据此**保留 dirty**、只发警告，不做任何交互）：

1. `executable-find' 找不到 diff3 程序（含 `seshat-merge-diff3-program'
   为 nil / 空串）；
2. 子进程以大于 1 的退出码结束（diff3 自身报错，例如文件不可读）；
3. 子进程被信号终止（退出码为负）；
4. `call-process' 抛错（程序在查找之后消失、权限不足等）。

**与 `seshat-conflict--diff3'（`seshat-conflict.el'）的关系**：后者同样是
「临时文件 + `call-process' + 退出码 1 视为正常」，但入参是**三个文件路径**
且临时文件由调用方管理；本函数把「内容 → 临时文件 → 清理」一并收进来，因为
增量引擎（`seshat-sync-push'）拿到的是内存里的字符串（本地文件内容、下载到
临时文件的远端内容、`/api/versions' 返回的祖先内容），没有现成的三个路径。
T4 会让 `seshat-conflict--diff3' 收敛到本实现，届时两者的差异只剩入参形态。"
  (let ((program (and (stringp seshat-merge-diff3-program)
                      (not (string-empty-p seshat-merge-diff3-program))
                      (executable-find seshat-merge-diff3-program)))
        (dir nil)
        (merged nil))
    (when program
      (condition-case nil
          (progn
            (setq dir (file-name-as-directory (make-temp-file "seshat-merge-" t)))
            (let ((base-file (expand-file-name "base" dir))
                  (local-file (expand-file-name "local" dir))
                  (remote-file (expand-file-name "remote" dir)))
              (seshat-merge--write-temp base-file base)
              (seshat-merge--write-temp local-file local)
              (seshat-merge--write-temp remote-file remote)
              (with-temp-buffer
                ;; 输出按原始字节收：unibyte 缓冲区 + no-conversion，合并结果的
                ;; 字节与三段输入一一对应，落盘时不会经编码往返。
                (set-buffer-multibyte nil)
                (let ((coding-system-for-read 'no-conversion)
                      (coding-system-for-write 'no-conversion)
                      (exit (call-process program nil (current-buffer) nil
                                          ;; `diff3 -m MINE OLDER YOURS'：**第二个**
                                          ;; 参数才是共同祖先。参数顺序颠倒时
                                          ;; diff3 会把 base 当「我方」、local 当
                                          ;; 祖先，干净的三方合并会被误报为冲突
                                          ;; （实测：只有 `local base remote' 的
                                          ;; 顺序能正确合并两侧独立的改动）。
                                          "-m" local-file base-file remote-file)))
                  ;; 0 = 无冲突合并成功；1 = 有冲突但标准输出仍是合并结果；
                  ;; 其余（>1 / 负值 / 非整数）= diff3 自身失败 → 返回 nil
                  (when (and (integerp exit) (>= exit 0) (<= exit 1))
                    (setq merged (buffer-string)))))))
        (error nil))
      ;; 清理必须在 `condition-case' 之外：退出码判定在外、异常在内，两种路径
      ;; 都要删掉临时目录（`make-temp-file' 成功过就一定会留下目录）。
      (when (and dir (file-directory-p dir))
        (ignore-errors (delete-directory dir t))))
    merged))

;;; 冲突标记判定

(defun seshat-merge-conflicted-p (text)
  "判断合并结果 TEXT 是否含冲突标记（有冲突返回 t，否则 nil）.
判据是**行首**的 `<<<<<<<` 或 `>>>>>>>`（`diff3 -m' 冲突块的起止标记），用
正则对整段文本做多行扫描：Emacs 的 `^' 在字符串内既匹配串首、也匹配每个换行
之后，故无需切行。只认这两个标记、**不认** `=======`：分隔行在「无冲突但两侧
内容恰好含 `=======`」的普通文本里也可能出现，单看它会误判。

TEXT 为 nil、非字符串或空串时返回 nil（不抛错）——调用方常在「合并失败
（nil）」之后顺手判一次。

**不用 `smerge-mode'**：它依赖 buffer 的交互状态（要显示在 window 里、依赖
惰性 refine），batch 与定时器路径下不可靠；自动流程（`seshat-sync-push' 的
412 分支）只判定「有没有冲突标记」，处理冲突留给用户在编辑器里做
（计划 D4）。本函数是纯字符串判定，与 `seshat-conflict.el' 的手动 `smerge'
路径同源（都看 diff3 的标记），因此两条路径的判据不会漂移。"
  (and (stringp text)
       (not (string-empty-p text))
       (string-match-p "^<<<<<<<\\|^>>>>>>>" text)
       t))

(provide 'seshat-merge)

;;; seshat-merge.el ends here
