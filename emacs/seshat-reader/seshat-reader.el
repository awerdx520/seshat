;;; seshat-reader.el --- General-purpose Document Reader -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026  Divya Ranjan Pattanaik
;; Copyright (C) 2025-2026  Tushar

;; Author: Divya Ranjan Pattanaik <divya@subvertising.org>
;; Keywords: lisp, files, tools
;; Version: 0.3.2
;; Package-Requires: ((emacs "26.1"))
;; URL: https://codeberg.org/divyaranjan/emacs-reader

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

;; This package provides a general purpose document viewer within
;; Emacs by leveraging the use of dynamic modules.  It primarily
;; relies on MuPDF to do the rendering, and Emacs Lisp’s native image
;; displaying capabilities to view the rendered images and manipulate them.

;;; Code:

(require 'image)

(defconst seshat-reader-directory
  (or (and load-file-name
           (file-name-directory load-file-name))
      default-directory)
  "The directory from where seshat-reader was first loaded.")

(defun seshat-reader--load-module ()
  "Load the `seshat-render-core' dynamic module from `seshat-reader-directory'."
  (let ((load-path (cons seshat-reader-directory load-path)))
    (require 'seshat-render-core)))

(defun seshat-reader--module-built-p ()
  "Return non-nil if the dynamic module exists in `seshat-reader-directory'."
  (file-exists-p
   (file-name-concat seshat-reader-directory
		     (concat "seshat-render-core" module-file-suffix))))

(defun seshat-reader--post-build (_buffer status)
  "Load the module if the build finished successfully, per STATUS."
  (if (string-prefix-p "finished" status)
      (progn (seshat-reader--load-module)
	     (mapc (lambda (buff)
		     (with-current-buffer buff
		       (revert-buffer-quick)))
		   (match-buffers '(major-mode . seshat-reader-mode))))
    (message "seshat-reader: module build failed, see *seshat-reader-module-compilation*")))

;;;###autoload
(defun seshat-reader-build ()
  "Build seshat-reader's dynamic module, then load it."
  (interactive)
  (if (not module-file-suffix)
      (error "Dynamic modules are not supported.  Get a newer Emacs!")
    (let ((default-directory seshat-reader-directory)
	  (compilation-buffer-name-function
	   (lambda (_) "*seshat-reader-module-compilation*")))
      (compile (concat "make seshat-render-core" module-file-suffix))
      (with-current-buffer "*seshat-reader-module-compilation*"
	;; Buffer-local hook
	(add-hook 'compilation-finish-functions #'seshat-reader--post-build nil t)))))

;; Try but don't handle error here directly for byte-comp purposes.
(with-demoted-errors
    (require 'seshat-render-core))

;; If the module doesn't exist, compile and load it.
(unless (seshat-reader--module-built-p)
  (when (yes-or-no-p "Build seshat-reader's dynamic module? ")
    (seshat-reader-build)))

(defgroup seshat-reader nil
  "Group for Seshat Reader’s customizations."
  :prefix "seshat-reader-"
  :group 'custom)

(defcustom seshat-reader-enlarge-factor 1.25
  "The fractional amount by which the page would be enlarged."
  :group 'seshat-reader
  :type 'number)

(defcustom seshat-reader-shrink-factor 0.75
  "The fractional amount by which the page would be shrinked."
  :group 'seshat-reader
  :type 'number)

(defcustom seshat-reader-default-fit 'seshat-reader-fit-to-height
  "The default fitting for documents."
  :group 'seshat-reader
  :type '(radio (function-item seshat-reader-fit-to-height)
		(function-item seshat-reader-fit-to-width)))

(defvar-local seshat-reader--recent-scale-fallback 1.0
  "Previous scaling factor applied to the document.")

(defvar-local seshat-reader--reloading nil
  "Boolean flag to represent reloading status of a document.")

;; Setting of `auto-mode-list' fails if not autoloaded.
;;;###autoload
(defconst seshat-reader-supported-formats (list "pdf" "epub" "mobi"
					 "fb2" "xps" "cbz"
					 "docx" "pptx" "xlsx"
					 "odt" "ods" "odp" "odg")
  "File formats supported by the Seshat Reader.")

(defun seshat-reader-current-doc-overlay (&optional window)
  "Overlay parameter for WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (window-parameter (or window (selected-window)) 'overlay))

(defun seshat-reader-current-doc-pagenumber (&optional window)
  "Page number of WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (window-parameter (or window (selected-window)) 'page))

(defun seshat-reader-current-doc-scale-value (&optional window)
  "Scaling factor of WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (or (window-parameter window 'scale) seshat-reader--recent-scale-fallback))

;; We queue some commands because the user is expected to use the
;; commands repeatedly, such as by simply spamming a key. If we don't
;; queue the commands, Emacs may start skipping intermediate commands.

(defvar seshat-reader--command-queue nil
  "Queue of seshat-reader commands to be executed sequentially.")

(defun seshat-reader--process-command-queue ()
  "Process the next command in the queue."
  (when-let* ((cmd (pop seshat-reader--command-queue))
	      (delay 0.0001))
    (funcall cmd)
    (redisplay)
    (run-with-idle-timer delay nil #'seshat-reader--process-command-queue)))

(defun seshat-reader--enqueue-command (cmd args)
  "Add CMD with ARGS to the queue and start processing if needed."
  (push (apply #'apply-partially cmd args) seshat-reader--command-queue)
  (unless (or (active-minibuffer-window)
              (memq #'seshat-reader--process-command-queue post-command-hook))
    (add-hook 'post-command-hook #'seshat-reader--process-command-queue nil t)))

(defmacro seshat-reader--define-queue-command (name arglist docstring interactive &rest body)
  "Define NAME as a seshat-reader command.
Also define a necessary non-queue function.

Much like `defun', except that ARGLIST, DOCSTRING, and INTERACTIVE are
required.

The seshat-reader--non-queue-NAME function is simply defined as a function with
body BODY.

The seshat-reader-NAME command is simply a wrapper around
`seshat-reader--enqueue-command' with seshat-reader--non-queue-NAME as the argument."
  (declare (indent defun)
	   (doc-string 3))
  (let* ((name (symbol-name name))
	 (non-queue-function-name (concat "seshat-reader--non-queue-" name))
	 (queue-function-name (concat "seshat-reader-" name)))
    `(progn

       (defun ,(intern non-queue-function-name) ,arglist
	 ,(format "%s

This is the actual function.
See `%s' for the interactive version."
		  docstring queue-function-name)
	 ,(push 'progn body))

       (defun ,(intern queue-function-name) ,arglist
	 ,(format "%s

This is the queuing function.
See `%s' for the actual definition."
		  docstring non-queue-function-name)
	 ,interactive
	 (seshat-reader--enqueue-command #',(intern non-queue-function-name)
				  ,(remq '&optional (push 'list arglist)))))))

(defun seshat-reader--read-doc-name ()
  "Read a document file name."
  (let* ((regexp (regexp-opt seshat-reader-supported-formats t))
	 (prompt "Open document: ")
	 (file (read-file-name
		prompt nil nil t nil
		(lambda (f)
		  (or (file-directory-p f)
		      (string-match-p regexp f))))))
    (if (file-directory-p file)
	(seshat-reader--read-doc-name) file)))

;;;###autoload
(defun seshat-reader-open-doc (document)
  "Open DOCUMENT for viewing.

This function calls the module function `seshat-reader-dyn--load-doc' from the
dynamic module to render the first page and displays it in a new buffer.

The only formats that can be opened `seshat-reader-supported-formats', any
other file format will simply not show up as a candidate."
  (interactive (list (expand-file-name (seshat-reader--read-doc-name))))
  (switch-to-buffer (create-file-buffer document))
  (setq buffer-file-name document)
  (if (seshat-reader-dyn--load-doc (expand-file-name document) 0)
      (seshat-reader-mode)
    (kill-buffer (current-buffer))))

(define-queue-command next-page ()
  "Go to the next page of the document."
  (interactive)
  (when (seshat-reader-dyn--next-page)
    ;; Must return `t' when the command succeeds.
    (force-mode-line-update) t))

(define-queue-command previous-page ()
  "Go to the previous page of the document."
  (interactive)
  (when (seshat-reader-dyn--prev-page)
    ;; Must return `t' when the command succeeds.
    (force-mode-line-update) t))

(defun seshat-reader-first-page ()
  "Go to the first page of the document."
  (interactive)
  (seshat-reader-dyn--first-page)
  (seshat-reader--center-page)
  (force-mode-line-update))

(defun seshat-reader-last-page ()
  "Go to the last page of the document."
  (interactive)
  (seshat-reader-dyn--last-page)
  (seshat-reader--center-page)
  (force-mode-line-update))

(defun seshat-reader-goto-page (n)
  "Go to page number N in the current document."
  (interactive "nGoto page: ")
  (seshat-reader-dyn--goto-page (- n 1)) ; MuPDF does 0-indexing
  (seshat-reader--center-page))

(defun seshat-reader--get-current-doc-image-size (&optional window)
  "Get the dimensions of the page in WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (let* ((cdr-image (cdr (overlay-get (seshat-reader-current-doc-overlay window) 'display)))
	 (width (plist-get cdr-image :width))
	 (height (plist-get cdr-image :height)))
    (cons width height)))

(defun seshat-reader-doc-scale-page (factor)
  "Scales the page by a given FACTOR.

It also updates `seshat-reader--recent-scale-fallback' and `scale' property of
selected window to reflect the new, possibly clamped scale."
  (when-let* ((factor-clamped (seshat-reader-dyn--scale-page factor)))
    (setq seshat-reader--recent-scale-fallback factor-clamped)
    (set-window-parameter nil 'scale factor-clamped)))

(defun seshat-reader-enlarge-size (&optional scaling-factor)
  "Enlarge the size of the current page by the `seshat-reader-enlarge-factor'.

Optionally scale it by the SCALING-FACTOR.  Scales on selected window."
  (interactive (list (float
		      (* (seshat-reader-current-doc-scale-value) seshat-reader-enlarge-factor))))
  (seshat-reader-doc-scale-page scaling-factor)
  (seshat-reader--center-page))

(defun seshat-reader-shrink-size (&optional scaling-factor)
  "Shrink the size of the current page by the `seshat-reader-shrink-factor'.

Optionally scale it by the SCALING-FACTOR.  Scales on selected window."
  (interactive (list (float
		      (* (seshat-reader-current-doc-scale-value) seshat-reader-shrink-factor))))
  (seshat-reader-doc-scale-page scaling-factor)
  (seshat-reader--center-page))

(defun seshat-reader-reset-size ()
  "Reset the size of the current page to 1.0."
  (interactive)
  (seshat-reader-doc-scale-page 1.0)
  (seshat-reader--center-page))

(defun seshat-reader-fit-to-height ()
  "Scale the current page in the selected window to fit its height."
  (interactive)
  (let* ((image-height (cdr (seshat-reader--get-current-doc-image-size)))
	 (pixel-window-height (window-body-height nil t))
	 (unscaled-height (/ image-height (seshat-reader-current-doc-scale-value)))
	 (scaling-factor (/ pixel-window-height unscaled-height)))
    (seshat-reader-doc-scale-page scaling-factor)
    (seshat-reader--center-page)
    (seshat-reader--set-window-vscroll nil 0)))

(defun seshat-reader-fit-to-width ()
  "Scale the current page in the selected window to fit its width."
  (interactive)
  (let* ((image-width (car (seshat-reader--get-current-doc-image-size)))
	 (pixel-window-width (window-body-width nil t))
	 (unscaled-width (/ image-width (seshat-reader-current-doc-scale-value)))
	 (scaling-factor (/ pixel-window-width unscaled-width)))
    (seshat-reader-doc-scale-page scaling-factor)
    (seshat-reader--center-page)))

(defun seshat-reader--get-pixel-per-col (&optional window)
  "Get the no of pixels per column for WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (/ (window-body-width window t) (window-body-width window)))

;; We need to do this because scrolling is possible in one direction
;; (downwards) indefinitely.

(defun seshat-reader--set-window-vscroll (window vscroll &optional pixels-p)
  "Set amount by which WINDOW should be scrolled vertically to VSCROLL.

If setting VSCROLL makes the document page's top disappear, it sets the
maximum vertical scroll possible without doing that.

If PIXELS-P is non-nil, VSCROLL is considered to be in pixels.
Also see `set-window-vscroll'."
  (let* ((image-height (cdr (seshat-reader--get-current-doc-image-size window)))
	 (pixel-window-height (window-body-height window t))
	 (window-height (window-body-height window))
	 (pixel-per-col (/ pixel-window-height window-height))
	 (pixel-vscroll (* pixel-per-col vscroll))
	 (max-pixel-vscroll (- image-height pixel-window-height))
	 (corrected-pixel-vscroll (min pixel-vscroll max-pixel-vscroll))
	 (corrected-vscroll (/ corrected-pixel-vscroll pixel-per-col)))
    (set-window-vscroll window
			(if pixels-p corrected-pixel-vscroll corrected-vscroll)
			pixels-p)))

;; Most of the scrolling functions here exist because of our handling
;; of centering in `seshat-reader--center-page'.

(defun seshat-reader--get-prefix-width (&optional window)
  "Get the line prefix width set by `seshat-reader--center-page'.

WINDOW must be a valid window and defaults to the selected one."
  (car
   (plist-get
    (cdr (overlay-get (seshat-reader-current-doc-overlay window) 'line-prefix))
    :width)))

(defun seshat-reader--right-most-window-hscroll (&optional window)
  "Get the maximum horizontal scroll value for WINDOW.

This position is at the rightmost point.
WINDOW must be a valid window and defaults to the selected one."
  (let* ((image-width (car (seshat-reader--get-current-doc-image-size window)))
	 (line-prefix-width (seshat-reader--get-prefix-width window))
	 (pixel-window-width (window-body-width window t))
	 (max-ncol (round (/ (max line-prefix-width
				  (- image-width pixel-window-width))
			     (seshat-reader--get-pixel-per-col window)))))
    max-ncol))

(defun seshat-reader--set-window-hscroll (window ncol &optional unconstrained)
  "Set number of columns WINDOW is scrolled from left margin to NCOL.

If setting NCOL makes the document page disappear, it sets the maximum
horizontal scroll possible without doing that.  If UNCONSTRAINED is
non-nil, it allows setting NCOL even if it makes the page disappear.

See also `set-window-hscroll'."
  (let* ((line-prefix-width (seshat-reader--get-prefix-width window))
	 (pixel-per-col (seshat-reader--get-pixel-per-col window))
	 (calibrated-ncol (round (- (/ line-prefix-width pixel-per-col) ncol)))
	 (max-ncol (seshat-reader--right-most-window-hscroll window))
	 (ncol (if unconstrained
		   calibrated-ncol
		 (min calibrated-ncol max-ncol))))
    (set-window-hscroll window ncol)
    (seshat-reader--window-hscroll window)))

(defun seshat-reader--window-hscroll (&optional window)
  "Return the number of columns by which WINDOW is scrolled from left margin.

WINDOW must be a live window and defaults to the selected one.

This correctly handles the prefix width set by seshat-reader documents and does
not return the actual horizontal scroll value; for that, see
`window-hscroll'."
  (let* ((line-prefix-width (seshat-reader--get-prefix-width window))
	 (pixel-per-col (seshat-reader--get-pixel-per-col window))
	 (hscroll (round (- (/ line-prefix-width pixel-per-col) (window-hscroll window)))))
    hscroll))

;; We need this hack involving line-prefix because Emacs' scrolling is
;; idiosyncratic, and doesn't allow arbitrary scrolling in every
;; direction.
(defun seshat-reader--center-page (&optional window)
  "Center the document with respect to WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (when-let* ((overlay (seshat-reader-current-doc-overlay window))
              ((overlayp overlay))
	      (window-width (window-body-width window t))
              (doc-image-width (car (seshat-reader--get-current-doc-image-size window)))
	      (max-left-offset (max 0 (- window-width doc-image-width)))
	      (overlay-offset `(space :width (,max-left-offset)))
	      (pixel-per-col (seshat-reader--get-pixel-per-col window))
	      (doc-left-offset (- window-width doc-image-width))
              (doc-center-offset (/ doc-left-offset 2))
              (scroll-offset (round (/ doc-center-offset pixel-per-col))))
    ;; Add prefix so that the page is at the leftmost point of the window.
    (overlay-put overlay 'line-prefix overlay-offset)
    ;; scroll window back to the center of the doc
    (seshat-reader--set-window-hscroll window scroll-offset t)))

(defun seshat-reader-scroll-up (&optional amount)
  "Scroll up the current page by AMOUNT.

AMOUNT defaults to 1."
  (interactive "p")
  (or amount (setq amount 1))
  (let* ((prev-scroll (window-vscroll))
	 (vscroll (- prev-scroll amount)))
    (- prev-scroll (seshat-reader--set-window-vscroll nil vscroll))))

(defun seshat-reader-scroll-down (&optional amount)
  "Scroll down the current page by AMOUNT.

AMOUNT defaults to 1."
  (interactive "p")
  (or amount (setq amount 1))
  (let* ((prev-scroll (window-vscroll))
	 (vscroll (+ prev-scroll amount)))
    (- (seshat-reader--set-window-vscroll nil vscroll) prev-scroll)))

(defun seshat-reader-scroll-up-screen (&optional amount)
  "Scroll up the current page by a screen.

Unless AMOUNT is specified in which case we scroll by that value."
  (interactive "P")
  (let ((amount (or amount (- (window-body-height)
			      next-screen-context-lines))))
    (when (= 0 (seshat-reader-scroll-up amount))
      (message "Beginning of page"))))

(defun seshat-reader-scroll-down-screen (&optional amount)
  "Scroll down the current page by a screen.

Unless AMOUNT is specified in which case we scroll by that value."
  (interactive "P")
  (let ((amount (or amount (- (window-body-height)
			      next-screen-context-lines))))
    (when (= 0 (seshat-reader-scroll-down amount))
      (message "End of page"))))

(defun seshat-reader-scroll-left (&optional amount)
  "Scroll to the left of the current page by AMOUNT.

AMOUNT defaults to 1.

Only scrolls when the document page width is larger then the window width."
  (interactive "p")
  (or amount (setq amount 1))
  (when-let* (((< (window-body-width nil t) (car (seshat-reader--get-current-doc-image-size))))
	      (prev-scroll (seshat-reader--window-hscroll))
	      (hscroll (+ prev-scroll amount)))
    (- (seshat-reader--set-window-hscroll nil hscroll) prev-scroll)))

(defun seshat-reader-scroll-right (&optional amount)
  "Scroll to the right of the current page by AMOUNT (or 1).

Only scrolls when the document page width is larger then the window width."
  (interactive "p")
  (or amount (setq amount 1))
  (when-let* (((< (window-body-width nil t) (car (seshat-reader--get-current-doc-image-size))))
	      (prev-scroll (seshat-reader--window-hscroll))
	      (hscroll (- prev-scroll amount)))
    (- prev-scroll (seshat-reader--set-window-hscroll nil hscroll))))

(defun seshat-reader-scroll-left-most ()
  "Scroll to the left most point of the current page.

Only scrolls when the document page width is larger then the window width."
  (interactive)
  (when (< (window-body-width nil t) (car (seshat-reader--get-current-doc-image-size)))
    (seshat-reader--set-window-hscroll nil 0)))

(defun seshat-reader-scroll-right-most ()
  "Scroll to the right most point of the current page.

Only scrolls when the document page width is larger then the window width."
  (interactive)
  (when (< (window-body-width nil t) (car (seshat-reader--get-current-doc-image-size)))
    ;; We use `set-window-hscroll' here because we need to go the right
    ;; most point directly, bypassing `'seshat-reader--set-window-hscroll' checks.
    (set-window-hscroll nil (seshat-reader--right-most-window-hscroll))))

(define-queue-command scroll-up-or-prev-page (&optional amount)
  "Scroll up the current page by AMOUNT, otherwise switch to the previous page.

AMOUNT defaults to 1."
  (interactive "p")
  (or amount (setq amount 1))
  (when-let* (((and (= 0 (seshat-reader-scroll-up amount))
		    (seshat-reader--non-queue-previous-page))) ; if succeeds
	      (image-height (cdr (seshat-reader--get-current-doc-image-size)))
	      (pixel-window-height (window-body-height nil t))
	      (bottom-most-scroll-pixel
	       (- image-height pixel-window-height)))
    (seshat-reader--set-window-vscroll nil bottom-most-scroll-pixel t)))

(define-queue-command scroll-down-or-next-page (&optional amount)
  "Scroll down the current page by AMOUNT, otherwise switch to the next page.

AMOUNT defaults to 1."
  (interactive "p")
  (or amount (setq amount 1))
  (when (and (= 0 (seshat-reader-scroll-down amount))
	     (seshat-reader--non-queue-next-page)) ; if succeeds
    (seshat-reader--set-window-vscroll nil 0)))

(define-queue-command scroll-up-screen-or-prev-page ()
  "Scroll up the current page by screen, otherwise switch to the previous page."
  (interactive)
  (let ((scroll (- (window-body-height)
		   next-screen-context-lines)))
    (seshat-reader--non-queue-scroll-up-or-prev-page scroll)))

(define-queue-command scroll-down-screen-or-next-page ()
  "Scroll down the current page by screen, otherwise switch to the next page."
  (interactive)
  (let ((scroll (- (window-body-height)
		   next-screen-context-lines)))
    (seshat-reader--non-queue-scroll-down-or-next-page scroll)))

(define-queue-command mwheel-scroll-up (event)
  "Scroll up or switch to the previous page, but also handle mouse EVENT.

See also `seshat-reader-non-queue-scroll-up-or-prev-page'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('wheel-up 1)
		   ('double-wheel-up 2)
		   ('triple-wheel-up 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader--non-queue-scroll-up-or-prev-page amount))))

(define-queue-command mwheel-scroll-down (event)
  "Scroll down or switch to the next page, but also handle mouse EVENT.

See also `seshat-reader--non-queue-scroll-down-or-next-page'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('wheel-down 1)
		   ('double-wheel-down 2)
		   ('triple-wheel-down 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader--non-queue-scroll-down-or-next-page amount))))

(defun seshat-reader-mwheel-scroll-left (event)
  "Scroll to the left, but also handle mouse EVENT.

See also `seshat-reader-scroll-left'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('S-wheel-up 1)
		   ('S-double-wheel-up 2)
		   ('S-triple-wheel-up 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-scroll-left amount))))

(defun seshat-reader-mwheel-scroll-right (event)
  "Scroll to the right, but also handle mouse EVENT.

See also `seshat-reader-scroll-right'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('S-wheel-down 1)
		   ('S-double-wheel-down 2)
		   ('S-triple-wheel-down 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-scroll-right amount))))

(defun seshat-reader-mwheel-enlarge-size (event)
  "Enlarge the current page, but also handle mouse EVENT.

See also `seshat-reader-enlarge-size'."
  (interactive "e")
  (let* ((event-type (car event))
	 (scaling-factor (pcase event-type
			   ('C-wheel-up seshat-reader-enlarge-factor)
			   ('C-double-wheel-up (+ seshat-reader-enlarge-factor 0.1))
			   ('C-triple-wheel-up (+ seshat-reader-enlarge-factor 0.2))))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-enlarge-size
       (* scaling-factor (seshat-reader-current-doc-scale-value))))))

(defun seshat-reader-mwheel-shrink-size (event)
  "Shrink the current page, but also handle mouse EVENT.

See also `seshat-reader-shrink-size'."
  (interactive "e")
  (let* ((event-type (car event))
	 (scaling-factor (pcase event-type
			   ('C-wheel-down seshat-reader-shrink-factor)
			   ('C-double-wheel-down (- seshat-reader-shrink-factor 0.1))
			   ('C-triple-wheel-down (- seshat-reader-shrink-factor 0.2))))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-shrink-size
       (* scaling-factor (seshat-reader-current-doc-scale-value))))))

(defun seshat-reader-rotate-clockwise ()
  "Rotate the current window's view by 90 degrees, clockwise."
  (interactive)
  (seshat-reader-dyn--rotate-page 90)
  (seshat-reader--center-page))

(defun seshat-reader-rotate-counter-clockwise ()
  "Rotate the current window's view by 90 degrees, counter-clockwise."
  (interactive)
  (seshat-reader-dyn--rotate-page -90)
  (seshat-reader--center-page))

(defun seshat-reader--clear-doc-memory ()
  "Clear document memory if we are in `seshat-reader-mode'.

Intended for use in `kill-buffer-hook'."
  (when (derived-mode-p 'seshat-reader-mode)
    (seshat-reader-dyn--close-doc)))
(add-hook 'kill-buffer-hook 'seshat-reader--clear-doc-memory nil t)

(defun seshat-reader-close-doc ()
  "Close the current document, also prompt the user for confirmation."
  (interactive)
  (when (yes-or-no-p "Are you sure you want to close the current document?")
    (kill-buffer (current-buffer))))

(defun seshat-reader--restore-display-on-quit (page scale)
  "Reload the document with PAGE at SCALE and rebuild window overlays on quit.

Quit is deferred inside so the recovery cannot itself be interrupted."
  (with-local-quit
    (condition-case nil
        (progn
          (seshat-reader--render-buffer (1- page))
          (seshat-reader-doc-scale-page scale)
          (seshat-reader--center-page)
          (seshat-reader--manage-window-overlays))
      (error nil))))

(define-queue-command refresh-doc-buffer (&optional _ignore-auto _noconfirm _preserve-modes)
  "Refresh the buffer document with file on disk.

It reloads the entire document while preserving the previous state.
The arguments are ignored and are simply to satisfy the template for
`revert-buffer-function'.

This function is replaced as `revert-buffer-function' for `seshat-reader-mode' buffers."
  (interactive)
  (when (and buffer-file-name (not seshat-reader--reloading))
    (setq seshat-reader--reloading t)
    (unwind-protect
        (let ((page (or (seshat-reader-current-doc-pagenumber) 1))
              (scale (seshat-reader-current-doc-scale-value)))
          (message "Reloading your document...Press C-g to stop.")
	  (condition-case err
              (progn
                (seshat-reader--render-buffer (1- page))
                (seshat-reader-doc-scale-page scale)
                (seshat-reader--center-page)
                (seshat-reader--manage-window-overlays))
            ((quit error)
             (message "Reloading interrupted; restoring display...")
             (seshat-reader--restore-display-on-quit page scale)
             (signal (car err) (cdr err)))))
      (setq-local seshat-reader--reloading nil))))

(defun seshat-reader--render-buffer (&optional page)
  "Render the document file current buffer is associated with.
Load the PAGE if provided."
  (interactive)
  (if-let* ((file (buffer-file-name (current-buffer))))
      (when (file-exists-p file)
	(let ((p (if (numberp page) (max 0 page) 0)))
	  (seshat-reader-dyn--load-doc file p)
	  ;; seshat-reader-dyn--load-doc resets the window state, which also
	  ;; needs to be reflected in the frontend.
	  (set-window-parameter nil 'scale 1.0)))
    (message "No file associated with buffer.")))

;; We have an overlay per window, since we (naturally) need to be able
;; show different pages on different windows.
;;
;; The window knows (as a window parameter):
;; * Which overlay it belongs to.
;; * Which page number it's currently displaying.
;; * What the current scale is.
;;
;; The overlay knows (as an overlay property):
;; * Which window it belongs to.
;; * user pointer to the underlying EmacsWinState from the native
;; module.
;;
;; Window and overlay need to know each other for efficient lookup.

(defun seshat-reader--manage-window-overlays ()
  "Manage the creation and deletion of window overlays as needed.

It is hooked to `window-configuration-change-hook' to keep detecting."
  (let ((overlays (car (overlay-lists)))
	(windows (get-buffer-window-list (current-buffer) nil t)))
    (mapc #'seshat-reader--window-close-function overlays)
    (mapc #'seshat-reader--window-create-function windows)))

(defun seshat-reader--window-create-function (window)
  "Create window overlay for WINDOW."
  (when-let* ((existing-overlay (window-parameter window 'overlay))

	      ;; Check if overlay exists but is invalid or belongs to
	      ;; a different buffer.
	      ((or (not (overlayp existing-overlay))
                   (not (eq (overlay-buffer existing-overlay) (current-buffer))))))

    ;; We intentionally DO NOT clear 'page and 'scale here.  We must
    ;; preserve the window's independent page and scale parameters so
    ;; they can be restored to the new DocState.
    (set-window-parameter window 'overlay nil))

  (unless (window-parameter window 'overlay)
    ;; Prioritize the window's own page and scale parameters.
    (let* ((page (or (window-parameter window 'page)
                     seshat-reader--recent-pagenumber-fallback
                     1))
           (scale (or (window-parameter window 'scale)
                      seshat-reader--recent-scale-fallback
                      1.0)))
      (seshat-reader-dyn--window-create window)
      (set-window-parameter window 'page page)
      (with-selected-window window
        (seshat-reader-goto-page page)
        (seshat-reader-doc-scale-page scale)
        (seshat-reader--center-page)))))

(defun seshat-reader--window-close-function (overlay)
  "Properly close the window belonging to OVERLAY."
  (let ((window (overlay-get overlay 'window)))
    (unless (window-valid-p window)
      (seshat-reader-dyn--window-close overlay))))

(defun seshat-reader--handle-window-buffer-change (window)
  "Handle overlay state when WINDOW's buffer changes.
Cleans up stale overlays if the window switched to a different buffer,
and ensures a valid overlay exists if the new buffer is a seshat-reader buffer."
  (when (windowp window)
    (let ((overlay (window-parameter window 'overlay)))
      (when (and overlay (overlayp overlay))
        (unless (eq (overlay-buffer overlay) (window-buffer window))
          ;; Overlay belongs to a different buffer. Clean it up.
          (seshat-reader-dyn--window-close overlay)
          (set-window-parameter window 'overlay nil)
          ;; We intentionally preserve 'page and 'scale so they can be
          ;; restored if the user switches back to the original seshat-reader buffer.
          )))
    ;; If the new buffer is a seshat-reader buffer and lacks an overlay, create one.
    (when (with-current-buffer (window-buffer window)
            (derived-mode-p 'seshat-reader-mode))
      (unless (window-parameter window 'overlay)
        (seshat-reader--window-create-function window)))))

;; We explicitly bind default keys because relying on the rebinding
;; mechanism can lead to them not being bound at all if users have
;; overridden the defaults with other commands.
(defvar-keymap seshat-reader-mode-map
  :doc "Keymap for `seshat-reader-mode'."
  "n"       #'seshat-reader-next-page
  "p"       #'seshat-reader-previous-page

  "C-p"     #'seshat-reader-scroll-up-or-prev-page
  "C-n"     #'seshat-reader-scroll-down-or-next-page
  "<remap> <previous-line>" #'seshat-reader-scroll-up-or-prev-page
  "<remap> <next-line>" #'seshat-reader-scroll-down-or-next-page
  "<remap> <next>" #'seshat-reader-scroll-down-or-next-page
  "<remap> <prior>" #'seshat-reader-scroll-up-or-prev-page

  "<wheel-up>" #'seshat-reader-mwheel-scroll-up
  "<wheel-down>" #'seshat-reader-mwheel-scroll-down

  "S-<wheel-up>" #'seshat-reader-mwheel-scroll-left
  "S-<wheel-down>" #'seshat-reader-mwheel-scroll-right

  "C-v"      #'seshat-reader-scroll-down-screen
  "M-v"      #'seshat-reader-scroll-up-screen
  "<remap> <scroll-down-command>" #'seshat-reader-scroll-up-screen
  "<remap> <scroll-up-command>" #'seshat-reader-scroll-down-screen

  "SPC"     #'seshat-reader-scroll-down-screen-or-next-page
  "DEL"     #'seshat-reader-scroll-up-screen-or-prev-page
  "S-SPC"   #'seshat-reader-scroll-up-screen-or-prev-page

  "C-f"     #'seshat-reader-scroll-right
  "C-b"     #'seshat-reader-scroll-left
  "<remap> <forward-char>" #'seshat-reader-scroll-right
  "<remap> <backward-char>" #'seshat-reader-scroll-left

  "C-e"     #'seshat-reader-scroll-right-most
  "C-a"     #'seshat-reader-scroll-left-most
  "<remap> <move-end-of-line>" #'seshat-reader-scroll-right-most
  "<remap> <move-beginning-of-line>" #'seshat-reader-scroll-left-most

  "M-<" #'seshat-reader-first-page
  "M->" #'seshat-reader-last-page
  "<remap> <beginning-of-buffer>" #'seshat-reader-first-page
  "<remap> <end-of-buffer>" #'seshat-reader-last-page

  "g" #'seshat-reader-refresh-doc-buffer

  "M-g g"   #'seshat-reader-goto-page
  "M-g M-g" #'seshat-reader-goto-page
  "<remap> <goto-line>"   #'seshat-reader-goto-page

  "="       #'seshat-reader-enlarge-size
  "+"       #'seshat-reader-enlarge-size
  "C-<wheel-up>" #'seshat-reader-mwheel-enlarge-size

  "-"       #'seshat-reader-shrink-size
  "C-<wheel-down>" #'seshat-reader-mwheel-shrink-size

  "0"       #'seshat-reader-reset-size

  "H"       #'seshat-reader-fit-to-height
  "W"       #'seshat-reader-fit-to-width

  "r"       #'seshat-reader-rotate-clockwise
  "R"       #'seshat-reader-rotate-counter-clockwise

  "o"       #'seshat-reader-outline-show

  "Q"       #'seshat-reader-close-doc


  ;; Disable a few mouse commands to make sure the user is not able to
  ;; accidentally move the point to a weird place, which causes the
  ;; cursor (which we use as a page border) to be drawn after the
  ;; page.

  "<remap> <mouse-set-point>"   #'ignore
  "<remap> <mouse-set-region>"  #'ignore
  "<remap> <mouse-set-mark>"    #'ignore
  "<remap> <mouse-set-secondary>"  #'ignore
  "<remap> <mouse-drag-region>"    #'ignore
  "<remap> <mouse-drag-secondary>" #'ignore)

;;;###autoload
(define-derived-mode seshat-reader-mode special-mode "Seshat Reader"
  "Major mode for viewing documents in The Seshat Reader.

Keybindings:
\\{seshat-reader-mode-map}"
  :group 'seshat-reader
  :interactive nil

  (unless (and buffer-file-name
	       (file-exists-p buffer-file-name)
	       (file-regular-p buffer-file-name)
	       (file-readable-p buffer-file-name))
    (message "Seshat Reader did not open the document: %s is not a valid file"
             (or buffer-file-name "<no file>"))
    (kill-buffer (current-buffer)))

  (setq-local buffer-read-only t
	      global-linum-mode nil
	      cursor-type 'hollow
	      display-line-numbers-mode nil
	      ;; messes up centering(line-prefix) otherwise, the
	      ;; default value is 8, so we keep it at that.
	      left-fringe-width 8)
  (set-buffer-modified-p nil)
  (blink-cursor-mode 0)
  (auto-revert-mode 1)
  (setq-local revert-buffer-function #'seshat-reader--non-queue-refresh-doc-buffer)

  ;; Disable `pixel-scroll-precision-mode' locally because it doesn't
  ;; work nicely with `seshat-reader-mode'.
  (when (bound-and-true-p pixel-scroll-precision-mode)
    (setq-local pixel-scroll-precision-mode nil))

  (declare-function seshat-reader-bookmark-make-record "seshat-reader-bookmark")
  (setq-local bookmark-make-record-function
	      #'seshat-reader-bookmark-make-record)

  (unless (bound-and-true-p
	   seshat-reader-current-doc-render-status)
    (seshat-reader--render-buffer))

  (setq-local imenu-create-index-function #'seshat-reader--outline-imenu-create-index
	      imenu-default-goto-function #'seshat-reader--outline-imenu-goto)

  (use-local-map seshat-reader-mode-map)
  (setq major-mode 'seshat-reader-mode)
  (setq mode-name "Seshat Reader")
  (run-hooks 'seshat-reader-mode-hook)

  (funcall seshat-reader-default-fit)
  (add-hook 'window-size-change-functions #'seshat-reader--center-page nil t)
  (add-hook 'window-configuration-change-hook #'seshat-reader--manage-window-overlays nil t)
  (add-hook 'window-buffer-change-functions #'seshat-reader--handle-window-buffer-change nil t))

(defun seshat-reader-mode-line ()
  "Set custom mode-line interface when reading documents."
  (setq-local mode-line-position
	      '(" P" (:eval (number-to-string (seshat-reader-current-doc-pagenumber)))
                "/" (:eval (number-to-string seshat-reader-current-doc-pagecount)))))

(add-hook 'seshat-reader-mode-hook #'seshat-reader-mode-line)
(add-hook 'seshat-reader-mode-hook #'imenu-add-menubar-index)

(defun seshat-reader--redisplay-all-windows ()
  "Redisplay the current document in all windows showing this buffer."
  (let ((current-win (selected-window)))
    (dolist (win (get-buffer-window-list (current-buffer) nil t))
      (with-selected-window win
        (seshat-reader-dyn--redisplay-doc)))
    (select-window current-win)))

(define-minor-mode seshat-reader-dark-mode
  "Toggle dark-mode for current seshat-reader document."
  :lighter " Dark"
  (when (eq major-mode 'seshat-reader-mode)
    (seshat-reader-dyn--doc-invert (if seshat-reader-dark-mode 1 0))
    (seshat-reader--redisplay-all-windows)))

(define-minor-mode seshat-reader-presentation-mode
  "Toggle presentation view for current seshat-reader document."
  :lighter ""
  (when (eq major-mode 'seshat-reader-mode)
    (cond (seshat-reader-presentation-mode
	   (setq-local mode-line-format nil)
	   (seshat-reader-fit-to-height))
	  ((kill-local-variable 'mode-line-format)))))

;;;###autoload
(dolist (pattern seshat-reader-supported-formats)
  (add-to-list 'auto-mode-alist (cons (concat "\\." pattern "\\'") 'seshat-reader-mode)))

;;; PoC text-extraction helpers

(defun seshat-reader-poc-dump-page-text ()
  "Print the extracted text of the current page.

This proof-of-concept helper calls the module function
`seshat-reader-dyn--page-text' without an explicit page argument, so the
current page is used."
  (interactive)
  (message "%s" (seshat-reader-dyn--page-text)))

(defun seshat-reader-poc-text-in-rect (page x0 y0 x1 y1)
  "Print the text inside a rectangle on PAGE.

PAGE is the 0-based page index expected by the module function
`seshat-reader-dyn--text-in-rect' (MuPDF indexes pages from 0).  When called
interactively it defaults to the current page: its 1-based number is
reported by `seshat-reader-current-doc-pagenumber', and is converted to the
0-based index with `1-' before being passed to the module, so the page
that is read matches the page on screen.

X0, Y0, X1 and Y1 are the rectangle corners in unrotated page
coordinates.  The text is read via the module function
`seshat-reader-dyn--text-in-rect'.  The C module accepts only floats for the
rectangle corners, so every coordinate is coerced with `float' before
being passed to the module function."
  (interactive (list (1- (or (seshat-reader-current-doc-pagenumber) 1))
		     (float (read-number "x0: "))
		     (float (read-number "y0: "))
		     (float (read-number "x1: "))
		     (float (read-number "y1: "))))
  (message "%s" (seshat-reader-dyn--text-in-rect page (float x0) (float y0) (float x1) (float y1))))

(provide 'seshat-reader)
;;; seshat-reader.el ends here.

;; Local Variables:
;; read-symbol-shorthands: (("define-queue-command" . "seshat-reader--define-queue-command"))
;; End:
