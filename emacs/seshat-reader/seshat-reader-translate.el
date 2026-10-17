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
;;   面板内 `q'（由 minor mode `seshat-reader-translate-panel-mode' 承载）或
;;   `seshat-reader-sidebar-toggle' 可关闭。
;; - `pop'/`pin'：回退 posframe（`gt-posframe-pop-render' 弹出、失焦即消失 /
;;   `gt-posframe-pin-render' 常驻），可在配置侧切回。
;;
;; 捕获译文：面板路径在 `:then' 回调内完成（`--panel-result'），不依赖任何
;; 全局 hook，故零误捕获；posframe 路径复用
;; `gt-posframe-pop-render-output-hook'（弹出）与
;; `gt-posframe-pin-render-output-hook'（固定），并在
;; `--capture-result' 中用启动时间戳的时间窗口守卫过滤其它 gt 用法。
;;
;; 文档标识（`document_id'）与位置（`location'）的约定见
;; `seshat-reader-annotation'。
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
  (put 'render 'slot-name t))

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
值为渲染缓冲区中所有带 `gt-result' 文本属性的片段以换行拼接的结果。
翻译失败语义分两个层面（有意为之）：**显示层**不清空——失败路径不会调用
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
（minor mode `seshat-reader-translate-panel-mode'）或
`seshat-reader-sidebar-toggle' 可关闭，**不再弹 posframe**。
`pop' 表示弹出式 posframe（gt function `gt-posframe-pop-render'，失焦即消失）；
`pin' 表示常驻的固定 posframe（gt function `gt-posframe-pin-render'）。

回退行为：取 `sidebar' 但 `seshat-reader-sidebar-enabled' 为 nil 时，退回
`pop' 同款的弹出式 posframe（即禁用面板后恢复旧行为）；取值为 nil 或其它
未知值时同样按 `pop' 处理。需要恢复 posframe 时把本变量改为 `pop' 或
`pin' 即可（posframe 相关参数一并恢复生效）。"
  :type '(choice (const sidebar) (const pop) (const pin))
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-show-source nil
  "是否在译文/解释面板的正文前显示选中的原文.
非 nil 且存在选区文本时，面板正文前插入原文**引用块**：原文按行拆分、每行
加 ``> `` 前缀，引用块与正文之间空一行。原文**不截断**（保持完整行，避免长段
被截半）。默认 nil 表示只显示译文/解释正文，面板更紧凑。"
  :type 'boolean
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-capture-window 120
  "捕获译文的时间窗口，单位为秒.
`seshat-reader-translate--capture-result' 仅在距最近一次本包翻译/解释的
启动时间（见 `seshat-reader-translate--active'）不超过本值的秒数时才捕获
译文；超出窗口视为其它 go-translate 用法触发的渲染，直接忽略，以免把非
本包的译文写进 `seshat-reader-translate-last-result'。"
  :type 'natnum
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
    (define-key map (kbd "q") #'seshat-reader-sidebar-toggle)
    (define-key map (kbd "C-c C-s") 'seshat-reader-translate-save-as-annotation)
    map)
  "面板 buffer 的键位.
`q' 关闭面板（`seshat-reader-sidebar-toggle'）；
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
面板渲染不因软依赖缺失而报错。"
  (let ((mode (seshat-reader-translate--view-mode-function)))
    (condition-case nil
        (funcall mode)
      (error (text-mode))))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only t))

(defun seshat-reader-translate--render-panel (text title)
  "把 TEXT 写入译文面板 buffer 并以只读 Markdown 视图显示，返回该 buffer.
TEXT 为纯译文/解释文本；TITLE 写到 buffer 的 `header-line-format'（显示在
窗口顶行，不占正文行）。

`seshat-reader-translate-show-source' 非 nil 且存在选区文本时，先在正文前插入
原文引用块：按行拆分、每行加 ``> `` 前缀，引用块与正文之间空一行，原文不
截断。

写入时用 `inhibit-read-only' 包裹（buffer 复用后仍是只读 buffer），随后
`seshat-reader-translate--prepare-view' 设视图与只读、`header-line-format' 写
标题、`seshat-reader-translate-panel-mode' 挂键位，最后经
`seshat-reader-sidebar-show' 以 `translate' 类型显示（SELECT 非 nil：内容已
就绪，可跟随光标）。"
  (let ((buffer (get-buffer-create
                 seshat-reader-sidebar-translate-buffer-name))
        (source (seshat-reader-translate--selection-source-text)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when (and seshat-reader-translate-show-source source)
          (insert (mapconcat (lambda (line) (concat "> " line))
                             (split-string source "\n")
                             "\n"))
          (insert "\n\n"))
        (insert text))
      (seshat-reader-translate--prepare-view)
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

返回写入的译文；中转 buffer 不存在、译文为空（翻译失败或流式尚未产出）或
渲染结果带错误 face 时返回 nil，并保留上一次的译文。"
  (let ((buffer (get-buffer seshat-reader-translate--gt-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (seshat-reader-translate--record-result
         (seshat-reader-translate--extract-result))))))

(defun seshat-reader-translate--render-object (mode &optional title)
  "按 MODE 构造一个 gt 渲染对象，TITLE 为译文面板的 header-line 标题.
MODE 为 `sidebar' 且 `seshat-reader-sidebar-enabled' 非 nil 时，返回 go-translate
function `gt-buffer-render'，让 gt 渲染到**隐藏中转 buffer**：`:name' 取
`seshat-reader-translate--gt-buffer-name'，`:window-config' 为
`(display-buffer-no-window)' + `(allow-no-window . t)'（缺后者时
`display-buffer' 会回退默认动作而弹窗）。渲染完成（translator state = 3）后
gt 调用 `:then' 回调：先用 `seshat-reader-translate--panel-result' 提取并记录
纯译文，成功则交 `seshat-reader-translate--render-panel' 写入信息面板 buffer
并以 Markdown 只读视图显示。

`seshat-reader-sidebar-enabled' 为 nil 时退回弹出式 posframe（与 `pop' 取值
同款），以保留禁用面板时的旧行为。

MODE 为 `pin' 时返回常驻 posframe 渲染器（gt function
`gt-posframe-pin-render'）；其它取值（含 `pop' 与 nil）返回弹出式
posframe 渲染器（gt function `gt-posframe-pop-render'）。

TITLE 由 `seshat-reader-translate--translator' 按 context 传入（译作
\"Seshat 译文\"、解释作 \"Seshat 解释\"）；`&optional' 保证既有单参调用无需
改动。"
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
                    (let ((result (seshat-reader-translate--panel-result)))
                      (when result
                        (seshat-reader-translate--render-panel result title))))))
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

CONTEXT 用于区分预设缺失时的提示文案，取 `translate'（默认，纯翻译）
或 `explain'（解释）：前者提示回退到内置翻译器，后者提示回退为普通翻译
并建议在配置侧定义解释预设。"
  (seshat-reader-translate--ensure-gt)
  (let* ((preset-trans (alist-get preset (gt-ensure-plain gt-preset-translators)))
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
                        seshat-reader-translate-render
                        (if (eq context 'explain)
                            "Seshat 解释"
                          "Seshat 译文")))
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

(defun seshat-reader-translate--extract-result ()
  "从当前缓冲区提取译文片段与失败标记.
返回 `(TEXT . FAILED)'：TEXT 为所有带 `gt-result' 文本属性的片段以
`string-join' 用换行拼接的字符串（无片段时为 nil）；FAILED 非 nil 表示
渲染结果带 `gt-buffer-render-error-face'（翻译失败标记）。供 posframe 捕获
（`seshat-reader-translate--capture-result'）与面板捕获
（`seshat-reader-translate--panel-result'）两条路径共用，避免逻辑重复。"
  (let ((pieces nil)
        (failed nil))
    ;; 收集带 `gt-result' 属性的片段。
    (save-excursion
      (goto-char (point-min))
      (while (let ((match (text-property-search-forward 'gt-result)))
               (when match
                 (push (buffer-substring-no-properties
                        (prop-match-beginning match)
                        (prop-match-end match))
                       pieces)
                 t))))
    ;; 失败检测：只在带 `face' 属性的连续片段上遍历
    ;; （`text-property-search-forward' 一次跳到下一个带 face 的区域），
    ;; 避免逐字符推进在无 face 的长缓冲上退化为 O(n^2)。
    (save-excursion
      (goto-char (point-min))
      (while (and (not failed)
                  (let ((match (text-property-search-forward 'face)))
                    (when match
                      (let ((face (get-text-property
                                   (prop-match-beginning match) 'face)))
                        (when (or (eq face 'gt-buffer-render-error-face)
                                  (and (consp face)
                                       (memq 'gt-buffer-render-error-face face)))
                          (setq failed t)))
                      t)))))
    (cons (when pieces (string-join (nreverse pieces) "\n")) failed)))

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
  (when (let ((started seshat-reader-translate--active))
          (and started
               (<= (- (float-time) started)
                   seshat-reader-translate-capture-window)))
    (seshat-reader-translate--record-result
     (seshat-reader-translate--extract-result))))

(defun seshat-reader-translate--install-capture-hook-for-mode ()
  "按 `seshat-reader-translate-render' 决定是否安装译文捕获 hook.
取 `sidebar' 且 `seshat-reader-sidebar-enabled' 非 nil 时**不安装任何 hook**：
面板路径的译文捕获在 gt 渲染对象的 `:then' 回调内完成（见
`seshat-reader-translate--panel-result'），它只操作本包专属的隐藏中转 buffer，
零误捕获，也不需要全局 hook 与其时间窗口守卫。

其余情形（`pop'/`pin'，或取 `sidebar' 但 `seshat-reader-sidebar-enabled' 为
nil 而回退 posframe）挂两个 posframe 输出 hook
（`seshat-reader-translate--install-capture-hooks'），与
`seshat-reader-translate--render-object' 的选取保持一致。安装经 `add-hook'，
重复调用幂等。"
  (unless (and (eq seshat-reader-translate-render 'sidebar)
               seshat-reader-sidebar-enabled)
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
**底部信息面板**的 Markdown 只读 buffer（不再弹 posframe），面板可用 `q' 或
`seshat-reader-sidebar-toggle' 关闭；取 `pop'/`pin' 时恢复 posframe。译文在
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
buffer（不再弹 posframe），面板可用 `q' 或 `seshat-reader-sidebar-toggle'
关闭；取 `pop'/`pin' 时恢复 posframe。译文写入方式同
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
正在阅读的原文档，因此不会改动文件内容。文档标识与位置分别由
`seshat-reader-annotation--doc-id' 与
`seshat-reader-annotation--location' 从最近一次选区
（`seshat-reader-select-last' 的 :file/:page/:rect）派生。

正文取 `seshat-reader-translate-last-result'（最近一次翻译或解释的纯
译文）；尚无译文、或译文去掉空白后为空时以 `user-error' 提示先翻译或
解释选区。无选区、或选区未记录文档文件时同样以 `user-error' 提示。

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
               (document-id (seshat-reader-annotation--doc-id file))
               (location (seshat-reader-annotation--location page rect)))
          (condition-case err
              (let ((response (seshat-rest-create-annotation
                               document-id location text)))
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
