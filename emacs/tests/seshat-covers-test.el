;;; seshat-covers-test.el --- ERT tests for seshat-covers  -*- lexical-binding: t; -*-

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

;; `seshat-covers'（封面三级回退）的 ERT 测试套件。覆盖四类契约：
;;
;; 1. uid 形态守卫（安全边界）与路径不变量（基路径不含扩展名）；
;; 2. 三级回退的**判定顺序**：已命中 → 已失败 → L1 → L2 → L3，以及负缓存的
;;    写入条件（确定性失败才写）；
;; 3. 子进程边界：超时、非零退出码、源图超限、嗅探失败，一律降级不抛错；
;; 4. 串行限速队列：去重、每次 1 本、callback 抛错不影响后续、清理。
;;
;; **测试隔离是硬要求**：所有用例都 `cl-letf' 桩掉 `executable-find' 与子进程
;; 入口 `seshat-covers--run'，因此**不依赖**本机是否装 `unzip' / `mutool'，
;; 也**不真起子进程**。每个用例把 `seshat-covers-dir' 与
;; `temporary-file-directory' 都绑到 `make-temp-file' 建的临时目录，结束递归
;; 删除——绝不污染用户真实缓存。定时器由 `run-with-idle-timer' 桩替（换成
;; 3600 秒后的真定时器，测试期间不会触发），`seshat-covers-queue-clear' 收尾
;; 取消，避免跨用例污染。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-covers)

;;; 样本数据

(defconst seshat-covers-test--uid "0123456789ABCDEFGHJKMNPQRS"
  "合法 uid（26 位 Crockford Base32，排除 I / L / O / U）.")

(defconst seshat-covers-test--uid-2 "0123456789ABCDEFGHJKMNPQRT"
  "第二个合法 uid.")

(defconst seshat-covers-test--uid-3 "ZZZZZZZZZZZZZZZZZZZZZZZZZZ"
  "第三个合法 uid.")

(defconst seshat-covers-test--png (unibyte-string 137 80 78 71 13 10 26 10 0 0 0 13)
  "PNG 魔数样本（只用于字节嗅探，不是可解码图片）.")

(defconst seshat-covers-test--jpg (unibyte-string 255 216 255 224 0 16 74 70 73 70)
  "JPEG 魔数样本.")

(defconst seshat-covers-test--gif (unibyte-string 71 73 70 56 57 97 1 0)
  "GIF 魔数样本.")

(defconst seshat-covers-test--webp
  (unibyte-string 82 73 70 70 36 0 0 0 87 69 66 80 86 80 56 32)
  "WebP 魔数样本.")

;;; 测试辅助

(defun seshat-covers-test--make-temp-dir ()
  "在 /tmp 下建一个临时目录并返回其绝对路径（带结尾斜杠）.
优先用系统 /tmp：`temporary-file-directory' 会跟随 `TMPDIR'，而本机 `TMPDIR'
可能被设为仓库根，那时临时目录会建进工作树。"
  (let* ((root (file-name-as-directory
                (if (file-directory-p "/tmp") "/tmp" temporary-file-directory)))
         (temporary-file-directory root))
    (file-name-as-directory (make-temp-file "seshat-covers-test-" t))))

(defmacro seshat-covers-test--with-env (&rest body)
  "在独立临时缓存目录与干净模块状态下执行 BODY.
BODY 期间 `seshat-covers-dir' 指向临时目录下**尚未创建**的 `covers/'（惰性
建目录因此可测），`temporary-file-directory' 也指向同一临时目录（子进程临时
文件不落工作树），队列 / 定时器 / 熔断计数状态从零开始。结束后清队列、取消
定时器、递归删除临时目录。

熔断状态（`seshat-covers--consecutive-failures' / `--cooldown-until'）必须一并
绑成初值：它们是模块级 defvar，跨用例残留会让「连续失败 5 次」这类断言随执行
顺序漂移。"
  `(let* ((seshat-covers-test--root (seshat-covers-test--make-temp-dir))
          (temporary-file-directory seshat-covers-test--root)
          (seshat-covers-dir (expand-file-name "covers/" seshat-covers-test--root))
          (seshat-covers--queue nil)
          (seshat-covers--timer nil)
          (seshat-covers--running nil)
          (seshat-covers--active-uid nil)
          (seshat-covers--consecutive-failures 0)
          (seshat-covers--cooldown-until nil)
          (seshat-covers-timeout 1)
          (seshat-covers-max-bytes (* 4 1024 1024)))
     (unwind-protect
         (cl-letf (((symbol-function 'run-with-idle-timer)
                    (lambda (_secs _repeat fn) (run-at-time 3600 nil fn))))
           ,@body)
       (seshat-covers-queue-clear)
       (ignore-errors (delete-directory seshat-covers-test--root t)))))

(defun seshat-covers-test--write (file bytes)
  "把 BYTES 原样写入 FILE（自动建父目录），返回 FILE。"
  (let ((coding-system-for-write 'no-conversion))
    (make-directory (file-name-directory file) t)
    (write-region bytes nil file nil 'silent))
  file)

(defun seshat-covers-test--executable-find-stub (&rest names)
  "返回一个 `executable-find' 桩：只有 NAMES 里的名字返回路径，其余 nil。"
  (lambda (name &optional _remote)
    (when (member name names)
      (concat "/usr/bin/" name))))

(defun seshat-covers-test--out-arg (command)
  "返回 COMMAND 里 `-o' 后面的参数（`mutool draw' 的输出路径）。"
  (cadr (member "-o" command)))

(defun seshat-covers-test--cache-file (uid ext)
  "返回临时缓存目录里 UID.EXT 的绝对路径。"
  (expand-file-name (concat uid "." ext) seshat-covers-dir))

;;; uid 形态与路径

(ert-deftest seshat-covers-test-uid-valid-p ()
  "26 位 Crockford Base32 合法；其余形态一律非法。"
  (should (seshat-covers--uid-valid-p seshat-covers-test--uid))
  (should (seshat-covers--uid-valid-p seshat-covers-test--uid-3))
  ;; 长度
  (should-not (seshat-covers--uid-valid-p (substring seshat-covers-test--uid 0 25)))
  (should-not (seshat-covers--uid-valid-p (concat seshat-covers-test--uid "Z")))
  (should-not (seshat-covers--uid-valid-p ""))
  ;; 小写（`case-fold-search' 必须绑 nil，否则会被误判合法）
  (should-not (seshat-covers--uid-valid-p (downcase seshat-covers-test--uid)))
  ;; 被排除的字符 I / L / O / U
  (dolist (ch '("I" "L" "O" "U"))
    (should-not (seshat-covers--uid-valid-p
                 (concat (substring seshat-covers-test--uid 0 25) ch))))
  ;; 路径注入字符
  (dolist (bad '("../0123456789ABCDEFGHJKMNPQ" "0123456789ABCDEFGHJKMNPQR/"
                 "0123456789ABCDEFGHJKMNPQ. " "0123456789ABCDEFGHJKMNPQR?"))
    (should-not (seshat-covers--uid-valid-p bad)))
  ;; 非字符串
  (should-not (seshat-covers--uid-valid-p nil))
  (should-not (seshat-covers--uid-valid-p 12345))
  (should-not (seshat-covers--uid-valid-p '("0123456789ABCDEFGHJKMNPQRS"))))

(ert-deftest seshat-covers-test-path-is-base-path ()
  "`seshat-covers-path' 返回不含扩展名的基路径；非法 uid 返回 nil。"
  (seshat-covers-test--with-env
   (should (equal (seshat-covers-path seshat-covers-test--uid)
                  (expand-file-name seshat-covers-test--uid
                                    seshat-covers-dir)))
   (should-not (string-match-p "\\.[A-Za-z]+\\'"
                               (seshat-covers-path seshat-covers-test--uid)))
   (should-not (seshat-covers-path "not-a-uid"))))

(ert-deftest seshat-covers-test-invalid-uid-creates-nothing ()
  "非法 uid 时 `seshat-covers-extract' 返回 nil 且不创建任何文件。"
  (seshat-covers-test--with-env
   (let ((calls nil))
     (cl-letf (((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output) (push cmd calls) (cons 0 "")))
               ((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip" "mutool")))
       (dolist (uid '("../etc/passwd" "0123456789ABCDEFGHJKMNPQRS/" nil 42
                      "0123456789abcdefghjkmnpqrs"))
         (should-not (seshat-covers-extract uid
                                            "/tmp/whatever.epub"))))
     (should-not (file-exists-p seshat-covers-dir))
     (should-not calls))))

;;; 缓存命中与负缓存

(ert-deftest seshat-covers-test-cached-hit-skips-everything ()
  "已命中缓存时 `cached' 返回该文件，`extract' 直接返回且不探测、不起子进程。"
  (seshat-covers-test--with-env
   (let ((target (seshat-covers-test--write
                  (seshat-covers-test--cache-file seshat-covers-test--uid "png")
                  seshat-covers-test--png))
         (probes 0)
         (runs 0))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (&rest _) (setq probes (1+ probes)) "/usr/bin/unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (&rest _) (setq runs (1+ runs)) (cons 0 ""))))
       (should (equal (seshat-covers-cached seshat-covers-test--uid) target))
       (should (equal (seshat-covers-extract seshat-covers-test--uid
                                             "/tmp/book.epub")
                      target))
       (should (= probes 0))
       (should (= runs 0))))))

(ert-deftest seshat-covers-test-negative-cache-blocks-retry ()
  "负缓存存在时 `extract' 返回 nil 且不起子进程、不探测工具。"
  (seshat-covers-test--with-env
   (seshat-covers-test--write
    (seshat-covers-test--cache-file seshat-covers-test--uid "none") "")
   (should (seshat-covers-failed-p seshat-covers-test--uid))
   (let ((probes 0) (runs 0))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (&rest _) (setq probes (1+ probes)) "/usr/bin/unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (&rest _) (setq runs (1+ runs)) (cons 0 ""))))
       (should-not (seshat-covers-extract seshat-covers-test--uid
                                          "/tmp/book.epub"))
       (should (= probes 0))
       (should (= runs 0))))))

(ert-deftest seshat-covers-test-cached-ignores-negative-file ()
  "`cached' 不把负缓存 `<uid>.none' 当作命中。"
  (seshat-covers-test--with-env
   (seshat-covers-test--write
    (seshat-covers-test--cache-file seshat-covers-test--uid "none") "")
   (should-not (seshat-covers-cached seshat-covers-test--uid))))

;;; 三级回退

(ert-deftest seshat-covers-test-pdf-fallback ()
  "L1 不可用（unzip 缺失 / 非 EPUB）时降级 L2：mutool 成功即返回 `<uid>.png'。"
  (seshat-covers-test--with-env
   (let* ((file (seshat-covers-test--write
                 (expand-file-name "book.pdf" seshat-covers-test--root)
                 (unibyte-string 37 80 68 70 45 49 46 52)))
          (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "mutool"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (push cmd commands)
                  (if (equal (car cmd) "mutool")
                      (progn
                        (seshat-covers-test--write
                         (seshat-covers-test--out-arg cmd) seshat-covers-test--png)
                        (cons 0 ""))
                    (cons 1 "")))))
       (should (equal (seshat-covers-extract seshat-covers-test--uid file)
                      (seshat-covers-test--cache-file seshat-covers-test--uid
                                                      "png")))
       ;; 只调用了 mutool：L1 没有白跑 unzip
       (should (equal (mapcar #'car commands) '("mutool")))
       ;; 成功路径不写负缓存
       (should-not (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-epub-without-unzip-falls-to-placeholder ()
  "EPUB 源文件在 `unzip' 缺失时不会走 L2（L2 只认 PDF），直接 L3 并写负缓存。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4)))
         (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "mutool"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output) (push cmd commands) (cons 0 ""))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file))
       (should-not commands)
       (should (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-both-tools-missing-writes-negative-cache ()
  "unzip / mutool 都缺失时返回 nil 并写负缓存（否则每次渲染都重试探针）。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4)))
         (runs 0))
     (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
               ((symbol-function 'seshat-covers--run)
                (lambda (&rest _) (setq runs (1+ runs)) (cons 0 ""))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file))
       (should (= runs 0))
       (should (file-exists-p
                (seshat-covers-test--cache-file seshat-covers-test--uid "none")))
       (should (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-both-tools-fail-writes-negative-cache ()
  "工具可用但命令全部非零退出：EPUB 与 PDF 两条路径都落到 L3 并写负缓存。"
  (seshat-covers-test--with-env
   (let ((epub (seshat-covers-test--write
                (expand-file-name "a.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4)))
         (pdf (seshat-covers-test--write
               (expand-file-name "b.pdf" seshat-covers-test--root)
               (unibyte-string 37 80 68 70)))
         (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip" "mutool"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output) (push cmd commands) (cons 1 ""))))
       ;; EPUB：unzip -Z1 失败 → 不是 PDF → L3
       (should-not (seshat-covers-extract seshat-covers-test--uid epub))
       (should (equal (mapcar #'car commands) '("unzip")))
       (should (seshat-covers-failed-p seshat-covers-test--uid))
       ;; PDF：mutool 失败 → L3
       (setq commands nil)
       (should-not (seshat-covers-extract seshat-covers-test--uid-2 pdf))
       (should (equal (mapcar #'car commands) '("mutool")))
       (should (seshat-covers-failed-p seshat-covers-test--uid-2))))))

(ert-deftest seshat-covers-test-epub-entry-heuristic ()
  "EPUB 选封面：扩展名 + `cover' 关键字，取层级最浅者；`unzip -p' 取该条目。"
  (seshat-covers-test--with-env
   (let* ((file (seshat-covers-test--write
                 (expand-file-name "book.epub" seshat-covers-test--root)
                 (unibyte-string 80 75 3 4)))
          (listing (concat "mimetype\nMETA-INF/container.xml\n"
                           "OEBPS/images/cover.png\n"
                           "OEBPS/cover.jpg\n"
                           "OEBPS/ch1.png\n"))
          (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (push cmd commands)
                  (cond
                   ((member "-Z1" cmd) (cons 0 listing))
                   ((member "-p" cmd) (cons 0 seshat-covers-test--jpg))
                   (t (cons 1 ""))))))
       (should (equal (seshat-covers-extract seshat-covers-test--uid file)
                      (seshat-covers-test--cache-file seshat-covers-test--uid
                                                      "jpg")))
       ;; `unzip -p -- <file> <entry>'：选中层级最浅的 cover.jpg，不是 images/ 下的
       (let ((unzip-p (cl-find-if (lambda (cmd) (member "-p" cmd)) commands)))
         (should (equal (car (last unzip-p)) "OEBPS/cover.jpg")))
       (should-not (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-pick-cover-entry-deterministic ()
  "`--pick-cover-entry' 的判据与确定性：层级最浅 → 字典序最小。"
  (should (equal (seshat-covers--pick-cover-entry
                  '("OEBPS/images/cover.png" "OEBPS/cover.jpg" "OEBPS/ch1.png"))
                 "OEBPS/cover.jpg"))
  ;; 同层级取字典序最小
  (should (equal (seshat-covers--pick-cover-entry
                  '("b/cover-a.png" "a/cover-b.png"))
                 "a/cover-b.png"))
  ;; 大小写不敏感匹配 `cover'
  (should (equal (seshat-covers--pick-cover-entry
                  '("OEBPS/COVER.JPG" "OEBPS/ch1.png"))
                 "OEBPS/COVER.JPG"))
  ;; 无 cover 关键字 / 扩展名不符 → nil
  (should-not (seshat-covers--pick-cover-entry '("OEBPS/ch1.png" "OEBPS/a.jpg")))
  (should-not (seshat-covers--pick-cover-entry '("OEBPS/cover.xml")))
  (should-not (seshat-covers--pick-cover-entry nil)))

(ert-deftest seshat-covers-test-source-too-big-skips ()
  "源图超过 `seshat-covers-max-bytes' 时不落盘，降级 L3 并写负缓存。"
  (seshat-covers-test--with-env
   (let ((seshat-covers-max-bytes 8)
         (file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4)))
         (listing "OEBPS/cover.jpg\n"))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (if (member "-Z1" cmd)
                      (cons 0 listing)
                    ;; 20 字节，超过上限 8
                    (cons 0 (make-string 20 65))))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file))
       (should-not (file-exists-p
                    (seshat-covers-test--cache-file seshat-covers-test--uid "jpg")))
       (should (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-timeout-degrades-without-error ()
  "`--run' 返回 nil（模拟超时）时 `extract' 不抛错，走降级并写负缓存。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4))))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip" "mutool"))
               ((symbol-function 'seshat-covers--run) (lambda (&rest _) nil)))
       (should-not (seshat-covers-extract seshat-covers-test--uid file))
       (should (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-unexpected-error-does-not-write-negative-cache ()
  "预期之外的异常（`--run' 直接抛错）不写负缓存：瞬时故障不该被固化成永久失败。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4))))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (&rest _) (error "boom"))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file))
       (should-not (seshat-covers-failed-p seshat-covers-test--uid))))))

(ert-deftest seshat-covers-test-sniff-ext ()
  "按字节头嗅探扩展名；未知格式返回 nil。"
  (should (equal (seshat-covers--sniff-ext seshat-covers-test--png) "png"))
  (should (equal (seshat-covers--sniff-ext seshat-covers-test--jpg) "jpg"))
  (should (equal (seshat-covers--sniff-ext seshat-covers-test--gif) "gif"))
  (should (equal (seshat-covers--sniff-ext seshat-covers-test--webp) "webp"))
  (should-not (seshat-covers--sniff-ext ""))
  (should-not (seshat-covers--sniff-ext "<html></html>"))
  (should-not (seshat-covers--sniff-ext nil))
  ;; 名字像图片但内容不是：仍按字节判（不靠后缀）
  (should-not (seshat-covers--sniff-ext "cover.png")))

;;; 串行限速队列

(ert-deftest seshat-covers-test-queue-dedup ()
  "同 uid 重复入队只保留一条；正在处理的 uid 再次入队被丢弃。"
  (seshat-covers-test--with-env
   (should (seshat-covers-queue seshat-covers-test--uid "/tmp/a.epub"))
   (should-not (seshat-covers-queue seshat-covers-test--uid "/tmp/a.epub"))
   (should (= (seshat-covers-queue-length) 1))
   (should (seshat-covers-queue seshat-covers-test--uid-2 "/tmp/b.pdf"))
   (should (= (seshat-covers-queue-length) 2))
   ;; 正在处理的 uid 不入队
   (setq seshat-covers--active-uid seshat-covers-test--uid-3)
   (should-not (seshat-covers-queue seshat-covers-test--uid-3 "/tmp/c.pdf"))
   (should (= (seshat-covers-queue-length) 2))
   ;; 非法 uid 不入队
   (should-not (seshat-covers-queue "bad/uid" "/tmp/d.epub"))
   (should (= (seshat-covers-queue-length) 2))))

(ert-deftest seshat-covers-test-queue-serial-one-per-pump ()
  "队列串行：每次 `--pump' 只处理 1 本，callback 依次收到结果。"
  (seshat-covers-test--with-env
   (let ((uids (list seshat-covers-test--uid
                     seshat-covers-test--uid-2
                     seshat-covers-test--uid-3))
         (seen nil)
         (calls 0))
     (dolist (uid uids)
       (seshat-covers-queue
        uid "/tmp/x.epub"
        (lambda (got result) (push (cons got result) seen))))
     (should (= (seshat-covers-queue-length) 3))
     (cl-letf (((symbol-function 'seshat-covers-extract)
                (lambda (uid _file)
                  (setq calls (1+ calls))
                  (concat "/cache/" uid ".png"))))
       (seshat-covers--pump)
       (should (= calls 1))
       (should (= (length seen) 1))
       (should (= (seshat-covers-queue-length) 2))
       (seshat-covers--pump)
       (should (= calls 2))
       (should (= (length seen) 2))
       (seshat-covers--pump)
       (should (= calls 3))
       (should (= (length seen) 3))
       (should (= (seshat-covers-queue-length) 0))
       ;; 队列空时再 pump 不做事
       (seshat-covers--pump)
       (should (= calls 3)))
     ;; 顺序为 FIFO（seen 是 push 出来的逆序）
     (should (equal (mapcar #'car (reverse seen)) uids))
     (should (equal (cdr (assq seshat-covers-test--uid (reverse seen)))
                    (concat "/cache/" seshat-covers-test--uid ".png"))))))

(ert-deftest seshat-covers-test-queue-callback-error-isolated ()
  "callback 抛错被吞掉，不影响后续条目继续处理。"
  (seshat-covers-test--with-env
   (let ((seen nil) (calls 0))
     (seshat-covers-queue seshat-covers-test--uid "/tmp/a.epub"
                          (lambda (&rest _) (error "回调炸了")))
     (seshat-covers-queue seshat-covers-test--uid-2 "/tmp/b.epub"
                          (lambda (uid result) (push (cons uid result) seen)))
     (cl-letf (((symbol-function 'seshat-covers-extract)
                (lambda (_uid _file) (setq calls (1+ calls)) "/cache/x.png")))
       (seshat-covers--pump)                 ; 第一条：callback 抛错
       (should (= calls 1))
       (should (= (seshat-covers-queue-length) 1))
       (seshat-covers--pump)                 ; 第二条仍被处理
       (should (= calls 2))
       (should (= (length seen) 1))
       (should (equal (car (car seen)) seshat-covers-test--uid-2))
       (should (= (seshat-covers-queue-length) 0))))))

(ert-deftest seshat-covers-test-queue-clear ()
  "`seshat-covers-queue-clear' 清空队列并取消定时器。"
  (seshat-covers-test--with-env
   (seshat-covers-queue seshat-covers-test--uid "/tmp/a.epub")
   (seshat-covers-queue seshat-covers-test--uid-2 "/tmp/b.epub")
   (should (= (seshat-covers-queue-length) 2))
   (should (timerp seshat-covers--timer))
   (seshat-covers-queue-clear)
   (should (= (seshat-covers-queue-length) 0))
   (should-not seshat-covers--timer)
   (should-not seshat-covers--queue)))

;;; 缓存清理与惰性

(ert-deftest seshat-covers-test-clear-cache-single-and-all ()
  "单条清理含负缓存；全部清理只删本模块的缓存文件，目录保留。"
  (seshat-covers-test--with-env
   (let ((img (seshat-covers-test--write
               (seshat-covers-test--cache-file seshat-covers-test--uid "png")
               seshat-covers-test--png))
         (neg (seshat-covers-test--write
               (seshat-covers-test--cache-file seshat-covers-test--uid "none") ""))
         (img2 (seshat-covers-test--write
                (seshat-covers-test--cache-file seshat-covers-test--uid-2 "jpg")
                seshat-covers-test--jpg))
         (foreign (seshat-covers-test--write
                   (expand-file-name "notes.txt" seshat-covers-dir) "x")))
     (should (= (seshat-covers-clear-cache seshat-covers-test--uid) 2))
     (should-not (file-exists-p img))
     (should-not (file-exists-p neg))
     (should (file-exists-p img2))
     (should (file-exists-p foreign))          ; 非本模块文件不删
     (should (= (seshat-covers-clear-cache) 1))
     (should-not (file-exists-p img2))
     (should (file-exists-p foreign))
     (should (file-directory-p seshat-covers-dir))
     ;; 非法 uid 不删任何东西
     (should (= (seshat-covers-clear-cache "bad/uid") 0))
     (should (file-exists-p foreign)))))

(ert-deftest seshat-covers-test-clear-cache-no-dir ()
  "缓存目录不存在时清理返回 0 且不建目录。"
  (seshat-covers-test--with-env
   (should (= (seshat-covers-clear-cache) 0))
   (should (= (seshat-covers-clear-cache seshat-covers-test--uid) 0))
   (should-not (file-exists-p seshat-covers-dir))))

(ert-deftest seshat-covers-test-lazy-dir-creation ()
  "只读 API 与「非法 uid」失败路径都不创建缓存目录；写负缓存时才创建。"
  (seshat-covers-test--with-env
   (should-not (file-exists-p seshat-covers-dir))
   (should (seshat-covers-path seshat-covers-test--uid))
   (should-not (seshat-covers-cached seshat-covers-test--uid))
   (should-not (seshat-covers-failed-p seshat-covers-test--uid))
   (should-not (file-exists-p seshat-covers-dir))
   (cl-letf (((symbol-function 'executable-find)
              (seshat-covers-test--executable-find-stub "unzip")))
     (should-not (seshat-covers-extract "../escape" "/tmp/a.epub")))
   (should-not (file-exists-p seshat-covers-dir))
   ;; 走到 L3（确定性失败）才建目录：负缓存必须落盘
   (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
     (should-not (seshat-covers-extract seshat-covers-test--uid "/tmp/a.epub")))
   (should (file-directory-p seshat-covers-dir))
   (should (file-exists-p
            (seshat-covers-test--cache-file seshat-covers-test--uid "none")))))

;;; 修复 1：子进程输出流式上限（防 EPUB 解压炸弹 OOM）
;;
;; 真实链路（造一个「条目声明 100 MB、压缩后极小」的 zip）需要真的 deflate 炸弹，
;; 不适合放进用例：`zip' 未必装、造炸弹本身也可能把测试机拖死。因此这里**桩
;; `make-process'** 驱动 `:filter' 模拟「filter 收到超大 chunk」，验证的是安全
;; 属性本身（越界即 `delete-process' + 返回标记 + 不落盘 + 写负缓存）。

(defmacro seshat-covers-test--with-stubbed-process (chunks &rest body)
  "在 `make-process' 等原语被桩替的环境里执行 BODY，桩把 CHUNKS 喂给 filter.
桩的语义：每次 `accept-process-output' 喂**一个** chunk，喂完最后一个即把进程
标成正常退出（否则 `--run' 的轮询循环会一路跑到超时分支）；`delete-process'
记下调用并把进程标成死掉。因此 `--run' 的轮询循环、越界判定与返回值都能被完整
驱动，且不需要真的起子进程。"
  (declare (indent 1) (debug t))
  `(let* ((chunks ,chunks)
          (filter nil)
          (deleted nil)
          (fed 0)
          (alive t))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest args)
                  (setq filter (plist-get args :filter))
                  'fake-proc))
               ((symbol-function 'process-live-p) (lambda (_proc) alive))
               ((symbol-function 'delete-process)
                (lambda (_proc) (setq deleted t alive nil)))
               ((symbol-function 'accept-process-output)
                (lambda (&rest _)
                  (when (and filter (< fed (length chunks)))
                    (funcall filter 'fake-proc (nth fed chunks))
                    (setq fed (1+ fed))
                    (when (>= fed (length chunks))
                      ;; 输出喂完 → 进程正常退出（退出码由下面的桩给出 0）
                      (setq alive nil)))))
               ((symbol-function 'process-exit-status) (lambda (_proc) 0)))
       ,@body)))

(ert-deftest seshat-covers-test-run-aborts-on-oversized-chunk ()
  "filter 累计超过 MAX-OUTPUT 时立即 `delete-process' 并返回 `(:too-large t)'.
这是防 OOM 的核心断言：不能等子进程跑完再判断，否则内存峰值已是解压后体积。"
  (seshat-covers-test--with-env
   (seshat-covers-test--with-stubbed-process (list (make-string 100 ?x))
     (let ((result (seshat-covers--run '("unzip" "-p" "f" "e") 10)))
       (should (equal result '(:too-large t)))
       (should deleted)
       ;; 只喂了一个 chunk 就中止：没有继续把后续输出读进 buffer
       (should (= fed 1))))))

(ert-deftest seshat-covers-test-run-aborts-across-chunks ()
  "单块未超限但**累计**超限时同样中止（判据是累计字节数，不是单块大小）。"
  (seshat-covers-test--with-env
   (seshat-covers-test--with-stubbed-process
       (list (make-string 8 ?a) (make-string 8 ?b) (make-string 8 ?c))
     (should (equal (seshat-covers--run '("unzip" "-p" "f" "e") 10)
                    '(:too-large t)))
     (should deleted))))

(ert-deftest seshat-covers-test-run-under-limit-streams-output ()
  "未超限时按原契约返回 `(0 . OUTPUT)'，且输出是各 chunk 的拼接（字节保真）。"
  (seshat-covers-test--with-env
   (seshat-covers-test--with-stubbed-process
       (list seshat-covers-test--png seshat-covers-test--jpg)
     (let ((result (seshat-covers--run '("unzip" "-p" "f" "e") 1024)))
       (should (integerp (car result)))
       (should (zerop (car result)))
       (should (equal (cdr result)
                      (concat seshat-covers-test--png seshat-covers-test--jpg)))
       (should-not deleted)))))

(ert-deftest seshat-covers-test-run-without-limit-never-aborts ()
  "MAX-OUTPUT 为 nil 时不设闸（用户显式配「不限」时照旧），输出完整返回。"
  (seshat-covers-test--with-env
   (seshat-covers-test--with-stubbed-process (list (make-string 64 ?x))
     (let ((result (seshat-covers--run '("unzip" "-p" "f" "e") nil)))
       (should (zerop (car result)))
       (should (= 64 (length (cdr result))))
       (should-not deleted)))))

(ert-deftest seshat-covers-test-epub-passes-limits-to-subprocess ()
  "`unzip -Z1' 与 `unzip -p' 都带输出上限：前者用清单上限，后者用源图上限。
（无上限的 `unzip -p' 就是 OOM 的入口，因此必须断言上限真的传下去了。）"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4)))
         (limits nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional max-output)
                  (push (cons (car (last cmd)) max-output) limits)
                  (if (member "-Z1" cmd)
                      (cons 0 "OEBPS/cover.png\n")
                    (cons 0 seshat-covers-test--png)))))
       (should (seshat-covers-extract seshat-covers-test--uid file)))
     (should (equal (cdr (assoc file (reverse limits)))
                    seshat-covers--listing-max-bytes))
     (should (equal (cdr (assoc "OEBPS/cover.png" (reverse limits)))
                    seshat-covers-max-bytes)))))

(ert-deftest seshat-covers-test-epub-cover-too-large-degrades-to-l3 ()
  "`unzip -p' 超限（`--run' 返回 `(:too-large t)'）→ 不落盘、写负缓存、不抛错。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4))))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip" "mutool"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (if (member "-Z1" cmd)
                      (cons 0 "OEBPS/cover.png\n")
                      (list :too-large t)))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file)))
     ;; 没有图片缓存
     (should-not (file-exists-p
                  (seshat-covers-test--cache-file seshat-covers-test--uid "png")))
     ;; 确定性失败 → 负缓存（下次不再起子进程）
     (should (seshat-covers-failed-p seshat-covers-test--uid)))))

(ert-deftest seshat-covers-test-epub-listing-too-large-degrades-to-l3 ()
  "`unzip -Z1' 超限（条目列表被构造成超长）→ 同样降级 L3 并写负缓存。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "book.epub" seshat-covers-test--root)
                (unibyte-string 80 75 3 4)))
         (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (push cmd commands)
                  (list :too-large t))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file)))
     ;; 只跑了列条目这一步就中止（没去取字节）
     (should (= 1 (length commands)))
     (should (member "-Z1" (car commands)))
     (should (seshat-covers-failed-p seshat-covers-test--uid)))))

(ert-deftest seshat-covers-test-pdf-output-file-too-big-skipped ()
  "`mutool' 的输出**文件**超过上限时在读入内存之前就跳过（判据是磁盘大小）。"
  (seshat-covers-test--with-env
   (let ((file (seshat-covers-test--write
                (expand-file-name "b.pdf" seshat-covers-test--root)
                (unibyte-string 37 80 68 70)))
         (seshat-covers-max-bytes 8))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "mutool"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  ;; 桩出「mutool 成功并写出 20 字节 PNG」：超上限 8
                  (seshat-covers-test--write
                   (seshat-covers-test--out-arg cmd)
                   (concat seshat-covers-test--png (make-string 12 ?x)))
                  (cons 0 ""))))
       (should-not (seshat-covers-extract seshat-covers-test--uid file)))
     (should-not (file-exists-p
                  (seshat-covers-test--cache-file seshat-covers-test--uid "png")))
     (should (seshat-covers-failed-p seshat-covers-test--uid))
     ;; 输出文件是临时文件，收尾必须删掉（不留垃圾）
     (should (equal (directory-files seshat-covers-test--root nil
                                     "\\`seshat-cover-")
                    nil)))))

;;; 修复 5：超时默认值与连续失败熔断

(ert-deftest seshat-covers-test-timeout-default-is-three ()
  "`seshat-covers-timeout' 默认 3 秒（不是 10）：封面是装饰，不值得一页卡 5 分钟。
（队列在 idle 定时器里同步跑，30 本 × 10 秒 = 5 分钟无响应。）"
  (should (= 3 (default-value 'seshat-covers-timeout)))
  ;; 判据常量：熔断阈值与冷却期也必须存在且有界
  (should (= 5 seshat-covers--failure-threshold))
  (should (= 60 seshat-covers--cooldown-seconds)))

(defun seshat-covers-test--queue-n (n)
  "把 N 条合法 uid 入队（uid 由 UID 前缀 + 两位序号拼成，全部合法）。
返回入队条数（应等于 N）。"
  (let ((count 0))
    (dotimes (i n)
      (let ((uid (concat (substring seshat-covers-test--uid 0 24)
                         (format "%02d" i))))
        (when (seshat-covers--uid-valid-p uid)
          (seshat-covers-queue uid "/tmp/x.epub")
          (setq count (1+ count)))))
    count))

(ert-deftest seshat-covers-test-breaker-opens-after-consecutive-failures ()
  "连续 5 次失败后熔断：第 6 次 `--pump' 不处理队首（队列长度不变），只 warn 一次。
（没有熔断时「`unzip' 没装」会让一页 30 本各白等一次超时。）"
  (seshat-covers-test--with-env
   (let ((warnings 0)
         (extract-calls 0)
         (orig-log (symbol-function 'seshat-log)))
     (should (= 6 (seshat-covers-test--queue-n 6)))
     (cl-letf (((symbol-function 'seshat-covers-extract)
                (lambda (_uid _file)
                  (setq extract-calls (1+ extract-calls))
                  nil))
               ((symbol-function 'seshat-log)
                (lambda (level &rest args)
                  (when (eq level 'warn) (setq warnings (1+ warnings)))
                  (apply orig-log level args))))
       (dotimes (_ seshat-covers--failure-threshold)
         (seshat-covers--pump))
       (should (= 5 extract-calls))
       (should (= 1 (seshat-covers-queue-length)))
       (should (floatp seshat-covers--cooldown-until))
       (should (= seshat-covers--failure-threshold
                  seshat-covers--consecutive-failures))
       (let ((warn-before warnings))
         ;; 冷却期内的 pump：不处理、不新增 warn
         (seshat-covers--pump)
         (should (= 5 extract-calls))
         (should (= 1 (seshat-covers-queue-length)))
         (should (= warn-before warnings)))))))

(ert-deftest seshat-covers-test-breaker-resumes-after-cooldown ()
  "冷却期过后恢复处理：计数清零、队首被正常消费。"
  (seshat-covers-test--with-env
   (let ((extract-calls 0))
     (should (= 2 (seshat-covers-test--queue-n 2)))
     (setq seshat-covers--consecutive-failures seshat-covers--failure-threshold
           ;; 冷却已在 1 秒前结束
           seshat-covers--cooldown-until (- (float-time) 1))
     (cl-letf (((symbol-function 'seshat-covers-extract)
                (lambda (_uid _file) (setq extract-calls (1+ extract-calls))
                  "/cache/x.png")))
       (seshat-covers--pump))
     (should (= 1 extract-calls))
     (should (= 1 (seshat-covers-queue-length)))
     ;; 冷却结束后计数已清零（重新给环境一次机会）
     (should (= 0 seshat-covers--consecutive-failures))
     (should-not seshat-covers--cooldown-until))))

(ert-deftest seshat-covers-test-breaker-success-resets-counter ()
  "成功一次即把连续失败计数清零（「连续」的语义）。"
  (seshat-covers-test--with-env
   (should (= 3 (seshat-covers-test--queue-n 3)))
   (let ((results (list nil nil "/cache/x.png")))
     (cl-letf (((symbol-function 'seshat-covers-extract)
                (lambda (_uid _file) (pop results))))
       (seshat-covers--pump)
       (should (= 1 seshat-covers--consecutive-failures))
       (seshat-covers--pump)
       (should (= 2 seshat-covers--consecutive-failures))
       (seshat-covers--pump)
       (should (= 0 seshat-covers--consecutive-failures))
       (should-not seshat-covers--cooldown-until)))))

(ert-deftest seshat-covers-test-queue-clear-resets-breaker ()
  "`seshat-covers-queue-clear' 同时复位熔断状态：主动重来不该继续受罚。"
  (seshat-covers-test--with-env
   (setq seshat-covers--consecutive-failures seshat-covers--failure-threshold
         seshat-covers--cooldown-until (+ (float-time) 60))
   (seshat-covers-queue-clear)
   (should (= 0 seshat-covers--consecutive-failures))
   (should-not seshat-covers--cooldown-until)))

;;; 子进程参数：`--' 分隔符（low 级加固）

;; 安全属性：`file' 恒为绝对路径（不会以 `-' 开头），但 **EPUB 条目名**来自压缩
;; 包内容，可以被构造成 `-x' 之类；没有 `--' 时「条目名只当数据」依赖 unzip /
;; mutool 的参数解析实现（本机 GNU unzip 恰好安全）。加 `--' 把它变成显式保证，
;; `--pick-cover-entry' 再拒一次 `-' 开头的条目名作为纵深防御。

(ert-deftest seshat-covers-test-unzip-commands-use-double-dash ()
  "`unzip -Z1' 与 `unzip -p' 的命令列表都含 `--'，且位于 file 之前。"
  (seshat-covers-test--with-env
   (let* ((file (seshat-covers-test--write
                 (expand-file-name "book.epub" seshat-covers-test--root)
                 (unibyte-string 80 75 3 4)))
          (listing "OEBPS/cover.jpg\n")
          (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "unzip"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (push cmd commands)
                  (if (member "-Z1" cmd)
                      (cons 0 listing)
                    (cons 0 seshat-covers-test--jpg)))))
       (should (seshat-covers-extract seshat-covers-test--uid file)))
     (let ((list-cmd (cl-find-if (lambda (cmd) (member "-Z1" cmd)) commands))
           (pipe-cmd (cl-find-if (lambda (cmd) (member "-p" cmd)) commands)))
       ;; 列条目：("unzip" "-Z1" "--" FILE)
       (should (equal (list "unzip" "-Z1" "--" file) list-cmd))
       ;; 取字节：("unzip" "-p" "--" FILE ENTRY)
       (should (equal (list "unzip" "-p" "--" file "OEBPS/cover.jpg") pipe-cmd))
       ;; 两条命令的 `--' 都在 file 之前（参数位置，不靠实现细节）
       (dolist (cmd (list list-cmd pipe-cmd))
         (should (member "--" cmd))
         (should (< (cl-position "--" cmd :test #'equal)
                    (cl-position file cmd :test #'equal))))))))

(ert-deftest seshat-covers-test-mutool-command-uses-double-dash ()
  "`mutool draw' 的命令列表含 `--'，且位于 file 之前、`-o' 输出路径之后。"
  (seshat-covers-test--with-env
   (let* ((file (seshat-covers-test--write
                 (expand-file-name "book.pdf" seshat-covers-test--root)
                 (unibyte-string 37 80 68 70)))
          (commands nil))
     (cl-letf (((symbol-function 'executable-find)
                (seshat-covers-test--executable-find-stub "mutool"))
               ((symbol-function 'seshat-covers--run)
                (lambda (cmd &optional _max-output)
                  (push cmd commands)
                  ;; `mutool' 写文件而不是 stdout：这里只需命令形状，模拟成功即可
                  (cons 0 ""))))
       (seshat-covers-extract seshat-covers-test--uid-2 file))
     (let ((cmd (car commands)))
       (should (equal "mutool" (car cmd)))
       (should (equal '("draw" "-r" "24") (cl-subseq cmd 1 4)))
       (should (member "--" cmd))
       (should (< (cl-position "--" cmd :test #'equal)
                  (cl-position file cmd :test #'equal)))
       ;; `--' 在 `-o TMP' 之后：输出路径仍按选项解析
       (should (< (cl-position "-o" cmd :test #'equal)
                  (cl-position "--" cmd :test #'equal)))
       ;; 最后两个参数是 `--' 之后的 file 与页号 1
       (should (equal (list file "1") (last cmd 2)))))))

(ert-deftest seshat-covers-test-pick-cover-entry-rejects-dash-prefixed ()
  "条目名以 `-' 开头时一律不选（纵深防御：它随后会成为 `unzip -p' 的参数）。"
  (should-not (seshat-covers--pick-cover-entry '("-cover.jpg")))
  (should-not (seshat-covers--pick-cover-entry
               '("-cover.jpg" "--cover.png" "-OEBPS/cover.jpg")))
  ;; 同批里有合法条目时选合法的那个，不被 `-' 条目干扰
  (should (equal (seshat-covers--pick-cover-entry
                  '("-cover.jpg" "OEBPS/cover.png"))
                 "OEBPS/cover.png"))
  ;; 非字符串元素被跳过而不是抛错（列表来自不可信压缩包内容）
  (should (equal (seshat-covers--pick-cover-entry
                  '(nil 42 "OEBPS/cover.png"))
                 "OEBPS/cover.png")))

(provide 'seshat-covers-test)

;;; seshat-covers-test.el ends here
