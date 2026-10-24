;;; seshat-state.el --- 同步状态库（uid↔path / base-blob / 游标 / dirty / 墓碑） -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: data, notes, tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块用**单个 `.eld' 文件**承载 Emacs 同步器需要的全部本地状态：
;;
;; - `:cursor'：`/api/changes?since=' 的全局 `seq' 游标（跨全部根共享，
;;   服务端只有一条全局变更流）。
;; - `:roots'：根映射，元素形如 `(TAG DIR MODE)'，`MODE' 必须与服务端
;;   `/api/roots' 对齐（`mirror' / `ondemand'）。
;; - `:uids'：uid → 条目 plist 的 alist；条目含 `:root' `:path' `:base-blob'
;;   `:size' `:mtime' `:dirty' `:deleted-at' `:orphan' 八个字段。
;; - `:paths'：`(ROOT . PATH)' → uid 的**派生索引**，可由 `:uids' 重建；
;;   持久化只是为避免每次同步都做一次 O(n) 重建，`seshat-state-load' 会校验
;;   它与 `:uids' 的一致性。
;;
;; 数据形状（顶层 plist，`prin1' 序列化）：
;;
;;   (:version 1 :cursor 0 :roots (...) :uids (...) :paths (...))
;;
;; 三条组合语义（改动本模块时必须保持）：
;;
;; 1. **remap 冲突**：uid A 改名到 uid B 已占的 `(ROOT . PATH)' 时，索引改指
;;    A，同时把 B 的 `:path' 置 nil 并标 `:orphan t'。只改索引是错的——否则
;;    `seshat-state--rebuild-paths' 会据 B 残留的旧 `:path' 把索引重新指回 B，
;;    覆盖新映射（双索引设计的数据丢失陷阱）。
;; 2. **墓碑**：`seshat-state-mark-deleted' 置 `:deleted-at'、清 `:dirty'、
;;    **保留** `:base-blob' / `:size' / `:mtime'（条件删除与「是否需重拉」判
;;    断要用）。墓碑不进 `dirty-uids'、也不占本地路径（不进 `:paths'）。
;; 3. **原子写**：同目录临时文件 + `rename-file'，写到一半崩溃不会留下损坏
;;    状态文件；正常结束后目录里只剩状态文件本身。
;;
;; 依赖方向：本模块只依赖 `cl-lib'，**不** require `seshat-rest' /
;; `seshat-sync*' / `seshat-reader-annotation-queue'（阅读器与同步器分属不同
;; 模块，原子写逻辑按计划取舍 3 有意重复而不抽公共库）。所有函数只在内存里
;; 改状态，落盘由调用方显式调 `seshat-state-save'。
;;
;; 已知限制：**不做并发保护**（单 Emacs 进程假设）。同一用户开两个 daemon 同时
;; 同步会互相覆盖状态文件，属记录在案的取舍。旧全局 head 文件
;; `~/.emacs.d/seshat-head' 不迁移，首次同步以服务端为准重建 base。

;;; Code:

(require 'cl-lib)

(defgroup seshat-state nil
  "Emacs 同步状态库。"
  :group 'data
  :prefix "seshat-state-")

(defconst seshat-state-version 1
  "状态库数据版本号.
`:version' 字段恒为此值，`seshat-state--normalize' 会把它归一化为该值；
将来升级数据形状时应同时提升此常量并在 `seshat-state-load' 内做迁移。")

(defcustom seshat-state-file
  (expand-file-name "sync-state.eld" "~/.local/share/seshat/")
  "同步状态文件的路径.

默认值为 \"~/.local/share/seshat/sync-state.eld\"（经 `expand-file-name' 展开；
路径中可用 `~' 表示主目录），与同目录的 \"annotation-queue.eld\" 保持同一
惯例。文件内容是一个 plist（结构见模块 Commentary 开头），由
`seshat-state-save' 以**同目录临时文件 + `rename-file'' 的原子替换方式写入。"
  :type 'file
  :group 'seshat-state)

(defvar seshat-state--state nil
  "内存中的状态 plist；nil 表示尚未从磁盘加载.
所有公开读写函数都经 `seshat-state--ensure' 惰性加载。测试可把它绑定为 nil
以获得干净的起点（配合把 `seshat-state-file' 绑到临时文件）。")

;;; 内存状态的构造与访问

(defun seshat-state--empty ()
  "返回空状态 plist.
形状为 `(:version 1 :cursor 0 :roots nil :uids nil :paths nil)'。"
  (list :version seshat-state-version
        :cursor 0
        :roots nil
        :uids nil
        :paths nil))

(defun seshat-state--empty-entry ()
  "返回字段齐备的空条目 plist（八个字段全为 nil）。"
  (seshat-state--normalize-entry nil))

(defun seshat-state--put (state key value)
  "返回把 STATE 的 KEY 设为 VALUE 的新状态 plist（不修改入参）.
`copy-sequence' 复制 plist 的骨架，因此随后的 `plist-put' 只改动副本。"
  (plist-put (copy-sequence state) key value))

(defun seshat-state--entry-put (entry key value)
  "返回把 ENTRY 的 KEY 设为 VALUE 的新条目 plist（不修改入参）."
  (plist-put (copy-sequence entry) key value))

(defun seshat-state--alist-put (alist key value)
  "返回把 KEY 关联到 VALUE 的新 alist.
KEY 已存在（`equal' 比较）时原位替换，否则追加到末尾，因此条目顺序稳定。"
  (let* ((replaced nil)
         (result (mapcar (lambda (cell)
                           (if (equal (car cell) key)
                               (progn (setq replaced t) (cons key value))
                             cell))
                         alist)))
    (if replaced result (append result (list (cons key value))))))

(defun seshat-state--ensure ()
  "返回当前内存状态；尚未加载时先从 `seshat-state-file' 加载。"
  (or seshat-state--state (seshat-state-load)))

(defun seshat-state--uids-where (predicate)
  "按 `:uids' 顺序返回满足 PREDICATE（接收条目 plist）的 uid 列表."
  (let (result)
    (dolist (cell (plist-get (seshat-state--ensure) :uids) (nreverse result))
      (when (funcall predicate (cdr cell))
        (push (car cell) result)))))

;;; 归一化与索引重建（纯函数）

(defun seshat-state--normalize-entry (entry)
  "返回 ENTRY 归一化后的标准条目 plist（不修改入参）.
字段固定为 `:root' `:path' `:base-blob' `:size' `:mtime' `:dirty'
`:deleted-at' `:orphan'，顺序如上；字符串字段非字符串时置 nil，数值字段
（`:size' / `:mtime' / `:deleted-at'）非数字时置 nil，布尔字段归一化为 t 或
nil。ENTRY 为 nil 时得到字段齐备的空条目。"
  (let ((root (plist-get entry :root))
        (path (plist-get entry :path))
        (blob (plist-get entry :base-blob))
        (size (plist-get entry :size))
        (mtime (plist-get entry :mtime))
        (dirty (plist-get entry :dirty))
        (deleted-at (plist-get entry :deleted-at))
        (orphan (plist-get entry :orphan)))
    (list :root (and (stringp root) root)
          :path (and (stringp path) path)
          :base-blob (and (stringp blob) blob)
          :size (and (numberp size) size)
          :mtime (and (numberp mtime) mtime)
          :dirty (and dirty t)
          :deleted-at (and (numberp deleted-at) deleted-at)
          :orphan (and orphan t))))

(defun seshat-state--normalize-roots (roots)
  "返回只保留 `(TAG DIR MODE)' 三元的根映射列表.
非三元或非正规列表的元素被丢弃（容错加载用）。"
  (let (result)
    (dolist (root (and (listp roots) roots) (nreverse result))
      (when (and (proper-list-p root) (= 3 (length root)))
        (push (list (nth 0 root) (nth 1 root) (nth 2 root)) result)))))

(defun seshat-state--normalize (state)
  "返回 STATE 归一化后的合法状态 plist（纯函数，不修改入参）.

容错规则：STATE 不是 plist（含 nil、数字、字符串、向量）时返回空状态；
缺失字段补默认值（`:version' 取 `seshat-state-version'、`:cursor' 取 0、
其余取 nil）；`:cursor' 非非负整数时置 0；`:uids' 中键不是字符串或值不是
plist 的元素丢弃，其余条目逐字段归一化；`:roots' 中非三元的元素丢弃；
`:paths' **原样保留**——它与 `:uids' 的一致性由
`seshat-state--rebuild-paths' 在 `seshat-state-load' 时校验。"
  (if (not (keywordp (car-safe state)))
      (seshat-state--empty)
    (let ((cursor (plist-get state :cursor))
          (raw-uids (plist-get state :uids))
          (raw-paths (plist-get state :paths))
          (uids nil))
      (dolist (cell (and (listp raw-uids) raw-uids))
        (when (and (consp cell) (stringp (car cell)) (listp (cdr cell)))
          (push (cons (car cell) (seshat-state--normalize-entry (cdr cell))) uids)))
      (list :version seshat-state-version
            :cursor (if (and (integerp cursor) (>= cursor 0)) cursor 0)
            :roots (seshat-state--normalize-roots (plist-get state :roots))
            :uids (nreverse uids)
            :paths (and (listp raw-paths) raw-paths)))))

(defun seshat-state--rebuild-paths (state)
  "返回把 STATE 的 `:paths' 依 `:uids' 重建后的新状态（纯函数）.
只为 `:path' 非 nil、且**无** `:orphan'、**无** `:deleted-at' 的条目建索引
（墓碑不占本地路径，孤儿没有本地路径）；同一 `(ROOT . PATH)' 出现多次时保留
`:uids' 中靠前的条目。索引顺序与 `:uids' 顺序一致，便于与磁盘内容逐项比较。"
  (let ((state (seshat-state--normalize state))
        (seen (make-hash-table :test #'equal))
        (paths nil))
    (dolist (cell (plist-get state :uids))
      (let* ((uid (car cell))
             (entry (cdr cell))
             (root (plist-get entry :root))
             (path (plist-get entry :path)))
        (when (and path
                   (not (plist-get entry :orphan))
                   (not (plist-get entry :deleted-at)))
          (let ((key (cons root path)))
            (unless (gethash key seen)
              (puthash key uid seen)
              (push (cons key uid) paths))))))
    (seshat-state--put state :paths (nreverse paths))))

(defun seshat-state--paths-equal (a b)
  "判断两个 `:paths' alist A 与 B 是否等价（忽略元素顺序）."
  (and (= (length a) (length b))
       (cl-every (lambda (cell)
                   (equal (cdr (assoc (car cell) b #'equal)) (cdr cell)))
                 a)))

;;; 批量写入

(defvar seshat-state--batch-depth 0
  "`seshat-state-batch' 的当前嵌套深度；0 表示不在批量块内.
深度大于 0 时 `seshat-state--put-entry' 跳过 `:paths' 重建（索引保持批前
形状），改由最外层批量块退出时统一重建一次。批量同步逐 uid 写 base blob
时靠它把每次写入的 O(n) 重建压成整批一次。")

(defun seshat-state--rebuild-paths-now ()
  "把内存状态的 `:paths' 依 `:uids' 就地重建一次，返回重建后的状态.
与纯函数 `seshat-state--rebuild-paths' 的区别只在副作用：本函数把重建结果
写回 `seshat-state--state'。批量写入块退出时调用它把索引一次性补齐。"
  (setq seshat-state--state
        (seshat-state--rebuild-paths (seshat-state--ensure)))
  seshat-state--state)

(defmacro seshat-state-batch (&rest body)
  "在批量写入块内执行 BODY，退出时只重建一次 `:paths'；返回 BODY 最后一个表达式的值.

批量期间 `seshat-state--batch-depth' 递增，`seshat-state--put-entry' 因此
**跳过** `:paths' 重建；`unwind-protect' 保证退出时（正常返回或出错）递减
深度，减到 0 时用 `seshat-state--rebuild-paths-now' 统一重建一次。嵌套使用时
只有最外层退出才重建（深度 2 → 1 不重建），所以嵌套块的写入同样只付出一次
O(n) 重建。

语义保证：

- **批量期间 `:paths' 不更新**：`seshat-state-uid-for-path' 与
  `seshat-state-path-for-uid' 读的是批前索引，**不保证**命中本批新写入的
  条目（已存在条目的旧映射仍能命中，本批新建或改名的路径查不到）。块内不要
  依赖这两个函数判断「本批写入是否可见」。
- **批量结束后状态与逐条写入完全一致**：退出时的那次重建按 `:uids' 顺序生成
  索引，与「每次写入都重建」的最终结果逐字段相同（含 `:paths'）。
- BODY 抛错时仍重建一次，因此不会留下「`:uids' 已更新、`:paths' 停留在批前
  形状」的半残索引；错误继续向调用方传播。
- `seshat-state-remap' **不受**本块影响：它靠实时索引做同路径冲突检测，仍然
  每次都重建索引（因此也保证 remap 的冲突语义在批量块内依然成立）。
- 块内**不要**调用 `seshat-state-save'：此时 `:paths' 还是批前形状，落盘会写出
  与 `:uids' 不一致的索引（下次 `seshat-state-load' 会按 `:uids' 重建并告警）。
  请在批量块退出后保存。"
  (declare (indent 0) (debug t))
  `(progn
     (setq seshat-state--batch-depth (1+ seshat-state--batch-depth))
     (unwind-protect
         (progn ,@body)
       (setq seshat-state--batch-depth (1- seshat-state--batch-depth))
       (when (= seshat-state--batch-depth 0)
         (seshat-state--rebuild-paths-now)))))

;;; 加载与保存

(defvar seshat-state--load-was-corrupt nil
  "最近一次 `seshat-state-load' 是否因文件损坏而回退为空状态.")

(defun seshat-state--warn (message &rest args)
  "以 `seshat-state' 类型发出一级警告.
MESSAGE 与 ARGS 交给 `format'。抽成函数只为让测试能统一桩替
`display-warning'。"
  (display-warning 'seshat-state (apply #'format message args) :warning))

(defun seshat-state--backup-corrupt (file)
  "把无法解析的状态文件 FILE 改名为 \"<FILE>.bak\".
旧备份会被覆盖（`rename-file' 第三个参数为 t）。改名失败时只发警告、保持原
文件不动——绝不静默删除用户的文件。"
  (condition-case err
      (rename-file file (concat file ".bak") t)
    (error
     (seshat-state--warn "状态文件 %s 无法改名为 .bak（%s），原文件保持不动"
                         file (error-message-string err)))))

(defun seshat-state--checked (state)
  "返回 STATE 中 `:paths' 与 `:uids' 已校准一致的状态.
不一致时以 `:uids' 重建并发出警告（`:paths' 只是派生索引，重建不会丢数据）。"
  (let ((rebuilt (seshat-state--rebuild-paths state)))
    (if (seshat-state--paths-equal (plist-get state :paths)
                                   (plist-get rebuilt :paths))
        state
      (seshat-state--warn "状态文件 %s 的 :paths 与 :uids 不一致，已按 :uids 重建索引"
                          seshat-state-file)
      rebuilt)))

(defun seshat-state--load-file (file)
  "读取 FILE 并返回校验过的状态 plist；无法读取或解析时 `error'.
顶层值必须是 plist（或 nil）且**之后不得再有内容**（多出一个 form 说明文件被
拼接或截断过），否则 `error'——由 `seshat-state-load' 转成「备份坏文件 + 空
状态」。"
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((raw (read (current-buffer))))
      (unless (or (null raw) (keywordp (car-safe raw)))
        (error "顶层值不是 plist：%S" raw))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (error "顶层 plist 之后还有多余内容：%S"
               (buffer-substring-no-properties
                (point) (min (point-max) (+ (point) 40)))))
      (seshat-state--checked (seshat-state--normalize raw)))))

(defun seshat-state-load ()
  "从 `seshat-state-file' 读取状态，装入内存并返回.

容错规则：
- 文件不存在 → 空状态（`:version 1 :cursor 0 :roots nil :uids nil
  :paths nil'），且不创建文件；
- 内容无法读取或解析（含顶层值不是 plist）→ 空状态 + 警告，并把坏文件
  **改名**为 \"<FILE>.bak\"（不静默删除，便于事后排查）；
- `:paths' 与 `:uids' 不一致 → 以 `seshat-state--rebuild-paths' 重建 + 警告。"
  (setq seshat-state--load-was-corrupt nil)
  (let* ((file seshat-state-file)
         (state (if (not (file-exists-p file))
                    (seshat-state--empty)
                  (condition-case err
                      (seshat-state--load-file file)
                    (error
                     (seshat-state--backup-corrupt file)
                     (setq seshat-state--load-was-corrupt t)
                     (seshat-state--warn "状态文件 %s 无法解析（%s），已改名为 %s.bak，按空状态继续"
                                         file (error-message-string err) file)
                     (seshat-state--empty))))))
    (setq seshat-state--state state)
    state))

(defun seshat-state-save ()
  "把当前内存状态原子写入 `seshat-state-file'，并返回写出的状态 plist.

写入前先 `seshat-state--normalize' 归一化并把 `:version' 置为
`seshat-state-version'。写入方式：`make-temp-file'（临时文件与目标文件
**同目录**，保证 `rename-file' 是同一文件系统内的原子替换）→ `write-region'
→ `rename-file'；中途失败会删除临时文件，正常结束后目录里只剩状态文件本身。
父目录不存在时自动创建。"
  (let* ((file seshat-state-file)
         (dir (file-name-directory (expand-file-name file)))
         (state (seshat-state--normalize (seshat-state--ensure)))
         (state (seshat-state--put state :version seshat-state-version)))
    (make-directory dir t)
    (let* ((temporary-file-directory dir)
           (tmp (make-temp-file "seshat-state" nil ".eld")))
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert ";; -*- mode: emacs-lisp; coding: utf-8-unix; -*-\n")
              (insert ";; Seshat 同步状态文件，由 seshat-state.el 自动生成，请勿手工编辑。\n")
              (let ((print-length nil)
                    (print-level nil)
                    (print-circle t)
                    (coding-system-for-write 'utf-8-unix))
                (prin1 state (current-buffer))
                (insert "\n")
                (write-region (point-min) (point-max) tmp nil 'silent)))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (delete-file tmp))))
    (setq seshat-state--state state)
    state))

;;; 条目读写

(defun seshat-state-get (uid)
  "返回 UID 的条目 plist；UID 未登记时返回 nil."
  (alist-get uid (plist-get (seshat-state--ensure) :uids) nil nil #'equal))

(defun seshat-state--put-entry (state uid entry)
  "返回把 UID 的条目设为 ENTRY 后的新状态.
`:paths' 的更新受 `seshat-state--batch-depth' 控制：在
`seshat-state-batch' 块内跳过重建（索引保持批前形状，由块退出时统一补一次），
不在批量块内则立即重建。"
  (let ((state (seshat-state--put
                state :uids
                (seshat-state--alist-put (plist-get state :uids) uid entry))))
    (if (> seshat-state--batch-depth 0)
        state
      (seshat-state--rebuild-paths state))))

(defun seshat-state-set (uid entry)
  "把 UID 的条目整体设为 ENTRY（plist）并同步路径索引；返回归一化后的条目.
UID 未登记时新建条目；ENTRY 缺字段时按 nil 补齐（见
`seshat-state--normalize-entry'），因此调用方只需写关心的字段。索引重建经
`seshat-state--put-entry' 完成：在 `seshat-state-batch' 块内跳过，由块退出时
统一重建一次。"
  (let ((entry (seshat-state--normalize-entry entry)))
    (setq seshat-state--state
          (seshat-state--put-entry (seshat-state--ensure) uid entry))
    (seshat-state-get uid)))

(defun seshat-state--update-entry (uid function)
  "以 FUNCTION 变换 UID 的条目、写回内存状态并返回新条目.
UID 未登记时以空条目为起点（不 `error'：调用方常先记 base-blob 再补路径）。
索引重建经 `seshat-state--put-entry' 完成，因此同样受
`seshat-state--batch-depth' 控制：在 `seshat-state-batch' 块内跳过重建。"
  (let* ((state (seshat-state--ensure))
         (entry (or (seshat-state-get uid) (seshat-state--empty-entry)))
         (new (seshat-state--normalize-entry (funcall function entry))))
    (setq seshat-state--state (seshat-state--put-entry state uid new))
    new))

;;; 复合键（root . path）双向查找

(defun seshat-state-uid-for-path (root path)
  "返回 ROOT 下相对路径 PATH 对应的 uid；无映射时返回 nil.
读派生索引 `:paths'，因此**墓碑条目与孤儿条目**（`path' 已清）不会被命中。"
  (cdr (assoc (cons root path)
              (plist-get (seshat-state--ensure) :paths)
              #'equal)))

(defun seshat-state-path-for-uid (uid)
  "返回 UID 当前占用的 `(ROOT . PATH)'；无有效路径时返回 nil.
「无有效路径」指：UID 未登记、`:path' 为 nil、条目带 `:orphan'、条目带
`:deleted-at'（与 `:paths' 索引口径一致，保证与 `seshat-state-uid-for-path'
互为反函数）。"
  (let ((entry (seshat-state-get uid)))
    (when (and entry
               (plist-get entry :path)
               (not (plist-get entry :orphan))
               (not (plist-get entry :deleted-at)))
      (cons (plist-get entry :root) (plist-get entry :path)))))

(defun seshat-state-remap (uid root new-path)
  "把 UID 记录的位置改到 `(ROOT . NEW-PATH)'，同步索引，返回冲突信息.

同路径冲突时以**新值**为准：索引改指 UID，被挤掉的旧属主的 `:path' 置 nil
并标 `:orphan t'——只改索引是不行的，否则 `seshat-state--rebuild-paths' 会据
旧属主残留的 `:path' 把索引抢回去。

返回 plist：发生冲突时为 `(:old-uid B :old-path NEW-PATH)'，无冲突时为
`(:old-uid nil :old-path nil)'；调用方据此告警，并在重新扫描时修正本地状态。

只改 `:root' / `:path' 并清 `:orphan'；`:dirty' 与 `:deleted-at' 保持原值
（「改名算不算本地改动」「墓碑是否复活」由调用方决定）。UID 未登记时新建
空条目再写入。"
  (let* ((state (seshat-state--ensure))
         (uids (plist-get state :uids))
         (entry (or (alist-get uid uids nil nil #'equal)
                    (seshat-state--empty-entry)))
         (displaced (seshat-state-uid-for-path root new-path))
         (displaced (unless (equal displaced uid) displaced))
         (entry (seshat-state--entry-put entry :root root))
         (entry (seshat-state--entry-put entry :path new-path))
         (entry (seshat-state--entry-put entry :orphan nil))
         (uids (seshat-state--alist-put uids uid
                                        (seshat-state--normalize-entry entry))))
    (when displaced
      (let ((old (or (alist-get displaced uids nil nil #'equal)
                     (seshat-state--empty-entry))))
        (setq old (seshat-state--entry-put old :path nil))
        (setq old (seshat-state--entry-put old :orphan t))
        (setq uids (seshat-state--alist-put uids displaced
                                            (seshat-state--normalize-entry old)))))
    (setq seshat-state--state
          (seshat-state--rebuild-paths (seshat-state--put state :uids uids)))
    (list :old-uid displaced :old-path (when displaced new-path))))

;;; 全局游标

(defun seshat-state-cursor ()
  "返回全局游标（`/api/changes?since=' 的 `seq'）；未设置时为 0."
  (or (plist-get (seshat-state--ensure) :cursor) 0))

(defun seshat-state-set-cursor (seq)
  "把全局游标设为 SEQ（非负整数）并返回 SEQ.
游标只增不减（空批次时服务端回传请求的 `since'，重试安全）；如需回退请显式
传入较小的值并在调用方说明理由。"
  (unless (and (integerp seq) (>= seq 0))
    (error "Seshat state: 游标必须是非负整数：%S" seq))
  (setq seshat-state--state (seshat-state--put (seshat-state--ensure) :cursor seq))
  seq)

;;; 根映射

(defun seshat-state-roots ()
  "返回根映射列表，元素形如 `(TAG DIR MODE)'."
  (plist-get (seshat-state--ensure) :roots))

(defun seshat-state-set-roots (roots)
  "设置根映射 ROOTS 并返回归一化后的列表.
每个元素必须是 `(TAG DIR MODE)' 三元组（TAG 为服务端根标签、DIR 为本地绝对
目录、MODE 为 `mirror' 或 `ondemand'，必须与服务端 `/api/roots' 对齐）；
形状非法时 `error'。"
  (let ((normalized
         (mapcar (lambda (root)
                   (unless (and (proper-list-p root) (= 3 (length root)))
                     (error "Seshat state: 根映射必须是 (TAG DIR MODE) 三元组：%S" root))
                   (list (nth 0 root) (nth 1 root) (nth 2 root)))
                 roots)))
    (setq seshat-state--state
          (seshat-state--put (seshat-state--ensure) :roots normalized))
    normalized))

;;; base blob 与 dirty

(defun seshat-state-set-base-blob (uid blob size mtime)
  "记录 UID 的 base blob：BLOB / SIZE / MTIME，并清除 dirty 标记；返回条目.
BLOB 是服务端 blob hash（乐观锁 `If-Match' 的取值），SIZE 与 MTIME 是本地
基线大小与修改时间。UID 未登记时新建条目；条目其余字段（`:root' `:path'
等）保持不变。"
  (seshat-state--update-entry
   uid
   (lambda (entry)
     (setq entry (seshat-state--entry-put entry :base-blob blob))
     (setq entry (seshat-state--entry-put entry :size size))
     (setq entry (seshat-state--entry-put entry :mtime mtime))
     (seshat-state--entry-put entry :dirty nil))))

(defun seshat-state-mark-dirty (uid)
  "把 UID 标记为本地已改（`:dirty' 置 t），返回条目.
墓碑条目即使被标脏也不会出现在 `seshat-state-dirty-uids' 的结果里。"
  (seshat-state--update-entry
   uid (lambda (entry) (seshat-state--entry-put entry :dirty t))))

(defun seshat-state-mark-clean (uid)
  "清除 UID 的 dirty 标记，返回条目."
  (seshat-state--update-entry
   uid (lambda (entry) (seshat-state--entry-put entry :dirty nil))))

(defun seshat-state-dirty-uids ()
  "返回所有脏 uid（按 `:uids' 顺序，不含墓碑条目）."
  (seshat-state--uids-where
   (lambda (entry)
     (and (plist-get entry :dirty)
          (not (plist-get entry :deleted-at))))))

;;; 墓碑

(defun seshat-state-mark-deleted (uid)
  "把 UID 标记为本地墓碑，返回条目.

置 `:deleted-at' 为当前时间戳（整数秒），**清除** `:dirty'，**保留**
`:base-blob' / `:size' / `:mtime'（条件删除与「是否需重拉」判断要用）。
墓碑不占本地路径：条目不会出现在 `seshat-state-uid-for-path' 的结果里，
也不出现在 `seshat-state-dirty-uids' 里。UID 未登记时新建条目。"
  (seshat-state--update-entry
   uid
   (lambda (entry)
     (setq entry (seshat-state--entry-put
                  entry :deleted-at (truncate (float-time))))
     (seshat-state--entry-put entry :dirty nil))))

(defun seshat-state-deleted-uids ()
  "返回所有墓碑 uid（按 `:uids' 顺序）."
  (seshat-state--uids-where (lambda (entry) (plist-get entry :deleted-at))))

(provide 'seshat-state)

;;; seshat-state.el ends here
