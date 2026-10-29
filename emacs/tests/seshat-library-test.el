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
;; 视图层的 `D'（dired 定位）会 `(require 'dired)'：这里预先加载，用例才能用
;; `cl-letf' 桩住 `dired' / `dired-goto-file' 而不被命令内部的 require 覆盖。
(require 'dired)
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

(defun seshat-library-test--gen-uid (i)
  "生成第 I 个**合法形态**的 uid（26 位 Crockford Base32），供批量用例使用.
批量用例（100 本 / 300 条远端清单）需要大量互不相同的合法 uid；`--collect'
会丢弃形态不合法的 uid，因此不能拿 `b0' / `r1' 这类短标签充数。

序号固定占 **4 位**（`%04d'），前缀固定 22 位，合计恒为 26 位：早先写成 `%02d'
时 I ≥ 100 会产出 27 位 uid，被 `--collect' 的形态校验整批丢弃——「300 条远端
清单」用例因此只剩 100 条，看起来像实现有隐藏条数限制，实际是夹具不合格。
4 位零填充同时保证字典序与数值序一致（用例依赖「第 I 个」的稳定顺序）。"
  (concat "01J8ZKQ2AAAAAAAAAAAAAA" (format "%04d" i)))

(defmacro seshat-library-test--with-queue-feature (&rest body)
  "把 `seshat-reader-annotation-queue' 伪造成「已加载」，**不真的加载模块**.
只往 `features' 里 push 符号，因此 `featurep' 为 t，但模块的顶层副作用（注册
300 秒自动同步定时器）不会发生——这正是被测的软依赖口径：模块**已经**加载时
才用它的接口，未加载时一律降级，绝不主动 require。"
  (declare (indent 0) (debug t))
  `(let ((seshat-library--pending-feature 'seshat-reader-annotation-queue))
     (push 'seshat-reader-annotation-queue features)
     (unwind-protect (progn ,@body)
       (setq features (delq 'seshat-reader-annotation-queue features)))))

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
;;; ===========================================================================
;;; 书架视图层（M9 T5b：自建 buffer + 分页 + 15 键位）
;;; ===========================================================================
;;
;; 视图层用例的口径与数据层一致：**零网络、零真实侧车文件**。
;;
;; - 数据层三层取数（`--entries-local' / `--entries-cached' /
;;   `--entries-refresh-remote'）与上层协作者（`--roots' / `seshat-library-fetch' /
;;   `seshat-state-path-for-uid'）一律桩替并记录实参；
;; - `seshat-sync--root-dir' / `seshat-sync--local-path' 是「记录后**转调真实
;;   实现**」——删除 / dired 用例的越界校验因此走真代码，不是被桩掉的口径；
;; - `seshat-rest--request'（`seshat-rest' 里所有 HTTP 的唯一咽喉）恒绑成抛错：
;;   视图层的每个动作都必须零网络，谁偷偷联网就当场失败而不是静默通过；
;; - 临时目录 + 侧车文件绑定由 `seshat-library-test--with-ui-env' 统一提供，
;;   每个用例收尾杀掉 `*Seshat Library*' buffer（buffer 是全局状态）。

(defvar seshat-library-test--ui-roots nil
  "UI 用例中 `seshat-library--roots' 的返回值（元素为 `(TAG DIR MODE)'）.")

(defvar seshat-library-test--ui-items nil
  "UI 用例中「本地状态库」层的统一 item 列表（`--entries-local' 的桩返回值）.")

(defvar seshat-library-test--ui-cached nil
  "UI 用例中「清单缓存」层的统一 item 列表（`--entries-cached' 的桩返回值）.")

(defvar seshat-library-test--ui-remote nil
  "UI 用例中 `g'（`--entries-refresh-remote'）的返回值；nil 表示沿用 `--ui-items'.")

(defvar seshat-library-test--ui-real-layer nil
  "非 nil 时 `--entries-local' / `--entries-cached' 的桩**转调真实实现**.
「打开书架零网络」用例靠它跑真数据层（真状态库 + 真缓存文件），其余用例用
固定 fixture，避免每条断言都被数据层的实现细节牵动。")

(defvar seshat-library-test--ui-fetch-result nil
  "UI 用例中 `seshat-library-fetch' 的返回值（本地路径字符串或 nil）.")

(defvar seshat-library-test--ui-fetch-calls nil
  "UI 用例中 `seshat-library-fetch' 收到的 `(UID FORCE)' 列表（按调用顺序）.")

(defvar seshat-library-test--ui-location nil
  "UI 用例中 `seshat-state-path-for-uid' 的默认返回值（`(ROOT . PATH)' 或 nil）.")

(defvar seshat-library-test--ui-locations nil
  "UI 用例中「uid → `(ROOT . PATH)'」的 alist；命中时优先于 `--ui-location'.
批量删（`x'）用例要给不同 uid 不同归属，单值 `--ui-location' 表达不了。")

(defvar seshat-library-test--ui-refresh-calls 0
  "UI 用例中 `--entries-refresh-remote' 被调用的次数（零网络断言用）.")

(defvar seshat-library-test--ui-dired-calls nil
  "UI 用例中 dired 相关调用记录：`(DIR)' 与 `(GOTO FILE)'，按发生顺序.")

(defvar seshat-library-test--ui-delete-calls 0
  "UI 用例中 `seshat-rest-delete-file' 的调用次数（`ondemand' 根只读，必须恒为 0）.")

(defun seshat-library-test--ui-item (uid &rest args)
  "构造一个视图用例用的统一 item，UID 先映射成合法 uid 形态.
ARGS 为 plist：`:root'（默认 \"books\"）`:path' `:name' `:size' `:mtime' `:state'
（默认 `downloaded'）`:page' `:total' `:percent' `:pending' `:source'
（默认 `local'）。形状与数据层 `seshat-library--make-item' 一致。"
  (let ((label uid))
    (list :uid (seshat-library-test--uid label)
          :root (if (plist-member args :root) (plist-get args :root) "books")
          :path (if (plist-member args :path)
                    (plist-get args :path)
                  (concat label ".pdf"))
          :name (if (plist-member args :name)
                    (plist-get args :name)
                  (concat label ".pdf"))
          :size (plist-get args :size)
          :mtime (plist-get args :mtime)
          :state (or (plist-get args :state) 'downloaded)
          :page (plist-get args :page)
          :total (plist-get args :total)
          :percent (plist-get args :percent)
          :pending (plist-get args :pending)
          :source (or (plist-get args :source) 'local))))

(defun seshat-library-test--library-buffer ()
  "返回 `*Seshat Library*' buffer；不存在时报错（说明 `seshat-library' 没建 buffer）."
  (or (get-buffer "*Seshat Library*")
      (error "书架 buffer 未创建")))

(defun seshat-library-test--rows ()
  "返回书架 buffer 里各条目行的 uid 短标签序列（按 buffer 顺序）.
按行首 `seshat-library-uid' 属性收集，因此页脚 / 空结果提示行不会被算成条目。"
  (with-current-buffer (seshat-library-test--library-buffer)
    (let (uids)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((uid (get-text-property (point) 'seshat-library-uid)))
            (when (stringp uid)
              (push uid uids)))
          (forward-line 1)))
      (mapcar #'seshat-library-test--label (nreverse uids)))))

(defun seshat-library-test--line (uid)
  "返回书架 buffer 里 UID（短标签）那一行的文本（不含换行符）；找不到返回 nil.
按行首 `seshat-library-uid' 属性定位，不按显示文字匹配——同名书在不同根下会
出现同样的文字。"
  (with-current-buffer (seshat-library-test--library-buffer)
    (save-excursion
      (goto-char (point-min))
      (let ((target (seshat-library-test--uid uid))
            (line nil))
        (while (and (not line) (not (eobp)))
          (if (equal target (get-text-property (point) 'seshat-library-uid))
              (setq line (buffer-substring-no-properties
                          (point) (line-end-position)))
            (forward-line 1)))
        line))))

(defun seshat-library-test--line-status (uid)
  "返回 UID 那一行正文的最后一段（状态文案：已下载 / 未下载 / 未登记）."
  (let ((line (seshat-library-test--line uid)))
    (and line (car (last (split-string line " · " t))))))

(defun seshat-library-test--goto-row (uid)
  "把 point 移到书架 buffer 里 UID（短标签）那一行的行首（缺行则报错）."
  (with-current-buffer (seshat-library-test--library-buffer)
    (goto-char (point-min))
    (let ((target (seshat-library-test--uid uid))
          (found nil))
      (while (and (not found) (not (eobp)))
        (if (equal target (get-text-property (point) 'seshat-library-uid))
            (setq found t)
          (forward-line 1)))
      (unless found
        (error "书架里找不到 uid %s 的行" uid)))))

(defun seshat-library-test--set-page-size (n)
  "把书架 buffer 的页大小设为 N 并重算重渲染（分页用例的准备步骤）."
  (with-current-buffer (seshat-library-test--library-buffer)
    (setq seshat-library--page-size n)
    (seshat-library--apply-view)
    (seshat-library--render)))

(defun seshat-library-test--filtered-labels ()
  "返回 `--filtered' 的 uid 短标签序列（断言「过滤命中了哪些书」用）.
分页用例里 buffer 只显示当前页，`--rows' 看不到全量，因此另立一个看 `--filtered'
的口径。"
  (with-current-buffer (seshat-library-test--library-buffer)
    (mapcar (lambda (item) (seshat-library-test--label (plist-get item :uid)))
            seshat-library--filtered)))

(defun seshat-library-test--header-line ()
  "返回书架 buffer 的 header-line 文本.
`format-mode-line' 在 `emacs --batch' 下对字符串构造返回空串（它走的是窗口的
mode-line 排版，批处理没有可排版的窗口），因此这里优先直接取变量值；只有变量
不是字符串（将来改成 `:eval' 形态）时才回落到 `format-mode-line'。"
  (with-current-buffer (seshat-library-test--library-buffer)
    (let ((format header-line-format))
      (if (stringp format)
          format
        (format-mode-line format)))))

(defvar seshat-library-test--ui-cover-failed nil
  "UI 用例中「有负缓存」的 uid 列表（`seshat-covers-failed-p' 的桩返回值）.")

(defvar seshat-library-test--ui-covers nil
  "UI 用例中「uid → 已生成的封面缓存路径」的 alist（`seshat-covers-cached' 的桩）.
默认 nil = 没有任何封面缓存：用例不会去读用户真实的 `seshat-covers-dir'。")

(defvar seshat-library-test--ui-cover-queue nil
  "UI 用例中 `seshat-covers-queue' 收到的 `(UID FILE CALLBACK)' 列表（按入队顺序）.
桩替是必须的：真队列会武装 idle 定时器并起 `unzip' / `mutool' 子进程，那既慢又
会跨用例泄漏。")

(defmacro seshat-library-test--with-ui-stubs (&rest body)
  "在书架视图层的协作者被桩替后执行 BODY（建议嵌在 `--with-temp-dir' 内）.
网络/上层协作者完全桩替并记录；纯本地的路径校验函数记录后**转调真实实现**；
`seshat-rest--request' 恒绑成抛错（视图层任何动作都不得联网）。收尾杀掉书架
buffer，避免跨用例污染。"
  (declare (indent 0) (debug t))
  `(let ((orig-root-dir (symbol-function 'seshat-sync--root-dir))
         (orig-local-path (symbol-function 'seshat-sync--local-path))
         (orig-entries-local (symbol-function 'seshat-library--entries-local))
         (orig-entries-cached (symbol-function 'seshat-library--entries-cached))
         (seshat-library-test--calls nil)
         (seshat-library-test--ui-roots nil)
         (seshat-library-test--ui-items nil)
         (seshat-library-test--ui-cached nil)
         (seshat-library-test--ui-remote nil)
         (seshat-library-test--ui-real-layer nil)
         (seshat-library-test--ui-fetch-result nil)
         (seshat-library-test--ui-fetch-calls nil)
         (seshat-library-test--ui-location nil)
         (seshat-library-test--ui-locations nil)
         (seshat-library-test--ui-refresh-calls 0)
         (seshat-library-test--ui-dired-calls nil)
         (seshat-library-test--ui-delete-calls 0)
         (seshat-library-test--ui-cover-failed nil)
         (seshat-library-test--ui-covers nil)
         (seshat-library-test--ui-cover-queue nil))
     (unwind-protect
         (cl-letf (((symbol-function 'seshat-library--roots)
                    (lambda ()
                      (seshat-library-test--record 'roots)
                      seshat-library-test--ui-roots))
                   ((symbol-function 'seshat-library--entries-local)
                    (lambda ()
                      (seshat-library-test--record 'entries-local)
                      (if seshat-library-test--ui-real-layer
                          (funcall orig-entries-local)
                        seshat-library-test--ui-items)))
                   ((symbol-function 'seshat-library--entries-cached)
                    (lambda ()
                      (seshat-library-test--record 'entries-cached)
                      (if seshat-library-test--ui-real-layer
                          (funcall orig-entries-cached)
                        seshat-library-test--ui-cached)))
                   ((symbol-function 'seshat-library--entries-refresh-remote)
                    (lambda (&optional roots)
                      (seshat-library-test--record 'entries-refresh-remote roots)
                      (setq seshat-library-test--ui-refresh-calls
                            (1+ seshat-library-test--ui-refresh-calls))
                      (or seshat-library-test--ui-remote
                          seshat-library-test--ui-items)))
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
                      (or (cdr (assoc uid seshat-library-test--ui-locations))
                          seshat-library-test--ui-location)))
                   ((symbol-function 'seshat-sync--root-dir)
                    (lambda (root)
                      (seshat-library-test--record 'root-dir root)
                      (funcall orig-root-dir root)))
                   ((symbol-function 'seshat-sync--local-path)
                    (lambda (root-dir path)
                      (seshat-library-test--record 'local-path root-dir path)
                      (funcall orig-local-path root-dir path)))
                   ((symbol-function 'dired)
                    (lambda (dirname &optional _switches)
                      (push (list dirname) seshat-library-test--ui-dired-calls)
                      nil))
                   ((symbol-function 'dired-goto-file)
                    (lambda (file)
                      (push (list file) seshat-library-test--ui-dired-calls)
                      nil))
                   ((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _args)
                      (seshat-library-test--record 'pop-to-buffer buffer)
                      buffer))
                   ;; 封面（T5b-2）：缓存查询与入队一律桩替。真 `seshat-covers-cached'
                   ;; 会去扫用户真实的封面缓存目录，真 `seshat-covers-queue' 会武装
                   ;; idle 定时器并起子进程——两者都必须挡在用例之外。
                   ((symbol-function 'seshat-covers-cached)
                    (lambda (uid)
                      (seshat-library-test--record 'covers-cached uid)
                      (cdr (assoc uid seshat-library-test--ui-covers))))
                   ((symbol-function 'seshat-covers-failed-p)
                    (lambda (uid)
                      (seshat-library-test--record 'covers-failed uid)
                      (and (member uid seshat-library-test--ui-cover-failed) t)))
                   ((symbol-function 'seshat-covers-queue)
                    (lambda (uid file &optional callback)
                      (seshat-library-test--record 'covers-queue uid file)
                      (setq seshat-library-test--ui-cover-queue
                            (append seshat-library-test--ui-cover-queue
                                    (list (list uid file callback))))
                      t))
                   ((symbol-function 'seshat-covers-queue-clear)
                    (lambda ()
                      (seshat-library-test--record 'covers-queue-clear)
                      nil))
                   ;; 视图层零网络：`seshat-rest' 的所有 HTTP 都过这一个咽喉。
                   ((symbol-function 'seshat-rest--request)
                    (lambda (&rest _args)
                      (error "书架视图层不得联网"))))
           ,@body)
       (let ((buffer (get-buffer "*Seshat Library*")))
         (when buffer (kill-buffer buffer))))))

(defmacro seshat-library-test--with-ui-env (&rest body)
  "视图用例的统一环境：临时目录 + 侧车文件全部指向它 + 干净状态库 + UI 桩.
侧车文件必须绑临时目录，否则用例会写用户的 `~/.local/share/seshat/'。
`seshat-library--pending-feature' 绑到不存在的 feature：批注队列是软依赖，用例
默认走「模块缺失」分支（否则会去加载整个 reader 包）。"
  (declare (indent 0) (debug t))
  `(seshat-library-test--with-temp-dir
     (let* ((seshat-library-cache-file
             (expand-file-name "library-cache.eld" seshat-library-test--dir))
            (seshat-covers-dir
             (expand-file-name "covers/" seshat-library-test--dir))
            (seshat-reads-file
             (expand-file-name "reads.eld" seshat-library-test--dir))
            (seshat-reads--state nil)
            (seshat-reader-annotation-queue-file
             (expand-file-name "annotation-queue.eld" seshat-library-test--dir))
            (seshat-library--pending-feature
             'seshat-library-test--no-such-feature))
       ;; `ignore` 只是「读一次」：绑定本身必须留着（模块会按这个变量名找侧车），
       ;; 但多数用例不直接用它的值——不加这一行，每次展开都会让字节编译报
       ;; "Unused lexical variable"（75 条既有警告，全是这一个变量）。
       (ignore seshat-reader-annotation-queue-file)
       (seshat-library-test--with-ui-stubs ,@body))))

;;; 列文案（纯函数）

(ert-deftest seshat-library-size-label ()
  "大小列格式化：字节 / KiB / MiB 三档 + 非整数（含 nil）显示 \"-\"。"
  (should (equal "10 B" (seshat-library--size-label 10)))
  (should (equal "1.0 KiB" (seshat-library--size-label 1024)))
  (should (equal "1.2 MiB" (seshat-library--size-label 1258291)))
  (should (equal "-" (seshat-library--size-label nil)))
  (should (equal "-" (seshat-library--size-label "123")))
  (should (equal "-" (seshat-library--size-label -1))))

(ert-deftest seshat-library-state-labels ()
  "三态文案固定：`downloaded' → 已下载、`missing' → 未下载、`unregistered' → 未登记；
未知符号原样输出而不是报错（只读视图不该因一个陌生状态打不开）。"
  (should (equal "已下载" (seshat-library--state-label 'downloaded)))
  (should (equal "未下载" (seshat-library--state-label 'missing)))
  (should (equal "未登记" (seshat-library--state-label 'unregistered)))
  (should (equal "weird" (seshat-library--state-label 'weird))))

(ert-deftest seshat-library-progress-and-pending-labels ()
  "进度文案三档（`42%' / `p.12' / `-'）与待同步文案（`⟳2' / nil）."
  (should (equal "42%" (seshat-library--progress-label
                        (seshat-library-test--ui-item "u1" :percent 42))))
  (should (equal "p.12" (seshat-library--progress-label
                         (seshat-library-test--ui-item "u1" :page 12))))
  (should (equal "-" (seshat-library--progress-label
                      (seshat-library-test--ui-item "u1"))))
  ;; 有页码但缺 :total（算不出百分比）时退化为页码，不冒充 0%
  (should (equal "p.7" (seshat-library--progress-label
                        (seshat-library-test--ui-item "u1" :page 7))))
  (should (equal "⟳2" (seshat-library--pending-label
                       (seshat-library-test--ui-item "u1" :pending 2))))
  (should-not (seshat-library--pending-label
               (seshat-library-test--ui-item "u1" :pending 0)))
  (should-not (seshat-library--pending-label
               (seshat-library-test--ui-item "u1"))))

;;; 打开书架（零网络）与行属性

(ert-deftest seshat-library-open-is-offline ()
  "打开书架**零网络**：`seshat-rest--request' 绑成抛错时 `(seshat-library)' 仍成功，
buffer 有内容——数据源是本地状态库 + 缓存，不是远端清单。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-real-layer t)
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-state-set (seshat-library-test--uid "u1")
                      (list :root "books" :path "a.pdf" :size 12 :mtime 100))
    ;; 本地副本落盘 → 三态为「已下载」（三态由磁盘事实重算，不靠缓存里的旧值）
    (seshat-library-test--write-file
     (expand-file-name "a.pdf" seshat-library-test--dir) "x")
    (seshat-library--cache-write
     (list (seshat-library-test--plain-item (seshat-library-test--uid "u2")
                                            :name "b.pdf" :source 'cache)))
    (cl-letf (((symbol-function 'seshat-rest-list-resources)
               (lambda (&rest _) (error "网络调用")))
              ((symbol-function 'seshat-rest-get-resource)
               (lambda (&rest _) (error "网络调用"))))
      (should (bufferp (seshat-library))))
    (with-current-buffer (seshat-library-test--library-buffer)
      (should (eq major-mode 'seshat-library-mode))
      ;; 本地登记的书 + 缓存独有的书都在（后者以「未登记」出现）
      (should (equal '("u1" "u2") (seshat-library-test--rows)))
      (should (equal "已下载" (seshat-library-test--line-status "u1")))
      (should (equal "未登记" (seshat-library-test--line-status "u2")))
      (should (> (buffer-size) 0)))))

(ert-deftest seshat-library-line-uid-property ()
  "行首第 1 个字符带 `seshat-library-uid' 属性，`get-text-property' 可反查 uid；
整行带 `seshat-library-item' 属性（`RET' / `D' 据此拿完整 item）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :size 10)
                (seshat-library-test--ui-item "u2" :size 20)))
    (seshat-library)
    (with-current-buffer (seshat-library-test--library-buffer)
      (goto-char (point-min))
      (should (equal (seshat-library-test--uid "u1")
                     (get-text-property (line-beginning-position)
                                        'seshat-library-uid)))
      (should (equal (seshat-library-test--uid "u1")
                     (plist-get (get-text-property (point) 'seshat-library-item)
                                :uid)))
      (forward-line 1)
      (should (equal (seshat-library-test--uid "u2")
                     (get-text-property (line-beginning-position)
                                        'seshat-library-uid)))
      ;; 页脚提示行不承载 uid 属性（否则会被命令当成条目）
      (goto-char (point-max))
      (forward-line -1)
      (should-not (get-text-property (line-beginning-position)
                                     'seshat-library-uid)))))

(ert-deftest seshat-library-row-format ()
  "行正文：书名（basename）· 根 · 大小 · 进度 · 待同步 · 状态，行首是标记位 + 定宽封面占位."
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :path "sub/alpha.pdf"
                                              :name "alpha.pdf" :size 10
                                              :percent 42 :pending 2)
                (seshat-library-test--ui-item "u2" :name "beta.epub"
                                              :state 'missing)))
    (seshat-library)
    (let* ((line (seshat-library-test--line "u1"))
           (cols (seshat-library--cover-columns))
           (cover (substring line 1 (+ 1 cols))))
      ;; 封面区：固定列宽 + 书名首字标签（T5b-2 起由 `--cover-placeholder' 生成）
      (should (equal cols (string-width cover)))
      (should (string-prefix-p "[a]" cover))
      (should (string-prefix-p " " line))
      (should (string-prefix-p " alpha.pdf" (substring line (+ 1 cols))))
      (should (string-match-p "books" line))
      (should (string-match-p "10 B" line))
      (should (string-match-p "42%" line))
      (should (string-match-p "⟳2" line))
      (should (string-match-p "已下载" line)))
    ;; 缺 size / 进度 / 待同步 / 未下载：大小与进度显示 "-"，待同步整段省略
    (let ((line (seshat-library-test--line "u2")))
      (should (string-match-p "beta.epub" line))
      (should (string-match-p "未下载" line))
      (should-not (string-match-p "⟳" line)))
    (should (equal "未下载" (seshat-library-test--line-status "u2")))))

(ert-deftest seshat-library-multi-root-rows ()
  "两个根的条目都在同一页上，各自显示自己的根（多根汇总不丢项）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :root "books" :name "a.pdf")
                (seshat-library-test--ui-item "u2" :root "media" :name "b.pdf")))
    (seshat-library)
    (should (equal '("u1" "u2") (seshat-library-test--rows)))
    (should (string-match-p "books" (seshat-library-test--line "u1")))
    (should (string-match-p "media" (seshat-library-test--line "u2")))))

;;; 键位（15 个，逐个断言）

(ert-deftest seshat-library-keybindings ()
  "15 个键位各自绑定到预期命令，且每个都是 `commandp'（逐个断言，不抽测）。"
  (let ((expected
         '(("RET" . seshat-library-open-at-point)
           ("u" . seshat-library-refresh-at-point)
           ("d" . seshat-library-delete-local-at-point)
           ("x" . seshat-library-delete-marked)
           ("m" . seshat-library-toggle-mark)
           ("D" . seshat-library-dired-at-point)
           ("n" . seshat-library-next-page)
           ("p" . seshat-library-previous-page)
           ("M-<" . seshat-library-first-page)
           ("M->" . seshat-library-last-page)
           ("g" . seshat-library-refresh-remote)
           ("/" . seshat-library-filter-keyword)
           ("F" . seshat-library-filter-state)
           ("s" . seshat-library-sort-cycle)
           ("q" . quit-window))))
    (should (= 15 (length expected)))
    (dolist (pair expected)
      (let ((command (keymap-lookup seshat-library-mode-map (car pair))))
        (should (eq (cdr pair) command))
        (should (commandp command))))
    ;; 父 keymap 是 `special-mode-map'（因此 `special-mode' 的通用绑定仍在）
    (should (eq special-mode-map (keymap-parent seshat-library-mode-map)))))

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
        (should buffer-read-only)
        (should-not called)))))

;;; 分页

(ert-deftest seshat-library-paging-next-previous ()
  "`n' / `p' 只改页码并重渲染，`--filtered' 一字不变（翻页不重算过滤 / 排序）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (mapcar (lambda (label) (seshat-library-test--ui-item label :size 1))
                  '("u1" "u2" "u3" "u4" "u5")))
    (seshat-library)
    (seshat-library-test--set-page-size 2)
    (with-current-buffer (seshat-library-test--library-buffer)
      (let ((filtered seshat-library--filtered))
        (should (= 1 seshat-library--page))
        (should (equal '("u1" "u2") (seshat-library-test--rows)))
        (seshat-library-next-page)
        (should (= 2 seshat-library--page))
        (should (equal filtered seshat-library--filtered))
        (should (equal '("u3" "u4") (seshat-library-test--rows)))
        (seshat-library-next-page)
        (should (= 3 seshat-library--page))
        (should (equal filtered seshat-library--filtered))
        ;; 末页只剩 1 条
        (should (equal '("u5") (seshat-library-test--rows)))
        (seshat-library-previous-page)
        (should (= 2 seshat-library--page))
        (should (equal filtered seshat-library--filtered))))))

(ert-deftest seshat-library-paging-last-page-clamped ()
  "末页再按 `n' 不越界（页码保持末页）并提示「已是最后一页」；首页按 `p' 同理。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (mapcar (lambda (label) (seshat-library-test--ui-item label))
                  '("u1" "u2" "u3" "u4" "u5")))
    (seshat-library)
    (seshat-library-test--set-page-size 2)
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-last-page)
      (should (= 3 seshat-library--page))
      (seshat-library-next-page)
      (should (= 3 seshat-library--page))
      (should (cl-some (lambda (msg)
                         (string-match-p "最后一页" (format "%s" msg)))
                       seshat-library-test--messages))
      (seshat-library-first-page)
      (should (= 1 seshat-library--page))
      (seshat-library-previous-page)
      (should (= 1 seshat-library--page))
      (should (cl-some (lambda (msg)
                         (string-match-p "第一页" (format "%s" msg)))
                       seshat-library-test--messages)))))

(ert-deftest seshat-library-paging-first-and-last ()
  "`M-<' 回首页、`M->' 到末页（页码与渲染内容都跟着变）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (mapcar (lambda (label) (seshat-library-test--ui-item label))
                  '("u1" "u2" "u3" "u4" "u5")))
    (seshat-library)
    (seshat-library-test--set-page-size 2)
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-last-page)
      (should (= 3 seshat-library--page))
      (should (equal '("u5") (seshat-library-test--rows)))
      (seshat-library-first-page)
      (should (= 1 seshat-library--page))
      (should (equal '("u1" "u2") (seshat-library-test--rows))))))

;;; 过滤

(ert-deftest seshat-library-filter-keyword-resets-page ()
  "`/' 过滤后页码重置为第 1 页，且只留命中的条目（零网络）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :name "alpha.pdf")
                (seshat-library-test--ui-item "u2" :name "beta.pdf")
                (seshat-library-test--ui-item "u3" :name "alphabet.pdf")))
    (seshat-library)
    (seshat-library-test--set-page-size 1)
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-last-page)
      (should (= 3 seshat-library--page))
      (seshat-library-filter-keyword "alpha")
      (should (= 1 seshat-library--page))
      (should (equal "alpha" seshat-library--keyword))
      (should (equal '("u1" "u3") (seshat-library-test--filtered-labels)))
      ;; 空串清除过滤
      (seshat-library-filter-keyword "")
      (should-not seshat-library--keyword)
      ;; 默认按 name 升序：alpha.pdf < alphabet.pdf < beta.pdf
      (should (equal '("u1" "u3" "u2")
                     (seshat-library-test--filtered-labels))))))

(ert-deftest seshat-library-filter-state-cycles ()
  "`F' 状态过滤循环 4 步后回到 `all'：all → downloaded → missing → unregistered → all."
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :state 'downloaded)
                (seshat-library-test--ui-item "u2" :state 'missing)
                (seshat-library-test--ui-item "u3" :state 'unregistered)))
    (seshat-library)
    (with-current-buffer (seshat-library-test--library-buffer)
      (should-not seshat-library--state-filter)
      (seshat-library-filter-state)
      (should (eq 'downloaded seshat-library--state-filter))
      (should (equal '("u1") (seshat-library-test--rows)))
      (seshat-library-filter-state)
      (should (eq 'missing seshat-library--state-filter))
      (should (equal '("u2") (seshat-library-test--rows)))
      (seshat-library-filter-state)
      (should (eq 'unregistered seshat-library--state-filter))
      (should (equal '("u3") (seshat-library-test--rows)))
      (seshat-library-filter-state)
      (should (eq 'all seshat-library--state-filter))
      (should (equal '("u1" "u2" "u3") (seshat-library-test--rows))))))

;;; 排序

(ert-deftest seshat-library-sort-cycle ()
  "`s' 循环 5 个键（name → root → size → percent → mtime），走完一轮后方向翻转。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :name "b.pdf" :root "media"
                                              :size 20 :percent 10 :mtime 200)
                (seshat-library-test--ui-item "u2" :name "a.pdf" :root "books"
                                              :size 10 :percent 30 :mtime 100)))
    (seshat-library)
    (with-current-buffer (seshat-library-test--library-buffer)
      (should (eq 'name seshat-library--sort-key))
      (should-not seshat-library--descending)
      (should (equal '("u2" "u1") (seshat-library-test--rows)))
      (seshat-library-sort-cycle)
      (should (eq 'root seshat-library--sort-key))
      (should-not seshat-library--descending)
      (seshat-library-sort-cycle)
      (should (eq 'size seshat-library--sort-key))
      (seshat-library-sort-cycle)
      (should (eq 'percent seshat-library--sort-key))
      (seshat-library-sort-cycle)
      (should (eq 'mtime seshat-library--sort-key))
      ;; 第 5 次：键回到 name，方向翻转（「同键再按一次反向」）
      (seshat-library-sort-cycle)
      (should (eq 'name seshat-library--sort-key))
      (should seshat-library--descending)
      (should (equal '("u1" "u2") (seshat-library-test--rows))))))

;;; 标记与批量删

(ert-deftest seshat-library-toggle-mark ()
  "`m' 标记后行首出现 `*'，再按一次取消；每次标记后 point 下移一行。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                (seshat-library-test--ui-item "u2" :name "b.pdf")))
    (seshat-library)
    (seshat-library-test--goto-row "u1")
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-toggle-mark)
      (should (equal (list (seshat-library-test--uid "u1"))
                     seshat-library--marked))
      ;; 标记后 point 已下移到下一行
      (should (equal (seshat-library-test--uid "u2")
                     (get-text-property (line-beginning-position)
                                        'seshat-library-uid))))
    (should (string-prefix-p "*" (seshat-library-test--line "u1")))
    (should (string-prefix-p " " (seshat-library-test--line "u2")))
    (seshat-library-test--goto-row "u1")
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-toggle-mark)
      (should-not seshat-library--marked))
    (should (string-prefix-p " " (seshat-library-test--line "u1")))))

(ert-deftest seshat-library-delete-marked-without-marks-errors ()
  "`x' 无标记时 `user-error`（不做任何删除）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1")))
    (seshat-library)
    (with-current-buffer (seshat-library-test--library-buffer)
      (let ((err (should-error (seshat-library-delete-marked) :type 'user-error)))
        (should (string-match-p "标记" (error-message-string err)))))))

(ert-deftest seshat-library-delete-marked-deletes-only-downloaded-ondemand ()
  "`x' 只删「`ondemand' 根 + 已下载」的本地副本：逐个调 `delete-file'（计数），
`mirror' 根与本地缺文件的条目一律跳过，且零远端删除请求。"
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (notes-dir (file-name-as-directory
                       (expand-file-name "notes/" seshat-library-test--dir)))
           (book (seshat-library-test--write-file
                  (expand-file-name "a.pdf" books-dir) "x"))
           (note (seshat-library-test--write-file
                  (expand-file-name "draft.org" notes-dir) "unsaved")))
      (make-directory books-dir t)
      (make-directory notes-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")
                                    (list "notes" notes-dir "mirror")))
      (setq seshat-library-test--ui-roots
            (list (list "books" books-dir "ondemand")
                  (list "notes" notes-dir "mirror"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "a.pdf" :name "a.pdf")
                  (seshat-library-test--ui-item "u2" :root "notes"
                                                :path "draft.org" :name "draft.org")
                  (seshat-library-test--ui-item "u3" :root "books"
                                                :path "gone.pdf" :name "gone.pdf"
                                                :state 'missing))
            seshat-library-test--ui-locations
            (list (cons (seshat-library-test--uid "u1") (cons "books" "a.pdf"))
                  (cons (seshat-library-test--uid "u2") (cons "notes" "draft.org"))
                  (cons (seshat-library-test--uid "u3") (cons "books" "gone.pdf"))))
      (seshat-library)
      ;; 用 `m' 逐个标记三行
      (dolist (label '("u1" "u2" "u3"))
        (seshat-library-test--goto-row label)
        (with-current-buffer (seshat-library-test--library-buffer)
          (seshat-library-toggle-mark)))
      (should (= 3 (length (with-current-buffer (seshat-library-test--library-buffer)
                             seshat-library--marked))))
      (let ((deleted nil))
        (cl-letf (((symbol-function 'delete-file)
                   (lambda (file &rest _args) (push file deleted) t)))
          (with-current-buffer (seshat-library-test--library-buffer)
            (seshat-library-delete-marked)))
        ;; 只有 books 根下已下载的那一本被删
        (should (equal (list book) deleted)))
      (should (file-exists-p note))
      (should (equal "unsaved" (seshat-library-test--read-file note)))
      (should (= 0 seshat-library-test--ui-delete-calls))
      (should (= 0 seshat-library-test--ui-refresh-calls))
      (with-current-buffer (seshat-library-test--library-buffer)
        (should-not seshat-library--marked)))))

;;; `d' 删本地副本

(ert-deftest seshat-library-delete-local-at-point-updates-state ()
  "`d' 删当前行本地副本：文件消失、状态列变「未下载」、零远端删除请求。"
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (local (seshat-library-test--write-file
                   (expand-file-name "book.pdf" books-dir) "x")))
      (make-directory books-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "book.pdf" :name "book.pdf"))
            seshat-library-test--ui-location (cons "books" "book.pdf"))
      (should (file-exists-p local))
      (seshat-library)
      (should (equal "已下载" (seshat-library-test--line-status "u1")))
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (seshat-library-delete-local-at-point))
      (should-not (file-exists-p local))
      (should (equal "未下载" (seshat-library-test--line-status "u1")))
      (should (= 0 seshat-library-test--ui-delete-calls))
      (should (= 0 seshat-library-test--ui-refresh-calls)))))

(ert-deftest seshat-library-delete-local-path-escape ()
  "`d' 遇到越界路径 → `user-error' 且**不删**任何文件（越界校验走真代码）。"
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (outside (seshat-library-test--write-file
                     (expand-file-name "outside.pdf" seshat-library-test--dir)
                     "x")))
      (make-directory books-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "book.pdf" :name "book.pdf"))
            seshat-library-test--ui-location (cons "books" "../outside.pdf"))
      (seshat-library)
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (let ((err (should-error (seshat-library-delete-local-at-point)
                                 :type 'user-error)))
          (should (string-match-p "越界" (error-message-string err)))))
      (should (file-exists-p outside))
      (should (= 0 seshat-library-test--ui-delete-calls)))))

(ert-deftest seshat-library-delete-local-mirror-root-refused ()
  "A1（high）：`d' 对 mirror 根 uid 必须 `user-error'，且**不删**任何文件。"
  (seshat-library-test--with-ui-env
    (let* ((notes-dir (file-name-as-directory
                       (expand-file-name "notes/" seshat-library-test--dir)))
           (local (seshat-library-test--write-file
                   (expand-file-name "draft.org" notes-dir) "unsaved")))
      (make-directory notes-dir t)
      (seshat-state-set-roots (list (list "notes" notes-dir "mirror")))
      (setq seshat-library-test--ui-roots (list (list "notes" notes-dir "mirror"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "notes"
                                                :path "draft.org"
                                                :name "draft.org"))
            seshat-library-test--ui-location (cons "notes" "draft.org"))
      (seshat-library)
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (let ((err (should-error (seshat-library-delete-local-at-point)
                                 :type 'user-error)))
          (should (string-match-p "ondemand" (error-message-string err)))))
      (should (file-exists-p local))
      (should (equal "unsaved" (seshat-library-test--read-file local)))
      (should (= 0 seshat-library-test--ui-delete-calls)))))

;;; 删本地副本：非普通文件一律拒（low 级加固）

;; 安全属性：`file-exists-p' 对**目录**同样返回 t，而 `delete-file' 对目录抛
;; `file-error'。裸调用会让 `d' 直接中断、`x' 整批中断。因此「能不能删」必须
;; 看**文件类型**而不只看存在性，且失败要转成调用方约定的信号（`d' →
;; `user-error'，`x' → 计入跳过），而不是让 `file-error' 冒出来。

(ert-deftest seshat-library-delete-local-at-point-directory-is-user-error ()
  "`d'：`:path' 指向**目录**时给 `user-error`（不是 `file-error`），且不删任何东西."
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           ;; 造一个**名为 book.pdf 的目录**：存在性为真、类型不是普通文件。
           (fake (expand-file-name "book.pdf" books-dir)))
      (make-directory books-dir t)
      (make-directory fake t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "book.pdf" :name "book.pdf"))
            seshat-library-test--ui-location (cons "books" "book.pdf"))
      (should (file-exists-p fake))
      (should-not (file-regular-p fake))
      (seshat-library)
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (let ((err (should-error (seshat-library-delete-local-at-point)
                                 :type 'user-error)))
          ;; 信号类型必须是 `user-error'（交互命令的约定），文案说明原因
          (should (eq 'user-error (car err)))
          (should (string-match-p "不是普通文件"
                                  (error-message-string err)))))
      ;; 目录仍在（没有被 `delete-file' 碰到）
      (should (file-directory-p fake))
      (should (= 0 seshat-library-test--ui-delete-calls)))))

(ert-deftest seshat-library-delete-marked-directory-counted-as-skipped ()
  "`x'：目录条目计入「跳过」而不是中断整批；同批的普通文件仍被删掉."
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (dir-target (expand-file-name "adir.pdf" books-dir))
           (file-target (seshat-library-test--write-file
                         (expand-file-name "ok.pdf" books-dir) "x"))
           (messages nil))
      (make-directory books-dir t)
      (make-directory dir-target t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "adir.pdf" :name "adir.pdf")
                  (seshat-library-test--ui-item "u2" :root "books"
                                                :path "ok.pdf" :name "ok.pdf"))
            seshat-library-test--ui-locations
            (list (cons (seshat-library-test--uid "u1") (cons "books" "adir.pdf"))
                  (cons (seshat-library-test--uid "u2") (cons "books" "ok.pdf"))))
      (seshat-library)
      (dolist (label '("u1" "u2"))
        (seshat-library-test--goto-row label)
        (with-current-buffer (seshat-library-test--library-buffer)
          (seshat-library-toggle-mark)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages)
                   nil)))
        (with-current-buffer (seshat-library-test--library-buffer)
          (seshat-library-delete-marked)))
      ;; 目录没被删，普通文件被删（整批没有中断）
      (should (file-directory-p dir-target))
      (should-not (file-exists-p file-target))
      (should (cl-some (lambda (msg)
                         (string-match-p "已删除 1 个本地副本（跳过 1 个）" msg))
                       messages))
      (should (= 0 seshat-library-test--ui-delete-calls)))))

(ert-deftest seshat-library-delete-local-copy-swallows-delete-error ()
  "`delete-file' 抛错（权限 / 竞态）时 `--delete-local-copy' 返回 `skipped'，不抛错."
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (local (seshat-library-test--write-file
                   (expand-file-name "book.pdf" books-dir) "x")))
      (make-directory books-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-location (cons "books" "book.pdf"))
      (should (file-exists-p local))
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (&rest _args) (error "Permission denied"))))
        ;; 不抛错：错误被吞掉并计入 skipped
        (should (eq 'skipped
                    (seshat-library--delete-local-copy
                     (seshat-library-test--uid "u1")))))
      (should (file-exists-p local)))))

;;; `D' 在 dired 中定位

(ert-deftest seshat-library-dired-at-point ()
  "`D' 未下载时 `user-error'；已下载时调 `dired' 打开所在目录并定位到该文件。"
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (local (seshat-library-test--write-file
                   (expand-file-name "book.pdf" books-dir) "x")))
      (make-directory books-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "book.pdf" :name "book.pdf")
                  (seshat-library-test--ui-item "u2" :root "books"
                                                :path "gone.pdf" :name "gone.pdf"
                                                :state 'missing))
            seshat-library-test--ui-locations
            (list (cons (seshat-library-test--uid "u1") (cons "books" "book.pdf"))
                  (cons (seshat-library-test--uid "u2") (cons "books" "gone.pdf"))))
      (seshat-library)
      ;; 未下载：报错且不打开 dired
      (seshat-library-test--goto-row "u2")
      (with-current-buffer (seshat-library-test--library-buffer)
        (let ((err (should-error (seshat-library-dired-at-point)
                                 :type 'user-error)))
          (should (string-match-p "本地副本" (error-message-string err)))))
      (should-not seshat-library-test--ui-dired-calls)
      ;; 已下载：dired 打开目录 + 定位文件
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (seshat-library-dired-at-point))
      (should (equal (list (list books-dir) (list local))
                     (reverse seshat-library-test--ui-dired-calls)))
      (should (file-exists-p local)))))

;;; 空结果提示

(ert-deftest seshat-library-empty-messages ()
  "空书架与「过滤无匹配」是两种不同文案（前者引导建索引，后者提示改过滤）。"
  (seshat-library-test--with-ui-env
    ;; ① `--items' 为空
    (setq seshat-library-test--ui-items nil)
    (seshat-library)
    (with-current-buffer (seshat-library-test--library-buffer)
      (should (string-match-p "书架为空"
                              (buffer-substring-no-properties
                               (point-min) (point-max))))
      (should (string-match-p "seshat-sync-now"
                              (buffer-substring-no-properties
                               (point-min) (point-max))))
      (should-not (seshat-library-test--rows)))
    (kill-buffer (seshat-library-test--library-buffer))
    ;; ② `--items' 非空但过滤无匹配
    (setq seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :name "alpha.pdf")))
    (seshat-library)
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-filter-keyword "zzz")
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "当前过滤无匹配" text))
        (should-not (string-match-p "书架为空" text)))
      (should-not (seshat-library-test--rows)))))

;;; 全链路零网络

(ert-deftest seshat-library-view-actions-are-offline ()
  "翻页 / 过滤 / 排序 / 标记 / 删本地全链路零网络：`seshat-rest--request' 抛错时
全部动作照常完成，且一次都没有调 `--entries-refresh-remote'。"
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir))))
      (make-directory books-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "a.pdf" :name "alpha.pdf")
                  (seshat-library-test--ui-item "u2" :root "books"
                                                :path "b.pdf" :name "beta.pdf")
                  (seshat-library-test--ui-item "u3" :root "books"
                                                :path "c.pdf" :name "gamma.pdf"))
            seshat-library-test--ui-locations
            (list (cons (seshat-library-test--uid "u1") (cons "books" "a.pdf"))
                  (cons (seshat-library-test--uid "u2") (cons "books" "b.pdf"))
                  (cons (seshat-library-test--uid "u3") (cons "books" "c.pdf"))))
      (seshat-library)
      (with-current-buffer (seshat-library-test--library-buffer)
        ;; 只有一页（默认页大小 30）：翻页类命令只会提示，不改页码
        (seshat-library-next-page)
        (seshat-library-previous-page)
        (seshat-library-first-page)
        (seshat-library-last-page)
        (should (= 1 seshat-library--page))
        (seshat-library-filter-keyword "a")
        (seshat-library-filter-keyword "")
        ;; `F' 走满一轮回到 `all'，避免状态过滤干扰后面的断言
        (dotimes (_ 4) (seshat-library-filter-state))
        (should (eq 'all seshat-library--state-filter))
        (seshat-library-sort-cycle)
        (seshat-library-sort-cycle)
        (seshat-library-test--goto-row "u1")
        (seshat-library-toggle-mark)
        ;; 本地缺文件 → 走 `:absent' 分支，不删任何东西、不报错
        (seshat-library-delete-local-at-point)
        (should (equal '("u1" "u2" "u3") (seshat-library-test--rows))))
      (should (= 0 seshat-library-test--ui-refresh-calls))
      (should (= 0 seshat-library-test--ui-delete-calls)))))

;;; header-line

(ert-deftest seshat-library-header-line ()
  "header-line 含页码与总数、排序方向、标记数；过滤生效时出现过滤段。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-items
          (mapcar (lambda (label) (seshat-library-test--ui-item label))
                  '("u1" "u2" "u3")))
    (seshat-library)
    (seshat-library-test--set-page-size 2)
    (with-current-buffer (seshat-library-test--library-buffer)
      (let ((header (seshat-library-test--header-line)))
        (should (stringp header))
        (should (string-match-p "第 1/2 页" header))
        (should (string-match-p "共 3 本" header))
        (should (string-match-p "本地 3" header))
        (should (string-match-p "排序 name" header))
        (should-not (string-match-p "标记" header)))
      (seshat-library-filter-keyword "u1")
      (let ((header (seshat-library-test--header-line)))
        (should (string-match-p "过滤 关键词 u1" header)))
      (seshat-library-filter-keyword "")
      (seshat-library-test--goto-row "u1")
      (seshat-library-toggle-mark)
      (let ((header (seshat-library-test--header-line)))
        (should (string-match-p "标记 1" header))))))

;;; `RET' 取书并打开

(ert-deftest seshat-library-open-at-point-uses-reading-open ()
  "`RET' 取书成功后交给 `seshat-reading-open' 打开（`require' 桩成 no-op 以稳住桩）。"
  (seshat-library-test--with-ui-env
    (let ((opened nil)
          (target (expand-file-name "book.pdf" seshat-library-test--dir)))
      (setq seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :path "book.pdf"
                                                :name "book.pdf" :state 'missing))
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
                     seshat-library-test--ui-fetch-calls)))))

(ert-deftest seshat-library-open-at-point-falls-back-to-find-file ()
  "`seshat-reading-open' 不可用时退化为 `find-file'（软依赖缺失不阻塞打开）。"
  (seshat-library-test--with-ui-env
    (let ((opened nil)
          (orig-fboundp (symbol-function 'fboundp))
          (target (expand-file-name "book.pdf" seshat-library-test--dir)))
      (setq seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :path "book.pdf"
                                                :name "book.pdf" :state 'missing))
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
      (should (equal target opened)))))

(ert-deftest seshat-library-open-at-point-fetch-failure ()
  "`RET' 取书返回 nil → `user-error`（且不打开任何文件）。"
  (seshat-library-test--with-ui-env
    (let ((opened nil))
      (setq seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :path "book.pdf"
                                                :name "book.pdf" :state 'missing))
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
      (should-not opened))))

;;; `u' 强制刷新

(ert-deftest seshat-library-refresh-at-point-forces-redownload ()
  "`u' 以 FORCE 非 nil 调 `seshat-library-fetch'，并按新的本地三态重算状态列；
不重拉远端清单（零网络）。"
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (local (expand-file-name "book.pdf" books-dir)))
      (make-directory books-dir t)
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :root "books"
                                                :path "book.pdf"
                                                :name "book.pdf" :state 'missing))
            seshat-library-test--ui-location (cons "books" "book.pdf")
            seshat-library-test--ui-fetch-result local)
      (seshat-library)
      (should (equal "未下载" (seshat-library-test--line-status "u1")))
      ;; 模拟「下载完成」：文件落盘，此列必须跟着变
      (seshat-library-test--write-file local "x")
      (seshat-library-test--goto-row "u1")
      (with-current-buffer (seshat-library-test--library-buffer)
        (seshat-library-refresh-at-point))
      (should (equal (list (list (seshat-library-test--uid "u1") t))
                     seshat-library-test--ui-fetch-calls))
      (should (equal "已下载" (seshat-library-test--line-status "u1")))
      (should (= 0 seshat-library-test--ui-refresh-calls)))))

;;; `g' 重拉远端清单

(ert-deftest seshat-library-refresh-remote-rereads ()
  "`g' 重拉远端清单：服务端新增的条目出现在表里（只有它触网）。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand"))
          seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u1" :name "a.pdf")))
    (seshat-library)
    (should (equal '("u1") (seshat-library-test--rows)))
    (should (= 0 seshat-library-test--ui-refresh-calls))
    ;; 服务端多了一本书：`g' 必须重拉，而不是只重算本地
    (setq seshat-library-test--ui-remote
          (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                (seshat-library-test--ui-item "u2" :name "b.pdf")))
    (with-current-buffer (seshat-library-test--library-buffer)
      (seshat-library-refresh-remote))
    (should (= 1 seshat-library-test--ui-refresh-calls))
    (should (equal '("u1" "u2") (seshat-library-test--rows)))
    ;; 重拉按 buffer 的根过滤传参（nil = 全部 ondemand 根，即整份根列表）
    (should (equal '(("books" "/tmp/books/" "ondemand"))
                   (car (cdr (assq 'entries-refresh-remote
                                   seshat-library-test--calls)))))))

;;; 根过滤

(ert-deftest seshat-library-root-filter ()
  "`seshat-library' 的 ROOT 参数只列该根的书目，且**不发任何远端请求**。"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand")
                                          ("media" "/tmp/media/" "ondemand"))
          seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u-book" :root "books"
                                              :name "a.pdf")
                (seshat-library-test--ui-item "u-media" :root "media"
                                              :name "b.pdf")))
    (seshat-library "media")
    (with-current-buffer (seshat-library-test--library-buffer)
      (should (equal "media" seshat-library--roots-filter)))
    (should (equal '("u-media") (seshat-library-test--rows)))
    (should (= 0 seshat-library-test--ui-refresh-calls))))

(ert-deftest seshat-library-interactive-prefix-filters-root ()
  "`C-u M-x seshat-library' 的 `interactive' 形态真的把所选 tag 传给命令体。
（只测 `interactive' 表单本身：`completing-read' 桩成直接返回 tag，前缀参数桩成
`(4)'。写成这样是因为 `interactive' 形式写错时程序调用测不出来。）"
  (seshat-library-test--with-ui-env
    (setq seshat-library-test--ui-roots '(("books" "/tmp/books/" "ondemand")
                                          ("media" "/tmp/media/" "ondemand"))
          seshat-library-test--ui-items
          (list (seshat-library-test--ui-item "u-book" :root "books"
                                              :name "a.pdf")
                (seshat-library-test--ui-item "u-media" :root "media"
                                              :name "b.pdf")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _args) "media")))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'seshat-library)))
    (with-current-buffer (seshat-library-test--library-buffer)
      (should (equal "media" seshat-library--roots-filter)))
    (should (equal '("u-media") (seshat-library-test--rows)))))

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
    ;; 直接桩 `--remote-entries'（本用例测的是 `--collect' 的校验，不是视图层），
    ;; 与 `--collect-drops-root-mismatch' 保持同一口径。
    (cl-letf (((symbol-function 'seshat-library--remote-entries)
               (lambda (_tag &optional _prefix)
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

;;; 离线数据层（M9 T5a）：统一 item / 三层取数 / 纯函数
;;
;; 本段用例全部**零网络、零真实侧车文件**：
;;
;; - `seshat-library-cache-file' / `seshat-reads-file' /
;;   `seshat-reader-annotation-queue-file' 一律绑到用例临时目录，绝不写用户的
;;   `~/.local/share/seshat/'；
;; - `seshat-library--pending-feature' 默认绑到不存在的 feature：批注队列是软依赖，
;;   用例默认走「模块缺失」分支（否则会去加载整个 reader 包）；
;; - 「零网络」断言的做法是把 `seshat-rest--request'（`seshat-rest' 里所有 HTTP
;;   的唯一咽喉）绑成 `error'：任何一层偷偷联网都会当场抛错而不是静默通过。

(defmacro seshat-library-test--with-offline-env (&rest body)
  "在「状态库 + 缓存 + 阅读进度 + 批注队列」全部指向临时目录的上下文中执行 BODY.
外层套 `seshat-library-test--with-temp-dir'（干净状态库 + `display-warning' /
`message' 桩 + 收尾递归删目录），因此用例不会碰任何真实侧车文件。"
  (declare (indent 0) (debug t))
  `(seshat-library-test--with-temp-dir
     (let* ((seshat-library-cache-file
             (expand-file-name "library-cache.eld" seshat-library-test--dir))
            (seshat-reads-file
             (expand-file-name "reads.eld" seshat-library-test--dir))
            (seshat-reads--state nil)
            (seshat-reader-annotation-queue-file
             (expand-file-name "annotation-queue.eld" seshat-library-test--dir))
            (seshat-library--pending-feature
             'seshat-library-test--no-such-feature))
       ;; 与 `seshat-library-test--with-ui-env' 同口径：绑定必须留着，只是「读一次」
       ;; 以免字节编译对每个展开都报 "Unused lexical variable"。
       (ignore seshat-reader-annotation-queue-file)
       ,@body)))

(defun seshat-library-test--plain-item (uid &rest args)
  "构造统一 item plist（不查状态库、不碰磁盘），供纯函数用例直接喂入.
ARGS 是 plist：`:root' `:path' `:name' `:size' `:mtime' `:state' `:page'
`:total' `:percent' `:pending' `:source'，缺省值见实现。"
  (list :uid uid
        :root (if (plist-member args :root) (plist-get args :root) "books")
        :path (if (plist-member args :path)
                  (plist-get args :path)
                (concat uid ".pdf"))
        :name (if (plist-member args :name)
                  (plist-get args :name)
                (concat uid ".pdf"))
        :size (plist-get args :size)
        :mtime (plist-get args :mtime)
        :state (or (plist-get args :state) 'downloaded)
        :page (plist-get args :page)
        :total (plist-get args :total)
        :percent (plist-get args :percent)
        :pending (plist-get args :pending)
        :source (or (plist-get args :source) 'local)))

(defun seshat-library-test--register (uid root path)
  "在状态库里把 UID 登记到 `(ROOT . PATH)'（只改内存，不落盘）."
  (seshat-state-set uid (list :root root :path path)))

(defun seshat-library-test--many-items (n)
  "构造 N 个 uid 递增的统一 item，用于分页用例."
  (let (items)
    (dotimes (i n)
      (push (seshat-library-test--plain-item (format "b%02d" (1+ i))) items))
    (nreverse items)))

(defun seshat-library-test--uids-of (items)
  "返回 ITEMS 的 uid 序列（断言顺序时用）."
  (mapcar (lambda (item) (plist-get item :uid)) items))

;;; seshat-library--entries-local

(ert-deftest seshat-library--entries-local-only-ondemand-roots ()
  "`--entries-local' 只列 `ondemand' 根：`mirror' 根的条目一律排除（安全门）."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots
     (list (list "books" seshat-library-test--dir "ondemand")
           (list "notes" (expand-file-name "notes/" seshat-library-test--dir)
                 "mirror")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (seshat-library-test--register (seshat-library-test--uid "u2") "notes" "n.org")
    (let ((items (seshat-library--entries-local)))
      (should (equal (list (seshat-library-test--uid "u1"))
                     (seshat-library-test--uids-of items)))
      (should (eq 'local (plist-get (car items) :source)))
      (should (equal "a.pdf" (plist-get (car items) :name)))
      (should (equal "books" (plist-get (car items) :root))))))

(ert-deftest seshat-library--entries-local-states ()
  "`--entries-local' 的三态：已下载 / 未下载，以及未登记 uid 的 `unregistered'.
本地条目天然都是「已登记」，因此 `unregistered' 用同一判定入口
`seshat-library--state-for' 单独断言——三态口径只有一处实现。"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--write-file
     (expand-file-name "a.pdf" seshat-library-test--dir) "x")
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (seshat-library-test--register (seshat-library-test--uid "u2") "books" "b.pdf")
    (let ((items (seshat-library--entries-local)))
      (should (equal 'downloaded (plist-get (nth 0 items) :state)))
      (should (equal 'missing (plist-get (nth 1 items) :state))))
    (should (eq 'unregistered
                (seshat-library--state-for (seshat-library-test--uid "u3"))))))

(ert-deftest seshat-library--entries-local-size-prefers-local-file ()
  "`:size' 优先取本地文件的 `file-attributes'，取不到时退回状态库的 `:size'."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--write-file
     (expand-file-name "a.pdf" seshat-library-test--dir) "12345")
    (seshat-state-set (seshat-library-test--uid "u1")
                      (list :root "books" :path "a.pdf" :size 999))
    (seshat-state-set (seshat-library-test--uid "u2")
                      (list :root "books" :path "b.pdf" :size 777))
    (let ((items (seshat-library--entries-local)))
      (should (= 5 (plist-get (nth 0 items) :size)))
      (should (= 777 (plist-get (nth 1 items) :size))))))

(ert-deftest seshat-library--entries-local-is-offline ()
  "`--entries-local' 零网络：`seshat-rest--request' 绑成 error 也照常返回."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (cl-letf (((symbol-function 'seshat-rest--request)
               (lambda (&rest _) (error "网络调用"))))
      (should (equal (list (seshat-library-test--uid "u1"))
                     (seshat-library-test--uids-of
                      (seshat-library--entries-local)))))))

;;; seshat-library--entries-cached

(ert-deftest seshat-library--entries-cached-roundtrip ()
  "缓存写出后能原样读回（uid / name / size / mtime），`:source' 为 `cache'."
  (seshat-library-test--with-offline-env
    (let ((item (seshat-library-test--plain-item
                 (seshat-library-test--uid "u1")
                 :root "books" :path "a/b.epub" :name "b.epub"
                 :size 1234 :mtime 1700000000 :source 'remote)))
      (should (seshat-library--cache-write (list item)))
      (let ((read-back (seshat-library--entries-cached)))
        (should (= 1 (length read-back)))
        (should (equal (seshat-library-test--uid "u1")
                       (plist-get (car read-back) :uid)))
        (should (equal "b.epub" (plist-get (car read-back) :name)))
        (should (= 1234 (plist-get (car read-back) :size)))
        (should (= 1700000000 (plist-get (car read-back) :mtime)))
        (should (eq 'cache (plist-get (car read-back) :source)))))))

(ert-deftest seshat-library--entries-cached-bad-file-degrades ()
  "坏缓存文件 → 返回 nil、不抛错、文件仍在、记一条 warn 日志."
  (seshat-library-test--with-offline-env
    (dolist (content '("(unbalanced" "42" "(not-a-plist)" "(:version 99 :items nil)"
                       "(:version 1 :items [1 2])"))
      (seshat-library-test--write-file seshat-library-cache-file content)
      (should (null (seshat-library--entries-cached)))
      (should (file-exists-p seshat-library-cache-file)))))

(ert-deftest seshat-library--cache-read-trailing-content-degrades ()
  "缓存文件顶层 plist 之后还有多余 form → 按空缓存降级、不抛错、文件保留.
与 `seshat-reads--read-file' 同口径：多余内容说明文件被拼接或截断过，此时
「读到的 plist」不可信，宁可退回只用状态库。"
  (seshat-library-test--with-offline-env
    (let ((content (concat
                    (prin1-to-string (list :version seshat-library--cache-version
                                           :items nil))
                    "\n(:version 1 :items nil)\n")))
      (seshat-library-test--write-file seshat-library-cache-file content)
      (should-not (seshat-library--cache-read))
      (should-not (seshat-library--entries-cached))
      (should (file-exists-p seshat-library-cache-file))
      (should (equal (seshat-library-test--read-file seshat-library-cache-file)
                     content)))))

(ert-deftest seshat-library--entries-cached-recomputes-state ()
  "缓存里的 `:state' 不可信：文件不在磁盘上时重算为 `missing'（登记在案但缺文件）."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (seshat-library--cache-write
     (list (seshat-library-test--plain-item
            (seshat-library-test--uid "u1") :root "books" :path "a.pdf"
            :state 'downloaded)))
    (let ((items (seshat-library--entries-cached)))
      (should (eq 'missing (plist-get (car items) :state)))
      ;; 补上本地文件后同一份缓存应判为已下载——缓存内容没变，判定变了。
      (seshat-library-test--write-file
       (expand-file-name "a.pdf" seshat-library-test--dir) "x")
      (should (eq 'downloaded
                  (plist-get (car (seshat-library--entries-cached)) :state))))))

;;; seshat-library--entries-merge

(ert-deftest seshat-library--entries-merge-local-wins ()
  "同一 uid 在两层都出现时以 local 为准（用 local 的 size / state / source）."
  (seshat-library-test--with-offline-env
    (let ((local (list (seshat-library-test--plain-item
                        (seshat-library-test--uid "u1") :size 100
                        :state 'downloaded :source 'local)))
          (cached (list (seshat-library-test--plain-item
                         (seshat-library-test--uid "u1") :size 200
                         :state 'missing :source 'cache))))
      (let ((merged (seshat-library--entries-merge local cached)))
        (should (= 1 (length merged)))
        (should (= 100 (plist-get (car merged) :size)))
        (should (eq 'downloaded (plist-get (car merged) :state)))
        (should (eq 'local (plist-get (car merged) :source)))))))

(ert-deftest seshat-library--entries-merge-cache-only-unregistered ()
  "缓存独有的 uid 以 `unregistered' 出现，并保留缓存的 size / name / mtime."
  (seshat-library-test--with-offline-env
    (let* ((local (list (seshat-library-test--plain-item
                         (seshat-library-test--uid "u1"))))
           (cached (list (seshat-library-test--plain-item
                          (seshat-library-test--uid "u2") :name "old.epub"
                          :size 42 :mtime 1700000001 :source 'cache)))
           (merged (seshat-library--entries-merge local cached)))
      (should (equal (list (seshat-library-test--uid "u1")
                           (seshat-library-test--uid "u2"))
                     (seshat-library-test--uids-of merged)))
      (let ((second (nth 1 merged)))
        (should (eq 'unregistered (plist-get second :state)))
        (should (eq 'cache (plist-get second :source)))
        (should (equal "old.epub" (plist-get second :name)))
        (should (= 42 (plist-get second :size)))
        (should (= 1700000001 (plist-get second :mtime)))))))

(ert-deftest seshat-library--entries-merge-order-and-purity ()
  "顺序：先 local（保持入参顺序）再 cache 独有（保持入参顺序）；且不修改入参."
  (seshat-library-test--with-offline-env
    (let* ((local (list (seshat-library-test--plain-item
                         (seshat-library-test--uid "u3"))
                        (seshat-library-test--plain-item
                         (seshat-library-test--uid "u1"))))
           (cached (list (seshat-library-test--plain-item
                          (seshat-library-test--uid "u2"))
                         (seshat-library-test--plain-item
                          (seshat-library-test--uid "u4"))))
           (local-copy (copy-tree local))
           (cached-copy (copy-tree cached))
           (merged (seshat-library--entries-merge local cached)))
      (should (equal (list (seshat-library-test--uid "u3")
                           (seshat-library-test--uid "u1")
                           (seshat-library-test--uid "u2")
                           (seshat-library-test--uid "u4"))
                     (seshat-library-test--uids-of merged)))
      (should (equal local-copy local))
      (should (equal cached-copy cached))
      ;; 合并结果里的 cache 独有项必须是**新** plist：就地改它不能污染入参。
      (plist-put (nth 2 merged) :state 'downloaded)
      (should (eq 'downloaded (plist-get (nth 0 cached) :state))))))

;;; seshat-library--filter-items

(ert-deftest seshat-library--filter-items-keyword ()
  "关键词大小写不敏感，且 name / path / root 三处都能命中；空串等于不过滤."
  (seshat-library-test--with-offline-env
    (let ((items (list (seshat-library-test--plain-item
                        "i1" :root "books" :path "x/Alpha.epub" :name "Alpha.epub")
                       (seshat-library-test--plain-item
                        "i2" :root "Notes" :path "y/beta.epub" :name "beta.epub")
                       (seshat-library-test--plain-item
                        "i3" :root "media" :path "z/gamma.epub" :name "gamma.epub"))))
      ;; 命中 :name
      (should (equal '("i1")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items "alpha"))))
      ;; 命中 :path（路径段，不在文件名里）
      (should (equal '("i2")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items "y/beta"))))
      ;; 命中 :root（大小写不敏感）
      (should (equal '("i2")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items "NOTES"))))
      ;; 空串 / nil → 不过滤
      (should (= 3 (length (seshat-library--filter-items items ""))))
      (should (= 3 (length (seshat-library--filter-items items nil))))
      ;; 不命中 → 空
      (should (null (seshat-library--filter-items items "zzz"))))))

(ert-deftest seshat-library--filter-items-state-and-keyword ()
  "状态过滤与关键词是 AND 关系；`all' 等于不按状态过滤."
  (seshat-library-test--with-offline-env
    (let ((items (list (seshat-library-test--plain-item
                        "i1" :name "alpha.pdf" :state 'downloaded)
                       (seshat-library-test--plain-item
                        "i2" :name "alpha-2.pdf" :state 'missing)
                       (seshat-library-test--plain-item
                        "i3" :name "beta.pdf" :state 'missing))))
      (should (equal '("i2")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items "alpha" 'missing))))
      (should (equal '("i1")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items "alpha" 'downloaded))))
      (should (equal '("i1" "i2")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items "alpha" 'all))))
      (should (equal '("i2" "i3")
                     (seshat-library-test--uids-of
                      (seshat-library--filter-items items nil 'missing))))
      ;; 纯函数：入参未被改动
      (should (= 3 (length items))))))

;;; seshat-library--sort-items

(ert-deftest seshat-library--sort-items-name ()
  "name 升 / 降序都大小写不敏感；nil 值在**两个方向**都排尾."
  (seshat-library-test--with-offline-env
    (let ((items (list (seshat-library-test--plain-item "i1" :name "beta.pdf")
                       (seshat-library-test--plain-item "i2" :name nil)
                       (seshat-library-test--plain-item "i3" :name "Alpha.pdf")
                       (seshat-library-test--plain-item "i4" :name "gamma.pdf"))))
      (should (equal '("i3" "i1" "i4" "i2")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'name))))
      (should (equal '("i4" "i1" "i3" "i2")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'name t))))
      ;; 入参顺序未变（纯函数）
      (should (equal '("i1" "i2" "i3" "i4")
                     (seshat-library-test--uids-of items))))))

(ert-deftest seshat-library--sort-items-numbers-and-fallback ()
  "size / percent 按数值排序（nil 排尾）；未知 key 回落 name."
  (seshat-library-test--with-offline-env
    (let ((items (list (seshat-library-test--plain-item
                        "i1" :name "b.pdf" :size 300 :percent 50)
                       (seshat-library-test--plain-item
                        "i2" :name "a.pdf" :size nil :percent nil)
                       (seshat-library-test--plain-item
                        "i3" :name "c.pdf" :size 100 :percent 4))))
      (should (equal '("i3" "i1" "i2")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'size))))
      (should (equal '("i1" "i3" "i2")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'size t))))
      (should (equal '("i3" "i1" "i2")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'percent))))
      ;; 未知 key → 按 name
      (should (equal '("i2" "i1" "i3")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'no-such-key)))))))

(ert-deftest seshat-library--sort-items-is-stable ()
  "同值的行保持输入顺序（`cl-stable-sort'），升降序都一样."
  (seshat-library-test--with-offline-env
    (let ((items (list (seshat-library-test--plain-item "i1" :size 100)
                       (seshat-library-test--plain-item "i2" :size 100)
                       (seshat-library-test--plain-item "i3" :size 100))))
      (should (equal '("i1" "i2" "i3")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'size))))
      (should (equal '("i1" "i2" "i3")
                     (seshat-library-test--uids-of
                      (seshat-library--sort-items items 'size t)))))))

;;; seshat-library--page-count / --page-slice

(ert-deftest seshat-library--page-count-boundaries ()
  "空 → 1（UI 显示 1/1）；30 条 / 30 → 1；31 条 / 30 → 2；非正整数页大小走默认值."
  (seshat-library-test--with-offline-env
    (should (= 1 (seshat-library--page-count nil)))
    (should (= 1 (seshat-library--page-count (seshat-library-test--many-items 30) 30)))
    (should (= 2 (seshat-library--page-count (seshat-library-test--many-items 31) 30)))
    (should (= 2 (seshat-library--page-count (seshat-library-test--many-items 31))))
    ;; 非法页大小（0 / 负数 / nil）→ 用 `seshat-library-page-size'（默认 30）
    (should (= 2 (seshat-library--page-count (seshat-library-test--many-items 31) 0)))
    (should (= 2 (seshat-library--page-count (seshat-library-test--many-items 31) -5)))))

(ert-deftest seshat-library--page-slice-boundaries ()
  "首页 / 末页不足 / 页码越界夹紧 / 空列表."
  (seshat-library-test--with-offline-env
    (let ((items (seshat-library-test--many-items 31)))
      ;; 首页满页
      (should (= 30 (length (seshat-library--page-slice items 1 30))))
      (should (equal "b01" (plist-get (car (seshat-library--page-slice items 1 30))
                                      :uid)))
      ;; 末页不足
      (should (equal '("b31")
                     (seshat-library-test--uids-of
                      (seshat-library--page-slice items 2 30))))
      ;; 越界夹紧：99 → 末页，0 / 负数 → 首页
      (should (equal '("b31")
                     (seshat-library-test--uids-of
                      (seshat-library--page-slice items 99 30))))
      (should (= 30 (length (seshat-library--page-slice items 0 30))))
      (should (= 30 (length (seshat-library--page-slice items -3 30))))
      ;; 空列表 → nil
      (should (null (seshat-library--page-slice nil 1 30))))))

;;; seshat-library--entries-refresh-remote

(ert-deftest seshat-library--entries-refresh-remote-failure-keeps-cache ()
  "远端拉取失败（`--remote-entries' 返回 nil）→ 不写缓存，返回本地与缓存的合并结果."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    ;; 先放一份可用缓存（模拟「上次刷新成功」）
    (seshat-library--cache-write
     (list (seshat-library-test--plain-item (seshat-library-test--uid "u2"))))
    (cl-letf (((symbol-function 'seshat-library--remote-entries)
               (lambda (_tag &optional _prefix) nil)))
      (let ((merged (seshat-library--entries-refresh-remote)))
        (should (equal (list (seshat-library-test--uid "u1")
                             (seshat-library-test--uid "u2"))
                       (seshat-library-test--uids-of merged)))
        ;; 旧缓存**未被覆盖**：仍是只有 u2 的那份
        (should (equal (list (seshat-library-test--uid "u2"))
                       (seshat-library-test--uids-of
                        (seshat-library--entries-cached))))))))

(ert-deftest seshat-library--entries-refresh-remote-success-writes-cache ()
  "远端成功 → 写缓存（含 `:version 1'），且再读 `--entries-cached' 能取回."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (let ((remote (list (plist-put (seshat-library-test--item
                                    (seshat-library-test--uid "u1") 100 "a.pdf")
                                   :size 4321))))
      (cl-letf (((symbol-function 'seshat-library--remote-entries)
                 (lambda (_tag &optional _prefix) remote)))
        (let ((merged (seshat-library--entries-refresh-remote)))
          (should (equal (list (seshat-library-test--uid "u1"))
                         (seshat-library-test--uids-of merged)))
          ;; 未登记 → `unregistered'
          (should (eq 'unregistered (plist-get (car merged) :state)))
          (should (file-exists-p seshat-library-cache-file))
          (should (string-match-p
                   ":version 1"
                   (seshat-library-test--read-file seshat-library-cache-file)))
          (let ((cached (seshat-library--entries-cached)))
            (should (equal (list (seshat-library-test--uid "u1"))
                           (seshat-library-test--uids-of cached)))
            (should (= 4321 (plist-get (car cached) :size)))
            (should (eq 'cache (plist-get (car cached) :source)))))))))

(ert-deftest seshat-library--offline-chain-is-offline ()
  "全链路零网络：local + cached + merge + 过滤 / 排序 / 分页，在
`seshat-rest--request' 绑成 error 时全部通过。"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (seshat-library--cache-write
     (list (seshat-library-test--plain-item (seshat-library-test--uid "u2")
                                            :name "b.pdf")
           (seshat-library-test--plain-item (seshat-library-test--uid "u3")
                                            :name "c.pdf")))
    (cl-letf (((symbol-function 'seshat-rest--request)
               (lambda (&rest _) (error "网络调用")))
              ((symbol-function 'seshat-rest-list-resources)
               (lambda (&rest _) (error "网络调用")))
              ((symbol-function 'seshat-rest-get-resource)
               (lambda (&rest _) (error "网络调用"))))
      (let* ((merged (seshat-library--entries-merge
                      (seshat-library--entries-local)
                      (seshat-library--entries-cached)))
             (filtered (seshat-library--filter-items merged nil nil))
             (sorted (seshat-library--sort-items filtered 'name))
             (page (seshat-library--page-slice sorted 1 2)))
        (should (equal (list (seshat-library-test--uid "u1")
                             (seshat-library-test--uid "u2")
                             (seshat-library-test--uid "u3"))
                       (seshat-library-test--uids-of merged)))
        (should (= 2 (seshat-library--page-count sorted 2)))
        (should (= 2 (length page)))
        (should (equal "a.pdf" (plist-get (car page) :name)))))))

;;; :pending（批注队列，软依赖）

(ert-deftest seshat-library--pending-count-nil-when-queue-module-missing ()
  "批注队列模块缺失时 `:pending' 为 nil（不是 0——「查不了」与「没有待同步」要区分）."
  (seshat-library-test--with-offline-env
    (let ((seshat-library--pending-feature 'seshat-library-test--no-such-feature))
      (should (null (seshat-library--pending-count (seshat-library-test--uid "u1"))))
      (seshat-state-set-roots
       (list (list "books" seshat-library-test--dir "ondemand")))
      (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
      (should (null (plist-get (car (seshat-library--entries-local)) :pending))))))

(ert-deftest seshat-library--pending-count-from-queue-entries ()
  "模块可用时按 uid 过滤队列条目计数；该 uid 无条目时为 0.
（`featurep' 守卫要求模块**已加载**：用例用 `--with-queue-feature' 把符号塞进
`features' 而**不真的加载**模块，因此「绝不 require」的不变量仍然成立。）"
  (seshat-library-test--with-offline-env
    (seshat-library-test--with-queue-feature
      (cl-letf (((symbol-function 'seshat-reader-annotation-queue-entries)
                 (lambda (&optional uid)
                   (when (or (null uid)
                             (equal uid (seshat-library-test--uid "u1")))
                     (list (list :action 'create
                                 :uid (seshat-library-test--uid "u1"))
                           (list :action 'create
                                 :uid (seshat-library-test--uid "u1")))))))
        (should (= 2 (seshat-library--pending-count
                      (seshat-library-test--uid "u1"))))
        (should (= 0 (seshat-library--pending-count
                      (seshat-library-test--uid "u2"))))))))

;;; 阅读进度进 item（`seshat-reads'）

(ert-deftest seshat-library--item-carries-progress ()
  "`:page' / `:total' / `:percent' 来自 `seshat-reads'；无记录时三项均为 nil."
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (seshat-library-test--register (seshat-library-test--uid "u2") "books" "b.pdf")
    (seshat-reads-record (seshat-library-test--uid "u1") 12 300)
    (let ((items (seshat-library--entries-local)))
      (should (= 12 (plist-get (nth 0 items) :page)))
      (should (= 300 (plist-get (nth 0 items) :total)))
      (should (= 4 (plist-get (nth 0 items) :percent)))
      (should (null (plist-get (nth 1 items) :page)))
      (should (null (plist-get (nth 1 items) :percent))))))

;;; ===========================================================================
;;; 封面集成 + I-OOM 不变量（M9 T5b-2）
;;; ===========================================================================
;;
;; I-OOM 的定义（本组所有用例共同守护的**唯一**不变量）：
;;
;;   任一时刻驻留（已构造、未 flush）的 image 个数 ≤ `seshat-library-page-size'；
;;   翻页与关闭 buffer 必须释放。
;;
;; 三条守恒式（每个场景都断言，符号约定见用例内的 `created' / `flushed'）：
;;
;;   ① `(--length seshat-library--resident)' ≤ page-size
;;   ② `flushed' == 构造总次数 − 当前驻留数     ← 被减数是**构造总次数**，不是页条目数
;;   ③ 关闭 buffer 后 `flushed' == 构造总次数
;;
;; 正断言 P（靶点）：首屏渲染完成后 `created' > 0，且 == 当前页「有封面可用」的
;; 条目数。P 不是装饰：没有它，一个「根本不构造 image」的实现会让 ①②③ 全部
;; 成立（0 ≤ 30、0 == 0 − 0、0 == 0）——这正是反假绿自检用例存在的理由。
;;
;; 桩的边界：桩 `seshat-library--make-cover-image' 与 `image-flush'，**不桩**
;; `create-image'（它是被测对象的下游）。`--make-cover-image' 的桩照抄真实契约
;; （先查驻留表复用 → 命中缓存才「构造」→ 登记），因此 `--resident' 的收支仍由
;; 真代码 `--register-cover' / `--release-covers' / `--release-leaving-covers'
;; 记账，守恒式不是自证。

(defconst seshat-library-test--png-base64
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="
  "一张 1x1 PNG 的 base64（67 字节）.
用于验证 `create-image' 在 `emacs --batch -Q' 下确实能返回 image 对象——这是
「构造不受 `display-graphic-p' 约束」这一分层的实测依据，不靠假设。")

(defvar seshat-library-test--created 0
  "I-OOM 组：`--make-cover-image' **实际构造**（非复用）的次数.")

(defvar seshat-library-test--flushed 0
  "I-OOM 组：`image-flush' 被调用的次数.")

(defvar seshat-library-test--covered nil
  "I-OOM 组：「有封面可用」的 uid 列表（`--make-cover-image' 桩据此决定构造与否）.")

(defun seshat-library-test--write-png (path)
  "把内置 1x1 PNG 写到绝对路径 PATH（建父目录），返回 PATH."
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'binary))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert (base64-decode-string seshat-library-test--png-base64))))
  path)

(defun seshat-library-test--stub-make-cover (uid _file)
  "I-OOM 组的 `--make-cover-image' 桩：照抄真实契约（复用驻留 → 命中缓存才构造 + 登记）.
真实实现用 `create-image' 造对象，这里用一个可辨认的 `(image UID)' 列表代替；
「有没有封面可用」由 `seshat-library-test--covered' 表达（真实实现里对应的判据是
`seshat-covers-cached' 命中）。"
  (or (alist-get uid seshat-library--resident nil nil #'equal)
      (when (member uid seshat-library-test--covered)
        (setq seshat-library-test--created (1+ seshat-library-test--created))
        (seshat-library--register-cover uid (list 'image uid)))))

(defun seshat-library-test--stub-image-flush (&rest _args)
  "I-OOM 组的 `image-flush' 桩：只计数（真 flush 需要真 image 对象）."
  (setq seshat-library-test--flushed (1+ seshat-library-test--flushed))
  nil)

(defmacro seshat-library-test--with-cover-counters (&rest body)
  "把 I-OOM 的三个计数 / 集合归零后执行 BODY."
  (declare (indent 0) (debug t))
  `(let ((seshat-library-test--created 0)
         (seshat-library-test--flushed 0)
         (seshat-library-test--covered nil))
     ,@body))

(defun seshat-library-test--resident ()
  "返回书架 buffer 当前的 `seshat-library--resident'（alist `(UID . IMAGE)'）."
  (with-current-buffer (seshat-library-test--library-buffer)
    seshat-library--resident))

(defun seshat-library-test--resident-labels ()
  "返回驻留表的 uid 短标签序列（排序后，便于断言集合相等）."
  (sort (mapcar (lambda (cell) (seshat-library-test--label (car cell)))
                (seshat-library-test--resident))
        #'string<))

(defun seshat-library-test--covered-on-page ()
  "返回当前页里「有封面可用」的条目数（正断言 P 的期望值）."
  (with-current-buffer (seshat-library-test--library-buffer)
    (cl-count-if (lambda (item)
                   (member (plist-get item :uid) seshat-library-test--covered))
                 (seshat-library--page-slice
                  seshat-library--filtered
                  (seshat-library--clamp-page seshat-library--page)
                  seshat-library--page-size))))

(defun seshat-library-test--assert-positive-p ()
  "正断言 P：`created' > 0 且 == 当前页「有封面可用」的条目数."
  (should (> seshat-library-test--created 0))
  (should (= seshat-library-test--created
             (seshat-library-test--covered-on-page))))

(defun seshat-library-test--open-shelf-with-page-size (n)
  "以页大小 N 打开书架，并把 N 落到 buffer-local（后续翻页沿用同一个页大小）.
两步都要：
- 只在 `let' 上绑 defcustom：出 `let' 之后 buffer 又回落到默认页大小（30），
  后面按「当前页」算的断言就全错；
- 只 `--set-page-size'：首屏先按默认页大小渲染整页、再收窄，会多构造一批随即被
  flush 的 image，正断言 P（`created' == 当前页可用封面数）随之失真。"
  (let ((seshat-library-page-size n))
    (seshat-library))
  (seshat-library-test--set-page-size n))

(defun seshat-library-test--assert-conservation-12 (page-size)
  "断言守恒式 ①②（③ 需要关闭 buffer，由调用方另行断言），返回当前驻留数."
  (let ((resident (length (seshat-library-test--resident))))
    (should (<= resident page-size))
    (should (= seshat-library-test--flushed
               (- seshat-library-test--created resident)))
    resident))

(defun seshat-library-test--assert-conservation-3 ()
  "断言守恒式 ③：关闭 buffer 后 `flushed' == 构造总次数."
  (should (= seshat-library-test--flushed seshat-library-test--created)))

(defun seshat-library-test--function-body-string (symbol)
  "从**源文件**读出 SYMBOL 的 defun 体（去掉 arglist 与 docstring）的 `prin1-to-string'.
不用 `symbol-function'：Emacs 32 默认对加载的 `.el' 做 JIT 原生编译，加载后它是
字节码 / 原生码对象，`prin1-to-string' 会把 docstring 一起印出来——而 docstring
里**必须**提到 `display-graphic-p'（口径说明），断言就会误报。

读源文件也顺带验证了「磁盘上的实现」而不是某个已被改写的运行时定义。"
  (let* ((lib (or (locate-library "seshat-library") ""))
         (el (concat (file-name-sans-extension lib) ".el"))
         (file (if (file-exists-p el) el lib))
         (form (with-temp-buffer
                 (insert-file-contents file)
                 (goto-char (point-min))
                 (let ((found nil))
                   (condition-case nil
                       (while (not found)
                         (let ((candidate (read (current-buffer))))
                           (when (and (consp candidate)
                                      (eq 'defun (car candidate))
                                      (eq symbol (cadr candidate)))
                             (setq found candidate))))
                     (end-of-file nil))
                   found))))
    (should (consp form))
    (let ((rest (cdddr form)))          ; (ARGLIST [DOCSTRING] . BODY)
      (when (stringp (car rest))
        (setq rest (cdr rest)))
      (prin1-to-string (cons 'progn rest)))))

;;; `--make-cover-image'：唯一构造点（不受 display-graphic-p 约束）

(ert-deftest seshat-library-cover-image-real-create-image-in-batch ()
  "批处理下（`display-graphic-p' 为 nil）真 `create-image' 仍返回 image 对象.
这是「构造与显示分层」的实测依据：构造不受图形环境约束，只有显示才受。"
  (seshat-library-test--with-ui-env
    (should-not (display-graphic-p))
    (let* ((png (seshat-library-test--write-png
                 (expand-file-name "covers/01J8ZKQ2AAAAAAAAAAAAAAAAV1.png"
                                   seshat-library-test--dir)))
           (uid (seshat-library-test--uid "u1")))
      (with-temp-buffer
        (cl-letf (((symbol-function 'seshat-covers-cached)
                   (lambda (candidate) (and (equal candidate uid) png))))
          (let ((image (seshat-library--make-cover-image uid png)))
            (should (consp image))
            (should (eq 'image (car image)))
            (should (eq 'png (plist-get (cdr image) :type)))
            ;; 登记进驻留表，且第二次调用复用同一个对象（不重复构造）
            (should (eq image (alist-get uid seshat-library--resident nil nil #'equal)))
            (should (eq image (seshat-library--make-cover-image uid png)))
            (should (= 1 (length seshat-library--resident)))))))))

(ert-deftest seshat-library-cover-image-nil-without-cache ()
  "缓存里没有封面时返回 nil（**绝不同步生成**），也不登记任何驻留."
  (seshat-library-test--with-ui-env
    (let ((uid (seshat-library-test--uid "u1")))
      (with-temp-buffer
        (cl-letf (((symbol-function 'seshat-covers-cached) (lambda (_uid) nil))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) (error "不该构造 image"))))
          (should-not (seshat-library--make-cover-image uid "/no/such/file.pdf"))
          (should-not seshat-library--resident))))))

(ert-deftest seshat-library-cover-image-cached-path-must-exist ()
  "缓存路径已失效（文件被删）时返回 nil，不拿坏路径去构造."
  (seshat-library-test--with-ui-env
    (let ((uid (seshat-library-test--uid "u1")))
      (with-temp-buffer
        (cl-letf (((symbol-function 'seshat-covers-cached)
                   (lambda (_uid) (expand-file-name "gone.png" seshat-library-test--dir)))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) (error "不该构造 image"))))
          (should-not (seshat-library--make-cover-image uid "/no/such/file.pdf"))
          (should-not seshat-library--resident))))))

(ert-deftest seshat-library-make-cover-image-has-no-display-graphic-p ()
  "`--make-cover-image' 的函数体**不含** `display-graphic-p'；`--insert-cover' 才含.
docstring 里必须提到它（分层口径），所以断言落在函数体上——拿整份
`symbol-function' 或 `documentation' 判断都会把 docstring 算进去。"
  (let ((body (seshat-library-test--function-body-string
               'seshat-library--make-cover-image))
        (insert-body (seshat-library-test--function-body-string
                      'seshat-library--insert-cover)))
    (should (stringp body))
    (should-not (string-match-p "display-graphic-p" body))
    (should (string-match-p "display-graphic-p"
                            (documentation 'seshat-library--make-cover-image)))
    (should (string-match-p "display-graphic-p" insert-body))))

;;; `--insert-cover'：显示层守卫（唯一检查 display-graphic-p 的地方）

(ert-deftest seshat-library-insert-cover-placeholder-without-graphics ()
  "`display-graphic-p' 为 nil 时插占位文本，且**不**调 `insert-image'."
  (seshat-library-test--with-ui-env
    (let ((insert-image-calls 0)
          (item (seshat-library-test--ui-item "u1" :name "alpha.pdf")))
      (cl-letf (((symbol-function 'insert-image)
                 (lambda (&rest _) (setq insert-image-calls (1+ insert-image-calls))))
                ((symbol-function 'seshat-library--make-cover-image)
                 (lambda (&rest _) (list 'image "stub")))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (with-temp-buffer
          (seshat-library--insert-cover item)
          (should (= 0 insert-image-calls))
          (should (equal (seshat-library--cover-placeholder item)
                         (buffer-string))))))))

(ert-deftest seshat-library-insert-cover-image-branch-same-columns ()
  "image 分支把**同一个**占位字符串交给 `insert-image' 当 STRING（列数天然对齐）."
  (seshat-library-test--with-ui-env
    (let ((item (seshat-library-test--ui-item "u1" :name "alpha.pdf"))
          (captured nil))
      (cl-letf (((symbol-function 'insert-image)
                 (lambda (image string &rest _args)
                   (setq captured (list image string))
                   (insert string)))
                ((symbol-function 'seshat-library--make-cover-image)
                 (lambda (&rest _) (list 'image "stub")))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (with-temp-buffer
          (seshat-library--insert-cover item)
          (should (equal (list 'image "stub")
                         (car captured)))
          ;; 与占位分支插的文本完全一致 ⇒ 列数一致
          (should (equal (seshat-library--cover-placeholder item)
                         (cadr captured)))
          (should (equal (seshat-library--cover-placeholder item)
                         (buffer-string))))))))

(ert-deftest seshat-library-cover-placeholder-width-and-label ()
  "占位文本：书名首字标签 + 定宽补空格；书名缺失时退回 `[书]'."
  (let* ((cols (seshat-library--cover-columns))
         (item (seshat-library-test--ui-item "u1" :name "alpha.pdf"))
         (no-name (seshat-library-test--ui-item "u1" :name nil))
         (placeholder (seshat-library--cover-placeholder item)))
    (should (>= cols 2))
    (should (= cols (string-width placeholder)))
    (should (string-prefix-p "[a]" placeholder))
    (should (= cols (string-width (seshat-library--cover-placeholder no-name))))
    (should (string-prefix-p "[书]" (seshat-library--cover-placeholder no-name)))))

;;; I-OOM：三场景（每个都跑 P + ①②③）

(ert-deftest seshat-library-i-oom-scenario-a-normal-page ()
  "场景 (a) 正常页：整页都有封面 ⇒ P（created == 页内可用封面数）+ ①②③ 成立."
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((uids (list (seshat-library-test--uid "u1")
                        (seshat-library-test--uid "u2")
                        (seshat-library-test--uid "u3"))))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf")
                    (seshat-library-test--ui-item "u3" :name "c.pdf"))
              seshat-library-test--covered uids)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library-test--open-shelf-with-page-size 3)
          ;; 正断言 P
          (seshat-library-test--assert-positive-p)
          (should (= 3 seshat-library-test--created))
          ;; ① ②
          (should (= 3 (seshat-library-test--assert-conservation-12 3)))
          (should (equal '("u1" "u2" "u3")
                         (seshat-library-test--resident-labels)))
          ;; ③
          (kill-buffer (seshat-library-test--library-buffer))
          (seshat-library-test--assert-conservation-3))))))

(ert-deftest seshat-library-i-oom-scenario-b-placeholders-on-page ()
  "场景 (b) 页内含占位条目：P（created == 可用封面数 < 页条目数）+ ①②③ 成立.
本场景专测守恒式 ② 的**收支口径**：被减数必须是构造总次数，不是页条目数——
用页条目数做被减数时这里会差 1（占位条目没构造过）。
"
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((uids (list (seshat-library-test--uid "u1")
                        (seshat-library-test--uid "u2"))))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf")
                    (seshat-library-test--ui-item "u3" :name "c.pdf"))
              seshat-library-test--covered uids)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library-test--open-shelf-with-page-size 3)
          (seshat-library-test--assert-positive-p)
          ;; created 少于页条目数（u3 走占位分支，没构造）
          (should (= 2 seshat-library-test--created))
          (should (< seshat-library-test--created 3))
          (should (= 2 (seshat-library-test--assert-conservation-12 3)))
          (should (equal '("u1" "u2") (seshat-library-test--resident-labels)))
          (kill-buffer (seshat-library-test--library-buffer))
          (seshat-library-test--assert-conservation-3))))))

(ert-deftest seshat-library-i-oom-scenario-c-last-page-partial ()
  "场景 (c) 末页不满：条目数 < page-size，P + ①②③ 仍成立."
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((uids (list (seshat-library-test--uid "u1")
                        (seshat-library-test--uid "u2"))))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf"))
              seshat-library-test--covered uids)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library-test--open-shelf-with-page-size 5)
          (seshat-library-test--assert-positive-p)
          (should (= 2 seshat-library-test--created))
          (should (= 2 (seshat-library-test--assert-conservation-12 5)))
          (kill-buffer (seshat-library-test--library-buffer))
          (seshat-library-test--assert-conservation-3))))))

;;; I-OOM：翻页 / 去重 / 关闭

(ert-deftest seshat-library-i-oom-paging-keeps-resident-bounded ()
  "翻页 10 次（n/p 各 5 次）后驻留数始终 ≤ page-size，且 ② 每步都成立.
另断言驻留集合 ⊆ 当前页（「先算离开集合再释放」没有把新页要用的 image 误 flush，
也没有漏掉旧页的）。
"
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((uids (mapcar (lambda (label) (seshat-library-test--uid label))
                          '("u1" "u2" "u3" "u4"))))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf")
                    (seshat-library-test--ui-item "u3" :name "c.pdf")
                    (seshat-library-test--ui-item "u4" :name "d.pdf"))
              seshat-library-test--covered uids)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library-test--open-shelf-with-page-size 2)
          (seshat-library-test--assert-positive-p)
          (let ((step 0))
            (dotimes (_ 5)
              (with-current-buffer (seshat-library-test--library-buffer)
                (seshat-library-next-page))
              (setq step (1+ step))
              (seshat-library-test--assert-conservation-12 2)
              (should (<= (length (seshat-library-test--resident)) 2))
              ;; 驻留集合 ⊆ 当前页
              (let ((page-labels (seshat-library-test--rows)))
                (dolist (label (seshat-library-test--resident-labels))
                  (should (member label page-labels)))))
            (dotimes (_ 5)
              (with-current-buffer (seshat-library-test--library-buffer)
                (seshat-library-previous-page))
              (setq step (1+ step))
              (seshat-library-test--assert-conservation-12 2))
            (should (= 10 step)))
          ;; 同页重渲染（标记动作会走 --render）不新增构造、不 flush
          (let ((created-before seshat-library-test--created)
                (flushed-before seshat-library-test--flushed))
            (with-current-buffer (seshat-library-test--library-buffer)
              (seshat-library--render))
            (should (= created-before seshat-library-test--created))
            (should (= flushed-before seshat-library-test--flushed)))
          (kill-buffer (seshat-library-test--library-buffer))
          (seshat-library-test--assert-conservation-3))))))

(ert-deftest seshat-library-i-oom-same-uid-constructed-once ()
  "同一 uid 重复渲染同一页只构造一次（`created' 不增）.
桩在 `create-image' 这一层（真 `--make-cover-image' 跑起来）：去重逻辑在
`seshat-library--register-cover' 里，桩掉 `--make-cover-image' 就测不到它。"
  (seshat-library-test--with-ui-env
    (let* ((png (seshat-library-test--write-png
                 (expand-file-name "covers/01J8ZKQ2AAAAAAAAAAAAAAAAV1.png"
                                   seshat-library-test--dir)))
           (uid (seshat-library-test--uid "u1"))
           (creates 0))
      (setq seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                  (seshat-library-test--ui-item "u2" :name "b.pdf")))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'seshat-covers-cached)
                 (lambda (candidate) (and (equal candidate uid) png)))
                ((symbol-function 'insert-image) (lambda (&rest _) nil))
                ((symbol-function 'create-image)
                 (lambda (&rest _)
                   (setq creates (1+ creates))
                   (list 'image creates))))
        (seshat-library)
        (should (= 1 creates))
        (should (equal (list uid) (mapcar #'car (seshat-library-test--resident))))
        ;; 重复渲染同一页：不再构造（驻留表命中即复用）
        (with-current-buffer (seshat-library-test--library-buffer)
          (seshat-library--render)
          (seshat-library--render))
        (should (= 1 creates))
        (should (= 1 (length (seshat-library-test--resident))))
        ;; 直接再取一次同一 uid 的封面：返回驻留对象，仍不构造
        ;; （`--resident' 是 buffer-local，所以必须在书架 buffer 里调）
        (with-current-buffer (seshat-library-test--library-buffer)
          (should (seshat-library--make-cover-image uid png)))
        (should (= 1 creates))))))

(ert-deftest seshat-library-i-oom-kill-buffer-flushes-all ()
  "关闭 buffer：`kill-buffer-hook' 释放全部驻留（`--resident' 为空 + ③ 成立）."
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((uids (list (seshat-library-test--uid "u1")
                        (seshat-library-test--uid "u2"))))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf"))
              seshat-library-test--covered uids)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library-test--open-shelf-with-page-size 2)
          (seshat-library-test--assert-positive-p)
          (let ((buffer (seshat-library-test--library-buffer)))
            ;; 钩子确实挂在 buffer-local
            (with-current-buffer buffer
              (should (memq 'seshat-library--release-all-covers kill-buffer-hook)))
            ;; 直接跑钩子函数：驻留清空 + 队列清空
            (with-current-buffer buffer
              (seshat-library--release-all-covers)
              (should-not seshat-library--resident))
            (should (= 2 seshat-library-test--flushed))
            (should (memq 'covers-queue-clear (seshat-library-test--call-names)))
            ;; 重新渲染后再 kill-buffer：钩子自动释放（③）
            (with-current-buffer buffer
              (seshat-library--render))
            (should (= 2 (length (seshat-library-test--resident))))
            (kill-buffer buffer)
            (should-not (buffer-live-p buffer))
            (seshat-library-test--assert-conservation-3)
            (should (= 4 seshat-library-test--flushed))))))))

(ert-deftest seshat-library-i-oom-positive-assertion-fails-without-graphic-stub ()
  "反假绿自检：**去掉** `display-graphic-p' 桩（回到批处理真实值 nil）后正断言 P 必须失败.
去桩后 `--insert-cover' 走占位分支，`--make-cover-image' 根本不被调用 ⇒
`created' 为 0 ⇒ P 的第一个断言失败。若这里仍然全绿，说明 P 写错了（例如被写在
桩外面、或断言了错的对象）——那要修 P，不能删自检。

本用例**故意**包含一个预期失败的 ERT 断言：用 `should-error' 包住
`--assert-positive-p'，并要求错误信息里出现 P 的失败形态。"
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((uids (list (seshat-library-test--uid "u1")
                        (seshat-library-test--uid "u2"))))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf"))
              seshat-library-test--covered uids)
        ;; 注意：这里**不**桩 `display-graphic-p'（批处理下它就是 nil）
        (cl-letf (((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library)
          (seshat-library-test--set-page-size 2)
          (should-not (display-graphic-p))
          (should (= 0 seshat-library-test--created))
          (should-not (seshat-library-test--resident))
          ;; P 必须失败：created 为 0，不满足 > 0
          (let ((err (should-error (seshat-library-test--assert-positive-p)
                                   :type 'ert-test-failed)))
            (should (string-match-p "created"
                                    (prin1-to-string err)))))))))

;;; 队列联动与行级重绘

(ert-deftest seshat-library-queue-cover-only-for-downloaded-uncached ()
  "只有「已下载 + 无缓存 + 无负缓存」的条目入队；回调固定为 `--cover-ready'."
  (seshat-library-test--with-ui-env
    (let* ((books-dir (file-name-as-directory
                       (expand-file-name "books/" seshat-library-test--dir)))
           (file-a (seshat-library-test--write-file
                    (expand-file-name "a.pdf" books-dir) "x"))
           (file-b (seshat-library-test--write-file
                    (expand-file-name "b.pdf" books-dir) "x"))
           (file-d (seshat-library-test--write-file
                    (expand-file-name "d.pdf" books-dir) "x")))
      (seshat-state-set-roots (list (list "books" books-dir "ondemand")))
      (setq seshat-library-test--ui-roots (list (list "books" books-dir "ondemand"))
            seshat-library-test--ui-items
            (list (seshat-library-test--ui-item "u1" :path "a.pdf" :name "a.pdf")
                  (seshat-library-test--ui-item "u2" :path "b.pdf" :name "b.pdf")
                  ;; u3：未下载（本地无文件）⇒ 不入队
                  (seshat-library-test--ui-item "u3" :path "c.pdf" :name "c.pdf"
                                                :state 'missing)
                  ;; u4：已下载但有负缓存 ⇒ 不入队
                  (seshat-library-test--ui-item "u4" :path "d.pdf" :name "d.pdf"))
            ;; u2 已有缓存 ⇒ 不入队；u4 有负缓存
            seshat-library-test--ui-covers
            (list (cons (seshat-library-test--uid "u2") "/fake/u2.png"))
            seshat-library-test--ui-cover-failed
            (list (seshat-library-test--uid "u4")))
      (seshat-library)
      (should (equal (list (list (seshat-library-test--uid "u1") file-a))
                     (mapcar (lambda (call) (list (nth 0 call) (nth 1 call)))
                             seshat-library-test--ui-cover-queue)))
      (should (eq #'seshat-library--cover-ready
                  (nth 2 (car seshat-library-test--ui-cover-queue))))
      ;; 文件存在性由 `--item-local-file' 校验：u3 的 c.pdf 根本不存在
      (should-not (file-exists-p (expand-file-name "c.pdf" books-dir)))
      (should (file-exists-p file-b))
      (should (file-exists-p file-d)))))

(ert-deftest seshat-library-cover-ready-redraws-only-that-line ()
  "`--cover-ready' 只重绘该 uid 的行：构造数 +1、驻留只增该 uid、其它行不变.
uid 不在当前页时静默返回（不构造、不改 buffer）。"
  (seshat-library-test--with-ui-env
    (seshat-library-test--with-cover-counters
      (let ((u1 (seshat-library-test--uid "u1"))
            (u2 (seshat-library-test--uid "u2")))
        (setq seshat-library-test--ui-items
              (list (seshat-library-test--ui-item "u1" :name "a.pdf")
                    (seshat-library-test--ui-item "u2" :name "b.pdf")))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'seshat-library--make-cover-image)
                   #'seshat-library-test--stub-make-cover)
                  ((symbol-function 'image-flush)
                   #'seshat-library-test--stub-image-flush))
          (seshat-library)
          ;; 首屏没有封面可用 ⇒ created = 0
          (should (= 0 seshat-library-test--created))
          (let ((line-before (seshat-library-test--line "u1")))
            ;; 封面就绪：只重绘 u1
            (setq seshat-library-test--covered (list u1))
            (should (seshat-library--cover-ready u1 "/fake/u1.png"))
            (should (= 1 seshat-library-test--created))
            (should (equal (list u1)
                           (mapcar #'car (seshat-library-test--resident))))
            (should (equal '("u1" "u2") (seshat-library-test--rows)))
            (should (equal line-before (seshat-library-test--line "u1"))))
          ;; 不在当前页的 uid：静默返回
          (should-not (seshat-library--cover-ready
                       (seshat-library-test--uid "u3") "/fake/u3.png"))
          (should (= 1 seshat-library-test--created))
          ;; buffer 不存在时也不报错
          (kill-buffer (seshat-library-test--library-buffer))
          (should-not (seshat-library--cover-ready u2 "/fake/u2.png"))
          (should (= 1 seshat-library-test--created)))))))

;;; 修复 3：批注队列软依赖「只查 featurep，绝不 require」+ 一次读取
;;
;; 不变量：打开书架是**只读视图**，不得改变运行态。批注队列模块顶层在
;; `seshat-reader-annotation-queue-auto-sync' 非 nil（默认即非 nil）时注册 300 秒
;; 联网同步定时器，因此「数一下待同步批注」绝不能 require 它。
;; 辅助宏 `seshat-library-test--with-queue-feature' 定义在文件前部的测试辅助区。


(ert-deftest seshat-library--entries-local-never-requires-queue-module ()
  "打开书架（`--entries-local' / `--entries-cached'）**不 require** 批注队列模块。
不变量：只读视图不得改变运行态——队列模块顶层会注册 300 秒联网同步定时器。"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (seshat-library--cache-write
     (list (seshat-library-test--plain-item (seshat-library-test--uid "u2"))))
    (let ((required nil))
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &optional _file _noerror)
                   (push feature required)
                   (when (eq feature 'seshat-reader-annotation-queue)
                     (error "只读视图不得 require 批注队列模块"))
                   nil))
                ;; 刷新路径会拉远端：桩成「失败」→ 走离线合并（零网络）
                ((symbol-function 'seshat-library--remote-entries)
                 (lambda (&rest _) nil)))
        (should (= 1 (length (seshat-library--entries-local))))
        (should (= 1 (length (seshat-library--entries-cached))))
        ;; ROOTS 的元素是 `(TAG DIR MODE)' 元组（`seshat-library--roots' 的原形）：
        ;; `--collect' 用 `nth' 取 TAG / DIR，传 `(list "books")' 这种字符串列表会
        ;; 当场抛 `wrong-type-argument listp'。
        (should (= 2 (length (seshat-library--entries-refresh-remote
                              (list (list "books" seshat-library-test--dir
                                          "ondemand")))))))
      (should-not (memq 'seshat-reader-annotation-queue required)))
    ;; 模块没被加载：`:pending' 为 nil（UI 显示「—」），不是 0
    (should-not (featurep 'seshat-reader-annotation-queue))
    (should (null (plist-get (car (seshat-library--entries-local)) :pending)))))

(ert-deftest seshat-library--entries-local-reads-queue-once ()
  "100 本书时队列文件只被读 **1 次**（批量路径必须在循环外建一次索引）。
修复前是「每条 item 读一次队列文件」= 100 次 IO。"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (dotimes (i 100)
      (seshat-library-test--register
       (seshat-library-test--gen-uid i) "books" (format "b%d.pdf" i)))
    (seshat-library-test--with-queue-feature
      (let ((reads 0))
        (cl-letf (((symbol-function 'seshat-reader-annotation-queue-entries)
                   (lambda (&optional _uid)
                     (setq reads (1+ reads))
                     (list (list :action 'create
                                 :uid (seshat-library-test--gen-uid 1))
                           (list :action 'delete :id "x")))))
          (let ((items (seshat-library--entries-local)))
            (should (= 100 (length items)))
            ;; 只读一次队列文件，且每条的 :pending 都算出来了（delete 全局计入）
            (should (= 1 reads))
            (should (equal 2 (plist-get (nth 1 items) :pending)))
            (should (equal 1 (plist-get (nth 2 items) :pending)))))))))

(ert-deftest seshat-library--pending-index-groups-by-uid ()
  "索引按 uid 分组，delete 类条目计入**每一本**（队列语义：delete 按 id 定位）。
（`seshat-reader-annotation-queue-entries' 对任意 uid 都会带上 delete 条目，
所以每本书的待同步数 = 全局 delete 数 + 该 uid 自己的条目数。）"
  (seshat-library-test--with-offline-env
    (seshat-library-test--with-queue-feature
      (cl-letf (((symbol-function 'seshat-reader-annotation-queue-entries)
                 (lambda (&optional _uid)
                   (list (list :action 'create :uid (seshat-library-test--uid "u1"))
                         (list :action 'create :uid (seshat-library-test--uid "u1"))
                         (list :action 'create :uid (seshat-library-test--uid "u2"))
                         (list :action 'delete :id "a")
                         (list :action 'create :uid nil)))))
        (let ((index (seshat-library--pending-index)))
          (should (equal 1 (plist-get index :deletes)))
          ;; 每本书 = 全局 delete 数 + 该 uid 自己的条目数：u1 有 2 条 create
          (should (equal 3 (seshat-library--pending-count-in-index
                            index (seshat-library-test--uid "u1"))))
          (should (equal 2 (seshat-library--pending-count-in-index
                            index (seshat-library-test--uid "u2"))))
          ;; 队列里没有的 uid → 只有全局 delete 数（不是 0）
          (should (equal 1 (seshat-library--pending-count-in-index
                            index (seshat-library-test--uid "u3"))))
          ;; 单条查询入口与索引口径一致
          (should (equal 3 (seshat-library--pending-count
                            (seshat-library-test--uid "u1"))))
          ;; nil 索引 = 查不了（nil），不是 0
          (should-not (seshat-library--pending-count-in-index
                       nil (seshat-library-test--uid "u1"))))))))

(ert-deftest seshat-library--pending-index-nil-when-read-fails ()
  "队列文件损坏（`entries' 抛错）时索引为 nil 且不抛错：书架必须照常打开。"
  (seshat-library-test--with-offline-env
    (seshat-library-test--with-queue-feature
      (cl-letf (((symbol-function 'seshat-reader-annotation-queue-entries)
                 (lambda (&optional _uid) (error "队列文件损坏"))))
        (should-not (seshat-library--pending-index))
        (should-not (seshat-library--pending-count (seshat-library-test--uid "u1")))))))

;;; 修复 4：远端清单刷新的一次性索引 + 总条数上限

(ert-deftest seshat-library--entries-refresh-remote-indexes-state-once ()
  "刷新 300 条远端清单时**不再**逐条线性反查状态库（`seshat-state-path-for-uid' 0 次）。
修复前每条一次 O(n) 反查 = O(n²)，异常服务端能把 `g' 拖到无响应。"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--gen-uid 0) "books" "a.pdf")
    (let ((remote (mapcar (lambda (i)
                            (seshat-library-test--item
                             (seshat-library-test--gen-uid i) 100
                             (format "r%d.pdf" i)))
                          (number-sequence 0 299)))
          (lookups 0))
      (cl-letf (((symbol-function 'seshat-library--remote-entries)
                 (lambda (_tag &optional _prefix) remote))
                ((symbol-function 'seshat-state-path-for-uid)
                 (lambda (_uid) (setq lookups (1+ lookups)) nil)))
        (let ((merged (seshat-library--entries-refresh-remote)))
          (should (= 300 (length merged)))
          ;; 一次性索引：零次线性反查
          (should (= 0 lookups))
          ;; 已登记的那本仍按状态库判定（索引口径与反查等价）
          (should (= 1 (length (cl-remove-if-not
                                (lambda (item) (eq 'missing (plist-get item :state)))
                                merged)))))))))

(ert-deftest seshat-library--entries-refresh-remote-caps-entries ()
  "远端返回条数超过 `seshat-library-max-entries' 时截断 + warn，**不抛错**。
（DoS 护栏：`--max-pages' × `--page-limit' 最多 100 万条。）"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (let ((seshat-library-max-entries 100)
          (remote (mapcar (lambda (i)
                            (seshat-library-test--item
                             (seshat-library-test--gen-uid i)
                             10 (format "r%d.pdf" i)))
                          (number-sequence 0 299)))
          (warns nil))
      (cl-letf (((symbol-function 'seshat-library--remote-entries)
                 (lambda (_tag &optional _prefix) remote))
                ((symbol-function 'seshat-log)
                 (lambda (level &rest args)
                   (when (eq level 'warn) (push args warns)))))
        (let ((merged (seshat-library--entries-refresh-remote)))
          (should (= 100 (length merged)))
          ;; 截断也写进缓存：下次打开书架不会又拉 300 条
          (should (= 100 (length (seshat-library--entries-cached))))
          (should (= 1 (length warns)))
          (should (string-match-p "截断" (apply #'format (car warns)))))))))

(ert-deftest seshat-library--entries-refresh-remote-normal-path-parity ()
  "正常路径（未超上限）结果与修复前一致：uid 顺序、`:source'、`:state' 口径不变。"
  (seshat-library-test--with-offline-env
    (seshat-state-set-roots (list (list "books" seshat-library-test--dir "ondemand")))
    (seshat-library-test--register (seshat-library-test--uid "u1") "books" "a.pdf")
    (let ((remote (list (seshat-library-test--item
                         (seshat-library-test--uid "u1") 100 "a.pdf")
                        (seshat-library-test--item
                         (seshat-library-test--uid "u2") 100 "b.pdf"))))
      (cl-letf (((symbol-function 'seshat-library--remote-entries)
                 (lambda (_tag &optional _prefix) remote)))
        (let ((merged (seshat-library--entries-refresh-remote)))
          (should (equal (list (seshat-library-test--uid "u1")
                               (seshat-library-test--uid "u2"))
                         (seshat-library-test--uids-of merged)))
          ;; u1 已登记 → missing（本地文件不存在）；u2 未登记 → unregistered
          (should (eq 'missing (plist-get (nth 0 merged) :state)))
          (should (eq 'unregistered (plist-get (nth 1 merged) :state)))
          ;; 经合并层回来的条目 `:source' 为 cache（缓存刚被写入）
          (should (eq 'cache (plist-get (nth 1 merged) :source))))))))

(provide 'seshat-library-test)

;;; seshat-library-test.el ends here
