;;; seshat-reader-etaf-test.el --- Tests for seshat-reader-etaf  -*- lexical-binding: t; -*-

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

;; `seshat-reader-etaf' 渲染层与三态降级（`enabled'=nil / `require'
;; 失败 / 渲染抛错）的 ERT 测试套件。它把 M11.9 的 T4–T6 batch 断言固化为
;; 可重复用例：items 合成、动作命令的取值路径、ETAF 面板文本、gt 渲染对象
;; 的隐藏中转配置、以及面板 `:keys' 注册。
;;
;; 运行方式（在仓库根目录执行）。下条命令**可直接复制运行**：其中写作
;; `"emacs"' 的是 Emacs 可执行文件名，加引号只为让 checkdoc 的专有名词检查
;; 予以忽略，shell 语义与不带引号完全一致。除本仓库两个 `-L' 外，还必须把
;; ETAF 四仓库（及其各自 `lisp/' 子目录）与 go-translate（gt）及其依赖
;; （pdd/posframe）的 straight 构建目录加入 `load-path'——缺 ETAF 时
;; `seshat-reader-etaf' 无法加载（它对 `etaf-ui' 是硬依赖），需要渲染层的
;; 用例会被 `ert-skip' 跳过；缺 gt 时 `sidebar' 渲染对象用例被跳过：
;;
;;   cd /home/thomas/WorkSpace/notes && \
;;   "emacs" --batch -Q \
;;     -L "emacs" -L "emacs"/seshat-reader \
;;     -L /home/thomas/WorkSpace/emacs-taf/ecss \
;;     -L /home/thomas/WorkSpace/emacs-taf/ecss/lisp \
;;     -L /home/thomas/WorkSpace/emacs-taf/ebox \
;;     -L /home/thomas/WorkSpace/emacs-taf/ebox/lisp \
;;     -L /home/thomas/WorkSpace/emacs-taf/etaf \
;;     -L /home/thomas/WorkSpace/emacs-taf/etaf/lisp \
;;     -L /home/thomas/WorkSpace/emacs-taf/etaf-ui \
;;     -L /home/thomas/WorkSpace/emacs-taf/etaf-ui/lisp \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/compat \
;;     -l "emacs"/tests/seshat-reader-etaf-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; gt 的三个路径是 straight 的默认构建目录（形如
;; `<配置目录>/.local/straight/build-<emacs 版本>/'）。换机器或 Emacs 版本
;; 时用下面的命令**探测**实际父目录，再把
;; `-L "$GTROOT/gt" -L "$GTROOT/pdd" -L "$GTROOT/posframe"' 补进命令：
;;
;;   GTROOT=$(dirname "$(find "$HOME" -maxdepth 6 -type d \
;;            -path '*/straight/build-*/gt' 2>/dev/null | head -n1)")
;;   echo "$GTROOT"   # 应形如 /home/thomas/thomas-emacs/.local/straight/build-31.1
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建（`seshat-reader'
;; 模块加载需要它）。
;;
;; 全部用例**绝不触网**、**绝不写用户真实文件**：HTTP 入口（`seshat-rest--request'
;; 等）一律以 `cl-letf' 桩替并计数；离线队列与批注删除的副作用由桩替代；
;; 面板 buffer 一律 `get-buffer-create' 造、用例末 `kill-buffer'；渲染层的
;; `etaf-ref' 状态一律 `let' 就地绑定，退出即恢复。
;;
;; 陷阱备忘（上一轮实测）：`etaf--keys-binding' 返回的 keymap 值**不要**用
;; `%S' 打印——对已挂载 keymap 做打印会挂起；断言一律用 `commandp'/`type-of'。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eieio)
;; 编译期加载 gt 的 buffer 渲染器（若在 `load-path' 中），使编译器认识
;; `gt-buffer-render' 的 `window-config' 等槽，避免 “Unknown slot” 编译告警。
(eval-when-compile (require 'gt-render-buffer nil t))
(require 'seshat-reader)
(require 'seshat-rest)
(require 'seshat-reader-annotation)
(require 'seshat-reader-translate)
(require 'seshat-reader-sidebar)
;; 软依赖：ETAF 不在 `load-path' 中时本行返回 nil，需要渲染层的用例自行跳过。
;; 必须用 `ignore-errors' 兜住——渲染层文件开头是**硬** `(require 'etaf-ui)'
;; （它只在 ETAF 可用时按需加载），缺 ETAF 时该加载**抛错**，而 `require' 的
;; NOERROR 只吞「找不到文件」，吞不掉加载期错误。
;;
;; `eval-when-compile' 那一份只为让**编译器**认识渲染层的函数与特殊变量
;; （否则 `let' 重绑动态变量会被报成「未使用的词法变量」）；运行期仍以
;; 下面的 `ignore-errors' 版本为准，保证无 ETAF 环境下本文件照样能加载。
(eval-when-compile
  (ignore-errors (require 'etaf-ui nil t))
  (ignore-errors (require 'seshat-reader-etaf nil t))

;; 渲染层与 ETAF 的符号只在环境具备 ETAF 时才于运行期存在（见上面的
;; `ignore-errors' 加载），此处声明签名以消除「might not be defined at
;; runtime」编译告警。
(declare-function seshat-reader-etaf-available-p "seshat-reader-etaf" ())
(declare-function seshat-reader-etaf-render-annotations "seshat-reader-etaf"
                  (buffer items doc-id &optional source))
(declare-function seshat-reader-etaf-annotation-goto "seshat-reader-etaf" ())
(declare-function seshat-reader-etaf-annotation-delete "seshat-reader-etaf" ())
(declare-function etaf-ref "etaf-reactive" (initial-value &rest args))
(declare-function etaf-runtime-for-buffer "etaf-runtime" (buffer-or-name))
(declare-function etaf-focus "etaf-events" (&optional runtime host-ref))
(declare-function etaf--keys-binding "etaf-keys" (event)))
(ignore-errors (require 'seshat-reader-etaf nil t))

;;; 夹具与辅助

(defconst seshat-reader-etaf-test--annotations
  '(((id . 101) (location . "page:12;rect:1,2,3,4") (text . "第一条批注正文"))
    ((id . 102) (location . "page:13;rect:1,2,3,4") (text . "第二条批注正文")))
  "服务端批注夹具：两条，页码由 `location' 解析（12 / 13）.")

(defun seshat-reader-etaf-test--queued ()
  "Return a fresh local-only (unsynced) queue entry fixture."
  (list (list :uuid "uuid-test-1" :location "page:14;rect:0,0,0,0"
              :text "待同步的一条批注")))

(defun seshat-reader-etaf-test--buffer-text (buffer)
  "Return the plain text of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun seshat-reader-etaf-test--count-matches (needle haystack)
  "Return the number of non-overlapping occurrences of NEEDLE in HAYSTACK."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (cl-incf count)
      (setq start (match-end 0)))
    count))

(defun seshat-reader-etaf-test--reset-list-buffer ()
  "Kill any leftover annotation list buffer and return its name."
  (let ((name seshat-reader-annotation-list-buffer-name))
    (when (get-buffer name)
      (kill-buffer name))
    name))

(defun seshat-reader-etaf-test--many-items (n)
  "Return N synthetic annotation items with distinguishable summaries.
每条摘要形如 \"批注条目-01\"，用于断言「面板只渲染当页条目」。条目不带
`:page' / `:location'，故卡片页列显示 `p.?'，不会与页码断言互相干扰。"
  (cl-loop for i from 1 to n
           collect (list :id i :uuid nil :page nil :location nil
                         :text (format "批注条目-%02d" i) :dirty nil)))

(defun seshat-reader-etaf-test--fetch-etaf-module ()
  "Load the ETAF rendering layer, returning t on success.
供 `skip-unless' 使用：无 ETAF 环境下加载会**抛错**（渲染层对 `etaf-ui' 是硬
依赖），故用 `ignore-errors' 兜住并返回 nil，需要渲染层的用例因此被
`ert-skip' 跳过，而不是报红。"
  (and (ignore-errors (require 'seshat-reader-etaf nil t)) t))

;;; ① `available-p' 降级

(ert-deftest seshat-reader-etaf-test--available-p-nil-when-require-fails ()
  "`(require \\='etaf-ui nil t)' 返回 nil 时 `available-p' 返回 nil 且不缓存 t."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let ((seshat-reader-etaf-enabled t)
        (seshat-reader-etaf--available nil)
        (orig (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'etaf-ui)
                     nil
                   (funcall orig feature filename noerror)))))
      (should-not (seshat-reader-etaf-available-p))
      (should-not seshat-reader-etaf--available))))

(ert-deftest seshat-reader-etaf-test--available-p-nil-when-disabled ()
  "`seshat-reader-etaf-enabled' 为 nil 时 `available-p' 直接返回 nil."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let ((seshat-reader-etaf-enabled nil))
    (should-not (seshat-reader-etaf-available-p))))

(ert-deftest seshat-reader-etaf-test--available-p-not-true-when-require-signals ()
  "`require' 抛错时 `available-p' 绝不误报「可用」."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let ((seshat-reader-etaf-enabled t)
        (seshat-reader-etaf--available nil)
        (orig (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'etaf-ui)
                     (error "桩：etaf-ui 加载期失败")
                   (funcall orig feature filename noerror)))))
      ;; `require' 的 NOERROR 只吞「找不到文件」，不吞加载期错误：当前实现让
      ;; 该错误继续冒泡。两条路径都不算「可用」，故对「返回 nil」与「抛错」
      ;; 一视同仁——断言的是**不得误报可用**这一不变量。
      (should-not (condition-case nil
                      (seshat-reader-etaf-available-p)
                    (error nil)))
      (should-not seshat-reader-etaf--available))))

(ert-deftest seshat-reader-etaf-test--available-p-does-not-signal ()
  "ETAF 半损坏（require 抛错）时 `available-p' 必须返回 nil 而非冒泡，且不缓存失败."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let ((seshat-reader-etaf-enabled t)
        (seshat-reader-etaf--available nil))
    ;; `require' 的 NOERROR 只吞「找不到文件」，吞不掉加载期错误；这里让
    ;; `require' 一律抛错，模拟「ETAF 文件存在但半损坏」（字节码与源码不匹配、
    ;; 依赖缺失等）。
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _args) (error "桩：require 加载期失败（half-broken）"))))
      ;; 关键：不要用 `condition-case' 包住断言本身——本用例要锁定的不变量
      ;; 正是「`available-p' 自己不冒泡」，包一层就把它测没了。
      (should-not (seshat-reader-etaf-available-p))
      ;; 探测失败不写缓存：下次调用必须重新探测。
      (should-not seshat-reader-etaf--available))))

;;; ② `--render-list' 的文本降级

(ert-deftest seshat-reader-etaf-test--render-list-text-fallback-when-unavailable ()
  "ETAF 不可用时 `--render-list' 走文本渲染路径（行带 `seshat-reader-annotation-id' 属性）."
  (let* ((module (seshat-reader-etaf-test--fetch-etaf-module))
         (name (seshat-reader-etaf-test--reset-list-buffer))
         (run (lambda ()
                (seshat-reader-annotation--render-list
                 "doc-fallback" nil seshat-reader-etaf-test--annotations
                 (seshat-reader-etaf-test--queued))
                (let ((buf (get-buffer name)))
                  (should buf)
                  (with-current-buffer buf
                    (should (string-match-p "第一条批注正文" (buffer-string)))
                    (should (string-match-p "待同步" (buffer-string)))
                    (should (text-property-not-all
                             (point-min) (point-max)
                             'seshat-reader-annotation-id nil)))
                  ;; 不挂 ETAF runtime，即确实是文本路径
                  (should-not (and (fboundp 'etaf-runtime-for-buffer)
                                   (etaf-runtime-for-buffer buf)))))))
    (unwind-protect
        (if module
            (cl-letf (((symbol-function 'seshat-reader-etaf-available-p)
                       (lambda () nil)))
              (funcall run))
          ;; 无 ETAF 环境：天然走文本路径，同样断言
          (funcall run))
      (when (get-buffer name)
        (kill-buffer name)))))

(ert-deftest seshat-reader-etaf-test--render-list-text-fallback-when-disabled ()
  "总开关为 nil 时 `--render-list' 走文本渲染路径，面板不空白."
  (let ((seshat-reader-etaf-enabled nil)
        (name (seshat-reader-etaf-test--reset-list-buffer)))
    (unwind-protect
        (progn
          (seshat-reader-annotation--render-list
           "doc-disabled" nil seshat-reader-etaf-test--annotations nil)
          (let ((buf (get-buffer name)))
            (should buf)
            (with-current-buffer buf
              (should (string-match-p "第一条批注正文" (buffer-string)))
              (should (string-match-p "第二条批注正文" (buffer-string)))
              (should (text-property-not-all
                       (point-min) (point-max)
                       'seshat-reader-annotation-id nil)))))
      (when (get-buffer name)
        (kill-buffer name)))))

;;; ③ 渲染层抛错的 `condition-case' 回退

(ert-deftest seshat-reader-etaf-test--render-layer-error-falls-back-to-text ()
  "渲染层抛错时回退文本渲染：不冒泡、面板仍有内容且可交互."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let* ((name (seshat-reader-etaf-test--reset-list-buffer))
         (err nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'seshat-reader-etaf-available-p)
                     (lambda () t))
                    ((symbol-function 'seshat-reader-etaf-render-annotations)
                     (lambda (&rest _args) (error "桩：ETAF 渲染故意抛错"))))
            (condition-case e
                (seshat-reader-annotation--render-list
                 "doc-error" nil seshat-reader-etaf-test--annotations
                 (seshat-reader-etaf-test--queued))
              (error (setq err e))))
          (should-not err)
          (let ((buf (get-buffer name)))
            (should buf)
            (with-current-buffer buf
              (should (string-match-p "第一条批注正文" (buffer-string)))
              (should (string-match-p "待同步" (buffer-string)))
              (should (text-property-not-all
                       (point-min) (point-max)
                       'seshat-reader-annotation-id nil)))
            (should-not (etaf-runtime-for-buffer buf))))
      (when (get-buffer name)
        (kill-buffer name)))))

;;; ④ items 合成（服务端在前、待同步在后）

(ert-deftest seshat-reader-etaf-test--items-server-and-queued ()
  "`--etaf-items' 把服务端项与本地待同步项合成为约定形状的 plist 列表."
  (let* ((items (seshat-reader-annotation--etaf-items
                 seshat-reader-etaf-test--annotations
                 (seshat-reader-etaf-test--queued)))
         (first (nth 0 items))
         (last (nth 2 items)))
    (should (= 3 (length items)))
    ;; 服务端项：有 :id、无 :uuid/:dirty，页码由 location 解析
    (should (equal 101 (plist-get first :id)))
    (should-not (plist-get first :uuid))
    (should-not (plist-get first :dirty))
    (should (equal 12 (plist-get first :page)))
    (should (equal 102 (plist-get (nth 1 items) :id)))
    ;; 本地待同步项：无 :id、有 :uuid、:dirty 为 t
    (should-not (plist-get last :id))
    (should (equal "uuid-test-1" (plist-get last :uuid)))
    (should (eq t (plist-get last :dirty)))
    (should (equal 14 (plist-get last :page)))
    ;; 顺序与服务端/待同步一致
    (should (equal '(101 102 nil)
                   (mapcar (lambda (it) (plist-get it :id)) items)))))

;;; ⑤ 动作命令的取值路径

(ert-deftest seshat-reader-etaf-test--goto-uses-location-page ()
  "`goto' 从选中项的 `:location' 解析页码并调用 `seshat-reader-goto-page'."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let* ((src (get-buffer-create " *seshat-etaf-test-doc*"))
         (items (list (list :id 101 :uuid nil :location "page:12;rect:1,2,3,4"
                            :page nil :text "第一条批注正文" :dirty nil)))
         (seshat-reader-etaf--items (etaf-ref items))
         (seshat-reader-etaf--selected (etaf-ref 101))
         (seshat-reader-etaf--doc-id "doc-goto")
         (seshat-reader-etaf--doc-source src)
         (goto-page nil)
         (popped nil))
    (unwind-protect
        (progn
          ;; 只置 buffer-local 的 `major-mode'（不跑 mode hook，避免依赖文档状态）
          (with-current-buffer src
            (setq major-mode 'seshat-reader-mode))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _args) (setq popped buffer) nil))
                    ((symbol-function 'seshat-reader-goto-page)
                     (lambda (page) (setq goto-page page) t)))
            (seshat-reader-etaf-annotation-goto))
          (should (eq popped src))
          (should (equal 12 goto-page)))
      (when (buffer-live-p src)
        (kill-buffer src)))))

(ert-deftest seshat-reader-etaf-test--delete-server-item ()
  "`delete' 对服务端项用 `:id' 调 `seshat-reader-annotation-delete'."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let* ((items (list (list :id 101 :uuid nil :location "page:12;rect:1,2,3,4"
                            :page 12 :text "第一条批注正文" :dirty nil)))
         (seshat-reader-etaf--items (etaf-ref items))
         (seshat-reader-etaf--selected (etaf-ref 101))
         (deleted nil))
    (cl-letf (((symbol-function 'seshat-reader-annotation-delete)
               (lambda (id) (setq deleted id) nil))
              ((symbol-function 'message) (lambda (&rest _args) nil)))
      (seshat-reader-etaf-annotation-delete))
    (should (equal 101 deleted))))

(ert-deftest seshat-reader-etaf-test--delete-queued-item-without-http ()
  "`delete' 对本地待同步项按 `:uuid' 取消队列条目，且**不发任何 HTTP 请求**."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (skip-unless (require 'seshat-reader-annotation-queue nil t))
  (let* ((items (list (list :id nil :uuid "uuid-test-1"
                            :location "page:14;rect:0,0,0,0" :page 14
                            :text "待同步的一条批注" :dirty t)))
         (seshat-reader-etaf--items (etaf-ref items))
         (seshat-reader-etaf--selected (etaf-ref "uuid-test-1"))
         (seshat-reader-etaf--doc-id "doc-queued")
         (http 0)
         (removed nil)
         (rerendered 0))
    (cl-letf (((symbol-function 'seshat-rest--request)
               (lambda (&rest _args) (cl-incf http) nil))
              ((symbol-function 'seshat-rest-list-annotations)
               (lambda (&rest _args) (cl-incf http) nil))
              ((symbol-function 'seshat-rest-delete-annotation)
               (lambda (&rest _args) (cl-incf http) nil))
              ((symbol-function 'seshat-reader-annotation-queue-remove)
               (lambda (uuid) (setq removed uuid) t))
              ((symbol-function 'seshat-reader-etaf--rerender-cached)
               (lambda () (cl-incf rerendered)))
              ((symbol-function 'message) (lambda (&rest _args) nil)))
      (seshat-reader-etaf-annotation-delete))
    (should (equal "uuid-test-1" removed))
    (should (= 0 http))
    (should (= 1 rerendered))))

;;; ⑥–⑧ ETAF 可用时的渲染断言（无 ETAF 环境自动跳过）

(ert-deftest seshat-reader-etaf-test--render-annotations-panel ()
  "批注面板渲染出标题、页码徽章、待同步标记与键位提示."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (skip-unless (seshat-reader-etaf-available-p))
  (let* ((items (seshat-reader-annotation--etaf-items
                 seshat-reader-etaf-test--annotations
                 (seshat-reader-etaf-test--queued)))
         (buf (get-buffer-create
               (seshat-reader-etaf-test--reset-list-buffer)))
         (seshat-reader-etaf--items (etaf-ref nil))
         (seshat-reader-etaf--selected (etaf-ref nil)))
    (unwind-protect
        (progn
          (seshat-reader-etaf-render-annotations buf items "doc-etaf")
          (let ((text (seshat-reader-etaf-test--buffer-text buf)))
            (should (string-match-p "Seshat 批注" text))
            (should (string-match-p "p\\.12" text))
            (should (string-match-p "第一条批注正文" text))
            (should (string-match-p "待同步" text))
            (should (string-match-p "3 条" text))
            (should (string-match-p "RET 打开" text))
            ;; 新排版：首项自动选中，只有一行带 `▌' 选中标记（其余留空格占位，
            ;; 该列宽 `(ch 2)'——按 2 列测量的 `▌' 在 `(ch 1)' 里会被裁成空格）。
            (should (= 1 (seshat-reader-etaf-test--count-matches "▌" text)))
            ;; `▌' 后是两个空格：页码列宽为 `(ch 2)'（见上一条注释）。
            (should (string-match-p "▌  p\\.12" text)))
          (should (etaf-runtime-for-buffer buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest seshat-reader-etaf-test--annotation-keys-registered ()
  "批注面板的 `:keys' 以 vector 形式登记，焦点在卡片时 `d' 解析为可执行命令."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (skip-unless (seshat-reader-etaf-available-p))
  (let* ((items (seshat-reader-annotation--etaf-items
                 seshat-reader-etaf-test--annotations nil))
         (buf (get-buffer-create
               (seshat-reader-etaf-test--reset-list-buffer)))
         (seshat-reader-etaf--items (etaf-ref nil))
         (seshat-reader-etaf--selected (etaf-ref nil))
         (deleted nil))
    (unwind-protect
        (progn
          (seshat-reader-etaf-render-annotations buf items "doc-keys")
          (let* ((runtime (etaf-runtime-for-buffer buf))
                 (sequences (and runtime
                                 (gethash (etaf-runtime-keymap runtime)
                                          etaf--keys-sequences))))
            (should runtime)
            (dolist (sequence '("RET" "d" "C-c C-r" "q" "n" "p"))
              (should (member (vconcat (kbd sequence)) sequences))))
          ;; 动态解析：焦点落在卡片后 `d' 应解析为可执行命令（勿打印返回值）
          (with-current-buffer buf
            (etaf-focus (etaf-runtime-for-buffer buf) 'seshat-etaf-item-101)
            (let ((command (etaf--keys-binding (vconcat (kbd "d")))))
              (should (commandp command))
              (cl-letf (((symbol-function 'seshat-reader-annotation-delete)
                         (lambda (id) (setq deleted id) nil))
                        ((symbol-function 'message) (lambda (&rest _args) nil)))
                (funcall command)))
            (should (equal 101 deleted))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; ⑨ 全量渲染（徽章恒为 N 条、全部卡片出图、无翻页键）

(ert-deftest seshat-reader-etaf-test--badge-text-always-count ()
  "徽章恒为「N 条」：30 条 → \"30 条\"，1 条 → \"1 条\"."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (let ((seshat-reader-etaf--items
         (etaf-ref (seshat-reader-etaf-test--many-items 30))))
    (should (equal "30 条" (seshat-reader-etaf--badge-text nil))))
  (let ((seshat-reader-etaf--items
         (etaf-ref (seshat-reader-etaf-test--many-items 1))))
    (should (equal "1 条" (seshat-reader-etaf--badge-text nil)))))

(ert-deftest seshat-reader-etaf-test--annotations-view-renders-all-items ()
  "30 条条目全部渲染进面板：viewport 高度按内容放大，末条不被裁掉."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (skip-unless (seshat-reader-etaf-available-p))
  (let* ((items (seshat-reader-etaf-test--many-items 30))
         (buf (get-buffer-create
               (seshat-reader-etaf-test--reset-list-buffer)))
         (seshat-reader-etaf--items (etaf-ref nil))
         (seshat-reader-etaf--selected (etaf-ref nil))
         (seshat-reader-etaf--doc-label (etaf-ref nil)))
    (unwind-protect
        (progn
          (seshat-reader-etaf-render-annotations buf items "doc-all")
          (let ((text (seshat-reader-etaf-test--buffer-text buf)))
            (should (string-match-p "批注条目-01" text))
            (should (string-match-p "批注条目-30" text))
            ;; 30 张卡片全部出图（无切片、无内部滚动裁剪）
            (should (= 30 (seshat-reader-etaf-test--count-matches
                           "批注条目-" text)))
            ;; 徽章恒为条目总数
            (should (string-match-p "30 条" text))
            (should-not (string-match-p "页" text))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest seshat-reader-etaf-test--render-annotations-refit-grows-viewport ()
  "已挂载后条目增多时 refit 放大 viewport：新增条目不被裁掉."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (skip-unless (seshat-reader-etaf-available-p))
  (let* ((few (seshat-reader-etaf-test--many-items 3))
         (many (seshat-reader-etaf-test--many-items 30))
         (buf (get-buffer-create
               (seshat-reader-etaf-test--reset-list-buffer)))
         (seshat-reader-etaf--items (etaf-ref nil))
         (seshat-reader-etaf--selected (etaf-ref nil))
         (seshat-reader-etaf--doc-label (etaf-ref nil)))
    (unwind-protect
        (progn
          (seshat-reader-etaf-render-annotations buf few "doc-grow")
          (should (= 3 (seshat-reader-etaf-test--count-matches
                        "批注条目-" (seshat-reader-etaf-test--buffer-text buf))))
          ;; 第二次渲染走幂等（runtime 已存在）分支：必须 refit 到新高度
          (seshat-reader-etaf-render-annotations buf many "doc-grow")
          (let ((text (seshat-reader-etaf-test--buffer-text buf)))
            (should (= 30 (seshat-reader-etaf-test--count-matches
                           "批注条目-" text)))
            (should (string-match-p "批注条目-30" text))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest seshat-reader-etaf-test--annotation-keys-no-paging ()
  "面板 `:keys' 表不含 `]' / `['，其余动作键仍在."
  (skip-unless (seshat-reader-etaf-test--fetch-etaf-module))
  (should-not (assoc "]" seshat-reader-etaf--annotation-keys))
  (should-not (assoc "[" seshat-reader-etaf--annotation-keys))
  (dolist (sequence '("RET" "d" "C-c C-r" "q" "n" "p"))
    (should (assoc sequence seshat-reader-etaf--annotation-keys))))

(ert-deftest seshat-reader-etaf-test--sidebar-render-object-uses-hidden-gt-buffer ()
  "`sidebar' 渲染对象指向隐藏中转 buffer，并带 `:then' 回调.
新实现不再依赖 ETAF 可用性（面板由 `seshat-reader-translate--render-panel'
以 Markdown 文本 buffer 渲染），故此处不再 `skip-unless' ETAF。"
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((seshat-reader-sidebar-enabled t)
         (obj (seshat-reader-translate--render-object 'sidebar))
         (window-config (slot-value obj 'window-config)))
    (should (eq (eieio-object-class obj) 'gt-buffer-render))
    (should (equal (slot-value obj 'name)
                   seshat-reader-translate--gt-buffer-name))
    (should (equal '(display-buffer-no-window) (car window-config)))
    (should (member '(allow-no-window . t) window-config))
    (should (slot-value obj 'then))))

(provide 'seshat-reader-etaf-test)
;;; seshat-reader-etaf-test.el ends here
