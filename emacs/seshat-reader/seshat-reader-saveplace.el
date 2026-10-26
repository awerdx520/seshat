;;; seshat-reader-saveplace.el --- Saveplace integration with seshat-reader  -*- lexical-binding: t; -*-

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

;; Bookmarks need to be stored inside a vector due to hard-coded logic
;; within `save-place--normalize-alist'.  Specifically, it performs
;; operations on an element assuming it's a list, and this leads to
;; issues when we try to use it like a bookmark.

;;; Acknowledgments:

;; `saveplace-pdf-view' by Nicolai Singh <nicolaisingh@pm.me> was used
;; for reference.

;;; Code:

(require 'bookmark)
(require 'saveplace)
(require 'seshat-reader-bookmark)

;;;###autoload
(defun seshat-reader--saveplace-find-file ()
  "Restore saved place in `seshat-reader-mode' buffers.

To be added to `save-place-after-find-file-hook'.  See also `seshat-reader--saveplace-to-alist'."
  (or save-place-loaded (save-place-load-alist-from-file))
  (when (derived-mode-p 'seshat-reader-mode)
    (if-let* ((place (assoc buffer-file-name save-place-alist))
	      (bookmark (aref (cdr place)  0))) ; get back the bookmark
        (seshat-reader-bookmark-jump bookmark))))

;;;###autoload
(add-hook 'save-place-after-find-file-hook #'seshat-reader--saveplace-find-file)

;;;###autoload
(defun seshat-reader--saveplace-to-alist ()
  "Save place in `seshat-reader-mode' buffers.

Used for advice around `save-place-to-alist'.  See also
`seshat-reader--saveplace-find-file'."
  ;; P1：记录内容完全由 `seshat-reader-bookmark-make-record' 决定，即
  ;; page / offset（页内像素偏移，取代单页时代的 vscroll）/ hscroll / scale /
  ;; fit-mode；恢复走 `seshat-reader-bookmark-jump'，旧记录里的 `vscroll' 由
  ;; `seshat-reader-bookmark--entry-offset' 迁移为页内偏移。
  (when-let* ((filename buffer-file-name)
	      (bookmark-record (seshat-reader-bookmark-make-record))
	      (bookmark (cons "seshat-reader-saveplace" bookmark-record)))
    (setq save-place-alist
          (assoc-delete-all filename save-place-alist))
    ;; store bookmark inside a vector
    (push (cons filename (vector bookmark)) save-place-alist)))

;;;###autoload
(advice-add 'save-place-to-alist :around (lambda (orig-fun &rest args)
					   (if (derived-mode-p 'seshat-reader-mode)
					       (seshat-reader--saveplace-to-alist)
					     (apply orig-fun args))))

(provide 'seshat-reader-saveplace)
;;; seshat-reader-saveplace.el ends here
