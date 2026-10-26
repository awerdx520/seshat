;;; seshat-reader-theme-test.el --- Tests for the dark-mode tint presets  -*- lexical-binding: t; -*-

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

;; 阅读器暗色模式「5 档配色预设」的 ERT 测试套件（计划
;; `openspec/active/2026-10-27-reader-dark-tint-presets.md' 的 T4）。
;;
;; 覆盖两类契约：
;;
;; 1. 下发契约（`seshat-reader-dark-mode' 的 body）：开暗色时按当前
;;    `seshat-reader-dark-tint' 把 (BG . FG) 交给原生模块的
;;    `seshat-reader-dyn--doc-tint'，`graphite' 交哨兵 `(-1 -1)'（等价
;;    改动前的满量程反色）；关暗色时**不**下发 tint；无论开还是关，一次
;;    toggle 只重绘一次。
;; 2. 解析契约（`seshat-reader--dark-tint-colors'，纯函数）：预设符号查
;;    表、`graphite' 返回 nil（旧路径）、自定义 cons 原样返回、非法取值
;;    返回 nil 且 `message' 恰好一次（不静默换成另一档）。
;;
;; 全部用例只桩替动态模块函数（`--doc-invert' / `--doc-tint'）与
;; `seshat-reader--redisplay-all-windows'：**不真渲染**、**不加载 PDF**、
;; **不接触运行中的 Emacs**，因此可在 `emacs --batch -Q' 下直接跑。
;;
;; 覆盖边界（必读）：本文件只断言**下发的 (BG FG) 参数**与解析契约，不覆盖
;; 像素极性——即「参数到了原生模块之后，页面到底是暗底亮字还是亮底暗字」
;; 这里一律测不到（`--doc-tint' 是桩，一旦真的渲染就无法在 batch 下断言）。
;; 像素方向性由两处负责：① batch 像素统计（同一页在每档预设下 PNM 的
;; min/median/mode/max 与「接近 BG ±2 的像素占比 > 70%」）；② L3 目测
;; （真开一幅 PDF 看观感）。改动 `render/render-core.c' 的 `fz_tint_pixmap'
;; 实参顺序时，本套件全绿并不代表方向正确，必须同时跑那两道。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader -l ert \
;;     -l emacs/tests/seshat-reader-theme-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)

(defun seshat-reader-theme-test--charcoal ()
  "`charcoal' 预设应在下发时使用的 (BG . FG)。"
  (cons #x26262b #xa8a49a))

(defmacro seshat-reader-theme-test--with-dark-toggle (&rest body)
  "在桩替过动态模块函数的 `seshat-reader-mode' buffer 内执行 BODY.

BODY 里三个记录变量可用：`tint-args'（每次下发按时间倒序压入的
(BG FG) 列表）、`invert-args'（每次 `--doc-invert' 的实参）、
`redisplay-calls'（`seshat-reader--redisplay-all-windows' 的调用次数）。

`seshat-reader-dark-mode' 用 `let' 动态绑定，退出时自动恢复全局值，
避免用例之间互相污染。"
  (declare (indent 0) (debug t))
  `(let ((tint-args nil)
         (invert-args nil)
         (redisplay-calls 0)
         (seshat-reader-dark-mode nil))
     (with-temp-buffer
       (setq major-mode 'seshat-reader-mode)
       (cl-letf (((symbol-function 'seshat-reader-dyn--doc-invert)
                  (lambda (flag) (push flag invert-args)))
                 ((symbol-function 'seshat-reader-dyn--doc-tint)
                  (lambda (bg fg)
                    (push (list bg fg) tint-args)
                    t))
                 ((symbol-function 'seshat-reader--redisplay-all-windows)
                  (lambda () (cl-incf redisplay-calls))))
         ,@body))))

;;;; 下发契约

(ert-deftest seshat-reader-theme-test-default-preset-is-charcoal ()
  "默认预设是 `charcoal'，且开暗色时下发它的两个端点色."
  (should (eq seshat-reader-dark-tint 'charcoal))
  (seshat-reader-theme-test--with-dark-toggle
    (let ((seshat-reader-dark-tint 'charcoal))
      (seshat-reader-dark-mode 1)
      (should (equal tint-args
                     (list (list (car (seshat-reader-theme-test--charcoal))
                                 (cdr (seshat-reader-theme-test--charcoal))))))
      (should (equal invert-args '(1)))
      (should (= redisplay-calls 1)))))

(ert-deftest seshat-reader-theme-test-charcoal-literals ()
  "`charcoal' 的下发值是 `#x26262b' / `#xa8a49a'（十六进制字面量钉死）."
  (seshat-reader-theme-test--with-dark-toggle
    (let ((seshat-reader-dark-tint 'charcoal))
      (seshat-reader-dark-mode 1)
      (should (equal tint-args '((#x26262b #xa8a49a)))))))

(ert-deftest seshat-reader-theme-test-each-preset-sends-its-colours ()
  "五个预设各自下发正确的 (BG FG)：`graphite' 是哨兵，其余是双端压缩."
  (seshat-reader-theme-test--with-dark-toggle
    (dolist (case '((graphite    -1       -1)
                    (midnight    #x1c1c22 #xc8c4ba)
                    (charcoal    #x26262b #xa8a49a)
                    (night-sepia #x201d18 #xc0b49c)
                    (sepia       #xe8dfc8 #x3a342a)))
      (setq tint-args nil)
      (let ((seshat-reader-dark-tint (car case)))
        (setq seshat-reader-dark-mode nil)
        (seshat-reader-dark-mode 1)
        (should (equal tint-args
                       (list (list (nth 1 case) (nth 2 case)))))))))

(ert-deftest seshat-reader-theme-test-graphite-sends-the-sentinel ()
  "`graphite' 下发 `(-1 -1)'：原生模块据此走旧的 invert+gamma 路径."
  (seshat-reader-theme-test--with-dark-toggle
    (let ((seshat-reader-dark-tint 'graphite))
      (seshat-reader-dark-mode 1)
      (should (equal tint-args '((-1 -1))))
      ;; 暗色标志本身照旧打开，回退只发生在像素变换那条分支上。
      (should (equal invert-args '(1))))))

(ert-deftest seshat-reader-theme-test-custom-cons-is-sent-as-is ()
  "自定义 cons 预设（两个 `#xRRGGBB' 整数）原样下发."
  (seshat-reader-theme-test--with-dark-toggle
    (let ((seshat-reader-dark-tint (cons #x101010 #xeeeeee)))
      (seshat-reader-dark-mode 1)
      (should (equal tint-args '((#x101010 #xeeeeee)))))))

(ert-deftest seshat-reader-theme-test-turning-off-does-not-send-tint ()
  "关暗色时不下发 tint（配色当作用户偏好保留），但仍然重绘一次."
  (seshat-reader-theme-test--with-dark-toggle
    (let ((seshat-reader-dark-tint 'charcoal))
      (seshat-reader-dark-mode 1)
      (setq tint-args nil)
      (setq redisplay-calls 0)
      (seshat-reader-dark-mode -1)
      (should-not tint-args)
      (should (equal invert-args '(0 1)))
      (should (= redisplay-calls 1)))))

(ert-deftest seshat-reader-theme-test-unknown-preset-falls-back-to-legacy-path ()
  "非法预设符号不下发 tint（回退旧路径），并 `message' 一次."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (seshat-reader-theme-test--with-dark-toggle
        (let ((seshat-reader-dark-tint 'no-such-preset))
          (seshat-reader-dark-mode 1)
          (should (equal tint-args '((-1 -1)))))))
    (should (= 1 (length messages)))))

;;;; 解析契约（纯函数）

(ert-deftest seshat-reader-theme-test-resolve-preset-symbol ()
  "预设符号查表返回 (BG . FG)。"
  (should (equal (seshat-reader--dark-tint-colors 'charcoal)
                 (cons #x26262b #xa8a49a)))
  (should (equal (seshat-reader--dark-tint-colors 'midnight)
                 (cons #x1c1c22 #xc8c4ba)))
  (should (equal (seshat-reader--dark-tint-colors 'night-sepia)
                 (cons #x201d18 #xc0b49c)))
  (should (equal (seshat-reader--dark-tint-colors 'sepia)
                 (cons #xe8dfc8 #x3a342a))))

(ert-deftest seshat-reader-theme-test-resolve-graphite-is-nil ()
  "`graphite' 返回 nil：nil 就是「不下发 tint」的内部表示。"
  (should-not (seshat-reader--dark-tint-colors 'graphite))
  (should-not (seshat-reader--dark-tint-colors nil)))

(ert-deftest seshat-reader-theme-test-resolve-custom-cons ()
  "自定义 cons 合法时原样返回，边界值 `#000000' / `#xFFFFFF' 也合法。"
  (should (equal (seshat-reader--dark-tint-colors (cons #x101010 #xeeeeee))
                 (cons #x101010 #xeeeeee)))
  (should (equal (seshat-reader--dark-tint-colors (cons 0 #xFFFFFF))
                 (cons 0 #xFFFFFF))))

(ert-deftest seshat-reader-theme-test-resolve-invalid-values ()
  "非法取值返回 nil 且 `message' 恰好一次（不静默换成另一档配色）。"
  (dolist (bad (list (cons -1 #xFFFFFF)          ; 负值
                     (cons #x1000000 #xFFFFFF)   ; 超出 24 位
                     (cons "x" #xFFFFFF)         ; 非整数
                     (cons #x101010 nil)))       ; 缺一端
    (let ((messages 0))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (cl-incf messages))))
        (should-not (seshat-reader--dark-tint-colors bad)))
      (should (= 1 messages))))
  (let ((messages 0))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _) (cl-incf messages))))
      (should-not (seshat-reader--dark-tint-colors 'no-such-preset)))
    (should (= 1 messages))))

(provide 'seshat-reader-theme-test)
;;; seshat-reader-theme-test.el ends here
