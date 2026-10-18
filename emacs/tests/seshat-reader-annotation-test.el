;;; seshat-reader-annotation-test.el --- ERT tests for seshat-reader-annotation  -*- lexical-binding: t; -*-

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

;; `seshat-reader-annotation' 的 ERT 测试套件。
;;
;; 全部用例**绝不触网**：统一用 `cl-letf' 桩替 `seshat-rest--request'，
;; 由桩记录实参（方法、路径、请求体）并返回构造好的 (STATUS . BODY)
;; 假响应；任何真实 HTTP 调用都不会发生。
;;
;; 临时文件与目录一律建在 `temporary-file-directory'（通常 /tmp）下，
;; 并在用例结束时递归删除，因此测试可重复运行、不污染仓库。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'seshat-reader-annotation)

;; 测试隔离：绝不写用户的真实队列文件，也不在测试期间启用自动同步定时器。
(require 'seshat-reader-annotation-queue)
(seshat-reader-annotation-queue-disable-timer)
(setq seshat-reader-annotation-queue-file
      (expand-file-name "annotation-queue.eld" (make-temp-file "seshat-annotation-test-queue" t)))

(defvar seshat-reader-annotation-test--calls nil
  "最近一批桩替调用记录，元素形如 (METHOD PATH REQUEST-BODY).")

(defun seshat-reader-annotation-test--stub (status response-body)
  "返回一个桩替 `seshat-rest--request' 的闭包.
闭包把每次调用的 (METHOD PATH REQUEST-BODY) 压入
`seshat-reader-annotation-test--calls'，并恒返回 (STATUS . RESPONSE-BODY)."
  (lambda (method path &optional request-body)
    (push (list method path request-body) seshat-reader-annotation-test--calls)
    (cons status response-body)))

(defmacro seshat-reader-annotation-test--with-stub (status body &rest forms)
  "桩替 `seshat-rest--request' 后求值 FORMS，并返回调用记录.
STATUS 与 BODY 是桩恒定返回的假响应；返回值是本次记录的调用列表
（元素形如 (METHOD PATH REQUEST-BODY)）。"
  (declare (indent 2) (debug t))
  `(let ((seshat-reader-annotation-test--calls nil))
     (cl-letf (((symbol-function 'seshat-rest--request)
                (seshat-reader-annotation-test--stub ,status ,body)))
       ,@forms)
     seshat-reader-annotation-test--calls))

(defmacro seshat-reader-annotation-test--with-temp-dir (var &rest body)
  "在临时目录中执行 BODY，并把目录名绑定到 VAR.
临时目录在 BODY 结束后递归删除；VAR 绑定为带末尾斜杠的目录名。"
  (declare (indent 1) (debug t))
  `(let ((,var (file-name-as-directory (make-temp-file "seshat-annotation-test" t))))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun seshat-reader-annotation-test--render (file annotations)
  "以假批注 ANNOTATIONS 渲染 FILE 的批注列表，返回列表 buffer.
ANNOTATIONS 为将作为服务端 JSON 响应返回的 Lisp 数据。"
  (with-temp-buffer
    (setq buffer-file-name file)
    (seshat-reader-annotation-test--with-stub 200 (json-encode annotations)
      (seshat-reader-annotation-list)))
  (get-buffer seshat-reader-annotation-list-buffer-name))

;;; document_id 派生

(ert-deftest seshat-reader-annotation-test--doc-id-hit-root ()
  "命中已配置文档根时返回 \"<标签>:<相对路径>\"."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "doc.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir))))
      (with-temp-file file)
      (should (equal (seshat-reader-annotation--doc-id file) "lib:doc.pdf")))))

(ert-deftest seshat-reader-annotation-test--doc-id-local-fallback ()
  "未命中任何根时降级为 \"local:<绝对路径>\" 并提示一次."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "doc.pdf" dir))
           (seshat-reader-annotation-roots nil)
           (messages 0))
      (with-temp-file file)
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (cl-incf messages))))
        (should (equal (seshat-reader-annotation--doc-id file)
                       (concat "local:" (file-truename (expand-file-name file))))))
      (should (= messages 1)))))

(ert-deftest seshat-reader-annotation-test--doc-id-longest-root-wins ()
  "多个根同时命中时取最长（最具体）的根."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((outer (file-name-as-directory (expand-file-name "A" dir)))
           (inner (file-name-as-directory (expand-file-name "A/sub" dir)))
           (file (expand-file-name "doc.pdf" inner))
           (seshat-reader-annotation-roots (list (cons "outer" outer)
                                                 (cons "inner" inner))))
      (make-directory inner t)
      (with-temp-file file)
      (should (equal (seshat-reader-annotation--doc-id file) "inner:doc.pdf")))))

;;; location 组装

(ert-deftest seshat-reader-annotation-test--location-format ()
  "位置字符串为 1-based 页码加两位小数的四个坐标."
  (should (equal (seshat-reader-annotation--location 1 '(10 20 30 40))
                 "page:1;rect:10.00,20.00,30.00,40.00"))
  (should (equal (seshat-reader-annotation--location
                  545 '(0.0 545.5 100.0 600.0))
                 "page:545;rect:0.00,545.50,100.00,600.00")))

(ert-deftest seshat-reader-annotation-test--location-rejects-bad-page ()
  "页码不是正整数时抛 `user-error'."
  (dolist (page (list nil 0 -1 1.5))
    (should-error (seshat-reader-annotation--location page '(0 0 1 1))
                  :type 'user-error)))

;;; 创建批注

(ert-deftest seshat-reader-annotation-test--create-assembles-request ()
  "创建批注时请求体含正确的 document_id、location 与 text."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (seshat-reader-select-last
            (list :file file :page 3 :rect '(1 2 3 4) :text "选区文本")))
      (with-temp-file file)
      (let ((calls (seshat-reader-annotation-test--with-stub
                      201 "{\"id\":7,\"document_id\":\"lib:book.pdf\"}"
                    (seshat-reader-annotation-create))))
        (should calls)
        (let* ((call (car calls))
               (body (json-parse-string (nth 2 call) :object-type 'alist)))
          (should (equal (nth 0 call) "POST"))
          (should (equal (nth 1 call) "/api/annotations"))
          (should (equal (alist-get 'document_id body) "lib:book.pdf"))
          (should (equal (alist-get 'location body)
                         "page:3;rect:1.00,2.00,3.00,4.00"))
          (should (equal (alist-get 'text body) "选区文本")))))))

(ert-deftest seshat-reader-annotation-test--create-explicit-body-wins ()
  "带前缀参数（显式 BODY）时覆盖选区文本."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (seshat-reader-select-last
            (list :file file :page 1 :rect '(0 0 1 1) :text "选区文本")))
      (with-temp-file file)
      (let* ((calls (seshat-reader-annotation-test--with-stub 201 "{\"id\":1}"
                      (seshat-reader-annotation-create "显式正文")))
             (call (car calls))
             (body (json-parse-string (nth 2 call) :object-type 'alist)))
        (should (equal (alist-get 'text body) "显式正文"))))))

(ert-deftest seshat-reader-annotation-test--create-blank-body-falls-back ()
  "显式 BODY 为空白时退回使用选区文本."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (seshat-reader-select-last
            (list :file file :page 1 :rect '(0 0 1 1) :text "选区文本")))
      (with-temp-file file)
      (let* ((calls (seshat-reader-annotation-test--with-stub 201 "{\"id\":1}"
                      (seshat-reader-annotation-create "   ")))
             (call (car calls))
             (body (json-parse-string (nth 2 call) :object-type 'alist)))
        (should (equal (alist-get 'text body) "选区文本"))))))

(ert-deftest seshat-reader-annotation-test--create-without-selection-errors ()
  "没有选区时创建批注抛 `user-error'."
  (let ((seshat-reader-select-last nil))
    (should-error (seshat-reader-annotation-create) :type 'user-error)))

;;; 列表渲染

(ert-deftest seshat-reader-annotation-test--list-renders-entries ()
  "列表渲染含页码、摘要与正确的文本属性."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (annotations (list (list (cons 'id 1)
                                    (cons 'location "page:12;rect:0.00,0.00,1.00,1.00")
                                    (cons 'text "第一条批注"))
                              (list (cons 'id 2)
                                    (cons 'location "page:7;rect:0.00,0.00,1.00,1.00")
                                    (cons 'text "第二条")))))
      (with-temp-file file)
      (with-current-buffer (seshat-reader-annotation-test--render file annotations)
        (let ((content (buffer-string)))
          (should (string-match-p "第一条批注" content))
          (should (string-match-p "第二条" content)))
        (goto-char (point-min))
        (should (equal (get-text-property (point) 'seshat-reader-annotation-id) 1))
        (should (equal (get-text-property (point) 'seshat-reader-annotation-page) 12))
        (forward-line 1)
        (should (equal (get-text-property (point) 'seshat-reader-annotation-id) 2))
        (should (equal (get-text-property (point) 'seshat-reader-annotation-page) 7))))))

(ert-deftest seshat-reader-annotation-test--list-empty-shows-hint ()
  "空批注列表渲染一行提示."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir))))
      (with-temp-file file)
      (with-current-buffer (seshat-reader-annotation-test--render file [])
        (should (string-match-p "没有批注" (buffer-string)))))))

(ert-deftest seshat-reader-annotation-test--list-unparseable-page ()
  "无法解析页码的 location 显示 ? 且页码属性为 nil."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (annotations (list (list (cons 'id 9)
                                    (cons 'location "bogus")
                                    (cons 'text "无页码")))))
      (with-temp-file file)
      (with-current-buffer (seshat-reader-annotation-test--render file annotations)
        (goto-char (point-min))
        (should (equal (get-text-property (point) 'seshat-reader-annotation-id) 9))
        (should-not (get-text-property (point) 'seshat-reader-annotation-page))
        (should (string-match-p "\\?" (buffer-string)))
        (should (string-match-p "无法从 location 解析页码" (buffer-string)))))))

;;; 列表拉取的 HTTP 错误（T7：非 2xx 不得伪装成「无批注」）

(ert-deftest seshat-reader-annotation-test--list-http-error-reports ()
  "服务端返回 500 时返回失败哨兵，并 message 一条含状态码的提示."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (seshat-reader-annotation-test--with-stub
          500 "{\"error\":{\"code\":\"internal\",\"message\":\"boom\"}}"
        (should (eq (seshat-reader-annotation--fetch "x")
                    seshat-reader-annotation--fetch-error))))
    (should messages)
    (should (string-match-p "500" (car messages)))))

(ert-deftest seshat-reader-annotation-test--list-auth-error-reports ()
  "服务端返回 401（鉴权失败）时同样返回失败哨兵并提示状态码."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (seshat-reader-annotation-test--with-stub
          401 "{\"error\":{\"code\":\"unauthorized\"}}"
        (should (eq (seshat-reader-annotation--fetch "x")
                    seshat-reader-annotation--fetch-error))))
    (should messages)
    (should (string-match-p "401" (car messages)))))

;;; 删除批注

(ert-deftest seshat-reader-annotation-test--delete-success ()
  "2xx 删除返回 t，且 id 字符串化后出现在请求路径."
  (let ((calls (seshat-reader-annotation-test--with-stub 204 ""
                 (should (seshat-reader-annotation-delete 42)))))
    (let ((call (car calls)))
      (should (equal (nth 0 call) "DELETE"))
      (should (equal (nth 1 call) "/api/annotations/42")))))

(ert-deftest seshat-reader-annotation-test--delete-failure ()
  "非 2xx 删除返回 nil."
  (seshat-reader-annotation-test--with-stub 404 ""
    (should-not (seshat-reader-annotation-delete 42))))

;;; 更新批注（当前无消费者，必须有测试兜底）

(ert-deftest seshat-reader-annotation-test--update-annotation-request ()
  "更新批注发 PUT，路径含 URL 编码 id，请求体含 location 与 text."
  (let* ((calls (seshat-reader-annotation-test--with-stub
                    200 (concat "{\"id\":1,"
                                "\"location\":\"page:5;rect:0.00,0.00,1.00,1.00\","
                                "\"text\":\"改\"}")
                  (should (seshat-rest-update-annotation
                           "a b/c" "page:5;rect:0.00,0.00,1.00,1.00" "改"))))
         (call (car calls))
         (body (json-parse-string (nth 2 call) :object-type 'alist)))
    (should (equal (nth 0 call) "PUT"))
    (should (equal (nth 1 call)
                   (format "/api/annotations/%s" (url-hexify-string "a b/c"))))
    (should (equal (alist-get 'location body)
                   "page:5;rect:0.00,0.00,1.00,1.00"))
    (should (equal (alist-get 'text body) "改"))))

;;; 审查补充：创建前置条件、交互声明与列表侧容错

(ert-deftest seshat-reader-annotation-test--create-without-file-errors ()
  "选区未记录文档文件（:file 为 nil）时创建批注抛 `user-error'."
  (let ((seshat-reader-select-last (list :file nil :page 1 :rect '(0 0 1 1)
                                         :text "正文"))
        (caught nil))
    (condition-case err
        (seshat-reader-annotation-create)
      (user-error (setq caught err)))
    (should caught)
    (should (string-match-p "选区未记录文档文件" (error-message-string caught)))))

(ert-deftest seshat-reader-annotation-test--create-empty-text-errors ()
  "选区文本为空且无显式 BODY 时创建批注抛 `user-error'."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (seshat-reader-select-last (list :file file :page 1 :rect '(0 0 1 1)
                                            :text "   "))
           (caught nil))
      (with-temp-file file)
      (condition-case err
          (seshat-reader-annotation-create)
        (user-error (setq caught err)))
      (should caught)
      (should (string-match-p "选区没有文本" (error-message-string caught))))))

(ert-deftest seshat-reader-annotation-test--create-interactive-prefix ()
  "交互声明：带前缀参数时读入正文；不带前缀时不读入、退回选区文本."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (seshat-reader-select-last (list :file file :page 2 :rect '(0 0 1 1)
                                            :text "选区文本"))
           (read-args nil))
      (with-temp-file file)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest args) (setq read-args args) "读入正文")))
        ;; 带前缀参数：经 read-string 读入正文并覆盖选区文本
        (let ((calls (seshat-reader-annotation-test--with-stub
                         201 "{\"id\":1}"
                      (let ((current-prefix-arg '(4)))
                        (call-interactively #'seshat-reader-annotation-create)))))
          (should (equal read-args '("批注正文: ")))
          (should calls)
          (let* ((call (car calls))
                 (body (json-parse-string (nth 2 call) :object-type 'alist)))
            (should (equal (alist-get 'text body) "读入正文"))))
        ;; 不带前缀参数：不调用 read-string，退回选区文本
        (setq read-args nil)
        (let ((calls (seshat-reader-annotation-test--with-stub
                         201 "{\"id\":2}"
                      (let ((current-prefix-arg nil))
                        (call-interactively #'seshat-reader-annotation-create)))))
          (should-not read-args)
          (should calls)
          (let* ((call (car calls))
                 (body (json-parse-string (nth 2 call) :object-type 'alist)))
            (should (equal (alist-get 'text body) "选区文本"))))))))

(ert-deftest seshat-reader-annotation-test--list-delete-without-id-messages ()
  "列表行无批注 id 时删除仅 message 提示，不发起请求、不抛错."
  (with-temp-buffer
    (seshat-reader-annotation-list-mode)
    (let ((inhibit-read-only t))
      (insert "  1  （该文档没有批注）\n"))
    (goto-char (point-min))
    (setq-local seshat-reader-annotation-list-document-id "lib:book.pdf")
    (setq-local seshat-reader-annotation-list-source nil)
    (let ((messages nil)
          (delete-called nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages)))
                ((symbol-function 'seshat-reader-annotation-delete)
                 (lambda (&rest _) (setq delete-called t) t)))
        (seshat-reader-annotation-list-delete))
      (should-not delete-called)
      (should messages)
      (should (string-match-p "没有关联批注" (car messages))))))

(ert-deftest seshat-reader-annotation-test--list-goto-dead-source-messages ()
  "原始 source 缓冲区已关闭时跳页仅 message 提示，不抛错."
  (let ((source (generate-new-buffer " *seshat-annotation-dead-source*")))
    (kill-buffer source)
    (with-temp-buffer
      (seshat-reader-annotation-list-mode)
      (let ((inhibit-read-only t))
        (insert (propertize "  1  某批注\n"
                            'seshat-reader-annotation-page 1)))
      (goto-char (point-min))
      (setq-local seshat-reader-annotation-list-source source)
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (seshat-reader-annotation-list-goto))
        (should messages)
        (should (string-match-p "原始文档缓冲区已不存在" (car messages)))))))

(ert-deftest seshat-reader-annotation-test--list-goto-non-reader-source-messages ()
  "原始 source 存活但非 seshat-reader 视图时跳页仅 message 提示，不抛错."
  (let ((source (generate-new-buffer " *seshat-annotation-fundamental-source*")))
    (unwind-protect
        (with-temp-buffer
          (seshat-reader-annotation-list-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "  1  某批注\n"
                                'seshat-reader-annotation-page 1)))
          (goto-char (point-min))
          (setq-local seshat-reader-annotation-list-source source)
          (let ((messages nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) messages))))
              (seshat-reader-annotation-list-goto))
            (should messages)
            (should (string-match-p "已不是 seshat-reader 视图" (car messages)))))
      (kill-buffer source))))

;;; 全量渲染（无分页）：合并入口与「全量条目 + 无页脚」

(defun seshat-reader-annotation-test--make-annotations (n)
  "构造 N 条服务端批注，第 I 条页码为 I、正文为 \"批注-I\"（两位补零）."
  (cl-loop for i from 1 to n
           collect (list (cons 'id i)
                         (cons 'location
                               (format "page:%d;rect:0.00,0.00,1.00,1.00" i))
                         (cons 'text (format "批注-%02d" i)))))

(defun seshat-reader-annotation-test--render-fresh (file annotations)
  "清掉既有列表缓冲区后渲染 FILE 的 ANNOTATIONS，返回列表 buffer.
清缓冲区是为了让每次渲染都从干净状态开始（不复用上一次的缓冲区内容）。"
  (when (get-buffer seshat-reader-annotation-list-buffer-name)
    (kill-buffer seshat-reader-annotation-list-buffer-name))
  (seshat-reader-annotation-test--render file annotations))

(ert-deftest seshat-reader-annotation-test--all-items-matches-etaf-items ()
  "`--all-items' 与 `--etaf-items' 完全一致，且服务端项在前、本地项在后."
  (let* ((annotations (list (list (cons 'id 1)
                                  (cons 'location "page:2;rect:0.00,0.00,1.00,1.00")
                                  (cons 'text "服务端一"))
                            (list (cons 'id 2)
                                  (cons 'location "page:5;rect:0.00,0.00,1.00,1.00")
                                  (cons 'text "服务端二"))))
         (queued (list (list :uuid "u1" :action 'create :document-id "lib:book.pdf"
                             :location "page:9;rect:0.00,0.00,1.00,1.00"
                             :text "本地一")
                       (list :uuid "u2" :action 'create :document-id "lib:book.pdf"
                             :location "page:1;rect:0.00,0.00,1.00,1.00"
                             :text "本地二")))
         (all (seshat-reader-annotation--all-items annotations queued)))
    ;; 单一合并来源：与既有合并逻辑逐项 `equal'
    (should (equal all (seshat-reader-annotation--etaf-items annotations queued)))
    (should (= (length all) 4))
    (should (equal (mapcar (lambda (item) (plist-get item :id)) all)
                   '(1 2 nil nil)))
    (should (equal (mapcar (lambda (item) (plist-get item :uuid)) all)
                   '(nil nil "u1" "u2")))
    (should (equal (mapcar (lambda (item) (plist-get item :dirty)) all)
                   '(nil nil t t)))
    (should (equal (mapcar (lambda (item) (plist-get item :page)) all)
                   '(2 5 9 1)))))

(ert-deftest seshat-reader-annotation-test--render-list-all-items-no-footer ()
  "21 条批注全量渲染：末条也在列表里，且末尾不再有页脚行."
  (seshat-reader-annotation-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "lib" dir)))
           (annotations (seshat-reader-annotation-test--make-annotations 21)))
      (with-temp-file file)
      (let ((buffer (seshat-reader-annotation-test--render-fresh file annotations)))
        (with-current-buffer buffer
          ;; 21 条各占一行，无页脚
          (should (= (count-lines (point-min) (point-max)) 21))
          (should (string-match-p "批注-01" (buffer-string)))
          (should (string-match-p "批注-20" (buffer-string)))
          (should (string-match-p "批注-21" (buffer-string)))
          (should-not (string-match-p "第 1/2 页" (buffer-string)))
          (should-not (string-match-p "-- 第" (buffer-string))))))))

(ert-deftest seshat-reader-annotation-test--list-mode-no-paging-keys ()
  "列表 mode 不再把 `]' / `[' 绑到翻页命令，翻页命令本身也已删除."
  (should-not (fboundp 'seshat-reader-annotation-list-next-page))
  (should-not (fboundp 'seshat-reader-annotation-list-prev-page))
  (should-not (fboundp 'seshat-reader-annotation-list-first-page))
  (should-not (fboundp 'seshat-reader-annotation-list-last-page))
  (with-temp-buffer
    (seshat-reader-annotation-list-mode)
    (dolist (sequence '("]" "["))
      (should-not (memq (key-binding (kbd sequence))
                        '(seshat-reader-annotation-list-next-page
                          seshat-reader-annotation-list-prev-page
                          seshat-reader-annotation-list-first-page
                          seshat-reader-annotation-list-last-page))))))

(provide 'seshat-reader-annotation-test)
;;; seshat-reader-annotation-test.el ends here
