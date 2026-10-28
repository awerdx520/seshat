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

;;; Code:

(require 'cl-lib)
(require 'seshat-rest)
(require 'seshat-state)
(require 'seshat-sync)

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
超限时不写盘、按失败处理：上限依据服务端响应的 `Content-Length' 在**落盘之前**
判断，因此不会先把磁盘写满才发现超限。"
  :type '(choice (const :tag "不限" nil) integer)
  :group 'seshat-library)

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

;;; 本地三态

(defun seshat-library--local-state (item)
  "判定远端 item 的本地状态，返回符号 `downloaded' / `missing' / `unregistered' 之一.
ITEM 是 `seshat-library--remote-entries' 返回的元素（只需要 `:uid'）。

- `unregistered'：状态库没有该 uid 的 `(ROOT . PATH)'（`seshat-state-path-for-uid'
  返回 nil，含「路径已清」「墓碑」「孤儿」三种情况）；
- `downloaded'：已登记，且按登记的根 / 路径拼出的本地文件**存在**；
- `missing'：其余情况（已登记但本地缺文件）。

路径一律「状态库 → `seshat-sync--root-dir' → `seshat-sync--local-path'」，不拿
ITEM 的 `:path' 自己拼：本地目录的对应关系只由 `seshat-sync-roots' 说得清，且
越界校验必须在同一处（安全底线）。根未配置目录、或路径越界时返回 `missing'
（视为「本地没有」），**不报错**：书架只需要如实显示三态，判状态不该成为会抛错的
操作；真正落盘时的越界拒绝由 `seshat-library-fetch' 的 `user-error' 承担。

本函数**零网络**：三态是远端清单 + 本地状态库 + 磁盘的组合，不需要额外请求。"
  (let* ((uid (plist-get item :uid))
         (location (and (stringp uid) (seshat-state-path-for-uid uid))))
    (if (null location)
        'unregistered
      (let* ((root-dir (seshat-sync--root-dir (car location)))
             (local (and root-dir
                         (seshat-sync--local-path root-dir (cdr location)))))
        (if (and local (file-exists-p local)) 'downloaded 'missing)))))

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

;;; 书架 buffer（UI 层）

;; `define-derived-mode' 展开时需要父 mode 已定义，故 UI 段开头显式 require；
;; 数据层不需要它（保持零额外依赖），因此这条 require 放在这里而不是文件顶部。
(require 'tabulated-list)

(declare-function seshat-reading-open "seshat-reading" (file))

(defconst seshat-library--buffer-name "*Seshat Library*"
  "书架 buffer 名.
带星号表示它不访问文件：无需保存，`q' 直接 `quit-window' 关掉。")

(defconst seshat-library--column-format
  [("书名" 40 t) ("根" 10 t) ("大小" 10 t) ("状态" 12 t)]
  "书架的列定义，元素与 `seshat-library--entry' 的列向量一一对应.
第三元素 `t' 是 `tabulated-list-format' 的「可按该列排序」标记；排序只改显示
顺序，不碰远端与本地状态。书名列取 `file-name-nondirectory'，因此不同根下的
同名书靠「根」列区分。宽度是容纳典型书名的上限，`tabulated-list' 会按实际内容
对齐。")

(defconst seshat-library--state-labels
  '((downloaded . "已下载")
    (missing . "未下载")
    (unregistered . "未登记"))
  "本地三态到显示文案的映射（三态的判定见 `seshat-library--local-state'）.
文案写死而不是直接用符号：符号对用户没有意义，而「已下载 / 未下载 / 未登记」三个
词与三态一一对应、不会随实现改名而漂移。")

(defconst seshat-library--size-units ["B" "KiB" "MiB" "GiB" "TiB"]
  "大小列的 1024 进制单位阶梯（与 `ls -h' 同口径）.")

(defvar-local seshat-library--items nil
  "书架 buffer 里最近一次拉到的远端 item 列表（`seshat-library--collect' 的结果）.
缓存它是为了让「删本地副本」与「强制刷新」只需重算状态列，**不必再拉一次清单**：
`ondemand' 根只读，这两个动作不该产生任何远端请求。`g'（`tabulated-list-revert'）
语义是「重拉清单」，因此它走另一条路（`seshat-library--reload-entries'）。")

(defvar-local seshat-library--roots-filter nil
  "本 buffer 的根 tag 过滤（`seshat-library' 的可选参数）；nil 表示列全部根.
必须存成 buffer-local：`g' 要按**同一个**过滤重拉，否则「只看某个根」的书架按下
`g' 后会突然变成全量清单。")

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
  "把 `seshat-library--local-state' 返回的三态符号 STATE 转成显示文案.
未知符号原样 `format' 出来而不是报错：书架是只读视图，显示一个陌生文案远好过
整张表打不开。"
  (or (alist-get state seshat-library--state-labels)
      (format "%s" state)))

(defun seshat-library--entry (item)
  "把远端 ITEM 变成 `tabulated-list-entries' 的一项 `(UID [书名 根 大小 状态])'.
UID 作为行 ID（`RET' / `u' / `d' 都靠它定位），因此必须是字符串——
`seshat-library--collect' 已经把没有字符串 uid 的项滤掉了，这里可以直接用。
状态列每次渲染都重新调 `seshat-library--local-state'：它零网络，重算没有成本，
而缓存状态会让「刚下载完」的行仍显示「未下载」。"
  (let* ((uid (plist-get item :uid))
         (path (plist-get item :path))
         (name (if (and (stringp path) (not (string-empty-p path)))
                   (file-name-nondirectory path)
                 uid))
         (root (plist-get item :root)))
    (list uid
          (vector name
                  (if (stringp root) root "")
                  (seshat-library--size-label (plist-get item :size))
                  (seshat-library--state-label
                   (seshat-library--local-state item))))))

(defun seshat-library--select-roots (root)
  "返回按 ROOT（根 tag 字符串）过滤后的 `ondemand' 根列表；ROOT 为 nil 时返回全部.
tag 用 `equal' 原样比较，不做大小写 / 空白归一：归一化会让「tag 配错了」表现成
「列出了别的根」，比空列表更难排查。"
  (let ((roots (seshat-library--roots)))
    (if (null root)
        roots
      (cl-remove-if-not (lambda (candidate) (equal (car candidate) root)) roots))))

(defun seshat-library--collect (&optional roots)
  "汇总 ROOTS（默认 `seshat-library--roots'）的远端清单，返回 item 列表.
对每个根调 `seshat-library--remote-entries' 后按根顺序拼接，元素保持服务端原样
（`:root' **不再**被覆盖成请求的 tag，见下）。

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

(defun seshat-library--set-entries ()
  "按缓存的 `seshat-library--items' 重算 `tabulated-list-entries'（不打印）."
  (setq tabulated-list-entries
        (mapcar #'seshat-library--entry seshat-library--items)))

(defun seshat-library--reload-entries ()
  "重拉远端清单并写入 `tabulated-list-entries'（不打印，打印由调用方负责）.
挂在 `tabulated-list-revert-hook' 上，因此 `g'（`tabulated-list-revert'）与
`revert-buffer' 都走这条路——两者都必须重拉，只用缓存就失去了「刷新」的意义。"
  (setq seshat-library--items
        (seshat-library--collect
         (seshat-library--select-roots seshat-library--roots-filter)))
  (seshat-library--set-entries))

(defun seshat-library--redisplay ()
  "按缓存的远端清单重算状态列并重画，**零远端请求**.
给「删本地副本」「强制刷新」用：这两个动作只改变本地三态，远端清单里的书名 /
根 / 大小一项都没变，再拉一次清单纯属浪费往返（且 `d' 的契约是绝不发远端请求）。"
  (seshat-library--set-entries)
  (tabulated-list-print t))

(defvar seshat-library-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'seshat-library-open-at-point)
    (define-key map (kbd "u") #'seshat-library-refresh-at-point)
    (define-key map (kbd "d") #'seshat-library-delete-local-at-point)
    (define-key map (kbd "g") #'tabulated-list-revert)
    (define-key map (kbd "q") #'quit-window)
    map)
  "书架 buffer 的 keymap：`RET' 取书并打开 / `u' 强制重下当前行 / `d' 删本地副本 /
`g' 重拉远端清单 / `q' 关窗口.
父 keymap 是 `tabulated-list-mode-map'，因此 `n' / `p' / `S' 等浏览与排序键照旧
可用。`g' 显式改绑 `tabulated-list-revert'：`special-mode-map' 里 `g' 是
`revert-buffer'，语义上同样是「重拉」，但直接用 tabulated 自己的入口更明确，且它
保证刷新后光标停在原条目上。")

(define-derived-mode seshat-library-mode tabulated-list-mode "Seshat Library"
  "浏览 `ondemand' 根远端书库的只读 major mode.
表格四列：书名 / 根 / 大小 / 状态，行 ID 是服务端的 uid。表内容由
`seshat-library--reload-entries'（重拉清单）与 `seshat-library--set-entries'
（只按缓存重算状态列）两个函数填充，用户不能就地编辑（`tabulated-list-mode'
本身把 buffer 设为只读）。

**只读视图**：本 mode 只发清单请求；除 `d'（删本地副本）外不改任何文件，任何键
都不会写远端。`ondemand' 根在服务端本就是只读的，这里不制造撞墙的机会。

evil 是**软依赖**：`seshat-reader--disable-evil' 存在时调它把 magic state 关掉
（书架是纯粹的选择界面，normal state 的 `d' / `u' 语义会与之冲突），不存在时零
副作用——不 require reader 包，也不报错。"
  (setq tabulated-list-format seshat-library--column-format)
  (setq tabulated-list-sort-key nil)
  ;; 父 mode 已把 `revert-buffer-function' 设为 `tabulated-list-revert'，此处显式
  ;; 重申一次：`g' 与 `M-x revert-buffer' 因此都走「重拉清单」这同一条路。
  (setq-local revert-buffer-function #'tabulated-list-revert)
  (add-hook 'tabulated-list-revert-hook #'seshat-library--reload-entries nil t)
  (tabulated-list-init-header)
  (when (fboundp 'seshat-reader--disable-evil)
    (funcall 'seshat-reader--disable-evil)))

;;;###autoload
(defun seshat-library (&optional root)
  "打开书架 buffer `*Seshat Library*'，列出 `ondemand' 根的远端清单.
ROOT 为根 tag 字符串时只列该根（按 `seshat-library--roots' 的 tag 用 `equal'
比较）；nil（默认）时列全部 `ondemand' 根。

DIR 未配置的根无法定位落点，只在 echo area 提示，不出现在列表里；某个根拉清单
失败只是少一批行，不会让书架打不开。

交互调用时用前缀参数（`C-u M-x seshat-library'）可从现有 `ondemand' 根的 tag
里选一个过滤——tag 是用户配置里的字符串，除此之外不做任何猜测式归一。

打开书架**只发清单请求**，不改远端也不改本地文件。返回书架 buffer，便于程序化
调用后继续在该 buffer 里操作。"
  (interactive
   (list (when current-prefix-arg
           (let ((tags (mapcar #'car (seshat-library--roots))))
             (and tags (completing-read "根 tag: " tags nil t))))))
  (let ((buffer (get-buffer-create seshat-library--buffer-name)))
    (with-current-buffer buffer
      (seshat-library-mode)
      (setq seshat-library--roots-filter root)
      (seshat-library--reload-entries)
      (tabulated-list-print))
    (pop-to-buffer buffer)
    buffer))

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
  (let ((uid (tabulated-list-get-id)))
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
  "强制重新下载当前行的书，并刷新「状态」列（`u'）.
`ondemand' 根的本地副本没有可检测的过期信号（`blob' 恒空、同步事件不带 size /
mtime），所以刷新只能是显式的：本命令以 FORCE 非 nil 调 `seshat-library-fetch'，
即使本地已有副本也重下。

重下成功后**只重算状态列**（用缓存的远端清单），不再拉一次清单：重下不会改变
书名 / 根 / 大小，多一次往返没有收益。"
  (interactive)
  (let ((uid (tabulated-list-get-id)))
    (unless (stringp uid)
      (user-error "当前行没有对应的书"))
    (unless (seshat-library-fetch uid t)
      (user-error "刷新本地副本失败：%s" uid))
    (seshat-library--redisplay)
    (message "已刷新本地副本：%s" uid)))

(defun seshat-library-delete-local-at-point ()
  "删除当前行的书的**本地副本**（`d'）.
`ondemand' 根只读：本命令**不发任何远端请求**（远端文件一律保留），也不改状态
库——删掉文件后该条目自然退回「未下载」，下次 `RET' 会重新取书。

路径必须经 `seshat-sync--root-dir' + `seshat-sync--local-path' 拼出并校验：
`seshat-state-path-for-uid' 只负责给出 `(ROOT . PATH)'，**不用它直接拼路径**——
那样会绕过越界校验，让一条被篡改的相对路径删掉根目录之外的文件。根未配置目录或
路径越界 → `user-error' 且**不删任何东西**（失败方向安全）。

**root 必须是 `ondemand' 根**（`seshat-library--ondemand-root-p'）：服务端清单
若把 `mirror' 根的 uid 混进来，这条命令就会删掉用户未提交的笔记，因此 mode 不符
同样 `user-error' 且不碰磁盘。"
  (interactive)
  (let ((uid (tabulated-list-get-id)))
    (unless (stringp uid)
      (user-error "当前行没有对应的书"))
    (let* ((location (seshat-state-path-for-uid uid))
           (root (car-safe location))
           (path (cdr-safe location)))
      (unless location
        (user-error "本地状态库没有 uid %s 的登记，没有可删的本地副本" uid))
      ;; mode 门（安全底线）：只有 `ondemand' 根才是书库。`mirror' 根上的文件是
      ;; 用户自己正在编辑的笔记——「按 `d' 删掉未提交笔记」是这条命令最不能出的错。
      (unless (seshat-library--ondemand-root-p root)
        (user-error "根 %s 不是书库（ondemand）根，拒绝删除本地副本" root))
      (let* ((root-dir (seshat-sync--root-dir root))
             (local (and root-dir (seshat-sync--local-path root-dir path))))
        (cond
         ((null root-dir)
          (user-error "根 %s 未配置本地目录，无法定位本地副本" root))
         ((null local)
          (user-error "服务端路径 %s 越界（根 %s），拒绝删除" path root))
         ((not (file-exists-p local))
          (message "本地副本不存在：%s" local)
          (seshat-library--redisplay))
         (t
          (delete-file local)
          (seshat-library--redisplay)
          (message "已删除本地副本：%s" local)))))))

(provide 'seshat-library)

;;; seshat-library.el ends here
