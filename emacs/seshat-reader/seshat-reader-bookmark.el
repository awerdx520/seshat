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

(defun seshat-reader-bookmark-make-record  ()
  "Create a bookmark seshat-reader doc record."
  (append (bookmark-make-record-default nil t 1)
          (list (cons 'page (seshat-reader-current-doc-pagenumber))
		(cons 'scale (seshat-reader-current-doc-scale-value))
		(cons 'hscroll (window-hscroll))
		(cons 'vscroll (window-vscroll))
		'(handler . seshat-reader-bookmark-jump))))

;;;###autoload
(defun seshat-reader-bookmark-jump (bookmark)
  "Handles BOOKMARK for record type returned by `seshat-reader-bookmark-make-record'."
  (let ((page (bookmark-prop-get bookmark 'page))
        (file (bookmark-prop-get bookmark 'filename))
        (scale (bookmark-prop-get bookmark 'scale))
	(hscroll (bookmark-prop-get bookmark 'hscroll))
	(vscroll (bookmark-prop-get bookmark 'vscroll)))
    (bookmark-default-handler bookmark)
    (when (file-exists-p file)
      (switch-to-buffer (current-buffer))
      (unless (derived-mode-p 'seshat-reader-mode)
	(seshat-reader-mode))
      (seshat-reader-goto-page page)
      ;; P1：单页时代的 `seshat-reader-doc-scale-page'（走 C 侧按页缩放）已删除，
      ;; 缩放口径改为 buffer 级的 base scale，故这里直接设 base scale。存的是绝对
      ;; 比例（不是增量），且不传 SOURCE，免得把「手动缩放」标成 fit。
      (when (numberp scale)
        (seshat-reader--multipage-set-scale scale))
      (seshat-reader--center-page)
      (set-window-hscroll nil hscroll)
      (set-window-vscroll nil vscroll))))

  (put 'seshat-reader-bookmark-jump 'bookmark-handler-type "Seshat Reader")

(provide 'seshat-reader-bookmark)
;;; seshat-reader-bookmark.el ends here
