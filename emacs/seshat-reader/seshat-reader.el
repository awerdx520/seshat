;;; seshat-reader.el --- General-purpose Document Reader -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026  Divya Ranjan Pattanaik
;; Copyright (C) 2025-2026  Tushar

;; Author: Divya Ranjan Pattanaik <divya@subvertising.org>
;; Keywords: lisp, files, tools
;; Version: 0.3.2
;; Package-Requires: ((emacs "32.0"))
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
;; FORMAT is mandatory since Emacs 30 -- pass it explicitly instead of the
;; old (with-demoted-errors BODY) form, which byte-compile warns about.
(with-demoted-errors "seshat-render-core: %S"
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

(defcustom seshat-reader-freeze-layout-during-minibuffer t
  "Non-nil means keep the page layout frozen while the minibuffer is open.

This is a pure UX switch, not a correctness one: the page geometry is never
computed from the minibuffer window (see
`seshat-reader--multipage--display-window'), so the pages stay correct either
way.  What it removes is the flicker of a layout that shrinks while a prompt
\(`M-x', `find-file', a bookmark jump) is open and grows back afterwards.

The price is cropping: an expanded minibuffer takes about 400 px (17 rows)
out of a 1275 px reader window, and a frozen page keeps the 1275 px height it
was laid out for, so roughly 416 px at the bottom are cut off by the window
while the prompt is open.  Nothing is lost -- the refit that
`seshat-reader--after-minibuffer-exit' schedules puts the layout back as soon
as the minibuffer is closed.

Set it to nil to let the pages follow the shrinking window again."
  :group 'seshat-reader
  :type 'boolean)

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
`seshat-reader--multipage-page-spec')."
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

;; 前置声明：真值在多页布局一节定义（`defvar-local'），这里先声明让字节编译器
;; 知道它是 special variable（`defvar' 不设值，不会覆盖后面的默认值）。
(defvar seshat-reader--multipage-base-scale)

(defun seshat-reader-current-doc-scale-value (&optional window)
  "Scaling factor of the current document, as shown in WINDOW.

WINDOW defaults to the selected one and is only a hint: since P1 the zoom is a
**buffer level** value (`seshat-reader--multipage-base-scale'), because every
window showing the document displays the same page rows at the same scale.
The window parameter `scale' is a compatibility mirror (written by
`seshat-reader--multipage-set-scale' for every window that shows the buffer),
and it is only consulted while the buffer holds no page row yet -- during
startup, or in a buffer that never rendered a document.

Reading the buffer value first is what keeps a **second** window correct
after the user zooms the first one: its own `scale' parameter may be stale,
and a stale mirror would make the selection geometry (which divides by this
value) return coordinates off by the ratio of the two scales."
  (or (and seshat-reader--pages seshat-reader--multipage-base-scale)
      (window-parameter window 'scale)
      seshat-reader--recent-scale-fallback))

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

(defvar-local seshat-reader--multipage-reference-native nil
  "Native pixel size (W . H) of the reference page, or nil when unknown.

Set by `seshat-reader--first-fit' from the page the document is opened on,
i.e. the first page (decision D5: the whole document is scaled from the first
page and never from the page that happens to be on screen).

Remembering the size instead of re-reading the page is what keeps `W' / `H' /
`0' deterministic: `seshat-reader--multipage-recycle-page' drops the measured
size of a page that leaves the resident set, so re-deriving the reference size
from `seshat-reader--page-native-sizes' would silently fall back to page 1.0
after the user scrolled away.  It is cleared when the document is reloaded or
the pages are rotated, because both change the native size.")

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

(defun seshat-reader--multipage-align-to (source)
  "Return the display value that centres a page row SOURCE wide.

SOURCE is either the image spec the row displays or, for a row whose pixels
have not been delivered yet, the pixel width of the page.  Either way the
value is a zero-width `space' display specification whose `:align-to' form is
the sum of `center' and half of SOURCE, so redisplay puts what follows in the
middle of the window and recomputes the position on every frame -- a window
resize is honoured in the same redisplay, with no hook and no stale prefix.

A spec is referenced by identity on purpose: rewriting its `:width' in place
with `seshat-reader--multipage-resize-spec' makes the centring follow the new
size without touching the row.  A number is wrapped as `(WIDTH)' first,
because a bare number inside a display specification is read as multiples of
the frame font and not as pixels: both spellings then resolve to the same
pixels, so a placeholder row is centred exactly where the rendered row it
becomes will be."
  (list 'space :align-to
        (list '+ 'center
              (cons -0.5 (if (numberp source) (list source) source)))))

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

(defun seshat-reader--multipage-set-scale (base &optional source mode)
  "Display every page row at BASE scale, synchronously and sharply.

BASE becomes the buffer local base scale, so every page keeps the same zoom
factor and no page is cropped for its own width (decision D5: the manual
`+' / `-' zoom never crops).  SOURCE, when non-nil, is recorded as the scale
source of the selected window (`fit' or `manual'); MODE, when non-nil,
replaces the buffer local fit mode.

The order is the one every zoom command needs, and it is what makes one
keypress produce a finished frame:

  1. clamp BASE into the range the native renderer can draw
     (`seshat-reader--multipage-clamp-scale');
  2. `seshat-reader--apply-display-scale' -- rewrite the `:width'/`:height' of
     every resident spec in place, so the geometry is final without touching a
     bitmap;
  3. `seshat-reader--center-page' -- re-place every row for its new width;
  4. `seshat-reader--multipage-refit-page' for every resident page -- render
     the pages whose bitmap resolution no longer matches the target, once each;
  5. `seshat-reader--multipage-sync' -- pull in the pages the viewport now
     asks for (they are rendered straight at the target scale).

The refit is synchronous on purpose: zooming and opening a document are user
actions that may block for a few milliseconds per page (0.7-11 ms measured),
whereas leaving the bitmap stretched until an idle timer fires shows a blurry
page for as long as the user keeps typing.  BASE is returned."
  (let ((base (seshat-reader--multipage-clamp-scale base))
        (window (selected-window)))
    (setq seshat-reader--multipage-base-scale base)
    (when mode
      (setq seshat-reader--multipage-fit-mode mode))
    (setq seshat-reader--recent-scale-fallback base)
    ;; `scale' 是兼容镜像：所有显示本 buffer 的窗口都写一遍，避免别的模块
    ;; （选区 / 书签 / 旧调用点）从另一个窗口读到 stale 值。真值仍是上面的
    ;; buffer-local `--multipage-base-scale'。
    (dolist (win (get-buffer-window-list (current-buffer) nil t))
      (set-window-parameter win 'scale base))
    (set-window-parameter window 'scale base)
    (when source
      (set-window-parameter window 'scale-source source))
    (seshat-reader--apply-display-scale window)
    (seshat-reader--center-page window)
    (dolist (page (seshat-reader--multipage-page-numbers))
      (seshat-reader--multipage-refit-page page window))
    (seshat-reader--multipage-sync window)
    base))

(defun seshat-reader--multipage-base-fit-scale (mode &optional window)
  "Return the base scale that a document-wide fit MODE implies.

MODE is `contain', `width', `height' or `manual' and WINDOW defaults to the
selected one.  The scale is computed from the *reference* page -- the one the
document was opened on, whose native size is remembered in
`seshat-reader--multipage-reference-native' -- and the window size, exactly the
way `seshat-reader--multipage-fit-scale' does it for a single page:

  `contain'  min (width fit, height fit)
  `width'    width fit
  `height'   height fit
  `manual'   the current base scale (a manual zoom has no fit of its own)

Anchoring on the remembered size is what keeps `W' / `H' / `0' deterministic:
the measured size of a page is dropped when it leaves the resident set, so
re-deriving the reference size from the page on screen would fall back to 1.0
after the user scrolled away.  When even the reference size is unknown (the
document was not fitted yet) the top page is used as a last resort, and nil is
returned when neither is measurable -- the callers then keep their current
scale instead of jumping to an arbitrary one."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (native (or seshat-reader--multipage-reference-native
                     (seshat-reader--multipage-native-size
                      (or (seshat-reader--multipage-window-start-page window) 1))))
         (width (car-safe native))
         (height (cdr-safe native)))
    (if (eq mode 'manual)
        (or seshat-reader--multipage-base-scale 1.0)
      (when (and (numberp width) (> width 0) (numberp height) (> height 0))
        (let ((window-width (window-body-width window t))
              (window-height (window-body-height window t)))
          (when (and (numberp window-width) (> window-width 0)
                     (numberp window-height) (> window-height 0))
            (let ((width-fit (/ (float window-width) width))
                  (height-fit (/ (float window-height) height)))
              (pcase mode
                ('width width-fit)
                ('height height-fit)
                (_ (min width-fit height-fit))))))))))

(defun seshat-reader--multipage-zoom (factor &optional source)
  "Multiply the base scale of the buffer by FACTOR and return the new scale.

FACTOR is a multiplier, not an absolute scale, which is what decision D5 asks
for: `+' / `-' keep zooming relative to the scale the document was opened
with, so the same number of keypresses always ends at the same zoom.  SOURCE
defaults to `manual' and is recorded as the scale source of the window."
  (seshat-reader--multipage-set-scale
   (* (or seshat-reader--multipage-base-scale 1.0) (or factor 1.0))
   (or source 'manual)
   'manual))

(defun seshat-reader-enlarge-size (&optional factor)
  "Zoom in by FACTOR, `seshat-reader-enlarge-factor' by default.

FACTOR multiplies the current base scale, so 20 presses of `+' end at
\\(enlarge-factor)^20 times the opening scale (clamped by
`seshat-reader--multipage-set-scale').  The visible pages are re-rendered
synchronously, so the page is sharp as soon as the command returns."
  (interactive (list seshat-reader-enlarge-factor))
  (seshat-reader--multipage-zoom (or factor seshat-reader-enlarge-factor) 'manual))

(defun seshat-reader-shrink-size (&optional factor)
  "Zoom out by FACTOR, `seshat-reader-shrink-factor' by default.

FACTOR multiplies the current base scale, mirroring
`seshat-reader-enlarge-size'; the visible pages are re-rendered synchronously."
  (interactive (list seshat-reader-shrink-factor))
  (seshat-reader--multipage-zoom (or factor seshat-reader-shrink-factor) 'manual))

(defun seshat-reader-reset-size ()
  "Drop the manual zoom and re-fit the document the way it was opened.

The base scale goes back to the fit of the reference page under
`seshat-reader--initial-fit-mode' -- the same scale `seshat-reader--first-fit'
would have computed -- and the fit mode returns to that mode, so `0' really
means \"start over\" instead of \"scale 1.0\".

The zoom command is re-rendered synchronously, like every other zoom."
  (interactive)
  (let* ((window (selected-window))
         (mode (seshat-reader--initial-fit-mode))
         (scale (or (seshat-reader--multipage-base-fit-scale mode window) 1.0)))
    (set-window-parameter window 'fit-mode mode)
    (seshat-reader--multipage-set-scale scale 'fit mode)))

(defun seshat-reader-fit-to-height ()
  "Fit every page to the window height and keep it sharp.

The base scale is the height fit of the *reference* page (the one the document
was opened on), and the fit mode becomes `height'; every page is then rendered
at that scale, so the frame that follows is already sharp.

The page is scaled on both dimensions, so a wide page overflows horizontally
and is left aligned; horizontal scrolling brings the rest into view.  That is
the pre-existing `fit-to-height' semantics, kept as it is by decision D5
\(`height' is the one mode that is allowed to overflow)."
  (interactive)
  (let* ((window (selected-window))
         (scale (or (seshat-reader--multipage-base-fit-scale 'height window) 1.0)))
    (set-window-parameter window 'fit-mode 'height)
    (seshat-reader--multipage-set-scale scale 'fit 'height)))

(defun seshat-reader-fit-to-width ()
  "Fit every page to the window width and keep it sharp.

The base scale is the width fit of the *reference* page, and the fit mode
becomes `width'; every page is then rendered at that scale.

Every page is fitted to its own width, so pages of different widths all end
up exactly as wide as the window and none of them overflows (decision D5,
`width' mode)."
  (interactive)
  (let* ((window (selected-window))
         (scale (or (seshat-reader--multipage-base-fit-scale 'width window) 1.0)))
    (set-window-parameter window 'fit-mode 'width)
    (seshat-reader--multipage-set-scale scale 'fit 'width)))

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

The base scale is derived from the native size of the page the document is
opened on -- remembered in `seshat-reader--multipage-reference-native', which
is what `W' / `H' / `0' later re-derive from -- and the window size, under the
window's initial fit mode (`seshat-reader--initial-fit-mode'), which is
recorded first so that later resizes keep using it.  That base scale is then
fixed for the whole document (decision D5: the reference page is the first one
and it never follows the scroll position).

The rows were rendered at the base scale of `seshat-reader--render-buffer'
\(1.0) before this function runs, so their specs are resized in place and then
every resident page is reconciled once with
`seshat-reader--multipage-refit-page': the pages whose bitmap resolution does
not match the new target are rendered again.  That costs one render per page
\(0.7-11 ms measured, i.e. a few dozen milliseconds for the resident set) and
buys a first frame that is already sharp, instead of a stretched bitmap that
only the idle refit would fix.  Never rendering twice is what keeps the call
cheap: a page that is already at the target scale is skipped.

Nothing is done in a buffer without page rows."
  (let* ((window (selected-window))
         (mode (seshat-reader--initial-fit-mode))
         (page (or (seshat-reader--multipage-window-start-page window) 1)))
    (set-window-parameter window 'fit-mode mode)
    (setq seshat-reader--multipage-fit-mode mode)
    ;; 基准页的 native 尺寸在此刻测量（此后它可能被回收，见该变量的 docstring）。
    (setq seshat-reader--multipage-reference-native
          (seshat-reader--multipage-native-size page))
    (when-let* ((scale (seshat-reader--multipage-base-fit-scale mode window)))
      (setq seshat-reader--multipage-base-scale
            (seshat-reader--multipage-clamp-scale scale)))
    (seshat-reader--apply-display-scale window)
    (seshat-reader--center-page window)
    (dolist (page (seshat-reader--multipage-page-numbers))
      (seshat-reader--multipage-refit-page page window))
    (seshat-reader--center-page window)))

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
still gets the `seshat-reader-default-fit' behaviour.

WINDOW defaults to the window displaying this buffer
\(`seshat-reader--multipage--display-window'), which is never a minibuffer
window.  When no window displays the buffer the answer is the buffer local
mode alone and may be nil: a window's fit mode only means something for the
window being fitted, and the callers treat nil as \"geometry unknown\"."
  (let ((window (seshat-reader--multipage--display-window window)))
    (or seshat-reader--multipage-fit-mode
        (and window (seshat-reader--window-fit-mode window)))))

(defun seshat-reader--multipage-fit-scale (page mode &optional window)
  "Return the scale at which PAGE fits WINDOW under fit MODE.

PAGE is a 1-based page number, MODE is one of `contain', `width' and
`height', and WINDOW defaults to the window displaying this buffer
\(`seshat-reader--multipage--display-window'), never to a minibuffer window.
The native size of PAGE (`seshat-reader--page-native-sizes') is what makes
this page-based: a page only ever needed to fit on its own dimensions, which
is what gives `contain' its `min (base scale, width fit)' shape through
`seshat-reader--multipage-target-scale'.

nil is returned while the native size of PAGE is unknown, i.e. before the
page has been rendered once, and also when no window displays the buffer:
there is no geometry to fit the page to, and measuring the minibuffer window
instead (102 px high) produced a 0.25 scaled strip."
  (let* ((window (seshat-reader--multipage--display-window window))
         (native (seshat-reader--multipage-native-size page))
         (width (car-safe native))
         (height (cdr-safe native)))
    (when (and window
               (numberp width) (> width 0) (numberp height) (> height 0))
      (let ((window-width (window-body-width window t))
            (window-height (window-body-height window t)))
        (let ((width-fit (and (numberp window-width) (> window-width 0)
                              (/ (float window-width) width)))
              (height-fit (and (numberp window-height) (> window-height 0)
                               (/ (float window-height) height))))
          (pcase mode
            ('width width-fit)
            ('height height-fit)
            (_ (and width-fit height-fit (min width-fit height-fit)))))))))

(defun seshat-reader--multipage--display-window (&optional window)
  "Return the window whose geometry the page layout of this buffer follows.

WINDOW is used when it is a live window that is not a minibuffer window and
that displays the current buffer.  Otherwise the window `get-buffer-window'
finds for the current buffer is used, then the selected window, both under
the same conditions, and nil is returned when none of them qualifies -- which
is how the fit calculations learn that the geometry is unknown instead of
measuring an unrelated window.

A minibuffer window is never returned, whatever its buffer happens to be.
While the minibuffer is active `(selected-window)' *is* the mini window, so
resolving \"the selected window\" there means fitting the page to a 102 px
high strip (four text lines): the height fit came out as 102 / 792 = 0.1288,
the clamp raised it to its 0.25 floor and a 612x792 page was rewritten to a
153x198 sliver.  The check is `window-minibuffer-p', a structural property of
the window, so recursive minibuffers and child frame minibuffers are covered
as well; a window whose buffer is `*Minibuf-N*' is skipped by the same test
that skips the mini window itself, because `(window-buffer MINIWINDOW)' is
exactly that buffer.

WINDOW being nil is not an error: it means \"resolve it for me\"."
  (catch 'seshat-reader--display-window
    ;; 三个候选按可信度排序：显式入参 → 显示本 buffer 的窗口 → 选中窗口。
    ;; 任一候选不满足「活窗口 + 非 minibuffer 窗口 + 显示本 buffer」就跳过，
    ;; 全部不符合时返回 nil（调用方必须把 nil 当作「几何未知」处理）。
    (dolist (candidate (list window
                             (get-buffer-window (current-buffer) t)
                             (selected-window)))
      (when (and (windowp candidate)
                 (window-live-p candidate)
                 (not (window-minibuffer-p candidate))
                 (eq (window-buffer candidate) (current-buffer)))
        (throw 'seshat-reader--display-window candidate)))))

(defun seshat-reader--multipage-target-scale (page &optional window)
  "Return the scale PAGE should be displayed at in WINDOW.

PAGE is a 1-based page number and WINDOW defaults to the window displaying
this buffer (`seshat-reader--multipage--display-window'), which is never a
minibuffer window.  The mode comes from
`seshat-reader--multipage-current-fit-mode' and the table is the one decision
D5 fixes:

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
scale is returned, which is what the first render of a page uses.

The base scale is returned as well when no window displays the buffer, i.e.
when even the selected window is a minibuffer window: there is no geometry to
compute a fit from, and the fallback must stay in the fit calculation rather
than in the window resolution, because a nil window cannot be measured at
all (`window-body-width' would signal)."
  (let* ((window (seshat-reader--multipage--display-window window))
         (base (or seshat-reader--multipage-base-scale 1.0)))
    (if (null window)
        ;; 中文：解析不出窗口（minibuffer 激活即此情形）＝几何未知，只报基准
        ;; scale。必须先返回，绝不能落到下面的 `window-body-width'（nil 会报错）。
        (seshat-reader--multipage-clamp-scale base)
      (let* ((mode (seshat-reader--multipage-current-fit-mode window))
             (native (seshat-reader--multipage-native-size page))
             (width (car-safe native))
             (window-width (window-body-width window t))
             (width-fit (and (numberp width) (> width 0)
                             (numberp window-width) (> window-width 0)
                             (/ (float window-width) width))))
        (seshat-reader--multipage-clamp-scale
         (pcase mode
           ('width (or width-fit base))
           ('height (or (seshat-reader--multipage-fit-scale page 'height window)
                        base))
           ('manual base)
           (_ (min base (or width-fit base)))))))))

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

Nothing is flushed here, and there is nothing to flush: a canvas spec has no
flush semantics.  The `:data-width'/`:data-height' properties and the pixels
of the canvas buffer are written exactly once, by the renderer that fills the
buffer, while `:width' and `:height' are the pair that may be `setf'ed at any
time.  Rewriting that pair alone is enough for the new geometry to take
effect, so a size change costs one relayout instead of a re-render of the
whole page bitmap -- which is what keeps dragging a window divider from
stalling."
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
;; as long as one page rasterization takes, so it is only exposed for explicit
;; measurement.  Nothing in the display, redisplay or scrolling paths may call
;; it directly: the multi-page layout renders through the wrapper below.

;; 前置声明：这两个变量属于多页布局一节（定义在下方），但缓存上限与清缓存函数
;; 先用到它们（`defvar' 不设值，不覆盖后面的 `defvar-local' 默认值），先声明让
;; 字节编译器知道它们是 special variable。
(defvar seshat-reader--multipage-preload)
(defvar seshat-reader--multipage-memory-warned)

(defconst seshat-reader--multipage-preload-max 3
  "Hard ceiling for `seshat-reader--multipage-preload', in pages per side.

Two pages each side is already more than one screen of slack on a normal
frame, and every extra page costs a row plus a cached spec (each holding a
Lisp copy of the bitmap), so the residency would grow linearly with no gain.
The clamp is internal on purpose: `seshat-reader--multipage-preload' stays a
plain defvar (no new user option), and a configuration that raises it is
silently bounded by `seshat-reader--multipage-effective-preload'.")

(defun seshat-reader--multipage-effective-preload ()
  "Return the preload actually used, clamped to [0 `-preload-max']."
  (min seshat-reader--multipage-preload-max
       (max 0 seshat-reader--multipage-preload)))


(defvar seshat-reader--page-spec-cache-limit 8
  "Hard ceiling for `seshat-reader--page-spec-cache', and a knob to lower it.

Each entry holds one rendered page, and its pixels live only in the canvas
buffer that Emacs owns (`:data-width' x `:data-height' x 4 bytes); the Lisp
side holds no copy of the bitmap, since the canvas backend stores it as an
opaque object instead of the `:data' string the pbm backend used, and the
native `CachedPage' cache is gone (removed in the 2026-10-28 canvas
migration).  One cache entry therefore costs exactly one canvas buffer.

The effective size is the smallest of this value,
`seshat-reader--multipage-cache-limit' (derived from the resident set) and 16
\(the ceiling registered in `decisions.md'): the cache may never grow past what
memory allows, so raising `seshat-reader--multipage-preload' must not raise it
past 16 either.")

(defvar-local seshat-reader--page-spec-cache nil
  "Buffer-local cache of per-page image specs, newest entry first.

Each element is a cons cell (KEY . SPEC).  KEY is the normalized list
\(PAGE SCALE ROTATE), as built by `seshat-reader--page-spec-key', and SPEC
is the image spec the native module returned for it.  At most
`seshat-reader--multipage-cache-limit' entries are kept; entries whose page is
outside the resident set are dropped first (see
`seshat-reader--page-spec-eviction-victim').")

(defvar-local seshat-reader--multipage-page-sizes nil
  "Buffer-local cache of per-page display sizes, newest entry first.

Each element is a cons cell (KEY . (WIDTH . HEIGHT)), where KEY is the very
key `seshat-reader--page-spec-key' builds for the spec cache -- (PAGE SCALE
ROTATE) -- so the two caches can never disagree about what \"the same
request\" means.  The limit and the eviction order come from the spec cache
as well (`seshat-reader--multipage-cache-limit' and
`seshat-reader--cache-eviction-victim'): there is one policy, used twice.

WIDTH and HEIGHT are the pixels the page occupies on screen at that scale,
i.e. the same numbers a rendered spec reports in `:width'/`:height', filled
from `seshat-reader-dyn--page-size' which measures the page bounds and
rasterizes nothing.  Keeping them next to (and independent of) the specs is
what lets a page row take the exact image height before the pixels exist.

Unlike the specs, these entries also survive a single-page recycle: see
`seshat-reader--multipage-forget-specs' for why that is load bearing.")

(defvar-local seshat-reader--multipage-render-generation 0
  "Generation counter of the two-phase multi-page render, per buffer.

A render started asynchronously (idle pass, periodic timer) records this
number when it is queued and compares it against the current value before it
writes anything back: cache entry, size entry or row pixels.  A mismatch means
the geometry changed while the pixels were in flight, so the result is of the
old generation and must be dropped instead of painted (decision D4) -- that is
what keeps a stale bitmap from a previous scale, tint or document out of the
layout.

The counter is bumped in exactly one place,
`seshat-reader--page-spec-clear-cache', i.e. only a **full** invalidation
starts a new generation.  See that function for why the single-page
`seshat-reader--multipage-forget-specs' must never bump it.

It is 0 in a fresh buffer; callers compare with
`seshat-reader--multipage-generation-current-p' rather than testing the number
itself.")

(defvar-local seshat-reader--multipage-render-failures nil
  "Per-page render failure counts of the current buffer, as an alist.

Each element is (PAGE . COUNT) with PAGE a 1-based page number, so a count
talks about a page and not about one specific request.  **Why the page and
not the (PAGE SCALE ROTATE) key the two caches use**: the tick re-derives the
scale from `seshat-reader--multipage-target-scale' every pass, and the first
render of a page is the one that records its native size, after which the
fit scale moves (a wide page is cropped by width).  A count keyed by the full
request would therefore restart at 1 whenever that happened, and the
\"give up after 3 failures\" guard would never fire for exactly the pages it
exists for (the ones the renderer keeps rejecting).  The invariant still says
\"the same page failed three times\", it is only measured per page.

T5 fills and reads this table: a page whose render keeps returning nil stops
being queued for the asynchronous pass, and the count is cleared in the two
places the invariant asks for -- a generation change
\(`seshat-reader--page-spec-clear-cache', which empties the whole table) and
the page becoming visible again
\(`seshat-reader--multipage-reset-render-failure', which T6 calls per visible
page; without it a transient failure would become permanent for the buffer as
soon as the reader scrolled away and back, because plain scrolling does not
advance the generation).")

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

(defun seshat-reader--multipage-cache-limit ()
  "Return how many page specs may be cached at once, given the resident set.

The resident set is the viewport plus `seshat-reader--multipage-preload' pages
on each side, so one spec per resident page plus one page of slack on each side
is enough: `2 * preload + 2` -- 6 with the default preload of 2, which is the
\"at most 6 resident specs\" budget of decision D4, and never below 4.

Two hard bounds apply on top: `seshat-reader--page-spec-cache-limit' (the knob
P0 measured) and 16 (the ceiling registered in `decisions.md', because every
entry pins a Lisp copy of the bitmap while the native module keeps its own).

The 16 is a **historical** hard ceiling: since the preload is clamped to
`seshat-reader--multipage-preload-max' (3, see m5 of the P1 review) the formula
tops out at `2 * 3 + 2 = 8`, so 16 can never be the binding bound today.  It is
kept as a guard for the day the preload ceiling is raised -- without it, a
larger preload would silently multiply the pinned bitmaps.
The smallest of the three wins, so a configuration that raises the preload
cannot push the cache past what memory allows."
  (min 16
       (max 0 seshat-reader--page-spec-cache-limit)
       (max 4 (+ (* 2 (seshat-reader--multipage-effective-preload)) 2))))

(defun seshat-reader--multipage-resident-page-range ()
  "Return the pages the layout currently holds, as a cons (FIRST . LAST).

The rows are kept sorted by page, so the first and the last row give the range
the viewport is allowed to draw from.  nil is returned when the buffer has no
page row at all, which is what makes the cache fall back to plain FIFO and the
recycle keep no spec.

This is the **cross distance** of the row table, not the resident set: the rows
are kept for the union of every window showing the buffer (decision D1), so the
span covers the pages between two windows as well.  It is no longer used as the
prefetch boundary -- `seshat-reader--multipage-prefetch' takes the calling
window's own range (decision D5) -- but it still describes \"the pages the
layout holds\" for the callers that want exactly that (the cache limit derived
from the resident set and the no-window fallback of
`seshat-reader--multipage-resident-pages')."
  (when seshat-reader--pages
    (cons (car (car seshat-reader--pages))
          (car (car (last seshat-reader--pages))))))

(defun seshat-reader--multipage-spec-cached-p (page)
  "Return non-nil when the cache holds any spec of PAGE, at any scale.

PAGE is a 1-based page number.  The prefetch uses this to avoid re-rendering a
page that is already cached under another scale or rotation; any entry of the
page counts, because a cached bitmap of the page is what makes the render cheap
\(the native module keeps the decoded page around as well)."
  (let ((entries seshat-reader--page-spec-cache)
        (found nil))
    (while (and entries (not found))
      (when (equal (car (car (car entries))) page)
        (setq found t))
      (setq entries (cdr entries)))
    found))

(defun seshat-reader--cache-eviction-victim (entries)
  "Return the entry of ENTRIES to drop when a page cache is over its limit.

ENTRIES is a page cache list, newest entry first, i.e. the shape of both
`seshat-reader--page-spec-cache' and `seshat-reader--multipage-page-sizes'.
Entries whose page is outside the resident set go first, oldest of them first:
the reader cannot see those pages any more, so their bitmaps are worth less
than the ones on screen.  When every entry belongs to a resident page the
oldest entry is dropped, which is the plain FIFO behaviour of P0.

The resident set is the union of what every window on the buffer shows
\(`seshat-reader--multipage-resident-pages', decision D4), not the cross
distance between the first and the last row: with two windows far apart, the
pages between them are on screen nowhere.

There is **no boundary slack here**, unlike
`seshat-reader--multipage-page-near-resident-p', which also accepts the pages
one step outside the set.  The two functions keep the boundary they always had
and only changed the source of the set:

- near-resident decides whether a recycled page keeps its bitmap, and a page
  one step away is exactly the page the way back needs;
- this function decides what to throw away, and a page one step outside the set
  is the page about to be seen -- counting it as resident would postpone its
  eviction, push the cache peak up (against the memory budget) and make the
  eviction timing differ from the single-window baseline for no gain.

Both caches evict through this one function, so the spec cache and the size
cache stay in step as the viewport moves and neither grows a policy of its
own."
  (let ((pages (seshat-reader--multipage-resident-pages))
        (victim nil))
    (dolist (entry entries)
      (let ((page (car (car entry))))
        (unless (memq page pages)
          ;; The list is newest first: the last match is the oldest match.
          (setq victim entry))))
    (or victim (car (last entries)))))

(defun seshat-reader--page-spec-eviction-victim ()
  "Return the spec cache entry to drop when the cache is over its limit.

The rule itself lives in `seshat-reader--cache-eviction-victim', which the
size cache shares."
  (seshat-reader--cache-eviction-victim seshat-reader--page-spec-cache))

(defun seshat-reader--page-spec-remember (key spec &optional generation)
  "Cache SPEC under KEY, dropping entries above `--multipage-cache-limit'.

The list is kept newest first.  Entries of pages that left the resident set are
evicted before the entries of pages still on screen (see
`seshat-reader--page-spec-eviction-victim'), which is what keeps a viewport's
worth of bitmaps alive while the reader scrolls: P0's plain FIFO cache with a
fixed limit of 8 scored a 0% hit rate while scanning 20 pages, because the page
that was just scrolled away was the first one to be dropped.

GENERATION is the render generation SPEC was produced in, or nil for \"do not
check\" -- which is what every synchronous caller passes, so a two-argument
call behaves exactly as before.  A non-nil GENERATION that no longer matches
`seshat-reader--multipage-render-generation' means the geometry changed while
SPEC was in flight: nothing is cached then and nil is returned, so the
asynchronous caller (T5) learns that its result was dropped instead of pinning
a stale bitmap into the layout (decision D4)."
  (if (and generation
           (not (seshat-reader--multipage-generation-current-p generation)))
      nil
    (push (cons key spec) seshat-reader--page-spec-cache)
    (let ((limit (seshat-reader--multipage-cache-limit)))
      (while (> (length seshat-reader--page-spec-cache) limit)
        (let ((victim (seshat-reader--page-spec-eviction-victim)))
          (if victim
              (setq seshat-reader--page-spec-cache
                    (delq victim seshat-reader--page-spec-cache))
            ;; No victim means the cache is empty, i.e. the limit is 0; stop
            ;; rather than spin.
            (setq seshat-reader--page-spec-cache nil)))))
    seshat-reader--page-spec-cache))

(defun seshat-reader--multipage-page-size-remember (key size &optional generation)
  "Cache SIZE under KEY, dropping entries above `--multipage-cache-limit'.

KEY is the normalized (PAGE SCALE ROTATE) list built by
`seshat-reader--page-spec-key' and SIZE is the cons (WIDTH . HEIGHT) the
native module reported.  The list is kept newest first and is trimmed by
`seshat-reader--cache-eviction-victim', i.e. with the very limit and the very
policy `seshat-reader--page-spec-remember' uses -- the two caches are one
budget spent on two kinds of entry, never two policies.

GENERATION has the meaning it has in `seshat-reader--page-spec-remember' -- nil
means \"do not check\", so the synchronous callers are unaffected, and a stale
generation drops SIZE instead of caching a size measured for a geometry that no
longer exists."
  (if (and generation
           (not (seshat-reader--multipage-generation-current-p generation)))
      nil
    (push (cons key size) seshat-reader--multipage-page-sizes)
    (let ((limit (seshat-reader--multipage-cache-limit)))
      (while (> (length seshat-reader--multipage-page-sizes) limit)
        (let ((victim (seshat-reader--cache-eviction-victim
                       seshat-reader--multipage-page-sizes)))
          (if victim
              (setq seshat-reader--multipage-page-sizes
                    (delq victim seshat-reader--multipage-page-sizes))
            ;; No victim means the cache is empty, i.e. the limit is 0; stop
            ;; rather than spin.
            (setq seshat-reader--multipage-page-sizes nil)))))
    seshat-reader--multipage-page-sizes))

(defun seshat-reader--page-spec (page &optional scale rotate generation)
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
file working with an older `seshat-render-core'.

GENERATION is the render generation the request was issued in, or nil for
\"do not check\" -- which is what every synchronous caller passes, so a
three-argument call behaves exactly as before.  It is forwarded to
`seshat-reader--page-spec-remember', i.e. a freshly rendered spec is cached
only while GENERATION is still current, and nil is returned when it is not:
the asynchronous tick (T5) then learns that its result belongs to a geometry
which no longer exists instead of painting it (decision D4).  A cache hit
needs no check at all, because `seshat-reader--page-spec-clear-cache' -- the
only place the generation advances -- empties the cache as well."
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
            ;; 代际校验落在这唯一一处写入：`--page-spec-remember' 在代际已变
            ;; 时不缓存并返回 nil，于是这里也返回 nil（作废，而不是「失败」）。
            (if (seshat-reader--page-spec-remember key spec generation)
                spec
              nil)))))))

(defun seshat-reader--page-size (page scale &optional rotate)
  "Return the display size of PAGE at SCALE and ROTATE, as (WIDTH HEIGHT).

PAGE is 1-based; SCALE and ROTATE mean what they mean for
`seshat-reader--page-spec'.  The result is in the logical pixels a rendered
spec reports in `:width'/`:height', so a page row can take the image's exact
height before the pixels exist (decision D2), and nil when the size is
unknown: out-of-range page, invalid arguments, document being reloaded, or a
module that predates the `seshat-reader-dyn--page-size' entry point.

Nothing is rendered here.  The size is measured from the page bounds by the
native entry point, which builds no display list and allocates no pixels, so
this is the cheap synchronous half of the two-phase render -- the whole point
of the split is that a scroll step may call it for every page it needs.

Sizes are cached in `seshat-reader--multipage-page-sizes' under the key
`seshat-reader--page-spec-key' builds, i.e. the very key of the spec cache,
and only a miss reaches the native module; a hit costs one `assoc'.  A
failure is never cached: nil may be transient (reload in progress, missing
entry point) and caching it would make that transient state permanent for the
buffer, the same reasoning D7 applies to pending pages.  Callers decide what
a nil means for them; this function only reports it."
  (when (fboundp 'seshat-reader-dyn--page-size)
    (let* ((key (seshat-reader--page-spec-key page scale rotate))
           (cached (assoc key seshat-reader--multipage-page-sizes)))
      (if cached
          (list (car (cdr cached)) (cdr (cdr cached)))
        ;; The normalized key doubles as the argument list, so the scale and
        ;; rotate defaults are applied in exactly one place (same trick as
        ;; `seshat-reader--page-spec').
        (let* ((result (ignore-errors
                         (seshat-reader-dyn--page-size
                          page (nth 1 key) (nth 2 key))))
               ;; The entry point returns (WIDTH HEIGHT); accepting a cons as
               ;; well keeps this wrapper from breaking on a module that
               ;; reports the pair dotted.
               (width (car-safe result))
               (height (car-safe (cdr-safe result))))
          (when (and (integerp width) (> width 0)
                     (integerp height) (> height 0))
            (seshat-reader--multipage-page-size-remember
             key (cons width height))
            (list width height)))))))

(defun seshat-reader--page-spec-clear-cache ()
  "Drop every cached per-page image spec of the current buffer.

Called when the cached specs become stale: the document is closed
\(`seshat-reader--clear-doc-memory') or re-rendered
\(`seshat-reader--render-buffer'), where the page bitmaps and the
decorations painted into them are rebuilt from scratch.

The size cache `seshat-reader--multipage-page-sizes' is dropped with it, and
this is the only place sizes are dropped: a size is valid only for the
geometry it was measured at, and every caller of this function -- rotate,
close, reload, `seshat-reader--redisplay-all-windows' -- changes that
geometry wholesale.  Single-page invalidation deliberately keeps the sizes
instead (see `seshat-reader--multipage-forget-specs').

This is also the **only** place the render generation is bumped, and the only
place the per-page failure counts of
`seshat-reader--multipage-render-failures' are cleared.  Why the generation is
bumped here and *not* in `seshat-reader--multipage-forget-specs' (do not
\"simplify\" this by moving it): `--multipage-forget-specs' is single-page and
is called by `seshat-reader--multipage-recycle-page' every time a page leaves
the resident set.  Bumping the generation there would mean \"recycling any far
page invalidates every in-flight pending render\" -- while scrolling
continuously the idle pass would then be voided over and over and the queue
would fall back to the timeout's forced synchronous render, which is exactly
the cost this plan exists to remove (review finding N1).  Full invalidation
bumps the generation; a recycle or a single-page re-render does not.

The memory warning is re-armed as well: a reloaded document starts from an
empty cache, so the budget is worth reporting again if it is exceeded again."
  (setq seshat-reader--multipage-render-generation
        (1+ seshat-reader--multipage-render-generation)
        seshat-reader--page-spec-cache nil
        seshat-reader--multipage-page-sizes nil
        ;; T5 使用：失败计数只在「全量失效」与「该页重新可见」两处清零。
        seshat-reader--multipage-render-failures nil
        seshat-reader--multipage-memory-warned nil))

(defun seshat-reader--multipage-generation-current-p (generation)
  "Return non-nil when GENERATION is the current render generation.

GENERATION is the number a render recorded when it was queued (see
`seshat-reader--multipage-render-generation'); nil means \"no generation
recorded\" and never matches, so a caller with a missing number drops its
result instead of guessing.  This is the one comparison every asynchronous
write-back does -- cache entry (`seshat-reader--page-spec-remember'), size
entry (`seshat-reader--multipage-page-size-remember') and the eventual row
fill of T5 -- so the rule lives in one function instead of being respelled as
`(eq gen ...)' in each of them."
  (and (integerp generation)
       (= generation seshat-reader--multipage-render-generation)))

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

(defcustom seshat-reader-page-separator t
  "When non-nil, insert a separator region after every page row.

The region is a rule that spans the whole window width plus the blank space
that balances it above and below, see `seshat-reader-page-separator-height'.
Turning this option off together with `seshat-reader-page-gap-lines' set to 0
brings back the layout where two consecutive pages touch each other.

The option is read while a page row is inserted, i.e. when the layout is
built or reordered, so it applies to the layouts created afterwards and not
to the rows a buffer already holds."
  :group 'seshat-reader
  :type 'boolean)

(defcustom seshat-reader-page-separator-height 0.5
  "Total height of the separator region, in default text lines.

The value may be fractional: 0.5 is half a line and covers the rule together
with the blank space above and below it, the three of them.  0 makes the
region take no space at all.  How that total is split is decided by
`seshat-reader-page-separator-thickness', see
`seshat-reader--multipage-separator-segments'."
  :group 'seshat-reader
  :type 'number)

(defcustom seshat-reader-page-separator-thickness 2
  "Thickness of the separator rule, in pixels.

The rule is a background-coloured stretch space, and neither a 1px image nor
a shrunk face renders thinner than about 2px on a real font frame, which is
why 2 is the default.  Larger values make the rule thicker; the value is
clamped to the total height of the region."
  :group 'seshat-reader
  :type 'integer)

(defface seshat-reader-page-separator-face
  '((t :background "gray70"))
  "Face whose colour the page separator rule takes.

Only the colour is taken from it: the rule is a stretch space spanning the
window width, and its height comes from the separator geometry, see
`seshat-reader-page-separator-height'.  A darker colour such as \"gray40\"
suits a dark theme."
  :group 'seshat-reader)

(defcustom seshat-reader-multipage-memory-warning-mb 75
  "Warn when the resident page bitmaps exceed this many megabytes.

The estimate sums `:data-width' x `:data-height' x 4 bytes, i.e. one ARGB32
pixel per device pixel of the canvas buffer that Emacs owns; it does not
double the figure, because the pixels exist only in that buffer (no Lisp-side
copy of the bitmap is pinned any more).  Specs without `:data-width' /
`:data-height' fall back to `:width' x `:height' x 4, which counts logical
pixels and so under-estimates on a frame whose scale factor is not 1.0.  With
the default preload the cache holds at most 6 specs, i.e. roughly 75 MB at
150 dpi; a document whose pages are much larger, or a configuration that
raises the preload, can cross that line and the message says so once per
buffer instead of on every scroll.

Set it to nil to disable the warning."
  :group 'seshat-reader
  :type '(choice (const :tag "Do not warn" nil) (number :tag "Megabytes")))

(defcustom seshat-reader-render-idle-delay 0.05
  "Interval of the asynchronous render pass, in seconds.

One number, two jobs: it is the delay of the idle timer that starts the
first pass once Emacs has been quiet that long, and the period of the
repeating timer that carries the queue on afterwards.  The idle timer is
started with a nil REPEAT on purpose -- an idle timer fires once per idle
window in a daemon Emacs (batch 0, probe G3b: one pulse was measured, no
re-arm without new input), so it cannot drive a queue; the periodic timer is
the only reliable source of further passes.  See
`seshat-reader--schedule-async-render'.

0.05 s is 20 passes per second, which is far more than a page render per pass
needs (one pass renders up to `seshat-reader-render-idle-batch' pages of a few
milliseconds each) while keeping the delay between a scroll and the pixels of
the page it revealed imperceptible."
  :group 'seshat-reader
  :type 'number)

(defcustom seshat-reader-render-idle-batch 2
  "Maximum number of pages one asynchronous pass renders.

The pass renders at most this many pages and then returns, leaving the rest
of the queue to the next pulse of the periodic timer.  The bound exists
because the pass runs on the Emacs main thread: rendering the whole queue in
one go would hand the event loop a single long block instead of several short
ones, and the reader would feel exactly the stall the asynchronous pass is
meant to remove.  2 pages of a scanned book cost roughly 40-100 ms of main
thread time, i.e. one command's worth of delay per pulse, which is the
reason this is a knob and not a constant."
  :group 'seshat-reader
  :type 'integer)

(defcustom seshat-reader-render-async t
  "When nil, scroll rendering runs entirely on the command path.

This is the rollback switch of the two-phase render.  While it is non-nil
\(the default) a scroll step renders only the pages the reader is looking at
right now -- the page point is on plus the next page in
`seshat-reader--multipage-scroll-direction' -- and queues the rest of the
visible range for the asynchronous pass, so the pixels of the pages that are
about to come into view arrive after the command returned.

nil means the pre-change behaviour, byte for byte: every page of the visible
range is rendered synchronously, in page order, and the asynchronous queue,
its timers and its timeout bookkeeping are dropped.  Nothing about the
resulting layout differs -- the same specs are written to the same rows -- the
setting only decides *when* the pixels are rendered.

The option is read on every scroll step, so toggling it takes effect on the
next command; no restart, no reload."
  :group 'seshat-reader
  :type 'boolean)

(defcustom seshat-reader-render-async-timeout 1.0
  "Seconds a non-empty render queue may stay pending before it is forced.

The last of the three safety nets of the asynchronous pass, and the only one
that does not depend on a timer firing: idle timers were measured to fire once
per idle window in a daemon Emacs (batch 0, probe G3b) and a periodic timer
can be missed while Emacs is busy, so a queue that never drains would leave
blank placeholder pages on screen for as long as the reader stays there.

The rule: when the queue has been non-empty for longer than this many seconds
-- measured from the moment it first became non-empty, or from the last forced
pass that left entries behind -- the next `post-command-hook' entry of
`seshat-reader--multipage-sync' renders the visible range of **its own
window** synchronously and drops exactly the pages that pass covered from the
queue (`seshat-reader--multipage-clear-synced-pending'): their pixels are in
hand now.  What survives -- the pages another window queued, plus the page the
synchronous prefetch just queued -- is kept, gets the pending clock restarted
and both timers re-armed, so it owns a full timeout window of its own; without
that restart the survivors would still look overdue, the very next command
would force another synchronous pass, and the net meant to rescue the queue
would switch the asynchronous path off for good.  Only a queue that is empty
after the drop takes the whole asynchronous state with it (queue, both timers
and the timestamp): nothing is left to drive.

The queue is buffer-local and shared by every window showing the buffer
\(decision D8), which is why a forced pass -- a window-level operation -- never
empties it as a whole.  The visible pages of a window are therefore blank for
at most this long, whatever the timers do.

1.0 s is above the worst case the timers can be late by (one pulse of
`seshat-reader-render-idle-delay' per batch of pages, i.e. tens of
milliseconds) and below what a reader would call \"stuck\".  The value is read
when the deadline is checked; set it to 0 to force the synchronous path on the
very next command, or set `seshat-reader-render-async' to nil to leave the
asynchronous pass altogether."
  :group 'seshat-reader
  :type 'number)

(defvar-local seshat-reader--multipage-preload 2
  "Number of pages kept resident above and below the visible ones.

The resident set is the page at the top of the window through the page at
its bottom, widened by this many pages in each direction and clipped to
the pages that actually exist in the buffer.  A value of 0 keeps only the
pages the window currently shows.")

(defvar-local seshat-reader--multipage-scroll-direction 1
  "Direction of the last scroll: 1 towards later pages, -1 towards earlier.

Set by `seshat-reader--multipage-scroll' and read by
`seshat-reader--multipage-prefetch', which queues one page beyond the
resident set *in that direction* for the asynchronous pass: the page the
reader is about to reach, not the one it just left.")

(defvar-local seshat-reader--multipage-memory-warned nil
  "Non-nil once the memory budget of this buffer has been reported.

The warning is per buffer and fires once: repeating it on every scroll would
only fill the echo area, and the situation does not change by itself while the
same document stays open (it is cleared when the document is reloaded).")

(defun seshat-reader--multipage-page-cached-size (page)
  "Return the newest cached size of PAGE as a cons (WIDTH . HEIGHT), or nil.

PAGE is a 1-based page number.  `seshat-reader--multipage-page-sizes' is keyed
by (PAGE SCALE ROTATE) and kept newest first, so the first entry of the page
is the size measured for the geometry that page is about to be rendered at --
which is exactly the size a placeholder row has to take.  Selecting by page
alone is deliberate: the row builder has no scale to build a key from, and
asking the native module for one on its own would cache a size belonging to
another geometry and make the placeholder disagree with the spec that follows."
  (catch 'found
    (dolist (entry seshat-reader--multipage-page-sizes)
      (when (equal (car (car entry)) page)
        (throw 'found (cdr entry))))
    nil))

(defun seshat-reader--multipage-page-display-size (page)
  "Return the pixel size the row of PAGE occupies, as a cons (WIDTH . HEIGHT).

PAGE is a 1-based page number.  A row is either rendered -- it displays the
image spec of PAGE -- or it is a placeholder: no spec yet, but the size of the
page is already known from `seshat-reader--multipage-page-sizes' because
`seshat-reader--page-size' measured it (decision D2: sizes first, pixels
later).  Both states answer with the same numbers, and that is the whole
point: the page height (`seshat-reader--multipage-page-pixel-height'), the
horizontal bound (`seshat-reader--multipage-max-page-width') and the centring
test (`seshat-reader--multipage-page-should-center-p') read this function and
nothing else, so a row does not change its geometry when its pixels arrive.

The spec wins where it carries the property, the cached size fills the gaps;
either field may be nil on its own.  nil means the size is unknown, i.e. a
page that was neither rendered nor measured."
  (let* ((spec (seshat-reader--multipage-page-spec page))
         (cached (seshat-reader--multipage-page-cached-size page))
         (width (or (and spec (image-property spec :width)) (car cached)))
         (height (or (and spec (image-property spec :height)) (cdr cached))))
    (when (or (numberp width) (numberp height))
      (cons width height))))

(defun seshat-reader--multipage-page-spacer (page)
  "Return the `space' display value giving PAGE the size it is known to have.

nil when the size of PAGE is unknown, and also when only one of its two
dimensions is known: a `space' specification with a missing dimension would
collapse the row instead of reserving it."
  (let ((size (seshat-reader--multipage-page-display-size page)))
    (when (and (integerp (car-safe size)) (integerp (cdr-safe size)))
      (list 'space
            :width (list (car size))
            :height (list (cdr size))))))

(defun seshat-reader--multipage-row-properties (page spec)
  "Return (GUIDE . BODY), the two `display' values the row of PAGE carries.

GUIDE is the value that centres the row (`seshat-reader--multipage-align-to'),
BODY is the value that gives it its size: the image spec SPEC when the page is
rendered, otherwise the `space' specification of the size PAGE is known to
have (`seshat-reader--multipage-page-spacer').  Both states build their
geometry through this one function, which is what stops a placeholder row from
drifting away from the rendered row it will become.

nil means there is nothing to display: an unrendered page of unknown size
keeps the historical empty row -- two spaces, no property, no height.

The size is spelled `(W)' / `(H)' on purpose.  A bare number inside a display
specification counts multiples of the frame font, and
`(space :width 612 :height 792)' measured 19008px high -- 792 x the 24px line
height -- against 792px for the pixel form (batch 0, S2)."
  (let ((body (or spec (seshat-reader--multipage-page-spacer page))))
    (when body
      (cons (seshat-reader--multipage-align-to
             (or spec
                 (car-safe (seshat-reader--multipage-page-display-size page))))
            body))))

(defun seshat-reader--multipage-page-row (spec &optional wide page)
  "Return the buffer text of one page row displaying SPEC.

SPEC is an image spec as returned by `seshat-reader--page-spec', or nil for a
page that is not rendered yet.  A row is two spaces followed by a newline: the
first space carries the `:align-to' value of
`seshat-reader--multipage-align-to' (which keeps the page horizontally
centred), the second one carries the `display' value that gives the row its
size.  The row therefore occupies exactly one buffer line and has a
well-defined line start to anchor its marker on.

For a rendered page that value is SPEC itself.  For a page whose size is known
but whose pixels are not (PAGE non-nil, see
`seshat-reader--multipage-row-properties') it is a `space' specification of
that size, so the placeholder is exactly as tall and as wide as the rendered
row will be and filling the page in later shifts nothing -- neither the rows
below it nor the ones above.  A page of unknown size stays an empty row of two
spaces with no property and no height, as before.

WIDE non-nil drops the centring space, which is what an overwide page needs:
its image then starts at the left edge and horizontal scrolling -- kept
as-is by decision D5b -- is the only way to see the rest of it."
  (let* ((properties (seshat-reader--multipage-row-properties page spec))
         (body (cdr-safe properties)))
    (cond
     ((null body) "  \n")
     (wide (concat " " (propertize " " 'display body) "\n"))
     (t (concat (propertize " " 'display (car properties))
                (propertize " " 'display body)
                "\n")))))

(defun seshat-reader--multipage-separator-row (pixels face &optional window)
  "Return the buffer text of one separator line PIXELS pixels high.

A nil FACE builds a blank line, a non-nil one builds the rule itself.  The
height is expressed as the relative :height of a face and not through the
`line-height' text property, because `line-height' can only make a line
taller than the default and never shorter.  The rule is a space whose
`display' property is (space :align-to (- right 0)): a stretch space that
fills the window width -- measured equal to the window body width -- and
follows a resize on its own.

nil is returned when PIXELS is not positive, which lets the caller skip the
line.  WINDOW defaults to the selected one and is only used to find the
frame."
  (when (> (or pixels 0) 0)
    (let ((ratio (/ (float pixels)
                    (max 1 (seshat-reader--default-line-pixels window)))))
      (if (null face)
          (concat (propertize "\n" 'face (list :height ratio)))
        (concat (propertize " "
                            'display '(space :align-to (- right 0))
                            'face (list :inherit face :height ratio))
                "\n")))))

(defun seshat-reader--multipage-separator-rows (&optional window)
  "Return the buffer text of the separator that follows a page row.

That is the complete region between a page row and the row of the next page:
the blank space, the rule in `seshat-reader-page-separator-face' and the
blank space again, in the sizes
`seshat-reader--multipage-separator-segments' reports.  A segment of 0
contributes no line, and nil means the region takes no space at all.  WINDOW
defaults to the selected one and is only used to find the frame."
  (when-let* ((segments (seshat-reader--multipage-separator-segments window)))
    (apply #'concat
           (delq nil
                 (list (seshat-reader--multipage-separator-row
                        (nth 0 segments) nil window)
                       (seshat-reader--multipage-separator-row
                        (nth 1 segments) 'seshat-reader-page-separator-face
                        window)
                       (seshat-reader--multipage-separator-row
                        (nth 2 segments) nil window))))))

(defun seshat-reader--multipage-write-row (start spec &optional centered page)
  "Write the display properties of the page row at START so it shows SPEC.

START is the first character of a row built by
`seshat-reader--multipage-page-row', so the row always has the two leading
characters this function writes to.  CENTERED non-nil gives the row the
`:align-to' centring space, nil leaves the image flush with the left edge.
PAGE is the page the row belongs to and is only needed when SPEC is nil: the
row then keeps (or takes) the size the page is known to have, the same
`space' specification `seshat-reader--multipage-page-row' builds for it.  Only
text properties are written here -- never text -- so the row keeps its length,
its marker and the position of every other page row: this is the function
that fills a placeholder in, and moving a marker there would move a page.

The buffer is written under `inhibit-read-only' and left unmodified."
  (let ((inhibit-read-only t)
        (end (min (point-max) (+ start 2)))
        (properties (seshat-reader--multipage-row-properties page spec)))
    (if (null properties)
        (remove-text-properties start end '(display nil))
      (put-text-property start (1+ start) 'display
                         (and centered (car properties)))
      (put-text-property (1+ start) end 'display (cdr properties)))
    (set-buffer-modified-p nil)))

(defun seshat-reader--multipage-set-page-centered (page centered)
  "Centre the row of PAGE when CENTERED is non-nil, left align it otherwise.

Nothing is rebuilt: only the `display' property of the leading space of the
row is rewritten, so the row keeps its identity, its marker and the spec it
shows.  That in-place edit is what makes the frame that follows a resize
correct without re-rendering anything."
  (when-let* ((entry (assq page seshat-reader--pages))
              (start (marker-position (cadr entry))))
    (seshat-reader--multipage-write-row start (cddr entry) centered page)))

(defun seshat-reader--multipage-page-centered-p (page)
  "Return non-nil when the row of PAGE is placed the way its geometry wants.

A rendered row's `:align-to' form has to reference the very spec object the
row displays, and the row has to display that object too -- by identity, not
by `equal': comparing multi-megabyte bitmaps by content on every redisplay
hook entry would be pointless.  A mismatch means the spec was replaced by a
re-render, or that the centring was cleared, and the row then counts as not
centred.

A placeholder row is checked against the size its page is known to have
instead: the `:align-to' form references that width in pixels and the second
space displays the `space' specification of the same size, so both are
compared by value.  Without that branch a centred placeholder would look
stale on every redisplay -- `seshat-reader--centered-p' compares this function
with `seshat-reader--multipage-page-should-center-p' before every frame -- and
the row would be rewritten once per frame."
  (when-let* ((entry (assq page seshat-reader--pages))
              (start (marker-position (cadr entry))))
    (let* ((spec (cddr entry))
           (properties (seshat-reader--multipage-row-properties page spec))
           (guide (get-text-property start 'display))
           (align (and (consp guide) (eq (car guide) 'space)
                       (plist-get (cdr guide) :align-to)))
           (form (and (consp align) (eq (car align) '+) (nth 2 align)))
           (image (get-text-property (1+ start) 'display))
           (width (car-safe (seshat-reader--multipage-page-display-size page))))
      (and properties
           (consp form)
           (if spec
               (eq (cdr form) spec)
             (equal (cdr form) (and (numberp width) (list width))))
           (if spec
               (eq image spec)
             (equal image (cdr properties)))
           t))))

(defun seshat-reader--multipage-page-should-center-p (page &optional window)
  "Return non-nil when the row of PAGE fits the width of WINDOW.

PAGE is a 1-based page number and WINDOW defaults to the selected one.  A
page wider than the window is left aligned so that horizontal scrolling can
reach the rest of it, a page that fits is centred; that is the mechanical
form of decision D5's \"crop wide pages by width\".  Unknown geometry counts
as centred, which is what the placeholder rows of unrendered pages want.

The width comes from `seshat-reader--multipage-page-display-size', i.e. from
the same place the row takes its geometry from, so a page whose size is known
but whose pixels are not yet answers exactly like the rendered page it becomes
instead of falling into the \"unknown, assume centred\" branch and jumping
sideways when the bitmap arrives."
  (let* ((window (if (window-live-p window) window (selected-window)))
         (width (car-safe (seshat-reader--multipage-page-display-size page)))
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

The value comes from the geometry the rows currently have
\(`seshat-reader--multipage-page-display-size'), i.e. from the spec of a
rendered page and from the measured size of a page whose pixels are still to
be delivered; the two states therefore report the same width and the
horizontal scroll bound does not change when a bitmap arrives.  That width is
what the caller needs."
  (let ((widest nil))
    (dolist (entry seshat-reader--pages widest)
      (let ((width (car-safe
                    (seshat-reader--multipage-page-display-size (car entry)))))
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
keeps its size in the meantime instead of collapsing.

Only the spec cache is touched here: the size of PAGE stays in
`seshat-reader--multipage-page-sizes' on purpose, because a far page that
lost its size would fall back to the height-0 placeholder and change the
scroll extent at the moment it is recycled (see the comment in the body)."
  ;; 为什么不清尺寸（这是 T3 能否成立的前提，不要「顺手」改掉）：
  ;; `seshat-reader--multipage-recycle-page' 会对离开驻留集的远页调本函数。
  ;; 若这里连尺寸一起删掉，那些页就退回「尺寸未知」的占位态（高度 0、span
  ;; 下限 1），**滚动范围在回收的那一刻立刻变化**——正是 P1/P2 反复踩过的
  ;; 跳变坑。尺寸条目每页只有两个整数（整本 800 页也只有几十 KB），没有
  ;; 回收必要；而保住它，才能让「已定尺寸、尚未渲染」的页与真实 image 同高。
  ;;
  ;; 同理，这里**也不自增渲染代际**（`--multipage-render-generation'）：本函数
  ;; 是单页粒度且被 `--multipage-recycle-page' 高频调用，若在此自增，「滚动回收
  ;; 一页」就等于「作废全部在途 pending」，idle 补位会被系统性作废（复审 N1）。
  ;; 全量失效才自增，入口是 `seshat-reader--page-spec-clear-cache'。
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
because `:align-to' references the spec object itself.  A page that has no
spec yet has nothing to resize and is left alone (nil): a placeholder row
takes its size from `seshat-reader--multipage-page-sizes' instead, and
rewriting a `:width' on a nil spec would signal."
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
          ;; canvas spec 没有 flush 语义：`:data-width'/`:data-height' 与缓冲
          ;; 内容只允许渲染函数写一次（那里才第一次分配并填像素），可随时 setf
          ;; 的只有 `:width'/`:height' 这一对。改尺寸因此只是重排，不会重渲染
          ;; 整页位图（旧 pbm 后端拖动分割线时每帧 flush，实测卡 1–2s）。
          (setf (image-property spec :width) new-width)
          (setf (image-property spec :height) new-height)
          t)))))

(defun seshat-reader--multipage-page-spec (page)
  "Return the image spec recorded for PAGE, or nil when it has none.

PAGE is a 1-based page number.  nil means either that the page is not part
of the layout or that it is part of it but not rendered yet; callers that
must tell those two cases apart test `seshat-reader--pages' with `assq'."
  (cddr (assq page seshat-reader--pages)))

(defun seshat-reader--multipage-insert-page (page spec &optional window)
  "Insert the row of PAGE holding SPEC, keeping the layout sorted by page.

PAGE is a 1-based page number and SPEC is an image spec, or nil for a page
that is not rendered yet.  A page whose pixels are still missing but whose
size is already known gets a row of that size instead of an empty one (see
`seshat-reader--multipage-page-row'), so the layout is final before the
bitmap exists and filling it in later moves nothing.  A page that already has
a row only gets its SPEC replaced and the function returns nil, so it is
idempotent and can be called on every scroll step.  A new row goes before the
first row of a greater page and at the end of the buffer when PAGE is greater
than every page present; the newline count from
`seshat-reader-page-gap-lines' is
appended after the row and the separator region of
`seshat-reader--multipage-separator-rows' after those newlines.  The buffer
is written under `inhibit-read-only' and left unmodified, and the marker of
the row is returned.

WINDOW is the display window the row is built for, i.e. the window whose
frame supplies the character height that bakes the `:height' ratio of the
separator rows.  nil means \"resolve it for me\" through
`seshat-reader--multipage--display-window', the same resolution every other
layout function uses.  It has to be the same window the scroll arithmetic
measures (`seshat-reader--multipage-page-gap-pixels'): on two frames with
different fonts the baked row heights and the scrolled pixel distance would
otherwise come from two different character heights and drift apart."
  (let ((entry (assq page seshat-reader--pages)))
    (if entry
        (let ((start (marker-position (cadr entry)))
              ;; 保持该页行当前的居中/贴左状态：换 spec 与换位置是两件事。
              ;; 占位态的居中判定同样走这一条（见
              ;; `seshat-reader--multipage-page-centered-p'），补位时不会先
              ;; 贴左再居中。
              (centered (seshat-reader--multipage-page-centered-p page)))
          (seshat-reader--multipage-write-row start spec centered page)
          (setcdr (cdr entry) spec)
          nil)
      (let ((inhibit-read-only t)
            (start nil)
            ;; 分隔行的高度按显示窗口所属 frame 的字符高度烘焙成 face :height
            ;; 倍率，因此必须与滚动几何用同一个窗口来源；显式入参优先，
            ;; nil 时按 `--multipage--display-window' 解析（与其它布局函数一致）。
            (win (seshat-reader--multipage--display-window window)))
        ;; 页按页号升序存放，第一个页号更大的行就是插入点。
        (catch 'found
          (dolist (other seshat-reader--pages)
            (when (> (car other) page)
              (setq start (marker-position (cadr other)))
              (throw 'found t))))
        (save-excursion
          (goto-char (or start (point-max)))
          (let* ((row-start (point))
                 ;; 占位行的居中/贴左与已渲染行同源：比窗口宽的页从一开始就
                 ;; 贴左，补位那一刻横向位置不会跳（`--center-page' 之后也会
                 ;; 算一次，但插行时就算对，首帧就是对的）。
                 (wide (and (null spec)
                            (not (seshat-reader--multipage-page-should-center-p
                                  page win)))))
            (insert (seshat-reader--multipage-page-row spec wide page))
            (dotimes (_ seshat-reader-page-gap-lines)
              (insert "\n"))
            (insert (or (seshat-reader--multipage-separator-rows win) ""))
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
           (preload (seshat-reader--multipage-effective-preload)))
      (cons (max 1 (- first-page preload))
            (min highest (+ (max first-page last-page) preload))))))

(defun seshat-reader--multipage-all-visible-pages (&optional window)
  "Return the union of the pages every window on this buffer keeps visible.

The pages of one window are what `seshat-reader--multipage-visible-range'
reports for it, i.e. its viewport widened by
`seshat-reader--multipage-preload'; the answer here is the union of those page
ranges over every window showing the current buffer **on any live frame**,
ascending and without duplicates.  A window whose range is nil (nothing known
about the buffer yet) contributes nothing.

The walk is `(frame-list)' -> `(window-list FRAME)' -> keep the windows whose
`window-buffer' is the current buffer, and it has to stay that way: plain
`(window-list)' answers the windows of the **selected frame only**, so a buffer
shown in two frames would leave the other frame's windows out of the union.
That is not cosmetic -- the union is the argument
`seshat-reader--multipage-prune-pending' trims the render queue with, so a
window left out of it has the pages it queued deleted and its placeholder pages
stay blank until it scrolls again.  That is the D8 defect of T8 reappearing
across frames.  Dead frames are skipped (`window-list' would signal on them);
a minibuffer-only frame reports no windows and drops out by itself.

WINDOW is merged into the set explicitly, nil meaning \"the selected window\";
it is normally the window the caller is working for, and naming it keeps the
answer independent of what the frame walk happens to report (a caller can work
for a window whose frame the walk does not reach, e.g. while a frame is being
made).

`window-list' is filtered by hand instead of `get-buffer-window-list' on
purpose: the latter resolves \"all frames\" through an extra layer that behaves
differently in batch and in a daemon, while `(eq (window-buffer w)
\(current-buffer))' is exactly the condition the rest of the layout uses.

Why a union and not just the calling window's range: the render queue
`seshat-reader--multipage-pending-renders' is buffer-local and shared by every
window (decision D8), so entries another window queued must survive a pass
made for this one.  Pruning it with a single window's range is the defect fixed
in T8 -- see `seshat-reader--multipage-prune-pending'.  The layout itself stays
per window: only the queue is shared.

nil means no window reported a page range at all; callers must read that as
\"nothing to prune against\" and leave the queue alone."
  (let ((windows nil)
        (pages nil))
    ;; 遍历**所有** frame 的窗口，不能用无参 `(window-list)'：它只答选中 frame
    ;; 的窗口，同一 buffer 显示在另一个 frame 时那个窗口不进并集，它的队项会被
    ;; `--multipage-prune-pending' 裁掉（D8 的跨 frame 缺口）。
    (dolist (frame (frame-list))
      (when (frame-live-p frame)
        (dolist (win (window-list frame))
          (when (and (windowp win)
                     (eq (window-buffer win) (current-buffer)))
            (push win windows)))))
    ;; 调用方自己的窗口显式并入：frame 遍历不保证覆盖它（见 docstring）。
    (when (and (windowp window) (window-live-p window))
      (push window windows))
    (dolist (win windows)
      (let ((range (seshat-reader--multipage-visible-range win)))
        (when (consp range)
          (let ((page (car range)))
            (while (<= page (cdr range))
              (push page pages)
              (setq page (1+ page)))))))
    (sort (delete-dups pages) #'<)))

(defun seshat-reader--multipage-resident-pages (&optional window)
  "Return the pages the layout must keep, as an ascending list of page numbers.

The row table `seshat-reader--pages' is buffer-local and shared by every window
showing the buffer, so \"resident\" cannot mean \"what this window sees\":
recycling a page another window still shows deletes the row under that window's
`window-start' and drags it forward.  The set is therefore the union of the
visible ranges of every window on the buffer --
`seshat-reader--multipage-all-visible-pages', with WINDOW merged in explicitly
-- and **not** the cross distance `seshat-reader--multipage-resident-page-range'
reports: two windows eleven pages apart would make every page between them
\"resident\", which keeps bitmaps alive for pages nobody sees and hides the real
victims from the cache eviction rule (decision D4 of the multi-window plan).

WINDOW is merged only when it is live and shows this buffer; nil means \"no
calling window to merge\", which is what the callers that work for the buffer
rather than for a window pass.

The fallback, and why it exists: when no window reports a range -- a buffer no
window displays, which is how the geometry fixtures run, or a buffer whose
layout is not built yet -- the answer is every page between the first and the
last row, i.e. exactly the cross distance of
`seshat-reader--multipage-resident-page-range'.  That is not a second policy:
with one window, and with no window at all, union and cross distance describe
the same set, so the fallback keeps the no-window path behaving as it did before
the union existed instead of recycling every row.

nil means \"nothing is known about visibility\": there is no row and no window
reports a range."
  (or (seshat-reader--multipage-all-visible-pages window)
      (when-let* ((range (seshat-reader--multipage-resident-page-range)))
        (number-sequence (car range) (cdr range)))))

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

(defconst seshat-reader--range-parameter 'seshat-reader-range
  "Window parameter holding the page range a window was last synchronised for.

The value is a cons (BUFFER . RANGE): BUFFER is the buffer whose layout was
synchronised in that window and RANGE is the (FIRST . LAST) cons
`seshat-reader--multipage-visible-range' returned for it.

`seshat-reader--multipage-sync' returns immediately while the range asked for
is still the recorded one, so the record decides whether any work happens at
all and the `post-command-hook' entry costs one range computation per command
instead of a full pass over the resident pages.  It is a **window** parameter
and not a buffer-local variable because the record is per window: a
buffer-local one is shared by every window showing the buffer, so which window
ran the previous command decided whether the current one was skipped -- the
\"random\" jumping of the two-window report (decision D2 of the multi-window
plan).  With the parameter each window is skipped or redone on its own
account.

BUFFER is part of the value because a window keeps its parameters when it
switches to another buffer and back.  Without the check a stale range left by
an earlier visit would compare equal to the range of the new visit while the
row table is empty (it was cleared on the way in), the sync would return early
and the rows would never be rebuilt: a permanently blank reader.

Use `seshat-reader--multipage-last-range-for' and
`seshat-reader--multipage-set-last-range' instead of the parameter directly,
so the buffer check stays in one place.")

(defun seshat-reader--multipage-last-range-for (window)
  "Return the page range WINDOW was last synchronised for, or nil.

WINDOW defaults to the selected window when it is not live.  The range is read
from the window parameter `seshat-reader--range-parameter' and only returned
when the buffer stored next to it is the current buffer, because a window
keeps its parameters across a buffer switch.  nil therefore means \"this
window has not been synchronised for this buffer\", which is exactly the
condition the early return of `seshat-reader--multipage-sync-blocking' and of
`seshat-reader--multipage-sync' test."
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (window-live-p win)
      (let ((value (window-parameter win seshat-reader--range-parameter)))
        (when (eq (car-safe value) (current-buffer))
          (cdr value))))))

(defun seshat-reader--multipage-set-last-range (window range)
  "Record RANGE as the page range WINDOW was last synchronised for.

WINDOW defaults to the selected window when it is not live and RANGE is the
\(FIRST . LAST) cons the synchronisation ran for.  The current buffer is
stored next to the range, because the parameter outlives the visit it was
recorded in; see `seshat-reader--range-parameter' for the failure that
prevents."
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (window-live-p win)
      (set-window-parameter win seshat-reader--range-parameter
                            (cons (current-buffer) range)))))

(defun seshat-reader--multipage-clear-last-ranges ()
  "Forget the synchronised range of every window showing this buffer.

Every window on every frame, not just the selected one, because the record is
what makes a sync return early: a window that keeps a range equal to the one
about to be asked for skips the rebuild, and with the row table just cleared
that means its rows are never inserted again -- the window stays blank for
good, the same shape as the \"page turned background colour\" report, which is
why this loops over `get-buffer-window-list' instead of clearing one window."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-parameter window seshat-reader--range-parameter nil)))

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
`seshat-reader--multipage-remove-page'.

The recorded range of every window showing the buffer is dropped too
\(`seshat-reader--multipage-clear-last-ranges'): the rows are gone, so a window
that kept a range equal to the next one asked for would return early from the
sync and its rows would never be rebuilt -- a permanently blank reader."
  (dolist (entry seshat-reader--pages)
    (when (markerp (cadr entry))
      (set-marker (cadr entry) nil)))
  (setq seshat-reader--pages nil)
  (seshat-reader--multipage-clear-last-ranges))

(defun seshat-reader--multipage-render-page (page &optional force window)
  "Make sure PAGE has a row displaying its image spec and return the spec.

PAGE is a 1-based page number.  A page without a row gets one built from
`seshat-reader--page-spec', a page whose row exists but carries no spec gets
the spec filled in, and an already rendered page is left alone, so calling
this on every scroll step is cheap.  FORCE non-nil renders the page again
even when its row already carries a spec, which is what a re-render at a new
resolution needs: the row keeps the spec object it had, so without FORCE the
early return would answer with the stale bitmap.

WINDOW defaults to the window displaying this buffer
\(`seshat-reader--multipage--display-window') and is only used to derive the
geometry: it is handed to `seshat-reader--multipage-target-scale' and
`seshat-reader--multipage-resize-spec'.  Passing it explicitly on every call
path keeps those two from having to guess, which matters while the minibuffer
is open, where guessing means the mini window.

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
    (let* ((scale (seshat-reader--multipage-target-scale page window))
           (spec (seshat-reader--page-spec
                  page scale seshat-reader--multipage-rotate)))
      (when spec
        (seshat-reader--multipage-record-native page spec scale))
      (seshat-reader--multipage-insert-page page spec window)
      (when spec
        ;; native 尺寸已记录，目标 scale 可能因此变小（宽页在 contain/width 下
        ;; 按宽裁剪），这里只改 spec 尺寸，不重渲染。
        (seshat-reader--multipage-resize-spec page window)
        (seshat-reader--multipage-set-page-centered
         page (seshat-reader--multipage-page-should-center-p page)))
      spec)))

(defun seshat-reader--multipage-rerender-page (page &optional window)
  "Render PAGE again at its target scale and update its row.

PAGE is a 1-based page number and WINDOW defaults to the window displaying
this buffer (`seshat-reader--multipage--display-window'), never to a
minibuffer window.  WINDOW is forwarded to
`seshat-reader--multipage-render-page' so that the geometry comes from the
window the page is really shown in.  The cached spec of the page is dropped
first and the render is forced, so the rows of a page whose bitmap became
invalid -- dark mode inverted the document, the page was rotated, the window
was resized -- are rebuilt at the resolution the current geometry asks for.
Nothing is done for a page without a row."
  (when (assq page seshat-reader--pages)
    (seshat-reader--multipage-forget-specs page)
    (let ((spec (seshat-reader--multipage-render-page page t window)))
      (when spec
        (seshat-reader--multipage-set-page-centered
         page (seshat-reader--multipage-page-should-center-p page window)))
      spec)))

(defun seshat-reader--multipage-refresh-decorations (&optional window)
  "Re-render every resident page of WINDOW so its decorations are up to date.

WINDOW defaults to the selected one and must be displaying the current
buffer.  Every page row of the buffer (the viewport plus
`seshat-reader--multipage-preload' pages on each side, see
`seshat-reader--multipage-page-numbers') is rendered again through
`seshat-reader--multipage-rerender-page', which drops the cached spec of the
page first: no row is inserted or removed and no scale is touched.

Why a re-render and not a repaint: since P1 the decorations (annotation
rectangles, the selection flash, search hits and ink strokes) are **baked into
the page bitmap while it is rendered**, so the C side table alone no longer
changes what is on screen.  Feeding the table used to be followed by a call to
a window-level repaint entry point; that entry point repainted a single-page
overlay which does not exist any more and was retired together with the overlay
backend, so the cached spec has to be dropped and the page drawn again instead.
See `VENDORED.md', decoration layer.

Each page is rendered inside `ignore-errors': a decoration refresh is optional
feedback and must never break the command that triggered it (a page that fails
to render simply keeps the bitmap it had).  The number of pages that were
re-rendered is returned."
  (let ((win (or window (selected-window)))
        (count 0))
    (when (eq (window-buffer win) (current-buffer))
      (dolist (page (seshat-reader--multipage-page-numbers))
        (when (ignore-errors (seshat-reader--multipage-rerender-page page win))
          (setq count (1+ count)))))
    count))

(defconst seshat-reader--refit-scale-tolerance 0.005
  "Largest difference between two scales that still counts as the same one.

The gate in `seshat-reader--multipage-refit-page' compares the scale a bitmap
was rendered at with the target scale of its page.  Exact equality would be too
strict: the native size of a page is the spec size divided by the scale it was
rendered at, so rounding moves the target in the third decimal on every
re-render, and an exact comparison would re-render the page again on the next
refit -- forever.  0.5% of a scale is far below what can be seen, so treating
such a difference as \"already sharp\" is both safe and what makes the refit
idempotent.")

(defun seshat-reader--multipage-refit-page (page &optional window)
  "Re-render PAGE when its bitmap resolution differs from its target scale.

PAGE is a 1-based page number and WINDOW defaults to the selected one.  The
geometry itself is adapted in place by `seshat-reader--multipage-resize-spec'
\(no pixels change), and the page is rendered again only when the scale its
bitmap was rendered at differs from the target by more than
`seshat-reader--refit-scale-tolerance', which is what makes the visible pages
sharp after a resize without ever rendering a page twice."
  (let ((target (seshat-reader--multipage-target-scale page window))
        (rendered (seshat-reader--multipage-render-scale page)))
    (unless (and (numberp target) (numberp rendered)
                 (< (abs (- target rendered))
                    seshat-reader--refit-scale-tolerance))
      (seshat-reader--multipage-rerender-page page window))))

(defun seshat-reader--multipage-page-near-resident-p (page &optional keep)
  "Return non-nil when PAGE is resident or one page away from the set.

PAGE is a 1-based page number.  The set is what
`seshat-reader--multipage-resident-pages' reports, i.e. the union of the pages
every window on the buffer keeps visible (decision D4); PAGE counts when it is a
member of that set or one page before/after a member, which is the \"±1\"
boundary this predicate always had.  Only the **source** of the set changed,
from the cross distance between the first and the last row to the union, so a
page sitting between two distant windows is no longer near-resident: nobody sees
it, and keeping its bitmap is what the eviction rule would undo first anyway.

For a contiguous union (one window, or windows whose ranges touch) the answer is
exactly the old `(>= page (1- first))' / `(<= page (1+ last))' interval.  For a
gap it extends the boundary around the real members instead of filling the gap,
so the page just before a window that starts at 20 still keeps its bitmap for
the way back.

KEEP, when non-nil, is the set to test against, as
`seshat-reader--multipage-resident-pages' returns it.  Callers that test many
pages in a row pass it so the frame/window walk happens once instead of once per
page: the recycle loops of `seshat-reader--multipage-sync-blocking' and
`seshat-reader--multipage-sync-async' would otherwise be quadratic in the number
of rows.

nil is returned when the set is empty, i.e. when no row is left and no window
reports a range."
  (let ((pages (or keep (seshat-reader--multipage-resident-pages))))
    (and pages
         (or (memq page pages)
             (memq (1- page) pages)
             (memq (1+ page) pages)))))

(defun seshat-reader--multipage-recycle-page (page &optional keep)
  "Remove the row of PAGE and release the cached spec of that page.

PAGE is a 1-based page number and the spec the row was displaying is
returned.  Dropping the cached spec is what actually releases the bitmap.

The spec of a page that is resident or one page next to the resident set is
kept, which is what makes scrolling one page back hit the cache instead of
rendering the page again: in P0 every recycled page lost its bitmap
immediately and a single page back was a full re-render (a 0% hit rate while
scanning 20 pages, the measurement this batch exists to fix).  Only pages
further away -- the ones the eviction rule of
`seshat-reader--page-spec-eviction-victim' would drop first anyway -- lose
their bitmap here.  \"Resident\" means the union of the pages every window on
the buffer shows (`seshat-reader--multipage-resident-pages'), so the bitmap of a
page another window still displays is never released here.

KEEP, when non-nil, is the resident set to test PAGE against, as
`seshat-reader--multipage-resident-pages' returns it.  The recycle loops compute
it once and pass it down: testing every page against a freshly computed union
would walk every frame and window once per row.

The recorded native size and render scale are dropped either way, so a page
that comes back is measured again instead of reusing a size that a rotation
may have changed."
  (let ((spec (seshat-reader--multipage-remove-page page)))
    (when (and spec
               (not (seshat-reader--multipage-page-near-resident-p page keep)))
      (seshat-reader--multipage-forget-specs page))
    (setq seshat-reader--page-native-sizes
          (assq-delete-all page seshat-reader--page-native-sizes)
          seshat-reader--page-render-scales
          (assq-delete-all page seshat-reader--page-render-scales))
    spec))

;;; Asynchronous render pass (P2-B T5)

;; 两阶段渲染的第二阶段：滚动路径只登记「哪些页还缺像素」，像素交给
;; 「idle 首轮 + 周期 timer 推进」的队列。下面每条约束都来自批次 0 的实测
;; （数值见 `openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md'）：
;;
;; - **idle timer 只做首轮启动，REPEAT 必须 nil**：daemon 下一个 idle 窗口只
;;   fire 一次，回调自续不会让它再触发（探针 G3b：ticks = 1），所以它不是驱动
;;   源，只是「Emacs 安静下来后先跑一轮」的触发器；
;; - **队列推进只能靠 `run-at-time' 的重复 timer**：这是唯一可靠的持续驱动源；
;; - **每轮有界**（`seshat-reader-render-idle-batch'）：渲染占 Emacs 主线程，
;;   一轮渲染整队会把多次短停顿合并成一次长停顿，正好是本项要消除的手感；
;; - **两个 timer 都存在 buffer-local 变量里，每次排程前先 cancel 旧的**：与
;;   `seshat-reader--schedule-refit' 同一范式（cancel + 单 timer + buffer 入参），
;;   避免一次滚动堆出多个 timer 同时推进同一队列。

(defconst seshat-reader--multipage-render-failure-limit 3
  "Number of failed renders after which a page stops being queued.

The mechanical form of the non-blocking-render invariant: a page whose render
keeps returning nil leaves the queue instead of being retried forever.  The
count is cleared when the page becomes visible again
\(`seshat-reader--multipage-reset-render-failure') and on a generation change
\(`seshat-reader--page-spec-clear-cache'), so a transient failure is never
turned into a permanent one.")

(defvar-local seshat-reader--multipage-pending-renders nil
  "Pages queued for the asynchronous render pass, oldest request first.

Each element is a 1-based page number.  The queue is buffer-local and holds
the union of what every window showing the buffer asked for (decision D8):
window-local queues would overwrite each other as soon as two windows show
the same buffer at different scroll positions.

Only page numbers are stored -- not the scale, not the rotation, not the
window.  Those are re-derived when the pass runs
\(`seshat-reader--multipage-target-scale' plus
`seshat-reader--multipage-rotate'), which is what makes the queue stay valid
across a zoom: a queued page is rendered at the geometry that holds when its
turn comes, and the generation recorded below is what drops the batch if that
geometry changed instead.")

(defvar-local seshat-reader--multipage-pending-generation nil
  "Render generation the queue was filled in, or nil when it is empty.

Recorded on the first queued page and compared by the pass before anything is
rendered or written back: a mismatch means a full invalidation (zoom, tint,
reload, relayout) ran while the pages waited, so the whole queue belongs to a
geometry that no longer exists and is dropped (decision D4).")

(defvar-local seshat-reader--multipage-async-idle-timer nil
  "Idle timer that fires the first pass of this buffer, or nil.

Always armed with a nil REPEAT: an idle timer fires once per idle window in a
daemon Emacs (probe G3b), so it must never be treated as the driver of the
queue.")

(defvar-local seshat-reader--multipage-async-render-timer nil
  "Repeating timer that advances the render queue of this buffer, or nil.

Armed by `seshat-reader--schedule-async-render' and cancelled as soon as the
queue is empty, so an idle reader has no timer running at all.")

(defvar-local seshat-reader--multipage-async-rendering nil
  "Non-nil while a render pass of this buffer is running.

The guard against re-entry: a pass writes text properties, which can report a
window state change, which can run the post-command path and queue more work;
a second pass started from inside the first one would render the same page
twice and interleave its writes with the outer pass (same idea as
`seshat-reader--multipage-syncing' and `seshat-reader--refitting').")

(defvar-local seshat-reader--multipage-async-pending-since nil
  "`float-time' at which the render queue of this buffer became non-empty.

nil means \"the queue is empty right now\".  The value is what the timeout net
of `seshat-reader--multipage-sync' compares against
`seshat-reader-render-async-timeout': it records when the *current* pending
stretch began, not when a page was queued last, so a queue that keeps being
refilled with new pages still ages out.

It is cleared by every path that empties the queue -- the pass itself, a full
invalidation, the forced synchronous pass of state C when its drop takes the
last entry and the switch to `seshat-reader-render-async' = nil -- so a stale
timestamp can never make the next scroll take the slow path.  The forced pass
also *restarts* it when entries survive the drop (they belong to another
window); see `seshat-reader--multipage-clear-synced-pending'.")

(defun seshat-reader--multipage-pending-add (page)
  "Queue PAGE for the asynchronous render pass, return non-nil when queued.

PAGE is a 1-based page number.  Nothing is queued when the page is already
queued, when its pixels are already known -- in the spec cache at any scale
\(`seshat-reader--multipage-spec-cached-p') or in the row of the page -- or
when its render already failed
`seshat-reader--multipage-render-failure-limit' times, which is how the
\"three failures then stop\" invariant is enforced at the entry point as well
as in the pass itself.

The generation is recorded with the first entry, so the queue as a whole
belongs to one geometry; see
`seshat-reader--multipage-pending-generation'."
  (when (and (integerp page) (> page 0)
             (not (memq page seshat-reader--multipage-pending-renders))
             (not (seshat-reader--multipage-spec-cached-p page))
             (not (and (assq page seshat-reader--pages)
                       (seshat-reader--multipage-page-spec page)))
             (not (seshat-reader--multipage-render-failed-p page)))
    (unless seshat-reader--multipage-pending-renders
      (setq seshat-reader--multipage-pending-generation
            seshat-reader--multipage-render-generation
            ;; 队列从空到非空的这一刻就是超时兜底的计时起点（T6 态 C）。
            seshat-reader--multipage-async-pending-since (float-time)))
    (setq seshat-reader--multipage-pending-renders
          (append seshat-reader--multipage-pending-renders (list page)))
    t))

(defun seshat-reader--multipage-pending-remove (page)
  "Drop PAGE from the asynchronous render queue.

PAGE is a 1-based page number; a page that is not queued is ignored.  The
recorded generation is cleared with the last entry, so an empty queue never
claims a generation."
  (setq seshat-reader--multipage-pending-renders
        (delq page seshat-reader--multipage-pending-renders))
  (unless seshat-reader--multipage-pending-renders
    (setq seshat-reader--multipage-pending-generation nil
          seshat-reader--multipage-async-pending-since nil)))

(defun seshat-reader--multipage-pending-clear ()
  "Empty the asynchronous render queue of the current buffer.

Both the page numbers and the generation they were queued in are dropped: the
queue is only meaningful for the geometry it was filled in.  The pending
timestamp goes with them -- an empty queue has no age."
  (setq seshat-reader--multipage-pending-renders nil
        seshat-reader--multipage-pending-generation nil
        seshat-reader--multipage-async-pending-since nil))

(defun seshat-reader--multipage-prune-pending (pages)
  "Keep only the queued pages that are also in PAGES.

PAGES is a list of 1-based page numbers -- in production the union of the pages
every window showing this buffer keeps visible, as returned by
`seshat-reader--multipage-all-visible-pages' -- and the queue is trimmed to its
intersection with it, so pages nobody can see are never rendered.  The order of
the surviving entries is kept, and so is the recorded generation while the
queue stays non-empty.

The argument is deliberately the union of all windows and **not** the calling
window's own range: the queue is buffer-local and shared (decision D8), so
pruning it with one window's range drops the entries another window just
queued -- two windows scrolled apart could then keep deleting each other's
pending pages.  Rendering, recycling and failure clearing keep walking the
calling window's own range: only the queue is shared, the layout is not.

nil PAGES leaves the queue untouched.  nil means \"no window reported a page
range\", not \"nothing is visible\"; emptying the queue on it would throw away
job that is still valid (the 1-based page list of a real pass is never nil)."
  (when pages
    (let (kept)
      (dolist (page seshat-reader--multipage-pending-renders)
        (when (memq page pages)
          (push page kept)))
      (setq seshat-reader--multipage-pending-renders (nreverse kept))
      (unless seshat-reader--multipage-pending-renders
        (setq seshat-reader--multipage-pending-generation nil
              seshat-reader--multipage-async-pending-since nil))))
  seshat-reader--multipage-pending-renders)

(defun seshat-reader--multipage-render-failure-count (page)
  "Return how many times the render of PAGE has failed.

PAGE is a 1-based page number; a page that never failed reports 0."
  (or (cdr (assq page seshat-reader--multipage-render-failures)) 0))

(defun seshat-reader--multipage-note-render-failure (page)
  "Count one more failed render of PAGE and return the new count.

PAGE is a 1-based page number.  The table stays an alist so that it stays
readable in a backtrace and cheap to clear wholesale; a page appears at most
once in it."
  (let ((count (1+ (seshat-reader--multipage-render-failure-count page))))
    (setq seshat-reader--multipage-render-failures
          (cons (cons page count)
                (assq-delete-all page
                                 seshat-reader--multipage-render-failures)))
    count))

(defun seshat-reader--multipage-render-failed-p (page)
  "Return non-nil when PAGE failed to render too many times to retry.

PAGE is a 1-based page number.  The threshold is
`seshat-reader--multipage-render-failure-limit'."
  (>= (seshat-reader--multipage-render-failure-count page)
      seshat-reader--multipage-render-failure-limit))

(defun seshat-reader--multipage-reset-render-failure (page)
  "Clear the failure count of PAGE so that it may be queued again.

PAGE is a 1-based page number.  This is the second of the two places the
non-blocking-render invariant clears the count -- the first one is the
generation change inside `seshat-reader--page-spec-clear-cache' -- and it
exists for the case the generation cannot cover: purely scrolling away and
back does not advance the generation, so without this call a page that failed
twice while it was off screen would be dropped permanently the next time it
came into view.  T6 calls it for every visible page (see
`seshat-reader--multipage-prune-pending' for the other T6 hook).

The pass calls it as well when a page finally renders, so the count always
describes consecutive failures."
  (setq seshat-reader--multipage-render-failures
        (assq-delete-all page seshat-reader--multipage-render-failures)))

(defun seshat-reader--cancel-async-render-timers ()
  "Cancel both timers of the asynchronous render pass of this buffer.

`timerp' is deliberately not tested: the variables only ever hold a timer or
nil, and a plain nil test keeps the function testable with a stub
`run-at-time' that returns a symbol instead of a timer object."
  (when seshat-reader--multipage-async-idle-timer
    (cancel-timer seshat-reader--multipage-async-idle-timer))
  (setq seshat-reader--multipage-async-idle-timer nil)
  (when seshat-reader--multipage-async-render-timer
    (cancel-timer seshat-reader--multipage-async-render-timer))
  (setq seshat-reader--multipage-async-render-timer nil))

(defun seshat-reader--multipage-reset-async-state ()
  "Drop the render queue, both timers and the pending timestamp.

The one call that returns the buffer to \"no asynchronous work in flight\", and
it is only right where the queue as a whole has become meaningless: state A of
`seshat-reader--multipage-sync' (`seshat-reader-render-async' = nil) renders
every visible page synchronously and never uses the queue, so emptying it
there throws nothing away.

State C must **not** use it: the forced pass is a window-level operation while
the queue is a buffer-level resource shared by every window (decision D8), so
wiping it there drops the entries another window queued.  That case belongs to
`seshat-reader--multipage-clear-synced-pending', which drops only the pages
the pass synchronised.

Keeping the three pieces of state together means no path can clear two of them
and leave the third to age out on its own."
  (seshat-reader--multipage-pending-clear)
  (seshat-reader--cancel-async-render-timers)
  (setq seshat-reader--multipage-async-pending-since nil))

(defun seshat-reader--multipage-clear-synced-pending (range)
  "Drop what RANGE just rendered from the queue and keep everything else.

RANGE is the cons \(FIRST . LAST) the forced synchronous pass of state C
synchronised, i.e. the visible range of the calling window as
`seshat-reader--multipage-visible-range' answered it **before** that pass
touched the layout (the pass recycles out-of-range rows and inserts missing
ones, so asking afterwards answers a different range).  nil means the pass did
nothing, and then this function returns at once: the queue, the pending clock
and both timers are left exactly as they are.  There is nothing to drop in that
case, and re-arming the timers for a pass that rendered nothing would only
disguise a queue that never drains.

State C renders one window's range synchronously; the queue, however, is the
union of what every window showing this buffer asked for (decision D8).  So
only the pages RANGE covers leave the queue -- their pixels are in hand now --
and the entries another window queued stay: dropping them would leave that
window's placeholder pages without a driver, i.e. permanently blank until it
scrolls again.  That was the second exit of the D8 defect, after the pruning
fixed in T8 (`seshat-reader--multipage-prune-pending').

What is left keeps a full timeout window of its own: the forced pass just
spent this buffer's `seshat-reader-render-async-timeout', so the pending clock
is restarted here and both timers are re-armed
\(`seshat-reader--schedule-async-render').  Without the restart the surviving
entries would still carry the old timestamp, the very next command would find
them overdue again, and the net that is supposed to rescue the queue would
switch the asynchronous path off for good.

An empty queue after the drop is the one case where the whole asynchronous
state goes (`seshat-reader--multipage-reset-async-state'): nothing is left to
drive, so the queue, both timers and the timestamp all go, exactly as state C
always did.

The queue is returned, i.e. what is still pending."
  (when (consp range)
    (let ((page (car range)))
      (while (<= page (cdr range))
        (seshat-reader--multipage-pending-remove page)
        (setq page (1+ page))))
    (if seshat-reader--multipage-pending-renders
        (progn
          (setq seshat-reader--multipage-async-pending-since (float-time))
          (seshat-reader--schedule-async-render (current-buffer)))
      (seshat-reader--multipage-reset-async-state)))
  seshat-reader--multipage-pending-renders)

(defun seshat-reader--multipage-note-pending-since ()
  "Keep the pending timestamp in step with the queue.

Sets it to the current time when the queue is non-empty and has no timestamp
yet, clears it when the queue is empty.  A queue that is already aged keeps
its original timestamp, which is the point: the deadline is the age of the
*stretch*, not of the last page queued into it.  Idempotent, so every path
that leaves the queue in an unknown state (the dispatch of
`seshat-reader--multipage-sync') can call it without checking first.

The forced synchronous pass of state C does not call it any more: that pass
restarts the clock unconditionally, because the entries that survive its drop
must get a full window rather than inherit the age of the stretch that just
timed out (`seshat-reader--multipage-clear-synced-pending')."
  (cond
   ((null seshat-reader--multipage-pending-renders)
    (setq seshat-reader--multipage-async-pending-since nil))
   ((null seshat-reader--multipage-async-pending-since)
    (setq seshat-reader--multipage-async-pending-since (float-time)))))

(defun seshat-reader--multipage-async-overdue-p ()
  "Return non-nil when the render queue has outlived its timeout.

The mechanical form of the last safety net of decision D5: a non-empty queue
whose pending timestamp is older than `seshat-reader-render-async-timeout'
seconds.  Both the timestamp and the timeout are checked for being numbers, so
a buffer whose queue was filled before the timeout was ever recorded (or a
customisation that set the option to a non-number) simply reports \"not
overdue\" instead of signaling.

`float-time' is called through the symbol on purpose: the tests stub it to
move the clock without sleeping."
  (and seshat-reader--multipage-pending-renders
       (numberp seshat-reader--multipage-async-pending-since)
       (numberp seshat-reader-render-async-timeout)
       (> (- (float-time) seshat-reader--multipage-async-pending-since)
          seshat-reader-render-async-timeout)))

(defun seshat-reader--multipage-placeholder-row (page window)
  "Give PAGE a row of its final size without rendering its pixels.

PAGE is a 1-based page number and WINDOW is used only to derive the geometry
the row is about to have.  This is the synchronous half of the two-phase
render for a page whose pixels are deferred: the page size comes from the
native entry point (`seshat-reader--page-size', bounds only, microseconds) and
the row is built from it, so the layout -- and with it the scroll extent -- is
final before any bitmap exists (decision D2, and what makes the placeholder of
T3 usable at all).

The size is measured in two steps on purpose.  `--page-size' at scale 1.0
answers the *native* size of the page; feeding it temporarily into
`seshat-reader--page-native-sizes' lets
`seshat-reader--multipage-target-scale' derive the target scale through the
single fit table of decision D5 instead of a copy of it, and the second
measurement then answers the size the page will really be displayed at.  The
temporary entry is dropped when the function returns: a page is only
\"rendered\" once `seshat-reader--page-render-scales' says so, and leaving a
native size behind for a page whose bitmap does not exist would make
`seshat-reader--multipage-refit-page' measure a page it never rendered.

A page that already has a spec, or whose size cannot be measured (a module
without the entry point), is left to
`seshat-reader--multipage-insert-page': it only rewrites text properties for
an existing row and inserts an empty one for an unknown size, exactly as
before T3.  Nothing here renders."
  (unless (seshat-reader--multipage-page-spec page)
    (let* ((rotate seshat-reader--multipage-rotate)
           (native (seshat-reader--page-size page 1.0 rotate))
           (width (car-safe native))
           ;; `--page-size' 返回的是二元列表 (W H)（不是 dotted pair），与它自
           ;; 己解 C 返回值的方式保持一致。
           (height (car-safe (cdr-safe native)))
           (scale (if (and (integerp width) (> width 0)
                           (integerp height) (> height 0))
                      (let ((seshat-reader--page-native-sizes
                             (cons (cons page (cons (float width) (float height)))
                                   seshat-reader--page-native-sizes)))
                        (seshat-reader--multipage-target-scale page window))
                    (seshat-reader--multipage-target-scale page window))))
      (when scale (seshat-reader--page-size page scale rotate))
      ;; 行一律走 `--multipage-insert-page'（T3 的唯一入口）：已有的占位行只
      ;; 重写属性、不动文本，缺行则按刚测到的尺寸建一条。
      (seshat-reader--multipage-insert-page page nil window))))

(defun seshat-reader--schedule-async-render (&optional buffer)
  "Start (or restart) the asynchronous render pass of BUFFER.

BUFFER defaults to the current buffer and is only used as the argument the
two timers hand back to `seshat-reader--async-render-tick', which is what
keeps the pass running in the right buffer whatever buffer is current when a
timer fires (the `seshat-reader--schedule-refit' pattern).

Any timer armed by the previous call is cancelled first, so a burst of scroll
steps ends with exactly two timers instead of a pile of them.  Nothing is
armed while the queue is empty: an idle reader runs no timer at all.

The idle timer starts the first pass and is armed with a **nil REPEAT** on
purpose -- in a daemon Emacs an idle timer fires once per idle window whether
or not REPEAT is non-nil (probe G3b), so treating it as a repeating driver
would silently stop the queue.  The repeating timer (`run-at-time' with the
same delay as its period) is the only thing that carries the queue past the
first pulse, and it cancels itself as soon as the queue is empty.

The queue is returned, i.e. what is still pending after scheduling, which is
nil when there was nothing to do."
  (let ((buffer (or (and (buffer-live-p buffer) buffer) (current-buffer))))
    (with-current-buffer buffer
      (seshat-reader--cancel-async-render-timers)
      (when seshat-reader--multipage-pending-renders
        (let ((delay seshat-reader-render-idle-delay))
          (setq seshat-reader--multipage-async-idle-timer
                (run-with-idle-timer delay nil
                                     #'seshat-reader--async-render-tick
                                     buffer))
          ;; 周期 timer 的闭包捕获 timer 自身：buffer 被 kill 之后没有人能再读
          ;; 它的 buffer-local 变量，于是下一次 fire 由闭包自己取消，队列随
          ;; buffer 一起消失，不会留下一个永远空转的周期 timer。
          (let ((timer nil))
            (setq timer
                  (run-at-time
                   delay delay
                   (lambda (target)
                     (if (buffer-live-p target)
                         (seshat-reader--async-render-tick target)
                       (when timer (cancel-timer timer))))
                   buffer))
            (setq seshat-reader--multipage-async-render-timer timer))))
      seshat-reader--multipage-pending-renders)))

(defun seshat-reader--async-render-batch ()
  "Render at most `seshat-reader-render-idle-batch' queued pages.

The queue of the current buffer is walked in request order.  For every page
the scale is re-derived (`seshat-reader--multipage-target-scale', nil window
meaning \"the window displaying this buffer\") and the rotation is the
buffer-local one, so a page is rendered at the geometry that holds now rather
than the one it was queued at.

A successful render is written back in three steps: the spec is recorded on
the page (the native size with it), the row is filled in when the page has
one, and the failure count is cleared.  Filling in a row goes through
`seshat-reader--multipage-insert-page', i.e. through
`seshat-reader--multipage-write-row': only text properties are written, so no
marker moves and no buffer text changes, which is what the placeholder of T3
needs in order to be replaced in place.  A page without a row (a prefetched
page the viewport has not reached) is only cached -- it must not add a row,
or the scroll range would grow for a page nobody is looking at.

A nil result is a failure: the count of the page goes up by one and the page
leaves the queue, which is how it stops being retried after
`seshat-reader--multipage-render-failure-limit' attempts.  A nil returned
because the generation moved while the page was rendering is **not** a
failure -- the geometry was invalidated, not the page -- so the whole batch is
dropped instead.

The number of pages the pass actually attempted is returned."
  (let* ((generation seshat-reader--multipage-pending-generation)
         (batch (max 1 (or seshat-reader-render-idle-batch 1)))
         (queue seshat-reader--multipage-pending-renders)
         (attempted 0)
         (invalidated nil))
    (while (and queue (< attempted batch) (not invalidated))
      (let ((page (car queue)))
        (setq queue (cdr queue))
        (cond
         ((not (seshat-reader--multipage-generation-current-p generation))
          (setq invalidated t))
         ((seshat-reader--multipage-render-failed-p page)
          ;; 已放弃的页还留在队里（例如缩放前登记的），直接丢弃不再尝试。
          (seshat-reader--multipage-pending-remove page))
         (t
          (setq attempted (1+ attempted))
          (let* ((window (seshat-reader--multipage--display-window))
                 (scale (seshat-reader--multipage-target-scale page window))
                 (rotate seshat-reader--multipage-rotate)
                 (spec (seshat-reader--page-spec page scale rotate generation)))
            (cond
             ((null spec)
              (if (seshat-reader--multipage-generation-current-p generation)
                  (progn
                    (seshat-reader--multipage-note-render-failure page)
                    (seshat-reader--multipage-pending-remove page))
                (setq invalidated t)))
             (t
              (seshat-reader--multipage-reset-render-failure page)
              (seshat-reader--multipage-record-native page spec scale)
              (seshat-reader--multipage-pending-remove page)
              (when (assq page seshat-reader--pages)
                (seshat-reader--multipage-insert-page page spec window)
                ;; native 尺寸刚记录下来，目标 scale 可能因此变小（宽页在
                ;; contain/width 下按宽裁剪）；与同步路径一样只改 spec 尺寸，
                ;; 不重渲染。
                (seshat-reader--multipage-resize-spec page window)
                (seshat-reader--multipage-set-page-centered
                 page (seshat-reader--multipage-page-should-center-p
                       page window))))))))))
    (when invalidated
      (seshat-reader--multipage-pending-clear))
    attempted))

(defun seshat-reader--async-render-tick (buffer)
  "Advance the asynchronous render queue of BUFFER by one pass.

BUFFER is the buffer the timers were armed for; nothing happens when it is no
longer live (the periodic timer cancels itself in that case, see
`seshat-reader--schedule-async-render').

A pass returns immediately when one is already running: writing text
properties can re-enter this function through the post-command path, and a
nested pass would render the same page twice.

The queue is dropped, together with both timers, when it is empty or when the
generation it was filled in is no longer current -- the second case is a full
invalidation (zoom, tint, reload, relayout) that ran while the pages waited,
so their results belong to a geometry that no longer exists (decision D4).
Otherwise one bounded batch is rendered
\(`seshat-reader--async-render-batch') and the timers are left alone: the
repeating timer fires again after its period, the idle timer is **not**
re-armed -- that is the mechanical form of probe G3b, which measured that an
idle timer fires once per idle window and cannot drive a queue."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond
       (seshat-reader--multipage-async-rendering
        nil)
       ((null seshat-reader--multipage-pending-renders)
        (seshat-reader--cancel-async-render-timers)
        nil)
       ((not (seshat-reader--multipage-generation-current-p
              seshat-reader--multipage-pending-generation))
        (seshat-reader--multipage-pending-clear)
        (seshat-reader--cancel-async-render-timers)
        nil)
       (t
        (let ((seshat-reader--multipage-async-rendering t))
          (seshat-reader--async-render-batch))
        (unless seshat-reader--multipage-pending-renders
          (seshat-reader--cancel-async-render-timers))
        nil)))))

(defun seshat-reader--multipage-prefetch (window range)
  "Warm the page just beyond RANGE, the resident set of WINDOW.

RANGE is the cons (FIRST . LAST) `seshat-reader--multipage-visible-range'
returned for WINDOW, i.e. **that window's** viewport widened by the preload,
and the page is chosen from its edges: scrolling down takes the page after
LAST, scrolling up the page before FIRST.  The cross distance of the row table
\(`seshat-reader--multipage-resident-page-range') must not be used here: the
rows are kept for the union of every window showing the buffer (decision D1),
so their span reaches from one window's pages to the other's, and the edge of
that span is a page neither window is about to show -- two windows eleven
pages apart warmed the wrong end of the document systematically (decision D5
of the multi-window plan).  RANGE is also the set the page is checked against
before it is warmed: a page inside RANGE is on screen already.

WINDOW is still needed, and must not be dropped in favour of
`selected-window': the synchronous branch below renders at
`seshat-reader--multipage-target-scale' of WINDOW, so a prefetch for a
non-selected window would otherwise be pre-rendered at the wrong scale and
size.

The page is clamped to the document and skipped when it is inside RANGE,
already cached under any scale (`seshat-reader--multipage-spec-cached-p'),
already queued, or already given up on.

`seshat-reader-render-async' decides **how** the page is warmed, and this
function is the only place that decision is made -- the signature and every
call site are the same in both modes, so a caller neither knows nor cares
which half runs:

- non-nil, the default -- the page is queued
  (`seshat-reader--multipage-pending-add') and
  `seshat-reader--schedule-async-render' arms the idle first pulse and the
  periodic driver.  No row is inserted and no pixels are rendered here, so the
  resident row count stays what `--multipage-visible-range' asked for and the
  scroll step pays for neither a render nor a buffer change.  A queued page
  that a pass never reaches is dropped by the next full invalidation or prune.
- nil -- the pre-T5 behaviour, restored verbatim: the spec of the page is
  rendered right here (`seshat-reader--page-spec', at the target scale of
  WINDOW), so it lands in `seshat-reader--page-spec-cache' and the next scroll
  step finds it.  Nothing is queued and no timer is armed, because state A of
  `seshat-reader--multipage-sync' must leave no asynchronous state behind at
  all.  This is what makes the rollback switch byte-for-byte equivalent to the
  path before the two-phase render: same pages, same order, same one-page head
  start.

Errors are swallowed -- a prefetch is an optimisation and must never break
scrolling.  The page number is returned when it was warmed (queued or
rendered), nil when there was nothing to do."
  (ignore-errors
    (when range
      (let* ((direction (if (eq seshat-reader--multipage-scroll-direction -1)
                            -1 1))
             (edge (if (> direction 0) (cdr range) (car range)))
             (page (seshat-reader--multipage-clamp-page (+ edge direction))))
        (when (and page
                   (not (and (>= page (car range)) (<= page (cdr range)))))
          (if seshat-reader-render-async
              (when (seshat-reader--multipage-pending-add page)
                (seshat-reader--schedule-async-render (current-buffer))
                page)
            ;; 态 A 的同步预取：与 T5 之前的实现同口径（同样的「已缓存即跳
            ;; 过」守卫、同样按窗口算目标 scale），但**不入队、不排 timer**
            ;; —— 态 A 收尾时会把异步状态清干净，登记了也会被丢掉。走
            ;; `--page-spec' 才进缓存，这一页的提前量才真的存在。
            (unless (seshat-reader--multipage-spec-cached-p page)
              (seshat-reader--page-spec
               page
               (seshat-reader--multipage-target-scale
                page (if (window-live-p window) window (selected-window)))
               seshat-reader--multipage-rotate)
              page)))))))

(defun seshat-reader--multipage-resident-spec-megabytes ()
  "Estimate the memory the cached page specs hold, in megabytes.

The pixels of a spec live in the canvas buffer that Emacs owns and holds on
the Lisp side only as an opaque object: there is no string copy of the bitmap
in the Lisp heap any more (the old pbm backend kept one in the `:data'
property).  The estimate therefore sums `:data-width' x `:data-height' x 4
bytes per cached spec, i.e. one ARGB32 pixel per device pixel.

Specs that carry no `:data-width'/`:data-height' fall back to
`:width' x `:height' x 4: that counts the logical size and implicitly assumes
a device pixel ratio of 1, so it under-estimates on a scaled frame.  The
fallback exists for specs the canvas renderer never produced (a placeholder
row, or a stub in a test); a spec with neither pair is skipped.  nil is
returned when nothing measurable is cached."
  (let ((bytes 0)
        (seen 0))
    (dolist (entry seshat-reader--page-spec-cache)
      (let* ((spec (cdr entry))
             (dw (and spec (image-property spec :data-width)))
             (dh (and spec (image-property spec :data-height))))
        (unless (and (integerp dw) (integerp dh) (> dw 0) (> dh 0))
          (setq dw (and spec (image-property spec :width))
                dh (and spec (image-property spec :height))))
        (when (and (integerp dw) (integerp dh) (> dw 0) (> dh 0))
          (setq bytes (+ bytes (* dw dh 4)))
          (setq seen (1+ seen)))))
    (when (> seen 0)
      (/ (float bytes) (* 1024.0 1024.0)))))

(defun seshat-reader--multipage-check-memory (&optional _window)
  "Report once per buffer when the resident page bitmaps exceed the budget.

The budget is `seshat-reader-multipage-memory-warning-mb'; the estimate comes
from `seshat-reader--multipage-resident-spec-megabytes'.  The warning is
recorded in `seshat-reader--multipage-memory-warned' so that it fires once per
buffer (scrolling would otherwise repeat it on every command), and the flag is
cleared when the document is reloaded or the cache is dropped.

WINDOW is accepted for symmetry with the other sync helpers and is not used."
  (unless seshat-reader--multipage-memory-warned
    (let ((budget seshat-reader-multipage-memory-warning-mb)
          (megabytes (seshat-reader--multipage-resident-spec-megabytes)))
      (when (and (numberp budget) (numberp megabytes)
                 (> megabytes budget))
        (setq seshat-reader--multipage-memory-warned t)
        (message "seshat-reader: %d page specs hold about %.0f MB of bitmaps (budget %s MB); consider lowering seshat-reader--multipage-preload or the render resolution"
                 (length seshat-reader--page-spec-cache)
                 megabytes budget)))))

(defun seshat-reader--multipage-sync-blocking (&optional window force)
  "Keep the resident page rows of WINDOW in sync with its viewport.

This is the synchronous half of `seshat-reader--multipage-sync', moved here
verbatim when the two-phase render landed (P2-B T6): it renders every page of
the visible range in page order and warms the page just beyond it.  It is
called as-is when `seshat-reader-render-async' is nil -- the rollback path --
and by the timeout net of the asynchronous path, which is why its body is
deliberately untouched: \"byte for byte equivalent\" has to be auditable by
diffing this function against the pre-T6 one.

WINDOW defaults to the selected window.  The pages
`seshat-reader--multipage-visible-range' asks for are rendered when they
are missing and every page outside the **union** of what all windows on this
buffer show (`seshat-reader--multipage-resident-pages', decision D1) is
recycled, so the buffer only holds the pages some window can see plus the
preload around them -- with one window that is exactly its own range.  The
range of
the previous run of this window is remembered in the window parameter
`seshat-reader--range-parameter' and an unchanged range returns at once, which
keeps the `post-command-hook'
entry from redoing the work on every command.  Nothing is done while a sync
is already running, which is what stops a buffer modification made here
from re-entering through `window-state-change-functions'.  The range that
was synchronised is returned, or nil when there was nothing to do.

FORCE non-nil bypasses that early return **and** the bookkeeping: the range is
not recorded, so a forced pass leaves the window with the range of the
previous unforced one and the next `seshat-reader--multipage-sync' for the
same range redoes the work.  \"Forced\" therefore never means \"already
synchronised\" (decision D6); that contract used to be kept by binding the
buffer-local record around the call, which the per-window parameter replaced.

Scrolling never changes the zoom: the base scale is read by
`seshat-reader--multipage-target-scale' and is only ever written by the zoom
commands and `seshat-reader--first-fit', so a page pulled in here is rendered
at exactly the same scale as the pages that were already on screen
\(decision D5's reference page anchoring).

Once the range is settled the page just beyond it in the scrolling direction is
prefetched (`seshat-reader--multipage-prefetch') and the memory budget is
checked, so the frame that scrolls one page further finds its bitmap ready
instead of blocking on the native renderer.  Which half does the warming
depends on `seshat-reader-render-async': queued for the asynchronous pass by
default, rendered synchronously (the pre-T5 behaviour) when it is nil -- this
function stays the single prefetch call site in both modes.  The rendering of
the visible pages is what `seshat-reader--multipage-sync' moves off this path
when the asynchronous pass is enabled."
  (let* ((win (or window (selected-window)))
         (range (and (window-live-p win)
                     (not seshat-reader--multipage-syncing)
                     (eq (window-buffer win) (current-buffer))
                     (seshat-reader--multipage-visible-range win))))
    (when (and range
               (or force
                   (not (equal range
                               (seshat-reader--multipage-last-range-for win)))))
      (let ((seshat-reader--multipage-syncing t)
            (first (car range))
            (last (cdr range)))
        ;; FORCE 只作用于本次调用：跳过写回，于是「强制同步」之后该窗口记的仍是
        ;; **上一次**同步的区间 —— 强制同步 ≠ 已同步（D6）。照常写回的话，下一次
        ;; 同一区间的 `--multipage-sync' 会因区间相等而早退，那是可观察的行为变化。
        (unless force
          (seshat-reader--multipage-set-last-range win range))
        ;; 回收按**并集**、渲染按本窗口（D1）：行表 `seshat-reader--pages' 是
        ;; buffer 唯一的一份，另一个窗口还在显示的页不能因为本窗口滚走就被删 ——
        ;; 删行会把那个窗口的 `window-start' 一起往前拖，正是真机现象 1。
        ;; 并集在**改动 buffer 之前**取快照：`--multipage-visible-range' 的页号
        ;; 来自 `window-start' 的 `page-at-pos'，渲染插行 / 回收删行都会让
        ;; `window-start' 落到另一个页行上，取得越晚越可能漏掉本轮真正可见的页。
        ;; 放在渲染循环之前，并集必然包含本窗口本轮的 RANGE。
        ;; 只算一次：循环内每页重算就是「行数 × 遍历所有 frame 的窗口」，见
        ;; `seshat-reader--multipage-page-near-resident-p' 的 KEEP 说明。
        (let ((keep (seshat-reader--multipage-resident-pages win))
              (page first))
          (while (<= page last)
            (seshat-reader--multipage-render-page page nil win)
            (setq page (1+ page)))
          (dolist (entry (copy-sequence seshat-reader--pages))
            (let ((page (car entry)))
              (when (not (memq page keep))
                (seshat-reader--multipage-recycle-page page keep)))))
        ;; 区间定型后才预热与体检：此时驻留集就是最终的视口 ± preload。
        ;; 预取边界用**本窗口**的 RANGE（D5）：行表按并集保留，跨距的边界可能
        ;; 是另一个窗口那一端的页。
        (seshat-reader--multipage-prefetch win range)
        (seshat-reader--multipage-check-memory win))
      range)))

(defun seshat-reader--multipage-sync (&optional window)
  "Keep the resident page rows of WINDOW in sync with its viewport.

The entry point of every scroll step (post-command-hook, window state
changes, the cross-page scroll commands and zoom/goto), and the dispatcher of
the three states of the two-phase render (P2-B T6):

  A. `seshat-reader-render-async' is nil -- the asynchronous machinery is
     dropped (queue, both timers, the pending timestamp) and
     `seshat-reader--multipage-sync-blocking' does exactly what the whole
     function did before T6: every page of the visible range rendered
     synchronously, in page order, then the synchronous prefetch
     (`seshat-reader--multipage-prefetch' takes its nil-mode branch and renders
     the page itself) and the memory check.
  B. asynchronous, the rule -- the page point is on and the page one step
     further in `seshat-reader--multipage-scroll-direction' are rendered
     synchronously (`seshat-reader--page-spec', so the reader never looks at a
     blank page where it is reading), every other page of the visible range
     gets its row built at its final size but no pixels
     (`seshat-reader--multipage-placeholder-row') and is queued
     (`seshat-reader--multipage-pending-add' +
     `seshat-reader--schedule-async-render'), the queue is pruned to the union
     of the visible ranges of every window on the buffer
     (`seshat-reader--multipage-all-visible-pages') and the pages that just
     came back into view get their failure count cleared
     (`seshat-reader--multipage-reset-render-failure').
  C. asynchronous and overdue -- the queue has been non-empty for longer than
     `seshat-reader-render-async-timeout', i.e. neither the idle nor the
     periodic timer managed to drain it; the visible range of this window is
     rendered synchronously and its pages leave the queue, while the entries
     other windows queued stay (`seshat-reader--multipage-force-sync' drops
     those pages through `seshat-reader--multipage-clear-synced-pending').  Both
     timers are re-armed for what is left, and dropped only when nothing is
     left.  This is the net that keeps a broken timer from leaving the reader
     on blank pages.

The returned value is unchanged in all three states: the range that was
synchronised, or nil when there was nothing to do.  The four groups of callers
\(see the docstring of `seshat-reader--multipage-sync-blocking') only look at
that value and at the side effects on the layout, so splitting the body behind
the switch is invisible to them."
  (if (not seshat-reader-render-async)
      ;; 态 A：逐页同步渲染 + 预取。先丢掉异步侧的状态，切回异步时不会拿一份
      ;; 「旧几何 + 已渲染」的队列继续跑；队列非空时把所有窗口的「上次同步区间」
      ;; 作废，迫使本轮的 blocking 真正重做一遍范围（否则区间没变即早退，占位页会
      ;; 一直空白）。必须遍历**所有**显示本 buffer 的窗口：只清本窗口会留下
      ;; 「行表已空 + 另一窗口的区间恰好相等 → 早退 → 行永不重建」的永久空白。
      (progn
        (when seshat-reader--multipage-pending-renders
          (seshat-reader--multipage-clear-last-ranges))
        (seshat-reader--multipage-reset-async-state)
        ;; 同步路径的预取现在按开关分流（`--multipage-prefetch' 内部）：态 A 下
        ;; 它同步取 spec、不入队、不排 timer，所以这里跑完的第二次清理只是兜底
        ;; （防某条尚未覆盖的路径留下残留），不再是「丢掉预取页」的代价。
        (prog1 (seshat-reader--multipage-sync-blocking window)
          (seshat-reader--multipage-reset-async-state)))
    (let* ((win (or window (selected-window)))
           (range (and (window-live-p win)
                       (not seshat-reader--multipage-syncing)
                       (eq (window-buffer win) (current-buffer))
                       (seshat-reader--multipage-visible-range win))))
      (cond
       ((null range) nil)
       ((seshat-reader--multipage-async-overdue-p)
        (seshat-reader--multipage-force-sync win))
       ((equal range (seshat-reader--multipage-last-range-for win)) range)
       (t (seshat-reader--multipage-sync-async win range))))))

(defun seshat-reader--multipage-sync-async (window range &optional force)
  "Render the within-reach pages of RANGE and queue the rest (state B).

WINDOW is the live window the range belongs to and RANGE is the cons
\(FIRST . LAST) `seshat-reader--multipage-visible-range' returned for it.
FORCE non-nil keeps this pass from recording RANGE as the range WINDOW was
synchronised for, exactly like the same argument of
`seshat-reader--multipage-sync-blocking' (decision D6).  No caller passes it
today -- the only forced path goes through the blocking half -- but the
argument exists so that an asynchronous forced pass, if one is ever added,
cannot silently turn \"forced\" into \"already synchronised\"; the bookkeeping
is wrapped in `unless' rather than the argument left unbound, which would be
a void variable.

The two pages rendered here are the page point is on and the page one step
further in `seshat-reader--multipage-scroll-direction', i.e. the one the
reader is reading and the one the next scroll reveals; both are clamped into
the document.  Every other page of the range gets its row first -- measured
with `seshat-reader--page-size' and built at the size it will finally have, so
the scroll extent is final before any pixel exists (decision D1/D2, and the
reason T3 introduced the placeholder row) -- and is then queued.

The queue is pruned afterwards to the pages **any** window on this buffer keeps
visible (`seshat-reader--multipage-all-visible-pages', decision D8) and not to
RANGE: the queue is buffer-local and shared, so trimming it to one window's
range would delete the entries another window queued.  Rendering and the failure
clearing below still walk RANGE only, because the layout is per window and only
the queue is shared; **recycling** does not, it keeps every page another window
still shows (`seshat-reader--multipage-resident-pages', decision D1) -- deleting
a row another window displays would drag that window's `window-start' forward.
Pruning is what keeps pages nobody can see from ever being rendered, and the
pages that were not in the previous range get their failure count cleared so
that a transient failure is never turned into a permanent one (the second
clearing point the non-blocking-render invariant requires).

Rows outside the union are recycled exactly like the synchronous path does, and
both the prefetch and the memory check run once the range is settled, so the
buffer state after this function is the one the blocking path would leave,
except that the pixels of the queued pages do not exist yet.

The monitored range is returned."
  (let ((seshat-reader--multipage-syncing t)
        (first (car range))
        (previous (seshat-reader--multipage-last-range-for window))
        ;; 回收口径的快照必须在**改动 buffer 之前**取（D1）：渲染插行 / 回收删行
        ;; 都会让 `window-start' 落到另一个页行上，而 `--multipage-visible-range'
        ;; 的页号正是由 `window-start' 的 `page-at-pos' 得来 —— 取得越晚，并集
        ;; 越可能漏掉本轮真正可见的页（本窗口的 RANGE 一定包含在内）。
        ;; 只算一次：循环内每页重算 = 每行都遍历一遍所有 frame 的窗口。
        (keep (seshat-reader--multipage-resident-pages window))
        (pages (number-sequence (car range) (cdr range))))
    ;; FORCE 下不写回，与 blocking 对称（D6）：强制同步 ≠ 已同步。
    (unless force
      (seshat-reader--multipage-set-last-range window range))
    (let* ((point-page (or (seshat-reader--multipage-page-at-pos (point))
                           (seshat-reader--multipage-page-at-pos
                            (window-start window))
                           first))
           (direction (if (eq seshat-reader--multipage-scroll-direction -1)
                          -1
                        1))
           (sync-pages (delq nil
                             (list point-page
                                   (seshat-reader--multipage-clamp-page
                                    (+ point-page direction))))))
      (dolist (page pages)
        (if (memq page sync-pages)
            (progn
              (seshat-reader--multipage-render-page page nil window)
              ;; 刚同步渲染完的页若还在队里（上一次登记的），立刻出队：它的像素
              ;; 已经到位，再让 tick 处理一遍只是白跑一趟。
              (seshat-reader--multipage-pending-remove page))
          (seshat-reader--multipage-placeholder-row page window)
          (seshat-reader--multipage-pending-add page))))
    ;; 回收按**并集**、渲染与失败清零按本窗口（D1、陷阱 1）：PAGES 只喂渲染
    ;; 与失败清零；回收用所有窗口的可见页并集（KEEP，函数入口处取的快照），
    ;; 否则另一个窗口还在显示的行会被本窗口这一轮删掉（删行拖前它的
    ;; `window-start'）。
    (dolist (entry (copy-sequence seshat-reader--pages))
      (let ((page (car entry)))
        (when (not (memq page keep))
          (seshat-reader--multipage-recycle-page page keep))))
    ;; 队列是 buffer-local 的，每个显示本 buffer 的窗口共用一份，所以裁剪口径
    ;; 必须是「所有窗口的可见页并集」而不是本窗口的 PAGES：后者会把另一个窗口
    ;; 刚登记的队项剪掉（D8 的缺陷，T8 修复）。渲染与失败清零仍然只看本窗口的
    ;; PAGES —— 布局是窗口的，只有队列是共享的；回收已在上面改成并集（D1）。
    (seshat-reader--multipage-prune-pending
     (seshat-reader--multipage-all-visible-pages window))
    (dolist (page pages)
      (when (and (not (and previous
                           (>= page (car previous))
                           (<= page (cdr previous))))
                 (> (seshat-reader--multipage-render-failure-count page) 0))
        (seshat-reader--multipage-reset-render-failure page)))
    (seshat-reader--multipage-prefetch window range)
    (seshat-reader--multipage-check-memory window)
    (seshat-reader--schedule-async-render (current-buffer))
    (seshat-reader--multipage-note-pending-since)
    range))

(defun seshat-reader--multipage-force-sync (window)
  "Render the whole visible range of WINDOW synchronously (state C).

The timeout net: the queue has been non-empty for longer than
`seshat-reader-render-async-timeout', so the timers are not doing their job
\(or Emacs never went idle) and the pages they were supposed to fill in are
still blank.  The synchronous path is run with FORCE, i.e. with the early
return of `seshat-reader--multipage-sync-blocking' bypassed and its bookkeeping
skipped: it really redoes the range instead of returning early on the unchanged
one (the asynchronous step already recorded it), and it does not record the
range either -- a forced pass is not a synchronised one.

Only the pages of that pass leave the queue
\(`seshat-reader--multipage-clear-synced-pending'): state C is a window-level
operation while the queue is a buffer-level resource shared by every window
\(decision D8), so emptying it here would drop the entries another window
queued and leave its placeholder pages without a driver -- blank until it
scrolls again.  That was the second exit of the D8 defect (T9); the first one
was the pruning of T8.  Whatever survives the drop (another window's pages,
plus the page the synchronous prefetch queues) gets its pending clock
restarted and both timers re-armed, so it has a full timeout window of its own.

The range used for the drop is the one `seshat-reader--multipage-sync-blocking'
returns: it computes it on entry, before any row is recycled or inserted, i.e.
exactly the \"before the layout changed\" value the drop must be keyed on -- and
it is nil when the pass did nothing, in which case nothing is dropped either.

The range the synchronous pass synchronised is returned."
  ;; FORCE 形参（D6）**有意**只作用于本次调用：它让
  ;; `--multipage-sync-blocking' 绕过「区间未变即早退」的检查、真正重做一遍范围，
  ;; 同时跳过写回 —— 强制同步之后该窗口记的仍是上一次同步的区间，下一次
  ;; `--multipage-sync' 因此仍会重做（「强制同步 ≠ 已同步」）。改成「先 setq nil
  ;; 再调用」会让强制同步之后留下本次区间，下一次 `--multipage-sync' 就因区间未变
  ;; 而早退，那是可观察的行为变化，故维持 FORCE 形参 + 本注释。
  (let ((synced (seshat-reader--multipage-sync-blocking window t)))
    (seshat-reader--multipage-clear-synced-pending synced)
    synced))


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
      (seshat-reader--multipage-render-page
       target nil (seshat-reader--multipage--display-window))
      (seshat-reader--multipage--show-page target)
      (seshat-reader--multipage-sync)
      (let ((pos (seshat-reader--multipage--show-page target)))
        ;; 页内滚动偏移不得被目标页继承：整页跳转一律停在页首。
        (when (eq (window-buffer (selected-window)) (current-buffer))
          (set-window-vscroll (selected-window) 0 t))
        pos))))

(defun seshat-reader--multipage-page-pixel-height (page)
  "Return the pixel height of the row of PAGE, or 0 when it is unknown.

PAGE is a 1-based page number.  The height comes from
`seshat-reader--multipage-page-display-size', so a rendered page answers with
the `:height' of its spec and a page whose pixels are still to be delivered
answers with the measured height of the same page -- the two numbers are
equal, which is what keeps the scroll extent stable while a page is filled in.
0 means the size is unknown (a failed render of a page that was never
measured); the scroll code treats that as an empty page rather than dividing
by an unknown."
  (or (cdr-safe (seshat-reader--multipage-page-display-size page)) 0))

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

(defun seshat-reader--multipage-separator-pixels (&optional window)
  "Return the nominal pixel height of the separator after a page row.

That is `seshat-reader-page-separator-height' default text lines, rounded to
whole pixels, one line being `seshat-reader--default-line-pixels' high.  The
answer is 0 — never nil — when `seshat-reader-page-separator' is nil or its
height is not positive, so that callers can add it without a nil test.
WINDOW defaults to the selected one and is only used to find the frame."
  (let ((height seshat-reader-page-separator-height))
    (if (and seshat-reader-page-separator
             (numberp height)
             (> height 0))
        (round (* height (seshat-reader--default-line-pixels window)))
      0)))

(defun seshat-reader--multipage-separator-segments (&optional window)
  "Return the separator geometry as (TOP LINE BOTTOM), in pixels.

This is the single source of truth for the geometry of the region: the scroll
arithmetic and the construction of the rows both take their numbers from here
and must not compute them on their own.  Two computations would drift apart,
and the bottom of a page would then get a dead scroll zone, the bug
`seshat-reader--multipage-page-max-offset' documents for the gap lines.

TOP and BOTTOM are the blank space above and below the rule, LINE is the
thickness of the rule, and the three add up to what
`seshat-reader--multipage-separator-pixels' returns.  nil means the region
takes no space and the reader can skip it altogether.  LINE is clamped to
TOTAL, and a non-numeric `seshat-reader-page-separator-thickness' counts as
0: the same reading `seshat-reader--multipage-separator-pixels' takes of a
non-numeric height, so a bad customisation shrinks the rule instead of
signalling out of the scroll arithmetic.  WINDOW defaults to the selected one
and is only used to find the frame."
  (let ((total (seshat-reader--multipage-separator-pixels window)))
    (when (> total 0)
      (let* ((line (min (if (numberp seshat-reader-page-separator-thickness)
                            (max 0 seshat-reader-page-separator-thickness)
                          0)
                        total))
             (top (/ (- total line) 2)))
        (list top line (- total line top))))))

(defun seshat-reader--multipage-separator-extra-pixels (&optional window)
  "Return the pixels the separator renders beyond its nominal height.

`seshat-reader--multipage-separator-pixels' answers with the **nominal** height
of the region -- the sum of the three segments
`seshat-reader--multipage-separator-segments' reports -- but the region renders
taller than that, and the scroll arithmetic has to know by how much.

The rule row is the reason.  `seshat-reader--multipage-separator-row' builds it
as a stretch space, `(space :align-to (- right 0))', painted by
`seshat-reader-page-separator-face' with a `:height' ratio equal to LINE
divided by the default line height.  A stretch space takes the height of one
default text line no matter what the face asks for: the `:height' ratio is
simply ignored for that row, which is why the rule row measures a full
`seshat-reader--default-line-pixels' instead of the LINE segment.  The two blank
rows above and below it are ordinary text lines and do honour their `:height'
ratio, so the padding is exact and only the rule row drifts.  Measured on a
real frame: default 0.5 line of separator on a 20px line is 10px nominal and
28px actual -- an 18px drift, i.e. exactly CHAR-HEIGHT minus THICKNESS
\\(reproduced with 25/35/17px line heights: +25/+33/+15).

The drift is therefore CHAR-HEIGHT minus the effective thickness of the rule,
and this function returns it, with these boundaries:

- 0 when `seshat-reader-page-separator' is off or the region takes no space
  (`--multipage-separator-segments' returns nil), because no rule row exists.
- 0 when the effective LINE of that geometry is 0 -- a non-numeric or
  non-positive `seshat-reader-page-separator-thickness', or a total that the
  clamp leaves with no thickness -- because a region without a rule row has
  nothing that can grow.
- 0 when the character height cannot be read at all, so that a frame without a
  usable font never turns into an error inside the scroll code.
- Otherwise `max 0 (CHAR-HEIGHT - LINE)'.  LINE is taken from
  `--multipage-separator-segments' itself rather than recomputed from the
  customisation, so the `min THICKNESS TOTAL' clamp and the \"non-numeric counts
  as 0\" reading exist in exactly one place and the geometry cannot drift from
  the compensation.

Why the compensation lives here and not in the row: giving the rule row a
smaller `:height' does not work (a stretch space ignores it, see above) and
shortening the row would change what the reader looks like.  The layout is the
fixed point and the arithmetic follows it -- the visual must not get narrower,
that being the user's call, so the missing pixels are added to the number the
scroll code uses.  Without them every page is short by one character height,
and the error accumulates into the landing point of a cross-page scroll: five
pages on a 20px line lose 90px.

WINDOW defaults to the selected one and is only used to find the frame."
  (let ((segments (seshat-reader--multipage-separator-segments window)))
    (if (null segments)
        0
      (let ((line (nth 1 segments)))
        (if (and (numberp line) (> line 0))
            (let ((height (ignore-errors
                            (seshat-reader--default-line-pixels window))))
              (if (numberp height) (max 0 (- height line)) 0))
          0)))))

(defun seshat-reader--multipage-page-gap-pixels (&optional window)
  "Return the pixel height of everything that follows a page row.

Three parts add up here: the gap lines, i.e. `seshat-reader-page-gap-lines'
empty lines of one default line height each
\(`seshat-reader--default-line-pixels'), plus the separator region of
`seshat-reader--multipage-separator-pixels', plus the pixels that region
renders beyond its nominal height
\(`seshat-reader--multipage-separator-extra-pixels' -- the rule row is a
stretch space and therefore one character height tall whatever thickness the
geometry asks for).  All of them sit between a page row and the row of the next
page, so the scroll code needs their sum: this function answers with what the
layout **measures**, not with what the customisation nominally asks for, and
every scroll number downstream inherits that.

None of the parts is taken with `line-pixel-height', which would report the
height of the page row the gap belongs to.  The value is 0 when all parts are
0.  WINDOW defaults to the selected one and is only used to find the frame."
  (let ((lines (max 0 seshat-reader-page-gap-lines)))
    (+ (if (> lines 0) (* lines (seshat-reader--default-line-pixels window)) 0)
       (seshat-reader--multipage-separator-pixels window)
       (seshat-reader--multipage-separator-extra-pixels window))))

(defun seshat-reader--multipage-page-span (page)
  "Return the pixel distance from the top of PAGE's row to the next row.

That is the page height plus the gap that follows it, floored at 1 so that the
scrolling loop always advances: a page without a rendered spec has a span of
0 pixels otherwise, and stepping through it would never move the target.

The gap is the measured one, separator drift included (see
`seshat-reader--multipage-page-gap-pixels'), so the span is the real distance
from this page row to the next one and a cross-page scroll lands where the
pixels say it should.  Computing the gap from the customisation alone would
short-change every page by one character height and lose that much on each
crossing."
  (max 1 (+ (seshat-reader--multipage-page-pixel-height page)
            (seshat-reader--multipage-page-gap-pixels))))

(defun seshat-reader--multipage-page-max-offset (page &optional window)
  "Return the largest vertical scroll, in pixels, that PAGE allows.

PAGE is a 1-based page number and WINDOW is the window the scroll happens in;
a missing or non-live WINDOW defaults to the selected one.  Clamping to this
value is what stops the scroll loop when there is no page left to cross.

A page with a follower allows one pixel less than its **span** (page height
plus the gap that follows it, see `seshat-reader--multipage-page-span'), or 0
for a page without a rendered spec.  The ceiling must cover the gap, not just
the bitmap: the scroll loop crosses to the next page when
`window-vscroll + step` reaches the span, so a ceiling of `page-height - 1`
would clamp back every attempt to accumulate the gap pixels -- those pixels
are neither inside the page nor past the span, so the page bottom became a
dead zone (with a positive `seshat-reader-page-gap-lines` the reader could
never scroll past the gap pixels of a page).  Using the span keeps the
crossing test and the clamp on the same number.

The last page of the document is bounded differently: no page follows it to
fill the rest of the window, so allowing the whole span would push the page
entirely out of the viewport and leave blank space below the document.  Its
ceiling is the page height minus the pixel body height of WINDOW, i.e. the
page bottom stops at the bottom of the window; the value is never negative (a
page that already fits the window allows no in-page offset at all) and never
larger than `span - 1`.  The gap is subtracted by that difference, which is
why the page height -- not the span -- is the left operand.

The document page count is nil while a document is loading or after a reload;
that state counts as \"not the last page\", which keeps the behaviour of the
pages the buffer holds.  A one-page document therefore falls back to the
non-last-page formula until the page count arrives, so for that short while it
can still be scrolled past its own bottom; the ceiling heals itself as soon as
the count is known."
  (let* ((win (if (window-live-p window) window (selected-window)))
         (span (seshat-reader--multipage-page-span page))
         (count (seshat-reader--multipage-pagecount)))
    (if (and count (>= page count))
        (max 0 (min (1- span)
                    (- (seshat-reader--multipage-page-pixel-height page)
                       (or (window-body-height win t) 0))))
      (max 0 (1- span)))))

(defun seshat-reader--multipage-page-neighbour (page delta)
  "Return the page DELTA pages away from PAGE, or nil when there is none.

DELTA is -1 or 1.  The result is clamped to the document, so the caller can
use a nil answer to stop scrolling at the first or the last page."
  (let ((target (seshat-reader--multipage-clamp-page (+ page delta))))
    (and target (/= target page) target)))

(defun seshat-reader--multipage--scroll-to-page (window page)
  "Put the row of PAGE at the top of WINDOW, leaving scroll and point alone.

PAGE is a 1-based page number and the row is rendered first when it is not
resident yet, so scrolling into a page the resident set has not reached works.

\"Leaving scroll and point alone\" means that this function never writes either
of them: the caller computes the final in-page offset only after this call and
sets it itself, and `seshat-reader--multipage--place-point` decides where point
has to be once the offset is known.  The vertical scroll is nevertheless reset
*implicitly* here, because `set-window-start` without its NOFORCE argument makes
the window start a fresh one and Emacs drops the pixel scroll that belonged to
the old start; the page-crossing path uses that side effect to clear the offset
of the previous page.  `seshat-reader--multipage-goto` is not used on purpose,
since it resets the vertical scroll explicitly.  The row position is returned,
or nil when PAGE has no row."
  (unless (assq page seshat-reader--pages)
    (seshat-reader--multipage-render-page page nil window))
  (when-let* ((entry (assq page seshat-reader--pages))
              (pos (marker-position (cadr entry))))
    (set-window-start window pos)
    pos))

(defun seshat-reader--multipage--place-point (window page vscroll)
  "Put point on a row the scrolled viewport of WINDOW actually shows.

WINDOW is the window that was just scrolled, PAGE is the page its top shows
\(1-based) and VSCROLL is the vertical scroll the window received, i.e. the
value the caller clamped before handing it to `set-window-vscroll`.

Point has to follow the scroll: Emacs drops a pixel scroll on the next
redisplay when the top of the window start line is cut off *and* point sits on
that line, because the cursor would be invisible -- so the scroll silently
returns to 0.  Real-frame probe: a 2000px scroll on a page row start vanished
after one redisplay.  Moving point to the row of the page *after* PAGE keeps it
visible (that row starts `span - VSCROLL` pixels below the top of the window)
and the scroll then survives.

Point is moved only when all three conditions hold: the page row start is
really out of sight, i.e. VSCROLL is larger than one text line of WINDOW; the
next page has a row; and that row starts inside the pixel body height of
WINDOW.  A body height that cannot be measured counts as 0, the same reading
`seshat-reader--multipage-page-max-offset` uses, so the answer degrades to the
row start of PAGE instead of signalling.  Otherwise point goes to the row start
of PAGE too, which is the old behaviour and correct there: a small offset leaves
the cursor partially visible, and a page without a follower has nothing to put
point on.

The row of the next page is read from `seshat-reader--pages' and never
rendered here, because this function must not modify the buffer: it runs after
`seshat-reader--multipage-sync` settled the resident set, so an insertion now
would send the sync through its recycling pass again.  For the same reason the
row below is not taken with `(forward-line 1)`: with a positive
`seshat-reader-page-gap-lines` the line after PAGE is one of the gap lines that
belong to PAGE itself, whose screen position is `page height - VSCROLL` --
negative after an upward crossing, i.e. invisible once more."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (assq page seshat-reader--pages))
    (let* ((below-page (seshat-reader--multipage-page-neighbour page 1))
           (below (and below-page
                       (when-let* ((entry (assq below-page seshat-reader--pages))
                                   (marker (cadr entry)))
                         (marker-position marker))))
           (own (when-let* ((entry (assq page seshat-reader--pages))
                            (marker (cadr entry)))
                  (marker-position marker)))
           (target (if (and (> vscroll
                                (seshat-reader--default-line-pixels window))
                            below
                            ;; 取不到窗口体高时按 0 处理：条件不成立，落点退回
                            ;; 顶页行首，与 `--multipage-page-max-offset' 同口径
                            (<= (- (seshat-reader--multipage-page-span page)
                                   vscroll)
                                (or (window-body-height window t) 0)))
                       below
                     own)))
      (when target
        (with-selected-window window (goto-char target))))))

(defun seshat-reader--multipage--apply-offset (window offset)
  "Give WINDOW the pixel vertical scroll OFFSET once its start has settled.

WINDOW may be nil, which stands for the selected window: it is resolved as
`(if (window-live-p window) window (selected-window))', the same reading
`seshat-reader--multipage-scroll' and `seshat-reader--multipage-sync' use.  The
argument itself is therefore never tested with `window-live-p' alone -- nil has
to be accepted, otherwise the offset could never be restored.  Nothing happens
when the resolved window is not live or OFFSET is not a positive number; that
guard replaces the `ignore-errors' the callers used to need, so real errors are
no longer swallowed.  Invalid arguments skip the frame too: an offset that will
not be written must not cost a redisplay.

Emacs drops a pixel scroll that is set in the same frame as a *new* window
start: `set-window-start' followed by `set-window-vscroll' inside one command
ends up with a scroll of 0 (real-frame probe: 3090 -> 0), while the same offset
survives once the new start has been displayed.  Restoration paths such as
`seshat-reader-bookmark-jump' move the window start first, so they have to force
a frame here before writing OFFSET.  The FORCE argument of `redisplay' is on
purpose: the frame must happen even under an inhibited redisplay.

That forced frame runs `pre-redisplay-functions' and may re-center the page,
which rewrites the centering property of the page rows (the `:align-to' of the
`before-string', `line-prefix' for a page wider than the window) and the
horizontal scroll.  The order is still safe: centering touches neither
`window-start' nor the vertical pixel scroll nor the row structure, and OFFSET
is written after the frame, while the caller sets `hscroll' after this call.
`seshat-reader--multipage-scroll' is the same constraint in another form, inside
the page-crossing sequence, where the sync gives the new start its own frame."
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (and (window-live-p win)
               (numberp offset)
               (> offset 0))
      (redisplay t)
      (set-window-vscroll win offset t))))

(defun seshat-reader--multipage-scroll (pixels &optional window)
  "Scroll WINDOW vertically by PIXELS, continuing across page boundaries.

WINDOW defaults to the selected window.  A positive PIXELS scrolls the view
down (towards later pages), a negative one up.

Every page is one buffer line whose height is the page image, so the built-in
line scrolling (`scroll-up` / `scroll-down`) jumps a whole page at a time and
makes in-page scrolling impossible.  This function therefore moves the window
in two steps: the vertical scroll of the window is used for the part of the
distance that stays inside the current page, and when the distance leaves the
page the window start is moved to the neighbouring page row and the remainder
becomes the new vertical scroll.  That is what makes the scrolling continuous:
reaching the bottom of a page continues into the next one instead of resetting.

The vertical scroll is always pixelwise (Emacs measures `window-vscroll` in
lines otherwise) and clamped to [0, height - 1] of the page at the top of the
window, so a page can never be scrolled past its own end and the clamp -- not
the loop condition -- is what stops at the first and the last page.  Every
iteration advances the page, so a page without a spec cannot loop forever.
The resident rows are synchronised before the scroll is written, which pulls
in the pages the new viewport asks for, and the scroll is written last so that
it gets the final word on the window state.  Two ways of losing the offset must
be kept apart.  Confirmed on a real frame: Emacs drops a pixel scroll that is
set in the same frame as a *new* window start -- `set-window-start` followed by
`set-window-vscroll` inside one command ends up with a scroll of 0 (3090 -> 0),
while the same offset survives when the new start has been displayed first.
Not confirmed: whether the buffer modification made by
`seshat-reader--multipage-sync` clears the scroll on its own (the probe that
blamed it had that sync return early), so the order below is defensive about it
rather than proven necessary.

A crossing therefore runs in two frames: it drops the offset of the old page,
moves the window start, syncs, forces `redisplay` -- so that the new start and
the buffer modification land in their own frame -- and only then writes the
offset, which now sticks.  The forced frame shows the new page at offset 0,
which is the price of the scheme, and it is forced on purpose so that an
inhibited redisplay cannot swallow it.  Scrolling inside a page skips all of
it: no forced frame, no extra cost.  The point placement below reads the offset
to decide whether the row start of the page is still visible, so it runs last.

Crossing a page also has to move point (`seshat-reader--multipage--place-point`,
called with the clamped offset and only when a page was crossed): the row start
of the page now at the top is cut off by the vertical scroll, and Emacs resets
the scroll to 0 on the next redisplay when point sits on a line that is scrolled
out of sight.  That reset was the reason an upward cross page fell back to the
top of the previous page."
  (let ((win (if (window-live-p window) window (selected-window))))
    (when (and (eq (window-buffer win) (current-buffer))
               seshat-reader--pages
               (numberp pixels)
               (/= pixels 0))
      ;; 预取方向：往下滚预热下一页，往上滚预热上一页
      (setq seshat-reader--multipage-scroll-direction (if (> pixels 0) 1 -1))
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
                (seshat-reader--multipage-render-page page nil win)))
          ;; 向上：对称，补上上一页的行高（+gap）后才成为该页的页内偏移
          (while (and (< distance 0)
                      (seshat-reader--multipage-page-neighbour page -1))
            (setq page (1- page)
                  moved t)
            (unless (assq page seshat-reader--pages)
              (seshat-reader--multipage-render-page page nil win))
            (setq distance (+ distance (seshat-reader--multipage-page-span page)))))
        ;; 跨页序列（两帧方案）：清旧偏移 → 设新 start → sync → 强制落帧 → 写偏移。
        ;; - 落帧那一帧是「新页 + 偏移 0」的中间态（偏移此时还没写），这是两帧
        ;;   方案的固有代价；快速连滚时理论上可见一帧跳动，要消除它必须同时重估
        ;;   Emacs 的「同帧丢弃偏移」行为。
        ;; - 这里的 (set-window-vscroll win 0 t) 与 set-window-start 的隐式重置
        ;;   语义重叠：保留它是防御 + 表达意图，不是功能必需。
        ;; - 已确证的清零源只有「与新设 window-start 同帧的偏移被丢弃」；sync 修改
        ;;   buffer 是否单独清零偏移未确证（那次探针里 sync 早退了）。
        ;; - 同一约束在书签 / saveplace 的恢复路径由
        ;;   `seshat-reader--multipage--apply-offset' 承担（goto 之后先落帧再写偏移）。
        (when moved
          (set-window-vscroll win 0 t))
        (when moved
          (seshat-reader--multipage--scroll-to-page win page))
        (seshat-reader--multipage-sync win)
        ;; force 是有意的：落帧必须无条件发生，不能被 inhibit-redisplay 静默吞掉
        (when moved
          (redisplay t))
        (let ((offset (max 0 (min distance
                                  (seshat-reader--multipage-page-max-offset page win)))))
          (set-window-vscroll win offset t)
          (when moved
            (seshat-reader--multipage--place-point win page offset)))
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
         ;; 几何窗口先解析一次，重排循环里复用：显式传参比让每个渲染函数自己
         ;; 猜更可靠（minibuffer 激活时「猜」会拿到 mini window）。
         (window (seshat-reader--multipage--display-window))
         (preload (seshat-reader--multipage-effective-preload))
         (count (seshat-reader--multipage-pagecount))
         (first (max 1 (- target preload)))
         (last (if count (min count (+ target preload)) (+ target preload))))
    (let ((inhibit-read-only t))
      (erase-buffer))
    ;; 与 `--render-buffer' 同一纪律：buffer 正文由原生模块生成，重排后
    ;; `erase-buffer' 留下的 modified 标志必须清掉，否则 modeline 显示 `**'、
    ;; super-save 一类包会把重生成内容写回原文件。
    (set-buffer-modified-p nil)
    (seshat-reader--multipage-clear)
    (setq seshat-reader--page-native-sizes nil
          seshat-reader--page-render-scales nil
          ;; 旋转会交换页面的宽高，基准页尺寸随之作废；下一次 `W'/`H'/`0'
          ;; 会退回视口顶页重新测量。
          seshat-reader--multipage-reference-native nil)
    (let ((number first))
      (while (<= number last)
        (seshat-reader--multipage-render-page number nil window)
        (setq number (1+ number))))
    (seshat-reader--multipage-goto target)
    (seshat-reader--center-page)))

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

(defun seshat-reader--multipage-row-nearest (pos)
  "Return the page row closest to POS as a cons (PAGE . MARKER), or nil.

The rows are sorted by page, so \"closest\" is the last row that starts at or
before POS -- the page the reader was looking at when POS moved off a row --
and only a POS before every row falls through to the first row after it.  nil
means there is no row at all.

`seshat-reader--multipage-page-at-pos' cannot answer this: it reports the page
*containing* POS and nothing else, so it returns nil for a POS that is before
the first row or past the end of the buffer, and it has no notion of \"the
nearest row\" for a POS that sits between two of them.  The re-anchor of
`seshat-reader--ensure-window-layout' needs exactly the row to move back to,
which is why the lookup lives here (decision D3)."
  (when (and seshat-reader--pages (integer-or-marker-p pos))
    (let ((previous nil)
          (next nil))
      (dolist (entry seshat-reader--pages)
        (let ((start (marker-position (cadr entry))))
          (cond ((and start (<= start pos)) (setq previous entry))
                ((and start (null next)) (setq next entry)))))
      (or previous next))))

(defun seshat-reader--ensure-window-layout (window)
  "Make WINDOW show the multi-page layout of the current buffer.

Registered buffer-locally on `window-state-change-functions', which is what
gives a new window, a resized window and a window that just switched to
this buffer their layout.  The window gets its starting fit mode recorded,
its resident pages synchronised and its rows centred for its own width --
a new window can be wider or narrower than the one the rows were placed
for.  When the window start is no longer at the start of a page row, the
window is moved to the **nearest** page row, so that the page number derived
from the viewport stays what the reader was looking at.

A scroll is a trigger path as well, and not only a native one: any scroll that
leaves `window-start' in the middle of a page row or on a blank line between
two rows -- `scroll-up' / `scroll-down', `recenter', a wheel event, the pixel
scrolling of a GUI frame alike -- is pulled back to the start of the nearest
page row on the next `window-state-change-functions' run, so the viewport
cannot come to rest between rows.  That is the deliberate price of anchoring
to the nearest row (a blank line between two rows carries no page number of
its own, so it belongs to the page above it) and not a defect; see
`docs/emacs-reader.md', section 7, \"已知限制（多窗口滚动）\", item 2.

The anchor used to be the smallest resident page -- the `first' fallback of
`seshat-reader--multipage-window-start-page' -- which pinned a window to the
lower edge of the whole layout: with the rows kept for the union of every
window (decision D1) that edge belongs to the *other* window, so window B was
dragged from page 12 to the pages window A was reading.  The nearest row is
this window's own page, and it is the reason the re-anchor still runs for
every window the hook reports and not only for the selected one: a
`split-window', a buffer switch, a `--render-buffer' reload and the rows a
recycle deletes all change the state of a window that is not current, and this
function is the only place that puts such a window back on a page row (D3).
`seshat-reader--multipage-window-start-page' itself is untouched: five callers
derive the page number to display from it, where its `first' fallback is the
right answer."
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
        ;; 顺序不可换：sync 会插行 / 删行并移动 marker，锚点必须在它之后算。
        (seshat-reader--multipage-sync window)
        (when seshat-reader--pages
          (let* ((start (window-start window))
                 (entry (seshat-reader--multipage-row-nearest start)))
            ;; 只在起点不在页行行首时移动：落在页行中间、页间空行或最后一个
            ;; 页行之后都算「不在行首」，回到该行行首后页号就稳定了。
            ;; 不需要重入守卫：守卫是严格 (< (marker-position entry) start)，
            ;; 而这里写入的正是页行 marker 的精确行首位置，锚定后
            ;; start 与 marker 位置相等、下一轮守卫即为 nil —— 自终止，最多
            ;; 多跑一轮。若将来锚点改成非幂等逻辑（写入位置不等于该行行首），
            ;; 必须补重入守卫，否则会与 window-state-change 互相触发。
            (when (and entry (< (marker-position (cadr entry)) start))
              (set-window-start window (marker-position (cadr entry))))))
        (seshat-reader--ensure-centered window)))))

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

(defun seshat-reader--layout-frozen-p ()
  "Return non-nil when the page layout has to be left alone for now.

The layout is frozen while `seshat-reader-freeze-layout-during-minibuffer'
is non-nil and a minibuffer is active, which is decided by
`window-minibuffer-p' on the selected window: that is a structural property
of the window, so recursive minibuffers and child frame minibuffers are
covered.  The more precise alternative is `minibuffer-window-active-p', which
also checks that the minibuffer is the *active* one; the two only disagree
when the user manually selects a non-active minibuffer window of another
frame, and freezing a layout nobody is looking at costs nothing, so the
simpler test is used.

Freezing is UX only -- correctness comes from
`seshat-reader--multipage--display-window', which never returns a minibuffer
window -- and the refit that puts the layout back is scheduled by
`seshat-reader--after-minibuffer-exit'.  Three callers honour it:
`seshat-reader--refit-window', `seshat-reader--schedule-refit' and the
`seshat-reader--apply-display-scale' step of
`seshat-reader--recenter-window'."
  (let ((window (selected-window)))
    (and seshat-reader-freeze-layout-during-minibuffer
         (windowp window)
         (window-minibuffer-p window))))

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
refit when the drag stops.

Nothing is resized while the layout is frozen for an open minibuffer
\(`seshat-reader--layout-frozen-p'): that skips
`seshat-reader--apply-display-scale', so the specs keep the size they were
laid out for and the pages are merely cropped by the smaller window instead
of shrinking with it, until `seshat-reader--after-minibuffer-exit' refits
them once the prompt is closed.  Centring still runs, because it rewrites the
leading space of the rows and the horizontal scroll but never the spec sizes
\(`seshat-reader--center-page' does not touch `:width'/`:height'; only
`seshat-reader--multipage-resize-spec' does), and so does the sync, which only
keeps the resident rows in step with the viewport."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'seshat-reader-mode)
        (condition-case err
            (progn
              ;; 拖拽中（两次 size-change 间隔小于阈值）只居中不缩放：改 spec 尺寸
              ;; 会让 redisplay 重新缩放整页位图，拖动时每帧一次会卡 1–2 秒。
              ;; 停手后由 idle 的 `--refit-window' 做一次几何适配 + 重渲染。
              ;; minibuffer 展开期间（`--layout-frozen-p'）同理跳过缩放：这才是
              ;; 真正的「几何冻结」——居中只改行首 space 与 hscroll，不改 spec 尺寸，
              ;; 故页面按旧尺寸显示、底部被窗口裁切，退出后由 exit-hook 排的 refit
              ;; 恢复（见 `seshat-reader--after-minibuffer-exit'）。
              (let ((dragging (and seshat-reader--last-size-change-delta
                                   (< seshat-reader--last-size-change-delta
                                      seshat-reader--drag-threshold)))
                    (frozen (seshat-reader--layout-frozen-p)))
                (unless (or dragging frozen)
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
refit is being applied (`seshat-reader--refitting'), when refitting is
disabled, or while the layout is frozen for an open minibuffer
\(`seshat-reader-freeze-layout-during-minibuffer'): a refit changes the
window layout itself, so queueing another one from inside it only feeds the
loop, and freezing has to skip the timer as well as `--refit-window' or the
timer would simply run the refit a moment later."
  (unless (or seshat-reader--refitting
              (not seshat-reader--resize-refit-enabled)
              (seshat-reader--layout-frozen-p))
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

Nothing is done while the layout is frozen for an open minibuffer
\(`seshat-reader--layout-frozen-p'): the pages then keep the size they were
laid out for and are merely cropped by the smaller window, and
`seshat-reader--after-minibuffer-exit' refits them once the prompt is gone.

The window is skipped silently when it is no longer live, no longer shows
the current buffer, or shows a buffer that has left `seshat-reader-mode'.  An
error while refitting one window is reported and does not prevent the other
windows from being refitted."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             ;; 中文：minibuffer 展开期间不重量几何（纯 UX 冻结，正确性由
             ;; `--multipage--display-window' 保证）。判据集中在上面那个
             ;; predicate 里，避免两处写入不同的判据。
             (not (seshat-reader--layout-frozen-p)))
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

(defun seshat-reader--after-minibuffer-exit ()
  "Refit the reader layout the minibuffer was opened from, once it is closed.

Registered on `minibuffer-exit-hook'.  With
`seshat-reader-freeze-layout-during-minibuffer' the layout is left alone
while the prompt is open, so this is what puts it back without asking the
user for one more keypress.  With that switch nil nothing is scheduled at
all: the layout was never frozen, every size change refits the windows as it
happens, and a timer here would only redo that work -- which is also why the
hook itself is installed unconditionally and the switch is read here, so
toggling the option takes effect without reloading the file.

The buffers to refit are collected from two sources, in this order:

1. `minibuffer-selected-window', i.e. the window that was selected before
   the minibuffer was entered.  Measuring Emacs 31.1 shows why this, and not
   `(selected-window)', has to come first: inside `minibuffer-exit-hook' the
   selected window is *still* the mini window and `(minibuffer-depth)' is
   still 1 (the depth is decremented after the hook runs), so resolving the
   buffer from `(selected-window)' answers ` *Minibuf-1*' (measured:
   `(depth 1 sel-buffer \" *Minibuf-1*\" mb-selected-win \"*probe-plain*\")').

2. Every window of every frame that shows a `seshat-reader-mode' buffer.
   `window-list' with a nil FRAME only lists the selected frame, which would
   miss a reader window on another frame, so `(frame-list)' is walked
   explicitly; `'nomini' drops the minibuffer window, whose buffer
   (` *Minibuf-N*') could never be a reader buffer and whose 102 px strip is
   no geometry to refit against.  This is the fallback for the cases where
   source 1 answers nil -- a child frame minibuffer, a mouse driven
   minibuffer -- and an extra safety net when the hook runs from an
   unexpected current buffer.

The buffers found that way are de-duplicated with `memq', so a buffer shown
in two windows is refitted once: `seshat-reader--run-pending-refit' already
walks every window of its buffer.  Each buffer then gets one one-shot idle
timer.  The timer handle is deliberately dropped: `--run-pending-refit'
clears `seshat-reader--resize-refit-timer' and is idempotent (a scale within
`seshat-reader--refit-scale-tolerance' is not rendered again), so the extra
timers a nested minibuffer arms -- one exit per depth -- are harmless.

The refit is not routed through `seshat-reader--schedule-refit': that gate
reads `seshat-reader--layout-frozen-p', which is still true here (the mini
window is still selected), and a timer armed now would have to outlive the
freezing anyway.  An idle timer of our own runs after the command loop has
returned from the minibuffer, where the depth is 0 and the reader window is
selected again.

Nothing happens when no window shows a `seshat-reader-mode' buffer, e.g. a
prompt opened from a non-reader buffer."
  (when seshat-reader-freeze-layout-during-minibuffer
    (let ((buffers nil)
          (primary (minibuffer-selected-window)))
      ;; 主路径：进 minibuffer 之前选中的窗口在 hook 里仍可信（它已经不是
      ;; mini window 了，退出时窗口树已复原）。
      (when (and (windowp primary) (window-live-p primary))
        (let ((buffer (window-buffer primary)))
          (when (and (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (derived-mode-p 'seshat-reader-mode)))
            (push buffer buffers))))
      ;; 兜底：`window-list' 的 FRAME 传 nil 只列 selected frame，故显式遍历
      ;; `(frame-list)' 才能覆盖其它 frame 上的 reader 窗口；`'nomini' 排除
      ;; minibuffer 窗口（buffer 是 ` *Minibuf-N*'，不可能是 reader buffer，
      ;; 也没有可 refit 的几何）。已收集的 buffer 用 `memq' 跳过。
      (dolist (frame (frame-list))
        (dolist (window (window-list frame 'nomini))
          (let ((buffer (window-buffer window)))
            (when (and (buffer-live-p buffer)
                       (not (memq buffer buffers))
                       (with-current-buffer buffer
                         (derived-mode-p 'seshat-reader-mode)))
              (push buffer buffers)))))
      ;; 中文：不用 `--schedule-refit'——它的冻结判据在此刻仍为真（selected
      ;; window 还是 mini window），会把自己挡掉；idle timer 在 read_minibuf
      ;; 返回、主循环 idle 后才跑，那时 depth 已归零、窗口已复原，最稳。
      (dolist (buffer (nreverse buffers))
        (run-with-idle-timer 0 nil #'seshat-reader--run-pending-refit buffer)))))

;; `minibuffer-exit-hook' 是全局 hook：加载本文件时挂一次即可。`add-hook' 不会
;; 重复添加同一个函数，故多次 `load'/`require' 是幂等的。
(add-hook 'minibuffer-exit-hook #'seshat-reader--after-minibuffer-exit)


;; Scrolling is pixel based, not line based: a page is one buffer line whose
;; height is the page image, so the built-in line scrolling (`scroll-up' /
;; `scroll-down' / `scroll-up-command') jumps a whole page per call and leaves
;; no way to scroll inside a page.  The commands below therefore ask
;; `seshat-reader--multipage-scroll' for a pixel distance, which moves the
;; window start to the neighbouring page row when the distance leaves the page
;; and keeps the remainder as the window's pixel vertical scroll.  Nothing
;; here turns a page: `n' / `p' stay on `seshat-reader--multipage-goto'.

;; 前置声明：两个 defcustom 定义在文件后部的选项区（`screen-context-lines' 附近），
;; 而读取它们的函数在这里，先声明让字节编译器知道它们是 special variable；真正的
;; 默认值与 `:type' 仍由后面的 `defcustom' 给出（`defvar' 不设值，不覆盖默认值）。
(defvar seshat-reader-scroll-step-ratio)
(defvar seshat-reader-scroll-step-pixels)

(defun seshat-reader--scroll-line-pixels (&optional window)
  "Return the pixel height of one *text* line in WINDOW.

WINDOW defaults to the selected window.  This is the unit of the screen-scroll
overlap (`seshat-reader-screen-context-lines') and of the page gap, not the
unit of a scroll step: a step is configurable
\(`seshat-reader--scroll-step-pixels').

It is deliberately not `line-pixel-height': the line under point is a page row
whose height is the whole page bitmap, so one \"line\" of it would be a whole
page — the bug that made `j' turn pages.  `seshat-reader--default-line-pixels'
returns the frame's character height instead."
  (seshat-reader--default-line-pixels window))

(defun seshat-reader--scroll-step-pixels (&optional window)
  "Return the pixel distance of one scroll step of WINDOW.

WINDOW defaults to the selected window.  A step is what one press of
\\[seshat-reader-scroll-down] / \\[seshat-reader-scroll-up], one wheel notch and
one `<remap> next-line' move by.

`seshat-reader-scroll-step-pixels' wins when it is a positive integer: an
absolute distance that does not change with the window.  Otherwise the step is
`seshat-reader-scroll-step-ratio' times the pixel height of the window's *text
area* (the PIXELWISE argument of `window-body-height'), so the mode line and the
header line are never counted: a step must not grow by the height of the mode
line.  A ratio that is not a positive number, or one that rounds to less than a
pixel, falls back to one default text line
\(`seshat-reader--default-line-pixels'), so a scroll step can never end up moving
0 pixels and the commands keep working whatever the option holds."
  (let ((window (if (window-live-p window) window (selected-window))))
    (or (and (integerp seshat-reader-scroll-step-pixels)
             (> seshat-reader-scroll-step-pixels 0)
             seshat-reader-scroll-step-pixels)
        (let* ((ratio seshat-reader-scroll-step-ratio)
               (height (window-body-height window t))
               (pixels (and (numberp ratio) (> ratio 0)
                            (numberp height) (> height 0)
                            (round (* ratio height)))))
          (if (and (integerp pixels) (>= pixels 1))
              pixels
            (seshat-reader--default-line-pixels window))))))

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
  "Scroll the view upward by AMOUNT steps, one step by default.

The text moves down and the content above comes into view, continuously across
the page boundary: a page is one buffer line, so the built-in line scrolling
would jump a whole page.  How far one step travels is decided by
`seshat-reader-scroll-step-ratio' / `seshat-reader-scroll-step-pixels' through
`seshat-reader--scroll-step-pixels'.

`seshat-reader--multipage-scroll' moves the view and synchronises the resident
page rows afterwards, so scrolling into a page that was not rendered yet renders
it on the spot.

Reaching the beginning of the buffer is a normal outcome, not an error: a
signal raised by the scroll primitive (`beginning-of-buffer') is swallowed
here, so the wheel neither dings nor prints `Beginning of buffer' at the top
of the document."
  (interactive "p")
  (ignore-errors
    (seshat-reader--multipage-scroll
     (- (* (or amount 1) (seshat-reader--scroll-step-pixels))))))

(defun seshat-reader-scroll-down (&optional amount)
  "Scroll the view downward by AMOUNT steps, one step by default.

The text moves up and the content below comes into view, continuously across
the page boundary, for the reason and with the step size given in
`seshat-reader-scroll-up'."
  (interactive "p")
  (ignore-errors
    (seshat-reader--multipage-scroll
     (* (or amount 1) (seshat-reader--scroll-step-pixels)))))

(defun seshat-reader-scroll-up-screen (&optional amount)
  "Scroll the view upward by one screen, or by AMOUNT steps.

One screen is the pixel body height of the window minus
`next-screen-context-lines' lines, so a line of context stays visible.  A screen
is a whole view, not a step, so `seshat-reader-scroll-step-ratio' does not
affect it.  Switching pages stays on `n' / `p'."
  (interactive "P")
  (if amount
      (seshat-reader-scroll-up amount)
    (ignore-errors
      (seshat-reader--multipage-scroll
       (- (seshat-reader--scroll-screen-pixels))))))

(defun seshat-reader-scroll-down-screen (&optional amount)
  "Scroll the view downward by one screen, or by AMOUNT steps.

One screen is the pixel body height of the window minus
`next-screen-context-lines' lines, so a line of context stays visible.  A screen
is a whole view, not a step, so `seshat-reader-scroll-step-ratio' does not
affect it.  Switching pages stays on `n' / `p'."
  (interactive "P")
  (if amount
      (seshat-reader-scroll-down amount)
    (ignore-errors
      (seshat-reader--multipage-scroll
       (seshat-reader--scroll-screen-pixels)))))

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

The wheel delta is read from the event: one scroll step for a single notch, two
or three for a double or triple one, so the notch count multiplies
`seshat-reader--scroll-step-pixels'.  See also `seshat-reader-scroll-up'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('wheel-up 1)
		   ('double-wheel-up 2)
		   ('triple-wheel-up 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (ignore-errors (seshat-reader-scroll-up amount)))))

(define-queue-command mwheel-scroll-down (event)
  "Scroll the view down, but also handle mouse EVENT.

The wheel delta is read from the event: one scroll step for a single notch, two
or three for a double or triple one, so the notch count multiplies
`seshat-reader--scroll-step-pixels'.  See also `seshat-reader-scroll-down'."
  (interactive "e")
  (let* ((event-type (car event))
	 (amount (pcase event-type
		   ('wheel-down 1)
		   ('double-wheel-down 2)
		   ('triple-wheel-down 3)))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (ignore-errors (seshat-reader-scroll-down amount)))))

(defun seshat-reader-mwheel-precision-scroll (event)
  "Handle the wheel EVENT of `pixel-scroll-precision-mode' with our own step.

`pixel-scroll-precision-mode' is a **global** minor mode, so its keymap sits on
`minor-mode-map-alist' and outranks the local `seshat-reader-mode-map': the
wheel events bound there (`<wheel-up>', `<mode-line> <wheel-down>',
`<left-fringe> <wheel-up>' and friends) all resolve to
`pixel-scroll-precision', which scrolls by the raw pixel delta of the event and
raises `beginning-of-buffer' / `end-of-buffer' at the document limits (seen on
a real session).  `seshat-reader-mode-map' remaps that command to this one.

The direction is read from the event symbol, so one notch scrolls exactly one
`seshat-reader--scroll-step-pixels' step of `seshat-reader-scroll-up' /
`seshat-reader-scroll-down' — the same semantics as the plain `<wheel-up>' /
`<wheel-down>' bindings of this mode — and the pixel delta is only used as a
fallback when the event carries no direction symbol (a trackpad gesture)."
  (interactive "e")
  (pcase (car-safe event)
    ((or 'wheel-up 'double-wheel-up 'triple-wheel-up)
     (seshat-reader-mwheel-scroll-up event))
    ((or 'wheel-down 'double-wheel-down 'triple-wheel-down)
     (seshat-reader-mwheel-scroll-down event))
    (_
     ;; 没有方向符号：按像素增量的符号判方向。`pixel-scroll-precision' 里
     ;; `delta' 为 `(nth 4 event)' 的 cdr 取整，且 `delta' 为负时走它自己的
     ;; `-scroll-down'（内容下移、露出上文），与本 mode 的
     ;; `seshat-reader-scroll-up' 同义。
     (let ((delta (cdr-safe (nth 4 event))))
       (cond ((not (numberp delta)) nil)
             ((< delta 0) (seshat-reader-mwheel-scroll-up event))
             ((> delta 0) (seshat-reader-mwheel-scroll-down event)))))))

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
  "Zoom in with the wheel, but also handle mouse EVENT.

A single notch passes `seshat-reader-enlarge-factor' as the multiplier and a
double or triple notch a slightly larger one, so the wheel goes through the
very same path as `+' (`seshat-reader-enlarge-size'): the multiplier is
applied to the base scale and the visible pages are re-rendered."
  (interactive "e")
  (let* ((event-type (car event))
	 (scaling-factor (pcase event-type
			   ('C-wheel-up seshat-reader-enlarge-factor)
			   ('C-double-wheel-up (+ seshat-reader-enlarge-factor 0.1))
			   ('C-triple-wheel-up (+ seshat-reader-enlarge-factor 0.2))))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-enlarge-size scaling-factor))))

(defun seshat-reader-mwheel-shrink-size (event)
  "Zoom out with the wheel, but also handle mouse EVENT.

Mirrors `seshat-reader-mwheel-enlarge-size': the notch picks the multiplier that
is handed to `seshat-reader-shrink-size', which multiplies the base scale."
  (interactive "e")
  (let* ((event-type (car event))
	 (scaling-factor (pcase event-type
			   ('C-wheel-down seshat-reader-shrink-factor)
			   ('C-double-wheel-down (- seshat-reader-shrink-factor 0.1))
			   ('C-triple-wheel-down (- seshat-reader-shrink-factor 0.2))))
	 (scrolled-window (car (cadr event))))
    (with-selected-window scrolled-window
      (seshat-reader-shrink-size scaling-factor))))

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
`seshat-reader-dyn--load-doc', which only builds the native document state;
the pages are displayed by the rows of the multi-page layout.  The buffer is
then emptied, the rows around PAGE are rendered and the window is left
showing PAGE."
  (interactive)
  (if-let* ((file (buffer-file-name (current-buffer))))
      (when (file-exists-p file)
	(let* ((p (if (numberp page) (max 0 page) 0))
	       (window (selected-window)))
	  (seshat-reader-dyn--load-doc file p)
	  ;; 页行由本函数重建，旧的页行/标记全部作废。
	  (let ((inhibit-read-only t))
	    (erase-buffer))
	  (seshat-reader--multipage-clear)
	  ;; 页面按 1.0 重画，窗口参数里的缩放与尺寸缓存全部复位。
	  (set-window-parameter window 'scale 1.0)
	  (set-window-parameter window 'render-scale nil)
	  (set-window-parameter window 'native-size nil)
	  ;; 按页的几何缓存随重载一起作废：native 尺寸与渲染 scale 都是上一份
	  ;; 文档的位图量出来的，缩放基准重新由 `--first-fit' 推导（基准页尺寸也
	  ;; 一并作废，否则 `W'/`H'/`0' 会用上一份文档的页面尺寸算 base）。
	  (setq seshat-reader--multipage-base-scale 1.0
	        seshat-reader--multipage-reference-native nil
	        seshat-reader--page-native-sizes nil
	        seshat-reader--page-render-scales nil)
	  ;; 位图随重载失效，按页缓存的 spec 不能再复用；清缓存失败不得中断重载。
	  (ignore-errors (seshat-reader--page-spec-clear-cache))
	  (let* ((target (or (seshat-reader--multipage-clamp-page (1+ p)) 1))
		 (preload (seshat-reader--multipage-effective-preload))
		 (count (seshat-reader--multipage-pagecount))
		 (first (max 1 (- target preload)))
		 (last (if count (min count (+ target preload))
			 (+ target preload)))
		 (number first))
	    (while (<= number last)
	      (seshat-reader--multipage-render-page number nil window)
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

  ;; `pixel-scroll-precision-mode'（全局 minor mode）的键表优先级高于本 mode 的
  ;; 局部键表，滚轮会被它接管并改成按像素增量滚动（到 buffer 首尾抛
  ;; `Beginning of buffer' / `End of buffer'）。命令重映射在命令解析之后才查，
  ;; 因此下面几条能把滚轮收回本 mode；`pixel-scroll-precision' 是它绑在
  ;; `<wheel-up>' / `<wheel-down>' / 各种前缀上的命令，另两个是它内部调用的滚动
  ;; 函数（老版本可能直接绑它们，一并重映射；命令不存在时重映射条目无害）。
  "<remap> <pixel-scroll-precision>" #'seshat-reader-mwheel-precision-scroll
  "<remap> <pixel-scroll-precision-scroll-up>" #'seshat-reader-scroll-up
  "<remap> <pixel-scroll-precision-scroll-down>" #'seshat-reader-scroll-down

  ;; 同上，`pixel-scroll-mode'（非 precision 版本）也可能在别的配置里打开。
  "<remap> <pixel-scroll-up>" #'seshat-reader-scroll-up
  "<remap> <pixel-scroll-down>" #'seshat-reader-scroll-down

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

(defcustom seshat-reader-scroll-step-ratio 0.15
  "Fraction of the window text height scrolled by one step.

A step is what \\[seshat-reader-scroll-down] and
\\[seshat-reader-scroll-up] move by (one line, one wheel notch, or a
`<remap> next-line' press), so this option decides how far one keypress
travels: 0.15 moves about a seventh of the visible text area.

The ratio is taken from the pixel height of the window's text area
\(`window-body-height' with the PIXELWISE argument), which excludes the mode
line and the header line: scrolling must never be computed from the whole
frame height, or a step would silently grow by the height of the mode line.

`seshat-reader-scroll-step-pixels', when non-nil, overrides this ratio."
  :type 'number
  :group 'seshat-reader)
;; 中文：一次滚动步长占窗口**文本区**高度的比例（不含 mode-line / header-line）。
;; 0.15 ≈ 一屏的七分之一，连按 j 时有段落感而不至于一次跨半页。

(defcustom seshat-reader-scroll-step-pixels nil
  "Absolute pixel distance of one scroll step, or nil to use the ratio.

When non-nil this overrides `seshat-reader-scroll-step-ratio' and every scroll
step is exactly this many pixels, whatever the window size is: it is meant for
users who want the speed of \\[seshat-reader-scroll-down] pinned to a value
instead of scaling with the window.

A non-positive value is ignored and the ratio is used instead, because a step
of 0 pixels would make the scroll commands silently do nothing."
  :type '(choice (const :tag "Use the ratio of the window height" nil)
                 (integer :tag "Fixed pixel distance"))
  :group 'seshat-reader)
;; 中文：绝对像素步长；非 nil 时**优先**于上面那个比例，适合把滚动速度钉死、
;; 不随窗口大小变化的人。非正数视同 nil（否则一次滚动 0 像素＝按键没反应）。

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

;;; hl-line 关闭（多页布局下一行 = 一整页）

(defun seshat-reader--disable-hl-line ()
  "在阅读 buffer 里关掉 `hl-line-mode'.

多页布局下阅读 buffer 的「一行」就是一整页图像：`hl-line' 的 overlay 按行
边界（`line-beginning-position' / `line-end-position'）染色，于是把当前页那
一行的**左右留白**也染成 `hl-line' 底色（实测 #2A2E38），而上下相邻页的行仍
是主题底色（#242730）——同屏两页两侧留白颜色不一致。留白不属于任何页面
位图，染色只暴露「这个 buffer 其实是文本行」这一实现细节。

`global-hl-line-mode' 是**全局化** minor mode，它在
`after-change-major-mode-hook' 上为每个新 major mode 重新打开
`hl-line-mode'；因此 mode body 里直接 `(hl-line-mode -1)' 关不住——body 先
跑、hook 后跑，同 `seshat-reader--disable-evil' 遇到的时序坑。本函数由
`seshat-reader-mode' 以 DEPTH t 追加到该 hook 的 **buffer-local** 值末尾：
实测（Emacs 31.1）本地值成为 `(t FUNC)'，运行时全局部分先跑、FUNC 后跑，
故关闭能粘住；本地值里那个标记元素同时保证全局化的其他 minor mode 在本
buffer 仍照常运行（buffer-local 值不会顶掉全局 hook）。

只对 `seshat-reader-mode' 系列 buffer 生效——侧栏 / 大纲 / 标注列表等列表
导航仍需要 hl-line，它们的 buffer 上不会注册本函数。"
  (when (bound-and-true-p hl-line-mode)
    (hl-line-mode -1)))

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
  ;; 阅读 buffer 是**只读渲染视图**：正文由原生模块生成、buffer 永远只读，
  ;; undo 历史对用户没有任何用途。但 `find-file' 会把整份文档读进 buffer，
  ;; 随后 `seshat-reader--render-buffer' 的 `erase-buffer' 把这整份内容记成
  ;; 一次 undo「saved text」（多页布局的重排还会反复全量重写，再记一份），
  ;; 于是 undo 记录量 ≈ 文件大小。实测打开 32,085,636 字节的 PDF 时，undo
  ;; 记录达到 32,086,307 字节，被 `undo-outer-limit' 判超限，Emacs 丢弃整份
  ;; 记录并弹警告，白占内存。故在渲染之前把 `buffer-undo-list' 置 t（关闭
  ;; 记录）——治本，而不是调大 `undo-outer-limit'（那只是把内存与崩溃风险往后
  ;; 推）。必须早于下面的 `--render-buffer'：`erase-buffer' 一旦跑过就已经记
  ;; 上了。
  (setq-local buffer-undo-list t)
  (set-buffer-modified-p nil)
  (seshat-reader--disable-evil)
  ;; `global-hl-line-mode'（全局化 minor mode）会在
  ;; `after-change-major-mode-hook' 上把 `hl-line-mode' 重新打开，故这里只注册
  ;; 收尾函数、不在 body 里直接关：DEPTH t 让本地值成为 `(t FUNC)'，全局部分
  ;; （含全局化 checker）先跑、FUNC 后跑，关掉才粘得住。见
  ;; `seshat-reader--disable-hl-line'。
  (add-hook 'after-change-major-mode-hook #'seshat-reader--disable-hl-line t t)
  (setq-local next-screen-context-lines
              (max 0 seshat-reader-screen-context-lines))
  (blink-cursor-mode 0)
  (auto-revert-mode 1)
  (setq-local revert-buffer-function #'seshat-reader--non-queue-refresh-doc-buffer)

  ;; `pixel-scroll-precision-mode' 是**全局** minor mode：它的键表挂在
  ;; `minor-mode-map-alist' 上，优先级高于本 mode 的局部键表，于是滚轮事件根本
  ;; 不到 `seshat-reader-mode-map' 的 `<wheel-up>' / `<wheel-down>'，而是走
  ;; `pixel-scroll-precision'；到 buffer 首尾时它抛 `Beginning of buffer' /
  ;; `End of buffer'（真机复现）。以前这里用
  ;; `(setq-local pixel-scroll-precision-mode nil)' 想按 buffer 关掉它，但局部
  ;; 绑定对全局 minor mode 无效（`bound-and-true-p' 读的是全局值），所以那些键
  ;; 一直是它接管的。
  ;; 正确做法是**按键重映射**：命令重映射（`[remap CMD]'）在命令解析之后才查，
  ;; 会越过更高优先级的 minor-mode 键表命中本 mode 的键表，故键表里的
  ;; `"<remap> <pixel-scroll-precision>"' 等条目能把滚轮收回本 mode。见
  ;; `seshat-reader-mode-map'。

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
another buffer is left alone.

The render below happens before the per-window loop, so it has to pick one
window for the geometry: it uses the window the buffer is really displayed
in (`seshat-reader--multipage--display-window'), which is what keeps a
document-wide re-render from measuring the minibuffer window while a prompt
is open.  The sizes each window ends up with are set by the loop anyway."
  (ignore-errors (seshat-reader--page-spec-clear-cache))
  (let ((window (seshat-reader--multipage--display-window)))
    (dolist (page (seshat-reader--multipage-page-numbers))
      (seshat-reader--multipage-rerender-page page window)))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (with-selected-window window
      (seshat-reader--multipage-sync window)
      (seshat-reader--apply-display-scale window)
      (seshat-reader--center-page window)))
  (force-mode-line-update))

(declare-function seshat-reader-dyn--doc-tint "seshat-render-core" (bg fg))

(defconst seshat-reader-dark-tint-presets
  '((graphite    . (-1 . -1))          ; 哨兵：走旧的 invert+gamma 路径
    (midnight    . (#x1c1c22 . #xc8c4ba))
    (charcoal    . (#x26262b . #xa8a49a))
    (night-sepia . (#x201d18 . #xc0b49c))
    (sepia       . (#xe8dfc8 . #x3a342a)))
  "暗色模式各预设的像素映射端点.

每项是 (NAME . (BG . FG))，BG / FG 都是 `#xRRGGBB' 整数：原生模块把页面
里最白的像素（页面的底）映射到 BG、最黑的像素（文字）映射到 FG（双端压
缩），因此彩色图会变成单色调。注意方向：BG 是「底」而不是「深色」，
`sepia' 的 BG 就是亮色，所以它渲染成亮底暗字而不是暗底亮字。

唯一例外是 `graphite'，它的 (-1 . -1) 是哨兵，表示「不下发 tint」，
像素仍走改动前的满量程反色（`fz_invert_pixmap_luminance' + gamma 1/1.4），
观感与旧版逐位一致，是配色的一键回退口。

新增预设只改本表，不需要改 C 侧、也不需要重编动态模块。")

(defcustom seshat-reader-dark-tint 'charcoal
  "暗色模式使用的配色预设.

取值是 `seshat-reader-dark-tint-presets' 里的符号（`graphite' / `midnight'
/ `charcoal' / `night-sepia' / `sepia'），或直接给出 (BG . FG) 两个
`#xRRGGBB' 整数组成的 cons 自定义配色。`graphite' 保留改动前的满量程反色
（观感与旧版一致），其余预设是双端压缩；`sepia' 是亮底暗字。

颜色由原生模块的进程级状态承载：**同一 Emacs 内所有 reader buffer 共享同
一套配色**，不能逐 buffer 设置；重载或新开文档也保持该配色（这是暗色作为
用户偏好而非文档属性的结果）。

改预设不会自动重绘已打开的 buffer：重新 toggle `seshat-reader-dark-mode'
（`M-x seshat-reader-dark-mode' 两次）或按 `C-l' 让页面重新渲染即可生效。"
  :group 'seshat-reader
  :type '(choice (const :tag "Graphite (old look, full contrast)" graphite)
                 (const :tag "Midnight" midnight)
                 (const :tag "Charcoal (default)" charcoal)
                 (const :tag "Night sepia" night-sepia)
                 (const :tag "Sepia (light background)" sepia)
                 (cons :tag "Custom (BG . FG) as #xRRGGBB" integer integer)))

(defun seshat-reader--dark-tint-colors (preset)
  "把预设 PRESET 解析成下发到原生模块的 (BG . FG) 整数对.

返回 nil 表示「不下发 tint」，即让原生模块走旧的满量程反色：`graphite'、
nil 与非法取值都是这条分支（非法取值额外 `message' 一次，不静默换成另一
档配色）。PRESET 可以是 `seshat-reader-dark-tint-presets' 里的符号，也可
以直接是两个 `#xRRGGBB' 整数组成的 cons；超出 0..`#xFFFFFF' 或不是整数的
cons 一律视为非法。"
  (cond
   ((consp preset)
    (let ((bg (car preset))
          (fg (cdr preset)))
      (if (and (integerp bg) (integerp fg)
               (<= 0 bg #xFFFFFF)
               (<= 0 fg #xFFFFFF))
          (cons bg fg)
        (message "seshat-reader-dark-tint: 需要 (BG . FG) 两个 #xRRGGBB 整数，\
忽略 %S" preset)
        nil)))
   ((null preset) nil)
   (t
    (let ((entry (assq preset seshat-reader-dark-tint-presets)))
      (if (null entry)
          (progn
            (message "seshat-reader-dark-tint: 未知预设 %S，按不下发 tint 处理" preset)
            nil)
        (let ((colors (cdr entry)))
          ;; `graphite' 的 (-1 . -1) 是「不下发 tint」的哨兵，不是颜色。
          ;; 两侧都校验：只查 `car' 会让 (BG . -1) 这种半负值蒙进来，
          ;; 原生模块收到负值会静默清空 tint，表现为「配色没生效」。
          (when (and (>= (car colors) 0) (>= (cdr colors) 0))
            colors)))))))

(defun seshat-reader--push-dark-tint ()
  "把 `seshat-reader-dark-tint' 解析后的两个端点色下发到原生模块.

`graphite' 与非法取值下发 `-1 -1'，即让原生模块走旧的满量程反色路径。
返回值仅供调试，调用方不消费。"
  (let ((colors (seshat-reader--dark-tint-colors seshat-reader-dark-tint)))
    (seshat-reader-dyn--doc-tint (if colors (car colors) -1)
                                 (if colors (cdr colors) -1))
    colors))

(define-minor-mode seshat-reader-dark-mode
  "Toggle dark-mode for current seshat-reader document.

The pixel mapping happens in the native module, at process level, so every
page bitmap becomes stale at once: the spec cache is dropped and the resident
pages are rendered again by `seshat-reader--redisplay-all-windows'.  The
pages are not recoloured on the Lisp side, which is what keeps the highlights
painted into the bitmap by the native module consistent.

Turning the mode on also pushes the colours of `seshat-reader-dark-tint'
through `seshat-reader--dark-tint-colors', so the flag and the palette always
travel together; `graphite' pushes the (-1 -1) sentinel instead, which keeps
the old full-range inversion.  Turning it off leaves the tint untouched: it
is a user preference, so the next activation comes back with the same
palette."
  :lighter " Dark"
  (when (derived-mode-p 'seshat-reader-mode)
    (seshat-reader-dyn--doc-invert (if seshat-reader-dark-mode 1 0))
    (when seshat-reader-dark-mode
      (seshat-reader--push-dark-tint))
    (seshat-reader--redisplay-all-windows)))

(defun seshat-reader-dark-tint-cycle (&optional n)
  "Switch the dark palette to another preset and repaint the pages.

The palettes are visited in the order of `seshat-reader-dark-tint-presets',
wrapping around at either end.  N is the number of presets to advance, one by
default; a negative N goes backwards, so a non-zero prefix argument walks the
same table in reverse.  When the current value of `seshat-reader-dark-tint' is
not one of the preset symbols -- a custom (BG . FG) cons, or nil -- the walk
starts just before the head of the table, which makes the first forward step
land on the first preset.

The palette only means something while dark-mode is on, so the command turns
`seshat-reader-dark-mode' on when it was off; the mode activation pushes the
new palette itself.  With the mode already on, the new colours are pushed and
the pages are repainted once, which is what makes the switch visible without
toggling the mode twice.  In a buffer that is not a reader buffer only the
global preference changes: nothing is pushed to the native module and no page
is repainted, because the palette is process-wide and the current buffer has
no pages to show.

The new preset symbol is returned; the echo-area feedback is not part of the
return value."
  (interactive "p")
  (let* ((presets (mapcar #'car seshat-reader-dark-tint-presets))
         (len (length presets))
         (step (or n 1))
         (idx -1)
         (i 0)
         (next nil))
    ;; 预设表被清空时下面会除零（`(mod x 0)` 抛 arith-error），显式报错更清楚。
    ;; 报文首字母大写：checkdoc 的 `Messages should start with a capital letter'
    ;; 会把小写开头的 `error' 记成一条新警告，破坏「零新增」判据。
    (when (zerop len)
      (error "Empty seshat-reader-dark-tint-presets, cannot cycle"))
    ;; 本文件不 require `cl-lib' 也不 require `seq'，故手写线性查找定位当前
    ;; 预设；找不到（自定义 cons / nil）时 idx 保持 -1，即「表首之前」。
    (while (< i len)
      (when (eq (nth i presets) seshat-reader-dark-tint)
        (setq idx i))
      (setq i (1+ i)))
    (setq next (nth (mod (+ idx step) len) presets))
    ;; 顺序不可颠倒：先改值，再让开启路径按**新值**下发；先开模式会下发旧值。
    (setq seshat-reader-dark-tint next)
    (cond
     ((not (derived-mode-p 'seshat-reader-mode))
      ;; 非阅读 buffer：只改全局偏好，不碰模块函数、不重绘。
      nil)
     (seshat-reader-dark-mode
      (seshat-reader--push-dark-tint)
      (seshat-reader--redisplay-all-windows))
     (t
      ;; 模式自己会下发 + 重绘，这里不得再补一次（否则重绘两次、肉眼闪）。
      (seshat-reader-dark-mode 1)))
    (message "Dark tint: %s%s" next
             (if (eq next 'graphite)
                 " (the old full-range inversion)"
               ""))
    next))

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
