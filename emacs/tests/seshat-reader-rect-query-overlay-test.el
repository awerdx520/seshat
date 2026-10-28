;;; seshat-reader-rect-query-overlay-test.el --- Rect queries without overlays  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
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

;; P2-A 真机缺陷（`overlayp nil' 崩溃）的回归套件：C 侧的三个矩形查询入口
;; （`--text-in-rect' / `--rects-in-rect' / `--lines-in-rect'）**只**按
;; buffer-local 的 `seshat-reader-current-doc-state-ptr' 解析文档，不得依赖
;; 被选窗口的 `overlay' 窗口参数。P1 的多页布局里拖选刻意不 `select-window'，
;; 窗口上也没有 overlay；旧实现经 `get_reader_current_state' 要求「selected
;; window 的 overlay 有效」，于是真机拖选时 `check_current_overlay' 先拿指针
;; 比较 `nil'（`overlay == EMACS_NIL'，对 `emacs_value' 句柄无效）漏判，再
;; 把 `nil' 喂给 `overlay-buffer'，抛
;; `(wrong-type-argument overlayp nil)'。
;;
;; 本套件与其它 select 相关套件的**关键差别**：那些套件用 `cl-letf' 桩掉
;; `seshat-reader-dyn--*'，因此完全覆盖不到 C 侧的状态解析；这里照
;; `seshat-reader-page-spec-test.el' 的夹具走**真实 `.so' + 真实 PDF**，
;; 让真实模块在真实文档上跑一遍，并在调用前把窗口的 `overlay' 参数清成 nil
;; （或换成一个不属于本文档 buffer 的外来 overlay，即真机崩溃的精确前置条件）。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q \
;;     -L emacs -L emacs/seshat-reader \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/etaf \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/etaf-ui \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/ecss \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/ebox \
;;     -l ert -l emacs/tests/seshat-reader-rect-query-overlay-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 缺 PDF 或 `.so' 不可用时用例 `skip-unless' 跳过，不会让整个文件报错。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'image)
(require 'seshat-reader)
;; 上层入口 `seshat-reader-select--page-selection' 住在 select.el，不由
;; `seshat-reader' 自带；真机崩在 `seshat-reader-select-extract'，故这里显式加载。
(require 'seshat-reader-select)

(defconst seshat-reader-rect-query-overlay-test--pdf
  "/usr/share/doc/ghostscript/Ghostscript.pdf"
  "真实 PDF 夹具；不存在时整套用例跳过。")

(defconst seshat-reader-rect-query-overlay-test--module
  (expand-file-name
   (concat "seshat-render-core" module-file-suffix)
   (file-name-directory (or load-file-name buffer-file-name)))
  "仓库内已构建的动态模块路径（与测试文件同级的包目录）。")

(defconst seshat-reader-rect-query-overlay-test--rect '(0.0 0.0 700.0 1000.0)
  "覆盖整页的矩形，单位为 MuPDF 页空间（point，y 向下）。

取「整页」而不是某个词的位置，是为了让断言只依赖「页上有字」这一事实，
不绑定夹具 PDF 的排版细节。A4 / Letter 都在 700×1000 point 之内。")

(defvar seshat-reader-rect-query-overlay-test--buffer nil
  "本会话复用的 reader buffer，nil 表示尚未打开。")

(defun seshat-reader-rect-query-overlay-test--module-available-p ()
  "确保模块入口可用；返回 nil 表示夹具不可用（用例应跳过）。"
  (or (fboundp 'seshat-reader-dyn--text-in-rect)
      (and (file-exists-p seshat-reader-rect-query-overlay-test--module)
           (condition-case nil
               (progn (module-load seshat-reader-rect-query-overlay-test--module) t)
             (error nil)))))

(defun seshat-reader-rect-query-overlay-test--open-doc ()
  "返回一个已加载夹具 PDF、并按多页布局显示出页行的 reader buffer。

与 `seshat-reader-page-spec-test--open-doc' 同构：`find-file' 经
`seshat-reader-mode' 调 `seshat-reader--render-buffer' 建立页行；ERT 在每个
用例前后恢复窗口配置，所以每次都把 buffer 重新显示到当前窗口上。"
  (unless (and (buffer-live-p seshat-reader-rect-query-overlay-test--buffer)
               (with-current-buffer seshat-reader-rect-query-overlay-test--buffer
                 (and (bound-and-true-p seshat-reader-current-doc-state-ptr)
                      seshat-reader--pages)))
    (when (buffer-live-p seshat-reader-rect-query-overlay-test--buffer)
      (kill-buffer seshat-reader-rect-query-overlay-test--buffer))
    (setq seshat-reader-rect-query-overlay-test--buffer
          (find-file seshat-reader-rect-query-overlay-test--pdf)))
  (with-current-buffer seshat-reader-rect-query-overlay-test--buffer
    (let ((window (selected-window)))
      (unless (eq (window-buffer window) (current-buffer))
        (set-window-buffer window (current-buffer)))
      (unless seshat-reader--pages
        (seshat-reader--render-buffer
         (1- (or (seshat-reader-current-doc-pagenumber) 1)))))
    seshat-reader-rect-query-overlay-test--buffer))

(defmacro seshat-reader-rect-query-overlay-test--with-doc (&rest body)
  "在活的 reader buffer 里执行 BODY。

canvas 后端的 spec 没有 flush 语义，夹具不再需要隔离 `image-flush'。"
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (file-exists-p seshat-reader-rect-query-overlay-test--pdf))
     (skip-unless (seshat-reader-rect-query-overlay-test--module-available-p))
     (with-current-buffer (seshat-reader-rect-query-overlay-test--open-doc)
       ,@body)))

(defun seshat-reader-rect-query-overlay-test--foreign-overlay ()
  "在当前 buffer 之外造一个 overlay，并返回它。

真机崩溃链的第一环就是「窗口的 overlay 属于别的 buffer」：
`check_current_overlay' 返回 false → `get_current_doc_overlay' 清掉窗口参数
并返回 nil → 旧代码把那个 nil 继续喂给 `overlay-buffer'。"
  (let ((temp (generate-new-buffer " *seshat-foreign-overlay*")))
    (unwind-protect
        (with-current-buffer temp
          (insert "foreign")
          (make-overlay (point-min) (point-max)))
      (kill-buffer temp))))

(defun seshat-reader-rect-query-overlay-test--text ()
  "用夹具矩形调 `--text-in-rect'，页号 0（0-based）。"
  (apply #'seshat-reader-dyn--text-in-rect
         0 seshat-reader-rect-query-overlay-test--rect))

(defun seshat-reader-rect-query-overlay-test--rects ()
  "用夹具矩形调 `--rects-in-rect'，页号 0（0-based）。"
  (apply #'seshat-reader-dyn--rects-in-rect
         0 seshat-reader-rect-query-overlay-test--rect))

(defun seshat-reader-rect-query-overlay-test--lines ()
  "用夹具矩形调 `--lines-in-rect'，页号 0（0-based）；不可用时返回 nil。"
  (when (fboundp 'seshat-reader-dyn--lines-in-rect)
    (apply #'seshat-reader-dyn--lines-in-rect
           0 seshat-reader-rect-query-overlay-test--rect)))

(defun seshat-reader-rect-query-overlay-test--call (fn)
  "在 `unwind-protect' 里调用 FN，返回 (RESULT . CONDITION)。

CONDITION 为 nil 表示没有信号；否则是 `signal' 收到的错误数据。结果与错误
一起返回，是为了让用例能同时断言「不报错」和「有返回值」，而不是让错误直接
冒泡到 ERT 的 backtrace 里掩盖真正的断言。"
  (let (result condition)
    (condition-case err
        (setq result (funcall fn))
      (error (setq condition err)))
    (cons result condition)))

;;; 无 overlay 时仍能取文

(ert-deftest seshat-reader-rect-query-overlay-test--text-without-overlay ()
  "窗口 overlay 参数为 nil 时 `--text-in-rect' 仍返回非空字符串。

这是真机崩溃的直接回归：修复前该调用在 `overlay-buffer(nil)' 上抛
`wrong-type-argument overlayp nil'。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (set-window-parameter (selected-window) 'overlay nil)
    (let* ((outcome (seshat-reader-rect-query-overlay-test--call
                     #'seshat-reader-rect-query-overlay-test--text))
           (text (car outcome)))
      (should-not (cdr outcome))
      (should (stringp text))
      (should (> (length text) 0)))))

(ert-deftest seshat-reader-rect-query-overlay-test--rects-without-overlay ()
  "窗口 overlay 参数为 nil 时 `--rects-in-rect' 返回非空四元组列表。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (set-window-parameter (selected-window) 'overlay nil)
    (let* ((outcome (seshat-reader-rect-query-overlay-test--call
                     #'seshat-reader-rect-query-overlay-test--rects))
           (rects (car outcome)))
      (should-not (cdr outcome))
      (should (consp rects))
      (should (cl-every (lambda (r) (and (consp r) (= 4 (length r))
                                         (cl-every #'numberp r)))
                        rects)))))

(ert-deftest seshat-reader-rect-query-overlay-test--lines-without-overlay ()
  "窗口 overlay 参数为 nil 时 `--lines-in-rect' 返回非空四元组列表。

老模块不导出该入口时整条用例跳过，其余用例仍然有效。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (skip-unless (fboundp 'seshat-reader-dyn--lines-in-rect))
    (set-window-parameter (selected-window) 'overlay nil)
    (let* ((outcome (seshat-reader-rect-query-overlay-test--call
                     #'seshat-reader-rect-query-overlay-test--lines))
           (lines (car outcome)))
      (should-not (cdr outcome))
      (should (consp lines))
      (should (cl-every (lambda (r) (and (consp r) (= 4 (length r))))
                        lines)))))

;;; 外来 overlay：真机崩溃链的精确前置条件

(ert-deftest seshat-reader-rect-query-overlay-test--foreign-overlay-no-signal ()
  "窗口 overlay 属于别的 buffer 时不抛 `overlayp' 错误，且仍返回文本。

旧代码在这里走完「清掉窗口参数 → 返回 nil → `check_current_overlay(nil)'」，
指针比较漏判 nil 后调 `overlay-buffer(nil)' 崩溃；这三步是新旧实现唯一
走同一入口的路径，因此单独立一条用例。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (let ((window (selected-window)))
      (unwind-protect
          (progn
            (set-window-parameter
             window 'overlay
             (seshat-reader-rect-query-overlay-test--foreign-overlay))
            (let* ((outcome (seshat-reader-rect-query-overlay-test--call
                             #'seshat-reader-rect-query-overlay-test--text))
                   (text (car outcome)))
              (should-not (cdr outcome))
              (should (stringp text))
              (should (> (length text) 0))))
        (set-window-parameter window 'overlay nil)))))

;;; overlay 状态不影响结果

(ert-deftest seshat-reader-rect-query-overlay-test--overlay-state-is-irrelevant ()
  "同一矩形在有 / 无 overlay 时返回 `equal' 的结果。

「有 overlay」用文档 buffer 里的普通 overlay 填窗口参数——它没有 `win-state'
属性，旧实现即使指针比较正确也会在 `get_win_state_ptr' 处失败，故这条用例
同时确认新实现**完全不看**窗口 overlay。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (let* ((window (selected-window))
           (own-overlay (make-overlay (point-min) (point-max) nil t t)))
      (unwind-protect
          (progn
            (set-window-parameter window 'overlay nil)
            (let ((text-nil (seshat-reader-rect-query-overlay-test--text))
                  (rects-nil (seshat-reader-rect-query-overlay-test--rects))
                  (lines-nil (seshat-reader-rect-query-overlay-test--lines)))
              (set-window-parameter window 'overlay own-overlay)
              (should (equal text-nil (seshat-reader-rect-query-overlay-test--text)))
              (should (equal rects-nil (seshat-reader-rect-query-overlay-test--rects)))
              (when (fboundp 'seshat-reader-dyn--lines-in-rect)
                (should (equal lines-nil
                               (seshat-reader-rect-query-overlay-test--lines))))))
        (delete-overlay own-overlay)
        (set-window-parameter window 'overlay nil)))))

;;; 与 buffer 归属无关的守卫仍在

(ert-deftest seshat-reader-rect-query-overlay-test--no-doc-state-returns-nil ()
  "没有 buffer-local 文档指针时三个入口静默返回 nil，不报错。

`prepare_rect_query' 的「无文档状态」早退必须保持静默（调用方可能正在
redisplay 中）。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (with-temp-buffer
      ;; 显式把 buffer-local 文档指针压成 nil（变量是 automatic buffer-local，
      ;; `setq-local' 不会惊动文档 buffer 里的值）。
      (setq-local seshat-reader-current-doc-state-ptr nil)
      (dolist (fn '(seshat-reader-rect-query-overlay-test--text
                    seshat-reader-rect-query-overlay-test--rects
                    seshat-reader-rect-query-overlay-test--lines))
        (let ((outcome (seshat-reader-rect-query-overlay-test--call fn)))
          (should-not (cdr outcome))
          (should-not (car outcome)))))))

;;; 选中流程的中间层（真机 backtrace 的直接调用者）

(ert-deftest seshat-reader-rect-query-overlay-test--page-selection-without-overlay ()
  "无 overlay 时 `seshat-reader-select--page-selection' 返回非空文本与几何。

这条用例走上层入口（`seshat-reader-select-extract' 在真机 backtrace 里调用的
正是它），因此顺带覆盖「1-based 页号 → 模块 0-based」的换算与
`seshat-reader-select--rects-in-rect' 的整行吸附回落。"
  (seshat-reader-rect-query-overlay-test--with-doc
    (set-window-parameter (selected-window) 'overlay nil)
    (let* ((outcome
            (seshat-reader-rect-query-overlay-test--call
             (lambda ()
               (seshat-reader-select--page-selection
                '((1 0.0 0.0 700.0 1000.0))))))
           (pages (car outcome))
           (first (car pages)))
      (should-not (cdr outcome))
      (should (consp pages))
      (should (= 1 (length pages)))
      ;; (PAGE TEXT RECTS)
      (should (equal 1 (nth 0 first)))
      (should (stringp (nth 1 first)))
      (should (> (length (nth 1 first)) 0))
      (should (consp (nth 2 first))))))

(provide 'seshat-reader-rect-query-overlay-test)
;;; seshat-reader-rect-query-overlay-test.el ends here
