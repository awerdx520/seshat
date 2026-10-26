;;; seshat-reader-page-join-test.el --- Tests for cross-page join  -*- lexical-binding: t; -*-

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

;; `seshat-reader' 跨页衔接（M12 T8a/T8b）遗留的少量用例。
;;
;; P1：strip / overlay 相关用例已随批次 2 删除，T7 整体删除本文件。
;;
;; 批次 2（多页布局）之后，`seshat-reader-page-join-lines' 的 strip、页 overlay
;; 的 vscroll 上限、居中 line-prefix 承载结构都不再是显示路径的一部分，断言它们
;; 内部形状的用例随之删除（实现本身由 T7 删除）。这里保留的只有仍然成立的少数
;; 契约：strip 行高换算、strip 默认关闭、窗口尺寸钩子的去抖与去重、以及
;; 「重写全文后 buffer 不得被标为已修改」。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   "emacs" --batch -Q \
;;     -L "emacs" -L "emacs"/seshat-reader \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
;;     -l ert -l "emacs"/tests/seshat-reader-page-join-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建（`seshat-reader'
;; 模块加载需要它）。
;;
;; 纪律：**不触网、不碰真实 PDF、不依赖真实窗口**，窗口访问函数一律用 `cl-letf'
;; 桩替，因此全部用例可在 batch 下稳定运行。
;;
;; 本套件全部用例都不需要外部包，故不使用 `skip-unless' / `ert-skip'——
;; skipped 必须恒为 0。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)

;;; 辅助函数

(defun seshat-reader-page-join-test--reset ()
  "把跨页衔接相关的 buffer-local 状态复位到初始值。"
  (setq seshat-reader--page-image-specs nil
        seshat-reader--join-strip-height 0
        seshat-reader--join-strip-end nil))

;;; 1. strip 像素高度

(ert-deftest seshat-reader-page-join-test--pixels ()
  "`seshat-reader--page-join-pixels' 按行高换算，0 表示关闭。"
  (cl-letf (((symbol-function 'frame-char-height)
             (lambda (&optional _frame) 20)))
    (let ((seshat-reader-page-join-lines 0))
      (should (= 0 (seshat-reader--page-join-pixels))))
    (let ((seshat-reader-page-join-lines 1))
      (should (= 20 (seshat-reader--page-join-pixels))))
    (let ((seshat-reader-page-join-lines 1.5))
      (should (= 30 (seshat-reader--page-join-pixels))))))

(ert-deftest seshat-reader-page-join-test--pixels-non-number ()
  "非法取值（非数字）视作 0，不得报错。"
  (let ((seshat-reader-page-join-lines nil))
    (should (= 0 (seshat-reader--page-join-pixels)))))

;;; 2. 回归修复：默认关闭 strip、窗口尺寸钩子

(ert-deftest seshat-reader-page-join-test--join-lines-default-zero ()
  "`seshat-reader-page-join-lines' 默认 0，默认值下 strip 像素高度为 0。"
  (should (= 0 (default-value 'seshat-reader-page-join-lines)))
  (cl-letf (((symbol-function 'frame-char-height)
             (lambda (&optional _frame) 20)))
    ;; 不绑定同名局部变量，直接走 defcustom 的默认值
    (should (= 0 (seshat-reader--page-join-pixels)))))

(ert-deftest seshat-reader-page-join-test--window-size-change ()
  "钩子按 frame 遍历窗口，对匹配的 buffer 排入一次去抖 refit，不直接居中。

契约变更：去抖取代同步 center（2026-10-22，见计划 D2）。尺寸变化路径不再同步
调 `seshat-reader--center-page'，而是排一个 idle timer，由
`seshat-reader--run-pending-refit' 统一 refit 全部窗口。"
  (with-temp-buffer
    (let* ((win-a 'win-a)
           (win-b 'win-b)
           (refits 0)
           (centers nil))
      (cl-letf (((symbol-function 'window-list)
                 (lambda (&optional _frame) (list win-a win-b)))
                ((symbol-function 'window-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'seshat-reader--schedule-refit)
                 (lambda () (setq refits (1+ refits)) nil))
                ((symbol-function 'seshat-reader--center-page)
                 (lambda (&optional window) (push window centers) 'centered)))
        (seshat-reader--window-size-change (selected-frame))
        ;; 两个窗口都显示当前 buffer，但按 buffer 只排一次 refit
        (should (= 1 refits))
        ;; wrapper 内零调用 `--center-page'：居中移交 refit 阶段
        (should-not centers)))))

(ert-deftest seshat-reader-page-join-test--window-size-change-dedup ()
  "同一 buffer 的多个窗口只排一次 refit，且窗口异常不会让 wrapper 抛错。

「单窗口报错隔离」语义已移交 `seshat-reader--refit-window' 的
`condition-case'。"
  (with-temp-buffer
    (let* ((win-a 'win-a)
           (win-b 'win-b)
           (refits 0))
      (cl-letf (((symbol-function 'window-list)
                 (lambda (&optional _frame) (list win-a win-b)))
                ((symbol-function 'window-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'seshat-reader--schedule-refit)
                 (lambda () (setq refits (1+ refits)) nil))
                ;; 若实现回归为「wrapper 内同步 refit」，此桩会抛错，
                ;; 使下面的 `should-not' 失败。
                ((symbol-function 'seshat-reader--refit-window)
                 (lambda (_window) (error "refit failed"))))
        (should-not (seshat-reader--window-size-change (selected-frame)))
        ;; win-a 与 win-b 命中同一 buffer，去重后只有一次排队
        (should (= 1 refits))))))

;;; 3. buffer 可变性

;; reader buffer 是程序生成的只读 buffer：重写全文是显示行为，不应让 buffer 带上
;; modified 标志（否则 modeline 显示 **，super-save 等自动保存包会尝试把重生成
;; 内容写回原始 PDF）。

(ert-deftest seshat-reader-page-join-test--render-buffer-not-modified ()
  "重写全文之后 buffer 不得被标为已修改。

P1 批次 2 起 `seshat-reader--render-buffer' 会清空 buffer 并重建页行，所以这里
不再断言 buffer 文本（原断言依赖 C 侧桩写入的 \"stub\"），改为断言「页行确实建
起来了」+「buffer 未被标为已修改」。"
  ;; 用真实临时文件承载 `buffer-file-name'（`fset' 桩替该 subr 会触发
  ;; native-comp 的 trampoline 缺失报错），`file-exists-p' 因而自然为真。
  (let ((file (make-temp-file "seshat-render-" nil ".pdf")))
    (unwind-protect
        (with-temp-buffer
          (seshat-reader-page-join-test--reset)
          (setq buffer-file-name file)
          (cl-letf (((symbol-function 'seshat-reader-dyn--load-doc)
                     ;; 桩替原生加载：不改 buffer 文本，布局自己写页行
                     (lambda (_file _page) t)))
            (set-buffer-modified-p nil)
            (seshat-reader--render-buffer 0)
            ;; 防空转：布局确实插入了页行（否则 modified 恒为 nil，用例无判别力）
            (should (> (buffer-size) 0))
            (should seshat-reader--pages)
            (should-not (buffer-modified-p))
            ;; 收尾：buffer 关联了文件，清掉 dirty 以免 kill 时提问
            (set-buffer-modified-p nil)))
      (delete-file file))))

(provide 'seshat-reader-page-join-test)
;;; seshat-reader-page-join-test.el ends here.
