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
;; 页码徽章 + 摘要 + 「待同步」标记 + 选中高亮 + 底部键位提示）。ETAF 只负责
;; 批注列表；译文/解释由 `seshat-reader-translate' 以 Markdown 文本 buffer 渲染。
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
;; 服务端批注删除、本地队列取消、引用块组装与写文件。引用模块按需加载
;; （`require … nil t`），故此处只作声明，避免字节编译告警，也避免在加载期
;; 引入循环 require。
(declare-function seshat-reader-annotation-queue-remove
                  "seshat-reader-annotation-queue" (uuid))
(declare-function seshat-reader-reference--format-block
                  "seshat-reader-reference" (text doc-id &optional location description))
(declare-function seshat-reader-reference--read-target-file
                  "seshat-reader-reference" ())
(declare-function seshat-reader-reference--insert-into-file
                  "seshat-reader-reference" (text file))

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

(defconst seshat-reader-etaf--annotation-keys
  '(("RET" seshat-reader-etaf-annotation-goto "打开")
    ("d" seshat-reader-etaf-annotation-delete "删除")
    ("C-c C-r" seshat-reader-etaf-annotation-reference "引用")
    ("q" seshat-reader-etaf-quit "关闭")
    ("n" seshat-reader-etaf-annotation-next "下一条")
    ("p" seshat-reader-etaf-annotation-prev "上一条"))
  "批注面板的 ETAF `:keys' 绑定表，元素为 (KEY COMMAND LABEL).
`n' / `p' 移动选中并滚动到选中项；`q' 关闭面板。列表不分页，故无翻页键。")

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
服务端项用 `:id'，本地待同步项用 `:uuid'，ink 聚合行用合成键 `:key'
（见 `seshat-reader-annotation--ink-aggregate-item'）；都缺失时返回 nil。"
  (or (plist-get it :id) (plist-get it :uuid) (plist-get it :key)))

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
文本取自 `seshat-reader-annotation--display-text' 的回退链（备注 → 选中
原文 `selected_text' → ink 聚合文案），再复用
`seshat-reader-annotation--summary' 压缩换行并截断；三者都为空时返回
\"（无正文）\"。"
  (let ((summary (seshat-reader-annotation--summary
                  (seshat-reader-annotation--display-text it))))
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
  location 为 EPUB 的 `chapter:' 形态时该列显示「章 N」（见
  `seshat-reader-annotation--chapter-from-location'），仍解析不出时显示
  `p.?'；
- 摘要单行截断（`seshat-reader-etaf--truncate'），不折行，行高一致；
- 卡片之间用 `:border' 色的细底线分隔（不用 `etaf-divider'，避免过密）。

本函数只负责**一张**卡片；哪些条目出卡片由 `seshat-reader-etaf--annotations-view'
决定——列表**全量**渲染（不分页、不切片）。选中态（`▌' 与底色）取
`seshat-reader-etaf--selected'。"
  (let* ((page (seshat-reader-etaf--item-page it))
         (chapter (and (null page)
                       (seshat-reader-annotation--chapter-from-location
                        (plist-get it :location))))
         (page-label (cond (page (format "p.%s" page))
                           (chapter (format "章%s" chapter))
                           (t "p.?")))
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
                page-label
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

(defun seshat-reader-etaf--badge-text (items)
  "Return the header badge text of the annotation panel.
恒为条目总数 \"N 条\"（列表不分页，「页」的概念对用户无意义）。ITEMS 为首次
渲染时的已知条目列表，仅作 ref 尚无值时（首次 mount 早期）的兜底来源。"
  (format "%d 条" (length (or (etaf-value seshat-reader-etaf--items) items))))

(defun seshat-reader-etaf--annotations-view (items)
  "Return the annotation panel view for ITEMS, a list of plists.
版式自上而下：标题栏（标题 + 右对齐徽章 + 细底线）→ 弱化的文档名 →
卡片列表（全量单列连续流，不限高、无内部滚动）→ 底部键位提示（细顶线）。

**全量渲染**：卡片列表把 `seshat-reader-etaf--items' 的**全部**条目铺开，
不分页也不切片；条目超出面板窗口高度时由**窗口**整体滚动查看，画布本身
不裁剪（根 viewport 高度由 `seshat-reader-etaf-render-annotations' 按条目数
显式计算，见 `seshat-reader-etaf--content-viewport-height'）。徽章恒为条目
总数（见 `seshat-reader-etaf--badge-text'）。

条目的**动态部分**（列表、徽章、文档名）一律经 `(expr …)' 读
`seshat-reader-etaf--items' / `--doc-label'，从而刷新只做增量更新
（`etaf-runtime-flush'）。`:keys' 挂在根 `column' 上，覆盖 ebox 默认滚动键
`n'/`p'（改为移动选中）。"
  (let ((colors (seshat-reader-etaf--colors)))
    (etaf-view
     (column :class "seshat-etaf-annotations"
             :width 'stretch
             :item-gap '(lh 0)
             :keys seshat-reader-etaf--annotation-keys
       ;; 标题栏：标题在左、徽章右对齐，下缘细线
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
             (text (expr (seshat-reader-etaf--badge-text items))))))
       ;; 文档名（弱化，交代上下文）
       (box :width 'stretch
            :padding '((lh 0) (ch 1))
         (expr (seshat-reader-etaf--text-view
                (or (etaf-value seshat-reader-etaf--doc-label) "")
                (alist-get :muted colors))))
       ;; 卡片列表：全量渲染，不限高、无内部滚动（面板窗口整体滚动）
       (column :class "seshat-etaf-list"
               :ref seshat-reader-etaf--list-ref
               :width 'stretch
               :item-gap '(lh 0)
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

(defconst seshat-reader-etaf--chrome-lines 6
  "批注面板除卡片列表外的固定行数估算（标题栏 + 文档名 + 底部提示 + 余量）.
取略大的值：估算偏大只会多申请 viewport 行数，ebox 按实际内容写入、
不补空行，故无视觉副作用；估算偏低则会**裁剪**条目。")

(defconst seshat-reader-etaf--card-lines 2
  "单张批注卡片占用的大致行数估算（单行文本 + 细下边线 + 余量）.")

(defun seshat-reader-etaf--content-viewport-height (items)
  "Return the viewport height in lines that lays out ITEMS in full.
`etaf-mount' 的 `:viewport-height' 决定 ebox 向 buffer 写入多少行：固定 20 行
时超出的卡片会被**裁掉**（画布只排 20 行，不是可滚动内容）。故按条目数
估算 `chrome 行数 + (卡片行数 × 条目数)'，并下限到
`seshat-reader-etaf--default-viewport-height'（空列表也不塌陷）。估算宁大勿小。"
  (max seshat-reader-etaf--default-viewport-height
       (+ seshat-reader-etaf--chrome-lines
          (* seshat-reader-etaf--card-lines (length items)))))

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
选中。ITEMS 即面板的全部条目（列表不分页）。"
  (let* ((keys (mapcar #'seshat-reader-etaf--item-key items))
         (current (etaf-value seshat-reader-etaf--selected)))
    (unless (member current keys)
      (seshat-reader-etaf--select (car keys)))))

(defun seshat-reader-etaf-render-annotations (buffer items doc-id &optional source)
  "Render annotation ITEMS into BUFFER for DOC-ID, remembering SOURCE.
ITEMS 为 plist 列表（**全部**条目，服务端项在前、本地待同步项在后），元素
可含 `:id'、`:uuid'、`:page'、`:text'、`:dirty'、`:location'；列表全量渲染，
不分页。DOC-ID 为文档标识，SOURCE 为发起面板的文档缓冲区（供后续跳页使用）。

viewport 高度按**内容高度**计算
（`seshat-reader-etaf--content-viewport-height'）：`etaf-mount' 的
`:viewport-height' 决定 ebox 写入多少行，固定值会裁掉多余条目，故随条目数
放大——全部卡片都进 buffer，超出面板窗口的部分靠**窗口滚动**查看。

幂等：BUFFER 已有挂载的 runtime 时先按新条目数 refit（视口高度需随条目数
变化，否则新条目被裁），再触发增量刷新；否则首次 `etaf-mount'，并必须传
viewport plist（`:viewport-width' 像素、`:viewport-height' 行），否则没有
布局。refit 失败不中断刷新，但会 `message' 一条警告（便于排查「列表被裁剪」）。

返回 BUFFER（buffer 对象）。"
  (setq seshat-reader-etaf--doc-id doc-id
        seshat-reader-etaf--doc-source source)
  (let* ((target (get-buffer-create buffer))
         (runtime (etaf-runtime-for-buffer target))
         (width (seshat-reader-etaf--viewport-width target))
         (height (seshat-reader-etaf--content-viewport-height items)))
    (setf (etaf-value seshat-reader-etaf--items) items)
    (setf (etaf-value seshat-reader-etaf--doc-label) doc-id)
    (seshat-reader-etaf--ensure-selection items)
    (if runtime
        (progn
          ;; 条目数变化后视口高度必须跟着变：固定高度的视口会裁掉新增条目。
          ;; refit 是体验层操作，失败（runtime 已卸载等）不得影响面板刷新，
          ;; 但必须留一条可排查的警告——静默失败会表现为「列表莫名被裁剪」。
          (condition-case err
              (etaf-runtime-refit runtime width height)
            (error
             (message "Seshat Reader annotation: 刷新 viewport 高度失败（%s），列表可能被裁剪"
                      (error-message-string err))))
          (etaf-runtime-flush runtime))
      (etaf-mount target
                  (seshat-reader-etaf--annotations-view items)
                  (list :viewport-width width
                        :viewport-height height)))
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
到两端时夹紧，不循环；ITEMS 为空时返回 nil 且不清除选中。

列表全量渲染、不分页，故移动只需把新选中项滚入可视区域（滚动是体验增强，
失败不影响选中切换本身：面板未挂载时静默跳过）。"
  (let* ((items (etaf-value seshat-reader-etaf--items))
         (keys (mapcar #'seshat-reader-etaf--item-key items))
         (current (etaf-value seshat-reader-etaf--selected))
         (pos (cl-position current keys :test #'equal))
         (last (1- (length keys)))
         (index (and keys (max 0 (min last (+ (or pos 0) step)))))
         (next (and keys (nth index keys))))
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
  "关闭**当前**（批注列表）面板，保存 per-kind 尺寸记忆.
委托 `seshat-reader-sidebar-quit'：按当前 buffer 名推断 kind
（`*Seshat Annotations*' → `annotations'）后只关该 kind 的承载单元，故与目录
面板、译文/解释面板的 `q' 行为一致——只关自己，不连带关掉其它面板。关闭前由
`seshat-reader-sidebar--toggle-kind' 捕获实测尺寸、记住 buffer，
`M-o' 可原样重开。

此前委托的是 `seshat-reader-sidebar-toggle'（无参 = 全部开合），在 ETAF 渲染
下按 `q' 会把目录与译文面板一并关掉，与另外两个面板的 `q' 语义相反。"
  (interactive)
  (seshat-reader-sidebar-quit))

(provide 'seshat-reader-etaf)

;;; seshat-reader-etaf.el ends here
