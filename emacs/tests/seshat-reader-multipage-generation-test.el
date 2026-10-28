;;; seshat-reader-multipage-generation-test.el --- Tests for the render generation  -*- lexical-binding: t; -*-

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

;; 阅读器 P2-B「两阶段渲染」T4 的 ERT 测试套件：渲染代际作废
;; （`seshat-reader--multipage-render-generation'，决策 D4）。
;;
;; 本层要钉的只有一件事：**什么时机算「旧几何」，什么时机不算**。调度器本身
;; （idle / 周期 timer / pending 集合）属于 T5，本文件不碰任何 timer，也不用真
;; 实 PDF 与已构建的 `.so' —— 与 `seshat-reader-multipage-page-size-test.el' 同
;; 一套夹具策略（`cl-letf' 桩掉两个原生入口），因此在 `emacs -Q --batch' 下恒可
;; 复现，无 `skip-unless'。
;;
;; 覆盖（对应计划 T4 验收 ①–④ 与两条防回归补充）：
;;
;;   1) `--page-spec-clear-cache' 调用后代际 +1（多次调用等于多次 +1）；
;;   2) 同一入口清空尺寸缓存、spec 缓存与失败计数表（T5 的失败计数占位）；
;;   3) `--multipage-forget-specs'（单页，recycle 远页走这里）**不改变代际**、
;;      该页尺寸仍在 —— 防过度作废的回归守卫（复审 N1）；
;;   4) `--multipage-generation-current-p'：同代 t、跨代 nil、
;;      nil / 非整数一律 nil；
;;   5) 模拟在途结果：记下 gen0 → 全量失效 → 用 gen0 判定为 nil，且带 gen0 调
;;      两个 remember 函数都不落缓存（即 T5 会丢弃该结果）；
;;   6) 两个 remember 函数的 `&optional GENERATION' 保持既有调用点零改动：
;;      两参调用（GENERATION = nil）逐字等同旧行为；当前代际照常缓存；
;;   7) 代际是 buffer-local：一个 buffer 自增不影响另一个。
;;
;; 运行方式（在仓库根目录执行，或直接 `make -C emacs/tests ert'）：
;;
;;   cd /home/thomas/Workspace/seshat && \
;;   emacs --batch -Q -L emacs -L emacs/seshat-reader \
;;     -l ert -l emacs/tests/seshat-reader-multipage-generation-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; batch 的教训（见 `emacs/tests/README.md'）：这里只断言「代数与缓存表」，
;; 不涉及真实 redisplay —— 「缩放/切暗色期间不出现旧代际像素」属 T9 的真机 L3。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seshat-reader)


;;; 夹具

(defmacro seshat-reader-multipage-generation-test--with-buffer (&rest body)
  "在干净的临时 buffer 里执行 BODY。

代际、两个缓存与失败计数表都是 buffer-local，`with-temp-buffer' 因此天然把
用例彼此隔离，并让代际回到初始值 0。"
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq-local seshat-reader--multipage-render-generation 0)
     (setq-local seshat-reader--page-spec-cache nil)
     (setq-local seshat-reader--multipage-page-sizes nil)
     (setq-local seshat-reader--multipage-render-failures nil)
     (setq-local seshat-reader--pages nil)
     ,@body))

(defmacro seshat-reader-multipage-generation-test--with-native-size
    (counter result &rest body)
  "在 BODY 内把 `seshat-reader-dyn--page-size' 换成计数器桩。

COUNTER 是计数变量的名字，RESULT 在每次调用时求值 —— 与
`seshat-reader-multipage-page-size-test.el' 的同名夹具一致。"
  (declare (indent 2) (debug t))
  `(let ((,counter 0))
     (cl-letf (((symbol-function 'seshat-reader-dyn--page-size)
                (lambda (&rest _args)
                  (setq ,counter (1+ ,counter))
                  ,result)))
       ,@body)))

(defun seshat-reader-multipage-generation-test--cached-pages ()
  "返回尺寸缓存里各条目的页号（保持缓存顺序，最新在前）。"
  (mapcar (lambda (entry) (car (car entry)))
          seshat-reader--multipage-page-sizes))


;;; 1) 全量失效入口自增代际

(ert-deftest seshat-reader-multipage-generation-test--starts-at-zero ()
  "新 buffer 的代际是 0。"
  (seshat-reader-multipage-generation-test--with-buffer
    (should (= seshat-reader--multipage-render-generation 0))
    (should (seshat-reader--multipage-generation-current-p 0))))

(ert-deftest seshat-reader-multipage-generation-test--clear-cache-bumps ()
  "`--page-spec-clear-cache' 每调用一次代际 +1。"
  (seshat-reader-multipage-generation-test--with-buffer
    (seshat-reader--page-spec-clear-cache)
    (should (= seshat-reader--multipage-render-generation 1))
    (seshat-reader--page-spec-clear-cache)
    (seshat-reader--page-spec-clear-cache)
    (should (= seshat-reader--multipage-render-generation 3))
    ;; 是**严格自增**，不是「置 1」：跨多次失效仍在增长。
    (should (> seshat-reader--multipage-render-generation 0))))


;;; 2) 同一入口清空三张表

(ert-deftest seshat-reader-multipage-generation-test--clear-cache-drops-tables ()
  "全量失效入口清空 spec 缓存、尺寸缓存与失败计数表（计划 T4 验收 ①）。"
  (seshat-reader-multipage-generation-test--with-buffer
    (seshat-reader-multipage-generation-test--with-native-size
        calls (list 612 792)
      (seshat-reader--page-size 1 1.0 0)
      (setq seshat-reader--page-spec-cache
            (list (cons (seshat-reader--page-spec-key 1 1.0 0) 'spec-1)))
      ;; T5 的失败计数表：本批只有占位定义，这里手工塞一条模拟。
      (setq seshat-reader--multipage-render-failures
            (list (cons (seshat-reader--page-spec-key 1 1.0 0) 2)))
      (should (= (length seshat-reader--multipage-page-sizes) 1))
      (seshat-reader--page-spec-clear-cache)
      (should-not seshat-reader--page-spec-cache)
      (should-not seshat-reader--multipage-page-sizes)
      (should-not seshat-reader--multipage-render-failures)
      ;; 清空后必须重新问 C：没有留下过期尺寸。
      (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
      (should (= calls 2)))))


;;; 3) 单页 forget 不自增代际（防过度作废的回归守卫，复审 N1）

(ert-deftest seshat-reader-multipage-generation-test--forget-specs-keeps-generation ()
  "单页 `--multipage-forget-specs' 不改代际，且该页尺寸仍在。

`--multipage-recycle-page'（滚走远页时回收）走的就是这条路径。若在此自增代
际，「回收一页」就等于「作废全部在途 pending」，持续滚动时 idle 补位被系统性
作废、退化为超时强制同步 —— 直接吃掉两阶段渲染的收益。故本断言是防回归关键：
**代际只由 `seshat-reader--page-spec-clear-cache' 自增**。
"
  (seshat-reader-multipage-generation-test--with-buffer
    (seshat-reader-multipage-generation-test--with-native-size
        calls (list 612 792)
      (seshat-reader--page-size 1 1.0 0)
      (seshat-reader--page-size 2 1.0 0)
      (seshat-reader--page-spec-remember
       (seshat-reader--page-spec-key 1 1.0 0) 'spec-1)
      (seshat-reader--page-spec-remember
       (seshat-reader--page-spec-key 2 1.0 0) 'spec-2)
      (let ((generation seshat-reader--multipage-render-generation))
        (seshat-reader--multipage-forget-specs 1)
        ;; 代际分毫不动。
        (should (= seshat-reader--multipage-render-generation generation))
        (should (seshat-reader--multipage-generation-current-p generation))
        ;; spec 掉了……
        (should (equal (mapcar (lambda (entry) (car (car entry)))
                               seshat-reader--page-spec-cache)
                       '(2)))
        ;; ……尺寸还在，且仍命中缓存（没有重新进 C）。
        (setq calls 0)
        (should (equal (seshat-reader-multipage-generation-test--cached-pages)
                       '(2 1)))
        (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
        (should (= calls 0))))))


;;; 4) 代际比对函数

(ert-deftest seshat-reader-multipage-generation-test--predicate-same-generation ()
  "同代返回 t。"
  (seshat-reader-multipage-generation-test--with-buffer
    (let ((gen seshat-reader--multipage-render-generation))
      (should (eq t (seshat-reader--multipage-generation-current-p gen))))
    (seshat-reader--page-spec-clear-cache)
    (should (seshat-reader--multipage-generation-current-p
             seshat-reader--multipage-render-generation))))

(ert-deftest seshat-reader-multipage-generation-test--predicate-across-generation ()
  "跨代返回 nil。"
  (seshat-reader-multipage-generation-test--with-buffer
    (let ((gen seshat-reader--multipage-render-generation))
      (seshat-reader--page-spec-clear-cache)
      (should-not (seshat-reader--multipage-generation-current-p gen)))))

(ert-deftest seshat-reader-multipage-generation-test--predicate-rejects-non-integer ()
  "nil 与非整数一律返回 nil（缺代际的结果必须丢弃，不能靠猜）。"
  (seshat-reader-multipage-generation-test--with-buffer
    (dolist (bad '(nil "0" 0.0 'zero))
      (should-not (seshat-reader--multipage-generation-current-p bad)))
    ;; 而当前的 0 是有效代际：区分「没有代际」与「第 0 代」。
    (should (seshat-reader--multipage-generation-current-p 0))))


;;; 5) 模拟在途结果被丢弃（计划 T4 验收 ②/④ 的核心）

(ert-deftest seshat-reader-multipage-generation-test--inflight-result-dropped ()
  "记下 gen0 → 全量失效 → 用 gen0 判定为 nil；带 gen0 的写入全部不落缓存。

这就是 T5 的丢弃路径在 batch 下的等价形式：渲染在 gen0 发起，回来时几何已经
换了一代，于是 spec、尺寸与补位都不许写回。
"
  (seshat-reader-multipage-generation-test--with-buffer
    (seshat-reader-multipage-generation-test--with-native-size
        calls (list 612 792)
      (let ((gen0 seshat-reader--multipage-render-generation)
            (key (seshat-reader--page-spec-key 1 1.0 0)))
        (should (seshat-reader--multipage-generation-current-p gen0))
        ;; 在途期间：缩放 / 切暗色 / 重载 / relayout 走同一入口。
        (seshat-reader--page-spec-clear-cache)
        (should-not (seshat-reader--multipage-generation-current-p gen0))
        ;; 迟到的结果：两个 remember 都不许写。
        (should-not (seshat-reader--page-spec-remember key 'stale-spec gen0))
        (should-not (seshat-reader--multipage-page-size-remember
                     key (cons 612 792) gen0))
        (should-not seshat-reader--page-spec-cache)
        (should-not seshat-reader--multipage-page-sizes)
        ;; 同一页在当前代际下重新渲染则照常落缓存（丢弃不是永久化）。
        (should (equal (seshat-reader--page-size 1 1.0 0) '(612 792)))
        (should (= calls 1))
        (should (= (length seshat-reader--multipage-page-sizes) 1))))))


;;; 6) `&optional GENERATION' 保持既有调用点零改动

(ert-deftest seshat-reader-multipage-generation-test--remember-without-generation ()
  "两参调用（GENERATION = nil）逐字等同旧行为：不做代际校验，直接缓存。"
  (seshat-reader-multipage-generation-test--with-buffer
    (let ((key (seshat-reader--page-spec-key 3 1.0 0)))
      ;; 先让代际前进，证明 nil 参数照样写（旧调用点不受影响）。
      (seshat-reader--page-spec-clear-cache)
      (should (equal (seshat-reader--page-spec-remember key 'spec-3)
                     (list (cons key 'spec-3))))
      (should (equal (cdr (assoc key seshat-reader--page-spec-cache))
                     'spec-3))
      (should (equal (seshat-reader--multipage-page-size-remember
                      key (cons 10 20))
                     (list (cons key (cons 10 20)))))
      (should (equal (cdr (assoc key seshat-reader--multipage-page-sizes))
                     (cons 10 20))))))

(ert-deftest seshat-reader-multipage-generation-test--remember-with-current-generation ()
  "带当前代际的写入照常落缓存。"
  (seshat-reader-multipage-generation-test--with-buffer
    (seshat-reader--page-spec-clear-cache)
    (let ((gen seshat-reader--multipage-render-generation)
          (key (seshat-reader--page-spec-key 3 1.0 0)))
      (should (equal (seshat-reader--page-spec-remember key 'spec-3 gen)
                     (list (cons key 'spec-3))))
      (should (equal (seshat-reader--multipage-page-size-remember
                      key (cons 10 20) gen)
                     (list (cons key (cons 10 20))))))))


;;; 7) 代际是 buffer-local

(ert-deftest seshat-reader-multipage-generation-test--generation-is-buffer-local ()
  "一个 buffer 自增代际不影响另一个 buffer。"
  (seshat-reader-multipage-generation-test--with-buffer
    (let ((outer seshat-reader--multipage-render-generation))
      (seshat-reader-multipage-generation-test--with-buffer
        (seshat-reader--page-spec-clear-cache)
        (should (= seshat-reader--multipage-render-generation (1+ outer))))
      (should (= seshat-reader--multipage-render-generation outer)))))

(provide 'seshat-reader-multipage-generation-test)

;;; seshat-reader-multipage-generation-test.el ends here
