;;; seshat-reader-bookmark.el --- Bookmarks integration for seshat-reader -*- lexical-binding: t; -*-

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
(require 'bookmark)

;; P1（多页布局）字段变更：书签记录的位置从「页号 + `vscroll'」改为
;; 「页号 + `offset' + `hscroll' + `scale' + `fit-mode'」：
;;
;;   page      1-based 页号，取 `seshat-reader-current-doc-pagenumber'，即
;;             视口顶页（多页布局下一屏多页，只能锚定顶页）。
;;   offset    页内**像素**偏移，取 `(window-vscroll nil t)'。一页在 buffer 里
;;             是一行，所以窗口的像素 vscroll 就是「这一页滚到了哪里」，不再需
;;             要单页时代的 `vscroll' 行数语义。
;;   hscroll   横向滚动（宽页贴左时的位置）。
;;   scale     显式缩放比例（base scale）；恢复时按 `manual' 处理，resize 不再
;;             用 fit 覆盖它。
;;   fit-mode  适配模式（`contain' / `width' / `height' / `manual'）。
;;
;; 迁移规则：旧记录只有 `vscroll'（单页时代的行数式滚动）时，按「页号 + 该值
;; 近似为页内偏移」读入；读不到（nil / 非数）就落到页首。旧记录里的
;; `vscroll' 字段本身不再写入，故新记录不会再产出它。

(defun seshat-reader-bookmark--current-offset ()
  "Return the page-internal pixel offset of the selected window."
  (let ((vscroll (ignore-errors (window-vscroll nil t))))
    (if (numberp vscroll) vscroll 0)))

(defun seshat-reader-bookmark--entry-offset (bookmark)
  "Return the page-internal pixel offset recorded in BOOKMARK.

The `offset' field is the P1 one; a record written before P1 only has
`vscroll' (whole lines, single-page layout), which is migrated to a pixel
offset as-is and used as an approximation.  nil / a non-number falls back to
0, i.e. the top of the page."
  (let ((offset (or (bookmark-prop-get bookmark 'offset)
                    ;; 旧字段迁移（P1 之前只有这个）
                    (bookmark-prop-get bookmark 'vscroll))))
    (if (and (numberp offset) (> offset 0)) offset 0)))

(defun seshat-reader-bookmark-make-record  ()
  "Create a bookmark seshat-reader doc record."
  (append (bookmark-make-record-default nil t 1)
          (list (cons 'page (seshat-reader-current-doc-pagenumber))
		(cons 'offset (seshat-reader-bookmark--current-offset))
		(cons 'hscroll (window-hscroll))
		(cons 'scale (seshat-reader-current-doc-scale-value))
		(cons 'fit-mode (seshat-reader--multipage-current-fit-mode))
		'(handler . seshat-reader-bookmark-jump))))

;;;###autoload
(defun seshat-reader-bookmark-jump (bookmark)
  "Handles BOOKMARK for record type returned by `seshat-reader-bookmark-make-record'.

The recorded place is restored in this order:

1. `fit-mode' + `scale' — applied first, because resizing the pages changes
   where the row of the target page sits.  This step is **skipped when the
   jump happens inside a `seshat-reader-mode' buffer**: the zoom mode (`W' /
   `H' / manual) and the scale the user is looking at right now are kept as
   they are, and only the place (steps 2-4) moves — a bookmark jump is meant
   to move the view, not to change it, so a record saved days ago must not
   undo a fit chosen for this window.  A jump that **opens a document** (the
   buffer was not a reader buffer before the jump, e.g. `save-place' or a
   bookmark of an unread document) has no current view to inherit and applies
   the recorded values: `manual' (or a missing mode) restores the recorded
   explicit `scale' as a manual zoom, so a later window resize does not
   replace it with a fit; `contain' / `width' / `height' instead restore the
   base scale that mode implies for the reference page
   \\(`seshat-reader--multipage-base-fit-scale'), which keeps the same fit
   behaviour across resizes — the recorded `scale' is then not used, because a
   fit scale has to be recomputed from the current window.  A missing or
   non-numeric value skips that step.
2. `page' — `seshat-reader--multipage-goto', which lands on the **top** of the
   page and clears the pixel scroll of the window.
3. `offset' — the page-internal pixel offset, re-applied on top of that top
   \\(old records only carry `vscroll', migrated by
   `seshat-reader-bookmark--entry-offset').  This step has to force one frame
   after the `goto' and only then write the offset: a pixel scroll set in the
   same frame as the new `window-start' the `goto' installed is dropped, so
   writing it in the same frame would leave the view on the top of the page.
4. `hscroll' — horizontal position, for a page wider than the window."
  (let ((page (bookmark-prop-get bookmark 'page))
        (file (bookmark-prop-get bookmark 'filename))
        ;; 必须在 handler **之前**取：`bookmark-default-handler' 会切 buffer，
        ;; 切完就再也看不出「跳转前」是不是已经在这个阅读 buffer 里了。
        (reader-buffer-p (derived-mode-p 'seshat-reader-mode))
        (scale (bookmark-prop-get bookmark 'scale))
	(hscroll (bookmark-prop-get bookmark 'hscroll))
	(offset (seshat-reader-bookmark--entry-offset bookmark)))
    (bookmark-default-handler bookmark)
    (when (file-exists-p file)
      (switch-to-buffer (current-buffer))
      (unless (derived-mode-p 'seshat-reader-mode)
	(seshat-reader-mode))
      ;; ① 缩放**只在「新开文档」时**按记录恢复（跳转前不是阅读 buffer）。
      ;; 同一阅读 buffer 内跳书签时这一步整体跳过：用户此刻的 W/H/manual 与
      ;; 缩放保持不动——跳转只该移动视图，不该改动正在使用的视图。新开文档
      ;; 没有「当前视图」可继承，才用记录的 fit 模式（`manual' 或缺失 → 记录
      ;; 的显式 scale；`contain' / `width' / `height' → 该模式的基准页 fit，
      ;; resize 后行为一致，且不依赖记录里那个已过期的 scale）。这一步仍排在
      ;; 页号之前：页行高度变了，目标页的位置才稳定。
      (unless reader-buffer-p
        (let ((mode (bookmark-prop-get bookmark 'fit-mode)))
          (cond
           ((memq mode '(contain width height))
            (let ((fit (seshat-reader--multipage-base-fit-scale mode)))
              (when (numberp fit)
                (seshat-reader--multipage-set-scale fit 'fit mode))))
           ((and (numberp scale) (> scale 0))
            (seshat-reader--multipage-set-scale scale 'manual 'manual)))))
      ;; ② 跳到目标页（`--multipage-goto' 会把页内偏移清零，停在页首）。
      (when (numberp page)
        (seshat-reader--multipage-goto page))
      ;; ③ 再叠加页内像素偏移。`--multipage--apply-offset' 会先强制落一帧再写
      ;; 偏移：与新设 window-start 同帧的像素偏移会被 Emacs 丢弃。
      (when (and (numberp offset) (> offset 0))
        (seshat-reader--multipage--apply-offset nil offset))
      ;; ④ 横向位置。
      (when (numberp hscroll)
        (set-window-hscroll nil hscroll)))))

  (put 'seshat-reader-bookmark-jump 'bookmark-handler-type "Seshat Reader")

(provide 'seshat-reader-bookmark)
;;; seshat-reader-bookmark.el ends here
