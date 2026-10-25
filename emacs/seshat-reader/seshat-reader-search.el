;;; seshat-reader-search.el --- Cross-page text search for Seshat Reader  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: docs, hypermedia, tools
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

;; `seshat-reader-mode' 的**跨页文本搜索**（自研扩展，不属上游 vendored 代码）。
;;
;; 入口与键位
;; ==========
;;
;; `C-s' → `seshat-reader-search'。这个前缀在 `seshat-reader-mode-map' 中原本
;; 未占用，绑定后**该 buffer 内的全局 `isearch-forward' 被有意覆盖**（PDF 页面
;; 是图片，isearch 本来就搜不到正文，搜的是 buffer 里那几个换行符，毫无用处）。
;; 其他 buffer 的 `C-s' 不受影响。
;;
;; 搜索会话内的继续/回退**不写进** `seshat-reader-mode-map'：`n' / `p' 在阅读
;; 器里是**翻页**，抢掉它们会让翻页彻底失效。做法是搜索成功后进入
;; `set-transient-map' 武装的临时键表（`n' 下一个 / `p' 上一个 / `RET' 结束并
;; 停留 / `C-g' 取消并回到起始页），按任何其它键即退出临时键表，`n' / `p' 立刻
;; 恢复翻页语义。
;;
;; 搜索结果侧栏
;; ============
;;
;; `C-s' 除了原有的页面高亮与临时键表导航，还把同一批命中列进**左侧** side
;; window（面板 kind 为 `search'，buffer 为 `seshat-reader-search-sidebar-buffer-name'），
;; 每条一行「[p.N] 片段」。片段取该命中所在**整行**的文本（整行才看得出这句话
;; 在讲什么），超过 80 字符截断。打开时光标切到侧栏：搜索已经结束，下一步是挑
;; 结果而不是翻页；侧栏内的 `RET' 跳转、`n' / `p' 逐条移动、`q' 只关自己（与
;; 其它面板一致）。侧栏与目录同侧（`left'），slot 排在目录之后，二者上下并存。
;;
;; 侧栏在文件末尾登记进 `seshat-reader-sidebar-extra-kinds'（buffer 名 →
;; kind `search'），因为承载层 `seshat-reader-sidebar' 是零依赖模块、不能反向
;; require 本模块。登记之后侧栏与其它面板行为完全一致：`q' 走统一的
;; `seshat-reader-sidebar-quit'（按 buffer 名推断 kind，只关自己）、`M-o' 的
;; 「重开最近面板」能覆盖它、popper 分流认得它；换文档时
;; `seshat-reader-search--reset-state' 还会清空侧栏并关闭面板，不保留上份文档
;; 的搜索结果。
;;
;; 侧栏是**并存视图**，不是搜索会话的第二套状态：命中全集仍是阅读 buffer 的
;; `--matches'，侧栏只记「行 → (PAGE INDEX RECTS)」映射；跳转时回到阅读 buffer
;; 设置 `--index' 再走既有 `--goto-page' + `--redraw' 路径，故页面高亮、批注
;; 共存与跨文档守卫全部复用，不存在第二条绘制链路。
;;
;; 搜索范围与回绕
;; ==============
;;
;; 从当前页开始，`n' 向后逐命中推进，到文末**回绕**到第一个命中并提示一次；
;; `p' 反向同理（到文首回绕到最后一个命中）。命中序列按「页号升序 + 页内
;; MuPDF 命中顺序」排列。
;;
;; 每页命中数上限
;; ==============
;;
;; 动态模块 `seshat-reader-dyn--search-page' 的 `limit' 参数会被夹到
;; 1..10000，但**实际收集**另有硬上限 1024 条（C 侧 `SEARCH_PAGE_MAX_QUADS'）。
;; 因此某页返回条数一旦达到 `min(limit, 1024)'，状态行会显式追加
;; 「（本页命中已达上限 1024，仅显示前 1024 条）」——否则用户会以为该页只有
;; 这么多命中。常见触发场景是目录页搜 `.`。
;;
;; 与批注装饰的共存
;; ================
;;
;; 页面上同时可能有批注高亮/下划线/删除线、框选闪现、搜索命中三路装饰。三者
;; 共用 C 层的**一张**文档级装饰表，任何一方都不能独占 `--clear-highlights'。
;; 故本模块走批注模块提供的扩展点：
;; `seshat-reader-annotation-extra-decorations-function'（buffer-local），由
;; `seshat-reader-annotation--redraw-highlights' 在投喂完批注与闪现之后调用，
;; 本模块返回当前页的全部命中装饰。每次搜索/跳转/退出都调用
;; `seshat-reader-annotation--redraw-highlights' 做**全量重投**，从而复用既有
;; 那条「clear → 批注 → 闪现 → 扩展」路径，不存在第二套共存逻辑。
;;
;; 批注模块**未加载**时（只 require 了 `seshat-reader'）搜索仍可用：降级为
;; 自己 `--clear-highlights' → `--add-decoration' → `--refresh-highlights'。
;;
;; 状态
;; ====
;;
;; `seshat-reader-search--query' / `--page-results'（按页缓存的哈希）/
;; `--matches' / `--index' 等全部是 buffer-local：关闭 buffer 时随 buffer
;; 一起消失，不留全局状态。
;;
;; 但「同一个 buffer 换了文档」（复用这个 buffer 打开另一本 PDF，如
;; `find-alternate-file'）**不换 buffer**，buffer-local 状态因此会残留：
;; `--active' 仍是 t，`--active-decorations' 会拿 A 的命中矩形去匹配 B 的
;; 当前页号并投喂出去——A 的命中被画到 B 的页面上。故搜索状态额外记录所属
;; 文档 `--doc-id'（`--start' 时写入），`--active-decorations' 返回前先比对
;; 当前文档 id，不符即清空整套会话状态并返回 nil。

;;; Code:

(require 'cl-lib)
(require 'seshat-reader)
;; 结果侧栏的显示/关闭一律经本模块（零依赖）完成：侧栏只用它做「按 kind 分配
;; side window、per-kind 尺寸记忆、只关自己那个面板」，不自己 split-window。
(require 'seshat-reader-sidebar)

(declare-function seshat-reader-dyn--search-page "seshat-render-core"
                  (page needle limit))
(declare-function seshat-reader-dyn--clear-highlights "seshat-render-core" ())
(declare-function seshat-reader-dyn--add-decoration "seshat-render-core"
                  (page x0 y0 x1 y1 r g b alpha))
(declare-function seshat-reader-dyn--refresh-highlights "seshat-render-core" ())
;; 侧栏片段取文用：两者都是 **0-based** 页号（与 `--search-page' 的 1-based
;; 相反），故调用处一律 `(1- page)' 换算，见 `seshat-reader-search--snippet'。
(declare-function seshat-reader-dyn--lines-in-rect "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--text-in-rect "seshat-render-core"
                  (page x0 y0 x1 y1))
;; 侧栏渲染完再防御性关一次 evil（软依赖：evil 未加载时 `fboundp' 守卫跳过）。
(declare-function seshat-reader--disable-evil "seshat-reader" ())

;; 该变量由 C 模块（`permanent_buffer_local_var'）注册为 buffer-local，编译期
;; 不可见；在此声明以消除 byte-compiler 的 free variable 警告。
(defvar seshat-reader-current-doc-pagecount nil
  "Total page count of the current document, set by the native module.")

;; 本模块**不碰** `n' / `p'：阅读 buffer 里这两个键在 evil normal state 下由
;; `seshat-reader' 的 evil 段统一补绑为翻页（`seshat-reader-next-page' /
;; `-previous-page'），搜索会话不改变该语义；会话内的命中导航由临时键表
;; `seshat-reader-search--map' 提供，会话一结束即自动失效。侧栏内的 `n' / `p'
;; 是「上下移动条目」，绑在 `seshat-reader-search--sidebar-map' 上。

(defgroup seshat-reader-search nil
  "Cross-page text search in `seshat-reader-mode'."
  :group 'seshat-reader)

(defconst seshat-reader-search--hard-cap 1024
  "Per-page hard cap of the native search, mirroring `SEARCH_PAGE_MAX_QUADS'.
`seshat-reader-dyn--search-page' clamps its LIMIT argument to 1..10000 but
never collects more than this many quads per page.  The Lisp side must know
the number to tell the user when a page hit the ceiling instead of assuming
its hits were all there is.")

(defcustom seshat-reader-search-limit 1024
  "单页向动态模块请求的命中上限.
C 侧会把该值夹到 1..10000，且**实际收集**不超过
`seshat-reader-search--hard-cap'（1024）条。默认 1024 即「尽量要满而不
白花内存」；调小可用于在密集页上减少投喂量。"
  :type 'integer
  :group 'seshat-reader-search)

(defcustom seshat-reader-search-max-matches 20000
  "整次搜索最多保留的命中总数.
搜索是**整本扫描**（否则无法回答「第 i/N 个命中」里的 N），像 `.` 这类在
排版文本里遍地都是的串，797 页文档能扫出几十万条命中；每条命中是一个五
元素浮点列表，几十万条就是几十 MB，而且每次跳转都要遍历一遍。故设总量
上限：达到后**停止扫描**并把 `seshat-reader-search--capped' 置 t，状态行
追加「命中过多」提示。调大能覆盖更长的文档，代价是内存与首次搜索耗时；
nil 或非正数表示不设上限（不推荐）。"
  :type '(choice integer (const :tag "不限制" nil))
  :group 'seshat-reader-search)

(defcustom seshat-reader-search-color '(1.0 0.45 0.0)
  "搜索命中的填充色，RGB 三元素各取 0.0–1.0.
默认橙，与批注 highlight 的默认黄（1.0 0.85 0.0）和 underline 的蓝
（0.0 0.45 0.85）都能区分。"
  :type '(list number number number)
  :group 'seshat-reader-search)

(defcustom seshat-reader-search-alpha 0.55
  "搜索命中的填充透明度（0.0 全透明 – 1.0 不透明）.
默认 0.55 比批注 highlight 的 0.35 更实，便于在已有批注高亮之上辨认命中
位置（两路装饰都会被绘制，先画的在下）。"
  :type 'number
  :group 'seshat-reader-search)

;;;; 状态（全部 buffer-local）

(defvar-local seshat-reader-search--query nil
  "当前搜索串，nil 表示没有进行过搜索.")

(defvar-local seshat-reader-search--page-results nil
  "按页缓存的命中：`(PAGE . RECTS)' 的哈希，PAGE 为 1-based 整数.")

(defvar-local seshat-reader-search--matches nil
  "全部命中的扁平列表，元素形如 (PAGE X0 Y0 X1 Y1)，PAGE 为 1-based.")

(defvar-local seshat-reader-search--index nil
  "`--matches' 中当前命中的 0-based 下标，无命中时为 nil.")

(defvar-local seshat-reader-search--truncated-pages nil
  "命中数达到本页上限的页号列表（1-based，升序）.")

(defvar-local seshat-reader-search--capped nil
  "整次搜索是否因 `seshat-reader-search-max-matches' 而提前停止.")

(defvar-local seshat-reader-search--origin-page nil
  "开始本次搜索时的页号（1-based）；`C-g' 取消时回到这里.")

(defvar-local seshat-reader-search--active nil
  "搜索会话是否仍在进行（决定命中装饰是否投喂）.")

(defvar-local seshat-reader-search--doc-id nil
  "本次搜索所属文档的标识，用于发现「同一 buffer 换了文档」.
由 `seshat-reader-search--start' 写入；nil 表示开始搜索时无法确定文档身份
（variable `buffer-file-name' 为空），此时不做跨文档判定。识别规则见
`seshat-reader-search--current-doc-id'.")

;;;; 纯函数：页号对齐、上限、状态串

(defun seshat-reader-search--page-limit ()
  "Return the LIMIT to pass to the native search.
This is the raw `seshat-reader-search-limit' clamped to the range the
native side accepts (1..10000); non-integers fall back to the hard cap.
The value may exceed `seshat-reader-search--hard-cap', since the native
side does its own collecting cap — passing the user value keeps the two
limits independent."
  (let ((limit seshat-reader-search-limit))
    (cond
     ((not (integerp limit)) seshat-reader-search--hard-cap)
     ((< limit 1) 1)
     ((> limit 10000) 10000)
     (t limit))))

(defun seshat-reader-search--cap ()
  "Return the effective per-page hit ceiling, i.e. min(LIMIT, 1024).
This is the number a page's hit count is compared against to decide
whether the page was truncated."
  (min (seshat-reader-search--page-limit) seshat-reader-search--hard-cap))

(defun seshat-reader-search--truncated-p (count)
  "Return non-nil when COUNT hits reached the per-page ceiling.
COUNT is the number of hits returned for one page.  Reaching the ceiling
means the native side may have stopped early, so the user has to be told
that what is shown is only the first `seshat-reader-search--cap' hits."
  (>= count (seshat-reader-search--cap)))

(defun seshat-reader-search--flatten (page rects)
  "Prefix every rectangle of RECTS with PAGE, returning (PAGE X0 Y0 X1 Y1).
RECTS is the native return shape, a list of (X0 Y0 X1 Y1) floats.  Entries
that are not four-element lists are dropped rather than turned into bogus
geometry."
  (let (flattened)
    (dolist (rect rects)
      (when (and (listp rect) (= 4 (length rect)))
        (push (cons page rect) flattened)))
    (nreverse flattened)))

(defun seshat-reader-search--status-string (index total page)
  "Compose the echo-area status for INDEX of TOTAL hits on PAGE.
INDEX is 1-based (the ordinal the user sees), TOTAL is the number of hits
of the whole document and PAGE is 1-based."
  (format "第 %d/%d 个命中 · 第 %d 页" index total page))

;;;; 与阅读器 / 动态模块的薄封装

(defun seshat-reader-search--available-p ()
  "Return non-nil when the native page search entry point is available."
  (and (fboundp 'seshat-reader-dyn--search-page) t))

(defun seshat-reader-search--page-count ()
  "Return the page count of the current document, or 0 when unknown.
The count comes from the buffer-local variable the native module keeps up
to date (`seshat-reader-current-doc-pagecount')."
  (let ((count (bound-and-true-p seshat-reader-current-doc-pagecount)))
    (if (integerp count) count 0)))

(defun seshat-reader-search--current-page ()
  "Return the 1-based page number shown in the selected window.
Falls back to 1 when the window has no page parameter (batch use, or a
buffer that is not being displayed)."
  (or (seshat-reader-current-doc-pagenumber) 1))

(defun seshat-reader-search--goto-page (page)
  "Display PAGE (1-based) in the selected window.
Silently does nothing when the reader's goto command is unavailable, so a
degraded environment only loses the jump, not the whole search."
  (when (fboundp 'seshat-reader-goto-page)
    (condition-case err
        (seshat-reader-goto-page page)
      (error
       (message "Seshat Reader search: 跳页失败：%s" (error-message-string err))))))

(defun seshat-reader-search--rects-for-page (page)
  "Return the hit rectangles of PAGE (1-based), caching them per page.
The native entry point takes a 1-based page number as well (the same
convention as `seshat-reader-dyn--add-decoration', the boundary that owns
the decrement), so PAGE is passed through unchanged; the returned
rectangles stay in page space.  A page without a text layer and a page
without a hit both come back as nil, which is cached as well so that a
failed or empty page is never searched twice."
  (let* ((results (or seshat-reader-search--page-results
                      (setq seshat-reader-search--page-results
                            (make-hash-table :test #'equal))))
         (cached (gethash page results 'seshat-reader-search--missing)))
    (if (not (eq cached 'seshat-reader-search--missing))
        cached
      (let ((rects (seshat-reader-search--request page)))
        (puthash page rects results)
        rects))))

(defun seshat-reader-search--request (page)
  "Ask the native module for the hits of PAGE (1-based).
Returns a list of (X0 Y0 X1 Y1) floats, or nil when the module is missing,
the page has no text layer, nothing matched, or the call signalled —
`ignore-errors' is deliberate: a failed page must degrade to \"no result on
this page\" and never abort a document-wide scan.  PAGE reaches the module
unchanged: `--search-page' is 1-based like the decoration entry points, so
no conversion happens on this side."
  (when (seshat-reader-search--available-p)
    (ignore-errors
      (seshat-reader-dyn--search-page page
                                     seshat-reader-search--query
                                     (seshat-reader-search--page-limit)))))

(defun seshat-reader-search--scan ()
  "Search the pages of the current document, refreshing `--matches'.
Returns nil; the hits are stored in `--matches' (page order) and the pages
that reached the per-page ceiling in `--truncated-pages'.  Pages are walked
in order so the resulting sequence is deterministic, and every page is
cached by `seshat-reader-search--rects-for-page'.

Scanning stops early once `seshat-reader-search-max-matches' hits have been
collected, so that a needle like a lone period cannot grow the hit list into
the hundreds of thousands; `--capped' then records that the scan was cut
short and the caller reports it instead of pretending the list is complete."
  (let ((total (seshat-reader-search--page-count))
        (limit seshat-reader-search-max-matches)
        (matches nil)
        (count 0)
        (truncated nil)
        (capped nil)
        (page 0))
    (while (and (< page total) (not capped))
      (setq page (1+ page))
      (let* ((rects (seshat-reader-search--rects-for-page page))
             (page-matches (seshat-reader-search--flatten page rects)))
        (when (seshat-reader-search--truncated-p (length rects))
          (push page truncated))
        (setq matches (nconc matches page-matches))
        (setq count (+ count (length page-matches)))
        (when (and (integerp limit) (> limit 0) (> count limit))
          (setq matches (seq-take matches limit)
                capped t))))
    (setq seshat-reader-search--matches matches)
    (setq seshat-reader-search--truncated-pages (nreverse truncated))
    (setq seshat-reader-search--capped capped)
    nil))

(defun seshat-reader-search--first-index-from (page)
  "Return the index of the first hit on or after PAGE; nil when there is none."
  (let ((rest seshat-reader-search--matches)
        (index 0)
        (found nil))
    (while (and rest (not found))
      (when (>= (nth 0 (car rest)) page)
        (setq found index))
      (setq rest (cdr rest)
            index (1+ index)))
    found))

(defun seshat-reader-search--current-doc-id ()
  "Return the document id of the current buffer, or nil when unknown.
Derived with `seshat-reader-annotation--quiet-doc-id' when the annotation
module is loaded — the same rule the annotation layer uses to tell two
documents apart, so the two views always agree — and otherwise to
variable `buffer-file-name'.  The fallback keeps a degraded setup (only
`seshat-reader' loaded, no annotation module) working: what matters here
is only that the value *changes* when the buffer is pointed at another
document, not that it matches the server-side identity.

The annotation entry point is a soft dependency, hence `fboundp' plus
`ignore-errors': a failing derivation must never break redrawing, it only
leaves the cross-document guard switched off.

A buffer with variable `buffer-file-name' unset has no identity, so nil
is returned and no cross-document comparison is possible (see
`seshat-reader-search--same-document-p')."
  (let ((file buffer-file-name))
    (cond
     ((not (stringp file)) nil)
     ((fboundp 'seshat-reader-annotation--quiet-doc-id)
      (or (ignore-errors (seshat-reader-annotation--quiet-doc-id file))
          file))
     (t file))))

(defun seshat-reader-search--same-document-p ()
  "Return non-nil when the buffer still shows the searched document.
`seshat-reader-search--doc-id' is what `--start' recorded, so a buffer
that was reused for another document reports a mismatch and the caller
drops the stale session.  When either side is nil the identity is unknown
and this returns non-nil (fail open): refusing to draw a legitimate
session is worse than drawing one that may be stale."
  (let ((current (seshat-reader-search--current-doc-id)))
    (or (null seshat-reader-search--doc-id)
        (null current)
        (equal seshat-reader-search--doc-id current))))

;;;; 装饰投喂

(defun seshat-reader-search--set-extra-hook (function)
  "Point the annotation extra-decorations hook at FUNCTION (nil clears it).
The variable only exists once the annotation module is loaded, hence the
`boundp' guard; `setq-local' keeps it buffer-local so it never leaks to
another document's buffer."
  (when (boundp 'seshat-reader-annotation-extra-decorations-function)
    (setq-local seshat-reader-annotation-extra-decorations-function function)))

(defun seshat-reader-search--reset-state ()
  "Drop the whole search session state of the current buffer.
Called from `--active-decorations' when the buffer has been pointed at
another document: the recorded hits, their per-page cache and the query
all describe a document that is no longer displayed, so keeping them
would feed geometry into the wrong pages.  The annotation hook is cleared
as well, since a session that no longer exists has nothing to contribute.

The **search sidebar is dropped too** (see
`seshat-reader-search--clear-sidebar'): 换文档后不再保留旧搜索结果——侧栏里那些
行属于上一份文档，留着既会让 `RET' / `n' / `p' 跳到与新文档无关的页码，也会
让面板看起来仍属于当前文档。故清空侧栏内容与「行 → 命中」映射，并在面板显示
时把它关掉。"
  (setq seshat-reader-search--active nil)
  (setq seshat-reader-search--query nil)
  (setq seshat-reader-search--page-results nil)
  (setq seshat-reader-search--matches nil)
  (setq seshat-reader-search--index nil)
  (setq seshat-reader-search--truncated-pages nil)
  (setq seshat-reader-search--capped nil)
  (setq seshat-reader-search--origin-page nil)
  (setq seshat-reader-search--doc-id nil)
  (seshat-reader-search--uninstall-hook)
  (seshat-reader-search--clear-sidebar))

(defun seshat-reader-search--active-decorations ()
  "Return the decorations of the hits on the current page.
Each element has the shape (PAGE X0 Y0 X1 Y1 R G B ALPHA), the form
`seshat-reader-annotation-extra-decorations-function' is expected to
return.  nil when no search session is active or the page has no hit, in
which case nothing is fed for this source and the annotation and flash
decorations stay alone in the table.

The buffer is also checked against the document the hits came from: a
buffer reused for another document keeps its buffer-local search state,
and matching those hits against the new document's page number would draw
one document's rectangles onto another's page.  On a mismatch the whole
session is dropped (state and annotation hook) and nil is returned, which
is exactly the shape \"no hits for this source\" has."
  (when (and seshat-reader-search--active seshat-reader-search--matches)
    (if (not (seshat-reader-search--same-document-p))
        (progn
          (seshat-reader-search--reset-state)
          nil)
      (let ((page (seshat-reader-search--current-page))
            (color seshat-reader-search-color)
            (alpha seshat-reader-search-alpha)
            (decorations nil))
        (dolist (match seshat-reader-search--matches)
          (when (= page (nth 0 match))
            (push (append match (list (nth 0 color) (nth 1 color) (nth 2 color)
                                      alpha))
                  decorations)))
        (nreverse decorations)))))

(defun seshat-reader-search--feed-decoration (decoration)
  "Feed one DECORATION of the shape (PAGE X0 Y0 X1 Y1 R G B ALPHA).
Uses the 9-argument `seshat-reader-dyn--add-decoration' entry point (the
5-argument one is hard-wired to the default highlight yellow).  Returns nil
when the entry point is missing, and never signals."
  (when (fboundp 'seshat-reader-dyn--add-decoration)
    (ignore-errors
      (seshat-reader-dyn--add-decoration
       (nth 0 decoration) (nth 1 decoration) (nth 2 decoration)
       (nth 3 decoration) (nth 4 decoration)
       (nth 5 decoration) (nth 6 decoration) (nth 7 decoration)
       (nth 8 decoration)))))

(defun seshat-reader-search--install-hook ()
  "Install `seshat-reader-search--active-decorations' as the extra source.
The variable only exists when the annotation module is loaded; without it
the degraded path in `seshat-reader-search--redraw' is used instead.

The reader's `post-command-hook' is armed here as well
\\(`--sidebar-follow-page'): paging does not call into this module at all (the
page is displayed by the native module), so a command hook is the cheapest
place to keep the sidebar's \"hits on this page\" highlight on the page that is
now on screen.  It is buffer-local, so it dies with the session buffer."
  (seshat-reader-search--set-extra-hook
   #'seshat-reader-search--active-decorations)
  (add-hook 'post-command-hook #'seshat-reader-search--sidebar-follow-page nil t))

(defun seshat-reader-search--uninstall-hook ()
  "Stop contributing decorations to the annotation redraw path.
The sidebar page-follow hook of the session is removed too, so paging a buffer
without a session costs nothing."
  (seshat-reader-search--set-extra-hook nil)
  (remove-hook 'post-command-hook #'seshat-reader-search--sidebar-follow-page t))

(defun seshat-reader-search--redraw ()
  "Redraw the page decorations, keeping annotation and flash decorations.
Delegates to `seshat-reader-annotation--redraw-highlights' when the
annotation module is loaded: that function clears the table, feeds the
annotations, feeds the flash rectangles and finally calls
`seshat-reader-annotation-extra-decorations-function' — so one full redraw
keeps all three sources, and no source has to own the clear step.

When the annotation module is not loaded the search decorations are fed
alone (clear, add every hit on the current page, refresh).  The native
module may not be loaded at all, hence the `fboundp' guards and
`ignore-errors': decorations are optional and must never break a search."
  (cond
   ((fboundp 'seshat-reader-annotation--redraw-highlights)
    (ignore-errors (seshat-reader-annotation--redraw-highlights)))
   (t
    (ignore-errors
      (when (fboundp 'seshat-reader-dyn--clear-highlights)
        (seshat-reader-dyn--clear-highlights)
        (dolist (decoration (seshat-reader-search--active-decorations))
          (seshat-reader-search--feed-decoration decoration))
        (when (fboundp 'seshat-reader-dyn--refresh-highlights)
          (seshat-reader-dyn--refresh-highlights)))))))

;;;; 会话：显示与提示

(defun seshat-reader-search--goto-match ()
  "Display the page of the current hit, if it is not the visible page.
The search sidebar follows: `--sidebar-sync' scrolls the result list to the
same hit and highlights it without touching the reader's focus, which is what
makes `n' / `p' in the reading buffer keep the two views pointing at the same
result.  Syncing after the jump (rather than in `--move') covers every caller
of `--show'; `--start' additionally syncs right after rendering."
  (let ((match (nth seshat-reader-search--index seshat-reader-search--matches)))
    (when (and match (integerp (nth 0 match))
               (/= (nth 0 match) (seshat-reader-search--current-page)))
      (seshat-reader-search--goto-page (nth 0 match))))
  (seshat-reader-search--sidebar-sync seshat-reader-search--index))

(defun seshat-reader-search--announce (&optional notice)
  "Report the current hit in the echo area, with an optional NOTICE suffix.
The status is `seshat-reader-search--status-string'; when the page is one
of `--truncated-pages' the per-page ceiling warning is appended, and
NOTICE (a wrap-around message) follows after a dash."
  (let* ((total (length seshat-reader-search--matches))
         (index (if seshat-reader-search--index
                    (1+ seshat-reader-search--index)
                  0))
         (match (nth (or seshat-reader-search--index 0)
                     seshat-reader-search--matches))
         (page (nth 0 match))
         (cap (and (memq page seshat-reader-search--truncated-pages)
                   (seshat-reader-search--cap))))
    (message "%s%s%s%s"
             (seshat-reader-search--status-string index total page)
             (if cap
                 (format "（本页命中已达上限 %d，仅显示前 %d 条）" cap cap)
               "")
             (if seshat-reader-search--capped
                 (format "（命中过多，仅保留前 %d 条）" total)
               "")
             (if notice (concat " — " notice) ""))))

(defun seshat-reader-search--show (&optional notice)
  "Jump to the current hit, redraw the decorations and announce NOTICE."
  (seshat-reader-search--goto-match)
  (seshat-reader-search--redraw)
  (seshat-reader-search--announce notice))

;;;; 搜索结果侧栏

;; 侧栏是**并存视图**：`C-s' 原有的页面高亮 + 临时键表导航一点都不变，只是把
;; 同一批命中额外列进左侧 panel（kind 为 `search'），每条一行「[p.N] 片段」。
;; 打开时光标切到侧栏（`--render-sidebar' 把 SELECT 传 t），于是接下来的
;; `RET' / `n' / `p' 落在侧栏自己的键表上——阅读 buffer 的临时键表只管阅读
;; buffer（其 keep 谓词要求 current-buffer 仍是原 buffer），两侧不抢键。

(defconst seshat-reader-search-sidebar-buffer-name "*Seshat Search*"
  "搜索结果侧栏的 buffer 名.
侧栏里是只读 Markdown-ish 文本（标题 + 每条一行「[p.N] 片段」），供 side
window 显示；本常量同时是「这个 buffer 是搜索结果侧栏」的唯一标识。")

(defconst seshat-reader-search--sidebar-snippet-max 80
  "侧栏单条片段的最大字符数.
超出即截断并追加省略号：片段是用来**辨认**命中的，侧栏宽度只有 frame 的四分
之一，长行会折成好几行、一屏放不下几条。")

(defconst seshat-reader-search--sidebar-max-entries 200
  "侧栏最多列出的命中条数.
每条要取一次整行矩形与整行文本，都要进动态模块；像 `.` 这种在排版文本里遍地
都是的串，几千条命中逐条取文会让 `C-s' 卡住数秒。故设上限，超出时标题写明显
式条数（侧栏是「快速定位」视图，不是命中全集——全集仍在页面上与状态行里）。")

(defvar-local seshat-reader-search--sidebar-matches nil
  "侧栏 buffer 里每一行对应的匹配数据，按行序.
每个元素是 (PAGE INDEX RECTS)：PAGE 为 1-based 页号，INDEX 为该命中在阅读
buffer `--matches' 里的 0-based 下标，RECTS 是该命中的页面坐标矩形
\(X0 Y0 X1 Y1)。本变量只存在于侧栏 buffer，是「侧栏行 ↔ 命中」映射的唯一来源
（行上另挂同名 text property，用于按行取条目）。")

(defvar-local seshat-reader-search--sidebar-source nil
  "侧栏内容所属的阅读 buffer.
`RET' / `n' / `p' 都必须回到**搜索所属的那个阅读 buffer**执行：侧栏 buffer
自己没有页号窗口参数、也没有搜索会话状态（`--matches' / `--index' 都是阅读
buffer 的 buffer-local）。该变量在 `seshat-reader-search--render-sidebar' 渲染
时写入；为 nil 或已被 kill 时跳转只提示、不发信号。")

(defvar-local seshat-reader-search--sidebar-markers nil
  "侧栏 buffer 里每条命中行行首的 marker 列表，顺序与 `--sidebar-matches' 一致.
用 marker 而不是行号：侧栏重渲染（`erase-buffer' + 重新 `insert'）或将来任何
改动 buffer 内容的操作都会让行号漂移，而 marker 跟着它指向的位置走。索引
下标与命中下标同义——「第 N 条命中」就取 `(nth N --sidebar-markers)'，这是阅读
buffer 里 `n' / `p' 时把侧栏滚到对应条目的唯一依据。")

(defvar-local seshat-reader-search--sidebar-cursor nil
  "侧栏里标记「当前条目」的 overlay，或 nil.
只覆盖当前条目那一行、且用 `window' 属性限定在侧栏窗口上显示（见
`seshat-reader-search--sidebar-highlight'）：侧栏窗口在被同步时**不是**选中的
窗口，所以不能用 `hl-line-mode'（它的 overlay 跟随当前 buffer 的 point 且默认
限制在 `(selected-window)'）。")

(defun seshat-reader-search--clear-sidebar ()
  "Clear the search sidebar of stale results and close the `search' panel.
Called from `seshat-reader-search--reset-state' when the buffer has been
pointed at another document: the sidebar still lists the hits of the
document that is no longer displayed, so its `RET' / `n' / `p' would jump to
pages that mean nothing in the new document, and the panel would look like
it still describes the current one.  The content and the line → hit mapping
\(`seshat-reader-search--sidebar-matches') are therefore dropped, together
with the recorded source buffer.

The panel is closed only when it is actually displayed
\\(`seshat-reader-sidebar-panel-visible-p'): `--toggle-kind' means \"open it
when nothing is shown\", so calling it unconditionally would *open* a panel
just to be done with it.

Best effort throughout: the sidebar buffer may never have been created
\(search never ran, no hits, or the search module was loaded but unused) and
the panel backend may be unavailable.  Neither may make a document switch
signal, hence the `buffer-live-p' guard and `ignore-errors' around the panel
close."
  (let ((buffer (get-buffer seshat-reader-search-sidebar-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (or seshat-reader-search--sidebar-matches
                  (> (buffer-size) 0))
          (let ((inhibit-read-only t))
            (erase-buffer))
          (setq seshat-reader-search--sidebar-matches nil)
          (setq seshat-reader-search--sidebar-markers nil)
          (setq seshat-reader-search--sidebar-source nil)
          ;; 高亮 overlay 随内容一起丢弃：留着会在空 buffer 上留下一个零长度
          ;; overlay，下一次同步又会把它挪到新内容上，状态来源就不唯一了。
          (when (overlayp seshat-reader-search--sidebar-cursor)
            (delete-overlay seshat-reader-search--sidebar-cursor)
            (setq seshat-reader-search--sidebar-cursor nil))
          ;; 「当前页的匹配」那一整组 overlay 同理（见
          ;; `--sidebar-highlight-page'）。
          (seshat-reader-search--sidebar-clear-page-overlays)
          (set-buffer-modified-p nil)))))
  (ignore-errors
    (when (seshat-reader-sidebar-panel-visible-p 'search)
      (seshat-reader-sidebar--toggle-kind 'search))))

(defun seshat-reader-search--one-line (text)
  "Return TEXT collapsed onto one line, or an empty string.
The native text extractor returns the page text verbatim, which contains the
line breaks and indentation of the PDF layout.  A sidebar line has to stay a
single line, so runs of whitespace are collapsed into one space and the ends
trimmed.  Non-strings (the module is missing, the page has no text layer) come
back as an empty string instead of nil, so callers never have to branch on
the type."
  (if (not (stringp text))
      ""
    (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))))

(defun seshat-reader-search--truncate-snippet (text)
  "Return TEXT truncated to `seshat-reader-search--sidebar-snippet-max' chars.
The ellipsis is appended only when something was actually cut, so a short
snippet is left byte-identical and the caller's assertions stay readable."
  (if (and (stringp text)
           (> (length text) seshat-reader-search--sidebar-snippet-max))
      (concat (substring text 0 seshat-reader-search--sidebar-snippet-max) "…")
    (or text "")))

(defun seshat-reader-search--snippet (page rect)
  "Return the snippet shown for RECT on PAGE.
PAGE is 1-based (the search convention) while RECT is a page-space rectangle
\(X0 Y0 X1 Y1) as the native search returned it.  The snippet is the text of
the **whole line** the hit sits on, not just the matched glyphs: a few
characters around a highlight do not say what the sentence is about, and the
search page hit is often a single short word.

The module entry points used here (`--lines-in-rect' / `--text-in-rect') take a
**0-based** PAGE — the opposite of `--search-page' — hence the single
`(1- page)' conversion in this function.  Every failure degrades to an empty
snippet: a build without those entry points, a page whose text cannot be read
and a rectangle that covers no text all leave the sidebar line as just
\"[p.N]\" instead of dropping the hit."
  (let* ((index (1- page))
         (lines (ignore-errors
                  (when (fboundp 'seshat-reader-dyn--lines-in-rect)
                    (seshat-reader-dyn--lines-in-rect
                     index (nth 0 rect) (nth 1 rect)
                     (nth 2 rect) (nth 3 rect)))))
         (target (or (car-safe lines) rect))
         (text (ignore-errors
                 (when (and target (fboundp 'seshat-reader-dyn--text-in-rect))
                   (seshat-reader-dyn--text-in-rect
                    index (nth 0 target) (nth 1 target)
                    (nth 2 target) (nth 3 target))))))
    (seshat-reader-search--truncate-snippet
     (seshat-reader-search--one-line text))))

(defun seshat-reader-search--sidebar-entries (matches)
  "Return the sidebar entries of MATCHES, capped at `--sidebar-max-entries'.
Each entry is (PAGE INDEX RECTS): PAGE is the 1-based page of the hit, INDEX is
its 0-based position in MATCHES (the same index the search session keeps in
`seshat-reader-search--index', so a jump can restore the session's notion of
\"current hit\") and RECTS is the (X0 Y0 X1 Y1) rectangle.

MATCHES is walked in full so the INDEX values stay true even when the list is
longer than the cap; only the entries themselves stop being collected once the
cap is reached."
  (let ((index 0)
        entries)
    (dolist (match matches)
      (when (< (length entries) seshat-reader-search--sidebar-max-entries)
        (push (list (nth 0 match) index (cdr match)) entries))
      (setq index (1+ index)))
    (nreverse entries)))

(defun seshat-reader-search--sidebar-header (query total shown)
  "Return the sidebar header line for QUERY with TOTAL hits, SHOWN listed.
The header states whether the list is complete: a capped list that looks like
the whole result set would send the reader scrolling for hits that were never
written."
  (let ((needle (if (stringp query) query "")))
    (if (< shown total)
        (format "# 搜索结果：%s（%d 条，仅列出前 %d 条）\n\n" needle total shown)
      (format "# 搜索结果：%s（%d 条）\n\n" needle total))))

(defun seshat-reader-search--sidebar-line (entry)
  "Return the text of the sidebar line for ENTRY.
The shape is \"[p.PAGE] snippet\"; when the snippet could not be extracted the
line is just \"[p.PAGE]\" — a dangling separator with nothing after it reads
like a rendering bug."
  (let* ((page (nth 0 entry))
         (snippet (seshat-reader-search--snippet page (nth 2 entry))))
    (if (string-empty-p snippet)
        (format "[p.%d]" page)
      (format "[p.%d] %s" page snippet))))

(defun seshat-reader-search--sidebar-highlight (marker window)
  "Highlight the sidebar line starting at MARKER, visible in WINDOW only.
MARKER belongs to the sidebar buffer.  The highlight is a dedicated overlay
whose `window' property is pinned to WINDOW, because the sidebar window is
*not* the selected window while the reader walks its hits: `hl-line-mode'
cannot be used here — its overlay follows the point of the **current buffer**
and is restricted to the selected window (see `hl-line-highlight'), so a
line synced into a background window would never light up and would be
re-pointed at the reader's own line by that buffer's post-command hook.

Using the `hl-line' face (when it exists) keeps the look consistent with the
rest of Emacs; `highlight' is the fallback for a build without hl-line.

Best effort: a marker without a live buffer does nothing."
  (let ((buffer (marker-buffer marker)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((overlay seshat-reader-search--sidebar-cursor))
          (unless (overlayp overlay)
            (setq overlay (make-overlay (point-min) (point-min)))
            (overlay-put overlay 'face (if (facep 'hl-line) 'hl-line 'highlight))
            (setq seshat-reader-search--sidebar-cursor overlay))
          (move-overlay overlay marker
                        (save-excursion (goto-char marker) (line-end-position)))
          (overlay-put overlay 'window window))))))

;;; 当前页的匹配在侧栏里高亮

;; 翻页（`n' / `p'、`M-<' / `M->'、鼠标滚动到页边界、`RET' 跳页）之后，侧栏里
;; 属于**新页面**的条目要能一眼看出来：只靠「当前命中」那一行的 `hl-line' 不够，
;; 因为读者想知道的是「这一页在结果里还有哪几处」。故除 `--sidebar-cursor'（跟随
;; 命中）外，另加**一组** overlay 标出当前页的全部条目。

(defface seshat-reader-search-sidebar-current-page
  '((t :inherit secondary-selection))
  "搜索结果侧栏中「当前页的匹配」的高亮.
默认继承 `secondary-selection'，故随主题变化；侧栏里「当前命中」那一行走
`hl-line'（见 `--sidebar-cursor'），两者可以同时出现在同一行上。"
  :group 'seshat-reader-search)

(defvar-local seshat-reader-search--sidebar-page-overlays nil
  "侧栏 buffer 里标出「当前页的匹配」的 overlay 列表.
每个 overlay 覆盖**一条**属于当前页的侧栏行。整组随页面切换重建（先全删再新建），
故重复调用不会叠加；`--clear-sidebar' 清空侧栏内容时一并删除。")

(defvar-local seshat-reader-search--sidebar-page-shown nil
  "上一次在侧栏里高亮的页号（1-based），或 nil.
只用于 `--sidebar-follow-page' 的提前返回：同页的连续命令不重建 overlay。")

(defun seshat-reader-search--sidebar-clear-page-overlays ()
  "Delete every overlay of `--sidebar-page-overlays' in the current buffer."
  (mapc (lambda (overlay)
          (when (overlayp overlay) (delete-overlay overlay)))
        seshat-reader-search--sidebar-page-overlays)
  (setq seshat-reader-search--sidebar-page-overlays nil))

(defun seshat-reader-search--sidebar-highlight-page (page)
  "Highlight the sidebar entries whose hit is on PAGE (1-based).
侧栏 buffer 不存在、`--sidebar-markers' 为空或 PAGE 不是整数时只清旧高亮并
返回。**不改 point、不滚动**：位置跟随是 `--sidebar-sync' 的职责，两者可以同时
存在于同一条侧栏行上（当前命中的 `hl-line' + 当前页的 `secondary-selection'）。

高亮用 overlay 而非 `add-face-text-property'：侧栏只读，但 overlay 不写 buffer
内容，重渲染（`erase-buffer' + 重新 `insert'）后不会留下文本属性残渣，删除也不
需要 `inhibit-read-only'。行范围取 `line-end-position'，与 `--sidebar-cursor'
一致（覆盖整行，包括折行后的续行由 overlay 的 face 自然延续）。"
  (let ((buffer (get-buffer seshat-reader-search-sidebar-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (seshat-reader-search--sidebar-clear-page-overlays)
        (when (and (integerp page) seshat-reader-search--sidebar-markers)
          (let ((entries seshat-reader-search--sidebar-matches)
                (markers seshat-reader-search--sidebar-markers))
            (while (and entries markers)
              (let ((marker (car markers)))
                (when (and (eql (nth 0 (car entries)) page)
                           (marker-position marker))
                  (let ((overlay (make-overlay
                                  marker
                                  (save-excursion
                                    (goto-char marker)
                                    (line-end-position))
                                  buffer)))
                    (overlay-put overlay 'face
                                 'seshat-reader-search-sidebar-current-page)
                    (push overlay seshat-reader-search--sidebar-page-overlays))))
              (setq entries (cdr entries)
                    markers (cdr markers)))))))))

(defun seshat-reader-search--sidebar-follow-page ()
  "把侧栏的「当前页高亮」跟到阅读 buffer 现在显示的页.
挂在阅读 buffer 的 `post-command-hook' 上（会话存续期间，见 `--install-hook'）：
翻页命令（`seshat-reader-next-page' 等）与 `RET' 跳页都会经过它，而搜索模块本身
在翻页时**不会**被调用（页显示由动态模块完成，不经过本模块的任何函数），故这是
最轻的接线点——不做任何 buffer 扫描，只比一次页号。

只有会话仍在进行（`--active' 且 `--matches' 非空）时才工作；页号与上次记录的
`--sidebar-page-shown' 相同则直接返回，避免每条命令都重建 overlay。"
  (when (and seshat-reader-search--active seshat-reader-search--matches)
    (let ((page (seshat-reader-search--current-page)))
      (unless (eql page seshat-reader-search--sidebar-page-shown)
        (setq seshat-reader-search--sidebar-page-shown page)
        (seshat-reader-search--sidebar-highlight-page page)))))

(defun seshat-reader-search--sidebar-scroll (window position)
  "Scroll WINDOW to show POSITION, roughly centred, without moving focus.
Same frame: `with-selected-window' + `recenter' — the window is selected only
for the duration of the call and the user's window is restored right after,
so the final focus is unchanged.  Another frame: fall back to setting
`window-start' directly, since selecting a window on a different frame would
raise that frame just to scroll it."
  (if (eq (window-frame window) (selected-frame))
      (with-selected-window window (recenter))
    (with-current-buffer (window-buffer window)
      (set-window-start window (max (point-min) (- position 2))))))

(defun seshat-reader-search--sidebar-sync (index)
  "把侧栏滚动到第 INDEX 条命中并高亮，不抢光标.
侧栏 buffer 不存在、INDEX 越界、或侧栏没有可见窗口时静默返回。
只 `set-window-point' 与 `recenter'（`recenter' 经 `with-selected-window'
短暂选中侧栏窗口后立即恢复），**不**把用户的焦点留在侧栏。

INDEX 是**命中的 0-based 下标**（与 `--sidebar-matches' / `--index' 同义），
不是行号：侧栏前两行是标题与空行，且行号会随重渲染漂移。目标位置取自
`--sidebar-markers'（渲染时记录的 marker），因此内容变化后依然指向同一条命中。

这条函数是「阅读 buffer 里 `n' / `p' 命中切换 → 左侧结果栏跟随」的唯一入口，
与反向的 `seshat-reader-search--sidebar-jump'（侧栏 `n' / `p' / `RET' → 阅读
buffer 跳页）互为镜像；两侧都只动对方视图的**显示**位置，不改会话状态。"
  (let ((buffer (get-buffer seshat-reader-search-sidebar-buffer-name)))
    (when (buffer-live-p buffer)
      (let* ((markers (buffer-local-value 'seshat-reader-search--sidebar-markers
                                          buffer))
             (marker (and (integerp index)
                          (>= index 0)
                          (nth index markers))))
        (when (and marker (marker-position marker))
          (let ((window (get-buffer-window buffer t)))
            (when window
              (seshat-reader-search--sidebar-highlight marker window)
              (set-window-point window marker)
              (seshat-reader-search--sidebar-scroll window
                                                     (marker-position marker)))))))))

(defun seshat-reader-search--sidebar-entry-at (position)
  "Return the sidebar entry recorded at POSITION, or nil.
The mapping lives in a text property written by
`seshat-reader-search--render-sidebar', so lookup is independent of how the
line was rendered (wrapping, faces, a future prefix column) and works on any
position inside the line, not only on its first column."
  (get-text-property position 'seshat-reader-search-sidebar-entry))

(defun seshat-reader-search--sidebar-entry-at-point ()
  "Return the sidebar entry of the line at point, or nil.
The property is attached to the whole line, so this works wherever point sits
in it; positions outside any entry line (the header, the blank separator)
return nil and the caller reports \"no hit on this line\"."
  (or (seshat-reader-search--sidebar-entry-at (line-beginning-position))
      (seshat-reader-search--sidebar-entry-at (point))))

(defun seshat-reader-search--sidebar-entry-line (step)
  "Return the position of the next entry line in direction STEP, or nil.
STEP is +1 for forward and -1 for backward.  Lines without an entry (the
header, the blank separator) are skipped, and running off either end returns
nil instead of erroring — `n' on the last hit and `p' on the first are normal
keystrokes, not failures."
  (let (position)
    (save-excursion
      (while (and (not position) (zerop (forward-line step)))
        (when (seshat-reader-search--sidebar-entry-at (line-beginning-position))
          (setq position (line-beginning-position)))))
    position))

(defun seshat-reader-search--sidebar-jump-in (buffer page index)
  "In BUFFER, display PAGE and make hit INDEX the session's current hit.
The page is shown first so that the redraw reads the page number of the page
that is now on screen, then the decorations are re-fed: the full redraw keeps
annotations and the selection flash alive (see
`seshat-reader-search--redraw') and swaps the search hits to the new page.

The reading buffer's transient keymap is re-armed here as well
\(`--arm-transient-map' with BUFFER): it is dropped as soon as one command runs
in another buffer (the sidebar), so a jump from the sidebar must re-arm it or
the next `n' / `p' pressed in the reading buffer would fall through to evil's
own bindings."
  (with-current-buffer buffer
    (setq seshat-reader-search--index index)
    (seshat-reader-search--goto-page page)
    (seshat-reader-search--redraw)
    (when seshat-reader-search--active
      (seshat-reader-search--arm-transient-map buffer))))

(defun seshat-reader-search--sidebar-jump (page index)
  "Show PAGE and highlight hit INDEX in the reading buffer of the sidebar.
The jump runs in the reader's own **window** when it is visible
\(`with-selected-window'): `seshat-reader-goto-page' and the redraw path read
the page and geometry of the selected window, so acting on the sidebar window
would page a buffer that has no document.  Focus is deliberately **not**
moved — the reader keeps clicking through results in the sidebar.

A source buffer that is gone (document closed) only produces a message: a
sidebar left over from a closed document must not signal on every RET."
  (let ((source seshat-reader-search--sidebar-source)
        (window (and (bufferp seshat-reader-search--sidebar-source)
                     (get-buffer-window seshat-reader-search--sidebar-source t))))
    (cond
     ((not (buffer-live-p source))
      (message "搜索结果：原阅读 buffer 已关闭"))
     (window
      (with-selected-window window
        (seshat-reader-search--sidebar-jump-in source page index)))
     (t
      (seshat-reader-search--sidebar-jump-in source page index)))))

(defun seshat-reader-search-sidebar-goto ()
  "Jump to the page of the result on the current sidebar line and highlight it.
The hit is identified by the line's text property, so the result is the same
wherever point sits inside the line."
  (interactive)
  (let ((entry (seshat-reader-search--sidebar-entry-at-point)))
    (if (not entry)
        (message "搜索结果：当前行没有对应结果")
      (seshat-reader-search--sidebar-jump (nth 0 entry) (nth 1 entry)))))

(defun seshat-reader-search--sidebar-move (step)
  "Move to the next (STEP positive) or previous entry line and jump there.
Hitting either end only reports it; point stays on the current line so the
reader can keep pressing `n' / `p' without the cursor wandering into the
header."
  (let ((position (seshat-reader-search--sidebar-entry-line step)))
    (if (not position)
        (message "%s" (if (> step 0) "已是最后一个结果" "已是第一个结果"))
      (goto-char position)
      (seshat-reader-search-sidebar-goto))))

(defun seshat-reader-search-sidebar-next ()
  "Jump to the next result listed in the search sidebar."
  (interactive)
  (seshat-reader-search--sidebar-move 1))

(defun seshat-reader-search-sidebar-prev ()
  "Jump to the previous result listed in the search sidebar."
  (interactive)
  (seshat-reader-search--sidebar-move -1))

(defun seshat-reader-search-sidebar-quit ()
  "Close the search sidebar, leaving every other panel open.
Kept as a thin alias of `seshat-reader-sidebar-quit' for compatibility (the
command existed before the sidebar was registered as a panel kind): the
generic command now derives kind `search' from the buffer name
\\(`*Seshat Search*' is in `seshat-reader-sidebar-extra-kinds', registered at
the end of this file) and closes only that panel, so both entry points have
exactly the same effect — `q' in the sidebar closes nothing but the sidebar.

It is **not** a wrapper around `seshat-reader-sidebar-toggle' with an explicit
kind anymore: routing through the name-based command keeps the search sidebar
on the same path as the annotation / translate / outline panels."
  (interactive)
  (seshat-reader-sidebar-quit))

(defvar-keymap seshat-reader-search--sidebar-map
  :doc "Keymap of the search result sidebar buffer.
Parented on `special-mode-map', so the usual read-only-buffer keys (scrolling
with \\[scroll-up-command] / \\[scroll-down-command], \\[quit-window]) keep
working; only the six keys that mean something here are overridden.

`j' / `k' move the cursor one line down / up (like `special-mode' users
expect), while `n' / `p' walk the hit list and jump the reader to the hit on
the current line — different semantics, so both families stay bound."
  :parent special-mode-map
  "q"   #'seshat-reader-sidebar-quit
  "RET" #'seshat-reader-search-sidebar-goto
  "n"   #'seshat-reader-search-sidebar-next
  "p"   #'seshat-reader-search-sidebar-prev
  "j"   #'next-line
  "k"   #'previous-line)

(defconst seshat-reader-search--sidebar-line-spacing 2
  "搜索结果侧栏的行距（`line-spacing'，单位像素）.
侧栏每条命中是一行「[p.N] 片段」，窄栏里片段会折成两三行；行距为 0 时相邻
命中在视觉上粘成一片，辨认成本明显高于占用的那点高度。取 2：条目之间能看出
分界，又不会让一屏装不下几条。用 `setq-local' 写进侧栏 buffer，只影响该
buffer，不改全局 `line-spacing'。")

(defun seshat-reader-search--render-sidebar (matches)
  "Render MATCHES into the search sidebar buffer and show the panel.
The sidebar is a **read-only text buffer** (\\`special-mode', `q' closes only
this panel) listing one line per hit — \"[p.PAGE] snippet\" — under a header
stating the query and how many hits were found.  Width comes from the panel
machinery: kind `search' is pinned to the left side and takes the slot after
`outline', so it coexists with the table of contents instead of replacing it.
Line spacing is set to `seshat-reader-search--sidebar-line-spacing' (2 px) so
consecutive hits stay visually separated in the narrow column; it is a
buffer-local `line-spacing', not a global setting.

MATCHES is the search module's flat hit list (PAGE X0 Y0 X1 Y1 ...), i.e. the
value of `seshat-reader-search--matches'.  Rendering happens **in the buffer of
the caller**: that buffer is recorded as the sidebar's source
\(`seshat-reader-search--sidebar-source') so the sidebar commands can act on
the reading buffer even while point sits in the sidebar.

The panel is displayed with SELECT non-nil (cursor moves into the sidebar at
the end of the command) — the search is finished at that point and the next
keystroke is expected to be a result choice, not a page turn.  Displaying never
signals: a missing or failing panel backend must not break a search that
already succeeded, so the call is wrapped in `ignore-errors'.

每行的行首另记进 `--sidebar-markers'（marker 列表，与 `--sidebar-matches'
同序），供 `--sidebar-sync' 在阅读 buffer 里切换命中时把侧栏滚到对应条目；
渲染结束时立刻同步一次，故侧栏一出现就指着当前命中。片段文本在**进入侧栏
buffer 之前**取（C 侧矩形查询要求当前 buffer 就是文档 buffer）。"
  (let ((query seshat-reader-search--query)
        (source (current-buffer))
        (entries (seshat-reader-search--sidebar-entries matches))
        (buffer (get-buffer-create seshat-reader-search-sidebar-buffer-name))
        (index 0))
    ;; 片段**必须**在阅读 buffer（= 当前 buffer，也就是调用者）里取：C 侧的
    ;; `--lines-in-rect' / `--text-in-rect' 先经 `get_reader_current_state' 校验
    ;; 「当前 buffer 就是文档 buffer」（文档状态指针是 permanent buffer-local，
    ;; overlay 的 buffer 还必须等于 `(current-buffer)'）。在侧栏 buffer 里调用
    ;; 一律失败且 `--snippet' 静默降级，于是每条只剩「[p.N]」——这正是真机上
    ;; 「匹配信息显示不完整」的成因。故先在这里逐条算出整行文本，再进侧栏
    ;; buffer 写入。
    (let ((rows (mapcar (lambda (entry)
                          (cons entry (seshat-reader-search--sidebar-line entry)))
                        entries)))
      (with-current-buffer buffer
        (special-mode)
        (let ((inhibit-read-only t)
              (markers nil))
          (erase-buffer)
          ;; 旧高亮 overlay 的位置随内容一起失效，重建时先丢弃。
          (when (overlayp seshat-reader-search--sidebar-cursor)
            (delete-overlay seshat-reader-search--sidebar-cursor)
            (setq seshat-reader-search--sidebar-cursor nil))
          (insert (seshat-reader-search--sidebar-header
                   query (length matches) (length entries)))
          (dolist (row rows)
            (let ((start (point)))
              (insert (propertize (concat (cdr row) "\n")
                                  'seshat-reader-search-sidebar-entry (car row)
                                  'seshat-reader-search-sidebar-index index))
              ;; marker 记行首：`copy-marker' 不推进（插入型为 nil），故对
              ;; 之后任何插入/删除都仍然指向这一行的开头。
              (push (copy-marker start) markers)
              (setq index (1+ index))))
          (setq seshat-reader-search--sidebar-matches entries)
          (setq seshat-reader-search--sidebar-markers (nreverse markers))
          (setq seshat-reader-search--sidebar-source source)
          (use-local-map seshat-reader-search--sidebar-map)
          ;; 折行：侧栏很窄，片段必须折行而不是横向溢出（`special-mode' 默认
          ;; 不折行，故显式置 nil）。
          (setq truncate-lines nil)
          (setq word-wrap t)
          ;; 行距：条目之间留出可见间隔（见
          ;; `seshat-reader-search--sidebar-line-spacing'）。
          (setq-local line-spacing seshat-reader-search--sidebar-line-spacing)
          (goto-char (point-min))
          (set-buffer-modified-p nil)
          (setq buffer-read-only t))))
    ;; 防御性关闭侧栏 buffer 的 evil：显示路径 `seshat-reader-sidebar--display'
    ;; 已关过一次，这里再幂等关一次，保证即使显示路径改变（或显示失败）侧栏
    ;; 也仍由 `seshat-reader-search--sidebar-map' 说了算——evil 的 normal state
    ;; 会经 `emulation-mode-map-alists' 抢走 j / k / n / p。evil 是软依赖，
    ;; `fboundp' 守卫让未加载 evil 时静默跳过；必须切到 **侧栏 buffer**：此处
    ;; 当前 buffer 是阅读 buffer，不能顺手关掉阅读器的 evil。
    (when (and (fboundp 'seshat-reader--disable-evil)
               (buffer-live-p buffer))
      (with-current-buffer buffer
        (seshat-reader--disable-evil)))
    (ignore-errors (seshat-reader-sidebar-show buffer 'search t))
    ;; 渲染后立即定位一次：侧栏刚建好时应当指着**当前**命中（搜索从文档中部
    ;; 开始时 `--index' 不是 0），而不是停在标题行。
    (seshat-reader-search--sidebar-sync (or seshat-reader-search--index 0))
    buffer))

;;;; 临时键表（n / p / RET / C-g）

(defvar-keymap seshat-reader-search--map
  :doc "Keymap of an active `seshat-reader-search' session.
Armed with `set-transient-map', so it shadows `seshat-reader-mode-map'
only while the session lasts: `n' / `p' mean next / previous hit here but
paging everywhere else."
  "n"   #'seshat-reader-search-next
  "p"   #'seshat-reader-search-prev
  "RET" #'seshat-reader-search-accept
  "C-g" #'seshat-reader-search-quit)

(defun seshat-reader-search--arm-transient-map (&optional buffer)
  "Arm `seshat-reader-search--map' for BUFFER (default: the current buffer).
The keep predicate requires both an active session and the same buffer, so
switching away from the document exits the session cleanly instead of
shadowing keys in an unrelated buffer.  The session flag is read from BUFFER
itself (not from whatever buffer the next command happens to run in), so the
predicate stays correct when it fires after the reader switched to another
window.

BUFFER is explicit rather than implicitly `(current-buffer)' so the map can
also be re-armed from the sidebar jump path (`--sidebar-jump-in', which runs
inside the reader buffer) — the map is dropped as soon as one command runs in
a different buffer (e.g. the sidebar), and a stale-free re-arm is what makes
`n' / `p' work again after the reader comes back from the sidebar."
  (let ((buffer (or buffer (current-buffer))))
    (set-transient-map seshat-reader-search--map
                       (lambda ()
                         (and (eq buffer (current-buffer))
                              (buffer-live-p buffer)
                              (buffer-local-value 'seshat-reader-search--active
                                                  buffer))))))

;;;; 交互命令

(defun seshat-reader-search--move (step)
  "Move STEP hits forward (positive) or backward (negative), wrapping once.
STEPS that run off either end wrap around and report it, so a reader never
gets stuck at the last hit without knowing the search is cyclic."
  (cond
   ((not seshat-reader-search--active)
    (message "没有进行中的搜索（`C-s' 开始）"))
   ((null seshat-reader-search--matches)
    (message "没有命中可跳转"))
   (t
    (let* ((total (length seshat-reader-search--matches))
           (new (+ (or seshat-reader-search--index 0) step))
           (notice nil))
      (cond
       ((>= new total) (setq new 0 notice "已回绕到文档开头"))
       ((< new 0) (setq new (1- total) notice "已回绕到文档末尾")))
      (setq seshat-reader-search--index new)
      (seshat-reader-search--show notice)))))

(defun seshat-reader-search-next ()
  "Jump to the next hit of the active search, wrapping at the end."
  (interactive)
  (seshat-reader-search--move 1))

(defun seshat-reader-search-prev ()
  "Jump to the previous hit of the active search, wrapping at the start."
  (interactive)
  (seshat-reader-search--move -1))

(defun seshat-reader-search--end (&optional page)
  "End the search session, optionally returning to PAGE (1-based).
Clears the hit decorations (via a full redraw, so annotations and the flash
stay), and leaves the page where the search ended unless PAGE is given."
  (setq-local seshat-reader-search--active nil)
  (seshat-reader-search--uninstall-hook)
  (when (and (integerp page) (/= page (seshat-reader-search--current-page)))
    (seshat-reader-search--goto-page page))
  (seshat-reader-search--redraw)
  (message "搜索结束"))

(defun seshat-reader-search-accept ()
  "End the search session, staying on the current hit's page."
  (interactive)
  (seshat-reader-search--end))

(defun seshat-reader-search-quit ()
  "Cancel the search session and return to the page it started on."
  (interactive)
  (seshat-reader-search--end seshat-reader-search--origin-page))

(defun seshat-reader-search--start (query)
  "Start a search session for QUERY, reporting the first hit at or after point.
The scan is document-wide (so the status can show \"i of N\"), every page is
cached, and the session is armed with `seshat-reader-search--map'.  The same
hits are rendered into the search sidebar as well, and the cursor is moved
there at the end of the command (see
`seshat-reader-search--render-sidebar') — page highlighting and the transient
keymap of the reading buffer stay exactly as before, the sidebar is an
additional view of the same result set.
When nothing matches anywhere, no session is started and the user is told
so."
  (setq seshat-reader-search--query query)
  (setq seshat-reader-search--page-results (make-hash-table :test #'equal))
  (setq seshat-reader-search--origin-page (seshat-reader-search--current-page))
  (setq seshat-reader-search--capped nil)
  (setq seshat-reader-search--doc-id (seshat-reader-search--current-doc-id))
  (seshat-reader-search--scan)
  (cond
   ((null seshat-reader-search--matches)
    (setq seshat-reader-search--index nil)
    (setq seshat-reader-search--active nil)
    (seshat-reader-search--uninstall-hook)
    (seshat-reader-search--redraw)
    (message "未找到 \"%s\"" query))
   (t
    (setq seshat-reader-search--index
          (or (seshat-reader-search--first-index-from
               seshat-reader-search--origin-page)
              0))
    (setq seshat-reader-search--active t)
    (seshat-reader-search--install-hook)
    (seshat-reader-search--show)
    ;; 并存视图：同一批命中同时列进左侧面板（光标在命令结束时切过去）。
    ;; 放在 `--show' 之后——页面高亮与状态行先就位，侧栏只是附加视图；渲染
    ;; 失败也不能影响已经成立的搜索会话。
    (seshat-reader-search--render-sidebar seshat-reader-search--matches)
    ;; 显式传当前 buffer 给临时键表：`--render-sidebar' 的 `post-command-select-window'
    ;; 虽然在**命令结束后**才把光标移进侧栏，但显式传参让这里的意图不依赖那个
    ;; 时序细节。
    (seshat-reader-search--arm-transient-map (current-buffer)))))

;;;###autoload
(defun seshat-reader-search (needle)
  "Search NEEDLE across every page of the current document.
Hits are highlighted on the page in `seshat-reader-search-color' /
`seshat-reader-search-alpha' and the echo area shows
\"第 i/N 个命中 · 第 p 页\".  While the session lasts, `n' / `p' walk the
hits (wrapping around with a notice), `RET' ends the session on the current
page and `C-g' cancels it and returns to the page the search started on.

This command owns `C-s' inside `seshat-reader-mode-map', which means the
global command `isearch-forward' is deliberately shadowed in reader buffers: the
page is an image, so isearch cannot find body text anyway.  `n' / `p'
remain paging outside the session.  A page whose hit count reaches the
per-page ceiling (min of `seshat-reader-search-limit' and 1024) is reported
as truncated instead of silently shortened.

The hits are also listed in the **search sidebar** (buffer
`seshat-reader-search-sidebar-buffer-name', left side, one \"[p.N] snippet\"
line per hit) and the cursor moves into it when the search finishes.  There
`RET' jumps to the hit on the current line, `n' / `p' walk the list and `q'
closes only this panel."
  (interactive (list (read-string "搜索: ")))
  (cond
   ((not (seshat-reader-search--available-p))
    (message "搜索不可用：动态模块未加载（`seshat-reader-dyn--search-page'）"))
   ((or (not (stringp needle)) (string-empty-p (string-trim needle)))
    (message "搜索串为空"))
   (t
    (seshat-reader-search--start (string-trim needle)))))

;; 自研扩展一律在自己的模块里注册键位（与 annotation / reference / translate
;; 一致）：不往 vendored 的 `seshat-reader.el' 里塞本地键位。
(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-s") #'seshat-reader-search)
  ;; `/` 是 search 模块自己补的第二入口（与 `C-s' 双绑）：阅读器自身不绑 `/`。
  (define-key seshat-reader-mode-map (kbd "/") #'seshat-reader-search))

;; 把搜索结果侧栏登记为面板 kind `search'：`seshat-reader-sidebar' 是零依赖的
;; 承载层（不 require 本模块），故由**创建该 buffer 的模块**在此声明
;; 「`*Seshat Search*' 属于 kind `search'」。登记后
;; `seshat-reader-sidebar-buffer-p' / `--kind-for-buffer-name' 认得它，于是：
;; ① `q'（`seshat-reader-sidebar-quit'）按 kind 只关侧栏；
;; ② `M-o' 的「重开最近面板」能覆盖侧栏（`--last-buffers' 按 kind 记忆）；
;; ③ popper 分流（`seshat-reader-sidebar-display-buffer'）按 `search' 处理它。
;; 放在文件末尾而不是变量定义处：登记的是「本模块加载完成」这一事实，且必须在
;; `seshat-reader-sidebar-extra-kinds' 已绑定（顶部 require 已保证）之后。
(add-to-list 'seshat-reader-sidebar-extra-kinds
             (cons seshat-reader-search-sidebar-buffer-name 'search))

(provide 'seshat-reader-search)
;;; seshat-reader-search.el ends here
