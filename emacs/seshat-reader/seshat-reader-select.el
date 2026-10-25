;;; seshat-reader-select.el --- Mouse selection of page text  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, files, tools
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

;; Mouse selection support for the vendored `seshat-reader' package of this
;; repository (see `VENDORED.md' in the same directory).  Dragging the
;; left mouse button over a page shown by `seshat-reader-mode' extracts the
;; text inside the dragged rectangle: the result is reported in the
;; echo area and can optionally be pushed onto the kill ring.
;;
;; This file is a self-contained extension.  The vendored `seshat-reader.el'
;; and the C sources under `render/' are deliberately left untouched;
;; the only integration points are the `down-mouse-1' binding installed
;; into `seshat-reader-mode-map' by `seshat-reader-select-enable' and the
;; module function `seshat-reader-dyn--text-in-rect' exported by
;; `seshat-render-core'.
;;
;; The last selection is also recorded, as a plist, in the variable
;; `seshat-reader-select-last' (:text, :page, :rect, :file), so that
;; annotation commands can reuse it without asking the user to drag again.
;;
;; Dependencies:
;;
;;   - `seshat-reader' (vendored) for `seshat-reader-current-doc-pagenumber',
;;     `seshat-reader-current-doc-scale-value' and `seshat-reader-mode-map'.
;;   - the `seshat-render-core' dynamic module for `seshat-reader-dyn--text-in-rect'.
;;
;; The vendored package provides the `seshat-reader' feature; this
;; directory must come before any other `seshat-reader' package on
;; `load-path'.
;;
;; Known limitations:
;;
;;   - Pages rotated away from zero degrees are not supported.  The
;;     rotation lives only in the C side `EmacsWinState' and is not
;;     readable from Lisp, so a rotated page yields silently wrong
;;     coordinates.
;;   - The visual feedback for a selection is limited to a short-lived
;;     "flash": the C renderer's rect highlight table is filled with the
;;     selection rectangle right after the button is released and cleared
;;     again after `seshat-reader-select-flash-duration' seconds (see
;;     `seshat-reader-select--flash-selection').  Overlays are not used:
;;     `seshat-reader-mode' displays a page with a single overlay per window
;;     and overlay `display' properties do not compose.  A persistent
;;     highlight comes from creating an annotation (`C-c C-a'), which feeds
;;     the same C table through `seshat-reader-annotation'.
;;   - The flashed (and annotated) geometry is a set of rectangles hugging
;;     the selected characters, merged per line: the module reports one
;;     rectangle per hit character and they are run together until the
;;     horizontal gap exceeds
;;     `seshat-reader-select-highlight-gap-ratio' times the line height (see
;;     `seshat-reader-select--merge-char-rects'), which keeps two-column
;;     text from being bridged by a single bar.  Set
;;     `seshat-reader-select-highlight-granularity' to `character' for one
;;     rectangle per character instead.  It is still not a text-shaping
;;     highlight: rotated pages remain unsupported, as they are for the
;;     selection itself.
;;   - Only pages carrying a text layer can be read; scanned images
;;     produce no text.
;;   - The frame scale used here is sampled from the frame displaying
;;     the page at selection time, while the C module samples it once
;;     (from the selected frame) when a document is opened.  The two
;;     agree only for a single frame whose scale has not changed since
;;     the document was loaded; mixed-scale multi-frame setups can
;;     therefore be off (tracked for a later change that exposes the
;;     load-time value from C).
;;   - evil 用户：evil 的 motion state map 绑定了 `[down-mouse-1]' →
;;     `evil-mouse-drag-region'，会遮蔽本 major-mode 的绑定；须在用户配置侧用
;;     `evil-collection-define-key 'normal 'seshat-reader-mode-map
;;     [down-mouse-1] #'seshat-reader-select-drag' 显式重绑
;;     （见 notes 项目 thomas-emacs 配置）。

;;; Code:

(require 'seshat-reader)

(defgroup seshat-reader-select nil
  "Extract text from mouse selections in `seshat-reader-mode'."
  :group 'seshat-reader)

(defcustom seshat-reader-select-copy-to-kill-ring nil
  "Whether selected text is also pushed onto the kill ring.
When non-nil, the text extracted by `seshat-reader-select-drag' is
copied with `kill-new' in addition to being reported in the echo
area."
  :type 'boolean
  :group 'seshat-reader-select)

(defconst seshat-reader-select-message-limit 200
  "Maximum number of characters reported for one selection.
Longer selections are truncated in the echo area; the full text is
still pushed onto the kill ring when
`seshat-reader-select-copy-to-kill-ring' is non-nil.")

(defcustom seshat-reader-select-flash-duration 2.0
  "How long the selection rectangle is highlighted after a drag, in seconds.
After the mouse button is released the selection rectangle is fed to
the C renderer's rect highlight table and cleared again after this
many seconds, so the user gets a visual confirmation of what was
selected.  The flash is independent of
`seshat-reader-annotation-highlight-enabled': it is transient feedback
for the selection, not an annotation highlight.

A value of 0 (or any non-positive number) disables the flash
completely; there is no second on/off switch."
  :type 'number
  :group 'seshat-reader-select)

(defcustom seshat-reader-select-highlight-granularity 'line
  "How the per-character rectangles of a selection are merged.
The C module reports one rectangle per character hit by the selection
drag, which is far too many to feed back as highlights.  With the
default `line' the rectangles are clustered into text lines and run
together inside a line until the horizontal gap gets too wide (see
`seshat-reader-select-highlight-gap-ratio'), so a selection spanning
three lines flashes three bars that hug the text.

With `character' no merging happens at all: every character keeps its
own rectangle, which is the most faithful and the most expensive
choice (it also pushes the multi-segment `rect:' limit of an
annotation location, see `seshat-reader-annotation--rect-max-segments').
Both values sort the rectangles by position; the ordering is what the
C renderer relies on for a stable result."
  :type '(choice (const :tag "Merge into lines" line)
                 (const :tag "One rect per character" character))
  :group 'seshat-reader-select)

(defcustom seshat-reader-select-highlight-gap-ratio 0.8
  "Horizontal gap, relative to the line height, that splits a line run.
Two neighbouring characters are merged into the same rectangle as long
as the gap between them does not exceed this ratio times the line
height (the line height is the median height of the characters in that
line).  The default 0.8 bridges the inter-word spaces of normal text
while still keeping the two columns of a two-column layout apart: the
gap between columns is far wider than a line height.

0 splits at every positive gap (touching characters still merge); a
very large value merges everything that shares a line."
  :type 'number
  :group 'seshat-reader-select)

(defcustom seshat-reader-select-highlight-shrink-ratio 0.8
  "Vertical height of a highlight rectangle, relative to its glyph box.
The character quads reported by the module are taller than the leading
of the text, so the per-line bars of two adjacent lines touch (or even
overlap) vertically and a multi-line selection looks like one solid
block.  Every rectangle returned by
`seshat-reader-select--merge-char-rects' is therefore shrunk around its
own vertical centre by this ratio, which restores a white gap between
the lines: with a glyph height of about 11pt and a leading of about
10.3pt the default 0.8 leaves roughly a 1pt gap.

Only the **height** is affected: the vertical centre is kept, and
neither the horizontal range (X0 / X1), nor the overall bounding box
of the drag (`:rect' of `seshat-reader-select-last'), nor the number of
merged segments and their x ranges written into an annotation
`location' change.  Both `seshat-reader-select-highlight-granularity'
values are shrunk.

1.0 disables the shrink (the raw merged geometry, i.e. the behaviour
before this option existed).  The useful range is 0.3 to 1.0; a value
outside of it is clamped into that range, and a non-number (nil, a
string) falls back to the default 0.8 instead of raising an error."
  :type 'number
  :group 'seshat-reader-select)

(defvar seshat-reader-select--flash-rects nil
  "Rectangles currently flashed, as a list of (PAGE X0 Y0 X1 Y1).
PAGE is 1-based, the four coordinates are page coordinates (the same
units accepted by `seshat-reader-dyn--add-highlight'), so the list can
be handed to the C renderer unchanged.

The variable is buffer-local: it describes the document displayed in
that buffer.  It is set by `seshat-reader-select--flash-selection' and
cleared by the timer it arms (or straight away when another selection
replaces it).  `seshat-reader-annotation--redraw-highlights' reads it
to feed the flash together with the annotation rectangles.")

(defvar-local seshat-reader-select--flash-timer nil
  "Timer that clears the flash armed by `seshat-reader-select--flash-selection'.
Kept so that a new selection can cancel the pending clear of the
previous one; a stale timer would otherwise wipe the fresh flash.

The variable is buffer-local, like `seshat-reader-select--flash-rects':
the timer belongs to the document displayed in that buffer.  A global
value would let two nearly simultaneous selections in two documents
interfere — the second `cancel-timer' would cancel the first document's
pending clear, leaving its flash rectangle on the page forever.")

;; 下面三个函数由动态模块（`render/render-core.c'）与批注模块提供：此处只
;; 声明签名，避免字节编译告警；运行时用 `fboundp' 判断可用性，缺模块时
;; 闪现静默跳过（取文本功能不受影响）。
(declare-function seshat-reader-dyn--add-highlight "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--rects-in-rect "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--clear-highlights "seshat-render-core" ())
(declare-function seshat-reader-dyn--refresh-highlights "seshat-render-core" ())
(declare-function seshat-reader-annotation--redraw-highlights
                  "seshat-reader-annotation" (&optional rects))

(defun seshat-reader-select--rect-valid-p (page rect)
  "Return non-nil when PAGE and RECT describe a flashable rectangle.
PAGE must be a positive integer (the module takes 1-based page
numbers) and RECT a list of four numbers (X0 Y0 X1 Y1) with a strictly
positive width and height; a degenerate rectangle has nothing to draw."
  (and (integerp page)
       (> page 0)
       (listp rect)
       (= 4 (length rect))
       (let ((x0 (nth 0 rect))
             (y0 (nth 1 rect))
             (x1 (nth 2 rect))
             (y1 (nth 3 rect)))
         (and (numberp x0) (numberp y0) (numberp x1) (numberp y1)
              (> (- x1 x0) 0)
              (> (- y1 y0) 0)))))

(defun seshat-reader-select--normalize-flash-rects (page rects)
  "Return RECTS as a list of (PAGE X0 Y0 X1 Y1) tuples.
RECTS is either a single rectangle (X0 Y0 X1 Y1) or a list of such
rectangles — both call shapes are accepted so that a caller holding an
unmerged bounding box does not have to wrap it.  PAGE is prepended to
every rectangle and rectangles rejected by
`seshat-reader-select--rect-valid-p' are dropped, so an unusable
selection yields nil instead of a half-broken flash."
  (let ((items (cond ((null rects) nil)
                     ((numberp (car-safe rects)) (list rects))
                     ((listp rects) rects)
                     (t nil))))
    (let (tuples)
      (dolist (rect items)
        (when (seshat-reader-select--rect-valid-p page rect)
          (push (cons page rect) tuples)))
      (nreverse tuples))))

(defun seshat-reader-select--normalize-rect (rect)
  "Return RECT as (X0 Y0 X1 Y1) with X0<=X1 and Y0<=Y1, or nil.
RECT must be a list of exactly four numbers; anything else (nil, a
shorter or longer list, a non-number element) yields nil so that the
merge step can simply drop it.  Values are compared with `min' /
`max', which keeps integers integral and floats floating."
  (when (and (listp rect)
             (= 4 (length rect))
             (numberp (nth 0 rect))
             (numberp (nth 1 rect))
             (numberp (nth 2 rect))
             (numberp (nth 3 rect)))
    (list (min (nth 0 rect) (nth 2 rect))
          (min (nth 1 rect) (nth 3 rect))
          (max (nth 0 rect) (nth 2 rect))
          (max (nth 1 rect) (nth 3 rect)))))

(defun seshat-reader-select--rect-height (rect)
  "Return the height of RECT, a (X0 Y0 X1 Y1) list."
  (- (nth 3 rect) (nth 1 rect)))

(defun seshat-reader-select--rect-y-center (rect)
  "Return the vertical centre of RECT as a float."
  (/ (+ (float (nth 1 rect)) (float (nth 3 rect))) 2.0))

(defconst seshat-reader-select--highlight-shrink-min 0.3
  "Lower bound the shrink ratio is clamped to.")

(defconst seshat-reader-select--highlight-shrink-max 1.0
  "Upper bound the shrink ratio is clamped to.")

(defconst seshat-reader-select--highlight-shrink-default 0.8
  "Shrink ratio used when the option holds a non-number.")

(defun seshat-reader-select--highlight-shrink-ratio ()
  "Return the effective vertical shrink ratio, clamped and defaulted.
The value of `seshat-reader-select-highlight-shrink-ratio' is read and
returned as a float within 0.3 and 1.0.  A non-number (nil, a string,
a symbol) yields 0.8, the option's default, so a misset variable can
never break a selection."
  (let ((value seshat-reader-select-highlight-shrink-ratio))
    (if (numberp value)
        (max seshat-reader-select--highlight-shrink-min
             (min seshat-reader-select--highlight-shrink-max (float value)))
      seshat-reader-select--highlight-shrink-default)))

(defun seshat-reader-select--shrink-rect-vertically (rect ratio)
  "Return RECT shrunk vertically to RATIO of its height, centre kept.
RECT is a (X0 Y0 X1 Y1) list and RATIO a number.  X0 and X1 are
returned unchanged; the vertical centre stays put and the height
becomes RATIO times the old height, so Y0 rises and Y1 falls by the
same amount.  RECT is returned as-is when its height is not positive
\(a degenerate rectangle has nothing to shrink, matching
`seshat-reader-select--normalize-rect'), and also when RATIO is not a
number or is 1.0 or more — the last case on purpose, so that turning
the shrink off yields the very same integers instead of floats that
merely compare equal."
  (let ((height (seshat-reader-select--rect-height rect)))
    (if (or (not (numberp ratio))
            (>= ratio 1.0)
            (not (> height 0)))
        rect
      (let* ((center (seshat-reader-select--rect-y-center rect))
             (half (/ (* (float height) ratio) 2.0)))
        (list (nth 0 rect)
              (- center half)
              (nth 2 rect)
              (+ center half))))))

(defun seshat-reader-select--shrink-rects-vertically (rects ratio)
  "Return RECTS with every rectangle shrunk vertically by RATIO.
RATIO of 1.0 or more (or a non-number) returns RECTS itself, so the
caller gets its input back untouched when the shrink is disabled."
  (if (or (not (numberp ratio)) (>= ratio 1.0))
      rects
    (mapcar (lambda (rect)
              (seshat-reader-select--shrink-rect-vertically rect ratio))
            rects)))

(defun seshat-reader-select--line-height (rects)
  "Return the median height of RECTS, or the mean when that is unusable.
The median is used on purpose: one tall character in a line (a
bracket, a capital with an accent) must not inflate the gap threshold
for the whole line, whereas the mean would be dragged upwards by it.
A median that is not positive (degenerate, zero-height rectangles)
falls back to the mean, and the mean in turn falls back to 0.0."
  (let* ((heights (sort (mapcar #'seshat-reader-select--rect-height rects) #'<))
         (count (length heights)))
    (cond
     ((zerop count) 0.0)
     (t
      (let ((median (if (= 1 (% count 2))
                        (float (nth (/ count 2) heights))
                      (/ (+ (float (nth (1- (/ count 2)) heights))
                            (float (nth (/ count 2) heights)))
                         2.0))))
        (if (> median 0)
            median
          (let ((mean (/ (float (apply #'+ heights)) count)))
            (if (> mean 0) mean 0.0))))))))

(defun seshat-reader-select--group-rects-into-lines (rects)
  "Cluster RECTS into text lines and return a list of rect lists.
RECTS are (X0 Y0 X1 Y1) lists in any order.  A rectangle joins an
existing line when its vertical centre is within half the line height
of that line's centre (the larger of the two heights is used), which
is the tolerance for the usual jitter of character boxes on one
baseline while still separating consecutive lines.  Lines are built in
ascending centre order, so the result is roughly top to bottom."
  (let ((sorted (sort (copy-sequence rects)
                      (lambda (a b)
                        (< (seshat-reader-select--rect-y-center a)
                           (seshat-reader-select--rect-y-center b)))))
        (lines nil))
    (dolist (rect sorted)
      (let* ((center (seshat-reader-select--rect-y-center rect))
             (height (seshat-reader-select--rect-height rect))
             (line (catch 'found
                     (dolist (line lines)
                       ;; line 是 [锚点中心 锚点高度 矩形表] 向量
                       (when (<= (abs (- center (aref line 0)))
                                 (* 0.5 (max height (aref line 1))))
                         (throw 'found line)))
                     nil)))
        (if line
            (progn
              ;; 锚点取组内已有中心的均值，避免被单个离群矩形带偏
              (aset line 0 (/ (+ (aref line 0) center) 2.0))
              (aset line 1 (max (aref line 1) height))
              (aset line 2 (cons rect (aref line 2))))
          (push (vector center height (list rect)) lines))))
    (mapcar (lambda (line) (nreverse (aref line 2))) (nreverse lines))))

(defun seshat-reader-select--merge-line-rects (rects threshold)
  "Merge the RECTS of one line into runs, breaking at gaps > THRESHOLD.
RECTS are (X0 Y0 X1 Y1) lists belonging to a single text line and are
sorted here by X0.  Each run grows to cover every rectangle whose left
edge is at most THRESHOLD to the right of the run's current right
edge; a wider gap starts a new run, which is what keeps the columns of
a two-column layout apart.  The returned runs are (MIN-X0 MIN-Y0 MAX-X1
MAX-Y1) lists in left to right order."
  (let ((sorted (sort (copy-sequence rects)
                      (lambda (a b) (< (nth 0 a) (nth 0 b)))))
        (runs nil)
        (run nil))
    (dolist (rect sorted)
      (cond
       ((null run) (setq run (copy-sequence rect)))
       ((<= (- (nth 0 rect) (nth 2 run)) threshold)
        (setq run (list (min (nth 0 run) (nth 0 rect))
                        (min (nth 1 run) (nth 1 rect))
                        (max (nth 2 run) (nth 2 rect))
                        (max (nth 3 run) (nth 3 rect)))))
       (t
        (push run runs)
        (setq run (copy-sequence rect)))))
    (when run (push run runs))
    (nreverse runs)))

(defun seshat-reader-select--sort-rects (rects)
  "Return RECTS sorted by Y0 and then X0."
  (sort rects
        (lambda (a b)
          (let ((ya (nth 1 a))
                (yb (nth 1 b)))
            (cond ((/= ya yb) (< ya yb))
                  ((/= (nth 0 a) (nth 0 b)) (< (nth 0 a) (nth 0 b)))
                  (t (< (nth 3 a) (nth 3 b))))))))

(defun seshat-reader-select--merge-char-rects (rects)
  "Merge per-character RECTS into the rectangles that are drawn.
RECTS is a list of (X0 Y0 X1 Y1) page-coordinate rectangles as
returned by `seshat-reader-dyn--rects-in-rect', in any order; nil or
an empty list yields nil, as do inputs made only of malformed
elements (those are dropped individually).

The rectangles are first clustered into text lines (see
`seshat-reader-select--group-rects-into-lines'), then each line is
sorted by X0 and run together until the horizontal gap exceeds
`seshat-reader-select-highlight-gap-ratio' times the line height (see
`seshat-reader-select--merge-line-rects').  Every run is reported as
one (MIN-X0 MIN-Y0 MAX-X1 MAX-Y1) rectangle, so a selection spanning
N lines yields about N rectangles rather than one per character.

When `seshat-reader-select-highlight-granularity' is `character' no
merging happens: the rectangles are only sorted by position and
returned unchanged.

Whatever the granularity, the result is finally shrunk vertically
around each rectangle's centre by
`seshat-reader-select-highlight-shrink-ratio' (see
`seshat-reader-select--shrink-rects-vertically'): the merged bars of
two adjacent lines never touch, so a multi-line selection shows white
gaps between the lines.  Only the height changes — the horizontal
range, the overall bounding box of the drag (`:rect' of
`seshat-reader-select-last') and the number of segments are unaffected.
A ratio of 1.0 returns the merged geometry unchanged.

This is a pure function — no buffer, no module, no document — so it
can be unit tested directly."
  (let ((normalized (delq nil (mapcar #'seshat-reader-select--normalize-rect rects))))
    (when normalized
      (let ((shrink (seshat-reader-select--highlight-shrink-ratio)))
        (seshat-reader-select--shrink-rects-vertically
         (if (eq seshat-reader-select-highlight-granularity 'character)
             (seshat-reader-select--sort-rects normalized)
           (let ((gap-ratio (let ((value seshat-reader-select-highlight-gap-ratio))
                              (if (numberp value) (max 0 (float value)) 0.8)))
                 (runs nil))
             (dolist (line (seshat-reader-select--group-rects-into-lines normalized))
               (setq runs (append (seshat-reader-select--merge-line-rects
                                   line (* gap-ratio (seshat-reader-select--line-height line)))
                                  runs)))
             (seshat-reader-select--sort-rects runs)))
         shrink)))))

(defun seshat-reader-select--redraw-highlights ()
  "Redraw the page highlights, feeding the flash rectangles.
Delegates to `seshat-reader-annotation--redraw-highlights' when the
annotation module is loaded, so that annotation rectangles and the
flash are fed through a single code path (and neither clobbers the
other: a redraw always clears the C table first).

When that function is not available, the flash is fed alone: clear,
add every rectangle of `seshat-reader-select--flash-rects', refresh.
The C module may not be loaded at all, so every call is inside
`ignore-errors' and guarded by `fboundp' — the flash is optional
feedback and must never break text extraction."
  (ignore-errors
    (cond
     ((fboundp 'seshat-reader-annotation--redraw-highlights)
      (seshat-reader-annotation--redraw-highlights))
     ((and (fboundp 'seshat-reader-dyn--clear-highlights)
           (fboundp 'seshat-reader-dyn--add-highlight))
      (seshat-reader-dyn--clear-highlights)
      (dolist (rect seshat-reader-select--flash-rects)
        (seshat-reader-dyn--add-highlight (nth 0 rect) (nth 1 rect)
                                          (nth 2 rect) (nth 3 rect)
                                          (nth 4 rect)))
      (when (fboundp 'seshat-reader-dyn--refresh-highlights)
        (seshat-reader-dyn--refresh-highlights))))))

(defun seshat-reader-select--clear-flash (buffer)
  "Clear the flash of BUFFER and redraw the page highlights.
BUFFER is the seshat-reader buffer the flash belongs to; it may be
dead already (the user closed the document), in which case nothing is
done.  Called from the timer armed by
`seshat-reader-select--flash-selection'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; 两个变量都是 buffer-local，故在 BUFFER 内赋值（`setq-local'）：只清
      ;; 该文档自己的 timer 与矩形，另一个文档的闪现不受影响。
      (setq-local seshat-reader-select--flash-timer nil)
      (setq-local seshat-reader-select--flash-rects nil)
      (seshat-reader-select--redraw-highlights))))

(defun seshat-reader-select--flash-selection (page rects)
  "Flash the selection geometry RECTS on PAGE for a moment.
PAGE is the 1-based page number and RECTS is the geometry of the
selection in page coordinates: either a single rectangle
\(X0 Y0 X1 Y1) — the unmerged bounding box, useful to a caller that
has no per-character data — or a list of such rectangles, such as the
per-line rectangles produced by
`seshat-reader-select--merge-char-rects'.  Both shapes are normalized
by `seshat-reader-select--normalize-flash-rects', which also drops
unusable rectangles (degenerate ones have nothing to draw).

The rectangles are stored in the buffer-local
`seshat-reader-select--flash-rects' and fed to the C renderer, which
draws all of them; a timer clears them again after
`seshat-reader-select-flash-duration' seconds.  The flash is skipped
when the duration is not positive or when no rectangle survives
validation.

Repeated selections in the **same buffer** cancel the previous timer, so
that an old clear cannot wipe a fresh flash; selections in different
buffers keep independent timers (both
`seshat-reader-select--flash-timer' and `seshat-reader-select--flash-rects'
are buffer-local).  Everything is wrapped in `ignore-errors': a missing
module or an unusable C call must never break text extraction."
  (let ((duration seshat-reader-select-flash-duration)
        (tuples (seshat-reader-select--normalize-flash-rects page rects)))
    (when (and (numberp duration) (> duration 0) tuples)
      (ignore-errors
        (when (timerp seshat-reader-select--flash-timer)
          (cancel-timer seshat-reader-select--flash-timer))
        (setq-local seshat-reader-select--flash-rects tuples)
        (seshat-reader-select--redraw-highlights)
        (let ((buffer (current-buffer)))
          (setq-local seshat-reader-select--flash-timer
                      (run-at-time duration nil
                                   (lambda ()
                                     (seshat-reader-select--clear-flash
                                      buffer)))))))))

(defvar seshat-reader-select-last nil
  "Most recent mouse selection, as a plist, or nil when there is none.
The plist holds the keys

  :text  the selected text, or nil when the rectangle held no text;
  :page  the page number the selection was made on, 1-based, as
         returned by `seshat-reader-current-doc-pagenumber';
  :rect  the selection rectangle as a list (X0 Y0 X1 Y1) in page
         coordinates (floats, as accepted by
         `seshat-reader-dyn--text-in-rect'), i.e. the bounding box of
         the drag — kept for the consumers that only need a position
         (translate, reference) and for the annotation path of older
         versions;
  :rects the per-line rectangles hugging the selected characters, as a
         list of (X0 Y0 X1 Y1) lists, or nil when the module could not
         report them (`seshat-reader-dyn--rects-in-rect' unavailable)
         or the region held no text.  Consumers that draw geometry
         should prefer this and fall back to :rect when it is nil;
  :file  the file name of the selected document, taken from the
         variable `buffer-file-name' (nil for a buffer without a file).

It is set by `seshat-reader-select-extract' whether or not text was
extracted (a rectangle without text still records its position), so
annotation commands can reuse the last selection.")

(defun seshat-reader-select--frame-scale (frame)
  "Return the scale factor of FRAME as a float.
FRAME is the frame that displays the seshat-reader page.  The C module
samples the very same value with `frame-scale-factor' when a
document is opened (see the assignment to `frame_scale' in
`render/render-core.c'), so the same primitive is used here.  A nil
or non-positive result falls back to 1.0."
  (let ((scale (and (frame-live-p frame) (frame-scale-factor frame))))
    (if (and (numberp scale) (> scale 0))
        (float scale)
      1.0)))

(defun seshat-reader-select--page-scale (window)
  "Return the page scale of WINDOW, or nil when it is unusable.
The scale is taken from `seshat-reader-current-doc-scale-value', which is
window-local in `seshat-reader-mode'; the window argument is mandatory
there and is passed through."
  (let ((scale (ignore-errors (seshat-reader-current-doc-scale-value window))))
    (and (numberp scale) (> scale 0) (float scale))))

(defun seshat-reader-select-posn->page (posn &optional window)
  "Convert the mouse position POSN into page coordinates.
POSN is a position list as returned by `event-start' or `event-end'.
WINDOW is the window showing the page and defaults to the window of
POSN.

Return the page coordinates as a cons (X . Y) of floats, or nil
when POSN cannot be converted, in which case a message explains the
failure.

The coordinates are computed as

    page = image pixel * frame scale / scale

where the image pixel offset comes from `posn-object-x-y' (which
already accounts for window scrolling and page centering), the
frame scale from `frame-scale-factor' and the page scale from
`seshat-reader-current-doc-scale-value'.  The result is valid only for an
unrotated page and is meant to be passed, over the rectangle formed
by two such positions, to `seshat-reader-dyn--text-in-rect'."
  (let ((window (or window (posn-window posn))))
    (cond
     ((not (windowp window))
      (message "Seshat Reader select: position is not in a live window.")
      nil)
     ((not (eq (car-safe (posn-object posn)) 'image))
      (message "Seshat Reader select: position is not over a page image.")
      nil)
     (t
      (let ((xy (posn-object-x-y posn))
            (scale (seshat-reader-select--page-scale window)))
        (cond
         ((not (consp xy))
          (message "Seshat Reader select: no image pixel offset at position.")
          nil)
         ((null scale)
          (message "Seshat Reader select: page scale is zero or invalid.")
          nil)
         (t
          (let ((factor (/ (seshat-reader-select--frame-scale
                            (window-frame window))
                           scale)))
            (cons (* (float (car xy)) factor)
                  (* (float (cdr xy)) factor))))))))))

(defun seshat-reader-select--report (text)
  "Report the extracted TEXT in the echo area, optionally copying it.
TEXT shorter than `seshat-reader-select-message-limit' is shown in
full; longer text is truncated for display.  When
`seshat-reader-select-copy-to-kill-ring' is non-nil the full TEXT is
also pushed onto the kill ring with `kill-new'."
  (let ((str (and text (string-trim text))))
    (if (or (null str) (equal str ""))
        (message "Seshat Reader select: no text in the selected rectangle.")
      (when seshat-reader-select-copy-to-kill-ring
        (kill-new str))
      (message "%s%s%s"
               (if (> (length str) seshat-reader-select-message-limit)
                   (concat (substring str 0 seshat-reader-select-message-limit)
                           "...")
                 str)
               (format " [%d chars]" (length str))
               " [C-c C-a 建批注]"))))

(defun seshat-reader-select--rects-in-rect (page x0 y0 x1 y1)
  "Return the selection geometry for the characters in a region.
PAGE is the 0-based page number the module expects, X0, Y0, X1 and Y1
are page coordinates — exactly the arguments given to
`seshat-reader-dyn--text-in-rect' for the same rectangle, so the
geometry matches the extracted text.

The module reports one rectangle per hit character; they are merged by
`seshat-reader-select--merge-char-rects' into per-line rectangles.
Return nil when the module does not provide the function (an older
build) or when the region holds no character: a region without text is
a normal outcome, not an error, and must not produce a message."
  (when (fboundp 'seshat-reader-dyn--rects-in-rect)
    (seshat-reader-select--merge-char-rects
     (ignore-errors
       (seshat-reader-dyn--rects-in-rect page x0 y0 x1 y1)))))

(defun seshat-reader-select-extract (start end)
  "Extract the text between the mouse positions START and END.
START and END are position lists, as produced by `event-start' and
`event-end', that must belong to the same window showing a seshat-reader
page.

Return the extracted text, or nil when the two positions are not in
the same window, when either of them cannot be converted to page
coordinates, or when the corresponding rectangle contains no text.

Besides reporting the text, the selection is recorded in
`seshat-reader-select-last': the drag's bounding box under :rect and
the per-line rectangles hugging the selected characters under :rects
\(nil when the module cannot report them).  The flash that confirms the
selection uses those per-line rectangles, falling back to the bounding
box when there are none."
  (let ((window (posn-window start)))
    (cond
     ((not (eq window (posn-window end)))
      (message "Seshat Reader select: the drag must stay inside one window.")
      nil)
     (t
      (let ((start-page (seshat-reader-select-posn->page start window))
            (end-page (seshat-reader-select-posn->page end window)))
        (when (and start-page end-page)
          (let* ((x0 (min (car start-page) (car end-page)))
                 (x1 (max (car start-page) (car end-page)))
                 (y0 (min (cdr start-page) (cdr end-page)))
                 (y1 (max (cdr start-page) (cdr end-page)))
                 (page (1- (or (seshat-reader-current-doc-pagenumber window) 1)))
                 ;; The four coordinates already come from (min ...) /
                 ;; (max ...) applied to float coordinates, so they are
                 ;; floats; the module function `seshat-reader-dyn--text-in-rect'
                 ;; does not accept integers.
                 (text (seshat-reader-dyn--text-in-rect page x0 y0 x1 y1))
                 ;; 逐字符矩形 → 按行合并（纯函数）；模块缺失或无命中时为 nil
                 (rects (seshat-reader-select--rects-in-rect page x0 y0 x1 y1))
                 (bbox (list x0 y0 x1 y1)))
            (setq seshat-reader-select-last
                  (list :text text
                        ;; :page must be the 1-based page number reported by
                        ;; seshat-reader; the local `page' above is 0-based (for
                        ;; the module) and therefore must not be reused here.
                        :page (seshat-reader-current-doc-pagenumber window)
                        :rect bbox
                        :rects rects
                        :file (buffer-file-name (window-buffer window))))
            (seshat-reader-select--report text)
            ;; 选区已确定（不论矩形内是否有文本）就用高亮闪一下，让用户看到自己
            ;; 选中的区域；闪现落在发起拖拽的 buffer 上（`--flash-selection' 读写
            ;; 的 `seshat-reader-select--flash-rects' 是 buffer-local 的）。
            ;; 有字级矩形的就闪字级（贴合文字），否则回落整体 bbox。
            (with-current-buffer (window-buffer window)
              (seshat-reader-select--flash-selection
               (seshat-reader-current-doc-pagenumber window)
               (or rects (list bbox))))
            text)))))))

(defun seshat-reader-select-drag (start-event)
  "Select text on a seshat-reader page by dragging the mouse.
START-EVENT is the `down-mouse-1' event that starts the drag.  The
following mouse events are read with `read-event' instead of
delegating to `mouse-drag-track', so that neither point nor mark is
moved: `seshat-reader-mode' uses the cursor as the page border and it must
not be placed outside of the page.

When the drag starts, the window the drag started in is selected
\(without being recorded in the window order) so that the C side,
which resolves the current document through the selected window,
addresses the document displayed in that window.

When the button is released, the selection rectangle is converted
to page coordinates and its text is reported by
`seshat-reader-select-extract'; see there for the exact semantics."
  (interactive "e")
  (let* ((start (event-start start-event))
         (window (posn-window start))
         (end start)
         (moved nil)
         (finished nil))
    ;; `seshat-reader-dyn--text-in-rect' resolves the current document through
    ;; the *selected* window (C side uses `(selected-window)'), so make
    ;; sure the window the drag started in is selected.  `norecord'
    ;; avoids disturbing the `other-window' ordering.
    (when (windowp window)
      (select-window window 'norecord))
    (let ((track-mouse t))
      (while (not finished)
        (let ((event (read-event)))
          (cond
           ((mouse-movement-p event)
            (let ((posn (event-start event)))
              (when (eq (posn-window posn) window)
                (setq end posn
                      moved t))))
           ;; Release events come both as clicks (mouse-1, double-/triple-mouse-1) and as drags (drag-mouse-1); handling the latter here avoids relying on seshat-reader-mode-map's mouse-set-region remap to swallow it.
           ((memq (car-safe event) '(mouse-1 double-mouse-1 triple-mouse-1 drag-mouse-1))
            (let ((e (event-end event)))
              (when (eq (posn-window e) window)
                (setq end e)))
            (setq finished t))
           (t
            (setq finished t)
            (push event unread-command-events))))))
    (if moved
        (seshat-reader-select-extract start end)
      nil)))

(defun seshat-reader-select-describe-posn (event)
  "Report the raw and converted coordinates of the mouse EVENT.
This is a calibration helper for `seshat-reader-select-posn->page':
it prints the image pixel offset returned by `posn-object-x-y', the
page coordinates computed from it and the scale factors involved."
  (interactive "e")
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (page (seshat-reader-select-posn->page posn window)))
    (message "Seshat Reader select: pixel=%S page=%S page-scale=%S frame-scale=%S"
             (posn-object-x-y posn)
             page
             (and (windowp window) (seshat-reader-select--page-scale window))
             (and (windowp window)
                  (seshat-reader-select--frame-scale (window-frame window))))))

(defun seshat-reader-select-enable ()
  "Enable mouse text selection in `seshat-reader-mode-map'.
Only the `down-mouse-1' event is bound; it is left free by
`seshat-reader-mode' itself and by `special-mode'.  The six mouse command
remappings already present in `seshat-reader-mode-map' (for
`mouse-set-point', `mouse-set-region', `mouse-set-mark',
`mouse-set-secondary', `mouse-drag-region' and
`mouse-drag-secondary') are not touched, and neither is any of the
existing page turning, scrolling or zooming binding."
  (interactive)
  (define-key seshat-reader-mode-map [down-mouse-1]
              #'seshat-reader-select-drag))

(defun seshat-reader-select-disable ()
  "Remove the mouse text selection binding from `seshat-reader-mode-map'.
Afterwards `down-mouse-1' behaves as before this file was loaded:
it falls through to the global `mouse-drag-region', which
`seshat-reader-mode-map' remaps to `ignore'."
  (interactive)
  (define-key seshat-reader-mode-map [down-mouse-1] nil))

(with-eval-after-load 'seshat-reader
  (seshat-reader-select-enable))

(provide 'seshat-reader-select)
;;; seshat-reader-select.el ends here
