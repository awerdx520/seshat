;;; seshat-reader-multipage-page-size-test.el --- Tests for the page size layer  -*- lexical-binding: t; -*-

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

;; 阅读器 P2-B「两阶段渲染」T2 的 ERT 测试套件：页尺寸层
;; `seshat-reader--page-size' 与它的缓存 `seshat-reader--multipage-page-sizes'。
;;
;; 夹具策略与 `seshat-reader-page-spec-test.el' 不同：**不用真实 PDF、不依赖已
;; 构建的 `.so'**。本层要钉的是「缓存命中/失效/淘汰 + 是否调用了哪个原生入口」，
;; 这些全部可以用 `cl-letf' 把两个原生入口换成计数器桩来断言，而桩不依赖任何外
;; 部资源 —— 于是整套用例在 `emacs -Q --batch' 下恒可复现（`skip-unless' 恒为
;; 0，符合 `README.md' 的判据）。
;;
;; 覆盖的七条（对应计划 T2 验收 a–g）与两条补充：
;;
;;   a) 未命中 ⇒ 调 C 一次并写入缓存；再调 ⇒ 计数不增；
;;   b) 查尺寸**不触发渲染**：`--page-image-spec' 计数恒为 0；
;;   c) 失败不缓存：桩返回 nil ⇒ 连续两次都真正进 C；
;;   d) 容量上限：超过 `--multipage-cache-limit' 后条目数不超过上限，
;;      且按既有策略淘汰（先丢非驻留页，其次 FIFO）；
;;   e) `--page-spec-clear-cache'（全量失效入口）后尺寸缓存为空；
;;   f) `--multipage-forget-specs'（单页，recycle 远页走这里）后该页尺寸仍在；
;;   g) 无原生入口（`fboundp' 为 nil）⇒ 返回 nil、不抛错、不动缓存；
;;   补充 1) 键与 spec 缓存同源（nil / 1 / 1.0 归一化后共用一条条目）；
;;   补充 2) C 返回退化值时按失败处理（返回 nil、不缓存）。
;;
;; 运行方式（在仓库根目录执行，或直接 `make -C emacs/tests ert'）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader \
;;     -l ert -l emacs/tests/seshat-reader-multipage-page-size-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; batch 的教训（见 `emacs/tests/README.md'）：这里只断言「算出的值」与「调了哪
;; 个函数」，不涉及真实 redisplay；页高是否真的等于已渲染 image 的行高属真机
;; 验收（T3/T9）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)


;;; 夹具

(defmacro seshat-reader-multipage-page-size-test--with-buffer (&rest body)
  "在干净的临时 buffer 里执行 BODY。

两个缓存都是 buffer-local，`with-temp-buffer' 因此天然把用例彼此隔离；
`seshat-reader--pages' 显式清空，让驻留范围默认为 \"无\"（纯 FIFO 淘汰）。"
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq-local seshat-reader--page-spec-cache nil)
     (setq-local seshat-reader--multipage-page-sizes nil)
     (setq-local seshat-reader--pages nil)
     ,@body))

(defmacro seshat-reader-multipage-page-size-test--with-native-size
    (counter result &rest body)
  "在 BODY 内把 `seshat-reader-dyn--page-size' 换成计数器桩。

COUNTER 是计数变量的名字，RESULT 在**每次调用时求值**：因此可以传一个变量，
在用例中途改它来模拟「先失败后成功」。桩的返回值原样当作原生入口的返回值，
便于断言包装层对非法值的处置。"
  (declare (indent 2) (debug t))
  `(let ((,counter 0))
     (cl-letf (((symbol-function 'seshat-reader-dyn--page-size)
                (lambda (&rest _args)
                  (setq ,counter (1+ ,counter))
                  ,result)))
       ,@body)))

(defun seshat-reader-multipage-page-size-test--cached-pages ()
  "返回尺寸缓存里各条目的页号（保持缓存顺序，最新在前）。"
  (mapcar (lambda (entry) (car (car entry)))
          seshat-reader--multipage-page-sizes))


;;; a) 未命中调 C 一次并缓存，命中不再调

(ert-deftest seshat-reader-multipage-page-size-test--miss-calls-native-once ()
  "未命中时调原生入口一次，并按 spec 缓存的键写入尺寸缓存。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (seshat-reader-multipage-page-size-test--with-native-size
        calls (list 612 792)
      (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
      (should (= calls 1))
      ;; 缓存形态 (KEY . (W . H))，KEY 与 spec 缓存同源。
      (should (equal seshat-reader--multipage-page-sizes
                     (list (cons (seshat-reader--page-spec-key 1 1.0 0)
                                 (cons 612 792))))))))

(ert-deftest seshat-reader-multipage-page-size-test--hit-skips-native ()
  "命中缓存后不再调原生入口：第二次调用的计数不增。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (seshat-reader-multipage-page-size-test--with-native-size
        calls (list 612 792)
      (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
      (should (= calls 1))
      (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
      (should (= calls 1))
      ;; 返回值是两元素真列表（不是点对），调用方可以按 (W H) 解构。
      (should (integerp (car (seshat-reader--page-size 1 1.0 0))))
      (should (integerp (cadr (seshat-reader--page-size 1 1.0 0)))))))

(ert-deftest seshat-reader-multipage-page-size-test--key-matches-spec-cache ()
  "键与 spec 缓存同源：nil / 1 / 1.0 归一化后共用一条缓存条目。

两套键口径会让清理与失效不同步，故这里钉住「归一化只有一处」。
"
  (seshat-reader-multipage-page-size-test--with-buffer
    (seshat-reader-multipage-page-size-test--with-native-size
        calls (list 612 792)
      (should (equal (seshat-reader--page-size 1 nil nil) '(612 792)))
      (should (equal (seshat-reader--page-size 1 1 0) '(612 792)))
      (should (equal (seshat-reader--page-size 1 1.0 nil) '(612 792)))
      (should (= calls 1))
      (should (= (length seshat-reader--multipage-page-sizes) 1))
      ;; 不同旋转是不同的请求，必须另进 C。
      (seshat-reader--page-size 1 1.0 90)
      (should (= calls 2))
      (should (= (length seshat-reader--multipage-page-sizes) 2)))))


;;; b) 查尺寸不触发渲染

(ert-deftest seshat-reader-multipage-page-size-test--does-not-render ()
  "查尺寸不触发渲染：渲染入口的调用次数必须为 0（计划 T2 的机械断言）。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (let ((size-calls 0)
          (render-calls 0))
      (cl-letf (((symbol-function 'seshat-reader-dyn--page-size)
                 (lambda (&rest _args)
                   (setq size-calls (1+ size-calls))
                   (list 612 792)))
                ((symbol-function 'seshat-reader-dyn--page-image-spec)
                 (lambda (&rest _args)
                   (setq render-calls (1+ render-calls))
                   'fake-spec)))
        (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
        (should (= size-calls 1))
        (should (= render-calls 0))
        ;; 命中缓存同样不渲染，也不查尺寸。
        (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
        (should (= size-calls 1))
        (should (= render-calls 0))
        ;; spec 缓存也没被顺手填上：尺寸层不产生 image。
        (should-not seshat-reader--page-spec-cache)))))


;;; c) 失败不缓存

(ert-deftest seshat-reader-multipage-page-size-test--failure-not-cached ()
  "原生入口返回 nil 时不缓存：连续两次调用都要真正进 C。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (seshat-reader-multipage-page-size-test--with-native-size calls nil
      (should-not (seshat-reader--page-size 1 1.0 0))
      (should-not (seshat-reader--page-size 1 1.0 0))
      (should (= calls 2))
      (should-not seshat-reader--multipage-page-sizes))))

(ert-deftest seshat-reader-multipage-page-size-test--failure-recovers ()
  "暂时性失败不被永久化：桩恢复后同一页立刻能拿到尺寸并缓存。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (let ((answer nil)
          (calls 0))
      (seshat-reader-multipage-page-size-test--with-native-size
          calls answer
        (should-not (seshat-reader--page-size 1 1.0 0))
        (setq answer (list 612 792))
        (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
        (should (= calls 2))
        (should (= (length seshat-reader--multipage-page-sizes) 1))))))

(ert-deftest seshat-reader-multipage-page-size-test--malformed-not-cached ()
  "原生入口返回退化值时按失败处理：返回 nil 且不写缓存。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (let ((answer nil)
          (calls 0))
      (seshat-reader-multipage-page-size-test--with-native-size
          calls answer
        (dolist (bad '(nil (0 0) (-1 10) (:width 10) "612x792"))
          (setq answer bad)
          (should-not (seshat-reader--page-size 1 1.0 0)))
        (should (= calls 5))
        (should-not seshat-reader--multipage-page-sizes)))))


;;; d) 容量上限与既有淘汰策略

(ert-deftest seshat-reader-multipage-page-size-test--capacity-limit ()
  "条目数不超过 `--multipage-cache-limit'，超出按既有策略淘汰。"
  (seshat-reader-multipage-page-size-test--with-buffer
    ;; 复用既有旋钮把上限压到 2：limit = min(16, spec-limit, max(4, 2*preload+2))。
    (let ((seshat-reader--page-spec-cache-limit 2))
      (should (= (seshat-reader--multipage-cache-limit) 2))
      (seshat-reader-multipage-page-size-test--with-native-size
          calls (list 100 200)
        (dotimes (i 3)
          (should (equal (seshat-reader--page-size (1+ i) 1.0 0) '(100 200))))
        (should (= calls 3))
        (should (= (length seshat-reader--multipage-page-sizes) 2))
        ;; 无驻留范围 ⇒ 纯 FIFO：最新两页留下，页 1 被淘汰。
        (should (equal (seshat-reader-multipage-page-size-test--cached-pages)
                       '(3 2)))))))

(ert-deftest seshat-reader-multipage-page-size-test--capacity-keeps-resident ()
  "淘汰先挑离开驻留集的页：驻留页的条目优先留下（既有策略，不是新策略）。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (let ((seshat-reader--page-spec-cache-limit 2))
      ;; 驻留范围 = 页 1..2（`--multipage-resident-page-range' 读首尾行的页号）。
      (setq seshat-reader--pages '((1 nil) (2 nil)))
      (seshat-reader-multipage-page-size-test--with-native-size
          calls (list 10 20)
        (seshat-reader--page-size 1 1.0 0)
        (seshat-reader--page-size 2 1.0 0)
        (should (= (length seshat-reader--multipage-page-sizes) 2))
        ;; 页 3 不在驻留集：它进去就把自己挤掉，驻留页的条目不动。
        (seshat-reader--page-size 3 1.0 0)
        (should (= (length seshat-reader--multipage-page-sizes) 2))
        (should (= calls 3))
        (should (equal (seshat-reader-multipage-page-size-test--cached-pages)
                       '(2 1)))))))


;;; e) 全量失效入口清空尺寸缓存

(ert-deftest seshat-reader-multipage-page-size-test--clear-cache-drops-sizes ()
  "`--page-spec-clear-cache' 把尺寸缓存一并清空，之后重新进 C。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (seshat-reader-multipage-page-size-test--with-native-size
        calls (list 612 792)
      (seshat-reader--page-size 1 1.0 0)
      (should (= (length seshat-reader--multipage-page-sizes) 1))
      (seshat-reader--page-spec-clear-cache)
      (should-not seshat-reader--multipage-page-sizes)
      (should-not seshat-reader--page-spec-cache)
      ;; 清空后必须重新问 C：没有留下过期的尺寸。
      (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
      (should (= calls 2)))))


;;; f) 单页 forget 不清尺寸（T3 的前提，防回归）

(ert-deftest seshat-reader-multipage-page-size-test--forget-specs-keeps-size ()
  "单页 `--multipage-forget-specs' 只掉 spec，尺寸条目必须留下。

`--multipage-recycle-page'（滚走远页时回收）走的就是这条路径。若尺寸也一起
删掉，该页退回「高度 0 / span 下限 1」的未知尺寸占位，**滚动范围在回收那一刻
立刻变化**（P1/P2 反复踩过的跳变）。T3 的「已定尺寸、未渲染 == 已渲染页高」
直接建立在这里，故本断言是防回归的关键。"
  (seshat-reader-multipage-page-size-test--with-buffer
    (setq seshat-reader--page-spec-cache
          (list (cons (seshat-reader--page-spec-key 1 1.0 0) 'spec-1)
                (cons (seshat-reader--page-spec-key 2 1.0 0) 'spec-2)))
    (seshat-reader-multipage-page-size-test--with-native-size
        calls (list 612 792)
      (seshat-reader--page-size 1 1.0 0)
      (seshat-reader--page-size 2 1.0 0)
      (setq calls 0)
      (should (= (length seshat-reader--multipage-page-sizes) 2))
      (seshat-reader--multipage-forget-specs 1)
      ;; spec 掉了……
      (should (equal (mapcar (lambda (entry) (car (car entry)))
                             seshat-reader--page-spec-cache)
                     '(2)))
      ;; ……尺寸还在，且命中缓存（没有重新进 C）。
      (should (= (length seshat-reader--multipage-page-sizes) 2))
      (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
      (should (= calls 0)))))


;;; g) 无原生入口

(ert-deftest seshat-reader-multipage-page-size-test--without-module ()
  "模块没有该入口时返回 nil、不抛错、不动缓存（批处理 / 未构建是常态）。"
  (seshat-reader-multipage-page-size-test--with-buffer
    ;; 把函数单元置 nil 即模拟「模块里没有这个入口」：`fboundp' 随之为 nil。
    (cl-letf (((symbol-function 'seshat-reader-dyn--page-size) nil))
      (should-not (fboundp 'seshat-reader-dyn--page-size))
      (should-not (seshat-reader--page-size 1 1.0 0))
      (should-not (seshat-reader--page-size 1 1.0))
      (should-not (seshat-reader--page-size 1 nil nil))
      (should-not seshat-reader--multipage-page-sizes)
      ;; 包装层在入口缺失时不碰渲染入口，也不报错。
      (should-not seshat-reader--page-spec-cache))))

(provide 'seshat-reader-multipage-page-size-test)

;;; seshat-reader-multipage-page-size-test.el ends here
