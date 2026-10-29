;;; seshat-library.el --- 远端书库清单与按需取书（ondemand 根） -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seshat contributors

;; Author: Seshat contributors
;; Keywords: data, tools
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

;; 本模块是「书架 / 按需取书」的**数据层**（UI 见后续任务）：为 `ondemand'
;; 模式的根（书库）提供「列远端清单 → 判本地三态 → 按需下载」三件事，不定义
;; 任何交互命令、不碰 buffer。
;;
;; 为什么需要它：同步引擎对 `ondemand' 根只做两件事——首同步把 `uid ↔ (root,
;; path)' 登记进状态库（不下载），以及在 `changes' 事件抵达且本地缺文件时下载。
;; 于是「从没下载过的书」在 Emacs 里没有任何入口可取，「本地副本过期」也没有
;; 显式刷新手段。本模块补的就是这两个缺口。
;;
;; 三条不变量（改动本模块时必须保持）：
;;
;; 1. **`ondemand' 根只读**：本模块只发 `GET' 请求（清单 / 元数据 / 文件），
;;    绝不发任何写请求；删除只针对本地副本（在 UI 层落实到 `--local-path' 校验
;;    过的路径上）。服务端对 `ondemand' 根写入本就返回 403，这里不制造撞墙的
;;    机会。
;; 2. **落盘路径一律过 `seshat-sync--local-path'**：服务端下发的相对路径不可信
;;    （一条被篡改的响应就能把文件写到根目录之外），因此不自行拼接路径字符串。
;; 3. **错了降级、不抛错**：网络失败（非 2xx / 传输失败）一律
;;    `display-warning' + 返回 nil，因为清单读取可能被定时器或批量路径调用；
;;    只有「用户配置错误 / 路径越界 / 服务端未登记该 uid」才 `user-error'——那
;;    三种是用户的显式操作需要立刻知道原因的场景（沿用 `seshat-sync' 的错误
;;    契约）。
;;
;; 依赖方向：本模块只依赖基础设施层（`seshat-rest' / `seshat-state'）与引擎层
;; （`seshat-sync'，复用其路径安全校验与游标推进）；`seshat-sync' 不反向依赖
;; 本模块（上层用 `fboundp' 软依赖探测）。`emacs/seshat-reader/**' 同样**不得**
;; require 本模块。
;;
;; **离线优先（M9 T5a）**：清单主源是**本地状态库**（`seshat-state-entries'），
;; 远端 REST 降级为「显式刷新的可选增强 + 落盘缓存」。三层各有一个入口：
;;
;; - `seshat-library--entries-local'：状态库 → item（零网络，主源）；
;; - `seshat-library--entries-cached'：`library-cache.eld' → item（零网络，
;;   覆盖「本地状态库还没登记但远端见过」的书）；
;; - `seshat-library--entries-refresh-remote'：显式刷新，拉远端 → 写缓存 →
;;   返回合并结果（**唯一**会联网的入口，且只发 `GET'）。
;;
;; 三层用 `seshat-library--entries-merge'（纯函数，D1 策略）合成一份清单：
;; 以本地为准，缓存独有的 uid 以 `unregistered' 出现（既不冒充「已下载」，也
;; 不静默丢书）。过滤 / 排序 / 分页全部是**纯函数**（`--filter-items' /
;; `--sort-items' / `--page-count' / `--page-slice'）：不读全局、不写文件、不
;; 联网，因此可以机械判定。
;;
;; **视图层（M9 T5b）**：同一文件后半段是**自建 buffer** 的书架视图
;; （`special-mode' 派生，不用 `tabulated-list-mode'、不用 ETAF）：分页渲染 +
;; 15 键位。打开书架只读本地两层（零网络），只有 `g' 触网。视图层只消费上面的
;; 统一 item 与纯函数，不直接碰状态库 / 缓存文件。
;;
;; **行内封面（M9 T5b-2）**：封面 image 的**唯一构造点**是
;; `seshat-library--make-cover-image'（它自己不查 `display-graphic-p'，能否显示
;; 由 `seshat-library--insert-cover' 判定）；未命中缓存时入 `seshat-covers' 的
;; 串行 idle 队列惰性生成，就绪后只重绘那一行。**I-OOM 不变量**：任一时刻驻留
;; （已构造未 flush）的 image ≤ `seshat-library-page-size'——由「只渲染当前页 +
;; 渲染前释放离开页 + `kill-buffer-hook' 释放全部」保证，改动前先读测试组
;; 「封面集成 + I-OOM 不变量」。

;;; Code:

(require 'cl-lib)
(require 'seshat-covers)
(require 'seshat-log)
(require 'seshat-reads)
(require 'seshat-rest)
(require 'seshat-state)
(require 'seshat-sync)

;; 批注队列在 vendored 包内，且书架只把它当**可选**增强（缺了就少一列），
;; 因此只声明函数签名，不 require（`--pending-count' 在运行时软探测）。
(declare-function seshat-reader-annotation-queue-entries
                  "seshat-reader-annotation-queue" (&optional uid))

(defconst seshat-library--page-limit 2000
  "书库清单每页请求的资源条数.
服务端把 `limit' 夹紧到 [1, 2000]，取上限以减少往返次数——清单要一路翻到
`:has-more' 为 nil，往返次数就是首次打开书架的主要成本。")

(defconst seshat-library--max-pages 500
  "书库清单分页的页数上限（500 页 × 2000 条 = 100 万条，覆盖真实书库）.
上限的作用是**终止条件**而不是性能优化：`:since-mtime' 游标若因服务端异常
（例如 `:has-more' 恒为真）不前进，没有上限就是死循环。达到上限时按「已收集
部分 + 一次警告」返回。")

(defconst seshat-library--uid-regexp "\\`[0-9A-HJKMNP-TV-Z]\\{26\\}\\'"
  "服务端 uid 的权威形态：26 位 Crockford Base32（排除 I / L / O / U）.
字符集取自 keystone 仓 `internal/registry/uid.go' 的 `^[0-9A-HJKMNP-TV-Z]{26}$'。
匹配时必须绑 `case-fold-search' 为 nil（见 `seshat-library--uid-valid-p'）。")

(defgroup seshat-library nil
  "远端书库清单与按需取书（`ondemand' 根）."
  :group 'data
  :prefix "seshat-library-")

(defcustom seshat-library-download-timeout 30
  "单次取书下载的超时秒数；nil 表示不限.
不限时一台挂住的慢服务能让一次取书无限期占住 Emacs 的主线程，因此默认给 30 秒。"
  :type '(choice (const :tag "不限" nil) integer)
  :group 'seshat-library)

(defcustom seshat-library-max-download-bytes (* 512 1024 1024)
  "单次取书允许的最大字节数；nil 表示不限.
超限时不写盘、按失败处理。**两道闸**：先按服务端响应的 `Content-Length' 在
落盘之前判断（不会先把磁盘写满才发现超限）；响应不带该头（chunked 分段响应
是常态）时，落盘后再按**实际文件大小**兜底，超限即删掉刚写的文件——详见
`seshat-rest-download-file' 的 docstring。"
  :type '(choice (const :tag "不限" nil) integer)
  :group 'seshat-library)

(defcustom seshat-library-max-entries 200000
  "书架清单单次刷新允许的最大条目数；nil 表示不限.
这是**DoS 护栏**而不是性能调优：分页上限 `seshat-library--max-pages'（500）乘
每页 `seshat-library--page-limit'（2000）最多 100 万条，一个异常或恶意服务端
可以把 `g'（刷新）拖到长时间无响应。超过本值时**截断并记一条 warn**，不抛错
——书架照常可用，只是这次少列了一些书。

默认 20 万条：真实书库远小于此，而 20 万条的内存与渲染开销已在可接受范围
（实际渲染还有分页）。"
  :type '(choice (const :tag "不限" nil) integer)
  :group 'seshat-library)

(defcustom seshat-library-cache-file
  (expand-file-name "library-cache.eld" "~/.local/share/seshat/")
  "书架清单缓存文件的路径.

默认值为 \"~/.local/share/seshat/library-cache.eld\"（经 `expand-file-name'
展开），与同目录的 \"sync-state.eld\" / \"reads.eld\" /
\"annotation-queue.eld\" 保持同一惯例。

它只缓存**远端清单**（uid / 根 / 路径 / 大小 / mtime），**不缓存**本地三态：
三态由 `seshat-library--state-for' 按当前磁盘事实重算，缓存里的旧状态不可信
（刚下载完的行会一直显示「未下载」）。内容形如
`(:version 1 :saved-at UNIX秒 :items (PLIST ...))'，由
`seshat-library--cache-write' 以**同目录临时文件 + `rename-file'' 原子写入；
删掉本文件即回到「只用本地状态库」的降级形态。"
  :type 'file
  :group 'seshat-library)

(defcustom seshat-library-page-size 30
  "书架每页显示的书目条数（正整数）.
分页本身由 `seshat-library--page-count' / `seshat-library--page-slice' 两个纯
函数计算，本值只是它们的默认页大小；非正整数时按 1 处理（宁可多翻几页，也不
让「除以 0」把整张表打不开）。"
  :type 'integer
  :group 'seshat-library)

(defcustom seshat-library-cover-height 48
  "书架行内封面的显示高度（像素，正整数）.
只影响 `create-image' 的 `:height' 缩放参数，不参与任何构造 / 释放判断：高度改
大改小都只让同一张图显示得更高或更矮，不改变「同时驻留几个 image」这一不变量
（I-OOM）。非正整数时由 `create-image' 自己忽略该参数（按图片原始尺寸显示）。"
  :type 'integer
  :group 'seshat-library)

(defcustom seshat-library-cover-width 36
  "封面区在文本里占用的**像素**宽度，用于推算占位文本的列数.
`create-image' 只按 `seshat-library-cover-height' 等比缩放，实际宽度取决于源图
长宽比；而 buffer 里真正占据列数的是 `insert-image' 的 STRING 参数（即占位文
本）。两者对不齐时翻页会让整列文字左右跳，因此这里用一个固定的像素宽度经
`seshat-library--cover-columns' 折算成列数，image 与占位分支插入**同一个**字符
串，列数天然一致。

改这个值等于改「封面区多宽」；它不影响 I-OOM（列宽与 image 个数无关）。"
  :type 'integer
  :group 'seshat-library)

(defconst seshat-library--cache-version 1
  "书架清单缓存的数据版本号.
`:version' 字段恒为此值；读到的版本不等时整份缓存按「不可用」处理（返回 nil
并记一条 warn 日志，**不删文件**——用户可能只是降级跑了一次旧版本）。将来升级
数据形状时应同时提升此常量并在 `seshat-library--entries-cached' 内做迁移。")

(defconst seshat-library--pending-feature 'seshat-reader-annotation-queue
  "提供「按 uid 查待同步批注」的模块名（软依赖）.
`seshat-library--pending-index' 用 `featurep' 守卫（**不 `require'**）：该模块
在 vendored 包内、且书架只把它当可选增强（缺了就少一列）。

**为什么绝不能 `require'**：该模块顶层会在 `seshat-reader-annotation-queue-auto-sync'
非 nil（默认即非 nil）时立刻注册一个 300 秒的自动同步定时器——打开书架（一个
只读视图）就会点起后台**联网**同步，改变用户运行态。与
`seshat-status--pending-annotations' 的「只查 `featurep'」口径必须一致。
模块未加载时 `:pending' 为 nil（UI 显示「—」），绝不主动加载它。

测试可把它绑到不存在的 feature 上验证降级路径。")

;;; 根与远端清单

(defun seshat-library--ondemand-root-p (root)
  "判断 ROOT 是否为本地配置里 mode 为 \"ondemand\" 的书库根.
查表依据是 `seshat-state-roots' 的三元组 `(TAG DIR MODE)'（经
`seshat-sync--root-entry' 与同步引擎取同一口径）。

为什么它是**安全门**而不是可用性判断：`ondemand' 根只读、取书是它的正常用途；
而 `mirror' 根上的 uid 属于用户自己正在编辑的笔记——服务端清单里若混入一个
`mirror' 根的 uid，书架就把「覆盖 / 删除本地副本」暴露给了用户未提交的笔记。
因此 ROOT 非字符串、未配置、或 MODE 不是字面量 \"ondemand\" 时一律返回 nil
（失败方向安全）。"
  (let ((entry (seshat-sync--root-entry root)))
    (and (consp entry) (equal "ondemand" (nth 2 entry)))))

(defun seshat-library--uid-valid-p (uid)
  "判断 UID 是否形如服务端 uid（26 位 Crockford Base32，**大小写敏感**）.
uid 会被拼进 `GET /api/resources/%s'（`seshat-rest-get-resource' 的 docstring
假设「uid 只含 Crockford 字符、无需 URL 编码」），因此形态校验是安全边界：
不校验就能用 `/`、`?`、`..` 之类字符构造同源 URL 注入。

必须绑 `case-fold-search' 为 nil——`string-match-p' 默认大小写不敏感，`[A-Z]'
会连小写字母一起匹配，小写 uid 会被误判合法。UID 非字符串时返回 nil。"
  (and (stringp uid)
       (let ((case-fold-search nil))
         (string-match-p seshat-library--uid-regexp uid))))

(defun seshat-library--roots ()
  "返回 `seshat-state-roots' 中模式为 \"ondemand\" 的根，元素保持 `(TAG DIR MODE)' 原形.

只做筛选，**不做任何归一化或去重**：调用方拿到的是用户配置里的原值，因此可以
据 `DIR' 为 nil / 空串这一事实给出「根未配置目录」的可见提示——所以这类根
**保留**在返回值里，不被静默丢弃（丢弃会让「配置错了」表现成「书库是空的」，
更难排查）。`MODE' 不是字面量 \"ondemand\"（含大小写不同、`:ondemand' 符号、
nil 等）的根一律不返回。

元素不是 proper list（畸形配置）时跳过，不用 `nth' 直接索引：`nth' 对非列表
参数会抛错，而书架是「打开就该看见东西」的界面，不该被一条坏配置卡死。

本函数**不碰网络、不碰磁盘**：`ondemand' 根只读，这是纯查表。"
  (let ((roots (seshat-state-roots)))
    (cl-remove-if-not
     (lambda (root)
       (and (consp root) (equal "ondemand" (nth 2 root))))
     roots)))

(defun seshat-library--remote-entries (tag &optional prefix)
  "拉取根 TAG 的远端资源清单（按 `:since-mtime' 一路翻页），返回 item 列表.
PREFIX 为根内路径段前缀，nil 表示整根（服务端按**路径段**匹配，`\"a\"' 命中
`a' 与 `a/b' 但不命中 `ab'）。

分页做法：`GET /api/resources' **没有 offset 分页**，唯一的游标是
`:since-mtime'（语义「mtime >= SINCE」）。因此本函数从 `since' = 0 起循环，每页
请求 2000 条，`has-more' 为真时用**既有已测试函数**
`seshat-sync--next-since-mtime' 推进游标——复用而不自己实现跳秒逻辑：该函数已
处理三种退化（末项 mtime 非数字、同秒超页、空页但仍 has-more），另写一份必然
与它漂移，而首同步建索引依赖同一口径。

**同秒超页是已知代价**：同一秒内的记录多于一页时，`since = mtime' 会反复取到
同一批记录（死循环），只能前进到 `(1+ mtime)'，该秒剩余记录被跳过。因此本函数
在**真正命中这一成因**时提示一次「清单可能不完整」——判据写死为「本页 `items'
非空**且**末项 `:mtime' 不大于本次请求的 `:since-mtime'」。另两种退化成因
（`items' 为空但 `has-more' 为真、末项 mtime 非数字）**不提示**：它们说明服务端
响应异常，与「同秒超页」不是同一件事，提示只会误导用户。整次调用最多提示一次
（后续页不再重复刷）。

失败契约：任一分页返回非 2xx（含传输失败导致的 `:status' 为 nil）即
`display-warning' 一次并返回 nil，**不重试、不返回半份清单**——半份清单配上
「已下载 / 未下载」的判定会误导用户去取一本其实已在远端的书；全 nil 让调用方
（UI）显式提示「清单读取失败」。

分页页数上限为 `seshat-library--max-pages`：达到上限时 `display-warning' 一次并
返回**已收集部分**（不是 nil）——上限的用途是给「游标不前进」的异常服务端一个
终止条件，能收集到的部分仍有价值；无限翻页会让书架永久卡死。

累积用 `push' + 收尾 `nreverse'（O(n)），不逐页 `append'（O(n²)）：100 万条
的清单在 O(n²) 下光拼接就是几十秒。`nreverse' 之前返回值保持服务端顺序。"
  (let ((since 0)
        (entries nil)
        (pages 0)
        (notified nil)
        (done nil)
        (failed nil))
    (while (not done)
      (let* ((response (seshat-rest-list-resources
                        :root tag
                        :prefix prefix
                        :limit seshat-library--page-limit
                        :since-mtime since))
             (status (plist-get response :status)))
        (cond
         ((not (and (integerp status) (>= status 200) (< status 300)))
          (display-warning
           'seshat-library
           (format "书库清单：根 %s 请求失败（状态 %S%s），清单不可用"
                   tag status
                   (let ((err (plist-get response :error)))
                     (if err (format "，%s" err) "")))
           :warning)
          (setq failed t)
          (setq done t))
         (t
          (let* ((items (plist-get response :items))
                 (has-more (plist-get response :has-more))
                 (last-mtime (plist-get (car (last items)) :mtime)))
            (dolist (item items)
              (push item entries))
            (setq pages (1+ pages))
            (when (and items
                       (not notified)
                       (numberp last-mtime)
                       (<= last-mtime since))
              (setq notified t)
              (message "书库清单可能不完整（同秒记录超页）：根 %s 的 mtime %s 处只能前进一秒"
                       tag last-mtime))
            (cond
             ((not has-more)
              (setq done t))
             ((>= pages seshat-library--max-pages)
              (display-warning
               'seshat-library
               (format "书库清单超过 %d 页上限，已截断（根 %s）"
                       seshat-library--max-pages tag)
               :warning)
              (setq done t))
             (t
              (setq since (seshat-sync--next-since-mtime since items)))))))))
    (unless failed (nreverse entries))))

(defun seshat-library--collect (&optional roots)
  "汇总 ROOTS（默认 `seshat-library--roots'）的远端清单，返回 item 列表.
对每个根调 `seshat-library--remote-entries' 后按根顺序拼接，元素保持服务端原样
（`:root' **不再**被覆盖成请求的 tag，见下）。

这是**远端清单的聚合器**，也是本模块唯一会批量联网的取数函数；离线数据层
（`seshat-library--entries-local' / `--entries-cached'）不经过它，只有显式刷新
`seshat-library--entries-refresh-remote' 才用——后者需要它顺带做的两道安全校验
（见下），因为校验结果会被落盘缓存。

两种根被跳过，但语义不同，不要混为一谈：

- **DIR 为空**（`nil' / 空串）：根配了却没有本地目录，无法定位落点，因此**不拉
  清单**，只 `message' 提示一次。这类根是配置问题，不是故障，所以提示而非警告。
- **拉了但返回 nil**（网络失败 / 空根）：只在**该根**失败时跳过并继续下一个根，
  绝不中断汇总——一根拉不动不该让整个书架打不开。失败与否由
  `seshat-library--remote-entries' 自己 `display-warning'，这里不重复报。

每一行还要过两道**安全校验**，不合格即丢弃（每次调用最多 `display-warning' 一次，
避免一条坏响应刷满 `*Warnings*`）：

1. **uid 形态**：必须是 26 位 Crockford Base32（见 `seshat-library--uid-valid-p'）。
   uid 会被拼进 `GET /api/resources/%s'，形态不合法就等于给同源 URL 注入留门。
2. **根一致**：服务端回包的 `:root' 必须与请求的 tag 一致。为什么不再「覆盖成
   请求的 tag」——「根」列同时是操作目标（`RET' / `u' / `d' 都按 uid 定位），
   让显示值与实际归属分叉，等于允许一行显示在 `books' 下而实际指向 `notes'。"
  (let ((roots (or roots (seshat-library--roots)))
        (warned nil)
        (result nil))
    (dolist (root roots)
      (let ((tag (nth 0 root))
            (dir (nth 1 root)))
        (cond
         ((or (not (stringp dir)) (string-empty-p dir))
          (message "根 %s 未配置本地目录，无法取书" tag))
         (t
          (dolist (item (seshat-library--remote-entries tag))
            (let ((uid (and (consp item) (plist-get item :uid)))
                  (item-root (and (consp item) (plist-get item :root))))
              (cond
               ((not (seshat-library--uid-valid-p uid))
                (unless warned
                  (setq warned t)
                  (display-warning
                   'seshat-library
                   (format "书库清单含形态不合法的 uid（%S），已丢弃该行" uid)
                   :warning)))
               ((not (equal tag item-root))
                (unless warned
                  (setq warned t)
                  (display-warning
                   'seshat-library
                   (format "书库清单的根与请求不一致（请求 %s，响应 %S），已丢弃该行"
                           tag item-root)
                   :warning)))
               (t
                (push item result)))))))))
    (nreverse result)))

;;; 本地三态

(defun seshat-library--local-file (root path)
  "返回 ROOT 根下相对路径 PATH 的本地绝对路径；无法安全定位时返回 nil.
路径一律「状态库 → `seshat-sync--root-dir' → `seshat-sync--local-path'」，
**不**拿调用方给的 `:path' 自己拼：本地目录的对应关系只由
`seshat-sync-roots' 说得清，且越界校验必须在同一处（安全底线）。根未配置
目录、或路径越界时返回 nil，**不报错**——判状态不该成为会抛错的操作。"
  (let* ((root-dir (and (stringp root) (seshat-sync--root-dir root)))
         (local (and root-dir
                     (stringp path)
                     (seshat-sync--local-path root-dir path))))
    local))

(defun seshat-library--state-from-location (location)
  "按 LOCATION（`(ROOT . PATH)' 或 nil）判定三态，返回 `downloaded' /
`missing' / `unregistered' 之一.
LOCATION 为 nil → `unregistered'；否则按 `seshat-library--local-file' 拼出本地
路径并看文件是否在盘上。这是三态判定的**唯一实现**，`--state-for' 与
`--item-from-state'（手上已有活条目，无需再反查）都调它，因此两条路径不可能
漂移。"
  (if (null location)
      'unregistered
    (let ((local (seshat-library--local-file (car location) (cdr location))))
      (if (and local (file-exists-p local)) 'downloaded 'missing))))

(defun seshat-library--state-for (uid)
  "判定 UID 的本地状态，返回符号 `downloaded' / `missing' / `unregistered' 之一.
这是三态判定的**唯一入口**（实现见 `seshat-library--state-from-location'）：
`seshat-library--local-state'（远端 item）与 `seshat-library--entries-cached'
（统一 item）都走这里，否则两条路径的「已下载」口径迟早漂移。

- `unregistered'：状态库没有该 uid 的 `(ROOT . PATH)'（`seshat-state-path-for-uid'
  返回 nil，含「路径已清」「墓碑」「孤儿」三种情况）；
- `downloaded'：已登记，且按登记的根 / 路径拼出的本地文件**存在**；
- `missing'：其余情况（已登记但本地缺文件）。

判定依据是**状态库登记**而不是调用方给的 `:root' / `:path'：服务端清单（或
缓存文件）里的路径不可信，能落盘的位置只由状态库 + 用户配置决定。

复杂度：`seshat-state-path-for-uid' 是一次 `equal' 线性反查（O(条目数)）。批量
场景（`--entries-local'）因此**不**走本函数，而是把手上的活条目位置直接交给
`seshat-library--state-from-location'，避免逐条反查退化成 O(n²)。

本函数**零网络、零子进程**：三态是本地状态库 + 磁盘的组合。"
  (seshat-library--state-from-location
   (and (stringp uid) (seshat-state-path-for-uid uid))))

(defun seshat-library--local-state (item)
  "判定远端 item 的本地状态，返回符号 `downloaded' / `missing' / `unregistered' 之一.
ITEM 是 `seshat-library--remote-entries' 返回的元素（只需要 `:uid'）；判定口径
全部委托 `seshat-library--state-for'（三态的唯一实现，见其 docstring）。

本函数**零网络**：三态是远端清单 + 本地状态库 + 磁盘的组合，不需要额外请求。"
  (seshat-library--state-for (plist-get item :uid)))

;;; 统一 item 与离线数据层（离线优先，零网络为主）

;; 数据层的**唯一数据形状**是下面这个 plist（视图层只消费它，不直接碰状态库 /
;; 缓存文件）：
;;
;;   (:uid "01J..." :root "books" :path "a/b.epub" :name "b.epub"
;;    :size 12345 :mtime 1700000000 :state downloaded :page 12 :total 300
;;    :percent 4 :pending 2 :source local)
;;
;; `:mtime' 不在最初的设计草案里，但 `--sort-items' 的 `mtime' 键需要它（「最近
;; 阅读 / 最近修改」排序），因此一并纳入。`:page' / `:total' / `:percent' /
;; `:pending' 在取不到时一律为 nil——**不猜**（0 与「没有进度」必须区分开）。

(defun seshat-library--item-name (uid path)
  "返回 item 的显示名：PATH 的文件名部分；PATH 为空时退回 UID.
书名列取 `file-name-nondirectory'，因此不同根下的同名书靠「根」区分。"
  (if (and (stringp path) (not (string-empty-p path)))
      (file-name-nondirectory path)
    uid))

(defun seshat-library--progress (uid)
  "返回 UID 的阅读进度 plist `(:page N :total M :percent P)'；无记录时 nil.
进度来自 `seshat-reads'（本地侧车，零网络）；`:percent' 由
`seshat-reads-percent' 计算——那是既有的唯一实现（含夹紧与除零保护），不在这里
重算一份百分比。"
  (when (stringp uid)
    (let ((entry (seshat-reads-get uid)))
      (when entry
        (list :page (plist-get entry :page)
              :total (plist-get entry :total)
              :percent (seshat-reads-percent entry))))))

(defun seshat-library--pending-index ()
  "读**一次**批注队列文件并按 uid 分组，返回索引 plist；不可用时返回 nil.
索引形状：`(:deletes N :by-uid HASH)'——`:deletes' 是 delete 类条目的总数，
`:by-uid' 是 uid → 该 uid 的（非 delete）条目数。

**为什么是索引而不是逐条计数**：`seshat-reader-annotation-queue-entries' 每次都
`insert-file-contents' + `read' 整个队列文件，逐条调用就是 100 本书 = 100 次
文件 IO（书架每次渲染都付一遍）。批量路径因此必须在循环**外**建一次索引，再
用 `seshat-library--pending-count-in-index' 逐条查。

**为什么 delete 条目单独计**：队列语义里 delete 条目按批注 `id' 定位、不依赖
文档身份，`seshat-reader-annotation-queue-entries' 对**任意** uid 都会包含它们。
所以每本书的待同步数 = 全局 delete 数 + 该 uid 自己的条目数。

守卫用 `featurep'（**不 `require'**，理由见 `seshat-library--pending-feature'）；
读取失败（队列文件损坏）也只记一条 warn 并返回 nil，绝不让书架打不开。"
  (when (and (featurep seshat-library--pending-feature)
             (fboundp 'seshat-reader-annotation-queue-entries))
    (condition-case err
        (let ((entries (seshat-reader-annotation-queue-entries))
              (by-uid (make-hash-table :test #'equal))
              (deletes 0))
          (when (listp entries)
            (dolist (entry entries)
              (if (eq (plist-get entry :action) 'delete)
                  (setq deletes (1+ deletes))
                (let ((uid (plist-get entry :uid)))
                  (when (stringp uid)
                    (puthash uid (1+ (or (gethash uid by-uid) 0)) by-uid)))))
            (list :deletes deletes :by-uid by-uid)))
      (error
       (seshat-log 'warn "书架：读取批注队列失败（%s），待同步列按不可用处理"
                   (error-message-string err))
       nil))))

(defun seshat-library--pending-count-in-index (index uid)
  "从索引 INDEX（`seshat-library--pending-index' 的返回值）里取 UID 的待同步条数.
INDEX 为 nil（模块不可用 / 队列读不出）时返回 nil——nil 是「查不了」，0 是
「查过、确实没有待同步」，两者不能混。UID 非字符串时同样返回 nil。"
  (when (and index (stringp uid))
    (+ (or (plist-get index :deletes) 0)
       (or (gethash uid (plist-get index :by-uid)) 0))))

(defun seshat-library--pending-count (uid)
  "返回 UID 的待同步批注条数；批注队列模块不可用时返回 nil.
**单条查询入口**：内部建一次索引（读一次队列文件）后取值，供零散调用点使用。
批量构造 item 的路径**不要**调它——那会退化成「每本书读一次队列文件」；应改为
循环外调一次 `seshat-library--pending-index'，再把索引交给
`seshat-library--make-item' 的 PENDING 参数。

守卫是 `featurep' 而非 `require'（理由见 `seshat-library--pending-feature'）：
队列模块没加载时返回 nil，UI 显示「—」。"
  (seshat-library--pending-count-in-index (seshat-library--pending-index) uid))

(defconst seshat-library--pending-unset 'seshat-library--pending-unset
  "`seshat-library--make-item' 的 PENDING 参数默认值（哨兵）.
用来区分「调用方没传 PENDING」与「传了 nil」：前者回落到单条查询
（`seshat-library--pending-count'），后者表示「队列模块不可用 / 队列读不出」，
`:-pending' 直接为 nil，不再重复读文件。")

(defconst seshat-library--location-unset 'seshat-library--location-unset
  "`seshat-library--make-item' 的 LOCATION 参数哨兵：「索引里没有这个 uid」.
用来区分三种情况：① 没传 LOCATION（nil）→ 按 uid 反查状态库（单条便利入口）；
② 传了哨兵 → 调用方已建好**完整**位置索引，该 uid 不在索引里，即**未登记**，
`:-state' 直接为 `unregistered'，**不再**逐条线性反查；③ 传了 `(ROOT . PATH)'
→ 按它判三态。

为什么需要这个哨兵：`seshat-library--state-location-index' 是状态库的完整快照
（「有键 = 已登记」「无键 = unregistered」），但 `gethash' 取不到键时同样是 nil，
与「调用方没传位置」无法区分——不区分就会让未登记的绝大多数条目逐条走
`seshat-state-path-for-uid' 的 O(条目数) 反查，整轮刷新退化成 O(n²)（这正是
一次性索引要消灭的开销）。")

(defun seshat-library--make-item (uid root path size mtime source
                                      &optional location pending)
  "构造统一 item plist（数据层唯一数据形状，见本节开头）.
`:name' 由 `seshat-library--item-name' 派生；`:page' / `:total' / `:percent'
现算（都零网络）。SOURCE 标记该 item 来自哪一层（`local' / `cache' /
`remote'）。

`:state' 走三态判定的唯一实现：给了 LOCATION（`(ROOT . PATH)'，调用方手上已有
**活条目**时用）就按它判，否则按 UID 反查状态库（`seshat-library--state-for'）。
批量调用方应当尽量传 LOCATION——反查是 O(条目数)，逐条反查会让整轮枚举退化成
O(n²)。批量路径上「索引里没有该 uid」要传哨兵
`seshat-library--location-unset'（等价于 `unregistered' 且零反查，见其
docstring）。**不接受**调用方直接传状态：缓存里的旧状态不可信。

PENDING 是**循环外建好一次**的批注索引（`seshat-library--pending-index' 的
返回值）。批量路径必须传它：不传就会为每条 item 读一次队列文件（100 本书 =
100 次文件 IO）。传 nil 表示「队列不可用」，`:pending' 即为 nil。"
  (let ((progress (seshat-library--progress uid)))
    (list :uid uid
          :root root
          :path path
          :name (seshat-library--item-name uid path)
          :size size
          :mtime mtime
          :state (cond
                  ((eq location seshat-library--location-unset) 'unregistered)
                  (location (seshat-library--state-from-location location))
                  (t (seshat-library--state-for uid)))
          :page (plist-get progress :page)
          :total (plist-get progress :total)
          :percent (plist-get progress :percent)
          :pending (if (eq pending seshat-library--pending-unset)
                       (seshat-library--pending-count uid)
                     (seshat-library--pending-count-in-index pending uid))
          :source source)))

(defun seshat-library--item-from-state (uid entry &optional pending)
  "把状态库条目 ENTRY（uid UID）转成统一 item，`:source' 为 `local'.
`:size' 优先取**本地文件**的 `file-attributes'（已下载时才是权威大小；状态库里
的 `:size' 是上次同步的基线，可能过期），取不到时退回 ENTRY 的 `:size'（可能是
nil——「不知道大小」不等于 0）。

ENTRY 来自 `seshat-state-entries'（只含活条目），它的 `(ROOT . PATH)' 就是
`seshat-state-path-for-uid' 会返回的值，因此直接把位置交给判态函数——不再逐条
反查状态库（那会让整轮枚举 O(n²)）。

PENDING 为循环外建好一次的批注索引（见 `seshat-library--make-item'）。"
  (let* ((root (plist-get entry :root))
         (path (plist-get entry :path))
         (local (seshat-library--local-file root path))
         (attrs (and local (file-exists-p local) (file-attributes local)))
         (size (or (and attrs (nth 7 attrs)) (plist-get entry :size))))
    (seshat-library--make-item uid root path size (plist-get entry :mtime) 'local
                               (cons root path) pending)))

(defun seshat-library--item-from-remote (entry &optional location pending)
  "把远端清单条目 ENTRY（`--remote-entries' 的元素）转成统一 item，`:source' 为 `remote'.
`:size' / `:mtime' 取服务端值（远端清单是这两项在「未下载」时唯一的来源）。

LOCATION 为 `(ROOT . PATH)'（来自调用方循环外建好的 uid 索引）或 nil；给了它
就**不再**按 uid 线性反查状态库（`seshat-library--state-for' 是 O(条目数) 的
`equal' 查找，对远端清单逐条调用就是 O(n²)）。批量路径上「索引里没有该 uid」
必须传哨兵 `seshat-library--location-unset'（由
`seshat-library--indexed-location' 产出），否则未登记的条目仍会逐条反查。
PENDING 同理：循环外建一次的批注索引。"
  (seshat-library--make-item (plist-get entry :uid)
                             (plist-get entry :root)
                             (plist-get entry :path)
                             (plist-get entry :size)
                             (plist-get entry :mtime)
                             'remote location pending))

(defun seshat-library--item-from-cache (item &optional pending locations)
  "把缓存里的 ITEM 归一化成统一 item，`:source' 为 `cache'.
`:state' **重算**（`seshat-library--make-item' 统一走 `--state-for'）：缓存文件
里的 state 只反映写入时刻的磁盘事实，直接拿来用会让「刚下载完的书仍显示未下载」。
`:name' / `:size' / `:mtime' 沿用缓存值（它们是远端事实，本地无从重算）。

PENDING 为循环外建好一次的批注索引（见 `seshat-library--make-item'）。
LOCATIONS 为循环外建好一次的位置索引（`seshat-library--state-location-index'）：
给了它就不再逐条反查状态库，`--make-item' 按索引判态（索引与反查口径等价）。
**注意**判态依据仍是状态库登记，不是缓存里的 `:root' / `:path'。"
  (let ((uid (plist-get item :uid))
        (root (plist-get item :root))
        (path (plist-get item :path)))
    (let ((fresh (seshat-library--make-item
                  uid root path (plist-get item :size) (plist-get item :mtime)
                  'cache
                  (seshat-library--indexed-location locations uid)
                  pending)))
      ;; `:name' 允许沿用缓存值（路径相同时派生结果一致；路径为空时缓存可能存了
      ;; 旧显示名），但 uid 非字符串的脏条目直接丢弃由调用方负责。
      (if (plist-get item :name)
          (plist-put fresh :name (plist-get item :name))
        fresh))))

;;; 三层取数（local / cache / remote）

(defun seshat-library--entries-local ()
  "从**本地状态库**枚举书目，返回统一 item 列表（零网络、零子进程）.
来源是 `seshat-state-entries'（只含活条目：`:path' 非 nil 且无 `:orphan' /
`:deleted-at'），因此「本地知道的书」一本书都不会漏——这正是离线可用的前提。

**只保留 `ondemand' 根**：`seshat-library--ondemand-root-p' 是安全门而不是可用
性判断。`mirror' 根上的 uid 是用户自己正在编辑的笔记，把它们列进书架就等于把
「覆盖 / 删除本地副本」暴露给未提交的笔记。

顺序保持状态库 `:uids' 的顺序（`seshat-state-entries' 已保证），调用方据此
得到稳定列表——稳定顺序是分页的前提，否则翻页会出现重复 / 漏项。

**批注索引在循环外建一次**（`seshat-library--pending-index'）：它读的是整个
队列文件，逐条构造 item 时再读就是 100 本书 = 100 次文件 IO。"
  (let ((pending (seshat-library--pending-index))
        result)
    (dolist (cell (seshat-state-entries))
      (let* ((uid (car cell))
             (entry (cdr cell))
             (root (plist-get entry :root)))
        (when (and (stringp uid) (seshat-library--ondemand-root-p root))
          (push (seshat-library--item-from-state uid entry pending) result))))
    (nreverse result)))

(defun seshat-library--cache-read ()
  "读 `seshat-library-cache-file' 并返回其 plist 内容；不可用时返回 nil.
不可用包含：文件不存在、读不出来、内容不是 plist、`:version' 与
`seshat-library--cache-version' 不等。后三种一律 `seshat-log' 记一条 warn 并
返回 nil，**不抛错、不删文件**——缓存是可再生的派生数据，坏了就退回「只用状态
库」，让用户看得见原因即可；删掉文件反而让排查线索消失。

读取用 `read'（不是 `eval'）：缓存文件按**纯数据**读取，并且**显式绑定
`read-eval' 为 nil**——旧版 Emacs 上这是禁用 `#.' 读语法的硬保护，Emacs 32 已
移除该变量（`#.' 直接报错），绑定时是无害空操作。这样「不执行缓存里的代码」
是**本函数显式保证**的，而不是依赖当前 Emacs 版本的默认行为或
`Package-Requires'（后者只在 package.el 路径生效）。

顶层 plist **之后不得再有内容**：多出一个 form 说明文件被拼接或截断过，与
`seshat-reads--read-file' 同口径，一律按坏缓存降级。"
  (let ((file (expand-file-name seshat-library-cache-file)))
    (if (not (file-exists-p file))
        nil
      (let ((data (condition-case err
                      (with-temp-buffer
                        (insert-file-contents file)
                        (goto-char (point-min))
                        (let ((read-eval nil))  ; 见 docstring：旧版硬保护，32+ 空操作
                          (ignore read-eval)    ; 32+ 里它是普通词法变量：读一次以免编译警告
                          (prog1 (read (current-buffer))
                            (skip-chars-forward " \t\n\r")
                            (unless (eobp)
                              (error "缓存文件顶层 plist 之后还有多余内容：%S"
                                     (buffer-substring-no-properties
                                      (point)
                                      (min (point-max) (+ (point) 40))))))))
                    (error
                     (seshat-log 'warn "书架缓存 %s 无法解析（%s），按空缓存继续"
                                 file (error-message-string err))
                     nil))))
        (cond
         ((null data) nil)
         ((not (and (listp data) (keywordp (car-safe data))))
          (seshat-log 'warn "书架缓存 %s 不是 plist，按空缓存继续" file)
          nil)
         ((not (equal seshat-library--cache-version (plist-get data :version)))
          (seshat-log 'warn "书架缓存 %s 版本不符（%S ≠ %S），按空缓存继续"
                      file (plist-get data :version)
                      seshat-library--cache-version)
          nil)
         ((not (or (null (plist-get data :items))
                   (listp (plist-get data :items))))
          ;; `:items' 是向量 / 字符串时不能 `dolist'（会抛 `wrong-type-argument'）：
          ;; 坏缓存必须降级成 nil，不能让「打开书架」失败。
          (seshat-log 'warn "书架缓存的 :items 不是列表（%S），按空缓存继续"
                      (type-of (plist-get data :items)))
          nil)
         (t data))))))

(defun seshat-library--entries-cached ()
  "从**清单缓存**读回书目，返回统一 item 列表（零网络）.
缓存的价值是覆盖「远端见过、但本地状态库还没登记」的书（例如换机后首次打开
书架、或状态库损坏后重建中），它们以 `unregistered' 出现而不是消失。

`:source' 一律置 `cache'，`:state' 一律**重算**（缓存里的状态不可信，见
`seshat-library--item-from-cache'）。缓存不可用（缺失 / 坏文件 / 版本不符）时
返回 nil，由 `seshat-library--cache-read' 记 warn。

**批注索引同样在循环外建一次**：与 `--entries-local' 共用
`seshat-library--pending-index'，避免每条 item 各读一遍队列文件。**位置索引也
在循环外建一次**（`seshat-library--state-location-index'）：判 `:state' 时逐条
反查状态库同样是 O(n²)。"
  (let* ((data (seshat-library--cache-read))
         (pending (seshat-library--pending-index))
         (locations (seshat-library--state-location-index))
         result)
    (dolist (item (plist-get data :items))
      (when (and (listp item) (stringp (plist-get item :uid)))
        (push (seshat-library--item-from-cache item pending locations) result)))
    (nreverse result)))

(defun seshat-library--entries-merge (local cached)
  "按 D1 策略合并两层书目 LOCAL 与 CACHED，返回统一 item 列表（**纯函数**）.
- 以 LOCAL 为准：同一 uid 在两层都出现时用 LOCAL 的 item（它的 `:state' /
  `:size' 来自当前磁盘事实，比缓存新鲜）；
- CACHED 独有的 uid → 以 `unregistered' 加入，保留缓存的
  `:size' / `:name' / `:mtime'，`:source' 置 `cache'。**不丢弃**：这些书在远端
  确实存在，只是本地状态库还没登记，丢掉就是「书架少书」；
- 顺序：先 LOCAL（保持状态库顺序），再 CACHED 独有项（保持缓存顺序）。

纯函数：只读入参、只返回新列表。`copy-sequence' 复制 item 的骨架后再
`plist-put'，因此调用方手里的 plist 不会被就地修改（`seshat-state-entries'
返回的是状态库内部条目的引用，就地改会污染内存状态）。"
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (item local)
      (let ((uid (plist-get item :uid)))
        (when (and (stringp uid) (not (gethash uid seen)))
          (puthash uid t seen)
          (push item result))))
    (dolist (item cached)
      (let ((uid (plist-get item :uid)))
        (when (and (stringp uid) (not (gethash uid seen)))
          (puthash uid t seen)
          ;; `:source' 强制置 `cache'：第二参数就是「缓存层」，而
          ;; `--entries-refresh-remote' 传给它的条目来自 `--item-from-remote'
          ;; （中间态 `remote'）。不归一化的话，同一本书「刚刷新」与「下次打开」
          ;; 会得到不同的 `:source'，调用方（如本地条数统计）口径随之漂移。
          (push (plist-put (plist-put (copy-sequence item)
                                      :state 'unregistered)
                           :source 'cache)
                result))))
    (nreverse result)))

(defun seshat-library--cache-write (items)
  "把 ITEMS 原子写入 `seshat-library-cache-file'，返回写入的 plist.
写入方式照 `seshat-state-save' 的惯例：`make-temp-file'（临时文件与目标文件
**同目录**，保证 `rename-file' 是同一文件系统内的原子替换）→ `write-region' →
`rename-file'；中途失败会删除临时文件，正常结束后目录里只剩缓存文件本身。父
目录不存在时自动创建。

写失败（磁盘满 / 权限）**不抛错**：缓存是可选增强，写不进去最多下次重拉，不该
让「刷新清单」这个动作失败。返回 nil 时调用方仍可继续用内存里的结果。"
  (let* ((file (expand-file-name seshat-library-cache-file))
         (dir (file-name-directory file))
         (data (list :version seshat-library--cache-version
                     :saved-at (truncate (float-time))
                     :items items)))
    (condition-case err
        (progn
          (make-directory dir t)
          (let* ((temporary-file-directory dir)
                 (tmp (make-temp-file "seshat-library-cache" nil ".eld")))
            (unwind-protect
                (progn
                  (with-temp-buffer
                    (insert ";; -*- mode: emacs-lisp; coding: utf-8-unix; -*-\n")
                    (insert ";; Seshat 书架清单缓存，由 seshat-library.el 自动生成，请勿手工编辑。\n")
                    (let ((print-length nil)
                          (print-level nil)
                          (print-circle t)
                          (coding-system-for-write 'utf-8-unix))
                      (prin1 data (current-buffer))
                      (insert "\n")
                      (write-region (point-min) (point-max) tmp nil 'silent)))
                  (rename-file tmp file t))
              (when (file-exists-p tmp)
                (delete-file tmp))))
          data)
      (error
       (seshat-log 'warn "书架缓存写入失败（%s），本次结果仅在内存中可用"
                   (error-message-string err))
       nil))))

(defun seshat-library--state-location-index ()
  "把本地状态库**一次性**建成 uid → `(ROOT . PATH)' 的哈希表.
为什么需要它：`seshat-library--state-for' 是一次 `equal' 线性反查
（`seshat-state-path-for-uid' 走 `seshat-state-get'），对远端清单逐条调用就是
O(n²)——一个返回 20 万条的服务端能让 `g'（刷新）长时间无响应。建索引是 O(n)，
之后逐条 `gethash'。

索引只含**活条目**（`seshat-state-entries' 的默认口径：`:path' 非 nil 且无
`:orphan' / `:deleted-at'），与 `seshat-state-path-for-uid' 的判据完全一致，
因此「有键 = 已登记」「无键 = unregistered」两者等价。"
  (let ((table (make-hash-table :test #'equal)))
    (dolist (cell (seshat-state-entries))
      (let ((uid (car cell))
            (entry (cdr cell)))
        (when (and (stringp uid) (plist-get entry :path))
          (puthash uid (cons (plist-get entry :root) (plist-get entry :path))
                   table))))
    table))

(defun seshat-library--indexed-location (locations uid)
  "从位置索引 LOCATIONS 取 UID 的 `(ROOT . PATH)'，返回三态之一供 `--make-item' 判.
- LOCATIONS 为 nil（调用方没建索引）→ nil，让 `--make-item' 按 uid 反查；
- 索引里有该 uid → 它的 `(ROOT . PATH)'；
- 索引里没有该 uid → 哨兵 `seshat-library--location-unset'（未登记，零反查）。

为什么不直接 `gethash'：取不到键返回的 nil 与「没建索引」无法区分，会让未登记
的条目逐条退化成 O(条目数) 的线性反查（见
`seshat-library--state-location-index' 的复杂度说明）。"
  (and locations
       (or (gethash uid locations) seshat-library--location-unset)))

(defun seshat-library--cap-entries (entries)
  "把远端清单 ENTRIES 截断到 `seshat-library-max-entries' 条以内（纯函数）.
这是 **DoS 护栏**：分页上限 `seshat-library--max-pages' ×
`seshat-library--page-limit' 最多 100 万条，异常 / 恶意服务端可以把刷新拖到
长时间无响应。超过上限时**截断 + 一条 warn**，不抛错——书架照常可用。

上限非正整数或 nil 时视为不限（配置写坏不该让刷新失败）。返回新列表
（`cl-subseq' 复制），不改入参。"
  (let ((max (and (integerp seshat-library-max-entries)
                  (> seshat-library-max-entries 0)
                  seshat-library-max-entries)))
    (if (and max (> (length entries) max))
        (progn
          (seshat-log 'warn
                      "书架清单条数 %s 超过上限 %s，已截断（可调 `seshat-library-max-entries'）"
                      (length entries) max)
          (cl-subseq entries 0 max))
      entries)))

(defun seshat-library--entries-refresh-remote (&optional roots)
  "显式刷新书目：拉远端清单 → 写缓存 → 返回合并结果；ROOTS 为 nil 时用全部
`ondemand' 根。

远端拉取复用 `seshat-library--collect'（它内部逐根调
`seshat-library--remote-entries'，并顺带做 uid 形态与「根一致」两道安全校验——
缓存会把结果落盘，因此**不能**绕过校验）。**只发 `GET'**：`ondemand' 根只读，
刷新清单不写远端。

失败契约（两种失败，同一处置）：
- 任一根拉取失败（`--remote-entries' 返回 nil）→ `seshat-log' 记一条 warn；
- 全部根都空（没有任何条目）→ 同上。

此时**不写缓存**（不拿半份 / 空清单覆盖上一份可用缓存，否则书架会「越刷新越
少」），返回 `(--entries-merge (--entries-local) (--entries-cached))`——即退回
离线合并结果，界面照常可用。

**两处「循环外建一次」**（性能 / DoS）：
1. `seshat-library--state-location-index'：uid → `(ROOT . PATH)'，避免逐条线性
   反查状态库（O(n²)）；
2. `seshat-library--pending-index'：uid → 待同步条数，避免逐条读队列文件。
另有 `seshat-library--cap-entries' 的总条数硬上限（`seshat-library-max-entries'）。

返回值**恒为**合并后的 item 列表：远端条目经 `--entries-merge' 的第二参数进入
（它们此刻正是缓存内容，故 `:source' 标 `cache'；中间态由
`seshat-library--item-from-remote' 标 `remote'，仅用于区分新鲜度）。"
  (let* ((roots (or roots (seshat-library--roots)))
         (entries (seshat-library--cap-entries
                   (seshat-library--collect roots)))
         (locations (seshat-library--state-location-index))
         (pending (seshat-library--pending-index))
         (items (mapcar (lambda (entry)
                          (seshat-library--item-from-remote
                           entry
                           (seshat-library--indexed-location
                            locations (plist-get entry :uid))
                           pending))
                        entries)))
    (if (null items)
        (progn
          (seshat-log 'warn "书架清单刷新未取到任何条目，沿用本地状态库与缓存")
          (seshat-library--entries-merge (seshat-library--entries-local)
                                         (seshat-library--entries-cached)))
      (seshat-library--cache-write items)
      (seshat-library--entries-merge (seshat-library--entries-local) items))))

;;; 过滤 / 排序 / 分页（纯函数）

(defun seshat-library--item-match-p (item needle)
  "判断 ITEM 是否命中关键词 NEEDLE（已 `downcase'）；大小写不敏感的子串匹配.
匹配 `:name' / `:path' / `:root' 三处：书名是用户最先想到的入口，路径能定位
「同一目录下的一批书」，根能在多书库时按书库筛选。用 `string-search' 而不是
`string-match-p'：关键词是用户输入的字面文本，走正则就等于要求用户转义
`[` / `*` 之类字符。"
  (let (hit)
    (dolist (key '(:name :path :root))
      (let ((value (plist-get item key)))
        (when (and (not hit) (stringp value)
                   (string-search needle (downcase value)))
          (setq hit t))))
    (and hit t)))

(defun seshat-library--filter-items (items &optional keyword state)
  "按关键词 KEYWORD 与状态 STATE 过滤 ITEMS，返回新列表（**纯函数**）.
- KEYWORD 为 nil / 空串 / 非字符串 → 不按关键词过滤；否则大小写不敏感地匹配
  `:name' / `:path' / `:root' 的子串（见 `seshat-library--item-match-p'）；
- STATE 为 nil 或 `all' → 不按状态过滤；否则 `:state' 必须 `eq' 等于它；
- 两个条件 **AND**。

空串当作「不过滤」而不是「匹配空串」：搜索框清空后必须回到全量列表，而不是
每行都命中（技术上确实每行都含空串）。纯函数：不修改入参，返回新列表。"
  (let ((needle (and (stringp keyword) (not (string-empty-p keyword))
                     (downcase keyword))))
    (cl-remove-if-not
     (lambda (item)
       (and (or (null needle) (seshat-library--item-match-p item needle))
            (or (null state) (eq state 'all)
                (eq (plist-get item :state) state))))
     items)))

(defconst seshat-library--sort-keys
  '((name . :name) (root . :root) (size . :size)
    (percent . :percent) (mtime . :mtime))
  "`seshat-library--sort-items' 支持的排序键到 item plist 键的映射.
排序键写成不带冒号的符号（`name' / `size' …）是给调用方用的可读形式，item 里的
键是 keyword（`:name' / `:size' …），因此这里显式映射——**不要**在 `plist-get'
里直接传 `name'：`plist-get' 默认用 `eq' 比较，符号 `name' 与 `:name' 不 `eq'，
会静默取到 nil（表现为「排序完全没生效」）。

未知键一律回落到 `name'（排序是用户的浏览动作，不该因为一个拼错的键就把表格
打不开）。")

(defun seshat-library--sort-value (item key)
  "返回 ITEM 在排序键 KEY 上的取值；缺失或类型不符时返回 nil.
KEY 是 `seshat-library--sort-keys' 里的可读符号，经该映射换成 item 的 keyword
键。nil 的语义是「该行在这列上没有值」，排序时统一排尾（见
`seshat-library--sort-items'）——空值夹在中间会让「最大 / 最新」不在首屏。"
  (let ((value (plist-get item (cdr (assq key seshat-library--sort-keys)))))
    (cond
     ((memq key '(name root)) (and (stringp value) value))
     ((memq key '(size percent mtime)) (and (numberp value) value))
     (t value))))

(defun seshat-library--sort-lessp (key)
  "返回排序键 KEY 的比较函数（升序语义，供 `cl-stable-sort' 使用）.
字符串用 `string-lessp' 且两边先 `downcase'（书名大小写混排时不出现「Z 排在 a
前面」）；数字用 `<`；两值类型不同（脏数据）时退化为按 `format' 后的字符串比
较，**不抛错**——排序失败会让整张表打不开。"
  (lambda (a b)
    (let ((va (seshat-library--sort-value a key))
          (vb (seshat-library--sort-value b key)))
      (cond
       ((and (stringp va) (stringp vb))
        (string-lessp (downcase va) (downcase vb)))
       ((and (numberp va) (numberp vb)) (< va vb))
       (t (string-lessp (format "%s" va) (format "%s" vb)))))))

(defun seshat-library--sort-items (items key &optional descending)
  "按 KEY 排序 ITEMS，返回新列表（**纯函数**）。
KEY 取 `name' / `root' / `size' / `percent' / `mtime' 之一，未知键按 `name'
（见 `seshat-library--sort-keys'）。

- 该键上没有值的行（nil）**一律排尾**，升降序都排尾：先分离再拼接，不用「把
  nil 当成空串」的取巧做法；
- 字符串比较大小写不敏感，数字按数值；
- 用 `cl-stable-sort' 稳定排序：同值的行保持输入顺序，翻页才不会忽前忽后；
- DESCENDING 非 nil 时反转比较方向（**不是**排完再 `nreverse'）：反转列表会把
  同值行的相对顺序一起翻掉，那就不稳定了。

纯函数：不修改入参（`cl-stable-sort' 只重排新列表 `present'，入参的 cons 单元
不被改动）。"
  (let* ((key (if (assq key seshat-library--sort-keys) key 'name))
         (present nil)
         (absent nil))
    (dolist (item items)
      (if (seshat-library--sort-value item key)
          (push item present)
        (push item absent)))
    (let* ((present (nreverse present))
           (lessp (seshat-library--sort-lessp key))
           (sorted (cl-stable-sort present
                                   (if descending
                                       (lambda (a b) (funcall lessp b a))
                                     lessp))))
      (append sorted (nreverse absent)))))

(defun seshat-library--effective-page-size (page-size)
  "返回实际使用的页大小：PAGE-SIZE 是正整数就用它，否则用 `seshat-library-page-size'，
后者也不合法时退化为 1（宁可多翻几页，也不让除零把表格打不开）。"
  (cond
   ((and (integerp page-size) (> page-size 0)) page-size)
   ((and (integerp seshat-library-page-size) (> seshat-library-page-size 0))
    seshat-library-page-size)
   (t 1)))

(defun seshat-library--page-count (items &optional page-size)
  "返回 ITEMS 的总页数（**纯函数**）.
空列表返回 **1**（空结果也算「第 1 页」，界面才能显示「1/1」而不是「1/0」）；
否则 `(ceiling (length items) page-size)'。PAGE-SIZE 非正整数时用
`seshat-library-page-size'（见 `seshat-library--effective-page-size'）。"
  (if (null items)
      1
    (ceiling (length items) (seshat-library--effective-page-size page-size))))

(defun seshat-library--page-slice (items page &optional page-size)
  "返回 ITEMS 的第 PAGE 页子列表（**纯函数**），PAGE 从 1 开始.
页码越界时**夹紧**到 `[1, 总页数]`（小于 1 取 1、大于总页数取末页）：过滤后条目
变少时用户可能停在一个已不存在的页码上，夹紧比报错或显示空表都更合理。

末页不足一页时返回剩余部分；ITEMS 为空时返回 nil（空表没有「第一页」）。
用 `cl-subseq'（`cl-lib' 已 require）：它在越界区间上不抛错，语义正是我们要的
「取交集」。"
  (when items
    (let* ((size (seshat-library--effective-page-size page-size))
           (count (seshat-library--page-count items size))
           (page (max 1 (min (if (integerp page) page 1) count)))
           (start (* (1- page) size)))
      (cl-subseq items start (min (length items) (+ start size))))))

;;; 取书事务

(defun seshat-library--location-from-server (uid)
  "向服务端询问 UID 的归属位置，返回三种形态之一的 plist.

- `(:location (ROOT . PATH))'：服务端给出可用位置（`ROOT' / `PATH' 都是非空
  字符串）；
- `(:not-found t)'：服务端 404（未登记 / 已墓碑）——**确定性答案**，调用方转
  `user-error'，不重试；
- `(:failed t)'：其余一切失败（500 / 403 / 传输失败 / 响应缺字段）。此时已
  `display-warning' 一次并返回本形态，调用方**返回 nil 而不是报「未登记」**：
  把「服务端 500」说成「未登记」会让用户以为书没了，而实际可能只是瞬时故障。"
  (let* ((response (seshat-rest-get-resource uid))
         (resource (plist-get response :resource))
         (root (plist-get resource :root))
         (path (plist-get resource :path)))
    (cond
     ((and (stringp root) (not (string-empty-p root))
           (stringp path) (not (string-empty-p path)))
      (list :location (cons root path)))
     ((plist-get response :not-found)
      (list :not-found t))
     (t
      (display-warning
       'seshat-library
       (format "取书失败：无法解析 uid %s 的归属位置（状态 %S%s）"
               uid (plist-get response :status)
               (let ((err (plist-get response :error)))
                 (if err (format "，%s" err) "")))
       :warning)
      (list :failed t)))))


(defun seshat-library-fetch (uid &optional force)
  "把 uid 对应的远端书下载到本地镜像，返回本地绝对路径；失败返回 nil.
FORCE 非 nil 时**即使本地已有副本也重新下载**（对应书架的显式刷新，见
`ondemand' 根没有可检测的过期信号这一已知边界）；nil（默认）时本地已有副本就
直接返回路径，不产生任何网络请求——「打开一本书」不该每次都重下整本。

**第 0 步（任何请求之前）：uid 形态守卫**。`seshat-library--uid-valid-p' 判定
UID 是 26 位 Crockford Base32，否则立即 `user-error' 且**不发任何请求**。
uid 会被拼进 `GET /api/resources/%s'（`seshat-rest-get-resource' 的 docstring
假设「uid 只含 Crockford 字符、无需 URL 编码」），因此形态校验是安全边界而不是
可用性判断：不校验就能用 `/`、`?`、`..' 之类字符把请求引到同源别的端点
（例如 `\"../../api/roots\"'）。

之后六步固定顺序，任一步失败即中止：

1. 由 UID 得到 `(ROOT . PATH)'：优先 `seshat-state-path-for-uid'（零网络）；
   本地无登记时才 `seshat-rest-get-resource' 问服务端，取 `:resource' 的
   `:root' / `:path'（见 `seshat-library--location-from-server'）。服务端 404
   （含墓碑）→ `user-error'，**不重试**：404 是确定性答案，重试只会把用户卡在
   同一处。**其它失败**（500 / 传输失败）→ `display-warning' + 返回 nil，不报
   「未登记」——瞬时故障不等于书没了。
2. `seshat-sync--root-dir' 取本地根目录；为 nil（根未配置 / DIR 为空）→
   `user-error'，提示去配 `seshat-sync-roots'。不凭空构造目录：服务端的根与
   本地目录的对应关系只有用户配置说得清。
   **mode 门**（安全底线）：`seshat-library--ondemand-root-p' 判定 ROOT 是本地
   配置的 `ondemand' 根，否则 `user-error'。少了这道门，服务端清单里一个
   `mirror' 根的 uid 就足以让取书覆盖用户未提交的笔记。
   **门的位置（重要）**：mode 门之前可能已发过**一次只读元数据请求**
   （`GET /api/resources/<uid>'，即第 1 步的兜底分支）——它只在本地状态库无
   登记时发生，用于兜底取回 `(root, path)'。**所有写盘、删除、状态写入一律在
   门后**；门前的请求全是只读的，因此「拒绝」不会留下任何本地改动。
3. `seshat-sync--local-path' 校验并把 PATH 拼成绝对路径；为 nil（越界 / 绝对
   路径 / 盘符 / `..' 穿越 / 符号链接逃逸）→ `user-error'，**不发下载请求**。
   PATH 来自服务端、不可信，这是安全底线。
4. 本地已存在且 FORCE 为 nil → 直接返回该路径（上面第 1 步之后的短路）；
   FORCE 非 nil 且本地已存在 → 先 `yes-or-no-p' 确认覆盖，用户拒绝即
   `user-error'（**不下载、不改状态**）。否则 `seshat-rest-download-file'
   下载，并带上 `seshat-library-download-timeout' 与
   `seshat-library-max-download-bytes' 两道闸（超时秒数、字节上限）。
   **不自己写临时文件**：该函数内部经
   `seshat-rest--write-binary-file' 用 `make-temp-file' 生成随机名 + `rename-file'
   原子落位，中断不留半文件，并发取书也不会互相覆盖（`.part' 是 Android 端
   的命名，这里不存在）。非 2xx → `display-warning' + nil（含 403 只读根、
   404 远端已消失），不重试。返回 `:too-large t'（超过字节上限）→
   `display-warning' + nil，且传输层**未写盘**。下载抛 `file-error'（磁盘满 /
   权限）→ 同样降级为 `display-warning' + nil，不让 raw error 穿透。
5. 状态库对齐：`seshat-sync--event-set-location' 重申 `(ROOT . PATH)'，再用
   `seshat-state-set-base-blob' 写 SIZE / MTIME——**blob 恒为空串**：`ondemand'
   根没有 blob（同步事件也不带 size / mtime），空串是「无内容基线」的既有表示，
   且它不会让后续 push 把书库文件误判为本地改动。SIZE 取落盘后的
   `file-attributes' 第 7 项、MTIME 取第 5 项换算成 Unix 秒（nil 时留 nil，不猜）。
   为什么不用 `seshat-state-remap'：remap 是**改名语义**（清 `:orphan'、把占据
   同路径的旧属主标孤儿），而取书只是重申服务端位置，不该改动其它 uid——
   与 `seshat-sync--event-set-location' 的判断一致。
6. `seshat-state-save' 落盘一次。

**不发任何写请求**：`ondemand' 根只读，本函数只做 `GET'。除上述六处
`user-error'（uid 形态不合法 / 服务端未登记 / 根未配置目录 / mode 门拒绝 /
路径越界 / 用户取消覆盖）外不抛错，也不返回 nil 之外的失败信号（UI 只需判真值）。"
  ;; 安全边界：uid 会被拼进 `GET /api/resources/%s'，形态不合法就等于给同源 URL
  ;; 注入留门。校验放在**任何请求之前**（含本地状态库查询之前）——UID 不合法时
  ;; 连查表都没有意义，而「先查后拒」会让非法输入有机会触发一次联网。
  (unless (seshat-library--uid-valid-p uid)
    (user-error "UID 形态不合法：%S" uid))
  (let* ((known (seshat-state-path-for-uid uid))
         (probe (unless known (seshat-library--location-from-server uid)))
         (location (or known (plist-get probe :location))))
    (cond
     ;; 位置取不到：404 才是「未登记」；其它失败已在 helper 里告警过，直接返回 nil
     ;; （不能让「服务端 500」也报「未登记」——那不是确定性答案）。
     ((null location)
      (when (plist-get probe :not-found)
        (user-error "服务端未登记该 uid：%s" uid))
      nil)
     (t
      (let* ((root (car location))
             (path (cdr location))
             (root-dir (seshat-sync--root-dir root)))
        (unless root-dir
          (user-error "根 %s 未配置本地目录，请先在 seshat-sync-roots 中配置"
                      root))
        ;; mode 门：只有 `ondemand' 根才是书库。`mirror' 根上的 uid 是用户自己
        ;; 正在编辑的笔记，取书会覆盖它们——这是安全底线，不是可用性判断。
        (unless (seshat-library--ondemand-root-p root)
          (user-error "根 %s 不是书库（ondemand）根，拒绝在此根上取书" root))
        (let ((target (seshat-sync--local-path root-dir path)))
          (unless target
            (user-error "服务端路径 %s 越界（根 %s），拒绝落盘" path root))
          (cond
           ((and (not force) (file-exists-p target))
            target)
           ;; FORCE 且本地已有副本 → 覆盖前必须确认：`u' 是显式刷新，但「覆盖
           ;; 一份刚下载好的大书」不该在用户没看清的情况下发生。
           ((and force (file-exists-p target)
                 (not (yes-or-no-p (format "覆盖本地副本 %s？" target))))
            (user-error "已取消（保留原副本）"))
           (t
            (let ((result
                   (condition-case err
                       (seshat-rest-download-file
                        path target
                        :root root
                        :timeout seshat-library-download-timeout
                        :max-bytes seshat-library-max-download-bytes)
                     ;; 写盘失败（磁盘满 / 权限）不能让 raw `file-error' 穿透：
                     ;; 上层 reader 的 `--fetch-library' 靠「返回 nil」给友好提示。
                     (file-error
                      (display-warning
                       'seshat-library
                       (format "取书写盘失败：根 %s 的 %s（%s），本地副本未改动"
                               root path (error-message-string err))
                       :warning)
                      nil))))
              (cond
               ((null result) nil)
               ;; 超过 `seshat-library-max-download-bytes'：传输层按
               ;; `Content-Length' 判定并**未写盘**，这里只报告。
               ((plist-get result :too-large)
                (display-warning
                 'seshat-library
                 (format "文件超过上限（%s 字节），未下载：根 %s 的 %s"
                         (plist-get result :size) root path)
                 :warning)
                nil)
               ((not (and (integerp (plist-get result :status))
                          (>= (plist-get result :status) 200)
                          (< (plist-get result :status) 300)))
                (display-warning
                 'seshat-library
                 (format "取书失败：根 %s 的 %s（状态 %S%s），本地副本未改动"
                         root path (plist-get result :status)
                         (let ((err (plist-get result :error)))
                           (if err (format "，%s" err) "")))
                 :warning)
                nil)
               (t
                (seshat-sync--event-set-location uid root path)
                (let* ((attrs (file-attributes target))
                       (mtime (nth 5 attrs)))
                  (seshat-state-set-base-blob
                   uid "" (nth 7 attrs)
                   (and mtime (truncate (float-time mtime)))))
                (seshat-state-save)
                target)))))))))))

;;; 书架 buffer（视图层）

;; 视图层是**自建 buffer**（`special-mode' 派生），不用 `tabulated-list-mode'，
;; 也不用 ETAF：行内封面要按条目控制行高与 `display' 属性，列格式化承载不了；
;; 而分页把「同时驻留的 image 数」钉在 `page-size' 上（不变量 I-OOM，见 T5b-2）。
;; 代价是过滤 / 排序 / 分页要自己实现——它们已下沉为数据层的**纯函数**（T5a），
;; 视图层只负责「把当前页的切片插进 buffer」。
;;
;; **离线优先**：打开书架只读本地两层（`--entries-local' + `--entries-cached'），
;; 零网络；只有 `g'（`seshat-library-refresh-remote'）才触网，失败静默降级为离线
;; 结果。`d' / `x' / 翻页 / 过滤 / 排序 / 标记一律零网络。

;; 软依赖：`RET' 用 `seshat-reading-open' 打开文档；本模块不 require 它。
(declare-function seshat-reading-open "seshat-reading" (file))
;; 以下声明只为消除字节编译的「未知函数」告警，不引入任何 require。
(declare-function insert-image "image" (image &optional string area slice))
(declare-function create-image "image" (file-or-data &optional type data-p &rest props))
(declare-function image-flush "image" (spec &optional frame))
(declare-function dired "dired" (dirname &optional switches))
(declare-function dired-goto-file "dired" (file))
(declare-function quit-window "window" (&optional kill window))

(defconst seshat-library--buffer-name "*Seshat Library*"
  "书架 buffer 名.
带星号表示它不访问文件：无需保存，`q' 直接 `quit-window' 关掉。")

(defconst seshat-library--state-labels
  '((downloaded . "已下载")
    (missing . "未下载")
    (unregistered . "未登记"))
  "本地三态到显示文案的映射（三态的判定见 `seshat-library--state-for'）.
文案写死而不是直接用符号：符号对用户没有意义，而「已下载 / 未下载 / 未登记」三个
词与三态一一对应、不会随实现改名而漂移。")

(defconst seshat-library--size-units ["B" "KiB" "MiB" "GiB" "TiB"]
  "大小列的 1024 进制单位阶梯（与 `ls -h' 同口径）.")

(defconst seshat-library--state-cycle '(all downloaded missing unregistered)
  "`F'（`seshat-library-filter-state'）的状态过滤循环顺序：末项之后回到 `all'.")

(defconst seshat-library--sort-cycle
  '((name . nil) (root . nil) (size . nil) (percent . nil) (mtime . nil)
    (name . t) (root . t) (size . t) (percent . t) (mtime . t))
  "`s'（`seshat-library-sort-cycle'）的排序循环，元素为 `(KEY . DESCENDING)'.
五个键先各走一遍升序、再各走一遍降序——「同键再按一次反向」由此实现：走完一轮
回到 `name' 时方向已经翻转，不靠额外的按键去切换方向。")

(defconst seshat-library--empty-shelf-message
  "书架为空：请先运行 M-x seshat-sync-now 建立索引"
  "`--items' 为 nil 时的提示文案（一个书都没有 ≠ 过滤没命中）.")

(defconst seshat-library--empty-filter-message
  "当前过滤无匹配"
  "`--items' 非 nil 但 `--filtered' 为 nil 时的提示文案（与「书架为空」区分开）.")

(defconst seshat-library--footer-hint
  (concat "RET 打开 · u 重下 · d 删本地 · x 批量删 · m 标记 · D dired"
          " · n/p 翻页 · M-</M-> 首末页 · g 刷新清单"
          " · / 关键词 · F 状态 · s 排序 · q 关闭")
  "页脚键位提示（只插入一次，不承载条目属性，因此不会被命令当成条目）.")

;;; buffer-local 状态

;; 所有视图状态都必须 buffer-local：`C-u M-x seshat-library' 按根过滤后再开一个
;; 书架时，两个 buffer 的页码 / 过滤 / 标记必须互不影响。用全局变量会让「翻了一页
;; 的书架」把另一个书架也翻页——这是最难查的一类 bug。

(defvar-local seshat-library--items nil
  "本 buffer 的全量书目（本地状态库 + 缓存合并后的统一 item 列表）.
它是**数据源**而不是当前页：渲染只取 `--filtered' 的当前页切片，不遍历它插入
文本（否则万级书库会卡住主线程，也破坏 I-OOM）。")

(defvar-local seshat-library--filtered nil
  "`--items' 经关键词 / 状态过滤并按 `--sort-key' 排序后的列表.
由 `seshat-library--apply-view' 唯一维护；渲染只消费它。")

(defvar-local seshat-library--page 1
  "当前页码，1-based；由 `seshat-library--apply-view' 夹紧到 `[1, 总页数]'.")

(defvar-local seshat-library--keyword nil
  "关键词过滤串；nil 或空串表示不按关键词过滤.
匹配 `:name' / `:path' / `:root' 的大小写不敏感子串（实现见数据层
`seshat-library--filter-items'）。")

(defvar-local seshat-library--state-filter nil
  "状态过滤：nil（等同 `all'）/ `all' / `downloaded' / `missing' / `unregistered'.
与关键词过滤是**两个维度**，可叠加生效。")

(defvar-local seshat-library--sort-key 'name
  "排序键：`name'（默认）/ `root' / `size' / `percent' / `mtime'.")

(defvar-local seshat-library--descending nil
  "非 nil 时降序排序（`s' 走完一轮 5 个键后翻转）。")

(defvar-local seshat-library--marked nil
  "已标记的 uid 字符串列表（`m' 增删；`x' 消费后清空）.")

(defvar-local seshat-library--page-size nil
  "本 buffer 的页大小；nil 表示取 `seshat-library-page-size'（defcustom）.
存成 buffer-local 是为了让「临时把某个书架调大页」不影响别的 buffer；非正整数
一律回落到 defcustom（见 `seshat-library--effective-page-size'）。")

(defvar-local seshat-library--roots-filter nil
  "本 buffer 的根 tag 过滤（`seshat-library' 的可选参数）；nil 表示列全部根.
必须 buffer-local：`g' 要按**同一个**过滤重拉，否则「只看某个根」的书架按下 `g'
后会突然变成全量清单。")

;;; 列文案（大小 / 状态 / 进度 / 待同步）

(defun seshat-library--size-label (size)
  "把字节数 SIZE 格式化成人类可读的字符串（如 \"1.2 MiB\"）.
SIZE 不是非负整数（nil / 字符串 / 负数）时返回 \"-\"：缺失与 0 必须区分开——0
会被读成「空文件」，而清单里的缺失只说明「不知道大小」。"
  (if (not (and (integerp size) (>= size 0)))
      "-"
    (let ((value (float size))
          (unit 0))
      (while (and (>= value 1024.0)
                  (< unit (1- (length seshat-library--size-units))))
        (setq value (/ value 1024.0))
        (setq unit (1+ unit)))
      (if (zerop unit)
          (format "%d B" size)
        (format "%.1f %s" value (aref seshat-library--size-units unit))))))

(defun seshat-library--state-label (state)
  "把三态符号 STATE（`downloaded' / `missing' / `unregistered'）转成显示文案.
未知符号原样 `format' 出来而不是报错：书架是只读视图，显示一个陌生文案远好过
整张表打不开。"
  (or (alist-get state seshat-library--state-labels)
      (format "%s" state)))

(defun seshat-library--progress-label (item)
  "返回 ITEM 的进度文案：有百分比 `42%'、只有页码 `p.12'、都没有 `-'.
「有页码但算不出百分比」（缺 `:total'）时退化为页码——两者都缺才显示 `-'，
不拿 0% 冒充「没有进度」。"
  (let ((percent (plist-get item :percent))
        (page (plist-get item :page)))
    (cond
     ((numberp percent) (format "%d%%" (truncate percent)))
     ((numberp page) (format "p.%d" (truncate page)))
     (t "-"))))

(defun seshat-library--pending-label (item)
  "返回 ITEM 的待同步批注文案 `⟳2'；无待同步或查不到（nil）时返回 nil.
nil 是「查不了」（批注队列模块缺失），0 是「查过、确实没有」——两者都不显示，
但**不能**把 nil 当成 0 来计数。"
  (let ((pending (plist-get item :pending)))
    (and (numberp pending) (> pending 0) (format "⟳%d" pending))))

;;; 封面接口（T5b-2：唯一构造点 + 显示守卫 + 驻留跟踪）

;; I-OOM 不变量（本节的**唯一目的**）：任一时刻驻留（已构造、未 flush）的 image
;; 个数 ≤ `seshat-library-page-size'。机械保证来自三件事，改动前请先读测试组
;; 「I-OOM」：
;;
;; 1. **构造分层**：`seshat-library--make-cover-image' 是唯一的 image 构造点，
;;    且**不受** `display-graphic-p' 约束（`create-image' 在 `emacs --batch' 下
;;    同样安全）；「要不要放进 buffer」才由 `seshat-library--insert-cover' 判断。
;; 2. **驻留表**：构造成功的 image 登记进 buffer-local
;;    `seshat-library--resident'（alist `(UID . IMAGE)'），同 uid 复用不重建。
;; 3. **只渲染一页 + 离开即释放**：`seshat-library--render' 只插当前页；渲染前
;;    先算出「不在新页上的驻留 uid」并 `image-flush'（见
;;    `seshat-library--release-leaving-covers'），`kill-buffer-hook' 释放全部。

(defvar-local seshat-library--resident nil
  "本 buffer 已构造、尚未 flush 的封面 image：alist `(UID . IMAGE)'.
buffer-local 是必须的：两个书架 buffer 各有一页封面，混用全局值会让 A buffer 的
释放动作 flush 掉 B buffer 正在显示的 image。

它同时是「同 uid 不重复构造」的依据——`seshat-library--make-cover-image' 先查
这里，命中就复用同一个 image 对象（`image-flush' 之后再显示会重建数据，但对象
本身不必重造）。

键是 uid **字符串**，因此所有查找都必须用 `equal' 而非 `eq'（`alist-get' 默认
`eq'，必须显式传 `#'equal'，否则永远查不到）。")

(defun seshat-library--register-cover (uid image)
  "把 UID 的 IMAGE 登记进 `seshat-library--resident'，返回最终驻留的 image.
同 uid 已驻留时**返回已有对象**（不覆盖、不重复登记）：这是「同一页重复渲染 /
同一 uid 出现两次只构造一次」的实现点，也是正断言 P 能成立的前提。

UID 非字符串时原样返回 IMAGE（不登记）：非法 uid 不该污染驻留表。"
  (if (not (stringp uid))
      image
    (or (alist-get uid seshat-library--resident nil nil #'equal)
        (setf (alist-get uid seshat-library--resident nil nil #'equal) image))))

(defconst seshat-library--cover-max-columns 8
  "封面区列数上限.
高度 48px 的封面在 GUI 里约 3 行文字高，按常见书封长宽比 0.7 折算约 34px 宽、
4–5 列；再宽就会把正文挤到屏幕外，因此封顶 8 列。它同时兜住「字符宽度异常小」
的环境（批处理下 `frame-char-width' 返回 1，按它折算会得到 36 列）。")

(defun seshat-library--cover-columns ()
  "返回封面区占用的**列数**：由 `seshat-library-cover-width'（像素）按当前字符
宽度折算，夹在 `[2, seshat-library--cover-max-columns]' 之间.

换算只用 `frame-char-width'（GUI 下是真实字宽），**不查** `display-graphic-p'
——列数是文本布局，与「能不能显示 image」无关。字符宽度不可信（批处理下为 1）
时按 8px 估算，避免把封面区撑成 36 列。"
  (let ((char-width (ignore-errors (frame-char-width))))
    (max 2
         (min seshat-library--cover-max-columns
              (round (/ (float seshat-library-cover-width)
                        (if (and (integerp char-width) (> char-width 1))
                            char-width
                          8)))))))

(defun seshat-library--cover-placeholder (item)
  "返回 ITEM 的封面区占位文本（固定 `seshat-library--cover-columns' 列）.
取书名首字构造 `[书]' 形标签（书名缺失时退回 `[书]'），右侧补空格到固定列宽。

它同时是 image 分支 `insert-image' 的 STRING 参数：`insert-image' 把 STRING
插进 buffer、再把 image 显示在它上面，因此「显示 image」与「只显示占位」两个分支
的**文本完全一致**，列数天然对齐——翻页时整列文字不会左右跳。"
  (let* ((cols (seshat-library--cover-columns))
         (name (plist-get item :name))
         (initial (and (stringp name)
                       (not (string-empty-p name))
                       (char-to-string (aref name 0))))
         (label (if initial (format "[%s]" initial) "[书]"))
         (pad (max 0 (- cols (string-width label)))))
    (concat label (make-string pad ?\s))))

(defun seshat-library--make-cover-image (uid file)
  "构造 UID（本地文件 FILE）的封面 image 对象；不可用 / 无需封面时返回 nil.

唯一 image 构造点。**不受** `display-graphic-p' 约束——`create-image` 在
`emacs --batch' 下是安全的。是否把结果放进 buffer 显示由
`seshat-library--insert-cover' 判定。改这里前先读 I-OOM 测试。

三级回退的第一级（缓存）在这里落地：**只读**缓存
（`seshat-covers-cached'），取不到就返回 nil 让视图层插占位——本函数**绝不**同步
生成封面（`unzip' / `mutool' 子进程动辄数百毫秒，一页 30 本足以把书架冻住几秒），
生成一律交给 `seshat-covers-queue' 的 idle 队列（见 `seshat-library--queue-cover'）。

FILE 只用于将来可能的「按文件内容校验」，当前不参与判断：缓存路径只由 uid 决定
（`seshat-covers-path'），拿 FILE 去猜路径会绕过 uid 形态校验。

构造成功即登记进驻留表（`seshat-library--register-cover'）：同 uid 第二次调用
直接复用，不重复 `create-image`。"
  (ignore file)
  (when (stringp uid)
    (or (alist-get uid seshat-library--resident nil nil #'equal)
        (let ((path (seshat-covers-cached uid)))
          (when (and (stringp path) (file-exists-p path))
            (let ((image (create-image path nil nil
                                       :height seshat-library-cover-height
                                       :ascent 'center)))
              (when image
                (seshat-library--register-cover uid image))))))))

(defun seshat-library--insert-cover (item)
  "在当前 point 处插入 ITEM 的封面区（image 或等宽占位）.
本函数是「把封面放进 buffer 显示」的那一步，因此**只有这里**检查
`display-graphic-p'：非图形环境下（`emacs --batch' / `emacs -nw'）**不构造**，
直接插占位。不构造而不是「构造后不显示」，是因为看不见的 image 会白占
`seshat-library--resident' 的驻留预算——I-OOM 说的是「驻留 ≤ 一页」，让一页
看不见的 image 驻留着没有意义。

两个分支插入的是**同一个**占位字符串（image 分支把它当 `insert-image' 的
STRING），因此列数一致，翻页不会让后面的正文左右跳。"
  (let* ((uid (plist-get item :uid))
         (placeholder (seshat-library--cover-placeholder item))
         (image (and (display-graphic-p)
                     (seshat-library--make-cover-image
                      uid (seshat-library--item-local-file item)))))
    (if image
        (insert-image image placeholder)
      (insert placeholder))))

(defun seshat-library--release-covers (uids)
  "释放 UIDS 对应的驻留封面，返回实际释放的个数.
对每个已驻留的 uid 调 `(image-flush IMAGE)'（Emacs 32 的签名是 `(spec &optional
frame)'，`create-image' 返回的 image 对象本身就是合法的 spec），然后从
`seshat-library--resident' 移除。

只处理**确实驻留**的 uid：不在表里的 uid 静默跳过——释放是幂等的清理动作，
「本来就没有」不该报错（`kill-buffer-hook' 与翻页都会调用它，两者可能重叠）。"
  (let ((count 0))
    (dolist (uid uids)
      (let ((cell (and (stringp uid)
                       (assoc uid seshat-library--resident))))
        (when cell
          (when (cdr cell)
            (ignore-errors (image-flush (cdr cell))))
          (setq seshat-library--resident
                (assoc-delete-all uid seshat-library--resident))
          (setq count (1+ count)))))
    count))

(defun seshat-library--release-leaving-covers (keep-uids)
  "释放**不在** KEEP-UIDS 里的全部驻留封面，返回释放个数.
KEEP-UIDS 是即将渲染的那一页的 uid 列表。翻页 / 过滤 / 排序都走这一条：先按
**新页**算出离开集合，再释放，最后才渲染——顺序不能反，反了新页要复用的 image
会被误 flush（下一帧又从磁盘重建，白掉一次）。

同页重渲染（`m' 标记、`u' 刷新、封面就绪回调）时离开集合为空，一个都不释放：
这就是「重复渲染同页只构造一次」的保证。"
  (seshat-library--release-covers
   (cl-remove-if (lambda (uid) (member uid keep-uids))
                 (mapcar #'car seshat-library--resident))))

(defun seshat-library--queue-cover (item)
  "把 ITEM 的封面加入惰性生成队列（不可用 / 已缓存 / 已失败时什么都不做）.
三个前置条件缺一不可：
- 有本地文件（`:state' 为 `downloaded' 且文件在盘上）——没文件就没封面可抽；
- 缓存里没有（`seshat-covers-cached' 为 nil）——已生成过就不必再排队；
- 负缓存不存在（`seshat-covers-failed-p' 为 nil）——确定性失败的书不再重试，
  否则每次翻页都会重跑一次必然失败的 `unzip'。

入队走 `seshat-covers-queue' 的串行 idle 队列（每次 1 本、间隔
`seshat-covers-queue-delay'），回调是 `seshat-library--cover-ready'。"
  (let ((uid (plist-get item :uid))
        (file (seshat-library--item-local-file item)))
    (when (and (stringp uid)
               (stringp file)
               (eq 'downloaded (plist-get item :state))
               (not (seshat-covers-cached uid))
               (not (seshat-covers-failed-p uid)))
      (seshat-covers-queue uid file #'seshat-library--cover-ready))))

(defun seshat-library--redraw-line (uid)
  "就地重绘 UID 所在的那一行，返回 t；该 uid 不在 buffer 里时返回 nil（静默）.
只重绘一行而不是整页重渲染：封面是**逐本**就绪的，整页重渲染会让用户在队列推进
期间反复看到光标跳回页首、标记列闪烁。

定位按行首 `seshat-library-uid' 属性（`seshat-library--goto-uid'），删掉整行
（含换行）后复用 `seshat-library--insert-item' 重插——**不另写一套行格式**，否则
封面区 / 分隔符迟早与渲染路径漂移。

找不到该 uid 说明它已被翻页或过滤掉，静默返回：封面是可选增强，迟到的回调不该
把已经不在屏幕上的书拽回来。"
  (let ((item (cl-find-if (lambda (candidate)
                            (equal uid (plist-get candidate :uid)))
                          seshat-library--filtered)))
    (when (and item (seshat-library--goto-uid uid))
      (let ((inhibit-read-only t)
            (start (line-beginning-position)))
        (save-excursion
          (delete-region start (1+ (line-end-position)))
          (goto-char start)
          (seshat-library--insert-item item))
        t))))

(defun seshat-library--cover-ready (uid path)
  "封面惰性生成完成回调（`seshat-covers-queue' 的 CALLBACK）：按需重绘一行.
PATH 是生成出来的缓存文件路径或 nil（失败）。nil 不重绘：负缓存已由
`seshat-covers--mark-failed' 落盘，占位文本就是最终形态。

buffer 已关闭（或已被别的 major mode 接管）时什么都不做：队列是模块级的，
buffer 却是短命的，迟到的回调不能操作已死的 buffer。"
  (ignore path)
  (let ((buffer (get-buffer seshat-library--buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'seshat-library-mode)
          (seshat-library--redraw-line uid))))))

(defun seshat-library--release-all-covers ()
  "释放本 buffer 的全部驻留封面并清空队列（`kill-buffer-hook'）.
两道清理都必须做：image 不 flush 会一直占着解码后的像素内存；队列不清会让
idle 定时器在 buffer 死后继续跑子进程，回调再操作死 buffer。"
  (seshat-library--release-covers (mapcar #'car seshat-library--resident))
  (seshat-covers-queue-clear))


;;; 行定位（文本属性承载 uid）

(defun seshat-library--item-local-file (item)
  "返回 ITEM 的本地绝对路径；未下载 / 无法安全定位时返回 nil.
路径一律过 `seshat-library--local-file'（内部走 `seshat-sync--root-dir' +
`seshat-sync--local-path' 的越界校验），不拿 `:path' 自己拼。"
  (let ((local (seshat-library--local-file (plist-get item :root)
                                           (plist-get item :path))))
    (and local (file-exists-p local) local)))

(defun seshat-library--item-at-point ()
  "返回 point 所在行的 item（整行 `seshat-library-item' 属性）；非条目行返回 nil.
先看 point 本身的属性、再看行首：point 可能停在行尾（`C-e' 之后）。"
  (or (get-text-property (point) 'seshat-library-item)
      (get-text-property (line-beginning-position) 'seshat-library-item)))

(defun seshat-library--uid-at-point ()
  "返回 point 所在行的 uid 字符串；非条目行返回 nil.
uid 存在行首第 1 个字符的 `seshat-library-uid' 属性上（正文里没有 uid，书名只是
文件名），因此 `d' / `RET' / `u' / `m' 都靠它定位而不是靠「行里的文字」。"
  (let ((uid (or (get-text-property (point) 'seshat-library-uid)
                 (get-text-property (line-beginning-position)
                                    'seshat-library-uid))))
    (and (stringp uid) uid)))

(defun seshat-library--goto-uid (uid)
  "把 point 移到 UID 所在行的行首，返回 t；找不到返回 nil.
按文本属性逐行扫描（行数 ≤ `page-size'），不按显示文字匹配——同名书在不同根下
会出现同样的文字，按文字找会定位到错的行。"
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (equal uid (get-text-property (point) 'seshat-library-uid))
          (setq found t)
        (forward-line 1)))
    found))

;;; 过滤 / 排序 / 分页的应用（纯计算，零网络）

(defun seshat-library--filter-root (items root)
  "只保留 `:root' 等于 ROOT 的条目；ROOT 为 nil 时原样返回（**纯函数**）.
tag 用 `equal' 原样比较，不做大小写 / 空白归一：归一化会让「tag 配错了」表现成
「列出了别的根」，比空列表更难排查。"
  (if (null root)
      items
    (cl-remove-if-not (lambda (item) (equal root (plist-get item :root))) items)))

(defun seshat-library--local-items (&optional root)
  "返回**零网络**的全量书目：本地状态库 + 缓存合并（D1 策略），ROOT 非 nil 时只留该根.
主源是本地状态库（`--entries-local'），缓存只补「远端见过、本地还没登记」的书
（`--entries-cached'，以 `unregistered' 出现）。打开书架走这条路，**不触网**。"
  (seshat-library--filter-root
   (seshat-library--entries-merge (seshat-library--entries-local)
                                  (seshat-library--entries-cached))
   root))

(defun seshat-library--clamp-page (page)
  "把 PAGE 夹紧到 `[1, 总页数]'（用本 buffer 的 `--filtered' 与页大小）.
过滤后条目变少时用户可能停在一个已不存在的页码上，夹紧比报错或显示空表都更合理。"
  (let ((count (seshat-library--page-count seshat-library--filtered
                                           seshat-library--page-size)))
    (max 1 (min (if (integerp page) page 1) count))))

(defun seshat-library--apply-view ()
  "按 buffer-local 状态重算 `seshat-library--filtered' 并夹紧页码（**零网络**）.
只调数据层的纯函数（`--filter-items' / `--sort-items' / `--page-count'）：不读
文件、不联网，因此过滤 / 排序 / 翻页 / 标记全都不触网。返回过滤后的列表。"
  (setq seshat-library--filtered
        (seshat-library--sort-items
         (seshat-library--filter-items seshat-library--items
                                       seshat-library--keyword
                                       seshat-library--state-filter)
         seshat-library--sort-key
         seshat-library--descending))
  (setq seshat-library--page (seshat-library--clamp-page seshat-library--page))
  seshat-library--filtered)

(defun seshat-library--refresh-item-state (uid)
  "就地重算 UID 在 `seshat-library--items' 里的 `:state'（零网络），返回该 item.
删本地副本 / 强制重下之后必须重算：`--items' 是数据源，状态列读的是它的
`:state'，不重算就会一直显示删除前的三态。`:state' 键恒存在，因此 `plist-put'
是就地修改，不需要把返回值写回列表。"
  (let ((cell (cl-find-if (lambda (item) (equal uid (plist-get item :uid)))
                          seshat-library--items)))
    (when cell
      (plist-put cell :state (seshat-library--state-for uid))
      cell)))

;;; 渲染

(defun seshat-library--line-body (item)
  "返回条目行的正文（不含行首标记与封面占位）：书名 · 根 · 大小 · 进度 · 待同步 · 状态.
空的段（`待同步' 为 nil、根为空串）直接省略，避免出现连续分隔符。"
  (let* ((name (plist-get item :name))
         (uid (plist-get item :uid))
         (root (plist-get item :root))
         (parts (list (cond ((stringp name) name)
                            ((stringp uid) uid)
                            (t ""))
                      (and (stringp root) (not (string-empty-p root)) root)
                      (seshat-library--size-label (plist-get item :size))
                      (seshat-library--progress-label item)
                      (seshat-library--pending-label item)
                      (seshat-library--state-label (plist-get item :state)))))
    (mapconcat #'identity (delq nil parts) " · ")))

(defun seshat-library--insert-item (item)
  "把 ITEM 作为一行插入当前 point 处，并挂上命令定位所需的文本属性.
行格式：`<标记> <封面区 N 列> <正文>'（N 见 `seshat-library--cover-columns'）。
文本属性两处：
- 行首第 1 个字符挂 `seshat-library-uid'（命令按 uid 定位，正文里没有 uid）；
- 整行挂 `seshat-library-item'（`RET' / `D' 要拿完整的 item，不想再反查列表）。

行插完再入封面队列（`seshat-library--queue-cover'）：回调 `--cover-ready' 要按
uid 定位并重绘这一行，行不存在时它只能静默放弃。"
  (let* ((uid (plist-get item :uid))
         (start (point)))
    (insert (if (member uid seshat-library--marked) "*" " "))
    (seshat-library--insert-cover item)
    (insert " ")
    (insert (seshat-library--line-body item))
    (put-text-property start (1+ start) 'seshat-library-uid uid)
    (put-text-property start (point) 'seshat-library-item item)
    (insert "\n")
    (seshat-library--queue-cover item)))

(defun seshat-library--insert-notice (text)
  "插入一行提示 TEXT（不挂任何条目属性，命令因此不会把它当成条目）."
  (insert (propertize text 'face 'shadow) "\n"))

(defun seshat-library--header-line ()
  "构造 header-line 字符串：书架 · 第 P/T 页 · 共 N 本（本地 M）· 排序 · 过滤 · 标记.
每次渲染重算成普通字符串（不用 `:eval'）：`:eval' 会在每次重绘时求值，代价与
「什么时候刷新」都更难推理，而渲染本来就是唯一的状态变更点。

「本地 M」是 `:source' 为 `local' 的条数，即**本地状态库登记过的**书；它与
「共 N 本」的差额就是只存在于缓存里的 `unregistered' 条目。"
  (let* ((total (seshat-library--page-count seshat-library--filtered
                                            seshat-library--page-size))
         (page (seshat-library--clamp-page seshat-library--page))
         (all (length seshat-library--items))
         (local (cl-count-if (lambda (item) (eq 'local (plist-get item :source)))
                             seshat-library--items))
         (state seshat-library--state-filter)
         (parts (append
                 (list "书架"
                       (format "第 %d/%d 页" page total)
                       (format "共 %d 本（本地 %d）" all local)
                       (format "排序 %s%s" seshat-library--sort-key
                               (if seshat-library--descending "↓" "↑")))
                 (when (and (stringp seshat-library--keyword)
                            (not (string-empty-p seshat-library--keyword)))
                   (list (format "过滤 关键词 %s" seshat-library--keyword)))
                 (when (and state (not (eq state 'all)))
                   (list (format "过滤 状态 %s" (seshat-library--state-label state))))
                 (when seshat-library--marked
                   (list (format "标记 %d" (length seshat-library--marked)))))))
    (concat " " (mapconcat #'identity parts " · ") " ")))

(defun seshat-library--render (&optional keep-uid)
  "把 `seshat-library--filtered' 的**当前页**渲染进当前 buffer.
KEEP-UID 非 nil 时渲染后把 point 放回该 uid 所在行；默认放回渲染前 point 所在的
uid（`u' / `d' 之后光标不该跳回第一行）。

只插入当前页的条目（≤ `page-size` 行）：遍历全量 items 插入文本会让万级书库卡住
主线程，也破坏「同时驻留的 image ≤ 一页」这一上限。过滤 / 排序 / 分页的结果已由
`seshat-library--apply-view' 算好，本函数只做插入。

I-OOM 的释放点也在这里：插入前先按**新页**算出「已驻留但不在新页上」的 uid 并
`image-flush'（`seshat-library--release-leaving-covers'）。放在这里而不是各个
翻页命令里，是为了让翻页 / 过滤 / 排序 / 刷新 / 空结果**全部**走同一条释放路径
——少一处就是一次泄漏。

`special-mode' 已把 buffer 设为只读，因此所有插入都必须绑 `inhibit-read-only'。"
  (let* ((inhibit-read-only t)
         (keep (or keep-uid (seshat-library--uid-at-point)))
         (page (seshat-library--clamp-page seshat-library--page))
         (slice (seshat-library--page-slice seshat-library--filtered page
                                            seshat-library--page-size)))
    ;; 先算离开集合再释放，最后才渲染新页：反过来的话新页要复用的 image 会被
    ;; 误 flush（下一帧又从磁盘重建）。同页重渲染时离开集合为空。
    (seshat-library--release-leaving-covers
     (mapcar (lambda (item) (plist-get item :uid)) slice))
    (erase-buffer)

    ;; `header-line-format' 是普通变量，`setq' 会写进全局值，故用 `setq-local'。
    (setq-local header-line-format (seshat-library--header-line))
    (cond
     ((null seshat-library--items)
      (seshat-library--insert-notice seshat-library--empty-shelf-message))
     ((null seshat-library--filtered)
      (seshat-library--insert-notice seshat-library--empty-filter-message))
     (t
      (dolist (item slice)
        (seshat-library--insert-item item))
      (insert "\n")
      (seshat-library--insert-notice seshat-library--footer-hint)))
    (goto-char (point-min))
    (when (and (stringp keep) (seshat-library--goto-uid keep))
      (goto-char (line-beginning-position)))))

;;; keymap

(defvar seshat-library-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'seshat-library-open-at-point)
    (define-key map (kbd "u") #'seshat-library-refresh-at-point)
    (define-key map (kbd "d") #'seshat-library-delete-local-at-point)
    (define-key map (kbd "x") #'seshat-library-delete-marked)
    (define-key map (kbd "m") #'seshat-library-toggle-mark)
    (define-key map (kbd "D") #'seshat-library-dired-at-point)
    (define-key map (kbd "n") #'seshat-library-next-page)
    (define-key map (kbd "p") #'seshat-library-previous-page)
    (define-key map (kbd "M-<") #'seshat-library-first-page)
    (define-key map (kbd "M->") #'seshat-library-last-page)
    (define-key map (kbd "g") #'seshat-library-refresh-remote)
    (define-key map (kbd "/") #'seshat-library-filter-keyword)
    (define-key map (kbd "F") #'seshat-library-filter-state)
    (define-key map (kbd "s") #'seshat-library-sort-cycle)
    (define-key map (kbd "q") #'quit-window)
    map)
  "书架 buffer 的 keymap（父表 `special-mode-map'）：15 个键位.
`RET' 打开 / `u' 强制重下当前行 / `d' 删当前行本地副本 / `x' 批量删已标记 /
`m' 标记 / `D' 在 dired 中定位 / `n' `p' `M-<' `M->' 翻页 / `g' 重拉远端清单 /
`/' 关键词过滤 / `F' 状态过滤 / `s' 排序循环 / `q' 关闭。

**只有 `RET'（本地缺副本时）、`u' 与 `g' 会触网**：`d' / `x' / 翻页 / 过滤 /
排序 / 标记全部走 buffer-local 状态 + 纯函数，零远端请求。`g' 覆盖了
`special-mode-map' 里的 `revert-buffer'（语义同为「重拉」，但这里必须明确触网）。")

;;; major mode

(defun seshat-library--revert-buffer (&rest _ignore)
  "`revert-buffer' 的适配层：语义同 `g'（重拉远端清单 + 重渲染）.
单独包一层是因为 `revert-buffer-function' 会以 `(IGNORE-AUTO NOCONFIRM)' 两个
实参调用，而 `seshat-library-refresh-remote' 是零参命令。"
  (seshat-library-refresh-remote))

(define-derived-mode seshat-library-mode special-mode "Seshat Library"
  "浏览 `ondemand' 根书架的只读 major mode（自建 buffer + 显式分页）.
每条目一行：行首标记 + N 列封面区 + 书名 · 根 · 大小 · 进度 · 待同步 · 状态；
header-line 显示页码 / 总数 / 排序 / 过滤 / 标记数。行首第 1 个字符挂
`seshat-library-uid' 属性，命令据此定位（`RET' / `u' / `d' / `m' / `D'）。

**只读视图**：本 mode 只发清单请求（`g'）；除 `d' / `x'（删本地副本）外不改任何
文件，任何键都不会写远端。`ondemand' 根在服务端本就是只读的，这里不制造撞墙的
机会。

关闭时挂 `kill-buffer-hook'（`seshat-library--release-all-covers'）：驻留的
image 必须 `image-flush'、封面队列必须清空——buffer 短命，模块级的 idle 队列
不该继续跑子进程、更不该回调一个已死的 buffer。

evil 是**软依赖**：`seshat-reader--disable-evil' 存在时调它把 magic state 关掉
（书架是纯粹的选择界面，normal state 的 `d' / `u' 语义会与之冲突），不存在时零
副作用——不 require reader 包，也不报错。"
  (setq-local revert-buffer-function #'seshat-library--revert-buffer)
  (add-hook 'kill-buffer-hook #'seshat-library--release-all-covers nil t)
  (when (fboundp 'seshat-reader--disable-evil)
    (funcall 'seshat-reader--disable-evil)))

;;;###autoload
(defun seshat-library (&optional root)
  "打开书架 buffer `*Seshat Library*'，列出本地已知书目（**零网络**）.
数据源是本地状态库（`seshat-library--entries-local'）+ 清单缓存
（`--entries-cached'）的合并结果：已登记的书一本不漏，缓存只补「远端见过、本地
还没登记」的条目（以「未登记」出现）。打开书架**不发任何请求**——这是离线可用的
前提；要重拉远端清单按 `g'。

ROOT 为根 tag 字符串时只列该根（`equal' 原样比较）；nil（默认）时列全部
`ondemand' 根。交互调用时用前缀参数（`C-u M-x seshat-library'）可从现有
`ondemand' 根的 tag 里选一个过滤。

返回书架 buffer，便于程序化调用后继续在该 buffer 里操作。"
  (interactive
   (list (when current-prefix-arg
           (let ((tags (mapcar #'car (seshat-library--roots))))
             (and tags (completing-read "根 tag: " tags nil t))))))
  (let ((buffer (get-buffer-create seshat-library--buffer-name)))
    (with-current-buffer buffer
      (seshat-library-mode)
      (setq seshat-library--roots-filter root)
      (setq seshat-library--items (seshat-library--local-items root))
      (seshat-library--apply-view)
      (seshat-library--render))
    (pop-to-buffer buffer)
    buffer))

;;; 命令：取书 / 刷新 / 删除 / 定位

(defun seshat-library-open-at-point ()
  "取当前行的书到本地并打开（`RET'）.
先 `seshat-library-fetch' 取书：本地已有副本时它零网络直接返回路径，因此
「打开一本已下载的书」不会每次都重下整本。

拿到路径后交给 `seshat-reading-open' 打开。该函数属 `seshat-reading'，是**软
依赖**：`require' 带 NOERROR 探测，缺失时退化为 `find-file'——可选依赖缺失不该
让「打开一本书」失败。

取书失败（网络 / 403 只读根 / 路径越界 / 服务端未登记）→ `user-error'：这是用户
的显式操作，失败原因必须出现在 echo area，不能静默返回。"
  (interactive)
  (let ((uid (seshat-library--uid-at-point)))
    (unless (stringp uid)
      (user-error "当前行没有对应的书"))
    (let ((file (seshat-library-fetch uid)))
      (unless file
        (user-error "取书失败：%s" uid))
      (require 'seshat-reading nil t)
      (if (fboundp 'seshat-reading-open)
          (seshat-reading-open file)
        (find-file file)))))

(defun seshat-library-refresh-at-point ()
  "强制重新下载当前行的书（`u'），并刷新状态列.
`ondemand' 根的本地副本没有可检测的过期信号（blob 恒空、同步事件不带 size /
mtime），所以刷新只能是显式的：以 FORCE 非 nil 调 `seshat-library-fetch'，即使
本地已有副本也重下（覆盖前会 `yes-or-no-p' 确认，见该函数）。

重下成功后**只重算本地三态并重渲染**，不重拉远端清单：重下不改变书名 / 根 / 大小。
"
  (interactive)
  (let ((uid (seshat-library--uid-at-point)))
    (unless (stringp uid)
      (user-error "当前行没有对应的书"))
    (unless (seshat-library-fetch uid t)
      (user-error "刷新本地副本失败：%s" uid))
    (seshat-library--refresh-item-state uid)
    (seshat-library--apply-view)
    (seshat-library--render uid)
    (message "已刷新本地副本：%s" uid)))

(defun seshat-library-refresh-remote ()
  "重拉远端清单（`g'）：**唯一会批量联网的键**，失败静默降级.
调 `seshat-library--entries-refresh-remote'（拉远端 → 写缓存 → 与本地合并）；
网络失败时它自己 `seshat-log' 记一条 warn 并退回「本地 + 旧缓存」的结果，因此
断网按 `g' 只会看到「清单没变」而不是报错。`ondemand' 根只读，本命令只发 `GET'。

本命令按 buffer 的根过滤重拉（`--roots-filter'），否则「只看某个根」的书架按下
`g' 会突然变成全量清单。"
  (interactive)
  (let ((items (seshat-library--entries-refresh-remote
                (seshat-library--select-roots seshat-library--roots-filter))))
    (setq seshat-library--items
          (seshat-library--filter-root items seshat-library--roots-filter))
    (seshat-library--apply-view)
    (seshat-library--render)
    (message "已刷新远端清单：%d 本" (length seshat-library--items))))

(defun seshat-library--select-roots (root)
  "返回按 ROOT（根 tag 字符串）过滤后的 `ondemand' 根列表；ROOT 为 nil 时返回全部.
tag 用 `equal' 原样比较，不做大小写 / 空白归一：归一化会让「tag 配错了」表现成
「列出了别的根」，比空列表更难排查。"
  (let ((roots (seshat-library--roots)))
    (if (null root)
        roots
      (cl-remove-if-not (lambda (candidate) (equal (car candidate) root)) roots))))

;;; 命令：删本地副本（零网络）

(defun seshat-library--local-copy-target (uid)
  "解析 UID 的本地副本路径，返回 `(:ok PATH)' / `(:absent PATH)' / `(:skip REASON)'.
路径一律经 `seshat-sync--root-dir' + `seshat-sync--local-path' 拼出并校验：
`seshat-state-path-for-uid' 只给出 `(ROOT . PATH)'，**不拿它直接拼路径**——那样
会绕过越界校验，让一条被篡改的相对路径删掉根目录之外的文件。

门禁共三道，任一不过就 `:skip'（失败方向安全，调用方转 `user-error'）：
- 状态库没有登记（没有可删的东西）；
- ROOT 不是 `ondemand' 根（`mirror' 根上的文件是用户正在编辑的笔记）；
- 路径存在但**不是普通文件**（目录 / FIFO / socket / 断链）。`file-exists-p'
  对目录也返回 t，裸 `delete-file' 会抛 `file-error'，所以「能不能删」不能只看
  存在性。

本函数**零网络**：三态与路径都是本地状态库 + 用户配置 + 磁盘的组合。"
  (let* ((location (seshat-state-path-for-uid uid))
         (root (car-safe location))
         (path (cdr-safe location)))
    (cond
     ((null location)
      (list :skip (format "本地状态库没有 uid %s 的登记，没有可删的本地副本" uid)))
     ((not (seshat-library--ondemand-root-p root))
      (list :skip (format "根 %s 不是书库（ondemand）根，拒绝删除本地副本" root)))
     (t
      (let* ((root-dir (seshat-sync--root-dir root))
             (local (and root-dir (seshat-sync--local-path root-dir path))))
        (cond
         ((null root-dir)
          (list :skip (format "根 %s 未配置本地目录，无法定位本地副本" root)))
         ((null local)
          (list :skip (format "服务端路径 %s 越界（根 %s），拒绝删除" path root)))
         ((not (file-exists-p local)) (list :absent local))
         ;; 第三道门：只有**普通文件**才可删。`file-exists-p' 对目录 / FIFO /
         ;; socket 同样返回 t，而 `delete-file' 对它们抛 `file-error'——裸调用会让
         ;; `d' 直接中断、`x' 整批中断。符号链接的语义在这里正好合适：
         ;; `file-regular-p' 指向普通文件时为 t（`delete-file' 删的是链接本身，
         ;; 不会删到目标），断链或指向目录时为 nil → 跳过。
         ((not (file-regular-p local))
          (list :skip (format "本地副本 %s 不是普通文件（目录 / 断链 / 特殊文件），拒绝删除"
                              local)))
         (t (list :ok local))))))))

(defun seshat-library--delete-local-copy (uid)
  "删除 UID 的本地副本，返回 `deleted' / `absent' / `skipped' 之一（**零网络**）.
不删远端、不改状态库：文件没了，三态自然退回 `missing'，下次 `RET' 会重新取书。
批量删（`x'）用返回值统计，而不是让一行不合格就中断整批。

**`delete-file' 的失败被吞掉并计入 `skipped'**：权限不足、文件在删之前被别人
挪走、路径其实是目录……都只记一条 warn 然后继续下一本。裸 `delete-file' 会抛
`file-error'，一行失败就让整批停在半路，剩下的书既不删也不统计。"
  (pcase (seshat-library--local-copy-target uid)
    (`(:ok ,path)
     (if (condition-case err
             (progn (delete-file path) t)
           (error
            (seshat-log 'warn "书架：删除本地副本 %s 失败（%s），计入跳过"
                        path (error-message-string err))
            nil))
         'deleted
       'skipped))
    (`(:absent ,_path) 'absent)
    (_ 'skipped)))

(defun seshat-library-delete-local-at-point ()
  "删除当前行的书的**本地副本**（`d'）.
`ondemand' 根只读：本命令**不发任何远端请求**（远端文件一律保留），也不改状态
库——删掉文件后该条目自然退回「未下载」。

路径必须经 `seshat-sync--root-dir' + `seshat-sync--local-path' 拼出并校验（见
`seshat-library--local-copy-target'）：根未配置目录、路径越界、根不是
`ondemand' 根、或目标不是普通文件 → `user-error' 且**不删任何东西**（失败方向
安全）。

`delete-file' 本身也用 `condition-case' 兜住：走到这里说明路径已通过全部门禁，
但删除仍可能因权限 / 竞态失败。那种情况下转 `user-error`（`d' 是用户直接触发
的交互命令，报错比静默吞掉更诚实），而**不是**让 `file-error' 原样冒出来——
两个命令对同一种失败给出同一种信号，用户不用分辨「哪种红字该找谁」。"
  (interactive)
  (let ((uid (seshat-library--uid-at-point)))
    (unless (stringp uid)
      (user-error "当前行没有对应的书"))
    (pcase (seshat-library--local-copy-target uid)
      (`(:skip ,reason) (user-error "%s" reason))
      (`(:absent ,path)
       (seshat-library--refresh-item-state uid)
       (seshat-library--apply-view)
       (seshat-library--render uid)
       (message "本地副本不存在：%s" path))
      (`(:ok ,path)
       (condition-case err
           (delete-file path)
         (error
          (user-error "删除本地副本 %s 失败：%s"
                      path (error-message-string err))))
       (seshat-library--refresh-item-state uid)
       (seshat-library--apply-view)
       (seshat-library--render uid)
       (message "已删除本地副本：%s" path)))))

(defun seshat-library-delete-marked ()
  "批量删除**已标记**条目的本地副本（`x'），零网络.
逐个走 `seshat-library--delete-local-copy'：只有「`ondemand' 根 + 已下载的普通
文件」的条目会被删，其余（含 `delete-file' 抛错的那些）计入「跳过」——不让一行
不合格中断整批。不删远端、不改状态库。
删除后清空标记并重渲染。"
  (interactive)
  (unless seshat-library--marked
    (user-error "没有标记任何书（先用 `m' 标记）"))
  (let ((uids (copy-sequence seshat-library--marked))
        (deleted 0)
        (skipped 0))
    (dolist (uid uids)
      (if (eq 'deleted (seshat-library--delete-local-copy uid))
          (setq deleted (1+ deleted))
        (setq skipped (1+ skipped))))
    (setq seshat-library--marked nil)
    (dolist (uid uids)
      (seshat-library--refresh-item-state uid))
    (seshat-library--apply-view)
    (seshat-library--render)
    (message "已删除 %d 个本地副本%s" deleted
             (if (> skipped 0) (format "（跳过 %d 个）" skipped) ""))))

;;; 命令：标记与 dired

(defun seshat-library-toggle-mark ()
  "标记 / 取消标记当前行（`m'），然后把 point 下移一行.
下移是为了「连续按 `m' 标记一批」：每次标记后光标停在下一本上，不用手动挪。
渲染会重建 buffer（point 回到 `point-min'），因此渲染后按 uid 重新定位再下移。"
  (interactive)
  (let ((uid (seshat-library--uid-at-point)))
    (unless (stringp uid)
      (user-error "当前行没有对应的书"))
    (if (member uid seshat-library--marked)
        (setq seshat-library--marked (delete uid seshat-library--marked))
      (setq seshat-library--marked (append seshat-library--marked (list uid))))
    (seshat-library--render uid)
    (forward-line 1)))

(defun seshat-library-dired-at-point ()
  "在 dired 中定位当前行的本地文件（`D'）.
只对**已下载**的条目有效：未下载时没有文件可定位，`user-error' 而不是打开一个
空的根目录——那会让用户以为书在盘上。"
  (interactive)
  (let* ((item (seshat-library--item-at-point))
         (file (and item (seshat-library--item-local-file item))))
    (unless file
      (user-error "当前行没有本地副本，无法在 dired 中定位"))
    (require 'dired)
    (dired (file-name-directory file))
    (dired-goto-file file)))

;;; 命令：分页

(defun seshat-library-next-page ()
  "下一页（`n'）；已是末页时提示且不越界."
  (interactive)
  (let ((count (seshat-library--page-count seshat-library--filtered
                                           seshat-library--page-size)))
    (if (>= (seshat-library--clamp-page seshat-library--page) count)
        (message "已是最后一页")
      (setq seshat-library--page (1+ (seshat-library--clamp-page seshat-library--page)))
      (seshat-library--render))))

(defun seshat-library-previous-page ()
  "上一页（`p'）；已是首页时提示且不越界."
  (interactive)
  (let ((page (seshat-library--clamp-page seshat-library--page)))
    (if (<= page 1)
        (message "已是第一页")
      (setq seshat-library--page (1- page))
      (seshat-library--render))))

(defun seshat-library-first-page ()
  "跳到首页（`M-<'）."
  (interactive)
  (setq seshat-library--page 1)
  (seshat-library--render))

(defun seshat-library-last-page ()
  "跳到末页（`M->'）."
  (interactive)
  (setq seshat-library--page
        (seshat-library--page-count seshat-library--filtered seshat-library--page-size))
  (seshat-library--render))

;;; 命令：过滤与排序

(defun seshat-library-filter-keyword (keyword)
  "按关键词过滤（`/'），并把页码重置到第 1 页.
KEYWORD 为空串（或 nil）时清除关键词过滤。匹配 `:name' / `:path' / `:root' 的
大小写不敏感子串，走数据层纯函数 `seshat-library--filter-items'，**零网络**。"
  (interactive
   (list (read-string "关键词（空则清除）: " seshat-library--keyword)))
  (setq seshat-library--keyword
        (and (stringp keyword) (not (string-empty-p keyword)) keyword))
  (setq seshat-library--page 1)
  (seshat-library--apply-view)
  (seshat-library--render))

(defun seshat-library-filter-state ()
  "按本地状态循环过滤（`F'）：all → downloaded → missing → unregistered → all.
与关键词过滤是两个独立维度，可叠加生效；每次切换都把页码重置到第 1 页（过滤后
条目变少，停在旧页码上没有意义）。零网络。"
  (interactive)
  (let* ((current (or seshat-library--state-filter 'all))
         (next (or (cadr (memq current seshat-library--state-cycle)) 'all)))
    (setq seshat-library--state-filter next)
    (setq seshat-library--page 1)
    (seshat-library--apply-view)
    (seshat-library--render)
    (message "状态过滤：%s" (if (eq next 'all)
                            "全部"
                          (seshat-library--state-label next)))))

(defun seshat-library-sort-cycle ()
  "排序键循环（`s'）：name → root → size → percent → mtime → name（再反向一轮）.
顺序见 `seshat-library--sort-cycle`：五个键各走一遍升序之后各走一遍降序，即走完
一轮回到 `name' 时方向已翻转。排序只重排 `--filtered'，零网络。"
  (interactive)
  (let* ((state (cons (or seshat-library--sort-key 'name)
                      (and seshat-library--descending t)))
         (next (or (cadr (member state seshat-library--sort-cycle))
                   (car seshat-library--sort-cycle))))
    (setq seshat-library--sort-key (car next))
    (setq seshat-library--descending (cdr next))
    (seshat-library--apply-view)
    (seshat-library--render)
    (message "排序：%s%s" seshat-library--sort-key
             (if seshat-library--descending "↓" "↑"))))

(provide 'seshat-library)

;;; seshat-library.el ends here
