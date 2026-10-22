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
（`seshat-reader-translate--render-panel'）都实际传了 SELECT=t，故管道
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
                       (lambda () nil)))
              ;; 批注：走文本回退路径，末尾仍经 `show' 以 annotations 显示
              (seshat-reader-annotation--render-list
               "doc-select" nil
               '(((id . 1) (location . "page:1;rect:0,0,0,0")
                  (text . "一条批注")))
               nil)
              ;; 译文：面板缓冲写入 + `show'，不依赖 gt
              (seshat-reader-translate--render-panel "一句译文" "Seshat 译文"))
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

(ert-deftest seshat-reader-sidebar-test--toggle-outline-command-and-binding ()
  "`C-c C-o' 绑定目录开合命令，`o' 仍是 `seshat-reader-outline-show'."
  (should (commandp 'seshat-reader-sidebar-toggle-outline))
  (should (eq (lookup-key seshat-reader-mode-map (kbd "C-c C-o"))
              'seshat-reader-sidebar-toggle-outline))
  (should (eq (lookup-key seshat-reader-mode-map (kbd "o"))
              'seshat-reader-outline-show))
  (let ((calls nil))
    (cl-letf (((symbol-function 'seshat-reader-sidebar-toggle)
               (lambda (&optional kind) (push kind calls))))
      (seshat-reader-sidebar-toggle-outline))
    (should (equal calls '(outline)))))

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

(provide 'seshat-reader-sidebar-test)
;;; seshat-reader-sidebar-test.el ends here
