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

(declare-function seshat-reader-dyn--search-page "seshat-render-core"
                  (page needle limit))
(declare-function seshat-reader-dyn--clear-highlights "seshat-render-core" ())
(declare-function seshat-reader-dyn--add-decoration "seshat-render-core"
                  (page x0 y0 x1 y1 r g b alpha))
(declare-function seshat-reader-dyn--refresh-highlights "seshat-render-core" ())

;; 该变量由 C 模块（`permanent_buffer_local_var'）注册为 buffer-local，编译期
;; 不可见；在此声明以消除 byte-compiler 的 free variable 警告。
(defvar seshat-reader-current-doc-pagecount nil
  "Total page count of the current document, set by the native module.")

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
as well, since a session that no longer exists has nothing to contribute."
  (setq seshat-reader-search--active nil)
  (setq seshat-reader-search--query nil)
  (setq seshat-reader-search--page-results nil)
  (setq seshat-reader-search--matches nil)
  (setq seshat-reader-search--index nil)
  (setq seshat-reader-search--truncated-pages nil)
  (setq seshat-reader-search--capped nil)
  (setq seshat-reader-search--origin-page nil)
  (setq seshat-reader-search--doc-id nil)
  (seshat-reader-search--set-extra-hook nil))

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
the degraded path in `seshat-reader-search--redraw' is used instead."
  (seshat-reader-search--set-extra-hook
   #'seshat-reader-search--active-decorations))

(defun seshat-reader-search--uninstall-hook ()
  "Stop contributing decorations to the annotation redraw path."
  (seshat-reader-search--set-extra-hook nil))

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
  "Display the page of the current hit, if it is not the visible page."
  (let ((match (nth seshat-reader-search--index seshat-reader-search--matches)))
    (when (and match (integerp (nth 0 match))
               (/= (nth 0 match) (seshat-reader-search--current-page)))
      (seshat-reader-search--goto-page (nth 0 match)))))

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

(defun seshat-reader-search--arm-transient-map ()
  "Arm `seshat-reader-search--map' until the session ends or another key runs.
The keep predicate requires both an active session and the same buffer, so
switching away from the document exits the session cleanly instead of
shadowing keys in an unrelated buffer."
  (let ((buffer (current-buffer)))
    (set-transient-map seshat-reader-search--map
                       (lambda ()
                         (and seshat-reader-search--active
                              (eq buffer (current-buffer)))))))

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
cached, and the session is armed with `seshat-reader-search--map'.
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
    (seshat-reader-search--arm-transient-map))))

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
as truncated instead of silently shortened."
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
  (define-key seshat-reader-mode-map (kbd "C-s") #'seshat-reader-search))

(provide 'seshat-reader-search)
;;; seshat-reader-search.el ends here
