;;; seshat-reading-test.el --- ERT tests for seshat-reading  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, tests, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

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

;; `seshat-reading' 的 ERT 测试套件，覆盖两类契约：
;;
;; 1. T1（派生 mode 兼容）：`seshat-reading-mode' 作为 `seshat-reader-mode'
;;    的派生 mode，`derived-mode-p' 判定、`seshat-reader-dark-mode' /
;;    `seshat-reader-presentation-mode' 的守卫、以及批注高亮源校验
;;    （`seshat-reader-annotation--source-document-p'）都仍然成立；
;; 2. T2（库身份 + mode-line + auto-mode-alist 接管）：`--resolve' 的四态
;;    （`library' / `unregistered' / `external' / `broken'）、**零网络**、
;;    `broken' 优先于 `external'、mode-line 标识、`seshat-reading-refresh'
;;    的显式触网成功/失败两条路径，以及「reader 先注册、reading 后加载」
;;    时 `auto-mode-alist' 仍被接管且不产生重复项。
;;
;; 全部用例**不触网**（`seshat-rest--request' 被桩替并用
;; `seshat-reading-test--calls' 计数）、**不接触运行中的 Emacs**、不读写用户
;; 真实状态文件：每个用例都把 `seshat-state-file' 绑到临时目录里的
;; "sync-state.eld"，并把 `seshat-state--state' 绑为 nil 从空状态起步，结束
;; 递归删除临时目录。
;;
;; mode-line 断言**不**用 `format-mode-line'：batch 模式下它不求值 `:eval'
;; 条目（实测恒返回空串），因此用例直接求值 `:eval' 的载荷
;; （`seshat-reading--mode-line-text'），并断言条目确实装在
;; `mode-line-misc-info' 里。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'seshat-reading)
(require 'seshat-reader-annotation)

;; 只在一个用例里按需 `require' `seshat-sync'（它加载的模块较多），因此这里
;; 先声明函数，避免字节编译报「函数未定义」。
(declare-function seshat-sync-detect-renames "seshat-sync")

;;; 测试辅助

(defvar seshat-reading-test--dir nil
  "当前用例的临时目录（带结尾斜杠）.
由 `seshat-reading-test--with-env' 绑定。")

(defvar seshat-reading-test--root nil
  "当前用例的库根目录（带结尾斜杠，TAG 为 \"lib\"，MODE 为 \"mirror\"）.
由 `seshat-reading-test--with-env' 创建并绑定。")

(defvar seshat-reading-test--calls 0
  "`seshat-rest--request' 的桩替调用计数.
由 `seshat-reading-test--with-request-stub' 动态绑定，断言必须在宏体内。")

(defun seshat-reading-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根（ECA 客户端所为），那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-reading-test-" t))))

(defmacro seshat-reading-test--with-env (&rest body)
  "在独立的临时状态文件与临时库根下执行 BODY.
BODY 执行期间 `seshat-state-file' 指向临时目录里的 \"sync-state.eld\"，
`seshat-state--state' 为 nil（空状态起步），`seshat-reading--warned' 为 nil
（警告去重从零开始）；库根目录见 `seshat-reading-test--root'，但**不会**
自动登记进状态库（由用例显式调用 `seshat-reading-test--register-root'）。
结束后递归删除临时目录。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-reading-test--dir (seshat-reading-test--make-temp-dir))
          (seshat-reading-test--root
           (file-name-as-directory
            (expand-file-name "library" seshat-reading-test--dir)))
          (seshat-state-file (expand-file-name "sync-state.eld"
                                               seshat-reading-test--dir))
          (seshat-state--state nil)
          (seshat-reading--warned nil))
     (make-directory seshat-reading-test--root t)
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory seshat-reading-test--dir t)))))

(defun seshat-reading-test--touch (dir name)
  "在 DIR 下创建文件 NAME（自动建父目录），返回绝对路径."
  (let ((file (expand-file-name name dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert "%PDF-1.4\n"))
    file))

(defun seshat-reading-test--register-root ()
  "把当前用例的库根登记进状态库（元素 `(TAG DIR MODE)'）."
  (seshat-state-set-roots (list (list "lib" seshat-reading-test--root "mirror"))))

(defun seshat-reading-test--warnings (function)
  "在调用 FUNCTION 期间捕获 `display-warning'，返回 `(RESULT . WARNINGS)'."
  (let (warnings)
    (let ((result (cl-letf (((symbol-function 'display-warning)
                             (lambda (_type message &optional _level _buffer)
                               (push message warnings))))
                  (funcall function))))
      (cons result (nreverse warnings)))))

(defmacro seshat-reading-test--with-request-stub (response &rest body)
  "在 BODY 期间桩替 `seshat-rest--request'，调用次数记入
`seshat-reading-test--calls'（动态绑定，断言必须写在 BODY 内）。
RESPONSE 是桩返回的 `(STATUS . BODY)'。用途：断言「零请求」以及驱动
`seshat-rest-resolve-uid' 的成功/失败两条路径。"
  (declare (indent 1) (debug t))
  `(let ((seshat-reading-test--calls 0))
     (cl-letf (((symbol-function 'seshat-rest--request)
                (lambda (&rest _args)
                  (setq seshat-reading-test--calls
                        (1+ seshat-reading-test--calls))
                  ,response)))
       ,@body)))

(defun seshat-reading-test--mode-line (file)
  "在临时 buffer 里应用 FILE 的库身份，返回 mode-line 的标识字符串.
同时断言 `mode-line-misc-info' 里确实装了本模块的条目，且条目的 `:eval'
载荷就是 `seshat-reading--mode-line-text'（batch 下 `format-mode-line' 不
求值 `:eval'，故直接求值载荷）。"
  (with-temp-buffer
    (setq buffer-file-name file)
    (setq major-mode 'seshat-reading-mode)
    (seshat-reading--apply-identity)
    (should (member seshat-reading--mode-line-entry mode-line-misc-info))
    (should (equal (nth 1 seshat-reading--mode-line-entry)
                   '(seshat-reading--mode-line-text)))
    (eval (nth 1 seshat-reading--mode-line-entry) t)))

(defun seshat-reading-test--resolve (file)
  "返回 FILE 在**零请求**前提下的身份 plist，并断言确实没有发请求."
  (let (identity)
    (seshat-reading-test--with-request-stub (cons 200 "{\"uid\":\"x\"}")
      (setq identity (seshat-reading--resolve file))
      (should (= seshat-reading-test--calls 0)))
    identity))

;;; T1：派生 mode 兼容

(ert-deftest seshat-reading-test-mode-is-derived-from-reader ()
  "`seshat-reading-mode' 是 `seshat-reader-mode' 的派生 major mode."
  (should (eq (get 'seshat-reading-mode 'derived-mode-parent)
              'seshat-reader-mode))
  (with-temp-buffer
    (setq major-mode 'seshat-reading-mode)
    (should (derived-mode-p 'seshat-reading-mode))
    (should (derived-mode-p 'seshat-reader-mode))))

(ert-deftest seshat-reading-test-dark-mode-guard-in-derived-mode ()
  "派生 mode 下 `seshat-reader-dark-mode' 的守卫仍然生效.
桩替动态模块函数与全窗口重绘，断言两者都被调用（`eq major-mode' 版本会
在派生 mode 下静默跳过）。"
  (let (invert-args redisplay-calls)
    (with-temp-buffer
      (setq major-mode 'seshat-reading-mode)
      (cl-letf (((symbol-function 'seshat-reader-dyn--doc-invert)
                 (lambda (flag) (push flag invert-args)))
                ((symbol-function 'seshat-reader--redisplay-all-windows)
                 (lambda () (setq redisplay-calls
                                  (1+ (or redisplay-calls 0))))))
        (seshat-reader-dark-mode 1))
      (should (equal invert-args '(1)))
      (should (eq redisplay-calls 1))
      (setq seshat-reader-dark-mode nil))))

(ert-deftest seshat-reading-test-presentation-mode-guard-in-derived-mode ()
  "派生 mode 下 `seshat-reader-presentation-mode' 的守卫仍然生效.
桩替 `seshat-reader-fit-to-height'，断言呈现模式确实接管了 mode-line。"
  (let (fit-calls)
    (with-temp-buffer
      (setq major-mode 'seshat-reading-mode)
      (setq-local mode-line-format '("%b"))
      (cl-letf (((symbol-function 'seshat-reader-fit-to-height)
                 (lambda () (setq fit-calls (1+ (or fit-calls 0))))))
        (seshat-reader-presentation-mode 1))
      (should (eq fit-calls 1))
      (should (null mode-line-format))
      (setq seshat-reader-presentation-mode nil))))

(ert-deftest seshat-reading-test-highlight-source-check-in-derived-mode ()
  "派生 mode 下批注高亮源校验不再因 mode 判断返回 nil."
  (seshat-reading-test--with-env
    (let* ((file (seshat-reading-test--touch seshat-reading-test--root
                                             "book.pdf"))
           (seshat-reader-annotation-roots nil))
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reading-mode)
        (let ((doc-id (seshat-reader-annotation--quiet-doc-id file)))
          (should (stringp doc-id))
          (should (seshat-reader-annotation--source-document-p
                   (current-buffer) doc-id))
          ;; 反向断言：不匹配的 doc-id 仍返回 nil（校验没被放宽）
          (should-not (seshat-reader-annotation--source-document-p
                       (current-buffer) "local:/nonexistent.pdf")))))))

;;; T2：四态解析（零网络）

(ert-deftest seshat-reading-test-resolve-external-is-network-free ()
  "文件不在任何库根下 → `external'，且零请求。"
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let* ((outside (seshat-reading-test--touch seshat-reading-test--dir
                                                "outside.pdf"))
           (identity (seshat-reading-test--resolve outside)))
      (should (eq (plist-get identity :state) 'external))
      (should (null (plist-get identity :uid)))
      (should (null (plist-get identity :root))))))

(ert-deftest seshat-reading-test-resolve-library-with-uid ()
  "在根下且状态库有 uid → `library'，`:uid' 正确，且零请求。"
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((file (seshat-reading-test--touch seshat-reading-test--root
                                            "book.pdf")))
      (seshat-state-set "UID-LIB" (list :root "lib" :path "book.pdf"))
      (let ((identity (seshat-reading-test--resolve file)))
        (should (eq (plist-get identity :state) 'library))
        (should (equal (plist-get identity :uid) "UID-LIB"))
        (should (equal (plist-get identity :root) "lib"))
        (should (equal (plist-get identity :rel) "book.pdf"))))))

(ert-deftest seshat-reading-test-resolve-unregistered-is-quiet-and-network-free ()
  "在根下但状态库无记录 → `unregistered'：零请求、零 warning。"
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let* ((file (seshat-reading-test--touch seshat-reading-test--root
                                             "new.pdf"))
           (result (seshat-reading-test--warnings
                    (lambda () (seshat-reading-test--resolve file))))
           (identity (car result)))
      (should (eq (plist-get identity :state) 'unregistered))
      (should (equal (plist-get identity :root) "lib"))
      (should (equal (plist-get identity :rel) "new.pdf"))
      (should (null (cdr result))))))

(ert-deftest seshat-reading-test-resolve-broken-state ()
  "状态库损坏（roots 空 + .bak 存在）→ `broken'。"
  (seshat-reading-test--with-env
    (with-temp-file (concat seshat-state-file ".bak")
      (insert "corrupt"))
    (let* ((file (seshat-reading-test--touch seshat-reading-test--root
                                             "book.pdf"))
           (identity (seshat-reading-test--resolve file)))
      (should (eq (plist-get identity :state) 'broken))
      (should (null (plist-get identity :uid))))))

(ert-deftest seshat-reading-test-resolve-broken-beats-external ()
  "`broken' 优先于 `external'：库外文件在状态库损坏时仍是 `broken'."
  (seshat-reading-test--with-env
    ;; 故意不登记任何根（模拟损坏后的空状态），并留下 .bak
    (with-temp-file (concat seshat-state-file ".bak")
      (insert "corrupt"))
    (let* ((outside (seshat-reading-test--touch seshat-reading-test--dir
                                                "outside.pdf"))
           (identity (seshat-reading-test--resolve outside)))
      (should (null (seshat-state-roots)))
      (should (eq (plist-get identity :state) 'broken))
      (should-not (eq (plist-get identity :state) 'external)))))

(ert-deftest seshat-reading-test-resolve-error-degrades-to-external ()
  "`--resolve' 内部抛错 → 降级为 `external'，不向外抛错，警告只发一次."
  (seshat-reading-test--with-env
    (let* ((file (seshat-reading-test--touch seshat-reading-test--dir
                                             "any.pdf"))
           (result (seshat-reading-test--warnings
                    (lambda ()
                      (cl-letf (((symbol-function 'seshat-state-roots)
                                 (lambda ()
                                   (error "状态文件不可读"))))
                        (list (seshat-reading--resolve file)
                              (seshat-reading--resolve file))))))
           (identities (car result))
           (warnings (cdr result)))
      (should (= 2 (length identities)))
      (dolist (identity identities)
        (should (eq (plist-get identity :state) 'external)))
      (should (= 1 (length warnings))))))

;;; T2：mode-line 标识

(ert-deftest seshat-reading-test-mode-line-four-states ()
  "mode-line 四态字符串正确（` [库]` / ` [未入库]` / ` [库外]` / ` [状态异常]`）。"
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((in-root (seshat-reading-test--touch seshat-reading-test--root
                                               "book.pdf"))
          (outside (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      ;; library
      (seshat-state-set "UID-LIB" (list :root "lib" :path "book.pdf"))
      (should (equal (seshat-reading-test--mode-line in-root) " [库]"))
      ;; unregistered
      (let ((other (seshat-reading-test--touch seshat-reading-test--root
                                               "new.pdf")))
        (should (equal (seshat-reading-test--mode-line other) " [未入库]")))
      ;; external
      (should (equal (seshat-reading-test--mode-line outside) " [库外]"))
      ;; broken：清空状态 + 留下 .bak
      (setq seshat-state--state (seshat-state--empty))
      (with-temp-file (concat seshat-state-file ".bak")
        (insert "corrupt"))
      (should (equal (seshat-reading-test--mode-line outside) " [状态异常]")))))

(ert-deftest seshat-reading-test-mode-line-entry-is-idempotent ()
  "重复应用身份不会在 `mode-line-misc-info' 里堆叠条目."
  (seshat-reading-test--with-env
    (let ((file (seshat-reading-test--touch seshat-reading-test--dir
                                            "outside.pdf")))
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reading-mode)
        (seshat-reading--apply-identity)
        (seshat-reading--apply-identity)
        (should (= 1 (seq-count (lambda (item)
                                  (equal item seshat-reading--mode-line-entry))
                                mode-line-misc-info)))))))

;;; T2：auto-mode-alist 接管

(ert-deftest seshat-reading-test-auto-mode-alist-takeover ()
  "「reader 先注册、reading 后加载」时 pdf 仍解析为 `seshat-reading-mode'."
  (let ((auto-mode-alist (mapcar (lambda (entry)
                                   (cons (car entry) (cdr entry)))
                                 (default-value 'auto-mode-alist))))
    ;; 回到「reading 尚未接管」的状态：把指向本 mode 的项改回 reader
    (dolist (entry auto-mode-alist)
      (when (eq (cdr entry) 'seshat-reading-mode)
        (setcdr entry 'seshat-reader-mode)))
    ;; 再按 reader 的方式注册一次（模拟 reader 后加载时前插）
    (dolist (pattern seshat-reader-supported-formats)
      (add-to-list 'auto-mode-alist
                   (cons (concat "\\." pattern "\\'") 'seshat-reader-mode)))
    (should (eq (assoc-default "x.pdf" auto-mode-alist #'string-match-p)
                'seshat-reader-mode))
    (seshat-reading--take-over-auto-mode-alist)
    (should (eq (assoc-default "x.pdf" auto-mode-alist #'string-match-p)
                'seshat-reading-mode))
    (should (eq (assoc-default "x.epub" auto-mode-alist #'string-match-p)
                'seshat-reading-mode))))

(ert-deftest seshat-reading-test-auto-mode-alist-no-duplicates ()
  "reader 支持的各扩展名在 `auto-mode-alist' 里只有一个本 mode 项、零 reader 项."
  (let ((keys nil))
    (dolist (entry (default-value 'auto-mode-alist))
      (when (memq (cdr entry) '(seshat-reader-mode seshat-reading-mode))
        (cl-pushnew (car entry) keys :test #'equal)))
    (should keys)
    (dolist (key keys)
      (let ((hits (seq-filter (lambda (entry) (equal (car entry) key))
                              (default-value 'auto-mode-alist))))
        (should (= 1 (seq-count (lambda (entry)
                                  (eq (cdr entry) 'seshat-reading-mode))
                                hits)))
        (should (= 0 (seq-count (lambda (entry)
                                  (eq (cdr entry) 'seshat-reader-mode))
                                hits)))))))

;;; T2：显式刷新（唯一的触网入口）

(ert-deftest seshat-reading-test-refresh-promotes-unregistered-to-library ()
  "`seshat-reading-refresh' 成功 → `library'，uid 被登记并落盘."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((file (seshat-reading-test--touch seshat-reading-test--root
                                            "book.pdf")))
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reading-mode)
        (should (eq (plist-get (seshat-reading--apply-identity) :state)
                    'unregistered))
        (seshat-reading-test--with-request-stub (cons 200 "{\"uid\":\"UID-SRV\"}")
          (seshat-reading-refresh)
          (should (= seshat-reading-test--calls 1)))
        (should (eq (plist-get seshat-reading--identity :state) 'library))
        (should (equal (plist-get seshat-reading--identity :uid) "UID-SRV"))
        (should (equal (seshat-state-uid-for-path "lib" "book.pdf")
                       "UID-SRV"))
        (should (file-exists-p seshat-state-file))
        ;; 落盘后重新加载仍是 library 的映射
        (setq seshat-state--state nil)
        (seshat-state-load)
        (should (equal (seshat-state-uid-for-path "lib" "book.pdf")
                       "UID-SRV"))))))

(ert-deftest seshat-reading-test-refresh-failure-keeps-unregistered ()
  "`seshat-reading-refresh' 失败 → 保持 `unregistered' + message，不抛错."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((file (seshat-reading-test--touch seshat-reading-test--root
                                            "book.pdf")))
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reading-mode)
        (seshat-reading--apply-identity)
        (let (messages)
          (seshat-reading-test--with-request-stub
              (cons 404 "{\"error\":\"not found\"}")
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args)
                               messages))))
              (seshat-reading-refresh))
            (should (= seshat-reading-test--calls 1)))
          (should (seq-some (lambda (msg) (string-match-p "未登记" msg))
                            messages)))
        (should (eq (plist-get seshat-reading--identity :state)
                    'unregistered))
        (should (null (plist-get seshat-reading--identity :uid)))
        ;; 失败不写状态文件
        (should-not (file-exists-p seshat-state-file))))))

(ert-deftest seshat-reading-test-refresh-library-does-not-touch-network ()
  "已是 `library' 时 `seshat-reading-refresh' 只重解析，零请求."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((file (seshat-reading-test--touch seshat-reading-test--root
                                            "book.pdf")))
      (seshat-state-set "UID-LIB" (list :root "lib" :path "book.pdf"))
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reading-mode)
        (seshat-reading-test--with-request-stub (cons 200 "{\"uid\":\"x\"}")
          (seshat-reading-refresh)
          (should (= seshat-reading-test--calls 0)))
        (should (equal (plist-get seshat-reading--identity :uid)
                       "UID-LIB"))))))

(defun seshat-reading-test--contents (file)
  "以二进制安全方式读取 FILE 的全部内容并返回字符串."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defmacro seshat-reading-test--with-reading-buffer (file &rest body)
  "在访问 FILE 的临时 buffer 中以 `seshat-reading-mode' 语义执行 BODY.
**不**调用真正的 `seshat-reading-mode'：父 mode `seshat-reader-mode' 的
mode 体会渲染文档（需要动态模块），batch 下不可用。因此按 mode 体的效果
手工设置 `major-mode' 与 `seshat-reading--quiet-fallback'（后者正是 mode
体内唯一的 `setq-local'，见 `seshat-reading-mode' 的 docstring），并刷新
库身份与 mode-line。BODY 结束后 buffer 随 `with-temp-buffer' 销毁。"
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name ,file)
     (setq major-mode 'seshat-reading-mode)
     (setq-local seshat-reading--quiet-fallback t)
     (seshat-reading--apply-identity)
     ,@body))

(defmacro seshat-reading-test--with-y-or-n (answer &rest body)
  "在 BODY 期间把 `y-or-n-p' 桩替为恒返回 ANSWER（避免 batch 下读 stdin）."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _args) ,answer)))
     ,@body))

(defvar seshat-reading-test--uploads nil
  "桩替 `seshat-rest-upload-file' 的调用记录（按调用顺序）.
每个元素为 `(:path PATH :content CONTENT :args ARGS)'，由
`seshat-reading-test--with-upload-stub' 动态绑定并填充。")

(defmacro seshat-reading-test--with-upload-stub (responses &rest body)
  "在 BODY 期间桩替 `seshat-rest-upload-file'，按顺序返回 RESPONSES 各项.
RESPONSES 是 plist 列表（每项形如 `(:status 201 :uid \"U\" :etag \"E\")'）。
调用记录写入 `seshat-reading-test--uploads'（**动态绑定**，断言必须写在
BODY 之内）。"
  (declare (indent 1) (debug t))
  `(let ((seshat-reading-test--uploads nil)
         (seshat-reading-test--pending (copy-sequence ,responses)))
     (cl-letf (((symbol-function 'seshat-rest-upload-file)
                (lambda (path content &rest args)
                  (setq seshat-reading-test--uploads
                        (append seshat-reading-test--uploads
                                (list (list :path path :content content
                                            :args args))))
                  (prog1 (car seshat-reading-test--pending)
                    (setq seshat-reading-test--pending
                          (cdr seshat-reading-test--pending))))))
       ,@body)))

;;; T4：未入库时批注静音（参数传递，非 buffer-local 开关）

(ert-deftest seshat-reading-test-doc-id-warns-in-reader-mode ()
  "`seshat-reader-mode' buffer 下 doc-id 未命中根 → 仍然 `message'（既有行为不变）."
  (seshat-reading-test--with-env
    (let ((file (seshat-reading-test--touch seshat-reading-test--dir
                                           "outside.pdf"))
          (seshat-reader-annotation-roots nil)
          messages)
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reader-mode)
        (setq-local seshat-reading--quiet-fallback nil)
        (should-not (seshat-reader-annotation--quiet-p file))
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          (should (equal (seshat-reader-annotation--doc-id
                          file (seshat-reader-annotation--quiet-p file))
                         (concat "local:" (file-truename file))))))
      (should (= 1 (length messages)))
      (should (string-match-p "降级为" (car messages))))))

(ert-deftest seshat-reading-test-doc-id-quiet-in-reading-mode ()
  "`seshat-reading-mode' buffer 下同样场景 → **无** `message'，doc-id 仍是 `local:<abs>'."
  (seshat-reading-test--with-env
    (let ((file (seshat-reading-test--touch seshat-reading-test--dir
                                           "outside.pdf"))
          (seshat-reader-annotation-roots nil)
          messages)
      (seshat-reading-test--with-reading-buffer file
        (should (seshat-reader-annotation--quiet-p file))
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          (should (equal (seshat-reader-annotation--doc-id
                          file (seshat-reader-annotation--quiet-p file))
                         (concat "local:" (file-truename file))))))
      (should (null messages))
      ;; 显式传 QUIET 与不传的返回值一致（只影响是否发警告）
      (let ((inhibit-message t))
        (should (equal (seshat-reader-annotation--doc-id file t)
                       (seshat-reader-annotation--doc-id file)))))))

(ert-deftest seshat-reading-test-quiet-p-reads-file-buffer ()
  "`seshat-reading-quiet-p' 对**非当前 buffer** 的文件返回正确值.
构造一个处于 reading-mode 的 buffer 打开某文件，然后在另一个 buffer 里
调用——证明跨 buffer（翻译面板场景）不是靠 buffer-local 开关作弊。"
  (seshat-reading-test--with-env
    (let ((file (seshat-reading-test--touch seshat-reading-test--dir
                                           "outside.pdf"))
          (seshat-reader-annotation-roots nil)
          messages
          quiet)
      (with-temp-buffer
        (setq buffer-file-name file)
        (setq major-mode 'seshat-reading-mode)
        (setq-local seshat-reading--quiet-fallback t)
        ;; 完全不同的 buffer（其自身标记为 nil）里按文件反查
        (with-temp-buffer
          (setq-local seshat-reading--quiet-fallback nil)
          (should-not (seshat-reading-quiet-p))
          (setq quiet (seshat-reading-quiet-p file))
          (should quiet)
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should (equal (seshat-reader-annotation--doc-id
                            file (seshat-reader-annotation--quiet-p file))
                           (concat "local:" (file-truename file))))))
      (should quiet)
      (should (null messages))
      ;; 未打开的文件的判定恒为 nil（不因全局默认值而静音）
      (should-not (seshat-reading-quiet-p
                   (expand-file-name "never-opened.pdf"
                                     seshat-reading-test--dir)))))))

(ert-deftest seshat-reading-test-uid-user-error-for-external-file ()
  "库外文件创建批注仍抛 `user-error'（既有行为不变，本计划不改 `--uid'）."
  (seshat-reading-test--with-env
    (let ((file (seshat-reading-test--touch seshat-reading-test--dir
                                           "outside.pdf"))
          (seshat-reader-annotation-roots nil)
          (seshat-reader-annotation--uid-cache nil))
      (should-error (seshat-reader-annotation--uid file) :type 'user-error))))

;;; T3：入库命令 `seshat-library-add'

(ert-deftest seshat-reading-test-library-add-happy-path ()
  "正常入库：复制到根 + `:if-none-match \"*\"' 上传 + 登记 state + 保存 + mode-line 变 ` [库]'."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((source (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      (let ((target (expand-file-name "books/book.pdf"
                                      seshat-reading-test--root)))
        (seshat-reading-test--with-upload-stub
            (list (list :status 201 :uid "UID-NEW" :etag "ETAG-1" :rev 1))
          (seshat-reading-test--with-reading-buffer source
            (seshat-reading-test--with-y-or-n t
              (let ((result (seshat-library-add source "lib" "books/book.pdf")))
                (should (equal (plist-get result :uid) "UID-NEW"))
                (should (equal (plist-get result :root) "lib"))
                (should (equal (plist-get result :rel) "books/book.pdf"))
                (should (equal (plist-get result :target) target))
                (should (equal (seshat-reading--mode-line-text) " [库]"))
                (should (eq (plist-get seshat-reading--identity :state)
                            'library)))))
          (should (= 1 (length seshat-reading-test--uploads)))
          (let ((upload (nth 0 seshat-reading-test--uploads)))
            (should (equal (plist-get upload :path) "books/book.pdf"))
            (should (equal (plist-get (plist-get upload :args) :root) "lib"))
            (should (equal (plist-get (plist-get upload :args) :if-none-match)
                           "*"))
            ;; 二进制安全：上传内容与原件逐字节一致
            (should (equal (plist-get upload :content)
                           (seshat-reading-test--contents source)))))
        ;; 复制保留原件
        (should (file-exists-p source))
        (should (file-exists-p target))
        (should (equal (seshat-reading-test--contents target)
                       (seshat-reading-test--contents source)))
        ;; state 登记 + 落盘
        (should (equal (seshat-state-uid-for-path "lib" "books/book.pdf")
                       "UID-NEW"))
        (let* ((entry (seshat-state-get "UID-NEW"))
               (attributes (file-attributes target)))
          (should (equal (plist-get entry :root) "lib"))
          (should (equal (plist-get entry :path) "books/book.pdf"))
          (should (equal (plist-get entry :base-blob) "ETAG-1"))
          (should (= (plist-get entry :size) (nth 7 attributes)))
          (should (= (plist-get entry :mtime)
                     (truncate (float-time (nth 5 attributes)))))
          (should-not (plist-get entry :dirty)))
        (should (file-exists-p seshat-state-file))))))

(ert-deftest seshat-reading-test-library-add-baseline-from-target-file ()
  "base blob 的 size/mtime 取自**复制后的目标文件**，而不是原文件.
把原文件 mtime 设成 2000-01-01，`copy-file'（不保时）后目标 mtime 是现在；
若实现误用原文件属性做基线，断言会拿到 2000 年的时间戳。"
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let* ((source (seshat-reading-test--touch seshat-reading-test--dir
                                               "outside.pdf"))
           (target (expand-file-name "book.pdf" seshat-reading-test--root)))
      (set-file-times source (seconds-to-time 946684800))
      (let ((source-mtime (truncate (float-time
                                     (nth 5 (file-attributes source))))))
        (seshat-reading-test--with-upload-stub
            (list (list :status 201 :uid "UID-1" :etag "E1"))
          (seshat-reading-test--with-reading-buffer source
            (seshat-reading-test--with-y-or-n t
              (seshat-library-add source "lib" "book.pdf")))
          (let* ((attributes (file-attributes target))
                 (target-mtime (truncate (float-time (nth 5 attributes))))
                 (entry (seshat-state-get "UID-1")))
            (should (file-exists-p target))
            ;; 前提：两个 mtime 确实不同，否则本用例无法区分基线来源
            (should-not (= source-mtime target-mtime))
            (should (= (plist-get entry :mtime) target-mtime))
            (should-not (= (plist-get entry :mtime) source-mtime))
            (should (= (plist-get entry :size) (nth 7 attributes)))))))))

(ert-deftest seshat-reading-test-library-add-then-detect-renames-is-clean ()
  "入库后立即 `seshat-sync-detect-renames' 不产生 dirty（端到端基线校验）."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (require 'seshat-sync)
    (let ((source (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      (seshat-reading-test--with-upload-stub
          (list (list :status 201 :uid "UID-1" :etag "E1"))
        (seshat-reading-test--with-reading-buffer source
          (seshat-reading-test--with-y-or-n t
            (seshat-library-add source "lib" "book.pdf"))))
      (let ((stats (seshat-reading-test--with-request-stub (cons 500 "")
                     (seshat-sync-detect-renames))))
        (should (= 0 (plist-get stats :dirty-marked)))
        (should (= 0 (plist-get stats :renamed)))
        (should (= 0 (plist-get stats :appeared)))
        (should (= 0 (plist-get stats :vanished)))
        ;; 零请求：本地基线与目标文件一致时既不推送也不配对改名
        (should (= 0 seshat-reading-test--calls)))
      (should (null (seshat-state-dirty-uids))))))

(ert-deftest seshat-reading-test-library-add-rejects-already-in-library ()
  "已是 `library' → `user-error'，不发上传请求."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((file (seshat-reading-test--touch seshat-reading-test--root
                                            "book.pdf")))
      (seshat-state-set "UID-LIB" (list :root "lib" :path "book.pdf"))
      (seshat-reading-test--with-upload-stub nil
        (seshat-reading-test--with-reading-buffer file
          (seshat-reading-test--with-y-or-n t
            (let ((err (should-error (seshat-library-add file "lib" "other.pdf")
                                     :type 'user-error)))
              (should (string-match-p "已在库中" (error-message-string err))))
            (should (= 0 (length seshat-reading-test--uploads)))))))))

(ert-deftest seshat-reading-test-library-add-requires-mirror-root ()
  "无 mirror 根 → `user-error' 且提示配置 `seshat-sync-roots'."
  (seshat-reading-test--with-env
    ;; 只有 ondemand 根（写请求会 403，不能作为入库目标）
    (seshat-state-set-roots
     (list (list "remote" seshat-reading-test--root "ondemand")))
    (let ((file (seshat-reading-test--touch seshat-reading-test--root
                                            "book.pdf")))
      (seshat-reading-test--with-upload-stub nil
        (seshat-reading-test--with-reading-buffer file
          (seshat-reading-test--with-y-or-n t
            (let ((err (should-error (seshat-library-add file nil "book.pdf")
                                     :type 'user-error)))
              (should (string-match-p "seshat-sync-roots"
                                      (error-message-string err))))
            (should (= 0 (length seshat-reading-test--uploads)))))))))

(ert-deftest seshat-reading-test-library-add-conflict-then-overwrite ()
  "412 → 用户同意覆盖 → 用 `:if-match' 带远端版本号重发并成功."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((source (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      (seshat-reading-test--with-upload-stub
          (list (list :status 412 :conflict 'etag-mismatch)
                (list :status 200 :uid "UID-2" :etag "E2"))
        (cl-letf (((symbol-function 'seshat-rest-versions)
                   (lambda (_path &optional _blob)
                     (list :status 200 :head "HEAD-ONE" :content nil)))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _args) t)))
          (seshat-reading-test--with-reading-buffer source
            (should (equal (plist-get (seshat-library-add source "lib" "book.pdf")
                                      :uid)
                           "UID-2"))))
        (should (= 2 (length seshat-reading-test--uploads)))
        (let ((first (nth 0 seshat-reading-test--uploads))
              (second (nth 1 seshat-reading-test--uploads)))
          (should (equal (plist-get (plist-get first :args) :if-none-match) "*"))
          (should (equal (plist-get (plist-get second :args) :if-match)
                         "HEAD-ONE")))
        (should (equal (seshat-state-uid-for-path "lib" "book.pdf") "UID-2"))
        (should (equal (plist-get (seshat-state-get "UID-2") :base-blob)
                       "E2"))))))

(ert-deftest seshat-reading-test-library-add-conflict-declined-keeps-state ()
  "412 → 用户拒绝覆盖 → 中止且不写 state，也不重发上传."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((source (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      (seshat-reading-test--with-upload-stub
          (list (list :status 412 :conflict 'etag-mismatch))
        (cl-letf (((symbol-function 'seshat-rest-versions)
                   (lambda (_path &optional _blob)
                     (list :status 200 :head "HEAD-ONE" :content nil)))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _args) nil)))
          (seshat-reading-test--with-reading-buffer source
            (should-error (seshat-library-add source "lib" "book.pdf")
                          :type 'user-error)))
        (should (= 1 (length seshat-reading-test--uploads)))
        (should (null (seshat-state-uid-for-path "lib" "book.pdf")))
        (should-not (file-exists-p seshat-state-file))))))

(ert-deftest seshat-reading-test-library-add-upload-failure-keeps-copy ()
  "上传失败（500）→ `user-error'，副本按用户选择保留，state 未登记."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let* ((source (seshat-reading-test--touch seshat-reading-test--dir
                                               "outside.pdf"))
           (target (expand-file-name "book.pdf" seshat-reading-test--root)))
      (seshat-reading-test--with-upload-stub (list (list :status 500))
        (seshat-reading-test--with-reading-buffer source
          ;; nil = 回答「不删除副本」
          (seshat-reading-test--with-y-or-n nil
            (let ((err (should-error (seshat-library-add source "lib" "book.pdf")
                                     :type 'user-error)))
              (should (string-match-p "500" (error-message-string err))))))
        (should (file-exists-p target))
        (should (null (seshat-state-uid-for-path "lib" "book.pdf")))
        (should-not (file-exists-p seshat-state-file))))))

(ert-deftest seshat-reading-test-library-add-rejects-path-escape ()
  "库内路径含 `..' → 拒绝且不复制、不上传."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((source (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      (seshat-reading-test--with-upload-stub nil
        (seshat-reading-test--with-reading-buffer source
          (seshat-reading-test--with-y-or-n t
            (let ((err (should-error (seshat-library-add source "lib"
                                                         "../escape.pdf")
                                     :type 'user-error)))
              (should (string-match-p "越出根目录" (error-message-string err))))
            (should (= 0 (length seshat-reading-test--uploads))))))
      (should-not (file-exists-p (expand-file-name "escape.pdf"
                                                   seshat-reading-test--dir)))
      (should-not (file-exists-p (expand-file-name "../escape.pdf"
                                                   seshat-reading-test--root))))))

(ert-deftest seshat-reading-test-library-add-chooses-among-multiple-roots ()
  "多个 mirror 根 → 走 `completing-read' 选 TAG，并按所选根落盘."
  (seshat-reading-test--with-env
    (let* ((root2 (file-name-as-directory
                   (expand-file-name "library2" seshat-reading-test--dir)))
           (source (seshat-reading-test--touch seshat-reading-test--dir
                                               "outside.pdf"))
           asked)
      (make-directory root2 t)
      (seshat-state-set-roots
       (list (list "lib" seshat-reading-test--root "mirror")
             (list "lib2" root2 "mirror")))
      (seshat-reading-test--with-upload-stub
          (list (list :status 201 :uid "UID-3" :etag "E3"))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &optional _predicate _require
                                   &rest _rest)
                     (setq asked (list prompt collection))
                     "lib2"))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _args) t)))
          (seshat-reading-test--with-reading-buffer source
            (seshat-library-add source nil "book.pdf")))
        (should asked)
        (should (equal (nth 1 asked) '("lib" "lib2")))
        (should (equal (plist-get (plist-get (nth 0 seshat-reading-test--uploads)
                                             :args)
                                  :root)
                       "lib2"))
        (should (file-exists-p (expand-file-name "book.pdf" root2)))
        (should-not (file-exists-p (expand-file-name "book.pdf"
                                                     seshat-reading-test--root)))
        (should (equal (seshat-state-uid-for-path "lib2" "book.pdf") "UID-3"))))))

(ert-deftest seshat-reading-test-library-add-requires-reading-buffer ()
  "文件所在 buffer 不是 reader/reading mode → `user-error'，不发上传请求."
  (seshat-reading-test--with-env
    (seshat-reading-test--register-root)
    (let ((source (seshat-reading-test--touch seshat-reading-test--dir
                                              "outside.pdf")))
      (seshat-reading-test--with-upload-stub nil
        (with-temp-buffer
          (setq buffer-file-name source)
          (setq major-mode 'fundamental-mode)
          (seshat-reading-test--with-y-or-n t
            (let ((err (should-error (seshat-library-add source "lib" "book.pdf")
                                     :type 'user-error)))
              (should (string-match-p "seshat-reader-mode"
                                      (error-message-string err))))
            (should (= 0 (length seshat-reading-test--uploads)))))))))

(provide 'seshat-reading-test)
;;; seshat-reading-test.el ends here
