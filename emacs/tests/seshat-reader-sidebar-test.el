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
;; 帮助页模块：`?' 绑定与 `*Seshat Reader Help*' 的内容断言都要用到它。
(require 'seshat-reader-help)

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
  ② **调用点**：批注渲染（`seshat-reader-annotation--render-list'）传 SELECT=t，
译文渲染（`seshat-reader-translate--render-panel'）传 SELECT=nil——阅读场景不
抢光标，光标留在阅读窗口；是否真正追加该项仍由调用方决定，管道不猜。"
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
                       (lambda () nil)))
              ;; 批注：走文本回退路径，末尾仍经 `show' 以 annotations 显示
              (seshat-reader-annotation--render-list
               "doc-select" nil
               '(((id . 1) (location . "page:1;rect:0,0,0,0")
                  (text . "一条批注")))
               nil)
              ;; 译文：面板缓冲写入 + `show'，不依赖 gt
              (seshat-reader-translate--render-panel "一句译文" "Seshat 译文"))
            ;; 批注列表仍在内容就绪后请求跟随光标；译文/解释面板自 2026-10-26
            ;; 起**不**抢光标（SELECT=nil，光标留在阅读窗口），见
            ;; `seshat-reader-translate--render-panel' 的 docstring。
            (should (equal (list 'annotations t) (assq 'annotations calls)))
            (should (equal (list 'translate nil) (assq 'translate calls)))))
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
  "`sidebar' 分支（enabled 非 nil）让 gt 渲染到**隐藏中转 buffer**，由 `:then' 接管面板展示."
  (unless (require 'gt nil t) (ert-skip "gt 未加载"))
  (unless (require 'gt-render-buffer nil t) (ert-skip "gt-render-buffer 未加载"))
  (let* ((seshat-reader-sidebar-enabled t)
         (obj (seshat-reader-translate--render-object 'sidebar))
         (window-config (slot-value obj 'window-config)))
    (should (eq (eieio-object-class obj) 'gt-buffer-render))
    ;; `:name' 是隐藏中转 buffer，不是展示用的面板 buffer
    (should (equal (slot-value obj 'name)
                   seshat-reader-translate--gt-buffer-name))
    (should-not (equal (slot-value obj 'name)
                       seshat-reader-sidebar-translate-buffer-name))
    (should (equal '(display-buffer-no-window) (car window-config)))
    (should (member '(allow-no-window . t) window-config))
    (should (functionp (slot-value obj 'then)))))

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
    (setq seshat-reader-sidebar--state '((annotations height 0.5)))
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
  "显示另一 kind 时先捕获当前窗口高度，且不关闭其它 kind 的窗口."
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar--state nil)
        (wins nil)                      ; alist（WINDOW . KIND），模拟已显示面板
        (deleted 0)
        (shown nil)
        (buf (get-buffer-create "*seshat-sidebar-test-switch*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () (mapcar #'car wins)))
                  ((symbol-function 'window-parameter)
                   (lambda (w param)
                     (pcase param
                       ('seshat-reader-sidebar (and (assq w wins) t))
                       ('seshat-reader-sidebar-kind (cdr (assq w wins)))
                       ('window-side nil))))
                  ((symbol-function 'window-total-height) (lambda (&rest _) 20))
                  ((symbol-function 'frame-height) (lambda (&rest _) 40))
                  ((symbol-function 'delete-window)
                   (lambda (&optional w)
                     (cl-incf deleted)
                     (setq wins (assq-delete-all w wins))))
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
          (setq wins '((w-a . annotations)))   ; 模拟批注窗口已显示
          ;; 2) 显示 translate：捕获 annotations=0.5，但**不关闭**它（多 kind 共存）
          (seshat-reader-sidebar--display buf 'translate)
          (should (= deleted 0))
          (should (equal (nth 2 (assq 'annotations seshat-reader-sidebar--state))
                         0.5))
          (should (equal (car shown) 0.35))
          (setq wins '((w-a . annotations) (w-b . translate)))
          ;; 3) 再显示 annotations：同 kind 同侧 → 复用不重建，高度用记忆值 0.5
          (seshat-reader-sidebar--display buf 'annotations)
          (should (= deleted 0))
          (should (equal (car shown) 0.5))
          (should (equal (nth 2 (assq 'translate seshat-reader-sidebar--state))
                         0.5)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--same-kind-display-idempotent ()
  "同 kind 再次显示不调用 `delete-window'，并沿用该 kind 的记忆高度."
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-sidebar--state '((annotations height 0.5)))
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
        ;; `--capture-state' 按该窗口 kind 的方位取宽或高；本用例断言高度语义，
        ;; 故固定底部模式（T3 起默认位置为 `right'）。
        (seshat-reader-sidebar-position 'below-selected)
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
          (should (equal (nth 2 (assq 'annotations seshat-reader-sidebar--state)) 0.4))
          (should (eq seshat-reader-sidebar--last-buffer buf)))
      (kill-buffer buf))))

;;; 内容自适应高度（T2）

(defun seshat-reader-sidebar-test--fit-run (kind content-lines init-height
                                                 &optional etaf-runtime frame-h)
  "在桩环境下跑一次 `seshat-reader-sidebar--fit-height-for-content'.
KIND 为面板内容类型，CONTENT-LINES 为桩出的内容行数，INIT-HEIGHT 为桩出的
初始窗口总行数；ETAF-RUNTIME 非 nil 时把 `etaf-runtime-for-buffer' 桩成返回它
（模拟「buffer 已挂载 ETAF runtime」）。返回 plist：`:resizes' 为
`window-resize' 调用列表（元素 `(WINDOW DELTA)'）、`:state' 为执行后的
`seshat-reader-sidebar--state'、`:final-height' 为执行后的窗口总行数。
首行像素高（`line-pixel-height'）与 `frame-char-height' 均固定桩为 10，
`frame-height' 固定桩为 FRAME-H（省略时 50）。"
  (let* ((buf (get-buffer-create "*seshat-sidebar-test-fit*"))
         (win (selected-window))
         (orig-buffer (window-buffer win))
         (h init-height)
         (line-height 10)
         (resizes nil)
         (result nil)
         (etaf-defined (fboundp 'etaf-runtime-for-buffer))
         (etaf-original (and etaf-defined
                             (symbol-function 'etaf-runtime-for-buffer))))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (when etaf-runtime
            (fset 'etaf-runtime-for-buffer (lambda (_buffer) etaf-runtime)))
          (let ((seshat-reader-sidebar--state nil)
                ;; M12 T3 起 `seshat-reader-sidebar-position' 默认 `right'
                ;; （side window，宽度语义 → 自适应整体停用），故这组「按内容
                ;; 自适应高度」用例显式固定底部模式。
                (seshat-reader-sidebar-position 'below-selected))
            (cl-letf (((symbol-function 'line-pixel-height)
                       (lambda () line-height))
                      ((symbol-function 'frame-char-height)
                       (lambda (&rest _) line-height))
                      ((symbol-function 'window-text-pixel-size)
                       (lambda (&rest _)
                         (cons 100 (* content-lines line-height))))
                      ((symbol-function 'frame-height)
                       (lambda (&rest _) (or frame-h 50)))
                      ((symbol-function 'window-total-height)
                       (lambda (&rest _) h))
                      ((symbol-function 'window-resize)
                       (lambda (w delta &rest _)
                         (push (list w delta) resizes)
                         (cl-incf h delta))))
              (seshat-reader-sidebar--fit-height-for-content win kind))
            (setq result (list :resizes (nreverse resizes)
                               :state seshat-reader-sidebar--state
                               :final-height h))))
      (when etaf-runtime
        (if etaf-defined
            (fset 'etaf-runtime-for-buffer etaf-original)
          (fmakunbound 'etaf-runtime-for-buffer)))
      (set-window-buffer win orig-buffer)
      (kill-buffer buf))
    result))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-translate-adjusts ()
  "translate 面板按内容行数调整高度，并把最终比例写入 per-kind 记忆.
桩内容 12 行 → 目标 = 12 + 2 = 14 行；初始 20 行 → DELTA = -6，最终 14 行，
记忆比例 = 14/50 = 0.28。"
  (let* ((result (seshat-reader-sidebar-test--fit-run 'translate 12 20))
         (resizes (plist-get result :resizes))
         (win (selected-window)))
    (should (= (length resizes) 1))
    (should (eq (caar resizes) win))
    (should (= (cadar resizes) -6))
    (should (= (plist-get result :final-height) 14))
    (should (equal (nth 2 (assq 'translate (plist-get result :state)))
                   0.28))
    (should (assq 'translate (plist-get result :state)))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-clamps-max ()
  "内容超过上限时夹到 `(floor (* max-height (frame-height)))'."
  (let* ((seshat-reader-sidebar-max-height 0.8)
         (result (seshat-reader-sidebar-test--fit-run 'translate 100 20))
         (resizes (plist-get result :resizes))
         (expect (floor (* 0.8 50))))
    (should (= expect 40))
    (should (= (length resizes) 1))
    (should (= (+ 20 (cadar resizes)) expect))
    (should (= (plist-get result :final-height) expect))
    (should (equal (nth 2 (assq 'translate (plist-get result :state)))
                   (/ (float expect) 50.0)))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-clamps-min ()
  "内容极少时目标高度不低于 `seshat-reader-sidebar-min-height' × `frame-height'."
  (let* ((seshat-reader-sidebar-min-height 0.25)
         (result (seshat-reader-sidebar-test--fit-run 'translate 1 20))
         (resizes (plist-get result :resizes))
         (expect (floor (* 0.25 50))))
    (should (= expect 12))
    (should (= (length resizes) 1))
    (should (= (+ 20 (cadar resizes)) expect))
    (should (= (plist-get result :final-height) expect))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-min-height-override ()
  "下限随 `seshat-reader-sidebar-min-height' 变化：0.4 × 50 = 20 行即目标高度.
初始 20 行与目标相等，故 DELTA 为 0、不调用 `window-resize'。"
  (let* ((seshat-reader-sidebar-min-height 0.4)
         (result (seshat-reader-sidebar-test--fit-run 'translate 1 20))
         (resizes (plist-get result :resizes)))
    (should-not resizes)
    (should (= (plist-get result :final-height) 20))
    (should (equal (nth 2 (assq 'translate (plist-get result :state)))
                   0.4))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-min-over-max ()
  "下限高于上限时先夹到上限，再用至少 1 行保底（不因下限越界而超过上限）."
  (let* ((seshat-reader-sidebar-min-height 0.9)
         (seshat-reader-sidebar-max-height 0.8)
         (result (seshat-reader-sidebar-test--fit-run 'translate 1 20))
         (resizes (plist-get result :resizes))
         (expect (floor (* 0.8 50))))
    (should (= expect 40))
    (should (= (length resizes) 1))
    (should (= (plist-get result :final-height) expect))
    (should (equal (nth 2 (assq 'translate (plist-get result :state)))
                   (/ (float expect) 50.0)))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-floor-one-line ()
  "`frame-height' 极小时目标高度仍至少 1 行（`max-h' 与 `target' 双重保底）."
  (let* ((seshat-reader-sidebar-min-height 0.25)
         (seshat-reader-sidebar-max-height 0.8)
         (result (seshat-reader-sidebar-test--fit-run 'translate 0 0 nil 1))
         (resizes (plist-get result :resizes)))
    (should (= (length resizes) 1))
    (should (= (plist-get result :final-height) 1))
    (should (= (+ 0 (cadar resizes)) 1))))

(ert-deftest seshat-reader-sidebar-test--content-height-uses-min-line-height ()
  "单行像素高取「首行像素高与 `frame-char-height' 的较小值」.
桩 `line-pixel-height' 为 20（模拟 Markdown 标题行更高）、`frame-char-height'
为 10、内容像素高 6 × 20 = 120；按较小的 10 换算得 12 行——若直接用 20 则会
低估为 6 行。"
  (let* ((buf (get-buffer-create "*seshat-sidebar-test-content-height*"))
         (win (selected-window))
         (orig-buffer (window-buffer win)))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (cl-letf (((symbol-function 'line-pixel-height) (lambda () 20))
                    ((symbol-function 'frame-char-height) (lambda (&rest _) 10))
                    ((symbol-function 'frame-height) (lambda (&rest _) 50))
                    ((symbol-function 'window-text-pixel-size)
                     (lambda (&rest _) (cons 100 (* 6 20)))))
            (should (= (seshat-reader-sidebar--content-height win) 12))))
      (set-window-buffer win orig-buffer)
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-skips-annotations ()
  "kind 为 `annotations' 时面板高度不被调整、记忆不变."
  (let ((result (seshat-reader-sidebar-test--fit-run 'annotations 12 20)))
    (should-not (plist-get result :resizes))
    (should-not (plist-get result :state))
    (should (= (plist-get result :final-height) 20))))

(ert-deftest seshat-reader-sidebar-test--fit-height-for-content-skips-etaf ()
  "buffer 已挂载 ETAF runtime 时面板高度不被调整."
  (let ((result (seshat-reader-sidebar-test--fit-run
                 'translate 12 20 'fake-etaf-runtime)))
    (should-not (plist-get result :resizes))
    (should-not (plist-get result :state))))

(ert-deftest seshat-reader-sidebar-test--fit-applicable-p ()
  "两重限制判据：仅 translate 且未挂载 ETAF runtime 的 buffer 适用."
  (let ((buf (get-buffer-create "*seshat-sidebar-test-applicable*"))
        ;; 自适应只在**底部模式**下适用；T3 起默认位置是 `right'。
        (seshat-reader-sidebar-position 'below-selected)
        (etaf-defined (fboundp 'etaf-runtime-for-buffer))
        (etaf-original (and (fboundp 'etaf-runtime-for-buffer)
                            (symbol-function 'etaf-runtime-for-buffer))))
    (unwind-protect
        (progn
          (should (seshat-reader-sidebar--fit-applicable-p buf 'translate))
          (should-not (seshat-reader-sidebar--fit-applicable-p buf 'annotations))
          (should-not (seshat-reader-sidebar--fit-applicable-p buf nil))
          (fset 'etaf-runtime-for-buffer (lambda (_buffer) 'fake-runtime))
          (should-not (seshat-reader-sidebar--fit-applicable-p buf 'translate)))
      (if etaf-defined
          (fset 'etaf-runtime-for-buffer etaf-original)
        (fmakunbound 'etaf-runtime-for-buffer))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--display-calls-fit-for-translate ()
  "`--display' 显示 translate 面板后按内容调整高度，annotations 面板不调整."
  (let* ((buf (get-buffer-create "*seshat-sidebar-test-display-fit*"))
         (win (selected-window))
         (orig-buffer (window-buffer win))
         (h 20)
         (line-height 10)
         (resizes nil))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (let ((seshat-reader-sidebar--state nil)
                (seshat-reader-sidebar-position 'below-selected))
            (cl-letf (((symbol-function 'display-buffer)
                       (lambda (_buffer &optional _action) win))
                      ((symbol-function 'line-pixel-height)
                       (lambda () line-height))
                      ((symbol-function 'frame-char-height)
                       (lambda (&rest _) line-height))
                      ((symbol-function 'window-text-pixel-size)
                       (lambda (&rest _) (cons 100 (* 12 line-height))))
                      ((symbol-function 'frame-height) (lambda (&rest _) 50))
                      ((symbol-function 'window-total-height) (lambda (&rest _) h))
                      ((symbol-function 'window-resize)
                       (lambda (w delta &rest _)
                         (push (list w delta) resizes)
                         (cl-incf h delta))))
              (seshat-reader-sidebar--display buf 'translate)
              (should (= (length resizes) 1))
              (should (equal (nth 2 (assq 'translate seshat-reader-sidebar--state))
                             0.28))
              (setq resizes nil)
              (seshat-reader-sidebar--display buf 'annotations)
              (should-not resizes))))
      (set-window-buffer win orig-buffer)
      (kill-buffer buf))))

;;; 方向感知版式：left / right side window（M12 T2）

(ert-deftest seshat-reader-sidebar-test--display-params-left-side-window ()
  "`left' 时动作函数换成 `display-buffer-in-side-window'，尺寸键换成 `window-width'."
  (let ((seshat-reader-sidebar-position 'left)
        ;; 目录不在本用例的关注范围，固定到右侧，使左侧只剩信息栏 kind
        (seshat-reader-outline-sidebar-position 'right)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-outline-sidebar-width 0.20)
        (seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar--state nil)
        (params nil))
    (setq params (seshat-reader-sidebar--display-params 'annotations))
    ;; 动作函数元素只含函数名；side / slot 与 window-width 同级放在顶层 alist
    ;; （`display-buffer' 只把 `(cdr ACTION)' 整体传给动作函数）
    (should (equal (car params) '(display-buffer-in-side-window)))
    (should (eq (caar params) 'display-buffer-in-side-window))
    (should (eq (cdr (assq 'side params)) 'left))
    (should (zerop (cdr (assq 'slot params))))
    ;; 宽度语义：只带 window-width，不带 window-height
    (should (equal (cdr (assq 'window-width params)) 0.24))
    (should-not (assq 'window-height params))
    (should (equal (cdr (assq 'window-parameters params))
                   '((seshat-reader-sidebar . t)
                     (seshat-reader-sidebar-kind . annotations))))
    ;; 目录 kind 用独立的宽度默认值
    (should (equal (cdr (assq 'window-width
                              (seshat-reader-sidebar--display-params 'outline)))
                   0.20))
    ;; T3 起按 kind 分槽：同一侧内按 `--kind-order' 从 0 编号。此处侧为 `left'
    ;; 时同侧 kind 是 (outline translate)（translate 跟随全局 left）。
    (should (zerop (seshat-reader-sidebar--slot-for-kind 'outline)))
    (should (= 1 (seshat-reader-sidebar--slot-for-kind 'translate)))))

(ert-deftest seshat-reader-sidebar-test--display-params-right-side-window ()
  "`right' 时 side 为 `right'，且记忆尺寸优先于默认宽度."
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-outline-sidebar-width 0.20)
        (seshat-reader-sidebar--state '((annotations width 0.3)))
        (params nil))
    (setq params (seshat-reader-sidebar--display-params 'annotations))
    ;; 动作函数元素只含函数名；side / slot 与 window-width 同级放在顶层 alist
    (should (equal (car params) '(display-buffer-in-side-window)))
    (should (eq (caar params) 'display-buffer-in-side-window))
    (should (eq (cdr (assq 'side params)) 'right))
    (should (zerop (cdr (assq 'slot params))))
    (should (equal (cdr (assq 'window-width params)) 0.3))
    (should-not (assq 'window-height params))
    ;; 未记忆的 kind 仍回落方向默认值
    (should (equal (cdr (assq 'window-width
                              (seshat-reader-sidebar--display-params
                               'translate)))
                  0.24))))

(ert-deftest seshat-reader-sidebar-test--display-params-bottom-unaffected ()
  "底部两种位置不受左右分栏扩展影响：仍用 `window-height'、不带 side/slot."
  ;; 只断言**跟随全局位置**的 kind（`annotations' / `translate'）：`outline' 自
  ;; M12 T3 起由 `seshat-reader-outline-sidebar-position' 单独管辖，默认左侧
  ;; side window（其底部模式见 `--display-params-outline-bottom-when-configured'）。
  (dolist (case '((below-selected . display-buffer-below-selected)
                  (at-bottom . display-buffer-at-bottom)))
    (let* ((seshat-reader-sidebar-position (car case))
           (seshat-reader-sidebar-height 0.35)
           (seshat-reader-sidebar--state nil)
           (params (seshat-reader-sidebar--display-params 'annotations)))
      (should (equal (car params) (list (cdr case))))
      (should (equal (cdr (assq 'window-height params)) 0.35))
      (should-not (assq 'window-width params))
      (should-not (assq 'side params))
      (should-not (assq 'slot params)))))

(ert-deftest seshat-reader-sidebar-test--size-key-and-defaults-follow-direction ()
  "尺寸键与默认尺寸随方向切换：左右分栏用宽度、底部用高度."
  (dolist (case '((below-selected . window-height)
                  (at-bottom . window-height)
                  (left . window-width)
                  (right . window-width)))
    (let ((seshat-reader-sidebar-position (car case)))
      (should (eq (seshat-reader-sidebar--size-key) (cdr case)))
      ;; side 只有 left/right 非 nil，底部模式为 nil
      (should (eq (seshat-reader-sidebar--position-side)
                  (pcase (car case)
                    ('left 'left)
                    ('right 'right)
                    (_ nil))))))
  (let ((seshat-reader-sidebar-width 0.24)
        (seshat-reader-outline-sidebar-width 0.20)
        (seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar--state nil))
    ;; 宽度语义
    (let ((seshat-reader-sidebar-position 'right))
      (should (= (seshat-reader-sidebar--size-for-kind 'annotations) 0.24))
      (should (= (seshat-reader-sidebar--size-for-kind 'translate) 0.24))
      (should (= (seshat-reader-sidebar--size-for-kind 'outline) 0.20))
      (should (= (seshat-reader-sidebar--size-for-kind nil) 0.24)))
    ;; 高度语义：`annotations' 跟随全局位置；`outline' 要**自己**也在底部模式
    ;; 时才回落到 `seshat-reader-sidebar-height'（M12 T3 起它默认在左侧、宽度
    ;; 语义，用 `seshat-reader-outline-sidebar-width'）
    (let ((seshat-reader-sidebar-position 'below-selected))
      (should (= (seshat-reader-sidebar--size-for-kind 'annotations) 0.35))
      (should (= (seshat-reader-sidebar--size-for-kind 'outline) 0.20)))
    (let ((seshat-reader-sidebar-position 'below-selected)
          (seshat-reader-outline-sidebar-position 'below-selected))
      (should (= (seshat-reader-sidebar--size-for-kind 'outline) 0.35)))))

(ert-deftest seshat-reader-sidebar-test--window-size-ratio-direction ()
  "尺寸读写取键方向：左右分栏读宽、底部模式读高."
  (let ((win 'fake-sidebar-window))
    (cl-letf (((symbol-function 'window-total-width) (lambda (&rest _) 48))
              ((symbol-function 'window-total-height) (lambda (&rest _) 16))
              ((symbol-function 'frame-width) (lambda (&rest _) 200))
              ((symbol-function 'frame-height) (lambda (&rest _) 40)))
      (dolist (case '((left . 0.24) (right . 0.24)
                      (below-selected . 0.4) (at-bottom . 0.4)))
        (let ((seshat-reader-sidebar-position (car case)))
          (should (= (seshat-reader-sidebar--window-size-ratio win)
                     (cdr case))))))))

(ert-deftest seshat-reader-sidebar-test--capture-state-uses-width-in-side-mode ()
  "左右分栏下 `--capture-state' 记宽度比例，底部模式记高度比例."
  (let ((win 'fake-sidebar-window))
    (cl-letf (((symbol-function 'window-total-width) (lambda (&rest _) 40))
              ((symbol-function 'window-total-height) (lambda (&rest _) 16))
              ((symbol-function 'frame-width) (lambda (&rest _) 200))
              ((symbol-function 'frame-height) (lambda (&rest _) 40))
              ((symbol-function 'window-parameter)
               (lambda (_w param)
                 (pcase param
                   ('seshat-reader-sidebar t)
                   ('seshat-reader-sidebar-kind 'annotations)))))
      (let ((seshat-reader-sidebar-position 'left)
            (seshat-reader-sidebar--state nil))
        (seshat-reader-sidebar--capture-state (list win))
        (should (= (nth 2 (assq 'annotations seshat-reader-sidebar--state))
                   0.2))
        ;; 记忆条目同步记录方向：宽度语义
        (should (eq (nth 1 (assq 'annotations seshat-reader-sidebar--state))
                    'width)))
      (let ((seshat-reader-sidebar-position 'below-selected)
            (seshat-reader-sidebar--state nil))
        (seshat-reader-sidebar--capture-state (list win))
        (should (= (nth 2 (assq 'annotations seshat-reader-sidebar--state))
                   0.4))
        (should (eq (nth 1 (assq 'annotations seshat-reader-sidebar--state))
                    'height))))))

(ert-deftest seshat-reader-sidebar-test--fit-applicable-p-disabled-in-side-mode ()
  "左右分栏下停用「按内容自适应高度」，底部模式仍适用."
  (let ((buf (get-buffer-create "*seshat-sidebar-test-fit-side*")))
    (unwind-protect
        (progn
          (dolist (pos '(left right))
            (let ((seshat-reader-sidebar-position pos))
              (should-not (seshat-reader-sidebar--fit-applicable-p
                           buf 'translate))))
          (let ((seshat-reader-sidebar-position 'below-selected))
            (should (seshat-reader-sidebar--fit-applicable-p buf 'translate))))
      (kill-buffer buf))))

;;; 目录面板 buffer 名与 popper 分流（M12 T2）

(ert-deftest seshat-reader-sidebar-test--buffer-p-outline ()
  "`--buffer-p' 正则识别目录 buffer 名，且仍识别批注/译文面板名."
  (should (seshat-reader-sidebar-buffer-p "*Outline of foo.pdf*"))
  (should (seshat-reader-sidebar-buffer-p (get-buffer-create
                                           "*Outline of foo.pdf*")))
  (should (seshat-reader-sidebar-buffer-p
           seshat-reader-sidebar--annotation-buffer-name))
  (should (seshat-reader-sidebar-buffer-p
           seshat-reader-sidebar-translate-buffer-name))
  ;; 无关 buffer 与非字符串输入
  (should-not (seshat-reader-sidebar-buffer-p "*scratch*"))
  (should-not (seshat-reader-sidebar-buffer-p "*Annotations of foo*"))
  ;; 锚定：名字只是**包含**该片段不算目录面板
  (should-not (seshat-reader-sidebar-buffer-p "foo*Outline of bar*"))
  (should-not (seshat-reader-sidebar-buffer-p nil))
  (should-not (seshat-reader-sidebar-buffer-p 42)))

(ert-deftest seshat-reader-sidebar-test--kind-for-buffer-name-three-branches ()
  "popper 分流的 kind 推断三分支，且 outline 不会被误判为 annotations."
  (should (eq (seshat-reader-sidebar--kind-for-buffer-name
               seshat-reader-sidebar-translate-buffer-name)
              'translate))
  (should (eq (seshat-reader-sidebar--kind-for-buffer-name
               "*Outline of foo.pdf*")
              'outline))
  (should (eq (seshat-reader-sidebar--kind-for-buffer-name
               seshat-reader-sidebar--annotation-buffer-name)
              'annotations))
  (should (eq (seshat-reader-sidebar--kind-for-buffer-name "*whatever*")
              'annotations))
  (should (eq (seshat-reader-sidebar--kind-for-buffer-name nil) 'annotations)))

(ert-deftest seshat-reader-sidebar-test--display-buffer-outline-routes-to-outline-kind ()
  "popper 重开目录 buffer 时按 `outline' kind 与 side 参数显示."
  (let ((seshat-reader-sidebar-enabled t)
        (seshat-reader-sidebar-position 'left)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-outline-sidebar-width 0.20)
        (seshat-reader-sidebar--state nil)
        (captured nil)
        (buf (get-buffer-create "*Outline of t2.pdf*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (_b &optional _action)
                       (setq captured display-buffer-overriding-action)
                       'fake-win)))
            (should (eq (seshat-reader-sidebar-display-buffer buf nil)
                        'fake-win)))
          (should (eq (car captured) 'display-buffer-in-side-window))
          (should (eq (alist-get 'side (cdr captured)) 'left))
          (should (equal (alist-get 'window-width (cdr captured)) 0.20))
          (should (eq (alist-get 'seshat-reader-sidebar-kind
                                 (alist-get 'window-parameters (cdr captured)))
                      'outline))
          (should (eq seshat-reader-sidebar--last-kind 'outline))
          (should (eq seshat-reader-sidebar--last-buffer buf)))
      (kill-buffer buf))))

;;; per-kind 方位解析与多面板共存（M12 T3）

(ert-deftest seshat-reader-sidebar-test--position-for-kind-defaults ()
  "默认：outline → left、annotations / translate → right（全局默认 right）."
  ;; 默认值本身（破坏性变更：`seshat-reader-sidebar-position' 旧默认
  ;; `below-selected'，M12 T3 改为 `right'）
  (should (eq (default-value 'seshat-reader-sidebar-position) 'right))
  (should (eq (default-value 'seshat-reader-outline-sidebar-position) 'left))
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'left))
    (should (eq (seshat-reader-sidebar--position-for-kind 'outline) 'left))
    (should (eq (seshat-reader-sidebar--position-for-kind 'annotations) 'right))
    (should (eq (seshat-reader-sidebar--position-for-kind 'translate) 'right))
    (should (eq (seshat-reader-sidebar--position-for-kind nil) 'right))
    ;; 方向 / 侧 / 尺寸键随之按 kind 解析
    (should (seshat-reader-sidebar--horizontal-p 'outline))
    (should (eq (seshat-reader-sidebar--position-side 'outline) 'left))
    (should (eq (seshat-reader-sidebar--position-side 'annotations) 'right))
    (should (eq (seshat-reader-sidebar--size-key 'outline) 'window-width))))

(ert-deftest seshat-reader-sidebar-test--position-for-kind-custom-override ()
  "自定义目录位置覆盖其侧；未知 kind 与 nil 回落全局位置."
  ;; 目录改到右侧：与信息栏同侧（slot 依次分配，见 --slot-for-kind 用例）
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'right))
    (should (eq (seshat-reader-sidebar--position-for-kind 'outline) 'right))
    (should (eq (seshat-reader-sidebar--position-side 'outline) 'right)))
  ;; 目录放底部：只有目录回到底部模式，信息栏仍在右侧
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'at-bottom))
    (should (eq (seshat-reader-sidebar--position-for-kind 'outline) 'at-bottom))
    (should-not (seshat-reader-sidebar--position-side 'outline))
    (should-not (seshat-reader-sidebar--horizontal-p 'outline))
    (should (eq (seshat-reader-sidebar--position-side 'annotations) 'right)))
  ;; 全局改底部：信息栏跟随，目录仍按自己的变量（默认 left）
  (let ((seshat-reader-sidebar-position 'below-selected)
        (seshat-reader-outline-sidebar-position 'left))
    (should (eq (seshat-reader-sidebar--position-for-kind 'annotations)
                'below-selected))
    (should (eq (seshat-reader-sidebar--position-for-kind 'outline) 'left)))
  ;; 未知 kind 与 nil 一律回落 `seshat-reader-sidebar-position'
  (let ((seshat-reader-sidebar-position 'at-bottom)
        (seshat-reader-outline-sidebar-position 'left))
    (should (eq (seshat-reader-sidebar--position-for-kind 'unknown-kind)
                'at-bottom))
    (should (eq (seshat-reader-sidebar--position-for-kind nil) 'at-bottom))))

(ert-deftest seshat-reader-sidebar-test--slot-for-kind-per-kind-and-stable ()
  "同侧不同 kind 得到不同 slot，同 kind 稳定；不同侧各自从 0 开始."
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'left))
    (should (= (seshat-reader-sidebar--slot-for-kind 'outline) 0))
    (should (= (seshat-reader-sidebar--slot-for-kind 'annotations) 0))
    (should (= (seshat-reader-sidebar--slot-for-kind 'translate) 1))
    ;; 稳定性：重复调用结果不变
    (should (= (seshat-reader-sidebar--slot-for-kind 'translate) 1))
    (should (equal (seshat-reader-sidebar--kinds-on-side 'left) '(outline)))
    (should (equal (seshat-reader-sidebar--kinds-on-side 'right)
                   '(annotations translate))))
  ;; 目录改到右侧：右侧三个 kind 依次 0 / 1 / 2
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'right))
    (should (= (seshat-reader-sidebar--slot-for-kind 'outline) 0))
    (should (= (seshat-reader-sidebar--slot-for-kind 'annotations) 1))
    (should (= (seshat-reader-sidebar--slot-for-kind 'translate) 2)))
  ;; 未知 kind 排在已知 kind 之后，不与任何已知 kind 撞槽
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'left))
    (should (= (seshat-reader-sidebar--slot-for-kind 'unknown-kind) 2))))

(ert-deftest seshat-reader-sidebar-test--display-params-per-kind-sides ()
  "三栏共存的 action list：左目录 slot 0、右批注 slot 0、右译文 slot 1."
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'left)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-outline-sidebar-width 0.20)
        (seshat-reader-sidebar--state nil))
    (let ((outline (seshat-reader-sidebar--display-params 'outline)))
      (should (eq (caar outline) 'display-buffer-in-side-window))
      (should (eq (cdr (assq 'side outline)) 'left))
      (should (zerop (cdr (assq 'slot outline))))
      (should (equal (cdr (assq 'window-width outline)) 0.20)))
    (let ((ann (seshat-reader-sidebar--display-params 'annotations))
          (tr (seshat-reader-sidebar--display-params 'translate)))
      (should (eq (cdr (assq 'side ann)) 'right))
      (should (zerop (cdr (assq 'slot ann))))
      (should (equal (cdr (assq 'window-width ann)) 0.24))
      (should (eq (cdr (assq 'side tr)) 'right))
      (should (= 1 (cdr (assq 'slot tr))))
      (should (equal (cdr (assq 'window-width tr)) 0.24)))
    ;; per-kind 尺寸记忆互不串台：目录记 0.3 不影响信息栏
    (let ((seshat-reader-sidebar--state '((outline width 0.3))))
      (should (equal (cdr (assq 'window-width
                                (seshat-reader-sidebar--display-params
                                 'outline)))
                     0.3))
      (should (equal (cdr (assq 'window-width
                                (seshat-reader-sidebar--display-params
                                 'annotations)))
                     0.24)))))

(ert-deftest seshat-reader-sidebar-test--display-params-outline-bottom-when-configured ()
  "目录面板也支持底部模式：位置变量设为底部位时退回高度语义，信息栏不受影响."
  (dolist (case '((below-selected . display-buffer-below-selected)
                  (at-bottom . display-buffer-at-bottom)))
    (let* ((seshat-reader-sidebar-position 'right)
           (seshat-reader-outline-sidebar-position (car case))
           (seshat-reader-sidebar-height 0.35)
           (params (seshat-reader-sidebar--display-params 'outline)))
      (should (equal (car params) (list (cdr case))))
      (should (equal (cdr (assq 'window-height params)) 0.35))
      (should-not (assq 'window-width params))
      (should-not (assq 'side params))
      (should (eq (cdr (assq 'side (seshat-reader-sidebar--display-params
                                    'annotations)))
                  'right)))))

(ert-deftest seshat-reader-sidebar-test--window-for-kind-lookup ()
  "按 kind 查找既有面板窗口（判据不再是「只看第一个窗口」）."
  (cl-letf (((symbol-function 'window-parameter)
             (lambda (win param)
               (pcase param
                 ('seshat-reader-sidebar-kind
                  (cdr (assq win '((w-a . annotations) (w-b . outline)))))
                 (_ nil)))))
    (should (eq (seshat-reader-sidebar--window-for-kind 'outline '(w-a w-b))
                'w-b))
    (should (eq (seshat-reader-sidebar--window-for-kind 'annotations
                                                        '(w-a w-b))
                'w-a))
    (should-not (seshat-reader-sidebar--window-for-kind 'translate
                                                         '(w-a w-b)))
    (should-not (seshat-reader-sidebar--window-for-kind 'outline nil))))

(ert-deftest seshat-reader-sidebar-test--display-keeps-other-kinds ()
  "显示目录既不关闭也不重建已显示的批注/译文窗口."
  (let* ((seshat-reader-sidebar-position 'right)
         (seshat-reader-outline-sidebar-position 'left)
         (seshat-reader-sidebar--state nil)
         (deleted nil)
         (shown-action nil)
         (buf (get-buffer-create "*Outline of t3.pdf*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () '(w-a w-b)))
                  ((symbol-function 'window-parameter)
                   (lambda (win param)
                     (pcase param
                       ('seshat-reader-sidebar-kind
                        (cdr (assq win '((w-a . annotations)
                                         (w-b . translate)))))
                       ('window-side 'right)
                       (_ nil))))
                  ((symbol-function 'delete-window)
                   (lambda (&optional w) (push w deleted)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _)
                     (setq shown-action display-buffer-overriding-action)
                     'fake-win)))
          (seshat-reader-sidebar--display buf 'outline)
          ;; 两个既有窗口都不是 outline kind → 一个都没被关闭
          (should-not deleted)
          (should (eq (alist-get 'side (cdr shown-action)) 'left))
          (should (zerop (alist-get 'slot (cdr shown-action))))
          (should (eq (alist-get 'seshat-reader-sidebar-kind
                                 (alist-get 'window-parameters
                                            (cdr shown-action)))
                      'outline)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--display-rebuilds-target-kind-only ()
  "该 kind 的旧窗口侧已变化时只关它；其它 kind 的窗口保留."
  (let* ((seshat-reader-sidebar-position 'left)  ; 运行中从 right 改到 left
         (seshat-reader-outline-sidebar-position 'left)
         (seshat-reader-sidebar--state nil)
         (deleted nil)
         (buf (get-buffer-create "*seshat-sidebar-test-rebuild*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () '(w-a w-b)))
                  ((symbol-function 'window-parameter)
                   (lambda (win param)
                     (pcase param
                       ('seshat-reader-sidebar-kind
                        (cdr (assq win '((w-a . annotations)
                                         (w-b . translate)))))
                       ('window-side 'right)
                       (_ nil))))
                  ((symbol-function 'delete-window)
                   (lambda (&optional w) (push w deleted)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) 'fake-win)))
          (seshat-reader-sidebar--display buf 'annotations)
          ;; 只关批注窗口（侧已从 right 变 left），译文窗口保留
          (should (equal deleted '(w-a))))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-kind-closes-only-that-kind ()
  "`toggle' 带 kind 时只关闭该 kind 的窗口，并把其 buffer 记入 per-kind 记忆."
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-outline-sidebar-position 'left)
        (seshat-reader-sidebar--state nil)
        (seshat-reader-sidebar--last-buffers nil)
        (deleted nil)
        (messages nil)
        (outline-buf (get-buffer-create "*Outline of t3-toggle.pdf*")))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () '(w-a w-b)))
                  ((symbol-function 'window-parameter)
                   (lambda (win param)
                     (pcase param
                       ('seshat-reader-sidebar-kind
                        (cdr (assq win '((w-a . annotations)
                                         (w-b . outline)))))
                       ('window-side 'right)
                       (_ nil))))
                  ((symbol-function 'window-buffer)
                   (lambda (&optional _w) outline-buf))
                  ((symbol-function 'delete-window)
                   (lambda (&optional w) (push w deleted)))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (seshat-reader-sidebar-toggle 'outline)
          (should (equal deleted '(w-b)))
          (should (eq (cdr (assq 'outline seshat-reader-sidebar--last-buffers))
                      outline-buf))
          (should (cl-some (lambda (m) (string-match-p "outline" m)) messages)))
      (kill-buffer outline-buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-kind-reopens-remembered-buffer ()
  "`toggle' 带 kind 且该 kind 无窗口时用 per-kind 记忆重开（并允许跟随光标）."
  (let* ((buf (get-buffer-create "*Outline of t3-reopen.pdf*"))
         (seshat-reader-sidebar--last-buffers (list (cons 'outline buf)))
         (seshat-reader-sidebar--last-kind 'annotations)
         (seshat-reader-sidebar--last-buffer nil)
         (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                   (lambda () nil))
                  ((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (b k &optional s) (setq shown (list b k s)) 'win))
                  ((symbol-function 'message) (lambda (&rest _) nil)))
          (seshat-reader-sidebar-toggle 'outline)
          (should (eq (car shown) buf))
          (should (eq (cadr shown) 'outline))
          (should (nth 2 shown)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-outline-command-still-works ()
  "目录开合命令保留（可 M-x 调用），`o' 绑到 per-kind 的 `seshat-reader-outline-toggle'."
  ;; 2026-10-26 起 `o' 由 `seshat-reader-outline-show' 改绑 per-kind toggle 命令
  ;; （三 kind 键位统一为「已显示则关、否则开」）；目录专用命令仍保留，可 M-x 调用。
  ;; `M-o'（全部面板）由 `--meta-o-toggles-all-panels' 断言。
  (should (commandp 'seshat-reader-sidebar-toggle-outline))
  (should (eq (lookup-key seshat-reader-mode-map (kbd "o"))
              'seshat-reader-outline-toggle))
  (let ((calls nil))
    (cl-letf (((symbol-function 'seshat-reader-sidebar-toggle)
               (lambda (&optional kind) (push kind calls))))
      (seshat-reader-sidebar-toggle-outline))
    (should (equal calls '(outline)))))

(ert-deftest seshat-reader-sidebar-test--meta-o-toggles-all-panels ()
  "`M-o' 绑到无参的 `seshat-reader-sidebar-toggle'，`C-c C-o' 已解绑.
2026-10-26 起「全部面板」开合由 `C-c C-o' 换绑 `M-o'：单 kind 的开合改由各自的
键承担（`o' / `C-c C-l' / `C-c C-t' / `C-c C-e'），`C-c C-o' 让给 outline 语境
（org / outline-minor-mode 的结构操作），必须**未绑定**。"
  (should (eq (lookup-key seshat-reader-mode-map (kbd "M-o"))
              'seshat-reader-sidebar-toggle))
  (should-not (lookup-key seshat-reader-mode-map (kbd "C-c C-o")))
  ;; 同前缀的批注列表键必须指向 per-kind toggle（新增绑定不得吞掉同前缀其它键）
  (should (eq (lookup-key seshat-reader-mode-map (kbd "C-c C-l"))
              'seshat-reader-annotation-toggle)))

(ert-deftest seshat-reader-sidebar-test--panel-visible-p-detects-window ()
  "`panel-visible-p' 对**窗口**承载判已显示，参数清掉后判未显示.
用真实窗口 + `seshat-reader-sidebar-kind' window parameter（不桩替），验证判据
走的是承载单元抽象而不是某个只看窗口/只看 frame 的函数。"
  (let ((win (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter win 'seshat-reader-sidebar t)
          (set-window-parameter win 'seshat-reader-sidebar-kind 'translate)
          (should (eq t (seshat-reader-sidebar-panel-visible-p 'translate)))
          ;; 其它 kind 不受影响
          (should-not (seshat-reader-sidebar-panel-visible-p 'outline)))
      (set-window-parameter win 'seshat-reader-sidebar nil)
      (set-window-parameter win 'seshat-reader-sidebar-kind nil))
    ;; 参数清掉后无任何承载单元 → 未显示
    (should-not (seshat-reader-sidebar-panel-visible-p 'translate))))

(ert-deftest seshat-reader-sidebar-test--panel-visible-p-detects-childframe ()
  "`panel-visible-p' 对 **child frame** 承载同样判已显示（承载无关判据）.
桩替 `--panels' 返回一个 frame 单元、`--unit-kind' 按单元给出 kind，模拟
childframe 承载下「面板是 frame 而不是窗口」的情形——只看窗口的
`--window-for-kind' 在此恒为 nil，本判据不能退化成它。"
  (let ((cf (list 'fake-child-frame)))
    (cl-letf (((symbol-function 'seshat-reader-sidebar--panels)
               (lambda () (list cf)))
              ((symbol-function 'seshat-reader-sidebar--unit-kind)
               (lambda (panel) (and (eq panel cf) 'annotations))))
      (should (eq t (seshat-reader-sidebar-panel-visible-p 'annotations)))
      (should-not (seshat-reader-sidebar-panel-visible-p 'translate)))
    ;; KIND 为 nil（无 kind 语义的面板）永不算「已显示」
    (should-not (seshat-reader-sidebar-panel-visible-p nil))))

;;; 尺寸记忆的方向标签（M12 审查修复：方位切换后不得误用旧记忆值）

(ert-deftest seshat-reader-sidebar-test--size-for-kind-reuses-memory-same-direction ()
  "同方向下复用 per-kind 记忆值（左右切换仍属同一方向）。"
  (let ((seshat-reader-sidebar-width 0.24)
        (seshat-reader-outline-sidebar-width 0.20)
        (seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar--state '((annotations width 0.42))))
    ;; 左右分栏都是宽度语义 → 记忆值可用
    (dolist (pos '(left right))
      (let ((seshat-reader-sidebar-position pos))
        (should (equal (seshat-reader-sidebar--size-for-kind 'annotations)
                       0.42))
        ;; 未记忆的 kind 仍回落默认值
        (should (equal (seshat-reader-sidebar--size-for-kind 'translate)
                       0.24))))
    ;; 另一 kind 的记忆互不串台
    (let ((seshat-reader-sidebar-position 'right)
          (seshat-reader-sidebar--state '((annotations width 0.42)
                                          (outline width 0.3))))
      (should (equal (seshat-reader-sidebar--size-for-kind 'outline) 0.3))
      (should (equal (seshat-reader-sidebar--size-for-kind 'annotations) 0.42)))))

(ert-deftest seshat-reader-sidebar-test--size-for-kind-falls-back-across-directions ()
  "记忆值的方向与当前方位不符时回落方向默认值（不把宽度比例当高度用）。"
  ;; 记忆是宽度比例（记录时在 left/right），当前切到底部模式 → 用高度默认值
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-sidebar--state '((annotations width 0.9))))
    (dolist (pos '(below-selected at-bottom))
      (let ((seshat-reader-sidebar-position pos))
        (should (equal (seshat-reader-sidebar--size-for-kind 'annotations)
                       0.35))
        (should (equal (cdr (assq 'window-height
                                  (seshat-reader-sidebar--display-params
                                   'annotations)))
                       0.35))
        (should-not (assq 'window-width
                          (seshat-reader-sidebar--display-params
                           'annotations))))))
  ;; 反向：记忆是高度比例（记录时在底部模式），当前在左右分栏 → 用宽度默认值
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-sidebar--state '((annotations height 0.9))))
    (dolist (pos '(left right))
      (let ((seshat-reader-sidebar-position pos))
        (should (equal (seshat-reader-sidebar--size-for-kind 'annotations)
                       0.24))
        (should (equal (cdr (assq 'window-width
                                  (seshat-reader-sidebar--display-params
                                   'annotations)))
                       0.24))))))

(ert-deftest seshat-reader-sidebar-test--size-for-kind-tolerates-legacy-format ()
  "旧格式（二元 `(KIND . RATIO)'）按方向未知处理：回落默认值且不报错."
  (let ((seshat-reader-sidebar-height 0.35)
        (seshat-reader-sidebar-width 0.24)
        (seshat-reader-sidebar--state '((annotations . 0.9))))
    (dolist (pos '(left right below-selected at-bottom))
      (let ((seshat-reader-sidebar-position pos))
        (should (= (seshat-reader-sidebar--size-for-kind 'annotations)
                   (seshat-reader-sidebar--default-size 'annotations)))))
    ;; 畸形条目（值不是数字）同样不报错
    (let ((seshat-reader-sidebar-position 'right)
          (seshat-reader-sidebar--state '((annotations width "oops"))))
      (should (equal (seshat-reader-sidebar--size-for-kind 'annotations)
                     0.24)))))

;;; 按 kind + buffer 定向关闭面板（T3b：退出 PDF 后关闭目录面板）

(defmacro seshat-reader-sidebar-test--with-fake-panel-windows (windows-var
                                                              delete-var
                                                              &rest body)
  "在桩替窗口原语的环境中求值 BODY.
WINDOWS-VAR 绑定为 `(WINDOW KIND BUFFER)' 三元列表的列表（模拟已显示的面板），
`window-parameter' / `window-buffer' 直接从该三元列表取 KIND / BUFFER，
DELETE-VAR 收集 `delete-window' 收到的窗口名（三元列表的 `car'）。
`seshat-reader-sidebar-position' 与 `seshat-reader-outline-sidebar-position' 均
固定为 `below-selected'（高度语义、`window-total-height'/`frame-height' =
20/40），故 `--capture-state' 写入的比例恒为 0.5。「最近显示缓冲」的记忆变量一并
置空，由用例自行设置。"
  (declare (indent 2))
  `(let ((,windows-var nil)
         (,delete-var nil)
         (seshat-reader-sidebar--state nil)
         (seshat-reader-sidebar--last-buffers nil)
         (seshat-reader-sidebar--last-buffer nil)
         (seshat-reader-sidebar--last-kind nil)
         (seshat-reader-sidebar-position 'below-selected)
         (seshat-reader-outline-sidebar-position 'below-selected))
     (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
                (lambda () ,windows-var))
               ((symbol-function 'window-parameter)
                (lambda (w param)
                  (pcase param
                    ('seshat-reader-sidebar (and (consp w) t))
                    ('seshat-reader-sidebar-kind (nth 1 w))
                    ('window-side nil))))
               ((symbol-function 'window-buffer)
                (lambda (&optional w) (nth 2 w)))
               ((symbol-function 'window-total-height) (lambda (&rest _) 20))
               ((symbol-function 'window-total-width) (lambda (&rest _) 40))
               ((symbol-function 'frame-height) (lambda (&rest _) 40))
               ((symbol-function 'frame-width) (lambda (&rest _) 100))
               ((symbol-function 'delete-window)
                (lambda (&optional w) (push (car-safe w) ,delete-var))))
       ,@body)))

(ert-deftest seshat-reader-sidebar-test--close-buffer-kind-matches-kind-and-buffer ()
  "只删除 kind 与 buffer 都匹配的面板窗口，并清掉该 kind 的死面板记忆."
  (let ((outline-panel (get-buffer-create "*Outline of doc.pdf*"))
        (outline-other (get-buffer-create "*Outline of other.pdf*"))
        (ann-panel (get-buffer-create "*Seshat Annotations*")))
    (unwind-protect
        (seshat-reader-sidebar-test--with-fake-panel-windows windows delete-calls
          (setq windows (list (list 'w-outline 'outline outline-panel)
                              (list 'w-other 'outline outline-other)
                              (list 'w-ann 'annotations ann-panel))
                seshat-reader-sidebar--last-buffers
                (list (cons 'outline outline-panel)
                      (cons 'annotations ann-panel))
                seshat-reader-sidebar--last-buffer outline-panel
                seshat-reader-sidebar--last-kind 'outline)
          (seshat-reader-sidebar-close-buffer-kind 'outline outline-panel)
          ;; ① 只删「kind=outline 且显示该面板 buffer」的那一个窗口
          (should (equal delete-calls '(w-outline)))
          ;; ② 删除前先捕获尺寸（用户手动 resize 的记忆不丢）
          (should (equal (nth 2 (assq 'outline seshat-reader-sidebar--state))
                         0.5))
          ;; ③ 目录开合命令的死面板记忆被清掉：outline 条目消失，annotations 保留
          (should-not (assq 'outline seshat-reader-sidebar--last-buffers))
          (should (eq (cdr (assq 'annotations
                                 seshat-reader-sidebar--last-buffers))
                      ann-panel))
          (should-not seshat-reader-sidebar--last-buffer)
          (should-not seshat-reader-sidebar--last-kind))
      (dolist (buf (list outline-panel outline-other ann-panel))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest seshat-reader-sidebar-test--close-buffer-kind-requires-both-matches ()
  "kind 或 buffer 不匹配时零删除，且不动任何记忆."
  (let ((outline-panel (get-buffer-create "*Outline of doc.pdf*"))
        (ann-panel (get-buffer-create "*Seshat Annotations*")))
    (unwind-protect
        (seshat-reader-sidebar-test--with-fake-panel-windows windows delete-calls
          (setq windows (list (list 'w-outline 'outline outline-panel)
                              (list 'w-ann 'annotations ann-panel))
                seshat-reader-sidebar--last-buffers
                (list (cons 'outline outline-panel)))
          ;; ① buffer 匹配但 kind 不同
          (seshat-reader-sidebar-close-buffer-kind 'annotations outline-panel)
          ;; ② kind 匹配但 buffer 不同
          (seshat-reader-sidebar-close-buffer-kind 'outline ann-panel)
          ;; ③ 根本没有该 kind 的窗口
          (seshat-reader-sidebar-close-buffer-kind 'translate outline-panel)
          (should-not delete-calls)
          (should (eq (cdr (assq 'outline seshat-reader-sidebar--last-buffers))
                      outline-panel)))
      (dolist (buf (list outline-panel ann-panel))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest seshat-reader-sidebar-test--close-buffer-kind-ignores-dead-buffer ()
  "BUFFER 已死（对象或名字）时零删除：原语在窗口遍历之前就返回."
  (let* ((dead (generate-new-buffer " *seshat-sidebar-dead*"))
         (dead-name (buffer-name dead)))
    ;; 在桩环境之外 kill，避免 `replace-buffer-in-windows' 撞上被桩替的窗口原语
    (kill-buffer dead)
    (seshat-reader-sidebar-test--with-fake-panel-windows windows delete-calls
      ;; 窗口仍记着这个已死的 buffer：若没有早期返回就会命中并删除
      (setq windows (list (list 'w-dead 'outline dead)))
      (seshat-reader-sidebar-close-buffer-kind 'outline dead)
      (seshat-reader-sidebar-close-buffer-kind 'outline dead-name)
      (should-not delete-calls))))

;;; 承载分派（window vs childframe）

(defun seshat-reader-sidebar-test--graphic-p (value)
  "把 `display-graphic-p' 桩成恒返回 VALUE 的 thunk，供 carrier 解析用例复用.
batch 与终端 frame 下真实 `display-graphic-p' 恒为 nil，不桩替就无法断言「图形
终端下的解析结果」。"
  (lambda (&optional _display) value))

(ert-deftest seshat-reader-sidebar-test--default-carrier-is-window ()
  "`seshat-reader-panel-carrier' 的**定义默认值**为 `window'，且各 kind 实际解析为窗口承载.
默认值读 `standard-value' 而非 `default-value'：后者会被运行时 `setq' /
`set-default' 改写，断言会随用户配置漂移；本用例要钉的是 defcustom 里写死的
那个默认。选 `window' 的理由是 childframe 满高时无法避让 frame 底部的
minibuffer 与 `*Completions*'（不在窗口树内），会遮挡候选列表与回显。
`translate' 单列一条，是因为 M12 T8a 时期它走 childframe——默认切换后它必须回到
窗口承载（右侧 side window）。"
  (should (eq (eval (car (get 'seshat-reader-panel-carrier 'standard-value)))
              'window))
  (cl-letf (((symbol-function 'display-graphic-p)
             (seshat-reader-sidebar-test--graphic-p t)))
    (should (eq (seshat-reader-sidebar--carrier-for-kind 'translate) 'window))
    (should (eq (seshat-reader-sidebar--carrier-for-kind 'outline) 'window))
    (should (eq (seshat-reader-sidebar--carrier-for-kind 'annotations)
                'window))
    ;; 未在 alist 中的未知 kind 走全局默认（不是回退，也不是报错）
    (should (eq (seshat-reader-sidebar--carrier-for-kind 'unknown) 'window))))

(ert-deftest seshat-reader-sidebar-test--default-sidebar-width ()
  "`seshat-reader-sidebar-width' 的**定义默认值**为 0.25（占 frame 宽度比例）.
同样读 `standard-value'：断言 defcustom 默认，不受运行时改写影响。该值只在
side window 承载下生效，childframe 承载改用 `seshat-reader-panel-width'。"
  (should (= (eval (car (get 'seshat-reader-sidebar-width 'standard-value)))
             0.25))
  ;; 宽度语义下 `--default-size' 直接取该默认值（信息栏两类 kind 都是它）
  (let ((seshat-reader-sidebar-position 'right)
        (seshat-reader-sidebar--state nil))
    (should (= (seshat-reader-sidebar--size-for-kind 'translate)
               (eval (car (get 'seshat-reader-sidebar-width
                               'standard-value)))))))

(ert-deftest seshat-reader-sidebar-test--carrier-for-kind-global-window ()
  "全局 carrier 设为 `window' 后，alist 未覆盖的 kind 全部回落窗口承载.
这是计划里的完整回退开关：`(setq seshat-reader-panel-carrier \\='window)'
只影响未被 alist 逐 kind 覆盖的 kind；批注列表本来就覆盖为 `window'，两项
结果一致，说明回退路径与默认路径收敛到同一后端。"
  (let ((seshat-reader-panel-carrier 'window))
    (cl-letf (((symbol-function 'display-graphic-p)
               (seshat-reader-sidebar-test--graphic-p t)))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'outline) 'window))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'translate)
                  'window))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'annotations)
                  'window)))))

(ert-deftest seshat-reader-sidebar-test--carrier-for-kind-non-graphic-fallback ()
  "非图形终端（`display-graphic-p' 为 nil）强制回退 `window'，与配置无关.
两个来源都验：全局 carrier 设为 `childframe' 时 outline 仍是 `window'；即便
alist 把该 kind 覆盖成 `childframe' 也一样——终端里 child frame 永远不显示，
返回值只能是窗口承载。"
  (let ((seshat-reader-panel-carrier 'childframe)
        (seshat-reader-panel-carrier-alist '((outline . childframe))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (seshat-reader-sidebar-test--graphic-p nil)))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'outline) 'window))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'translate)
                  'window)))))

(ert-deftest seshat-reader-sidebar-test--carrier-for-kind-invalid-falls-back ()
  "非法 carrier 取值静默回落 `window'，不取 nil、不报错、不发 message.
全局值与 alist 覆盖值两条路径都要回落：配置写错时最坏结果是回到既有窗口承载
（必然可用），而不是让上层拿到一个非法符号去建不存在的承载单元。同时断言
全程无 `message' 调用——回落是静默的，避免每次显示/刷新都刷警告。"
  (let ((messages 0))
    (cl-letf (((symbol-function 'display-graphic-p)
               (seshat-reader-sidebar-test--graphic-p t))
              ((symbol-function 'message)
               (lambda (&rest _) (setq messages (1+ messages)))))
      (let ((seshat-reader-panel-carrier 'bogus))
        (should (eq (seshat-reader-sidebar--carrier-for-kind 'outline) 'window)))
      (let ((seshat-reader-panel-carrier-alist '((translate . bogus))))
        (should (eq (seshat-reader-sidebar--carrier-for-kind 'translate)
                    'window)))
      (should (zerop messages)))))

(ert-deftest seshat-reader-sidebar-test--carrier-for-kind-alist-overrides-window ()
  "全局为 `window' 时 alist 仍可把单个 kind 覆盖为 `childframe'.
覆盖优先级高于全局默认（三层解析的第 2 层）：默认全局值本身已是 `window'，本
用例把它固定住再逐 kind 改成 `childframe'，说明 alist 是**双向覆盖**而非单向
降级——想只让译文走浮层不必改全局值。"
  (let ((seshat-reader-panel-carrier 'window)
        (seshat-reader-panel-carrier-alist '((outline . childframe))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (seshat-reader-sidebar-test--graphic-p t)))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'outline)
                  'childframe))
      (should (eq (seshat-reader-sidebar--carrier-for-kind 'annotations)
                  'window)))))

;;; 承载单元访问器（window 后端；frame 后端的访问器同时用桩对象覆盖）

(ert-deftest seshat-reader-sidebar-test--panels-window-backend ()
  "`--panels' 在 frame 后端无面板时与 `--windows' 完全一致.
这是旧行为不回归的判据：childframe 后端接入后，只要当前没有本包 child frame，
上层经 `--panels' 得到的仍是「本包面板窗口」这一既有语义与顺序。"
  (let ((panels (list 'w-outline 'w-annotations)))
    (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
               (lambda () panels))
              ((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () nil)))
      (should (equal (seshat-reader-sidebar--panels) panels)))))

(ert-deftest seshat-reader-sidebar-test--panel-kind-window-and-frame ()
  "`--panel-kind' 对窗口读 window parameter，对 frame 读 frame parameter.
两类承载单元的 kind 标记名不同（`seshat-reader-sidebar-kind' /
`seshat-reader-panel-kind'），访问器必须按类型选对来源；既非窗口也非 frame
的对象返回 nil，而不是报错。"
  (cl-letf (((symbol-function 'window-parameter)
             (lambda (_win param)
               (when (eq param 'seshat-reader-sidebar-kind) 'translate)))
            ((symbol-function 'frame-parameter)
             (lambda (_frame param)
               (when (eq param 'seshat-reader-panel-kind) 'outline)))
            ((symbol-function 'windowp) (lambda (obj) (eq obj 'fake-window)))
            ((symbol-function 'framep) (lambda (obj) (eq obj 'fake-frame))))
    (should (eq (seshat-reader-sidebar--panel-kind 'fake-window) 'translate))
    (should (eq (seshat-reader-sidebar--panel-kind 'fake-frame) 'outline))
    (should-not (seshat-reader-sidebar--panel-kind 'unknown-object))))

(ert-deftest seshat-reader-sidebar-test--panel-buffer-window-and-frame ()
  "`--panel-buffer' 窗口取窗口 buffer，frame 取选中窗口 buffer；死 frame 返回 nil.
`(window-buffer nil)' 的语义是「当前选中窗口」，故 frame 无选中窗口时必须
显式返回 nil——放任 nil 透传会把不相干 buffer 当成面板内容（这是本用例要锁死
的坑）。"
  (let ((buf (get-buffer-create " *seshat-sidebar-panel-buffer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'window-buffer)
                   (lambda (&optional win)
                     (if (memq win '(fake-window frame-window)) buf nil)))
                  ((symbol-function 'windowp)
                   (lambda (obj) (memq obj '(fake-window frame-window))))
                  ((symbol-function 'framep)
                   (lambda (obj) (memq obj '(fake-frame dead-frame))))
                  ((symbol-function 'frame-live-p)
                   (lambda (frame) (not (eq frame 'dead-frame))))
                  ((symbol-function 'frame-selected-window)
                   (lambda (frame) (if (eq frame 'fake-frame) 'frame-window nil))))
          (should (eq (seshat-reader-sidebar--panel-buffer 'fake-window) buf))
          (should (eq (seshat-reader-sidebar--panel-buffer 'fake-frame) buf))
          ;; frame 无选中窗口 → nil，而不是回落当前选中窗口
          (let ((selected (current-buffer)))
            (should-not (eq (seshat-reader-sidebar--panel-buffer
                             'frame-without-selected-window)
                            selected)))
          ;; 死 frame → nil
          (should-not (seshat-reader-sidebar--panel-buffer 'dead-frame)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--panel-for-kind-and-close ()
  "`--panel-for-kind' 按 kind 取第一个单元，`--panel-close' 按类型选关闭原语.
关闭路径是要点：窗口走 `delete-window'、frame 走 `delete-frame'，两者混用会
要么删错对象、要么对 frame 调 `delete-window' 报错；`--panel-close' 必须按
类型分流且吞掉「已被用户手工关掉」的错误。"
  (let (delete-window-calls delete-frame-calls)
    (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
               (lambda () (list 'w-ann 'w-tr)))
              ((symbol-function 'windowp)
               (lambda (obj) (memq obj '(w-ann w-tr))))
              ((symbol-function 'window-parameter)
               (lambda (win param)
                 (when (eq param 'seshat-reader-sidebar-kind)
                   (pcase win ('w-ann 'annotations) ('w-tr 'translate)))))
              ((symbol-function 'framep) (lambda (obj) (eq obj 'fake-frame)))
              ((symbol-function 'delete-window)
               (lambda (win) (push win delete-window-calls)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (push frame delete-frame-calls))))
      ;; 按 kind 命中第一个匹配单元；不存在的 kind 返回 nil
      (should (eq (seshat-reader-sidebar--panel-for-kind 'translate) 'w-tr))
      (should (eq (seshat-reader-sidebar--panel-for-kind 'annotations) 'w-ann))
      (should-not (seshat-reader-sidebar--panel-for-kind 'outline))
      ;; 显式传 PANELS 时不读 `--panels'（该单元里没有 translate）
      (should-not (seshat-reader-sidebar--panel-for-kind 'translate '(w-ann)))
      (seshat-reader-sidebar--panel-close 'w-tr)
      (seshat-reader-sidebar--panel-close 'fake-frame)
      ;; 既非窗口也非 frame：两种原语都不调用
      (seshat-reader-sidebar--panel-close 'unknown-object)
      (should (equal delete-window-calls '(w-tr)))
      (should (equal delete-frame-calls '(fake-frame))))))

;;; childframe 后端：几何纯函数、frame 过滤与幂等复用

(ert-deftest seshat-reader-sidebar-test--cf-parameters-required-keys ()
  "child frame parameters 必含约定项，且**不含** `no-accept-focus'.
`no-accept-focus' 会让面板连点击都无法聚焦，从而不能滚动、不能选文本复制，
是本方案明确排除的取值——出现即视为回归。`name' 也不得出现在参数里：GUI frame
的 name 随 buffer 名变化（目录 buffer 名还带源文件名），不能作「本包面板」的
标识，标识一律用 `seshat-reader-panel-kind'。

本用例是纯函数断言：batch 下父 frame 取不到像素尺寸，宽高退化为字符占位值，不
影响被测参数（这正是把几何计算与 frame 创建分开的目的）。"
  (let ((params (seshat-reader-sidebar--cf-parameters
                 'fake-parent 'translate)))
    (should (equal (cdr (assq 'parent-frame params)) 'fake-parent))
    (should (eq (cdr (assq 'undecorated params)) t))
    (should (eq (cdr (assq 'no-focus-on-map params)) t))
    (should (eq (cdr (assq 'no-other-frame params)) t))
    (should (eq (cdr (assq 'no-delete-other-frames params)) t))
    (should (equal (cdr (assq 'internal-border-width params)) 8))
    (should (eq (cdr (assq 'seshat-reader-panel-kind params)) 'translate))
    ;; 明确排除的参数
    (should-not (assq 'no-accept-focus params))
    (should-not (assq 'name params))
    ;; 背景色必须是字符串（取不到 default face 时回退 #ffffff）
    (should (stringp (cdr (assq 'background-color params))))
    ;; 初始字符尺寸至少 1，供 `display-buffer-in-child-frame' 建 frame
    (should (>= (cdr (assq 'width params)) 1))
    (should (>= (cdr (assq 'height params)) 1))))

(ert-deftest seshat-reader-sidebar-test--cf-size-ratio-and-invalid-parent ()
  "像素尺寸 = 父 frame 像素尺寸 × 比例；父尺寸异常时返回 nil.
1000 × 800 的父 frame 按默认宽度比例 0.25 得宽 250；高度默认**满高**
（`seshat-reader-panel-full-height' 为 t）→ 800 − 2×16 = 768。返回 nil 而非
(0 . 0) 是要点：调用方靠 nil 判定「本环境建不出 child frame」，返回 0 尺寸会
让它去建一个不可见的 frame。"
  (let ((seshat-reader-panel-margin 16))
    (cl-letf (((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1000))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800)))
      (should (equal (seshat-reader-sidebar--cf-size 'parent 'translate)
                     '(250 . 768)))
      ;; 比例可配置，且与 kind 无关（kind 目前只作签名占位）；关掉满高才走
      ;; `seshat-reader-panel-height' 的比例路径。800×0.25 = 200 低于「父高
      ;; 30%」保底 240，故高度被夹到 240（见 `--cf-size-for-side'）。
      (let ((seshat-reader-panel-width 0.5)
            (seshat-reader-panel-height 0.25)
            (seshat-reader-panel-full-height nil))
        (should (equal (seshat-reader-sidebar--cf-size 'parent 'outline)
                       '(500 . 240))))
      ;; 父尺寸非数值 / 非正 → nil
      (cl-letf (((symbol-function 'frame-pixel-width)
                 (lambda (&optional _frame) nil)))
        (should-not (seshat-reader-sidebar--cf-size 'parent 'translate)))
      (cl-letf (((symbol-function 'frame-pixel-height)
                 (lambda (&optional _frame) 0)))
        (should-not (seshat-reader-sidebar--cf-size 'parent 'translate))))))

;;; 面板贴边（左右侧）、满高与同侧堆叠

(ert-deftest seshat-reader-sidebar-test--panel-side-for-kind-defaults ()
  "默认配置下目录贴左、译文/解释贴右（`seshat-reader-panel-position-alist'）."
  (should (eq (seshat-reader-sidebar--panel-side-for-kind 'outline) 'left))
  (should (eq (seshat-reader-sidebar--panel-side-for-kind 'translate) 'right))
  ;; alist 可自定义：改表即改侧，不必动 kind 逻辑
  (let ((seshat-reader-panel-position-alist '((outline . right)
                                             (translate . left))))
    (should (eq (seshat-reader-sidebar--panel-side-for-kind 'outline) 'right))
    (should (eq (seshat-reader-sidebar--panel-side-for-kind 'translate) 'left))))

(ert-deftest seshat-reader-sidebar-test--panel-side-for-kind-fallback ()
  "未命中 alist 的 kind 回落到 `seshat-reader-sidebar-position'.
取 `left' 时得 `left'；取底部模式（`below-selected' / `at-bottom'，以及规范中
举例的 `bottom`）这类**非左右**取值时按 `right' 处理——child frame 是覆盖浮层，
没有「底部」概念。"
  (let ((seshat-reader-panel-position-alist nil))
    (let ((seshat-reader-sidebar-position 'left))
      (should (eq (seshat-reader-sidebar--panel-side-for-kind 'annotations) 'left)))
    (let ((seshat-reader-sidebar-position 'below-selected))
      (should (eq (seshat-reader-sidebar--panel-side-for-kind 'annotations) 'right)))
    (let ((seshat-reader-sidebar-position 'bottom))
      (should (eq (seshat-reader-sidebar--panel-side-for-kind 'unknown-kind) 'right)))
    (let ((seshat-reader-sidebar-position 'right))
      (should (eq (seshat-reader-sidebar--panel-side-for-kind nil) 'right)))))

(ert-deftest seshat-reader-sidebar-test--cf-position-for-side-left-and-right ()
  "`--cf-position-for-side' 贴左边时 LEFT=margin、贴右边时 LEFT=父宽−面板宽−margin.
父宽 1200 / 面板宽 300 / margin 16：左 → LEFT 16，右 → 1200−300−16 = 884；
无同侧已有面板时 TOP = margin = 16。"
  (should (equal (seshat-reader-sidebar--cf-position-for-side
                  1200 300 16 'left nil)
                 '(16 . 16)))
  (should (equal (seshat-reader-sidebar--cf-position-for-side
                  1200 300 16 'right nil)
                 '(884 . 16))))

(ert-deftest seshat-reader-sidebar-test--cf-position-for-side-stacking ()
  "同侧已有面板把 TOP 往下推「该面板高度 + margin」，空表等同 nil."
  (should (equal (seshat-reader-sidebar--cf-position-for-side
                  1200 300 16 'left '(400))
                 '(16 . 432)))
  ;; 两个同侧面板：16 + (300+16) + (200+16)
  (should (equal (seshat-reader-sidebar--cf-position-for-side
                  1200 300 16 'right '(300 200))
                 '(884 . 548)))
  (should (equal (seshat-reader-sidebar--cf-position-for-side
                  1200 300 16 'left '())
                 '(16 . 16)))
  ;; 非数值 / 非正项不占位（调用方可能从 `frame-pixel-height' 拿到 nil）
  (should (equal (seshat-reader-sidebar--cf-position-for-side
                  1200 300 16 'left '(nil 0 -5))
                 '(16 . 16))))

(ert-deftest seshat-reader-sidebar-test--cf-position-for-side-invalid-args ()
  "参数异常（nil / 非正数 / 非法 side）时 `--cf-position-for-side' 返回 nil."
  (should-not (seshat-reader-sidebar--cf-position-for-side
               nil 300 16 'left nil))
  (should-not (seshat-reader-sidebar--cf-position-for-side
               0 300 16 'left nil))
  (should-not (seshat-reader-sidebar--cf-position-for-side
               1200 nil 16 'left nil))
  (should-not (seshat-reader-sidebar--cf-position-for-side
               1200 0 16 'right nil))
  (should-not (seshat-reader-sidebar--cf-position-for-side
               1200 300 nil 'left nil))
  (should-not (seshat-reader-sidebar--cf-position-for-side
               1200 300 -1 'left nil))
  (should-not (seshat-reader-sidebar--cf-position-for-side
               1200 300 16 'bottom nil)))

(ert-deftest seshat-reader-sidebar-test--cf-size-for-side-full-height ()
  "满高时高度 = 父高 − 2×margin，与 `seshat-reader-panel-height' 无关."
  (let ((seshat-reader-panel-width 0.25)
        (seshat-reader-panel-height 0.45)
        (seshat-reader-panel-margin 16)
        (seshat-reader-panel-full-height t))
    (cl-letf (((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1200))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800)))
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate nil)
                     '(300 . 768)))
      ;; 换高度比例不影响满高结果
      (let ((seshat-reader-panel-height 0.1))
        (should (equal (seshat-reader-sidebar--cf-size-for-side
                        'parent 'translate nil)
                       '(300 . 768)))))))

(ert-deftest seshat-reader-sidebar-test--cf-size-for-side-subtracts-existing ()
  "同侧已有面板时从可用高度里扣掉其高度（含 margin），且不低于父高 30%."
  (let ((seshat-reader-panel-width 0.25)
        (seshat-reader-panel-margin 16)
        (seshat-reader-panel-full-height t))
    (cl-letf (((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1200))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800)))
      ;; 768 − (400 + 16) = 352
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate '(400))
                     '(300 . 352)))
      ;; 挤压过度：768 − (700+16) = 52 < 30%×800=240 → 取 240（允许超出）
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate '(700))
                     '(300 . 240)))
      ;; 非数值 / 非正项不扣减
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate '(nil 0))
                     '(300 . 768))))))

(ert-deftest seshat-reader-sidebar-test--cf-size-for-side-ratio-when-not-full ()
  "`seshat-reader-panel-full-height' 为 nil 时按 `seshat-reader-panel-height' 比例."
  (let ((seshat-reader-panel-width 0.25)
        (seshat-reader-panel-height 0.45)
        (seshat-reader-panel-margin 16)
        (seshat-reader-panel-full-height nil))
    (cl-letf (((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1200))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800)))
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate nil)
                     '(300 . 360)))
      ;; 同侧已有面板同样扣减：360 − (100+16) = 244 ≥ 240
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate '(100))
                     '(300 . 244)))
      ;; 扣到低于 30% 时仍保底 240
      (should (equal (seshat-reader-sidebar--cf-size-for-side
                      'parent 'translate '(300))
                     '(300 . 240))))))

(ert-deftest seshat-reader-sidebar-test--cf-position-uses-side-from-alist ()
  "`--cf-position' 薄包装按 kind 的侧定位：目录在左、译文在右."
  (let ((seshat-reader-panel-width 0.25)
        (seshat-reader-panel-margin 16)
        (seshat-reader-panel-full-height t))
    (cl-letf (((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1200))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800)))
      (should (equal (seshat-reader-sidebar--cf-position 'parent 'outline nil)
                     '(16 . 16)))
      (should (equal (seshat-reader-sidebar--cf-position 'parent 'translate nil)
                     '(884 . 16))))))

(ert-deftest seshat-reader-sidebar-test--cf-position-right-edge-and-stacking ()
  "面板贴父 frame 右边缘、多面板纵向堆叠时按「高度 + margin」逐层下移.
公式（与 `seshat-reader-sidebar--cf-position' 的 docstring 一致）：

  LEFT = 父宽 - 面板宽 - margin
  TOP  = margin + Σ(已存在面板高度 + margin)

父宽 1000、面板宽 340、margin 16 → LEFT 644；无其它面板时 TOP 16；已有高度
300 / 200 两个面板时 TOP = 16 + 300 + 16 + 200 + 16 = 548（正是「后者不遮挡
前者」的要求）。"
  (let ((seshat-reader-panel-width 0.34)
        (seshat-reader-panel-height 0.45)
        (seshat-reader-panel-margin 16))
    (cl-letf (((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1000))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800)))
      ;; 唯一面板：贴右上角
      (should (equal (seshat-reader-sidebar--cf-position
                      'parent 'translate nil)
                     '(644 . 16)))
      ;; 已有两个面板 → 堆叠
      (should (equal (seshat-reader-sidebar--cf-position
                      'parent 'translate '(300 200))
                     '(644 . 548)))
      ;; 空表等同于 nil
      (should (equal (seshat-reader-sidebar--cf-position
                      'parent 'translate '())
                     '(644 . 16)))
      ;; 非法高度项不占位（调用方可能从 `frame-pixel-height' 拿到 nil）
      (should (equal (seshat-reader-sidebar--cf-position
                      'parent 'translate '(nil 0))
                     '(644 . 16)))
      ;; 父尺寸异常 → nil（调用方跳过定位）
      (cl-letf (((symbol-function 'frame-pixel-width)
                 (lambda (&optional _frame) nil)))
        (should-not (seshat-reader-sidebar--cf-position
                     'parent 'translate nil))))))

(ert-deftest seshat-reader-sidebar-test--cf-frames-filter-and-lookup ()
  "`--cf-frames' 只保留带 kind 参数的活 frame，`--cf-frame-for-kind' 按 kind 命中.
过滤判据是**自有 frame parameter**（`seshat-reader-panel-kind'）而不是 frame
的 `name'：name 随 buffer 名变化，用它当标识会在面板换内容后失配。已死 frame
必须排除——`delete-frame' 之后对象可能仍留在 `frame-list' 的残余里，误当成
「面板已显示」会让显示路径永远走幂等复用、内容再也不刷新。"
  (cl-letf (((symbol-function 'frame-list)
             (lambda () '(cf-outline cf-translate other dead-cf)))
            ((symbol-function 'frame-live-p)
             (lambda (frame) (not (eq frame 'dead-cf))))
            ((symbol-function 'frame-parameter)
             (lambda (frame param)
               (when (eq param 'seshat-reader-panel-kind)
                 (pcase frame
                   ('cf-outline 'outline)
                   ('cf-translate 'translate)
                   ('dead-cf 'translate))))))
    (should (equal (seshat-reader-sidebar--cf-frames)
                   '(cf-outline cf-translate)))
    (should (eq (seshat-reader-sidebar--cf-frame-for-kind 'translate)
                'cf-translate))
    (should (eq (seshat-reader-sidebar--cf-frame-for-kind 'outline)
                'cf-outline))
    ;; 该 kind 没有面板 → nil（走创建路径）
    (should-not (seshat-reader-sidebar--cf-frame-for-kind 'annotations))
    ;; 显式传 FRAMES 时不读 `--cf-frames'
    (should (eq (seshat-reader-sidebar--cf-frame-for-kind
                 'translate '(cf-translate))
                'cf-translate))
    (should-not (seshat-reader-sidebar--cf-frame-for-kind
                 'outline '(cf-translate)))))

(ert-deftest seshat-reader-sidebar-test--cf-show-reuses-existing-frame ()
  "同 kind 的 child frame 已存在时只换 buffer 并重新定位，**不**重建 frame.
幂等是面板能承受流式刷新的前提：每次增量都重建 frame 会闪烁，并丢掉滚动位置
与面板内的 point。判据即 `display-buffer' 调用 0 次、`set-window-buffer'
1 次。"
  (let ((buf (get-buffer-create " *seshat-cf-reuse*"))
        (display-calls 0)
        set-buffer-calls placed)
    (unwind-protect
        (cl-letf (((symbol-function 'selected-frame) (lambda () 'gui-frame))
                  ((symbol-function 'display-graphic-p)
                   (lambda (&optional _frame) t))
                  ((symbol-function 'seshat-reader-sidebar--cf-frame-for-kind)
                   (lambda (_kind) 'cf-translate))
                  ((symbol-function 'frame-live-p) (lambda (_frame) t))
                  ((symbol-function 'frame-selected-window)
                   (lambda (_frame) 'cf-window))
                  ((symbol-function 'windowp)
                   (lambda (obj) (eq obj 'cf-window)))
                  ((symbol-function 'set-window-buffer)
                   (lambda (window buffer)
                     (push (cons window buffer) set-buffer-calls)))
                  ((symbol-function 'seshat-reader-sidebar--cf-place)
                   (lambda (frame kind) (push (cons frame kind) placed)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _)
                     (setq display-calls (1+ display-calls))
                     'never-window)))
          (should (eq (seshat-reader-sidebar--cf-show buf 'translate)
                      'cf-window))
          (should (zerop display-calls))
          (should (equal set-buffer-calls (list (cons 'cf-window buf))))
          (should (equal placed '((cf-translate . translate)))))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--cf-show-creates-frame-with-dotted-action ()
  "创建路径：ACTION 必须是**点对** `(FUNC . ALIST)'，并按像素收口尺寸与位置.
嵌套列表 `((display-buffer-in-child-frame (child-frame-parameters ...)))' 会让
`display-buffer' 收到的 ALIST 变成 nil、child frame 参数全丢（frame 只用默认
参数建出来）——这是本用例锁死的不变量：car 必须是动作函数符号，cdr 必须是含
`child-frame-parameters' 的 alist。

尺寸与位置必须走像素级接口：`set-frame-size' 带 PIXELWISE 非 nil，尺寸等于
「父 frame 像素 × 比例」，位置走 `set-frame-position'（frame parameters 的
width/height 是字符单位，无法精确等于像素比例）。"
  (let ((buf (get-buffer-create " *seshat-cf-create*"))
        captured-action sized positioned)
    (unwind-protect
        (cl-letf (((symbol-function 'selected-frame) (lambda () 'gui-frame))
                  ((symbol-function 'display-graphic-p)
                   (lambda (&optional _frame) t))
                  ((symbol-function 'seshat-reader-sidebar--cf-frame-for-kind)
                   (lambda (_kind) nil))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _)
                     (setq captured-action display-buffer-overriding-action)
                     'cf-window))
                  ((symbol-function 'windowp)
                   (lambda (obj) (eq obj 'cf-window)))
                  ((symbol-function 'window-frame) (lambda (_window) 'cf-new))
                  ((symbol-function 'frame-parameter)
                   (lambda (frame param)
                     (cond ((and (eq frame 'cf-new)
                                 (eq param 'parent-frame))
                            'gui-frame)
                           ;; `--cf-place' 先验证本包 kind 参数（防御），故桩必须
                           ;; 给出非 nil kind，否则尺寸/定位收口被整体跳过
                           ((eq param 'seshat-reader-panel-kind) 'translate))))
                  ((symbol-function 'seshat-reader-sidebar--cf-frames)
                   (lambda () nil))
                  ((symbol-function 'frame-pixel-width)
                   (lambda (&optional _frame) 1000))
                  ((symbol-function 'frame-pixel-height)
                   (lambda (&optional _frame) 800))
                  ((symbol-function 'set-frame-size)
                   (lambda (frame width height &optional pixelwise)
                     (push (list frame width height pixelwise) sized)))
                  ((symbol-function 'set-frame-position)
                   (lambda (frame left top)
                     (push (list frame left top) positioned))))
          (should (eq (seshat-reader-sidebar--cf-show buf 'translate)
                      'cf-window))
          ;; ACTION 是点对：car 为动作函数，cdr 为 alist
          (should (eq (car captured-action) 'display-buffer-in-child-frame))
          (should (consp (cdr captured-action)))
          (should (assq 'child-frame-parameters (cdr captured-action)))
          (should (eq (cdr (assq 'seshat-reader-panel-kind
                                 (alist-get 'child-frame-parameters
                                            (cdr captured-action))))
                      'translate))
          ;; 像素级收口：默认宽度 0.25 × 1000 = 250、满高 800 − 2×16 = 768；
          ;; 译文默认贴右 → LEFT = 1000 − 250 − 16 = 734
          (should (equal sized '((cf-new 250 768 t))))
          (should (equal positioned '((cf-new 734 16)))))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--cf-show-non-graphic-returns-nil ()
  "非图形 frame（batch / 终端）直接返回 nil，且完全不触碰 `display-buffer'.
回退窗口承载的决定必须由调用方拿着 nil 做出：本函数只懂 child frame 一种后端，
在此自行降级会把「谁负责回退」这件事藏起来；报错则会让终端用户连面板都没得用。"
  (let ((buf (get-buffer-create " *seshat-cf-terminal*"))
        (display-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'selected-frame)
                   (lambda () 'terminal-frame))
                  ((symbol-function 'display-graphic-p)
                   (lambda (&optional _frame) nil))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _)
                     (setq display-calls (1+ display-calls))
                     'never-window)))
          (should-not (seshat-reader-sidebar--cf-show buf 'translate))
          (should (zerop display-calls)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--cf-place-suppresses-mode-line ()
  "`--cf-place' 给 child frame 的窗口设 window parameter `mode-line-format' 为 `none'.
真机反馈的第二项修复：面板不应显示 mode-line（header-line 保留）。实测 Emacs
31.1 支持该 window parameter（设后 `window-mode-line-height' 20 → 0、body
680 → 700），故断言 `set-window-parameter' 收到 (WINDOW `mode-line-format'
`none')。创建路径与复用路径都经本函数，故一处设置两路生效。"
  (let (param-calls sized positioned)
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (frame param)
                 (cond ((and (eq frame 'cf-new) (eq param 'parent-frame))
                        'gui-frame)
                       ;; `--cf-place' 开头会先验证本包 kind 参数（防御），故桩
                       ;; 必须给出非 nil kind，否则整段收口被跳过
                       ((eq param 'seshat-reader-panel-kind) 'translate))))
              ((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () nil))
              ((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1000))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800))
              ((symbol-function 'set-frame-size)
               (lambda (&rest args) (push args sized)))
              ((symbol-function 'set-frame-position)
               (lambda (&rest args) (push args positioned)))
              ((symbol-function 'frame-selected-window)
               (lambda (_frame) 'cf-window))
              ((symbol-function 'windowp)
               (lambda (obj) (eq obj 'cf-window)))
              ((symbol-function 'set-window-parameter)
               (lambda (window parameter value)
                 (push (list window parameter value) param-calls))))
      (should (eq (seshat-reader-sidebar--cf-place 'cf-new 'translate)
                  'cf-new))
      (should (equal param-calls '((cf-window mode-line-format none))))
      ;; 尺寸与定位仍然生效（新增的一步不得挤掉既有收口）
      (should sized)
      (should positioned))))

(ert-deftest seshat-reader-sidebar-test--cf-place-mode-line-tolerates-missing-window ()
  "取不到 child frame 的窗口时不设参数、不报错，仍返回 FRAME.
`--cf-place' 的定位/尺寸/去 mode-line 都是「更好看」的收口步骤，任一失败都不
该让面板显示整体失败（frame 可能已死、选中窗口可能取不到）。"
  (let (param-calls)
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (frame param)
                 (cond ((and (eq frame 'cf-dead) (eq param 'parent-frame))
                        'gui-frame)
                       ((eq param 'seshat-reader-panel-kind) 'translate))))
              ((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () nil))
              ((symbol-function 'frame-pixel-width)
               (lambda (&optional _frame) 1000))
              ((symbol-function 'frame-pixel-height)
               (lambda (&optional _frame) 800))
              ((symbol-function 'set-frame-size) (lambda (&rest _args) nil))
              ((symbol-function 'set-frame-position) (lambda (&rest _args) nil))
              ;; 选中窗口取不到（死 frame / 无窗口）
              ((symbol-function 'frame-selected-window) (lambda (_frame) nil))
              ((symbol-function 'set-window-parameter)
               (lambda (window parameter value)
                 (push (list window parameter value) param-calls))))
      (should (eq (seshat-reader-sidebar--cf-place 'cf-dead 'translate)
                  'cf-dead))
      (should-not param-calls))))

(ert-deftest seshat-reader-sidebar-test--cf-place-rejects-foreign-frame ()
  "`--cf-place' 对不带本包 kind 参数的 frame 直接返回 nil，不设 mode-line、不定位.
防御场景：`display-buffer' 没走 child frame 动作、或意外把父 frame 的窗口交回来
时，若继续跑收口步骤就会把**父 frame** 自己的窗口 mode-line 关掉、并按面板尺寸
重排父 frame，破坏主界面。"
  (let (param-calls sized positioned)
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'parent-frame) 'gui-frame)))
              ((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () nil))
              ((symbol-function 'set-frame-size)
               (lambda (&rest args) (push args sized)))
              ((symbol-function 'set-frame-position)
               (lambda (&rest args) (push args positioned)))
              ((symbol-function 'set-window-parameter)
               (lambda (window parameter value)
                 (push (list window parameter value) param-calls))))
      (should-not (seshat-reader-sidebar--cf-place 'parent-window 'translate)))
    (should-not param-calls)
    (should-not sized)
    (should-not positioned)))

(ert-deftest seshat-reader-sidebar-test--cf-close-deletes-live-frame-only ()
  "`--cf-close' 只对活 frame 调 `delete-frame'，死 frame 与非 frame 静默返回.
关闭必须幂等：面板可能已被 `q' / `delete-other-frames' / 父 frame 关闭连带
删掉，此时再关不该报错。"
  (let (deleted)
    (cl-letf (((symbol-function 'framep)
               (lambda (obj) (memq obj '(cf dead-cf))))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (not (eq frame 'dead-cf))))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (push frame deleted))))
      (seshat-reader-sidebar--cf-close 'cf)
      (seshat-reader-sidebar--cf-close 'dead-cf)
      (seshat-reader-sidebar--cf-close 'not-a-frame)
      (should (equal deleted '(cf))))))

(ert-deftest seshat-reader-sidebar-test--panels-merges-windows-and-frames ()
  "`--panels' = 本包面板窗口 + 本包 child frame 面板，窗口在前、frame 在后.
拼接顺序是有意固定的：窗口是既有后端，「按 kind 取第一个」在混合场景下优先命中
窗口，与历史行为一致。"
  (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
             (lambda () '(w1 w2)))
            ((symbol-function 'seshat-reader-sidebar--cf-frames)
             (lambda () '(f1 f2))))
    (should (equal (seshat-reader-sidebar--panels) '(w1 w2 f1 f2))))
  (cl-letf (((symbol-function 'seshat-reader-sidebar--windows)
             (lambda () nil))
            ((symbol-function 'seshat-reader-sidebar--cf-frames)
             (lambda () '(f1))))
    (should (equal (seshat-reader-sidebar--panels) '(f1)))))

;;; 承载接入与生命周期（T3）

(ert-deftest seshat-reader-sidebar-test--display-dispatches-to-window ()
  "carrier 解析为 `window' 时 `--display' 只走窗口后端，完全不碰 `--cf-show'。
分派层同时负责 `--last-*' 记忆（childframe 分支靠它重开），故一并断言。"
  (let ((buf (get-buffer-create " *seshat-dispatch-window*"))
        (seshat-reader-sidebar--last-buffer nil)
        (seshat-reader-sidebar--last-kind nil)
        (seshat-reader-sidebar--last-buffers nil)
        (window-calls nil)
        (cf-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                   (lambda (_kind) 'window))
                  ((symbol-function 'seshat-reader-sidebar--display-window)
                   (lambda (b k &optional s)
                     (push (list b k s) window-calls) 'w-panel))
                  ((symbol-function 'seshat-reader-sidebar--cf-show)
                   (lambda (&rest _) (setq cf-calls (1+ cf-calls)) 'cf-window)))
          (should (eq (seshat-reader-sidebar--display buf 'outline t) 'w-panel))
          (should (equal window-calls (list (list buf 'outline t))))
          (should (zerop cf-calls))
          (should (eq seshat-reader-sidebar--last-buffer buf))
          (should (eq seshat-reader-sidebar--last-kind 'outline))
          (should (eq (cdr (assq 'outline seshat-reader-sidebar--last-buffers))
                      buf)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--display-dispatches-to-childframe ()
  "carrier 解析为 `childframe' 时 `--display' 走 `--cf-show' 并返回其窗口。
返回值语义是「承载单元的窗口」：childframe 分支返回 frame 的选中窗口，调用方
不需要知道自己拿到的是哪一种后端。"
  (let ((buf (get-buffer-create " *seshat-dispatch-cf*"))
        (seshat-reader-sidebar--last-buffer nil)
        (seshat-reader-sidebar--last-kind nil)
        (seshat-reader-sidebar--last-buffers nil)
        (cf-calls nil)
        (window-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                   (lambda (_kind) 'childframe))
                  ((symbol-function 'seshat-reader-sidebar--cf-show)
                   (lambda (b k &optional s)
                     (push (list b k s) cf-calls) 'cf-window))
                  ((symbol-function 'seshat-reader-sidebar--display-window)
                   (lambda (&rest _) (cl-incf window-calls) 'w-panel)))
          (should (eq (seshat-reader-sidebar--display buf 'translate)
                      'cf-window))
          (should (equal cf-calls (list (list buf 'translate nil))))
          (should (zerop window-calls))
          ;; child frame 的 buffer 也必须记进 per-kind 记忆，否则关掉后无法重开
          (should (eq (cdr (assq 'translate seshat-reader-sidebar--last-buffers))
                      buf)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--display-falls-back-to-window-when-cf-fails ()
  "child frame 建不出来（`--cf-show' 返回 nil）时回退窗口承载并返回窗口。
回退是分派层的职责：终端 frame / 父 frame 像素尺寸取不到 / 创建失败都表现为
nil，此时**必须**仍然给调用方一个窗口，而不是让面板显示整体失败。"
  (let ((buf (get-buffer-create " *seshat-dispatch-fallback*"))
        (seshat-reader-sidebar--last-buffer nil)
        (seshat-reader-sidebar--last-kind nil)
        (seshat-reader-sidebar--last-buffers nil)
        (cf-calls 0)
        (window-calls nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                   (lambda (_kind) 'childframe))
                  ((symbol-function 'seshat-reader-sidebar--cf-show)
                   (lambda (&rest _) (cl-incf cf-calls) nil))
                  ((symbol-function 'seshat-reader-sidebar--display-window)
                   (lambda (b k &optional s)
                     (push (list b k s) window-calls) 'w-fallback)))
          (should (eq (seshat-reader-sidebar--display buf 'translate t)
                      'w-fallback))
          (should (= cf-calls 1))
          (should (equal window-calls (list (list buf 'translate t)))))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-kind-closes-frame-panel ()
  "`--toggle-kind' 关闭 childframe 面板：走 `--panel-close'，buffer 仍记入记忆。
frame 面板的 buffer 必须一并记录——否则关掉 child frame 后 toggle 无从重开
（窗口能靠「窗口还在」判断，frame 关掉就什么都不剩）。"
  (let ((buf (get-buffer-create " *seshat-toggle-frame*"))
        (seshat-reader-sidebar--last-buffers nil)
        (seshat-reader-sidebar--last-buffer nil)
        (seshat-reader-sidebar--last-kind nil)
        (seshat-reader-sidebar--state nil)
        (closed nil)
        (messages nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--panels)
                   (lambda () (list 'cf-panel)))
                  ((symbol-function 'seshat-reader-sidebar--panel-kind)
                   (lambda (_panel) 'translate))
                  ((symbol-function 'seshat-reader-sidebar--panel-buffer)
                   (lambda (_panel) buf))
                  ((symbol-function 'seshat-reader-sidebar--panel-close)
                   (lambda (panel) (push panel closed)))
                  ((symbol-function 'seshat-reader-sidebar--cf-show)
                   (lambda (&rest _) 'should-not-be-called))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (seshat-reader-sidebar-toggle 'translate)
          (should (equal closed '(cf-panel)))
          (should (eq (cdr (assq 'translate seshat-reader-sidebar--last-buffers))
                      buf))
          (should (eq seshat-reader-sidebar--last-buffer buf))
          (should (cl-some (lambda (m) (string-match-p "已关闭" m)) messages)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--toggle-kind-reopens-childframe ()
  "无该 kind 面板但有记忆 buffer 时，重开经分派层落到 `--cf-show'。
重开路径不直接选后端，而是交 `seshat-reader-sidebar--display' 按 carrier 分派：
这样 `seshat-reader-sidebar-enabled' 的回退语义与 select 契约与首次显示完全一致。"
  (let* ((buf (get-buffer-create " *seshat-toggle-cf-reopen*"))
         (seshat-reader-sidebar--last-buffers (list (cons 'outline buf)))
         (seshat-reader-sidebar--last-kind nil)
         (seshat-reader-sidebar--last-buffer nil)
         (seshat-reader-sidebar-enabled t)
         (cf-calls nil)
         (window-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar--panels)
                   (lambda () nil))
                  ((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                   (lambda (_kind) 'childframe))
                  ((symbol-function 'seshat-reader-sidebar--cf-show)
                   (lambda (b k &optional s)
                     (push (list b k s) cf-calls) 'cf-window))
                  ((symbol-function 'seshat-reader-sidebar--display-window)
                   (lambda (&rest _) (cl-incf window-calls) 'w-panel))
                  ((symbol-function 'message) (lambda (&rest _) nil)))
          (seshat-reader-sidebar-toggle 'outline)
          (should (equal cf-calls (list (list buf 'outline t))))
          (should (zerop window-calls)))
      (kill-buffer buf))))

(ert-deftest seshat-reader-sidebar-test--capture-state-ignores-frame ()
  "`--capture-state' 只记窗口单元的尺寸：frame 单元不写入 `--state'。
child frame 的尺寸由父 frame 像素 × 比例固定决定，用户无法 resize，记忆它既无
意义也无恢复路径；函数把 `--panels' 的混合列表原样传进来时也必须过滤掉 frame。"
  (let ((seshat-reader-sidebar--state nil)
        (seshat-reader-sidebar-position 'below-selected))
    (cl-letf (((symbol-function 'framep)
               (lambda (obj) (eq obj 'cf-panel)))
              ((symbol-function 'window-parameter)
               (lambda (unit param)
                 (when (eq param 'seshat-reader-sidebar-kind)
                   (pcase unit
                     ('w-panel 'annotations)
                     ('cf-panel 'translate)))))
              ((symbol-function 'window-total-height) (lambda (&rest _) 20))
              ((symbol-function 'frame-height) (lambda (&rest _) 40)))
      (seshat-reader-sidebar--capture-state (list 'w-panel 'cf-panel))
      (should (equal (nth 2 (assq 'annotations seshat-reader-sidebar--state))
                     0.5))
      (should-not (assq 'translate seshat-reader-sidebar--state)))))

(ert-deftest seshat-reader-sidebar-test--hide-cf-on-buffer-change ()
  "生命周期：仅当「开启开关 + 有 child frame 面板 + 已不在阅读器」各条件同时成立才关闭.
六条早期返回是本函数挂在全局 `post-command-hook' 上（每条命令结束都跑）仍然廉价
的前提；关闭时对每个 frame 调一次 `--cf-close'、只 `message' 一次，且本函数确实
挂在全局 `post-command-hook' 上（不带 LOCAL），**不再**挂
`window-buffer-change-functions'（那里不得 `delete-frame'）。"
  (let ((closed nil)
        (messages nil)
        (frames '(cf-1 cf-2))
        (in-reader nil)
        (seshat-reader-panel-hide-on-buffer-change t))
    (cl-letf (((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () frames))
              ((symbol-function 'seshat-reader-sidebar--cf-close)
               (lambda (frame) (push frame closed)))
              ((symbol-function 'derived-mode-p)
               (lambda (&rest _modes) in-reader))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      ;; hook 必须挂在全局 `post-command-hook' 上（不传 LOCAL），否则切走 buffer
      ;; 时无从触发；且**不得**再挂 `window-buffer-change-functions'——那里属于
      ;; redisplay 流程，不允许 `delete-frame'
      (should (memq 'seshat-reader-sidebar--hide-cf-on-buffer-change
                    post-command-hook))
      (should-not (memq 'seshat-reader-sidebar--hide-cf-on-buffer-change
                        window-buffer-change-functions))
      (should (= 1 (cl-count 'seshat-reader-sidebar--hide-cf-on-buffer-change
                             post-command-hook)))
      ;; ① 开关为 nil → 一个都不关
      (setq seshat-reader-panel-hide-on-buffer-change nil)
      (seshat-reader-sidebar--hide-cf-on-buffer-change)
      (should-not closed)
      ;; ② 没有 child frame 面板 → 不关、也不提示（连 mode 都不判）
      (setq seshat-reader-panel-hide-on-buffer-change t
            frames nil)
      (seshat-reader-sidebar--hide-cf-on-buffer-change)
      (should-not closed)
      (should-not messages)
      ;; ③ 仍在阅读器里（`derived-mode-p' 命中）→ 不关
      (setq frames '(cf-1 cf-2)
            in-reader t)
      (seshat-reader-sidebar--hide-cf-on-buffer-change)
      (should-not closed)
      ;; ④ 切到非阅读 buffer → 逐个关闭，且只提示一次
      (setq in-reader nil)
      (seshat-reader-sidebar--hide-cf-on-buffer-change)
      (should (equal closed '(cf-2 cf-1)))
      (should (= (length messages) 1)))))

;;; 面板内 `q'：`seshat-reader-sidebar-quit' 的四条分支

(ert-deftest seshat-reader-sidebar-test--quit-closes-translate-panel ()
  "译文面板内按 `q' → 只关 `translate' 面板，不走全部开合.
kind 由 buffer 名推断；命令必须把 kind 交给 `--toggle-kind'（它按承载单元分派
`delete-window' / `delete-frame'），而不是无参 `seshat-reader-sidebar-toggle'
（那会连带关掉其它 kind）。"
  (let (kind-calls toggle-calls)
    (cl-letf (((symbol-function 'buffer-name)
               (lambda (&optional _buffer)
                 seshat-reader-sidebar-translate-buffer-name))
              ((symbol-function 'seshat-reader-sidebar--toggle-kind)
               (lambda (kind) (push kind kind-calls)))
              ((symbol-function 'seshat-reader-sidebar-toggle)
               (lambda (&optional kind) (push kind toggle-calls))))
      (seshat-reader-sidebar-quit))
    (should (equal kind-calls '(translate)))
    (should-not toggle-calls)))

(ert-deftest seshat-reader-sidebar-test--quit-closes-outline-panel ()
  "目录面板内按 `q' → kind 推断为 `outline'（名字是动态格式）."
  (let (kind-calls toggle-calls)
    (cl-letf (((symbol-function 'buffer-name)
               (lambda (&optional _buffer) "*Outline of paper.pdf*"))
              ((symbol-function 'seshat-reader-sidebar--toggle-kind)
               (lambda (kind) (push kind kind-calls)))
              ((symbol-function 'seshat-reader-sidebar-toggle)
               (lambda (&optional kind) (push kind toggle-calls))))
      (seshat-reader-sidebar-quit))
    (should (equal kind-calls '(outline)))
    (should-not toggle-calls)))

(ert-deftest seshat-reader-sidebar-test--quit-falls-back-to-toggle ()
  "非面板 buffer 里按 `q' → 退回「全部开合」旧语义（无参 toggle）."
  (let (toggle-calls kind-calls)
    (cl-letf (((symbol-function 'buffer-name)
               (lambda (&optional _buffer) "*scratch*"))
              ((symbol-function 'seshat-reader-sidebar-toggle)
               (lambda (&optional kind) (push kind toggle-calls)))
              ((symbol-function 'seshat-reader-sidebar--toggle-kind)
               (lambda (kind) (push kind kind-calls))))
      (seshat-reader-sidebar-quit))
    (should (equal toggle-calls '(nil)))
    (should-not kind-calls)))

(ert-deftest seshat-reader-sidebar-test--quit-deletes-frame-for-childframe ()
  "child frame 承载时按 `q' 走 `delete-frame'，不留下空 frame.
`quit-window' 对 child frame 只能删窗口、frame 会剩成空壳——这正是本命令存在的
理由，故断言 `delete-window' **没有**被调用。"
  (let (delete-frame-calls delete-window-calls captured)
    (cl-letf (((symbol-function 'buffer-name)
               (lambda (&optional _buffer)
                 seshat-reader-sidebar-translate-buffer-name))
              ((symbol-function 'seshat-reader-sidebar--panels)
               (lambda () (list 'fake-frame)))
              ((symbol-function 'framep)
               (lambda (obj) (eq obj 'fake-frame)))
              ((symbol-function 'seshat-reader-sidebar--unit-kind)
               (lambda (_panel) 'translate))
              ((symbol-function 'seshat-reader-sidebar--capture-state)
               (lambda (panels) (setq captured panels)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force)
                 (push frame delete-frame-calls)))
              ((symbol-function 'delete-window)
               (lambda (window) (push window delete-window-calls))))
      (seshat-reader-sidebar-quit))
    (should (equal delete-frame-calls '(fake-frame)))
    (should-not delete-window-calls)
    (should (equal captured '(fake-frame)))))

;;; 生命周期（post-command-hook）：六条早期返回逐条固定

(ert-deftest seshat-reader-sidebar-test--hide-cf-skipped-when-no-frames ()
  "没有 child frame 面板时零动作：不关、不提示，连 minibuffer/mode 判定都不算.
这条**必须**排在其它判定之前：`post-command-hook' 每条命令结束都跑，而无面板是
绝大多数命令的常态，故只允许付一次 `--cf-frames'（`frame-list' 过滤）的成本。"
  (let (closed messages minibuffer-asked mode-asked)
    (cl-letf (((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () nil))
              ((symbol-function 'seshat-reader-sidebar--cf-close)
               (lambda (frame) (push frame closed)))
              ((symbol-function 'minibufferp)
               (lambda (&optional _buffer) (setq minibuffer-asked t) nil))
              ((symbol-function 'derived-mode-p)
               (lambda (&rest _modes) (setq mode-asked t) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (let ((seshat-reader-panel-hide-on-buffer-change t))
        (seshat-reader-sidebar--hide-cf-on-buffer-change)))
    (should-not closed)
    (should-not messages)
    (should-not minibuffer-asked)
    (should-not mode-asked)))

(ert-deftest seshat-reader-sidebar-test--hide-cf-skipped-in-minibuffer ()
  "在 minibuffer 里不关面板：追问/过滤正在输入时面板必须留着.
桩 `minibufferp' 为 t，其余条件都「本该关」，断言零关闭、零提示，且 mode 判定根本
没被算到（minibuffer 判定在其之前）。"
  (let (closed messages mode-asked)
    (cl-letf (((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () '(cf-1 cf-2)))
              ((symbol-function 'seshat-reader-sidebar--cf-close)
               (lambda (frame) (push frame closed)))
              ((symbol-function 'minibufferp)
               (lambda (&optional _buffer) t))
              ((symbol-function 'derived-mode-p)
               (lambda (&rest _modes) (setq mode-asked t) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (let ((seshat-reader-panel-hide-on-buffer-change t))
        (seshat-reader-sidebar--hide-cf-on-buffer-change)))
    (should-not closed)
    (should-not messages)
    (should-not mode-asked)))

(ert-deftest seshat-reader-sidebar-test--hide-cf-skipped-when-selected-frame-is-panel ()
  "选中 frame 是本包 child frame 时不关：用户正在面板里选词/滚动，撤面板等于毁操作.
桩 `frame-parameter' 对 `seshat-reader-panel-kind' 返回 `translate'（真机上面板被
`select-frame' 选中后就是这个状态）。"
  (let (closed messages mode-asked)
    (cl-letf (((symbol-function 'seshat-reader-sidebar--cf-frames)
               (lambda () '(cf-1 cf-2)))
              ((symbol-function 'seshat-reader-sidebar--cf-close)
               (lambda (frame) (push frame closed)))
              ((symbol-function 'minibufferp)
               (lambda (&optional _buffer) nil))
              ((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'seshat-reader-panel-kind) 'translate)))
              ((symbol-function 'derived-mode-p)
               (lambda (&rest _modes) (setq mode-asked t) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (let ((seshat-reader-panel-hide-on-buffer-change t))
        (seshat-reader-sidebar--hide-cf-on-buffer-change)))
    (should-not closed)
    (should-not messages)
    (should-not mode-asked)))

(ert-deftest seshat-reader-sidebar-test--hide-cf-skipped-in-reader-buffer ()
  "选中窗口的 buffer 派生自阅读器 mode 时不关，且两个 mode 的冗余判定都生效.
判定显式取 `(window-buffer (selected-window))` 再 `with-current-buffer' 求值，不
依赖 `current-buffer'。① `seshat-reader-mode' 命中即返回；② 只让
`seshat-reading-mode' 命中（模拟派生关系将来变化）仍不关——这正是写两个 mode 的
理由。"
  (let (closed messages asked)
    (let ((buf (generate-new-buffer " *seshat-hide-reader*")))
      (unwind-protect
          (cl-letf (((symbol-function 'seshat-reader-sidebar--cf-frames)
                     (lambda () '(cf-1 cf-2)))
                    ((symbol-function 'seshat-reader-sidebar--cf-close)
                     (lambda (frame) (push frame closed)))
                    ((symbol-function 'minibufferp)
                     (lambda (&optional _buffer) nil))
                    ((symbol-function 'frame-parameter)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'window-buffer)
                     (lambda (&optional _window) buf))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages))))
            ;; ① 只有 `seshat-reader-mode' 命中
            (cl-letf (((symbol-function 'derived-mode-p)
                       (lambda (&rest modes)
                         (push modes asked)
                         (memq 'seshat-reader-mode modes))))
              (let ((seshat-reader-panel-hide-on-buffer-change t))
                (seshat-reader-sidebar--hide-cf-on-buffer-change)))
            (should-not closed)
            ;; ② 只让 `seshat-reading-mode' 命中（冗余保险）
            (cl-letf (((symbol-function 'derived-mode-p)
                       (lambda (&rest modes)
                         (push modes asked)
                         (memq 'seshat-reading-mode modes))))
              (let ((seshat-reader-panel-hide-on-buffer-change t))
                (seshat-reader-sidebar--hide-cf-on-buffer-change)))
            (should-not closed)
            (should-not messages)
            (should asked))
        (kill-buffer buf)))))

(ert-deftest seshat-reader-sidebar-test--hide-cf-closes-on-foreign-buffer ()
  "切到非阅读 buffer 时逐个关闭 child frame，且只 `message' 一次.
本用例**不桩** mode 谓词：选中窗口的 buffer 是真的 `fundamental-mode'，`--cf-close'
被每个 frame 各调一次，提示只说一次（与关了几个面板无关）。"
  (let (closed messages)
    (let ((buf (generate-new-buffer " *seshat-hide-foreign*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (fundamental-mode))
            (cl-letf (((symbol-function 'seshat-reader-sidebar--cf-frames)
                       (lambda () '(cf-1 cf-2)))
                      ((symbol-function 'seshat-reader-sidebar--cf-close)
                       (lambda (frame) (push frame closed)))
                      ((symbol-function 'minibufferp)
                       (lambda (&optional _buffer) nil))
                      ((symbol-function 'frame-parameter)
                       (lambda (&rest _args) nil))
                      ((symbol-function 'window-buffer)
                       (lambda (&optional _window) buf))
                      ((symbol-function 'message)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) messages))))
              (let ((seshat-reader-panel-hide-on-buffer-change t))
                (seshat-reader-sidebar--hide-cf-on-buffer-change)))
            (should (equal closed '(cf-2 cf-1)))
            (should (= 1 (length messages)))
            (should (string-match-p "隐藏" (car messages))))
        (kill-buffer buf)))))

;;; 折行默认与面板宽度切换（M12 后续）

(ert-deftest seshat-reader-sidebar-test--panel-defaults ()
  "面板折行默认 `nil`（折行），扩大宽度默认 `0.75`。"
  ;; `standard-value' 存的是**求值形式**（defcustom 会把常量包成
  ;; `(funcall (function (lambda nil VALUE)))'），故必须先 `eval' 再比较
  (should-not (eval (car (get 'seshat-reader-panel-truncate-lines
                              'standard-value))
                    t))
  (should (null (default-value 'seshat-reader-panel-truncate-lines)))
  (should (equal (eval (car (get 'seshat-reader-sidebar-expanded-width
                                 'standard-value))
                       t)
                 0.75))
  (should (= (default-value 'seshat-reader-sidebar-expanded-width) 0.75)))

(defun seshat-reader-sidebar-test--toggle-width-run
    (kind init-width frame-width &optional expanded-width)
  "在桩环境下跑两次 `seshat-reader-sidebar-toggle-width'（扩大 → 恢复）.
桩：`seshat-reader-sidebar-window-p' 恒 t（选中窗口当作面板）、
`window-parameter' 恒返回 KIND、`window-total-width' 返回可变的当前列数、
`frame-width' 固定 FRAME-WIDTH、`window-resize' 记录 `(WINDOW DELTA)' 并累加
列数、`message' 收集文案。EXPANDED-WIDTH 省略时固定为 `0.75`（显式绑定，避免
用例受用户配置影响）。返回 plist：`:resizes' / `:width' / `:memory' 为**第一次**
调用（扩大）后的状态，`:resizes2' / `:width2' / `:memory2' / `:messages2' 为
**第二次**调用（恢复）后的状态（`:memory' 取不到时用符号 `none' 占位）。"
  (let* ((width init-width)
         (resizes nil)
         (messages nil)
         (memory (make-hash-table :test #'eq))
         (first nil))
    (let ((seshat-reader-sidebar--width-memory memory)
          ;; 左右分栏（宽度语义）与扩大比例都显式固定
          (seshat-reader-sidebar-position 'right)
          (seshat-reader-sidebar-expanded-width (or expanded-width 0.75)))
      (cl-letf (((symbol-function 'seshat-reader-sidebar-window-p)
                 (lambda (&rest _) t))
                ((symbol-function 'window-parameter)
                 (lambda (&rest _) kind))
                ((symbol-function 'window-total-width)
                 (lambda (&rest _) width))
                ((symbol-function 'frame-width)
                 (lambda (&rest _) frame-width))
                ((symbol-function 'window-resize)
                 (lambda (window delta &rest _)
                   (push (list window delta) resizes)
                   (cl-incf width delta)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (seshat-reader-sidebar-toggle-width)
        (setq first (list :resizes (nreverse resizes)
                          :width width
                          :memory (gethash kind memory 'none)))
        (setq resizes nil
              messages nil)
        (seshat-reader-sidebar-toggle-width)
        (append first
                (list :resizes2 (nreverse resizes)
                      :width2 width
                      :memory2 (gethash kind memory 'none)
                      :messages2 (nreverse messages)))))))

(ert-deftest seshat-reader-sidebar-test--toggle-width-expands-and-restores ()
  "首次调用扩大到 `round(frame 宽 × 0.75)`，再次调用回到原列数并清记忆."
  (let* ((kind 'translate)
         (result (seshat-reader-sidebar-test--toggle-width-run kind 20 80))
         (win (selected-window)))
    ;; 目标列数 = round(80 × 0.75) = 60；DELTA = 60 − 20 = 40
    (should (= 60 (plist-get result :width)))
    (should (equal (plist-get result :resizes) (list (list win 40))))
    ;; 扩大前宽度按 kind 记下，供恢复使用
    (should (= 20 (plist-get result :memory)))
    ;; 第二次：DELTA = 20 − 60 = −40，恢复后记忆被清空
    (should (= 20 (plist-get result :width2)))
    (should (equal (plist-get result :resizes2) (list (list win -40))))
    (should (eq 'none (plist-get result :memory2)))
    ;; 恢复时给出可见反馈
    (should (string-match-p "恢复" (car (plist-get result :messages2))))))

(ert-deftest seshat-reader-sidebar-test--toggle-width-target-smaller-than-current ()
  "`expanded-width' 小于当前宽度时照常工作（差量为负），恢复仍回到原列数."
  (let* ((result (seshat-reader-sidebar-test--toggle-width-run
                  'annotations 60 80 0.25))
         (win (selected-window)))
    ;; 目标 = round(80 × 0.25) = 20 → DELTA = −40
    (should (= 20 (plist-get result :width)))
    (should (equal (plist-get result :resizes) (list (list win -40))))
    (should (= 60 (plist-get result :memory)))
    (should (= 60 (plist-get result :width2)))
    (should (equal (plist-get result :resizes2) (list (list win 40))))))

(ert-deftest seshat-reader-sidebar-test--toggle-width-without-panel ()
  "没有面板时只 `message' 提示，不调用 `window-resize'。"
  (let ((resized nil)
        (messages nil))
    (cl-letf (((symbol-function 'seshat-reader-sidebar-window-p)
               (lambda (&rest _) nil))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
              ((symbol-function 'seshat-reader-sidebar--windows)
               (lambda () nil))
              ((symbol-function 'window-resize)
               (lambda (&rest _) (setq resized t)))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (seshat-reader-sidebar-toggle-width)
      (should-not resized)
      (should (= 1 (length messages)))
      (should (string-match-p "没有可调整宽度的面板" (car messages))))))

(ert-deftest seshat-reader-sidebar-test--toggle-width-childframe-unsupported ()
  "childframe 承载时提示不支持、不 `window-resize'、不写宽度记忆."
  (let ((resized nil)
        (messages nil)
        (memory (make-hash-table :test #'eq)))
    (let ((seshat-reader-sidebar--width-memory memory))
      (cl-letf (((symbol-function 'seshat-reader-sidebar-window-p)
                 (lambda (&rest _) t))
                ((symbol-function 'window-parameter)
                 (lambda (&rest _) 'translate))
                ((symbol-function 'seshat-reader-sidebar--carrier-for-kind)
                 (lambda (&rest _) 'childframe))
                ((symbol-function 'window-resize)
                 (lambda (&rest _) (setq resized t)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (seshat-reader-sidebar-toggle-width)
        (should-not resized)
        (should (= 1 (length messages)))
        (should (string-match-p "childframe" (car messages)))
        (should (= 0 (hash-table-count memory)))))))

(ert-deftest seshat-reader-sidebar-test--toggle-width-keybindings ()
  "`C-c w' 在阅读 buffer 与三个面板 keymap 上都绑到 `--toggle-width'."
  ;; 目录面板的 keymap 在其自己的模块里定义，本用例必须先加载该模块
  (require 'seshat-reader-outline)
  (should (eq (lookup-key seshat-reader-mode-map (kbd "C-c w"))
              #'seshat-reader-sidebar-toggle-width))
  (should (eq (lookup-key seshat-reader-translate-panel-map (kbd "C-c w"))
              #'seshat-reader-sidebar-toggle-width))
  (should (eq (lookup-key seshat-reader-annotation-list-mode-map (kbd "C-c w"))
              #'seshat-reader-sidebar-toggle-width))
  (should (eq (lookup-key seshat-reader-outline-mode-map (kbd "C-c w"))
              #'seshat-reader-sidebar-toggle-width)))

;;; 帮助页（seshat-reader-help，2026-10-26）

(ert-deftest seshat-reader-sidebar-test--help-creates-special-mode-buffer ()
  "`seshat-reader-help' 生成只读 `special-mode' 帮助页，内容含真实键位与功能词."
  (let ((buffer nil)
        (displayed nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (b &optional _action) (setq displayed b) b)))
            (setq buffer (seshat-reader-help)))
          (should (buffer-live-p buffer))
          (should (eq buffer (get-buffer seshat-reader-help-buffer-name)))
          (should (eq displayed buffer))
          (with-current-buffer buffer
            (should (eq major-mode 'special-mode))
            (should buffer-read-only)
            (let ((content (buffer-string)))
              ;; 键位来自真实绑定（`M-o' 由 sidebar 模块注册），不是硬编码字符串
              (should (string-match-p
                       (regexp-quote (key-description (kbd "M-o")))
                       content))
              ;; 至少 5 个功能词
              (dolist (word '("翻译" "解释" "追问" "批注" "目录" "搜索" "缓存"))
                (should (string-match-p (regexp-quote word) content))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest seshat-reader-sidebar-test--help-bound-to-question-mark ()
  "阅读 buffer 的 `?' 绑到 `seshat-reader-help'（override `special-mode' 的 `describe-mode'）."
  (should (eq (lookup-key seshat-reader-mode-map (kbd "?"))
              #'seshat-reader-help)))

(ert-deftest seshat-reader-sidebar-test--help-reuses-buffer ()
  "重复调用复用同一个帮助 buffer，不新建、不清空."
  (let ((first nil)
        (second nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (b &optional _action) b)))
          (setq first (seshat-reader-help))
          (let ((buffers-before (length (buffer-list))))
            (setq second (seshat-reader-help))
            (should (eq first second))
            ;; 不新建 buffer：总数不变
            (should (= buffers-before (length (buffer-list))))
            (should (> (with-current-buffer second (buffer-size)) 0))))
      (when (buffer-live-p first) (kill-buffer first)))))

(provide 'seshat-reader-sidebar-test)
;;; seshat-reader-sidebar-test.el ends here
