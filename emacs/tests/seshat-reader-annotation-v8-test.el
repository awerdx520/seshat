;;; seshat-reader-annotation-v8-test.el --- ERT tests for v8 annotation contract  -*- lexical-binding: t; -*-

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

;; v8 批注契约（`kind' / `selected_text'）在 Emacs 端的兼容读取测试：
;; 缺键兼容、摘要回退链、`chapter:' location 降级、ink 聚合显示，以及离线
;; 队列按 `(kind, location, text)' 去重。
;;
;; 全部用例**绝不触网**：只调用纯函数（解析/摘要/聚合/渲染到临时 buffer），
;; 队列去重用 `cl-letf' 桩替 `seshat-reader-annotation--fetch' 与
;; `seshat-rest-create-annotation'，任何真实 HTTP 调用都不会发生；也不读写
;; 用户的真实队列文件（`--sync-create' 不触碰队列文件）。
;;
;; 测试隔离：加载队列模块后立即关闭自动同步定时器，避免 ERT 期间后台同步。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader-annotation)
(require 'seshat-reader-annotation-queue)

(seshat-reader-annotation-queue-disable-timer)

;;; 辅助构造

(defun seshat-reader-annotation-v8-test--annotation (plist)
  "把 PLIST 转成服务端响应形态的 alist（键为符号）.
PLIST 形如 `(:id 1 :location \"page:3\" :text \"x\")'；值为 nil 的字段
**不**出现在结果里，用于模拟老服务端缺键的情形。"
  (let (alist)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (when value
          (push (cons (intern (substring (symbol-name key) 1)) value) alist))))
    (nreverse alist)))

(defun seshat-reader-annotation-v8-test--render (item)
  "把条目 ITEM 用纯文本渲染路径渲染到临时 buffer，返回 buffer 字符串."
  (with-temp-buffer
    (seshat-reader-annotation--insert-entry item)
    (buffer-string)))

;;; 1. 响应缺键兼容

(ert-deftest seshat-reader-annotation-v8-test-missing-keys-defaults ()
  "缺 `kind' / `selected_text' 的控制响应：kind 视为 note，其余字段不变."
  (let ((ann (seshat-reader-annotation-v8-test--annotation
              '(:id 7 :location "page:5;rect:1,2,3,4" :text "老批注"))))
    (should (equal (seshat-reader-annotation--kind ann) "note"))
    (should-not (seshat-reader-annotation--selected-text ann))
    (should (equal (seshat-reader-annotation--item-field ann 'id) 7))
    (should (equal (seshat-reader-annotation--item-field ann 'text) "老批注"))
    (should (equal (seshat-reader-annotation--page-from-location
                    (seshat-reader-annotation--item-field ann 'location))
                   5))
    ;; 摘要与改动前完全一致（备注即摘要）
    (should (equal (seshat-reader-annotation--display-text ann) "老批注"))))

;;; 2. 响应含新键

(ert-deftest seshat-reader-annotation-v8-test-present-keys-read ()
  "响应含 `kind' / `selected_text' 时正确读入；缺键与含键互不干扰."
  (let ((ann (seshat-reader-annotation-v8-test--annotation
              '(:id 8 :location "page:2"
                :text "" :kind "highlight" :selected_text "被选中的原文"))))
    (should (equal (seshat-reader-annotation--kind ann) "highlight"))
    (should (equal (seshat-reader-annotation--selected-text ann) "被选中的原文"))
    (should (equal (seshat-reader-annotation--item-field ann 'text) ""))))

(ert-deftest seshat-reader-annotation-v8-test-all-items-propagate-keys ()
  "`--all-items' 把 v8 字段转成 `:kind' / `:selected-text' 供两条渲染路径."
  (let* ((ann (seshat-reader-annotation-v8-test--annotation
               '(:id 9 :location "page:4"
                 :text "" :kind "highlight" :selected_text "原文")))
         (items (seshat-reader-annotation--all-items (list ann) nil)))
    (should (= 1 (length items)))
    (should (equal (plist-get (car items) :kind) "highlight"))
    (should (equal (plist-get (car items) :selected-text) "原文"))
    (should (equal (plist-get (car items) :page) 4))))

;;; 3-4. 摘要回退链

(ert-deftest seshat-reader-annotation-v8-test-summary-falls-back-to-selected ()
  "`text' 为空且 `selected_text' 非空时，摘要取选中原文."
  (let* ((ann (seshat-reader-annotation-v8-test--annotation
               '(:id 10 :location "page:2"
                 :text "" :kind "highlight"
                 :selected_text "这是一段被选中的原文")))
         (summary (seshat-reader-annotation--summary
                   (seshat-reader-annotation--display-text ann))))
    (should (equal summary "这是一段被选中的原文"))
    (should (string-match-p "这是一段被选中的原文"
                            (seshat-reader-annotation-v8-test--render ann)))))

(ert-deftest seshat-reader-annotation-v8-test-summary-prefers-text ()
  "`text' 与 `selected_text' 都非空时，摘要取 `text'."
  (let ((ann (seshat-reader-annotation-v8-test--annotation
              '(:id 11 :location "page:2"
                :text "我写的备注" :kind "highlight"
                :selected_text "被选中的原文"))))
    (should (equal (seshat-reader-annotation--display-text ann) "我写的备注"))
    (should-not (string-match-p "被选中的原文"
                                (seshat-reader-annotation-v8-test--render ann)))))

(ert-deftest seshat-reader-annotation-v8-test-plist-selected-text-fallback ()
  "渲染层 plist 的 `:selected-text' 也能作为摘要回退来源.
alist（服务端，键 `selected_text'）与 plist（渲染层，键 `:selected-text'）
两种形态都必须被识别，否则 ETAF 路径拿到的选中原文恒为 nil。"
  (let ((item (list :id 15 :location "page:2" :text ""
                    :kind "highlight" :selected-text "plist 原文")))
    (should (equal (seshat-reader-annotation--selected-text item) "plist 原文"))
    (should (equal (seshat-reader-annotation--display-text item) "plist 原文"))
    (when (require 'seshat-reader-etaf nil t)
      (should (equal (seshat-reader-etaf--item-text item) "plist 原文")))))

;;; 5. chapter: location 降级

(ert-deftest seshat-reader-annotation-v8-test-chapter-location-degrades ()
  "`chapter:' 与 `chapter-<n>' 两种形态不报错、页码为 nil、显示「章节 N」."
  (let ((v8 (seshat-reader-annotation-v8-test--annotation
             '(:id 12 :location "chapter:3@120-180" :text "EPUB 批注")))
        (legacy (seshat-reader-annotation-v8-test--annotation
                 '(:id 13 :location "chapter-7" :text "旧 EPUB 批注")))
        (page (seshat-reader-annotation-v8-test--annotation
               '(:id 14 :location "page:6;rect:1,2,3,4" :text "PDF 批注"))))
    ;; 解析：不报错、不返回非法页码
    (should-not (seshat-reader-annotation--page-from-location
                 (seshat-reader-annotation--item-field v8 'location)))
    (should (= 3 (seshat-reader-annotation--chapter-from-location
                  (seshat-reader-annotation--item-field v8 'location))))
    (should (= 7 (seshat-reader-annotation--chapter-from-location
                  (seshat-reader-annotation--item-field legacy 'location))))
    ;; 显示：含「章节 N」，且不再提示无法解析页码
    (let ((rendered (seshat-reader-annotation-v8-test--render v8)))
      (should (string-match-p "章节 3" rendered))
      (should-not (string-match-p "无法从 location 解析页码" rendered)))
    (should (string-match-p "章节 7"
                            (seshat-reader-annotation-v8-test--render legacy)))
    ;; page 形态行为不变：仍显示数字页码，且无章节文案
    (let ((rendered (seshat-reader-annotation-v8-test--render page)))
      (should (string-match-p "    6  PDF 批注" rendered))
      (should-not (string-match-p "章节" rendered)))))

;;; 6. ink location 取页码

(ert-deftest seshat-reader-annotation-v8-test-ink-page-from-location ()
  "`page:<n>;ink:...' 可取页码 n，且既有 page/rect 解析行为不变."
  (let ((ink (seshat-reader-annotation-v8-test--annotation
              '(:id 20 :location "page:9;ink:1.00,2.00,3.00,4.00"
                :text "" :kind "ink")))
        (rect (seshat-reader-annotation-v8-test--annotation
               '(:id 21 :location "page:9;rect:1,2,3,4" :text "文本批注"))))
    (should (= 9 (seshat-reader-annotation--ink-page ink)))
    (should (= 9 (seshat-reader-annotation--page-from-location
                  (seshat-reader-annotation--item-field ink 'location))))
    (should (= 9 (seshat-reader-annotation--page-from-location
                  (seshat-reader-annotation--item-field rect 'location))))
    (should (equal (seshat-reader-annotation--rects-from-location
                    (seshat-reader-annotation--item-field rect 'location))
                   '((1.0 2.0 3.0 4.0))))))

;;; 7. ink 按页聚合

(ert-deftest seshat-reader-annotation-v8-test-ink-aggregate-same-page ()
  "同页 3 笔 ink 聚合为 1 行，文案含「3 笔」，不渲染空白条目."
  (let* ((items (seshat-reader-annotation--all-items
                 (list (seshat-reader-annotation-v8-test--annotation
                        '(:id 30 :location "page:3;ink:1,1,2,2"
                          :text "" :kind "ink"))
                       (seshat-reader-annotation-v8-test--annotation
                        '(:id 31 :location "page:3;ink:5,5,6,6"
                          :text "" :kind "ink"))
                       (seshat-reader-annotation-v8-test--annotation
                        '(:id 32 :location "page:3;ink:7,7,8,8"
                          :text "" :kind "ink")))
                 nil))
         (rendered (with-temp-buffer
                     (dolist (item items)
                       (seshat-reader-annotation--insert-entry item))
                     (buffer-string))))
    (should (= 1 (length items)))
    (should (equal (plist-get (car items) :kind) "ink"))
    (should (= 3 (plist-get (car items) :ink-count)))
    (should (= 3 (plist-get (car items) :page)))
    (should (equal (plist-get (car items) :ink-ids) '(30 31 32)))
    ;; 合成键：ETAF 路径仍能选中该聚合行
    (should (equal (plist-get (car items) :key) "ink-page:3"))
    (when (require 'seshat-reader-etaf nil t)
      (should (equal (seshat-reader-etaf--item-key (car items)) "ink-page:3"))
      (should (= 3 (seshat-reader-etaf--item-page (car items)))))
    ;; 一行且文案含笔数；摘要不回退到空白
    (should (= 1 (length (split-string (string-trim rendered) "\n"))))
    (should (string-match-p "第 3 页手写（3 笔）" rendered))
    (should-not (string-match-p "（无正文）" rendered))))

(ert-deftest seshat-reader-annotation-v8-test-ink-aggregate-different-pages ()
  "不同页的 ink 不合并；文本批注穿插顺序保持不变."
  (let* ((items (seshat-reader-annotation--all-items
                 (list (seshat-reader-annotation-v8-test--annotation
                        '(:id 40 :location "page:1;ink:1,1,2,2"
                          :text "" :kind "ink"))
                       (seshat-reader-annotation-v8-test--annotation
                        '(:id 41 :location "page:2;ink:1,1,2,2"
                          :text "" :kind "ink"))
                       (seshat-reader-annotation-v8-test--annotation
                        '(:id 42 :location "page:2;rect:1,2,3,4"
                          :text "文本批注")))
                 nil))
    (should (= 3 (length items)))
    (should (equal (mapcar (lambda (item) (plist-get item :page)) items) '(1 2 2)))
    (should (equal (mapcar (lambda (item) (plist-get item :ink-count)) items)
                   '(1 1 nil)))
    (should (equal (plist-get (nth 2 items) :text) "文本批注")))))

(ert-deftest seshat-reader-annotation-v8-test-ink-aggregate-not-rendered-blank ()
  "未聚合的单笔 ink 也不会渲染空白摘要行."
  (let ((ann (seshat-reader-annotation-v8-test--annotation
              '(:id 50 :location "page:8;ink:1,1,2,2" :text "" :kind "ink"))))
    (should (equal (seshat-reader-annotation--display-text ann)
                   "第 8 页手写（1 笔）"))
    (should (string-match-p "第 8 页手写（1 笔）"
                            (seshat-reader-annotation-v8-test--render ann)))))

;;; 8. 队列去重键含 kind

(ert-deftest seshat-reader-annotation-v8-test-queue-dedup-distinguishes-kind ()
  "同 location 不同 kind 不被误去重：服务端是 ink、队列是 note 时必须创建."
  (let* ((ann (seshat-reader-annotation-v8-test--annotation
               '(:id 60 :location "page:3;ink:1,1,2,2" :text "" :kind "ink")))
         (entry (list :action 'create :uid "uid-1" :document-id "doc"
                      :location "page:3;ink:1,1,2,2" :text ""))
         (created nil))
    (cl-letf (((symbol-function 'seshat-reader-annotation--fetch)
               (lambda (_uid) (list ann)))
              ((symbol-function 'seshat-rest-create-annotation)
               (lambda (_uid location text)
                 (setq created (list location text))
                 (list (cons 'id 61)))))
      (should (eq (seshat-reader-annotation-queue--sync-create entry) 'ok)))
    ;; 未被误判为已同步 → 真的发起了创建
    (should (equal created '("page:3;ink:1,1,2,2" "")))))

(ert-deftest seshat-reader-annotation-v8-test-queue-dedup-missing-kind-is-note ()
  "缺 `kind' 的队列条目按 note 比较：服务端已有同 location 同 text 即去重."
  (let* ((ann (seshat-reader-annotation-v8-test--annotation
               '(:id 70 :location "page:5;rect:1,2,3,4" :text "备注")))
         (entry (list :action 'create :uid "uid-2" :document-id "doc"
                      :location "page:5;rect:1,2,3,4" :text "备注"))
         (created nil))
    (cl-letf (((symbol-function 'seshat-reader-annotation--fetch)
               (lambda (_uid) (list ann)))
              ((symbol-function 'seshat-rest-create-annotation)
               (lambda (&rest _args) (setq created t) (list (cons 'id 71)))))
      (should (eq (seshat-reader-annotation-queue--sync-create entry) 'ok)))
    (should-not created)))

(ert-deftest seshat-reader-annotation-v8-test-queue-dedup-explicit-note-kind ()
  "队列条目显式带 `:kind \"note\"' 时与缺键的服务端记录视为同一去重键."
  (let* ((ann (seshat-reader-annotation-v8-test--annotation
               '(:id 80 :location "page:5;rect:1,2,3,4" :text "备注")))
         (entry (list :action 'create :uid "uid-3" :document-id "doc"
                      :location "page:5;rect:1,2,3,4" :text "备注"
                      :kind "note"))
         (created nil))
    (cl-letf (((symbol-function 'seshat-reader-annotation--fetch)
               (lambda (_uid) (list ann)))
              ((symbol-function 'seshat-rest-create-annotation)
               (lambda (&rest _args) (setq created t) (list (cons 'id 81)))))
      (should (eq (seshat-reader-annotation-queue--sync-create entry) 'ok)))
    (should-not created)))

(provide 'seshat-reader-annotation-v8-test)
;;; seshat-reader-annotation-v8-test.el ends here
