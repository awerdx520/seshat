;;; seshat-reader-sidebar-test.el --- Tests for seshat-reader-sidebar  -*- lexical-binding: t; -*-

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

;; `seshat-reader-sidebar' 的 ERT 测试套件。
;;
;; 运行方式（在仓库根目录执行）。下条命令**可直接复制运行**：其中写作
;; `"emacs"' 的是 Emacs 可执行文件名，加引号只为让 checkdoc 的专有名词检查
;; 予以忽略，shell 语义与不带引号完全一致。除本仓库两个 `-L' 外，还必须把
;; go-translate（gt）及其依赖（pdd/posframe）的 straight 构建目录加入
;; `load-path'——否则 `(require 'gt)' 失败，涉及 gt 的译文渲染对象用例会被
;; `ert-skip' 跳过：
;;
;;   cd /home/thomas/WorkSpace/notes && \
;;   "emacs" --batch -Q \
;;     -L "emacs" -L "emacs"/seshat-reader \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
;;     -l "emacs"/tests/seshat-reader-sidebar-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 上面 gt 的三个路径是 straight 的默认构建目录（形如
;; `<配置目录>/.local/straight/build-<emacs 版本>/'）。换机器或 Emacs 版本
;; 时，用下面的命令**探测**实际父目录，再把
;; `-L "$GTROOT/gt" -L "$GTROOT/pdd" -L "$GTROOT/posframe"' 补进命令：
;;
;;   GTROOT=$(dirname "$(find "$HOME" -maxdepth 6 -type d \
;;            -path '*/straight/build-*/gt' 2>/dev/null | head -n1)")
;;   echo "$GTROOT"   # 应形如 /home/thomas/thomas-emacs/.local/straight/build-31.1
;;
;; 或者直接 dump 一个已加载用户配置的 Emacs 的 `load-path'，从中挑出 gt 目录：
;;
;;   "emacs" --batch -l ~/.emacs.d/init.el --eval '(prin1 load-path)'
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建（`seshat-reader'
;; 模块加载需要它）。
;;
;; 全部用例**绝不触网**、**绝不写用户真实文件**：窗口显示一律以 `cl-letf'
;; 桩替两个显示出入口（`display-buffer' / `pop-to-buffer'）与
;; `delete-window' / `window-toggle-side-windows'；经信息面板显示的 buffer
;; 一律用 `get-buffer-create' 造的临时 buffer，并在用例末 `kill-buffer'；
;; 共享变量一律 `let' 就地绑定，退出即恢复。需要 go-translate 的用例先
;; `(require 'gt nil t)' 判定，不可用时以 `ert-skip' 跳过而不使整套失败。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eieio)
;; 编译期加载 gt 的 buffer 渲染器（若在 `load-path' 中），使编译器认识
;; `gt-buffer-render' 的 `window-config' 等槽，避免 “Unknown slot” 编译告警；
;; 运行时仍由用例内的 `(require 'gt nil t)' 按需加载，gt 缺失时用例被跳过。
(eval-when-compile (require 'gt-render-buffer nil t))
(require 'seshat-reader)
(require 'seshat-reader-sidebar)
(require 'seshat-reader-translate)

;;; 显示参数（--display-params / --display）

(ert-deftest seshat-reader-sidebar-test--display-params-below-selected ()
  "默认 `below-selected' 时经 `display-buffer-overriding-action' 传给 `display-buffer' 的 action list 正确."
  (let ((seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar--state nil)
        (captured nil)
        (buf (get-buffer-create "*seshat-sidebar-test-params-a*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (_b &optional _action)
                       (setq captured display-buffer-overriding-action)
                       'win)))
            (seshat-reader-sidebar--display buf 'annotations))
          (should (eq (car captured) 'display-buffer-below-selected))
          (should-not (eq (car captured) 'display-buffer-at-bottom))
          (should (equal (cdr (assq 'window-height captured)) 0.35))
          (should (equal (cdr (assq 'window-parameters captured))
                         '((seshat-reader-sidebar . t)
                           (seshat-reader-sidebar-kind . annotations)))))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--display-params-at-bottom ()
  "`position' 为 `at-bottom' 时 action list 换用 `display-buffer-at-bottom'."
  (let ((seshat-reader-sidebar-position 'at-bottom)
        (seshat-reader-sidebar-height 0.5)
        (params nil))
    (setq params (seshat-reader-sidebar--display-params))
    (should (member '(display-buffer-at-bottom) params))
    (should-not (member '(display-buffer-below-selected) params))
    (should (equal (cdr (assq 'window-height params)) 0.5))
    (should (equal (cdr (assq 'window-parameters params))
                   '((seshat-reader-sidebar . t)
                     (seshat-reader-sidebar-kind))))))

;;; 统一显示入口（show）

(ert-deftest seshat-reader-sidebar-test--show-enabled-uses-display-buffer ()
  "`enabled' 为真时 `show' 走 `display-buffer'，overriding-action 等于批注版 `--display-params'（含 select）."
  (let ((seshat-reader-sidebar-enabled t)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar--state nil)
        (captured nil)
        (pop-called nil)
        (buf (get-buffer-create "*seshat-sidebar-test-show-on*")))
    (unwind-protect
        (progn
                      (cl-letf (((symbol-function 'display-buffer)
                               (lambda (b &optional _action)
                                 (setq captured (list b display-buffer-overriding-action))
                                 'fake-win))
                              ((symbol-function 'pop-to-buffer)
                               (lambda (&rest _) (setq pop-called t) nil)))
                      ;; 调用点（`seshat-reader-annotation--render-list'）传 SELECT=t，
                      ;; 故此处按同样契约调用。
                      (should (eq (seshat-reader-sidebar-show buf 'annotations t)
                                  'fake-win)))
          (should (eq (car captured) buf))
          (let ((params (seshat-reader-sidebar--display-params 'annotations t)))
            ;; overriding-action 是规范 `(FUNCTIONS . ALIST)' cons cell
            (should (equal (cadr captured) (cons (caar params) (cdr params)))))
          (should-not pop-called))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--select-window-both-kinds ()
  "译文与批注两条显示路径的 action list 都含 `(post-command-select-window . t)'.
T10 第 1 轮反馈的验收：用户要求译文面板也跟随光标。分两段断言——
① **管线**：`seshat-reader-sidebar-show'（两种 KIND）与 popper 重开走的
`seshat-reader-sidebar-display-buffer'（两种 buffer 名）都把该项放进
`display-buffer-overriding-action'；
② **调用点**：批注渲染（`seshat-reader-annotation--render-list'）与译文渲染
（`seshat-reader-translate--render-sidebar-etaf'）都实际传了 SELECT=t，故管道
两侧闭合——任一侧漏传都会让译文面板不跟随光标。"
  (let ((seshat-reader-sidebar-enabled t)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar-select-window t)
        (seshat-reader-sidebar--state nil)
        (captured nil)
        (buf (get-buffer-create "*seshat-sidebar-test-select-window*"))
        (tbuf (get-buffer-create seshat-reader-sidebar-translate-buffer-name)))
    (unwind-protect
        (progn
          ;; ---- ① 管线：四条显示入口 ----
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (b &optional _action)
                       (push (cons b display-buffer-overriding-action)
                             captured)
                       'fake-win)))
            (dolist (case (list (list "show/annotations"
                                      (lambda ()
                                        (seshat-reader-sidebar-show
                                         buf 'annotations t)))
                                (list "show/translate"
                                      (lambda ()
                                        (seshat-reader-sidebar-show
                                         tbuf 'translate t)))
                                (list "display-buffer/annotations"
                                      (lambda ()
                                        (seshat-reader-sidebar-display-buffer
                                         buf nil)))
                                (list "display-buffer/translate"
                                      (lambda ()
                                        (seshat-reader-sidebar-display-buffer
                                         tbuf nil)))))
              (setq captured nil)
              (funcall (cadr case))
              (let* ((label (car case))
                     (alist (cdar captured)))
                (should (consp captured))
                (should (member (cons 'post-command-select-window t)
                                alist))
                ;; kind 标记随之正确（译文走 translate，其余走 annotations）
                (should (eq (alist-get 'seshat-reader-sidebar-kind
                                       (alist-get 'window-parameters alist))
                            (if (string-match-p "translate" label)
                                'translate
                              'annotations))))))
          ;; ---- ② 调用点：两条渲染路径都传 SELECT=t ----
          (let ((calls nil))
            (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                       (lambda (b k &optional s)
                         (push (list k s) calls) 'fake-win))
                      ((symbol-function 'seshat-reader-annotation--etaf-p)
                       (lambda () nil))
                      ((symbol-function 'seshat-reader-translate--gt-buffer-text)
                       (lambda () "一句译文"))
                      ((symbol-function 'seshat-reader-etaf-render-translate)
                       (lambda (&rest _args) nil)))
              ;; 批注：走文本回退路径，末尾仍经 `show' 以 annotations 显示
              (seshat-reader-annotation--render-list
               "doc-select" nil
               '(((id . 1) (location . "page:1;rect:0,0,0,0")
                  (text . "一条批注")))
               nil)
              ;; 译文：不依赖 gt，只验 `show' 的第三个实参
              (seshat-reader-translate--render-sidebar-etaf))
            (should (equal (list 'annotations t) (assq 'annotations calls)))
            (should (equal (list 'translate t) (assq 'translate calls)))
            (dolist (call calls)
              (should (cadr call)))))
      (dolist (b (list buf tbuf
                       (get-buffer seshat-reader-annotation-list-buffer-name)))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest seshat-reader-sidebar-test--show-disabled-uses-pop-to-buffer ()
  "`enabled' 为 nil 时 `show' 退回 `pop-to-buffer'，不调用 `display-buffer'."
  (let ((seshat-reader-sidebar-enabled nil)
        (pop-called nil)
        (display-called nil)
        (buf (get-buffer-create "*seshat-sidebar-test-show-off*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (setq pop-called b) 'fake-win))
                    ((symbol-function 'display-buffer)
                     (lambda (&rest _) (setq display-called t) nil)))
            (should (eq (seshat-reader-sidebar-show buf 'annotations) 'fake-win)))
          (should (eq pop-called buf))
          (should-not display-called))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--show-returns-window ()
  "`show' 对尚未显示的 buffer 不报错，并返回一个窗口."
  (let ((seshat-reader-sidebar-enabled t)
        (seshat-reader-sidebar-position 'below-selected)
        (buf (get-buffer-create "*seshat-sidebar-test-live*"))
        (win nil))
    (unwind-protect
        (progn
          (setq win (seshat-reader-sidebar-show buf 'annotations))
          (should (windowp win))
          (should (eq (window-buffer win) buf)))
      (when (windowp win)
        (ignore-errors (delete-window win)))
      (kill-buffer buf))))

;;; 面板窗口判据（window-p）

(ert-deftest seshat-reader-sidebar-test--window-p-predicate ()
  "`window-p' 仅对本包面板窗口为真，对 nil 与普通窗口为假."
  (should-not (seshat-reader-sidebar-window-p nil))
  (should-not (seshat-reader-sidebar-window-p (selected-window)))
  (let ((win (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter win 'seshat-reader-sidebar t)
          (should (seshat-reader-sidebar-window-p win)))
      (set-window-parameter win 'seshat-reader-sidebar nil))))

;;; 开合（toggle）

(ert-deftest seshat-reader-sidebar-test--toggle-closes-package-windows ()
  "有本包窗口时 `toggle' 逐个 `delete-window'，且不调用 `window-toggle-side-windows'."
  (let ((win (selected-window))
        (orig-buffer (window-buffer (selected-window)))
        (buf (get-buffer-create "*seshat-sidebar-test-toggle-close*"))
        (deleted nil)
        (side-toggled 0))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (set-window-parameter win 'seshat-reader-sidebar t)
          (should (= (length (seshat-reader-sidebar--windows)) 1))
          (cl-letf (((symbol-function 'delete-window)
                     (lambda (w) (push w deleted)))
                    ((symbol-function 'window-toggle-side-windows)
                     (lambda (&rest _) (cl-incf side-toggled)))
                    ((symbol-function 'message) (lambda (&rest _) nil)))
            (seshat-reader-sidebar-toggle))
          (should (= (length deleted) 1))
          (should (eq (car deleted) win))
          (should (= side-toggled 0)))
      (set-window-parameter win 'seshat-reader-sidebar nil)
      (set-window-buffer win orig-buffer)
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-reopens-last-buffer ()
  "无本包窗口但有 `--last-buffer' 时按最近 kind 重新 `show'，且不调用 frame 级开关."
  (let ((seshat-reader-sidebar--last-buffer
         (get-buffer-create "*seshat-sidebar-test-toggle-open*"))
        (seshat-reader-sidebar--last-kind 'annotations)
        (seshat-reader-sidebar-enabled t)
        (shown nil)
        (side-toggled 0))
    (unwind-protect
        (progn
          (should (null (seshat-reader-sidebar--windows)))
          (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                     (lambda (b k &optional s) (setq shown (list b k s)) 'win))
                    ((symbol-function 'window-toggle-side-windows)
                     (lambda (&rest _) (cl-incf side-toggled)))
                    ((symbol-function 'message) (lambda (&rest _) nil)))
            (seshat-reader-sidebar-toggle))
          (should (eq (car shown) seshat-reader-sidebar--last-buffer))
          (should (eq (cadr shown) 'annotations))
          ;; 重开是显式用户动作，按 T10 第 1 轮修复后的契约传 SELECT=t
          (should (nth 2 shown))
          (should (= side-toggled 0)))
      (kill-buffer seshat-reader-sidebar--last-buffer))))

(ert-deftest seshat-reader-sidebar-test--toggle-no-restore-messages ()
  "无可恢复 buffer 时 `toggle' 仅提示，且不调用 `window-toggle-side-windows'."
  (let ((seshat-reader-sidebar--last-buffer nil)
        (messages nil)
        (side-toggled 0))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
              ((symbol-function 'window-toggle-side-windows)
               (lambda (&rest _) (cl-incf side-toggled))))
      (seshat-reader-sidebar-toggle))
    (should (= side-toggled 0))
    (should (cl-some (lambda (m) (string-match-p "先打开批注列表" m)) messages))))

(ert-deftest seshat-reader-sidebar-test--toggle-dead-buffer-messages ()
  "`--last-buffer' 已死时 `toggle' 同样只提示、不重开."
  (let* ((buf (generate-new-buffer "*seshat-sidebar-test-dead*"))
         (seshat-reader-sidebar--last-buffer buf)
         (messages nil))
    (kill-buffer buf)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (seshat-reader-sidebar-toggle))
    (should messages)))

;;; 译文面板渲染路径（--render-object）

(ert-deftest seshat-reader-sidebar-test--translate-sidebar-render-object ()
  "ETAF 不可用时 `sidebar' 分支用 go-translate function `gt-buffer-render'，其 `window-config' 槽等于 `--display-params'，不建 posframe."
  (unless (require 'gt nil t) (ert-skip "gt 未加载"))
  ;; 先让渲染层进入「已加载」态：无 ETAF 时这一步失败，渲染层保持未加载，
  ;; 后续判断自然为 nil；有 ETAF 时先加载、再由下面的 `cl-letf' 桩成不可用。
  ;; 顺序不能颠倒——`cl-letf' 的桩会被 `require' 期间执行的 `defun' 覆盖。
  (ignore-errors (require 'seshat-reader-etaf nil t))
  (let ((seshat-reader-sidebar-enabled t)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar--state nil)
        (obj nil))
    ;; `--render-object' 现会按需 `require' 渲染层（M11.9 缺口修补：先翻译、
    ;; 再开批注列表时 ETAF 排版不得静默失效），故「渲染层尚未加载」不再是
    ;; 可靠前提。本用例要验的是 **ETAF 不可用**时的降级路径，因此显式把
    ;; `available-p' 钉成 nil；模块不可加载与模块已加载但不可用两条情形都
    ;; 落到 gt 直接渲染。
    (cl-letf (((symbol-function 'seshat-reader-etaf-available-p)
               (lambda () nil)))
      (setq obj (seshat-reader-translate--render-object 'sidebar)))
    (should (eq (eieio-object-class obj) 'gt-buffer-render))
    (should (equal (slot-value obj 'window-config)
                   (seshat-reader-sidebar--display-params 'translate)))
    (should (equal (slot-value obj 'name)
                   seshat-reader-sidebar-translate-buffer-name))))

(ert-deftest seshat-reader-sidebar-test--translate-pop-pin-render-object ()
  "`pop'/`pin' 分支分别返回弹出式/固定式 posframe 渲染器."
  (unless (require 'gt nil t) (ert-skip "gt 未加载"))
  (should (eq (eieio-object-class (seshat-reader-translate--render-object 'pop))
              'gt-posframe-pop-render))
  (should (eq (eieio-object-class (seshat-reader-translate--render-object 'pin))
              'gt-posframe-pin-render))
  (should (eq (eieio-object-class (seshat-reader-translate--render-object nil))
              'gt-posframe-pop-render)))

(ert-deftest seshat-reader-sidebar-test--translate-sidebar-disabled-posframe ()
  "`enabled' 为 nil 时 `sidebar' 回退为弹出式 posframe."
  (unless (require 'gt nil t) (ert-skip "gt 未加载"))
  (let ((seshat-reader-sidebar-enabled nil))
    (should (eq (eieio-object-class
                 (seshat-reader-translate--render-object 'sidebar))
                'gt-posframe-pop-render))))

;;; per-kind 窗口状态记忆（2026-10-16 返工）

(ert-deftest seshat-reader-sidebar-test--height-for-kind-default-and-memory ()
  "首次显示某 kind 用 `seshat-reader-sidebar-height'，命中记忆时用记忆值."
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar--state nil))
    (should (equal (cdr (assq 'window-height
                              (seshat-reader-sidebar--display-params 'annotations)))
                   0.35))
    (setq seshat-reader-sidebar--state '((annotations . 0.5)))
    (should (equal (cdr (assq 'window-height
                              (seshat-reader-sidebar--display-params 'annotations)))
                   0.5))
    (should (equal (cdr (assq 'window-height
                              (seshat-reader-sidebar--display-params 'translate)))
                   0.35))
    (should (equal (cdr (assq 'window-height
                              (seshat-reader-sidebar--display-params)))
                   0.35))))

(ert-deftest seshat-reader-sidebar-test--switch-captures-and-restores-height ()
  "切换 kind 时先捕获当前窗口高度，再按目标 kind 的记忆高度新建窗口."
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar--state nil)
        (fake-kind nil)
        (win 'fake-sidebar-window)
        (deleted 0)
        (shown nil)
        (buf (get-buffer-create "*seshat-sidebar-test-switch*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () (if fake-kind (list win) nil)))
                  ((symbol-function 'window-parameter)
                   (lambda (_w param)
                     (pcase param
                       ('seshat-reader-sidebar (and fake-kind t))
                       ('seshat-reader-sidebar-kind fake-kind))))
                  ((symbol-function 'window-total-height) (lambda (&rest _) 20))
                  ((symbol-function 'frame-height) (lambda (&rest _) 40))
                  ((symbol-function 'delete-window)
                   (lambda (&optional _w) (cl-incf deleted) (setq fake-kind nil)))
                  ((symbol-function 'display-buffer)
                   (lambda (_b &optional _action)
                     (push (cdr (assq 'window-height
                                      display-buffer-overriding-action))
                           shown)
                     'fake-win)))
          ;; 1) 首次显示 annotations：无本包窗口，用默认 0.35
          (seshat-reader-sidebar--display buf 'annotations)
          (should (equal (car shown) 0.35))
          (should (= deleted 0))
          (setq fake-kind 'annotations)   ; 模拟窗口已显示且 kind=annotations
          ;; 2) 切到 translate：捕获 annotations=0.5 → 关闭旧窗口 → 用默认 0.35
          (seshat-reader-sidebar--display buf 'translate)
          (should (= deleted 1))
          (should (equal (cdr (assq 'annotations seshat-reader-sidebar--state)) 0.5))
          (should (equal (car shown) 0.35))
          (setq fake-kind 'translate)
          ;; 3) 切回 annotations：捕获 translate=0.5 → 用记忆的 annotations=0.5
          (seshat-reader-sidebar--display buf 'annotations)
          (should (= deleted 2))
          (should (equal (car shown) 0.5))
          (should (equal (cdr (assq 'translate seshat-reader-sidebar--state)) 0.5)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--same-kind-display-idempotent ()
  "同 kind 再次显示不调用 `delete-window'，并沿用该 kind 的记忆高度."
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar--state '((annotations . 0.5)))
        (deleted 0)
        (shown nil)
        (win 'fake-sidebar-window)
        (buf (get-buffer-create "*seshat-sidebar-test-idempotent*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () (list win)))
                  ((symbol-function 'window-parameter)
                   (lambda (_w param)
                     (pcase param
                       ('seshat-reader-sidebar t)
                       ('seshat-reader-sidebar-kind 'annotations))))
                  ((symbol-function 'window-total-height) (lambda (&rest _) 20))
                  ((symbol-function 'frame-height) (lambda (&rest _) 40))
                  ((symbol-function 'delete-window)
                   (lambda (&optional _w) (cl-incf deleted)))
                  ((symbol-function 'display-buffer)
                   (lambda (_b &optional _action)
                     (push (cdr (assq 'window-height
                                      display-buffer-overriding-action))
                           shown)
                     'fake-win)))
          (seshat-reader-sidebar--display buf 'annotations)
          (should (= deleted 0))
          (should (equal (car shown) 0.5)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-captures-before-close ()
  "`toggle' 关闭窗口前先捕获其高度到 `seshat-reader-sidebar--state'."
  (let ((seshat-reader-sidebar--state nil)
        (seshat-reader-sidebar--last-buffer nil)
        (win 'fake-sidebar-window)
        (deleted 0)
        (buf (get-buffer-create "*seshat-sidebar-test-toggle-capture*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () (list win)))
                  ((symbol-function 'window-parameter)
                   (lambda (_w param)
                     (pcase param
                       ('seshat-reader-sidebar t)
                       ('seshat-reader-sidebar-kind 'annotations))))
                  ((symbol-function 'window-total-height) (lambda (&rest _) 16))
                  ((symbol-function 'frame-height) (lambda (&rest _) 40))
                  ((symbol-function 'window-buffer) (lambda (&optional _w) buf))
                  ((symbol-function 'delete-window)
                   (lambda (&optional _w) (cl-incf deleted)))
                  ((symbol-function 'message) (lambda (&rest _) nil)))
          (seshat-reader-sidebar-toggle)
          (should (= deleted 1))
          (should (equal (cdr (assq 'annotations seshat-reader-sidebar--state)) 0.4))
          (should (eq seshat-reader-sidebar--last-buffer buf)))
      (kill-buffer buf))))

(provide 'seshat-reader-sidebar-test)
;;; seshat-reader-sidebar-test.el ends here
