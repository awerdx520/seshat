;;; seshat-reader-multipage-test.el --- Tests for the multi-page layout skeleton  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
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

;; 阅读器 P1 T1「多页布局骨架」的 ERT 测试套件：页行插入/移除、`display'
;; 文本属性承载 image spec、`seshat-reader-page-gap-lines' 的间隙行数、
;; 以及可见集区间（视口 ± preload）的计算。
;;
;; T1 **只测新增结构，不涉及显示路径**：夹具用 `with-temp-buffer' 直接调新
;; 函数，不进入 `seshat-reader-mode'、不渲染真实 PDF、不需要 native 模块；
;; fake spec 只用 `(list 'image :width N :height 10)'。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader -l ert \
;;     -l emacs/tests/seshat-reader-multipage-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 可见集用例依赖窗口：batch 下 `set-window-start' 可用（`should' 断言它确实
;; 生效，未生效即用例失败而不是静默退化）。

;;; Code:

(require 'ert)
(require 'seshat-reader)

;;;; 夹具与辅助函数

(defun seshat-reader-multipage-test--fake-spec (&optional width)
  "Return a fake image spec WIDTH pixels wide."
  (list 'image :width (or width 10) :height 10))

(defun seshat-reader-multipage-test--insert-pages (pages)
  "Insert PAGES, a list of page numbers, each with a fake spec."
  (dolist (page pages)
    (seshat-reader--multipage-insert-page
     page (seshat-reader-multipage-test--fake-spec page))))

(defun seshat-reader-multipage-test--display-count ()
  "Return how many buffer positions carry a `display' property."
  (let ((count 0)
        (pos (point-min)))
    (while (< pos (point-max))
      (if (get-text-property pos 'display)
          (progn
            (setq count (1+ count))
            (setq pos (next-single-property-change pos 'display nil (point-max))))
        (setq pos (1+ pos))))
    count))

(defun seshat-reader-multipage-test--page-numbers ()
  "Return the page numbers of the layout in buffer order."
  (mapcar #'car seshat-reader--pages))

(defun seshat-reader-multipage-test--marker-positions ()
  "Return the row marker positions of the layout in buffer order."
  (mapcar (lambda (entry) (marker-position (cadr entry))) seshat-reader--pages))

;;;; 用例

(ert-deftest seshat-reader-multipage-test--inserts-five-pages-in-order ()
  "Five pages give five displayed rows, ordered by page number."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
    (should (= (seshat-reader-multipage-test--display-count) 5))
    (should (equal (seshat-reader-multipage-test--page-numbers) '(1 2 3 4 5)))
    (let ((positions (seshat-reader-multipage-test--marker-positions)))
      (should (= (length positions) 5))
      (should (apply #'< positions)))))

(ert-deftest seshat-reader-multipage-test--inserts-sixth-page-at-the-end ()
  "A sixth page appends one more displayed row after the fifth."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
    (seshat-reader-multipage-test--insert-pages '(6))
    (should (= (seshat-reader-multipage-test--display-count) 6))
    (should (equal (seshat-reader-multipage-test--page-numbers)
                   '(1 2 3 4 5 6)))
    (let ((positions (seshat-reader-multipage-test--marker-positions)))
      (should (apply #'< positions)))))

(ert-deftest seshat-reader-multipage-test--removes-first-page ()
  "Removing page 1 hands its spec back and keeps the other rows intact."
  (with-temp-buffer
    (let ((spec-one (seshat-reader-multipage-test--fake-spec 101))
          (spec-two (seshat-reader-multipage-test--fake-spec 102)))
      (seshat-reader--multipage-insert-page 1 spec-one)
      (seshat-reader--multipage-insert-page 2 spec-two)
      (seshat-reader-multipage-test--insert-pages '(3 4 5 6))
      (should (= (seshat-reader-multipage-test--display-count) 6))
      (let ((removed (seshat-reader--multipage-remove-page 1)))
        ;; 返回的 spec 必须是插入时的那一个对象（调用方据此回收位图）。
        (should (eq removed spec-one))
        (should (= (seshat-reader-multipage-test--display-count) 5))
        (should (equal (seshat-reader-multipage-test--page-numbers)
                       '(2 3 4 5 6)))
        (should (null (seshat-reader--multipage-page-spec 1)))
        (should (eq (seshat-reader--multipage-page-spec 2) spec-two))
        ;; 剩余页的 marker 仍指向各自页行：行首的 display 属性即该页 spec，
        ;; 且 `--multipage-page-at-pos' 在行首返回该页号。
        (dolist (entry seshat-reader--pages)
          (let* ((page (car entry))
                 (pos (marker-position (cadr entry))))
            (should (eq (get-text-property pos 'display)
                        (seshat-reader--multipage-page-spec page)))
            (should (= (seshat-reader--multipage-page-at-pos pos) page))))
        ;; 移除最后剩下的页后布局回到空状态。
        (dolist (page '(2 3 4 5 6))
          (seshat-reader--multipage-remove-page page))
        (should (null seshat-reader--pages))
        (should (= (seshat-reader-multipage-test--display-count) 0))))))

(ert-deftest seshat-reader-multipage-test--gap-lines-add-blank-lines ()
  "`seshat-reader-page-gap-lines' adds exactly that many lines per page."
  (let ((zero-lines (with-temp-buffer
                      (let ((seshat-reader-page-gap-lines 0))
                        (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
                        (count-lines (point-min) (point-max)))))
        (two-lines (with-temp-buffer
                     (let ((seshat-reader-page-gap-lines 2))
                       (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
                       (count-lines (point-min) (point-max))))))
    ;; 5 页各占 1 行，gap 每页再追加 2 行 → 差 = 2 × 5 = 10。
    (should (= (- two-lines zero-lines) 10))))

(ert-deftest seshat-reader-multipage-test--out-of-order-inserts-stay-sorted ()
  "Inserting pages 3, 1 and 2 keeps them sorted and each row addressable."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(3 1 2))
    (should (equal (seshat-reader-multipage-test--page-numbers) '(1 2 3)))
    (should (= (seshat-reader-multipage-test--display-count) 3))
    (let ((positions (seshat-reader-multipage-test--marker-positions)))
      (should (apply #'< positions))
      ;; 每个行首都必须反查回自己的页号。
      (dolist (entry seshat-reader--pages)
        (should (= (seshat-reader--multipage-page-at-pos
                    (marker-position (cadr entry)))
                   (car entry)))))))

(ert-deftest seshat-reader-multipage-test--insert-page-replaces-spec ()
  "Inserting an existing page only replaces its spec, it adds no row."
  (with-temp-buffer
    (let ((first (seshat-reader-multipage-test--fake-spec 111))
          (second (seshat-reader-multipage-test--fake-spec 222)))
      (should (markerp (seshat-reader--multipage-insert-page 1 first)))
      (should (null (seshat-reader--multipage-insert-page 1 second)))
      (should (= (seshat-reader-multipage-test--display-count) 1))
      (should (eq (seshat-reader--multipage-page-spec 1) second))
      (should (eq (get-text-property (point-min) 'display) second)))))

(ert-deftest seshat-reader-multipage-test--page-at-pos-keeps-gaps-on-previous ()
  "The gap line after a page belongs to that page, not to the next one."
  (with-temp-buffer
    (let ((seshat-reader-page-gap-lines 2))
      (seshat-reader-multipage-test--insert-pages '(1 2))
      (let* ((first (marker-position (cadr (assq 1 seshat-reader--pages))))
             (second (marker-position (cadr (assq 2 seshat-reader--pages)))))
        (should (= (seshat-reader--multipage-page-at-pos (point-min)) 1))
        (should (= (seshat-reader--multipage-page-at-pos first) 1))
        ;; 第 1 页行尾与它后面两条 gap 空行都归第 1 页。
        (should (= (seshat-reader--multipage-page-at-pos (1- second)) 1))
        (should (= (seshat-reader--multipage-page-at-pos second) 2))
        (should (= (seshat-reader--multipage-page-at-pos (point-max)) 2))
        ;; 空布局与越界都返回 nil。
        (should (null (seshat-reader--multipage-page-at-pos (1+ (point-max))))))))
  (with-temp-buffer
    (should (null (seshat-reader--multipage-page-at-pos (point-min))))))

(ert-deftest seshat-reader-multipage-test--visible-range-widens-around-viewport ()
  "A viewport on page 3 of five asks for pages 1 through 5."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3 4 5))
    (let ((window (selected-window))
          (original (window-buffer))
          (third (cadr (assq 3 seshat-reader--pages))))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (set-window-start window (marker-position third))
            (should (= (window-start window) (marker-position third)))
            (let ((seshat-reader--multipage-preload 2))
              (should (equal (seshat-reader--multipage-visible-range window)
                             '(1 . 5)))))
        (set-window-buffer window original)))))

(ert-deftest seshat-reader-multipage-test--visible-range-clips-to-existing-pages ()
  "A large preload is clipped to the first and the last existing page."
  (with-temp-buffer
    (seshat-reader-multipage-test--insert-pages '(1 2 3))
    (let ((window (selected-window))
          (original (window-buffer))
          (second (cadr (assq 2 seshat-reader--pages))))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (set-window-start window (marker-position second))
            (should (= (window-start window) (marker-position second)))
            (let ((seshat-reader--multipage-preload 10))
              (should (equal (seshat-reader--multipage-visible-range window)
                             '(1 . 3)))))
        (set-window-buffer window original)))))

(provide 'seshat-reader-multipage-test)

;;; seshat-reader-multipage-test.el ends here
