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
;; 链接协议（两种形态，解析端都支持，构造端各有一个函数）：
;;
;;   `seshat:<doc-id>#<location>'          —— doc-id 形态（历史形态，路径派生身份）
;;   `seshat:uid:<uid>#<location>'         —— uid 形态（服务端权威身份，改名稳定）
;;
;; 两种形态的 `#<location>' 都可省略。
;;
;; 构造端**单一入口**是 `seshat-reader-reference--link-for'：它先问
;; `seshat-reader-reference--identity'（零网络查 uid），能解析出 uid 就产 uid
;; 形态，否则回落 doc-id 形态。全部产链接的路径（`:store' / 摘录块
;; `--format-block'（被 `insert' 与 `insert-annotation' 复用）/ `copy-link'）都
;; 经它，不再各自拼 doc-id；`--link' / `--uid-link' 只负责各形态的字符串拼装。
;; `:complete' 是唯一例外——补全候选仍是人类可读的 doc-id（换 uid 会让补全不可用）。
;; `:export' 与 `--description' 对两种形态都必须给出**可读且非空**的描述，
;; uid 取不到本地路径时回落 `uid:<前 8 位>…'（见 `--uid-fallback-label'）。
;; `doc-id' 与批注模块的 `document_id' 同源（\"<根标签>:<相对路径>\"，未命中
;; 任何已配置根时降级为 \"local:<绝对路径>\"）；`location' 与批注的
;; `location' 同源同构（\"page:<n>;rect:...\"），故链接片段可直接复用批注的
;; 位置字符串，不新增解析器。解析时只按**最后一个** `#' 分割。
;;
;; uid 形态的判别靠字符集白名单而不是「有没有 `uid:' 前缀」：`uid:' 之后到
;; 第一个 `#' 之前的部分必须是 26 位 Crockford Base32
;; （`[0-9A-HJKMNP-TV-Z]'，排除 I/L/O/U；服务端 `internal/registry/uid.go:29'）
;; 才判 uid 形态，否则回落 doc-id 形态——这样把根标签取名为 `uid' 仍是合法的。
;;
;; 转义不变量：`document_id' **不得包含 `#' 与 `%'**。本模块禁用任何百分号
;; 转义（`url-hexify-string' 会连 `:'、`/' 一起转义、破坏 doc-id 可读性，
;; 且 org 自身会对 `%' 二次转义，双重转义不自洽），因此生成链接时一旦发现
;; `#'/`%' 即 `user-error' 并提示重命名文档；解析端据此只需「最后一个 `#'
;; 分割」这一条规则，行为可完全断言。
;;
;; 与批注模块的关系：本模块不自造位置表示，**引用锚**的构造
;; （`seshat-reader-annotation--anchor'）与页码解析
;; （`seshat-reader-annotation--page-from-location'）都直接复用
;; `seshat-reader-annotation'，两处口径始终一致。
;;
;; 「引用锚」= 页锚（`page:<n>'，唯一导航真值）+ 可选几何尾段
;; （`;rect:...'，由最近一次鼠标选区派生）。**本模块的 rect 不产生任何渲染**：
;; 引用锚只用于 `seshat:' 链接的跳转片段（`seshat-reader-reference--follow'
;; 只读其中的页码），不投喂 C 层高亮、不画任何覆盖层——渲染只由
;; `seshat-reader-annotation' 的批注投喂路径负责。
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

;; 项目层（`seshat-state' / `seshat-sync'）对本模块是**软依赖**：本文件**不
;; require** 它们（vendored reader 包对项目层保持单向软依赖；反向 require 会
;; 成环，也会把状态库拖进 reader 的加载链）。调用处一律 `fboundp' 守卫 +
;; `funcall'，此处只声明签名——`make' 的编译命令含 `-L ..'，签名可见故不产生
;; 「函数未定义」告警。
(declare-function seshat-state-path-for-uid "seshat-state" (uid))
(declare-function seshat-state-uid-for-path "seshat-state" (root path))
(declare-function seshat-state-roots "seshat-state" ())
(declare-function seshat-sync--local-path "seshat-sync" (root-dir path))
;; 按需下载的软依赖：`seshat-library-fetch'（项目层 `seshat-library'）。同样
;; **只声明不 require**——reader 包对项目层是单向软依赖（见 D7），反向 require
;; 会成环。`seshat-library-fetch' 内部自带六步取书事务与 `user-error' 报错，
;; 本模块只负责「本地没有就请求它」。
(declare-function seshat-library-fetch "seshat-library" (uid &optional force))

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

(defconst seshat-reader-reference--uid-format-regexp
  "\\`[0-9A-HJKMNP-TV-Z]\\{26\\}\\'"
  "服务端 uid 的权威形态：26 位 Crockford Base32，排除 I / L / O / U.
字符集逐字取自服务端 `internal/registry/uid.go:29' 的
`^[0-9A-HJKMNP-TV-Z]{26}$'（依据见 `docs/adr/0003-uid-identity-model.md:18'）；
`seshat-rest.el' 里既有的 `[0-9A-Z]' 写法是不精确的，一律以服务端代码为准。
本常量只做**形态校验**（解析判别与构造前置条件），不提供生成能力。

**匹配时必须绑定 `case-fold-search` 为 nil**（见
`seshat-reader-reference--uid-string-p'）：`string-match-p' 默认受
`case-fold-search'（默认 t）影响，会让 `[A-Z]' 连小写字母一起匹配，从而把
小写串误判为合法 uid。")

(defun seshat-reader-reference--uid-string-p (string)
  "判断 STRING 是否为服务端 uid 形态（26 位 Crockford Base32），大小写敏感.
`string-match-p' 默认受 `case-fold-search'（默认值为 t）影响，`[A-Z]' 会连
小写字母一起匹配；uid 是**全大写**的权威形态，小写串必须判为不合法（否则
`uid:01j8zkq2...' 这类错拼会被当成 uid 形态静默接受），故此处显式把
`case-fold-search' 绑为 nil。

STRING 非字符串时返回 nil，不抛错。"
  (and (stringp string)
       (let ((case-fold-search nil))
         (string-match-p seshat-reader-reference--uid-format-regexp string))))

(defun seshat-reader-reference--uid-fallback-label (uid)
  "返回 UID 的回落可读标识，**绝不返回空串**.
格式（与 `docs/emacs-reader.md' 的说明、ERT 断言三处逐字一致）：UID 长度大于
8 时取前 8 位再加省略号 `…'（如 `uid:01J8ZKQ2…'），不大于 8 时原样输出
`uid:<uid>'；UID 非字符串或为空串时返回 \"（未知文档）\"。

为什么需要它：uid 形态的 `seshat:' 链接**不可读**，可读性由链接描述承担
（`[[seshat:uid:X][书名 第 3 页]]'）。本地状态库查不到该 uid 时（尚未下载、
状态库被清、跨机同步未到）仍必须给出**可辨识、非空**的标识，否则 org 导出与
摘录块会出现空描述。"
  (cond
   ((not (stringp uid)) "（未知文档）")
   ((string-empty-p uid) "（未知文档）")
   ((> (length uid) 8) (concat "uid:" (substring uid 0 8) "…"))
   (t (concat "uid:" uid))))

(defun seshat-reader-reference--uid-like-p (string)
  "判断 STRING 是否应按 uid 处理（供 `--description' / `:export' 选择分支）.
两条判据**任一**成立：

1. 权威 uid 形态：26 位 Crockford Base32（见 `--uid-string-p'）。
2. 「裸 uid 串」：非空、不含 `:' / `#' / `%'，且全部字符属 Crockford Base32
   字符集 `[0-9A-HJKMNP-TV-Z]'。

判据 2 为什么必要：doc-id 必含 `:'（\"<标签>:<相对路径>\" 或
\"local:<绝对路径>\"），因此**不含 `:' 的串不可能是合法 doc-id**；把这类串按
uid 处理，才能对「形态不全 / 被截断」的 uid 也给出可辨识的回落标识
（`--uid-fallback-label'），并让「uid 长度不大于 8」这一回落分支可达。

判据 2 **不放宽** `--parse-link' 的判别：链接形态仍要求权威 26 位 uid，否则
根标签取名为 `uid' 的 doc-id 会被误判（见 `--parse-link' 的 docstring）。"
  (and (stringp string)
       (not (string-empty-p string))
       (let ((case-fold-search nil))
         (or (string-match-p seshat-reader-reference--uid-format-regexp string)
             (and (not (string-match-p "[:#%]" string))
                  (string-match-p "\\`[0-9A-HJKMNP-TV-Z]+\\'" string))))))

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

(defun seshat-reader-reference--link-for (doc-id &optional location)
  "为 DOC-ID 与可选 LOCATION 构造 `seshat:' 链接，形态由身份入口决定.
`--identity' 给出 `(:uid UID)' 时用 `--uid-link' 产 uid 形态
（\"seshat:uid:<uid>[#LOCATION]\"）；给出 `(:doc-id DOC)' 时用 `--link' 产
doc-id 形态（与引入本函数前的行为**逐字一致**）。DOC-ID 为 nil 时返回 nil——
调用方据此不产链接（`--identity' 对 nil 返回 `:doc-id` 为 nil 的 plist，若继续走
`--link' 会抛 `user-error' 把整条命令打崩）。

本函数是**全部产链接路径的单一构造入口**：`:store'（`org-store-link'）、摘录块
（`--format-block'，被 `insert' 与 `insert-annotation' 复用）与 `copy-link' 都经
它决定形态，不再各自拼 doc-id；`:complete' **不**经它（候选仍是人类可读的
doc-id，换成 uid 会让补全不可用，见 `--complete-link'）。

软依赖口径（设计行为，非降级补丁）：`seshat-state' 未加载、或路径未登记时
`--identity' 返回 `(:doc-id ...)'，本函数据此产 doc-id 形态而**不报错**——产链接
不能因为查不到 uid 就失败。"
  (when doc-id
    (let* ((identity (seshat-reader-reference--identity doc-id))
           (uid (plist-get identity :uid))
           (doc (plist-get identity :doc-id)))
      (cond
       ((and (stringp uid) (not (string-empty-p uid)))
        (seshat-reader-reference--uid-link uid location))
       ((and (stringp doc) (not (string-empty-p doc)))
        (seshat-reader-reference--link doc location))))))

(defun seshat-reader-reference--uid-link (uid &optional location)
  "由 UID 与可选 LOCATION 构造 uid 形态的 `seshat:' 链接字符串.
返回 \"seshat:uid:<uid>\"；LOCATION 非空（非 nil 且非空串）时追加
\"#<location>\"，否则只返回整篇文档的链接。

UID 必须是 26 位 Crockford Base32（见
`seshat-reader-reference--uid-format-regexp'），否则 `error'——uid 来自状态库
或服务端，不该由用户手填，故这属**编程错误**而不是用户输入错误，不用
`user-error'。

与 `seshat-reader-reference--link' **分成两个函数**（不复用同一签名）：两者
参数语义不同——doc-id 形态要先过 `#'/`%' 的转义不变量校验，uid 的字符集天然
不含 `#'；合并会让调用方无法从签名判断该产哪种形态。"
  (unless (seshat-reader-reference--uid-string-p uid)
    (error "Seshat Reader reference: %S 不是 26 位 Crockford Base32 uid，无法构造 uid 形态链接"
           uid))
  (let ((base (concat "seshat:uid:" uid)))
    (if (and (stringp location) (not (string-empty-p location)))
        (concat base "#" location)
      base)))

(defun seshat-reader-reference--parse-doc-id (s)
  "把已剥掉 \"seshat:\" 前缀的字符串 S 解析为 doc-id 形态 plist.
返回 `(:uid nil :doc-id DOC :location LOC)'：`:uid' 恒为 nil（本函数只处理
doc-id 形态），`:doc-id' 与 `:location' 按**最后一个** `#' 分割得出，无 `#'
时 `:location' 为 nil。空 location（尾部裸 `#'）归一为 nil，与「无 location」
语义一致。`#' 之前的 doc-id 为空时返回 nil。

抽成独立函数是为了让 uid 形态的回落分支（`uid:' 之后不是合法 26 位串）与
普通 doc-id 形态**共用同一份**分割逻辑，避免两处口径漂移。"
  (cond
   ((string-match "#\\([^#]*\\)\\'" s)
    (let ((doc-id (substring s 0 (match-beginning 0)))
          (loc (match-string 1 s)))
      (unless (string-empty-p doc-id)
        (list :uid nil
              :doc-id doc-id
              :location (and (not (string-empty-p loc)) loc)))))
   (t (list :uid nil :doc-id s :location nil))))

(defun seshat-reader-reference--parse-link (link)
  "把 LINK 解析为 plist `(:uid UID :doc-id DOC :location LOC)'，非法时返回 nil.
LINK 可带或不带 \"seshat:\" 前缀。三形态的判别顺序**固定**：

1. 剥前缀后以 `uid:' 开头，**且** `uid:' 之后到第一个 `#' 之前的部分匹配
   `seshat-reader-reference--uid-format-regexp'（26 位 Crockford Base32，
   排除 I/L/O/U）→ **uid 形态**：`:uid' 为该串、`:doc-id' 为 nil。
2. 以 `uid:' 开头但后半不匹配上述正则 → **回落 doc-id 形态**：把 `uid' 当作
   普通根标签，`:doc-id' 为 \"uid:...\"、`:uid' 为 nil。因此根标签取名为 `uid'
   仍然合法；只有「根标签是 `uid' 且相对路径恰好是 26 位大写字母数字」这一
   极端组合会被误判为 uid 形态（已知取舍，见计划「已知取舍」）。
3. 其余形态（`local:' / `tag:path' / 无前缀）→ 交给
   `seshat-reader-reference--parse-doc-id'，行为与引入 uid 形态前**逐字一致**。

三个键**始终存在**：非 uid 形态下 `:uid' 为 nil，调用方可统一 `plist-get'
而无需 `plist-member' 判定。LINK 非字符串、剥前缀后为空、或 `#' 之前的
doc-id 为空时返回 nil。尾部裸 `#'（location 为空串）归一为 nil：空 location
与「无 location」语义相同。"
  (when (stringp link)
    (let* ((s (if (string-prefix-p "seshat:" link)
                  (substring link (length "seshat:"))
                link))
           ;; `case-fold-search' 绑 nil：`uid:' 前缀与 uid 形态都是严格大写的
           ;; 协议串，小写 `UID:' / 小写 uid 一律不算 uid 形态（否则错拼会被
           ;; 静默接受成 uid 形态）。
           (uid-match (let ((case-fold-search nil))
                        (string-match
                         "\\`uid:\\([^#]*\\)\\(?:#\\(.*\\)\\)?\\'" s))))
      (cond
       ((string-empty-p s) nil)
       (uid-match
        (let ((candidate (match-string 1 s))
              (loc (match-string 2 s)))
          (if (seshat-reader-reference--uid-string-p candidate)
              (list :uid candidate
                    :doc-id nil
                    :location (and (stringp loc)
                                   (not (string-empty-p loc))
                                   loc))
            (seshat-reader-reference--parse-doc-id s))))
       (t (seshat-reader-reference--parse-doc-id s))))))

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

;;; uid → 本地路径（零网络，软依赖项目层）

(defun seshat-reader-reference--sync-root-dir (root)
  "返回根 tag ROOT 在 `seshat-state-roots' 里配置的本地目录（带结尾斜杠）.
`seshat-state-roots'（元素形如 `(TAG DIR MODE)'）是**软依赖**：函数不存在
（`seshat-state' 未加载）时返回 nil；ROOT 未配置、或配置的 DIR 不是非空字符串
时同样返回 nil。返回 nil 时 `seshat-reader-reference--file-from-uid' 直接给出
nil，**不凭空拼路径**——根与本地目录的对应关系只有用户配置说得清。"
  (when (and (stringp root) (fboundp 'seshat-state-roots))
    (let ((dir (nth 1 (assoc root (funcall 'seshat-state-roots)))))
      (when (and (stringp dir) (not (string-empty-p dir)))
        (file-name-as-directory (expand-file-name dir))))))

(defvar seshat-reader-reference--uid-path-warned nil
  "回落分支的警告是否已发出（**只警告一次**，避免每次 follow 都刷满 echo area）.")

(defun seshat-reader-reference--uid-local-path (root-dir path)
  "把 ROOT-DIR 与相对路径 PATH 拼成绝对路径并做越界校验；无法安全校验时返回 nil.
**只走软依赖** `seshat-sync--local-path'（`seshat-sync' 已加载时口径与同步引擎
完全一致：拒绝绝对路径 / `~' 前缀 / Windows 盘符前缀 / `..' 穿越，并用
`file-truename' 覆盖符号链接逃逸）。

该函数不可用时**不回落任何自写弱校验**，直接返回 nil 并 `display-warning'
一次（用 `seshat-reader-reference--uid-path-warned' 保证幂等）：原先那份
「`expand-file-name' 归一后判前缀」的校验缺 `file-truename' 双校验，符号链接
指向根外时判不出来，且 PATH 为 \".\" 时会返回根目录本身——安全优先，宁可解析
失败（`--file-from-uid' 因此返回 nil，调用方会提示需加载 `seshat-sync'）也不猜
路径。"
  (if (fboundp 'seshat-sync--local-path)
      (funcall 'seshat-sync--local-path root-dir path)
    (unless seshat-reader-reference--uid-path-warned
      (setq seshat-reader-reference--uid-path-warned t)
      (display-warning
       'seshat-reader-reference
       "需加载 seshat-sync 才能安全解析 uid 路径"
       :warning))
    nil))

(defun seshat-reader-reference--file-from-uid (uid)
  "把 UID 反解析为本地绝对文件路径；取不到时返回 nil（**零网络**、不抛错）.
路径来源全部是本地状态库：`seshat-state-path-for-uid'（软依赖，零网络）给出
`(ROOT . PATH)'，再用 `seshat-state-roots' 里 ROOT 的 DIR 拼绝对路径，并做
越界校验（见 `seshat-reader-reference--uid-local-path'）。

下列任一情形返回 nil：UID 不是非空字符串、`seshat-state' 未加载、UID 未登记
（墓碑 / 孤儿条目已由 `seshat-state-path-for-uid' 排除）、ROOT 未配置 DIR、
PATH 越界、**`seshat-sync--local-path' 不可用**（此时无法做 `file-truename'
双校验，安全优先一律返回 nil，见 `seshat-reader-reference--uid-local-path'）。
**不抛错**：调用方（`:follow'）据此给用户提示，不该因状态库缺项就让整条 org
链接命令崩掉。

与 `seshat-reader-reference--file-from-doc-id' 的分工：本函数给 uid 形态用，
那个给 doc-id 形态用；两者都是零网络纯查表，不发起任何请求。"
  (when (and (stringp uid) (not (string-empty-p uid))
             (fboundp 'seshat-state-path-for-uid))
    (let ((loc (funcall 'seshat-state-path-for-uid uid)))
      (when (and (consp loc) (stringp (cdr loc)))
        (let ((dir (seshat-reader-reference--sync-root-dir (car loc))))
          (when dir
            (seshat-reader-reference--uid-local-path dir (cdr loc))))))))

(defun seshat-reader-reference--identity (doc-id)
  "把 DOC-ID 解析为权威身份 plist：查得到 uid 时 `(:uid UID)'，否则 `(:doc-id DOC)'.
DOC-ID 为 nil 或非字符串时返回 `(:doc-id nil)'——调用方据此什么都不产（不报错、
不产空链接）。

解析链**全程零网络**：`seshat-reader-reference--file-from-doc-id' 得本地绝对
路径 → `seshat-reader-annotation--root-match' 得 `(TAG . DIR)' →
`file-relative-name' 得相对路径 → **软依赖** `seshat-state-uid-for-path' 查
uid。查到 uid 返回 `(:uid UID)'；查不到（`seshat-state' 未加载 / uid 未登记 /
文档不在任何已配置根下）回落 `(:doc-id DOC)'，**不报错**——产链接的路径不能
因为查不到 uid 就失败。

为什么查 uid 要先过 `seshat-reader-annotation-roots'：`seshat-state' 的路径索引
键是 `(ROOT . PATH)'，ROOT 是**服务端根标签**，而 DOC-ID 的标签来自批注模块的
根配置。两套根配置并存是既知取舍（见 `docs/emacs-reader.md' 与 tech-debt），
这里按 DOC-ID 的标签口径反查路径再求相对名，因此两套配置必须能映射到同一
路径才查得到 uid；查不到就回落 doc-id 形态。

本函数是**产链接路径的单一身份入口**：`:store' / 摘录 / 批注引用 / `copy-link'
都应经它决定形态，不各自拼 doc-id。"
  (if (not (stringp doc-id))
      (list :doc-id nil)
    (let* ((file (seshat-reader-reference--file-from-doc-id doc-id))
           (truename (and file
                          (ignore-errors
                            (file-truename (expand-file-name file)))))
           (match (and truename
                       (ignore-errors
                         (seshat-reader-annotation--root-match truename))))
           (uid (and match
                     (fboundp 'seshat-state-uid-for-path)
                     (ignore-errors
                       (funcall 'seshat-state-uid-for-path
                                (car match)
                                (file-relative-name truename (cdr match)))))))
      (if (and (stringp uid) (not (string-empty-p uid)))
          (list :uid uid)
        (list :doc-id doc-id)))))

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
              (let ((id (seshat-reader-annotation--doc-id
                         file (seshat-reader-annotation--quiet-p file))))
                (when (and (stringp id)
                           (not (string-empty-p id))
                           (not (string-match-p "[#%]" id)))
                  (push id ids))))))))
    (let* ((sorted (delete-dups (sort ids #'string<)))
           (current (and (derived-mode-p 'seshat-reader-mode)
                         (buffer-file-name)
                         (seshat-reader-annotation--doc-id
                          (buffer-file-name)
                          (seshat-reader-annotation--quiet-p
                           (buffer-file-name))))))
      (if (and current (member current sorted))
          (cons current (delete current sorted))
        sorted))))

(defun seshat-reader-reference--uid-file-name (uid)
  "零网络取 UID 对应文档的文件名；取不到时返回 nil.
经 `seshat-reader-reference--file-from-uid'（纯查本地状态库，不发起任何请求）
得到绝对路径后取 `file-name-nondirectory'。路径取不到、或文件名恰为空串时返回
nil——「什么算取不到」只在这里判定，避免调用方各写一遍。"
  (let ((file (seshat-reader-reference--file-from-uid uid)))
    (when (stringp file)
      (let ((name (file-name-nondirectory file)))
        (and (not (string-empty-p name)) name)))))

(defun seshat-reader-reference--description (doc-id &optional location)
  "为 DOC-ID / UID 与可选 LOCATION 生成人类可读的链接描述，**绝不返回空串**.
DOC-ID 的参数语义已扩为「doc-id 或 uid 或 nil」，判定顺序**固定**：

1. 按 uid 处理（判据见 `seshat-reader-reference--uid-like-p'）→ 零网络经
   `seshat-reader-reference--uid-file-name' 取文件名；取不到路径时回落
   `seshat-reader-reference--uid-fallback-label' 的可辨识标识
   （`uid:<前 8 位>…'；uid 长度不大于 8 时原样 `uid:<uid>'）。
2. 其它非空字符串 → 取第一个 `:' 之后部分的 `file-name-nondirectory'
   （历史行为，逐字不变；`local:' 前缀的 doc-id 因此取绝对路径的文件名）。
3. nil / 非字符串 / 空串 → \"（未知文档）\"。

**不得返回空串**：uid 形态的链接本身不可读，可读性全由描述承担；描述为空会让
org 导出与摘录块出现空描述，用户也无从判断链接指向什么。

页取自 `seshat-reader-annotation--page-from-location'（1-based，逻辑不变）；
页非 nil 时返回 \"<名字> 第 <页> 页\"，否则只返回名字。"
  (let* ((page (seshat-reader-annotation--page-from-location location))
         (name (let ((raw (cond
                           ((seshat-reader-reference--uid-like-p doc-id)
                            (or (seshat-reader-reference--uid-file-name doc-id)
                                (seshat-reader-reference--uid-fallback-label
                                 doc-id)))
                           ((and (stringp doc-id)
                                 (not (string-empty-p doc-id)))
                            (file-name-nondirectory
                             (if (string-match ":" doc-id)
                                 (substring doc-id (1+ (match-beginning 0)))
                               doc-id)))
                           (t "（未知文档）"))))
                 (if (and (stringp raw) (not (string-empty-p raw)))
                     raw
                   "（未知文档）"))))
    (if page
        (format "%s 第 %d 页" name page)
      name)))

(defun seshat-reader-reference--format-block
    (text doc-id &optional location description)
  "把 TEXT 与 DOC-ID（及可选 LOCATION、DESCRIPTION）组装为摘录块字符串.
链接由 `seshat-reader-reference--link-for' 生成——**能解析出 uid 时是 uid 形态**
（\"seshat:uid:<uid>[#LOCATION]\"），否则回落 doc-id 形态；DOC-ID 为 nil 时
不产链接（链接占位符以空串填充，不写出 nil 字样）。DESCRIPTION 为空时用
`seshat-reader-reference--description' 现算（uid 形态同样给出非空描述）。最终按
`seshat-reader-reference-format' 用 `format' 代入正文 / 链接 / 描述三个
占位符，TEXT 为 nil 时以空串填充。

`:store' / `insert' / `insert-annotation' / `copy-link' 与摘录块共用同一形态
入口（`--link-for'），本函数改形态后四条路径同时生效。"
  (let ((link (seshat-reader-reference--link-for doc-id location))
        (desc (or description
                  (seshat-reader-reference--description doc-id location))))
    (format seshat-reader-reference-format (or text "") (or link "") desc)))

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

(defun seshat-reader-reference--display-file (file)
  "在阅读器中显示 FILE：复用已有 reader buffer，否则新开文档.
复用判据：`find-buffer-visiting'（它会做路径规范化，**不用** `get-file-buffer'，
其精确字符串匹配会因路径归一化差异而静默失效）命中且该 buffer 的
`major-mode' 为 `seshat-reader-mode' 时 `pop-to-buffer'；否则调用
`seshat-reader-open-doc' 新开文档。

doc-id 形态与 uid 形态**共用**本函数：两种链接最终都是「显示一个本地文件」，
各写一套 `pop-to-buffer' 必然口径漂移。"
  (let ((buf (find-buffer-visiting file)))
    (if (and buf
             (eq (buffer-local-value 'major-mode buf) 'seshat-reader-mode))
        (pop-to-buffer buf)
      (seshat-reader-open-doc file))))

(defun seshat-reader-reference--goto-location (parsed)
  "按 PARSED（`--parse-link' 的结果）的 `:location' 跳到对应页.
location 含 `page:<n>' 时用 `seshat-reader-goto-page' 跳到该 1-based 页
（**不再加 1**）；`rect:' 部分不产生任何 UI 动作（本模块无高亮能力，rect 仅
承载信息）；无 location、或 location 不含页码时什么都不做。"
  (let ((page (seshat-reader-annotation--page-from-location
               (plist-get parsed :location))))
    (when page
      ;; P1：`seshat-reader-goto-page' → `seshat-reader--multipage-goto'，落点
      ;; 恒为**页首**（页内像素偏移清零）；多页布局下一屏多页，回报页码让用户
      ;; 知道跳到了哪一页。
      (seshat-reader-goto-page page)
      (message "Seshat Reader reference: 跳到第 %d 页" page))))

(defun seshat-reader-reference--fetch-library (uid)
  "按需下载 UID 对应的书，返回本地绝对路径；失败时 `user-error'.
软依赖 `seshat-library-fetch'（项目层 `seshat-library'，按 D7 的**单向**依赖
纪律只探测不 require）：

- 函数不存在（`seshat-library' 未加载）→ `user-error'：此时既无本地副本也无
  下载能力，只能明确告知用户缺什么；**不自行 require**（reader 包反向依赖
  项目层会成环）。
- 函数可用 → `(funcall \\='seshat-library-fetch UID)'：返回非空字符串即本地
  绝对路径；返回 nil（取书失败，细节由该函数 `display-warning' 到
  `*Warnings*' / echo area）→ `user-error'，定位信息交给那边的提示。

为什么用 `fboundp' + `funcall' 而不是直接调用：本文件不 require
`seshat-library'，直接调用在未加载时会 `void-function'，错误信息对用户毫无
指向性。"
  (unless (fboundp 'seshat-library-fetch)
    (user-error "Seshat Reader reference: uid 形态链接需要 `seshat-library'（未加载）且本地无副本，无法打开：%s"
                uid))
  (let ((file (funcall 'seshat-library-fetch uid)))
    (unless (and (stringp file) (not (string-empty-p file)))
      (user-error "Seshat Reader reference: 取书失败（详见 `*Warnings*' / echo area）：%s"
                  uid))
    file))

(defun seshat-reader-reference-open (path &optional _arg)
  "打开 PATH 指向的文档并跳到链接记录的位置.
PATH 为 `seshat:' 链接的路径部分（可带或不带 \"seshat:\" 前缀），本函数是
`org-link-set-parameters' 的 `:follow' 处理函数。解析结果**按形态分流**：

1. **uid 形态**（`--parse-link' 给出 `:uid'）：先经
   `seshat-reader-reference--file-from-uid' **零网络**查本地副本，文件存在就
   直接打开；本地查不到路径**或**查到的文件不存在时按需下载——见
   `seshat-reader-reference--fetch-library'（软依赖 `seshat-library-fetch'，
   依赖缺失或取书失败都 `user-error'）。
2. **doc-id 形态**（`:doc-id' 非 nil）：经
   `seshat-reader-reference--file-from-doc-id' 反解析为本地绝对路径；doc-id
   无法解析、标签未知或文件不存在时 `user-error'。行为与引入 uid 形态前一致。

两形态的「显示」与「跳页」共用 `--display-file' / `--goto-location'：优先复用
已存在且 major-mode 为 `seshat-reader-mode' 的 buffer（判据是
`find-buffer-visiting'，**不用** `get-file-buffer'——其精确字符串匹配会因路径
归一化差异而静默失效）；未命中复用条件时调用 `seshat-reader-open-doc' 新开
文档。location 含 `page:<n>' 时用 `seshat-reader-goto-page' 跳到该 1-based
页（**不再加 1**）；`rect:' 部分不产生任何 UI 动作（本模块无高亮能力，rect
仅承载信息）。

可选 _ARG 为 org `:follow' 传入的前缀参数，本实现忽略。"
  (let* ((link (if (string-prefix-p "seshat:" path)
                   path
                 (concat "seshat:" path)))
         (parsed (seshat-reader-reference--parse-link link))
         (uid (plist-get parsed :uid))
         (doc-id (plist-get parsed :doc-id)))
    (cond
     (uid
      (let ((local (seshat-reader-reference--file-from-uid uid)))
        (seshat-reader-reference--display-file
         (if (and local (file-exists-p local))
             local
           (seshat-reader-reference--fetch-library uid)))))
     (doc-id
      (let ((file (seshat-reader-reference--file-from-doc-id doc-id)))
        (unless file
          (user-error "Seshat Reader reference: 未在 `seshat-reader-annotation-roots' 中找到标签，或链接格式非法：%s"
                      doc-id))
        (unless (file-exists-p file)
          (user-error "Seshat Reader reference: 文档不存在：%s" file))
        (seshat-reader-reference--display-file file)))
     (t
      (user-error "Seshat Reader reference: 链接格式非法，无法解析：%s" path)))
    (seshat-reader-reference--goto-location parsed)))

(defun seshat-reader-reference-store-link (&optional _interactive)
  "为 `org-store-link' 生成当前阅读位置的 `seshat:' 链接并返回 t.
仅在 `seshat-reader-mode' 缓冲区中可用，否则 `user-error' 说明用法。文档
标识由 variable `buffer-file-name' 经 `seshat-reader-annotation--doc-id' 派生；
引用锚优先取最近一次选区（`seshat-reader-select-last'，其 `:file' 须与
当前文件等价且 `:page'/`:rect' 齐备）构造的完整锚（页锚 + 几何尾段），否则
退化为纯页锚 \"page:<n>\"（此时若 `seshat-reader-current-doc-pagenumber'
取不到整数页码，说明当前缓冲区不是阅读器视图，`user-error' 提示先打开
文档）。几何尾段只写进链接片段供将来取用，**本模块不据此渲染任何内容**。
描述在有选区文本时用 `seshat-reader-reference--summary'，否则用
`seshat-reader-reference--description'。链接本身由
`seshat-reader-reference--link-for' 构造——**能零网络解析出 uid 时存的是 uid
形态**（`seshat:uid:<uid>[#<location>]'），否则回落 doc-id 形态。

可选 _INTERACTIVE 被忽略，仅为满足 org 9.7+ 对 `:store' 的首选单参签名。"
  (unless (derived-mode-p 'seshat-reader-mode)
    (user-error "Seshat Reader reference: `org-store-link' 仅在 seshat-reader 阅读缓冲区中可用"))
  (let* ((file (buffer-file-name))
         (doc-id (seshat-reader-annotation--doc-id
                  file (seshat-reader-annotation--quiet-p file)))
         (selection seshat-reader-select-last)
         (location (if (and selection
                            (plist-get selection :file)
                            (plist-get selection :page)
                            (plist-get selection :rect)
                            (file-equal-p (plist-get selection :file) file))
                       ;; 引用锚只取整体 bbox（:rect），不含字级多段 :rects；
                       ;; `--anchor' 单 rect / rect 列表两种入参都接受。
                       (seshat-reader-annotation--anchor
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
         (link (seshat-reader-reference--link-for doc-id location)))
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
链接描述，非空时**原样采用**（org 已有描述时直接用，符合 org 语义），为空或 nil
时用 `seshat-reader-reference--description' 现算——doc-id 形态得
\"<文件名> 第 <页> 页\"，**uid 形态**同样经它得 \"<文件名> 第 <页> 页\"（零网络
查本地状态库取文件名），与摘录块、`:store' 的描述同源，**不重写一份**逻辑。
FORMAT 为导出后端符号（常见取值 `html' / `latex' / `ascii' / `md' / `texinfo' /
`odt' / `org'，也可能为 nil），本实现**对所有后端输出同一份纯文本**，不按后端
区分；可选 _BACKEND 为导出通信通道 plist，忽略。

**绝不输出空串**：uid 的本地路径取不到（未下载 / 状态库无此 uid）时描述回落为
`uid:<前 8 位>…'（见 `seshat-reader-reference--uid-fallback-label'），因此导出
结果恒为非空文本——空描述会让读者完全看不出链接指向什么。

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
     (t (let* ((uid (plist-get parsed :uid))
               (location (plist-get parsed :location))
               ;; uid 形态下传 uid（`--description' 按 uid 分支取本地文件名），
               ;; doc-id 形态下传 doc-id（历史行为逐字不变）。
               (name (seshat-reader-reference--description
                      (or uid (plist-get parsed :doc-id))
                      location)))
          (cond
           ((and (stringp name) (not (string-empty-p name))) name)
           (uid (seshat-reader-reference--uid-fallback-label uid))
           (t "（未知文档）")))))))

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
`seshat-reader-annotation--doc-id' 派生（QUIET 取自
`seshat-reader-annotation--quiet-p'，软依赖 `seshat-reading'：在
`seshat-reading-mode' 的 buffer 里不再刷库外降级警告）；供下面的交互命令与
T6 的批注引用复用。"
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Seshat Reader reference: 当前缓冲区没有关联文件，无法派生文档标识"))
    (seshat-reader-annotation--doc-id
     file (seshat-reader-annotation--quiet-p file))))

(defun seshat-reader-reference--current-location ()
  "(internal) 返回当前阅读位置的**引用锚**字符串.
引用锚 = 页锚（`page:<n>'）+ 可选几何尾段（`;rect:...'）。优先使用最近一次
鼠标选区（`seshat-reader-select-last'）：其 `:file' 与 variable
`buffer-file-name' 等价（`file-equal-p'）且 `:page'/`:rect' 齐备时返回
`seshat-reader-annotation--anchor' 构造的完整锚（与批注 location 同构，但
**只作跳转片段用，本模块的 rect 不产生任何渲染**）；否则退化为纯页锚
\"page:<n>\"，其中 <n> 取 `seshat-reader-current-doc-pagenumber'
（已是 1-based，**不再加 1**）。

**引用锚只取整体 bbox**（`seshat-reader-select-last' 的 `:rect'），故意不用
字级多段 `:rects'：引用只需要一个可复现的落点，链接串短一些更利于阅读与
存储，多段几何对跳转没有任何增益。`seshat-reader-annotation--anchor' 两种
入参都接受（单 rect / rect 列表），因此这里继续传单 rect 完全合法。

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
        (seshat-reader-annotation--anchor (plist-get selection :page)
                                          (plist-get selection :rect))
      (let ((page (seshat-reader-current-doc-pagenumber)))
        (unless (integerp page)
          (user-error "Seshat Reader reference: 当前缓冲区不是阅读器视图，无法确定页码，请先在阅读器中打开文档"))
        (format "page:%d" page)))))

(defun seshat-reader-reference-copy-link ()
  "把当前阅读位置对应的 `seshat:' 链接复制到 `kill-ring' 并提示.
链接由 `seshat-reader-reference--link-for' 用当前文档标识与当前阅读位置
（`seshat-reader-reference--current-location'）构造：**能解析出 uid 时复制 uid
形态**，否则回落 doc-id 形态（与摘录、`:store' 同一入口，形态始终一致）。"
  (interactive)
  (let ((link (seshat-reader-reference--link-for
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
