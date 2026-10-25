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
                  t)))
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
  "把事件记录归一成符号列表（正序）."
  (mapcar (lambda (event) (if (consp event) (car event) event))
          (reverse seshat-reader-search-test--events)))

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

(provide 'seshat-reader-search-test)
;;; seshat-reader-search-test.el ends here
