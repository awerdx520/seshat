;;; seshat-reader.el --- General-purpose Document Reader -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026  Divya Ranjan Pattanaik
;; Copyright (C) 2025-2026  Tushar

;; Author: Divya Ranjan Pattanaik <divya@subvertising.org>
;; Keywords: lisp, files, tools
;; Version: 0.3.2
;; Package-Requires: ((emacs "29.1"))
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

;; 前向声明：页表在下面的多页布局段落里由 `defvar-local' 定义，而
;; `seshat-reader-current-doc-pagenumber' 等访问器先于它出现。
(defvar seshat-reader--pages)

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

(defun seshat-reader-current-doc-overlay (&optional window page)
  "Return the image spec displayed for PAGE, or for the page atop WINDOW.

WINDOW must be a valid window and defaults to the selected one.  PAGE is a
1-based page number and defaults to the page `window-start' falls into.

The name is kept from the single-page layout, where the function returned
the overlay that carried the page image in its `display' property.  Since
P1 a page is displayed by a page row whose `display' text property holds
the spec, so the accessor returns that spec: no window parameter and no
overlay is read here any more, and every caller was converted to the spec
semantics (see `seshat-reader--get-current-doc-image-size' and
`seshat-reader--page-image-spec')."
  (when seshat-reader--pages
    (seshat-reader--multipage-page-spec
     (or page
         (seshat-reader--multipage-window-start-page
          (or window (selected-window)))))))

(defun seshat-reader-current-doc-pagenumber (&optional window)
  "Page number at the top of WINDOW.

WINDOW must be a valid window and defaults to the selected one.  The number
is derived from the page row that `window-start' falls into, because the
multi-page layout shows several pages at once and only the page at the top
is unambiguous.  The page parameter the native module writes is no longer
read: it still describes a single displayed page and would disagree with
the layout as soon as the window is scrolled by less than a page.

nil is returned while the buffer holds no page row; the native fallback is
used when the viewport cannot be mapped to a row."
  (when seshat-reader--pages
    (or (seshat-reader--multipage-window-start-page
         (or window (selected-window)))
        seshat-reader--recent-pagenumber-fallback)))

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

The document is loaded and displayed by `seshat-reader-mode', which calls
`seshat-reader--render-buffer' to build the multi-page layout in a new
buffer.  Loading the document here as well would leave the buffer with the
single-page overlay the native module creates, because the render status it
records would make the mode skip the layout.

The only formats that can be opened `seshat-reader-supported-formats', any
other file format will simply not show up as a candidate."
  (interactive (list (expand-file-name (seshat-reader--read-doc-name))))
  (switch-to-buffer (create-file-buffer document))
  (setq buffer-file-name document)
  (seshat-reader-mode))

(define-queue-command next-page ()
  "Go to the next page of the document."
  (interactive)
  (let* ((page (seshat-reader-current-doc-pagenumber))
         (target (and (integerp page)
                      (seshat-reader--multipage-clamp-page (1+ page)))))
    (when (and target (> target page))
      (seshat-reader--multipage-goto target)
      ;; Must return `t' when the command succeeds.
      (force-mode-line-update) t)))

(define-queue-command previous-page ()
  "Go to the previous page of the document."
  (interactive)
  (let* ((page (seshat-reader-current-doc-pagenumber))
         (target (and (integerp page)
                      (seshat-reader--multipage-clamp-page (1- page)))))
    (when (and target (< target page))
      (seshat-reader--multipage-goto target)
      ;; Must return `t' when the command succeeds.
      (force-mode-line-update) t)))

(defun seshat-reader-first-page ()
  "Go to the first page of the document."
  (interactive)
  (when (seshat-reader--multipage-goto 1)
    (force-mode-line-update)))

(defun seshat-reader-last-page ()
  "Go to the last page of the document."
  (interactive)
  (let ((count (seshat-reader--multipage-pagecount)))
    (when (and count (seshat-reader--multipage-goto count))
      (force-mode-line-update))))

(defun seshat-reader-goto-page (n)
  "Go to page number N in the current document."
  (interactive "nGoto page: ")
  (when (seshat-reader--multipage-goto n)
    (force-mode-line-update)))

(defun seshat-reader--get-current-doc-image-size (&optional window)
  "Return the pixel size of the page at the top of WINDOW as (WIDTH . HEIGHT).

WINDOW must be a valid window and defaults to the selected one.  nil is
returned while `window-start' does not fall into a rendered page row, which
is the case for an empty buffer and for a row that has not been rendered
yet."
  (when-let* ((spec (seshat-reader-current-doc-overlay window)))
    (cons (image-property spec :width) (image-property spec :height))))

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

;;; Multi-page geometry state (P1 T4)

;; The geometry of a page is buffer-local: every window showing the buffer
;; shows the same page sizes, and only the viewport differs.  These two
;; variables state the zoom the whole document is displayed at, and the two
;; per-page caches below them remember what each page was measured at.

(defvar-local seshat-reader--multipage-base-scale 1.0
  "Base scale every page of the current buffer is derived from.

It is fixed when the document is first displayed -- from the native size of
the page at the top of the window and the window size, under the initial
fit mode -- and does not follow the scroll position (decision D5).  The
scale a page is actually drawn at is computed from it by
`seshat-reader--multipage-target-scale', which may crop a wide page in the
`contain' and `width' modes.")

(defvar-local seshat-reader--multipage-fit-mode nil
  "Fit mode the page rows of the current buffer are displayed with.

One of `contain', `width', `height' or `manual', or nil while it has not
been seeded yet: `seshat-reader--multipage-current-fit-mode' then falls back
to the window's fit mode.  The value is buffer-local because the scales
belong to the buffer -- every window showing it shows the same sizes.")

(defvar-local seshat-reader--page-native-sizes nil
  "Unscaled pixel sizes of the pages, as an alist PAGE -> (W . H).

Recorded the first time a page is rendered, by dividing the size of the spec
the native module returned by the scale it was rendered at, which is why no
native interface is needed to learn the size of a page (decision D5).  Two
pages of one document may differ in size, so the value is per page and not
per window.")

(defvar-local seshat-reader--page-render-scales nil
  "Scale the bitmap of each page was rendered at, as an alist PAGE -> SCALE.

`seshat-reader--multipage-refit-page' compares it with the target scale of
the page to decide whether the bitmap has to be rendered again: rewriting a
spec only stretches the bitmap that is already there, so the resolution is
upgraded once the geometry has settled.")

(defvar-local seshat-reader--pages nil
  "Page rows of the multi-page layout of the current buffer.

Each element is (PAGE MARKER . SPEC): PAGE is the 1-based page number,
MARKER points at the first character of the page row (made with
`copy-marker' and an insertion type of t, so text inserted at the row
start stays before the marker) and SPEC is the image spec the row
displays, or nil while the page has not been rendered yet.  The list is
kept sorted by PAGE; go through `seshat-reader--multipage-insert-page' and
`seshat-reader--multipage-remove-page' rather than editing it directly.")

(defun seshat-reader--multipage-align-to (spec)
  "Return the display value that centres a page row showing SPEC.

The value is a zero-width `space' display specification whose `:align-to'
form is `(+ center (-0.5 . SPEC))', so redisplay puts the image that follows
in the middle of the window and recomputes the position on every frame -- a
window resize is honoured in the same redisplay, with no hook and no stale
prefix.  SPEC is referenced by identity on purpose: rewriting its `:width'
in place (`seshat-reader--multipage-resize-spec') makes the centring follow
the new size without touching the row."
  (list 'space :align-to (list '+ 'center (cons -0.5 spec))))

(defun seshat-reader--window-scale-source (&optional window)
  "Return WINDOW's scale source, `fit' or `manual' (default `fit').

WINDOW defaults to the selected window.  A window that never recorded a
source, for example one restored from a bookmark, counts as `fit'."
  (or (window-parameter (or window (selected-window)) 'scale-source) 'fit))

(defun seshat-reader--multipage-clamp-scale (scale)
  "Return SCALE clamped to the range the native module can render.

SCALE is a multiple of 72 dpi.  The bounds are those of the native renderer
\(MINRES 18 dpi, MAXRES 850 dpi, i.e. 0.25 .. 11.8) rounded inwards on the
top end: a scale the module would clamp silently would make the recorded
native size of the page wrong, because that size is the spec size divided by
the scale the page was requested at.  A non-numeric SCALE falls back to 1.0
so that a caller which lost its value still renders."
  (cond ((not (numberp scale)) 1.0)
        ((<= scale 0) 1.0)
        (t (max 0.25 (min 11.0 (float scale))))))

(defun seshat-reader--multipage-set-scale (scale &optional source mode)
  "Display every page row at SCALE and return SCALE.

SCALE becomes the buffer local base scale, so every page keeps the same zoom
factor and no page is cropped for its own width (decision D5: the manual
`+' / `-' zoom never crops).  SOURCE, when non-nil, is recorded as the scale
source of the selected window (`fit' or `manual'); MODE, when non-nil,
replaces the buffer local fit mode.

The specs are rewritten in place and every row is re-centred, so the frame
that follows already shows the new geometry; the bitmaps are rendered at the
new resolution by the debounced refit."
  (let ((scale (seshat-reader--multipage-clamp-scale scale)))
    (setq seshat-reader--multipage-base-scale scale)
    (when mode
      (setq seshat-reader--multipage-fit-mode mode))
    (setq seshat-reader--recent-scale-fallback scale)
    (set-window-parameter nil 'scale scale)
    (when source
      (set-window-parameter nil 'scale-source source))
    (seshat-reader--apply-display-scale (selected-window))
    (seshat-reader--center-page (selected-window))
    (seshat-reader--schedule-refit)
    scale))

(defun seshat-reader-enlarge-size (&optional scaling-factor)
  "Enlarge the size of every visible page by `seshat-reader-enlarge-factor'.

Optionally scale it by the SCALING-FACTOR, which is the new scale itself.
Scales on the selected window: the pages are rescaled in place by rewriting
their image specs, so nothing is re-rendered here."
  (interactive (list (float
		      (* (seshat-reader-current-doc-scale-value) seshat-reader-enlarge-factor))))
  (seshat-reader--multipage-set-scale scaling-factor 'manual 'manual))

(defun seshat-reader-shrink-size (&optional scaling-factor)
  "Shrink the size of every visible page by `seshat-reader-shrink-factor'.

Optionally scale it by the SCALING-FACTOR, which is the new scale itself.
Scales on the selected window: the pages are rescaled in place by rewriting
their image specs, so nothing is re-rendered here."
  (interactive (list (float
		      (* (seshat-reader-current-doc-scale-value) seshat-reader-shrink-factor))))
  (seshat-reader--multipage-set-scale scaling-factor 'manual 'manual))

(defun seshat-reader-reset-size ()
  "Reset the size of every visible page to 1.0.

The zoom becomes manual, so the pages are shown at their native scale even
when they do not fit the window."
  (interactive)
  (seshat-reader--multipage-set-scale 1.0 'manual 'manual))

(defun seshat-reader-fit-to-height ()
  "Scale every visible page so that one page fills the window height.

The page is scaled on both dimensions, so a wide page overflows horizontally
and is left aligned; horizontal scrolling brings the rest into view.  That
is the pre-existing `fit-to-height' semantics, kept as it is by decision D5
\(`height' is the one mode that is allowed to overflow)."
  (interactive)
  (let* ((window (selected-window))
         (page (or (seshat-reader--multipage-window-start-page window) 1))
         (scale (or (seshat-reader--multipage-fit-scale page 'height window)
                    1.0)))
    (set-window-parameter window 'fit-mode 'height)
    (seshat-reader--multipage-set-scale scale 'fit 'height)))

(defun seshat-reader-fit-to-width ()
  "Scale every visible page so that each page fills the window width.

Every page is fitted to its own width, so pages of different widths all end
up exactly as wide as the window and none of them overflows (decision D5,
`width' mode)."
  (interactive)
  (let* ((window (selected-window))
         (page (or (seshat-reader--multipage-window-start-page window) 1))
         (scale (or (seshat-reader--multipage-fit-scale page 'width window)
                    1.0)))
    (set-window-parameter window 'fit-mode 'width)
    (seshat-reader--multipage-set-scale scale 'fit 'width)))

(defun seshat-reader--contain-scale (&optional window)
  "Return the scale at which the page at the top of WINDOW fits completely.

WINDOW defaults to the selected one.  The result is the smaller of the two
dimensions' scales, so whichever dimension binds is the one that ends up
filled; the page is never enlarged beyond it.  This function provides the
`contain' geometry itself and does not read `seshat-reader-default-fit':
that option only decides which fit mode a window starts with (see
`seshat-reader--initial-fit-mode')."
  (let* ((window (or window (selected-window)))
         (page (or (seshat-reader--multipage-window-start-page window) 1)))
    (or (seshat-reader--multipage-fit-scale page 'contain window) 1.0)))

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
  "Fit the pages of the selected window for the first time they are shown.

The base scale is derived from the native size of the page at the top of the
window and the window size, under the window's initial fit mode
\(`seshat-reader--initial-fit-mode'), which is recorded first so that later
resizes keep using it.  That base scale is then fixed for the whole document
\(decision D5: the reference page is the first one and it never follows the
scroll position).

The specs are adapted in place, so the very first frame already shows the
pages at their final size; the bitmaps are rendered at the new resolution by
the debounced refit afterwards.  Nothing is done in a buffer without page
rows."
  (let* ((window (selected-window))
         (mode (seshat-reader--initial-fit-mode))
         (page (or (seshat-reader--multipage-window-start-page window) 1)))
    (set-window-parameter window 'fit-mode mode)
    (setq seshat-reader--multipage-fit-mode mode)
    (when-let* ((scale (seshat-reader--multipage-fit-scale page mode window)))
      (setq seshat-reader--multipage-base-scale
            (seshat-reader--multipage-clamp-scale scale)))
    (seshat-reader--apply-display-scale window)
    (seshat-reader--center-page window)
    (seshat-reader--schedule-refit)))

(defun seshat-reader--window-fit-mode (&optional window)
  "Return WINDOW's fit mode: `contain', `width' or `height'.

WINDOW defaults to the selected one.  A window that never recorded a mode
\(opened before the option existed, restored from a bookmark, or simply
never used `H' / `W') counts as `contain', which keeps the pre-existing
behaviour of fitting the whole page into the window."
  (or (window-parameter (or window (selected-window)) 'fit-mode) 'contain))

(defun seshat-reader--multipage-current-fit-mode (&optional window)
  "Return the fit mode the page rows are displayed with.

The buffer local `seshat-reader--multipage-fit-mode' wins, because every
window showing this buffer shows the same scales; it is seeded from the
window's fit mode by `seshat-reader--first-fit' and
`seshat-reader--ensure-window-layout', so a window that never recorded one
still gets the `seshat-reader-default-fit' behaviour.  WINDOW defaults to
the selected one."
  (or seshat-reader--multipage-fit-mode
      (seshat-reader--window-fit-mode (or window (selected-window)))))

(defun seshat-reader--multipage-fit-scale (page mode &optional window)
  "Return the scale at which PAGE fits WINDOW under fit MODE.

PAGE is a 1-based page number, MODE is one of `contain', `width' and
`height', and WINDOW defaults to the selected one.  The native size of PAGE
\(`seshat-reader--page-native-sizes') is what makes this page-based: a page
only ever needed to fit on its own dimensions, which is what gives `contain'
its `min (base scale, width fit)' shape through
`seshat-reader--multipage-target-scale'.

nil is returned while the native size of PAGE is unknown, i.e. before the
page has been rendered once."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (native (seshat-reader--multipage-native-size page))
         (width (car-safe native))
         (height (cdr-safe native))
         (window-width (window-body-width window t))
         (window-height (window-body-height window t)))
    (when (and (numberp width) (> width 0) (numberp height) (> height 0))
      (let ((width-fit (and (numberp window-width) (> window-width 0)
                            (/ (float window-width) width)))
            (height-fit (and (numberp window-height) (> window-height 0)
                             (/ (float window-height) height))))
        (pcase mode
          ('width width-fit)
          ('height height-fit)
          (_ (and width-fit height-fit (min width-fit height-fit))))))))

(defun seshat-reader--multipage-target-scale (page &optional window)
  "Return the scale PAGE should be displayed at in WINDOW.

PAGE is a 1-based page number and WINDOW defaults to the selected one.  The
mode comes from `seshat-reader--multipage-current-fit-mode' and the table is
the one decision D5 fixes:

  `contain'  min (base scale, width fit of PAGE) -- a wide page is cropped
             to the window width, so nothing overflows;
  `width'    width fit of PAGE, so every page fills the window exactly;
  `height'   height fit of PAGE -- the width is *not* cropped, an overwide
             page is left aligned and horizontally scrollable;
  `manual'   the base scale itself, i.e. the `+' / `-' zoom factor with no
             cropping at all.

The base scale is fixed for the document (\"first page reference\"), so
scrolling across a page boundary never changes the zoom of the pages that
stay on screen.  While the native size of PAGE is still unknown the base
scale is returned, which is what the first render of a page uses."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (mode (seshat-reader--multipage-current-fit-mode window))
         (base (or seshat-reader--multipage-base-scale 1.0))
         (native (seshat-reader--multipage-native-size page))
         (width (car-safe native))
         (window-width (window-body-width window t))
         (width-fit (and (numberp width) (> width 0)
                         (numberp window-width) (> window-width 0)
                         (/ (float window-width) width))))
    (seshat-reader--multipage-clamp-scale
     (pcase mode
       ('width (or width-fit base))
       ('height (or (seshat-reader--multipage-fit-scale page 'height window) base))
       ('manual base)
       (_ (min base (or width-fit base)))))))

(defun seshat-reader--fit-scale (&optional window)
  "Return the scale the page at the top of WINDOW should have.

WINDOW defaults to the selected one.  The scale follows the buffer local fit
mode of the page rows; `width' and `height' use only one dimension, so an
explicit `W' (\\[seshat-reader-fit-to-width]) keeps filling the width even
when the page then overflows vertically, and `H'
\(\\[seshat-reader-fit-to-height]) does the converse."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (page (or (seshat-reader--multipage-window-start-page window) 1)))
    (or (seshat-reader--multipage-target-scale page window)
        seshat-reader--multipage-base-scale
        1.0)))

(defun seshat-reader--page-image-spec (window &optional page)
  "Return the image spec displayed for PAGE in WINDOW.

PAGE is a 1-based page number and defaults to the page at the top of WINDOW,
which defaults to the selected one.  This is a thin alias of
`seshat-reader-current-doc-overlay', kept under its historical name because
the callers read the spec of the page a window shows."
  (seshat-reader-current-doc-overlay window page))

(defun seshat-reader--native-page-size (&optional window)
  "Return the unscaled pixel size of the page at the top of WINDOW as (W . H).

WINDOW defaults to the selected one.  The native size is per page and lives
in `seshat-reader--page-native-sizes', recorded the first time the page is
rendered (spec size divided by the scale it was rendered at), because two
pages of one document may well differ in size.  nil is returned while that
page has not been rendered yet."
  (when-let* ((page (seshat-reader--multipage-window-start-page
                     (if (window-live-p window) window (selected-window)))))
    (seshat-reader--multipage-native-size page)))

(defun seshat-reader--apply-display-scale (&optional window scale)
  "Resize every page row of WINDOW to its target scale, without rendering.

WINDOW defaults to the selected one.  SCALE, when non-nil, replaces the
buffer local base scale first, so a caller can apply a new zoom level in one
step; SCALE is clamped like every other scale.  Each page is resized by
rewriting the `:width' and `:height' of its image spec in place, following
`seshat-reader--multipage-target-scale', which is the per-mode table of
decision D5.  An overwide page (the `height' mode and the manual zoom) keeps
its size and is left aligned instead of being cropped.

Return non-nil when at least one spec changed.  The window parameter `scale'
and the buffer-local `seshat-reader--recent-scale-fallback' are updated
together with the specs, so that \"spec size / scale = native size\" keeps
holding for the bookmarks and the selection code that read the scale.

No `image-flush' is issued here: rewriting the spec in place is enough for
the new geometry to take effect, and flushing on every size change would
make redisplay re-decode the whole page bitmap each time, which is what
makes dragging a window divider stall."
  (let ((window (if (window-live-p window) window (selected-window)))
        (changed nil))
    (when (and (numberp scale) (> scale 0))
      (setq seshat-reader--multipage-base-scale
            (seshat-reader--multipage-clamp-scale scale)))
    (when (eq (window-buffer window) (current-buffer))
      (dolist (page (seshat-reader--multipage-page-numbers))
        (when (seshat-reader--multipage-resize-spec page window)
          (setq changed t))))
    (setq seshat-reader--recent-scale-fallback
          (or seshat-reader--multipage-base-scale 1.0))
    (set-window-parameter window 'scale seshat-reader--recent-scale-fallback)
    changed))

(defun seshat-reader--get-pixel-per-col (&optional window)
  "Get the no of pixels per column for WINDOW.

WINDOW must be a valid window and defaults to the selected one."
  (/ (window-body-width window t) (window-body-width window)))

;;; Per-page image spec (P0 groundwork for a multi-page layout)

;; `seshat-reader-dyn--page-image-spec' renders one page outside the display
;; path: given a page number, a scale and a rotation it hands back the image
;; spec of that page without reading or writing a window parameter, an
;; overlay, a cache slot or the current page number.  The wrapper below adds
;; a small spec cache on top of it.
;;
;; The entry point is synchronous and blocks the Emacs main thread for about
;; as long as one page of `seshat-reader-dyn--refresh-highlights', so P0 only
;; exposes it for explicit measurement (and for P1 to build on).  Nothing in
;; the display, redisplay or scrolling paths may call it.

(defvar seshat-reader--page-spec-cache-limit 8
  "Maximum number of specs kept in `seshat-reader--page-spec-cache'.

Each entry pins a copy of the page bitmap on the Lisp heap (the `:data'
string of the spec) while the native module keeps its own copy in the
`CachedPage' and in the MuPDF image cache, so one entry costs roughly two
bitmaps.  Eight is what P0 needs to measure page-to-page reuse; do not
raise it past sixteen.")

(defvar-local seshat-reader--page-spec-cache nil
  "Buffer-local cache of per-page image specs, newest entry first.

Each element is a cons cell (KEY . SPEC).  KEY is the normalized list
\(PAGE SCALE ROTATE), as built by `seshat-reader--page-spec-key', and SPEC
is the image spec the native module returned for it.  At most
`seshat-reader--page-spec-cache-limit' entries are kept and the oldest one
is dropped first.  Only `seshat-reader--page-spec' reads this cache: no
display path uses it in P0.")

(defun seshat-reader--page-spec-key (page &optional scale rotate)
  "Return the cache key for PAGE rendered at SCALE and rotated by ROTATE.

SCALE defaults to 1.0 and is coerced to a float, ROTATE defaults to 0, so
that equal requests spelled differently (nil / 1 / 1.0) share one key —
`assoc' compares keys with `equal', which equates neither 1 with 1.0 nor
nil with 1.0."
  (list page
        (cond ((null scale) 1.0)
              ((numberp scale) (float scale))
              (t scale))
        (cond ((null rotate) 0)
              ((numberp rotate) (truncate rotate))
              (t rotate))))

(defun seshat-reader--page-spec-remember (key spec)
  "Cache SPEC under KEY, dropping the oldest entry above the cache limit.

The list is kept newest first, so the oldest entry is the last one; the
walk is a plain `while' loop rather than a `cl-*' helper to stay in line
with the hand-written list code elsewhere in this file."
  (push (cons key spec) seshat-reader--page-spec-cache)
  (let ((tail seshat-reader--page-spec-cache)
        (count 1))
    (while (and (cdr tail) (< count seshat-reader--page-spec-cache-limit))
      (setq tail (cdr tail))
      (setq count (1+ count)))
    (when (cdr tail)
      (setcdr tail nil)))
  seshat-reader--page-spec-cache)

(defun seshat-reader--page-spec (page &optional scale rotate)
  "Return the image spec of PAGE rendered at SCALE and rotated by ROTATE.

PAGE is 1-based.  SCALE is a multiple of 72 dpi (1.0 when nil) and is
clamped by the native module to its MINRES/MAXRES range.  ROTATE is 0 when
nil and must then be 0, 90, 180 or 270.  The native module rejects invalid
arguments (out-of-range or non-integral page, non-numeric scale,
unsupported rotation, document being reloaded) by returning nil, and nil is
what this function returns then as well; a nil result is never cached.

A spec is cached in `seshat-reader--page-spec-cache' under the normalized
key (PAGE SCALE ROTATE), so a repeated request returns the very same spec
object without calling the native module again.  Rendering is synchronous
and blocks the Emacs main thread, so this is a measurement/P1 hook only and
must not be called from a scrolling or redisplay path.  The result is nil
when the loaded native module predates the entry point, which keeps this
file working with an older `seshat-render-core'."
  (when (fboundp 'seshat-reader-dyn--page-image-spec)
    (let* ((key (seshat-reader--page-spec-key page scale rotate))
           (cached (assoc key seshat-reader--page-spec-cache)))
      (if cached
          (cdr cached)
        ;; The normalized key doubles as the argument list, so the scale and
        ;; rotate defaults are applied in exactly one place.
        (let ((spec (seshat-reader-dyn--page-image-spec
                     page (nth 1 key) (nth 2 key))))
          (when spec
            (seshat-reader--page-spec-remember key spec))
          spec)))))

(defun seshat-reader--page-spec-clear-cache ()
  "Drop every cached per-page image spec of the current buffer.

Called when the cached specs become stale: the document is closed
\(`seshat-reader--clear-doc-memory') or re-rendered
\(`seshat-reader--render-buffer'), where the page bitmaps and the
decorations painted into them are rebuilt from scratch."
  (setq seshat-reader--page-spec-cache nil))

;;; Multi-page layout (P1)

;; P1 replaces the per-window page overlay with a buffer that holds one row
;; per page, each row carrying that page's image spec as its `display' text
;; property.  T1 landed the structure, T1b/T2/T3 wired it into the display
;; path and T4 adds the geometry: a row is centred by a leading `:align-to'
;; space, the scale of a page is derived from its own native size and the
;; window, and the spec of a row is rewritten in place when the geometry
;; changes so that no page has to be rendered twice.

(defcustom seshat-reader-page-gap-lines 0
  "Number of blank lines kept between two consecutive page rows.

0 makes adjacent pages touch each other, which matches the continuous
scrolling layout of the Android client; a positive value leaves that many
empty lines between the bottom of one page and the top of the next one."
  :group 'seshat-reader
  :type 'integer)

(defvar-local seshat-reader--multipage-preload 2
  "Number of pages kept resident above and below the visible ones.

The resident set is the page at the top of the window through the page at
its bottom, widened by this many pages in each direction and clipped to
the pages that actually exist in the buffer.  A value of 0 keeps only the
pages the window currently shows.")

(defun seshat-reader--multipage-page-row (spec &optional wide)
  "Return the buffer text of one page row displaying SPEC.

SPEC is an image spec as returned by `seshat-reader--page-spec', or nil for
a page that is not rendered yet.  A rendered row is two spaces followed by a
newline: the first space carries the `:align-to' value of
`seshat-reader--multipage-align-to' (which keeps the page horizontally
centred), the second one carries SPEC itself as its `display' property.  The
row therefore occupies exactly one buffer line and has a well-defined line
start to anchor its marker on.  A placeholder row is the same width without
any property, so that filling the page in later never shifts the layout.

WIDE non-nil drops the centring space, which is what an overwide page needs:
its image then starts at the left edge and horizontal scrolling -- kept
as-is by decision D5b -- is the only way to see the rest of it."
  (cond
   (wide (concat " " (propertize " " 'display spec) "\n"))
   ((null spec) "  \n")
   (t (concat (propertize " " 'display (seshat-reader--multipage-align-to spec))
              (propertize " " 'display spec)
              "\n"))))

(defun seshat-reader--multipage-write-row (start spec &optional centered)
  "Write the display properties of the page row at START so it shows SPEC.

START is the first character of a row built by
`seshat-reader--multipage-page-row', so the row always has the two leading
characters this function writes to.  CENTERED non-nil gives the row the
`:align-to' centring space, nil leaves the image flush with the left edge.
A nil SPEC clears both properties, which is the placeholder state of a page
that is not rendered yet.  The buffer is written under `inhibit-read-only'
and left unmodified."
  (let ((inhibit-read-only t)
        (end (min (point-max) (+ start 2))))
    (if (null spec)
        (remove-text-properties start end '(display nil))
      (put-text-property start (1+ start) 'display
                         (and centered (seshat-reader--multipage-align-to spec)))
      (put-text-property (1+ start) end 'display spec))
    (set-buffer-modified-p nil)))

(defun seshat-reader--multipage-set-page-centered (page centered)
  "Centre the row of PAGE when CENTERED is non-nil, left align it otherwise.

Nothing is rebuilt: only the `display' property of the leading space of the
row is rewritten, so the row keeps its identity, its marker and the spec it
shows.  That in-place edit is what makes the frame that follows a resize
correct without re-rendering anything."
  (when-let* ((entry (assq page seshat-reader--pages))
              (start (marker-position (cadr entry))))
    (seshat-reader--multipage-write-row start (cddr entry) centered)))

(defun seshat-reader--multipage-page-centered-p (page)
  "Return non-nil when the row of PAGE is centred on its current spec.

The `:align-to' form has to reference the very spec object the row displays,
and the row has to display that object too -- by identity, not by `equal':
comparing multi-megabyte bitmaps by content on every redisplay hook entry
would be pointless.  A mismatch means the spec was replaced by a re-render,
or that the centring was cleared, and the row then counts as not centred."
  (when-let* ((entry (assq page seshat-reader--pages))
              (spec (cddr entry))
              (start (marker-position (cadr entry))))
    (let* ((guide (get-text-property start 'display))
           (align (and (consp guide) (eq (car guide) 'space)
                       (plist-get (cdr guide) :align-to)))
           (form (and (consp align) (eq (car align) '+) (nth 2 align)))
           (image (get-text-property (1+ start) 'display)))
      (and (consp form) (eq (cdr form) spec) (eq image spec) t))))

(defun seshat-reader--multipage-page-should-center-p (page &optional window)
  "Return non-nil when the row of PAGE fits the width of WINDOW.

PAGE is a 1-based page number and WINDOW defaults to the selected one.  A
page wider than the window is left aligned so that horizontal scrolling can
reach the rest of it, a page that fits is centred; that is the mechanical
form of decision D5's \"crop wide pages by width\".  Unknown geometry counts
as centred, which is what the placeholder rows of unrendered pages want."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (spec (seshat-reader--multipage-page-spec page))
         (width (and spec (image-property spec :width)))
         (window-width (window-body-width window t)))
    (or (not (numberp width)) (not (numberp window-width))
        (<= width window-width))))

(defun seshat-reader--multipage-page-numbers ()
  "Return the page numbers of every page row of the buffer, in buffer order.

The resident set is what the geometry works on: it is the viewport plus
`seshat-reader--multipage-preload' pages on each side, so a handful of pages
and never the whole document."
  (mapcar #'car seshat-reader--pages))

(defun seshat-reader--multipage-max-page-width ()
  "Return the width of the widest page row of the buffer, or nil.

The value comes from the specs the rows display, i.e. from the size they are
currently fitted to, which is what the horizontal scroll bound needs."
  (let ((widest nil))
    (dolist (entry seshat-reader--pages widest)
      (let ((width (and (cddr entry) (image-property (cddr entry) :width))))
        (when (and (numberp width) (or (null widest) (> width widest)))
          (setq widest width))))))

(defun seshat-reader--multipage-native-size (page)
  "Return the unscaled pixel size of PAGE as (W . H), or nil.

PAGE is a 1-based page number.  nil means the page has not been rendered
yet, so its native size is still unknown."
  (cdr (assq page seshat-reader--page-native-sizes)))

(defun seshat-reader--multipage-render-scale (page)
  "Return the scale the bitmap of PAGE was rendered at, or nil.

PAGE is a 1-based page number.  nil means the page has not been rendered
yet, which the refit treats as \"needs a render\"."
  (cdr (assq page seshat-reader--page-render-scales)))

(defun seshat-reader--multipage-record-native (page spec scale)
  "Record the native size of PAGE, measured on SPEC rendered at SCALE.

SPEC is the spec the native module returned for PAGE at SCALE, so dividing
its size by SCALE gives the size of the page at scale 1.0, which is what
every fit calculation needs (decision D5: no native interface required).
The scale the bitmap was rendered at is recorded as well, so that
`seshat-reader--multipage-refit-page' knows whether it has to render the
page again."
  (let ((width (and spec (image-property spec :width)))
        (height (and spec (image-property spec :height))))
    (when (and (integerp width) (> width 0)
               (integerp height) (> height 0)
               (numberp scale) (> scale 0))
      (setq seshat-reader--page-native-sizes
            (cons (cons page (cons (/ (float width) scale)
                                   (/ (float height) scale)))
                  (assq-delete-all page seshat-reader--page-native-sizes)))
      (setq seshat-reader--page-render-scales
            (cons (cons page scale)
                  (assq-delete-all page seshat-reader--page-render-scales))))))

(defun seshat-reader--multipage-forget-specs (page)
  "Drop every cached spec of PAGE so that the next request renders it again.

PAGE is a 1-based page number.  The spec the row currently displays is left
in place: the caller replaces it with the freshly rendered one, so the row
keeps its size in the meantime instead of collapsing."
  (setq seshat-reader--page-spec-cache
        (let (kept)
          (dolist (entry seshat-reader--page-spec-cache (nreverse kept))
            (unless (equal (car (car entry)) page)
              (push entry kept))))))

(defun seshat-reader--multipage-resize-spec (page &optional window)
  "Rewrite the spec of PAGE in place so that it matches its target scale.

PAGE is a 1-based page number and WINDOW defaults to the selected one.
Return non-nil when the size of the spec changed.  Nothing is rendered here:
only `:width' and `:height' of the spec are rewritten, which the next
redisplay picks up, and the centring space keeps following the new size
because `:align-to' references the spec object itself."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (spec (seshat-reader--multipage-page-spec page))
         (native (seshat-reader--multipage-native-size page))
         (target (seshat-reader--multipage-target-scale page window)))
    (when (and spec (consp native) target)
      (let* ((width (image-property spec :width))
             (height (image-property spec :height))
             (new-width (max 1 (round (* (car native) target))))
             (new-height (max 1 (round (* (cdr native) target)))))
        (unless (and (equal width new-width) (equal height new-height))
          ;; 不做 image-flush：拖动分割线时每帧 flush 会强制重解码整页位图
          ;; （实测卡 1–2s）；旧缓存由 C 侧下次重渲染替换 spec 时清掉。
          (setf (image-property spec :width) new-width)
          (setf (image-property spec :height) new-height)
          t)))))

(defun seshat-reader--multipage-page-spec (page)
  "Return the image spec recorded for PAGE, or nil when it has none.

PAGE is a 1-based page number.  nil means either that the page is not part
of the layout or that it is part of it but not rendered yet; callers that
must tell those two cases apart test `seshat-reader--pages' with `assq'."
  (cddr (assq page seshat-reader--pages)))

(defun seshat-reader--multipage-insert-page (page spec)
  "Insert the row of PAGE holding SPEC, keeping the layout sorted by page.

PAGE is a 1-based page number and SPEC is an image spec, or nil for a page
that is not rendered yet.  A page that already has a row only gets its
SPEC replaced and the function returns nil, so it is idempotent and can be
called on every scroll step.  A new row goes before the first row of a
greater page and at the end of the buffer when PAGE is greater than every
page present; the newline count from `seshat-reader-page-gap-lines' is
appended after the row.  The buffer is written under `inhibit-read-only'
and left unmodified, and the marker of the row is returned."
  (let ((entry (assq page seshat-reader--pages)))
    (if entry
        (let ((start (marker-position (cadr entry)))
              ;; 保持该页行当前的居中/贴左状态：换 spec 与换位置是两件事。
              (centered (seshat-reader--multipage-page-centered-p page)))
          (seshat-reader--multipage-write-row start spec centered)
          (setcdr (cdr entry) spec)
          nil)
      (let ((inhibit-read-only t)
            (start nil))
        ;; 页按页号升序存放，第一个页号更大的行就是插入点。
        (catch 'found
          (dolist (other seshat-reader--pages)
            (when (> (car other) page)
              (setq start (marker-position (cadr other)))
              (throw 'found t))))
        (save-excursion
          (goto-char (or start (point-max)))
          (let ((row-start (point)))
            (insert (seshat-reader--multipage-page-row spec))
            (dotimes (_ seshat-reader-page-gap-lines)
              (insert "\n"))
            ;; marker 在插入之后创建：位置 = 页行行首，插入类型 t 保证之后在
            ;; 行首前插入别的页时它随文本后移，仍指向自己的页行。
            (let ((marker (copy-marker row-start t)))
              (setq seshat-reader--pages
                    (sort (cons (cons page (cons marker spec))
                                seshat-reader--pages)
                          (lambda (a b) (< (car a) (car b)))))
              (set-buffer-modified-p nil)
              marker)))))))

(defun seshat-reader--multipage-remove-page (page)
  "Remove the row of PAGE and return the image spec it was displaying.

PAGE is a 1-based page number.  The row and the gap newlines that follow it
are deleted -- the deletion runs to the start of the next page row, or to
`point-max' for the last one, so it does not have to know the exact row
width.  The marker is detached with `set-marker' so that it cannot leak, and
the page is dropped from `seshat-reader--pages'.  The returned spec is the
one `seshat-reader--multipage-insert-page' was given for that page, or nil
when the page has no row or was not rendered; that is what the caller needs
in order to release the bitmap.  The buffer is written under
`inhibit-read-only' and left unmodified."
  (let ((entry (assq page seshat-reader--pages)))
    (when entry
      (let ((marker (cadr entry))
            (spec (cddr entry)))
        (let* ((inhibit-read-only t)
               (tail (memq entry seshat-reader--pages))
               (next (car (cdr tail)))
               (start (marker-position marker))
               (end (or (and next (marker-position (cadr next)))
                        (point-max))))
          (set-marker marker nil)
          (when (and start (>= end start))
            (delete-region start end)))
        (setq seshat-reader--pages (delq entry seshat-reader--pages))
        (unless seshat-reader--pages
          (setq seshat-reader--pages nil))
        (set-buffer-modified-p nil)
        spec))))

(defun seshat-reader--multipage-page-at-pos (pos)
  "Return the number of the page that contains POS, or nil.

POS inside a page row, at its line end or in the gap newlines that follow
it belongs to that page, so the answer only changes at the start of the
next row.  POS before the first page row, past the end of the buffer or in
a buffer without page rows returns nil."
  (when (and seshat-reader--pages
             (integer-or-marker-p pos)
             (<= pos (point-max)))
    (let ((page nil))
      (dolist (entry seshat-reader--pages)
        (when (<= (marker-position (cadr entry)) pos)
          (setq page (car entry))))
      page)))

(defun seshat-reader--multipage-visible-range (&optional window)
  "Return the pages to keep resident for WINDOW as a cons (FIRST . LAST).

WINDOW defaults to the selected window and must be a live window.  FIRST
and LAST are page numbers: the ones at `window-start' and `window-end',
widened by `seshat-reader--multipage-preload' pages in each direction and
clipped to the document pages, i.e. to 1 and the page count the native
module reports.  A document whose page count is still unknown is clipped
to the pages the buffer already holds, which is what keeps the very first
render of a buffer working.  The viewport counts as a single page when
`window-end' cannot be determined.  The value is nil when the buffer has
no page rows and no page count is known either."
  (when (or seshat-reader--pages
            (seshat-reader--multipage-pagecount))
    (let* ((win (or window (selected-window)))
           (first-page (or (seshat-reader--multipage-page-at-pos
                            (window-start win))
                           (and seshat-reader--pages
                                (car (car seshat-reader--pages)))
                           1))
           (last-page (or (when-let* ((end (window-end win t)))
                            (seshat-reader--multipage-page-at-pos end))
                          first-page))
           ;; 裁剪基准是文档页数（不是「已存在的页」），否则首次渲染后视口一旦
           ;; 移到尚未插入的页就会把范围算成空集。
           (highest (or (seshat-reader--multipage-pagecount)
                        (and seshat-reader--pages
                             (car (car (last seshat-reader--pages))))
                        first-page))
           (preload (max 0 seshat-reader--multipage-preload)))
      (cons (max 1 (- first-page preload))
            (min highest (+ (max first-page last-page) preload))))))

;;; Multi-page layout residency (P1 T1b)

;; The resident set is the pages the viewport shows plus
;; `seshat-reader--multipage-preload' pages on each side.  Rendering is
;; synchronous and one page costs a few milliseconds, so the set is kept
;; small on purpose: a page row is inserted when the viewport reaches it and
;; recycled as soon as it leaves the set.

(defvar-local seshat-reader--multipage-rotate 0
  "Rotation in degrees applied to every page row of this buffer.

One of 0, 90, 180 and 270.  The value is buffer-local because the pages are
not attached to a window any more: every window showing this buffer sees
the same rotation.  It is passed to the native per-page renderer through
`seshat-reader--page-spec'.")

(defvar-local seshat-reader--multipage-syncing nil
  "Non-nil while `seshat-reader--multipage-sync' is modifying the buffer.

Inserting or deleting a page row can report a window state change, which
runs `seshat-reader--ensure-window-layout' and would re-enter the sync.
The flag breaks that cycle.")

(defvar-local seshat-reader--multipage-last-range nil
  "Page range the resident set was last synchronised for, as (FIRST . LAST).

`seshat-reader--multipage-sync' returns immediately while the range asked
for is still this one, so the `post-command-hook' entry costs one range
computation per command instead of a full pass over the resident pages.")

(defun seshat-reader--multipage-pagecount ()
  "Return the number of pages of the loaded document, or nil.

The value comes from the buffer-local
`seshat-reader-current-doc-pagecount' the native module maintains.  A
missing or non-positive value is reported as nil, so callers can fall back
to the pages the buffer actually holds."
  (let ((count (bound-and-true-p seshat-reader-current-doc-pagecount)))
    (and (integerp count) (> count 0) count)))

(defun seshat-reader--multipage-clamp-page (page)
  "Return PAGE clamped into 1..PAGECOUNT, or nil when PAGE is unusable.

PAGE is a 1-based page number.  When the document page count is unknown the
value is only checked to be a positive integer."
  (when (and (integerp page) (> page 0))
    (let ((count (seshat-reader--multipage-pagecount)))
      (if count (max 1 (min count page)) page))))

(defun seshat-reader--multipage-clear ()
  "Drop every page row of the current buffer together with its marker.

The buffer text is left untouched; callers that want it gone erase the
buffer themselves, which is why this is separate from
`seshat-reader--multipage-remove-page'."
  (dolist (entry seshat-reader--pages)
    (when (markerp (cadr entry))
      (set-marker (cadr entry) nil)))
  (setq seshat-reader--pages nil
        seshat-reader--multipage-last-range nil))

(defun seshat-reader--multipage-render-page (page &optional force)
  "Make sure PAGE has a row displaying its image spec and return the spec.

PAGE is a 1-based page number.  A page without a row gets one built from
`seshat-reader--page-spec', a page whose row exists but carries no spec gets
the spec filled in, and an already rendered page is left alone, so calling
this on every scroll step is cheap.  FORCE non-nil renders the page again
even when its row already carries a spec, which is what a re-render at a new
resolution needs: the row keeps the spec object it had, so without FORCE the
early return would answer with the stale bitmap.

The page is rendered at its target scale
\(`seshat-reader--multipage-target-scale'), so a page that is scrolled into
view is sharp immediately instead of being rendered at 1.0 and stretched
afterwards.  Because the target scale needs the native size of the page,
which is only known after the first render, the very first render of a page
uses the base scale and the spec is then resized in place, without a second
render."
  (if (and (not force)
           (assq page seshat-reader--pages)
           (seshat-reader--multipage-page-spec page))
      (seshat-reader--multipage-page-spec page)
    (let* ((scale (seshat-reader--multipage-target-scale page))
           (spec (seshat-reader--page-spec
                  page scale seshat-reader--multipage-rotate)))
      (when spec
        (seshat-reader--multipage-record-native page spec scale))
      (seshat-reader--multipage-insert-page page spec)
      (when spec
        ;; native 尺寸已记录，目标 scale 可能因此变小（宽页在 contain/width 下
        ;; 按宽裁剪），这里只改 spec 尺寸，不重渲染。
        (seshat-reader--multipage-resize-spec page)
        (seshat-reader--multipage-set-page-centered
         page (seshat-reader--multipage-page-should-center-p page)))
      spec)))

(defun seshat-reader--multipage-rerender-page (page &optional window)
  "Render PAGE again at its target scale and update its row.

PAGE is a 1-based page number and WINDOW defaults to the selected one.  The
cached spec of the page is dropped first and the render is forced, so the
rows of a page whose bitmap became invalid -- dark mode inverted the
document, the page was rotated, the window was resized -- are rebuilt at the
resolution the current geometry asks for.  Nothing is done for a page
without a row."
  (when (assq page seshat-reader--pages)
    (seshat-reader--multipage-forget-specs page)
    (let ((spec (seshat-reader--multipage-render-page page t)))
      (when spec
        (seshat-reader--multipage-set-page-centered
         page (seshat-reader--multipage-page-should-center-p page window)))
      spec)))

(defun seshat-reader--multipage-refit-page (page &optional window)
  "Re-render PAGE when its bitmap resolution differs from its target scale.

PAGE is a 1-based page number and WINDOW defaults to the selected one.  The
geometry itself is adapted in place by `seshat-reader--multipage-resize-spec'
\(no pixels change), and the page is rendered again only when the scale its
bitmap was rendered at differs from the target, which is what makes the
visible pages sharp after a resize without ever rendering a page twice."
  (let ((target (seshat-reader--multipage-target-scale page window))
        (rendered (seshat-reader--multipage-render-scale page)))
    (unless (and (numberp target) (numberp rendered) (= target rendered))
      (seshat-reader--multipage-rerender-page page window))))

(defun seshat-reader--multipage-recycle-page (page)
  "Remove the row of PAGE and drop the cached spec of that page.

PAGE is a 1-based page number and the spec the row was displaying is
returned.  Dropping the cached spec is what actually releases the bitmap:
the row marker alone pins nothing, but the spec cache would keep the image
of a page nobody can see any more.  The recorded native size and render
scale are dropped too, so a page that comes back is measured again instead
of reusing a size that a rotation may have changed."
  (let ((spec (seshat-reader--multipage-remove-page page)))
    (when spec
      (seshat-reader--multipage-forget-specs page))
    (setq seshat-reader--page-native-sizes
          (assq-delete-all page seshat-reader--page-native-sizes)
          seshat-reader--page-render-scales
          (assq-delete-all page seshat-reader--page-render-scales))
    spec))

(defun seshat-reader--multipage-sync (&optional window)
  "Keep the resident page rows of WINDOW in sync with its viewport.

WINDOW defaults to the selected window.  The pages
`seshat-reader--multipage-visible-range' asks for are rendered when they
are missing and every page outside that range is recycled, so the buffer
only holds the visible pages plus the preload around them.  The range of
the previous run is remembered in `seshat-reader--multipage-last-range' and
an unchanged range returns at once, which keeps the `post-command-hook'
entry from redoing the work on every command.  Nothing is done while a sync
is already running, which is what stops a buffer modification made here
from re-entering through `window-state-change-functions'.  The range that
was synchronised is returned, or nil when there was nothing to do."
  (let* ((win (or window (selected-window)))
         (range (and (window-live-p win)
                     (not seshat-reader--multipage-syncing)
                     (eq (window-buffer win) (current-buffer))
                     (seshat-reader--multipage-visible-range win))))
    (when (and range (not (equal range seshat-reader--multipage-last-range)))
      (let ((seshat-reader--multipage-syncing t)
            (first (car range))
            (last (cdr range)))
        (setq seshat-reader--multipage-last-range range)
        (let ((page first))
          (while (<= page last)
            (seshat-reader--multipage-render-page page)
            (setq page (1+ page))))
        (dolist (entry (copy-sequence seshat-reader--pages))
          (let ((page (car entry)))
            (when (or (< page first) (> page last))
              (seshat-reader--multipage-recycle-page page)))))
      range)))

(defun seshat-reader--multipage--show-page (page)
  "Put the window start and point on the row of PAGE and return its position.

The position is read fresh from the row marker, so callers get a value that is
valid after the buffer was modified.  When the selected window does not show
the current buffer only point is moved, because `set-window-start' would
otherwise be applied to a buffer nobody asked about; nil is returned when
PAGE has no row."
  (when-let* ((entry (assq page seshat-reader--pages)))
    (let ((pos (marker-position (cadr entry))))
      (if (eq (window-buffer (selected-window)) (current-buffer))
          (with-selected-window (selected-window)
            (set-window-start (selected-window) pos)
            (goto-char pos))
        (goto-char pos))
      pos)))

(defun seshat-reader--multipage-goto (page)
  "Scroll the selected window to the row of PAGE and put point there.

PAGE is a 1-based page number and is clamped to the document; nil is
returned when no row can be shown.  The row of PAGE is rendered first, so
jumping outside the resident set works, and the pages around it are pulled
in afterwards by `seshat-reader--multipage-sync'.  The window is positioned
again after the sync, because the sync inserts or recycles rows in front of
the viewport: the markers follow the text, but a window start that sits at
`point-min' would be left before the freshly inserted rows.

The vertical scroll of the window is reset to 0, so a page jump always lands
on the top of the page: the scrolling commands
\(`seshat-reader--multipage-scroll') keep a pixel offset inside the page they
show, and that offset would otherwise be inherited by the target page.  The
buffer position of the row is returned."
  (let ((target (seshat-reader--multipage-clamp-page page)))
    (when target
      (seshat-reader--multipage-render-page target)
      (seshat-reader--multipage--show-page target)
      (seshat-reader--multipage-sync)
      (let ((pos (seshat-reader--multipage--show-page target)))
        ;; 页内滚动偏移不得被目标页继承：整页跳转一律停在页首。
        (when (eq (window-buffer (selected-window)) (current-buffer))
          (set-window-vscroll (selected-window) 0 t))
        pos))))

(defun seshat-reader--multipage-page-pixel-height (page)
  "Return the pixel height of the row of PAGE, or 0 when it has no image.

PAGE is a 1-based page number.  A placeholder row (a page whose render failed)
has no spec and therefore no height, which the scroll code treats as an empty
page rather than dividing by an unknown."
  (let ((spec (seshat-reader--multipage-page-spec page)))
    (or (and spec (image-property spec :height)) 0)))

(defun seshat-reader--default-line-pixels (&optional window)
  "Return the pixel height of a normal text line in WINDOW.

A page is one buffer line whose height is the whole page bitmap, so
`line-pixel-height' answers with the page height (2400px on a real frame) when
point is on a page row, and it must therefore never be used as \"one line\"
here: a scroll of one line would jump a whole page, which is exactly the bug
this function exists to prevent.

The height of a plain text line is the frame's character height instead: it is
independent of what is displayed on the current line, which is what the scroll
commands and the page gap need."
  (let ((frame (window-frame (if (window-live-p window) window
                               (selected-window)))))
    (max 1 (frame-char-height frame))))

(defun seshat-reader--multipage-page-gap-pixels (&optional window)
  "Return the pixel height of the gap lines that follow a page row.

The gap is `seshat-reader-page-gap-lines' empty lines, so their height is one
default line height each (`seshat-reader--default-line-pixels') — not
`line-pixel-height', which would report the height of the page row the gap
belongs to.  The value is 0 — the default configuration — when the option is 0.
WINDOW defaults to the selected one and is only used to find the frame."
  (let ((lines (max 0 seshat-reader-page-gap-lines)))
    (if (> lines 0) (* lines (seshat-reader--default-line-pixels window)) 0)))

(defun seshat-reader--multipage-page-span (page)
  "Return the pixel distance from the top of PAGE's row to the next row.

That is the page height plus the gap that follows it, floored at 1 so that the
scrolling loop always advances: a page without a rendered spec has a span of
0 pixels otherwise, and stepping through it would never move the target."
  (max 1 (+ (seshat-reader--multipage-page-pixel-height page)
            (seshat-reader--multipage-page-gap-pixels))))

(defun seshat-reader--multipage-page-max-offset (page)
  "Return the largest vertical scroll, in pixels, that PAGE allows.

One pixel less than the page height, so the page never scrolls completely off
the top of the window; 0 for a page without a rendered spec.  Clamping to this
value is what stops the scroll loop when there is no page left to cross."
  (max 0 (1- (seshat-reader--multipage-page-pixel-height page))))

(defun seshat-reader--multipage-page-neighbour (page delta)
  "Return the page DELTA pages away from PAGE, or nil when there is none.

DELTA is -1 or 1.  The result is clamped to the document, so the caller can
use a nil answer to stop scrolling at the first or the last page."
  (let ((target (seshat-reader--multipage-clamp-page (+ page delta))))
    (and target (/= target page) target)))

(defun seshat-reader--multipage--scroll-to-page (window page)
  "Put the row of PAGE at the top of WINDOW without touching its vscroll.

PAGE is a 1-based page number and the row is rendered first when it is not
resident yet, so scrolling into a page the resident set has not reached works.
`seshat-reader--multipage-goto' is not used on purpose: it resets the vertical
scroll, and the caller is about to set that scroll to the remainder of the
scrolling distance.  The row position is returned, or nil when PAGE has no row."
  (unless (assq page seshat-reader--pages)
    (seshat-reader--multipage-render-page page))
  (when-let* ((entry (assq page seshat-reader--pages))
              (pos (marker-position (cadr entry))))
    (set-window-start window pos)
    (when (eq (window-buffer window) (current-buffer))
      ;; 阅读 buffer 里 point 就是页面边框的落点，视口换页后要跟到页首。
      (with-selected-window window (goto-char pos)))
    pos))

(defun seshat-reader--multipage-scroll (pixels &optional window)
  "Scroll WINDOW vertically by PIXELS, continuing across page boundaries.

WINDOW defaults to the selected window.  A positive PIXELS scrolls the view
down (towards later pages), a negative one up.

Every page is one buffer line whose height is the page image, so the built-in
line scrolling (`scroll-up' / `scroll-down') jumps a whole page at a time and
makes in-page scrolling impossible.  This function therefore moves the window
in two steps: the vertical scroll of the window is used for the part of the
distance that stays inside the current page, and when the distance leaves the
page the window start is moved to the neighbouring page row and the remainder
becomes the new vertical scroll.  That is what makes the scrolling continuous:
reaching the bottom of a page continues into the next one instead of resetting.

The vertical scroll is always pixelwise (Emacs measures `window-vscroll' in
lines otherwise) and clamped to [0, height - 1] of the page at the top of the
window, so a page can never be scrolled past its own end and the clamp — not
the loop condition — is what stops at the first and the last page.  Every
iteration advances the page, so a page without a spec cannot loop forever.
The resident rows are synchronised afterwards, which pulls in the pages the
new viewport asks for."
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (and (eq (window-buffer win) (current-buffer))
               seshat-reader--pages
               (numberp pixels)
               (/= pixels 0))
      (let ((page (or (seshat-reader--multipage-page-at-pos (window-start win))
                      (car (car seshat-reader--pages))))
            (distance (+ (window-vscroll win t) pixels))
            (moved nil))
        (if (> pixels 0)
            ;; 向下：跨越整页时把该页的行高（+页后 gap）从距离里扣掉
            (while (and (>= distance (seshat-reader--multipage-page-span page))
                        (seshat-reader--multipage-page-neighbour page 1))
              (setq distance (- distance (seshat-reader--multipage-page-span page))
                    page (1+ page)
                    moved t)
              (unless (assq page seshat-reader--pages)
                (seshat-reader--multipage-render-page page)))
          ;; 向上：对称，补上上一页的行高（+gap）后才成为该页的页内偏移
          (while (and (< distance 0)
                      (seshat-reader--multipage-page-neighbour page -1))
            (setq page (1- page)
                  moved t)
            (unless (assq page seshat-reader--pages)
              (seshat-reader--multipage-render-page page))
            (setq distance (+ distance (seshat-reader--multipage-page-span page)))))
        (when moved
          (seshat-reader--multipage--scroll-to-page win page))
        (set-window-vscroll
         win (max 0 (min distance (seshat-reader--multipage-page-max-offset page))) t)
        (seshat-reader--multipage-sync win)
        (window-vscroll win t)))))

(defun seshat-reader--multipage-window-start-page (&optional window)
  "Return the number of the page shown at the top of WINDOW.

WINDOW defaults to the selected window.  nil is returned for a buffer
without page rows.  A window whose start is not inside a page row, and a
window showing some other buffer, count as showing the first page: that
keeps the derived page number inside the document instead of inventing
one."
  (when seshat-reader--pages
    (let* ((win (or window (selected-window)))
           (first (car (car seshat-reader--pages))))
      (if (eq (window-buffer win) (current-buffer))
          (or (seshat-reader--multipage-page-at-pos (window-start win))
              first)
        first))))

(defun seshat-reader--multipage--after-command ()
  "Refresh the resident page rows after a command moved the viewport.

Registered buffer-locally at the end of `post-command-hook'.  Errors are
swallowed: a `post-command-hook' entry that signals blocks every following
command, and the next scroll step simply retries the same work."
  (when (and (derived-mode-p 'seshat-reader-mode)
             (eq (window-buffer (selected-window)) (current-buffer)))
    (ignore-errors (seshat-reader--multipage-sync))))

(defun seshat-reader--multipage-relayout (&optional page)
  "Rebuild the page rows of the current buffer around PAGE.

PAGE defaults to the page at the top of the selected window, and the first
page is used when even that is unknown.  Every row is dropped, together with
the native sizes and render scales of the dropped pages -- a rotation swaps
the dimensions of a page, so a size measured before it must not be reused --
and the pages from PAGE minus the preload through PAGE plus the preload are
rendered again.  That is what a command that changes the rendering of every
page (rotation, dark mode) needs.  The window is left showing PAGE and every
row is placed according to the current geometry."
  (let* ((target (or (seshat-reader--multipage-clamp-page page)
                     (seshat-reader--multipage-clamp-page
                      (seshat-reader-current-doc-pagenumber))
                     1))
         (preload (max 0 seshat-reader--multipage-preload))
         (count (seshat-reader--multipage-pagecount))
         (first (max 1 (- target preload)))
         (last (if count (min count (+ target preload)) (+ target preload))))
    (let ((inhibit-read-only t))
      (erase-buffer))
    (seshat-reader--multipage-clear)
    (setq seshat-reader--page-native-sizes nil
          seshat-reader--page-render-scales nil)
    (let ((number first))
      (while (<= number last)
        (seshat-reader--multipage-render-page number)
        (setq number (1+ number))))
    (seshat-reader--multipage-goto target)
    (seshat-reader--center-page)))

(defun seshat-reader--multipage-c-overlay ()
  "Return the single-page overlay the native module attached to the buffer.

The overlay spans the whole buffer and carries a `win-state' property, which
is how it is recognised here: the `win-state' overlay property is the handle
of the native `EmacsWinState', and only this overlay has one.  Looking the
overlay up by property instead of by window parameter keeps the display code
free of the per-window state the multi-page layout does not use any more,
and it works for any window showing the buffer.  nil is returned when there
is no such overlay."
  (let (found)
    (dolist (overlay (overlays-in (point-min) (point-max)) found)
      (when (and (not found) (overlay-get overlay 'win-state))
        (setq found overlay)))))

(defun seshat-reader--multipage-drop-c-overlay (window)
  "Remove the single-page overlay the native module attached to the buffer.

That overlay spans the whole buffer and carries the image of one page in its
`display' property, so it would cover the multi-page layout and has to go
once the page rows take over.  It is closed through
`seshat-reader-dyn--window-close' rather than `delete-overlay' because the
native module owns an `EmacsWinState' behind it and only that entry point
releases it.  The window parameter of WINDOW is cleared either way, so that
no stale overlay handle survives the reload."
  (let ((overlay (seshat-reader--multipage-c-overlay)))
    (when (overlayp overlay)
      (ignore-errors (seshat-reader-dyn--window-close overlay)))
    (set-window-parameter window 'overlay nil)))

(defun seshat-reader--multipage-rotate-by (delta)
  "Rotate every page of the buffer by DELTA degrees.

DELTA is 90 or -90; the buffer-local rotation is kept in the 0..359 range,
and every cached spec is dropped because a rotated page has a different
bitmap and, for the quarter turns, swapped dimensions.  The rows are then
rebuilt around the page that is on screen, so the reader stays where it
was."
  (let ((page (seshat-reader-current-doc-pagenumber)))
    (setq seshat-reader--multipage-rotate
          (mod (+ (or seshat-reader--multipage-rotate 0) delta) 360))
    (ignore-errors (seshat-reader--page-spec-clear-cache))
    (seshat-reader--multipage-relayout page)
    (force-mode-line-update)))

(defun seshat-reader--ensure-window-layout (window)
  "Make WINDOW show the multi-page layout of the current buffer.

Registered buffer-locally on `window-state-change-functions', which is what
gives a new window, a resized window and a window that just switched to
this buffer their layout.  The window gets its starting fit mode recorded,
its resident pages synchronised and its rows centred for its own width --
a new window can be wider or narrower than the one the rows were placed
for.  When the window start is no longer inside a page row, the window is
moved to the nearest page row so that the page number derived from the
viewport stays meaningful."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'seshat-reader-mode)
        (unless (window-parameter window 'fit-mode)
          (set-window-parameter window 'fit-mode
                                (seshat-reader--initial-fit-mode window)))
        (unless seshat-reader--multipage-fit-mode
          (setq seshat-reader--multipage-fit-mode
                (seshat-reader--window-fit-mode window)))
        (seshat-reader--multipage-sync window)
        (when (and seshat-reader--pages
                   (not (seshat-reader--multipage-page-at-pos
                         (window-start window))))
          (when-let* ((entry (assq (seshat-reader--multipage-window-start-page
                                    window)
                                   seshat-reader--pages)))
            (set-window-start window (marker-position (cadr entry)))))
        (seshat-reader--ensure-centered window)))))

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

(defun seshat-reader--get-prefix-width (&optional _window)
  "Return the width of the line prefix that shifts a page to the right.

The value is always 0 now.  The single-page layout used to draw a
`line-prefix' of a computed width on an overlay, which is why every
horizontal scroll computation of this package counts columns relative to
that prefix; the multi-page layout centres a page with an `:align-to' space
that occupies no horizontal space of its own and left aligns an overwide
page, so there is no prefix left to compensate.  Keeping the accessor at 0
is what makes the calibration of `seshat-reader--set-window-hscroll' an
identity, i.e. what makes horizontal scrolling start at the left edge of an
overwide page.

Carrying a prefix here would silently invert every horizontal scroll
command: the calibration subtracts the prefix width, so a non-zero value
would move a page towards its right edge when the user asks for the left
one.  The scrollable margin itself is reported by
`seshat-reader--right-most-window-hscroll', which reads the widest page.

WINDOW is accepted for compatibility with the callers and is not used."
  0)

(defun seshat-reader--right-most-window-hscroll (&optional window)
  "Get the maximum horizontal scroll value for WINDOW.

The value is the width of the widest page row minus the pixel body width of
WINDOW, in columns, floored at 0; it is 0 while every page fits the window,
which is always the case in the `contain' and `width' modes because those
crop a wide page to the window width.  Returns 0 while no page has been
rendered yet: the image sizes are unknown then, and callers such as
`seshat-reader--set-window-hscroll' run during mode initialisation and must
not signal.

WINDOW must be a valid window and defaults to the selected one."
  (let* ((window (or window (selected-window)))
	 (image-width (seshat-reader--multipage-max-page-width))
	 (pixel-window-width (window-body-width window t))
	 (pixel-per-col (seshat-reader--get-pixel-per-col window)))
    (if (and (numberp image-width) (numberp pixel-per-col) (> pixel-per-col 0))
	(round (/ (max 0 (- image-width pixel-window-width))
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
  "Return non-nil when every page row of WINDOW is placed as geometry wants.

Every row has to be either centred on the spec it displays -- the leading
`:align-to' space references that very spec object -- or left aligned when
the page is wider than the window.  Comparing the placement with the current
geometry is what detects a re-render (which replaces the spec object) and a
resize (which changes which rows are too wide), so the repair happens once
and not on every redisplay.

A buffer without page rows counts as centred: there is nothing to place, and
reporting nil would make `seshat-reader--ensure-centered' rewrite the same
nothing on every hook entry."
  (let ((pages (seshat-reader--multipage-page-numbers))
        (centered t)
        (window (if (window-live-p window) window (selected-window))))
    (while (and pages centered)
      (let ((page (car pages)))
        (unless (eq (and (seshat-reader--multipage-page-centered-p page) t)
                    (and (seshat-reader--multipage-page-should-center-p
                          page window)
                         t))
          (setq centered nil)))
      (setq pages (cdr pages)))
    centered))

;; Centring is per page row: a row that fits is centred by an `:align-to'
;; space, a row that is wider than the window is left aligned so that the
;; horizontal scroll commands of this package can reach the rest of it
;; (decision D5b).  Both are plain text properties, so nothing has to be
;; rebuilt when the geometry changes.
(defun seshat-reader--center-page (&optional window)
  "Center the pages of WINDOW horizontally.

WINDOW must be a valid window and defaults to the selected one.

Every page row is placed according to its own width: a row that fits is
centred by delegating to redisplay -- its leading space carries
\\(space :align-to (+ center (-0.5 . IMAGE))), where IMAGE is the very spec
the row displays, so the position is computed at layout time and a resize is
honoured in the same redisplay, with no hook and no stale prefix frame.  A
row that is wider than WINDOW is left aligned instead and the horizontal
scroll machinery of this package brings the rest of it into view.

Working on every row is what makes several pages visible at once stay
centred: a page is never placed relative to the page above it.

When no page is wider than the window the horizontal scroll is reset, so a
page that used to overflow and now fits is not left scrolled."
  (let ((window (if (window-live-p window) window (selected-window)))
        (overflow nil))
    (when (eq (window-buffer window) (current-buffer))
      (dolist (page (seshat-reader--multipage-page-numbers))
        (let ((centered (seshat-reader--multipage-page-should-center-p
                         page window)))
          (unless centered
            (setq overflow t))
          (seshat-reader--multipage-set-page-centered page centered)))
      (unless overflow
        (ignore-errors (set-window-hscroll window 0))))))

(defun seshat-reader--ensure-centered (window)
  "Re-centre the page rows of WINDOW when their placement is stale.

With text-property centring the geometry itself needs no hook; this check
only repairs a row whose leading space still references the spec a
re-render has replaced, or whose placement no longer matches the window
width.  It is a no-op while `seshat-reader--centered-p' is satisfied."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (not (seshat-reader--centered-p window)))
    (seshat-reader--center-page window)
    t))

(defun seshat-reader--pre-redisplay-center (&optional _window)
  "Re-centre the page rows of the current buffer before it is redisplayed.

Registered buffer-locally on `pre-redisplay-functions'.  Without it the first
frames after a window resize are drawn with the placement computed for the
previous window width, because `window-size-change-functions' runs after that
redisplay; with it the frame that first shows the new width is already
centred.

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
  "Recentre WINDOW synchronously, without re-rendering the bitmaps.

The geometry of every page row is adapted in place -- the spec sizes follow
the target scale of each page and the rows are centred or left aligned
accordingly -- and the resident pages are synchronised afterwards, so the
frame produced by this very redisplay already shows the pages at their final
size and position.  Doing that work from the size-change hook is what keeps
the frame that noticed the size change from showing stale geometry.

The bitmaps are not rendered again here, because the C side renders
synchronously and redisplay cannot afford it: the resolution is upgraded by
the debounced refit (`seshat-reader--schedule-refit').

WINDOW is skipped silently when it is no longer live, no longer shows the
current buffer, or shows a buffer that has left `seshat-reader-mode'.  An
error while recentring one window is reported and does not prevent the other
windows from being recentred.

A burst of size changes (dragging a window divider) is detected by the
interval between them: such events only recentre the rows, so that no spec
is rewritten per frame, and the geometry is adapted once by the debounced
refit when the drag stops."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
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
                (unless dragging
                  (seshat-reader--apply-display-scale window)))
              (seshat-reader--center-page window)
              (seshat-reader--multipage-sync window))
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
  "Refit every page row of WINDOW to the current window size.

All the pages of the layout are handled, not only the one at the top: the
geometry is adapted in place first, which changes no pixels and needs no
rendering, and then every page whose bitmap was rendered at a different
scale is rendered again, so the visible pages get sharp without the geometry
moving.  The page rows are centred afterwards, because a page that got
cropped for its width has to stop being centred while a page that now fits
has to start.

The window is skipped silently when it is no longer live, no longer shows
the current buffer, or shows a buffer that has left `seshat-reader-mode'.  An
error while refitting one window is reported and does not prevent the other
windows from being refitted."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'seshat-reader-mode)
        (condition-case err
            (progn
              (seshat-reader--apply-display-scale window)
              (dolist (page (seshat-reader--multipage-page-numbers))
                (seshat-reader--multipage-refit-page page window))
              (seshat-reader--center-page window))
          (error
           (message "seshat-reader: resize refit skipped in %s: %S"
                    (buffer-name) err)))))))


;; Scrolling is pixel based, not line based: a page is one buffer line whose
;; height is the page image, so the built-in line scrolling (`scroll-up' /
;; `scroll-down' / `scroll-up-command') jumps a whole page per call and leaves
;; no way to scroll inside a page.  The commands below therefore ask
;; `seshat-reader--multipage-scroll' for a pixel distance, which moves the
;; window start to the neighbouring page row when the distance leaves the page
;; and keeps the remainder as the window's pixel vertical scroll.  Nothing
;; here turns a page: `n' / `p' stay on `seshat-reader--multipage-goto'.

(defun seshat-reader--scroll-line-pixels (&optional window)
  "Return the pixel height of one *text* line, the unit of a one-line scroll.

WINDOW defaults to the selected window.  This is deliberately not
`line-pixel-height': the line under point is a page row whose height is the
whole page bitmap, so a one-line scroll would move by a whole page — the bug
that made `j' turn pages.  `seshat-reader--default-line-pixels' returns the
frame's character height instead, which is what one line of scrolling means."
  (seshat-reader--default-line-pixels window))

(defun seshat-reader--scroll-screen-pixels (&optional window)
  "Return the pixel distance of one screen scroll of WINDOW.

WINDOW defaults to the selected window.  The distance is the pixel body height
of the window minus `next-screen-context-lines' default text lines, so a line
of context stays visible; it is clamped to at least one pixel so that a tiny
window still scrolls instead of doing nothing.  The context lines are measured
with `seshat-reader--default-line-pixels', never with `line-pixel-height',
which would answer with the height of the page row under point."
  (let ((window (if (window-live-p window) window (selected-window))))
    (max 1 (- (window-body-height window t)
              (* (max 0 next-screen-context-lines)
                 (seshat-reader--scroll-line-pixels window))))))

(defun seshat-reader-scroll-up (&optional amount)
  "Scroll the view upward by AMOUNT lines, one line by default.

The text moves down and the content above comes into view, one pixel line at a
time and continuously across the page boundary: a page is one buffer line, so
the built-in line scrolling would jump a whole page.
`seshat-reader--multipage-scroll' moves the view instead and synchronises the
resident page rows afterwards, so scrolling into a page that was not rendered
yet renders it on the spot."
  (interactive "p")
  (seshat-reader--multipage-scroll
   (- (* (or amount 1) (seshat-reader--scroll-line-pixels)))))

(defun seshat-reader-scroll-down (&optional amount)
  "Scroll the view downward by AMOUNT lines, one line by default.

The text moves up and the content below comes into view, continuously across
the page boundary, for the reason given in `seshat-reader-scroll-up'."
  (interactive "p")
  (seshat-reader--multipage-scroll
   (* (or amount 1) (seshat-reader--scroll-line-pixels))))

(defun seshat-reader-scroll-up-screen (&optional amount)
  "Scroll the view upward by one screen, or by AMOUNT lines.

One screen is the pixel body height of the window minus
`next-screen-context-lines' lines, so a line of context stays visible.
Switching pages stays on `n' / `p'."
  (interactive "P")
  (if amount
      (seshat-reader-scroll-up amount)
    (seshat-reader--multipage-scroll
     (- (seshat-reader--scroll-screen-pixels)))))

(defun seshat-reader-scroll-down-screen (&optional amount)
  "Scroll the view downward by one screen, or by AMOUNT lines.

One screen is the pixel body height of the window minus
`next-screen-context-lines' lines, so a line of context stays visible.
Switching pages stays on `n' / `p'."
  (interactive "P")
  (if amount
      (seshat-reader-scroll-down amount)
    (seshat-reader--multipage-scroll
     (seshat-reader--scroll-screen-pixels))))

(defun seshat-reader-scroll-left (&optional amount)
  "Scroll to the left of the current page by AMOUNT.

AMOUNT defaults to 1.

Only scrolls when the document page width is larger then the window width."
  (interactive "p")
  (or amount (setq amount 1))
  (when-let* (((< (window-body-width nil t) (or (seshat-reader--multipage-max-page-width) 0)))
	      (prev-scroll (seshat-reader--window-hscroll))
	      (hscroll (+ prev-scroll amount)))
    (- (seshat-reader--set-window-hscroll nil hscroll) prev-scroll)))

(defun seshat-reader-scroll-right (&optional amount)
  "Scroll to the right of the current page by AMOUNT (or 1).

Only scrolls when the document page width is larger then the window width."
  (interactive "p")
  (or amount (setq amount 1))
  (when-let* (((< (window-body-width nil t) (or (seshat-reader--multipage-max-page-width) 0)))
	      (prev-scroll (seshat-reader--window-hscroll))
	      (hscroll (- prev-scroll amount)))
    (- prev-scroll (seshat-reader--set-window-hscroll nil hscroll))))

(defun seshat-reader-scroll-left-most ()
  "Scroll to the left most point of the current page.

Only scrolls when the document page width is larger then the window width."
  (interactive)
  (when (< (window-body-width nil t) (or (seshat-reader--multipage-max-page-width) 0))
    (seshat-reader--set-window-hscroll nil 0)))

(defun seshat-reader-scroll-right-most ()
  "Scroll to the right most point of the current page.

Only scrolls when the document page width is larger then the window width."
  (interactive)
  (when (< (window-body-width nil t) (or (seshat-reader--multipage-max-page-width) 0))
    ;; We use `set-window-hscroll' here because we need to go the right
    ;; most point directly, bypassing `'seshat-reader--set-window-hscroll' checks.
    (set-window-hscroll nil (seshat-reader--right-most-window-hscroll))))

(define-queue-command scroll-up-or-prev-page (&optional amount)
  "Scroll the view upward by AMOUNT lines, one line by default.

The name is kept for the key bindings that predate the multi-page layout:
the command no longer turns the page, because scrolling itself is continuous
now and turning pages stays on `n' / `p'."
  (interactive "p")
  (seshat-reader-scroll-up amount))

(define-queue-command scroll-down-or-next-page (&optional amount)
  "Scroll the view downward by AMOUNT lines, one line by default.

The name is kept for the key bindings that predate the multi-page layout:
the command no longer turns the page, because scrolling itself is continuous
now and turning pages stays on `n' / `p'."
  (interactive "p")
  (seshat-reader-scroll-down amount))

(define-queue-command scroll-up-screen-or-prev-page ()
  "Scroll the view upward by one screen.

The name is kept for the key bindings that predate the multi-page layout:
the command no longer turns the page, because scrolling itself is continuous
now and turning pages stays on `n' / `p'."
  (interactive)
  (seshat-reader-scroll-up-screen))

(define-queue-command scroll-down-screen-or-next-page ()
  "Scroll the view downward by one screen.

The name is kept for the key bindings that predate the multi-page layout:
the command no longer turns the page, because scrolling itself is continuous
now and turning pages stays on `n' / `p'."
  (interactive)
  (seshat-reader-scroll-down-screen))

(define-queue-command mwheel-scroll-up (event)
  "Scroll the view up, but also handle mouse EVENT.

The wheel delta is read from the event: one line for a single notch and more
for a double or triple one.  See also `seshat-reader-scroll-up'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('wheel-up 1)
		   ('double-wheel-up 2)
		   ('triple-wheel-up 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-scroll-up amount))))

(define-queue-command mwheel-scroll-down (event)
  "Scroll the view down, but also handle mouse EVENT.

The wheel delta is read from the event: one line for a single notch and more
for a double or triple one.  See also `seshat-reader-scroll-down'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('wheel-down 1)
		   ('double-wheel-down 2)
		   ('triple-wheel-down 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-scroll-down amount))))

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
  "Rotate every page of the current document by 90 degrees, clockwise.

The rotation is buffer-local and is applied when a page is rendered, so the
rows around the page on screen are rebuilt at the new orientation."
  (interactive)
  (seshat-reader--multipage-rotate-by 90))

(defun seshat-reader-rotate-counter-clockwise ()
  "Rotate every page of the current document by 90 degrees, counter-clockwise.

The rotation is buffer-local and is applied when a page is rendered, so the
rows around the page on screen are rebuilt at the new orientation."
  (interactive)
  (seshat-reader--multipage-rotate-by -90))

(defun seshat-reader--clear-doc-memory ()
  "Clear document memory if we are in `seshat-reader-mode'.

Intended for use in `kill-buffer-hook'.  A refit that is still pending
for this buffer is cancelled as well, so that no timer survives the
buffer."
  (when (derived-mode-p 'seshat-reader-mode)
    (seshat-reader--cancel-pending-refit)
    ;; 关文档后位图（含装饰）全部失效，按页缓存的 spec 不能再复用。
    ;; 清理失败不得拦住关文档本身，故吞掉异常。
    (ignore-errors (seshat-reader--page-spec-clear-cache))
    (seshat-reader-dyn--close-doc)))
(add-hook 'kill-buffer-hook 'seshat-reader--clear-doc-memory nil t)

(defun seshat-reader-close-doc ()
  "Close the current document, also prompt the user for confirmation."
  (interactive)
  (when (yes-or-no-p "Are you sure you want to close the current document?")
    (kill-buffer (current-buffer))))

(defun seshat-reader--restore-display-on-quit (page _scale)
  "Reload the document with PAGE and rebuild the layout on quit.

Quit is deferred inside so the recovery cannot itself be interrupted.  The
scale is still part of the signature because the caller has it at hand, but
it is not applied: every page of the layout is rendered at scale 1.0 and
scaling comes back with a later batch."
  (with-local-quit
    (condition-case nil
        (progn
          (seshat-reader--render-buffer (1- page))
          (seshat-reader--center-page))
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
                (seshat-reader--center-page))
            ((quit error)
             (message "Reloading interrupted; restoring display...")
             (seshat-reader--restore-display-on-quit page scale)
             (signal (car err) (cdr err)))))
      (setq-local seshat-reader--reloading nil))))

(defun seshat-reader--render-buffer (&optional page)
  "Render the document file current buffer is associated with.
Load the PAGE if provided.

PAGE is a 0-based page index, which is what the native loader expects, and
defaults to the first page.  The document is loaded through
`seshat-reader-dyn--load-doc', which also attaches a whole-buffer overlay
displaying a single page; that overlay is closed again, because the pages are
displayed by the rows of the multi-page layout instead.  The buffer is then
emptied, the rows around PAGE are rendered and the window is left showing
PAGE."
  (interactive)
  (if-let* ((file (buffer-file-name (current-buffer))))
      (when (file-exists-p file)
	(let* ((p (if (numberp page) (max 0 page) 0))
	       (window (selected-window)))
	  (seshat-reader-dyn--load-doc file p)
	  ;; C 在建完 DocState 后总会挂一个覆盖全文、带单页图片的 overlay；它带着
	  ;; display 属性，会盖住整页布局。必须经 `--window-close' 释放（它同时
	  ;; 释放 C 侧的 EmacsWinState），直接 `delete-overlay' 会漏掉那份状态。
	  (seshat-reader--multipage-drop-c-overlay window)
	  ;; 页行由本函数重建，旧的页行/标记全部作废。
	  (let ((inhibit-read-only t))
	    (erase-buffer))
	  (seshat-reader--multipage-clear)
	  ;; 页面按 1.0 重画，窗口参数里的缩放与尺寸缓存全部复位。
	  (set-window-parameter window 'scale 1.0)
	  (set-window-parameter window 'render-scale nil)
	  (set-window-parameter window 'native-size nil)
	  ;; 按页的几何缓存随重载一起作废：native 尺寸与渲染 scale 都是上一份
	  ;; 文档的位图量出来的，缩放基准重新由 `--first-fit' 推导。
	  (setq seshat-reader--multipage-base-scale 1.0
	        seshat-reader--page-native-sizes nil
	        seshat-reader--page-render-scales nil)
	  ;; 位图随重载失效，按页缓存的 spec 不能再复用；清缓存失败不得中断重载。
	  (ignore-errors (seshat-reader--page-spec-clear-cache))
	  (let* ((target (or (seshat-reader--multipage-clamp-page (1+ p)) 1))
		 (preload (max 0 seshat-reader--multipage-preload))
		 (count (seshat-reader--multipage-pagecount))
		 (first (max 1 (- target preload)))
		 (last (if count (min count (+ target preload))
			 (+ target preload)))
		 (number first))
	    (while (<= number last)
	      (seshat-reader--multipage-render-page number)
	      (setq number (1+ number)))
	    (seshat-reader--multipage-goto target))
	  ;; 文档文本由原生模块生成，buffer 永远不是用户意义上的「已编辑」。
	  ;; `seshat-reader-dyn--load-doc' 重写全文后留下的 modified 标志必须清掉，
	  ;; 否则 revert 后 modeline 显示 **，super-save 等包会把重生成内容写回 PDF。
	  (set-buffer-modified-p nil)))
    (message "No file associated with buffer.")))

;; The layout keeps one buffer row per page and no per-window overlay, so the
;; window no longer owns any display state: every window showing this buffer
;; shows the same text and only differs in where it is scrolled to.  The
;; window state that is left is the fit mode (`fit-mode'), initialised by
;; `seshat-reader--ensure-window-layout', and the scale parameters the
;; geometry batch maintains.

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


;;; 键位预设

;; 前置声明：`seshat-reader--install-keymap-preset' 在定义它的 `defcustom' 之前
;; 引用该变量（`defcustom' 的 :set 必须指向已定义的函数，故 defcustom 只能排在
;; 函数之后），这里先声明一次让字节编译器知道它是 special variable；真正的
;; 默认值与 :set 钩子由下面的 `defcustom' 给出。
(defvar seshat-reader-keymap-preset 'vim
  "Keymap preset for `seshat-reader-mode-map'; see the `defcustom' below.")

(defconst seshat-reader--key-bindings-shared
  '(("t" . seshat-reader-translate-toggle)
    ("e" . seshat-reader-translate-explain-toggle)
    ("a" . seshat-reader-annotation-create)
    ("m" . seshat-reader-annotation-toggle)
    ("w" . seshat-reader-sidebar-toggle-width))
  "Bindings installed under every `seshat-reader-keymap-preset'.
The commands live in the extension modules, which may not be loaded yet:
storing the symbols in the keymap is safe (no funcall happens).")

(defconst seshat-reader--key-bindings-emacs-only
  '(("C-f" . seshat-reader-scroll-right)
    ("C-b" . seshat-reader-scroll-left)
    ("g"   . seshat-reader-refresh-doc-buffer))
  "Bindings installed when `seshat-reader-keymap-preset' is `emacs'.
This is the upstream reader semantics: the character-motion keys scroll
horizontally and the refresh key re-renders the current page.")

(defconst seshat-reader--key-bindings-vim-only
  '(("j"   . seshat-reader-scroll-down-or-next-page)
    ("k"   . seshat-reader-scroll-up-or-prev-page)
    ("h"   . seshat-reader-scroll-left)
    ("l"   . seshat-reader-scroll-right)
    ("^"   . seshat-reader-scroll-left-most)
    ("$"   . seshat-reader-scroll-right-most)
    ("g g" . seshat-reader-first-page)
    ("G"   . seshat-reader-last-page)
    ("C-l" . seshat-reader-refresh-doc-buffer)
    ("C-f" . seshat-reader-scroll-down-screen)
    ("C-b" . seshat-reader-scroll-up-screen)
    ("/"   . seshat-reader-search))
  "Bindings installed when `seshat-reader-keymap-preset' is `vim'.
The screen-scroll pair scrolls by a screen (vim semantics), \"g g\" jumps to
the first page and the vim refresh key re-renders it; \"/\" starts the
cross-page search.")

(defconst seshat-reader--preset-keys
  '("g" "C-f" "C-b" "C-l" "j" "k" "h" "l" "^" "$" "g g" "G"
    "t" "e" "a" "m" "w" "/")
  "Keys removed before a preset is (re)installed.
Unsetting \"g\" removes the whole prefix (including \"g g\"), which is what
the emacs preset needs.  No `<remap>' or wheel key is listed here, so those
bindings are never touched.")

(defun seshat-reader--install-keymap-preset (&optional preset)
  "Install PRESET bindings into `seshat-reader-mode-map'.
Idempotent: every key in `seshat-reader--preset-keys' is unset first, then
the shared and preset-specific tables are written.  The keymap is a mutable
shared object, so the change takes effect immediately in already-open
buffers; no `evil-normalize-keymaps' or keymap rebuild is needed."
  (let ((preset (or preset seshat-reader-keymap-preset 'vim)))
    (dolist (key seshat-reader--preset-keys)
      (keymap-unset seshat-reader-mode-map key))
    (dolist (entry seshat-reader--key-bindings-shared)
      (keymap-set seshat-reader-mode-map (car entry) (cdr entry)))
    (dolist (entry (if (eq preset 'emacs)
                       seshat-reader--key-bindings-emacs-only
                     seshat-reader--key-bindings-vim-only))
      (keymap-set seshat-reader-mode-map (car entry) (cdr entry)))))

(defun seshat-reader--set-keymap-preset (symbol value)
  "Customize setter for `seshat-reader-keymap-preset'.
Set SYMBOL's default to VALUE, then install the bindings for VALUE.
Must be defined BEFORE the defcustom that references it, because
`defcustom' funcalls its :set function while being evaluated."
  (set-default symbol value)
  (seshat-reader--install-keymap-preset value))

(defcustom seshat-reader-disable-evil t
  "Non-nil means turn evil off in every Seshat reader buffer.
The reader is read-only and its keys are defined by its own mode maps, so
evil's normal state only shadows them.  Set to nil to keep evil available."
  :type 'boolean
  :group 'seshat-reader)

(defcustom seshat-reader-screen-context-lines 1
  "Lines of overlap kept when scrolling by a screen.
Bound locally to `next-screen-context-lines' in reader buffers, which makes
\\[seshat-reader-scroll-down-screen] scroll by (window height - N) lines.
0 means a full screen with no overlap; 1 keeps one line of context."
  :type 'integer
  :group 'seshat-reader)

(defcustom seshat-reader-keymap-preset 'vim
  "Keymap preset for `seshat-reader-mode-map'.
`vim'   = the Emacs native bindings plus vim aliases (\"j\", \"k\", \"h\",
          \"l\", \"^\", \"$\", \"g g\", \"G\", \"/\"), with the screen-scroll
          commands on the character-motion keys.
`emacs' = upstream Emacs bindings only: the character-motion keys scroll
          horizontally and \"g\" refreshes the current page."
  :type '(choice (const :tag "vim" vim)
                 (const :tag "emacs" emacs))
  :group 'seshat-reader
  :set #'seshat-reader--set-keymap-preset)

;;; Evil 兼容（软依赖）

;; evil 是软依赖：本包不 require、不写进 Package-Requires；evil 不在时下面的
;; helper 全部是空操作（fboundp 守卫）。
;;
;; 阅读 buffer 是只读单页位图，evil 的 normal state 会经
;; `emulation-mode-map-alists' 压在本 mode 的键表之前，抢走 `down-mouse-1' 与
;; j / k / C-v。阅读系 major mode 因此设 `emacs' initial state；面板 buffer
;; 走 `seshat-reader--disable-evil' 直接关掉。
(declare-function evil-set-initial-state "evil" (mode state &optional keymap))

(defun seshat-reader--disable-evil ()
  "Turn evil off in the current buffer if `seshat-reader-disable-evil'.
That variable is non-nil by default; setting it to nil keeps evil available."
  (when (and seshat-reader-disable-evil
             (fboundp 'evil-local-mode)
             (bound-and-true-p evil-local-mode))
    (evil-local-mode -1)))

(defun seshat-reader--disable-evil-in-existing-buffers ()
  "Apply `seshat-reader--disable-evil' to already-open reader and panel buffers.
Needed because evil may be loaded AFTER this package (the user's
`init-evil.el' is a `use-package' :config block, so its load order is not
guaranteed): buffers opened before evil is up would otherwise be pulled into
normal state when evil turns on."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (or (derived-mode-p 'seshat-reader-mode)
                (derived-mode-p 'seshat-reader-outline-mode)
                (derived-mode-p 'seshat-reader-annotation-list-mode)
                (bound-and-true-p seshat-reader-translate-panel-mode))
        (seshat-reader--disable-evil)))))

(defun seshat-reader--evil-set-initial-states ()
  "Put the Seshat reader modes into evil's `emacs' state.
evil is a globalized minor mode and re-enables itself after the mode body
has run, so `seshat-reader--disable-evil' alone does not stick.  An `emacs'
initial state keeps `down-mouse-1', j/k and the screen-scroll keys with the
mode maps."
  (when (fboundp 'evil-set-initial-state)
    (dolist (mode '(seshat-reader-mode seshat-reading-mode
                    seshat-reader-outline-mode
                    seshat-reader-annotation-list-mode))
      (evil-set-initial-state mode 'emacs))))

(with-eval-after-load 'evil
  (seshat-reader--evil-set-initial-states)
  (seshat-reader--disable-evil-in-existing-buffers))

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
  (seshat-reader--disable-evil)
  (setq-local next-screen-context-lines
              (max 0 seshat-reader-screen-context-lines))
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
  ;; 多页布局下窗口不再拥有显示状态：新窗口、尺寸变化与「换成本 buffer」都由
  ;; `window-state-change-functions' 承接，它按窗口补齐可见页并初始化 fit-mode。
  ;; 因此不再需要 `window-configuration-change-hook' 与
  ;; `window-buffer-change-functions'：没有 per-window overlay 可建可删。
  (add-hook 'window-state-change-functions #'seshat-reader--ensure-window-layout nil t)
  (add-hook 'pre-redisplay-functions #'seshat-reader--pre-redisplay-center nil t)
  ;; 滚动后补齐可见页。追加到末尾（DEPTH 传 t），不与命令队列的
  ;; `--process-command-queue' 抢顺序；先 remove 再 add，重复进 mode 不累积副本。
  (remove-hook 'post-command-hook #'seshat-reader--multipage--after-command t)
  (add-hook 'post-command-hook #'seshat-reader--multipage--after-command t t))

(defun seshat-reader--page-indicator ()
  "返回 `[当前页/总页]' 形式的字符串，供 mode-line 显示.
当前页取 `seshat-reader-current-doc-pagenumber'（多页布局下由视口顶页派生），
总页数取 buffer-local 变量 `seshat-reader-current-doc-pagecount'（由动态模块
设置）；任一取不到（文档尚未加载完）时该项用 `?' 占位，不报错、不阻塞
redisplay。"
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
	      '(" P" (:eval (let ((page (seshat-reader-current-doc-pagenumber)))
			      (or (and (integerp page)
				       (number-to-string page))
				  "?")))
                "/" (:eval (let ((count (bound-and-true-p
					 seshat-reader-current-doc-pagecount)))
			     (or (and (integerp count)
				      (number-to-string count))
				 "?")))))
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
  "Re-render the page rows of the current buffer and re-centre its windows.

The pages of the multi-page layout are not attached to a window, so the
bitmaps are rebuilt once for the whole buffer -- that is what a document-wide
change such as dark mode needs -- and every window showing the buffer is then
synchronised, refitted to its own size and re-centred.  A window showing
another buffer is left alone."
  (ignore-errors (seshat-reader--page-spec-clear-cache))
  (dolist (page (seshat-reader--multipage-page-numbers))
    (seshat-reader--multipage-rerender-page page))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (with-selected-window window
      (seshat-reader--multipage-sync window)
      (seshat-reader--apply-display-scale window)
      (seshat-reader--center-page window)))
  (force-mode-line-update))

(define-minor-mode seshat-reader-dark-mode
  "Toggle dark-mode for current seshat-reader document.

The inversion happens in the native module, at document level, so every page
bitmap becomes stale at once: the spec cache is dropped and the resident
pages are rendered again by `seshat-reader--redisplay-all-windows'.  The
pages are not inverted on the Lisp side, which is what keeps the highlights
painted into the bitmap by the native module consistent."
  :lighter " Dark"
  (when (derived-mode-p 'seshat-reader-mode)
    (seshat-reader-dyn--doc-invert (if seshat-reader-dark-mode 1 0))
    (seshat-reader--redisplay-all-windows)))

(defvar-local seshat-reader--presentation-state nil
  "Zoom and fit mode the buffer had before presentation view was entered.

A cons (FIT-MODE . BASE-SCALE).  Both are restored on exit, so leaving the
presentation view returns to the zoom the reader was opened with instead of
keeping the height fitting: re-deriving the base scale from the current fit
mode would keep the scale presentation view had set, because the reference
page no longer has its original size by then.")

(define-minor-mode seshat-reader-presentation-mode
  "Toggle presentation view for current seshat-reader document.

Presentation view keeps the existing semantics: the mode line is hidden and
every page is fitted to the window height.  In the multi-page layout that
naturally means \"about one page per screen\", without a second layout of its
own (decision 4).

The fit mode and the base scale the buffer had are remembered on entry and
restored on exit, together with the mode line, so leaving the presentation
view puts the pages back where they were."
  :lighter ""
  (when (derived-mode-p 'seshat-reader-mode)
    (cond (seshat-reader-presentation-mode
           (setq seshat-reader--presentation-state
                 (cons (seshat-reader--multipage-current-fit-mode)
                       (or seshat-reader--multipage-base-scale 1.0)))
	   (setq-local mode-line-format nil)
	   (seshat-reader-fit-to-height))
	  (t
           (kill-local-variable 'mode-line-format)
           (let* ((state seshat-reader--presentation-state)
                  (mode (or (car-safe state)
                            (seshat-reader--window-fit-mode)))
                  (scale (or (cdr-safe state)
                             (seshat-reader--fit-scale))))
             (setq seshat-reader--presentation-state nil)
             (set-window-parameter nil 'fit-mode mode)
             (seshat-reader--multipage-set-scale scale 'fit mode))))))

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
