;;; seshat-reader-outline-test.el --- Tests for seshat-reader-outline  -*- lexical-binding: t; -*-

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

;; `seshat-reader-outline' 的 ERT 测试套件（M12 T4：目录面板接入 sidebar
;; 承载层 + 每次 show 重建内容；M12 T5：行模型纯函数 + 美化渲染；M12 T6：avy
;; 式跳转的标签生成 / 候选人收集纯函数 + 命令失败路径与键位）。
;;
;; 运行方式（在仓库根目录执行）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   "emacs" --batch -Q \
;;     -L "emacs" -L "emacs"/seshat-reader \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
;;     -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
;;     -l ert -l "emacs"/tests/seshat-reader-outline-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; 前置：`seshat-render-core.so' 已由包目录 `make all' 构建（`seshat-reader'
;; 模块加载需要它）。
;;
;; 纪律：**不触网、不碰真实 PDF、不依赖真实窗口**。阅读器 buffer 用
;; `get-buffer-create' 造，`major-mode' 直接置为 `seshat-reader-mode'（只借用
;; `derived-mode-p' 的判据，不跑 mode body——真 body 会因无文件名 kill buffer）；
;; 承载层入口 `seshat-reader-sidebar-show' 与跳页入口
;; `seshat-reader-goto-page' 一律用 `cl-letf' 桩替；目录数据自行构造
;; `seshat-reader-current-doc-outline' 的 plist 结构。
;;
;; 本套件全部用例都不需要外部包，故不使用 `skip-unless' / `ert-skip'——
;; skipped 必须恒为 0。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'seshat-reader)
(require 'seshat-reader-outline)

;;; 辅助函数与测试数据

(defconst seshat-reader-outline-test--outline-a
  '((:title "Chapter 1" :page 0
     :children ((:title "Section 1.1" :page 1)
                (:title "Section 1.2" :page 2)))
    (:title "Chapter 2" :page 5))
  "测试用目录 A：4 个条目（2 层）。")

(defconst seshat-reader-outline-test--outline-b
  '((:title "Preface" :page 0)
    (:title "Chapter A" :page 3
     :children ((:title "Section A.1" :page 4))))
  "测试用目录 B：3 个条目（2 层），与目录 A 无重叠标题。")

(defconst seshat-reader-outline-test--tree-3level
  '((:title "Part I" :page 0
     :children ((:title "Chapter 1" :page 1
                 :children ((:title "Section 1.1" :page 2)
                            (:title "Section 1.2" :page 4)))
                (:title "Chapter 2" :page 6)))
    (:title "Part II" :page 9))
  "测试用三层树：6 个节点，页号 0-based，DFS 前序页号单调递增.

DFS 前序页号（1-based）：Part I 1 / Chapter 1 2 / Section 1.1 3 /
Section 1.2 5 / Chapter 2 7 / Part II 10.")

(defun seshat-reader-outline-test--make-reader-buffer (name outline)
  "造一个伪装成 `seshat-reader-mode' 的 buffer NAME，目录变量置为 OUTLINE."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq major-mode 'seshat-reader-mode)
      (setq-local seshat-reader-current-doc-outline outline))
    buffer))

(defun seshat-reader-outline-test--buttons (buffer)
  "返回 BUFFER 中全部文本按钮的列表，元素为 (TEXT . PAGE)."
  (with-current-buffer buffer
    (let (result)
      (save-excursion
        (goto-char (point-min))
        (let ((button (next-button (point-min))))
          (while button
            (push (cons (button-label button)
                        (button-get button 'seshat-reader-page))
                  result)
            (setq button (next-button (button-end button))))))
      (nreverse result))))

(defun seshat-reader-outline-test--outline-buffer-name (doc-name)
  "返回文档 DOC-NAME 对应的目录 buffer 名."
  (format "*Outline of %s*" doc-name))

(defmacro seshat-reader-outline-test--with-stubs (&rest body)
  "在 `body' 内桩替承载层与跳页入口，并收集调用记录.

契约提示（T18 起 `show' 变成目录面板开关）：桩替
`seshat-reader-sidebar-show' 只记录调用，**不会**创建真实的 outline 面板
窗口，故这些用例里 `seshat-reader-outline-show' 恒走**打开**路径（重建内容
+ 显示），与改动前的行为一致；关闭路径由
`seshat-reader-outline-test--show-toggles-off-when-visible' 单独覆盖."
  (declare (indent 0))
  `(let (seshat-reader-outline-test--show-calls
         seshat-reader-outline-test--jumped-pages)
     (cl-letf (((symbol-function 'seshat-reader-sidebar-show)
                (lambda (buffer kind &optional select)
                  (push (list (if (bufferp buffer) (buffer-name buffer) buffer)
                              kind select)
                        seshat-reader-outline-test--show-calls)
                  'fake-panel-window))
               ((symbol-function 'seshat-reader-outline-select-doc-window)
                (lambda (&rest _) nil))
               ((symbol-function 'seshat-reader-goto-page)
                (lambda (page) (push page seshat-reader-outline-test--jumped-pages))))
       ,@body)))

(defmacro seshat-reader-outline-test--with-cleanup (buffers &rest body)
  "执行 BODY，结束后 kill BUFFERS 求值结果中的 buffer（buffer 对象或名字，可含 nil）."
  (declare (indent 1))
  `(unwind-protect
       (progn ,@body)
     (dolist (item ,buffers)
       (when item
         (let ((buffer (if (bufferp item) item (get-buffer item))))
           (when (buffer-live-p buffer)
             (kill-buffer buffer)))))))

;;; 1. 接入承载层：show 经 `seshat-reader-sidebar-show' 显示，kind 为 outline

(ert-deftest seshat-reader-outline-test--show-delegates-to-sidebar ()
  "`show' 必须经 `seshat-reader-sidebar-show' 显示目录，kind 参数为 `outline'."
  (let* ((doc "seshat-outline-test-doc-a.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a)))
    (seshat-reader-outline-test--with-cleanup
        (list reader (seshat-reader-outline-test--outline-buffer-name doc))
      (seshat-reader-outline-test--with-stubs
        (with-current-buffer reader
          (seshat-reader-outline-show))
        (should (= 1 (length seshat-reader-outline-test--show-calls)))
        (let ((call (car seshat-reader-outline-test--show-calls)))
          ;; ① 传给承载层的是目录 buffer（不是 buffer 名、也不是阅读器 buffer）
          (should (equal (nth 0 call)
                         (seshat-reader-outline-test--outline-buffer-name doc)))
          ;; ② kind 必须是 outline，否则会落到批注面板的方位/尺寸语义
          (should (eq (nth 1 call) 'outline))
          ;; ③ T5 起 SELECT 传 t（与 `seshat-reader-sidebar-toggle-outline' 的
          ;;    重开路径一致：按 `o' 打开目录后光标进入目录面板）
          (should (eq (nth 2 call) t)))))))

;;; 2. 切换文档后内容被重建（核心缺陷修复）

(ert-deftest seshat-reader-outline-test--show-rebuilds-after-document-change ()
  "同一 buffer 切换文档后再次 `show'，目录内容按新文档重建，归属信息同步更新."
  (let* ((doc "seshat-outline-test-doc-b.pdf")
         (renamed "seshat-outline-test-doc-b2.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (bufname (seshat-reader-outline-test--outline-buffer-name doc))
         (renamed-bufname (seshat-reader-outline-test--outline-buffer-name
                           renamed)))
    (seshat-reader-outline-test--with-cleanup
        (list reader bufname renamed-bufname)
      (seshat-reader-outline-test--with-stubs
        ;; ---- 第一次：目录 A ----
        (with-current-buffer reader
          (seshat-reader-outline-show))
        (should (equal (mapcar #'car (seshat-reader-outline-test--buttons bufname))
                       '("Chapter 1" "Section 1.1" "Section 1.2" "Chapter 2")))
        (with-current-buffer bufname
          (should (equal seshat-reader-outline--doc-buffername doc)))
        ;; ---- 同一 buffer 内换成文档 B 的目录，再次 show ----
        (with-current-buffer reader
          (setq-local seshat-reader-current-doc-outline
                      seshat-reader-outline-test--outline-b)
          (seshat-reader-outline-show))
        ;; 内容被重建（而非保留旧内容/在其后追加）：条目集合完全等于 B
        (should (equal (mapcar #'car (seshat-reader-outline-test--buttons bufname))
                       '("Preface" "Chapter A" "Section A.1")))
        (with-current-buffer bufname
          (should-not (string-match-p "Chapter 1" (buffer-string)))
          (should (equal seshat-reader-outline--doc-buffername doc)))
        ;; ---- 换文档名（等价于同一 buffer 换了文档）：归属信息随 show 更新 ----
        (with-current-buffer reader
          (rename-buffer renamed t)
          (seshat-reader-outline-show))
        (with-current-buffer renamed-bufname
          (should (equal seshat-reader-outline--doc-buffername renamed))
          (should (equal (length (seshat-reader-outline-test--buttons
                                  renamed-bufname))
                         3)))))))

;;; 3. 同一文档重复 show 幂等（不重复追加）

(ert-deftest seshat-reader-outline-test--show-idempotent-for-same-document ()
  "同一文档连续 `show' 两次：条目与内容不变（重建而非追加），归属信息保持一致.

契约变更说明（T18：`o' 改为目录面板开关）：真实环境下第二次 `show' 会**关闭**
面板，因此本用例只在「无面板窗口 → 打开路径」下成立——batch 里承载层被桩替、
不产生 outline 面板窗口，两次调用都走打开路径，断言的是**打开路径的重建幂等**
（不重复追加）。关闭路径见
`seshat-reader-outline-test--show-toggles-off-when-visible'."
  (let* ((doc "seshat-outline-test-doc-c.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (bufname (seshat-reader-outline-test--outline-buffer-name doc)))
    (seshat-reader-outline-test--with-cleanup (list reader bufname)
      (seshat-reader-outline-test--with-stubs
        (with-current-buffer reader
          (seshat-reader-outline-show))
        (let ((first (seshat-reader-outline-test--buttons bufname)))
          (with-current-buffer reader
            (seshat-reader-outline-show))
          (let ((second (seshat-reader-outline-test--buttons bufname)))
            ;; 内容逐字相同：条目标题与页号都不变
            (should (equal first second))
            (should (= 4 (length second)))
            ;; 没有重复追加（4 个条目 × 1 次）
            (should (= 1 (cl-count "Chapter 1" second
                                   :key #'car :test #'equal)))
            (with-current-buffer bufname
              (should (equal seshat-reader-outline--doc-buffername doc))
              ;; point 被放到 buffer 开头
              (should (= (point) (point-min)))
              ;; 仍是只读的既有目录 buffer（未 kill 重建）
              (should buffer-read-only)
              (should (eq major-mode 'seshat-reader-outline-mode)))))))))

;;; 4. 文档无 outline：抛 user-error 且不清空既有内容

(ert-deftest seshat-reader-outline-test--show-no-outline-keeps-content ()
  "文档无目录时抛 `user-error'，且**先校验后重建**——既有目录内容不被清空."
  (let* ((doc "seshat-outline-test-doc-d.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (bufname (seshat-reader-outline-test--outline-buffer-name doc)))
    (seshat-reader-outline-test--with-cleanup (list reader bufname)
      (seshat-reader-outline-test--with-stubs
        ;; 先正常渲染一次，制造「面板里已有内容」的状态
        (with-current-buffer reader
          (seshat-reader-outline-show))
        (let ((before (seshat-reader-outline-test--buttons bufname)))
          (should (= 4 (length before)))
          ;; 清掉目录变量后再次 show：必须报错
          (with-current-buffer reader
            (setq-local seshat-reader-current-doc-outline nil)
            (should-error (seshat-reader-outline-show) :type 'user-error))
          ;; 内容原封不动（既没清空，也没被重建为空）
          (should (equal before (seshat-reader-outline-test--buttons bufname)))
          (with-current-buffer bufname
            (should (> (buffer-size) 0)))
          ;; 报错路径不应调用承载层
          (should (= 1 (length seshat-reader-outline-test--show-calls))))))))

;;; 5. 跳页闭环：归属信息刷新后仍能跳回正确页

(ert-deftest seshat-reader-outline-test--goto-entry-refreshes-doc-window ()
  "`show' 后 `--doc-buffername' 指向当前文档，`goto-entry' 按按钮页号跳页."
  (let* ((doc "seshat-outline-test-doc-e.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (bufname (seshat-reader-outline-test--outline-buffer-name doc)))
    (seshat-reader-outline-test--with-cleanup (list reader bufname)
      (seshat-reader-outline-test--with-stubs
        (with-current-buffer reader
          (seshat-reader-outline-show))
        (with-current-buffer bufname
          (should (equal seshat-reader-outline--doc-buffername doc))
          ;; `--doc-window' 在 batch 下无窗口 → nil，但变量必须被 show 刷新过
          (should (boundp 'seshat-reader-outline--doc-window))
          (let ((button (next-button (point-min))))
            (should button)
            (seshat-reader-outline-goto-entry button)))
        ;; "Chapter 1" 的 :page 为 0（MuPDF 0-based）→ 跳转用 1
        (should (equal seshat-reader-outline-test--jumped-pages '(1)))
        ;; 跳到第二个条目（"Section 1.1" :page 1 → 2）
        (with-current-buffer bufname
          (let ((button (next-button (point-min)))
                (second nil))
            (setq second (next-button (button-end button)))
            (should second)
            (seshat-reader-outline-goto-entry second)))
        (should (equal seshat-reader-outline-test--jumped-pages '(2 1)))))))

;;; 5b. `show' 是目录面板开关（T18：已显示则关闭，未显示则重建并显示）

(ert-deftest seshat-reader-outline-test--show-toggles-off-when-visible ()
  "已显示目录面板时 `show' 走关闭路径：窗口被删、内容不重建、不调用承载层."
  (let* ((doc "seshat-outline-test-doc-toggle-off.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (bufname (seshat-reader-outline-test--outline-buffer-name doc))
         (win (selected-window))
         (orig-buffer (window-buffer win))
         ;; 全局状态一律动态绑定：关闭路径会写尺寸记忆与「上次 buffer」记忆
         (seshat-reader-sidebar--state nil)
         (seshat-reader-sidebar--last-buffers nil)
         (seshat-reader-sidebar--last-buffer nil)
         (seshat-reader-sidebar--last-kind nil)
         (deleted nil)
         (erases 0)
         (shown nil))
    (unwind-protect
        (progn
          ;; 预置面板窗口：带 `seshat-reader-sidebar' 参数 + kind 为 outline，
          ;; 正是 `seshat-reader-sidebar--panel-for-kind'（承载单元 = 面板窗口 +
          ;; child frame）只看窗口一侧时的判据（沿用
          ;; `seshat-reader-sidebar-test--toggle-closes-package-windows' 的
          ;; 「直接给 `selected-window' 设参数」做法，batch 下无真实 GUI 侧窗）。
          (set-window-parameter win 'seshat-reader-sidebar t)
          (set-window-parameter win 'seshat-reader-sidebar-kind 'outline)
          ;; 预置面板内容（渲染层直插，不经 `show'，避免依赖真实窗口显示）
          (with-current-buffer (get-buffer-create bufname)
            (seshat-reader-outline-mode)
            (let ((inhibit-read-only t))
              (seshat-reader--outline-insert-outline
               (seshat-reader-outline--rows
                seshat-reader-outline-test--outline-a nil nil))
              (goto-char (point-min))))
          ;; 面板窗口必须真的显示该面板 buffer：关闭路径用 `window-buffer' 记
          ;; 「上次 buffer」，窗口显示别的 buffer 会记错（真实环境恒一致）
          (set-window-buffer win (get-buffer bufname))
          (let ((before (seshat-reader-outline-test--buttons bufname)))
            (should (= 4 (length before)))
            (cl-letf (((symbol-function 'erase-buffer)
                       (lambda (&rest _) (cl-incf erases)))
                      ((symbol-function 'delete-window)
                       (lambda (w &optional _) (push w deleted)))
                      ((symbol-function 'seshat-reader-sidebar-show)
                       (lambda (&rest args) (push args shown) 'fake-panel-window))
                      ((symbol-function 'message) (lambda (&rest _) nil)))
              (with-current-buffer reader
                (seshat-reader-outline-show)))
            ;; ① 窗口被删（经 `seshat-reader-sidebar--toggle-kind' 的
            ;;    `delete-window'，不是本命令自己删）
            (should (= 1 (length deleted)))
            (should (eq (car deleted) win))
            ;; ② 内容**没有**被重建：`erase-buffer' 未被调用，条目逐字不变
            (should (zerop erases))
            (should (equal before (seshat-reader-outline-test--buttons bufname)))
            ;; ③ 关闭路径不调用承载层的显示入口
            (should-not shown)
            ;; ④ 关闭时把面板 buffer 记入「上次 buffer」记忆，供下次重开恢复
            (should (eq (cdr (assq 'outline seshat-reader-sidebar--last-buffers))
                        (get-buffer bufname)))))
      (set-window-parameter win 'seshat-reader-sidebar nil)
      (set-window-parameter win 'seshat-reader-sidebar-kind nil)
      (set-window-buffer win orig-buffer)
      (let ((panel (get-buffer bufname)))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest seshat-reader-outline-test--show-rebuilds-and-displays-when-hidden ()
  "无目录面板窗口时 `show' 重建内容（覆盖旧条目）并经承载层显示，kind 为 outline."
  (let* ((doc "seshat-outline-test-doc-toggle-on.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-b))
         (bufname (seshat-reader-outline-test--outline-buffer-name doc))
         (erases 0))
    (seshat-reader-outline-test--with-cleanup (list reader bufname)
      ;; 预置：面板 buffer 里是**旧**内容，且不存在 outline 面板窗口
      (with-current-buffer (get-buffer-create bufname)
        (seshat-reader-outline-mode)
        (let ((inhibit-read-only t))
          (insert "* stale entry\n")))
      (should-not (seshat-reader-sidebar--panel-for-kind 'outline))
      (seshat-reader-outline-test--with-stubs
        (cl-letf (((symbol-function 'erase-buffer)
                   (lambda (&rest _)
                     (cl-incf erases)
                     (delete-region (point-min) (point-max)))))
          (with-current-buffer reader
            (seshat-reader-outline-show)))
        ;; ① 承载层被调用：目录 buffer 名 + kind `outline' + SELECT 非 nil
        (should (= 1 (length seshat-reader-outline-test--show-calls)))
        (let ((call (car seshat-reader-outline-test--show-calls)))
          (should (equal (nth 0 call) bufname))
          (should (eq (nth 1 call) 'outline))
          (should (eq (nth 2 call) t))))
      ;; ② 内容被重建（`erase-buffer' 被调用一次，旧条目不在，行数 > 0）
      (should (= 1 erases))
      (with-current-buffer bufname
        (should-not (string-match-p "stale entry" (buffer-string)))
        (should (> (line-number-at-pos (point-max)) 1)))
      (should (equal (mapcar #'car (seshat-reader-outline-test--buttons bufname))
                     '("Preface" "Chapter A" "Section A.1"))))))

;;; 5c. 目录面板内按 `o' 一次即关（T18b：不再先切回阅读窗口再按第二次）

(ert-deftest seshat-reader-outline-test--show-in-outline-buffer-closes-panel ()
  "光标在目录面板里时 `show' 直接关闭：只调 per-kind toggle，不重建、不报错."
  (let ((panel (get-buffer-create "*seshat-outline-test-panel-body*"))
        (toggles nil)
        (shows nil)
        (erases 0)
        (err nil))
    (unwind-protect
        (progn
          (with-current-buffer panel
            (seshat-reader-outline-mode)
            (let ((inhibit-read-only t))
              (insert "* Chapter 1  1\n"))
            (goto-char (point-min))
            ;; 面板 buffer 不是 `seshat-reader-mode'——正是旧实现的报错点
            (should-not (derived-mode-p 'seshat-reader-mode))
            (should (derived-mode-p 'seshat-reader-outline-mode))
            ;; 面板里也没有目录数据：关闭路径不该需要它
            (should-not (bound-and-true-p seshat-reader-current-doc-outline)))
          (cl-letf (((symbol-function 'seshat-reader-sidebar--toggle-kind)
                     (lambda (kind) (push kind toggles)))
                    ((symbol-function 'seshat-reader-sidebar-show)
                     (lambda (&rest args) (push args shows) 'fake-panel-window))
                    ((symbol-function 'erase-buffer)
                     (lambda (&rest _) (cl-incf erases))))
            (with-current-buffer panel
              (setq err (condition-case e
                            (progn (seshat-reader-outline-show) nil)
                          (error e)))))
          ;; ① 不报错（未加面板分支时会因「不在 `seshat-reader-mode'」抛
          ;;    `user-error'，用户也就得先按一次切回阅读窗口）
          (should-not err)
          ;; ② 关闭只经 per-kind toggle，参数为 `outline'，且只调一次（一次即关）
          (should (equal toggles '(outline)))
          ;; ③ 没走重建 / 显示路径：`erase-buffer' 零调用，承载层未被调用
          (should (zerop erases))
          (should-not shows))
      (when (buffer-live-p panel) (kill-buffer panel)))))

(ert-deftest seshat-reader-outline-test--o-is-bound-to-toggle-in-mode-map ()
  "`o' / `s' 绑定在 `seshat-reader-outline-mode-map'，键位不再依赖 evil.
2026-10-26 起 `o' 由 `seshat-reader-outline-show' 改绑
`seshat-reader-outline-toggle'：面板已显示则关闭、否则构建并显示，与批注列表 /
译文 / 解释的键语义统一。

同日起不再给 evil 的 normal state 补绑（`seshat-reader-outline--install-evil-bindings'
已删除），改为在 mode body 里关闭面板 buffer 的 evil——键位只由本 mode 的键表
决定，evil 的 state keymap 不再参与解析。"
  ;; ① 原生 keymap（`seshat-reader-outline-mode-map'）
  (should (eq (keymap-lookup seshat-reader-outline-mode-map "o")
              #'seshat-reader-outline-toggle))
  (should (eq (keymap-lookup seshat-reader-outline-mode-map "s")
              #'seshat-reader-outline-select-doc-window))
  ;; ② 旧的 evil 补绑入口已删除（语义改为「关闭 evil」）
  (should-not (fboundp 'seshat-reader-outline--install-evil-bindings))
  ;; ③ 取代补绑的路径是「mode body 关闭 evil」：桩替 helper 记录调用次数，再真正
  ;;    进入 mode body。本套件 skipped 必须恒为 0，故用桩替而不是 `skip-unless'。
  (let ((calls 0)
        (buffer (get-buffer-create " *Seshat outline evil-off*")))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'seshat-reader--disable-evil)
                     (lambda () (cl-incf calls))))
            (seshat-reader-outline-mode))
          (should (= 1 calls)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest seshat-reader-outline-test--toggle-closes-when-visible ()
  "`outline-toggle' 在面板已显示时只走 per-kind 关闭，不重建内容.
判据经 `seshat-reader-sidebar-panel-visible-p'（承载无关：childframe 下也能
判出「已显示」），关闭只经 `seshat-reader-sidebar--toggle-kind'，`show' 的重建
路径（`erase-buffer' / 承载层显示）一次都不该被触发。"
  (let* ((doc "seshat-outline-test-doc-toggle-visible.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (toggles nil)
         (erases 0)
         (shows nil))
    (seshat-reader-outline-test--with-cleanup (list reader)
      (cl-letf (((symbol-function 'seshat-reader-sidebar-panel-visible-p)
                 (lambda (kind) (eq kind 'outline)))
                ((symbol-function 'seshat-reader-sidebar--toggle-kind)
                 (lambda (kind) (push kind toggles)))
                ((symbol-function 'seshat-reader-sidebar-show)
                 (lambda (&rest args) (push args shows) 'fake-panel-window))
                ((symbol-function 'erase-buffer)
                 (lambda (&rest _) (cl-incf erases))))
        (with-current-buffer reader
          (seshat-reader-outline-toggle)))
      ;; ① 关闭走 per-kind toggle，且只调一次（一次即关）
      (should (equal toggles '(outline)))
      ;; ② 没有重建、没有重新显示
      (should (zerop erases))
      (should-not shows))))

(ert-deftest seshat-reader-outline-test--toggle-rebuilds-when-hidden ()
  "`outline-toggle' 在面板未显示时委托 `seshat-reader-outline-show'（重建 + 显示）."
  (let* ((doc "seshat-outline-test-doc-toggle-hidden.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (toggles nil)
         (shown nil))
    (seshat-reader-outline-test--with-cleanup (list reader)
      (cl-letf (((symbol-function 'seshat-reader-sidebar-panel-visible-p)
                 (lambda (_kind) nil))
                ((symbol-function 'seshat-reader-sidebar--toggle-kind)
                 (lambda (kind) (push kind toggles)))
                ((symbol-function 'seshat-reader-sidebar-show)
                 (lambda (buffer kind &optional select)
                   (setq shown (list buffer kind select))
                   'fake-panel-window)))
        (with-current-buffer reader
          (seshat-reader-outline-toggle)))
      ;; ① 未显示 → 不关闭
      (should-not toggles)
      ;; ② 委托 show：重建后按 outline kind 显示
      (should (eq (cadr shown) 'outline))
      (should (string-match-p "\\`\\*Outline of .*\\*\\'" (buffer-name (car shown)))))))

;;; 6. 行模型（纯函数）：DFS 前序 / depth / page 1-based

(ert-deftest seshat-reader-outline-test--rows-basic-shape ()
  "`--rows' 的基本形状：DFS 前序、depth 从 0 起、page 输出为 1-based."
  (let ((rows (seshat-reader-outline--rows
               seshat-reader-outline-test--tree-3level nil nil)))
    (should (= 6 (length rows)))
    ;; DFS 前序：父 → 子 → 兄弟，与树的书写顺序一致
    (should (equal (mapcar (lambda (row) (plist-get row :title)) rows)
                   '("Part I" "Chapter 1" "Section 1.1" "Section 1.2"
                     "Chapter 2" "Part II")))
    ;; 根深度为 0，逐层 +1
    (should (equal (mapcar (lambda (row) (plist-get row :depth)) rows)
                   '(0 1 2 2 1 0)))
    ;; 页码 1-based（原树 0-based，+1）
    (should (equal (mapcar (lambda (row) (plist-get row :page)) rows)
                   '(1 2 3 5 7 10)))
    ;; has-children 只有带 :children 的节点为 t（Chapter 2 / Part II / 两个 Section 为 nil）
    (should (equal (mapcar (lambda (row) (plist-get row :has-children)) rows)
                   '(t t nil nil nil nil)))
    ;; 无折叠、无当前页 → collapsed-p / current-p 全 nil
    (should (equal (mapcar (lambda (row) (plist-get row :collapsed-p)) rows)
                   '(nil nil nil nil nil nil)))
    (should (equal (mapcar (lambda (row) (plist-get row :current-p)) rows)
                   '(nil nil nil nil nil nil))))
  ;; 空树 → 空行列表（不报错）
  (should-not (seshat-reader-outline--rows nil nil 1)))

;;; 7. 行模型：折叠节点的子树不出现，且节点自身 collapsed-p 为 t

(ert-deftest seshat-reader-outline-test--rows-collapsed-subtree ()
  "折叠中间节点后其子树不出现在结果里，该行 `:collapsed-p' 为 t."
  (let ((rows (seshat-reader-outline--rows
               seshat-reader-outline-test--tree-3level
               '(("Part I" "Chapter 1")) nil)))
    (should (equal (mapcar (lambda (row) (plist-get row :title)) rows)
                   '("Part I" "Chapter 1" "Chapter 2" "Part II")))
    (should (equal (mapcar (lambda (row) (plist-get row :depth)) rows)
                   '(0 1 1 0)))
    (should (equal (mapcar (lambda (row) (plist-get row :collapsed-p)) rows)
                   '(nil t nil nil))))
  ;; 折叠根节点：整棵子树都不出现，根自身仍在
  (let ((rows (seshat-reader-outline--rows
               seshat-reader-outline-test--tree-3level
               '(("Part I")) nil)))
    (should (equal (mapcar (lambda (row) (plist-get row :title)) rows)
                   '("Part I" "Part II")))
    (should (eq t (plist-get (car rows) :collapsed-p)))
    (should (eq t (plist-get (car rows) :has-children))))
  ;; 路径不匹配（只给标题字符串 / 路径打错）→ 不折叠，行数仍为 6
  (should (= 6 (length (seshat-reader-outline--rows
                        seshat-reader-outline-test--tree-3level
                        '("Chapter 1" "Part I") nil)))))

;;; 8. 行模型：当前章标记只有最深包含节点为 t

(ert-deftest seshat-reader-outline-test--rows-current-section ()
  "只有「包含当前页的最深节点」` :current-p' 为 t；折叠子树内命中则无标记."
  (let* ((rows (seshat-reader-outline--rows
                seshat-reader-outline-test--tree-3level nil 4))
         (marked (seq-filter (lambda (row) (plist-get row :current-p)) rows)))
    ;; 第 4 页落在 Section 1.1（3）与 Section 1.2（5）之间 → 最深者为 1.1
    (should (= 1 (length marked)))
    (should (equal (plist-get (car marked) :title) "Section 1.1"))
    (should (= 2 (plist-get (car marked) :depth))))
  ;; 第 2 页只被「Part I 与 Chapter 1」覆盖 → 取更深者 Chapter 1
  (let ((marked (seq-filter
                 (lambda (row) (plist-get row :current-p))
                 (seshat-reader-outline--rows
                  seshat-reader-outline-test--tree-3level nil 2))))
    (should (equal (mapcar (lambda (row) (plist-get row :title)) marked)
                   '("Chapter 1"))))
  ;; 父节点与首个子节点同页时取更深者（前序里页号并列，后者胜）
  (let* ((tree '((:title "Parent" :page 0
                  :children ((:title "Child" :page 0)))))
         (marked (seq-filter
                  (lambda (row) (plist-get row :current-p))
                  (seshat-reader-outline--rows tree nil 1))))
    (should (equal (mapcar (lambda (row) (plist-get row :title)) marked)
                   '("Child"))))
  ;; 命中节点位于折叠子树内 → 结果里没有任何行被标记
  (should-not (seq-find
               (lambda (row) (plist-get row :current-p))
               (seshat-reader-outline--rows
                seshat-reader-outline-test--tree-3level
                '(("Part I" "Chapter 1")) 3)))
  ;; current-page 为 nil（未知）→ 不标记
  (should-not (seq-find
               (lambda (row) (plist-get row :current-p))
               (seshat-reader-outline--rows
                seshat-reader-outline-test--tree-3level nil nil))))

;;; 9. `--current-path'：最深包含节点的路径 / 超出范围返回 nil

(ert-deftest seshat-reader-outline-test--current-path ()
  "`--current-path' 返回最深包含节点的路径（标题列表），越界或未知时 nil."
  (let ((tree seshat-reader-outline-test--tree-3level))
    (should (equal (seshat-reader-outline--current-path tree 1) '("Part I")))
    (should (equal (seshat-reader-outline--current-path tree 3)
                   '("Part I" "Chapter 1" "Section 1.1")))
    (should (equal (seshat-reader-outline--current-path tree 8)
                   '("Part I" "Chapter 2")))
    ;; 末节点的范围延到文档末尾：超出最大页号仍命中最后一个节点
    (should (equal (seshat-reader-outline--current-path tree 99)
                   '("Part II")))
    ;; 小于所有页号 / 页号未知 / 空树 → nil
    (should-not (seshat-reader-outline--current-path tree 0))
    (should-not (seshat-reader-outline--current-path tree nil))
    (should-not (seshat-reader-outline--current-path nil 1))))

;;; 10. 渲染层：星号前缀（TAB 折叠前提）+ 折叠符号 + 页码对齐 + 当前章竖线

(ert-deftest seshat-reader-outline-test--render-rows ()
  "渲染 ROWS：每行仍匹配 `outline-regexp'、缩进层级正确、页码 face 与对齐、
当前章有行首竖线且标题用 current-face."
  (with-temp-buffer
    ;; 目录面板的 `outline-regexp' 是 TAB 折叠的前提，这里复刻 mode body 的设置
    (setq-local outline-regexp "^\\*+ ")
    (let ((inhibit-read-only t))
      (seshat-reader--outline-insert-outline
       (seshat-reader-outline--rows
        seshat-reader-outline-test--tree-3level nil 3)))
    ;; ① 每行都以 "^*+ " 开头（星号必须在行首），星号数 = depth+1
    (goto-char (point-min))
    (let (star-counts)
      (while (not (eobp))
        (should (looking-at "^\\*+ "))
        (push (length (match-string 0)) star-counts)
        (forward-line 1))
      (should (equal (nreverse star-counts) '(2 3 4 4 3 2))))
    ;; ② 折叠符号：有子节点显示 ▾（默认全部展开）
    (goto-char (point-min))
    (should (search-forward "▾" nil t))
    ;; ③ 页码右对齐：某处存在 align-to 的 display 属性
    (goto-char (point-min))
    (let (aligned)
      (while (not (eobp))
        (when (equal (get-text-property (point) 'display)
                     seshat-reader-outline--page-align)
          (setq aligned t))
        (forward-char 1))
      (should aligned))
    ;; ④ 当前章（第 3 页 → Section 1.1）行首有竖线，标题用 current-face
    (goto-char (point-min))
    (should (search-forward "Section 1.1" nil t))
    (should (equal (get-text-property (line-beginning-position) 'line-prefix)
                   seshat-reader-outline--current-bar))
    (should (eq (get-text-property (match-beginning 0) 'face)
                'seshat-reader-outline-current-face))
    ;; ⑤ 非当前行行首是同宽空格（保证缩进不错位），标题按层级取 face
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'line-prefix) " "))
    (should (search-forward "Part II" nil t))
    (should (eq (get-text-property (match-beginning 0) 'face)
                'seshat-reader-outline-level-1-face))
    ;; ⑥ 标题仍是可点击按钮（保留 `seshat-reader-page' 属性）
    (should (equal (mapcar #'cdr (seshat-reader-outline-test--buttons
                                  (current-buffer)))
                   '(1 2 3 5 7 10)))))

;;; 11. avy 标签生成（纯函数）

(ert-deftest seshat-reader-outline-test--avy-labels ()
  "`--avy-labels'：0 → nil；≤ keys 长度 → 单字符；更多 → 双字符且无前缀冲突."
  (should-not (seshat-reader-outline--avy-labels 0))
  (should-not (seshat-reader-outline--avy-labels -1))
  (let ((keys '(?a ?s ?d ?f ?g ?h ?j ?k ?l)))
    ;; 1 个候选 → 1 个字符
    (should (equal (seshat-reader-outline--avy-labels 1 keys) '("a")))
    ;; 5 个候选（< 9）→ 全单字符、唯一
    (let ((labels (seshat-reader-outline--avy-labels 5 keys)))
      (should (equal labels '("a" "s" "d" "f" "g")))
      (should (cl-every (lambda (label) (= 1 (length label))) labels))
      (should (= 5 (length (delete-dups (copy-sequence labels))))))
    ;; 正好等长于 keys（9）→ 仍单字符
    (should (cl-every (lambda (label) (= 1 (length label)))
                      (seshat-reader-outline--avy-labels 9 keys)))
    ;; 30 个候选（> 9）→ 全双字符、无重复、且不存在「某标签是另一标签前缀」
    (let ((labels (seshat-reader-outline--avy-labels 30 keys)))
      (should (= 30 (length labels)))
      (should (cl-every (lambda (label) (= 2 (length label))) labels))
      (should (= 30 (length (delete-dups (copy-sequence labels)))))
      (should-not (cl-some (lambda (one)
                             (cl-some (lambda (other)
                                        (and (not (equal one other))
                                             (string-prefix-p one other)))
                                      labels))
                           labels))
      ;; 组合规则：先 key1 再 key2（第 0 个 "aa"、第 1 个 "as"、第 9 个 "sa"）
      (should (equal (nth 0 labels) "aa"))
      (should (equal (nth 1 labels) "as"))
      (should (equal (nth 9 labels) "sa")))
    ;; 超过 len^2 → user-error（不生成 3 字符标签）
    (should-error (seshat-reader-outline--avy-labels 82 keys) :type 'user-error))
  ;; 省略 keys → 读 `seshat-reader-outline--avy-keys'（batch 下 avy 未加载 → 默认表）
  (should (= 3 (length (seshat-reader-outline--avy-labels 3))))
  (should (equal (seshat-reader-outline--avy-labels 2
                                                   seshat-reader-outline--avy-default-keys)
                 '("a" "s"))))

;;; 12. 候选人收集（纯函数）

(ert-deftest seshat-reader-outline-test--avy-candidates ()
  "`--avy-candidates' 收集区间内带 `seshat-reader-page' 的按钮，按位置升序."
  (with-temp-buffer
    (let (starts)
      (dolist (spec '(("Chapter 1" . 1) ("Section 1.1" . 3) ("Section 1.2" . 7)))
        (push (point) starts)
        (insert-text-button (car spec) 'seshat-reader-page (cdr spec))
        (insert "\n"))
      (setq starts (nreverse starts))
      ;; 全区间 → 3 个候选，位置与页号都对
      (let ((all (seshat-reader-outline--avy-candidates (point-min) (point-max))))
        (should (= 3 (length all)))
        (should (equal (mapcar #'car all) starts))
        (should (equal (mapcar #'cdr all) '(1 3 7)))
        ;; 第一个候选的位置就是第一个按钮的起始位置（overlay 插入点）
        (should (= (car (car all)) (nth 0 starts))))
      ;; 区间只覆盖前两行 → 只返回 2 个
      (let ((two (seshat-reader-outline--avy-candidates (point-min)
                                                        (nth 2 starts))))
        (should (= 2 (length two)))
        (should (equal (mapcar #'cdr two) '(1 3))))
      ;; 空区间 → nil
      (should-not (seshat-reader-outline--avy-candidates (point-min) (point-min)))
      (should-not (seshat-reader-outline--avy-candidates (point-max) (point-max)))))
  ;; 无 `seshat-reader-page' 属性的按钮被跳过
  (with-temp-buffer
    (insert-text-button "plain" 'action #'ignore)
    (insert " ")
    (insert-text-button "entry" 'seshat-reader-page 5)
    (let ((candidates (seshat-reader-outline--avy-candidates (point-min)
                                                             (point-max))))
      (should (= 1 (length candidates)))
      (should (equal (cdr (car candidates)) 5)))))

;;; 13. 命令的失败路径 + 键位

(ert-deftest seshat-reader-outline-test--avy-jump-errors ()
  "非 outline-mode buffer 与「可见区间无候选」两条失败路径都抛 `user-error'."
  ;; ① 非 `seshat-reader-outline-mode' buffer
  (with-temp-buffer
    (should-not (derived-mode-p 'seshat-reader-outline-mode))
    (should-error (seshat-reader-outline-avy-jump) :type 'user-error))
  ;; ② outline-mode buffer 但可见区间内无候选（`--avy-candidates' 桩返回 nil；
  ;;    batch 下没有真实窗口，`window-start' / `window-end' 一并桩替）
  (with-temp-buffer
    (insert "no buttons here\n")
    (seshat-reader-outline-mode)
    (cl-letf (((symbol-function 'window-start)
               (lambda (&optional _window) (point-min)))
              ((symbol-function 'window-end)
               (lambda (&optional _window _update) (point-max)))
              ((symbol-function 'seshat-reader-outline--avy-candidates)
               (lambda (_start _end) nil)))
      (should-error (seshat-reader-outline-avy-jump) :type 'user-error))))

(ert-deftest seshat-reader-outline-test--avy-jump-key-binding ()
  "`f' 绑定到 `seshat-reader-outline-avy-jump'，且不覆盖既有键位."
  (should (eq (lookup-key seshat-reader-outline-mode-map "f")
              #'seshat-reader-outline-avy-jump))
  (should (eq (lookup-key seshat-reader-outline-mode-map "p") #'previous-line))
  (should (eq (lookup-key seshat-reader-outline-mode-map "n") #'next-line))
  ;; 2026-10-26：`o' 由 `seshat-reader-outline-show' 改绑 per-kind toggle
  ;; （面板已显示则关、否则构建并显示；三 kind 键语义统一）
  (should (eq (lookup-key seshat-reader-outline-mode-map "o")
              #'seshat-reader-outline-toggle))
  (should (eq (lookup-key seshat-reader-outline-mode-map "q")
              #'seshat-reader-sidebar-quit))
  (should (eq (lookup-key seshat-reader-outline-mode-map (kbd "RET"))
              #'seshat-reader-outline-visit-page))
  (should (eq (lookup-key seshat-reader-outline-mode-map (kbd "M-RET"))
              #'seshat-reader-outline-visit-page)))

(defmacro seshat-reader-outline-test--with-rendered (rows &rest body)
  "在临时 buffer 中渲染 ROWS，然后执行 BODY（point 在 buffer 开头）.

复刻目录面板的最小环境：`outline-regexp' 按 `seshat-reader-outline-mode' 的
设置给出（不跑 mode body，避免 `buffer-read-only' 干扰插入）。"
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local outline-regexp "^\\*+ ")
     (let ((inhibit-read-only t))
       (seshat-reader--outline-insert-outline ,rows))
     (goto-char (point-min))
     ,@body))

(defun seshat-reader-outline-test--line-depths ()
  "返回当前渲染 buffer 中每行的 `(LINE-START . DEPTH)'（按行首星号数 - 1 推算）."
  (save-excursion
    (goto-char (point-min))
    (let (result)
      (while (not (eobp))
        (unless (looking-at "^\\(\\*+\\) ")
          (error "Line does not match `outline-regexp': %S"
                 (buffer-substring-no-properties (line-beginning-position)
                                                 (line-end-position))))
        (push (cons (line-beginning-position) (1- (length (match-string 1))))
              result)
        (forward-line 1))
      (nreverse result))))

(defun seshat-reader-outline-test--hidden-p (pos)
  "POS 处是否被 outline 折叠隐藏.

Emacs 31 的 `outline-hide-subtree' 用 **overlay**（`invisible' = `outline'）
实现隐藏，旧版用同名 text property；`invisible-p' 两者都认，故用它，并额外
兼容 text property 形态。"
  (or (invisible-p pos) (get-text-property pos 'invisible)))

;;; 14. 渲染层：行首星号零宽（保留 outline 结构，但不占显示列）

(ert-deftest seshat-reader-outline-test--render-stars-zero-width ()
  "星号区间带 `display \"\"'：星号文本仍在、行仍是标题、星号之后不留零宽."
  (let ((rows (seshat-reader-outline--rows
               seshat-reader-outline-test--tree-3level nil nil)))
    (seshat-reader-outline-test--with-rendered rows
      (let ((line-depths (seshat-reader-outline-test--line-depths)))
        (should (= 6 (length line-depths)))
        (dolist (entry line-depths)
          (let* ((line-start (car entry))
                 (depth (cdr entry))
                 (stars (1+ depth)))
            ;; ① 星号文本**仍在 buffer 里**（零宽是显示属性，不是删除文本）
            (should (string-prefix-p
                     "*" (buffer-substring-no-properties line-start
                                                        (1+ line-start))))
            (should (equal (buffer-substring-no-properties
                            line-start (+ line-start stars))
                           (make-string stars ?*)))
            ;; ② (1+depth) 个星号逐个零宽
            (dotimes (i stars)
              (should (equal (get-text-property (+ line-start i) 'display) "")))
            ;; ③ 星号之后那一列**不是**零宽（星号后的固定空格保留）
            (should-not (equal (get-text-property (+ line-start stars) 'display)
                               ""))
            ;; ④ `outline-regexp' / `outline-on-heading-p' 仍认这是标题行
            (save-excursion
              (goto-char line-start)
              (should (looking-at "^\\*+ "))
              (should (outline-on-heading-p)))))))))

;;; 15. 渲染层：缩进规则（星号后 1 个固定空格 + `--indent-width' × depth）

(ert-deftest seshat-reader-outline-test--render-indent-width ()
  "缩进：`--indent-width' 默认 1，行前缀 = 星号 + 1 空格 + depth × 1 空格."
  (should (= 1 seshat-reader-outline--indent-width))
  (let ((rows (seshat-reader-outline--rows
               seshat-reader-outline-test--tree-3level nil nil)))
    (seshat-reader-outline-test--with-rendered rows
      (let ((line-depths (seshat-reader-outline-test--line-depths)))
        ;; 三层都覆盖到（depth 0/1/2）
        (should (equal (mapcar #'cdr line-depths) '(0 1 2 2 1 0)))
        (dolist (entry line-depths)
          (let* ((line-start (car entry))
                 (depth (cdr entry))
                 (indent (* seshat-reader-outline--indent-width depth))
                 (prefix-len (+ (1+ depth) 1 indent))
                 (prefix (buffer-substring-no-properties
                          line-start (+ line-start prefix-len))))
            ;; 星号之后的空格数 = 1（固定左边距）+ indent-width × depth
            (should (equal prefix
                           (concat (make-string (1+ depth) ?*)
                                   " "
                                   (make-string indent ?\s))))
            (should (= (+ 1 indent) (- (length prefix) (1+ depth))))
            ;; 缩进区之后紧跟折叠符号（有子节点）或 2 空格占位（叶子）
            (should (memq (char-after (+ line-start prefix-len))
                          '(?▾ ?▸ ?\s)))))))))

;;; 16. 折叠：星号零宽后 TAB 折叠仍可用

(ert-deftest seshat-reader-outline-test--fold-still-works ()
  "星号零宽后 `outline-hide-subtree' / `outline-show-subtree' 仍生效（`invisible'）."
  (with-temp-buffer
    (seshat-reader-outline-mode)
    (let ((inhibit-read-only t))
      (seshat-reader--outline-insert-outline
       (seshat-reader-outline--rows
        seshat-reader-outline-test--tree-3level nil nil))
      (goto-char (point-min)))
    ;; 面板模式的两条不变量未被本批改动
    (should buffer-read-only)
    (should (equal outline-regexp "^\\*+ "))
    (should (outline-on-heading-p))
    (let ((chapter-1 (save-excursion
                       (goto-char (point-min))
                       (search-forward "Chapter 1")
                       (match-beginning 0))))
      ;; 折叠 "Part I" 的子树 → 子树（含 Chapter 1 行）变不可见
      (should-not (seshat-reader-outline-test--hidden-p chapter-1))
      (outline-hide-subtree)
      (should (seshat-reader-outline-test--hidden-p chapter-1))
      ;; 零宽属性不被折叠影响
      (should (equal (get-text-property (point-min) 'display) ""))
      (outline-show-subtree)
      (should-not (seshat-reader-outline-test--hidden-p chapter-1)))
    ;; 折叠/展开只改显示属性，buffer 文本（含星号与标题）不变
    (should (save-excursion (goto-char (point-min)) (looking-at "^\\* ")))
    (should (save-excursion
              (goto-char (point-min))
              (search-forward "Part I" nil t)))))

;;; 17. evil 软依赖：面板内关闭 evil（不再补绑）

(ert-deftest seshat-reader-outline-test--evil-soft-dependency ()
  "evil 的接入从「补绑」改为「关闭」：旧入口消失，面板键全部来自 mode-map."
  ;; ① 旧补绑入口整体删除（语义改为 mode body 里关 evil）
  (should-not (fboundp 'seshat-reader-outline--install-evil-bindings))
  ;; ② 关闭 helper 由阅读器提供（本模块 `require' 了它，故必然可用）
  (should (fboundp 'seshat-reader--disable-evil))
  ;; ③ 面板 8 个键（含 `f'）全部绑在本 mode 的键表上：evil 关闭后不会被
  ;;    `evil-find-char' / `evil-ret' 一类命令抢走，故无需任何补绑
  (should (eq (lookup-key seshat-reader-outline-mode-map "f")
              #'seshat-reader-outline-avy-jump))
  (should (eq (lookup-key seshat-reader-outline-mode-map "p")
              #'previous-line))
  (should (eq (lookup-key seshat-reader-outline-mode-map "n")
              #'next-line))
  (should (eq (lookup-key seshat-reader-outline-mode-map "o")
              #'seshat-reader-outline-toggle))
  (should (eq (lookup-key seshat-reader-outline-mode-map "s")
              #'seshat-reader-outline-select-doc-window))
  (should (eq (lookup-key seshat-reader-outline-mode-map "q")
              #'seshat-reader-sidebar-quit))
  (should (eq (lookup-key seshat-reader-outline-mode-map (kbd "RET"))
              #'seshat-reader-outline-visit-page))
  (should (eq (lookup-key seshat-reader-outline-mode-map (kbd "M-RET"))
              #'seshat-reader-outline-visit-page)))

;;; 7. 阅读器 buffer 被 kill 时的目录面板清理（T3b）

(ert-deftest seshat-reader-outline-test--kill-buffer-cleanup-ignores-non-reader ()
  "非 `seshat-reader-mode' buffer 上零动作：不查面板 buffer、不关窗口."
  (let ((buf (get-buffer-create "*seshat-outline-test-plain*"))
        (queried nil)
        (closed nil))
    (unwind-protect
        (with-current-buffer buf
          (setq major-mode 'fundamental-mode)
          (cl-letf (((symbol-function 'get-buffer)
                     (lambda (name) (push name queried) nil))
                    ((symbol-function 'seshat-reader-sidebar-close-buffer-kind)
                     (lambda (kind buffer) (push (list kind buffer) closed))))
            (seshat-reader-outline--kill-buffer-cleanup)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    ;; 连 `get-buffer' 都不该调用：早期返回必须发生在查面板之前
    (should-not queried)
    (should-not closed)))

(ert-deftest seshat-reader-outline-test--kill-buffer-cleanup-closes-and-empties-panel ()
  "阅读器 buffer 被 kill 时：关闭 outline 面板窗口、清空内容、归属信息置 nil."
  (let* ((doc "seshat-outline-test-kill.pdf")
         (panel (get-buffer-create
                 (seshat-reader-outline-test--outline-buffer-name doc)))
         (reader (get-buffer-create doc))
         (closed nil))
    (unwind-protect
        (progn
          (with-current-buffer panel
            (insert "stale outline entry\n")
            (setq seshat-reader-outline--doc-buffername doc))
          (with-current-buffer reader
            (setq major-mode 'seshat-reader-mode))
          ;; 钩子必须是**全局**注册（不是 buffer-local），否则只有加载本库之后
          ;; 才打开的阅读器 buffer 才受保护
          (should (memq #'seshat-reader-outline--kill-buffer-cleanup
                        kill-buffer-hook))
          (cl-letf (((symbol-function 'seshat-reader-sidebar-close-buffer-kind)
                     (lambda (kind buffer) (push (list kind buffer) closed))))
            (with-current-buffer reader
              (seshat-reader-outline--kill-buffer-cleanup)))
          ;; ① 以 kind `outline' + 该文档的面板 buffer 调用承载层的关闭原语
          (should (equal closed (list (list 'outline panel))))
          ;; ② 面板内容被清空（不 kill 面板 buffer，下次 show 可重建）
          (with-current-buffer panel
            (should (zerop (buffer-size)))
            (should-not seshat-reader-outline--doc-buffername)))
      (dolist (buf (list panel reader))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; 5d. childframe 承载（M12 T6）：已显示判断经承载单元抽象 / 跨 frame 回窗口

(ert-deftest seshat-reader-outline-test--outline-show-detects-childframe-panel ()
  "childframe 承载下 `show' 仍判「已显示」并走关闭分支.

桩替 `seshat-reader-sidebar--panel-for-kind' 返回一个 fake frame（窗口承载时
该函数返回窗口，childframe 承载时返回 frame），并断言
`seshat-reader-sidebar--window-for-kind' **不再被调用**：它只看窗口，
childframe 下恒为 nil，已显示会被误判成未显示而重复建面板."
  (let* ((doc "seshat-outline-test-doc-cf-panel.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (fake-frame (list 'fake-child-frame))
         (toggles nil)
         (panel-queries nil)
         (window-queries 0)
         (shows nil))
    (seshat-reader-outline-test--with-cleanup (list reader)
      (cl-letf (((symbol-function 'seshat-reader-sidebar--panel-for-kind)
                 (lambda (kind &optional _panels)
                   (push kind panel-queries)
                   (and (eq kind 'outline) fake-frame)))
                ((symbol-function 'seshat-reader-sidebar--window-for-kind)
                 (lambda (&rest _) (cl-incf window-queries) nil))
                ((symbol-function 'seshat-reader-sidebar--toggle-kind)
                 (lambda (kind) (push kind toggles)))
                ((symbol-function 'seshat-reader-sidebar-show)
                 (lambda (&rest args) (push args shows) 'fake-panel-window)))
        (with-current-buffer reader
          (seshat-reader-outline-show)))
      ;; ① 已显示 → 关闭分支（per-kind toggle，kind 为 outline，只调一次）
      (should (equal toggles '(outline)))
      ;; ② 判据经 `--panel-for-kind'，参数为 outline
      (should (equal panel-queries '(outline)))
      ;; ③ 不再调用只看窗口的 `--window-for-kind'
      (should (zerop window-queries))
      ;; ④ 不重复建面板：承载层显示入口未被调用
      (should-not shows))))

(ert-deftest seshat-reader-outline-test--outline-select-doc-window-cross-frame ()
  "阅读窗口在父 frame、选中 frame 是子 frame 时先 `select-frame' 再 `select-window'."
  (let* ((doc "seshat-outline-test-doc-cross-frame.pdf")
         (reader (seshat-reader-outline-test--make-reader-buffer
                  doc seshat-reader-outline-test--outline-a))
         (win (selected-window))
         (orig-buffer (window-buffer win))
         (calls nil))
    (unwind-protect
        (progn
          (set-window-buffer win reader)
          (with-current-buffer reader
            (setq seshat-reader-outline--doc-buffername doc)
            (setq seshat-reader-outline--doc-window win)
            ;; 第一段：`win' 属于父 frame，当前选中 frame 是子 frame（childframe
            ;; 承载时光标在子 frame 里）——必须先切 frame 再选窗口。
            (cl-letf (((symbol-function 'window-frame)
                       (lambda (&rest _) 'parent-frame))
                      ((symbol-function 'selected-frame)
                       (lambda (&rest _) 'child-frame))
                      ((symbol-function 'select-frame)
                       (lambda (frame &optional _norecord)
                         (push (list 'frame frame) calls)))
                      ((symbol-function 'select-window)
                       (lambda (window &optional _norecord)
                         (push (list 'window window) calls))))
              (seshat-reader-outline-select-doc-window))
            ;; `calls' 是 push 出来的逆序：reverse 后第一项即最早的调用
            (should (equal (reverse calls)
                           (list (list 'frame 'parent-frame)
                                 (list 'window win))))
            ;; 第二段：`win' 与选中 frame 相同时不得多切一次 frame
            (setq calls nil)
            (cl-letf (((symbol-function 'window-frame)
                       (lambda (&rest _) 'same-frame))
                      ((symbol-function 'selected-frame)
                       (lambda (&rest _) 'same-frame))
                      ((symbol-function 'select-frame)
                       (lambda (frame &optional _norecord)
                         (push (list 'frame frame) calls)))
                      ((symbol-function 'select-window)
                       (lambda (window &optional _norecord)
                         (push (list 'window window) calls))))
              (seshat-reader-outline-select-doc-window))
            (should (equal (reverse calls) (list (list 'window win))))))
      (set-window-buffer win orig-buffer)
      (when (buffer-live-p reader) (kill-buffer reader)))))

(ert-deftest seshat-reader-outline-test--outline-goto-entry-forces-redisplay ()
  "`goto-entry' 调 `(redisplay t)'——强制重绘所有 frame，不只当前 frame."
  (let ((buf (get-buffer-create "*seshat-outline-test-goto-redisplay*"))
        (redisplay-args nil)
        (pages nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert-text-button "Chapter 1" 'seshat-reader-page 3)
            ;; `next-button' 的 COUNT-CURRENT 必须传 t：按钮正好从 `point-min'
            ;; 起，默认行为是跳过 POS 处的按钮。
            (let ((button (next-button (point-min) t)))
              (should button)
              (cl-letf (((symbol-function
                          'seshat-reader-outline-select-doc-window)
                         (lambda (&rest _) nil))
                        ((symbol-function 'redisplay)
                         (lambda (&optional force &rest _)
                           (push force redisplay-args)
                           t))
                        ((symbol-function 'seshat-reader-goto-page)
                         (lambda (page) (push page pages))))
                (seshat-reader-outline-goto-entry button))))
          ;; ① 重绘参数为 t（强制全 frame 重绘），且只调一次
          (should (equal redisplay-args '(t)))
          ;; ② 跳页仍按按钮的 1-based 页号
          (should (equal pages '(3))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'seshat-reader-outline-test)
;;; seshat-reader-outline-test.el ends here
