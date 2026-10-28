;;; seshat-reader-annotation-cross-page-location-test.el --- 跨页 location 新旧形态  -*- lexical-binding: t; -*-

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

;; 跨页 location 的**两种形态**（批次 3 = T4 / T5 / T6），全程纯函数级：
;; 不加载动态模块、不打开文档、不发请求。
;;
;; 1. **构造（T4）**：`seshat-reader-annotation--anchor' 在全部矩形同页时输出
;;    旧形态 `page:<n>;rect:…`（**与改造前逐字节一致**），跨页时输出
;;    `pages:<a>-<b>;rect@<p>:…`；`--anchor-segments' 必须把五元组
;;    `(PAGE X0 Y0 X1 Y1)' 识别为**带页号段**（否则 PAGE 会当 x0、Y1 被丢弃，
;;    是确定性数据损坏）；跨页按「页数 + 段数」计数，超上限降级为首页矩形并
;;    `display-warning'。引用链接（D5b）在跨页时降级为纯页锚 `page:<起点页>'。
;; 2. **解析与接入（T5）**：新增的 `--pages-from-location' /
;;    `--page-rects-from-location' 解析新形态；`--annotation-decorations'
;;    按段页号展开；列表与 ETAF 条目的页码显示 `a-b'、跳转落首页。
;; 3. **兼容反向断言（T6）**：新形态下 `--page-from-location' 必须返回 nil、
;;    `--rects-from-location' 必须返回 nil。依据 F7（旧解析器：前者只认
;;    `page:'、后者只按 `;' 切段且只认 `rect:' 前缀）与 F8（页码取不到时整条
;;    批注不参与装饰），旧客户端因此**整条跳过**该批注而不是把两页的矩形都画
;;    到第一页上（那才是「画错」）。本套件最后一条用例即是该断言的载体，它是
;;    变异自检（把 `--page-from-location' 改成也认 `pages:'）的失败观察点。
;;
;; 运行方式见 `docs/emacs-reader.md' 的逐文件 ERT 命令（load-path 需含
;; `emacs' 与 `emacs/seshat-reader'）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader-annotation)
(require 'seshat-reader-reference)

;;; 夹具

(defun seshat-reader-annotation-cross-page-location-test--temp-file ()
  "创建一个临时 .pdf 文件并返回其绝对路径（供 `file-equal-p' 用）。
调用方负责 `delete-file'。"
  (make-temp-file "seshat-cross-page-" nil ".pdf"))

(defun seshat-reader-annotation-cross-page-location-test--selection
    (file page page-rects &optional rect)
  "构造一个跨页选区 plist：FILE、起点页 PAGE、逐页几何 PAGE-RECTS、可选 RECT."
  (list :text "第一页文字\n第二页文字"
        :page page
        :rect (or rect '(10 20 30 40))
        :rects (list (or rect '(10 20 30 40)))
        :page-rects page-rects
        :file file))

(defconst seshat-reader-annotation-cross-page-location-test--two-page-location
  "pages:1-2;rect@1:10,20,30,40;rect@2:50,60,70,80"
  "两页新形态 location 的标准样例（页 1 一段、页 2 一段）。")

;;; T4：新形态构造

(ert-deftest seshat-reader-annotation-cross-page-location-test--anchor-cross-page-new-form ()
  "跨页时 `--anchor' 输出 `pages:<a>-<b>;rect@<page>:…'（逐段带页号）。
样例：页 1 两段 + 页 2 一段 → 页跨度 1-2，段按阅读顺序（页升序、页内原顺序）。"
  (should (equal (seshat-reader-annotation--anchor
                  1 '((1 10 20 30 40) (1 12 22 32 42) (2 50 60 70 80)))
                 (concat "pages:1-2"
                         ";rect@1:10.00,20.00,30.00,40.00"
                         ";rect@1:12.00,22.00,32.00,42.00"
                         ";rect@2:50.00,60.00,70.00,80.00")))
  ;; 页跨度取**实际有矩形**的页号最小/最大值（不是 PAGE 与 PAGE+N）
  (should (equal (seshat-reader-annotation--anchor
                  4 '((4 1 2 3 4) (9 5 6 7 8)))
                 (concat "pages:4-9"
                         ";rect@4:1.00,2.00,3.00,4.00"
                         ";rect@9:5.00,6.00,7.00,8.00"))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--anchor-single-page-byte-identical ()
  "单页时五元组入参与四元组入参的输出**逐字节相同**（旧形态回归基线）。
`--selection-rects' 改取 `:page-rects' 后，单页选区走的正是这条路径，因此这条
断言就是「单页 location 零变更」的证据。"
  (let ((from-page-rects (seshat-reader-annotation--anchor
                          1 '((1 10 20 30 40) (1 5 6 7 8))))
        (from-rects (seshat-reader-annotation--anchor
                     1 '((10 20 30 40) (5 6 7 8))))
        (from-bare-rect (seshat-reader-annotation--anchor 1 '(10 20 30 40))))
    (should (equal from-page-rects from-rects))
    (should (equal from-rects
                   "page:1;rect:10.00,20.00,30.00,40.00;rect:5.00,6.00,7.00,8.00"))
    (should (equal from-bare-rect "page:1;rect:10.00,20.00,30.00,40.00"))
    ;; 无几何仍是纯页锚
    (should (equal (seshat-reader-annotation--anchor 7 nil) "page:7"))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--anchor-orders-segments-by-page ()
  "跨页时段序按页升序重排（页内保持输入顺序），页跨度仍取最小/最大值。
`:page-rects' 本已是阅读顺序，本断言防的是乱序入参（手工构造 / 反向拖拽）。"
  (should (equal (seshat-reader-annotation--anchor
                  3 '((3 50 60 70 80) (1 10 20 30 40) (1 12 22 32 42)))
                 (concat "pages:1-3"
                         ";rect@1:10.00,20.00,30.00,40.00"
                         ";rect@1:12.00,22.00,32.00,42.00"
                         ";rect@3:50.00,60.00,70.00,80.00"))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--anchor-segments-five-tuple ()
  "**反向断言**：五元组 `(PAGE X0 Y0 X1 Y1)' 不得被当成裸 rect。
改造前 `--anchor-segments' 只看 `(nth 0..3)'，于是页号会变成 x0、Y1 被丢弃。
本用例同时从两个方向锁死：归一化结果带正确页号，且写出的串里没有把页号当坐标。"
  (should (equal (seshat-reader-annotation--anchor-segments '((2 10 20 30 40)))
                 '((2 10 20 30 40))))
  (should (equal (seshat-reader-annotation--anchor-segments '((10 20 30 40)) 2)
                 '((2 10 20 30 40))))
  ;; 单段五元组（首元素是数字，走单 rect 分支）同样按带页号处理
  (should (equal (seshat-reader-annotation--anchor-segments '(2 10 20 30 40))
                 '((2 10 20 30 40))))
  (let ((location (seshat-reader-annotation--anchor 2 '((2 10 20 30 40)))))
    ;; 页号 2 是页锚，不是 x0：坐标必须是 10/20/30/40
    (should (equal location "page:2;rect:10.00,20.00,30.00,40.00"))
    (should (equal (seshat-reader-annotation--rects-from-location location)
                   '((10.0 20.0 30.0 40.0))))
    (should-not (equal (seshat-reader-annotation--rects-from-location location)
                       '((2.0 10.0 20.0 30.0)))))
  ;; 坏元素（非数字）被跳过，不毁掉整个锚
  (should (equal (seshat-reader-annotation--anchor-segments
                  '((1 "x" 2 3 4) (1 10 20 30 40)))
                 '((1 10 20 30 40)))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--anchor-degrades-over-limit ()
  "跨页锚按「页数 + 段数」计数，超上限时降级为**首页**矩形并 display-warning。
降级不静默丢段：提示进 `*Warnings*'，输出退回单页形态（首页 = 页号最小的页）。"
  (let ((seshat-reader-annotation--anchor-max-segments 3)
        (warnings nil)
        (location nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &optional _level)
                 (push message warnings))))
      ;; 2 页 + 3 段 = 5 > 3 → 降级
      (setq location (seshat-reader-annotation--anchor
                      1 '((1 10 20 30 40) (1 12 22 32 42) (2 50 60 70 80)))))
    (should (equal location
                   "page:1;rect:10.00,20.00,30.00,40.00;rect:12.00,22.00,32.00,42.00"))
    (should (= 1 (length warnings)))
    (should (string-match-p "跨页" (car warnings)))
    (should (string-match-p "上限" (car warnings)))
    ;; 降级后能被**旧**解析器原样读回（首页矩形），不会写出读不动的串
    (should (= 1 (seshat-reader-annotation--page-from-location location)))
    (should (= 2 (length (seshat-reader-annotation--rects-from-location
                          location))))
    ;; 未超限时仍走新形态（同 max，但少一段）
    (let ((seshat-reader-annotation--anchor-max-segments 4))
      (should (string-prefix-p "pages:"
                               (seshat-reader-annotation--anchor
                                1 '((1 10 20 30 40) (2 50 60 70 80))))))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--selection-rects-prefers-page-rects ()
  "`--selection-rects' 优先 `:page-rects'，其后 `:rects'，最后 `:rect'。"
  (should (equal (seshat-reader-annotation--selection-rects
                  (list :page-rects '((2 5 6 7 8))
                        :rects '((1 1 2 2))
                        :rect '(0 0 1 1)))
                 '((2 5 6 7 8))))
  (should (equal (seshat-reader-annotation--selection-rects
                  (list :rects '((9 9 9 9)) :rect '(0 0 1 1)))
                 '((9 9 9 9))))
  (should (equal (seshat-reader-annotation--selection-rects
                  (list :rects nil :rect '(0 0 1 1)))
                 '((0 0 1 1))))
  (should-not (seshat-reader-annotation--selection-rects (list :rect nil)))
  (should-not (seshat-reader-annotation--selection-rects nil)))

(ert-deftest seshat-reader-annotation-cross-page-location-test--selection-cross-page-signal ()
  "跨页判定只看 `:page-rects' 去重页号：单页多矩形不误判。
这是引用链接降级（D5b）与锚形态选择的**共同信号**。"
  (let ((single (list :page-rects '((1 10 20 30 40) (1 12 22 32 42))))
        (cross (list :page-rects '((1 10 20 30 40) (2 50 60 70 80))))
        (legacy (list :rects '((10 20 30 40)) :rect '(10 20 30 40))))
    (should-not (seshat-reader-annotation--selection-cross-page-p single))
    (should (seshat-reader-annotation--selection-cross-page-p cross))
    (should-not (seshat-reader-annotation--selection-cross-page-p legacy))
    (should (equal (seshat-reader-annotation--selection-pages cross) '(1 2)))
    (should (equal (seshat-reader-annotation--selection-pages single) '(1)))
    (should-not (seshat-reader-annotation--selection-pages legacy))))

;;; T4 / D5b：引用链接降级为纯页锚

(ert-deftest seshat-reader-annotation-cross-page-location-test--current-location-cross-page-degrades ()
  "跨页选区时 `--current-location' 输出纯页锚 `page:<起点页>' 并 message 提示。"
  (let* ((file (seshat-reader-annotation-cross-page-location-test--temp-file))
         (selection (seshat-reader-annotation-cross-page-location-test--selection
                     file 2 '((2 10 20 30 40) (3 50 60 70 80))))
         (messages nil)
         (location nil))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name file)
          (let ((seshat-reader-select-last selection))
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
              (setq location (seshat-reader-reference--current-location)))))
      (delete-file file))
    (should (equal location "page:2"))
    (should (= 1 (length messages)))
    (should (string-match-p "降级" (car messages)))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--current-location-single-page-unchanged ()
  "单页选区时 `--current-location' 输出与改动前**逐字节一致**（旧形态回归）。"
  (let* ((file (seshat-reader-annotation-cross-page-location-test--temp-file))
         (selection (seshat-reader-annotation-cross-page-location-test--selection
                     file 2 '((2 10 20 30 40)) '(10 20 30 40)))
         (messages nil)
         (location nil))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name file)
          (let ((seshat-reader-select-last selection))
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
              (setq location (seshat-reader-reference--current-location)))))
      (delete-file file))
    (should (equal location "page:2;rect:10.00,20.00,30.00,40.00"))
    (should-not messages)))

(defmacro seshat-reader-annotation-cross-page-location-test--with-store
    (selection &rest body)
  "在阅读器 buffer 中带 SELECTION 执行 BODY，返回 `--link-for' 收到的 location.
SELECTION 的 `:file' 同时决定 `buffer-file-name'（`--store' 会 `file-equal-p'
校验两者等价）；BODY 结束后删除该临时文件。链接与描述都由桩截断——本套件只
关心 location 形态。"
  (declare (indent 1) (debug t))
  `(let ((selection-value ,selection)
         (captured nil))
     (unwind-protect
         (with-temp-buffer
           (setq major-mode 'seshat-reader-mode)
           (setq buffer-file-name (plist-get selection-value :file))
           (let ((seshat-reader-select-last selection-value))
             (cl-letf (((symbol-function 'seshat-reader-annotation--doc-id)
                        (lambda (&rest _) "ebook:a.pdf"))
                       ((symbol-function 'seshat-reader-annotation--quiet-p)
                        (lambda (&rest _) t))
                       ((symbol-function 'seshat-reader-reference--link-for)
                        (lambda (_doc-id &optional location)
                          (setq captured location)
                          "seshat:ebook:a.pdf"))
                       ((symbol-function 'org-link-store-props)
                        (lambda (&rest _) nil))
                       ((symbol-function 'message) (lambda (&rest _) nil)))
               ,@body))
           captured)
       (ignore-errors
         (delete-file (plist-get selection-value :file))))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--store-link-cross-page-degrades ()
  "`org-store-link' 的 `:store' 路径（不经过 `--current-location'）同样降级。"
  (let ((file (seshat-reader-annotation-cross-page-location-test--temp-file)))
    (should (equal
             (seshat-reader-annotation-cross-page-location-test--with-store
                 (seshat-reader-annotation-cross-page-location-test--selection
                  file 2 '((2 10 20 30 40) (3 50 60 70 80)))
               (should (seshat-reader-reference-store-link)))
             "page:2"))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--store-link-single-page-unchanged ()
  "单页时 `org-store-link' 的 location 与改动前**逐字节一致**（旧形态回归）。"
  (let ((file (seshat-reader-annotation-cross-page-location-test--temp-file)))
    (should (equal
             (seshat-reader-annotation-cross-page-location-test--with-store
                 (seshat-reader-annotation-cross-page-location-test--selection
                  file 2 '((2 10 20 30 40)) '(10 20 30 40))
               (should (seshat-reader-reference-store-link)))
             "page:2;rect:10.00,20.00,30.00,40.00"))))

;;; T5：新形态解析

(ert-deftest seshat-reader-annotation-cross-page-location-test--pages-from-location ()
  "`--pages-from-location' 只认**严格**的 `pages:<a>-<b>' 前缀形态。"
  (should (equal (seshat-reader-annotation--pages-from-location
                  seshat-reader-annotation-cross-page-location-test--two-page-location)
                 '(1 2)))
  (should (equal (seshat-reader-annotation--pages-from-location "pages:3-9") '(3 9)))
  ;; 非新形态
  (should-not (seshat-reader-annotation--pages-from-location "page:1;rect:1,2,3,4"))
  (should-not (seshat-reader-annotation--pages-from-location "chapter:2@10-20"))
  ;; 锚点：不允许前缀污染、不允许尾部垃圾
  (should-not (seshat-reader-annotation--pages-from-location "xpages:1-2"))
  (should-not (seshat-reader-annotation--pages-from-location "pages:1-2x"))
  (should-not (seshat-reader-annotation--pages-from-location "pages:a-b;"))
  (should-not (seshat-reader-annotation--pages-from-location ""))
  (should-not (seshat-reader-annotation--pages-from-location nil)))

(ert-deftest seshat-reader-annotation-cross-page-location-test--page-rects-from-location ()
  "`--page-rects-from-location' 逐段解析 `rect@<page>:' 并带上段页号。"
  (should (equal (seshat-reader-annotation--page-rects-from-location
                  seshat-reader-annotation-cross-page-location-test--two-page-location)
                 '((1 10.0 20.0 30.0 40.0) (2 50.0 60.0 70.0 80.0))))
  ;; 旧形态的 `rect:' 段不是本函数的目标形态 → nil（旧 location 不产生新几何）
  (should-not (seshat-reader-annotation--page-rects-from-location
               "page:1;rect:10,20,30,40;rect:5,6,7,8"))
  (should-not (seshat-reader-annotation--page-rects-from-location ""))
  (should-not (seshat-reader-annotation--page-rects-from-location nil)))

(ert-deftest seshat-reader-annotation-cross-page-location-test--page-rects-reject-bad-segments ()
  "坏段（字段数不对 / 非数字 / 负面积 / 页号 0）只丢该段，不抛错、不毁其余段。"
  (should (equal (seshat-reader-annotation--page-rects-from-location
                  "pages:1-2;rect@1:10,20;rect@2:50,60,70,80")
                 '((2 50.0 60.0 70.0 80.0))))
  (should (equal (seshat-reader-annotation--page-rects-from-location
                  "pages:1-2;rect@1:abc,20,30,40;rect@2:50,60,70,80")
                 '((2 50.0 60.0 70.0 80.0))))
  ;; 负面积（x1 < x0）
  (should-not (seshat-reader-annotation--page-rects-from-location
               "pages:1-1;rect@1:30,20,10,40"))
  ;; 页号 0 不是合法 1-based 页
  (should-not (seshat-reader-annotation--page-rects-from-location
               "pages:0-1;rect@0:10,20,30,40")))

(ert-deftest seshat-reader-annotation-cross-page-location-test--page-rects-caps-segment-count ()
  "段数达到解析端上限即停止（与 `--rects-from-location' 同口径的有界解析）。"
  (let* ((count (+ seshat-reader-annotation--rect-max-segments 100))
         (segments nil))
    (dotimes (i count)
      (push (format "rect@1:%d,%d,%d,%d" i i i i) segments))
    (let ((location (concat "pages:1-1;" (mapconcat #'identity
                                                    (nreverse segments) ";"))))
      (should (= seshat-reader-annotation--rect-max-segments
                 (length (seshat-reader-annotation--page-rects-from-location
                          location)))))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--decorations-expand-by-segment-page ()
  "`--annotation-decorations' 对跨页形态按**段页号**展开；旧形态逐字节不变。"
  (should (equal (seshat-reader-annotation--annotation-decorations
                  (list (list :location
                              seshat-reader-annotation-cross-page-location-test--two-page-location
                              :kind "highlight")))
                 '((1 10.0 20.0 30.0 40.0 "highlight")
                   (2 50.0 60.0 70.0 80.0 "highlight"))))
  ;; kind 归一（underline / strikeout）同样生效
  (should (equal (seshat-reader-annotation--annotation-decorations
                  (list (list :location
                              seshat-reader-annotation-cross-page-location-test--two-page-location
                              :kind "underline")))
                 '((1 10.0 20.0 30.0 40.0 "underline")
                   (2 50.0 60.0 70.0 80.0 "underline"))))
  ;; 旧形态回归：单页多段，页号取页锚
  (should (equal (seshat-reader-annotation--annotation-decorations
                  (list (list :location "page:3;rect:1,2,3,4;rect:5,6,7,8"
                              :kind "highlight")))
                 '((3 1.0 2.0 3.0 4.0 "highlight")
                   (3 5.0 6.0 7.0 8.0 "highlight")))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--insert-entry-shows-page-span ()
  "文本列表对新形态显示 `a-b'，行属性 `seshat-reader-annotation-page' 是首页（供跳转）。"
  (with-temp-buffer
    (seshat-reader-annotation--insert-entry
     (list (cons 'id 7)
           (cons 'location seshat-reader-annotation-cross-page-location-test--two-page-location)
           (cons 'text "跨页批注")))
    (should (string-match-p "1-2" (buffer-string)))
    (should-not (string-match-p "无法从 location 解析页码" (buffer-string)))
    (should (= 1 (get-text-property (point-min) 'seshat-reader-annotation-page)))
    (should (equal (get-text-property (point-min)
                                      'seshat-reader-annotation-location)
                   seshat-reader-annotation-cross-page-location-test--two-page-location)))
  ;; 旧形态仍显示数字页号（回归）
  (with-temp-buffer
    (seshat-reader-annotation--insert-entry
     (list (cons 'id 8) (cons 'location "page:3;rect:1,2,3,4") (cons 'text "旧批注")))
    (should (string-match-p "3" (buffer-string)))
    (should-not (string-match-p "-" (buffer-string)))
    (should (= 3 (get-text-property (point-min) 'seshat-reader-annotation-page)))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--etaf-items-page-and-label ()
  "`--etaf-items' 的 `:page' 是首页数字（跳转/排序安全），`:page-label' 是 \"a-b\"。
离线队列待同步条目（queued 分支）同样如此。"
  (let ((items (seshat-reader-annotation--etaf-items
                (list (list (cons 'id 7)
                            (cons 'location
                                  seshat-reader-annotation-cross-page-location-test--two-page-location)
                            (cons 'text "服务端跨页")))
                (list (list :uuid "uuid-1"
                            :location
                            seshat-reader-annotation-cross-page-location-test--two-page-location
                            :text "离线条目")))))
    (should (= 2 (length items)))
    (dolist (item items)
      (should (= 1 (plist-get item :page)))
      (should (equal "1-2" (plist-get item :page-label))))
    ;; 旧形态：`:page' 不变，`:page-label' 为 nil（消费方继续用 `:page'）
    (let ((legacy (seshat-reader-annotation--etaf-items
                   (list (list (cons 'id 9)
                               (cons 'location "page:3;rect:1,2,3,4")
                               (cons 'text "旧")))
                   nil)))
      (should (= 3 (plist-get (car legacy) :page)))
      (should-not (plist-get (car legacy) :page-label)))))

;;; T6：兼容反向断言（旧客户端必须「整条跳过」而非「画错」）

(ert-deftest seshat-reader-annotation-cross-page-location-test--legacy-parsers-skip-new-form ()
  "**T6 核心**：新形态下旧解析器全部返回 nil，因此旧客户端的装饰必然为空。
依据 F7（`--page-from-location' 只认 `page:' 正则、`--rects-from-location'
只按 `;' 切段且只认 `rect:' 前缀）与 F8（页码取不到时 `when page' 跳过整条
批注，不报错）。

若有人把这个行为「修好」（让 `--page-from-location' 也认 `pages:'，或让
`--rects-from-location' 接受 `rect@'），下面的 `should-not' 立刻失败——这正是
变异自检的观察点：旧客户端一旦能解析新形态，就会把两页的矩形都画到第一页上。"
  (let ((location seshat-reader-annotation-cross-page-location-test--two-page-location))
    (should-not (seshat-reader-annotation--page-from-location location))
    (should-not (seshat-reader-annotation--rects-from-location location))
    ;; 模拟旧实现：`(when page (dolist (rect (--rects-from-location location)) …))'
    (should-not (let ((page (seshat-reader-annotation--page-from-location location))
                      (rects (seshat-reader-annotation--rects-from-location location)))
                  (when page
                    (mapcar (lambda (rect) (cons page rect)) rects))))
    ;; `--page-rects-from-location' 不认旧形态（互斥：两种形态不会互相吞并）
    (should-not (seshat-reader-annotation--page-rects-from-location
                 "page:1;rect:10,20,30,40"))
    ;; 同一 location 上，新解析器给出的是**带页号**的两段，与旧解析器的 nil 对照
    (should (= 2 (length (seshat-reader-annotation--page-rects-from-location
                          location))))))

(ert-deftest seshat-reader-annotation-cross-page-location-test--anchor-segment-rejects-float-page ()
  "五元组的页号必须是整数：浮点页号按坏段跳过，不得抛 wrong-type-argument。
`(1.0 10 20 30 40)' 只判「五个元素都是数字」时会通过，随后写入端用
`(format \"page:%d\" …)' / `(format \"rect@%d:…\" …)' 渲染它即抛
`wrong-type-argument'，整条批注的创建中断；解析端读回的页号是 `[0-9]+'
口径的整数，两端必须一致。修法（审查修复 F2）：五元组分支要求
`(integerp (nth 0 rect))'，不满足按坏段处理（返回 nil，由调用方跳过），
不猜也不取整。"
  ;; 单体：浮点页号 → nil（不抛错）
  (should-not (seshat-reader-annotation--anchor-segment '(1.0 10 20 30 40) nil))
  ;; 列表入口：坏段被跳过，合法整数五元组行为不变
  (should (equal '((2 10 20 30 40))
                 (seshat-reader-annotation--anchor-segments
                  '((1.0 10 20 30 40) (2 10 20 30 40)) nil)))
  (should (equal '((3 10 20 30 40))
                 (seshat-reader-annotation--anchor-segments
                  '((3 10 20 30 40)) nil)))
  ;; 裸 rect（四元组）口径不变：页号仍用 PAGE 补齐
  (should (equal '(3 10 20 30 40)
                 (seshat-reader-annotation--anchor-segment '(10 20 30 40) 3)))
  ;; 端到端：`--anchor' 不因浮点页号抛错，坏段被跳过后退化为页级锚
  (should (equal "page:1"
                 (seshat-reader-annotation--anchor 1 '((1.0 10 20 30 40)))))
  ;; 混合入参：整数段照常写出，浮点段一个都不写
  (should (equal "page:2;rect:10.00,20.00,30.00,40.00"
                 (seshat-reader-annotation--anchor
                  2 '((2.0 50 60 70 80) (2 10 20 30 40))))))

;;; seshat-reader-annotation-cross-page-location-test.el ends here
