;;; seshat-reader-reference.el --- Seshat cross-references  -*- lexical-binding: t; -*-

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

;; 阅读器（seshat-reader）与笔记（denote org）之间的双向引用通道。
;;
;; 链接协议：`seshat:<doc-id>#<location>'，`#<location>' 可省略。
;; `doc-id' 与批注模块的 `document_id' 同源（\"<根标签>:<相对路径>\"，未命中
;; 任何已配置根时降级为 \"local:<绝对路径>\"）；`location' 与批注的
;; `location' 同源同构（\"page:<n>;rect:...\"），故链接片段可直接复用批注的
;; 位置字符串，不新增解析器。解析时只按**最后一个** `#' 分割。
;;
;; 转义不变量：`document_id' **不得包含 `#' 与 `%'**。本模块禁用任何百分号
;; 转义（`url-hexify-string' 会连 `:'、`/' 一起转义、破坏 doc-id 可读性，
;; 且 org 自身会对 `%' 二次转义，双重转义不自洽），因此生成链接时一旦发现
;; `#'/`%' 即 `user-error' 并提示重命名文档；解析端据此只需「最后一个 `#'
;; 分割」这一条规则，行为可完全断言。
;;
;; 与批注模块的关系：本模块不自造位置表示，`location' 的构造
;; （`seshat-reader-annotation--location'）与页码解析
;; （`seshat-reader-annotation--page-from-location'）都直接复用
;; `seshat-reader-annotation'，两处口径始终一致。
;;
;; 本文件是**本仓库自研扩展**：从上游 vendor 重拷 seshat-reader 时应保留本
;; 文件、不得覆盖（vendor 边界见同目录 VENDORED.md）。
;;
;; `org' 为**软依赖**：`(require 'org nil t)'，未加载 org 时本模块仍可加载，
;; 只是链接注册（`:follow' / `:store' / `:complete' / `:export'）与
;; `org-store-link' 集成不可用。

;;; Code:

(require 'seshat-reader-annotation)
(require 'org nil t)

;; 离线队列模块在加载时会 `(require 'seshat-reader-annotation)'，故本文件不在
;; 顶部 require 它（避免循环 require）；改为声明其公开函数，并在真正需要时
;; 于函数体内 `require'（Emacs 会缓存 feature，重复 require 只是一次查表）。
(declare-function seshat-reader-annotation-queue-entries "seshat-reader-annotation-queue")
;; 位置计算用到的 org / outline API（签名已用 `elisp-describe-function' 核实：
;; `org-back-to-heading' 见 `org.el:21369'，可选 INVISIBLE-OK，失败 `user-error'；
;; `outline-next-heading' 见 `outline.el'，无参）。
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-outline-level "org" ())
(declare-function outline-next-heading "outline" ())

(defgroup seshat-reader-reference nil
  "笔记与阅读器之间的 `seshat:' 链接协议与摘录插入."
  :group 'seshat-reader
  :prefix "seshat-reader-reference-")

(defcustom seshat-reader-reference-target-file nil
  "摘录/引用写入的目标 org 笔记文件.
为 nil 时 `seshat-reader-reference-insert' 交互询问落点文件，并把所选文件
`setq' 到本变量（**仅会话内记忆**，不写回用户配置文件）；也可直接设为固定
文件路径（可含 `~'）。插入位置由
`seshat-reader-reference-insert-position' 决定（默认仍为文件末尾）。"
  :type '(choice (const :tag "每次交互选择" nil)
                 (file :tag "固定目标文件"))
  :group 'seshat-reader-reference)

(defcustom seshat-reader-reference-insert-position 'end-of-file
  "摘录写入目标笔记文件时的插入位置.
- `end-of-file'：插入到文件末尾（默认值，与历史行为完全一致）。
- `headline'：插入到「当前 headline 子树的末尾」——即整个子树（含其全部
  子标题）之后、下一个同级或更高级 headline 之前的位置；判定用 org 既有 API
  （`org-back-to-heading' + `org-outline-level' + `outline-next-heading'），
  详见 `seshat-reader-reference--insert-position'。
- `point'：插入到目标文件 visiting buffer 中 `point' 所在位置。

**回退规则**（三种模式共用）：位置计算只在目标文件存在 visiting buffer
（`find-buffer-visiting' 命中）时才有可能生效。`headline' / `point' 在没有
visiting buffer 时无从得知「当前 headline」与光标，一并回退为
`end-of-file'（即 `append-to-file' 追加到末尾，**不为支持新语义强行打开
文件**，避免产生用户未预期的 buffer 与文件锁）；此外 `headline' 在 org 未
加载、或光标位于第一个 headline 之前、或 buffer 内没有任何 headline 时
同样回退。"
  :type '(choice (const :tag "文件末尾" end-of-file)
                 (const :tag "当前 headline 子树末尾" headline)
                 (const :tag "visiting buffer 的光标处" point))
  :group 'seshat-reader-reference)

(defcustom seshat-reader-reference-format
  "#+begin_quote\n%s\n#+end_quote\n来源：[[%s][%s]]\n"
  "摘录块模板，三个 `%s' 依次为正文文本、链接与链接描述.
由 `seshat-reader-reference--format-block' 用 `format' 代入；正文为空时以
空串填充。默认值是一个 org 引用块加一行带描述的来源链接。"
  :type 'string
  :group 'seshat-reader-reference)

;;; 纯函数层

(defun seshat-reader-reference--doc-id-check-encodable (doc-id)
  "校验 DOC-ID 可承载于 `seshat:' 链接，通过时原样返回.
DOC-ID 为 nil、空串、非字符串或含 `#'/`%' 时以 `user-error' 报错：消息含
「不支持」与「重命名」指引，并把违规字符串原样放进消息便于定位。不使用
`url-hexify-string' 等转义手段（理由见 Commentary 的转义不变量）。"
  (cond
   ((not (stringp doc-id))
    (user-error "Seshat Reader reference: 文档标识 %S 不是字符串，不支持生成链接；请重命名文档后重试"
                doc-id))
   ((string-empty-p doc-id)
    (user-error "Seshat Reader reference: 文档标识为空，不支持生成链接；请重命名文档后重试"))
   ((string-match-p "[#%]" doc-id)
    (user-error "Seshat Reader reference: 文档标识 %s 含不支持的字符 `#' 或 `%%'，请重命名文档后重试"
                doc-id))
   (t doc-id)))

(defun seshat-reader-reference--link (doc-id &optional location)
  "由 DOC-ID 与可选 LOCATION 构造 `seshat:' 链接字符串.
DOC-ID 先经 `seshat-reader-reference--doc-id-check-encodable' 校验。LOCATION
非空（非 nil 且非空串）时以 `#' 追加到链接末尾，否则只返回整篇文档的链接。"
  (let ((base (concat "seshat:"
                      (seshat-reader-reference--doc-id-check-encodable doc-id))))
    (if (and (stringp location) (not (string-empty-p location)))
        (concat base "#" location)
      base)))

(defun seshat-reader-reference--parse-link (link)
  "把 LINK 解析为 plist `(:doc-id DOC :location LOC)'，非法时返回 nil.
LINK 可带或不带 \"seshat:\" 前缀；剥掉前缀后按**最后一个** `#' 分割为
doc-id 与 location（`#' 本身不接受转义，见 Commentary）。无 `#'' 时
`:location' 为 nil，但该键仍然存在，便于调用方用 `plist-get' 判定。
LINK 非字符串、剥前缀后为空、或 `#' 之前的 doc-id 为空时返回 nil。

尾部裸 `#'（location 为空串，如 \"seshat:ebook:a.pdf#\"）归一为 nil：空
location 与「无 location」语义相同，两种写法解析结果一致。"
  (when (stringp link)
    (let ((s (if (string-prefix-p "seshat:" link)
                 (substring link (length "seshat:"))
               link)))
      (cond
       ((string-empty-p s) nil)
       ((string-match "#\\([^#]*\\)\\'" s)
        (let ((doc-id (substring s 0 (match-beginning 0)))
              (loc (match-string 1 s)))
          (unless (string-empty-p doc-id)
            (list :doc-id doc-id
                  :location (and (not (string-empty-p loc)) loc)))))
       (t (list :doc-id s :location nil))))))

(defun seshat-reader-reference--file-from-doc-id (doc-id)
  "把 DOC-ID 反解析为本地绝对文件路径；无法解析时返回 nil.
\"local:\" 前缀的 DOC-ID 直接取冒号之后的绝对路径。否则按
\"<标签>:<相对路径>\" 拆分，在 `seshat-reader-annotation-roots' 中用
`string=' 按标签查找根目录，命中时用 `expand-file-name' 把相对路径拼到根
目录下。标签不在 `seshat-reader-annotation-roots' 中、或 DOC-ID 不符合上述
两种形式时返回 nil。"
  (when (stringp doc-id)
    (cond
     ((string-prefix-p "local:" doc-id)
      (substring doc-id (length "local:")))
     ((string-match "\\`\\([^:]+\\):\\(.+\\)\\'" doc-id)
      (let* ((tag (match-string 1 doc-id))
             (rel (match-string 2 doc-id))
             (entry (seq-find (lambda (e) (string= (car e) tag))
                              seshat-reader-annotation-roots)))
        (when entry
          (expand-file-name rel (expand-file-name (cdr entry)))))))))

;;; 链接补全候选（`:complete' 的数据层）

(defun seshat-reader-reference--doc-file-regexp ()
  "返回匹配受支持文档文件名的正则；扩展名列表不可得时返回 nil.
扩展名列表复用 variable `seshat-reader-supported-formats'（**软依赖**：
未加载时先 `(require \\='seshat-reader nil t)' 试探，仍不可得则返回 nil，由
调用方放弃补全而不是自行维护一份格式清单）。"
  (let ((formats (or (and (boundp 'seshat-reader-supported-formats)
                          (symbol-value 'seshat-reader-supported-formats))
                     (progn
                       (require 'seshat-reader nil t)
                       (and (boundp 'seshat-reader-supported-formats)
                            (symbol-value 'seshat-reader-supported-formats))))))
    (when formats
      (concat "\\.\\(?:" (regexp-opt formats) "\\)\\'"))))

(defun seshat-reader-reference--complete-link ()
  "返回 `seshat:' 链接的补全候选：去重、按字典序排序的 doc-id 列表.
候选枚举 `seshat-reader-annotation-roots' 中每个根目录下受支持的文档文件
（扩展名正则见 `seshat-reader-reference--doc-file-regexp'），doc-id 一律由
`seshat-reader-annotation--doc-id' 派生（**不自行拼接路径**，保证与批注模块
的 doc-id 同源）。含 `#'/`%' 的 doc-id 无法承载于链接（见 Commentary），
直接剔除。

当前缓冲区处于 `seshat-reader-mode' 且其 doc-id 已在候选中时，该 doc-id 被
移到首位（其余保持字典序）；不在候选中则不添加。根列表为空、格式列表不可
得、目录不存在/不可读、无匹配文档时返回 nil，**不报错**。

本期**只补 doc-id**，不构造 `#page:<n>' 位置片段（位置插入语义见摘录任务）。"
  (let ((regexp (seshat-reader-reference--doc-file-regexp))
        (ids nil))
    (when regexp
      (dolist (entry seshat-reader-annotation-roots)
        (let ((dir (expand-file-name (cdr entry))))
          (when (and (file-directory-p dir) (file-readable-p dir))
            (dolist (file (ignore-errors
                            (directory-files-recursively dir regexp nil t)))
              (let ((id (seshat-reader-annotation--doc-id file)))
                (when (and (stringp id)
                           (not (string-empty-p id))
                           (not (string-match-p "[#%]" id)))
                  (push id ids))))))))
    (let* ((sorted (delete-dups (sort ids #'string<)))
           (current (and (derived-mode-p 'seshat-reader-mode)
                         (buffer-file-name)
                         (seshat-reader-annotation--doc-id
                          (buffer-file-name)))))
      (if (and current (member current sorted))
          (cons current (delete current sorted))
        sorted))))

(defun seshat-reader-reference--description (doc-id &optional location)
  "为 DOC-ID 与可选 LOCATION 生成人类可读的链接描述.
页取自 `seshat-reader-annotation--page-from-location'（1-based）；文件名取
DOC-ID 中第一个 `:' 之后部分的 `file-name-nondirectory'（`local:' 前缀的
DOC-ID 因此取绝对路径为其后的部分）。页非 nil 时返回 \"<文件名> 第 <页>
页\"，否则只返回文件名。"
  (let* ((page (seshat-reader-annotation--page-from-location location))
         (rest (if (and (stringp doc-id) (string-match ":" doc-id))
                   (substring doc-id (1+ (match-beginning 0)))
                 (or doc-id "")))
         (name (file-name-nondirectory rest)))
    (if page
        (format "%s 第 %d 页" name page)
      name)))

(defun seshat-reader-reference--format-block
    (text doc-id &optional location description)
  "把 TEXT 与 DOC-ID（及可选 LOCATION、DESCRIPTION）组装为摘录块字符串.
链接由 `seshat-reader-reference--link' 生成；DESCRIPTION 为空时用
`seshat-reader-reference--description' 现算。最终按
`seshat-reader-reference-format' 用 `format' 代入正文 / 链接 / 描述三个
占位符，TEXT 为 nil 时以空串填充。"
  (let ((link (seshat-reader-reference--link doc-id location))
        (desc (or description
                  (seshat-reader-reference--description doc-id location))))
    (format seshat-reader-reference-format (or text "") link desc)))

(defun seshat-reader-reference--summary (text)
  "把 TEXT 压缩为单行摘要（薄封装，复用批注模块的实现）.
之所以**直接复用** `seshat-reader-annotation--summary'，是为了让摘录与批注
的摘要口径（去换行 / 回车 / 制表符并按宽度截断）完全一致，避免两套实现
各自漂移。"
  (seshat-reader-annotation--summary text))

(defun seshat-reader-reference--insert-position (mode)
  "在当前 buffer 中按 MODE 计算摘录的插入位置，返回整数 position.
MODE 的取值语义与 `seshat-reader-reference-insert-position' 一致：

- `point'：返回当前 `point'。
- `headline'：返回 `point' 所在 headline **子树的末尾**（下一个同级或更高级
  headline 之前，即整个子树——含其全部子标题——之后）。一律用 org 既有 API
  计算，不自行解析星号：`org-back-to-heading'（`org.el:21369'，可选
  INVISIBLE-OK，本调用传 t；point 在第一个 headline 之前时抛 `user-error'）
  先回到所在 headline，`org-outline-level'（无参，返回当前 headline 的星号
  数）取当前层级，再用 `outline-next-heading'（`outline.el'，无参，移动到
  下一个 headline 行首、无下一个时到 `point-max'）逐级前进，直到层级**不深于**
  当前层级或到达 `point-max'——该位置正是子树边界。org 未加载（`featurep'
  对 `org' 返回 nil）、**当前 buffer 不是 org-mode**（`derived-mode-p'
  对 `org-mode' 返回 nil——org 已加载但本 buffer 是 Markdown / 纯文本时
  星号行未必是 headline，不能按 org 规则解析）、上述调用抛错（如 point 位于
  第一个 headline 之前、buffer 内无 headline、`outline-regexp' 不可用）时
  回退 `(point-max)'。
- 其它任何值（含默认的 `end-of-file' 与未知值）：返回 `(point-max)'。

本函数**只做当前 buffer 内的位置计算**：不读写文件、不插入文本、不切换
buffer、不移动 `point'（`save-excursion' 保证）。「目标文件无 visiting buffer」
这一层的回退由调用方 `seshat-reader-reference--insert-into-file' 负责（直接
`append-to-file'）。抽成独立函数是为了让 ERT 能在 batch 下直接断言三种模式
的位置计算。"
  (pcase mode
    ('point (point))
    ('headline
     ;; 双重守卫：org 已加载**且**当前 buffer 处于 org-mode（含派生 mode）才走
     ;; org API。只看 `featurep' 不够——org 已加载但当前 buffer 是 Markdown /
     ;; 纯文本时，`org-back-to-heading' 会按 org 的 `outline-regexp' 匹配星号
     ;; 行，可能把非 org 文档的 `* ' 列表项误认成 headline。
     (if (not (and (featurep 'org) (derived-mode-p 'org-mode)))
         (point-max)
       (or (condition-case nil
               (save-excursion
                 (org-back-to-heading t)
                 (let ((level (org-outline-level)))
                   ;; 跳过更深的子标题：只在层级不深于当前层级时停下
                   (while (and (outline-next-heading)
                               (not (eobp))
                               (> (org-outline-level) level)))
                   (point)))
             (error nil))
           (point-max))))
    (_ (point-max))))

(defun seshat-reader-reference--read-target-file ()
  "返回摘录应写入的目标文件路径.
`seshat-reader-reference-target-file' 非空时展开并直接返回；为空时用
`read-file-name' 交互选择，起点取 variable `denote-directory'（经
`bound-and-true-p' 探测——**不得**直接引用该变量，否则 denote 未加载时会
`void-variable' 崩溃）并兜底为 `default-directory'。选择结果 `setq' 回
`seshat-reader-reference-target-file'，仅会话内记忆，不写回用户配置文件。"
  (if seshat-reader-reference-target-file
      (expand-file-name seshat-reader-reference-target-file)
    (let ((file (read-file-name
                 "摘录写入文件: "
                 (or (bound-and-true-p denote-directory) default-directory))))
      (setq seshat-reader-reference-target-file file)
      file)))

(defun seshat-reader-reference--insert-into-file (text file)
  "把 TEXT 写入 FILE 的插入位置（由 `seshat-reader-reference-insert-position' 指定）.
TEXT 先补齐换行结尾（缺失时补一个换行）。FILE 已有关联 buffer（visiting
buffer）时在该 buffer 中插入到 `seshat-reader-reference--insert-position' 按
`seshat-reader-reference-insert-position' 算出的位置：插入前 buffer 无未保存
修改则 `save-buffer'，否则只 `message' 提示用户自行保存（不静默覆盖用户未保存
的改动）。FILE 无关联 buffer 时用 `append-to-file' 直接追加到末尾——此时
`headline' / `point' 一律按 `end-of-file' 语义处理，**不为支持它们强行打开
文件**（避免副作用）。返回 FILE。"
  (let* ((payload (if (string-suffix-p "\n" text) text (concat text "\n")))
         (buf (find-buffer-visiting file))
         (modified (and buf (buffer-modified-p buf))))
    (if buf
        (with-current-buffer buf
          (goto-char (seshat-reader-reference--insert-position
                      seshat-reader-reference-insert-position))
          (insert payload)
          (if modified
              (message "Seshat Reader reference: 目标文件有未保存修改，请在插入后自行保存：%s"
                       file)
            (save-buffer)))
      (append-to-file payload nil file))
    file))

;;; 链接注册与 :follow / :store / :complete

(defun seshat-reader-reference-open (path &optional _arg)
  "打开 PATH 指向的文档并跳到链接记录的位置.
PATH 为 `seshat:' 链接的路径部分（可带或不带 \"seshat:\" 前缀），本函数是
`org-link-set-parameters' 的 `:follow' 处理函数。解析出的 doc-id 经
`seshat-reader-reference--file-from-doc-id' 反解析为本地绝对路径；doc-id
无法解析、标签未知或文件不存在时 `user-error'。

打开文档时优先复用已存在且 major-mode 为 `seshat-reader-mode' 的 buffer：
用 `find-buffer-visiting'（它会做路径规范化），**不用** `get-file-buffer'
（其精确字符串匹配会因路径归一化差异而静默失效）；未命中复用条件时调用
`seshat-reader-open-doc' 新开文档。location 含 `page:<n>' 时用
`seshat-reader-goto-page' 跳到该 1-based 页（**不再加 1**）；`rect:' 部分
不产生任何 UI 动作（本模块无高亮能力，rect 仅承载信息）。

可选 _ARG 为 org `:follow' 传入的前缀参数，本实现忽略。"
  (let* ((link (if (string-prefix-p "seshat:" path)
                   path
                 (concat "seshat:" path)))
         (parsed (seshat-reader-reference--parse-link link))
         (doc-id (plist-get parsed :doc-id)))
    (unless doc-id
      (user-error "Seshat Reader reference: 链接格式非法，无法解析：%s" path))
    (let ((file (seshat-reader-reference--file-from-doc-id doc-id)))
      (unless file
        (user-error "Seshat Reader reference: 未在 `seshat-reader-annotation-roots' 中找到标签，或链接格式非法：%s"
                    doc-id))
      (unless (file-exists-p file)
        (user-error "Seshat Reader reference: 文档不存在：%s" file))
      (let ((buf (find-buffer-visiting file)))
        (if (and buf
                 (eq (buffer-local-value 'major-mode buf) 'seshat-reader-mode))
            (pop-to-buffer buf)
          (seshat-reader-open-doc file)))
      (let ((page (seshat-reader-annotation--page-from-location
                   (plist-get parsed :location))))
        (when page
          (seshat-reader-goto-page page))))))

(defun seshat-reader-reference-store-link (&optional _interactive)
  "为 `org-store-link' 生成当前阅读位置的 `seshat:' 链接并返回 t.
仅在 `seshat-reader-mode' 缓冲区中可用，否则 `user-error' 说明用法。文档
标识由 variable `buffer-file-name' 经 `seshat-reader-annotation--doc-id' 派生；
location 优先取最近一次选区（`seshat-reader-select-last'，其 `:file' 须与
当前文件等价且 `:page'/`:rect' 齐备）构造的完整位置，否则退化为
\"page:<n>\"（此时若 `seshat-reader-current-doc-pagenumber' 取不到整数页码，
说明当前缓冲区不是阅读器视图，`user-error' 提示先打开文档）。描述在有选区
文本时用 `seshat-reader-reference--summary'，否则用
`seshat-reader-reference--description'。

可选 _INTERACTIVE 被忽略，仅为满足 org 9.7+ 对 `:store' 的首选单参签名。"
  (unless (derived-mode-p 'seshat-reader-mode)
    (user-error "Seshat Reader reference: `org-store-link' 仅在 seshat-reader 阅读缓冲区中可用"))
  (let* ((file (buffer-file-name))
         (doc-id (seshat-reader-annotation--doc-id file))
         (selection seshat-reader-select-last)
         (location (if (and selection
                            (plist-get selection :file)
                            (plist-get selection :page)
                            (plist-get selection :rect)
                            (file-equal-p (plist-get selection :file) file))
                       (seshat-reader-annotation--location
                        (plist-get selection :page)
                        (plist-get selection :rect))
                     (let ((page (seshat-reader-current-doc-pagenumber)))
                       (unless (integerp page)
                         (user-error "Seshat Reader reference: 当前缓冲区不是阅读器视图，无法确定页码，请先在阅读器中打开文档"))
                       (format "page:%d" page))))
         (text (and selection (plist-get selection :text)))
         (desc (if (and (stringp text)
                        (not (string-empty-p (string-trim text))))
                   (seshat-reader-reference--summary text)
                 (seshat-reader-reference--description doc-id location)))
         (link (seshat-reader-reference--link doc-id location)))
    (org-link-store-props :type "seshat" :link link :description desc)
    t))

(defun seshat-reader-reference-complete-link (&optional _arg)
  "为 `seshat:' 链接提供补全并返回**完整的链接字符串**.
本函数是 `org-link-set-parameters' 的 `:complete' 处理函数，按 org 的
约定（`org-link-parameters' 的 `:complete' 条目）接收**一个可选前缀参数**，
返回值为完整链接字符串（含 \"seshat:\" 前缀），插入动作由 `org-insert-link'
完成；它不返回候选列表，也不是 `completion-at-point' 函数。

候选由 `seshat-reader-reference--complete-link' 生成（roots 下的 doc-id，
去重排序、当前文档优先）；无候选时退回 `read-string'，初值 \"seshat:\"，
与 org 对无补全支持类型的兜底行为（`org-link--try-special-completion'）
一致。可选 _ARG 被忽略。"
  (let ((candidates (seshat-reader-reference--complete-link)))
    (if candidates
        (concat "seshat:" (completing-read "Seshat 文档: " candidates nil t))
      (read-string "Seshat 链接: " "seshat:"))))

(defun seshat-reader-reference-export-link (path desc format &optional _backend)
  "把 `seshat:' 链接导出为**人类可读文本**，供 org 导出后端调用.
本函数是 `org-link-set-parameters' 的 `:export' 处理函数。**实读本机 org 9.8.7
源码确认的契约**——`ol.el.gz:119-128'（`:export' 的属性说明）：「Function that
accepts four arguments: the path, as a string, the description as a string, or
nil, the export backend, the export communication channel, as a plist」，
且「When nil, export for that type of link is delegated to the backend」；
调用点 `org-export-custom-protocol-maybe'（`ox.el.gz:4352-4377'）以
`(funcall protocol path desc backend info)' 调用，遇 `wrong-number-of-arguments'
再按 3 参重试（兼容 org < 9.4 的旧式处理函数），故第 4 参数声明为可选。
其返回值非 nil 时**优先于后端自身的链接转义**（调用点例：`ox-html.el.gz:3374'
`(org-export-custom-protocol-maybe link desc \\='html info)'、`ox-md.el.gz:576'、
`ox-latex.el.gz:3089'、`ox-ascii.el.gz:1591'），返回 nil 则交回后端——本实现
**恒返回字符串**，从不返回 nil。

PATH 为链接路径（允许缺 \"seshat:\" 前缀，本函数自行补齐后解析）；DESC 为
链接描述，非空时**原样采用**，为空或 nil 时用
`seshat-reader-reference--description' 现算（\"<文件名> 第 <页> 页\"）——与
摘录块、`:store' 的描述同源，**不重写一份**逻辑。FORMAT 为导出后端符号
（常见取值 `html' / `latex' / `ascii' / `md' / `texinfo' / `odt' / `org'，也可能
为 nil），本实现**对所有后端输出同一份纯文本**，不按后端区分；可选 _BACKEND
为导出通信通道 plist，忽略。

取舍（**有意如此，不是遗漏**）：本实现不生成可点击的跨文档 URL——`seshat:'
链接指向本机书库里的 PDF 与其页码，没有稳定的服务端 URL 方案，凭空拼一个
`http://...' 式的假链接比纯文本更有害（下游读者点开即 404）。因此 `:export'
的职责收敛为「把协议串变成人能读的描述」，不承担定位跳转。

PATH 无法解析（非字符串、空串、剥掉 `#' 后 doc-id 为空）时**不报错**，退回
原始文本 \"seshat:<path>\"：一个坏链接不应让整份导出失败。"
  (let ((parsed (seshat-reader-reference--parse-link
                 (if (and (stringp path) (string-prefix-p "seshat:" path))
                     path
                   (concat "seshat:" (if (stringp path) path ""))))))
    ;; FORMAT 不参与计算（所有后端输出同一份纯文本，见 docstring 的取舍）；
    ;; 显式 `ignore' 以避免 byte-compile 的「未使用词法参数」告警。
    (ignore format)
    (cond
     ((not parsed) (concat "seshat:" (if (stringp path) path "")))
     ((and (stringp desc) (not (string-empty-p desc))) desc)
     (t (seshat-reader-reference--description (plist-get parsed :doc-id)
                                              (plist-get parsed :location))))))

;; 注册 `seshat:' 链接类型：`:follow' 收 (path arg)、`:store' 收
;; (interactive?)、`:complete' 收可选前缀参数并返回完整链接字符串、
;; `:export' 收 (path desc backend info) 并返回可读文本（契约与取舍见
;; `seshat-reader-reference-export-link' 的 docstring）。放在
;; `with-eval-after-load 'org' 中，保证 org 就绪时才注册且只注册一次。
(with-eval-after-load 'org
  (org-link-set-parameters "seshat"
                           :follow #'seshat-reader-reference-open
                           :store #'seshat-reader-reference-store-link
                           :complete #'seshat-reader-reference-complete-link
                           :export #'seshat-reader-reference-export-link))

;;; 交互命令

(defun seshat-reader-reference--current-doc-id ()
  "(internal) 返回当前缓冲区所关联文件的文档标识.
variable `buffer-file-name' 为 nil 时 `user-error'，否则交给
`seshat-reader-annotation--doc-id' 派生；供下面的交互命令与 T6 的批注引用
复用。"
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Seshat Reader reference: 当前缓冲区没有关联文件，无法派生文档标识"))
    (seshat-reader-annotation--doc-id file)))

(defun seshat-reader-reference--current-location ()
  "(internal) 返回当前阅读位置的 `location' 字符串.
优先使用最近一次鼠标选区（`seshat-reader-select-last'）：其 `:file' 与 variable
`buffer-file-name' 等价（`file-equal-p'）且 `:page'/`:rect' 齐备时返回
`seshat-reader-annotation--location' 构造的完整位置（与批注 location 同构）；
否则退化为 \"page:<n>\"，其中 <n> 取 `seshat-reader-current-doc-pagenumber'
（已是 1-based，**不再加 1**）。

当前缓冲区不是阅读器视图（`seshat-reader-current-doc-pagenumber' 取不到整数
页码）时 `user-error'，提示先在阅读器中打开文档，而不是抛出
`wrong-type-argument'。"
  (let ((selection seshat-reader-select-last)
        (file (buffer-file-name)))
    (if (and selection
             file
             (plist-get selection :file)
             (plist-get selection :page)
             (plist-get selection :rect)
             (file-equal-p (plist-get selection :file) file))
        (seshat-reader-annotation--location (plist-get selection :page)
                                            (plist-get selection :rect))
      (let ((page (seshat-reader-current-doc-pagenumber)))
        (unless (integerp page)
          (user-error "Seshat Reader reference: 当前缓冲区不是阅读器视图，无法确定页码，请先在阅读器中打开文档"))
        (format "page:%d" page)))))

(defun seshat-reader-reference-copy-link ()
  "把当前阅读位置对应的 `seshat:' 链接复制到 `kill-ring' 并提示.
链接由 `seshat-reader-reference--link' 用当前文档标识与当前阅读位置
（`seshat-reader-reference--current-location'）构造。"
  (interactive)
  (let ((link (seshat-reader-reference--link
               (seshat-reader-reference--current-doc-id)
               (seshat-reader-reference--current-location))))
    (kill-new link)
    (message "Seshat Reader reference: 已复制链接 %s" link)))

(defun seshat-reader-reference-insert (&optional body)
  "把选区文本（或当前页）作为摘录插入目标笔记文件.
BODY 为摘录正文；去空白后非空时使用它，否则回退到最近一次选区的 `:text'
（`seshat-reader-select-last'），两者皆空时正文为空串——允许只插链接。
交互调用不带前缀参数时直接使用选区文本，带前缀参数（`C-u'）时在迷你缓冲区
读取正文。

摘录块由 `seshat-reader-reference--format-block' 按
`seshat-reader-reference-format' 组装，写入
`seshat-reader-reference--read-target-file' 返回的文件，**插入位置**由
`seshat-reader-reference-insert-position' 决定（默认文件末尾；`headline' /
`point' 需目标文件已有 visiting buffer，否则回退文件末尾）。完成后 `message'
报告目标文件与写入字符数。"
  (interactive (list (when current-prefix-arg (read-string "摘录正文: "))))
  (let* ((selection seshat-reader-select-last)
         (text (if (and (stringp body)
                        (not (string-empty-p (string-trim body))))
                   body
                 (and selection (plist-get selection :text))))
         (doc-id (seshat-reader-reference--current-doc-id))
         (location (seshat-reader-reference--current-location))
         (block (seshat-reader-reference--format-block text doc-id location))
         (file (seshat-reader-reference--read-target-file)))
    (seshat-reader-reference--insert-into-file block file)
    (message "Seshat Reader reference: 已写入 %s（%d 字符）"
             file (length block))))

(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-c C-r")
              #'seshat-reader-reference-insert))

(defun seshat-reader-reference-insert-annotation ()
  "把批注列表当前行对应的批注引用插入目标笔记文件.
本命令**仅能在 `seshat-reader-annotation-list-mode' 缓冲区（即
`*Seshat Annotations*'）中使用**，否则 `user-error' 并说明用法。

批注正文取自当前行（`line-beginning-position'）的文本属性：服务端批注按其
`seshat-reader-annotation-id' 在 buffer-local
`seshat-reader-annotation-list-entries' 中匹配取 `text'；本地待同步项按其
`seshat-reader-annotation-queue-uuid' 在 `seshat-reader-annotation-queue-entries'
中匹配取 `:text'。两条路径都**不发起任何网络请求**。

位置取自行的 `seshat-reader-annotation-location' 文本属性；缺失时退化为
\"page:<n>\"（<n> 取自行的 `seshat-reader-annotation-page'），二者皆缺时
`user-error'。引用块由 `seshat-reader-reference--format-block' 组装，写入
`seshat-reader-reference--read-target-file' 返回的文件；完成后 `message'
报告目标文件、写入字符数与批注页码，便于用户核对。"
  (interactive)
  (unless (derived-mode-p 'seshat-reader-annotation-list-mode)
    (user-error "Seshat Reader reference: 该命令只能在批注列表缓冲区（*Seshat Annotations*）中使用，请先用 `seshat-reader-annotation-list' 打开批注列表"))
  (let* ((pos (line-beginning-position))
         (id (get-text-property pos 'seshat-reader-annotation-id))
         (uuid (get-text-property pos 'seshat-reader-annotation-queue-uuid))
         (location (get-text-property pos 'seshat-reader-annotation-location))
         (page (get-text-property pos 'seshat-reader-annotation-page))
         (document-id seshat-reader-annotation-list-document-id))
    (unless (or id uuid)
      (user-error "Seshat Reader reference: 当前行没有关联批注，无法生成引用"))
    (let* ((text (cond
                  (id
                   (alist-get
                    'text
                    (seq-find
                     (lambda (entry)
                       (let ((entry-id (alist-get 'id entry)))
                         (and entry-id
                              (string= (format "%s" entry-id)
                                       (format "%s" id)))))
                     seshat-reader-annotation-list-entries)))
                  (uuid
                   (require 'seshat-reader-annotation-queue)
                   (plist-get
                    (seq-find
                     (lambda (e)
                       (let ((e-uuid (plist-get e :uuid)))
                         (and e-uuid
                              (string= (format "%s" e-uuid)
                                       (format "%s" uuid)))))
                     (seshat-reader-annotation-queue-entries))
                    :text))
                  (t nil)))
           (loc (cond
                 ((and (stringp location) (not (string-empty-p location))) location)
                 ((integerp page) (format "page:%d" page))
                 (t (user-error "Seshat Reader reference: 当前行缺少位置信息，无法生成引用"))))
           (block (seshat-reader-reference--format-block text document-id loc))
           (file (seshat-reader-reference--read-target-file))
           (page-n (seshat-reader-annotation--page-from-location loc)))
      (seshat-reader-reference--insert-into-file block file)
      (message "Seshat Reader reference: 已从批注写入 %s（%d 字符，%s）"
               file (length block)
               (if page-n (format "page:%d" page-n) loc)))))

;; 批注列表 buffer 的 `C-c C-r'：reference.el 已 `(require
;; 'seshat-reader-annotation)'，故此 form 在加载本文件时立即生效；
;; `define-key' 本身幂等，重复求值不会重复堆积绑定。
(with-eval-after-load 'seshat-reader-annotation
  (define-key seshat-reader-annotation-list-mode-map (kbd "C-c C-r")
              #'seshat-reader-reference-insert-annotation))

(provide 'seshat-reader-reference)
;;; seshat-reader-reference.el ends here
