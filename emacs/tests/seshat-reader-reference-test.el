;;; seshat-reader-reference-test.el --- Tests for seshat-reader-reference  -*- lexical-binding: t; -*-

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

;; `seshat-reader-reference' 的 ERT 测试套件。
;;
;; 运行方式（在仓库根目录执行；下文以 `emacs' 指代可执行文件名）：
;;
;;   cd /home/thomas/WorkSpace/notes && \
;;   `emacs' --batch -Q -L `emacs' -L `emacs'/seshat-reader \
;;     -l `emacs'/tests/seshat-reader-reference-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建。
;;
;; 全部用例**绝不触网**、**绝不写用户真实文件**：落点文件与文档根一律
;; `let' 绑定到 `temporary-file-directory' 下的临时路径；`:follow' 与
;; `--insert-into-file' 的副作用入口用 `cl-letf' 桩替，文档存在性检查用
;; `(make-temp-file "seshat-ref-" nil ".pdf")' 造真实空文件通过。
;;
;; 本文件同时 `(require 'seshat-reader)'，以取到 `seshat-reader-mode' 符号
;; （`open' 的 buffer 复用分支用它与 major-mode 比较）；若不前置该 require，
;; `(setq major-mode 'seshat-reader-mode)' 会因符号未定义而失败。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)
(require 'seshat-reader-annotation)
(require 'seshat-reader-reference)

(defmacro seshat-reader-reference-test--with-temp-dir (var &rest body)
  "在临时目录中执行 BODY，并把目录名绑定到 VAR.
临时目录在 BODY 结束后递归删除；VAR 绑定为带末尾斜杠的目录名。"
  (declare (indent 1) (debug t))
  `(let ((,var (file-name-as-directory (make-temp-file "seshat-ref-test" t))))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun seshat-reader-reference-test--temp-pdf ()
  "在临时目录中造一个空的 .pdf 文件，返回其绝对路径.
调用方负责在用例结束时删除该文件。"
  (make-temp-file "seshat-ref-" nil ".pdf"))

;;; 链接构造与解析

(ert-deftest seshat-reader-reference-test--link-no-location ()
  "无 location（nil 或空串）时构造整篇文档链接."
  (should (equal (seshat-reader-reference--link "ebook:a.pdf")
                 "seshat:ebook:a.pdf"))
  (should (equal (seshat-reader-reference--link "ebook:a.pdf" nil)
                 "seshat:ebook:a.pdf"))
  (should (equal (seshat-reader-reference--link "ebook:a.pdf" "")
                 "seshat:ebook:a.pdf")))

(ert-deftest seshat-reader-reference-test--link-with-location ()
  "带 location 时以 `#' 追加位置片段."
  (should (equal (seshat-reader-reference--link "ebook:a.pdf" "page:3")
                 "seshat:ebook:a.pdf#page:3"))
  (should (equal (seshat-reader-reference--link
                  "ebook:a.pdf" "page:112;rect:50.00,100.00,545.00,140.00")
                 "seshat:ebook:a.pdf#page:112;rect:50.00,100.00,545.00,140.00")))

(ert-deftest seshat-reader-reference-test--link-local-value ()
  "`local:' 降级值同样可构造链接."
  (should (equal (seshat-reader-reference--link "local:/abs/a.pdf")
                 "seshat:local:/abs/a.pdf"))
  (should (equal (seshat-reader-reference--link "local:/abs/a.pdf" "page:9")
                 "seshat:local:/abs/a.pdf#page:9")))

(ert-deftest seshat-reader-reference-test--link-parse-roundtrip ()
  "构造后再解析，doc-id 与含 rect 的完整 location 均应原样往返."
  (let* ((doc-id "ebook:a.pdf")
         (location "page:112;rect:50.00,100.00,545.00,140.00")
         (parsed (seshat-reader-reference--parse-link
                  (seshat-reader-reference--link doc-id location))))
    (should (equal (plist-get parsed :doc-id) doc-id))
    (should (equal (plist-get parsed :location) location)))
  (let ((parsed (seshat-reader-reference--parse-link
                 (seshat-reader-reference--link "local:/abs/a.pdf" "page:9"))))
    (should (equal (plist-get parsed :doc-id) "local:/abs/a.pdf"))
    (should (equal (plist-get parsed :location) "page:9"))))

(ert-deftest seshat-reader-reference-test--parse-link-without-location-keeps-key ()
  "无 location 时返回的 plist 仍含 `:location' 键且值为 nil."
  (let ((parsed (seshat-reader-reference--parse-link "seshat:ebook:a.pdf")))
    (should (plist-member parsed :location))
    (should-not (plist-get parsed :location))
    (should (equal (plist-get parsed :doc-id) "ebook:a.pdf"))))

(ert-deftest seshat-reader-reference-test--parse-link-accepts-missing-prefix ()
  "带与不带 `seshat:' 前缀的输入解析结果一致."
  (should (equal (seshat-reader-reference--parse-link "seshat:ebook:a.pdf#page:3")
                 (seshat-reader-reference--parse-link "ebook:a.pdf#page:3")))
  (should (equal (seshat-reader-reference--parse-link "ebook:a.pdf#page:3")
                 (list :doc-id "ebook:a.pdf" :location "page:3"))))

(ert-deftest seshat-reader-reference-test--parse-link-invalid-returns-nil ()
  "非字符串、空串与 `#' 前文档标识为空时返回 nil."
  (should-not (seshat-reader-reference--parse-link nil))
  (should-not (seshat-reader-reference--parse-link 42))
  (should-not (seshat-reader-reference--parse-link ""))
  (should-not (seshat-reader-reference--parse-link "seshat:"))
  (should-not (seshat-reader-reference--parse-link "#page:3"))
  (should-not (seshat-reader-reference--parse-link "seshat:#page:3")))

;;; 转义不变量

(ert-deftest seshat-reader-reference-test--link-rejects-hash ()
  "DOC-ID 含 `#' 时构造链接抛 `user-error'."
  (should-error (seshat-reader-reference--link "ebook:a#b.pdf")
                :type 'user-error)
  (should-error (seshat-reader-reference--link "ebook:a#b.pdf" "page:1")
                :type 'user-error))

(ert-deftest seshat-reader-reference-test--link-rejects-percent ()
  "DOC-ID 含 `%' 时构造链接抛 `user-error'."
  (should-error (seshat-reader-reference--link "ebook:a%b.pdf")
                :type 'user-error))

;;; doc-id 反解析

(ert-deftest seshat-reader-reference-test--file-from-doc-id-hit-root ()
  "命中已配置根时返回该根下的绝对路径."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "ebook" dir))))
      (with-temp-file file)
      (should (equal (seshat-reader-reference--file-from-doc-id "ebook:book.pdf")
                     file)))))

(ert-deftest seshat-reader-reference-test--file-from-doc-id-unknown-tag ()
  "标签不在根列表中时返回 nil."
  (let ((seshat-reader-annotation-roots nil))
    (should-not (seshat-reader-reference--file-from-doc-id "ebook:book.pdf")))
  (let ((seshat-reader-annotation-roots (list (cons "other" "/tmp/"))))
    (should-not (seshat-reader-reference--file-from-doc-id "ebook:book.pdf"))))

(ert-deftest seshat-reader-reference-test--file-from-doc-id-local-prefix ()
  "`local:' 前缀直接返回冒号之后的绝对路径，不做其它改写."
  (should (equal (seshat-reader-reference--file-from-doc-id "local:/abs/path.pdf")
                 "/abs/path.pdf"))
  (should (equal (seshat-reader-reference--file-from-doc-id "local:/a/b/c.pdf")
                 "/a/b/c.pdf")))

(ert-deftest seshat-reader-reference-test--file-from-doc-id-longest-root ()
  "嵌套多根时正向取更具体（更长）的根，反向解析回到该根下路径."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((outer (file-name-as-directory (expand-file-name "A" dir)))
           (inner (file-name-as-directory (expand-file-name "A/sub" dir)))
           (file (expand-file-name "book.pdf" inner))
           (seshat-reader-annotation-roots (list (cons "outer" outer)
                                                 (cons "inner" inner))))
      (make-directory inner t)
      (with-temp-file file)
      (should (equal (seshat-reader-annotation--doc-id file) "inner:book.pdf"))
      (let ((resolved (seshat-reader-reference--file-from-doc-id
                       (seshat-reader-annotation--doc-id file))))
        (should (file-equal-p resolved file))
        (should (file-in-directory-p resolved inner))))))

(ert-deftest seshat-reader-reference-test--file-from-doc-id-missing-root-derives ()
  "挂载根目录不存在时仍返回推导出的路径（本函数不校验存在性）."
  (let ((seshat-reader-annotation-roots
         (list (cons "ghost" "/nonexistent/seshat-root/"))))
    (should (equal (seshat-reader-reference--file-from-doc-id "ghost:book.pdf")
                   "/nonexistent/seshat-root/book.pdf"))))

;;; 摘录块组装

(ert-deftest seshat-reader-reference-test--format-block-default ()
  "默认模板产物含正文、`seshat:' 链接与描述."
  (let ((block (seshat-reader-reference--format-block
                "摘录正文" "ebook:a.pdf" "page:3")))
    (should (string-match-p "摘录正文" block))
    (should (string-match-p "#\\+begin_quote" block))
    (should (string-match-p "\\[\\[seshat:ebook:a.pdf#page:3\\]\\[a.pdf 第 3 页\\]\\]"
                            block))))

(ert-deftest seshat-reader-reference-test--format-block-custom ()
  "绑定自定义模板后按新模板渲染."
  (let ((seshat-reader-reference-format "TEXT=%s LINK=%s DESC=%s\n"))
    (should (equal (seshat-reader-reference--format-block
                    "正文" "ebook:a.pdf" "page:3")
                   "TEXT=正文 LINK=seshat:ebook:a.pdf#page:3 DESC=a.pdf 第 3 页\n"))))

(ert-deftest seshat-reader-reference-test--format-block-explicit-description ()
  "显式传入 DESCRIPTION 时不再现算描述."
  (let ((seshat-reader-reference-format "%s|%s|%s\n"))
    (should (equal (seshat-reader-reference--format-block
                    "正文" "ebook:a.pdf" "page:3" "自定义描述")
                   "正文|seshat:ebook:a.pdf#page:3|自定义描述\n"))))

;;; 写入目标文件（追加语义）

(ert-deftest seshat-reader-reference-test--insert-into-file-appends ()
  "两次插入追加到临时文件末尾，不覆盖既有内容."
  (let ((file (make-temp-file "seshat-ref-insert-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "初始内容\n"))
          (seshat-reader-reference--insert-into-file "第一次" file)
          (seshat-reader-reference--insert-into-file "第二次" file)
          (should (equal (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "初始内容\n第一次\n第二次\n")))
      (delete-file file))))

(ert-deftest seshat-reader-reference-test--insert-into-file-visited-buffer ()
  "目标文件已有关联 buffer 时就地追加并保存."
  (let ((file (make-temp-file "seshat-ref-insert-visit-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "既有\n"))
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (seshat-reader-reference--insert-into-file "追加" file)
              (kill-buffer buf)))
          (should (equal (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "既有\n追加\n")))
      (delete-file file))))

;;; :follow（seshat-reader-reference-open）

(ert-deftest seshat-reader-reference-test--follow-opens-doc-and-goto-page ()
  "无既有 buffer 时调用 open-doc（实参为解析出的绝对路径）与 1-based 跳页."
  (let ((file (seshat-reader-reference-test--temp-pdf)))
    (unwind-protect
        (let* ((seshat-reader-annotation-roots
                (list (cons "ebook" (file-name-directory file))))
               (doc-id (concat "ebook:" (file-name-nondirectory file)))
               (opened nil)
               (page-arg nil))
          (cl-letf (((symbol-function 'find-buffer-visiting)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-open-doc)
                     (lambda (doc) (setq opened doc)))
                    ((symbol-function 'seshat-reader-goto-page)
                     (lambda (n) (setq page-arg n))))
            (seshat-reader-reference-open (concat "seshat:" doc-id "#page:3")))
          (should (equal opened (expand-file-name file)))
          (should (equal page-arg 3)))
      (delete-file file))))

(ert-deftest seshat-reader-reference-test--follow-reuses-existing-reader-buffer ()
  "命中已有 `seshat-reader-mode' buffer 时不调用 `seshat-reader-open-doc'，仅 `pop-to-buffer'."
  (let ((file (seshat-reader-reference-test--temp-pdf)))
    (unwind-protect
        (let ((seshat-reader-annotation-roots
               (list (cons "ebook" (file-name-directory file))))
              (doc-id (concat "ebook:" (file-name-nondirectory file)))
              (opened nil)
              (page-arg nil)
              (poped nil))
          (with-temp-buffer
            (setq major-mode 'seshat-reader-mode)
            (let ((buf (current-buffer)))
              (cl-letf (((symbol-function 'find-buffer-visiting)
                         (lambda (&rest _) buf))
                        ((symbol-function 'seshat-reader-open-doc)
                         (lambda (doc) (setq opened doc)))
                        ((symbol-function 'seshat-reader-goto-page)
                         (lambda (n) (setq page-arg n)))
                        ((symbol-function 'pop-to-buffer)
                         (lambda (b &rest _) (setq poped b) b)))
                (seshat-reader-reference-open (concat "seshat:" doc-id "#page:3")))
              (should (eq poped buf))))
          (should-not opened)
          (should (equal page-arg 3)))
      (delete-file file))))

(ert-deftest seshat-reader-reference-test--follow-without-page-skips-goto ()
  "链接无 `page:' 片段时不调用 goto-page."
  (let ((file (seshat-reader-reference-test--temp-pdf)))
    (unwind-protect
        (let* ((seshat-reader-annotation-roots
                (list (cons "ebook" (file-name-directory file))))
               (doc-id (concat "ebook:" (file-name-nondirectory file)))
               (opened nil)
               (goto-called nil))
          (cl-letf (((symbol-function 'find-buffer-visiting)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-open-doc)
                     (lambda (doc) (setq opened doc)))
                    ((symbol-function 'seshat-reader-goto-page)
                     (lambda (_n) (setq goto-called t))))
            (seshat-reader-reference-open (concat "seshat:" doc-id)))
          (should (equal opened (expand-file-name file)))
          (should-not goto-called))
      (delete-file file))))

(ert-deftest seshat-reader-reference-test--follow-with-rect-validates-format ()
  "含 rect 的链接只打开文档、跳到该页，rect 不产生额外 UI 动作."
  (let ((file (seshat-reader-reference-test--temp-pdf)))
    (unwind-protect
        (let* ((seshat-reader-annotation-roots
                (list (cons "ebook" (file-name-directory file))))
               (doc-id (concat "ebook:" (file-name-nondirectory file)))
               (page-arg nil))
          (cl-letf (((symbol-function 'find-buffer-visiting)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-open-doc)
                     (lambda (_doc) nil))
                    ((symbol-function 'seshat-reader-goto-page)
                     (lambda (n) (setq page-arg n))))
            (seshat-reader-reference-open
             (concat "seshat:" doc-id
                     "#page:112;rect:50.00,100.00,545.00,140.00")))
          (should (equal page-arg 112)))
      (delete-file file))))

(ert-deftest seshat-reader-reference-test--follow-unknown-tag-errors ()
  "标签未知时抛 `user-error'."
  (let ((seshat-reader-annotation-roots nil))
    (should-error (seshat-reader-reference-open "seshat:ebook:book.pdf#page:1")
                  :type 'user-error)))

(ert-deftest seshat-reader-reference-test--follow-missing-file-errors ()
  "标签已知但文档不存在时抛 `user-error'."
  (seshat-reader-reference-test--with-temp-dir dir
    (let ((seshat-reader-annotation-roots (list (cons "ebook" dir))))
      (should-error (seshat-reader-reference-open "seshat:ebook:ghost.pdf")
                    :type 'user-error))))

;;; 落点文件读取

(ert-deftest seshat-reader-reference-test--read-target-file-uses-defcustom ()
  "目标文件配置项非空时直接返回展开后的路径，不提示选择."
  (let ((seshat-reader-reference-target-file "~/seshat-ref-target.org"))
    (should (equal (seshat-reader-reference--read-target-file)
                   (expand-file-name "~/seshat-ref-target.org")))))

(ert-deftest seshat-reader-reference-test--read-target-file-prompts-and-remembers ()
  "目标文件配置项为空时用 `read-file-name' 选择，并把结果 setq 记忆到 `seshat-reader-reference-target-file'."
  (let ((seshat-reader-reference-target-file nil)
        (chosen (make-temp-file "seshat-ref-target-" nil ".org"))
        (prompt-start nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (_prompt &optional dir &rest _)
                       (setq prompt-start dir)
                       chosen)))
            (should (equal (seshat-reader-reference--read-target-file) chosen))
            (should (equal seshat-reader-reference-target-file chosen))
            (should (stringp prompt-start)))
          ;; 第二次调用直接命中已记忆值，不再走 read-file-name
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _)
                       (ert-fail "不应再次调用 read-file-name"))))
            (should (equal (seshat-reader-reference--read-target-file) chosen))))
      (delete-file chosen))))

;;; org 链接注册

(ert-deftest seshat-reader-reference-test--org-registration ()
  "`seshat:' 已注册 :follow/:store，且未定制 :export."
  (should (eq (org-link-get-parameter "seshat" :follow)
              #'seshat-reader-reference-open))
  (should (eq (org-link-get-parameter "seshat" :store)
              #'seshat-reader-reference-store-link))
  (should-not (org-link-get-parameter "seshat" :export)))

(ert-deftest seshat-reader-reference-test--org-registration-idempotent ()
  "重复求值注册 form 后 :follow/:store 仍是同一函数（幂等）."
  (dotimes (_ 2)
    (eval '(with-eval-after-load 'org
             (org-link-set-parameters "seshat"
                                      :follow #'seshat-reader-reference-open
                                      :store #'seshat-reader-reference-store-link))
          t))
  (should (eq (org-link-get-parameter "seshat" :follow)
              #'seshat-reader-reference-open))
  (should (eq (org-link-get-parameter "seshat" :store)
              #'seshat-reader-reference-store-link))
  (should-not (org-link-get-parameter "seshat" :export)))

(provide 'seshat-reader-reference-test)
;;; seshat-reader-reference-test.el ends here
