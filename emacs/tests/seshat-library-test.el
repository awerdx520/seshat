;;; seshat-library-test.el --- ERT tests for seshat-library  -*- lexical-binding: t; -*-

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

;; `seshat-library' 数据层的 ERT 测试（M8-C T1）：`ondemand' 根的远端清单读取
;; （`:since-mtime' 翻页、同秒超页只提示一次、非 2xx 降级为 nil）、本地三态判定
;; 与六步取书事务。
;;
;; 全部用例**零网络、零真实状态文件**：
;;
;; - `seshat-rest-list-resources' / `seshat-rest-get-resource' /
;;   `seshat-rest-download-file' 一律 `cl-letf' 桩替，并记录实参——断言的是
;;   被测代码**传了什么**（`:root' / `:since-mtime' / `:limit'、`root'/`target'
;;   关键字实参），而不是被桩函数的行为；
;; - `seshat-state-*' 只在取书用例里桩替「有副作用的两处」（`state-save' 计入
;;   次数、`set-base-blob' / `event-set-location' 包一层记录后**转调真实实现**），
;;   因此「blob 恒为空串」「size / mtime 取本地 `file-attributes'」这类断言跑的是
;;   真状态库逻辑；
;; - `seshat-sync--root-dir' / `seshat-sync--local-path' 同样「记录 + 转调真实
;;   实现」：路径越界用例因此走的是真实的 `file-truename' 校验，不是被桩掉的
;;   口径；
;; - 状态库绑到临时目录里的 `state.eld'，**绝不写用户的
;;   `~/.local/share/seshat/'**；临时目录在每例收尾递归删除。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-state)
(require 'seshat-sync)
(require 'seshat-library)

;;; 测试辅助

(defvar seshat-library-test--dir nil
  "当前用例的临时目录（带结尾斜杠）.")

(defvar seshat-library-test--calls nil
  "本次用例的调用记录，元素为 `(NAME ARG ...)'，按调用发生的顺序累积.")

(defvar seshat-library-test--pages nil
  "排队等待消费的 `/api/resources' 响应列表（先进先出）.
队列耗尽时回一个空页，既能让用例收尾，也能在「本该翻页却没翻」时通过调用
次数断言暴露问题（而不是让用例挂死）。")

(defvar seshat-library-test--warnings nil
  "本次用例中被桩的 `display-warning' 收到的实参列表（反向累积）.")

(defvar seshat-library-test--messages nil
  "本次用例中被桩的 `message' 收到的实参列表（反向累积）.")

(defvar seshat-library-test--location nil
  "取书用例中 `seshat-state-path-for-uid' 的返回值（`(ROOT . PATH)' 或 nil）.")

(defvar seshat-library-test--resource-response nil
  "取书用例中 `seshat-rest-get-resource' 的返回值.")

(defvar seshat-library-test--download-handler nil
  "取书用例中 `seshat-rest-download-file' 的处理函数，接收 (PATH TARGET ROOT).
nil 表示「下载成功但不落盘」，返回 `(:status 200)'.")

(defvar seshat-library-test--saves 0
  "本次用例中 `seshat-state-save' 被调用的次数.")

(defun seshat-library-test--record (name &rest args)
  "把一次调用 NAME 与实参 ARGS 追加进本次用例的调用记录."
  (setq seshat-library-test--calls
        (append seshat-library-test--calls (list (cons name args)))))

(defun seshat-library-test--call-names ()
  "返回本次用例的调用名序列（按发生顺序）."
  (mapcar #'car seshat-library-test--calls))

(defun seshat-library-test--call-count (name)
  "返回本次用例中 NAME 被调用的次数."
  (seq-count (lambda (call) (eq (car call) name)) seshat-library-test--calls))

(defun seshat-library-test--call-arg (n key)
  "返回第 N 次调用（从 0 起）的第一个 plist 实参里 KEY 的值.
只对以 plist 为唯一实参的被桩函数有意义（`seshat-rest-list-resources' 的
`&key' 调用在 `&rest' 桩里表现为单个 plist）。"
  (plist-get (nth 1 (nth n seshat-library-test--calls)) key))

(defmacro seshat-library-test--with-temp-dir (&rest body)
  "在干净状态库与临时目录的上下文中执行 BODY，收尾删除临时目录.
`seshat-state-file' 指向临时目录里的 `state.eld'、`seshat-state--state' 绑成
nil（干净起点），因此用例绝不会读写用户的真实状态库。"
  (declare (indent 0) (debug t))
  `(let* ((seshat-library-test--dir
           (file-name-as-directory (make-temp-file "seshat-library-test-" t)))
          (seshat-state-file
           (expand-file-name "state.eld" seshat-library-test--dir))
          (seshat-state--state nil)
          (seshat-library-test--calls nil)
          (seshat-library-test--pages nil)
          (seshat-library-test--warnings nil)
          (seshat-library-test--messages nil)
          (seshat-library-test--location nil)
          (seshat-library-test--resource-response nil)
          (seshat-library-test--download-handler nil)
          (seshat-library-test--saves 0))
     (unwind-protect
         (cl-letf (((symbol-function 'display-warning)
                    (lambda (&rest args)
                      (push args seshat-library-test--warnings)
                      nil))
                   ((symbol-function 'message)
                    (lambda (&rest args)
                      (push args seshat-library-test--messages)
                      nil)))
           ,@body)
       (delete-directory seshat-library-test--dir t))))

(defmacro seshat-library-test--with-fetch-stubs (&rest body)
  "在取书事务的六个协作者被桩替后执行 BODY.
网络协作者（`seshat-rest-get-resource' / `seshat-rest-download-file'）被完全
桩替并记录实参；本地协作者（`seshat-sync--root-dir' / `seshat-sync--local-path' /
`seshat-sync--event-set-location' / `seshat-state-set-base-blob'）**记录后转调
真实实现**，因此越界校验与状态写入走的都是真代码。`seshat-state-save' 只计数
（避免用例产生真实落盘，同时可断言「落盘一次」）。"
  (declare (indent 0) (debug t))
  `(let ((orig-root-dir (symbol-function 'seshat-sync--root-dir))
         (orig-local-path (symbol-function 'seshat-sync--local-path))
         (orig-set-location (symbol-function 'seshat-sync--event-set-location))
         (orig-set-base-blob (symbol-function 'seshat-state-set-base-blob)))
     (cl-letf (((symbol-function 'seshat-state-path-for-uid)
                (lambda (uid)
                  (seshat-library-test--record 'state-path-for-uid uid)
                  seshat-library-test--location))
               ((symbol-function 'seshat-rest-get-resource)
                (lambda (uid)
                  (seshat-library-test--record 'get-resource uid)
                  seshat-library-test--resource-response))
               ((symbol-function 'seshat-rest-download-file)
                (lambda (path target &rest args)
                  (seshat-library-test--record 'download path target args)
                  (if seshat-library-test--download-handler
                      (funcall seshat-library-test--download-handler
                               path target (plist-get args :root))
                    (list :status 200))))
               ((symbol-function 'seshat-sync--root-dir)
                (lambda (root)
                  (seshat-library-test--record 'root-dir root)
                  (funcall orig-root-dir root)))
               ((symbol-function 'seshat-sync--local-path)
                (lambda (root-dir path)
                  (seshat-library-test--record 'local-path root-dir path)
                  (funcall orig-local-path root-dir path)))
               ((symbol-function 'seshat-sync--event-set-location)
                (lambda (uid root path)
                  (seshat-library-test--record 'event-set-location uid root path)
                  (funcall orig-set-location uid root path)))
               ((symbol-function 'seshat-state-set-base-blob)
                (lambda (uid blob size mtime)
                  (seshat-library-test--record 'set-base-blob uid blob size mtime)
                  (funcall orig-set-base-blob uid blob size mtime)))
               ((symbol-function 'seshat-state-save)
                (lambda ()
                  (seshat-library-test--record 'state-save)
                  (setq seshat-library-test--saves (1+ seshat-library-test--saves))
                  t)))
       ,@body)))

(defun seshat-library-test--item (uid mtime &optional path)
  "构造一个最小可用的远端 item plist：UID / MTIME / PATH（默认由 UID 派生）."
  (list :uid uid :root "books" :path (or path (concat uid ".pdf"))
        :kind "file" :blob "" :rev 1 :size 10 :mtime mtime
        :created-at 0 :updated-at 0 :deleted-at ""))

(defun seshat-library-test--write-file (path content)
  "把 CONTENT 写入绝对路径 PATH（先建父目录），返回 PATH."
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert content))
  path)

(defun seshat-library-test--read-file (path)
  "读取绝对路径 PATH 的全部文本内容（用于断言「文件未被改动」）。"
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defconst seshat-library-test--uids
  '(("u1" . "01J8ZKQ2AAAAAAAAAAAAAAAAV1")
    ("u2" . "01J8ZKQ2AAAAAAAAAAAAAAAAV2")
    ("u3" . "01J8ZKQ2AAAAAAAAAAAAAAAAV3")
    ("u-book" . "01J8ZKQ2AAAAAAAAAAAAAAAAVB")
    ("u-media" . "01J8ZKQ2AAAAAAAAAAAAAAAAVM")
    ("u-unknown" . "01J8ZKQ2AAAAAAAAAAAAAAAAVX")
    ("u-gone" . "01J8ZKQ2AAAAAAAAAAAAAAAAVG"))
  "测试短标签到**合法 uid 形态**（26 位 Crockford Base32）的映射。
`seshat-library--collect' 会丢弃形态不合法的 uid（安全修复 A5），书架 UI 用例的
fixture 因此必须提供真形态 uid；短标签只为可读性而保留，断言侧用
`seshat-library-test--label' 映射回标签。")

(defun seshat-library-test--uid (label)
  "把短标签 LABEL 映射为合法 uid；不在映射表里的值原样返回（便于构造非法 uid）。"
  (or (cdr (assoc label seshat-library-test--uids)) label))

(defun seshat-library-test--label (uid)
  "把合法 uid UID 映射回短标签；不在映射表里的 uid 原样返回。"
  (or (car (rassoc uid seshat-library-test--uids)) uid))

;;; seshat-library--roots

(ert-deftest seshat-library--roots-filters-ondemand ()
  "`seshat-library--roots' 只返回 mode 为 \"ondemand\" 的根，mirror 根被过滤掉."
  (cl-letf (((symbol-function 'seshat-state-roots)
             (lambda ()
               '(("books" "/tmp/books/" "ondemand")
                 ("notes" "/tmp/notes/" "mirror")
                 ("media" "/tmp/media/" "ondemand")))))
    (should (equal (seshat-library--roots)
                   '(("books" "/tmp/books/" "ondemand")
                     ("media" "/tmp/media/" "ondemand"))))))

(ert-deftest seshat-library--roots-keeps-unconfigured-dir ()
  "DIR 为 nil 或空串的 ondemand 根**保留**在返回值里（供上层给出可见提示），
不会被静默丢弃，也不会被当成 mirror 根过滤掉。"
  (cl-letf (((symbol-function 'seshat-state-roots)
             (lambda ()
               '(("no-dir" nil "ondemand")
                 ("empty-dir" "" "ondemand")))))
    (should (equal (seshat-library--roots)
                   '(("no-dir" nil "ondemand")
                     ("empty-dir" "" "ondemand"))))))

;;; seshat-library--remote-entries

(ert-deftest seshat-library--remote-entries-pages-until-no-more ()
  "`seshat-library--remote-entries' 按 `:has-more' 翻页：两页响应恰发两次请求，
返回值是两页 item 的拼接。"
  (seshat-library-test--with-temp-dir
    (let ((seshat-library-test--pages
           (list (list :status 200 :has-more t
                       :items (list (seshat-library-test--item "u1" 100)))
                 (list :status 200 :has-more nil
                       :items (list (seshat-library-test--item "u2" 200))))))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (or (pop seshat-library-test--pages)
                       (list :status 200 :items nil :has-more nil)))))
        (let ((items (seshat-library--remote-entries "books" "sub/")))
          (should (= 2 (seshat-library-test--call-count 'list)))
          (should (equal '("u1" "u2") (mapcar (lambda (i) (plist-get i :uid)) items)))
          (should (equal "books" (seshat-library-test--call-arg 0 :root)))
          (should (equal "sub/" (seshat-library-test--call-arg 0 :prefix)))
          (should (= 2000 (seshat-library-test--call-arg 0 :limit)))
          (should (= 0 (seshat-library-test--call-arg 0 :since-mtime))))))))

(ert-deftest seshat-library--remote-entries-advances-since-mtime-per-page ()
  "第二页请求的 `:since-mtime' 等于首页最后一项的 `:mtime'（游标前进的唯一来源）."
  (seshat-library-test--with-temp-dir
    (let ((seshat-library-test--pages
           (list (list :status 200 :has-more t
                       :items (list (seshat-library-test--item "u1" 100)
                                    (seshat-library-test--item "u2" 137)))
                 (list :status 200 :has-more nil
                       :items (list (seshat-library-test--item "u3" 200))))))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (or (pop seshat-library-test--pages)
                       (list :status 200 :items nil :has-more nil)))))
        (should (= 3 (length (seshat-library--remote-entries "books"))))
        (should (= 2 (seshat-library-test--call-count 'list)))
        (should (= 137 (seshat-library-test--call-arg 1 :since-mtime)))))))

(ert-deftest seshat-library--remote-entries-same-second-overflow-warns-once ()
  "同秒超页（本页末项 `:mtime' 不大于本次请求的 `:since-mtime'）时：游标强制
`(1+ mtime)' 前进，且整次调用只 `message' 提示一次。"
  (seshat-library-test--with-temp-dir
    (let ((seshat-library-test--pages
           (list (list :status 200 :has-more t
                       :items (list (seshat-library-test--item "u1" 100)))
                 ;; 第二页末项 mtime 与本次 since（100）相同 → 同秒超页
                 (list :status 200 :has-more t
                       :items (list (seshat-library-test--item "u2" 100)))
                 (list :status 200 :has-more nil
                       :items (list (seshat-library-test--item "u3" 200))))))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (or (pop seshat-library-test--pages)
                       (list :status 200 :items nil :has-more nil)))))
        (should (= 3 (length (seshat-library--remote-entries "books"))))
        (should (= 3 (seshat-library-test--call-count 'list)))
        ;; 第二页把 since 推进到 101，第三页据此请求
        (should (= 101 (seshat-library-test--call-arg 2 :since-mtime)))
        (should (= 1 (length seshat-library-test--messages)))))))

(ert-deftest seshat-library--remote-entries-empty-page-has-more-is-silent ()
  "`items' 为空但 `:has-more' 为真（异常响应）时游标靠 `(1+ since)' 前进，但
**不**提示——那不是「同秒超页」这一成因，提示只会误导用户。"
  (seshat-library-test--with-temp-dir
    (let ((seshat-library-test--pages
           (list (list :status 200 :has-more t :items nil)
                 (list :status 200 :has-more nil
                       :items (list (seshat-library-test--item "u1" 100))))))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (or (pop seshat-library-test--pages)
                       (list :status 200 :items nil :has-more nil)))))
        (should (= 1 (length (seshat-library--remote-entries "books"))))
        (should (= 2 (seshat-library-test--call-count 'list)))
        (should (= 1 (seshat-library-test--call-arg 1 :since-mtime)))
        (should (= 0 (length seshat-library-test--messages)))))))

(ert-deftest seshat-library--remote-entries-non-2xx-returns-nil ()
  "非 2xx（含传输失败时的 `:status' 为 nil）→ `display-warning' 一次并返回 nil，
不抛错、不重试（清单只是尽力而为，不能中断调用方）。"
  (seshat-library-test--with-temp-dir
    (let ((seshat-library-test--pages
           (list (list :status 500 :error "boom"))))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (or (pop seshat-library-test--pages)
                       (list :status 200 :items nil :has-more nil)))))
        (should-not (seshat-library--remote-entries "books"))
        (should (= 1 (seshat-library-test--call-count 'list)))
        (should (= 1 (length seshat-library-test--warnings)))))))

(ert-deftest seshat-library--remote-entries-transport-failure-returns-nil ()
  "传输失败（`:status' 为 nil）同样降级为 nil + 警告，不重试."
  (seshat-library-test--with-temp-dir
    (let ((seshat-library-test--pages (list (list :status nil :error "timeout"))))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (or (pop seshat-library-test--pages)
                       (list :status 200 :items nil :has-more nil)))))
        (should-not (seshat-library--remote-entries "books"))
        (should (= 1 (seshat-library-test--call-count 'list)))
        (should (= 1 (length seshat-library-test--warnings)))))))

;;; seshat-library--local-state

(ert-deftest seshat-library--local-state-unregistered ()
  "本地状态库查不到该 uid → `unregistered'（不发任何网络请求）."
  (seshat-library-test--with-temp-dir
    (let ((item (seshat-library-test--item "u-unknown" 100)))
      (cl-letf (((symbol-function 'seshat-state-path-for-uid)
                 (lambda (_uid) nil)))
        (should (eq 'unregistered (seshat-library--local-state item)))))))

(ert-deftest seshat-library--local-state-downloaded ()
  "已登记且本地文件存在 → `downloaded'."
  (seshat-library-test--with-temp-dir
    (let* ((item (seshat-library-test--item "u1" 100 "book.pdf"))
           (local (seshat-library-test--write-file
                   (expand-file-name "book.pdf" seshat-library-test--dir) "x")))
      (should (file-exists-p local))
      (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
      (seshat-state-set "u1" (list :root "books" :path "book.pdf"))
      (should (eq 'downloaded (seshat-library--local-state item))))))

(ert-deftest seshat-library--local-state-missing ()
  "已登记但本地文件不存在 → `missing'."
  (seshat-library-test--with-temp-dir
    (let ((item (seshat-library-test--item "u1" 100 "book.pdf")))
      (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
      (seshat-state-set "u1" (list :root "books" :path "book.pdf"))
      (should (eq 'missing (seshat-library--local-state item))))))

(ert-deftest seshat-library--local-state-unconfigured-root-is-missing ()
  "根未配置本地目录（`--root-dir' 为 nil）时判为 `missing'，不报错——取书是
用户的显式动作，书架只需要如实显示「本地没有」。"
  (seshat-library-test--with-temp-dir
    (let ((item (seshat-library-test--item "u1" 100 "book.pdf")))
      (seshat-state-set "u1" (list :root "books" :path "book.pdf"))
      (should (eq 'missing (seshat-library--local-state item))))))

;;; seshat-library-fetch
;;
;; 本段用例的 uid 一律写成 `(seshat-library-test--uid "u1")`：`seshat-library-fetch'
;; 开头有 uid 形态守卫（安全边界，见 `seshat-library--uid-valid-p'），短标签
;; `"u1"' 会被直接拒绝。状态库登记与调用记录里的 uid 因此也必须用同一映射值，
;; 否则「登记的是短标签、取书用真 uid」这种错配会让断言假绿。

(ert-deftest seshat-library-fetch-call-order ()
  "取书事务的六步顺序固定：`state-path-for-uid' → `root-dir' → `local-path'
→ `download' → `event-set-location' → `set-base-blob' → `state-save'。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "book.pdf"))
    (seshat-library-test--with-fetch-stubs
      (should (equal (expand-file-name "book.pdf" seshat-library-test--dir)
                     (seshat-library-fetch (seshat-library-test--uid "u1"))))
      (should (equal '(state-path-for-uid root-dir local-path download
                       event-set-location set-base-blob state-save)
                     (seshat-library-test--call-names)))
      ;; 网络步骤的实参也是契约的一部分
      (should (equal "book.pdf" (nth 1 (assq 'download seshat-library-test--calls))))
      (should (equal "books" (plist-get (nth 3 (assq 'download
                                                      seshat-library-test--calls))
                                        :root))))))

(ert-deftest seshat-library-fetch-unconfigured-root-errors ()
  "步骤 2：根未配置本地目录 → `user-error'（提示配置 `seshat-sync-roots'），
且**不发**下载请求。"
  (seshat-library-test--with-temp-dir
    (setq seshat-library-test--location (cons "books" "book.pdf"))
    (seshat-library-test--with-fetch-stubs
      (should-error (seshat-library-fetch (seshat-library-test--uid "u1")) :type 'user-error)
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 seshat-library-test--saves)))))

(ert-deftest seshat-library-fetch-path-escape-errors ()
  "步骤 3：服务端下发的路径越界 → `user-error'，且**不发**下载请求（安全底线）."
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "../escape.pdf"))
    (seshat-library-test--with-fetch-stubs
      (should-error (seshat-library-fetch (seshat-library-test--uid "u1")) :type 'user-error)
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 seshat-library-test--saves)))))

(ert-deftest seshat-library-fetch-existing-local-skips-download ()
  "步骤 4：本地已存在且 FORCE 为 nil → 直接返回本地路径，不下载、不写状态库."
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-state-set (seshat-library-test--uid "u1") (list :root "books" :path "book.pdf"))
    (let ((local (seshat-library-test--write-file
                  (expand-file-name "book.pdf" seshat-library-test--dir) "x")))
      (setq seshat-library-test--location (cons "books" "book.pdf"))
      (seshat-library-test--with-fetch-stubs
        (should (equal local (seshat-library-fetch (seshat-library-test--uid "u1"))))
        (should (= 0 (seshat-library-test--call-count 'download)))
        (should (= 0 seshat-library-test--saves))))))

(ert-deftest seshat-library-fetch-force-redownloads ()
  "FORCE 非 nil 时即使本地已有副本也重新下载并重申状态。
A2 之后「已有副本 + FORCE」会先 `yes-or-no-p' 确认，故此处把确认桩成 t
（拒绝的分支见 `seshat-library-fetch-force-confirm-declined'）。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-state-set (seshat-library-test--uid "u1") (list :root "books" :path "book.pdf"))
    (seshat-library-test--write-file
     (expand-file-name "book.pdf" seshat-library-test--dir) "old")
    (setq seshat-library-test--location (cons "books" "book.pdf"))
    (seshat-library-test--with-fetch-stubs
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
        (seshat-library-fetch (seshat-library-test--uid "u1") 'force))
      (should (= 1 (seshat-library-test--call-count 'download)))
      (should (= 1 seshat-library-test--saves)))))

(ert-deftest seshat-library-fetch-success-registers-state ()
  "成功路径：`event-set-location' 收到 (UID ROOT PATH)、`set-base-blob' 的 blob
恒为空串（`ondemand' 根没有 blob）、size / mtime 取落盘后本地 `file-attributes'、
状态库落盘一次，返回本地绝对路径。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "sub/book.pdf")
          seshat-library-test--download-handler
          (lambda (_path target _root)
            (seshat-library-test--write-file target "0123456789")
            (list :status 200)))
    (seshat-library-test--with-fetch-stubs
      (let ((local (expand-file-name "sub/book.pdf" seshat-library-test--dir)))
        (should (equal local (seshat-library-fetch (seshat-library-test--uid "u1"))))
        (let ((call (assq 'event-set-location seshat-library-test--calls)))
          (should (equal (seshat-library-test--uid "u1") (nth 1 call)))
          (should (equal "books" (nth 2 call)))
          (should (equal "sub/book.pdf" (nth 3 call))))
        (let ((call (assq 'set-base-blob seshat-library-test--calls)))
          (should (equal (seshat-library-test--uid "u1") (nth 1 call)))
          (should (equal "" (nth 2 call)))
          (should (= 10 (nth 3 call)))
          (should (integerp (nth 4 call))))
        (should (= 1 seshat-library-test--saves))
        ;; 真状态库里的结果（本地协作者是真实实现，故此处能读到真值）
        (let ((entry (seshat-state-get (seshat-library-test--uid "u1"))))
          (should (equal "books" (plist-get entry :root)))
          (should (equal "sub/book.pdf" (plist-get entry :path)))
          (should (equal "" (plist-get entry :base-blob))))))))

(ert-deftest seshat-library-fetch-download-failure-returns-nil ()
  "下载返回非 2xx → `display-warning' + nil，且不写状态库、不再发第二次请求."
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "book.pdf")
          seshat-library-test--download-handler
          (lambda (_path _target _root) (list :status 403 :read-only-root t)))
    (seshat-library-test--with-fetch-stubs
      (should-not (seshat-library-fetch (seshat-library-test--uid "u1")))
      (should (= 1 (seshat-library-test--call-count 'download)))
      (should (= 0 (seshat-library-test--call-count 'event-set-location)))
      (should (= 0 seshat-library-test--saves))
      (should (= 1 (length seshat-library-test--warnings))))))

(ert-deftest seshat-library-fetch-404-does-not-retry ()
  "本地无登记且服务端 404 → 只发一次 `GET /api/resources/{uid}' 后 `user-error'，
不重试、不下载。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--resource-response
          (list :status 404 :not-found t :resource nil))
    (seshat-library-test--with-fetch-stubs
      (should-error (seshat-library-fetch (seshat-library-test--uid "u-gone")) :type 'user-error)
      (should (= 1 (seshat-library-test--call-count 'get-resource)))
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 seshat-library-test--saves)))))

(ert-deftest seshat-library-fetch-falls-back-to-remote-metadata ()
  "本地无登记时用 `seshat-rest-get-resource' 的 `:root' / `:path' 补出位置并
取书（步骤 1 的兜底分支）。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--resource-response
          (list :status 200
                :resource (list :uid "u1" :root "books" :path "book.pdf")))
    (seshat-library-test--with-fetch-stubs
      (should (equal (expand-file-name "book.pdf" seshat-library-test--dir)
                     (seshat-library-fetch (seshat-library-test--uid "u1"))))
      (should (= 1 (seshat-library-test--call-count 'get-resource)))
      (should (= 1 (seshat-library-test--call-count 'download))))))

;;; ===========================================================================
;;; 书架 buffer（UI 层，M8-C T2）
;;; ===========================================================================
;;
;; 这一层的用例同样**零网络、零真实状态库**：`seshat-library--roots' /
;; `--remote-entries' / `--local-state' / `seshat-library-fetch' 四个上层协作者
;; 一律桩替并记录实参；`seshat-sync--root-dir' / `seshat-sync--local-path' 则是
;; 「记录后转调真实实现」——删除用例的越界校验因此走真代码，不是被桩掉的口径。
;; `pop-to-buffer' 桩替成只记录，避免 batch 下真的切窗口/选中窗口。
;;
;; 每个 UI 用例收尾都会杀掉 `*Seshat Library*' buffer：buffer 是全局状态，
;; 留着会让下一个用例读到上一例的 `tabulated-list-entries'。

(defvar seshat-library-test--ui-roots nil
  "UI 用例中 `seshat-library--roots' 的返回值（元素为 `(TAG DIR MODE)'）.")

(defvar seshat-library-test--ui-items nil
  "UI 用例中「根 tag → 远端 item 列表」的 alist（tag 用 `equal' 比较）.")

(defvar seshat-library-test--ui-states nil
  "UI 用例中「uid → 三态符号」的 alist；查不到按 `unregistered' 处理.")

(defvar seshat-library-test--ui-fetch-result nil
  "UI 用例中 `seshat-library-fetch' 的返回值（本地路径字符串或 nil）.")

(defvar seshat-library-test--ui-fetch-calls nil
  "UI 用例中 `seshat-library-fetch' 收到的 `(UID FORCE)' 列表（按调用顺序）.")

(defvar seshat-library-test--ui-delete-calls 0
  "UI 用例中 `seshat-rest-delete-file' 的调用次数（`ondemand' 根只读，必须恒为 0）.")

(defvar seshat-library-test--ui-location nil
  "UI 用例中 `seshat-state-path-for-uid' 的返回值（`(ROOT . PATH)' 或 nil）.")

(defun seshat-library-test--library-buffer ()
  "返回 `*Seshat Library*' buffer；不存在时报错（说明 `seshat-library' 没建 buffer）."
  (or (get-buffer "*Seshat Library*")
      (error "书架 buffer 未创建")))

(defun seshat-library-test--rows ()
  "返回书架 buffer 里 `tabulated-list-entries' 的行 ID 序列（映射回测试短标签）."
  (with-current-buffer (seshat-library-test--library-buffer)
    (mapcar (lambda (id) (seshat-library-test--label id))
            (mapcar #'car tabulated-list-entries))))

(defun seshat-library-test--row (uid)
  "返回书架 buffer 里 UID（短标签）对应的列向量 `[书名 根 大小 状态]'；不存在时返回 nil."
  (with-current-buffer (seshat-library-test--library-buffer)
    (cadr (assoc (seshat-library-test--uid uid) tabulated-list-entries))))

(defun seshat-library-test--row-status (uid)
  "返回书架 buffer 里 UID 那一行的状态列文案."
  (aref (seshat-library-test--row uid) 3))

(defun seshat-library-test--goto-row (uid)
  "把 point 移到书架 buffer 里 UID（短标签）那一行（缺行则报错）.
按 `tabulated-list-get-id'（行 ID）定位，不按「行里显示的文字」找：UID 只作为行
属性存在，正文里没有它（书名列显示的是文件名）。"
  (with-current-buffer (seshat-library-test--library-buffer)
    (goto-char (point-min))
    (let ((target (seshat-library-test--uid uid))
          (found nil))
      (while (and (not found) (not (eobp)))
        (if (equal target (tabulated-list-get-id))
            (setq found t)
          (forward-line 1)))
      (unless found
        (error "书架里找不到 uid %s 的行" uid)))))

(defmacro seshat-library-test--with-ui-stubs (&rest body)
  "在书架 UI 的协作者被桩替后执行 BODY（建议嵌在 `--with-temp-dir' 内）.
三层桩替口径与数据层用例一致：网络/上层协作者完全桩替并记录，纯本地的路径
校验函数记录后**转调真实实现**。收尾杀掉书架 buffer，避免跨用例污染。"
  (declare (indent 0) (debug t))
  `(let ((orig-root-dir (symbol-function 'seshat-sync--root-dir))
         (orig-local-path (symbol-function 'seshat-sync--local-path))
         (seshat-library-test--calls nil)
         (seshat-library-test--ui-roots nil)
         (seshat-library-test--ui-items nil)
         (seshat-library-test--ui-states nil)
         (seshat-library-test--ui-fetch-result nil)
         (seshat-library-test--ui-fetch-calls nil)
         (seshat-library-test--ui-delete-calls 0)
         (seshat-library-test--ui-location nil))
     (unwind-protect
         (cl-letf (((symbol-function 'seshat-library--roots)
                    (lambda ()
                      (seshat-library-test--record 'roots)
                      seshat-library-test--ui-roots))
                   ((symbol-function 'seshat-library--remote-entries)
                    (lambda (tag &optional prefix)
                      (seshat-library-test--record 'remote-entries tag prefix)
                      ;; fixture 用短标签写 uid，桩在这里补成合法 uid 形态（A5 之后
                      ;; `--collect' 会丢掉不合法 uid）；`:root' 一律等于请求 tag，
                      ;; 模拟「服务端回包与请求一致」的正常路径。
                      (mapcar (lambda (item)
                                (let ((copy (copy-sequence item)))
                                  (plist-put copy :uid
                                             (seshat-library-test--uid
                                              (plist-get item :uid)))
                                  (plist-put copy :root tag)))
                              (alist-get tag seshat-library-test--ui-items
                                         nil nil #'equal))))
                   ((symbol-function 'seshat-library--local-state)
                    (lambda (item)
                      (let* ((uid (plist-get item :uid))
                             (label (seshat-library-test--label uid)))
                        (seshat-library-test--record 'local-state uid)
                        (or (alist-get label seshat-library-test--ui-states
                                       nil nil #'equal)
                            'unregistered))))
                   ((symbol-function 'seshat-library-fetch)
                    (lambda (uid &optional force)
                      (setq seshat-library-test--ui-fetch-calls
                            (append seshat-library-test--ui-fetch-calls
                                    (list (list uid force))))
                      (seshat-library-test--record 'fetch uid force)
                      seshat-library-test--ui-fetch-result))
                   ;; `ondemand' 根只读：本桩一旦被调用就说明实现越界了。
                   ((symbol-function 'seshat-rest-delete-file)
                    (lambda (&rest args)
                      (setq seshat-library-test--ui-delete-calls
                            (1+ seshat-library-test--ui-delete-calls))
                      (seshat-library-test--record 'rest-delete args)
                      (list :status 200)))
                   ((symbol-function 'seshat-state-path-for-uid)
                    (lambda (uid)
                      (seshat-library-test--record 'state-path-for-uid uid)
                      seshat-library-test--ui-location))
                   ((symbol-function 'seshat-sync--root-dir)
                    (lambda (root)
                      (seshat-library-test--record 'root-dir root)
                      (funcall orig-root-dir root)))
                   ((symbol-function 'seshat-sync--local-path)
                    (lambda (root-dir path)
                      (seshat-library-test--record 'local-path root-dir path)
                      (funcall orig-local-path root-dir path)))
                   ((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _args)
                      (seshat-library-test--record 'pop-to-buffer buffer)
                      buffer)))
           ,@body)
       (let ((buffer (get-buffer "*Seshat Library*")))
         (when buffer (kill-buffer buffer))))))

;;; 列定义与行内容

(ert-deftest seshat-library-mode-format-and-rows ()
  "3 条远端 item → 4 列表头 + 3 行；书名取 basename、大小人类可读、缺 size 显示 \"-\"。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "sub/alpha.pdf")
                              (seshat-library-test--item "u2" 200 "beta.epub")
                              (plist-put (seshat-library-test--item
                                          "u3" 300 "gamma.pdf")
                                         :size nil)))))
      (should-not (get-buffer "*Seshat Library*"))
      (seshat-library)
      (with-current-buffer (seshat-library-test--library-buffer)
        (should (equal "*Seshat Library*" (buffer-name)))
        (should (eq major-mode 'seshat-library-mode))
        (should (= 4 (length tabulated-list-format)))
        (should (equal '("书名" "根" "大小" "状态")
                       (mapcar (lambda (col) (nth 0 col)) tabulated-list-format)))
        (should (equal (list (seshat-library-test--uid "u1")
                             (seshat-library-test--uid "u2")
                             (seshat-library-test--uid "u3"))
                       (mapcar #'car tabulated-list-entries)))
        (should (= 3 (length tabulated-list-entries)))
        ;; 正文每行一条：打印真的发生了（不只 entries 变量对）
        (should (= 3 (count-lines (point-min) (point-max)))))
      (should (equal "alpha.pdf" (aref (seshat-library-test--row "u1") 0)))
      (should (equal "books" (aref (seshat-library-test--row "u1") 1)))
      (should (equal "10 B" (aref (seshat-library-test--row "u1") 2)))
      (should (equal "-" (aref (seshat-library-test--row "u3") 2))))))

(ert-deftest seshat-library-size-label ()
  "大小列格式化：字节 / KiB / MiB 三档 + 非整数（含 nil）显示 \"-\"。"
  (should (equal "10 B" (seshat-library--size-label 10)))
  (should (equal "1.0 KiB" (seshat-library--size-label 1024)))
  (should (equal "1.2 MiB" (seshat-library--size-label 1258291)))
  (should (equal "-" (seshat-library--size-label nil)))
  (should (equal "-" (seshat-library--size-label "123")))
  (should (equal "-" (seshat-library--size-label -1))))

(ert-deftest seshat-library-state-labels ()
  "三态列文案固定：`downloaded' → 已下载、`missing' → 未下载、`unregistered' → 未登记。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "a.pdf")
                              (seshat-library-test--item "u2" 200 "b.pdf")
                              (seshat-library-test--item "u3" 300 "c.pdf"))))
            seshat-library-test--ui-states '(("u1" . downloaded)
                                             ("u2" . missing)))
      (seshat-library)
      (should (equal "已下载" (seshat-library-test--row-status "u1")))
      (should (equal "未下载" (seshat-library-test--row-status "u2")))
      (should (equal "未登记" (seshat-library-test--row-status "u3"))))))

(ert-deftest seshat-library-multi-root-rows ()
  "两个根各返回 1 项 → 列表 2 行，「根」列显示各自的 tag（多根汇总不丢项）。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand")
                                            ("media" "/tmp/media/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "a.pdf")))
                  (cons "media"
                        (list (seshat-library-test--item "u2" 200 "b.pdf")))))
      (seshat-library)
      (should (equal '("u1" "u2") (seshat-library-test--rows)))
      (should (equal "books" (aref (seshat-library-test--row "u1") 1)))
      (should (equal "media" (aref (seshat-library-test--row "u2") 1))))))

;;; 键位

(ert-deftest seshat-library-keybindings ()
  "`RET' / `u' / `d' / `g' / `q' 逐项绑定到预期命令（`q' 为 `quit-window'）。"
  (should (eq 'seshat-library-open-at-point
              (keymap-lookup seshat-library-mode-map "RET")))
  (should (eq 'seshat-library-refresh-at-point
              (keymap-lookup seshat-library-mode-map "u")))
  (should (eq 'seshat-library-delete-local-at-point
              (keymap-lookup seshat-library-mode-map "d")))
  (should (eq 'tabulated-list-revert
              (keymap-lookup seshat-library-mode-map "g")))
  (should (eq 'quit-window
              (keymap-lookup seshat-library-mode-map "q"))))

;;; 空清单与根过滤

(ert-deftest seshat-library-empty-list ()
  "所有根都返回 nil（拉取失败 / 空根）→ 不报错，buffer 正常显示空表。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items nil)
      (should (bufferp (seshat-library)))
      (with-current-buffer (seshat-library-test--library-buffer)
        (should (eq major-mode 'seshat-library-mode))
        (should (null tabulated-list-entries))
        ;; 空表也照样打印（正文为空）
        (should (= 0 (count-lines (point-min) (point-max))))))))

(ert-deftest seshat-library-root-filter ()
  "`seshat-library' 的 ROOT 参数只拉指定 tag 的清单（其它根一次都不请求）。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand")
                                            ("media" "/tmp/media/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u-book" 100 "a.pdf")))
                  (cons "media"
                        (list (seshat-library-test--item "u-media" 200 "b.pdf")))))
      (seshat-library "media")
      (should (= 1 (seshat-library-test--call-count 'remote-entries)))
      (should (equal "media"
                     (nth 1 (assq 'remote-entries seshat-library-test--calls))))
      (should (equal '("u-media") (seshat-library-test--rows))))))

(ert-deftest seshat-library-interactive-prefix-filters-root ()
  "`C-u M-x seshat-library' 的 `interactive' 形态真的把所选 tag 传给命令体。
（只测 `interactive' 表单本身：`completing-read' 桩成直接返回 tag，前缀参数桩成
`(4)'。写成这样是因为 `interactive' 形式写错时程序调用测不出来。）"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand")
                                            ("media" "/tmp/media/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u-book" 100 "a.pdf")))
                  (cons "media"
                        (list (seshat-library-test--item "u-media" 200 "b.pdf")))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _args) "media")))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'seshat-library)))
      (should (= 1 (seshat-library-test--call-count 'remote-entries)))
      (should (equal "media"
                     (nth 1 (assq 'remote-entries seshat-library-test--calls))))
      (should (equal '("u-media") (seshat-library-test--rows))))))

(ert-deftest seshat-library-root-without-dir ()
  "DIR 为 nil 的根：`message' 提示一次且不调 `--remote-entries'（无法定位落点）。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("no-dir" nil "ondemand")
                                            ("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "a.pdf")))))
      (seshat-library)
      (should (= 1 (length seshat-library-test--messages)))
      (should (string-match-p "no-dir" (format "%s"
                                               (car seshat-library-test--messages))))
      (should (= 1 (seshat-library-test--call-count 'remote-entries)))
      (should (equal "books"
                     (nth 1 (assq 'remote-entries seshat-library-test--calls))))
      (should (equal '("u1") (seshat-library-test--rows))))))

;;; evil 软依赖

(ert-deftest seshat-library-mode-without-evil-helper ()
  "`seshat-reader--disable-evil' 不可用时 `seshat-library-mode' 零副作用、不报错。"
  (let ((orig-fboundp (symbol-function 'fboundp))
        (called nil))
    (cl-letf (((symbol-function 'seshat-reader--disable-evil)
               (lambda () (setq called t)))
              ((symbol-function 'fboundp)
               (lambda (symbol)
                 (if (eq symbol 'seshat-reader--disable-evil)
                     nil
                   (funcall orig-fboundp symbol)))))
      (with-temp-buffer
        (seshat-library-mode)
        (should (eq major-mode 'seshat-library-mode))
        (should-not called)))))

;;; `RET' 取书并打开

(ert-deftest seshat-library-open-at-point-uses-reading-open ()
  "`RET' 取书成功后交给 `seshat-reading-open' 打开（`require' 桩成 no-op 以稳住桩）。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (let ((opened nil)
            (target (expand-file-name "book.pdf" seshat-library-test--dir)))
        (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
              seshat-library-test--ui-items
              (list (cons "books"
                          (list (seshat-library-test--item "u1" 100 "book.pdf"))))
              seshat-library-test--ui-states '(("u1" . missing))
              seshat-library-test--ui-fetch-result target)
        (seshat-library)
        (cl-letf (((symbol-function 'require) (lambda (&rest _args) nil))
                  ((symbol-function 'seshat-reading-open)
                   (lambda (file) (setq opened file))))
          (seshat-library-test--goto-row "u1")
          (with-current-buffer (seshat-library-test--library-buffer)
            (seshat-library-open-at-point)))
        (should (equal target opened))
        (should (equal (list (list (seshat-library-test--uid "u1") nil))
                       seshat-library-test--ui-fetch-calls))))))

(ert-deftest seshat-library-open-at-point-falls-back-to-find-file ()
  "`seshat-reading-open' 不可用时退化为 `find-file'（软依赖缺失不阻塞打开）。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (let ((opened nil)
            (orig-fboundp (symbol-function 'fboundp))
            (target (expand-file-name "book.pdf" seshat-library-test--dir)))
        (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
              seshat-library-test--ui-items
              (list (cons "books"
                          (list (seshat-library-test--item "u1" 100 "book.pdf"))))
              seshat-library-test--ui-states '(("u1" . missing))
              seshat-library-test--ui-fetch-result target)
        (seshat-library)
        (cl-letf (((symbol-function 'require) (lambda (&rest _args) nil))
                  ((symbol-function 'find-file)
                   (lambda (file &rest _args) (setq opened file) nil))
                  ((symbol-function 'fboundp)
                   (lambda (symbol)
                     (if (eq symbol 'seshat-reading-open)
                         nil
                       (funcall orig-fboundp symbol)))))
          (seshat-library-test--goto-row "u1")
          (with-current-buffer (seshat-library-test--library-buffer)
            (seshat-library-open-at-point)))
        (should (equal target opened))))))

(ert-deftest seshat-library-open-at-point-fetch-failure ()
  "`RET' 取书返回 nil → `user-error`（且不打开任何文件）。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (let ((opened nil))
        (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
              seshat-library-test--ui-items
              (list (cons "books"
                          (list (seshat-library-test--item "u1" 100 "book.pdf"))))
              seshat-library-test--ui-states '(("u1" . missing))
              seshat-library-test--ui-fetch-result nil)
        (seshat-library)
        (cl-letf (((symbol-function 'require) (lambda (&rest _args) nil))
                  ((symbol-function 'seshat-reading-open)
                   (lambda (file) (setq opened file)))
                  ((symbol-function 'find-file)
                   (lambda (file &rest _args) (setq opened file) nil)))
          (seshat-library-test--goto-row "u1")
          (with-current-buffer (seshat-library-test--library-buffer)
            (should-error (seshat-library-open-at-point) :type 'user-error)))
        (should-not opened)))))

;;; `u' 强制刷新

(ert-deftest seshat-library-refresh-at-point-forces-redownload ()
  "`u' 以 FORCE 非 nil 调 `seshat-library-fetch'，并按新的三态重算状态列。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "book.pdf"))))
            seshat-library-test--ui-states '(("u1" . missing))
            seshat-library-test--ui-fetch-result
            (expand-file-name "book.pdf" seshat-library-test--dir))
      (seshat-library)
      (should (equal "未下载" (seshat-library-test--row-status "u1")))
      ;; 模拟「下载完成后状态库已更新」，此列必须跟着变
      (setq seshat-library-test--ui-states '(("u1" . downloaded)))
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (seshat-library-refresh-at-point))
      (should (equal (list (list (seshat-library-test--uid "u1") t))
                     seshat-library-test--ui-fetch-calls))
      (should (equal "已下载" (seshat-library-test--row-status "u1")))
      ;; `u' 只重算本地状态列，不重拉远端清单
      (should (= 1 (seshat-library-test--call-count 'remote-entries))))))

;;; `d' 只删本地副本

(ert-deftest seshat-library-delete-local-only ()
  "`d' 只删本地副本：无任何远端请求，删的是经 `--local-path' 校验后的路径。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (let* ((root-dir (file-name-as-directory seshat-library-test--dir))
             (local (seshat-library-test--write-file
                     (expand-file-name "book.pdf" root-dir) "x")))
        (seshat-state-set-roots (list (list "books" root-dir "ondemand")))
        (setq seshat-library-test--ui-roots (list (list "books" root-dir "ondemand"))
              seshat-library-test--ui-items
              (list (cons "books"
                          (list (seshat-library-test--item "u1" 100 "book.pdf"))))
              seshat-library-test--ui-states '(("u1" . downloaded))
              seshat-library-test--ui-location (cons "books" "book.pdf"))
        (should (file-exists-p local))
        (seshat-library)
        (let ((before (seshat-library-test--call-count 'remote-entries)))
          (seshat-library-test--goto-row "u1")
          (with-current-buffer (seshat-library-test--library-buffer)
            (seshat-library-delete-local-at-point))
          ;; `d' 之后不得再拉远端清单（`ondemand' 根只读，删除不产生任何远端请求）
          (should (= before (seshat-library-test--call-count 'remote-entries)))
          (should (= 0 seshat-library-test--ui-delete-calls)))
        (should-not (file-exists-p local))
        ;; 删的是 `--local-path' 拼出来并校验过的路径
        (should (= 1 (seshat-library-test--call-count 'local-path)))
        (should (equal "book.pdf"
                       (nth 2 (assq 'local-path seshat-library-test--calls))))))))

(ert-deftest seshat-library-delete-local-path-escape ()
  "`d' 遇到越界路径 → `user-error' 且**不删**任何文件。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (let* ((root-dir (file-name-as-directory
                        (expand-file-name "books/" seshat-library-test--dir)))
             (outside (seshat-library-test--write-file
                       (expand-file-name "outside.pdf" seshat-library-test--dir)
                       "x")))
        (make-directory root-dir t)
        (seshat-state-set-roots (list (list "books" root-dir "ondemand")))
        (setq seshat-library-test--ui-roots (list (list "books" root-dir "ondemand"))
              seshat-library-test--ui-items
              (list (cons "books"
                          (list (seshat-library-test--item "u1" 100 "book.pdf"))))
              seshat-library-test--ui-states '(("u1" . downloaded))
              seshat-library-test--ui-location (cons "books" "../outside.pdf"))
        (seshat-library)
        (seshat-library-test--goto-row "u1")
        (with-current-buffer (seshat-library-test--library-buffer)
          (should-error (seshat-library-delete-local-at-point) :type 'user-error))
        (should (file-exists-p outside))
        (should (= 0 seshat-library-test--ui-delete-calls))))))

;;; `g' 重拉远端清单

(ert-deftest seshat-library-revert-rereads-remote ()
  "`tabulated-list-revert'（`g'）重拉远端清单：服务端新增的条目出现在表里。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "a.pdf")))))
      (seshat-library)
      (should (= 1 (seshat-library-test--call-count 'remote-entries)))
      (should (equal '("u1") (seshat-library-test--rows)))
      ;; 服务端多了一本书：`g' 必须重拉，而不是只用缓存
      (setq seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item "u1" 100 "a.pdf")
                              (seshat-library-test--item "u2" 200 "b.pdf")))))
      (with-current-buffer (seshat-library-test--library-buffer)
        (tabulated-list-revert))
      (should (= 2 (seshat-library-test--call-count 'remote-entries)))
      (should (equal '("u1" "u2") (seshat-library-test--rows))))))

;;; ===========================================================================
;;; 安全审查修复（A1–A6）：uid 归属根的 mode 门 / 覆盖确认 / 下载上限 /
;;; 分页上限 / uid 形态校验 / 错误契约
;;; ===========================================================================

(ert-deftest seshat-library-test--uid-fixtures-are-valid ()
  "测试 fixture 的短标签映射出的 uid 必须是 26 位 Crockford Base32。
（A5 之后 `--collect' 会丢弃不合法 uid；本用例守住 fixture 自身的正确性。）"
  (dolist (pair seshat-library-test--uids)
    (let ((uid (cdr pair)))
      (should (= 26 (length uid)))
      (should (let ((case-fold-search nil))
                (string-match-p "\\`[0-9A-HJKMNP-TV-Z]\\{26\\}\\'" uid))))))

(ert-deftest seshat-library--ondemand-root-p ()
  "mode 门判据：只有本地配置为 \"ondemand\" 的根才算书库根。"
  (cl-letf (((symbol-function 'seshat-state-roots)
             (lambda ()
               '(("books" "/tmp/books/" "ondemand")
                 ("notes" "/tmp/notes/" "mirror")
                 ("no-dir" nil "ondemand")))))
    (should (seshat-library--ondemand-root-p "books"))
    (should (seshat-library--ondemand-root-p "no-dir"))
    (should-not (seshat-library--ondemand-root-p "notes"))
    (should-not (seshat-library--ondemand-root-p "missing"))
    (should-not (seshat-library--ondemand-root-p nil))))

(ert-deftest seshat-library-fetch-mirror-root-refused ()
  "A1（high）：uid 归属根是 `mirror' 根时 `seshat-library-fetch' 必须 `user-error'，
且**不发**下载请求——恶意清单塞一个 mirror 根 uid 不能借书架写/删用户笔记。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "notes" seshat-library-test--dir "mirror")))
    (setq seshat-library-test--location (cons "notes" "draft.org"))
    (seshat-library-test--with-fetch-stubs
      (let ((err (should-error (seshat-library-fetch (seshat-library-test--uid "u1")) :type 'user-error)))
        (should (string-match-p "ondemand" (error-message-string err))))
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 (seshat-library-test--call-count 'local-path)))
      (should (= 0 seshat-library-test--saves)))))

(ert-deftest seshat-library-delete-local-mirror-root-refused ()
  "A1（high）：`d' 对 mirror 根 uid 必须 `user-error'，且**不删**任何文件。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (let* ((root-dir (file-name-as-directory
                        (expand-file-name "notes/" seshat-library-test--dir)))
             (local (seshat-library-test--write-file
                     (expand-file-name "draft.org" root-dir) "unsaved")))
        (make-directory root-dir t)
        (seshat-state-set-roots (list (list "notes" root-dir "mirror")))
        (setq seshat-library-test--ui-roots (list (list "notes" root-dir "mirror"))
              seshat-library-test--ui-items
              (list (cons "notes"
                          (list (seshat-library-test--item "u1" 100 "draft.org"))))
              seshat-library-test--ui-states '(("u1" . downloaded))
              seshat-library-test--ui-location (cons "notes" "draft.org"))
        (seshat-library)
        (seshat-library-test--goto-row "u1")
        (with-current-buffer (seshat-library-test--library-buffer)
          (let ((err (should-error (seshat-library-delete-local-at-point)
                                   :type 'user-error)))
            (should (string-match-p "ondemand" (error-message-string err)))))
        (should (file-exists-p local))
        (should (equal "unsaved" (seshat-library-test--read-file local)))
        (should (= 0 seshat-library-test--ui-delete-calls))))))

(ert-deftest seshat-library-fetch-force-confirm-declined ()
  "A2：FORCE 且本地已有副本时先确认；用户拒绝 → `user-error'、不下载、
不动文件与状态库（`force' 为 nil 的短路分支不触发确认）。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-state-set (seshat-library-test--uid "u1") (list :root "books" :path "book.pdf"))
    (let ((local (seshat-library-test--write-file
                  (expand-file-name "book.pdf" seshat-library-test--dir) "old"))
          (asked nil))
      (setq seshat-library-test--location (cons "books" "book.pdf"))
      (seshat-library-test--with-fetch-stubs
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (prompt) (setq asked prompt) nil)))
          (let ((err (should-error (seshat-library-fetch (seshat-library-test--uid "u1") 'force)
                                   :type 'user-error)))
            (should (string-match-p "已取消" (error-message-string err)))))
        (should asked)
        (should (= 0 (seshat-library-test--call-count 'download)))
        (should (= 0 seshat-library-test--saves))
        (should (equal "old" (seshat-library-test--read-file local)))))))

(ert-deftest seshat-library-fetch-force-confirm-accepted ()
  "A2：确认返回 t 时照常重新下载。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-state-set (seshat-library-test--uid "u1") (list :root "books" :path "book.pdf"))
    (seshat-library-test--write-file
     (expand-file-name "book.pdf" seshat-library-test--dir) "old")
    (setq seshat-library-test--location (cons "books" "book.pdf"))
    (seshat-library-test--with-fetch-stubs
      (let ((asked 0))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _args) (setq asked (1+ asked)) t)))
          (should (equal (expand-file-name "book.pdf" seshat-library-test--dir)
                         (seshat-library-fetch (seshat-library-test--uid "u1") 'force))))
        (should (= 1 asked))
        (should (= 1 (seshat-library-test--call-count 'download)))
        (should (= 1 seshat-library-test--saves))))))

(ert-deftest seshat-library-fetch-not-found-says-unregistered ()
  "A6-1：步骤 1 fallback 拿到 404（`:not-found t'）→ `user-error' 明说「未登记」。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--resource-response
          (list :status 404 :not-found t :resource nil))
    (seshat-library-test--with-fetch-stubs
      (let ((err (should-error (seshat-library-fetch (seshat-library-test--uid "u-gone")) :type 'user-error)))
        (should (string-match-p "未登记" (error-message-string err))))
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 (length seshat-library-test--warnings))))))

(ert-deftest seshat-library-fetch-server-error-warns-and-returns-nil ()
  "A6-1：步骤 1 fallback 拿到 500（无 `:not-found'）→ `display-warning' + nil，
**不得**报「未登记」——那不是确定性答案，不能糊成墓碑。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--resource-response
          (list :status 500 :error 'unexpected-status :resource nil))
    (seshat-library-test--with-fetch-stubs
      (should-not (seshat-library-fetch (seshat-library-test--uid "u1")))
      (should (= 1 (seshat-library-test--call-count 'get-resource)))
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 seshat-library-test--saves))
      (should (= 1 (length seshat-library-test--warnings)))
      (should-not (cl-some (lambda (warning)
                             (string-match-p "未登记" (format "%s" warning)))
                           seshat-library-test--warnings)))))

(ert-deftest seshat-library-fetch-download-file-error-warns-and-returns-nil ()
  "A6-2：下载抛 `file-error'（磁盘满 / 权限）→ `display-warning' + nil，
不让 raw error 穿透（否则 reader 的 `--fetch-library' 友好提示收不到）。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "book.pdf")
          seshat-library-test--download-handler
          (lambda (&rest _args)
            (signal 'file-error '("Writing to disk failed: no space left"))))
    (seshat-library-test--with-fetch-stubs
      (should-not (seshat-library-fetch (seshat-library-test--uid "u1")))
      (should (= 1 (seshat-library-test--call-count 'download)))
      (should (= 0 (seshat-library-test--call-count 'event-set-location)))
      (should (= 0 seshat-library-test--saves))
      (should (= 1 (length seshat-library-test--warnings))))))

(ert-deftest seshat-library-fetch-passes-download-limits ()
  "A3：下载调用带 `:timeout' 与 `:max-bytes'（取自两个 defcustom）。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "book.pdf"))
    (seshat-library-test--with-fetch-stubs
      (seshat-library-fetch (seshat-library-test--uid "u1"))
      (let ((args (nth 3 (assq 'download seshat-library-test--calls))))
        (should (equal seshat-library-download-timeout
                       (plist-get args :timeout)))
        (should (equal seshat-library-max-download-bytes
                       (plist-get args :max-bytes)))
        (should (= 30 seshat-library-download-timeout))
        (should (= (* 512 1024 1024) seshat-library-max-download-bytes))))))

(ert-deftest seshat-library-fetch-too-large-warns-and-returns-nil ()
  "A3：下载返回 `:too-large t' → `display-warning'（含字节数）+ nil，不写状态库。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (setq seshat-library-test--location (cons "books" "book.pdf")
          seshat-library-test--download-handler
          (lambda (&rest _args) (list :status 200 :too-large t :size 123456789)))
    (seshat-library-test--with-fetch-stubs
      (should-not (seshat-library-fetch (seshat-library-test--uid "u1")))
      (should (= 1 (length seshat-library-test--warnings)))
      (should (string-match-p "上限"
                              (format "%s" (car seshat-library-test--warnings))))
      (should (string-match-p "123456789"
                              (format "%s" (car seshat-library-test--warnings))))
      (should (= 0 (seshat-library-test--call-count 'event-set-location)))
      (should (= 0 seshat-library-test--saves)))))

(ert-deftest seshat-library--remote-entries-page-limit ()
  "A4：服务端恒回 `:has-more t' 时按 `seshat-library--max-pages' 截断并警告一次，
不无限循环；返回的是已收集部分且**保持服务端顺序**（push + nreverse）。

上限在用例内绑成 3（不是走默认 500）：500 页的桩循环既慢又**危险**——上限判定
一旦被误删，`while' 永不退出（桩 mtime 逐页递增，游标永远在前进，没有任何自然
终止条件），CI 表现为挂死而不是断言失败。绑小上限 + 桩自身 10 页硬顶，让「上限
失效」表现为断言不符。默认值 500 由 `seshat-library--max-pages-default' 单独守。"
  (seshat-library-test--with-temp-dir
    (let ((n 0)
          (seshat-library--max-pages 3))
      (cl-letf (((symbol-function 'seshat-rest-list-resources)
                 (lambda (&rest args)
                   (seshat-library-test--record 'list args)
                   (setq n (1+ n))
                   ;; 10 页硬顶：上限判定若被删掉，循环在这里收口而不是挂死
                   ;; （此时调用次数 > 3，下面的断言会失败）。
                   (list :status 200 :has-more (< n 10)
                         :items (list (seshat-library-test--item
                                       (format "u%d" n) n))))))
        (let ((items (seshat-library--remote-entries "books")))
          (should (= 3 (seshat-library-test--call-count 'list)))
          (should (= 3 (length items)))
          (should (equal "u1" (plist-get (car items) :uid)))
          (should (equal "u3" (plist-get (car (last items)) :uid)))
          (should (= 1 (length seshat-library-test--warnings)))
          (should (string-match-p
                   "页上限"
                   (format "%s" (car seshat-library-test--warnings)))))))))

(ert-deftest seshat-library--max-pages-default ()
  "分页上限的默认值必须是 500（500 页 × 2000 条 = 100 万条，覆盖真实书库）。
单独断言常量本身：上面那条行为用例为了不挂死把上限绑小了，默认值不能再靠它守。"
  (should (= 500 seshat-library--max-pages)))

(ert-deftest seshat-library--collect-drops-invalid-uid ()
  "A5：uid 形态不合法（含 `/`、小写、长度非 26）的行被丢弃并只警告一次。
理由：uid 会拼进 `GET /api/resources/%s'，校验缺失会让同源 URL 注入成为可能。"
  (seshat-library-test--with-temp-dir
    (seshat-library-test--with-ui-stubs
      (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
            seshat-library-test--ui-items
            (list (cons "books"
                        (list (seshat-library-test--item
                               (seshat-library-test--uid "u1") 100 "ok.pdf")
                              (seshat-library-test--item "abc/def" 200 "slash.pdf")
                              (seshat-library-test--item
                               "01j8zkq2aaaaaaaaaaaaaaaav1" 300 "lower.pdf")
                              (seshat-library-test--item
                               "01J8ZKQ2" 400 "short.pdf")))))
      (let ((items (seshat-library--collect
                    (list (list "books" "/tmp/books/" "ondemand")))))
        (should (equal (list (seshat-library-test--uid "u1"))
                       (mapcar (lambda (item) (plist-get item :uid)) items)))
        (should (= 1 (length seshat-library-test--warnings)))
        (should (string-match-p
                 "uid"
                 (format "%s" (car seshat-library-test--warnings))))))))

(ert-deftest seshat-library--collect-drops-root-mismatch ()
  "A1-4：响应的 `:root' 与请求的 tag 不一致时丢弃该行并警告一次——
「根」列与操作目标不允许分叉（否则 `d' / `u' 可能落到别的根上）。"
  (seshat-library-test--with-temp-dir
    (cl-letf (((symbol-function 'seshat-library--remote-entries)
               (lambda (tag &optional _prefix)
                 (list (plist-put (seshat-library-test--item
                                   (seshat-library-test--uid "u1") 100 "a.pdf")
                                  :root tag)
                       (plist-put (seshat-library-test--item
                                   (seshat-library-test--uid "u2") 200 "b.pdf")
                                  :root "elsewhere")))))
      (let ((items (seshat-library--collect
                    (list (list "books" "/tmp/books/" "ondemand")))))
        (should (equal (list (seshat-library-test--uid "u1"))
                       (mapcar (lambda (item) (plist-get item :uid)) items)))
        (should (equal "books" (plist-get (car items) :root)))
        (should (= 1 (length seshat-library-test--warnings)))
        (should (string-match-p
                 "根"
                 (format "%s" (car seshat-library-test--warnings))))))))

;;; 安全复核第二轮（low）：uid 形态守卫

(ert-deftest seshat-library-fetch-invalid-uid-refused ()
  "A7（low）：uid 形态不合法时 `seshat-library-fetch' 必须在**任何请求之前**
`user-error'。

uid 会被拼进 `GET /api/resources/%s'（该路径假设 uid 无需 URL 编码），
`../../api/roots' 这样的值能把请求引到同源别的端点，因此形态校验是安全边界，
不是可用性判断。桩断言 `get-resource' / `download' 调用数均为 0——拒绝必须发生
在联网之前，也不能先拿非法 uid 去查本地状态库。"
  (seshat-library-test--with-temp-dir
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--with-fetch-stubs
      (dolist (uid '("../../api/roots"      ; 路径穿越
                     "01J8ZKQ2/../../x"     ; 含分隔符
                     "01j8zkq2aaaaaaaaaaaaaaaav1" ; 小写
                     "01J8ZKQ2"             ; 长度不足
                     ""))                   ; 空串
        (let ((err (should-error (seshat-library-fetch uid) :type 'user-error)))
          (should (string-match-p "形态不合法" (error-message-string err))))
        ;; FORCE 非 nil 也不该绕过守卫
        (should-error (seshat-library-fetch uid 'force) :type 'user-error))
      (should (= 0 (seshat-library-test--call-count 'get-resource)))
      (should (= 0 (seshat-library-test--call-count 'download)))
      (should (= 0 seshat-library-test--saves)))))

(provide 'seshat-library-test)

;;; seshat-library-test.el ends here
