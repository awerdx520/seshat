;;; seshat-reader-annotation.el --- Annotations for seshat-reader documents  -*- lexical-binding: t; -*-

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

;; `seshat-reader' 文档的批注采集与侧车同步。
;;
;; 批注是**侧车（sidecar）**数据：保存在服务端（`POST /api/annotations'），
;; 不写回文档文件；阅读器只负责采集与展示，从不修改用户文档。
;;
;; 本模块区分**两个文档身份**（双值不变量）：
;;
;; - **显示标识（doc-id）**：由 `seshat-reader-annotation--doc-id' 从文件
;;   路径单点派生，约定为 \"<根标签>:<相对路径>\"，根标签到根目录的映射由
;;   `seshat-reader-annotation-roots' 配置；未命中任何已配置根的文档降级为
;;   \"local:<绝对路径>\"。它**只用于**列表/面板显示与 `seshat:' 链接文本。
;; - **服务端身份（uid）**：由 `seshat-reader-annotation--uid' 经
;;   `GET /api/resolve' 从同一路径解析得到（按真实路径内存缓存），**只用于**
;;   所有发给服务端的实参（批注的创建/拉取、离线队列同步）。
;;
;; 判据：凡「发给服务端」的实参一律 uid，凡「写进 buffer / 链接 / 文案」的
;; 一律 doc-id。二者不可互换——服务端只认 uid，链接文本只认 doc-id。
;;
;; 位置（`location'）约定为 \"page:<n>;rect:<x0>,<y0>,<x1>,<y1>\"：页码
;; `<n>' 为 **1-based** 十进制整数，矩形为**页面坐标**（PDF point 空间、
;; 原点左上、y 向下），不含缩放与旋转，四个坐标各保留两位小数。
;;
;; 服务端契约（端点、字段与错误码）见项目 `docs/api.md'。
;;
;; 交互入口（键位加在 `seshat-reader-mode-map'）：
;;
;;   `C-c C-a'  `seshat-reader-annotation-create'
;;     把最近一次鼠标选区（`seshat-reader-select-last'）作为内容创建批注；
;;     带前缀参数（`C-u'）时在迷你缓冲区读取正文。创建成功后**不清除**
;;     选区，因此可对同一选区连续创建多条批注。
;;
;;   `C-c C-l'  `seshat-reader-annotation-list'
;;     列出当前文档的批注，渲染到 `*Seshat Annotations*'（页码 + 正文
;;     摘要）；列表缓冲区中 `RET' 跳页、`d' 删除。
;;
;; 列表缓冲区使用 `special-mode' 派生的内部 mode
;; `seshat-reader-annotation-list-mode'，`RET' 与 `d' 经其 local keymap
;; 用 `define-key' 绑定，不引入 evil 依赖。在 evil 环境下这两个键可能被
;; evil 接管（evil 会覆盖 `special-mode' 系的这两个键），需要用户在配置
;; 侧处理（真机验证由 M11.3 的 T11 覆盖）。

;;; Code:

(require 'url-util)
(require 'seshat-rest)
(require 'seshat-reader)
;; 信息面板承载体（`seshat-reader-sidebar'）为**零依赖**模块（只操作 buffer
;; 与 window，不 require 任何本项目模块），因此在此 require 它不会与
;; annotation 形成循环 require。
(require 'seshat-reader-sidebar)

;; 离线队列模块（`seshat-reader-annotation-queue'）在加载时会
;; `(require 'seshat-reader-annotation)'，因此本文件**不得**在顶部 require
;; 它（会形成循环 require）。改为在此声明其公开函数，并在真正需要时于函数
;; 体内 `require'——Emacs 会缓存 feature，重复 require 只是一次查表。
(declare-function seshat-reader-annotation-queue-enqueue "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-remove "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-count "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-entries "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-sync "seshat-reader-annotation-queue")

;; ETAF 渲染层是**软依赖**：本文件不在顶部 require 它（未安装 ETAF 时列表中
;; 的批注仍需可用），渲染入口在 `seshat-reader-annotation--render-list-etaf'
;; 内按需 `(require 'seshat-reader-etaf nil t)'。此处声明公开符号以避免字节
;; 编译告警。
(declare-function seshat-reader-etaf-available-p "seshat-reader-etaf" ())
(declare-function seshat-reader-etaf-render-annotations "seshat-reader-etaf"
                  (buffer items doc-id &optional source))
;; ETAF 已挂载判定用（`seshat-reader-annotation--etaf-mounted-p'）；同样只在
;; ETAF 已加载时才会被调用。
(declare-function etaf-runtime-for-buffer "etaf-runtime" (buffer-or-name))

(defvar seshat-reader-select-last nil
  "最近一次鼠标选区，正式定义与完整语义见 `seshat-reader-select'.
此处声明仅用于避免字节编译告警，并保证在 `seshat-reader-select' 尚未
加载时该变量仍有 nil 绑定，使 `seshat-reader-annotation-create' 的
“无选区”检查走 `user-error' 而不是 void-variable 崩溃。")

(defgroup seshat-reader-annotation nil
  "批注采集与侧车同步（seshat-reader 文档）."
  :group 'seshat-reader
  :prefix "seshat-reader-annotation-")

(defcustom seshat-reader-annotation-roots nil
  "已配置的文档根列表，用于把文件路径派生为批注用的 `document_id'.
每个元素形如 (标签 . 根目录)：标签是简短字符串，用于组成
`document_id' 的 \"<标签>:<相对路径>\"；根目录是书库目录的绝对路径
（可含 `~'，比较前经 `expand-file-name' 展开）。
文件命中某个根时取 \"<标签>:<相对路径>\"；多个根同时命中时取**最长
（最具体）的根**优先。
未命中任何已配置根的文档降级为 \"local:<绝对路径>\"，其批注只在本地
可见、不跨端共享。"
  :type '(alist :key-type (string :tag "根标签")
                :value-type (directory :tag "根目录"))
  :group 'seshat-reader-annotation)

(defvar seshat-reader-annotation--uid-cache nil
  "文件真实路径到服务端 uid 的内存缓存（alist，key 为 `file-truename'）.
只在当前 Emacs 进程内有效。uid 由服务端分配、跨改名稳定，故不做失效：
极端情形（服务端重建登记后 uid 变化）可手动
`(setq seshat-reader-annotation--uid-cache nil)' 清空。")

(defun seshat-reader-annotation--root-match (truename)
  "在 `seshat-reader-annotation-roots' 中为 TRUENAME 找最长匹配根.
TRUENAME 须为已归一的绝对真实路径（`file-truename'）。命中时返回
`(标签 . 根目录)'，根目录带末尾斜杠；多个根同时命中时取**最长（最具体）
的根**；未命中任何根时返回 nil。"
  (let ((best nil)
        (best-length -1))
    (dolist (entry seshat-reader-annotation-roots)
      (let* ((root (file-name-as-directory
                    (file-truename (expand-file-name (cdr entry)))))
             (length (length root)))
        (when (and (file-in-directory-p truename root)
                   (> length best-length))
          (setq best (cons (car entry) root)
                best-length length))))
    best))

(defun seshat-reader-annotation--doc-id (file)
  "由文件路径 FILE 派生**显示用**的文档标识（doc-id）.
先把 FILE 归一化为绝对真实路径（`file-truename' 展开 `~'、相对路径与
符号链接），再依次与 `seshat-reader-annotation-roots' 中的每个根比较：
命中时返回 \"<标签>:<相对路径>\"，多个根命中时取**最长（最具体）的根**。
未命中任何根时把结果降级为 \"local:<绝对路径>\"，并 `message' 一条警告
提示该标识不跨端共享。

FILE 为文档文件路径，可以是相对路径。返回值**只用于**列表/面板显示与
`seshat:' 链接文本；发给服务端的身份必须是 uid（见
`seshat-reader-annotation--uid'）。"
  (let* ((truename (file-truename (expand-file-name file)))
         (match (seshat-reader-annotation--root-match truename)))
    (if match
        (concat (car match) ":" (file-relative-name truename (cdr match)))
      (let ((fallback (concat "local:" truename)))
        (message "Seshat Reader annotation: %s 不在任何已配置的文档根内，降级为 %s（不跨端共享）"
                 truename fallback)
        fallback))))

(defun seshat-reader-annotation--uid (file)
  "由文件路径 FILE 解析服务端权威的文件 uid（**只用于** API 身份）.
先把 FILE 归一化为绝对真实路径（`file-truename'），命中
`seshat-reader-annotation--uid-cache' 时直接返回缓存值；未命中时按
`seshat-reader-annotation-roots' 找最长匹配根，拆出 (根标签 . 相对路径)，
再经 `seshat-rest-resolve-uid' 向服务端解析，成功则写入缓存并返回。

文件不在任何已配置根内，或服务端未登记该文档（resolve 返回 nil）时抛
`user-error' \"文档未在服务端登记：%s\"。失败结果**不写缓存**，下次调用
会重试。

显示与 `seshat:' 链接文本请用 `seshat-reader-annotation--doc-id'，不要把
本函数的返回值写进 buffer。"
  (let* ((truename (file-truename (expand-file-name file)))
         (cached (assoc truename seshat-reader-annotation--uid-cache)))
    (or (cdr cached)
        (let* ((match (seshat-reader-annotation--root-match truename))
               (uid (and match
                         (seshat-rest-resolve-uid
                          (car match)
                          (file-relative-name truename (cdr match))))))
          (unless (and (stringp uid) (not (string-empty-p uid)))
            (user-error "文档未在服务端登记：%s" file))
          (setq seshat-reader-annotation--uid-cache
                (cons (cons truename uid)
                      seshat-reader-annotation--uid-cache))
          uid))))

(defun seshat-reader-annotation--location (page rect)
  "由 PAGE 与 RECT 构造批注位置字符串.
PAGE 为 **1-based 正整数**页码；RECT 为四元素列表 (X0 Y0 X1 Y1)，元素为
**页面坐标**浮点数（顺序不做重排，由调用方保证已归一）。返回
\"page:<n>;rect:<x0>,<y0>,<x1>,<y1>\"，其中页码为 1-based 十进制整数，
四个坐标各保留两位小数（`%.2f'）。PAGE 不是正整数时以 `user-error' 明确
报错，不以 1 兜底。"
  (unless (and (integerp page) (> page 0))
    (user-error "Seshat Reader annotation: page 必须是正整数（1-based），实际为 %S"
                page))
  (let ((x0 (nth 0 rect))
        (y0 (nth 1 rect))
        (x1 (nth 2 rect))
        (y1 (nth 3 rect)))
    (format "page:%d;rect:%.2f,%.2f,%.2f,%.2f" page x0 y0 x1 y1)))

;;; 离线队列接入

(defun seshat-reader-annotation--require-queue ()
  "按需加载离线队列模块并返回 t.
本文件不在顶部 `require' `seshat-reader-annotation-queue'（后者加载时会
`require' 本文件，顶部 require 会形成循环）；因此所有对队列模块公开函数
与选项的访问都先经本函数按需加载。`require' 对已加载 feature 只是一次
查表，开销可忽略。"
  (require 'seshat-reader-annotation-queue)
  t)

(defun seshat-reader-annotation--enqueue (entry what)
  "把一条批注操作 ENTRY 存入离线队列并提示待同步条数.
WHAT 是描述该操作的短语（如 \"批注\"、\"删除操作\"），用于拼出提示语
「WHAT已存入本地待同步队列（N 条待同步）」，其中 N 由
`seshat-reader-annotation-queue-count' 现算。提示语刻意只陈述「已本地暂存」
这一事实，不描述服务端状态（离线是预期路径，不是错误）。"
  (seshat-reader-annotation--require-queue)
  (seshat-reader-annotation-queue-enqueue entry)
  (message "Seshat Reader annotation: %s已存入本地待同步队列（%d 条待同步）"
           what (seshat-reader-annotation-queue-count)))

(defun seshat-reader-annotation--maybe-sync-queue ()
  "队列非空且启用自动同步时，机会性同步一次离线队列.
先按需加载队列模块，再在 `seshat-reader-annotation-queue-auto-sync' 非 nil
且 `seshat-reader-annotation-queue-count' 大于 0 时调用
`seshat-reader-annotation-queue-sync'。同步自身的网络失败已被其吞掉，此处
再用 `ignore-errors' 兜住队列文件损坏等异常，以免影响调用方的正常结果。"
  (seshat-reader-annotation--require-queue)
  (when (and (symbol-value 'seshat-reader-annotation-queue-auto-sync)
             (> (seshat-reader-annotation-queue-count) 0))
    (ignore-errors (seshat-reader-annotation-queue-sync))))

(defun seshat-reader-annotation--queued-create-entries (uid)
  "返回 UID 对应的文档在本地离线队列中待同步的 create 条目列表.
UID 为服务端权威身份（**不是**显示用 doc-id）。按需加载队列模块后取
`seshat-reader-annotation-queue-entries' 中 `:action' 为 `create' 的条目
（`delete' 条目没有可展示的位置与正文），保持入队顺序；没有匹配条目或
UID 为 nil 时返回 nil。"
  (seshat-reader-annotation--require-queue)
  (when uid
    (let (result)
      (dolist (entry (seshat-reader-annotation-queue-entries uid))
        (when (eq (plist-get entry :action) 'create)
          (push entry result)))
      (nreverse result))))

;;; 交互式采集

(defun seshat-reader-annotation-create (&optional body)
  "为最近一次鼠标选区创建一条服务端批注.
BODY 为批注正文；为 nil 或去掉空白后为空串时退回使用最近一次选区的
文本（`seshat-reader-select-last' 的 :text）；两者皆空时 `user-error'。

交互调用：不带前缀参数时直接使用选区文本，带前缀参数（`C-u'）时在
迷你缓冲区读取正文。

运行前置：必须先用鼠标拖拽选中页面文本，使 `seshat-reader-select-last'
非 nil；该变量在创建成功后**不会被清除**，因此可对同一选区连续创建多条
批注（这是有意的语义）。旋转页面上的选区不受支持。

服务端返回含 `id' 的结果时 `message' 报告该 `id'，并在本地队列非空时
机会性地触发一次队列同步（同步失败不影响本次创建成功的结果）。服务端
不可用时**不**报错：把 `(:action create …)' 条目存入本地离线队列，并
`message' 提示已本地暂存及待同步条数，稍后由
`seshat-reader-annotation-queue-sync' 自动同步到服务端。"
  (interactive (list (when current-prefix-arg (read-string "批注正文: "))))
  (let ((selection seshat-reader-select-last))
    (unless selection
      (user-error "Seshat Reader annotation: 尚无选区，请先用鼠标（down-mouse-1）拖拽选中页面文本"))
    (let ((file (plist-get selection :file)))
      (unless file
        (user-error "Seshat Reader annotation: 选区未记录文档文件，无法派生文档标识"))
      (let* ((page (plist-get selection :page))
             (rect (plist-get selection :rect))
             (selection-text (plist-get selection :text))
             (text (if (and (stringp body) (not (string-empty-p (string-trim body))))
                       body
                     selection-text))
             (document-id (seshat-reader-annotation--doc-id file))
             (location (seshat-reader-annotation--location page rect)))
        (when (or (null text) (string-empty-p (string-trim text)))
          (user-error "Seshat Reader annotation: 选区没有文本，可先用 C-u 输入批注正文"))
        ;; 服务端身份在正文校验之后再解析：未登记时 `user-error' 直接冒泡给
        ;; 用户（服务端权威 uid 无法离线生成）。
        (let ((uid (seshat-reader-annotation--uid file)))
          (condition-case nil
              (let ((response (seshat-rest-create-annotation uid location text)))
                (if (and (listp response) (alist-get 'id response))
                    (progn
                      (message "Seshat Reader annotation: 已创建批注 %s（%s，%s）"
                               (format "%s" (alist-get 'id response))
                               document-id location)
                      ;; 机会性同步：服务端此刻可达，顺手把积压的本地队列推进一次。
                      (seshat-reader-annotation--require-queue)
                      (when (> (seshat-reader-annotation-queue-count) 0)
                        (ignore-errors (seshat-reader-annotation-queue-sync))))
                  (seshat-reader-annotation--enqueue
                   (list :action 'create
                         :uid uid
                         :document-id document-id
                         :location location
                         :text text)
                   "批注")))
            (error
             (seshat-reader-annotation--enqueue
              (list :action 'create
                    :uid uid
                    :document-id document-id
                    :location location
                    :text text)
              "批注"))))))))


;;; 列表与删除

(defconst seshat-reader-annotation-list-buffer-name "*Seshat Annotations*"
  "批注列表缓冲区名称.")

(defconst seshat-reader-annotation-list-summary-width 60
  "批注列表中正文摘要的最大字符数，超出部分以 \"…\" 截断.")

(defconst seshat-reader-annotation--fetch-error 'seshat-reader-annotation--fetch-error
  "`seshat-reader-annotation--fetch' 在拉取失败时返回的哨兵值.")

(defvar-local seshat-reader-annotation-list-document-id nil
  "列表缓冲区所展示批注的**显示标识（doc-id）**.
形如 \"<标签>:<相对路径>\"，只用于列表显示与 `seshat:' 链接文本（
`seshat-reader-reference' 只读本变量）。刷新/删除等 API 操作不得使用它，
而应用 `seshat-reader-annotation-list-uid'。")

(defvar-local seshat-reader-annotation-list-uid nil
  "列表缓冲区所展示批注的**服务端身份（uid）**.
供列表刷新（`g'）与删除路径发请求使用；显示与 `seshat:' 链接文本仍用
`seshat-reader-annotation-list-document-id'（doc-id）。")

(defvar-local seshat-reader-annotation-list-source nil
  "发起列表的 seshat-reader 文档缓冲区，供 `RET' 跳页使用.")

(defvar-local seshat-reader-annotation-list-entries nil
  "列表缓冲区最近一次渲染的服务端批注列表（仅内存缓存）.
`seshat-reader-annotation-list-delete' 在取消本地待同步批注后重渲染列表时
复用本缓存，从而无需再次拉取服务端（即不发起任何 HTTP）。")

(defun seshat-reader-annotation--page-from-location (location)
  "从 LOCATION 中解析 **1-based** 页码；解析失败时返回 nil.
LOCATION 的约定为 \"page:<n>;rect:...\"，其中 <n> 为 1-based 十进制
整数；本函数用正则 `page:\\([0-9]+\\)' 提取该整数。"
  (when (and (stringp location)
             (string-match "page:\\([0-9]+\\)" location))
    (string-to-number (match-string 1 location))))

(defun seshat-reader-annotation--summary (text)
  "把 TEXT 压缩为单行摘要，超过配置宽度时以 \"…\" 截断.
TEXT 中的换行、回车与制表符被替换为空格；TEXT 为 nil 时返回空串。"
  (let* ((flat (if (stringp text)
                   (replace-regexp-in-string "[\n\r\t]+" " " text)
                 ""))
         (trimmed (string-trim flat)))
    (if (> (length trimmed) seshat-reader-annotation-list-summary-width)
        (concat (substring trimmed 0 seshat-reader-annotation-list-summary-width) "…")
      trimmed)))

(defun seshat-reader-annotation--insert-entry (annotation &optional queued-uuid)
  "把一条批注 ANNOTATION 插入当前缓冲区的一行.
ANNOTATION 为服务端返回的 alist，含 `id'、`location'、`text' 等字段。
该行以 **1-based** 页码开头（无法解析时显示 \"?\" 并在行尾标注），后接
正文摘要；整行携带 `seshat-reader-annotation-id'、`seshat-reader-annotation-page'
与 `seshat-reader-annotation-location' 三个文本属性，供 `RET' 与 `d' 使用。

QUEUED-UUID 非 nil 时表示该条来自本地离线队列、尚未同步到服务端：行尾
追加 \"[待同步]\" 标记，且该行携带值为 QUEUED-UUID 的
`seshat-reader-annotation-queue-uuid' 文本属性。服务端返回的批注调用本
函数时不传 QUEUED-UUID，该属性因此为 nil，供
`seshat-reader-annotation-list-delete' 区分「取消本地条目」与「删除服务端
批注」两条路径。"
  (let* ((id (alist-get 'id annotation))
         (location (alist-get 'location annotation))
         (text (alist-get 'text annotation))
         (page (seshat-reader-annotation--page-from-location location))
         (start (point)))
    (insert (format "  %5s  %s%s%s\n"
                    (if page (number-to-string page) "?")
                    (let ((summary (seshat-reader-annotation--summary text)))
                      (if (string-empty-p summary) "（无正文）" summary))
                    (if page "" "  [无法从 location 解析页码]")
                    (if queued-uuid "  [待同步]" "")))
    (add-text-properties start (point)
                         (list 'seshat-reader-annotation-id id
                               'seshat-reader-annotation-page page
                               'seshat-reader-annotation-queue-uuid queued-uuid
                               'seshat-reader-annotation-location location))))

(defun seshat-reader-annotation--fetch (uid)
  "拉取 UID 的批注列表，失败时提示并返回失败哨兵.
UID 为服务端权威身份（**不是** doc-id）。本函数直接查 HTTP 状态码，因此
非 2xx 与「真正无批注」不会混为一谈：2xx 时用 `seshat-rest--json' 解析
响应并返回批注列表（无批注为 nil，属合法结果，由调用方渲染为提示行）；
HTTP 非 2xx（如 401 鉴权失败、400 uid 非法、500 服务端错误）时 `message'
一条**含状态码**的提示，并返回
`seshat-reader-annotation--fetch-error'。服务端不可用、网络失败或响应
无法解析等异常情形同样 `message' 提示并返回该哨兵。哨兵只用于让调用
方跳过渲染、保留既有列表，绝不把异常冒泡成 backtrace。"
  (condition-case err
      (let* ((response (seshat-rest--request
                        "GET"
                        (format "/api/annotations?uid=%s"
                                (url-hexify-string uid))))
             (status (car response)))
        (if (and (integerp status) (>= status 200) (< status 300))
            (seshat-rest--json response)
          (message "Seshat Reader annotation: 拉取批注列表失败（HTTP %s）"
                   status)
          seshat-reader-annotation--fetch-error))
    (error
     (message "Seshat Reader annotation: 拉取批注列表失败（请求失败或响应异常）：%s"
              (error-message-string err))
     seshat-reader-annotation--fetch-error)))

;;; ETAF 渲染层接入

(defun seshat-reader-annotation--etaf-p ()
  "判断 ETAF 渲染层当前是否可用.
判据是渲染层模块已加载（`seshat-reader-etaf-available-p' 已定义）且该函数
返回非 nil（总开关打开并且 `etaf-ui' 加载成功）。渲染层是本包的**软依赖**：
本文件不在顶部 require 它，因此未安装 ETAF 时本函数返回 nil，列表走既有
纯文本渲染。"
  (and (fboundp 'seshat-reader-etaf-available-p)
       (seshat-reader-etaf-available-p)))

(defun seshat-reader-annotation--etaf-items (annotations queued)
  "把 ANNOTATIONS 与 QUEUED 合成为 ETAF 渲染层使用的 plist 列表.
ANNOTATIONS 为服务端返回的批注 alist 列表，QUEUED 为本地离线队列中待同步
的 create 条目 plist 列表。每个元素形如
`(:id ID :uuid UUID :location LOCATION :page PAGE :text TEXT :dirty DIRTY)'：

- 服务端项取 `:id'（`:uuid' 为 nil，`:dirty' 为 nil），页码由
  `seshat-reader-annotation--page-from-location' 从 `:location' 解析；
- 本地待同步项取队列条目的 `:uuid'（`:id' 为 nil，`:dirty' 为 t）。

顺序与 `seshat-reader-annotation--render-list' 的文本渲染一致：**服务端项
在前、本地待同步项在后**。"
  (append
   (mapcar (lambda (annotation)
             (let ((location (alist-get 'location annotation)))
               (list :id (alist-get 'id annotation)
                     :uuid nil
                     :location location
                     :page (seshat-reader-annotation--page-from-location location)
                     :text (alist-get 'text annotation)
                     :dirty nil)))
           annotations)
   (mapcar (lambda (entry)
             (let ((location (plist-get entry :location)))
               (list :id nil
                     :uuid (plist-get entry :uuid)
                     :location location
                     :page (seshat-reader-annotation--page-from-location location)
                     :text (plist-get entry :text)
                     :dirty t)))
           queued)))

(defun seshat-reader-annotation--all-items (annotations queued)
  "返回全量条目列表，元素为 plist.
ANNOTATIONS 为服务端批注列表，QUEUED 为本地离线队列中待同步的 create 条目
列表。本函数**直接复用** `seshat-reader-annotation--etaf-items' 的合并结果
（服务端项在前、本地待同步项在后），不另写一套合并逻辑，以免两条路径的
顺序漂移。

本函数是列表渲染的全量条目合并入口：纯文本路径与 ETAF 路径都只接受本
函数的返回值，且都**全量**渲染，不做任何切片。"
  (seshat-reader-annotation--etaf-items annotations queued))

(defun seshat-reader-annotation--render-list-etaf (items document-id source)
  "用 ETAF 渲染层把 ITEMS 渲染到当前缓冲区；成功返回 t，否则返回 nil.
ITEMS 是 `seshat-reader-annotation--etaf-items' 的返回值（**全量**条目，
服务端项在前、本地待同步项在后），渲染层全量渲染成卡片——单列连续流，
面板窗口整体滚动，不做切片也不显示页码徽章。DOCUMENT-ID 与 SOURCE 随渲染
一并交给渲染层，供其动作命令（跳页 / 删除 / 引用）复用。

渲染层未安装或加载失败时返回 nil，由调用方回退纯文本渲染。渲染**抛错**时
`message' 一条警告后同样返回 nil——面板不得因为渲染失败而空白。"
  (condition-case err
      (if (require 'seshat-reader-etaf nil t)
          (progn
            (seshat-reader-etaf-render-annotations
             (current-buffer) items document-id source)
            t)
        nil)
    (error
     (message "Seshat Reader annotation: ETAF 渲染失败，回退文本渲染：%s"
              (error-message-string err))
     nil)))

(defun seshat-reader-annotation--etaf-mounted-p ()
  "判断当前缓冲区是否已挂载 ETAF runtime.
`seshat-reader-annotation--render-list' 据此决定是否可以先 `erase-buffer'：
ETAF 的 runtime 依赖缓冲区既有文本做增量刷新，清空后再 flush 会报错。
ETAF 渲染层未加载（或尚未挂载）时返回 nil，调用方按文本渲染处理。"
  (and (fboundp 'etaf-runtime-for-buffer)
       (and (etaf-runtime-for-buffer (current-buffer)) t)))

(defun seshat-reader-annotation--render-list (document-id source annotations
                                                         &optional queued uid)
  "在 `*Seshat Annotations*' 中渲染批注列表.
DOCUMENT-ID 为**显示标识（doc-id）**，SOURCE 为发起列表的 seshat-reader
文档缓冲区；二者都以 buffer-local 形式记入列表缓冲区，供 `d' 刷新与 `RET'
跳页复用，ANNOTATIONS 也一并缓存到
`seshat-reader-annotation-list-entries' 供免 HTTP 重渲染。

UID 为服务端权威身份，非 nil 时写入 buffer-local
`seshat-reader-annotation-list-uid'（供列表刷新与删除发请求）。为 nil 时
**保留**列表缓冲区里已有的值——ETAF 渲染层的 `--rerender-cached' 走的就是
这条「无新 uid」的路径，它复用上一次完整渲染写入的值。显示与 `seshat:'
链接文本一律用 DOCUMENT-ID，绝不写 uid。

ANNOTATIONS 为服务端返回的批注列表，QUEUED 为本地离线队列中待同步的
create 条目列表（plist 列表，见
`seshat-reader-annotation--queued-create-entries'），二者先合并为全量条目
（`seshat-reader-annotation--all-items'，服务端项在前、本地待同步项在后），
再**全量**渲染——单列连续流，不做切片、不显示页脚：本地待同步项带
\"[待同步]\" 标记，并携带各自的
`seshat-reader-annotation-queue-uuid' 属性。

全量条目为空时渲染一行明确提示。

**ETAF 分流**：`seshat-reader-annotation--etaf-p' 为真时先用 ETAF 渲染层
（`seshat-reader-etaf-render-annotations'）渲染卡片列表；渲染层不可用、
加载失败或渲染抛错时回退上面的纯文本渲染（见
`seshat-reader-annotation--render-list-etaf'）。ETAF 路径直接复用上面已
合并好的 ALL-ITEMS（**不再**重复调用 `--etaf-items' 合并一次），把**全量**
条目交给渲染层。两条路径都由
`seshat-reader-sidebar-show' 以 `annotations' 类型统一显示，故面板位置、
高度与 per-kind 记忆不变；条目超出面板高度时由面板**窗口**整体滚动查看。"
  (with-current-buffer (get-buffer-create seshat-reader-annotation-list-buffer-name)
    (let* ((inhibit-read-only t)
           (etaf-mounted (seshat-reader-annotation--etaf-mounted-p))
           (all-items (seshat-reader-annotation--all-items annotations queued)))
      ;; ETAF 已挂载时**不得** `erase-buffer'：ETAF runtime 的节点位置依赖
      ;; 缓冲区既有文本，清空后 `etaf-runtime-flush' 会报「Args out of range」
      ;; 从而整块回退文本渲染（刷新后面板降级）。增量刷新由渲染层自己 flush。
      (unless etaf-mounted
        (erase-buffer))
      ;; 仅首次进入时调用派生 mode，避免每次刷新重复触发 mode hook。
      (unless (derived-mode-p 'seshat-reader-annotation-list-mode)
        (seshat-reader-annotation-list-mode))
      (setq-local seshat-reader-annotation-list-document-id document-id)
      (when uid
        (setq-local seshat-reader-annotation-list-uid uid))
      (setq-local seshat-reader-annotation-list-source source)
      (setq-local seshat-reader-annotation-list-entries annotations)
      (unless (and (seshat-reader-annotation--etaf-p)
                   (seshat-reader-annotation--render-list-etaf
                    all-items document-id source))
        ;; 回退路径：渲染层可能已写入部分文本，故先清空再走文本渲染。
        (erase-buffer)
        (if (null all-items)
            (insert "（该文档没有批注）\n")
          (dolist (item all-items)
            (seshat-reader-annotation--insert-entry
             (list (cons 'id (plist-get item :id))
                   (cons 'location (plist-get item :location))
                   (cons 'text (plist-get item :text)))
             (plist-get item :uuid)))))
      (goto-char (point-min)))
    ;; 列表缓冲区在 `*Seshat Annotations*' 中渲染完毕后，经信息面板统一入口
    ;; 显示（启用面板时投到底部弹出窗口，禁用时 `show' 内部退回
    ;; `pop-to-buffer'）。此处 `(current-buffer)' 即列表缓冲区本身。
    (seshat-reader-sidebar-show (current-buffer) 'annotations t)))

(defun seshat-reader-annotation--refresh-list (document-id &optional source uid)
  "按文档标识 DOCUMENT-ID 重新拉取批注并刷新列表缓冲区.
DOCUMENT-ID 为**显示标识（doc-id）**；SOURCE 为发起列表的 seshat-reader
文档缓冲区（可为 nil）；UID 为服务端权威身份（拉取、删除等 API 操作用
它）。UID 为 nil 时取列表缓冲区的 buffer-local
`seshat-reader-annotation-list-uid'——ETAF 渲染层的刷新路径
（`seshat-reader-etaf--refresh-list'）只传前两个参数，它复用上一次完整
渲染写入的值；两者都取不到时不猜身份：只展示本地待同步条目并提示。

服务端批注渲染在前，本地离线队列中尚未同步的 create 条目以 \"[待同步]\"
追加在后（见 `seshat-reader-annotation--render-list'）——本地项只读队列
文件，不受拉取结果影响。

拉取成功（返回的不是失败哨兵）时渲染服务端项与本地项，随后在
`seshat-reader-annotation-queue-auto-sync' 非 nil 且队列非空时机会性地
尝试一次队列同步；同步发生在本轮渲染之后，故本轮不刷新、已同步条目仍会
显示到下次刷新为止（这样避免了渲染—同步—再渲染的递归与竞态）。

拉取失败（返回 `seshat-reader-annotation--fetch-error' 哨兵）时**不**
清空列表：仍渲染本地待同步条目并提示当前只显示本地批注；队列也为空时只
提示当前没有可显示的批注。两种情形都不会抛出 backtrace。"
  (let* ((uid (or uid
                  (and (get-buffer seshat-reader-annotation-list-buffer-name)
                       (buffer-local-value
                        'seshat-reader-annotation-list-uid
                        (get-buffer seshat-reader-annotation-list-buffer-name)))))
         (queued (seshat-reader-annotation--queued-create-entries uid))
         (result (if uid
                     (seshat-reader-annotation--fetch uid)
                   seshat-reader-annotation--fetch-error)))
    (if (eq result seshat-reader-annotation--fetch-error)
        (progn
          (seshat-reader-annotation--render-list document-id source nil queued uid)
          (cond
           ((null uid)
            (message "Seshat Reader annotation: 未知服务端文档身份，本轮不拉取服务端批注。"))
           (queued
            (message "Seshat Reader annotation: 批注列表（离线）仅显示本地待同步批注 %d 条"
                     (length queued)))
           (t
            (message "Seshat Reader annotation: 当前没有可显示的批注（本地也没有待同步条目）。"))))
      (seshat-reader-annotation--render-list document-id source result queued uid)
      (seshat-reader-annotation--maybe-sync-queue))))

;;; 跳页与删除

(defun seshat-reader-annotation-list-goto ()
  "跳转到当前行批注所在的页面.
页码取自该行的 `seshat-reader-annotation-page' 文本属性（**1-based**），
跳转复用 `seshat-reader-goto-page'。原始文档缓冲区已关闭、不再是
seshat-reader 视图、页码缺失或跳转抛错时只 `message' 提示，不抛出
backtrace。"
  (interactive)
  (let ((page (get-text-property (line-beginning-position)
                                 'seshat-reader-annotation-page))
        (source (buffer-local-value 'seshat-reader-annotation-list-source
                                    (current-buffer))))
    (cond
     ((null page)
      (message "Seshat Reader annotation: 当前行没有可跳转的页码。"))
     ((not (buffer-live-p source))
      (message "Seshat Reader annotation: 原始文档缓冲区已不存在，请重新打开文档后再跳页。"))
     ((not (eq (buffer-local-value 'major-mode source) 'seshat-reader-mode))
      (message "Seshat Reader annotation: 原始缓冲区已不是 seshat-reader 视图，无法跳页。"))
     (t
      (pop-to-buffer source)
      (condition-case err
          (seshat-reader-goto-page page)
        (error
         (message "Seshat Reader annotation: 跳转到第 %d 页失败：%s"
                  page (error-message-string err))))))))

(defun seshat-reader-annotation-list-delete ()
  "删除当前行对应的批注，成功后刷新列表.
按当前行的属性分两条路径：

- 行上有 `seshat-reader-annotation-queue-uuid'（即本地待同步项，见
  `seshat-reader-annotation--insert-entry'）时，用
  `seshat-reader-annotation-queue-remove' 按该 UUID 从本地队列取消并重渲染
  列表——**不发起任何 HTTP**；重渲染复用已缓存的服务端项
  （`seshat-reader-annotation-list-entries'），因此也不会触网。提示按
  `seshat-reader-annotation-queue-remove' 的返回值区分：返回 t 时 `message'
  「已取消本地待同步批注」，返回 nil（该条目已不在队列，可能已同步移除）时
  `message' 「该批注已不在本地队列（可能已同步）」；两种情况都刷新列表。
- 行上没有该属性时，取其 `seshat-reader-annotation-id' 交给
  `seshat-reader-annotation-delete' 删除服务端批注，成功后刷新列表。

当前行既无 UUID 也无批注 `id' 时只 `message' 提示。"
  (interactive)
  (let ((uuid (get-text-property (line-beginning-position)
                                 'seshat-reader-annotation-queue-uuid))
        (id (get-text-property (line-beginning-position)
                               'seshat-reader-annotation-id))
        (document-id (buffer-local-value 'seshat-reader-annotation-list-document-id
                                         (current-buffer)))
        (uid (buffer-local-value 'seshat-reader-annotation-list-uid
                                 (current-buffer)))
        (source (buffer-local-value 'seshat-reader-annotation-list-source
                                    (current-buffer))))
    (cond
     (uuid
      (seshat-reader-annotation--require-queue)
      (if (seshat-reader-annotation-queue-remove uuid)
          (message "Seshat Reader annotation: 已取消本地待同步批注")
        (message "Seshat Reader annotation: 该批注已不在本地队列（可能已同步），列表将刷新"))
      (seshat-reader-annotation--render-list
       document-id source
       (buffer-local-value 'seshat-reader-annotation-list-entries
                           (current-buffer))
       (seshat-reader-annotation--queued-create-entries uid)
       uid))
     ((null id)
      (message "Seshat Reader annotation: 当前行没有关联批注，无法删除。"))
     (t
      (when (seshat-reader-annotation-delete id uid)
        (seshat-reader-annotation--refresh-list document-id source uid))))))

(defun seshat-reader-annotation-delete (id &optional uid)
  "删除编号为 ID 的批注并报告结果.
ID 可为整数或字符串（服务端列表返回的 `id' 可能是整数），发送前一律用
`(format \"%s\" id)' 字符串化，以统一整数/字符串入参。成功时 `message'
报告已删除并返回 t。

UID 为可选的文档服务端身份：删除请求按批注 `id' 定位，并不需要它；它只
随离线队列条目的 `:uid' 一并保存，使队列条目保留文档归属（列表路径会传
`seshat-reader-annotation-list-uid'，交互调用可为 nil）。

失败（非 2xx 或请求异常）时**不**报错：把 `(:action delete :id ID)' 条目
存入本地离线队列（ID 保留入参的原始类型，序列化与同步侧用
`(format \"%s\" id)'），`message' 提示「删除操作已存入本地待同步队列
（N 条待同步）」，并返回 nil。稍后由
`seshat-reader-annotation-queue-sync' 自动同步到服务端。"
  (interactive "s批注 ID: ")
  (let ((id-string (format "%s" id)))
    (condition-case nil
        (if (seshat-rest-delete-annotation id-string)
            (progn
              (message "Seshat Reader annotation: 已删除批注 %s。" id-string)
              t)
          (seshat-reader-annotation--enqueue
           (list :action 'delete :id id :uid uid)
           "删除操作")
          nil)
      (error
       (seshat-reader-annotation--enqueue
        (list :action 'delete :id id :uid uid)
        "删除操作")
       nil))))

(define-derived-mode seshat-reader-annotation-list-mode special-mode "Seshat-Annotations"
  "Major mode for the `*Seshat Annotations*' buffer.

Keybindings:
\\{seshat-reader-annotation-list-mode-map}

`RET' 跳转到当前行批注所在页面，`d' 删除当前行批注。
列表为全量单列连续流（不分页），条目超出面板高度时滚动面板窗口查看。"
  (setq-local truncate-lines t))

(define-key seshat-reader-annotation-list-mode-map (kbd "RET")
            #'seshat-reader-annotation-list-goto)
(define-key seshat-reader-annotation-list-mode-map (kbd "d")
            #'seshat-reader-annotation-list-delete)

(defun seshat-reader-annotation-list ()
  "列出当前文档的全部批注.
从当前缓冲区的 variable `buffer-file-name' 派生两个身份：显示标识
（doc-id，供列表与 `seshat:' 链接）与服务端权威身份（uid，供拉取/刷新/
删除）；uid 由 `GET /api/resolve' 解析并缓存，文档未在服务端登记时
`user-error' 提示。随后向服务端拉取批注并
渲染到 `*Seshat Annotations*'；每行显示 **1-based** 页码与正文摘要
（摘要按 `seshat-reader-annotation-list-summary-width' 截断并以 \"…\"
结尾）。服务端批注在前，本地离线队列中待同步的 create 条目以
\"[待同步]\" 追加在后。

列表缓冲区中 `RET' 跳转到该行批注所在页面（复用
`seshat-reader-goto-page'），`d' 删除该行批注并刷新列表——服务端项走
`seshat-reader-annotation-delete'，本地 \"[待同步]\" 项则由
`seshat-reader-annotation-list-delete' 直接取消本地条目、不发 HTTP。列表
**全量**渲染为单列连续流（不分页、无页脚）：条目超出面板高度时滚动面板
窗口查看。这些键经
`seshat-reader-annotation-list-mode' 的 local keymap 绑定，不依赖
evil；在 evil 环境下它们可能被 evil 接管（evil 会覆盖 `special-mode' 系的
这几个键），需要用户在配置侧处理。

服务端暂时拉不到时**不**报错也不清空列表：仍展示本地待同步条目并提示
「（离线）仅显示本地待同步批注 N 条」；本地也为空时只提示当前没有可显示
的批注。当前缓冲区没有关联文件时 `message' 提示，不会抛出 backtrace。"
  (interactive)
  (let ((file (buffer-file-name)))
    (if file
        ;; 双值：doc-id 供显示与 `seshat:' 链接，uid 供 API（拉取/删除/刷新）
        (seshat-reader-annotation--refresh-list
         (seshat-reader-annotation--doc-id file)
         (current-buffer)
         (seshat-reader-annotation--uid file))
      (message "Seshat Reader annotation: 当前缓冲区没有关联文件，无法确定文档标识。"))))

(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-c C-a") #'seshat-reader-annotation-create)
  (define-key seshat-reader-mode-map (kbd "C-c C-l") #'seshat-reader-annotation-list))

(provide 'seshat-reader-annotation)
;;; seshat-reader-annotation.el ends here
