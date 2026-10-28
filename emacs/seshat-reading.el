;;; seshat-reading.el --- Seshat 阅读模式：库身份 + 显式入库  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tools
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

;; `seshat-reading-mode' 是 `seshat-reader-mode' 的派生 major mode：渲染、
;; 翻页、目录、缩放 100% 继承自 reader，本模块只叠加两件事：
;;
;; 1. 库身份解析（`seshat-reading--resolve'）——只读本地同步状态文件，
;;    **零网络**，四态 `library' / `unregistered' / `external' / `broken'；
;; 2. mode-line 标识（" [库]" / " [未入库]" / " [库外]" / " [状态异常]"）。
;;
;; 加载本文件后会把 `auto-mode-alist' 中指向 `seshat-reader-mode' 的项**就地**
;; 改成 `seshat-reading-mode'（遍历替换 cdr，不重拼正则），因此 reader 支持的
;; 格式默认进本 mode。想回通用阅读器的用户可用 `add-to-list' 把对应扩展名的
;; pattern 指回 `seshat-reader-mode'（后加载者决定胜负）；pattern 文本与
;; `auto-mode-alist' 中现有项保持一致即可。
;;
;; 唯一会触网的入口是 `seshat-reading-refresh'（显式交互命令）：`--resolve'
;; 与 mode 体绝不发起任何 HTTP 请求——`seshat-rest-resolve-uid' 是同步请求，
;; 服务端不可达时会阻塞若干秒，直接毁掉「打开即阅读」。
;;
;; 本模块只读同步状态，不写：唯一会写状态的是 `seshat-reading-refresh'
;; 成功解析到 uid 之后的登记（`seshat-state-set' + `seshat-state-save'）。

;;; Code:

;; `require' 必须在顶层：保证 reader 的 `auto-mode-alist' 注册已经完成，
;; 之后本文件的接管才不会被 reader 的 lazy-load 反超。
(require 'seshat-reader)
(require 'seshat-state)
(require 'seshat-rest)

(defgroup seshat-reading nil
  "Seshat 阅读模式：库身份与显式入库。"
  :prefix "seshat-reading-"
  :group 'seshat-reader)

(defvar-local seshat-reading--identity nil
  "当前 buffer 的库身份 plist，由 `seshat-reading--resolve' 填充.
形状为 `(:state SYM :uid UID :root TAG :rel PATH)'，语义见
`seshat-reading--resolve'。")

(defvar seshat-reading--warned nil
  "`seshat-reading--resolve' 是否已经发过降级警告.
用于把「解析异常」的 `display-warning' 限制为每个 Emacs 进程一次，避免每
打开一个文件就刷一条同样的警告。")

(defconst seshat-reading--mode-line-entry
  '(:eval (seshat-reading--mode-line-text))
  "追加到 `mode-line-misc-info' 的 mode-line 构造.
`(:eval FORM)' 在回显时求值，因此状态变化后无需重建 mode-line。")

(defvar-local seshat-reading--quiet-fallback nil
  "当前 buffer 是否走批注 `--doc-id' 的 QUIET 路径（未入库时不刷警告）.
默认 nil——**非本 mode 的 buffer 行为完全不变**（`seshat-reader-mode' 下
未命中库根时仍会 `message' 降级警告）。`seshat-reading-mode' 的 mode 体会把
它设为 t，随后各调用点经 `seshat-reading-quiet-p' 取值并作为
`seshat-reader-annotation--doc-id' 的 QUIET 参数传入。

为什么用 buffer-local 标记 + 显式传参（而不是只靠 buffer-local 开关）：
`seshat-reader-translate' 的面板 buffer 会在 **reader buffer 之外**触发
doc-id 派生，buffer-local 开关在那时读不到正确值；因此标记只在
`seshat-reading-quiet-p' 里按**文件**反查 buffer 后取值，判定结果再经参数
传给 `--doc-id'。")

(defconst seshat-reading--state-mode-line-alist
  '((library . " [库]")
    (unregistered . " [未入库]")
    (external . " [库外]")
    (broken . " [状态异常]"))
  "库身份状态到 mode-line 标识的映射（状态见 `seshat-reading--resolve'）。")

;;; 批注静音（reader 模块的**软依赖**入口）

(defun seshat-reading-quiet-p (&optional file)
  "判断是否应静音批注 doc-id 的降级警告.
FILE 缺省用 `buffer-file-name'（当前 buffer）；给定 FILE 时查**访问该文件的
buffer**（`get-file-buffer'）并读其 `seshat-reading--quiet-fallback'，因此在
**跨 buffer** 调用（翻译面板等）里也能得到正确结果。

返回值恒为布尔（buffer 不存在或无标记时为 nil）。本函数只读 buffer-local
状态，不发请求、不交互。

reader 模块（`seshat-reader-annotation' / `-reference' / `-translate'）对
本函数是**软依赖**：它们经 `fboundp' 判断后 `funcall'，不得 `require'
`seshat-reading'——本模块反向 `require' 了 `seshat-reader'，硬依赖会成环。"
  (let ((buffer (if (and file (stringp file))
                    (get-file-buffer file)
                  (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'seshat-reading--quiet-fallback buffer)
         t)))

;;; 库身份解析（零网络）

(defun seshat-reading--warn-once (format-string &rest args)
  "发出一次 `seshat-reading' 级别的警告，之后不再重复.
FORMAT-STRING 与 ARGS 交给 `format'；去重标记见 `seshat-reading--warned'。"
  (unless seshat-reading--warned
    (setq seshat-reading--warned t)
    (display-warning 'seshat-reading
                     (apply #'format format-string args)
                     :warning)))

(defun seshat-reading--root-for-file (file)
  "返回 FILE 所属库根的 `(TAG . REL)'；不在任何根下时返回 nil.
FILE 先经 `expand-file-name' 与 `file-truename' 归一；根目录取自
`seshat-state-roots'（元素形如 `(TAG DIR MODE)'），多个根同时命中时取
**最长（最具体）的根**。REL 是相对该根的文件路径（不含根目录）。

本函数只读本地状态，不发任何请求。"
  (let* ((truename (file-truename (expand-file-name file)))
         (best nil)
         (best-length -1))
    (dolist (root (seshat-state-roots))
      (let* ((dir (file-name-as-directory
                   (file-truename (expand-file-name (nth 1 root)))))
             (length (length dir)))
        (when (and (> length best-length)
                   (file-in-directory-p truename dir))
          (setq best (cons (nth 0 root)
                           (file-relative-name truename dir))
                best-length length))))
    best))

(defun seshat-reading--state-broken-p ()
  "判断同步状态库是否处于「损坏后的空状态」.
判据是 `(seshat-state-roots)' 为空**且** `seshat-state--load-was-corrupt'
为 t（最近一次 `seshat-state-load' 因文件损坏回退到了空状态）。

**不看 \"<FILE>.bak\" 是否残留**：`.bak` 由 `seshat-state--backup-corrupt'
生成后从不清理，而「roots 为空」本身是合法状态（用户没配根），两者相与会
让一份旧损坏残留永久污染判定——每个文件都显示「状态异常」。

调用本函数会经 `seshat-state-roots' 触发一次惰性加载（磁盘读，通常几十
毫秒；坏文件在此被改名成 .bak 并置位 `seshat-state--load-was-corrupt'），
此后都是内存查表。"
  (seshat-state-roots)                 ; 触发惰性加载（若尚未加载）
  (and (null (seshat-state-roots)) seshat-state--load-was-corrupt))

(defun seshat-reading--resolve (file)
  "解析 FILE 的库身份，返回 `(:state SYM :uid UID :root TAG :rel PATH)'.
四态判定顺序固定，且**全部只读本地状态、不发任何 HTTP 请求**：

1. `broken'——状态库损坏（`:roots' 为空且有 .bak）。**优先级最高、先判**：
   否则它会顺流被下一条吃成 `external'，用户永远看不到「该修状态文件」；
2. `external'——不在任何库根下（`:root' 与 `:rel' 均为 nil）；
3. `library'——在根下且 `seshat-state-uid-for-path' 命中（含 `:uid'）；
4. `unregistered'——在根下但状态库没有该路径的 uid（含 `:root' 与 `:rel'，
   供 `seshat-reading-refresh' 显式向服务端确认）。

任何异常都降级为 `external' 并 `display-warning' 一次（标记见
`seshat-reading--warned'）——「打开文件」绝不因状态异常而失败。"
  (condition-case err
      (if (seshat-reading--state-broken-p)
          (list :state 'broken :uid nil :root nil :rel nil)
        (let ((match (seshat-reading--root-for-file file)))
          (if (null match)
              (list :state 'external :uid nil :root nil :rel nil)
            (let ((uid (seshat-state-uid-for-path (car match) (cdr match))))
              (list :state (if uid 'library 'unregistered)
                    :uid uid
                    :root (car match)
                    :rel (cdr match))))))
    (error
     (seshat-reading--warn-once "解析库身份失败（%s），按库外文档处理"
                                (error-message-string err))
     (list :state 'external :uid nil :root nil :rel nil))))

;;; mode-line 标识

(defun seshat-reading--mode-line-text ()
  "返回当前 buffer 的库身份 mode-line 标识；无身份时返回 nil."
  (cdr (assq (plist-get seshat-reading--identity :state)
             seshat-reading--state-mode-line-alist)))

(defun seshat-reading--install-mode-line ()
  "把库身份标识装入 buffer-local 的 `mode-line-misc-info'（幂等）.
同一 buffer 重复调用只保留一个 `seshat-reading--mode-line-entry'。"
  (setq-local mode-line-misc-info
              (cons seshat-reading--mode-line-entry
                    (delete seshat-reading--mode-line-entry
                            (copy-sequence mode-line-misc-info)))))

;;; 身份应用与显式刷新

(defun seshat-reading--apply-identity ()
  "解析当前 buffer 的库身份，写入 buffer-local 并刷新 mode-line.
无关联文件的 buffer 按 `external' 处理。返回解析出的身份 plist。
本函数不发任何网络请求，也不与用户交互。"
  (setq seshat-reading--identity
        (if (and (stringp buffer-file-name)
                 (not (equal buffer-file-name "")))
            (seshat-reading--resolve buffer-file-name)
          (list :state 'external :uid nil :root nil :rel nil)))
  (seshat-reading--install-mode-line)
  seshat-reading--identity)

(defun seshat-reading-refresh ()
  "向服务端确认当前文档的 uid（**显式触网**），并刷新库身份与 mode-line.
只有本地状态判为 `unregistered'（在库根下但状态库没有 uid）时才发一次
`seshat-rest-resolve-uid' 请求：

- 成功 → 把 uid 登记进状态（`seshat-state-set' + `seshat-state-save'），
  重新解析为 `library' 并说明结果；
- 失败（404 / 网络错误等）→ 保持 `unregistered'，用 `message' 说明原因，
  **不抛错**。

其余状态（`library' / `external' / `broken'）只重新解析本地状态，不发请求。
返回刷新后的身份 plist。"
  (interactive)
  (let ((file buffer-file-name))
    (unless (and (stringp file) (not (equal file "")))
      (user-error "Seshat: 当前 buffer 没有关联文件"))
    (setq seshat-reading--identity (seshat-reading--resolve file))
    (when (eq (plist-get seshat-reading--identity :state) 'unregistered)
      (let* ((root (plist-get seshat-reading--identity :root))
             (rel (plist-get seshat-reading--identity :rel))
             (uid (seshat-rest-resolve-uid root rel)))
        (if (null uid)
            (message "Seshat: 服务端未登记 %s:%s，仍为「未入库」（可用 %s 入库）"
                     root rel "M-x seshat-library-add")
          (seshat-state-set uid (list :root root :path rel))
          (seshat-state-save)
          (setq seshat-reading--identity (seshat-reading--resolve file))
          (message "Seshat: 已确认 %s:%s 为库内文档（uid %s）" root rel uid))))
    (seshat-reading--install-mode-line)
    (let ((state (plist-get seshat-reading--identity :state)))
      (cond
       ((eq state 'library)
        (message "Seshat: %s 是库内文档（uid %s）"
                 file (plist-get seshat-reading--identity :uid)))
       ((eq state 'external)
        (message "Seshat: %s 不在任何库根内（保持「库外」）" file))
       ((eq state 'broken)
        (message "Seshat: 同步状态库异常（备份见 %s.bak）" seshat-state-file))))
    seshat-reading--identity))

;;; 入库（显式动作：复制上传，保留原件）

(defcustom seshat-library-add-max-bytes (* 32 1024 1024)
  "`seshat-library-add' 允许入库的单个文件上限（字节）。
默认与服务端 `PUT /api/files' 的 32 MiB 上限对齐——超过这个值上传必然失败，
提前拒绝可避免无谓的复制与内存峰值。"
  :type 'integer
  :group 'seshat-reading)

(defun seshat-reading--file-buffer (file)
  "返回访问 FILE 的 buffer；没有时返回 nil.
先看当前 buffer 是否正访问 FILE（`file-equal-p'，避免临时 buffer 与
`get-file-buffer' 的口径差异），再退回 `get-file-buffer'。"
  (or (and (stringp file)
           (stringp buffer-file-name)
           (ignore-errors (file-equal-p buffer-file-name file))
           (current-buffer))
      (and (stringp file) (get-file-buffer file))))

(defun seshat-reading--mirror-roots ()
  "返回 `seshat-state-roots' 中 MODE 为 \"mirror\" 的根（元素 `(TAG DIR MODE)'）.
`ondemand' 根对写请求返回 403，不能作为入库目标，因此这里只筛 `mirror'。"
  (let (roots)
    (dolist (root (seshat-state-roots))
      (when (equal (nth 2 root) "mirror")
        (push root roots)))
    (nreverse roots)))

(defun seshat-reading--root-by-tag (tag roots)
  "在 ROOTS（`(TAG DIR MODE)' 列表）中按 TAG 找根；找不到返回 nil."
  (let (found)
    (dolist (root roots found)
      (when (and (null found) (equal (nth 0 root) tag))
        (setq found root)))))

(defun seshat-reading--choose-mirror-root ()
  "选择入库用的 `mirror' 根，返回 `(TAG DIR MODE)'.
没有 `mirror' 根时 `user-error' 并提示配置 `seshat-sync-roots'；只有一个
时直接返回；多个时用 `completing-read' 让用户按 TAG 选。"
  (let ((roots (seshat-reading--mirror-roots)))
    (cond
     ((null roots)
      (user-error "Seshat: 没有可写的 mirror 根，请先在 `seshat-sync-roots' 里配置"))
     ((null (cdr roots)) (nth 0 roots))
     (t
      (let* ((tags (mapcar (lambda (root) (nth 0 root)) roots))
             (tag (completing-read "入库根: " tags nil t)))
        (or (seshat-reading--root-by-tag tag roots)
            (user-error "Seshat: 未知的根 %s" tag)))))))

(defun seshat-reading--target-path (dir rel)
  "把库内相对路径 REL 拼到根目录 DIR 下并做越界校验，返回绝对路径或 nil.
拒绝：绝对路径、以 \"~\" 开头（`expand-file-name' 会展开成家目录）、Windows
盘符前缀、含 `..' 路径段的 REL、以 \"/\" 结尾（`directory-name-p'）、含连续
斜杠、归一后等于 \".\" 的 REL，以及解析后落在 DIR 之外（含**符号链接逃逸**）
或指向 DIR 内已存在目录的目标。

越界校验在本模块**内联实现**，不软依赖 `seshat-sync--local-path'：本文件
顶层只 require reader/state/rest，默认不加载 `seshat-sync'，`fboundp' 分支
会让典型路径（新会话 → `find-file' PDF → 入库）走到**没有 `file-truename'
复核**的回退分支上，于是根内软链（`evil -> ~/.ssh/authorized_keys'、
`books -> /home/u/Documents'、悬空链）就能让复制写穿到根外；悬空链时
`file-exists-p' 还返回 nil，连覆盖确认都不会弹。两套口径并存也必然漂移，
故统一走内联实现。

`file-truename' 对不存在的路径同样有效（解析已存在的祖先、其余原样保留）；
它出错时按「不安全」处理，失败方向安全。"
  (when (and (stringp rel)
             (not (string-empty-p rel))
             (not (string-prefix-p "/" rel))
             (not (string-prefix-p "~" rel))
             (not (string-match-p "\\`[A-Za-z]:" rel))
             (not (string-match-p "\\(?:\\`\\|/\\)\\.\\.\\(?:/\\|\\'\\)" rel))
             (not (directory-name-p rel))
             (not (string-match-p "/\\{2,\\}" rel))
             (not (equal "." (file-name-nondirectory
                              (directory-file-name rel)))))
    (let* ((dir* (file-name-as-directory (expand-file-name dir)))
           (expanded (expand-file-name rel dir*))
           (true-dir (ignore-errors
                       (file-name-as-directory (file-truename dir*))))
           (true-file (ignore-errors (file-truename expanded))))
      (when (and (string-prefix-p dir* expanded)
                 true-dir true-file
                 (string-prefix-p true-dir true-file)
                 (not (file-directory-p expanded)))
        expanded))))

(defun seshat-reading--write-copy (source target)
  "把 SOURCE 的字节复制到 TARGET（同目录临时文件 + `rename-file' 替换）.
**不做 `copy-file' 直写 TARGET**：`rename(2)' 替换的是 TARGET 这个目录项
本身，因此 TARGET 若是指向根外的符号链接（含悬空链，此时 `file-exists-p'
为 nil）只会被替换掉，不会穿透到链接目标去覆盖根外文件。临时文件建在
TARGET 同目录，保证 `rename-file' 是同一文件系统内的原子替换；中途出错时
临时文件被删除。"
  (let* ((temporary-file-directory (file-name-directory target))
         (tmp (make-temp-file "seshat-add-" nil ".tmp")))
    (unwind-protect
        (progn
          (copy-file source tmp t)
          (rename-file tmp target t))
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun seshat-reading--file-contents (file)
  "读取 FILE 的全部内容并返回字符串（**二进制安全**）.
用 `insert-file-contents-literally'（不编码转换、不解压、不做格式解码），
临时 buffer 先设为 unibyte：上传接口按原始字节发送，任何一次编码往返都会
破坏 PDF/EPUB。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun seshat-reading--register-library-entry (uid tag rel target etag)
  "把 UID 登记为库内文档并写盘：`(ROOT TAG :path REL)' + base blob（ETAG）.
SIZE 与 MTIME **取自复制后的目标文件 TARGET**（`file-attributes'），**不是**
原文件：`copy-file' 默认不保留 mtime，用原件属性做基线会让
`seshat-sync-detect-renames' 在下一轮立刻把该文件判为「本地已修改」并重复
推送。返回归一化后的条目。"
  (seshat-state-set uid (list :root tag :path rel))
  (let* ((attributes (file-attributes target))
         (size (nth 7 attributes))
         (mtime (truncate (float-time (nth 5 attributes)))))
    (prog1 (seshat-state-set-base-blob uid etag size mtime)
      (seshat-state-save))))

(defun seshat-reading--apply-identity-for (source &optional buffer)
  "以 SOURCE 为身份来源，在 BUFFER（缺省为访问 SOURCE 的 buffer）里刷新库身份.
用于入库成功后把调用方 buffer 的 mode-line 立刻切到 ` [库]'：入库命令读的
是**原件**（仍可能位于库外），而新登记的身份属于**库内副本**，因此这里显式
以副本路径解析，而不是让 `seshat-reading--apply-identity' 重解析原件。
BUFFER 不存活时什么也不做，返回解析出的身份 plist（或 nil）。"
  (let ((target-buffer (or buffer (seshat-reading--file-buffer source))))
    (when (buffer-live-p target-buffer)
      (with-current-buffer target-buffer
        (setq seshat-reading--identity (seshat-reading--resolve source))
        (seshat-reading--install-mode-line)
        seshat-reading--identity))))

(defun seshat-reading--drop-copy-maybe (target)
  "上传失败后询问是否删除已复制的副本 TARGET（默认保留）.
`y-or-n-p' 返回 nil（用户答「不删除」或非交互场景）时保留副本并 `message'
给出路径——原件始终不受影响，留着副本用户还能自行处理。"
  (if (y-or-n-p (format "Seshat: 上传失败，是否删除已复制的副本 %s？" target))
      (progn
        (ignore-errors (delete-file target))
        (message "Seshat: 已删除副本 %s" target))
    (message "Seshat: 已保留副本 %s（原件未被改动）" target)))

(defun seshat-reading--remote-etag (tag rel)
  "取远端 `TAG:REL' 当前内容 blob 的 ETag（**条件写令牌**），取不到就 `user-error'.
做法是一次 `seshat-rest-download-file' 到系统临时目录，只读响应头 `:etag'，
读完立刻删除临时文件（不解析内容、不碰任何本地文件）。

**不能用 `seshat-rest-versions' 的 `:head'**：`:head' 是最近一次 commit 的
hash，而 `If-Match' 比对的是**内容 blob hash**——用提交 hash 做条件写会永远
412（见 `seshat-sync.el' 对 `:rev' / `:etag' 的说明）。"
  (let ((probe-file (make-temp-file "seshat-probe-" nil ".tmp")))
    (unwind-protect
        (let ((probe (seshat-rest-download-file rel probe-file :root tag)))
          (unless (seshat-rest--2xx-p (plist-get probe :status))
            (user-error "Seshat: 取远端 %s 的 ETag 失败（HTTP %s）"
                        rel (plist-get probe :status)))
          (let ((etag (plist-get probe :etag)))
            (unless (and (stringp etag) (not (string-empty-p etag)))
              (user-error "Seshat: 远端未返回 ETag，未覆盖 %s" rel))
            etag))
      (when (file-exists-p probe-file)
        (ignore-errors (delete-file probe-file))))))

(defun seshat-reading--upload-new-entry (tag rel target)
  "把 TARGET 的内容按 REL 上传到根 TAG（仅允许创建），返回登记的 uid.
条件写用 `:if-none-match' \"*\"（远端已有同名文件 → 412）；412 时询问是否
覆盖，同意后先用 `seshat-reading--remote-etag' 取**内容 ETag** 再以
`:if-match' 重发（取不到 ETag 就中止，不猜测）。
403（只读根）、其它非 2xx、以及上传后缺 uid 的情形都 `user-error'，并把
「副本去留」交给 `seshat-reading--drop-copy-maybe'（由调用方统一处理）。
成功返回 `(UID . ETAG)'。"
  (let ((content (seshat-reading--file-contents target))
        (response nil))
    (setq response (seshat-rest-upload-file
                    rel content :root tag :if-none-match "*"))
    (when (eq (plist-get response :status) 412)
      (if (not (y-or-n-p
                "Seshat: 服务端已有同名文件，是否用远端内容版本覆盖？"))
          (user-error "Seshat: 已取消入库（远端已有同名文件，未覆盖）")
        (let ((etag (seshat-reading--remote-etag tag rel)))
          (setq response (seshat-rest-upload-file
                          rel content :root tag :if-match etag)))))
    (let ((status (plist-get response :status)))
      (cond
       ((memq status '(200 201))
        (let ((uid (plist-get response :uid)))
          (unless (and (stringp uid) (not (string-empty-p uid)))
            (user-error "Seshat: 上传成功但响应未含 uid，无法登记 %s" rel))
          (cons uid (plist-get response :etag))))
       ((eq status 403)
        (user-error "Seshat: 根 %s 是只读根（ondemand），不能入库" tag))
       (t
        (user-error "Seshat: 上传 %s:%s 失败（状态码 %s）"
                    tag rel (if (integerp status) status "无")))))))

(defun seshat-library-add (file root rel)
  "把库外文档 FILE 加入库根 ROOT 下的 REL 路径（复制上传，保留原件）.
交互调用时只读文件名（默认当前 buffer 的文件），ROOT 与 REL 在函数内部
交互收集：ROOT 取 `seshat-state-roots' 里 MODE 为 \"mirror\" 的根（多个则
`completing-read' 按 TAG 选），REL 由 `read-string' 读入（默认同名文件）。
程序化调用可直接传 ROOT（根 TAG）与 REL（库内相对路径），跳过对应提问。

执行顺序固定：
1. FILE 必须是受支持格式，且正被 `seshat-reader-mode' / `seshat-reading-mode'
   的 buffer 访问；否则 `user-error'；
2. 已在库中（本地状态解析为 `library'）→ `user-error'（含 uid）；
3. 校验 REL 未越出根目录（含符号链接逃逸、末尾斜杠、连续斜杠、`.`）→
   `make-directory' 递归建父目录；
4. 目标已存在时 `y-or-n-p' 确认覆盖，拒绝则中止（不写任何状态）；
5. `seshat-reading--write-copy' 把原件复制到目标（同目录临时文件 +
   `rename-file'，**保留原件**、不穿透目标处的软链）；
6. 读取目标内容（二进制安全）后 `seshat-rest-upload-file'
   `:if-none-match' \"*\"：2xx → 登记 uid + base blob（size/mtime **取自
   复制后的目标文件**）+ 落盘 → 刷新 mode-line 为 ` [库]'；412 → 询问是否
   覆盖，同意则取远端**内容 ETag** 以 `:if-match' 重发；403 / 其它 →
   `user-error'；
7. 上传失败时询问是否删除已复制的副本（默认保留并给出路径）。

返回新登记的 `(:uid UID :root TAG :rel REL :target PATH)'；中止或失败按上述
抛 `user-error'。本命令是**交互命令**，允许 `y-or-n-p' / `read-string'；
`seshat-reading--resolve' 与 mode 体仍不得有任何交互。"
  (interactive "fFile: ")
  (let ((file-buffer (seshat-reading--file-buffer file)))
    (unless (and (stringp file) (file-exists-p file))
      (user-error "Seshat: 找不到文件 %s" file))
    (unless (file-regular-p file)
      (user-error "Seshat: %s 不是常规文件" file))
    (let ((size (nth 7 (file-attributes file))))
      (when (and (numberp size) (> size seshat-library-add-max-bytes))
        (user-error "Seshat: %s 超过入库上限（%d 字节）"
                    file seshat-library-add-max-bytes)))
    (unless (member (downcase (or (file-name-extension file) ""))
                    seshat-reader-supported-formats)
      (user-error "Seshat: %s 不是受支持的文档格式" file))
    (unless (buffer-live-p file-buffer)
      (user-error "Seshat: 请先在 seshat-reader-mode / seshat-reading-mode 的 buffer 里打开 %s"
                  file))
    (with-current-buffer file-buffer
      (unless (derived-mode-p 'seshat-reader-mode)
        (user-error "Seshat: 当前 buffer 不是 seshat-reader-mode / seshat-reading-mode")))
    (let ((identity (seshat-reading--resolve file)))
      (when (eq (plist-get identity :state) 'library)
        (user-error "Seshat: %s 已在库中（uid %s）"
                    file (plist-get identity :uid))))
    (let* ((roots (seshat-reading--mirror-roots))
           (chosen (if (and (stringp root) (not (string-empty-p root)))
                       (or (seshat-reading--root-by-tag root roots)
                           (user-error "Seshat: 未知的根 %s" root))
                     (seshat-reading--choose-mirror-root)))
           (tag (nth 0 chosen))
           (dir (nth 1 chosen))
           (rel* (if (and (stringp rel) (not (string-empty-p (string-trim rel))))
                     (string-trim rel)
                   (let ((input (read-string "库内路径: "
                                             (file-name-nondirectory file))))
                     (when (string-empty-p (string-trim input))
                       (user-error "Seshat: 库内路径不能为空"))
                     (string-trim input))))
           (target (or (seshat-reading--target-path dir rel*)
                       (user-error "Seshat: 库内路径 %s 越出根目录 %s"
                                   rel* dir))))
      (when (file-exists-p target)
        (unless (y-or-n-p (format "Seshat: %s 已存在，是否覆盖？" target))
          (user-error "Seshat: 已取消（目标已存在）")))
      (make-directory (file-name-directory target) t)
      (seshat-reading--write-copy file target)
      (let ((registered
             (condition-case err
                 (seshat-reading--upload-new-entry tag rel* target)
               (user-error
                (seshat-reading--drop-copy-maybe target)
                (signal (car err) (cdr err)))
               (error
                (seshat-reading--drop-copy-maybe target)
                (user-error "Seshat: 入库 %s 失败：%s"
                            file (error-message-string err))))))
        (let ((uid (car registered)))
          (seshat-reading--register-library-entry
           uid tag rel* target (cdr registered))
          (seshat-reading--apply-identity-for target file-buffer)
          (message "Seshat: 已入库 %s → %s:%s（uid %s）"
                   file tag rel* uid)
          (list :uid uid :root tag :rel rel* :target target))))))

;;; 模式定义

(define-derived-mode seshat-reading-mode seshat-reader-mode "Seshat Reading"
  "Major mode for reading documents with Seshat library identity.

渲染、翻页、目录与缩放全部继承 `seshat-reader-mode'（不复制任何渲染代码，
不直接调用动态模块）；本 mode 只叠加库身份解析（**零网络**）、mode-line
标识，以及供批注静音路径使用的 buffer-local 标记
`seshat-reading--quiet-fallback'。

mode 体不做任何 I/O 循环与网络请求：首次 `seshat-state-load' 是唯一一次
磁盘读（通常几十毫秒），此后都是内存查表。

mode 体只在**父 mode 正常渲染完成**后才动手（判据是父 mode 设的
`seshat-reader-current-doc-render-status'）：文件非法时父 mode 会
`kill-buffer'，此后 `current-buffer' 已切到另一个 buffer，用
`buffer-live-p' 检查恒为真，会把 `mode-line-misc-info' 与静音标记污染到
无关 buffer 上。

Keybindings:
\\{seshat-reading-mode-map}"
  :group 'seshat-reading
  ;; 父 mode 在文件非法时会 kill-buffer，此时 current-buffer 已切换，
  ;; `buffer-live-p' 检查无效。改用它是否成功渲染作判据：只有正常完成
  ;; 的 reader buffer 才有 render-status。
  (when (bound-and-true-p seshat-reader-current-doc-render-status)
    (setq-local seshat-reading--quiet-fallback t)
    (seshat-reading--apply-identity)))

;;;###autoload
(defun seshat-reading-open (file)
  "以 `seshat-reading-mode' 打开 FILE.
FILE 必须是 `seshat-reader-mode' 能处理的文档格式（`find-file' 后按
`derived-mode-p' 判定），否则 `user-error'。已经是 `seshat-reading-mode'
的 buffer 不重复初始化。"
  (interactive "fOpen: ")
  (find-file file)
  (cond
   ((derived-mode-p 'seshat-reading-mode) nil)
   ((derived-mode-p 'seshat-reader-mode) (seshat-reading-mode))
   (t (user-error "Seshat: %s 不是受支持的文档格式" file))))

;;; auto-mode-alist 接管

(defun seshat-reading--take-over-auto-mode-alist ()
  "把 `auto-mode-alist' 中指向 `seshat-reader-mode' 的项就地改为本 mode.
遍历替换每项的 cdr，**不重拼 pattern**：reader 用什么正则，本 mode 自动
跟随，也不会产生重复项（同一 cons 被就地改写，位置与 key 都不变）。

必须在 reader 加载完成后调用（本文件顶层已完成 require），否则 reader 的
lazy-load 可能在其后再前插 `seshat-reader-mode` 项反超。"
  (dolist (entry auto-mode-alist)
    (when (eq (cdr entry) 'seshat-reader-mode)
      (setcdr entry 'seshat-reading-mode))))

(seshat-reading--take-over-auto-mode-alist)

(provide 'seshat-reading)
;;; seshat-reading.el ends here
