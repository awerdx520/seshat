;;; seshat-reader-outline.el --- imenu and outline-mode integration for the seshat-reader  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026  Divya Ranjan Pattanaik
;; Copyright (C) 2025-2026  Tushar

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

;;; Code:

(require 'seshat-reader)
;; 承载层（面板显示）：`seshat-reader-sidebar' **零依赖**（不 require 本包任何
;; 模块），故此处 require 它不构成循环依赖（本模块被 `seshat-reader' 以 autoload
;; 引用，反过来不 require 本模块）。
(require 'seshat-reader-sidebar)
(require 'cl-lib)
(require 'imenu)
(require 'outline)

;; 本模块在 `seshat-reader-outline-mode' 里调用 `seshat-reader--disable-evil'
;; （定义在 `seshat-reader.el'，本模块顶部已 require 它）。声明一下只为在**单独
;; 字节编译**本文件时消除 byte-compile-function-not-defined 类告警。
(declare-function seshat-reader--disable-evil "seshat-reader" ())

;;; Imenu

;;;###autoload
(defun seshat-reader--outline-make-imenu-entry (plist)
  "Convert one outline PLIST to an imenu entry."
  (let* ((title (plist-get plist :title))
         (page (1+ (plist-get plist :page))) ; MuPDF does 0-indexing
         (children (plist-get plist :children)))
    (if children
        (cons title
              (mapcar #'seshat-reader--outline-make-imenu-entry children))
      (cons title page))))

;;;###autoload
(defun seshat-reader--outline-imenu-create-index ()
  "Turn `seshat-reader-current-doc-outline' into an imenu index."
  (when seshat-reader-current-doc-outline
    (mapcar #'seshat-reader--outline-make-imenu-entry
	    seshat-reader-current-doc-outline)))

;;;###autoload
(defun seshat-reader--outline-imenu-goto (_name page)
  "Switch to PAGE.

Ignores the _NAME argument.
Just wraps `seshat-reader-goto-page' for imenu compatibility."
  (seshat-reader-goto-page page))

;;; Faces（目录面板）

;; 只用 :weight / :height / :inherit，**不使用 variable-pitch**——中文标题在
;; variable-pitch 下会回退到比例字体，中英文混排会跳行距（M12 T5 明确规避）。

(defface seshat-reader-outline-level-1-face
  '((t :weight bold :height 1.1))
  "目录面板一级标题的 face（根节点）."
  :group 'seshat-reader)

(defface seshat-reader-outline-level-2-face
  '((t :weight bold))
  "目录面板二级标题的 face."
  :group 'seshat-reader)

(defface seshat-reader-outline-level-3-face
  '((t :inherit shadow))
  "目录面板三级及更深标题的 face（3 级之后统一复用本 face）."
  :group 'seshat-reader)

(defface seshat-reader-outline-page-face
  '((t :inherit shadow))
  "目录面板页码的 face（弱化，避免与标题抢视觉焦点）."
  :group 'seshat-reader)

(defface seshat-reader-outline-current-face
  '((t :inherit highlight))
  "目录面板中「当前章节」的 face（标题与页码共用）."
  :group 'seshat-reader)

(defface seshat-reader-outline-avy-label-face
  '((((class color) (background dark))
     :weight bold :foreground "#e6a700" :background "#333333")
    (((class color) (background light))
     :weight bold :foreground "#111111" :background "#ffd479")
    (t :weight bold :inverse-video t))
  "目录面板 avy 式跳转标签的 face（`seshat-reader-outline-avy-jump'）.

**不**用 `(:inherit avy-lead-face)'：avy 是软依赖（本包不 require、不进
`Package-Requires'），继承一个未加载的 face 会让标签失去配色；且 avy 的 face
由主题决定，在目录面板里可能与标题 face 混同。这里用显式配色，并按背景明暗
各给一组，保证任何主题下标签都醒目."
  :group 'seshat-reader)

;;; Outline

(defvar-local seshat-reader-outline--doc-buffername nil
  "Name of the document buffer whose outline was generated.")

(defvar-local seshat-reader-outline--doc-window nil
  "The window from where the outline was generated.")

(defun seshat-reader-outline--doc-current-page (buffer)
  "返回阅读器 BUFFER 当前显示的 1-based 页号；无法判定时返回 nil.

页号取自 `seshat-reader-current-doc-pagenumber'（窗口参数 `page'）。batch 下
（或无可见窗口、窗口参数未设置）返回 nil，调用方须按「当前章未知」处理。
本函数是 `show' 与 `--rows' 之间的适配层：前者拿真实页号，后者是无副作用
的纯函数。"
  (let ((window (get-buffer-window buffer)))
    (when (window-live-p window)
      (seshat-reader-current-doc-pagenumber window))))

;;;###autoload
(defun seshat-reader-outline-show ()
  "Toggle the document outline panel.

When the outline panel is already displayed (a panel window whose
`seshat-reader-sidebar-kind' is `outline', or — with the childframe
carrier — a child frame whose `seshat-reader-panel-kind' is `outline'
exists), this command **closes**
it through `seshat-reader-sidebar--toggle-kind', i.e. exactly the way
`seshat-reader-sidebar-toggle-outline' does (that command is no longer
key-bound, it is only reachable through
\\[seshat-reader-sidebar-toggle-outline]): the measured dimensions are
captured before the windows are deleted and the panel buffer is remembered
for the next re-open, so the panel comes back with the size the user
resized it to.  Neither `delete-window' nor the size/kind bookkeeping is
re-implemented here — duplicating them would let this path drift apart from
the sidebar's per-kind toggle.

When the panel is not displayed, its content is **rebuilt** from
`seshat-reader-current-doc-outline' for the current document and then
shown.  Key binding note: `o' is bound to `seshat-reader-outline-toggle',
which first asks `seshat-reader-sidebar-panel-visible-p' (carrier agnostic)
and closes the panel through `seshat-reader-sidebar--toggle-kind' when it is
already displayed, so only the not-displayed case reaches this command.
`o' and `seshat-reader-sidebar-toggle-outline' therefore have the same
semantics and `o' additionally refreshes the outline content of the
document being read.  The closing branches below are kept because
`M-x seshat-reader-outline-show' (and re-loading the library) must not
create a second panel.

Where point is decides the direction: from a document buffer in
`seshat-reader-mode' the key both opens and closes the panel, while from
inside the panel itself (a buffer in `seshat-reader-outline-mode') it only
closes it.  The panel branch runs **before** the mode check below, so one
press inside the panel is enough; without it the key would first move point
back into the reading window and only the second press would close.  Both
directions go through `seshat-reader-sidebar--toggle-kind' with kind
`outline', so the key stays a plain toggle and the size bookkeeping never
differs between the two sides.

The outline is displayed through `seshat-reader-sidebar-show' with kind
`outline' (and SELECT non-nil, so the panel follows the cursor like the
`seshat-reader-sidebar-toggle-outline' path), hence it obeys
`seshat-reader-outline-sidebar-position' and
`seshat-reader-outline-sidebar-width'; when
`seshat-reader-sidebar-enabled' is nil that function itself falls back to
`pop-to-buffer', so no separate fallback is needed here.

The outline buffer is named after the document it was created from and is
**rebuilt on every opening** (the closing path does not touch its content)
from `seshat-reader-current-doc-outline'.  The old code only filled an
empty buffer, so re-opening a document (or switching the document shown in
the same buffer) kept the stale entries.  Rebuilding keeps the same buffer,
so the panel window stays valid; it also reuses
`seshat-reader-outline-mode', erases with `inhibit-read-only' bound and
leaves point at the beginning of the buffer.  Both
`seshat-reader-outline--doc-buffername' and
`seshat-reader-outline--doc-window' are refreshed, so
`seshat-reader-outline-goto-entry' still jumps back into the current
reading window (the fallback inside
`seshat-reader-outline-select-doc-window' covers a dead window).

The buffer content is produced by the side-effect free
`seshat-reader-outline--rows' (line model) and then inserted by
`seshat-reader--outline-insert-outline'; the current page of the document
window is passed in so the containing section can be highlighted.

Signals `user-error' when the opening path runs in a buffer that is not in
`seshat-reader-mode', or when the document has no outline; validation
happens **before** rebuilding, so a document without outline never leaves
the panel blanked.  Neither check applies to the closing paths (point in the
panel, or a panel window already displayed) — closing never needs an
outline."
  (interactive)
  ;; 光标在目录面板里时，`o' 就是关闭（与阅读窗口里按 `o' 的 toggle 语义一致：
  ;; 否则要先按一次切回阅读窗口、再按一次才关，用户得按两次）。这条分支必须在
  ;; 「非阅读 buffer 报错」之前——面板 buffer 不是 `seshat-reader-mode'。关闭仍
  ;; 走 sidebar 的 per-kind toggle，尺寸记忆与恢复行为与
  ;; `seshat-reader-sidebar-toggle-outline' 一致。
  (if (derived-mode-p 'seshat-reader-outline-mode)
      (seshat-reader-sidebar--toggle-kind 'outline)
    (unless (derived-mode-p 'seshat-reader-mode)
      (user-error "Not in a seshat-reader-mode buffer"))
    ;; 目录面板已显示时，再按一次就是关闭（与
    ;; `seshat-reader-sidebar-toggle-outline' 的 toggle 语义一致）。
    ;; 关闭走 sidebar 的 per-kind toggle：先捕获尺寸再 delete-window，并记住
    ;; buffer 供下次重开；不在这里自己 delete-window，避免与 sidebar 的
    ;; kind/slot/尺寸记忆逻辑分叉。
    ;; 「已显示」的判据必须经 sidebar 的**承载单元**抽象
    ;; `seshat-reader-sidebar--panel-for-kind'（= 面板窗口 + child frame），
    ;; 不能用只看窗口的 `--window-for-kind'：childframe 承载时面板是 frame 而
    ;; 不是窗口，后者恒返回 nil，于是这里会误判「未显示」而重复建面板。
    (if (seshat-reader-sidebar--panel-for-kind 'outline)
        (seshat-reader-sidebar--toggle-kind 'outline)
      (let* ((outline-data seshat-reader-current-doc-outline)
             (source-buffer (current-buffer))
             (source-name (buffer-name source-buffer))
             (bufname (format "*Outline of %s*" source-name)))
        ;; 先校验再重建：文档无目录时不得把面板清成空白（否则拿不到旧内容）。
        (unless outline-data
          (user-error "This document has no outline"))
        (with-current-buffer (get-buffer-create bufname)
          (unless (derived-mode-p 'seshat-reader-outline-mode)
            (seshat-reader-outline-mode))
          ;; 每次打开都同步归属信息（`goto-entry' 靠它找回阅读窗口）。
          (setq seshat-reader-outline--doc-buffername source-name)
          (setq seshat-reader-outline--doc-window
                (get-buffer-window source-buffer))
          ;; 按当前文档重建内容：可读 buffer 须绑 `inhibit-read-only'；不 kill 也
          ;; 不重建 buffer，否则承载该 buffer 的面板窗口会失效。
          (let ((inhibit-read-only t)
                ;; 折叠态集合暂恒为 nil（全部展开）：buffer 内的 TAB 折叠由
                ;; `outline-mode' 自身的不可见性实现，不需要重建 buffer，也就不经
                ;; 本集合（详见 `seshat-reader-outline--rows' 的 docstring）。
                (collapsed nil)
                (current-page (seshat-reader-outline--doc-current-page
                               source-buffer)))
            (erase-buffer)
            (seshat-reader--outline-insert-outline
             (seshat-reader-outline--rows outline-data collapsed current-page))
            (goto-char (point-min))))
        ;; 显示交给承载层（`outline' kind：左侧/底部由 sidebar 决定）；SELECT 非
        ;; nil 与 `seshat-reader-sidebar-toggle-outline' 的重开路径一致——按 `o'
        ;; 打开目录后光标进入目录面板。
        (seshat-reader-sidebar-show (get-buffer bufname) 'outline t)))))

;;;###autoload
(defun seshat-reader-outline-toggle ()
  "目录面板开合：已显示则关闭，否则构建并显示目录.
「已显示」由 `seshat-reader-sidebar-panel-visible-p' 判定（**承载无关**：side
window / 底部窗口 / child frame 都算已显示），关闭走
`seshat-reader-sidebar--toggle-kind'——只关 `outline' 这一 kind，右侧批注/译文
面板不受影响，且关闭前捕获尺寸、记住 buffer 供重开。未显示时原样调用
`seshat-reader-outline-show'（校验 + 按当前文档重建内容 + 显示）。

与 `seshat-reader-outline-show' 的关系：`show' 自面板 per-kind 化以来**自身**
也含关闭分支（「已显示」判据 + 在面板 buffer 内按 `o' 的快捷关闭），故两者的
**可观察行为等价**；本命令存在的意义是把「已显示」的判据提到统一入口
（`seshat-reader-sidebar-panel-visible-p'），使四个开合命令形状一致（目录、批注
列表、译文、解释都是同一个 if），且键位统一指向 `-toggle' 名字，不依赖某个
`show' 命令内部恰好实现了 toggle。"
  (interactive)
  (if (seshat-reader-sidebar-panel-visible-p 'outline)
      (seshat-reader-sidebar--toggle-kind 'outline)
    (seshat-reader-outline-show)))

;;; 行模型（纯函数，无 buffer 副作用，可在 batch 下测试）

(defconst seshat-reader-outline--fold-open-symbol "▾"
  "有子节点且展开时的折叠符号.")

(defconst seshat-reader-outline--fold-closed-symbol "▸"
  "有子节点且折叠时的折叠符号.")

(defconst seshat-reader-outline--current-bar "▌"
  "当前章节行首的竖线（用 `line-prefix' 显示，不写进 buffer 文本）.")

(defconst seshat-reader-outline--page-align '(space :align-to (- right 6))
  "页码右对齐的 display 属性值.

插在标题之后、页码之前的一个空格上，把其后的页码推到窗口右边缘往左 6 列处.")

(defconst seshat-reader-outline--indent-width 1
  "目录面板每级的缩进列数.

星号前缀改为零宽显示后（见 `seshat-reader--outline-insert-outline'），每级的
视觉缩进 = 本值 × depth 个空格 + 折叠符号的 2 列，故取 1 列即够：星号不再占位，
若仍取 2 列，深层条目会明显右飘.")

(defun seshat-reader-outline--node-page (node)
  "返回 outline plist NODE 的 1-based 页号（原树 `:page' 是 0-based）.

缺 `:page' 时按第 1 页处理，避免渲染路径因数据缺字段报错."
  (1+ (or (plist-get node :page) 0)))

(defun seshat-reader-outline--level-face (depth)
  "返回目录面板深度 DEPTH（0-based）对应的标题 face.

深度 0 → `seshat-reader-outline-level-1-face'，1 → `-level-2-face'，
≥2 → `-level-3-face'（3 级之后统一复用 3 级）."
  (pcase depth
    (0 'seshat-reader-outline-level-1-face)
    (1 'seshat-reader-outline-level-2-face)
    (_ 'seshat-reader-outline-level-3-face)))

(defun seshat-reader-outline--map-tree (tree fn &optional path)
  "对 outline 树 TREE 按 DFS 前序逐节点调用 FN.

FN 收到两个参数：该节点的**行路径**（自根到该节点的标题列表）与节点 plist。
PATH 是父节点的行路径（内部递归用，调用方省略即为根层）。
TREE 的结构为 `(:title STR :page N [:children (...)]'，`:page' 为 0-based.
本函数是 `--rows' / `--current-path' 共用的遍历原语，只读不写."
  (dolist (node tree)
    (let ((node-path (append path (list (plist-get node :title)))))
      (funcall fn node-path node)
      (when-let* ((children (plist-get node :children)))
        (seshat-reader-outline--map-tree children fn node-path)))))

(defun seshat-reader-outline--current-path (tree current-page)
  "返回 TREE 中「包含 CURRENT-PAGE 的最深节点」的路径，找不到时返回 nil.

CURRENT-PAGE 为 1-based 页号（nil 表示未知，直接返回 nil）。节点的包含范围按
DFS 前序定义：从节点自身的页开始，到下一个前序节点的前一页结束，末节点延到文档
末尾（因此页号单调递增是前提）。由此可得判据——前序里「页号 ≤ CURRENT-PAGE 的
最后一个节点」就是包含该页的最深节点：前序保证祖先先于后代、相同时取后者即更
深者。返回值是自根到该节点的**标题列表**（与折叠态集合的元素同构），供
`--rows' 标记当前章，也供后续「首屏自动展开到当前章」复用."
  (when (integerp current-page)
    (let (best-page best-path)
      (seshat-reader-outline--map-tree
       tree
       (lambda (path node)
         (let ((page (seshat-reader-outline--node-page node)))
           (when (and (<= page current-page)
                      (or (null best-page) (>= page best-page)))
             (setq best-page page)
             (setq best-path path)))))
      best-path)))

(defun seshat-reader-outline--collect-rows (nodes collapsed current
                                                 depth path fn)
  "把 NODES 摊平成行并逐个传给 FN；内部递归实现，供 `--rows' 使用.

COLLAPSED / CURRENT 见 `seshat-reader-outline--rows'；DEPTH 为当前层深度
（0-based）；PATH 为父节点的行路径；FN 每收到一个行 plist 即被调用一次."
  (dolist (node nodes)
    (let* ((title (plist-get node :title))
           (node-path (append path (list title)))
           (children (plist-get node :children))
           (collapsed-p (and children (and (member node-path collapsed) t))))
      (funcall fn (list :depth depth
                        :title title
                        :page (seshat-reader-outline--node-page node)
                        :collapsed-p collapsed-p
                        :current-p (and current (equal node-path current) t)
                        :has-children (and children t)))
      (unless collapsed-p
        (when children
          (seshat-reader-outline--collect-rows
           children collapsed current (1+ depth) node-path fn))))))

(defun seshat-reader-outline--rows (tree collapsed current-page)
  "把 outline 树 TREE 摊平成目录面板的**行列表**（纯函数，不碰 buffer）.

TREE 为 `(:title STR :page N [:children (...)]' 组成的列表，页号 0-based。
COLLAPSED 为折叠态集合，元素是**行路径**——自根到该节点的标题列表，如
`(\"Chapter 1\" \"Section 1.1\")'；用路径而非标题字符串，是为了区分同名节点，
且与 `--current-path' 的返回值同构。CURRENT-PAGE 为当前页（1-based），nil 表示
未知（不标记当前章）。

返回值是按 **DFS 前序**排列的行 plist 列表，每行形如：
  `(:depth D :title STR :page N :collapsed-p BOOL
          :current-p BOOL :has-children BOOL)'
不变式：`:page' 已转 1-based（原树 +1）；根节点 `:depth' 为 0；折叠节点自身
仍在结果里（`:collapsed-p' 为 t）但其子树**不出现**；只有
`--current-path' 指到的节点 `:current-p' 为 t，该节点若位于折叠子树内则结果里
没有行被标记."
  (let ((current (seshat-reader-outline--current-path tree current-page))
        (rows nil))
    (seshat-reader-outline--collect-rows
     tree collapsed current 0 nil
     (lambda (row) (push row rows)))
    (nreverse rows)))

;;; 渲染（消费行列表，唯一有 buffer 副作用的一层）

(defun seshat-reader--outline-insert-outline (rows)
  "把 `seshat-reader-outline--rows' 产出的行列表 ROWS 插入当前 buffer.

每行 plist 的字段见 `seshat-reader-outline--rows'。渲染规则：
① 缩进：每级 `seshat-reader-outline--indent-width'（1）个空格，叠在 outline 的
星号标题前缀之后——星号**必须**留在行首的 buffer 文本里，否则 `outline-regexp'
失配、TAB 折叠（`outline-hide-subtree'）失效；但星号不该出现在视觉上，故给
星号所在区间加一个显示属性 `display`（值为空字符串）：它只影响显示，buffer 文本
不变、`outline-regexp' 照常匹配（`outline-on-heading-p' 仍为 t）、星号也不再
占显示列；星号后那一个空格保留，作为每行的固定左边距；
② 折叠符号：有子节点插 `▾'（展开）/ `▸'（折叠），无子节点插 2 空格占位对齐；
③ 标题：`insert-text-button'，保留 `seshat-reader-page' 属性与 `action'，face 按
深度取 `seshat-reader-outline--level-face'；
④ 页码：用 `seshat-reader-outline--page-align' 这个 display 属性（弹性空白）把
页码推到窗口右侧，页码 face 为 `seshat-reader-outline-page-face'；
⑤ 当前章：标题与页码用 `seshat-reader-outline-current-face'，并在行首用
`line-prefix' 加竖线 `▌'——`line-prefix' 只是显示属性、不进入 buffer 文本，
故不破坏 `outline-regexp'；非当前行加同宽空格，保证所有行缩进一致。
缓冲区的只读性由调用方负责（`inhibit-read-only'）。"
  (dolist (row rows)
    (let* ((depth (plist-get row :depth))
           (title (plist-get row :title))
           (page (plist-get row :page))
           (has-children (plist-get row :has-children))
           (collapsed-p (plist-get row :collapsed-p))
           (current-p (plist-get row :current-p))
           (title-face (if current-p
                           'seshat-reader-outline-current-face
                         (seshat-reader-outline--level-face depth)))
           (page-face (if current-p
                          'seshat-reader-outline-current-face
                        'seshat-reader-outline-page-face))
           (line-start (point)))
      ;; ① 星号前缀（outline 结构，必须留在行首的 buffer 文本里）+ ② 层级缩进
      (insert (make-string (1+ depth) ?*) " ")
      ;; 星号视觉零宽：`outline-regexp' 与 `outline-hide-subtree' 依赖行首星号
      ;; 文本，但星号本身不该被看见——`display ""' 只改显示，不改 buffer 文本，
      ;; 也不影响 `outline-regexp' 的匹配，且星号不再占显示列。
      (put-text-property line-start (+ line-start (1+ depth)) 'display "")
      (insert (make-string (* seshat-reader-outline--indent-width depth) ?\s))
      ;; ③ 折叠符号（无子节点用 2 空格占位）
      (insert (cond ((not has-children) "  ")
                    (collapsed-p (concat seshat-reader-outline--fold-closed-symbol
                                         " "))
                    (t (concat seshat-reader-outline--fold-open-symbol " "))))
      ;; ④ 标题按钮（保留原有 `seshat-reader-page' 属性与 `action'）
      (insert-text-button
       title
       'seshat-reader-page page
       'action #'seshat-reader-outline-goto-entry
       'follow-link t
       'help-echo "Jump to section."
       'face title-face)
      ;; ⑤ 页码右对齐（弹性空白 + 页码，均不进 button）
      (insert (propertize " " 'display seshat-reader-outline--page-align))
      (insert (propertize (format " %d" page) 'face page-face))
      (insert "\n")
      ;; ⑥ 当前章竖线：line-prefix 是显示属性，不改变 buffer 文本与缩进列数
      (add-text-properties
       line-start (1+ line-start)
       (list 'line-prefix
             (if current-p
                 (propertize seshat-reader-outline--current-bar
                             'face 'seshat-reader-outline-current-face)
               " "))))))

;;; avy 式跳转（目录面板内单键跳转）

;; 实现选择：**零依赖自实现**，只借 `avy-keys' 的字符表。理由（实读
;; `.local/straight/repos/avy/avy.el'）：
;; ① `avy-process'（868 行）虽是公开入口，但 overlay 渲染由全局 `avy-style'
;;    经 `avy--style-fn'（1254 行）决定——用户把 `avy-style' 设成 `ignore' 就
;;    完全不显示标签，设成 `words'/`de-bruijn' 又走另一套（`avy-read-words' /
;;    `avy-read-de-bruijn'）；它还调用 `avy--make-backgrounds'（受
;;    `avy-background' 影响，会覆盖**所有**窗口）与 `avy-pre-action'（压 mark +
;;    强制选窗口）、`avy-action'（默认 `avy-action-goto'，被用户配置改写即失去
;;    确定性）。命中后我们要做的还有 `seshat-reader-outline-goto-entry'，
;;    只能靠 let-bind `avy-action' 绕开——即「依赖 avy 的内部全局状态」。
;; ② `avy-read'（509 行）稍轻（自带 display-fn / cleanup-fn），但仍依赖全局
;;    `avy-translate-char-function' 与 `avy-handler-function'，且树必须由
;;    `avy-tree'（400 行）生成，标签只能经 `avy-traverse' 的路径还原——与本任务
;;    要求的纯函数 `--avy-labels' 重复实现同一件事。
;; 结论：两条都不满足「稳定、自包含」，故按计划走零依赖兜底；`avy-keys' 仍被
;; 读取，标签风格因此与 avy 一致。

(defconst seshat-reader-outline--avy-default-keys
  '(?a ?s ?d ?f ?g ?h ?j ?k ?l)
  "Avy 未加载（`avy-keys' 未绑定）时使用的标签字符表.

与 `avy-keys' 的默认值一致，使标签在任何环境下都是同一个风格.")

(defun seshat-reader-outline--avy-keys ()
  "返回 avy 式标签使用的字符表.

优先读 `avy-keys'（avy 已加载且取值是字符列表时），否则退回
`seshat-reader-outline--avy-default-keys'。本函数只读全局变量，**不**
require avy（软依赖：缺失时静默降级，见 `docs/configuration.md'）."
  (let ((keys (and (boundp 'avy-keys) avy-keys)))
    (if (and (consp keys) (cl-every #'characterp keys))
        keys
      seshat-reader-outline--avy-default-keys)))

(defun seshat-reader-outline--avy-labels (n &optional keys)
  "返回 N 个 avy 式标签字符串的列表（纯函数）.

KEYS 为标签字符表，省略时取 `seshat-reader-outline--avy-keys'。生成规则：
① N ≤ 0 → nil；
② N ≤ `(length KEYS)' → 每个候选 1 个字符，取 KEYS 的前 N 个；
③ N 更多 → 每个候选 2 个字符，第一个字符取 `(nth (/ I LEN) KEYS)'、第二个取
`(nth (% I LEN) KEYS)'（即「先 key1 再 key2'的组合），可覆盖 `LEN^2' 个候选.

同一批标签**等长**，因此不存在「某标签是另一标签的前缀」的冲突；候选数超过
`LEN^2' 时抛 `user-error'（当前实现不生成 3 字符标签）."
  (let* ((keys (or keys (seshat-reader-outline--avy-keys)))
         (len (length keys))
         (index 0)
         labels)
    (cond
     ((<= n 0) nil)
     ((> n (* len len))
      (user-error "Too many candidates (%d) for %d label keys" n len))
     ((<= n len)
      (while (< index n)
        (push (char-to-string (nth index keys)) labels)
        (setq index (1+ index)))
      (nreverse labels))
     (t
      (while (< index n)
        (push (concat (char-to-string (nth (/ index len) keys))
                      (char-to-string (nth (% index len) keys)))
              labels)
        (setq index (1+ index)))
      (nreverse labels)))))

(defun seshat-reader-outline--avy-candidates (start end)
  "返回 START..END 区间内目录按钮的 `(POSITION . PAGE)' 列表（纯函数）.

POSITION 是按钮起始位置（`button-start'，也是标签 overlay 的插入点），PAGE 是
按钮的 `seshat-reader-page' 属性（1-based）。调用方传可见区间（`window-start' /
`window-end'）即得「当前屏可见条目」，本函数自身不读窗口、不写 buffer，故可在
batch 下测试。没有 `seshat-reader-page' 属性的按钮（非跳转按钮）被跳过.

`next-button' 的第二参 COUNT-CURRENT 必须传 t：按它的 docstring，POS 处**正好
有**按钮时默认是跳过该按钮、从下一个按钮开始找，而候选区间起点（`window-start'）
往往正好落在某个按钮的首字符上."
  (let ((pos start)
        result)
    (save-excursion
      (while (and pos (< pos end))
        (setq pos (next-button pos t))
        (when (and pos (< pos end))
          (let ((button-pos (button-start pos))
                (page (button-get pos 'seshat-reader-page)))
            (when (and page button-pos (< button-pos end))
              (push (cons button-pos page) result)))
          ;; `next-button' 没有区间上界参数：手工跳过本按钮，避免原地打转
          (setq pos (1+ (button-end pos))))))
    (nreverse result)))

(defun seshat-reader-outline--avy-read (entries)
  "逐键读取输入，从 ENTRIES 中选出一项；无匹配时返回 nil.

ENTRIES 的元素形如 `(LABEL POSITION . PAGE)'（`--avy-labels' 与
`--avy-candidates' 的乘积）。累积输入不匹配任何 LABEL 的前缀 → 立即取消
（返回 nil）；累积输入只剩一个候选 → 返回该候选的 `(POSITION . PAGE)'。
`read-key' 读到的退出键会抛 quit 信号，此处不吞——由调用方的
`unwind-protect' 负责清理标签 overlay."
  (let ((typed "")
        (result nil)
        (done nil))
    (while (not done)
      (let* ((char (read-key (format "Jump to outline entry: %s" typed)))
             (matches nil))
        ;; 鼠标等非字符事件直接当作取消：`string' 对 list 事件会报错
        (if (not (characterp char))
            (setq done t
                  result nil)
          (setq typed (concat typed (string char)))
          (dolist (entry entries)
            (when (string-prefix-p typed (car entry))
              (push entry matches)))
          (cond ((null matches)
                 (setq done t
                       result nil))
                ((= 1 (length matches))
                 (setq done t
                       result (cdr (car matches))))))))
    result))

(defun seshat-reader-outline-avy-jump ()
  "在当前可见的目录条目间用 avy 式标签跳转.

对当前窗口可见区间（`window-start' 到 `window-end'）内的每个目录按钮，用
overlay 的 `before-string' 在其前面显示 1-2 个字符的标签（face 为
`seshat-reader-outline-avy-label-face'，**不写入 buffer 文本**），随后逐键读取：
按键不匹配任何标签前缀则取消并抛 `user-error'，只剩一个候选即跳转。跳转前
`goto-char' 到按钮位置，再交给既有的 `seshat-reader-outline-goto-entry'
（读按钮的 `seshat-reader-page'、切回阅读窗口并跳页）。

标签字符表来自 `avy-keys'（avy 已加载时），因此风格与 avy 一致，但本命令
**不** require avy，也不进入 `Package-Requires'。

所有标签 overlay 都在 `unwind-protect' 的清理段删除，用退出键中断时同样清理
（见 `seshat-reader-outline--avy-read' 对 quit 信号的处理）。"
  (interactive)
  (unless (derived-mode-p 'seshat-reader-outline-mode)
    (user-error "Not in a seshat-reader-outline-mode buffer"))
  (let* ((start (window-start))
         (end (window-end nil t))
         (candidates (seshat-reader-outline--avy-candidates start end)))
    (unless candidates
      (user-error "No outline entries visible"))
    (let* ((labels (seshat-reader-outline--avy-labels (length candidates)))
           (entries (cl-mapcar #'cons labels candidates))
           (overlays nil)
           target)
      (unwind-protect
          (progn
            (dolist (entry entries)
              (let ((overlay (make-overlay (cadr entry) (cadr entry))))
                (overlay-put overlay 'before-string
                             (propertize (car entry)
                                         'face
                                         'seshat-reader-outline-avy-label-face))
                (push overlay overlays)))
            (setq target (seshat-reader-outline--avy-read entries)))
        ;; 正常返回、取消与 C-g（quit 信号）都到这里：overlay 必须全部清掉。
        (dolist (overlay overlays)
          (delete-overlay overlay)))
      (unless target
        (user-error "Canceled"))
      (goto-char (car target))
      (seshat-reader-outline-goto-entry (button-at (car target))))))

(defun seshat-reader-outline-select-doc-window ()
  "Display and switch to the original document's window.

Bound to `s' in `seshat-reader-outline-mode-map'.  The `o' key does not reach
this command any more: it is carried by `seshat-reader-outline-show', which
toggles the panel open/closed and closes it when point is inside the panel
\(pressing this command there would instead move point back into the reading
window, so the user had to press twice).  This command remains the
jump-back primitive used by `seshat-reader-outline-goto-entry'.

With the childframe carrier, point may be inside the child frame while the
reading window belongs to the parent frame, so the frame owning the reading
window is selected first (`select-frame') and the window afterwards
\(`select-window') — selecting a window of a non-selected frame does not
bring the cursor back to that frame."
  (interactive)
  (let ((buf (get-buffer seshat-reader-outline--doc-buffername)))
    (unless (buffer-live-p buf)
      (user-error "Document buffer no longer exists"))
    (let ((win (or (and (window-live-p seshat-reader-outline--doc-window)
			(eq (window-buffer seshat-reader-outline--doc-window) buf)
			seshat-reader-outline--doc-window)
		   (get-buffer-window buf))))
      (if win
          (progn
            ;; childframe 承载下光标可能在子 frame，必须先回父 frame：`win' 属于
            ;; 父 frame 而当前选中 frame 是子 frame 时，直接 `select-window' 要么
            ;; 报「不是选中 frame 的窗口」，要么把光标留在子 frame 里——目录面板
            ;; 仍是前台，用户看起来「没切回阅读窗口」。所以先切 frame 再选窗口。
            (unless (eq (window-frame win) (selected-frame))
              (select-frame (window-frame win)))
            (select-window win))
        (pop-to-buffer buf))
      (setq seshat-reader-outline--doc-window (selected-window)))))

(defvar-keymap seshat-reader-outline-mode-map
  :doc "Keymap for `seshat-reader-outline-mode'.

`q' closes the panel this buffer is displayed in
\(`seshat-reader-sidebar-quit'): kind `outline' only, so the translate /
annotation panels are left alone, and a childframe carrier is removed with
`delete-frame' instead of leaving an empty frame behind."
  "p"        #'previous-line
  "n"        #'next-line
  "j"        #'next-line
  "k"        #'previous-line
  "f"        #'seshat-reader-outline-avy-jump
  "o"        #'seshat-reader-outline-toggle
  "s"        #'seshat-reader-outline-select-doc-window
  "q"        #'seshat-reader-sidebar-quit
  "RET"      #'seshat-reader-outline-visit-page
  "M-RET"    #'seshat-reader-outline-visit-page)

(define-derived-mode seshat-reader-outline-mode outline-mode "Seshat Reader Outline"
  "Major mode for navigating document outlines."
  (setq buffer-read-only t)
  (setq-local outline-regexp "^\\*+ ")
  (use-local-map seshat-reader-outline-mode-map)
  ;; 目录面板同样关掉 evil：evil 的各 state keymap 经
  ;; `emulation-mode-map-alists' 压在本 mode 的键表之前，会把 j/k/f/q/RET 抢走
  ;; （与阅读器 buffer 的处理一致，见 `seshat-reader-disable-evil'）。
  (seshat-reader--disable-evil))

(defun seshat-reader-outline-goto-entry (button)
  "Shared logic to jump to an outline BUTTON.

The redisplay after switching windows is forced for **all** frames
\(`redisplay' with t) on purpose: with the childframe carrier the jump
starts inside the child frame, and a plain `redisplay' would only update
that frame, leaving the reading window in the parent frame stale until the
next natural redraw."
  (let ((page (button-get button 'seshat-reader-page)))
    (unless (numberp page)
      (user-error "Invalid outline entry: no page info"))
    (seshat-reader-outline-select-doc-window)
    ;; activates `window-buffer-change-functions' and `window-configuration-change-hook'
    ;; 参数 t = 强制重绘**所有** frame：childframe 承载时跳转从子 frame 发起，
    ;; 无参 `redisplay' 只刷当前（子）frame，父 frame 里的阅读窗口不会立即更新，
    ;; 用户看到「跳了但页面没变」，要等下一次自然重绘。
    (redisplay t)
    (seshat-reader-goto-page page)))

(defun seshat-reader-outline-visit-page ()
  "Jump to the page at point in the associated seshat-reader buffer."
  (interactive)
  (save-excursion
    (end-of-line)   ; This is done to make sure the we always have a
    (backward-char) ; button at point.
    (seshat-reader-outline-goto-entry (button-at (point)))))

;;; 阅读器 buffer 关闭时的目录面板清理

;; 用户反馈：关掉 PDF buffer 后目录面板窗口仍留着，点里面的按钮还会因为源 buffer
;; 已死而报错。故在 `kill-buffer-hook' 上挂一个**全局**回调（不是 buffer-local：
;; 阅读器 buffer 可能在别的模块打开时就已经存在，buffer-local 钩子只对之后打开
;; 的 buffer 生效）。

(defun seshat-reader-outline--kill-buffer-cleanup ()
  "Close and empty the outline panel of a seshat-reader buffer being killed.
Runs from the **global** `kill-buffer-hook' (not a buffer-local one), so it
also covers buffers opened before this library got loaded; it returns
immediately unless the dying buffer is still in `seshat-reader-mode'
\(`major-mode' is valid while `kill-buffer-hook' runs).

The panel of that document, `*Outline of NAME*', is closed through
`seshat-reader-sidebar-close-buffer-kind' with kind `outline' — only the
window of that kind showing that very panel is removed, other panels are
untouched.  The panel buffer is then emptied (`inhibit-read-only' bound)
and `seshat-reader-outline--doc-buffername' reset to nil, so the entries of
a dead document cannot survive and the outline toggle command
\(\\[seshat-reader-sidebar-toggle-outline]) cannot resurrect them.  The
panel buffer itself is **not** killed: keeping it empty lets the next
`seshat-reader-outline-show' rebuild into the same buffer.

The body is wrapped in `ignore-errors' because it runs inside
`kill-buffer-hook', where a signal would abort the kill.

Note: this library is loaded lazily (`seshat-reader-outline-show' is
autoloaded), so the hook only gets registered once an outline panel has
been opened in the session.  That is sufficient — with no panel ever
opened there is no panel to close."
  (ignore-errors
    (when (derived-mode-p 'seshat-reader-mode)
      (let ((panel (get-buffer (format "*Outline of %s*" (buffer-name)))))
        (when (buffer-live-p panel)
          (seshat-reader-sidebar-close-buffer-kind 'outline panel)
          (with-current-buffer panel
            (setq seshat-reader-outline--doc-buffername nil)
            (let ((inhibit-read-only t))
              (erase-buffer))))))))

(add-hook 'kill-buffer-hook #'seshat-reader-outline--kill-buffer-cleanup)

(provide 'seshat-reader-outline)
;;; seshat-reader-outline.el ends here
