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

;; 该变量由 C 模块（`permanent_buffer_local_var'）注册为 buffer-local；编译期不可见，
;; 故在此声明以消除 byte-compiler 的 free variable 警告。C 侧会覆盖 buffer-local 值。
(defvar seshat-reader--recent-pagenumber-fallback nil
  "Registered by the native module; declared here to silence the byte-compiler.")

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

(defcustom seshat-reader-default-fit 'contain
  "The fit mode a reader window starts with.

One of `contain' (the whole page is visible: the smaller of the width
fit and the height fit wins), `width' (fill the window width, scroll
vertically) or `height' (fill the window height, scroll horizontally).

This is only the starting point.  `W' and `H' override it for the
window they are used in, and that choice is not remembered across
sessions: a new window starts from this value again.

Legacy function values are still accepted: `seshat-reader-fit-to-width'
means `width', while `seshat-reader-fit-to-height' (the former default)
means `contain', which keeps the behaviour of unmodified
configurations."
  :group 'seshat-reader
  :type '(choice (const :tag "Whole page (contain)" contain)
                 (const :tag "Fill width" width)
                 (const :tag "Fill height" height)))

(defcustom seshat-reader-page-join-lines 0
  "Height of the cross-page join strip, measured in page text lines.

The strip above the current page shows the bottom of the previous page.
Its height is this many times the frame character height; fractional
values are allowed.  A value of 0 disables the strip, in which case page
turning behaves exactly as it did before the feature existed.

The default is 0 because the strip line is known to conflict with the
geometry of the page overlay: the strip is inserted before `point-min'
of the buffer, which the vertical scroll limits and landing points of
the page assume to be the top of the page image, so with
`seshat-reader-fit-to-height' an enabled strip can push the top of the
page out of the window and crop it.  See `openspec/tech-debt.md'.  The
feature is kept, but opt-in, until that conflict is fixed."
  :group 'seshat-reader
  :type '(number :tag "Lines from the previous page"))

(defvar-local seshat-reader--recent-scale-fallback 1.0
  "Previous scaling factor applied to the document.")

(defvar-local seshat-reader--reloading nil
  "Boolean flag to represent reloading status of a document.")

(defvar-local seshat-reader--resize-refit-timer nil
  "Pending debounced refit timer of the current buffer.

The timer is buffer-local on purpose: every window showing the buffer is
refitted by one timer, so two windows cannot cancel each other's refit.")

(defvar-local seshat-reader--refitting nil
  "Non-nil while a pending refit is being applied for this buffer.

A refit re-renders the page synchronously, and the re-render changes the
`line-prefix' and the vertical scroll of the window, which can be reported
back as another size change.  Size-change events arriving while this flag
is non-nil are dropped instead of being queued, so a single refit cannot
trigger the next one.")

(defvar-local seshat-reader--last-size-change-time nil
  "Time of the last window size change handled for this buffer.")

(defvar-local seshat-reader--last-size-change-delta nil
  "Seconds between the last two window size changes of this buffer.

Used to tell a one-off change (opening the outline panel) from a burst of
changes (dragging a window divider): only the former adapts the page
geometry synchronously, the latter leaves the geometry alone and lets the
debounced refit do it once the drag stops.")

(defvar seshat-reader--drag-threshold 0.12
  "Maximum number of seconds between two size changes that counts as a drag.

Internal switch, not a user option.  Values above this are treated as
unrelated, one-off changes and get a synchronous geometry adaptation.")

(defvar seshat-reader--resize-refit-delay 0.15
  "Idle delay, in seconds, before a pending refit is executed.")

(defvar seshat-reader--resize-refit-enabled t
  "Whether window size changes trigger a refit.

Setting this to nil restores the previous behaviour, where a size change
only recentred the page, without touching the rendering resolution or the
vertical scroll.  It is an internal switch, not a user option.")

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
  (seshat-reader--remember-current-page-spec)
  (when (seshat-reader-dyn--next-page)
    (seshat-reader--update-join-strip)
    ;; Land at the strip top, so that the last line of the previous page
    ;; stays visible right above the new page.
    (seshat-reader--set-window-vscroll nil 0)
    ;; Must return `t' when the command succeeds.
    (force-mode-line-update) t))

(define-queue-command previous-page ()
  "Go to the previous page of the document."
  (interactive)
  (seshat-reader--remember-current-page-spec)
  (when (seshat-reader-dyn--prev-page)
    (seshat-reader--update-join-strip)
    ;; Landing at the page bottom keeps the pages continuous when
    ;; scrolling upwards.
    (seshat-reader--set-page-bottom)
    ;; Must return `t' when the command succeeds.
    (force-mode-line-update) t))

(defun seshat-reader-first-page ()
  "Go to the first page of the document."
  (interactive)
  (seshat-reader--remember-current-page-spec)
  (seshat-reader-dyn--first-page)
  (seshat-reader--update-join-strip)
  (seshat-reader--center-page)
  (seshat-reader--set-window-vscroll nil 0)
  (force-mode-line-update))

(defun seshat-reader-last-page ()
  "Go to the last page of the document."
  (interactive)
  (seshat-reader--remember-current-page-spec)
  (seshat-reader-dyn--last-page)
  (seshat-reader--update-join-strip)
  (seshat-reader--center-page)
  (seshat-reader--set-page-bottom)
  (force-mode-line-update))

(defun seshat-reader-goto-page (n)
  "Go to page number N in the current document."
  (interactive "nGoto page: ")
  (seshat-reader--remember-current-page-spec)
  (seshat-reader-dyn--goto-page (- n 1)) ; MuPDF does 0-indexing
  (seshat-reader--update-join-strip)
  (seshat-reader--center-page)
  (seshat-reader--set-window-vscroll nil 0))

(defun seshat-reader--get-current-doc-image-size (&optional window)
  "Get the dimensions of the page in WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (let* ((cdr-image (cdr (overlay-get (seshat-reader-current-doc-overlay window) 'display)))
	 (width (plist-get cdr-image :width))
	 (height (plist-get cdr-image :height)))
    (cons width height)))

(defun seshat-reader-doc-scale-page (factor &optional source)
  "Scales the page by a given FACTOR.

It also updates `seshat-reader--recent-scale-fallback' and `scale' property of
selected window to reflect the new, possibly clamped scale.

When SOURCE is non-nil, it is also recorded as the scale source of the selected
window.  The expected values are `fit' (the scale was derived from the window
size) and `manual' (the user chose the scale).  A nil SOURCE leaves the
recorded source unchanged, so restoring a window's previous scale does not
pretend to be a new scaling command.

It also records the clamped scale in the window parameter `render-scale',
which is what `seshat-reader--refit-window' compares against to decide
whether the bitmap needs re-rendering, and drops the `native-size' cache
because the freshly rendered spec is the authoritative size.  The
`render-scale' of a window is cleared by
`seshat-reader--render-buffer'; rotating the page keeps it, since rotation
does not change the rendering resolution."
  (when-let* ((factor-clamped (seshat-reader-dyn--scale-page factor)))
    (setq seshat-reader--recent-scale-fallback factor-clamped)
    (set-window-parameter nil 'scale factor-clamped)
    (set-window-parameter nil 'render-scale factor-clamped)
    (set-window-parameter nil 'native-size nil)
    (when source
      (set-window-parameter nil 'scale-source source))))

(defun seshat-reader--window-scale-source (&optional window)
  "Return WINDOW's scale source, `fit' or `manual' (default `fit').

WINDOW defaults to the selected window.  A window that never recorded a
source, for example one restored from a bookmark, counts as `fit'."
  (or (window-parameter (or window (selected-window)) 'scale-source) 'fit))

(defun seshat-reader-enlarge-size (&optional scaling-factor)
  "Enlarge the size of the current page by the `seshat-reader-enlarge-factor'.

Optionally scale it by the SCALING-FACTOR.  Scales on selected window."
  (interactive (list (float
		      (* (seshat-reader-current-doc-scale-value) seshat-reader-enlarge-factor))))
  (seshat-reader-doc-scale-page scaling-factor 'manual)
  (seshat-reader--center-page)
  (seshat-reader--set-page-top-when-joined))

(defun seshat-reader-shrink-size (&optional scaling-factor)
  "Shrink the size of the current page by the `seshat-reader-shrink-factor'.

Optionally scale it by the SCALING-FACTOR.  Scales on selected window."
  (interactive (list (float
		      (* (seshat-reader-current-doc-scale-value) seshat-reader-shrink-factor))))
  (seshat-reader-doc-scale-page scaling-factor 'manual)
  (seshat-reader--center-page)
  (seshat-reader--set-page-top-when-joined))

(defun seshat-reader-reset-size ()
  "Reset the size of the current page to 1.0."
  (interactive)
  (seshat-reader-doc-scale-page 1.0 'manual)
  (seshat-reader--center-page)
  (seshat-reader--set-page-top-when-joined))

(defun seshat-reader-fit-to-height ()
  "Scale the current page in the selected window to fit its height."
  (interactive)
  (let* ((image-height (cdr (seshat-reader--get-current-doc-image-size)))
	 (pixel-window-height (window-body-height nil t))
	 (unscaled-height (/ image-height (seshat-reader-current-doc-scale-value)))
	 (scaling-factor (/ pixel-window-height unscaled-height)))
    (seshat-reader-doc-scale-page scaling-factor 'fit)
    (seshat-reader--center-page)
    (seshat-reader--set-page-top)
    (set-window-parameter nil 'fit-mode 'height)))

(defun seshat-reader-fit-to-width ()
  "Scale the current page in the selected window to fit its width."
  (interactive)
  (let* ((image-width (car (seshat-reader--get-current-doc-image-size)))
	 (pixel-window-width (window-body-width nil t))
	 (unscaled-width (/ image-width (seshat-reader-current-doc-scale-value)))
	 (scaling-factor (/ pixel-window-width unscaled-width)))
    (seshat-reader-doc-scale-page scaling-factor 'fit)
    (seshat-reader--center-page)
    (seshat-reader--set-page-top-when-joined)
    (set-window-parameter nil 'fit-mode 'width)))

(defun seshat-reader--contain-scale (&optional window)
  "Return the scale at which the current page fits WINDOW completely.

WINDOW defaults to the selected one.  The result is the smaller of the two
scales, so whichever dimension binds is the one that ends up filled; the
page is never enlarged beyond it.  This function provides the `contain'
geometry itself and does not read `seshat-reader-default-fit': that option
only decides which fit mode a window starts with (see
`seshat-reader--initial-fit-mode'), and its `contain' value ends up calling
this function through `seshat-reader--fit-scale'."
  (let* ((window (or window (selected-window)))
         (size (seshat-reader--get-current-doc-image-size window))
         (image-width (car-safe size))
         (image-height (cdr-safe size)))
    (if (and (numberp image-width) (numberp image-height)
             (> image-width 0) (> image-height 0))
        (let* ((scale (with-selected-window window
                        (or (seshat-reader-current-doc-scale-value) 1.0)))
               (scale (if (> scale 0) scale 1.0))
               (width-factor (/ (window-body-width window t)
                                (/ image-width scale)))
               (height-factor (/ (window-body-height window t)
                                 (/ image-height scale))))
          (min width-factor height-factor))
      1.0)))

(defun seshat-reader--normalize-default-fit (value)
  "Return VALUE as a fit mode symbol: `contain', `width' or `height'.

VALUE is normally the symbol stored in `seshat-reader-default-fit', but
the two function symbols used before 2026-10-23 are still understood:
`seshat-reader-fit-to-width' means `width' while
`seshat-reader-fit-to-height' (the former default) means `contain', so
that a configuration that never touched the option keeps behaving as
before.  Anything else degrades to `contain'."
  (pcase value
    ((or 'contain 'width 'height) value)
    ('seshat-reader-fit-to-width 'width)
    ('seshat-reader-fit-to-height 'contain)
    (_ 'contain)))

(defun seshat-reader--initial-fit-mode (&optional window)
  "Return the fit mode WINDOW should start with.

WINDOW defaults to the selected one.  A window that already recorded a
mode keeps it; otherwise WINDOW starts from `seshat-reader-default-fit',
normalised through `seshat-reader--normalize-default-fit'."
  (or (window-parameter (or window (selected-window)) 'fit-mode)
      (seshat-reader--normalize-default-fit seshat-reader-default-fit)))

(defun seshat-reader--first-fit ()
  "Fit the page to the selected window the first time it is displayed.

The target scale follows the window's initial fit mode
\(`seshat-reader--initial-fit-mode'), which is recorded as the window's
`fit-mode' first so that later resizes keep using it.  Uses a
display-level rescale instead of a re-render, so the very first frame
already shows the page at its final size; the bitmap is rendered at the
new resolution by the debounced refit afterwards.  Falls back to a
synchronous re-render when the page spec is not available yet."
  (let ((mode (seshat-reader--initial-fit-mode)))
    (set-window-parameter nil 'fit-mode mode)
    (let ((target (seshat-reader--fit-scale)))
      (unless (seshat-reader--apply-display-scale (selected-window) target)
        (seshat-reader-doc-scale-page target 'fit))))
  (seshat-reader--center-page)
  (seshat-reader--schedule-refit))

(defun seshat-reader--window-fit-mode (&optional window)
  "Return WINDOW's fit mode: `contain', `width' or `height'.

WINDOW defaults to the selected one.  A window that never recorded a mode
\(opened before the option existed, restored from a bookmark, or simply
never used `H' / `W') counts as `contain', which keeps the pre-existing
behaviour of fitting the whole page into the window."
  (or (window-parameter (or window (selected-window)) 'fit-mode) 'contain))

(defun seshat-reader--fit-scale (&optional window)
  "Return the scale WINDOW's page should have, according to its fit mode.

WINDOW defaults to the selected one.  With the `contain' mode this is
exactly `seshat-reader--contain-scale'; `width' and `height' use only one
dimension, so an explicit `W' (\\[seshat-reader-fit-to-width]) keeps filling
the width even when the page then overflows vertically, and `H'
\(\\[seshat-reader-fit-to-height]) does the converse."
  (let* ((window (or window (selected-window)))
         (mode (seshat-reader--window-fit-mode window)))
    (if (eq mode 'contain)
        (seshat-reader--contain-scale window)
      (let ((native (seshat-reader--native-page-size window)))
        (if (and native (> (car native) 0) (> (cdr native) 0))
            (if (eq mode 'width)
                (/ (window-body-width window t) (float (car native)))
              (/ (window-body-height window t) (float (cdr native))))
          1.0)))))

(defun seshat-reader--page-image-spec (window)
  "Return WINDOW's page image spec, or nil if it is not an image yet."
  (let ((overlay (seshat-reader-current-doc-overlay window)))
    (when (overlayp overlay)
      (let ((display (overlay-get overlay 'display)))
        (when (and (consp display) (eq (car display) 'image))
          display)))))

(defun seshat-reader--native-page-size (window)
  "Return the unscaled pixel size of WINDOW's page as (W . H), or nil.

The value is cached in the window parameter `native-size' as
\(PAGE . (W . H)), together with the page number it was measured on: two
pages of the same document may have different sizes, so a cached size is
reused only while the window still shows PAGE.  The cache is also dropped
when the page is re-rendered at a new resolution
\(`seshat-reader-doc-scale-page'), the document is reloaded
\(`seshat-reader--render-buffer') or the page is rotated
\(`seshat-reader-rotate-clockwise' / `-counter-clockwise')."
  (let* ((page (seshat-reader-current-doc-pagenumber window))
         (cached (window-parameter window 'native-size)))
    (if (and (consp cached) (equal (car cached) page) (consp (cdr cached)))
        (cdr cached)
      (let* ((spec (seshat-reader--page-image-spec window))
             (scale (seshat-reader-current-doc-scale-value window))
             (w (and spec (image-property spec :width)))
             (h (and spec (image-property spec :height))))
        (when (and (integerp w) (integerp h) (> w 0) (> h 0)
                   (numberp scale) (> scale 0))
          (let ((native (cons (/ (float w) scale) (/ (float h) scale))))
            (set-window-parameter window 'native-size (cons page native))
            native))))))

(defun seshat-reader--apply-display-scale (window scale)
  "Resize WINDOW's page to SCALE by rewriting the image spec, without rendering.

Return non-nil when the spec changed.  The window parameter `scale' and the
buffer-local `seshat-reader--recent-scale-fallback' are updated together
with the spec, so the invariant \"spec size / `scale' = native size\" keeps
holding for `seshat-reader--contain-scale', `seshat-reader--fit-scale' and
the vertical scroll upper bound.

No `image-flush' is issued here: rewriting the spec in place is enough for
the new geometry to take effect, and flushing on every size change would
make the redisplay re-decode the whole page bitmap each time, which is
what makes dragging a window divider stall.  Stale cache entries are
dropped by the C side when it replaces the spec on the next re-render."
  (when (and (windowp window) (numberp scale) (> scale 0))
    (let* ((spec (seshat-reader--page-image-spec window))
           (native (and spec (seshat-reader--native-page-size window)))
           (w (and spec (image-property spec :width)))
           (h (and spec (image-property spec :height)))
           (new-w (and native (max 1 (round (* (car native) scale)))))
           (new-h (and native (max 1 (round (* (cdr native) scale))))))
      (when (and (integerp new-w) (integerp new-h))
        (unless (and (equal w new-w) (equal h new-h))
          ;; 不做 image-flush：拖动分割线时每帧 flush 会强制重解码整页位图（实测卡 1–2s）；
          ;; 旧缓存由 C 侧下次重渲染替换 spec 时清掉。
          (setf (image-property spec :width) new-w)
          (setf (image-property spec :height) new-h)
          (set-window-parameter window 'scale scale)
          (setq seshat-reader--recent-scale-fallback scale)
          t)))))

(defun seshat-reader--get-pixel-per-col (&optional window)
  "Get the no of pixels per column for WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (/ (window-body-width window t) (window-body-width window)))

;;; Cross-page join

;; The bottom strip of the previous page is drawn as a single buffer line
;; inserted before the current page, using a `slice' display specification
;; over the image spec of the previous page.  The image spec of a page is
;; only available while that page is displayed, hence the spec cache below.

(defconst seshat-reader--page-image-specs-limit 5
  "Maximum number of page image specs kept in the spec cache.")

(defvar-local seshat-reader--page-image-specs nil
  "Cache of recently displayed page image specs.

Each element is a cons cell of (PAGE . SPEC), where PAGE is the 1-based
page number and SPEC is the image spec of that page.  The newest element
comes first and at most `seshat-reader--page-image-specs-limit' elements
are kept.")

(defvar-local seshat-reader--join-strip-height 0
  "Height in pixels of the cross-page join strip, or 0 if there is none.")

(defvar-local seshat-reader--join-strip-end nil
  "Marker at the end of the cross-page join strip line, or nil.

The marker is nil when the buffer holds no join strip.")

(defvar-local seshat-reader--center-overlay nil
  "Buffer-wide overlay carrying the centering `line-prefix'.

The overlay spans the whole accessible buffer so that the prefix also
applies to the cross-page join strip line.  It is kept up to date by
`seshat-reader--ensure-center-overlay'.")

(defun seshat-reader--page-join-pixels ()
  "Return the height in pixels of the cross-page join strip.

The height is `seshat-reader-page-join-lines' times the frame character
height, rounded to whole pixels.  The value 0 means the feature is
disabled."
  (let ((lines seshat-reader-page-join-lines))
    (if (numberp lines)
	(max 0 (round (* lines (frame-char-height))))
      0)))

(defun seshat-reader--remember-current-page-spec (&optional window)
  "Remember the image spec of the page displayed in WINDOW.

WINDOW defaults to the selected window.  The spec is needed later to
draw the strip of the page that is about to be left, so this function is
called right before the page of WINDOW changes.  Entries for the same
page are de-duplicated and at most
`seshat-reader--page-image-specs-limit' entries are kept, newest first."
  (let* ((window (or window (selected-window)))
	 (overlay (seshat-reader-current-doc-overlay window))
	 (page (seshat-reader-current-doc-pagenumber window))
	 (spec (and (overlayp overlay)
		    (overlay-get overlay 'display))))
    (when (and (integerp page) (consp spec))
      (let ((cell (cons (cons page spec)
			(assq-delete-all
			 page seshat-reader--page-image-specs)))
	    (tail nil))
	(setq tail cell)
	(dotimes (_ (1- seshat-reader--page-image-specs-limit))
	  (when (cdr tail)
	    (setq tail (cdr tail))))
	(when (cdr tail)
	  (setcdr tail nil))
	(setq seshat-reader--page-image-specs cell)))))

(defun seshat-reader--ensure-center-overlay ()
  "Return the buffer-wide centering overlay, creating it if needed.

The overlay is repositioned to cover the whole buffer on every call, so
that it stays valid after the join strip is inserted or deleted."
  (unless (and (overlayp seshat-reader--center-overlay)
	       (eq (overlay-buffer seshat-reader--center-overlay)
		   (current-buffer)))
    (setq seshat-reader--center-overlay
	  (make-overlay (point-min) (point-max))))
  (move-overlay seshat-reader--center-overlay
		(point-min) (point-max) (current-buffer))
  seshat-reader--center-overlay)

(defun seshat-reader--remove-join-strip ()
  "Delete the cross-page join strip from the current buffer.

The strip height is reset to 0, so the page height semantics fall back
to the plain page image height."
  (when (and (markerp seshat-reader--join-strip-end)
	     (eq (marker-buffer seshat-reader--join-strip-end)
		 (current-buffer)))
    (let ((inhibit-read-only t))
      (delete-region (point-min) seshat-reader--join-strip-end)))
  (when (markerp seshat-reader--join-strip-end)
    (set-marker seshat-reader--join-strip-end nil))
  (setq seshat-reader--join-strip-end nil
	seshat-reader--join-strip-height 0))

(defun seshat-reader--insert-join-strip (spec height)
  "Insert a strip of HEIGHT pixels cut from the bottom of image SPEC.

SPEC is the image spec of the previous page.  The strip is inserted as a
single line at the beginning of the current buffer and displays the
bottom HEIGHT pixels of SPEC through a `slice' display specification.
The newline ending the strip line carries a non-nil `line-height'
property so that no extra leading is added below the strip."
  (let* ((image-height (plist-get (cdr spec) :height))
	 (image-width (plist-get (cdr spec) :width)))
    (when (and (integerp image-height) (integerp image-width)
	       (> image-height 0) (> image-width 0) (> height 0))
      (let* ((strip-height (min height image-height))
	     (start (point-min)))
	(let ((inhibit-read-only t))
	  (goto-char start)
	  (insert " ")
	  (put-text-property
	   start (point) 'display
	   (list (list 'slice 0 (- image-height strip-height)
		       image-width strip-height)
		 spec))
	  (insert (propertize "\n" 'line-height t)))
	(setq seshat-reader--join-strip-end (copy-marker (point))
	      seshat-reader--join-strip-height strip-height)))))

(defun seshat-reader--update-join-strip ()
  "Redraw the cross-page join strip for the current buffer.

The strip shows the bottom of the previous page above the current page,
and is only drawn when the spec of the previous page is cached and
`seshat-reader--page-join-pixels' is non-zero.  The function is
idempotent: an existing strip is always removed before a new one is
inserted."
  (seshat-reader--remove-join-strip)
  (let* ((page (seshat-reader-current-doc-pagenumber))
	 (height (seshat-reader--page-join-pixels))
	 (spec (and (integerp page) (> page 1)
		    (alist-get (1- page) seshat-reader--page-image-specs))))
    (when (and spec (> height 0))
      (seshat-reader--insert-join-strip spec height)))
  ;; strip 纯属显示产物：翻页时增删它不应让 buffer 变成「已修改」。
  (set-buffer-modified-p nil))

;; We need to do this because scrolling is possible in one direction
;; (downwards) indefinitely.

(defun seshat-reader--set-window-vscroll (window vscroll &optional pixels-p)
  "Set amount by which WINDOW should be scrolled vertically to VSCROLL.

If setting VSCROLL makes the document page's top disappear, it sets the
maximum vertical scroll possible without doing that.

If PIXELS-P is non-nil, VSCROLL is considered to be in pixels and is
used as-is.
Also see `set-window-vscroll'."
  (let* ((image-height
	  (or (cdr (seshat-reader--get-current-doc-image-size window)) 0))
	 (pixel-window-height (window-body-height window t))
	 (window-height (window-body-height window))
	 (pixel-per-col (/ pixel-window-height window-height))
	 (pixel-vscroll (if pixels-p vscroll (* pixel-per-col vscroll)))
	 (max-pixel-vscroll
	  (max 0 (- (+ image-height (or seshat-reader--join-strip-height 0))
		    pixel-window-height)))
	 (corrected-pixel-vscroll (min pixel-vscroll max-pixel-vscroll))
	 (corrected-vscroll (/ corrected-pixel-vscroll pixel-per-col)))
    (set-window-vscroll window
			(if pixels-p corrected-pixel-vscroll corrected-vscroll)
			pixels-p)))

;;; Page landing points

;; Cross-page joining shifts the vertical scroll origin: the join strip of
;; the previous page occupies the first `seshat-reader--join-strip-height'
;; pixels of the window.  The helpers below name the three landing points
;; that every page turning and scaling command has to use.

(defun seshat-reader--window-vscroll-pixels (&optional window)
  "Return the vertical scroll of WINDOW in pixels.

WINDOW defaults to the selected window.  Emacs reports the vertical
scroll in lines unless the pixel argument is used, so every caller that
works with the join strip goes through this function to keep a single
unit across the code base."
  (window-vscroll (or window (selected-window)) t))

(defun seshat-reader--page-max-vscroll-pixels (&optional window)
  "Return the maximum vertical scroll of WINDOW in pixels.

The value is the page image height plus the join strip height minus the
pixel body height of WINDOW, floored at 0.  WINDOW defaults to the
selected window."
  (let* ((window (or window (selected-window)))
         (image-height
          (or (cdr (seshat-reader--get-current-doc-image-size window)) 0))
         (window-height (window-body-height window t)))
    (max 0 (- (+ image-height (or seshat-reader--join-strip-height 0))
              window-height))))

(defun seshat-reader--at-page-top-p (&optional window)
  "Return non-nil if the top of the page in WINDOW is visible.

The join strip occupies the first `seshat-reader--join-strip-height'
pixels of the window, so the page top counts as visible as soon as the
vertical scroll does not exceed the strip height.  With the join feature
disabled the strip height is 0 and the predicate degenerates to a plain
zero scroll check.  WINDOW defaults to the selected window."
  (<= (seshat-reader--window-vscroll-pixels window)
      (or seshat-reader--join-strip-height 0)))

(defun seshat-reader--set-page-top (&optional window)
  "Scroll WINDOW so that the page top sits at the window top.

The landing point is the join strip height: scrolling by exactly that
amount hides the strip of the previous page and keeps the whole page
visible.  WINDOW defaults to the selected window."
  (seshat-reader--set-window-vscroll (or window (selected-window))
                                     (or seshat-reader--join-strip-height 0)
                                     t))

(defun seshat-reader--set-page-top-when-joined (&optional window)
  "Scroll WINDOW to the page top only when a join strip is displayed.

Commands that never touched the vertical scroll before cross-page
joining existed must stay inert when `seshat-reader-page-join-lines' is
0, so that disabling the feature restores the previous behaviour
exactly.  WINDOW defaults to the selected window."
  (when (> (or seshat-reader--join-strip-height 0) 0)
    (seshat-reader--set-page-top window)))

(defun seshat-reader--set-page-bottom (&optional window)
  "Scroll WINDOW so that the bottom of the page is visible.

The landing point is `seshat-reader--page-max-vscroll-pixels', which
shows the page bottom together with the strip of the next page.  WINDOW
defaults to the selected window."
  (let ((window (or window (selected-window))))
    (seshat-reader--set-window-vscroll
     window (seshat-reader--page-max-vscroll-pixels window) t)))

(defun seshat-reader--clamp-window-vscroll (&optional window)
  "Clamp the pixel vertical scroll of WINDOW to [0, maximum].

The maximum is `seshat-reader--page-max-vscroll-pixels', which already
accounts for the join strip height; the lower bound is added here because
`seshat-reader--set-window-vscroll' only clamps above.  Nothing is sent
when the current scroll is already inside the range, so that no useless
redisplay is triggered.  WINDOW defaults to the selected window."
  (let* ((window (or window (selected-window)))
         (max-px (max 0 (seshat-reader--page-max-vscroll-pixels window)))
         (cur (seshat-reader--window-vscroll-pixels window))
         (clamped (max 0 (min cur max-px))))
    (unless (= cur clamped)
      (seshat-reader--set-window-vscroll window clamped t))
    clamped))

;; Most of the scrolling functions here exist because of our handling
;; of centering in `seshat-reader--center-page'.

(defun seshat-reader--get-prefix-width (&optional window)
  "Get the line prefix width set by `seshat-reader--center-page'.

The width is read from the buffer-wide centering overlay.  Buffers that
were centered before the join strip existed have no such overlay, in
which case the window's document overlay is consulted instead.  The
function always returns a number: when neither overlay carries a
`line-prefix', the width is 0, so callers can use the value in
arithmetic without guarding against nil.

WINDOW must be a valid window and defaults to the selected one."
  (or (when (overlayp seshat-reader--center-overlay)
	(car (plist-get
	      (cdr (overlay-get seshat-reader--center-overlay 'line-prefix))
	      :width)))
      (when-let* ((overlay (seshat-reader-current-doc-overlay window))
		  ((overlayp overlay)))
	(car (plist-get
	      (cdr (overlay-get overlay 'line-prefix))
	      :width)))
      0))

(defun seshat-reader--right-most-window-hscroll (&optional window)
  "Get the maximum horizontal scroll value for WINDOW.

This position is at the rightmost point.  Returns 0 while the page has not
been rendered yet: the image size is unknown then, and callers such as
`seshat-reader--set-window-hscroll' run during mode initialisation and must
not signal.

WINDOW must be a valid window and defaults to the selected one."
  (let* ((image-width (car (seshat-reader--get-current-doc-image-size window)))
	 (line-prefix-width (seshat-reader--get-prefix-width window))
	 (pixel-window-width (window-body-width window t))
	 (pixel-per-col (seshat-reader--get-pixel-per-col window)))
    (if (and (numberp image-width) (numberp pixel-per-col) (> pixel-per-col 0))
	(round (/ (max line-prefix-width
		       (- image-width pixel-window-width))
		  pixel-per-col))
      0)))

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

(defun seshat-reader--centered-p (window)
  "Return non-nil if WINDOW's page is already positioned by the live prefix.

Two different prefixes are used: pages that fit are centred by a
`before-string' whose `:align-to' form references the displayed image spec,
while pages wider than the window are left-aligned through the buffer-wide
centring overlay's `line-prefix'.  Either one counts as centred only when
it matches the current geometry, so that a re-render (new spec identity) or
a resize (different leftover width) is detected and repaired once."
  (let* ((overlay (window-parameter window 'overlay))
         (spec (seshat-reader--page-image-spec window))
         (image-width (and spec (image-property spec :width)))
         (window-width (window-body-width window t)))
    (cond
     ;; 页面比窗口宽：center overlay 的 line-prefix 宽度必须等于剩余宽度
     ((and (numberp image-width) (> image-width 0)
           (numberp window-width) (< window-width image-width))
      (let* ((center seshat-reader--center-overlay)
             (prefix (and (overlayp center) (overlay-get center 'line-prefix)))
             (width (and (consp prefix) (car (plist-get (cdr prefix) :width)))))
        (and (numberp width)
             (= width (max 0 (- window-width image-width)))
             t)))
     ;; 能放下：before-string 必须引用当前 spec（身份比较）
     ((and (overlayp overlay) spec)
      (let* ((before (overlay-get overlay 'before-string))
             (display (and (stringp before) (> (length before) 0)
                           (get-text-property 0 'display before)))
             (align (and (consp display) (plist-get (cdr display) :align-to)))
             (form (and (consp align) (eq (car align) '+)
                        (nth 2 align))))
        (and (consp form) (eq (cdr form) spec) t)))
     (t nil))))

;; We need this hack involving line-prefix because Emacs' scrolling is
;; idiosyncratic, and doesn't allow arbitrary scrolling in every
;; direction.
;; We need this hack involving line-prefix because Emacs' scrolling is
;; idiosyncratic, and doesn't allow arbitrary scrolling in every
;; direction.  It is only used while the page is wider than the window:
;; a page that fits is centred by redisplay itself (see the docstring).
(defun seshat-reader--center-page (&optional window)
  "Center the document with respect to WINDOW.

WINDOW must be a valid window and defaults to the selected one.

When the page fits, centring is delegated to redisplay: the page overlay
gets a `before-string' of one space whose `display' is
\\(space :align-to (+ center (-0.5 . IMAGE))), where IMAGE is the very
image spec being displayed.  Because the position is computed at layout
time, a window resize is honoured in the same redisplay, with no hook and
no stale prefix frame.

When the page is wider than WINDOW the horizontal scroll machinery is used
instead: the page is left-aligned and scrolled with the width-based
`line-prefix'.

When the geometry is unknown everything is cleared, so a stale offset from
an earlier centring cannot keep the page stuck to one side."
  (let ((window (or window (selected-window))))
    (let* ((overlay (seshat-reader-current-doc-overlay window))
           (window-width (window-body-width window t))
           (spec (seshat-reader--page-image-spec window))
           (doc-image-width (and spec (image-property spec :width))))
      (cond
       ;; 能完整放下：交给 redisplay 自己居中（before-string + align-to）
       ((and (overlayp overlay) spec (numberp doc-image-width)
             (> doc-image-width 0) (numberp window-width)
             (>= window-width doc-image-width))
        (when (overlayp seshat-reader--center-overlay)
          (overlay-put seshat-reader--center-overlay 'line-prefix nil))
        (overlay-put overlay 'line-prefix nil)
        (overlay-put overlay 'before-string
                     (propertize " " 'display
                                 (list 'space :align-to
                                       (list '+ 'center (cons -0.5 spec)))))
        (set-window-hscroll window 0))
       ;; 页面比窗口宽：左对齐 + 横向滚动（保留原 line-prefix 逻辑）
       ((and (overlayp overlay) (numberp window-width) doc-image-width)
        (overlay-put overlay 'before-string nil)
        (let* ((max-left-offset (max 0 (- window-width doc-image-width)))
               (overlay-offset `(space :width (,max-left-offset)))
               (center-overlay (seshat-reader--ensure-center-overlay))
               (pixel-per-col (seshat-reader--get-pixel-per-col window))
               (doc-left-offset (- window-width doc-image-width))
               (doc-center-offset (/ doc-left-offset 2))
               (scroll-offset (max 0 (round (/ doc-center-offset pixel-per-col)))))
          (if (overlayp center-overlay)
              (progn
                (overlay-put overlay 'line-prefix nil)
                (overlay-put center-overlay 'line-prefix overlay-offset)
                (seshat-reader--set-window-hscroll window scroll-offset t))
            (ignore-errors (seshat-reader--set-window-hscroll window 0 t))
            (ignore-errors (set-window-hscroll window 0)))))
       ;; 几何未知：清干净
       (t
        (when (overlayp overlay)
          (overlay-put overlay 'before-string nil))
        (dolist (ov (list overlay seshat-reader--center-overlay))
          (when (overlayp ov)
            (overlay-put ov 'line-prefix nil)))
        (ignore-errors (seshat-reader--set-window-hscroll window 0 t))
        (ignore-errors (set-window-hscroll window 0)))))))

(defun seshat-reader--ensure-centered (window)
  "Re-centre WINDOW's page when its centring prefix is missing or stale.

With the `before-string' centring the geometry itself needs no hook; this
check only rebuilds the prefix after a re-render replaced the image spec
\\(the stored `before-string' still references the previous spec) or after
the prefix was cleared."
  (when (and (window-live-p window)
             (overlayp (window-parameter window 'overlay))
             (not (seshat-reader--centered-p window)))
    (seshat-reader--center-page window)
    t))

(defun seshat-reader--pre-redisplay-center (&optional _window)
  "Re-centre the page of the current buffer right before it is redisplayed.

Registered buffer-locally on `pre-redisplay-functions'.  Without it the
first frames after a window resize are drawn with the previous
`line-prefix', because `window-size-change-functions' runs after that
redisplay; with it the frame that first shows the new window width is
already centred.

WINDOW is the window about to be redisplayed, as passed by
`pre-redisplay-functions'; it is ignored, because every window showing
this buffer has to be checked (the hook can run for one window while
another one is resized)."
  (when (derived-mode-p 'seshat-reader-mode)
    (dolist (window (get-buffer-window-list nil nil t))
      (seshat-reader--ensure-centered window))))

(defun seshat-reader--window-size-change (window-or-frame)
  "Recentre and schedule a refit after a size change of WINDOW-OR-FRAME.

`window-size-change-functions' passes a window when the hook entry is
buffer-local (which is how this package registers it) and a frame when it
is the global or default value.  Both shapes are accepted: a window is
checked directly, a frame is walked for windows showing the current
buffer.

Every matching window is recentred synchronously by
`seshat-reader--recenter-window', so that the frame produced by this very
redisplay is already centred; the re-render at the new scale is left to the
debounced refit.  Scheduling is buffer-wide, so at most one refit is queued
per event no matter how many windows match."
  (let* ((now (float-time))
         (delta (and seshat-reader--last-size-change-time
                     (- now seshat-reader--last-size-change-time))))
    (setq seshat-reader--last-size-change-time now
          seshat-reader--last-size-change-delta delta))
  (cond
   ((windowp window-or-frame)
    (when (eq (window-buffer window-or-frame) (current-buffer))
      (seshat-reader--recenter-window window-or-frame)
      (seshat-reader--schedule-refit)))
   ((frame-live-p window-or-frame)
    ;; 每个匹配窗口都要同步居中，但 refit 是 buffer 级的（取消并重排同一个
    ;; timer），多窗口各排一次只是重复取消/重排，故用 MATCHED 汇总后只排一次。
    (let ((matched nil))
      (dolist (window (window-list window-or-frame))
        (when (eq (window-buffer window) (current-buffer))
          (seshat-reader--recenter-window window)
          (setq matched t)))
      (when matched
        (seshat-reader--schedule-refit))))))

(defun seshat-reader--recenter-window (window)
  "Recentre WINDOW synchronously, without re-rendering the page.

Centring writes a static `line-prefix' and a static horizontal scroll, and
redisplay recomputes neither when the window grows or shrinks.  Doing the
work from the size-change hook is therefore what keeps the very frame that
noticed the size change from showing a stale, off-centre page; the resize
tests pin this behaviour.

Only geometry is touched here: the page is not re-rendered, because the C
side renders synchronously and redisplay cannot afford it.  Re-rendering at
the new scale stays in the debounced refit
\(`seshat-reader--schedule-refit').

WINDOW is skipped silently when it is no longer live, no longer shows the
current buffer, has lost its page overlay, or shows a buffer that has left
`seshat-reader-mode'.  An error while recentring one window is reported and
does not prevent the other windows from being recentred.

The page geometry is adapted synchronously first, so the very frame that
noticed the size change already shows the page at its final size; no
re-rendering happens here.

A burst of size changes (dragging a window divider) is detected by the
interval between them: such events only recentre the page, so that no
bitmap is rescaled per frame, and the geometry is adapted once by the
debounced refit when the drag stops."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (overlayp (window-parameter window 'overlay)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'seshat-reader-mode)
        (condition-case err
            (progn
              ;; 拖拽中（两次 size-change 间隔小于阈值）只居中不缩放：改 spec 尺寸
              ;; 会让 redisplay 重新缩放整页位图，拖动时每帧一次会卡 1–2 秒。
              ;; 停手后由 idle 的 `--refit-window' 做一次几何适配 + 重渲染。
              (let ((dragging (and seshat-reader--last-size-change-delta
                                   (< seshat-reader--last-size-change-delta
                                      seshat-reader--drag-threshold))))
                (unless (or dragging
                            (eq (seshat-reader--window-scale-source window) 'manual))
                  (seshat-reader--apply-display-scale
                   window (seshat-reader--fit-scale window))))
              (seshat-reader--clamp-window-vscroll window)
              (seshat-reader--center-page window))
          (error
           (message "seshat-reader: resize recentre skipped in %s: %S"
                    (buffer-name) err)))))))

(defun seshat-reader--schedule-refit ()
  "Schedule a debounced refit of the windows showing the current buffer.

Scheduling cancels the timer armed by the previous event, so a burst of
size changes results in a single refit.  Nothing is scheduled while a
refit is being applied (`seshat-reader--refitting') or when refitting is
disabled: a refit changes the window layout itself, so queueing another
one from inside it only feeds the loop."
  (unless (or seshat-reader--refitting
              (not seshat-reader--resize-refit-enabled))
    (seshat-reader--cancel-pending-refit)
    (let ((buffer (current-buffer)))
      (setq seshat-reader--resize-refit-timer
            (run-with-idle-timer seshat-reader--resize-refit-delay nil
                                 #'seshat-reader--run-pending-refit buffer)))))

(defun seshat-reader--run-pending-refit (buffer)
  "Refit the windows showing BUFFER and clear the pending timer.

This is the idle timer callback.  It runs in whatever buffer is current
at the time, so it switches to BUFFER before touching any buffer-local
state, and it refits every window of BUFFER, not just the selected one.
`seshat-reader--refitting' is bound while the windows are refitted, so the
size changes caused by the refit itself are not queued again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq seshat-reader--resize-refit-timer nil)
      (let ((seshat-reader--refitting t))
        (dolist (window (get-buffer-window-list buffer nil t))
          (seshat-reader--refit-window window))))))

(defun seshat-reader--cancel-pending-refit ()
  "Cancel the pending refit timer of the current buffer, if any.

`seshat-reader--refitting' is not touched here: it is only non-nil for the
short span of an ongoing refit, where the `let' binding restores it."
  (when (timerp seshat-reader--resize-refit-timer)
    (cancel-timer seshat-reader--resize-refit-timer))
  (setq seshat-reader--resize-refit-timer nil))

(defun seshat-reader--refit-window (window)
  "Refit the page of WINDOW to its current size.

A window whose scale source is `manual' keeps its scale and only gets its
vertical scroll clamped and the page recentred.  Every other window is
first adapted synchronously to its fit mode (`seshat-reader--fit-scale') by
rewriting the image spec, which changes no pixels and needs no rendering;
the page is then re-rendered once at that scale only when the scale the
overlay was last rendered at (`render-scale') differs from the displayed
scale, so the bitmap gets sharp again without the geometry moving.

The window is skipped silently when it is no longer live, no longer shows
the current buffer, has lost its page overlay, or shows a buffer that has
left `seshat-reader-mode'.  An error while refitting one window is
reported and does not prevent the other windows from being refitted."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (overlayp (window-parameter window 'overlay)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'seshat-reader-mode)
        (condition-case err
            (progn
              (unless (eq (seshat-reader--window-scale-source window) 'manual)
                (seshat-reader--apply-display-scale
                 window (seshat-reader--fit-scale window)))
              ;; Geometry is already final after the synchronous apply above;
              ;; re-rendering only upgrades the bitmap to the new resolution.
              ;; It runs only when the displayed scale differs from the scale
              ;; the overlay was last rendered at, so a refit never renders twice.
              (let ((scale (seshat-reader-current-doc-scale-value window))
                    (rendered (window-parameter window 'render-scale)))
                (unless (and (numberp scale) (numberp rendered) (= scale rendered))
                  (with-selected-window window
                    ;; 不传 source：清晰化重渲染不得改动 scale-source，
                    ;; 否则 manual 窗口会被静默转成 fit。
                    (seshat-reader-doc-scale-page scale))))
              (seshat-reader--clamp-window-vscroll window)
              (seshat-reader--center-page window))
          (error
           (message "seshat-reader: resize refit skipped in %s: %S"
                    (buffer-name) err)))))))


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
  (when-let* (((< (window-body-width nil t) (or (car (seshat-reader--get-current-doc-image-size)) 0)))
	      (prev-scroll (seshat-reader--window-hscroll))
	      (hscroll (+ prev-scroll amount)))
    (- (seshat-reader--set-window-hscroll nil hscroll) prev-scroll)))

(defun seshat-reader-scroll-right (&optional amount)
  "Scroll to the right of the current page by AMOUNT (or 1).

Only scrolls when the document page width is larger then the window width."
  (interactive "p")
  (or amount (setq amount 1))
  (when-let* (((< (window-body-width nil t) (or (car (seshat-reader--get-current-doc-image-size)) 0)))
	      (prev-scroll (seshat-reader--window-hscroll))
	      (hscroll (- prev-scroll amount)))
    (- prev-scroll (seshat-reader--set-window-hscroll nil hscroll))))

(defun seshat-reader-scroll-left-most ()
  "Scroll to the left most point of the current page.

Only scrolls when the document page width is larger then the window width."
  (interactive)
  (when (< (window-body-width nil t) (or (car (seshat-reader--get-current-doc-image-size)) 0))
    (seshat-reader--set-window-hscroll nil 0)))

(defun seshat-reader-scroll-right-most ()
  "Scroll to the right most point of the current page.

Only scrolls when the document page width is larger then the window width."
  (interactive)
  (when (< (window-body-width nil t) (or (car (seshat-reader--get-current-doc-image-size)) 0))
    ;; We use `set-window-hscroll' here because we need to go the right
    ;; most point directly, bypassing `'seshat-reader--set-window-hscroll' checks.
    (set-window-hscroll nil (seshat-reader--right-most-window-hscroll))))

(define-queue-command scroll-up-or-prev-page (&optional amount)
  "Scroll up the current page by AMOUNT, otherwise switch to the previous page.

AMOUNT defaults to 1."
  (interactive "p")
  (or amount (setq amount 1))
  (seshat-reader-scroll-up amount)
  ;; The join strip makes "the top of the page is on screen" the boundary
  ;; of a page, which `seshat-reader--at-page-top-p' detects even when the
  ;; strip itself is still visible.
  (when (and (seshat-reader--at-page-top-p)
	     (seshat-reader--non-queue-previous-page)) ; if succeeds
    ;; Bottom landing keeps the pages continuous when reading upwards.
    (seshat-reader--set-page-bottom)))

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
  (set-window-parameter nil 'native-size nil)
  (seshat-reader--center-page)
  (seshat-reader--set-page-top-when-joined))

(defun seshat-reader-rotate-counter-clockwise ()
  "Rotate the current window's view by 90 degrees, counter-clockwise."
  (interactive)
  (seshat-reader-dyn--rotate-page -90)
  (set-window-parameter nil 'native-size nil)
  (seshat-reader--center-page)
  (seshat-reader--set-page-top-when-joined))

(defun seshat-reader--clear-doc-memory ()
  "Clear document memory if we are in `seshat-reader-mode'.

Intended for use in `kill-buffer-hook'.  A refit that is still pending
for this buffer is cancelled as well, so that no timer survives the
buffer."
  (when (derived-mode-p 'seshat-reader-mode)
    (seshat-reader--cancel-pending-refit)
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
	  (set-window-parameter nil 'scale 1.0)
	  (set-window-parameter nil 'render-scale nil)
	  (set-window-parameter nil 'native-size nil)
	  ;; The page images are rendered anew, so cached specs are stale.
	  (setq seshat-reader--page-image-specs nil)
	  (seshat-reader--update-join-strip)
	  ;; 文档文本由原生模块生成，buffer 永远不是用户意义上的「已编辑」。
	  ;; `seshat-reader-dyn--load-doc' 重写全文后留下的 modified 标志必须清掉，
	  ;; 否则 revert 后 modeline 显示 **，super-save 等包会把重生成内容写回 PDF。
	  (set-buffer-modified-p nil)))
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
      ;; 新窗口的适配模式起点。已有 fit-mode 的窗口（用户按过 W/H，或
      ;; --first-fit 已记录）不被覆盖，因此只在参数缺失时写入。
      (unless (window-parameter window 'fit-mode)
        (set-window-parameter window 'fit-mode
                              (seshat-reader--normalize-default-fit
                               seshat-reader-default-fit)))
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
ensures a valid overlay exists if the new buffer is a seshat-reader buffer,
and recentres a window whose page overlay survived the switch.

`set-window-buffer' resets the window's horizontal scroll to zero on its
own, and showing the same document in a new window or a new frame triggers
neither `window-size-change-functions' nor the creation of a new overlay,
so without this recentre the page stays glued to the right edge of the
window and never recovers."
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
    ;; If the new buffer is a seshat-reader buffer: recentre when the page
    ;; overlay is already there, otherwise create it.  The two branches are
    ;; mutually exclusive on purpose — `--window-create-function' already
    ;; centres the page, so recentring again would only do the work twice.
    (when (with-current-buffer (window-buffer window)
            (derived-mode-p 'seshat-reader-mode))
      (if (window-parameter window 'overlay)
          (seshat-reader--recenter-window window)
        (seshat-reader--window-create-function window)))))

;; We explicitly bind default keys because relying on the rebinding
;; mechanism can lead to them not being bound at all if users have
;; overridden the defaults with other commands.
;; `seshat-reader-help' 在另一个文件里，这里只声明不 require（首次调用由
;; autoload 加载），声明同时消掉字节编译的未定义函数告警。
(declare-function seshat-reader-help "seshat-reader-help")
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

  "o"       #'seshat-reader-outline-toggle

  "Q"       #'seshat-reader-close-doc

  ;; "?" 打开内置帮助页：`seshat-reader-help' 自带 `;;;###autoload'，首次按下
  ;; 时由 autoload 懒加载该模块，故这里**不需要** require 它，也不会把帮助
  ;; 模块拖进阅读器的加载路径。
  "?"       #'seshat-reader-help


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

;;; Evil 兼容（软依赖）

;; evil 是**软依赖**：本包不 `require'、不写进 `Package-Requires'，也不做任何
;; 版本探测；evil 不在时下面的注册整体静默跳过（`fboundp' 守卫）。
;;
;; 为什么需要它：evil 把各 state 的 keymap（`evil-normal-state-map' →
;; `evil-motion-state-map'）经 `emulation-mode-map-alists' 挂在 major-mode-map
;; **之前**，而 `?' 在 normal state 是 `evil-search-backward'，于是上面
;; `seshat-reader-mode-map' 里的 `?' 在 evil 用户手里按不到——实测 Emacs 31.1
;; + evil：normal state 下 `(key-binding (kbd "?"))' 为 `evil-search-backward'
;; 而不是 `seshat-reader-help'。
;;
;; **只接管 `?' 与 `n' / `p'**：evil 的 `/`（正向搜索）、`N`（上一处）一律不动。
;; 阅读器自己的搜索走 `C-s'（`seshat-reader-search'，全程基于页面坐标、与
;; buffer 文本无关），evil 的 `?` 反向搜索在只读、单页位图的阅读 buffer 里没有
;; 用武之地，故让给帮助页；想保留 evil 反向搜索的用户可在自己配置里覆盖本绑定
;; （`(evil-define-key* 'normal seshat-reader-mode-map (kbd "?")
;; #'evil-search-backward)'）——本包只在**加载时**注册一次，不会再次抢回。
;;
;; `n' / `p' 在阅读 buffer 是**翻页**（`seshat-reader-next-page' /
;; `-previous-page'，与 `seshat-reader-mode-map' 里的绑定一致），但 normal state
;; 下被 `evil-search-next' / `evil-paste-after' 抢走；`hjkl' / `v' / `y' /
;; `gg' / `G' 等原生键**一律不碰**，evil 的移动、可视选取与复制照旧可用。
;; 搜索会话期间 `n' / `p' 的「下一个/上一个命中」由搜索模块的临时键表提供（见
;; `seshat-reader-search--map'），会话一结束即恢复翻转页语义——本函数不参与该
;; 切换，故两个模块不抢同一个键。
;;
;; 为什么用 `evil-define-key*'：它是**函数**（evil-core.el，签名
;; `(STATE KEYMAP KEY DEF &rest BINDINGS)'），把绑定写进 KEYMAP 关联的
;; **auxiliary keymap**；`evil-normalize-keymaps' 装载时 auxiliary keymap 的
;; 优先级高于 state 自身的 map，因此这条绑定只在本 mode 生效、压过
;; `evil-motion-state-map'，且**不触碰** evil 的全局 map（传的 KEYMAP 是本 mode
;; 的 map，不是 `global'）。`evil-define-key'（无星号）是宏、且会把绑定延迟到
;; `after-load-functions'，不如函数版确定。
;;
;; 注册位置必须在**阅读器本身**、而不是帮助页模块（`seshat-reader-help'）里：
;; 帮助页是 `?' 首次按下时才由 autoload 加载的，若把补绑写在那边，evil 用户
;; 第一次按 `?' 走的仍是 `evil-search-backward'、永远不会加载帮助页，补绑也就
;; 永远不生效。
;;
;; `M-o'（全部面板开合）**不需要**补绑：evil 的 normal state 未占该键（实测
;; Emacs 31.1 + evil：normal state 下 `(key-binding (kbd "M-o"))' 已经是
;; `seshat-reader-sidebar-toggle'）。将来若某个 evil 版本占了它，按同一模式在
;; 本函数里加一对绑定即可。
(defun seshat-reader--install-evil-bindings ()
  "Install the reader's `?' and `n' / `p' bindings for evil's normal state.
`n' / `p' keep meaning \"next / previous page\" in the reading buffer (the
same commands `seshat-reader-mode-map' binds); evil's `evil-search-next' /
`evil-paste-after' would otherwise take them.  `hjkl' / `v' / `y' are left
alone, so evil's motion, visual selection and yank stay available.

Soft dependency: does nothing when evil (or `evil-define-key*') is absent, so
loading this library never requires evil.  Extracted from the
`with-eval-after-load' block below only so that it can be unit-tested."
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'normal seshat-reader-mode-map
      (kbd "?") #'seshat-reader-help
      "n"       #'seshat-reader-next-page
      "p"       #'seshat-reader-previous-page)))

;; evil 可能在本文件之后才加载（用户把 evil 放在 init 更后面），故用
;; `with-eval-after-load' 挂到 evil 上：evil 已加载时立即执行，未加载则等它加载
;; 完再执行，两条路径都只注册一次。
(with-eval-after-load 'evil
  (seshat-reader--install-evil-bindings))

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

  ;; contain：打开文档时若窗口已很窄（目录/侧栏开着），不能让页面溢出
  ;; 首次 fit 用显示层缩放一步到位（不重渲染），避免「先按默认比例画一张小图
  ;; 居中、再重渲染大图重新居中」的两帧；清晰位图由 idle 的 refit 补一次。
  ;; 起点由 `seshat-reader-default-fit' 的 `fit-mode' 决定（默认含 contain）。
  (seshat-reader--first-fit)
  (add-hook 'window-size-change-functions #'seshat-reader--window-size-change nil t)
  (add-hook 'window-configuration-change-hook #'seshat-reader--manage-window-overlays nil t)
  (add-hook 'window-buffer-change-functions #'seshat-reader--handle-window-buffer-change nil t)
  (add-hook 'pre-redisplay-functions #'seshat-reader--pre-redisplay-center nil t))

(defun seshat-reader--page-indicator ()
  "返回 `[当前页/总页]' 形式的字符串，供 mode-line 显示.
当前页取 `seshat-reader-current-doc-pagenumber'（读窗口参数），总页数取
buffer-local 变量 `seshat-reader-current-doc-pagecount'（由动态模块设置）；
任一取不到（文档尚未加载完）时该项用 `?' 占位，不报错、不阻塞 redisplay。"
  (format "[%s/%s]"
          (or (seshat-reader-current-doc-pagenumber) "?")
          (or (bound-and-true-p seshat-reader-current-doc-pagecount) "?")))

(defvar seshat-reader--page-mode-line '(:eval (seshat-reader--page-indicator))
  "挂到 `mode-line-misc-info' 的页码元素.
用 defvar 而非字面量，便于用 `member'/`equal' 去重（`mode-line-misc-info' 是
全局变量，重复进入 mode 时不能累积多个副本）。")

(defun seshat-reader-mode-line ()
  "Set custom mode-line interface when reading documents."
  (setq-local mode-line-position
	      '(" P" (:eval (number-to-string (seshat-reader-current-doc-pagenumber)))
                "/" (:eval (number-to-string seshat-reader-current-doc-pagecount))))
  ;; 第三方 modeline（doom-modeline 等）接管 `mode-line-format' 后不会读
  ;; `mode-line-position'，故同时把页码挂到 `mode-line-misc-info'：
  ;; doom-modeline 的 misc-info segment 会 `format-mode-line' 它，原生 modeline
  ;; (`mode-line-misc-info' 默认就在 `mode-line-format' 里) 同样会显示。
  (unless (member seshat-reader--page-mode-line mode-line-misc-info)
    (setq-local mode-line-misc-info
                (cons seshat-reader--page-mode-line mode-line-misc-info)))
  ;; doom-modeline 的行列段在 PDF 阅读 buffer 里恒为 "1:0"（整页只有一行），
  ;; 对阅读毫无意义且占位，故在本 buffer 把三种格式都清空（保留 mode 判断逻辑，
  ;; 只是不产生文本）；行列段与百分比段一并隐藏。
  ;; `boundp' 守卫使非 doom-modeline 环境完全无副作用。
  (when (boundp 'doom-modeline-position-column-line-format)
    (setq-local doom-modeline-position-column-line-format '(""))
    (setq-local doom-modeline-position-line-format '(""))
    (setq-local doom-modeline-position-column-format '(""))
    ;; 同一 segment 还带 `%p'（buffer 百分比）：PDF 阅读 buffer 只有一行、整段
    ;; 可见，`%p' 恒为 "All"，对阅读无意义。该变量是 (CONDITION THEN ELSE) 的
    ;; 条件，nil 时走 else 分支（只剩分隔符），故安全。
    (setq-local doom-modeline-percent-position nil)))

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
  (when (derived-mode-p 'seshat-reader-mode)
    (seshat-reader-dyn--doc-invert (if seshat-reader-dark-mode 1 0))
    (seshat-reader--redisplay-all-windows)))

(define-minor-mode seshat-reader-presentation-mode
  "Toggle presentation view for current seshat-reader document."
  :lighter ""
  (when (derived-mode-p 'seshat-reader-mode)
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
