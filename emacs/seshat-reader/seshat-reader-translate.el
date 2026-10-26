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
;; 预设来源与解释的 prompt 装配（2026-10-25）：
;;
;; - 预设查表先查 `seshat-reader-translate-presets'（seshat 自有表），再回落
;;   gt 全局的 `gt-preset-translators'。自有表优先，故 `reader' /
;;   `reader-explain' 不必进 gt 全局表——否则它们会出现在 `gt-translate' 的
;;   预设选择列表里，污染用户其它 gt 用法。
;; - 解释的 prompt 与上下文**全部装配进 taker 的 `:text'**，引擎槽零改动
;;   （`gt-single' 的 class 级实例缓存使「克隆引擎再改槽」可能根本没克隆，
;;   会污染全局引擎实例）；配置侧把预设引擎的 `prompt' 槽设为纯透传
;;   `"{{text}}"' 即可。
;; - 相关开关：`-presets' / `-explain-prompt' / `-explain-max-chars' /
;;   `-context-enabled' / `-context-lines' / `-context-max-chars' /
;;   `-strip-chatter'（变量前缀均为 `seshat-reader-translate-'）。
;;
;; 多引擎来源标注（`seshat-reader-translate-engines-pick'，默认 `all'）：多引擎
;; 预设本就是为了一眼比对各家译文，故默认展示**全部成功结果**，每条前标
;; `【引擎名】'、段间用 Markdown 分隔线 `---'（`--format-engine-results'）；
;; `first' / `last' 只留第一个 / 最后一个**成功**结果且不带标签。带
;; `gt-buffer-render-error-face' 的片段视为失败并跳过（`first' 顺延到下一个
;; 成功片段），来源取不到时退化为纯译文。
;;
;; 流式增量（`seshat-reader-translate-stream'，默认开启）：构造翻译器时把
;; **克隆后的**引擎的 `stream' 槽设为 t（引擎对象也要再克隆——eieio 的
;; `clone' 是浅拷贝，translator 的 `engines' 槽与预设共享同一批引擎对象）；
;; **只对 `delimit' 为 nil 的引擎开**（gt 在 `stream' 为 t 时跳过 `delimit'
;; 的 join，youdao/google 这类依赖字符串的引擎会收到分段列表并报
;; `Wrong type argument: stringp'），其余引擎保持原对象、一次性返回。
;; 并把 `gt-buffer-render-output-hook' 的增量同步到面板：首个增量写入模板
;; 骨架（正文 `%t' 为空）并记录正文起点 marker，后续只替换 marker 之后的
;; 正文区；完成时只更新 header-line 状态、不 erase 重写（避免完成瞬间整块
;; 跳变）。**hook 守卫**：`gt-buffer-render-output-hook' 不带参数，只能事后
;; 比对中转 buffer 的 buffer-local `gt-buffer-render-translator' 与本次登记的
;; translator（`--current-translator'）是否 `eq`——这是绕过 gt 内部约定的
;; HACK；gt 若改名或改时机，守卫退化为永不匹配，面板静默退回完成时整体渲染
;; （不出错、只是没有中间过程）。`stream' 为 nil 或引擎无该槽时同样退回旧路径。
;;
;; 多轮追问（`seshat-reader-translate-follow-up'，面板键位 `C-c C-q'）：解释
;; 或译文面板里可以针对**同一段原文**继续提问，历史轮次以 OpenAI messages
;; 形式随请求发送，答案追加到面板。轮次正文不带标签：问题写成 Markdown 引用
;; 块（每行加 `> '，与首轮原文引用块同风格），空行之后直出答案正文，轮次之间
;; 用 `---' 分隔线（首轮答案与第 1 轮追问之间也有）；轮次序号只留在
;; header-line。追问**恒不开引擎流式**——gt 的纯流式链路既不调 `gt-update'
;; 也不调渲染器的 output 函数，渲染对象的 `:then' 永不触发，而追问写面板的
;; 唯一通路就是 `:then'（详见 `--follow-up-translator' 的注释）。实现方式
;; 是克隆预设里的 `gt-chatgpt-engine'，把它的 `prompt' 槽换成「返回 messages
;; 列表的函数」——gt 的 `gt-execute' 对函数型 `prompt' 走
;; `(pdd-funcall prompt (list item tgt))'，`gt-chatgpt-send' 在 prompt 为列表
;; 时按 `messages' 数组发送，因此**不改 gt 源码、不自行拼 JSON**。预设里没有
;; `gt-chatgpt-engine'（例如只配了 youdao/google 这类纯翻译引擎）时报
;; `user-error' 提示改配置，**不做文本拼接降级**——翻译引擎没有对话语义，
;; 降级只会产出误导性答案。追问的中转 buffer 与首轮分开
;; （` *Seshat gt follow-up*'），完成时只替换「当前轮答案区」的 marker 区间，
;; 不触碰首轮骨架与此前各轮问答。轮次上限由
;; `seshat-reader-translate-follow-up-max-rounds'（默认 6）控制——超出后丢弃
;; 最早的轮次，但首轮原文与首轮解释恒保留（否则追问失去讨论对象），取 0 表示
;; 每次只看原文与首轮解释。
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
  (put 'stream 'slot-name t)
  ;; 流式的开流判据读引擎的 `delimit' 槽（gt 在 `stream' 为 t 时跳过 join，
  ;; 故 `delimit' 非 nil 的引擎不能开流式），同样登记槽名消除告警。
  (put 'delimit 'slot-name t)
  ;; 追问（T5）要改写 `gt-chatgpt-engine' 的 `prompt' 槽（换成返回 messages
  ;; 列表的函数），同样登记槽名消除告警。
  (put 'prompt 'slot-name t)
  ;; 可观测（T4）要读 `gt-chatgpt-engine' 的 `model' / `host' 槽（解释失败的
  ;; 引擎标识，见 `seshat-reader-translate--engine-label'），同样登记槽名。
  ;; **只登记这两个非敏感槽**：key 类槽（key / auth / token）永不读取。
  (put 'model 'slot-name t)
  (put 'host 'slot-name t))

(declare-function eieio-oset "eieio-core" (obj slot value))
(declare-function eieio-oref "eieio-core" (obj slot))
(declare-function eieio-object-p "eieio" (obj))
(declare-function object-of-class-p "eieio" (obj class))
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
;; `visual-fill-column-adjust' 是 vfcm 的**公开**命令（改宽度后立即重算 margin，
;; 避免依赖其私有 `--set-margins'）；同样按软依赖处理，运行期再用 `fboundp' 守卫。
(declare-function visual-fill-column-adjust "visual-fill-column" (&optional inc))
;; valign-mode 同样是软依赖（只在 `--prepare-view' 内按需 `require'）。
(declare-function valign-mode "valign" (&optional arg))
;; 译文面板开启时关闭 evil（`seshat-reader--disable-evil'，定义在
;; `seshat-reader'）。这里的 `require' 只在运行时执行，字节编译期不加载，
;; 故显式声明签名以消除「not known to be defined」告警。
(declare-function seshat-reader--disable-evil "seshat-reader" ())

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

(defvar seshat-reader-translate--cache (make-hash-table :test #'equal)
  "翻译/解释结果缓存：KEY → 结果字符串.
KEY 为 `(KIND PRESET LANGS REQUEST-TEXT)'：KIND 取 `translate' / `explain'
（译文与解释**不共用**条目——两者的模板与模型输入都不同），PRESET 是本次使用
的 gt 预设名，LANGS 是目标语言列表，REQUEST-TEXT 是**实际送给模型的文本**
（译文路径为纯选区，解释路径为 `seshat-reader-translate--explain-request-text'
装配出的「上下文 + 原文 + 指令」串，故上下文变化自然视为不同条目）。

命中的效果与「重新请求」一致：把结果写进
`seshat-reader-translate-last-result'，再按原模板渲染面板，只是**不发起请求**。
`C-u' 前缀（或 `seshat-reader-translate-selection' 的 FORCE 参数）跳过命中。

**仅本会话内存**：不落盘、不跨 Emacs 进程，重启即清空；清空用
`seshat-reader-translate-clear-cache'。**流式路径不写缓存**：面板路径恒为非
流式（`seshat-reader-translate--stream-wanted-p' 对面板返回 nil），故缓存只在
`seshat-reader-translate--record-result' 的成功分支写入——posframe 模式的流式
增量不经过该函数，其结果不进本表（要缓存就让面板承载接管，或关掉流式）。")

(defvar seshat-reader-translate--pending-cache-key nil
  "本次请求成功后要写入 `seshat-reader-translate--cache' 的 KEY，或 nil.
**只由 `seshat-reader-translate--render-object' 的 `:then' 回调动态绑定**
（`let`），并只在回调内被 `seshat-reader-translate--record-result' 读取一次、
随后清回 nil；它**没有**全局值，也不由命令 `setq'。

为什么绑定放在回调里：gt 的请求是**异步**完成的，命令返回时结果还没到，命令
里的动态绑定那时早已出栈。`:then' 闭包捕获了本次请求的 KEY（由
`--translator' 经 `--cache-key' 算出），在回调执行时再建立绑定，于是「写缓存」
与「这次请求」严格一一对应——不会出现「上一个请求留下的 KEY 被下一个请求的
结果写入」这种串条目，也正是靠这条，posframe / 流式路径（不经过 `:then'）
天然不写缓存。")

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

(defvar-local seshat-reader-translate--panel-context nil
  "面板 buffer 当前承载的语境（buffer-local）：`translate' 或 `explain'.
翻译与解释共用同一个面板 buffer 与同一个面板 kind（`translate'），故
`seshat-reader-sidebar-panel-visible-p' 只能回答「面板是否显示」，回答不了
「显示的是译文还是解释」。两个 toggle（`-toggle' / `-explain-toggle'）要做到
一一对应（面板里是译文时按「解释」键应**替换**成解释、而不是关掉面板），就
必须另有语境记录，本变量即该记录。

写入点：`--render-panel'（非流式与缓存重绘）与 `--stream-init'（流式骨架）——
两者都必须在 `--prepare-view' **之后**设置，因为切 major mode 会
`kill-all-local-variables'。读取走 `--panel-context'（读面板 buffer 的这一份，
不是当前 buffer 的）。")

(defconst seshat-reader-translate--follow-up-buffer-name " *Seshat gt follow-up*"
  "追问请求的 go-translate 中转 buffer 名.
与首轮的 `seshat-reader-translate--gt-buffer-name' 分开，避免追问的增量输出
与首轮渲染互相覆盖；同样是隐藏 buffer（两侧各一个空格是 gt 隐藏 buffer 的
惯例，`seshat-reader-sidebar-buffer-p' 不匹配它）。")

(defvar-local seshat-reader-translate--follow-up-state nil
  "面板 buffer 上的追问状态（buffer-local plist），nil 表示尚无首轮结果.
字段：
`:source'         追问所针对的原文（首轮选中文本，无选区时为 nil）；
`:answer'         首轮解释/译文（流式场景在完成回调里补成最终文本）；
`:langs'          首轮使用的语言对（追问复用，gt 需要目标语言）；
`:kind'           `translate' 或 `explain'，决定追问复用哪个预设；
`:round'          已发起的追问轮次序号（0 表示还没追问过）；
`:answer-marker'  当前轮答案区起点的 marker（无进行中的轮次时为 nil）；
`:answer-start'   当前轮是否仍在生成（真表示增量应写进答案区）。
由 `seshat-reader-translate--follow-up-reset-state' 在新一次翻译/解释时重置，
`seshat-reader-translate--follow-up-start' 与
`seshat-reader-translate--follow-up-complete' 在追问开始/结束时更新。")

(defgroup seshat-reader-translate nil
  "阅读器选区的翻译与解释（基于 go-translate）."
  :group 'seshat-reader
  :prefix "seshat-reader-translate-")

(defcustom seshat-reader-translate-preset 'reader
  "翻译时使用的 gt 预设名（符号）.
取值应是 `seshat-reader-translate-presets' 或 `gt-preset-translators' 中
某个预设的键（前者优先）。命中该预设时本模块会克隆它（见
`seshat-reader-translate--translator'）；未命中时 `message' 提示并回退到
内置的 youdao/google 翻译器。"
  :type 'symbol
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-explain-preset 'reader-explain
  "解释（而非纯翻译）时使用的 gt 预设名（符号）.
语义与 `seshat-reader-translate-preset' 相同，只是供“解释选区”一类
用途使用；该预设需用户在自己的 gt 配置中提供，未提供时回退到内置的
youdao/google 翻译器。"
  :type 'symbol
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-presets nil
  "Seshat 专用的 gt 预设表：名字 → gt-translator 对象，或名字 → thunk.
thunk 是无参函数，调用后返回 `gt-translator' 对象；用它可以把预设构造推迟到
gt 真正加载之后（`use-package gt :config' 里定义的预设就是这种情况）。

查表顺序见 `seshat-reader-translate--preset-translator'：**本表优先**，未命中
回落 gt 的全局表 `gt-preset-translators'。因此 seshat 的预设不必再 `push'
进 gt 的全局表，也就不会出现在 gt 自己的预设选择列表里。"
  :type '(alist :key-type symbol :value-type (choice (function :tag "thunk") sexp))
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-context-enabled t
  "解释选区时是否把同页邻近文本作为上下文注入 prompt.
nil 时 `seshat-reader-translate--context-text' 直接返回 nil，完全不触碰 C 模块。"
  :type 'boolean
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-context-lines 2
  "上下文向选区上下各扩的行数.
上下文取自「选区上方块 + 下方块」两个矩形，各向选区外扩此行数：实现见
`seshat-reader-translate--expand-rect'（按选区触达的行矩形估算行高后外扩）
与 `seshat-reader-translate--context-text'。"
  :type 'natnum
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-context-max-chars 1200
  "上下文文本的字符数上限.
上限由 `seshat-reader-translate--context-window' 落实：矩形路径拿到的
「上方块 + 下方块」不含选区，定位不到选区，因此只保留前 MAX-CHARS 个字符
（矩形路径失败、降级到整页文本时才以选区为中心取窗口）。"
  :type 'natnum
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-explain-prompt
  "## 任务

解释下文「需要解释的原文」，读者是一位正在读专业书的中文读者。不要翻译，不要复述原文。

## 要求

1. 首行用一句话概括这段在说什么（≤30 字，加粗）。
2. 随后用 2-4 个要点展开：关键概念/术语的准确含义、它在本文语境中的作用、读者容易误解的地方。
3. 术语首次出现时给出「英文原词（中文释义）」。
4. 若原文含代词指代、代码、公式，明确指出它指代/对应什么。
5. 全文不超过 200 字；信息不足时直说「仅凭本段无法确定」，不要编造。
6. 输出 Markdown，不要用代码围栏包裹整段。

## 上下文（仅供理解，不要解释）

{{context}}

## 需要解释的原文

{{text}}
"
  "解释 prompt 模板；nil 表示不装配（只发送纯选区，由引擎 `:root` 决定行为）.
nil 的真实语义：不装配 → 只发送纯选区文本，由引擎的 `:root`（system
prompt）决定行为。注意 `reader-explain` 预设的 `:prompt' 已改为纯透传
\"{{text}}\"（解释指令改由 seshat 装配），因此 nil **不等于**恢复此前的旧
中文长 prompt——需要那种效果请在配置侧把 `:prompt' 改回长指令。

占位符：`{{text}}' 选区原文、`{{context}}' 上下文（可能为空）、`{{doc}}' 文档名
（无则替换为「未知文档」）、`{{lang}}' 语言对（如 \"en → zh\"，可能为空）。
输入值里的 `{{' 会被转义，原样保留在结果中，不参与替换。

**每个标题行后必须留一个空行**：thomas-emacs 的软换行归一化
（`+thomas/normalize-soft-wraps'）只在空行处分段；`## ' 开头的行虽是保护行，
但它只保留**自身之前**的换行，紧随其后的普通正文行会被并入它。"
  :type '(choice (const :tag "不装配（沿用预设 prompt）" nil) string)
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-explain-max-chars 2000
  "解释时送模型的选区原文字符上限，超出则截断并标注.
只影响送引擎的文本（见 `seshat-reader-translate--truncate-selection'），
不影响面板原文引用块与追问的原文来源（两者都取
`seshat-reader-translate--selection-source-text'，即**完整**选区）。取值
非正整数时关闭截断。"
  :type 'natnum
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-strip-chatter t
  "是否去掉模型输出正文前的寒暄首行（如「好的，以下是…：」）.
作用于 `seshat-reader-translate--record-result'（见
`seshat-reader-translate--strip-chatter'），因此对翻译与解释、面板与
posframe 四条组合都生效；流式增量路径（`seshat-reader-translate--stream-sync'）
不经过该函数，故流式期间首行仍可见，收尾后的 `last-result' 已净化。
设为 nil 即恢复「原样输出」。"
  :type 'boolean
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
时静默跳过。批注列表面板不受本变量影响。
只在**折行模式**下生效（`seshat-reader-panel-truncate-lines' 为 nil，即默认
配置）——不折行 + 横向滚动与按列宽折行互斥。"
  :type 'boolean
  :safe #'booleanp
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-visual-fill-column-ratio 0.94
  "面板正文宽度占面板窗口可用宽度的比例.
非 nil 时，`seshat-reader-translate--vfcm-follow-window' 把
`visual-fill-column-width'（buffer-local）设为「窗口可用文本宽度 × 本值」，
让正文宽度随面板窗口同步变化：按 `w' / `C-c w' 加宽面板或手动拖拽窗口时，
新增宽度用于**正文**而不是留白。vfcm 默认 `visual-fill-column-center-text' 为
nil → 正文**左对齐**、未占用的约 6% 集中在**右侧**（若用户把该项设为 t，则
左右各约 3%）；本包**不**设置该变量，尊重用户全局配置。

**`nil` = 恢复旧行为（正文固定为全局 `fill-column'，扩宽面板后仍只增留白）**：
此时不设置 `visual-fill-column-width'，vfcm 回落到
`(or visual-fill-column-width fill-column)' 的 `fill-column' 分支，即 M11.14
引入的「正文宽度恒定」语义。

只在 `seshat-reader-translate-visual-fill-column' 非 nil 且处于折行模式时
有意义（vfcm 未启用时本值不起作用）；取值建议在 `(0, 1]` 区间，非正数会被
上方 `max 1' 夹到 1 列。"
  :type '(choice (const :tag "沿用全局 fill-column（旧行为）" nil) number)
  :safe #'numberp
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-valign t
  "译文/解释面板是否启用 `valign-mode'.
非 nil 时在 `seshat-reader-translate--prepare-view' 末尾启用 `valign-mode'，
让面板里的 Markdown 表格按列视觉对齐（CJK 宽字符与 ASCII 混排时尤其明显）。

**译文与解释共用同一 buffer**（`seshat-reader-sidebar-translate-buffer-name'，
只有 header-line 不同），故本开关**无法只对解释生效**——两者要么都开、要么
都关。

`valign' 为**软依赖**：未安装时静默跳过（不报错、不提示），面板照常渲染。
**非图形环境静默跳过（不提示）**：`display-graphic-p' 为 nil（batch / 终端）
时不调用 `valign-mode'——它自身在非图形环境下只会 `message' 一句
\"Valign mode has no effect in non-graphical display\"，本包提前拦掉以免面板
每次渲染都刷一条无意义提示。

只在折行模式下生效（与 `seshat-reader-translate-visual-fill-column' 同条件）；
关闭面板宽度跟随（`...-visual-fill-column-ratio' 设为 nil）不影响本开关，
两者互不耦合。"
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
「完成后一次性渲染」的旧路径。

**只对 `delimit' 为 nil 的引擎生效（LLM 类）**：gt 在引擎 `stream' 为 t 时
跳过 `delimit' 的 join（`gt-core.el' 的 `gt-execute'），引擎会拿到分段列表
而非字符串；youdao / google 等依赖 join 的引擎（`delimit' 非 nil）自动跳过，
翻译仍然一次性返回。

**面板（`sidebar'）渲染下本开关不生效**：gt 的纯流式既不调 `gt-update'
（translator `state' 停在 2，渲染对象 `:then' 永不触发），也不调渲染器的
output 函数（`gt-buffer-render-output-hook' 永不触发），而面板路径的
markers 位于 `(display-buffer-no-window)' 隐藏的 buffer 里——开了流式就只有
「增量写进没人看得到的 buffer」，面板不出现也不报错。故
`seshat-reader-translate--stream-wanted-p' 在面板路径返回 nil，强制走非流式。
本开关因此只对 posframe 渲染（`pop'/`pin'，或面板被禁用时的回退路径）有意义。"
  :type 'boolean
  :group 'seshat-reader-translate)

(defcustom seshat-reader-translate-follow-up-max-rounds 6
  "追问历史最多保留的轮数（`seshat-reader-translate-follow-up' 用）.
每一轮追问是「问 + 答」两条 messages；保留的轮数越多，每次请求的上下文越长、
费用越高。超出本值时**丢弃最早的轮次**，只保留最近的这么多轮——注意首轮的
原文与首轮解释（messages 的前两条）**始终保留**，不属于丢弃范围，否则追问就
失去了讨论对象。取 0 表示不带任何历史轮次（每次追问只看原文与首轮解释）。"
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

(defun seshat-reader-translate--hidden-gt-buffer-names ()
  "返回两个 gt 中转（隐藏）buffer 的名字列表.
`seshat-reader-translate--gt-buffer-name'（首轮翻译/解释）与
`seshat-reader-translate--follow-up-buffer-name'（追问）各自独立，避免互相
覆盖输出。两者都必须永不显示窗口，故在此集中成一处，供
`seshat-reader-translate--ensure-hidden-gt-buffers' 与测试共用。"
  (list seshat-reader-translate--gt-buffer-name
        seshat-reader-translate--follow-up-buffer-name))

(defun seshat-reader-translate--ensure-hidden-gt-buffers ()
  "把两个 gt 中转 buffer 名登记进 `display-buffer-alist'：一律不显示窗口.
`:window-config' 槽只影响 `gt-init' 里的**那一次** `display-buffer'；
`gt-buffer-render' 的输出方法在 translator 完成时（state = 3）**另有一次**
`(display-buffer buf)'——不带 action，直接落到 `display-buffer-alist' 的默认
动作，于是追问的中转 buffer（名字两侧带空格的那个 ` *Seshat gt follow-up*'）
会在答案到达的瞬间被弹出来挤占阅读窗口（实测：PDF 被挤到左半边）。用户配置里给
`\\*Seshat gt\\*' 写过一条 no-window 的条目，恰好只盖住首轮那个名字，追问的
名字带 ` follow-up' 后缀，正则匹配不到，因此暴露了这条缺口。

本函数给两个名字各注册一条 `(display-buffer-no-window)' +
`(allow-no-window . t)'，使两次显示都落空（缺 `allow-no-window' 时
`display-buffer' 会报 \"No window\"）。幂等：已存在同 REGEXP 的条目时不再重复
插入；只在缺失时补一条**精确匹配**（`\\`` + `regexp-quote' + `\\''），不会
误伤其它 buffer，返回 t。"
  (dolist (name (seshat-reader-translate--hidden-gt-buffer-names))
    (let ((regexp (concat "\\`" (regexp-quote name) "\\'")))
      (unless (assoc regexp display-buffer-alist)
        (push (list regexp '(display-buffer-no-window)
                    '(allow-no-window . t))
              display-buffer-alist))))
  t)

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
    (define-key map (kbd "M-o") #'seshat-reader-sidebar-toggle)
    (define-key map (kbd "C-c w") #'seshat-reader-sidebar-toggle-width)
    (define-key map (kbd "C-c C-s") 'seshat-reader-translate-save-as-annotation)
    (define-key map (kbd "C-c C-q") #'seshat-reader-translate-follow-up)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "w") #'seshat-reader-sidebar-toggle-width)
    map)
  "面板 buffer 的键位.
`q' 关闭面板（`seshat-reader-sidebar-quit'：只关本面板所在 kind，child frame
承载时走 `delete-frame'，不会连带关掉其它 kind）；
`M-o' **全部面板**开合（`seshat-reader-sidebar-toggle'：面板开着就全部关闭，
关了重开最近一个——在面板里按 `M-o' 与在阅读 buffer 里按完全等价，不必先切回
阅读 window；同一绑定写在阅读 buffer、批注列表、目录面板、搜索结果侧栏四个
键表上）；
`C-c w' 切换面板宽度（`seshat-reader-sidebar-toggle-width'：常态 ↔
`seshat-reader-sidebar-expanded-width'，与阅读 buffer / 批注列表 / 目录面板
同一键位）；
`seshat-reader-translate-save-as-annotation' 把最近一次译文存为批注；
`seshat-reader-translate-follow-up'（对面板里的原文继续追问）也绑在本 map 上。
`j' / `k' 逐行上下移动（`next-line' / `previous-line'：面板是只读视图，与
evil 的 normal state 同名键位一致，故面板开启时关闭 evil，见
`seshat-reader--disable-evil'）；`w' 切换面板宽度，与 `C-c w' 等价（两个绑定
都指向 `seshat-reader-sidebar-toggle-width'）。
用 minor mode 承载而非 `local-set-key'，以免污染 Markdown 视图 mode 的键位表
（同名 mode 的 map 是共享对象）。")

(define-minor-mode seshat-reader-translate-panel-mode
  "Seshat 译文/解释面板的键位与只读视图小模式." :lighter nil
  :keymap seshat-reader-translate-panel-map
  ;; evil 是软依赖：面板里 `j' / `k' 必须落到本 map 的 `next-line' /
  ;; `previous-line'，而 evil 的 normal state 经 `emulation-mode-map-alists'
  ;; 优先于本 mode 的键表。只在开启方向关闭 evil；关闭本 minor mode 时不必
  ;; 恢复（面板 buffer 随之关闭或被复用，无残留状态）。
  (when seshat-reader-translate-panel-mode
    (seshat-reader--disable-evil)))

(defun seshat-reader-translate--view-mode-function ()
  "返回可用的 Markdown 只读视图 major mode 函数符号.
按降级链依次判定：`gfm-view-mode'（支持 GFM 表格与任务列表）→
`markdown-view-mode' → `text-mode'，用 `fboundp' 判断可用性。markdown-mode
是**软依赖**：未安装时前两者都不存在，回退 `text-mode' 保证渲染不报错。"
  (cond ((fboundp 'gfm-view-mode) 'gfm-view-mode)
        ((fboundp 'markdown-view-mode) 'markdown-view-mode)
        (t 'text-mode)))

(defun seshat-reader-translate--vfcm-available-width (window)
  "返回 WINDOW 的可用文本宽度（与 vfcm 同源，含 text-scale 因子）.
`visual-fill-column--window-max-text-width' 的口径是「remap 换算后的窗口宽度
+ 左右 margin × remap 比例」，再按 text-scale 折算，即排除 fringes /
scroll-bar / 右侧 divider 之后的可用列数。**不得**改用 `window-body-width'：
它比 vfcm 的口径少 2–4 列，会让实际正文比
`seshat-reader-translate-visual-fill-column-ratio' 算出的比例更窄。

remap 比例 `remap-scale = (window-width WINDOW \\='remap) / (window-width WINDOW)'`
用于把 margin 的列数折算到 remap 坐标（Emacs 29+ 起 remap 与逻辑列可能不同）。

text-scale 因子与 vfcm 的 `visual-fill-column-adjust-for-text-scale' 分支同源：
该选项非 nil（默认）时取 WINDOW 的 buffer 内
`(expt text-scale-mode-step text-scale-mode-amount)'，并作为**除数**（放大字体
后一个「列」更宽，有效列数相应变少）；因子取不到或非正数时回退 1.0。

WINDOW 非 live、任一取值为 nil 或非正数时返回 nil（交调用方静默跳过）。"
  (when (and (windowp window) (window-live-p window))
    (let ((remap (window-width window 'remap))
          (plain (window-width window))
          (margins (window-margins window)))
      (when (and (integerp remap) (> remap 0)
                 (integerp plain) (> plain 0))
        (let* ((remap-scale (/ (float remap) plain))
               (left (or (car margins) 0))
               (right (or (cdr margins) 0))
               ;; text-scale 是 buffer-local，必须在 WINDOW 的 buffer 内取值。
               (raw-scale (if (and (bound-and-true-p visual-fill-column-adjust-for-text-scale)
                                   (boundp 'text-scale-mode-step)
                                   (boundp 'text-scale-mode-amount))
                              (with-current-buffer (window-buffer window)
                                (expt text-scale-mode-step text-scale-mode-amount))
                            1.0))
               (scale (if (or (not (numberp raw-scale)) (<= raw-scale 0))
                          1.0
                        raw-scale))
               (avail (truncate (/ (+ remap
                                      (* left remap-scale)
                                      (* right remap-scale))
                                   (float scale)))))
          (when (> avail 0) avail))))))

(defun seshat-reader-translate--vfcm-follow-window (&optional window)
  "把正文宽度设为 WINDOW 可用宽的 `...-visual-fill-column-ratio'，并重算 margin.
WINDOW 缺省取当前 buffer 所在的可见窗口；取不到（nil 或非 live）时静默返回 nil。

仅在 WINDOW 的 buffer 已启用 `visual-fill-column-mode' 时生效——vfcm 未启用时
`visual-fill-column-width' 没有任何消费者，设置它只会留下无意义的 buffer-local
残留值。

`seshat-reader-translate-visual-fill-column-ratio' 为 nil 时**直接返回**（nil
语义是「沿用全局 `fill-column'」；把 nil 传进乘法会报
`wrong-type-argument'）。

设置宽度后用 `visual-fill-column-adjust'（vfcm 的公开命令，非私有
`--set-margins'）在 WINDOW 内立即重算 margin：窗口尺寸变化时 vfcm 自己也会
（以 `'append' 注册在 `window-state-change-functions'），但那里要等 hook 轮到
它才执行，且首次显示时算的是 selected window；本函数主动调一次作为双保险。

留白落点由 vfcm 的 `visual-fill-column-center-text' 决定（默认 nil）：正文
左对齐，未占用的约 6% 全部落在**右侧**；该项为 t 时左右各约 3%。本包不
`setq-local' 该变量。

返回设置后的 `visual-fill-column-width'（便于测试断言）；未生效时返回 nil。"
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    (when (and (windowp window) (window-live-p window))
      (with-current-buffer (window-buffer window)
        (when (bound-and-true-p visual-fill-column-mode)
          (when (numberp seshat-reader-translate-visual-fill-column-ratio)
            (let* ((ratio seshat-reader-translate-visual-fill-column-ratio)
                   (avail (seshat-reader-translate--vfcm-available-width window)))
              (when avail
                (setq-local visual-fill-column-width
                            (max 1 (round (* avail ratio))))
                (when (fboundp 'visual-fill-column-adjust)
                  (ignore-errors
                    (with-selected-window window
                      (visual-fill-column-adjust))))
                visual-fill-column-width))))))))

(defun seshat-reader-translate--vfcm-refresh (&optional window)
  "窗口状态变化 / 面板显示后刷新正文宽度的入口.
转调 `seshat-reader-translate--vfcm-follow-window'，整体用 `ignore-errors'
包裹：本函数被注册为 `window-state-change-functions' 的 hook 函数，hook 里
抛错会打断同一 hook 上后续函数（包括 vfcm 自己的 margin 调整），故必须静默。
WINDOW 缺省交由 `seshat-reader-translate--vfcm-follow-window' 自行解析。"
  (ignore-errors
    (seshat-reader-translate--vfcm-follow-window window)))

(defun seshat-reader-translate--prepare-view ()
  "把当前 buffer 设为译文面板的只读 Markdown 视图.
先调 `seshat-reader-translate--view-mode-function' 选出的 major mode（隐藏
Markdown 标记、标题分级、列表缩进、代码块），再按
`seshat-reader-panel-truncate-lines' 设置折行与横向滚动：

- nil（**默认**）：**折行**——`truncate-lines' 为 nil、`word-wrap' 为 t。
  `gfm-view-mode' 实测不设 `word-wrap'，不显式设置就只能按字符边界硬折行，
  CJK 折行效果差，故必须显式打开；
- 非 nil：不折行——`truncate-lines' 为 t、`word-wrap' 为 nil、
  `auto-hscroll-mode' 为 t（面板较窄，长行必须能横向滚动，否则超出宽度的内容
  既看不见也到不了）；此时**跳过** `visual-fill-column-mode`，二者互斥（按列宽
  折行与横向滚动不能并存），跳过时不 `message' 提示。

最后设 `buffer-read-only' 为 t。

major mode 调用失败（如 autoload 指向的库缺失）时回退 `text-mode'，保证
面板渲染不因软依赖缺失而报错。

**折行模式**（默认）下，末尾按 `seshat-reader-translate-visual-fill-column'
启停 `visual-fill-column-mode'（软依赖 `visual-fill-column'，未安装时静默
跳过），让面板正文按 `visual-fill-column-width'（nil 时回退 `fill-column'）
缩窄/居中；不折行模式不做这一步（二者互斥）。故默认配置下面板正文是
「折行 + 可选 `visual-fill-column-mode`」，横向滚动只在不折行模式出现。"
  (let ((mode (seshat-reader-translate--view-mode-function)))
    (condition-case nil
        (funcall mode)
      (error (text-mode))))
  (if seshat-reader-panel-truncate-lines
      (progn
        ;; 不折行 + 允许横向滚动：长行超出面板宽度时可 hscroll（`scroll-left'
        ;; / `C-x <' 可用），否则被截断的右半部分永远看不到。
        (setq-local truncate-lines t)
        (setq-local word-wrap nil)
        (setq-local auto-hscroll-mode t))
    (setq-local truncate-lines nil)
    (setq-local word-wrap t))
  (setq-local buffer-read-only t)
  ;; 折行与 visual-fill-column 互斥：后者按列宽硬折行，与 truncate-lines 为 t
  ;; 的横向滚动冲突，故不折行模式下整体跳过（不提示，属正常语义）。
  (when (and (not seshat-reader-panel-truncate-lines)
             (or (fboundp 'visual-fill-column-mode)
                 (require 'visual-fill-column nil t)))
    ;; 启用时立即设 margin；关闭时仅当面板已显示（窗口可能残留旧 margin）
    ;; 才传 -1 清理——面板未显示时 selected-window 是阅读器窗口，传 -1 会
    ;; 误清它的 margin/fringe。
    (if seshat-reader-translate-visual-fill-column
        (visual-fill-column-mode 1)
      (when (get-buffer-window (current-buffer))
        (visual-fill-column-mode -1))))
  ;; 正文宽度跟随面板窗口 + valign：都只在折行模式下接线（不折行模式下
  ;; 按列宽折行与横向滚动互斥，vfcm 整体被跳过，跟随宽度自然也不该生效）。
  (unless seshat-reader-panel-truncate-lines
    (if seshat-reader-translate-visual-fill-column
        ;; **不加 append**：vfcm 在 Emacs 28+ 用
        ;; `(add-hook 'window-state-change-functions
        ;;            #'visual-fill-column--adjust-window 'append 'local)'
        ;; 注册 margin 调整；这里 prepend 才能保证「先按新窗口宽度改
        ;; `visual-fill-column-width'、再由 vfcm 算 margin」。顺序是外部包契约，
        ;; 不要改成 append 或手动重排。
        (add-hook 'window-state-change-functions
                  #'seshat-reader-translate--vfcm-refresh nil 'local)
      ;; 防御性冗余：本函数每次都以 `funcall mode' 换 major mode，那会
      ;; `kill-all-local-variables' 清掉 buffer-local 宽度，故这里多半是空操作；
      ;; 真正的语义是「旧行为 = 不设宽度、由 vfcm 回退 fill-column」。
      (when (boundp 'visual-fill-column-width)
        (kill-local-variable 'visual-fill-column-width)))
    ;; valign 与 vfcm 同条件：折行模式下让 Markdown 表格列视觉对齐。软依赖，
    ;; 缺失静默跳过。非图形环境直接跳过——`valign-mode' 自身只会 `message'
    ;; 「Valign mode has no effect in non-graphical display」，每渲染一次就刷
    ;; 一条无意义提示；`ignore-errors' 挡不住 `message'，故显式判 `display-graphic-p'。
    (when (and seshat-reader-translate-valign
               (display-graphic-p)
               (or (fboundp 'valign-mode) (require 'valign nil t)))
      (ignore-errors (valign-mode 1)))))

(defun seshat-reader-translate--as-string (value)
  "把 VALUE 规范成字符串，用于防御「上游把 gt 的分段列表当字符串传入」.
字符串原样返回；nil 返回空串；全部元素都是字符串的 list 用换行拼接（gt 的
translator `text' 槽就是这个形状，一个选区是单元素列表）；其它值用 `format'。
诊断依据：用户环境中曾出现 `Wrong type argument: stringp, (\"选区文本\")'，
来自 gt 异步渲染路径把整表喂给字符串函数；本包边界处统一规范化可避免同类崩溃。"
  (cond
   ((stringp value) value)
   ((null value) "")
   ((and (listp value) (cl-every #'stringp value)) (string-join value "\n"))
   (t (format "%s" value))))

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
引用块填 `%q'，TEXT 填 `%t'。所选模板为 nil 时原样返回 TEXT（仍经
`seshat-reader-translate--as-string' 规范成字符串）。渲染后压缩
占位符为空造成的连续空行（`\\n{3,}' → `\\n\\n'）并补一个尾换行。仅
`format-spec' 调用包在 `condition-case' 内：模板非法时 `message' 警告并
原样返回 TEXT。

TEXT 在进入 `format-spec' 之前经 `seshat-reader-translate--as-string' 规范
成字符串：gt 的 translator `text' 槽可能是**分段列表**（一个选区是单元素
列表），直接喂给 `format-spec' 会把它 prin1 成 `(\"…\")' 静默写进面板。"
  (let ((template (if (eq context 'explain)
                      seshat-reader-translate-explain-template
                    seshat-reader-translate-template)))
    (if (null template)
        (seshat-reader-translate--as-string text)
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
                                     (cons ?t (seshat-reader-translate--as-string
                                               text))))
                (error
                 (message "Seshat Reader translate: 模板渲染失败（%s），回退纯正文"
                          (error-message-string err))
                 nil)))
        (if (null rendered)
            (seshat-reader-translate--as-string text)
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
`seshat-reader-sidebar-show' 以 `translate' 类型显示（SELECT 传 **nil**：阅读
场景**不抢光标**，见下）。

**SELECT 为 nil 的理由**：用户在阅读窗口里选中文字后触发译文/解释（见
`seshat-reader-translate-toggle' / `seshat-reader-translate-explain-toggle'）
是要「看一眼译文」，此时把光标挪进面板会让接下来的滚动/翻页键落到面板上，读的
节奏被打断。光标留在阅读窗口后，需要编辑或复制译文时点进面板即可；若确要让面板
在显示后接管光标，把 `seshat-reader-sidebar-select-window' 保持默认非 nil，并
把本调用与 `seshat-reader-translate--stream-init' 里的 SELECT 改回非 nil（popper
的重开路径 `seshat-reader-sidebar-display-buffer' 本来就传非 nil）。
流式路径 `seshat-reader-translate--stream-init' 同样传 nil。

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
      ;; 新一次翻译/解释：重置追问状态（原文、首轮答案、轮次全部从头开始）。
      ;; 必须在 `--prepare-view' 之后——它切换 major mode 会
      ;; `kill-all-local-variables'，把 buffer-local 状态一并清掉。
      (seshat-reader-translate--follow-up-reset-state text langs context)
      ;; 语境（译文 / 解释）另记一份 buffer-local 值，供两个 toggle 判断
      ;; 「面板显示的是哪一份」（见 `seshat-reader-translate--panel-context'）。
      (setq seshat-reader-translate--panel-context
            (if (eq context 'explain) 'explain 'translate))
      (setq-local header-line-format title)
      (seshat-reader-translate-panel-mode 1)
      (goto-char (point-min)))
    ;; SELECT 传 nil：阅读场景不抢光标（详见本函数 docstring）。
    (seshat-reader-sidebar-show buffer 'translate nil)
    ;; 显示后按**面板窗口**（不是阅读窗口）再算一次正文宽度：`--prepare-view'
    ;; 里 `(visual-fill-column-mode 1)' 是以 selected window 计算首次 margin 的
    ;; （M11.14 已记录的已知副作用），此时面板刚显示、宽度与 margin 都可能
    ;; 算到别处，故在显示之后收口一次。
    (seshat-reader-translate--vfcm-refresh (get-buffer-window buffer t))
    buffer))

(defun seshat-reader-translate--panel-result ()
  "从中转 buffer 提取面板译文并写入 `seshat-reader-translate-last-result'.
定位 `seshat-reader-translate--gt-buffer-name' 指定的隐藏中转 buffer，在其中
调 `seshat-reader-translate--extract-result' 取 `(TEXT . FAILED)'，再交
`seshat-reader-translate--record-result' 写入（保留 error face 的失败判定，
并按 `seshat-reader-translate-strip-chatter' 净化后写入）。本函数把
`--record-result' 的**返回值**（净化后文本）原样透出，`:then' 回调据此重绘
面板，故面板正文与 `last-result' 内容一致。

写入后无论成功失败都调 `seshat-reader-translate--stream-complete' 收尾流式渲染
（把面板 header-line 从「生成中…」改成「已完成」并清骨架状态）；面板内容**不
重写**——增量期间写好的正文即最终内容，erase 重写会在完成瞬间造成整块跳变。
非流式路径（面板 buffer 无骨架）下该收尾是空操作。

成功时还经 `seshat-reader-translate--follow-up-update-answer' 把追问状态里的
`:answer'（首轮答案）补成最终文本——流式骨架建立时只记下了当时的**部分**增量
文本，直接用会让后续追问的上下文缺一截。

返回写入的译文；中转 buffer 不存在、译文为空（翻译失败或流式尚未产出）或
渲染结果带错误 face 时返回 nil，并保留上一次的译文。"
  (let ((buffer (get-buffer seshat-reader-translate--gt-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((result (seshat-reader-translate--record-result
                       (seshat-reader-translate--extract-result))))
          (seshat-reader-translate--stream-complete)
          (seshat-reader-translate--follow-up-update-answer result)
          result)))))

(defun seshat-reader-translate--render-object (mode &optional title langs context cache-key)
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
由后者据其选择翻译模板或解释模板；默认 nil 时按翻译模板处理。

CACHE-KEY 由 `--translator' 传入（`--cache-key' 构造的键，或 nil）：sidebar
分支把 `:then' 回调里的 `seshat-reader-translate--pending-cache-key' 动态绑定
成它，`--record-result' 据此在这次请求成功后写缓存。绑定写在**回调内**而不是
命令内——请求是异步完成的，命令的动态绑定那时已出栈，只有闭包捕获的 KEY 能在
回调触发时重新建立绑定。CACHE-KEY 为 nil（或 posframe 分支，那里不经过
`:then'）时 `--record-result' 不写缓存，与「posframe 流式结果不缓存」一致。"
  (pcase mode
    ('pin (gt-posframe-pin-render))
    ('sidebar
     (if seshat-reader-sidebar-enabled
         (progn
           (seshat-reader-translate--ensure-gt-buffer-render)
           (seshat-reader-translate--ensure-hidden-gt-buffers)
           (gt-buffer-render
            :name seshat-reader-translate--gt-buffer-name
            :window-config '((display-buffer-no-window)
                             (allow-no-window . t))
            :then (lambda (&rest _args)
                    ;; 先判定「增量期间是否已建骨架」，再调 `--panel-result'
                    ;; ——后者会清掉骨架标志，顺序反了就走不到流式分支。
                    (let ((seshat-reader-translate--pending-cache-key cache-key))
                      (let ((streamed (seshat-reader-translate--panel-streamed-p))
                            (result (seshat-reader-translate--panel-result)))
                        (when (and result (not streamed))
                          (seshat-reader-translate--render-panel
                           result title langs context)))))))
       (gt-posframe-pop-render)))
    (_ (gt-posframe-pop-render))))

;; --- 解释上下文：行矩形扩行 → 页面文本降级 ---
;;
;; 上下文提取要调动态模块（`render/render-core.c'）导出的三个查询函数。此处
;; 只声明签名以免字节编译告警；运行时一律 `fboundp' 守卫（未构建 `.so' 或模块
;; 未加载时它们 unbound），任何失败都静默返回 nil——批处理 / 无模块是常态。
(declare-function seshat-reader-dyn--lines-in-rect "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--text-in-rect "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--page-text "seshat-render-core"
                  (&optional page))

(defun seshat-reader-translate--expand-rect (rects lines)
  "Return RECTS grown by LINES lines above and below, as one rectangle.
RECTS is what `seshat-reader-dyn--lines-in-rect' returns: one
\(X0 Y0 X1 Y1) float quadruple per whole text line the selection
touches, in reading order.  The result is a single (X0 Y0 X1 Y1)
quadruple: horizontally the union of every rectangle, vertically the
union grown by LINES times an estimated line height, the latter being
\(max Y1 - min Y0) divided by the number of rectangles (a page's lines
are assumed evenly spaced, which is what makes a line-metric guess
possible at all without asking the module for font metrics).

Return nil when RECTS is not a non-empty list, when an element is not a
four-number list, or when the estimated line height is not positive
\(all rectangles share the same vertical span, so the line height cannot
be told apart from zero) — callers then fall back to the whole-page
text instead of growing the rectangle by a meaningless amount.

Pure: reads no global variable and never calls the dynamic module."
  (let ((n (if (natnump lines) lines 0))
        (count 0)
        (x0 nil)
        (y0 nil)
        (x1 nil)
        (y1 nil)
        (valid t))
    (when (listp rects)
      (dolist (rect rects)
        (if (and (listp rect)
                 (= 4 (length rect))
                 (numberp (nth 0 rect))
                 (numberp (nth 1 rect))
                 (numberp (nth 2 rect))
                 (numberp (nth 3 rect)))
            (setq count (1+ count)
                  x0 (if x0 (min x0 (nth 0 rect)) (nth 0 rect))
                  y0 (if y0 (min y0 (nth 1 rect)) (nth 1 rect))
                  x1 (if x1 (max x1 (nth 2 rect)) (nth 2 rect))
                  y1 (if y1 (max y1 (nth 3 rect)) (nth 3 rect)))
          (setq valid nil))))
    (when (and valid (> count 0))
      (let ((line-height (/ (- y1 y0) count)))
        (when (> line-height 0)
          (list x0 (- y0 (* n line-height)) x1 (+ y1 (* n line-height))))))))

(defun seshat-reader-translate--context-window (page-text selection max-chars)
  "Return at most MAX-CHARS characters of PAGE-TEXT around SELECTION.
SELECTION is located in PAGE-TEXT by a literal search; when it is found
the window runs from `half' characters before it to `half' characters
after it, where `half' is (/ MAX-CHARS 2), then shrunk from the left
when the result would still be longer than MAX-CHARS (a long SELECTION
eats into the same budget).  When SELECTION is nil, empty or absent from
PAGE-TEXT the first MAX-CHARS characters of PAGE-TEXT are returned
instead — a page-level context is better than none, and the caller has
already given up on the tighter rectangle query by then.

The window is then cleaned up for prompt embedding: runs of spaces and
tabs collapse to a single space (PDF extraction inserts one per glyph
gap), three or more consecutive newlines collapse to a paragraph break
and surrounding whitespace is trimmed.  A window that cleans up to the
empty string yields nil.

Return nil when PAGE-TEXT is not a non-empty string or MAX-CHARS is not a
positive integer.  Pure: reads no global variable and never calls the
dynamic module."
  (when (and (stringp page-text)
             (not (string-empty-p page-text))
             (natnump max-chars)
             (> max-chars 0))
    (let* ((length (length page-text))
           (beg (and (stringp selection)
                     (not (string-empty-p selection))
                     (string-match (regexp-quote selection) page-text)))
           (raw (if beg
                    (let* ((half (/ max-chars 2))
                           (start (max 0 (- beg half)))
                           (end (min length (+ beg (length selection) half)))
                           ;; 两侧各扩 half 后总长可能超过 MAX-CHARS（选区自身也
                           ;; 占预算）：从左端收缩以守住上限，且优先保住选区起点。
                           (start (if (> (- end start) max-chars)
                                      (max 0 (min beg (- end max-chars)))
                                    start)))
                      (substring page-text start (min end (+ start max-chars))))
                  (substring page-text 0 (min length max-chars))))
           (spaces (replace-regexp-in-string "[ \t]+" " " raw))
           (breaks (replace-regexp-in-string "\n\\{3,\\}" "\n\n" spaces))
           (trimmed (string-trim breaks)))
      (unless (string-empty-p trimmed)
        trimmed))))

(defun seshat-reader-translate--context-text ()
  "Return the neighbouring text of the last selection, or nil.
Used to feed the explain prompt with the page context around the
selection (see `seshat-reader-translate-context-lines' and
`seshat-reader-translate-context-max-chars').

The preferred path grows the selection to whole lines and then by
`seshat-reader-translate-context-lines' lines: the selection's `:page'
\(1-based) is turned into the module's 0-based PAGE, the rectangles of
the touched lines come from `seshat-reader-dyn--lines-in-rect' and the
grown rectangle from `seshat-reader-translate--expand-rect'.  The
context is then the text of the block **above** the selection (the
grown rectangle's X span, Y from the grown top to the selection top)
plus the text of the block **below** it (same X span, Y from the
selection bottom to the grown bottom), both from
`seshat-reader-dyn--text-in-rect' and joined by a blank line.  Nothing
is deleted from the extracted strings: the module inserts no line break
between text lines of one paragraph, so cutting the selection out with
a literal search would never match a selection that crosses lines — the
selection simply is not part of either rectangle.  The joined text then
goes through `seshat-reader-translate--context-window' with no
SELECTION, i.e. whitespace is cleaned up and only the first MAX-CHARS
characters are kept.

When the rectangle path is unavailable or yields nothing (no `:rect',
no line rectangles, or both blocks empty) the whole page text
\(`seshat-reader-dyn--page-text', again with the explicit 0-based PAGE —
the omitted-argument form depends on the selected window and is not
reliable in batch) goes through the same window function, this time
with the selection so that the window is centred on it.

Everything happens inside `condition-case' and no failure is reported:
the dynamic module is often missing (batch runs, an unbuilt `.so') and
a missing context must never break the explain command.
`seshat-reader-translate-context-enabled' being nil returns nil before
the module is touched at all."
  (when seshat-reader-translate-context-enabled
    (condition-case nil
        (let ((page (plist-get seshat-reader-select-last :page))
              (rect (plist-get seshat-reader-select-last :rect))
              (text (plist-get seshat-reader-select-last :text)))
          (when (and (integerp page)
                     (> page 0)
                     (listp rect)
                     (= 4 (length rect))
                     (stringp text)
                     (not (string-empty-p (string-trim text))))
            (let* ((index (1- page))
                   (x0 (nth 0 rect))
                   (y0 (nth 1 rect))
                   (x1 (nth 2 rect))
                   (y1 (nth 3 rect))
                   (max-chars seshat-reader-translate-context-max-chars)
                   ;; ①②③ 行矩形路径：触达整行 → 按行高外扩 → 分成上下两块取文本。
                   ;; 每一步都用 `ignore-errors' 兜住：模块缺失、结果为空都只是
                   ;; 「这一步没拿到」，交给下面的 `or' 继续降级。
                   (grown (ignore-errors
                            (when (fboundp 'seshat-reader-dyn--lines-in-rect)
                              (seshat-reader-translate--expand-rect
                               (seshat-reader-dyn--lines-in-rect
                                index x0 y0 x1 y1)
                               seshat-reader-translate-context-lines))))
                   (ctx (ignore-errors
                          (when (and grown
                                     (fboundp 'seshat-reader-dyn--text-in-rect))
                            (let* ((bx0 (nth 0 grown))
                                   (by0 (nth 1 grown))
                                   (bx1 (nth 2 grown))
                                   (by1 (nth 3 grown))
                                   ;; 选区矩形：`:rect' 的坐标已是 1-based 页上的
                                   ;; float，与行矩形同一坐标系，无需换算。
                                   (sy0 y0)
                                   (sy1 y1)
                                   (above (when (< by0 sy0)
                                            (seshat-reader-dyn--text-in-rect
                                             index bx0 by0 bx1 sy0)))
                                   (below (when (> by1 sy1)
                                            (seshat-reader-dyn--text-in-rect
                                             index bx0 sy1 bx1 by1))))
                              (when (or above below)
                                (string-join (delq nil (list above below))
                                             "\n\n")))))))
              (or
               ;; 矩形路径：上下文 = 选区上方块 + 下方块，不做「删除选区原文」的
               ;; 字符串操作（跨行选区与 raw 切片永不相等，剥离命中率恒为 0）。
               (and (stringp ctx)
                    (seshat-reader-translate--context-window
                     ctx nil max-chars))
               ;; ④ 整页降级：显式传 0-based 页号（省略参数时依赖 selected window）
               (ignore-errors
                 (when (fboundp 'seshat-reader-dyn--page-text)
                   (let ((page-text (seshat-reader-dyn--page-text index)))
                     (when (stringp page-text)
                       (seshat-reader-translate--context-window
                        page-text
                        text
                        max-chars)))))))))
      (error nil))))

(defun seshat-reader-translate--document-title ()
  "返回最近一次选区所属文档的名字，取不到时返回 nil.
名字取选区 `:file' 的 `file-name-base'（basename 去掉扩展名），**不输出
完整路径**：目录层级与文档内容无关，只会白占 prompt 预算，还可能把用户的
家目录结构带给远端引擎。`seshat-reader-select-last' 没有 `:file'、或它
不是非空字符串时返回 nil，由调用方替换为「未知文档」。

非纯函数：读全局变量 `seshat-reader-select-last'（不改状态、不调用动态
模块）。"
  (let ((file (plist-get seshat-reader-select-last :file)))
    (when (and (stringp file) (not (string-empty-p (string-trim file))))
      (file-name-base file))))

(defconst seshat-reader-translate--explain-placeholders
  '("{{text}}" "{{context}}" "{{doc}}" "{{lang}}")
  "模板里受支持的占位符列表（逐个完整匹配，不做前缀/大小写放宽）.")

(defconst seshat-reader-translate--explain-brace-sentinel "\0{"
  "输入值中转义 `{{' 用的哨兵：NUL 后跟 `{'.
输入值（选区、上下文、文档名、语言对）里的 `{{' 先换成本哨兵，四个占位符
替换完成后再还原为 `{{'，因此输入值中形如 `{{foo}}' 的片段既不会被替换、
也不会触发未知占位符判定。NUL 不会出现在模板与 PDF 文本里。")

(defun seshat-reader-translate--explain-escape-value (value)
  "把输入值 VALUE 里的 `{{' 换成哨兵，返回转义后的字符串；nil 视为空串.
只转义 `{{'：单个 `{' 不参与占位符语法，无需处理。

VALUE 先经 `seshat-reader-translate--as-string' 规范成字符串：gt 的
translator `text' 槽可能是**分段列表**，直接传给 `string-replace' 会抛
`Wrong type argument: stringp, (\"…\")'。"
  (string-replace "{{" seshat-reader-translate--explain-brace-sentinel
                  (seshat-reader-translate--as-string value)))

(defun seshat-reader-translate--explain-unknown-placeholder (template)
  "扫描 TEMPLATE（字符串）里的 `{{[^{}]*}}'，返回首个未知占位符或 nil.
`{{text}}' / `{{context}}' / `{{doc}}' / `{{lang}}' 视为已知而跳过；只看
模板本身，**不**判断任何输入值。"
  (let ((start 0)
        (unknown nil))
    (while (and (not unknown)
                (string-match "{{[^{}]*}}" template start))
      (let ((placeholder (match-string 0 template)))
        (if (member placeholder seshat-reader-translate--explain-placeholders)
            (setq start (match-end 0))
          (setq unknown placeholder))))
    unknown))

(defun seshat-reader-translate--explain-request-text (text context title &optional langs)
  "把 TEXT / CONTEXT / TITLE 装配成送引擎的完整 prompt 文本.
`seshat-reader-translate-explain-prompt' 为 nil 时原样返回 TEXT：此时不装配，
只发送纯选区文本，由引擎的 `:root'（system prompt）决定行为。注意
`reader-explain' 预设的 `:prompt' 已改为纯透传 \"{{text}}\"（解释指令改由
seshat 装配），因此 nil **不等于**恢复此前的旧中文长 prompt——需要那种效果
请在配置侧把 `:prompt' 改回长指令。

装配分**两个阶段**，顺序不可颠倒：

1. **先校验模板**：对 `seshat-reader-translate-explain-prompt' 本身扫描
   `{{[^{}]*}}'，扣掉四个已知占位符后仍有剩余 → 视为未知占位符：`message'
   警告（文案含「未知占位符」）并**回退返回 TEXT**，绝不把未解析的模板送进
   引擎。此阶段只读模板，**不对任何输入值做判断**。
2. **再替换，且输入值必须转义**：四个输入值里的 `{{' 先换成哨兵
   （`seshat-reader-translate--explain-brace-sentinel'），替换完成后还原为
   `{{'。这样输入值里的 `{{foo}}' 会原样保留在结果中，既不参与替换、也不
   触发第 1 阶段的未知占位符判定。

替换用 `string-replace' **逐个替换**，不用 `format-spec'：占位符是
`{{name}}' 风格，而 `format-spec' 以 `%' 为占位语法，遇到中文与 Markdown
正文里常见的 `%' 会直接报错。替换顺序：先 `{{context}}'（CONTEXT，nil 视为
空串）、`{{doc}}'（TITLE，nil 填「未知文档」）、`{{lang}}'（LANGS 经
`seshat-reader-translate--format-langs' 转成 \"en → zh\"；LANGS 为 nil 时
取 `seshat-reader-translate-fallback-langs'，仍无法格式化则留空），最后才
换 `{{text}}'（TEXT）。

除未知占位符那条 warning 外无副作用：不读选区、不调用动态模块。"
  (let ((template seshat-reader-translate-explain-prompt))
    (cond
     ((null template) text)
     ((seshat-reader-translate--explain-unknown-placeholder template)
      (message "Seshat Reader translate: 解释 prompt 存在未知占位符（未解析的 `{{'），回退纯选区")
      text)
     (t
      (let* ((lang-str (seshat-reader-translate--format-langs
                        (or langs seshat-reader-translate-fallback-langs)))
             (assembled template))
        (setq assembled
              (string-replace "{{context}}"
                              (seshat-reader-translate--explain-escape-value context)
                              assembled))
        (setq assembled
              (string-replace "{{doc}}"
                              (seshat-reader-translate--explain-escape-value
                               (or title "未知文档"))
                              assembled))
        (setq assembled
              (string-replace "{{lang}}"
                              (seshat-reader-translate--explain-escape-value
                               (or lang-str ""))
                              assembled))
        (setq assembled
              (string-replace "{{text}}"
                              (seshat-reader-translate--explain-escape-value text)
                              assembled))
        (string-replace seshat-reader-translate--explain-brace-sentinel
                        "{{" assembled))))))

(defconst seshat-reader-translate--chatter-regexp
  "\\`\\(?:好的\\|以下是\\|下面\\|这段\\|该段\\)[^\n]*[：:]\\s-*\n"
  "寒暄首行的识别正则：首行以常见寒暄词开头、且以冒号结尾.
锚定在文本开头（`\\\\='），`[^\\n]*[：:]' 要求冒号是该行最后一个非空白
字符，因此「这段代码做了什么：说明…」这类正文不会被误判（冒号不在行尾）。")

(defun seshat-reader-translate--strip-chatter (text)
  "去掉模型输出 TEXT 正文前的寒暄首行，其余情况原样返回.
仅当**首行**以「好的 / 以下是 / 下面 / 这段 / 该段」开头、且该行以全角
`：'或半角 `:' 结尾时，删掉该行与其后的空行，返回 `string-trim' 后的
剩余文本；不做任何其它清洗（缩进、编号、多余空行一律保留），以免误删正文。
删掉寒暄后剩余内容为空（模型只回了一行寒暄）时仍原样返回 TEXT——宁可留着
寒暄，也不把整段回答抹成空。

TEXT 为 nil 或非字符串时原样返回。本函数是纯函数，不读写任何全局状态；
开关 `seshat-reader-translate-strip-chatter' 由调用方
（`seshat-reader-translate--record-result'）判断，且该调用方在调用本函数
**之前**已用 `seshat-reader-translate--as-string' 把文本规范成字符串。"
  (if (not (stringp text))
      text
    (if (string-match seshat-reader-translate--chatter-regexp text)
        (let ((remainder (string-trim (substring text (match-end 0)))))
          (if (string-empty-p remainder) text remainder))
      text)))

(defun seshat-reader-translate--truncate-selection (text)
  "按 `seshat-reader-translate-explain-max-chars' 截断解释用的选区原文 TEXT.
长度未超上限、上限非正整数（关闭截断）、或 TEXT 非字符串时原样返回；
超限时保留前上限个字符并追加标注 `（选区过长，以上为节选）'。
只用于**送引擎**的文本：面板原文引用块与追问来源仍取完整选区
（`seshat-reader-translate--selection-source-text'）。纯函数。
调用方（`seshat-reader-translate--record-result' 一侧）已在边界处用
`seshat-reader-translate--as-string' 规范化文本。"
  (let ((max seshat-reader-translate-explain-max-chars))
    (if (or (not (stringp text))
            (not (integerp max))
            (< max 1)
            (<= (length text) max))
        text
      (concat (substring text 0 max) "\n\n（选区过长，以上为节选）"))))

(defun seshat-reader-translate--engine-label (translator)
  "返回 TRANSLATOR 首个引擎的「模型 @ 主机」描述，取不到时返回空串.
从 `(oref translator engines)' 取**第一个**引擎，只读 `model' 与 `host'
两个槽（`slot-exists-p' 守卫，槽不存在或值为空则省略），拼成如
「（deepseek-chat @ api.deepseek.com）」的字符串；两者都读不到时返回空串，
便于调用方直接拼进 `message'。

**绝不读取 `key' / `auth' / `token' 一类凭据槽**：本函数的返回值会进
`message' 与 `*Messages*'，只允许出现模型名与主机名。纯函数（只读对象
槽，不修改任何状态）。"
  (let ((engines (and (eieio-object-p translator)
                      (slot-exists-p translator 'engines)
                      (oref translator engines)))
        parts)
    (let ((engine (car-safe (and (listp engines) engines))))
      (when (eieio-object-p engine)
        ;; 槽名以字面量给出（`oref' 是宏，槽名不能走变量）；两个槽名已在
        ;; 文件头 `eval-when-compile' 里登记为 `slot-name'，编译期不会报
        ;; 「Unknown slot」。只读 model / host，**不读任何 key 类槽**。
        (let ((model (and (slot-exists-p engine 'model)
                          (oref engine model)))
              (host (and (slot-exists-p engine 'host)
                         (oref engine host))))
          (dolist (value (list model host))
            (when (and (stringp value) (not (string-empty-p (string-trim value))))
              (push (string-trim value) parts))))))
    (if parts
        (format "（%s）" (mapconcat #'identity (nreverse parts) " @ "))
      "")))

(defun seshat-reader-translate--preset-translator (preset)
  "按 PRESET 名返回对应的 gt-translator.
先查 `seshat-reader-translate-presets'，未命中再查 `gt-preset-translators'
（后者经 `gt-ensure-plain' 归一化）。值为函数时按 thunk 调用一次取结果。
两表都未命中、或 thunk 返回 nil 时返回 nil。"
  (let ((value (or (alist-get preset seshat-reader-translate-presets)
                   (alist-get preset (gt-ensure-plain gt-preset-translators)))))
    (if (functionp value) (funcall value) value)))

(defun seshat-reader-translate--cache-key (context preset langs text)
  "返回翻译/解释结果的缓存键，形式为 `(KIND PRESET LANGS TEXT)'.
KIND 由 CONTEXT 归一：`explain' → `explain'，其余（含 nil）→ `translate'——
译文与解释的模板、模型输入都不同，必须分表。PRESET 是 gt 预设名，LANGS 是
目标语言列表，TEXT 是**实际送模型的文本**（译文为纯选区，解释为装配好的
「上下文 + 原文 + 指令」串）。

本函数是键结构的**单一来源**：命令查表、`--translator' 交给 `:then' 回调写表，
都调它，避免「查的键」与「写的键」两处手写而漂移（那种漂移的表现为「缓存永远
不命中、或者命中到别的请求」）。"
  (list (if (eq context 'explain) 'explain 'translate) preset langs text))

(defun seshat-reader-translate--title (context)
  "返回面板标题：CONTEXT 为 `explain' 时是解释标题，其余为译文标题.
把「语境 → 标题」的映射收敛到一处：`seshat-reader-translate--translator' 用它
写面板 header-line 与流式状态，两个命令的缓存命中分支用它重绘面板——命中缓存
时不装配 translator，若无本函数就得在命令里重复一份同样的判断，两处一旦漂移就
会出现「首次请求显示『Seshat 译文』、命中缓存显示别的标题」。"
  (if (eq context 'explain) "Seshat 解释" "Seshat 译文"))

(defun seshat-reader-translate--translator (preset text langs &optional context request-text)
  "为 PRESET、TEXT 与 LANGS 构造一个可供 gt 使用的翻译器对象.
PRESET 是预设名（符号）：先查 `seshat-reader-translate-presets'，未命中
再查 `gt-preset-translators'（见
`seshat-reader-translate--preset-translator'）；命中时**克隆**该预设
（`clone'），未命中时 `message' 提示并回退到内置的 youdao/google
翻译器。预设对象是 gt 的单例缓存，直接改写其槽会污染其他使用者，因此
一律只把改动施加在克隆结果上。

TEXT 为待翻译的纯文本；LANGS 为目标语言列表（如 (en zh)）。二者通过
**重建 gt function `gt-taker'** 注入，并显式设置 `:pick nil' 以避免 gt 回退到
`gt-taker-pick' 按段落切分传入的字符串。渲染方式取自
`seshat-reader-translate-render'。返回设置好 taker 与 render 的
translator 对象；调用前会先确保 gt 已加载。

REQUEST-TEXT 为调用方**已装配好的** prompt 文本（解释路径用，见
`seshat-reader-translate--explain-request-text'），非 nil 时填入 taker 的
`:text'，nil 时用 TEXT —— 本函数自身不读选区、不调动态模块、不装配模板。
注意只有 taker 的 `:text' 用它；追问状态（
`seshat-reader-translate--follow-up-reset-state'）与面板原文引用块（`%q'）
仍取纯选区 TEXT。

CONTEXT 用于区分预设缺失时的提示文案，并决定面板模板，取 `translate'
（默认，纯翻译）或 `explain'（解释）：前者提示回退到内置翻译器并用
`seshat-reader-translate-template'，后者提示回退为普通翻译、建议在配置侧
定义解释预设，并用 `seshat-reader-translate-explain-template'。

`seshat-reader-translate--stream-wanted-p' 为真时（`seshat-reader-translate-stream'
非 nil **且**当前渲染方式能承接 gt 的流式增量；面板路径恒为 nil，原因见该谓词的
文档）末尾经 `seshat-reader-translate--enable-stream' 为各引擎开启流式，并登记本次
请求的标题 / 语言对 / 语境与 translator 身份（供
`seshat-reader-translate--stream-sync' 的守卫与骨架创建使用）。"
  (seshat-reader-translate--ensure-gt)
  (let* ((preset-trans (seshat-reader-translate--preset-translator preset))
         (title (seshat-reader-translate--title context))
         ;; 本次请求的缓存键：与命令查表用的是同一个构造函数（见
         ;; `--cache-key'），故「查的键」与「写的键」不会漂移。它被交给
         ;; `--render-object'，由 `:then' 回调在**回调执行时**把
         ;; `--pending-cache-key' 动态绑定成它——请求是异步完成的，命令里的
         ;; `let'/`setq' 那时早已出栈，只有闭包捕获的静态绑定能在回调里存活。
         (cache-key (seshat-reader-translate--cache-key
                     context preset langs (or request-text text)))
         (trans (if preset-trans
                    (clone preset-trans)
                  (message (if (eq context 'explain)
                               "Seshat Reader translate: 找不到解释预设 %S，回退为普通翻译（请在配置侧定义该预设以启用 LLM 解释）"
                             "Seshat Reader translate: 找不到预设 %S，回退到内置 youdao/google 翻译器")
                           preset)
                  (gt-translator :engines (list (gt-youdao-dict-engine)
                                                (gt-google-engine))))))
    (oset trans taker (gt-taker :text (or request-text text) :pick nil :langs langs))
    (oset trans render (seshat-reader-translate--render-object
                        seshat-reader-translate-render title langs context
                        cache-key))
    (when (seshat-reader-translate--stream-wanted-p)
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
`seshat-reader-translate-last-result' 的文档）。

成功分支写入的是**净化后**的文本：`seshat-reader-translate-strip-chatter'
非 nil（默认）时先经 `seshat-reader-translate--strip-chatter' 去掉寒暄
首行，并返回净化后的文本——面板路径与本函数的返回值因此一致，四条
「翻译/解释 × 面板/posframe」组合都生效。流式增量路径
（`seshat-reader-translate--stream-sync'）不经过本函数，其面板内容保持
模型原样输出。

成功分支在净化前先经 `seshat-reader-translate--as-string' 规范成字符串：
gt 的 translator `text' 槽可能是**分段列表**，直接写进
`seshat-reader-translate-last-result' 会让后续
`seshat-reader-translate-save-as-annotation' 的 `string-trim' 崩溃（同源
第二现场）。

成功分支同时把净化后的文本写入 `seshat-reader-translate--cache'——KEY 取自
`seshat-reader-translate--pending-cache-key'（命令在发起请求前登记，为 nil 时
不写，故 posframe 流式等不经过本函数的路径自然不缓存），写完把该变量清回
nil。"
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
      (let ((clean (seshat-reader-translate--as-string text)))
        (setq seshat-reader-translate-last-result
              (if seshat-reader-translate-strip-chatter
                  (seshat-reader-translate--strip-chatter clean)
                clean))
        ;; 成功即写缓存。KEY 由命令在发起请求前登记到
        ;; `seshat-reader-translate--pending-cache-key'（本函数拿不到请求参数；
        ;; 异步回调场景下动态绑定已出栈，故那条路径用全局变量传递）。写入值取
        ;; 刚写好的 `last-result'，保证「命中缓存看到的内容」与首次请求逐字一
        ;; 致；写完清回 nil，一个 KEY 只被消费一次。
        (when seshat-reader-translate--pending-cache-key
          (puthash seshat-reader-translate--pending-cache-key
                   seshat-reader-translate-last-result
                   seshat-reader-translate--cache)
          (setq seshat-reader-translate--pending-cache-key nil))
        seshat-reader-translate-last-result)))))

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

(defun seshat-reader-translate--stream-wanted-p ()
  "本次请求是否真的为引擎开启流式（`seshat-reader-translate-stream' 之外的第二道判据）.
`seshat-reader-translate-stream' 非 nil，**且**当前渲染方式能承接 gt 的流式
增量时返回 t；否则 nil。

面板（`sidebar' + `seshat-reader-sidebar-enabled'）路径**不能**承接，因此在
那里强制不开启引擎流式。原因是 gt 纯流式的输出链路（实测 gt 2026-10 版，
`gt-core.el' / `gt-render-buffer.el'）：

1. `gt-finalize' 的 `(oref engine stream)' 分支只调 `(gt-output render task)'
   ——**不调** `gt-update'，translator 的 `state' 永远停在 2，`gt-output' 的
   `(= state 3)' 判定因此永不成立，渲染对象的 `:then' 回调（本包创建面板的
   唯一入口 `seshat-reader-translate--panel-result' + `--render-panel'）
   永不触发；
2. task 级 `gt-output' 走 `gt-insert-text-at-marker' 把增量插进 task 的
   markers，**不调**渲染器的 output 函数，因此
   `gt-buffer-render-output'（以及它末尾的
   `(run-hooks \\='gt-buffer-render-output-hook)'）根本不执行——
   `seshat-reader-translate--stream-sync' 挂在该 hook 上，同样永不触发。

面板路径把 gt 的 buffer 以 `(display-buffer-no-window)' 隐藏
（`seshat-reader-translate--render-object'），markers 就在那个隐藏 buffer 里，
于是「增量写进去了但没人看得到，完成时也没有任何回调」——面板既无增量也无
最终渲染，表现为面板不弹出且无报错。故此处对面板路径关掉流式，退回「完成后
一次性渲染」，面板一定出现；posframe 路径（`pop'/`pin'，或 `sidebar' 但面板
被禁用而退回 posframe）的显示 buffer 就是 markers 所在 buffer，增量可见，
维持原有行为。"
  (and seshat-reader-translate-stream
       (not (and (eq seshat-reader-translate-render 'sidebar)
                 seshat-reader-sidebar-enabled))))

(defun seshat-reader-translate--enable-stream (translator)
  "在 TRANSLATOR 的引擎上开启流式，并登记本次请求的 translator 身份.
引擎必须**再克隆一次**：eieio 的 `clone' 是浅拷贝，translator 的 `engines'
槽与预设共享同一批引擎对象，直接 `oset' `stream' 会污染用户在 gt 里的预设
（用户自己的其它 gt 用法会突然变成流式）。

**只有 `delimit' 为 nil 的引擎才开流式**：gt 的 `gt-execute'
（`gt-core.el'）在引擎 `stream' 为 t 时**跳过** `delimit' 决定的 join——
`(when (and delimiter (not (oref engine stream))) (string-join ...))'
——于是引擎拿到的是 translator `text' 槽里的**分段列表**而不是拼接后的
字符串。依赖字符串的引擎（youdao / google / 多数非 LLM 引擎）随即在内部
字符串函数上报 `Wrong type argument: stringp, (\"…\")'（多引擎各报一次）。
判据直接用引擎自己的 `delimit' 槽（gt-engine 基类定义，google / youdao 等
`web-engine' 子类 `:initform t'），与 gt 的 join 决策**同源**，因此不硬编码
引擎类名、新增引擎也自动正确。

不开流式的引擎（`delimit' 非 nil）保持**原对象**：不 clone、不改任何槽，
翻译仍一次性返回。没有 `stream' 槽的引擎（不支持流式）同样保持原样。
返回 TRANSLATOR。"
  (oset translator engines
        (mapcar (lambda (engine)
                  (if (and (slot-exists-p engine 'stream)
                           (null (oref engine delimit)))
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

(defun seshat-reader-translate--panel-context ()
  "返回面板当前承载的语境：`translate' / `explain'，无法判定时 nil.
读的是**面板 buffer** 的 buffer-local
`seshat-reader-translate--panel-context'（`buffer-local-value'），故在阅读
buffer 里调用也成立。面板不存在、或该变量尚未设置（例如面板由旧版代码渲染、
或面板内容已被外部改写）时退回追问状态里的 `:kind'（同一份语境的另一处记录，
见 `--follow-up-reset-state'）；两处都没有则返回 nil——此时两个 toggle 按
「语境不匹配」处理，即重新执行对应命令替换内容，不会误关面板。"
  (let ((buffer (seshat-reader-translate--panel-buffer)))
    (when (buffer-live-p buffer)
      (or (buffer-local-value 'seshat-reader-translate--panel-context buffer)
          (plist-get (buffer-local-value 'seshat-reader-translate--follow-up-state
                                         buffer)
                     :kind)))))

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
    ;; buffer-local 状态（skeleton 标志、正文 marker、面板标题、追问状态）一并清掉。
    (seshat-reader-translate--prepare-view)
    ;; 本路径与 `--render-panel' **不同**：这里没有「显示之后」的
    ;; `seshat-reader-translate--vfcm-refresh'，`(visual-fill-column-mode 1)' 与
    ;; 刷新 hook 都是在 buffer 尚未显示时接线的，首次 margin 可能按
    ;; selected-window（阅读窗口）算出。当前面板渲染**不走流式**
    ;; （`seshat-reader-translate--stream-wanted-p' 对面板路径返回 nil），故本
    ;; 函数对 `sidebar' 渲染不可达；若将来恢复面板流式渲染，必须在此（或显示
    ;; 之后）补一次 `--vfcm-refresh'，否则首次正文宽度会按 selected-window 算错。
    (setq seshat-reader-translate--panel-skeleton t)
    (setq seshat-reader-translate--panel-title title)
    ;; 追问状态同样在此建立：流式骨架路径不经过 `--render-panel'，
    ;; 若只在那里记录，流式场景下追问会因「无状态」而报错。
    (seshat-reader-translate--follow-up-reset-state
     text seshat-reader-translate--stream-langs seshat-reader-translate--stream-context)
    ;; 与 `--render-panel' 同口径：流式骨架路径也要记下语境，否则流式渲染
    ;; 出来的面板在 toggle 眼里「语境未知」，`C-c C-e' 会把译文面板关掉。
    (setq seshat-reader-translate--panel-context
          (if (eq seshat-reader-translate--stream-context 'explain)
              'explain
            'translate))
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
translator state 置 4（整次翻译中止）；流式是增强功能，绝不能因为它让翻译失败。

**当前挂载点不会被触发（gt 侧缺口）**：gt 纯流式下 `gt-finalize' 只调 task 级
`gt-output'（`gt-insert-text-at-marker'），不调渲染器的 output 函数，故
`gt-buffer-render-output-hook' 不会 run；面板路径因此由
`seshat-reader-translate--stream-wanted-p' 直接关掉引擎流式，本函数只在
「渲染方式切到 posframe 类、gt 补上回调」等场景才有机会被调用。保留它是为了
增量实现不随开关一起消失（详见 `--stream-wanted-p' 的文档）。

**追问分支**：当面板 buffer 的追问状态里 `:answer-start' 为真（本轮追问仍在
生成）时，增量改写「当前轮答案区」（`:answer-marker' 之后到 buffer 末尾），
不触碰首轮骨架与此前各轮问答；否则走首轮的骨架 + 正文区逻辑。"
  (ignore-errors
    (when (seshat-reader-translate--stream-active-p)
      (let ((text (car (seshat-reader-translate--extract-result t))))
        (when (and text (not (string-empty-p text)))
          (if (seshat-reader-translate--follow-up-active-p)
              (seshat-reader-translate--follow-up-stream-render text)
            (seshat-reader-translate--stream-render text)))))))

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
      ;; 面板路径不会为引擎开启流式（见 `seshat-reader-translate--stream-wanted-p'），
      ;; 故这个 hook 目前不会被触发；保留挂载是为了让「用户把渲染方式从面板切成
      ;; posframe 再切回」以及 gt 将来补上完成回调时无需再改这段安装逻辑。
      (when seshat-reader-translate-stream
        (seshat-reader-translate--install-stream-hook))
    (seshat-reader-translate--install-capture-hooks)))

;;; 追问（多轮 messages）

(defconst seshat-reader-translate--follow-up-request-prefix
  "请解释下面的文本（讲清含义与用法），不要逐字翻译：\n\n"
  "追问请求里首条 user 消息的引导语，后接原文.
与首轮解释的语义保持一致（首轮由预设的 prompt 模板发出），使多轮上下文里
「assistant 的首轮答案」与「user 的首轮问题」彼此对应。")

(defun seshat-reader-translate--follow-up-message (role content)
  "构造一条 messages 元素：ROLE 为角色符号，CONTENT 为内容字符串.
返回 `((role . ROLE) (content . CONTENT))'——这正是 `gt-chatgpt-send' 在
prompt 为列表时 `,@' 拼进请求体的形态（每一元素即一条 message 对象）。"
  (list (cons 'role role) (cons 'content content)))

(defun seshat-reader-translate--follow-up-messages (source answer turns question limit)
  "构造追问请求的 messages 列表（**不含 system**，system 由引擎的 `root' 槽提供）.
SOURCE 为追问所针对的原文；ANSWER 为首轮解释/译文；TURNS 为已完成的
`(QUESTION . ANSWER)' 历史轮次列表（按时间先后）；QUESTION 为本次追问；
LIMIT 为保留的历史轮数上限（数字，超出时只保留**最近** LIMIT 轮；nil 表示
不限制）。

返回按对话顺序排列的 messages：首轮 user（引导语 + 原文）→ assistant（首轮
答案）→ 历史轮 user/assistant 交替 → 本次 user（QUESTION）。SOURCE 为空
（nil 或全空白）时不生成首轮 user 那条；ANSWER 为空时跳过对应的 assistant
条目；历史轮里问题或答案任一为空时跳过该轮。QUESTION 始终生成（保底），
故返回值至少一条。

本函数是纯函数（只依赖入参、不读 buffer），供
`seshat-reader-translate--follow-up-translator' 里引擎 `prompt' 槽的闭包调用，
ERT 可直接覆盖。"
  (let* ((turns (and (listp turns) turns))
         (turns (cl-remove-if-not
                 (lambda (turn)
                   (and (consp turn)
                        (stringp (car turn))
                        (not (string-empty-p (string-trim (car turn))))
                        (stringp (cdr turn))
                        (not (string-empty-p (string-trim (cdr turn))))))
                 turns))
         (turns (if (and (numberp limit) (> (length turns) limit))
                    (nthcdr (- (length turns) limit) turns)
                  turns))
         (has-source (and (stringp source)
                          (not (string-empty-p (string-trim source)))))
         (has-answer (and (stringp answer)
                          (not (string-empty-p (string-trim answer)))))
         (messages nil))
    (when has-source
      (push (seshat-reader-translate--follow-up-message
             'user (concat seshat-reader-translate--follow-up-request-prefix source))
            messages))
    (when (and has-source has-answer)
      (push (seshat-reader-translate--follow-up-message 'assistant answer) messages))
    (dolist (turn turns)
      (push (seshat-reader-translate--follow-up-message 'user (car turn)) messages)
      (push (seshat-reader-translate--follow-up-message 'assistant (cdr turn)) messages))
    (push (seshat-reader-translate--follow-up-message 'user (or question "")) messages)
    (nreverse messages)))

(defun seshat-reader-translate--follow-up-reset-state (answer langs context)
  "在**当前（面板）buffer** 重置追问状态，ANSWER 为首轮答案、LANGS 为语言对.
CONTEXT 取 `explain' 时 `:kind' 记为 `explain'，其余记为 `translate'（决定
追问复用哪个预设）。`:source' 取当前选区原文
（`seshat-reader-translate--selection-source-text'，无选区时为 nil），
轮次与答案区标记全部清空。

新一次翻译/解释开始时调用（`--render-panel' 的非流式路径与 `--stream-init'
的流式路径都要调）。**必须在切换 major mode 之后调用**：`--prepare-view' 会
`kill-all-local-variables'，把 buffer-local 状态一并清掉。"
  (setq seshat-reader-translate--follow-up-state
        (list :source (seshat-reader-translate--selection-source-text)
              :answer answer
              :langs langs
              :kind (if (eq context 'explain) 'explain 'translate)
              :round 0
              :turns nil
              :answer-marker nil
              :answer-start nil)))

(defun seshat-reader-translate--follow-up-update-answer (answer)
  "把面板 buffer 追问状态里的首轮答案补写为 ANSWER（最终文本）.
流式骨架建立时只记下了当时的**部分**增量文本，完成后再以此函数补成完整
答案，否则后续追问的 assistant 上下文会缺一截。ANSWER 非 nil、面板存在、
状态存在且当前没有进行中的追问轮次时才写。"
  (let ((panel (seshat-reader-translate--panel-buffer)))
    (when (and answer (buffer-live-p panel))
      (with-current-buffer panel
        (when (and seshat-reader-translate--follow-up-state
                   (not (plist-get seshat-reader-translate--follow-up-state :answer-start)))
          (setq seshat-reader-translate--follow-up-state
                (plist-put seshat-reader-translate--follow-up-state :answer answer)))))))

(defun seshat-reader-translate--follow-up-active-p ()
  "面板 buffer 的追问状态是否处于「本轮答案仍在生成」.
读取面板 buffer 的 buffer-local 状态（`--stream-sync' 执行在中转 buffer 内，
不能直接读局部变量），状态缺失或 `:answer-start' 为 nil 时返回 nil。"
  (let ((panel (seshat-reader-translate--panel-buffer)))
    (and (buffer-live-p panel)
         (plist-get (buffer-local-value 'seshat-reader-translate--follow-up-state panel)
                    :answer-start)
         t)))

(defun seshat-reader-translate--follow-up-trim (turns)
  "把历史轮次 TURNS 裁剪到最近 `seshat-reader-translate-follow-up-max-rounds' 轮.
首轮的原文与首轮解释不属于 TURNS，故裁剪不会丢掉追问的讨论对象。TURNS 为
nil 或轮数未超限时原样返回。"
  (let ((turns (ensure-list turns))
        (limit seshat-reader-translate-follow-up-max-rounds))
    (if (and (numberp limit) (> (length turns) limit))
        (nthcdr (- (length turns) limit) turns)
      turns)))

(defun seshat-reader-translate--chatgpt-engine-p (engine)
  "ENGINE 是否为 go-translate 的对话式 ChatGPT 引擎实例.
只有 `gt-chatgpt-engine' 及其子类支持 messages 多轮（它的 `gt-execute' 对
函数型 `prompt' 走 `pdd-funcall' 并把返回值当 messages 发送）。ENGINE 不是
eieio 对象时返回 nil，不报错。"
  (and (eieio-object-p engine)
       (object-of-class-p engine 'gt-chatgpt-engine)))

(defun seshat-reader-translate--preset-chatgpt-engine (preset)
  "返回 PRESET 预设翻译器中的第一个 ChatGPT 引擎**原对象**，没有则 nil.
PRESET 先查 `seshat-reader-translate-presets'，未命中再查
`gt-preset-translators'（见 `seshat-reader-translate--preset-translator'）。
预设缺失、或其中只有 youdao/google 这类纯翻译引擎时返回 nil——调用方据此
报 `user-error'（**不做文本拼接降级**：翻译引擎没有对话语义，降级只会产出
误导性答案）。返回的是预设里的原对象，调用方必须 `clone' 后再改槽。"
  (when-let* ((trans (seshat-reader-translate--preset-translator preset)))
    (cl-find-if #'seshat-reader-translate--chatgpt-engine-p
                (ensure-list (gt-ensure-plain (oref trans engines))))))

(defun seshat-reader-translate--follow-up-quote (text)
  "把追问 TEXT 转成 Markdown 引用块（每行加 `> ' 前缀）.
与首轮原文引用块（`seshat-reader-translate--quote-block'）同风格，只是不带
`> **原文**' 那一行标签：追问的问题本身就是正文，不需要额外标签。多行问题逐行
加前缀，空行变成单独的 `>'（Markdown 引用块内的段落分隔，与首轮原文引用块的
`>' 空引用行同形态，不留行尾空白——面板不折行，行尾空白会被横向溢出）。TEXT
先经 `seshat-reader-translate--as-string' 规范成字符串（gt 的 taker `text'
槽可能是分段列表）。"
  (mapconcat (lambda (line)
               (if (string-empty-p (string-trim line))
                   ">"
                 (concat "> " line)))
             (split-string (seshat-reader-translate--as-string text) "\n")
             "\n"))

(defun seshat-reader-translate--follow-up-append-round (panel question)
  "在面板 buffer PANEL 末尾追加本轮追问的问题区，返回答案区起点 marker.
QUESTION 为问题原文，经 `--follow-up-quote' 转成引用块。追加的文本为 `---'
分隔线 + 问题引用块 + 一个空行：**不再**写「### 追问 N」「**问：**」
「**答：**」三种标签——轮次序号只留在 header-line（它是状态不是正文），标签行
在窄面板里还会横向溢出。分隔线同时充当「首轮答案 → 第 1 轮追问」与
「此前各轮 → 本轮」的边界。

返回的 marker 指向引用块之后的空行之后，即答案区起点；最终答案只替换它之后到
buffer 末尾的内容（`copy-marker' 用默认插入类型，在 marker 处插入的文本落在
marker 之后）。"
  (with-current-buffer panel
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "\n---\n\n"
              (seshat-reader-translate--follow-up-quote question)
              "\n\n")
      (copy-marker (point)))))

(defun seshat-reader-translate--follow-up-translator (panel question state engine)
  "构造本轮追问的 gt translator（PANEL 面板、QUESTION 问题、STATE 状态、ENGINE 引擎）.
taker 用 `(gt-taker :text QUESTION :pick nil :langs LANGS)'（`LANGS' 取自
STATE）；引擎克隆自 ENGINE 后构造，保证不改用户预设单例。渲染对象
`gt-buffer-render' 指向**独立**隐藏中转 buffer
（`seshat-reader-translate--follow-up-buffer-name'），`:dislike-header' /
`:dislike-source' 为 t（面板已有标题与原文，中转 buffer 不需要重复），
`:then' 在完成时调 `seshat-reader-translate--follow-up-complete'。

引擎克隆体的 `stream' 槽**恒为 nil**：追问的答案只能经 `:then' 写进面板，
而 gt 的流式链路不触发 `:then'（详见函数内注释与
`seshat-reader-translate--stream-wanted-p'）。"
  (let* ((source (plist-get state :source))
         (answer (plist-get state :answer))
         (turns (plist-get state :turns))
         (langs (plist-get state :langs))
         (limit seshat-reader-translate-follow-up-max-rounds)
         (engine-copy (clone engine)))
    ;; HACK: 把引擎的 `prompt' 槽换成「返回 messages 列表的函数」来绕过 gt 默认
    ;; 的单轮 prompt 构造。gt 的 `gt-execute' 对函数型 `prompt' 执行
    ;; `(pdd-funcall prompt (list item tgt))'，而 `gt-chatgpt-send' 在 prompt 为
    ;; 列表时把它当 `messages' 数组发送。故这里忽略 gt 传入的 item/tgt，直接
    ;; 返回按状态拼好的多轮对话——不改 gt 源码、不自行拼 JSON 请求体。
    ;; 若 gt 升级后改变函数型 prompt 的调用约定或 messages 形态，这里会退化为
    ;; 「消息体不对」，但不会影响首轮翻译/解释（走的是另一条路径）。
    (oset engine-copy prompt
          (lambda (_text _lang)
            (seshat-reader-translate--follow-up-messages
             source answer turns question limit)))
    ;; 追问**恒不**为引擎开启流式，与 `seshat-reader-translate-stream' 无关。
    ;; 原因：面板路径下 gt 的纯流式链路（实测 gt 2026-10 版 `gt-core.el'）
    ;; `gt-finalize' 只调 task 级 `gt-output'（把增量写进中转 buffer 的 marker），
    ;; **不调** `gt-update'，也不调渲染器的 output 函数——于是渲染对象的
    ;; `:then' 永不触发（详见 `seshat-reader-translate--stream-wanted-p' 的文档）。
    ;; 而追问把答案写进面板的**唯一**通路就是 `:then'
    ;; （`seshat-reader-translate--follow-up-complete'），中转 buffer
    ;; （`seshat-reader-translate--follow-up-buffer-name'）又是隐藏的——开着流式
    ;; 就只剩「模型答案写进没人看得到的 buffer，面板答案区永远空白、header 卡在
    ;; 『生成中…』」。故此处必须显式置 nil，不能沿用首轮的
    ;; `seshat-reader-translate-stream' 开关。
    (oset engine-copy stream nil)
    ;; `:window-config' 只挡 `gt-init' 那一次显示，完成时 gt 还会再
    ;; `display-buffer' 一次（见 `--ensure-hidden-gt-buffers'），故这里补登记
    ;; 隐藏规则——否则答案到达的瞬间中转 buffer 会被弹出来挤占阅读窗口。
    (seshat-reader-translate--ensure-hidden-gt-buffers)
    (gt-translator
     :engines (list engine-copy)
     :taker (gt-taker :text question :pick nil :langs langs)
     :render
     (gt-buffer-render
      :name seshat-reader-translate--follow-up-buffer-name
      :window-config '((display-buffer-no-window) (allow-no-window . t))
      :dislike-header t
      :dislike-source t
      :then (lambda (&rest _args)
              (seshat-reader-translate--follow-up-complete panel question))))))

(defun seshat-reader-translate--follow-up-start (panel question state engine)
  "在面板 PANEL 追加一轮追问（问题 QUESTION，当前状态 STATE）并启动 gt 请求.
ENGINE 为预设里的 ChatGPT 引擎（`--follow-up-translator' 会克隆它）。返回
登记好的 translator。

步骤：先在面板末尾追加问题区（`---' 分隔线 + 问题引用块，拿到答案区
marker），再更新状态（`:round' 自增、`:answer-marker'、`:answer-start' 置真）
与 header-line（「追问 N 生成中…」），最后登记
`seshat-reader-translate--current-translator'（复用 `--stream-sync' 的身份
守卫）与 `seshat-reader-translate--active'（时间窗守卫）并 `gt-start'。
追问的引擎不开流式（见 `--follow-up-translator'），答案由 `:then' 回调
`seshat-reader-translate--follow-up-complete' 一次性写入。"
  (let* ((round (1+ (or (plist-get state :round) 0)))
         (marker (seshat-reader-translate--follow-up-append-round
                  panel question))
         (trans (seshat-reader-translate--follow-up-translator
                 panel question state engine)))
    (with-current-buffer panel
      (setq seshat-reader-translate--follow-up-state
            (plist-put (plist-put state :round round)
                       :answer-marker marker))
      (setq seshat-reader-translate--follow-up-state
            (plist-put seshat-reader-translate--follow-up-state :answer-start t))
      (setq-local header-line-format
                  (concat (or seshat-reader-translate--panel-title "Seshat 解释")
                          (format "（追问 %d 生成中…）" round))))
    (setq seshat-reader-translate--current-translator trans)
    (setq seshat-reader-translate--active (float-time))
    (seshat-reader-translate--install-capture-hook-for-mode)
    (gt-start trans)
    trans))

(defun seshat-reader-translate--follow-up-stream-render (text)
  "把追问增量 TEXT 写进面板的当前轮答案区（`:answer-marker' 之后到 buffer 末尾）.
只替换答案区：首轮骨架、原文引用块与**此前各轮**问答都不动。`TEXT' 是 gt 每次
输出时的**全量快照**（该引擎把增量拼在 `res' 上整体重发），故直接整块替换
即可，不需要自行做差异合并。答案区里只有答案正文——问题以引用块写在
`:answer-marker' 之前，本轮不带「问：」「答：」标签。滚动跟随条件与首轮一致
（`seshat-reader-panel-follow-bottom' + 写入前判定窗口是否停在底部 + 节流）。

**当前无调用路径**：追问的引擎恒不开流式（见
`seshat-reader-translate--follow-up-translator'），而 gt 的流式链路又不调渲染器
的 output 函数（`gt-buffer-render-output-hook' 不 run），故 `--stream-sync' 的
追问分支拿不到调用者。保留它是为了「gt 补上流式完成/增量回调」后增量实现不
必从零重写；届时需同时打开 `--follow-up-translator' 里的 `stream' 开关。"
  (let* ((panel (seshat-reader-translate--panel-buffer)))
    (when (buffer-live-p panel)
      (let* ((window (seshat-reader-translate--panel-display-window panel))
             (tailing (and window
                           (seshat-reader-translate--panel-tailing-p window panel))))
        (with-current-buffer panel
          (let ((inhibit-read-only t)
                (marker (plist-get seshat-reader-translate--follow-up-state
                                   :answer-marker)))
            (when (and (markerp marker) (marker-position marker))
              (save-excursion
                (goto-char marker)
                (delete-region (point) (point-max))
                (insert text)
                (unless (string-suffix-p "\n" text)
                  (insert "\n"))))))
        (when (and seshat-reader-panel-follow-bottom
                   tailing
                   window
                   (seshat-reader-translate--stream-scroll-due-p))
          (seshat-reader-translate--panel-scroll-to-bottom window panel))))))

(defun seshat-reader-translate--follow-up-complete (panel question)
  "追问完成回调：把最终答案写进面板 PANEL、更新状态、记录结果，返回答案文本.
从追问的隐藏中转 buffer（`--follow-up-buffer-name'）取最终答案（SKIP-LOADING
过滤掉尚未产出的占位），替换 `:answer-marker' 之后到 buffer 末尾的答案区
（问题以引用块写在前面，答案正文直接接在空行之后，不带任何标签）；
随后把 QUESTION 与本轮答案追加进 `:turns'（并按
`seshat-reader-translate-follow-up-max-rounds' 裁剪）、`:answer-start' 与
`:answer-marker' 置 nil、header-line 改成「已完成 · N 轮追问」（N 取自状态
里的 `:round'，不依赖闭包捕获）。

取不到答案（请求失败、中转 buffer 不存在或内容仍全是 `Loading...'）时不改
面板内容、不追加轮次，但**必须**把 `:answer-start' / `:answer-marker' 清空
并把 header-line 改成「追问 N 失败」——否则面板永久停在「生成中…」，下一轮
追问也会被当成「上一轮仍在生成」。成功时把**整面板纯文本**交给
`seshat-reader-translate--record-result'（存批注语义：批注要保存的是整段
对话，而非孤立的一轮答案）。

本函数是 gt 渲染对象 `:then' 的唯一入口（`pdd' 回调），**任何异常都不许外泄**
（外泄会被 gt 的 `gt-output :around' 捕获并把 translator state 置 4，面板同样
停在生成中且无提示），故取答案、更新面板、记录结果三段各自 `condition-case'
+ `message'。执行顺序保证「清 translator 登记」永远发生（迟到增量不再误写）。"
  (let ((answer nil))
    (condition-case err
        (let ((gt-buffer (get-buffer
                          seshat-reader-translate--follow-up-buffer-name)))
          (when (buffer-live-p gt-buffer)
            (with-current-buffer gt-buffer
              (setq answer (car (seshat-reader-translate--extract-result t))))))
      (error (message "Seshat Reader translate: 追问取答案失败（%s）"
                      (error-message-string err))))
    (when (buffer-live-p panel)
      (condition-case err
          (with-current-buffer panel
            (let* ((state seshat-reader-translate--follow-up-state)
                   (round (or (plist-get state :round) 1))
                   (marker (plist-get state :answer-marker))
                   (turns (plist-get state :turns)))
              (when (and answer (markerp marker) (marker-position marker))
                (let ((inhibit-read-only t))
                  (save-excursion
                    (goto-char marker)
                    (delete-region (point) (point-max))
                    (insert answer)
                    (unless (string-suffix-p "\n" answer)
                      (insert "\n"))))
                (setq turns (append (ensure-list turns)
                                    (list (cons question answer)))))
              (when (markerp marker) (set-marker marker nil))
              (setq seshat-reader-translate--follow-up-state
                    (list :source (plist-get state :source)
                          :answer (plist-get state :answer)
                          :langs (plist-get state :langs)
                          :kind (plist-get state :kind)
                          :round round
                          :turns (seshat-reader-translate--follow-up-trim turns)
                          :answer-marker nil
                          :answer-start nil))
              (setq-local header-line-format
                          (concat (or seshat-reader-translate--panel-title
                                      "Seshat 解释")
                                  (if answer
                                      (format "（已完成 · %d 轮追问）" round)
                                    (format "（追问 %d 失败）" round))))))
        (error (message "Seshat Reader translate: 追问面板更新失败（%s）"
                        (error-message-string err)))))
    ;; 本轮已结束：清掉 translator 登记，防止 gt 在收尾后再次输出增量时
    ;; `--stream-sync' 误把追问答案写进首轮正文区。
    (setq seshat-reader-translate--current-translator nil)
    (if answer
        (condition-case err
            (when (buffer-live-p panel)
              (seshat-reader-translate--record-result
               (cons (with-current-buffer panel
                       (buffer-substring-no-properties (point-min) (point-max)))
                     nil)))
          (error (message "Seshat Reader translate: 追问结果记录失败（%s）"
                          (error-message-string err))))
      (message "Seshat Reader translate: 追问失败（未取到答案），面板保留问题块；可重试一次"))
    answer))

(defun seshat-reader-translate-follow-up (question)
  "针对当前译文/解释面板的原文继续追问，QUESTION 为本轮问题.
追问复用面板记录的首轮原文与首轮答案，并把最近
`seshat-reader-translate-follow-up-max-rounds' 轮问答一起作为 messages 发送
（组装见 `seshat-reader-translate--follow-up-messages'），答案追加到面板：
问题写成 Markdown 引用块（每行 `> ` 前缀），空行之后直出答案正文，轮次之间
用 `---' 分隔线分隔；轮次序号只显示在 header-line（「追问 N 生成中…」→
「已完成 · N 轮追问」）。追问**不走流式**（原因见
`seshat-reader-translate--follow-up-translator'），答案在 `:then' 回调里一次
写入面板。

前置条件缺失时一律 `user-error' 并说明原因：面板未打开、面板尚无首轮结果
（`:source' 缺失）、问题为空、或预设里的引擎不是 `gt-chatgpt-engine'
（youdao/google 等纯翻译引擎没有对话语义，**不做文本拼接降级**，只提示把
`seshat-reader-translate-preset' / `seshat-reader-translate-explain-preset'
配成 ChatGPT 预设）。

交互调用时在迷你缓冲区输入问题（阅读器键位表 `seshat-reader-mode-map` 与面板
键位表 `seshat-reader-translate-panel-map' 都绑定了本命令）。"
  (interactive (list (read-string "追问: ")))
  (let ((question (and (stringp question) (string-trim question))))
    (when (or (null question) (string-empty-p question))
      (user-error "Seshat Reader translate: 追问内容为空，已取消"))
    (let ((panel (seshat-reader-translate--panel-buffer)))
      (unless (buffer-live-p panel)
        (user-error "Seshat Reader translate: 译文/解释面板未打开，请先翻译或解释选区再追问"))
      (let ((state (buffer-local-value 'seshat-reader-translate--follow-up-state panel)))
        (unless state
          (user-error "Seshat Reader translate: 面板里还没有解释/翻译结果，无法追问"))
        (let ((source (plist-get state :source)))
          (unless (and (stringp source)
                       (not (string-empty-p (string-trim source))))
            (user-error "Seshat Reader translate: 面板未记录原文，无法追问（请重新选中原文后再解释）"))
          (seshat-reader-translate--ensure-gt)
          (let* ((explain (eq (plist-get state :kind) 'explain))
                 (preset (if explain
                             seshat-reader-translate-explain-preset
                           seshat-reader-translate-preset))
                 (engine (seshat-reader-translate--preset-chatgpt-engine preset)))
            (unless engine
              (user-error
               "Seshat Reader translate: 当前预设引擎不支持多轮追问（需要 gt-chatgpt-engine 预设），请把 `%s' 配成基于 gt-chatgpt-engine 的预设"
               (if explain
                   "seshat-reader-translate-explain-preset"
                 "seshat-reader-translate-preset")))
            (seshat-reader-translate--follow-up-start
             panel question state engine)))))))

;;; 交互式命令

(defun seshat-reader-translate-selection (&optional target-lang force)
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
错误文案形如 `翻译失败（模型 @ 主机）：<原因>'——引擎标识取
`seshat-reader-translate--engine-label'，只含模型名与主机名，不含任何
凭据。

本命令在启动翻译前会把 `seshat-reader-translate-last-result' 清为 nil，
并记录启动时间到 `seshat-reader-translate--active'，以启用
`seshat-reader-translate--capture-result' 的捕获窗口守卫（避免旧译文被
误存，也避免其它 go-translate 用法污染结果）。

翻译路径不做长度截断（选区通常只有几个词）；解释路径的长度护栏见
`seshat-reader-translate-explain-selection'。

**缓存**：`(translate 预设 语言 选区原文)' 命中
`seshat-reader-translate--cache' 时**不发起请求**——直接把缓存结果写进
`seshat-reader-translate-last-result' 并按原模板重绘面板，回显
「使用缓存结果（`C-u' 重新生成）」。FORCE 非 nil（`C-u' 前缀）时跳过缓存、照常
请求；`C-u' 同时仍会读目标语言（既有行为不变）。"
  (interactive (list (when current-prefix-arg (read-string "目标语言: "))
                     current-prefix-arg))
  (let* ((text (seshat-reader-translate--selection-text))
         (langs (if (and (stringp target-lang)
                         (not (string-empty-p (string-trim target-lang))))
                    (seshat-reader-translate--target-langs target-lang)
                  seshat-reader-translate-fallback-langs))
         ;; 缓存键把「预设 + 语言对 + **送给模型的文本**」一起纳入：预设换了、
         ;; 目标语言换了都算不同条目；译文路径送模型的就是纯选区，故文本相同即
         ;; 内容相同。
         (key (seshat-reader-translate--cache-key
               'translate seshat-reader-translate-preset langs text))
         (cached (and (not force)
                      (gethash key seshat-reader-translate--cache))))
    (if cached
        ;; 命中：只重绘，不碰 translator、不启动 gt、不更新捕获时间戳（没有请求
        ;; 需要被捕获），因此 `--capture-result' 的窗口守卫也不会被这次操作打开。
        (progn
          (setq seshat-reader-translate-last-result cached)
          (seshat-reader-translate--render-panel
           cached (seshat-reader-translate--title 'translate) langs 'translate)
          (message "Seshat Reader translate: 使用缓存结果（C-u 重新生成）"))
      ;; 未命中：照原路请求。缓存写入的 KEY 不在命令里登记——它由
      ;; `--translator' 用同一个构造函数算出、随渲染对象交给 `:then' 回调，在
      ;; 回调内动态绑定 `--pending-cache-key'（见 `--render-object'）。
      ;; `trans' 在 `condition-case' 之外绑定：错误分支要靠它取引擎标识
      ;; （见 `seshat-reader-translate--engine-label'），绑定在受保护体内部
      ;; 的 `let' 里时 handler 看不到。
      (let (trans)
        (condition-case err
            (progn
              (setq trans (seshat-reader-translate--translator
                           seshat-reader-translate-preset text langs 'translate))
              (seshat-reader-translate--install-capture-hook-for-mode)
              (setq seshat-reader-translate-last-result nil)
              (setq seshat-reader-translate--active (float-time))
              (gt-start trans))
          (user-error
           (signal (car err) (cdr err)))
          (error
           (message "Seshat Reader translate: 翻译失败%s：%s"
                    (if trans (seshat-reader-translate--engine-label trans) "")
                    (error-message-string err))))))))

(defun seshat-reader-translate-explain-selection (&optional target-lang force)
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
错误捕获后 `message'，文案形如 `解释失败（模型 @ 主机）：<原因>'
（引擎标识见 `seshat-reader-translate--engine-label'，不含凭据）。本命令
同样会在启动前清空 `seshat-reader-translate-last-result' 并记录启动时间到
`seshat-reader-translate--active'（预设缺失时按 `explain' 语境提示回退
为普通翻译）。

解释的输入是「上下文 + 原文 + 指令」的**装配串**（由
`seshat-reader-translate--explain-request-text' 与
`seshat-reader-translate-explain-prompt' 生成），经
`seshat-reader-translate--translator' 的第 5 参（REQUEST-TEXT）只填进
taker 的 `:text'；面板原文引用块（`%q'）与 `last-result' 语义不变，仍取
纯选区。上下文取不到（无动态模块、无 `:rect'、结果为空）时静默退化为
「原文 + 指令」；把 `seshat-reader-translate-explain-prompt' 设为 nil 则
退回纯选区（旧行为），同时**跳过上下文提取**（不装配就用不上它）。
上下文提取在 `condition-case' 之外执行：它自身静默降级，不该被「解释
失败」捕获后误报。

长度护栏：装配前先用 `seshat-reader-translate--truncate-selection' 按
`seshat-reader-translate-explain-max-chars' 截断**送模型的选区原文**，
超限时尾部追加「（选区过长，以上为节选）」；面板引用块与追问来源仍取
完整选区文本。

**缓存**：键为 `(explain 预设 语言 REQUEST-TEXT)'，其中 REQUEST-TEXT 就是装配
好的「上下文 + 原文 + 指令」串——因此**同一段原文在不同上下文（不同页 / 邻近
文字不同）下是两个条目**，不会把上一处的解释套到这一处。命中时照
`seshat-reader-translate-selection' 的做法直接重绘面板并提示「使用缓存结果」，
不发请求；FORCE 非 nil（`C-u' 前缀）跳过命中、强制重新生成。"
  (interactive (list (when current-prefix-arg (read-string "目标语言: "))
                     current-prefix-arg))
  (let* ((text (seshat-reader-translate--selection-text))
         (langs (if (and (stringp target-lang)
                         (not (string-empty-p (string-trim target-lang))))
                    (seshat-reader-translate--target-langs target-lang)
                  seshat-reader-translate-fallback-langs))
         ;; 送模型的是**截断后**的 `send-text'（长度护栏见
         ;; `seshat-reader-translate-explain-max-chars'）；`text' 未截断，
         ;; 仍供面板 `%q'、`last-result' 语义与追问来源使用。
         (send-text (seshat-reader-translate--truncate-selection text))
         ;; 上下文提取失败一律静默（见 `seshat-reader-translate--context-text'），
         ;; 故放在 `condition-case' 之外：不让「解释失败」把它一并报出。
         ;; 模板为 nil 时不装配 prompt，也就不需要上下文——省掉一次整页文本
         ;; 提取（每次都要走动态模块）。
         (context-text (when seshat-reader-translate-explain-prompt
                         (seshat-reader-translate--context-text)))
         (request-text (seshat-reader-translate--explain-request-text
                        send-text context-text
                        (seshat-reader-translate--document-title)
                        langs))
         ;; 键里的 REQUEST-TEXT 已含上下文，故上下文不同即不同条目。
         (key (seshat-reader-translate--cache-key
               'explain seshat-reader-translate-explain-preset
               langs request-text))
         (cached (and (not force)
                      (gethash key seshat-reader-translate--cache))))
    (if cached
        ;; 命中：与译文路径同构——只重绘，不发请求、不动捕获时间戳。
        (progn
          (setq seshat-reader-translate-last-result cached)
          (seshat-reader-translate--render-panel
           cached (seshat-reader-translate--title 'explain) langs 'explain)
          (message "Seshat Reader translate: 使用缓存结果（C-u 重新生成）"))
      ;; 未命中：照原路请求；缓存 KEY 由 `--translator' 用同一个构造函数算出,
      ;; 随渲染对象交给 `:then' 回调（见 `--render-object'）。
      ;; `trans' 在 `condition-case' 之外绑定：错误分支要靠它取引擎标识
      ;; （见 `seshat-reader-translate--engine-label'），绑定在受保护体内部
      ;; 的 `let' 里时 handler 看不到。
      (let (trans)
        (condition-case err
            (progn
              (setq trans (seshat-reader-translate--translator
                           seshat-reader-translate-explain-preset text langs 'explain
                           request-text))
              (seshat-reader-translate--install-capture-hook-for-mode)
              (setq seshat-reader-translate-last-result nil)
              (setq seshat-reader-translate--active (float-time))
              (gt-start trans))
          (user-error
           (signal (car err) (cdr err)))
          (error
           (message "Seshat Reader translate: 解释失败%s：%s"
                    (if trans (seshat-reader-translate--engine-label trans) "")
                    (error-message-string err))))))))

(defun seshat-reader-translate-clear-cache ()
  "清空翻译/解释的结果缓存（`seshat-reader-translate--cache'）.
缓存只在**本会话内存**里：容量随「用过的原文 × 语言对 × 预设」增长，完全不
落盘，重启 Emacs 自然清空。本命令用于会话内主动释放——例如改了预设的 prompt
或换了模型之后，想立刻丢掉旧结果重新生成，又不想退出 Emacs。

清空后所有请求都回到「重新请求」路径（`C-u' 强制重算因此不再必要）。只影响
缓存，不动 `seshat-reader-translate-last-result' 与已显示的面板内容。"
  (interactive)
  (clrhash seshat-reader-translate--cache)
  (message "Seshat Reader translate: 翻译/解释缓存已清空"))

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

;;; per-kind 开合（语境匹配才关闭，否则照常翻译/解释并替换面板内容）

;; 两个 `-toggle' 包装是 `C-c C-t' / `C-c C-e' 的新落点：阅读界面里同一组键
;; 既要能「开」也要能「关」。关面板的其它途径都不顺手——面板内 `q'
;; （`seshat-reader-translate-panel-map'）要求光标已在面板里，而阅读窗口里的 `q'
;; 走 `seshat-reader-sidebar-quit' 的退回分支会关掉**全部**面板；`M-o'
;; （`seshat-reader-sidebar-toggle'）同样是全部开关。原命令
;; （`seshat-reader-translate-selection' / `-explain-selection'）**保留不变**，
;; 脚本化调用（`M-x'、用户配置里的 `define-key'）语义不受影响，永远执行翻译。
;;
;; **语境一一对应**（2026-10-26）：译文与解释共用同一个面板 buffer 与同一个
;; kind（`translate'），早期两键都只判 `panel-visible-p'，于是「面板已显示」就
;; 一律关闭——面板里是译文时按 `C-c C-e' 会把面板关掉，得再按一次才出解释。
;; 现在两键都要求「已显示 **且** 面板语境匹配」
;; （`seshat-reader-translate--panel-context'），不匹配则重新执行对应命令覆
;; 盖内容：译文 ↦ `C-c C-e' 换解释、解释 ↦ `C-c C-t' 换译文，各按一次即到。

(defun seshat-reader-translate-toggle (&optional target-lang force)
  "译文面板开合：面板显示的是**译文**则关闭，否则生成译文（替换现有内容）.
「显示的是译文」= `seshat-reader-sidebar-panel-visible-p' 判为已显示 **且**
`seshat-reader-translate--panel-context' 为 `translate'。只判前者不够：译文与
解释共用同一个面板 buffer 与同一个 kind（`translate'），面板里放的是解释时
前者同样为真，若照旧关闭，想「换成译文」就会变成「先关面板再按一次」——两个
toggle 必须与语境一一对应。

关闭走 `seshat-reader-sidebar--toggle-kind'——只关 `translate' 这一 kind，
批注列表与目录面板不受影响，且关闭前捕获尺寸、记住 buffer 供 `M-o' 重开。
语境不匹配（或面板未显示）时原样调用
`seshat-reader-translate-selection'（TARGET-LANG 与 FORCE 语义都与它完全
一致，`C-u' 前缀参数既读目标语言也强制重新生成、跳过缓存），新结果覆盖面板
现有内容。

渲染方式取 `pop' / `pin'（posframe）时面板不是承载单元，本命令恒判「未显示」
→ 行为与原命令一致（每次都翻译），无需特判。"
  (interactive (list (when current-prefix-arg (read-string "目标语言: "))
                     current-prefix-arg))
  (if (and (seshat-reader-sidebar-panel-visible-p 'translate)
           (eq (seshat-reader-translate--panel-context) 'translate))
      (seshat-reader-sidebar--toggle-kind 'translate)
    (seshat-reader-translate-selection target-lang force)))

(defun seshat-reader-translate-explain-toggle (&optional target-lang force)
  "解释面板开合：面板显示的是**解释**则关闭，否则生成解释（替换现有内容）.
TARGET-LANG 与 FORCE 语义与 `seshat-reader-translate-toggle' 完全相同（`C-u'
前缀参数既读目标语言也强制重新生成）。与它同构，区别在语境判据：只在面板
**已经显示解释**时关闭，面板显示译文时按本键是「换成解释」（调
`seshat-reader-translate-explain-selection' 覆盖面板内容），反之亦然——两个
键因此与语境一一对应，不再互相误关。"
  (interactive (list (when current-prefix-arg (read-string "目标语言: "))
                     current-prefix-arg))
  (if (and (seshat-reader-sidebar-panel-visible-p 'translate)
           (eq (seshat-reader-translate--panel-context) 'explain))
      (seshat-reader-sidebar--toggle-kind 'translate)
    (seshat-reader-translate-explain-selection target-lang force)))

;;; 键位

(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-c C-t")
    #'seshat-reader-translate-toggle)
  (define-key seshat-reader-mode-map (kbd "C-c C-e")
    #'seshat-reader-translate-explain-toggle)
  ;; 追问：`C-c C-a' 已被 `seshat-reader-annotation-create' 占用，故用 C-c C-q。
  (define-key seshat-reader-mode-map (kbd "C-c C-q")
    #'seshat-reader-translate-follow-up)
  ;; 单键快捷（阅读 buffer 里 evil 已被关闭，`t' / `e' 不会被 normal state 抢走）：
  ;; 与 `C-c C-t' / `C-c C-e' 双绑，保持既有前缀绑定不变。
  (define-key seshat-reader-mode-map (kbd "t")
    #'seshat-reader-translate-toggle)
  (define-key seshat-reader-mode-map (kbd "e")
    #'seshat-reader-translate-explain-toggle))

(provide 'seshat-reader-translate)
;;; seshat-reader-translate.el ends here
