;;; seshat-reader-select-merge-test.el --- ERT tests for char rect line merging  -*- lexical-binding: t; -*-

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

;; `seshat-reader-select--merge-char-rects' 的 ERT 测试套件。该函数把动态
;; 模块给出的**逐字符**矩形（`seshat-reader-dyn--rects-in-rect' 的结果）
;; 合并成贴合文字的**行矩形**：先按 y 中心聚类成行，再在行内按 x 排序后依
;; 水平间隙断开（间隙阈值 = `seshat-reader-select-highlight-gap-ratio' ×
;; 行高）。
;;
;; 全部用例都是纯函数级：不加载动态模块、不打开文档、不依赖 buffer。测试里
;; 的坐标一律用整数，便于用 `equal' 直接比对（`min'/`max' 不改变数值类型）。
;;
;; 垂直收缩（`seshat-reader-select-highlight-shrink-ratio'，默认 0.8）是
;; 合并之后的一步：围绕每条矩形中心把高度乘以比值，让相邻行的横条之间留出
;; 白缝。既有用例断言的是**纯合并几何**，因此 helper 把该比值绑为 1.0
;; （关闭收缩）；收缩本身的用例显式绑定各自需要的比值。

;;; Code:

(require 'ert)
(require 'seshat-reader-select)

(defun seshat-reader-select-merge-test--merge (rects)
  "Call `seshat-reader-select--merge-char-rects' on RECTS.
The vertical shrink is disabled (ratio 1.0) so that the assertions of
the merging tests see the raw merged geometry."
  (let ((seshat-reader-select-highlight-shrink-ratio 1.0))
    (seshat-reader-select--merge-char-rects rects)))

(ert-deftest seshat-reader-select-merge-test--defaults ()
  "三个 defcustom 的默认值与类型：粒度 `line'、间隙比 0.8、收缩比 0.8."
  (should (eq 'line seshat-reader-select-highlight-granularity))
  (should (= 0.8 seshat-reader-select-highlight-gap-ratio))
  (should (= 0.8 seshat-reader-select-highlight-shrink-ratio))
  (should (eq 'choice
              (car (get 'seshat-reader-select-highlight-granularity
                        'custom-type))))
  (should (eq 'number
              (get 'seshat-reader-select-highlight-gap-ratio 'custom-type)))
  (should (eq 'number
              (get 'seshat-reader-select-highlight-shrink-ratio
                   'custom-type))))

(ert-deftest seshat-reader-select-merge-test--single-line-continuous ()
  "同一行内首尾相接的三个字符矩形合并成一条."
  (should (equal (seshat-reader-select-merge-test--merge
                  '((10 100 15 110) (15 100 20 110) (20 100 25 110)))
                 '((10 100 25 110)))))

(ert-deftest seshat-reader-select-merge-test--two-lines ()
  "两行各三个字符：每行一条，按 (y, x) 排序输出."
  (should (equal (seshat-reader-select-merge-test--merge
                  '((10 100 15 110) (15 100 20 110) (20 100 25 110)
                    (10 112 15 122) (15 112 20 122) (20 112 25 122)))
                 '((10 100 25 110) (10 112 25 122)))))

(ert-deftest seshat-reader-select-merge-test--dual-column-splits ()
  "同一 y 上两簇字符被大水平间隙分开（双栏排版）时输出两条."
  (let ((result (seshat-reader-select-merge-test--merge
                 '((10 100 30 110) (200 100 220 110)))))
    (should (equal result '((10 100 30 110) (200 100 220 110))))
    ;; 每条都必须是正面积矩形（C 侧绘制无效矩形无意义）
    (dolist (rect result)
      (should (< (nth 0 rect) (nth 2 rect)))
      (should (< (nth 1 rect) (nth 3 rect))))))

(ert-deftest seshat-reader-select-merge-test--single-character ()
  "单个字符矩形原样返回（不丢、不扩）."
  (should (equal (seshat-reader-select-merge-test--merge '((10 100 15 110)))
                 '((10 100 15 110)))))

(ert-deftest seshat-reader-select-merge-test--empty-input ()
  "空输入返回 nil（nil 与空表两种形态）."
  (should-not (seshat-reader-select-merge-test--merge nil))
  (should-not (seshat-reader-select-merge-test--merge '())))

(ert-deftest seshat-reader-select-merge-test--unordered-input ()
  "乱序输入结果与有序输入一致，且两行时按 y 再按 x 排序."
  (should (equal (seshat-reader-select-merge-test--merge
                  '((20 100 25 110) (10 100 15 110) (15 100 20 110)))
                 '((10 100 25 110))))
  (should (equal (seshat-reader-select-merge-test--merge
                  '((15 112 20 122) (10 100 15 110) (20 112 25 122)
                    (15 100 20 110) (10 112 15 122) (20 100 25 110)))
                 '((10 100 25 110) (10 112 25 122)))))

(ert-deftest seshat-reader-select-merge-test--character-granularity-keeps-rects ()
  "`granularity' 为 `character' 时不合并，只按 (y, x) 排序."
  (let ((seshat-reader-select-highlight-granularity 'character))
    (should (equal (seshat-reader-select-merge-test--merge
                    '((20 100 25 110) (10 100 15 110) (15 100 20 110)))
                   '((10 100 15 110) (15 100 20 110) (20 100 25 110))))
    ;; 多行同样只排序、不合并
    (should (equal (seshat-reader-select-merge-test--merge
                    '((15 112 20 122) (10 100 15 110)))
                   '((10 100 15 110) (15 112 20 122))))))

(ert-deftest seshat-reader-select-merge-test--gap-ratio-zero-splits-any-gap ()
  "`gap-ratio' 为 0 时：间隙 0（相接）仍合并，任何正间隙都断开."
  (let ((seshat-reader-select-highlight-gap-ratio 0))
    (should (equal (seshat-reader-select-merge-test--merge
                    '((10 100 15 110) (15 100 20 110)))
                   '((10 100 20 110))))
    (should (equal (seshat-reader-select-merge-test--merge
                    '((10 100 15 110) (16 100 20 110)))
                   '((10 100 15 110) (16 100 20 110))))))

(ert-deftest seshat-reader-select-merge-test--gap-ratio-huge-merges-all ()
  "`gap-ratio' 极大时同一行的所有字符合并成一条（即使间隙很宽）."
  (let ((seshat-reader-select-highlight-gap-ratio 1000))
    (should (equal (seshat-reader-select-merge-test--merge
                    '((10 100 15 110) (200 100 220 110)))
                   '((10 100 220 110))))))

(ert-deftest seshat-reader-select-merge-test--median-line-height ()
  "行高取本行矩形高度的中位数：一个更高的字符不抬高阈值."
  (should (equal (seshat-reader-select-merge-test--merge
                  '((10 100 15 112) (15 100 20 110) (20 100 25 110)))
                 '((10 100 25 112)))))

(ert-deftest seshat-reader-select-merge-test--invalid-rects-skipped ()
  "形态不合法的元素（nil、长度不足、非列表）被跳过，不影响正确元素."
  (should (equal (seshat-reader-select-merge-test--merge
                  '(nil (10 100 15) (10 100 15 110) "x"))
                 '((10 100 15 110))))
  (should-not (seshat-reader-select-merge-test--merge '(nil (10 100 15) "x"))))

(ert-deftest seshat-reader-select-merge-test--shrink-halves-height-keeps-center ()
  "收缩比 0.5：高度减半，y 中心不变，x 范围不变."
  (let ((seshat-reader-select-highlight-shrink-ratio 0.5))
    (let* ((result (seshat-reader-select--merge-char-rects
                    '((10 100 25 110))))
           (rect (car result)))
      ;; 高 10 → 5，中心仍是 105.0
      (should (equal result '((10 102.5 25 107.5))))
      (should (= 5.0 (- (nth 3 rect) (nth 1 rect))))
      (should (= 105.0 (/ (+ (nth 1 rect) (nth 3 rect)) 2.0)))
      ;; 水平范围与收缩无关
      (should (equal (list (nth 0 rect) (nth 2 rect)) '(10 25)))
      ;; 收缩本身不改条数
      (should (= 1 (length result))))))

(ert-deftest seshat-reader-select-merge-test--shrink-ratio-one-is-identity ()
  "收缩比 1.0：与未收缩的合并结果完全 `equal'（整数仍是整数）."
  (let ((input '((10 100 15 110) (15 100 20 110)
                 (10 112 15 122) (15 112 20 122)))
        (expected '((10 100 20 110) (10 112 20 122))))
    (let ((seshat-reader-select-highlight-shrink-ratio 1.0))
      (should (equal (seshat-reader-select--merge-char-rects input) expected)))
    ;; 关闭收缩就是恒等：浮点化不算通过
    (let ((seshat-reader-select-highlight-shrink-ratio 1.0))
      (should (equal (seshat-reader-select--shrink-rects-vertically
                      expected 1.0)
                     expected)))))

(ert-deftest seshat-reader-select-merge-test--shrink-ratio-clamped ()
  "越界比值被夹紧：0.1 → 0.3，2.0 → 1.0（后者等价于关闭收缩）."
  (let ((seshat-reader-select-highlight-shrink-ratio 0.1))
    (should (= 0.3 (seshat-reader-select--highlight-shrink-ratio)))
    ;; 高 10 × 0.3 = 3，中心 105.0
    (should (equal (seshat-reader-select--merge-char-rects '((10 100 20 110)))
                   '((10 103.5 20 106.5)))))
  (let ((seshat-reader-select-highlight-shrink-ratio 2.0))
    (should (= 1.0 (seshat-reader-select--highlight-shrink-ratio)))
    (should (equal (seshat-reader-select--merge-char-rects '((10 100 20 110)))
                   '((10 100 20 110))))))

(defconst seshat-reader-select-merge-test--eight-lines
  ;; 8 行 × 2 字符的实测形态：字符 quad 高 11.7pt、行距 10.3pt（quad 比行距
  ;; 高，所以收缩前相邻两条横条垂直重叠 1.4pt）。
  (let (rects)
    (dotimes (i 8)
      (let ((y0 (+ 100.0 (* i 10.3)))
            (y1 (+ 111.7 (* i 10.3))))
        (push (list 100.0 y0 110.0 y1) rects)
        (push (list 110.0 y0 120.0 y1) rects)))
    (nreverse rects)))

(ert-deftest seshat-reader-select-merge-test--shrink-gaps-between-eight-lines ()
  "8 行实测数据：每行各自收缩，行间留出白缝（相邻 y1 < 下一行 y0）."
  (let ((seshat-reader-select-highlight-shrink-ratio 0.8))
    (let ((result (seshat-reader-select--merge-char-rects
                   seshat-reader-select-merge-test--eight-lines)))
      (should (= 8 (length result)))
      ;; 每行：保留原来的 y 中心，高度 = 11.7 × 0.8 = 9.36
      (dotimes (i 8)
        (let ((rect (nth i result))
              (center (+ 105.85 (* i 10.3))))
          (should (< (abs (- (/ (+ (nth 1 rect) (nth 3 rect)) 2.0) center))
                     1e-9))
          (should (< (abs (- (- (nth 3 rect) (nth 1 rect)) 9.36)) 1e-9))
          ;; x 范围完全不变（两字符 100..120）
          (should (= 100.0 (nth 0 rect)))
          (should (= 120.0 (nth 2 rect)))))
      ;; 相邻横条之间必须有缝（这是本次改动的目的）
      (dotimes (i 7)
        (should (< (nth 3 (nth i result)) (nth 1 (nth (1+ i) result)))))))
  ;; 对照：关闭收缩时相邻横条真的重叠（证明收缩不是无意义的动作）
  (let ((seshat-reader-select-highlight-shrink-ratio 1.0))
    (let ((result (seshat-reader-select--merge-char-rects
                   seshat-reader-select-merge-test--eight-lines)))
      (should (= 8 (length result)))
      (dotimes (i 7)
        (should (> (nth 3 (nth i result)) (nth 1 (nth (1+ i) result))))))))

(ert-deftest seshat-reader-select-merge-test--shrink-nonnumeric-falls-back ()
  "非数字 / nil 回落默认 0.8，且不报错."
  (dolist (bad '(nil "0.5" shrink-me))
    (let ((seshat-reader-select-highlight-shrink-ratio bad))
      (should (= 0.8 (seshat-reader-select--highlight-shrink-ratio)))
      ;; 高 10 × 0.8 = 8，中心 105.0
      (should (equal (seshat-reader-select--merge-char-rects
                      '((10 100 20 110)))
                     '((10 101.0 20 109.0)))))))

(ert-deftest seshat-reader-select-merge-test--shrink-applies-to-character-granularity ()
  "`character' 粒度同样收缩：逐字符矩形各自围绕自身中心缩短."
  (let ((seshat-reader-select-highlight-granularity 'character)
        (seshat-reader-select-highlight-shrink-ratio 0.5))
    (should (equal (seshat-reader-select--merge-char-rects
                    '((20 100 25 110) (10 100 15 110)))
                   '((10 102.5 15 107.5) (20 102.5 25 107.5))))))

(provide 'seshat-reader-select-merge-test)
;;; seshat-reader-select-merge-test.el ends here
