;;; seshat-reader-select.el --- Mouse selection of page text  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, files, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))

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
;; text inside the dragged rectangle: the echo area reports only how many
;; lines and characters were selected (never the text itself, see
;; `seshat-reader-select--report') and the text can optionally be pushed
;; onto the kill ring.
;;
;; This file is a self-contained extension.  The vendored `seshat-reader.el'
;; and the C sources under `render/' are deliberately left untouched;
;; the only integration points are the `down-mouse-1' binding installed
;; into `seshat-reader-mode-map' by `seshat-reader-select-enable' and the
;; module function `seshat-reader-dyn--text-in-rect' exported by
;; `seshat-render-core'.
;;
;; The last selection is also recorded, as a plist, in the variable
;; `seshat-reader-select-last' (:text, :page, :rect, :rects, :page-rects,
;; :file), so that annotation commands can reuse it without asking the user
;; to drag again.
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
;;   - Pages rotated away from zero degrees are supported since P1 made
;;     the rotation a Lisp-side value: `seshat-reader--multipage-rotate' is
;;     buffer-local and readable here, so every coordinate a drag produces
;;     is un-rotated to page space before it reaches the module (see
;;     `seshat-reader-select--unrotate-point').  The C side
;;     `EmacsWinState' still carries the rotation of the legacy single-page
;;     overlay; this module neither reads nor needs it.
;;   - The visual feedback for a selection is limited to a short-lived
;;     "flash": the C renderer's rect highlight table is filled with the
;;     selection rectangle right after the button is released and cleared
;;     again after `seshat-reader-select-flash-duration' seconds (see
;;     `seshat-reader-select--flash-selection').  Overlays are not used:
;;     `seshat-reader-mode' displays a page with a single overlay per window
;;     and overlay `display' properties do not compose.  A persistent
;;     highlight comes from creating an annotation (`C-c C-a'), which feeds
;;     the same C table through `seshat-reader-annotation'.
;;   - The flashed (and annotated) geometry snaps to whole text lines by
;;     default: a rectangle that touches any character of a line selects
;;     that entire line (`seshat-reader-select-highlight-scope', value
;;     `line', answered by the module function
;;     `seshat-reader-dyn--lines-in-rect').  Set the option to `region' to
;;     fall back to highlighting only the characters inside the rectangle,
;;     which is then merged per line: the module reports one rectangle per
;;     hit character and they are run together until the horizontal gap
;;     exceeds `seshat-reader-select-highlight-gap-ratio' times the line
;;     height (see `seshat-reader-select--merge-char-rects').  Under either
;;     scope the columns of a two-column layout stay separate — a line is
;;     only selected when one of its own characters was touched.  Set
;;     `seshat-reader-select-highlight-granularity' to `character' for one
;;     rectangle per character instead (`region' scope only; whole-line
;;     rectangles are never split).  Line clustering assumes horizontal
;;     lines in page space, which is also what a rotated page is mapped back
;;     to, so the rectangles of a quarter turn stay axis-aligned.
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
(require 'cl-lib)

(defgroup seshat-reader-select nil
  "Extract text from mouse selections in `seshat-reader-mode'."
  :group 'seshat-reader)

(defcustom seshat-reader-select-copy-to-kill-ring nil
  "Whether selected text is also pushed onto the kill ring.
When non-nil, the text extracted by `seshat-reader-select-drag' is
copied with `kill-new'; the echo area then says 已复制, i.e. the
selection can be pasted.  When nil the kill ring is left alone and
the echo area says 已选中 instead (在 echo area 报告行数与字数统计).

Either way the echo area only reports the line and character count of
the selection — never the text itself.  The text stays available to the
annotation and translation commands through
`seshat-reader-select-last' regardless of this option."
  :type 'boolean
  :group 'seshat-reader-select)

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

(defcustom seshat-reader-select-highlight-scope 'line
  "Which characters of a selection are highlighted.
This decides *what the selection grabs*, before any merging happens:

  `line'    (default) Line snapping.  As soon as the dragged rectangle
            touches any character of a line, the whole of that line is
            highlighted, from the line's first to its last glyph.  A
            narrow drag across the middle of a paragraph therefore
            highlights complete lines instead of a few characters,
            which is what makes the feedback readable.
  `region'  Only the characters intersecting the rectangle, i.e. the
            behaviour before line snapping existed.

Line snapping is done in the dynamic module
\(`seshat-reader-dyn--lines-in-rect'), which reports one rectangle per
whole line.  Those rectangles are *not* run through
`seshat-reader-select--merge-char-rects' — they already span their line,
and merging could only bridge two neighbouring lines together.  The
vertical shrink (`seshat-reader-select-highlight-shrink-ratio') still
applies, so the bars of adjacent lines keep their white gap.

Two-column pages stay separated: MuPDF's structured text splits the left
and right column into different lines, and a line is only reported when
one of *its own* characters was touched, so a drag over the left column
does not highlight the right one.

Set this to `region' to get the old rectangle-exact highlight back; an
older dynamic module without `seshat-reader-dyn--lines-in-rect' falls
back to `region' silently as well."
  :type '(choice (const :tag "Snap to whole lines" line)
                 (const :tag "Only the characters in the rectangle" region))
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
(declare-function seshat-reader-dyn--lines-in-rect "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--clear-highlights "seshat-render-core" ())
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
add every rectangle of `seshat-reader-select--flash-rects', then re-render
the resident pages so the baked-in decorations are redrawn.
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
      ;; P1：装饰在渲染时**烘进位图**，C 侧那张表本身不再改变画面，故投喂完
      ;; 之后要「清 spec 缓存 + 重渲染驻留页」（见
      ;; `seshat-reader--multipage-refresh-decorations'），不再是刷新单页
      ;; overlay 的 `--refresh-highlights'（该入口已于 2026-10-28 删除）。
      (seshat-reader--multipage-refresh-decorations)))))

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
         returned by `seshat-reader-current-doc-pagenumber'; for a drag
         that spans several pages this is the page it **started** on;
  :rect  the selection rectangle as a list (X0 Y0 X1 Y1) in page
         coordinates (floats, as accepted by
         `seshat-reader-dyn--text-in-rect'), i.e. the bounding box of
         the drag — kept for the consumers that only need a position
         (translate, reference) and for the annotation path of older
         versions.  It always belongs to :page, so for a cross-page drag
         it is the part of the selection on the page the drag started on;
  :rects the selection rectangles to draw, as a list of
         (X0 Y0 X1 Y1) lists, or nil when the module could not report
         them (neither `seshat-reader-dyn--lines-in-rect' nor
         `seshat-reader-dyn--rects-in-rect' available) or the region
         held no text.  With `seshat-reader-select-highlight-scope'
         at its default `line' these rectangles span whole text lines;
         with `region' they hug the selected characters.  Consumers
         that draw geometry should prefer this and fall back to :rect
         when it is nil.  Like :rect they belong to :page, i.e. they
         cover the page the drag started on, never another page;
  :page-rects
         the same rectangles, each tagged with the page it belongs to,
         as a list of (PAGE X0 Y0 X1 Y1) lists in reading order.  For a
         single-page selection every PAGE equals :page and the value is
         one-to-one with :rects: `cdr' of each of its elements equals
         the matching `:rects' element, in the same order.  So :rects
         stays the field to read when only one page is involved.  For a
         cross-page drag it carries the rectangles of
         every page covered, in page order, which is what drawing several
         pages needs; nil when :rects is nil;
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

(defun seshat-reader-select--page-rotate (&optional window)
  "Return the rotation of the page shown in WINDOW, in degrees.
The value is one of 0, 90, 180 and 270.  Since P1 the pages are buffer rows
and every window showing the buffer sees the same rotation, so the source of
truth is the buffer-local `seshat-reader--multipage-rotate' of the buffer
WINDOW displays.  When WINDOW is not a live window, or the buffer it shows
does not carry that variable (something that is not in `seshat-reader-mode'),
the value of the current buffer is used instead; the drag path runs with the
reader buffer current, so the two agree there.

A value that is not a multiple of 90 is reported as 0, which is what the
native renderer answers for an unsupported angle as well (it returns a nil
image spec rather than an image rotated by an arbitrary angle)."
  (let* ((buffer (or (and (windowp window) (window-buffer window))
                     (current-buffer)))
         (raw (cond
               ((and (buffer-live-p buffer)
                     (local-variable-p 'seshat-reader--multipage-rotate buffer))
                (buffer-local-value 'seshat-reader--multipage-rotate buffer))
               ((local-variable-p 'seshat-reader--multipage-rotate)
                seshat-reader--multipage-rotate)
               (t 0))))
    (if (and (numberp raw) (zerop (mod (round raw) 90)))
        (mod (round raw) 360)
      0)))

(defun seshat-reader-select--unrotate-size (size rotate)
  "Exchange the sides of SIZE when ROTATE is a quarter turn.
SIZE is the (W . H) of a page in page coordinates and ROTATE a rotation in
degrees.  A bitmap of a page rotated by 90 or 270 degrees is as wide as the
page is tall, so the two sides swap; 0 and 180 keep them.  The mapping is its
own inverse, which is why the same function converts a rotated size back to
the unrotated one."
  (if (memq (mod (or rotate 0) 360) '(90 270))
      (cons (cdr size) (car size))
    (cons (car size) (cdr size))))

(defun seshat-reader-select--unrotate-point (point rotate size)
  "Map POINT from rotated image space back to unrotated page space.
POINT is a cons (X . Y) in the coordinate system of the rendered page, i.e.
in image space **after** ROTATE degrees have been applied, expressed in page
coordinates rather than device pixels.  SIZE is the **unrotated** size of the
page as a cons (W . H) in the same units; the quarter turns and 180 need it
because the mapping mirrors a coordinate, and it is ignored for ROTATE 0.

The mapping inverts the transform the native renderer builds with
`fz_transform_page' (`render/render-core.c'), which turns the page clockwise
on screen by ROTATE degrees.  Written in image space, a point (X Y) of the
unrotated page (origin top-left, X to the right, Y down) lands at

    rotate    image x    image y
    0         X          Y
    90        H - Y      X
    180       W - X      H - Y
    270       Y          W - X

so the top-left corner (0, 0) of a page rotated by 90 degrees ends up in the
top-right corner of the bitmap, and the bitmap of that page is H wide and W
tall.  Both facts were checked against the renderer itself with a
four-quadrant probe page rendered at all four angles (2026-10-27), not only
derived from the formula."
  (let ((x (car point))
        (y (cdr point)))
    (cond
     ((= rotate 90) (cons y (- (cdr size) x)))
     ((= rotate 180) (cons (- (car size) x) (- (cdr size) y)))
     ((= rotate 270) (cons (- (car size) y) x))
     (t (cons x y)))))

(defun seshat-reader-select--unrotate-rect (rect rotate size)
  "Map RECT from rotated image space back to unrotated page space.
RECT is (X0 Y0 X1 Y1) in the image space of a page rotated by ROTATE degrees
and SIZE is the unrotated page size (W . H); the arithmetic is
`seshat-reader-select--unrotate-point'.  Both opposite corners are mapped and
the result normalized, because a quarter turn changes which of them is the
low corner; for ROTATE 0 the value is the bounding box of the same two
corners, i.e. RECT itself for the normalized rectangles this module deals
in."
  (let* ((a (seshat-reader-select--unrotate-point
             (cons (nth 0 rect) (nth 1 rect)) rotate size))
         (b (seshat-reader-select--unrotate-point
             (cons (nth 2 rect) (nth 3 rect)) rotate size))
         (x0 (car a))
         (x1 (car b))
         (y0 (cdr a))
         (y1 (cdr b)))
    (list (min x0 x1) (min y0 y1) (max x0 x1) (max y0 y1))))

;;; 显示口径（A+ 修复）

;; 页面坐标的单位是 native（页的点），而鼠标报的是**显示像素**，两者之间只差
;; 一个系数：显示 scale。它曾经取自 `--multipage-base-scale'（文档打开那一刻
;; fit 出来的基准值），但窗口 resize 只重写每页 spec 的 `:width'/`:height'
;; （`seshat-reader--apply-display-scale'），基准值不动，于是 resize 之后两者
;; 分叉（实测 base 1.0 / 实际显示 0.25）：换算把整页宽的拖拽压成页面坐标
;; 0..153（页宽 612），每行只剩左侧 1/4 的字。下面的函数一律按「显示即真相」
;; 测量——行里那幅图多大，分母就是多少。

(defun seshat-reader-select--page-spec (page window)
  "Return the image spec PAGE displays in the buffer of WINDOW, or nil.
PAGE is a 1-based page number and WINDOW a window that may show a buffer with
page rows.  The spec is read from the buffer-local `seshat-reader--pages' of
**that** buffer, following the layout used there: an entry is
\(PAGE MARKER . SPEC), so the spec is its `cddr'.

nil means WINDOW shows no buffer with page rows, or that PAGE has no row in
it.  Reading the page table of the window's buffer instead of the current one
is what keeps the measurement right when the drag runs while another buffer
is current."
  (when (and (integerp page) (windowp window))
    (let ((buffer (window-buffer window)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (and (boundp 'seshat-reader--pages)
               (cddr (assq page seshat-reader--pages))))))))

(defun seshat-reader-select--page-native-size (page window)
  "Return the unscaled native size of PAGE in the buffer of WINDOW, or nil.
PAGE is a 1-based page number and WINDOW a window that may show a buffer with
page rows.  The size is `seshat-reader--multipage-native-size' read **in that
buffer**, because the table behind it is buffer-local; it is the size of the
page at scale 1.0, i.e. the unit the coordinates of
`seshat-reader-select-posn->page' are expressed in.

nil means PAGE has no row yet, has not been rendered, or the vendored reader
does not expose the native size."
  (when (and (integerp page) (windowp window))
    (let ((buffer (window-buffer window)))
      (when (and (buffer-live-p buffer)
                 (fboundp 'seshat-reader--multipage-native-size))
        (with-current-buffer buffer
          (ignore-errors (seshat-reader--multipage-native-size page)))))))

(defun seshat-reader-select--display-scale (page window)
  "Return the scale PAGE is displayed at in WINDOW, or nil.
PAGE is a 1-based page number and WINDOW the window showing it.  The value is
the ratio of the size the page row actually displays to the native size of
the page:

    display scale = spec `:width' / native width

so it is 0.25 for a 612 pt wide page whose row holds a 153 px wide bitmap —
the scale a fully zoomed out page is fitted at, and the divisor
`seshat-reader-select-posn->page' needs to turn image pixels back into page
coordinates.  It is **not** `seshat-reader--multipage-base-scale': that value
is the scale the document was fitted at when it was opened, and a resize
rewrites the page specs without touching it, which is exactly how the two
drift apart.

A quarter turn does **not** swap the sides here.  Both quantities are taken in
the rotated orientation and are therefore divided as they are: the spec is the
bitmap the row displays, rendered with `seshat-reader--multipage-rotate'
applied, and the native size is that same bitmap divided by its render scale
\(`seshat-reader--multipage-record-native'), so the two always face the same
way and their ratio is the scale and nothing else.  Swapping one side would
inflate the answer by width/height (612x792 gives 1.294x, i.e. page
coordinates compressed by 23%, which loses the right part of every line on a
rotated page).  Only the functions whose answer is in page coordinates
\(`seshat-reader-select--page-space-size', `--posn-page-extent') exchange the
sides through `seshat-reader-select--unrotate-size', because the module takes
rectangles in unrotated page space.

When the width of the spec is unusable the height is used instead, and nil is
returned when neither is usable, when PAGE has no row or no native size, or
when the resulting scale would not be positive."
  (let ((spec (seshat-reader-select--page-spec page window))
        (native (seshat-reader-select--page-native-size page window)))
    (when (and spec
               (consp native)
               (numberp (car native)) (> (car native) 0)
               (numberp (cdr native)) (> (cdr native) 0))
      (let* ((width (image-property spec :width))
             (height (image-property spec :height))
             (scale (cond
                     ((and (numberp width) (> width 0))
                      (/ (float width) (float (car native))))
                     ((and (numberp height) (> height 0))
                      (/ (float height) (float (cdr native)))))))
        (and scale (> scale 0) scale)))))

(defun seshat-reader-select--page-scale (window &optional page)
  "Return the page scale of WINDOW, or nil when it is unusable.
The scale is the one the page is **displayed** at, so it is asked of
`seshat-reader-select--display-scale' first, which measures PAGE against the
image spec its row really shows.

PAGE defaults to nil, meaning \"the page is unknown\": the measurement is
skipped and the document scale answers instead, which is what this function
always returned before the display scale was measured.  The document scale
comes from `seshat-reader-current-doc-scale-value' and is only a fallback,
because it is the scale the document was fitted at **when it was opened**
\(`seshat-reader--multipage-base-scale'): a resize rewrites the size of every
page row without touching that base value, so after a resize the base scale
and the displayed size disagree, and dividing by the base one shrinks the
page coordinates to a fraction of the page (measured 2026-10-28: a full width
drag came back as page x 0..153 on a page 612 pt wide, so only the left
quarter of every line was selected).

A nil or non-positive answer from either source is reported as nil.

Note that the two sources do not read the same buffer: the fallback answers
from `seshat-reader-current-doc-scale-value', i.e. from the base scale of the
**current** buffer, while the display scale reads the page table of the buffer
WINDOW displays.  The drag path runs with the reader buffer current, so the
two agree there; a caller running in another buffer (a test, a batch job)
should make the window's buffer the one it means, or pass PAGE to stay on the
measured path."
  (let ((scale (or (ignore-errors
                     (seshat-reader-select--display-scale page window))
                   (ignore-errors
                     (seshat-reader-current-doc-scale-value window)))))
    (and (numberp scale) (> scale 0) (float scale))))

(defun seshat-reader-select-posn-page (posn &optional window)
  "Return the 1-based page number POSN points into, or nil.

POSN is a position list as returned by `event-start' or `event-end';
WINDOW defaults to the window of POSN.

The page is looked up from the **buffer position** of the event
\(`posn-point') through `seshat-reader--multipage-page-at-pos', i.e. from the
page row the click landed on, not from the page at the top of the viewport:
the multi-page layout shows several pages at once, so the top page says
nothing about which page a click belongs to.  The top page
\(`seshat-reader-current-doc-pagenumber') is used as a fallback when the
position cannot be mapped to a row — a click in the gap between two pages, a
buffer whose rows are gone, or a batch frame without redisplay information.

nil is returned when neither source yields a page number."
  (let ((win (or window (posn-window posn))))
    (when (windowp win)
      (or (when (fboundp 'seshat-reader--multipage-page-at-pos)
            (seshat-reader--multipage-page-at-pos (posn-point posn)))
          (ignore-errors (seshat-reader-current-doc-pagenumber win))))))

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
`seshat-reader-select--display-scale', i.e. from the size the page row really
displays over the native size of the page — the scale of the document as it
is **on screen now**, not the one it was fitted at when it was opened.  The
page whose scale is measured is the one POSN landed on, as answered by
`seshat-reader-select-posn-page'.  The result is meant to be passed,
over the rectangle formed by two such positions, to
`seshat-reader-dyn--text-in-rect'.

That arithmetic describes the page as it is **displayed**, i.e. after
`seshat-reader--multipage-rotate' was applied by the renderer, while the
module takes rectangles in unrotated page coordinates.  The value is
therefore mapped back through `seshat-reader-select--unrotate-point' using
the page size measured by `seshat-reader-select--posn-page-extent'.  For
rotation 0 the mapping is the identity and the returned value is exactly what
the formula above gives; for the other angles it is the same point expressed
in page space, and nil is returned (with a message) when the page size is
unknown, because a quarter turn cannot be undone without it.

The result is **page-local**: `posn-object-x-y' reports the offset inside the
image under the mouse, so the coordinates already belong to the page the click
landed on, whatever page the viewport starts at.  The page that owns them is
`seshat-reader-select-posn-page', which `seshat-reader-select-extract' uses to
reject a drag that spans two pages (P1 shows several pages per screen, so a
drag across a page boundary is a real case, not an edge case)."
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
            (scale (seshat-reader-select--page-scale
                    window (seshat-reader-select-posn-page posn window))))
        (cond
         ((not (consp xy))
          (message "Seshat Reader select: no image pixel offset at position.")
          nil)
         ((null scale)
          (message "Seshat Reader select: page scale is zero or invalid.")
          nil)
         (t
          (let* ((factor (/ (seshat-reader-select--frame-scale
                             (window-frame window))
                            scale))
                 (rotate (seshat-reader-select--page-rotate window))
                 (point (cons (* (float (car xy)) factor)
                              (* (float (cdr xy)) factor)))
                 ;; 只有 rotate=0 才不需要页尺寸，其余角度都要靠它镜像坐标；
                 ;; 量不到时宁可报错返回 nil，也不把「旋转后坐标」当成页面
                 ;; 坐标交给模块（那会静默取到错位置的字）。
                 (size (and (/= rotate 0)
                            (seshat-reader-select--posn-page-extent
                             posn window))))
            (cond
             ((= rotate 0) point)
             ((null size)
              (message "Seshat Reader select: page size unknown, cannot map a rotated page.")
              nil)
             (t (seshat-reader-select--unrotate-point point rotate size)))))))))))

(defun seshat-reader-select--report (text)
  "Report the extracted TEXT as a line count and a character count.
Nothing of TEXT itself is echoed — the echo area only says how much
was selected, e.g. \"已复制 3 行 · 145 字\", so that a long selection
cannot flood the minibuffer or leak the page content into it.

Line count is the number of newlines plus one (TEXT is passed through
`string-trim' first, so surrounding blank lines do not count) and
character count is `length' of the trimmed string, i.e. code points: a
CJK character counts as one character, not as its bytes.

The wording follows `seshat-reader-select-copy-to-kill-ring': when it
is non-nil the trimmed TEXT really is pushed with `kill-new' and the
report says 已复制; when it is nil nothing is copied and the report
says 已选中.  Empty or nil TEXT keeps the older, explanatory message
about the rectangle holding no text, and copies nothing either way."
  (let ((str (and text (string-trim text))))
    (if (or (null str) (equal str ""))
        (message "Seshat Reader select: no text in the selected rectangle.")
      (when seshat-reader-select-copy-to-kill-ring
        (kill-new str))
      (let ((lines (1+ (cl-count ?\n str)))
            (chars (length str)))
        (if seshat-reader-select-copy-to-kill-ring
            (message "Seshat Reader select: 已复制 %d 行 · %d 字" lines chars)
          (message "Seshat Reader select: 已选中 %d 行 · %d 字"
                   lines chars))))))

(defun seshat-reader-select--rects-in-rect (page x0 y0 x1 y1)
  "Return the selection geometry for the characters in a region.
PAGE is the 0-based page number the module expects, X0, Y0, X1 and Y1
are page coordinates — exactly the arguments given to
`seshat-reader-dyn--text-in-rect' for the same rectangle, so the
geometry matches the extracted text.

Which characters the geometry covers is decided by
`seshat-reader-select-highlight-scope':

  `line'    ask the module for whole lines
            (`seshat-reader-dyn--lines-in-rect'): a line touched
            anywhere by the rectangle is reported in full.  The result
            is used as-is, without `seshat-reader-select--merge-char-rects':
            the rectangles already span their line, so merging could
            only join two neighbouring lines into one bar.
  `region'  the historical path: one rectangle per hit character
            (`seshat-reader-dyn--rects-in-rect'), run together into
            per-line rectangles by `seshat-reader-select--merge-char-rects'.

Either way the rectangles are finally shrunk vertically by
`seshat-reader-select-highlight-shrink-ratio', and either way a `line'
scope falls back to the `region' path without an error when the module
does not export `seshat-reader-dyn--lines-in-rect' (an older build).

Return nil when the module provides neither function or when the region
holds no character: a region without text is a normal outcome, not an
error, and must not produce a message."
  (let ((scope seshat-reader-select-highlight-scope)
        (lines-fn (and (fboundp 'seshat-reader-dyn--lines-in-rect)
                       'seshat-reader-dyn--lines-in-rect)))
    (cond
     ((and (eq scope 'line) lines-fn)
      (let ((lines (ignore-errors
                     (seshat-reader-dyn--lines-in-rect page x0 y0 x1 y1))))
        (when lines
          (seshat-reader-select--shrink-rects-vertically
           (seshat-reader-select--sort-rects
            (delq nil (mapcar #'seshat-reader-select--normalize-rect lines)))
           (seshat-reader-select--highlight-shrink-ratio)))))
     ((fboundp 'seshat-reader-dyn--rects-in-rect)
      (seshat-reader-select--merge-char-rects
       (ignore-errors
         (seshat-reader-dyn--rects-in-rect page x0 y0 x1 y1)))))))

;;; Cross-page selections (P2-A T2)

;; A drag can start on one page and end on the next once several pages share a
;; window, so the selection is no longer one rectangle: it is one rectangle per
;; page covered, clipped to the page boundaries, and the module is asked page by
;; page (it only ever reads a single page).  Nothing here touches the C side.

(defconst seshat-reader-select--page-extent-fallback 1.0e7
  "Page height assumed when the pixel size of a page cannot be measured.
Clipping a cross-page selection to the page boundary needs the height of
the page; `posn-object-width-height' answers it, but only when redisplay
information is available (a batch frame carries none).  A value this large
covers any page: the native module only reports text the page really
holds, so an over-long rectangle cannot reach anything outside it.")

(defun seshat-reader-select--posn-page-extent (posn window)
  "Return the size of the page under POSN as (W . H), in page coordinates.
POSN is a position list as returned by `event-start' or `event-end', and
WINDOW the window showing the page.  The size is the image size of the
page (`posn-object-width-height', in image pixels) scaled with the very
factor `seshat-reader-select-posn->page' applies to a position, i.e. frame
scale over page scale, so a rectangle built from it lives in the same
coordinate system as the two converted drag positions.

The image size is the size of the **rendered** page, i.e. of the bitmap after
`seshat-reader--multipage-rotate' was applied, and a quarter turn makes that
bitmap as wide as the page is tall.  The value is therefore passed through
`seshat-reader-select--unrotate-size', so what comes back always describes
the unrotated page — the coordinate system the module takes rectangles in.

nil is returned when the size cannot be measured: POSN is not over a page
image, WINDOW has no usable page scale, or `posn-object-width-height' answers
nil (a batch frame carries no redisplay information)."
  (when (and (windowp window)
             (eq (car-safe (posn-object posn)) 'image))
    (let ((size (ignore-errors (posn-object-width-height posn)))
          (scale (seshat-reader-select--page-scale
                  window (seshat-reader-select-posn-page posn window))))
      (when (and (consp size)
                 (numberp (car size))
                 (numberp (cdr size))
                 scale)
        (let ((factor (/ (seshat-reader-select--frame-scale
                          (window-frame window))
                         scale)))
          (seshat-reader-select--unrotate-size
           (cons (* (float (car size)) factor)
                 (* (float (cdr size)) factor))
           (seshat-reader-select--page-rotate window)))))))

(defun seshat-reader-select--page-space-size (page window)
  "Return the unrotated size of PAGE as (W . H) in page coordinates, or nil.
PAGE is a 1-based page number and WINDOW the window showing it.  The size
comes from `seshat-reader--multipage-native-size', i.e. from the bitmap the
row already displays divided by the scale it was rendered at — no rendering
happens here.  Because that bitmap carries the current rotation, the size is
passed through `seshat-reader-select--unrotate-size' to describe the unrotated
page, and the frame scale factor lifts it to the unit
`seshat-reader-select-posn->page' converts positions into.

nil means the page has no row, has not been rendered yet, or the vendored
reader does not expose the native size; callers then fall back to the size
measured on the page the drag started on."
  (when (and (integerp page) (windowp window))
    (let ((native (and (fboundp 'seshat-reader--multipage-native-size)
                       (ignore-errors
                         (seshat-reader--multipage-native-size page)))))
      (when (and (consp native)
                 (numberp (car native)) (> (car native) 0)
                 (numberp (cdr native)) (> (cdr native) 0))
        (let ((factor (seshat-reader-select--frame-scale (window-frame window))))
          (seshat-reader-select--unrotate-size
           (cons (* (float (car native)) factor)
                 (* (float (cdr native)) factor))
           (seshat-reader-select--page-rotate window)))))))

(defun seshat-reader-select--selection-page-rects (start-page start-number
                                                              end-page end-number
                                                              start-posn window)
  "Return the drag rectangle of every page covered, as (PAGE . RECT) pairs.
START-PAGE and END-PAGE are the two drag positions converted to page
coordinates by `seshat-reader-select-posn->page', while START-NUMBER and
END-NUMBER are the pages those positions landed on, as answered by
`seshat-reader-select-posn-page'.  Either number may be nil; the selection
is then treated as covering the number that is known, or page 1 when none
is.  START-POSN and WINDOW locate the page image whose size a clipped page
is measured on.

The value is in reading order (ascending page number) and every rectangle
is in page coordinates.  The horizontal extent is the same on every page —
a drag selects one column band — while the vertical one is clipped to the
page: the first page is selected from the drag position down to its bottom
edge, the last one from its top edge down to the drag position, and the
pages in between in full.  A drag that covers a single page therefore
yields exactly the bounding box of its two positions, which is what the
single-page code stored before cross-page selections existed.

The bottom edge of a page is that page's **own** height, because the pages of
one document do not have to be equally tall — a cover page next to body pages
is the common case, and clipping every page with the height of the page the
drag started on would cut text away on a taller page.  The own height is read
from the native size of the page's row, i.e. from
`seshat-reader-select--page-space-size', the same unrotated page size the two
drag positions are expressed in, so it is used **as it is**: every quantity
here is now the same unit (page coordinates, i.e. native size times the frame
scale), because `seshat-reader-select-posn->page' divides by the **displayed**
page scale.
The ratio this function used to calibrate the two units with is therefore
identically 1 and is gone.  The height still comes from two fallbacks, in
this order:

  1. the page's own size, when its row has been rendered;
  2. the height measured on the start page (`--posn-page-extent'), then
     `seshat-reader-select--page-extent-fallback', when it has not.

Erring long is deliberate and harmless (the native module only reports text
the page really holds), while a short rectangle loses text, so every fallback
goes to the longer value.  All sizes are unrotated, i.e. they live in the same
page space as the rectangles."
  (let* ((first (or (and start-number end-number (min start-number end-number))
                    start-number
                    end-number
                    1))
         (last (if (and start-number end-number)
                   (max start-number end-number)
                 first))
         (x0 (min (car start-page) (car end-page)))
         (x1 (max (car start-page) (car end-page))))
    (if (= first last)
        (list (cons first (list x0
                                (min (cdr start-page) (cdr end-page))
                                x1
                                (max (cdr start-page) (cdr end-page)))))
      (let* ((extent (seshat-reader-select--posn-page-extent start-posn window))
             (height (or (cdr extent)
                         seshat-reader-select--page-extent-fallback))
             (start-on-first (and start-number (= first start-number)))
             (first-y (if start-on-first (cdr start-page) (cdr end-page)))
             (last-y (if start-on-first (cdr end-page) (cdr start-page)))
             ;; 每页有自己的高度：`--posn-page-extent' 只量到起点页，而封面与
             ;; 正文的页高经常不同，用同一个高度裁剪会让中间页的矩形越界或不足
             ;; （越界无害，模块只报页内真有的字；不足会丢字）。口径统一后
             ;; `--page-space-size' 的绝对值就是页面坐标（native × frame
             ;; scale），不再需要比例校准；量不到（页没有行 / 尚未渲染）才
             ;; 退回起点页量到的高度，再退常量。
             rects)
        (cl-labels ((page-height (page)
                      "Height of PAGE in page coordinates, or the fallback."
                      (or (cdr (seshat-reader-select--page-space-size
                                page window))
                          height)))
          (cl-loop for page from first to last
                   do (push (cons page
                                  (list x0
                                        (if (= page first) first-y 0.0)
                                        x1
                                        (if (= page last) last-y
                                          (page-height page))))
                            rects)))
        (nreverse rects)))))

(defun seshat-reader-select--page-selection (page-rects)
  "Return the text and the geometry of every page in PAGE-RECTS.
PAGE-RECTS is the (PAGE . RECT) list answered by
`seshat-reader-select--selection-page-rects', i.e. in reading order.
Every page is read on its own with the native module, the 1-based page
number converted to the 0-based one the module takes.  The value is a list
of (PAGE TEXT RECTS) items, one per page, where TEXT is what the page
rectangle holds and RECTS the per-line geometry of that page (nil when the
module cannot report it)."
  (mapcar (lambda (entry)
            (cl-destructuring-bind (page x0 y0 x1 y1) entry
              (list page
                    (seshat-reader-dyn--text-in-rect (1- page) x0 y0 x1 y1)
                    (seshat-reader-select--rects-in-rect (1- page)
                                                         x0 y0 x1 y1))))
          page-rects))

(defun seshat-reader-select--join-page-texts (texts)
  "Join TEXTS, the text read on each selected page, into one string.
A single page keeps its text untouched — no trimming and no filtering — so a
one-page selection stays byte-identical to what the pre-cross-page code
reported.  Several pages are joined in reading order with one newline between
two pages, because `seshat-reader-dyn--text-in-rect' does not keep the line
breaks; pages that contributed no text at all (an image page, or a page whose
rectangle held nothing) are dropped **before** the join, so a selection whose
first or last page is empty does not begin or end with a bare newline.  nil
when no page contributed any text, which is how the single-page code reported
an empty selection."
  (when (cl-some #'identity texts)
    (if (cdr texts)
        (when-let* ((kept (cl-remove-if (lambda (text)
                                          (or (null text) (equal text "")))
                                        texts)))
          (mapconcat #'identity kept "\n"))
      (car texts))))

(defun seshat-reader-select--flatten-page-rects (pages)
  "Flatten PAGES, as answered by `seshat-reader-select--page-selection'.
Every rectangle becomes a (PAGE X0 Y0 X1 Y1) item, in reading order, so a
consumer that has to draw several pages at once can tell them apart.  Pages
that reported no geometry contribute nothing, which keeps the value
one-to-one with `:rects' for a single page."
  (let (flat)
    (dolist (item pages)
      (dolist (rect (nth 2 item))
        (push (cons (car item) rect) flat)))
    (nreverse flat)))

(defun seshat-reader-select-extract (start end)
  "Extract the text between the mouse positions START and END.
START and END are position lists, as produced by `event-start' and
`event-end', that must belong to the same window showing a seshat-reader
page.

Return the extracted text, or nil when the two positions are not in
the same window, when either of them cannot be converted to page
coordinates, or when the corresponding rectangle contains no text.

The two positions may belong to **different pages**: with the multi-page
layout a drag can start on one page and end on the next.  The pages between
them are then read one by one, each page rectangle clipped to the page
boundary, and their texts are joined in reading order with one newline
between two pages (the module does not keep line breaks).  Which page a
position landed on is `seshat-reader-select-posn-page', i.e. looked up from
the row the event landed on; a position in the gap that follows a page row
belongs to that page, so the answer only changes at the start of the next
row — no \"nearest page\" rule is applied.

Besides reporting the text, the selection is recorded in
`seshat-reader-select-last': the drag's bounding box under :rect, the
per-line rectangles hugging the selected characters under :rects and those
same rectangles tagged with their page under :page-rects.  :page, :rect and
:rects always describe the page the drag **started** on — the whole
selection for a one-page drag, its first page only for a cross-page one.
The flash that confirms the selection uses those per-line rectangles,
falling back to the bounding box when there are none."
  (let ((window (posn-window start)))
    (cond
     ((not (eq window (posn-window end)))
      (message "Seshat Reader select: the drag must stay inside one window.")
      nil)
     (t
      (let ((start-page (seshat-reader-select-posn->page start window))
            (end-page (seshat-reader-select-posn->page end window))
            ;; 两端各落在哪一页（按 posn 的 buffer 位置反查，不是视口顶页）。
            (start-page-number (seshat-reader-select-posn-page start window))
            (end-page-number (seshat-reader-select-posn-page end window)))
        ;; 跨页拖拽不再拒绝：页区间与逐页取文由 `--selection-page-rects' /
        ;; `--page-selection' 完成，单页时它们退化成 P2-A 之前的同一个 bbox。
        (when (and start-page end-page)
          (let* ((page-rects (seshat-reader-select--selection-page-rects
                              start-page start-page-number
                              end-page end-page-number
                              start window))
                 ;; 逐页取文与几何；模块的页号是 0-based，页区间是 1-based，
                 ;; 换算只在 `--page-selection' 里做一次。
                 (pages (seshat-reader-select--page-selection page-rects))
                 ;; :page / :rect / :rects 都描述**起点页**：单页拖拽时就是整个
                 ;; 选区，跨页时只是首页那一段（见 `seshat-reader-select-last'）。
                 (index (or (and start-page-number
                                 (cl-position start-page-number page-rects
                                              :key #'car :test #'=))
                            0))
                 (text (seshat-reader-select--join-page-texts
                        (mapcar #'cadr pages)))
                 (bbox (cdr (nth index page-rects)))
                 (rects (nth 2 (nth index pages))))
            (setq seshat-reader-select-last
                  (list :text text
                        ;; :page must be the 1-based page number reported by
                        ;; seshat-reader; the module takes a 0-based one, which
                        ;; `--page-selection' subtracts once per page.
                        :page (or start-page-number
                                  (seshat-reader-current-doc-pagenumber window))
                        :rect bbox
                        :rects rects
                        :page-rects (seshat-reader-select--flatten-page-rects
                                     pages)
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

The whole gesture runs with the **buffer** of the window the drag started in
current, because the native text extraction resolves the document through the
buffer-local `seshat-reader-current-doc-state-ptr'.  P1 changed this: the
single-page code had to select that window, since the C side resolved the
document through `(selected-window)'; selecting a window during a drag would
now move point and disturb the pixel scroll position the viewport is sitting
at, so the selected window, point and `window-start' are left untouched.

When the button is released, the selection rectangle is converted
to page coordinates and its text is reported by
`seshat-reader-select-extract'; see there for the exact semantics."
  (interactive "e")
  (let* ((start (event-start start-event))
         (window (posn-window start))
         (end start)
         (moved nil)
         (finished nil))
    ;; 整段手势在**被拖窗口的 buffer** 里执行：C 侧的文本抽取按
    ;; buffer-local 的 `seshat-reader-current-doc-state-ptr' 解析文档，故只需
    ;; 当前 buffer 正确。不 `select-window'：那会移动 point 并打断像素滚动
    ;; 停留的位置（见本函数 docstring）。
    (with-current-buffer (if (windowp window)
                             (window-buffer window)
                           (current-buffer))
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
        nil))))

(defun seshat-reader-select-describe-posn (event)
  "Report the raw and converted coordinates of the mouse EVENT.
This is a calibration helper for `seshat-reader-select-posn->page':
it prints the image pixel offset returned by `posn-object-x-y', the
page coordinates computed from it and the scale factors involved.
`display-scale' is the scale measured on the displayed page row — the divisor
the conversion uses — while `page-scale' is what the conversion was handed in
total (it falls back to the document scale when the page cannot be measured);
comparing the two is how a drift between the base scale and the displayed one
is spotted on a live frame."
  (interactive "e")
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (number (and (windowp window)
                      (seshat-reader-select-posn-page posn window)))
         (page (seshat-reader-select-posn->page posn window)))
    (message "Seshat Reader select: pixel=%S page=%S page-scale=%S display-scale=%S frame-scale=%S"
             (posn-object-x-y posn)
             page
             (and (windowp window) (seshat-reader-select--page-scale window number))
             (and (windowp window)
                  (seshat-reader-select--display-scale number window))
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
