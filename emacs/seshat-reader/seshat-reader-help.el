;;; seshat-reader-help.el --- 阅读器内置帮助页  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, files, tools
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

;; 阅读器的内置帮助页：`seshat-reader-help' 生成/复用只读 buffer
;; `*Seshat Reader Help*'（`special-mode'，`q' 关闭本页），把「阅读 buffer 的
;; 键位 + 面板内键位 + 功能简介 + 面板行为」整理成一页。
;;
;; **键位一律取自运行时**：每行键位都由 `substitute-command-keys' 解析
;; `\\[命令]' 形态得到，**不**手写键位字符串。这样用户改过键位、或某个命令被
;; 本包升级换到别的键上时，帮助页自动跟着变，不会出现「文档说 C-c C-t、实际按
;; 下去没反应」的漂移。实现要点：`\\[命令]' 解析的是**当前 buffer 的活跃
;; keymap**，故每一段都在临时 buffer 里把目标 keymap 装成 local map 之后再解析
;; （`seshat-reader-help--key-text'），否则从帮助页 buffer 里解析只会落回
;; `special-mode-map' / 全局表，所有本包命令都被显示成 `M-x 命令名'。
;;
;; **未加载的命令写占位**：本包的扩展模块（目录、搜索、批注、译文）都是按需
;; 加载的，命令尚未定义时键位也没有注册，此时该行显示「（未加载）」而不是编造
;; 一个键位。在会话里用过对应功能后重开本页，该行就变成真实键位。
;;
;; 本文件只在**渲染时**读 keymap 与 `fboundp'，不 require 任何本项目模块
;; （与 `seshat-reader-sidebar' 同一条边界），故加载它不会把 C 模块或批注 /
;; 译文栈一并拉进来。
;;
;; 键位注册走 `with-eval-after-load 'seshat-reader`：本模块不 require 阅读器
;; （避免循环依赖），只在阅读器加载完成后往 `seshat-reader-mode-map' 补 `?'。
;; 因此配置里需要 `(require 'seshat-reader-help nil t)' 才会生效，见
;; `docs/emacs-reader.md' 的「安装与加载」。

;;; Code:

;; 本模块零依赖，但渲染与键位注册都要用到这两个 keymap。声明只为消除字节编译
;; 的「reference to free variable」告警；运行时由各自模块定义，未加载时按 nil
;; 处理（`seshat-reader-help--key-text' 会退化为解析全局表）。
(defvar seshat-reader-mode-map)
(defvar seshat-reader-translate-panel-map)
;; 搜索结果侧栏的键表定义在 `seshat-reader-search'（本模块不 require 它，同一条
;; 「渲染时只读、不拉依赖」的边界）。声明只为消除字节编译的 free variable 告警；
;; 运行时该模块未加载时按 nil 处理（`--key-text' 会退化为解析全局表，但那一行
;; 的命令本身也未定义，故实际显示「（未加载）」）。
(defvar seshat-reader-search--sidebar-map)

;; 帮助页也是 `special-mode' 只读页，同样要摘掉 evil normal state；该函数由
;; `seshat-reader' 提供（本模块不 require 它），故在此仅声明以消除字节编译告警。
(declare-function seshat-reader--disable-evil "seshat-reader" ())

(defconst seshat-reader-help-buffer-name "*Seshat Reader Help*"
  "帮助页的 buffer 名.
由 `seshat-reader-help' 复用（已存在就重写内容，不重建 buffer），也是本页作为
普通帮助 buffer（而非信息面板）的标识——它不带 `seshat-reader-sidebar' window
parameter，因此 `seshat-reader-sidebar-toggle' 之类的面板命令不管它。")

(defconst seshat-reader-help--navigation-keys
  '((seshat-reader-next-page . "下一页")
    (seshat-reader-previous-page . "上一页")
    (seshat-reader-scroll-down-screen-or-next-page . "下滚一屏，到底翻页")
    (seshat-reader-scroll-up-screen-or-prev-page . "上滚一屏，到顶翻页")
    (seshat-reader-scroll-left . "横向左滚")
    (seshat-reader-scroll-right . "横向右滚")
    (seshat-reader-goto-page . "跳到指定页")
    (seshat-reader-first-page . "跳到首页")
    (seshat-reader-last-page . "跳到末页")
    (seshat-reader-fit-to-height . "按整页适配（页面完整可见）")
    (seshat-reader-fit-to-width . "按整宽适配（纵向可滚动）")
    (seshat-reader-enlarge-size . "放大")
    (seshat-reader-shrink-size . "缩小")
    (seshat-reader-rotate-clockwise . "顺时针旋转 90°")
    (seshat-reader-refresh-doc-buffer . "重渲染当前页")
    (seshat-reader-close-doc . "关闭文档"))
  "阅读 buffer 的**翻页 / 缩放**键位表，形式为 (命令 . 一行说明).
键位在 `seshat-reader-mode-map' 中解析（见
`seshat-reader-help--key-text'）。与 `seshat-reader-help--feature-keys' 分表
只为让帮助页读起来有分组，二者渲染方式完全相同。")

(defconst seshat-reader-help--feature-keys
  '((seshat-reader-annotation-create . "在最近一次选区上建批注")
    (seshat-reader-translate-toggle . "翻译最近一次选区（面板已开则关闭）")
    (seshat-reader-translate-explain-toggle . "解释最近一次选区（与译文共用面板）")
    (seshat-reader-translate-follow-up . "对同一段原文继续追问")
    (seshat-reader-search . "跨页文本搜索（命中同时列进左侧搜索结果面板）")
    (seshat-reader-outline-toggle . "开合目录面板")
    (seshat-reader-annotation-toggle . "开合批注列表面板")
    (seshat-reader-sidebar-toggle . "全部面板开合（有面板即全关，否则重开最近一个）")
    (seshat-reader-sidebar-toggle-width . "面板宽度在常态与扩大值之间切换")
    (seshat-reader-dark-mode . "开合暗色模式")
    (seshat-reader-dark-tint-cycle . "切换暗色配色预设（按预设表循环，可反向）")
    (seshat-reader-help . "本帮助页"))
  "阅读 buffer 的**功能**键位表，形式为 (命令 . 一行说明).
键位在 `seshat-reader-mode-map' 中解析。")

(defconst seshat-reader-help--panel-keys
  '((seshat-reader-sidebar-quit . "关闭当前面板（只关自己，其它面板保留）")
    (seshat-reader-sidebar-toggle-width . "面板宽度在常态与扩大值之间切换")
    (seshat-reader-translate-follow-up . "对面板里的原文继续追问")
    (seshat-reader-translate-save-as-annotation . "把最近一次译文存为服务端批注"))
  "面板 buffer 内的键位表，形式为 (命令 . 一行说明).
键位在 `seshat-reader-translate-panel-map' 中解析——面板是独立 buffer，它的
键表不在 `seshat-reader-mode-map' 里，混用会解析出错误的键位。")

(defconst seshat-reader-help--search-panel-keys
  '((seshat-reader-search-sidebar-goto . "跳到该条命中所在页并高亮它")
    (seshat-reader-search-sidebar-next . "下一条命中（并跳过去）")
    (seshat-reader-search-sidebar-prev . "上一条命中（并跳过去）")
    (seshat-reader-sidebar-quit . "关闭当前面板（只关自己，其它面板保留）"))
  "搜索结果侧栏内的键位表，形式为 (命令 . 一行说明).
键位在 `seshat-reader-search--sidebar-map' 中解析——搜索侧栏有自己的
`defvar-keymap'，与译文/批注/目录面板的键表不是同一张，混用会解析出错误键位
（面板内的 `q' 在三处都绑 `seshat-reader-sidebar-quit'，故这一行解析出的键位
与译文面板一致）。")

(defconst seshat-reader-help--feature-descriptions
  '(("翻译" . "把选区发往翻译引擎，结果写进译文面板。多引擎预设会逐条标注来源引擎、段间加分隔线。")
    ("解释" . "仍是同一个面板，但送模型的是「上下文 + 原文 + 指令」的装配串，用来理解术语与句法。")
    ("追问" . "针对同一段原文继续提问，历史轮次随请求发送；保留轮数由配置决定，首轮原文与首轮答案始终保留。")
    ("批注" . "框选取文后建服务端批注（高亮 / 便签），批注几何会画回页面；批注列表面板可跳转与删除。")
    ("目录" . "按文档大纲跳转，支持 avy 式单键定位；目录与搜索结果在左、译文与批注在右是默认版式。")
    ("搜索" . "整本跨页文本搜索，命中直接标在页面上，同时列进左侧搜索结果面板，可在命中之间逐个跳转。")
    ("面板承载" . "child frame 覆盖或窗口承载，逐类型的方位与宽度都可配；面板内容超出后在面板内滚动。")
    ("缓存" . "翻译与解释结果在**本会话内**缓存：同一内容（含上下文）再次打开不再请求，前缀参数 \\[universal-argument] 强制重新生成。"))
  "功能简介条目，形式为 (名称 . 说明).
说明文本会经 `substitute-command-keys' 处理一次，故可写 `\\[命令]' 形态的键位
占位符（例如 `\\[universal-argument]' 渲染为真实的前缀键）。")

(defun seshat-reader-help--key-text (command keymap)
  "返回 COMMAND 在 KEYMAP 中的键位文本；命令尚未加载时返回占位串.
KEYMAP 为 nil（该模块未加载，keymap 变量仍未绑定）或不是 keymap 时，解析退化
为全局表——此时本包命令多半没有全局键位，`substitute-command-keys' 给出
`M-x 命令名'，仍然是可执行的指引而不是错误信息。

**为什么在临时 buffer 里解析**：`\\[COMMAND]' 是相对**当前 buffer 的活跃
keymap** 解析的（实测：在 `special-mode' 的 buffer 里直接解析本包命令，得到的
全是 `M-x …'）。故先把 KEYMAP 装成临时 buffer 的 local map，再让
`substitute-command-keys' 解析，才能拿到 `seshat-reader-mode-map' 里的真实
键位。

COMMAND 未定义时直接返回「（未加载）」：键位表里那一行的命令压根不存在，键位
自然也没有注册，编造或显示 `M-x …' 都会误导。"
  (if (fboundp command)
      (with-temp-buffer
        (when (keymapp keymap)
          (use-local-map keymap))
        (substitute-command-keys (format "\\[%s]" command)))
    "（未加载）"))

(defun seshat-reader-help--rows (entries keymap)
  "把 ENTRIES 渲染成若干行文本，键位在 KEYMAP 中解析.
ENTRIES 为 (命令 . 说明) 列表，顺序即输出顺序；每行形如「两空格 + 左对齐的
键位（宽 12 列）+ 说明」，键位与说明之间至少一个空格。键位文本宽度不定
（`M-x 命令名' 会很长），因此宽度只用 `format' 的 `%-12s' 补足、不截断。"
  (mapconcat (lambda (entry)
               (format "  %-12s %s\n"
                       (seshat-reader-help--key-text (car entry) keymap)
                       (cdr entry)))
             entries
             ""))

(defun seshat-reader-help--features ()
  "返回「功能简介」段落文本，未加载的功能按命令名提示.
每条说明都经 `substitute-command-keys' 处理一次（见
`seshat-reader-help--feature-descriptions' 的 docstring），说明里的
`\\[命令]' 因此渲染成真实键位。这里解析的对象是 `global-map'（临时 buffer 不
装 local map），只用于前缀键与全局命令，不用于本包命令。"
  (mapconcat (lambda (entry)
               (with-temp-buffer
                 (format "  %s：%s\n"
                         (car entry)
                         (substitute-command-keys (cdr entry)))))
             seshat-reader-help--feature-descriptions
             ""))

(defun seshat-reader-help--panel-behavior (reader-map panel-map close-key)
  "返回「面板行为」段落文本.
READER-MAP 解析阅读 buffer 里的面板命令（全部开合），PANEL-MAP 解析面板内的
命令（`q' / 宽度切换），CLOSE-KEY 为关闭本帮助页的键位文本（由调用方在帮助页
buffer 内解析 `quit-window' 得到，故与本页真实的 `q' 一致）。末尾几句为固定
语义说明：面板位置、同类型复用与缓存生命周期。"
  (concat
   (seshat-reader-help--rows
    (list (cons 'seshat-reader-sidebar-quit "关闭**当前**面板，其它面板保留")
          (cons 'seshat-reader-sidebar-toggle-width
                "面板宽度在常态与扩大值之间切换"))
    panel-map)
   (seshat-reader-help--rows
    (list (cons 'seshat-reader-sidebar-toggle
                "全部面板开合（在阅读 buffer 里按；有面板即全关，否则重开最近一个）"))
    reader-map)
   (format "  %-12s %s\n" close-key "关闭本帮助页")
   "\n"
   "  位置固定：**目录与搜索结果在左**，译文与批注在右，方位与宽度可配；\n"
   "  同一类型重复打开复用同一窗口，不重置你手动调过的尺寸。\n"
   "  译文 / 解释缓存只在本会话内存里，重启 Emacs 即清空；\n"
   "  想立刻清空用 M-x seshat-reader-translate-clear-cache。\n"))

(defun seshat-reader-help--content (close-key)
  "返回帮助页的完整正文，CLOSE-KEY 为关闭本页的键位文本.
正文分五段（每段之间空行分隔）：标题与一句话简介、「阅读（翻页 / 缩放）」、
「功能键」、「面板内键位」（译文 / 批注 / 目录面板一张表，搜索结果侧栏另
一张表）、「功能简介」、「面板行为」。三处 keymap 在函数内按 `boundp' 取值——
`seshat-reader' / `seshat-reader-translate' / `seshat-reader-search' 未加载时
对应变量为 nil，键位解析退化为全局表，而不是报 void-variable。"
  (let ((reader-map (and (boundp 'seshat-reader-mode-map)
                         seshat-reader-mode-map))
        (panel-map (and (boundp 'seshat-reader-translate-panel-map)
                        seshat-reader-translate-panel-map))
        (search-map (and (boundp 'seshat-reader-search--sidebar-map)
                         seshat-reader-search--sidebar-map)))
    (concat
     "Seshat Reader 帮助\n"
     "==================\n\n"
     "文档阅读器：翻页与缩放、目录、跨页搜索、框选翻译 / 解释与批注。\n"
     "下面的键位取自**当前运行时的真实绑定**（由 substitute-command-keys 解析），\n"
     "因此与你自己的按键配置一致；标「（未加载）」的行表示对应模块尚未加载。\n\n"
     "* 阅读（翻页 / 缩放）\n\n"
     (seshat-reader-help--rows seshat-reader-help--navigation-keys reader-map)
     "\n* 功能键\n\n"
     (seshat-reader-help--rows seshat-reader-help--feature-keys reader-map)
     "\n* 面板内键位（光标在译文 / 批注 / 目录面板里时）\n\n"
     (seshat-reader-help--rows seshat-reader-help--panel-keys panel-map)
     "\n* 搜索结果面板内键位（光标在 *Seshat Search* 里时）\n\n"
     (seshat-reader-help--rows seshat-reader-help--search-panel-keys search-map)
     "\n* 功能简介\n\n"
     (seshat-reader-help--features)
     "\n* 面板行为\n\n"
     (seshat-reader-help--panel-behavior reader-map panel-map close-key))))

;;;###autoload
(defun seshat-reader-help ()
  "显示 Seshat Reader 的帮助页（只读 buffer `*Seshat Reader Help*'）.
buffer 已存在时**复用**并重写内容（不新建 buffer、不丢窗口），因此重复调用不会
堆积同名 buffer。内容每次重新渲染，故会话中途加载了新模块、或用户改过键位后，
再按一次即反映最新的键位与状态。

正文写完后切到 `special-mode'（只读视图，`q' 关闭本页 = `quit-window'；关闭
键位由 `substitute-command-keys' 在帮助页 buffer 内解析 `quit-window' 得到，
不在正文字符串里硬编码）。以 `display-buffer-below-selected' 显示在阅读区
下方、占 frame 高度四成——帮助页是「看一眼就关」的旁注，不抢阅读区的宽度；
已显示时走 `display-buffer-reuse-window' 复用原窗口。

键位注册不在本函数内：`?' 到 `seshat-reader-help' 的绑定由文件末尾的
`with-eval-after-load' 在阅读器加载完成后写入 `seshat-reader-mode-map'。返回
帮助页 buffer。"
  (interactive)
  (let ((buffer (get-buffer-create seshat-reader-help-buffer-name)))
    (with-current-buffer buffer
      (special-mode)
      (when (fboundp 'seshat-reader--disable-evil)
        (seshat-reader--disable-evil))
      (let ((inhibit-read-only t)
            (close-key (substitute-command-keys "\\[quit-window]")))
        (erase-buffer)
        (insert (seshat-reader-help--content close-key))
        (goto-char (point-min))
        (set-buffer-modified-p nil)
        (setq buffer-read-only t)))
    (pop-to-buffer buffer
                   '((display-buffer-reuse-window
                      display-buffer-below-selected)
                     (window-height . 0.4)))
    ;; 显示之后要再摘一次 evil：上面那次只管 major mode 刚就位的时点，
    ;; 而 evil 会在 buffer 被显示时把 `evil-local-mode' 重新打开（实测：
    ;; `pop-to-buffer' 之后它又变回 t），此处再关一次才真正生效。
    (when (fboundp 'seshat-reader--disable-evil)
      (seshat-reader--disable-evil))
    buffer))

;;; 键位

;; 本模块不 require `seshat-reader'（阅读器是重依赖：加载它会初始化 C 模块），
;; 故与其它扩展模块一致，用 `with-eval-after-load' 在阅读器加载完成后补键位；
;; 阅读器已加载时 `eval-after-load' 立即执行，重复加载也只是重写同一条绑定。
;; `?' 在 `special-mode-map' 里原本是 `describe-mode'；写进更具体的
;; `seshat-reader-mode-map' 后在阅读 buffer 内由本包接管，其它 buffer 的
;; `?' 行为不受影响。
(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "?") #'seshat-reader-help))

(provide 'seshat-reader-help)
;;; seshat-reader-help.el ends here
