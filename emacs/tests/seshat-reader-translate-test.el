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

(defconst seshat-reader-translate-test--uid "01K8Q3M7D2X9V6T1B8N5C0RDEF"
  "测试用的固定 uid（服务端权威文件身份，存批注时发送）.")

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
  "`--capture-result' 在 pick 取 `all' 时把带 `gt-result' 的片段按分隔线拼接.
默认 pick 已改为 `all'（多引擎展示全部结果，见
`seshat-reader-translate-engines-pick'）。本用例的中转 buffer 里片段上方
没有引擎前缀行（无来源），故格式化退化为纯文本：不加 `【来源】' 标签，
但多条之间仍插 Markdown 分隔线。"
  (with-temp-buffer
    (insert (propertize "第一段" 'gt-result t))
    (insert "（无属性，忽略）\n")
    (insert (propertize "第二段" 'gt-result t))
    (let ((seshat-reader-translate-last-result nil)
          (seshat-reader-translate-engines-pick 'all)
          (seshat-reader-translate--active (float-time)))
      (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
        (should (equal (seshat-reader-translate--capture-result)
                       "第一段\n\n---\n\n第二段")))
      (should (equal seshat-reader-translate-last-result
                     "第一段\n\n---\n\n第二段")))))

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

;;; 多引擎结果去重（T3.5：真机反馈「面板显示两份译文」）

(defun seshat-reader-translate-test--insert-pieces (pieces)
  "在当前 buffer 依次插入 PIECES 描述的译文片段.
PIECES 是 `(TEXT . FAILED)' 列表：每个元素插成带 `gt-result' 属性的片段，
FAILED 非 nil 时再带 `gt-buffer-render-error-face'（模拟该引擎失败）。

片段之间插一个**无属性**的换行：真实渲染缓冲区里各引擎结果之间有分隔文本，
而相邻且同属性的片段会被 `text-property-search-forward' 合并成同一个
`gt-result' 区域（那样就测不到「多片段」的场景了）。该行也不带 gt 的引擎
前缀 face，故 `seshat-reader-translate--result-source' 取不到来源（标签为
nil）——需要来源标注的用例改用
`seshat-reader-translate-test--insert-engine-results'。"
  (dolist (piece pieces)
    (insert (if (cdr piece)
                (propertize (car piece) 'gt-result t
                            'face 'gt-buffer-render-error-face)
              (propertize (car piece) 'gt-result t)))
    (insert "\n")))

(defun seshat-reader-translate-test--insert-engine-results (entries)
  "按 gt 的真实渲染格式在当前 buffer 插入引擎结果片段.
ENTRIES 是 `(TEXT FAILED SOURCE)' 列表。gt 的 `gt-buffer-render-init' 把每个
引擎的 `:prefix' 渲染成**单独一行**（带
`gt-buffer-render-block-prefix-face'），随后再写一个**空行**，然后才写带
`gt-result' 属性的结果片段——原文未被切成多段时就是这种「前缀行 + 空行 +
结果」三行结构；单引擎没有前缀行，只有结果行。本函数如实复刻该结构（face
符号以引号形式使用，不依赖 face 是否已定义），用于验证「上一行（跳过空行）
取来源」的契约。"
  (dolist (entry entries)
    (let ((text (nth 0 entry))
          (failed (nth 1 entry))
          (source (nth 2 entry)))
      (when source
        (insert (propertize (concat source "\n")
                            'face 'gt-buffer-render-block-prefix-face))
        (insert "\n"))
      (insert (if failed
                  (propertize text 'gt-result t
                              'face 'gt-buffer-render-error-face)
                (propertize text 'gt-result t)))
      (insert "\n\n"))))

(ert-deftest seshat-reader-translate-test--extract-pick-first-takes-first ()
  "pick 取 `first' 时只返回第一个片段（默认取值为 `all'，见 T3.7）."
  (with-temp-buffer
    (seshat-reader-translate-test--insert-pieces
     '(("youdao 译文" . nil) ("google 译文" . nil)))
    (let ((seshat-reader-translate-engines-pick 'first))
      (should (equal (seshat-reader-translate--extract-result)
                     '("youdao 译文"))))))

(ert-deftest seshat-reader-translate-test--extract-pick-last-takes-last ()
  "pick 取 `last' 时返回最后一个成功片段."
  (with-temp-buffer
    (seshat-reader-translate-test--insert-pieces
     '(("youdao 译文" . nil) ("google 译文" . nil)))
    (let ((seshat-reader-translate-engines-pick 'last))
      (should (equal (seshat-reader-translate--extract-result)
                     '("google 译文"))))))

(ert-deftest seshat-reader-translate-test--extract-pick-all-joins-successes ()
  "pick 取 `all' 时把所有成功片段用 Markdown 分隔线拼接（失败片段跳过）."
  (with-temp-buffer
    (seshat-reader-translate-test--insert-pieces
     '(("youdao 译文" . nil) ("失败片段" . t) ("google 译文" . nil)))
    (let ((seshat-reader-translate-engines-pick 'all))
      (should (equal (seshat-reader-translate--extract-result)
                     '("youdao 译文\n\n---\n\ngoogle 译文"))))))

(ert-deftest seshat-reader-translate-test--extract-pick-first-skips-failed ()
  "pick 取 `first' 时首个片段带 error face 则顺延到下一个成功片段."
  (with-temp-buffer
    (seshat-reader-translate-test--insert-pieces
     '(("失败片段" . t) ("google 译文" . nil)))
    (let ((seshat-reader-translate-engines-pick 'first))
      (should (equal (seshat-reader-translate--extract-result)
                     '("google 译文"))))))

(ert-deftest seshat-reader-translate-test--extract-all-failed-returns-failed ()
  "全部片段都失败或没有片段时返回 `(nil . t)'（失败语义不变）."
  (with-temp-buffer
    (seshat-reader-translate-test--insert-pieces
     '(("失败一" . t) ("失败二" . t)))
    (dolist (pick '(first last all))
      (let ((seshat-reader-translate-engines-pick pick))
        (should (equal (seshat-reader-translate--extract-result) (cons nil t))))))
  ;; 无任何 `gt-result' 片段：同样判定为失败
  (with-temp-buffer
    (insert "没有任何属性的文本")
    (let ((seshat-reader-translate-engines-pick 'first))
      (should (equal (seshat-reader-translate--extract-result) (cons nil t))))))

;;; 多引擎结果标注来源 + 分隔线（T3.7：默认展示全部结果）

(ert-deftest seshat-reader-translate-test--format-engine-results-all-labels-and-separates ()
  "pick 取 `all' 时逐条标注来源并用 Markdown 分隔线分段."
  (should (equal (seshat-reader-translate--format-engine-results
                  '(("A" nil "youdao") ("B" nil "google")) 'all)
                 "【youdao】\nA\n\n---\n\n【google】\nB")))

(ert-deftest seshat-reader-translate-test--format-engine-results-all-without-source ()
  "pick 取 `all' 且来源为 nil/空串时只保留分隔线、不加标签."
  (should (equal (seshat-reader-translate--format-engine-results
                  '(("A" nil nil) ("B" nil "")) 'all)
                 "A\n\n---\n\nB"))
  ;; 单条且无来源：纯文本，连分隔线也没有
  (should (equal (seshat-reader-translate--format-engine-results
                  '(("A" nil nil)) 'all)
                 "A")))

(ert-deftest seshat-reader-translate-test--format-engine-results-all-skips-failed ()
  "pick 取 `all' 时跳过失败条目，成功条目仍带自己的来源标签."
  (should (equal (seshat-reader-translate--format-engine-results
                  '(("A" t "youdao") ("B" nil "google")) 'all)
                 "【google】\nB")))

(ert-deftest seshat-reader-translate-test--format-engine-results-all-all-failed ()
  "全部条目失败、或列表为空时 pick 取 `all' 返回 nil."
  (should-not (seshat-reader-translate--format-engine-results
               '(("A" t "youdao") ("B" t "google")) 'all))
  (should-not (seshat-reader-translate--format-engine-results nil 'all)))

(ert-deftest seshat-reader-translate-test--format-engine-results-first-last-return-plain-text ()
  "pick 取 `first'/`last' 时返回纯译文，不带来源标签与分隔线."
  (let ((results '(("A" nil "youdao") ("B" t "google") ("C" nil "bing"))))
    (should (equal (seshat-reader-translate--format-engine-results
                    results 'first)
                   "A"))
    (should (equal (seshat-reader-translate--format-engine-results
                    results 'last)
                   "C")))
  ;; 未知 pick 值按 `all' 处理（配置写错时不静默丢结果）
  (should (equal (seshat-reader-translate--format-engine-results
                  '(("A" nil "youdao") ("B" nil "google")) 'bogus)
                 "【youdao】\nA\n\n---\n\n【google】\nB")))

(ert-deftest seshat-reader-translate-test--extract-result-source-from-previous-line ()
  "`--extract-result' 从片段上方的引擎前缀行取来源；取不到时退化为纯文本."
  ;; ① gt 实际布局（前缀行 + 空行 + 结果，多引擎）：每条带来源标签与分隔线
  (with-temp-buffer
    (seshat-reader-translate-test--insert-engine-results
     '(("youdao 译文" nil "youdao") ("google 译文" nil "google")))
    (let ((seshat-reader-translate-engines-pick 'all))
      (should (equal (seshat-reader-translate--extract-result)
                     '("【youdao】\nyoudao 译文\n\n---\n\n【google】\ngoogle 译文")))))
  ;; ② 前缀行紧贴结果（原文被切成多段时 gt 不再写空行）：同样取到来源
  (with-temp-buffer
    (insert (propertize "youdao\n" 'face
                        'gt-buffer-render-inline-prefix-face))
    (insert (propertize "译文" 'gt-result t))
    (let ((seshat-reader-translate-engines-pick 'all))
      (should (equal (seshat-reader-translate--extract-result)
                     '("【youdao】\n译文")))))
  ;; ③ 片段上方是原文引用块（gt source face，单引擎无前缀行）：不含标签
  (with-temp-buffer
    (insert "\n")
    (insert (propertize "Hello world\n\n" 'face 'gt-buffer-render-source-face))
    (insert (propertize "译文" 'gt-result t))
    (let ((seshat-reader-translate-engines-pick 'all))
      (should (equal (seshat-reader-translate--extract-result) '("译文")))))
  ;; ④ 片段上方只有空行：不含标签
  (with-temp-buffer
    (insert "\n\n")
    (insert (propertize "译文" 'gt-result t))
    (let ((seshat-reader-translate-engines-pick 'all))
      (should (equal (seshat-reader-translate--extract-result) '("译文")))))
  ;; ⑤ 失败片段也带来源时仍被跳过（来源不影响失败判定）
  (with-temp-buffer
    (seshat-reader-translate-test--insert-engine-results
     '(("失败译文" t "youdao") ("google 译文" nil "google")))
    (let ((seshat-reader-translate-engines-pick 'all))
      (should (equal (seshat-reader-translate--extract-result)
                     '("【google】\ngoogle 译文"))))))

;;; 面板内 Markdown 文本 buffer 渲染

(ert-deftest seshat-reader-translate-test--render-panel-writes-text-and-view ()
  "`--render-panel' 把译文写入面板 buffer、设只读视图与 header-line，并经 show 显示."
  (skip-unless (require 'gt nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name "*Seshat Test Panel*")
         (seshat-reader-translate-show-source nil)
         ;; 本用例只验证「写入 + 视图」，把模板关掉以免与模板渲染耦合
         (seshat-reader-translate-template nil)
         ;; 折行模式（`seshat-reader-panel-truncate-lines' 为 nil）下的视图断言；
         ;; 不折行 + 横向滚动的新默认行为在
         ;; `seshat-reader-translate-test--prepare-view-truncate-lines' 里单独测。
         (seshat-reader-panel-truncate-lines nil)
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
  "`--prepare-view' 在 `seshat-reader-translate-visual-fill-column' 为 t 时启用 vfc.
须同时把 `seshat-reader-panel-truncate-lines' 设为 nil：折行与 vfc 互斥，不折行
模式（默认）下 vfc 被整体跳过。"
  (skip-unless (require 'visual-fill-column nil t))
  (with-temp-buffer
    (let ((seshat-reader-translate-visual-fill-column t)
          (seshat-reader-panel-truncate-lines nil))
      (seshat-reader-translate--prepare-view)
      (should visual-fill-column-mode))))

(ert-deftest seshat-reader-translate-test--prepare-view-honors-disable-option ()
  "选项为 nil 时 `--prepare-view' 不启用 `visual-fill-column-mode'.
测试 buffer 无窗口，故 `-1' 守卫分支也不会执行。"
  (skip-unless (require 'visual-fill-column nil t))
  (with-temp-buffer
    (let ((seshat-reader-translate-visual-fill-column nil)
          (seshat-reader-panel-truncate-lines nil))
      (seshat-reader-translate--prepare-view)
      (should-not visual-fill-column-mode))))

(ert-deftest seshat-reader-translate-test--prepare-view-truncate-lines-on ()
  "`seshat-reader-panel-truncate-lines' 非 nil：不折行 + 允许横向滚动，并跳过 vfc."
  (with-temp-buffer
    (let ((seshat-reader-panel-truncate-lines t)
          (seshat-reader-translate-visual-fill-column t))
      (seshat-reader-translate--prepare-view)
      (should truncate-lines)
      (should-not word-wrap)
      ;; 横向滚动开关：长行超出面板宽度后 `scroll-left' / `C-x <' 才有效
      (should auto-hscroll-mode)
      (should buffer-read-only)
      ;; 互斥：不折行模式下即使 vfc 开关为 t 也不启用它
      (should-not (bound-and-true-p visual-fill-column-mode)))))

(ert-deftest seshat-reader-translate-test--prepare-view-word-wrap-when-disabled ()
  "`seshat-reader-panel-truncate-lines' 为 nil 时保持折行（原行为）。"
  (with-temp-buffer
    (let ((seshat-reader-panel-truncate-lines nil))
      (seshat-reader-translate--prepare-view)
      (should-not truncate-lines)
      (should word-wrap))))

(ert-deftest seshat-reader-translate-test--prepare-view-tolerates-missing-visual-fill-column ()
  "`visual-fill-column' 软依赖缺失时 `--prepare-view' 静默跳过、不报错.
用 `cl-letf' 桩 `fboundp' 与 `require' 模拟包未安装：仅对
`visual-fill-column-mode'/`visual-fill-column' 返回 nil，其它符号透传给原
函数——`--prepare-view' 还用 `fboundp' 判定 `gfm-view-mode'/
`markdown-view-mode'，不透传会破坏视图 mode 的降级链。"
  (with-temp-buffer
    (let ((seshat-reader-translate-visual-fill-column t)
          ;; 折行模式才有 vfc 路径（不折行模式下整体跳过）
          (seshat-reader-panel-truncate-lines nil)
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
  "sidebar + enabled 时不装 posframe 捕获 hook；流式开启时只装增量同步 hook."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  ;; ① 默认（流式开启）：挂 `gt-buffer-render-output-hook' 的增量同步，不挂 posframe
  (let ((seshat-reader-translate-render 'sidebar)
        (seshat-reader-sidebar-enabled t)
        (seshat-reader-translate-stream t)
        (gt-buffer-render-output-hook nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (seshat-reader-translate--install-capture-hook-for-mode)
    (should (memq #'seshat-reader-translate--stream-sync
                  gt-buffer-render-output-hook))
    (should-not gt-posframe-pop-render-output-hook)
    (should-not gt-posframe-pin-render-output-hook))
  ;; ② 关掉流式：三个 hook 都不装（译文捕获仍在 `:then' 内完成）
  (let ((seshat-reader-translate-render 'sidebar)
        (seshat-reader-sidebar-enabled t)
        (seshat-reader-translate-stream nil)
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
        (seshat-reader-translate-stream t)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (seshat-reader-translate--install-capture-hook-for-mode)
    (should (memq #'seshat-reader-translate--capture-result
                  gt-posframe-pop-render-output-hook))
    (should (memq #'seshat-reader-translate--capture-result
                  gt-posframe-pin-render-output-hook))))

;;; 存为批注

(ert-deftest seshat-reader-translate-test--save-as-annotation-posts ()
  "存批注发 POST /api/annotations，body 的 uid/location/text 正确（不发 doc-id）."
  (let ((dir (file-name-as-directory
              (make-temp-file "seshat-translate-test" t))))
    (unwind-protect
        (let* ((file (expand-file-name "book.pdf" dir))
               (seshat-reader-annotation-roots (list (cons "lib" dir)))
               (seshat-reader-annotation--uid-cache nil)
               (seshat-reader-translate-last-result "译文正文")
               (seshat-reader-select-last
                (list :file file :page 3 :rect '(10.0 20.0 30.0 40.0)
                      :text "选区"))
               (calls nil))
          (with-temp-file file)
          (cl-letf (((symbol-function 'seshat-rest--request)
                     (lambda (method path &optional body)
                       (push (list method path body) calls)
                       (cons 201 "{\"id\":7}")))
                    ((symbol-function 'seshat-rest-resolve-uid)
                     (lambda (_root _path)
                       seshat-reader-translate-test--uid)))
            (seshat-reader-translate-save-as-annotation))
          (should calls)
          (let* ((call (car calls))
                 (body (json-parse-string (nth 2 call) :object-type 'alist)))
            (should (equal (nth 0 call) "POST"))
            (should (equal (nth 1 call) "/api/annotations"))
            ;; 存批注发给服务端的是服务端权威 uid，不是显示用的 doc-id
            (should (equal (alist-get 'uid body)
                           seshat-reader-translate-test--uid))
            (should-not (alist-get 'document-id body))
            (should-not (equal (alist-get 'uid body) "lib:book.pdf"))
            (should (equal (alist-get 'location body)
                           "page:3;rect:10.00,20.00,30.00,40.00"))
            (should (equal (alist-get 'text body) "译文正文"))))
      (delete-directory dir t))))

(ert-deftest seshat-reader-translate-test--save-as-annotation-unregistered-errors ()
  "文档未在服务端登记（resolve 返回 nil）时存批注抛 `user-error'、不发 POST."
  (let ((dir (file-name-as-directory
              (make-temp-file "seshat-translate-test" t))))
    (unwind-protect
        (let* ((file (expand-file-name "book.pdf" dir))
               (seshat-reader-annotation-roots (list (cons "lib" dir)))
               (seshat-reader-annotation--uid-cache nil)
               (seshat-reader-translate-last-result "译文正文")
               (seshat-reader-select-last
                (list :file file :page 3 :rect '(10.0 20.0 30.0 40.0)
                      :text "选区"))
               (calls nil)
               (caught nil))
          (with-temp-file file)
          (cl-letf (((symbol-function 'seshat-rest--request)
                     (lambda (method path &optional body)
                       (push (list method path body) calls)
                       (cons 201 "{\"id\":7}")))
                    ((symbol-function 'seshat-rest-resolve-uid)
                     (lambda (_root _path) nil))
                    ((symbol-function 'message) (lambda (&rest _) nil)))
            (condition-case err
                (seshat-reader-translate-save-as-annotation)
              (user-error (setq caught err))))
          (should caught)
          (should (string-match-p "文档未在服务端登记"
                                  (error-message-string caught)))
          (should-not calls))
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
         ;; 折行模式下的视图断言（见 `--prepare-view-truncate-lines'）
         (seshat-reader-panel-truncate-lines nil)
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
  "端到端：面板里的译文存为服务端批注，uid/location/text 正确.
承接 `--integration-selection-to-panel' 的链路（同一份选区与译文），再走
`seshat-reader-translate-save-as-annotation'，断言提交给
`seshat-rest-create-annotation' 的三个实参由选区派生且正文取面板内容
（首个实参是服务端权威 uid，显示用 doc-id 不参与提交）。"
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
                     ;; create 自 v8 起有 5 个实参（新增 kind / selected-text）；
                     ;; 桩点用 &optional 兜住，仍只断言前三个实参。
                     (lambda (uid location text &optional _kind _selected)
                       (push (list uid location text) created)
                       '((id . 42))))
                    ((symbol-function 'seshat-rest-resolve-uid)
                     (lambda (_root _path) seshat-reader-translate-test--uid))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages)
                       nil)))
            (seshat-reader-translate-save-as-annotation))
          (should (= 1 (length created)))
          (let ((call (car created)))
            ;; 第一个实参是服务端权威 uid（不是显示用的 doc-id）
            (should (equal (nth 0 call) seshat-reader-translate-test--uid))
            (should-not (equal (nth 0 call) "t6:seshat-translate-test.pdf"))
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

;;; 流式增量渲染（T4）

(defun seshat-reader-translate-test--stream-translator ()
  "返回一个空的 gt translator 桩，供流式守卫的身份比对使用.
顺带确保 `gt-render-buffer' 已加载——buffer-local 变量
`gt-buffer-render-translator' 由该库定义，`--stream-sync' 的守卫要用 `boundp'
判定它是否存在。"
  (require 'gt-render-buffer)
  (gt-translator :engines nil))

(defun seshat-reader-translate-test--stream-feed (translator text &optional loading)
  "在临时「中转 buffer」里放入片段 TEXT 并调用 `--stream-sync'.
LOADING 非 nil 时给片段加 `gt-buffer-render-loading-face'（模拟 gt 的
`Loading...' 占位）。用 `with-temp-buffer' 复刻 gt 的中转 buffer 环境：
`--stream-sync' 被调用时 `current-buffer' 就是中转 buffer，且
`gt-buffer-render-translator' 是 buffer-local。"
  (with-temp-buffer
    (setq-local gt-buffer-render-translator translator)
    (if loading
        (insert (propertize text 'gt-result t
                            'face 'gt-buffer-render-loading-face))
      (insert (propertize text 'gt-result t)))
    (seshat-reader-translate--stream-sync)))

(ert-deftest seshat-reader-translate-test--stream-sync-skips-when-disabled ()
  "`seshat-reader-translate-stream' 为 nil 时 `--stream-sync' 不写面板."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((panel-name "*Seshat Test Stream Panel*")
         (seshat-reader-sidebar-translate-buffer-name panel-name)
         (trans (seshat-reader-translate-test--stream-translator))
         (seshat-reader-translate-stream nil)
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         (seshat-reader-translate--current-translator trans)
         (seshat-reader-translate--active (float-time))
         (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (&rest args) (push args shown) 'fake-window)))
          (seshat-reader-translate-test--stream-feed trans "译文片段")
          (should-not shown)
          (should-not (get-buffer panel-name))
          ;; 打开开关后再喂一次，面板就建起来了（对照组，证明上一步不是「实现没生效」）
          (let ((seshat-reader-translate-stream t))
            (seshat-reader-translate-test--stream-feed trans "译文片段")
            (should (get-buffer panel-name))))
      (when (get-buffer panel-name) (kill-buffer (get-buffer panel-name))))))

(ert-deftest seshat-reader-translate-test--stream-sync-skips-foreign-translator ()
  "中转 buffer 的 translator 与本次登记的不同（其它 gt 用法）时不写面板."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((panel-name "*Seshat Test Stream Panel*")
         (seshat-reader-sidebar-translate-buffer-name panel-name)
         (mine (seshat-reader-translate-test--stream-translator))
         (theirs (seshat-reader-translate-test--stream-translator))
         (seshat-reader-translate-stream t)
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         ;; 本包登记的是 MINE，而中转 buffer 里挂的是 THEIRS
         (seshat-reader-translate--current-translator mine)
         (seshat-reader-translate--active (float-time))
         (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (&rest args) (push args shown) 'fake-window)))
          (seshat-reader-translate-test--stream-feed theirs "别人的译文")
          (should-not shown)
          (should-not (get-buffer panel-name))
          ;; 换成自己的 translator 后应当通过守卫
          (seshat-reader-translate-test--stream-feed mine "自己的译文")
          (should (get-buffer panel-name)))
      (when (get-buffer panel-name) (kill-buffer (get-buffer panel-name))))))

(ert-deftest seshat-reader-translate-test--stream-sync-writes-skeleton-once ()
  "两次增量只写一次模板骨架：原文引用块在面板正文里只出现 1 次."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((panel-name "*Seshat Test Stream Panel*")
         (seshat-reader-sidebar-translate-buffer-name panel-name)
         (trans (seshat-reader-translate-test--stream-translator))
         (seshat-reader-translate-stream t)
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         (seshat-reader-translate--current-translator trans)
         (seshat-reader-translate--active (float-time))
         (seshat-reader-translate--stream-title "Seshat 译文")
         (seshat-reader-translate--stream-langs nil)
         (seshat-reader-translate--stream-context 'translate)
         (seshat-reader-translate-show-source t)
         (seshat-reader-select-last (list :text "原文片段"))
         (shown nil)
         (panel nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (buffer kind &optional select)
                     (push (list buffer kind select) shown)
                     'fake-window)))
          (seshat-reader-translate-test--stream-feed trans "第一段")
          (seshat-reader-translate-test--stream-feed trans "第一段与第二段")
          (setq panel (get-buffer panel-name))
          (should (bufferp panel))
          ;; 面板以 SELECT=nil 显示（流式期间不抢焦点）
          (should (= 1 (length shown)))
          (should (null (nth 2 (car shown))))
          (with-current-buffer panel
            (should (equal seshat-reader-translate--panel-skeleton t))
            (should (markerp seshat-reader-translate--panel-body-marker))
            (goto-char (point-min))
            ;; 骨架只写一次
            (should (= 1 (how-many (regexp-quote "> **原文**"))))
            (should (= 1 (how-many "^---$")))
            (should (string-match-p "第一段与第二段" (buffer-string)))
            ;; header-line 带「生成中…」状态后缀
            (should (string-match-p "生成中" header-line-format))))
      (when (get-buffer panel-name) (kill-buffer (get-buffer panel-name))))))

(ert-deftest seshat-reader-translate-test--stream-sync-replaces-body ()
  "第二次增量只替换正文区：旧正文消失、骨架保持不变."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((panel-name "*Seshat Test Stream Panel*")
         (seshat-reader-sidebar-translate-buffer-name panel-name)
         (trans (seshat-reader-translate-test--stream-translator))
         (seshat-reader-translate-stream t)
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         (seshat-reader-translate--current-translator trans)
         (seshat-reader-translate--active (float-time))
         (seshat-reader-translate--stream-title "Seshat 译文")
         (seshat-reader-translate--stream-langs nil)
         (seshat-reader-translate--stream-context 'translate)
         (seshat-reader-translate-show-source t)
         (seshat-reader-select-last (list :text "原文片段"))
         (panel nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                   (lambda (&rest _args) 'fake-window)))
          (seshat-reader-translate-test--stream-feed trans "旧译文")
          (seshat-reader-translate-test--stream-feed trans "新译文")
          (setq panel (get-buffer panel-name))
          (with-current-buffer panel
            (let ((content (buffer-string)))
              (should (string-match-p "新译文" content))
              ;; 旧正文被整块替换，而不是追加
              (should-not (string-match-p "旧译文" content))
              ;; 骨架区完好（引用块 + 分隔线各一次），正文在分隔线之后
              (goto-char (point-min))
              (should (= 1 (how-many (regexp-quote "> **原文**"))))
              (should (= 1 (how-many "^---$")))
              (should (string-suffix-p "---\n新译文\n" content)))))
      (when (get-buffer panel-name) (kill-buffer (get-buffer panel-name))))))

(ert-deftest seshat-reader-translate-test--stream-sync-ignores-loading ()
  "片段仍是 gt 的 `Loading...' 占位时不写面板（面板不创建）."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((panel-name "*Seshat Test Stream Panel*")
         (seshat-reader-sidebar-translate-buffer-name panel-name)
         (trans (seshat-reader-translate-test--stream-translator))
         (seshat-reader-translate-stream t)
         (seshat-reader-translate-render 'sidebar)
         (seshat-reader-sidebar-enabled t)
         (seshat-reader-translate--current-translator trans)
         (seshat-reader-translate--active (float-time))
         (shown nil))
    (unwind-protect
        (progn
          ;; 先确认 `--extract-result' 带 SKIP-LOADING 时确实把占位过滤干净
          (with-temp-buffer
            (insert (propertize seshat-reader-translate--loading-text
                                'gt-result t
                                'face 'gt-buffer-render-loading-face))
            (should (equal (seshat-reader-translate--extract-result t)
                           '(nil . t)))
            ;; 不过滤时它会被当译文取出来（对照，说明过滤是必要的）
            (should (equal (car (seshat-reader-translate--extract-result))
                           seshat-reader-translate--loading-text)))
          (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                     (lambda (&rest args) (push args shown) 'fake-window)))
            (seshat-reader-translate-test--stream-feed
             trans seshat-reader-translate--loading-text t)
            (should-not shown)
            (should-not (get-buffer panel-name))))
      (when (get-buffer panel-name) (kill-buffer (get-buffer panel-name))))))

(ert-deftest seshat-reader-translate-test--panel-result-keeps-stream-content ()
  "流式已渲染时 `--panel-result' 不重写面板，只把 header-line 改成「已完成」."
  (skip-unless (require 'gt nil t))
  (let* ((panel-name "*Seshat Test Stream Panel*")
         (seshat-reader-sidebar-translate-buffer-name panel-name)
         (gt-buffer (get-buffer-create seshat-reader-translate--gt-buffer-name))
         (seshat-reader-translate-last-result nil)
         (panel (get-buffer-create panel-name)))
    (unwind-protect
        (progn
          ;; 造一个「已由流式骨架渲染过」的面板
          (with-current-buffer panel
            (insert "> **原文**\n>\n> 原文片段\n\n---\n流式正文\n")
            (setq seshat-reader-translate--panel-skeleton t)
            (setq seshat-reader-translate--panel-title "Seshat 译文")
            (setq-local header-line-format "Seshat 译文（生成中…）"))
          (with-current-buffer gt-buffer
            (erase-buffer)
            (insert (propertize "流式正文" 'gt-result t)))
          (should (equal (seshat-reader-translate--panel-result) "流式正文"))
          ;; 面板内容一字未变（没有 erase 重写）
          (with-current-buffer panel
            (should (equal (buffer-string)
                           "> **原文**\n>\n> 原文片段\n\n---\n流式正文\n"))
            (should-not seshat-reader-translate--panel-skeleton)
            (should-not (string-match-p "生成中" header-line-format))
            (should (string-match-p "已完成" header-line-format)))
          ;; 译文照常记录（存批注依赖它）
          (should (equal seshat-reader-translate-last-result "流式正文")))
      (when (buffer-live-p panel) (kill-buffer panel))
      (when (buffer-live-p gt-buffer) (kill-buffer gt-buffer)))))

(ert-deftest seshat-reader-translate-test--extract-result-source-strips-stream-suffix ()
  "引擎前缀行的 \" (stream)\" 后缀不进入来源标签."
  (with-temp-buffer
    (insert (propertize "youdao (stream)\n"
                        'face 'gt-buffer-render-block-prefix-face))
    (insert "\n")
    (insert (propertize "译文" 'gt-result t))
    (should (equal (car (seshat-reader-translate--extract-result))
                   "【youdao】\n译文")))
  (should (equal (seshat-reader-translate--strip-stream-mark "google (stream)")
                 "google"))
  (should (equal (seshat-reader-translate--strip-stream-mark "google")
                 "google")))

(ert-deftest seshat-reader-translate-test--enable-stream-clones-engines ()
  "`--enable-stream' 为引擎克隆体开流式，且不改预设共享的引擎对象（H5）."
  (skip-unless (require 'gt nil t))
  ;; 用 `delimit' 为 nil 的 chatgpt 引擎：只有这类引擎会被开流式
  ;; （google/youdao 的 `delimit' 默认 t，见下面几条用例）。
  (let* ((preset-engine (gt-chatgpt-engine))
         (preset (gt-translator :engines (list preset-engine)))
         (trans (clone preset))
         (seshat-reader-translate--current-translator nil))
    (seshat-reader-translate--enable-stream trans)
    ;; 克隆出来的 translator 有自己的一份引擎，且已开流式
    (let ((engines (slot-value trans 'engines)))
      (should (= 1 (length engines)))
      (should-not (eq (car engines) preset-engine))
      (should (eq (eieio-object-class (car engines)) 'gt-chatgpt-engine))
      (should (eq (slot-value (car engines) 'stream) t)))
    ;; 预设里那个引擎对象没有被污染
    (should-not (slot-value preset-engine 'stream))
    ;; 登记了本次请求的 translator（守卫用）
    (should (eq seshat-reader-translate--current-translator trans))))

(ert-deftest seshat-reader-translate-test--enable-stream-skips-delimit-engines ()
  "`delimit' 非 nil 的引擎不开流式：不改槽、也不被克隆替换."
  (skip-unless (require 'gt nil t))
  (let* ((engine (gt-google-engine))
         (trans (gt-translator :engines (list engine)))
         (seshat-reader-translate--current-translator nil))
    ;; google 引擎的 `delimit' 默认 t（依赖 gt 的 join）
    (should (eq (oref engine delimit) t))
    (seshat-reader-translate--enable-stream trans)
    (let ((engines (oref trans engines)))
      (should (= 1 (length engines)))
      ;; 未开流式
      (should-not (oref (car engines) stream))
      ;; 且是**同一个对象**：不 clone、不替换
      (should (eq (car engines) engine)))))

(ert-deftest seshat-reader-translate-test--enable-stream-clones-nil-delimit-engines ()
  "`delimit' 为 nil 的引擎开流式，且原对象不被污染."
  (skip-unless (require 'gt nil t))
  (let* ((engine (gt-chatgpt-engine))
         (trans (gt-translator :engines (list engine)))
         (seshat-reader-translate--current-translator nil))
    ;; chatgpt 引擎未覆盖 `delimit'，继承基类的 nil
    (should-not (oref engine delimit))
    (seshat-reader-translate--enable-stream trans)
    (let ((result (car (oref trans engines))))
      (should (oref result stream))
      ;; 新对象（克隆体），原引擎保持原样
      (should-not (eq result engine))
      (should-not (oref engine stream)))))

(ert-deftest seshat-reader-translate-test--enable-stream-mixed-engines ()
  "混合引擎：顺序与长度不变，只有 `delimit' 为 nil 的那个被开流式."
  (skip-unless (require 'gt nil t))
  (let* ((google (gt-google-engine))
         (chatgpt (gt-chatgpt-engine))
         (trans (gt-translator :engines (list google chatgpt)))
         (seshat-reader-translate--current-translator nil))
    (seshat-reader-translate--enable-stream trans)
    (let ((engines (oref trans engines)))
      (should (= 2 (length engines)))
      ;; 顺序不变
      (should (eq (eieio-object-class (nth 0 engines)) 'gt-google-engine))
      (should (eq (eieio-object-class (nth 1 engines)) 'gt-chatgpt-engine))
      ;; 前者不流式（原对象），后者流式（克隆体）
      (should-not (oref (nth 0 engines) stream))
      (should (eq (nth 0 engines) google))
      (should (oref (nth 1 engines) stream))
      (should-not (eq (nth 1 engines) chatgpt)))))

(ert-deftest seshat-reader-translate-test--stream-wanted-p ()
  "面板路径不给引擎开流式；开关关闭或退回 posframe 的判定见各分支."
  ;; ① 面板渲染 + 面板启用：绝不流式（即便开关为 t）
  (let ((seshat-reader-translate-render 'sidebar)
        (seshat-reader-sidebar-enabled t)
        (seshat-reader-translate-stream t))
    (should-not (seshat-reader-translate--stream-wanted-p)))
  ;; ② 开关关闭：任何渲染方式都不流式
  (let ((seshat-reader-translate-render 'pop)
        (seshat-reader-sidebar-enabled t)
        (seshat-reader-translate-stream nil))
    (should-not (seshat-reader-translate--stream-wanted-p)))
  ;; ③ posframe 渲染 + 开关打开：维持流式
  (let ((seshat-reader-translate-render 'pop)
        (seshat-reader-sidebar-enabled t)
        (seshat-reader-translate-stream t))
    (should (seshat-reader-translate--stream-wanted-p)))
  ;; ④ 渲染方式为面板但面板被禁用（实际退回 posframe）：仍允许流式
  (let ((seshat-reader-translate-render 'sidebar)
        (seshat-reader-sidebar-enabled nil)
        (seshat-reader-translate-stream t))
    (should (seshat-reader-translate--stream-wanted-p))))

(ert-deftest seshat-reader-translate-test--translator-panel-disables-stream ()
  "面板路径下 `--translator' 不开引擎流式（gt 纯流式下 `:then' 与
`gt-buffer-render-output-hook' 都不触发，开了只会让面板彻底不出现）."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (skip-unless (require 'gt-render-posframe nil t))
  (let* ((preset (gt-translator :engines (list (gt-chatgpt-engine))))
         (seshat-reader-translate-presets (list (cons 'diag-preset preset))))
    ;; ① 面板渲染：即便 `seshat-reader-translate-stream' 为 t 也不开流式
    (let ((seshat-reader-translate-render 'sidebar)
          (seshat-reader-sidebar-enabled t)
          (seshat-reader-translate-stream t))
      (should-not (oref (car (oref (seshat-reader-translate--translator
                                    'diag-preset "AAA" '(en zh))
                                   engines))
                        stream)))
    ;; ② posframe 渲染：开关为 t 时照旧开流式（行为不变）
    (let ((seshat-reader-translate-render 'pop)
          (seshat-reader-sidebar-enabled t)
          (seshat-reader-translate-stream t))
      (should (oref (car (oref (seshat-reader-translate--translator
                                'diag-preset "AAA" '(en zh))
                               engines))
                    stream)))))

;;; 追问（多轮 messages）

(defconst seshat-reader-translate-test--panel-name "*Seshat Test Follow-up Panel*"
  "追问用例使用的面板 buffer 名（与生产名区分，用例结束即杀掉）.")

(defun seshat-reader-translate-test--follow-up-panel (state)
  "重建追问测试面板 buffer 并把追问状态 STATE 写成它的 buffer-local 值.
STATE 为 plist（可含 `:source' `:answer' `:langs' `:kind' `:round' `:turns'
`:answer-marker' `:answer-start'），nil 表示「面板存在但还没有追问状态」。
返回该 buffer；用例负责在结束时杀掉它。"
  (let ((panel (get-buffer-create seshat-reader-translate-test--panel-name)))
    (with-current-buffer panel
      (erase-buffer)
      (insert "> **原文**\n>\n> 原文片段\n\n---\n首轮解释\n")
      (setq-local seshat-reader-translate--panel-title "Seshat 解释")
      (setq-local header-line-format "Seshat 解释（已完成）")
      (setq seshat-reader-translate--follow-up-state state))
    panel))

(ert-deftest seshat-reader-translate-test--follow-up-messages-order ()
  "messages 顺序为「原文 user → 首轮 assistant → 历史轮 → 本次追问」."
  (let* ((turns '(("问题甲" . "答案甲")))
         (messages (seshat-reader-translate--follow-up-messages
                    "原文" "首轮解释" turns "本次追问" 6)))
    (should (= 5 (length messages)))
    (should (equal (mapcar (lambda (message) (alist-get 'role message)) messages)
                   '(user assistant user assistant user)))
    (let ((first (alist-get 'content (nth 0 messages))))
      (should (string-match-p "请解释下面的文本" first))
      (should (string-suffix-p "原文" first)))
    (should (equal (alist-get 'content (nth 1 messages)) "首轮解释"))
    (should (equal (alist-get 'content (nth 2 messages)) "问题甲"))
    (should (equal (alist-get 'content (nth 3 messages)) "答案甲"))
    (should (equal (alist-get 'content (nth 4 messages)) "本次追问"))
    ;; 元素形态与 `gt-chatgpt-send' 期望的 `((role . x) (content . y))' 一致
    (should (equal (nth 1 messages)
                   '((role . assistant) (content . "首轮解释"))))))

(ert-deftest seshat-reader-translate-test--follow-up-messages-limit ()
  "历史轮超过 LIMIT 时只保留最近 LIMIT 轮（最早的问题不进入 messages）."
  (let* ((turns '(("最早问题" . "最早答案")
                  ("中期问题" . "中期答案")
                  ("最近问题" . "最近答案")))
         (messages (seshat-reader-translate--follow-up-messages
                    "原文" "首轮解释" turns "本次追问" 2))
         (contents (mapcar (lambda (message) (alist-get 'content message)) messages)))
    ;; 1（原文）+ 1（首轮答案）+ 2 轮 × 2 + 1（本次追问）
    (should (= 7 (length messages)))
    (should-not (cl-some (lambda (content) (string-match-p "最早" content)) contents))
    (should (cl-some (lambda (content) (equal content "中期问题")) contents))
    (should (cl-some (lambda (content) (equal content "最近问题")) contents))
    (should (equal (car (last contents)) "本次追问"))))

(ert-deftest seshat-reader-translate-test--follow-up-messages-missing-source ()
  "SOURCE 为 nil 时不产生首轮解释请求，但本次追问仍必须有."
  (let* ((messages (seshat-reader-translate--follow-up-messages
                    nil "首轮解释" nil "本次追问" 6)))
    (should (= 1 (length messages)))
    (should (equal (alist-get 'role (car messages)) 'user))
    (should (equal (alist-get 'content (car messages)) "本次追问")))
  ;; SOURCE 是纯空白时按「没有原文」处理（与空白 ANSWER 同理）
  (let ((messages (seshat-reader-translate--follow-up-messages
                   "  \n\t" "  " nil "只有追问" 6)))
    (should (= 1 (length messages)))
    (should (equal (alist-get 'content (car messages)) "只有追问"))))

(ert-deftest seshat-reader-translate-test--follow-up-requires-state ()
  "面板不存在、没有追问状态、没有原文或问题为空时命令抛 `user-error'."
  (let ((seshat-reader-sidebar-translate-buffer-name
         seshat-reader-translate-test--panel-name))
    (when (get-buffer seshat-reader-translate-test--panel-name)
      (kill-buffer seshat-reader-translate-test--panel-name))
    ;; 情形 1：面板不存在
    (should-error (seshat-reader-translate-follow-up "问题") :type 'user-error)
    (let ((panel (seshat-reader-translate-test--follow-up-panel nil)))
      (unwind-protect
          (progn
            ;; 情形 2：面板存在但还没有追问状态（尚未翻译/解释）
            (should-error (seshat-reader-translate-follow-up "问题") :type 'user-error)
            ;; 情形 3：有状态但没记录原文
            (with-current-buffer panel
              (setq seshat-reader-translate--follow-up-state
                    (list :source nil :answer "首轮解释" :langs '(en zh)
                          :kind 'explain :round 0 :turns nil
                          :answer-marker nil :answer-start nil)))
            (should-error (seshat-reader-translate-follow-up "问题") :type 'user-error)
            ;; 情形 4：问题为空或纯空白
            (should-error (seshat-reader-translate-follow-up " \n ") :type 'user-error))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest seshat-reader-translate-test--follow-up-rejects-non-chatgpt-engine ()
  "预设里没有 `gt-chatgpt-engine' 时抛 `user-error'，不发起请求、不做文本拼接降级."
  (skip-unless (require 'gt nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name
          seshat-reader-translate-test--panel-name)
         (seshat-reader-translate-explain-preset 'reader-explain)
         (gt-preset-translators
          (list (cons 'reader-explain
                      (gt-translator :engines (list (gt-google-engine))))))
         (started nil)
         (panel (seshat-reader-translate-test--follow-up-panel
                 (list :source "原文片段" :answer "首轮解释" :langs '(en zh)
                       :kind 'explain :round 0 :turns nil
                       :answer-marker nil :answer-start nil))))
    (unwind-protect
        (cl-letf (((symbol-function 'gt-start)
                   (lambda (&rest _args) (setq started t))))
          (should-error (seshat-reader-translate-follow-up "问题") :type 'user-error)
          (should-not started)
          ;; 面板内容不受影响（没有追加任何轮次）
          (with-current-buffer panel
            (should-not (string-match-p "### 追问" (buffer-string)))))
      (when (buffer-live-p panel) (kill-buffer panel)))))

(ert-deftest seshat-reader-translate-test--follow-up-appends-round ()
  "追问在面板末尾追加「### 追问 1 / **问：** / **答：**」，记录答案区 marker 并递增轮次."
  (skip-unless (require 'gt nil t))
  (skip-unless (require 'gt-render-buffer nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name
          seshat-reader-translate-test--panel-name)
         (seshat-reader-translate-explain-preset 'reader-explain)
         (preset-engine (gt-chatgpt-engine))
         (gt-preset-translators
          (list (cons 'reader-explain
                      (gt-translator :engines (list preset-engine)))))
         (seshat-reader-translate-stream t)
         (gt-buffer-render-output-hook nil)
         (seshat-reader-translate--current-translator nil)
         (seshat-reader-translate--active nil)
         (captured nil)
         (panel (seshat-reader-translate-test--follow-up-panel
                 (list :source "原文片段" :answer "首轮解释" :langs '(en zh)
                       :kind 'explain :round 0 :turns nil
                       :answer-marker nil :answer-start nil))))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gt-start)
                     (lambda (translator) (setq captured translator))))
            (seshat-reader-translate-follow-up "  测试追问  "))
          (should captured)
          (with-current-buffer panel
            (should (string-match-p "### 追问 1" (buffer-string)))
            (should (string-match-p "\\*\\*问：\\*\\* 测试追问" (buffer-string)))
            ;; 问题被 `string-trim' 处理（前后空白不进面板）
            (should-not (string-match-p "  测试追问" (buffer-string)))
            (should (string-suffix-p "**答：**\n\n" (buffer-string)))
            (let ((state seshat-reader-translate--follow-up-state))
              (should (= 1 (plist-get state :round)))
              (should (eq (plist-get state :answer-start) t))
              (should (markerp (plist-get state :answer-marker)))
              (should (= (marker-position (plist-get state :answer-marker))
                         (point-max))))
            (should (string-match-p "追问 1 生成中" header-line-format)))
          ;; 引擎克隆体带函数型 prompt，调用它得到多轮 messages
          (let* ((engine (car (slot-value captured 'engines)))
                 (prompt (slot-value engine 'prompt)))
            (should (functionp prompt))
            ;; H5：克隆体不是预设里的那个引擎对象
            (should-not (eq engine preset-engine))
            (should-not (eq (slot-value preset-engine 'prompt) prompt))
            (let ((messages (funcall prompt "ignored" 'zh)))
              (should (equal (mapcar (lambda (m) (alist-get 'role m)) messages)
                             '(user assistant user)))
              (should (string-match-p "原文片段"
                                      (alist-get 'content (car messages))))
              (should (equal (alist-get 'content (nth 1 messages)) "首轮解释"))
              (should (equal (alist-get 'content (car (last messages)))
                             "测试追问"))))
          ;; 登记了本次 translator（流式守卫用）
          (should (eq seshat-reader-translate--current-translator captured)))
      (when (buffer-live-p panel) (kill-buffer panel)))))

(ert-deftest seshat-reader-translate-test--follow-up-complete-records-turn ()
  "完成回调替换答案区、追加历史轮、清 `:answer-start'，header-line 报已完成轮数."
  (skip-unless (require 'gt nil t))
  (let* ((seshat-reader-sidebar-translate-buffer-name
          seshat-reader-translate-test--panel-name)
         (seshat-reader-translate-last-result nil)
         (seshat-reader-translate--current-translator 'fake-translator)
         (gt-buffer (get-buffer-create
                     seshat-reader-translate--follow-up-buffer-name))
         (panel (seshat-reader-translate-test--follow-up-panel nil)))
    (unwind-protect
        (progn
          (with-current-buffer panel
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert "\n\n---\n\n### 追问 1\n\n**问：** 测试追问\n\n**答：**\n\n"))
            (setq seshat-reader-translate--follow-up-state
                  (list :source "原文片段" :answer "首轮解释" :langs '(en zh)
                        :kind 'explain :round 1 :turns nil
                        :answer-marker (copy-marker (point-max))
                        :answer-start t)))
          (with-current-buffer gt-buffer
            (erase-buffer)
            (insert (propertize "本轮答案" 'gt-result t)))
          (should (equal (seshat-reader-translate--follow-up-complete panel "测试追问")
                         "本轮答案"))
          (with-current-buffer panel
            (let ((state seshat-reader-translate--follow-up-state))
              (should (equal (plist-get state :turns)
                             '(("测试追问" . "本轮答案"))))
              (should-not (plist-get state :answer-start))
              (should-not (plist-get state :answer-marker))
              (should (= 1 (plist-get state :round))))
            (should (string-suffix-p "**答：**\n\n本轮答案\n" (buffer-string)))
            (goto-char (point-min))
            (should (= 1 (how-many "### 追问")))
            (should (string-match-p "已完成 · 1 轮追问" header-line-format)))
          ;; 存批注口径：记录整面板纯文本（含首轮解释与本轮答案）
          (should seshat-reader-translate-last-result)
          (should (string-match-p "首轮解释" seshat-reader-translate-last-result))
          (should (string-match-p "本轮答案" seshat-reader-translate-last-result))
          ;; 收尾后清掉 translator 登记，防止迟到增量误写首轮正文区
          (should-not seshat-reader-translate--current-translator))
      (when (buffer-live-p panel) (kill-buffer panel))
      (when (buffer-live-p gt-buffer) (kill-buffer gt-buffer)))))

(ert-deftest seshat-reader-translate-test--follow-up-key-binding ()
  "`C-c C-q' 在阅读器键位表与面板键位表上都绑到追问命令."
  (should (eq (lookup-key seshat-reader-mode-map (kbd "C-c C-q"))
              #'seshat-reader-translate-follow-up))
  (should (eq (lookup-key seshat-reader-translate-panel-map (kbd "C-c C-q"))
              #'seshat-reader-translate-follow-up))
  ;; `C-c C-a' 已被批注命令占用，追问不得复用它
  (should-not (eq (lookup-key seshat-reader-mode-map (kbd "C-c C-a"))
                  #'seshat-reader-translate-follow-up)))

;;; 预设表：seshat 自有表优先 + thunk 回落顺序

(ert-deftest seshat-reader-translate-test--presets-seshat-table-wins ()
  "两表同名时取 seshat 自有表里的预设，而不是全局表那个."
  (let* ((seshat-trans (gt-translator :engines (list (gt-google-engine))))
         (global-trans (gt-translator :engines (list (gt-youdao-dict-engine))))
         (seshat-reader-translate-presets (list (cons 'x seshat-trans)))
         (gt-preset-translators (list (cons 'x global-trans)))
         (seshat-reader-translate-render 'pop)
         (seshat-reader-translate-stream nil)
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil)
         (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let ((trans (seshat-reader-translate--translator 'x "hello" '(en zh))))
        (should-not messages)
        ;; 仍按「克隆预设」的既有语义：不改写预设本体
        (should-not (eq trans seshat-trans))
        (should-not (eq trans global-trans))
        ;; 引擎来自 seshat 表那个预设（浅克隆共享引擎对象）
        (should (eq (car (slot-value trans 'engines))
                    (car (slot-value seshat-trans 'engines))))
        (should (eq (eieio-object-class (car (slot-value trans 'engines)))
                    'gt-google-engine))))))

(ert-deftest seshat-reader-translate-test--presets-falls-back-to-global ()
  "seshat 自有表未命中时回落到 gt 的全局表 `gt-preset-translators'."
  (let* ((global-trans (gt-translator :engines (list (gt-youdao-dict-engine))))
         (seshat-reader-translate-presets nil)
         (gt-preset-translators (list (cons 'x global-trans)))
         (seshat-reader-translate-render 'pop)
         (seshat-reader-translate-stream nil)
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil)
         (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let ((trans (seshat-reader-translate--translator 'x "hello" '(en zh))))
        (should-not messages)
        (should-not (eq trans global-trans))
        (should (eq (car (slot-value trans 'engines))
                    (car (slot-value global-trans 'engines))))
        (should (eq (eieio-object-class (car (slot-value trans 'engines)))
                    'gt-youdao-dict-engine))))))

(ert-deftest seshat-reader-translate-test--presets-thunk-called ()
  "自有表的值是 thunk 时被调用一次，用其返回的 translator."
  (let* ((called 0)
         (built (gt-translator :engines (list (gt-google-engine))))
         (seshat-reader-translate-presets
          (list (cons 'x (lambda () (setq called (1+ called)) built))))
         (gt-preset-translators nil)
         (seshat-reader-translate-render 'pop)
         (seshat-reader-translate-stream nil)
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (let ((trans (seshat-reader-translate--translator 'x "hello" '(en zh))))
        (should (= called 1))
        (should-not (eq trans built))
        (should (eq (car (slot-value trans 'engines))
                    (car (slot-value built 'engines))))
        (should (eq (eieio-object-class (car (slot-value trans 'engines)))
                    'gt-google-engine))))))

(ert-deftest seshat-reader-translate-test--presets-thunk-nil-falls-back ()
  "thunk 返回 nil 时不崩溃，回退到内置 youdao/google 翻译器."
  (let ((seshat-reader-translate-presets (list (cons 'x (lambda () nil))))
        (gt-preset-translators nil)
        (seshat-reader-translate-render 'pop)
        (seshat-reader-translate-stream nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let* ((trans (seshat-reader-translate--translator 'x "hello" '(en zh)))
             (engines (slot-value trans 'engines)))
        (should (= (length engines) 2))
        (should (eq (eieio-object-class (car engines)) 'gt-youdao-dict-engine))
        (should (eq (eieio-object-class (cadr engines)) 'gt-google-engine))))
    ;; 与「预设缺失」同一条提示，且只提示一次
    (should (= (length messages) 1))))

(ert-deftest seshat-reader-translate-test--presets-both-empty-falls-back ()
  "两表都查不到时查表函数返回 nil，`--translator' 回退内置且不崩溃."
  (let ((seshat-reader-translate-presets nil)
        (gt-preset-translators nil)
        (seshat-reader-translate-render 'pop)
        (seshat-reader-translate-stream nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (messages nil))
    (should-not (seshat-reader-translate--preset-translator 'x))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let* ((trans (seshat-reader-translate--translator 'x "hello" '(en zh)))
             (engines (slot-value trans 'engines)))
        (should (= (length engines) 2))
        (should (eq (eieio-object-class (car engines)) 'gt-youdao-dict-engine))
        (should (equal (slot-value (slot-value trans 'taker) 'text) "hello"))))
    (should (= (length messages) 1))))

(ert-deftest seshat-reader-translate-test--preset-translator-thunk-not-cached ()
  "查表函数每次调用都执行 thunk（不缓存），thunk 返回 nil 时不回落全局表."
  (let* ((calls 0)
         (seshat-reader-translate-presets
          (list (cons 'x (lambda () (setq calls (1+ calls)) 'built))))
         (gt-preset-translators nil))
    (should (eq (seshat-reader-translate--preset-translator 'x) 'built))
    (should (= calls 1))
    (should (eq (seshat-reader-translate--preset-translator 'x) 'built))
    (should (= calls 2)))
  ;; 两表都未命中 → nil
  (let ((seshat-reader-translate-presets nil)
        (gt-preset-translators nil))
    (should-not (seshat-reader-translate--preset-translator 'missing)))
  ;; 自有表的 thunk 返回 nil 时返回 nil（此时不再看全局表，与 docstring 一致）
  (let ((seshat-reader-translate-presets (list (cons 'y (lambda () nil))))
        (gt-preset-translators (list (cons 'y 'global))))
    (should-not (seshat-reader-translate--preset-translator 'y))))

;;; 追问路径取引擎也走统一查表（seshat 表优先 → 全局表回落）

(ert-deftest seshat-reader-translate-test--preset-chatgpt-engine-from-seshat-table ()
  "`--preset-chatgpt-engine' 从 seshat 自有表取到 ChatGPT 引擎."
  (skip-unless (require 'gt nil t))
  (let* ((engine (gt-chatgpt-engine))
         (seshat-reader-translate-presets
          (list (cons 'x (gt-translator :engines (list engine)))))
         (gt-preset-translators nil))
    (let ((found (seshat-reader-translate--preset-chatgpt-engine 'x)))
      (should found)
      (should (eq found engine))
      (should (object-of-class-p found 'gt-chatgpt-engine)))))

(ert-deftest seshat-reader-translate-test--preset-chatgpt-engine-falls-back-to-global ()
  "seshat 自有表未命中时回落全局表 `gt-preset-translators' 取到 ChatGPT 引擎."
  (skip-unless (require 'gt nil t))
  (let* ((engine (gt-chatgpt-engine))
         (seshat-reader-translate-presets nil)
         (gt-preset-translators
          (list (cons 'x (gt-translator :engines (list engine))))))
    (let ((found (seshat-reader-translate--preset-chatgpt-engine 'x)))
      (should found)
      (should (eq found engine))
      (should (object-of-class-p found 'gt-chatgpt-engine)))))

(ert-deftest seshat-reader-translate-test--preset-chatgpt-engine-returns-nil ()
  "预设缺失、或预设里只有纯翻译引擎时 `--preset-chatgpt-engine' 返回 nil."
  (skip-unless (require 'gt nil t))
  ;; 两表都查不到该预设
  (let ((seshat-reader-translate-presets nil)
        (gt-preset-translators nil))
    (should-not (seshat-reader-translate--preset-chatgpt-engine 'x)))
  ;; 预设存在，但引擎只有 youdao/google（无语义对话能力，不做拼接降级）
  (let ((seshat-reader-translate-presets
         (list (cons 'x (gt-translator :engines (list (gt-google-engine))))))
        (gt-preset-translators nil))
    (should-not (seshat-reader-translate--preset-chatgpt-engine 'x))))

;;; 解释上下文：纯函数（行矩形扩行 / 窗口截断）与 IO 包装

(ert-deftest seshat-reader-translate-test--expand-rect-nil ()
  "`--expand-rect' 对 nil、非列表、残缺矩形一律返回 nil."
  (should-not (seshat-reader-translate--expand-rect nil 2))
  (should-not (seshat-reader-translate--expand-rect "rect" 2))
  (should-not (seshat-reader-translate--expand-rect '(1.0 2.0 3.0) 2))
  (should-not (seshat-reader-translate--expand-rect '((1.0 2.0 3.0)) 2))
  (should-not (seshat-reader-translate--expand-rect '(("a" 2.0 3.0 4.0)) 2)))

(ert-deftest seshat-reader-translate-test--expand-rect-single-line ()
  "单矩形扩 LINES 行：行高取 (Y1 - Y0)，上下各外扩 LINES 倍."
  ;; 单行 y0=100 y1=110 → 行高 10；扩 2 行 → y0'=80 y1'=130
  (should (equal (seshat-reader-translate--expand-rect
                  '((0.0 100.0 10.0 110.0)) 2)
                 '(0.0 80.0 10.0 130.0)))
  ;; LINES 为 0 时不外扩（横向仍取并集）
  (should (equal (seshat-reader-translate--expand-rect
                  '((0.0 100.0 10.0 110.0)) 0)
                 '(0.0 100.0 10.0 110.0))))

(ert-deftest seshat-reader-translate-test--expand-rect-multi-line ()
  "多矩形：横向取并集，纵向按行高均值（(最大 Y1 − 最小 Y0) / 行数）外扩."
  ;; y0=100/112、y1=110/122 → 行高 (122-100)/2 = 11；扩 1 行 → y0'=89 y1'=133
  (should (equal (seshat-reader-translate--expand-rect
                  '((0.0 100.0 10.0 110.0)
                    (2.0 112.0 20.0 122.0))
                  1)
                 '(0.0 89.0 20.0 133.0))))

(ert-deftest seshat-reader-translate-test--expand-rect-zero-line-height ()
  "估算行高为 0（矩形零高度）时返回 nil，避免无意义外扩."
  (should-not (seshat-reader-translate--expand-rect
               '((0.0 100.0 10.0 100.0)) 2))
  (should-not (seshat-reader-translate--expand-rect
               '((0.0 100.0 10.0 100.0)
                 (2.0 100.0 20.0 100.0))
               1)))

(ert-deftest seshat-reader-translate-test--context-window-locates-selection ()
  "能定位选区时窗口包含选区且总长不超过 MAX-CHARS."
  (let* ((selection "TARGET")
         (page-text (concat (make-string 40 ?a) selection (make-string 40 ?b)))
         (window (seshat-reader-translate--context-window page-text selection 20)))
    (should (stringp window))
    (should (<= (length window) 20))
    (should (string-match-p (regexp-quote selection) window))))

(ert-deftest seshat-reader-translate-test--context-window-falls-back-to-prefix ()
  "定位不到选区（或无选区）时取 PAGE-TEXT 前 MAX-CHARS 个字符."
  (let ((page-text (concat (make-string 100 ?a) "x")))
    (should (string= (seshat-reader-translate--context-window page-text "zzz" 20)
                     (substring page-text 0 20)))
    ;; SELECTION 为 nil 同样走前缀
    (should (string= (seshat-reader-translate--context-window page-text nil 20)
                     (substring page-text 0 20)))
    ;; MAX-CHARS 超过长度时取全串
    (should (string= (seshat-reader-translate--context-window "short" "zzz" 200)
                     "short"))))

(ert-deftest seshat-reader-translate-test--context-window-invalid-input ()
  "PAGE-TEXT 非字符串/空串、MAX-CHARS 非正数时返回 nil."
  (should-not (seshat-reader-translate--context-window nil "abc" 20))
  (should-not (seshat-reader-translate--context-window "" "abc" 20))
  (should-not (seshat-reader-translate--context-window "abc" "abc" 0))
  (should-not (seshat-reader-translate--context-window "abc" "abc" -5)))

(ert-deftest seshat-reader-translate-test--context-window-normalizes-whitespace ()
  "窗口内连续空格/制表符折叠为单空格，三段以上换行折叠为两段，并去首尾空白."
  (let ((page-text "Alpha    beta\tgamma\n\n\n\nDelta   epsilon"))
    (should (string= (seshat-reader-translate--context-window page-text nil 200)
                     "Alpha beta gamma\n\nDelta epsilon")))
  ;; 清洗后为空（纯空白）时返回 nil
  (should-not (seshat-reader-translate--context-window "  \t \n \n " "zzz" 100)))

(ert-deftest seshat-reader-translate-test--context-text-disabled-touches-nothing ()
  "`context-enabled' 为 nil 时立即返回 nil，三个模块函数零调用."
  (let ((seshat-reader-translate-context-enabled nil)
        (seshat-reader-select-last (list :page 1
                                        :rect '(0.0 0.0 10.0 10.0)
                                        :text "abc"))
        (calls 0))
    (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (&rest _) (setq calls (1+ calls)) '((0.0 0.0 10.0 10.0))))
              ((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (&rest _) (setq calls (1+ calls)) "rect text"))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (&rest _) (setq calls (1+ calls)) "page text")))
      (should-not (seshat-reader-translate--context-text))
      (should (= calls 0)))))

(ert-deftest seshat-reader-translate-test--context-text-swallows-errors ()
  "模块函数全部抛错时静默返回 nil（`condition-case' 兜住，不外抛）."
  (let ((seshat-reader-translate-context-enabled t)
        (seshat-reader-select-last (list :page 1
                                        :rect '(0.0 0.0 10.0 10.0)
                                        :text "abc")))
    (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (&rest _) (error "boom")))
              ((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (&rest _) (error "boom")))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (&rest _) (error "boom"))))
      (should-not (seshat-reader-translate--context-text)))))

(ert-deftest seshat-reader-translate-test--context-text-page-is-zero-based ()
  "选区 `:page'（1-based）为 1 时，三个模块函数收到的 PAGE 参数必须是 0."
  (let ((seshat-reader-translate-context-enabled t)
        (seshat-reader-translate-context-lines 1)
        (seshat-reader-translate-context-max-chars 100)
        (seshat-reader-select-last (list :page 1
                                        :rect '(0.0 100.0 10.0 110.0)
                                        :text "abc"))
        (seen nil))
    (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (page &rest _)
                 (push (cons 'lines page) seen)
                 '((0.0 100.0 10.0 110.0))))
              ((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (page &rest _)
                 (push (cons 'rect page) seen)
                 ;; 空串 → 矩形路径无结果，继续降级到整页
                 ""))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (page &rest _)
                 (push (cons 'page page) seen)
                 "Leading text before abc and trailing text after.")))
      (should (string= (seshat-reader-translate--context-text)
                       "Leading text before abc and trailing text after.")))
    ;; lines ×1 + text-in-rect ×2（上方块 / 下方块）+ page-text ×1
    (should (= (length seen) 4))
    ;; `push' 倒序：page → text-in-rect(下) → text-in-rect(上) → lines
    (should (equal (mapcar #'car seen) '(page rect rect lines)))
    (dolist (item seen)
      (should (= (cdr item) 0)))))

(ert-deftest seshat-reader-translate-test--context-text-above-and-below-blocks ()
  "上下文按「上方块 + 下方块」两次调用 `--text-in-rect'，Y 范围不含选区。
第一次是 [外扩顶, 选区顶]，第二次是 [选区底, 外扩底]，X 范围取外扩矩形的。"
  (let ((seshat-reader-translate-context-enabled t)
        (seshat-reader-translate-context-lines 2)
        (seshat-reader-translate-context-max-chars 1200)
        ;; 选区跨两行：Y 从 100 到 120
        (seshat-reader-select-last (list :page 1
                                        :rect '(0.0 100.0 10.0 120.0)
                                        :text "AlphaBeta"))
        (calls nil))
    (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (&rest _)
                 '((0.0 100.0 10.0 110.0) (0.0 110.0 10.0 120.0))))
              ;; 行高 10，外扩 2 行 → 大矩形 Y 从 80 到 140
              ((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (page x0 y0 x1 y1)
                 (push (list page x0 y0 x1 y1) calls)
                 (if (= (length calls) 1) "ABOVE TEXT" "BELOW TEXT")))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (&rest _) (error "不该降级到整页"))))
      (should (string= (seshat-reader-translate--context-text)
                       "ABOVE TEXT\n\nBELOW TEXT")))
    (should (= (length calls) 2))
    ;; calls 是倒序（push）：第一条是下块，第二条是上块
    (should (equal (nth 1 calls) '(0 0.0 80.0 10.0 100.0)))
    (should (equal (nth 0 calls) '(0 0.0 120.0 10.0 140.0)))))

(ert-deftest seshat-reader-translate-test--context-text-above-only-no-blank-line ()
  "下方块为空（nil）时上下文只含上方块，`string-join' 不产生多余空行。"
  (let ((seshat-reader-translate-context-enabled t)
        (seshat-reader-translate-context-lines 1)
        (seshat-reader-translate-context-max-chars 1200)
        (seshat-reader-select-last (list :page 1
                                        :rect '(0.0 100.0 10.0 110.0)
                                        :text "abc"))
        (calls nil))
    (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (&rest _) '((0.0 100.0 10.0 110.0))))
              ((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (page x0 y0 x1 y1)
                 (push (list page x0 y0 x1 y1) calls)
                 ;; 上块 [90, 100] 有值，下块 [110, 120] 无值
                 (unless (= y0 110.0) "ONLY ABOVE")))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (&rest _) (error "不该降级到整页"))))
      (let ((ctx (seshat-reader-translate--context-text)))
        (should (string= ctx "ONLY ABOVE"))
        (should-not (string-match-p "\n" ctx))))
    (should (= (length calls) 2))
    (should (equal (nth 1 calls) '(0 0.0 90.0 10.0 100.0)))
    (should (equal (nth 0 calls) '(0 0.0 110.0 10.0 120.0)))))

(ert-deftest seshat-reader-translate-test--context-text-excludes-selection ()
  "上下文天然不含选区原文：模块在段落内不插换行，跨行选区已不落在上下块中。
（旧实现「取大矩形再精确删除选区字符串」在此场景命中率恒为 0。）"
  (let ((seshat-reader-translate-context-enabled t)
        (seshat-reader-translate-context-lines 1)
        (seshat-reader-translate-context-max-chars 1200)
        ;; 选区在第 1 行末尾 "Alpha" 换到第 2 行开头 "Beta"
        (seshat-reader-select-last (list :page 1
                                        :rect '(0.0 100.0 10.0 120.0)
                                        :text "AlphaBeta"))
        (calls 0))
    (cl-letf (((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (&rest _)
                 '((0.0 100.0 10.0 110.0) (0.0 110.0 10.0 120.0))))
              ((symbol-function 'seshat-reader-dyn--text-in-rect)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 (if (= calls 1)
                     "Header line one Header line two"
                   "Tail line one Tail line two")))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (&rest _) (error "不该降级到整页"))))
      (let ((ctx (seshat-reader-translate--context-text)))
        (should (stringp ctx))
        (should-not (string-match-p (regexp-quote "AlphaBeta") ctx))
        ;; 上块与下块都在，顺序为「先上后下」
        (should (string-match-p "Header" ctx))
        (should (string-match-p "Tail" ctx))
        (should (< (string-match-p "Header" ctx) (string-match-p "Tail" ctx)))
        (should (string= ctx
                         (concat "Header line one Header line two"
                                 "\n\n"
                                 "Tail line one Tail line two")))))))

;;; 解释 prompt 装配（模板 → request-text）与 explain 接线

(defun seshat-reader-translate-test--occurrences (needle haystack)
  "返回 NEEDLE 在 HAYSTACK 中按字面匹配出现的次数."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest seshat-reader-translate-test--document-title-basename-only ()
  "`--document-title' 只取 basename 去扩展名；未记录 `:file' 时返回 nil."
  (let ((seshat-reader-select-last
         (list :text "x" :file "/home/u/books/d2l-zh-pytorch.pdf")))
    (should (equal (seshat-reader-translate--document-title) "d2l-zh-pytorch"))
    ;; 不得输出完整路径
    (should-not (string-match-p "/" (seshat-reader-translate--document-title))))
  (let ((seshat-reader-select-last (list :text "x")))
    (should-not (seshat-reader-translate--document-title)))
  (let ((seshat-reader-select-last nil))
    (should-not (seshat-reader-translate--document-title))))

(ert-deftest seshat-reader-translate-test--explain-request-text-nil-template ()
  "模板为 nil 时 `--explain-request-text' 原样返回纯选区（不装配）."
  (let ((seshat-reader-translate-explain-prompt nil))
    (should (equal (seshat-reader-translate--explain-request-text
                    "PLAIN TEXT" "CTX TEXT" "docname" '(en zh))
                   "PLAIN TEXT"))
    ;; 上下文、文档名、指令行都不该出现在结果里
    (let ((request (seshat-reader-translate--explain-request-text
                    "PLAIN TEXT" "CTX TEXT" "docname" '(en zh))))
      (should-not (string-match-p "CTX TEXT" request))
      (should-not (string-match-p "docname" request))
      (should-not (string-match-p "## 任务" request)))))

(ert-deftest seshat-reader-translate-test--explain-request-text-fills-placeholders ()
  "模板含四个占位符时逐字替换：选区、上下文、文档名、语言对各出现一次."
  (let* ((seshat-reader-translate-explain-prompt
          "## 任务\n\n解释 {{doc}}（{{lang}}）。\n\n## 上下文\n\n{{context}}\n\n## 原文\n\n{{text}}\n")
         (assembled (seshat-reader-translate--explain-request-text
                     "SELECTED ORIGINAL" "CTX-A CTX-B" "docname" '(en zh))))
    (should (stringp assembled))
    (should (= 1 (seshat-reader-translate-test--occurrences
                  "SELECTED ORIGINAL" assembled)))
    (should (= 1 (seshat-reader-translate-test--occurrences "CTX-A CTX-B" assembled)))
    (should (= 1 (seshat-reader-translate-test--occurrences "docname" assembled)))
    (should (= 1 (seshat-reader-translate-test--occurrences "en → zh" assembled)))
    ;; 占位符全部解析：结果里不含未替换的双花括号
    (should-not (string-match-p "{{" assembled))
    (should (= 0 (seshat-reader-translate-test--occurrences "{{text}}" assembled)))))

(ert-deftest seshat-reader-translate-test--explain-request-text-default-structure ()
  "默认模板装配后每个 `## ' 标题行都紧跟空行（软换行归一化分段的前提）."
  ;; 不绑定 `seshat-reader-translate-explain-prompt'：批处理 `emacs --batch -Q'
  ;; 下它就是 defcustom 默认值，本用例正是要钉住这个默认值的结构。
  (let* ((text "SELECTED ORIGINAL")
         (context "CTX BEFORE\n\nCTX AFTER")
         (assembled (seshat-reader-translate--explain-request-text
                     text context "docname" '(en zh)))
         (start 0)
         (headings 0))
    (should (string-match-p "^## 任务$" assembled))
    (should (string-match-p "## 任务\n\n" assembled))
    (should (string-match-p "## 需要解释的原文\n\n" assembled))
    (should (string-match-p (regexp-quote context) assembled))
    (should (= 1 (seshat-reader-translate-test--occurrences text assembled)))
    (should-not (string-match-p "{{" assembled))
    ;; 逐个标题断言「行自身独立成行且紧跟空行」
    (while (string-match "^## [^\n]*\n" assembled start)
      (setq headings (1+ headings))
      (should (= ?\n (aref assembled (match-end 0))))
      (setq start (match-end 0)))
    (should (>= headings 3))))

(ert-deftest seshat-reader-translate-test--explain-request-text-unknown-placeholder ()
  "模板含未知占位符时 `message' 警告并回退纯选区."
  (let ((seshat-reader-translate-explain-prompt
         "## 任务\n\n{{bogus}}\n\n{{text}}\n")
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (should (equal (seshat-reader-translate--explain-request-text
                      "SELECTED" "CTX" "docname" '(en zh))
                     "SELECTED")))
    (should (= 1 (length messages)))
    (should (string-match-p "未知占位符" (car messages)))))

(ert-deftest seshat-reader-translate-test--explain-request-text-escapes-input-braces ()
  "输入值里的 `{{' 被转义：原样保留在结果中，且不触发未知占位符警告."
  (let ((seshat-reader-translate-explain-prompt
         "## 任务\n\n解释 {{doc}}。\n\n## 原文\n\n{{text}}\n")
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (let ((assembled (seshat-reader-translate--explain-request-text
                        "{{foo}} bar" "CTX" "docname" '(en zh))))
        (should (stringp assembled))
        ;; 输入值原样保留：`{{foo}} bar' 一字不差地出现在结果里
        (should (= 1 (seshat-reader-translate-test--occurrences
                      "{{foo}} bar" assembled)))
        ;; 不得残留转义哨兵（NUL）
        (should-not (string-match-p "\0" assembled))
        ;; 模板占位符依然被正确替换
        (should (= 1 (seshat-reader-translate-test--occurrences "docname" assembled)))
        (should (string-match-p "## 原文\n\n{{foo}} bar" assembled))))
    ;; 输入值里的 `{{' 不应被误判为未知占位符：`message' 一次都没调
    (should (= 0 (length messages)))))

(ert-deftest seshat-reader-translate-test--explain-request-text-unknown-placeholder-beside-known ()
  "已知占位符与未知占位符并存时：警告一次并回退纯选区（不装配半成品）."
  (let ((seshat-reader-translate-explain-prompt "{{text}} {{bogus}}")
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (should (equal (seshat-reader-translate--explain-request-text
                      "SELECTED" "CTX" "docname" '(en zh))
                     "SELECTED")))
    (should (= 1 (length messages)))
    (should (string-match-p "未知占位符" (car messages)))))

(ert-deftest seshat-reader-translate-test--translator-request-text-fills-taker ()
  "`--translator' 第 5 参（REQUEST-TEXT）填入 taker 的 `:text'，其余参数不变."
  (let ((seshat-reader-translate-presets nil)
        (gt-preset-translators nil)
        (seshat-reader-translate-render 'pop)
        (seshat-reader-translate-stream nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (let ((trans (seshat-reader-translate--translator
                    'x "AAA" '(en zh) 'explain "REQ")))
        (should (equal (oref (oref trans taker) text) "REQ"))
        (should (null (oref (oref trans taker) pick)))
        (should (equal (oref (oref trans taker) langs) '(en zh)))))))

(ert-deftest seshat-reader-translate-test--translator-without-request-text ()
  "不传第 5 参时 taker 的 `:text' 仍是纯选区文本（回归）."
  (let ((seshat-reader-translate-presets nil)
        (gt-preset-translators nil)
        (seshat-reader-translate-render 'pop)
        (seshat-reader-translate-stream nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (dolist (kind '(nil translate explain))
        (let ((trans (seshat-reader-translate--translator
                      'x "AAA" '(en zh) kind)))
          (should (equal (oref (oref trans taker) text) "AAA")))))))

(ert-deftest seshat-reader-translate-test--quote-block-uses-pure-selection ()
  "面板原文引用块仍取纯选区，不含 prompt 指令行."
  (let ((seshat-reader-select-last
         (list :text "Hello world" :page 3
               :rect '(10.0 20.0 30.0 40.0)
               :file "/tmp/d2l-zh-pytorch.pdf"))
        (seshat-reader-translate-show-source t))
    (let ((block (seshat-reader-translate--quote-block)))
      (should (stringp block))
      (should (string-match-p "> \\*\\*原文\\*\\*" block))
      (should (string-match-p "Hello world" block))
      (should-not (string-match-p "## 任务" block))
      (should-not (string-match-p "需要解释的原文" block))
      (should-not (string-match-p "{{" block)))))

(ert-deftest seshat-reader-translate-test--explain-selection-sends-assembled-text ()
  "`seshat-reader-translate-explain-selection' 把装配串送进 taker，纯选区保持原样."
  (let ((seshat-reader-select-last
         (list :text "Hello world" :page 1
               :rect '(0.0 0.0 10.0 10.0)
               :file "/tmp/d2l.pdf"))
        (seshat-reader-translate-context-enabled t)
        (seshat-reader-translate-explain-prompt
         "## 任务\n\n解释。\n\n{{context}}\n\n{{text}}\n")
        (seshat-reader-translate-explain-preset 'reader-explain)
        (seshat-reader-translate-fallback-langs '(en zh))
        (seshat-reader-translate-render 'pop)
        (seshat-reader-translate-stream nil)
        (seshat-reader-translate-last-result "旧结果")
        (gt-preset-translators nil)
        (gt-posframe-pop-render-output-hook nil)
        (gt-posframe-pin-render-output-hook nil)
        (captured nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (translator) (setq captured translator)))
              ((symbol-function 'message) (lambda (&rest _) nil))
              ((symbol-function 'seshat-reader-dyn--lines-in-rect)
               (lambda (&rest _) (error "no module")))
              ((symbol-function 'seshat-reader-dyn--page-text)
               (lambda (&rest _) "page before Hello world page after")))
      (seshat-reader-translate-explain-selection))
    (should captured)
    (let ((sent (oref (oref captured taker) text)))
      (should (string-match-p "^## 任务$" sent))
      (should (string-match-p "page before" sent))
      (should (string-match-p "Hello world" sent)))
    ;; 既有语义不变：启动前清 `last-result'，纯选区仍在选区变量里
    (should-not seshat-reader-translate-last-result)
    (should (equal (plist-get seshat-reader-select-last :text) "Hello world"))))

;;; 长度护栏（`seshat-reader-translate-explain-max-chars'）

(ert-deftest seshat-reader-translate-test--truncate-selection-over-limit ()
  "超长选区被截断到上限，并在尾部追加「（选区过长，以上为节选）」."
  (let* ((seshat-reader-translate-explain-max-chars 10)
         (text (make-string 50 ?x))
         (result (seshat-reader-translate--truncate-selection text)))
    (should (stringp result))
    (should (string-suffix-p "（选区过长，以上为节选）" result))
    ;; 前半段原样保留前 MAX 个字符，长度 = MAX + 标注串长度
    (should (equal (substring result 0 10) (make-string 10 ?x)))
    (should (= (length result)
               (+ 10 (length "\n\n（选区过长，以上为节选）"))))
    ;; 超限部分被真的丢掉（50 个 x 只剩 10 个）
    (should (= 10 (seshat-reader-translate-test--occurrences "x" result)))))

(ert-deftest seshat-reader-translate-test--truncate-selection-within-limit ()
  "未超限、上限非正整数或文本非字符串时原样返回（同一个对象）."
  (let ((seshat-reader-translate-explain-max-chars 2000)
        (text "short selection"))
    (should (eq (seshat-reader-translate--truncate-selection text) text))
    ;; 恰好等于上限也不截断
    (let ((exact (make-string 2000 ?y)))
      (should (eq (seshat-reader-translate--truncate-selection exact) exact))))
  ;; 上限非正整数 → 关闭截断
  (dolist (max '(0 -1))
    (let ((seshat-reader-translate-explain-max-chars max))
      (should (equal (seshat-reader-translate--truncate-selection
                      "abcdefghijklmn")
                     "abcdefghijklmn"))))
  ;; 非字符串 → 原样（含 nil）
  (let ((seshat-reader-translate-explain-max-chars 1))
    (should-not (seshat-reader-translate--truncate-selection nil))
    (should (= 42 (seshat-reader-translate--truncate-selection 42)))))

;;; 输出净化（`seshat-reader-translate-strip-chatter'）

(ert-deftest seshat-reader-translate-test--strip-chatter-removes-chatter-line ()
  "首行为「好的，以下是…：」时删掉该行与其后的空行，返回正文."
  (should (equal (seshat-reader-translate--strip-chatter
                  "好的，以下是这段的解释：\n\n正文")
                 "正文"))
  ;; 半角冒号同样识别
  (should (equal (seshat-reader-translate--strip-chatter
                  "以下是原文要点:\n\n- 第一条")
                 "- 第一条"))
  ;; 多个前导空行一并吃掉
  (should (equal (seshat-reader-translate--strip-chatter
                  "下面给出要点：\n\n\n\n正文一\n正文二")
                 "正文一\n正文二"))
  ;; 只剩寒暄行时原样返回（不把回答抹成空）
  (should (equal (seshat-reader-translate--strip-chatter "好的，以下是：")
                 "好的，以下是："))
  ;; nil / 非字符串原样
  (should-not (seshat-reader-translate--strip-chatter nil))
  (should (= 7 (seshat-reader-translate--strip-chatter 7))))

(ert-deftest seshat-reader-translate-test--strip-chatter-keeps-body-line ()
  "非寒暄首行原样返回（同一个对象），不做任何其它清洗."
  (let ((text "这是一段正文。\n第二行"))
    (should (eq (seshat-reader-translate--strip-chatter text) text)))
  ;; 冒号不在行尾 → 不是寒暄行，正文不得被删
  (let ((text "这段代码做了什么：说明在下一段\n第二行"))
    (should (eq (seshat-reader-translate--strip-chatter text) text))))

(ert-deftest seshat-reader-translate-test--record-result-skips-strip-when-disabled ()
  "`strip-chatter' 为 nil 时 `--record-result' 不净化；为 t 时写入净化后文本."
  (let* ((chatter "好的，以下是：\n\n正文")
         (seshat-reader-translate--active (float-time))
         (seshat-reader-translate-last-result nil))
    (cl-letf (((symbol-function 'seshat-reader-translate--extract-result)
               (lambda (&rest _) (cons chatter nil))))
      ;; 开关 nil：寒暄保留，返回值与 `last-result' 都是原文
      (let ((seshat-reader-translate-strip-chatter nil))
        (should (equal (seshat-reader-translate--capture-result) chatter))
        (should (equal seshat-reader-translate-last-result chatter)))
      ;; 开关 t（默认）：寒暄被去掉
      (setq seshat-reader-translate-last-result nil)
      (let ((seshat-reader-translate-strip-chatter t))
        (should (equal (seshat-reader-translate--capture-result) "正文"))
        (should (equal seshat-reader-translate-last-result "正文"))))))

;;; 可观测（`seshat-reader-translate--engine-label'）

(ert-deftest seshat-reader-translate-test--engine-label-shows-model-and-host ()
  "引擎标识含 model 与 host，且**绝不**含 key 槽里的哨兵字符串."
  (skip-unless (require 'gt nil t))
  (let* ((sentinel "SENTINEL-KEY-DO-NOT-LEAK")
         (engine (gt-chatgpt-engine :host "api.deepseek.com"
                                    :model "deepseek-chat"
                                    :key sentinel))
         (translator (gt-translator :engines (list engine)))
         (label (seshat-reader-translate--engine-label translator)))
    (should (stringp label))
    (should (string-match-p "deepseek-chat" label))
    (should (string-match-p "api\\.deepseek\\.com" label))
    ;; 形如「（model @ host）」
    (should (string-match-p "（deepseek-chat @ api\\.deepseek\\.com）" label))
    (should-not (string-match-p sentinel label))
    ;; translator 为 nil / 无引擎 / 非对象 → 空串
    (should (equal (seshat-reader-translate--engine-label nil) ""))
    (should (equal (seshat-reader-translate--engine-label
                    (gt-translator :engines nil))
                   ""))
    (should (equal (seshat-reader-translate--engine-label "not-a-translator") ""))))

(ert-deftest seshat-reader-translate-test--explain-error-message-shows-engine-no-key ()
  "解释失败的 `message' 含引擎 model/host，且不含 key 哨兵."
  (skip-unless (require 'gt nil t))
  (let* ((sentinel "SENTINEL-KEY-DO-NOT-LEAK")
         (seshat-reader-translate-presets
          (list (cons 'reader-explain
                      (gt-translator
                       :engines (list (gt-chatgpt-engine
                                       :host "api.deepseek.com"
                                       :model "deepseek-chat"
                                       :key sentinel))))))
         (seshat-reader-translate-explain-preset 'reader-explain)
         (seshat-reader-translate-explain-prompt nil)
         (seshat-reader-translate-stream nil)
         (seshat-reader-translate-render 'pop)
         (seshat-reader-translate-fallback-langs '(en zh))
         (seshat-reader-select-last (list :text "Hello world"))
         (seshat-reader-translate-last-result nil)
         (gt-posframe-pop-render-output-hook nil)
         (gt-posframe-pin-render-output-hook nil)
         (messages nil))
    (cl-letf (((symbol-function 'gt-start)
               (lambda (&rest _) (error "boom-500")))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (seshat-reader-translate-explain-selection))
    (should (= 1 (length messages)))
    (let ((msg (car messages)))
      (should (string-match-p "解释失败" msg))
      (should (string-match-p "deepseek-chat" msg))
      (should (string-match-p "api\\.deepseek\\.com" msg))
      (should-not (string-match-p sentinel msg)))))

;;; 边界规范化（`seshat-reader-translate--as-string'）
;;
;; gt 的 translator `text' 槽永远是**分段列表**（一个选区是单元素列表
;; `("文本")'）。上游把它当字符串传给字符串函数时报
;; `Wrong type argument: stringp, ("…")'；本包在边界处统一规范化。

(ert-deftest seshat-reader-translate-test--as-string-normalizes ()
  "字符串原样、nil 为空串、纯字符串列表换行拼接、其它值 `format' 成串."
  (should (equal (seshat-reader-translate--as-string "abc") "abc"))
  (should (equal (seshat-reader-translate--as-string nil) ""))
  (should (equal (seshat-reader-translate--as-string '("a" "b")) "a\nb"))
  (should (equal (seshat-reader-translate--as-string '("only")) "only"))
  (should (equal (seshat-reader-translate--as-string 42) "42"))
  ;; 非字符串元素的列表走 `format'，不抛错
  (should (stringp (seshat-reader-translate--as-string '(1 2)))))

(ert-deftest seshat-reader-translate-test--explain-request-text-accepts-segment-list ()
  "TEXT 为 gt 的单元素分段列表时不抛错，返回含该文本的字符串."
  (let* ((text '("Kademlia: A Peer-to-Peer Information SyBased on the XOR Metric?"))
         (assembled (seshat-reader-translate--explain-request-text
                     text "CTX" "docname" '(en zh))))
    (should (stringp assembled))
    (should (string-match-p "Kademlia" assembled))))

(ert-deftest seshat-reader-translate-test--apply-template-accepts-segment-list ()
  "TEXT 为单元素列表时返回字符串，且不把 prin1 括号形态写进面板."
  (let ((seshat-reader-select-last nil))
    (let ((rendered (seshat-reader-translate--apply-template
                     '("Kademlia: A Peer-to-Peer Information System")
                     "Seshat 译文" '(en zh) 'translate)))
      (should (stringp rendered))
      (should (string-match-p "Kademlia" rendered))
      ;; 关键断言：不能出现列表的 prin1 形态 `("Kademlia' / `(Kademlia'
      (should-not (string-match-p "(Kademlia" rendered))
      (should-not (string-match-p "(\"" rendered)))
    ;; 模板为 nil 的早退分支同样返回字符串形态
    (let ((seshat-reader-translate-template nil)
          (seshat-reader-select-last nil))
      (should (equal (seshat-reader-translate--apply-template
                      '("纯正文") "T" nil 'translate)
                     "纯正文")))))

(ert-deftest seshat-reader-translate-test--record-result-accepts-segment-list ()
  "EXTRACTED 的 TEXT 是分段列表时 `last-result' 仍是字符串."
  (let ((seshat-reader-translate-strip-chatter t)
        (seshat-reader-translate-last-result nil))
    (should (equal (seshat-reader-translate--record-result
                    '(("某段译文") . nil))
                   "某段译文"))
    (should (stringp seshat-reader-translate-last-result))
    (should (equal seshat-reader-translate-last-result "某段译文"))))

(provide 'seshat-reader-translate-test)
;;; seshat-reader-translate-test.el ends here

