;;; seshat-reader-evil-keymap-test.el --- Tests for reader evil and keymaps  -*- lexical-binding: t; -*-

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

;; 阅读器「关闭 evil + 键位预设 + 翻屏留 1 行」的 ERT 测试套件（M12 T9）。
;;
;; 覆盖 openspec/active/2026-10-26-reader-disable-evil-and-keymap.md 的 T1 语义：
;;
;;   1. 三个 defcustom 的默认值（`seshat-reader-disable-evil' 为 t、
;;      `seshat-reader-screen-context-lines' 为 1、`seshat-reader-keymap-preset'
;;      为 `vim'），且都是可定制变量；
;;   2. `seshat-reader-mode' 把 `next-screen-context-lines' 设成 defcustom 的值；
;;   3. `seshat-reader-keymap-preset' 的两向切换（vim ↔ emacs），含 `g' 在
;;      「前缀」与「完整绑定」之间的干净切换；
;;   4. `seshat-reader-disable-evil' 为 nil 时 helper **不**碰 `evil-local-mode'；
;;   5. 面板显示漏斗 `seshat-reader-sidebar--display' 在显示动作**之后**关闭
;;      evil（显示本身会把 evil 重新打开），且 evil 在显示路径上被重新打开后再次
;;      显示仍能关掉（T7 实测现象）；
;;   6. 被删除的三处 evil 补绑入口不再存在。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   "emacs" --batch -Q \
;;     -L "emacs" -L "emacs"/seshat-reader -L "emacs"/tests \
;;     -l ert -l "emacs"/tests/seshat-reader-evil-keymap-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建（`seshat-reader'
;; 模块加载需要它）。
;;
;; 纪律：**不加载 evil**（本机未安装，且真加载它会污染 keymap 解析）。evil 的
;; 存在性用 `cl-letf' 桩替 `evil-local-mode' 模拟，桩会真的写 buffer-local 值，
;; 从而能断言「关闭确实生效」而不只是「函数被调用」。本套件不需要任何外部包，
;; 故不使用 `skip-unless'——skipped 必须恒为 0。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
(require 'seshat-reader-sidebar)

;; evil 是软依赖（不 require）：测试里用 `cl-letf' 桩替它的函数，故先声明符号，
;; 避免字节编译器把 `let'/`setq-local' 里的同名变量当自由变量报错。
(defvar evil-local-mode)
(defvar evil-define-key*)

;;; 1. defcustom 默认值

(ert-deftest seshat-reader-evil-keymap-test--defcustom-defaults ()
  "三个新增 defcustom 的默认值，且都注册为可定制变量."
  (should (eq t seshat-reader-disable-evil))
  (should (= 1 seshat-reader-screen-context-lines))
  (should (eq 'vim seshat-reader-keymap-preset))
  ;; `use-package ... :custom' 走 `customize-set-variable'，变量必须先可定制
  (dolist (symbol '(seshat-reader-disable-evil
                    seshat-reader-screen-context-lines
                    seshat-reader-keymap-preset))
    (should (custom-variable-p symbol))))

;;; 2. 翻屏步长：`next-screen-context-lines' 取 defcustom 的值

(ert-deftest seshat-reader-evil-keymap-test--mode-sets-screen-context-lines ()
  "`seshat-reader-mode' 把 `next-screen-context-lines' 设为 defcustom 的值."
  (let ((file (make-temp-file "seshat-reader-ctx-test")))
    (unwind-protect
        (let ((buffer (find-file-noselect file)))
          (unwind-protect
              (with-current-buffer buffer
                ;; 只桩替「碰真实文档 / 真实窗口」的入口，其余 body 照常执行
                (cl-letf (((symbol-function 'seshat-reader--render-buffer)
                           (lambda (&rest _) nil))
                          ((symbol-function 'seshat-reader--disable-evil)
                           (lambda () nil))
                          ((symbol-function 'seshat-reader--first-fit)
                           (lambda (&rest _) nil)))
                  (seshat-reader-mode)
                  (should (= 1 next-screen-context-lines))
                  ;; 默认的 1 之外，改 defcustom 后 mode body 必须跟着走
                  (let ((seshat-reader-screen-context-lines 0))
                    (seshat-reader-mode)
                    (should (= 0 next-screen-context-lines)))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))
      (delete-file file))))

;;; 3. 键位预设两向切换

(ert-deftest seshat-reader-evil-keymap-test--preset-round-trip ()
  "vim → emacs → vim 往返：`C-f' / `C-b' / `g' / `g g' / `C-l' 语义两向正确."
  (unwind-protect
      (with-temp-buffer
        ;; `key-binding' 读的是当前 buffer 的键表，故先装上阅读器 map
        (use-local-map seshat-reader-mode-map)
        ;; ① emacs 预设 = 上游语义：字符移动键横向滚动，`g' 重渲染
        (seshat-reader--install-keymap-preset 'emacs)
        (should (eq (key-binding (kbd "C-f")) #'seshat-reader-scroll-right))
        (should (eq (key-binding (kbd "C-b")) #'seshat-reader-scroll-left))
        (should (eq (key-binding (kbd "g"))
                    #'seshat-reader-refresh-doc-buffer))
        ;; ② vim 预设 = 滚一屏 + `g' 让位给 `g g'，重渲染移到 `C-l'
        (seshat-reader--install-keymap-preset 'vim)
        (should (eq (key-binding (kbd "C-f"))
                    #'seshat-reader-scroll-down-screen))
        (should (eq (key-binding (kbd "C-b"))
                    #'seshat-reader-scroll-up-screen))
        (should (eq (key-binding (kbd "g g")) #'seshat-reader-first-page))
        (should (eq (key-binding (kbd "C-l"))
                    #'seshat-reader-refresh-doc-buffer))
        (should-not (eq (key-binding (kbd "g"))
                        #'seshat-reader-refresh-doc-buffer))
        ;; `g' 变成**前缀**（单按会等下一个键），不是命令也不是空绑定
        (should (keymapp (key-binding (kbd "g"))))
        ;; ③ 切回 emacs：`g' 恢复为完整绑定，`g g' 不再是首页
        (seshat-reader--install-keymap-preset 'emacs)
        (should (eq (key-binding (kbd "g"))
                    #'seshat-reader-refresh-doc-buffer))
        (should-not (eq (key-binding (kbd "g g")) #'seshat-reader-first-page)))
    ;; 收尾恢复默认预设：`--install-keymap-preset' 直接改共享 map 对象，不还原会
    ;; 污染同进程内的其它用例
    (seshat-reader--install-keymap-preset 'vim)))

;;; 4. `seshat-reader-disable-evil' 的两个方向

(ert-deftest seshat-reader-evil-keymap-test--disable-evil-turns-evil-off ()
  "非 nil（默认）且 evil 已在本 buffer 打开时，helper 用 -1 关掉它."
  (with-temp-buffer
    (setq-local evil-local-mode t)
    (let ((seshat-reader-disable-evil t)
          (calls nil))
      (cl-letf (((symbol-function 'evil-local-mode)
                 (lambda (arg) (push arg calls) nil)))
        (should (fboundp 'evil-local-mode))
        (seshat-reader--disable-evil)
        (should (equal calls '(-1)))))))

(ert-deftest seshat-reader-evil-keymap-test--disable-evil-honours-nil ()
  "`seshat-reader-disable-evil' 为 nil 时 **不**调用 `evil-local-mode'."
  (with-temp-buffer
    (setq-local evil-local-mode t)
    (let ((seshat-reader-disable-evil nil)
          (calls nil))
      (cl-letf (((symbol-function 'evil-local-mode)
                 (lambda (&rest _) (setq calls t))))
        (seshat-reader--disable-evil)
        (should-not calls)))))

;;; 4.1 reader 系 mode 的 evil initial state = emacs

(ert-deftest seshat-reader-evil-keymap-test--evil-initial-states ()
  "reader 系四个 major mode 的 evil initial state 都设成 emacs."
  (let (calls)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state) (push (cons mode state) calls) nil)))
      (seshat-reader--evil-set-initial-states))
    (should (equal (sort (mapcar #'car calls) #'string<)
                   (sort '(seshat-reader-mode seshat-reading-mode
                           seshat-reader-outline-mode
                           seshat-reader-annotation-list-mode)
                         #'string<)))
    (should (seq-every-p (lambda (call) (eq (cdr call) 'emacs)) calls))))

;;; 5. 面板显示漏斗：先显示，再关 evil

(ert-deftest seshat-reader-evil-keymap-test--display-disables-evil-after ()
  "`seshat-reader-sidebar--display' 在显示动作**之后**调用关闭 helper.
显示动作本身会把面板 buffer 的 evil 重新打开（实测 `pop-to-buffer' /
`display-buffer' 之后 `evil-local-mode' 又变回 t），故关闭必须发生在显示之后，
否则等于白关。"
  (let ((buffer (get-buffer-create " *Seshat evil-order panel*"))
        (events nil)
        (seshat-reader-sidebar--recent-kinds nil)
        (seshat-reader-sidebar--last-buffers nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'seshat-reader--disable-evil)
                     (lambda () (setq events (append events (list :kill)))))
                    ((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                     (lambda (_kind) 'window))
                    ((symbol-function 'seshat-reader-sidebar--display-window)
                     (lambda (_buffer _kind &optional _select)
                       (setq events (append events (list :display)))
                       'fake-window))
                    ((symbol-function 'seshat-reader-sidebar--cf-show)
                     (lambda (&rest _)
                       (setq events (append events (list :childframe-display)))
                       'fake-frame-window)))
            (should (eq (seshat-reader-sidebar--display buffer 'outline nil)
                        'fake-window)))
          ;; EVENTS 按**时间顺序**记录（`append' 而非 `push'）：先显示、后关 evil
          (should (equal events '(:display :kill))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest seshat-reader-evil-keymap-test--display-re-disables-re-enabled-evil ()
  "evil 在显示路径上被重新打开后，下一次显示仍能关掉它（T7 实测现象）."
  (let ((buffer (get-buffer-create " *Seshat evil-reenable panel*"))
        (seshat-reader-sidebar--recent-kinds nil)
        (seshat-reader-sidebar--last-buffers nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'evil-local-mode)
                     ;; 真实语义的替身：`-1' 关、正数开，写到当前 buffer
                     (lambda (arg) (setq-local evil-local-mode (> arg 0))))
                    ((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                     (lambda (_kind) 'window))
                    ((symbol-function 'seshat-reader-sidebar--display-window)
                     (lambda (&rest _) 'fake-window))
                    ((symbol-function 'seshat-reader-sidebar--cf-show)
                     (lambda (&rest _) 'fake-frame-window)))
            ;; 模拟 `pop-to-buffer' 之后 evil 的全局 minor mode 又把面板 buffer
            ;; 拉回 normal state
            (with-current-buffer buffer
              (setq-local evil-local-mode t))
            (seshat-reader-sidebar--display buffer 'translate nil)
            ;; 关闭必须落在**面板 buffer 自己**身上
            (with-current-buffer buffer
              (should-not evil-local-mode))
            ;; 再开一次 → 第二次显示同样关掉（幂等，不依赖「第一次已关」）
            (with-current-buffer buffer
              (setq-local evil-local-mode t))
            (seshat-reader-sidebar--display buffer 'translate nil)
            (with-current-buffer buffer
              (should-not evil-local-mode))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;;; 6. 旧的 evil 补绑入口已删除

(ert-deftest seshat-reader-evil-keymap-test--old-evil-helpers-removed ()
  "三处 evil 补绑辅助函数及其绑定表整体删除（语义改为「关闭 evil」）."
  (should-not (fboundp 'seshat-reader--install-evil-bindings))
  (should-not (fboundp 'seshat-reader-outline--install-evil-bindings))
  (should-not (fboundp 'seshat-reader-sidebar--ensure-panel-evil-keys))
  (should-not (fboundp 'seshat-reader-sidebar--panel-normal-key-specs))
  (should-not (fboundp 'seshat-reader-sidebar--panel-common-keys))
  ;; 连符号本身都不该残留（否则还能被 `boundp' 检查到）
  (should-not (boundp 'seshat-reader-sidebar--panel-normal-key-specs))
  (should-not (boundp 'seshat-reader-sidebar--panel-common-keys)))

(provide 'seshat-reader-evil-keymap-test)
;;; seshat-reader-evil-keymap-test.el ends here
