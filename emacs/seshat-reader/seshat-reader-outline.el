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
(require 'imenu)
(require 'outline)

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

;;; Outline

(defvar-local seshat-reader-outline--doc-buffername nil
  "Name of the document buffer whose outline was generated.")

(defvar-local seshat-reader-outline--doc-window nil
  "The window from where the outline was generated.")

;;;###autoload
(defun seshat-reader-outline-show ()
  "Show the document outline in a separate buffer.

The outline buffer inherits it's name from the original
document it was created from."
  (interactive)
  (unless (derived-mode-p 'seshat-reader-mode)
    (user-error "Not in a seshat-reader-mode buffer"))
  (unless seshat-reader-current-doc-outline
    (user-error "This document has no outline"))
  (let* ((outline-data seshat-reader-current-doc-outline)
         (source-buffer (current-buffer))
         (bufname (format "*Outline of %s*" (buffer-name source-buffer))))
    (with-current-buffer (get-buffer-create bufname)
      (when-let* ((emptyp (= 0 (buffer-size)))
		  (inhibit-read-only t))
        (seshat-reader-outline-mode)
	(setq seshat-reader-outline--doc-buffername (buffer-name source-buffer))
	(setq seshat-reader-outline--doc-window (get-buffer-window source-buffer))
        (seshat-reader--outline-insert-outline outline-data 1)
	(goto-char (point-min))))
    (pop-to-buffer bufname)))

(defun seshat-reader--outline-insert-outline (outline level)
  "Recursively insert OUTLINE entries at LEVEL.

Each heading title is its own clickable button."
  (dolist (entry outline)
    (let ((title (plist-get entry :title))
          (page (1+ (plist-get entry :page))) ; MuPDF does 0-indexing
	  (children (plist-get entry :children)))
      ;; This cannot be part of label (title) because that will
      ;; obscure the outline TAB bindings with button bindings.
      (insert (concat (make-string level ?*) " "))
      (insert-text-button
       title
       'seshat-reader-page page
       'action #'seshat-reader-outline-goto-entry
       'follow-link t
       'help-echo "Jump to section.")
      (insert "\n")
      (if children
          (seshat-reader--outline-insert-outline children (1+ level))))))

(defun seshat-reader-outline-select-doc-window ()
  "Display and switch to the original document's window."
  (interactive)
  (let ((buf (get-buffer seshat-reader-outline--doc-buffername)))
    (unless (buffer-live-p buf)
      (user-error "Document buffer no longer exists"))
    (let ((win (or (and (window-live-p seshat-reader-outline--doc-window)
			(eq (window-buffer seshat-reader-outline--doc-window) buf)
			seshat-reader-outline--doc-window)
		   (get-buffer-window buf))))
      (if win
	  (select-window win)
	(pop-to-buffer buf))
      (setq seshat-reader-outline--doc-window (selected-window)))))

(defvar-keymap seshat-reader-outline-mode-map
  :doc "Keymap for `seshat-reader-outline-mode'"
  "p"        #'previous-line
  "n"        #'next-line
  "o"        #'seshat-reader-outline-select-doc-window
  "q"        #'quit-window
  "RET"      #'seshat-reader-outline-visit-page
  "M-RET"    #'seshat-reader-outline-visit-page)

(define-derived-mode seshat-reader-outline-mode outline-mode "Seshat Reader Outline"
  "Major mode for navigating document outlines."
  (setq buffer-read-only t)
  (setq-local outline-regexp "^\\*+ ")
  (use-local-map seshat-reader-outline-mode-map))

(defun seshat-reader-outline-goto-entry (button)
  "Shared logic to jump to an outline BUTTON."
  (let ((page (button-get button 'seshat-reader-page)))
    (unless (numberp page)
      (user-error "Invalid outline entry: no page info"))
    (seshat-reader-outline-select-doc-window)
    ;; activates `window-buffer-change-functions' and `window-configuration-change-hook'
    (redisplay)
    (seshat-reader-goto-page page)))

(defun seshat-reader-outline-visit-page ()
  "Jump to the page at point in the associated seshat-reader buffer."
  (interactive)
  (save-excursion
    (end-of-line)   ; This is done to make sure the we always have a
    (backward-char) ; button at point.
    (seshat-reader-outline-goto-entry (button-at (point)))))

(provide 'seshat-reader-outline)
;;; seshat-reader-outline.el ends here
