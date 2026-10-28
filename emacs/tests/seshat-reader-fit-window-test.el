;;; seshat-reader-fit-window-test.el --- fit 计算用哪个窗口  -*- lexical-binding: t; -*-

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

;; 阅读器 fit 计算的**窗口解析**契约（计划
;; `openspec/active/2026-10-27-reader-fit-minibuffer-window.md` 的 T1–T3）：
;;
;; 1. `seshat-reader--multipage--display-window' 的四个分支 + A1b 的
;;    「不传 window 且 selected-window 不显示当前 buffer」edge case；
;; 2. `--multipage-target-scale' / `--multipage-current-fit-mode' 在解析不出
;;    窗口时必须退回基准 scale / buffer-local 模式，且**不得**去量窗口
;;   （minibuffer 窗口高 102 px，量它会把页面压成 153x198 的窄条）；
;; 3. `--multipage-render-page' 把 WINDOW 继续传下去（T2）；
;; 4. minibuffer 期间的布局冻结与退出后的恢复（T3 / D2）。
;;
;; 全部用例在 `emacs --batch -Q' 下可跑：batch 里窗口原语可用（`split-window' /
;; `get-buffer-window' / `minibuffer-window' 都真实存在，实测 Emacs 31.1），
;; 故不需要伪造窗口对象；只有「reader 模式 buffer」的夹具要桩掉真渲染
;; （`--render-buffer' / `--first-fit'）。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader -l ert \
;;     -l emacs/tests/seshat-reader-fit-window-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)

;;;; 夹具

(defmacro seshat-reader-fit-window-test--with-window-showing (&rest body)
  "在当前 buffer 里执行 BODY，同时把它显示在选中窗口。

结束时把选中窗口恢复成原来的 buffer：`split-window' 造出来的窗口与「选中窗口
显示哪个 buffer」都是全局状态，用例之间必须还原，否则后面的用例会因为前一个
用例残留的窗口而得出错误结论。"
  (declare (indent 0) (debug t))
  `(let ((original (window-buffer (selected-window))))
     (unwind-protect
         (progn
           (set-window-buffer (selected-window) (current-buffer))
           ,@body)
       (set-window-buffer (selected-window) original))))

(defun seshat-reader-fit-window-test--open-reader-buffer ()
  "在当前 buffer 里真正跑一遍 `seshat-reader-mode'.

只桩替 `seshat-reader--render-buffer'（真渲染要真实文档）与
`seshat-reader--first-fit'（直接碰真实窗口）——本条用例要测的正是 mode 生效
之后的 refit 路径，桩掉 mode 本身就没有被测对象了。"
  (cl-letf (((symbol-function 'seshat-reader--render-buffer)
             (lambda (&rest _) nil))
            ((symbol-function 'seshat-reader--first-fit)
             (lambda (&rest _) nil)))
    (seshat-reader-mode)))

(defmacro seshat-reader-fit-window-test--with-reader-buffer (&rest body)
  "在已进入 `seshat-reader-mode' 的临时文件 buffer 内执行 BODY.

`seshat-reader-mode' 的 body 开头有 kill-buffer 守卫（文件不存在就杀 buffer），
故必须给一个真实存在的临时文件。"
  (declare (indent 0) (debug t))
  `(let ((file (make-temp-file "seshat-reader-fit-window-test")))
     (unwind-protect
         (let ((buffer (find-file-noselect file)))
           (unwind-protect
               (with-current-buffer buffer
                 (seshat-reader-fit-window-test--open-reader-buffer)
                 ,@body)
             (when (buffer-live-p buffer) (kill-buffer buffer))))
       (delete-file file))))

;;;; 1. 解析器：四个分支（T1 / D1）

(ert-deftest seshat-reader-fit-window-test--display-window-uses-given-window ()
  "入参窗口可用（活、非 minibuffer、显示当前 buffer）时原样返回。"
  (with-temp-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (should (eq (selected-window)
                  (seshat-reader--multipage--display-window
                   (selected-window)))))))

(ert-deftest seshat-reader-fit-window-test--display-window-skips-minibuffer-window ()
  "入参是 minibuffer 窗口时不返回它，回落到显示当前 buffer 的窗口。"
  (with-temp-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((mini (minibuffer-window)))
        (should (windowp mini))
        ;; 夹具自检：这确实是 minibuffer 窗口，否则下面的断言是空跑。
        (should (window-minibuffer-p mini))
        (should-not (eq (window-buffer mini) (current-buffer)))
        (should (eq (selected-window)
                    (seshat-reader--multipage--display-window mini)))))))

(ert-deftest seshat-reader-fit-window-test--display-window-mini-test-is-load-bearing ()
  "排除 minibuffer 窗口靠的是 `window-minibuffer-p'，不只是 buffer 不同.

桩掉 `window-minibuffer-p'，让它把**显示当前 buffer 的选中窗口**判为
minibuffer 窗口：三个候选都被这条判据挡掉，解析结果必须是 nil。若实现只比较
`window-buffer'（本例里它完全匹配），这里就会错误地返回那个窗口。"
  (with-temp-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (cl-letf (((symbol-function 'window-minibuffer-p)
                 (lambda (window) (eq window (selected-window)))))
        (should-not (seshat-reader--multipage--display-window
                     (selected-window)))))))

(ert-deftest seshat-reader-fit-window-test--display-window-falls-back-to-buffer-window ()
  "入参不可用（显示别的 buffer / 已删除）时回落到 `get-buffer-window' 的结果。"
  (with-temp-buffer
    (let ((other (get-buffer-create "*seshat-fit-window-test-other*"))
          (target (current-buffer))
          (displaying nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (setq displaying (split-window (selected-window)))
            ;; `with-selected-window' 里 `(current-buffer)' 就是那个窗口的
            ;; buffer，故先把目标 buffer 取出来再设，否则等于又设回 OTHER。
            (set-window-buffer displaying target)
            ;; 入参是「显示别的 buffer」的窗口 → 必须回落到真正显示本 buffer 的窗口
            (should (eq displaying
                        (seshat-reader--multipage--display-window
                         (selected-window))))
            (should (eq displaying
                        (get-buffer-window (current-buffer) t)))
            ;; 入参是已删除的窗口 → 同样回落
            (let ((dead (split-window (selected-window))))
              (delete-window dead)
              (should-not (window-live-p dead))
              (should (eq displaying
                          (seshat-reader--multipage--display-window dead)))))
        (when (window-live-p displaying) (delete-window displaying))
        (set-window-buffer (selected-window) (get-buffer "*scratch*"))
        (kill-buffer other)))))

(ert-deftest seshat-reader-fit-window-test--display-window-returns-nil ()
  "当前 buffer 没有窗口显示、选中窗口又显示别的 buffer 时返回 nil。"
  (with-temp-buffer
    (should-not (get-buffer-window (current-buffer) t))
    (should-not (eq (window-buffer (selected-window)) (current-buffer)))
    (should-not (seshat-reader--multipage--display-window))
    (should-not (seshat-reader--multipage--display-window nil))
    (should-not (seshat-reader--multipage--display-window (selected-window)))))

(ert-deftest seshat-reader-fit-window-test--display-window-a1b-prefers-buffer-window ()
  "A1b：不传 window 且选中的窗口显示别的 buffer 时，返回显示本 buffer 的窗口.

这是相对旧实现（`(if (window-live-p window) window (selected-window))'）的行为
改进：旧实现会返回那个显示别的 buffer 的选中窗口，并拿它的尺寸算 fit。"
  (with-temp-buffer
    (let ((other (get-buffer-create "*seshat-fit-window-test-a1b*"))
          (target (current-buffer))
          (displaying nil))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (setq displaying (split-window (selected-window)))
            ;; 同上：在 `with-selected-window' 里 `(current-buffer)' 会变成
            ;; 那个窗口的 buffer，所以目标 buffer 必须先取出来。
            (set-window-buffer displaying target)
            ;; 不传 window：选中窗口显示的是 OTHER，不是当前 buffer
            (should-not (eq (window-buffer (selected-window)) (current-buffer)))
            (should (eq displaying (seshat-reader--multipage--display-window))))
        (when (window-live-p displaying) (delete-window displaying))
        (set-window-buffer (selected-window) (get-buffer "*scratch*"))
        (kill-buffer other)))))

;;;; 2. 解析不出窗口时三处调用的退化（T1 / A3 / 注意事项 7）

(ert-deftest seshat-reader-fit-window-test--target-scale-returns-clamped-base ()
  "解析出 nil 窗口时 `--multipage-target-scale' 返回 clamp 过的基准 scale.

并且**不得触碰** `window-body-width' / `window-body-height'：A3 是硬约束，
nil 窗口走到那里就是 `wrong-type-argument windowp nil'。"
  (with-temp-buffer
    (should-not (seshat-reader--multipage--display-window))
    (cl-letf (((symbol-function 'window-body-width)
               (lambda (&rest _) (error "window-body-width must not run")))
              ((symbol-function 'window-body-height)
               (lambda (&rest _) (error "window-body-height must not run"))))
      ;; 下限：0.1 被 clamp 到 0.25
      (let ((seshat-reader--multipage-base-scale 0.1))
        (should (= 0.25 (seshat-reader--multipage-target-scale 1))))
      ;; 正常基准原样返回
      (let ((seshat-reader--multipage-base-scale 1.75))
        (should (= 1.75 (seshat-reader--multipage-target-scale 1))))
      ;; 上限：20.0 被 clamp 到 11.0
      (let ((seshat-reader--multipage-base-scale 20.0))
        (should (= 11.0 (seshat-reader--multipage-target-scale 1)))))))

(ert-deftest seshat-reader-fit-window-test--fit-scale-nil-without-window ()
  "解析出 nil 窗口时 `--multipage-fit-scale' 返回 nil（无几何可fit）。"
  (with-temp-buffer
    (setq seshat-reader--page-native-sizes '((1 612.0 . 792.0)))
    (cl-letf (((symbol-function 'window-body-width)
               (lambda (&rest _) (error "window-body-width must not run")))
              ((symbol-function 'window-body-height)
               (lambda (&rest _) (error "window-body-height must not run"))))
      (should-not (seshat-reader--multipage-fit-scale 1 'width))
      (should-not (seshat-reader--multipage-fit-scale 1 'height))
      (should-not (seshat-reader--multipage-fit-scale 1 'contain)))))

(ert-deftest seshat-reader-fit-window-test--current-fit-mode-buffer-local-only ()
  "解析出 nil 窗口时 `--multipage-current-fit-mode' 只返回 buffer-local 值.

允许 nil：原来会经 `--window-fit-mode' 兜底成 `contain'，现在没有窗口就不该
凭空造一个模式出来（注意事项 7）。"
  (with-temp-buffer
    (should-not (seshat-reader--multipage--display-window))
    (let ((seshat-reader--multipage-fit-mode 'width))
      (should (eq 'width (seshat-reader--multipage-current-fit-mode))))
    (should-not seshat-reader--multipage-fit-mode)
    (cl-letf (((symbol-function 'seshat-reader--window-fit-mode)
               (lambda (&rest _) (error "must not consult a window"))))
      (should-not (seshat-reader--multipage-current-fit-mode)))))

;;;; 3. 渲染传参（T2）

(ert-deftest seshat-reader-fit-window-test--render-page-forwards-window ()
  "`--multipage-render-page' 把 WINDOW 传给 target-scale 与 resize-spec.

断言**实参与顺序**，不是「被调用过」：target-scale 先于 resize-spec，两者都
收到同一个 WINDOW 对象。"
  (with-temp-buffer
    (let ((calls nil)
          (window (minibuffer-window)))
      (cl-letf (((symbol-function 'seshat-reader--multipage-target-scale)
                 (lambda (page &optional window)
                   (push (list 'target page window) calls)
                   1.0))
                ((symbol-function 'seshat-reader--page-spec)
                 (lambda (&rest _) (list 'image :width 10 :height 10)))
                ((symbol-function 'seshat-reader--multipage-record-native)
                 (lambda (&rest _) nil))
                ((symbol-function 'seshat-reader--multipage-resize-spec)
                 (lambda (page &optional window)
                   (push (list 'resize page window) calls)
                   nil))
                ((symbol-function 'seshat-reader--multipage-set-page-centered)
                 (lambda (&rest _) nil)))
        (should (seshat-reader--multipage-render-page 3 nil window))
        (should (equal (nreverse calls)
                       (list (list 'target 3 window)
                             (list 'resize 3 window))))))))

(ert-deftest seshat-reader-fit-window-test--rerender-page-forwards-window ()
  "`--multipage-rerender-page' 把自己的 WINDOW 传下去，并强制重渲染."
  (with-temp-buffer
    (let ((calls nil)
          (window (minibuffer-window)))
      ;; 必须已经有一行，否则 rerender 直接早退（nothing to do）。
      (setq seshat-reader--pages
            (list (list 2 (copy-marker (point-min) t) 'image)))
      (cl-letf (((symbol-function 'seshat-reader--multipage-render-page)
                 (lambda (page &optional force window)
                   (push (list 'render page force window) calls)
                   (list 'image :width 10 :height 10)))
                ((symbol-function 'seshat-reader--multipage-set-page-centered)
                 (lambda (&rest _) nil)))
        (seshat-reader--multipage-rerender-page 2 window)
        (should (equal (nreverse calls)
                       (list (list 'render 2 t window))))))))

;;;; 4. minibuffer 期间的冻结与退出后的恢复（T3 / D2）

(ert-deftest seshat-reader-fit-window-test--refit-window-frozen-in-minibuffer ()
  "`window-minibuffer-p' 为真时 `--refit-window' 完全不重排也不重渲染."
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((calls nil))
        (cl-letf (((symbol-function 'window-minibuffer-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'seshat-reader--apply-display-scale)
                   (lambda (&rest _) (push 'scale calls)))
                  ((symbol-function 'seshat-reader--multipage-refit-page)
                   (lambda (&rest _) (push 'refit calls)))
                  ((symbol-function 'seshat-reader--multipage-rerender-page)
                   (lambda (&rest _) (push 'rerender calls)))
                  ((symbol-function 'seshat-reader--center-page)
                   (lambda (&rest _) (push 'center calls))))
          (should seshat-reader-freeze-layout-during-minibuffer)
          (should-not (seshat-reader--refit-window (selected-window)))
          (should-not calls))))))

(ert-deftest seshat-reader-fit-window-test--schedule-refit-frozen-in-minibuffer ()
  "`window-minibuffer-p' 为真时 `--schedule-refit' 不产生 timer."
  (seshat-reader-fit-window-test--with-reader-buffer
    (let ((timers nil))
      (cl-letf (((symbol-function 'window-minibuffer-p)
                 (lambda (&rest _) t))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (&rest args) (push args timers) 'fake-timer))
                ((symbol-function 'seshat-reader--cancel-pending-refit)
                 (lambda () nil)))
        (should-not (seshat-reader--schedule-refit))
        (should-not timers)
        (should-not (timerp seshat-reader--resize-refit-timer))))))

(ert-deftest seshat-reader-fit-window-test--no-freeze-when-option-is-nil ()
  "`seshat-reader-freeze-layout-during-minibuffer' 为 nil 时不冻结。

断言 `--refit-window' 的调用序列（含实参）：先适配几何，再逐页重渲染，最后
居中，全部使用同一个窗口。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((calls nil)
            (window (selected-window)))
        (cl-letf (((symbol-function 'window-minibuffer-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'seshat-reader--multipage-page-numbers)
                   (lambda () '(1 2)))
                  ((symbol-function 'seshat-reader--apply-display-scale)
                   (lambda (w) (push (list 'scale w) calls)))
                  ((symbol-function 'seshat-reader--multipage-refit-page)
                   (lambda (page w) (push (list 'refit page w) calls)))
                  ((symbol-function 'seshat-reader--center-page)
                   (lambda (w) (push (list 'center w) calls))))
          (let ((seshat-reader-freeze-layout-during-minibuffer nil))
            (should-not (seshat-reader--layout-frozen-p))
            (seshat-reader--refit-window window)
            (should (equal (nreverse calls)
                           (list (list 'scale window)
                                 (list 'refit 1 window)
                                 (list 'refit 2 window)
                                 (list 'center window))))))))))

(ert-deftest seshat-reader-fit-window-test--after-minibuffer-exit-schedules-refit ()
  "退出 minibuffer 后按窗口 buffer 排到 `--run-pending-refit'.

断言 `run-with-idle-timer' 收到的完整实参：0 秒、一次性、函数是
`--run-pending-refit'、buffer 实参是被 minibuffer 挡住的 reader buffer。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((buffer (current-buffer))
            (timers nil))
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () nil))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (seconds repeat function &rest args)
                     (push (list seconds repeat function args) timers)
                     'fake-timer)))
          (seshat-reader--after-minibuffer-exit)
          (should (equal timers
                         (list (list 0 nil
                                     #'seshat-reader--run-pending-refit
                                     (list buffer))))))))))

(ert-deftest seshat-reader-fit-window-test--after-minibuffer-exit-prefers-mini-selected-window ()
  "恢复用的是 `minibuffer-selected-window' 的 buffer.

实测（Emacs 31.1）：`minibuffer-exit-hook' 执行时选中窗口**仍是** minibuffer
窗口、`minibuffer-depth' 仍是 1，所以「取选中窗口的 buffer」拿到的是
` *Minibuf-1*'。这里让当前 buffer 不是 reader buffer 而
`minibuffer-selected-window' 返回 reader 窗口，断言恢复仍然排到 reader buffer ——
即实现必须先看 `minibuffer-selected-window'。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (let ((reader-buffer (current-buffer))
          (reader-window (selected-window))
          (original (window-buffer (selected-window)))
          (timers nil))
      (unwind-protect
          (progn
            (set-window-buffer reader-window reader-buffer)
            (with-temp-buffer
              (cl-letf (((symbol-function 'minibuffer-selected-window)
                         (lambda () reader-window))
                        ((symbol-function 'run-with-idle-timer)
                         (lambda (seconds repeat function &rest args)
                           (push (list seconds repeat function args) timers)
                           'fake-timer)))
                (should-not (eq (current-buffer) reader-buffer))
                (seshat-reader--after-minibuffer-exit)
                (should (equal timers
                               (list (list 0 nil
                                           #'seshat-reader--run-pending-refit
                                           (list reader-buffer))))))))
        (set-window-buffer reader-window original)))))

(ert-deftest seshat-reader-fit-window-test--after-minibuffer-exit-skips-other-buffers ()
  "minibuffer 是从非 reader buffer 打开的时候不排任何 refit."
  (with-temp-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((timers nil))
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () nil))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (&rest args) (push args timers) 'fake-timer)))
          (should-not (derived-mode-p 'seshat-reader-mode))
          (should-not (seshat-reader--after-minibuffer-exit))
          (should-not timers))))))

(ert-deftest seshat-reader-fit-window-test--recenter-window-frozen-skips-display-scale ()
  "冻结时 `--recenter-window' 不改 spec 尺寸，只保留居中与 sync.

断言 `--apply-display-scale' 与 `--multipage-resize-spec'（真正写
`:width'/`:height' 的那一个）**零调用**、`--multipage-rerender-page' 零调用；
居中与 sync 仍以同一个窗口实参发生——这才是「几何冻结」（页面按旧尺寸显示、
底部被裁切），而不只是「不重渲染」。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((calls nil)
            ;; 拖拽判定必须为 nil，否则「跳过缩放」是拖拽分支做的，冻结判据被
            ;; 空跑通过。
            (seshat-reader--last-size-change-delta nil))
        (cl-letf (((symbol-function 'window-minibuffer-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'seshat-reader--apply-display-scale)
                   (lambda (&rest _) (push 'scale calls)))
                  ((symbol-function 'seshat-reader--multipage-resize-spec)
                   (lambda (&rest _) (push 'resize-spec calls)))
                  ((symbol-function 'seshat-reader--multipage-rerender-page)
                   (lambda (&rest _) (push 'rerender calls)))
                  ((symbol-function 'seshat-reader--center-page)
                   (lambda (&rest args) (push (cons 'center args) calls)))
                  ((symbol-function 'seshat-reader--multipage-sync)
                   (lambda (&rest args) (push (cons 'sync args) calls))))
          (should (seshat-reader--layout-frozen-p))
          (seshat-reader--recenter-window (selected-window))
          (should-not (memq 'scale calls))
          (should-not (memq 'resize-spec calls))
          (should-not (memq 'rerender calls))
          ;; 居中与 sync 仍然发生，且拿到的是同一个窗口（顺序：center → sync）。
          (should (equal (nreverse calls)
                         (list (list 'center (selected-window))
                               (list 'sync (selected-window))))))))))

(ert-deftest seshat-reader-fit-window-test--recenter-window-default-applies-display-scale ()
  "非冻结时 `--recenter-window' 仍适配几何（防回归）.

同一夹具、同一 `window-minibuffer-p'（返回 nil，即 minibuffer 未激活），只把
冻结开关留在默认值：此时 `--apply-display-scale' 必须被调用一次，且顺序是
scale → center → sync。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((calls nil)
            (seshat-reader--last-size-change-delta nil))
        (cl-letf (((symbol-function 'window-minibuffer-p)
                   (lambda (&rest _) nil))
                  ((symbol-function 'seshat-reader--apply-display-scale)
                   (lambda (&rest args) (push (cons 'scale args) calls)))
                  ((symbol-function 'seshat-reader--center-page)
                   (lambda (&rest args) (push (cons 'center args) calls)))
                  ((symbol-function 'seshat-reader--multipage-sync)
                   (lambda (&rest args) (push (cons 'sync args) calls))))
          (should seshat-reader-freeze-layout-during-minibuffer)
          (should-not (seshat-reader--layout-frozen-p))
          (seshat-reader--recenter-window (selected-window))
          (should (equal (nreverse calls)
                         (list (list 'scale (selected-window))
                               (list 'center (selected-window))
                               (list 'sync (selected-window))))))))))

(ert-deftest seshat-reader-fit-window-test--after-minibuffer-exit-gated-by-option ()
  "开关为 nil 时 `--after-minibuffer-exit' 不排任何 refit.

夹具里确实有一个显示 reader buffer 的窗口、且 `minibuffer-selected-window'
桩成那个窗口（主路径可用），否则「零调用」可能是空跑通过。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((timers nil)
            (seshat-reader-freeze-layout-during-minibuffer nil))
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () (selected-window)))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (&rest args) (push args timers) 'fake-timer)))
          ;; 前提自检：确实是 reader buffer 且有窗口显示它。
          (should (derived-mode-p 'seshat-reader-mode))
          (should (eq (window-buffer (selected-window)) (current-buffer)))
          (should-not seshat-reader-freeze-layout-during-minibuffer)
          (should-not (seshat-reader--after-minibuffer-exit))
          (should-not timers))))))

(ert-deftest seshat-reader-fit-window-test--after-minibuffer-exit-falls-back-to-all-frames ()
  "`minibuffer-selected-window' 为 nil 时靠全 frame 窗口扫描找到 reader buffer.

同时把 `selected-window' 桩成 minibuffer 窗口，复现「hook 内 selected window
仍是 mini window」这一前提：实现若退回 `(selected-window)' 取 buffer 就只能拿到
` *Minibuf-1*'，本用例会红。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((buffer (current-buffer))
            (timers nil)
            (mini (minibuffer-window)))
        (should (windowp mini))
        (should (window-minibuffer-p mini))
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () nil))
                  ((symbol-function 'selected-window)
                   (lambda () mini))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (seconds repeat function &rest args)
                     (push (list seconds repeat function args) timers)
                     'fake-timer)))
          ;; 前提自检：selected-window 是 mini window，且它不显示 reader buffer。
          (should (window-minibuffer-p (selected-window)))
          (should-not (eq (window-buffer (selected-window)) buffer))
          (should seshat-reader-freeze-layout-during-minibuffer)
          (seshat-reader--after-minibuffer-exit)
          (should (equal timers
                         (list (list 0 nil
                                     #'seshat-reader--run-pending-refit
                                     (list buffer))))))))))

(ert-deftest seshat-reader-fit-window-test--after-minibuffer-exit-dedupes-buffer ()
  "同一 reader buffer 显示在两个窗口时只排一次 idle refit.

`--run-pending-refit' 自己会遍历该 buffer 的所有窗口，按 buffer 去重是契约。"
  (seshat-reader-fit-window-test--with-reader-buffer
    (seshat-reader-fit-window-test--with-window-showing
      (let ((buffer (current-buffer))
            (timers nil)
            (second nil))
        (unwind-protect
            (progn
              (setq second (split-window (selected-window)))
              (set-window-buffer second buffer)
              ;; 前提自检：两个窗口都显示同一个 reader buffer。
              (should (eq (window-buffer (selected-window)) buffer))
              (should (eq (window-buffer second) buffer))
              (should (>= (length (window-list (selected-frame) 'nomini)) 2))
              (cl-letf (((symbol-function 'minibuffer-selected-window)
                         (lambda () (selected-window)))
                        ((symbol-function 'run-with-idle-timer)
                         (lambda (seconds repeat function &rest args)
                           (push (list seconds repeat function args) timers)
                           'fake-timer)))
                (seshat-reader--after-minibuffer-exit)
                (should (= 1 (length timers)))
                (should (equal timers
                               (list (list 0 nil
                                           #'seshat-reader--run-pending-refit
                                           (list buffer)))))))
          (when (window-live-p second) (delete-window second)))))))

(provide 'seshat-reader-fit-window-test)
;;; seshat-reader-fit-window-test.el ends here
