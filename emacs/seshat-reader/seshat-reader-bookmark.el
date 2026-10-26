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
   where the row of the target page sits.  The recorded **fit mode takes part
   in the restore**: `manual' (or a missing mode) restores the recorded
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
   `seshat-reader-bookmark--entry-offset').
4. `hscroll' — horizontal position, for a page wider than the window."
  (let ((page (bookmark-prop-get bookmark 'page))
        (file (bookmark-prop-get bookmark 'filename))
        (scale (bookmark-prop-get bookmark 'scale))
	(hscroll (bookmark-prop-get bookmark 'hscroll))
	(offset (seshat-reader-bookmark--entry-offset bookmark)))
    (bookmark-default-handler bookmark)
    (when (file-exists-p file)
      (switch-to-buffer (current-buffer))
      (unless (derived-mode-p 'seshat-reader-mode)
	(seshat-reader-mode))
      ;; ① 先恢复缩放：页行高度变了，目标页的位置才稳定。记录的 fit 模式参与
      ;; 恢复：`manual' 或缺失 → 用记录的显式 scale；`contain' / `width' /
      ;; `height' → 用该模式的基准页 fit（resize 后行为一致，且不依赖记录里
      ;; 那个已过期的 scale）。
      (let ((mode (bookmark-prop-get bookmark 'fit-mode)))
        (cond
         ((memq mode '(contain width height))
          (let ((fit (seshat-reader--multipage-base-fit-scale mode)))
            (when (numberp fit)
              (seshat-reader--multipage-set-scale fit 'fit mode))))
         ((and (numberp scale) (> scale 0))
          (seshat-reader--multipage-set-scale scale 'manual 'manual))))
      ;; ② 跳到目标页（`--multipage-goto' 会把页内偏移清零，停在页首）。
      (when (numberp page)
        (seshat-reader--multipage-goto page))
      ;; ③ 再叠加页内像素偏移。
      (when (and (numberp offset) (> offset 0))
        (ignore-errors (set-window-vscroll nil offset t)))
      ;; ④ 横向位置。
      (when (numberp hscroll)
        (set-window-hscroll nil hscroll)))))

  (put 'seshat-reader-bookmark-jump 'bookmark-handler-type "Seshat Reader")

(provide 'seshat-reader-bookmark)
;;; seshat-reader-bookmark.el ends here
