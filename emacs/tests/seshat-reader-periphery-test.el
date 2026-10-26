;;; seshat-reader-periphery-test.el --- Tests for the T8 periphery adaptation  -*- lexical-binding: t; -*-

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

;; P1 批次 7（T8）的 ERT 套件：把**外围模块**从单页 overlay 语义迁到多页语义
;; 之后的行为断言，全部围绕「页号从哪来、页内偏移怎么记、装饰怎么刷新」：
;;
;;   · 选区：`seshat-reader-select-posn-page' 按 posn 落在哪一页行反查页号，
;;     跨页拖选 `user-error'，同页拖选行为不变，拖拽不动选中窗口/window-start。
;;   · 书签/saveplace：page + offset（页内像素偏移）+ hscroll + scale +
;;     fit-mode 的保存与恢复，以及旧记录 `vscroll' → `offset' 的迁移。
;;   · 搜索/引用跳转：落在页首（vscroll 归 0），页号取视口顶页。
;;   · 装饰刷新：`seshat-reader--multipage-refresh-decorations' 逐驻留页重渲染
;;     （装饰烘在位图里），非驻留页不动，且不再调用
;;     `--refresh-highlights'（单页 overlay 已不存在）。
;;
;; 纪律：不触网、不碰真实文档、不触 GUI；动态模块入口与窗口访问函数一律
;; `cl-letf' 桩替；`skipped' 必须恒为 0，故不用 `skip-unless'。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
(require 'seshat-reader-select)
(require 'seshat-reader-bookmark)
(require 'seshat-reader-saveplace)
(require 'seshat-reader-search)
(require 'seshat-reader-reference)

;;;; 夹具

(defun seshat-reader-periphery-test--reader-buffer (&optional pages width height)
  "Create a reader buffer holding one page row per page in PAGES.
Each row displays a fake image spec of WIDTH x HEIGHT (600x800 by default) and
records the matching native size at scale 1.0, the state a first render leaves
behind.  Returns the buffer."
  (let ((buffer (generate-new-buffer " *seshat-reader-periphery-test*")))
    (with-current-buffer buffer
      (setq major-mode 'seshat-reader-mode
            mode-name "Seshat Reader")
      (setq-local seshat-reader--multipage-base-scale 1.0
                  seshat-reader--multipage-fit-mode 'contain
                  seshat-reader--recent-scale-fallback 1.0)
      (use-local-map seshat-reader-mode-map)
      (dolist (page (or pages '(1 2 3)))
        (let ((spec (list 'image :type 'pbm :data "x"
                          :width (or width 600) :height (or height 800))))
          (seshat-reader--multipage-insert-page page spec)
          (seshat-reader--multipage-record-native page spec 1.0))))
    buffer))

(defun seshat-reader-periphery-test--row-start (page)
  "Return the first buffer position of the row of PAGE."
  (when-let* ((entry (assq page seshat-reader--pages))
              (marker (cadr entry)))
    (marker-position marker)))

(defmacro seshat-reader-periphery-test--with-window-buffer (buffer &rest body)
  "Display BUFFER in the selected window while BODY runs."
  (declare (indent 1) (debug t))
  `(let ((window (selected-window))
         (original (window-buffer (selected-window))))
     (unwind-protect
         (progn (set-window-buffer window ,buffer) ,@body)
       (set-window-buffer window original))))

(defun seshat-reader-periphery-test--load-select-source ()
  "Reload `seshat-reader-select' from source so `posn-*' stubs take effect.
`posn-window'/`posn-object'/`posn-object-x-y'/`posn-point' 在 Emacs 31 里可内联，
`.elc' 已把调用内联进 `seshat-reader-select-posn->page'，`cl-letf' 拦不住；改载
同源的 `.el' 即恢复运行时查找（语义不变）。"
  (let* ((elc (symbol-file 'seshat-reader-select-posn->page 'defun))
         (el (and elc (concat (file-name-sans-extension elc) ".el"))))
    (when (and el (file-exists-p el))
      (load el nil t t))))

(defun seshat-reader-periphery-test--fake-posn (window point &optional xy)
  "Return a fake position list for WINDOW at buffer POINT.
XY is the image pixel offset (`posn-object-x-y'), (10 . 20) by default."
  (list window 5 point (cons 0 0) 100
        (list 'image :type 'pbm :data "x")
        (cons 0 0)
        (or xy (cons 10 20))))

(defmacro seshat-reader-periphery-test--with-posn-stubs (window &rest body)
  "Run BODY with the `posn-*' accessors answering for WINDOW.
`posn-window' returns WINDOW, `posn-point' the buffer position stored in the
third element of the fake position list, `posn-object' a page image and
`posn-object-x-y' the pixel offset in its eighth element."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'posn-window) (lambda (_posn) ,window))
             ((symbol-function 'posn-point) (lambda (posn) (nth 2 posn)))
             ((symbol-function 'posn-object) (lambda (posn) (nth 5 posn)))
             ((symbol-function 'posn-object-x-y) (lambda (posn) (nth 7 posn)))
             ((symbol-function 'frame-scale-factor) (lambda (&optional _f) 1.0)))
     ,@body))

;;;; 1. 选区：页号反查

(ert-deftest seshat-reader-periphery-test--posn-page-reverse-lookup ()
  "The page of a click is the row it landed on, not the top of the viewport.

`seshat-reader-select-posn-page' 按 `posn-point' 反查页号：同一个窗口里，落在
第 2、3 页行的 posn 必须分别答 2 和 3，即使视口顶页是第 1 页。`posn->page' 的
坐标换算不变（图像像素 × frame scale ÷ 页 scale）。"
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (should (= 1 (seshat-reader-current-doc-pagenumber window)))
            (seshat-reader-periphery-test--with-posn-stubs window
              (let ((posn2 (seshat-reader-periphery-test--fake-posn
                            window (seshat-reader-periphery-test--row-start 2)))
                    (posn3 (seshat-reader-periphery-test--fake-posn
                            window (seshat-reader-periphery-test--row-start 3))))
                (should (= 2 (seshat-reader-select-posn-page posn2 window)))
                (should (= 3 (seshat-reader-select-posn-page posn3 window)))
                ;; 坐标仍是该页图内的像素坐标
                (should (equal (cons 10.0 20.0)
                               (seshat-reader-select-posn->page posn2 window)))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--posn-page-falls-back-to-top-page ()
  "A position that maps to no page row falls back to the viewport top page."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (seshat-reader-periphery-test--with-posn-stubs window
              ;; 落在 buffer 开头之后、第一页行之前的 newline 上
              (should (= 1 (seshat-reader-select-posn-page
                            (seshat-reader-periphery-test--fake-posn window 1)
                            window))))))
      (kill-buffer buffer))))

;;;; 2/3. 选区：跨页拒绝与同页不变

(ert-deftest seshat-reader-periphery-test--select-extract-rejects-cross-page ()
  "A drag spanning two pages signals `user-error' with the D7 message."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (seshat-reader-periphery-test--with-posn-stubs window
              (let ((start (seshat-reader-periphery-test--fake-posn
                            window (seshat-reader-periphery-test--row-start 1)))
                    (end (seshat-reader-periphery-test--fake-posn
                          window (seshat-reader-periphery-test--row-start 2))))
                (let ((err (should-error (seshat-reader-select-extract start end)
                                         :type 'user-error)))
                  (should (string-match-p "跨页" (error-message-string err))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--select-extract-same-page-returns-text ()
  "A same-page drag extracts text and records the page the click landed on."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (seshat-reader-select-last nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-parameter window 'scale 1.0)
            (seshat-reader-periphery-test--with-posn-stubs window
              (cl-letf (((symbol-function 'seshat-reader-dyn--text-in-rect)
                         (lambda (&rest _) "hello"))
                        ((symbol-function 'seshat-reader-select--rects-in-rect)
                         (lambda (&rest _) nil))
                        ((symbol-function 'seshat-reader-select--flash-selection)
                         (lambda (&rest _) t))
                        ((symbol-function 'message) (lambda (&rest _) nil)))
                (let ((start (seshat-reader-periphery-test--fake-posn
                              window (seshat-reader-periphery-test--row-start 2)))
                      (end (seshat-reader-periphery-test--fake-posn
                            window (1+ (seshat-reader-periphery-test--row-start 2))
                            (cons 200 400))))
                  (should (equal "hello" (seshat-reader-select-extract start end)))
                  (should (= 2 (plist-get seshat-reader-select-last :page)))
                  (should (equal '(10.0 20.0 200.0 400.0)
                                 (plist-get seshat-reader-select-last :rect))))))))
      (kill-buffer buffer))))

;;;; 4/5. 书签：保存/恢复与旧字段迁移

(defun seshat-reader-periphery-test--jump-calls (bookmark)
  "Jump to BOOKMARK with every UI side effect stubbed, return what was called.
The returned plist holds :scale (args of `--multipage-set-scale'), :page (arg
of `--multipage-goto'), :vscroll (args of `set-window-vscroll') and :hscroll."
  (let ((calls nil))
    (cl-letf (((symbol-function 'bookmark-default-handler) (lambda (&rest _) nil))
              ((symbol-function 'file-exists-p) (lambda (&rest _) t))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil))
              ((symbol-function 'seshat-reader-mode) (lambda (&rest _) nil))
              ((symbol-function 'derived-mode-p)
               (lambda (&rest _) 'seshat-reader-mode))
              ((symbol-function 'seshat-reader--multipage-set-scale)
               (lambda (&rest args) (setq calls (plist-put calls :scale args))))
              ((symbol-function 'seshat-reader--multipage-goto)
               (lambda (page) (setq calls (plist-put calls :page page)) page))
              ((symbol-function 'set-window-vscroll)
               (lambda (&rest args) (setq calls (plist-put calls :vscroll args))))
              ((symbol-function 'set-window-hscroll)
               (lambda (&rest args) (setq calls (plist-put calls :hscroll args)))))
      (seshat-reader-bookmark-jump bookmark))
    calls))

(ert-deftest seshat-reader-periphery-test--bookmark-round-trip ()
  "Page, offset, hscroll and scale are restored, the zoom as `manual'."
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 7)
                         (cons 'offset 120)
                         (cons 'hscroll 40)
                         (cons 'scale 1.5)
                         (cons 'fit-mode 'width)))
         (calls (seshat-reader-periphery-test--jump-calls bookmark)))
    (should (equal '(1.5 manual manual) (plist-get calls :scale)))
    (should (= 7 (plist-get calls :page)))
    (should (equal (list nil 120 t) (plist-get calls :vscroll)))
    (should (equal (list nil 40) (plist-get calls :hscroll)))))

(ert-deftest seshat-reader-periphery-test--bookmark-legacy-vscroll-migrates ()
  "A pre-P1 record carrying only `vscroll' is migrated to a pixel offset."
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 3)
                         (cons 'vscroll 80)))
         (calls (seshat-reader-periphery-test--jump-calls bookmark)))
    (should (= 3 (plist-get calls :page)))
    (should (equal (list nil 80 t) (plist-get calls :vscroll)))
    ;; 旧记录没有 scale → 不缩放
    (should-not (plist-get calls :scale))))

(ert-deftest seshat-reader-periphery-test--bookmark-invalid-scale-is-skipped ()
  "A missing or non-numeric scale skips the zoom instead of signalling."
  (let* ((bookmark (list (cons 'filename "/tmp/doc.pdf")
                         (cons 'page 2)
                         (cons 'offset nil)
                         (cons 'scale "big")))
         (calls (seshat-reader-periphery-test--jump-calls bookmark)))
    (should-not (plist-get calls :scale))
    (should (= 2 (plist-get calls :page)))
    ;; offset 非法 → 不设 vscroll（落到页首）
    (should-not (plist-get calls :vscroll))))

(ert-deftest seshat-reader-periphery-test--bookmark-record-has-p1-fields ()
  "The record carries page/offset/hscroll/scale/fit-mode and no `vscroll'."
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2))))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'bookmark-make-record-default)
                       (lambda (&rest _) nil)))
              (let ((record (seshat-reader-bookmark-make-record)))
                (should (= 1 (alist-get 'page record)))
                (should (numberp (alist-get 'offset record)))
                (should (assq 'hscroll record))
                (should (= 1.0 (alist-get 'scale record)))
                (should (eq 'contain (alist-get 'fit-mode record)))
                (should-not (assq 'vscroll record))))))
      (kill-buffer buffer))))

;;;; 6. saveplace 往返

(ert-deftest seshat-reader-periphery-test--saveplace-round-trip ()
  "Saveplace stores the bookmark record and restores it through the handler."
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
        (save-place-alist nil)
        (jumped nil))
    (unwind-protect
        (with-current-buffer buffer
          (setq buffer-file-name "/tmp/saveplace-doc.pdf")
          (cl-letf (((symbol-function 'bookmark-make-record-default)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-bookmark-jump)
                     (lambda (bookmark) (setq jumped bookmark) t))
                    ((symbol-function 'save-place-load-alist-from-file)
                     (lambda (&rest _) t)))
            (seshat-reader--saveplace-to-alist)
            (let* ((place (assoc "/tmp/saveplace-doc.pdf" save-place-alist))
                   (bookmark (aref (cdr place) 0)))
              (should place)
              (should (equal "seshat-reader-saveplace" (car bookmark)))
              (should (= 1 (alist-get 'page (cdr bookmark))))
              (should (assq 'offset (cdr bookmark)))
              ;; 往返：find-file 路径把记录交给同一处理函数
              (seshat-reader--saveplace-find-file)
              (should (equal (cdr bookmark) (cdr jumped))))))
      (kill-buffer buffer))))

;;;; 7. 搜索跳转停在页首

(ert-deftest seshat-reader-periphery-test--search-goto-lands-on-page-top ()
  "A search hit jump goes through the goto command and resets the pixel scroll."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (vscrolls nil)
         (gotos nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (&rest args) (push args vscrolls)))
                      ((symbol-function 'seshat-reader--multipage-sync)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage-render-page)
                       (lambda (&rest _) nil))
                      ((symbol-function 'seshat-reader--multipage--show-page)
                       (lambda (page) (push page gotos)
                              (seshat-reader-periphery-test--row-start page))))
              ;; 真实 `--multipage-goto'：必须把页内偏移清零
              (seshat-reader--multipage-goto 2)
              (should (equal (list (selected-window) 0 t) (car vscrolls)))
              ;; `--multipage-goto' 会 show 两次：先定位到目标页，sync 插入/回收
              ;; 页行之后再重定位一次（见其 docstring）。
              (should (equal '(2 2) gotos)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--search-jump-uses-goto-command ()
  "The search jump path calls the public goto command with the hit page."
  (let ((called nil))
    (cl-letf (((symbol-function 'seshat-reader-goto-page)
               (lambda (page) (setq called page))))
      (seshat-reader-search--goto-page 5))
    (should (= 5 called))))

;;;; 8. 引用 page:<n> 生成 → 跳回

(ert-deftest seshat-reader-periphery-test--reference-page-anchor-round-trip ()
  "A page anchor built from `page:<n>' jumps back to that page and reports it."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (messages nil)
         (called nil))
    (unwind-protect
        (with-current-buffer buffer
          ;; 生成：页号取**视口顶页**（多页布局下一屏多页，只能锚定顶页）。
          ;; 窗口几何本身由 multipage 套件覆盖，这里桩住页号以便断言锚点内容。
          (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                     (lambda (&optional _window) 2)))
            (let ((location (format "page:%d"
                                    (seshat-reader-current-doc-pagenumber))))
              (should (equal "page:2" location))
              (cl-letf (((symbol-function 'seshat-reader-goto-page)
                         (lambda (page) (setq called page)))
                        ((symbol-function 'message)
                         (lambda (fmt &rest args)
                           (push (apply #'format fmt args) messages))))
                (seshat-reader-reference--goto-location
                 (list :location location)))))
          (should (= 2 called))
          (should (seq-find (lambda (m) (string-match-p "2" m)) messages)))
      (kill-buffer buffer))))

;;;; 9/10. 装饰刷新

(ert-deftest seshat-reader-periphery-test--refresh-decorations-rerenders-resident ()
  "Every resident page is re-rendered once, old cached specs are dropped."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (renders 0))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            ;; 先塞一条「过期」缓存（第 1 页、另一个 scale）
            (setq seshat-reader--page-spec-cache
                  (list (cons (seshat-reader--page-spec-key 1 2.0 0) 'stale)))
            (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                       (lambda (page scale &optional _rotate)
                         (setq renders (1+ renders))
                         (list 'image :type 'pbm :data "x"
                               :width 600 :height 800 :page page :scale scale)))
                      ((symbol-function 'seshat-reader-dyn--refresh-highlights)
                       (lambda (&rest _) (error "Must not be called"))))
              (should (= 3 (seshat-reader--multipage-refresh-decorations window)))
              (should (= 3 renders))
              ;; 过期条目被清掉：第 1 页只留下新的（scale 1.0）那条
              (let ((page1 (cl-remove-if-not
                            (lambda (entry) (= 1 (car (car entry))))
                            seshat-reader--page-spec-cache)))
                (should (= 1 (length page1)))
                (should-not (eq 'stale (cdr (car page1))))))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--refresh-decorations-skips-non-resident ()
  "Only pages with a row are re-rendered, never a page outside the layout."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 3 5)))
         (window (selected-window))
         (visited nil))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'seshat-reader--multipage-rerender-page)
                       (lambda (page &optional _window)
                         (push page visited) t)))
              (should (= 3 (seshat-reader--multipage-refresh-decorations window)))
              (should (equal '(5 3 1) visited))
              ;; 第 2、4 页没有页行 → 从未被访问
              (should-not (memq 2 visited))
              (should-not (memq 4 visited)))))
      (kill-buffer buffer))))

(ert-deftest seshat-reader-periphery-test--refresh-decorations-other-buffer-is-noop ()
  "A window showing another buffer triggers no re-render at all."
  (let ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2)))
        (visited 0))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'seshat-reader--multipage-rerender-page)
                     (lambda (&rest _) (setq visited (1+ visited)) t)))
            (should (= 0 (seshat-reader--multipage-refresh-decorations
                          (selected-window))))
            (should (= 0 visited))))
      (kill-buffer buffer))))

;;;; 11. 拖拽不动选中窗口与 window-start

(ert-deftest seshat-reader-periphery-test--drag-keeps-window-start-and-selection ()
  "A drag leaves the selected window and `window-start' exactly as they were."
  (let* ((buffer (seshat-reader-periphery-test--reader-buffer '(1 2 3)))
         (window (selected-window))
         (selected-before (selected-window))
         (start-before nil)
         (extracted nil)
         (events (list 'move 'release)))
    (unwind-protect
        (seshat-reader-periphery-test--with-window-buffer buffer
          (with-current-buffer buffer
            (seshat-reader-periphery-test--load-select-source)
            (set-window-start window (seshat-reader-periphery-test--row-start 2))
            (setq start-before (window-start window))
            (cl-letf (((symbol-function 'read-event)
                       (lambda (&rest _)
                         (let ((kind (pop events)))
                           (if (eq kind 'move) 'mouse-movement 'drag-mouse-1))))
                      ((symbol-function 'event-start)
                       (lambda (event) (seshat-reader-periphery-test--fake-posn
                                        window
                                        (seshat-reader-periphery-test--row-start 2))))
                      ((symbol-function 'event-end)
                       (lambda (event) (seshat-reader-periphery-test--fake-posn
                                        window
                                        (seshat-reader-periphery-test--row-start 2))))
                      ((symbol-function 'mouse-movement-p)
                       (lambda (event) (eq event 'mouse-movement)))
                      ((symbol-function 'seshat-reader-select-extract)
                       (lambda (start end) (setq extracted t) "ok")))
              (seshat-reader-select-drag '(down-mouse-1)))
            (should extracted)
            ;; 选中窗口没变（没有被 `select-window' 换掉）
            (should (eq selected-before (selected-window)))
            ;; window-start 没动：拖拽不得打断像素滚动位置
            (should (= start-before (window-start window)))))
      (kill-buffer buffer))))

(provide 'seshat-reader-periphery-test)

;;; seshat-reader-periphery-test.el ends here
