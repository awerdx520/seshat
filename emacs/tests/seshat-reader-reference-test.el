;;; seshat-reader-reference-test.el --- Tests for seshat-reader-reference  -*- lexical-binding: t; -*-

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
  "带与不带 `seshat:' 前缀的输入解析结果一致.
只断言 `:doc-id' / `:location' 的键值（**不**整体 `equal' 整个 plist）：
引入 uid 形态后 plist 多出 `:uid' 键，整体比较会把测试绑死在结构上。"
  (should (equal (seshat-reader-reference--parse-link "seshat:ebook:a.pdf#page:3")
                 (seshat-reader-reference--parse-link "ebook:a.pdf#page:3")))
  (let ((parsed (seshat-reader-reference--parse-link "ebook:a.pdf#page:3")))
    (should (equal (plist-get parsed :doc-id) "ebook:a.pdf"))
    (should (equal (plist-get parsed :location) "page:3"))))

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
  "`seshat:' 已注册 :follow/:store/:export."
  (should (eq (org-link-get-parameter "seshat" :follow)
              #'seshat-reader-reference-open))
  (should (eq (org-link-get-parameter "seshat" :store)
              #'seshat-reader-reference-store-link))
  (should (eq (org-link-get-parameter "seshat" :export)
              #'seshat-reader-reference-export-link)))

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
  (should (eq (org-link-get-parameter "seshat" :export)
              #'seshat-reader-reference-export-link)))

;;; 链接补全（:complete）

(ert-deftest seshat-reader-reference-test--complete-link-candidates ()
  "枚举 roots 下受支持的文档：剔除不支持格式与含 `#'/`%' 的名称、去重、按字典序排序."
  (seshat-reader-reference-test--with-temp-dir dir
    (let ((sub (expand-file-name "sub" dir))
          (seshat-reader-annotation-roots (list (cons "ebook" dir))))
      (make-directory sub)
      (dolist (name '("a.pdf" "b.pdf" "notes.txt" "bad#name.pdf"))
        (with-temp-file (expand-file-name name dir)))
      (with-temp-file (expand-file-name "c.epub" sub))
      (should (equal (seshat-reader-reference--complete-link)
                     '("ebook:a.pdf" "ebook:b.pdf" "ebook:sub/c.epub")))
      ;; 同一根被重复配置时不产生重复候选
      (let ((seshat-reader-annotation-roots (list (cons "ebook" dir)
                                                  (cons "ebook" dir))))
        (should (equal (seshat-reader-reference--complete-link)
                       '("ebook:a.pdf" "ebook:b.pdf" "ebook:sub/c.epub")))))))

(ert-deftest seshat-reader-reference-test--complete-link-empty-roots ()
  "roots 为空、或根目录不存在时返回 nil，不报错."
  (let ((seshat-reader-annotation-roots nil))
    (should-not (seshat-reader-reference--complete-link)))
  (let ((seshat-reader-annotation-roots
         (list (cons "ghost" "/nonexistent/seshat-root/"))))
    (should-not (seshat-reader-reference--complete-link))))

(ert-deftest seshat-reader-reference-test--complete-link-current-doc-first ()
  "阅读器 buffer 内且当前 doc-id 已在候选中时排首位，其余保持字典序."
  (seshat-reader-reference-test--with-temp-dir dir
    (let ((seshat-reader-annotation-roots (list (cons "ebook" dir)))
          (file (expand-file-name "m.pdf" dir)))
      (dolist (name '("a.pdf" "m.pdf" "z.pdf"))
        (with-temp-file (expand-file-name name dir)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (cl-letf (((symbol-function 'derived-mode-p)
                   (lambda (&rest _) t)))
          (should (equal (seshat-reader-reference--complete-link)
                         '("ebook:m.pdf" "ebook:a.pdf" "ebook:z.pdf"))))))))

(ert-deftest seshat-reader-reference-test--complete-link-returns-full-link ()
  ":complete 处理函数返回带前缀的完整链接字符串（org 约定），不自行插入文本."
  (cl-letf (((symbol-function 'seshat-reader-reference--complete-link)
             (lambda () '("ebook:a.pdf" "ebook:b.pdf")))
            ((symbol-function 'completing-read)
             (lambda (&rest _) "ebook:b.pdf")))
    (should (equal (seshat-reader-reference-complete-link)
                   "seshat:ebook:b.pdf")))
  (cl-letf (((symbol-function 'seshat-reader-reference--complete-link)
             (lambda () nil))
            ((symbol-function 'read-string)
             (lambda (_prompt &optional initial &rest _) initial)))
    (should (equal (seshat-reader-reference-complete-link) "seshat:"))))

(ert-deftest seshat-reader-reference-test--org-registration-complete ()
  "`seshat:' 的 `:complete' 参数为补全处理函数（org 已加载时生效）."
  (require 'org nil t)
  (should (eq (org-link-get-parameter "seshat" :complete)
              #'seshat-reader-reference-complete-link)))

;;; 尾部 `#' 归一（T14）

(ert-deftest seshat-reader-reference-test--parse-link-trailing-hash ()
  "尾部裸 `#' 的 location 归一为 nil，有 location 时原样返回."
  (let ((parsed (seshat-reader-reference--parse-link "seshat:ebook:a.pdf#")))
    (should (plist-member parsed :location))
    (should-not (plist-get parsed :location))
    (should (equal (plist-get parsed :doc-id) "ebook:a.pdf")))
  (should (equal (plist-get
                  (seshat-reader-reference--parse-link
                   "seshat:ebook:a.pdf#page:3")
                  :location)
                 "page:3"))
  (should-not (plist-get
               (seshat-reader-reference--parse-link "seshat:ebook:a.pdf")
               :location)))

;;; 链接导出（`:export'，M12 T12）

(ert-deftest seshat-reader-reference-test--export-link-uses-desc ()
  "有 DESC 时各 FORMAT（含 nil）原样采用 DESC，且输出不含裸协议串."
  (dolist (format '(html latex ascii md nil))
    (let ((out (seshat-reader-reference-export-link
                "ebook:a.pdf#page:3" "我的摘录描述" format)))
      (should (stringp out))
      (should (equal out "我的摘录描述"))
      (should-not (string-match-p "seshat:" out))
      (should-not (string-match-p "\\[\\[seshat:" out)))))

(ert-deftest seshat-reader-reference-test--export-link-without-desc ()
  "无 DESC（或空 DESC）时导出为「文件名 + 页号」，各 FORMAT 输出一致."
  (dolist (format '(html latex ascii md nil))
    ;; 带页号：与摘录块描述同源
    (should (equal (seshat-reader-reference-export-link
                    "ebook:a.pdf#page:3" nil format)
                   "a.pdf 第 3 页"))
    ;; 允许缺 `seshat:' 前缀
    (should (equal (seshat-reader-reference-export-link
                    "seshat:ebook:a.pdf#page:3" nil format)
                   "a.pdf 第 3 页"))
    ;; 无 location：只给文件名
    (should (equal (seshat-reader-reference-export-link
                    "ebook:a.pdf" nil format)
                   "a.pdf"))
    ;; 含 rect 的完整 location：描述只看页号
    (should (equal (seshat-reader-reference-export-link
                    "ebook:a.pdf#page:112;rect:50.00,100.00,545.00,140.00"
                    nil format)
                   "a.pdf 第 112 页")))
  ;; 空串 DESC 视同无 DESC
  (should (equal (seshat-reader-reference-export-link "ebook:a.pdf#page:3" "" 'html)
                 "a.pdf 第 3 页")))

(ert-deftest seshat-reader-reference-test--export-link-invalid-path-falls-back ()
  "非法 path 退回原始 `seshat:<path>' 文本，不报错、不返回 nil."
  (should (equal (seshat-reader-reference-export-link "#page:3" nil 'html)
                 "seshat:#page:3"))
  (should (equal (seshat-reader-reference-export-link "" nil 'latex)
                 "seshat:"))
  (should (equal (seshat-reader-reference-export-link nil nil 'ascii)
                 "seshat:"))
  ;; 三个必选实参之外的通信通道参数（org 传 info）也应被接受
  (should (equal (seshat-reader-reference-export-link
                  "ebook:a.pdf#page:3" nil 'html '(:ascii-links-to-notes t))
                 "a.pdf 第 3 页")))

;;; 插入位置（M12 T13）

(defmacro seshat-reader-reference-test--with-org-buffer (content &rest body)
  "在临时 org buffer 中插入 CONTENT 后执行 BODY.
buffer 启用 `org-mode'，`point' 置 `point-min'，便于用 `search-forward' 定位。"
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,content)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(ert-deftest seshat-reader-reference-test--insert-position-default-is-end-of-file ()
  "defcustom 默认值为 `end-of-file'（存量行为不变）."
  (should (eq seshat-reader-reference-insert-position 'end-of-file))
  (should (eq (default-value 'seshat-reader-reference-insert-position)
              'end-of-file)))

(ert-deftest seshat-reader-reference-test--insert-position-end-of-file ()
  "`end-of-file' 与未知值都返回 `(point-max)'."
  (with-temp-buffer
    (insert "abc\ndef\n")
    (should (= (seshat-reader-reference--insert-position 'end-of-file)
               (point-max)))
    (should (= (seshat-reader-reference--insert-position 'no-such-mode)
               (point-max)))))

(ert-deftest seshat-reader-reference-test--insert-position-point ()
  "`point' 返回当前 `point'，且不移动光标."
  (with-temp-buffer
    (insert "abcdef\n")
    (goto-char 3)
    (should (= (seshat-reader-reference--insert-position 'point) 3))
    (should (= (point) 3))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-last-subtree ()
  "光标在最后一个 headline 正文内时返回该子树末尾（= `point-max'）."
  (seshat-reader-reference-test--with-org-buffer "* 第一章\n正文一\n* 第二章\n正文二\n"
    (search-forward "正文二")
    (should (= (seshat-reader-reference--insert-position 'headline)
               (point-max)))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-next-sibling ()
  "光标在第一个 headline 正文内、后面还有同级 headline 时返回下一个 headline 起点之前."
  (seshat-reader-reference-test--with-org-buffer "* 第一章\n正文一\n* 第二章\n正文二\n"
    (search-forward "正文一")
    (let ((expected (save-excursion
                      (goto-char (point-min))
                      (search-forward "* 第二章")
                      (match-beginning 0))))
      (should (= (seshat-reader-reference--insert-position 'headline)
                 expected))
      ;; 边界：插入点之前不应包含第二个 headline，之后不应包含第一段正文
      (should (eq (char-after expected) ?*)))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-nested-subtree ()
  "嵌套子标题属于当前子树 → 返回整个子树末尾（子标题之后）."
  (seshat-reader-reference-test--with-org-buffer "* 甲\n正文甲\n** 甲子\n正文子\n* 乙\n正文乙\n"
    (search-forward "正文甲")
    (let ((expected (save-excursion
                      (goto-char (point-min))
                      (search-forward "* 乙")
                      (match-beginning 0))))
      (should (= (seshat-reader-reference--insert-position 'headline)
                 expected)))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-no-headline ()
  "buffer 内没有任何 headline 时回退 `(point-max)'."
  (seshat-reader-reference-test--with-org-buffer "只有正文，没有标题\n"
    (search-forward "正文")
    (should (= (seshat-reader-reference--insert-position 'headline)
               (point-max)))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-before-first ()
  "光标在第一个 headline 之前时回退 `(point-max)'."
  (seshat-reader-reference-test--with-org-buffer "前言\n* 第一章\n正文一\n"
    ;; point 在 point-min（第一个 headline 之前）
    (should (= (seshat-reader-reference--insert-position 'headline)
               (point-max)))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-without-org ()
  "org 不可用（`featurep' 桩为 nil）时 `headline' 回退 `(point-max)'."
  (with-temp-buffer
    (insert "* 第一章\n正文一\n* 第二章\n正文二\n")
    (goto-char (point-min))
    (search-forward "正文一")
    (cl-letf (((symbol-function 'featurep)
               (lambda (&rest _) nil)))
      (should (= (seshat-reader-reference--insert-position 'headline)
                 (point-max))))))

(ert-deftest seshat-reader-reference-test--insert-position-headline-non-org-buffer ()
  "org 已加载但 buffer 不是 org-mode 时 `headline' 回退 `(point-max)'."
  (skip-unless (require 'org nil t))
  ;; fundamental-mode 下星号行只是普通文本，不是 headline：不得按 org 规则解析
  (with-temp-buffer
    (insert "* 不是标题\n正文\n* 也不是标题\n")
    (goto-char (point-min))
    (search-forward "正文")
    (should (featurep 'org))
    (should-not (derived-mode-p 'org-mode))
    (should (= (seshat-reader-reference--insert-position 'headline)
               (point-max)))))

;;; 插入位置接入写入函数（`--insert-into-file'）

(ert-deftest seshat-reader-reference-test--insert-into-file-headline-position ()
  "`insert-position' 为 `headline' 且目标有 visiting buffer 时插到子树末尾."
  (let ((file (make-temp-file "seshat-ref-insert-head-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* 第一章\n正文一\n* 第二章\n正文二\n"))
          (let ((buf (find-file-noselect file))
                (seshat-reader-reference-insert-position 'headline))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-min))
                  (search-forward "正文一")
                  (seshat-reader-reference--insert-into-file "插入块" file))
              (kill-buffer buf)))
          (let ((content (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))))
            ;; 插在第一章正文之后、第二个 headline 之前
            (should (string-match-p "正文一\n插入块\n\\* 第二章" content))
            (should-not (string-match-p "正文二\n插入块" content))))
      (delete-file file))))

(ert-deftest seshat-reader-reference-test--insert-into-file-point-mode-no-buffer ()
  "`point' 模式但目标无 visiting buffer 时回退 `append-to-file'（不动用其它 buffer）."
  (let ((file (make-temp-file "seshat-ref-insert-point-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "既有\n"))
          (should-not (find-buffer-visiting file))
          (let ((seshat-reader-reference-insert-position 'point))
            (seshat-reader-reference--insert-into-file "追加" file))
          (should-not (find-buffer-visiting file))
          (should (equal (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "既有\n追加\n")))
      (delete-file file))))

;;; uid 形态（M8-C T3a：解析 + 构造 + 身份入口 + 零网络路径解析）

(defconst seshat-reader-reference-test--uid "01J8ZKQ2ABCDEFGHJKMNPQRSTV"
  "测试用合法 uid：26 位 Crockford Base32（排除 I / L / O / U）.")

(ert-deftest seshat-reader-reference-test--parse-link-uid-form ()
  "`uid:' + 合法 26 位串判为 uid 形态：`:uid' 为该串、`:doc-id' 为 nil.
`:uid' / `:doc-id' / `:location' 三个键始终存在，便于调用方统一 `plist-get'。"
  (let ((parsed (seshat-reader-reference--parse-link
                 (concat "seshat:uid:" seshat-reader-reference-test--uid))))
    (should (plist-member parsed :uid))
    (should (plist-member parsed :doc-id))
    (should (plist-member parsed :location))
    (should (equal (plist-get parsed :uid) seshat-reader-reference-test--uid))
    (should-not (plist-get parsed :doc-id))
    (should-not (plist-get parsed :location)))
  ;; 允许缺 `seshat:' 前缀（与 doc-id 形态一致）
  (should (equal (plist-get (seshat-reader-reference--parse-link
                             (concat "uid:" seshat-reader-reference-test--uid))
                            :uid)
                 seshat-reader-reference-test--uid)))

(ert-deftest seshat-reader-reference-test--parse-link-uid-with-location ()
  "`uid:<合法>#page:3' 的 location 为 \"page:3\"，rect 尾段完整保留."
  (let ((parsed (seshat-reader-reference--parse-link
                 (concat "seshat:uid:" seshat-reader-reference-test--uid
                         "#page:3"))))
    (should (equal (plist-get parsed :uid) seshat-reader-reference-test--uid))
    (should-not (plist-get parsed :doc-id))
    (should (equal (plist-get parsed :location) "page:3")))
  (should (equal
           (plist-get
            (seshat-reader-reference--parse-link
             (concat "seshat:uid:" seshat-reader-reference-test--uid
                     "#page:112;rect:50.00,100.00,545.00,140.00"))
            :location)
           "page:112;rect:50.00,100.00,545.00,140.00")))

(ert-deftest seshat-reader-reference-test--parse-link-uid-trailing-hash ()
  "`uid:<合法>#'（尾部空 location）归一为 nil，uid 仍解析成功."
  (let ((parsed (seshat-reader-reference--parse-link
                 (concat "seshat:uid:" seshat-reader-reference-test--uid "#"))))
    (should (equal (plist-get parsed :uid) seshat-reader-reference-test--uid))
    (should-not (plist-get parsed :doc-id))
    (should (plist-member parsed :location))
    (should-not (plist-get parsed :location))))

(ert-deftest seshat-reader-reference-test--parse-link-uid-empty-falls-back ()
  "`uid:' 后为空串时回落 doc-id 形态（`:uid' 为 nil、`:doc-id' 为原文）."
  (dolist (link '("seshat:uid:" "uid:"))
    (let ((parsed (seshat-reader-reference--parse-link link)))
      (should (plist-member parsed :uid))
      (should-not (plist-get parsed :uid))
      (should (equal (plist-get parsed :doc-id) "uid:"))
      (should-not (plist-get parsed :location))))
  ;; 带 location 的空 uid 同样回落，location 按既有规则解析
  (let ((parsed (seshat-reader-reference--parse-link "seshat:uid:#page:3")))
    (should-not (plist-get parsed :uid))
    (should (equal (plist-get parsed :doc-id) "uid:"))
    (should (equal (plist-get parsed :location) "page:3"))))

(ert-deftest seshat-reader-reference-test--parse-link-uid-wrong-length-falls-back ()
  "`uid:' 后长度非 26（25 / 27 位）时回落 doc-id 形态."
  (should (= 26 (length seshat-reader-reference-test--uid)))
  (dolist (uid (list (substring seshat-reader-reference-test--uid 0 25)
                     (concat seshat-reader-reference-test--uid "V")))
    (should (/= 26 (length uid)))
    (let ((parsed (seshat-reader-reference--parse-link
                   (concat "seshat:uid:" uid "#page:5"))))
      (should-not (plist-get parsed :uid))
      (should (equal (plist-get parsed :doc-id) (concat "uid:" uid)))
      (should (equal (plist-get parsed :location) "page:5")))))

(ert-deftest seshat-reader-reference-test--parse-link-uid-lowercase-falls-back ()
  "`uid:' 后含小写字母时回落 doc-id 形态."
  (let ((uid (downcase seshat-reader-reference-test--uid)))
    (should (= 26 (length uid)))
    (should (string-match-p "[a-z]" uid))
    (let ((parsed (seshat-reader-reference--parse-link
                   (concat "seshat:uid:" uid))))
      (should-not (plist-get parsed :uid))
      (should (equal (plist-get parsed :doc-id) (concat "uid:" uid))))))

(ert-deftest seshat-reader-reference-test--parse-link-uid-excluded-letters-falls-back ()
  "`uid:' 后是含 I / L / O / U 的 26 位串时回落 doc-id 形态.
uid 的权威字符集是 Crockford Base32 `[0-9A-HJKMNP-TV-Z]'（排除 I/L/O/U），
不是 `[0-9A-Z]'（见服务端 `internal/registry/uid.go:29'）。"
  (dolist (uid '("01J8ZKQ2ABCDEFGHIJKLMNOPQR"   ; 含 I / L / O
                 "01J8ZKQ2ABCDEFGHJKMNPQRSTU"))  ; 含 U
    (should (= 26 (length uid)))
    (should (string-match-p "[ILOU]" uid))
    (let ((parsed (seshat-reader-reference--parse-link
                   (concat "seshat:uid:" uid))))
      (should-not (plist-get parsed :uid))
      (should (equal (plist-get parsed :doc-id) (concat "uid:" uid))))))

(ert-deftest seshat-reader-reference-test--parse-link-doc-id-forms-unchanged ()
  "回归：`tag:path' / `local:' / 根 tag 名为 `uid' 的形态语义逐字不变.
**不得**用整体 `equal' 断言 plist——新增 `:uid' 键后结构必然变化，只断言
`:doc-id' 与 `:location' 的键值语义不变。"
  (let ((parsed (seshat-reader-reference--parse-link "seshat:books:a.pdf")))
    (should (plist-member parsed :uid))
    (should-not (plist-get parsed :uid))
    (should (equal (plist-get parsed :doc-id) "books:a.pdf"))
    (should-not (plist-get parsed :location)))
  (let ((parsed (seshat-reader-reference--parse-link
                 "seshat:books:a.pdf#page:7")))
    (should-not (plist-get parsed :uid))
    (should (equal (plist-get parsed :doc-id) "books:a.pdf"))
    (should (equal (plist-get parsed :location) "page:7")))
  (let ((parsed (seshat-reader-reference--parse-link "seshat:local:/abs/x.pdf")))
    (should-not (plist-get parsed :uid))
    (should (equal (plist-get parsed :doc-id) "local:/abs/x.pdf"))
    (should-not (plist-get parsed :location)))
  (let ((parsed (seshat-reader-reference--parse-link
                 "seshat:local:/abs/x.pdf#page:2;rect:1.00,2.00,3.00,4.00")))
    (should-not (plist-get parsed :uid))
    (should (equal (plist-get parsed :doc-id) "local:/abs/x.pdf"))
    (should (equal (plist-get parsed :location)
                   "page:2;rect:1.00,2.00,3.00,4.00")))
  ;; 根 tag 叫 `uid' 时 `uid:foo.pdf' 仍是 doc-id 形态（不误判）
  (let ((parsed (seshat-reader-reference--parse-link "seshat:uid:foo.pdf")))
    (should-not (plist-get parsed :uid))
    (should (equal (plist-get parsed :doc-id) "uid:foo.pdf"))
    (should-not (plist-get parsed :location))))

(ert-deftest seshat-reader-reference-test--uid-link-construction ()
  "`--uid-link' 构造 uid 形态：无 location 只给整篇链接，有 location 追加 `#<location>'."
  (let ((base (concat "seshat:uid:" seshat-reader-reference-test--uid)))
    (should (equal (seshat-reader-reference--uid-link
                    seshat-reader-reference-test--uid)
                   base))
    (should (equal (seshat-reader-reference--uid-link
                    seshat-reader-reference-test--uid nil)
                   base))
    (should (equal (seshat-reader-reference--uid-link
                    seshat-reader-reference-test--uid "")
                   base))
    (should (equal (seshat-reader-reference--uid-link
                    seshat-reader-reference-test--uid "page:3")
                   (concat base "#page:3"))))
  ;; 构造 → 解析往返
  (let ((parsed (seshat-reader-reference--parse-link
                 (seshat-reader-reference--uid-link
                  seshat-reader-reference-test--uid "page:9"))))
    (should (equal (plist-get parsed :uid) seshat-reader-reference-test--uid))
    (should-not (plist-get parsed :doc-id))
    (should (equal (plist-get parsed :location) "page:9"))))

(ert-deftest seshat-reader-reference-test--uid-link-rejects-illegal-uid ()
  "非法 uid 抛 `error'（编程错误，不是 `user-error'）."
  (dolist (bad (list nil
                     ""
                     "not-a-uid"
                     (substring seshat-reader-reference-test--uid 0 25)
                     "01J8ZKQ2ABCDEFGHIJKLMNOPQR"
                     (downcase seshat-reader-reference-test--uid)))
    (let ((err (should-error (seshat-reader-reference--uid-link bad))))
      (should (eq (car err) 'error)))))

(ert-deftest seshat-reader-reference-test--identity-nil-doc-id ()
  "DOC-ID 为 nil 或非字符串时返回 `(:doc-id nil)'（调用方据此什么都不产）."
  (should (equal (seshat-reader-reference--identity nil) (list :doc-id nil)))
  (should (equal (seshat-reader-reference--identity 42) (list :doc-id nil)))
  (should (equal (seshat-reader-reference--identity 'sym) (list :doc-id nil))))

(ert-deftest seshat-reader-reference-test--identity-returns-uid ()
  "软依赖 `seshat-state-uid-for-path' 查到 uid 时返回 `(:uid ...)'，实参为 `(TAG REL)'."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "ebook" dir)))
           (asked nil))
      (with-temp-file file)
      (cl-letf (((symbol-function 'seshat-state-uid-for-path)
                 (lambda (root path)
                   (setq asked (cons root path))
                   seshat-reader-reference-test--uid)))
        (should (equal (seshat-reader-reference--identity "ebook:book.pdf")
                       (list :uid seshat-reader-reference-test--uid))))
      (should (equal asked (cons "ebook" "book.pdf"))))))

(ert-deftest seshat-reader-reference-test--identity-falls-back-to-doc-id ()
  "软依赖查不到 uid（返回 nil）时回落 `(:doc-id DOC)'."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "ebook" dir))))
      (with-temp-file file)
      (cl-letf (((symbol-function 'seshat-state-uid-for-path)
                 (lambda (&rest _) nil)))
        (should (equal (seshat-reader-reference--identity "ebook:book.pdf")
                       (list :doc-id "ebook:book.pdf")))))))

(ert-deftest seshat-reader-reference-test--identity-without-state-module ()
  "软依赖 `seshat-state' 缺失（`fboundp' 为 nil）时回落 `(:doc-id ...)' 且不报错."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "ebook" dir)))
           (orig (symbol-function 'fboundp)))
      (with-temp-file file)
      (cl-letf (((symbol-function 'fboundp)
                 (lambda (sym)
                   (and (not (eq sym 'seshat-state-uid-for-path))
                        (funcall orig sym)))))
        (should (equal (seshat-reader-reference--identity "ebook:book.pdf")
                       (list :doc-id "ebook:book.pdf")))))))

(ert-deftest seshat-reader-reference-test--identity-outside-roots ()
  "不在任何已配置根下（`local:' 降级 doc-id 且无根命中）时回落 `(:doc-id ...)'."
  (let ((seshat-reader-annotation-roots nil))
    (should (equal (seshat-reader-reference--identity "local:/abs/x.pdf")
                   (list :doc-id "local:/abs/x.pdf")))
    (should (equal (seshat-reader-reference--identity "ghost:x.pdf")
                   (list :doc-id "ghost:x.pdf")))))

(ert-deftest seshat-reader-reference-test--file-from-uid-hit ()
  "state 命中且根的 DIR 已配置时经 `seshat-sync--local-path' 拼出绝对路径（零网络）."
  (seshat-reader-reference-test--with-temp-dir dir
    (let ((seshat-reader-annotation-roots nil)
          (asked nil))
      (cl-letf (((symbol-function 'seshat-state-path-for-uid)
                 (lambda (uid)
                   (and (equal uid seshat-reader-reference-test--uid)
                        (cons "ebook" "sub/book.pdf"))))
                ((symbol-function 'seshat-state-roots)
                 (lambda () (list (list "ebook" dir "mirror"))))
                ((symbol-function 'seshat-sync--local-path)
                 (lambda (root-dir path)
                   (setq asked (cons root-dir path))
                   (expand-file-name path root-dir))))
        (should (equal (seshat-reader-reference--file-from-uid
                        seshat-reader-reference-test--uid)
                       (expand-file-name "sub/book.pdf" dir))))
      ;; 传给 sync 层的是「带结尾斜杠的根目录」
      (should (equal asked (cons (file-name-as-directory
                                  (expand-file-name dir))
                                 "sub/book.pdf"))))))

(ert-deftest seshat-reader-reference-test--file-from-uid-without-sync-module ()
  "软依赖 `seshat-sync--local-path' 缺失时**不再**回落弱校验：一律返回 nil 并
`display-warning' 一次（安全优先——自写的前缀比较缺 `file-truename' 双校验，
且 `path' 为 \".\" 时会返回根目录本身）。"
  (seshat-reader-reference-test--with-temp-dir dir
    (let ((orig (symbol-function 'fboundp))
          (warnings nil)
          (seshat-reader-reference--uid-path-warned nil))
      (cl-letf (((symbol-function 'seshat-state-path-for-uid)
                 (lambda (&rest _) (cons "ebook" "sub/book.pdf")))
                ((symbol-function 'seshat-state-roots)
                 (lambda () (list (list "ebook" dir "mirror"))))
                ((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings) nil))
                ((symbol-function 'fboundp)
                 (lambda (sym)
                   (and (not (eq sym 'seshat-sync--local-path))
                        (funcall orig sym)))))
        ;; 合法路径同样返回 nil：无法安全校验就不解析
        (should-not (seshat-reader-reference--file-from-uid
                     seshat-reader-reference-test--uid))
        (should (= 1 (length warnings)))
        ;; 幂等：第二次不再刷警告
        (should-not (seshat-reader-reference--file-from-uid
                     seshat-reader-reference-test--uid))
        (should (= 1 (length warnings)))
        ;; 越界 / 绝对路径 / `~' 前缀一并返回 nil（且不再重复警告）
        (dolist (bad '("../../etc/passwd" "/etc/passwd" "~/x.pdf" "."))
          (cl-letf (((symbol-function 'seshat-state-path-for-uid)
                     (lambda (&rest _) (cons "ebook" bad))))
            (should-not (seshat-reader-reference--file-from-uid
                         seshat-reader-reference-test--uid))))
        (should (= 1 (length warnings)))))))

(ert-deftest seshat-reader-reference-test--file-from-uid-misses ()
  "未登记 / 根 DIR 未配置 / uid 非法时返回 nil，不抛错."
  ;; 未登记
  (cl-letf (((symbol-function 'seshat-state-path-for-uid)
             (lambda (&rest _) nil)))
    (should-not (seshat-reader-reference--file-from-uid
                 seshat-reader-reference-test--uid)))
  ;; 已登记但根不在 `seshat-state-roots' 里 / DIR 为空串
  (dolist (roots (list nil (list (list "ebook" "" "mirror"))))
    (cl-letf (((symbol-function 'seshat-state-path-for-uid)
               (lambda (&rest _) (cons "ebook" "book.pdf")))
              ((symbol-function 'seshat-state-roots) (lambda () roots)))
      (should-not (seshat-reader-reference--file-from-uid
                   seshat-reader-reference-test--uid))))
  ;; uid 非字符串 / 空串
  (should-not (seshat-reader-reference--file-from-uid nil))
  (should-not (seshat-reader-reference--file-from-uid "")))

(ert-deftest seshat-reader-reference-test--file-from-uid-without-state-module ()
  "软依赖 `seshat-state' 缺失（`fboundp' 为 nil）时返回 nil，不抛错."
  (let ((orig (symbol-function 'fboundp)))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (and (not (memq sym '(seshat-state-path-for-uid
                                       seshat-state-roots)))
                      (funcall orig sym)))))
      (should-not (seshat-reader-reference--file-from-uid
                   seshat-reader-reference-test--uid)))))

;;; T3b：uid 形态接入全部插入与导出路径

(defconst seshat-reader-reference-test--short-uid "01J8ZKQ2ABCDEFGH"
  "测试用「不足 26 位」的 uid 串.
用于断言描述回落标识 `uid:<前 8 位>…'；它不是权威 uid 形态（26 位），因此只能
出现在 `--description' / `:export' 的**宽松 uid 识别**路径上（doc-id 必含
`:'，故不含 `:' 的 Crockford Base32 串一律按 uid 处理）。")

(defconst seshat-reader-reference-test--uid-expected-label "uid:01J8ZKQ2…"
  "权威测试 uid 与短 uid 共同的回落标识（两者前 8 位相同：`01J8ZKQ2'）.")

;;; `--link-for'：统一链接构造入口

(ert-deftest seshat-reader-reference-test--link-for-uid-form ()
  "`--identity' 给出 uid 时 `--link-for' 产 uid 形态（带 / 不带 location）."
  (cl-letf (((symbol-function 'seshat-reader-reference--identity)
             (lambda (doc-id)
               (should (equal doc-id "ebook:a.pdf"))
               (list :uid seshat-reader-reference-test--uid))))
    (let ((base (concat "seshat:uid:" seshat-reader-reference-test--uid)))
      (should (equal (seshat-reader-reference--link-for "ebook:a.pdf") base))
      (should (equal (seshat-reader-reference--link-for "ebook:a.pdf" nil) base))
      (should (equal (seshat-reader-reference--link-for "ebook:a.pdf" "") base))
      (should (equal (seshat-reader-reference--link-for "ebook:a.pdf" "page:3")
                     (concat base "#page:3"))))))

(ert-deftest seshat-reader-reference-test--link-for-doc-id-fallback ()
  "`--identity' 给出 doc-id 时回落 doc-id 形态；DOC-ID 为 nil 时返回 nil."
  (cl-letf (((symbol-function 'seshat-reader-reference--identity)
             (lambda (doc-id)
               (if (stringp doc-id)
                   (list :doc-id doc-id)
                 (list :doc-id nil)))))
    (should (equal (seshat-reader-reference--link-for "ebook:a.pdf")
                   "seshat:ebook:a.pdf"))
    (should (equal (seshat-reader-reference--link-for "ebook:a.pdf" "page:3")
                   "seshat:ebook:a.pdf#page:3"))
    ;; nil doc-id 不产链接（不报错、不产空链接）
    (should-not (seshat-reader-reference--link-for nil))
    (should-not (seshat-reader-reference--link-for nil "page:3"))))

(ert-deftest seshat-reader-reference-test--link-for-real-identity-uid ()
  "真实 `--identity' 查到 uid 时 `--link-for' 产 uid 形态（端到端，零网络）."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "ebook" dir))))
      (with-temp-file file)
      (cl-letf (((symbol-function 'seshat-state-uid-for-path)
                 (lambda (&rest _) seshat-reader-reference-test--uid)))
        (should (equal (seshat-reader-reference--link-for
                        "ebook:book.pdf" "page:7")
                       (concat "seshat:uid:" seshat-reader-reference-test--uid
                               "#page:7")))))))

(ert-deftest seshat-reader-reference-test--link-for-without-state-module ()
  "软依赖 `seshat-state' 缺失时自动回落 doc-id 形态，不报错（设计行为）."
  (seshat-reader-reference-test--with-temp-dir dir
    (let* ((file (expand-file-name "book.pdf" dir))
           (seshat-reader-annotation-roots (list (cons "ebook" dir)))
           (orig (symbol-function 'fboundp)))
      (with-temp-file file)
      (cl-letf (((symbol-function 'fboundp)
                 (lambda (sym)
                   (and (not (eq sym 'seshat-state-uid-for-path))
                        (funcall orig sym)))))
        (should (equal (seshat-reader-reference--link-for "ebook:book.pdf")
                       "seshat:ebook:book.pdf"))))))

;;; `:store'（org-store-link）

(defmacro seshat-reader-reference-test--with-store-capture (&rest body)
  "在阅读器 buffer 中执行 BODY，返回 `org-link-store-props' 捕获到的 plist.
阅读器 buffer 用临时空 PDF 作 `buffer-file-name'，doc-id / 页码 / 身份都由
桩给（BODY 内自行 `cl-letf' 身份入口）。"
  (declare (indent 0) (debug t))
  `(let ((file (seshat-reader-reference-test--temp-pdf))
         (captured nil))
     (unwind-protect
         (progn
           (with-temp-buffer
             (setq major-mode 'seshat-reader-mode)
             (setq buffer-file-name file)
             (let ((seshat-reader-select-last nil))
               (cl-letf (((symbol-function 'seshat-reader-annotation--doc-id)
                          (lambda (&rest _) "ebook:a.pdf"))
                         ((symbol-function 'seshat-reader-annotation--quiet-p)
                          (lambda (&rest _) t))
                         ((symbol-function 'seshat-reader-current-doc-pagenumber)
                          (lambda (&optional _window) 3))
                         ((symbol-function 'org-link-store-props)
                          (lambda (&rest plist) (setq captured plist))))
                 ,@body)))
           captured)
       (delete-file file))))

(ert-deftest seshat-reader-reference-test--store-link-uid-form ()
  "能查到 uid 时 `org-store-link' 存的是 uid 形态链接，描述仍可读."
  (let ((props (seshat-reader-reference-test--with-store-capture
                 (cl-letf (((symbol-function 'seshat-reader-reference--identity)
                            (lambda (&rest _)
                              (list :uid seshat-reader-reference-test--uid))))
                   (should (seshat-reader-reference-store-link))))))
    (should (equal (plist-get props :type) "seshat"))
    (should (equal (plist-get props :link)
                   (concat "seshat:uid:" seshat-reader-reference-test--uid
                           "#page:3")))
    (should (equal (plist-get props :description) "a.pdf 第 3 页"))))

(ert-deftest seshat-reader-reference-test--store-link-doc-id-fallback ()
  "查不到 uid 时 `org-store-link' 回落 doc-id 形态（回归）."
  (let ((props (seshat-reader-reference-test--with-store-capture
                 (cl-letf (((symbol-function 'seshat-reader-reference--identity)
                            (lambda (doc-id) (list :doc-id doc-id))))
                   (should (seshat-reader-reference-store-link))))))
    (should (equal (plist-get props :link) "seshat:ebook:a.pdf#page:3"))
    (should (equal (plist-get props :description) "a.pdf 第 3 页"))))

;;; 摘录（`insert'，经 `--format-block'）

(ert-deftest seshat-reader-reference-test--insert-uid-form ()
  "能查到 uid 时摘录块里的链接为 uid 形态（`--format-block' 经 `--link-for'）."
  (let ((file (seshat-reader-reference-test--temp-pdf))
        (target (make-temp-file "seshat-ref-ins-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq major-mode 'seshat-reader-mode)
            (setq buffer-file-name file)
            (let ((seshat-reader-select-last nil)
                  (seshat-reader-reference-target-file target))
              (cl-letf (((symbol-function 'seshat-reader-annotation--doc-id)
                         (lambda (&rest _) "ebook:a.pdf"))
                        ((symbol-function 'seshat-reader-annotation--quiet-p)
                         (lambda (&rest _) t))
                        ((symbol-function 'seshat-reader-current-doc-pagenumber)
                         (lambda (&optional _window) 3))
                        ((symbol-function 'seshat-reader-reference--identity)
                         (lambda (&rest _)
                           (list :uid seshat-reader-reference-test--uid))))
                (seshat-reader-reference-insert))))
          (let ((content (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))))
            (should (string-match-p
                     (regexp-quote
                      (concat "[[" "seshat:uid:"
                              seshat-reader-reference-test--uid
                              "#page:3" "][" "a.pdf 第 3 页" "]]"))
                     content))))
      (delete-file file)
      (delete-file target))))

;;; 批注引用（`insert-annotation'）

(ert-deftest seshat-reader-reference-test--insert-annotation-uid-form ()
  "能查到 uid 时批注引用的链接为 uid 形态（经 `--format-block'）."
  (let ((target (make-temp-file "seshat-ref-ann-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq major-mode 'seshat-reader-annotation-list-mode)
            (insert "批注正文")
            (add-text-properties
             (point-min) (point-max)
             '(seshat-reader-annotation-id 7
               seshat-reader-annotation-location "page:3"
               seshat-reader-annotation-page 3))
            (let ((seshat-reader-annotation-list-document-id "ebook:a.pdf")
                  (seshat-reader-annotation-list-entries
                   '(((id . 7) (text . "批注正文"))))
                  (seshat-reader-reference-target-file target))
              (cl-letf (((symbol-function 'seshat-reader-reference--identity)
                         (lambda (&rest _)
                           (list :uid seshat-reader-reference-test--uid))))
                (seshat-reader-reference-insert-annotation))))
          (let ((content (with-temp-buffer
                           (insert-file-contents target)
                           (buffer-string))))
            (should (string-match-p (regexp-quote "批注正文") content))
            (should (string-match-p
                     (regexp-quote
                      (concat "seshat:uid:" seshat-reader-reference-test--uid
                              "#page:3"))
                     content))
            (should-not (string-match-p "seshat:ebook:" content))))
      (delete-file target))))

;;; copy-link

(defun seshat-reader-reference-test--copy-link-with (identity)
  "以桩身份 IDENTITY 调用 `seshat-reader-reference-copy-link'，返回复制内容."
  (let ((killed nil))
    (cl-letf (((symbol-function 'seshat-reader-reference--current-doc-id)
               (lambda () "ebook:a.pdf"))
              ((symbol-function 'seshat-reader-reference--current-location)
               (lambda () "page:3"))
              ((symbol-function 'seshat-reader-reference--identity)
               (lambda (&rest _) identity))
              ((symbol-function 'kill-new)
               (lambda (string) (setq killed string))))
      (seshat-reader-reference-copy-link))
    killed))

(ert-deftest seshat-reader-reference-test--copy-link-uid-form ()
  "能查到 uid 时 copy-link 复制 uid 形态链接."
  (should (equal (seshat-reader-reference-test--copy-link-with
                  (list :uid seshat-reader-reference-test--uid))
                 (concat "seshat:uid:" seshat-reader-reference-test--uid
                         "#page:3"))))

(ert-deftest seshat-reader-reference-test--copy-link-doc-id-fallback ()
  "查不到 uid 时 copy-link 复制 doc-id 形态链接（回归）."
  (should (equal (seshat-reader-reference-test--copy-link-with
                  (list :doc-id "ebook:a.pdf"))
                 "seshat:ebook:a.pdf#page:3")))

;;; `--description'：uid 形态 / 未知文档

(ert-deftest seshat-reader-reference-test--description-uid-with-local-file ()
  "uid 形态且本地可解析时描述为「文件名 + 页号」（零网络）。"
  (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
             (lambda (uid)
               (and (equal uid seshat-reader-reference-test--uid)
                    "/lib/ebook/a.pdf"))))
    (should (equal (seshat-reader-reference--description
                    seshat-reader-reference-test--uid "page:3")
                   "a.pdf 第 3 页"))
    (should (equal (seshat-reader-reference--description
                    seshat-reader-reference-test--uid)
                   "a.pdf"))))

(ert-deftest seshat-reader-reference-test--description-uid-without-file ()
  "uid 形态但本地取不到路径时回落逐字 `uid:<前 8 位>…'（不得为空串）。"
  (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
             (lambda (&rest _) nil)))
    ;; 权威 26 位 uid
    (should (equal (seshat-reader-reference--description
                    seshat-reader-reference-test--uid)
                   seshat-reader-reference-test--uid-expected-label))
    ;; 不足 26 位的短 uid（宽松识别路径）
    (should (equal (seshat-reader-reference--description
                    seshat-reader-reference-test--short-uid)
                   seshat-reader-reference-test--uid-expected-label))
    ;; 页号仍照旧拼接
    (should (equal (seshat-reader-reference--description
                    seshat-reader-reference-test--short-uid "page:5")
                   (concat seshat-reader-reference-test--uid-expected-label
                           " 第 5 页")))))

(ert-deftest seshat-reader-reference-test--description-uid-fallback-label ()
  "回落标识格式定死：长度 > 8 取前 8 位加省略号，≤ 8 原样 `uid:<uid>'."
  (should (equal (seshat-reader-reference--uid-fallback-label
                  "01J8ZKQ2ABCDEFGH")
                 "uid:01J8ZKQ2…"))
  (should (equal (seshat-reader-reference--uid-fallback-label "ABCDEFGH")
                 "uid:ABCDEFGH"))
  (should (equal (seshat-reader-reference--uid-fallback-label "ABCDE")
                 "uid:ABCDE"))
  (should (equal (seshat-reader-reference--uid-fallback-label
                  seshat-reader-reference-test--uid)
                 seshat-reader-reference-test--uid-expected-label)))

(ert-deftest seshat-reader-reference-test--description-unknown-doc-not-empty ()
  "DOC-ID 为 nil / 空串 / 非字符串时返回非空占位串，绝不返回空串."
  (dolist (doc-id (list nil "" 42 'sym))
    (let ((desc (seshat-reader-reference--description doc-id)))
      (should (stringp desc))
      (should (not (string-empty-p desc)))
      (should (equal desc "（未知文档）")))
    (should (equal (seshat-reader-reference--description doc-id "page:2")
                   "（未知文档） 第 2 页")))
  ;; 既有 doc-id 形态的描述逐字不变（回归）
  (should (equal (seshat-reader-reference--description "ebook:a.pdf" "page:3")
                 "a.pdf 第 3 页"))
  (should (equal (seshat-reader-reference--description "local:/abs/x.pdf")
                 "x.pdf")))

;;; `:export'

(ert-deftest seshat-reader-reference-test--export-link-uid-form ()
  "`:export' 对 uid 形态输出「文件名 第 N 页」，所有后端一致."
  (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
             (lambda (&rest _) "/lib/ebook/a.pdf")))
    (dolist (format '(html latex ascii md nil))
      (should (equal (seshat-reader-reference-export-link
                      (concat "seshat:uid:" seshat-reader-reference-test--uid
                              "#page:3")
                      nil format)
                     "a.pdf 第 3 页"))
      ;; 无 location 时只给文件名
      (should (equal (seshat-reader-reference-export-link
                      (concat "seshat:uid:" seshat-reader-reference-test--uid)
                      nil format)
                     "a.pdf")))
    ;; 有 DESC 时优先用 DESC（org 语义不变）
    (should (equal (seshat-reader-reference-export-link
                    (concat "seshat:uid:" seshat-reader-reference-test--uid
                            "#page:3")
                    "我的描述" 'html)
                   "我的描述"))))

(ert-deftest seshat-reader-reference-test--export-link-uid-without-file ()
  "`:export' 在 uid 描述取不到时输出含 `uid:' 的非空文本（逐字断言回落格式）."
  (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
             (lambda (&rest _) nil)))
    (let ((out (seshat-reader-reference-export-link
                (concat "seshat:uid:" seshat-reader-reference-test--uid
                        "#page:5")
                nil 'html)))
      (should (stringp out))
      (should (not (string-empty-p out)))
      (should (string-match-p "uid:" out))
      (should (equal out (concat seshat-reader-reference-test--uid-expected-label
                                 " 第 5 页"))))
    ;; 无 location 的纯回落
    (should (equal (seshat-reader-reference-export-link
                    (concat "seshat:uid:" seshat-reader-reference-test--uid)
                    nil 'latex)
                   seshat-reader-reference-test--uid-expected-label))
    ;; 不足 26 位的 `uid:' **链接**按 doc-id 形态解析（`--parse-link' 的判别
    ;; 不放宽，否则根标签名为 `uid' 的 doc-id 会被误判），因此走 doc-id 分支
    (should (equal (seshat-reader-reference-export-link
                    (concat "seshat:uid:"
                            seshat-reader-reference-test--short-uid)
                    nil 'latex)
                   seshat-reader-reference-test--short-uid))))

;;; `:complete' 保持 doc-id 形态（回归）

(ert-deftest seshat-reader-reference-test--complete-stays-doc-id ()
  ":complete 的候选与产物仍是 doc-id 形态（不产 uid、不经身份入口）."
  (cl-letf (((symbol-function 'seshat-reader-reference--complete-link)
             (lambda () '("ebook:a.pdf")))
            ((symbol-function 'completing-read)
             (lambda (&rest _) "ebook:a.pdf"))
            ((symbol-function 'seshat-reader-reference--identity)
             (lambda (&rest _)
               (ert-fail ":complete 不应经 `--identity' 决定形态"))))
    (should (equal (seshat-reader-reference-complete-link)
                   "seshat:ebook:a.pdf"))))

;;; T4：`:follow' 的按需下载链

;; 全部用例都把「打开」「跳页」「身份解析」「取书」四个副作用入口桩替，
;; 只用 `make-temp-file' 造真实空文件通过存在性检查，不碰用户真实文件、不触网。
;; 「软依赖可用」这一态由 `cl-letf' 绑定 `(symbol-function 'seshat-library-fetch)'
;; 促成——绑上后 `fboundp' 自然为 t，与实现里的 `fboundp' + `funcall' 口径一致；
;; 「软依赖缺失」态则把 `fboundp' 桩为对该符号返回 nil。

(ert-deftest seshat-reader-reference-test--follow-uid-opens-local-file ()
  "uid 形态：本地有副本时直接打开该路径，**不**调用 `seshat-library-fetch'."
  (let ((file (seshat-reader-reference-test--temp-pdf))
        (opened nil)
        (fetch-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
                   (lambda (uid)
                     (should (equal uid seshat-reader-reference-test--uid))
                     file))
                  ((symbol-function 'seshat-library-fetch)
                   (lambda (&rest _) (cl-incf fetch-calls) nil))
                  ((symbol-function 'find-buffer-visiting)
                   (lambda (&rest _) nil))
                  ((symbol-function 'seshat-reader-open-doc)
                   (lambda (doc) (setq opened doc)))
                  ((symbol-function 'seshat-reader-goto-page)
                   (lambda (&rest _) (ert-fail "无 location 的链接不应跳页"))))
          (seshat-reader-reference-open
           (concat "seshat:uid:" seshat-reader-reference-test--uid)))
      (delete-file file))
    (should (equal opened file))
    (should (= fetch-calls 0))))

(ert-deftest seshat-reader-reference-test--follow-uid-downloads-when-unregistered ()
  "uid 形态：本地查不到路径（`--file-from-uid' 返回 nil）时按需下载并用其返回路径打开."
  (let ((file (seshat-reader-reference-test--temp-pdf))
        (opened nil)
        (fetch-uid nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
                   (lambda (&rest _) nil))
                  ((symbol-function 'seshat-library-fetch)
                   (lambda (uid &optional _force)
                     (setq fetch-uid uid)
                     file))
                  ((symbol-function 'find-buffer-visiting)
                   (lambda (&rest _) nil))
                  ((symbol-function 'seshat-reader-open-doc)
                   (lambda (doc) (setq opened doc)))
                  ((symbol-function 'seshat-reader-goto-page)
                   (lambda (&rest _) (ert-fail "无 location 的链接不应跳页"))))
          (seshat-reader-reference-open
           (concat "seshat:uid:" seshat-reader-reference-test--uid)))
      (delete-file file))
    ;; 实参必须就是链接里的 uid（不是 doc-id、不是派生值）
    (should (equal fetch-uid seshat-reader-reference-test--uid))
    (should (equal opened file))))

(ert-deftest seshat-reader-reference-test--follow-uid-missing-file-downloads ()
  "uid 形态：`--file-from-uid' 给出的路径**不存在**时同样按需下载."
  (let ((ghost (expand-file-name
                (format "seshat-ref-t4-ghost-%d.pdf" (abs (random 1000000)))
                temporary-file-directory))
        (file (seshat-reader-reference-test--temp-pdf))
        (opened nil)
        (fetch-calls 0))
    (unwind-protect
        (progn
          (should-not (file-exists-p ghost))
          (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
                     (lambda (&rest _) ghost))
                    ((symbol-function 'seshat-library-fetch)
                     (lambda (&rest _) (cl-incf fetch-calls) file))
                    ((symbol-function 'find-buffer-visiting)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-open-doc)
                     (lambda (doc) (setq opened doc)))
                    ((symbol-function 'seshat-reader-goto-page)
                     (lambda (&rest _) (ert-fail "无 location 的链接不应跳页"))))
            (seshat-reader-reference-open
             (concat "seshat:uid:" seshat-reader-reference-test--uid))))
      (delete-file file))
    (should (= fetch-calls 1))
    (should (equal opened file))))

(ert-deftest seshat-reader-reference-test--follow-uid-without-library-errors ()
  "uid 形态：本地无副本且软依赖缺失（`fboundp' 为 nil）时 `user-error'，取书桩 0 次调用."
  (let ((fetch-calls 0)
        (orig (symbol-function 'fboundp)))
    (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
               (lambda (&rest _) nil))
              ((symbol-function 'seshat-library-fetch)
               (lambda (&rest _) (cl-incf fetch-calls) "/nonexistent/x.pdf"))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (and (not (eq sym 'seshat-library-fetch))
                      (funcall orig sym))))
              ((symbol-function 'find-buffer-visiting)
               (lambda (&rest _) (ert-fail "失败路径不应查找 buffer")))
              ((symbol-function 'seshat-reader-open-doc)
               (lambda (&rest _) (ert-fail "失败路径不应打开文档"))))
      ;; 判据要能区分两条失败路径：缺依赖的消息必须点名 `seshat-library'
      (should (string-match-p
               "seshat-library"
               (error-message-string
                (should-error
                 (seshat-reader-reference-open
                  (concat "seshat:uid:" seshat-reader-reference-test--uid))
                 :type 'user-error)))))
    (should (= fetch-calls 0))))

(ert-deftest seshat-reader-reference-test--follow-uid-download-failure-errors ()
  "uid 形态：软依赖可用但返回 nil 时 `user-error'，且不打开任何文件."
  (let ((opened nil)
        (poped nil))
    (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
               (lambda (&rest _) nil))
              ((symbol-function 'seshat-library-fetch)
               (lambda (&rest _) nil))
              ((symbol-function 'find-buffer-visiting)
               (lambda (&rest _) nil))
              ((symbol-function 'pop-to-buffer)
               (lambda (buf &rest _) (setq poped buf) buf))
              ((symbol-function 'seshat-reader-open-doc)
               (lambda (doc) (setq opened doc))))
      ;; 取书失败与「缺依赖」都抛 `user-error'，用消息区分两条路径
      (should (string-match-p
               "取书失败"
               (error-message-string
                (should-error
                 (seshat-reader-reference-open
                  (concat "seshat:uid:" seshat-reader-reference-test--uid))
                 :type 'user-error)))))
    (should-not opened)
    (should-not poped)))

(ert-deftest seshat-reader-reference-test--follow-uid-goto-page ()
  "uid 形态带 `#page:3' 时打开后调用 `seshat-reader-goto-page'，实参为 3（不再加 1）."
  (let ((file (seshat-reader-reference-test--temp-pdf))
        (opened nil)
        (page-arg nil))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
                   (lambda (&rest _) file))
                  ((symbol-function 'seshat-library-fetch)
                   (lambda (&rest _) (ert-fail "本地有副本不应取书")))
                  ((symbol-function 'find-buffer-visiting)
                   (lambda (&rest _) nil))
                  ((symbol-function 'seshat-reader-open-doc)
                   (lambda (doc) (setq opened doc)))
                  ((symbol-function 'seshat-reader-goto-page)
                   (lambda (n) (setq page-arg n))))
          (seshat-reader-reference-open
           (concat "seshat:uid:" seshat-reader-reference-test--uid "#page:3")))
      (delete-file file))
    (should (equal opened file))
    (should (equal page-arg 3))))

(ert-deftest seshat-reader-reference-test--follow-doc-id-unchanged ()
  "回归：doc-id 形态仍走 `--file-from-doc-id'，不触发取书、不经 `--file-from-uid'."
  (let ((file (seshat-reader-reference-test--temp-pdf))
        (opened nil)
        (page-arg nil)
        (fetch-calls 0))
    (unwind-protect
        (let ((seshat-reader-annotation-roots
               (list (cons "ebook" (file-name-directory file)))))
          (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
                     (lambda (&rest _)
                       (ert-fail "doc-id 形态不应经 `--file-from-uid'")))
                    ((symbol-function 'seshat-library-fetch)
                     (lambda (&rest _) (cl-incf fetch-calls)))
                    ((symbol-function 'find-buffer-visiting)
                     (lambda (&rest _) nil))
                    ((symbol-function 'seshat-reader-open-doc)
                     (lambda (doc) (setq opened doc)))
                    ((symbol-function 'seshat-reader-goto-page)
                     (lambda (n) (setq page-arg n))))
            (seshat-reader-reference-open
             (concat "seshat:ebook:" (file-name-nondirectory file) "#page:2"))))
      (delete-file file))
    (should (equal opened (expand-file-name file)))
    (should (equal page-arg 2))
    (should (= fetch-calls 0))))

(ert-deftest seshat-reader-reference-test--follow-local-form-unchanged ()
  "回归：`local:' 形态仍按绝对路径直接打开，不触发取书."
  (let ((file (seshat-reader-reference-test--temp-pdf))
        (opened nil)
        (fetch-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'seshat-reader-reference--file-from-uid)
                   (lambda (&rest _)
                     (ert-fail "`local:' 形态不应经 `--file-from-uid'")))
                  ((symbol-function 'seshat-library-fetch)
                   (lambda (&rest _) (cl-incf fetch-calls)))
                  ((symbol-function 'find-buffer-visiting)
                   (lambda (&rest _) nil))
                  ((symbol-function 'seshat-reader-open-doc)
                   (lambda (doc) (setq opened doc)))
                  ((symbol-function 'seshat-reader-goto-page)
                   (lambda (&rest _) (ert-fail "无 location 的链接不应跳页"))))
          (seshat-reader-reference-open (concat "seshat:local:" file)))
      (delete-file file))
    (should (equal opened (expand-file-name file)))
    (should (= fetch-calls 0))))

(ert-deftest seshat-reader-reference-test--follow-malformed-uid-link-errors ()
  "畸形链接（`seshat:'）仍 `user-error'，且不因 uid 改造而误触发取书."
  (let ((fetch-calls 0))
    (cl-letf (((symbol-function 'seshat-library-fetch)
               (lambda (&rest _) (cl-incf fetch-calls) "/nonexistent/x.pdf"))
              ((symbol-function 'find-buffer-visiting)
               (lambda (&rest _) (ert-fail "失败路径不应查找 buffer")))
              ((symbol-function 'seshat-reader-open-doc)
               (lambda (&rest _) (ert-fail "失败路径不应打开文档"))))
      (should-error (seshat-reader-reference-open "seshat:") :type 'user-error))
    (should (= fetch-calls 0))))

(provide 'seshat-reader-reference-test)
;;; seshat-reader-reference-test.el ends here
