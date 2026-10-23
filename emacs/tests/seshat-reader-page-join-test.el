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

;; `seshat-reader' 跨页衔接（M12 T8a/T8b）的 ERT 测试套件：页面 image
;; spec 缓存、strip 行渲染、居中 line-prefix 承载结构、vscroll 上限语义、
;; 翻页落点（页顶/页底）与页首谓词。
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
;; 纪律：**不触网、不碰真实 PDF、不依赖真实窗口**。页面 image spec 用
;; `(image :type pbm :data ...)' 形态自行构造，窗口与 overlay 访问函数一律用
;; `cl-letf' 桩替，因此全部用例可在 batch 下稳定运行。
;;
;; 本套件全部用例都不需要外部包，故不使用 `skip-unless' / `ert-skip'——
;; skipped 必须恒为 0。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)

;;; 辅助函数

(defun seshat-reader-page-join-test--spec (width height)
  "构造 WIDTH x HEIGHT 的假 image spec，形态与 C 侧 `create-image' 一致。"
  (list 'image :type 'pbm :data "" :width width :height height :scale 1))

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

;;; 2. 页面 image spec 缓存

(ert-deftest seshat-reader-page-join-test--remember-spec ()
  "记住当前页 spec：写入、同页去重、超出上限丢最旧。"
  (with-temp-buffer
    (seshat-reader-page-join-test--reset)
    (let* ((spec (seshat-reader-page-join-test--spec 100 200))
           (overlay (make-overlay (point-min) (point-max))))
      (overlay-put overlay 'display spec)
      (cl-letf (((symbol-function 'seshat-reader-current-doc-overlay)
                 (lambda (&optional _window) overlay))
                ((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) 3)))
        (seshat-reader--remember-current-page-spec)
        (should (equal spec (alist-get 3 seshat-reader--page-image-specs)))
        (should (= 1 (length seshat-reader--page-image-specs)))
        ;; 同页重复记忆不得刷爆缓存
        (seshat-reader--remember-current-page-spec)
        (should (= 1 (length seshat-reader--page-image-specs)))
        ;; 再记 5 个不同的页 → 只保留最近 5 条，最旧的页 3 被丢弃
        (dolist (page '(4 5 6 7 8))
          (let ((current-page page))
            (cl-letf (((symbol-function 'seshat-reader-current-doc-pagenumber)
                       (lambda (&optional _window) current-page)))
              (seshat-reader--remember-current-page-spec))))
        (should (= 5 (length seshat-reader--page-image-specs)))
        (should (= 8 (car (car seshat-reader--page-image-specs))))
        (should-not (alist-get 3 seshat-reader--page-image-specs))))))

(ert-deftest seshat-reader-page-join-test--remember-spec-no-overlay ()
  "无 overlay（无 display 属性）时缓存保持不变。"
  (with-temp-buffer
    (seshat-reader-page-join-test--reset)
    (cl-letf (((symbol-function 'seshat-reader-current-doc-overlay)
               (lambda (&optional _window) nil))
              ((symbol-function 'seshat-reader-current-doc-pagenumber)
               (lambda (&optional _window) 2)))
      (seshat-reader--remember-current-page-spec)
      (should-not seshat-reader--page-image-specs))))

;;; 3. strip 行渲染

(ert-deftest seshat-reader-page-join-test--strip-inserted ()
  "有上一页 spec 时插入一行 strip，display 为 slice 包装形态。"
  (with-temp-buffer
    (seshat-reader-page-join-test--reset)
    (let ((spec (seshat-reader-page-join-test--spec 300 400))
          (seshat-reader-page-join-lines 1))
      (setq seshat-reader--page-image-specs (list (cons 1 spec)))
      (cl-letf (((symbol-function 'frame-char-height)
                 (lambda (&optional _frame) 20))
                ((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) 2)))
        (seshat-reader--update-join-strip)
        (should (= 2 (buffer-size)))
        (should (= 2 (line-number-at-pos (point-max))))
        (should (= 20 seshat-reader--join-strip-height))
        (let ((display (get-text-property (point-min) 'display)))
          ;; display = ((slice 0 Y W H) IMAGE-SPEC)，Y = 图高 - strip 高
          (should (eq 'slice (car (car display))))
          (should (equal '(slice 0 380 300 20) (car display)))
          (should (equal spec (car (cdr display)))))
        ;; strip 行行尾换行带 line-height，行内字符不带
        (should (equal t (get-text-property 2 'line-height)))
        (should-not (get-text-property 1 'line-height))
        ;; 幂等：重复调用不叠加
        (seshat-reader--update-join-strip)
        (should (= 2 (buffer-size)))
        (should (= 20 seshat-reader--join-strip-height))))))

(ert-deftest seshat-reader-page-join-test--strip-clamped ()
  "strip 高度超过图高时被夹到图高。"
  (with-temp-buffer
    (seshat-reader-page-join-test--reset)
    (let ((spec (seshat-reader-page-join-test--spec 300 400))
          (seshat-reader-page-join-lines 100))
      (setq seshat-reader--page-image-specs (list (cons 1 spec)))
      (cl-letf (((symbol-function 'frame-char-height)
                 (lambda (&optional _frame) 20))
                ((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) 2)))
        (seshat-reader--update-join-strip)
        (should (= 400 seshat-reader--join-strip-height))
        (should (equal '(slice 0 0 300 400)
                       (car (get-text-property (point-min) 'display))))))))

(ert-deftest seshat-reader-page-join-test--strip-absent ()
  "无上一页 spec / 首页 / 开关为 0 时都没有 strip 行。"
  (with-temp-buffer
    (seshat-reader-page-join-test--reset)
    (let ((spec (seshat-reader-page-join-test--spec 300 400))
          (seshat-reader-page-join-lines 1)
          (page 2))
      (cl-letf (((symbol-function 'frame-char-height)
                 (lambda (&optional _frame) 20))
                ((symbol-function 'seshat-reader-current-doc-pagenumber)
                 (lambda (&optional _window) page)))
        ;; 无上一页 spec
        (seshat-reader--update-join-strip)
        (should (= 0 (buffer-size)))
        (should (= 0 seshat-reader--join-strip-height))
        ;; 首页（无上一页）
        (setq seshat-reader--page-image-specs (list (cons 1 spec))
              page 1)
        (seshat-reader--update-join-strip)
        (should (= 0 (buffer-size)))
        ;; 开关为 0
        (setq page 2)
        (let ((seshat-reader-page-join-lines 0))
          (seshat-reader--update-join-strip))
        (should (= 0 (buffer-size)))
        (should (= 0 seshat-reader--join-strip-height))
        ;; 先有 strip，再关掉开关 → strip 被删除
        (seshat-reader--update-join-strip)
        (should (= 2 (buffer-size)))
        (let ((seshat-reader-page-join-lines 0))
          (seshat-reader--update-join-strip))
        (should (= 0 (buffer-size)))
        (should (= 0 seshat-reader--join-strip-height))))))

;;; 4. vscroll 上限包含 strip 高度

(ert-deftest seshat-reader-page-join-test--vscroll-max ()
  "`seshat-reader--set-window-vscroll' 的上限 = 图高 + strip 高 - 窗高。"
  (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
             (lambda (&optional _window) (cons 600 1000)))
            ((symbol-function 'window-body-height)
             (lambda (&optional _window pixels-p) (if pixels-p 700 40)))
            ((symbol-function 'set-window-vscroll)
             (lambda (_window vscroll &optional _pixels-p) vscroll)))
    ;; 无 strip：与改造前语义一致
    (let ((seshat-reader--join-strip-height 0))
      (should (= 300 (seshat-reader--set-window-vscroll nil 9999 t))))
    ;; 有 strip：上限增加 strip 高度
    (let ((seshat-reader--join-strip-height 120))
      (should (= 420 (seshat-reader--set-window-vscroll nil 9999 t))))
    ;; 按行滚动的换算路径同样生效（pixel-per-col = 700/40 = 17.5）
    (let ((seshat-reader--join-strip-height 120))
      (should (= 24 (seshat-reader--set-window-vscroll nil 9999))))))

(ert-deftest seshat-reader-page-join-test--vscroll-max-not-negative ()
  "页高小于窗高时上限为 0，不得为负。"
  (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
             (lambda (&optional _window) (cons 600 500)))
            ((symbol-function 'window-body-height)
             (lambda (&optional _window pixels-p) (if pixels-p 700 40)))
            ((symbol-function 'set-window-vscroll)
             (lambda (_window vscroll &optional _pixels-p) vscroll)))
    (let ((seshat-reader--join-strip-height 120))
      (should (= 0 (seshat-reader--set-window-vscroll nil 9999 t))))))

(ert-deftest seshat-reader-page-join-test--vscroll-no-clamp-pixels ()
  "未触发上限时像素值原样下发（乘一次 pixel-per-col，而非两次）.

上限 = 图高 2000 + strip 0 - 窗高 1000 = 1000，传入的 50 远低于上限，故
`set-window-vscroll' 收到的像素值必须**就是 50**。若实现把
pixel-per-col 多乘一次（50 × 25 = 1250），会先被夹到 1000，断言即可暴露。"
  (let ((calls nil)
        (seshat-reader--join-strip-height 0))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons 600 2000)))
              ;; pixel-per-col = 1000/40 = 25（整数，便于换算断言）
              ((symbol-function 'window-body-height)
               (lambda (&optional _window pixels-p) (if pixels-p 1000 40)))
              ((symbol-function 'set-window-vscroll)
               (lambda (_window vscroll &optional pixels-p)
                 (push (list vscroll pixels-p) calls)
                 vscroll)))
      (should (= 50 (seshat-reader--set-window-vscroll nil 50 t)))
      (should (equal (car calls) '(50 t))))))

(ert-deftest seshat-reader-page-join-test--vscroll-no-clamp-lines ()
  "未触发上限时行数只乘一次 pixel-per-col：2 行 → 50 像素（ppc=25）.

返回值与下发值都应是**行数 2**（`pixels-p' 为 nil 的契约）；换算回像素即
2 × 25 = 50。若实现把像素值当行数下发（乘两次的典型症状），收到的会是
50 行，第一条 `equal' 断言直接失败。"
  (let ((calls nil)
        (seshat-reader--join-strip-height 0))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons 600 2000)))
              ((symbol-function 'window-body-height)
               (lambda (&optional _window pixels-p) (if pixels-p 1000 40)))
              ((symbol-function 'set-window-vscroll)
               (lambda (_window vscroll &optional pixels-p)
                 (push (list vscroll pixels-p) calls)
                 vscroll)))
      (should (= 2 (seshat-reader--set-window-vscroll nil 2)))
      (should (equal (car calls) '(2 nil)))
      ;; 收到的行数换算回像素 = 2 × 25 = 50（恰好一次换算）
      (should (= 50 (* (nth 0 (car calls)) 25))))))

;;; 5. line-prefix 承载结构

(ert-deftest seshat-reader-page-join-test--center-overlay-prefix ()
  "line-prefix 由 buffer 级 center overlay 承载，doc overlay 不再承载。"
  (with-temp-buffer
    (seshat-reader-page-join-test--reset)
    (setq seshat-reader--center-overlay nil)
    (let* ((spec (seshat-reader-page-join-test--spec 500 700))
           (overlay (make-overlay (point-min) (point-max))))
      (overlay-put overlay 'display spec)
      (cl-letf (((symbol-function 'seshat-reader-current-doc-overlay)
                 (lambda (&optional _window) overlay))
                ((symbol-function 'window-body-width)
                 (lambda (&optional _window pixels-p)
                   (if pixels-p 800 80)))
                ((symbol-function 'set-window-hscroll)
                 (lambda (&optional _window _ncol) 0))
                ((symbol-function 'window-hscroll)
                 (lambda (&optional _window) 0)))
        (seshat-reader--center-page)
        ;; 契约变更（2026-10-23）：页面能完整放下时居中改由 before-string 承担，
        ;; 两个 overlay 都不再写 `line-prefix'（实测 line-prefix + hscroll 在窗口
        ;; 变窄后的第一帧恒错位 −524px），因此也不再需要 buffer 级 center overlay。
        ;; 这里钉住：before-string 挂在页面 overlay 上并引用正在显示的 image spec
        ;; （`eq'），center overlay 缺失或 line-prefix 为 nil，`--get-prefix-width'
        ;; 因此返回 0。
        (should-not (and (overlayp seshat-reader--center-overlay)
                         (overlay-get seshat-reader--center-overlay
                                      'line-prefix)))
        (should-not (overlay-get overlay 'line-prefix))
        (let* ((before (overlay-get overlay 'before-string))
               (display (and (stringp before)
                             (get-text-property 0 'display before)))
               (align (and (consp display) (plist-get (cdr display) :align-to)))
               (form (and (consp align) (eq (car align) '+)
                          (nth 2 align))))
          (should (consp form))
          (should (eq (cdr form) spec)))
        (should (= 0 (seshat-reader--get-prefix-width)))))))

;;; 5b. 回归修复：默认关闭 strip、居中兜底、窗口尺寸钩子

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
`condition-case'（由 T3 的新用例 ⑫/⑬ 覆盖）。"
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

(ert-deftest seshat-reader-page-join-test--prefix-width-zero ()
  "center overlay 不存在或 line-prefix 为 nil 时前缀宽度是数字 0。"
  (with-temp-buffer
    (let ((seshat-reader--center-overlay nil))
      ;; 连 doc overlay 都没有：不得报错，返回 0
      (cl-letf (((symbol-function 'seshat-reader-current-doc-overlay)
                 (lambda (&optional _window) nil)))
        (should (numberp (seshat-reader--get-prefix-width)))
        (should (= 0 (seshat-reader--get-prefix-width))))
      ;; doc overlay 存在但没有 line-prefix：同样是 0
      (let ((overlay (make-overlay (point-min) (point-max))))
        (cl-letf (((symbol-function 'seshat-reader-current-doc-overlay)
                   (lambda (&optional _window) overlay)))
          (should (numberp (seshat-reader--get-prefix-width)))
          (should (= 0 (seshat-reader--get-prefix-width))))))))

(ert-deftest seshat-reader-page-join-test--vscroll-nil-image-size ()
  "页面尺寸未知时 `seshat-reader--set-window-vscroll' 不报错，按 0 处理。"
  (let ((calls nil))
    (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
               (lambda (&optional _window) (cons nil nil)))
              ((symbol-function 'window-body-height)
               (lambda (&optional _window pixels-p) (if pixels-p 700 40)))
              ((symbol-function 'set-window-vscroll)
               (lambda (_window vscroll &optional pixels-p)
                 (push (list vscroll pixels-p) calls)
                 vscroll)))
      (should (= 0 (seshat-reader--set-window-vscroll nil 100 t)))
      (should (equal '((0 t)) calls)))))

(ert-deftest seshat-reader-page-join-test--center-page-fallback ()
  "页面宽度未知时 `--center-page' 清旧前缀并把水平滚动归零，而非静默放弃。"
  (with-temp-buffer
    (let ((seshat-reader--center-overlay nil)
          (hscroll-calls nil)
          (plain-calls nil))
      (let ((overlay (make-overlay (point-min) (point-max))))
        (overlay-put overlay 'line-prefix '(space :width (300)))
        (cl-letf (((symbol-function 'seshat-reader-current-doc-overlay)
                   (lambda (&optional _window) overlay))
                  ((symbol-function 'seshat-reader--get-current-doc-image-size)
                   (lambda (&optional _window) (cons nil nil)))
                  ((symbol-function 'window-body-width)
                   (lambda (&optional _window pixels-p) (if pixels-p 800 80)))
                  ((symbol-function 'seshat-reader--set-window-hscroll)
                   (lambda (_window ncol &optional _unconstrained)
                     (push ncol hscroll-calls) 0))
                  ((symbol-function 'set-window-hscroll)
                   (lambda (_window ncol) (push ncol plain-calls) 0)))
          (seshat-reader--center-page)
          (should-not (overlay-get overlay 'line-prefix))
          (should (equal '(0) hscroll-calls))
          (should (equal '(0) plain-calls)))))))

;;; 6. 翻页落点语义（T8b）

(defun seshat-reader-page-join-test--window-stubs (image-height window-height
                                                               vscroll-cell)
  "返回窗口相关桩函数（页高 IMAGE-HEIGHT、窗高 WINDOW-HEIGHT）。

VSCROLL-CELL 是承载当前 vscroll（像素）的 cons cell。返回值为三个函数：
取页尺寸、取窗体高、取 vscroll。"
  (list (lambda (&optional _window) (cons 600 image-height))
        (lambda (&optional _window pixels-p)
          (if pixels-p window-height (round window-height 17.5)))
        (lambda (&optional _window pixels-p)
          (if pixels-p (car vscroll-cell) (/ (car vscroll-cell) 17.5)))))

(ert-deftest seshat-reader-page-join-test--at-page-top-p ()
  "页首谓词以 strip 高度为界：vscroll <= H_s 即页面开头可见。"
  (let ((cell (list 0))
        (seshat-reader--join-strip-height 120))
    (cl-destructuring-bind (image-fn height-fn vscroll-fn)
        (seshat-reader-page-join-test--window-stubs 1000 700 cell)
      (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
                 image-fn)
                ((symbol-function 'window-body-height) height-fn)
                ((symbol-function 'window-vscroll) vscroll-fn))
        (setcar cell 0)
        (should (seshat-reader--at-page-top-p))
        (setcar cell 120)
        (should (seshat-reader--at-page-top-p))
        (setcar cell 121)
        (should-not (seshat-reader--at-page-top-p))
        ;; 关闭开关：仅 vscroll = 0 才算页首
        (let ((seshat-reader--join-strip-height 0))
          (setcar cell 0)
          (should (seshat-reader--at-page-top-p))
          (setcar cell 1)
          (should-not (seshat-reader--at-page-top-p)))))))

(ert-deftest seshat-reader-page-join-test--page-max-vscroll-pixels ()
  "页底落点 = 图高 + strip 高 - 窗高，且不为负。"
  (let ((cell (list 0)))
    (cl-destructuring-bind (image-fn height-fn vscroll-fn)
        (seshat-reader-page-join-test--window-stubs 1000 700 cell)
      (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
                 image-fn)
                ((symbol-function 'window-body-height) height-fn)
                ((symbol-function 'window-vscroll) vscroll-fn))
        (let ((seshat-reader--join-strip-height 0))
          (should (= 300 (seshat-reader--page-max-vscroll-pixels))))
        (let ((seshat-reader--join-strip-height 120))
          (should (= 420 (seshat-reader--page-max-vscroll-pixels))))))
    ;; 图高 < 窗高：返回 0
    (cl-destructuring-bind (image-fn height-fn vscroll-fn)
        (seshat-reader-page-join-test--window-stubs 500 700 cell)
      (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
                 image-fn)
                ((symbol-function 'window-body-height) height-fn)
                ((symbol-function 'window-vscroll) vscroll-fn))
        (let ((seshat-reader--join-strip-height 120))
          (should (= 0 (seshat-reader--page-max-vscroll-pixels))))))))

(ert-deftest seshat-reader-page-join-test--set-page-top-bottom ()
  "页顶落点为 H_s、页底落点为 max-vscroll，均按像素下发。"
  (let ((calls nil)
        (cell (list 0)))
    (cl-destructuring-bind (image-fn height-fn vscroll-fn)
        (seshat-reader-page-join-test--window-stubs 1000 700 cell)
      (cl-letf (((symbol-function 'seshat-reader--get-current-doc-image-size)
                 image-fn)
                ((symbol-function 'window-body-height) height-fn)
                ((symbol-function 'window-vscroll) vscroll-fn)
                ((symbol-function 'seshat-reader--set-window-vscroll)
                 (lambda (_window vscroll &optional pixels-p)
                   (push (list vscroll pixels-p) calls)
                   vscroll)))
        (let ((seshat-reader--join-strip-height 120))
          (seshat-reader--set-page-top)
          (should (equal '((120 t)) calls))
          (setq calls nil)
          (seshat-reader--set-page-bottom)
          (should (equal '((420 t)) calls)))
        ;; 关闭开关：页顶 0、页底 300（= 图高 - 窗高，与改造前一致）
        (let ((seshat-reader--join-strip-height 0))
          (setq calls nil)
          (seshat-reader--set-page-top)
          (should (equal '((0 t)) calls))
          (setq calls nil)
          (seshat-reader--set-page-bottom)
          (should (equal '((300 t)) calls)))))))

(ert-deftest seshat-reader-page-join-test--set-page-top-when-joined ()
  "关闭开关时，原本不碰 vscroll 的缩放/旋转命令保持惰性。"
  (let ((calls nil))
    (cl-letf (((symbol-function 'seshat-reader--set-window-vscroll)
               (lambda (_window vscroll &optional pixels-p)
                 (push (list vscroll pixels-p) calls)
                 vscroll)))
      (let ((seshat-reader--join-strip-height 0))
        (seshat-reader--set-page-top-when-joined)
        (should-not calls))
      (let ((seshat-reader--join-strip-height 120))
        (seshat-reader--set-page-top-when-joined)
        (should (equal '((120 t)) calls))))))

(ert-deftest seshat-reader-page-join-test--next-page-landing ()
  "next-page 落点为 vscroll = 0（strip 顶对齐窗口顶）。"
  (let ((calls nil)
        (cell (list 0)))
    (cl-letf (((symbol-function 'seshat-reader--remember-current-page-spec)
               #'ignore)
              ((symbol-function 'seshat-reader-dyn--next-page)
               (lambda (&rest _) t))
              ((symbol-function 'seshat-reader--update-join-strip) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'seshat-reader--set-window-vscroll)
               (lambda (_window vscroll &optional pixels-p)
                 (push (list vscroll pixels-p) calls)
                 vscroll)))
      (let ((seshat-reader--join-strip-height 120))
        (should (seshat-reader--non-queue-next-page))
        (should (equal '((0 nil)) calls))))))

(ert-deftest seshat-reader-page-join-test--previous-page-landing ()
  "previous-page 落点为 max-vscroll（含 strip 高度）。"
  (let ((calls nil)
        (cell (list 0)))
    (cl-destructuring-bind (image-fn height-fn vscroll-fn)
        (seshat-reader-page-join-test--window-stubs 1000 700 cell)
      (cl-letf (((symbol-function 'seshat-reader--remember-current-page-spec)
                 #'ignore)
                ((symbol-function 'seshat-reader-dyn--prev-page)
                 (lambda (&rest _) t))
                ((symbol-function 'seshat-reader--update-join-strip) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore)
                ((symbol-function 'seshat-reader--get-current-doc-image-size)
                 image-fn)
                ((symbol-function 'window-body-height) height-fn)
                ((symbol-function 'window-vscroll) vscroll-fn)
                ((symbol-function 'seshat-reader--set-window-vscroll)
                 (lambda (_window vscroll &optional pixels-p)
                   (push (list vscroll pixels-p) calls)
                   vscroll)))
        (let ((seshat-reader--join-strip-height 120))
          (should (seshat-reader--non-queue-previous-page))
          (should (equal '((420 t)) calls)))))))

(provide 'seshat-reader-page-join-test)
;;; seshat-reader-page-join-test.el ends here.
