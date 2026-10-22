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

(defun seshat-reader-select--flash-selection (page rect)
  "Flash the selection rectangle RECT on PAGE for a moment.
PAGE is the 1-based page number and RECT the selection rectangle as
a list (X0 Y0 X1 Y1) in page coordinates — exactly what
`seshat-reader-select-last' stores under :rect, so the flash and the
annotation create path (`seshat-reader-annotation-create') use the same
units.

The rectangle is stored in the buffer-local
`seshat-reader-select--flash-rects' and fed to the C renderer; a timer
clears it again after `seshat-reader-select-flash-duration' seconds.
The flash is skipped when the duration is not positive or when PAGE /
RECT are unusable (a degenerate rectangle cannot be drawn).

Repeated selections in the **same buffer** cancel the previous timer, so
that an old clear cannot wipe a fresh flash; selections in different
buffers keep independent timers (both
`seshat-reader-select--flash-timer' and `seshat-reader-select--flash-rects'
are buffer-local).  Everything is wrapped in `ignore-errors': a missing
module or an unusable C call must never break text extraction."
  (let ((duration seshat-reader-select-flash-duration))
    (when (and (numberp duration) (> duration 0)
               (seshat-reader-select--rect-valid-p page rect))
      (ignore-errors
        (when (timerp seshat-reader-select--flash-timer)
          (cancel-timer seshat-reader-select--flash-timer))
        (setq-local seshat-reader-select--flash-rects
                    (list (list page (nth 0 rect) (nth 1 rect)
                                (nth 2 rect) (nth 3 rect))))
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
         `seshat-reader-dyn--text-in-rect');
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

(defun seshat-reader-select-extract (start end)
  "Extract the text between the mouse positions START and END.
START and END are position lists, as produced by `event-start' and
`event-end', that must belong to the same window showing a seshat-reader
page.

Return the extracted text, or nil when the two positions are not in
the same window, when either of them cannot be converted to page
coordinates, or when the corresponding rectangle contains no text."
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
                 (text (seshat-reader-dyn--text-in-rect page x0 y0 x1 y1)))
            (setq seshat-reader-select-last
                  (list :text text
                        ;; :page must be the 1-based page number reported by
                        ;; seshat-reader; the local `page' above is 0-based (for
                        ;; the module) and therefore must not be reused here.
                        :page (seshat-reader-current-doc-pagenumber window)
                        :rect (list x0 y0 x1 y1)
                        :file (buffer-file-name (window-buffer window))))
            (seshat-reader-select--report text)
            ;; 选区已确定（不论矩形内是否有文本）就用高亮闪一下，让用户看到自己
            ;; 选中的区域；闪现落在发起拖拽的 buffer 上（`--flash-selection' 读写
            ;; 的 `seshat-reader-select--flash-rects' 是 buffer-local 的）。
            (with-current-buffer (window-buffer window)
              (seshat-reader-select--flash-selection
               (seshat-reader-current-doc-pagenumber window)
               (list x0 y0 x1 y1)))
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
