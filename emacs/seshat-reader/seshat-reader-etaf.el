;;; seshat-reader-etaf.el --- ETAF rendering for seshat-reader panels  -*- lexical-binding: t; -*-

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

;; seshat-reader 面板的 **ETAF 渲染层**：把批注列表渲染为卡片列表（标题栏 +
;; 页码徽章 + 摘要 + 「待同步」标记 + 选中高亮 + 底部键位提示），把译文面板
;; 渲染为排版布局（标题 + 可折叠原文 + 译文正文 + 操作提示）。
;;
;; 本模块**不负责显示**：仍由 `seshat-reader-sidebar' 统一投放到底部弹出
;; 窗口；buffer 名不变量（`*Seshat Annotations*'、`*Seshat Sidebar*'）由接入
;; 点维持，本模块只接收 buffer 并往里挂 ETAF runtime。
;;
;; **模块加载契约**：本文件**硬** `(require 'etaf-ui)'——ETAF 缺失时加载本
;; 文件即报错。接入点必须用 `(require 'seshat-reader-etaf nil t)' 按需加载并
;; 自行降级（`require' 返回 nil 即表示不可用，走既有纯文本渲染路径）。
;;
;; **主题双色板**：ETAF 的 `etaf-theme-token'（`:ui-*`）取值不随明暗主题变化，
;; 故本模块自带两套色板，按 `(frame-parameter nil 'background-mode)' 选择；
;; 用户切换明暗主题后需**重新渲染面板**（再次调用渲染函数）才会换成新色板。
;;
;; **键位与 evil 的加载顺序**：ETAF 的 `:keys' 依赖 `emulation-mode-map-alists'
;; 的**顺序**——ETAF 的 keymap 会被放在该列表首位，从而优先于 evil 的
;; emulation map。前提是「evil 先启用、面板后 mount」：正常使用场景中 evil 在
;; 启动时已加载而面板是运行期 mount，故前提满足；若在面板挂载**之后**才
;; `(evil-mode 1)'，evil 的 map 会抢在 ETAF 之前，此时需重新渲染（重新 mount）
;; 面板，键位才恢复。
;;
;; **禁止在渲染期写状态**：`etaf-ref' 的写入必须发生在命令/回调中，渲染期只
;; 读值（ETAF 对此有断言）。
;;
;; 本文件是**本仓库自研扩展**：从上游 vendor 重拷 seshat-reader 时应保留本
;; 文件、不得覆盖（vendor 边界见同目录 VENDORED.md）。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-ui)
(require 'seshat-reader-annotation)

;; 动作命令复用的**底层能力**（本模块不调用依赖行文本属性的交互命令）：
;; 服务端批注删除、本地队列取消、引用块组装与写文件，以及「译文存为批注」。
;; 引用模块与译文模块按需加载（`require … nil t`），故此处只作声明，避免
;; 字节编译告警，也避免在加载期引入循环 require。
(declare-function seshat-reader-annotation-queue-remove
                  "seshat-reader-annotation-queue" (uuid))
(declare-function seshat-reader-reference--format-block
                  "seshat-reader-reference" (text doc-id &optional location description))
(declare-function seshat-reader-reference--read-target-file
                  "seshat-reader-reference" ())
(declare-function seshat-reader-reference--insert-into-file
                  "seshat-reader-reference" (text file))
(declare-function seshat-reader-translate-save-as-annotation
                  "seshat-reader-translate" ())

(defgroup seshat-reader-etaf nil
  "ETAF rendering layer for seshat-reader panels."
  :group 'seshat-reader)

(defcustom seshat-reader-etaf-enabled t
  "Non-nil means render seshat-reader panels with ETAF when it is available.
置为 nil 时接入点直接走既有纯文本渲染，行为与未安装 ETAF 时一致。"
  :type 'boolean
  :group 'seshat-reader-etaf)

(defvar seshat-reader-etaf--available nil
  "缓存 `(require \\='etaf-ui nil t)' 的结果；nil 表示尚未探测或不可用.")

(defconst seshat-reader-etaf--default-viewport-width 600
  "面板 buffer 没有可见窗口时使用的 viewport 宽度（像素）.")

(defconst seshat-reader-etaf--default-viewport-height 20
  "面板 buffer 的 viewport 高度（行）；`etaf-mount' 缺它时无布局.")

(defvar seshat-reader-etaf--items (etaf-ref nil)
  "当前面板展示的批注 plist 列表，供渲染与动作命令共用.")

(defvar seshat-reader-etaf--selected (etaf-ref nil)
  "当前选中项的主键：服务端项用 `:id'、本地待同步项用 `:uuid'.")

(defvar seshat-reader-etaf--doc-id nil
  "当前面板对应的文档标识，供动作命令（跳页 / 引用 / 刷新）使用.")

(defvar seshat-reader-etaf--doc-label (etaf-ref nil)
  "标题区弱化显示的文档名（`seshat-reader-etaf--doc-id' 的渲染副本）.
动作命令读平变量 `seshat-reader-etaf--doc-id'，而视图需要经 ref 才能在
`etaf-runtime-flush' 时增量更新，故两者并行存在；写入点统一在
`seshat-reader-etaf-render-annotations'。")

(defvar seshat-reader-etaf--doc-source nil
  "发起面板的 seshat-reader 文档缓冲区，供动作命令跳页时使用.")

(defvar seshat-reader-etaf--translate-title (etaf-ref "Seshat 译文")
  "译文面板的标题文本.")

(defvar seshat-reader-etaf--translate-meta (etaf-ref nil)
  "译文面板标题栏徽章文本（引擎 / 语言），nil 时徽章不显示.")

(defvar seshat-reader-etaf--translate-source (etaf-ref nil)
  "译文面板「原文」区的文本（折叠状态下不显示）.")

(defvar seshat-reader-etaf--translate-body (etaf-ref "")
  "译文面板的译文正文，按空行分段渲染.")

(defvar seshat-reader-etaf--translate-origin (etaf-ref nil)
  "译文面板的「来源」行文本（如 \"来源：第 112 页\"）.")

(defvar seshat-reader-etaf--translate-source-open (etaf-ref nil)
  "译文面板「原文」区是否展开；由折叠按钮 `:on-press' 切换.")

(defconst seshat-reader-etaf--translate-keys
  '(("q" seshat-reader-etaf-quit "关闭"))
  "译文面板的 ETAF `:keys' 绑定表，元素为 (KEY COMMAND LABEL).")

(defconst seshat-reader-etaf--annotation-keys
  '(("RET" seshat-reader-etaf-annotation-goto "打开")
    ("d" seshat-reader-etaf-annotation-delete "删除")
    ("C-c C-r" seshat-reader-etaf-annotation-reference "引用")
    ("q" seshat-reader-etaf-quit "关闭")
    ("n" seshat-reader-etaf-annotation-next "下一条")
    ("p" seshat-reader-etaf-annotation-prev "上一条"))
  "批注面板的 ETAF `:keys' 绑定表，元素为 (KEY COMMAND LABEL).")

(defun seshat-reader-etaf-available-p ()
  "Return non-nil when the ETAF rendering layer may be used.
判断依据是总开关 `seshat-reader-etaf-enabled' 与 `(require \\='etaf-ui nil t)'
是否成功；结果缓存在 `seshat-reader-etaf--available' 中。

`require' **抛错**（ETAF 文件存在但加载失败：字节码与源码不匹配、依赖缺失等）
与返回 nil 一视同仁——`condition-case' 吞掉加载期错误后返回 nil，本函数绝不
向上冒泡，故调用方（`--render-list' 的分流、接入点）无需额外兜底。探测失败
不写入缓存，下次调用会重新探测。"
  (and seshat-reader-etaf-enabled
       (or seshat-reader-etaf--available
           (setq seshat-reader-etaf--available
                 (condition-case nil
                     (and (require 'etaf-ui nil t) t)
                   (error nil))))))

;;; 颜色

(defun seshat-reader-etaf--colors ()
  "Return the color alist for the current frame's background mode.
按 `(frame-parameter nil \\='background-mode)' 区分暗色（`dark'）与亮色
（其它一切取值）：暗色组为深底浅字、亮色组为浅底深字。返回 alist，键为
`:fg'、`:muted'、`:border'（卡片之间的细分隔线）、`:divider'（标题栏 /
底部栏的细线）、`:muted-bg'（原文区等弱化底色）、`:selected-bg'（选中行
底色）、`:accent'（页码 / 选中标记）、`:warning-fg'、`:warning-bg'。

ETAF 的 `etaf-theme-token' 不随明暗主题变化，故这里自带两套色板；用户切换
主题后需重新调用本模块的渲染函数，面板才会换成新色板。"
  (if (eq (frame-parameter nil 'background-mode) 'dark)
      '((:fg . "#E6E6E6")
        (:muted . "#9CA3AF")
        (:border . "#374151")
        (:divider . "#4B5563")
        (:muted-bg . "#263041")
        (:selected-bg . "#374151")
        (:accent . "#93C5FD")
        (:warning-fg . "#FCD34D")
        (:warning-bg . "#4A3F1E"))
    '((:fg . "#1F2937")
      (:muted . "#6B7280")
      (:border . "#E5E7EB")
      (:divider . "#D1D5DB")
      (:muted-bg . "#F3F4F6")
      (:selected-bg . "#E5E7EB")
      (:accent . "#1D4ED8")
      (:warning-fg . "#92400E")
      (:warning-bg . "#FDE68A"))))

;;; 排版基元

;; 面板里的文字一律用下面两个基元渲染，**不用** `etaf-label'/`etaf-badge'：
;; 它们的文字色固定取 ETAF 主题 token（`:ui-fg' = #252A2E 等**亮色主题值**，
;; 且不随明暗主题变化），在暗色主题（如 doom-vibrant）下是深底深字；而
;; `etaf-label' 只接受 `:text'/`:variant'，调用方传的 `:color' 会被静默丢弃
;; （T3 教训）。故这里把颜色/字重放在**父 Host**（`box'）上，由子 `text'
;; 继承——实测 face 属性为 `((:weight bold) (:foreground "#112233"))'。

(defun seshat-reader-etaf--text-view (text &optional color weight)
  "Return a View rendering TEXT in COLOR with font WEIGHT.
COLOR 为 nil 时继承上层色；WEIGHT 取 nil 或 `bold'。样式落在父节点
`box' 上（`text' 只承载字符串），故两者都会真正作用到字形上。"
  (etaf-view
   (box :color color :font-weight weight
     (text (expr text)))))

(defun seshat-reader-etaf--rule (color)
  "Return a 1px full-width horizontal rule painted with COLOR.
由 `flex' + 一个可伸展的空 `box' 组成（与 `etaf-divider' 同构），
`border-bottom' 落在该 box 的运行段上；不用 `etaf-divider' 是因为它的线色
固定取 ETAF 主题 token（`:ui-border'），无法跟随本模块双色板。"
  (etaf-view
   (flex :width 'stretch :align-items 'center
     (box :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0)
          :height '(lh 1)
          :border-bottom-width '(px 1)
          :border-bottom-style 'solid
          :border-bottom-color color))))

(defconst seshat-reader-etaf--summary-display-width 40
  "卡片摘要单行截断的显示宽度（列）.
`seshat-reader-annotation--summary' 已按**字符数**截断，但中日韩字符占两列，
故渲染前再用 `truncate-string-to-width' 按**显示列数**收紧一次，避免长摘要
折行破坏行高一致。")

(defun seshat-reader-etaf--truncate (text)
  "Return TEXT truncated to `…-summary-display-width' display columns.
超宽时以 \"…\" 结尾；TEXT 为空或 nil 时返回空串。"
  (let ((text (or text "")))
    (if (> (string-width text) seshat-reader-etaf--summary-display-width)
        (truncate-string-to-width
         text seshat-reader-etaf--summary-display-width nil nil "…")
      text)))

;;; 条目与卡片

(defun seshat-reader-etaf--item-key (it)
  "Return the stable key of annotation plist IT.
服务端项用 `:id'，本地待同步项用 `:uuid'；两者都缺失时返回 nil。"
  (or (plist-get it :id) (plist-get it :uuid)))

(defconst seshat-reader-etaf--list-ref 'seshat-etaf-annotations-list
  "批注列表面板中可滚动列表容器的 Host 引用名.")

(defun seshat-reader-etaf--item-ref (key)
  "Return the ETAF Host reference symbol of the card keyed by KEY.
KEY 为 nil 时返回 nil。每张卡片行都带该 `:ref'，`next'/`prev' 据此用
`etaf-scroll-into-view' 把新选中项滚入可视区域。"
  (and key (intern (format "seshat-etaf-item-%s" key))))

(defun seshat-reader-etaf--annotation-runtime ()
  "Return the ETAF runtime of the annotation panel buffer, or nil.
面板 buffer 不存在或未挂载时返回 nil（动作命令因此可安全地在无面板时
调用）。"
  (let ((buffer (get-buffer seshat-reader-annotation-list-buffer-name)))
    (and buffer (etaf-runtime-for-buffer buffer))))

(defun seshat-reader-etaf--item-page (it)
  "Return the 1-based page number of annotation plist IT, or nil.
优先取 `:page'，否则用 `seshat-reader-annotation--page-from-location' 从
`:location' 解析。"
  (or (plist-get it :page)
      (seshat-reader-annotation--page-from-location (plist-get it :location))))

(defun seshat-reader-etaf--item-text (it)
  "Return the single-line summary text of annotation plist IT.
复用 `seshat-reader-annotation--summary' 压缩换行并截断；正文为空时返回
\"（无正文）\"。"
  (let ((summary (seshat-reader-annotation--summary (plist-get it :text))))
    (if (string-empty-p summary) "（无正文）" summary)))

(defun seshat-reader-etaf--item-selected-p (it)
  "Return non-nil when annotation plist IT is the selected one."
  (let ((key (seshat-reader-etaf--item-key it)))
    (and key (equal key (etaf-value seshat-reader-etaf--selected)))))

(defun seshat-reader-etaf--card (it colors)
  "Return an ETAF card view for annotation plist IT, themed by COLORS.
COLORS 为 `seshat-reader-etaf--colors' 返回的 alist。一行一卡，列结构固定，
保证纵向对齐：

      选中标记(2ch) · 页码(6ch) · 摘要(可伸展) · [待同步]

- 选中项整行铺 `:selected-bg'，并在首列画 `▌'（用 `:accent' 着色）——未选中
  项该列留空格占位，故各行文字起点不会因选中而错位。该列宽取 `(ch 2)'：
  `▌'（U+258C）在 ETAF 里按 2 列测量，`(ch 1)' 的盒子会把它裁成空格（实测）；
- 页码列宽固定 `(ch 6)'，`p.9' 与 `p.112' 因此右对齐在同一条竖线上；
- 摘要单行截断（`seshat-reader-etaf--truncate'），不折行，行高一致；
- 卡片之间用 `:border' 色的细底线分隔（不用 `etaf-divider'，避免过密）。"
  (let* ((page (seshat-reader-etaf--item-page it))
         (key (seshat-reader-etaf--item-key it))
         (selected (seshat-reader-etaf--item-selected-p it)))
    (etaf-view
     (row :class "seshat-etaf-card"
          :ref (seshat-reader-etaf--item-ref key)
          :width 'stretch
          :item-gap '(ch 1)
          :padding '((lh 0) (ch 1))
          :role 'button
          :tab-index 0
          :background-color (when selected (alist-get :selected-bg colors))
          :border-bottom-width '(px 1)
          :border-bottom-style 'solid
          :border-bottom-color (alist-get :border colors)
          :on-press (lambda () (seshat-reader-etaf--select key))
       (box :width '(ch 2)
         (expr (seshat-reader-etaf--text-view (if selected "▌ " "  ")
                                             (alist-get :accent colors)
                                             'bold)))
       (box :width '(ch 6)
         (expr (seshat-reader-etaf--text-view
                (if page (format "p.%s" page) "p.?")
                (if selected
                    (alist-get :accent colors)
                  (alist-get :muted colors)))))
       (box :flex-grow 1 :min-width '(px 0)
         (expr (seshat-reader-etaf--text-view
                (seshat-reader-etaf--truncate (seshat-reader-etaf--item-text it))
                (alist-get :fg colors)
                (when selected 'bold))))
       (expr (when (plist-get it :dirty)
               (etaf-view
                (box :color (alist-get :warning-fg colors)
                     :background-color (alist-get :warning-bg colors)
                     :padding-inline '(ch 1)
                  (text "待同步")))))))))

(defun seshat-reader-etaf--select (key)
  "Select the annotation whose key is KEY.
KEY 为 nil 时清除选中；本函数只改 `seshat-reader-etaf--selected'，不做
滚动——滚动可见在 T6 接入。"
  (setf (etaf-value seshat-reader-etaf--selected) key))

;;; 面板视图

(defun seshat-reader-etaf--annotations-view (items)
  "Return the annotation panel view for ITEMS, a list of plists.
版式自上而下：标题栏（标题 + 右对齐计数徽章 + 细底线）→ 弱化的文档名 →
卡片列表（可滚动，固定 12 行高）→ 底部键位提示（细顶线）。ITEMS 仅用于
首次渲染时已知条目数；条目的**动态部分**（列表、计数、文档名）一律经
`(expr …)' 读 `seshat-reader-etaf--items' / `--doc-label'，从而增量更新。
`:keys' 挂在根 `column' 上，覆盖 ebox 默认滚动键 `n'/`p'。"
  (let ((colors (seshat-reader-etaf--colors)))
    (etaf-view
     (column :class "seshat-etaf-annotations"
             :width 'stretch
             :item-gap '(lh 0)
             :keys seshat-reader-etaf--annotation-keys
       ;; 标题栏：标题在左、计数徽章右对齐，下缘细线
       (box :width 'stretch
            :padding '((lh 1) (ch 1))
            :border-bottom-width '(px 1)
            :border-bottom-style 'solid
            :border-bottom-color (alist-get :divider colors)
         (flex :width 'stretch :justify-content 'space-between
               :align-items 'center
           (expr (seshat-reader-etaf--text-view "Seshat 批注"
                                                (alist-get :fg colors) 'bold))
           (box :color (alist-get :accent colors)
                :background-color (alist-get :muted-bg colors)
                :padding-inline '(ch 1)
             (text (expr (format "%d 条"
                                 (length (or (etaf-value
                                              seshat-reader-etaf--items)
                                             items))))))))
       ;; 文档名（弱化，交代上下文）
       (box :width 'stretch
            :padding '((lh 0) (ch 1))
         (expr (seshat-reader-etaf--text-view
                (or (etaf-value seshat-reader-etaf--doc-label) "")
                (alist-get :muted colors))))
       ;; 卡片列表
       (column :class "seshat-etaf-list"
               :ref seshat-reader-etaf--list-ref
               :width 'stretch
               :item-gap '(lh 0)
               :height '(lh 12)
               :overflow 'scroll
         (expr (mapcar (lambda (it)
                         (seshat-reader-etaf--card it colors))
                       (etaf-value seshat-reader-etaf--items))))
       ;; 底部键位提示
       (box :width 'stretch
            :padding '((lh 0) (ch 1))
            :border-top-width '(px 1)
            :border-top-style 'solid
            :border-top-color (alist-get :divider colors)
         (expr (seshat-reader-etaf--text-view
                "RET 打开 · d 删除 · C-c C-r 引用 · n/p 移动 · q 关闭"
                (alist-get :muted colors))))))))

(defun seshat-reader-etaf--viewport-width (buffer)
  "Return BUFFER's viewport width in pixels, or the default width.
BUFFER 已显示时取其窗口的像素宽度（不小于 40），否则用
`seshat-reader-etaf--default-viewport-width'——`etaf-mount' 缺 viewport 时
没有布局。"
  (let ((window (get-buffer-window buffer t)))
    (if window
        (max 40 (window-body-width window t))
      seshat-reader-etaf--default-viewport-width)))

;;; 渲染入口

(defun seshat-reader-etaf--ensure-selection (items)
  "Keep `seshat-reader-etaf--selected' pointing at an item of ITEMS.
原选中项已不在 ITEMS 中（或原本就没有选中）时改选首项；ITEMS 为空时清空
选中。"
  (let* ((keys (mapcar #'seshat-reader-etaf--item-key items))
         (current (etaf-value seshat-reader-etaf--selected)))
    (unless (member current keys)
      (seshat-reader-etaf--select (car keys)))))

(defun seshat-reader-etaf-render-annotations (buffer items doc-id
                                                    &optional source)
  "Render annotation ITEMS into BUFFER for DOC-ID, remembering SOURCE.
ITEMS 为 plist 列表，元素可含 `:id'、`:uuid'、`:page'、`:text'、`:dirty'、
`:location'；服务端项在前、本地待同步项在后。DOC-ID 为文档标识，SOURCE 为
发起面板的文档缓冲区（供后续跳页使用）。

幂等：BUFFER 已有挂载的 runtime 时只改 `seshat-reader-etaf--items' 触发
增量刷新，不重建组件树；否则首次 `etaf-mount'，并必须传 viewport plist
（`:viewport-width' 像素、`:viewport-height' 行），否则没有布局。

返回 BUFFER（buffer 对象）。"
  (setq seshat-reader-etaf--doc-id doc-id
        seshat-reader-etaf--doc-source source)
  (let* ((target (get-buffer-create buffer))
         (runtime (etaf-runtime-for-buffer target)))
    (setf (etaf-value seshat-reader-etaf--items) items)
    (setf (etaf-value seshat-reader-etaf--doc-label) doc-id)
    (seshat-reader-etaf--ensure-selection items)
    (if runtime
        (etaf-runtime-flush runtime)
      (etaf-mount target
                  (seshat-reader-etaf--annotations-view items)
                  (list :viewport-width
                        (seshat-reader-etaf--viewport-width target)
                        :viewport-height
                        seshat-reader-etaf--default-viewport-height)))
    target))

;;; 动作命令（从选中项解析底层能力）

(defun seshat-reader-etaf--scroll-selected-into-view (&optional key)
  "Scroll the annotation list so the card keyed by KEY becomes visible.
KEY 省略时取当前选中项的 key。面板未挂载、无 runtime 或 key 为 nil 时静默
返回——滚动可见是**体验增强**，失败不得影响选中切换与命令本身的语义。"
  (let* ((runtime (seshat-reader-etaf--annotation-runtime))
         (ref (seshat-reader-etaf--item-ref
               (or key (etaf-value seshat-reader-etaf--selected)))))
    (when (and runtime ref)
      (ignore-errors (etaf-scroll-into-view runtime ref)))
    ref))

(defun seshat-reader-etaf--selected-item ()
  "Return the selected annotation plist, or nil when nothing is selected."
  (let ((key (etaf-value seshat-reader-etaf--selected)))
    (and key
         (cl-find-if (lambda (it)
                       (equal key (seshat-reader-etaf--item-key it)))
                     (etaf-value seshat-reader-etaf--items)))))

(defun seshat-reader-etaf--move-selection (step)
  "Move the selection by STEP items and return the new key.
到两端时夹紧，不循环；ITEMS 为空时返回 nil 且不清除选中。移动成功后把新
选中项滚入可视区域（`etaf-scroll-into-view'，面板未挂载时静默跳过）。"
  (let* ((items (etaf-value seshat-reader-etaf--items))
         (keys (mapcar #'seshat-reader-etaf--item-key items))
         (current (etaf-value seshat-reader-etaf--selected))
         (pos (cl-position current keys :test #'equal))
         (last (1- (length keys)))
         (next (and keys
                    (nth (max 0 (min last (+ (or pos 0) step))) keys))))
    (when next
      (seshat-reader-etaf--select next)
      (seshat-reader-etaf--scroll-selected-into-view next))
    next))

(defun seshat-reader-etaf--cached-annotations ()
  "Return the cached server-side annotation alist list of the panel, or nil.
缓存位于列表缓冲区的 `seshat-reader-annotation-list-entries'（由
`seshat-reader-annotation--render-list' 每次渲染时写入），因此取它**不触网**。"
  (let ((buffer (get-buffer seshat-reader-annotation-list-buffer-name)))
    (and buffer
         (buffer-local-value 'seshat-reader-annotation-list-entries buffer))))

(defun seshat-reader-etaf--rerender-cached ()
  "Re-render the annotation panel from cache, without any HTTP request.
服务端项取自 `seshat-reader-etaf--cached-annotations'（列表缓冲区缓存），
本地待同步项重新读离线队列（只读本地文件，见
`seshat-reader-annotation--queued-create-entries'），随后交给
`seshat-reader-annotation--render-list' 统一重渲染——ETAF 可用时仍走卡片
路径，不可用时回退文本渲染。用于「取消本地待同步项」这类**不改变服务端
列表**的场合：与 `seshat-reader-annotation-list-delete' 的 uuid 分支同款。"
  (seshat-reader-annotation--render-list
   seshat-reader-etaf--doc-id
   seshat-reader-etaf--doc-source
   (seshat-reader-etaf--cached-annotations)
   (seshat-reader-annotation--queued-create-entries seshat-reader-etaf--doc-id)))

(defun seshat-reader-etaf--refresh-list ()
  "Re-fetch and re-render the annotation panel for the current document.
复用 `seshat-reader-annotation--refresh-list'（服务端批注在前、本地待同步
项在后，两条路径的渲染分流也由它负责）。文档标识缺失时只重渲染本地缓存，
不发请求；拉取失败由该函数自行降级，不抛 backtrace。"
  (if seshat-reader-etaf--doc-id
      (seshat-reader-annotation--refresh-list
       seshat-reader-etaf--doc-id seshat-reader-etaf--doc-source)
    (seshat-reader-etaf-render-annotations
     seshat-reader-annotation-list-buffer-name
     (etaf-value seshat-reader-etaf--items)
     nil seshat-reader-etaf--doc-source)))

(defun seshat-reader-etaf-annotation-goto ()
  "跳转到选中批注所在页.
页码由选中项的 `:location' 解析（见 `seshat-reader-etaf--item-page'），跳转
复用 `seshat-reader-goto-page'。发起面板的文档缓冲区已关闭、或已不是
`seshat-reader-mode' 时只 `message' 提示，不抛 backtrace。"
  (interactive)
  (let ((it (seshat-reader-etaf--selected-item)))
    (cond
     ((null it)
      (message "Seshat Reader: 没有选中的批注"))
     (t
      (let ((page (seshat-reader-etaf--item-page it))
            (source seshat-reader-etaf--doc-source))
        (cond
         ((null page)
          (message "Seshat Reader: 该批注没有可解析的页码，无法跳页"))
         ((not (buffer-live-p source))
          (message "Seshat Reader: 原始文档缓冲区已不存在，请重新打开文档后再跳页。"))
         ((not (eq (buffer-local-value 'major-mode source) 'seshat-reader-mode))
          (message "Seshat Reader: 原始缓冲区已不是 seshat-reader 视图，无法跳页。"))
         (t
          (pop-to-buffer source)
          (condition-case err
              (seshat-reader-goto-page page)
            (error
             (message "Seshat Reader: 跳转到第 %d 页失败：%s"
                      page (error-message-string err)))))))))))

(defun seshat-reader-etaf-annotation-delete ()
  "删除选中的批注并刷新面板.
按选中项的来源分两条路径：

- 服务端项（`:id' 非 nil）→ `seshat-reader-annotation-delete'（含离线队列
  语义：失败时把删除操作存入本地待同步队列），成功返回 t 时刷新面板；
- 本地待同步项（`:uuid' 非 nil）→ `seshat-reader-annotation-queue-remove'
  按 UUID 从本地队列取消，**不发任何 HTTP 请求**；随后用
  `seshat-reader-etaf--rerender-cached' 从缓存重渲染面板（服务端项取列表
  缓冲区缓存、本地项重读队列文件），同样不触网——取消本地待同步项不改变
  服务端列表，无需重新拉取。

既无 `:id' 也无 `:uuid' 时只 `message' 提示。"
  (interactive)
  (let ((it (seshat-reader-etaf--selected-item)))
    (cond
     ((null it)
      (message "Seshat Reader: 没有选中的批注"))
     ((plist-get it :uuid)
      (require 'seshat-reader-annotation-queue nil t)
      (if (seshat-reader-annotation-queue-remove (plist-get it :uuid))
          (message "Seshat Reader: 已取消本地待同步批注")
        (message "Seshat Reader: 该批注已不在本地队列（可能已同步），列表将刷新"))
      (seshat-reader-etaf--rerender-cached))
     ((plist-get it :id)
      (when (seshat-reader-annotation-delete (plist-get it :id))
        (seshat-reader-etaf--refresh-list)))
     (t
      (message "Seshat Reader: 该条批注既无 id 也无 uuid，无法删除")))))

(defun seshat-reader-etaf-annotation-reference ()
  "把选中的批注作为摘录引用插入目标笔记.
摘录块由 `seshat-reader-reference--format-block' 用批注正文、文档标识与
`:location' 组装，目标文件由 `seshat-reader-reference--read-target-file'
决定（已配置则直用，否则交互选择），写入复用
`seshat-reader-reference--insert-into-file'。引用失败（正文为空、文档标识
缺失、写文件抛错）只 `message' 提示；`user-error'（如取消选择文件）原样
冒泡，不吞掉用户意图。"
  (interactive)
  (let ((it (seshat-reader-etaf--selected-item)))
    (cond
     ((null it)
      (message "Seshat Reader: 没有选中的批注"))
     ((let ((text (plist-get it :text)))
        (or (not (stringp text)) (string-empty-p (string-trim text))))
      (message "Seshat Reader: 该批注没有正文，无法插入引用"))
     ((null seshat-reader-etaf--doc-id)
      (message "Seshat Reader: 未知文档标识，无法组装引用，请重新打开批注列表。"))
     (t
      (require 'seshat-reader-reference nil t)
      (condition-case err
          (let* ((block (seshat-reader-reference--format-block
                         (plist-get it :text)
                         seshat-reader-etaf--doc-id
                         (plist-get it :location)))
                 (file (seshat-reader-reference--read-target-file)))
            (seshat-reader-reference--insert-into-file block file)
            (message "Seshat Reader: 已把批注引用插入 %s" file))
        (user-error
         (signal (car err) (cdr err)))
        (error
         (message "Seshat Reader: 插入引用失败：%s"
                  (error-message-string err))))))))

(defun seshat-reader-etaf-annotation-next ()
  "选中下一条批注，并把它滚入可视区域.
选中移动到面板末尾时夹紧（不循环）；滚动失败静默跳过。"
  (interactive)
  (seshat-reader-etaf--move-selection 1))

(defun seshat-reader-etaf-annotation-prev ()
  "选中上一条批注，并把它滚入可视区域.
选中移动到面板开头时夹紧（不循环）；滚动失败静默跳过。"
  (interactive)
  (seshat-reader-etaf--move-selection -1))

(defun seshat-reader-etaf-quit ()
  "关闭本包信息面板（保存 per-kind 高度记忆）.
复用 `seshat-reader-sidebar-toggle'：关闭前捕获各面板窗口的实测高度，
下次打开同类型面板时按记忆恢复。"
  (interactive)
  (seshat-reader-sidebar-toggle))

;;; 译文面板

(defun seshat-reader-etaf--paragraphs (text)
  "Split TEXT into paragraphs for the translate panel.
按空行（一个以上换行，允许行尾空白）分段，去掉每段首尾空白并丢弃空段；
TEXT 为 nil 或全空白时返回 nil。"
  (when (stringp text)
    (let (result)
      (dolist (para (split-string text "\n[ \t]*\n" t))
        (let ((trimmed (string-trim para)))
          (unless (string-empty-p trimmed)
            (push trimmed result))))
      (nreverse result))))

(defconst seshat-reader-etaf--origin-line-regexp
  "[ \t]*来源[：:]"
  "匹配 gt 正文里可能与面板「来源」行重复的元信息行的**行首**部分.
只锚定行首（不锚行尾）：重复行形如 \"来源：第 112 页\"，冒号后还有页码，
锚行尾会一条也删不掉。")

(defun seshat-reader-etaf--drop-origin-lines (text)
  "Return TEXT without its 「来源：…」 metadata lines.
译文面板的「来源：第 N 页」由视图**结构化**渲染一次
（`seshat-reader-etaf--selection-origin'），故正文里若也带同一行就会重复
显示——gt 的正文来自 `seshat-reader-translate--gt-buffer-text'（`gt-result'
片段，提取不到时回退整个 gt buffer 的 `buffer-string'，含 gt 自己插入的
原文/引擎区块），而 `seshat-reader-translate--clean-gt-text' 只剔除分隔线与
多余空行，**不**过滤「来源」行，故该行会原样进入正文。此处在渲染前把它
剔除，保证面板中「来源」只出现一次。TEXT 为 nil 时返回 nil。"
  (when (stringp text)
    (let ((kept (cl-remove-if
                 (lambda (line)
                   (string-match-p
                    (concat "\\`" seshat-reader-etaf--origin-line-regexp)
                    (string-trim line)))
                 (split-string text "\n"))))
      (string-trim (mapconcat #'identity kept "\n")))))

(defun seshat-reader-etaf--translate-meta (engine langs)
  "Compose the translate panel badge text from ENGINE and LANGS.
ENGINE 为引擎名（字符串或符号，nil 表示未知），LANGS 为语言符号列表；两者
都为空时返回 nil（徽章不显示）。都给出时返回 \"ENGINE → lang1→lang2\"。"
  (let ((engine (and engine (format "%s" engine)))
        (langs (and langs
                    (mapconcat #'symbol-name (ensure-list langs) "→"))))
    (cond
     ((and engine langs) (format "%s → %s" engine langs))
     (engine engine)
     (langs langs)
     (t nil))))

(defun seshat-reader-etaf--selection-origin ()
  "Return the translate panel's origin line for the last mouse selection.
取 `seshat-reader-select-last' 的 `:page'（**1-based**）拼出
\"来源：第 N 页\"；无选区或无页码时返回 \"来源：选区\"。"
  (let ((page (plist-get seshat-reader-select-last :page)))
    (if page (format "来源：第 %s 页" page) "来源：选区")))

(defun seshat-reader-etaf--toggle-translate-source ()
  "Toggle the translate panel's source section.
只翻转 `seshat-reader-etaf--translate-source-open'，由渲染期的读取触发增量
刷新；在渲染期之外调用（命令/回调内），符合 ETAF 的写状态约束。"
  (setf (etaf-value seshat-reader-etaf--translate-source-open)
        (not (etaf-value seshat-reader-etaf--translate-source-open))))

(defun seshat-reader-etaf--save-translate-as-annotation ()
  "Save the currently displayed translation as an annotation.
把译文交给 `seshat-reader-translate-save-as-annotation'（侧车批注，不写回
文档）；译文模块未加载时只 `message' 提示，不抛 void-function。"
  (if (fboundp 'seshat-reader-translate-save-as-annotation)
      (seshat-reader-translate-save-as-annotation)
    (message "Seshat Reader: 译文模块未加载，无法存为批注")))

(defconst seshat-reader-etaf--translate-source-excerpt-limit 200
  "原文折叠区展开时显示的字符数上限.")

(defun seshat-reader-etaf--translate-source-excerpt ()
  "Return the first `…-limit' characters of the translate panel's source text.
无原文时返回 nil。超出上限时以 \"…\" 结尾，避免长选区把面板撑满。"
  (let ((source (etaf-value seshat-reader-etaf--translate-source)))
    (when (and (stringp source) (not (string-empty-p (string-trim source))))
      (let ((trimmed (string-trim source)))
        (if (> (length trimmed)
               seshat-reader-etaf--translate-source-excerpt-limit)
            (concat (substring trimmed 0
                               seshat-reader-etaf--translate-source-excerpt-limit)
                    "…")
          trimmed)))))

(defun seshat-reader-etaf--translate-view ()
  "Return the translate panel view, reading all content from refs.
版式自上而下：标题栏（标题 + 右对齐引擎/语言徽章 + 细底线）→ 可折叠原文
（折叠时只有一行按钮；展开后放进浅底 `box'，文字弱化）→ 译文正文（段落之间
留 1 行，正常前景色）→ **唯一一处**「来源」行（弱化）→ 底部操作行（左
「q 关闭」提示、右「存为批注」按钮，`flex :justify-content` 为
`space-between'）。

动态内容（标题、徽章、原文、正文、来源）全部经 `(expr …)' / `etaf-value'
读取，故再次渲染同一 buffer 时只做增量更新——非 `expr' 的静态属性在 mount
时求值一次，不会随 flush 变化（这是「第二次翻译后来源行不更新」的根因）。

来源只出现一次：正文里的「来源：…」行在渲染前由
`seshat-reader-etaf--drop-origin-lines' 剔除，仅保留这里结构化的一行。

原文区默认折叠：展开状态由 `seshat-reader-etaf--translate-source-open'
控制，按钮文字随状态在 \"▸ 原文\" 与 \"▾ 原文\" 之间切换。"
  (let ((colors (seshat-reader-etaf--colors)))
    (etaf-view
     (column :class "seshat-etaf-translate"
             :width 'stretch
             :item-gap '(lh 0)
             :padding '((lh 0) (ch 1))
             :keys seshat-reader-etaf--translate-keys
       ;; 标题栏
       (box :width 'stretch
            :padding '((lh 1) (ch 0))
            :border-bottom-width '(px 1)
            :border-bottom-style 'solid
            :border-bottom-color (alist-get :divider colors)
         (flex :width 'stretch :justify-content 'space-between
               :align-items 'center
           (expr (seshat-reader-etaf--text-view
                  (etaf-value seshat-reader-etaf--translate-title)
                  (alist-get :fg colors) 'bold))
           (expr (when-let* ((meta (etaf-value seshat-reader-etaf--translate-meta)))
                                       (etaf-view
                                       (box :color (alist-get :accent colors)
                                            :background-color (alist-get :muted-bg colors)
                                            :padding-inline '(ch 1)
                                         (text (expr meta))))))))
       ;; 原文折叠开关（常态一行；展开后下方的浅底区块说明内容）
       (box :width 'stretch
            :padding '((lh 0) (ch 0))
         (etaf-button :variant 'ghost
                      :label (if (etaf-value
                                  seshat-reader-etaf--translate-source-open)
                                 "▾ 原文" "▸ 原文")
                      :color (alist-get :muted colors)
                      :on-press #'seshat-reader-etaf--toggle-translate-source))
       (expr (when (etaf-value seshat-reader-etaf--translate-source-open)
               (etaf-view
                (box :width 'stretch
                     :background-color (alist-get :muted-bg colors)
                     :padding '((lh 0) (ch 1))
                     :wrap-mode 'word
                  (expr (seshat-reader-etaf--text-view
                         (or (seshat-reader-etaf--translate-source-excerpt)
                             "（无原文）")
                         (alist-get :muted colors)))))))
       ;; 译文正文：段落之间 1 行间距
       (column :class "seshat-etaf-translate-body"
               :width 'stretch
               :item-gap '(lh 1)
               :wrap-mode 'word
               :padding '((lh 1) (ch 0))
         (expr (mapcar (lambda (paragraph)
                         (etaf-view
                          (box :color (alist-get :fg colors)
                            (text (expr paragraph)))))
                       (seshat-reader-etaf--paragraphs
                        (seshat-reader-etaf--drop-origin-lines
                         (etaf-value seshat-reader-etaf--translate-body))))))
       ;; 来源：全面板唯一一处
       (expr (let ((origin (etaf-value seshat-reader-etaf--translate-origin)))
               (when (and (stringp origin) (not (string-empty-p origin)))
                 (etaf-view
                  (box :width 'stretch
                       :padding '((lh 0) (ch 0))
                    (expr (seshat-reader-etaf--text-view
                           origin (alist-get :muted colors))))))))
       ;; 底部操作行：左提示、右按钮
       (box :width 'stretch
            :padding '((lh 0) (ch 0))
            :border-top-width '(px 1)
            :border-top-style 'solid
            :border-top-color (alist-get :divider colors)
         (flex :width 'stretch :justify-content 'space-between
               :align-items 'center
           (expr (seshat-reader-etaf--text-view "q 关闭"
                                                (alist-get :muted colors)))
           (etaf-button :variant 'ghost
                        :label "存为批注"
                        :color (alist-get :accent colors)
                        :on-press
                        #'seshat-reader-etaf--save-translate-as-annotation)))))))

(cl-defun seshat-reader-etaf-render-translate
    (buffer &key title source body engine langs)
  "Render the translate panel into BUFFER.
TITLE 为面板标题（默认 \"Seshat 译文\"），SOURCE 为原文（折叠区内容），
BODY 为译文正文（按空行分段排版），ENGINE 与 LANGS 组成标题栏的引擎/语言
徽章（都为空时不显示）。来源行取自最近一次选区的页码。

幂等：BUFFER 已挂载 runtime 时只改各 ref 并 `etaf-runtime-flush' 做增量
刷新，不重建组件树；否则首次 `etaf-mount'（必须带 viewport plist）。返回
BUFFER（buffer 对象）。"
  (let* ((target (get-buffer-create buffer))
         (runtime (etaf-runtime-for-buffer target)))
    (setf (etaf-value seshat-reader-etaf--translate-title) (or title "Seshat 译文"))
    (setf (etaf-value seshat-reader-etaf--translate-meta)
          (seshat-reader-etaf--translate-meta engine langs))
    (setf (etaf-value seshat-reader-etaf--translate-source) source)
    (setf (etaf-value seshat-reader-etaf--translate-body) (or body ""))
    (setf (etaf-value seshat-reader-etaf--translate-origin)
          (seshat-reader-etaf--selection-origin))
    (if runtime
        (etaf-runtime-flush runtime)
      (etaf-mount target
                  (seshat-reader-etaf--translate-view)
                  (list :viewport-width
                        (seshat-reader-etaf--viewport-width target)
                        :viewport-height
                        seshat-reader-etaf--default-viewport-height)))
    target))

(provide 'seshat-reader-etaf)

;;; seshat-reader-etaf.el ends here
