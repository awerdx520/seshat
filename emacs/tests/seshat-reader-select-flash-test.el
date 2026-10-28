;;; seshat-reader-select-flash-test.el --- ERT tests for the selection flash  -*- lexical-binding: t; -*-

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

;; `seshat-reader-select--flash-selection'（框选松手后把选区矩形高亮闪一下）
;; 的 ERT 测试套件。
;;
;; 全部用例**不依赖动态模块、不依赖真实文档、不起真实定时器等待**：
;;
;;   - `run-at-time' 被桩替：记录调用时长并把「武装」交给真正的
;;     `run-at-time'（3600 秒后到期，测试进程内不会真正触发），因此
;;     `timerp' 判定与 `cancel-timer' 的取消链路都按真实语义运行；
;;   - `cancel-timer' 被桩替：记录取消并转调真正的 `cancel-timer'，避免
;;     残留 timer 在测试进程里乱跑；
;;   - `seshat-reader-select--redraw-highlights' 被桩替：只记录「重投被
;;     调用」，从而与动态模块是否加载、是否真的画出高亮解耦；
;;   - 定时器回调不等待真实时长，而是取出 `run-at-time' 桩捕获的回调直接
;;     `funcall'，断言「清空 `--flash-rects' + 再重投一次」。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader-select)

(defvar seshat-reader-select-flash-test--last-timer-function nil
  "最近一次被 `run-at-time' 桩捕获的回调函数.
定时器回调用例直接调用它，以代替真实等待 `flash-duration' 秒。")

(defvar seshat-reader-select-flash-test--armed-timers nil
  "本次用例经 `run-at-time' 桩武装的全部真实 timer.
由 `--with-clean-timer' 在用例结束时统一取消。之所以要在武装时记录：
`seshat-reader-select--flash-timer' 是 **buffer-local**，`with-temp-buffer'
结束后 buffer 被 kill、局部绑定随之消失，无法再按变量取到 timer 对象。")

(defmacro seshat-reader-select-flash-test--with-stubs (state &rest body)
  "在 `run-at-time' / `cancel-timer' / 重投函数被桩替的环境中求值 BODY.
STATE 是 (LIST) 形态的 cons 表达式，`(car STATE)' 按调用顺序收集
\(`push' 后需 `nreverse' 取正序）三类事件：

  `redraw'        重投函数 `seshat-reader-select--redraw-highlights' 被调用
  `(at SECONDS)'  `run-at-time' 被调用，SECONDS 为传入的时长
  `(cancel TIMER)' `cancel-timer' 被调用

`run-at-time' 桩把回调存进
`seshat-reader-select-flash-test--last-timer-function'，并把返回的真实 timer
记入 `seshat-reader-select-flash-test--armed-timers'（供用例结束时统一取消），
同时以 3600 秒的延迟转调真正的 `run-at-time'（测试期间不会触发）。"
  (declare (indent 1) (debug t))
  (let ((var (make-symbol "state"))
        (real-run (make-symbol "real-run"))
        (real-cancel (make-symbol "real-cancel")))
    `(let* ((,var ,state)
            (,real-run (symbol-function 'run-at-time))
            (,real-cancel (symbol-function 'cancel-timer))
            (seshat-reader-select-flash-test--last-timer-function nil))
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (seconds _repeat function &rest args)
                    (push (list 'at seconds) (car ,var))
                    (setq seshat-reader-select-flash-test--last-timer-function
                          function)
                    (let ((timer (apply ,real-run 3600 nil function args)))
                      (push timer seshat-reader-select-flash-test--armed-timers)
                      timer)))
                 ((symbol-function 'cancel-timer)
                  (lambda (timer)
                    (push (list 'cancel timer) (car ,var))
                    (funcall ,real-cancel timer)))
                 ((symbol-function 'seshat-reader-select--redraw-highlights)
                  (lambda () (push 'redraw (car ,var)) nil)))
         ,@body))))

(defmacro seshat-reader-select-flash-test--with-clean-timer (&rest body)
  "求值 BODY，结束后取消本次用例武装的全部真实 timer.
用例会武装真实 timer（3600 秒后到期）；`seshat-reader-select--flash-timer'
是 **buffer-local**，`with-temp-buffer' 结束后 buffer 被 kill、局部绑定随之
消失，故不能按变量取 timer 对象，改由 `run-at-time' 桩把武装的 timer 记入
`seshat-reader-select-flash-test--armed-timers'，本宏逐个取消以保持测试进程
干净（残留的 timer 虽然不会触发，仍是垃圾）。"
  (declare (indent 0) (debug t))
  `(let ((seshat-reader-select-flash-test--armed-timers nil))
     (unwind-protect
         (progn ,@body)
       (dolist (timer seshat-reader-select-flash-test--armed-timers)
         (when (timerp timer)
           (ignore-errors (cancel-timer timer))))
       (setq seshat-reader-select-flash-test--armed-timers nil))))

(ert-deftest seshat-reader-select-flash-test--default-duration ()
  "`seshat-reader-select-flash-duration' 默认 2.0 秒，`:type' 为 number."
  (should (= 2.0 seshat-reader-select-flash-duration))
  (should (eq (get 'seshat-reader-select-flash-duration 'custom-type) 'number)))

(ert-deftest seshat-reader-select-flash-test--sets-rects-and-redraws ()
  "闪现设置 buffer-local 矩形、调用重投并按 defcustom 武装定时器."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (with-temp-buffer
          (let ((seshat-reader-select-flash-duration 3.5))
            (seshat-reader-select--flash-selection 3 '(10.0 20.0 110.0 40.0))
            ;; 矩形按 (PAGE X0 Y0 X1 Y1) 存入 buffer-local 变量
            (should (equal seshat-reader-select--flash-rects
                           '((3 10.0 20.0 110.0 40.0))))
            (should (local-variable-p 'seshat-reader-select--flash-rects))
            ;; 先重投，再武装定时器；时长等于 defcustom 的当前值
            (should (equal (nreverse (car state))
                           '(redraw (at 3.5))))
            (should (timerp seshat-reader-select--flash-timer))))))))

(ert-deftest seshat-reader-select-flash-test--cancels-previous-timer ()
  "同一 buffer 内连续两次拖选：第二次取消第一次武装的 timer，只保留最新一次."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (with-temp-buffer
          (seshat-reader-select--flash-selection 1 '(1.0 1.0 2.0 2.0))
          (let ((first-timer seshat-reader-select--flash-timer))
            (should (timerp first-timer))
            ;; timer 与矩形一样是 buffer-local（不是全局 defvar）
            (should (local-variable-p 'seshat-reader-select--flash-timer))
            (setcar state nil)
            (seshat-reader-select--flash-selection 2 '(3.0 3.0 4.0 4.0))
            (let ((events (nreverse (car state))))
              ;; 事件顺序：取消旧 timer → 重投 → 武装新 timer
              (should (equal (caar events) 'cancel))
              (should (eq (nth 1 (car events)) first-timer))
              (should (eq (nth 1 events) 'redraw))
              (should (equal (nth 2 events) '(at 2.0))))
            (should (equal seshat-reader-select--flash-rects
                           '((2 3.0 3.0 4.0 4.0))))
            (should (timerp seshat-reader-select--flash-timer))
            (should-not (eq first-timer seshat-reader-select--flash-timer))))))))

(ert-deftest seshat-reader-select-flash-test--timers-are-per-buffer ()
  "两个 buffer 各留自己的 timer 与矩形：后一次框选不取消前一个 buffer 的 timer."
  (let ((state (list nil))
        (buf-a (generate-new-buffer " *seshat-flash-a*"))
        (buf-b (generate-new-buffer " *seshat-flash-b*")))
    (unwind-protect
        (seshat-reader-select-flash-test--with-clean-timer
          (seshat-reader-select-flash-test--with-stubs state
            (with-current-buffer buf-a
              (seshat-reader-select--flash-selection 1 '(1.0 1.0 2.0 2.0)))
            (with-current-buffer buf-b
              (seshat-reader-select--flash-selection 2 '(3.0 3.0 4.0 4.0)))
            (let ((timer-a (buffer-local-value 'seshat-reader-select--flash-timer
                                               buf-a))
                  (timer-b (buffer-local-value 'seshat-reader-select--flash-timer
                                               buf-b)))
              (should (timerp timer-a))
              (should (timerp timer-b))
              (should-not (eq timer-a timer-b))
              ;; 无任何取消事件：第二个 buffer 的框选没动第一个的 timer
              (should-not (cl-some (lambda (event) (eq (car-safe event) 'cancel))
                                   (car state)))
              ;; 矩形也各归各的 buffer
              (should (equal (buffer-local-value
                              'seshat-reader-select--flash-rects buf-a)
                             '((1 1.0 1.0 2.0 2.0))))
              (should (equal (buffer-local-value
                              'seshat-reader-select--flash-rects buf-b)
                             '((2 3.0 3.0 4.0 4.0)))))))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

(ert-deftest seshat-reader-select-flash-test--disabled-by-zero-duration ()
  "`flash-duration' 为 0 时什么都不做：不设矩形、不重投、不武装定时器."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-stubs state
      (with-temp-buffer
        (let ((seshat-reader-select-flash-duration 0))
          (seshat-reader-select--flash-selection 1 '(1.0 1.0 2.0 2.0))
          (should-not seshat-reader-select--flash-rects)
          (should-not (car state))
          (should-not seshat-reader-select--flash-timer))))))

(ert-deftest seshat-reader-select-flash-test--invalid-rect-does-not-flash ()
  "非法矩形（宽或高为 0、页号非正）不闪：不设矩形、不重投、不武装定时器."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-stubs state
      (with-temp-buffer
        (dolist (case '((1 (1.0 1.0 1.0 5.0))   ; 宽为 0
                        (1 (1.0 1.0 5.0 1.0))   ; 高为 0
                        (0 (1.0 1.0 5.0 5.0))   ; 页号不是正数
                        (nil (1.0 1.0 5.0 5.0)) ; 页号缺失
                        (1 (1.0 1.0 5.0))       ; 坐标不足四个
                        (1 (1.0 1.0 5.0 "x")))) ; 坐标不是数字
          (apply #'seshat-reader-select--flash-selection case)
          (should-not seshat-reader-select--flash-rects)
          (should-not (car state))
          (should-not seshat-reader-select--flash-timer))))))

(ert-deftest seshat-reader-select-flash-test--timer-callback-clears-and-redraws ()
  "定时器回调执行后矩形被清空、重投被再次调用（无需等待真实时长）."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (with-temp-buffer
          (seshat-reader-select--flash-selection 4 '(5.0 5.0 50.0 50.0))
          (should (equal seshat-reader-select--flash-rects
                         '((4 5.0 5.0 50.0 50.0))))
          (let ((callback seshat-reader-select-flash-test--last-timer-function))
            (should (functionp callback))
            ;; 清空事件记录，只观察回调本身的效果
            (setcar state nil)
            (funcall callback)
            (should-not seshat-reader-select--flash-rects)
            (should (equal (nreverse (car state)) '(redraw)))
            (should-not seshat-reader-select--flash-timer)))))))

(ert-deftest seshat-reader-select-flash-test--callback-of-dead-buffer-is-ignored ()
  "定时器回调指向的缓冲区已死时不报错（用户已关闭文档）."
  (let ((state (list nil))
        (buffer nil)
        (callback nil))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (setq buffer (generate-new-buffer " *seshat-flash-test*"))
        (with-current-buffer buffer
          (seshat-reader-select--flash-selection 2 '(1.0 1.0 3.0 3.0)))
        (setq callback seshat-reader-select-flash-test--last-timer-function)
        (kill-buffer buffer)
        (setcar state nil)
        (should-not (funcall callback))
        ;; 缓冲区已死：既不重投也不报错
        (should-not (car state))))))

(ert-deftest seshat-reader-select-flash-test--multiple-rects-flash ()
  "多条矩形（按行合并后的选区）逐条写入 `--flash-rects'，只武装一个 timer."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (with-temp-buffer
          (seshat-reader-select--flash-selection
           5 '((10.0 20.0 110.0 30.0)
              (10.0 32.0 90.0 42.0)
              (10.0 44.0 60.0 54.0)))
          ;; 三条矩形各自带上页号，顺序与入参一致
          (should (equal seshat-reader-select--flash-rects
                         '((5 10.0 20.0 110.0 30.0)
                           (5 10.0 32.0 90.0 42.0)
                           (5 10.0 44.0 60.0 54.0))))
          (should (= 3 (length seshat-reader-select--flash-rects)))
          ;; 一次性重投 + 只武装一个 timer
          (should (equal (nreverse (car state))
                         '(redraw (at 2.0))))
          (should (timerp seshat-reader-select--flash-timer)))))))

(ert-deftest seshat-reader-select-flash-test--single-rect-falls-back ()
  "单矩形两种写法（裸四元组 / 只含一条的列表）等价，都只闪一条."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (with-temp-buffer
          (seshat-reader-select--flash-selection 2 '(1.0 2.0 3.0 4.0))
          (let ((from-bare seshat-reader-select--flash-rects))
            (seshat-reader-select--flash-selection 2 '((1.0 2.0 3.0 4.0)))
            (should (equal seshat-reader-select--flash-rects from-bare))
            (should (equal seshat-reader-select--flash-rects
                           '((2 1.0 2.0 3.0 4.0))))))))))

(ert-deftest seshat-reader-select-flash-test--invalid-rects-skipped ()
  "多矩形里逐条校验：非法条目跳过，合法条目照常闪现；全非法则不闪."
  (let ((state (list nil)))
    (seshat-reader-select-flash-test--with-clean-timer
      (seshat-reader-select-flash-test--with-stubs state
        (with-temp-buffer
          (seshat-reader-select--flash-selection
           3 '((1.0 2.0 3.0 4.0)     ; 合法
              (1.0 2.0 1.0 4.0)     ; 宽为 0 → 跳过
              (5.0 6.0 7.0)         ; 坐标不足 → 跳过
              (8.0 9.0 10.0 11.0))) ; 合法
          (should (equal seshat-reader-select--flash-rects
                         '((3 1.0 2.0 3.0 4.0)
                           (3 8.0 9.0 10.0 11.0))))
          ;; 再闪一次：整批非法 → 全部跳过，状态不变、不武装新 timer
          (setcar state nil)
          (with-temp-buffer
            (seshat-reader-select-flash-test--with-stubs state
              (seshat-reader-select--flash-selection
               3 '((1.0 2.0 1.0 4.0) (5.0 6.0 7.0)))
              (should-not seshat-reader-select--flash-rects)
              (should-not (car state))
              (should-not seshat-reader-select--flash-timer))))))))

(provide 'seshat-reader-select-flash-test)
;;; seshat-reader-select-flash-test.el ends here
