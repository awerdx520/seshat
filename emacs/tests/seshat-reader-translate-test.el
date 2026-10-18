;;; seshat-reader-translate-test.el --- ERT tests for seshat-reader-translate  -*- lexical-binding: t; -*-

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

;; `seshat-reader-translate' 的 ERT 测试套件。
;;
;; 全部用例**绝不触网**：用 `cl-letf' 桩替两个网络出口——`gt-start'
;; （go-translate 真正发起翻译的入口）与 `seshat-rest--request'（REST
;; 底层请求）——由桩记录实参并返回构造好的假响应；任何真实 HTTP 调用
;; 都不会发生。翻译器对象与 gt 预设都用真实的 gt 类构造，但从不启动。
;;
;; 临时文件与目录一律建在 `temporary-file-directory'（通常 /tmp）下，
;; 并在用例结束时递归删除，因此测试可重复运行、不污染仓库。用例对共享
;; 变量（选区、预设、渲染方式、两个输出 hook）一律用 `let' 就地绑定，
;; 退出即恢复。
;;
;; 末尾两条 `--integration-*' 用例是**端到端**的：由辅助函数
;; `seshat-reader-translate-test--panel-chain' 一次性走完「选区 → 翻译器
;; 装配 → 渲染对象 `:then' → 面板 buffer」链路（`gt-start' 桩改为直接调用
;; 渲染对象的 `:then'），再分别断言面板视图参数与「存为批注」的入参；同样
;; 不触网、不写真实文件。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'gt)
(require 'seshat-reader-translate)

(defvar seshat-reader-translate-test--selection-file
  "/tmp/seshat-translate-test.pdf"
  "测试用选区的文档文件路径（无需真实存在）.")

(defun seshat-reader-translate-test--selection ()
  "返回一个典型的鼠标选区 plist（含 :text、:page、:rect、:file）."
  (list :text "Hello world"
        :page 3
        :rect '(10.0 20.0 30.0 40.0)
        :file seshat-reader-translate-test--selection-file))

;;; 软依赖 gt 的按需加载

(ert-deftest seshat-reader-translate-test--ensure-gt-missing-errors ()
  "未加载 gt 时 `--ensure-gt' 抛 `user-error'."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (should-error (seshat-reader-translate--ensure-gt) :type 'user-error)))

(ert-deftest seshat-reader-translate-test--ensure-gt-loaded-returns-t ()
  "可加载 gt 时 `--ensure-gt' 返回 t."
  (should (eq (seshat-reader-translate--ensure-gt) t)))

;;; 选区文本的读取

(ert-deftest seshat-reader-translate-test--selection-text-missing-errors ()
  "`seshat-reader-select-last' 为 nil 时取选区文本抛 `user-error'."
  (let ((seshat-reader-select-last nil))
    (should-error (seshat-reader-translate--selection-text) :type 'user-error)))

(ert-deftest seshat-reader-translate-test--selection-text-blank-errors ()
  "选区文本为空白时取选区文本抛 `user-error'."
  (let ((seshat-reader-select-last (list :text "  \n\t")))
    (should-error (seshat-reader-translate--selection-text) :type 'user-error)))

(ert-deftest seshat-reader-translate-test--selection-text-returns-text ()
  "选区有正常文本时取选区文本原样返回."
  (let ((seshat-reader-select-last (list :text "hello")))
    (should (equal (seshat-reader-translate--selection-text) "hello"))))

;;; 翻译器装配

(ert-deftest seshat-reader-translate-test--selection-assembles-translator ()
  "缺预设时装配的 translator：taker 的 text/pick/langs、engines 与 render 正确."
  (let ((seshat-reader-select-last (seshat-reader-translate-test--selection))
        (seshat-reader-translate-fallback-langs '(en zh))
        (seshat-reader-translate-preset 'reader)
        (seshat-reader-translate-render 'pop)
        (gt-preset-translators nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (captured nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (translator) (setq captured translator)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (seshat-reader-translate-selection))
    (should captured)
    (let* ((taker (slot-value captured 'taker))
           (engines (slot-value captured 'engines))
           (render (slot-value captured 'render)))
      (should (equal (slot-value taker 'text) "Hello world"))
      (should (null (slot-value taker 'pick)))
      (should (equal (slot-value taker 'langs) '(en zh)))
      (should (equal (mapcar #'eieio-object-class engines)
                     '(gt-youdao-dict-engine gt-google-engine)))
      (should (eq (eieio-object-class render) 'gt-posframe-pop-render)))))

(ert-deftest seshat-reader-translate-test--preset-missing-falls-back-once ()
  "预设缺失时回退内置 youdao/google 引擎，且只 message 一次."
  (let ((seshat-reader-select-last (seshat-reader-translate-test--selection))
        (seshat-reader-translate-fallback-langs '(en zh))
        (seshat-reader-translate-preset 'reader)
        (gt-preset-translators nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (captured nil)
        (messages nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (translator) (setq captured translator)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (seshat-reader-translate-selection))
    (should (= (length messages) 1))
    (should captured)
    (let* ((taker (slot-value captured 'taker))
           (engines (slot-value captured 'engines)))
      (should (equal (slot-value taker 'langs) '(en zh)))
      (should (equal (mapcar #'eieio-object-class engines)
                     '(gt-youdao-dict-engine gt-google-engine))))))

(ert-deftest seshat-reader-translate-test--preset-hit-clones-without-mutation ()
  "命中预设时克隆该预设、改写克隆而非原预设，且不 message."
  (let* ((preset (gt-translator :engines (list (gt-google-engine))))
         (presets (list (cons 'chosen preset)))
         (seshat-reader-select-last (seshat-reader-translate-test--selection))
         (seshat-reader-translate-preset 'chosen)
         (seshat-reader-translate-render 'pin)
         (gt-preset-translators presets)
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil)
         (captured nil)
         (messages nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (translator) (setq captured translator)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (seshat-reader-translate-selection))
    (should-not messages)
    (should captured)
    (should-not (eq captured preset))
    (should (slot-value captured 'taker))
    (should (eq (eieio-object-class (slot-value captured 'render))
                'gt-posframe-pin-render))
    ;; 原预设对象未被改写。
    (should-not (slot-value preset 'taker))
    (should-not (slot-value preset 'render))))

(ert-deftest seshat-reader-translate-test--target-lang-prefix-builds-langs ()
  "带目标语言 \"ja\" 时 taker 的 langs 为 (en ja)."
  (let ((seshat-reader-select-last (seshat-reader-translate-test--selection))
        (seshat-reader-translate-fallback-langs '(en zh))
        (seshat-reader-translate-preset 'reader)
        (gt-preset-translators nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (captured nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (translator) (setq captured translator)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (seshat-reader-translate-selection "ja"))
    (should captured)
    (should (equal (slot-value (slot-value captured 'taker) 'langs) '(en ja)))))

(ert-deftest seshat-reader-translate-test--preset-taker-render-not-polluted ()
  "预设自身带 taker/render 时克隆不被污染，原预设槽仍是原对象且 text 不变."
  (let* ((orig-taker (gt-taker :text "ORIG" :pick nil :langs '(en zh)))
         (orig-render (gt-posframe-pop-render))
         (preset (gt-translator :taker orig-taker :render orig-render
                                :engines (list (gt-google-engine))))
         (gt-preset-translators (list (cons 'chosen preset)))
         (seshat-reader-translate-render 'pop))
    (let ((t1 (seshat-reader-translate--translator 'chosen "AAA" '(en zh)))
          (t2 (seshat-reader-translate--translator 'chosen "BBB" '(en zh))))
      ;; 原预设的 taker/render 槽仍是原对象，text 未被改写。
      (should (eq (slot-value preset 'taker) orig-taker))
      (should (eq (slot-value preset 'render) orig-render))
      (should (equal (slot-value (slot-value preset 'taker) 'text) "ORIG"))
      ;; 两次克隆体各自持有新的 taker 与对应 text。
      (should-not (eq (slot-value t1 'taker) orig-taker))
      (should-not (eq (slot-value t2 'taker) orig-taker))
      (should (equal (slot-value (slot-value t1 'taker) 'text) "AAA"))
      (should (equal (slot-value (slot-value t2 'taker) 'text) "BBB")))))

;;; 渲染方式

(ert-deftest seshat-reader-translate-test--render-object-pop-pin ()
  "`--render-object' 按 pop/pin 返回不同渲染对象."
  (should (eq (eieio-object-class (seshat-reader-translate--render-object 'pop))
              'gt-posframe-pop-render))
  (should (eq (eieio-object-class (seshat-reader-translate--render-object nil))
              'gt-posframe-pop-render))
  (should (eq (eieio-object-class (seshat-reader-translate--render-object 'pin))
              'gt-posframe-pin-render)))

(ert-deftest seshat-reader-translate-test--render-mode-switches ()
  "随 `seshat-reader-translate-render' 在 pop/pin 间切换 render 对象类型."
  (dolist (case '((pop . gt-posframe-pop-render)
                  (pin . gt-posframe-pin-render)))
    (let ((seshat-reader-select-last (seshat-reader-translate-test--selection))
          (seshat-reader-translate-preset 'reader)
          (seshat-reader-translate-render (car case))
          (gt-preset-translators nil)
          (gt-posframe-pop-render-output-hook nil)
          (gt-posframe-pin-render-output-hook nil)
          (captured nil))
      (cl-letf (((symbol-function 'gt-start)
                 (lambda (translator) (setq captured translator)))
                ((symbol-function 'message) (lambda (&rest _) nil)))
        (seshat-reader-translate-selection))
      (should (eq (eieio-object-class (slot-value captured 'render)) (cdr case))))))

;;; 译文捕获

(ert-deftest seshat-reader-translate-test--capture-result-joins-pieces ()
  "`--capture-result' 把带 `gt-result' 的片段以换行拼接，忽略无属性内容."
  (with-temp-buffer
    (insert (propertize "第一段" 'gt-result t))
    (insert "（无属性，忽略）")
    (insert (propertize "第二段" 'gt-result t))
    (let ((seshat-reader-translate-last-result nil)
          (seshat-reader-translate--active (float-time)))
      (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
        (should (equal (seshat-reader-translate--capture-result)
                       "第一段\n第二段")))
      (should (equal seshat-reader-translate-last-result
                     "第一段\n第二段")))))

(ert-deftest seshat-reader-translate-test--capture-result-no-piece-keeps-nil ()
  "无 `gt-result' 片段时 `--capture-result' 提示且不写入译文."
  (with-temp-buffer
    (insert "没有任何属性的文本")
    (let ((seshat-reader-translate-last-result nil)
          (seshat-reader-translate--active (float-time))
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (should-not (seshat-reader-translate--capture-result)))
      (should (null seshat-reader-translate-last-result))
      (should messages))))

(ert-deftest seshat-reader-translate-test--capture-result-error-face-keeps-nil ()
  "渲染结果带错误 face 时 `--capture-result' 提示且不写入译文."
  (with-temp-buffer
    (insert (propertize "貌似译文" 'gt-result t
                        'face 'gt-buffer-render-error-face))
    (let ((seshat-reader-translate-last-result nil)
          (seshat-reader-translate--active (float-time))
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (should-not (seshat-reader-translate--capture-result)))
      (should (null seshat-reader-translate-last-result))
      (should messages))))

(ert-deftest seshat-reader-translate-test--capture-result-window-guard ()
  "活动标记为 nil 或超出窗口时不写入 last-result，窗口内正常写入."
  (with-temp-buffer
    (insert (propertize "新译文" 'gt-result t))
    ;; ① 标记为 nil：不写、不提示。
    (let ((seshat-reader-translate-last-result "OLD")
          (seshat-reader-translate--active nil)
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest args) (push args messages))))
        (should-not (seshat-reader-translate--capture-result)))
      (should (equal seshat-reader-translate-last-result "OLD"))
      (should-not messages))
    ;; ② 标记在窗口内：正常写入。
    (let ((seshat-reader-translate-last-result "OLD")
          (seshat-reader-translate--active (float-time)))
      (should (equal (seshat-reader-translate--capture-result) "新译文"))
      (should (equal seshat-reader-translate-last-result "新译文")))
    ;; ③ 标记超出窗口：不写。
    (let ((seshat-reader-translate-last-result "OLD")
          (seshat-reader-translate--active
           (- (float-time) (+ seshat-reader-translate-capture-window 10))))
      (should-not (seshat-reader-translate--capture-result))
      (should (equal seshat-reader-translate-last-result "OLD")))))

;;; 面板内 Markdown 文本 buffer 渲染

(ert-deftest seshat-reader-translate-test--render-panel-writes-text-and-view ()
  "`--render-panel' 把译文写入面板 buffer、设只读视图与 header-line，并经 show 显示."
  (skip-unless (require 'gt nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name "*Seshat Test Panel*")
         (seshat-reader-translate-show-source nil)
         ;; 本用例只验证「写入 + 视图」，把模板关掉以免与模板渲染耦合
         (seshat-reader-translate-template nil)
         (seshat-reader-select-last nil)
         (shown nil)
         (text "**粗体**\n\n- 列表项一\n- 列表项二")
         (buf nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (b kind &optional select)
                     (setq shown (list b kind select))
                     'fake-win)))
          (setq buf (seshat-reader-translate--render-panel text "Seshat 译文"))
          (should (bufferp buf))
          (should (equal (buffer-name buf) "*Seshat Test Panel*"))
          (should (equal (with-current-buffer buf (buffer-string)) text))
          (with-current-buffer buf
            (should (null truncate-lines))
            (should word-wrap)
            (should buffer-read-only)
            (should (equal header-line-format "Seshat 译文"))
            (should seshat-reader-translate-panel-mode)
            (should (= (point) (point-min))))
          ;; 经统一显示入口、以 translate 类型显示、请求跟随光标
          (should (eq (car shown) buf))
          (should (eq (nth 1 shown) 'translate))
          (should (nth 2 shown)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest seshat-reader-translate-test--render-panel-show-source ()
  "默认模板 + `show-source' 为 t 时渲染完整（不截断）引用块、分隔线与正文."
  (skip-unless (require 'gt nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name "*Seshat Test Panel*")
         (seshat-reader-translate-show-source t)
         (long (concat "长原文行" (make-string 260 ?字)))
         (seshat-reader-select-last (list :text (concat long "\n第二行原文")))
         (buf nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (b &rest _args) b)))
          (setq buf (seshat-reader-translate--render-panel "译文正文" "Seshat 译文"))
          (with-current-buffer buf
            (let ((content (buffer-string)))
              ;; 引号块在语言对行之后（LANGS 为 nil 故无该行），内容以引用块开头
              (should (string-match-p (regexp-quote "> **原文**\n>\n") content))
              (should (string-prefix-p "> **原文**\n>\n" content))
              ;; 引用块每行带 `> ' 前缀，随后是分隔线与正文
              (should (string-match-p
                       (regexp-quote (concat "> " long
                                             "\n> 第二行原文\n\n---\n\n译文正文\n"))
                       content))
              ;; 不截断
              (should (string-match-p (regexp-quote long) content))
              (should (string-suffix-p "译文正文\n" content)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest seshat-reader-translate-test--render-panel-show-source-off ()
  "`show-source' 为 nil 时不插入引用块，正文位于分隔线之后."
  (skip-unless (require 'gt nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name "*Seshat Test Panel*")
         (seshat-reader-translate-show-source nil)
         (seshat-reader-select-last (list :text "原文片段"))
         (buf nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (b &rest _args) b)))
          (setq buf (seshat-reader-translate--render-panel "译文正文" "Seshat 译文"))
          (let ((content (with-current-buffer buf (buffer-string))))
            ;; 无原文引用块
            (should-not (string-match-p "原文" content))
            ;; 分隔线 + 正文（无标题、无语言对行）
            (should (string-prefix-p "---\n\n译文正文\n" content))
            (should (string-match-p "---\n\n译文正文\n\\'" content))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest seshat-reader-translate-test--prepare-view-enables-visual-fill-column ()
  "`--prepare-view' 在 `seshat-reader-translate-visual-fill-column' 为 t 时启用 vfc."
  (skip-unless (require 'visual-fill-column nil t))
  (with-temp-buffer
    (let ((seshat-reader-translate-visual-fill-column t))
      (seshat-reader-translate--prepare-view)
      (should visual-fill-column-mode))))

(ert-deftest seshat-reader-translate-test--prepare-view-honors-disable-option ()
  "选项为 nil 时 `--prepare-view' 不启用 `visual-fill-column-mode'.
测试 buffer 无窗口，故 `-1' 守卫分支也不会执行。"
  (skip-unless (require 'visual-fill-column nil t))
  (with-temp-buffer
    (let ((seshat-reader-translate-visual-fill-column nil))
      (seshat-reader-translate--prepare-view)
      (should-not visual-fill-column-mode))))

(ert-deftest seshat-reader-translate-test--prepare-view-tolerates-missing-visual-fill-column ()
  "`visual-fill-column' 软依赖缺失时 `--prepare-view' 静默跳过、不报错.
用 `cl-letf' 桩 `fboundp' 与 `require' 模拟包未安装：仅对
`visual-fill-column-mode'/`visual-fill-column' 返回 nil，其它符号透传给原
函数——`--prepare-view' 还用 `fboundp' 判定 `gfm-view-mode'/
`markdown-view-mode'，不透传会破坏视图 mode 的降级链。"
  (with-temp-buffer
    (let ((seshat-reader-translate-visual-fill-column t)
          ;; 先取出原函数对象，避免桩内部递归调用自身
          (orig-fboundp (symbol-function 'fboundp))
          (orig-require (symbol-function 'require)))
      (cl-letf (((symbol-function 'fboundp)
                 (lambda (sym)
                   (if (eq sym 'visual-fill-column-mode)
                       nil
                     (funcall orig-fboundp sym))))
                ((symbol-function 'require)
                 (lambda (feature &optional filename noerror)
                   (if (eq feature 'visual-fill-column)
                       nil
                     (funcall orig-require feature filename noerror)))))
        ;; 不抛错即视为通过（vfc 缺失时静默跳过）
        (seshat-reader-translate--prepare-view)
        (should-not (bound-and-true-p visual-fill-column-mode))))))

;;; 模板渲染

(ert-deftest seshat-reader-translate-test--format-langs-joins ()
  "`--format-langs' 把语言列表格式化为 \"源 → 目标\" 字符串，无法格式化时 nil."
  (should (equal (seshat-reader-translate--format-langs '(en zh)) "en → zh"))
  (should (equal (seshat-reader-translate--format-langs '(en zh ja))
                 "en → zh → ja"))
  (should-not (seshat-reader-translate--format-langs nil))
  ;; 非列表（单个符号）与含非符号元素的列表都无法格式化
  (should-not (seshat-reader-translate--format-langs 'en))
  (should-not (seshat-reader-translate--format-langs '(en "zh"))))

(ert-deftest seshat-reader-translate-test--format-langs-rejects-nil-element ()
  "列表含 nil 元素时 `--format-langs' 返回 nil.
`(symbolp nil)' 为 t，故不能只用 `cl-every #'symbolp' 校验：含 nil 的列表
（如 `seshat-reader-translate-fallback-langs' 被误配成 (nil zh)）会退化成
\"nil → zh\" 这类无意义元信息，必须整体判为不可格式化。"
  (should-not (seshat-reader-translate--format-langs '(nil zh)))
  (should-not (seshat-reader-translate--format-langs '(en nil))))

(ert-deftest seshat-reader-translate-test--apply-template-default ()
  "默认模板渲染出语言对元信息、分隔线与正文（默认不含标题）。"
  (let ((seshat-reader-translate-show-source nil)
        (seshat-reader-select-last nil))
    (let ((rendered (seshat-reader-translate--apply-template
                     "正文" "Seshat 译文" '(en zh))))
      ;; header-line 已显示标题，默认模板不再重复 `%k'
      (should-not (string-match-p "# Seshat 译文" rendered))
      (should (string-match-p (regexp-quote "*en → zh*") rendered))
      (should (string-match-p "\n---\n" rendered))
      (should (string-match-p "正文" rendered))
      (should (string-suffix-p "正文\n" rendered))
      (should (equal rendered "*en → zh*\n\n---\n\n正文\n")))))

(ert-deftest seshat-reader-translate-test--apply-template-langs-nil ()
  "LANGS 为 nil 时不产生语言对元信息行，结果以分隔线开头。"
  (let ((seshat-reader-translate-show-source nil)
        (seshat-reader-select-last nil))
    (let ((rendered (seshat-reader-translate--apply-template
                     "正文" "Seshat 译文" nil)))
      (should-not (string-match-p "\\*" rendered))
      (should-not (string-match-p "\n\n\n" rendered))
      (should (equal rendered "---\n\n正文\n")))))

(ert-deftest seshat-reader-translate-test--apply-template-disabled ()
  "模板为 nil 时 `--apply-template' 原样返回 TEXT."
  (let ((seshat-reader-translate-template nil))
    (should (equal (seshat-reader-translate--apply-template
                    "原样正文" "Seshat 译文" '(en zh))
                   "原样正文"))))

(ert-deftest seshat-reader-translate-test--apply-template-custom ()
  "自定义模板按占位符替换并补一个尾换行."
  (let ((seshat-reader-translate-template "## %k\n\n%t"))
    (should (equal (seshat-reader-translate--apply-template
                    "正文" "Seshat 译文" '(en zh))
                   "## Seshat 译文\n\n正文\n"))))

(ert-deftest seshat-reader-translate-test--apply-template-invalid-placeholder ()
  "非法占位符时回退纯正文、不报错，并 message 警告."
  (let ((seshat-reader-translate-template "# %z\n\n%t")
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)
                 nil)))
      (should (equal (seshat-reader-translate--apply-template
                      "正文" "Seshat 译文" '(en zh))
                     "正文")))
    (should messages)
    (should (string-match-p "模板渲染失败" (car messages)))))

(ert-deftest seshat-reader-translate-test--apply-template-percent-in-text ()
  "正文里字面的 `%' 不被 `format-spec' 二次解析，原样出现在渲染结果中.
`format-spec' 只解析**模板**里的占位符，替换值中的 `%' 不会再被解析；本测试
把这条语义固定下来，避免以后改用其它替换实现时正文（如「完成度 100%」）被
吞掉或报错。"
  ;; 取 defcustom 的标准值作为默认模板，避免在此重复字面模板而漂移
  (let ((seshat-reader-translate-template
         (eval (car (get 'seshat-reader-translate-template 'standard-value)) t))
        (seshat-reader-translate-show-source nil)
        (seshat-reader-select-last nil))
    (let ((rendered (seshat-reader-translate--apply-template
                     "完成度 100%" "Seshat 译文" '(en zh))))
      (should (string-match-p (regexp-quote "完成度 100%") rendered))
      (should (string-suffix-p "完成度 100%\n" rendered)))))

(ert-deftest seshat-reader-translate-test--apply-template-uses-explain-template ()
  "context 为 `explain' 时用解释模板（默认不含语言对行），其余用翻译模板."
  (let ((seshat-reader-translate-show-source nil)
        (seshat-reader-select-last nil))
    ;; 解释：默认解释模板无 `%l'，故即使有 LANGS 也不出现语言对元信息
    (let ((explain (seshat-reader-translate--apply-template
                    "正文" "Seshat 解释" '(en zh) 'explain)))
      (should-not (string-match-p (regexp-quote "*en → zh*") explain))
      (should (equal explain "---\n\n正文\n")))
    ;; 翻译：显式 `translate' 与 nil 都走 `seshat-reader-translate-template'
    (dolist (context (list 'translate nil))
      (let ((translated (seshat-reader-translate--apply-template
                         "正文" "Seshat 译文" '(en zh) context)))
        (should (string-match-p (regexp-quote "*en → zh*") translated))
        (should (equal translated "*en → zh*\n\n---\n\n正文\n"))))))

(ert-deftest seshat-reader-translate-test--show-source-defaults-to-t ()
  "`seshat-reader-translate-show-source' 的默认值为 t（默认显示原文引用块）."
  (should (eq (default-value 'seshat-reader-translate-show-source) t)))

(ert-deftest seshat-reader-translate-test--apply-template-explain-no-langs-line ()
  "context 为 `explain' 时用解释模板默认值渲染，结果不含语言对行."
  (let ((seshat-reader-translate-explain-template
         (eval (car (get 'seshat-reader-translate-explain-template
                         'standard-value))
               t))
        (seshat-reader-translate-show-source nil)
        (seshat-reader-select-last nil))
    (should seshat-reader-translate-explain-template)
    (let ((rendered (seshat-reader-translate--apply-template
                     "解释正文" "Seshat 解释" '(en zh) 'explain)))
      (should-not (string-match-p "en → zh" rendered))
      (should-not (string-match-p (regexp-quote "Seshat 解释") rendered))
      (should (equal rendered "---\n\n解释正文\n")))))

(ert-deftest seshat-reader-translate-test--apply-template-independent-nil ()
  "两个模板都为 nil 时各自原样返回 TEXT，不互相回退."
  (let ((seshat-reader-translate-template nil)
        (seshat-reader-translate-explain-template nil))
    (dolist (context (list 'translate 'explain nil))
      (should (equal (seshat-reader-translate--apply-template
                      "纯正文" "标题" '(en zh) context)
                     "纯正文")))))

(ert-deftest seshat-reader-translate-test--panel-result-uses-record-result ()
  "`--panel-result' 从中转 buffer 提取译文并写入 last-result；取不到时保留上次."
  (skip-unless (require 'gt nil t))
  (let ((gt-buffer (get-buffer-create seshat-reader-translate--gt-buffer-name))
        (seshat-reader-translate-last-result "OLD"))
    (unwind-protect
        (progn
          ;; ① 有 `gt-result' 片段：写入 last-result 并返回译文
          (with-current-buffer gt-buffer
            (erase-buffer)
            (insert (propertize "面板译文" 'gt-result t)))
          (should (equal (seshat-reader-translate--panel-result) "面板译文"))
          (should (equal seshat-reader-translate-last-result "面板译文"))
          ;; ② 无 `gt-result' 片段：提示失败、保留上次译文
          (with-current-buffer gt-buffer
            (erase-buffer)
            (insert "没有任何属性的文本"))
          (let ((messages nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) messages))))
              (should-not (seshat-reader-translate--panel-result)))
            (should messages))
          (should (equal seshat-reader-translate-last-result "面板译文"))
          ;; ③ 中转 buffer 不存在：返回 nil，不报错
          (kill-buffer gt-buffer)
          (should-not (seshat-reader-translate--panel-result))
          (should (equal seshat-reader-translate-last-result "面板译文")))
      (when (buffer-live-p gt-buffer) (kill-buffer gt-buffer)))))

(ert-deftest seshat-reader-translate-test--render-object-title ()
  "`--render-object' 的 sidebar 分支指向隐藏中转 buffer 并由 `:then' 接管面板."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((seshat-reader-sidebar-enabled t)
         (obj (seshat-reader-translate--render-object 'sidebar "Seshat 解释"))
         (window-config (slot-value obj 'window-config)))
    (should (eq (eieio-object-class obj) 'gt-buffer-render))
    (should (equal (slot-value obj 'name)
                   seshat-reader-translate--gt-buffer-name))
    (should (equal '(display-buffer-no-window) (car window-config)))
    (should (member '(allow-no-window . t) window-config))
    (should (functionp (slot-value obj 'then)))
    ;; `enabled' 为 nil 时回退 posframe（与 `pop' 同款）
    (let ((seshat-reader-sidebar-enabled nil))
      (should (eq (eieio-object-class
                   (seshat-reader-translate--render-object
                    'sidebar "Seshat 解释"))
                  'gt-posframe-pop-render)))))

(ert-deftest seshat-reader-translate-test--render-object-then-passes-langs ()
  "sidebar 渲染对象的 `:then' 回调把 LANGS 与 CONTEXT 透传给 `--render-panel'."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let ((seshat-reader-sidebar-enabled t)
        (calls nil)
        (obj nil))
    (cl-letf (((symbol-function 'seshat-reader-translate--panel-result)
               (lambda () "结果"))
              ((symbol-function 'seshat-reader-translate--render-panel)
               (lambda (&rest args) (push args calls) 'fake-buffer)))
      (setq obj (seshat-reader-translate--render-object
                 'sidebar "Seshat 译文" '(en zh) 'translate))
      (funcall (slot-value obj 'then)))
    (should (equal calls (list (list "结果" "Seshat 译文" '(en zh) 'translate))))))

(ert-deftest seshat-reader-translate-test--install-capture-hook-for-mode-sidebar-no-hook ()
  "sidebar + enabled 时不安装任何捕获 hook（捕获在 `:then' 内完成）."
  (skip-unless (require 'gt nil t))
  (let ((seshat-reader-translate-render 'sidebar)
        (seshat-reader-sidebar-enabled t)
        (gt-buffer-render-output-hook nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (seshat-reader-translate--install-capture-hook-for-mode)
    (should-not gt-buffer-render-output-hook)
    (should-not gt-posframe-pop-render-output-hook)
    (should-not gt-posframe-pin-render-output-hook))
  ;; 对照：posframe 路径（`pop'）仍安装两个 posframe 输出 hook
  (let ((seshat-reader-translate-render 'pop)
        (seshat-reader-sidebar-enabled t)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (seshat-reader-translate--install-capture-hook-for-mode)
    (should (memq #'seshat-reader-translate--capture-result
                  gt-posframe-pop-render-output-hook))
    (should (memq #'seshat-reader-translate--capture-result
                  gt-posframe-pin-render-output-hook))))

;;; 存为批注

(ert-deftest seshat-reader-translate-test--save-as-annotation-posts ()
  "存批注发 POST /api/annotations，body 的 document_id/location/text 正确."
  (let ((dir (file-name-as-directory
              (make-temp-file "seshat-translate-test" t))))
    (unwind-protect
        (let* ((file (expand-file-name "book.pdf" dir))
               (seshat-reader-annotation-roots (list (cons "lib" dir)))
               (seshat-reader-translate-last-result "译文正文")
               (seshat-reader-select-last
                (list :file file :page 3 :rect '(10.0 20.0 30.0 40.0)
                      :text "选区"))
               (calls nil))
          (with-temp-file file)
          (cl-letf (((symbol-function 'seshat-rest--request)
                     (lambda (method path &optional body)
                       (push (list method path body) calls)
                       (cons 201 "{\"id\":7}"))))
            (seshat-reader-translate-save-as-annotation))
          (should calls)
          (let* ((call (car calls))
                 (body (json-parse-string (nth 2 call) :object-type 'alist)))
            (should (equal (nth 0 call) "POST"))
            (should (equal (nth 1 call) "/api/annotations"))
            (should (equal (alist-get 'document_id body) "lib:book.pdf"))
            (should (equal (alist-get 'location body)
                           "page:3;rect:10.00,20.00,30.00,40.00"))
            (should (equal (alist-get 'text body) "译文正文"))))
      (delete-directory dir t))))

(ert-deftest seshat-reader-translate-test--save-as-annotation-without-result-errors ()
  "尚无译文（`last-result' 为 nil）时存批注抛 `user-error'."
  (let ((seshat-reader-translate-last-result nil))
    (should-error (seshat-reader-translate-save-as-annotation) :type 'user-error)))

(ert-deftest seshat-reader-translate-test--save-as-annotation-blank-result-errors ()
  "译文为空白时存批注抛 `user-error'."
  (let ((seshat-reader-translate-last-result "  \n"))
    (should-error (seshat-reader-translate-save-as-annotation) :type 'user-error)))

;;; 启动翻译的错误处理

(ert-deftest seshat-reader-translate-test--gt-start-user-error-bubbles ()
  "`gt-start' 抛 `user-error' 时命令原样冒泡、不崩溃、不吞掉提示."
  (let ((seshat-reader-select-last (seshat-reader-translate-test--selection))
        (seshat-reader-translate-preset 'reader)
        (gt-preset-translators nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (caught nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (_translator) (user-error "翻译启动失败")))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (condition-case err
          (seshat-reader-translate-selection)
        (user-error (setq caught err))))
    (should caught)
    (should (string-match-p "翻译启动失败" (error-message-string caught)))))

(ert-deftest seshat-reader-translate-test--gt-start-generic-error-messages ()
  "`gt-start' 抛一般 error 时命令捕获并 message 提示、不冒泡."
  (let ((seshat-reader-select-last (seshat-reader-translate-test--selection))
        (seshat-reader-translate-preset 'reader)
        (gt-preset-translators nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (messages nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (_translator) (error "底层炸了")))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (seshat-reader-translate-selection))
    (should messages)
    (should (string-match-p "底层炸了" (car messages)))))

;;; 捕获 hook 的挂载

(ert-deftest seshat-reader-translate-test--install-capture-hooks-idempotent ()
  "两个输出 hook 都含捕获函数，且重复调用不重复挂载."
  (let ((gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (seshat-reader-translate--install-capture-hooks)
    (seshat-reader-translate--install-capture-hooks)
    (dolist (hook (list gt-posframe-pop-render-output-hook
                        gt-posframe-pin-render-output-hook))
      (should (memq #'seshat-reader-translate--capture-result hook))
      (should (= 1 (cl-count #'seshat-reader-translate--capture-result hook))))))

;;; 端到端集成（选区 → 译文 → 面板 → 批注）

(defvar seshat-reader-translate-test--translated-text
  "**译文标题**\n\n- 第一段译文\n- 第二段译文"
  "集成用例里由 `gt-start' 桩写入隐藏中转 buffer 的译文（带 Markdown 标记）.
带 Markdown 标记是有意为之：它让面板的视图模式断言（标题/列表被隐藏标记
渲染）有实际意义，而不是只验证纯文本搬运。")

(defun seshat-reader-translate-test--panel-chain ()
  "跑一遍「选区 → 译文 → 面板」链路并返回结果 plist.
返回 `(:panel B :render R :shown L :messages M)'：B 为面板 buffer，R 为装配
出的 gt 渲染对象，L 为 `seshat-reader-sidebar-show' 的实参记录（逆序已恢复），
M 为链路上 `message' 的文本。

本函数把两个外部出口用 `cl-letf' 桩替：`gt-start' 改为「往隐藏中转 buffer
（`seshat-reader-translate--gt-buffer-name'）写入带 `gt-result' 属性的译文，
再调用渲染对象的 `:then' 回调」，`seshat-reader-sidebar-show' 改为记录显示
请求；`message' 一并捕获以免刷屏。因此整条链路**不触网、不写真实文件**。
面板 buffer 名、中转 buffer 名、选区与渲染方式都由调用方的 `let' 绑定决定；
中转 buffer 在返回前删除，面板 buffer 留给调用方 `unwind-protect' 清理。"
  (let ((gt-buffer (get-buffer-create seshat-reader-translate--gt-buffer-name))
        (render nil)
        (shown nil)
        (messages nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gt-start)
                     (lambda (translator)
                       (setq render (slot-value translator 'render))
                       ;; gt 渲染完成：中转 buffer 已写入带 `gt-result' 的译文。
                       (with-current-buffer gt-buffer
                         (erase-buffer)
                         (insert (propertize
                                  seshat-reader-translate-test--translated-text
                                  'gt-result t)))
                       ;; 随后由渲染对象的 `:then' 回调把译文搬进信息面板。
                       (funcall (slot-value render 'then))))
                    ((symbol-function 'seshat-reader-sidebar-show)
                     (lambda (buffer kind &optional select)
                       (push (list buffer kind select) shown)
                       'fake-window))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages)
                       nil)))
            (seshat-reader-translate-selection))
          (list :panel (get-buffer seshat-reader-sidebar-translate-buffer-name)
                :render render
                :shown (nreverse shown)
                :messages (nreverse messages)))
      (when (buffer-live-p gt-buffer) (kill-buffer gt-buffer)))))

(ert-deftest seshat-reader-translate-test--integration-selection-to-panel ()
  "端到端：选区经 gt 渲染后进入信息面板（只读 Markdown 视图 + header-line）.
覆盖「选区 → 翻译器装配 → 渲染对象 `:then' → 面板 buffer → last-result」
整条链路，断言面板内容、视图参数、只读、标题、显示类型与译文记录一致。"
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  ;; markdown-mode 是软依赖：它在 `load-path' 上时显式加载一次，使下面的视图
  ;; 模式断言走到**真实 Markdown 分支**（`batch -Q' 不加载 autoloads，故
  ;; `fboundp' 为 nil）；不在 `load-path' 上时静默返回 nil，由 `text-mode'
  ;; 降级断言兜底——两条分支都必须通过。
  (require 'markdown-mode nil t)
  (let* ((seshat-reader-select-last
          (list :text "Hello world" :page 3
                :file seshat-reader-translate-test--selection-file))
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         (seshat-reader-translate-show-source nil)
         (seshat-reader-translate-preset 'reader)
         (gt-preset-translators nil)
         (seshat-reader-sidebar-translate-buffer-name "*Seshat T6 Panel*")
         (seshat-reader-translate--gt-buffer-name " *Seshat T6 gt*")
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil)
         (seshat-reader-translate-last-result nil)
         (chain nil)
         (panel nil))
    (unwind-protect
        (progn
          (setq chain (seshat-reader-translate-test--panel-chain))
          (setq panel (plist-get chain :panel))
          ;; ① 渲染对象：隐藏中转 buffer 上的 `gt-buffer-render'
          (let ((render (plist-get chain :render)))
            (should (eq (eieio-object-class render) 'gt-buffer-render))
            (should (equal (slot-value render 'name) " *Seshat T6 gt*"))
            (should (member '(allow-no-window . t)
                            (slot-value render 'window-config))))
          ;; ② 面板 buffer 内容 = 默认模板渲染结果（语言对 + 分隔线 + 译文；默认无标题）
          (should (bufferp panel))
          (should (equal (with-current-buffer panel (buffer-string))
                         (concat "*en → zh*\n\n---\n\n"
                                 seshat-reader-translate-test--translated-text
                                 "\n")))
          ;; ③ 只读 Markdown 视图：major-mode / 折行 / 只读 / header-line / 键位
          (with-current-buffer panel
            (if (or (fboundp 'gfm-view-mode) (fboundp 'markdown-view-mode))
                (should (memq major-mode '(gfm-view-mode markdown-view-mode)))
              (should (eq major-mode 'text-mode)))
            (should (null truncate-lines))
            (should word-wrap)
            (should buffer-read-only)
            (should (string-match-p "Seshat 译文"
                                    (format "%s" header-line-format)))
            (should seshat-reader-translate-panel-mode)
            (should (= (point) (point-min))))
          ;; ④ 译文同步写入 last-result（供存为批注使用）
          (should (equal seshat-reader-translate-last-result
                         seshat-reader-translate-test--translated-text))
          ;; ⑤ 经统一显示入口、以 translate 类型显示、请求跟随光标
          (should (equal (plist-get chain :shown)
                         (list (list panel 'translate t))))
          ;; ⑥ 链路上没有失败提示
          (should-not (cl-some (lambda (msg) (string-match-p "失败" msg))
                               (plist-get chain :messages))))
      (when (buffer-live-p panel) (kill-buffer panel)))))

(ert-deftest seshat-reader-translate-test--integration-panel-to-annotation ()
  "端到端：面板里的译文存为服务端批注，document-id/location/text 正确.
承接 `--integration-selection-to-panel' 的链路（同一份选区与译文），再走
`seshat-reader-translate-save-as-annotation'，断言提交给
`seshat-rest-create-annotation' 的三个实参由选区派生且正文取面板内容。"
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((seshat-reader-select-last
          (list :text "Hello world" :page 3
                :rect '(10.0 20.0 30.0 40.0)
                :file seshat-reader-translate-test--selection-file))
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         (seshat-reader-translate-show-source nil)
         (seshat-reader-translate-preset 'reader)
         (gt-preset-translators nil)
         (seshat-reader-sidebar-translate-buffer-name "*Seshat T6 Panel*")
         (seshat-reader-translate--gt-buffer-name " *Seshat T6 gt*")
         (seshat-reader-annotation-roots (list (cons "t6" "/tmp")))
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil)
         (seshat-reader-translate-last-result nil)
         (created nil)
         (messages nil)
         (chain nil)
         (panel nil))
    (unwind-protect
        (progn
          (setq chain (seshat-reader-translate-test--panel-chain))
          (setq panel (plist-get chain :panel))
          ;; 承接上一条：译文已在 last-result 中
          (should (equal seshat-reader-translate-last-result
                         seshat-reader-translate-test--translated-text))
          (cl-letf (((symbol-function 'seshat-rest-create-annotation)
                     (lambda (document-id location text)
                       (push (list document-id location text) created)
                       '((id . 42))))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages)
                       nil)))
            (seshat-reader-translate-save-as-annotation))
          (should (= 1 (length created)))
          (let ((call (car created)))
            ;; document-id 由选区文件经文档根派生（不写真实文件）
            (should (equal (nth 0 call) "t6:seshat-translate-test.pdf"))
            ;; location 带 page: 前缀，且 rect 按两位小数格式化
            (should (string-prefix-p "page:3;" (nth 1 call)))
            (should (equal (nth 1 call)
                           "page:3;rect:10.00,20.00,30.00,40.00"))
            ;; 存批注的正文是纯译文（不含模板结构）
            (should (equal (nth 2 call)
                           seshat-reader-translate-test--translated-text))
            ;; 面板 buffer 包含该纯译文（正文位于模板的 `---' 之后）
            (should (string-match-p
                     (regexp-quote seshat-reader-translate-test--translated-text)
                     (with-current-buffer panel (buffer-string)))))
          ;; 面板确实套了模板：内容以语言对元信息行（模板 `%l'）开头
          (should (string-prefix-p
                   "*en → zh*"
                   (with-current-buffer panel (buffer-string))))
          ;; 成功提示报告批注 id，且不出现「失败」
          (should messages)
          (should (string-match-p "42" (car messages)))
          (should-not (cl-some (lambda (msg) (string-match-p "失败" msg))
                               messages)))
      (when (buffer-live-p panel) (kill-buffer panel)))))

(provide 'seshat-reader-translate-test)
;;; seshat-reader-translate-test.el ends here
