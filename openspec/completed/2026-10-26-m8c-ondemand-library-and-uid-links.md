# M8-C：按需取书（ondemand 根）· `seshat:` uid 稳定跟随 · 透明性验证

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅、计划 ✅、执行 ✅、验证 ✅（L1/L2 全绿；L3 未验证——服务端未运行且需交互式 Emacs，见 T7 执行结果）
- 审查记录：plan-reviewer 共 **三轮** 复审——首轮**不通过**（2 blocking：分页策略不可实现、透明性差分基线不成立；5 major；3 minor）→ 第二轮**不通过**（2 blocking：advice 断言方向反了、`uid:` 前缀与 tag 歧义；2 major；4 minor）→ 第三轮**不通过但无 blocking**（3 major：uid 正则字符集、`advice--p` 调用对象、D1/T1⑪ 口径漂移；3 minor）→ 已全部修订，待第四轮终审 → 第四轮**终审通过**（无 blocking / 无 major，仅 N11/N12 两条注释范围 minor，已落入 T1）
- 执行进展：T1–T9 **全部完成**（T1 数据层 / T2 书架 buffer / T3a 解析与构造 / T3b 全部插入与导出路径 / T4 follow 按需下载链 / T5 透明性断言 / T6 文档沉淀 / T7 全量验证与归档 / T8 服务端 `uid:` 前缀 / T9 协议文档）；L1（warning 33 = 基线、checkdoc 0）+ L2（Elisp **28 文件 1110 例** 0 unexpected 0 skipped；Go **13 包全 PASS**）全绿；L3 未验证（服务端未运行）
- 下一步：代码审查（code-reviewer）→ 文档同步复核
- 归档：已移入 `openspec/completed/2026-10-26-m8c-ondemand-library-and-uid-links.md`

## 目标

本计划交付三项能力，全部落在 Emacs 客户端与文档（**计划外追加**：T8 服务端识别 `seshat:uid:<uid>` 前缀、T9 协议文档同步——原「服务端零改动」口径作废，见「任务」T8/T9 与「已知取舍」）：

1. **书架 + 按需取书**：新增 `emacs/seshat-library.el` 与 `seshat-library` 命令，列出 `ondemand` 根的服务端清单（书名 / 根 / 大小 / 本地状态），`RET` 即取书到本地并打开阅读，`u` 显式强制刷新本地副本，`d` 删本地副本。
2. **`seshat:` 链接的 uid 稳定跟随**：新增 `seshat:uid:<uid>[#<location>]` 形态，链接身份改由服务端权威 uid 承载，`doc-id`（`tag:relative-path`）降级为人类可读描述；**所有**新产生的 `seshat:` 链接（`org-store-link`、摘录、批注引用、copy-link）在能解析出 uid 时均为 uid 形态；既有 doc-id 形态继续可用。
3. **透明性可验证**：把「Emacs 端零侵入」从人工目视升级为自动化断言（**加载后白名单式反向断言**，不依赖加载前基线），并把边界写进文档。

**完成后用户可感知的变化**：

- 从未下载过的电子书，在 `*Seshat Library*` 里 `RET` 一下即可下载到本地并打开，无需离开 Emacs 去别处取文件；
- 服务端重命名书库文件后，笔记里既有的 `seshat:` 链接仍能打开同一本书（uid 稳定，路径变化不再导致链接失效）；
- **所有**新产生的 `seshat:` 链接（`org-store-link`、摘录、批注引用、copy-link）在能解析出 uid 时均为 uid 形态（文件里呈现为 `seshat:uid:...`），旧链接照旧可解析；
- 有测试守护「装上 seshat 之后 denote 改名、dired 改名与删除、org-agenda 生成这三项行为与未装时一致」。

## 根本问题

服务端早已把 uid 定为权威身份，客户端也已有按 uid 定位的能力（`seshat-state-path-for-uid`，零网络，无需打服务端即可给出 `(ROOT . PATH)`），但 Emacs 端只用到这套能力的一半：多根配置里 `ondemand` 根只被「登记索引」而不被「取用」，`seshat:` 链接仍以路径派生身份。于是出现两条断头路：

- ① **`ondemand` 根等于只读死镜像**：下载只在 `changes` 事件抵达且本地缺文件时触发，首同步只登记 `uid ↔ (root,path)` 不下载，且没有任何「列出远端书库 / 主动取书」的入口；本地已有副本时事件又被判定为无需下载，服务端更新后的副本永不刷新（F1/F2/F3）。
- ② **改名即断链**：链接的 `doc-id` 是 `tag:relative-path`，路径一改就失效，而 uid 本就是改名稳定的唯一身份（F4/F5）。

两条断头路是同一个缺口：**uid 已存在，但客户端没有把它当作身份使用**。第三项交付（透明性断言）是同一缺口的护栏——集成要动 reader 与链接层，若不把「不侵入宿主生态」写成机械可验证的不变量，改造无法安全落地。

## 事实清单

| # | 事实 | 证据 |
|---|---|---|
| F1 | `ondemand` 根的下载只在 `changes` 事件抵达且本地缺文件时触发；首同步的预建索引只登记 `uid ↔ (root,path)`，不下载 | `emacs/seshat-sync.el:677-683` |
| F2 | `ondemand` 根 `blob` 恒为空串，`changes` 事件无 `size/mtime`；本地已有副本时 `need-download` 恒 nil，服务端更新书库文件后本地副本永不刷新 | `docs/api.md:526`、`docs/sync-protocol.md:481`、`emacs/seshat-sync.el:679` |
| F3 | 没有任何「列出远端书库 / 主动取书」的 Emacs 入口；`seshat-sync-cmd.el` 全是同步编排，`seshat-library-add`（`emacs/seshat-reading.el:462`）是反方向（上传入库） | `emacs/seshat-sync-cmd.el`、`emacs/seshat-reading.el:462` |
| F4 | `seshat:` 链接的 doc-id 是 `tag:relative-path`，路径改名即失效；解析用 `seshat-reader-annotation-roots` 这一套独立根配置，不查 uid | `emacs/seshat-reader/seshat-reader-reference.el:135`、`:168-180` |
| F5 | uid 是改名稳定的唯一身份，`seshat-state-path-for-uid`（零网络）已能给出 `(ROOT . PATH)` | `emacs/seshat-state.el:415-423` |
| F6 | 服务端 `GET /api/resources?root=`（分页）与 `GET /api/files?root=`（整份下载）能力齐备；`GET /api/resources/{uid}` 可 uid → root/path | `emacs/seshat-rest.el:455-500`、`:501-524` |
| F7 | Emacs 端存在两套根配置：`seshat-state-roots`（同步，`TAG DIR MODE`）与 `seshat-reader-annotation-roots`（批注/引用，`TAG . DIR`） | `emacs/seshat-sync.el:181`、`emacs/seshat-reader/seshat-reader-annotation.el:133` |
| F8 | `seshat-reading-mode` 只接管 `auto-mode-alist` 中指向 `seshat-reader-mode` 的项（PDF/EPUB 等），不碰 `.org`；同步引擎唯一写 org 的路径是 412 冲突合并写冲突标记 | `emacs/seshat-reading.el:586-598`、`emacs/seshat-sync.el:1071-1186` |
| F9 | Android 侧「书架 + 按需下载」已实现并真机验证：`BookDownloader.ensureLocal` 先写 `.part` 再 `renameTo`（`.part` 是 Android 端实现，Emacs 端对应机制是 `make-temp-file` + `rename-file`） | `docs/android.md:353` |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | 「按需取书」的价值不在 Emacs 端读 PDF（那是 reader 的事），而在让本地镜像按需补齐 | `假设?` |
| A2 | `ondemand` 根的本地副本可能过期是**可接受**的已知边界，本计划只提供显式刷新（键位 `u` / 命令），不做自动比对 | `事实✓`（F2）+ `假设?`（接受取舍） |
| A3 | `seshat:` 链接改由 uid 承载身份、doc-id 仅作人类可读描述，是改名稳定性的根治方式，且必须向后兼容既有 doc-id 形态 | `事实✓`（F5）+ `类比⚡`（Android 端 uid 化，`docs/android.md:356`） |
| A4 | 两套根配置（F7）**不在本计划统一**：统一会牵动批注/翻译/离线队列整条链路，风险与收益不成比例 | `假设?` |
| A5 | 「透明性」可用零侵入断言（加载后白名单式反向断言，不依赖加载前基线）自动化验证，不必只靠人工 | `假设?` |

## 设计

### D1 新增模块 `emacs/seshat-library.el`（项目层，不属 reader 包）

模块放在 `emacs/` 顶层（与 `seshat-sync.el` / `seshat-state.el` 同级），**不属于** vendored 的 reader 包；依赖方向见 D7。函数清单：

```elisp
(seshat-library--roots)                               ; → ((TAG DIR MODE) ...)
(seshat-library--remote-entries (tag &optional prefix) ) ; → (item ...)
(seshat-library--local-state (item))                  ; → downloaded | missing | unregistered
(seshat-library-fetch (uid &optional force))          ; → t | nil
```

- `seshat-library--roots` —— 返回 `seshat-state-roots` 中 mode 为 `ondemand` 的 `(TAG DIR MODE)`；DIR 为空的根跳过（不参与后续取书，避免拼出 `/` 级路径），但在返回值中可辨识（不静默丢弃，供上层给出「根未配置目录」的可见提示）。
- `seshat-library--remote-entries (tag &optional prefix)` —— 调 `seshat-rest-list-resources`，实参 `:root TAG`、`:prefix PREFIX`、`:limit 2000`，用 **`:since-mtime` 翻页**：该参数语义是「mtime >= SINCE」（`docs/api.md` §1.5），客户端用本页最后一项的 `:mtime` 作为下一页的 `since-mtime`；服务端 `/api/resources` **无 offset 分页**（`docs/api.md:1146`），不得按 offset 循环。翻页**直接复用**既有已测试函数 `seshat-sync--next-since-mtime (since items)`（`emacs/seshat-sync.el:373`），它在「同秒且该秒内记录多于一页」时强制 `(1+ mtime)` 前进以避免死循环——**代价是同秒剩余记录被跳过，这是已知代价**（与 M8-B 首同步建索引同一手法，见 `emacs/seshat-sync.el:437-480` 的 `--index-root`）。仅当本页 `items` 非空**且**最后一项 `:mtime` 不大于请求的 `:since-mtime`（即「同秒超页」这一成因）时才 `message` 提示一次「清单可能不完整（同秒记录超页）」，不重试、不补救；`items` 为空但 `has-more` 为真、或 `mtime` 非数字这两种退化成因**不提示**（`seshat-sync--next-since-mtime` 的另两种分支）。返回 item 列表，item 键为 `:uid :root :path :kind :blob :rev :size :mtime :created-at :updated-at :deleted-at`。
- `seshat-library--local-state (item)` —— 返回 `downloaded`（已登记且本地文件存在）/ `missing`（已登记但本地缺文件）/ `unregistered`（本地状态库无此 uid）三态之一。
- `seshat-library-fetch (uid &optional force)` —— 取书事务，实现见 D2；`force` 非 nil 时即使本地已有副本也重新下载。

**错误契约**：所有网络失败降级为 `display-warning` + 返回 nil，**不抛错**（沿用 `seshat-sync--apply-event` 的契约，避免定时器/批量路径被中断）；只有「用户配置错误 / 越界 / 404」用 `user-error`。

### D2 取书事务（顺序固定，任一步失败即中止并返回 nil）

1. 由 UID 得到 `(ROOT . PATH)`：优先 `seshat-state-path-for-uid`（零网络）；缺失则 `seshat-rest-get-resource` 取 `:root` / `:path`。
2. `seshat-sync--root-dir ROOT` 取本地根目录；为 nil 则 `user-error`（提示配置 `seshat-sync-roots`）。
3. `seshat-sync--local-path DIR PATH` 做越界校验（PATH 来自服务端，不可信，这是安全底线）；为 nil 则 `user-error`。
4. `seshat-rest-download-file PATH TARGET :root ROOT` —— 该函数内部经 `seshat-rest--write-binary-file`（`emacs/seshat-rest.el:623-640`）用 `make-temp-file` 生成随机临时名 + `rename-file` **已完成原子落位**，library 只传最终 TARGET，**不自行写任何临时文件**（`.part` 是 Android 端命名，Emacs 端不存在该机制；自写固定名会在并发取书时冲突、中断时残留半文件）。
5. `seshat-sync--event-set-location UID ROOT PATH` + `seshat-state-set-base-blob UID "" SIZE MTIME`——`ondemand` 根 blob 恒为空串（F2），SIZE / MTIME 取落盘后本地 `file-attributes`。**为何不用 `seshat-state-remap`**：`seshat-state-remap` 是**改名语义**（会清 `:orphan` 并把占据同路径的旧属主标孤儿），取书只是重申服务端位置，不应改动其它 uid——与 `seshat-sync--event-set-location` 的 docstring（`emacs/seshat-sync.el:579-597`，明确写「不走 remap」）判断一致。
6. `seshat-state-save`。

**不做内容比对、不进入 push 路径**（`ondemand` 根只读）。`force` 非 nil 只影响第 1 步之后「本地已存在」的短路判断，其余六步不变。

### D3 书架 buffer

- `seshat-library-mode` 派生自 `tabulated-list-mode`，buffer 名 `*Seshat Library*`。
- 列：「书名（`file-name-nondirectory`）/ 根 / 大小 / 状态」。
- 键位：`RET` = `seshat-library-open-at-point`（先取书 → `seshat-reading-open` 打开阅读）；`u` = 强制刷新本地副本（以 `force` 非 nil 调 `seshat-library-fetch`）；`d` = 删**本地副本**（绝不删远端，`ondemand` 根只读）；`g` = 重拉远端清单（`revert-buffer` 语义）；`q` = `quit-window`。

> **零网络不变量（T2 执行期修正，2026-10-26）**：`g` 的「重拉远端清单」挂在 `revert-buffer-function` 上；因此 `d`（删本地副本）与 `u`（刷新副本后重画状态列）**不得**走 `tabulated-list-revert`，否则会顺带发一次 `GET /api/resources`，违反「`seshat-library` 除取书外不发任何请求」的约束。两者改用内部 `seshat-library--redisplay`（按 buffer-local 缓存重算状态列并重画）。**`d` 绝不发远端请求**这一点必须有测试断言（断言前后 `--remote-entries` 调用次数不变）。

- 入口命令 `seshat-library`，可选参数为根 tag 过滤；缺省列全部 `ondemand` 根。
- mode body 内**软依赖**关 evil：`(when (fboundp 'seshat-reader--disable-evil) (funcall 'seshat-reader--disable-evil))`——evil 缺失时零副作用（不 require、不报错）。

### D4 `seshat:` uid 形态

- 新增形态 `seshat:uid:<uid>[#<location>]`。
- `seshat-reader-reference--parse-link` 识别 `uid:` 前缀：返回 plist 增加 `:uid`，此时 `:doc-id` 为 nil。现有 `tag:path` 形态的解析**逐字不变**（回归测试守护）。

> **`uid:` 前缀的判别优先级（必须遵守）**：`--parse-link` 剥掉 `seshat:` 后，若字符串以 `uid:` 开头，**且** `uid:` 之后到第一个 `#` 之前的部分匹配 `[0-9A-HJKMNP-TV-Z]\{26\}`（服务端 uid 的权威形态：26 位 Crockford Base32，排除 I/L/O/U；`internal/registry/uid.go:29`、`docs/adr/0003-uid-identity-model.md:18`、`docs/api.md:74`、`docs/sync-protocol.md:40`），才判为 uid 形态；否则**回落 doc-id 形态**（即把 `uid` 当作一个普通的根 tag 处理）。因此根 tag 叫 `uid` 是合法的（`docs/configuration.md:57` 只要求 tag 非空、唯一、不含 `:`），不需要改配置；只有「tag 为 `uid` 且相对路径恰好是 26 位大写字母数字」这一极端组合会误判为 uid 形态，接受该风险（记录在「已知取舍」）。
>
> 判别顺序固定为：`local:` 前缀 → doc-id（绝对路径形态）；`uid:` + 26 位校验 → uid 形态；其余 → `tag:path` 形态。
>
> **字符集依据**：字符集取自服务端 `internal/registry/uid.go:29` 的 `^[0-9A-HJKMNP-TV-Z]{26}$`（Crockford Base32 排除 I/L/O/U）；`emacs/seshat-rest.el:503` 的既有注释写作 `[0-9A-Z]` 是**不精确的**，以服务端代码为准。

- 新增**单一身份解析入口** `seshat-reader-reference--identity (doc-id)` → 返回 `(:uid UID)` 或 `(:doc-id DOC)`：先按 `seshat-reader-annotation-roots` 得 `(tag . rel)`，再**软依赖** `seshat-state-uid-for-path` 查 uid；命中返回 uid，未命中返回 doc-id。**零网络**。
- 全部产链接的路径（`:store`、`--format-block`（摘录）、`insert`、`insert-annotation`、`copy-link`）**统一经该入口**决定形态，不再各自拼 doc-id。
- `:link` 侧新增构造 uid 形态的函数，**不复用** doc-id 版签名（两个形态的参数语义不同，合一会让调用方无法区分）。
- `:complete` **保持不变**（候选仍是人类可读 doc-id：换 uid 会让补全不可用）。
- `:export` 与 `--description` **必须支持 uid 形态**：uid → 文件名（零网络经 `seshat-state-path-for-uid` 取 `file-name-nondirectory`）；查不到时回退输出含 uid 的**非空**文本（如 `uid:<前 8 位>…`），**绝不允许输出空串**。回落格式**定死为**：`uid` 长度大于 8 时取前 8 位加 `…`（如 `uid:01J8ZKQ2…`），不大于 8 时原样输出 `uid:<uid>`——该字符串必须与 `docs/emacs-reader.md` 的说明、T3b 的断言三处逐字一致。

> **判据补充（T3b 执行期修正，2026-10-26）**：`--description` / `:export` 的 uid 分支除接受严格 26 位 uid 外，还接受「裸 Crockford Base32 串」（非空、不含 `:` / `#` / `%`、字符集合法）——因为回落标识 `uid:<前8位>…` 需能处理非 26 位输入，而合法 doc-id 必含 `:`，两者不可能相撞。**该放宽只作用于描述/导出，不作用于 `--parse-link` 的链接形态判别**（后者仍严格要求 26 位）。

### D5 follow 的按需下载链（`:follow` 分支顺序）

1. uid 形态 → `seshat-reader-reference--file-from-uid`（D4 定义的零网络函数，内部即 `seshat-state-path-for-uid` + `seshat-state-roots` 的 DIR 拼接）→ 本地绝对路径。
2. 本地文件存在 → 直接打开。
3. 不存在且软依赖 `seshat-library-fetch` 可用 → 调用它取书。
4. 软依赖缺失或取书失败 → `user-error` 说明原因（明确告知缺什么、为什么打不开）。
5. doc-id 形态走现有逻辑，**完全不变**（回归测试守护）。

软依赖实现口径：`fboundp` 探测 + `declare-function`，**不得 require**（硬约束见 D7）。

### D6 透明性断言（加载后白名单式反向断言）

新增 `emacs/tests/seshat-transparency-test.el`，把「零侵入」写成断言：**加载后白名单式反向断言**——不依赖「加载前」基线，断言「不该出现的东西不出现」。加载 `seshat-sync` / `seshat-reading` / `seshat-library` 后逐条断言（六项可执行口径）：

1. `.org` 文件的实际 major mode 不是 seshat 系：断言 `(assoc-default "x.org" auto-mode-alist 'string-match)` 既不是 `seshat-reading-mode` 也不是 `seshat-reader-mode`（用 `auto-mode-alist` 的实际匹配方式，不要假设条目字面是 `"\\.org\\'"`）；
2. `dired-mode-map` 中不存在任何绑定到「symbol 名以 `seshat-` 开头的命令」的键：断言前先 `(require 'dired)`；用 `map-keymap` 遍历 `dired-mode-map` **自身及其前缀子 keymap（含 `remap`）**——只扫 `map-keymap` 顶层会漏掉前缀绑定与 `remap` 伪事件（实测：`(define-key dired-mode-map (kbd "C-c z") 'seshat-x)` 与前缀绑定都落在子 keymap 里，顶层查不出，断言会半空）；遍历时必须递归前缀子 keymap，但**不跟随 `keymap-parent`、不看 `global-map`**（按命令反查按键的查询函数会连带搜索父 keymap 链与 `global-map`，无法限定「只查自身」，故不用它），对每对 `(EVENT CMD)` 判断 `CMD` 的 symbol 名是否以 `seshat-` 开头，断言不存在；
3. `after-save-hook` 与 `after-change-major-mode-hook` 中不存在 symbol 名以 `seshat-` 开头的函数；
4. **advice 白名单断言**：遍历 `obarray`，对每个符号 `SYM` 取 `(symbol-function SYM)`，若 `(advice--p (symbol-function SYM))` 非 nil 则把 `SYM` 计入「被 advice 的函数集合」，断言该集合 **⊆ 已知白名单**。**注意 `advice--p` 接受的是函数对象、不是符号**（`nadvice.el` 的 `oclosure-define` 谓词，签名 `(advice--p OCLOSURE)`）；对符号直接调用恒返回 nil，会导致集合恒空、断言恒真（假绿）。白名单初始值为**两个**元素：`save-place-to-alist`（`emacs/seshat-reader/seshat-reader-saveplace.el:66` 的既有实现，reader 包集成 saveplace 所需，属 vendored 既有行为、非本计划引入）与 `pcase--mutually-exclusive-p`（stock Emacs `cl-macs.el` 在 `cl-lib` 加载时自带的 advice，装不装 seshat 都存在；不纳入会因**无关原因**永久失败）。**新增任何 advice 都必须先更新该白名单**——白名单的变更即侵入评审点，断言失败时先问「为什么要 advice 第三方函数」而不是直接加白名单。
   - **匿名 lambda advice 的处置**：谓词作用在 `(symbol-function SYM)` 上，只反映该符号绑定的函数对象是否被 advice、不看 advice 函数自身（是具名还是 lambda），因此匿名 lambda（如 saveplace 那一条）也能被本断言覆盖——它体现在「被 advice 的函数名进入集合」这一事实里，不需要识别 lambda 的来源。这正是选「按被 advice 的函数名建白名单」而非「按 advice 函数名前缀过滤」的原因。
5. 加载 `seshat-reading` 后 `.org` 文件不会进入 seshat 系 mode（用临时 buffer + `set-auto-mode` 断言，与第 1 项区分开：第 1 项断言 alist 事实，本项断言实际行为）；
6. `seshat-library-mode` 未在 `auto-mode-alist` 中注册任何条目。

- **性能**：第 2 项（`map-keymap` 遍历 `dired-mode-map`）与第 4 项（`obarray` 全量遍历）在装载大量第三方包的 ERT 进程里可能较慢；第 4 项先按 `intern-soft` 候选集过滤，再对每个 `(symbol-function SYM)` 调 `advice--p`。性能仅作观测记录，**不改变断言范围**（断言覆盖范围固定，不随耗时动态调整）。

**为何不用加载前后差分**：共享 ERT 单进程里模块早已 `require` 完成，`require` 幂等 → 差分恒为空 → 断言恒通过（假绿）；且 `seshat-reading--take-over-auto-mode-alist` 是就地改写，第二次执行零效果。因此改为白名单式反向断言：不依赖「加载前」基线，断言「不该出现的东西不出现」。

断言若发现真实侵入，视为本计划缺陷，在计划内修（不放行、不记 tech-debt 了事）。

**执行期修正（2026-10-26，T5 的变异自检证据）**：① advice 白名单由 1 项扩为 2 项（新增 `pcase--mutually-exclusive-p`，stock cl-lib 基线）；② `dired-mode-map` 断言由「只扫顶层」改为「递归前缀子 keymap（含 `remap`），不跟随父链与 global-map」——若按原字面实现，注入假侵入也不会被检出。

### D7 依赖方向（硬约束）

- `emacs/seshat-reader/**` **不得 require** `seshat-library`——vendored 包的反向依赖纪律，沿用 `seshat-reading-quiet-p` 的软依赖先例（`fboundp` 探测 + `declare-function`）。
- `emacs/seshat-library.el` 可 `require 'seshat-reading`（`seshat-reading-open` 用于书架 `RET` 打开文档）；依赖链单向 `library → reading → reader`，reader 包不反向依赖 library，无环。
- `emacs/seshat-library.el` 可 require `seshat-rest` / `seshat-state` / `seshat-sync`（单向：项目层依赖基础设施层与引擎层）。

### D8 安全

- 所有落盘路径必须过 `seshat-sync--local-path`（越界即拒绝，不自行拼接路径字符串）。
- `ondemand` 根**绝不写远端**：`seshat-library` 不发任何写请求；`d` 键只删本地副本。
- 删本地副本前校验路径在该根内（同一校验函数，不另写一套）。
- 下载复用 rest 层的 `make-temp-file` + `rename-file` 原子落位（`seshat-rest--write-binary-file`），library 不自写临时文件（中断不留半文件、不污染本地清单的三态判定）。

## 任务

勾选总览（执行完成一项就把 `[ ]` 改为 `[x]`，并与下方各任务标题的勾选保持一致）：

- [x] T1 `emacs/seshat-library.el` 数据层（D1 + D2）
- [x] T2 书架 buffer（D3）
- [x] T3a uid 形态的解析与构造（D4 前半）
- [x] T3b uid 形态接入全部插入与导出路径（D4 后半）
- [x] T4 follow 的按需下载链（D5）
- [x] T5 透明性自动化测试（D6）
- [x] T6 文档沉淀
- [x] T7 验证与归档
- [x] T8 服务端识别 `uid:` 前缀（计划外新增，用户 2026-10-26 确认）
- [x] T9 协议文档与计划范围修订（计划外新增）

### [x] T1 `emacs/seshat-library.el` 数据层（D1 + D2）

- 动作：新建 `emacs/seshat-library.el`，实现 `seshat-library--roots` / `--remote-entries` / `--local-state` / `seshat-library-fetch` 四个函数与 D2 的六步取书事务；测试写入新文件 `emacs/tests/seshat-library-test.el`。**改动文件范围另含 `emacs/seshat-rest.el` 与 `emacs/tests/seshat-rest-test.el`**——两者均**仅为注释字符集修正**，不改任何可执行代码（见下方「收尾动作」）。
- 收尾动作（与本计划的 uid 判别规则同源）：修正**三处** uid 注释字符集 `[0-9A-Z]` → `[0-9A-HJKMNP-TV-Z]`，路径与行号：
  - `emacs/seshat-rest.el:503`
  - `emacs/seshat-rest.el:776`
  - `emacs/tests/seshat-rest-test.el:252`（测试 docstring，同样写「uid 只含 `[0-9A-Z]`」）

  三处均为照抄源，一处不改就会有后来者继续照抄。
- 依赖：无（可与 T3a、T5 并行）
- 验收：新增 ERT ≥10 例，全桩 transport——① 分页按 `:has-more` 循环（构造两页，断言调用 2 次）；② 三态判定各 1 例（`downloaded` / `missing` / `unregistered`）；③ 取书事务六步顺序（记录调用序列断言，按修订后的函数名断言——步骤 5 为 `seshat-sync--event-set-location`；步骤 2/3 是纯本地函数，需用 `cl-letf` 打桩 `symbol-function` 记录调用序列，网络步骤用既有 transport 桩）；④ 根目录未配置 → `user-error`；⑤ 路径越界 → `user-error`；⑥ 404 → 不再重试（断言只发一次请求）；⑦ `set-base-blob` 的 blob 为 `""`、size/mtime 取本地 `file-attributes`；⑧ 下载失败返回 nil 且不发第二次请求；⑨ `seshat-state-save` 被调用一次（桩计数）；⑩ 分页用 `:since-mtime` 前进：构造两页，断言第二次请求的 `:since-mtime` 等于首页最后一项的 `:mtime`（桩断言实参）；⑪ 同秒超页时 `:since-mtime` 为 `(1+ mtime)`（复用 `seshat-sync--next-since-mtime` 语义），且发生跳秒时不重试、只提示一次（`message` 桩计数为 1）；**提示的检测条件写死**：**仅当**本页 `items` 非空**且**最后一项 `:mtime` 不大于请求的 `:since-mtime`（即真正的「同秒超页」成因）时才 `message` 提示；`items` 为空但 `has-more` 为真、或 mtime 非数字这两种成因**不提示**（`seshat-sync--next-since-mtime` 的另两种退化分支）。断言两例：构造「items 非空 + 同秒」→ 提示 1 次；构造「items 空 + has-more」→ 提示 0 次。 ⑫ **注释修正的验证**：注释-only 变更不进 ERT，由 L1 门禁覆盖——对 `emacs/seshat-rest.el` 与 `emacs/tests/seshat-rest-test.el` 执行 `emacs --batch -Q -L emacs -L emacs/seshat-reader -f batch-byte-compile`（0 warning 0 error）+ 逐行 `git diff` 确认只改了注释字符集、无代码逻辑变动。
- ✅ 执行结果（2026-10-26）：新建 `emacs/seshat-library.el`（345 行，4 个函数：`--roots` / `--remote-entries` / `--local-state` / `seshat-library-fetch`）与 `emacs/tests/seshat-library-test.el`（**21 例**全绿）；分页复用 `seshat-sync--next-since-mtime`；步骤 5 用 `seshat-sync--event-set-location`（merge 语义）；未自写 `.part`；L1 三文件 0 warning 0 error；3 处 uid 注释字符集已改为 `[0-9A-HJKMNP-TV-Z]`（`seshat-rest.el:503` / `:776` / `seshat-rest-test.el:252`）

### [x] T2 书架 buffer（D3）

- 动作：实现 `seshat-library-mode` / `seshat-library` / `seshat-library-open-at-point` 与五组键位；用例追加到 `emacs/tests/seshat-library-test.el`。
- 依赖：T1
- 验收：新增 ERT ≥8 例——① 列名与行数（构造 3 条远端 item → 表头 4 列 + 3 行）；② 三态列文案（三种状态各自的显示字符串）；③ `RET` / `u` / `d` / `g` / `q` 绑定逐项断言；④ `d` 只删本地（断言无远端 DELETE 请求）；⑤ 空清单不报错只提示；⑥ `seshat-library` 的根过滤参数生效（只列指定 tag）；⑦ evil 软依赖缺失时零副作用（`fboundp` 返回 nil 时不报错、不改全局）。
- ✅ 执行结果（2026-10-26）：`seshat-library-mode`（tabulated-list 派生）+ `seshat-library` / `seshat-library-open-at-point` / `seshat-library-refresh-at-point` / `seshat-library-delete-local-at-point` 四个命令；键位 `RET` / `u` / `d` / `g` / `q`；**零新增 defcustom**；测试 21 → **38 例**全绿；transparency 回归 9/9。**执行期偏差（已采纳）**：`d` / `u` 不用 `tabulated-list-revert`，改用零网络的 `seshat-library--redisplay`——因为 `g` 的「重拉远端清单」挂在 revert 钩子上，若 `d` 也走 revert 就会发一次 `GET /api/resources`，违反「`d` 绝不发远端请求」；另有 buffer-local 缓存 `seshat-library--items` 支撑「只重算状态列」。

### [x] T3a uid 形态的解析与构造（D4 前半）

- 动作：`seshat-reader-reference--parse-link` 增加 `uid:` 前缀识别（plist 增加 `:uid`，`:doc-id` 为 nil；判别按 D4 的优先级——`uid:` 之后的部分须匹配 26 位 Crockford Base32 `[0-9A-HJKMNP-TV-Z]\{26\}`（排除 I/L/O/U）才判 uid 形态，否则回落 `tag:path` 形态）；新增 uid 形态构造函数；新增单一身份解析入口 `seshat-reader-reference--identity`；新增 `--file-from-uid`（uid → 本地路径，零网络）。用例追加到既有 `emacs/tests/seshat-reader-reference-test.el`。
- 依赖：无（与 T1/T2 文件不重叠，可并行）
- 验收：新增 ERT ≥7 例——① `uid:` 前缀解析出 `:uid` 且 `:doc-id` 为 nil；② `uid:<uid>#page:3` 的 location 正确；③ 排除判据三例（D4 判别优先级）：③a `uid:` 后为空串 / 长度非 26 / 含 `/` / 含小写字母 → **不判为 uid 形态**，按 `tag:path` 回落（断言 `:doc-id` 为原文、`:uid` 为 nil）；另一例含 I/L/O/U 的 26 位串（如 `01J8ZKQ2ABCDEFGHIJKLMNOPQR`）→ 回落 doc-id 形态（不判为 uid）；③b `uid:` + 合法 26 位 Crockford Base32 → 判为 uid 形态（`:uid` 为该串、`:doc-id` 为 nil）；③c 根 tag 名为 `uid` 的 `tag:path` 形态（如 `uid:foo.pdf`）仍按 doc-id 解析（`:doc-id` = `uid:foo.pdf`），不误判；④ 既有 `tag:path` 与 `local:` 形态的 `:doc-id` 与 `:location` 键值语义不变（回归断言，口径：**不得用整体 `equal` 断言 plist**——新增 `:uid` 键后结构必然变化，只断言 `:doc-id` 与 `:location` 的键值语义不变）；⑤ uid 形态构造函数正确（含带 location 与不带 location 两例）；⑥ `--identity` 能查到 uid 时返回 `(:uid ...)`、查不到返回 `(:doc-id ...)`（两例）；⑦ `--file-from-uid` 零网络返回本地路径、查不到返回 nil（两例）。
- ✅ 执行结果（2026-10-26）：`--parse-link` 增 uid 形态（判别用 `[0-9A-HJKMNP-TV-Z]{26}`）、新增 `--uid-string-p` / `--uid-link` / `--identity` / `--file-from-uid` / `--sync-root-dir` / `--uid-local-path`；**执行期抓到真实 bug**——`string-match-p` 默认 `case-fold-search=t` 会让小写 uid 被误判，已收敛到单一校验点绑 nil；新增 **19 例**（50 → 69），L1 warning 33 = 基线、checkdoc 0

### [x] T3b uid 形态接入全部插入与导出路径（D4 后半）

- 动作：`:store`、`copy-link`、`insert`、`insert-annotation`（批注引用）以及 `--format-block`（被 `insert` 与 `insert-annotation` 调用）统一经 `seshat-reader-reference--identity` 决定形态（不再各自拼 doc-id）；`:export` 与 `--description` 支持 uid 形态且**不输出空串**；`:complete` 保持不变。用例追加到既有 `emacs/tests/seshat-reader-reference-test.el`。
- 依赖：T3a
- 验收：新增 ERT ≥8 例——① 按 5 个入口组织（`:store` / `copy-link` / `insert` / `insert-annotation` /（`--format-block` 由 `insert` 与 `insert-annotation` 覆盖））各 1 例「能查到 uid 时产 uid 形态」；② 2 例「查不到 uid 时回落 doc-id 形态」；③ `:export` 的 uid 形态输出非空「书名 第 N 页」（1 例）；④ 回落格式逐字断言两例：④a 构造 >8 位 uid，断言回落字符串**逐字等于** `uid:<前 8 位>…`（uid 为 `01J8ZKQ2ABCDEFGH` 时回落为 `uid:01J8ZKQ2…`）；④b 构造 ≤8 位 uid，断言逐字等于 `uid:<uid>`；⑤ `--description` 两种形态各 1 例。
- ✅ 执行结果（2026-10-26）：新增 `--link-for`（唯一链接构造入口，`--identity` 决定形态）与 `--uid-fallback-label`；`--format-block` / `store-link` / `copy-link` 三处改调 `--link-for`（`insert` 与 `insert-annotation` 经 `--format-block` 一并生效）；`--description` 与 `:export` 支持 uid 形态且**恒非空**（回落格式 `uid:<前8位>…`，实测字符串 `uid:01J8ZKQ2…`）；`:complete` 未动；测试 69 → **86 例**全绿；L1 warning 33 = 基线、checkdoc 0。**执行期偏差（已采纳）**：`--description` 的 uid 判据新增「裸 Crockford Base32 串」分支（新增 `--uid-like-p`）——因为计划验收要求 16 位 uid 也能回落 `uid:01J8ZKQ2…`，而 16 位必然过不了 26 位正则，严格判据会让该验收项成死分支；**`--parse-link` 的链接形态判别未放宽**，根 tag 名为 `uid` 的兼容性不变。

### [x] T4 follow 的按需下载链（D5）

- 动作：改 `emacs/seshat-reader/seshat-reader-reference.el` 的 `:follow` 分支（`seshat-reader-reference-open`），按 D5 五步顺序接入按需下载（`fboundp` + `declare-function` 软依赖，不 require）。
- 依赖：T1、T3a
- 验收：新增 ERT ≥6 例——① uid → state path → 打开（断言最终打开的文件路径）；② 本地缺文件且软依赖可用 → 调用 `seshat-library-fetch`（桩断言实参为该 uid）；③ 软依赖缺失 → `user-error` 且**不**调用（断言桩调用 0 次）；④ 取书失败 → `user-error`；⑤ doc-id 形态 follow 行为不变（回归断言）。
- ✅ 执行结果（2026-10-26）：`seshat-reader-reference-open` 的 `:follow` 分支改三分支判定（**uid / doc-id / 非法**）；uid 分支「本地有副本直接打开 → 否则软依赖 `seshat-library-fetch` 按需下载 → 仍失败则 `user-error`」；新增 **9 例**（reference 套件 86 → **95**）；L1 warning **33 = 基线**、checkdoc 0；3 组变异自检（去掉 `file-exists-p` 门 / 去掉 `fboundp` 守卫 / 本地有副本仍取书）**全部被抓到**

### [x] T5 透明性自动化测试（D6）

- 动作：新建 `emacs/tests/seshat-transparency-test.el`，实现 D6 六项白名单式反向断言。
- 依赖：无（可先行，独立于 T1–T4）
- 验收：新增测试文件 `emacs/tests/seshat-transparency-test.el` ≥7 例（对应修订后 D6 的六项反向断言，每项至少 1 例，其中第 4 项 2 例——advice 白名单断言：断言被 advice 的函数名集合 **⊆ `(save-place-to-alist)`**；并**必须另加一例反向自我验证**：临时 `(advice-add 'ignore :around #'ignore)` 后断言集合不再 ⊆ 白名单（证明该断言真的能抓到侵入），清理段必须包在 `unwind-protect` 内（断言失败时也要执行 `advice-remove`，否则残留 advice 会污染同进程后续用例）），全部通过且 `skipped = 0`；断言须能在模块**已加载**的前提下通过，不依赖加载前基线。
- ✅ 执行结果（2026-10-26）：新建 `emacs/tests/seshat-transparency-test.el`，**9 例**全绿（六项断言 + 3 组反向自我验证），并用 **5 组变异自检**证明断言真能失败；未抓到真实侵入。执行期发现两处计划需修正（已按下节修订）：白名单需含 stock Emacs 的 `pcase--mutually-exclusive-p`；`dired-mode-map` 断言必须遍历前缀子 keymap

### [x] T6 文档沉淀

- 动作：按「## 文档清单」逐项更新（`docs/emacs-reader.md` / `docs/configuration.md` / `docs/sync-protocol.md` / `docs/architecture.md` / `CHANGELOG.md` / `openspec/decisions.md` / `openspec/tech-debt.md` / `openspec/active/roadmap.md`）。
- 依赖：T1、T2、T3a、T3b、T4、T5
- 验收：文档清单 8 项全部落地；`docs/emacs-reader.md` 新增三节且 §13 用例总数与实际 ERT 计数一致；`CHANGELOG.md` 标注**所有插入路径**的链接形态变更（doc-id → uid）；`openspec/decisions.md` 三条、`openspec/tech-debt.md` 四条均写入。
- ✅ 执行结果（2026-10-26）：`docs/emacs-reader.md`（书架「按需取书」节 / `seshat:` 双形态链接 / 透明性边界（denote / dired / org-agenda）/ §13 实测 **28 文件 1110 例**）、`docs/configuration.md`（**零新增 defcustom** / `ondemand` 根必须配 DIR / 两套根配置对照表）、`docs/sync-protocol.md`（按需取书实现要点：复用 rest 层 `make-temp-file` + `rename-file` 原子落位、`ondemand` blob 恒空、显式刷新语义）、`docs/architecture.md`（`seshat-library` 分层与依赖方向）、`CHANGELOG.md`（**3 条**）、`openspec/decisions.md`（**4 条**）、`openspec/tech-debt.md`（**5 条**）全部落地

### [x] T8 服务端识别 `uid:` 前缀（计划外新增，用户 2026-10-26 确认）

- 动作：`internal/registry/service.go` 的 `Resolve` 增 `uid:` 前缀识别（其后须为合法 26 位 Crockford Base32 uid），不合法回落 `tag:path`；`internal/registry/service_test.go` 增 ≥6 例（含 `RefreshRefs` 集成例）。
- 依赖：无（与 T1–T6 并行；改的是服务端 Go 代码，与 Emacs 侧文件不重叠）
- 验收：`go build ./...` 0 error、`go vet ./...` 0 新增告警、`go test ./...` 13 包全 PASS；`uid:<合法>` 返回该 uid、`uid:<非法>` 回落 `tag:path` 而非报 `invalid_uid`、裸 uid 与 `tag:path` 行为回归不变、含 `[[seshat:uid:<uid>]]` 的 org 经 `RefreshRefs` 后 refs 表有边。
- **背景（为何原口径作废）**：原计划明写「服务端零改动」，但核对发现客户端产出的 `seshat:uid:<uid>` 与 `registry.Resolve`（`internal/registry/service.go:226`）不对齐——服务端只认裸 uid，`uid:<uid>` 会被当成「根 tag = `uid`」的路径，`RefreshRefs` 提取不到该形态、`GET /api/refs` 缺边。用户决定**服务端补识别 `uid:` 前缀，Emacs 与服务端两端对齐，Android 不涉及**（Android 目前没有任何 `seshat:` 链接处理）。
- ✅ 执行结果（2026-10-26）：`internal/registry/service.go` 的 `Resolve` 改为**四段优先级**（空 key → 裸 uid → `uid:` 前缀（`IsUID` 校验，不合法则继续走路径分支而非报错）→ `root:path` / 默认根），新增包级常量 `uidRefPrefix = "uid:"`；`internal/registry/refs_test.go` 新增 **13 例**（含 `RefreshRefs` 集成例：含 `[[seshat:uid:<uid>]]` 的 org 经刷新后 refs 表有边）；`go build ./...` 0 error、`go vet ./...` 干净、`go test ./...` **13 包全 PASS**

### [x] T9 协议文档与计划范围修订（计划外新增）

- 动作：`docs/api.md` / `docs/sync-protocol.md` / `CHANGELOG.md` / `openspec/decisions.md` 补 `uid:` 形态说明；本计划新增 T8/T9 与文档清单修订。
- 依赖：无（规则已定，可并行 T8）
- 验收：四个文件均有 `uid:` 形态说明且与服务端实际行为一致；计划文档清单 `docs/api.md` 一行由「不改」改为「改」。
- ✅ 执行结果（2026-10-26）：`docs/api.md`（`seshat:` 引用的**四种 target 形态** + 五条解析优先级 + `RefreshRefs` 收录 `uid:` 形态）、`docs/sync-protocol.md`（`uid:` 形态进入 refs 提取）、`CHANGELOG.md`（服务端识别 `uid:` 条目）、`openspec/decisions.md`（+1 条：服务端识别 `seshat:uid:<uid>` 与客户端对齐）；计划新增 T8/T9（原「服务端零改动」口径作废）

### [x] T7 验证与归档

- 动作：跑完 L1 / L2 / L3（L3 需服务端），全过后勾选全部任务，把本文件移入 `openspec/completed/`。**不 commit**。
- 依赖：T6（且 T1–T5 全部完成）
- 验收：L1 / L2 全部通过（L2 `unexpected = 0` 且 `skipped = 0`，逐文件跑）；L3 六项通过或记「未验证」并说明；文件已位于 `openspec/completed/`；`git status --porcelain` 无意外改动文件。
- ✅ 执行结果（2026-10-26）：
  - **L1**：`make all` EXIT 0、`Warning|Error` 计数 **33 = 基线**；`make checkdoc` EXIT 0、**0 报错**；顶层 6 个 `.el` 字节编译 **0 warning 0 error**；4 个测试文件字节编译 **0 warning 0 error**；`go build ./...` 与 `go vet ./...` 均 EXIT 0 无输出；7 个本次改动/新建 `.el` 的 `check-parens` **全通过**。
  - **L2（Elisp）**：**28 个文件逐文件实测合计 1110 例**，每文件 `unexpected = 0` 且 `skipped = 0`（本次新增两文件：`seshat-library-test.el` 38 例、`seshat-transparency-test.el` 9 例；`seshat-reader-reference-test.el` 95 例）；与 `docs/emacs-reader.md` §13 声明的「28 文件 / 1110 例」**逐文件逐数字一致，无差异**。
  - **L2（Go）**：`go test -count=1 ./...` → **13 个包全 PASS，0 FAIL，0 SKIP**。
  - **L3**：**未验证**——探测 `http://127.0.0.1:8080/api/roots`（`ctx_execute` fetch，3s 超时）连接失败，`ss -lntH "sport = :8080"` 无监听，`docker ps` 无 seshat 容器、`pgrep -af seshat` 无进程；且六项验证中 ②③④⑤⑥ 需交互式 Emacs 会话（取书 / `u` 刷新 / 改名后跟随 / denote-dired-org-agenda 透明性），batch 下不可完成 → **需人工**，按计划「不阻塞归档」。
  - **归档**：勾选 T4/T6/T7/T8/T9（总览与标题一致，10/10 全 `[x]`）；本文件已移入 `openspec/completed/2026-10-26-m8c-ondemand-library-and-uid-links.md`。

## 依赖关系

```
T1 ──┬──▶ T2
     └──▶ T4
T3a ──┬──▶ T3b
      └──▶ T4
T5（独立，可先行）
T1..T5 ──▶ T6 ──▶ T7
```

- `T1 → T2`：书架 buffer 依赖数据层。
- `T1 → T4` 与 `T3a → T4`：follow 链同时需要「取书入口」与「uid 形态解析」。
- `T3a → T3b`：接入全部插入路径前先有「解析 + 构造 + 身份入口」。
- `T5` 与 T1–T4 无依赖（只断言加载后的全局状态），可先行。
- `T3a` / `T3b` 与 `T1` / `T2` 文件不重叠（改 reader 包内文件 + 既有 reader 测试），**可并行**。
- `T6` 依赖 T1–T5；`T7` 最后。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `docs/emacs-reader.md` | 新增「书架：按需取书」节；`seshat:` 链接的 uid 形态与兼容性（**全部插入路径统一 uid 形态**：`org-store-link` / 摘录 / 批注引用 / copy-link）；新增「透明性边界」节（denote / dired / org-agenda）；§13 用例总数 | T6 |
| `docs/configuration.md` | 若新增 defcustom（书架根过滤、下载上限等）则补；否则写明「本计划零新增 defcustom」 | T6 |
| `docs/sync-protocol.md` | 新增「Emacs 客户端按需取书实现要点」：`make-temp-file` + `rename-file` 原子落位（复用 rest 层）、`ondemand` 根 blob 为空、显式刷新语义 | T6 |
| `docs/architecture.md` | Emacs 客户端分层补 `seshat-library` 一层及其与 `seshat-sync` / `seshat-state` 的依赖方向 | T6 |
| `docs/api.md` / `docs/errors.md` | `docs/api.md`：`seshat:` 引用语法补 `uid:` 形态与回落规则（§6 解析优先级同步为服务端 `Resolve` 的四段判定）→ 由 **T9** 改；`docs/errors.md`：仍**不改**（无新错误码，`uid:<非法>` 走回落而非报错） | T9 |
| `CHANGELOG.md` | `[Unreleased]`：新增书架与按需取书、`seshat:` uid 形态（行为变更提示：**所有产生 `seshat:` 链接的路径**（`org-store-link`、`C-c C-r` 摘录、批注引用插入、`copy-link`）在能解析出 uid 时改为输出 uid 形态）；另由 T9 追加服务端识别 `uid:` 形态的服务端条目 | T6 / T9 |
| `openspec/decisions.md` | 三条：按需取书复用 rest 层原子落位（`make-temp-file` + `rename-file`，library 不自写临时文件）+ 显式刷新（不自动比对）；`seshat:` 改由 uid 承载身份且向后兼容（全部插入路径统一）；两套根配置暂不统一。另由 T9 追加第四条：服务端识别 `seshat:uid:<uid>`，与客户端 uid 形态对齐 | T6 / T9 |
| `openspec/tech-debt.md` | 新增：两套根配置待统一；`ondemand` 副本过期无可检测信号；`seshat-library` 清单一次性拉全根；reader 包对 `save-place-to-alist` 的 advice 是既有侵入（vendored 行为），已纳入透明性白名单，任何新增 advice 需先更新白名单 | T6 |
| `openspec/active/roadmap.md` | 更新 M8.4 / M8.5 / M8.6 状态 | T6 |

## 验证标准

### L1 语法与编译门禁

- `cd emacs/seshat-reader && rm -f *.elc && make all` → EXIT 0，warning ≤ 基线 **33**。
- `make checkdoc` → **0 报错**。
- 顶层 `emacs/` 文件：`emacs --batch -Q -L emacs -L emacs/seshat-reader -f batch-byte-compile <改动文件>` → **0 warning 0 error**（若既有文件存在基线警告，逐条对比零新增）。
- `check-parens` 全部通过（含新增 `emacs/seshat-library.el` 与两个新增测试文件）。

### L2 功能验证（全仓 ERT）

- 全仓 ERT **逐文件**跑，`unexpected = 0` **且 `skipped = 0`**（只看 `unexpected` 会假绿）。
- 必须带齐 **2 个仓库内 `-L`**（`emacs`、`emacs/seshat-reader`）+ straight `build-31.1` 下 **12 个**（`gt` / `pdd` / `posframe` / `etaf` / `etaf/lisp` / `etaf-ui` / `ebox` / `ebox/lisp` / `ecss` / `ecss/lisp` / `markdown-mode` / `visual-fill-column`）；缺 `-L` 会静默 skip 造成假绿。
- 基线 **26** 个测试文件，完成后 **28** 个（新增 `emacs/tests/seshat-library-test.el` 承 T1 / T2、`emacs/tests/seshat-transparency-test.el` 承 T5；T3a / T3b / T4 用例追加进既有 `emacs/tests/seshat-reader-reference-test.el`）。

### L3 真机验证（**需服务端可用**：`docker-compose.yml` 或 `go run ./cmd/server`）

1. 书架能列出 `ondemand` 根全部条目且三态正确；
2. `RET` 取书后文件落位、state 登记、能打开阅读；
3. 服务端替换该书内容后 `u` 能刷新本地副本；
4. 服务端改名该书后，旧 uid 形态链接仍能跟随打开；
5. doc-id 形态旧链接仍可用；
6. denote 改名 / dired 改名与删除 / org-agenda 生成三项行为与未装 seshat 时一致。

**服务端不可用 → 记「未验证」并在报告说明，不阻塞归档。**

## 已知取舍

- **A2（副本可能过期）**：`ondemand` 根的本地副本没有可检测的过期信号（`blob` 恒空串、事件无 `size/mtime`），因此本计划**不做自动比对**，只提供显式刷新（`u` 键 / 命令）。代价是：服务端更新书库文件后，用户不按 `u` 就继续读旧副本。此边界写进 `tech-debt.md`（「`ondemand` 副本过期无可检测信号」）与 `docs/emacs-reader.md` 的透明性边界节。
- **A2 派生取舍**：不自动比对也意味着取书事务**不读服务端内容做校验**（D2 第 4 步直接下载覆盖），避免为「可能过期」引入额外往返。
- **A4（两套根配置并存）**：`seshat-state-roots`（同步）与 `seshat-reader-annotation-roots`（批注/引用）**不在本计划统一**。代价是同一目录可能被配置两次、uid 解析要按两套分别查；收益是避免一次改动牵动批注 / 翻译 / 离线队列整条链路。统一列入 `tech-debt.md`。
- **A4 派生取舍**：`:store` 的 uid 查询走 `seshat-reader-annotation-roots` 得 `(tag . rel)` 后软依赖 `seshat-state-uid-for-path`，因此**两套根配置必须都能映射到同一路径**才能查到 uid；查不到即回落到 doc-id 形态（不报错，不阻塞插入链接）。
- **uid 形态不可读**：`seshat:` 链接的 uid 形态**不可读**，可读性由 org 链接描述（`[[seshat:uid:X][书名 第 3 页]]`）承担；未配置 `seshat-sync-roots` 或两套根配置 tag 不一致的用户仍产 doc-id 形态（自动回落，不报错）。
- **根 tag 名为 `uid` 的极端组合**：根 tag 为 `uid` 且相对路径恰好是 26 位大写字母数字时，`seshat:uid:<相对路径>` 会被误判为 uid 形态（判别规则见 D4：`uid:` 之后须匹配 26 位 Crockford Base32 `[0-9A-HJKMNP-TV-Z]\{26\}`（排除 I/L/O/U）才判 uid 形态，否则回落 doc-id 形态）。属极端组合，接受该风险，不为此改动 tag 校验规则。
- **清单规模**：`seshat-library` 一次性拉全根清单（分页到 `:has-more` nil），超大书库首次打开书架有等待；不做增量清单缓存，列入 `tech-debt.md`。
- **服务端需识别两种 uid 形态**（裸 uid 与 `uid:<uid>`）：客户端为兼容「根 tag 名为 `uid`」而选择显式前缀，代价是服务端解析多一段判断；Android 端当前没有 `seshat:` 链接能力，将来新增时按同一规则实现。

## 回滚

- 删除新增文件：`emacs/seshat-library.el`、`emacs/tests/seshat-library-test.el`、`emacs/tests/seshat-transparency-test.el`。
- 还原改动文件：`git checkout -- emacs/seshat-reader/seshat-reader-reference.el emacs/tests/seshat-reader-reference-test.el emacs/seshat-rest.el emacs/tests/seshat-rest-test.el`（末两者**仅注释字符集修正**），以及 T4 触及的 follow 实现文件（以 `git status --porcelain` 实际输出为准，逐项 checkout）。
- 文档回滚：`git checkout -- docs/emacs-reader.md docs/configuration.md docs/sync-protocol.md docs/architecture.md CHANGELOG.md openspec/decisions.md openspec/tech-debt.md openspec/active/roadmap.md`。
- **状态库无需清理**：本计划只写 `ondemand` 根已登记条目的 base-blob（blob 为空串），回滚后旧代码读同一状态库不受影响；若已用 `seshat-library-fetch` 下载过文件，本地副本保留（不属状态污染）。

## 注意事项

1. **TDD**：每个任务先写失败测试再实现（Red → Green → Refactor）。
2. `emacs/seshat-reader/**` 不得 require `seshat-library`；一律 `fboundp` + `declare-function` 软依赖。
3. 所有落盘路径必须过 `seshat-sync--local-path`，不得自行拼接。
4. `ondemand` 根**绝不写远端**；`d` 键只删本地副本。
5. 不改 `seshat-reader-annotation-roots`（两套根配置并存是已知取舍，记 tech-debt）。
6. **所有插入路径**（`:store` / 摘录 / 批注引用 / copy-link）的链接形态变更属用户可感知变更，CHANGELOG 必须标注，且 `:follow` 双形态兼容、`:export` 与 `--description` 对 uid 形态不得输出空串。
7. ERT 必须逐文件跑并断言 `skipped = 0`；缺 `-L` 会静默 skip 造成假绿。
8. `config` 任务下禁止跑 ERT / 批量字节编译（会占住用户 Emacs 主线程）；长耗时验证用 `verify` 隔离实例。
9. 测试一律用临时目录，禁止污染 `~/.local/share/seshat/`。
10. 不 commit、不 push（归档后由用户决定）。

## 假设复核

执行后逐条回填。结论取值：成立 ✓ / 被推翻 ✗ / 未验证 ?。

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| A1 | 按需取书的价值在补齐本地镜像，而非 Emacs 端读 PDF | 成立 ✓ | `seshat-library-fetch` 只做「下载落盘 + state 登记（`event-set-location` / `set-base-blob ""`）」，不含任何 PDF 解析；打开阅读一律转交 `seshat-reading-open`（`library → reading → reader` 单向依赖）。L2 `seshat-library-test.el` 38 例全绿覆盖三态与六步事务 |
| A2 | `ondemand` 副本过期可接受，只做显式刷新 | 成立 ✓ | 实现无任何内容比对（D2 第 4 步直接下载覆盖）；刷新只由 `u`（`force` 非 nil）触发；边界写入 `docs/emacs-reader.md` 透明性边界节与 `openspec/tech-debt.md`「`ondemand` 副本过期无可检测信号」 |
| A3 | uid 承载链接身份是改名稳定性的根治方式，且需向后兼容 | 成立 ✓ | uid 形态解析/构造/全部插入路径与回落共 **95 例**（reference 套件，含 doc-id 与 `local:` 形态回归断言全绿）；服务端 `internal/registry/service.go` 的 `Resolve` 补 `uid:` 前缀（`uidRefPrefix`）后两端对齐，`go test ./...` 13 包全 PASS |
| A4 | 两套根配置本计划暂不统一 | 成立 ✓ | `git status --porcelain` 中 `emacs/seshat-reader/seshat-reader-annotation.el` **未改动**；`seshat-state-roots` 与 `seshat-reader-annotation-roots` 两套并存，已记入 `openspec/tech-debt.md`「两套根配置待统一」与 `docs/configuration.md` 两套根配置对照表 |
| A5 | 透明性可用零侵入断言自动化验证 | 成立 ✓ | `seshat-transparency-test.el` **9 例全绿**（`unexpected = 0`、`skipped = 0`）；**5 组变异自检**证明断言真能失败；执行期修正两处（advice 白名单补 stock `pcase--mutually-exclusive-p`、`dired-mode-map` 断言递归前缀子 keymap 含 `remap`）均落在计划内，未放行任何真实侵入 |

## Phase 4：代码审查与安全审查（2026-10-26）

- **code-reviewer**：✅ 通过（无 blocking / 无 major；3 minor + 4 nit）。minor 中「错误契约穿透」「500 误报未登记」已随安全修复一并处理；`docs/architecture.md:161` 的旧三优先级表述同步更新。
- **security-reviewer**：❌ 需修复后合入（**1 high + 3 medium + 3 low**）→ 已全部修复并复核。
  - 【high】取书/删本地副本未校验 uid 所属根 mode → 新增 `seshat-library--ondemand-root-p` 门；`--collect` 改为校验响应 `:root` 与请求 tag 一致
  - 【medium】`u` 无确认强覆盖 → `yes-or-no-p` 确认
  - 【medium】下载无超时/大小上限 → 新增 2 个 defcustom + `Content-Length` 写盘前预判 + transport 实现 timeout
  - 【medium】分页无上限 → `--max-pages 500`
  - 【low】uid 未校验形态 / `--uid-local-path` 弱回落 / `refs.go` 日志可写爆 → 分别改为正则过滤、返回 nil + 幂等警告、120 字节 UTF-8 边界截断
- **修复后验证**：全仓 ERT **1110 → 1127**（library 38 → 52、rest 55 → 57、transport 33 → 34），0 unexpected / 0 skipped；Go 13 包 PASS；`make all` warning 33 = 基线、checkdoc 0
- **FP-3 假设复盘补充**：安全审查推翻了一条隐含假设——「路径安全（`seshat-sync--local-path`）⇒ 操作安全」不成立，还缺「归属安全（该 uid 是否该由该根处理）」。已编码为本计划的一条新不变量。

### Phase 4 收尾：安全复核与 N1–N6 修复

- **security-reviewer 复核**：✅ **可合入**——上一轮 7 项（1 high + 3 medium + 3 low）逐条验证修复生效，无绕过路径（mode 门位于所有写/删路径之前；`Content-Length` 闸在写盘之前；`--collect` 根一致校验不误伤正常响应）；新发现 6 项均为 low。
- **N1**：`seshat-library-fetch` 在任何请求之前增加 uid 形态守卫（此前依赖 `--collect` / `--parse-link` 前置过滤，属纵深防御缺口）
- **N2**：更正 mode 门位置的 docstring（门前可能有一次**只读**元数据请求；写/删/落盘一律在门后）
- **N3**：两个 defcustom 的 `:type` 改为 `(choice (const :tag "不限" nil) integer)`；`max-bytes` 判据 `integerp` → `numberp`（浮点不再静默失效）
- **N5**：补 `truncateForLog` 的多字节边界回退用例（原用例 `limit` 恰为 3 的整数倍，回退分支未执行）
- **N6**：分页上限用例改小上限 + 桩硬顶（原写法在上限被误删时会 `while` 永不退出，CI 挂死）
- **N4 与 3 条残余风险不改代码**，记入 `openspec/tech-debt.md`（uid 正则 6 处重复、`mirror` 根下载仍无 timeout/max-bytes、书架「根」列与状态库 root 可能分叉）
- **最终验证**：全仓 ERT **28 文件 / 1130 例 / 0 unexpected / 0 skipped**；Go **13 包 PASS**；`make -C emacs/seshat-reader all` EXIT 0、warning **33**（= 基线）、checkdoc **0**
- **L3 仍未验证**：服务端未运行（8080 无监听 / 无容器 / 无进程），六项端到端行为（书架三态、取书落位、`u` 刷新、服务端改名后 uid 链接跟随、旧 doc-id 链接、denote/dired/org-agenda 透明性）需人工在服务端可用后复核
