;;; seshat-reader-translate.el --- Translate and explain reader selections -*- lexical-binding: t; -*-

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

;; 桥接 go-translate（gt）与阅读器选区：把最近一次鼠标拖拽选中的文本交给
;; gt 翻译或解释，渲染完成后把纯译文写入
;; `seshat-reader-translate-last-result'。
;;
;; gt 是**软依赖**：本模块不在顶层 `require' gt，只在
;; `seshat-reader-translate--ensure-gt' 中按需加载；未安装 gt 时给出明确
;; `user-error'，不产生 void-function 崩溃。
;;
;; 译文的呈现方式由 gt 预设（`gt-preset-translators'）与
;; `seshat-reader-translate-render' 共同决定：
;;
;; - `sidebar'（**默认**）：gt 先渲染到**隐藏中转 buffer**
;;   （`seshat-reader-translate--gt-buffer-name'，`:window-config' 用
;;   `(display-buffer-no-window)' 故不弹窗）；其 `:then' 回调在渲染完成后
;;   从中转 buffer 取纯译文，写入**底部信息面板**的普通只读 buffer
;;   （`seshat-reader-sidebar-translate-buffer-name'，默认
;;   \"*Seshat Sidebar*\"）并以 Markdown 只读视图显示——原生滚动、折行、复制
;;   与 isearch 全部可用，不再受 ETAF 固定画布高度限制。面板位置与高度由
;;   `seshat-reader-sidebar-position' / `seshat-reader-sidebar-height' 决定，
;;   且显示后按内容自适应（上限 `seshat-reader-sidebar-max-height'）；
;;   面板内 `q'（`seshat-reader-sidebar-quit'，由 minor mode
;;   `seshat-reader-translate-panel-mode' 承载）或
;;   `seshat-reader-sidebar-toggle' 可关闭。
;; - `pop'/`pin'：回退 posframe（`gt-posframe-pop-render' 弹出、失焦即消失 /
;;   `gt-posframe-pin-render' 常驻），可在配置侧切回。
;;
;; 流式增量（`seshat-reader-translate-stream'，默认开启）：构造翻译器时把
;; **克隆后的**引擎的 `stream' 槽设为 t（引擎对象也要再克隆——eieio 的
;; `clone' 是浅拷贝，translator 的 `engines' 槽与预设共享同一批引擎对象），
;; 并把 `gt-buffer-render-output-hook' 的增量同步到面板：首个增量写入模板
;; 骨架（正文 `%t' 为空）并记录正文起点 marker，后续只替换 marker 之后的
;; 正文区；完成时只更新 header-line 状态、不 erase 重写（避免完成瞬间整块
;; 跳变）。`stream' 为 nil 或引擎无该槽时退回「完成即整体渲染」的旧路径。
;;
;; 捕获译文：面板路径在 `:then' 回调内完成（`--panel-result'），不依赖任何
;; 全局 hook，故零误捕获；posframe 路径复用
;; `gt-posframe-pop-render-output-hook'（弹出）与
;; `gt-posframe-pin-render-output-hook'（固定），并在
;; `--capture-result' 中用启动时间戳的时间窗口守卫过滤其它 gt 用法。
;;
;; 文档身份与位置（`location'）的约定见 `seshat-reader-annotation'：存批注
;; 时发送的是服务端权威 uid（`seshat-reader-annotation--uid'），显示用
;; doc-id（`seshat-reader-annotation--doc-id'）只用于提示文案。
;;
;; 本模块**不做 OCR**：扫描件（页面无文本层）无法取词，需等 M11.6 的
;; OCR 支持。

;;; Code:

(require 'seshat-reader)
(require 'seshat-rest)
(require 'seshat-reader-annotation)
;; 信息面板承载体（零依赖模块）；本模块用它取面板 buffer 名、
;; `--display-params' 与统一显示入口。
(require 'seshat-reader-sidebar)
;; `cl-every' 用于校验语言列表（`--format-langs'）；cl-lib 是内置库，
;; 加载成本可忽略。注意它**不是** `-Q' 批处理下默认已加载的库。
(require 'cl-lib)

(eval-when-compile
  ;; `oset'/`oref' 是内置 eieio 的宏，仅在**编译期**需要 eieio 才能正确
  ;; 展开为 `eieio-oset'/`eieio-oref'；运行时本模块不加载 gt/eieio，二者
  ;; 由 `seshat-reader-translate--ensure-gt' 按需加载 gt 时一并可用。
  (require 'eieio)
  ;; gt 是软依赖，编译期不加载 gt，故 eieio 的槽名编译器宏
  ;; （`eieio--check-slot-name'，判据是 `slot-name' 符号属性）会把
  ;; `gt-translator' 的真实槽 `taker'、`render' 判为未知槽，各报一条
  ;; 「Unknown slot」告警。这里在编译期登记这两个槽名，消除无意义告警；
  ;; 只影响编译期判定，运行时语义不变。
  (put 'taker 'slot-name t)
  (put 'render 'slot-name t)
  ;; 流式渲染（T4）还要读写 `gt-translator' 的 `engines' 槽与 `gt-engine' 的
  ;; `stream' 槽，同样在编译期登记，避免两条无意义的「Unknown slot」告警。
  (put 'engines 'slot-name t)
  (put 'stream 'slot-name t))

(declare-function eieio-oset "eieio-core" (obj slot value))
(declare-function eieio-oref "eieio-core" (obj slot))
(declare-function clone "eieio" (obj))
(declare-function gt-ensure-plain "gt-core" (obj &rest args))
(declare-function gt-taker "gt-core" (&rest args))
(declare-function gt-translator "gt-core" (&rest args))
(declare-function gt-youdao-dict-engine "gt-engine-youdao" (&rest args))
(declare-function gt-google-engine "gt-engine-google" (&rest args))
(declare-function gt-posframe-pop-render "gt-render-posframe" (&rest args))
(declare-function gt-posframe-pin-render "gt-render-posframe" (&rest args))
(declare-function gt-buffer-render "gt-render-buffer" (&rest args))
(declare-function gt-start "gt-core" (translator))
;; 流式渲染需要判定引擎是否有 `stream' 槽（`gt-engine' 基类定义，部分引擎不
;; 支持）；`slot-exists-p' 是 eieio-core 的函数，编译期声明签名以免告警。
(declare-function slot-exists-p "eieio-core" (object-or-class slot))
;; visual-fill-column 同样是软依赖（只在 `--prepare-view' 内按需加载），
;; 编译期不加载其库，故显式声明签名以消除「not known to be defined」告警。
(declare-function visual-fill-column-mode "visual-fill-column" (&optional arg))

(defvar gt-preset-translators)

(defvar seshat-reader-select-last nil
  "最近一次鼠标选区，正式定义与完整语义见 `seshat-reader-select'.
此处声明仅用于避免字节编译告警，并保证在 `seshat-reader-select' 尚未
加载时该变量仍有 nil 绑定，使本模块的“无选区”检查走 `user-error' 而
不是 void-variable 崩溃。")

(defvar seshat-reader-translate-last-result nil
  "最近一次翻译/解释的纯译文文本，或 nil.
由 `seshat-reader-translate--record-result' 写入：面板路径经
`seshat-reader-translate--panel-result' 在 gt 的 `:then' 回调内调用它，
posframe 路径经 `seshat-reader-translate--capture-result' 从输出 hook 调用它。
值为按 `seshat-reader-translate-engines-pick' 从渲染缓冲区中带 `gt-result'
文本属性的片段里**格式化出的正文**（默认 `all'：全部成功结果逐条标注来源引擎
名、段间加 Markdown 分隔线，与面板显示完全一致；取 `first'/`last' 时只有选
中那一份的纯译文、不带标签，见 `seshat-reader-translate--extract-result'）。
翻译失败语义分两个层面（有意为之）：
**显示层**不清空——失败路径不会调用
`seshat-reader-translate--render-panel'，面板 buffer 保留上一次渲染的内容，
用户仍能看到旧译文；**变量层**则会被清空——
`seshat-reader-translate-selection' 与
`seshat-reader-translate-explain-selection' 在调用 `gt-start' 之前显式把
本变量置为 nil，失败后自然保持 nil，因此失败后再调用
`seshat-reader-translate-save-as-annotation' 会以 `user-error' 提示「尚无
译文」，不会把上一次的旧译文误存为批注。")

(defvar seshat-reader-translate--active nil
  "最近一次本包发起的翻译/解释的启动时间戳（the function `float-time' 的返回值），或 nil.
由 `seshat-reader-translate-selection' 与
`seshat-reader-translate-explain-selection' 在调用 `gt-start' 之前写入；
`seshat-reader-translate--capture-result' 仅当该时间戳存在、且距当前时间
不超过 `seshat-reader-translate-capture-window' 秒时才捕获译文，用以区分
本包发起的翻译与其它 go-translate 用法（后者同样会触发全局渲染输出
hook）。")

(defvar seshat-reader-translate--current-translator nil
  "本次发起的 gt translator 对象，或 nil.
由 `seshat-reader-translate--enable-stream' 在装配翻译器时写入，供
`seshat-reader-translate--stream-sync' 做身份守卫：go-translate 每次输出都会
把当前 translator 写进中转 buffer 的 buffer-local 变量
`gt-buffer-render-translator'，只有二者 `eq' 相同时才认为这份增量属于本包
（否则可能是用户自己的 gt 用法触发的输出）。
**这是绕过 gt 内部约定的 HACK**：gt 的 `gt-buffer-render-output-hook' 不带
translator 参数，只能事后比对 buffer-local 变量；gt 升级若改用其它变量名或
改变调用时机，本守卫会退化为「永不匹配」，此时面板退回完成时整体渲染
（`seshat-reader-translate--panel-result' 路径仍在），不会出错。")

(defvar seshat-reader-translate--stream-title nil
  "本次请求写进面板 header-line 的标题（\"Seshat 译文\" / \"Seshat 解释\"），或 nil.
由 `seshat-reader-translate--translator' 在装配翻译器时写入，供流式骨架首次
创建面板 buffer 时使用（`seshat-reader-translate--stream-init'）。")

(defvar seshat-reader-translate--stream-langs nil
  "本次请求的目标语言列表（供面板模板 `%l'），由 `--translator' 写入.")

(defvar seshat-reader-translate--stream-context nil
  "本次请求的语境（`translate' / `explain'，决定用哪个模板），由 `--translator' 写入.")

(defvar seshat-reader-translate--last-sync-time nil
  "最近一次流式滚动跟随的时间戳（the function `float-time' 的返回值），或 nil.
只用于节流滚动，见 `seshat-reader-translate--stream-scroll-due-p'。")

(defvar-local seshat-reader-translate--panel-skeleton nil
  "面板 buffer 中是否已写入流式骨架（buffer-local）.
非 nil 表示本 buffer 已由 `seshat-reader-translate--stream-init' 建好模板骨架
与正文 marker，后续增量只替换正文区；`seshat-reader-translate--render-panel'
与 `seshat-reader-translate--stream-reset' 会把它清回 nil（新一次翻译重建骨架）。")

(defvar-local seshat-reader-translate--panel-body-marker nil
  "面板 buffer 中正文起点的 marker（buffer-local），无骨架时为 nil.
`seshat-reader-translate--stream-insert-body' 用它定位「骨架 + 正文」的交界：
marker 之前的模板骨架（原文引用块、分隔线）保持不变，只重写 marker 到
`point-max' 的正文区。marker 的插入类型为默认值，故在 marker 处插入文本时
marker 停在插入文本之前，正好指向正文起点。")

(defvar-local seshat-reader-translate--panel-title nil
  "面板 buffer 当前 header-line 的标题（buffer-local），用作状态后缀的前缀.
流式完成时 `seshat-reader-translate--stream-complete' 需要「标题 + 已完成」
而非只知道后缀，故在此记下标题（`--panel-result' 拿不到 `:then' 闭包里的
TITLE 参数）。")

(defgroup seshat-reader-translate nil
  "阅读器选区的翻译与解释（基于 go-translate）."
  :group 'seshat-reader
  :prefix "seshat-reader-translate-")

(defcustom seshat-reader-translate-preset 'reader
  "翻译时使用的 gt 预设名（符号）.
取值应是 `gt-preset-translators' 中某个预设的键。命中该预设时本模块会
克隆它（见 `seshat-reader-translate--translator'）；未命中时 `message'
提示并回退到内置的 youdao/google 翻译器。"
  :type 'symbol
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-explain-preset 'reader-explain
  "解释（而非纯翻译）时使用的 gt 预设名（符号）.
语义与 `seshat-reader-translate-preset' 相同，只是供“解释选区”一类
用途使用；该预设需用户在自己的 gt 配置中提供，未提供时回退到内置的
youdao/google 翻译器。"
  :type 'symbol
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-fallback-langs '(en zh)
  "回退翻译器使用的目标语言列表.
当预设缺失、需要自建回退翻译器时，以此列表作为 gt function `gt-taker' 的
`:langs'。列表第一个元素通常是源语言，其余为目标语言，例如 (en zh)
表示英文译为中文。"
  :type '(repeat symbol)
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-render 'sidebar
  "译文的渲染方式.
`sidebar'（**默认**）表示把译文写入**底部弹出的信息面板** buffer
（`seshat-reader-sidebar-translate-buffer-name'，默认 \"*Seshat Sidebar*\"）并以
Markdown 只读视图显示：gt 只负责把纯译文渲染到隐藏中转 buffer，随后由
`:then' 回调（`seshat-reader-translate--panel-result' →
`seshat-reader-translate--render-panel'）写入面板；面板位置与初始高度由
`seshat-reader-sidebar-position' 与 `seshat-reader-sidebar-height' 决定，
显示后按内容自适应（上限 `seshat-reader-sidebar-max-height'），面板内 `q'
（`seshat-reader-sidebar-quit'，minor mode `seshat-reader-translate-panel-mode'
承载）或 `seshat-reader-sidebar-toggle' 可关闭，**不再弹 posframe**。
`pop' 表示弹出式 posframe（gt function `gt-posframe-pop-render'，失焦即消失）；
`pin' 表示常驻的固定 posframe（gt function `gt-posframe-pin-render'）。

回退行为：取 `sidebar' 但 `seshat-reader-sidebar-enabled' 为 nil 时，退回
`pop' 同款的弹出式 posframe（即禁用面板后恢复旧行为）；取值为 nil 或其它
未知值时同样按 `pop' 处理。需要恢复 posframe 时把本变量改为 `pop' 或
`pin' 即可（posframe 相关参数一并恢复生效）。"
  :type '(choice (const sidebar) (const pop) (const pin))
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-show-source t
  "是否在译文/解释面板的正文前显示选中的原文.
默认 t：显示原文引用块，便于对照原文与译文；设 nil 时关闭，面板更紧凑。
非 nil 且存在选区文本时，面板模板 `seshat-reader-translate-template' 的
`%q' 占位符位置插入原文**引用块**（见
`seshat-reader-translate--quote-block'）：首行 `> **原文**'、紧跟一个空
引用行，随后原文按行拆分、每行加 ``> `` 前缀。原文**不截断**（保持完整行，
避免长段被截半）。"
  :type 'boolean
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-template
  "%l\n\n%q\n\n---\n\n%t\n"
  "译文面板的 Markdown 模板；nil 表示不套模板、直接插入正文.
默认模板**不含标题**（`%k'）：面板的 `header-line' 已显示
\"Seshat 译文\"/\"Seshat 解释\"，正文再复述一次只是噪音。`%k' 占位符仍保留，
供自定义模板使用。
占位符：`%k' 标题（`seshat-reader-translate--render-panel' 的 TITLE）、
`%l' 语言对元信息（斜体，如 `en → zh'）、`%q' 原文引用块（仅
`seshat-reader-translate-show-source' 非 nil 且有选区时非空）、`%t' 译文
正文。模板渲染失败（未知占位符等）时回退纯正文并 `message' 警告。
模板里的字面 `%' 需写成 `%%'（`format-spec' 语义）；正文与标题值中的 `%'
不会被解析。

解释面板使用**独立**的 `seshat-reader-translate-explain-template'（其默认
值更精简：无标题、无语言对行）；本变量只影响翻译面板。"
  :type '(choice (const :tag "不使用模板" nil) string)
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-explain-template
  "%q\n\n---\n\n%t\n"
  "解释面板的 Markdown 模板；nil 表示不套模板、直接插入正文.
占位符与 `seshat-reader-translate-template' 相同（`%k' 标题、`%l' 语言对、
`%q' 原文引用块、`%t' 正文），默认不含 `%k' 与 `%l'（header-line 已显示
标题；解释场景语言对信息价值低）。与翻译模板**相互独立**：本变量为 nil
时解释面板退回纯正文，**不会**借用 `seshat-reader-translate-template'。"
  :type '(choice (const :tag "不使用模板" nil) string)
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-visual-fill-column t
  "译文/解释面板是否启用 `visual-fill-column-mode'.
非 nil 时在 `seshat-reader-translate--prepare-view' 末尾启用该 minor mode，
按 `visual-fill-column-width'（nil 时回退 `fill-column'）缩窄文本区；设为
nil 关闭——仅当面板已显示时传 -1 清理窗口 margin（面板未显示时不触碰窗口，
避免误清阅读器窗口的 margin/fringe）。`visual-fill-column' 是软依赖：未安装
时静默跳过。批注列表面板不受本变量影响。"
  :type 'boolean
  :safe #'booleanp
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-capture-window 120
  "捕获译文的时间窗口，单位为秒.
`seshat-reader-translate--capture-result' 仅在距最近一次本包翻译/解释的
启动时间（见 `seshat-reader-translate--active'）不超过本值的秒数时才捕获
译文；超出窗口视为其它 go-translate 用法触发的渲染，直接忽略，以免把非
本包的译文写进 `seshat-reader-translate-last-result'。"
  :type 'natnum
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-engines-pick 'all
  "多个引擎时如何展示结果.
`all'（**默认**）：展示**全部**成功结果，每条前标注来源引擎名，段间用
Markdown 分隔线（`---`）分隔——多引擎预设能让用户一眼比对各家译文；来源
取不到时（单引擎不写前缀行）退化为纯译文，不加标签也不加分隔线。`first'：
只展示第一个**成功**结果；`last'：只展示最后一个成功结果；二者都**不带**
来源标签（只有一个结果时标注来源没有价值）。片段带
`gt-buffer-render-error-face' 时视为失败并跳过（`first' 顺延到下一个成功
片段）。格式化细节见 `seshat-reader-translate--format-engine-results'。"
  :type '(choice (const :tag "全部结果，标注来源（默认）" all)
                 (const :tag "第一个成功结果" first)
                 (const :tag "最后一个成功结果" last))
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-stream t
  "非 nil 时对支持流式的引擎开启增量输出（面板边生成边显示）.
实现方式是为克隆后的引擎设置 `stream' 槽，并把
`gt-buffer-render-output-hook' 的增量同步到面板；引擎不支持流式或取 nil 时，退回
「完成后一次性渲染」的旧路径。"
  :type 'boolean
  :group 'seshat-reader-translate)

;;; 内部辅助

(defun seshat-reader-translate--ensure-gt ()
  "确保 go-translate（gt）已加载，未加载时报错.
用 `(require \\='gt nil t)' 按需加载软依赖 gt。加载失败（未安装 gt、
或 gt 不在 `load-path' 中）时抛出 `user-error' 并提示安装/加载 gt；
成功时返回 t。"
  (unless (require 'gt nil t)
    (user-error "Seshat Reader translate: 未加载 go-translate（gt）；请安装/加载 gt 后再使用阅读器翻译"))
  t)

(defun seshat-reader-translate--ensure-gt-buffer-render ()
  "确保 go-translate 的 buffer 渲染器库（`gt-render-buffer'）已加载.
go-translate function `gt-buffer-render' 是该库中定义的**类名**（不是库名），构造其实例前必须
先加载其库 `gt-render-buffer'。用 `(require \\='gt-render-buffer nil t)'
按需加载软依赖；加载失败（gt 安装不完整或不在 `load-path'）时抛出可操作
的 `user-error'，风格与 `seshat-reader-translate--ensure-gt' 一致。成功时
返回 t。"
  (unless (require 'gt-render-buffer nil t)
    (user-error "Seshat Reader translate: 未加载 gt-render-buffer（go-translate 的 buffer 渲染器）；请确认 gt 安装完整，或把 `seshat-reader-translate-render' 切回 `pop'/`pin' 以使用 posframe"))
  t)

(defun seshat-reader-translate--selection-text ()
  "返回最近一次鼠标选区的文本，无可用选区时报错.
从 `seshat-reader-select-last' 的 `:text' 取选区文本；变量为 nil、缺少
`:text'、或文本去掉空白后为空时抛出 `user-error'，提示先拖拽选中文本、
扫描件需 OCR。"
  (let ((text (plist-get seshat-reader-select-last :text)))
    (unless (and (stringp text) (not (string-empty-p (string-trim text))))
      (user-error "Seshat Reader translate: 请先用鼠标拖拽选中文本；扫描件需 OCR（M11.6）"))
    text))

(defvar seshat-reader-translate--gt-buffer-name " *Seshat gt*"
  "Go-translate function `gt-buffer-render' 的中转 buffer 名.
这是**隐藏 buffer**：`gt-buffer-render' 以
`(display-buffer-no-window)' 显示它故不弹窗、也不参与 popper 名单；名字两侧
各一个空格是约定（gt 隐藏 buffer 的惯例），`seshat-reader-sidebar-buffer-p'
不匹配它。gt 渲染完成后由 `:then' 回调（`--panel-result'）从这里提取纯译文，
再写入真正的展示 buffer `seshat-reader-sidebar-translate-buffer-name'。")

(defconst seshat-reader-translate--loading-text "Loading..."
  "中转 buffer 里占位文本的字面值（gt 结果位置的初值）.
`gt-buffer-render-init' 先把 `Loading...' 写进每个结果位置，`gt-extract-data'
在任务尚无结果时也把它当作结果文本。流式期间尚未产出结果的引擎在中转 buffer
里就是这段文本；捕获与增量同步都要把它当作「还没有内容」，不得当译文写进面板
或 `last-result'。")

(defun seshat-reader-translate--selection-source-text ()
  "Return the text of the last mouse selection, or nil.
用于面板正文前的原文引用块（见 `seshat-reader-translate-show-source'）；无
选区、无 `:text' 或文本全空白时返回 nil（本函数不报错，与
`seshat-reader-translate--selection-text' 的 `user-error' 语义不同）。"
  (let ((text (plist-get seshat-reader-select-last :text)))
    (and (stringp text)
         (not (string-empty-p (string-trim text)))
         text)))

(defvar seshat-reader-translate-panel-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'seshat-reader-sidebar-quit)
    (define-key map (kbd "C-c C-s") 'seshat-reader-translate-save-as-annotation)
    map)
  "面板 buffer 的键位.
`q' 关闭面板（`seshat-reader-sidebar-quit'：只关本面板所在 kind，child frame
承载时走 `delete-frame'，不会连带关掉其它 kind）；
`seshat-reader-translate-save-as-annotation' 把最近一次译文存为批注。用
minor mode 承载而非 `local-set-key'，以免污染 Markdown 视图 mode 的键位表
（同名 mode 的 map 是共享对象）。")

(define-minor-mode seshat-reader-translate-panel-mode
  "Seshat 译文/解释面板的键位与只读视图小模式." :lighter nil
  :keymap seshat-reader-translate-panel-map)

(defun seshat-reader-translate--view-mode-function ()
  "返回可用的 Markdown 只读视图 major mode 函数符号.
按降级链依次判定：`gfm-view-mode'（支持 GFM 表格与任务列表）→
`markdown-view-mode' → `text-mode'，用 `fboundp' 判断可用性。markdown-mode
是**软依赖**：未安装时前两者都不存在，回退 `text-mode' 保证渲染不报错。"
  (cond ((fboundp 'gfm-view-mode) 'gfm-view-mode)
        ((fboundp 'markdown-view-mode) 'markdown-view-mode)
        (t 'text-mode)))

(defun seshat-reader-translate--prepare-view ()
  "把当前 buffer 设为译文面板的只读 Markdown 视图.
先调 `seshat-reader-translate--view-mode-function' 选出的 major mode（隐藏
Markdown 标记、标题分级、列表缩进、代码块），再显式设 `truncate-lines' 为
nil 与 `word-wrap' 为 t——`gfm-view-mode' 实测不设 `word-wrap'，不显式设置
就只能按字符边界硬折行，CJK 折行效果差——最后设 `buffer-read-only' 为 t。

major mode 调用失败（如 autoload 指向的库缺失）时回退 `text-mode'，保证
面板渲染不因软依赖缺失而报错。

末尾按 `seshat-reader-translate-visual-fill-column' 启停
`visual-fill-column-mode'（软依赖 `visual-fill-column'，未安装时静默跳过），
让面板正文按 `visual-fill-column-width'（nil 时回退 `fill-column'）缩窄/居中。"
  (let ((mode (seshat-reader-translate--view-mode-function)))
    (condition-case nil
        (funcall mode)
      (error (text-mode))))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only t)
  (when (or (fboundp 'visual-fill-column-mode)
            (require 'visual-fill-column nil t))
    ;; 启用时立即设 margin；关闭时仅当面板已显示（窗口可能残留旧 margin）
    ;; 才传 -1 清理——面板未显示时 selected-window 是阅读器窗口，传 -1 会
    ;; 误清它的 margin/fringe。
    (if seshat-reader-translate-visual-fill-column
        (visual-fill-column-mode 1)
      (when (get-buffer-window (current-buffer))
        (visual-fill-column-mode -1)))))

(defun seshat-reader-translate--format-langs (langs)
  "把 LANGS 列表格式化为 \"源 → 目标...\" 字符串；无法格式化时返回 nil.
例如 (en zh) 返回 \"en → zh\"，(en zh ja) 返回 \"en → zh → ja\"。
LANGS 为 nil、非列表、含非符号或 nil 元素时返回 nil。"
  (when (and (listp langs) langs
             (cl-every (lambda (x) (and (symbolp x) (not (null x)))) langs))
    (mapconcat #'symbol-name langs " → ")))

(defun seshat-reader-translate--quote-block ()
  "返回原文引用块 Markdown，无原文或未开启 `show-source' 时返回 nil.
格式为 `> **原文**' 后接一个空引用行，再逐行加 `> ' 前缀；原文不截断。"
  (let ((source (seshat-reader-translate--selection-source-text)))
    (when (and seshat-reader-translate-show-source source)
      (concat "> **原文**\n>\n"
              (mapconcat (lambda (line) (concat "> " line))
                         (split-string source "\n")
                         "\n")))))

(defun seshat-reader-translate--apply-template (text title &optional langs context)
  "把 TEXT 按对应模板套上 Markdown 模板.
CONTEXT 取 `explain' 时用 `seshat-reader-translate-explain-template'，其余
（含 nil、`translate'）用 `seshat-reader-translate-template'。两个模板都为
nil 时各自退回纯正文，互不借用——这是用 CONTEXT 而非「模板参数」的原因：
模板参数为 nil 时无法区分「未提供」与「显式要求纯正文」，会导致解释模板
为 nil 时错误回退到翻译模板。

TITLE 填 `%k'，LANGS 经 `--format-langs' 转成 \"en → zh\" 后包成斜体填 `%l'
（如 `*en → zh*'；LANGS 为空时该占位符留空，不会留下空的 `**'），原文
引用块填 `%q'，TEXT 填 `%t'。所选模板为 nil 时原样返回 TEXT。渲染后压缩
占位符为空造成的连续空行（`\\n{3,}' → `\\n\\n'）并补一个尾换行。仅
`format-spec' 调用包在 `condition-case' 内：模板非法时 `message' 警告并
原样返回 TEXT。"
  (let ((template (if (eq context 'explain)
                      seshat-reader-translate-explain-template
                    seshat-reader-translate-template)))
    (if (null template)
        text
      (let* ((lang-str (seshat-reader-translate--format-langs langs))
             (quote-block (or (seshat-reader-translate--quote-block) ""))
             (lang-line (if lang-str (concat "*" lang-str "*") ""))
             rendered)
        (setq rendered
              (condition-case err
                  (format-spec template
                               (list (cons ?k title)
                                     (cons ?l lang-line)
                                     (cons ?q quote-block)
                                     (cons ?t text)))
                (error
                 (message "Seshat Reader translate: 模板渲染失败（%s），回退纯正文"
                          (error-message-string err))
                 nil)))
        (if (null rendered)
            text
          (concat (string-trim
                   (replace-regexp-in-string "\n\\{3,\\}" "\n\n" rendered))
                  "\n"))))))

(defun seshat-reader-translate--render-panel (text title &optional langs context)
  "把 TEXT 写入译文面板 buffer 并以只读 Markdown 视图显示，返回该 buffer.
TEXT 为纯译文/解释文本，先经 `seshat-reader-translate--apply-template' 按
CONTEXT 选定模板（`explain' 用 `seshat-reader-translate-explain-template'，
其余用 `seshat-reader-translate-template'）套上语言对元信息、原文引用块与
分隔线后写入；LANGS 用于模板的 `%l'，为 nil 时该行留空。CONTEXT 为 nil 时
按翻译模板处理，故既有三参调用无需改动。TITLE 写到 buffer 的
`header-line-format'（显示在窗口顶行，不占正文行）；默认模板不再把标题写进
正文。

`seshat-reader-translate-show-source' 非 nil（默认）且存在选区文本时，原文
以引用块形式出现在模板的 `%q' 位置（由
`seshat-reader-translate--quote-block' 生成，原文不截断）。

写入时用 `inhibit-read-only' 包裹（buffer 复用后仍是只读 buffer），随后
`seshat-reader-translate--prepare-view' 设视图与只读、`header-line-format' 写
标题、`seshat-reader-translate-panel-mode' 挂键位，最后经
`seshat-reader-sidebar-show' 以 `translate' 类型显示（SELECT 非 nil：内容已
就绪，可跟随光标）。

本函数是**非流式**路径：进入时先用 `seshat-reader-translate--stream-reset' 清掉
上一次的流式骨架状态（skeleton 标志与正文 marker），保证内容被整块重写后不会
再有增量按旧 marker 往新内容里插文本。"
  (let ((buffer (get-buffer-create
                 seshat-reader-sidebar-translate-buffer-name))
        (content (seshat-reader-translate--apply-template
                  text title langs context)))
    (with-current-buffer buffer
      ;; 新一次翻译：清掉上一次的流式骨架状态（skeleton 标志与正文 marker），
      ;; 否则后续增量会误以为骨架已存在、只替换正文区而丢掉新模板。
      (seshat-reader-translate--stream-reset)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content))
      (seshat-reader-translate--prepare-view)
      (setq seshat-reader-translate--panel-title title)
      (setq-local header-line-format title)
      (seshat-reader-translate-panel-mode 1)
      (goto-char (point-min)))
    (seshat-reader-sidebar-show buffer 'translate t)
    buffer))

(defun seshat-reader-translate--panel-result ()
  "从中转 buffer 提取面板译文并写入 `seshat-reader-translate-last-result'.
定位 `seshat-reader-translate--gt-buffer-name' 指定的隐藏中转 buffer，在其中
调 `seshat-reader-translate--extract-result' 取 `(TEXT . FAILED)'，再交
`seshat-reader-translate--record-result' 写入（保留 error face 的失败判定）。

写入后无论成功失败都调 `seshat-reader-translate--stream-complete' 收尾流式渲染
（把面板 header-line 从「生成中…」改成「已完成」并清骨架状态）；面板内容**不
重写**——增量期间写好的正文即最终内容，erase 重写会在完成瞬间造成整块跳变。
非流式路径（面板 buffer 无骨架）下该收尾是空操作。

返回写入的译文；中转 buffer 不存在、译文为空（翻译失败或流式尚未产出）或
渲染结果带错误 face 时返回 nil，并保留上一次的译文。"
  (let ((buffer (get-buffer seshat-reader-translate--gt-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (prog1 (seshat-reader-translate--record-result
                (seshat-reader-translate--extract-result))
          (seshat-reader-translate--stream-complete))))))

(defun seshat-reader-translate--render-object (mode &optional title langs context)
  "按 MODE 构造一个 gt 渲染对象，TITLE 为译文面板的 header-line 标题.
MODE 为 `sidebar' 且 `seshat-reader-sidebar-enabled' 非 nil 时，返回 go-translate
function `gt-buffer-render'，让 gt 渲染到**隐藏中转 buffer**：`:name' 取
`seshat-reader-translate--gt-buffer-name'，`:window-config' 为
`(display-buffer-no-window)' + `(allow-no-window . t)'（缺后者时
`display-buffer' 会回退默认动作而弹窗）。渲染完成（translator state = 3）后
gt 调用 `:then' 回调：先用 `seshat-reader-translate--panel-result' 提取并记录
纯译文，成功则交 `seshat-reader-translate--render-panel' 写入信息面板 buffer
并以 Markdown 只读视图显示。若本次请求已在流式期间渲染过骨架
（`seshat-reader-translate--panel-streamed-p' 非 nil），则**不**再调
`--render-panel'：面板内容已是最新，重写只会在完成瞬间造成整块跳变；此时仅由
`--panel-result' 把 header-line 状态从「生成中…」改成「已完成」。

`seshat-reader-sidebar-enabled' 为 nil 时退回弹出式 posframe（与 `pop' 取值
同款），以保留禁用面板时的旧行为。

MODE 为 `pin' 时返回常驻 posframe 渲染器（gt function
`gt-posframe-pin-render'）；其它取值（含 `pop' 与 nil）返回弹出式
posframe 渲染器（gt function `gt-posframe-pop-render'）。

TITLE 由 `seshat-reader-translate--translator' 按 context 传入（译作
\"Seshat 译文\"、解释作 \"Seshat 解释\"）；`&optional' 保证既有单参调用无需
改动。LANGS 由 `seshat-reader-translate--translator' 传入，供面板模板 `%l'
使用（仅 sidebar 分支使用，posframe 分支忽略）。

CONTEXT 同样由 `seshat-reader-translate--translator' 传入（`translate' 或
`explain'），经 `:then' 回调原样转交 `seshat-reader-translate--render-panel'，
由后者据其选择翻译模板或解释模板；默认 nil 时按翻译模板处理。"
  (pcase mode
    ('pin (gt-posframe-pin-render))
    ('sidebar
     (if seshat-reader-sidebar-enabled
         (progn
           (seshat-reader-translate--ensure-gt-buffer-render)
           (gt-buffer-render
            :name seshat-reader-translate--gt-buffer-name
            :window-config '((display-buffer-no-window)
                             (allow-no-window . t))
            :then (lambda (&rest _args)
                    ;; 先判定「增量期间是否已建骨架」，再调 `--panel-result'
                    ;; ——后者会清掉骨架标志，顺序反了就走不到流式分支。
                    (let ((streamed (seshat-reader-translate--panel-streamed-p))
                          (result (seshat-reader-translate--panel-result)))
                      (when (and result (not streamed))
                        (seshat-reader-translate--render-panel
                         result title langs context))))))
       (gt-posframe-pop-render)))
    (_ (gt-posframe-pop-render))))

(defun seshat-reader-translate--translator (preset text langs &optional context)
  "为 PRESET、TEXT 与 LANGS 构造一个可供 gt 使用的翻译器对象.
PRESET 是 `gt-preset-translators' 中的预设名（符号）；命中时**克隆**该
预设（`clone'），未命中时 `message' 提示并回退到内置的 youdao/google
翻译器。预设对象是 gt 的单例缓存，直接改写其槽会污染其他使用者，因此
一律只把改动施加在克隆结果上。

TEXT 为待翻译的纯文本；LANGS 为目标语言列表（如 (en zh)）。二者通过
**重建 gt function `gt-taker'** 注入，并显式设置 `:pick nil' 以避免 gt 回退到
`gt-taker-pick' 按段落切分传入的字符串。渲染方式取自
`seshat-reader-translate-render'。返回设置好 taker 与 render 的
translator 对象；调用前会先确保 gt 已加载。

CONTEXT 用于区分预设缺失时的提示文案，并决定面板模板，取 `translate'
（默认，纯翻译）或 `explain'（解释）：前者提示回退到内置翻译器并用
`seshat-reader-translate-template'，后者提示回退为普通翻译、建议在配置侧
定义解释预设，并用 `seshat-reader-translate-explain-template'。

`seshat-reader-translate-stream' 非 nil 时末尾经
`seshat-reader-translate--enable-stream' 为各引擎开启流式，并登记本次请求的
标题 / 语言对 / 语境与 translator 身份（供
`seshat-reader-translate--stream-sync' 的守卫与骨架创建使用）。"
  (seshat-reader-translate--ensure-gt)
  (let* ((preset-trans (alist-get preset (gt-ensure-plain gt-preset-translators)))
         (title (if (eq context 'explain) "Seshat 解释" "Seshat 译文"))
         (trans (if preset-trans
                    (clone preset-trans)
                  (message (if (eq context 'explain)
                               "Seshat Reader translate: 找不到解释预设 %S，回退为普通翻译（请在配置侧定义该预设以启用 LLM 解释）"
                             "Seshat Reader translate: 找不到预设 %S，回退到内置 youdao/google 翻译器")
                           preset)
                  (gt-translator :engines (list (gt-youdao-dict-engine)
                                                (gt-google-engine))))))
    (oset trans taker (gt-taker :text text :pick nil :langs langs))
    (oset trans render (seshat-reader-translate--render-object
                        seshat-reader-translate-render title langs context))
    (when seshat-reader-translate-stream
      (setq seshat-reader-translate--stream-title title
            seshat-reader-translate--stream-langs langs
            seshat-reader-translate--stream-context context)
      (seshat-reader-translate--enable-stream trans))
    trans))

(defun seshat-reader-translate--target-langs (target-lang)
  "把用户输入的目标语言字符串 TARGET-LANG 转成 gt 的 langs 列表.
源语言取 `seshat-reader-translate-fallback-langs' 的**第一个**元素，
目标语言为 `(intern TARGET-LANG)'；返回形如 (en ja) 的列表（例如
TARGET-LANG 为 \"ja\" 且回退 langs 为 (en zh) 时返回 (en ja)）。
本函数只做语言列表的构造，不校验 TARGET-LANG 是否为已知语言。

`seshat-reader-translate-fallback-langs' 为空（没有第一个元素）时无法
确定源语言，故抛 `user-error' 提示先在配置侧设置该变量，避免构造出源
语言为 nil 的非法 langs（如 (nil ja)）。"
  (let ((source-lang (car seshat-reader-translate-fallback-langs)))
    (unless source-lang
      (user-error "Seshat Reader translate: `seshat-reader-translate-fallback-langs' 未配置源语言"))
    (list source-lang (intern target-lang))))

(defun seshat-reader-translate--install-capture-hooks ()
  "把 `seshat-reader-translate--capture-result' 挂到 gt 的两个渲染输出 hook.
同时加入 `gt-posframe-pop-render-output-hook'（弹出式 posframe）与
`gt-posframe-pin-render-output-hook'（固定式 posframe），使两种渲染方式
在输出完成后都能捕获纯译文到 `seshat-reader-translate-last-result'。
使用 `add-hook'，重复调用天然幂等（不会重复挂载同一函数）。"
  (add-hook 'gt-posframe-pop-render-output-hook
            #'seshat-reader-translate--capture-result)
  (add-hook 'gt-posframe-pin-render-output-hook
            #'seshat-reader-translate--capture-result))

(defun seshat-reader-translate--engine-prefix-face-p (position)
  "POSITION 处的 `face' 属性是否为 gt 的引擎前缀 face.
用于判定「上一行是不是来源标签」。gt 的 `gt-buffer-render-init' 给每个引擎的
`:prefix' 单独加 `gt-buffer-render-block-prefix-face'（原文被切成多段时是
`gt-buffer-render-inline-prefix-face'）；而原文引用块用
`gt-buffer-render-source-face'、译文片段用结果自身的 face。三个 face 符号以
引号形式参与比较，故 gt 未加载时也不会 void-variable。

FACE 可能是符号、符号列表，或含 `(face . plist)' 形式的属性表
（如 `(:foreground \"red\")'），三者都按「是否含目标 face 符号」判定。"
  (let ((face (get-text-property position 'face))
        (wanted '(gt-buffer-render-block-prefix-face
                  gt-buffer-render-inline-prefix-face)))
    (cond
     ((null face) nil)
     ((symbolp face) (and (memq face wanted) t))
     ((consp face)
      (and (cl-some (lambda (item)
                      (memq (if (consp item) (car item) item) wanted))
                    face)
           t))
     (t nil))))

(defun seshat-reader-translate--result-source (beg)
  "返回 BEG 处译文片段的来源标签（引擎名），取不到时返回 nil.
gt 的 `gt-buffer-render-init' 在隐藏中转 buffer 里把每个引擎的 `:prefix'
渲染在译文片段**上方**：多引擎时为 `gt-tag'（如 \"youdao\" / \"google\"，
带 `gt-buffer-render-block-prefix-face'），单引擎时**没有前缀行**。原文
未被切成多段时 gt 在前缀行后再写一个**空行**才写结果（前缀行、空行、结果
三行），故本函数从 BEG 上方的行起**逐行向上跳过空白行**，取最靠下的非空行
的文本（`buffer-substring-no-properties' 后 `string-trim'）。

取到文本后还要过 `seshat-reader-translate--engine-prefix-face-p' 的 face
校验才算来源：单引擎时片段上方紧邻的非空行是**原文引用块**（带
`gt-buffer-render-source-face'），不做校验就会把原文误当来源标签。校验不过
即返回 nil。校验通过后还要经
`seshat-reader-translate--strip-stream-mark' 去掉 gt 为流式引擎追加的
\" (stream)\" 后缀（`seshat-reader-translate-stream' 开启后每个引擎的前缀行都
带它）。

契约失效的后果：gt 改渲染格式（不再给前缀加这两个 face，或把前缀并入结果
片段）时本函数返回 nil，面板退化为纯译文——不加标签也不加分隔线，既不会
报错，也不会显示错标签。"
  (save-excursion
    (goto-char beg)
    (let ((done nil)
          (found nil))
      (while (and (not done) (zerop (forward-line -1)))
        (let ((text (string-trim (buffer-substring-no-properties
                                  (line-beginning-position)
                                  (line-end-position)))))
          (unless (string-empty-p text)
            (setq done t
                  found (and (seshat-reader-translate--engine-prefix-face-p
                              (line-beginning-position))
                             ;; 引擎开启流式后 gt 会在前缀行追加
                             ;; \" (stream)\"（`gt-extract-data' 的
                             ;; 拼接逻辑），那是 gt 的内部标记而非引擎名，
                             ;; 直接显示会变成「【youdao (stream)】」。
                             (seshat-reader-translate--strip-stream-mark text))))))
      found)))

(defun seshat-reader-translate--strip-stream-mark (label)
  "去掉 gt 加在引擎前缀行末尾的流式标记，返回真正的来源标签.
gt 在引擎开启流式时把前缀写成 \"引擎名 (stream)\"；该后缀只对调试有意义，
显示层要去掉。LABEL 不以该后缀结尾时原样返回。"
  (let ((suffix " (stream)"))
    (if (string-suffix-p suffix label)
        (string-trim (substring label 0 (- (length label) (length suffix))))
      label)))

(defun seshat-reader-translate--format-engine-results (results pick)
  "按 PICK 把 RESULTS 格式化为面板正文；无可展示内容时返回 nil.
RESULTS 是 `(TEXT FAILED SOURCE)' 三元组列表，顺序即渲染缓冲区中的顺序；
FAILED 非 nil 表示该引擎失败，SOURCE 为来源引擎名或 nil（单引擎、或取不到
来源时为 nil）。

PICK 取 `all'（默认）：跳过 FAILED 条目，其余每条 SOURCE 非空时渲染为
\"【来源】\\n译文\"，SOURCE 为 nil 时原样用 TEXT；多条之间用 Markdown 分隔线
\"\\n\\n---\\n\\n\" 连接；没有任何成功条目时返回 nil。PICK 取 `first' / `last'
时只返回第一个 / 最后一个成功条目的 TEXT，**不带**来源标签。其它取值（含
nil）一律按 `all' 处理——不静默退回「只显示一个」，避免配置写错时丢失结果。

本函数是纯函数（只依赖入参 RESULTS 与 PICK，不读缓冲区），故格式化逻辑可被
ERT 直接覆盖。"
  (let ((ok (cl-remove-if #'cadr results)))
    (pcase pick
      ('first (car (car ok)))
      ('last (car (car (last ok))))
      (_ (when ok
           (string-join
            (mapcar (lambda (item)
                      (let ((text (nth 0 item))
                            (source (nth 2 item)))
                        (if (and source (not (string-empty-p source)))
                            (format "【%s】\n%s" source text)
                          text)))
                    ok)
            "\n\n---\n\n"))))))

(defun seshat-reader-translate--extract-result (&optional skip-loading)
  "从当前缓冲区提取译文片段并按 `seshat-reader-translate-engines-pick' 格式化.
返回 `(TEXT . FAILED)'：TEXT 为格式化后的正文（无可用片段时为 nil）；
FAILED 非 nil 表示**没有成功片段**——没有任何 `gt-result' 片段，或全部片段
都带 `gt-buffer-render-error-face'。供 posframe 捕获
（`seshat-reader-translate--capture-result'）与面板捕获
（`seshat-reader-translate--panel-result'）两条路径共用，签名与语义不变。

为什么在这里做来源标注：多引擎预设（默认 `reader' 预设含 youdao + google
两个引擎）会把**每份**译文各渲染成一个带 `gt-result' 属性的片段。默认展示
**全部**结果，故本函数先逐片段收集 `(TEXT FAILED SOURCE)'——SOURCE 由
`seshat-reader-translate--result-source' 从片段上方的引擎前缀行取得——再交
`seshat-reader-translate--format-engine-results' 按 pick 格式化（`all' 标注
来源并用 `---' 分段，`first'/`last' 只给纯译文）。单引擎时 gt 不写前缀行，
来源为 nil，格式化自然退化为纯译文。

单个片段的失败判定口径不变：只看**片段起点**的 `face` 属性是否含
`gt-buffer-render-error-face`（用 `get-text-property' 读一次，不做逐字符推进，
故在长缓冲区上也不会退化）。

SKIP-LOADING 非 nil 时先丢弃「文本等于 `Loading...'」的片段：gt 在结果位置
先写 `Loading...' 占位（`gt-buffer-render-init'），流式期间尚未产出结果的引擎
在缓冲区里就是这段占位文本，不过滤就会把 `Loading...' 当译文写进面板。过滤后
若没有剩余片段，返回 `(nil . t)'（调用方据此按「还没内容」处理，不写面板）。"
  (let (pieces)
    ;; 收集带 `gt-result' 属性的片段，并就地判定失败标记与来源标签。
    (save-excursion
      (goto-char (point-min))
      (while (let ((match (text-property-search-forward 'gt-result)))
               (when match
                 (let* ((begin (prop-match-beginning match))
                        (face (get-text-property begin 'face)))
                   (push (list (buffer-substring-no-properties
                                begin (prop-match-end match))
                               (or (eq face 'gt-buffer-render-error-face)
                                   (and (consp face)
                                        (memq 'gt-buffer-render-error-face
                                              face)))
                               (seshat-reader-translate--result-source begin))
                         pieces))
                 t))))
    (when skip-loading
      (setq pieces (cl-remove-if
                    (lambda (piece)
                      (equal (string-trim (nth 0 piece))
                             seshat-reader-translate--loading-text))
                    pieces)))
    (let ((formatted (seshat-reader-translate--format-engine-results
                      (nreverse pieces)
                      seshat-reader-translate-engines-pick)))
      (cons formatted (if formatted nil t)))))

(defun seshat-reader-translate--record-result (extracted)
  "把 EXTRACTED（`seshat-reader-translate--extract-result' 的返回值）写入译文.
EXTRACTED 为 `(TEXT . FAILED)'。翻译失败（FAILED 为真，或 TEXT 为 nil）时
以 `message' 明确提示，且**不写入** `seshat-reader-translate-last-result'
（即保留进入本函数前的变量值，本函数自身不清 nil）；成功时写入并返回
TEXT。posframe 路径与面板路径（`seshat-reader-translate--panel-result'）
共用本函数以保证失败语义一致。注意调用本函数的翻译/解释命令在 `gt-start'
之前已把该变量清为 nil，故端到端表现为「失败后变量为 nil」，而面板 buffer
的显示内容仍保留上一次的渲染结果（两层语义详见
`seshat-reader-translate-last-result' 的文档）。"
  (let ((text (car extracted))
        (failed (cdr extracted)))
    (cond
     (failed
      (message "Seshat Reader translate: 翻译失败（渲染结果带有错误标记），未记录译文。")
      nil)
     ((null text)
      (message "Seshat Reader translate: 翻译失败（在渲染缓冲区中未找到译文）。")
      nil)
     (t
      (setq seshat-reader-translate-last-result text)))))

(defun seshat-reader-translate--capture-result ()
  "从当前缓冲区捕获纯译文并写入 `seshat-reader-translate-last-result'.
设计为挂到 gt 的 posframe 渲染输出 hook（`gt-posframe-pop-render-output-hook'
或 `gt-posframe-pin-render-output-hook'）上；触发时 `current-buffer' 即
渲染缓冲区。取 `seshat-reader-translate--extract-result' 的提取结果交给
`seshat-reader-translate--record-result' 写入。

由于这两个 hook 是**全局**的，其它 go-translate 用法也会触发本函数，若
不加区分会把非本包的译文写进 `seshat-reader-translate-last-result'。故
本函数先检查活动标记 `seshat-reader-translate--active'：该标记由本包的
翻译/解释命令在调用 `gt-start' 前写入启动时间；仅当标记存在、且距今不
超过 `seshat-reader-translate-capture-window' 秒时才继续捕获，否则直接
返回 nil（既不写 `seshat-reader-translate-last-result'，也不 `message'）。
**残留局限**：窗口内用户若使用其它走 posframe 渲染的 gt 功能，仍可能被
误捕获；根治需子类化 gt 的 render 或改用请求级回调。走**面板（Markdown
文本 buffer）渲染**的路径不受此局限：它在 gt 渲染对象的 `:then' 回调内直接
读取本包专属的隐藏中转 buffer（`seshat-reader-translate--panel-result'），
既不依赖全局 hook，也不会误捕获。

翻译失败时（没有任何 `gt-result' 片段，或存在带
`gt-buffer-render-error-face' 属性的文本）以 `message' 明确提示，且**不
写入** `seshat-reader-translate-last-result'（保持上一次的译文）。本函数
在非 gt 缓冲区中同样可安全调用：只提示、不报错。返回写入的译文，或 nil。"
  (when (seshat-reader-translate--within-capture-window-p)
    (seshat-reader-translate--record-result
     (seshat-reader-translate--extract-result))))

;;; 流式增量渲染（`seshat-reader-translate-stream'）

(defconst seshat-reader-translate--streaming-suffix "（生成中…）"
  "流式进行中时面板 header-line 标题后的状态后缀.")

(defconst seshat-reader-translate--done-suffix "（已完成）"
  "流式结束后面板 header-line 标题后的状态后缀，用于替换前者（不改内容）.")

(defconst seshat-reader-translate--stream-scroll-interval 0.05
  "流式期间两次「滚动跟随」之间的最小间隔（秒）.
只节流滚动，不节流正文写入——见 `seshat-reader-translate--stream-scroll-due-p'。")

(defun seshat-reader-translate--within-capture-window-p ()
  "距本包最近一次翻译启动是否仍在 `seshat-reader-translate-capture-window' 秒内.
`seshat-reader-translate--active' 为 nil（本包从未发起翻译）或已超窗口时返回
nil。供 `seshat-reader-translate--capture-result'（posframe 捕获）与
`seshat-reader-translate--stream-sync'（面板增量）共用的时间窗守卫。"
  (let ((started seshat-reader-translate--active))
    (and started
         (<= (- (float-time) started)
             seshat-reader-translate-capture-window))))

(defun seshat-reader-translate--enable-stream (translator)
  "在 TRANSLATOR 的引擎上开启流式，并登记本次请求的 translator 身份.
引擎必须**再克隆一次**：eieio 的 `clone' 是浅拷贝，translator 的 `engines'
槽与预设共享同一批引擎对象，直接 `oset' `stream' 会污染用户在 gt 里的预设
（用户自己的其它 gt 用法会突然变成流式）。没有 `stream' 槽的引擎（不支持
流式）保持原样、不做包装。返回 TRANSLATOR。"
  (oset translator engines
        (mapcar (lambda (engine)
                  (if (slot-exists-p engine 'stream)
                      (let ((copy (clone engine)))
                        (oset copy stream t)
                        copy)
                    engine))
                (oref translator engines)))
  (setq seshat-reader-translate--current-translator translator)
  translator)

(defun seshat-reader-translate--stream-active-p ()
  "判断当前输出是否属于本包的流式请求（`--stream-sync' 的守卫）.
四重判定：① `seshat-reader-translate-stream' 非 nil；② 渲染方式为 `sidebar' 且
面板已启用（posframe 路径没有面板可写）；③ 中转 buffer 的 buffer-local 变量
`gt-buffer-render-translator' 与本次登记的 translator `eq' 相同——这是绕过 gt
内部约定的 HACK：gt 的 `gt-buffer-render-output-hook' 不带任何参数，只能事后
比对 buffer-local 变量；④ 仍在 `seshat-reader-translate-capture-window' 时间窗
内（避免长时间后残留的一次输出误写面板）。"
  (and seshat-reader-translate-stream
       (eq seshat-reader-translate-render 'sidebar)
       seshat-reader-sidebar-enabled
       seshat-reader-translate--current-translator
       (boundp 'gt-buffer-render-translator)
       (eq gt-buffer-render-translator
           seshat-reader-translate--current-translator)
       (seshat-reader-translate--within-capture-window-p)))

(defun seshat-reader-translate--panel-buffer ()
  "返回译文面板 buffer，不存在时返回 nil（**不创建**）."
  (get-buffer seshat-reader-sidebar-translate-buffer-name))

(defun seshat-reader-translate--panel-streamed-p ()
  "面板 buffer 是否已写入流式骨架（读 buffer-local 标志）.
`seshat-reader-translate--panel-skeleton' 是 buffer-local 的，而流式同步执行在
中转 buffer 内，故必须用 `buffer-local-value' 读面板 buffer 的那一份。"
  (let ((buffer (seshat-reader-translate--panel-buffer)))
    (and (buffer-live-p buffer)
         (buffer-local-value 'seshat-reader-translate--panel-skeleton buffer)
         t)))

(defun seshat-reader-translate--panel-display-window (buffer)
  "返回显示面板 BUFFER 的窗口（含 child frame 内的窗口），没有时 nil.
child frame 承载时窗口在另一个 frame 上，故先带 ALL-FRAMES=t 查，再退回当前
frame。"
  (and (buffer-live-p buffer)
       (or (get-buffer-window buffer t)
           (get-buffer-window buffer))))

(defun seshat-reader-translate--panel-tailing-p (window buffer)
  "判断面板窗口 WINDOW 是否停在 BUFFER 底部（距末尾 ≤ 3 行）.
WINDOW 不是活窗口、或显示的不是 BUFFER 时返回 nil（按「不跟随」处理，不动
用户的 point）。"
  (and (window-live-p window)
       (eq (window-buffer window) buffer)
       (with-current-buffer buffer
         (let ((position (window-point window)))
           (and (<= (point-min) position)
                (<= position (point-max))
                (<= (count-lines position (point-max)) 3))))))

(defun seshat-reader-translate--stream-scroll-due-p ()
  "滚动跟随是否已过节流间隔；是则记下本次时间戳并返回 t.
节流只作用于**滚动**：正文每次都写（增量是「全量快照」——每次输出都包含截至
当前的完整译文，偶尔少写一帧只会让内容晚 ≤0.05 秒，不丢内容），而每次增量都
`set-window-point' + `recenter' 才是抖动来源。"
  (let ((now (float-time)))
    (when (or (null seshat-reader-translate--last-sync-time)
              (<= seshat-reader-translate--stream-scroll-interval
                  (- now seshat-reader-translate--last-sync-time)))
      (setq seshat-reader-translate--last-sync-time now)
      t)))

(defun seshat-reader-translate--panel-scroll-to-bottom (window buffer)
  "把显示 BUFFER 的面板窗口 WINDOW 的 point 移到正文末尾并保证末行可见."
  (when (and (window-live-p window) (eq (window-buffer window) buffer))
    (with-current-buffer buffer
      (set-window-point window (point-max))
      ;; frame 刚布局（窗口高度为 0）等情形下 recenter 可能报错，滚动只是观感，
      ;; 失败不影响内容，故静默。
      (ignore-errors
        (with-selected-window window
          (recenter -1))))))

(defun seshat-reader-translate--stream-reset ()
  "清除流式骨架状态（buffer-local 的 skeleton 标志与正文 marker）."
  (setq seshat-reader-translate--panel-skeleton nil)
  (when (markerp seshat-reader-translate--panel-body-marker)
    (set-marker seshat-reader-translate--panel-body-marker nil))
  (setq seshat-reader-translate--panel-body-marker nil)
  (setq seshat-reader-translate--last-sync-time nil))

(defun seshat-reader-translate--stream-insert-body (text)
  "在当前（面板）buffer 用 TEXT 替换 marker 之后的正文区.
marker 之前的模板骨架（原文引用块、分隔线）保持不变：不重建 buffer、不重设
major mode，markdown 视图只对真正变化的正文重算 font-lock。"
  (let ((inhibit-read-only t)
        (marker seshat-reader-translate--panel-body-marker))
    (when (and (markerp marker) (marker-position marker))
      (save-excursion
        (goto-char marker)
        (delete-region (point) (point-max))
        (insert text)
        (unless (string-suffix-p "\n" text)
          (insert "\n"))))))

(defun seshat-reader-translate--stream-init (text)
  "首次增量：在当前（面板）buffer 写入模板骨架与正文 TEXT，并显示面板.
骨架由 `seshat-reader-translate--apply-template' 以空正文（`%t' 为 \"\"）生成，
故模板里的原文引用块、分隔线与语言对行只写一次；正文起点用 marker 记录，后续
增量只重写 marker 之后的部分。显示时 SELECT 传 nil：流式期间不抢焦点。"
  (let ((title (or seshat-reader-translate--stream-title "Seshat 译文"))
        (inhibit-read-only t))
    (erase-buffer)
    (insert (seshat-reader-translate--apply-template
             "" title
             seshat-reader-translate--stream-langs
             seshat-reader-translate--stream-context))
    ;; 顺序要紧：切视图 major mode 会 `kill-all-local-variables'，把下面要设的
    ;; buffer-local 状态（skeleton 标志、正文 marker、面板标题）一并清掉。
    (seshat-reader-translate--prepare-view)
    (setq seshat-reader-translate--panel-skeleton t)
    (setq seshat-reader-translate--panel-title title)
    (setq seshat-reader-translate--panel-body-marker (copy-marker (point-max)))
    (seshat-reader-translate--stream-insert-body text)
    (setq-local header-line-format
                (concat title seshat-reader-translate--streaming-suffix))
    (seshat-reader-translate-panel-mode 1)
    (seshat-reader-sidebar-show (current-buffer) 'translate nil)))

(defun seshat-reader-translate--stream-render (text)
  "把增量 TEXT 写入面板：首次写骨架，之后只替换正文区，并按需跟随底部.
「是否跟随」由**写入前**的窗口位置判定：用户已把 point 移离底部（距末尾 > 3
行）就不再动它，回到底部后自动恢复。判定必须在写入前做——写正文会先删除再插入
正文区，窗口 point 若正落在被删区间会被 relocation 到 marker 处，写后再判定会
把「一直停在底部」误判成「用户滚走了」。"
  (let* ((buffer (get-buffer-create seshat-reader-sidebar-translate-buffer-name))
         (window (seshat-reader-translate--panel-display-window buffer))
         (tailing (and window
                       (seshat-reader-translate--panel-tailing-p window buffer))))
    (with-current-buffer buffer
      (if (and seshat-reader-translate--panel-skeleton
               (markerp seshat-reader-translate--panel-body-marker)
               (marker-position seshat-reader-translate--panel-body-marker))
          (seshat-reader-translate--stream-insert-body text)
        (seshat-reader-translate--stream-init text)))
    (when (and seshat-reader-panel-follow-bottom
               tailing
               window
               (seshat-reader-translate--stream-scroll-due-p))
      (seshat-reader-translate--panel-scroll-to-bottom window buffer))))

(defun seshat-reader-translate--stream-sync ()
  "把中转 buffer 的增量同步到译文面板（`gt-buffer-render-output-hook' 挂载点）.
gt 每次流式输出后都在**隐藏中转 buffer 内**运行该 hook，故本函数执行时
`current-buffer' 就是中转 buffer（`--extract-result' 直接读它）。守卫见
`seshat-reader-translate--stream-active-p'；`Loading...' 占位片段由
`--extract-result' 的 SKIP-LOADING 过滤，全部片段都还是 Loading 时本函数直接
返回、完全不碰面板（面板也不创建）。

整体套 `ignore-errors'：hook 抛错会被 gt 的 `gt-output :around' 捕获并把
translator state 置 4（整次翻译中止）；流式是增强功能，绝不能因为它让翻译失败。"
  (ignore-errors
    (when (seshat-reader-translate--stream-active-p)
      (let ((text (car (seshat-reader-translate--extract-result t))))
        (when (and text (not (string-empty-p text)))
          (seshat-reader-translate--stream-render text))))))

(defun seshat-reader-translate--stream-complete ()
  "流式渲染收尾：header-line 状态改成「已完成」并清骨架状态，**不重写内容**.
仅在面板 buffer 已由骨架渲染过时生效（非流式路径为无操作）。不 erase 重写是
刻意的：增量期间写好的正文就是最终内容，重写会在完成瞬间造成整块跳变。"
  (let ((buffer (seshat-reader-translate--panel-buffer)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'seshat-reader-translate--panel-skeleton buffer))
      (with-current-buffer buffer
        (setq-local header-line-format
                    (concat (or seshat-reader-translate--panel-title "Seshat 译文")
                            seshat-reader-translate--done-suffix))
        (seshat-reader-translate--stream-reset)))))

(defun seshat-reader-translate--install-stream-hook ()
  "把 `seshat-reader-translate--stream-sync' 挂到 `gt-buffer-render-output-hook'.
经 `add-hook' 安装，重复调用幂等。hook 常驻不卸载：函数体自带守卫（关闭流式、
切换渲染方式、或输出属于别的 translator 时直接返回），卸载反而要在每次渲染方式
切换时重新协调。"
  (add-hook 'gt-buffer-render-output-hook
            #'seshat-reader-translate--stream-sync))

(defun seshat-reader-translate--install-capture-hook-for-mode ()
  "按 `seshat-reader-translate-render' 决定安装哪些输出 hook.
取 `sidebar' 且 `seshat-reader-sidebar-enabled' 非 nil 时：译文捕获在 gt 渲染
对象的 `:then' 回调内完成（见 `seshat-reader-translate--panel-result'），它只
操作本包专属的隐藏中转 buffer，零误捕获，故**不挂** posframe 的输出 hook；但
`seshat-reader-translate-stream' 非 nil 时挂
`gt-buffer-render-output-hook'（`seshat-reader-translate--stream-sync'）以实现
增量显示——该 hook **是**全局的，故函数体内用
`seshat-reader-translate--stream-active-p'（translator 身份 + 时间窗）双重守卫，
不会误捕获其它 gt 用法。

其余情形（`pop'/`pin'，或取 `sidebar' 但 `seshat-reader-sidebar-enabled' 为
nil 而回退 posframe）挂两个 posframe 输出 hook
（`seshat-reader-translate--install-capture-hooks'），与
`seshat-reader-translate--render-object' 的选取保持一致。安装经 `add-hook'，
重复调用幂等。"
  (if (and (eq seshat-reader-translate-render 'sidebar)
           seshat-reader-sidebar-enabled)
      (when seshat-reader-translate-stream
        (seshat-reader-translate--install-stream-hook))
    (seshat-reader-translate--install-capture-hooks)))

;;; 交互式命令

(defun seshat-reader-translate-selection (&optional target-lang)
  "翻译最近一次鼠标选区，译文经信息面板展示（默认）或 posframe 弹出.
TARGET-LANG 为非空字符串时用作目标语言：源语言取
`seshat-reader-translate-fallback-langs' 的第一个元素，目标语言为
`(intern TARGET-LANG)'（见 `seshat-reader-translate--target-langs'）；
TARGET-LANG 为 nil 时直接使用 `seshat-reader-translate-fallback-langs'
整体作为 langs。交互调用时可用 `C-u' 前缀参数在迷你缓冲区输入目标语言
（如 \"ja\"）。

使用预设 `seshat-reader-translate-preset'；预设缺失时回退到内置的
youdao/google 翻译器。呈现方式见 `seshat-reader-translate-render'：默认
`sidebar' 让 gt 渲染到隐藏中转 buffer，再由 `:then' 回调把纯译文写进
**底部信息面板**的 Markdown 只读 buffer（不再弹 posframe），面板可用 `q'
（`seshat-reader-sidebar-quit'）或 `seshat-reader-sidebar-toggle' 关闭；取
`pop'/`pin' 时恢复 posframe。译文在
面板路径由 `seshat-reader-translate--panel-result' 在 `:then' 回调内写入
`seshat-reader-translate-last-result'，posframe 路径由
`seshat-reader-translate--capture-result' 写入，都可用
`seshat-reader-translate-save-as-annotation' 把译文存为批注。

无可用选区（`seshat-reader-select-last' 为空或文本为空）时以
`user-error' 提示先选中文本。取选区与构造 langs 阶段的 `user-error'
直接冒泡（Emacs 显示提示且不打印 backtrace）；构建翻译器与启动翻译阶段
（`seshat-reader-translate--translator' / `gt-start'）的一般错误被
`condition-case' 捕获并以 `message' 明确提示，`user-error' 仍原样冒泡。

本命令在启动翻译前会把 `seshat-reader-translate-last-result' 清为 nil，
并记录启动时间到 `seshat-reader-translate--active'，以启用
`seshat-reader-translate--capture-result' 的捕获窗口守卫（避免旧译文被
误存，也避免其它 go-translate 用法污染结果）。"
  (interactive (list (when current-prefix-arg (read-string "目标语言: "))))
  (let* ((text (seshat-reader-translate--selection-text))
         (langs (if (and (stringp target-lang)
                         (not (string-empty-p (string-trim target-lang))))
                    (seshat-reader-translate--target-langs target-lang)
                  seshat-reader-translate-fallback-langs)))
    (condition-case err
        (let ((trans (seshat-reader-translate--translator
                      seshat-reader-translate-preset text langs 'translate)))
          (seshat-reader-translate--install-capture-hook-for-mode)
          (setq seshat-reader-translate-last-result nil)
          (setq seshat-reader-translate--active (float-time))
          (gt-start trans))
      (user-error
       (signal (car err) (cdr err)))
      (error
       (message "Seshat Reader translate: 翻译失败：%s"
                (error-message-string err))))))

(defun seshat-reader-translate-explain-selection (&optional target-lang)
  "解释（而非纯翻译）最近一次鼠标选区，译文经信息面板展示（默认）或 posframe 弹出.
TARGET-LANG 的语义与 `seshat-reader-translate-selection' 完全相同：非空
字符串时用作目标语言（源语言取 `seshat-reader-translate-fallback-langs'
的第一个元素，目标语言为 `(intern TARGET-LANG)'），nil 时使用
`seshat-reader-translate-fallback-langs' 整体。区别只在于使用预设
`seshat-reader-translate-explain-preset'（该预设需用户在自己的 gt 配置
中提供，未提供时回退到内置的 youdao/google 翻译器）。交互调用时可用
`C-u' 前缀参数在迷你缓冲区输入目标语言。

呈现方式见 `seshat-reader-translate-render'：默认 `sidebar' 让 gt 渲染到隐藏
中转 buffer，再由 `:then' 回调把纯文本写进**底部信息面板**的 Markdown 只读
buffer（不再弹 posframe），面板可用 `q'
（`seshat-reader-sidebar-quit'）或 `seshat-reader-sidebar-toggle' 关闭；取
`pop'/`pin' 时恢复 posframe。译文写入方式同
`seshat-reader-translate-selection'（面板路径在 `:then' 回调内写入），可用
`seshat-reader-translate-save-as-annotation' 把结果存为批注。错误处理与
`seshat-reader-translate-selection' 一致：`user-error' 冒泡，其余一般
错误捕获后 `message'。本命令同样会在启动前清空
`seshat-reader-translate-last-result' 并记录启动时间到
`seshat-reader-translate--active'（预设缺失时按 `explain' 语境提示回退
为普通翻译）。"
  (interactive (list (when current-prefix-arg (read-string "目标语言: "))))
  (let* ((text (seshat-reader-translate--selection-text))
         (langs (if (and (stringp target-lang)
                         (not (string-empty-p (string-trim target-lang))))
                    (seshat-reader-translate--target-langs target-lang)
                  seshat-reader-translate-fallback-langs)))
    (condition-case err
        (let ((trans (seshat-reader-translate--translator
                      seshat-reader-translate-explain-preset text langs 'explain)))
          (seshat-reader-translate--install-capture-hook-for-mode)
          (setq seshat-reader-translate-last-result nil)
          (setq seshat-reader-translate--active (float-time))
          (gt-start trans))
      (user-error
       (signal (car err) (cdr err)))
      (error
       (message "Seshat Reader translate: 解释失败：%s"
                (error-message-string err))))))

(defun seshat-reader-translate-save-as-annotation ()
  "把最近一次译文存为服务端批注（**侧车**，不写回文档）.
批注存储在服务端（经 `seshat-rest-create-annotation'），**不会**写回用户
正在阅读的原文档，因此不会改动文件内容。位置（引用锚，页锚 + 几何尾段）由
`seshat-reader-annotation--anchor' 从最近一次选区
（`seshat-reader-select-last' 的 :page/:rect）派生；服务端身份由
`seshat-reader-annotation--uid' 从选区的 :file 解析（uid 是发给服务端的
唯一身份；显示用 doc-id 仍由 `seshat-reader-annotation--doc-id' 派生，
只用于提示文案；该派生按**源文件所属 buffer** 的静音标记决定是否 `message'
降级警告（`seshat-reader-annotation--quiet-p'，软依赖），因此本命令即使从
翻译面板 buffer 触发，也不会在 `seshat-reading-mode' 下刷库外警告）。

正文取 `seshat-reader-translate-last-result'（最近一次翻译或解释的纯
译文）；尚无译文、或译文去掉空白后为空时以 `user-error' 提示先翻译或
解释选区。无选区、选区未记录文档文件、或文档未在服务端登记时同样以
`user-error' 提示。

创建成功（服务端返回含 `id' 的 alist）时 `message' 报告批注 id；服务端
不可用、返回非 2xx 或响应无法解析时 `message' 明确警告，绝不静默。异常
由 `condition-case' 捕获并 `message'。本命令用 `M-x' 调用，不绑定键位。"
  (interactive)
  (let ((text seshat-reader-translate-last-result))
    (when (or (null text) (string-empty-p (string-trim text)))
      (user-error "Seshat Reader translate: 尚无译文；请先翻译或解释选区"))
    (let ((selection seshat-reader-select-last))
      (unless selection
        (user-error "Seshat Reader translate: 尚无选区，请先用鼠标拖拽选中文本"))
      (let ((file (plist-get selection :file)))
        (unless file
          (user-error "Seshat Reader translate: 选区未记录文档文件，无法派生文档标识"))
        (let* ((page (plist-get selection :page))
               (rect (plist-get selection :rect))
               (document-id (seshat-reader-annotation--doc-id
                             file (seshat-reader-annotation--quiet-p file)))
               (uid (seshat-reader-annotation--uid file))
               (location (seshat-reader-annotation--anchor page rect)))
          (condition-case err
              (let ((response (seshat-rest-create-annotation
                               uid location text)))
                (if (and (listp response) (alist-get 'id response))
                    (message "Seshat Reader translate: 已把译文存为批注 %s（%s，%s）"
                             (format "%s" (alist-get 'id response))
                             document-id location)
                  (message "Seshat Reader translate: 存批注失败（服务端返回非 2xx 或响应无法解析）")))
            (error
             (message "Seshat Reader translate: 存批注失败：%s"
                      (error-message-string err)))))))))

;;; 键位

(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-c C-t")
    #'seshat-reader-translate-selection)
  (define-key seshat-reader-mode-map (kbd "C-c C-e")
    #'seshat-reader-translate-explain-selection))

(provide 'seshat-reader-translate)
;;; seshat-reader-translate.el ends here
