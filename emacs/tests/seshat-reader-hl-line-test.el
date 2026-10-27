;;; seshat-reader-hl-line-test.el --- hl-line 在阅读 buffer 内必须关闭  -*- lexical-binding: t; -*-

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

;; `seshat-reader-mode' buffer 内 `hl-line-mode' 必须恒为关闭的 ERT 套件。
;;
;; 为什么必须在阅读 buffer 里关掉：多页布局下「一行 = 一整页图像」，`hl-line'
;; 的 overlay 只按 `line-beginning-position'/`line-end-position' 染色，于是把当前
;; 页那一行的**左右留白**也染成 `hl-line' 的底色（实测 #2A2E38），而上下相邻页
;; 的行仍是主题底色（#242730）→ 同屏两页两侧留白颜色不一致。留白不属于任何
;; 页面位图，染色只暴露「这个 buffer 其实是文本行」这一实现细节。
;;
;; 覆盖三类契约：
;;
;; 1. 与 `global-hl-line-mode' 的时序竞争：它是**全局化** minor mode，会在
;;    `after-change-major-mode-hook' 上为每个新 major mode 重新打开
;;    `hl-line-mode'，所以 mode body 里直接关掉是**站不住**的；收尾函数必须
;;    排在全局化 checker **之后**运行（否则关完又被重开）。
;; 2. 显式重新打开后仍被收尾路径关掉（模拟「全局化 minor mode 在 mode 建立
;;    之后重新启用」）。
;; 3. 不误伤：非阅读 buffer（`special-mode' / `fundamental-mode'）里手动打开的
;;    `hl-line-mode' 不受影响——侧栏 / 大纲 / 标注列表仍需要 hl-line 做列表导航。
;;
;; 全部用例在 `emacs --batch -Q' 下可跑：只桩替碰真实文档与真实窗口的两个入口
;; （`seshat-reader--render-buffer' / `seshat-reader--first-fit'），不渲染 PDF、
;; 不接触运行中的 Emacs。`hl-line-mode' 自身是纯 overlay 的 buffer-local minor
;; mode，batch 下可正常开关（无需图形界面）。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader -l ert \
;;     -l emacs/tests/seshat-reader-hl-line-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)

(defun seshat-reader-hl-line-test--open-reader-buffer (&optional mode)
  "在当前 buffer 里真正跑一遍 MODE（默认 `seshat-reader-mode'）。

只桩替 `seshat-reader--render-buffer'（真渲染需要动态模块与真实 PDF）与
`seshat-reader--first-fit'（碰真实窗口）：收尾函数的注册就在父 mode body 里，
桩掉 body 就没有被测对象了。"
  (cl-letf (((symbol-function 'seshat-reader--render-buffer)
             (lambda (&rest _) nil))
            ((symbol-function 'seshat-reader--first-fit)
             (lambda (&rest _) nil)))
    (funcall (or mode #'seshat-reader-mode))))

(defmacro seshat-reader-hl-line-test--with-file-buffer (&rest body)
  "在带合法 `buffer-file-name' 的临时 buffer 内执行 BODY.

`seshat-reader-mode' 的 body 开头有 kill-buffer 守卫（文件不存在 / 不可读就
杀 buffer），故必须用真实存在的临时文件；`find-file-noselect' 顺带给出未
改动的全新 buffer，用例之间不会互相污染。"
  (declare (indent 0) (debug t))
  `(let ((file (make-temp-file "seshat-reader-hl-line-test")))
     (unwind-protect
         (let ((buffer (find-file-noselect file)))
           (unwind-protect
               (with-current-buffer buffer
                 ,@body)
             (when (buffer-live-p buffer) (kill-buffer buffer))))
       (delete-file file))))

;;;; 1. 与 `global-hl-line-mode' 的时序竞争

(ert-deftest seshat-reader-hl-line-test--wins-over-globalized-turn-on ()
  "全局化 minor mode 在阅读 buffer 重开 `hl-line' 时，收尾函数仍胜出.

`global-hl-line-mode' 在 batch（无 display）下**不会**把它的 checker 注册到
`after-change-major-mode-hook'（实测 Emacs 31.1：`(global-hl-line-mode 1)'
之后该 hook 仍只有 eldoc 的 checker，`special-mode' buffer 里 `hl-line-mode'
也没被打开），故这里用**同形状**的全局 hook 代替：往全局值里放一个会
`(hl-line-mode 1)' 的函数。它先于 buffer-local 值里的收尾函数运行（本地值
形如 `(t FUNC)'），所以最终必须回到 nil——顺序反了就会是 t。"
  (let* ((turn-on-calls 0)
         (turn-on (lambda ()
                    (cl-incf turn-on-calls)
                    (hl-line-mode 1))))
    (unwind-protect
        (progn
          (add-hook 'after-change-major-mode-hook turn-on)
          (seshat-reader-hl-line-test--with-file-buffer
            (seshat-reader-hl-line-test--open-reader-buffer)
            (should (derived-mode-p 'seshat-reader-mode))
            (should (memq turn-on
                          (default-value 'after-change-major-mode-hook)))
            ;; 全局 turn-on 确实跑过（否则「最终 nil」是空跑得来的）。
            (should (>= turn-on-calls 1))
            (should-not (bound-and-true-p hl-line-mode))))
      (remove-hook 'after-change-major-mode-hook turn-on))))

(ert-deftest seshat-reader-hl-line-test--disable-fn-is-last-in-hook ()
  "阅读 buffer 的 `after-change-major-mode-hook' 末尾就是收尾函数.

这是上面那个用例的**结构契约**：只要收尾函数排在 buffer-local hook 的末尾，
全局化 checker（全局值部分）就先跑，关闭才粘得住。断言形如 `(t FUNC)' 的值
也顺带钉住「buffer-local 值仍会运行全局值」这一点。"
  (seshat-reader-hl-line-test--with-file-buffer
    (seshat-reader-hl-line-test--open-reader-buffer)
    (let ((hook (symbol-value 'after-change-major-mode-hook)))
      (should (local-variable-p 'after-change-major-mode-hook))
      (should (eq (car (last hook)) #'seshat-reader--disable-hl-line))
      ;; `t' 元素表示「全局值也要跑」；没有它，buffer-local 值会**顶掉**全局
      ;; hook，阅读 buffer 之外的全局化 minor mode 就会在本 buffer 失效。
      (should (memq t hook)))))

;;;; 2. 重新启用后仍被收尾路径关掉

(ert-deftest seshat-reader-hl-line-test--hook-turns-hl-line-off-again ()
  "阅读 buffer 里手动重新打开 `hl-line-mode' 后，收尾路径会把它关掉.

模拟「全局化 minor mode 在 mode body 之后重新启用」：先 `(hl-line-mode 1)'，
再触发 `after-change-major-mode-hook'，最终必须回到 nil。"
  (seshat-reader-hl-line-test--with-file-buffer
    (seshat-reader-hl-line-test--open-reader-buffer)
    (should (derived-mode-p 'seshat-reader-mode))
    (hl-line-mode 1)
    (should (bound-and-true-p hl-line-mode))
    (run-hooks 'after-change-major-mode-hook)
    (should-not (bound-and-true-p hl-line-mode))))

(ert-deftest seshat-reader-hl-line-test--derived-reading-mode-also-clean ()
  "`seshat-reader-mode' 的派生 mode（`seshat-reading-mode'）同样保持关闭.

收尾函数的注册发生在父 mode body 里，派生 mode 跑父 body 时同样会注册，
故这条链路不需要额外代码——但要真的按派生 mode 跑一遍才能确认它没被
派生 mode 的 `kill-all-local-variables' 之类的操作冲掉。"
  (require 'seshat-reading)
  (seshat-reader-hl-line-test--with-file-buffer
    (seshat-reader-hl-line-test--open-reader-buffer #'seshat-reading-mode)
    (should (derived-mode-p 'seshat-reading-mode))
    (should (eq (car (last (symbol-value 'after-change-major-mode-hook)))
                #'seshat-reader--disable-hl-line))
    (hl-line-mode 1)
    (run-hooks 'after-change-major-mode-hook)
    (should-not (bound-and-true-p hl-line-mode))))

;;;; 3. 不误伤：非阅读 buffer

(ert-deftest seshat-reader-hl-line-test--special-mode-keeps-hl-line ()
  "非阅读的 `special-mode' buffer 里 `hl-line-mode' 必须**不**受影响.

侧栏 / 大纲 / 标注列表都是 `special-mode' 派生，列表导航依赖 hl-line；收尾
函数只能对 `seshat-reader-mode' 生效。"
  (with-temp-buffer
    (special-mode)
    (hl-line-mode 1)
    (run-hooks 'after-change-major-mode-hook)
    (should (bound-and-true-p hl-line-mode))))

(ert-deftest seshat-reader-hl-line-test--fundamental-mode-keeps-hl-line ()
  "非阅读的 `fundamental-mode' buffer 里手动打开的 `hl-line-mode' 不受影响."
  (with-temp-buffer
    (fundamental-mode)
    (hl-line-mode 1)
    (run-hooks 'after-change-major-mode-hook)
    (should (bound-and-true-p hl-line-mode))))

(provide 'seshat-reader-hl-line-test)

;;; seshat-reader-hl-line-test.el ends here
