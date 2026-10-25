;;; seshat-reader-search-test.el --- ERT tests for the reader text search  -*- lexical-binding: t; -*-

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

;; `seshat-reader-search'（跨页文本搜索）的 ERT 测试套件。
;;
;; 全部用例**不依赖动态模块、不依赖真实文档**：
;;
;;   - `seshat-reader-dyn--search-page' 被桩替成一个 `(PAGE . RECTS)' alist，
;;     并把每次调用的 `(PAGE NEEDLE LIMIT)' 记入 `--dyn-calls'，用于断言
;;     「1-based 页号原样传给 C」这条对齐关系（C 侧 `--search-page' 与
;;     `--add-decoration' 同约定，都是 1-based）；
;;   - `seshat-reader-current-doc-pagenumber' / `seshat-reader-goto-page' 被
;;     桩替（真实实现分别读窗口参数、调用 C 模块，batch 下都不可用）；
;;   - 三个装饰入口 `--clear-highlights' / `--add-decoration' /
;;     `--refresh-highlights' 被桩替并记录投喂顺序，从而与「是否真的画出来」
;;     解耦。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
;; 批注模块用于验证「命中与批注装饰共存」这条路径（扩展点
;; `seshat-reader-annotation-extra-decorations-function'）。搜索模块本身**不**
;; 硬依赖它：`--works-without-annotation' 用例把委托目标变成未绑定函数来
;; 覆盖降级路径。
(require 'seshat-reader-annotation)
(require 'seshat-reader-search)
;; 结果侧栏的展示与关闭都走 sidebar 模块（kind → 位置/slot、per-kind 独立窗口），
;; 故测试要能直接断言该模块的位置解析与 slot 分配。
(require 'seshat-reader-sidebar)

(defvar seshat-reader-search-test--pages nil
  "桩替的搜索结果表：`(PAGE . RECTS)' 的 alist，PAGE 为 1-based.")

(defvar seshat-reader-search-test--events nil
  "本用例内记录的事件（投喂顺序 / 跳页），最新的在表头.")

(defvar seshat-reader-search-test--dyn-calls nil
  "本用例内 `seshat-reader-dyn--search-page' 的调用记录（最新的在表头）.")

(defvar seshat-reader-search-test--current-page 1
  "桩替的「当前页」（1-based）。")

(defvar seshat-reader-search-test--total-pages 3
  "桩替的文档总页数。")

(defvar seshat-reader-search-test--messages nil
  "本用例内经 `message' 桩捕获的消息（最新的在表头）。")

(defmacro seshat-reader-search-test--with-stubs (&rest body)
  "在桩替了 C 入口与跳页函数的环境中求值 BODY.
桩替的变量（`--pages' 等）在块内 `let' 绑定为默认值，BODY 内可直接 `setq'。
`message' 也被桩替：batch 下没有回显区，`current-message' 恒为 nil，故把
格式化后的消息记进 `--messages' 供断言。"
  (declare (indent 0) (debug t))
  `(let ((seshat-reader-search-test--pages nil)
         (seshat-reader-search-test--events nil)
         (seshat-reader-search-test--dyn-calls nil)
         (seshat-reader-search-test--current-page 1)
         (seshat-reader-search-test--total-pages 3)
         (seshat-reader-search-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (if args
                            (apply #'format format-string args)
                          format-string)
                        seshat-reader-search-test--messages)
                  format-string))
               ((symbol-function 'seshat-reader-dyn--search-page)
                (lambda (page needle limit)
                  (push (list page needle limit) seshat-reader-search-test--dyn-calls)
                  (copy-sequence
                   (cdr (assq page seshat-reader-search-test--pages)))))
               ((symbol-function 'seshat-reader-search--page-count)
                (lambda () seshat-reader-search-test--total-pages))
               ((symbol-function 'seshat-reader-current-doc-pagenumber)
                (lambda (&optional _window) seshat-reader-search-test--current-page))
               ((symbol-function 'seshat-reader-goto-page)
                (lambda (n)
                  (push (list 'goto n) seshat-reader-search-test--events)
                  (setq seshat-reader-search-test--current-page n)))
               ((symbol-function 'seshat-reader-dyn--clear-highlights)
                (lambda ()
                  (push 'clear seshat-reader-search-test--events)
                  t))
               ((symbol-function 'seshat-reader-dyn--add-decoration)
                (lambda (page x0 y0 x1 y1 r g b alpha)
                  (push (list 'deco page x0 y0 x1 y1 r g b alpha)
                        seshat-reader-search-test--events)
                  t))
               ((symbol-function 'seshat-reader-dyn--refresh-highlights)
                (lambda ()
                  (push 'refresh seshat-reader-search-test--events)
                  t))
               ;; 侧栏：显示入口桩替掉（batch 下不真的建 side window），只记录
               ;; 调用参数，用于断言「SELECT 传 t（光标切到侧栏）」。
               ((symbol-function 'seshat-reader-sidebar-show)
                (lambda (buffer kind &optional select)
                  (push (list 'sidebar-show kind select
                              (if (bufferp buffer) (buffer-name buffer) buffer))
                        seshat-reader-search-test--events)
                  nil))
               ;; 侧栏片段取文用的两个 rect 入口：模块真实存在时假页号会走到 C
               ;; 侧并 `message' 报「页号越界」，污染 `--messages' 里最后一条；
               ;; 桩成 nil 既切断了模块依赖，也让片段退化为「只有页号」。
               ((symbol-function 'seshat-reader-dyn--lines-in-rect)
                (lambda (&rest _args) nil))
               ((symbol-function 'seshat-reader-dyn--text-in-rect)
                (lambda (&rest _args) nil)))
       ,@body)))

(defun seshat-reader-search-test--rects (n)
  "造 N 条互不相同的矩形（X0 递增，便于断言顺序）."
  (let (rects)
    (dotimes (i n)
      (push (list (* 10.0 i) 20.0 (+ (* 10.0 i) 5.0) 30.0) rects))
    (nreverse rects)))

(defun seshat-reader-search-test--decos ()
  "取出记录中的装饰投喂事件（正序）."
  (seq-filter (lambda (event) (eq (car-safe event) 'deco))
              (reverse seshat-reader-search-test--events)))

(defun seshat-reader-search-test--last-message ()
  "返回本用例最近一条被 `message' 桩捕获的消息（可能为 nil）."
  (car seshat-reader-search-test--messages))

(defun seshat-reader-search-test--event-names ()
  "把事件记录归一成符号列表（正序）.
`sidebar-show' 事件**不计入**：它们记录的是侧栏面板的显示调用（独立的并存
视图），混进来会让「装饰投喂顺序」这套断言多出一个与绘制无关的元素。"
  (mapcar (lambda (event) (if (consp event) (car event) event))
          (seq-filter (lambda (event)
                        (not (eq (car-safe event) 'sidebar-show)))
                      (reverse seshat-reader-search-test--events))))

(defun seshat-reader-search-test--goto-pages ()
  "取出跳页事件的目标页号（正序）."
  (mapcar #'cadr
          (seq-filter (lambda (event) (eq (car-safe event) 'goto))
                      (reverse seshat-reader-search-test--events))))

;;; 纯函数：页号对齐、上限与状态串

(ert-deftest seshat-reader-search-test--c-page-is-one-based ()
  "1-based 页号原样传给 C（C 侧 `--search-page' 也是 1-based，与装饰入口一致）."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "the")
      (setq seshat-reader-search-test--pages '((1 . ((1.0 2.0 3.0 4.0)))))
      (should (equal (seshat-reader-search--rects-for-page 1)
                     '((1.0 2.0 3.0 4.0))))
      ;; C 收到的是 1，而不是 0
      (should (equal (nth 0 (car seshat-reader-search-test--dyn-calls)) 1))
      (should (equal (nth 1 (car seshat-reader-search-test--dyn-calls)) "the"))
      (should (= (nth 2 (car seshat-reader-search-test--dyn-calls))
                 seshat-reader-search--hard-cap)))))

(ert-deftest seshat-reader-search-test--page-results-cached ()
  "同一页只向 C 请求一次（按页缓存在 `--page-results' 里）."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "x")
      (setq seshat-reader-search-test--pages '((2 . ((1.0 2.0 3.0 4.0)))))
      (seshat-reader-search--rects-for-page 2)
      (seshat-reader-search--rects-for-page 2)
      (should (= 1 (length seshat-reader-search-test--dyn-calls)))
      ;; 空结果同样缓存（无文本层页不会被反复请求）
      (seshat-reader-search--rects-for-page 3)
      (seshat-reader-search--rects-for-page 3)
      (should (= 2 (length seshat-reader-search-test--dyn-calls))))))

(ert-deftest seshat-reader-search-test--truncation-threshold ()
  "条数达到 min(limit, 1024) 即判定为「本页已达上限」."
  (should (seshat-reader-search--truncated-p seshat-reader-search--hard-cap))
  (should-not (seshat-reader-search--truncated-p
               (1- seshat-reader-search--hard-cap)))
  ;; limit 小于硬上限时，上限变成 limit
  (let ((seshat-reader-search-limit 10))
    (should (= 10 (seshat-reader-search--cap)))
    (should (seshat-reader-search--truncated-p 10))
    (should-not (seshat-reader-search--truncated-p 9)))
  ;; limit 大于硬上限时，上限仍是 1024
  (let ((seshat-reader-search-limit 5000))
    (should (= seshat-reader-search--hard-cap (seshat-reader-search--cap)))
    ;; 传给 C 的 limit 仍是用户值（C 侧自行夹到 1024）
    (should (= 5000 (seshat-reader-search--page-limit)))))

(ert-deftest seshat-reader-search-test--status-string ()
  "状态串形如「第 i/N 个命中 · 第 p 页」，i 与 p 都是 1-based."
  (should (equal (seshat-reader-search--status-string 1 3 1)
                 "第 1/3 个命中 · 第 1 页"))
  (should (equal (seshat-reader-search--status-string 12 40 7)
                 "第 12/40 个命中 · 第 7 页")))

;;; 搜索主流程

(ert-deftest seshat-reader-search-test--same-page-multiple-hits ()
  "同页多命中：全部进入 `--matches'，当前页全部命中都被投喂."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq reader (current-buffer))
      (setq seshat-reader-search-test--total-pages 2)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0) (5.0 6.0 7.0 8.0) (9.0 10.0 11.0 12.0)))))
      (seshat-reader-search "the")
      (should (= 3 (length seshat-reader-search--matches)))
      (should (= 0 seshat-reader-search--index))
      (should (equal (seshat-reader-search--status-string
                      (1+ seshat-reader-search--index)
                      (length seshat-reader-search--matches)
                      (seshat-reader-search--current-page))
                     "第 1/3 个命中 · 第 1 页"))
      (should (string-match-p "第 1/3 个命中" (seshat-reader-search-test--last-message)))
      ;; 清除 → 3 条命中 → 刷新
      (should (equal (seshat-reader-search-test--event-names)
                     '(clear deco deco deco refresh)))
      ;; 搜索命中走 9 参 `--add-decoration'（自定义橙色，不走默认黄的 5 参）
      (should (= 3 (length (seshat-reader-search-test--decos)))))))

(ert-deftest seshat-reader-search-test--advance-across-pages ()
  "`n' 推进到下一命中页并重新投喂该页命中."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 3)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0)))
              (2 . ((5.0 6.0 7.0 8.0) (9.0 10.0 11.0 12.0)))))
      (seshat-reader-search "the")
      (should (= 1 seshat-reader-search-test--current-page))
      ;; 第二个命中在第 2 页 → 跳页
      (seshat-reader-search-next)
      (should (= 2 seshat-reader-search-test--current-page))
      (should (= 1 seshat-reader-search--index))
      (should (equal (seshat-reader-search-test--goto-pages) '(2)))
      ;; 当前页（第 2 页）两条命中同时点亮
      (should (= 2 (length (seshat-reader-search--active-decorations))))
      ;; 再前进一步仍在第 2 页，不产生新的跳页事件
      (seshat-reader-search-next)
      (should (= 2 seshat-reader-search--index))
      (should (equal (seshat-reader-search-test--goto-pages) '(2))))))

(ert-deftest seshat-reader-search-test--wrap-at-end ()
  "到末尾再 `n' 回绕到第一个命中，并提示一次."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 2)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0))) (2 . ((5.0 6.0 7.0 8.0)))))
      (seshat-reader-search "the")
      (seshat-reader-search-next)          ; 第 2 个命中（第 2 页）
      (should (= 1 seshat-reader-search--index))
      (seshat-reader-search-next)          ; 回绕
      (should (= 0 seshat-reader-search--index))
      (should (= 1 seshat-reader-search-test--current-page))
      (should (string-match-p "回绕" (seshat-reader-search-test--last-message))))))

(ert-deftest seshat-reader-search-test--prev-wraps-backwards ()
  "`p' 从第一个命中反向回绕到最后一个命中."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 2)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0))) (2 . ((5.0 6.0 7.0 8.0)))))
      (seshat-reader-search "the")
      (seshat-reader-search-prev)
      (should (= 1 seshat-reader-search--index))
      (should (= 2 seshat-reader-search-test--current-page))
      (should (string-match-p "回绕" (seshat-reader-search-test--last-message))))))

(ert-deftest seshat-reader-search-test--no-match-anywhere ()
  "整本无命中：不投喂任何装饰，提示「未找到」."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 3)
      (seshat-reader-search "nonexistent")
      (should-not seshat-reader-search--matches)
      (should-not seshat-reader-search--active)
      (should-not (seshat-reader-search--active-decorations))
      (should (string-match-p "未找到" (seshat-reader-search-test--last-message)))
      ;; 三页都问过 C，且没有任何投喂
      (should (= 3 (length seshat-reader-search-test--dyn-calls)))
      (should-not (seshat-reader-search-test--decos)))))

(ert-deftest seshat-reader-search-test--truncation-notice ()
  "某页命中达上限时状态行带显式上限提示."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 1)
      (setq seshat-reader-search-test--pages
            (list (cons 1 (seshat-reader-search-test--rects
                           seshat-reader-search--hard-cap))))
      (seshat-reader-search ".")
      (should (= seshat-reader-search--hard-cap
                 (length seshat-reader-search--matches)))
      (should (equal seshat-reader-search--truncated-pages '(1)))
      (should (string-match-p "上限 1024" (seshat-reader-search-test--last-message)))
      (should (string-match-p "仅显示前 1024 条" (seshat-reader-search-test--last-message))))))

(ert-deftest seshat-reader-search-test--match-total-cap ()
  "命中总数达到 `seshat-reader-search-max-matches' 时停止扫描并提示."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 5)
      (let ((seshat-reader-search-max-matches 3))
        (setq seshat-reader-search-test--pages
              '((1 . ((1.0 1.0 2.0 2.0) (3.0 3.0 4.0 4.0)))
                (2 . ((5.0 5.0 6.0 6.0) (7.0 7.0 8.0 8.0)))
                (3 . ((9.0 9.0 10.0 10.0)))
                (4 . ((11.0 11.0 12.0 12.0)))
                (5 . ((13.0 13.0 14.0 14.0)))))
        (seshat-reader-search ".")
        (should seshat-reader-search--capped)
        (should (= 3 (length seshat-reader-search--matches)))
        ;; 达到上限即停：第 2 页后不再向 C 请求第 3-5 页
        (should (= 2 (length seshat-reader-search-test--dyn-calls)))
        (should (string-match-p "命中过多" (seshat-reader-search-test--last-message)))
        (should (string-match-p "仅保留前 3 条"
                                (seshat-reader-search-test--last-message)))))))

(ert-deftest seshat-reader-search-test--quit-restores-decorations ()
  "`C-g' 退出后钩子置空、命中装饰不再投喂（批注/闪现恢复独占）."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 2)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0)))))
      (seshat-reader-search "the")
      (should seshat-reader-search--active)
      (should (functionp (and (boundp 'seshat-reader-annotation-extra-decorations-function)
                              seshat-reader-annotation-extra-decorations-function)))
      (should (= 1 (length (seshat-reader-search--active-decorations))))
      ;; 清空事件记录，只观察退出动作本身的效果
      (setq seshat-reader-search-test--events nil)
      (seshat-reader-search-quit)
      (should-not seshat-reader-search--active)
      (should-not seshat-reader-annotation-extra-decorations-function)
      (should-not (seshat-reader-search--active-decorations))
      ;; 退出时再次重投：只剩「清空 + 刷新」，没有任何命中装饰
      (should-not (seshat-reader-search-test--decos))
      (should (equal (seshat-reader-search-test--event-names)
                     '(clear refresh)))
      ;; 回到起始页
      (should (= 1 seshat-reader-search-test--current-page))
      (should (string-match-p "搜索结束" (seshat-reader-search-test--last-message))))))

(ert-deftest seshat-reader-search-test--accept-keeps-page ()
  "`RET' 结束搜索但停留在当前命中页."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 2)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0))) (2 . ((5.0 6.0 7.0 8.0)))))
      (seshat-reader-search "the")
      (seshat-reader-search-next)
      (seshat-reader-search-accept)
      (should (= 2 seshat-reader-search-test--current-page))
      (should-not seshat-reader-search--active))))

;;; 键位与 transient map

(ert-deftest seshat-reader-search-test--keybindings ()
  "`C-s' 绑在 `seshat-reader-mode-map'，n/p/RET/C-g 只在 transient map 里."
  (should (eq (lookup-key seshat-reader-mode-map (kbd "C-s"))
              #'seshat-reader-search))
  ;; n / p 仍是翻页，绝不被搜索会话抢走（否则翻页彻底失效）
  (should (memq (lookup-key seshat-reader-mode-map (kbd "n"))
                '(seshat-reader-next-page)))
  (should (memq (lookup-key seshat-reader-mode-map (kbd "p"))
                '(seshat-reader-previous-page)))
  (should (eq (lookup-key seshat-reader-search--map (kbd "n"))
              #'seshat-reader-search-next))
  (should (eq (lookup-key seshat-reader-search--map (kbd "p"))
              #'seshat-reader-search-prev))
  (should (eq (lookup-key seshat-reader-search--map (kbd "RET"))
              #'seshat-reader-search-accept))
  (should (eq (lookup-key seshat-reader-search--map (kbd "C-g"))
              #'seshat-reader-search-quit)))

(ert-deftest seshat-reader-search-test--state-is-buffer-local ()
  "搜索状态是 buffer-local：另一个 buffer 看不到它."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 1)
      (setq seshat-reader-search-test--pages '((1 . ((1.0 2.0 3.0 4.0)))))
      (seshat-reader-search "the")
      (let ((local-matches seshat-reader-search--matches))
        (should local-matches)
        (with-temp-buffer
          (should-not seshat-reader-search--matches)
          (should-not seshat-reader-search--query)
          (should-not seshat-reader-search--active))))))

;;; 跨文档残留（同一 buffer 换文档）

(ert-deftest seshat-reader-search-test--no-feed-after-document-switch ()
  "同一 buffer 换了文档后不再投喂上一个文档的命中，且状态被整体清空."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 5)
      (setq buffer-file-name
            (expand-file-name "a.pdf" temporary-file-directory))
      (setq seshat-reader-search--query "the")
      ;; 上一本文档的命中：两条落在第 2 页
      (setq seshat-reader-search--matches
            '((2 1.0 2.0 3.0 4.0) (2 5.0 6.0 7.0 8.0)))
      (setq seshat-reader-search--page-results (make-hash-table :test #'equal))
      (setq seshat-reader-search--index 0)
      (setq seshat-reader-search--active t)
      (setq seshat-reader-search--doc-id
            (seshat-reader-search--current-doc-id))
      (seshat-reader-search--install-hook)
      (should seshat-reader-search--doc-id)
      ;; 仍是同一本文档：正常投喂当前页的两条命中（第 2 页）
      (setq seshat-reader-search-test--current-page 2)
      (should (seshat-reader-search--same-document-p))
      (should (= 2 (length (seshat-reader-search--active-decorations))))
      ;; 复用同一个 buffer 打开另一本文档
      (setq buffer-file-name
            (expand-file-name "b.pdf" temporary-file-directory))
      (should-not (seshat-reader-search--same-document-p))
      ;; 不再投喂：A 的矩形绝不能被画到 B 的页面上
      (should-not (seshat-reader-search--active-decorations))
      ;; 整套会话状态被清空，批注扩展点也摘掉
      (should-not seshat-reader-search--active)
      (should-not seshat-reader-search--matches)
      (should-not seshat-reader-search--page-results)
      (should-not seshat-reader-search--query)
      (should-not seshat-reader-search--index)
      (should-not seshat-reader-search--doc-id)
      (should-not seshat-reader-annotation-extra-decorations-function))))

(ert-deftest seshat-reader-search-test--doc-id-falls-back-without-annotation ()
  "批注模块未加载时，文档标识回落到 `buffer-file-name'（仍能发现换文档）."
  (with-temp-buffer
    (let ((real-fboundp (symbol-function 'fboundp)))
      (cl-letf (((symbol-function 'fboundp)
                 (lambda (symbol)
                   (if (eq symbol 'seshat-reader-annotation--quiet-doc-id)
                       nil
                     (funcall real-fboundp symbol)))))
        (setq buffer-file-name
              (expand-file-name "a.pdf" temporary-file-directory))
        (should (equal (seshat-reader-search--current-doc-id)
                       buffer-file-name))
        (setq seshat-reader-search--doc-id
              (seshat-reader-search--current-doc-id))
        (setq buffer-file-name
              (expand-file-name "b.pdf" temporary-file-directory))
        (should-not (seshat-reader-search--same-document-p))))
    ;; 没有文件名即没有文档身份：不做跨文档判定（fail open）
    (setq buffer-file-name nil)
    (should-not (seshat-reader-search--current-doc-id))
    (should (seshat-reader-search--same-document-p))))

;;; 与批注装饰的共存

(ert-deftest seshat-reader-search-test--annotation-hook-feeds-decorations ()
  "批注模块的 `--redraw-highlights' 会调用本模块注册的 extra 钩子."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 1)
      (setq seshat-reader-search-test--pages '((1 . ((1.0 2.0 3.0 4.0)))))
      (seshat-reader-search "the")
      (setq seshat-reader-search-test--events nil)
      (let ((seshat-reader-annotation-highlight-enabled nil))
        ;; 无批注、无闪现：只剩搜索命中被投喂
        (seshat-reader-annotation--redraw-highlights nil))
      (should (= 1 (length (seshat-reader-search-test--decos))))
      (should (equal (car (seshat-reader-search-test--decos))
                     (list 'deco 1 1.0 2.0 3.0 4.0
                           (nth 0 seshat-reader-search-color)
                           (nth 1 seshat-reader-search-color)
                           (nth 2 seshat-reader-search-color)
                           seshat-reader-search-alpha))))))

(ert-deftest seshat-reader-search-test--works-without-annotation ()
  "批注模块不可用时仍能搜索（自带 clear → add → refresh 降级路径）."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search-test--total-pages 1)
      (setq seshat-reader-search-test--pages
            '((1 . ((1.0 2.0 3.0 4.0) (5.0 6.0 7.0 8.0)))))
      ;; 模拟「批注模块没加载」：把委托目标变成未绑定函数
      (let ((real-fboundp (symbol-function 'fboundp)))
        (cl-letf (((symbol-function 'seshat-reader-annotation--redraw-highlights) nil)
                  ((symbol-function 'fboundp)
                   (lambda (symbol)
                     (if (eq symbol 'seshat-reader-annotation--redraw-highlights)
                         nil
                       (funcall real-fboundp symbol)))))
          (seshat-reader-search "the")
          (should (= 2 (length (seshat-reader-search-test--decos))))
          (should (equal (seshat-reader-search-test--event-names)
                         '(clear deco deco refresh))))))))

;;; 搜索结果侧栏（kind 为 `search'）

(defun seshat-reader-search-test--sidebar-entry-line-count ()
  "数侧栏 buffer 里以「[p.N]」开头的行数（返回侧栏 buffer 缺失时的 0）."
  (let ((count 0)
        (buffer (get-buffer seshat-reader-search-sidebar-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (when (looking-at-p "\\[p\\.[0-9]+\\]")
              (setq count (1+ count)))
            (forward-line 1)))))
    count))

(defun seshat-reader-search-test--sidebar-show-events ()
  "返回本用例内 `seshat-reader-sidebar-show' 的调用记录（正序，形如 (KIND SELECT NAME))."
  (mapcar #'cdr
          (seq-filter (lambda (event) (eq (car-safe event) 'sidebar-show))
                      (reverse seshat-reader-search-test--events))))

(ert-deftest seshat-reader-search-test--sidebar-render-writes-buffer ()
  "`--render-sidebar' 写入标题 + 每条一行；只读、折行、行首为 [p.N]."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "the")
      (seshat-reader-search--render-sidebar
       '((1 1.0 2.0 3.0 4.0) (2 5.0 6.0 7.0 8.0)))
      (with-current-buffer seshat-reader-search-sidebar-buffer-name
        (should (eq major-mode 'special-mode))
        (should buffer-read-only)
        ;; 折行：`special-mode' 默认不折行，侧栏必须显式置 nil
        (should-not truncate-lines)
        (let ((text (buffer-string)))
          (should (string-match-p "搜索结果" text))
          (should (string-match-p "the" text))
          (should (string-match-p "2 条" text)))
        ;; 标题在第 1 行，空行后第 3 行是第一条结果
        (goto-char (point-min))
        (should (looking-at-p "#"))
        (forward-line 2)
        (should (looking-at-p "\\[p\\.1\\]"))
        (forward-line 1)
        (should (looking-at-p "\\[p\\.2\\]"))))))

(ert-deftest seshat-reader-search-test--sidebar-entries-match-lines ()
  "`--sidebar-matches' 与侧栏结果行一一对应，且页码/下标/矩形都对得上."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "x")
      (seshat-reader-search--render-sidebar
       '((1 1.0 2.0 3.0 4.0) (1 5.0 6.0 7.0 8.0) (3 9.0 10.0 11.0 12.0)))
      (with-current-buffer seshat-reader-search-sidebar-buffer-name
        (should (= 3 (length seshat-reader-search--sidebar-matches)))
        (should (equal (mapcar #'car seshat-reader-search--sidebar-matches)
                       '(1 1 3)))
        (should (equal (mapcar #'cadr seshat-reader-search--sidebar-matches)
                       '(0 1 2)))
        (should (equal (nth 2 (car seshat-reader-search--sidebar-matches))
                       '(1.0 2.0 3.0 4.0)))
        ;; 行数与条目数一一对应
        (should (= (length seshat-reader-search--sidebar-matches)
                   (seshat-reader-search-test--sidebar-entry-line-count)))
        ;; 点在第 k 条行上取到的就是第 k 条
        (goto-char (point-min))
        (forward-line 2)
        (should (equal (seshat-reader-search--sidebar-entry-at-point)
                       (nth 0 seshat-reader-search--sidebar-matches)))
        (forward-line 1)
        (should (equal (seshat-reader-search--sidebar-entry-at-point)
                       (nth 1 seshat-reader-search--sidebar-matches)))
        ;; 标题行没有条目
        (goto-char (point-min))
        (should-not (seshat-reader-search--sidebar-entry-at-point))))))

(ert-deftest seshat-reader-search-test--sidebar-goto-jumps-to-line-page ()
  "`sidebar-goto' 在阅读 buffer 里跳到当前行的页码并把它设为当前命中."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "the")
      (setq seshat-reader-search--matches
            '((1 1.0 2.0 3.0 4.0) (2 5.0 6.0 7.0 8.0)))
      (seshat-reader-search--render-sidebar seshat-reader-search--matches)
      (with-current-buffer seshat-reader-search-sidebar-buffer-name
        (goto-char (point-min))
        (forward-line 2)                 ; 第一条（第 1 页）
        (seshat-reader-search-sidebar-goto)
        (should (equal (seshat-reader-search-test--goto-pages) '(1)))
        (forward-line 1)                 ; 第二条（第 2 页）
        (seshat-reader-search-sidebar-goto)
        (should (equal (seshat-reader-search-test--goto-pages) '(1 2))))
      ;; 跳转落在阅读 buffer：当前命中下标被写回源 buffer
      (should (= 1 seshat-reader-search--index)))))

(ert-deftest seshat-reader-search-test--sidebar-move-boundaries ()
  "首条 `p'、末条 `n' 只提示不报错，point 不动."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "the")
      (seshat-reader-search--render-sidebar
       '((1 1.0 2.0 3.0 4.0) (2 5.0 6.0 7.0 8.0)))
      (with-current-buffer seshat-reader-search-sidebar-buffer-name
        ;; 首条上按 `p'
        (goto-char (point-min))
        (forward-line 2)
        (let ((start (point)))
          (seshat-reader-search-sidebar-prev)
          (should (= start (point)))
          (should (string-match-p "已是第一个结果"
                                  (seshat-reader-search-test--last-message))))
        ;; 末条上按 `n'
        (forward-line 1)
        (let ((start (point)))
          (seshat-reader-search-sidebar-next)
          (should (= start (point)))
          (should (string-match-p "已是最后一个结果"
                                  (seshat-reader-search-test--last-message))))
        ;; 边界上都没有触发跳页
        (should-not (seshat-reader-search-test--goto-pages))))))

(ert-deftest seshat-reader-search-test--sidebar-next-moves-and-jumps ()
  "`n' 移动到下一条并跳页；`p' 回到上一条并跳页."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query "the")
      (seshat-reader-search--render-sidebar
       '((1 1.0 2.0 3.0 4.0) (2 5.0 6.0 7.0 8.0)))
      (with-current-buffer seshat-reader-search-sidebar-buffer-name
        (goto-char (point-min))
        (forward-line 2)
        (seshat-reader-search-sidebar-next)
        (should (equal (seshat-reader-search-test--goto-pages) '(2)))
        (should (seshat-reader-search--sidebar-entry-at-point))
        (should (= 2 (nth 0 (seshat-reader-search--sidebar-entry-at-point))))
        (seshat-reader-search-sidebar-prev)
        (should (equal (seshat-reader-search-test--goto-pages) '(2 1)))))))

(ert-deftest seshat-reader-search-test--sidebar-keybindings ()
  "侧栏键表：`RET' 跳转、`n' / `p' 逐条、`q' 只关自己；其余继承 `special-mode-map'."
  (should (eq (lookup-key seshat-reader-search--sidebar-map (kbd "RET"))
              #'seshat-reader-search-sidebar-goto))
  (should (eq (lookup-key seshat-reader-search--sidebar-map (kbd "n"))
              #'seshat-reader-search-sidebar-next))
  (should (eq (lookup-key seshat-reader-search--sidebar-map (kbd "p"))
              #'seshat-reader-search-sidebar-prev))
  (should (eq (lookup-key seshat-reader-search--sidebar-map (kbd "q"))
              #'seshat-reader-search-sidebar-quit))
  ;; 父键表仍是 `special-mode-map'（滚动等基础键不丢）
  (should (eq (keymap-parent seshat-reader-search--sidebar-map)
              special-mode-map)))

(ert-deftest seshat-reader-search-test--sidebar-quit-closes-only-search ()
  "`sidebar-quit' 只按 kind `search' 关面板，不走「全部开合」."
  (let (kinds)
    (cl-letf (((symbol-function 'seshat-reader-sidebar-toggle)
               (lambda (kind) (push kind kinds))))
      (seshat-reader-search-sidebar-quit)
      (should (equal kinds '(search))))))

(ert-deftest seshat-reader-search-test--search-opens-sidebar ()
  "`C-s' 成功后侧栏被列出且**请求光标切过去**（SELECT 非 nil）."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (let ((reader (current-buffer)))
        (setq seshat-reader-search-test--total-pages 2)
        (setq seshat-reader-search-test--pages
              '((1 . ((1.0 2.0 3.0 4.0))) (2 . ((5.0 6.0 7.0 8.0)))))
        (seshat-reader-search "the")
        ;; 页面高亮与状态行仍是原行为
        (should (= 2 (length seshat-reader-search--matches)))
        (should seshat-reader-search--active)
        ;; 侧栏：kind 为 search、SELECT 为 t（光标切到侧栏）
        (let ((shows (seshat-reader-search-test--sidebar-show-events)))
          (should (= 1 (length shows)))
          (should (eq (nth 0 (car shows)) 'search))
          (should (nth 1 (car shows)))
          (should (equal (nth 2 (car shows))
                         seshat-reader-search-sidebar-buffer-name)))
        ;; 侧栏内容与命中一一对应，且记录了源 buffer
        (should (= 2 (seshat-reader-search-test--sidebar-entry-line-count)))
        (with-current-buffer seshat-reader-search-sidebar-buffer-name
          ;; 侧栏记下的源 buffer 就是发起搜索的那个阅读 buffer
          (should (eq seshat-reader-search--sidebar-source reader))
          (should (= 2 (length seshat-reader-search--sidebar-matches))))))))

(ert-deftest seshat-reader-search-test--sidebar-entry-cap ()
  "超出 `--sidebar-max-entries' 时只列前 N 条，标题写明显式条数."
  (seshat-reader-search-test--with-stubs
    (with-temp-buffer
      (setq seshat-reader-search--query ".")
      (let ((seshat-reader-search--sidebar-max-entries 2))
        (seshat-reader-search--render-sidebar
         '((1 1.0 2.0 3.0 4.0) (1 5.0 6.0 7.0 8.0) (2 9.0 10.0 11.0 12.0))))
      (with-current-buffer seshat-reader-search-sidebar-buffer-name
        (should (= 2 (length seshat-reader-search--sidebar-matches)))
        (should (= 2 (seshat-reader-search-test--sidebar-entry-line-count)))
        (should (string-match-p "3 条" (buffer-string)))
        (should (string-match-p "仅列出前 2 条" (buffer-string)))))))

(provide 'seshat-reader-search-test)
;;; seshat-reader-search-test.el ends here
