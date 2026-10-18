;;; seshat-reader-annotation-queue-test.el --- ERT tests for seshat-reader-annotation-queue  -*- lexical-binding: t; -*-

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

;; `seshat-reader-annotation-queue' 的 ERT 测试套件，同时覆盖它在
;; `seshat-reader-annotation' 中的接入点（create 入队/在线、list 合并渲染与
;; `-list-delete' 的 uuid 分支）。
;;
;; 全部用例**绝不触网**：统一用 `cl-letf' **桩替网络出口**——`seshat-rest--request'、
;; `seshat-reader-annotation--fetch'，以及用于断言调用次数的
;; `seshat-reader-annotation-queue-sync'；任何真实 HTTP 调用都不会发生。
;;
;; 每个用例都把 `seshat-reader-annotation-queue-file' 绑定到 /tmp 下的临时
;; 路径（经 `make-temp-file' 建临时目录），并在结束时递归删除，因此**绝不
;; 写用户真实队列文件**；测试可重复运行、不污染仓库。模块加载会依
;; `seshat-reader-annotation-queue-auto-sync' 自动启用自动同步定时器，故本文件
;; 在 `require' 队列模块后**立即** `seshat-reader-annotation-queue-disable-timer'；
;; 涉及定时器的用例另行 `unwind-protect' 恢复。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader-annotation-queue)

;; 模块加载时会依 `-auto-sync' 自动启用定时器，这里立即关闭。
(seshat-reader-annotation-queue-disable-timer)

(require 'seshat-reader-annotation)

;;; 测试辅助

(defvar seshat-reader-annotation-queue-test--requests nil
  "最近一批 `seshat-rest--request' 桩的调用记录，元素形如 (METHOD PATH BODY).")

(defvar seshat-reader-annotation-queue-test--sync-calls nil
  "最近一批 `seshat-reader-annotation-queue-sync' 桩的调用记录.")

(defun seshat-reader-annotation-queue-test--stub (status body)
  "返回一个桩替 `seshat-rest--request' 的闭包.
闭包把每次调用 (METHOD PATH BODY) 压入
`seshat-reader-annotation-queue-test--requests'，并恒返回 (STATUS . BODY)."
  (lambda (method path &optional request-body)
    (push (list method path request-body)
          seshat-reader-annotation-queue-test--requests)
    (cons status body)))

(defmacro seshat-reader-annotation-queue-test--with-stub (status body &rest body-forms)
  "桩替 `seshat-rest--request' 后求值 BODY-FORMS，返回调用记录.
STATUS 与 BODY 是桩恒定返回的假响应；返回本次记录的调用列表
（元素形如 (METHOD PATH BODY)）。"
  (declare (indent 2) (debug t))
  `(let ((seshat-reader-annotation-queue-test--requests nil))
     (cl-letf (((symbol-function 'seshat-rest--request)
                (seshat-reader-annotation-queue-test--stub ,status ,body)))
       ,@body-forms)
     (nreverse seshat-reader-annotation-queue-test--requests)))

(defmacro seshat-reader-annotation-queue-test--with-fetch (fn &rest body-forms)
  "把 `seshat-reader-annotation--fetch' 桩替为 FN 后求值 BODY-FORMS.
FN 接收一个 document-id 参数并作为拉取结果返回。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'seshat-reader-annotation--fetch) ,fn))
     ,@body-forms))

(defmacro seshat-reader-annotation-queue-test--with-sync-spy (&rest body-forms)
  "桩替 `seshat-reader-annotation-queue-sync' 并记录调用后求值 BODY-FORMS.
返回调用记录列表（元素为实参列表）。"
  (declare (indent 0) (debug t))
  `(let ((seshat-reader-annotation-queue-test--sync-calls nil))
     (cl-letf (((symbol-function 'seshat-reader-annotation-queue-sync)
                (lambda (&rest args)
                  (push args seshat-reader-annotation-queue-test--sync-calls))))
       ,@body-forms)
     (nreverse seshat-reader-annotation-queue-test--sync-calls)))

(defmacro seshat-reader-annotation-queue-test--capture-messages (&rest body-forms)
  "桩替 `message' 收集提示文本后求值 BODY-FORMS，返回提示文本列表."
  (declare (indent 0) (debug t))
  `(let ((seshat-reader-annotation-queue-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (if (stringp fmt) (apply #'format fmt args) fmt)
                        seshat-reader-annotation-queue-test--messages))))
       ,@body-forms)
     (nreverse seshat-reader-annotation-queue-test--messages)))

(defmacro seshat-reader-annotation-queue-test--with-temp-queue (var &rest body-forms)
  "把队列文件指向临时路径并求值 BODY-FORMS，把该路径绑定到 VAR.
临时目录在 BODY-FORMS 结束后递归删除，避免写入用户真实队列文件。"
  (declare (indent 1) (debug t))
  `(let* ((seshat-reader-annotation-queue-test--dir
           (make-temp-file "seshat-queue-test" t))
          (,var (expand-file-name "annotation-queue.eld"
                                  seshat-reader-annotation-queue-test--dir))
          (seshat-reader-annotation-queue-file ,var))
     (unwind-protect
         (progn ,@body-forms)
       (when (file-directory-p seshat-reader-annotation-queue-test--dir)
         (delete-directory seshat-reader-annotation-queue-test--dir t)))))

(defmacro seshat-reader-annotation-queue-test--with-temp-dir (var &rest body-forms)
  "在临时目录中求值 BODY-FORMS，并把带末尾斜杠的目录名绑定到 VAR.
临时目录在 BODY-FORMS 结束后递归删除。"
  (declare (indent 1) (debug t))
  `(let ((,var (file-name-as-directory
                (make-temp-file "seshat-queue-test-dir" t))))
     (unwind-protect
         (progn ,@body-forms)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defconst seshat-reader-annotation-queue-test--uid
  "01K8Q3M7D2X9V6T1B8N5C0RDEF"
  "测试用的固定 uid（服务端权威文件身份，同步用）。")

(defun seshat-reader-annotation-queue-test--create-entry (uid location text)
  "返回一条 create 队列条目 plist（UID、LOCATION、TEXT）.
`:uid' 为服务端权威身份（同步时发送）；`:document-id' 为显示用文档标识，
本套件固定为 \"notes:display.pdf\"，不参与同步、也不参与按 uid 过滤。"
  (list :action 'create
        :uid uid
        :document-id "notes:display.pdf"
        :location location
        :text text))

(defconst seshat-reader-annotation-queue-test--loc1
  "page:1;rect:0.00,0.00,1.00,1.00"
  "测试用位置字符串 1.")

(defconst seshat-reader-annotation-queue-test--loc2
  "page:2;rect:0.00,0.00,1.00,1.00"
  "测试用位置字符串 2.")

;;; A. 队列纯函数

(ert-deftest seshat-reader-annotation-queue-test--read-missing-file-nil ()
  "队列文件不存在时 `--read' 返回 nil."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (should-not (file-exists-p queue-file))
    (should-not (seshat-reader-annotation-queue--read))))

(ert-deftest seshat-reader-annotation-queue-test--enqueue-read-roundtrip ()
  "`-enqueue' 后的条目经 `--read' 读回，含 `:uuid' 与 `:queued-at'."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let ((entry (seshat-reader-annotation-queue-enqueue
                  (seshat-reader-annotation-queue-test--create-entry
                   "lib:book.pdf" seshat-reader-annotation-queue-test--loc1 "正文"))))
      (should (stringp (plist-get entry :uuid)))
      (should (stringp (plist-get entry :queued-at)))
      (let* ((read (seshat-reader-annotation-queue--read))
             (item (car read)))
        (should (= (length read) 1))
        (should (equal (plist-get item :uuid) (plist-get entry :uuid)))
        (should (stringp (plist-get item :uuid)))
        (should (stringp (plist-get item :queued-at)))
        (should (equal (plist-get item :action) 'create))))))

(ert-deftest seshat-reader-annotation-queue-test--entries-filters-by-uid ()
  "`-entries' 按 uid 过滤（不再按 doc-id）；不存在的 uid 返回 nil."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry "uid-a"
                                                        seshat-reader-annotation-queue-test--loc1 "a1"))
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry "uid-a"
                                                        seshat-reader-annotation-queue-test--loc2 "a2"))
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry "uid-b"
                                                        seshat-reader-annotation-queue-test--loc1 "b1"))
    (should (= (length (seshat-reader-annotation-queue-entries "uid-a")) 2))
    (should (= (length (seshat-reader-annotation-queue-entries)) 3))
    (should-not (seshat-reader-annotation-queue-entries "uid-missing"))
    ;; 过滤按 uid，不按 doc-id（所有条目 doc-id 相同，仍按 uid 分组）
    (should-not (seshat-reader-annotation-queue-entries "notes:display.pdf"))))

(ert-deftest seshat-reader-annotation-queue-test--remove-existing-and-missing ()
  "`-remove'：存在返回 t 且后续读取不含；不存在返回 nil."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let* ((entry (seshat-reader-annotation-queue-enqueue
                   (seshat-reader-annotation-queue-test--create-entry
                    "lib:a.pdf" seshat-reader-annotation-queue-test--loc1 "a")))
           (uuid (plist-get entry :uuid)))
      (should (seshat-reader-annotation-queue-remove uuid))
      (should-not (seshat-reader-annotation-queue--read))
      (should-not (seshat-reader-annotation-queue-remove uuid)))))

(ert-deftest seshat-reader-annotation-queue-test--count-missing-file-zero ()
  "队列文件不存在时 `-count' 返回 0."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (should (= (seshat-reader-annotation-queue-count) 0))))

(ert-deftest seshat-reader-annotation-queue-test--enqueue-rejects-at-max-entries ()
  "`-max-entries' 为 2 时第三条入队返回 nil，队列仍 2 条."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let ((seshat-reader-annotation-queue-max-entries 2))
      (cl-letf (((symbol-function 'message) #'ignore))
        (should (seshat-reader-annotation-queue-enqueue
                 (seshat-reader-annotation-queue-test--create-entry
                  "lib:a.pdf" seshat-reader-annotation-queue-test--loc1 "1")))
        (should (seshat-reader-annotation-queue-enqueue
                 (seshat-reader-annotation-queue-test--create-entry
                  "lib:a.pdf" seshat-reader-annotation-queue-test--loc2 "2")))
        (should-not (seshat-reader-annotation-queue-enqueue
                     (seshat-reader-annotation-queue-test--create-entry
                      "lib:a.pdf" "page:3;rect:0.00,0.00,1.00,1.00" "3"))))
      (should (= (seshat-reader-annotation-queue-count) 2))
      (should (= (length (seshat-reader-annotation-queue--read)) 2)))))

(ert-deftest seshat-reader-annotation-queue-test--read-corrupt-file-errors-without-touching ()
  "损坏文件：`--read' 抛 error，且文件内容未被修改."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let ((broken "(:uuid \"x\""))
      (with-temp-file queue-file (insert broken))
      (should-error (seshat-reader-annotation-queue--read) :type 'error)
      (with-temp-buffer
        (insert-file-contents queue-file)
        (should (equal (buffer-string) broken))))))

(ert-deftest seshat-reader-annotation-queue-test--read-non-list-errors-without-touching ()
  "非 list 内容（写入 `42'）：`--read' 抛 error，且文件内容未被修改."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (with-temp-file queue-file (insert "42"))
    (should-error (seshat-reader-annotation-queue--read) :type 'error)
    (with-temp-buffer
      (insert-file-contents queue-file)
      (should (equal (buffer-string) "42")))))

;;; B. 同步 `-sync'

(ert-deftest seshat-reader-annotation-queue-test--sync-all-success ()
  "全部成功：`-sync' 返回 (N . 0) 且队列清空."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "lib:a.pdf" seshat-reader-annotation-queue-test--loc1 "1"))
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "lib:a.pdf" seshat-reader-annotation-queue-test--loc2 "2"))
    (let ((result nil))
      (seshat-reader-annotation-queue-test--with-fetch
          (lambda (_doc) nil)
        (ignore
         (seshat-reader-annotation-queue-test--with-stub 201 "{\"id\":1}"
           (setq result (seshat-reader-annotation-queue-sync)))))
      (should (equal result '(2 . 0)))
      (should (= (seshat-reader-annotation-queue-count) 0)))))

(ert-deftest seshat-reader-annotation-queue-test--sync-service-unavailable-keeps-queue ()
  "服务不可达（`--fetch' 哨兵）：成功数 0、队列条数不变、无异常."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "lib:a.pdf" seshat-reader-annotation-queue-test--loc1 "1"))
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "lib:a.pdf" seshat-reader-annotation-queue-test--loc2 "2"))
    (let ((result nil))
      (seshat-reader-annotation-queue-test--with-fetch
          (lambda (_doc) seshat-reader-annotation--fetch-error)
        (setq result (seshat-reader-annotation-queue-sync)))
      (should (equal result '(0 . 2)))
      (should (= (seshat-reader-annotation-queue-count) 2)))))

(ert-deftest seshat-reader-annotation-queue-test--sync-create-dedupe-no-request ()
  "已存在的 create 条目（同 location 与 text）：视为成功且 `--request' 未被调用."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let* ((location seshat-reader-annotation-queue-test--loc1)
           (text "已有正文"))
      (seshat-reader-annotation-queue-enqueue
       (seshat-reader-annotation-queue-test--create-entry "lib:a.pdf" location text))
      (let ((result nil)
            (requests nil))
        (seshat-reader-annotation-queue-test--with-fetch
            (lambda (_doc) (list (list (cons 'location location) (cons 'text text))))
          (setq requests
                (seshat-reader-annotation-queue-test--with-stub 500 ""
                  (setq result (seshat-reader-annotation-queue-sync)))))
        (should (= (length requests) 0))
        (should (equal result '(1 . 0)))
        (should (= (seshat-reader-annotation-queue-count) 0))))))

(ert-deftest seshat-reader-annotation-queue-test--sync-delete-404-success ()
  "删除条目时服务端返回 404：视为成功并移除条目."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue (list :action 'delete :id 7))
    (let ((result nil)
          (requests nil))
      (setq requests
            (seshat-reader-annotation-queue-test--with-stub 404 ""
              (setq result (seshat-reader-annotation-queue-sync))))
      (should (= (length requests) 1))
      (should (equal (nth 0 (car requests)) "DELETE"))
      (should (equal (nth 1 (car requests)) "/api/annotations/7"))
      (should (equal result '(1 . 0)))
      (should (= (seshat-reader-annotation-queue-count) 0)))))

(ert-deftest seshat-reader-annotation-queue-test--sync-concurrent-enqueue-preserved ()
  "桩 `--fetch' 期间并发入队的新条目在同步后仍在队列中."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "lib:a.pdf" seshat-reader-annotation-queue-test--loc1 "原始"))
    (let ((injected nil)
          (result nil))
      (seshat-reader-annotation-queue-test--with-fetch
          (lambda (_doc)
            (unless injected
              (setq injected t)
              (seshat-reader-annotation-queue-enqueue
               (seshat-reader-annotation-queue-test--create-entry
                "lib:a.pdf" "page:9;rect:0.00,0.00,1.00,1.00" "并发")))
            nil)
        (ignore
         (seshat-reader-annotation-queue-test--with-stub 201 "{\"id\":1}"
           (setq result (seshat-reader-annotation-queue-sync)))))
      (should (equal (car result) 1))
      (should (= (seshat-reader-annotation-queue-count) 1))
      (let ((entries (seshat-reader-annotation-queue--read)))
        (should (= (length entries) 1))
        (should (equal (plist-get (car entries) :text) "并发"))))))

(ert-deftest seshat-reader-annotation-queue-test--sync-delete-500-retains-400-discards ()
  "`--sync-delete'：500 保留条目（stop）；400 丢弃该条且不阻塞后续条目."
  ;; 500：条目保留，成功数 0、队列仍 1 条
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue (list :action 'delete :id 7))
    (let ((result nil))
      (ignore
       (seshat-reader-annotation-queue-test--with-stub 500 ""
         (setq result (seshat-reader-annotation-queue-sync))))
      (should (equal result '(0 . 1)))
      (should (= (seshat-reader-annotation-queue-count) 1))))
  ;; 400：坏 id 条被终态丢弃，其后的正常条成功同步（不再被永久阻塞）
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue (list :action 'delete :id "bad"))
    (seshat-reader-annotation-queue-enqueue (list :action 'delete :id 8))
    (let ((result nil)
          (paths nil))
      (cl-letf (((symbol-function 'seshat-rest--request)
                 (lambda (_method path &optional _body)
                   (push path paths)
                   (if (string-suffix-p "/bad" path)
                       (cons 400 "{}")
                     (cons 200 "{}")))))
        (setq result (seshat-reader-annotation-queue-sync)))
      (should (equal result '(2 . 0)))
      (should (= (length paths) 2))
      (should (= (seshat-reader-annotation-queue-count) 0)))))

;;; B2. 旧队列条目（无 `:uid'）

(ert-deftest seshat-reader-annotation-queue-test--sync-skips-legacy-entry-without-uid ()
  "缺 `:uid' 的旧 create 条目被跳过（不移除）且只提示一次，后续条目照常同步."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (list :action 'create :document-id "notes:legacy.pdf"
           :location seshat-reader-annotation-queue-test--loc1 :text "旧一"))
    (seshat-reader-annotation-queue-enqueue
     (list :action 'create :document-id "notes:legacy.pdf"
           :location seshat-reader-annotation-queue-test--loc2 :text "旧二"))
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      seshat-reader-annotation-queue-test--uid
      "page:3;rect:0.00,0.00,1.00,1.00" "新条目"))
    (let ((result nil)
          (messages nil)
          (requests nil))
      (setq messages
            (seshat-reader-annotation-queue-test--capture-messages
              (seshat-reader-annotation-queue-test--with-fetch (lambda (_uid) nil)
                (setq requests
                      (seshat-reader-annotation-queue-test--with-stub
                          201 "{\"id\":1}"
                        (setq result
                              (seshat-reader-annotation-queue-sync)))))))
      ;; 只有带 uid 的那条同步成功，两条旧条目仍留在队列
      (should (equal result '(1 . 2)))
      (should (= (length requests) 1))
      (should (string-match-p
               (regexp-quote seshat-reader-annotation-queue-test--uid)
               (nth 2 (car requests))))
      ;; 提示只发一次（而不是每条旧条目各一次）
      (should (= 1 (length (cl-remove-if-not
                            (lambda (msg)
                              (string-match-p "旧队列条目缺少 uid" msg))
                            messages)))))))

;;; C. 接入点（`seshat-reader-annotation'）

(ert-deftest seshat-reader-annotation-queue-test--create-offline-enqueues-both-paths ()
  "离线创建（桩抛 error / 桩返回 500）均入队且条目带 uid，提示不含「不可用」."
  (dolist (mode '(error http-500))
    (seshat-reader-annotation-queue-test--with-temp-queue queue-file
      (seshat-reader-annotation-queue-test--with-temp-dir dir
        (let* ((file (expand-file-name "book.pdf" dir))
               (seshat-reader-annotation-roots (list (cons "lib" dir)))
               (seshat-reader-select-last
                (list :file file :page 1 :rect '(0 0 1 1) :text "离线正文")))
          (with-temp-file file)
          (cl-letf (((symbol-function 'seshat-reader-annotation--uid)
                     (lambda (&rest _)
                       seshat-reader-annotation-queue-test--uid)))
            (let ((messages
                   (seshat-reader-annotation-queue-test--capture-messages
                     (pcase mode
                       ('error
                        (cl-letf (((symbol-function 'seshat-rest--request)
                                   (lambda (&rest _) (error "Network down"))))
                          (seshat-reader-annotation-create)))
                       ('http-500
                        (ignore
                         (seshat-reader-annotation-queue-test--with-stub
                             500 "{\"error\":{}}"
                           (seshat-reader-annotation-create))))))))
              (should (= (seshat-reader-annotation-queue-count) 1))
              (should messages)
              (should-not (cl-some (lambda (m) (string-match-p "不可用" m))
                                   messages))
              ;; 入队条目同时带 uid（供同步）与 doc-id（供显示）
              (let ((entry (car (seshat-reader-annotation-queue--read))))
                (should (equal (plist-get entry :uid)
                               seshat-reader-annotation-queue-test--uid))
                (should (equal (plist-get entry :document-id)
                               "lib:book.pdf"))))))))))

(ert-deftest seshat-reader-annotation-queue-test--create-online-empty-queue-no-sync ()
  "在线创建成功 + 队列为空：队列仍空、未触发 sync."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-test--with-temp-dir dir
      (let* ((file (expand-file-name "book.pdf" dir))
             (seshat-reader-annotation-roots (list (cons "lib" dir)))
             (seshat-reader-select-last
              (list :file file :page 1 :rect '(0 0 1 1) :text "在线正文"))
             (sync-calls nil)
             (requests nil))
        (with-temp-file file)
        (cl-letf (((symbol-function 'seshat-reader-annotation--uid)
                   (lambda (&rest _)
                     seshat-reader-annotation-queue-test--uid)))
          (setq requests
                (seshat-reader-annotation-queue-test--with-stub 201 "{\"id\":9}"
                  (setq sync-calls
                        (seshat-reader-annotation-queue-test--with-sync-spy
                          (seshat-reader-annotation-create))))))
        (should (= (length requests) 1))
        (should-not sync-calls)
        (should (= (seshat-reader-annotation-queue-count) 0))))))

(ert-deftest seshat-reader-annotation-queue-test--create-online-nonempty-queue-triggers-sync ()
  "在线创建成功 + 队列非空：触发一次 sync."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "01K8Q3M7D2X9V6T1B8N5C0RDEZ" seshat-reader-annotation-queue-test--loc1 "旧项"))
    (seshat-reader-annotation-queue-test--with-temp-dir dir
      (let* ((file (expand-file-name "book.pdf" dir))
             (seshat-reader-annotation-roots (list (cons "lib" dir)))
             (seshat-reader-select-last
              (list :file file :page 2 :rect '(0 0 1 1) :text "在线正文"))
             (sync-calls nil))
        (with-temp-file file)
        (cl-letf (((symbol-function 'seshat-reader-annotation--uid)
                   (lambda (&rest _)
                     seshat-reader-annotation-queue-test--uid)))
          (ignore
           (seshat-reader-annotation-queue-test--with-stub 201 "{\"id\":9}"
             (setq sync-calls
                   (seshat-reader-annotation-queue-test--with-sync-spy
                     (seshat-reader-annotation-create))))))
        (should (= (length sync-calls) 1))))))

(ert-deftest seshat-reader-annotation-queue-test--list-offline-renders-queued ()
  "离线 list：`--fetch' 哨兵 + 队列 1 条 create → 渲染该条并含 [待同步]."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-test--with-temp-dir dir
      (let* ((file (expand-file-name "book.pdf" dir))
             (seshat-reader-annotation-roots (list (cons "lib" dir)))
             (uid seshat-reader-annotation-queue-test--uid))
        (with-temp-file file)
        (let ((messages nil))
          (seshat-reader-annotation-queue-enqueue
           (seshat-reader-annotation-queue-test--create-entry
            uid "page:4;rect:0.00,0.00,1.00,1.00" "本地待同步"))
          (setq messages
                (seshat-reader-annotation-queue-test--capture-messages
                  (seshat-reader-annotation-queue-test--with-fetch
                      (lambda (_uid) seshat-reader-annotation--fetch-error)
                    (cl-letf (((symbol-function 'seshat-reader-annotation--uid)
                               (lambda (&rest _) uid)))
                      (with-temp-buffer
                        (setq buffer-file-name file)
                        (seshat-reader-annotation-list))))))
          (with-current-buffer (get-buffer seshat-reader-annotation-list-buffer-name)
            (should (string-match-p "本地待同步" (buffer-string)))
            (should (string-match-p "\\[待同步\\]" (buffer-string)))
            ;; 双值：uid 供刷新，doc-id 供显示
            (should (equal seshat-reader-annotation-list-uid uid))
            (should (equal seshat-reader-annotation-list-document-id
                           "lib:book.pdf")))
          (should messages)
          (should-not (cl-some (lambda (m) (string-match-p "不可用" m))
                               messages)))))))

(ert-deftest seshat-reader-annotation-queue-test--list-online-server-and-local ()
  "在线 list：服务端项在前、本地项在后；本地行带 queue-uuid 属性、服务端行无."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-test--with-temp-dir dir
      (let* ((file (expand-file-name "book.pdf" dir))
             (seshat-reader-annotation-roots (list (cons "lib" dir)))
             (uid seshat-reader-annotation-queue-test--uid))
        (with-temp-file file)
        (seshat-reader-annotation-queue-enqueue
         (seshat-reader-annotation-queue-test--create-entry
          uid "page:9;rect:0.00,0.00,1.00,1.00" "本地项"))
        (let ((server (list (list (cons 'id 5)
                                  (cons 'location "page:2;rect:0.00,0.00,1.00,1.00")
                                  (cons 'text "服务端项")))))
          (cl-letf (((symbol-function 'seshat-reader-annotation--fetch)
                     (lambda (_uid) server))
                    ((symbol-function 'seshat-reader-annotation--uid)
                     (lambda (&rest _) uid))
                    ((symbol-function 'seshat-reader-annotation-queue-sync) #'ignore))
            (with-temp-buffer
              (setq buffer-file-name file)
              (seshat-reader-annotation-list))))
        (with-current-buffer (get-buffer seshat-reader-annotation-list-buffer-name)
          (should (= (count-lines (point-min) (point-max)) 2))
          (goto-char (point-min))
          (should (equal (get-text-property (point) 'seshat-reader-annotation-id) 5))
          (should-not (get-text-property (point) 'seshat-reader-annotation-queue-uuid))
          (forward-line 1)
          (should (stringp (get-text-property (point)
                                              'seshat-reader-annotation-queue-uuid)))
          (should-not (get-text-property (point) 'seshat-reader-annotation-id)))))))

(ert-deftest seshat-reader-annotation-queue-test--list-delete-local-item-no-http ()
  "删除本地待同步项：不发起 HTTP（桩 `--request' 0 次），队列项被移除."
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let* ((entry (seshat-reader-annotation-queue-enqueue
                   (seshat-reader-annotation-queue-test--create-entry
                    seshat-reader-annotation-queue-test--uid
                    seshat-reader-annotation-queue-test--loc1 "本地项")))
           (uuid (plist-get entry :uuid)))
      (with-temp-buffer
        (seshat-reader-annotation-list-mode)
        (let ((inhibit-read-only t))
          (insert (propertize "  1  本地项  [待同步]\n"
                              'seshat-reader-annotation-queue-uuid uuid)))
        (goto-char (point-min))
        (setq-local seshat-reader-annotation-list-uid
                    seshat-reader-annotation-queue-test--uid)
        (setq-local seshat-reader-annotation-list-document-id "lib:book.pdf")
        (setq-local seshat-reader-annotation-list-source nil)
        (setq-local seshat-reader-annotation-list-entries nil)
        (let ((requests
               (seshat-reader-annotation-queue-test--with-stub
                   200 "{}"
                 (seshat-reader-annotation-list-delete))))
          (should (= (length requests) 0))))
      (should (= (seshat-reader-annotation-queue-count) 0)))))

;;; D. 自动同步接线

(ert-deftest seshat-reader-annotation-queue-test--enable-timer-idempotent ()
  "连续两次 `-enable-timer' 只保留一个活跃周期定时器."
  (let ((seshat-reader-annotation-queue--timer nil)
        (seshat-reader-annotation-queue-initial-delay 3600)
        (seshat-reader-annotation-queue-sync-interval 3600))
    (unwind-protect
        (progn
          (seshat-reader-annotation-queue-enable-timer)
          (should (timerp seshat-reader-annotation-queue--timer))
          (should (memq seshat-reader-annotation-queue--timer timer-list))
          (let ((first seshat-reader-annotation-queue--timer))
            (seshat-reader-annotation-queue-enable-timer)
            (should (timerp seshat-reader-annotation-queue--timer))
            (should (memq seshat-reader-annotation-queue--timer timer-list))
            ;; 第二次启用会取消并替换第一次的周期定时器
            (should-not (eq seshat-reader-annotation-queue--timer first))))
      (seshat-reader-annotation-queue-disable-timer))))

(ert-deftest seshat-reader-annotation-queue-test--disable-then-enable-recreates-timer ()
  "`-disable-timer' 后 `--timer' 为 nil；再次 enable 重新建立."
  (let ((seshat-reader-annotation-queue--timer nil)
        (seshat-reader-annotation-queue-initial-delay 3600)
        (seshat-reader-annotation-queue-sync-interval 3600))
    (unwind-protect
        (progn
          (seshat-reader-annotation-queue-enable-timer)
          (should (timerp seshat-reader-annotation-queue--timer))
          (seshat-reader-annotation-queue-disable-timer)
          (should-not seshat-reader-annotation-queue--timer)
          (seshat-reader-annotation-queue-enable-timer)
          (should (timerp seshat-reader-annotation-queue--timer)))
      (seshat-reader-annotation-queue-disable-timer))))

(ert-deftest seshat-reader-annotation-queue-test--enable-timer-auto-sync-nil-creates-none ()
  "`-auto-sync' 为 nil 时 `-enable-timer' 不创建定时器（桩 `run-with-timer' 0 次）."
  (let ((seshat-reader-annotation-queue--timer nil)
        (seshat-reader-annotation-queue-auto-sync nil)
        (run-calls 0))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _) (cl-incf run-calls) nil)))
      (seshat-reader-annotation-queue-enable-timer))
    (should (= run-calls 0))
    (should-not seshat-reader-annotation-queue--timer)))

(ert-deftest seshat-reader-annotation-queue-test--enable-timer-wiring-args ()
  "接线参数：首次延迟 = `-initial-delay'，周期延迟与间隔 = `-sync-interval'."
  (let ((seshat-reader-annotation-queue--timer nil)
        (seshat-reader-annotation-queue-initial-delay 42)
        (seshat-reader-annotation-queue-sync-interval 99)
        (calls nil))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest args) (push args calls) (list 'fake-timer))))
      (seshat-reader-annotation-queue-enable-timer))
    (setq calls (nreverse calls))
    (should (= (length calls) 2))
    (should (equal (nth 0 calls)
                   (list 42 nil #'seshat-reader-annotation-queue--timer-sync)))
    (should (equal (nth 1 calls)
                   (list 99 99 #'seshat-reader-annotation-queue--timer-sync)))
    (should (equal seshat-reader-annotation-queue--timer (list 'fake-timer)))))

(ert-deftest seshat-reader-annotation-queue-test--enable-timer-twice-no-accumulation ()
  "连续两次 `-enable-timer'：one-shot 与周期定时器都不累积；disable 后两者均 nil."
  (let ((seshat-reader-annotation-queue--initial-timer nil)
        (seshat-reader-annotation-queue--timer nil)
        (seshat-reader-annotation-queue-initial-delay 3600)
        (seshat-reader-annotation-queue-sync-interval 3600)
        (run-calls 0))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _) (cl-incf run-calls) (list 'fake-timer))))
      (seshat-reader-annotation-queue-enable-timer)
      (should (= run-calls 2))
      (should seshat-reader-annotation-queue--initial-timer)
      (should seshat-reader-annotation-queue--timer)
      (seshat-reader-annotation-queue-enable-timer)
      ;; 第二次 enable 先 disable（不新增定时器）再建 2 个 → 累计 4 个
      (should (= run-calls 4))
      (should seshat-reader-annotation-queue--initial-timer)
      (should seshat-reader-annotation-queue--timer))
    (seshat-reader-annotation-queue-disable-timer)
    (should-not seshat-reader-annotation-queue--initial-timer)
    (should-not seshat-reader-annotation-queue--timer)))

(ert-deftest seshat-reader-annotation-queue-test--timer-sync-swallows-error-and-skips-empty ()
  "`--timer-sync'：`-sync' 抛 error 时不冒泡；队列为空时不调用 `-sync'."
  ;; 队列非空且 -sync 抛 error：错误被吞掉并 message 一行
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (seshat-reader-annotation-queue-enqueue
     (seshat-reader-annotation-queue-test--create-entry
      "lib:b.pdf" seshat-reader-annotation-queue-test--loc1 "x"))
    (let ((messages nil)
          (signalled nil))
      (cl-letf (((symbol-function 'seshat-reader-annotation-queue-sync)
                 (lambda (&rest _) (error "Boom")))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (condition-case nil
            (seshat-reader-annotation-queue--timer-sync)
          (error (setq signalled t))))
      (should-not signalled)
      (should messages)
      (should (string-match-p "定时自动同步失败" (car messages)))))
  ;; 队列为空：不调用 -sync
  (seshat-reader-annotation-queue-test--with-temp-queue queue-file
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'seshat-reader-annotation-queue-sync)
                 (lambda (&rest _) (setq sync-called t))))
        (seshat-reader-annotation-queue--timer-sync))
      (should-not sync-called))))

(provide 'seshat-reader-annotation-queue-test)
;;; seshat-reader-annotation-queue-test.el ends here
