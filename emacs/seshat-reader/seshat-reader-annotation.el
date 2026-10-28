;;; seshat-reader-annotation.el --- Annotations for seshat-reader documents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: lisp, files, tools
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

;; `seshat-reader' 文档的批注采集与侧车同步。
;;
;; 批注是**侧车（sidecar）**数据：保存在服务端（`POST /api/annotations'），
;; 不写回文档文件；阅读器只负责采集与展示，从不修改用户文档。
;;
;; 本模块区分**两个文档身份**（双值不变量）：
;;
;; - **显示标识（doc-id）**：由 `seshat-reader-annotation--doc-id' 从文件
;;   路径单点派生，约定为 \"<根标签>:<相对路径>\"，根标签到根目录的映射由
;;   `seshat-reader-annotation-roots' 配置；未命中任何已配置根的文档降级为
;;   \"local:<绝对路径>\"。它**只用于**列表/面板显示与 `seshat:' 链接文本。
;; - **服务端身份（uid）**：由 `seshat-reader-annotation--uid' 经
;;   `GET /api/resolve' 从同一路径解析得到（按真实路径内存缓存），**只用于**
;;   所有发给服务端的实参（批注的创建/拉取、离线队列同步）。
;;
;; 判据：凡「发给服务端」的实参一律 uid，凡「写进 buffer / 链接 / 文案」的
;; 一律 doc-id。二者不可互换——服务端只认 uid，链接文本只认 doc-id。
;;
;; 位置（`location'）有**两种**形态（服务端只存不解析，故两者都无需后端改动）：
;;
;; 1. 单页形态 \"page:<n>;rect:<x0>,<y0>,<x1>,<y1>[;rect:...]\"：页码 `<n>' 为
;;    **1-based** 十进制整数，其后是零到多段 `rect:'（字级高亮按行展开，顺序
;;    即绘制顺序，段数上限见 `seshat-reader-annotation--anchor-max-segments'）。
;; 2. 跨页形态 \"pages:<a>-<b>;rect@<p>:<x0>,<y0>,<x1>,<y1>[;rect@<q>:...]\"：
;;    `<a>'/`<b>' 是实际有矩形的页号的最小/最大值（同为 1-based），每段矩形
;;    **自带页号**，因此同一条批注的几何可以落在不同页上。构造见
;;    `seshat-reader-annotation--anchor'，解析见
;;    `seshat-reader-annotation--pages-from-location' 与
;;    `seshat-reader-annotation--page-rects-from-location'。
;;
;; 向后兼容（**刻意如此，不要「修好」**）：旧解析器只认单页形态——页码入口
;; `--page-from-location' 只匹配 `page:'，矩形入口 `--rects-from-location' 只
;; 接受 `rect:' 前缀，于是旧客户端读到跨页形态时**整条跳过**该批注（页码为 nil
;; 即不参与装饰），既不会画错也不会报错；Android 的 `LocationCodec.parsePage'
;; 则落到 `Parsed.Unknown'（多 `rect:' 段今天已不支持）。因此**不要**让这两个
;; 旧入口接受新形态——那会把两页的矩形都画到第一页上（反向断言见
;; `seshat-reader-annotation-cross-page-location-test'）。
;;
;; 两种形态的矩形都是**页面坐标**（PDF point 空间、原点左上、y 向下），不含
;; 缩放与旋转，四个坐标各保留两位小数。
;;
;; 手写笔迹另用一条 location 形态 "page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,…"
;; （一笔一条批注，见 keystone 仓 `docs/api.md' §4.5.1）：解析入口是
;; `seshat-reader-annotation--ink-strokes-from-location'，它把串解析成
;; ((PAGE R G B ALPHA WIDTH POINTS TRUNCATED) …) 形式的 stroke 结构，**本
;; 模块不投喂也不渲染**——把 stroke 送进装饰表的渲染入口由后续任务（T5）
;; 消费本函数结果后实现。
;;
;; 服务端契约（端点、字段与错误码）见 keystone 仓 `docs/api.md'。
;;
;; 交互入口（键位加在 `seshat-reader-mode-map'）：
;;
;;   `C-c C-a'  `seshat-reader-annotation-create'
;;     把最近一次鼠标选区（`seshat-reader-select-last'）作为内容创建批注；
;;     带前缀参数（`C-u'）时在迷你缓冲区读取正文。创建成功后**不清除**
;;     选区，因此可对同一选区连续创建多条批注。
;;
;;   `C-c C-l'  `seshat-reader-annotation-toggle'
;;     批注列表面板开合：面板已显示则关闭，否则调
;;     `seshat-reader-annotation-list' 列出当前文档的批注，渲染到
;;     `*Seshat Annotations*'（页码 + 正文摘要）；列表缓冲区中 `RET' 跳页、
;;     `d' 删除、`q' 关面板。
;;
;; 列表缓冲区使用 `special-mode' 派生的内部 mode
;; `seshat-reader-annotation-list-mode'，`RET' 与 `d' 经其 local keymap
;; 用 `define-key' 绑定，不引入 evil 依赖。在 evil 环境下这两个键可能被
;; evil 接管（evil 会覆盖 `special-mode' 系的这两个键），需要用户在配置
;; 侧处理（真机验证由 M11.3 的 T11 覆盖）。

;;; Code:

(require 'url-util)
(require 'seshat-rest)
(require 'seshat-reader)
;; 信息面板承载体（`seshat-reader-sidebar'）为**零依赖**模块（只操作 buffer
;; 与 window，不 require 任何本项目模块），因此在此 require 它不会与
;; annotation 形成循环 require。
(require 'seshat-reader-sidebar)

;; 离线队列模块（`seshat-reader-annotation-queue'）在加载时会
;; `(require 'seshat-reader-annotation)'，因此本文件**不得**在顶部 require
;; 它（会形成循环 require）。改为在此声明其公开函数，并在真正需要时于函数
;; 体内 `require'——Emacs 会缓存 feature，重复 require 只是一次查表。
(declare-function seshat-reader-annotation-queue-enqueue "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-remove "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-count "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-entries "seshat-reader-annotation-queue")
(declare-function seshat-reader-annotation-queue-sync "seshat-reader-annotation-queue")

;; 关闭 evil 的 helper 定义在 `seshat-reader'（阅读 buffer 模块）中；本文件
;; 不 require 它（annotation 是阅读器的附属模块，反向 require 会形成循环），
;; 故此处声明签名以免字节编译告警。实际调用点只有
;; `seshat-reader-annotation-list-mode' 的 body——列表 buffer 只在阅读器流程
;; 中被创建，此时 `seshat-reader' 必已加载。
(declare-function seshat-reader--disable-evil "seshat-reader" ())

;; ETAF 渲染层是**软依赖**：本文件不在顶部 require 它（未安装 ETAF 时列表中
;; 的批注仍需可用），渲染入口在 `seshat-reader-annotation--render-list-etaf'
;; 内按需 `(require 'seshat-reader-etaf nil t)'。此处声明公开符号以避免字节
;; 编译告警。
(declare-function seshat-reader-etaf-available-p "seshat-reader-etaf" ())
(declare-function seshat-reader-etaf-render-annotations "seshat-reader-etaf"
                  (buffer items doc-id &optional source))
;; ETAF 已挂载判定用（`seshat-reader-annotation--etaf-mounted-p'）；同样只在
;; ETAF 已加载时才会被调用。
(declare-function etaf-runtime-for-buffer "etaf-runtime" (buffer-or-name))

(defvar seshat-reader-select-last nil
  "最近一次鼠标选区，正式定义与完整语义见 `seshat-reader-select'.
此处声明仅用于避免字节编译告警，并保证在 `seshat-reader-select' 尚未
加载时该变量仍有 nil 绑定，使 `seshat-reader-annotation-create' 的
“无选区”检查走 `user-error' 而不是 void-variable 崩溃。")

(defvar seshat-reader-select--flash-rects nil
  "当前缓冲区待闪现的选区矩形，正式定义与完整语义见 `seshat-reader-select'.
元素形如 (PAGE X0 Y0 X1 Y1)（PAGE 1-based、坐标为页面坐标）。此处声明仅用于
避免字节编译告警，并保证 `seshat-reader-select' 尚未加载时
`seshat-reader-annotation--redraw-highlights' 仍能安全读取（nil）。")

(defgroup seshat-reader-annotation nil
  "批注采集与侧车同步（seshat-reader 文档）."
  :group 'seshat-reader
  :prefix "seshat-reader-annotation-")

(defcustom seshat-reader-annotation-roots nil
  "已配置的文档根列表，用于把文件路径派生为批注用的 `document_id'.
每个元素形如 (标签 . 根目录)：标签是简短字符串，用于组成
`document_id' 的 \"<标签>:<相对路径>\"；根目录是书库目录的绝对路径
（可含 `~'，比较前经 `expand-file-name' 展开）。
文件命中某个根时取 \"<标签>:<相对路径>\"；多个根同时命中时取**最长
（最具体）的根**优先。
未命中任何已配置根的文档降级为 \"local:<绝对路径>\"，其批注只在本地
可见、不跨端共享。"
  :type '(alist :key-type (string :tag "根标签")
                :value-type (directory :tag "根目录"))
  :group 'seshat-reader-annotation)

(defvar seshat-reader-annotation--uid-cache nil
  "文件真实路径到服务端 uid 的内存缓存（alist，key 为 `file-truename'）.
只在当前 Emacs 进程内有效。uid 由服务端分配、跨改名稳定，故不做失效：
极端情形（服务端重建登记后 uid 变化）可手动
`(setq seshat-reader-annotation--uid-cache nil)' 清空。")

(defun seshat-reader-annotation--root-match (truename)
  "在 `seshat-reader-annotation-roots' 中为 TRUENAME 找最长匹配根.
TRUENAME 须为已归一的绝对真实路径（`file-truename'）。命中时返回
`(标签 . 根目录)'，根目录带末尾斜杠；多个根同时命中时取**最长（最具体）
的根**；未命中任何根时返回 nil。"
  (let ((best nil)
        (best-length -1))
    (dolist (entry seshat-reader-annotation-roots)
      (let* ((root (file-name-as-directory
                    (file-truename (expand-file-name (cdr entry)))))
             (length (length root)))
        (when (and (file-in-directory-p truename root)
                   (> length best-length))
          (setq best (cons (car entry) root)
                best-length length))))
    best))

(defun seshat-reader-annotation--quiet-p (file)
  "返回是否应对 FILE 的 doc-id 降级警告静音（**软依赖** `seshat-reading'）.
`seshat-reading'（项目层模块，负责「阅读模式 = 库身份 + 显式入库」）定义了
`seshat-reading-quiet-p'：它在 `seshat-reading-mode' 的 buffer 里返回 t，
让库外文档**不再每次**派生 doc-id 都 `message' 一条降级警告。

本模块对它是软依赖——`seshat-reading' 反向 `require' 了 `seshat-reader'，
硬依赖会成环；因此用 `fboundp' 探测 + `funcall'（不经字节编译器直接引用，
避免编译出「函数未定义」告警）。未加载 `seshat-reading' 时恒返回 nil，
即既有行为完全不变。"
  (and (fboundp 'seshat-reading-quiet-p)
       (funcall 'seshat-reading-quiet-p file)))

(defun seshat-reader-annotation--doc-id (file &optional quiet)
  "由文件路径 FILE 派生**显示用**的文档标识（doc-id）.
先把 FILE 归一化为绝对真实路径（`file-truename' 展开 `~'、相对路径与
符号链接），再依次与 `seshat-reader-annotation-roots' 中的每个根比较：
命中时返回 \"<标签>:<相对路径>\"，多个根命中时取**最长（最具体）的根**。
未命中任何根时把结果降级为 \"local:<绝对路径>\"，并 `message' 一条警告
提示该标识不跨端共享。

QUIET 非 nil 时**不**发那条降级警告（返回值不变，仍是 \"local:<绝对路径>\"）。
默认 nil 即保持既有行为；静音判定的来源见
`seshat-reader-annotation--quiet-p'（`seshat-reading-mode' 的 buffer 里
显式入库前的文档只靠 mode-line 标识，不刷回显区）。

FILE 为文档文件路径，可以是相对路径。返回值**只用于**列表/面板显示与
`seshat:' 链接文本；发给服务端的身份必须是 uid（见
`seshat-reader-annotation--uid'）。"
  (let* ((truename (file-truename (expand-file-name file)))
         (match (seshat-reader-annotation--root-match truename)))
    (if match
        (concat (car match) ":" (file-relative-name truename (cdr match)))
      (let ((fallback (concat "local:" truename)))
        (unless quiet
          (message "Seshat Reader annotation: %s 不在任何已配置的文档根内，降级为 %s（不跨端共享）"
                   truename fallback))
        fallback))))

(defun seshat-reader-annotation--uid (file)
  "由文件路径 FILE 解析服务端权威的文件 uid（**只用于** API 身份）.
先把 FILE 归一化为绝对真实路径（`file-truename'），命中
`seshat-reader-annotation--uid-cache' 时直接返回缓存值；未命中时按
`seshat-reader-annotation-roots' 找最长匹配根，拆出 (根标签 . 相对路径)，
再经 `seshat-rest-resolve-uid' 向服务端解析，成功则写入缓存并返回。

文件不在任何已配置根内，或服务端未登记该文档（resolve 返回 nil）时抛
`user-error' \"文档未在服务端登记：%s\"。失败结果**不写缓存**，下次调用
会重试。

显示与 `seshat:' 链接文本请用 `seshat-reader-annotation--doc-id'，不要把
本函数的返回值写进 buffer。"
  (let* ((truename (file-truename (expand-file-name file)))
         (cached (assoc truename seshat-reader-annotation--uid-cache)))
    (or (cdr cached)
        (let* ((match (seshat-reader-annotation--root-match truename))
               (uid (and match
                         (seshat-rest-resolve-uid
                          (car match)
                          (file-relative-name truename (cdr match))))))
          (unless (and (stringp uid) (not (string-empty-p uid)))
            (user-error "文档未在服务端登记：%s" file))
          (setq seshat-reader-annotation--uid-cache
                (cons (cons truename uid)
                      seshat-reader-annotation--uid-cache))
          uid))))

(defconst seshat-reader-annotation--anchor-max-segments 500
  "写入 location 时最多包含的 `rect:' 段数.
解析端的上限是 `seshat-reader-annotation--rect-max-segments'（2000 段），
写入端刻意取更小的 500，留出三倍余量：多段 location 是**写进服务端**的
不透明串，服务端只存不解析，一旦写入端产出超过解析端上限的串，超出的段在
解析时被静默丢弃（高亮看起来「缺一块」却毫无线索）。500 段 × 每段约 24 字符
仅约 12KB，也远低于 location 的 64KB 长度上限（`--location-max-length'）。
超出的段**丢弃**（只写前 500 段）：少画几段是可接受的降级，写一个会被截断
的超长串才是真问题。`character' 粒度下逐字符矩形可达数千条，本上限正是为
它准备的兜底。")

(defvar seshat-reader-annotation--anchor-truncation-warned nil
  "是否已就「矩形段数超出锚上限、已截断」提示过一次（避免刷屏）.
截断是**稳定状态**（同一选区反复创建批注都会命中），每次提示只会淹没回显
区，故只提示首次。用户可 `(setq seshat-reader-annotation--anchor-truncation-warned nil)'
复位。")

(defun seshat-reader-annotation--anchor-segment (rect page)
  "把单段 RECT 归一化为带页号的段 (PAGE X0 Y0 X1 Y1)；坏段返回 nil.
RECT 有两种合法形态：

- **带页号段** `(PAGE X0 Y0 X1 Y1)`：五元素、五个都是数字且**页号是整数**，
  页号取段内值，PAGE 参数不参与——跨页选区的 `:page-rects' 即此形态；
- **裸 rect** `(X0 Y0 X1 Y1)`：四元素且四个都是数字，页号用 PAGE 补齐；
  PAGE 为 nil 时返回 nil（没有页号可补，宁可不画也不猜页号）。

页号必须是**整数**：写入端后面用 `(format \"page:%d\" …)' /
`(format \"rect@%d:…\" …)' 渲染，浮点页号（1.0）会让 `%d' 抛
`wrong-type-argument' 打断整条批注的创建；解析端读回的页号也是 `[0-9]+'
口径的整数，两端必须一致。故 `(1.0 10 20 30 40)' 这类段按坏段处理（返回
nil，由调用方跳过），不猜也不取整。

长度大于 4 而第五个元素不是数字的形态按**裸 rect** 处理（前四个元素当坐标），
与改造前「只看 `(nth 0..3)'」的口径一致。坐标不做重排。"
  (when (consp rect)
    (let ((len (ignore-errors (length rect)))
          (coords-ok (and (numberp (nth 0 rect))
                          (numberp (nth 1 rect))
                          (numberp (nth 2 rect))
                          (numberp (nth 3 rect)))))
      (cond
       ;; 五元素且五个都是数字 = 带页号段：页号必须是整数（审查修复 F2）。
       ;; 浮点页号**不落回**下面的裸 rect 分支——那会让页号变成 x0、y1 被丢弃，
       ;; 正是五元组分支存在要防的确定性数据损坏。
       ((and (= len 5) coords-ok (numberp (nth 4 rect)))
        (when (integerp (nth 0 rect))
          (list (nth 0 rect) (nth 1 rect) (nth 2 rect)
                (nth 3 rect) (nth 4 rect))))
       ((and (>= (or len 0) 4) coords-ok (numberp page))
        (list page (nth 0 rect) (nth 1 rect) (nth 2 rect) (nth 3 rect)))
       (t nil)))))

(defun seshat-reader-annotation--anchor-segments (rects &optional page)
  "把 RECTS（单 rect 或 rect 列表）归一化为**带页号**的段列表.
返回 ((PAGE X0 Y0 X1 Y1) …)，每段都带页号；nil 返回 nil（页级锚）。单 rect
（首元素是数字）与 rect 列表靠首元素是否为数字区分，因此老调用点（
`seshat-reader-reference--current-location'、翻译面板）继续传单 rect 时行为
不变。每段的页号来源见 `seshat-reader-annotation--anchor-segment'：五元素段
用自身页号、四元素段用 PAGE 补齐。坏元素被跳过（不让一条坏数据毁掉整个锚），
顺序保持输入顺序。

**五元组分支是必须的**：改造前本函数只认「前四个元素都是数字」，于是
`(PAGE X0 Y0 X1 Y1)' 会被当成裸 rect（PAGE 变 x0、Y1 被丢弃），是确定性的
数据损坏（见 `seshat-reader-annotation--anchor' 的跨页形态）。"
  (cond
   ((null rects) nil)
   ((numberp (car rects))
    (let ((segment (seshat-reader-annotation--anchor-segment rects page)))
      (when segment (list segment))))
   (t (let (result)
        (dolist (rect rects)
          (let ((segment (seshat-reader-annotation--anchor-segment rect page)))
            (when segment (push segment result))))
        (nreverse result)))))

(defun seshat-reader-annotation--warn-anchor-truncated (count max)
  "提示一次「矩形段数超出锚上限，已截断」（COUNT 段只保留前 MAX 段）.
variable `inhibit-message' 在此被临时置 nil：这是**数据丢失**提示，不能在调用方
为了安静而抑制消息的上下文里（如 `seshat-reader-annotation--quiet-doc-id'
之类临时绑定的路径）被静默吞掉。"
  (unless seshat-reader-annotation--anchor-truncation-warned
    (setq seshat-reader-annotation--anchor-truncation-warned t)
    (let ((inhibit-message nil))
      (message
       "Seshat Reader annotation: 选区共 %d 段矩形，超出锚上限 %d 段，只写入前 %d 段"
       count max max))))

(defun seshat-reader-annotation--anchor-rect-segments (segments)
  "把带页号段 SEGMENTS 渲染为 `;rect:…' 尾串（不含页锚）；无段时为空串.
每段形如 (PAGE X0 Y0 X1 Y1)，坐标各保留两位小数（`%.2f'，与单段时代逐字
一致）；页号在这里**不输出**——单页形态的页信息由 `page:<n>' 页锚承载。"
  (mapconcat (lambda (segment)
               (format ";rect:%.2f,%.2f,%.2f,%.2f"
                       (nth 1 segment) (nth 2 segment)
                       (nth 3 segment) (nth 4 segment)))
             segments ""))

(defun seshat-reader-annotation--anchor-page-segments (segments)
  "把带页号段 SEGMENTS 渲染为 `;rect@<page>:…' 尾串（跨页形态）.
每段形如 (PAGE X0 Y0 X1 Y1)：页号输出为 1-based 十进制整数，坐标各保留
两位小数。段序由调用方按阅读顺序给好（本函数不重排）。"
  (mapconcat (lambda (segment)
               (format ";rect@%d:%.2f,%.2f,%.2f,%.2f"
                       (nth 0 segment) (nth 1 segment) (nth 2 segment)
                       (nth 3 segment) (nth 4 segment)))
             segments ""))

(defun seshat-reader-annotation--anchor-pages (segments)
  "返回带页号段 SEGMENTS 涉及的页号（去重、升序）；无段时返回 nil."
  (let ((pages (mapcar #'car segments)))
    (when pages
      (sort (delete-dups (copy-sequence pages)) #'<))))

(defun seshat-reader-annotation--anchor-degrades-p (segments)
  "SEGMENTS 跨页且「页数 + 段数」超出锚上限时返回 t（D7）.
跨页形态的串长由**页数**与**矩形段数**共同决定（每段都要带 `rect@<page>:'
前缀，比单页形态的 `rect:' 多出页号开销），故计数取二者之和；单页形态只按
段数计数，不适用本判定（见 `seshat-reader-annotation--anchor'）。"
  (let ((pages (seshat-reader-annotation--anchor-pages segments)))
    (and (cdr pages)
         (> (+ (length pages) (length segments))
            seshat-reader-annotation--anchor-max-segments))))

(defun seshat-reader-annotation--warn-anchor-degraded
    (pages segments max first-page kept)
  "提示「跨页锚超限已降级为首页矩形」.
PAGES 为选区涉及的页数、SEGMENTS 为段数、MAX 为锚上限、FIRST-PAGE 为降级
后保留的页号、KEPT 为实际写入的段数。走 `display-warning' 而非 `message'：
降级是**数据丢失**且确定发生（同一选区反复创建都会命中），进入
`*Warnings*' 才不会被后续回显冲掉、也便于事后追查。"
  (display-warning
   'seshat-reader-annotation
   (format
    (concat "跨页选区共 %d 页 %d 段矩形，超出锚上限 %d（页数 + 段数），"
            "已降级为只保留第 %d 页的 %d 段矩形")
    pages segments max first-page kept)
   :warning))

(defun seshat-reader-annotation--anchor (page rects)
  "由 PAGE 与 RECTS 构造批注**锚**；单页与跨页两种形态.
锚的第一段永远是**页信息**，其后是零到多个**几何段**（页级锚没有几何段，
见 `seshat-reader-reference--current-location' 的退化分支）；几何段只用于
渲染，不参与导航判定。

- **单页形态**（含同页多矩形）：
  \"page:<n>;rect:<x0>,<y0>,<x1>,<y1>[;rect:…]\"。页锚 `page:<n>' 是唯一
  跳转真值，多段正是字级高亮的落地形态（一行一段，解析端由
  `seshat-reader-annotation--rects-from-location' 逐段读回）。**与改造前
  逐字节一致**。
- **跨页形态**：
  \"pages:<a>-<b>;rect@<p>:x0,y0,x1,y1[;rect@<q>:…]\"。<a>/<b> 取实际有
  矩形的页号的**最小/最大值**，段按阅读顺序（页升序、页内原顺序），每段自带
  页号。旧客户端读到该形态会**整条跳过**（`--page-from-location' 只认
  `page:' 前缀、`--rects-from-location' 只认 `rect:' 前缀），因此不会画错，
  只是不画。

PAGE 为 **1-based 正整数**（起点页）；RECTS 可以是**单 rect**
（`(X0 Y0 X1 Y1)`，老调用点的形态），也可以是**rect 列表**；元素既可以是
裸 rect（用 PAGE 补页号），也可以是**带页号段** `(PAGE X0 Y0 X1 Y1)`（用
自身页号，见 `--anchor-segments'）。坐标单位是**页面坐标**（PDF point 空间、
原点左上、y 向下，不含缩放与旋转）。nil 时输出纯页锚 \"page:<n>\"。坐标各
保留两位小数；页码为 1-based 十进制整数。

**段数上限（D7）**：单页形态按段数计数，超过
`seshat-reader-annotation--anchor-max-segments' 时只写前 N 段并提示一次
（`--warn-anchor-truncated'）；跨页形态按「页数 + 段数」计数，超限时**降级**
为「只保留首页（页号最小的那一页）的矩形」，落成单页形态并
`display-warning' 提示——降级而非静默丢段，也不写出会被解析端截断的超长串。
降级时调用方（`seshat-reader-annotation-create'）须把正文同步截断到首页，
以免「正文含第二页、高亮只在第一页」。

**两种降级保留的页不同，勿混**：段数超限降级（D7，本函数）保留**页号最小的
那一页**（`pages:<a>-<b>' 的 a，因为降级目标是尽量多留有用的矩形，阅读顺序
从最小页号开始）；`seshat:' 引用链接降级（D5b，
`seshat-reader-reference--current-location'）保留**起点页**（`page:<起点页>'，
因为引用只需可复现的落点，而起点页才是用户按下的那一页）。两者语义不同且
各自自洽：反向拖拽（起点在较大页号那页）时前者仍取最小页号页、后者取起点页，
同一选区可能落到不同页——这是预期行为，不是缺陷。

PAGE 不是正整数时以 `user-error' 明确报错，不以 1 兜底。"
  (unless (and (integerp page) (> page 0))
    (user-error "Seshat Reader annotation: page 必须是正整数（1-based），实际为 %S"
                page))
  (let* ((segments (seshat-reader-annotation--anchor-segments rects page))
         (pages (seshat-reader-annotation--anchor-pages segments))
         (max seshat-reader-annotation--anchor-max-segments))
    (cond
     ;; 页级锚：无几何段
     ((null segments) (format "page:%d" page))
     ;; 单页形态（含同页多矩形）：旧形态，逐字节不变
     ((null (cdr pages))
      (let* ((count (length segments))
             (kept (if (> count max)
                       (butlast segments (- count max))
                     segments)))
        (when (> count max)
          (seshat-reader-annotation--warn-anchor-truncated count max))
        (concat (format "page:%d" (car pages))
                (seshat-reader-annotation--anchor-rect-segments kept))))
     ;; 跨页超限：降级为首页矩形（单页形态）+ display-warning
     ((seshat-reader-annotation--anchor-degrades-p segments)
      (let* ((first-page (car pages))
             (first-segments
              (let (kept)
                (dolist (segment segments)
                  (when (= (car segment) first-page)
                    (push segment kept)))
                (nreverse kept)))
             (count (length first-segments))
             (kept (if (> count max)
                       (butlast first-segments (- count max))
                     first-segments)))
        (seshat-reader-annotation--warn-anchor-degraded
         (length pages) (length segments) max first-page (length kept))
        (concat (format "page:%d" first-page)
                (seshat-reader-annotation--anchor-rect-segments kept))))
     ;; 跨页形态：段按页升序（页内保持原顺序）重排后输出
     (t
      (let (ordered)
        (dolist (current pages)
          (dolist (segment segments)
            (when (= (car segment) current)
              (push segment ordered))))
        (concat (format "pages:%d-%d" (car pages) (car (last pages)))
                (seshat-reader-annotation--anchor-page-segments
                 (nreverse ordered))))))))

(defun seshat-reader-annotation--selection-rects (selection)
  "取选区 SELECTION 中用于构造锚的矩形序列.
优先用 `:page-rects'——`seshat-reader-select-last' 的**逐页**几何，元素为
带页号的 `(PAGE X0 Y0 X1 Y1)'，是跨页选区的唯一真值；没有该字段（或为空）时
回落到 `:rects'（按行合并后的多段矩形，属**起点页**）；仍为 nil 时回落
`:rect'（整体 bbox，老版本选区与模块不报告逐字符矩形时只有它）；三者都没有
时返回 nil（锚退化为页级）。

单页选区下 `:page-rects' 每段的页号都等于 `:page'，且坐标与 `:rects' 逐值
相等，因此改取 `:page-rects' 后**单页锚的输出逐字节不变**（回归断言见
`seshat-reader-annotation-decoration-test'）。"
  (or (plist-get selection :page-rects)
      (plist-get selection :rects)
      (let ((rect (plist-get selection :rect)))
        (when rect (list rect)))))

(defun seshat-reader-annotation--selection-pages (selection)
  "返回选区 SELECTION 的几何涉及的页号（去重、升序）；无几何时返回 nil.
只读 `:page-rects'：这是「选区是否跨页」的**唯一判定信号**。`:rects' 与
`:rect' 都只描述起点页，单页多矩形时页号全同，故用本函数判定不会把单页选区
误判成跨页。"
  (let ((page-rects (plist-get selection :page-rects)))
    (when page-rects
      (sort (delete-dups (delq nil (mapcar #'car page-rects))) #'<))))

(defun seshat-reader-annotation--selection-cross-page-p (selection)
  "判断选区 SELECTION 是否**跨页**（`:page-rects' 去重页号多于一个）.
`seshat:' 引用链接的降级判定（D5b）与锚形态选择共用本函数，避免两处口径
漂移。无 `:page-rects'（老选区、无几何选区）时返回 nil。"
  (let ((pages (seshat-reader-annotation--selection-pages selection)))
    (and pages (cdr pages) t)))

(defun seshat-reader-annotation--first-page-text (page rects)
  "取 RECTS 中**页号最小**那一页的矩形包络内的文本；取不到时返回 nil.
供 D7 的跨页锚降级使用：锚降级为「只保留首页（页号最小的那一页）矩形」时，
正文必须同步截断到**同一页**，否则会出现「正文含第二页、高亮只在第一页」的
不一致。PAGE 是起点页（用于给裸 rect 补页号），RECTS 形同
`seshat-reader-annotation--anchor-segments' 的入参。

页号最小 ≠ 起点页：从第 3 页反向拖到第 1 页时起点页是 3 而首页是 1，因此本
函数按**段内页号**取首页，不读 `:page'。矩形包络取该页所有段的最小/最大
坐标，再经 `seshat-reader-dyn--text-in-rect'（0-based 页号）取文；模块不可
用、或该页没有段时返回 nil（调用方据此保留原正文）。"
  (let* ((segments (seshat-reader-annotation--anchor-segments rects page))
         (first (car (seshat-reader-annotation--anchor-pages segments))))
    (when (and first (fboundp 'seshat-reader-dyn--text-in-rect))
      (let (x0 y0 x1 y1)
        (dolist (segment segments)
          (when (= (car segment) first)
            (setq x0 (if x0 (min x0 (nth 1 segment)) (nth 1 segment))
                  y0 (if y0 (min y0 (nth 2 segment)) (nth 2 segment))
                  x1 (if x1 (max x1 (nth 3 segment)) (nth 3 segment))
                  y1 (if y1 (max y1 (nth 4 segment)) (nth 4 segment)))))
        (when x0
          (ignore-errors
            (seshat-reader-dyn--text-in-rect
             (1- first) x0 y0 x1 y1)))))))

;;; 离线队列接入

(defun seshat-reader-annotation--require-queue ()
  "按需加载离线队列模块并返回 t.
本文件不在顶部 `require' `seshat-reader-annotation-queue'（后者加载时会
`require' 本文件，顶部 require 会形成循环）；因此所有对队列模块公开函数
与选项的访问都先经本函数按需加载。`require' 对已加载 feature 只是一次
查表，开销可忽略。"
  (require 'seshat-reader-annotation-queue)
  t)

(defun seshat-reader-annotation--enqueue (entry what)
  "把一条批注操作 ENTRY 存入离线队列并提示待同步条数.
WHAT 是描述该操作的短语（如 \"批注\"、\"删除操作\"），用于拼出提示语
「WHAT已存入本地待同步队列（N 条待同步）」，其中 N 由
`seshat-reader-annotation-queue-count' 现算。提示语刻意只陈述「已本地暂存」
这一事实，不描述服务端状态（离线是预期路径，不是错误）。"
  (seshat-reader-annotation--require-queue)
  (seshat-reader-annotation-queue-enqueue entry)
  (message "Seshat Reader annotation: %s已存入本地待同步队列（%d 条待同步）"
           what (seshat-reader-annotation-queue-count)))

(defun seshat-reader-annotation--maybe-sync-queue ()
  "队列非空且启用自动同步时，机会性同步一次离线队列.
先按需加载队列模块，再在 `seshat-reader-annotation-queue-auto-sync' 非 nil
且 `seshat-reader-annotation-queue-count' 大于 0 时调用
`seshat-reader-annotation-queue-sync'。同步自身的网络失败已被其吞掉，此处
再用 `ignore-errors' 兜住队列文件损坏等异常，以免影响调用方的正常结果。"
  (seshat-reader-annotation--require-queue)
  (when (and (symbol-value 'seshat-reader-annotation-queue-auto-sync)
             (> (seshat-reader-annotation-queue-count) 0))
    (ignore-errors (seshat-reader-annotation-queue-sync))))

(defun seshat-reader-annotation--queued-create-entries (uid)
  "返回 UID 对应的文档在本地离线队列中待同步的 create 条目列表.
UID 为服务端权威身份（**不是**显示用 doc-id）。按需加载队列模块后取
`seshat-reader-annotation-queue-entries' 中 `:action' 为 `create' 的条目
（`delete' 条目没有可展示的位置与正文），保持入队顺序；没有匹配条目或
UID 为 nil 时返回 nil。"
  (seshat-reader-annotation--require-queue)
  (when uid
    (let (result)
      (dolist (entry (seshat-reader-annotation-queue-entries uid))
        (when (eq (plist-get entry :action) 'create)
          (push entry result)))
      (nreverse result))))

;;; 交互式采集

(defun seshat-reader-annotation-create (&optional body)
  "为最近一次鼠标选区创建一条服务端批注.
批注有两个**正交**维度：类型 `kind' 与备注 `text'（见
`seshat-reader-annotation--kind'）。本命令按 BODY 决定类型：

- BODY 为 nil 或去掉空白后为空串（含「不带前缀参数」的交互调用）→
  标记类：`kind' = \"highlight\"，`text' = 空串，`selected_text' = 选区文本；
- BODY 非空（`C-u' 输入了备注）→ 便签：`kind' = \"note\"，`text' = BODY，
  `selected_text' = 选区文本。

选区文本（`seshat-reader-select-last' 的 :text）为空白时**仍可创建**：只要
选区带几何（`:rects' 或仅有 `:rect'），就落成 `kind' = \"highlight\"、
`text' 为空串、`selected_text' 为 nil 的标记批注——扫描版 PDF 与无文本层
区域（图片、矢量图）没有字符可匹配，几何是唯一可用的锚
（`page:<n>;rect:...'）。只有**无任何几何**（`:rects' 与 `:rect' 皆为
nil）**且**无可用原文、也无 BODY 时才 `user-error'——空选区不落成页级锚
（`page:<n>` 只服务「有正文的页级批注」，见
`seshat-reader-annotation--anchor'）。列表显示用
`seshat-reader-annotation--display-text' 的回退链（text → selected_text →
ink 聚合），故高亮条目的标题就是选区原文。

交互调用：不带前缀参数时创建高亮，带前缀参数（`C-u'）时在迷你缓冲区读取
备注正文。

运行前置：必须先用鼠标拖拽选中页面区域（文本型 PDF 选中文字、扫描版 /
无文本层区域直接框住目标位置），使 `seshat-reader-select-last' 非 nil；该
变量在创建成功后**不会被清除**，因此可对同一选区连续创建多条批注（这是
有意的语义）。旋转页面上的选区已由 `seshat-reader-select-posn->page' 的
逆变换换算回页面空间（旋转页可以正常创建批注）。

锚的形态由选区是否跨页决定（见 `seshat-reader-annotation--anchor'）：单页
（含同页多矩形）写旧形态 `page:<n>;rect:…'，跨页写
`pages:<a>-<b>;rect@<p>:…'。跨页且「页数 + 段数」超出锚上限时锚降级为只
保留首页矩形，此时**正文也同步截断到首页**（取首页矩形包络内的文本），
以免出现「正文含第二页、高亮只在第一页」的不一致。

服务端返回含 `id' 的结果时 `message' 报告该 `id'，并在本地队列非空时
机会性地触发一次队列同步（同步失败不影响本次创建成功的结果）。服务端
不可用时**不**报错：把 `(:action create …)' 条目（含 `:kind' 与
`:selected-text'，重放时原样带上）存入本地离线队列，并 `message' 提示已
本地暂存及待同步条数，稍后由 `seshat-reader-annotation-queue-sync' 自动
同步到服务端。"
  (interactive (list (when current-prefix-arg (read-string "批注正文: "))))
  (let ((selection seshat-reader-select-last))
    (unless selection
      (user-error "Seshat Reader annotation: 尚无选区，请先用鼠标（down-mouse-1）拖拽选中页面文本"))
    (let ((file (plist-get selection :file)))
      (unless file
        (user-error "Seshat Reader annotation: 选区未记录文档文件，无法派生文档标识"))
      (let* ((page (plist-get selection :page))
             ;; 字级高亮：优先 `:page-rects'（逐页、带页号），无则回落
             ;; `:rects' / `:rect'（起点页内的多段 / 整体 bbox）。
             (rects (seshat-reader-annotation--selection-rects selection))
             ;; D7：跨页锚按「页数 + 段数」超限时会降级为只保留首页矩形，
             ;; 正文必须同步截断到首页，否则出现「正文含第二页、高亮只在
             ;; 第一页」的不一致（`--anchor' 用的是同一个判定函数）。
             (degraded
              (seshat-reader-annotation--anchor-degrades-p
               (seshat-reader-annotation--anchor-segments rects page)))
             (selection-text (plist-get selection :text))
             (selected (when (and (stringp selection-text)
                                  (not (string-empty-p (string-trim selection-text))))
                         (if degraded
                             (or (seshat-reader-annotation--first-page-text
                                  page rects)
                                 selection-text)
                           selection-text)))
             (note (when (and (stringp body)
                              (not (string-empty-p (string-trim body))))
                     body))
             (kind (if note "note" "highlight"))
             (text (or note ""))
             (document-id (seshat-reader-annotation--doc-id
                           file (seshat-reader-annotation--quiet-p file))))
        ;; 空选区守卫：只在「无任何几何（`:rects' 与 `:rect' 皆 nil）且无文本、
        ;; 无备注」时报错。**有几何但取不到文本是合法情形**——扫描版 PDF 与无
        ;; 文本层区域（图片、矢量图）没有任何字符可匹配，`--selection-rects' 会
        ;; 回落 `:rect' 的单段 bbox，锚即 `page:<n>;rect:...`（`kind` 仍为
        ;; `highlight`、`text` 为空、`selected_text` 为 nil），也就是「框住什么
        ;; 就标记什么」。`--anchor' 的 nil→「page:<n>」是给「有正文的页级锚」
        ;; 准备的合法退化（如翻译面板只给页码），不该被「什么都没选中」借用——
        ;; 否则一次空选区会静默产生一条只有页码、既无几何也无原文的批注。
        (when (and (null rects) (null selected) (null note))
          (user-error "Seshat Reader annotation: 尚未选中任何文本（选区没有文本与几何），可先用 C-u 输入批注正文"))
        ;; 服务端身份在正文校验之后再解析：未登记时 `user-error' 直接冒泡给
        ;; 用户（服务端权威 uid 无法离线生成）。
        (let* ((location (seshat-reader-annotation--anchor page rects))
               (uid (seshat-reader-annotation--uid file))
               (entry (list :action 'create
                            :uid uid
                            :document-id document-id
                            :location location
                            :kind kind
                            :selected-text selected
                            :text text)))
          (condition-case nil
              (let ((response (seshat-rest-create-annotation
                               uid location text kind selected)))
                (if (and (listp response) (alist-get 'id response))
                    (progn
                      (message "Seshat Reader annotation: 已创建批注 %s（%s，%s）"
                               (format "%s" (alist-get 'id response))
                               document-id location)
                      ;; 已在服务端落地：若列表缓存属于本文档，增量追加该条并
                      ;; 重投页面高亮（不发请求、不重渲染列表）。
                      (seshat-reader-annotation--note-created-annotation
                       file (alist-get 'id response) location text
                       kind selected)
                      ;; 机会性同步：服务端此刻可达，顺手把积压的本地队列推进一次。
                      (seshat-reader-annotation--require-queue)
                      (when (> (seshat-reader-annotation-queue-count) 0)
                        (ignore-errors (seshat-reader-annotation-queue-sync))))
                  (seshat-reader-annotation--enqueue entry "批注")))
            (error
             (seshat-reader-annotation--enqueue entry "批注"))))))))


;;; 列表与删除

(defconst seshat-reader-annotation-list-buffer-name "*Seshat Annotations*"
  "批注列表缓冲区名称.")

(defconst seshat-reader-annotation-list-summary-width 60
  "批注列表中正文摘要的最大字符数，超出部分以 \"…\" 截断.")

(defconst seshat-reader-annotation--fetch-error 'seshat-reader-annotation--fetch-error
  "`seshat-reader-annotation--fetch' 在拉取失败时返回的哨兵值.")

(defvar-local seshat-reader-annotation-list-document-id nil
  "列表缓冲区所展示批注的**显示标识（doc-id）**.
形如 \"<标签>:<相对路径>\"，只用于列表显示与 `seshat:' 链接文本（
`seshat-reader-reference' 只读本变量）。刷新/删除等 API 操作不得使用它，
而应用 `seshat-reader-annotation-list-uid'。")

(defvar-local seshat-reader-annotation-list-uid nil
  "列表缓冲区所展示批注的**服务端身份（uid）**.
供列表刷新（`g'）与删除路径发请求使用；显示与 `seshat:' 链接文本仍用
`seshat-reader-annotation-list-document-id'（doc-id）。")

(defvar-local seshat-reader-annotation-list-source nil
  "发起列表的 seshat-reader 文档缓冲区，供 `RET' 跳页使用.")

(defvar-local seshat-reader-annotation-list-entries nil
  "列表缓冲区最近一次渲染的服务端批注列表（仅内存缓存）.
`seshat-reader-annotation-list-delete' 在取消本地待同步批注后重渲染列表时
复用本缓存，从而无需再次拉取服务端（即不发起任何 HTTP）。")

(defun seshat-reader-annotation--page-from-location (location)
  "从 LOCATION 中解析 **1-based** 页码；解析失败时返回 nil.
LOCATION 的约定为 \"page:<n>;rect:...\"，其中 <n> 为 1-based 十进制
整数；本函数用正则 `page:\\([0-9]+\\)' 提取该整数。"
  (when (and (stringp location)
             (string-match "page:\\([0-9]+\\)" location))
    (string-to-number (match-string 1 location))))

(defun seshat-reader-annotation--chapter-from-location (location)
  "从 LOCATION 解析 EPUB 章节序号；解析失败时返回 nil.
支持 v8 契约的 \"chapter:<spine>@<start>-<end>\" 与更早的旧形态
\"chapter-<n>\"；返回的序号原样取自字符串（不做 +1/-1 换算，仅用于显示）。
\"page:<n>\" 形态不属于本函数职责，返回 nil（页码由
`seshat-reader-annotation--page-from-location' 负责）。

本函数只做解析，不抛错：location 为 nil、非字符串或其他形态时一律返回
nil，调用方据此决定是否展示「章节 N」而不是空白或错误页码。"
  (when (stringp location)
    (cond
     ((string-match "\\`chapter:\\([0-9]+\\)" location)
      (string-to-number (match-string 1 location)))
     ((string-match "\\`chapter-\\([0-9]+\\)\\'" location)
      (string-to-number (match-string 1 location)))
     (t nil))))

(defun seshat-reader-annotation--item-field (item field)
  "取条目 ITEM 中名为 FIELD（**不带**冒号的符号）的字段值；缺失时返回 nil.
ITEM 既可以是服务端返回的 alist（键为符号，如 `location'），也可以是渲染
层使用的 plist（键为 `:location'）：两种形态对同名字段返回同一个值，故
本函数是纯文本渲染与 ETAF 渲染两条路径共用的取字段入口。"
  (let ((plist-key (intern (concat ":" (symbol-name field)))))
    (cond
     ((not (listp item)) nil)
     ((plist-member item plist-key) (plist-get item plist-key))
     ((assq field item) (cdr (assq field item)))
     (t nil))))

(defun seshat-reader-annotation--kind (item)
  "返回条目 ITEM 的批注类型字符串，缺键或空值时视为 \"note\".
v8 契约的服务端响应带 `kind' 字段（`note' / `highlight' / `ink'）；
老服务端与 M12 之前的存量记录没有该字段，此时返回 \"note\"，从而既有字段
解析与显示行为与改动前完全一致。ITEM 可为 alist 或 plist（见
`seshat-reader-annotation--item-field'）。"
  (let ((kind (seshat-reader-annotation--item-field item 'kind)))
    (if (and (stringp kind) (not (string-empty-p kind)))
        kind
      "note")))

(defun seshat-reader-annotation--selected-text (item)
  "返回条目 ITEM 的选中原文（v8 字段 `selected_text'）.
缺键、非字符串时返回 nil；空串原样返回（调用方按「无可用原文」处理），
因此老记录不会因该字段缺失而改变任何既有行为。

服务端 alist 的键是 `selected_text'（JSON 原名），渲染层 plist 的键是
`:selected-text'（Emacs 风格），两种形态都识别——否则 ETAF 路径拿到的
选中原文永远是 nil。"
  (cond
   ((not (listp item)) nil)
   ((plist-member item :selected-text)
    (let ((selected (plist-get item :selected-text)))
      (and (stringp selected) selected)))
   (t
    (let ((selected (or (cdr (assq 'selected_text item))
                        (cdr (assq 'selected-text item)))))
      (and (stringp selected) selected)))))

(defun seshat-reader-annotation--ink-page (item)
  "返回 ink 条目 ITEM 的 **1-based** 页码；取不到时返回 nil.
优先用已解析好的 `page' 字段，否则从 `location' 的 \"page:<n>;ink:...\"
前缀解析（与 rect 批注共用 `seshat-reader-annotation--page-from-location'）。"
  (or (seshat-reader-annotation--item-field item 'page)
      (seshat-reader-annotation--page-from-location
       (seshat-reader-annotation--item-field item 'location))))

(defun seshat-reader-annotation--ink-label (item)
  "返回 ink 条目 ITEM 的聚合文案（形如 \"第 3 页手写（2 笔）\"）.
页码取 `seshat-reader-annotation--ink-page'，无法解析时退化为
\"手写（N 笔）\"；笔数取 `ink-count' 字段，缺省按 1 笔计。"
  (let* ((page (seshat-reader-annotation--ink-page item))
         (count (let ((n (seshat-reader-annotation--item-field item 'ink-count)))
                  (if (integerp n) n 1))))
    (if page
        (format "第 %s 页手写（%d 笔）" page count)
      (format "手写（%d 笔）" count))))

(defun seshat-reader-annotation--display-text (item)
  "返回条目 ITEM 在批注列表中应显示的**原始**文本（未压缩、未截断）.
回退链：`text' 非空白 → `text'；否则 `selected_text' 非空白 →
`selected_text'；否则 `kind' 为 \"ink\" 时返回聚合文案（见
`seshat-reader-annotation--ink-label'）；都不满足时返回空串（不抛错）。
压缩与截断仍由 `seshat-reader-annotation--summary' 负责。"
  (let ((text (seshat-reader-annotation--item-field item 'text))
        (selected (seshat-reader-annotation--selected-text item)))
    (cond
     ((and (stringp text) (not (string-empty-p (string-trim text)))) text)
     ((and (stringp selected)
           (not (string-empty-p (string-trim selected))))
      selected)
     ((equal (seshat-reader-annotation--kind item) "ink")
      (seshat-reader-annotation--ink-label item))
     (t ""))))

(defun seshat-reader-annotation--ink-aggregate-item (page entries)
  "把同一页的 ink 条目 ENTRIES 合并为一条聚合条目 plist.
PAGE 为 **1-based** 页码（可为 nil）。聚合条目保留 `:ink-ids'（各笔的服务端
id，供调试与将来按笔删除）与 `:ink-count'（笔数）；`:id' / `:uuid' 恒为
nil——它不对应服务端的单条记录。`:key' 是合成键（\"ink-page:<n>\"），让
ETAF 路径仍能选中该行并据 `:page' 跳页。"
  (list :id nil
        :uuid nil
        :key (format "ink-page:%s" page)
        :location (seshat-reader-annotation--item-field (car entries) 'location)
        :page page
        :text ""
        :dirty nil
        :kind "ink"
        :ink-count (length entries)
        :ink-ids (delq nil
                       (mapcar (lambda (entry)
                                 (seshat-reader-annotation--item-field
                                  entry 'id))
                               entries))
        :aggregate t))

(defun seshat-reader-annotation--group-ink-items (items)
  "把 ITEMS 中同一页的 `ink' 条目按页聚合为一条汇总行，返回新列表.
聚合行出现在该页**首个** ink 条目的原位置，其余条目相对顺序不变（服务端
项在前、本地待同步项在后的既有顺序因此得以保留）。页码解析不出的 ink 条目
全部并入同一条无页码的汇总行。非 ink 条目原样返回（同一个 cons 对象）。
ITEMS 为 nil 时返回 nil；本函数不修改 ITEMS。"
  (let ((by-page (make-hash-table :test #'equal))
        (emitted (make-hash-table :test #'equal))
        result)
    (dolist (item items)
      (when (equal (seshat-reader-annotation--kind item) "ink")
        (let ((page (seshat-reader-annotation--ink-page item)))
          (puthash page (append (gethash page by-page) (list item)) by-page))))
    (dolist (item items)
      (if (not (equal (seshat-reader-annotation--kind item) "ink"))
          (push item result)
        (let ((page (seshat-reader-annotation--ink-page item)))
          (unless (gethash page emitted)
            (puthash page t emitted)
            (push (seshat-reader-annotation--ink-aggregate-item
                   page (gethash page by-page))
                  result)))))
    (nreverse result)))

(defun seshat-reader-annotation--summary (text)
  "把 TEXT 压缩为单行摘要，超过配置宽度时以 \"…\" 截断.
TEXT 中的换行、回车与制表符被替换为空格；TEXT 为 nil 时返回空串。"
  (let* ((flat (if (stringp text)
                   (replace-regexp-in-string "[\n\r\t]+" " " text)
                 ""))
         (trimmed (string-trim flat)))
    (if (> (length trimmed) seshat-reader-annotation-list-summary-width)
        (concat (substring trimmed 0 seshat-reader-annotation-list-summary-width) "…")
      trimmed)))

(defun seshat-reader-annotation--insert-entry (annotation &optional queued-uuid)
  "把一条批注 ANNOTATION 插入当前缓冲区的一行.
ANNOTATION 为服务端返回的 alist 或渲染层的 plist，含 `id'、`location'、
`text' 等字段（v8 契约还可能带 `kind' 与 `selected_text'）。
该行以 **1-based** 页码开头；location 为跨页形态 `pages:<a>-<b>' 时显示
\"a-b\"（跳转仍落首页 A，见行属性 `seshat-reader-annotation-page'）；location
为 EPUB 的 `chapter:' 形态时改以 \"章节 N\" 开头；都解析不出时显示 \"?\" 并在
行尾标注。页码/章节之后是
摘要，取 `seshat-reader-annotation--display-text' 的回退链（备注优先，其次
选中原文，ink 条目走聚合文案）；整行携带 `seshat-reader-annotation-id'、
`seshat-reader-annotation-page' 与 `seshat-reader-annotation-location'
三个文本属性，供 `RET' 与 `d' 使用。

QUEUED-UUID 非 nil 时表示该条来自本地离线队列、尚未同步到服务端：行尾
追加 \"[待同步]\" 标记，且该行携带值为 QUEUED-UUID 的
`seshat-reader-annotation-queue-uuid' 文本属性。服务端返回的批注调用本
函数时不传 QUEUED-UUID，该属性因此为 nil，供
`seshat-reader-annotation-list-delete' 区分「取消本地条目」与「删除服务端
批注」两条路径。"
  (let* ((id (seshat-reader-annotation--item-field annotation 'id))
         (location (seshat-reader-annotation--item-field annotation 'location))
         ;; 跳转页号：旧形态取 `page:<n>'，跨页形态取 `pages:<a>-<b>' 的首页 A。
         (page (seshat-reader-annotation--location-page location))
         ;; 显示页码：旧形态是数字页号，跨页形态是 "a-b"。
         (page-label (seshat-reader-annotation--page-label location))
         (chapter (and (null page)
                       (seshat-reader-annotation--chapter-from-location location)))
         (label (cond (page-label page-label)
                      (chapter (format "章节 %s" chapter))
                      (t "?")))
         (start (point))
         (summary (seshat-reader-annotation--summary
                   (seshat-reader-annotation--display-text annotation))))
    (insert (format "  %5s  %s%s%s\n"
                    label
                    (if (string-empty-p summary) "（无正文）" summary)
                    (if (or page-label chapter) ""
                      "  [无法从 location 解析页码]")
                    (if queued-uuid "  [待同步]" "")))
    (add-text-properties start (point)
                         (list 'seshat-reader-annotation-id id
                               'seshat-reader-annotation-page page
                               'seshat-reader-annotation-queue-uuid queued-uuid
                               'seshat-reader-annotation-location location))))

(defun seshat-reader-annotation--fetch (uid)
  "拉取 UID 的批注列表，失败时提示并返回失败哨兵.
UID 为服务端权威身份（**不是** doc-id）。本函数直接查 HTTP 状态码，因此
非 2xx 与「真正无批注」不会混为一谈：2xx 时用 `seshat-rest--json' 解析
响应并返回批注列表（无批注为 nil，属合法结果，由调用方渲染为提示行）；
HTTP 非 2xx（如 401 鉴权失败、400 uid 非法、500 服务端错误）时 `message'
一条**含状态码**的提示，并返回
`seshat-reader-annotation--fetch-error'。服务端不可用、网络失败或响应
无法解析等异常情形同样 `message' 提示并返回该哨兵。哨兵只用于让调用
方跳过渲染、保留既有列表，绝不把异常冒泡成 backtrace。"
  (condition-case err
      (let* ((response (seshat-rest--request
                        "GET"
                        (format "/api/annotations?uid=%s"
                                (url-hexify-string uid))))
             (status (car response)))
        (if (and (integerp status) (>= status 200) (< status 300))
            (seshat-rest--json response)
          (message "Seshat Reader annotation: 拉取批注列表失败（HTTP %s）"
                   status)
          seshat-reader-annotation--fetch-error))
    (error
     (message "Seshat Reader annotation: 拉取批注列表失败（请求失败或响应异常）：%s"
              (error-message-string err))
     seshat-reader-annotation--fetch-error)))

;;; 页面高亮同步（C 层 rect 高亮）

;; 五个模块函数由动态模块提供（render/render-core.c），elisp 侧只声明签名，
;; 以免字节编译告警「not known to be defined」。声明不改变运行时行为。
(declare-function seshat-reader-dyn--add-highlight "seshat-render-core"
                  (page x0 y0 x1 y1))
(declare-function seshat-reader-dyn--add-decoration "seshat-render-core"
                  (page x0 y0 x1 y1 r g b alpha))
(declare-function seshat-reader-dyn--add-stroke "seshat-render-core"
                  (page r g b alpha width points))
(declare-function seshat-reader-dyn--clear-highlights "seshat-render-core" ())

(declare-function seshat-reader-dyn--text-in-rect
                  "seshat-render-core" (page x0 y0 x1 y1))

(defcustom seshat-reader-annotation-highlight-enabled t
  "是否把批注 location 中的 `rect:' 段绘制为页面高亮.
非 nil 时 `seshat-reader-annotation--redraw-highlights' 把解析出的批注矩形
逐条交给动态模块，绘制成半透明高亮；为 nil 时批注矩形一个都不投（只清空
已有高亮并重绘），从而关闭批注高亮显示。

本开关**只管批注高亮**：框选松手后的闪现高亮（
`seshat-reader-select-flash-duration' /
`seshat-reader-select--flash-selection'）不受它约束，关闭批注高亮时闪现
仍然可见。"
  :type 'boolean
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-ink-enabled t
  "是否把批注 location 中的 `ink:' 段绘制为页面手写笔迹.
非 nil（默认）时 `seshat-reader-annotation--redraw-highlights' 把解析出的
笔迹逐条交给动态模块的 stroke 入口，按原色/透明度/线宽画出；为 nil 时一条
笔迹都不投，页面只剩 rect 类装饰。

本开关**只控 ink 笔迹渲染**：`rect:' 段（highlight / underline / strikeout）
是否绘制仍由 `seshat-reader-annotation-highlight-enabled' 决定，两者互不
影响；框选闪现（`seshat-reader-select--flash-selection'）与搜索命中（
`seshat-reader-search'）同样不受本开关约束——它们不来自批注 location 里的
`ink:' 段。"
  :type 'boolean
  :group 'seshat-reader-annotation)

(defun seshat-reader-annotation--quiet-doc-id (file)
  "安静地求 FILE 的显示标识（doc-id）；FILE 不是字符串时返回 nil.
与 `seshat-reader-annotation--doc-id' 是同一套派生规则，只是临时抑制其
「降级为 local:」的 `message'，供高亮同步这类只做**比对**的场景复用，
避免每次重绘都往回显区刷一条提示。"
  (when (stringp file)
    (let ((inhibit-message t))
      (seshat-reader-annotation--doc-id file))))

(defun seshat-reader-annotation--parse-coordinate (field)
  "把坐标字段 FIELD 解析为浮点数；不是合法数字时返回 nil.
合法形态是十进制数（可带正负号、小数点与指数），字段两端允许空白；
\"abc\"、空串等一律返回 nil，绝不以 0 兜底（否则非法坐标会被画到
页角）。"
  (when (and (stringp field)
             (string-match-p
              (concat "\\`[ \t]*\\(?:-?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?"
                      "\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\)[ \t]*\\'")
              field))
    (float (string-to-number (string-trim field)))))

(defun seshat-reader-annotation--rect-from-segment (segment)
  "把单个 \"rect:\" 段 SEGMENT 解析为 (X0 Y0 X1 Y1)，失败时返回 nil.
SEGMENT 须以 \"rect:\" 开头且其后为四个逗号分隔的数字。下列情形返回
nil：字段数不为 4、任一字段不是数字、X1 小于 X0 或 Y1 小于 Y0（负面积
矩形无法绘制）。"
  (when (and (stringp segment)
             (string-prefix-p "rect:" segment))
    (let* ((fields (split-string (substring segment (length "rect:")) "," nil))
           (coords (mapcar #'seshat-reader-annotation--parse-coordinate fields))
           (x0 (nth 0 coords))
           (y0 (nth 1 coords))
           (x1 (nth 2 coords))
           (y1 (nth 3 coords)))
      (when (and (= (length fields) 4)
                 (not (memq nil coords))
                 (<= x0 x1)
                 (<= y0 y1))
        (list x0 y0 x1 y1)))))

(defconst seshat-reader-annotation--location-max-length 65536
  "解析 location 时接受的最大字符数（超出部分截断丢弃）.
LOCATION 来自**不可信的服务端响应**：恶意或有缺陷的服务端可能返回数百万
字符的 location，`split-string' 会一次产出上万段，把一次重绘变成 CPU 与
内存的放大攻击。故解析前先截断到本上限，**截断后仍解析前面合法的段**
（不整体放弃）；正常 location 只有几十字符，不受影响。")

(defconst seshat-reader-annotation--rect-max-segments 2000
  "解析 location 时最多处理的 `rect:' 段数.
超过本上限即**停止解析**并保留已解析出的矩形——同样是为了给不可信的服务端
响应一个有界的工作量上界（每段解析都要做正则与浮点转换）。正常批注的
location 至多几段 `rect:'，2000 段已远超实际需要。")

(defun seshat-reader-annotation--rects-from-location (location)
  "从 LOCATION 中解析出全部可用的 `rect:' 矩形，返回 rect 列表.
LOCATION 的约定形态是 \"page:<n>;rect:<x0>,<y0>,<x1>,<y1>\"；按 \";\"
切段后**只**处理以 \"rect:\" 开头的段，出现多个 \"rect:\" 段时逐个解析，
顺序与 LOCATION 中一致。每段的四个坐标须为数字且 X0<=X1、Y0<=Y1
（负面积矩形跳过），任一条件不满足即跳过该段。\"ink:\"（手写笔迹）段
**本期不解析、不渲染**，只在 tech-debt 记录。全部段都不可用时返回 nil，
否则返回 ((X0 Y0 X1 Y1) …) 形式的列表，坐标为浮点数，单位与页面坐标系
一致（见 `seshat-reader-annotation--anchor'）。

LOCATION 来自不可信的服务端响应，故解析**有界**：长度先按
`seshat-reader-annotation--location-max-length' 截断（截断后仍解析前面合法
的段），解析出的 `rect:' 段数达到
`seshat-reader-annotation--rect-max-segments' 即停止（保留已解析的）。"
  (when (stringp location)
    (let* ((limit seshat-reader-annotation--location-max-length)
           (text (if (> (length location) limit)
                     (substring location 0 limit)
                   location))
           (rest (split-string text ";"))
           (rects nil)
           (count 0))
      ;; 用 while 而非 dolist：达到段数上限后不再继续尝试解析后续段。
      (while (and rest (< count seshat-reader-annotation--rect-max-segments))
        (let ((rect (seshat-reader-annotation--rect-from-segment
                     (string-trim (car rest)))))
          (when rect
            (push rect rects)
            (setq count (1+ count))))
        (setq rest (cdr rest)))
      (nreverse rects))))

(defun seshat-reader-annotation--pages-from-location (location)
  "从 LOCATION 解析跨页形态的页跨度 `pages:<a>-<b>'，返回 (A B)；否则 nil.
严格匹配：串**开头**即 `pages:'，其后为十进制 <a>、连字符、十进制 <b>，且
紧跟 `;' 或串尾——锚点 `\\=' 与 `\\'' 是刻意加的，否则
\"xpages:1-2;…\" 之类的畸形串会被误认成跨页锚。A/B 为 1-based 页码（与
`page:<n>' 同域）。

旧形态 \"page:<n>;rect:…\"、EPUB 的 \"chapter:…\" 与任何未知形态一律返回
nil。**本函数不改变 `seshat-reader-annotation--page-from-location' 的语义**
——后者对新形态继续返回 nil，旧客户端的「整条跳过」行为（F8）依赖这一点。"
  (when (and (stringp location)
             (string-match
              "\\`pages:\\([0-9]+\\)-\\([0-9]+\\)\\(?:;\\|\\'\\)" location))
    (list (string-to-number (match-string 1 location))
          (string-to-number (match-string 2 location)))))

(defun seshat-reader-annotation--page-rect-from-segment (segment)
  "把单个 \"rect@<page>:\" 段 SEGMENT 解析为 (PAGE X0 Y0 X1 Y1)；失败时 nil.
SEGMENT 须以 \"rect@<page>:\" 开头（<page> 为 1-based 十进制、须为正），
其后为四个逗号分隔的数字。字段级校验**复用**既有口径：拼成 \"rect:...\" 后
交给 `seshat-reader-annotation--rect-from-segment'，因此字段数、数字性、
负面积三条判定与旧形态逐条一致（非法即丢该段，不抛错）。"
  (when (and (stringp segment)
             (string-match "\\`rect@\\([0-9]+\\):" segment))
    (let ((page (string-to-number (match-string 1 segment)))
          (rect (seshat-reader-annotation--rect-from-segment
                 (concat "rect:" (substring segment (match-end 0))))))
      (when (and (> page 0) rect)
        (cons page rect)))))

(defun seshat-reader-annotation--page-rects-from-location (location)
  "从 LOCATION 解析跨页形态的**带页号**矩形，返回 ((PAGE X0 Y0 X1 Y1) …).
按 \";\" 切段后**只**处理以 \"rect@<page>:\" 开头的段（旧形态的 \"rect:\"
段因此被忽略，旧 location 一律得到 nil），顺序与串内一致。每段的校验见
`seshat-reader-annotation--page-rect-from-segment'：任一条件不满足即跳过该
段，不抛错。

LOCATION 来自不可信的服务端响应，故解析**有界**，与
`seshat-reader-annotation--rects-from-location' 同口径：长度先按
`seshat-reader-annotation--location-max-length' 截断（截断后仍解析前面合法
的段），解析出的段数达到 `seshat-reader-annotation--rect-max-segments' 即
停止（保留已解析的）。"
  (when (stringp location)
    (let* ((limit seshat-reader-annotation--location-max-length)
           (text (if (> (length location) limit)
                     (substring location 0 limit)
                   location))
           (rest (split-string text ";"))
           (rects nil)
           (count 0))
      ;; 用 while 而非 dolist：达到段数上限后不再继续尝试解析后续段。
      (while (and rest (< count seshat-reader-annotation--rect-max-segments))
        (let ((rect (seshat-reader-annotation--page-rect-from-segment
                     (string-trim (car rest)))))
          (when rect
            (push rect rects)
            (setq count (1+ count))))
        (setq rest (cdr rest)))
      (nreverse rects))))

(defun seshat-reader-annotation--page-label (location)
  "返回 LOCATION 的**显示用**页码串；两种形态都识别，取不到时 nil.
旧形态（及任何含 `page:<n>' 的串）返回十进制页号字符串；跨页形态
`pages:<a>-<b>' 返回 \"<a>-<b>\"。列表与 ETAF 卡片用它显示 \"1-2\"，跳转
仍用 `seshat-reader-annotation--page-from-location' 给的首个页号。"
  (let ((page (seshat-reader-annotation--page-from-location location)))
    (cond
     (page (number-to-string page))
     (t (let ((span (seshat-reader-annotation--pages-from-location location)))
          (when span (format "%d-%d" (car span) (cadr span))))))))

(defun seshat-reader-annotation--page-span-label (location)
  "返回 LOCATION 的显示用**页跨度** \"<a>-<b>\"；非跨页形态时返回 nil.
与 `seshat-reader-annotation--page-label' 的区别：后者对旧形态也返回十进制
页号（供文本列表的行首页码用），本函数**只**为跨页形态产出跨度串，因此
`--etaf-items' 的 `:page-label' 在旧形态下是 nil——消费方继续用 `:page'。"
  (let ((span (seshat-reader-annotation--pages-from-location location)))
    (when span (format "%d-%d" (car span) (cadr span)))))

(defun seshat-reader-annotation--location-page (location)
  "返回 LOCATION 的**1-based 跳转页号**：跨页形态取首页 A；否则 nil.
旧形态走 `seshat-reader-annotation--page-from-location'（语义不变）；跨页
形态取 `pages:<a>-<b>' 的 A——批注列表里的 `RET' 与 ETAF 卡片的跳转都落到
首页，与 `seshat-reader-annotation--page-label' 的 \"a-b\" 显示一致。"
  (or (seshat-reader-annotation--page-from-location location)
      (car (seshat-reader-annotation--pages-from-location location))))

(defconst seshat-reader-annotation--ink-max-points 1024
  "单笔手写笔迹最多保留的点数（与 C 侧 `DECORATION_MAX_POINTS' 一致）.
超出本上限的笔迹**截断**为前 N 个点并把解析结果的 TRUNCATED 置 t，而不是
丢掉整笔：异常长的笔迹（上万点）会拖慢每一次重绘，但整笔丢弃等于用户的手写
凭空消失，削短并留标记才是可解释的降级。正常一笔只有几十到几百点，不受
影响。")

(defun seshat-reader-annotation--ink-color-from-hex (color)
  "把 \"#AARRGGBB\" 形态的 COLOR 解析为 (R G B ALPHA)；非法时返回 nil.
四个字节依次是 alpha、红、绿、蓝（**alpha 在最高位**），每个分量除以 255
归一化到 0..1：alpha 满值 \"FF\" 为 1.0、半透明 \"80\" 约 0.502。只接受
**恰好 8 位**十六进制的形态；\"#RGB\"、\"#RRGGBB\"、缺 \"#\" 的前缀以及
含非十六进制字符的串一律返回 nil——keystone 仓 `docs/api.md' §4.5.1 只定义了
`#AARRGGBB'，其它位宽的 alpha 归属无从判断，猜错会把整笔颜色（含透明度）
画错，故宁可不画。"
  (when (and (stringp color)
             (string-match-p "\\`#[0-9A-Fa-f]\\{8\\}\\'" color))
    (list (/ (string-to-number (substring color 3 5) 16) 255.0)
          (/ (string-to-number (substring color 5 7) 16) 255.0)
          (/ (string-to-number (substring color 7 9) 16) 255.0)
          (/ (string-to-number (substring color 1 3) 16) 255.0))))

(defun seshat-reader-annotation--ink-coordinate (field)
  "把 FIELD 解析为**有限的**浮点坐标；非法或非有限数时返回 nil.
\"NaN\"、\"inf\" 及指数溢出成无穷大的形态（如 \"1e999\"）都返回 nil：与
`seshat-reader-annotation--parse-coordinate' 的十进制正则相比，这里多一道
有限性判断，因为溢出值能通过正则却在 MuPDF 里等价于非法坐标。"
  (let ((value (seshat-reader-annotation--parse-coordinate field)))
    (when (and (numberp value)
               (= value value)
               (< (abs value) 1.0e+INF))
      value)))

(defun seshat-reader-annotation--ink-stroke-from-segment (segment page)
  "把单个 \"ink:\" 段 SEGMENT 解析为一条笔迹；PAGE 是其 1-based 页码.
返回 (PAGE R G B ALPHA WIDTH POINTS TRUNCATED)：R/G/B/ALPHA 为 0..1 浮点
（颜色见 `seshat-reader-annotation--ink-color-from-hex'），WIDTH 为页面 pt
线宽，POINTS 为扁平浮点列表 (X0 Y0 X1 Y1 …)（页面 pt 坐标，**原样**不翻转
y），TRUNCATED 为 t 表示点数超过
`seshat-reader-annotation--ink-max-points' 而只保留了前 N 个点。

**整笔跳过**（返回 nil）的判据：不是 \"ink:\" 段、点数成形但缺颜色或宽度
字段、颜色不是 `#AARRGGBB'、宽度不是有限数字、坐标个数为奇数、任一坐标不是
有限数。任一条不满足即丢弃**整笔**而不是丢弃坏点：坐标错一个点会把整笔画
歪，画一条歪线比不画更误导用户。点数为 0（契约里的降级形态，只有颜色与
宽度）同样返回 nil——本来就没有几何可画。"
  (when (and (stringp segment)
             (string-prefix-p "ink:" segment))
    (let* ((fields (split-string (substring segment (length "ink:")) "," nil))
           (color (seshat-reader-annotation--ink-color-from-hex (nth 0 fields)))
           (width (seshat-reader-annotation--ink-coordinate (nth 1 fields)))
           (coords (mapcar #'seshat-reader-annotation--ink-coordinate
                           (nthcdr 2 fields))))
      (when (and page color width coords
                 (not (memq nil coords))
                 (zerop (% (length coords) 2)))
        (let* ((max seshat-reader-annotation--ink-max-points)
               (pairs (/ (length coords) 2))
               (truncated (> pairs max))
               (points (if truncated
                           (butlast coords (* 2 (- pairs max)))
                         coords)))
          (list page (nth 0 color) (nth 1 color) (nth 2 color) (nth 3 color)
                width points truncated))))))

(defun seshat-reader-annotation--ink-strokes-from-location (location)
  "从 LOCATION 解析出全部可渲染的手写笔迹，返回 stroke 列表.
LOCATION 的约定形态是
\"page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,<x1>,<y1>,…\"（一笔一条批注，
见 keystone 仓 `docs/api.md' §4.5.1）：页码 `<n>' 为 **1-based** 十进制整数，颜色为
`#AARRGGBB'，线宽与点列都是**页面 pt 坐标**（与 `rect:' 段同口径、原点
左上、y 向下）。按 \";\" 切段后**只**处理以 \"ink:\" 开头的段，出现多个
\"ink:\" 段时逐个解析，返回顺序与 LOCATION 中一致；`rect:' 段由
`seshat-reader-annotation--rects-from-location' 另行解析，两者互不吞并。

每个元素为 (PAGE R G B ALPHA WIDTH POINTS TRUNCATED)，字段含义见
`seshat-reader-annotation--ink-stroke-from-segment'。无 \"ink:\" 段、缺
`page:<n>' 页锚（无处安放）、降级形态（无点列）或全部段都非法时返回 nil
（即「无几何」），调用方据此跳过渲染。

坐标方向**本函数不做任何翻转**：Android 侧上传的是页面 pt 坐标，与 `rect:'
段一致；若实测发现两端口径相反，翻转应在渲染侧统一处理，解析层保持与契约
逐字对应。渲染入口（投喂 C 侧 stroke）由后续任务消费本函数结果，本模块
自身不投喂。

LOCATION 来自不可信的服务端响应，故解析**有界**：长度先按
`seshat-reader-annotation--location-max-length' 截断（截断后仍解析前面合法
的段，与 `seshat-reader-annotation--rects-from-location' 同口径），单笔点数
按 `seshat-reader-annotation--ink-max-points' 截断并标记。"
  (when (stringp location)
    (let* ((limit seshat-reader-annotation--location-max-length)
           (text (if (> (length location) limit)
                     (substring location 0 limit)
                   location))
           (page (seshat-reader-annotation--page-from-location text))
           (strokes nil))
      (dolist (segment (split-string text ";"))
        (let ((stroke (seshat-reader-annotation--ink-stroke-from-segment
                       (string-trim segment) page)))
          (when stroke
            (push stroke strokes))))
      (nreverse strokes))))

(defun seshat-reader-annotation--item-location (item)
  "取条目 ITEM 的 location 字符串；取不到时返回 nil.
ITEM 可以是 plist（含 `:location'，如
`seshat-reader-annotation--all-items' 的元素），也可以是服务端返回的
alist（含 `location'）。"
  (cond
   ((not (listp item)) nil)
   ((plist-member item :location) (plist-get item :location))
   ((assq 'location item) (cdr (assq 'location item)))
   (t nil)))

(defvar seshat-reader-annotation--highlight-warned nil
  "是否已就「装饰模块不可用」提示过一次（避免每次重绘刷屏）.
动态模块未加载、或加载的是缺 `--add-decoration' 的旧版模块，都是**稳定
状态**（会话内不会自愈），每次刷新都提示只会把回显区淹没，故只提示首次。
用户重装模块后可用
`(setq seshat-reader-annotation--highlight-warned nil)' 复位。")

(defvar seshat-reader-annotation-extra-decorations-function nil
  "附加装饰来源：一个无参函数，返回装饰列表，默认为 nil（不投喂）.
阅读器页面的装饰表是**文档级唯一**的一张，批注、框选闪现与搜索命中都要画在
同一页上，谁都不能独占 \"清空后重投\" 这条路径。故本模块开放这个扩展点：
`seshat-reader-annotation--redraw-highlights' 在投喂完批注与闪现之后调用
它，把返回的装饰也投进同一张表。

函数返回值的形态与 9 参 `seshat-reader-dyn--add-decoration' 一致，每个
元素为 (PAGE X0 Y0 X1 Y1 R G B ALPHA)（**9 个元素**）：PAGE 为 **1-based**
页号，坐标为页面坐标，R/G/B 各取 0.0–1.0、ALPHA 为透明度。返回 nil 表示
本次没有附加装饰。函数抛错或返回畸形元素时逐条跳过，绝不影响批注与闪现
的投喂。

该变量通常由使用方以 `setq-local' 设成 buffer-local（如
`seshat-reader-search--install-hook'），因此只在该文档的缓冲区里生效；
搜索会话结束时置回 nil 即可让批注重新独占装饰表。它**不计入**
`seshat-reader-annotation--redraw-highlights' 的返回值（返回值恒为批注
装饰数）。")

(defvar seshat-reader-annotation--feed-failure-report nil
  "非 nil 时把「单条装饰投喂失败」的条数打到回显区（默认为 nil，静默计数）.
「装饰模块不可用」（五个入口任一缺 `fboundp'，见
`seshat-reader-annotation--highlight-module-available-p'）与「单条投喂失败」
（页号越界、坐标非法、C 侧拒绝该条目）是**两种不同成因**：前者是稳定的
环境状态，后者通常是上游数据问题。二者此前共用同一条提示，于是「某条 rect
坐标非法」也被报成「模块未加载」，把排查引向错误方向。

现在只让前者走一次性提示（`--warn-highlight-unavailable'）；后者只累计失败
条数，默认**不** `message'——单条失败会随每次重绘复现，默认提示等于把回显区
刷爆，需要定位时把本变量设为 t 即可。返回值口径不变（仍只计成功投喂的批注
rect 数）。")

(defun seshat-reader-annotation--feed-extra-decorations ()
  "投喂 `seshat-reader-annotation-extra-decorations-function' 返回的装饰.
返回成功投喂的条数（扩展点未设置、返回 nil 或模块缺 `--add-decoration'
时为 0）。每个元素取 (PAGE X0 Y0 X1 Y1 R G B ALPHA) 九个字段，不足 9 个或
投喂抛错时**逐条跳过**，不影响调用方（批注与闪现早已投完）。该计数
**不并入** `--redraw-highlights' 的返回值——那个返回值恒为批注装饰数，是
既有调用点与测试依赖的口径。"
  (let ((function (and (boundp 'seshat-reader-annotation-extra-decorations-function)
                       seshat-reader-annotation-extra-decorations-function))
        (count 0))
    (when (functionp function)
      (dolist (decoration (ignore-errors (funcall function)))
        (when (and (listp decoration) (= 9 (length decoration))
                   (fboundp 'seshat-reader-dyn--add-decoration)
                   (ignore-errors
                     (seshat-reader-dyn--add-decoration
                      (nth 0 decoration) (nth 1 decoration)
                      (nth 2 decoration) (nth 3 decoration)
                      (nth 4 decoration) (nth 5 decoration)
                      (nth 6 decoration) (nth 7 decoration)
                      (nth 8 decoration))))
          (setq count (1+ count)))))
    count))

(defun seshat-reader-annotation--highlight-module-available-p ()
  "判断动态模块提供的四个入口是否都已可用.
`--clear-highlights' / `--add-highlight' 任一缺失即模块未加载；
`--add-decoration' 缺失则表示加载的是**装饰表之前**的旧版模块（画不了
underline / strikeout 细条，也画不了自定义配色）；`--add-stroke' 缺失表示
模块早于笔迹（ink）入口（画不了手写轨迹）。四种缺失都让投喂必然不完整，
调用方据此提前跳过并提示一次。"
  (and (fboundp 'seshat-reader-dyn--clear-highlights)
       (fboundp 'seshat-reader-dyn--add-highlight)
       (fboundp 'seshat-reader-dyn--add-decoration)
       (fboundp 'seshat-reader-dyn--add-stroke)
       t))

(defun seshat-reader-annotation--warn-highlight-unavailable ()
  "提示一次「装饰模块不可用」（同一会话内不重复）.
措辞覆盖三种成因：整个动态模块未加载，模块是装饰表之前的旧版（缺
`--add-decoration' 装饰入口），或模块早于笔迹入口（缺 `--add-stroke' 笔迹
入口）。只在**真正尝试投喂**而失败时由
`seshat-reader-annotation--redraw-highlights' 调用；提示本身不影响返回值，
也不抛错。"
  (unless seshat-reader-annotation--highlight-warned
    (setq seshat-reader-annotation--highlight-warned t)
    (message "Seshat Reader annotation: 装饰模块不可用（模块未加载，或缺少装饰入口/笔迹入口），跳过批注装饰")))

;;; 装饰几何与配色（kind → 装饰规格）

;; 每个 kind 的几何变换与配色都是**纯数据 + 纯函数**：C 侧只负责把
;; 「页面坐标矩形 + RGB + alpha」画出来，不认识 kind。因此新增一种装饰只需
;; 在 `seshat-reader-annotation--decoration-for' 里加一个分支，渲染层零改动。

(defcustom seshat-reader-annotation-highlight-color '(1.0 0.85 0.0)
  "高亮（`kind' = \"highlight\"）的填充色，RGB 三元素各取 0.0–1.0.
默认值与 C 侧 `DECORATION_DEFAULT_COLOR_R/G/B' 逐字一致（1.0 / 0.85 / 0.0，
即历史默认黄），因此默认配置下的渲染结果与引入装饰表之前**像素级相同**。
改成非默认值时 Lisp 侧改走 9 参 `--add-decoration' 投喂（C 的 5 参
`--add-highlight' 只认默认色）。"
  :type '(list number number number)
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-highlight-alpha 0.35
  "高亮的填充透明度（0.0 全透明 – 1.0 不透明）.
默认 0.35 与 C 侧 `DECORATION_DEFAULT_ALPHA' 一致，保证默认配色下仍走
5 参 `--add-highlight' 且像素不变。"
  :type 'number
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-underline-color '(0.0 0.45 0.85)
  "下划线（`kind' = \"underline\"）的颜色，RGB 三元素各取 0.0–1.0.
默认取偏蓝的深色，与半透明黄高亮在视觉上可区分；下划线是不透明细条。"
  :type '(list number number number)
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-underline-alpha 1.0
  "下划线的透明度；默认 1.0（不透明细条，避免与半透明高亮一样发糊）."
  :type 'number
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-underline-thickness 1.5
  "下划线细条的高度（页面坐标，单位 point）.
细条贴齐行矩形的**底边**：Y0 取 `Y1 - 本值'、Y1 保持行矩形底边。行高小于
本值时细条上沿被夹到行矩形上沿（不产生负面积矩形）。"
  :type 'number
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-strikeout-color '(0.85 0.1 0.1)
  "删除线（`kind' = \"strikeout\"）的颜色，RGB 三元素各取 0.0–1.0."
  :type '(list number number number)
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-strikeout-alpha 1.0
  "删除线的透明度；默认 1.0（不透明细条）."
  :type 'number
  :group 'seshat-reader-annotation)

(defcustom seshat-reader-annotation-strikeout-thickness 1.5
  "删除线细条的高度（页面坐标，单位 point）.
细条以行矩形的**垂直中线**为中心，上下各取本值的一半。"
  :type 'number
  :group 'seshat-reader-annotation)

(defconst seshat-reader-annotation--drawing-kinds '("underline" "strikeout")
  "有专属几何变换的批注 kind.
不在此表内的 kind（含 nil、\"highlight\"、\"note\"、\"ink\"）按
\"highlight\" 处理——保持引入本表之前的向后兼容行为。")

(defun seshat-reader-annotation--drawing-kind (kind)
  "把批注 KIND 归一为绘制用的 kind（\"highlight\" / \"underline\" / \"strikeout\"）.
未知或缺失的 kind 一律归为 \"highlight\"，与
`seshat-reader-annotation--decoration-for' 的兜底分支一致，因此老服务端
（没有 `kind' 字段）与便签（\"note\"）的渲染行为完全不变。"
  (if (member kind seshat-reader-annotation--drawing-kinds)
      kind
    "highlight"))

(defun seshat-reader-annotation--decoration-for (rect kind)
  "把行矩形 RECT 按 KIND 变换成装饰规格 (X0 Y0 X1 Y1 R G B ALPHA).
RECT 为页面坐标四元素列表 (X0 Y0 X1 Y1)。KIND 取：

- \"highlight\"：RECT **原样**返回，颜色取
  `seshat-reader-annotation-highlight-color'（默认 1.0 0.85 0.0）、透明度
  取 `seshat-reader-annotation-highlight-alpha'（默认 0.35）——与 C 侧
  `--add-highlight' 的历史默认配色逐字一致。
- \"underline\"：取 RECT **底边**的细条 (X0, Y1 - 粗细, X1, Y1)，颜色与
  透明度取 underline 的两个选项（默认不透明深蓝）。
- \"strikeout\"：取 RECT **垂直中线**上下的细条 (X0, MID - 粗细/2, X1,
  MID + 粗细/2)，MID = (Y0 + Y1) / 2，颜色取 strikeout 选项（默认不透明红）。
- 其它任意值：按 \"highlight\" 处理（向后兼容）。

细条的上下界用 `max'/`min' 夹在 RECT 的 [Y0, Y1] 内，保证行高小于粗细时
也不会产出 Y0 > Y1 的负面积矩形（C 侧会静默丢弃这种矩形，表现为什么都没
画）。本函数是纯函数，不读 buffer、不碰 C 层，便于单测。"
  (let ((x0 (nth 0 rect))
        (y0 (nth 1 rect))
        (x1 (nth 2 rect))
        (y1 (nth 3 rect)))
    (cond
     ((equal kind "underline")
      (list x0
            (max y0 (- y1 seshat-reader-annotation-underline-thickness))
            x1 y1
            (nth 0 seshat-reader-annotation-underline-color)
            (nth 1 seshat-reader-annotation-underline-color)
            (nth 2 seshat-reader-annotation-underline-color)
            seshat-reader-annotation-underline-alpha))
     ((equal kind "strikeout")
      (let* ((mid (/ (+ y0 y1) 2.0))
             (half (/ seshat-reader-annotation-strikeout-thickness 2.0)))
        (list x0
              (max y0 (- mid half))
              x1
              (min y1 (+ mid half))
              (nth 0 seshat-reader-annotation-strikeout-color)
              (nth 1 seshat-reader-annotation-strikeout-color)
              (nth 2 seshat-reader-annotation-strikeout-color)
              seshat-reader-annotation-strikeout-alpha)))
     (t
      (list x0 y0 x1 y1
            (nth 0 seshat-reader-annotation-highlight-color)
            (nth 1 seshat-reader-annotation-highlight-color)
            (nth 2 seshat-reader-annotation-highlight-color)
            seshat-reader-annotation-highlight-alpha)))))

(defun seshat-reader-annotation--annotation-decorations (items)
  "把条目列表 ITEMS 解析为装饰描述列表，元素形如 (PAGE X0 Y0 X1 Y1 KIND).
ITEMS 的元素形态见 `seshat-reader-annotation--item-location'（plist 或
服务端 alist 皆可）。location 的两种形态都支持：

- **旧形态** `page:<n>;rect:…`：PAGE 取页锚，矩形由
  `seshat-reader-annotation--rects-from-location' 逐段读回（行为不变）；
- **跨页形态** `pages:<a>-<b>;rect@<p>:…`：逐段用**段内页号**，由
  `seshat-reader-annotation--page-rects-from-location' 读回，因此同一条批注
  的矩形可以落在不同的页上。

没有 location、没有可用几何段、或（旧形态下）页码无法解析的条目直接跳过——
跨页形态不依赖 `seshat-reader-annotation--page-from-location'（它对
`pages:' 返回 nil），所以「旧形态跳过」与「新形态展开」是两条互斥路径。
坐标为浮点数、PAGE 为 1-based 整数；KIND 已归一（见
`seshat-reader-annotation--drawing-kind'，取 \"highlight\" / \"underline\" /
\"strikeout\"）。顺序与服务端返回的条目顺序一致，同一条的多段 location 按
**段**展开。

本函数是**纯解析**：既不清空也不投喂，供
`seshat-reader-annotation--redraw-highlights' 消费。"
  (let (decorations)
    (dolist (item items)
      (let* ((location (seshat-reader-annotation--item-location item))
             (page (seshat-reader-annotation--page-from-location location))
             (kind (seshat-reader-annotation--drawing-kind
                    (seshat-reader-annotation--kind item))))
        (cond
         (page
          (dolist (rect (seshat-reader-annotation--rects-from-location location))
            (push (list page (nth 0 rect) (nth 1 rect) (nth 2 rect) (nth 3 rect)
                        kind)
                  decorations)))
         (t
          (dolist (rect (seshat-reader-annotation--page-rects-from-location
                         location))
            (push (list (nth 0 rect) (nth 1 rect) (nth 2 rect) (nth 3 rect)
                        (nth 4 rect) kind)
                  decorations))))))
    (nreverse decorations)))

(defun seshat-reader-annotation--annotation-rects (items)
  "把条目列表 ITEMS 解析为矩形列表，元素形如 (PAGE X0 Y0 X1 Y1).
与 `seshat-reader-annotation--annotation-decorations' 同源，只是**省略**
kind（5 元素）——保留本形态是为了让既有的调用点与测试口径不变。需要在
跨页绘制时区分高亮/下划线/删除线的调用方请直接用 decorations。
坐标为浮点数、PAGE 为 1-based 整数，可直接交给
`seshat-reader-dyn--add-highlight'。"
  (mapcar (lambda (decoration)
            (list (nth 0 decoration) (nth 1 decoration) (nth 2 decoration)
                  (nth 3 decoration) (nth 4 decoration)))
          (seshat-reader-annotation--annotation-decorations items)))

(defun seshat-reader-annotation--annotation-strokes (items)
  "把条目列表 ITEMS 解析为手写笔迹列表，元素为 (PAGE R G B ALPHA WIDTH POINTS TRUNCATED).
ITEMS 的元素形态见 `seshat-reader-annotation--item-location'（plist 或服务端
alist 皆可）；没有 location、location 里没有 `ink:' 段或段全非法的条目直接
跳过（见 `seshat-reader-annotation--ink-strokes-from-location'）。PAGE 为
**1-based**（与 location 的 `page:<n>' 一致，转 0-based 是投喂入口
`seshat-reader-annotation--feed-stroke' 的职责）。

本函数是**纯解析**：既不清空也不投喂，供
`seshat-reader-annotation--redraw-highlights' 消费。一条 location 含多个
`ink:' 段时按**段**展开，顺序与串内一致。"
  (let (strokes)
    (dolist (item items)
      (dolist (stroke (seshat-reader-annotation--ink-strokes-from-location
                       (seshat-reader-annotation--item-location item)))
        (push stroke strokes)))
    (nreverse strokes)))

(defun seshat-reader-annotation--cached-entries ()
  "返回列表缓冲区缓存中**属于当前文档**的条目列表；不可用时返回 nil.
缓存取 `seshat-reader-annotation-list-buffer-name' 缓冲区的
`seshat-reader-annotation-list-entries'（最近一次成功拉取的结果，不发起任何
网络请求）。以下三种情形返回 nil：缓存缓冲区不存在、当前缓冲区没有关联文件
（缓冲区不访问任何磁盘文件）、缓存所属文档与当前文档不同。

跨文档过滤是**唯一一份**：装饰缓存与笔迹缓存都从这里取条目，因此两者不可能
出现「一个过滤了一个没过滤」的漂移——C 层装饰表是文档级的，把 A 文档的矩形
或笔迹画到 B 文档的页面上就是错误标注。"
  (let* ((buffer (get-buffer seshat-reader-annotation-list-buffer-name))
         (document-id (seshat-reader-annotation--quiet-doc-id buffer-file-name)))
    (when (and document-id
               (buffer-live-p buffer)
               (equal document-id
                      (buffer-local-value
                       'seshat-reader-annotation-list-document-id buffer)))
      (buffer-local-value 'seshat-reader-annotation-list-entries buffer))))

(defun seshat-reader-annotation--cached-annotation-decorations ()
  "从列表缓冲区缓存派生装饰描述列表（元素形如 (PAGE X0 Y0 X1 Y1 KIND)）.
缓存取列表缓冲区 `*Seshat Annotations*' 的
`seshat-reader-annotation-list-entries'，即**最近一次成功拉取**的结果
（不发起任何网络请求）；条目里的 `kind' 决定每段的几何与配色（见
`seshat-reader-annotation--annotation-decorations'）。

缓存缺失、属于**其它文档**或当前缓冲区没有关联文件时返回 nil：C 层装饰表
是**文档级**的，把 A 文档的矩形投到 B 文档的页面上就是错误高亮。过滤逻辑
收敛在 `seshat-reader-annotation--cached-entries'，笔迹缓存（
`seshat-reader-annotation--cached-annotation-strokes'）与它共用同一份判定。"
  (seshat-reader-annotation--annotation-decorations
   (seshat-reader-annotation--cached-entries)))

(defun seshat-reader-annotation--cached-annotation-rects ()
  "从列表缓冲区缓存派生批注矩形列表（元素形如 (PAGE X0 Y0 X1 Y1)）.
与 `seshat-reader-annotation--cached-annotation-decorations' 同一份缓存与
同一套过滤（跨文档/无缓存即 nil），只是**省略** kind（5 元素）。"
  (let ((decorations (seshat-reader-annotation--cached-annotation-decorations)))
    (mapcar (lambda (decoration)
              (list (nth 0 decoration) (nth 1 decoration) (nth 2 decoration)
                    (nth 3 decoration) (nth 4 decoration)))
            decorations)))

(defun seshat-reader-annotation--cached-annotation-strokes ()
  "从列表缓冲区缓存派生手写笔迹列表（元素为 (PAGE R G B ALPHA WIDTH POINTS TRUNCATED)）.
与 `seshat-reader-annotation--cached-annotation-decorations' **同源同过滤**
（经 `seshat-reader-annotation--cached-entries'）：只取最近一次成功拉取、
且属于**当前文档**的条目；缓存缺失或属于其它文档时返回 nil，避免把 A 文档
的手写笔迹画到 B 文档的页面上。

PAGE 为 **1-based**；转 0-based 由投喂入口
`seshat-reader-annotation--feed-stroke' 负责。"
  (seshat-reader-annotation--annotation-strokes
   (seshat-reader-annotation--cached-entries)))

(defun seshat-reader-annotation--feed-stroke
    (page r g b alpha width points)
  "把一条手写笔迹投喂给 C 层，成功返回 t、失败返回 nil.
PAGE 为 **1-based** 页号，**原样**传给 C 入口：`--add-stroke' 与
`--add-highlight' / `--add-decoration' 共用 C 侧的 `resolve_page_arg'，三个
入口的 page 参数口径完全一致（都是 1-based，0-based 换算在 C 里做）。实测
证据（`d2l-zh-pytorch.pdf'，当前页 0-based 10 = 1-based 11）：传 11 → 笔迹
出现在当前页；传 (1- 11) = 10 → 笔迹消失（画到了上一页）。因此本函数不做
任何 ±1 换算。R/G/B/ALPHA 取 0.0–1.0；WIDTH 为页面 pt 线宽；POINTS 为扁平
坐标列表 (X0 Y0 X1 Y1 …)（页面 pt，原点左上、y 向下，与 `rect:' 段同口径，
**不做任何翻转**）。

跳过条件（返回 nil，不调 C）：`--add-stroke' 不存在（旧版模块没有笔迹入口）
或点数不足两个（少于 4 个数字）——C 侧同样会拒，先判省一次跨界调用。C 侧
返回 nil（页号越界、坐标非有限等）时本函数同样返回 nil，由调用方计入失败。
所有 C 调用都包在 `ignore-errors' 里：装饰是可选增强，不得打断调用方。"
  (when (and (fboundp 'seshat-reader-dyn--add-stroke)
             (integerp page)
             (>= page 1)
             (listp points)
             (>= (length points) 4))
    (ignore-errors
      (and (seshat-reader-dyn--add-stroke page r g b alpha width points)
           t))))

(defun seshat-reader-annotation--flash-rects ()
  "返回当前缓冲区待闪现的选区矩形（元素形如 (PAGE X0 Y0 X1 Y1)），无则 nil.
数据源是 buffer-local 变量 `seshat-reader-select--flash-rects'，由
`seshat-reader-select--flash-selection' 在框选松手后设置、由它武装的定时器
清除。`seshat-reader-select' 未加载时该变量为 nil 绑定，本函数返回 nil。"
  (when (boundp 'seshat-reader-select--flash-rects)
    seshat-reader-select--flash-rects))

(defconst seshat-reader-annotation--c-default-highlight-color '(1.0 0.85 0.0)
  "C 侧 `--add-highlight' 写死的默认高亮色（`DECORATION_DEFAULT_COLOR_R/G/B'）.
用于判断「配置是否仍是历史默认值」——是则继续走 5 参 `--add-highlight'
（像素级等价路径），否则改走 9 参 `--add-decoration'。")

(defconst seshat-reader-annotation--c-default-highlight-alpha 0.35
  "C 侧 `--add-highlight' 写死的默认透明度（`DECORATION_DEFAULT_ALPHA'）.")

(defun seshat-reader-annotation--feed-decoration (decoration)
  "把一条装饰 DECORATION 投喂给 C 层，成功返回 t、失败返回 nil.
DECORATION 形如 (PAGE X0 Y0 X1 Y1 KIND)，KIND 已经过
`seshat-reader-annotation--drawing-kind' 归一。

两条 C 入口**二选一、不混用**（默认配置下像素等价，T3 实测 PNM 字节相同）：

- KIND 为 \"highlight\" 且配色仍是历史默认值（1.0 0.85 0.0 / 0.35）→ 5 参
  `seshat-reader-dyn--add-highlight'，由 C 侧填默认色；这条路径的调用形态
  与引入装饰表之前完全一致，既有调用点与测试口径都不受影响。
- 其余情形（underline / strikeout 细条，或用户自定义了 highlight 配色）→
  9 参 `seshat-reader-dyn--add-decoration'，显式传 RGB 与 alpha。

失败（模块无该函数、页号越界、坐标非法）时向上抛出或返回 nil，由
`seshat-reader-annotation--redraw-highlights' 用 `ignore-errors' 计数与提示。"
  (let* ((page (nth 0 decoration))
         (rect (list (nth 1 decoration) (nth 2 decoration)
                     (nth 3 decoration) (nth 4 decoration)))
         (kind (seshat-reader-annotation--drawing-kind (nth 5 decoration)))
         (spec (seshat-reader-annotation--decoration-for rect kind))
         (x0 (nth 0 spec))
         (y0 (nth 1 spec))
         (x1 (nth 2 spec))
         (y1 (nth 3 spec))
         (color (list (nth 4 spec) (nth 5 spec) (nth 6 spec)))
         (alpha (nth 7 spec)))
    (if (and (equal kind "highlight")
             (equal color seshat-reader-annotation--c-default-highlight-color)
             (equal alpha seshat-reader-annotation--c-default-highlight-alpha))
        (seshat-reader-dyn--add-highlight page x0 y0 x1 y1)
      (seshat-reader-dyn--add-decoration page x0 y0 x1 y1
                                        (nth 0 color) (nth 1 color) (nth 2 color)
                                        alpha))))

(defun seshat-reader-annotation--redraw-highlights (&optional decorations strokes)
  "全量重投页面装饰：批注装饰 DECORATIONS + 闪现矩形 + 手写笔迹 STROKES.
DECORATIONS 为 (PAGE X0 Y0 X1 Y1 [KIND]) 列表——KIND 省略（5 元素，老口径）
时按 \"highlight\" 处理；省略或传 nil 时改用列表缓冲区的最近一次拉取缓存
（见 `seshat-reader-annotation--cached-annotation-decorations'）。
STROKES 为 (PAGE R G B ALPHA WIDTH POINTS [TRUNCATED]) 列表（见
`seshat-reader-annotation--annotation-strokes'；PAGE 为 1-based）；省略或传
nil 时同样回落到缓存（`seshat-reader-annotation--cached-annotation-strokes'）。

闪现矩形取自**当前缓冲区**的 `seshat-reader-select--flash-rects'
（`seshat-reader-select--flash-selection' 设置）。闪现**不受**
`seshat-reader-annotation-highlight-enabled' 约束：该开关只关闭批注装饰，
而闪现是框选松手后的独立反馈（用户明确要求的交互反馈，关闭批注装饰时仍
应可见）；闪现恒按 highlight 投喂。笔迹只受
`seshat-reader-annotation-ink-enabled' 约束，两个开关互不影响。

流程固定为 `seshat-reader-dyn--clear-highlights' → 逐条投喂（批注 rect 在前、
闪现其次、第三方附加装饰再其次、ink 笔迹最后）→
`seshat-reader--multipage-refresh-decorations'：全量重投、不做增量，避免 C 侧
表与 elisp 侧缓存在删除/离线同步后漂移（P1 起装饰是在渲染时烘进位图的，所以
最后一步是重渲染驻留页，而不是刷新单页 overlay）。三次 C 调用都包在 `ignore-errors' 里
（模块未加载、没有载入文档时不打断调用方）；elisp 侧的解析错误**不**吞掉。
批注按 kind 走 `seshat-reader-annotation--feed-decoration'（highlight 走 5 参
`--add-highlight'，细条走 9 参 `--add-decoration'）；笔迹走 7 参
`--add-stroke'（页号与 `--add-highlight' 同为 **1-based**，C 侧统一做
0-based 换算，Lisp 侧不做 ±1；投喂层也不做 y 翻转——两端口径同为原点左上、
y 向下，见 keystone 仓 `docs/api.md' §4.5.1）。

笔迹排在最后：额外装饰来源（搜索命中）与笔迹互不遮挡顺序敏感度低，但笔迹是
用户手写，画在矩形装饰之上更符合「手写覆盖高亮」的直觉。

**两种失败分开归因**：模块不可用（`--clear-highlights' / `--add-highlight' /
`--add-decoration' / `--add-stroke' 四入口任一缺 `fboundp'；单页 overlay 刷新
入口 `--refresh-highlights' 已于 2026-10-28 随 canvas 迁移删除，不再探测）经
`seshat-reader-annotation--warn-highlight-unavailable' 提示一次
（会话内不重复）；而**单条投喂失败**（页号越界、坐标非法、C 侧拒绝该条目）
只静默累计条数，仅在 `seshat-reader-annotation--feed-failure-report' 非 nil
时 `message' 一次总数——它通常是上游数据问题，且每次重绘都会复现。两种情况
都**不抛错**——装饰是可选增强。

返回值为成功投喂的**批注 rect** 装饰数（一条多段 location 的批注按**段**
计数，与改造前「每段一次投喂」的语义一致）；闪现矩形与 ink 笔迹不计入，以
保持 `seshat-reader-annotation--apply-highlights' 既有的计数语义。"
  (let* ((annotation-decorations
          (and seshat-reader-annotation-highlight-enabled
               (or decorations
                   (seshat-reader-annotation--cached-annotation-decorations))))
         (annotation-strokes
          (and seshat-reader-annotation-ink-enabled
               (or strokes
                   (seshat-reader-annotation--cached-annotation-strokes))))
         (flash (seshat-reader-annotation--flash-rects))
         (count 0)
         (unavailable nil)
         (failed 0))
    (ignore-errors (seshat-reader-dyn--clear-highlights))
    (if (not (seshat-reader-annotation--highlight-module-available-p))
        ;; 模块不可用是稳定的环境状态：只累计，末尾一次性提示。
        (when (or annotation-decorations annotation-strokes flash)
          (setq unavailable t))
      (when annotation-decorations
        (dolist (decoration annotation-decorations)
          (if (ignore-errors
                (seshat-reader-annotation--feed-decoration decoration))
              (setq count (1+ count))
            (setq failed (1+ failed)))))
      (dolist (rect flash)
        (ignore-errors
          (seshat-reader-dyn--add-highlight (nth 0 rect) (nth 1 rect)
                                            (nth 2 rect) (nth 3 rect)
                                            (nth 4 rect))))
      ;; 批注与闪现之后才追加第三方来源（如搜索命中），见
      ;; `seshat-reader-annotation-extra-decorations-function'。这一句**不能**
      ;; 被「有批注或闪现」的守卫挡住：只做搜索时两者都为空，照样要投。
      (seshat-reader-annotation--feed-extra-decorations)
      ;; 最后画 ink 笔迹（`ink-enabled' 为 nil 时上面已把 STROKES 置空）。
      (dolist (stroke annotation-strokes)
        (unless (seshat-reader-annotation--feed-stroke
                 (nth 0 stroke) (nth 1 stroke) (nth 2 stroke)
                 (nth 3 stroke) (nth 4 stroke) (nth 5 stroke) (nth 6 stroke))
          (setq failed (1+ failed)))))
    ;; P1：装饰在渲染时烘进位图，C 侧表本身不再改变画面 —— 投喂完之后要
    ;; 「清 spec 缓存 + 重渲染驻留页」，见
    ;; `seshat-reader--multipage-refresh-decorations'。
    (ignore-errors (seshat-reader--multipage-refresh-decorations))
    (when unavailable
      (seshat-reader-annotation--warn-highlight-unavailable))
    ;; 单条失败与「模块不可用」分开归因：默认只计数，见
    ;; `seshat-reader-annotation--feed-failure-report'。
    (when (and seshat-reader-annotation--feed-failure-report
               (> failed 0))
      (message "Seshat Reader annotation: %d 条装饰投喂失败（页号越界或坐标非法）"
               failed))
    count))

(defun seshat-reader-annotation--apply-highlights (items)
  "把 ITEMS 的批注装饰批量投喂给 C 层并触发重绘，返回添加的装饰数.
ITEMS 为条目列表，元素形态见 `seshat-reader-annotation--item-location'
（plist 或服务端 alist 皆可）；没有 location 或 location 里没有可用
`rect:' 段的条目直接跳过。条目 `kind' 决定每段的几何与配色（见
`seshat-reader-annotation--annotation-decorations'）。

本函数只做「解析」，投喂与重绘统一交给
`seshat-reader-annotation--redraw-highlights'（全量重投：clear → 逐条投喂
→ refresh，不做增量，避免 C 侧表与 elisp 侧缓存在删除/离线同步后漂移），
从而闪现与批注共用一套投喂逻辑。

`seshat-reader-annotation-highlight-enabled' 为 nil 时批注一个都不投
（返回值 0），但当前缓冲区的闪现矩形仍会被投——闪现不受该开关约束，详见
`seshat-reader-annotation--redraw-highlights'。`ink:' 段的手写笔迹由
`seshat-reader-annotation-ink-enabled' 单独控制，与 rect 开关互不影响。

返回值是成功投喂的批注装饰数（多段 location 按段计数）；模块不可用时返回
0、提示一次且不抛错。"
  (seshat-reader-annotation--redraw-highlights
   (seshat-reader-annotation--annotation-decorations items)
   (seshat-reader-annotation--annotation-strokes items)))

(defun seshat-reader-annotation--source-document-p (source document-id)
  "判断 SOURCE 缓冲区所显示的文档是否就是 DOCUMENT-ID 指向的文档.
SOURCE 须为存活的、处于 `seshat-reader-mode' 且关联了文件的缓冲区；
文档标识按 `seshat-reader-annotation--quiet-doc-id' 派生后与
DOCUMENT-ID 比较。不满足时返回 nil，调用方据此**跳过**高亮同步，避免把
A 文档的批注画到 B 文档上（动态模块的高亮表是文档级的）。"
  (and (buffer-live-p source)
       (with-current-buffer source
         (and (derived-mode-p 'seshat-reader-mode)
              (equal document-id
                     (seshat-reader-annotation--quiet-doc-id buffer-file-name))))))

(defun seshat-reader-annotation--note-created-annotation
    (file id location text &optional kind selected-text)
  "新建批注成功后把该条追加进缓存并重投页面高亮.
FILE 为批注所属文档路径，ID 为服务端返回的批注 id（可为 nil），
LOCATION 与 TEXT 为该批注的位置与正文。KIND 与 SELECTED-TEXT 为可选的
类型与选中原文：KIND 非 nil 时随条目一并写入缓存，使随后从缓存重渲染的
列表行仍能沿 `seshat-reader-annotation--display-text' 的回退链显示原文
（高亮的 `text' 是空串，标题全靠 `selected_text'）。只有同时满足下面三个
条件才增量追加到缓存末尾并调用 `seshat-reader-annotation--apply-highlights'
重投：

1. 列表缓冲区存在；
2. 其缓存（`seshat-reader-annotation-list-entries'）属于 FILE 所指文档
   （doc-id 相等）；
3. **当前载入文档就是该文件**——经 `seshat-reader-annotation--source-document-p'
   校验列表缓冲区记录的发起方 reader 缓冲区（`-list-source'）确实显示着
   FILE 这份文档。仅比对 doc-id 不足以保证这一点（A 文档的列表缓存可能
   仍然存在，而用户已经切去读 B 文档），而 C 层高亮表是**文档级**的，
   错投会把 A 的矩形画到 B 的页面上。

任一条件不满足时什么都不做（下次
`\\[seshat-reader-annotation-list]' 再全量同步）。
本函数**不发起任何网络请求**，也不重渲染列表缓冲区。"
  (let* ((buffer (get-buffer seshat-reader-annotation-list-buffer-name))
         (document-id (seshat-reader-annotation--quiet-doc-id file))
         (source (and (buffer-live-p buffer)
                      (buffer-local-value
                       'seshat-reader-annotation-list-source buffer))))
    (when (and document-id
               (buffer-live-p buffer)
               (equal document-id
                      (buffer-local-value
                       'seshat-reader-annotation-list-document-id buffer))
               ;; 当前载入文档 == 目标文件，否则不投喂（防跨文档画高亮）。
               (seshat-reader-annotation--source-document-p source document-id))
      (with-current-buffer buffer
        (let ((entries (append seshat-reader-annotation-list-entries
                               (list (append
                                      (list (cons 'id id)
                                            (cons 'location location)
                                            (cons 'text text))
                                      (when (stringp kind)
                                        (list (cons 'kind kind)))
                                      (when (and (stringp selected-text)
                                                 (not (string-empty-p selected-text)))
                                        (list (cons 'selected_text selected-text))))))))
          (setq-local seshat-reader-annotation-list-entries entries)
          (seshat-reader-annotation--apply-highlights entries))))))

(defun seshat-reader-annotation-refresh-highlights ()
  "按最近一次成功拉取的批注重新投喂页面高亮.
取列表缓冲区 `*Seshat Annotations*' 缓存的最近一次**服务端拉取结果**
（`seshat-reader-annotation-list-entries'），重新解析其 rect 段并调用
`seshat-reader-annotation--apply-highlights' 全量重投与重绘。本命令
**不发起任何网络请求**（缓存已在内存里）。

缓存缺失（从未成功拉取）、缓存属于**其它文档**或当前缓冲区没有关联
文件时只 `message' 提示先用 `\\[seshat-reader-annotation-list]'
拉取一次，不做任何修改。返回实际添加的 rect 数量（提示情形返回 0）。"
  (interactive)
  (let ((document-id (seshat-reader-annotation--quiet-doc-id buffer-file-name))
        (buffer (get-buffer seshat-reader-annotation-list-buffer-name))
        (hint (substitute-command-keys
               "\\[seshat-reader-annotation-list]")))
    (cond
     ((null document-id)
      (message "Seshat Reader annotation: 当前缓冲区没有关联文件，无法同步高亮。")
      0)
     ((not (buffer-live-p buffer))
      (message "Seshat Reader annotation: 还没有批注缓存，请先用 %s 拉取一次。"
               hint)
      0)
     ((not (equal document-id
                  (buffer-local-value
                   'seshat-reader-annotation-list-document-id buffer)))
      (message "Seshat Reader annotation: 缓存的批注属于其它文档，请先在本文档用 %s 拉取一次。"
               hint)
      0)
     (t
      (seshat-reader-annotation--apply-highlights
       (buffer-local-value 'seshat-reader-annotation-list-entries buffer))))))

;;; ETAF 渲染层接入

(defun seshat-reader-annotation--etaf-p ()
  "判断 ETAF 渲染层当前是否可用.
判据是渲染层模块已加载（`seshat-reader-etaf-available-p' 已定义）且该函数
返回非 nil（总开关打开并且 `etaf-ui' 加载成功）。渲染层是本包的**软依赖**：
本文件不在顶部 require 它，因此未安装 ETAF 时本函数返回 nil，列表走既有
纯文本渲染。"
  (and (fboundp 'seshat-reader-etaf-available-p)
       (seshat-reader-etaf-available-p)))

(defun seshat-reader-annotation--etaf-items (annotations queued)
  "把 ANNOTATIONS 与 QUEUED 合成为 ETAF 渲染层使用的 plist 列表.
ANNOTATIONS 为服务端返回的批注 alist 列表，QUEUED 为本地离线队列中待同步
的 create 条目 plist 列表。每个元素形如
`(:id ID :uuid UUID :location LOCATION :page PAGE :page-label LABEL
  :text TEXT :dirty DIRTY)'：

- 服务端项取 `:id'（`:uuid' 为 nil，`:dirty' 为 nil），页码由
  `seshat-reader-annotation--location-page' 从 `:location' 解析（旧形态是
  `page:<n>' 的数字，跨页形态是 `pages:<a>-<b>' 的首页 A）；
- 本地待同步项取队列条目的 `:uuid'（`:id' 为 nil，`:dirty' 为 t）。

`:page-label' 是**显示用**页码串（`seshat-reader-annotation--page-label'）：
旧形态为 nil（消费方继续用 `:page'），跨页形态为 \"a-b\"。两者分开是为了让
跳转/排序始终拿到数字页号，而显示可以写 \"a-b\"。

v8 契约的 `kind' / `selected_text' 一并转成 `:kind' / `:selected-text'：
缺键时 `:kind' 为 \"note\"、`:selected-text' 为 nil，故两条渲染路径对老
记录的行为与改动前完全一致。

顺序与 `seshat-reader-annotation--render-list' 的文本渲染一致：**服务端项
在前、本地待同步项在后**。"
  (append
   (mapcar (lambda (annotation)
             (let ((location (alist-get 'location annotation)))
               (list :id (alist-get 'id annotation)
                     :uuid nil
                     :location location
                     :page (seshat-reader-annotation--location-page location)
                     :page-label (seshat-reader-annotation--page-span-label
                                  location)
                     :text (alist-get 'text annotation)
                     :selected-text (seshat-reader-annotation--selected-text
                                     annotation)
                     :kind (seshat-reader-annotation--kind annotation)
                     :dirty nil)))
           annotations)
   (mapcar (lambda (entry)
             (let ((location (plist-get entry :location)))
               (list :id nil
                     :uuid (plist-get entry :uuid)
                     :location location
                     :page (seshat-reader-annotation--location-page location)
                     :page-label (seshat-reader-annotation--page-span-label
                                  location)
                     :text (plist-get entry :text)
                     :selected-text (seshat-reader-annotation--selected-text
                                     entry)
                     :kind (seshat-reader-annotation--kind entry)
                     :dirty t)))
           queued)))

(defun seshat-reader-annotation--all-items (annotations queued)
  "返回全量条目列表，元素为 plist.
ANNOTATIONS 为服务端批注列表，QUEUED 为本地离线队列中待同步的 create 条目
列表。本函数**直接复用** `seshat-reader-annotation--etaf-items' 的合并结果
（服务端项在前、本地待同步项在后），不另写一套合并逻辑，以免两条路径的
顺序漂移。

本函数是列表渲染的全量条目合并入口：纯文本路径与 ETAF 路径都只接受本
函数的返回值，且都**全量**渲染，不做任何切片。

合并结果随后经 `seshat-reader-annotation--group-ink-items' 聚合：同一页的
`ink' 条目（`kind' 为 \"ink\"，一笔一条）折叠为一条「第 N 页手写（M 笔）」
汇总行，避免 `text' / `selected_text' 均为空串的笔迹条目渲染成空白行、也
避免它们淹没文本批注。其他 kind 的条目原样保留、顺序不变。"
  (seshat-reader-annotation--group-ink-items
   (seshat-reader-annotation--etaf-items annotations queued)))

(defun seshat-reader-annotation--render-list-etaf (items document-id source)
  "用 ETAF 渲染层把 ITEMS 渲染到当前缓冲区；成功返回 t，否则返回 nil.
ITEMS 是 `seshat-reader-annotation--etaf-items' 的返回值（**全量**条目，
服务端项在前、本地待同步项在后），渲染层全量渲染成卡片——单列连续流，
面板窗口整体滚动，不做切片也不显示页码徽章。DOCUMENT-ID 与 SOURCE 随渲染
一并交给渲染层，供其动作命令（跳页 / 删除 / 引用）复用。

渲染层未安装或加载失败时返回 nil，由调用方回退纯文本渲染。渲染**抛错**时
`message' 一条警告后同样返回 nil——面板不得因为渲染失败而空白。"
  (condition-case err
      (if (require 'seshat-reader-etaf nil t)
          (progn
            (seshat-reader-etaf-render-annotations
             (current-buffer) items document-id source)
            t)
        nil)
    (error
     (message "Seshat Reader annotation: ETAF 渲染失败，回退文本渲染：%s"
              (error-message-string err))
     nil)))

(defun seshat-reader-annotation--etaf-mounted-p ()
  "判断当前缓冲区是否已挂载 ETAF runtime.
`seshat-reader-annotation--render-list' 据此决定是否可以先 `erase-buffer'：
ETAF 的 runtime 依赖缓冲区既有文本做增量刷新，清空后再 flush 会报错。
ETAF 渲染层未加载（或尚未挂载）时返回 nil，调用方按文本渲染处理。"
  (and (fboundp 'etaf-runtime-for-buffer)
       (and (etaf-runtime-for-buffer (current-buffer)) t)))

(defun seshat-reader-annotation--render-list (document-id source annotations
                                                         &optional queued uid)
  "在 `*Seshat Annotations*' 中渲染批注列表.
DOCUMENT-ID 为**显示标识（doc-id）**，SOURCE 为发起列表的 seshat-reader
文档缓冲区；二者都以 buffer-local 形式记入列表缓冲区，供 `d' 刷新与 `RET'
跳页复用，ANNOTATIONS 也一并缓存到
`seshat-reader-annotation-list-entries' 供免 HTTP 重渲染。

UID 为服务端权威身份，非 nil 时写入 buffer-local
`seshat-reader-annotation-list-uid'（供列表刷新与删除发请求）。为 nil 时
**保留**列表缓冲区里已有的值——ETAF 渲染层的 `--rerender-cached' 走的就是
这条「无新 uid」的路径，它复用上一次完整渲染写入的值。显示与 `seshat:'
链接文本一律用 DOCUMENT-ID，绝不写 uid。

ANNOTATIONS 为服务端返回的批注列表，QUEUED 为本地离线队列中待同步的
create 条目列表（plist 列表，见
`seshat-reader-annotation--queued-create-entries'），二者先合并为全量条目
（`seshat-reader-annotation--all-items'，服务端项在前、本地待同步项在后），
再**全量**渲染——单列连续流，不做切片、不显示页脚：本地待同步项带
\"[待同步]\" 标记，并携带各自的
`seshat-reader-annotation-queue-uuid' 属性。

全量条目为空时渲染一行明确提示。

**ETAF 分流**：`seshat-reader-annotation--etaf-p' 为真时先用 ETAF 渲染层
（`seshat-reader-etaf-render-annotations'）渲染卡片列表；渲染层不可用、
加载失败或渲染抛错时回退上面的纯文本渲染（见
`seshat-reader-annotation--render-list-etaf'）。ETAF 路径直接复用上面已
合并好的 ALL-ITEMS（**不再**重复调用 `--etaf-items' 合并一次），把**全量**
条目交给渲染层。两条路径都由
`seshat-reader-sidebar-show' 以 `annotations' 类型统一显示，故面板位置、
高度与 per-kind 记忆不变；条目超出面板高度时由面板**窗口**整体滚动查看。"
  (with-current-buffer (get-buffer-create seshat-reader-annotation-list-buffer-name)
    (let* ((inhibit-read-only t)
           (etaf-mounted (seshat-reader-annotation--etaf-mounted-p))
           (all-items (seshat-reader-annotation--all-items annotations queued)))
      ;; ETAF 已挂载时**不得** `erase-buffer'：ETAF runtime 的节点位置依赖
      ;; 缓冲区既有文本，清空后 `etaf-runtime-flush' 会报「Args out of range」
      ;; 从而整块回退文本渲染（刷新后面板降级）。增量刷新由渲染层自己 flush。
      (unless etaf-mounted
        (erase-buffer))
      ;; 仅首次进入时调用派生 mode，避免每次刷新重复触发 mode hook。
      (unless (derived-mode-p 'seshat-reader-annotation-list-mode)
        (seshat-reader-annotation-list-mode))
      (setq-local seshat-reader-annotation-list-document-id document-id)
      (when uid
        (setq-local seshat-reader-annotation-list-uid uid))
      (setq-local seshat-reader-annotation-list-source source)
      (setq-local seshat-reader-annotation-list-entries annotations)
      (unless (and (seshat-reader-annotation--etaf-p)
                   (seshat-reader-annotation--render-list-etaf
                    all-items document-id source))
        ;; 回退路径：渲染层可能已写入部分文本，故先清空再走文本渲染。
        (erase-buffer)
        (if (null all-items)
            (insert "（该文档没有批注）\n")
          (dolist (item all-items)
            (seshat-reader-annotation--insert-entry
             item
             (plist-get item :uuid)))))
      (goto-char (point-min)))
    ;; 列表缓冲区在 `*Seshat Annotations*' 中渲染完毕后，经信息面板统一入口
    ;; 显示（启用面板时投到底部弹出窗口，禁用时 `show' 内部退回
    ;; `pop-to-buffer'）。此处 `(current-buffer)' 即列表缓冲区本身。
    (seshat-reader-sidebar-show (current-buffer) 'annotations t)))

(defun seshat-reader-annotation--refresh-list (document-id &optional source uid)
  "按文档标识 DOCUMENT-ID 重新拉取批注并刷新列表缓冲区.
DOCUMENT-ID 为**显示标识（doc-id）**；SOURCE 为发起列表的 seshat-reader
文档缓冲区（可为 nil）；UID 为服务端权威身份（拉取、删除等 API 操作用
它）。UID 为 nil 时取列表缓冲区的 buffer-local
`seshat-reader-annotation-list-uid'——ETAF 渲染层的刷新路径
（`seshat-reader-etaf--refresh-list'）只传前两个参数，它复用上一次完整
渲染写入的值；两者都取不到时不猜身份：只展示本地待同步条目并提示。

服务端批注渲染在前，本地离线队列中尚未同步的 create 条目以 \"[待同步]\"
追加在后（见 `seshat-reader-annotation--render-list'）——本地项只读队列
文件，不受拉取结果影响。

拉取成功（返回的不是失败哨兵）时渲染服务端项与本地项，随后在
`seshat-reader-annotation-queue-auto-sync' 非 nil 且队列非空时机会性地
尝试一次队列同步；同步发生在本轮渲染之后，故本轮不刷新、已同步条目仍会
显示到下次刷新为止（这样避免了渲染—同步—再渲染的递归与竞态）。

拉取失败（返回 `seshat-reader-annotation--fetch-error' 哨兵）时**不**
清空列表：仍渲染本地待同步条目并提示当前只显示本地批注；队列也为空时只
提示当前没有可显示的批注。两种情形都不会抛出 backtrace。"
  (let* ((uid (or uid
                  (and (get-buffer seshat-reader-annotation-list-buffer-name)
                       (buffer-local-value
                        'seshat-reader-annotation-list-uid
                        (get-buffer seshat-reader-annotation-list-buffer-name)))))
         (queued (seshat-reader-annotation--queued-create-entries uid))
         (result (if uid
                     (seshat-reader-annotation--fetch uid)
                   seshat-reader-annotation--fetch-error)))
    (if (eq result seshat-reader-annotation--fetch-error)
        (progn
          (seshat-reader-annotation--render-list document-id source nil queued uid)
          (cond
           ((null uid)
            (message "Seshat Reader annotation: 未知服务端文档身份，本轮不拉取服务端批注。"))
           (queued
            (message "Seshat Reader annotation: 批注列表（离线）仅显示本地待同步批注 %d 条"
                     (length queued)))
           (t
            (message "Seshat Reader annotation: 当前没有可显示的批注（本地也没有待同步条目）。"))))
      (seshat-reader-annotation--render-list document-id source result queued uid)
      ;; 服务端拉取成功：顺手把批注矩形同步到页面高亮。数据全部来自本轮已经
      ;; 拿到手的 RESULT 与本地队列 QUEUED，不新增任何请求；SOURCE 不是本文档
      ;; 的 reader 缓冲区时跳过（防止把 A 文档的批注画到 B 文档上）。
      (when (seshat-reader-annotation--source-document-p source document-id)
        (seshat-reader-annotation--apply-highlights
         (seshat-reader-annotation--all-items result queued)))
      (seshat-reader-annotation--maybe-sync-queue))))

;;; 跳页与删除

(defun seshat-reader-annotation-list-goto ()
  "跳转到当前行批注所在的页面.
页码取自该行的 `seshat-reader-annotation-page' 文本属性（**1-based**），
跳转复用 `seshat-reader-goto-page'。原始文档缓冲区已关闭、不再是
seshat-reader 视图、页码缺失或跳转抛错时只 `message' 提示，不抛出
backtrace。"
  (interactive)
  (let ((page (get-text-property (line-beginning-position)
                                 'seshat-reader-annotation-page))
        (source (buffer-local-value 'seshat-reader-annotation-list-source
                                    (current-buffer))))
    (cond
     ((null page)
      (message "Seshat Reader annotation: 当前行没有可跳转的页码。"))
     ((not (buffer-live-p source))
      (message "Seshat Reader annotation: 原始文档缓冲区已不存在，请重新打开文档后再跳页。"))
     ((not (eq (buffer-local-value 'major-mode source) 'seshat-reader-mode))
      (message "Seshat Reader annotation: 原始缓冲区已不是 seshat-reader 视图，无法跳页。"))
     (t
      (pop-to-buffer source)
      (condition-case err
          (seshat-reader-goto-page page)
        (error
         (message "Seshat Reader annotation: 跳转到第 %d 页失败：%s"
                  page (error-message-string err))))))))

(defun seshat-reader-annotation-list-delete ()
  "删除当前行对应的批注，成功后刷新列表.
按当前行的属性分两条路径：

- 行上有 `seshat-reader-annotation-queue-uuid'（即本地待同步项，见
  `seshat-reader-annotation--insert-entry'）时，用
  `seshat-reader-annotation-queue-remove' 按该 UUID 从本地队列取消并重渲染
  列表——**不发起任何 HTTP**；重渲染复用已缓存的服务端项
  （`seshat-reader-annotation-list-entries'），因此也不会触网。提示按
  `seshat-reader-annotation-queue-remove' 的返回值区分：返回 t 时 `message'
  「已取消本地待同步批注」，返回 nil（该条目已不在队列，可能已同步移除）时
  `message' 「该批注已不在本地队列（可能已同步）」；两种情况都刷新列表。
- 行上没有该属性时，取其 `seshat-reader-annotation-id' 交给
  `seshat-reader-annotation-delete' 删除服务端批注，成功后刷新列表。

当前行既无 UUID 也无批注 `id' 时只 `message' 提示。"
  (interactive)
  (let ((uuid (get-text-property (line-beginning-position)
                                 'seshat-reader-annotation-queue-uuid))
        (id (get-text-property (line-beginning-position)
                               'seshat-reader-annotation-id))
        (document-id (buffer-local-value 'seshat-reader-annotation-list-document-id
                                         (current-buffer)))
        (uid (buffer-local-value 'seshat-reader-annotation-list-uid
                                 (current-buffer)))
        (source (buffer-local-value 'seshat-reader-annotation-list-source
                                    (current-buffer))))
    (cond
     (uuid
      (seshat-reader-annotation--require-queue)
      (if (seshat-reader-annotation-queue-remove uuid)
          (message "Seshat Reader annotation: 已取消本地待同步批注")
        (message "Seshat Reader annotation: 该批注已不在本地队列（可能已同步），列表将刷新"))
      (seshat-reader-annotation--render-list
       document-id source
       (buffer-local-value 'seshat-reader-annotation-list-entries
                           (current-buffer))
       (seshat-reader-annotation--queued-create-entries uid)
       uid))
     ((null id)
      (message "Seshat Reader annotation: 当前行没有关联批注，无法删除。"))
     (t
      (when (seshat-reader-annotation-delete id uid)
        (seshat-reader-annotation--refresh-list document-id source uid))))))

(defun seshat-reader-annotation-delete (id &optional uid)
  "删除编号为 ID 的批注并报告结果.
ID 可为整数或字符串（服务端列表返回的 `id' 可能是整数），发送前一律用
`(format \"%s\" id)' 字符串化，以统一整数/字符串入参。成功时 `message'
报告已删除并返回 t。

UID 为可选的文档服务端身份：删除请求按批注 `id' 定位，并不需要它；它只
随离线队列条目的 `:uid' 一并保存，使队列条目保留文档归属（列表路径会传
`seshat-reader-annotation-list-uid'，交互调用可为 nil）。

失败（非 2xx 或请求异常）时**不**报错：把 `(:action delete :id ID)' 条目
存入本地离线队列（ID 保留入参的原始类型，序列化与同步侧用
`(format \"%s\" id)'），`message' 提示「删除操作已存入本地待同步队列
（N 条待同步）」，并返回 nil。稍后由
`seshat-reader-annotation-queue-sync' 自动同步到服务端。"
  (interactive "s批注 ID: ")
  (let ((id-string (format "%s" id)))
    (condition-case nil
        (if (seshat-rest-delete-annotation id-string)
            (progn
              (message "Seshat Reader annotation: 已删除批注 %s。" id-string)
              t)
          (seshat-reader-annotation--enqueue
           (list :action 'delete :id id :uid uid)
           "删除操作")
          nil)
      (error
       (seshat-reader-annotation--enqueue
        (list :action 'delete :id id :uid uid)
        "删除操作")
       nil))))

(define-derived-mode seshat-reader-annotation-list-mode special-mode "Seshat-Annotations"
  "Major mode for the `*Seshat Annotations*' buffer.

Keybindings:
\\{seshat-reader-annotation-list-mode-map}

`RET' 跳转到当前行批注所在页面，`d' 删除当前行批注，`j'/`k' 上下移动。
列表为全量单列连续流（不分页），条目超出面板高度时滚动面板窗口查看。

body 里调 `seshat-reader--disable-evil'：evil 的 normal state 会经
`emulation-mode-map-alists' 压在本 mode 的键表之前，把 `j'/`k' 抢走；关闭后
本文件绑定的 `j'/`k'/`RET'/`d'/`q' 才真正生效（evil 是软依赖，未安装时
helper 是空操作）。"
  (setq-local truncate-lines t)
  (seshat-reader--disable-evil))

(define-key seshat-reader-annotation-list-mode-map (kbd "RET")
            #'seshat-reader-annotation-list-goto)
(define-key seshat-reader-annotation-list-mode-map (kbd "d")
            #'seshat-reader-annotation-list-delete)
;; vim 风格的逐行移动：列表 buffer 已关闭 evil（见 mode body），这两个键由
;; 本文件直接绑定，语义即 Emacs 原生的 `next-line' / `previous-line'。
(define-key seshat-reader-annotation-list-mode-map (kbd "j") #'next-line)
(define-key seshat-reader-annotation-list-mode-map (kbd "k") #'previous-line)
;; 面板内 `q' 统一走 `seshat-reader-sidebar-quit'（只关本面板所在 kind），与目录
;; 面板、译文面板的 `q' 一致。`special-mode' 自带的 `q'（`quit-window'）只删窗口，
;; 不走 sidebar 的 per-kind 尺寸记忆与 buffer 记忆，三面板行为会不一致。
(define-key seshat-reader-annotation-list-mode-map (kbd "q")
            #'seshat-reader-sidebar-quit)

(defun seshat-reader-annotation-list ()
  "列出当前文档的全部批注.
从当前缓冲区的 variable `buffer-file-name' 派生两个身份：显示标识
（doc-id，供列表与 `seshat:' 链接）与服务端权威身份（uid，供拉取/刷新/
删除）；uid 由 `GET /api/resolve' 解析并缓存，文档未在服务端登记时
`user-error' 提示。随后向服务端拉取批注并
渲染到 `*Seshat Annotations*'；每行显示 **1-based** 页码与正文摘要
（摘要按 `seshat-reader-annotation-list-summary-width' 截断并以 \"…\"
结尾）。服务端批注在前，本地离线队列中待同步的 create 条目以
\"[待同步]\" 追加在后。

列表缓冲区中 `RET' 跳转到该行批注所在页面（复用
`seshat-reader-goto-page'），`d' 删除该行批注并刷新列表——服务端项走
`seshat-reader-annotation-delete'，本地 \"[待同步]\" 项则由
`seshat-reader-annotation-list-delete' 直接取消本地条目、不发 HTTP。列表
**全量**渲染为单列连续流（不分页、无页脚）：条目超出面板高度时滚动面板
窗口查看。这些键经
`seshat-reader-annotation-list-mode' 的 local keymap 绑定，不依赖
evil；在 evil 环境下它们可能被 evil 接管（evil 会覆盖 `special-mode' 系的
这几个键），需要用户在配置侧处理。

服务端暂时拉不到时**不**报错也不清空列表：仍展示本地待同步条目并提示
「（离线）仅显示本地待同步批注 N 条」；本地也为空时只提示当前没有可显示
的批注。当前缓冲区没有关联文件时 `message' 提示，不会抛出 backtrace。"
  (interactive)
  (let ((file (buffer-file-name)))
    (if file
        ;; 双值：doc-id 供显示与 `seshat:' 链接，uid 供 API（拉取/删除/刷新）
        (seshat-reader-annotation--refresh-list
         (seshat-reader-annotation--doc-id
          file (seshat-reader-annotation--quiet-p file))
         (current-buffer)
         (seshat-reader-annotation--uid file))
      (message "Seshat Reader annotation: 当前缓冲区没有关联文件，无法确定文档标识。"))))

(defun seshat-reader-annotation-toggle ()
  "批注列表面板开合：已显示则关闭，否则打开列表.
「已显示」由 `seshat-reader-sidebar-panel-visible-p' 判定（**承载无关**：窗口
与 child frame 都算），关闭走 `seshat-reader-sidebar--toggle-kind'——只关
`annotations' 这一 kind，目录与译文/解释面板不受影响，且关闭前捕获尺寸、记住
buffer 供 `M-o' 重开。未显示时原样调用 `seshat-reader-annotation-list'（拉取并
渲染列表，行为、错误提示与离线降级完全不变）。

批注列表每次「打开」都会重新拉取渲染（`seshat-reader-annotation-list' 的语义，
delete/refresh 后需要重绘），所以本命令**不是**用记忆 buffer 重开的轻量路径：
这与 `seshat-reader-sidebar--toggle-kind' 的「重开上次 buffer」分支不同，后者
只在 `M-o' 全部开合时才用到。"
  (interactive)
  (if (seshat-reader-sidebar-panel-visible-p 'annotations)
      (seshat-reader-sidebar--toggle-kind 'annotations)
    (seshat-reader-annotation-list)))

(with-eval-after-load 'seshat-reader
  (define-key seshat-reader-mode-map (kbd "C-c C-a") #'seshat-reader-annotation-create)
  (define-key seshat-reader-mode-map (kbd "C-c C-l") #'seshat-reader-annotation-toggle)
  ;; 无前缀的 vim 风格别名（与上面的 `C-c' 前缀键双绑，前缀键不删）：
  ;; `a' 建批注、`m' 批注列表面板开合。
  (define-key seshat-reader-mode-map (kbd "a") #'seshat-reader-annotation-create)
  (define-key seshat-reader-mode-map (kbd "m") #'seshat-reader-annotation-toggle)
  ;; C-c C-h 在 `seshat-reader-mode-map' 中未被占用（已占用：C-a / C-l /
  ;; C-r / C-o / C-t / C-e），用于按缓存重投页面高亮。
  (define-key seshat-reader-mode-map (kbd "C-c C-h")
              #'seshat-reader-annotation-refresh-highlights))

(provide 'seshat-reader-annotation)
;;; seshat-reader-annotation.el ends here
