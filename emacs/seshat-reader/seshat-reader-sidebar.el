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

;; 阅读器信息面板的**承载体**。术语分工：`outline' = 导航（目录/大纲，只
;; 跳转，不记录任何内容），`annotations' = 标注（批注列表，可创建/跳转/删除）。
;; 本模块把既有 buffer 显示为阅读区旁/下方的面板，承载批注列表与译文/解释，
;; 将来还承载目录（`outline'）。
;;
;; 弹出形式由「kind → 位置」解析函数 `seshat-reader-sidebar--position-for-kind'
;; 决定，共四种取值：
;;
;; - `below-selected'：在当前窗口下方分割，形如 `*Help*'，**高度语义**；
;; - `at-bottom'：frame 底部整宽，**高度语义**；
;; - `left' / `right'：frame 左侧/右侧的 **side window**，**宽度语义**。
;;
;; side window 由 Emacs 维护独立窗口树（同侧同 slot 复用），故左右分栏时
;; 阅读区不会被逐次分割挤压；本模块**不自己 `split-window'**。四种形式都是
;; **非固定**窗口，可用 `q' 或 `seshat-reader-sidebar-toggle' 关闭。
;;
;; **per-kind 多窗口共存 + per-kind 尺寸记忆**：每个内容类型（kind）占**独立**
;; 窗口，slot 由 `seshat-reader-sidebar--slot-for-kind' 按 kind 分配，故「左
;; 目录（`outline'）/ 右信息（`annotations' / `translate'）/ 中间阅读区」三栏
;; 可同时存在、互不挤压；显示或关闭一个 kind **不影响**其它 kind。方位也按
;; kind 解析：`outline' 用 `seshat-reader-outline-sidebar-position'（默认
;; `left'），其余 kind 用 `seshat-reader-sidebar-position'（默认 `right'），
;; 两者都可取上面四种形式。每个 kind 还**各记各的尺寸比例**——显示/关闭前先
;; 捕获现有窗口的实测尺寸（相对 frame 的比例，按**该 kind 方位**取宽或高）存入
;; `seshat-reader-sidebar--state'，再用目标 kind 记住的比例新建窗口，故切回时
;; 尺寸自动恢复。记忆值带**方向标签**（`width' / `height'）：若运行中把某 kind
;; 的方位从左右分栏改到底部模式（或反之），旧记忆的方向与当前方向不符，读取时
;; 回落该方向的默认值——不会把宽度比例当高度比例用（见
;; `seshat-reader-sidebar--direction' / `--size-for-kind'）。**同一** kind 重复
;; 显示（批注列表在 delete/refresh 时会被反复
;; 渲染）走 `display-buffer' 复用同一窗口，不重建、不重置用户手动调整的尺寸
;; （幂等）。首次显示某 kind 时用其方位对应的默认值：
;; `seshat-reader-sidebar-height'（高度语义）或 `seshat-reader-sidebar-width'
;; / `seshat-reader-outline-sidebar-width'（宽度语义）。该状态仅**会话内**
;; 记忆，不持久化。
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

(defcustom seshat-reader-sidebar-position 'right
  "**信息栏**（kind 为 `annotations' / `translate'）的弹出位置.
取值与尺寸语义的对应关系：

- `right'（默认）：frame 右侧的 side window，**宽度语义**（尺寸由
  `seshat-reader-sidebar-width' 决定）。
- `left'：frame 左侧的 side window，**宽度语义**（同上）。
- `below-selected'：在当前窗口下方分割弹出，形如 `*Help*'，**高度语义**
  （尺寸由 `seshat-reader-sidebar-height' 与 `-min-height' / `-max-height'
  决定）。
- `at-bottom'：在 frame 底部整宽弹出，**高度语义**（同上）。

四种形式都是非固定窗口，可用 `q' 或 `seshat-reader-sidebar-toggle' 关闭。
side window 由 Emacs 维护独立窗口树（同侧同 slot 复用），故左右分栏时阅读区
不会被逐次分割挤压。变更为 `left' / `right' 后 `-height' 一族的变量不再生效，
改由宽度变量接管；反之亦然。

**只管辖信息栏**：目录面板（kind 为 `outline'）的位置由
`seshat-reader-outline-sidebar-position' 单独决定（默认 `left'），二者由
`seshat-reader-sidebar--position-for-kind' 统一解析，故「左目录 + 右信息」可
并存。想让**全部**面板回到底部模式，把本变量与
`seshat-reader-outline-sidebar-position' 同时设为底部位。

**破坏性变更（2026-10-22，M12 T3）**：默认值由 `below-selected' 改为
`right'——批注/译文本属旁注信息，放右侧不挤压阅读区的横向阅读流。旧配置中依赖
默认底部弹出的用户需显式设置
`(setq seshat-reader-sidebar-position \\='below-selected)'；仅依赖旧默认值、
未显式设置本变量的用户，升级后面板会改到右侧（宽度语义，
`seshat-reader-sidebar-width' 生效，`-height' 一族不再生效），目录面板则改到
左侧。"
  :type '(choice (const :tag "frame 右侧 side window" right)
                 (const :tag "frame 左侧 side window" left)
                 (const :tag "当前窗口下方（类 *Help*）" below-selected)
                 (const :tag "frame 底部整宽" at-bottom))
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-outline-sidebar-position 'left
  "**目录栏**（kind 为 `outline'）的弹出位置.
取值与 `seshat-reader-sidebar-position' 相同（`left' / `right' 为 side
window、**宽度语义**；`below-selected' / `at-bottom' 为底部模式、**高度语
义**），但只对 kind 为 `outline' 的面板生效；其余 kind 一律由
`seshat-reader-sidebar-position' 管辖（见
`seshat-reader-sidebar--position-for-kind'）。默认 `left'，与信息栏默认的
`right' 分居两侧，形成「左目录 / 右信息 / 中间阅读区」的三栏版式。

side 模式下的宽度由 `seshat-reader-outline-sidebar-width' 决定；目录面板切到
底部模式时宽度变量不再生效，改由 `seshat-reader-sidebar-height' 决定高度。"
  :type '(choice (const :tag "frame 左侧 side window" left)
                 (const :tag "frame 右侧 side window" right)
                 (const :tag "当前窗口下方（类 *Help*）" below-selected)
                 (const :tag "frame 底部整宽" at-bottom))
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-width 0.24
  "左右分栏时**信息栏**（kind 为 `annotations' / `translate'）的宽度比例.
仅在 `seshat-reader-sidebar-position' 取 `left' 或 `right' 时生效，作为
`display-buffer' 的 `(window-width . WIDTH)'：**小数**按 frame 根窗口总宽的
比例换算为列数（`window--display-buffer' 的语义），整数则直接作为列数。
目录栏（kind 为 `outline'）用 `seshat-reader-outline-sidebar-width'。

改动仅对**新建**面板窗口生效（已显示的窗口不自动重排，需重开或手动
`window-resize'）。底部模式（`below-selected' / `at-bottom'）不使用本值，见
`seshat-reader-sidebar-height'。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-outline-sidebar-width 0.20
  "左右分栏时**目录栏**（kind 为 `outline'）的宽度比例.
与 `seshat-reader-sidebar-width' 同义（小数按 frame 根窗口总宽的比例换算为
列数，整数直接作为列数），但只对 kind 为 `outline' 的面板生效——目录标题通常
短于批注/译文卡片，故默认更窄。

仅当 `seshat-reader-sidebar-position' 取 `left' 或 `right' 时生效；底部模式下
目录面板的高度语义仍由 `seshat-reader-sidebar-height' 决定。改动仅对**新建**
面板窗口生效。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-carrier 'childframe
  "面板承载方式（除 `seshat-reader-panel-carrier-alist' 逐 kind 覆盖外生效).
`childframe'：以 child frame 覆盖在父 frame 右上角，不参与窗口树，故显示/刷新
面板不会改变阅读窗口尺寸（阅读器版面与窗口像素尺寸耦合，压缩阅读窗口会触发
重新适配）。`window'：沿用既有的 side window / 底部窗口承载，行为与
`seshat-reader-sidebar-position' 一族变量完全一致。
非图形环境（`display-graphic-p' 为 nil）强制回退 `window'：child frame 只存在
于图形终端。"
  :type '(choice (const :tag "child frame 覆盖（不改窗口布局）" childframe)
                 (const :tag "窗口承载（side window / 底部）" window))
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-carrier-alist '((annotations . window))
  "逐 kind 覆盖 `seshat-reader-panel-carrier' 的承载方式.
键是面板 kind（`outline' / `annotations' / `translate'），值是 carrier
（`childframe' / `window`）。默认为批注列表保留窗口承载：批注条目多、需要长
列表浏览与逐条跳转，覆盖浮层既遮挡正文又放不下。"
  :type '(alist :key-type symbol :value-type symbol)
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-width 0.34
  "面板承载为 child frame 时的宽度比例（占父 frame 像素宽）."
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-height 0.45
  "面板承载为 child frame 时的高度比例（占父 frame 像素高）.
面板尺寸**打开即固定、全程不 resize**：内容超出后在面板窗口内滚动，避免流式
输出期间反复改变遮挡区域。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-margin 16
  "面板承载为 child frame 时距父 frame 右边缘与上边缘的像素间距."
  :type 'natnum
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-follow-bottom t
  "非 nil 时流式输出期间面板自动跟随底部（显示最新内容）.
用户向上滚动后停止跟随，回到底部时恢复。"
  :type 'boolean
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-panel-hide-on-buffer-change t
  "非 nil 时当前 buffer 不再是阅读器 buffer 就关闭本包 child frame 面板.
面板内容仍留在 buffer 中，可用 `seshat-reader-sidebar-toggle' 重开。"
  :type 'boolean
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-height 0.35
  "信息面板高度，作为 `window-height' 参数（按比例）.
**仅底部模式**（`seshat-reader-sidebar-position' 取 `below-selected' 或
`at-bottom'）生效；左右分栏（`left' / `right'）改用
`seshat-reader-sidebar-width' / `seshat-reader-outline-sidebar-width'。
仅对**新建**面板窗口生效：改动对已显示的窗口不会自动重排，需重开窗口或
手动 `window-resize'。该值在译文/解释面板上只作**首次显示/下限参考**——
显示后 `seshat-reader-sidebar--fit-height-for-content' 会按内容实际行数覆盖
它（上限见 `seshat-reader-sidebar-max-height'）；批注列表仍按本值固定高度。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-min-height 0.25
  "译文/解释面板按内容自适应时的**下限**，按 `frame-height' 的**比例**计.
仅对 kind 为 `translate' 的面板生效，且**只在底部模式**（`below-selected' /
`at-bottom'）下有意义——左右分栏时按内容行数调整高度没有意义，自适应整体停用
（见 `seshat-reader-sidebar--fit-applicable-p'）。目标高度不低于本值 ×
`frame-height'（向下取整，至少 1 行），也不高于
`seshat-reader-sidebar-max-height' × `frame-height'。批注列表固定高度不受影响。"
  :type 'number
  :group 'seshat-reader-sidebar)

(defcustom seshat-reader-sidebar-max-height 0.8
  "面板自适应高度的上限，按 `frame-height' 的**比例**计.
仅对译文/解释（kind 为 `translate'）面板生效，且**只在底部模式**下生效（左右
分栏时自适应整体停用）：面板显示后按内容实际行数调整高度（见
`seshat-reader-sidebar--fit-height-for-content'），调整后的窗口总高不超过本值
× `frame-height'（超出则面板内滚动）。批注列表固定高度不受影响，仍由
`seshat-reader-sidebar-height' 决定。"
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

(defconst seshat-reader-sidebar--outline-buffer-regexp "\\`\\*Outline of .*\\*\\'"
  "目录面板 buffer 名的正则.
目录 buffer 名是**动态**的（`seshat-reader-outline.el' 用 `format' 按
「星号 Outline of 源 buffer 名 星号」的模板生成），无法按常量精确匹配，故用本
正则判定（见 `seshat-reader-sidebar-buffer-p'）。两端用缓冲锚点锚定，避免名字
只是**包含**该片段的普通 buffer 被误判为目录面板。")

(defvar seshat-reader-sidebar--last-kind nil
  "最近一次经 `seshat-reader-sidebar-show' 显示的内容类型.
取值为 `annotations'、`translate' 或 `outline'。
供 `seshat-reader-sidebar-toggle' 重新打开时恢复。译文/解释面板现在也经
`seshat-reader-sidebar-show' 显示（`seshat-reader-translate--render-panel' 调用
并传 kind 为 `translate'），故关闭译文面板后 toggle 可原样重开。")

(defvar seshat-reader-sidebar--last-buffer nil
  "最近一次显示的面板 buffer.
供 `seshat-reader-sidebar-toggle' 重新打开时恢复。")

(defvar seshat-reader-sidebar--last-buffers nil
  "**Per-kind** 最近显示的面板 buffer，形式为 alist（KIND -> buffer）.
由 `seshat-reader-sidebar--display' 在每次显示时写入，供
`seshat-reader-sidebar-toggle' 携带 KIND 时按 kind 定向重开（例如关闭目录面
板后再按 \\[seshat-reader-sidebar-toggle-outline] 恢复原目录 buffer）。与
`seshat-reader-sidebar--last-buffer' 并存：后者是「最近一个面板」的全局记忆，
本变量是**每个 kind 各自**的记忆。仅会话内记忆，不持久化。")

(defvar seshat-reader-sidebar--state nil
  "Per-kind 面板**尺寸**记忆，形式为 alist（KIND -> (DIRECTION RATIO)）.
每个元素是三元列表 (KIND DIRECTION RATIO)：KIND 为 `annotations' /
`translate' / `outline'，DIRECTION 为**记录时**该 kind 方位对应的尺寸方向
（`width' 左右分栏 / `height' 底部模式，由
`seshat-reader-sidebar--direction' 给出），RATIO 为相对 `frame-width' 或
`frame-height' 的比例。

DIRECTION 是**语义标签**，不是冗余信息：运行中把某 kind 的方位从 `left'
改到 `below-selected' 后，旧记忆值是**宽度**比例，若直接当高度比例用会把
面板高度算成荒谬的值。故 `seshat-reader-sidebar--size-for-kind' 只在
DIRECTION 与当前方向一致时复用记忆值，否则回落到
`seshat-reader-sidebar--default-size' 的方向默认值。

旧格式（二元 `(KIND . RATIO)'，无方向信息）读取时按「方向未知」处理——
一律回落默认值，**不报错**（`--size-for-kind' 用 `consp' / `cadr' 判定，
畸形或旧格式条目自然落入默认分支）。

由 `seshat-reader-sidebar--capture-state' 在切换内容或关闭面板时写入（同时
记录方向），供 `seshat-reader-sidebar--size-for-kind' 读取。**另**由
`seshat-reader-sidebar--fit-height-for-content' 在按内容自适应调整译文/解释
面板高度后写入（记忆的是调整后的实测高度比例）。仅会话内记忆，不持久化；
为空时各 kind 使用方向对应的默认值
（`seshat-reader-sidebar--default-size'）。")

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

(defun seshat-reader-sidebar--window-for-kind (kind &optional windows)
  "返回本包面板窗口中 kind 标记等于 KIND 的那个窗口，没有则返回 nil.
WINDOWS 省略时取全部本包面板窗口（`seshat-reader-sidebar--windows'）。KIND 为
nil 时同样匹配 kind 标记为 nil 的面板窗口。供
`seshat-reader-sidebar--display' 判断「同 kind 是否已显示」——判据从「只看第一
个窗口」改为**按 kind 查找**，这是多 kind 共存的前提（否则批注与译文会互相顶
替）。"
  (let ((rest (or windows (seshat-reader-sidebar--windows)))
        found)
    (while (and rest (null found))
      (when (eq (window-parameter (car rest) 'seshat-reader-sidebar-kind) kind)
        (setq found (car rest)))
      (setq rest (cdr rest)))
    found))

;;; 方向与尺寸语义（宽度 vs 高度）

(defun seshat-reader-sidebar--position-for-kind (&optional kind)
  "返回 KIND 实际使用的弹出位置.
KIND 为 `outline' 时取 `seshat-reader-outline-sidebar-position'，其余（含 nil
与未知 kind）取 `seshat-reader-sidebar-position'。本函数是「kind → 位置」的
**单一判据**：方向（宽/高）、side、slot、尺寸默认值全部经它派生，故要加新的
per-kind 方位只需扩展本函数。"
  (if (eq kind 'outline)
      seshat-reader-outline-sidebar-position
    seshat-reader-sidebar-position))

(defun seshat-reader-sidebar--horizontal-p (&optional kind)
  "判断 KIND 是否为**左右分栏**（宽度语义）.
KIND 的方位由 `seshat-reader-sidebar--position-for-kind' 解析，取 `left' /
`right' 时返回非 nil（面板以 side window 形式占据 frame 侧边，尺寸按**宽
度**计）；`below-selected' / `at-bottom' 或任何未知取值返回 nil（尺寸按**高
度**计，走底部 pop 语义）。KIND 省略时按 `seshat-reader-sidebar-position'
判断（即信息栏方向）。本函数是尺寸读写方向的**单一判据**。"
  (memq (seshat-reader-sidebar--position-for-kind kind) '(left right)))

(defun seshat-reader-sidebar--position-side (&optional kind)
  "返回 KIND 的方位对应的 side window 侧（宽度语义的侧）.
`left' / `right' 分别返回 `left' / `right'；底部模式（`below-selected' /
`at-bottom'）返回 nil，表示面板不是 side window。方位按 KIND 经
`seshat-reader-sidebar--position-for-kind' 解析，故 `outline' 与信息栏可各在
不同侧。供 `seshat-reader-sidebar--display' 判断已有窗口是否仍在正确的侧（方
位变更时必须重建该 kind 的窗口，否则会残留旧侧的面板）。"
  (pcase (seshat-reader-sidebar--position-for-kind kind)
    ('left 'left)
    ('right 'right)
    (_ nil)))

(defun seshat-reader-sidebar--size-key (&optional kind)
  "返回 KIND 方位下 `display-buffer' action alist 的尺寸键.
左右分栏返回 `window-width'（float 按 frame 根窗口总宽的比例换算为列数，整数
直接用列数——依据 `window--display-buffer' 的实现），底部模式返回
`window-height'（float 为相对根窗口总高的比例，整数为行数）。"
  (if (seshat-reader-sidebar--horizontal-p kind) 'window-width 'window-height))

(defun seshat-reader-sidebar--default-size (kind)
  "返回 KIND 在其方位下的默认尺寸比例（无记忆值时使用）.
左右分栏（宽度语义）：KIND 为 `outline' 时用
`seshat-reader-outline-sidebar-width'，其余（含 nil）用
`seshat-reader-sidebar-width'。底部模式（高度语义）：一律用
`seshat-reader-sidebar-height'——`-min-height' / `-max-height' 只在底部模式
的自适应里参与夹紧，不是首次显示的默认值。"
  (if (seshat-reader-sidebar--horizontal-p kind)
      (if (eq kind 'outline)
          seshat-reader-outline-sidebar-width
        seshat-reader-sidebar-width)
    seshat-reader-sidebar-height))

(defun seshat-reader-sidebar--direction (&optional kind)
  "返回 KIND 当前方位下的**尺寸方向**，取 `width' 或 `height'.
左右分栏（`left' / `right'）返回 `width'，底部模式（`below-selected' /
`at-bottom'）返回 `height'，方位按 KIND 经
`seshat-reader-sidebar--position-for-kind' 解析。本函数是尺寸记忆**方向标签**
的单一来源：`--capture-state' 写入记忆时用它记录方向，
`--size-for-kind' 读取记忆时用它判断记忆值是否仍适用（方向不同即作废、回落
默认值），从而避免「运行中改方位后把宽度比例当高度比例用」。"
  (if (seshat-reader-sidebar--horizontal-p kind) 'width 'height))

(defun seshat-reader-sidebar--size-for-kind (kind)
  "返回 KIND 在当前方向下对应的面板尺寸比例.
命中 `seshat-reader-sidebar--state' 中该 KIND 的记忆值、**且**记忆条目的
方向（`nth 1'）与 `seshat-reader-sidebar--direction' 给出的当前方向一致时
返回该比例（`nth 2'）；其余情形——无记忆、方向不符、条目是旧的二元
`(KIND . RATIO)' 畸形格式——一律返回 `seshat-reader-sidebar--default-size'
的方向默认值。KIND 为 nil 时直接返回默认值。返回值直接作为
`display-buffer' 的 `window-width'（左右分栏）或 `window-height'（底部模式）
比例。

方向校验的理由：记忆值的方向跟随**记录时**的方位，若用户运行中把某 kind
从 `left' 切到 `below-selected'，旧记忆是宽度比例，直接复用会得到荒谬的
窗口高度。"
  (let ((cell (cdr-safe (and kind
                             (assq kind seshat-reader-sidebar--state)))))
    ;; CELL 是新格式的 `(DIRECTION RATIO)'；旧格式（二元 `(KIND . RATIO)'，无
    ;; 方向信息）的 cdr 是数字而非列表，`consp' 判据让它一并落入默认分支
    ;; （用 `nth' 取会因 `wrong-type-argument listp' 报错）。
    (if (and (consp cell)
             (eq (car cell) (seshat-reader-sidebar--direction kind))
             (numberp (cadr cell)))
        (cadr cell)
      (seshat-reader-sidebar--default-size kind))))

(defun seshat-reader-sidebar--window-size-ratio (window &optional kind)
  "返回 WINDOW 相对 frame 的尺寸比例（按 KIND 方位取宽或高）.
KIND 省略时读 WINDOW 的 `seshat-reader-sidebar-kind' window parameter（读不到
则按信息栏方位）。左右分栏取 `window-total-width' / `frame-width'，底部模式取
`window-total-height' / `frame-height'。WINDOW 非法、尺寸非正数或 frame 尺寸
异常（含为 0）时返回 nil（调用方跳过该窗口）。"
  (let* ((kind (or kind
                   (ignore-errors
                     (window-parameter window 'seshat-reader-sidebar-kind))))
         (horizontal (seshat-reader-sidebar--horizontal-p kind))
         (total (ignore-errors
                  (if horizontal
                      (window-total-width window)
                    (window-total-height window))))
         (frame-total (ignore-errors
                        (if horizontal (frame-width) (frame-height)))))
    (when (and (numberp total) (> total 0)
               (numberp frame-total) (> frame-total 0))
      (/ (float total) (float frame-total)))))

(defun seshat-reader-sidebar--capture-state (&optional windows)
  "捕获本包面板窗口的当前**尺寸**，按 kind 记入 `seshat-reader-sidebar--state'.
WINDOWS 省略时取全部本包面板窗口（`seshat-reader-sidebar--windows'）。逐个读
窗口的 `seshat-reader-sidebar-kind' window parameter 与其当前尺寸，换算为相对
frame 的比例后写入三元条目 (KIND DIRECTION RATIO)（同 KIND 的旧值先
`assq-delete-all' 删除再 `cons'，保持零依赖的 alist 语义）。方向的选取由
`seshat-reader-sidebar--window-size-ratio' 统一决定：底部模式记**高度**比例
（`window-total-height'/`frame-height'），左右分栏记**宽度**比例
（`window-total-width'/`frame-width'）；并**同步**用
`seshat-reader-sidebar--direction' 把该尺寸的方向记进条目，使
`seshat-reader-sidebar--size-for-kind' 能在下次方位变更后判定记忆值是否仍
适用。KIND 为 nil 或比例算不出（窗口/ frame 尺寸异常）时跳过该窗口。用户
手动 resize 后的尺寸因此被记住，供下次切回该 KIND 时恢复。"
  (dolist (win (or windows (seshat-reader-sidebar--windows)))
    (let ((kind (window-parameter win 'seshat-reader-sidebar-kind))
          (ratio (seshat-reader-sidebar--window-size-ratio win)))
      (when (and kind ratio)
        (setq seshat-reader-sidebar--state
              (cons (list kind
                          (seshat-reader-sidebar--direction kind)
                          ratio)
                    (assq-delete-all kind seshat-reader-sidebar--state)))))))

(defun seshat-reader-sidebar--content-height (window)
  "返回 WINDOW 的内容高度，以**行数**（整数）表示.
实现：在 WINDOW 的 buffer 内取单行像素高——取 `line-pixel-height'（首行）与
`frame-char-height' 的**较小值**，首行像素高非正数或取不到时退回
`frame-char-height'（Markdown 标题行通常比正文行高，直接用首行高会把内容行数
低估）——再用 `window-text-pixel-size' 测量从 `point-min' 到 `point-max' 的
像素高，测量上限取 120 行（避免超长内容测量耗时），最后按单行像素高向上取整
换算为行数。任一环节失败返回 nil（调用方按最小高度处理）。"
  (ignore-errors
    (with-current-buffer (window-buffer window)
      (let* ((raw (line-pixel-height))
             (char-height (frame-char-height))
             (line-height (if (and (numberp raw) (> raw 0))
                              (min raw char-height)
                            char-height))
             (pixel (cdr (window-text-pixel-size
                          window (point-min) (point-max)
                          nil (* 120 line-height)))))
        (ceiling pixel line-height)))))

(defun seshat-reader-sidebar--fit-applicable-p (buffer &optional kind)
  "判断面板 BUFFER 是否适用「按内容自适应高度」.
KIND 省略时读 BUFFER 所在窗口的 `seshat-reader-sidebar-kind' window parameter。
判据为**三重限制**：① KIND 的方位必须**不是**左右分栏（`left' / `right' 下按
内容行数调窗高没有意义——side window 的高度恒为 frame 高度，方位按 KIND 经
`seshat-reader-sidebar--position-for-kind' 解析）；② KIND 必须是 `translate'
（批注列表固定高度、不参与自适应）；③ BUFFER 未挂载 ETAF runtime（ETAF 画布
自管 viewport，改窗口高度无意义；`etaf-runtime-for-buffer' 未定义时视为未挂
载）。"
  (let ((kind (or kind
                  (let ((win (get-buffer-window buffer t)))
                    (and win (window-parameter
                              win 'seshat-reader-sidebar-kind))))))
    (and (not (seshat-reader-sidebar--horizontal-p kind))
         (buffer-live-p buffer)
         (eq kind 'translate)
         (not (ignore-errors
                (and (fboundp 'etaf-runtime-for-buffer)
                     (etaf-runtime-for-buffer buffer)))))))

(defun seshat-reader-sidebar--fit-height-for-content (window &optional kind)
  "按内容高度调整面板 WINDOW 的高度（仅译文/解释面板）.
先经 `seshat-reader-sidebar--fit-applicable-p' 过三重限制（当前方向不是左右
分栏、KIND 必须是 `translate'、且 buffer 未挂载 ETAF runtime；KIND 省略时取
WINDOW 的 `seshat-reader-sidebar-kind' window parameter），再以
`seshat-reader-sidebar--content-height' 的行数 + 2（header-line 与余量）为
目标高度，下限为 `seshat-reader-sidebar-min-height' × `frame-height'（至少 1
行）、上限为 `seshat-reader-sidebar-max-height' × `frame-height' 向下取整
（`max-h' 与 `target' 都做 `max' 1 保底，故 frame 极小时仍至少 1 行；下限高于
上限时先按上限夹紧再保底），用 `window-resize'（DELTA 按行、忽略固定尺寸
约束）调整。
调整后把最终比例 `window-total-height'/`frame-height' 以三元条目「KIND、
方向 `height'、比例 RATIO」记入 `seshat-reader-sidebar--state'（同 KIND 先
`assq-delete-all' 再 `cons'，与 `seshat-reader-sidebar--capture-state' 的写法
一致；方向恒为 `height'——本函数只在底部模式生效——故下次切回该 KIND 且仍处
底部模式时沿用内容高度，切到左右分栏后因方向不符自动回落宽度默认值）。

只调窗口高度、**不动** buffer 与阅读窗口对象。整个函数体由 `ignore-errors'
包裹：测量或调整失败一律静默，不影响面板正常展示。"
  (ignore-errors
    (let* ((buffer (window-buffer window))
           (kind (or kind
                     (window-parameter window 'seshat-reader-sidebar-kind))))
      (when (seshat-reader-sidebar--fit-applicable-p buffer kind)
        (let* ((content (or (seshat-reader-sidebar--content-height window) 0))
               (frame-h (frame-height))
               (min-h (floor (* seshat-reader-sidebar-min-height
                                (float frame-h))))
               (max-h (max 1 (floor (* seshat-reader-sidebar-max-height
                                     (float frame-h)))))
               (target (max 1 (max (min min-h max-h)
                                   (min max-h (+ content 2)))))
               (delta (- target (window-total-height window))))
          (unless (zerop delta)
            (window-resize window delta nil t))
          (setq seshat-reader-sidebar--state
                (cons (list kind 'height
                            (/ (float (window-total-height window))
                               (float frame-h)))
                      (assq-delete-all kind seshat-reader-sidebar--state))))))))

(defconst seshat-reader-sidebar--kind-order '(outline annotations translate)
  "面板 kind 的**稳定顺序**，决定同一侧内 side window 的 slot 编号.
顺序本身只影响 slot 分配（`seshat-reader-sidebar--slot-for-kind'），不影响
显示优先级；新增 kind 时追加到表尾即可（不影响已有 kind 的 slot）。")

(defun seshat-reader-sidebar--kinds-on-side (side)
  "按 `seshat-reader-sidebar--kind-order' 顺序返回方位在 SIDE 侧的 kind 列表.
SIDE 为 `left' / `right' 时筛选该侧的 kind；为 nil（底部模式）时返回全部方位
在底部的 kind。供 `seshat-reader-sidebar--slot-for-kind' 分配 slot 与测试
使用。"
  (let (kinds)
    (dolist (kind seshat-reader-sidebar--kind-order)
      (when (eq (seshat-reader-sidebar--position-side kind) side)
        (push kind kinds)))
    (nreverse kinds)))

(defun seshat-reader-sidebar--slot-for-kind (kind)
  "返回 KIND 在 side window 上使用的 slot 号.
同一侧内的 kind 按 `seshat-reader-sidebar--kind-order' 顺序编号（从 0 起），
不同侧**各自从 0 开始**：默认方位（目录左、信息右）下 `outline' 为 0，
`annotations' 为 0、`translate' 为 1。故**同一 kind 每次得到同一 slot**（重复
显示复用同一 side window，不重建、不影响用户手动调的尺寸），**不同 kind 得到
不同 slot**（三 kind 共存、互不顶替；显示/关闭一个 kind 不会顶掉其它 kind 的
窗口）。不在 kind 顺序表中的未知 kind 排在已知 kind 之后（slot = 该侧已知
kind 数）。

slot 数量上限由 `window-sides-slots' 控制（本机 Emacs 31.1 默认
`(nil nil nil nil)'，即不限）；若用户把某侧上限设为较小的整数，超出上限的
slot 会被 `display-buffer-in-side-window' 拒绝而回落为普通窗口，此时需调大该
侧上限或把某个 kind 改到底部模式。底部模式下 slot 不参与显示，返回值仅为占
位。"
  (let ((kinds (seshat-reader-sidebar--kinds-on-side
                (seshat-reader-sidebar--position-side kind)))
        (slot 0))
    (while (and kinds (not (eq (car kinds) kind)))
      (setq slot (1+ slot))
      (setq kinds (cdr kinds)))
    slot))

;;; 承载分派（window vs childframe）

;; 面板有两种**承载单元**：window（side window / 底部窗口，参与窗口树）与
;; child frame（覆盖在父 frame 右上角，不参与窗口树）。两类单元的 kind 标记、
;; 内容 buffer、关闭原语各不相同，而上层逻辑（toggle / 关闭 / 生命周期）只关心
;; 「有哪些面板、各自是什么 kind、显示的是哪个 buffer」，不关心底层是窗口还是
;; frame。故本节的访问器把差异收敛到一处：上层只经
;; `seshat-reader-sidebar--panels' 与它的三个访问器工作，新增或回退承载后端时
;; 不必改动上层逻辑，也不会漏改某条关闭路径。

(defun seshat-reader-sidebar--carrier-for-kind (kind)
  "返回 KIND 实际使用的承载方式，取值为 `childframe' 或 `window'.
三层优先级，从高到低：

1. **非图形终端强制窗口**：`display-graphic-p' 为 nil（batch、终端 frame）时
   一律返回 `window'——child frame 只存在于图形终端，此时若返回 `childframe'
   会让上层去建一个永远不显示的 frame。
2. **per-kind 覆盖**：`seshat-reader-panel-carrier-alist' 命中 KIND 时取其值
   （批注列表默认走窗口承载，理由见该变量的 docstring）。
3. **全局默认**：未命中时取 `seshat-reader-panel-carrier'。

前两层任一层给出非法取值（不是 `childframe' / `window' 的符号）时**静默回落
`window'**，不发 `message'：承载方式由用户配置决定，配置写错时每次显示/刷新都
刷一条警告只会淹没真正的错误，而窗口承载是既有行为、必然可用。"
  (cond
   ((not (display-graphic-p)) 'window)
   (t (let ((carrier (or (alist-get kind seshat-reader-panel-carrier-alist)
                         seshat-reader-panel-carrier)))
        (if (memq carrier '(childframe window)) carrier 'window)))))

(defun seshat-reader-sidebar--panels ()
  "返回本包当前全体**承载单元**（window 或 child frame）的列表.
承载单元是「显示某个面板内容的那个东西」：窗口承载时是带
`seshat-reader-sidebar' window parameter 的窗口（判定与
`seshat-reader-sidebar-window-p' 一致），frame 承载时是带
`seshat-reader-panel-kind' frame parameter 的 child frame。上层只经本函数与
`seshat-reader-sidebar--panel-kind' / `--panel-buffer' / `--panel-close'
访问承载单元，故「同 kind 是否已显示」「关掉这个 kind」这类判断不必各自区分
两类承载单元，新增后端也只需扩展本函数与那几个访问器。

当前只实现窗口后端（返回值与 `seshat-reader-sidebar--windows' 完全一致）；
frame 后端尚未实现，故其承载单元暂时不在本列表中。"
  (seshat-reader-sidebar--windows))

(defun seshat-reader-sidebar--panel-kind (panel)
  "返回承载单元 PANEL 的面板 kind（`outline' / `annotations' / `translate'）.
窗口承载读 window parameter `seshat-reader-sidebar-kind'（由
`seshat-reader-sidebar--display-params' 设置）；frame 承载读 frame parameter
`seshat-reader-panel-kind'（由 childframe 后端在建 frame 时设置）。两个
parameter 名不同是历史原因（window 侧的名字已被既有测试与配置依赖，不宜改
名），本访问器负责屏蔽这一差异。PANEL 既非窗口也非 frame（含已死 frame 对象）
时返回 nil，判据是 `windowp' / `framep'。"
  (cond
   ((windowp panel) (window-parameter panel 'seshat-reader-sidebar-kind))
   ((framep panel) (frame-parameter panel 'seshat-reader-panel-kind))
   (t nil)))

(defun seshat-reader-sidebar--panel-buffer (panel)
  "返回承载单元 PANEL 当前显示的面板 buffer，没有则返回 nil.
窗口承载取该窗口的 buffer；frame 承载取该 frame 选中窗口的 buffer（child
frame 只含一个窗口，即 `display-buffer-in-child-frame' 建出的那个）。frame 已
死（`frame-live-p' 为 nil）或没有选中窗口时返回 nil——此处**必须**显式守卫：
`(window-buffer nil)' 的含义是「当前选中窗口」，放任 nil 透传会把不相干 buffer
当成面板内容。上层用本访问器替代「直接 `window-buffer'」，关闭判据与
`--last-buffers' 记忆的刷新才能同时兼容两类承载单元。"
  (cond
   ((windowp panel) (window-buffer panel))
   ((and (framep panel) (frame-live-p panel))
    (let ((win (frame-selected-window panel)))
      (and (windowp win) (window-buffer win))))
   (t nil)))

(defun seshat-reader-sidebar--panel-for-kind (kind &optional panels)
  "返回承载单元列表中 kind 标记等于 KIND 的第一个单元，没有则返回 nil.
PANELS 省略时取 `seshat-reader-sidebar--panels'；KIND 为 nil 时匹配 kind 标记
为 nil 的单元。遍历与返回语义与 `seshat-reader-sidebar--window-for-kind' 逐字
对应，区别只在于它作用于**两类**承载单元——「该 kind 的面板是否已显示」因此
不再隐含「承载单元一定是窗口」的假设（childframe 承载时同样成立）。"
  (let ((rest (or panels (seshat-reader-sidebar--panels)))
        found)
    (while (and rest (null found))
      (when (eq (seshat-reader-sidebar--panel-kind (car rest)) kind)
        (setq found (car rest)))
      (setq rest (cdr rest)))
    found))

(defun seshat-reader-sidebar--panel-close (panel)
  "关闭承载单元 PANEL，忽略关闭过程中的错误.
窗口承载走 `delete-window'（与既有关闭路径一致：只删本包面板窗口，不动其它
窗口）；frame 承载走 `delete-frame'（父 frame 被删除时其 child frame 由 Emacs
自动清理，本函数无需额外处理）。两类原语都包 `ignore-errors'：面板可能已被
用户手工关掉（`q' / `delete-other-frames'），此时关闭是幂等操作，不该把
「窗口或 frame 已不存在」变成用户可见的错误。PANEL 既非窗口也非 frame 时什么
也不做。"
  (cond
   ((windowp panel) (ignore-errors (delete-window panel)))
   ((framep panel) (ignore-errors (delete-frame panel)))))

(defun seshat-reader-sidebar--display-params (&optional kind select)
  "生成 `display-buffer' 的弹出 action list.
第一个元素是按 **KIND 的方位**（`seshat-reader-sidebar--position-for-kind'）
分派出的**动作函数**，其余元素是交给它的 action alist：

- `below-selected' → `(display-buffer-below-selected)'（保持既有行为）；
- `at-bottom' → `(display-buffer-at-bottom)'（保持既有行为）；
- `left' / `right' → 动作函数 `(display-buffer-in-side-window)'，并在 alist
  里带 `(side . left|right)' 与 `(slot . N)'——side window 由 Emacs 维护独立
  窗口树，同侧同 slot 复用，故阅读区不会被逐次分割挤压。N 由
  `seshat-reader-sidebar--slot-for-kind' 按 kind 分配（同侧有多个 kind 时各占
  一个 slot，见该函数）。

**side / slot 必须放在顶层 alist**：`display-buffer' 只把 `(cdr ACTION)' 整体
当作 ALIST 传给动作函数（`(car FUNCTION)' 之后逐项 `funcall'），不会把动作函数
元素内自带的 alist 合进来；因此 `(side . ...)' 不能写成
`(display-buffer-in-side-window (side . ...))' 的元素内参数，否则会退化为
`display-buffer-in-side-window' 的默认 `bottom' 侧。`display-buffer' 的
docstring 也把 `side' / `slot' 列为 action alist 项，与 `window-height' 同级。

alist 中的尺寸项按**方向**取键（见 `seshat-reader-sidebar--size-key'）：左右
分栏用 `(window-width . WIDTH)'，底部模式用 `(window-height . HEIGHT)'；值取
KIND 的记忆尺寸（`seshat-reader-sidebar--size-for-kind'，无记忆时回落到方向
默认值）。宽度/高度都可以是**小数**——`window--display-buffer' 对小数按
frame 根窗口总宽/总高换算，对整数则直接当作列数/行数。alist 另携带
`(window-parameters . PARAMS)'，PARAMS 同时含面板判据
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
  (append (pcase (seshat-reader-sidebar--position-for-kind kind)
            ('at-bottom '((display-buffer-at-bottom)))
            ((or 'left 'right)
             (list (list 'display-buffer-in-side-window)
                   (cons 'side (seshat-reader-sidebar--position-side kind))
                   (cons 'slot (seshat-reader-sidebar--slot-for-kind kind))))
            (_ '((display-buffer-below-selected))))
          (list (cons (seshat-reader-sidebar--size-key kind)
                      (seshat-reader-sidebar--size-for-kind kind))
                (cons 'window-parameters
                      (list (cons 'seshat-reader-sidebar t)
                            (cons 'seshat-reader-sidebar-kind kind))))
          (when (and select seshat-reader-sidebar-select-window)
            (list (cons 'post-command-select-window t)))))

(defun seshat-reader-sidebar--display (buffer kind &optional select)
  "把 BUFFER 显示到信息面板并返回窗口.
显示经 `display-buffer' 与 `seshat-reader-sidebar--display-params' 完成，以保证
幂等。KIND 既用于记录（供 `seshat-reader-sidebar-toggle' 恢复时使用），也决定
面板窗口的 kind 标记与**per-kind 尺寸记忆**：

1. 先 `seshat-reader-sidebar--capture-state' 捕获现有本包窗口的实测尺寸
   （用户可能刚 resize 过）——**必须**在关闭任何窗口之前完成；
2. **同 kind 已在目标侧**：本包窗口中找到 kind 等于 KIND 的那个、**且位于该
   kind 方位对应的侧**（side window 的侧由
   `seshat-reader-sidebar--position-side' 给出；底部模式下两者都是 nil）→
   直接 `display-buffer' 复用（幂等，不动用户手动调整的尺寸）；
3. **只重建目标 kind**：该 kind 的旧窗口侧已变化（例如运行中把方位从
   `right' 改成 `left'）→ 关闭**该 kind** 的窗口后按 KIND 的记忆尺寸新建；
   其它 kind 的窗口**一律保留**——三 kind 共存时显示目录不会关掉批注/译文；
4. 无该 kind 的窗口 → 按 KIND 的记忆尺寸新建（slot 由 kind 决定，故不会顶替
   同侧其它 kind 的窗口）。

尺寸语义随 KIND 方位变化（见 `seshat-reader-sidebar--display-params'）：底部
模式为高度，左右分栏为宽度。

显示之后按内容自适应高度：`display-buffer' 的返回值（窗口）交给
`seshat-reader-sidebar--fit-height-for-content'，由它自行判三重限制
（该 kind 方位不是左右分栏、KIND=`translate'、buffer 未挂载 ETAF runtime）后
调整高度并把实测比例写入 `seshat-reader-sidebar--state'；批注列表因此恒为固
定高度，左右分栏下自适应整体停用，不受影响。

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
`seshat-reader-sidebar--last-buffer'，并按 KIND 记入
`seshat-reader-sidebar--last-buffers'（供 `seshat-reader-sidebar-toggle' 按
kind 定向重开）。"
  (setq seshat-reader-sidebar--last-kind kind
        seshat-reader-sidebar--last-buffer buffer)
  (when kind
    (setq seshat-reader-sidebar--last-buffers
          (cons (cons kind buffer)
                (assq-delete-all kind seshat-reader-sidebar--last-buffers))))
  (let* ((params (seshat-reader-sidebar--display-params kind select))
         (windows (seshat-reader-sidebar--windows))
         (side (seshat-reader-sidebar--position-side kind))
         (existing (seshat-reader-sidebar--window-for-kind kind windows))
         (same (and existing
                    (eq (window-parameter existing 'window-side) side)))
         (display-buffer-overriding-action (cons (caar params) (cdr params))))
    (seshat-reader-sidebar--capture-state windows)
    (unless same
      ;; 只关闭**目标 kind** 的旧窗口：同一时刻每个 kind 至多占一个窗口，其它
      ;; kind 的窗口必须保留（三 kind 共存的基础语义）。
      (dolist (win windows)
        (when (eq (window-parameter win 'seshat-reader-sidebar-kind) kind)
          (ignore-errors (delete-window win)))))
    (let ((window (display-buffer buffer)))
      (seshat-reader-sidebar--fit-height-for-content window kind)
      window)))

(defun seshat-reader-sidebar-buffer-p (buffer)
  "判断 BUFFER 是否本包信息面板的 buffer.
BUFFER 可以是 buffer 对象或 buffer 名（字符串），其它类型返回 nil。判定**只
按名字**进行，不检查 major-mode 或 window parameter，故对尚未显示的 buffer
同样有效（popper 登记 popup 时 buffer 可能还没被显示）。三种面板 buffer 名：

- 批注列表：精确等于 `seshat-reader-sidebar--annotation-buffer-name'；
- 译文/解释：精确等于 `seshat-reader-sidebar-translate-buffer-name'；
- 目录：匹配 `seshat-reader-sidebar--outline-buffer-regexp'（目录 buffer 名
  带源文件名，是**动态**的，无法精确匹配）。

供 popper 的分流使用。"
  (let ((name (cond ((bufferp buffer) (buffer-name buffer))
                    ((stringp buffer) buffer)
                    (t nil))))
    (and name
         (or (member name (list seshat-reader-sidebar--annotation-buffer-name
                                seshat-reader-sidebar-translate-buffer-name))
             (string-match-p seshat-reader-sidebar--outline-buffer-regexp name))
         t)))

(defun seshat-reader-sidebar--kind-for-buffer-name (name)
  "按 buffer 名 NAME 推断面板 kind.
推断顺序**必须**是：先 `translate'（精确匹配
`seshat-reader-sidebar-translate-buffer-name'），再 `outline'（匹配
`seshat-reader-sidebar--outline-buffer-regexp'），最后回落到 `annotations'。
顺序很关键：目录 buffer 名带源文件名，若先判 `annotations' 兜底则 outline
会被误判为批注面板（popper 重开目录时按批注 kind 恢复高度/尺寸即错）。

NAME 为 nil 或非字符串时同样回落到 `annotations'（批注列表是默认面板）。"
  (cond
   ((equal name seshat-reader-sidebar-translate-buffer-name) 'translate)
   ((and (stringp name)
         (string-match-p seshat-reader-sidebar--outline-buffer-regexp name))
    'outline)
   (t 'annotations)))

(defun seshat-reader-sidebar-display-buffer (buffer alist)
  "显示本包面板 BUFFER 并返回窗口（供 popper 的 `display-function' 分流）.
popper 重开 popup 时用裸 `display-buffer'（`popper-open-latest'），会命中它在
`display-buffer-alist' 表头插入的规则而漂移为 bottom side window；本函数让 popper
改走本包显示路径，使「首次显示」与「popper 开→关→重开」布局一致（位置、尺寸、
per-kind 尺寸记忆、`seshat-reader-sidebar' 窗口参数全部保留）。

KIND 按 buffer 名推断，三分支（见
`seshat-reader-sidebar--kind-for-buffer-name'，与
`seshat-reader-sidebar-buffer-p' 的判定口径一致）：译文/解释面板 → `translate'，
目录面板 → `outline'，其余 → `annotations'。随后调用
`seshat-reader-sidebar--display' 显示并返回其窗口。

所有 KIND 都传 SELECT=t：popper 重开是显式用户动作、且 buffer 内容早已就绪，
故与常态渲染路径一致地跟随光标（T10 第 1 轮反馈：用户要求译文面板也跟随，
一致性优先）。是否真正跟随仍受 `seshat-reader-sidebar-select-window' 约束。

ALIST 被忽略：面板布局参数一律由本包决定，不接受调用方覆盖；保留该参数只为
兼容 `display-buffer' 动作函数的签名（popper 以 `(BUFFER ALIST)' 调用）。"
  (ignore alist)                        ; 面板布局由本包决定，ALIST 不参与
  (let* ((name (cond ((bufferp buffer) (buffer-name buffer))
                     ((stringp buffer) buffer)))
         (kind (seshat-reader-sidebar--kind-for-buffer-name name))
         (target (or (and (bufferp buffer) buffer)
                     (and name (get-buffer name))
                     buffer)))
    (seshat-reader-sidebar--display target kind t)))

(defun seshat-reader-sidebar-show (buffer kind &optional select)
  "把 BUFFER 显示到信息面板的统一入口，返回窗口.
批注列表与译文/解释面板都经本函数显示：批注列表由
`seshat-reader-annotation--render-list' 调用；译文/解释由
`seshat-reader-translate--render-panel' 写入 Markdown 文本 buffer 后调用（kind
为 `translate'）；目录面板由 `seshat-reader-outline-show' 调用（kind 为
`outline'）。只有 `pop' / `pin' 两条 posframe 回退路径不经本函数。
KIND 决定三件事：① 面板窗口的 kind 标记；② **该 kind 的方位**（`outline' 用
`seshat-reader-outline-sidebar-position'，其余用
`seshat-reader-sidebar-position'，见
`seshat-reader-sidebar--position-for-kind'）；③ **该 kind 的尺寸记忆**（显示前
先捕获现有窗口实测尺寸，按各自方位取宽或高）。**不同 kind 各自独立**：显示
`outline' 不会关闭或重排已显示的 `annotations' / `translate' 窗口；同一 kind
重复显示不重建窗口。显示后**译文/解释面板**还会按内容自适应高度
（`seshat-reader-sidebar--fit-height-for-content'，上限
`seshat-reader-sidebar-max-height'，仅在该 kind 处于底部模式时生效）；批注列
表与目录面板固定尺寸。
`seshat-reader-sidebar-enabled' 为真时走 `seshat-reader-sidebar--display'；
否则退回 `pop-to-buffer'（保证禁用时行为可回退）。

SELECT 非 nil 表示「面板内容已就绪，可以跟随光标」：批注列表与译文/解释面板
都在**内容写入 buffer 之后**调用本函数，故都传非 nil（是否真正跟随仍受
`seshat-reader-sidebar-select-window' 约束）。T10 首轮反馈前这里按 KIND 硬编码
（只对批注面板传非 nil），导致译文面板永远不跟随光标。"
  (if seshat-reader-sidebar-enabled
      (seshat-reader-sidebar--display buffer kind select)
    (pop-to-buffer buffer)))

(defun seshat-reader-sidebar-close-buffer-kind (kind buffer)
  "Close the sidebar window of KIND that is displaying BUFFER.
KIND is a panel content type (`outline' / `annotations' / `translate'), BUFFER
is a buffer object or a buffer name.  Only windows whose
`seshat-reader-sidebar-kind' window parameter equals KIND **and** whose
`window-buffer' is BUFFER are handled: panels of other kinds are untouched,
and neither is a panel of the same kind showing a different buffer.  Before
closing, the dimensions of the matching windows are captured by
`seshat-reader-sidebar--capture-state' (so a user resize survives), then
`delete-window' runs inside `ignore-errors' (the window may be the frame's
last non-side window, or already deleted).

The KIND entry is also dropped from `seshat-reader-sidebar--last-buffers'
\(and from `seshat-reader-sidebar--last-buffer' / `--last-kind') when it
points at BUFFER, so `seshat-reader-sidebar-toggle' (\\[seshat-reader-sidebar-toggle-outline])
cannot resurrect the removed panel by re-displaying a buffer whose document
is gone.

Deliberately **not** implemented on top of `seshat-reader-sidebar-toggle':
`toggle' re-opens a panel when no window of that kind exists, which is the
opposite of what a cleanup needs."
  (let ((buffer (if (bufferp buffer) buffer (get-buffer buffer))))
    (when (buffer-live-p buffer)
      (let (targets)
        (dolist (win (seshat-reader-sidebar--windows))
          (when (and (eq (window-parameter win 'seshat-reader-sidebar-kind) kind)
                     (eq (window-buffer win) buffer))
            (push win targets)))
        (when targets
          (seshat-reader-sidebar--capture-state targets)
          (dolist (win targets)
            (ignore-errors (delete-window win))))
        ;; 记忆里的死面板必须一并清掉，否则
        ;; `seshat-reader-sidebar-toggle-outline' 会拿它复活。
        (when (eq (cdr (assq kind seshat-reader-sidebar--last-buffers)) buffer)
          (setq seshat-reader-sidebar--last-buffers
                (assq-delete-all kind seshat-reader-sidebar--last-buffers)))
        (when (eq seshat-reader-sidebar--last-buffer buffer)
          (setq seshat-reader-sidebar--last-buffer nil
                seshat-reader-sidebar--last-kind nil))))))

(defun seshat-reader-sidebar--toggle-kind (kind)
  "**只**开或**只**关 kind 为 KIND 的面板窗口，其它 kind 不受影响.
KIND 有窗口时：先 `seshat-reader-sidebar--capture-state' 记住这些窗口的实测
尺寸，再逐个 `delete-window'，并把 buffer 按 KIND 记入
`seshat-reader-sidebar--last-buffers'。KIND 无窗口时：用
`seshat-reader-sidebar--last-buffers' 中该 KIND 的记忆 buffer 重新显示（按其
记忆尺寸恢复、允许跟随光标）；没有可恢复的 buffer 时只提示，不做任何窗口
操作。"
  (let ((windows (seshat-reader-sidebar--windows))
        targets)
    (dolist (win windows)
      (when (eq (window-parameter win 'seshat-reader-sidebar-kind) kind)
        (push win targets)))
    (if targets
        (progn
          (seshat-reader-sidebar--capture-state targets)
          (dolist (win targets)
            (let ((buffer (window-buffer win)))
              (when (buffer-live-p buffer)
                (setq seshat-reader-sidebar--last-buffer buffer
                      seshat-reader-sidebar--last-buffers
                      (cons (cons kind buffer)
                            (assq-delete-all
                             kind seshat-reader-sidebar--last-buffers)))))
            (ignore-errors (delete-window win)))
          (message "Seshat Reader sidebar: 已关闭 %s 面板" kind))
      (let ((buffer (or (cdr (assq kind seshat-reader-sidebar--last-buffers))
                        (and (eq kind seshat-reader-sidebar--last-kind)
                             seshat-reader-sidebar--last-buffer))))
        (if (and (bufferp buffer) (buffer-live-p buffer))
            ;; 重开是显式用户动作、内容已就绪 → 允许跟随光标。
            (seshat-reader-sidebar-show buffer kind t)
          (message "Seshat Reader sidebar: %s 面板还没有可恢复的内容" kind))))))

(defun seshat-reader-sidebar-toggle (&optional kind)
  "开或关本包的信息面板.
KIND 为 nil 时保持**全部开合**语义（向后兼容）：有本包窗口时全部关闭，无窗口
时重开最近一个面板。KIND 非 nil（`annotations' / `translate' / `outline'）时
**只**处理该 kind 的面板窗口，其它 kind 的面板保持不变（见
`seshat-reader-sidebar--toggle-kind'）——这是「三 kind 共存、互不影响」的开合
保证。

关闭时先用 `seshat-reader-sidebar--capture-state' 记住各面板窗口的实测尺寸
（保证用户 resize 后的尺寸被记住），再把目标面板窗口逐个 `delete-window'
（用 `ignore-errors' 包裹；左右分栏的 side window 同样可被 `delete-window'
删除——`delete-window' 只拒绝删除 frame 上最后一个非 side 窗口，故 side 模式下
关闭逻辑与底部模式一致），并把窗口 buffer 记入
`seshat-reader-sidebar--last-buffer' 与 `seshat-reader-sidebar--last-buffers'；
打开时按最近一次的类型（`seshat-reader-sidebar--last-kind'）重新显示（按其记
忆尺寸恢复），若无可恢复的 buffer 则提示先打开批注列表或译文。
**不使用 `window-toggle-side-windows'**：
它是 frame 级全量开关，会连带删除/恢复 eca-chat 与 which-key 的侧窗，跨包
副作用不可接受。"
  (interactive)
  (if kind
      (seshat-reader-sidebar--toggle-kind kind)
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
          (message
           "Seshat Reader sidebar: 先打开批注列表（C-c C-l）或译文再切换"))))))

(defun seshat-reader-sidebar-toggle-outline ()
  "收起或展开阅读器的**目录面板**（kind 为 `outline'）.
等价于 `(seshat-reader-sidebar-toggle \\='outline)`：只开合目录面板，右侧批注
/译文面板保持不变。不再默认绑键（阅读 buffer 的 `o' 已覆盖目录开合），命令
本身仍可经 \\[seshat-reader-sidebar-toggle-outline] 调用。"
  (interactive)
  (seshat-reader-sidebar-toggle 'outline))

;;; 键位

;; `C-c C-o' 曾绑到 `seshat-reader-sidebar-toggle-outline'，与阅读 buffer 的
;; `o'（`seshat-reader-outline-show'）功能重复，用户要求移除；命令本身仍可 M-x 调用。
;; 本模块仍不 require `seshat-reader'（模块零依赖），本文件因此不再有键位注册代码。

(provide 'seshat-reader-sidebar)
;;; seshat-reader-sidebar.el ends here
