;;; seshat-reader-page-spec-test.el --- Tests for per-page image specs  -*- lexical-binding: t; -*-

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

;; 阅读器 P0「按页渲染返回 image spec」的 ERT 测试套件：`seshat-reader--page-spec'
;; 的参数语义、缓存命中与淘汰、缓存清理挂点、以及「不碰窗口状态」的零副作用守门。
;;
;; 夹具策略依 P0 T0 spike 结论：batch 下可以 `module-load' 仓库内的
;; `seshat-render-core.so' 并打开真实 PDF，因此本套件走**真实 .so + 真实 PDF**
;; （`/usr/share/doc/ghostscript/Ghostscript.pdf'，477 页），而不是桩。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q \
;;     -L emacs -L emacs/seshat-reader \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/etaf \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/etaf-ui \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/ecss \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/ebox \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/visual-fill-column \
;;     -l ert -l emacs/tests/seshat-reader-page-spec-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 两个 batch 独有的坑：
;;  1. batch 下**第二次**往 overlay 写 display 时 C 侧 `image-flush' 会抛
;;     `Window system frame should be used'；本套件连续渲染多页，故夹具内把
;;     `image-flush' 绑成 `ignore'（只影响图像缓存，不影响 PNM 字节），
;;     并在 `unwind-protect' 里恢复原函数。
;;  2. PDF 打开一次贵（477 页 + 首页渲染），故整个会话复用同一个 reader
;;     buffer；文档被关闭（`seshat-reader-current-doc-state-ptr' 为 nil）时才重开。
;;
;; 缺 PDF 或 `.so' 不可用时用例 `skip-unless' 跳过，不会让整个文件报错。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'image)
(require 'seshat-reader)

(defconst seshat-reader-page-spec-test--pdf
  "/usr/share/doc/ghostscript/Ghostscript.pdf"
  "真实 PDF 夹具（P0 T0 spike 指定）；不存在时整套用例跳过。")

(defconst seshat-reader-page-spec-test--module
  (expand-file-name
   (concat "seshat-render-core" module-file-suffix)
   (file-name-directory (or load-file-name buffer-file-name)))
  "仓库内已构建的动态模块路径（与测试文件同级的包目录）。")

(defconst seshat-reader-page-spec-test--min-dpi 18
  "`render/render-core.h' 的 MINRES：低于它的 scale 被夹到该分辨率。")

(defconst seshat-reader-page-spec-test--max-dpi 850
  "`render/render-core.h' 的 MAXRES：高于它的 scale 被夹到该分辨率。")

(defvar seshat-reader-page-spec-test--buffer nil
  "本会话复用的 reader buffer，nil 表示尚未打开。")

(defun seshat-reader-page-spec-test--module-available-p ()
  "确保模块入口可用；返回 nil 表示夹具不可用（用例应跳过）。"
  (or (fboundp 'seshat-reader-dyn--page-image-spec)
      (and (file-exists-p seshat-reader-page-spec-test--module)
           (condition-case nil
               (progn (module-load seshat-reader-page-spec-test--module) t)
             (error nil)))))

(defun seshat-reader-page-spec-test--open-doc ()
  "返回一个已加载夹具 PDF、并显示在窗口里的 reader buffer。

必要时重新打开文档。ERT 在每个用例前后恢复窗口配置，所以上一个用例结束时
窗口会回到 `*scratch*'；这里因此每次都把 buffer 重新显示，页 overlay 由
`window-configuration-change-hook' 重新创建（窗口参数 `page'/`scale' 随窗口保留）。"
  (unless (and (buffer-live-p seshat-reader-page-spec-test--buffer)
               (with-current-buffer seshat-reader-page-spec-test--buffer
                 (bound-and-true-p seshat-reader-current-doc-state-ptr)))
    (when (buffer-live-p seshat-reader-page-spec-test--buffer)
      (kill-buffer seshat-reader-page-spec-test--buffer))
    (setq seshat-reader-page-spec-test--buffer
          (find-file seshat-reader-page-spec-test--pdf)))
  (with-current-buffer seshat-reader-page-spec-test--buffer
    (let ((window (selected-window)))
      (unless (eq (window-buffer window) (current-buffer))
        (set-window-buffer window (current-buffer)))
      (unless (window-parameter window 'overlay)
        (seshat-reader--manage-window-overlays))))
  seshat-reader-page-spec-test--buffer)

(defmacro seshat-reader-page-spec-test--with-doc (&rest body)
  "在活的 reader buffer 里执行 BODY，并隔离 `image-flush' 与规范缓存。

BODY 执行前缓存被清空，因此各用例互不影响；`image-flush' 被绑成 `ignore'
（batch 下连续渲染必需），退出时无条件恢复原函数。"
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (file-exists-p seshat-reader-page-spec-test--pdf))
     (skip-unless (seshat-reader-page-spec-test--module-available-p))
     (let ((original-image-flush (symbol-function 'image-flush)))
       (unwind-protect
           (progn
             (fset 'image-flush #'ignore)
             (with-current-buffer (seshat-reader-page-spec-test--open-doc)
               (seshat-reader--page-spec-clear-cache)
               ,@body))
         (fset 'image-flush original-image-flush)))))

(defmacro seshat-reader-page-spec-test--with-c-counter (counter &rest body)
  "在 BODY 内统计原生入口被调用的次数，结果放在 COUNTER。"
  (declare (indent 1) (debug t))
  `(let ((,counter 0)
         (seshat-reader-page-spec-test--original-c
          (symbol-function 'seshat-reader-dyn--page-image-spec)))
     (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec)
                (lambda (&rest args)
                  (setq ,counter (1+ ,counter))
                  (apply seshat-reader-page-spec-test--original-c args))))
       ,@body)))

(defun seshat-reader-page-spec-test--dims (spec)
  "返回 SPEC 的 (WIDTH HEIGHT)，SPEC 为 nil 时返回 nil。"
  (and spec
       (list (image-property spec :width) (image-property spec :height))))

(defun seshat-reader-page-spec-test--pagecount ()
  "返回当前 buffer 的文档页数（夹具 PDF 为 477）。"
  (or (bound-and-true-p seshat-reader-current-doc-pagecount) 0))

;;; 参数语义

(ert-deftest seshat-reader-page-spec-test--returns-image-spec ()
  "正常页返回 image spec，且宽高为正整数。"
  (seshat-reader-page-spec-test--with-doc
    (let* ((spec (seshat-reader--page-spec 1 1.0))
           (width (image-property spec :width))
           (height (image-property spec :height)))
      (should (consp spec))
      (should (integerp width))
      (should (> width 0))
      (should (integerp height))
      (should (> height 0))
      ;; PNM 字节已复制进 Lisp 字符串，spec 必须能取回 :data。
      (should (stringp (image-property spec :data))))))

(ert-deftest seshat-reader-page-spec-test--invalid-page-numbers-return-nil ()
  "页号 0 / 负数 / 越界一律返回 nil，且不写缓存。"
  (seshat-reader-page-spec-test--with-doc
    (let ((pagecount (seshat-reader-page-spec-test--pagecount)))
      (should (> pagecount 0))
      (dolist (page (list 0 -1 -100 (1+ pagecount) (* pagecount 10)))
        (should-not (seshat-reader--page-spec page 1.0)))
      (should-not seshat-reader--page-spec-cache))))

(ert-deftest seshat-reader-page-spec-test--non-integral-page-returns-nil ()
  "非整数页号（2.7 / 1.5）返回 nil。"
  (seshat-reader-page-spec-test--with-doc
    (should-not (seshat-reader--page-spec 2.7 1.0))
    (should-not (seshat-reader--page-spec 1.5 1.0))
    (should-not seshat-reader--page-spec-cache)))

;;; scale 语义

(ert-deftest seshat-reader-page-spec-test--scale-is-clamped-to-dpi-range ()
  "极端 scale 被夹到 MINRES/MAXRES 对应分辨率，仍返回 spec。"
  (seshat-reader-page-spec-test--with-doc
    (let* ((unit (seshat-reader-page-spec-test--dims
                  (seshat-reader--page-spec 1 1.0)))
           (low (seshat-reader-page-spec-test--dims
                 (seshat-reader--page-spec 1 0.001)))
           (low-ref (seshat-reader-page-spec-test--dims
                     (seshat-reader--page-spec
                      1 (/ (float seshat-reader-page-spec-test--min-dpi) 72))))
           (high (seshat-reader-page-spec-test--dims
                  (seshat-reader--page-spec 1 1000)))
           (high-ref (seshat-reader-page-spec-test--dims
                      (seshat-reader--page-spec
                       1 (/ (float seshat-reader-page-spec-test--max-dpi) 72)))))
      (should low)
      (should high)
      ;; 与「恰好在边界上」的 scale 渲染结果完全一致 = 确实被夹紧。
      (should (equal low low-ref))
      (should (equal high high-ref))
      ;; 且不是按原比例渲染的：0.001 明显小于 1.0，1000 明显大于 1.0。
      (should (< (car low) (car unit)))
      (should (< (cadr low) (cadr unit)))
      (should (> (car high) (car unit)))
      (should (> (cadr high) (cadr unit))))))

(ert-deftest seshat-reader-page-spec-test--invalid-scale-and-rotate-return-nil ()
  "非法 scale（字符串 / 符号）与非法 rotate（45）返回 nil。"
  (seshat-reader-page-spec-test--with-doc
    (should-not (seshat-reader--page-spec 1 "1.0"))
    (should-not (seshat-reader--page-spec 1 'large))
    (should-not (seshat-reader--page-spec 1 1.0 45))
    (should-not (seshat-reader--page-spec 1 1.0 91))
    (should-not seshat-reader--page-spec-cache)))

;;; rotate 语义

(ert-deftest seshat-reader-page-spec-test--quarter-turns-rotate-the-bitmap ()
  "90 / 270 交换宽高，180 与不旋转一致。"
  (seshat-reader-page-spec-test--with-doc
    (let ((r0 (seshat-reader-page-spec-test--dims
               (seshat-reader--page-spec 2 1.0)))
          (r90 (seshat-reader-page-spec-test--dims
                (seshat-reader--page-spec 2 1.0 90)))
          (r180 (seshat-reader-page-spec-test--dims
                 (seshat-reader--page-spec 2 1.0 180)))
          (r270 (seshat-reader-page-spec-test--dims
                 (seshat-reader--page-spec 2 1.0 270))))
      (should (equal r90 (list (cadr r0) (car r0))))
      (should (equal r180 r0))
      (should (equal r270 r90)))))

;;; 缓存

(ert-deftest seshat-reader-page-spec-test--cache-hit-skips-native-call ()
  "同一页同 scale 的第二次请求不再进 C（含 1 vs 1.0 的规范化）。"
  (seshat-reader-page-spec-test--with-doc
    (seshat-reader-page-spec-test--with-c-counter calls
      (let ((first (seshat-reader--page-spec 3 1.0))
            (second (seshat-reader--page-spec 3 1.0 0))
            (third (seshat-reader--page-spec 3 1))
            (fourth (seshat-reader--page-spec 3)))
        (should (= calls 1))
        (should first)
        ;; 命中缓存时返回的是同一个 spec 对象，不是副本。
        (should (eq first second))
        (should (eq first third))
        (should (eq first fourth))))))

(ert-deftest seshat-reader-page-spec-test--cache-drops-the-oldest-entry ()
  "连续请求 10 页后缓存不超过上限，且最早的一页已被淘汰。"
  (seshat-reader-page-spec-test--with-doc
    ;; 用最小 scale（18 dpi）渲染，尽量把 10 次渲染的成本压到最低。
    (let ((scale (/ (float seshat-reader-page-spec-test--min-dpi) 72)))
      (dotimes (i 10)
        (should (seshat-reader--page-spec (+ 10 i) scale)))
      (should (= (length seshat-reader--page-spec-cache) 8))
      ;; 最早的 10、11 页已被淘汰：再次请求会重新进 C。
      (seshat-reader-page-spec-test--with-c-counter calls
        (should (seshat-reader--page-spec 10 scale))
        (should (seshat-reader--page-spec 11 scale))
        (should (= calls 2)))
      ;; 最新的 19 页仍在缓存里：不再进 C。
      (seshat-reader-page-spec-test--with-c-counter calls
        (should (seshat-reader--page-spec 19 scale))
        (should (= calls 0))))))

(ert-deftest seshat-reader-page-spec-test--clear-cache-forces-native-call ()
  "`--page-spec-clear-cache' 之后缓存为空，再次请求会进 C。"
  (seshat-reader-page-spec-test--with-doc
    (should (seshat-reader--page-spec 6 1.0))
    (should (= (length seshat-reader--page-spec-cache) 1))
    (seshat-reader--page-spec-clear-cache)
    (should-not seshat-reader--page-spec-cache)
    (seshat-reader-page-spec-test--with-c-counter calls
      (should (seshat-reader--page-spec 6 1.0))
      (should (= calls 1)))))

;;; 零副作用守门

(ert-deftest seshat-reader-page-spec-test--does-not-touch-window-state ()
  "调用前后窗口参数与页面 overlay 的 display 对象保持不变。"
  (seshat-reader-page-spec-test--with-doc
    (let* ((window (get-buffer-window (current-buffer) t))
           (overlay (and window (window-parameter window 'overlay))))
      (should (windowp window))
      (should (overlayp overlay))
      (let ((page-before (window-parameter window 'page))
            (scale-before (window-parameter window 'scale))
            (native-before (window-parameter window 'native-size))
            (display-before (overlay-get overlay 'display)))
        (should (seshat-reader--page-spec 5 (/ (float
                                                seshat-reader-page-spec-test--min-dpi)
                                               72)
                                          90))
        (should (equal (window-parameter window 'page) page-before))
        (should (equal (window-parameter window 'scale) scale-before))
        (should (equal (window-parameter window 'native-size) native-before))
        ;; display 必须是同一个对象（不是等值的新 spec）。
        (should (eq (overlay-get overlay 'display) display-before))))))

;;; 兼容与清理挂点

(ert-deftest seshat-reader-page-spec-test--missing-native-entry-returns-nil ()
  "旧 .so（没有该入口）下包装返回 nil 且不报错、不写缓存。"
  (seshat-reader-page-spec-test--with-doc
    (cl-letf (((symbol-function 'seshat-reader-dyn--page-image-spec) nil))
      (should-not (fboundp 'seshat-reader-dyn--page-image-spec))
      (should-not (seshat-reader--page-spec 1 1.0))
      (should-not (seshat-reader--page-spec 1 1.0 90))
      (should-not seshat-reader--page-spec-cache))))

(ert-deftest seshat-reader-page-spec-test--clear-doc-memory-drops-cache ()
  "`--clear-doc-memory' 会清空按页缓存（关文档即失效）。"
  (seshat-reader-page-spec-test--with-doc
    (should (seshat-reader--page-spec 7 1.0))
    (should seshat-reader--page-spec-cache)
    ;; 不真的关闭文档：只把 close-doc 桩掉，保留 C 侧 DocState 供后续用例。
    (cl-letf (((symbol-function 'seshat-reader-dyn--close-doc) #'ignore))
      (seshat-reader--clear-doc-memory))
    (should-not seshat-reader--page-spec-cache)))

(ert-deftest seshat-reader-page-spec-test--render-buffer-drops-cache ()
  "`--render-buffer' 收尾会清空按页缓存（重载后位图重画）。"
  (seshat-reader-page-spec-test--with-doc
    (should (seshat-reader--page-spec 8 1.0))
    (should seshat-reader--page-spec-cache)
    ;; 桩掉真正的文档重载与 join strip 更新，只验证收尾的清理动作。
    (cl-letf (((symbol-function 'seshat-reader-dyn--load-doc) #'ignore)
              ((symbol-function 'seshat-reader--update-join-strip) #'ignore))
      (seshat-reader--render-buffer 0))
    (should-not seshat-reader--page-spec-cache)))

(provide 'seshat-reader-page-spec-test)
;;; seshat-reader-page-spec-test.el ends here
