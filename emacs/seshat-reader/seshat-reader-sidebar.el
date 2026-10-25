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
;; **两类承载后端**：显示前经 `seshat-reader-panel-carrier' 与逐 kind 覆盖表
;; `seshat-reader-panel-carrier-alist' 解析承载方式后分派。child frame **打开
;; 即固定尺寸**（父 frame 宽高之比 `seshat-reader-panel-width' / `-height'，
;; 距右上边缘 `seshat-reader-panel-margin' 像素），覆盖在父 frame 右上角且
;; **不参与窗口树**——显示 / 刷新 / 滚动都不改变阅读窗口尺寸，多面板经
;; `--cf-position' 纵向堆叠；非图形环境（`display-graphic-p' 为 nil）强制回退
;; 窗口承载。`seshat-reader-sidebar-quit' 按**承载单元**关闭：窗口走
;; `delete-window'、child frame 走 `delete-frame'。
;;
;; 本文件是**本仓库自研扩展**：从上游 vendor 重拷 seshat-reader 时应保留本
;; 文件、不得覆盖（vendor 边界见同目录 VENDORED.md）。

;;; Code:

;; 本模块零依赖（不 `require' `seshat-reader'），但键位要注册到阅读器的
;; `seshat-reader-mode-map' 上。此处声明只为消除字节编译的「reference to free
;; variable」告警；运行时该变量由文末 `with-eval-after-load' 保证（只在
;; `seshat-reader' 加载完成后才注册键位，故届时它必然已定义）。
(defvar seshat-reader-mode-map)

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
手动 resize 后的尺寸因此被记住，供下次切回该 KIND 时恢复。

**只捕获窗口单元**：签名不变（WINDOWS 可以是
`seshat-reader-sidebar--windows' 的结果，也可以是
`seshat-reader-sidebar--panels' 的混合列表），但函数体内**只处理窗口**——
child frame 的尺寸由「父 frame 像素 × 比例」固定决定，用户无法手动 resize，
记忆它既没有意义也没有恢复路径。判据用 `framep' 的反面而不是 `windowp'：上层
传入的窗口可能是包装或替身对象（测试桩即如此），用 `windowp' 当唯一判据会把
它们全部漏掉，而 frame 是唯一确定「不参与记忆」的类型。"
  (dolist (unit (or windows (seshat-reader-sidebar--windows)))
    (unless (framep unit)
      (let ((kind (ignore-errors
                    (window-parameter unit 'seshat-reader-sidebar-kind)))
            (ratio (seshat-reader-sidebar--window-size-ratio unit)))
        (when (and kind ratio)
          (setq seshat-reader-sidebar--state
                (cons (list kind
                            (seshat-reader-sidebar--direction kind)
                            ratio)
                      (assq-delete-all kind
                                       seshat-reader-sidebar--state))))))))

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

;;; childframe 后端（覆盖式承载，不参与窗口树）

;; child frame 是「不属于任何窗口树的 frame」：它浮在父 frame 之上，创建、
;; 换内容、关闭都不改动父 frame 的窗口树与其窗口尺寸。这正是本后端存在的唯一
;; 理由——阅读器版面与窗口像素尺寸耦合（`seshat-reader--refit-window' 挂在
;; `window-size-change-functions' 上），把面板做成 side window 必然压缩阅读窗
;; 口并触发重新适配，观感就是「跳一下」。本节只提供**机制**（几何计算、创建、
;; 幂等复用、关闭），分派到本后端的逻辑由上层的 carrier 判断决定。

(defun seshat-reader-sidebar--cf-size (parent kind)
  "返回 KIND 面板在父 frame PARENT 下的应有尺寸，形式为像素 (WIDTH . HEIGHT).
宽度 = `seshat-reader-panel-width' × PARENT 的像素宽，高度 =
`seshat-reader-panel-height' × PARENT 的像素高，均四舍五入为整数像素。
PARENT 的像素尺寸取不到或非正（`frame-pixel-width' / `frame-pixel-height'
返回 nil / 0，终端 frame 即如此）时返回 nil——调用方据此放弃创建 child
frame 并回退窗口承载，而不是拿 nil 去算坐标。

**面板尺寸固定、不做内容自适应**：内容长度差异极大（一行译文 vs 几十行解
释），若按内容调高，面板每次刷新都会改变遮挡区域，正好制造本方案要消除的观感
跳动；固定尺寸 + 面板窗口内部滚动可让遮挡区域全程恒定。

KIND 目前不参与计算（比例由两个全局变量决定），保留该参数只为将来支持
per-kind 比例时不必改调用点；故此处显式 `ignore' 它，避免字节编译器报「未使用
的语汇参数」。"
  (ignore kind)                         ; 见 docstring：仅为将来 per-kind 比例预留
  (let ((width (ignore-errors (frame-pixel-width parent)))
        (height (ignore-errors (frame-pixel-height parent))))
    (when (and (numberp width) (> width 0)
               (numberp height) (> height 0))
      (cons (round (* width seshat-reader-panel-width))
            (round (* height seshat-reader-panel-height))))))

(defun seshat-reader-sidebar--cf-position (parent kind existing)
  "返回 KIND 面板相对父 frame PARENT 左上角的像素位置，形式为 (LEFT . TOP).
EXISTING 是**已存在面板的像素高度列表**（整数列表，不是 frame 对象——纯数据
入参才能在无 GUI 的 batch 下断言）。计算公式：

  LEFT = PARENT 像素宽 - 面板像素宽 - `seshat-reader-panel-margin'
  TOP  = margin + Σ(EXISTING 中每个高度 + margin)

即所有面板都贴父 frame **右边缘**、从上往下纵向堆叠：最上面一个只留 margin
作上边距，每多一个已存在面板就再下移「该面板高度 + margin」，故多个 kind 的
面板（目录 + 译文）同时显示时**互不遮挡**——这是多面板共存的前提，否则后来者
会完全盖住先来者。EXISTING 为 nil 时 TOP 就是 margin。

EXISTING 中的非数值与非正项被跳过（不占位）：调用方从 `frame-pixel-height'
取值，个别 frame 取不到时会得到 nil，不能让它把 TOP 算成 NaN。

PARENT 尺寸异常或面板尺寸算不出（见 `seshat-reader-sidebar--cf-size'）时返回
nil，调用方跳过定位、让 frame 停在创建时的默认位置。"
  (let ((parent-width (ignore-errors (frame-pixel-width parent)))
        (size (seshat-reader-sidebar--cf-size parent kind)))
    (when (and (numberp parent-width) (> parent-width 0) size)
      (let ((margin seshat-reader-panel-margin)
            (top seshat-reader-panel-margin))
        (dolist (height existing)
          (when (and (numberp height) (> height 0))
            (setq top (+ top height margin))))
        (cons (- parent-width (car size) margin) top)))))

(defun seshat-reader-sidebar--cf-parameters (parent kind)
  "构造 KIND 面板 child frame 的 frame parameters（alist，元素为 cons）.
PARENT 是父 frame：用它的像素尺寸反算初始宽高、用它的 default face 背景色
作面板背景。各参数的理由：

- `parent-frame'：绑定父子关系——父 frame 删除时 Emacs 自动删除子 frame，故
  本模块不需要额外的父 frame 清理逻辑；
- `undecorated' 与 `internal-border-width'：去掉窗口系统标题栏/外框（其高度
  由主题决定、不可控，会让「贴右上角」错位），改用 8 像素内边框作视觉间隔；
- `no-focus-on-map'：面板出现时**不抢**输入焦点（不打断阅读）；
  **不设** `no-accept-focus'——那个参数会让点击也无法聚焦，面板从此不能滚动、
  不能选文本复制，是本方案明确排除的取值；
- `no-other-frame' 与 `no-delete-other-frames'：`other-frame'（\\[other-frame]）
  跳过面板、`delete-other-frames' 不删面板，面板不算「用户可直接操作的
  frame」；
- `background-color'：取 PARENT 的 default face 背景色，取不到（终端 frame、
  无色主题给出 nil 或 \"unspecified-bg\"）时回退 \"#ffffff\"，避免面板用与
  阅读区不协调的默认色；
- `seshat-reader-panel-kind'：**本包面板的唯一判据**。不能用 `name'——GUI
  frame 的 name 随 buffer 名变化（目录 buffer 名还带源文件名），不足以标识
  「这个 frame 是本包的面板」；
- `width' / `height'：**字符单位**的初始尺寸，由 `--cf-size' 的像素尺寸按
  `frame-char-width' / `frame-char-height' 反算（至少 1 个字符）。它只在
  frame 创建的那一瞬间生效，`seshat-reader-sidebar--cf-place' 随后用像素级
  接口精确收口。

PARENT 尺寸取不到时（batch / 终端）宽高退化为 40 × 20 字符的占位值：这类环境
根本不会创建 frame，占位值只为让本纯函数在任何环境下都返回结构完整的 alist
（因而可在 batch 中通测）。"
  (let* ((size (seshat-reader-sidebar--cf-size parent kind))
         (char-width (max 1 (or (ignore-errors (frame-char-width parent)) 1)))
         (char-height (max 1 (or (ignore-errors (frame-char-height parent)) 1)))
         (background (ignore-errors (face-background 'default parent))))
    (list (cons 'parent-frame parent)
          (cons 'undecorated t)
          (cons 'no-focus-on-map t)
          (cons 'no-other-frame t)
          (cons 'no-delete-other-frames t)
          (cons 'internal-border-width 8)
          (cons 'background-color
                (if (and (stringp background)
                         (not (equal background "unspecified-bg")))
                    background
                  "#ffffff"))
          (cons 'seshat-reader-panel-kind kind)
          (cons 'width (if size (max 1 (/ (car size) char-width)) 40))
          (cons 'height (if size (max 1 (/ (cdr size) char-height)) 20)))))

(defun seshat-reader-sidebar--cf-frames ()
  "返回本包当前全体 child frame 面板（已死的不算）.
判据：`(frame-list)' 中 `frame-live-p' 为真、且带非 nil
`seshat-reader-panel-kind' frame parameter 的 frame。**不用**
`frame-child-frames'（本 Emacs 不存在该函数），也**不用** frame 的 `name'
（它随 buffer 名变化，见 `seshat-reader-sidebar--cf-parameters'）。"
  (let (frames)
    (dolist (frame (frame-list))
      (when (and (frame-live-p frame)
                 (frame-parameter frame 'seshat-reader-panel-kind))
        (push frame frames)))
    (nreverse frames)))

(defun seshat-reader-sidebar--cf-frame-for-kind (kind &optional frames)
  "返回本包 child frame 面板中 kind 标记等于 KIND 的那个 frame，没有则 nil.
FRAMES 省略时取 `seshat-reader-sidebar--cf-frames'。遍历与返回语义逐字对应
`seshat-reader-sidebar--window-for-kind'，供 `seshat-reader-sidebar--cf-show'
判断「同 kind 是否已显示」——命中即走幂等复用，不重建 frame。"
  (let ((rest (or frames (seshat-reader-sidebar--cf-frames)))
        found)
    (while (and rest (null found))
      (when (eq (frame-parameter (car rest) 'seshat-reader-panel-kind) kind)
        (setq found (car rest)))
      (setq rest (cdr rest)))
    found))

(defun seshat-reader-sidebar--cf-suppress-mode-line (frame)
  "抑制 child frame FRAME 的 mode-line（保留 header-line），返回其选中窗口.
实现：给该 frame 的窗口设 window parameter `mode-line-format' 为 `none'——
Emacs 手册「Window Parameters」节点的语义是「本窗口显示时不显示 mode-line，
且不影响其它窗口显示同一 buffer 时的 mode-line」，正是面板需要的粒度（不必改
buffer-local 变量，故同一 buffer 在别的窗口里显示时不受影响）。

**实测（Emacs 31.1 + pgtk GUI child frame）**：设参数前
`window-pixel-height' 700 / `window-body-height' 680 /
`window-mode-line-height' 20；设参数并 redisplay 后回读参数为 `none'、body
升到 700、mode-line 高降为 0——即本机确实支持该 window parameter，故走这条
路径，**不**回退 buffer-local `mode-line-format' 置 nil（那会连带影响其它窗口
显示同一 buffer，且需要额外的恢复逻辑）。

幂等：窗口参数重复设置无副作用，故创建路径与复用路径（同 kind frame 已存在）
都调用；取不到窗口（frame 异常 / 已死）时静默跳过。返回该窗口或 nil。"
  (let ((window (ignore-errors (frame-selected-window frame))))
    (when (windowp window)
      (ignore-errors
        (set-window-parameter window 'mode-line-format 'none)))
    window))

(defun seshat-reader-sidebar--cf-place (frame kind)
  "把已创建的 child frame FRAME 精确设置为 KIND 面板的像素尺寸与右上角位置.
父 frame 取 FRAME 的 `parent-frame' frame parameter（由
`seshat-reader-sidebar--cf-parameters' 设置）。

  ;; HACK: 为什么创建后还要再摆一次位置，而不是全靠 frame parameters：
  ;; parameters 里的 (width . W) / (height . H) 是**字符单位**，实际像素取决
  ;; 于字体度量与 fringe，无法等于「父 frame 像素宽 × 比例」；child frame 也
  ;; 不吃 `left' / `top' 参数。故创建后走像素级接口收口：
  ;; `set-frame-size' 的第三参数 PIXELWISE 非 nil 时宽高按**像素**解释，
  ;; `set-frame-position' 本身就是像素坐标。

其它本包 child frame 的像素高度作为 EXISTING 传给
`seshat-reader-sidebar--cf-position'，使多面板纵向堆叠不重叠；定位前先从列表
里排除 FRAME 自身（它此刻已带 kind 参数、已在 `--cf-frames' 中）。

任一步失败静默跳过（尺寸与定位是「更好看」，不该让面板显示整体失败），返回
FRAME。

最后一步顺手抑制该 frame 窗口的 mode-line
（`seshat-reader-sidebar--cf-suppress-mode-line'：window parameter
`mode-line-format' 置 `none'，header-line 保留）——放在此处而非创建路径，
是因为复用路径也必经本函数，故两个路径都得到同样的面板外观且幂等。"
  (let* ((parent (frame-parameter frame 'parent-frame))
         (size (and parent (seshat-reader-sidebar--cf-size parent kind)))
         (others (delq frame (seshat-reader-sidebar--cf-frames)))
         (heights (mapcar (lambda (other)
                            (ignore-errors (frame-pixel-height other)))
                          others))
         (position (and parent
                        (seshat-reader-sidebar--cf-position
                         parent kind heights))))
    (when size
      (ignore-errors (set-frame-size frame (car size) (cdr size) t)))
    (when position
      (ignore-errors (set-frame-position frame (car position) (cdr position))))
    (seshat-reader-sidebar--cf-suppress-mode-line frame)
    frame))

(defun seshat-reader-sidebar--cf-show (buffer kind &optional select)
  "在选中 frame 的右上角以 child frame 覆盖显示 BUFFER，返回被显示的 window.
返回 nil 表示**本环境无法用 child frame 承载**（选中 frame 不是图形 frame）或
创建失败，调用方据此回退窗口承载。步骤：

1. 父 frame 取 `(selected-frame)'；`display-graphic-p' 为 nil（batch、终端
   frame）时直接返回 nil——child frame 只存在于图形终端，且此处**不**自行
   降级成窗口承载（回退决策属于上层，本函数只管一种后端）。
2. **幂等复用**：同 KIND 的 child frame 已存在 → 只 `set-window-buffer' 换
   内容 + 重新定位后返回它的选中窗口。重复显示同一 kind（批注/译文刷新、流式
   输出）因此不重建 frame：不闪、不丢滚动位置。
3. 否则经 `display-buffer' 创建。action 经
   `display-buffer-overriding-action' 绑定为**点对**
   `(display-buffer-in-child-frame . ((child-frame-parameters . PARAMS)))'。
   **点对是硬要求**：`display-buffer' 只把 ACTION 的 cdr 整体当 ALIST 交给
   动作函数，写成嵌套列表 `((display-buffer-in-child-frame
   (child-frame-parameters ...)))' 会让 ALIST 变成 nil、参数全丢（frame 只会
   用默认参数建出来）。用 overriding-action 而非 ACTION 实参，是因为它优先级
   高于 `display-buffer-alist'——popper 启用时会在表头插入接管规则，普通
   action 会被它改道。
4. 创建后按像素精确收口尺寸与位置（`seshat-reader-sidebar--cf-place'）。
5. SELECT 非 nil 时把光标移入面板：`select-frame' + `select-window'。
   **不调** `select-frame-set-input-focus'：面板带 `no-focus-on-map'（出现时
   不抢焦点），再抢输入焦点与该参数语义相反，也会打断正在阅读的父 frame。"
  (let ((parent (selected-frame)))
    (when (display-graphic-p parent)
      (let ((existing (seshat-reader-sidebar--cf-frame-for-kind kind)))
        (if (and existing (frame-live-p existing))
            (let ((window (frame-selected-window existing)))
              (when (windowp window)
                (set-window-buffer window buffer))
              (seshat-reader-sidebar--cf-place existing kind)
              (when (and select (windowp window))
                (select-frame existing)
                (select-window window))
              window)
          (let* ((display-buffer-overriding-action
                  (cons 'display-buffer-in-child-frame
                        (list (cons 'child-frame-parameters
                                    (seshat-reader-sidebar--cf-parameters
                                     parent kind)))))
                 (window (display-buffer buffer)))
            (when window
              (let ((frame (window-frame window)))
                (seshat-reader-sidebar--cf-place frame kind)
                (when select
                  (select-frame frame)
                  (select-window window))))
            window))))))

(defun seshat-reader-sidebar--cf-close (frame)
  "关闭 child frame 面板 FRAME；死 frame 或非 frame 静默返回 nil.
`delete-frame' 包 `ignore-errors'：面板可能已被用户手工关掉（`q' /
`delete-other-frames' / 父 frame 关闭时连带删除），此时关闭是幂等操作，不该
把「frame 已不存在」变成用户可见的错误。父 frame 删除时其 child frame 由
Emacs 自动清理，故本函数不做额外清理。"
  (when (and (framep frame) (frame-live-p frame))
    (ignore-errors (delete-frame frame))))

;;; 承载单元访问器（--panels 与三个访问器）

(defun seshat-reader-sidebar--panels ()
  "返回本包当前全体**承载单元**（window 或 child frame）的列表.
承载单元是「显示某个面板内容的那个东西」：窗口承载时是带
`seshat-reader-sidebar' window parameter 的窗口（判定与
`seshat-reader-sidebar-window-p' 一致，见 `seshat-reader-sidebar--windows'），
frame 承载时是带 `seshat-reader-panel-kind' frame parameter 的 child frame
（见 `seshat-reader-sidebar--cf-frames'）。返回值是两者的拼接，**窗口在前、
frame 在后**——窗口是既有后端，保序使「按 kind 取第一个」在混合场景下与历史
行为一致（先命中窗口）。

两类承载单元的 kind 标记、内容 buffer、关闭原语都不同，而上层（toggle / 关闭
/ 生命周期）只关心「有哪些面板、各自什么 kind、显示的是哪个 buffer」，故差异
全部收敛在 `seshat-reader-sidebar--panel-kind' / `--panel-buffer' /
`--panel-close' 三个访问器里，上层只经本函数与它们工作。"
  (append (seshat-reader-sidebar--windows)
          (seshat-reader-sidebar--cf-frames)))

(defun seshat-reader-sidebar--panel-kind (panel)
  "返回承载单元 PANEL 的面板 kind（`outline' / `annotations' / `translate'）.
窗口承载读 window parameter `seshat-reader-sidebar-kind'（由
`seshat-reader-sidebar--display-params' 设置）；frame 承载读 frame parameter
`seshat-reader-panel-kind'（由 childframe 后端在建 frame 时设置）。两个
parameter 名不同是历史原因（window 侧的名字已被既有测试与配置依赖，不宜改
名），本访问器负责屏蔽这一差异。

判据是**严格的类型判定**（`windowp' / `framep'）：既非窗口也非 frame（含已死
frame 对象）时返回 nil。这是「类型谓词」语义，供需要区分后端的调用方使用；
**遍历匹配**（关掉/重开某个 kind 的面板）用的是
`seshat-reader-sidebar--unit-kind'——它对窗口单元的包装/替身对象兜底。"
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
`--last-buffers' 记忆的刷新才能同时兼容两类承载单元。

判据与 `seshat-reader-sidebar--panel-kind' 一致是严格类型判定；
**遍历匹配**用 `seshat-reader-sidebar--unit-buffer'（对窗口替身兜底）。"
  (cond
   ((windowp panel) (window-buffer panel))
   ((and (framep panel) (frame-live-p panel))
    (let ((win (frame-selected-window panel)))
      (and (windowp win) (window-buffer win))))
   (t nil)))

;; `--panels' 名义上只产出「窗口」与「child frame」两类承载单元，但窗口单元的
;; 包装/替身对象（例如测试里的窗口桩）并不满足 `windowp'。两个访问器
;; （`--panel-kind' / `--panel-buffer'）保持严格类型判定，以免把任意对象当成
;; 面板；而「关掉/重开某个 kind 的面板」这条路径关心的是「这个单元是哪个 kind
;; 的面板、显示的是哪个 buffer」，与它的类型无关，故另设两个**兜底**访问器：
;; 非 frame 的对象一律按窗口读取（`--panels' 不会产出其它类型的单元）。

(defun seshat-reader-sidebar--unit-kind (panel)
  "返回承载单元 PANEL 的面板 kind，对窗口替身对象兜底.
先取 `seshat-reader-sidebar--panel-kind' 的严格结果；为 nil 且 PANEL 不是
frame 时，再按窗口读 window parameter `seshat-reader-sidebar-kind'（frame 的
kind 由 frame parameter 唯一决定，不参与兜底）。PANEL 为 nil 或读不到时返回
nil。"
  (or (seshat-reader-sidebar--panel-kind panel)
      (and (not (framep panel))
           (ignore-errors
             (window-parameter panel 'seshat-reader-sidebar-kind)))))

(defun seshat-reader-sidebar--unit-buffer (panel)
  "返回承载单元 PANEL 显示的 buffer，对窗口替身对象兜底.
先取 `seshat-reader-sidebar--panel-buffer' 的严格结果；为 nil 且 PANEL 不是
frame 时，再按窗口读 `window-buffer'。frame 已死或没有选中窗口时严格访问器返回
nil，此时**不**兜底——否则会把不相干 buffer 当成面板内容。"
  (or (seshat-reader-sidebar--panel-buffer panel)
      (and (not (framep panel))
           (ignore-errors (window-buffer panel)))))

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
frame 承载走 `delete-frame'（父 frame 被删除时其 child frame 由 Emacs 自动清
理，本函数无需额外处理）；窗口承载走 `delete-window'（与既有关闭路径一致：只删
本包面板窗口，不动其它窗口）。两类原语都包 `ignore-errors'：面板可能已被用户
手工关掉（`q' / `delete-other-frames'），此时关闭是幂等操作，不该把「窗口或
frame 已不存在」变成用户可见的错误。

**按类型分流，而不是按 `windowp' 一票否决**：先判 frame（`framep'），非 frame
且「是窗口**或**是带面板 kind 标记的窗口替身」才按窗口关闭。加后半个条件是因为
窗口单元在包装/替身场景下可能不是真正的窗口对象（既有测试正是用符号/三元列表
桩替 `--windows'），只认 `windowp' 会让这些单元的关闭路径静默失效；而真正不相干
的对象既没有 kind 标记也不是窗口，仍与历史行为一致地「什么也不做」（判据用
`seshat-reader-sidebar--unit-kind'，与遍历匹配同一口径）。"
  (cond
   ((framep panel) (ignore-errors (delete-frame panel)))
   ((or (windowp panel)
        (ignore-errors (seshat-reader-sidebar--unit-kind panel)))
    (ignore-errors (delete-window panel)))))

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

(defun seshat-reader-sidebar--display-window (buffer kind &optional select)
  "把 BUFFER 显示到信息面板的**窗口后端**，返回面板窗口.
本函数是**窗口承载**的完整实现（side window / 底部窗口，参与窗口树）。承载
方式的分派与 childframe 分支、以及「childframe 建不出来就回退到本函数」的回退
决策都在 `seshat-reader-sidebar--display' 里，本函数只管一种后端；`--last-*'
一族的记忆也在分派层统一完成，此处不再重复。

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

调用前由分派层 `seshat-reader-sidebar--display' 记录
`seshat-reader-sidebar--last-kind' / `--last-buffer' 与 per-kind 的
`seshat-reader-sidebar--last-buffers'（供 `seshat-reader-sidebar-toggle' 与
`seshat-reader-sidebar--toggle-kind' 重开）。"
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

(defun seshat-reader-sidebar--display (buffer kind &optional select)
  "把 BUFFER 显示到信息面板并返回承载单元的窗口.
本函数是面板显示的**分派层**，两层语义：

1. **carrier 分派**：按 `seshat-reader-sidebar--carrier-for-kind' 解析出的
   承载方式分流——`childframe' 交给 `seshat-reader-sidebar--cf-show'（覆盖在
   父 frame 右上角，不参与窗口树，故不改变阅读窗口尺寸），`window' 交给
   `seshat-reader-sidebar--display-window'（side window / 底部窗口）。解析规则
   是「per-kind 覆盖 → 全局默认 → 非图形终端强制窗口」，见该函数。
2. **失败回退**：`--cf-show' 返回 nil 时说明 child frame 建不出来（父 frame 不是
   图形 frame、像素尺寸取不到、创建失败）——此时**回退窗口承载**，绝不把「面板
   显示失败」抛给调用方：终端用户与异常 GUI 环境下仍然看得到面板，最坏结果只是
   回到改动前的观感。

返回值语义（不变量）：始终返回**承载单元的窗口**。窗口后端返回面板窗口（与
`seshat-reader-sidebar--display' 改造前完全一致，签名与返回形态不变）；child
frame 后端返回该 frame 的选中窗口。调用方（`seshat-reader-sidebar-show' /
popper 的 `display-function'）只在极少数地方用到返回值，两种形态都可用。

两后端共有的状态记忆在**本层**完成（不进 `--display-window'，否则 childframe
分支就不会记录，toggle 重开会失效）：KIND 记入
`seshat-reader-sidebar--last-kind'，BUFFER 记入
`seshat-reader-sidebar--last-buffer' 与 per-kind 的
`seshat-reader-sidebar--last-buffers'。**child frame 的 buffer 同样必须记**——
否则关掉 frame 面板后没有任何重开依据。

SELECT 原样透传给选中的后端（`--cf-show' / `--display-window'），语义不变：
非 nil 表示「面板内容已就绪，可以跟随光标」，是否真正移动光标仍由后端按
`seshat-reader-sidebar-select-window' 决定。本层**不**按 KIND 猜测 SELECT。

其余语义（幂等显示、per-kind 独立、per-kind 尺寸记忆）由窗口后端在
`seshat-reader-sidebar--display-window' 内实现，本层不重复。"
  (setq seshat-reader-sidebar--last-kind kind
        seshat-reader-sidebar--last-buffer buffer)
  (when kind
    (setq seshat-reader-sidebar--last-buffers
          (cons (cons kind buffer)
                (assq-delete-all kind seshat-reader-sidebar--last-buffers))))
  (if (eq (seshat-reader-sidebar--carrier-for-kind kind) 'childframe)
      (or (seshat-reader-sidebar--cf-show buffer kind select)
          ;; child frame 建不出来（非图形 / 父 frame 异常 / 创建失败）→ 回退窗口承载
          (seshat-reader-sidebar--display-window buffer kind select))
    (seshat-reader-sidebar--display-window buffer kind select)))

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
  "Close the sidebar panel of KIND that is displaying BUFFER.
KIND is a panel content type (`outline' / `annotations' / `translate'), BUFFER
is a buffer object or a buffer name.  Only **承载单元**（窗口或 child frame）
whose `seshat-reader-sidebar--panel-kind' equals KIND **and** whose
`seshat-reader-sidebar--panel-buffer' is BUFFER are handled: panels of other
kinds are untouched, and neither is a panel of the same kind showing a
different buffer.  Before closing, the dimensions of the matching windows are
captured by `seshat-reader-sidebar--capture-state' (so a user resize
survives; child frames are skipped there — their size is fixed and not
remembered), then `seshat-reader-sidebar--panel-close' runs inside
`ignore-errors' (the window may be the frame's last non-side window, or the
unit may already be deleted).

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
        ;; 经 `--panels' 遍历而非直接 `--windows'：childframe 承载的面板同样要能
        ;; 按 kind + buffer 定向关闭（类型差异由访问器屏蔽）。
        (dolist (panel (seshat-reader-sidebar--panels))
          (when (and (eq (seshat-reader-sidebar--unit-kind panel) kind)
                     (eq (seshat-reader-sidebar--unit-buffer panel) buffer))
            (push panel targets)))
        (when targets
          (seshat-reader-sidebar--capture-state targets)
          (dolist (panel targets)
            (seshat-reader-sidebar--panel-close panel)))
        ;; 记忆里的死面板必须一并清掉，否则
        ;; `seshat-reader-sidebar-toggle-outline' 会拿它复活。
        (when (eq (cdr (assq kind seshat-reader-sidebar--last-buffers)) buffer)
          (setq seshat-reader-sidebar--last-buffers
                (assq-delete-all kind seshat-reader-sidebar--last-buffers)))
        (when (eq seshat-reader-sidebar--last-buffer buffer)
          (setq seshat-reader-sidebar--last-buffer nil
                seshat-reader-sidebar--last-kind nil))))))

(defun seshat-reader-sidebar--toggle-kind (kind)
  "**只**开或**只**关 kind 为 KIND 的面板，其它 kind 不受影响.
承载单元一律经 `seshat-reader-sidebar--panels' 取得（窗口与 child frame 混在
一起返回），故同一条逻辑对两种后端都成立。

- **关闭**：KIND 有承载单元时，先 `seshat-reader-sidebar--capture-state' 记住
  其中窗口单元的实测尺寸（frame 单元在内部被跳过——child frame 尺寸固定，不参与
  记忆），再逐个 `seshat-reader-sidebar--panel-close'（窗口走 `delete-window'、
  frame 走 `delete-frame'）。关闭前把每个单元的 buffer 记入
  `seshat-reader-sidebar--last-buffers'（并刷新
  `seshat-reader-sidebar--last-buffer'）——**frame 也必须记**，否则关掉 child
  frame 面板后没有任何重开依据。
- **打开**：无该 KIND 的承载单元时，用 `seshat-reader-sidebar--last-buffers' 中
  该 KIND 的记忆 buffer 重新显示；走 `seshat-reader-sidebar-show' 而非直接调某个
  后端——重开路径的后端（`--cf-show' / `--display-window'）由
  `seshat-reader-sidebar--display' 按 carrier 统一分派，且据此保留
  `seshat-reader-sidebar-enabled' 的回退语义与 select 契约（允许跟随光标）。
  没有可恢复的 buffer 时只提示，不做任何承载操作。"
  (let (targets)
    (dolist (panel (seshat-reader-sidebar--panels))
      (when (eq (seshat-reader-sidebar--unit-kind panel) kind)
        (push panel targets)))
    (setq targets (nreverse targets))
    (if targets
        (progn
          (seshat-reader-sidebar--capture-state targets)
          (dolist (panel targets)
            (let ((buffer (seshat-reader-sidebar--unit-buffer panel)))
              (when (buffer-live-p buffer)
                (setq seshat-reader-sidebar--last-buffer buffer
                      seshat-reader-sidebar--last-buffers
                      (cons (cons kind buffer)
                            (assq-delete-all
                             kind seshat-reader-sidebar--last-buffers)))))
            (seshat-reader-sidebar--panel-close panel))
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
KIND 为 nil 时保持**全部开合**语义（向后兼容）：有本包面板（窗口或 child
frame）时全部关闭，无面板时重开最近一个面板。KIND 非 nil（`annotations' /
`translate' / `outline'）时**只**处理该 kind 的面板，其它 kind 的面板保持不变
（见 `seshat-reader-sidebar--toggle-kind'）——这是「三 kind 共存、互不影响」的
开合保证。

全部开合分支经 `seshat-reader-sidebar--panels' 遍历承载单元（窗口与 child frame
一视同仁），关闭前先用 `seshat-reader-sidebar--capture-state' 记住**窗口**单元
的实测尺寸（保证用户 resize 后的尺寸被记住；child frame 尺寸固定，不参与记
忆），再逐个 `seshat-reader-sidebar--panel-close'：窗口走 `delete-window'（左右
分栏的 side window 同样可删——`delete-window' 只拒绝删除 frame 上最后一个非
side 窗口），frame 走 `delete-frame'。关闭后提示「已关闭 %d 个面板」——不写
「窗口」，因为承载单元可能含 child frame。buffer 记入
`seshat-reader-sidebar--last-buffer' / `--last-buffers'；打开时按最近一次的类型
（`seshat-reader-sidebar--last-kind'）重新显示（经 `seshat-reader-sidebar-show'
按 carrier 分派，childframe 后端会重开 child frame），若无可恢复的 buffer 则提
示先打开批注列表或译文。
**不使用 `window-toggle-side-windows'**：
它是 frame 级全量开关，会连带删除/恢复 eca-chat 与 which-key 的侧窗，跨包
副作用不可接受；且它对 child frame 面板完全无效。"
  (interactive)
  (if kind
      (seshat-reader-sidebar--toggle-kind kind)
    (let ((panels (seshat-reader-sidebar--panels)))
      (if panels
          (progn
            (seshat-reader-sidebar--capture-state panels)
            (dolist (panel panels)
              (let ((buffer (seshat-reader-sidebar--unit-buffer panel)))
                (when (buffer-live-p buffer)
                  (setq seshat-reader-sidebar--last-buffer buffer)))
              (seshat-reader-sidebar--panel-close panel))
            (message "Seshat Reader sidebar: 已关闭 %d 个面板"
                     (length panels)))
        (if (and (bufferp seshat-reader-sidebar--last-buffer)
                 (buffer-live-p seshat-reader-sidebar--last-buffer))
            ;; 重开是显式用户动作、内容已就绪 → 允许跟随光标。
            (seshat-reader-sidebar-show
             seshat-reader-sidebar--last-buffer
             (or seshat-reader-sidebar--last-kind 'annotations)
             t)
          (message
           "Seshat Reader sidebar: 先打开批注列表（C-c C-l）或译文再切换"))))))

(defun seshat-reader-sidebar-quit ()
  "关闭当前缓冲所在的面板；当前缓冲不是面板时退回 `seshat-reader-sidebar-toggle'.
kind 由 `seshat-reader-sidebar-buffer-p' 与
`seshat-reader-sidebar--kind-for-buffer-name' 按 buffer 名推断，因此本命令既能
从面板内部（`q'）调用，也能被阅读器 buffer 的键位复用。面板可能是窗口，也可能是
child frame：关闭统一经 `seshat-reader-sidebar--toggle-kind'（它按承载单元分派
`delete-window' / `delete-frame'）。"
  (interactive)
  (let* ((name (buffer-name (current-buffer)))
         (kind (and (seshat-reader-sidebar-buffer-p name)
                    (seshat-reader-sidebar--kind-for-buffer-name name))))
    (if kind
        (seshat-reader-sidebar--toggle-kind kind)
      (seshat-reader-sidebar-toggle))))

(defun seshat-reader-sidebar-toggle-outline ()
  "收起或展开阅读器的**目录面板**（kind 为 `outline'）.
等价于 `(seshat-reader-sidebar-toggle \\='outline)`：只开合目录面板，右侧批注
/译文面板保持不变。不再默认绑键（阅读 buffer 的 `o' 已覆盖目录开合），命令
本身仍可经 \\[seshat-reader-sidebar-toggle-outline] 调用。"
  (interactive)
  (seshat-reader-sidebar-toggle 'outline))

;;; 生命周期：切出阅读 buffer 时隐藏 child frame 面板

;; 窗口承载的面板属于某个窗口，切到别的 buffer 时它自然留在原 frame 的窗口树里
;; （用户看得见、可自行关闭），故不需要生命周期处理。child frame 覆盖浮在父 frame
;; 之上、不属于任何窗口树——用户切到非阅读 buffer（回邮件、看终端）后它会一直悬
;; 在右上角，挡住真正要看的窗口。故这里补一条「不再是阅读器 buffer 就关掉 child
;; frame 面板」的生命周期规则；面板内容留在 buffer 里，随时可 toggle 重开。

(defun seshat-reader-sidebar--hide-cf-on-buffer-change (&optional window)
  "当前 buffer 不再是阅读器 buffer 时隐藏本包 child frame 面板.
`seshat-reader-panel-hide-on-buffer-change' 为 nil 时不做事（用户可以要求面板
常驻）。否则按以下三个**早期返回**判定（本函数挂在全局
`window-buffer-change-functions' 上，每次窗口换 buffer 都会跑，故必须廉价、不得
做重活）：

1. 本包没有任何 child frame 面板 → 直接返回（**先**判这条：没有面板时连
   `derived-mode-p' 都不算，正常的 buffer 切换因此零开销）；
2. 当前 buffer（WINDOW 的 buffer，省略 WINDOW 时取当前 buffer）派生自
   `seshat-reader-mode' → 返回（仍在阅读器里，例如从 PDF 切到它自己的目录
   buffer）；
3. 其余情况 → 逐个 `seshat-reader-sidebar--cf-close' 关掉本包 child frame，并
   `message' 一句提示（**只提示一次**，不管关了几个面板）。

**为什么用 `window-buffer-change-functions' 而不是 post-command-hook**：这个
hook 在**窗口 buffer 真正变化的那一刻**触发，不需要等到命令结束再回头比较
`current-buffer'，因此不会出现「命令执行中面板已失效、界面已经闪一下」的中间
态；也不受 `this-command` 类判据的干扰。代价是它对**每个**窗口的每次换 buffer
都调用，所以上面三条早期返回是硬要求，不是优化。

WINDOW 参数由 hook 传入（也可能是手工调用，省略时按当前 buffer 判定）。"
  (when seshat-reader-panel-hide-on-buffer-change
    (let ((frames (seshat-reader-sidebar--cf-frames)))
      (when (and frames
                 (not (ignore-errors
                        (with-current-buffer (if (windowp window)
                                                 (window-buffer window)
                                               (current-buffer))
                          (derived-mode-p 'seshat-reader-mode)))))
        (dolist (frame frames)
          (seshat-reader-sidebar--cf-close frame))
        (message "Seshat 面板已随阅读器隐藏")))))

;;; 键位

;; `C-c C-o' 曾绑到 `seshat-reader-sidebar-toggle-outline'，与阅读 buffer 的
;; `o'（`seshat-reader-outline-show'）功能重复，2026-10-23 被移除；真机反馈后按
;; 用户要求恢复该键，但改绑**无参**的 `seshat-reader-sidebar-toggle`：面板开着
;; 就全部关闭，关了就重开最近一个面板——比「只开合目录」更贴近「快捷关闭」的直
;; 觉。面板内 `q'（`seshat-reader-translate-panel-map'）保持原样。
;; 本模块仍不 require `seshat-reader'（模块零依赖），故键位用
;; `with-eval-after-load' 在阅读器加载后注册，与 translate 模块的写法一致。
(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-c C-o")
    #'seshat-reader-sidebar-toggle))

;; 挂到**全局**的 `window-buffer-change-functions'（不传 LOCAL）：阅读器 buffer
;; 退出后当前 buffer 已不是阅读器 buffer，buffer-local 的钩子绑在谁身上都不对，
;; 只有全局钩子能在「切走的那一刻」看到新 buffer。`add-hook' 本身幂等（同一个
;; 函数符号不会重复入表），故文件被重新加载时不会叠加调用。
(add-hook 'window-buffer-change-functions
          #'seshat-reader-sidebar--hide-cf-on-buffer-change)

(provide 'seshat-reader-sidebar)
;;; seshat-reader-sidebar.el ends here
