;;; seshat-reader-sidebar.el --- Info panel support  -*- lexical-binding: t; -*-

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

;; 阅读器信息面板的**承载体**：把既有 buffer 以 **pop 式底部弹出**（形如
;; `*Help*'）的方式显示在阅读窗口下方或 frame 底部，承载批注列表与译文/解释。
;;
;; 弹出形式由 `seshat-reader-sidebar-position' 决定：`below-selected'（默认，
;; 在当前窗口下方分割，形如 `*Help*'）或 `at-bottom'（frame 底部整宽）。两者
;; 都是**非固定**窗口，可用 `q' 或 `seshat-reader-sidebar-toggle' 关闭。
;;
;; **单窗口 + per-kind 窗口状态记忆**：底部同一时刻只有一个面板窗口，批注与
;; 译文/解释**后显示者接管**（这是底部 pop 语义的必然结果，非缺陷）；但每个
;; 内容类型（kind）**各记各的高度**——切换内容前先捕获当前窗口的实测高度
;; （相对 frame 的比例）存入 `seshat-reader-sidebar--state'，再用目标 kind
;; 记住的高度新建窗口，故切回时高度自动恢复。**同一** kind 重复显示（批注
;; 列表在 delete/refresh 时会被反复渲染）走 `display-buffer' 复用同一窗口，
;; 不重建、不重置用户手动调整的高度（幂等）。首次显示某 kind 时用
;; `seshat-reader-sidebar-height'。该状态仅**会话内**记忆，不持久化。
;;
;; 本模块**不渲染内容**：批注列表由 `seshat-reader-annotation--render-list'
;; 渲染（ETAF 可用时改由 `seshat-reader-etaf' 渲染卡片）、译文/解释由
;; `seshat-reader-translate--render-panel' 写成只读 Markdown 文本 buffer
;; （`gfm-view-mode' 降级链），本模块只负责**显示与参数**。渲染抽象不在本步
;; 引入：若将来需统一渲染层再抽象（记入 tech-debt）。
;;
;; 模块零依赖：不 require 任何本项目/外部模块，只操作 buffer 与 window。
;;
;; 显示**必须**经 `display-buffer'（其复用逻辑保证同一 buffer 重复显示时窗口
;; 布局不变），**不得**绕过 `display-buffer' 直接操作窗口。
;;
;; 关闭面板**禁用** `window-toggle-side-windows'：它是 **frame 级全量**开关，
;; 会连带删除/恢复 eca-chat 与 which-key 的侧窗，跨包副作用不可接受；本模块
;; 只对本包面板窗口（带 `seshat-reader-sidebar' window parameter）逐个
;; `delete-window'。
;;
;; 本文件是**本仓库自研扩展**：从上游 vendor 重拷 seshat-reader 时应保留本
;; 文件、不得覆盖（vendor 边界见同目录 VENDORED.md）。

;;; Code:

(defgroup seshat-reader-sidebar nil
  "阅读器信息面板的显示方式与参数."
  :group 'seshat-reader
  :prefix "seshat-reader-sidebar-")

(defcustom seshat-reader-sidebar-enabled t
  "是否使用信息面板展示批注与译文/解释.
为 nil 时 `seshat-reader-sidebar-show' 退回 `pop-to-buffer'（批注列表）；译文
/解释是否同样退回 posframe 由 `seshat-reader-translate' 的渲染开关判断。"
  :type 'boolean
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-position 'below-selected
  "信息面板的弹出位置.
取 `below-selected'（默认）时在当前窗口下方分割弹出，形如 `*Help*'；
取 `at-bottom' 时在 frame 底部整宽弹出。两者都是非固定窗口，可用 `q' 或
`seshat-reader-sidebar-toggle' 关闭。"
  :type '(choice (const :tag "当前窗口下方（类 *Help*）" below-selected)
                 (const :tag "frame 底部整宽" at-bottom))
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-height 0.35
  "信息面板高度，作为 `window-height' 参数（按比例）.
仅对**新建**面板窗口生效：改动对已显示的窗口不会自动重排，需重开窗口或
手动 `window-resize'。该值在译文/解释面板上只作**首次显示/下限参考**——
显示后 `seshat-reader-sidebar--fit-height-for-content' 会按内容实际行数覆盖
它（上限见 `seshat-reader-sidebar-max-height'）；批注列表仍按本值固定高度。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-max-height 0.8
  "面板自适应高度的上限，按 `frame-height' 的**比例**计.
仅对译文/解释（kind 为 `translate'）面板生效：面板显示后按内容实际行数调整
高度（见 `seshat-reader-sidebar--fit-height-for-content'），调整后的窗口总高
不超过本值 × `frame-height'（超出则面板内滚动）。批注列表固定高度不受影响，
仍由 `seshat-reader-sidebar-height' 决定。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-select-window t
  "面板显示后是否在**命令结束时**把光标移入面板.
非 nil 时 `seshat-reader-sidebar--display-params' 会在调用方请求 SELECT 时
往 `display-buffer' 的 action list 末尾追加 `(post-command-select-window . t)'
——`display-buffer' 自身不选窗口，把选窗延到当前命令结束时执行（避免在渲染
中途抢光标）；本变量为 nil 时无论调用方是否请求都不追加，光标留在原窗口。

调用方按语义决定是否请求 SELECT（`seshat-reader-sidebar-show' 的第三个
参数）：**批注列表与译文面板都请求**——
- 批注列表由 `seshat-reader-annotation--render-list' 在本命令内渲染完成后
  请求，此时内容已就绪；
- 译文/解释面板由 `seshat-reader-translate--render-panel' 请求：该函数在
  写入 Markdown 正文之后才调 `show'，内容已就绪。

渲染层（ETAF 批注卡片或 translate 的 Markdown 文本 buffer）把内容写进面板
buffer 后再调 `show'，同样满足「内容就绪」前提。"
  :type 'boolean
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-translate-buffer-name "*Seshat Sidebar*"
  "译文/解释面板的**展示 buffer** 名.
只用于承载最终呈现给用户的只读 Markdown 文本 buffer（由
`seshat-reader-translate--render-panel' 写入），也是 popper 名单
（`seshat-reader-sidebar-buffer-p'）判定的名字之一。**不再**用作 go-translate
function `gt-buffer-render' 的 `:name'，也**不再**作为结果捕获的守卫依据：
gt 的中转 buffer 改用隐藏 buffer ` \" *Seshat gt*\"'
（`seshat-reader-translate--gt-buffer-name'），捕获在 `:then' 回调内直接完成。"
  :type 'string
  :group 'seshat-reader-sidebar)

(defconst seshat-reader-sidebar--annotation-buffer-name "*Seshat Annotations*"
  "批注列表面板的 buffer 名.
值须与 `seshat-reader-annotation.el' 的
`seshat-reader-annotation-list-buffer-name' **保持一致**；本模块零依赖、不
require annotation，故在此另立常量（若上游改名需同步）。仅用于按名判定面板
buffer（见 `seshat-reader-sidebar-buffer-p'）。")

(defvar seshat-reader-sidebar--last-kind nil
  "最近一次经 `seshat-reader-sidebar-show' 显示的内容类型（`annotations' 或 `translate'）.
供 `seshat-reader-sidebar-toggle' 重新打开时恢复。译文/解释面板现在也经
`seshat-reader-sidebar-show' 显示（`seshat-reader-translate--render-panel' 调用
并传 kind 为 `translate'），故关闭译文面板后 toggle 可原样重开。")

(defvar seshat-reader-sidebar--last-buffer nil
  "最近一次显示的面板 buffer.
供 `seshat-reader-sidebar-toggle' 重新打开时恢复。")

(defvar seshat-reader-sidebar--state nil
  "Per-kind 窗口高度记忆，形式为 alist（KIND -> 高度比例）.
由 `seshat-reader-sidebar--capture-state' 在切换内容或关闭面板时写入，供
`seshat-reader-sidebar--height-for-kind' 读取。**另**由
`seshat-reader-sidebar--fit-height-for-content' 在按内容自适应调整译文/解释
面板高度后写入（记忆的是调整后的实测比例，故下次切回该 kind 时沿用内容高度）。
仅会话内记忆，不持久化；为空时各 kind 一律使用 `seshat-reader-sidebar-height'。")

(defun seshat-reader-sidebar-window-p (window)
  "判断 WINDOW 是否本包信息面板窗口.
判据是 WINDOW 带有非 nil 的 `seshat-reader-sidebar' window parameter（由
`seshat-reader-sidebar--display-params' 在 action list 的 `window-parameters'
中设置）。供 `seshat-reader-sidebar-toggle' 与测试复用。"
  (and (windowp window)
       (window-parameter window 'seshat-reader-sidebar)))

(defun seshat-reader-sidebar--windows ()
  "返回本包当前的全体信息面板窗口."
  (let (windows)
    (dolist (win (window-list nil 'nomini))
      (when (seshat-reader-sidebar-window-p win)
        (push win windows)))
    (nreverse windows)))

(defun seshat-reader-sidebar--height-for-kind (kind)
  "返回 KIND 对应的面板高度（`window-height' 比例）.
命中 `seshat-reader-sidebar--state' 中该 KIND 的记忆值时返回记忆值，否则返回
`seshat-reader-sidebar-height'；KIND 为 nil 时直接返回默认值。"
  (let ((cell (and kind (assq kind seshat-reader-sidebar--state))))
    (if cell (cdr cell) seshat-reader-sidebar-height)))

(defun seshat-reader-sidebar--capture-state (&optional windows)
  "捕获本包面板窗口的当前高度，按 kind 记入 `seshat-reader-sidebar--state'.
WINDOWS 省略时取全部本包面板窗口（`seshat-reader-sidebar--windows'）。逐个读
窗口的 `seshat-reader-sidebar-kind' window parameter 与 `window-total-height'，
换算为相对 `frame-height' 的比例后写入（同 KIND 的旧值先 `assq-delete-all'
删除再 `cons'，保持零依赖的 alist 语义）。KIND 为 nil、高度非正数或
`frame-height' 异常（含为 0）时跳过该窗口。用户手动 resize 后的高度因此被
记住，供下次切回该 KIND 时恢复。"
  (dolist (win (or windows (seshat-reader-sidebar--windows)))
    (let ((kind (window-parameter win 'seshat-reader-sidebar-kind))
          (frame-h (ignore-errors (frame-height))))
      (when (and kind (numberp frame-h) (> frame-h 0))
        (let ((h (ignore-errors (window-total-height win))))
          (when (and (numberp h) (> h 0))
            (setq seshat-reader-sidebar--state
                  (cons (cons kind (/ (float h) (float frame-h)))
                        (assq-delete-all kind seshat-reader-sidebar--state)))))))))

(defun seshat-reader-sidebar--content-height (window)
  "返回 WINDOW 的内容高度，以**行数**（整数）表示.
实现：在 WINDOW 的 buffer 内取 `line-pixel-height' 作单行像素高（非正数或
取不到时退回 `frame-char-height'），再用 `window-text-pixel-size' 测量从
`point-min' 到 `point-max' 的像素高——测量上限取 40 行，避免超长内容测量
耗时——最后按单行像素高向上取整换算为行数。任一环节失败返回 nil（调用方按
最小高度处理）。"
  (ignore-errors
    (with-current-buffer (window-buffer window)
      (let* ((raw (line-pixel-height))
             (line-height (if (and (numberp raw) (> raw 0))
                              raw
                            (frame-char-height)))
             (pixel (cdr (window-text-pixel-size
                          window (point-min) (point-max)
                          nil (* 40 line-height)))))
        (ceiling pixel line-height)))))

(defun seshat-reader-sidebar--fit-applicable-p (buffer &optional kind)
  "判断面板 BUFFER 是否适用「按内容自适应高度」.
KIND 省略时读 BUFFER 所在窗口的 `seshat-reader-sidebar-kind' window parameter。
判据为**两重限制**：KIND 必须是 `translate'（批注列表固定高度、不参与自适应），
且 BUFFER 未挂载 ETAF runtime（ETAF 画布自管 viewport，改窗口高度无意义；
`etaf-runtime-for-buffer' 未定义时视为未挂载）。"
  (and (buffer-live-p buffer)
       (eq (or kind
               (let ((win (get-buffer-window buffer t)))
                 (and win (window-parameter win 'seshat-reader-sidebar-kind))))
           'translate)
       (not (ignore-errors
              (and (fboundp 'etaf-runtime-for-buffer)
                   (etaf-runtime-for-buffer buffer))))))

(defun seshat-reader-sidebar--fit-height-for-content (window &optional kind)
  "按内容高度调整面板 WINDOW 的高度（仅译文/解释面板）.
先经 `seshat-reader-sidebar--fit-applicable-p' 过两重限制（KIND 必须是
`translate'、且 buffer 未挂载 ETAF runtime；KIND 省略时取 WINDOW 的
`seshat-reader-sidebar-kind' window parameter），再以
`seshat-reader-sidebar--content-height' 的行数 + 2（header-line 与余量）为
目标高度，下限 5 行、上限为 `seshat-reader-sidebar-max-height' 与
`frame-height' 之积向下取整，用 `window-resize'（DELTA 按行、忽略固定尺寸
约束）调整。
调整后把最终比例 `window-total-height'/`frame-height' 写入
`seshat-reader-sidebar--state'（同 KIND 先 `assq-delete-all' 再 `cons'，与
`seshat-reader-sidebar--capture-state' 的写法一致），使下次切回该 KIND 时沿用。

只调窗口高度、**不动** buffer 与阅读窗口对象。整个函数体由 `ignore-errors'
包裹：测量或调整失败一律静默，不影响面板正常展示。"
  (ignore-errors
    (let* ((buffer (window-buffer window))
           (kind (or kind
                     (window-parameter window 'seshat-reader-sidebar-kind))))
      (when (seshat-reader-sidebar--fit-applicable-p buffer kind)
        (let* ((content (or (seshat-reader-sidebar--content-height window) 0))
               (frame-h (frame-height))
               (max-h (floor (* seshat-reader-sidebar-max-height
                                (float frame-h))))
               (target (max 5 (min max-h (+ content 2))))
               (delta (- target (window-total-height window))))
          (unless (zerop delta)
            (window-resize window delta nil t))
          (setq seshat-reader-sidebar--state
                (cons (cons kind
                            (/ (float (window-total-height window))
                               (float frame-h)))
                      (assq-delete-all kind seshat-reader-sidebar--state))))))))

(defun seshat-reader-sidebar--display-params (&optional kind select)
  "生成 `display-buffer' 的弹出 action list.
按 `seshat-reader-sidebar-position' 返回 `(display-buffer-below-selected)'
（`below-selected'）或 `(display-buffer-at-bottom)'（`at-bottom`），其后附
`(window-height . HEIGHT)' 与 `(window-parameters . PARAMS)' 两项：HEIGHT 取
KIND 的记忆高度（见 `seshat-reader-sidebar--height-for-kind'；KIND 为 nil 时
用 `seshat-reader-sidebar-height'），PARAMS 同时携带面板判据
`(seshat-reader-sidebar . t)' 与 kind 标记
`(seshat-reader-sidebar-kind . KIND)'。该返回值由
`seshat-reader-sidebar--display' 使用，是面板参数的**单一来源**（gt 的中转
buffer 改用 `(display-buffer-no-window)'，不再共用本 action list）。

可选参数 SELECT 非 nil 表示调用方希望**命令结束时**把光标移入面板：此时若
`seshat-reader-sidebar-select-window' 亦非 nil，在 action list 末尾追加
`(post-command-select-window . t)'；两者任一为 nil 则不追加（光标留在原窗口）。
SELECT 由调用方按语义决定（见 `seshat-reader-sidebar-show' 的第三个参数）：
批注列表与译文面板都在内容就绪后请求它，故 `seshat-reader-sidebar--display'
与本函数都把 SELECT 原样透传，不再按 KIND 猜。"
  (append (pcase seshat-reader-sidebar-position
            ('at-bottom '((display-buffer-at-bottom)))
            (_ '((display-buffer-below-selected))))
          (list (cons 'window-height (seshat-reader-sidebar--height-for-kind kind))
                (cons 'window-parameters
                      (list (cons 'seshat-reader-sidebar t)
                            (cons 'seshat-reader-sidebar-kind kind))))
          (when (and select seshat-reader-sidebar-select-window)
            (list (cons 'post-command-select-window t)))))

(defun seshat-reader-sidebar--display (buffer kind &optional select)
  "把 BUFFER 显示到信息面板并返回窗口.
显示经 `display-buffer' 与 `seshat-reader-sidebar--display-params' 完成，以保证
幂等。KIND 既用于记录（供 `seshat-reader-sidebar-toggle' 恢复时使用），也决定
面板窗口的 kind 标记与高度记忆：

1. 先 `seshat-reader-sidebar--capture-state' 捕获现有本包窗口的实测高度
   （用户可能刚 resize 过）——**必须**在关闭任何窗口之前完成；
2. 已有本包窗口且其 kind 等于 KIND → 直接 `display-buffer' 复用（幂等，不动
   用户手动调整的高度）；
3. 已有本包窗口但 kind 不同 → 先关闭本包全部窗口，再按 KIND 的记忆高度新建；
4. 无本包窗口 → 按 KIND 的记忆高度新建。

显示之后按内容自适应高度：`display-buffer' 的返回值（窗口）交给
`seshat-reader-sidebar--fit-height-for-content'，由它自行判两重限制
（KIND=`translate' 且 buffer 未挂载 ETAF runtime）后调整高度并把实测比例写入
`seshat-reader-sidebar--state'；批注列表因此恒为固定高度，不受影响。

光标跟随：SELECT 非 nil 时向 `seshat-reader-sidebar--display-params' 请求
`(post-command-select-window . t)'（是否真正追加还受
`seshat-reader-sidebar-select-window' 约束），命令结束时光标移入面板。
SELECT 由调用方按语义给出、本函数原样透传——不再按 KIND 猜测（T10 首轮
反馈：译文面板曾因「只有 `annotations' 才请求」的硬编码而不跟随光标）。

参数传递方式：action list 经 `display-buffer-overriding-action' 以规范
`(FUNCTIONS . ALIST)' cons cell 绑定后交给裸 `display-buffer'，**而非**作为其
ACTION 实参——overriding-action 的优先级高于 `display-buffer-alist'（popper 启用
时会在表头插入接管规则），故面板布局始终由本包掌控。

调用前记录 `seshat-reader-sidebar--last-kind' 与
`seshat-reader-sidebar--last-buffer'。"
  (setq seshat-reader-sidebar--last-kind kind
        seshat-reader-sidebar--last-buffer buffer)
  (let* ((params (seshat-reader-sidebar--display-params kind select))
         (windows (seshat-reader-sidebar--windows))
         (same (and windows
                    (eq (window-parameter (car windows)
                                          'seshat-reader-sidebar-kind)
                        kind)))
         (display-buffer-overriding-action (cons (caar params) (cdr params))))
    (seshat-reader-sidebar--capture-state windows)
    (unless same
      (dolist (win windows)
        (ignore-errors (delete-window win))))
    (let ((window (display-buffer buffer)))
      (seshat-reader-sidebar--fit-height-for-content window kind)
      window)))

(defun seshat-reader-sidebar-buffer-p (buffer)
  "判断 BUFFER 是否本包信息面板的 buffer.
BUFFER 可以是 buffer 对象或 buffer 名（字符串），其它类型返回 nil。判定**只
按名字**匹配 `seshat-reader-sidebar--annotation-buffer-name'（批注列表）与
`seshat-reader-sidebar-translate-buffer-name'（译文/解释），不检查 major-mode
或 window parameter，故对尚未显示的 buffer 同样有效（popper 登记 popup 时
buffer 可能还没被显示）。供 popper 的分流使用。"
  (let ((name (cond ((bufferp buffer) (buffer-name buffer))
                    ((stringp buffer) buffer)
                    (t nil))))
    (and name
         (member name (list seshat-reader-sidebar--annotation-buffer-name
                            seshat-reader-sidebar-translate-buffer-name))
         t)))

(defun seshat-reader-sidebar-display-buffer (buffer alist)
  "显示本包面板 BUFFER 并返回窗口（供 popper 的 `display-function' 分流）.
popper 重开 popup 时用裸 `display-buffer'（`popper-open-latest'），会命中它在
`display-buffer-alist' 表头插入的规则而漂移为 bottom side window；本函数让 popper
改走本包显示路径，使「首次显示」与「popper 开→关→重开」布局一致（位置、高度、
per-kind 高度记忆、`seshat-reader-sidebar' 窗口参数全部保留）。

KIND 按 buffer 名推断：等于 `seshat-reader-sidebar-translate-buffer-name' 时取
`translate'，否则取 `annotations'（与 `seshat-reader-sidebar-buffer-p' 的判定
口径一致）。随后调用 `seshat-reader-sidebar--display' 显示并返回其窗口。

两种 KIND 都传 SELECT=t：popper 重开是显式用户动作、且 buffer 内容早已就绪，
故与常态渲染路径一致地跟随光标（T10 第 1 轮反馈：用户要求译文面板也跟随，
一致性优先）。是否真正跟随仍受 `seshat-reader-sidebar-select-window' 约束。

ALIST 被忽略：面板布局参数一律由本包决定，不接受调用方覆盖；保留该参数只为
兼容 `display-buffer' 动作函数的签名（popper 以 `(BUFFER ALIST)' 调用）。"
  (ignore alist)                        ; 面板布局由本包决定，ALIST 不参与
  (let* ((name (cond ((bufferp buffer) (buffer-name buffer))
                     ((stringp buffer) buffer)))
         (kind (if (equal name seshat-reader-sidebar-translate-buffer-name)
                   'translate
                 'annotations))
         (target (or (and (bufferp buffer) buffer)
                     (and name (get-buffer name))
                     buffer)))
    (seshat-reader-sidebar--display target kind t)))

(defun seshat-reader-sidebar-show (buffer kind &optional select)
  "把 BUFFER 显示到信息面板的统一入口，返回窗口.
批注列表与译文/解释面板都经本函数显示：批注列表由
`seshat-reader-annotation--render-list' 调用；译文/解释由
`seshat-reader-translate--render-panel' 写入 Markdown 文本 buffer 后调用（kind
为 `translate'）。只有 `pop' / `pin' 两条 posframe 回退路径不经本函数。
KIND 用于记录最近显示的内容类型（供 `seshat-reader-sidebar-toggle'
恢复时使用），并决定面板窗口的 kind 标记与**per-kind 高度记忆**：切换内容前
先捕获当前窗口实测高度存给其 kind，再按目标 kind 记住的高度新建窗口，故切换
回来时高度自动恢复；同一 kind 重复显示不重建窗口。显示后**译文/解释面板**
还会按内容自适应高度（`seshat-reader-sidebar--fit-height-for-content'，上限
`seshat-reader-sidebar-max-height'）；批注列表固定高度。
`seshat-reader-sidebar-enabled' 为真时走 `seshat-reader-sidebar--display'；
否则退回 `pop-to-buffer'（保证禁用时行为可回退）。

SELECT 非 nil 表示「面板内容已就绪，可以跟随光标」：批注列表与译文/解释面板
都在**内容写入 buffer 之后**调用本函数，故都传非 nil（是否真正跟随仍受
`seshat-reader-sidebar-select-window' 约束）。T10 首轮反馈前这里按 KIND 硬编码
（只对批注面板传非 nil），导致译文面板永远不跟随光标。"
  (if seshat-reader-sidebar-enabled
      (seshat-reader-sidebar--display buffer kind select)
    (pop-to-buffer buffer)))

(defun seshat-reader-sidebar-toggle ()
  "开或关本包的信息面板.
关闭时先用 `seshat-reader-sidebar--capture-state' 记住各面板窗口的实测高度
（保证用户 resize 后的高度被记住），再把本包全部面板窗口逐个 `delete-window'
（用 `ignore-errors' 包裹），并把窗口 buffer 记入
`seshat-reader-sidebar--last-buffer'；打开时按最近一次的类型
（`seshat-reader-sidebar--last-kind'）重新显示（按其记忆高度恢复），若无可恢复
的 buffer 则提示先打开批注列表或译文。**不使用 `window-toggle-side-windows'**：
它是 frame 级全量开关，会连带删除/恢复 eca-chat 与 which-key 的侧窗，跨包
副作用不可接受。"
  (interactive)
  (let ((windows (seshat-reader-sidebar--windows)))
    (if windows
        (progn
          (seshat-reader-sidebar--capture-state windows)
          (dolist (win windows)
            (let ((buffer (window-buffer win)))
              (when (buffer-live-p buffer)
                (setq seshat-reader-sidebar--last-buffer buffer)))
            (ignore-errors (delete-window win)))
          (message "Seshat Reader sidebar: 已关闭 %d 个面板窗口"
                   (length windows)))
      (if (and (bufferp seshat-reader-sidebar--last-buffer)
               (buffer-live-p seshat-reader-sidebar--last-buffer))
          ;; 重开是显式用户动作、内容已就绪 → 允许跟随光标。
          (seshat-reader-sidebar-show
           seshat-reader-sidebar--last-buffer
           (or seshat-reader-sidebar--last-kind 'annotations)
           t)
        (message "Seshat Reader sidebar: 先打开批注列表（C-c C-l）或译文再切换")))))

(provide 'seshat-reader-sidebar)
;;; seshat-reader-sidebar.el ends here
