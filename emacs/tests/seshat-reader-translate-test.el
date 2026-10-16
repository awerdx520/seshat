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

(provide 'seshat-reader-translate-test)
;;; seshat-reader-translate-test.el ends here
